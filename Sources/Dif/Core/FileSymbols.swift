import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - Symbol Types

/// Kind of a top-level or member symbol shown in the `⌘R` File Structure popup.
enum FileSymbolKind: String, Sendable, CaseIterable {
    case function
    case method
    case `struct`
    case interface
    case type
    case `class`
    case `enum`
    case constant

    /// Single-letter badge shown in the symbol list, matching GoLand / JetBrains outline icons.
    var badge: String {
        switch self {
        case .function: return "f"
        case .method: return "m"
        case .struct: return "S"
        case .interface: return "I"
        case .type: return "T"
        case .class: return "C"
        case .enum: return "E"
        case .constant: return "C"
        }
    }

    /// Compact kind label for preview sub-headers and accessibility.
    var label: String {
        switch self {
        case .function: return "func"
        case .method: return "method"
        case .struct: return "struct"
        case .interface: return "interface"
        case .type: return "type"
        case .class: return "class"
        case .enum: return "enum"
        case .constant: return "const"
        }
    }

    /// Accent color aligned with the GoLand Light / Dark syntax palette in `Theme.swift`.
    var accentColor: Color {
        switch self {
        case .function: return Color(NSColor.dyn(0x0A5EB8, 0x2E8CE6))
        case .method: return Color(NSColor.dyn(0x246A9E, 0x4E8EC6))
        case .struct: return Color(NSColor.dyn(0x0E7C73, 0x50B8A8))
        case .interface: return Color(NSColor.dyn(0x684DB0, 0x9E8DD4))
        case .type: return Color(NSColor.dyn(0x8A5A2B, 0xDFC7B3))
        case .class: return Color(NSColor.dyn(0xB5541C, 0xD9A589))
        case .enum: return Color(NSColor.dyn(0x566B2F, 0x919758))
        case .constant: return Color(NSColor.dyn(0x9B2378, 0xC8569C))
        }
    }
}

/// Quick category filter pills in the File Structure popup header.
enum FileSymbolFilter: String, Sendable, CaseIterable {
    case all
    case functions
    case types

    var title: String {
        switch self {
        case .all: return L("All", "全部")
        case .functions: return L("Func", "函数")
        case .types: return L("Type", "类型")
        }
    }

    func matches(_ kind: FileSymbolKind) -> Bool {
        switch self {
        case .all:
            return true
        case .functions:
            return kind == .function || kind == .method
        case .types:
            return kind == .struct || kind == .interface || kind == .type || kind == .class || kind == .enum
        }
    }
}

/// One extracted symbol in the current file.
struct FileSymbolItem: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// Receiver, parameter/return signature, or type kind detail (e.g. `(*Manager) (lid int64) error`, `struct`).
    let detail: String
    let kind: FileSymbolKind
    /// 1-based start line number.
    let lineNumber: Int
    /// 0-based UTF-16 start column of the symbol name.
    let column: Int
    /// 0-based UTF-16 end column of the symbol name.
    let endColumn: Int
    let isExported: Bool
    /// 1-based inclusive end line number of the symbol's block, when determinable.
    var endLine: Int? = nil
}

/// Associates a file symbol with the diff hunk indices that overlap its line span.
struct ChangedFileSymbol: Identifiable, Equatable, Sendable {
    var id: String { symbol.id }
    let symbol: FileSymbolItem
    /// Sorted indices into the document's `hunks` array overlapping this symbol.
    let hunkIndices: [Int]
}

// MARK: - Multi-Language Static Symbol Extractor

/// Fast, zero-I/O, comment- and string-aware static symbol extractor.
enum FileSymbolExtractor {
    struct Token {
        let text: String
        /// 0-based UTF-16 start offset in the original line.
        let start: Int
        /// 0-based UTF-16 end offset in the original line.
        let end: Int
        let isIdentifier: Bool
    }

    struct ScannedLine {
        let lineNumber: Int
        let original: String
        let units: [UInt16]
        let masked: [UInt16]
        /// UTF-16 index where a trailing line comment begins (or `units.count`).
        let codeEnd: Int
        let startBraceDepth: Int
        let endBraceDepth: Int
        let startParenDepth: Int
        let endParenDepth: Int
        let leadingIndent: Int
        /// True when the line ends inside an unclosed multiline string (backtick, triple quote, or Rust raw string).
        let endInMultilineString: Bool
        /// True when a string/rune/backtick literal closed on this line with no subsequent non-whitespace code tokens.
        let hasTrailingLiteralAfterLastToken: Bool
        let tokens: [Token]
    }

    struct ScannerConfig {
        var slashComments: Bool = true
        var hashComments: Bool = false
        var nestedBlockComments: Bool = false
        var singleQuoteStrings: Bool = true
        var backtickStrings: Bool = false
        var backtickEscapes: Bool = false
        var tripleDoubleQuotes: Bool = false
        var tripleSingleQuotes: Bool = false
        var rustLifetimesAndRawStrings: Bool = false
    }

    /// Extracts symbols from `lines` using language-appropriate rules.
    static func extract(lines: [String], language: LanguageSpec) -> [FileSymbolItem] {
        guard !lines.isEmpty else { return [] }
        switch language.name {
        case "Go":
            return extractGo(lines: lines)
        case "Swift":
            return extractSwift(lines: lines)
        case "Rust":
            return extractRust(lines: lines)
        case "JavaScript":
            return extractJavaScript(lines: lines)
        case "Python":
            return extractPython(lines: lines)
        case "C/C++":
            return extractCFamily(lines: lines)
        default:
            return extractFallback(lines: lines, language: language)
        }
    }

    // MARK: - Go Extraction

    private static func extractGo(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: true,
            hashComments: false,
            nestedBlockComments: false,
            singleQuoteStrings: true,
            backtickStrings: true,
            backtickEscapes: false,
            tripleDoubleQuotes: false,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        var inTypeBlock = false
        var typeBlockParenDepth = 0
        var inConstBlock = false
        var constBlockParenDepth = 0
        var constContinuation = false

        for line in scanned {
            let tokens = line.tokens

            // Close grouped type / const blocks when their closing `)` returns parenDepth below block depth.
            if inTypeBlock && line.endBraceDepth == 0 && line.endParenDepth < typeBlockParenDepth {
                if line.startBraceDepth == 0, !tokens.isEmpty, tokens[0].text != ")" {
                    parseGoTypeEntry(tokens: tokens, startIndex: 0, line: line, into: &results)
                }
                inTypeBlock = false
                continue
            }
            if inConstBlock && line.endBraceDepth == 0 && line.endParenDepth < constBlockParenDepth {
                if line.startBraceDepth == 0, !tokens.isEmpty, tokens[0].text != ")", !constContinuation, line.startParenDepth == constBlockParenDepth {
                    parseGoConstEntries(tokens: tokens, startIndex: 0, line: line, into: &results)
                }
                inConstBlock = false
                constContinuation = false
                continue
            }

            // Inside a top-level `const ( ... )` block (handle even when `tokens` is empty, e.g. closing multiline backtick or `"world"` continuation).
            if inConstBlock {
                if !tokens.isEmpty, line.startBraceDepth == 0, line.startParenDepth == constBlockParenDepth, !constContinuation {
                    parseGoConstEntries(tokens: tokens, startIndex: 0, line: line, into: &results)
                }
                if !tokens.isEmpty || line.hasTrailingLiteralAfterLastToken || line.endInMultilineString {
                    let endsWithOp = !line.hasTrailingLiteralAfterLastToken && endsWithGoContinuationOperator(tokens)
                    constContinuation = line.endInMultilineString
                        || line.endBraceDepth > 0
                        || line.endParenDepth > constBlockParenDepth
                        || endsWithOp
                }
                continue
            }

            guard !tokens.isEmpty else { continue }

            // Inside a top-level `type ( ... )` block (skip struct fields / interface methods at braceDepth > 0).
            if inTypeBlock {
                if line.startBraceDepth == 0 && line.startParenDepth == typeBlockParenDepth {
                    parseGoTypeEntry(tokens: tokens, startIndex: 0, line: line, into: &results)
                }
                continue
            }

            // Top-level Go declarations live at braceDepth == 0.
            guard line.startBraceDepth == 0 else { continue }

            switch tokens[0].text {
            case "func":
                parseGoFunc(tokens: tokens, line: line, into: &results)

            case "type":
                if tokens.count >= 2 && tokens[1].text == "(" {
                    // Single-line `type ( Foo struct{} )` vs multi-line block.
                    if line.endParenDepth > line.startParenDepth {
                        inTypeBlock = true
                        typeBlockParenDepth = line.startParenDepth + 1
                        if tokens.count > 2 && tokens[2].text != ")" {
                            parseGoTypeEntry(tokens: tokens, startIndex: 2, line: line, into: &results)
                        }
                    } else if tokens.count > 2 && tokens[2].text != ")" {
                        parseGoTypeEntry(tokens: tokens, startIndex: 2, line: line, into: &results)
                    }
                } else {
                    parseGoTypeEntry(tokens: tokens, startIndex: 1, line: line, into: &results)
                }

            case "const":
                if tokens.count >= 2 && tokens[1].text == "(" {
                    if line.endParenDepth > line.startParenDepth {
                        inConstBlock = true
                        constBlockParenDepth = line.startParenDepth + 1
                        constContinuation = false
                        if tokens.count > 2 && tokens[2].text != ")" {
                            parseGoConstEntries(tokens: tokens, startIndex: 2, line: line, into: &results)
                            let endsWithOp = !line.hasTrailingLiteralAfterLastToken && endsWithGoContinuationOperator(tokens)
                            constContinuation = line.endInMultilineString
                                || line.endBraceDepth > 0
                                || line.endParenDepth > constBlockParenDepth
                                || endsWithOp
                        }
                    } else if tokens.count > 2 && tokens[2].text != ")" {
                        parseGoConstEntries(tokens: tokens, startIndex: 2, line: line, into: &results)
                    }
                } else {
                    parseGoConstEntries(tokens: tokens, startIndex: 1, line: line, into: &results)
                }

            default:
                break
            }
        }

        return attachBraceEndLines(results, scanned: scanned)
    }

    private static func parseGoFunc(tokens: [Token], line: ScannedLine, into results: inout [FileSymbolItem]) {
        guard tokens.count >= 2 else { return }

        if tokens[1].text == "(" {
            // Method: `func (r *Recv) Name(...) ...` or `func (*Recv) Name(...) ...`
            guard let closeIdx = matchingClose(tokens: tokens, openIndex: 1, open: "(", close: ")") else { return }
            let nameIdx = closeIdx + 1
            guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { return }
            let nameTok = tokens[nameIdx]
            let recvInner = sliceOriginal(line, start: tokens[1].end, end: tokens[closeIdx].start)
            let recvType = extractGoReceiverType(recvInner)
            let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
            let sig = cleanSignatureDetail(rawSig)
            let detail: String
            if !recvType.isEmpty && !sig.isEmpty {
                detail = "(\(recvType)) \(sig)"
            } else if !recvType.isEmpty {
                detail = "(\(recvType))"
            } else {
                detail = sig
            }
            results.append(makeItem(
                name: nameTok.text,
                detail: detail,
                kind: .method,
                lineNumber: line.lineNumber,
                column: nameTok.start,
                endColumn: nameTok.end,
                isExported: isGoExported(nameTok.text)
            ))
        } else if tokens[1].isIdentifier {
            // Package-level function: `func Name[T any](...) ...`
            let nameTok = tokens[1]
            let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
            let sig = cleanSignatureDetail(rawSig)
            results.append(makeItem(
                name: nameTok.text,
                detail: sig,
                kind: .function,
                lineNumber: line.lineNumber,
                column: nameTok.start,
                endColumn: nameTok.end,
                isExported: isGoExported(nameTok.text)
            ))
        }
    }

    private static func parseGoTypeEntry(
        tokens: [Token],
        startIndex: Int,
        line: ScannedLine,
        into results: inout [FileSymbolItem]
    ) {
        guard startIndex < tokens.count, tokens[startIndex].isIdentifier else { return }
        let nameTok = tokens[startIndex]
        guard nameTok.text != "_" else { return }

        var cursor = startIndex + 1
        var typeParams = ""
        if cursor < tokens.count, tokens[cursor].text == "[" {
            if let closeBracket = matchingClose(tokens: tokens, openIndex: cursor, open: "[", close: "]") {
                typeParams = collapseWhitespace(sliceOriginal(line, start: tokens[cursor].start, end: tokens[closeBracket].end))
                cursor = closeBracket + 1
            }
        }

        let kind: FileSymbolKind
        let detail: String
        if cursor < tokens.count, tokens[cursor].text == "struct" {
            kind = .struct
            detail = typeParams.isEmpty ? "struct" : "\(typeParams) struct"
        } else if cursor < tokens.count, tokens[cursor].text == "interface" {
            kind = .interface
            detail = typeParams.isEmpty ? "interface" : "\(typeParams) interface"
        } else {
            kind = .type
            let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
            let cleaned = cleanDetail(rawRest)
            detail = cleaned.isEmpty ? "type" : cleaned
        }

        results.append(makeItem(
            name: nameTok.text,
            detail: detail,
            kind: kind,
            lineNumber: line.lineNumber,
            column: nameTok.start,
            endColumn: nameTok.end,
            isExported: isGoExported(nameTok.text)
        ))
    }

    private static func parseGoConstEntries(
        tokens: [Token],
        startIndex: Int,
        line: ScannedLine,
        into results: inout [FileSymbolItem]
    ) {
        guard startIndex < tokens.count, tokens[startIndex].isIdentifier else { return }

        // Collect comma-separated identifier list: `A, B = 1, 2` or `StatusPending Status = iota`.
        var nameTokens: [Token] = []
        var idx = startIndex
        while idx < tokens.count, tokens[idx].isIdentifier {
            nameTokens.append(tokens[idx])
            idx += 1
            if idx < tokens.count, tokens[idx].text == "," {
                idx += 1
            } else {
                break
            }
        }
        guard let lastName = nameTokens.last else { return }
        let rawRest = sliceOriginal(line, start: lastName.end, end: line.codeEnd)
        let cleaned = cleanDetail(rawRest)
        let detail = cleaned.isEmpty ? "const" : cleaned

        for tok in nameTokens where tok.text != "_" {
            results.append(makeItem(
                name: tok.text,
                detail: detail,
                kind: .constant,
                lineNumber: line.lineNumber,
                column: tok.start,
                endColumn: tok.end,
                isExported: isGoExported(tok.text)
            ))
        }
    }

    /// Extracts `*Manager` or `Cache[K, V]` from a Go receiver inner string like `m *Manager` or `*Cache[K, V]`.
    private static func extractGoReceiverType(_ rawInner: String) -> String {
        let trimmed = rawInner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Split only on the first whitespace run (outside `[...]`) to separate optional receiver variable name from type.
        var bracketDepth = 0
        var splitIndex: String.Index?
        for i in trimmed.indices {
            let ch = trimmed[i]
            if ch == "[" {
                bracketDepth += 1
            } else if ch == "]" {
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth == 0 && ch.isWhitespace {
                splitIndex = i
                break
            }
        }
        if let splitIndex {
            let firstPart = String(trimmed[..<splitIndex])
            let rest = trimmed[splitIndex...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !rest.isEmpty, isSimpleIdentifier(firstPart) {
                return collapseWhitespace(rest)
            }
        }
        return collapseWhitespace(trimmed)
    }

    private static func endsWithGoContinuationOperator(_ tokens: [Token]) -> Bool {
        guard let last = tokens.last?.text else { return false }
        switch last {
        case "+", "-", "*", "/", "%", "|", "&", "^", "=", ",", "(", "[", "<<", ">>", "&^", "&&", "||":
            return true
        default:
            return false
        }
    }

    private static func isGoExported(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        return CharacterSet.uppercaseLetters.contains(first)
    }

    // MARK: - Swift Extraction

    private static let swiftModifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "package",
        "final", "static", "override", "mutating", "nonmutating",
        "nonisolated", "isolated", "indirect", "convenience", "required",
        "lazy", "weak", "unowned", "optional", "prefix", "postfix", "infix",
        "async", "borrowing", "consuming", "dynamic", "distributed",
    ]

    private static func extractSwift(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: true,
            hashComments: false,
            nestedBlockComments: true,
            singleQuoteStrings: false,
            backtickStrings: false,
            backtickEscapes: false,
            tripleDoubleQuotes: true,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }

            var idx = 0
            var isPrivate = false
            while idx < tokens.count {
                let text = tokens[idx].text
                if text == "@" {
                    idx += 1
                    if idx < tokens.count { idx += 1 }
                    if idx < tokens.count, tokens[idx].text == "(",
                       let close = matchingClose(tokens: tokens, openIndex: idx, open: "(", close: ")") {
                        idx = close + 1
                    }
                    continue
                }
                if text == "nonisolated", idx + 1 < tokens.count, tokens[idx + 1].text == "(",
                   let close = matchingClose(tokens: tokens, openIndex: idx + 1, open: "(", close: ")") {
                    idx = close + 1
                    continue
                }
                if swiftModifiers.contains(text) {
                    if text == "private" || text == "fileprivate" { isPrivate = true }
                    idx += 1
                    continue
                }
                // `class func ...` treats `class` as a modifier rather than a class declaration.
                if text == "class", idx + 1 < tokens.count, tokens[idx + 1].text == "func" {
                    idx += 1
                    continue
                }
                break
            }

            guard idx < tokens.count else { continue }
            let kw = tokens[idx].text
            let exported = !isPrivate

            switch kw {
            case "func":
                let nameIdx = idx + 1
                guard nameIdx < tokens.count else { continue }
                let nameTok = tokens[nameIdx]
                guard nameTok.isIdentifier || isSwiftOperatorToken(nameTok.text) else { continue }
                let kind: FileSymbolKind = line.startBraceDepth == 0 ? .function : .method
                let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleanSignatureDetail(rawSig),
                    kind: kind,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: exported
                ))

            case "struct", "class", "enum", "protocol", "actor", "typealias", "extension":
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let kind: FileSymbolKind
                let defaultDetail: String
                switch kw {
                case "struct": kind = .struct; defaultDetail = "struct"
                case "class": kind = .class; defaultDetail = "class"
                case "enum": kind = .enum; defaultDetail = "enum"
                case "protocol": kind = .interface; defaultDetail = "protocol"
                case "actor": kind = .class; defaultDetail = "actor"
                case "typealias": kind = .type; defaultDetail = "typealias"
                case "extension": kind = .type; defaultDetail = "extension"
                default: kind = .type; defaultDetail = kw
                }
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanDetail(rawRest)
                let detail: String
                if kw == "extension" {
                    detail = cleaned.isEmpty ? "extension" : "extension \(cleaned)"
                } else if kw == "actor" {
                    detail = cleaned.isEmpty ? "actor" : "actor \(cleaned)"
                } else {
                    detail = cleaned.isEmpty ? defaultDetail : cleaned
                }
                results.append(makeItem(
                    name: nameTok.text,
                    detail: detail,
                    kind: kind,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: exported
                ))

            default:
                break
            }
        }
        return attachBraceEndLines(results, scanned: scanned)
    }

    private static func isSwiftOperatorToken(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return "+-*/=<>!&|^~%?".unicodeScalars.contains(first)
    }

    // MARK: - Rust Extraction

    private static func extractRust(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: true,
            hashComments: false,
            nestedBlockComments: true,
            singleQuoteStrings: false,
            backtickStrings: false,
            backtickEscapes: false,
            tripleDoubleQuotes: false,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: true
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }

            var idx = 0
            var isPub = false
            while idx < tokens.count {
                let text = tokens[idx].text
                if text == "pub" {
                    isPub = true
                    idx += 1
                    if idx < tokens.count, tokens[idx].text == "(",
                       let close = matchingClose(tokens: tokens, openIndex: idx, open: "(", close: ")") {
                        idx = close + 1
                    }
                    continue
                }
                if text == "async" || text == "unsafe" || text == "default" {
                    idx += 1
                    continue
                }
                if text == "extern" {
                    idx += 1
                    continue
                }
                if text == "const", idx + 1 < tokens.count, tokens[idx + 1].text == "fn" {
                    idx += 1
                    continue
                }
                break
            }

            guard idx < tokens.count else { continue }
            let kw = tokens[idx].text

            switch kw {
            case "fn":
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let kind: FileSymbolKind = line.startBraceDepth == 0 ? .function : .method
                let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleanSignatureDetail(rawSig),
                    kind: kind,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isPub
                ))

            case "struct", "enum", "trait", "type":
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let kind: FileSymbolKind
                switch kw {
                case "struct": kind = .struct
                case "enum": kind = .enum
                case "trait": kind = .interface
                default: kind = .type
                }
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanDetail(rawRest)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned.isEmpty ? kw : cleaned,
                    kind: kind,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isPub
                ))

            case "impl":
                var cur = idx + 1
                if cur < tokens.count, tokens[cur].text == "<",
                   let closeAngle = matchingClose(tokens: tokens, openIndex: cur, open: "<", close: ">") {
                    cur = closeAngle + 1
                }
                guard cur < tokens.count else { continue }
                // Look for `for <Type>` in `impl Trait for Type`.
                var forIdx: Int?
                for i in cur..<tokens.count where tokens[i].text == "for" {
                    forIdx = i
                    break
                }
                if let forIdx, forIdx + 1 < tokens.count {
                    let targetTok = firstIdentifierToken(in: tokens, from: forIdx + 1) ?? tokens[forIdx + 1]
                    let traitPart = collapseWhitespace(sliceOriginal(line, start: tokens[cur].start, end: tokens[forIdx].start))
                    let detail = traitPart.isEmpty ? "impl" : "impl \(traitPart)"
                    results.append(makeItem(
                        name: targetTok.text,
                        detail: detail,
                        kind: .type,
                        lineNumber: line.lineNumber,
                        column: targetTok.start,
                        endColumn: targetTok.end,
                        isExported: true
                    ))
                } else if let targetTok = firstIdentifierToken(in: tokens, from: cur) {
                    results.append(makeItem(
                        name: targetTok.text,
                        detail: "impl",
                        kind: .type,
                        lineNumber: line.lineNumber,
                        column: targetTok.start,
                        endColumn: targetTok.end,
                        isExported: true
                    ))
                }

            case "const":
                guard line.startBraceDepth == 0 else { continue }
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier, tokens[nameIdx].text != "_" else { continue }
                let nameTok = tokens[nameIdx]
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanDetail(rawRest)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned.isEmpty ? "const" : cleaned,
                    kind: .constant,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isPub
                ))

            default:
                break
            }
        }
        return attachBraceEndLines(results, scanned: scanned)
    }

    // MARK: - TypeScript / JavaScript Extraction

    private static let jsModifiers: Set<String> = [
        "export", "default", "declare", "async", "abstract",
        "public", "private", "protected", "readonly", "static", "override",
    ]

    private static func extractJavaScript(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: true,
            hashComments: false,
            nestedBlockComments: false,
            singleQuoteStrings: true,
            backtickStrings: true,
            backtickEscapes: true,
            tripleDoubleQuotes: false,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }

            var idx = 0
            var isExported = false
            while idx < tokens.count, jsModifiers.contains(tokens[idx].text) {
                if tokens[idx].text == "export" { isExported = true }
                idx += 1
            }
            guard idx < tokens.count else { continue }
            let kw = tokens[idx].text

            switch kw {
            case "function":
                var nameIdx = idx + 1
                if nameIdx < tokens.count, tokens[nameIdx].text == "*" { nameIdx += 1 }
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleanSignatureDetail(rawSig),
                    kind: .function,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isExported
                ))

            case "class", "interface", "enum":
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let kind: FileSymbolKind = kw == "class" ? .class : (kw == "interface" ? .interface : .enum)
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanDetail(rawRest)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned.isEmpty ? kw : cleaned,
                    kind: kind,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isExported
                ))

            case "type":
                let nameIdx = idx + 1
                guard nameIdx + 1 < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nextText = tokens[nameIdx + 1].text
                guard nextText == "=" || nextText == "<" else { continue }
                let nameTok = tokens[nameIdx]
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanDetail(rawRest)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned.isEmpty ? "type" : cleaned,
                    kind: .type,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: isExported
                ))

            case "const", "let", "var":
                guard line.startBraceDepth == 0 else { continue }
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                // Match `const Foo = (...) =>` / `const Foo = async (...) =>` / `const Foo = function(...)`.
                if let eqIdx = tokens[(nameIdx + 1)...].firstIndex(where: { $0.text == "=" }) {
                    let rhsTokens = tokens[(eqIdx + 1)...]
                    let isArrow = rhsTokens.contains(where: { $0.text == "=>" })
                    let isFuncExpr = rhsTokens.first?.text == "function"
                        || (rhsTokens.first?.text == "async" && rhsTokens.dropFirst().first?.text == "function")
                    if isArrow || isFuncExpr {
                        let rawRhs = sliceOriginal(line, start: tokens[eqIdx].end, end: line.codeEnd)
                        results.append(makeItem(
                            name: nameTok.text,
                            detail: cleanSignatureDetail(rawRhs),
                            kind: .function,
                            lineNumber: line.lineNumber,
                            column: nameTok.start,
                            endColumn: nameTok.end,
                            isExported: isExported
                        ))
                    }
                }

            default:
                break
            }
        }
        return attachBraceEndLines(results, scanned: scanned)
    }

    // MARK: - Python Extraction

    private static func extractPython(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: false,
            hashComments: true,
            nestedBlockComments: false,
            singleQuoteStrings: true,
            backtickStrings: false,
            backtickEscapes: false,
            tripleDoubleQuotes: true,
            tripleSingleQuotes: true,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []
        var scopeStack: [(indent: Int, isClass: Bool)] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }

            // Pop scopes that ended before this line's indentation (ignore decorator lines `@...`).
            if tokens[0].text != "@" {
                while let top = scopeStack.last, line.leadingIndent <= top.indent {
                    scopeStack.removeLast()
                }
            }

            var idx = 0
            if tokens[idx].text == "async", idx + 1 < tokens.count, tokens[idx + 1].text == "def" {
                idx += 1
            }

            let kw = tokens[idx].text
            if kw == "def" {
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let isMethod = scopeStack.last?.isClass == true
                let rawSig = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanPythonDetail(rawSig)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned,
                    kind: isMethod ? .method : .function,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: !nameTok.text.hasPrefix("_")
                ))
                scopeStack.append((line.leadingIndent, false))
            } else if kw == "class" {
                let nameIdx = idx + 1
                guard nameIdx < tokens.count, tokens[nameIdx].isIdentifier else { continue }
                let nameTok = tokens[nameIdx]
                let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                let cleaned = cleanPythonDetail(rawRest)
                results.append(makeItem(
                    name: nameTok.text,
                    detail: cleaned.isEmpty ? "class" : cleaned,
                    kind: .class,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: !nameTok.text.hasPrefix("_")
                ))
                scopeStack.append((line.leadingIndent, true))
            }
        }
        return attachPythonEndLines(results, scanned: scanned)
    }

    private static func cleanPythonDetail(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(":") {
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleanSignatureDetail(trimmed)
    }

    // MARK: - C / C++ Extraction

    private static let cControlKeywords: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof", "decltype",
        "alignof", "static_assert", "typedef", "using", "namespace", "struct",
        "class", "enum", "union", "else", "do", "try", "template", "case", "goto", "delete", "new",
    ]

    private static func extractCFamily(lines: [String]) -> [FileSymbolItem] {
        let config = ScannerConfig(
            slashComments: true,
            hashComments: false,
            nestedBlockComments: false,
            singleQuoteStrings: true,
            backtickStrings: false,
            backtickEscapes: false,
            tripleDoubleQuotes: false,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        for lineIdx in scanned.indices {
            let line = scanned[lineIdx]
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }
            if tokens[0].text == "#" { continue }

            // `struct Name`, `class Name`, `enum [class|struct] Name` (skip forward declarations ending in `;`).
            let first = tokens[0].text
            if first == "struct" || first == "class" || first == "enum" {
                let isForwardDecl = tokens.last?.text == ";" && !tokens.contains(where: { $0.text == "{" })
                if !isForwardDecl {
                    var nameIdx = 1
                    if first == "enum", nameIdx < tokens.count,
                       tokens[nameIdx].text == "class" || tokens[nameIdx].text == "struct" {
                        nameIdx += 1
                    }
                    if nameIdx < tokens.count, tokens[nameIdx].isIdentifier {
                        let nameTok = tokens[nameIdx]
                        let kind: FileSymbolKind = first == "struct" ? .struct : (first == "class" ? .class : .enum)
                        results.append(makeItem(
                            name: nameTok.text,
                            detail: first,
                            kind: kind,
                            lineNumber: line.lineNumber,
                            column: nameTok.start,
                            endColumn: nameTok.end,
                            isExported: true
                        ))
                        continue
                    }
                }
            }

            // Top-level function definition: `braceDepth == 0`, contains `name(`, and opens `{` here or on next line.
            guard line.startBraceDepth == 0 else { continue }
            guard !tokens.contains(where: { $0.text == ";" }) else { continue }
            guard let openParen = tokens.firstIndex(where: { $0.text == "(" }), openParen >= 1 else { continue }
            let nameTok = tokens[openParen - 1]
            guard nameTok.isIdentifier, !cControlKeywords.contains(nameTok.text) else { continue }
            guard !cControlKeywords.contains(tokens[0].text) else { continue }
            // Must have a return type or `Class::` before name (avoids bare macro invocations like `FOO(x)`).
            guard openParen >= 2 else { continue }

            let opensBraceHere = tokens.contains(where: { $0.text == "{" })
            let opensBraceNext: Bool = {
                guard !opensBraceHere, lineIdx + 1 < scanned.count else { return false }
                return scanned[lineIdx + 1].tokens.first?.text == "{"
            }()
            guard opensBraceHere || opensBraceNext else { continue }

            let isMethod = openParen >= 3 && tokens[openParen - 2].text == "::"
            let rawSig = sliceOriginal(line, start: tokens[openParen].start, end: line.codeEnd)
            let sig = cleanSignatureDetail(rawSig)
            let detail: String
            if isMethod {
                let owner = tokens[openParen - 3].text
                detail = "\(owner):: \(sig)"
            } else {
                detail = sig
            }
            results.append(makeItem(
                name: nameTok.text,
                detail: detail,
                kind: isMethod ? .method : .function,
                lineNumber: line.lineNumber,
                column: nameTok.start,
                endColumn: nameTok.end,
                isExported: tokens[0].text != "static"
            ))
        }
        return attachBraceEndLines(results, scanned: scanned)
    }

    // MARK: - Generic Fallback (Kotlin, Java, Ruby, PHP, Lua, Protobuf, etc.)

    private static func extractFallback(lines: [String], language: LanguageSpec) -> [FileSymbolItem] {
        guard language.family == .cLike else { return [] }
        let config = ScannerConfig(
            slashComments: language.lineComments.contains(Array("//".utf8)),
            hashComments: language.lineComments.contains(Array("#".utf8)),
            nestedBlockComments: false,
            singleQuoteStrings: language.quotes.contains(UInt8(ascii: "'")),
            backtickStrings: language.multilineQuotes.contains(UInt8(ascii: "`")),
            backtickEscapes: false,
            tripleDoubleQuotes: language.tripleQuotes,
            tripleSingleQuotes: false,
            rustLifetimesAndRawStrings: false
        )
        let scanned = scan(lines: lines, config: config)
        var results: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }
            for i in tokens.indices {
                let kw = tokens[i].text
                guard i + 1 < tokens.count, tokens[i + 1].isIdentifier else { continue }
                let nameTok = tokens[i + 1]
                let kind: FileSymbolKind?
                switch kw {
                case "fun", "def", "function", "rpc":
                    kind = line.startBraceDepth == 0 ? .function : .method
                case "class", "object", "record":
                    kind = .class
                case "struct", "message":
                    kind = .struct
                case "interface", "trait", "protocol", "service":
                    kind = .interface
                case "enum":
                    kind = .enum
                case "typealias":
                    kind = .type
                default:
                    kind = nil
                }
                if let kind {
                    let rawRest = sliceOriginal(line, start: nameTok.end, end: line.codeEnd)
                    let detail = (kind == .function || kind == .method)
                        ? cleanSignatureDetail(rawRest)
                        : (cleanDetail(rawRest).isEmpty ? kw : cleanDetail(rawRest))
                    results.append(makeItem(
                        name: nameTok.text,
                        detail: detail,
                        kind: kind,
                        lineNumber: line.lineNumber,
                        column: nameTok.start,
                        endColumn: nameTok.end,
                        isExported: true
                    ))
                    break
                }
            }
        }
        return attachBraceEndLines(results, scanned: scanned)
    }

    // MARK: - Shared Scanner (Comment & String Masking with Exact UTF-16 Offsets)

    static func scan(lines: [String], config: ScannerConfig) -> [ScannedLine] {
        var result: [ScannedLine] = []
        result.reserveCapacity(lines.count)

        var blockCommentDepth = 0
        var inBacktick = false
        var tripleQuoteChar: UInt16 = 0
        var rustRawHashes: Int? = nil
        var braceDepth = 0
        var parenDepth = 0

        let space: UInt16 = 32
        let tab: UInt16 = 9
        let slash: UInt16 = 47
        let star: UInt16 = 42
        let hash: UInt16 = 35
        let dquote: UInt16 = 34
        let squote: UInt16 = 39
        let backtick: UInt16 = 96
        let backslash: UInt16 = 92
        let openBrace: UInt16 = 123
        let closeBrace: UInt16 = 125
        let openParen: UInt16 = 40
        let closeParen: UInt16 = 41
        let lowerR: UInt16 = 114

        for (index, rawLine) in lines.enumerated() {
            let units = Array(rawLine.utf16)
            let count = units.count
            var masked = [UInt16](repeating: space, count: count)

            var leadingIndent = 0
            for u in units {
                if u == space { leadingIndent += 1 }
                else if u == tab { leadingIndent += 4 }
                else { break }
            }

            let startBrace = braceDepth
            let startParen = parenDepth
            var codeEnd = count
            var hasTrailingLiteralAfterLastToken = false
            var i = 0

            while i < count {
                // 1. Inside block comment `/* ... */`
                if blockCommentDepth > 0 {
                    if config.nestedBlockComments && i + 1 < count && units[i] == slash && units[i + 1] == star {
                        blockCommentDepth += 1
                        i += 2
                    } else if i + 1 < count && units[i] == star && units[i + 1] == slash {
                        blockCommentDepth -= 1
                        i += 2
                    } else {
                        i += 1
                    }
                    continue
                }

                // 2. Inside multiline backtick raw/template string
                if inBacktick {
                    if config.backtickEscapes && units[i] == backslash && i + 1 < count {
                        i += 2
                        continue
                    }
                    if units[i] == backtick {
                        inBacktick = false
                        hasTrailingLiteralAfterLastToken = true
                    }
                    i += 1
                    continue
                }

                // 3. Inside multiline triple-quoted string (`"""` or `'''`)
                if tripleQuoteChar != 0 {
                    if units[i] == backslash && i + 1 < count {
                        i += 2
                        continue
                    }
                    if i + 2 < count && units[i] == tripleQuoteChar && units[i + 1] == tripleQuoteChar && units[i + 2] == tripleQuoteChar {
                        tripleQuoteChar = 0
                        hasTrailingLiteralAfterLastToken = true
                        i += 3
                        continue
                    }
                    i += 1
                    continue
                }

                // 4. Inside Rust raw string `r#"..."#`
                if let hashes = rustRawHashes {
                    if units[i] == dquote {
                        var h = 0
                        while h < hashes && i + 1 + h < count && units[i + 1 + h] == hash {
                            h += 1
                        }
                        if h == hashes {
                            rustRawHashes = nil
                            hasTrailingLiteralAfterLastToken = true
                            i += 1 + hashes
                            continue
                        }
                    }
                    i += 1
                    continue
                }

                let c = units[i]

                // 5. Line comments (`//` or `#`)
                if config.slashComments && c == slash && i + 1 < count && units[i + 1] == slash {
                    codeEnd = i
                    break
                }
                if config.hashComments && c == hash {
                    codeEnd = i
                    break
                }

                // 6. Block comment start `/*`
                if config.slashComments && c == slash && i + 1 < count && units[i + 1] == star {
                    blockCommentDepth = 1
                    i += 2
                    continue
                }

                // 7. Triple-quoted strings (`"""` / `'''`)
                if config.tripleDoubleQuotes && c == dquote && i + 2 < count && units[i + 1] == dquote && units[i + 2] == dquote {
                    tripleQuoteChar = dquote
                    i += 3
                    continue
                }
                if config.tripleSingleQuotes && c == squote && i + 2 < count && units[i + 1] == squote && units[i + 2] == squote {
                    tripleQuoteChar = squote
                    i += 3
                    continue
                }

                // 8. Backtick string
                if config.backtickStrings && c == backtick {
                    inBacktick = true
                    i += 1
                    continue
                }

                // 9. Rust raw string `r"..."` or `r#"..."#`
                if config.rustLifetimesAndRawStrings && c == lowerR && (i == 0 || !isIdentContinue(units[i - 1])) {
                    var j = i + 1
                    while j < count && units[j] == hash { j += 1 }
                    if j < count && units[j] == dquote {
                        rustRawHashes = j - (i + 1)
                        i = j + 1
                        continue
                    }
                }

                // 10. Double-quoted single-line string
                if c == dquote {
                    i += 1
                    while i < count {
                        if units[i] == backslash && i + 1 < count {
                            i += 2
                            continue
                        }
                        if units[i] == dquote {
                            i += 1
                            break
                        }
                        i += 1
                    }
                    hasTrailingLiteralAfterLastToken = true
                    continue
                }

                // 11. Single-quoted string / char literal (Rust distinguishes `'a` lifetime vs `'x'` char literal)
                if c == squote {
                    if config.rustLifetimesAndRawStrings {
                        if i + 2 < count && units[i + 1] == backslash {
                            // Escaped char literal like `'\n'` or `'\u{1F600}'`
                            var j = i + 3
                            while j < count && units[j] != squote && j - i < 16 { j += 1 }
                            if j < count && units[j] == squote {
                                hasTrailingLiteralAfterLastToken = true
                                i = j + 1
                                continue
                            }
                        } else if i + 2 < count && units[i + 2] == squote {
                            hasTrailingLiteralAfterLastToken = true
                            i += 3
                            continue
                        }
                        // Lifetime like `'a` — keep in masked output!
                        masked[i] = c
                        hasTrailingLiteralAfterLastToken = false
                        i += 1
                        continue
                    } else if config.singleQuoteStrings {
                        i += 1
                        while i < count {
                            if units[i] == backslash && i + 1 < count {
                                i += 2
                                continue
                            }
                            if units[i] == squote {
                                i += 1
                                break
                            }
                            i += 1
                        }
                        hasTrailingLiteralAfterLastToken = true
                        continue
                    }
                }

                // 12. Normal code character
                masked[i] = c
                if c != space && c != tab && c != 13 && c != 10 {
                    hasTrailingLiteralAfterLastToken = false
                }
                if c == openBrace { braceDepth += 1 }
                else if c == closeBrace { braceDepth = max(0, braceDepth - 1) }
                else if c == openParen { parenDepth += 1 }
                else if c == closeParen { parenDepth = max(0, parenDepth - 1) }
                i += 1
            }

            let tokens = tokenize(masked)
            let endInMultiline = inBacktick || tripleQuoteChar != 0 || rustRawHashes != nil
            result.append(ScannedLine(
                lineNumber: index + 1,
                original: rawLine,
                units: units,
                masked: masked,
                codeEnd: codeEnd,
                startBraceDepth: startBrace,
                endBraceDepth: braceDepth,
                startParenDepth: startParen,
                endParenDepth: parenDepth,
                leadingIndent: leadingIndent,
                endInMultilineString: endInMultiline,
                hasTrailingLiteralAfterLastToken: hasTrailingLiteralAfterLastToken && !endInMultiline,
                tokens: tokens
            ))
        }

        return result
    }

    private static func tokenize(_ masked: [UInt16]) -> [Token] {
        var tokens: [Token] = []
        let count = masked.count
        var i = 0

        while i < count {
            let c = masked[i]
            if c == 32 || c == 9 || c == 13 || c == 10 {
                i += 1
                continue
            }
            if isIdentStart(c) {
                let start = i
                i += 1
                while i < count && isIdentContinue(masked[i]) { i += 1 }
                let text = String(utf16CodeUnits: Array(masked[start..<i]), count: i - start)
                tokens.append(Token(text: text, start: start, end: i, isIdentifier: true))
                continue
            }
            // Two-char punctuation operators useful for parsing (`=>`, `::`, `<<`, `>>`, `&&`, `||`, `&^`).
            if i + 1 < count {
                let n = masked[i + 1]
                let pair: String?
                switch (c, n) {
                case (61, 62): pair = "=>"
                case (58, 58): pair = "::"
                case (60, 60): pair = "<<"
                case (62, 62): pair = ">>"
                case (38, 38): pair = "&&"
                case (124, 124): pair = "||"
                case (38, 94): pair = "&^"
                default: pair = nil
                }
                if let pair {
                    tokens.append(Token(text: pair, start: i, end: i + 2, isIdentifier: false))
                    i += 2
                    continue
                }
            }
            let text = String(utf16CodeUnits: [c], count: 1)
            tokens.append(Token(text: text, start: i, end: i + 1, isIdentifier: false))
            i += 1
        }

        return tokens
    }

    // MARK: - Small Helpers

    private static func makeItem(
        name: String,
        detail: String,
        kind: FileSymbolKind,
        lineNumber: Int,
        column: Int,
        endColumn: Int,
        isExported: Bool
    ) -> FileSymbolItem {
        FileSymbolItem(
            id: "\(lineNumber):\(column):\(kind.rawValue):\(name)",
            name: name,
            detail: detail,
            kind: kind,
            lineNumber: lineNumber,
            column: column,
            endColumn: endColumn,
            isExported: isExported
        )
    }

    static func matchingClose(tokens: [Token], openIndex: Int, open: String, close: String) -> Int? {
        var depth = 0
        for i in openIndex..<tokens.count {
            if tokens[i].text == open {
                depth += 1
            } else if tokens[i].text == close {
                depth -= 1
                if depth == 0 { return i }
            }
        }
        return nil
    }

    private static func firstIdentifierToken(in tokens: [Token], from start: Int) -> Token? {
        for i in start..<tokens.count where tokens[i].isIdentifier {
            return tokens[i]
        }
        return nil
    }

    private static func sliceOriginal(_ line: ScannedLine, start: Int, end: Int) -> String {
        let clampedStart = max(0, min(start, line.units.count))
        let clampedEnd = max(clampedStart, min(end, line.units.count))
        guard clampedEnd > clampedStart else { return "" }
        return String(utf16CodeUnits: Array(line.units[clampedStart..<clampedEnd]), count: clampedEnd - clampedStart)
    }

    private static func cleanSignatureDetail(_ raw: String) -> String {
        var text = cleanDetail(raw)
        if text.hasSuffix("(") {
            text += "…)"
        }
        return text
    }

    private static func cleanDetail(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip trailing opening brace `{` and inline empty body `{}`.
        while trimmed.hasSuffix("{") || trimmed.hasSuffix("{}") {
            if trimmed.hasSuffix("{}") {
                trimmed.removeLast(2)
            } else {
                trimmed.removeLast()
            }
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        trimmed = collapseWhitespace(trimmed)
        if trimmed.count > 96 {
            return String(trimmed.prefix(95)) + "…"
        }
        return trimmed
    }

    private static func collapseWhitespace(_ input: String) -> String {
        var out = ""
        out.reserveCapacity(input.count)
        var lastWasSpace = false
        for ch in input {
            if ch.isWhitespace {
                if !lastWasSpace {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
    }

    private static func isIdentContinue(_ c: UInt16) -> Bool {
        isIdentStart(c) || (c >= 48 && c <= 57)
    }

    private static func isSimpleIdentifier(_ text: String) -> Bool {
        let units = Array(text.utf16)
        guard let first = units.first, isIdentStart(first) else { return false }
        return units.dropFirst().allSatisfy(isIdentContinue)
    }

    // MARK: - Symbol Block Ranges & Changed Symbol Attribution

    private static let headerContinuationTokens: Set<String> = [
        ",", "(", "->", ":", "where", "throws", "rethrows", "async", "=", "|", "&",
    ]

    /// Infers 1-based inclusive `endLine` for brace-delimited languages using `ScannedLine` brace depths.
    static func attachBraceEndLines(_ items: [FileSymbolItem], scanned: [ScannedLine]) -> [FileSymbolItem] {
        guard !items.isEmpty, !scanned.isEmpty else { return items }
        let lastFileLine = scanned.last?.lineNumber ?? scanned.count
        var out = items
        for i in out.indices {
            let startIdx = out[i].lineNumber - 1
            guard scanned.indices.contains(startIdx) else { continue }
            let startLine = scanned[startIdx]
            let baseDepth = startLine.startBraceDepth

            if out[i].kind == .constant {
                out[i].endLine = out[i].lineNumber
                continue
            }

            if startLine.endBraceDepth > baseDepth {
                out[i].endLine = findClosingBraceLine(in: scanned, after: startIdx, targetDepth: baseDepth, fallback: lastFileLine)
                continue
            }

            if startLine.tokens.contains(where: { $0.text == "{" }) || startLine.tokens.last?.text == ";" {
                out[i].endLine = out[i].lineNumber
                continue
            }

            // Look ahead for multi-line signatures or Allman-style `{` on subsequent lines,
            // stopping before the next extracted symbol so single-line declarations never steal a later block.
            let nextSymbolIdx = (i + 1 < out.count) ? max(startIdx + 1, out[i + 1].lineNumber - 1) : scanned.count
            let limit = min(scanned.count, nextSymbolIdx)
            var inferredEnd = out[i].lineNumber
            var k = startIdx + 1
            while k < limit {
                let prev = scanned[k - 1]
                let cur = scanned[k]
                if cur.endBraceDepth < baseDepth { break }

                if cur.tokens.contains(where: { $0.text == "{" }) {
                    if cur.endBraceDepth > baseDepth {
                        inferredEnd = findClosingBraceLine(in: scanned, after: k, targetDepth: baseDepth, fallback: lastFileLine)
                        break
                    }
                    // Inline `interface{}` / `struct{}` inside a multi-line parameter list still has open parens;
                    // keep scanning until the parameter list closes and the body `{` appears.
                    if cur.endParenDepth <= startLine.startParenDepth {
                        inferredEnd = cur.lineNumber
                        break
                    }
                }
                if cur.tokens.contains(where: { $0.text == ";" }) && cur.endBraceDepth == baseDepth {
                    inferredEnd = cur.lineNumber
                    break
                }

                let prevContinues = prev.endParenDepth > startLine.startParenDepth
                    || prev.tokens.last.map({ headerContinuationTokens.contains($0.text) }) == true
                if prevContinues || cur.tokens.isEmpty || k == startIdx + 1 {
                    k += 1
                    continue
                }
                break
            }
            out[i].endLine = inferredEnd
        }
        return out
    }

    private static func findClosingBraceLine(
        in scanned: [ScannedLine],
        after openIdx: Int,
        targetDepth: Int,
        fallback: Int
    ) -> Int {
        var j = openIdx + 1
        while j < scanned.count {
            if scanned[j].endBraceDepth <= targetDepth {
                return scanned[j].lineNumber
            }
            j += 1
        }
        return fallback
    }

    /// Infers 1-based inclusive `endLine` for indentation-scoped languages (Python).
    private static func attachPythonEndLines(_ items: [FileSymbolItem], scanned: [ScannedLine]) -> [FileSymbolItem] {
        guard !items.isEmpty, !scanned.isEmpty else { return items }
        var out = items
        for i in out.indices {
            let startIdx = out[i].lineNumber - 1
            guard scanned.indices.contains(startIdx) else { continue }
            let startLine = scanned[startIdx]
            let baseIndent = startLine.leadingIndent

            // Advance across multi-line `def` parameter lists before checking body indentation.
            var headerEndIdx = startIdx
            while headerEndIdx + 1 < scanned.count && scanned[headerEndIdx].endParenDepth > startLine.startParenDepth {
                headerEndIdx += 1
            }

            var lastBodyLine = scanned[headerEndIdx].lineNumber
            var prevInMultiline = scanned[headerEndIdx].endInMultilineString
            var j = headerEndIdx + 1
            while j < scanned.count {
                let line = scanned[j]
                let hasContent = !line.tokens.isEmpty || line.hasTrailingLiteralAfterLastToken
                if !prevInMultiline && hasContent && line.leadingIndent <= baseIndent {
                    break
                }
                if hasContent || line.endInMultilineString || prevInMultiline {
                    lastBodyLine = line.lineNumber
                }
                prevInMultiline = line.endInMultilineString
                j += 1
            }
            out[i].endLine = max(out[i].lineNumber, lastBodyLine)
        }
        return out
    }

    /// Attributes `hunks` to symbols whose 1-based range `lineNumber...(endLine ?? lineNumber)`
    /// overlaps at least one hunk on `side` (defaults to `.right`).
    static func changedSymbols(
        symbols: [FileSymbolItem],
        hunks: [Hunk],
        side: Side = .right
    ) -> [ChangedFileSymbol] {
        guard !symbols.isEmpty, !hunks.isEmpty else { return [] }
        var result: [ChangedFileSymbol] = []
        for symbol in symbols {
            let symStart = max(0, symbol.lineNumber - 1)
            let symEnd = max(symStart, (symbol.endLine ?? symbol.lineNumber) - 1)
            var matched: [Int] = []
            for (index, hunk) in hunks.enumerated() {
                let start = side == .left ? hunk.leftStart : hunk.rightStart
                let count = side == .left ? hunk.leftCount : hunk.rightCount
                if count > 0 {
                    let end = start + count - 1
                    if start <= symEnd && end >= symStart {
                        matched.append(index)
                    }
                } else {
                    // Pure deletion on the opposite side anchored inside this symbol's body.
                    if symStart < start && start <= symEnd {
                        matched.append(index)
                    }
                }
            }
            if !matched.isEmpty {
                result.append(ChangedFileSymbol(symbol: symbol, hunkIndices: matched))
            }
        }
        return result
    }
}

// MARK: - File Symbols Popup Model

/// Drives the `⌘R` File Structure / Symbols popup with instant extraction, fuzzy filtering,
/// cursor-aware pre-selection, and zero-I/O live syntax-highlighted preview.
@MainActor
@Observable
final class FileSymbolsModel {
    nonisolated static let previewLinesBefore = 4
    nonisolated static let previewLinesAfter = 10

    var title: String = ""
    var displayPath: String = ""
    var kindFilter: FileSymbolFilter = .all {
        didSet {
            if kindFilter != oldValue, !suppressFilterRebuild {
                rebuildFiltered(preserveSelectionIfEmptyQuery: true)
            }
        }
    }
    var filterQuery: String = "" {
        didSet {
            if filterQuery != oldValue, !suppressFilterRebuild {
                rebuildFiltered(preserveSelectionIfEmptyQuery: false)
            }
        }
    }

    private(set) var allItems: [FileSymbolItem] = []
    private(set) var filteredItems: [FileSymbolItem] = []
    /// Matched UTF-8 byte offsets into `item.name` keyed by `item.id`, for fuzzy highlighting.
    private(set) var matchPositions: [String: [Int]] = [:]
    var selectedIndex: Int = 0
    var focusToken: Int = 0
    private(set) var previewContext: ReferencePreviewContext?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var documentLines: [String] = []
    @ObservationIgnored private var documentSpans: [[SyntaxSpan]] = []
    @ObservationIgnored private var documentLanguage: LanguageSpec = .plain
    @ObservationIgnored private var documentURL: URL = URL(fileURLWithPath: "/")
    @ObservationIgnored private var usingLeftSide: Bool = false
    @ObservationIgnored private var cursorLineWhenOpened: Int = 1
    @ObservationIgnored private var suppressFilterRebuild: Bool = false

    var selectedItem: FileSymbolItem? {
        guard filteredItems.indices.contains(selectedIndex) else { return nil }
        return filteredItems[selectedIndex]
    }

    /// Populates the model directly from the active `ViewerModel` text document (zero disk I/O).
    func prepare() {
        guard let store,
              let doc = store.viewer.document,
              case .text = doc.content else {
            release()
            return
        }

        let request = store.viewer.request
        let path = request?.path ?? ""
        let filename = path.isEmpty ? L("Current File", "当前文件") : (path as NSString).lastPathComponent
        let fileURL = request?.fileURL ?? URL(fileURLWithPath: "/" + filename)

        let useLeft = doc.right.lines.isEmpty && !doc.left.lines.isEmpty
        let buffer = useLeft ? doc.left : doc.right
        let lines = buffer.lines
        let spans = buffer.spans.count == lines.count
            ? buffer.spans
            : Highlighter.highlight(lines, language: doc.language)
        let cursorLine = store.viewer.currentCaretPosition().row + 1

        prepare(
            title: filename,
            displayPath: path.isEmpty ? filename : path,
            fileURL: fileURL,
            lines: lines,
            spans: spans,
            language: doc.language,
            cursorLine: cursorLine,
            usingLeftSide: useLeft
        )
    }

    /// Populates the model from explicit lines, spans, language, and cursor line (directly testable without UI).
    func prepare(
        title: String,
        displayPath: String? = nil,
        fileURL: URL = URL(fileURLWithPath: "/file"),
        lines: [String],
        spans: [[SyntaxSpan]]? = nil,
        language: LanguageSpec,
        cursorLine: Int = 1,
        usingLeftSide: Bool = false
    ) {
        self.title = title
        self.displayPath = displayPath ?? title
        self.documentURL = fileURL
        self.documentLines = lines
        self.documentLanguage = language
        self.documentSpans = (spans?.count == lines.count ? spans : nil)
            ?? Highlighter.highlight(lines, language: language)
        self.usingLeftSide = usingLeftSide
        self.cursorLineWhenOpened = max(1, cursorLine)

        self.allItems = FileSymbolExtractor.extract(lines: lines, language: language)
        suppressFilterRebuild = true
        self.kindFilter = .all
        self.filterQuery = ""
        suppressFilterRebuild = false
        self.filteredItems = self.allItems
        self.matchPositions = [:]
        self.selectedIndex = Self.nearestSymbolIndex(in: self.filteredItems, cursorLine: self.cursorLineWhenOpened)
        self.focusToken += 1
        updatePreviewForSelection()
    }

    func move(_ delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let next = min(filteredItems.count - 1, max(0, selectedIndex + delta))
        guard next != selectedIndex else { return }
        selectedIndex = next
        updatePreviewForSelection()
    }

    func select(_ index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        selectedIndex = index
        updatePreviewForSelection()
    }

    func cycleFilter(_ delta: Int = 1) {
        let cases = FileSymbolFilter.allCases
        guard let idx = cases.firstIndex(of: kindFilter) else { return }
        let next = ((idx + delta) % cases.count + cases.count) % cases.count
        kindFilter = cases[next]
    }

    func positions(for item: FileSymbolItem) -> [Int] {
        matchPositions[item.id] ?? []
    }

    /// Records jump origin on `store.jumpHistory`, dismisses the popup, jumps in-place, and focuses the canvas.
    func activate(_ index: Int? = nil) {
        let targetIndex = index ?? selectedIndex
        guard let store, filteredItems.indices.contains(targetIndex) else { return }
        let item = filteredItems[targetIndex]
        let isLeftOnly = usingLeftSide

        store.recordCurrentJumpOriginIfDifferent(targetLine1Based: item.lineNumber)
        store.dismissPopup(restoreFocus: false)

        if isLeftOnly, let container = store.viewer.container, let doc = store.viewer.document, !doc.left.lines.isEmpty {
            let lineIdx = max(0, min(item.lineNumber - 1, doc.left.lines.count - 1))
            container.canvas.focusLine = (.left, lineIdx)
            container.scroll(toRow: container.canvas.row(forLine: lineIdx, side: .left), fraction: 0.35, animated: false)
        } else {
            store.viewer.reveal(line: item.lineNumber, column: item.column)
        }
        store.viewer.focusCanvas()
    }

    /// Clears cached document references and filter state when the popup closes.
    func release() {
        suppressFilterRebuild = true
        kindFilter = .all
        filterQuery = ""
        suppressFilterRebuild = false
        documentLines = []
        documentSpans = []
        allItems = []
        filteredItems = []
        matchPositions = [:]
        previewContext = nil
        usingLeftSide = false
    }

    func updatePreviewForSelection() {
        guard let item = selectedItem, !documentLines.isEmpty else {
            previewContext = nil
            return
        }
        previewContext = ReferencesPickerModel.extractContext(
            fileURL: documentURL,
            displayPath: displayPath,
            lines: documentLines,
            spans: documentSpans,
            language: documentLanguage,
            lineNumber: item.lineNumber,
            column: item.column,
            endColumn: item.endColumn,
            symbolName: item.name,
            linesBefore: Self.previewLinesBefore,
            linesAfter: Self.previewLinesAfter
        )
    }

    // MARK: - Pure Filtering & Selection Helpers

    /// Returns the index of the symbol at or just above `cursorLine` (1-based), defaulting to `0`.
    nonisolated static func nearestSymbolIndex(in items: [FileSymbolItem], cursorLine: Int) -> Int {
        guard !items.isEmpty else { return 0 }
        var best = 0
        for (index, item) in items.enumerated() {
            if item.lineNumber <= cursorLine {
                best = index
            } else {
                break
            }
        }
        return best
    }

    private func rebuildFiltered(preserveSelectionIfEmptyQuery: Bool) {
        let previousID = selectedItem?.id
        let kindFiltered = allItems.filter { kindFilter.matches($0.kind) }
        let trimmed = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            filteredItems = kindFiltered
            matchPositions = [:]
            if preserveSelectionIfEmptyQuery,
               let previousID,
               let idx = kindFiltered.firstIndex(where: { $0.id == previousID }) {
                selectedIndex = idx
            } else {
                selectedIndex = Self.nearestSymbolIndex(in: kindFiltered, cursorLine: cursorLineWhenOpened)
            }
            updatePreviewForSelection()
            return
        }

        let queryBytes = Array(trimmed.lowercased().utf8).filter { $0 != 32 }
        guard !queryBytes.isEmpty else {
            filteredItems = kindFiltered
            matchPositions = [:]
            selectedIndex = 0
            updatePreviewForSelection()
            return
        }

        var scored: [(item: FileSymbolItem, score: Int, namePositions: [Int])] = []
        scored.reserveCapacity(kindFiltered.count)

        for item in kindFiltered {
            if let direct = Fuzzy.match(query: queryBytes, candidate: item.name, wantPositions: true) {
                scored.append((item, direct.score + 500, direct.positions))
                continue
            }

            guard !item.detail.isEmpty else { continue }
            // Replace `/` with space (1-to-1 UTF-8 byte length) so Fuzzy.match treats detail + name uniformly.
            let safeDetail = item.detail.replacingOccurrences(of: "/", with: " ")
            let detailFirst = "\(safeDetail) \(item.name)"
            let nameFirst = "\(item.name) \(safeDetail)"

            let m1 = Fuzzy.match(query: queryBytes, candidate: detailFirst, wantPositions: true)
            let m2 = Fuzzy.match(query: queryBytes, candidate: nameFirst, wantPositions: true)

            if let m1, (m2 == nil || m1.score >= m2!.score) {
                let nameOffset = safeDetail.utf8.count + 1
                let namePos = m1.positions.compactMap { pos -> Int? in
                    let local = pos - nameOffset
                    return local >= 0 && local < item.name.utf8.count ? local : nil
                }
                scored.append((item, m1.score, namePos))
            } else if let m2 {
                let nameLen = item.name.utf8.count
                let namePos = m2.positions.filter { $0 >= 0 && $0 < nameLen }
                scored.append((item, m2.score, namePos))
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.lineNumber < rhs.item.lineNumber
        }

        filteredItems = scored.map(\.item)
        var positionsMap: [String: [Int]] = [:]
        positionsMap.reserveCapacity(scored.count)
        for entry in scored where !entry.namePositions.isEmpty {
            positionsMap[entry.item.id] = entry.namePositions
        }
        matchPositions = positionsMap
        selectedIndex = 0
        updatePreviewForSelection()
    }
}
