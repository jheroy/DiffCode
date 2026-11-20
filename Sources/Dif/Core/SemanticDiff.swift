import Foundation

// MARK: - Options

/// Configuration for Stage 1 SemanticDiff features (pure Swift, zero external dependencies,
/// compatible with both Direct and AppStore editions).
struct SemanticDiffOptions: Equatable, Hashable, Sendable {
    /// Hide hunks whose left and right sides are identical once `.comment` spans and whitespace are stripped.
    var ignoreComments: Bool = false
    /// Canonically pretty-print & sort keys of JSON documents before diffing (falls back silently on invalid JSON).
    var normalizeJSON: Bool = false
    /// Pair deleted and added blocks that were moved (exact or slightly modified) within the same file.
    var detectMoves: Bool = true
    /// Group repeated consistent identifier renames across modified hunks for coordinated highlighting.
    var detectRenames: Bool = true
    /// Collapse long unchanged runs into interactive fold bars in `DiffDisplayMap`.
    var collapseUnchanged: Bool = false
    /// Number of unchanged context lines preserved above and below each changed hunk when folding.
    var collapseContextLines: Int = 3
    /// Minimum hidden lines required before emitting a fold bar (avoids tiny folds).
    var collapseMinHiddenLines: Int = 6

    static let `default` = SemanticDiffOptions()

    static let disabled = SemanticDiffOptions(
        ignoreComments: false,
        normalizeJSON: false,
        detectMoves: false,
        detectRenames: false,
        collapseUnchanged: false
    )
}

// MARK: - Move Detection Types

/// Whether a moved hunk is the original deleted block or the relocated added block.
enum MoveRole: String, Equatable, Hashable, Sendable {
    case source
    case target
}

/// Word-level inline diff ranges between a moved source block and its relocated target block.
struct MoveInlineDiff: Equatable, Sendable {
    /// Changed UTF-16 ranges per line of the source (deleted) block.
    var source: [[Range<Int>]]
    /// Changed UTF-16 ranges per line of the target (added) block.
    var target: [[Range<Int>]]
}

/// Metadata attached to a `Hunk` paired by intra-file move detection.
struct HunkMoveInfo: Equatable, Sendable {
    /// Stable 0-based identifier shared by the source and target hunks of the same move pair.
    var pairID: Int
    var role: MoveRole
    /// Index of the paired hunk in `DiffDocument.hunks`.
    var counterpartHunkIndex: Int
    /// Similarity score in `0.0...1.0` (`1.0` for exact normalized move).
    var similarity: Double
    /// Fine-grained word-level differences between source and target when the moved block was also edited.
    var inlineDiff: MoveInlineDiff?
}

// MARK: - Rename Detection Types

/// One highlighted occurrence of a cross-hunk identifier rename.
struct RenameOccurrence: Equatable, Hashable, Sendable {
    var hunkIndex: Int
    var side: Side
    /// 0-based line index in the corresponding `TextBuffer`.
    var lineIndex: Int
    /// UTF-16 character range within `lineIndex`.
    var range: Range<Int>
    var groupID: Int
    var colorIndex: Int
}

/// A consistent identifier rename (`oldName -> newName`) detected across a file's modified hunks.
struct RenameGroup: Identifiable, Equatable, Hashable, Sendable {
    /// Number of distinct accent slots available for coordinated rename coloring in the UI.
    static let paletteCount = 6

    var id: Int
    var oldName: String
    var newName: String
    var colorIndex: Int
    /// Number of paired replacement sites across the file.
    var occurrenceCount: Int
    /// Sorted unique hunk indices where this rename appears.
    var hunkIndices: [Int]
    /// Concrete left/right highlight spans for every paired occurrence.
    var occurrences: [RenameOccurrence]
}

/// O(1) lookup tables for `RenameGroup` queries used by `CodeCanvasView`.
struct SemanticRenameIndex: Equatable, Sendable {
    struct SpanKey: Hashable, Sendable {
        var hunkIndex: Int
        var side: Side
        var lineIndex: Int
        var range: Range<Int>
    }

    struct PairKey: Hashable, Sendable {
        var oldName: String
        var newName: String
    }

    struct LineKey: Hashable, Sendable {
        var side: Side
        var lineIndex: Int
    }

    static let empty = SemanticRenameIndex(groups: [])

    private let colorBySpan: [SpanKey: Int]
    private let groupByPair: [PairKey: RenameGroup]
    private let occurrencesByLine: [LineKey: [RenameOccurrence]]

    init(groups: [RenameGroup]) {
        var bySpan: [SpanKey: Int] = [:]
        var byPair: [PairKey: RenameGroup] = [:]
        var byLine: [LineKey: [RenameOccurrence]] = [:]
        byPair.reserveCapacity(groups.count)

        for group in groups {
            byPair[PairKey(oldName: group.oldName, newName: group.newName)] = group
            for occ in group.occurrences {
                let spanKey = SpanKey(
                    hunkIndex: occ.hunkIndex,
                    side: occ.side,
                    lineIndex: occ.lineIndex,
                    range: occ.range
                )
                bySpan[spanKey] = group.colorIndex
                let lineKey = LineKey(side: occ.side, lineIndex: occ.lineIndex)
                byLine[lineKey, default: []].append(occ)
            }
        }
        self.colorBySpan = bySpan
        self.groupByPair = byPair
        self.occurrencesByLine = byLine
    }

    func colorIndex(hunkIndex: Int, side: Side, lineIndex: Int, range: Range<Int>) -> Int? {
        colorBySpan[SpanKey(hunkIndex: hunkIndex, side: side, lineIndex: lineIndex, range: range)]
    }

    func colorIndex(oldName: String, newName: String) -> Int? {
        groupByPair[PairKey(oldName: oldName, newName: newName)]?.colorIndex
    }

    func group(oldName: String, newName: String) -> RenameGroup? {
        groupByPair[PairKey(oldName: oldName, newName: newName)]
    }

    func occurrences(side: Side, lineIndex: Int) -> [RenameOccurrence] {
        occurrencesByLine[LineKey(side: side, lineIndex: lineIndex)] ?? []
    }
}

// MARK: - Unchanged Code Folding & Display Mapping

/// Describes a collapsed span of unchanged lines inside a single `DiffDocument.segments` entry.
struct DiffFoldRegion: Equatable, Hashable, Sendable {
    /// Index into `DiffDocument.segments`.
    var segmentIndex: Int
    /// 0-based hidden line range in the left buffer.
    var leftRange: Range<Int>
    /// 0-based hidden line range in the right buffer.
    var rightRange: Range<Int>
    /// Number of hidden display rows (`max(leftRange.count, rightRange.count)`).
    var hiddenLineCount: Int
}

/// One row rendered by a diff canvas when unchanged-region folding is supported.
enum DisplayRow: Equatable, Sendable {
    case line(left: Int?, right: Int?, hunkIndex: Int?, segmentIndex: Int)
    case foldBar(DiffFoldRegion)
}

/// Lightweight bidirectional mapping between `DiffDocument` lines/hunks/segments and visible `DisplayRow`s.
struct DiffDisplayMap: Equatable, Sendable {
    private struct SegmentEntry: Equatable, Sendable {
        var segmentIndex: Int
        var leftStart: Int
        var leftCount: Int
        var rightStart: Int
        var rightCount: Int
        var rowStart: Int
        var rowCount: Int
        var foldRowIndex: Int?
        var foldRegion: DiffFoldRegion?
    }

    let rows: [DisplayRow]
    let foldRegions: [DiffFoldRegion]
    let totalHiddenLines: Int

    private let entries: [SegmentEntry]
    private let hunkToRow: [Int: Int]

    var totalRowCount: Int { rows.count }

    init(
        document: DiffDocument,
        expandedSegments: Set<Int> = [],
        collapseEnabled: Bool,
        contextLines: Int = 3,
        minHiddenLines: Int = 6
    ) {
        self.init(
            segments: document.segments,
            hunkCount: document.hunks.count,
            isPlainFile: document.isPlainFile,
            expandedSegments: expandedSegments,
            collapseEnabled: collapseEnabled,
            contextLines: contextLines,
            minHiddenLines: minHiddenLines
        )
    }

    init(
        segments: [Segment],
        hunkCount: Int,
        isPlainFile: Bool = false,
        expandedSegments: Set<Int> = [],
        collapseEnabled: Bool,
        contextLines: Int = 3,
        minHiddenLines: Int = 6
    ) {
        let context = max(0, contextLines)
        let minHidden = max(1, minHiddenLines)
        let canCollapse = collapseEnabled && !isPlainFile && hunkCount > 0

        // Precompute whether any changed hunk precedes / follows each segment index.
        var hasHunkBefore = [Bool](repeating: false, count: segments.count)
        var seenBefore = false
        for i in segments.indices {
            hasHunkBefore[i] = seenBefore
            if segments[i].hunk >= 0 { seenBefore = true }
        }
        var hasHunkAfter = [Bool](repeating: false, count: segments.count)
        var seenAfter = false
        for i in segments.indices.reversed() {
            hasHunkAfter[i] = seenAfter
            if segments[i].hunk >= 0 { seenAfter = true }
        }

        var rows: [DisplayRow] = []
        var foldRegions: [DiffFoldRegion] = []
        var entries: [SegmentEntry] = []
        var hunkToRow: [Int: Int] = [:]
        var hiddenTotal = 0

        entries.reserveCapacity(segments.count)
        hunkToRow.reserveCapacity(hunkCount)

        for (segIndex, seg) in segments.enumerated() {
            let rowStart = rows.count
            let totalSpan = seg.span

            if seg.hunk >= 0 {
                hunkToRow[seg.hunk] = rowStart
                for k in 0..<totalSpan {
                    let l: Int? = k < seg.leftCount ? seg.leftStart + k : nil
                    let r: Int? = k < seg.rightCount ? seg.rightStart + k : nil
                    rows.append(.line(left: l, right: r, hunkIndex: seg.hunk, segmentIndex: segIndex))
                }
                entries.append(SegmentEntry(
                    segmentIndex: segIndex,
                    leftStart: seg.leftStart,
                    leftCount: seg.leftCount,
                    rightStart: seg.rightStart,
                    rightCount: seg.rightCount,
                    rowStart: rowStart,
                    rowCount: rows.count - rowStart,
                    foldRowIndex: nil,
                    foldRegion: nil
                ))
                continue
            }

            let leadingContext = hasHunkBefore[segIndex] ? context : 0
            let trailingContext = hasHunkAfter[segIndex] ? context : 0
            let foldStart = leadingContext
            let foldEnd = totalSpan - trailingContext
            let hiddenCount = foldEnd - foldStart

            if canCollapse && !expandedSegments.contains(segIndex) && hiddenCount >= minHidden {
                for k in 0..<foldStart {
                    let l: Int? = k < seg.leftCount ? seg.leftStart + k : nil
                    let r: Int? = k < seg.rightCount ? seg.rightStart + k : nil
                    rows.append(.line(left: l, right: r, hunkIndex: nil, segmentIndex: segIndex))
                }

                let leftFoldStart = min(seg.leftCount, foldStart)
                let leftFoldEnd = min(seg.leftCount, foldEnd)
                let rightFoldStart = min(seg.rightCount, foldStart)
                let rightFoldEnd = min(seg.rightCount, foldEnd)

                let region = DiffFoldRegion(
                    segmentIndex: segIndex,
                    leftRange: (seg.leftStart + leftFoldStart)..<(seg.leftStart + leftFoldEnd),
                    rightRange: (seg.rightStart + rightFoldStart)..<(seg.rightStart + rightFoldEnd),
                    hiddenLineCount: hiddenCount
                )
                let foldRowIdx = rows.count
                rows.append(.foldBar(region))
                foldRegions.append(region)
                hiddenTotal += hiddenCount

                for k in foldEnd..<totalSpan {
                    let l: Int? = k < seg.leftCount ? seg.leftStart + k : nil
                    let r: Int? = k < seg.rightCount ? seg.rightStart + k : nil
                    rows.append(.line(left: l, right: r, hunkIndex: nil, segmentIndex: segIndex))
                }

                entries.append(SegmentEntry(
                    segmentIndex: segIndex,
                    leftStart: seg.leftStart,
                    leftCount: seg.leftCount,
                    rightStart: seg.rightStart,
                    rightCount: seg.rightCount,
                    rowStart: rowStart,
                    rowCount: rows.count - rowStart,
                    foldRowIndex: foldRowIdx,
                    foldRegion: region
                ))
            } else {
                for k in 0..<totalSpan {
                    let l: Int? = k < seg.leftCount ? seg.leftStart + k : nil
                    let r: Int? = k < seg.rightCount ? seg.rightStart + k : nil
                    rows.append(.line(left: l, right: r, hunkIndex: nil, segmentIndex: segIndex))
                }
                entries.append(SegmentEntry(
                    segmentIndex: segIndex,
                    leftStart: seg.leftStart,
                    leftCount: seg.leftCount,
                    rightStart: seg.rightStart,
                    rightCount: seg.rightCount,
                    rowStart: rowStart,
                    rowCount: rows.count - rowStart,
                    foldRowIndex: nil,
                    foldRegion: nil
                ))
            }
        }

        self.rows = rows
        self.foldRegions = foldRegions
        self.totalHiddenLines = hiddenTotal
        self.entries = entries
        self.hunkToRow = hunkToRow
    }

    func row(at displayIndex: Int) -> DisplayRow? {
        guard rows.indices.contains(displayIndex) else { return nil }
        return rows[displayIndex]
    }

    func lineNumber(at displayIndex: Int, side: Side) -> Int? {
        guard case .line(let left, let right, _, _) = row(at: displayIndex) else { return nil }
        return side == .left ? left : right
    }

    func foldRegion(at displayIndex: Int) -> DiffFoldRegion? {
        guard case .foldBar(let region) = row(at: displayIndex) else { return nil }
        return region
    }

    func displayRow(forHunk hunkIndex: Int) -> Int? {
        hunkToRow[hunkIndex]
    }

    func displayRowRange(forSegment segmentIndex: Int) -> Range<Int>? {
        guard entries.indices.contains(segmentIndex) else { return nil }
        let e = entries[segmentIndex]
        return e.rowStart..<(e.rowStart + e.rowCount)
    }

    /// Returns the display row index containing `line` on `side`.
    /// When `line` is currently collapsed, returns the display row index of its `.foldBar`.
    func displayRow(forLine line: Int, side: Side) -> Int? {
        guard line >= 0, let entry = entry(containingLine: line, side: side) else { return nil }
        let start = side == .left ? entry.leftStart : entry.rightStart
        let count = side == .left ? entry.leftCount : entry.rightCount
        guard count > 0, line >= start, line < start + count else { return nil }

        if let region = entry.foldRegion, let foldRow = entry.foldRowIndex {
            let foldRange = side == .left ? region.leftRange : region.rightRange
            if foldRange.contains(line) {
                return foldRow
            }
            if line < foldRange.lowerBound {
                return entry.rowStart + (line - start)
            }
            return foldRow + 1 + (line - foldRange.upperBound)
        }
        return entry.rowStart + (line - start)
    }

    /// True when `line` on `side` is currently hidden inside a collapsed `.foldBar`.
    func isLineHidden(_ line: Int, side: Side) -> Bool {
        foldRegion(containingLine: line, side: side) != nil
    }

    /// Returns the active `DiffFoldRegion` hiding `line` on `side`, if any.
    func foldRegion(containingLine line: Int, side: Side) -> DiffFoldRegion? {
        guard line >= 0, let entry = entry(containingLine: line, side: side), let region = entry.foldRegion else {
            return nil
        }
        let foldRange = side == .left ? region.leftRange : region.rightRange
        return foldRange.contains(line) ? region : nil
    }

    private func entry(containingLine line: Int, side: Side) -> SegmentEntry? {
        guard !entries.isEmpty else { return nil }
        // Binary search the last entry whose `start <= line` and has `count > 0` (or scan past zero-count gaps).
        var lo = 0
        var hi = entries.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = side == .left ? entries[mid].leftStart : entries[mid].rightStart
            if start <= line { lo = mid } else { hi = mid - 1 }
        }
        // Multiple zero-count segments on this side can share the same `start`; walk backwards to the one owning `line`.
        var idx = lo
        while idx >= 0 {
            let e = entries[idx]
            let start = side == .left ? e.leftStart : e.rightStart
            let count = side == .left ? e.leftCount : e.rightCount
            if count > 0 && line >= start && line < start + count {
                return e
            }
            if start < line && count > 0 { break }
            idx -= 1
        }
        return nil
    }
}

// MARK: - Core SemanticDiff Algorithms

enum SemanticDiff {
    static let defaultMoveMinNonEmptyLines = 3
    static let defaultMoveSimilarityThreshold = 0.78
    static let defaultShortMoveSimilarityThreshold = 0.72
    static let defaultRenameMinOccurrences = 2
    static let defaultRenameDominanceThreshold = 0.75

    // MARK: 1. Comment Stripping & Filtering

    /// Removes `.comment` syntax spans from `line` (using UTF-16 offsets from `Highlighter.highlight`),
    /// collapses internal whitespace runs to a single space, and trims leading/trailing whitespace.
    static func stripComments(from line: String, spans: [SyntaxSpan]) -> String {
        let commentSpans = spans.filter { $0.kind == .comment }
        if commentSpans.isEmpty {
            return normalizeCodeWhitespace(line)
        }

        let units = Array(line.utf16)
        guard !units.isEmpty else { return "" }

        let sorted = commentSpans.sorted { $0.start < $1.start }
        var kept: [UInt16] = []
        kept.reserveCapacity(units.count)

        var cursor = 0
        for span in sorted {
            let start = max(0, min(Int(span.start), units.count))
            let end = max(start, min(start + Int(span.length), units.count))
            if start > cursor {
                kept.append(contentsOf: units[cursor..<start])
            }
            // Replace inline block comments with a single space so adjacent tokens stay separated.
            if !kept.isEmpty && end < units.count {
                kept.append(32)
            }
            if end > cursor {
                cursor = end
            }
        }
        if cursor < units.count {
            kept.append(contentsOf: units[cursor..<units.count])
        }

        let stripped = String(utf16CodeUnits: kept, count: kept.count)
        return normalizeCodeWhitespace(stripped)
    }

    /// Returns true when at least one side of `hunk` contains a `.comment` span and,
    /// after stripping `.comment` spans and normalizing whitespace / ignoring empty lines,
    /// the remaining code lines on left and right are identical.
    static func isCommentOnlyHunk(
        _ hunk: Hunk,
        leftLines: [String],
        rightLines: [String],
        leftSpans: [[SyntaxSpan]],
        rightSpans: [[SyntaxSpan]]
    ) -> Bool {
        guard hunk.leftStart >= 0, hunk.rightStart >= 0,
              hunk.leftStart + hunk.leftCount <= leftLines.count,
              hunk.rightStart + hunk.rightCount <= rightLines.count else {
            return false
        }

        var sawComment = false
        var leftNormalized: [String] = []
        leftNormalized.reserveCapacity(hunk.leftCount)
        for idx in hunk.leftStart..<(hunk.leftStart + hunk.leftCount) {
            let spans = idx < leftSpans.count ? leftSpans[idx] : []
            if !sawComment && spans.contains(where: { $0.kind == .comment }) {
                sawComment = true
            }
            let code = stripComments(from: leftLines[idx], spans: spans)
            if !code.isEmpty {
                leftNormalized.append(code)
            }
        }

        var rightNormalized: [String] = []
        rightNormalized.reserveCapacity(hunk.rightCount)
        for idx in hunk.rightStart..<(hunk.rightStart + hunk.rightCount) {
            let spans = idx < rightSpans.count ? rightSpans[idx] : []
            if !sawComment && spans.contains(where: { $0.kind == .comment }) {
                sawComment = true
            }
            let code = stripComments(from: rightLines[idx], spans: spans)
            if !code.isEmpty {
                rightNormalized.append(code)
            }
        }

        return sawComment && leftNormalized == rightNormalized
    }

    /// Partitions `hunks` into substantive hunks (`kept`) and comment-only hunks (`hidden`).
    static func filterCommentOnlyHunks(
        _ hunks: [Hunk],
        leftLines: [String],
        rightLines: [String],
        leftSpans: [[SyntaxSpan]],
        rightSpans: [[SyntaxSpan]]
    ) -> (kept: [Hunk], hidden: [Hunk]) {
        guard !hunks.isEmpty else { return ([], []) }
        var kept: [Hunk] = []
        var hidden: [Hunk] = []
        kept.reserveCapacity(hunks.count)
        for hunk in hunks {
            if isCommentOnlyHunk(
                hunk,
                leftLines: leftLines,
                rightLines: rightLines,
                leftSpans: leftSpans,
                rightSpans: rightSpans
            ) {
                hidden.append(hunk)
            } else {
                kept.append(hunk)
            }
        }
        return (kept, hidden)
    }

    private static func normalizeCodeWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inSpace = false
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n" {
                if !out.isEmpty && !inSpace {
                    out.append(" ")
                    inSpace = true
                }
            } else {
                out.unicodeScalars.append(scalar)
                inSpace = false
            }
        }
        if out.last == " " {
            out.removeLast()
        }
        return out
    }

    // MARK: 2. JSON Semantic Normalization

    /// True when the file should be treated as JSON for semantic normalization.
    static func isJSONFile(language: LanguageSpec, path: String) -> Bool {
        if language.name == "JSON" { return true }
        let ext = (path as NSString).pathExtension.lowercased()
        return ext == "json"
    }

    /// Canonically formats valid JSON bytes with sorted keys, pretty printing, and unescaped slashes.
    /// Returns `nil` if the input is empty, invalid JSON, or a top-level scalar fragment that
    /// `JSONSerialization.data(withJSONObject:)` cannot serialize.
    static func normalizeJSONData(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        // Guard against ObjC NSInvalidArgumentException for scalar top-level fragments.
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        guard var formatted = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }
        if formatted.last != 0x0A {
            formatted.append(0x0A)
        }
        return formatted
    }

    /// Convenience wrapper around `normalizeJSONData(_:)` for UTF-8 strings.
    static func normalizeJSONString(_ text: String) -> String? {
        guard let normalized = normalizeJSONData(Data(text.utf8)) else { return nil }
        return String(decoding: normalized, as: UTF8.self)
    }

    /// Normalizes both non-empty sides of a JSON diff pair.
    /// If either non-empty side fails to parse, silently falls back to the original inputs (`normalized = false`).
    static func normalizeJSONPair(old: Data?, new: Data?) -> (old: Data?, new: Data?, normalized: Bool) {
        let hasOld = old.map { !$0.isEmpty } ?? false
        let hasNew = new.map { !$0.isEmpty } ?? false
        guard hasOld || hasNew else { return (old, new, false) }

        var normOld = old
        var normNew = new

        if let old, !old.isEmpty {
            guard let formatted = normalizeJSONData(old) else {
                return (old, new, false)
            }
            normOld = formatted
        }
        if let new, !new.isEmpty {
            guard let formatted = normalizeJSONData(new) else {
                return (old, new, false)
            }
            normNew = formatted
        }
        return (normOld, normNew, true)
    }

    // MARK: 3. Intra-File Code Move Detection

    private struct MoveCandidate {
        let hunkIndex: Int
        let lineRange: Range<Int>
        let hunkLineRange: Range<Int>
        let isPure: Bool
        let isShort: Bool
        let normalizedLines: [String]
        let normalizedLineHashes: [UInt64]
        let normalizedBlockHash: UInt64
        let tokens: [UInt64]
        let tokenCounts: [UInt64: Int]
        let lineCounts: [UInt64: Int]
        let symbolNames: Set<String>
        let wordSubTokens: [UInt64]
        let fullSubTokens: [UInt64]
        let primaryCalleeSubTokens: [UInt64]?
    }

    private struct MovePairCandidate {
        let sourceCandidateIndex: Int
        let targetCandidateIndex: Int
        let similarity: Double
        let sharesSymbolName: Bool
        let bothPure: Bool
        let lineWeight: Int
        let isExact: Bool

        var sortScore: Double {
            similarity + (sharesSymbolName ? 0.05 : 0.0) + (bothPure ? 0.02 : 0.0)
        }
    }

    private struct ContainerLineProfile {
        let offset: Int
        let normalized: String
        let lineHash: UInt64
        let wholeTokens: [UInt64]
        let wordSubTokens: [UInt64]
        let fullSubTokens: [UInt64]
        let primaryCalleeSubTokens: [UInt64]?
    }

    private struct ContainerProfile {
        let hunkIndex: Int
        let isAdded: Bool
        let baseStart: Int
        let lineCount: Int
        let lines: [ContainerLineProfile]
    }

    private struct SubHunkMatchCandidate {
        let donorHunkIndex: Int
        let donorIsSource: Bool // true when donor is .deleted and container is .added
        let donorLineRange: Range<Int>
        let donorNonEmptyCount: Int
        let containerHunkIndex: Int
        let containerOffsetRange: Range<Int> // 0-based line offsets inside container hunk
        let similarity: Double
        let isExact: Bool
    }

    /// Detects deleted/added hunk pairs (plus separable deleted/added spans inside modified hunks)
    /// representing moved or moved-and-tweaked code blocks within the same file, attaching `HunkMoveInfo`.
    /// Also splits multi-source merged `.added` hunks or single-source split `.deleted` hunks into
    /// ordered, non-overlapping sub-hunks when distinct moved slices are detected inside them.
    /// Returns an array mapping each final hunk index back to its original pre-call index in `hunks`.
    @discardableResult
    static func detectMoves(
        in hunks: inout [Hunk],
        leftLines: [String],
        rightLines: [String],
        language: LanguageSpec = .plain,
        minNonEmptyLines: Int = defaultMoveMinNonEmptyLines,
        similarityThreshold: Double = defaultMoveSimilarityThreshold
    ) -> [Int] {
        guard hunks.count >= 2 else { return Array(hunks.indices) }

        // Clear any stale move metadata before recomputing.
        for i in hunks.indices { hunks[i].moveInfo = nil }

        let minLines = max(1, minNonEmptyLines)
        let threshold = min(1.0, max(0.0, similarityThreshold))
        let shortThreshold: Double = threshold > defaultMoveSimilarityThreshold
            ? threshold
            : min(threshold, defaultShortMoveSimilarityThreshold)
        let allowShortSubstantive = minLines <= defaultMoveMinNonEmptyLines
        let excludedKeywords = buildExcludedKeywordSet(for: language)
        let hashComments = language.lineComments.contains(Array("#".utf8))

        var rawSources: [(index: Int, range: Range<Int>, hunkRange: Range<Int>, isPure: Bool, normalized: [String])] = []
        var rawTargets: [(index: Int, range: Range<Int>, hunkRange: Range<Int>, isPure: Bool, normalized: [String])] = []

        for (index, h) in hunks.enumerated() {
            if h.kind == .deleted, h.leftStart >= 0, h.leftStart + h.leftCount <= leftLines.count {
                let range = h.leftStart..<(h.leftStart + h.leftCount)
                let norm = normalizedNonEmptyLines(leftLines[range])
                if isEligibleMoveBlock(
                    norm,
                    minLines: minLines,
                    excludedKeywords: excludedKeywords,
                    hashComments: hashComments,
                    allowShortSubstantive: allowShortSubstantive
                ) {
                    rawSources.append((index, range, range, true, norm))
                }
            } else if h.kind == .added, h.rightStart >= 0, h.rightStart + h.rightCount <= rightLines.count {
                let range = h.rightStart..<(h.rightStart + h.rightCount)
                let norm = normalizedNonEmptyLines(rightLines[range])
                if isEligibleMoveBlock(
                    norm,
                    minLines: minLines,
                    excludedKeywords: excludedKeywords,
                    hashComments: hashComments,
                    allowShortSubstantive: allowShortSubstantive
                ) {
                    rawTargets.append((index, range, range, true, norm))
                }
            } else if h.kind == .modified,
                      h.leftStart >= 0, h.leftStart + h.leftCount <= leftLines.count,
                      h.rightStart >= 0, h.rightStart + h.rightCount <= rightLines.count {
                // Separable excess deleted lines inside a modified hunk (e.g. a moved block adjacent to an edited line).
                if h.leftCount >= h.rightCount + minLines {
                    let hunkRange = h.leftStart..<(h.leftStart + h.leftCount)
                    let excess = h.leftCount - h.rightCount
                    let slices = [
                        h.leftStart..<(h.leftStart + excess),
                        (h.leftStart + h.rightCount)..<(h.leftStart + h.leftCount),
                    ]
                    for subRange in slices {
                        let norm = normalizedNonEmptyLines(leftLines[subRange])
                        if isEligibleMoveBlock(
                            norm,
                            minLines: minLines,
                            excludedKeywords: excludedKeywords,
                            hashComments: hashComments,
                            allowShortSubstantive: false
                        ) {
                            rawSources.append((index, subRange, hunkRange, false, norm))
                        }
                    }
                }
                if h.rightCount >= h.leftCount + minLines {
                    let hunkRange = h.rightStart..<(h.rightStart + h.rightCount)
                    let excess = h.rightCount - h.leftCount
                    let slices = [
                        h.rightStart..<(h.rightStart + excess),
                        (h.rightStart + h.leftCount)..<(h.rightStart + h.rightCount),
                    ]
                    for subRange in slices {
                        let norm = normalizedNonEmptyLines(rightLines[subRange])
                        if isEligibleMoveBlock(
                            norm,
                            minLines: minLines,
                            excludedKeywords: excludedKeywords,
                            hashComments: hashComments,
                            allowShortSubstantive: false
                        ) {
                            rawTargets.append((index, subRange, hunkRange, false, norm))
                        }
                    }
                }
            }
        }

        guard !rawSources.isEmpty, !rawTargets.isEmpty else { return Array(hunks.indices) }

        // Only extract symbols when we actually have candidate source & target blocks to match.
        let leftSymbols = language.family == .plain ? [] : FileSymbolExtractor.extract(lines: leftLines, language: language)
        let rightSymbols = language.family == .plain ? [] : FileSymbolExtractor.extract(lines: rightLines, language: language)

        let sources = rawSources.map {
            makeMoveCandidate(
                hunkIndex: $0.index,
                range: $0.range,
                hunkRange: $0.hunkRange,
                isPure: $0.isPure,
                isShort: $0.normalized.count < minLines,
                normalizedLines: $0.normalized,
                symbols: leftSymbols,
                excludedKeywords: excludedKeywords,
                hashComments: hashComments
            )
        }
        let targets = rawTargets.map {
            makeMoveCandidate(
                hunkIndex: $0.index,
                range: $0.range,
                hunkRange: $0.hunkRange,
                isPure: $0.isPure,
                isShort: $0.normalized.count < minLines,
                normalizedLines: $0.normalized,
                symbols: rightSymbols,
                excludedKeywords: excludedKeywords,
                hashComments: hashComments
            )
        }

        var primaryPairs: [MovePairCandidate] = []
        var unequalPurePairs: [MovePairCandidate] = []
        let allowApproximate = sources.count * targets.count <= 25_000

        // Fast index for exact matches when candidate counts are large.
        var targetsByBlockHash: [UInt64: [Int]] = [:]
        if !allowApproximate {
            for (tIdx, target) in targets.enumerated() {
                targetsByBlockHash[target.normalizedBlockHash, default: []].append(tIdx)
            }
        }

        for (sIdx, src) in sources.enumerated() {
            let targetIndices: [Int] = allowApproximate
                ? Array(targets.indices)
                : (targetsByBlockHash[src.normalizedBlockHash] ?? [])

            for tIdx in targetIndices {
                let dst = targets[tIdx]
                guard src.hunkIndex != dst.hunkIndex else { continue }
                let sharesSymbol = !src.symbolNames.isEmpty && !src.symbolNames.isDisjoint(with: dst.symbolNames)
                let bothPure = src.isPure && dst.isPure
                let anyShort = src.isShort || dst.isShort

                // Short (1-2 non-empty line) candidates only pair whole-hunk when both are pure
                // and have the same non-empty line count; mismatched lengths are left for sub-hunk splitting.
                if anyShort && (!bothPure || src.normalizedLines.count != dst.normalizedLines.count) {
                    continue
                }

                if src.normalizedBlockHash == dst.normalizedBlockHash && src.normalizedLines == dst.normalizedLines {
                    primaryPairs.append(MovePairCandidate(
                        sourceCandidateIndex: sIdx,
                        targetCandidateIndex: tIdx,
                        similarity: 1.0,
                        sharesSymbolName: sharesSymbol,
                        bothPure: bothPure,
                        lineWeight: src.normalizedLines.count,
                        isExact: true
                    ))
                    continue
                }

                guard allowApproximate else { continue }

                let sim: Double
                let requiredThreshold: Double
                if anyShort {
                    requiredThreshold = shortThreshold
                    sim = shortBlockSimilarity(
                        aLines: src.normalizedLines,
                        bLines: dst.normalizedLines,
                        aWordSubTokens: src.wordSubTokens,
                        bWordSubTokens: dst.wordSubTokens,
                        aFullSubTokens: src.fullSubTokens,
                        bFullSubTokens: dst.fullSubTokens,
                        aPrimaryCallee: src.primaryCalleeSubTokens,
                        bPrimaryCallee: dst.primaryCalleeSubTokens,
                        threshold: shortThreshold
                    )
                } else {
                    requiredThreshold = threshold
                    sim = blockSimilarity(src, dst, threshold: threshold)
                }

                if sim >= requiredThreshold {
                    let candidate = MovePairCandidate(
                        sourceCandidateIndex: sIdx,
                        targetCandidateIndex: tIdx,
                        similarity: sim,
                        sharesSymbolName: sharesSymbol,
                        bothPure: bothPure,
                        lineWeight: min(src.normalizedLines.count, dst.normalizedLines.count),
                        isExact: false
                    )
                    if bothPure && src.normalizedLines.count != dst.normalizedLines.count {
                        unequalPurePairs.append(candidate)
                    } else {
                        primaryPairs.append(candidate)
                    }
                }
            }
        }

        var matchedHunkIndices = Set<Int>()
        var pairID = 0

        func sortMovePairs(_ list: inout [MovePairCandidate]) {
            list.sort { lhs, rhs in
                if lhs.isExact != rhs.isExact { return lhs.isExact }
                if abs(lhs.sortScore - rhs.sortScore) > 1e-9 { return lhs.sortScore > rhs.sortScore }
                if lhs.bothPure != rhs.bothPure { return lhs.bothPure }
                if lhs.sharesSymbolName != rhs.sharesSymbolName { return lhs.sharesSymbolName }
                if lhs.lineWeight != rhs.lineWeight { return lhs.lineWeight > rhs.lineWeight }
                if lhs.sourceCandidateIndex != rhs.sourceCandidateIndex { return lhs.sourceCandidateIndex < rhs.sourceCandidateIndex }
                return lhs.targetCandidateIndex < rhs.targetCandidateIndex
            }
        }

        func commitWholePairs(_ list: [MovePairCandidate]) {
            for pair in list {
                let src = sources[pair.sourceCandidateIndex]
                let dst = targets[pair.targetCandidateIndex]
                guard !matchedHunkIndices.contains(src.hunkIndex),
                      !matchedHunkIndices.contains(dst.hunkIndex) else { continue }
                matchedHunkIndices.insert(src.hunkIndex)
                matchedHunkIndices.insert(dst.hunkIndex)

                var moveInline: MoveInlineDiff? = nil
                if !pair.isExact, src.lineRange.count <= 200, dst.lineRange.count <= 200,
                   let computed = InlineDiff.compute(old: leftLines[src.lineRange], new: rightLines[dst.lineRange]) {
                    let srcPadded = padInlineRanges(computed.old, subRange: src.lineRange, fullRange: src.hunkLineRange)
                    let dstPadded = padInlineRanges(computed.new, subRange: dst.lineRange, fullRange: dst.hunkLineRange)
                    moveInline = MoveInlineDiff(source: srcPadded, target: dstPadded)
                }

                hunks[src.hunkIndex].moveInfo = HunkMoveInfo(
                    pairID: pairID,
                    role: .source,
                    counterpartHunkIndex: dst.hunkIndex,
                    similarity: pair.similarity,
                    inlineDiff: moveInline
                )
                hunks[dst.hunkIndex].moveInfo = HunkMoveInfo(
                    pairID: pairID,
                    role: .target,
                    counterpartHunkIndex: src.hunkIndex,
                    similarity: pair.similarity,
                    inlineDiff: moveInline
                )
                pairID += 1
            }
        }

        // Phase 1A: Exact, same-line-count, and modified-excess whole-block pairs.
        sortMovePairs(&primaryPairs)
        commitWholePairs(primaryPairs)

        // Phase 2: Sub-hunk split matching on still-unmatched pure .deleted / .added hunks
        // (multi-source merge into one .added hunk, single-source split out of one .deleted hunk,
        // or partial move embedded inside a larger added/deleted hunk).
        var wholeUnequalPairKeys = Set<UInt64>()
        for p in unequalPurePairs {
            let sH = sources[p.sourceCandidateIndex].hunkIndex
            let tH = targets[p.targetCandidateIndex].hunkIndex
            wholeUnequalPairKeys.insert((UInt64(UInt32(sH)) << 32) | UInt64(UInt32(tH)))
        }

        let splitReplacements = detectSubHunkSplits(
            hunks: &hunks,
            sources: sources,
            targets: targets,
            leftLines: leftLines,
            rightLines: rightLines,
            matchedHunkIndices: &matchedHunkIndices,
            pairID: &pairID,
            wholeUnequalPairKeys: wholeUnequalPairKeys,
            minLines: minLines,
            threshold: threshold,
            shortThreshold: shortThreshold,
            excludedKeywords: excludedKeywords,
            hashComments: hashComments
        )

        // Phase 1B: Remaining unequal-size whole-block matches (>= minLines blocks with edits).
        if !unequalPurePairs.isEmpty {
            sortMovePairs(&unequalPurePairs)
            commitWholePairs(unequalPurePairs)
        }

        // Rebuild hunks with any split sub-hunks in-place and re-index all counterpartHunkIndex links.
        var rebuilt: [Hunk]
        var postToPre: [Int]
        if splitReplacements.isEmpty {
            rebuilt = hunks
            postToPre = Array(hunks.indices)
        } else {
            rebuilt = []
            postToPre = []
            rebuilt.reserveCapacity(hunks.count + splitReplacements.count * 2)
            postToPre.reserveCapacity(hunks.count + splitReplacements.count * 2)
            for origIdx in hunks.indices {
                if let subHunks = splitReplacements[origIdx] {
                    for sub in subHunks {
                        rebuilt.append(sub)
                        postToPre.append(origIdx)
                    }
                } else {
                    rebuilt.append(hunks[origIdx])
                    postToPre.append(origIdx)
                }
            }
        }

        reconcileMoveCounterpartIndices(&rebuilt)
        hunks = rebuilt
        return postToPre
    }

    /// Scans unmatched pure `.deleted`/`.added` hunks to match smaller donor blocks inside larger
    /// container hunks, splitting matched containers into ordered, contiguous, non-overlapping sub-hunks.
    private static func detectSubHunkSplits(
        hunks: inout [Hunk],
        sources: [MoveCandidate],
        targets: [MoveCandidate],
        leftLines: [String],
        rightLines: [String],
        matchedHunkIndices: inout Set<Int>,
        pairID: inout Int,
        wholeUnequalPairKeys: Set<UInt64>,
        minLines: Int,
        threshold: Double,
        shortThreshold: Double,
        excludedKeywords: Set<String>,
        hashComments: Bool
    ) -> [Int: [Hunk]] {
        let unmatchedSourceDonors = sources.filter { $0.isPure && !matchedHunkIndices.contains($0.hunkIndex) }
        let unmatchedTargetDonors = targets.filter { $0.isPure && !matchedHunkIndices.contains($0.hunkIndex) }

        var addedContainers: [ContainerProfile] = []
        var deletedContainers: [ContainerProfile] = []
        for (idx, h) in hunks.enumerated() where !matchedHunkIndices.contains(idx) {
            if h.kind == .added, h.rightCount >= 2, h.rightStart >= 0, h.rightStart + h.rightCount <= rightLines.count {
                if let profile = makeContainerProfile(
                    hunkIndex: idx,
                    isAdded: true,
                    baseStart: h.rightStart,
                    lineCount: h.rightCount,
                    allLines: rightLines,
                    excludedKeywords: excludedKeywords,
                    hashComments: hashComments
                ) {
                    addedContainers.append(profile)
                }
            } else if h.kind == .deleted, h.leftCount >= 2, h.leftStart >= 0, h.leftStart + h.leftCount <= leftLines.count {
                if let profile = makeContainerProfile(
                    hunkIndex: idx,
                    isAdded: false,
                    baseStart: h.leftStart,
                    lineCount: h.leftCount,
                    allLines: leftLines,
                    excludedKeywords: excludedKeywords,
                    hashComments: hashComments
                ) {
                    deletedContainers.append(profile)
                }
            }
        }

        var subCandidates: [SubHunkMatchCandidate] = []

        // Direction 1: Unmatched .deleted donors matched inside larger unmatched .added containers.
        if !unmatchedSourceDonors.isEmpty && !addedContainers.isEmpty {
            let allowApprox = unmatchedSourceDonors.count * addedContainers.count <= 4_000
            scanDonorsAgainstContainers(
                donors: unmatchedSourceDonors,
                donorIsSource: true,
                containers: addedContainers,
                allowApproximate: allowApprox,
                minLines: minLines,
                threshold: threshold,
                shortThreshold: shortThreshold,
                into: &subCandidates
            )
        }

        // Direction 2: Unmatched .added donors matched inside larger unmatched .deleted containers.
        if !unmatchedTargetDonors.isEmpty && !deletedContainers.isEmpty {
            let allowApprox = unmatchedTargetDonors.count * deletedContainers.count <= 4_000
            scanDonorsAgainstContainers(
                donors: unmatchedTargetDonors,
                donorIsSource: false,
                containers: deletedContainers,
                allowApproximate: allowApprox,
                minLines: minLines,
                threshold: threshold,
                shortThreshold: shortThreshold,
                into: &subCandidates
            )
        }

        guard !subCandidates.isEmpty else { return [:] }

        subCandidates.sort { lhs, rhs in
            if lhs.isExact != rhs.isExact { return lhs.isExact }
            if abs(lhs.similarity - rhs.similarity) > 1e-9 { return lhs.similarity > rhs.similarity }
            if lhs.donorNonEmptyCount != rhs.donorNonEmptyCount { return lhs.donorNonEmptyCount > rhs.donorNonEmptyCount }
            if lhs.containerHunkIndex != rhs.containerHunkIndex { return lhs.containerHunkIndex < rhs.containerHunkIndex }
            if lhs.containerOffsetRange.lowerBound != rhs.containerOffsetRange.lowerBound {
                return lhs.containerOffsetRange.lowerBound < rhs.containerOffsetRange.lowerBound
            }
            return lhs.donorHunkIndex < rhs.donorHunkIndex
        }

        var usedDonors = Set<Int>()
        var usedContainers = Set<Int>()
        var tentativeByContainer: [Int: [SubHunkMatchCandidate]] = [:]

        for cand in subCandidates {
            guard !matchedHunkIndices.contains(cand.donorHunkIndex),
                  !matchedHunkIndices.contains(cand.containerHunkIndex),
                  !usedDonors.contains(cand.donorHunkIndex),
                  !usedContainers.contains(cand.donorHunkIndex),
                  !usedDonors.contains(cand.containerHunkIndex) else {
                continue
            }
            let existing = tentativeByContainer[cand.containerHunkIndex] ?? []
            let overlaps = existing.contains {
                $0.containerOffsetRange.lowerBound < cand.containerOffsetRange.upperBound
                    && cand.containerOffsetRange.lowerBound < $0.containerOffsetRange.upperBound
            }
            if overlaps { continue }

            usedDonors.insert(cand.donorHunkIndex)
            usedContainers.insert(cand.containerHunkIndex)
            tentativeByContainer[cand.containerHunkIndex, default: []].append(cand)
        }

        var splitReplacements: [Int: [Hunk]] = [:]

        for containerIdx in tentativeByContainer.keys.sorted() {
            guard let matches = tentativeByContainer[containerIdx], !matches.isEmpty else { continue }

            // Avoid fragmenting a single moved >=minLines block that merely had a few lines edited/added
            // when whole-block pairing already qualifies with similarity >= threshold.
            if matches.count == 1 {
                let only = matches[0]
                if only.donorNonEmptyCount >= minLines {
                    let srcH = only.donorIsSource ? only.donorHunkIndex : containerIdx
                    let dstH = only.donorIsSource ? containerIdx : only.donorHunkIndex
                    let key = (UInt64(UInt32(srcH)) << 32) | UInt64(UInt32(dstH))
                    if wholeUnequalPairKeys.contains(key) {
                        continue
                    }
                }
            }

            let container = hunks[containerIdx]
            let isAddedContainer = container.kind == .added
            let containerTotalLines = isAddedContainer ? container.rightCount : container.leftCount
            let containerBaseStart = isAddedContainer ? container.rightStart : container.leftStart
            let containerBuffer = isAddedContainer ? rightLines : leftLines

            let sortedMatches = matches.sorted { $0.containerOffsetRange.lowerBound < $1.containerOffsetRange.lowerBound }

            // Partition 0..<containerTotalLines into ordered, contiguous, non-overlapping pieces,
            // absorbing whitespace-only gaps adjacent to matched sub-hunks so trailing blank lines
            // stay cleanly attached instead of creating stray 1-line blank hunks.
            func isBlankOnly(_ range: Range<Int>) -> Bool {
                guard !range.isEmpty else { return false }
                for off in range {
                    if !containerBuffer[containerBaseStart + off].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return false
                    }
                }
                return true
            }

            struct Piece {
                var offsetRange: Range<Int>
                var match: SubHunkMatchCandidate?
            }

            var pieces: [Piece] = []
            var absorbedLeading = false
            let firstStart = sortedMatches[0].containerOffsetRange.lowerBound
            if firstStart > 0 {
                let leadRange = 0..<firstStart
                if isBlankOnly(leadRange) {
                    absorbedLeading = true
                } else {
                    pieces.append(Piece(offsetRange: leadRange, match: nil))
                }
            }

            for i in sortedMatches.indices {
                let m = sortedMatches[i]
                let startOff = (i == 0 && absorbedLeading) ? 0 : m.containerOffsetRange.lowerBound
                let nextBound = (i + 1 < sortedMatches.count)
                    ? sortedMatches[i + 1].containerOffsetRange.lowerBound
                    : containerTotalLines
                let gapRange = m.containerOffsetRange.upperBound..<nextBound

                if !gapRange.isEmpty && isBlankOnly(gapRange) {
                    pieces.append(Piece(offsetRange: startOff..<nextBound, match: m))
                } else {
                    pieces.append(Piece(offsetRange: startOff..<m.containerOffsetRange.upperBound, match: m))
                    if !gapRange.isEmpty {
                        pieces.append(Piece(offsetRange: gapRange, match: nil))
                    }
                }
            }

            // Commit matched indices and construct sub-hunks + MoveInfo.
            matchedHunkIndices.insert(containerIdx)
            var subHunks: [Hunk] = []
            subHunks.reserveCapacity(pieces.count)

            for piece in pieces {
                var sub: Hunk
                if isAddedContainer {
                    sub = Hunk(
                        leftStart: container.leftStart,
                        leftCount: 0,
                        rightStart: container.rightStart + piece.offsetRange.lowerBound,
                        rightCount: piece.offsetRange.count
                    )
                } else {
                    sub = Hunk(
                        leftStart: container.leftStart + piece.offsetRange.lowerBound,
                        leftCount: piece.offsetRange.count,
                        rightStart: container.rightStart,
                        rightCount: 0
                    )
                }

                if let m = piece.match {
                    matchedHunkIndices.insert(m.donorHunkIndex)
                    let currentPairID = pairID
                    pairID += 1

                    let srcRange: Range<Int>
                    let dstRange: Range<Int>
                    if m.donorIsSource {
                        srcRange = m.donorLineRange
                        dstRange = sub.rightStart..<(sub.rightStart + sub.rightCount)
                    } else {
                        srcRange = sub.leftStart..<(sub.leftStart + sub.leftCount)
                        dstRange = m.donorLineRange
                    }

                    var moveInline: MoveInlineDiff? = nil
                    if !m.isExact, srcRange.count <= 200, dstRange.count <= 200,
                       let computed = InlineDiff.compute(old: leftLines[srcRange], new: rightLines[dstRange]) {
                        moveInline = MoveInlineDiff(source: computed.old, target: computed.new)
                    }

                    let containerRole: MoveRole = isAddedContainer ? .target : .source
                    let donorRole: MoveRole = isAddedContainer ? .source : .target

                    sub.moveInfo = HunkMoveInfo(
                        pairID: currentPairID,
                        role: containerRole,
                        counterpartHunkIndex: -1,
                        similarity: m.similarity,
                        inlineDiff: moveInline
                    )
                    hunks[m.donorHunkIndex].moveInfo = HunkMoveInfo(
                        pairID: currentPairID,
                        role: donorRole,
                        counterpartHunkIndex: -1,
                        similarity: m.similarity,
                        inlineDiff: moveInline
                    )
                }

                subHunks.append(sub)
            }

            splitReplacements[containerIdx] = subHunks
        }

        return splitReplacements
    }

    private static func makeContainerProfile(
        hunkIndex: Int,
        isAdded: Bool,
        baseStart: Int,
        lineCount: Int,
        allLines: [String],
        excludedKeywords: Set<String>,
        hashComments: Bool
    ) -> ContainerProfile? {
        var profiles: [ContainerLineProfile] = []
        profiles.reserveCapacity(lineCount)
        for off in 0..<lineCount {
            let trimmed = allLines[baseStart + off].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let (wordSubs, fullSubs) = tokenizeSubTokens(trimmed)
            let callee = extractCodeIdentifiersAndCallee(
                from: trimmed,
                excluded: excludedKeywords,
                hashComments: hashComments
            ).primaryCallee.map { identifierSubTokenHashes($0) }
            profiles.append(ContainerLineProfile(
                offset: off,
                normalized: trimmed,
                lineHash: fnv1a(trimmed),
                wholeTokens: tokenizeForSimilarity(trimmed),
                wordSubTokens: wordSubs,
                fullSubTokens: fullSubs,
                primaryCalleeSubTokens: callee
            ))
        }
        // A container must have at least 2 non-empty lines to be split into sub-hunks.
        guard profiles.count >= 2 else { return nil }
        return ContainerProfile(
            hunkIndex: hunkIndex,
            isAdded: isAdded,
            baseStart: baseStart,
            lineCount: lineCount,
            lines: profiles
        )
    }

    private static func scanDonorsAgainstContainers(
        donors: [MoveCandidate],
        donorIsSource: Bool,
        containers: [ContainerProfile],
        allowApproximate: Bool,
        minLines: Int,
        threshold: Double,
        shortThreshold: Double,
        into out: inout [SubHunkMatchCandidate]
    ) {
        for container in containers {
            let cLines = container.lines
            let cCount = cLines.count
            let allowContainerApprox = allowApproximate && cCount <= 300

            for donor in donors {
                let k = donor.normalizedLines.count
                guard k < cCount else { continue }

                if donor.isShort {
                    // Exact 1-to-1 non-empty line count window (1 line matches 1 line, 2 lines match 2 lines).
                    for startNE in 0...(cCount - k) {
                        let rawStart = cLines[startNE].offset
                        let rawEnd = cLines[startNE + k - 1].offset + 1

                        var exact = true
                        for j in 0..<k {
                            if cLines[startNE + j].lineHash != donor.normalizedLineHashes[j]
                                || cLines[startNE + j].normalized != donor.normalizedLines[j] {
                                exact = false
                                break
                            }
                        }
                        if exact {
                            out.append(SubHunkMatchCandidate(
                                donorHunkIndex: donor.hunkIndex,
                                donorIsSource: donorIsSource,
                                donorLineRange: donor.lineRange,
                                donorNonEmptyCount: k,
                                containerHunkIndex: container.hunkIndex,
                                containerOffsetRange: rawStart..<rawEnd,
                                similarity: 1.0,
                                isExact: true
                            ))
                            continue
                        }

                        guard allowContainerApprox else { continue }

                        let sliceLines: [String]
                        let sliceWordSubs: [UInt64]
                        let sliceFullSubs: [UInt64]
                        let sliceCallee: [UInt64]?
                        if k == 1 {
                            let lp = cLines[startNE]
                            sliceLines = [lp.normalized]
                            sliceWordSubs = lp.wordSubTokens
                            sliceFullSubs = lp.fullSubTokens
                            sliceCallee = lp.primaryCalleeSubTokens
                        } else {
                            var sLines: [String] = []
                            var sWords: [UInt64] = []
                            var sFull: [UInt64] = []
                            sLines.reserveCapacity(k)
                            for j in 0..<k {
                                let lp = cLines[startNE + j]
                                sLines.append(lp.normalized)
                                sWords.append(contentsOf: lp.wordSubTokens)
                                sFull.append(contentsOf: lp.fullSubTokens)
                            }
                            sliceLines = sLines
                            sliceWordSubs = sWords
                            sliceFullSubs = sFull
                            sliceCallee = nil
                        }

                        let sim = shortBlockSimilarity(
                            aLines: donor.normalizedLines,
                            bLines: sliceLines,
                            aWordSubTokens: donor.wordSubTokens,
                            bWordSubTokens: sliceWordSubs,
                            aFullSubTokens: donor.fullSubTokens,
                            bFullSubTokens: sliceFullSubs,
                            aPrimaryCallee: donor.primaryCalleeSubTokens,
                            bPrimaryCallee: sliceCallee,
                            threshold: shortThreshold
                        )
                        if sim >= shortThreshold {
                            out.append(SubHunkMatchCandidate(
                                donorHunkIndex: donor.hunkIndex,
                                donorIsSource: donorIsSource,
                                donorLineRange: donor.lineRange,
                                donorNonEmptyCount: k,
                                containerHunkIndex: container.hunkIndex,
                                containerOffsetRange: rawStart..<rawEnd,
                                similarity: sim,
                                isExact: false
                            ))
                        }
                    }
                } else {
                    // Standard >= minLines donor inside a larger container.
                    // Check exact k-line windows first, plus near-length windows if approximate is allowed.
                    let maxDelta = allowContainerApprox
                        ? min(2, max(1, Int(floor(Double(k) * (1.0 - threshold) / max(0.01, threshold)))))
                        : 0
                    let minW = max(minLines, k - maxDelta)
                    let maxW = min(cCount - 1, k + maxDelta)
                    guard minW <= maxW else { continue }

                    var bestForPair: SubHunkMatchCandidate? = nil
                    for w in minW...maxW {
                        for startNE in 0...(cCount - w) {
                            let rawStart = cLines[startNE].offset
                            let rawEnd = cLines[startNE + w - 1].offset + 1

                            if w == k {
                                var exact = true
                                for j in 0..<k {
                                    if cLines[startNE + j].lineHash != donor.normalizedLineHashes[j]
                                        || cLines[startNE + j].normalized != donor.normalizedLines[j] {
                                        exact = false
                                        break
                                    }
                                }
                                if exact {
                                    out.append(SubHunkMatchCandidate(
                                        donorHunkIndex: donor.hunkIndex,
                                        donorIsSource: donorIsSource,
                                        donorLineRange: donor.lineRange,
                                        donorNonEmptyCount: k,
                                        containerHunkIndex: container.hunkIndex,
                                        containerOffsetRange: rawStart..<rawEnd,
                                        similarity: 1.0,
                                        isExact: true
                                    ))
                                    continue
                                }
                            }

                            guard allowContainerApprox else { continue }

                            var windowTokens: [UInt64] = []
                            var windowTokenCounts: [UInt64: Int] = [:]
                            var windowLineCounts: [UInt64: Int] = [:]
                            for j in 0..<w {
                                let lp = cLines[startNE + j]
                                windowLineCounts[lp.lineHash, default: 0] += 1
                                for tok in lp.wholeTokens {
                                    windowTokens.append(tok)
                                    windowTokenCounts[tok, default: 0] += 1
                                }
                            }

                            let sim = tokenBlockSimilarity(
                                aTokens: donor.tokens,
                                aTokenCounts: donor.tokenCounts,
                                aLineCounts: donor.lineCounts,
                                aLineCount: donor.normalizedLineHashes.count,
                                bTokens: windowTokens,
                                bTokenCounts: windowTokenCounts,
                                bLineCounts: windowLineCounts,
                                bLineCount: w,
                                threshold: threshold
                            )
                            if sim >= threshold {
                                let cand = SubHunkMatchCandidate(
                                    donorHunkIndex: donor.hunkIndex,
                                    donorIsSource: donorIsSource,
                                    donorLineRange: donor.lineRange,
                                    donorNonEmptyCount: k,
                                    containerHunkIndex: container.hunkIndex,
                                    containerOffsetRange: rawStart..<rawEnd,
                                    similarity: sim,
                                    isExact: false
                                )
                                if bestForPair == nil || cand.similarity > bestForPair!.similarity {
                                    bestForPair = cand
                                }
                            }
                        }
                    }
                    if let best = bestForPair {
                        out.append(best)
                    }
                }
            }
        }
    }

    /// Recomputes every hunk's `moveInfo.counterpartHunkIndex` from its `pairID` and `role`,
    /// guaranteeing strict bidirectional symmetry across the final `hunks` array.
    private static func reconcileMoveCounterpartIndices(_ hunks: inout [Hunk]) {
        var sourceByPair: [Int: Int] = [:]
        var targetByPair: [Int: Int] = [:]
        for (idx, h) in hunks.enumerated() {
            guard let info = h.moveInfo else { continue }
            switch info.role {
            case .source: sourceByPair[info.pairID] = idx
            case .target: targetByPair[info.pairID] = idx
            }
        }
        for idx in hunks.indices {
            guard var info = hunks[idx].moveInfo else { continue }
            let counterpart = info.role == .source ? targetByPair[info.pairID] : sourceByPair[info.pairID]
            if let counterpart, counterpart != idx {
                info.counterpartHunkIndex = counterpart
                hunks[idx].moveInfo = info
            } else {
                hunks[idx].moveInfo = nil
            }
        }
    }

    private static func padInlineRanges(
        _ ranges: [[Range<Int>]],
        subRange: Range<Int>,
        fullRange: Range<Int>
    ) -> [[Range<Int>]] {
        guard subRange != fullRange else { return ranges }
        let prefix = max(0, subRange.lowerBound - fullRange.lowerBound)
        let suffix = max(0, fullRange.upperBound - subRange.upperBound)
        var out = [[Range<Int>]](repeating: [], count: prefix)
        out.append(contentsOf: ranges)
        if suffix > 0 {
            out.append(contentsOf: repeatElement([], count: suffix))
        }
        return out
    }

    private static func normalizedNonEmptyLines(_ slice: ArraySlice<String>) -> [String] {
        var result: [String] = []
        result.reserveCapacity(slice.count)
        for line in slice {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                result.append(trimmed)
            }
        }
        return result
    }

    private static func isEligibleMoveBlock(
        _ normalizedLines: [String],
        minLines: Int,
        excludedKeywords: Set<String>,
        hashComments: Bool,
        allowShortSubstantive: Bool
    ) -> Bool {
        if normalizedLines.count >= minLines {
            var totalChars = 0
            for line in normalizedLines {
                totalChars += line.utf8.count
                if totalChars >= 12 { return true }
            }
            return false
        }
        guard allowShortSubstantive, !normalizedLines.isEmpty, normalizedLines.count <= 2 else {
            return false
        }
        return isSubstantiveShortBlock(normalizedLines, excludedKeywords: excludedKeywords, hashComments: hashComments)
    }

    /// Substantive-statement guard for 1-2 non-empty line move candidates.
    /// Rejects boilerplate lines (`}`, `return`, `return nil`, `else {`, `break`, `continue`,
    /// trivial short assignments, or short calls like `log("a")`) while allowing real calls/statements.
    private static func isSubstantiveShortBlock(
        _ normalizedLines: [String],
        excludedKeywords: Set<String>,
        hashComments: Bool
    ) -> Bool {
        var maxLineLen = 0
        var totalNonWS = 0
        var distinctIdents = Set<String>()
        var maxIdentLen = 0
        var hasCall = false

        for line in normalizedLines {
            maxLineLen = max(maxLineLen, line.utf8.count)
            for b in line.utf8 where b != 32 && b != 9 && b != 13 && b != 10 {
                totalNonWS += 1
            }
            let extracted = extractCodeIdentifiersAndCallee(
                from: line,
                excluded: excludedKeywords,
                hashComments: hashComments
            )
            if extracted.hasCall { hasCall = true }
            for ident in extracted.identifiers {
                distinctIdents.insert(ident)
                maxIdentLen = max(maxIdentLen, ident.utf8.count)
            }
        }

        let meetsLength = (maxLineLen >= 18 && totalNonWS >= 16)
            || (normalizedLines.count == 2 && totalNonWS >= 24 && (hasCall || maxIdentLen >= 12))
        guard meetsLength else { return false }

        if maxIdentLen >= 12 { return true }
        guard distinctIdents.count >= 2 else { return false }
        let totalIdentChars = distinctIdents.reduce(0) { $0 + $1.utf8.count }
        return totalIdentChars >= 10
    }

    /// Extracts non-keyword identifiers (ignoring string literals and comments) and the primary
    /// call identifier (first non-keyword identifier immediately followed by `(`) from a single line.
    private static func extractCodeIdentifiersAndCallee(
        from line: String,
        excluded: Set<String>,
        hashComments: Bool
    ) -> (identifiers: [String], primaryCallee: String?, hasCall: Bool) {
        let bytes = Array(line.utf8)
        let n = bytes.count
        var i = 0
        var identifiers: [String] = []
        var primaryCallee: String? = nil
        var hasCall = false

        while i < n {
            let b = bytes[i]
            // Line comments: `//` (always) or `#` (for hash-comment languages).
            if b == 47 && i + 1 < n && bytes[i + 1] == 47 { // "//"
                break
            }
            if hashComments && b == 35 { // "#"
                break
            }
            // Inline block comment `/* ... */`.
            if b == 47 && i + 1 < n && bytes[i + 1] == 42 { // "/*"
                i += 2
                while i + 1 < n && !(bytes[i] == 42 && bytes[i + 1] == 47) { i += 1 }
                i = min(n, i + 2)
                continue
            }
            // String literals `"..."`, `'...'`, `` `...` ``.
            if b == 34 || b == 39 || b == 96 {
                let quote = b
                i += 1
                while i < n {
                    if bytes[i] == 92 && quote != 96 { // backslash escape
                        i += 2
                        continue
                    }
                    if bytes[i] == quote {
                        i += 1
                        break
                    }
                    i += 1
                }
                continue
            }
            // Identifier start: ASCII letter, `_`, or non-ASCII UTF-8 lead byte.
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80 {
                let start = i
                i += 1
                while i < n && isWordByte(bytes[i]) { i += 1 }
                let ident = String(decoding: bytes[start..<i], as: UTF8.self)
                if !excluded.contains(ident) {
                    var look = i
                    while look < n && (bytes[look] == 32 || bytes[look] == 9) { look += 1 }
                    if look < n && bytes[look] == 40 { // '('
                        hasCall = true
                        if primaryCallee == nil {
                            primaryCallee = ident
                        }
                    }
                    if i - start >= 2 {
                        identifiers.append(ident)
                    }
                }
                continue
            }
            i += 1
        }

        return (identifiers, primaryCallee, hasCall)
    }

    private static func makeMoveCandidate(
        hunkIndex: Int,
        range: Range<Int>,
        hunkRange: Range<Int>,
        isPure: Bool,
        isShort: Bool,
        normalizedLines: [String],
        symbols: [FileSymbolItem],
        excludedKeywords: Set<String>,
        hashComments: Bool
    ) -> MoveCandidate {
        var lineHashes: [UInt64] = []
        lineHashes.reserveCapacity(normalizedLines.count)
        var blockHash: UInt64 = 0xcbf29ce484222325
        var lineCounts: [UInt64: Int] = [:]
        var tokens: [UInt64] = []
        var tokenCounts: [UInt64: Int] = [:]
        var wordSubTokens: [UInt64] = []
        var fullSubTokens: [UInt64] = []

        for line in normalizedLines {
            let lh = fnv1a(line)
            lineHashes.append(lh)
            blockHash = (blockHash ^ lh) &* 0x100000001b3
            lineCounts[lh, default: 0] += 1
            for tok in tokenizeForSimilarity(line) {
                tokens.append(tok)
                tokenCounts[tok, default: 0] += 1
            }
            if isShort {
                let (wSubs, fSubs) = tokenizeSubTokens(line)
                wordSubTokens.append(contentsOf: wSubs)
                fullSubTokens.append(contentsOf: fSubs)
            }
        }

        let primaryCalleeSubTokens: [UInt64]?
        if isShort && normalizedLines.count == 1 {
            primaryCalleeSubTokens = extractCodeIdentifiersAndCallee(
                from: normalizedLines[0],
                excluded: excludedKeywords,
                hashComments: hashComments
            ).primaryCallee.map { identifierSubTokenHashes($0) }
        } else {
            primaryCalleeSubTokens = nil
        }

        // Collect symbols declared within this hunk's 1-based line range.
        var names = Set<String>()
        if !symbols.isEmpty {
            let start1 = range.lowerBound + 1
            let end1 = range.upperBound
            for sym in symbols where sym.lineNumber >= start1 && sym.lineNumber <= end1 {
                names.insert(sym.name)
            }
        }

        return MoveCandidate(
            hunkIndex: hunkIndex,
            lineRange: range,
            hunkLineRange: hunkRange,
            isPure: isPure,
            isShort: isShort,
            normalizedLines: normalizedLines,
            normalizedLineHashes: lineHashes,
            normalizedBlockHash: blockHash,
            tokens: tokens,
            tokenCounts: tokenCounts,
            lineCounts: lineCounts,
            symbolNames: names,
            wordSubTokens: wordSubTokens,
            fullSubTokens: fullSubTokens,
            primaryCalleeSubTokens: primaryCalleeSubTokens
        )
    }

    private static func blockSimilarity(_ a: MoveCandidate, _ b: MoveCandidate, threshold: Double) -> Double {
        tokenBlockSimilarity(
            aTokens: a.tokens,
            aTokenCounts: a.tokenCounts,
            aLineCounts: a.lineCounts,
            aLineCount: a.normalizedLineHashes.count,
            bTokens: b.tokens,
            bTokenCounts: b.tokenCounts,
            bLineCounts: b.lineCounts,
            bLineCount: b.normalizedLineHashes.count,
            threshold: threshold
        )
    }

    private static func tokenBlockSimilarity(
        aTokens: [UInt64],
        aTokenCounts: [UInt64: Int],
        aLineCounts: [UInt64: Int],
        aLineCount: Int,
        bTokens: [UInt64],
        bTokenCounts: [UInt64: Int],
        bLineCounts: [UInt64: Int],
        bLineCount: Int,
        threshold: Double
    ) -> Double {
        let totalTokens = aTokens.count + bTokens.count
        guard totalTokens > 0 else { return 0 }

        // Fast upper-bound length check: 2 * min(|A|, |B|) / (|A| + |B|) >= threshold.
        let minTokens = min(aTokens.count, bTokens.count)
        if Double(2 * minTokens) / Double(totalTokens) < threshold {
            return 0
        }

        // Fast multiset Dice upper bound: always >= token LCS Dice, so zero false negatives when pruning.
        let tokDice = multisetDice(aTokenCounts, bTokenCounts, totalCount: totalTokens)
        if tokDice < threshold {
            return 0
        }

        if totalTokens <= 2000 {
            let maxEdits = Int(ceil(Double(totalTokens) * (1.0 - threshold))) + 2
            guard let (matchedA, _) = Myers.matches(aTokens, bTokens, maxEdits: maxEdits) else {
                return 0
            }
            var matched = 0
            for flag in matchedA where flag { matched += 1 }
            return Double(2 * matched) / Double(totalTokens)
        }

        let lineDice = multisetDice(aLineCounts, bLineCounts, totalCount: aLineCount + bLineCount)
        return 0.5 * tokDice + 0.5 * lineDice
    }

    /// Sub-token (CamelCase & snake_case) similarity for 1-2 line substantive statements.
    /// Recognizes suffix-renamed/tweaked calls (e.g. `HandleEvent...` -> `HandleEvent...ByRid`)
    /// while preventing false positives between calls to completely unrelated functions.
    private static func shortBlockSimilarity(
        aLines: [String],
        bLines: [String],
        aWordSubTokens: [UInt64],
        bWordSubTokens: [UInt64],
        aFullSubTokens: [UInt64],
        bFullSubTokens: [UInt64],
        aPrimaryCallee: [UInt64]?,
        bPrimaryCallee: [UInt64]?,
        threshold: Double
    ) -> Double {
        if aLines == bLines { return 1.0 }
        guard !aWordSubTokens.isEmpty, !bWordSubTokens.isEmpty else { return 0 }

        // Guard against pairing two single-line calls to unrelated functions with similar argument lists
        // (e.g. `player.Foo(a, b, c)` vs `player.Bar(a, b, c)`).
        if aLines.count == 1 && bLines.count == 1,
           let cA = aPrimaryCallee, let cB = bPrimaryCallee,
           !cA.isEmpty, !cB.isEmpty, cA != cB {
            let calleeDice = multisetDiceOfArray(cA, cB)
            if calleeDice == 0.0 || (cA.count + cB.count >= 3 && calleeDice < 0.40) {
                return 0.0
            }
        }

        let minWordThreshold = max(0.0, threshold - 0.05)
        let wordSim = sequenceDice(aWordSubTokens, bWordSubTokens, minThreshold: minWordThreshold)
        guard wordSim >= minWordThreshold else { return 0.0 }

        let minFullThreshold = max(0.0, min(1.0, (threshold - 0.70 * wordSim) / 0.30))
        let fullSim = sequenceDice(aFullSubTokens, bFullSubTokens, minThreshold: minFullThreshold)
        guard fullSim >= minFullThreshold else { return 0.0 }

        let combined = 0.70 * wordSim + 0.30 * fullSim
        return combined >= threshold ? combined : 0.0
    }

    private static func sequenceDice(_ a: [UInt64], _ b: [UInt64], minThreshold: Double) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 0 }
        let minLen = min(a.count, b.count)
        if Double(2 * minLen) / Double(total) < minThreshold {
            return 0
        }
        let bagDice = multisetDiceOfArray(a, b)
        if bagDice < minThreshold {
            return 0
        }
        let maxEdits = min(total, Int(ceil(Double(total) * (1.0 - minThreshold))) + 2)
        guard let (matchedA, _) = Myers.matches(a, b, maxEdits: maxEdits) else {
            return 0
        }
        var matched = 0
        for flag in matchedA where flag { matched += 1 }
        return Double(2 * matched) / Double(total)
    }

    private static func multisetDiceOfArray(_ a: [UInt64], _ b: [UInt64]) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 0 }
        var countsA: [UInt64: Int] = [:]
        countsA.reserveCapacity(a.count)
        for tok in a { countsA[tok, default: 0] += 1 }
        var countsB: [UInt64: Int] = [:]
        countsB.reserveCapacity(b.count)
        for tok in b { countsB[tok, default: 0] += 1 }
        return multisetDice(countsA, countsB, totalCount: total)
    }

    private static func multisetDice(_ a: [UInt64: Int], _ b: [UInt64: Int], totalCount: Int) -> Double {
        guard totalCount > 0 else { return 0 }
        let (smaller, larger) = a.count <= b.count ? (a, b) : (b, a)
        var overlap = 0
        for (k, countA) in smaller {
            if let countB = larger[k] {
                overlap += min(countA, countB)
            }
        }
        return Double(2 * overlap) / Double(totalCount)
    }

    private static func identifierSubTokenHashes(_ ident: String) -> [UInt64] {
        let bytes = Array(ident.utf8)
        var out: [UInt64] = []
        appendSubTokenHashes(from: bytes, start: 0, end: bytes.count, to: &out)
        return out
    }

    private static func tokenizeSubTokens(_ line: String) -> (word: [UInt64], full: [UInt64]) {
        var wordTokens: [UInt64] = []
        var fullTokens: [UInt64] = []
        let bytes = Array(line.utf8)
        let n = bytes.count
        var i = 0
        while i < n {
            let b = bytes[i]
            if b == 32 || b == 9 {
                i += 1
                continue
            }
            if isWordByte(b) {
                let start = i
                while i < n && isWordByte(bytes[i]) { i += 1 }
                let beforeCount = wordTokens.count
                appendSubTokenHashes(from: bytes, start: start, end: i, to: &wordTokens)
                if wordTokens.count > beforeCount {
                    fullTokens.append(contentsOf: wordTokens[beforeCount...])
                }
            } else {
                let hash = ((0xcbf29ce484222325 ^ UInt64(b)) &* 0x100000001b3) ^ 1
                fullTokens.append(hash)
                i += 1
            }
        }
        return (wordTokens, fullTokens)
    }

    private static func appendSubTokenHashes(
        from bytes: [UInt8],
        start: Int,
        end: Int,
        to out: inout [UInt64]
    ) {
        var i = start
        while i < end {
            while i < end && bytes[i] == 95 { i += 1 } // skip '_'
            guard i < end else { break }
            let segStart = i
            i += 1
            while i < end && bytes[i] != 95 {
                let prev = bytes[i - 1]
                let curr = bytes[i]
                let isBoundary: Bool
                if isLowerASCII(prev) && isUpperASCII(curr) {
                    isBoundary = true
                } else if isUpperASCII(prev) && isUpperASCII(curr) && (i + 1 < end) && isLowerASCII(bytes[i + 1]) {
                    isBoundary = true
                } else if isDigitASCII(prev) && (isUpperASCII(curr) || isLowerASCII(curr)) {
                    isBoundary = true
                } else {
                    isBoundary = false
                }
                if isBoundary { break }
                i += 1
            }
            var hash: UInt64 = 0xcbf29ce484222325
            for j in segStart..<i {
                var ch = bytes[j]
                if ch >= 65 && ch <= 90 { ch &+= 32 } // ASCII lowercase
                hash = (hash ^ UInt64(ch)) &* 0x100000001b3
            }
            out.append(hash ^ UInt64(i - segStart))
        }
    }

    @inline(__always)
    private static func isUpperASCII(_ b: UInt8) -> Bool { b >= 65 && b <= 90 }
    @inline(__always)
    private static func isLowerASCII(_ b: UInt8) -> Bool { b >= 97 && b <= 122 }
    @inline(__always)
    private static func isDigitASCII(_ b: UInt8) -> Bool { b >= 48 && b <= 57 }

    private static func tokenizeForSimilarity(_ line: String) -> [UInt64] {
        var tokens: [UInt64] = []
        let bytes = Array(line.utf8)
        let n = bytes.count
        var i = 0
        while i < n {
            let b = bytes[i]
            if b == 32 || b == 9 {
                i += 1
                continue
            }
            if isWordByte(b) {
                var hash: UInt64 = 0xcbf29ce484222325
                let start = i
                while i < n && isWordByte(bytes[i]) {
                    hash = (hash ^ UInt64(bytes[i])) &* 0x100000001b3
                    i += 1
                }
                tokens.append(hash ^ UInt64(i - start))
            } else {
                let hash = ((0xcbf29ce484222325 ^ UInt64(b)) &* 0x100000001b3) ^ 1
                tokens.append(hash)
                i += 1
            }
        }
        return tokens
    }

    @inline(__always)
    private static func isWordByte(_ b: UInt8) -> Bool {
        (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 95 || b >= 0x80
    }

    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 {
            hash = (hash ^ UInt64(b)) &* 0x100000001b3
        }
        return hash
    }

    // MARK: 4. Cross-Hunk Rename / Refactoring Detection

    private struct RawRenameHit {
        let oldName: String
        let newName: String
        let hunkIndex: Int
        let leftLineIndex: Int
        let leftRange: Range<Int>
        let rightLineIndex: Int
        let rightRange: Range<Int>
    }

    private struct RenamePairKey: Hashable {
        let oldName: String
        let newName: String
    }

    private static let universalExcludedKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return",
        "var", "let", "const", "val", "mut", "func", "function", "def", "fn", "fun",
        "class", "struct", "enum", "interface", "protocol", "trait", "type", "typealias", "extension", "impl",
        "public", "private", "fileprivate", "internal", "protected", "open", "static", "final", "override",
        "async", "await", "try", "catch", "throw", "throws", "guard", "defer", "import", "export", "package",
        "true", "false", "nil", "null", "none", "None", "True", "False", "self", "Self", "this", "super",
        "void", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
        "float", "float32", "float64", "double", "bool", "boolean", "string", "char", "byte", "any", "object",
        "Int", "String", "Bool", "Double", "Float", "Void", "Any", "Error",
    ]

    /// Scans all `.modified` hunks' word-level diffs to detect repeated, dominant identifier renames.
    static func detectRenames(
        hunks: [Hunk],
        leftLines: [String],
        rightLines: [String],
        language: LanguageSpec = .plain,
        minOccurrences: Int = defaultRenameMinOccurrences,
        dominanceThreshold: Double = defaultRenameDominanceThreshold
    ) -> [RenameGroup] {
        guard !hunks.isEmpty else { return [] }
        let minCount = max(2, minOccurrences)
        let dominance = min(1.0, max(0.5, dominanceThreshold))

        let excluded = buildExcludedKeywordSet(for: language)
        var hits: [RawRenameHit] = []

        for (hunkIndex, hunk) in hunks.enumerated() where hunk.kind == .modified {
            guard hunk.leftStart >= 0, hunk.rightStart >= 0,
                  hunk.leftStart + hunk.leftCount <= leftLines.count,
                  hunk.rightStart + hunk.rightCount <= rightLines.count else {
                continue
            }

            let leftInline: [[Range<Int>]]
            let rightInline: [[Range<Int>]]
            if hunk.leftInline.count == hunk.leftCount && hunk.rightInline.count == hunk.rightCount {
                leftInline = hunk.leftInline
                rightInline = hunk.rightInline
            } else if hunk.leftCount <= 200 && hunk.rightCount <= 200,
                      let computed = InlineDiff.compute(
                          old: leftLines[hunk.leftStart..<(hunk.leftStart + hunk.leftCount)],
                          new: rightLines[hunk.rightStart..<(hunk.rightStart + hunk.rightCount)]
                      ) {
                leftInline = computed.old
                rightInline = computed.new
            } else {
                continue
            }

            if hunk.leftCount == hunk.rightCount {
                for row in 0..<hunk.leftCount {
                    let lLineIdx = hunk.leftStart + row
                    let rLineIdx = hunk.rightStart + row
                    let lLine = leftLines[lLineIdx]
                    let rLine = rightLines[rLineIdx]
                    let lRanges = leftInline[row]
                    let rRanges = rightInline[row]

                    if lRanges.isEmpty && rRanges.isEmpty {
                        // InlineDiff clears ranges on lines that changed end-to-end (e.g. a lone identifier line).
                        if let oldIdent = extractStandaloneIdentifier(in: lLine, excluded: excluded),
                           let newIdent = extractStandaloneIdentifier(in: rLine, excluded: excluded),
                           oldIdent.name != newIdent.name {
                            hits.append(RawRenameHit(
                                oldName: oldIdent.name,
                                newName: newIdent.name,
                                hunkIndex: hunkIndex,
                                leftLineIndex: lLineIdx,
                                leftRange: oldIdent.range,
                                rightLineIndex: rLineIdx,
                                rightRange: newIdent.range
                            ))
                        }
                        continue
                    }

                    if lRanges.count == rRanges.count {
                        for k in 0..<lRanges.count {
                            if let oldIdent = extractIdentifier(in: lLine, utf16Range: lRanges[k], excluded: excluded),
                               let newIdent = extractIdentifier(in: rLine, utf16Range: rRanges[k], excluded: excluded),
                               oldIdent.name != newIdent.name {
                                hits.append(RawRenameHit(
                                    oldName: oldIdent.name,
                                    newName: newIdent.name,
                                    hunkIndex: hunkIndex,
                                    leftLineIndex: lLineIdx,
                                    leftRange: oldIdent.range,
                                    rightLineIndex: rLineIdx,
                                    rightRange: newIdent.range
                                ))
                            }
                        }
                    } else {
                        // Mixed edits on the same line (e.g. renaming a function while adding a parameter):
                        // pair when valid identifier spans match 1-to-1 after ignoring non-identifier edits.
                        let lIdents = lRanges.compactMap { extractIdentifier(in: lLine, utf16Range: $0, excluded: excluded) }
                        let rIdents = rRanges.compactMap { extractIdentifier(in: rLine, utf16Range: $0, excluded: excluded) }
                        if lIdents.count == rIdents.count && !lIdents.isEmpty {
                            for k in 0..<lIdents.count where lIdents[k].name != rIdents[k].name {
                                hits.append(RawRenameHit(
                                    oldName: lIdents[k].name,
                                    newName: rIdents[k].name,
                                    hunkIndex: hunkIndex,
                                    leftLineIndex: lLineIdx,
                                    leftRange: lIdents[k].range,
                                    rightLineIndex: rLineIdx,
                                    rightRange: rIdents[k].range
                                ))
                            }
                        }
                    }
                }
            } else {
                // Asymmetric modified hunk: collect valid identifier edits on each side and pair only when 1-to-1.
                var lIdents: [(lineIndex: Int, name: String, range: Range<Int>)] = []
                for row in 0..<hunk.leftCount {
                    let lLineIdx = hunk.leftStart + row
                    let lLine = leftLines[lLineIdx]
                    for r in leftInline[row] {
                        if let ident = extractIdentifier(in: lLine, utf16Range: r, excluded: excluded) {
                            lIdents.append((lLineIdx, ident.name, ident.range))
                        }
                    }
                }
                var rIdents: [(lineIndex: Int, name: String, range: Range<Int>)] = []
                for row in 0..<hunk.rightCount {
                    let rLineIdx = hunk.rightStart + row
                    let rLine = rightLines[rLineIdx]
                    for r in rightInline[row] {
                        if let ident = extractIdentifier(in: rLine, utf16Range: r, excluded: excluded) {
                            rIdents.append((rLineIdx, ident.name, ident.range))
                        }
                    }
                }
                if lIdents.count == rIdents.count && !lIdents.isEmpty {
                    for k in 0..<lIdents.count where lIdents[k].name != rIdents[k].name {
                        hits.append(RawRenameHit(
                            oldName: lIdents[k].name,
                            newName: rIdents[k].name,
                            hunkIndex: hunkIndex,
                            leftLineIndex: lIdents[k].lineIndex,
                            leftRange: lIdents[k].range,
                            rightLineIndex: rIdents[k].lineIndex,
                            rightRange: rIdents[k].range
                        ))
                    }
                }
            }
        }

        guard !hits.isEmpty else { return [] }

        var hitsByPair: [RenamePairKey: [RawRenameHit]] = [:]
        var totalFromOld: [String: Int] = [:]
        var totalToNew: [String: Int] = [:]

        for hit in hits {
            let key = RenamePairKey(oldName: hit.oldName, newName: hit.newName)
            hitsByPair[key, default: []].append(hit)
            totalFromOld[hit.oldName, default: 0] += 1
            totalToNew[hit.newName, default: 0] += 1
        }

        struct CandidateGroup {
            let key: RenamePairKey
            let hits: [RawRenameHit]
            let hunkIndices: [Int]
        }

        var qualified: [CandidateGroup] = []
        for (key, pairHits) in hitsByPair {
            let count = pairHits.count
            guard count >= minCount else { continue }
            let fromTotal = totalFromOld[key.oldName] ?? count
            let toTotal = totalToNew[key.newName] ?? count
            guard Double(count) / Double(fromTotal) >= dominance,
                  Double(count) / Double(toTotal) >= dominance else {
                continue
            }
            let hunkSet = Set(pairHits.map(\.hunkIndex)).sorted()
            qualified.append(CandidateGroup(key: key, hits: pairHits, hunkIndices: hunkSet))
        }

        guard !qualified.isEmpty else { return [] }

        qualified.sort { lhs, rhs in
            if lhs.hits.count != rhs.hits.count { return lhs.hits.count > rhs.hits.count }
            let lFirst = lhs.hunkIndices.first ?? Int.max
            let rFirst = rhs.hunkIndices.first ?? Int.max
            if lFirst != rFirst { return lFirst < rFirst }
            if lhs.key.oldName != rhs.key.oldName { return lhs.key.oldName < rhs.key.oldName }
            return lhs.key.newName < rhs.key.newName
        }

        return qualified.enumerated().map { index, item in
            let colorIdx = index % RenameGroup.paletteCount
            var occurrences: [RenameOccurrence] = []
            occurrences.reserveCapacity(item.hits.count * 2)
            for hit in item.hits {
                occurrences.append(RenameOccurrence(
                    hunkIndex: hit.hunkIndex,
                    side: .left,
                    lineIndex: hit.leftLineIndex,
                    range: hit.leftRange,
                    groupID: index,
                    colorIndex: colorIdx
                ))
                occurrences.append(RenameOccurrence(
                    hunkIndex: hit.hunkIndex,
                    side: .right,
                    lineIndex: hit.rightLineIndex,
                    range: hit.rightRange,
                    groupID: index,
                    colorIndex: colorIdx
                ))
            }
            return RenameGroup(
                id: index,
                oldName: item.key.oldName,
                newName: item.key.newName,
                colorIndex: colorIdx,
                occurrenceCount: item.hits.count,
                hunkIndices: item.hunkIndices,
                occurrences: occurrences
            )
        }
    }

    private static func buildExcludedKeywordSet(for language: LanguageSpec) -> Set<String> {
        var set = universalExcludedKeywords
        set.formUnion(language.keywords)
        set.formUnion(language.typeKeywords)
        set.formUnion(language.builtinTypeKeywords)
        set.formUnion(language.constantKeywords)
        return set
    }

    private static func extractIdentifier(
        in line: String,
        utf16Range: Range<Int>,
        excluded: Set<String>
    ) -> (name: String, range: Range<Int>)? {
        let units = Array(line.utf16)
        guard utf16Range.lowerBound >= 0,
              utf16Range.upperBound <= units.count,
              utf16Range.count >= 2 else {
            return nil
        }
        let slice = units[utf16Range]
        guard isValidASCIIIdentifier(slice) else { return nil }
        let name = String(utf16CodeUnits: Array(slice), count: slice.count)
        guard !excluded.contains(name) else { return nil }
        return (name, utf16Range)
    }

    private static func extractStandaloneIdentifier(
        in line: String,
        excluded: Set<String>
    ) -> (name: String, range: Range<Int>)? {
        let units = Array(line.utf16)
        var start = 0
        var end = units.count
        while start < end && (units[start] == 32 || units[start] == 9) { start += 1 }
        while end > start && (units[end - 1] == 32 || units[end - 1] == 9) { end -= 1 }
        guard end - start >= 2 else { return nil }
        let slice = units[start..<end]
        guard isValidASCIIIdentifier(slice) else { return nil }
        let name = String(utf16CodeUnits: Array(slice), count: slice.count)
        guard !excluded.contains(name) else { return nil }
        return (name, start..<end)
    }

    /// Validates `[A-Za-z_][A-Za-z0-9_]*` with length >= 2.
    static func isValidIdentifier(_ text: String) -> Bool {
        let units = Array(text.utf16)
        return isValidASCIIIdentifier(units[...])
    }

    private static func isValidASCIIIdentifier(_ units: ArraySlice<UInt16>) -> Bool {
        guard units.count >= 2, let first = units.first else { return false }
        let validFirst = (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95
        guard validFirst else { return false }
        for u in units.dropFirst() {
            let valid = (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || (u >= 48 && u <= 57) || u == 95
            if !valid { return false }
        }
        return true
    }

    // MARK: 5. Content-Level AI Group Hunk Filtering

    /// Output of applying an AI group hunk filter to a raw `(old, new, rawHunks)` diff.
    struct GroupHunkFilterResult: Equatable, Sendable {
        /// Left-side lines after syncing every non-included raw hunk to match `newLines`.
        var filteredOldLines: [String]
        /// Remaining hunks between `filteredOldLines` and `newLines` (strictly ordered, 0-based).
        var filteredHunks: [Hunk]
        /// Maps each kept original 0-based raw hunk index to its 0-based index in `filteredHunks`.
        var rawToFilteredIndex: [Int: Int]

        var filteredOldText: String {
            filteredOldLines.joined(separator: "\n")
        }
    }

    /// Produces a filtered left-side line array in which every raw hunk NOT in `includedHunkIndices`
    /// is pre-applied onto `oldLines` so it matches `newLines` verbatim and disappears from the diff.
    /// Right-side line numbers in `newLines` remain 100% unchanged.
    static func applyGroupHunkFilter(
        oldLines: [String],
        newLines: [String],
        rawHunks: [Hunk],
        includedHunkIndices: Set<Int>
    ) -> GroupHunkFilterResult {
        guard !rawHunks.isEmpty else {
            return GroupHunkFilterResult(
                filteredOldLines: oldLines,
                filteredHunks: [],
                rawToFilteredIndex: [:]
            )
        }

        var filteredOld: [String] = []
        filteredOld.reserveCapacity(max(oldLines.count, newLines.count))
        var filteredHunks: [Hunk] = []
        filteredHunks.reserveCapacity(min(rawHunks.count, includedHunkIndices.count))
        var rawToFiltered: [Int: Int] = [:]
        rawToFiltered.reserveCapacity(min(rawHunks.count, includedHunkIndices.count))

        var oldPos = 0
        var newPos = 0

        for (rawIndex, hunk) in rawHunks.enumerated() {
            let lStart = min(max(hunk.leftStart, oldPos), oldLines.count)
            let lEnd = min(max(lStart, lStart + max(0, hunk.leftCount)), oldLines.count)
            let rStart = min(max(hunk.rightStart, newPos), newLines.count)
            let rEnd = min(max(rStart, rStart + max(0, hunk.rightCount)), newLines.count)

            // Emit unchanged context preceding this hunk (use newLines so alignment with right stays exact).
            if rStart > newPos {
                filteredOld.append(contentsOf: newLines[newPos..<rStart])
            }

            let lCount = lEnd - lStart
            let rCount = rEnd - rStart
            if includedHunkIndices.contains(rawIndex) {
                let filteredLeftStart = filteredOld.count
                if lCount > 0 {
                    filteredOld.append(contentsOf: oldLines[lStart..<lEnd])
                }
                if lCount > 0 || rCount > 0 {
                    let filteredIndex = filteredHunks.count
                    filteredHunks.append(Hunk(
                        leftStart: filteredLeftStart,
                        leftCount: lCount,
                        rightStart: rStart,
                        rightCount: rCount
                    ))
                    rawToFiltered[rawIndex] = filteredIndex
                }
            } else {
                // Non-group hunk: sync left side to match right side so this change vanishes completely.
                if rCount > 0 {
                    filteredOld.append(contentsOf: newLines[rStart..<rEnd])
                }
            }

            oldPos = lEnd
            newPos = rEnd
        }

        if newPos < newLines.count {
            filteredOld.append(contentsOf: newLines[newPos..<newLines.count])
        }

        return GroupHunkFilterResult(
            filteredOldLines: filteredOld,
            filteredHunks: filteredHunks,
            rawToFilteredIndex: rawToFiltered
        )
    }

    /// String convenience overload of `applyGroupHunkFilter(oldLines:newLines:rawHunks:includedHunkIndices:)`.
    static func applyGroupHunkFilter(
        oldText: String,
        newText: String,
        rawHunks: [Hunk],
        includedHunkIndices: Set<Int>
    ) -> GroupHunkFilterResult {
        applyGroupHunkFilter(
            oldLines: TextCodec.splitLines(oldText),
            newLines: TextCodec.splitLines(newText),
            rawHunks: rawHunks,
            includedHunkIndices: includedHunkIndices
        )
    }
}
