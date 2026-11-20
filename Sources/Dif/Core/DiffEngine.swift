import Foundation

/// One side of a comparison (or the whole of a plain file).
final class TextBuffer {
    private(set) var lines: [String]
    var spans: [[SyntaxSpan]] = []
    /// Base Lexer spans preserved separately once LSP semantic tokens are overlaid,
    /// so subsequent semantic refreshes re-merge cleanly without compounding.
    var baseSpans: [[SyntaxSpan]]?
    /// The lexer state at the start of each line and after the last, for buffers that can be edited:
    /// an edit then re-colours only the lines it affects.
    var states: [Highlighter.State]?
    /// Widest line, in approximate monospace columns. Drives the horizontal scroll extent.
    /// Grows as lines are edited wider; never shrinks until the file is read again.
    private(set) var maxColumns: Int

    /// Shared and never edited: a side that does not exist.
    nonisolated(unsafe) static let empty = TextBuffer(lines: [])

    init(lines: [String]) {
        self.lines = lines
        var widest = 0
        for line in lines where line.utf8.count * 4 > widest { // cannot beat the current maximum even if all tabs
            widest = max(widest, Self.columns(of: line))
        }
        maxColumns = widest
    }

    static func columns(of line: String) -> Int {
        var cols = 0
        for b in line.utf8 {
            if b == 9 { cols += 4 - cols % 4 } else if b & 0xC0 != 0x80 { cols += b >= 0xE0 ? 2 : 1 }
        }
        return cols
    }

    func spans(at line: Int) -> [SyntaxSpan] {
        line < spans.count ? spans[line] : []
    }

    /// Replaces text; see `TextEditing.replace`. Colours are the caller's to bring up to date.
    @discardableResult
    func replace(from: TextPosition, to: TextPosition, with text: String) -> (end: TextPosition, raw: LineEdit, change: LineEdit) {
        precondition(self !== TextBuffer.empty, "the shared empty buffer is never edited")
        let count = lines.count
        let result = TextEditing.replace(&lines, from: from, to: to, with: text)
        let raw = result.raw
        for row in raw.start..<(raw.start + raw.inserted) {
            maxColumns = max(maxColumns, Self.columns(of: lines[row]))
        }
        if count > 0, spans.count == count {
            spans.replaceSubrange(raw.start..<(raw.start + raw.removed), with: repeatElement([], count: raw.inserted))
        } else {
            spans = []
        }
        if count > 0, baseSpans?.count == count {
            baseSpans!.replaceSubrange(raw.start..<(raw.start + raw.removed), with: repeatElement([], count: raw.inserted))
        } else {
            baseSpans = nil
        }
        if count > 0, states?.count == count + 1 {
            // The states going into the first rewritten line, and into the line after them, are kept.
            states!.replaceSubrange((raw.start + 1)..<(raw.start + raw.removed),
                                    with: repeatElement(Highlighter.State(), count: raw.inserted - 1))
        } else {
            states = nil
        }
        return result
    }

    /// Replaces `lines[range]` with `newLines` (allowing empty-buffer and full-deletion transitions) and
    /// incrementally updates syntax spans and lexer states. Returns the range of lines whose highlighting changed.
    @discardableResult
    func replaceLines(in range: Range<Int>, with newLines: [String], language: LanguageSpec) -> Range<Int> {
        precondition(self !== TextBuffer.empty, "the shared empty buffer is never edited")
        let clampedLower = min(max(0, range.lowerBound), lines.count)
        let clampedUpper = min(max(clampedLower, range.upperBound), lines.count)
        let safeRange = clampedLower..<clampedUpper
        let oldCount = lines.count

        lines.replaceSubrange(safeRange, with: newLines)
        for row in clampedLower..<(clampedLower + newLines.count) {
            maxColumns = max(maxColumns, Self.columns(of: lines[row]))
        }

        if lines.isEmpty {
            spans = []
            baseSpans = nil
            states = states != nil ? [Highlighter.State()] : nil
            return 0..<0
        }

        if oldCount == 0 {
            let tracked = Highlighter.highlightTracking(lines, language: language)
            spans = tracked.spans
            states = tracked.states
            baseSpans = nil
            return 0..<lines.count
        }

        let inserted = newLines.count
        if spans.count == oldCount {
            spans.replaceSubrange(safeRange, with: repeatElement([], count: inserted))
        } else {
            spans = [[SyntaxSpan]](repeating: [], count: lines.count)
        }
        baseSpans = nil

        if var currentStates = states, currentStates.count == oldCount + 1 {
            // Keep state entering `clampedLower` (`currentStates[clampedLower]`) and state entering `clampedUpper` intact.
            let removed = clampedUpper - clampedLower
            if inserted == 0, removed > 0 {
                currentStates.removeSubrange((clampedLower + 1)..<(clampedUpper + 1))
            } else if removed == 0, inserted > 0 {
                let incoming = currentStates[clampedLower]
                currentStates.insert(contentsOf: repeatElement(Highlighter.State(), count: inserted - 1) + [incoming], at: clampedLower + 1)
            } else if removed > 0, inserted > 0 {
                currentStates.replaceSubrange((clampedLower + 1)..<clampedUpper,
                                            with: repeatElement(Highlighter.State(), count: inserted - 1))
            }
            states = currentStates
            if currentStates.count == lines.count + 1 {
                let startRow = min(clampedLower, lines.count - 1)
                let recolourCount = min(max(1, inserted), lines.count - startRow)
                return Highlighter.rehighlight(lines, language: language, from: startRow, count: recolourCount, spans: &spans, states: &states!)
            }
        }

        let tracked = Highlighter.highlightTracking(lines, language: language)
        spans = tracked.spans
        states = tracked.states
        return 0..<lines.count
    }

    /// Merges per-line LSP semantic spans over the preserved base Lexer spans.
    /// Returns the 0-based line indices whose displayed spans changed.
    @discardableResult
    func applySemanticTokens(_ semanticByLine: [Int: [LSPSemanticSpan]]) -> IndexSet {
        guard !lines.isEmpty else { return IndexSet() }
        if baseSpans == nil || baseSpans?.count != lines.count {
            if spans.count == lines.count {
                baseSpans = spans
            } else {
                baseSpans = [[SyntaxSpan]](repeating: [], count: lines.count)
            }
        }
        if spans.count != lines.count {
            spans = baseSpans!
        }
        let base = baseSpans!
        var changed = IndexSet()
        var activeGoReceiver: String?
        for line in 0..<lines.count {
            let text = lines[line]
            if text.hasPrefix("func ") || text.hasPrefix("func(") {
                activeGoReceiver = SyntaxOverlay.goMethodReceiverName(in: text)
            } else if text.hasPrefix("}") {
                activeGoReceiver = nil
            }
            let merged: [SyntaxSpan]
            if let sem = semanticByLine[line], !sem.isEmpty {
                merged = SyntaxOverlay.merge(base: base[line], semantic: sem, lineText: text, goReceiver: activeGoReceiver)
            } else {
                merged = base[line]
            }
            if spans[line] != merged {
                spans[line] = merged
                changed.insert(line)
            }
        }
        return changed
    }
}

/// What it takes to edit the right side of a document and write it back.
struct EditInfo {
    var format = TextFormat()
    var crlf: [Bool]?
    /// Fingerprint of the bytes the right side was read from.
    var fingerprint = Data()
    /// The left side's bytes, to diff against as the text changes; nil when there is no left side.
    var base: Data?
    /// Why the right side stays read-only, when it does.
    var readOnlyReason: String?
}

struct Hunk: Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable { case added, deleted, modified }

    var leftStart: Int
    var leftCount: Int
    var rightStart: Int
    var rightCount: Int
    /// Changed character ranges (UTF-16) per line of the hunk, for word-level highlighting.
    var leftInline: [[Range<Int>]] = []
    var rightInline: [[Range<Int>]] = []
    /// Populated when intra-file move detection pairs this hunk with a counterpart hunk.
    var moveInfo: HunkMoveInfo? = nil

    var kind: Kind {
        if leftCount == 0 { return .added }
        if rightCount == 0 { return .deleted }
        return .modified
    }
}

/// A run of lines that scrolls as a unit. Unchanged runs have equal counts on both sides;
/// a hunk occupies `max(leftCount, rightCount)` virtual lines so the shorter side scrolls
/// proportionally slower and the two panes stay aligned without padding.
struct Segment: Equatable, Sendable {
    var virtualStart: Int
    var leftStart: Int
    var leftCount: Int
    var rightStart: Int
    var rightCount: Int
    var hunk: Int // -1 for unchanged runs

    var span: Int { max(leftCount, rightCount) }
}

struct UnifiedRow {
    enum Kind: UInt8 { case context, removed, added }
    var kind: Kind
    var left: Int32   // -1 when absent
    var right: Int32
    var hunk: Int32
}

enum Side: Int, Hashable, Sendable { case left = 0, right = 1 }

/// Cached raw unfiltered lines and 0-based raw hunks (matching `AIHunkGrouper`) so switching
/// between AI groups on the same file re-filters in memory without re-reading disk or spawning git.
struct GroupFilterBaseline {
    var oldLines: [String]?
    var newLines: [String]?
    var rawHunks: [Hunk]
    var rightSpans: [[SyntaxSpan]]
    var shouldHighlight: Bool
    var hasWorktreeFile: Bool
}

final class DiffDocument {
    enum Content {
        case text
        case image(old: Data?, new: Data?)
        case spreadsheet(XLSXWorkbook, fileURL: URL?)
        case message(title: String, detail: String)
    }

    let left: TextBuffer
    let right: TextBuffer
    private(set) var hunks: [Hunk]
    private(set) var segments: [Segment]
    private(set) var virtualLineCount: Int
    let language: LanguageSpec
    let content: Content
    /// True for a plain file view (no comparison).
    let isPlainFile: Bool
    var leftTitle = ""
    var rightTitle = ""
    var note: String?
    var loadMilliseconds: Double = 0
    /// Set when the right side is a file in the working tree: how to write it back, or why it cannot be.
    var editing: EditInfo?
    /// Active SemanticDiff options used to build this document.
    var semanticOptions: SemanticDiffOptions = .disabled
    /// True when both sides were canonically normalized as JSON (right side is read-only).
    var isJSONNormalized: Bool = false
    /// True when this document is filtered to show only one AI group's hunks (read-only view).
    var isGroupFiltered: Bool = false
    /// Maps original 0-based raw hunk indices to their 0-based indices in this filtered document's `hunks`.
    var groupHunkIndexMap: [Int: Int] = [:]
    /// Cached unfiltered baseline lines & raw hunks so switching AI groups on the same file is instantaneous.
    var groupFilterBaseline: GroupFilterBaseline?
    /// Comment-only hunks hidden when `semanticOptions.ignoreComments == true`.
    private(set) var hiddenCommentHunks: [Hunk] = []
    /// Number of comment-only hunks hidden from `hunks` by `ignoreComments`.
    var hiddenCommentHunkCount: Int { hiddenCommentHunks.count }
    /// Cross-hunk identifier rename groups detected when `semanticOptions.detectRenames == true`.
    private(set) var renameGroups: [RenameGroup] = []
    private var renameIndex: SemanticRenameIndex = .empty

    private var unifiedCache: [UnifiedRow]?
    var unifiedRows: [UnifiedRow] {
        if let cached = unifiedCache { return cached }
        let rows = buildUnifiedRows()
        unifiedCache = rows
        return rows
    }

    var additions: Int { hunks.reduce(0) { $0 + $1.rightCount } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.leftCount } }

    /// True when this is a newly added / untracked file whose left side has no lines and all hunks are additions.
    var isAddedOnly: Bool {
        !isPlainFile && left.lines.isEmpty && !right.lines.isEmpty && hunks.allSatisfy { $0.kind == .added }
    }

    init(left: TextBuffer, right: TextBuffer, hunks: [Hunk], language: LanguageSpec,
         content: Content = .text, isPlainFile: Bool = false, hiddenCommentHunks: [Hunk] = []) {
        self.left = left
        self.right = right
        self.language = language
        self.content = content
        self.isPlainFile = isPlainFile
        (self.hunks, self.hiddenCommentHunks, segments, virtualLineCount) = Self.layout(
            hunks,
            hiddenCommentHunks: hiddenCommentHunks,
            leftCount: left.lines.count,
            rightCount: right.lines.count
        )
    }

    /// New hunks for the same two sides, e.g. after the right side was edited (its buffer is shared, so it already has the new lines).
    func setHunks(_ hunks: [Hunk], hiddenCommentHunks: [Hunk] = []) {
        (self.hunks, self.hiddenCommentHunks, segments, virtualLineCount) = Self.layout(
            hunks,
            hiddenCommentHunks: hiddenCommentHunks,
            leftCount: left.lines.count,
            rightCount: right.lines.count
        )
        groupFilterBaseline = nil
        unifiedCache = nil
    }

    /// Stores detected cross-hunk rename groups and rebuilds the O(1) lookup index.
    func setRenameGroups(_ groups: [RenameGroup]) {
        renameGroups = groups
        renameIndex = SemanticRenameIndex(groups: groups)
    }

    /// O(1) lookup of rename palette color index for a specific inline diff span.
    func renameColorIndex(hunkIndex: Int, side: Side, lineIndex: Int, range: Range<Int>) -> Int? {
        renameIndex.colorIndex(hunkIndex: hunkIndex, side: side, lineIndex: lineIndex, range: range)
    }

    /// O(1) lookup of rename palette color index for an `(oldName, newName)` pair.
    func renameColorIndex(oldName: String, newName: String) -> Int? {
        renameIndex.colorIndex(oldName: oldName, newName: newName)
    }

    /// O(1) lookup of the `RenameGroup` for an `(oldName, newName)` pair.
    func renameGroup(for oldName: String, newName: String) -> RenameGroup? {
        renameIndex.group(oldName: oldName, newName: newName)
    }

    /// O(1) lookup of all rename highlight spans on `lineIndex` of `side`.
    func renameOccurrences(side: Side, lineIndex: Int) -> [RenameOccurrence] {
        renameIndex.occurrences(side: side, lineIndex: lineIndex)
    }

    /// Builds a `DiffDisplayMap` for this document using its `semanticOptions` folding parameters.
    func displayMap(expandedSegments: Set<Int> = [], collapseEnabled: Bool? = nil) -> DiffDisplayMap {
        DiffDisplayMap(
            document: self,
            expandedSegments: expandedSegments,
            collapseEnabled: collapseEnabled ?? semanticOptions.collapseUnchanged,
            contextLines: semanticOptions.collapseContextLines,
            minHiddenLines: semanticOptions.collapseMinHiddenLines
        )
    }

    private static func layout(
        _ hunks: [Hunk],
        hiddenCommentHunks: [Hunk] = [],
        leftCount: Int,
        rightCount: Int
    ) -> ([Hunk], [Hunk], [Segment], Int) {
        if hiddenCommentHunks.isEmpty {
            // Fast path identical to standard diff layout.
            var clean: [Hunk] = []
            var lpos = 0, rpos = 0
            for var h in hunks {
                h.leftStart = min(max(h.leftStart, lpos), leftCount)
                h.rightStart = min(max(h.rightStart, rpos), rightCount)
                h.leftCount = max(0, min(h.leftCount, leftCount - h.leftStart))
                h.rightCount = max(0, min(h.rightCount, rightCount - h.rightStart))
                if h.leftCount == 0 && h.rightCount == 0 { continue }
                clean.append(h)
                lpos = h.leftStart + h.leftCount
                rpos = h.rightStart + h.rightCount
            }

            var segs: [Segment] = []
            var v = 0
            lpos = 0; rpos = 0
            for (index, h) in clean.enumerated() {
                let gapL = h.leftStart - lpos, gapR = h.rightStart - rpos
                if gapL > 0 || gapR > 0 {
                    segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: gapL, rightStart: rpos, rightCount: gapR, hunk: -1))
                    v += max(gapL, gapR)
                }
                segs.append(Segment(virtualStart: v, leftStart: h.leftStart, leftCount: h.leftCount,
                                    rightStart: h.rightStart, rightCount: h.rightCount, hunk: index))
                v += max(h.leftCount, h.rightCount)
                lpos = h.leftStart + h.leftCount
                rpos = h.rightStart + h.rightCount
            }
            let tailL = leftCount - lpos, tailR = rightCount - rpos
            if tailL > 0 || tailR > 0 {
                segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: tailL, rightStart: rpos, rightCount: tailR, hunk: -1))
                v += max(tailL, tailR)
            }
            return (clean, [], segs, v)
        }

        // Interleave visible hunks and hidden comment-only hunks (as `hunk: -1` segments)
        // so surrounding identical code keeps exact 1:1 alignment on both sides.
        struct CombinedEntry {
            var hunk: Hunk
            var isHidden: Bool
        }
        var combined: [CombinedEntry] = []
        combined.reserveCapacity(hunks.count + hiddenCommentHunks.count)
        for h in hunks { combined.append(CombinedEntry(hunk: h, isHidden: false)) }
        for h in hiddenCommentHunks { combined.append(CombinedEntry(hunk: h, isHidden: true)) }
        combined.sort { lhs, rhs in
            if lhs.hunk.leftStart != rhs.hunk.leftStart { return lhs.hunk.leftStart < rhs.hunk.leftStart }
            if lhs.hunk.rightStart != rhs.hunk.rightStart { return lhs.hunk.rightStart < rhs.hunk.rightStart }
            return !lhs.isHidden && rhs.isHidden
        }

        var clean: [Hunk] = []
        var cleanHidden: [Hunk] = []
        var clampedEntries: [CombinedEntry] = []
        var lpos = 0, rpos = 0
        for var entry in combined {
            entry.hunk.leftStart = min(max(entry.hunk.leftStart, lpos), leftCount)
            entry.hunk.rightStart = min(max(entry.hunk.rightStart, rpos), rightCount)
            entry.hunk.leftCount = max(0, min(entry.hunk.leftCount, leftCount - entry.hunk.leftStart))
            entry.hunk.rightCount = max(0, min(entry.hunk.rightCount, rightCount - entry.hunk.rightStart))
            if entry.hunk.leftCount == 0 && entry.hunk.rightCount == 0 { continue }
            if entry.isHidden {
                cleanHidden.append(entry.hunk)
            } else {
                clean.append(entry.hunk)
            }
            clampedEntries.append(entry)
            lpos = entry.hunk.leftStart + entry.hunk.leftCount
            rpos = entry.hunk.rightStart + entry.hunk.rightCount
        }

        var segs: [Segment] = []
        var v = 0
        var visibleIndex = 0
        lpos = 0; rpos = 0
        for entry in clampedEntries {
            let h = entry.hunk
            let gapL = h.leftStart - lpos, gapR = h.rightStart - rpos
            if gapL > 0 || gapR > 0 {
                segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: gapL, rightStart: rpos, rightCount: gapR, hunk: -1))
                v += max(gapL, gapR)
            }
            let hunkTag = entry.isHidden ? -1 : visibleIndex
            if !entry.isHidden { visibleIndex += 1 }
            segs.append(Segment(virtualStart: v, leftStart: h.leftStart, leftCount: h.leftCount,
                                rightStart: h.rightStart, rightCount: h.rightCount, hunk: hunkTag))
            v += max(h.leftCount, h.rightCount)
            lpos = h.leftStart + h.leftCount
            rpos = h.rightStart + h.rightCount
        }
        let tailL = leftCount - lpos, tailR = rightCount - rpos
        if tailL > 0 || tailR > 0 {
            segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: tailL, rightStart: rpos, rightCount: tailR, hunk: -1))
            v += max(tailL, tailR)
        }
        return (clean, cleanHidden, segs, v)
    }

    static func message(_ title: String, detail: String = "") -> DiffDocument {
        DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain, content: .message(title: title, detail: detail))
    }

    func buffer(_ side: Side) -> TextBuffer { side == .left ? left : right }

    // MARK: Scroll mapping

    private func segmentIndex(forVirtual v: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(segments[mid].virtualStart) <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Fractional line positions on each side for a virtual line position.
    func panePositions(forVirtual v: Double) -> (left: Double, right: Double) {
        guard let idx = segmentIndex(forVirtual: v) else { return (0, 0) }
        let s = segments[idx]
        let span = Double(s.span)
        let t = span > 0 ? min(1, max(0, (v - Double(s.virtualStart)) / span)) : 0
        return (Double(s.leftStart) + t * Double(s.leftCount), Double(s.rightStart) + t * Double(s.rightCount))
    }

    /// The virtual line position at which `line` of `side` sits.
    func virtualPosition(of line: Int, side: Side) -> Double {
        guard !segments.isEmpty else { return 0 }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = side == .left ? segments[mid].leftStart : segments[mid].rightStart
            if start <= line { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        let start = side == .left ? s.leftStart : s.rightStart
        let count = side == .left ? s.leftCount : s.rightCount
        guard count > 0 else { return Double(s.virtualStart) }
        let t = min(1, Double(line - start) / Double(count))
        return Double(s.virtualStart) + t * Double(s.span)
    }

    func virtualStart(ofHunk index: Int) -> Int {
        segments.first(where: { $0.hunk == index })?.virtualStart ?? 0
    }

    private func buildUnifiedRows() -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        rows.reserveCapacity(virtualLineCount + hunks.count * 4)
        for s in segments {
            if s.hunk < 0 {
                let common = min(s.leftCount, s.rightCount)
                for k in 0..<common {
                    rows.append(UnifiedRow(kind: .context, left: Int32(s.leftStart + k), right: Int32(s.rightStart + k), hunk: -1))
                }
                if s.leftCount < s.rightCount {
                    for k in common..<s.rightCount {
                        rows.append(UnifiedRow(kind: .context, left: -1, right: Int32(s.rightStart + k), hunk: -1))
                    }
                } else if s.rightCount < s.leftCount {
                    for k in common..<s.leftCount {
                        rows.append(UnifiedRow(kind: .context, left: Int32(s.leftStart + k), right: -1, hunk: -1))
                    }
                }
            } else {
                for k in 0..<s.leftCount {
                    rows.append(UnifiedRow(kind: .removed, left: Int32(s.leftStart + k), right: -1, hunk: Int32(s.hunk)))
                }
                for k in 0..<s.rightCount {
                    rows.append(UnifiedRow(kind: .added, left: -1, right: Int32(s.rightStart + k), hunk: Int32(s.hunk)))
                }
            }
        }
        return rows
    }

    /// First unified row belonging to a hunk.
    func unifiedRow(ofHunk index: Int) -> Int {
        unifiedRows.firstIndex(where: { $0.hunk == Int32(index) }) ?? 0
    }

    func unifiedRow(ofLine line: Int, side: Side) -> Int {
        let target = Int32(line)
        // Rows are sorted by line on each side, so a linear scan from an estimate is unnecessary; just search.
        var lo = 0, hi = unifiedRows.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            var probe = mid
            // Skip rows that have no line on the requested side.
            while probe <= hi, (side == .left ? unifiedRows[probe].left : unifiedRows[probe].right) < 0 { probe += 1 }
            if probe > hi { hi = mid - 1; continue }
            let value = side == .left ? unifiedRows[probe].left : unifiedRows[probe].right
            if value == target { return probe }
            if value < target { best = probe; lo = probe + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

// MARK: - Hunk parsing

enum DiffParser {
    /// Extracts hunks from unified diff output produced with `-U0`.
    static func parseHunks(_ data: Data) -> (hunks: [Hunk], binary: Bool) {
        var hunks: [Hunk] = []
        var binary = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            let n = buf.count
            var i = 0
            while i < n {
                var end = i
                while end < n, buf[end] != 0x0A { end += 1 }
                if end - i > 4, buf[i] == 0x40, buf[i + 1] == 0x40, buf[i + 2] == 0x20, buf[i + 3] == 0x2D { // "@@ -"
                    var p = i + 4
                    func number() -> Int {
                        var value = 0
                        while p < end, buf[p] >= 48, buf[p] <= 57 { value = value * 10 + Int(buf[p] - 48); p += 1 }
                        return value
                    }
                    let a = number()
                    var b = 1
                    if p < end, buf[p] == 0x2C { p += 1; b = number() }
                    while p < end, buf[p] != 0x2B { p += 1 } // '+'
                    p += 1
                    let c = number()
                    var d = 1
                    if p < end, buf[p] == 0x2C { p += 1; d = number() }
                    // With zero lines on a side, git reports the line *after which* the change sits.
                    hunks.append(Hunk(leftStart: b == 0 ? a : a - 1, leftCount: b,
                                      rightStart: d == 0 ? c : c - 1, rightCount: d))
                } else if end - i > 12, buf[i] == 0x42, buf[i + 1] == 0x69, buf[i + 2] == 0x6E, buf[i + 3] == 0x61 { // "Bina"
                    binary = true
                }
                i = end + 1
            }
        }
        return (hunks, binary)
    }
}

// MARK: - Word-level diff

enum InlineDiff {
    private enum TokenClass: UInt8 {
        case lineBreak
        case space
        case word
        case punct
    }

    private struct Token {
        var line: Int32
        var start: Int32
        var length: Int32
        var hash: UInt64
        var tokenClass: TokenClass
        var unit: UInt16

        var isSpace: Bool { tokenClass == .space || tokenClass == .lineBreak }
    }

    static let maxTokens = 3000

    private static func tokenize(_ lines: ArraySlice<String>) -> [Token]? {
        var tokens: [Token] = []
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                tokens.append(Token(
                    line: Int32(lineIndex - 1),
                    start: -1,
                    length: 0,
                    hash: 0x9E3779B97F4A7C15,
                    tokenClass: .lineBreak,
                    unit: 0
                ))
            }
            var start = 0
            var hash: UInt64 = 0xcbf29ce484222325
            var cls = -1 // 0 word, 1 space, 2 punct
            var firstUnit: UInt16 = 0
            var i = 0
            func flush(_ end: Int) {
                if cls >= 0, end > start {
                    let tokenClass: TokenClass = switch cls {
                    case 1: .space
                    case 2: .punct
                    default: .word
                    }
                    tokens.append(Token(
                        line: Int32(lineIndex),
                        start: Int32(start),
                        length: Int32(end - start),
                        hash: hash ^ UInt64(end - start),
                        tokenClass: tokenClass,
                        unit: firstUnit
                    ))
                }
                cls = -1
                hash = 0xcbf29ce484222325
                firstUnit = 0
            }
            for unit in line.utf16 {
                let c: Int
                if unit == 32 || unit == 9 {
                    c = 1
                } else if (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
                            || (unit >= 0x80 && unit < 0x2E80) || (unit >= 0xDC00 && unit <= 0xDFFF) {
                    c = 0
                } else {
                    c = 2 // punctuation and CJK: one token per unit
                }
                if c == 2 {
                    flush(i)
                    // A high surrogate starts a pair; let the low surrogate (class 0) join it.
                    start = i
                    firstUnit = unit
                    hash = (0xcbf29ce484222325 ^ UInt64(unit)) &* 0x100000001b3
                    if unit >= 0xD800 && unit <= 0xDBFF {
                        cls = 0
                    } else {
                        cls = 2
                        flush(i + 1)
                    }
                } else {
                    if c != cls { flush(i); start = i; cls = c; firstUnit = unit }
                    hash = (hash ^ UInt64(unit)) &* 0x100000001b3
                }
                i += 1
            }
            flush(i)
            if tokens.count > maxTokens { return nil }
        }
        return tokens
    }

    @inline(__always)
    private static func tokensEqual(_ a: Token, _ b: Token) -> Bool {
        a.hash == b.hash && a.length == b.length && a.tokenClass == b.tokenClass && a.unit == b.unit
    }

    @inline(__always)
    private static func isOpeningDelimiter(_ unit: UInt16) -> Bool {
        unit == 40 || unit == 91 || unit == 123 // '(', '[', '{'
    }

    @inline(__always)
    private static func isClosingDelimiter(_ unit: UInt16) -> Bool {
        unit == 41 || unit == 93 || unit == 125 // ')', ']', '}'
    }

    @inline(__always)
    private static func isSeparator(_ unit: UInt16) -> Bool {
        unit == 44 || unit == 59 || unit == 58 // ',', ';', ':'
    }

    /// Scores splitting between `left` and `right` for semantic lossless boundary shifting.
    private static func boundaryScore(left: Token?, right: Token?) -> Int {
        guard let l = left else {
            guard let r = right else { return 0 }
            if r.tokenClass == .lineBreak { return 100 }
            return r.tokenClass == .space ? 20 : 100
        }
        guard let r = right else {
            if l.tokenClass == .lineBreak { return 100 }
            return l.tokenClass == .space ? 20 : 100
        }
        if l.tokenClass == .lineBreak || r.tokenClass == .lineBreak {
            if l.tokenClass == .lineBreak && r.tokenClass == .lineBreak { return 100 }
            let other = l.tokenClass == .lineBreak ? r : l
            return other.tokenClass == .space ? 90 : 100
        }

        // Strongly prefer whitespace -> non-whitespace boundaries (e.g. "if " | "table")
        // over non-whitespace -> whitespace (e.g. "table" | " ").
        if l.isSpace != r.isSpace {
            if l.isSpace {
                switch r.tokenClass {
                case .word: return 50
                case .punct where isOpeningDelimiter(r.unit): return 48
                default: return 45
                }
            } else {
                return 10
            }
        }
        if l.isSpace && r.isSpace { return 0 }

        // Penalize breaking member-access chains, especially right after '.' (e.g. "B().").
        if r.tokenClass == .punct && r.unit == 46 {
            if l.tokenClass == .punct && isClosingDelimiter(l.unit) { return 20 }
            return l.tokenClass == .word ? -10 : -5
        }
        if l.tokenClass == .punct && l.unit == 46 {
            return r.tokenClass == .word ? -25 : -15
        }

        if l.tokenClass == .punct && isClosingDelimiter(l.unit) {
            return (r.tokenClass == .punct && isOpeningDelimiter(r.unit)) ? 35 : 25
        }
        if l.tokenClass == .punct && isSeparator(l.unit) { return 30 }
        if r.tokenClass == .punct && isSeparator(r.unit) { return 15 }
        if r.tokenClass == .punct && isOpeningDelimiter(r.unit) { return 25 }
        if l.tokenClass == .punct && isOpeningDelimiter(l.unit) { return 18 }
        if r.tokenClass == .punct && isClosingDelimiter(r.unit) { return 25 }

        if l.tokenClass != r.tokenClass { return 12 }
        return l.tokenClass == .punct ? -5 : 2
    }

    /// Shifts each unmatched run within its lossless equivalence window to the cleanest
    /// semantic boundary, returning the optimal replacement for `matched`.
    private static func shiftUnmatchedRuns<T>(
        _ items: [T],
        matched: inout [Bool],
        maxPasses: Int = 1,
        equals: (T, T) -> Bool,
        isValidBoundary: (Int) -> Bool = { _ in true },
        scoreBoundary: (T?, T?) -> Int
    ) {
        var pass = 0
        var coalesced = true
        while coalesced && pass < maxPasses {
            coalesced = false
            pass += 1
            var i = 0
            while i < items.count {
                guard !matched[i] else { i += 1; continue }
                let runStart = i
                var runEnd = i + 1
                while runEnd < items.count && !matched[runEnd] {
                    runEnd += 1
                }

                var minStart = runStart
                var minEnd = runEnd
                while minStart > 0 && matched[minStart - 1] && equals(items[minStart - 1], items[minEnd - 1]) {
                    minStart -= 1
                    minEnd -= 1
                }

                var maxStart = runStart
                var maxEnd = runEnd
                while maxEnd < items.count && matched[maxEnd] && equals(items[maxStart], items[maxEnd]) {
                    maxStart += 1
                    maxEnd += 1
                }

                if minStart < maxStart {
                    let len = runEnd - runStart
                    var bestStart = runStart
                    var bestScore = Int.min
                    for candStart in minStart...maxStart {
                        let candEnd = candStart + len
                        guard isValidBoundary(candStart) && isValidBoundary(candEnd) else { continue }
                        let score = scoreBoundary(
                            candStart > 0 ? items[candStart - 1] : nil,
                            items[candStart]
                        ) + scoreBoundary(
                            items[candEnd - 1],
                            candEnd < items.count ? items[candEnd] : nil
                        )
                        if score > bestScore {
                            bestScore = score
                            bestStart = candStart
                        }
                    }
                    let bestEnd = bestStart + len
                    if bestStart != runStart {
                        for k in runStart..<runEnd { matched[k] = true }
                        for k in bestStart..<bestEnd { matched[k] = false }
                        if (bestStart > 0 && !matched[bestStart - 1]) || (bestEnd < items.count && !matched[bestEnd]) {
                            coalesced = true
                        }
                    }
                    i = max(runEnd, bestEnd)
                } else {
                    i = runEnd
                }
            }
        }
    }

    private static func shiftMatchedRuns(tokens: [Token], matched: inout [Bool]) {
        shiftUnmatchedRuns(
            tokens,
            matched: &matched,
            maxPasses: 8,
            equals: tokensEqual,
            scoreBoundary: boundaryScore
        )
    }

    /// Shifts unmatched UTF-16 runs within their lossless equivalence window on single-token
    /// fallback lines (respecting surrogate pairs and preferring word/separator boundaries).
    static func shiftUTF16Runs(units: [UInt16], matched: inout [Bool]) {
        @inline(__always)
        func isLowSurrogate(_ u: UInt16) -> Bool { (0xDC00...0xDFFF).contains(u) }
        @inline(__always)
        func isWord(_ u: UInt16) -> Bool {
            (u >= 48 && u <= 57) || (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || u >= 0x80
        }
        @inline(__always)
        func isSpace(_ u: UInt16) -> Bool { u == 32 || u == 9 }

        func charBoundaryScore(left: UInt16?, right: UInt16?) -> Int {
            guard let l = left else {
                guard let r = right else { return 0 }
                return isSpace(r) ? 20 : 100
            }
            guard let r = right else {
                return isSpace(l) ? 20 : 100
            }
            if isSpace(l) != isSpace(r) {
                return isSpace(l) ? 50 : 10
            }
            if isSpace(l) && isSpace(r) { return 0 }
            if l == 95 && r != 95 { return 35 } // '_' | char
            if r == 95 && l != 95 { return 15 } // char | '_'
            if r == 46 { return isClosingDelimiter(l) ? 20 : (isWord(l) ? -10 : -5) }
            if l == 46 { return isWord(r) ? -25 : -15 }
            if isClosingDelimiter(l) { return isOpeningDelimiter(r) ? 35 : 25 }
            if isSeparator(l) { return 30 }
            if isSeparator(r) { return 15 }
            if isOpeningDelimiter(r) { return 25 }
            if isOpeningDelimiter(l) { return 18 }
            if isClosingDelimiter(r) { return 25 }
            if isWord(l) != isWord(r) { return 20 }
            // CamelCase boundary: lowercase followed by uppercase.
            if (97...122).contains(l) && (65...90).contains(r) { return 20 }
            if isWord(l) && isWord(r) { return -20 }
            return 0
        }

        shiftUnmatchedRuns(
            units,
            matched: &matched,
            equals: ==,
            isValidBoundary: { idx in
                !(idx > 0 && idx < units.count && isLowSurrogate(units[idx]))
            },
            scoreBoundary: charBoundaryScore
        )
    }

    /// Returns per-line changed ranges for both sides of a modified hunk, or nil when the
    /// two sides share nothing worth aligning (whole-line colouring says enough).
    static func compute(old: ArraySlice<String>, new: ArraySlice<String>) -> (old: [[Range<Int>]], new: [[Range<Int>]])? {
        guard let a = tokenize(old), let b = tokenize(new), !a.isEmpty, !b.isEmpty else { return nil }
        guard var (matchedA, matchedB) = Myers.matches(a.map(\.hash), b.map(\.hash), maxEdits: 600) else { return nil }

        var common = 0
        for (i, t) in a.enumerated() where matchedA[i] && !t.isSpace { common += 1 }
        if common == 0 { return nil }

        shiftMatchedRuns(tokens: a, matched: &matchedA)
        shiftMatchedRuns(tokens: b, matched: &matchedB)

        func ranges(_ tokens: [Token], _ matched: [Bool], lineCount: Int) -> [[Range<Int>]] {
            var result = [[Range<Int>]](repeating: [], count: lineCount)
            // Extent of each line's visible text, to spot lines that changed from end to end.
            var extents = [Range<Int>?](repeating: nil, count: lineCount)
            var open: (line: Int, start: Int, end: Int)?
            func close() {
                if let o = open { result[o.line].append(o.start..<o.end) }
                open = nil
            }
            for (i, t) in tokens.enumerated() {
                if t.start < 0 { close(); continue } // line break
                // Whitespace never starts or ends a range (re-indented code would otherwise light up
                // as solid blocks), but a space between two changed words is bridged so they merge.
                if t.isSpace { continue }
                let line = Int(t.line)
                let tokenEnd = Int(t.start + t.length)
                extents[line] = (extents[line]?.lowerBound ?? Int(t.start))..<tokenEnd
                if !matched[i] {
                    let end = Int(t.start + t.length)
                    if let o = open, o.line == line {
                        open = (line, o.start, end)
                    } else {
                        close()
                        open = (line, Int(t.start), end)
                    }
                } else {
                    close()
                }
            }
            close()
            // A line that differs in its entirety gains nothing from a second, darker highlight
            // on top of its band; keeping those lines plain makes the partial edits stand out.
            for line in 0..<lineCount where result[line].count == 1 && result[line][0] == extents[line] {
                result[line] = []
            }
            return result
        }
        return (ranges(a, matchedA, lineCount: old.count), ranges(b, matchedB, lineCount: new.count))
    }
}

/// Myers' O(ND) diff, used for word-level alignment inside a hunk.
enum Myers {
    /// Flags which elements of `a` and `b` belong to the longest common subsequence.
    /// Returns nil when more than `maxEdits` edits would be needed.
    static func matches<T: Equatable>(_ a: [T], _ b: [T], maxEdits: Int) -> (a: [Bool], b: [Bool])? {
        var matchedA = [Bool](repeating: false, count: a.count)
        var matchedB = [Bool](repeating: false, count: b.count)

        // Trim the common prefix and suffix; real edits are usually a small middle.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            matchedA[prefix] = true; matchedB[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            matchedA[a.count - 1 - suffix] = true; matchedB[b.count - 1 - suffix] = true
            suffix += 1
        }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        if n == 0 || m == 0 { return (matchedA, matchedB) }

        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var solvedAt = -1

        outer: for d in 0...limit {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { solvedAt = d; break outer }
                k += 2
            }
        }
        guard solvedAt >= 0 else { return nil }

        var x = n, y = m
        var d = solvedAt
        while d >= 0 {
            let snapshot = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && snapshot[offset + k - 1] < snapshot[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : snapshot[offset + prevK]
            let prevY = d == 0 ? 0 : prevX - prevK
            while x > prevX, y > prevY {
                x -= 1; y -= 1
                matchedA[prefix + x] = true
                matchedB[prefix + y] = true
            }
            x = prevX; y = prevY
            d -= 1
        }
        return (matchedA, matchedB)
    }
}

// MARK: - Loading

struct DiffRequest: Equatable {
    enum Source: Equatable {
        /// `base` (normally HEAD) against the working tree.
        case worktree(base: String)
        /// A commit against its first parent (nil parent means a root commit).
        case commit(hash: String, parent: String?)
        /// A plain file from the working tree, no comparison.
        case file
        /// An external read-only file opened via LSP navigation (sibling `go.work` repo, `$GOROOT`, `pkg/mod`…).
        case externalFile(displayPath: String, workspaceRoot: URL?)
    }

    var root: URL
    var path: String
    var oldPath: String?
    var kind: FileChange.Kind?
    var source: Source
    var ignoreWhitespace = false
    var semantic: SemanticDiffOptions = .default

    /// A local change as the Changes list has it: the working tree against HEAD, not against another commit.
    var isAgainstHead: Bool {
        if case .worktree(let base) = source { return base == "HEAD" || base == Git.emptyTree }
        return false
    }

    var isExternalFile: Bool {
        if case .externalFile = source { return true }
        return false
    }

    var fileURL: URL {
        root.appendingPathComponent(path)
    }

    /// True when the right side represents a live file on disk eligible for LSP semantic highlighting & navigation.
    var isLiveFile: Bool {
        switch source {
        case .file, .externalFile: return true
        case .worktree: return kind != .deleted
        case .commit: return false
        }
    }

    /// Repository or workspace root passed to `LSPManager` for workspace/go.work discovery.
    var lspRepoRoot: URL? {
        switch source {
        case .externalFile(_, let workspaceRoot): return workspaceRoot
        case .file, .worktree: return root
        case .commit: return nil
        }
    }

    /// Path shown in the viewer header (`<repo>/<relPath>` or `~/...` for external files).
    var displayPath: String {
        if case .externalFile(let display, _) = source { return display }
        return path
    }
}

enum DiffLoader {
    static let maxTextBytes = 12 * 1024 * 1024
    static let maxSpreadsheetBytes = 80 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "ico", "icns", "pdf"]

    static func isSpreadsheetPath(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".xlsx")
    }

    private static let scratch: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A directory of this process's own, removed when the app quits.
    static var scratchDirectory: URL { scratch }

    static func cleanup() {
        try? FileManager.default.removeItem(at: scratch)
    }

    static func load(_ request: DiffRequest, includedGroupHunks: Set<Int>? = nil) async -> DiffDocument {
        let started = DispatchTime.now()
        let doc = await build(request, includedGroupHunks: includedGroupHunks)
        doc.loadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return doc
    }

    private static func buildSpreadsheet(_ request: DiffRequest) async -> DiffDocument {
        let root = request.root
        let data: Data?

        switch request.source {
        case .file, .externalFile:
            data = readWorktree(root, request.path)
        case .worktree:
            if request.kind == .deleted {
                data = nil
            } else {
                data = readWorktree(root, request.path)
            }
        case .commit(let hash, let parent):
            if request.kind != .deleted,
               let newBlob = await Git.blob(rev: hash, path: request.path, in: root) {
                data = newBlob
            } else if let parent,
                      let oldBlob = await Git.blob(rev: parent, path: request.oldPath ?? request.path, in: root) {
                data = oldBlob
            } else {
                data = nil
            }
        }

        guard let spreadsheetData = data else {
            return .message(L("File deleted", "文件已删除"), detail: request.displayPath)
        }
        if spreadsheetData.count > maxSpreadsheetBytes {
            return .message(L("File too large to display", "文件过大，无法显示"), detail: spreadsheetData.count.byteSizeString)
        }

        do {
            let workbook = try await Task.detached(priority: .userInitiated) {
                try XLSXReader.parse(data: spreadsheetData)
            }.value
            return DiffDocument(
                left: .empty,
                right: .empty,
                hunks: [],
                language: .plain,
                content: .spreadsheet(workbook, fileURL: request.isLiveFile ? request.fileURL : nil),
                isPlainFile: true
            )
        } catch {
            return .message(L("Unable to open spreadsheet", "无法打开表格文件"), detail: error.localizedDescription)
        }
    }

    private static func readWorktree(_ root: URL, _ path: String) -> Data? {
        let url = root.appendingPathComponent(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func build(_ request: DiffRequest, includedGroupHunks: Set<Int>? = nil) async -> DiffDocument {
        if Self.isSpreadsheetPath(request.path) {
            return await buildSpreadsheet(request)
        }

        let root = request.root
        let language = LanguageSpec.detect(path: request.path)
        let ext = (request.path as NSString).pathExtension.lowercased()

        var oldData: Data?
        var newData: Data?
        var leftTitle = "", rightTitle = ""

        switch request.source {
        case .file, .externalFile:
            newData = readWorktree(root, request.path)
            guard let data = newData else {
                return .message(L("File not found", "文件不存在"), detail: request.displayPath)
            }
            if imageExtensions.contains(ext) {
                return DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain,
                                    content: .image(old: nil, new: data), isPlainFile: true)
            }
            if TextCodec.looksBinary(data) {
                return .message(L("Binary file", "二进制文件"), detail: data.count.byteSizeString)
            }
            if data.count > maxTextBytes {
                return .message(L("File too large to display", "文件过大，无法显示"), detail: data.count.byteSizeString)
            }
            if request.isExternalFile {
                let buffer = await makeBuffer(data, language)
                let doc = DiffDocument(left: .empty, right: buffer, hunks: [], language: language, isPlainFile: true)
                doc.editing = EditInfo(readOnlyReason: L("Read-only", "只读"))
                return doc
            }
            let (buffer, editing) = await makeWorktreeSide(data, language, url: root.appendingPathComponent(request.path), base: nil)
            let doc = DiffDocument(left: .empty, right: buffer, hunks: [], language: language, isPlainFile: true)
            doc.editing = editing
            return doc

        case .worktree(let base):
            let hasOld = request.kind != .added && request.kind != .untracked
            let hasNew = request.kind != .deleted
            async let old: Data? = hasOld ? Git.blob(rev: base, path: request.oldPath ?? request.path, in: root) : nil
            if hasNew { newData = readWorktree(root, request.path) }
            oldData = await old
            // A commit compared with is named by its short hash, as in a commit's own diff.
            switch base {
            case Git.emptyTree: leftTitle = L("Empty", "空")
            case ConflictBase.base.rev: leftTitle = L("Base (common ancestor)", "共同祖先")
            case ConflictBase.incoming.rev: leftTitle = L("Incoming", "传入的版本")
            default: leftTitle = base.count == 40 && base.allSatisfy(\.isHexDigit) ? String(base.prefix(7)) : base
            }
            rightTitle = request.kind == .conflicted ? L("Result (Working Tree)", "合并结果（工作区）") : L("Working Tree", "工作区")

        case .commit(let hash, let parent):
            let hasOld = request.kind != .added && parent != nil
            let hasNew = request.kind != .deleted
            async let old: Data? = hasOld ? Git.blob(rev: parent ?? "", path: request.oldPath ?? request.path, in: root) : nil
            async let new: Data? = hasNew ? Git.blob(rev: hash, path: request.path, in: root) : nil
            oldData = await old
            newData = await new
            leftTitle = parent.map { String($0.prefix(7)) } ?? L("Empty", "空")
            rightTitle = String(hash.prefix(7))
        }

        func finish(_ doc: DiffDocument) -> DiffDocument {
            doc.leftTitle = leftTitle
            doc.rightTitle = rightTitle
            return doc
        }

        if oldData == nil && newData == nil {
            return finish(.message(L("Nothing to show", "没有可显示的内容"),
                                   detail: L("The file does not exist on either side.", "文件在两侧都不存在。")))
        }
        if imageExtensions.contains(ext) {
            return finish(DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain,
                                       content: .image(old: oldData, new: newData)))
        }
        if (oldData.map(TextCodec.looksBinary) ?? false) || (newData.map(TextCodec.looksBinary) ?? false) {
            let sizes = [oldData?.count.byteSizeString, newData?.count.byteSizeString].compactMap { $0 }.joined(separator: " → ")
            return finish(.message(L("Binary file changed", "二进制文件有变化"), detail: sizes))
        }
        if max(oldData?.count ?? 0, newData?.count ?? 0) > maxTextBytes {
            return finish(.message(L("File too large to diff", "文件过大，无法比较"),
                                   detail: max(oldData?.count ?? 0, newData?.count ?? 0).byteSizeString))
        }

        // Optional JSON semantic normalization (pretty-printed, sorted keys). Silently falls back on parse failure.
        // Disabled while filtering an AI group so raw 0-based hunk indices match AIHunkGrouper verbatim.
        let semanticOptions = request.semantic
        let isGroupFilterActive = includedGroupHunks != nil
        let jsonResult: (old: Data?, new: Data?, normalized: Bool)
        if !isGroupFilterActive && semanticOptions.normalizeJSON && SemanticDiff.isJSONFile(language: language, path: request.path) {
            jsonResult = SemanticDiff.normalizeJSONPair(old: oldData, new: newData)
        } else {
            jsonResult = (oldData, newData, false)
        }
        let isJSONNormalized = jsonResult.normalized
        let oldBytes = jsonResult.old
        let newBytes = jsonResult.new

        var worktreeURL: URL?
        if case .worktree = request.source, newBytes != nil { worktreeURL = root.appendingPathComponent(request.path) }
        let url = worktreeURL

        if let groupFilter = includedGroupHunks {
            let shouldHighlight = max(oldBytes?.count ?? 0, newBytes?.count ?? 0) <= 4 * 1024 * 1024
            async let computedRawHunks: [Hunk]? = (oldBytes != nil && newBytes != nil)
                ? computeHunks(old: oldBytes, new: newBytes, ignoreWhitespace: false)
                : []
            let oldLines: [String]? = oldBytes.map { TextCodec.splitLines(TextCodec.decode($0)) }
            let newLines: [String]? = newBytes.map { TextCodec.splitLines(TextCodec.decode($0)) }
            let rightSpans: [[SyntaxSpan]]
            if let newLines, shouldHighlight {
                rightSpans = Highlighter.highlight(newLines, language: language)
            } else {
                rightSpans = []
            }

            let rawHunks: [Hunk]
            if oldBytes == nil {
                let count = newLines?.count ?? 0
                rawHunks = count == 0 ? [] : [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: count)]
                _ = await computedRawHunks
            } else if newBytes == nil {
                let count = oldLines?.count ?? 0
                rawHunks = count == 0 ? [] : [Hunk(leftStart: 0, leftCount: count, rightStart: 0, rightCount: 0)]
                _ = await computedRawHunks
            } else if let computed = await computedRawHunks {
                rawHunks = computed
            } else {
                return finish(.message(L("Could not compute diff", "无法计算差异"), detail: request.path))
            }

            let baseline = GroupFilterBaseline(
                oldLines: oldLines,
                newLines: newLines,
                rawHunks: rawHunks,
                rightSpans: rightSpans,
                shouldHighlight: shouldHighlight,
                hasWorktreeFile: url != nil
            )
            return buildGroupFiltered(
                baseline: baseline,
                includedGroupHunks: groupFilter,
                language: language,
                semanticOptions: semanticOptions,
                ignoreWhitespace: request.ignoreWhitespace,
                leftTitle: leftTitle,
                rightTitle: rightTitle
            )
        }

        // Decode and highlight both sides in parallel. The working tree side is read so that it can be edited
        // (except in JSON normalized view, where the right side stays read-only to avoid overwriting raw formatting).
        async let leftBuffer: TextBuffer = makeBuffer(oldBytes, language)
        async let rightSide: (TextBuffer, EditInfo?) = isJSONNormalized
            ? (await makeBuffer(newBytes, language),
               url != nil ? EditInfo(readOnlyReason: L("JSON normalized view · read-only", "JSON 语义归一化视图 · 只读")) : nil)
            : await makeRightSide(newBytes, language, worktree: url, base: oldBytes)
        async let rawHunks: [Hunk]? = computeHunks(old: oldBytes, new: newBytes, ignoreWhitespace: request.ignoreWhitespace)
        let left = await leftBuffer
        let (right, editing) = await rightSide

        var hunks: [Hunk]
        if oldBytes == nil {
            // A new file: every line is added. An empty one has nothing to show, though it has a line to type on.
            hunks = (newBytes?.isEmpty ?? true) ? [] : [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: right.lines.count)]
            _ = await rawHunks
        } else if newBytes == nil {
            hunks = left.lines.isEmpty ? [] : [Hunk(leftStart: 0, leftCount: left.lines.count, rightStart: 0, rightCount: 0)]
            _ = await rawHunks
        } else if let computed = await rawHunks {
            hunks = computed
        } else {
            return finish(.message(L("Could not compute diff", "无法计算差异"), detail: request.path))
        }

        let processed = applySemanticPostProcessing(
            hunks: hunks,
            left: left,
            right: right,
            language: language,
            options: semanticOptions,
            bothSidesExist: oldBytes != nil && newBytes != nil
        )

        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: processed.hunks,
            language: language,
            hiddenCommentHunks: processed.hiddenCommentHunks
        )
        doc.semanticOptions = semanticOptions
        doc.isJSONNormalized = isJSONNormalized
        doc.setRenameGroups(processed.renameGroups)
        doc.editing = editing
        if !isJSONNormalized && !request.ignoreWhitespace {
            doc.groupFilterBaseline = GroupFilterBaseline(
                oldLines: oldBytes != nil ? left.lines : nil,
                newLines: newBytes != nil ? right.lines : nil,
                rawHunks: hunks,
                rightSpans: right.spans,
                shouldHighlight: max(oldBytes?.count ?? 0, newBytes?.count ?? 0) <= 4 * 1024 * 1024,
                hasWorktreeFile: url != nil
            )
        }
        doc.note = note(
            hunks: doc.hunks,
            old: oldData,
            new: newData,
            ignoreWhitespace: request.ignoreWhitespace,
            hiddenCommentHunkCount: doc.hiddenCommentHunkCount,
            isJSONNormalized: isJSONNormalized
        )
        return finish(doc)
    }

    /// Builds a read-only, content-level AI group-filtered `DiffDocument` synchronously from an
    /// already-loaded `GroupFilterBaseline` (zero disk I/O or git subprocesses).
    static func buildGroupFiltered(
        baseline: GroupFilterBaseline,
        includedGroupHunks: Set<Int>,
        language: LanguageSpec,
        semanticOptions: SemanticDiffOptions,
        ignoreWhitespace: Bool,
        leftTitle: String,
        rightTitle: String
    ) -> DiffDocument {
        let left: TextBuffer
        let right: TextBuffer
        var filteredHunks: [Hunk]
        var rawToFiltered: [Int: Int]
        let bothSidesExist: Bool

        if let oldLines = baseline.oldLines, let newLines = baseline.newLines {
            let result = SemanticDiff.applyGroupHunkFilter(
                oldLines: oldLines,
                newLines: newLines,
                rawHunks: baseline.rawHunks,
                includedHunkIndices: includedGroupHunks
            )
            left = TextBuffer(lines: result.filteredOldLines)
            if baseline.shouldHighlight {
                left.spans = Highlighter.highlight(left.lines, language: language)
            }
            right = TextBuffer(lines: newLines)
            if baseline.rightSpans.count == newLines.count {
                right.spans = baseline.rightSpans
            } else if baseline.shouldHighlight {
                right.spans = Highlighter.highlight(newLines, language: language)
            }
            filteredHunks = result.filteredHunks
            rawToFiltered = result.rawToFilteredIndex
            bothSidesExist = true
        } else if let newLines = baseline.newLines {
            // Added / untracked file: single raw hunk at index 0.
            right = TextBuffer(lines: newLines)
            if baseline.rightSpans.count == newLines.count {
                right.spans = baseline.rightSpans
            } else if baseline.shouldHighlight {
                right.spans = Highlighter.highlight(newLines, language: language)
            }
            if !newLines.isEmpty && includedGroupHunks.contains(0) {
                left = .empty
                filteredHunks = [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: newLines.count)]
                rawToFiltered = [0: 0]
                bothSidesExist = false
            } else {
                left = TextBuffer(lines: newLines)
                left.spans = right.spans
                filteredHunks = []
                rawToFiltered = [:]
                bothSidesExist = true
            }
        } else if let oldLines = baseline.oldLines {
            // Deleted file: single raw hunk at index 0.
            right = .empty
            if !oldLines.isEmpty && includedGroupHunks.contains(0) {
                left = TextBuffer(lines: oldLines)
                if baseline.shouldHighlight {
                    left.spans = Highlighter.highlight(oldLines, language: language)
                }
                filteredHunks = [Hunk(leftStart: 0, leftCount: oldLines.count, rightStart: 0, rightCount: 0)]
                rawToFiltered = [0: 0]
            } else {
                left = .empty
                filteredHunks = []
                rawToFiltered = [:]
            }
            bothSidesExist = false
        } else {
            left = .empty
            right = .empty
            filteredHunks = []
            rawToFiltered = [:]
            bothSidesExist = false
        }

        // Apply ignore-whitespace filtering on kept hunks while preserving raw -> filtered index mapping.
        if ignoreWhitespace && bothSidesExist && !filteredHunks.isEmpty {
            var kept: [Hunk] = []
            var oldFilteredToNewFiltered: [Int: Int] = [:]
            for (idx, h) in filteredHunks.enumerated() {
                if !isWhitespaceOnlyHunk(h, leftLines: left.lines, rightLines: right.lines) {
                    oldFilteredToNewFiltered[idx] = kept.count
                    kept.append(h)
                }
            }
            filteredHunks = kept
            var remapped: [Int: Int] = [:]
            for (rawIdx, oldFIdx) in rawToFiltered {
                if let newFIdx = oldFilteredToNewFiltered[oldFIdx] {
                    remapped[rawIdx] = newFIdx
                }
            }
            rawToFiltered = remapped
        }

        let processed = applySemanticPostProcessingWithMapping(
            hunks: filteredHunks,
            left: left,
            right: right,
            language: language,
            options: semanticOptions,
            bothSidesExist: bothSidesExist
        )

        var inputToFinal: [Int: Int] = [:]
        inputToFinal.reserveCapacity(processed.keptInputIndices.count)
        for (finalIdx, inputIdx) in processed.keptInputIndices.enumerated() {
            // Preserve the first sub-hunk index when `detectMoves` splits one input hunk into multiple sub-hunks.
            if inputToFinal[inputIdx] == nil {
                inputToFinal[inputIdx] = finalIdx
            }
        }
        var finalRawToFiltered: [Int: Int] = [:]
        finalRawToFiltered.reserveCapacity(rawToFiltered.count)
        for (rawIdx, filteredIdx) in rawToFiltered {
            if let finalIdx = inputToFinal[filteredIdx] {
                finalRawToFiltered[rawIdx] = finalIdx
            }
        }

        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: processed.hunks,
            language: language,
            hiddenCommentHunks: processed.hiddenCommentHunks
        )
        doc.leftTitle = leftTitle
        doc.rightTitle = rightTitle
        doc.semanticOptions = semanticOptions
        doc.isJSONNormalized = false
        doc.isGroupFiltered = true
        doc.groupHunkIndexMap = finalRawToFiltered
        doc.groupFilterBaseline = baseline
        doc.setRenameGroups(processed.renameGroups)
        if baseline.hasWorktreeFile {
            doc.editing = EditInfo(readOnlyReason: L("Group view · read-only", "分组视图 · 只读"))
        }
        doc.note = note(
            hunks: doc.hunks,
            old: nil,
            new: nil,
            ignoreWhitespace: ignoreWhitespace,
            hiddenCommentHunkCount: doc.hiddenCommentHunkCount,
            isJSONNormalized: false,
            isGroupFiltered: true
        )
        return doc
    }

    private static func isWhitespaceOnlyHunk(_ hunk: Hunk, leftLines: [String], rightLines: [String]) -> Bool {
        guard hunk.leftCount == hunk.rightCount,
              hunk.leftStart >= 0, hunk.rightStart >= 0,
              hunk.leftStart + hunk.leftCount <= leftLines.count,
              hunk.rightStart + hunk.rightCount <= rightLines.count else {
            return false
        }
        for offset in 0..<hunk.leftCount {
            let l = leftLines[hunk.leftStart + offset].utf8.filter { $0 != 32 && $0 != 9 && $0 != 13 }
            let r = rightLines[hunk.rightStart + offset].utf8.filter { $0 != 32 && $0 != 9 && $0 != 13 }
            if l != r { return false }
        }
        return true
    }

    /// Runs comment-only hunk filtering, inline word highlights, intra-file move detection,
    /// and cross-hunk rename detection on raw line hunks without modifying the underlying buffers.
    static func applySemanticPostProcessing(
        hunks rawHunks: [Hunk],
        left: TextBuffer,
        right: TextBuffer,
        language: LanguageSpec,
        options: SemanticDiffOptions,
        bothSidesExist: Bool = true
    ) -> (hunks: [Hunk], hiddenCommentHunks: [Hunk], renameGroups: [RenameGroup]) {
        let result = applySemanticPostProcessingWithMapping(
            hunks: rawHunks,
            left: left,
            right: right,
            language: language,
            options: options,
            bothSidesExist: bothSidesExist
        )
        return (result.hunks, result.hiddenCommentHunks, result.renameGroups)
    }

    private static func applySemanticPostProcessingWithMapping(
        hunks rawHunks: [Hunk],
        left: TextBuffer,
        right: TextBuffer,
        language: LanguageSpec,
        options: SemanticDiffOptions,
        bothSidesExist: Bool = true
    ) -> (hunks: [Hunk], hiddenCommentHunks: [Hunk], renameGroups: [RenameGroup], keptInputIndices: [Int]) {
        var hunks = rawHunks
        var hiddenCommentHunks: [Hunk] = []
        var keptInputIndices = Array(rawHunks.indices)

        if options.ignoreComments && bothSidesExist && !hunks.isEmpty {
            let leftSpans = left.spans.count == left.lines.count
                ? left.spans
                : Highlighter.highlight(left.lines, language: language)
            let rightSpans = right.spans.count == right.lines.count
                ? right.spans
                : Highlighter.highlight(right.lines, language: language)
            var kept: [Hunk] = []
            var keptIndices: [Int] = []
            kept.reserveCapacity(hunks.count)
            keptIndices.reserveCapacity(hunks.count)
            for (idx, hunk) in hunks.enumerated() {
                if SemanticDiff.isCommentOnlyHunk(
                    hunk,
                    leftLines: left.lines,
                    rightLines: right.lines,
                    leftSpans: leftSpans,
                    rightSpans: rightSpans
                ) {
                    hiddenCommentHunks.append(hunk)
                } else {
                    kept.append(hunk)
                    keptIndices.append(idx)
                }
            }
            hunks = kept
            keptInputIndices = keptIndices
        }

        addInlineHighlights(&hunks, left: left.lines, right: right.lines)

        if options.detectMoves && hunks.count >= 2 {
            let postToPre = SemanticDiff.detectMoves(in: &hunks, leftLines: left.lines, rightLines: right.lines, language: language)
            if postToPre.count == hunks.count {
                keptInputIndices = postToPre.map { keptInputIndices[$0] }
            }
        }

        let renameGroups: [RenameGroup] = options.detectRenames
            ? SemanticDiff.detectRenames(hunks: hunks, leftLines: left.lines, rightLines: right.lines, language: language)
            : []

        return (hunks, hiddenCommentHunks, renameGroups, keptInputIndices)
    }

    /// Word-level highlights for the changed lines of each modified hunk (left alone above 200 lines a side).
    static func addInlineHighlights(_ hunks: inout [Hunk], left: [String], right: [String]) {
        for index in hunks.indices where hunks[index].kind == .modified {
            let h = hunks[index]
            guard h.leftCount <= 200, h.rightCount <= 200,
                  h.leftStart + h.leftCount <= left.count, h.rightStart + h.rightCount <= right.count,
                  let inline = InlineDiff.compute(old: left[h.leftStart..<(h.leftStart + h.leftCount)],
                                                  new: right[h.rightStart..<(h.rightStart + h.rightCount)]) else { continue }
            hunks[index].leftInline = inline.old
            hunks[index].rightInline = inline.new
        }
    }

    /// Said over a diff with no differences in it, when both sides exist. The lines can be the same while the bytes
    /// are not: line endings git converts (`core.autocrlf`), or the same text in another encoding.
    static func note(
        hunks: [Hunk],
        old: Data?,
        new: Data?,
        ignoreWhitespace: Bool,
        hiddenCommentHunkCount: Int = 0,
        isJSONNormalized: Bool = false,
        isGroupFiltered: Bool = false
    ) -> String? {
        guard hunks.isEmpty else { return nil }
        if isGroupFiltered {
            if hiddenCommentHunkCount > 0 { return L("Only comments differ", "仅注释不同") }
            return L("No changes in this group", "当前分组在此文件中没有改动")
        }
        guard let old, let new else { return nil }
        if old == new { return L("Contents are identical", "内容完全相同") }
        if hiddenCommentHunkCount > 0 { return L("Only comments differ", "仅注释不同") }
        if isJSONNormalized { return L("JSON structures are semantically identical", "JSON 语义结构完全一致") }
        return ignoreWhitespace ? L("Only whitespace differs", "仅空白字符不同")
                                : L("Only line endings or encoding differ", "仅换行符或编码不同")
    }

    private static func makeRightSide(_ data: Data?, _ language: LanguageSpec, worktree url: URL?, base: Data?) async -> (TextBuffer, EditInfo?) {
        if let data, let url { return await makeWorktreeSide(data, language, url: url, base: base) }
        return (await makeBuffer(data, language), nil)
    }

    /// The working tree side of a document: decoded so that it can be written back where that is possible,
    /// and highlighted keeping the lexer states that editing needs. Otherwise read as any other side, with the reason.
    private static func makeWorktreeSide(_ data: Data, _ language: LanguageSpec, url: URL, base: Data?) async -> (TextBuffer, EditInfo?) {
        var info = EditInfo()
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            info.readOnlyReason = L("A symbolic link · read-only", "符号链接 · 只读")
        } else if !FileManager.default.isWritableFile(atPath: url.path) {
            // Read-only permissions, or locked in the Finder.
            info.readOnlyReason = L("No permission to write it · read-only", "没有写入权限 · 只读")
        } else if data.count > TextEditing.maxEditableBytes {
            info.readOnlyReason = L("Larger than 4 MB · read-only", "文件超过 4 MB · 只读")
        } else if let text = TextCodec.decodeForEditing(data) {
            if text.lines.contains(where: { $0.utf8.count > TextEditing.maxLineBytes }) {
                info.readOnlyReason = L("Has lines too long to edit · read-only", "有过长的行 · 只读")
            } else {
                info.format = text.format
                info.crlf = text.crlf
                info.fingerprint = TextCodec.fingerprint(data)
                info.base = base
                let buffer = TextBuffer(lines: text.lines)
                let colours = Highlighter.highlightTracking(text.lines, language: language)
                buffer.spans = colours.spans
                buffer.states = colours.states
                return (buffer, info)
            }
        } else {
            info.readOnlyReason = L("Its encoding cannot be written back exactly · read-only", "编码无法原样写回 · 只读")
        }
        return (await makeBuffer(data, language), info)
    }

    private static func makeBuffer(_ data: Data?, _ language: LanguageSpec) async -> TextBuffer {
        guard let data else { return .empty }
        let buffer = TextBuffer(lines: TextCodec.splitLines(TextCodec.decode(data)))
        if data.count <= 4 * 1024 * 1024 {
            buffer.spans = Highlighter.highlight(buffer.lines, language: language)
        }
        return buffer
    }

    /// Line-level hunks via `git diff --no-index` on the exact bytes being displayed, so the
    /// hunks always agree with the text on screen regardless of filters, renames or repo state.
    /// Nil when git could not compare them.
    /// - Parameter environment: added to git's (tests give it settings of their own).
    static func computeHunks(old: Data?, new: Data?, ignoreWhitespace: Bool,
                             environment: [String: String] = [:]) async -> [Hunk]? {
        guard var old, var new else { return [] }
        if old == new { return [] }
        // Git takes UTF-16 for binary (it is full of zero bytes). As UTF-8 the lines are the same lines.
        if HunkPatch.isUTF16(old) || HunkPatch.isUTF16(new) {
            old = Data(TextCodec.decode(old).utf8)
            new = Data(TextCodec.decode(new).utf8)
            if old == new { return [] }
        }
        let id = UUID().uuidString
        let a = scratch.appendingPathComponent("\(id).a"), b = scratch.appendingPathComponent("\(id).b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try old.write(to: a)
            try new.write(to: b)
        } catch {
            return nil
        }
        // DiffCode shows these files as text. The user's own gitattributes still apply to them: without `--text` a
        // rule such as `*.a binary` (in common templates) has git call them binary, and a textconv driver would compare
        // something else than what is shown.
        var args = ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "-U0",
                    "--diff-algorithm=histogram"]
        if ignoreWhitespace { args.append("-w") }
        args += [a.lastPathComponent, b.lastPathComponent]
        guard let output = try? await Git.run(args, in: scratch, okStatuses: [0, 1], environment: environment) else { return nil }
        let parsed = DiffParser.parseHunks(output)
        // Files git did not compare line by line are not files without differences.
        return parsed.binary ? nil : parsed.hunks
    }
}
