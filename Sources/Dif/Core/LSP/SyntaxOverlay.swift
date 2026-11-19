import Foundation

/// Pure overlay merger combining immediate Lexer `SyntaxSpan`s with async LSP `LSPSemanticSpan`s.
enum SyntaxOverlay {
    /// Converts a single LSP semantic span into a `SyntaxSpan` using the 1:1 raw-value mapping.
    static func convert(_ span: LSPSemanticSpan) -> SyntaxSpan {
        SyntaxSpan(
            start: span.start,
            length: span.length,
            kind: TokenKind(rawValue: span.kind.rawValue) ?? .plain
        )
    }

    /// Merges per-line LSP semantic spans over base Lexer spans.
    ///
    /// When `lineText` is supplied, refines Go/LSP semantic tokens using identifier casing, modifiers,
    /// and local punctuation context (distinguishing exported vs unexported functions, constants,
    /// variables, types, struct fields, and builtin types vs builtin functions).
    ///
    /// Guarantees:
    /// - Preserves Lexer spans in regions not covered by LSP (keywords, punctuation, strings, comments).
    /// - Protects base `.comment` and `.string` spans from being corrupted by non-comment/non-string LSP spans.
    /// - Cleanly splits or replaces overlapping base spans with semantic spans.
    /// - Output is strictly sorted by `start` and non-overlapping.
    static func merge(
        base: [SyntaxSpan],
        semantic: [LSPSemanticSpan],
        lineText: String? = nil,
        goReceiver: String? = nil
    ) -> [SyntaxSpan] {
        guard !semantic.isEmpty else { return normalize(base) }
        let utf16: [UInt16]? = lineText.map { Array($0.utf16) }
        let converted = semantic.compactMap { span -> SyntaxSpan? in
            guard span.start >= 0, span.length > 0 else { return nil }
            let syntax: SyntaxSpan
            if let units = utf16 {
                let kind = refineKind(span, utf16: units, base: base, semantic: semantic, goReceiver: goReceiver)
                syntax = SyntaxSpan(start: span.start, length: span.length, kind: kind)
            } else {
                syntax = convert(span)
            }
            guard syntax.kind != .plain else { return nil }
            return syntax
        }
        return merge(base: base, semanticSpans: converted)
    }

    /// Extracts the Go method receiver parameter name from a top-level `func (m *Type) Name(` line, if any.
    static func goMethodReceiverName(in line: String) -> String? {
        guard line.hasPrefix("func (") || line.hasPrefix("func(") else { return nil }
        guard let open = line.firstIndex(of: "("),
              let close = line[line.index(after: open)...].firstIndex(of: ")") else { return nil }
        let afterClose = line[line.index(after: close)...].drop(while: { $0 == " " || $0 == "\t" })
        guard let firstAfter = afterClose.first, firstAfter.isLetter || firstAfter == "_" else { return nil }
        let inside = line[line.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let parts = inside.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count >= 2 else { return nil }
        let candidate = String(parts[0])
        guard let c0 = candidate.first, c0.isLetter || c0 == "_",
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return candidate
    }

    // MARK: - Semantic Refinement

    private static func refineKind(
        _ span: LSPSemanticSpan,
        utf16: [UInt16],
        base: [SyntaxSpan],
        semantic: [LSPSemanticSpan],
        goReceiver: String?
    ) -> TokenKind {
        let start = Int(span.start)
        let end = start + Int(span.length)
        guard start >= 0, end <= utf16.count, start < end else {
            return convert(span).kind
        }
        let token = String(decoding: utf16[start..<end], as: UTF16.self)
        let isExported = token.first?.isUppercase == true
        let mods = span.modifiers

        switch span.kind {
        case .function, .method:
            if mods.contains(.defaultLibrary) { return .builtin }
            if isExported { return .exportedFunction }
            return span.kind == .method ? .method : .function

        case .builtin:
            if LanguageSpec.go.builtinTypeKeywords.contains(token) { return .builtinType }
            if LanguageSpec.go.constantKeywords.contains(token) { return .constant }
            return .builtin

        case .constant:
            if mods.contains(.defaultLibrary) || LanguageSpec.go.constantKeywords.contains(token) {
                return .constant
            }
            return isExported ? .exportedConstant : .constant

        case .type:
            if mods.contains(.defaultLibrary) { return .builtinType }
            if mods.contains(.interface) { return .interface }
            return isExported ? .exportedType : .type

        case .interface:
            return mods.contains(.defaultLibrary) ? .builtinType : .interface

        case .parameter:
            return .parameter

        case .property:
            return isExported ? .exportedProperty : .property

        case .variable:
            if mods.contains(.readonly) {
                if mods.contains(.defaultLibrary) || LanguageSpec.go.constantKeywords.contains(token) {
                    return .constant
                }
                return isExported ? .exportedConstant : .constant
            }
            if mods.contains(.defaultLibrary) {
                return LanguageSpec.go.constantKeywords.contains(token) ? .constant : .builtin
            }
            // Preserve Go method receiver parameter highlighted by the static lexer (`func (m *T)`),
            // since gopls emits method receivers as `variable`.
            if base.contains(where: { $0.start == span.start && $0.length == span.length && $0.kind == .parameter }) {
                return .parameter
            }
            // Member access (`obj.Field` / `obj.field` vs `pkg.ExportedVar`):
            if let dotIndex = prevNonSpaceIndex(in: utf16, before: start), utf16[dotIndex] == 0x2E {
                if isPrecededByNamespace(dotIndex: dotIndex, utf16: utf16, semantic: semantic) {
                    return isExported ? .exportedVariable : .variable
                }
                return isExported ? .exportedProperty : .property
            }
            // Struct literal field key (`Channel: value`, `lock: 1`, excluding `:=`):
            if let colonIndex = nextNonSpaceIndex(in: utf16, from: end),
               utf16[colonIndex] == 0x3A,
               (colonIndex + 1 >= utf16.count || utf16[colonIndex + 1] != 0x3D) {
                if isStructLiteralKeyContext(in: utf16, before: start) {
                    return isExported ? .exportedProperty : .property
                }
            }
            // Struct field declaration (`    RoomId int64`, `    lock sync.Mutex`):
            if mods.contains(.definition),
               isStructFieldDeclContext(in: utf16, before: start, after: end) {
                return isExported ? .exportedProperty : .property
            }
            // Active Go method receiver referenced inside the method body (`m.lock.Lock()`, `m.state.Signups`):
            if let recv = goReceiver, !mods.contains(.definition), token == recv {
                return .parameter
            }
            return isExported ? .exportedVariable : .variable

        default:
            return convert(span).kind
        }
    }

    @inline(__always)
    private static func isUTF16Space(_ u: UInt16) -> Bool { u == 0x20 || u == 0x09 }

    private static func prevNonSpaceIndex(in utf16: [UInt16], before index: Int) -> Int? {
        var i = index - 1
        while i >= 0 {
            if !isUTF16Space(utf16[i]) { return i }
            i -= 1
        }
        return nil
    }

    private static func nextNonSpaceIndex(in utf16: [UInt16], from index: Int) -> Int? {
        var i = index
        while i < utf16.count {
            if !isUTF16Space(utf16[i]) { return i }
            i += 1
        }
        return nil
    }

    private static func isPrecededByNamespace(dotIndex: Int, utf16: [UInt16], semantic: [LSPSemanticSpan]) -> Bool {
        guard let prevEnd = prevNonSpaceIndex(in: utf16, before: dotIndex) else { return false }
        let targetEnd = Int32(prevEnd + 1)
        return semantic.contains { $0.kind == .namespace && ($0.start + $0.length) == targetEnd }
    }

    /// True when `ident:` appears at the start of an indented line or right after `{` or `,`
    /// (struct literal field keys like `Channel: ...`), excluding `case X:` or top-level labels.
    private static func isStructLiteralKeyContext(in utf16: [UInt16], before start: Int) -> Bool {
        if let prev = prevNonSpaceIndex(in: utf16, before: start) {
            let u = utf16[prev]
            return u == 0x7B || u == 0x2C // `{` or `,`
        }
        // Only whitespace before `start` — indented inside a struct literal (not column-0 label).
        return start > 0
    }

    /// True when a `definition` variable sits alone after leading indentation and is followed by a Go type
    /// with no `=` assignment on the line (i.e. a struct field declaration like `    RoomId int64`).
    private static func isStructFieldDeclContext(in utf16: [UInt16], before start: Int, after end: Int) -> Bool {
        guard start > 0, prevNonSpaceIndex(in: utf16, before: start) == nil else { return false }
        guard let next = nextNonSpaceIndex(in: utf16, from: end) else { return false }
        let u = utf16[next]
        // Assignment (`=`, `:=`), comma, closing delim, or operator means it's a var/const/expr, not a field decl.
        if u == 0x3D || u == 0x3A || u == 0x2C || u == 0x29 || u == 0x7D || u == 0x3B { return false }
        // Confirm no `=` appears later on the line (outside backtick tags/strings).
        var j = next
        while j < utf16.count {
            let c = utf16[j]
            if c == 0x60 || c == 0x22 || c == 0x2F { break } // struct tag, string, or comment
            if c == 0x3D { return false }
            j += 1
        }
        return true
    }

    /// Merges already-converted semantic `SyntaxSpan`s over base Lexer spans.
    static func merge(base: [SyntaxSpan], semanticSpans: [SyntaxSpan]) -> [SyntaxSpan] {
        let cleanBase = normalize(base)
        guard !semanticSpans.isEmpty else { return cleanBase }

        // 1. Collect base `.comment` and `.string` intervals so LSP never corrupts comments or strings.
        let protected: [(start: Int32, end: Int32)] = cleanBase.compactMap { span in
            guard span.kind == .comment || span.kind == .string else { return nil }
            return (span.start, span.start + span.length)
        }

        // 2. Clip semantic spans against protected base strings/comments (unless the semantic span itself
        //    is also a string/comment) and ensure semantic spans are sorted and pairwise disjoint.
        let sortedSemantic = semanticSpans
            .filter { $0.start >= 0 && $0.length > 0 && $0.kind != .plain }
            .sorted { a, b in
                if a.start != b.start { return a.start < b.start }
                return a.length < b.length
            }

        var clippedSemantic: [SyntaxSpan] = []
        clippedSemantic.reserveCapacity(sortedSemantic.count)
        for span in sortedSemantic {
            if span.kind == .comment || span.kind == .string || protected.isEmpty {
                clippedSemantic.append(span)
            } else {
                subtract(intervals: protected, from: span, into: &clippedSemantic)
            }
        }

        let disjointSemantic = normalize(clippedSemantic)
        guard !disjointSemantic.isEmpty else { return cleanBase }

        // 3. Subtract all surviving semantic intervals from base spans, splitting partial overlaps cleanly.
        let semanticIntervals = disjointSemantic.map { ($0.start, $0.start + $0.length) }
        var result: [SyntaxSpan] = []
        result.reserveCapacity(cleanBase.count + disjointSemantic.count)
        for span in cleanBase {
            subtract(intervals: semanticIntervals, from: span, into: &result)
        }
        result.append(contentsOf: disjointSemantic)

        // 4. Sort by start (already non-overlapping by construction).
        result.sort { $0.start < $1.start }
        return result
    }

    // MARK: - Helpers

    /// Filters invalid spans, sorts by `start`, and trims any accidental overlaps so spans are strictly disjoint.
    private static func normalize(_ spans: [SyntaxSpan]) -> [SyntaxSpan] {
        let valid = spans.filter { $0.start >= 0 && $0.length > 0 }
        guard valid.count > 1 else { return valid }
        let sorted = valid.sorted { a, b in
            if a.start != b.start { return a.start < b.start }
            return a.length < b.length
        }
        var out: [SyntaxSpan] = []
        out.reserveCapacity(sorted.count)
        var cursor: Int32 = 0
        for span in sorted {
            let end = span.start + span.length
            let start = max(span.start, cursor)
            if end > start {
                out.append(SyntaxSpan(start: start, length: end - start, kind: span.kind))
                cursor = end
            }
        }
        return out
    }

    /// Appends the sub-spans of `span` that lie outside every sorted, disjoint interval in `intervals`.
    private static func subtract(
        intervals: [(start: Int32, end: Int32)],
        from span: SyntaxSpan,
        into out: inout [SyntaxSpan]
    ) {
        var cursor = span.start
        let spanEnd = span.start + span.length
        for interval in intervals {
            if interval.end <= cursor { continue }
            if interval.start >= spanEnd { break }
            if interval.start > cursor {
                out.append(SyntaxSpan(start: cursor, length: interval.start - cursor, kind: span.kind))
            }
            cursor = max(cursor, interval.end)
            if cursor >= spanEnd { break }
        }
        if cursor < spanEnd {
            out.append(SyntaxSpan(start: cursor, length: spanEnd - cursor, kind: span.kind))
        }
    }
}
