import Foundation
import XCTest
@testable import DifKit

final class SemanticDiffTests: XCTestCase {
    // MARK: - 1. Comment Filtering (ignoreComments)

    func testCommentOnlyHunksFilteredIncludingMultilineBlockAndInlineComments() {
        let leftLines = [
            "import Foundation",
            "// Old header comment",
            "/*",
            " * Old block doc line 1",
            " * Old block doc line 2",
            " */",
            "func compute(value: Int) -> Int {",
            "    let result = value + 1 // old trailing comment",
            "    let url = \"https://old.example.com\"",
            "    return /* old inline */ result",
            "}",
        ]
        let rightLines = [
            "import Foundation",
            "// Updated header comment",
            "/// Replaced with single doc line",
            "func compute(value: Int) -> Int {",
            "    let result = value + 1 // new trailing comment",
            "    let url = \"https://new.example.com\"",
            "    return result",
            "}",
        ]

        let leftSpans = Highlighter.highlight(leftLines, language: .swift)
        let rightSpans = Highlighter.highlight(rightLines, language: .swift)

        // Hunk 0: lines 1..<6 (comment + multiline block comment) -> lines 1..<3 (comment)
        // Hunk 1: line 7 (inline trailing comment) -> line 4
        // Hunk 2: line 8 (URL string literal containing //) -> line 5 (MUST NOT be filtered!)
        // Hunk 3: line 9 (inline /* ... */ comment) -> line 6
        let rawHunks = [
            Hunk(leftStart: 1, leftCount: 5, rightStart: 1, rightCount: 2),
            Hunk(leftStart: 7, leftCount: 1, rightStart: 4, rightCount: 1),
            Hunk(leftStart: 8, leftCount: 1, rightStart: 5, rightCount: 1),
            Hunk(leftStart: 9, leftCount: 1, rightStart: 6, rightCount: 1),
        ]

        let filtered = SemanticDiff.filterCommentOnlyHunks(
            rawHunks,
            leftLines: leftLines,
            rightLines: rightLines,
            leftSpans: leftSpans,
            rightSpans: rightSpans
        )

        XCTAssertEqual(filtered.hidden.count, 3)
        XCTAssertEqual(filtered.kept.count, 1)
        XCTAssertEqual(filtered.kept[0].leftStart, 8)
        XCTAssertEqual(filtered.kept[0].rightStart, 5)
    }

    func testIgnoreCommentsPreservesCodeChangesBlankLinesAndUnicodeOffsets() {
        let leftLines = [
            "let 标题 = \"你好\" // 旧注释",
            "let count = 1 // old",
            "let keep = true",
        ]
        let rightLines = [
            "let 标题 = \"你好\" // 新注释",
            "let count = 2 // new",
            "",
            "let keep = true",
        ]
        let leftSpans = Highlighter.highlight(leftLines, language: .swift)
        let rightSpans = Highlighter.highlight(rightLines, language: .swift)

        let hunks = [
            Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1), // CJK + trailing comment only -> hidden
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1), // Code changed + comment -> kept
            Hunk(leftStart: 2, leftCount: 0, rightStart: 2, rightCount: 1), // Pure blank line (no comment) -> kept
        ]

        let filtered = SemanticDiff.filterCommentOnlyHunks(
            hunks,
            leftLines: leftLines,
            rightLines: rightLines,
            leftSpans: leftSpans,
            rightSpans: rightSpans
        )
        XCTAssertEqual(filtered.hidden.count, 1)
        XCTAssertEqual(filtered.hidden[0].leftStart, 0)
        XCTAssertEqual(filtered.kept.count, 2)
        XCTAssertEqual(filtered.kept.map(\.leftStart), [1, 2])
    }

    func testDocumentPreservesBuffersAndAlignmentWhenCommentHunksHidden() {
        let leftLines = [
            "let a = 1",
            "// deleted comment line 1",
            "// deleted comment line 2",
            "let b = 2",
            "let c = 3",
        ]
        let rightLines = [
            "let a = 1",
            "let b = 2",
            "let c = 99",
        ]
        let left = TextBuffer(lines: leftLines)
        left.spans = Highlighter.highlight(leftLines, language: .swift)
        let right = TextBuffer(lines: rightLines)
        right.spans = Highlighter.highlight(rightLines, language: .swift)

        let rawHunks = [
            Hunk(leftStart: 1, leftCount: 2, rightStart: 1, rightCount: 0), // pure deleted comments
            Hunk(leftStart: 4, leftCount: 1, rightStart: 2, rightCount: 1), // code change
        ]
        var options = SemanticDiffOptions.disabled
        options.ignoreComments = true

        let processed = DiffLoader.applySemanticPostProcessing(
            hunks: rawHunks,
            left: left,
            right: right,
            language: .swift,
            options: options
        )
        let doc = DiffDocument(
            left: left,
            right: right,
            hunks: processed.hunks,
            language: .swift,
            hiddenCommentHunks: processed.hiddenCommentHunks
        )

        // Original buffers must remain untouched for safe editor save semantics.
        XCTAssertEqual(doc.left.lines, leftLines)
        XCTAssertEqual(doc.right.lines, rightLines)
        XCTAssertEqual(doc.hiddenCommentHunkCount, 1)
        XCTAssertEqual(doc.hunks.count, 1)
        XCTAssertEqual(doc.hunks[0].leftStart, 4)
        XCTAssertEqual(doc.hunks[0].rightStart, 2)

        // Surrounding identical line `let b = 2` (left 3, right 1) stays aligned 1:1 in unifiedRows.
        XCTAssertTrue(doc.unifiedRows.contains(where: { $0.kind == .context && $0.left == 3 && $0.right == 1 }))
        // Deleted comment lines are emitted as left-only context rows rather than dropped.
        XCTAssertTrue(doc.unifiedRows.contains(where: { $0.kind == .context && $0.left == 1 && $0.right == -1 }))
        XCTAssertTrue(doc.unifiedRows.contains(where: { $0.kind == .context && $0.left == 2 && $0.right == -1 }))
    }

    // MARK: - 2. JSON Semantic Normalization (normalizeJSON)

    func testNormalizeJSONSortsKeysAndCanonicalizesFormatting() throws {
        let leftJSON = #"{"z": 1, "a": {"y": "https://example.com/a/b", "x": [3, 2, 1]}}"#
        let rightJSON = """
        {
          "a": {
            "x": [3, 2, 1],
            "y": "https://example.com/a/b"
          },
          "z": 1
        }
        """

        let result = SemanticDiff.normalizeJSONPair(old: Data(leftJSON.utf8), new: Data(rightJSON.utf8))
        XCTAssertTrue(result.normalized)
        XCTAssertEqual(result.old, result.new)

        let normalizedText = try XCTUnwrap(result.old.map { String(decoding: $0, as: UTF8.self) })
        // Unescaped slashes preserved.
        XCTAssertTrue(normalizedText.contains("https://example.com/a/b"))
        XCTAssertFalse(normalizedText.contains(#"https:\/\/example.com"#))
        // Keys sorted alphabetically: `"a"` appears before `"z"`.
        let aIdx = try XCTUnwrap(normalizedText.range(of: "\"a\"")?.lowerBound)
        let zIdx = try XCTUnwrap(normalizedText.range(of: "\"z\"")?.lowerBound)
        XCTAssertLessThan(aIdx, zIdx)
    }

    func testNormalizeJSONFallsBackSilentlyOnInvalidOrFragmentJSON() {
        let valid = Data(#"{"b": 1, "a": 2}"#.utf8)
        let invalid = Data(#"{"b": 1, "a": }"#.utf8)

        let failedRight = SemanticDiff.normalizeJSONPair(old: valid, new: invalid)
        XCTAssertFalse(failedRight.normalized)
        XCTAssertEqual(failedRight.old, valid)
        XCTAssertEqual(failedRight.new, invalid)

        let failedLeft = SemanticDiff.normalizeJSONPair(old: invalid, new: valid)
        XCTAssertFalse(failedLeft.normalized)
        XCTAssertEqual(failedLeft.old, invalid)
        XCTAssertEqual(failedLeft.new, valid)

        // Scalar top-level JSON fragments must not throw an ObjC exception from JSONSerialization.data.
        let fragment = Data(#""just a string""#.utf8)
        let fragResult = SemanticDiff.normalizeJSONPair(old: fragment, new: fragment)
        XCTAssertFalse(fragResult.normalized)
        XCTAssertEqual(fragResult.old, fragment)
    }

    func testDiffLoaderNormalizesJSONAndMarksWorktreeReadOnly() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let fileURL = repo.appendingPathComponent("config.json")
        try #"{"b":1,"a":{"d":true,"c":"ok"}}"#.write(to: fileURL, atomically: true, encoding: .utf8)
        try await gitCommitAll(in: repo, message: "initial")

        // Semantically identical JSON with reordered keys and pretty formatting.
        try """
        {
          "a": {
            "c": "ok",
            "d": true
          },
          "b": 1
        }
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        var semantic = SemanticDiffOptions.default
        semantic.normalizeJSON = true
        let req = DiffRequest(root: repo, path: "config.json", oldPath: nil, kind: .modified,
                              source: .worktree(base: "HEAD"), semantic: semantic)
        let doc = await DiffLoader.load(req)

        XCTAssertTrue(doc.isJSONNormalized)
        XCTAssertTrue(doc.hunks.isEmpty)
        XCTAssertNotNil(doc.editing?.readOnlyReason)
        XCTAssertNotNil(doc.note)

        // Corrupt JSON must fall back cleanly to raw diff with `isJSONNormalized == false`.
        try "{ broken json".write(to: fileURL, atomically: true, encoding: .utf8)
        let fallbackDoc = await DiffLoader.load(req)
        XCTAssertFalse(fallbackDoc.isJSONNormalized)
        XCTAssertFalse(fallbackDoc.hunks.isEmpty)
        XCTAssertNil(fallbackDoc.editing?.readOnlyReason)
    }

    // MARK: - 3. Intra-File Code Move Detection (detectMoves)

    func testDetectMovesExactMoveIncludingReindentation() throws {
        let leftLines = [
            "struct Service {",
            "    func helperAlpha(x: Int) -> Int {",
            "        let doubled = x * 2",
            "        let offset = doubled + 10",
            "        return offset",
            "    }",
            "",
            "    func keepMe() {",
            "        print(\"stay\")",
            "    }",
            "}",
        ]
        let rightLines = [
            "struct Service {",
            "    func keepMe() {",
            "        print(\"stay\")",
            "    }",
            "",
            "        func helperAlpha(x: Int) -> Int {",
            "            let doubled = x * 2",
            "            let offset = doubled + 10",
            "            return offset",
            "        }",
            "}",
        ]

        var hunks = [
            Hunk(leftStart: 1, leftCount: 5, rightStart: 1, rightCount: 0), // deleted helperAlpha
            Hunk(leftStart: 10, leftCount: 0, rightStart: 5, rightCount: 5), // added helperAlpha (re-indented)
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .swift)

        let srcInfo = try XCTUnwrap(hunks[0].moveInfo)
        let dstInfo = try XCTUnwrap(hunks[1].moveInfo)

        XCTAssertEqual(srcInfo.pairID, dstInfo.pairID)
        XCTAssertEqual(srcInfo.role, .source)
        XCTAssertEqual(dstInfo.role, .target)
        XCTAssertEqual(srcInfo.counterpartHunkIndex, 1)
        XCTAssertEqual(dstInfo.counterpartHunkIndex, 0)
        XCTAssertEqual(srcInfo.similarity, 1.0, accuracy: 0.0001)
        XCTAssertNil(srcInfo.inlineDiff)
        XCTAssertNil(dstInfo.inlineDiff)
    }

    func testDetectMovesModifiedBlockComputesInlineDiff() throws {
        let leftLines = [
            "func computeScore(items: [Int]) -> Int {",
            "    var total = 0",
            "    for item in items {",
            "        total += item",
            "    }",
            "    return total",
            "}",
            "let anchor = 1",
        ]
        let rightLines = [
            "let anchor = 1",
            "func computeScore(items: [Int]) -> Int {",
            "    var total = 0",
            "    for item in items {",
            "        total += item * 2",
            "    }",
            "    return total",
            "}",
        ]

        var hunks = [
            Hunk(leftStart: 0, leftCount: 7, rightStart: 0, rightCount: 0),
            Hunk(leftStart: 8, leftCount: 0, rightStart: 1, rightCount: 7),
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .swift)

        let srcInfo = try XCTUnwrap(hunks[0].moveInfo)
        let dstInfo = try XCTUnwrap(hunks[1].moveInfo)

        XCTAssertEqual(srcInfo.pairID, dstInfo.pairID)
        XCTAssertEqual(srcInfo.role, .source)
        XCTAssertEqual(dstInfo.role, .target)
        XCTAssertGreaterThanOrEqual(srcInfo.similarity, SemanticDiff.defaultMoveSimilarityThreshold)
        XCTAssertLessThan(srcInfo.similarity, 1.0)

        let inline = try XCTUnwrap(srcInfo.inlineDiff)
        XCTAssertEqual(inline, dstInfo.inlineDiff)
        // Line index 3 inside the moved block changed from `total += item` to `total += item * 2`.
        XCTAssertEqual(inline.target.count, 7)
        XCTAssertFalse(inline.target[3].isEmpty)
    }

    func testDetectMovesIgnoresShortOrUnrelatedBlocksAndPrioritizesMatchingSymbol() throws {
        let leftLines = [
            "let shortA = 1",
            "let shortB = 2",
            "func alphaTask() {",
            "    let stepOne = prepareInput(1)",
            "    let stepTwo = transformValue(stepOne)",
            "    emitOutput(stepTwo)",
            "}",
        ]
        let rightLines = [
            "let shortA = 1",
            "let shortB = 2",
            "func betaTask() {",
            "    let stepOne = prepareInput(1)",
            "    let stepTwo = transformValue(stepOne)",
            "    emitOutput(stepTwo)",
            "}",
            "func alphaTask() {",
            "    let stepOne = prepareInput(2)",
            "    let stepTwo = transformValue(stepOne)",
            "    emitOutput(stepTwo)",
            "}",
        ]

        var hunks = [
            Hunk(leftStart: 0, leftCount: 2, rightStart: 0, rightCount: 0), // too short (2 lines)
            Hunk(leftStart: 2, leftCount: 5, rightStart: 2, rightCount: 0), // alphaTask source
            Hunk(leftStart: 7, leftCount: 0, rightStart: 0, rightCount: 2), // too short (2 lines)
            Hunk(leftStart: 7, leftCount: 0, rightStart: 2, rightCount: 5), // betaTask (1 token diff)
            Hunk(leftStart: 7, leftCount: 0, rightStart: 7, rightCount: 5), // alphaTask (same symbol name + 1 token diff)
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .swift)

        XCTAssertNil(hunks[0].moveInfo)
        XCTAssertNil(hunks[2].moveInfo)
        XCTAssertNil(hunks[3].moveInfo)

        let alphaSource = try XCTUnwrap(hunks[1].moveInfo)
        let alphaTarget = try XCTUnwrap(hunks[4].moveInfo)
        XCTAssertEqual(alphaSource.counterpartHunkIndex, 4)
        XCTAssertEqual(alphaTarget.counterpartHunkIndex, 1)
    }

    func testDetectMovesSplitsMergedGoAddedHunkForTwoDispersedSingleLineMoves() throws {
        // Exact reproduction of real Go refactoring: two dispersed calls inside a lock
        // moved outside the lock and merged into one 2-line + blank-line `.added` hunk.
        let leftLines = [
            "func handleLeave(player *Player, tableMgr *TableMgr, recvData *LeaveReq, fromRid int64) {",
            "    if recvData == nil {",
            "        return",
            "    }",
            "    lock.Lock()",
            "    defer lock.Unlock()",
            "    currentRole := player.GetRole()",
            "    player.HandleEventEmpireShadowLeaveLeague(tableMgr, currentRole, recvData.Lid, getEmpireShadowGroup())",
            "    recordLeaveMetric(recvData.Lid)",
            "    notifyRoom(recvData.Lid)",
            "    player.SyncLeague(recvData.Info, tableMgr, false)",
            "",
            "    finishLeave()",
            "}",
        ]
        let rightLines = [
            "func handleLeave(player *Player, tableMgr *TableMgr, recvData *LeaveReq, fromRid int64) {",
            "    if recvData == nil {",
            "        return",
            "    }",
            "    player.HandleEventEmpireShadowLeaveLeagueByRid(tableMgr, recvData.Lid, fromRid, getEmpireShadowGroup())",
            "    player.SyncLeague(recvData.Info, tableMgr, false)",
            "",
            "    lock.Lock()",
            "    defer lock.Unlock()",
            "    currentRole := player.GetRole()",
            "    recordLeaveMetric(recvData.Lid)",
            "    notifyRoom(recvData.Lid)",
            "    finishLeave()",
            "}",
        ]

        // Raw hunks before move detection:
        // 0: merged .added (right lines 4..6: HandleEvent...ByRid, SyncLeague, "")
        // 1: dispersed .deleted 1 (left line 7: HandleEvent...)
        // 2: dispersed .deleted 2 (left lines 10..11: SyncLeague + "")
        var hunks = [
            Hunk(leftStart: 4, leftCount: 0, rightStart: 4, rightCount: 3),
            Hunk(leftStart: 7, leftCount: 1, rightStart: 10, rightCount: 0),
            Hunk(leftStart: 10, leftCount: 2, rightStart: 12, rightCount: 0),
        ]

        let postToPre = SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .go)

        // Merged right hunk must split into 2 moved target sub-hunks -> total 4 hunks.
        XCTAssertEqual(hunks.count, 4)
        XCTAssertEqual(postToPre, [0, 0, 1, 2])

        // Sub-hunk 0: HandleEvent...ByRid (right line 4, 1 line) paired with deleted hunk 2 (left line 7).
        XCTAssertEqual(hunks[0].kind, .added)
        XCTAssertEqual(hunks[0].rightStart, 4)
        XCTAssertEqual(hunks[0].rightCount, 1)
        let targetHandle = try XCTUnwrap(hunks[0].moveInfo)
        let sourceHandle = try XCTUnwrap(hunks[2].moveInfo)
        XCTAssertEqual(targetHandle.role, .target)
        XCTAssertEqual(sourceHandle.role, .source)
        XCTAssertEqual(targetHandle.pairID, sourceHandle.pairID)
        XCTAssertEqual(targetHandle.counterpartHunkIndex, 2)
        XCTAssertEqual(sourceHandle.counterpartHunkIndex, 0)
        XCTAssertGreaterThanOrEqual(targetHandle.similarity, SemanticDiff.defaultShortMoveSimilarityThreshold)
        XCTAssertLessThan(targetHandle.similarity, 1.0)

        // Tweaked HandleEvent move must carry word-level MoveInlineDiff highlighting both sides.
        let handleInline = try XCTUnwrap(targetHandle.inlineDiff)
        XCTAssertEqual(handleInline, sourceHandle.inlineDiff)
        XCTAssertEqual(handleInline.source.count, 1)
        XCTAssertEqual(handleInline.target.count, 1)
        XCTAssertFalse(handleInline.source[0].isEmpty)
        XCTAssertFalse(handleInline.target[0].isEmpty)

        // Sub-hunk 1: SyncLeague + trailing blank line (right lines 5..6) paired with deleted hunk 3 (left lines 10..11).
        XCTAssertEqual(hunks[1].kind, .added)
        XCTAssertEqual(hunks[1].rightStart, 5)
        XCTAssertEqual(hunks[1].rightCount, 2)
        let targetSync = try XCTUnwrap(hunks[1].moveInfo)
        let sourceSync = try XCTUnwrap(hunks[3].moveInfo)
        XCTAssertEqual(targetSync.role, .target)
        XCTAssertEqual(sourceSync.role, .source)
        XCTAssertEqual(targetSync.pairID, sourceSync.pairID)
        XCTAssertNotEqual(targetSync.pairID, targetHandle.pairID)
        XCTAssertEqual(targetSync.counterpartHunkIndex, 3)
        XCTAssertEqual(sourceSync.counterpartHunkIndex, 1)
        XCTAssertEqual(targetSync.similarity, 1.0, accuracy: 0.0001)
        XCTAssertNil(targetSync.inlineDiff)
        XCTAssertNil(sourceSync.inlineDiff)

        try assertBidirectionalMovesAndFullCoverage(
            hunks: hunks,
            leftLines: leftLines,
            rightLines: rightLines,
            language: .go
        )

        // Also verify DiffLoader.buildGroupFiltered preserves valid groupHunkIndexMap after splitting.
        let baseline = GroupFilterBaseline(
            oldLines: leftLines,
            newLines: rightLines,
            rawHunks: [
                Hunk(leftStart: 4, leftCount: 0, rightStart: 4, rightCount: 3),
                Hunk(leftStart: 7, leftCount: 1, rightStart: 10, rightCount: 0),
                Hunk(leftStart: 10, leftCount: 2, rightStart: 12, rightCount: 0),
            ],
            rightSpans: [],
            shouldHighlight: false,
            hasWorktreeFile: false
        )
        var semantic = SemanticDiffOptions.disabled
        semantic.detectMoves = true
        let filteredDoc = DiffLoader.buildGroupFiltered(
            baseline: baseline,
            includedGroupHunks: [0, 1, 2],
            language: .go,
            semanticOptions: semantic,
            ignoreWhitespace: false,
            leftTitle: "old",
            rightTitle: "new"
        )
        XCTAssertEqual(filteredDoc.hunks.count, 4)
        XCTAssertEqual(filteredDoc.groupHunkIndexMap, [0: 0, 1: 2, 2: 3])
    }

    func testDetectMovesSplitsSingleDeletedHunkIntoTwoDispersedAddedHunks() throws {
        // Reverse split: one large deleted hunk on the left split into two separate added hunks on the right.
        let leftLines = [
            "func runPipeline() {",
            "    cfg := loadPipelineConfig(ctx, tenantID)",
            "    validatePipelineConfig(cfg)",
            "    applyPipelineConfig(worker, cfg)",
            "    metrics.RecordPipelineStart(tenantID, cfg.Version)",
            "    notifyPipelineObservers(tenantID, cfg.Version)",
            "    anchorOne()",
            "    anchorTwo()",
            "}",
        ]
        let rightLines = [
            "func runPipeline() {",
            "    anchorOne()",
            "    cfg := loadPipelineConfig(ctx, tenantID)",
            "    validatePipelineConfig(cfg)",
            "    applyPipelineConfig(worker, cfg)",
            "    anchorTwo()",
            "    metrics.RecordPipelineStart(tenantID, cfg.Version)",
            "    notifyPipelineObservers(tenantID, cfg.Version)",
            "}",
        ]

        // Raw hunks:
        // 0: single 5-line .deleted hunk (left 1..<6)
        // 1: first 3-line .added hunk (right 2..<5)
        // 2: second 2-line .added hunk (right 6..<8)
        var hunks = [
            Hunk(leftStart: 1, leftCount: 5, rightStart: 1, rightCount: 0),
            Hunk(leftStart: 7, leftCount: 0, rightStart: 2, rightCount: 3),
            Hunk(leftStart: 8, leftCount: 0, rightStart: 6, rightCount: 2),
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .go)

        // Deleted hunk 0 must split into 2 moved source sub-hunks -> total 4 hunks.
        XCTAssertEqual(hunks.count, 4)
        XCTAssertEqual(hunks[0].kind, .deleted)
        XCTAssertEqual(hunks[0].leftStart, 1)
        XCTAssertEqual(hunks[0].leftCount, 3)
        XCTAssertEqual(hunks[1].kind, .deleted)
        XCTAssertEqual(hunks[1].leftStart, 4)
        XCTAssertEqual(hunks[1].leftCount, 2)

        let srcA = try XCTUnwrap(hunks[0].moveInfo)
        let dstA = try XCTUnwrap(hunks[2].moveInfo)
        XCTAssertEqual(srcA.role, .source)
        XCTAssertEqual(dstA.role, .target)
        XCTAssertEqual(srcA.counterpartHunkIndex, 2)
        XCTAssertEqual(dstA.counterpartHunkIndex, 0)
        XCTAssertEqual(srcA.similarity, 1.0, accuracy: 0.0001)

        let srcB = try XCTUnwrap(hunks[1].moveInfo)
        let dstB = try XCTUnwrap(hunks[3].moveInfo)
        XCTAssertEqual(srcB.role, .source)
        XCTAssertEqual(dstB.role, .target)
        XCTAssertEqual(srcB.counterpartHunkIndex, 3)
        XCTAssertEqual(dstB.counterpartHunkIndex, 1)
        XCTAssertEqual(srcB.similarity, 1.0, accuracy: 0.0001)

        try assertBidirectionalMovesAndFullCoverage(
            hunks: hunks,
            leftLines: leftLines,
            rightLines: rightLines,
            language: .go
        )
    }

    func testDetectMovesSplitsMixedPartialMovePreservingSurroundingAddedLines() throws {
        // 4-line added hunk where only the middle 2 lines were moved from elsewhere;
        // the leading and trailing lines are brand new and must stay plain `.added`.
        let leftLines = [
            "func syncState() {",
            "    headerLine()",
            "    middleAnchor()",
            "    snapshot := captureLedgerSnapshot(accountID, regionCode)",
            "    publishLedgerSnapshot(dispatcher, snapshot)",
            "    footerLine()",
            "}",
        ]
        let rightLines = [
            "func syncState() {",
            "    headerLine()",
            "    auditLog.BeginSyncTransaction(accountID)",
            "    snapshot := captureLedgerSnapshot(accountID, regionCode)",
            "    publishLedgerSnapshot(dispatcher, snapshot)",
            "    auditLog.EndSyncTransaction(accountID)",
            "    middleAnchor()",
            "    footerLine()",
            "}",
        ]

        // Raw hunks:
        // 0: 4-line .added hunk (right 2..<6) containing [newTop, moved1, moved2, newBottom]
        // 1: 2-line .deleted hunk (left 3..<5) containing [moved1, moved2]
        var hunks = [
            Hunk(leftStart: 2, leftCount: 0, rightStart: 2, rightCount: 4),
            Hunk(leftStart: 3, leftCount: 2, rightStart: 7, rightCount: 0),
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .go)

        // Added hunk splits into 3 sub-hunks (plain added, moved target, plain added) + 1 moved source = 4 hunks.
        XCTAssertEqual(hunks.count, 4)

        // Leading brand-new line stays plain .added.
        XCTAssertEqual(hunks[0].kind, .added)
        XCTAssertEqual(hunks[0].rightStart, 2)
        XCTAssertEqual(hunks[0].rightCount, 1)
        XCTAssertNil(hunks[0].moveInfo)

        // Middle 2 lines are marked as moved .target paired with source hunk 3.
        XCTAssertEqual(hunks[1].kind, .added)
        XCTAssertEqual(hunks[1].rightStart, 3)
        XCTAssertEqual(hunks[1].rightCount, 2)
        let movedTarget = try XCTUnwrap(hunks[1].moveInfo)
        let movedSource = try XCTUnwrap(hunks[3].moveInfo)
        XCTAssertEqual(movedTarget.role, .target)
        XCTAssertEqual(movedSource.role, .source)
        XCTAssertEqual(movedTarget.counterpartHunkIndex, 3)
        XCTAssertEqual(movedSource.counterpartHunkIndex, 1)
        XCTAssertEqual(movedTarget.similarity, 1.0, accuracy: 0.0001)

        // Trailing brand-new line stays plain .added.
        XCTAssertEqual(hunks[2].kind, .added)
        XCTAssertEqual(hunks[2].rightStart, 5)
        XCTAssertEqual(hunks[2].rightCount, 1)
        XCTAssertNil(hunks[2].moveInfo)

        // Verify 100% line conservation across split sub-hunks.
        let addedLinesCovered = hunks[0...2].flatMap { Array(rightLines[$0.rightStart..<($0.rightStart + $0.rightCount)]) }
        XCTAssertEqual(addedLinesCovered, Array(rightLines[2..<6]))

        try assertBidirectionalMovesAndFullCoverage(
            hunks: hunks,
            leftLines: leftLines,
            rightLines: rightLines,
            language: .go
        )
    }

    func testDetectMovesRejectsBoilerplateShortLinesAndUnrelatedCalls() {
        let leftLines = [
            "func sample() error {",
            "    }",
            "    keepA()",
            "    return nil",
            "    keepB()",
            "    else {",
            "    keepC()",
            "    log(\"a\")",
            "    keepD()",
            "    player.SendReward(tableMgr, currentRole, recvData.Lid)",
            "    keepE()",
            "}",
        ]
        let rightLines = [
            "func sample() error {",
            "    keepA()",
            "    keepB()",
            "    keepC()",
            "    keepD()",
            "    keepE()",
            "    }",
            "    return nil",
            "    else {",
            "    log(\"b\")",
            "    player.RemoveMember(tableMgr, currentRole, recvData.Lid)",
            "}",
        ]

        var hunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 0), // "}"
            Hunk(leftStart: 3, leftCount: 1, rightStart: 2, rightCount: 0), // "return nil"
            Hunk(leftStart: 5, leftCount: 1, rightStart: 3, rightCount: 0), // "else {"
            Hunk(leftStart: 7, leftCount: 1, rightStart: 4, rightCount: 0), // log("a")
            Hunk(leftStart: 9, leftCount: 1, rightStart: 5, rightCount: 0), // player.SendReward(...)
            Hunk(leftStart: 11, leftCount: 0, rightStart: 6, rightCount: 1), // "}"
            Hunk(leftStart: 11, leftCount: 0, rightStart: 7, rightCount: 1), // "return nil"
            Hunk(leftStart: 11, leftCount: 0, rightStart: 8, rightCount: 1), // "else {"
            Hunk(leftStart: 11, leftCount: 0, rightStart: 9, rightCount: 1), // log("b")
            Hunk(leftStart: 11, leftCount: 0, rightStart: 10, rightCount: 1), // player.RemoveMember(...)
        ]

        SemanticDiff.detectMoves(in: &hunks, leftLines: leftLines, rightLines: rightLines, language: .go)

        XCTAssertEqual(hunks.count, 10)
        for (idx, h) in hunks.enumerated() {
            XCTAssertNil(h.moveInfo, "Hunk \(idx) should not be falsely marked as moved")
        }
    }

    private func assertBidirectionalMovesAndFullCoverage(
        hunks: [Hunk],
        leftLines: [String],
        rightLines: [String],
        language: LanguageSpec
    ) throws {
        // 1. Every moveInfo link must be valid and strictly symmetric.
        for (idx, h) in hunks.enumerated() {
            guard let info = h.moveInfo else { continue }
            XCTAssertTrue(hunks.indices.contains(info.counterpartHunkIndex))
            XCTAssertNotEqual(info.counterpartHunkIndex, idx)
            let other = try XCTUnwrap(hunks[info.counterpartHunkIndex].moveInfo)
            XCTAssertEqual(other.pairID, info.pairID)
            XCTAssertNotEqual(other.role, info.role)
            XCTAssertEqual(other.counterpartHunkIndex, idx)
            XCTAssertEqual(other.similarity, info.similarity, accuracy: 1e-9)
        }

        // 2. DiffDocument segments must cover every left and right line with zero gaps or overlaps.
        let doc = DiffDocument(
            left: TextBuffer(lines: leftLines),
            right: TextBuffer(lines: rightLines),
            hunks: hunks,
            language: language
        )
        XCTAssertEqual(doc.hunks.count, hunks.count)
        var lPos = 0
        var rPos = 0
        for seg in doc.segments {
            XCTAssertEqual(seg.leftStart, lPos)
            XCTAssertEqual(seg.rightStart, rPos)
            if seg.hunk < 0 {
                XCTAssertEqual(seg.leftCount, seg.rightCount)
                XCTAssertEqual(
                    Array(leftLines[seg.leftStart..<(seg.leftStart + seg.leftCount)]),
                    Array(rightLines[seg.rightStart..<(seg.rightStart + seg.rightCount)])
                )
            }
            lPos += seg.leftCount
            rPos += seg.rightCount
        }
        XCTAssertEqual(lPos, leftLines.count)
        XCTAssertEqual(rPos, rightLines.count)
    }

    // MARK: - 4. Cross-Hunk Rename Detection (detectRenames)

    func testDetectRenamesGroupsConsistentCrossHunkRenamesAndProvidesO1Lookup() throws {
        let leftLines = [
            "struct Profile {",
            "    var userName: String",
            "    func greet() {",
            "        print(userName)",
            "        log(fetchData(userName))",
            "    }",
            "    func refresh() {",
            "        _ = fetchData(userName)",
            "    }",
            "}",
        ]
        let rightLines = [
            "struct Profile {",
            "    var accountName: String",
            "    func greet() {",
            "        print(accountName)",
            "        log(loadRecords(accountName))",
            "    }",
            "    func refresh() {",
            "        _ = loadRecords(accountName)",
            "    }",
            "}",
        ]

        var hunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1),
            Hunk(leftStart: 3, leftCount: 2, rightStart: 3, rightCount: 2),
            Hunk(leftStart: 7, leftCount: 1, rightStart: 7, rightCount: 1),
        ]
        DiffLoader.addInlineHighlights(&hunks, left: leftLines, right: rightLines)

        let groups = SemanticDiff.detectRenames(hunks: hunks, leftLines: leftLines, rightLines: rightLines, language: .swift)
        XCTAssertEqual(groups.count, 2)

        let doc = DiffDocument(left: TextBuffer(lines: leftLines), right: TextBuffer(lines: rightLines),
                               hunks: hunks, language: .swift)
        doc.setRenameGroups(groups)

        let userGroup = try XCTUnwrap(doc.renameGroup(for: "userName", newName: "accountName"))
        XCTAssertEqual(userGroup.occurrenceCount, 4)
        XCTAssertEqual(userGroup.hunkIndices, [0, 1, 2])

        let fetchGroup = try XCTUnwrap(doc.renameGroup(for: "fetchData", newName: "loadRecords"))
        XCTAssertEqual(fetchGroup.occurrenceCount, 2)
        XCTAssertEqual(fetchGroup.hunkIndices, [1, 2])
        XCTAssertNotEqual(userGroup.colorIndex, fetchGroup.colorIndex)

        // Verify O(1) lookups by pair, by span, and by line.
        XCTAssertEqual(doc.renameColorIndex(oldName: "userName", newName: "accountName"), userGroup.colorIndex)
        let line1LeftOccs = doc.renameOccurrences(side: .left, lineIndex: 1)
        XCTAssertEqual(line1LeftOccs.count, 1)
        let occ = line1LeftOccs[0]
        XCTAssertEqual(
            doc.renameColorIndex(hunkIndex: occ.hunkIndex, side: .left, lineIndex: occ.lineIndex, range: occ.range),
            userGroup.colorIndex
        )
        let extracted = (leftLines[1] as NSString).substring(with: NSRange(location: occ.range.lowerBound, length: occ.range.count))
        XCTAssertEqual(extracted, "userName")
    }

    func testDetectRenamesRejectsKeywordsSingleOccurrencesShortNamesAndAmbiguousMappings() {
        let leftLines = [
            "var x = true",
            "var y = true",
            "let oneOff = 1",
            "let a = foo + foo",
            "let b = foo + foo",
        ]
        let rightLines = [
            "let x = false",
            "let y = false",
            "let renamedOnce = 1",
            "let a = bar + bar",
            "let b = baz + baz",
        ]
        var hunks = [
            Hunk(leftStart: 0, leftCount: 2, rightStart: 0, rightCount: 2), // var->let, true->false (keywords)
            Hunk(leftStart: 2, leftCount: 1, rightStart: 2, rightCount: 1), // oneOff->renamedOnce (only 1x)
            Hunk(leftStart: 3, leftCount: 1, rightStart: 3, rightCount: 1), // foo->bar (2x)
            Hunk(leftStart: 4, leftCount: 1, rightStart: 4, rightCount: 1), // foo->baz (2x) -> 50% dominance, ambiguous!
        ]
        DiffLoader.addInlineHighlights(&hunks, left: leftLines, right: rightLines)

        let groups = SemanticDiff.detectRenames(hunks: hunks, leftLines: leftLines, rightLines: rightLines, language: .swift)
        XCTAssertTrue(groups.isEmpty)
    }

    // MARK: - 5. Unchanged Region Folding (DiffFoldRegion & DiffDisplayMap)

    func testDisplayMapFoldsLongUnchangedSegmentsAndSupportsBidirectionalLookups() throws {
        // 40-line document with two 1-line modified hunks at line 15 and line 32.
        let leftLines = (0..<40).map { "line \($0)" }
        var rightLines = leftLines
        rightLines[15] = "line 15 modified"
        rightLines[32] = "line 32 modified"

        let hunks = [
            Hunk(leftStart: 15, leftCount: 1, rightStart: 15, rightCount: 1),
            Hunk(leftStart: 32, leftCount: 1, rightStart: 32, rightCount: 1),
        ]
        let doc = DiffDocument(left: TextBuffer(lines: leftLines), right: TextBuffer(lines: rightLines),
                               hunks: hunks, language: .plain)

        // Segments:
        // 0: unchanged 0..<15  (15 lines -> top fold 0..<12 [12 hidden], trailing context 12,13,14)
        // 1: hunk 0 at 15
        // 2: unchanged 16..<32 (16 lines -> leading 16,17,18, middle fold 19..<29 [10 hidden], trailing 29,30,31)
        // 3: hunk 1 at 32
        // 4: unchanged 33..<40 (7 lines -> leading 33,34,35, remaining 4 < minHidden 6 -> NOT folded!)
        let map = DiffDisplayMap(document: doc, expandedSegments: [], collapseEnabled: true, contextLines: 3, minHiddenLines: 6)

        XCTAssertEqual(map.foldRegions.count, 2)
        XCTAssertEqual(map.foldRegions[0], DiffFoldRegion(segmentIndex: 0, leftRange: 0..<12, rightRange: 0..<12, hiddenLineCount: 12))
        XCTAssertEqual(map.foldRegions[1], DiffFoldRegion(segmentIndex: 2, leftRange: 19..<29, rightRange: 19..<29, hiddenLineCount: 10))
        XCTAssertEqual(map.totalHiddenLines, 22)

        // Expected display row count: 40 - 22 + 2 fold bars = 20 rows.
        XCTAssertEqual(map.totalRowCount, 20)

        // Row 0 is fold bar for segment 0; hidden line 5 maps to row 0.
        XCTAssertEqual(map.foldRegion(at: 0), map.foldRegions[0])
        XCTAssertNil(map.lineNumber(at: 0, side: .left))
        XCTAssertTrue(map.isLineHidden(5, side: .left))
        XCTAssertEqual(map.displayRow(forLine: 5, side: .left), 0)
        XCTAssertEqual(map.foldRegion(containingLine: 5, side: .right), map.foldRegions[0])

        // Line 12 is first visible context line (row 1); hunk 0 (line 15) sits at row 4.
        XCTAssertFalse(map.isLineHidden(12, side: .left))
        XCTAssertEqual(map.displayRow(forLine: 12, side: .left), 1)
        XCTAssertEqual(map.lineNumber(at: 1, side: .right), 12)
        XCTAssertEqual(map.displayRow(forHunk: 0), 4)
        XCTAssertEqual(map.displayRow(forLine: 15, side: .right), 4)

        // Expanding segment 0 unfolds its 12 hidden lines while keeping segment 2 collapsed.
        let expanded = DiffDisplayMap(document: doc, expandedSegments: [0], collapseEnabled: true, contextLines: 3, minHiddenLines: 6)
        XCTAssertEqual(expanded.foldRegions.count, 1)
        XCTAssertEqual(expanded.foldRegions[0].segmentIndex, 2)
        XCTAssertEqual(expanded.totalRowCount, 31)
        XCTAssertEqual(expanded.displayRow(forLine: 5, side: .left), 5)
        XCTAssertFalse(expanded.isLineHidden(5, side: .left))

        // Disabled folding returns all 40 lines with zero fold bars.
        let unfolded = DiffDisplayMap(document: doc, expandedSegments: [], collapseEnabled: false)
        XCTAssertTrue(unfolded.foldRegions.isEmpty)
        XCTAssertEqual(unfolded.totalRowCount, 40)
        XCTAssertEqual(unfolded.displayRow(forHunk: 1), 32)
    }

    // MARK: - 6. Symbol Block End Lines & Changed Symbols Attribution

    func testFileSymbolExtractorInfersBraceAndPythonEndLines() {
        let swiftSource = """
        struct Calculator {
            func add(
                a: Int,
                b: Int
            ) -> Int {
                return a + b
            }

            func inlineSub(_ a: Int, _ b: Int) -> Int { return a - b }
        }

        func topLevel() {
            let x = 1
            print(x)
        }
        """
        let swiftSymbols = FileSymbolExtractor.extract(lines: swiftSource.components(separatedBy: "\n"), language: .swift)
        let byName = Dictionary(uniqueKeysWithValues: swiftSymbols.map { ($0.name, $0) })

        XCTAssertEqual(byName["Calculator"]?.lineNumber, 1)
        XCTAssertEqual(byName["Calculator"]?.endLine, 10)
        XCTAssertEqual(byName["add"]?.lineNumber, 2)
        XCTAssertEqual(byName["add"]?.endLine, 7)
        XCTAssertEqual(byName["inlineSub"]?.lineNumber, 9)
        XCTAssertEqual(byName["inlineSub"]?.endLine, 9)
        XCTAssertEqual(byName["topLevel"]?.lineNumber, 12)
        XCTAssertEqual(byName["topLevel"]?.endLine, 15)

        let pythonSource = """
        class Worker:
            def run(self):
                value = 1
                return value

            def stop(self):
                pass

        def helper():
            return 42
        """
        let pySymbols = FileSymbolExtractor.extract(lines: pythonSource.components(separatedBy: "\n"), language: .python)
        let pyByName = Dictionary(uniqueKeysWithValues: pySymbols.map { ($0.name, $0) })

        XCTAssertEqual(pyByName["Worker"]?.lineNumber, 1)
        XCTAssertEqual(pyByName["Worker"]?.endLine, 7)
        XCTAssertEqual(pyByName["run"]?.lineNumber, 2)
        XCTAssertEqual(pyByName["run"]?.endLine, 4)
        XCTAssertEqual(pyByName["stop"]?.lineNumber, 6)
        XCTAssertEqual(pyByName["stop"]?.endLine, 7)
        XCTAssertEqual(pyByName["helper"]?.lineNumber, 9)
        XCTAssertEqual(pyByName["helper"]?.endLine, 10)
    }

    func testChangedSymbolsAttributesHunksIncludingInteriorDeletions() {
        let swiftSource = """
        struct Store {
            func alpha() {
                let a = 1
                print(a)
            }

            func beta() {
                let b = 2
                print(b)
            }
        }
        """
        let symbols = FileSymbolExtractor.extract(lines: swiftSource.components(separatedBy: "\n"), language: .swift)

        // Hunk 0: modification on 0-based line 2 (1-based line 3, inside `alpha` and `Store`).
        // Hunk 1: pure deletion anchored at 0-based line 8 (1-based line 9, inside `beta` [7...10] and `Store` [1...11]).
        let hunks = [
            Hunk(leftStart: 2, leftCount: 1, rightStart: 2, rightCount: 1),
            Hunk(leftStart: 8, leftCount: 2, rightStart: 8, rightCount: 0),
        ]

        let changed = FileSymbolExtractor.changedSymbols(symbols: symbols, hunks: hunks, side: .right)
        let map = Dictionary(uniqueKeysWithValues: changed.map { ($0.symbol.name, $0.hunkIndices) })

        XCTAssertEqual(map["Store"], [0, 1])
        XCTAssertEqual(map["alpha"], [0])
        XCTAssertEqual(map["beta"], [1])

        // Pure deletion placed strictly above `beta` (rightStart = 6, i.e. blank line 6 before `func beta()` at line 7)
        // must NOT bleed into `beta`.
        let outsideDeletion = [Hunk(leftStart: 6, leftCount: 1, rightStart: 6, rightCount: 0)]
        let outsideChanged = FileSymbolExtractor.changedSymbols(symbols: symbols, hunks: outsideDeletion, side: .right)
        XCTAssertFalse(outsideChanged.contains(where: { $0.symbol.name == "beta" }))
        XCTAssertTrue(outsideChanged.contains(where: { $0.symbol.name == "Store" }))
    }

    func testDiffLoaderEndToEndSemanticPipelineOnSwiftFile() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let fileURL = repo.appendingPathComponent("Service.swift")
        let oldSource = """
        // Old file header
        struct Service {
            func movedHelper(value: Int) -> Int {
                let step1 = value + 10
                let step2 = step1 * 2
                return step2
            }

            let keep0 = 0
            let oldToken = "abc"
            let keep1 = 1
            let keep2 = 2
            let keep3 = 3
            let keep4 = 4
            let keep5 = 5
            let keep6 = 6
            let keep7 = 7
            let keep8 = 8
            let keep9 = 9
            let keep10 = 10
            let keep11 = 11
            let keep12 = 12
            let keep13 = 13

            func useToken() -> String {
                return oldToken
            }
        }
        """
        let newSource = """
        // Updated file header
        struct Service {
            let keep0 = 0
            let newToken = "abc"
            let keep1 = 1
            let keep2 = 2
            let keep3 = 3
            let keep4 = 4
            let keep5 = 5
            let keep6 = 6
            let keep7 = 7
            let keep8 = 8
            let keep9 = 9
            let keep10 = 10
            let keep11 = 11
            let keep12 = 12
            let keep13 = 13

            func useToken() -> String {
                return newToken
            }

            func movedHelper(value: Int) -> Int {
                let step1 = value + 10
                let step2 = step1 * 2
                return step2
            }
        }
        """
        try oldSource.write(to: fileURL, atomically: true, encoding: .utf8)
        try await gitCommitAll(in: repo, message: "initial swift")
        try newSource.write(to: fileURL, atomically: true, encoding: .utf8)

        var semantic = SemanticDiffOptions.default
        semantic.ignoreComments = true
        semantic.detectMoves = true
        semantic.detectRenames = true
        semantic.collapseUnchanged = true

        let req = DiffRequest(root: repo, path: "Service.swift", oldPath: nil, kind: .modified,
                              source: .worktree(base: "HEAD"), semantic: semantic)
        let doc = await DiffLoader.load(req)

        XCTAssertEqual(doc.hiddenCommentHunkCount, 1)
        XCTAssertFalse(doc.isJSONNormalized)
        XCTAssertTrue(doc.hunks.contains(where: { $0.moveInfo?.role == .source }))
        XCTAssertTrue(doc.hunks.contains(where: { $0.moveInfo?.role == .target }))
        let rename = try XCTUnwrap(doc.renameGroup(for: "oldToken", newName: "newToken"))
        XCTAssertEqual(rename.occurrenceCount, 2)

        let displayMap = doc.displayMap()
        XCTAssertFalse(displayMap.foldRegions.isEmpty)
        XCTAssertGreaterThan(displayMap.totalHiddenLines, 0)
    }

    // MARK: - 7. Content-Level AI Group Hunk Filtering (applyGroupHunkFilter)

    func testApplyGroupHunkFilterKeepsOnlyIncludedSubsetAndMapsRawIndices() throws {
        let oldLines = [
            "ctx0",
            "oldMod0",        // hunk 0: modified (1 -> 2 lines)
            "ctx1",
            "oldDel1",        // hunk 1: pure deletion (2 -> 0 lines)
            "oldDel2",
            "ctx2",
            "ctx3",           // hunk 2: pure addition after ctx3 (0 -> 2 lines)
            "ctx4",
            "oldMultiA",      // hunk 3: multi-line modified (2 -> 1 line)
            "oldMultiB",
            "ctx5",
        ]
        let newLines = [
            "ctx0",
            "newMod0a",       // hunk 0
            "newMod0b",
            "ctx1",
            "ctx2",
            "ctx3",
            "newAdd1",        // hunk 2
            "newAdd2",
            "ctx4",
            "newMultiMerged", // hunk 3
            "ctx5",
            "newTail",        // hunk 4: trailing pure addition (0 -> 1 line)
        ]

        let rawHunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 2),
            Hunk(leftStart: 3, leftCount: 2, rightStart: 4, rightCount: 0),
            Hunk(leftStart: 7, leftCount: 0, rightStart: 6, rightCount: 2),
            Hunk(leftStart: 8, leftCount: 2, rightStart: 9, rightCount: 1),
            Hunk(leftStart: 11, leftCount: 0, rightStart: 11, rightCount: 1),
        ]

        // Keep only raw hunks 1 (deletion) and 3 (multi-line modification).
        let result = SemanticDiff.applyGroupHunkFilter(
            oldLines: oldLines,
            newLines: newLines,
            rawHunks: rawHunks,
            includedHunkIndices: [1, 3]
        )

        XCTAssertEqual(result.filteredHunks.count, 2)
        XCTAssertEqual(result.rawToFilteredIndex, [1: 0, 3: 1])

        // Verify filtered hunk 0 matches raw hunk 1 verbatim (deletion of oldDel1, oldDel2 at rightStart 4).
        let fh0 = result.filteredHunks[0]
        XCTAssertEqual(fh0.kind, .deleted)
        XCTAssertEqual(fh0.rightStart, 4)
        XCTAssertEqual(fh0.rightCount, 0)
        XCTAssertEqual(Array(result.filteredOldLines[fh0.leftStart..<(fh0.leftStart + fh0.leftCount)]), ["oldDel1", "oldDel2"])

        // Verify filtered hunk 1 matches raw hunk 3 verbatim (rightStart 9 preserved!).
        let fh1 = result.filteredHunks[1]
        XCTAssertEqual(fh1.kind, .modified)
        XCTAssertEqual(fh1.rightStart, 9)
        XCTAssertEqual(fh1.rightCount, 1)
        XCTAssertEqual(Array(result.filteredOldLines[fh1.leftStart..<(fh1.leftStart + fh1.leftCount)]), ["oldMultiA", "oldMultiB"])
        XCTAssertEqual(Array(newLines[fh1.rightStart..<(fh1.rightStart + fh1.rightCount)]), ["newMultiMerged"])

        // Non-included hunks (0, 2, 4) must completely vanish: every unchanged segment matches 1:1 verbatim.
        let doc = DiffDocument(
            left: TextBuffer(lines: result.filteredOldLines),
            right: TextBuffer(lines: newLines),
            hunks: result.filteredHunks,
            language: .plain
        )
        for seg in doc.segments where seg.hunk < 0 {
            XCTAssertEqual(seg.leftCount, seg.rightCount)
            XCTAssertEqual(
                Array(doc.left.lines[seg.leftStart..<(seg.leftStart + seg.leftCount)]),
                Array(doc.right.lines[seg.rightStart..<(seg.rightStart + seg.rightCount)])
            )
        }
        // Excluded changes appear identically in filteredOldLines (no longer diffs).
        XCTAssertTrue(result.filteredOldLines.contains("newMod0a"))
        XCTAssertTrue(result.filteredOldLines.contains("newAdd1"))
        XCTAssertTrue(result.filteredOldLines.contains("newTail"))
        XCTAssertFalse(result.filteredOldLines.contains("oldMod0"))
    }

    func testApplyGroupHunkFilterFullEmptyAndOutOfBoundsBoundaries() {
        let oldText = "a\nold1\nb\nold2\nc"
        let newText = "a\nnew1\nb\nnew2\nc"
        let rawHunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1),
            Hunk(leftStart: 3, leftCount: 1, rightStart: 3, rightCount: 1),
        ]

        // All selected -> identical to original oldText and rawHunks.
        let allSelected = SemanticDiff.applyGroupHunkFilter(
            oldText: oldText,
            newText: newText,
            rawHunks: rawHunks,
            includedHunkIndices: [0, 1]
        )
        XCTAssertEqual(allSelected.filteredOldText, oldText)
        XCTAssertEqual(allSelected.filteredHunks, rawHunks)
        XCTAssertEqual(allSelected.rawToFilteredIndex, [0: 0, 1: 1])

        // Empty selection -> filteredOld matches newText completely, zero hunks.
        let noneSelected = SemanticDiff.applyGroupHunkFilter(
            oldText: oldText,
            newText: newText,
            rawHunks: rawHunks,
            includedHunkIndices: []
        )
        XCTAssertEqual(noneSelected.filteredOldText, newText)
        XCTAssertTrue(noneSelected.filteredHunks.isEmpty)
        XCTAssertTrue(noneSelected.rawToFilteredIndex.isEmpty)

        // Out-of-bounds indices are safely ignored.
        let outOfBounds = SemanticDiff.applyGroupHunkFilter(
            oldText: oldText,
            newText: newText,
            rawHunks: rawHunks,
            includedHunkIndices: [-1, 5, 99]
        )
        XCTAssertEqual(outOfBounds.filteredOldText, newText)
        XCTAssertTrue(outOfBounds.filteredHunks.isEmpty)
        XCTAssertTrue(outOfBounds.rawToFilteredIndex.isEmpty)
    }

    func testDiffLoaderGroupHunkFilterEndToEndAndIgnoreCommentsRemapping() async throws {
        let repo = try makeTempGitRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let fileURL = repo.appendingPathComponent("Feature.swift")
        let oldSource = """
        // Old header comment
        struct Feature {
            let alpha = 1
            let keepA = true
            let beta = 2
            let keepB = true
            let gamma = 3
        }
        """
        let newSource = """
        // New header comment
        struct Feature {
            let alpha = 10
            let keepA = true
            let beta = 20
            let keepB = true
            let gamma = 30
        }
        """
        try oldSource.write(to: fileURL, atomically: true, encoding: .utf8)
        try await gitCommitAll(in: repo, message: "initial feature")
        try newSource.write(to: fileURL, atomically: true, encoding: .utf8)

        // Raw hunks: 0 = comment, 1 = alpha, 2 = beta, 3 = gamma.
        var semantic = SemanticDiffOptions.disabled
        semantic.ignoreComments = false
        let req = DiffRequest(root: repo, path: "Feature.swift", oldPath: nil, kind: .modified,
                              source: .worktree(base: "HEAD"), semantic: semantic)

        // Filter to group containing hunks {0, 2, 3} (excluding hunk 1 `alpha`).
        let doc = await DiffLoader.load(req, includedGroupHunks: [0, 2, 3])
        XCTAssertTrue(doc.isGroupFiltered)
        XCTAssertNotNil(doc.editing?.readOnlyReason)
        XCTAssertEqual(doc.hunks.count, 3)
        XCTAssertEqual(doc.groupHunkIndexMap, [0: 0, 2: 1, 3: 2])
        // Excluded `alpha` line is synced to `let alpha = 10` on both sides so it is invisible.
        XCTAssertEqual(doc.left.lines[2], "    let alpha = 10")
        XCTAssertEqual(doc.right.lines[2], "    let alpha = 10")

        // With ignoreComments = true, comment hunk 0 is hidden and map remaps [2: 0, 3: 1].
        var noComments = semantic
        noComments.ignoreComments = true
        let reqNoComments = DiffRequest(root: repo, path: "Feature.swift", oldPath: nil, kind: .modified,
                                        source: .worktree(base: "HEAD"), semantic: noComments)
        let docNoComments = await DiffLoader.load(reqNoComments, includedGroupHunks: [0, 2, 3])
        XCTAssertTrue(docNoComments.isGroupFiltered)
        XCTAssertEqual(docNoComments.hiddenCommentHunkCount, 1)
        XCTAssertEqual(docNoComments.hunks.count, 2)
        XCTAssertEqual(docNoComments.groupHunkIndexMap, [2: 0, 3: 1])

        // Fast synchronous re-filter using cached baseline switches cleanly to hunk {1} only.
        let baseline = try XCTUnwrap(doc.groupFilterBaseline)
        let switched = DiffLoader.buildGroupFiltered(
            baseline: baseline,
            includedGroupHunks: [1],
            language: doc.language,
            semanticOptions: semantic,
            ignoreWhitespace: false,
            leftTitle: doc.leftTitle,
            rightTitle: doc.rightTitle
        )
        XCTAssertTrue(switched.isGroupFiltered)
        XCTAssertEqual(switched.hunks.count, 1)
        XCTAssertEqual(switched.groupHunkIndexMap, [1: 0])
        XCTAssertEqual(switched.left.lines[2], "    let alpha = 1")
        XCTAssertEqual(switched.right.lines[2], "    let alpha = 10")
        XCTAssertEqual(switched.left.lines[4], "    let beta = 20")

        // Empty group produces zero hunks and a clear note.
        let emptyDoc = await DiffLoader.load(req, includedGroupHunks: [])
        XCTAssertTrue(emptyDoc.isGroupFiltered)
        XCTAssertTrue(emptyDoc.hunks.isEmpty)
        XCTAssertEqual(emptyDoc.left.lines, emptyDoc.right.lines)
        XCTAssertTrue(emptyDoc.groupHunkIndexMap.isEmpty)
        XCTAssertNotNil(emptyDoc.note)
    }

    // MARK: - Helpers

    private func makeTempGitRepo() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-semantic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init", "-q"]
        initProc.currentDirectoryURL = dir
        try initProc.run()
        initProc.waitUntilExit()
        XCTAssertEqual(initProc.terminationStatus, 0)
        return dir
    }

    private func gitCommitAll(in repo: URL, message: String) async throws {
        _ = try await Git.run(["config", "user.email", "test@example.com"], in: repo)
        _ = try await Git.run(["config", "user.name", "Test User"], in: repo)
        _ = try await Git.run(["add", "-A"], in: repo)
        _ = try await Git.run(["commit", "-q", "-m", message], in: repo)
    }
}
