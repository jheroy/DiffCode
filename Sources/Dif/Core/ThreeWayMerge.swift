import Foundation

/// Which input branch/side a merge chunk's proposal comes from (Left = ours/HEAD, Right = theirs/incoming).
enum MergeSide: String, CaseIterable, Equatable, Hashable, Sendable {
    case left
    case right
}

/// Which of the three visible panes in the 3-way merge viewer.
enum MergePane: Int, CaseIterable, Equatable, Hashable, Sendable {
    case left = 0
    case center = 1
    case right = 2
}

/// Line-level change shape of one side relative to the common ancestor (Base).
enum MergeChangeSubkind: Equatable, Hashable, Sendable {
    case added
    case deleted
    case modified

    var hunkKind: Hunk.Kind {
        switch self {
        case .added: return .added
        case .deleted: return .deleted
        case .modified: return .modified
        }
    }
}

/// Resolution state of one side (`left` or `right`) for a single `MergeChunk`.
enum MergeSideResolution: Equatable, Hashable, Sendable {
    /// That side made no change relative to Base in this chunk.
    case notApplicable
    /// Still waiting for the user to accept (`»`/`«`) or ignore (`✕`).
    case unresolved
    /// Accepted into the Center result.
    case accepted
    /// Explicitly ignored/dismissed (`✕`).
    case ignored
}

/// Full one-click resolution choices for a conflict chunk.
enum ConflictResolutionChoice: Equatable, Hashable, Sendable {
    case acceptLeft
    case acceptRight
    case acceptBothLeftFirst
    case acceptBothRightFirst
    case keepBase
}

/// Non-text conflict resolution action (binary, image, or modify/delete).
enum NonTextConflictAction: Equatable, Hashable, Sendable {
    case keepLeft
    case keepRight
    case deleteFile
}

/// One logical change or conflict region across Left (ours), Base (ancestor), Center (result), and Right (theirs).
struct MergeChunk: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case leftOnly(MergeChangeSubkind)
        case rightOnly(MergeChangeSubkind)
        case bothIdentical(MergeChangeSubkind)
        case conflict
    }

    let id: Int
    let kind: Kind
    var leftRange: Range<Int>
    var baseRange: Range<Int>
    var rightRange: Range<Int>
    var centerRange: Range<Int>
    var leftState: MergeSideResolution
    var rightState: MergeSideResolution
    /// Order in which sides were accepted for this chunk (supports GoLand's sequential Left->Right or Right->Left append).
    var acceptedOrder: [MergeSide] = []
    /// True once manual text edits touched this chunk's `centerRange`.
    var manuallyEdited: Bool = false

    /// Word-level changed character ranges (UTF-16) per line on Left / Base-for-Left / Right / Base-for-Right.
    var leftInline: [[Range<Int>]] = []
    var baseLeftInline: [[Range<Int>]] = []
    var rightInline: [[Range<Int>]] = []
    var baseRightInline: [[Range<Int>]] = []

    var isConflict: Bool { kind == .conflict }
    var isNonConflicting: Bool { !isConflict }
    var hasLeftChange: Bool { leftState != .notApplicable }
    var hasRightChange: Bool { rightState != .notApplicable }
    var isLeftUnresolved: Bool { leftState == .unresolved }
    var isRightUnresolved: Bool { rightState == .unresolved }
    var isUnresolved: Bool { isLeftUnresolved || isRightUnresolved }
    var isResolved: Bool { !isUnresolved }
    var isUnresolvedConflict: Bool { isConflict && isUnresolved }
    var isUnresolvedNonConflict: Bool { !isConflict && isUnresolved }

    /// Visual change classification of `side` relative to Base for coloring bands and bridges.
    func subkind(for side: MergeSide) -> MergeChangeSubkind {
        switch kind {
        case .leftOnly(let s), .rightOnly(let s), .bothIdentical(let s):
            return s
        case .conflict:
            let sideCount = side == .left ? leftRange.count : rightRange.count
            if baseRange.isEmpty { return .added }
            if sideCount == 0 { return .deleted }
            return .modified
        }
    }

    /// True if `side` can still be appended after the opposite side was already accepted in a conflict.
    func isAppendMode(for side: MergeSide) -> Bool {
        guard isConflict else { return false }
        switch side {
        case .left: return leftState == .unresolved && rightState == .accepted
        case .right: return rightState == .unresolved && leftState == .accepted
        }
    }
}

/// Synchronized scroll unit across Left, Center, and Right panes.
/// `chunk == -1` for unchanged runs; `chunk >= 0` for `MergeChunk` index `chunk`.
struct MergeSegment: Equatable, Sendable {
    var virtualStart: Int
    var leftStart: Int
    var leftCount: Int
    var centerStart: Int
    var centerCount: Int
    var rightStart: Int
    var rightCount: Int
    var chunk: Int

    var span: Int { max(leftCount, max(centerCount, rightCount)) }
}

/// Column titles displayed above the 3 panes.
struct ThreeWayMergeTitles: Equatable, Sendable {
    var left: String
    var center: String
    var right: String
}

/// Pure 3-way line-level merge analyzer mirroring Git/GoLand conflict clustering.
enum ThreeWayMergeEngine {
    /// Computes disjoint sorted `Hunk`s from `old` to `new` using Myers LCS.
    static func computeLineHunks(old: [String], new: [String]) -> [Hunk] {
        if old == new { return [] }
        if old.isEmpty {
            return [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: new.count)]
        }
        if new.isEmpty {
            return [Hunk(leftStart: 0, leftCount: old.count, rightStart: 0, rightCount: 0)]
        }
        let maxEdits = max(1200, old.count + new.count)
        guard let (matchedA, matchedB) = Myers.matches(old, new, maxEdits: maxEdits) else {
            // Trim exact common prefix/suffix so even very large diffs remain bounded around real changes.
            var prefix = 0
            while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < old.count - prefix, suffix < new.count - prefix,
                  old[old.count - 1 - suffix] == new[new.count - 1 - suffix] {
                suffix += 1
            }
            let lc = old.count - prefix - suffix
            let rc = new.count - prefix - suffix
            guard lc > 0 || rc > 0 else { return [] }
            return [Hunk(leftStart: prefix, leftCount: lc, rightStart: prefix, rightCount: rc)]
        }

        var hunks: [Hunk] = []
        var ia = 0
        var ib = 0
        while ia < old.count || ib < new.count {
            while ia < old.count, ib < new.count, matchedA[ia], matchedB[ib] {
                ia += 1
                ib += 1
            }
            if ia >= old.count, ib >= new.count { break }
            let startA = ia
            let startB = ib
            while ia < old.count, !matchedA[ia] { ia += 1 }
            while ib < new.count, !matchedB[ib] { ib += 1 }
            if ia > startA || ib > startB {
                hunks.append(Hunk(leftStart: startA, leftCount: ia - startA, rightStart: startB, rightCount: ib - startB))
            }
        }
        return hunks
    }

    /// Computes 3-way `MergeChunk`s directly from `base`, `left`, and `right` line arrays.
    static func compute(base: [String], left: [String], right: [String]) -> [MergeChunk] {
        let leftHunks = computeLineHunks(old: base, new: left)
        let rightHunks = computeLineHunks(old: base, new: right)
        return buildChunks(base: base, left: left, right: right, leftHunks: leftHunks, rightHunks: rightHunks)
    }

    /// Clusters precomputed Base->Left and Base->Right hunks into non-conflicting and conflicting `MergeChunk`s.
    static func buildChunks(
        base: [String],
        left: [String],
        right: [String],
        leftHunks rawLeftHunks: [Hunk],
        rightHunks rawRightHunks: [Hunk]
    ) -> [MergeChunk] {
        // Both-added (AA) case: empty Base with non-empty Left and Right. Align identical runs between Left and Right
        // as `.bothIdentical(.added)` (so one-click non-conflict merge picks them up) and differing runs as `.conflict`.
        if base.isEmpty, !left.isEmpty, !right.isEmpty {
            return buildBothAddedChunks(left: left, right: right)
        }

        let leftHunks = rawLeftHunks.sorted { $0.leftStart < $1.leftStart }
        let rightHunks = rawRightHunks.sorted { $0.leftStart < $1.leftStart }

        var chunks: [MergeChunk] = []
        var li = 0
        var ri = 0
        var leftDelta = 0
        var rightDelta = 0
        var nextID = 0

        while li < leftHunks.count || ri < rightHunks.count {
            let baseStart: Int
            var baseEnd: Int
            if li < leftHunks.count, ri < rightHunks.count {
                if leftHunks[li].leftStart <= rightHunks[ri].leftStart {
                    baseStart = leftHunks[li].leftStart
                    baseEnd = leftHunks[li].leftStart + leftHunks[li].leftCount
                } else {
                    baseStart = rightHunks[ri].leftStart
                    baseEnd = rightHunks[ri].leftStart + rightHunks[ri].leftCount
                }
            } else if li < leftHunks.count {
                baseStart = leftHunks[li].leftStart
                baseEnd = leftHunks[li].leftStart + leftHunks[li].leftCount
            } else {
                baseStart = rightHunks[ri].leftStart
                baseEnd = rightHunks[ri].leftStart + rightHunks[ri].leftCount
            }

            let liStart = li
            let riStart = ri
            var progressed = true
            while progressed {
                progressed = false
                while li < leftHunks.count, leftHunks[li].leftStart <= baseEnd {
                    baseEnd = max(baseEnd, leftHunks[li].leftStart + leftHunks[li].leftCount)
                    li += 1
                    progressed = true
                }
                while ri < rightHunks.count, rightHunks[ri].leftStart <= baseEnd {
                    baseEnd = max(baseEnd, rightHunks[ri].leftStart + rightHunks[ri].leftCount)
                    ri += 1
                    progressed = true
                }
            }

            let leftStart = min(max(0, baseStart + leftDelta), left.count)
            for idx in liStart..<li {
                leftDelta += leftHunks[idx].rightCount - leftHunks[idx].leftCount
            }
            let leftEnd = min(max(leftStart, baseEnd + leftDelta), left.count)

            let rightStart = min(max(0, baseStart + rightDelta), right.count)
            for idx in riStart..<ri {
                rightDelta += rightHunks[idx].rightCount - rightHunks[idx].leftCount
            }
            let rightEnd = min(max(rightStart, baseEnd + rightDelta), right.count)

            let safeBaseStart = min(max(0, baseStart), base.count)
            let safeBaseEnd = min(max(safeBaseStart, baseEnd), base.count)

            let baseRange = safeBaseStart..<safeBaseEnd
            let leftRange = leftStart..<leftEnd
            let rightRange = rightStart..<rightEnd

            let baseSlice = Array(base[baseRange])
            let leftSlice = Array(left[leftRange])
            let rightSlice = Array(right[rightRange])

            let leftChanged = (li > liStart) && (leftSlice != baseSlice)
            let rightChanged = (ri > riStart) && (rightSlice != baseSlice)

            if !leftChanged && !rightChanged {
                continue
            }

            let kind: MergeChunk.Kind
            let leftState: MergeSideResolution
            let rightState: MergeSideResolution

            func subkind(for sideCount: Int) -> MergeChangeSubkind {
                if baseRange.isEmpty { return .added }
                if sideCount == 0 { return .deleted }
                return .modified
            }

            if leftChanged && !rightChanged {
                kind = .leftOnly(subkind(for: leftRange.count))
                leftState = .unresolved
                rightState = .notApplicable
            } else if !leftChanged && rightChanged {
                kind = .rightOnly(subkind(for: rightRange.count))
                leftState = .notApplicable
                rightState = .unresolved
            } else if leftSlice == rightSlice {
                kind = .bothIdentical(subkind(for: leftRange.count))
                leftState = .unresolved
                rightState = .unresolved
            } else {
                kind = .conflict
                leftState = .unresolved
                rightState = .unresolved
            }

            var chunk = MergeChunk(
                id: nextID,
                kind: kind,
                leftRange: leftRange,
                baseRange: baseRange,
                rightRange: rightRange,
                centerRange: baseRange,
                leftState: leftState,
                rightState: rightState
            )
            populateInlineHighlights(&chunk, base: base, left: left, right: right)
            chunks.append(chunk)
            nextID += 1
        }

        return chunks
    }

    private static func buildBothAddedChunks(left: [String], right: [String]) -> [MergeChunk] {
        let diffHunks = computeLineHunks(old: left, new: right)
        var chunks: [MergeChunk] = []
        var nextID = 0
        var lPos = 0
        var rPos = 0

        for h in diffHunks {
            if h.leftStart > lPos, h.rightStart > rPos {
                chunks.append(MergeChunk(
                    id: nextID,
                    kind: .bothIdentical(.added),
                    leftRange: lPos..<h.leftStart,
                    baseRange: 0..<0,
                    rightRange: rPos..<h.rightStart,
                    centerRange: 0..<0,
                    leftState: .unresolved,
                    rightState: .unresolved
                ))
                nextID += 1
            }
            var conflict = MergeChunk(
                id: nextID,
                kind: .conflict,
                leftRange: h.leftStart..<(h.leftStart + h.leftCount),
                baseRange: 0..<0,
                rightRange: h.rightStart..<(h.rightStart + h.rightCount),
                centerRange: 0..<0,
                leftState: .unresolved,
                rightState: .unresolved
            )
            if h.leftCount > 0, h.rightCount > 0, h.leftCount <= 200, h.rightCount <= 200,
               let inline = InlineDiff.compute(old: left[conflict.leftRange], new: right[conflict.rightRange]) {
                conflict.leftInline = inline.old
                conflict.rightInline = inline.new
            }
            chunks.append(conflict)
            nextID += 1
            lPos = h.leftStart + h.leftCount
            rPos = h.rightStart + h.rightCount
        }

        if lPos < left.count, rPos < right.count {
            chunks.append(MergeChunk(
                id: nextID,
                kind: .bothIdentical(.added),
                leftRange: lPos..<left.count,
                baseRange: 0..<0,
                rightRange: rPos..<right.count,
                centerRange: 0..<0,
                leftState: .unresolved,
                rightState: .unresolved
            ))
        }
        return chunks
    }

    private static func populateInlineHighlights(_ chunk: inout MergeChunk, base: [String], left: [String], right: [String]) {
        if chunk.hasLeftChange, !chunk.baseRange.isEmpty, !chunk.leftRange.isEmpty,
           chunk.baseRange.count <= 200, chunk.leftRange.count <= 200,
           let inline = InlineDiff.compute(old: base[chunk.baseRange], new: left[chunk.leftRange]) {
            chunk.baseLeftInline = inline.old
            chunk.leftInline = inline.new
        }
        if chunk.hasRightChange, !chunk.baseRange.isEmpty, !chunk.rightRange.isEmpty,
           chunk.baseRange.count <= 200, chunk.rightRange.count <= 200,
           let inline = InlineDiff.compute(old: base[chunk.baseRange], new: right[chunk.rightRange]) {
            chunk.baseRightInline = inline.old
            chunk.rightInline = inline.new
        }
    }
}

/// Interactive 3-way merge document holding Left (ours), Base (ancestor), Center (editable result), and Right (theirs),
/// with unified atomic Undo/Redo across chunk actions and direct Center text editing.
final class ThreeWayMergeDocument {
    struct LineRangeEdit: Equatable {
        var range: Range<Int>
        var oldLines: [String]
        var newLines: [String]
    }

    struct MergeUndoGroup {
        var edits: [LineRangeEdit]
        var chunksBefore: [MergeChunk]
        var chunksAfter: [MergeChunk]
        var selectionBefore: EditorSession.Selection
        var selectionAfter: EditorSession.Selection
        var kind: EditorSession.Kind
        var time: TimeInterval
    }

    static let undoLimit = 300

    let left: TextBuffer
    let base: [String]
    let center: TextBuffer
    let right: TextBuffer
    let language: LanguageSpec
    var format: TextFormat
    var titles: ThreeWayMergeTitles

    private(set) var chunks: [MergeChunk]
    private(set) var segments: [MergeSegment] = []
    private(set) var virtualLineCount: Int = 0

    private let initialChunks: [MergeChunk]
    private var undoStack: [MergeUndoGroup] = []
    private var redoStack: [MergeUndoGroup] = []
    private var groupOpen = false
    private(set) var version = 0
    private(set) var savedVersion = 0

    /// Active IME composition range inside `center`, never recorded into undo history.
    private(set) var marked: (row: Int, range: Range<Int>)?
    private(set) lazy var indentUnit: String = TextEditing.indentUnit(
        for: center.lines.isEmpty ? (left.lines.isEmpty ? right.lines : left.lines) : center.lines
    )

    private var lineStarts: [Int] = [0]
    private var validStarts = 1

    init(
        left: TextBuffer,
        base: [String],
        center: TextBuffer,
        right: TextBuffer,
        chunks: [MergeChunk],
        language: LanguageSpec,
        format: TextFormat = TextFormat(encoding: .utf8, bom: false, newline: "\n", finalNewline: true),
        titles: ThreeWayMergeTitles
    ) {
        self.left = left
        self.base = base
        self.center = center
        self.right = right
        self.chunks = chunks
        self.initialChunks = chunks
        self.language = language
        self.format = format
        self.titles = titles
        rebuildSegments()
    }

    var canUndo: Bool { marked == nil && !undoStack.isEmpty }
    var canRedo: Bool { marked == nil && !redoStack.isEmpty }
    var isModified: Bool { version != savedVersion }

    var unresolvedConflictCount: Int {
        chunks.reduce(0) { $0 + ($1.isUnresolvedConflict ? 1 : 0) }
    }

    var totalConflictCount: Int {
        chunks.reduce(0) { $0 + ($1.isConflict ? 1 : 0) }
    }

    var unresolvedNonConflictCount: Int {
        chunks.reduce(0) { $0 + ($1.isUnresolvedNonConflict ? 1 : 0) }
    }

    var unresolvedLeftNonConflictCount: Int {
        chunks.reduce(0) { $0 + ($1.isUnresolvedNonConflict && $1.hasLeftChange ? 1 : 0) }
    }

    var unresolvedRightNonConflictCount: Int {
        chunks.reduce(0) { $0 + ($1.isUnresolvedNonConflict && $1.hasRightChange ? 1 : 0) }
    }

    var unresolvedCount: Int {
        chunks.reduce(0) { $0 + ($1.isUnresolved ? 1 : 0) }
    }

    func markSaved() {
        savedVersion = version
    }

    func closeGroup() {
        groupOpen = false
    }

    func lines(for side: MergeSide, range: Range<Int>) -> [String] {
        let source = side == .left ? left.lines : right.lines
        let lo = min(max(0, range.lowerBound), source.count)
        let hi = min(max(lo, range.upperBound), source.count)
        return Array(source[lo..<hi])
    }

    func encodedCenterData() -> Data? {
        guard marked == nil else { return nil }
        if center.lines.isEmpty {
            return format.bom && format.encoding == .utf8 ? Data([0xEF, 0xBB, 0xBF]) : Data()
        }
        return TextCodec.encode(center.lines, format: format, crlf: nil)
    }

    // MARK: GoLand chunk operations

    /// Accepts `side` for `chunkIndex`:
    /// - Non-conflicting chunk: replaces `centerRange` with `side`'s lines and marks applicable side(s) accepted.
    /// - Conflict chunk: if the opposite side was already accepted, appends `side`'s lines after it;
    ///   otherwise replaces `centerRange` with `side`'s lines while keeping the opposite side unresolved (if it was)
    ///   so the user can either append it next (`+«`/`+»`) or dismiss it (`✕`).
    @discardableResult
    func acceptSide(_ side: MergeSide, chunkIndex: Int, selection: EditorSession.Selection) -> Bool {
        guard chunks.indices.contains(chunkIndex) else { return false }
        let chunk = chunks[chunkIndex]
        let sideState = side == .left ? chunk.leftState : chunk.rightState
        guard sideState == .unresolved else { return false }

        let sideRange = side == .left ? chunk.leftRange : chunk.rightRange
        let sideLines = lines(for: side, range: sideRange)
        let currentCenter = Array(center.lines[clampedCenterRange(chunk.centerRange)])
        let otherSide: MergeSide = side == .left ? .right : .left
        let otherState = otherSide == .left ? chunk.leftState : chunk.rightState

        let newLines: [String]
        var nextChunk = chunk

        switch chunk.kind {
        case .leftOnly:
            guard side == .left else { return false }
            newLines = sideLines
            nextChunk.leftState = .accepted
            nextChunk.acceptedOrder = [.left]
        case .rightOnly:
            guard side == .right else { return false }
            newLines = sideLines
            nextChunk.rightState = .accepted
            nextChunk.acceptedOrder = [.right]
        case .bothIdentical:
            newLines = sideLines
            nextChunk.leftState = .accepted
            nextChunk.rightState = .accepted
            nextChunk.acceptedOrder = [side]
        case .conflict:
            if otherState == .accepted {
                newLines = currentCenter + sideLines
                if side == .left { nextChunk.leftState = .accepted } else { nextChunk.rightState = .accepted }
                if !nextChunk.acceptedOrder.contains(side) { nextChunk.acceptedOrder.append(side) }
            } else {
                newLines = sideLines
                if side == .left { nextChunk.leftState = .accepted } else { nextChunk.rightState = .accepted }
                nextChunk.acceptedOrder = [side]
            }
        }

        return applyChunkReplacement(
            chunkIndex: chunkIndex,
            newLines: newLines,
            updatedChunk: nextChunk,
            selectionBefore: selection
        )
    }

    /// Dismisses `side` for `chunkIndex` without modifying Center text.
    @discardableResult
    func ignoreSide(_ side: MergeSide, chunkIndex: Int, selection: EditorSession.Selection) -> Bool {
        guard chunks.indices.contains(chunkIndex) else { return false }
        let chunk = chunks[chunkIndex]
        let sideState = side == .left ? chunk.leftState : chunk.rightState
        guard sideState == .unresolved else { return false }

        let beforeChunks = chunks
        var nextChunk = chunk
        switch chunk.kind {
        case .leftOnly:
            guard side == .left else { return false }
            nextChunk.leftState = .ignored
        case .rightOnly:
            guard side == .right else { return false }
            nextChunk.rightState = .ignored
        case .bothIdentical:
            nextChunk.leftState = .ignored
            nextChunk.rightState = .ignored
        case .conflict:
            if side == .left { nextChunk.leftState = .ignored } else { nextChunk.rightState = .ignored }
        }

        chunks[chunkIndex] = nextChunk
        rebuildSegments()
        closeGroup()
        pushUndo(MergeUndoGroup(
            edits: [],
            chunksBefore: beforeChunks,
            chunksAfter: chunks,
            selectionBefore: selection,
            selectionAfter: selection,
            kind: .other,
            time: Self.now
        ))
        return true
    }

    /// Resolves conflict `chunkIndex` in a single atomic operation (`Left`, `Right`, `Left+Right`, `Right+Left`, `Base`).
    @discardableResult
    func resolveConflict(_ chunkIndex: Int, choice: ConflictResolutionChoice, selection: EditorSession.Selection) -> Bool {
        guard chunks.indices.contains(chunkIndex) else { return false }
        let chunk = chunks[chunkIndex]
        let leftLines = lines(for: .left, range: chunk.leftRange)
        let rightLines = lines(for: .right, range: chunk.rightRange)
        let baseLines = Array(base[min(max(0, chunk.baseRange.lowerBound), base.count)..<min(max(chunk.baseRange.lowerBound, chunk.baseRange.upperBound), base.count)])

        var nextChunk = chunk
        let newLines: [String]
        switch choice {
        case .acceptLeft:
            newLines = leftLines
            nextChunk.leftState = chunk.hasLeftChange ? .accepted : .notApplicable
            nextChunk.rightState = chunk.hasRightChange ? .ignored : .notApplicable
            nextChunk.acceptedOrder = chunk.hasLeftChange ? [.left] : []
        case .acceptRight:
            newLines = rightLines
            nextChunk.leftState = chunk.hasLeftChange ? .ignored : .notApplicable
            nextChunk.rightState = chunk.hasRightChange ? .accepted : .notApplicable
            nextChunk.acceptedOrder = chunk.hasRightChange ? [.right] : []
        case .acceptBothLeftFirst:
            newLines = leftLines + rightLines
            nextChunk.leftState = chunk.hasLeftChange ? .accepted : .notApplicable
            nextChunk.rightState = chunk.hasRightChange ? .accepted : .notApplicable
            nextChunk.acceptedOrder = [.left, .right]
        case .acceptBothRightFirst:
            newLines = rightLines + leftLines
            nextChunk.leftState = chunk.hasLeftChange ? .accepted : .notApplicable
            nextChunk.rightState = chunk.hasRightChange ? .accepted : .notApplicable
            nextChunk.acceptedOrder = [.right, .left]
        case .keepBase:
            newLines = baseLines
            nextChunk.leftState = chunk.hasLeftChange ? .ignored : .notApplicable
            nextChunk.rightState = chunk.hasRightChange ? .ignored : .notApplicable
            nextChunk.acceptedOrder = []
        }

        return applyChunkReplacement(
            chunkIndex: chunkIndex,
            newLines: newLines,
            updatedChunk: nextChunk,
            selectionBefore: selection
        )
    }

    /// One-click merge of all unresolved non-conflicting changes (or only those on `sideFilter`) as a single undo step.
    /// Returns the number of chunks merged.
    @discardableResult
    func applyAllNonConflicting(sideFilter: MergeSide? = nil, selection: EditorSession.Selection) -> Int {
        let targets = chunks.indices.filter { idx in
            let chunk = chunks[idx]
            guard chunk.isUnresolvedNonConflict else { return false }
            switch sideFilter {
            case nil: return true
            case .left: return chunk.hasLeftChange
            case .right: return chunk.hasRightChange
            }
        }
        guard !targets.isEmpty else { return 0 }

        let beforeChunks = chunks
        var updatedChunks = chunks
        var deltaPerChunk = [Int](repeating: 0, count: chunks.count)
        var edits: [LineRangeEdit] = []
        edits.reserveCapacity(targets.count)

        // Apply bottom-to-top so earlier chunk `centerRange` indices remain exact without shifting mid-loop.
        for idx in targets.reversed() {
            let chunk = updatedChunks[idx]
            let side: MergeSide
            if let sideFilter {
                side = sideFilter
            } else {
                side = chunk.hasLeftChange ? .left : .right
            }
            let sideRange = side == .left ? chunk.leftRange : chunk.rightRange
            let newLines = lines(for: side, range: sideRange)
            let range = clampedCenterRange(chunk.centerRange)
            let oldLines = Array(center.lines[range])
            let edit = LineRangeEdit(range: range, oldLines: oldLines, newLines: newLines)
            applyLineRangeEdit(edit)
            edits.append(edit)

            deltaPerChunk[idx] = newLines.count - range.count
            if updatedChunks[idx].hasLeftChange { updatedChunks[idx].leftState = .accepted }
            if updatedChunks[idx].hasRightChange { updatedChunks[idx].rightState = .accepted }
            updatedChunks[idx].acceptedOrder = [side]
        }

        // Propagate cumulative deltas forward across all chunks.
        var cumulativeDelta = 0
        for idx in updatedChunks.indices {
            let lo = updatedChunks[idx].centerRange.lowerBound + cumulativeDelta
            let hi = updatedChunks[idx].centerRange.upperBound + cumulativeDelta + deltaPerChunk[idx]
            updatedChunks[idx].centerRange = lo..<max(lo, hi)
            cumulativeDelta += deltaPerChunk[idx]
        }

        chunks = updatedChunks
        rebuildSegments()
        closeGroup()
        let clampedAfter = clampSelection(selection)
        pushUndo(MergeUndoGroup(
            edits: edits,
            chunksBefore: beforeChunks,
            chunksAfter: updatedChunks,
            selectionBefore: selection,
            selectionAfter: clampedAfter,
            kind: .other,
            time: Self.now
        ))
        return targets.count
    }

    /// Accepts `side` across every still-unresolved chunk (both non-conflicting and conflicts) in one undo step.
    @discardableResult
    func acceptAll(_ side: MergeSide, selection: EditorSession.Selection) -> Int {
        let targets = chunks.indices.filter { chunks[$0].isUnresolved }
        guard !targets.isEmpty else { return 0 }

        let beforeChunks = chunks
        var updatedChunks = chunks
        var deltaPerChunk = [Int](repeating: 0, count: chunks.count)
        var edits: [LineRangeEdit] = []
        edits.reserveCapacity(targets.count)

        for idx in targets.reversed() {
            let chunk = updatedChunks[idx]
            let sideRange = side == .left ? chunk.leftRange : chunk.rightRange
            let newLines = lines(for: side, range: sideRange)
            let range = clampedCenterRange(chunk.centerRange)
            let oldLines = Array(center.lines[range])
            let edit = LineRangeEdit(range: range, oldLines: oldLines, newLines: newLines)
            applyLineRangeEdit(edit)
            edits.append(edit)

            deltaPerChunk[idx] = newLines.count - range.count
            if side == .left {
                updatedChunks[idx].leftState = chunk.hasLeftChange ? .accepted : .notApplicable
                updatedChunks[idx].rightState = chunk.hasRightChange ? .ignored : .notApplicable
                updatedChunks[idx].acceptedOrder = chunk.hasLeftChange ? [.left] : []
            } else {
                updatedChunks[idx].rightState = chunk.hasRightChange ? .accepted : .notApplicable
                updatedChunks[idx].leftState = chunk.hasLeftChange ? .ignored : .notApplicable
                updatedChunks[idx].acceptedOrder = chunk.hasRightChange ? [.right] : []
            }
        }

        var cumulativeDelta = 0
        for idx in updatedChunks.indices {
            let lo = updatedChunks[idx].centerRange.lowerBound + cumulativeDelta
            let hi = updatedChunks[idx].centerRange.upperBound + cumulativeDelta + deltaPerChunk[idx]
            updatedChunks[idx].centerRange = lo..<max(lo, hi)
            cumulativeDelta += deltaPerChunk[idx]
        }

        chunks = updatedChunks
        rebuildSegments()
        closeGroup()
        let clampedAfter = clampSelection(selection)
        pushUndo(MergeUndoGroup(
            edits: edits,
            chunksBefore: beforeChunks,
            chunksAfter: updatedChunks,
            selectionBefore: selection,
            selectionAfter: clampedAfter,
            kind: .other,
            time: Self.now
        ))
        return targets.count
    }

    /// Restores Center text to `base` and resets all chunks back to their initial unresolved state (undoable).
    @discardableResult
    func resetToBase(selection: EditorSession.Selection) -> Bool {
        guard center.lines != base || chunks != initialChunks else { return false }
        let beforeChunks = chunks
        let edit = LineRangeEdit(range: 0..<center.lines.count, oldLines: center.lines, newLines: base)
        applyLineRangeEdit(edit)
        chunks = initialChunks
        rebuildSegments()
        closeGroup()
        let afterSel = clampSelection(selection)
        pushUndo(MergeUndoGroup(
            edits: [edit],
            chunksBefore: beforeChunks,
            chunksAfter: chunks,
            selectionBefore: selection,
            selectionAfter: afterSel,
            kind: .other,
            time: Self.now
        ))
        return true
    }

    private func applyChunkReplacement(
        chunkIndex: Int,
        newLines: [String],
        updatedChunk: MergeChunk,
        selectionBefore: EditorSession.Selection
    ) -> Bool {
        let beforeChunks = chunks
        let range = clampedCenterRange(updatedChunk.centerRange)
        let oldLines = Array(center.lines[range])
        let edit = LineRangeEdit(range: range, oldLines: oldLines, newLines: newLines)
        applyLineRangeEdit(edit)

        let delta = newLines.count - range.count
        var nextChunk = updatedChunk
        nextChunk.centerRange = range.lowerBound..<(range.lowerBound + newLines.count)
        chunks[chunkIndex] = nextChunk
        for idx in (chunkIndex + 1)..<chunks.count {
            chunks[idx].centerRange = (chunks[idx].centerRange.lowerBound + delta)..<(chunks[idx].centerRange.upperBound + delta)
        }
        rebuildSegments()
        closeGroup()

        let caretPos = TextPosition(row: range.lowerBound, column: 0)
        let afterSel = clampSelection((caretPos, caretPos))
        pushUndo(MergeUndoGroup(
            edits: [edit],
            chunksBefore: beforeChunks,
            chunksAfter: chunks,
            selectionBefore: selectionBefore,
            selectionAfter: afterSel,
            kind: .other,
            time: Self.now
        ))
        return true
    }

    // MARK: Direct Center Editing & IME Composition

    /// Replaces arbitrary text in `center` (keyboard typing, paste, delete, Vim-style actions) while keeping chunk ranges aligned.
    @discardableResult
    func replaceCenter(
        from: TextPosition,
        to: TextPosition,
        with text: String,
        kind: EditorSession.Kind,
        selection: EditorSession.Selection
    ) -> (end: TextPosition, raw: LineEdit) {
        let beforeChunks = chunks
        let hadEmptyCenter = center.lines.isEmpty
        var workingLines = hadEmptyCenter ? [""] : center.lines
        let a = TextEditing.clamp(min(from, to), in: workingLines)
        let b = TextEditing.clamp(max(from, to), in: workingLines)
        let oldAffected = hadEmptyCenter ? [] : Array(workingLines[a.row...b.row])
        let result = TextEditing.replace(&workingLines, from: a, to: b, with: text)
        let newAffected = Array(workingLines[result.raw.start..<(result.raw.start + result.raw.inserted)])

        let editRange: Range<Int> = hadEmptyCenter ? 0..<0 : a.row..<(b.row + 1)
        let lineEdit = LineRangeEdit(range: editRange, oldLines: oldAffected, newLines: newAffected)
        applyLineRangeEdit(lineEdit)

        let chunkDelta = LineEdit(start: result.change.start, removed: result.change.removed, inserted: result.change.inserted)
        if hadEmptyCenter, !center.lines.isEmpty {
            adjustChunks(for: LineEdit(start: 0, removed: 0, inserted: center.lines.count))
        } else {
            adjustChunks(for: chunkDelta)
        }
        rebuildSegments()

        let afterSel: EditorSession.Selection = (result.end, result.end)
        recordDirectEdit(
            lineEdit,
            chunksBefore: beforeChunks,
            chunksAfter: chunks,
            kind: kind,
            before: selection,
            after: afterSel
        )
        return (result.end, result.raw)
    }

    func setMarked(_ text: String, at position: TextPosition) {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        if center.lines.isEmpty {
            applyLineRangeEdit(LineRangeEdit(range: 0..<0, oldLines: [], newLines: [""]))
        }
        let start: TextPosition
        let end: TextPosition
        if let marked {
            start = TextPosition(row: marked.row, column: marked.range.lowerBound)
            end = TextPosition(row: marked.row, column: marked.range.upperBound)
        } else {
            start = TextEditing.clamp(position, in: center.lines)
            end = start
        }
        let safeRow = min(max(0, start.row), max(0, center.lines.count - 1))
        var rowLines = [center.lines[safeRow]]
        let localFrom = TextPosition(row: 0, column: start.column)
        let localTo = TextPosition(row: 0, column: end.column)
        _ = TextEditing.replace(&rowLines, from: localFrom, to: localTo, with: flat)
        applyLineRangeEdit(LineRangeEdit(range: safeRow..<(safeRow + 1), oldLines: [center.lines[safeRow]], newLines: rowLines))
        let length = (flat as NSString).length
        marked = length > 0 ? (safeRow, start.column..<(start.column + length)) : nil
        validStarts = min(validStarts, safeRow + 1)
    }

    func removeMarked() -> (text: String, at: TextPosition)? {
        guard let marked, marked.row < center.lines.count else {
            self.marked = nil
            return nil
        }
        let start = TextPosition(row: marked.row, column: marked.range.lowerBound)
        let end = TextPosition(row: marked.row, column: marked.range.upperBound)
        let text = TextEditing.text(center.lines, from: start, to: end)
        let rowLine = center.lines[marked.row]
        var rowLines = [rowLine]
        _ = TextEditing.replace(
            &rowLines,
            from: TextPosition(row: 0, column: start.column),
            to: TextPosition(row: 0, column: end.column),
            with: ""
        )
        applyLineRangeEdit(LineRangeEdit(range: marked.row..<(marked.row + 1), oldLines: [rowLine], newLines: rowLines))
        self.marked = nil
        validStarts = min(validStarts, marked.row + 1)
        return (text, start)
    }

    // MARK: Undo / Redo

    @discardableResult
    func undo() -> EditorSession.Selection? {
        guard marked == nil, let group = undoStack.popLast() else { return nil }
        closeGroup()
        for edit in group.edits.reversed() {
            let reverseRange = edit.range.lowerBound..<(edit.range.lowerBound + edit.newLines.count)
            applyLineRangeEdit(LineRangeEdit(range: reverseRange, oldLines: edit.newLines, newLines: edit.oldLines))
        }
        chunks = group.chunksBefore
        rebuildSegments()
        redoStack.append(group)
        version += 1
        return clampSelection(group.selectionBefore)
    }

    @discardableResult
    func redo() -> EditorSession.Selection? {
        guard marked == nil, let group = redoStack.popLast() else { return nil }
        closeGroup()
        for edit in group.edits {
            applyLineRangeEdit(edit)
        }
        chunks = group.chunksAfter
        rebuildSegments()
        undoStack.append(group)
        version += 1
        return clampSelection(group.selectionAfter)
    }

    // MARK: Offsets for NSTextInputClient

    func offset(of position: TextPosition) -> Int {
        guard !center.lines.isEmpty else { return 0 }
        let p = TextEditing.clamp(position, in: center.lines)
        return lineStart(p.row) + p.column
    }

    func position(ofOffset offset: Int) -> TextPosition {
        let lines = center.lines
        guard !lines.isEmpty else { return TextPosition(row: 0, column: 0) }
        let target = max(0, offset)
        while validStarts < lines.count, lineStart(validStarts - 1) <= target { _ = lineStart(validStarts) }
        var lo = 0
        var hi = validStarts - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return TextPosition(row: lo, column: min(target - lineStarts[lo], lines[lo].utf16.count))
    }

    var totalLength: Int {
        guard !center.lines.isEmpty else { return 0 }
        let last = center.lines.count - 1
        return lineStart(last) + center.lines[last].utf16.count
    }

    private func lineStart(_ row: Int) -> Int {
        let lines = center.lines
        let row = min(max(0, row), lines.count - 1)
        while validStarts <= row {
            let previous = validStarts - 1
            let start = lineStarts[previous] + lines[previous].utf16.count + 1
            if validStarts < lineStarts.count { lineStarts[validStarts] = start } else { lineStarts.append(start) }
            validStarts += 1
        }
        return lineStarts[row]
    }

    // MARK: Synchronized 3-pane layout & scroll mapping

    func rebuildSegments() {
        let leftCount = left.lines.count
        let centerCount = center.lines.count
        let rightCount = right.lines.count

        var segs: [MergeSegment] = []
        var v = 0
        var lPos = 0
        var cPos = 0
        var rPos = 0

        for (index, chunk) in chunks.enumerated() {
            let lStart = min(max(chunk.leftRange.lowerBound, lPos), leftCount)
            let cStart = min(max(chunk.centerRange.lowerBound, cPos), centerCount)
            let rStart = min(max(chunk.rightRange.lowerBound, rPos), rightCount)

            let lEnd = min(max(lStart, chunk.leftRange.upperBound), leftCount)
            let cEnd = min(max(cStart, chunk.centerRange.upperBound), centerCount)
            let rEnd = min(max(rStart, chunk.rightRange.upperBound), rightCount)

            let gapL = lStart - lPos
            let gapC = cStart - cPos
            let gapR = rStart - rPos
            if gapL > 0 || gapC > 0 || gapR > 0 {
                let seg = MergeSegment(
                    virtualStart: v,
                    leftStart: lPos, leftCount: gapL,
                    centerStart: cPos, centerCount: gapC,
                    rightStart: rPos, rightCount: gapR,
                    chunk: -1
                )
                segs.append(seg)
                v += seg.span
            }

            let seg = MergeSegment(
                virtualStart: v,
                leftStart: lStart, leftCount: lEnd - lStart,
                centerStart: cStart, centerCount: cEnd - cStart,
                rightStart: rStart, rightCount: rEnd - rStart,
                chunk: index
            )
            segs.append(seg)
            v += seg.span

            lPos = lEnd
            cPos = cEnd
            rPos = rEnd
        }

        let tailL = leftCount - lPos
        let tailC = centerCount - cPos
        let tailR = rightCount - rPos
        if tailL > 0 || tailC > 0 || tailR > 0 {
            let seg = MergeSegment(
                virtualStart: v,
                leftStart: lPos, leftCount: tailL,
                centerStart: cPos, centerCount: tailC,
                rightStart: rPos, rightCount: tailR,
                chunk: -1
            )
            segs.append(seg)
            v += seg.span
        }

        segments = segs
        virtualLineCount = v
    }

    private func segmentIndex(forVirtual v: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(segments[mid].virtualStart) <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func panePositions(forVirtual v: Double) -> (left: Double, center: Double, right: Double) {
        guard let idx = segmentIndex(forVirtual: v) else { return (0, 0, 0) }
        let s = segments[idx]
        let span = Double(s.span)
        let t = span > 0 ? min(1, max(0, (v - Double(s.virtualStart)) / span)) : 0
        return (
            Double(s.leftStart) + t * Double(s.leftCount),
            Double(s.centerStart) + t * Double(s.centerCount),
            Double(s.rightStart) + t * Double(s.rightCount)
        )
    }

    func virtualPosition(of line: Int, pane: MergePane) -> Double {
        guard !segments.isEmpty else { return 0 }
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start: Int
            switch pane {
            case .left: start = segments[mid].leftStart
            case .center: start = segments[mid].centerStart
            case .right: start = segments[mid].rightStart
            }
            if start <= line { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        let start: Int
        let count: Int
        switch pane {
        case .left: start = s.leftStart; count = s.leftCount
        case .center: start = s.centerStart; count = s.centerCount
        case .right: start = s.rightStart; count = s.rightCount
        }
        guard count > 0 else { return Double(s.virtualStart) }
        let t = min(1, max(0, Double(line - start) / Double(count)))
        return Double(s.virtualStart) + t * Double(s.span)
    }

    func virtualStart(ofChunk index: Int) -> Int {
        segments.first(where: { $0.chunk == index })?.virtualStart ?? 0
    }

    func virtualSpan(ofChunk index: Int) -> Int {
        segments.first(where: { $0.chunk == index })?.span ?? 0
    }

    // MARK: Internal helpers

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func clampedCenterRange(_ range: Range<Int>) -> Range<Int> {
        let lo = min(max(0, range.lowerBound), center.lines.count)
        let hi = min(max(lo, range.upperBound), center.lines.count)
        return lo..<hi
    }

    private func clampSelection(_ selection: EditorSession.Selection) -> EditorSession.Selection {
        guard !center.lines.isEmpty else {
            return (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0))
        }
        return (TextEditing.clamp(selection.anchor, in: center.lines), TextEditing.clamp(selection.head, in: center.lines))
    }

    private func applyLineRangeEdit(_ edit: LineRangeEdit) {
        center.replaceLines(in: edit.range, with: edit.newLines, language: language)
        validStarts = min(validStarts, edit.range.lowerBound + 1)
    }

    private func adjustChunks(for change: LineEdit) {
        guard change.removed > 0 || change.inserted > 0 else { return }
        let s = change.start
        let e = change.start + change.removed
        let delta = change.delta
        let lineCount = center.lines.count

        func mapBound(_ x: Int, isUpper: Bool) -> Int {
            if x < s { return x }
            if x > e { return x + delta }
            if change.removed == 0 { return x + delta }
            return isUpper ? (s + change.inserted) : s
        }

        var prevUpper = 0
        for idx in chunks.indices {
            let cs = chunks[idx].centerRange.lowerBound
            let ce = chunks[idx].centerRange.upperBound
            let touched = (change.removed > 0 && cs < e && ce > s)
                || (change.removed == 0 && cs < s && ce > s)
                || (cs == ce && cs == s && change.removed > 0)
            let rawLower = mapBound(cs, isUpper: false)
            let rawUpper = mapBound(ce, isUpper: true)
            let clampedLower = min(max(prevUpper, rawLower), lineCount)
            let clampedUpper = min(max(clampedLower, rawUpper), lineCount)
            chunks[idx].centerRange = clampedLower..<clampedUpper
            if touched {
                chunks[idx].manuallyEdited = true
            }
            prevUpper = clampedUpper
        }
    }

    private func recordDirectEdit(
        _ edit: LineRangeEdit,
        chunksBefore: [MergeChunk],
        chunksAfter: [MergeChunk],
        kind: EditorSession.Kind,
        before: EditorSession.Selection,
        after: EditorSession.Selection
    ) {
        let now = Self.now
        if groupOpen, kind != .other, var last = undoStack.last, last.kind == kind, now - last.time < 4,
           last.edits.count == 1, let prev = last.edits.first, canCoalesce(prev, edit) {
            // Merge adjacent single-line typing/deleting steps into one undo group.
            let combined = mergeLineEdits(prev, edit)
            last.edits = [combined]
            last.chunksAfter = chunksAfter
            last.selectionAfter = after
            last.time = now
            undoStack[undoStack.count - 1] = last
            redoStack.removeAll()
        } else {
            pushUndo(MergeUndoGroup(
                edits: [edit],
                chunksBefore: chunksBefore,
                chunksAfter: chunksAfter,
                selectionBefore: before,
                selectionAfter: after,
                kind: kind,
                time: now
            ))
        }
        groupOpen = kind != .other
    }

    private func canCoalesce(_ prev: LineRangeEdit, _ next: LineRangeEdit) -> Bool {
        let prevResultRange = prev.range.lowerBound..<(prev.range.lowerBound + prev.newLines.count)
        return prevResultRange.count == 1 && next.range == prevResultRange
            && prev.newLines.count == 1 && next.newLines.count == 1
    }

    private func mergeLineEdits(_ prev: LineRangeEdit, _ next: LineRangeEdit) -> LineRangeEdit {
        LineRangeEdit(range: prev.range, oldLines: prev.oldLines, newLines: next.newLines)
    }

    private func pushUndo(_ group: MergeUndoGroup) {
        undoStack.append(group)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        version += 1
    }
}

/// What a conflicted path represents when opened in the 3-way merge viewer.
enum ConflictFileKind {
    case text(ThreeWayMergeDocument)
    case binary(leftSize: Int?, baseSize: Int?, rightSize: Int?)
    case image(left: Data?, right: Data?)
    /// Deleted in HEAD (Left, stage 2 absent), modified in Incoming (Right, stage 3 present).
    case deletedByLeft(rightPreview: String?, rightSize: Int)
    /// Modified in HEAD (Left, stage 2 present), deleted in Incoming (Right, stage 3 absent).
    case deletedByRight(leftPreview: String?, leftSize: Int)
    /// Deleted on both sides (neither stage 2 nor stage 3 present).
    case bothDeleted
    case message(title: String, detail: String)
}

/// Reads Git index stages `:1:` (Base), `:2:` (Left/HEAD), `:3:` (Right/Incoming) and constructs `ConflictFileKind`.
enum ThreeWayMergeLoader {
    /// Resolves human-readable pane titles based on the active Git operation.
    static func titles(
        operation: RepoOperation?,
        branch: String?,
        gitDirectory: URL?,
        in root: URL
    ) async -> ThreeWayMergeTitles {
        let effectiveOp = operation ?? gitDirectory.flatMap(detectOperation(in:))
        let centerTitle = L("Result", "合并结果")
        let branchSuffix = branch.map { " (\($0))" } ?? ""
        var leftTitle = "HEAD\(branchSuffix)"
        var rightTitle = L("Incoming", "传入")

        switch effectiveOp {
        case .merge:
            leftTitle = branch.map { L("Local (\($0))", "本地 (\($0))") } ?? "HEAD"
            if let gitDir = gitDirectory,
               let msg = Git.preparedMessage(in: gitDir),
               let firstLine = msg.split(separator: "\n").first {
                let raw = String(firstLine)
                if let range = raw.range(of: "Merge branch '"),
                   let end = raw[range.upperBound...].firstIndex(of: "'") {
                    rightTitle = String(raw[range.upperBound..<end])
                } else if let range = raw.range(of: "Merge remote-tracking branch '"),
                          let end = raw[range.upperBound...].firstIndex(of: "'") {
                    rightTitle = String(raw[range.upperBound..<end])
                } else if let headOID = try? String(contentsOf: gitDir.appendingPathComponent("MERGE_HEAD"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), headOID.count >= 7 {
                    rightTitle = String(headOID.prefix(7))
                }
            }
        case .rebase:
            if let gitDir = gitDirectory {
                let headName = readTrimmed(gitDir.appendingPathComponent("rebase-merge/head-name"))
                    ?? readTrimmed(gitDir.appendingPathComponent("rebase-apply/head-name"))
                let onto = readTrimmed(gitDir.appendingPathComponent("rebase-merge/onto"))
                let stopped = readTrimmed(gitDir.appendingPathComponent("rebase-merge/stopped-sha"))
                let targetName = onto.map { String($0.prefix(7)) } ?? "HEAD"
                let rebasedName = headName.map { $0.replacingOccurrences(of: "refs/heads/", with: "") } ?? L("Rebased", "变基提交")
                leftTitle = L("Onto (\(targetName))", "目标 (\(targetName))")
                rightTitle = stopped.map { "\(rebasedName) (\(String($0.prefix(7))))" } ?? rebasedName
            }
        case .cherryPick:
            leftTitle = branch.map { L("Local (\($0))", "本地 (\($0))") } ?? "HEAD"
            if let gitDir = gitDirectory,
               let oid = readTrimmed(gitDir.appendingPathComponent("CHERRY_PICK_HEAD")), oid.count >= 7 {
                rightTitle = "Cherry-Pick \(oid.prefix(7))"
            } else {
                rightTitle = "Cherry-Pick"
            }
        case .revert:
            leftTitle = branch.map { L("Local (\($0))", "本地 (\($0))") } ?? "HEAD"
            if let gitDir = gitDirectory,
               let oid = readTrimmed(gitDir.appendingPathComponent("REVERT_HEAD")), oid.count >= 7 {
                rightTitle = "Revert \(oid.prefix(7))"
            } else {
                rightTitle = "Revert"
            }
        case nil:
            leftTitle = branch.map { L("Local (\($0))", "本地 (\($0))") } ?? "HEAD"
            rightTitle = L("Incoming (Stash / Patch)", "传入 (Stash / 补丁)")
        }
        return ThreeWayMergeTitles(left: leftTitle, center: centerTitle, right: rightTitle)
    }

    private static func detectOperation(in gitDir: URL) -> RepoOperation? {
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path) { return .merge }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-merge").path)
            || fm.fileExists(atPath: gitDir.appendingPathComponent("rebase-apply").path) { return .rebase }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("CHERRY_PICK_HEAD").path) { return .cherryPick }
        if fm.fileExists(atPath: gitDir.appendingPathComponent("REVERT_HEAD").path) { return .revert }
        return nil
    }

    private static func readTrimmed(_ url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func load(
        path: String,
        in root: URL,
        operation: RepoOperation?,
        branch: String?,
        gitDirectory: URL?,
        ignoreWhitespace: Bool = false
    ) async -> ConflictFileKind {
        async let stage1 = Git.blob(rev: ":1", path: path, in: root)
        async let stage2 = Git.blob(rev: ":2", path: path, in: root)
        async let stage3 = Git.blob(rev: ":3", path: path, in: root)
        async let resolvedTitles = titles(operation: operation, branch: branch, gitDirectory: gitDirectory, in: root)

        let baseData = await stage1
        let leftData = await stage2
        let rightData = await stage3
        let titles = await resolvedTitles

        let worktreeURL = root.appendingPathComponent(path)
        let worktreeData = try? Data(contentsOf: worktreeURL)

        let ext = (path as NSString).pathExtension.lowercased()
        if DiffLoader.imageExtensions.contains(ext) {
            return .image(left: leftData, right: rightData)
        }

        // Handle delete/modify or both-deleted conflicts when stages exist or file was removed.
        if leftData == nil && rightData == nil && baseData != nil {
            return .bothDeleted
        }
        if leftData == nil && rightData != nil && baseData != nil {
            let preview = rightData.flatMap { TextCodec.looksBinary($0) ? nil : String(TextCodec.decode($0).prefix(2000)) }
            return .deletedByLeft(rightPreview: preview, rightSize: rightData?.count ?? 0)
        }
        if leftData != nil && rightData == nil && baseData != nil {
            let preview = leftData.flatMap { TextCodec.looksBinary($0) ? nil : String(TextCodec.decode($0).prefix(2000)) }
            return .deletedByRight(leftPreview: preview, leftSize: leftData?.count ?? 0)
        }

        if [baseData, leftData, rightData].compactMap({ $0 }).contains(where: TextCodec.looksBinary) {
            return .binary(leftSize: leftData?.count, baseSize: baseData?.count, rightSize: rightData?.count)
        }

        let maxBytes = max(baseData?.count ?? 0, max(leftData?.count ?? 0, rightData?.count ?? 0))
        if maxBytes > DiffLoader.maxTextBytes {
            return .message(title: L("File too large to merge", "文件过大，无法打开三方合并"), detail: maxBytes.byteSizeString)
        }

        let language = LanguageSpec.detect(path: path)

        let baseLines: [String]
        let leftLines: [String]
        let rightLines: [String]

        if leftData == nil && rightData == nil && baseData == nil {
            // Fallback: reconstruct Left/Base/Right from worktree conflict markers if stages are absent.
            guard let worktreeData else {
                return .message(title: L("Conflict details unavailable", "无法读取冲突内容"), detail: path)
            }
            if TextCodec.looksBinary(worktreeData) {
                return .binary(leftSize: nil, baseSize: nil, rightSize: worktreeData.count)
            }
            let reconstructed = reconstructFromMarkers(TextCodec.splitLines(TextCodec.decode(worktreeData)))
            leftLines = reconstructed.left
            baseLines = reconstructed.base
            rightLines = reconstructed.right
        } else {
            baseLines = baseData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
            leftLines = leftData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
            rightLines = rightData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
        }

        let formatSource = leftData ?? baseData ?? rightData ?? worktreeData
        let format = formatSource.flatMap { TextCodec.decodeForEditing($0)?.format }
            ?? TextFormat(encoding: .utf8, bom: false, newline: "\n", finalNewline: true)

        // Compute Base -> Left and Base -> Right hunks using git's histogram diff when byte blobs are available,
        // falling back to internal Myers diff for AA / reconstructed / non-UTF8 cases.
        let leftHunks: [Hunk]
        let rightHunks: [Hunk]
        if let baseBlob = baseData ?? (baseLines.isEmpty ? Data() : nil),
           let leftBlob = leftData, let rightBlob = rightData {
            async let lh = DiffLoader.computeHunks(old: baseBlob, new: leftBlob, ignoreWhitespace: ignoreWhitespace)
            async let rh = DiffLoader.computeHunks(old: baseBlob, new: rightBlob, ignoreWhitespace: ignoreWhitespace)
            leftHunks = await lh ?? ThreeWayMergeEngine.computeLineHunks(old: baseLines, new: leftLines)
            rightHunks = await rh ?? ThreeWayMergeEngine.computeLineHunks(old: baseLines, new: rightLines)
        } else {
            leftHunks = ThreeWayMergeEngine.computeLineHunks(old: baseLines, new: leftLines)
            rightHunks = ThreeWayMergeEngine.computeLineHunks(old: baseLines, new: rightLines)
        }

        let chunks = ThreeWayMergeEngine.buildChunks(
            base: baseLines,
            left: leftLines,
            right: rightLines,
            leftHunks: leftHunks,
            rightHunks: rightHunks
        )

        let shouldHighlight = max(baseLines.count, max(leftLines.count, rightLines.count)) <= 60_000
        let leftBuffer = TextBuffer(lines: leftLines)
        let rightBuffer = TextBuffer(lines: rightLines)
        let centerBuffer = TextBuffer(lines: baseLines)

        if shouldHighlight {
            leftBuffer.spans = Highlighter.highlight(leftLines, language: language)
            rightBuffer.spans = Highlighter.highlight(rightLines, language: language)
            let tracked = Highlighter.highlightTracking(baseLines, language: language)
            centerBuffer.spans = tracked.spans
            centerBuffer.states = tracked.states
        }

        let doc = ThreeWayMergeDocument(
            left: leftBuffer,
            base: baseLines,
            center: centerBuffer,
            right: rightBuffer,
            chunks: chunks,
            language: language,
            format: format,
            titles: titles
        )
        return .text(doc)
    }

    private static func reconstructFromMarkers(_ lines: [String]) -> (left: [String], base: [String], right: [String]) {
        let blocks = ConflictBlock.find(in: lines)
        guard !blocks.isEmpty else { return (lines, lines, lines) }
        var left: [String] = []
        var base: [String] = []
        var right: [String] = []
        var cursor = 0
        for block in blocks {
            if block.start > cursor {
                let common = lines[cursor..<block.start]
                left.append(contentsOf: common)
                base.append(contentsOf: common)
                right.append(contentsOf: common)
            }
            left.append(contentsOf: lines[block.ours])
            if let baseMarker = block.base {
                base.append(contentsOf: lines[(baseMarker + 1)..<block.middle])
            }
            right.append(contentsOf: lines[block.theirs])
            cursor = block.end + 1
        }
        if cursor < lines.count {
            let tail = lines[cursor..<lines.count]
            left.append(contentsOf: tail)
            base.append(contentsOf: tail)
            right.append(contentsOf: tail)
        }
        return (left, base, right)
    }
}
