import AppKit
import SwiftUI

/// One side's line data inside `LineDiffSnapshot`.
struct LineDiffRow: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unchanged
        case removed
        case added
        case modified
        case moved
        case empty
    }

    /// 1-based line number, or `nil` when this side has no corresponding line.
    var lineNumber: Int?
    var text: String
    var syntaxSpans: [SyntaxSpan]
    /// UTF-16 ranges of changed words/characters on this line.
    var highlightRanges: [Range<Int>]
    var kind: Kind

    static let empty = LineDiffRow(lineNumber: nil, text: "", syntaxSpans: [], highlightRanges: [], kind: .empty)
}

/// Metadata describing a moved code block when the active line belongs to a hunk paired by move detection.
struct LineDiffMoveContext: Equatable, Sendable {
    var hunkIndex: Int
    var counterpartHunkIndex: Int
    var role: MoveRole
    var similarity: Double
    var hasInlineEdits: Bool
}

/// Paired Left (Old) / Right (New) snapshot of a single selected line for the bottom inline diff bar.
struct LineDiffSnapshot: Equatable, Sendable {
    var left: LineDiffRow
    var right: LineDiffRow
    var language: LanguageSpec
    var hunkKind: Hunk.Kind?
    var moveContext: LineDiffMoveContext? = nil

    static func == (lhs: LineDiffSnapshot, rhs: LineDiffSnapshot) -> Bool {
        lhs.left == rhs.left
            && lhs.right == rhs.right
            && lhs.hunkKind == rhs.hunkKind
            && lhs.moveContext == rhs.moveContext
            && (lhs.language === rhs.language || (lhs.language.name == rhs.language.name && lhs.language.family == rhs.language.family))
    }
}

/// Pure formatting helpers for `LineDiffBarView`.
enum LineDiffFormatter {
    struct ExpandedLine: Equatable, Sendable {
        var text: String
        var syntaxSpans: [SyntaxSpan]
        var highlightRanges: [Range<Int>]
    }

    /// Expands `\t` to 4-column tab stops while remapping UTF-16 `SyntaxSpan`s and highlight ranges.
    static func expandTabs(
        _ line: String,
        syntaxSpans: [SyntaxSpan],
        highlightRanges: [Range<Int>],
        tabWidth: Int = 4
    ) -> ExpandedLine {
        let effectiveTabWidth = max(1, tabWidth)
        let ns = line as NSString
        let length = ns.length
        guard line.utf8.contains(9) else {
            let clampedSpans = syntaxSpans.compactMap { span -> SyntaxSpan? in
                let start = max(0, min(Int(span.start), length))
                let end = max(start, min(Int(span.start + span.length), length))
                guard end > start else { return nil }
                return SyntaxSpan(start: Int32(start), length: Int32(end - start), kind: span.kind)
            }
            let clampedHighlights = highlightRanges.compactMap { range -> Range<Int>? in
                let start = max(0, min(range.lowerBound, length))
                let end = max(start, min(range.upperBound, length))
                return end > start ? start..<end : nil
            }
            return ExpandedLine(text: line, syntaxSpans: clampedSpans, highlightRanges: clampedHighlights)
        }

        var map = [Int](repeating: 0, count: length + 1)
        var units: [unichar] = []
        units.reserveCapacity(length + 16)
        var visualCol = 0

        for i in 0..<length {
            map[i] = units.count
            let c = ns.character(at: i)
            if c == 9 {
                let spaces = effectiveTabWidth - (visualCol % effectiveTabWidth)
                for _ in 0..<spaces { units.append(32) }
                visualCol += spaces
            } else {
                units.append(c)
                if !(0xDC00...0xDFFF).contains(c) {
                    visualCol += 1
                }
            }
        }
        map[length] = units.count

        let expandedText = String(utf16CodeUnits: units, count: units.count)
        let mappedSpans: [SyntaxSpan] = syntaxSpans.compactMap { span in
            let s0 = max(0, min(Int(span.start), length))
            let s1 = max(s0, min(Int(span.start + span.length), length))
            let newStart = map[s0]
            let newEnd = map[s1]
            guard newEnd > newStart else { return nil }
            return SyntaxSpan(start: Int32(newStart), length: Int32(newEnd - newStart), kind: span.kind)
        }
        let mappedHighlights: [Range<Int>] = highlightRanges.compactMap { range in
            let h0 = map[max(0, min(range.lowerBound, length))]
            let h1 = map[max(0, min(range.upperBound, length))]
            return h1 > h0 ? h0..<h1 : nil
        }
        return ExpandedLine(text: expandedText, syntaxSpans: mappedSpans, highlightRanges: mappedHighlights)
    }
}

/// Pure extractor that pairs any 0-based line on either side of a `DiffDocument` into a `LineDiffSnapshot`.
enum LineDiffExtractor {
    /// Extracts a paired snapshot for 0-based `line` on `side`.
    static func extract(from doc: DiffDocument, side: Side, line: Int) -> LineDiffSnapshot? {
        guard !doc.isPlainFile else { return nil }
        guard case .text = doc.content else { return nil }
        guard !doc.left.lines.isEmpty || !doc.right.lines.isEmpty else { return nil }
        let sourceBuffer = doc.buffer(side)
        guard line >= 0, line < sourceBuffer.lines.count else { return nil }

        var precedingDelta = 0
        for (hunkIndex, hunk) in doc.hunks.enumerated() {
            let start = side == .left ? hunk.leftStart : hunk.rightStart
            let count = side == .left ? hunk.leftCount : hunk.rightCount

            if count > 0, line >= start, line < start + count {
                return extractInHunk(doc: doc, hunk: hunk, hunkIndex: hunkIndex, side: side, line: line)
            }
            if start + count <= line {
                precedingDelta += hunk.rightCount - hunk.leftCount
            } else if start > line {
                break
            }
        }

        // Context line outside every hunk: pair using cumulative line shift from preceding hunks.
        switch side {
        case .left:
            let rightLine = line + precedingDelta
            let leftRow = makeRow(buffer: doc.left, line: line, highlightRanges: [], kind: .unchanged)
            let rightRow: LineDiffRow = (rightLine >= 0 && rightLine < doc.right.lines.count)
                ? makeRow(buffer: doc.right, line: rightLine, highlightRanges: [], kind: .unchanged)
                : .empty
            return LineDiffSnapshot(left: leftRow, right: rightRow, language: doc.language, hunkKind: nil)

        case .right:
            let leftLine = line - precedingDelta
            let leftRow: LineDiffRow = (leftLine >= 0 && leftLine < doc.left.lines.count)
                ? makeRow(buffer: doc.left, line: leftLine, highlightRanges: [], kind: .unchanged)
                : .empty
            let rightRow = makeRow(buffer: doc.right, line: line, highlightRanges: [], kind: .unchanged)
            return LineDiffSnapshot(left: leftRow, right: rightRow, language: doc.language, hunkKind: nil)
        }
    }

    /// Fallback snapshot for the focused hunk (or hunk 0) before the user clicks a line.
    static func defaultSnapshot(for doc: DiffDocument, focusedHunk: Int? = nil) -> LineDiffSnapshot? {
        guard !doc.isPlainFile, !doc.hunks.isEmpty else { return nil }
        let idx: Int
        if let focusedHunk, focusedHunk >= 0, focusedHunk < doc.hunks.count {
            idx = focusedHunk
        } else {
            idx = 0
        }
        let hunk = doc.hunks[idx]
        if hunk.rightCount > 0 {
            return extract(from: doc, side: .right, line: hunk.rightStart)
        } else if hunk.leftCount > 0 {
            return extract(from: doc, side: .left, line: hunk.leftStart)
        }
        return nil
    }

    // MARK: - Private helpers

    private static func extractInHunk(doc: DiffDocument, hunk: Hunk, hunkIndex: Int, side: Side, line: Int) -> LineDiffSnapshot? {
        if let move = hunk.moveInfo, doc.hunks.indices.contains(move.counterpartHunkIndex) {
            let counterpart = doc.hunks[move.counterpartHunkIndex]
            let isSourceSide = move.role == .source && side == .left
            let isTargetSide = move.role == .target && side == .right
            if isSourceSide || isTargetSide {
                let sourceHunk = move.role == .source ? hunk : counterpart
                let targetHunk = move.role == .target ? hunk : counterpart
                let offset = isSourceSide ? (line - hunk.leftStart) : (line - hunk.rightStart)
                let srcLine = sourceHunk.leftStart + offset
                let dstLine = targetHunk.rightStart + offset
                let hasSrc = offset >= 0 && offset < sourceHunk.leftCount && srcLine >= 0 && srcLine < doc.left.lines.count
                let hasDst = offset >= 0 && offset < targetHunk.rightCount && dstLine >= 0 && dstLine < doc.right.lines.count

                var leftRanges: [Range<Int>] = []
                var rightRanges: [Range<Int>] = []
                if let inline = move.inlineDiff {
                    if offset >= 0, offset < inline.source.count { leftRanges = inline.source[offset] }
                    if offset >= 0, offset < inline.target.count { rightRanges = inline.target[offset] }
                } else if hasSrc && hasDst && doc.left.lines[srcLine] != doc.right.lines[dstLine] {
                    let fallback = fallbackInlineDiff(old: doc.left.lines[srcLine], new: doc.right.lines[dstLine])
                    leftRanges = fallback.left
                    rightRanges = fallback.right
                }

                let leftRow: LineDiffRow = hasSrc
                    ? makeRow(buffer: doc.left, line: srcLine, highlightRanges: leftRanges, kind: .moved)
                    : .empty
                let rightRow: LineDiffRow = hasDst
                    ? makeRow(buffer: doc.right, line: dstLine, highlightRanges: rightRanges, kind: .moved)
                    : .empty
                let context = LineDiffMoveContext(
                    hunkIndex: hunkIndex,
                    counterpartHunkIndex: move.counterpartHunkIndex,
                    role: move.role,
                    similarity: move.similarity,
                    hasInlineEdits: move.inlineDiff != nil || move.similarity < 0.999
                )
                return LineDiffSnapshot(
                    left: leftRow,
                    right: rightRow,
                    language: doc.language,
                    hunkKind: hunk.kind,
                    moveContext: context
                )
            }
        }

        let moveContext: LineDiffMoveContext? = hunk.moveInfo.map {
            LineDiffMoveContext(
                hunkIndex: hunkIndex,
                counterpartHunkIndex: $0.counterpartHunkIndex,
                role: $0.role,
                similarity: $0.similarity,
                hasInlineEdits: $0.inlineDiff != nil || $0.similarity < 0.999
            )
        }

        switch hunk.kind {
        case .added:
            guard side == .right else { return nil }
            let rightRow = makeRow(buffer: doc.right, line: line, highlightRanges: [], kind: .added)
            return LineDiffSnapshot(left: .empty, right: rightRow, language: doc.language, hunkKind: .added, moveContext: moveContext)

        case .deleted:
            guard side == .left else { return nil }
            let leftRow = makeRow(buffer: doc.left, line: line, highlightRanges: [], kind: .removed)
            return LineDiffSnapshot(left: leftRow, right: .empty, language: doc.language, hunkKind: .deleted, moveContext: moveContext)

        case .modified:
            let thisStart = side == .left ? hunk.leftStart : hunk.rightStart
            let otherCount = side == .left ? hunk.rightCount : hunk.leftCount
            let otherStart = side == .left ? hunk.rightStart : hunk.leftStart
            let offset = line - thisStart

            if offset < otherCount {
                let leftLine = side == .left ? line : otherStart + offset
                let rightLine = side == .right ? line : otherStart + offset
                guard leftLine >= 0, leftLine < doc.left.lines.count,
                      rightLine >= 0, rightLine < doc.right.lines.count else {
                    return nil
                }

                let leftRanges: [Range<Int>]
                let rightRanges: [Range<Int>]
                if offset < hunk.leftInline.count, offset < hunk.rightInline.count {
                    leftRanges = hunk.leftInline[offset]
                    rightRanges = hunk.rightInline[offset]
                } else {
                    let fallback = fallbackInlineDiff(old: doc.left.lines[leftLine], new: doc.right.lines[rightLine])
                    leftRanges = offset < hunk.leftInline.count ? hunk.leftInline[offset] : fallback.left
                    rightRanges = offset < hunk.rightInline.count ? hunk.rightInline[offset] : fallback.right
                }

                let leftRow = makeRow(buffer: doc.left, line: leftLine, highlightRanges: leftRanges, kind: .modified)
                let rightRow = makeRow(buffer: doc.right, line: rightLine, highlightRanges: rightRanges, kind: .modified)
                return LineDiffSnapshot(left: leftRow, right: rightRow, language: doc.language, hunkKind: .modified, moveContext: moveContext)
            } else {
                // Asymmetric modified hunk: this line has no partner at the same offset on the other side.
                if side == .left {
                    let leftRow = makeRow(buffer: doc.left, line: line, highlightRanges: [], kind: .removed)
                    return LineDiffSnapshot(left: leftRow, right: .empty, language: doc.language, hunkKind: .modified, moveContext: moveContext)
                } else {
                    let rightRow = makeRow(buffer: doc.right, line: line, highlightRanges: [], kind: .added)
                    return LineDiffSnapshot(left: .empty, right: rightRow, language: doc.language, hunkKind: .modified, moveContext: moveContext)
                }
            }
        }
    }

    private static func makeRow(
        buffer: TextBuffer,
        line: Int,
        highlightRanges: [Range<Int>],
        kind: LineDiffRow.Kind
    ) -> LineDiffRow {
        LineDiffRow(
            lineNumber: line + 1,
            text: buffer.lines[line],
            syntaxSpans: buffer.spans(at: line),
            highlightRanges: highlightRanges,
            kind: kind
        )
    }

    /// Computes word-level (or character-level fallback) UTF-16 diff ranges for a single line pair.
    private static func fallbackInlineDiff(old: String, new: String) -> (left: [Range<Int>], right: [Range<Int>]) {
        guard old != new else { return ([], []) }

        if let wordDiff = InlineDiff.compute(old: [old][...], new: [new][...]),
           let oldRanges = wordDiff.old.first, let newRanges = wordDiff.new.first,
           !oldRanges.isEmpty || !newRanges.isEmpty {
            return (oldRanges, newRanges)
        }

        let a = Array(old.utf16)
        let b = Array(new.utf16)

        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            prefix += 1
        }
        if prefix > 0,
           (prefix < a.count && isLowSurrogate(a[prefix])) || (prefix < b.count && isLowSurrogate(b[prefix])) {
            prefix -= 1
        }

        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            suffix += 1
        }
        if suffix > 0,
           isLowSurrogate(a[a.count - suffix]) || isLowSurrogate(b[b.count - suffix]) {
            suffix -= 1
        }

        let aMidEnd = a.count - suffix
        let bMidEnd = b.count - suffix
        let midA = Array(a[prefix..<aMidEnd])
        let midB = Array(b[prefix..<bMidEnd])

        if !midA.isEmpty, !midB.isEmpty {
            if midA.count <= 512, midB.count <= 512,
               let (midMatchedA, midMatchedB) = Myers.matches(midA, midB, maxEdits: 200) {
                let matchedCount = midMatchedA.lazy.filter { $0 }.count
                if matchedCount >= max(2, min(midA.count, midB.count) / 3) {
                    var matchedA = [Bool](repeating: true, count: a.count)
                    var matchedB = [Bool](repeating: true, count: b.count)
                    for i in midMatchedA.indices { matchedA[prefix + i] = midMatchedA[i] }
                    for i in midMatchedB.indices { matchedB[prefix + i] = midMatchedB[i] }
                    InlineDiff.shiftUTF16Runs(units: a, matched: &matchedA)
                    InlineDiff.shiftUTF16Runs(units: b, matched: &matchedB)
                    return (
                        unmatchedRanges(in: a, offset: 0, matched: matchedA),
                        unmatchedRanges(in: b, offset: 0, matched: matchedB)
                    )
                }
            }
            let leftRanges = aMidEnd > prefix ? [prefix..<aMidEnd] : []
            let rightRanges = bMidEnd > prefix ? [prefix..<bMidEnd] : []
            return (leftRanges, rightRanges)
        }

        // Pure character-level insertion or deletion: shift to semantic character boundaries.
        func shiftedPureRanges(in units: [UInt16], midEnd: Int) -> [Range<Int>] {
            guard midEnd > prefix else { return [] }
            var matched = [Bool](repeating: true, count: units.count)
            for i in prefix..<midEnd { matched[i] = false }
            InlineDiff.shiftUTF16Runs(units: units, matched: &matched)
            return unmatchedRanges(in: units, offset: 0, matched: matched)
        }
        return (shiftedPureRanges(in: a, midEnd: aMidEnd), shiftedPureRanges(in: b, midEnd: bMidEnd))
    }

    private static func unmatchedRanges(in units: [UInt16], offset: Int, matched: [Bool]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openStart: Int?
        for i in matched.indices {
            if !matched[i] {
                if openStart == nil { openStart = offset + i }
            } else if let start = openStart {
                ranges.append(safeUTF16Range(start..<(offset + i), in: units))
                openStart = nil
            }
        }
        if let start = openStart {
            ranges.append(safeUTF16Range(start..<(offset + matched.count), in: units))
        }
        return mergeAdjacentRanges(ranges)
    }

    private static func safeUTF16Range(_ range: Range<Int>, in units: [UInt16]) -> Range<Int> {
        var start = range.lowerBound
        var end = range.upperBound
        if start > 0, start < units.count, isLowSurrogate(units[start]) {
            start -= 1
        }
        if end > 0, end < units.count, isLowSurrogate(units[end]) {
            end += 1
        }
        return start..<max(start, end)
    }

    private static func mergeAdjacentRanges(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges where !range.isEmpty {
            if let last = merged.last, last.upperBound >= range.lowerBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    @inline(__always)
    private static func isLowSurrogate(_ unit: UInt16) -> Bool {
        (0xDC00...0xDFFF).contains(unit)
    }
}

/// Beyond Compare-style bottom inline line diff bar showing Left (Old) stacked above Right (New).
struct LineDiffBarView: View {
    let snapshot: LineDiffSnapshot?
    let theme: CanvasTheme
    let codeFont: CodeFont
    let onClose: () -> Void
    var onJumpToMoveCounterpart: ((Int) -> Void)? = nil

    @State private var closeHovered = false
    @State private var jumpHovered = false

    private var rowHeight: CGFloat {
        max(20, min(25, codeFont.lineHeight + 3))
    }

    private var scrollAreaHeight: CGFloat {
        rowHeight * 2 + 1 + 8
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(cgColor: theme.separator))
                .frame(height: 1)

            if let snapshot {
                if let move = snapshot.moveContext {
                    moveBanner(move)
                    Rectangle()
                        .fill(Color(cgColor: theme.separator).opacity(0.6))
                        .frame(height: 1)
                }
                diffBody(snapshot)
            } else {
                emptyBody
            }
        }
        .background(Color(cgColor: theme.background))
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.top, snapshot?.moveContext != nil ? 3 : 4)
                .padding(.trailing, 6)
        }
    }

    private func moveBanner(_ move: LineDiffMoveContext) -> some View {
        let pct = Int((move.similarity * 100).rounded())
        let roleText = move.role == .source ? L("Move Source", "移动源") : L("Move Target", "移动目标")
        let summaryText: String = move.hasInlineEdits
            ? L("Moved block (similarity \(pct)% · tweaked)", "已移动（相似度 \(pct)% · 有微调）")
            : L("Moved block (100% identical)", "已移动（100% 一致）")
        return HStack(spacing: 8) {
            Image(systemName: move.role == .source ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.difMovedAccent)
            Text(roleText)
                .font(.ui(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.difMovedAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.difMovedBg))
                .overlay(Capsule().strokeBorder(Color.difMovedBorder.opacity(0.6), lineWidth: 0.75))
            Text(summaryText)
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
            if let onJump = onJumpToMoveCounterpart {
                Button {
                    onJump(move.hunkIndex)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(move.role == .source ? L("Jump to Target", "跳至目标块") : L("Jump to Source", "跳至源块"))
                            .font(.ui(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(jumpHovered ? Color.white : Color.difMovedAccent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(jumpHovered ? Color.difMovedAccent : Color.difMovedBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.difMovedBorder.opacity(jumpHovered ? 0 : 0.7), lineWidth: 0.75)
                    )
                }
                .buttonStyle(.plain)
                .onHover { jumpHovered = $0 }
                .help(L("Jump to the paired moved hunk", "跳转到配对的移动代码块"))
            }
            Spacer(minLength: 28)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color.difMovedBg.opacity(0.55))
    }

    @ViewBuilder
    private func diffBody(_ snapshot: LineDiffSnapshot) -> some View {
        let leftExpanded = LineDiffFormatter.expandTabs(
            snapshot.left.text,
            syntaxSpans: snapshot.left.syntaxSpans,
            highlightRanges: snapshot.left.highlightRanges
        )
        let rightExpanded = LineDiffFormatter.expandTabs(
            snapshot.right.text,
            syntaxSpans: snapshot.right.syntaxSpans,
            highlightRanges: snapshot.right.highlightRanges
        )
        let maxNumber = max(snapshot.left.lineNumber ?? 0, snapshot.right.lineNumber ?? 0)
        let digits = max(3, String(maxNumber).count)
        let gutterWidth = CGFloat(digits) * codeFont.charWidth + 26

        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                gutterRow(row: snapshot.left, isLeft: true, width: gutterWidth)
                Rectangle()
                    .fill(Color(cgColor: theme.separator).opacity(0.45))
                    .frame(width: gutterWidth, height: 1)
                gutterRow(row: snapshot.right, isLeft: false, width: gutterWidth)
            }

            Rectangle()
                .fill(Color(cgColor: theme.separator))
                .frame(width: 1, height: scrollAreaHeight)

            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        codeRow(row: snapshot.left, expanded: leftExpanded, language: snapshot.language)
                        Rectangle()
                            .fill(Color(cgColor: theme.separator).opacity(0.45))
                            .frame(height: 1)
                        codeRow(row: snapshot.right, expanded: rightExpanded, language: snapshot.language)
                    }
                    .frame(minWidth: geo.size.width, alignment: .leading)
                }
            }
            .frame(height: scrollAreaHeight)
        }
    }

    private var emptyBody: some View {
        HStack(spacing: 8) {
            Text(L("Select a line to inspect its full inline diff", "选中任意行以查看完整行内对比"))
                .font(.ui(size: 11.5))
                .foregroundStyle(Color(cgColor: theme.gutterTextStrong))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.trailing, 24)
        .frame(height: scrollAreaHeight)
    }

    private func gutterRow(row: LineDiffRow, isLeft: Bool, width: CGFloat) -> some View {
        let marker = gutterMarker(for: row.kind, isLeft: isLeft)
        return HStack(spacing: 5) {
            Text(marker.symbol)
                .font(Font(codeFont.regularFont as NSFont))
                .foregroundStyle(marker.color)
                .frame(width: 10, alignment: .center)
            Text(row.lineNumber.map(String.init) ?? "")
                .font(Font(codeFont.regularFont as NSFont).monospacedDigit())
                .foregroundStyle(row.kind == .unchanged ? Color(cgColor: theme.gutterText) : Color(cgColor: theme.gutterTextStrong))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: rowHeight)
        .background(rowBackground(for: row.kind))
    }

    private func codeRow(
        row: LineDiffRow,
        expanded: LineDiffFormatter.ExpandedLine,
        language: LanguageSpec
    ) -> some View {
        HStack(spacing: 0) {
            Text(attributedLine(row: row, expanded: expanded, language: language))
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 28)
        .frame(height: rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground(for: row.kind))
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(Color(cgColor: closeHovered ? theme.text : theme.gutterTextStrong))
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color(cgColor: theme.background).opacity(closeHovered ? 0.95 : 0.78))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(cgColor: theme.separator).opacity(closeHovered ? 0.9 : 0.4), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { closeHovered = $0 }
        .help(L("Hide Inline Line Diff Bar", "隐藏底部行内对比栏"))
        .accessibilityLabel(L("Hide Inline Line Diff Bar", "隐藏底部行内对比栏"))
    }

    // MARK: - Styling helpers

    private func gutterMarker(for kind: LineDiffRow.Kind, isLeft: Bool) -> (symbol: String, color: Color) {
        switch kind {
        case .removed:
            return ("−", Color.difRemoved)
        case .added:
            return ("+", Color(cgColor: theme.addedMark))
        case .modified:
            return (isLeft ? "−" : "+", Color(cgColor: theme.modifiedMark))
        case .moved:
            return (isLeft ? "↗" : "↘", Color(cgColor: theme.movedAccent))
        case .unchanged:
            return ("·", Color(cgColor: theme.gutterText))
        case .empty:
            return (" ", Color(cgColor: theme.gutterText))
        }
    }

    private func rowBackground(for kind: LineDiffRow.Kind) -> Color {
        switch kind {
        case .unchanged, .empty: return .clear
        case .removed: return Color(cgColor: theme.removedLine)
        case .added: return Color(cgColor: theme.added)
        case .modified: return Color(cgColor: theme.modified)
        case .moved: return Color(cgColor: theme.moved)
        }
    }

    private func wordHighlightColor(for kind: LineDiffRow.Kind) -> Color? {
        switch kind {
        case .removed: return Color(cgColor: theme.removedWord)
        case .added: return Color(cgColor: theme.addedWord)
        case .modified: return Color(cgColor: theme.modifiedWord)
        case .moved: return Color(cgColor: theme.movedWord)
        case .unchanged, .empty: return nil
        }
    }

    private func attributedLine(
        row: LineDiffRow,
        expanded: LineDiffFormatter.ExpandedLine,
        language: LanguageSpec
    ) -> AttributedString {
        guard !expanded.text.isEmpty else {
            var empty = AttributedString(" ")
            empty[Attr.Font.self] = Font(codeFont.regularFont as NSFont)
            return empty
        }

        var result = AttributedString(expanded.text)
        let styles = theme.styles(for: language)
        let defaultColor = styles.first?.color ?? theme.text
        result[Attr.Foreground.self] = Color(cgColor: defaultColor)
        result[Attr.Font.self] = Font(codeFont.regularFont as NSFont)
        result[Attr.Ligature.self] = codeFont.ligatures ? 1 : 0

        let utf16Len = (expanded.text as NSString).length

        for span in expanded.syntaxSpans where span.kind != .plain {
            let start = max(0, min(Int(span.start), utf16Len))
            let end = max(start, min(Int(span.start + span.length), utf16Len))
            guard end > start else { continue }
            let idx = Int(span.kind.rawValue)
            guard idx < styles.count else { continue }
            let style = styles[idx]
            if let range = utf16Range(start..<end, in: expanded.text, attributed: result) {
                result[range][Attr.Foreground.self] = Color(cgColor: style.color)
                if style.bold || style.italic {
                    result[range][Attr.Font.self] = Font(codeFont.ctFont(bold: style.bold, italic: style.italic) as NSFont)
                }
            }
        }

        if let hlColor = wordHighlightColor(for: row.kind) {
            for hl in expanded.highlightRanges {
                let start = max(0, min(hl.lowerBound, utf16Len))
                let end = max(start, min(hl.upperBound, utf16Len))
                if end > start, let range = utf16Range(start..<end, in: expanded.text, attributed: result) {
                    result[range][Attr.Background.self] = hlColor
                }
            }
        }

        return result
    }

    private func utf16Range(
        _ range: Range<Int>,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count, range.lowerBound < range.upperBound else {
            return nil
        }
        let start16 = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end16 = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard let start = start16.samePosition(in: text),
              let end = end16.samePosition(in: text),
              start < end else {
            return nil
        }
        return Range(start..<end, in: attributed)
    }
}
