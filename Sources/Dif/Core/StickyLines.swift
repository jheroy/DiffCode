import CoreGraphics
import Foundation

/// A structural block scope extracted from a single text buffer (0-based inclusive lines).
struct StickyScope: Equatable, Sendable {
    var startLine: Int
    var endLine: Int
    var kind: FileSymbolKind
    var depth: Int
}

/// A scope mapped into a pane's display row coordinate space (accounting for unified rows and diff folds).
struct StickyDisplayScope: Equatable, Sendable {
    var headerRow: Int
    var endRow: Int
    var sourceSide: Side
    var sourceLine: Int
}

/// One sticky header line currently pinned at the top of a pane.
struct StickyLineSlot: Equatable, Sendable {
    let slotIndex: Int
    let scope: StickyDisplayScope
    /// Y coordinate relative to the top of the viewport (0 = flush at top; negative while pushing up).
    let y: CGFloat
}

/// Resolved sticky header stack and total overlay height for one pane at a given scroll offset.
struct StickyLayoutResult: Equatable, Sendable {
    let slots: [StickyLineSlot]
    let height: CGFloat

    static let empty = StickyLayoutResult(slots: [], height: 0)
}

/// Pure, thread-safe engine that extracts nested declaration scopes and computes GoLand-style
/// sticky header pinning, push-out physics, and live-edit range shifting.
enum StickyLinesEngine {
    static let defaultMaxLines = 5
    static let maxSupportedLineCount = 30_000

    private static let swiftModifiers: Set<String> = [
        "public", "private", "fileprivate", "internal", "open", "package",
        "final", "static", "override", "mutating", "nonmutating",
        "nonisolated", "isolated", "indirect", "convenience", "required",
        "lazy", "weak", "unowned", "optional", "prefix", "postfix", "infix",
        "async", "borrowing", "consuming", "dynamic", "distributed",
    ]

    private static let jsMethodModifiers: Set<String> = [
        "public", "private", "protected", "static", "readonly", "override",
        "abstract", "async", "get", "set", "declare",
    ]

    private static let jsNonMethodKeywords: Set<String> = [
        "if", "for", "while", "switch", "catch", "with", "return", "throw",
        "new", "typeof", "delete", "void", "await", "yield", "else", "try",
        "finally", "do", "case", "default", "function", "class", "interface",
        "enum", "type", "const", "let", "var", "import", "export", "super", "this",
    ]

    private static let cNonMethodKeywords: Set<String> = [
        "if", "for", "while", "switch", "catch", "return", "sizeof", "decltype",
        "alignof", "static_assert", "typedef", "using", "namespace", "struct",
        "class", "enum", "union", "else", "do", "try", "template", "case",
        "goto", "delete", "new", "throw", "co_await", "co_return", "co_yield",
    ]

    private static let shapeNonMethodKeywords: Set<String> = [
        "if", "for", "while", "switch", "catch", "synchronized", "using", "lock",
        "fixed", "foreach", "return", "throw", "new", "super", "this", "else",
        "do", "try", "case", "default", "when", "assert", "yield", "await",
        "sizeof", "typeof", "nameof", "checked", "unchecked", "fixed",
    ]

    // MARK: - Scope Extraction

    /// Extracts strictly nested, non-overlapping block scopes suitable for sticky pinning.
    static func extractScopes(lines: [String], language: LanguageSpec) -> [StickyScope] {
        guard !lines.isEmpty, lines.count <= maxSupportedLineCount, language.family != .plain else {
            return []
        }

        let baseSymbols = FileSymbolExtractor.extract(lines: lines, language: language)
        let extraSymbols = extractSupplementaryScopes(lines: lines, language: language)

        var candidates: [(startLine: Int, endLine: Int, kind: FileSymbolKind)] = []
        candidates.reserveCapacity(baseSymbols.count + extraSymbols.count)

        for sym in baseSymbols where sym.kind != .constant {
            guard let endLine1 = sym.endLine else { continue }
            let start = sym.lineNumber - 1
            let end = endLine1 - 1
            // A scope needs >= 3 lines (end >= start + 2) so at least 1 body line exists below the header.
            if start >= 0, end < lines.count, end >= start + 2 {
                candidates.append((start, end, sym.kind))
            }
        }
        for sym in extraSymbols where sym.kind != .constant {
            guard let endLine1 = sym.endLine else { continue }
            let start = sym.lineNumber - 1
            let end = endLine1 - 1
            if start >= 0, end < lines.count, end >= start + 2 {
                candidates.append((start, end, sym.kind))
            }
        }

        guard !candidates.isEmpty else { return [] }

        candidates.sort { lhs, rhs in
            if lhs.startLine != rhs.startLine { return lhs.startLine < rhs.startLine }
            return lhs.endLine > rhs.endLine
        }

        // Deduplicate multiple symbols starting on the same line, keeping the widest block.
        var deduped: [(startLine: Int, endLine: Int, kind: FileSymbolKind)] = []
        deduped.reserveCapacity(candidates.count)
        for item in candidates {
            if let last = deduped.last, last.startLine == item.startLine { continue }
            deduped.append(item)
        }

        // Normalize into a strictly nested laminar forest.
        var scopes: [StickyScope] = []
        scopes.reserveCapacity(deduped.count)
        var stack: [StickyScope] = []

        for item in deduped {
            while let top = stack.last, item.startLine >= top.endLine {
                stack.removeLast()
            }
            let clampedEnd = stack.last.map { min(item.endLine, $0.endLine) } ?? item.endLine
            guard clampedEnd >= item.startLine + 2 else { continue }
            let scope = StickyScope(
                startLine: item.startLine,
                endLine: clampedEnd,
                kind: item.kind,
                depth: stack.count
            )
            scopes.append(scope)
            stack.append(scope)
        }

        return scopes
    }

    // MARK: - Supplementary Block Scopes

    private static func extractSupplementaryScopes(lines: [String], language: LanguageSpec) -> [FileSymbolItem] {
        switch language.name {
        case "Swift":
            return extractSwiftExtra(lines: lines)
        case "Rust":
            return extractRustExtra(lines: lines)
        case "JavaScript":
            return extractJavaScriptExtra(lines: lines)
        case "C/C++":
            return extractCFamilyExtra(lines: lines)
        default:
            if language.declByShape {
                return extractShapeMethodsExtra(lines: lines, language: language)
            }
            return []
        }
    }

    private static func extractSwiftExtra(lines: [String]) -> [FileSymbolItem] {
        let config = FileSymbolExtractor.ScannerConfig(
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
        let scanned = FileSymbolExtractor.scan(lines: lines, config: config)
        var items: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }
            var idx = 0
            while idx < tokens.count {
                let text = tokens[idx].text
                if text == "@" {
                    idx += 1
                    if idx < tokens.count { idx += 1 }
                    if idx < tokens.count, tokens[idx].text == "(",
                       let close = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: idx, open: "(", close: ")") {
                        idx = close + 1
                    }
                    continue
                }
                if text == "nonisolated", idx + 1 < tokens.count, tokens[idx + 1].text == "(",
                   let close = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: idx + 1, open: "(", close: ")") {
                    idx = close + 1
                    continue
                }
                if swiftModifiers.contains(text) {
                    idx += 1
                    continue
                }
                break
            }
            guard idx < tokens.count else { continue }
            let kw = tokens[idx]
            switch kw.text {
            case "init", "deinit", "subscript":
                if kw.text == "init" {
                    let next = idx + 1
                    guard next < tokens.count else { continue }
                    let nt = tokens[next].text
                    guard nt == "(" || nt == "?" || nt == "!" || nt == "<" else { continue }
                } else if kw.text == "deinit" {
                    guard line.tokens.contains(where: { $0.text == "{" }) || line.endBraceDepth > line.startBraceDepth else { continue }
                } else if kw.text == "subscript" {
                    let next = idx + 1
                    guard next < tokens.count, tokens[next].text == "(" || tokens[next].text == "<" else { continue }
                }
                items.append(FileSymbolItem(
                    id: "sticky:\(line.lineNumber):\(kw.start):\(kw.text)",
                    name: kw.text,
                    detail: "",
                    kind: .method,
                    lineNumber: line.lineNumber,
                    column: kw.start,
                    endColumn: kw.end,
                    isExported: true
                ))
            default:
                break
            }
        }
        return FileSymbolExtractor.attachBraceEndLines(items, scanned: scanned)
    }

    private static func extractRustExtra(lines: [String]) -> [FileSymbolItem] {
        let config = FileSymbolExtractor.ScannerConfig(
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
        let scanned = FileSymbolExtractor.scan(lines: lines, config: config)
        var items: [FileSymbolItem] = []

        for line in scanned {
            let tokens = line.tokens
            guard !tokens.isEmpty else { continue }
            var idx = 0
            while idx < tokens.count {
                let text = tokens[idx].text
                if text == "pub" {
                    idx += 1
                    if idx < tokens.count, tokens[idx].text == "(",
                       let close = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: idx, open: "(", close: ")") {
                        idx = close + 1
                    }
                    continue
                }
                if text == "unsafe" {
                    idx += 1
                    continue
                }
                break
            }
            guard idx + 1 < tokens.count, tokens[idx].text == "mod", tokens[idx + 1].isIdentifier else { continue }
            let isForwardDecl = tokens.last?.text == ";" && !tokens.contains(where: { $0.text == "{" })
            guard !isForwardDecl else { continue }
            let nameTok = tokens[idx + 1]
            items.append(FileSymbolItem(
                id: "sticky:\(line.lineNumber):\(nameTok.start):mod:\(nameTok.text)",
                name: nameTok.text,
                detail: "mod",
                kind: .type,
                lineNumber: line.lineNumber,
                column: nameTok.start,
                endColumn: nameTok.end,
                isExported: true
            ))
        }
        return FileSymbolExtractor.attachBraceEndLines(items, scanned: scanned)
    }

    private static func extractJavaScriptExtra(lines: [String]) -> [FileSymbolItem] {
        let config = FileSymbolExtractor.ScannerConfig(
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
        let scanned = FileSymbolExtractor.scan(lines: lines, config: config)
        var items: [FileSymbolItem] = []

        for lineIdx in scanned.indices {
            let line = scanned[lineIdx]
            let tokens = line.tokens
            guard line.startBraceDepth > 0, !tokens.isEmpty else { continue }

            var idx = 0
            while idx < tokens.count, jsMethodModifiers.contains(tokens[idx].text) {
                idx += 1
            }
            if idx < tokens.count, tokens[idx].text == "*" {
                idx += 1
            }
            guard idx + 1 < tokens.count else { continue }
            let nameTok = tokens[idx]
            guard nameTok.isIdentifier, !jsNonMethodKeywords.contains(nameTok.text) else { continue }

            var cursor = idx + 1
            if cursor < tokens.count, tokens[cursor].text == "<",
               let closeAngle = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: cursor, open: "<", close: ">") {
                cursor = closeAngle + 1
            }
            guard cursor < tokens.count, tokens[cursor].text == "(" else { continue }

            if opensMethodBodyAfterParen(tokens: tokens, openParenIdx: cursor, scanned: scanned, lineIdx: lineIdx) {
                items.append(FileSymbolItem(
                    id: "sticky:\(line.lineNumber):\(nameTok.start):method:\(nameTok.text)",
                    name: nameTok.text,
                    detail: "",
                    kind: .method,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: true
                ))
            }
        }
        return FileSymbolExtractor.attachBraceEndLines(items, scanned: scanned)
    }

    private static func extractCFamilyExtra(lines: [String]) -> [FileSymbolItem] {
        let config = FileSymbolExtractor.ScannerConfig(
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
        let scanned = FileSymbolExtractor.scan(lines: lines, config: config)
        var items: [FileSymbolItem] = []

        for lineIdx in scanned.indices {
            let line = scanned[lineIdx]
            let tokens = line.tokens
            guard !tokens.isEmpty, tokens[0].text != "#" else { continue }

            if tokens[0].text == "namespace", tokens.count >= 2, tokens[1].isIdentifier {
                let isAliasOrDirective = tokens.contains(where: { $0.text == ";" || $0.text == "=" })
                    && !tokens.contains(where: { $0.text == "{" })
                if !isAliasOrDirective {
                    let nameTok = tokens[1]
                    items.append(FileSymbolItem(
                        id: "sticky:\(line.lineNumber):\(nameTok.start):ns:\(nameTok.text)",
                        name: nameTok.text,
                        detail: "namespace",
                        kind: .type,
                        lineNumber: line.lineNumber,
                        column: nameTok.start,
                        endColumn: nameTok.end,
                        isExported: true
                    ))
                    continue
                }
            }

            // Inline class/struct methods & constructors at braceDepth > 0.
            guard line.startBraceDepth > 0 else { continue }
            guard !cNonMethodKeywords.contains(tokens[0].text) else { continue }
            guard let openParen = tokens.firstIndex(where: { $0.text == "(" }), openParen >= 1 else { continue }
            let nameTok = tokens[openParen - 1]
            guard nameTok.isIdentifier, !cNonMethodKeywords.contains(nameTok.text) else { continue }
            if tokens[..<openParen].contains(where: { $0.text == "=" || $0.text == "." || $0.text == "->" }) {
                continue
            }
            if opensMethodBodyAfterParen(tokens: tokens, openParenIdx: openParen, scanned: scanned, lineIdx: lineIdx) {
                items.append(FileSymbolItem(
                    id: "sticky:\(line.lineNumber):\(nameTok.start):method:\(nameTok.text)",
                    name: nameTok.text,
                    detail: "",
                    kind: .method,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: true
                ))
            }
        }
        return FileSymbolExtractor.attachBraceEndLines(items, scanned: scanned)
    }

    private static func extractShapeMethodsExtra(lines: [String], language: LanguageSpec) -> [FileSymbolItem] {
        let config = FileSymbolExtractor.ScannerConfig(
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
        let scanned = FileSymbolExtractor.scan(lines: lines, config: config)
        var items: [FileSymbolItem] = []

        for lineIdx in scanned.indices {
            let line = scanned[lineIdx]
            let tokens = line.tokens
            guard line.startBraceDepth > 0, !tokens.isEmpty else { continue }

            var start = 0
            while start < tokens.count {
                let t = tokens[start].text
                if t == "@" {
                    start += 1
                    if start < tokens.count { start += 1 }
                    if start < tokens.count, tokens[start].text == "(",
                       let close = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: start, open: "(", close: ")") {
                        start = close + 1
                    }
                    continue
                }
                if t == "[",
                   let close = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: start, open: "[", close: "]") {
                    start = close + 1
                    continue
                }
                break
            }
            guard start < tokens.count else { continue }
            guard !shapeNonMethodKeywords.contains(tokens[start].text) else { continue }
            guard let openParen = tokens[start...].firstIndex(where: { $0.text == "(" }), openParen > start else { continue }
            let nameTok = tokens[openParen - 1]
            guard nameTok.isIdentifier, !shapeNonMethodKeywords.contains(nameTok.text) else { continue }
            if tokens[start..<openParen].contains(where: { $0.text == "=" || $0.text == "." || $0.text == "->" || $0.text == ";" }) {
                continue
            }
            if opensMethodBodyAfterParen(tokens: tokens, openParenIdx: openParen, scanned: scanned, lineIdx: lineIdx) {
                items.append(FileSymbolItem(
                    id: "sticky:\(line.lineNumber):\(nameTok.start):method:\(nameTok.text)",
                    name: nameTok.text,
                    detail: "",
                    kind: .method,
                    lineNumber: line.lineNumber,
                    column: nameTok.start,
                    endColumn: nameTok.end,
                    isExported: true
                ))
            }
        }
        return FileSymbolExtractor.attachBraceEndLines(items, scanned: scanned)
    }

    /// Returns true if a parameter list starting at `openParenIdx` closes and opens a `{` block body
    /// (without hitting `;` or `=>` or an assignment `=` before `{`), distinguishing method definitions from calls.
    private static func opensMethodBodyAfterParen(
        tokens: [FileSymbolExtractor.Token],
        openParenIdx: Int,
        scanned: [FileSymbolExtractor.ScannedLine],
        lineIdx: Int
    ) -> Bool {
        let startLine = scanned[lineIdx]
        if let closeParen = FileSymbolExtractor.matchingClose(tokens: tokens, openIndex: openParenIdx, open: "(", close: ")") {
            for t in tokens[(closeParen + 1)...] {
                if t.text == ";" || t.text == "=>" { return false }
                if t.text == "{" { return true }
            }
            if lineIdx + 1 < scanned.count {
                let nextTokens = scanned[lineIdx + 1].tokens
                if nextTokens.first?.text == "{" { return true }
                if let colon = nextTokens.first?.text, (colon == ":" || colon == "throws" || colon == "where") && nextTokens.contains(where: { $0.text == "{" }) {
                    return true
                }
            }
            return false
        }

        // Multi-line parameter list: advance until paren depth drops back to `startLine.startParenDepth`.
        let limit = min(scanned.count, lineIdx + 16)
        var k = lineIdx + 1
        while k < limit {
            let cur = scanned[k]
            if cur.endBraceDepth < startLine.startBraceDepth { return false }
            if cur.tokens.contains(where: { $0.text == ";" || $0.text == "=>" }) && cur.endParenDepth <= startLine.startParenDepth {
                return false
            }
            if cur.endParenDepth <= startLine.startParenDepth {
                if cur.tokens.contains(where: { $0.text == "{" }) { return true }
                if k + 1 < scanned.count, scanned[k + 1].tokens.first?.text == "{" { return true }
                return false
            }
            k += 1
        }
        return false
    }

    // MARK: - Live Edit Shifting

    /// Synchronously shifts cached scopes across a line edit before the debounced re-extraction runs.
    static func shiftScopes(_ scopes: [StickyScope], by edit: LineEdit) -> [StickyScope] {
        let delta = edit.inserted - edit.removed
        guard delta != 0, !scopes.isEmpty else { return scopes }
        let editEnd = edit.start + edit.removed
        var shifted: [StickyScope] = []
        shifted.reserveCapacity(scopes.count)

        for scope in scopes {
            if scope.endLine < edit.start {
                shifted.append(scope)
            } else if scope.startLine >= editEnd {
                let start = scope.startLine + delta
                let end = scope.endLine + delta
                if end >= start + 2 {
                    shifted.append(StickyScope(startLine: start, endLine: end, kind: scope.kind, depth: scope.depth))
                }
            } else if scope.startLine >= edit.start {
                // Header fell inside the deleted span; drop until debounced re-extract rebuilds it.
                continue
            } else {
                let end = max(scope.startLine, scope.endLine + delta)
                if end >= scope.startLine + 2 {
                    shifted.append(StickyScope(startLine: scope.startLine, endLine: end, kind: scope.kind, depth: scope.depth))
                }
            }
        }
        return shifted
    }

    // MARK: - Scroll Layout Resolution

    /// Resolves which scopes are pinned at the top of the viewport and their Y coordinates.
    ///
    /// - Parameters:
    ///   - scopes: Display scopes sorted by `headerRow` ascending (and widest `endRow` first).
    ///   - scrollTop: Current pane top scroll offset in points.
    ///   - lineHeight: Single row height in points.
    ///   - viewportHeight: Visible pane height in points.
    ///   - maxLines: User-configured maximum number of sticky lines.
    static func resolve(
        scopes: [StickyDisplayScope],
        scrollTop: CGFloat,
        lineHeight: CGFloat,
        viewportHeight: CGFloat,
        maxLines: Int
    ) -> StickyLayoutResult {
        guard scrollTop > 0, lineHeight > 0, viewportHeight > 0, maxLines > 0, !scopes.isEmpty else {
            return .empty
        }
        let limit = min(maxLines, Int(floor(viewportHeight / lineHeight)) / 3)
        guard limit > 0 else { return .empty }

        var slots: [StickyLineSlot] = []
        slots.reserveCapacity(limit)
        var parentScope: StickyDisplayScope?
        var searchStart = 0

        for k in 0..<limit {
            let slotTopY = scrollTop + CGFloat(k) * lineHeight
            var matched: (index: Int, scope: StickyDisplayScope)?

            var idx = searchStart
            while idx < scopes.count {
                let candidate = scopes[idx]
                if CGFloat(candidate.headerRow) * lineHeight >= slotTopY - 0.001 {
                    break
                }
                if let parent = parentScope {
                    if candidate.headerRow >= parent.endRow {
                        break
                    }
                    if candidate.headerRow <= parent.headerRow {
                        idx += 1
                        continue
                    }
                }
                let effectiveEndRow = parentScope.map { min(candidate.endRow, $0.endRow) } ?? candidate.endRow
                if effectiveEndRow >= candidate.headerRow + 2 && CGFloat(effectiveEndRow) * lineHeight > slotTopY + 0.001 {
                    let clamped = StickyDisplayScope(
                        headerRow: candidate.headerRow,
                        endRow: effectiveEndRow,
                        sourceSide: candidate.sourceSide,
                        sourceLine: candidate.sourceLine
                    )
                    matched = (idx, clamped)
                    break
                }
                idx += 1
            }

            guard let match = matched else { break }

            let nominalY = CGFloat(k) * lineHeight
            let endScreenY = CGFloat(match.scope.endRow) * lineHeight - scrollTop
            let y = min(nominalY, endScreenY - lineHeight)
            slots.append(StickyLineSlot(slotIndex: k, scope: match.scope, y: y))
            parentScope = match.scope
            searchStart = match.index + 1
        }

        guard let last = slots.last else { return .empty }
        let height = max(0, last.y + lineHeight)
        return StickyLayoutResult(slots: slots, height: height)
    }
}
