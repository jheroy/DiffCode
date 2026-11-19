import XCTest
@testable import DifKit

extension InlineDiffTests {
    private func utf16Substring(_ string: String, range: Range<Int>) -> String {
        (string as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    func testNilGuardInsertionBeforeMemberChainShiftsToTokenBoundary() throws {
        let old = "if table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"
        let new = "if table == nil || table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"

        let result = try XCTUnwrap(InlineDiff.compute(old: [old][...], new: [new][...]))
        XCTAssertEqual(result.old, [[]])
        XCTAssertEqual(result.new.count, 1)
        XCTAssertEqual(result.new[0].count, 1)
        let range = result.new[0][0]
        XCTAssertEqual(range, 3..<18)
        XCTAssertEqual(utf16Substring(new, range: range), "table == nil ||")
    }

    func testNilGuardDeletionBeforeMemberChainShiftsToTokenBoundary() throws {
        let old = "if table == nil || table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"
        let new = "if table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"

        let result = try XCTUnwrap(InlineDiff.compute(old: [old][...], new: [new][...]))
        XCTAssertEqual(result.new, [[]])
        XCTAssertEqual(result.old.count, 1)
        XCTAssertEqual(result.old[0].count, 1)
        let range = result.old[0][0]
        XCTAssertEqual(range, 3..<18)
        XCTAssertEqual(utf16Substring(old, range: range), "table == nil ||")
    }

    func testShortGuardInsertionAndDeletionShiftCleanly() throws {
        let old = "if table.Foo() {"
        let new = "if table == nil || table.Foo() {"

        let inserted = try XCTUnwrap(InlineDiff.compute(old: [old][...], new: [new][...]))
        XCTAssertEqual(inserted.old, [[]])
        XCTAssertEqual(inserted.new, [[3..<18]])
        XCTAssertEqual(utf16Substring(new, range: inserted.new[0][0]), "table == nil ||")

        let deleted = try XCTUnwrap(InlineDiff.compute(old: [new][...], new: [old][...]))
        XCTAssertEqual(deleted.old, [[3..<18]])
        XCTAssertEqual(deleted.new, [[]])
    }

    func testRepeatedArgumentInsertionStaysOnTokenAndCommaBoundaries() throws {
        let insertDistinct = try XCTUnwrap(InlineDiff.compute(old: ["foo(a, b)"][...], new: ["foo(x, a, b)"][...]))
        XCTAssertEqual(insertDistinct.old, [[]])
        XCTAssertEqual(insertDistinct.new, [[4..<6]])
        XCTAssertEqual(utf16Substring("foo(x, a, b)", range: insertDistinct.new[0][0]), "x,")

        let insertDuplicate = try XCTUnwrap(InlineDiff.compute(old: ["foo(a, b)"][...], new: ["foo(a, a, b)"][...]))
        XCTAssertEqual(insertDuplicate.old, [[]])
        XCTAssertEqual(insertDuplicate.new, [[7..<9]])
        XCTAssertEqual(utf16Substring("foo(a, a, b)", range: insertDuplicate.new[0][0]), "a,")

        let compactDuplicate = try XCTUnwrap(InlineDiff.compute(old: ["foo(a,b)"][...], new: ["foo(a,a,b)"][...]))
        XCTAssertEqual(compactDuplicate.old, [[]])
        XCTAssertEqual(compactDuplicate.new, [[6..<8]])
        XCTAssertEqual(utf16Substring("foo(a,a,b)", range: compactDuplicate.new[0][0]), "a,")
    }

    func testPrefixAndOperatorExpressionsShiftCleanlyWithoutSplittingOperators() throws {
        let wrapped = try XCTUnwrap(InlineDiff.compute(old: ["return err"][...], new: ["return wrap(err)"][...]))
        XCTAssertEqual(wrapped.old, [[]])
        XCTAssertEqual(wrapped.new, [[7..<12, 15..<16]])

        let repeatedSum = try XCTUnwrap(InlineDiff.compute(old: ["a + b"][...], new: ["a + a + b"][...]))
        XCTAssertEqual(repeatedSum.old, [[]])
        XCTAssertEqual(repeatedSum.new, [[0..<3]])
        XCTAssertEqual(utf16Substring("a + a + b", range: repeatedSum.new[0][0]), "a +")

        let repeatedOr = try XCTUnwrap(InlineDiff.compute(old: ["a || b"][...], new: ["a || a || b"][...]))
        XCTAssertEqual(repeatedOr.old, [[]])
        XCTAssertEqual(repeatedOr.new, [[0..<4]])
        XCTAssertEqual(utf16Substring("a || a || b", range: repeatedOr.new[0][0]), "a ||")
    }

    func testRepeatedMemberAndSubscriptChainsKeepDotAndBracketsIntact() throws {
        let insertedCall = try XCTUnwrap(InlineDiff.compute(old: ["x.A()"][...], new: ["x.B().A()"][...]))
        XCTAssertEqual(insertedCall.old, [[]])
        XCTAssertEqual(insertedCall.new, [[1..<5]])
        XCTAssertEqual(utf16Substring("x.B().A()", range: insertedCall.new[0][0]), ".B()")

        let deletedCall = try XCTUnwrap(InlineDiff.compute(old: ["x.B().A()"][...], new: ["x.A()"][...]))
        XCTAssertEqual(deletedCall.old, [[1..<5]])
        XCTAssertEqual(deletedCall.new, [[]])

        let insertedSubscript = try XCTUnwrap(InlineDiff.compute(old: ["a[i]"][...], new: ["a[j][i]"][...]))
        XCTAssertEqual(insertedSubscript.old, [[]])
        XCTAssertEqual(insertedSubscript.new, [[1..<4]])
        XCTAssertEqual(utf16Substring("a[j][i]", range: insertedSubscript.new[0][0]), "[j]")
    }

    func testMultilineInsertedLineDoesNotLeakTrailingDelimiterOntoNeighborLine() throws {
        let old = ["foo(a,", "    b)"]
        let new = ["foo(a,", "    x,", "    b)"]

        let result = try XCTUnwrap(InlineDiff.compute(old: old[...], new: new[...]))
        XCTAssertEqual(result.old, [[], []])
        XCTAssertEqual(result.new, [[], [], []])
    }

    func testLineDiffBarMatchesHunkInlineHighlightsAndShiftsCharFallback() throws {
        let oldLine = "if table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"
        let newLine = "if table == nil || table.EventArmsRaceSever() == nil || !table.EventArmsRaceSever().HasRow(int(sid)) {"

        var hunks = [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)]
        DiffLoader.addInlineHighlights(&hunks, left: [oldLine], right: [newLine])
        let precomputedDoc = DiffDocument(
            left: TextBuffer(lines: [oldLine]),
            right: TextBuffer(lines: [newLine]),
            hunks: hunks,
            language: .go
        )
        let fallbackDoc = DiffDocument(
            left: TextBuffer(lines: [oldLine]),
            right: TextBuffer(lines: [newLine]),
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .go
        )

        let precomputedSnap = try XCTUnwrap(LineDiffExtractor.extract(from: precomputedDoc, side: .right, line: 0))
        let fallbackSnap = try XCTUnwrap(LineDiffExtractor.extract(from: fallbackDoc, side: .right, line: 0))
        XCTAssertEqual(precomputedSnap.left.highlightRanges, [])
        XCTAssertEqual(precomputedSnap.right.highlightRanges, [3..<18])
        XCTAssertEqual(fallbackSnap.left.highlightRanges, precomputedSnap.left.highlightRanges)
        XCTAssertEqual(fallbackSnap.right.highlightRanges, precomputedSnap.right.highlightRanges)

        // Single-token fallback also shifts cleanly to underscore / surrogate-safe boundaries.
        let singleTokenDoc = DiffDocument(
            left: TextBuffer(lines: ["table_row"]),
            right: TextBuffer(lines: ["table_nil_table_row"]),
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .go
        )
        let singleSnap = try XCTUnwrap(LineDiffExtractor.extract(from: singleTokenDoc, side: .right, line: 0))
        XCTAssertEqual(singleSnap.left.highlightRanges, [])
        XCTAssertEqual(singleSnap.right.highlightRanges, [0..<10])
        XCTAssertEqual(utf16Substring("table_nil_table_row", range: singleSnap.right.highlightRanges[0]), "table_nil_")

        let emojiDoc = DiffDocument(
            left: TextBuffer(lines: ["🚀_a"]),
            right: TextBuffer(lines: ["🚀_🚀_a"]),
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .plain
        )
        let emojiSnap = try XCTUnwrap(LineDiffExtractor.extract(from: emojiDoc, side: .right, line: 0))
        XCTAssertEqual(emojiSnap.left.highlightRanges, [])
        XCTAssertEqual(emojiSnap.right.highlightRanges, [0..<3])
        XCTAssertEqual(utf16Substring("🚀_🚀_a", range: emojiSnap.right.highlightRanges[0]), "🚀_")
    }
}
