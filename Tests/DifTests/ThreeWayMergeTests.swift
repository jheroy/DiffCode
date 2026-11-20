import XCTest
@testable import DifKit

final class ThreeWayMergeTests: XCTestCase {
    private var tempRoot: URL?

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private func makeDoc(base: [String], left: [String], right: [String], path: String = "sample.swift") -> ThreeWayMergeDocument {
        let chunks = ThreeWayMergeEngine.compute(base: base, left: left, right: right)
        return ThreeWayMergeDocument(
            left: TextBuffer(lines: left),
            base: base,
            center: TextBuffer(lines: base),
            right: TextBuffer(lines: right),
            chunks: chunks,
            language: .detect(path: path),
            titles: ThreeWayMergeTitles(left: "Left", center: "Result", right: "Right")
        )
    }

    private var emptySelection: EditorSession.Selection {
        (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0))
    }

    // MARK: - ThreeWayMergeEngine

    func testEngineClassifiesNonConflictingIdenticalAndConflictChunks() {
        let base = [
            "line 1",
            "line 2",
            "line 3",
            "line 4",
            "line 5",
            "line 6",
            "line 7",
            "line 8",
            "line 9",
        ]
        let left = [
            "line 1 left",   // leftOnly modified
            "line 2",
            "line 3",
            "line 4 left",   // conflict modified
            "line 5",
            "line 6 same",   // bothIdentical modified
            "line 7",
            "line 8",
            "line 9",
        ]
        let right = [
            "line 1",
            "line 2",
            "line 3",
            "line 4 right",  // conflict modified
            "line 5",
            "line 6 same",   // bothIdentical modified
            "line 7",
            "line 8 right",  // rightOnly modified
            "line 9",
        ]

        let chunks = ThreeWayMergeEngine.compute(base: base, left: left, right: right)
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].kind, .leftOnly(.modified))
        XCTAssertEqual(chunks[1].kind, .conflict)
        XCTAssertEqual(chunks[2].kind, .bothIdentical(.modified))
        XCTAssertEqual(chunks[3].kind, .rightOnly(.modified))
    }

    func testEngineHandlesAdditionsDeletionsAndTouchingConflicts() {
        let base = ["a", "b", "c", "d", "e"]
        let left = ["a", "b-left", "c", "d", "e"]
        let right = ["a", "b", "c-right", "d", "e"]

        // Touching base ranges [1..<2] and [2..<3] merge into one conflict chunk.
        let touching = ThreeWayMergeEngine.compute(base: base, left: left, right: right)
        XCTAssertEqual(touching.count, 1)
        XCTAssertEqual(touching[0].kind, .conflict)
        XCTAssertEqual(touching[0].baseRange, 1..<3)
        XCTAssertEqual(touching[0].leftRange, 1..<3)
        XCTAssertEqual(touching[0].rightRange, 1..<3)

        // Independent pure insertion vs deletion far apart remain non-conflicting.
        let added = ThreeWayMergeEngine.compute(
            base: ["top", "mid", "bot"],
            left: ["top", "inserted", "mid", "bot"],
            right: ["top", "mid"]
        )
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added[0].kind, .leftOnly(.added))
        XCTAssertEqual(added[1].kind, .rightOnly(.deleted))
    }

    func testEngineHandlesBothAddedEmptyBase() {
        let chunks = ThreeWayMergeEngine.compute(
            base: [],
            left: ["common 1", "only left", "common 2"],
            right: ["common 1", "only right", "common 2"]
        )
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].kind, .bothIdentical(.added))
        XCTAssertEqual(chunks[1].kind, .conflict)
        XCTAssertEqual(chunks[2].kind, .bothIdentical(.added))
    }

    // MARK: - Non-Conflicting One-Click Merge & Side Filters

    func testApplyAllNonConflictingLeavesConflictsUntouchedAndSupportsSingleUndoRedo() {
        let base = [
            "header",
            "context 1",
            "conflict line",
            "context 2",
            "shared line",
            "context 3",
            "footer",
        ]
        let left = [
            "header left",
            "left extra",
            "context 1",
            "conflict left",
            "context 2",
            "shared merged",
            "context 3",
            "footer",
        ]
        let right = [
            "header",
            "context 1",
            "conflict right",
            "context 2",
            "shared merged",
            "context 3",
            "footer right",
        ]

        let doc = makeDoc(base: base, left: left, right: right)
        XCTAssertEqual(doc.unresolvedNonConflictCount, 3)
        XCTAssertEqual(doc.unresolvedConflictCount, 1)

        let applied = doc.applyAllNonConflicting(selection: emptySelection)
        XCTAssertEqual(applied, 3)
        XCTAssertEqual(doc.unresolvedNonConflictCount, 0)
        XCTAssertEqual(doc.unresolvedConflictCount, 1)
        XCTAssertEqual(doc.center.lines, [
            "header left",
            "left extra",
            "context 1",
            "conflict line",
            "context 2",
            "shared merged",
            "context 3",
            "footer right",
        ])

        // Undo reverts the entire batch in one step.
        XCTAssertNotNil(doc.undo())
        XCTAssertEqual(doc.center.lines, base)
        XCTAssertEqual(doc.unresolvedNonConflictCount, 3)
        XCTAssertEqual(doc.unresolvedConflictCount, 1)

        // Redo reapplies it in one step.
        XCTAssertNotNil(doc.redo())
        XCTAssertEqual(doc.center.lines, [
            "header left",
            "left extra",
            "context 1",
            "conflict line",
            "context 2",
            "shared merged",
            "context 3",
            "footer right",
        ])
        XCTAssertEqual(doc.unresolvedNonConflictCount, 0)
    }

    func testApplyNonConflictingSideFilter() {
        let base = ["a", "b", "c", "d", "e"]
        let left = ["a-L", "b", "c", "d", "e"]
        let right = ["a", "b", "c", "d", "e-R"]
        let doc = makeDoc(base: base, left: left, right: right)

        XCTAssertEqual(doc.applyAllNonConflicting(sideFilter: .left, selection: emptySelection), 1)
        XCTAssertEqual(doc.center.lines, ["a-L", "b", "c", "d", "e"])
        XCTAssertEqual(doc.unresolvedRightNonConflictCount, 1)

        XCTAssertEqual(doc.applyAllNonConflicting(sideFilter: .right, selection: emptySelection), 1)
        XCTAssertEqual(doc.center.lines, ["a-L", "b", "c", "d", "e-R"])
        XCTAssertEqual(doc.unresolvedNonConflictCount, 0)
    }

    // MARK: - GoLand 2-Step Bridge Actions & 1-Click Choices

    func testGoLandTwoStepConflictResolutionMatchesOrderAndIgnore() {
        let base = ["top", "baseLine", "bot"]
        let left = ["top", "leftLine", "bot"]
        let right = ["top", "rightLine", "bot"]

        // 1. Accept Left then Accept Right => Left + Right
        let docLR = makeDoc(base: base, left: left, right: right)
        XCTAssertTrue(docLR.acceptSide(.left, chunkIndex: 0, selection: emptySelection))
        XCTAssertTrue(docLR.chunks[0].isUnresolved, "right side remains unresolved for append or ignore")
        XCTAssertTrue(docLR.chunks[0].isAppendMode(for: .right))
        XCTAssertEqual(docLR.center.lines, ["top", "leftLine", "bot"])

        XCTAssertTrue(docLR.acceptSide(.right, chunkIndex: 0, selection: emptySelection))
        XCTAssertFalse(docLR.chunks[0].isUnresolved)
        XCTAssertEqual(docLR.chunks[0].acceptedOrder, [.left, .right])
        XCTAssertEqual(docLR.center.lines, ["top", "leftLine", "rightLine", "bot"])

        // 2. Accept Right then Accept Left => Right + Left
        let docRL = makeDoc(base: base, left: left, right: right)
        XCTAssertTrue(docRL.acceptSide(.right, chunkIndex: 0, selection: emptySelection))
        XCTAssertTrue(docRL.chunks[0].isAppendMode(for: .left))
        XCTAssertTrue(docRL.acceptSide(.left, chunkIndex: 0, selection: emptySelection))
        XCTAssertFalse(docRL.chunks[0].isUnresolved)
        XCTAssertEqual(docRL.chunks[0].acceptedOrder, [.right, .left])
        XCTAssertEqual(docRL.center.lines, ["top", "rightLine", "leftLine", "bot"])

        // 3. Accept Left then Ignore Right => Left only
        let docL = makeDoc(base: base, left: left, right: right)
        XCTAssertTrue(docL.acceptSide(.left, chunkIndex: 0, selection: emptySelection))
        XCTAssertTrue(docL.ignoreSide(.right, chunkIndex: 0, selection: emptySelection))
        XCTAssertFalse(docL.chunks[0].isUnresolved)
        XCTAssertEqual(docL.center.lines, ["top", "leftLine", "bot"])

        // 4. Ignore Left then Ignore Right => Keep Base
        let docBase = makeDoc(base: base, left: left, right: right)
        XCTAssertTrue(docBase.ignoreSide(.left, chunkIndex: 0, selection: emptySelection))
        XCTAssertTrue(docBase.ignoreSide(.right, chunkIndex: 0, selection: emptySelection))
        XCTAssertFalse(docBase.chunks[0].isUnresolved)
        XCTAssertEqual(docBase.center.lines, ["top", "baseLine", "bot"])
    }

    func testOneClickResolveConflictChoicesAndReset() {
        let base = ["a", "b0", "c"]
        let left = ["a", "b1", "c"]
        let right = ["a", "b2", "c"]
        let doc = makeDoc(base: base, left: left, right: right)

        XCTAssertTrue(doc.resolveConflict(0, choice: .acceptLeft, selection: emptySelection))
        XCTAssertEqual(doc.center.lines, ["a", "b1", "c"])

        XCTAssertTrue(doc.resolveConflict(0, choice: .acceptRight, selection: emptySelection))
        XCTAssertEqual(doc.center.lines, ["a", "b2", "c"])

        XCTAssertTrue(doc.resolveConflict(0, choice: .acceptBothLeftFirst, selection: emptySelection))
        XCTAssertEqual(doc.center.lines, ["a", "b1", "b2", "c"])

        XCTAssertTrue(doc.resolveConflict(0, choice: .acceptBothRightFirst, selection: emptySelection))
        XCTAssertEqual(doc.center.lines, ["a", "b2", "b1", "c"])

        XCTAssertTrue(doc.resolveConflict(0, choice: .keepBase, selection: emptySelection))
        XCTAssertEqual(doc.center.lines, ["a", "b0", "c"])
        XCTAssertEqual(doc.unresolvedConflictCount, 0)

        XCTAssertTrue(doc.resetToBase(selection: emptySelection))
        XCTAssertEqual(doc.unresolvedConflictCount, 1)
    }

    // MARK: - Direct Editing & 3-Pane Alignment

    func testDirectCenterEditingMaintainsChunkBoundsAndUndo() {
        let base = ["line0", "baseA", "line2", "baseB", "line4"]
        let left = ["line0", "leftA", "line2", "baseB", "line4"]
        let right = ["line0", "baseA", "line2", "rightB", "line4"]
        let doc = makeDoc(base: base, left: left, right: right)

        // Insert a new line before chunk 0; both chunk centerRanges should shift by +1 cleanly.
        _ = doc.replaceCenter(
            from: TextPosition(row: 0, column: 5),
            to: TextPosition(row: 0, column: 5),
            with: "\ninsertedBefore",
            kind: .typing,
            selection: emptySelection
        )
        XCTAssertEqual(doc.chunks[0].centerRange, 2..<3)
        XCTAssertEqual(doc.chunks[1].centerRange, 4..<5)
        XCTAssertFalse(doc.chunks[0].manuallyEdited)

        // Edit inside chunk 0; marks chunk 0 manuallyEdited and keeps later chunks monotonic.
        _ = doc.replaceCenter(
            from: TextPosition(row: 2, column: 0),
            to: TextPosition(row: 2, column: 5),
            with: "custom1\ncustom2",
            kind: .other,
            selection: emptySelection
        )
        XCTAssertEqual(doc.chunks[0].centerRange, 2..<4)
        XCTAssertTrue(doc.chunks[0].manuallyEdited)
        XCTAssertEqual(doc.chunks[1].centerRange, 5..<6)
        XCTAssertLessThanOrEqual(doc.chunks[0].centerRange.upperBound, doc.chunks[1].centerRange.lowerBound)

        XCTAssertNotNil(doc.undo())
        XCTAssertNotNil(doc.undo())
        XCTAssertEqual(doc.center.lines, base)
        XCTAssertEqual(doc.chunks[0].centerRange, 1..<2)
        XCTAssertEqual(doc.chunks[1].centerRange, 3..<4)
    }

    func testSynchronizedPanePositionsAcrossInsertedAndDeletedHunks() {
        let base = ["0", "1", "2", "3", "4"]
        let left = ["0", "L1", "L2", "L3", "2", "3", "4"]
        let right = ["0", "1", "2", "4"]
        let doc = makeDoc(base: base, left: left, right: right)

        XCTAssertGreaterThan(doc.virtualLineCount, base.count)
        let vChunk0 = Double(doc.virtualStart(ofChunk: 0))
        let p0 = doc.panePositions(forVirtual: vChunk0)
        XCTAssertEqual(p0.left, 1, accuracy: 0.001)
        XCTAssertEqual(p0.center, 1, accuracy: 0.001)
        XCTAssertEqual(p0.right, 1, accuracy: 0.001)

        // Row 2 ("2") is common across all 3 panes and maps identically from any pane.
        let vLeft2 = doc.virtualPosition(of: 4, pane: .left)
        let vCenter2 = doc.virtualPosition(of: 2, pane: .center)
        let vRight2 = doc.virtualPosition(of: 2, pane: .right)
        XCTAssertEqual(vLeft2, vCenter2, accuracy: 0.001)
        XCTAssertEqual(vCenter2, vRight2, accuracy: 0.001)
    }

    // MARK: - Real Git Repository Integration

    private func runGit(_ args: String..., in dir: URL, allowedExitCodes: Set<Int32> = [0]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = ["-c", "user.name=Dif Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false"] + args
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertTrue(allowedExitCodes.contains(p.terminationStatus), "git \(args.joined(separator: " ")) failed with \(p.terminationStatus)")
    }

    func testRealRepoMergeConflictLoadApplyAndMarkResolved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-3way-test-\(UUID().uuidString)")
        tempRoot = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try runGit("init", "-q", "-b", "main", in: root)
        let baseText = [
            "line1",
            "line2",
            "line3",
            "line4",
            "line5-conflict",
            "line6",
            "line7",
            "line8",
            "line9",
        ].joined(separator: "\n") + "\n"
        try Data(baseText.utf8).write(to: root.appendingPathComponent("app.txt"))
        try Data("will keep or delete\n".utf8).write(to: root.appendingPathComponent("moddel.txt"))
        try runGit("add", "-A", in: root)
        try runGit("commit", "-q", "-m", "base", in: root)

        try runGit("checkout", "-q", "-b", "feature", in: root)
        let featureText = [
            "line1",
            "line2",
            "line3",
            "line4",
            "line5-right",
            "line6",
            "line7",
            "line8-right-only",
            "line9",
        ].joined(separator: "\n") + "\n"
        try Data(featureText.utf8).write(to: root.appendingPathComponent("app.txt"))
        try runGit("rm", "-q", "moddel.txt", in: root)
        try runGit("add", "-A", in: root)
        try runGit("commit", "-q", "-m", "feature changes", in: root)

        try runGit("checkout", "-q", "main", in: root)
        let mainText = [
            "line1-left-only",
            "line2",
            "line3",
            "line4",
            "line5-left",
            "line6",
            "line7",
            "line8",
            "line9",
        ].joined(separator: "\n") + "\n"
        try Data(mainText.utf8).write(to: root.appendingPathComponent("app.txt"))
        try Data("modified on main\n".utf8).write(to: root.appendingPathComponent("moddel.txt"))
        try runGit("add", "-A", in: root)
        try runGit("commit", "-q", "-m", "main changes", in: root)

        // Trigger merge conflict (git merge returns exit code 1).
        try runGit("merge", "feature", in: root, allowedExitCodes: [0, 1])

        let gitDir = root.appendingPathComponent(".git")
        let statusBefore = try await Git.status(in: root, gitDirectory: gitDir)
        XCTAssertEqual(statusBefore.operation, .merge)
        XCTAssertEqual(Set(statusBefore.changes.filter { $0.kind == .conflicted }.map(\.path)), ["app.txt", "moddel.txt"])

        let appKind = await ThreeWayMergeLoader.load(
            path: "app.txt",
            in: root,
            operation: statusBefore.operation,
            branch: statusBefore.branch,
            gitDirectory: gitDir
        )
        guard case .text(let doc) = appKind else {
            return XCTFail("Expected text 3-way merge document for app.txt")
        }
        XCTAssertEqual(doc.titles.right, "feature")
        XCTAssertEqual(doc.unresolvedNonConflictCount, 2)
        XCTAssertEqual(doc.unresolvedConflictCount, 1)

        XCTAssertEqual(doc.applyAllNonConflicting(selection: emptySelection), 2)
        let conflictIdx = try XCTUnwrap(doc.chunks.firstIndex(where: \.isConflict))
        XCTAssertTrue(doc.acceptSide(.left, chunkIndex: conflictIdx, selection: emptySelection))
        XCTAssertTrue(doc.acceptSide(.right, chunkIndex: conflictIdx, selection: emptySelection))

        let encoded = try XCTUnwrap(doc.encodedCenterData())
        try encoded.write(to: root.appendingPathComponent("app.txt"), options: .atomic)
        try await Git.markResolved(["app.txt"], in: root)

        let written = String(decoding: encoded, as: UTF8.self)
        XCTAssertEqual(written, [
            "line1-left-only",
            "line2",
            "line3",
            "line4",
            "line5-left",
            "line5-right",
            "line6",
            "line7",
            "line8-right-only",
            "line9",
        ].joined(separator: "\n") + "\n")

        // Verify modify/delete conflict loading & resolution via Git.removeResolved.
        let modDelKind = await ThreeWayMergeLoader.load(
            path: "moddel.txt",
            in: root,
            operation: statusBefore.operation,
            branch: statusBefore.branch,
            gitDirectory: gitDir
        )
        guard case .deletedByRight(let preview, _) = modDelKind else {
            return XCTFail("Expected deletedByRight for moddel.txt")
        }
        XCTAssertTrue(preview?.contains("modified on main") == true)
        try await Git.removeResolved(["moddel.txt"], in: root)

        let statusAfter = try await Git.status(in: root)
        XCTAssertEqual(statusAfter.changes.filter { $0.kind == .conflicted }.count, 0)
    }
}
