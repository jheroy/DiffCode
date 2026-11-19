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
    /// Guarantees:
    /// - Preserves Lexer spans in regions not covered by LSP (keywords, punctuation, strings, comments).
    /// - Protects base `.comment` and `.string` spans from being corrupted by non-comment/non-string LSP spans.
    /// - Cleanly splits or replaces overlapping base spans with semantic spans.
    /// - Output is strictly sorted by `start` and non-overlapping.
    static func merge(base: [SyntaxSpan], semantic: [LSPSemanticSpan]) -> [SyntaxSpan] {
        guard !semantic.isEmpty else { return normalize(base) }
        let converted = semantic.compactMap { span -> SyntaxSpan? in
            guard span.start >= 0, span.length > 0 else { return nil }
            let syntax = convert(span)
            guard syntax.kind != .plain else { return nil }
            return syntax
        }
        return merge(base: base, semanticSpans: converted)
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
