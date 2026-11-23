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
        XCTAssertEqual(result.new, [[], [4..<6], []])
    }

    func testGofmtAlignmentAndAppendedFieldsSplitHunkAndHighlightSpaces() async throws {
        let oldText = """
        // MSG_GS_L_JOIN_INIT_LEAGUE
        type S_JOIN_INIT_LEAGUE_L struct {
        \tRid        int64
        \tLeagueAreaId int32
        \tCountry    int8
        \tServerId   uint32
        \tPower      int64
        \tLocale     string
        \tRoleHeader datastruct.StRoleHeader
        \tSimpleInfo datastruct.StRoleSimpleInfo
        }
        """
        let newText = """
        // MSG_GS_L_JOIN_INIT_LEAGUE
        type S_JOIN_INIT_LEAGUE_L struct {
        \tRid            int64
        \tLeagueAreaId   int32
        \tCountry        int8
        \tServerId       uint32
        \tPower          int64
        \tLocale         string
        \tRoleHeader     datastruct.StRoleHeader
        \tSimpleInfo     datastruct.StRoleSimpleInfo
        \tSameAreaLids   []int64 // 同区域普通联盟
        \tSameCountryLids []int64 // 同阵营、非同区域的普通联盟
        \tInitLids       []int64 // 本区域新手联盟
        }
        """
        let oldData = Data((oldText + "\n").utf8)
        let newData = Data((newText + "\n").utf8)
        let oldLines = TextCodec.splitLines(oldText)
        let newLines = TextCodec.splitLines(newText)

        var hunks = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: false))
        XCTAssertEqual(hunks.map(\.kind), [.modified, .added])
        XCTAssertEqual(hunks[0].leftStart, 2)
        XCTAssertEqual(hunks[0].leftCount, 8)
        XCTAssertEqual(hunks[0].rightStart, 2)
        XCTAssertEqual(hunks[0].rightCount, 8)
        XCTAssertEqual(hunks[1].leftStart, 10)
        XCTAssertEqual(hunks[1].leftCount, 0)
        XCTAssertEqual(hunks[1].rightStart, 10)
        XCTAssertEqual(hunks[1].rightCount, 3)

        DiffLoader.addInlineHighlights(&hunks, left: oldLines, right: newLines)
        XCTAssertEqual(hunks[0].leftInline, Array(repeating: [], count: 8))
        for row in 0..<8 {
            XCTAssertFalse(hunks[0].rightInline[row].isEmpty, "row \(row) should highlight added alignment spaces")
        }
        XCTAssertEqual(utf16Substring(newLines[2], range: hunks[0].rightInline[0][0]), "    ")
        XCTAssertEqual(utf16Substring(newLines[3], range: hunks[0].rightInline[1][0]), "  ")

        let filtered = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: true))
        XCTAssertEqual(filtered.map(\.kind), [.added])
        XCTAssertEqual(filtered[0].rightStart, 10)
        XCTAssertEqual(filtered[0].rightCount, 3)
    }

    func testWhitespaceOnlyEditsAndMixedHunkLineHighlights() throws {
        // Added alignment spaces, removed alignment spaces, tab-to-spaces, trailing spaces, blank-line spaces.
        let added = try XCTUnwrap(InlineDiff.compute(old: ["\tRid        int64"][...], new: ["\tRid            int64"][...]))
        XCTAssertEqual(added.old, [[]])
        XCTAssertEqual(added.new, [[12..<16]])

        let removed = try XCTUnwrap(InlineDiff.compute(old: ["\tLeague   datastruct.StLeague"][...], new: ["\tLeague datastruct.StLeague"][...]))
        XCTAssertEqual(removed.old, [[8..<10]])
        XCTAssertEqual(removed.new, [[]])

        let tabToSpaces = try XCTUnwrap(InlineDiff.compute(old: ["\tfoo"][...], new: ["    foo"][...]))
        XCTAssertEqual(tabToSpaces.old, [[0..<1]])
        XCTAssertEqual(tabToSpaces.new, [[0..<4]])

        let trailing = try XCTUnwrap(InlineDiff.compute(old: ["foo"][...], new: ["foo   "][...]))
        XCTAssertEqual(trailing.old, [[]])
        XCTAssertEqual(trailing.new, [[3..<6]])

        let blankLine = try XCTUnwrap(InlineDiff.compute(old: [""][...], new: ["    "][...]))
        XCTAssertEqual(blankLine.old, [[]])
        XCTAssertEqual(blankLine.new, [[0..<4]])

        // Mixed un-splittable hunk: real edit + wholly added line preserves full visible-text highlight on added line.
        let mixed = try XCTUnwrap(InlineDiff.compute(
            old: ["let a = 1"][...],
            new: ["let a = 2", "    let b = 3"][...]
        ))
        XCTAssertEqual(mixed.old, [[8..<9]])
        XCTAssertEqual(mixed.new, [[8..<9], [4..<13]])
    }

    func testStructuralRealignmentAlignsMatchingTypeHeader() async throws {
        let oldText = """
        // MSG_GS_L_EVOLVE_LEAGUE
        type S_EVOLVE_LEAGUE_L struct {
        \tSid uint32
        }

        // MSG_L_GS_EVOLVE_LEAGUE_NOTIFY
        type S_EVOLVE_LEAGUE_NOTIFY_L struct {
        \tElection [][]datastruct.LeagueElectionResult
        \tLeagues  map[int64]datastruct.StLeague
        }

        // MSG_GS_C_EVOLVE_LEAGUE_NOTIFY
        type S_EVOLVE_LEAGUE_NOTIFY struct {
        \tElection []datastruct.LeagueElectionResult
        \tLeague   datastruct.StLeague
        }

        // MSG_C_GS_GET_LEAGUE_ELECT
        type S_GET_LEAGUE_ELECT struct {
        }

        // MSG_GS_C_GET_LEAGUE_ELECT_RESULT
        type S_GET_LEAGUE_ELECT_RESULT struct {
        \tResult ResultCode
        \tInfos  []datastruct.StLeagueElectElem
        }

        // MSG_GS_L_GET_LEAGUE_ELECT
        type S_GET_LEAGUE_ELECT_L struct {
        \tLid int64
        }
        """
        let newText = """
        // MSG_GS_L_EVOLVE_LEAGUE
        type S_EVOLVE_LEAGUE_L struct {
        \tSid uint32
        \tLid int64
        }

        // MSG_L_GS_EVOLVE_LEAGUE_NOTIFY
        type S_EVOLVE_LEAGUE_NOTIFY_L struct {
        \tEvolved  bool // 本次是否实际转正
        \tElection []datastruct.LeagueElectionResult
        \tLeague   datastruct.StLeague
        }

        // MSG_GS_C_EVOLVE_LEAGUE_NOTIFY
        type S_EVOLVE_LEAGUE_NOTIFY struct {
        \tLeague datastruct.StLeague
        }
        """
        let oldData = Data((oldText + "\n").utf8)
        let newData = Data((newText + "\n").utf8)
        let oldLines = TextCodec.splitLines(oldText)
        let newLines = TextCodec.splitLines(newText)

        var exactHunks = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: false))
        DiffLoader.addInlineHighlights(&exactHunks, left: oldLines, right: newLines)
        let exactDoc = DiffDocument(left: TextBuffer(lines: oldLines), right: TextBuffer(lines: newLines), hunks: exactHunks, language: .go)
        // Left line 12 (`type S_EVOLVE_LEAGUE_NOTIFY struct {`) must sit inside an unchanged segment paired 1:1 with right line 14.
        let headerSeg = exactDoc.segments.first {
            $0.hunk < 0 && ($0.leftStart..<($0.leftStart + $0.leftCount)).contains(12)
        }
        XCTAssertNotNil(headerSeg)
        if let seg = headerSeg {
            XCTAssertEqual(seg.rightStart + (12 - seg.leftStart), 14)
        }
        // Closing brace of S_EVOLVE_LEAGUE_NOTIFY (left 15 <-> right 16) is also aligned unchanged.
        let braceSeg = exactDoc.segments.first {
            $0.hunk < 0 && ($0.leftStart..<($0.leftStart + $0.leftCount)).contains(15)
        }
        XCTAssertNotNil(braceSeg)
        if let seg = braceSeg {
            XCTAssertEqual(seg.rightStart + (15 - seg.leftStart), 16)
        }
        // Inside S_EVOLVE_LEAGUE_NOTIFY, deleted Election and whitespace-modified League split into .deleted + .modified.
        let leagueModified = exactHunks.first { $0.kind == .modified && $0.leftStart == 14 && $0.rightStart == 15 }
        XCTAssertNotNil(leagueModified)
        XCTAssertEqual(leagueModified?.leftInline, [[8..<10]])
        XCTAssertEqual(leagueModified?.rightInline, [[]])
        // Trailing S_GET_LEAGUE_ELECT* blocks are pure deletions.
        XCTAssertTrue(exactHunks.contains { $0.kind == .deleted && $0.leftStart == 16 && $0.leftCount == 15 })

        let wsHunks = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: true))
        let wsDoc = DiffDocument(left: TextBuffer(lines: oldLines), right: TextBuffer(lines: newLines), hunks: wsHunks, language: .go)
        let wsHeaderSeg = wsDoc.segments.first {
            $0.hunk < 0 && ($0.leftStart..<($0.leftStart + $0.leftCount)).contains(12)
        }
        XCTAssertNotNil(wsHeaderSeg)
        // With ignoreWhitespace=true, League line (left 14 <-> right 15) is unchanged too.
        let wsLeagueSeg = wsDoc.segments.first {
            $0.hunk < 0 && ($0.leftStart..<($0.leftStart + $0.leftCount)).contains(14)
        }
        XCTAssertNotNil(wsLeagueSeg)
        XCTAssertEqual(wsLeagueSeg?.rightStart, 15)
    }

    func testStructuralRealignmentPreservesEqualWeightFunctionSwap() {
        let oldLines = [
            "func alpha() {",
            "    alphaLine1()",
            "    alphaLine2()",
            "}",
            "func beta() {",
            "    betaLine1()",
            "    betaLine2()",
            "}",
        ]
        let newLines = [
            "func beta() {",
            "    betaLine1()",
            "    betaLine2()",
            "}",
            "func alpha() {",
            "    alphaLine1()",
            "    alphaLine2()",
            "}",
        ]
        let rawHunks = [
            Hunk(leftStart: 0, leftCount: 4, rightStart: 0, rightCount: 0),
            Hunk(leftStart: 8, leftCount: 0, rightStart: 4, rightCount: 4),
        ]
        let refined = DiffRefiner.realignStructuralHunks(rawHunks, oldLines: oldLines, newLines: newLines, ignoreWhitespace: false)
        XCTAssertEqual(refined, rawHunks)
    }

    func testPartialContentAndRevertStayValidOnRefinedHunks() async throws {
        let oldText = """
        type S struct {
        \tA int64
        \tB int64
        }
        """
        let newText = """
        type S struct {
        \tA  int64
        \tB  int64
        \tCC int64
        }
        """
        let oldData = Data((oldText + "\n").utf8)
        let newData = Data((newText + "\n").utf8)
        let hunks = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: false))
        XCTAssertEqual(hunks.map(\.kind), [.modified, .added])

        let revertedAdded = try XCTUnwrap(HunkPatch.revert(hunks[1], old: oldData, new: newData))
        let postRevertHunks = try XCTUnwrap(await DiffLoader.computeHunks(old: oldData, new: revertedAdded, ignoreWhitespace: false))
        XCTAssertEqual(postRevertHunks.map(\.kind), [.modified])

        let excludedLine = ChangeLine(removed: false, line: 3, text: "\tCC int64")
        let partial = try XCTUnwrap(WorkingTree.partialContent(old: oldData, new: newData, hunks: hunks, excluded: [excludedLine]))
        XCTAssertEqual(partial, revertedAdded)
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
