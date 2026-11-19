import XCTest
@testable import DifKit

final class LineDiffBarTests: XCTestCase {
    // MARK: - LineDiffExtractor

    func testExtractModifiedPairedLineReusesHunkInlineRanges() throws {
        let left = TextBuffer(lines: [
            "let count = 1",
            "let message = \"hello world\"",
            "return count",
        ])
        let right = TextBuffer(lines: [
            "let count = 1",
            "let message = \"hello swift\"",
            "return count",
        ])
        left.spans = [[], [SyntaxSpan(start: 0, length: 3, kind: .keyword)], []]
        right.spans = [[], [SyntaxSpan(start: 0, length: 3, kind: .keyword)], []]

        var hunks = [Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1)]
        DiffLoader.addInlineHighlights(&hunks, left: left.lines, right: right.lines)
        let doc = DiffDocument(left: left, right: right, hunks: hunks, language: .swift)

        let snapFromRight = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 1))
        XCTAssertEqual(snapFromRight.hunkKind, .modified)
        XCTAssertEqual(snapFromRight.left.kind, .modified)
        XCTAssertEqual(snapFromRight.right.kind, .modified)
        XCTAssertEqual(snapFromRight.left.lineNumber, 2)
        XCTAssertEqual(snapFromRight.right.lineNumber, 2)
        XCTAssertEqual(snapFromRight.left.text, "let message = \"hello world\"")
        XCTAssertEqual(snapFromRight.right.text, "let message = \"hello swift\"")
        XCTAssertEqual(snapFromRight.left.syntaxSpans, [SyntaxSpan(start: 0, length: 3, kind: .keyword)])
        XCTAssertEqual(snapFromRight.right.syntaxSpans, [SyntaxSpan(start: 0, length: 3, kind: .keyword)])
        XCTAssertEqual(snapFromRight.left.highlightRanges, doc.hunks[0].leftInline[0])
        XCTAssertEqual(snapFromRight.right.highlightRanges, doc.hunks[0].rightInline[0])
        XCTAssertFalse(snapFromRight.left.highlightRanges.isEmpty)
        XCTAssertFalse(snapFromRight.right.highlightRanges.isEmpty)

        let snapFromLeft = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .left, line: 1))
        XCTAssertEqual(snapFromLeft, snapFromRight)
    }

    func testExtractModifiedFallbackComputesInlineRangesWhenHunkInlineEmpty() throws {
        let left = TextBuffer(lines: ["let value = fooBar"])
        let right = TextBuffer(lines: ["let value = fooBaz"])
        // Hunk without precomputed leftInline/rightInline (e.g. >200 line hunk).
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .swift
        )

        let snap = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 0))
        XCTAssertEqual(snap.left.highlightRanges, [12..<18])
        XCTAssertEqual(snap.right.highlightRanges, [12..<18])

        // Single-token line where InlineDiff.compute returns nil falls back to character-level prefix/suffix diff.
        let singleTokenDoc = DiffDocument(
            left: TextBuffer(lines: ["fooBar"]),
            right: TextBuffer(lines: ["fooBaz"]),
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .plain
        )
        let charSnap = try XCTUnwrap(LineDiffExtractor.extract(from: singleTokenDoc, side: .left, line: 0))
        XCTAssertEqual(charSnap.left.highlightRanges, [5..<6])
        XCTAssertEqual(charSnap.right.highlightRanges, [5..<6])
    }

    func testExtractAsymmetricModifiedHunkMarksExtraLinePartnerEmpty() throws {
        let left = TextBuffer(lines: ["a1", "a2"])
        let right = TextBuffer(lines: ["b1", "b2", "b3"])
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: [Hunk(leftStart: 0, leftCount: 2, rightStart: 0, rightCount: 3)],
            language: .plain
        )

        let extraRight = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 2))
        XCTAssertEqual(extraRight.hunkKind, .modified)
        XCTAssertEqual(extraRight.left, .empty)
        XCTAssertNil(extraRight.left.lineNumber)
        XCTAssertEqual(extraRight.right.kind, .added)
        XCTAssertEqual(extraRight.right.lineNumber, 3)
        XCTAssertEqual(extraRight.right.text, "b3")

        let leftSide = TextBuffer(lines: ["a1", "a2", "a3"])
        let rightSide = TextBuffer(lines: ["b1"])
        let doc2 = DiffDocument(
            left: leftSide,
            right: rightSide,
            hunks: [Hunk(leftStart: 0, leftCount: 3, rightStart: 0, rightCount: 1)],
            language: .plain
        )
        let extraLeft = try XCTUnwrap(LineDiffExtractor.extract(from: doc2, side: .left, line: 2))
        XCTAssertEqual(extraLeft.hunkKind, .modified)
        XCTAssertEqual(extraLeft.left.kind, .removed)
        XCTAssertEqual(extraLeft.left.lineNumber, 3)
        XCTAssertEqual(extraLeft.left.text, "a3")
        XCTAssertEqual(extraLeft.right, .empty)
    }

    func testExtractAddedOnlyAndDeletedOnlyHunks() throws {
        let left = TextBuffer(lines: ["keep0", "del1", "keep1"])
        let right = TextBuffer(lines: ["keep0", "add1", "add2", "keep1"])
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: [
                Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 0),
                Hunk(leftStart: 2, leftCount: 0, rightStart: 1, rightCount: 2),
            ],
            language: .plain
        )

        let deletedSnap = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .left, line: 1))
        XCTAssertEqual(deletedSnap.hunkKind, .deleted)
        XCTAssertEqual(deletedSnap.left.kind, .removed)
        XCTAssertEqual(deletedSnap.left.lineNumber, 2)
        XCTAssertEqual(deletedSnap.left.text, "del1")
        XCTAssertEqual(deletedSnap.right, .empty)

        let addedSnap = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 2))
        XCTAssertEqual(addedSnap.hunkKind, .added)
        XCTAssertEqual(addedSnap.left, .empty)
        XCTAssertEqual(addedSnap.right.kind, .added)
        XCTAssertEqual(addedSnap.right.lineNumber, 3)
        XCTAssertEqual(addedSnap.right.text, "add2")
    }

    func testExtractContextLinesBeforeAndAfterHunksWithNonZeroOffsetShift() throws {
        // Left: L0..L9 (10 lines), Right: R0..R12 (13 lines)
        // Hunk 0: left 2..<4 (2 lines) -> right 2..<5 (3 lines), delta = +1
        // Hunk 1: left 7..<7 (0 lines) -> right 8..<10 (2 lines), delta = +2
        // Total delta after both hunks = +3
        let left = TextBuffer(lines: (0..<10).map { "same_\($0)" })
        let right = TextBuffer(lines: [
            "same_0", "same_1",
            "mod_a", "mod_b", "mod_c",
            "same_4", "same_5", "same_6",
            "ins_a", "ins_b",
            "same_7", "same_8", "same_9",
        ])
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: [
                Hunk(leftStart: 2, leftCount: 2, rightStart: 2, rightCount: 3),
                Hunk(leftStart: 7, leftCount: 0, rightStart: 8, rightCount: 2),
            ],
            language: .plain
        )

        // Before all hunks: L1 <-> R1
        let beforeSnap = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .left, line: 1))
        XCTAssertNil(beforeSnap.hunkKind)
        XCTAssertEqual(beforeSnap.left.kind, .unchanged)
        XCTAssertEqual(beforeSnap.right.kind, .unchanged)
        XCTAssertEqual(beforeSnap.left.lineNumber, 2)
        XCTAssertEqual(beforeSnap.right.lineNumber, 2)
        XCTAssertEqual(beforeSnap.left.text, "same_1")
        XCTAssertEqual(beforeSnap.right.text, "same_1")

        // Between Hunk 0 and Hunk 1 (delta = +1): L6 <-> R7
        let middleSnapFromLeft = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .left, line: 6))
        XCTAssertEqual(middleSnapFromLeft.left.lineNumber, 7)
        XCTAssertEqual(middleSnapFromLeft.right.lineNumber, 8)
        XCTAssertEqual(middleSnapFromLeft.left.text, "same_6")
        XCTAssertEqual(middleSnapFromLeft.right.text, "same_6")

        let middleSnapFromRight = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 7))
        XCTAssertEqual(middleSnapFromRight, middleSnapFromLeft)

        // After both hunks (delta = +3, with Hunk 1 having leftCount == 0 at leftStart == 7): L7 <-> R10
        let afterSnapFromLeft = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .left, line: 7))
        XCTAssertEqual(afterSnapFromLeft.left.lineNumber, 8)
        XCTAssertEqual(afterSnapFromLeft.right.lineNumber, 11)
        XCTAssertEqual(afterSnapFromLeft.left.text, "same_7")
        XCTAssertEqual(afterSnapFromLeft.right.text, "same_7")

        let afterSnapFromRight = try XCTUnwrap(LineDiffExtractor.extract(from: doc, side: .right, line: 10))
        XCTAssertEqual(afterSnapFromRight, afterSnapFromLeft)
    }

    func testExtractPlainFileAndOutOfBoundsReturnNil() {
        let buf = TextBuffer(lines: ["hello", "world"])
        let plainDoc = DiffDocument(left: .empty, right: buf, hunks: [], language: .swift, isPlainFile: true)
        XCTAssertNil(LineDiffExtractor.extract(from: plainDoc, side: .right, line: 0))
        XCTAssertNil(LineDiffExtractor.defaultSnapshot(for: plainDoc))

        let diffDoc = DiffDocument(left: buf, right: buf, hunks: [], language: .swift)
        XCTAssertNil(LineDiffExtractor.extract(from: diffDoc, side: .right, line: -1))
        XCTAssertNil(LineDiffExtractor.extract(from: diffDoc, side: .right, line: 2))
        XCTAssertNil(LineDiffExtractor.defaultSnapshot(for: diffDoc))

        let msgDoc = DiffDocument.message("Binary file")
        XCTAssertNil(LineDiffExtractor.extract(from: msgDoc, side: .right, line: 0))
    }

    func testDefaultSnapshotSelectsFocusedOrFirstHunk() throws {
        let left = TextBuffer(lines: ["a", "old1", "c", "old2"])
        let right = TextBuffer(lines: ["a", "new1", "c", "new2"])
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: [
                Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1),
                Hunk(leftStart: 3, leftCount: 1, rightStart: 3, rightCount: 1),
            ],
            language: .plain
        )

        let first = try XCTUnwrap(LineDiffExtractor.defaultSnapshot(for: doc))
        XCTAssertEqual(first.right.lineNumber, 2)
        XCTAssertEqual(first.right.text, "new1")

        let second = try XCTUnwrap(LineDiffExtractor.defaultSnapshot(for: doc, focusedHunk: 1))
        XCTAssertEqual(second.right.lineNumber, 4)
        XCTAssertEqual(second.right.text, "new2")
    }

    // MARK: - LineDiffFormatter.expandTabs

    func testExpandTabsRemapsSyntaxSpansAndHighlightsWithMultiByteUTF16() {
        // "\tlet 🚀\tval = 中文"
        // Original UTF-16 offsets:
        // 0: '\t' -> expands to 4 spaces (0..<4), visualCol becomes 4
        // 1..<4: "let" -> 4..<7, visualCol becomes 7
        // 4: ' ' -> 7..<8, visualCol becomes 8
        // 5..<7: "🚀" (surrogate pair: 2 UTF-16 units, 1 visual col) -> 8..<10, visualCol becomes 9
        // 7: '\t' at visualCol 9 -> 3 spaces (4 - 9%4 = 3) -> 10..<13, visualCol becomes 12
        // 8..<11: "val" -> 13..<16
        // 11..<14: " = " -> 16..<19
        // 14..<16: "中文" -> 19..<21
        let raw = "\tlet 🚀\tval = 中文"
        let spans = [
            SyntaxSpan(start: 1, length: 3, kind: .keyword),   // "let"
            SyntaxSpan(start: 8, length: 3, kind: .variable),  // "val"
            SyntaxSpan(start: 14, length: 2, kind: .string),   // "中文"
        ]
        let highlights = [
            1..<4,   // "let"
            8..<11,  // "val"
            14..<16, // "中文"
        ]

        let expanded = LineDiffFormatter.expandTabs(raw, syntaxSpans: spans, highlightRanges: highlights)
        XCTAssertEqual(expanded.text, "    let 🚀   val = 中文")
        XCTAssertEqual(expanded.syntaxSpans, [
            SyntaxSpan(start: 4, length: 3, kind: .keyword),
            SyntaxSpan(start: 13, length: 3, kind: .variable),
            SyntaxSpan(start: 19, length: 2, kind: .string),
        ])
        XCTAssertEqual(expanded.highlightRanges, [4..<7, 13..<16, 19..<21])

        let nsExpanded = expanded.text as NSString
        XCTAssertEqual(nsExpanded.substring(with: NSRange(location: 4, length: 3)), "let")
        XCTAssertEqual(nsExpanded.substring(with: NSRange(location: 13, length: 3)), "val")
        XCTAssertEqual(nsExpanded.substring(with: NSRange(location: 19, length: 2)), "中文")
    }

    func testExpandTabsWithoutTabsClampsInvalidRangesSafely() {
        let raw = "abc"
        let expanded = LineDiffFormatter.expandTabs(
            raw,
            syntaxSpans: [SyntaxSpan(start: 1, length: 10, kind: .keyword)],
            highlightRanges: [0..<2, 2..<99]
        )
        XCTAssertEqual(expanded.text, "abc")
        XCTAssertEqual(expanded.syntaxSpans, [SyntaxSpan(start: 1, length: 2, kind: .keyword)])
        XCTAssertEqual(expanded.highlightRanges, [0..<2, 2..<3])
    }

    // MARK: - Settings & Commands

    @MainActor
    func testShowLineDiffBarDefaultsAndPersistence() throws {
        let suiteName = "LineDiffBarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertTrue(initial.showLineDiffBar, "showLineDiffBar should default to true")

        initial.showLineDiffBar = false
        initial.save()

        let reloadedFalse = Settings(defaults: defaults)
        XCTAssertFalse(reloadedFalse.showLineDiffBar)

        reloadedFalse.showLineDiffBar = true
        reloadedFalse.save()

        let reloadedTrue = Settings(defaults: defaults)
        XCTAssertTrue(reloadedTrue.showLineDiffBar)
    }

    @MainActor
    func testLineDiffBarCommandIsRegisteredInViewGroup() throws {
        let command = try XCTUnwrap(AppStore.shared.commands.first { $0.id == "view.lineDiffBar" })
        XCTAssertEqual(command.group, .view)
        XCTAssertEqual(command.symbol, "rectangle.split.1x2")
    }

    @MainActor
    func testViewerModelLineDiffSnapshotLifecycleAndCanvasSync() throws {
        let suiteName = "LineDiffBarTests.Viewer.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        let viewer = ViewerModel()
        viewer.settings = settings
        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        viewer.attach(container)

        let left = TextBuffer(lines: ["same0", "old1", "same2", "deleted3", "same4"])
        let right = TextBuffer(lines: ["same0", "new1", "same2", "same4"])
        var hunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1),
            Hunk(leftStart: 3, leftCount: 1, rightStart: 3, rightCount: 0),
        ]
        DiffLoader.addInlineHighlights(&hunks, left: left.lines, right: right.lines)
        let diffDoc = DiffDocument(left: left, right: right, hunks: hunks, language: .swift)

        viewer.document = diffDoc
        container.show(diffDoc, mode: .sideBySide, preserveScroll: false)
        viewer.refreshLineDiff()

        let initial = try XCTUnwrap(viewer.lineDiffSnapshot)
        XCTAssertEqual(initial.hunkKind, .modified)
        XCTAssertEqual(initial.left.lineNumber, 2)
        XCTAssertEqual(initial.right.lineNumber, 2)
        XCTAssertEqual(initial.left.text, "old1")
        XCTAssertEqual(initial.right.text, "new1")

        // Selecting a deleted line on the left pane updates the snapshot via onActiveLineChange.
        container.canvas.selection = TextSelection(
            pane: .left,
            anchor: TextPosition(row: 3, column: 0),
            head: TextPosition(row: 3, column: 0)
        )
        let deletedSnap = try XCTUnwrap(viewer.lineDiffSnapshot)
        XCTAssertEqual(deletedSnap.hunkKind, .deleted)
        XCTAssertEqual(deletedSnap.left.lineNumber, 4)
        XCTAssertEqual(deletedSnap.left.text, "deleted3")
        XCTAssertEqual(deletedSnap.right, .empty)

        // Caret move on the right pane updates the snapshot to the unchanged context line.
        container.canvas.placeCaret(line: 0)
        let unchangedSnap = try XCTUnwrap(viewer.lineDiffSnapshot)
        XCTAssertNil(unchangedSnap.hunkKind)
        XCTAssertEqual(unchangedSnap.left.lineNumber, 1)
        XCTAssertEqual(unchangedSnap.right.lineNumber, 1)
        XCTAssertEqual(unchangedSnap.right.text, "same0")

        // Focusing a deleted hunk updates the snapshot to that deleted line.
        container.canvas.focusedHunk = 1
        let focusedDeleted = try XCTUnwrap(viewer.lineDiffSnapshot)
        XCTAssertEqual(focusedDeleted.hunkKind, .deleted)
        XCTAssertEqual(focusedDeleted.left.text, "deleted3")

        // Unified mode maps removed rows via source(pane: .right, row:) to `.left`.
        container.setMode(.unified)
        let removedRow = try XCTUnwrap(diffDoc.unifiedRows.firstIndex { $0.kind == .removed && Int($0.left) == 3 })
        container.canvas.selection = TextSelection(
            pane: .right,
            anchor: TextPosition(row: removedRow, column: 0),
            head: TextPosition(row: removedRow, column: 0)
        )
        let unifiedSnap = try XCTUnwrap(viewer.lineDiffSnapshot)
        XCTAssertEqual(unifiedSnap.hunkKind, .deleted)
        XCTAssertEqual(unifiedSnap.left.text, "deleted3")

        // When hidden, active line is still tracked so re-enabling refreshes to the latest line.
        settings.showLineDiffBar = false
        container.canvas.placeCaret(line: 2)
        XCTAssertEqual(viewer.lineDiffSnapshot?.left.text, "deleted3")
        settings.showLineDiffBar = true
        viewer.refreshLineDiff()
        XCTAssertEqual(viewer.lineDiffSnapshot?.right.text, "same2")

        // Plain files and added-only files clear lineDiffSnapshot to nil.
        let plainDoc = DiffDocument(left: .empty, right: right, hunks: [], language: .swift, isPlainFile: true)
        viewer.document = plainDoc
        container.show(plainDoc, mode: .single, preserveScroll: false)
        viewer.refreshLineDiff()
        XCTAssertNil(viewer.lineDiffSnapshot)

        let addedDoc = DiffDocument(
            left: .empty,
            right: TextBuffer(lines: ["newFileLine"]),
            hunks: [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 1)],
            language: .swift
        )
        XCTAssertTrue(addedDoc.isAddedOnly)
        viewer.document = addedDoc
        container.show(addedDoc, mode: .sideBySide, preserveScroll: false)
        viewer.refreshLineDiff()
        XCTAssertNil(viewer.lineDiffSnapshot)
    }
}
