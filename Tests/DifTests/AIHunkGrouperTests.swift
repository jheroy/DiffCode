import XCTest
@testable import DifKit

final class AIHunkGrouperTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? fm.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("dif-grouper-\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    @discardableResult
    private func runGit(_ args: [String], in root: URL) async throws -> String {
        try await Git.runString(args, in: root)
    }

    private func makeRepo() async throws -> URL {
        let root = try makeTempDir("repo")
        try await runGit(["init", "-q", "-b", "main"], in: root)
        try await runGit(["config", "user.name", "Dif Tests"], in: root)
        try await runGit(["config", "user.email", "tests@example.invalid"], in: root)
        try await runGit(["config", "commit.gpgsign", "false"], in: root)
        return root
    }

    private func writeFile(_ path: String, content: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    // MARK: - Working-Tree Hunk Collection

    func testCollectWorkingTreeHunksCoversModifiedMultiHunkUntrackedDeletedRenamedAndBinary() async throws {
        let root = try await makeRepo()
        let baseLines = (0..<15).map { "line\($0)" }
        try writeFile("multi.swift", content: baseLines.joined(separator: "\n") + "\n", in: root)
        try writeFile("remove_me.swift", content: "let obsolete = 1\nlet old2 = 2\n", in: root)
        try writeFile("old_name.swift", content: "let renamedOnly = true\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Initial"], in: root)

        // Two separated hunks in multi.swift
        var edited = baseLines
        edited[1] = "line1_updated"
        edited[13] = "line13_updated"
        try writeFile("multi.swift", content: edited.joined(separator: "\n") + "\n", in: root)

        // Untracked text file
        try writeFile("new_feature.swift", content: "func featureA() {}\n", in: root)

        // Deleted file
        try fm.removeItem(at: root.appendingPathComponent("remove_me.swift"))

        // Pure rename (0 line diffs -> fallback descriptor at hunkIndex 0)
        try await runGit(["mv", "old_name.swift", "new_name.swift"], in: root)

        // Binary untracked file (contains NUL bytes)
        let binaryURL = root.appendingPathComponent("icon.bin")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x01, 0x02]).write(to: binaryURL)

        let hunks = try await AIHunkGrouper.collectWorkingTreeHunks(repoRoot: root)

        let multiHunks = hunks.filter { $0.filePath == "multi.swift" }
        XCTAssertEqual(multiHunks.count, 2)
        XCTAssertEqual(multiHunks.map(\.hunkIndex), [0, 1])
        XCTAssertEqual(multiHunks.map(\.id), ["multi.swift#0", "multi.swift#1"])
        XCTAssertEqual(multiHunks[0].removedLines, ["line1"])
        XCTAssertEqual(multiHunks[0].addedLines, ["line1_updated"])
        XCTAssertEqual(multiHunks[1].removedLines, ["line13"])
        XCTAssertEqual(multiHunks[1].addedLines, ["line13_updated"])
        XCTAssertFalse(multiHunks[0].isFileLevelFallback)

        let untracked = try XCTUnwrap(hunks.first { $0.filePath == "new_feature.swift" })
        XCTAssertEqual(untracked.hunkIndex, 0)
        XCTAssertEqual(untracked.kind, .added)
        XCTAssertEqual(untracked.addedLines, ["func featureA() {}"])

        let deleted = try XCTUnwrap(hunks.first { $0.filePath == "remove_me.swift" })
        XCTAssertEqual(deleted.hunkIndex, 0)
        XCTAssertEqual(deleted.kind, .deleted)
        XCTAssertEqual(deleted.removedLines, ["let obsolete = 1", "let old2 = 2"])

        let renamed = try XCTUnwrap(hunks.first { $0.filePath == "new_name.swift" })
        XCTAssertEqual(renamed.hunkIndex, 0)
        XCTAssertEqual(renamed.oldPath, "old_name.swift")
        XCTAssertTrue(renamed.isFileLevelFallback)

        let binary = try XCTUnwrap(hunks.first { $0.filePath == "icon.bin" })
        XCTAssertEqual(binary.hunkIndex, 0)
        XCTAssertTrue(binary.isFileLevelFallback)
        XCTAssertTrue(binary.header.contains("binary"))
    }

    // MARK: - Prompt Budget & Schema Validity

    func testBuildPromptPreservesAllHunkIDsUnderTightBudget() {
        var hunks: [HunkDescriptor] = []
        let bigLines = (0..<80).map { "let veryLongSwiftIdentifierName_\($0) = \"some payload content\"" }
        for i in 0..<12 {
            hunks.append(HunkDescriptor(
                filePath: "Sources/Module\(i)/File\(i).swift",
                hunkIndex: i % 3,
                kind: .modified,
                oldStart: 10,
                oldCount: 2,
                newStart: 10,
                newCount: bigLines.count,
                header: "@@ -11,2 +11,\(bigLines.count) @@",
                addedLines: bigLines,
                removedLines: ["let oldA = 1", "let oldB = 2"]
            ))
        }

        let prompt = AIHunkGrouper.buildPrompt(hunks: hunks, maxDiffBytes: 2048)
        for hunk in hunks {
            XCTAssertTrue(prompt.contains(hunk.id), "Prompt must retain header/ID for \(hunk.id)")
            XCTAssertTrue(prompt.contains(hunk.header), "Prompt must retain line range header for \(hunk.id)")
        }
        XCTAssertTrue(prompt.contains("truncated"))
        XCTAssertLessThan(prompt.utf8.count, 8192)
    }

    func testResponseJSONSchemaIsValidStrictJSON() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(AIHunkGrouper.responseJSONSchema.utf8), options: [])
        let dict = try XCTUnwrap(obj as? [String: Any])
        XCTAssertEqual(dict["type"] as? String, "object")
        XCTAssertEqual(dict["additionalProperties"] as? Bool, false)
    }

    // MARK: - Tolerant JSON Parsing, Validation, Deduplication & Fallback Coverage

    private func sampleValidHunks() -> [HunkDescriptor] {
        [
            HunkDescriptor(filePath: "Sources/Auth.swift", hunkIndex: 0, kind: .modified, oldStart: 0, oldCount: 1, newStart: 0, newCount: 2, header: "@@ -1,1 +1,2 @@", addedLines: ["+a"], removedLines: ["-a"]),
            HunkDescriptor(filePath: "Sources/Auth.swift", hunkIndex: 1, kind: .added, oldStart: 20, oldCount: 0, newStart: 21, newCount: 3, header: "@@ -20,0 +22,3 @@", addedLines: ["+b"], removedLines: []),
            HunkDescriptor(filePath: "Sources/UI.swift", hunkIndex: 0, kind: .modified, oldStart: 5, oldCount: 1, newStart: 5, newCount: 1, header: "@@ -6,1 +6,1 @@", addedLines: ["+c"], removedLines: ["-c"]),
            HunkDescriptor(filePath: "Tests/AuthTests.swift", hunkIndex: 0, kind: .added, oldStart: 0, oldCount: 0, newStart: 0, newCount: 10, header: "@@ -0,0 +1,10 @@", addedLines: ["+t"], removedLines: []),
        ]
    }

    func testParseGroupingResponseStripsCodeFencesAndSurroundingProse() throws {
        let valid = sampleValidHunks()
        let raw = """
        好的，我已经帮你把改动按功能分成两组：
        ```json
        {
          "groups": [
            {
              "name": "认证核心逻辑与测试",
              "summary": "更新认证流程（包含 {大括号} 示例）并补充单元测试。",
              "files": [
                {"path": "Sources/Auth.swift", "hunkIndices": [1, 0]},
                {"path": "Tests/AuthTests.swift", "hunkIndices": [0]}
              ]
            },
            {
              "name": "界面样式调整",
              "summary": "微调 UI 布局展示。",
              "files": [
                {"path": "Sources/UI.swift", "hunkIndices": [0]}
              ]
            }
          ]
        }
        ```
        希望这有助于你逐组评审！
        """

        let result = try AIHunkGrouper.parseGroupingResponse(raw, validHunks: valid, provider: .agy, model: "gemini-4")
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.totalHunks, 4)
        XCTAssertEqual(result.totalFiles, 3)
        XCTAssertEqual(result.provider, .agy)
        XCTAssertEqual(result.model, "gemini-4")
        XCTAssertEqual(result.groups[0].name, "认证核心逻辑与测试")
        XCTAssertEqual(result.groups[0].files[0].hunkIndices, [0, 1], "Indices should be sorted ascending")
        XCTAssertEqual(result.groups[0].hunkCount, 3)
        XCTAssertEqual(result.groups[1].hunkCount, 1)
    }

    func testParseGroupingResponseDeduplicatesDropsInvalidAndAppendsFallbackForMissedHunks() throws {
        let valid = sampleValidHunks()
        let raw = """
        Here is the JSON:
        {
          "groups": [
            {
              "name": "认证改动",
              "summary": "修改认证逻辑",
              "files": [
                {"path": "Sources/Auth.swift", "hunkIndices": [0, 99, -1]},
                {"path": "Sources/Hallucinated.swift", "hunkIndices": [0]}
              ]
            },
            {
              "name": "重复与无效组",
              "summary": "全部重复或无效，应被丢弃",
              "files": [
                {"path": "Sources/Auth.swift", "hunkIndices": [0]},
                {"path": "DoesNotExist.swift", "hunkIndices": [0]}
              ]
            }
          ]
        }
        """

        let result = try AIHunkGrouper.parseGroupingResponse(raw, validHunks: valid, provider: .claude, model: "sonnet")
        // Group 1 keeps Auth.swift#0; Group 2 becomes empty and is dropped; Fallback captures Auth.swift#1, UI.swift#0, AuthTests.swift#0.
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].name, "认证改动")
        XCTAssertEqual(result.groups[0].files, [AIHunkGroupFile(path: "Sources/Auth.swift", hunkIndices: [0])])

        let fallback = result.groups[1]
        XCTAssertEqual(fallback.name, AIHunkGrouper.fallbackGroupName)
        XCTAssertEqual(fallback.files, [
            AIHunkGroupFile(path: "Sources/Auth.swift", hunkIndices: [1]),
            AIHunkGroupFile(path: "Sources/UI.swift", hunkIndices: [0]),
            AIHunkGroupFile(path: "Tests/AuthTests.swift", hunkIndices: [0]),
        ])

        // 100% coverage & zero duplicates
        let allAssigned = result.groups.flatMap { group in
            group.files.flatMap { file in file.hunkIndices.map { "\(file.path)#\($0)" } }
        }
        XCTAssertEqual(Set(allAssigned), Set(valid.map(\.id)))
        XCTAssertEqual(allAssigned.count, valid.count)
    }

    func testParseGroupingResponseRejectsGarbageText() {
        let valid = sampleValidHunks()
        XCTAssertThrowsError(try AIHunkGrouper.parseGroupingResponse("Sorry, I cannot help with that.", validHunks: valid)) { error in
            guard case AIHunkGroupingError.invalidJSONResponse = error else {
                XCTFail("Expected invalidJSONResponse, got \(error)")
                return
            }
        }
    }

    // MARK: - End-to-End Grouping with Mock Agent & AppStore Gate

    func testGenerateGroupsEndToEndWithMockACPAgent() async throws {
        let repo = try await makeRepo()
        try writeFile("a.swift", content: "let a = 1\n", in: repo)
        try writeFile("b.swift", content: "let b = 1\n", in: repo)
        try await runGit(["add", "-A"], in: repo)
        try await runGit(["commit", "-q", "-m", "Init"], in: repo)

        try writeFile("a.swift", content: "let a = 2\n", in: repo)
        try writeFile("b.swift", content: "let b = 2\n", in: repo)

        let binDir = try makeTempDir("mock-bin")
        let agyURL = binDir.appendingPathComponent("agy")
        let mockScript = """
        #!/usr/bin/env python3
        import json, sys

        def emit(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for raw in sys.stdin:
            msg = json.loads(raw)
            m = msg.get("method")
            i = msg.get("id")
            if m == "initialize":
                emit({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":1}})
            elif m == "session/new":
                emit({"jsonrpc":"2.0","id":i,"result":{"sessionId":"s1"}})
            elif m == "session/prompt":
                payload = json.dumps({
                    "groups": [
                        {"name": "模块 A 更新", "summary": "更新变量 a 的值", "files": [{"path": "a.swift", "hunkIndices": [0]}]}
                    ]
                }, ensure_ascii=False)
                emit({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":payload}}}})
                emit({"jsonrpc":"2.0","id":i,"result":{"stopReason":"end_turn"}})
            elif m == "session/close":
                emit({"jsonrpc":"2.0","id":i,"result":{}})
                break
        """
        try Data(mockScript.utf8).write(to: agyURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

        let service = LocalAgentService(searchPaths: [binDir.path], environment: ProcessInfo.processInfo.environment)
        let result = try await AIHunkGrouper.generateGroups(
            repoRoot: repo,
            provider: .agy,
            service: service
        )

        XCTAssertEqual(result.totalHunks, 2)
        XCTAssertEqual(result.totalFiles, 2)
        XCTAssertEqual(result.groups.count, 2)
        XCTAssertEqual(result.groups[0].name, "模块 A 更新")
        XCTAssertEqual(result.groups[1].name, AIHunkGrouper.fallbackGroupName)
        XCTAssertEqual(result.groups[1].files, [AIHunkGroupFile(path: "b.swift", hunkIndices: [0])])
    }

    func testGenerateGroupsRejectsCleanRepoAndAppStoreEdition() async throws {
        let repo = try await makeRepo()
        do {
            _ = try await AIHunkGrouper.generateGroups(repoRoot: repo)
            XCTFail("Expected noChangesToGroup")
        } catch let error as AIHunkGroupingError {
            XCTAssertEqual(error, .noChangesToGroup)
        }

        let previous = AppEnvironment.edition
        AppEnvironment.edition = .appStore
        defer { AppEnvironment.edition = previous }

        do {
            _ = try await AIHunkGrouper.generateGroups(repoRoot: repo)
            XCTFail("Expected unavailableInAppStore")
        } catch let error as AIHunkGroupingError {
            XCTAssertEqual(error, .unavailableInAppStore)
        }
    }

    // MARK: - Direct Group Commit Helpers & End-to-End Partial Commit

    func testDefaultCommitMessageFormatting() {
        let withSummary = AIHunkGroup(
            name: "  新增分组直接提交能力  ",
            summary: "  支持直接使用分组名与描述提交，或按分组差异重新生成提交信息。  ",
            files: []
        )
        XCTAssertEqual(
            AIHunkGrouper.defaultCommitMessage(for: withSummary),
            "新增分组直接提交能力\n\n支持直接使用分组名与描述提交，或按分组差异重新生成提交信息。"
        )

        let emptySummary = AIHunkGroup(
            name: "修复边界问题",
            summary: "   \n  ",
            files: []
        )
        XCTAssertEqual(AIHunkGrouper.defaultCommitMessage(for: emptySummary), "修复边界问题")

        let duplicateSummary = AIHunkGroup(
            name: "优化布局性能",
            summary: "  优化布局性能  ",
            files: []
        )
        XCTAssertEqual(AIHunkGrouper.defaultCommitMessage(for: duplicateSummary), "优化布局性能")
    }

    func testResultAfterCommittingRemovesGroupAndShiftsSharedFileHunkIndices() {
        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "提交 0 和 2 号 hunk",
            files: [AIHunkGroupFile(path: "shared.swift", hunkIndices: [0, 2])]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "保留 1 和 3 号 hunk",
            files: [AIHunkGroupFile(path: "shared.swift", hunkIndices: [1, 3])]
        )
        let groupC = AIHunkGroup(
            name: "分组 C",
            summary: "独立文件改动",
            files: [AIHunkGroupFile(path: "other.swift", hunkIndices: [0])]
        )

        let initial = AIHunkGroupingResult(
            groups: [groupA, groupB, groupC],
            totalHunks: 5,
            totalFiles: 2,
            provider: .agy,
            model: "gemini-4",
            generatedAt: Date()
        )

        let afterA = AIHunkGrouper.resultAfterCommitting(groupID: groupA.id, in: initial)
        XCTAssertNotNil(afterA)
        XCTAssertEqual(afterA?.groups.count, 2)
        XCTAssertEqual(afterA?.groups[0].id, groupB.id)
        XCTAssertEqual(afterA?.groups[0].files, [AIHunkGroupFile(path: "shared.swift", hunkIndices: [0, 1])])
        XCTAssertEqual(afterA?.groups[1].id, groupC.id)
        XCTAssertEqual(afterA?.groups[1].files, [AIHunkGroupFile(path: "other.swift", hunkIndices: [0])])
        XCTAssertEqual(afterA?.totalHunks, 3)
        XCTAssertEqual(afterA?.totalFiles, 2)

        let afterB = afterA.flatMap { AIHunkGrouper.resultAfterCommitting(groupID: groupB.id, in: $0) }
        XCTAssertEqual(afterB?.groups.count, 1)
        XCTAssertEqual(afterB?.groups[0].id, groupC.id)
        XCTAssertEqual(afterB?.totalHunks, 1)
        XCTAssertEqual(afterB?.totalFiles, 1)

        let afterC = afterB.flatMap { AIHunkGrouper.resultAfterCommitting(groupID: groupC.id, in: $0) }
        XCTAssertNil(afterC)
    }

    func testBuildCommitSelectionAndPartialGroupCommitEndToEnd() async throws {
        let repo = try await makeRepo()
        let baseLines = (0..<15).map { "line\($0)" }
        try writeFile("multi.swift", content: baseLines.joined(separator: "\n") + "\n", in: repo)
        try writeFile("only_b.swift", content: "let bValue = 1\n", in: repo)
        try await runGit(["add", "-A"], in: repo)
        try await runGit(["commit", "-q", "-m", "Initial commit"], in: repo)

        // Two separated hunks in multi.swift: hunk 0 belongs to Group A, hunk 1 belongs to Group B.
        var edited = baseLines
        edited[1] = "line1_group_a"
        edited[13] = "line13_group_b"
        try writeFile("multi.swift", content: edited.joined(separator: "\n") + "\n", in: repo)

        // File exclusive to Group A (untracked) and file exclusive to Group B (modified).
        try writeFile("only_a.swift", content: "let aFeature = true\n", in: repo)
        try writeFile("only_b.swift", content: "let bValue = 2\n", in: repo)

        let statusBefore = try await Git.status(in: repo)
        let groupA = AIHunkGroup(
            name: "功能 A 更新",
            summary: "更新 multi.swift 顶部逻辑并新增 only_a.swift",
            files: [
                AIHunkGroupFile(path: "multi.swift", hunkIndices: [0]),
                AIHunkGroupFile(path: "only_a.swift", hunkIndices: [0]),
            ]
        )
        let groupB = AIHunkGroup(
            name: "功能 B 更新",
            summary: "更新 multi.swift 底部逻辑与 only_b.swift",
            files: [
                AIHunkGroupFile(path: "multi.swift", hunkIndices: [1]),
                AIHunkGroupFile(path: "only_b.swift", hunkIndices: [0]),
            ]
        )
        let groupingResult = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 4,
            totalFiles: 3,
            provider: .agy,
            model: nil,
            generatedAt: Date()
        )

        // 1. Build commit selection for Group A only.
        let selectionA = try await AIHunkGrouper.buildCommitSelection(
            for: groupA,
            allChanges: statusBefore.changes,
            repoRoot: repo,
            isInitial: statusBefore.isInitial
        )
        XCTAssertEqual(selectionA.files.map(\.path), ["multi.swift", "only_a.swift"])
        XCTAssertNil(selectionA.excludedLines["only_a.swift"])
        let excludedMulti = try XCTUnwrap(selectionA.excludedLines["multi.swift"])
        XCTAssertTrue(excludedMulti.contains(ChangeLine(removed: true, line: 13, text: "line13")))
        XCTAssertTrue(excludedMulti.contains(ChangeLine(removed: false, line: 13, text: "line13_group_b")))
        XCTAssertFalse(excludedMulti.contains(ChangeLine(removed: true, line: 1, text: "line1")))
        XCTAssertFalse(excludedMulti.contains(ChangeLine(removed: false, line: 1, text: "line1_group_a")))

        // Verify AI commit diff payload sees ONLY Group A's changes.
        let checkedPayloadA = try await AICommitGenerator.collectCheckedDiff(
            changes: selectionA.files,
            excludedLines: selectionA.excludedLines,
            in: repo,
            isInitial: statusBefore.isInitial
        )
        XCTAssertTrue(checkedPayloadA.diff.contains("line1_group_a"))
        XCTAssertTrue(checkedPayloadA.diff.contains("only_a.swift"))
        XCTAssertFalse(checkedPayloadA.diff.contains("line13_group_b"))
        XCTAssertFalse(checkedPayloadA.diff.contains("only_b.swift"))

        // 2. Commit Group A using WorkingTree.commit.
        let partialA = selectionA.files.compactMap { change in
            selectionA.excludedLines[change.path].flatMap {
                $0.isEmpty ? nil : WorkingTree.PartialFile(change: change, excluded: $0)
            }
        }
        let wholeA = selectionA.files.filter { selectionA.excludedLines[$0.path]?.isEmpty != false }
        XCTAssertEqual(wholeA.map(\.path), ["only_a.swift"])
        XCTAssertEqual(partialA.map(\.change.path), ["multi.swift"])

        let commitMessageA = AIHunkGrouper.defaultCommitMessage(for: groupA)
        let commitResultA = try await WorkingTree.commit(
            message: commitMessageA,
            whole: wholeA,
            partial: partialA,
            amend: false,
            in: repo
        )

        // Verify HEAD commit contains ONLY Group A's changes and exact message.
        let committedMsgA = await Git.commitBody(commitResultA.hash, in: repo)
        XCTAssertEqual(committedMsgA.trimmingCharacters(in: .whitespacesAndNewlines), commitMessageA)

        let headMultiBlob = await Git.blob(rev: "HEAD", path: "multi.swift", in: repo)
        let headMultiData = try XCTUnwrap(headMultiBlob)
        let headMultiText = String(decoding: headMultiData, as: UTF8.self)
        XCTAssertTrue(headMultiText.contains("line1_group_a"))
        XCTAssertTrue(headMultiText.contains("line13\n"))
        XCTAssertFalse(headMultiText.contains("line13_group_b"))

        let headOnlyABlob = await Git.blob(rev: "HEAD", path: "only_a.swift", in: repo)
        let headOnlyAData = try XCTUnwrap(headOnlyABlob)
        XCTAssertEqual(String(decoding: headOnlyAData, as: UTF8.self), "let aFeature = true\n")

        let headOnlyBBlob = await Git.blob(rev: "HEAD", path: "only_b.swift", in: repo)
        let headOnlyBData = try XCTUnwrap(headOnlyBBlob)
        XCTAssertEqual(String(decoding: headOnlyBData, as: UTF8.self), "let bValue = 1\n")

        // Verify working tree now has ONLY Group B's hunks (with multi.swift shifted to hunkIndex 0).
        let remainingHunks = try await AIHunkGrouper.collectWorkingTreeHunks(repoRoot: repo)
        XCTAssertEqual(remainingHunks.count, 2)
        let remMulti = try XCTUnwrap(remainingHunks.first { $0.filePath == "multi.swift" })
        XCTAssertEqual(remMulti.hunkIndex, 0)
        XCTAssertEqual(remMulti.removedLines, ["line13"])
        XCTAssertEqual(remMulti.addedLines, ["line13_group_b"])
        let remOnlyB = try XCTUnwrap(remainingHunks.first { $0.filePath == "only_b.swift" })
        XCTAssertEqual(remOnlyB.hunkIndex, 0)

        // 3. Recompute remaining groups and commit shifted Group B -> working tree becomes completely clean.
        let remainingResult = try XCTUnwrap(AIHunkGrouper.resultAfterCommitting(groupID: groupA.id, in: groupingResult))
        XCTAssertEqual(remainingResult.groups.count, 1)
        let shiftedGroupB = remainingResult.groups[0]
        XCTAssertEqual(shiftedGroupB.id, groupB.id)
        XCTAssertEqual(shiftedGroupB.files, [
            AIHunkGroupFile(path: "multi.swift", hunkIndices: [0]),
            AIHunkGroupFile(path: "only_b.swift", hunkIndices: [0]),
        ])

        let statusAfterA = try await Git.status(in: repo)
        let selectionB = try await AIHunkGrouper.buildCommitSelection(
            for: shiftedGroupB,
            allChanges: statusAfterA.changes,
            repoRoot: repo,
            isInitial: statusAfterA.isInitial
        )
        XCTAssertEqual(selectionB.files.map(\.path), ["multi.swift", "only_b.swift"])
        XCTAssertTrue(selectionB.excludedLines.isEmpty, "All remaining hunks of multi.swift belong to Group B")

        _ = try await WorkingTree.commit(
            message: AIHunkGrouper.defaultCommitMessage(for: shiftedGroupB),
            changes: selectionB.files,
            amend: false,
            in: repo
        )

        let statusAfterB = try await Git.status(in: repo)
        XCTAssertTrue(statusAfterB.changes.isEmpty)
        XCTAssertNil(AIHunkGrouper.resultAfterCommitting(groupID: shiftedGroupB.id, in: remainingResult))
    }

    // MARK: - Deletion, File-Removal Helpers & Persistence Storage

    func testResultAfterDeletingRemovesGroupWithoutShiftingIndices() {
        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "保留 0 和 2 号 hunk",
            files: [AIHunkGroupFile(path: "shared.swift", hunkIndices: [0, 2])]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "保留 1 和 3 号 hunk",
            files: [AIHunkGroupFile(path: "shared.swift", hunkIndices: [1, 3])]
        )
        let result = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 4,
            totalFiles: 1,
            provider: .agy,
            model: "gemini-4",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let afterDeleteA = AIHunkGrouper.resultAfterDeleting(groupID: groupA.id, in: result)
        XCTAssertNotNil(afterDeleteA)
        XCTAssertEqual(afterDeleteA?.groups.count, 1)
        XCTAssertEqual(afterDeleteA?.groups[0].id, groupB.id)
        XCTAssertEqual(
            afterDeleteA?.groups[0].files,
            [AIHunkGroupFile(path: "shared.swift", hunkIndices: [1, 3])],
            "Deleting a group must not shift hunk indices of remaining groups"
        )
        XCTAssertEqual(afterDeleteA?.totalHunks, 2)
        XCTAssertEqual(afterDeleteA?.totalFiles, 1)

        XCTAssertNil(afterDeleteA.flatMap { AIHunkGrouper.resultAfterDeleting(groupID: groupB.id, in: $0) })
    }

    func testResultAfterRemovingFilesDropsEmptiedGroupsAndUpdatesTotals() {
        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "仅含已提交文件",
            files: [AIHunkGroupFile(path: "committed.swift", hunkIndices: [0, 1])]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "跨文件改动",
            files: [
                AIHunkGroupFile(path: "committed.swift", hunkIndices: [2]),
                AIHunkGroupFile(path: "kept.swift", hunkIndices: [0, 2]),
            ]
        )
        let result = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 5,
            totalFiles: 2,
            provider: .claude,
            model: "sonnet",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let afterEmpty = AIHunkGrouper.resultAfterRemovingFiles([], in: result)
        XCTAssertEqual(afterEmpty, result)

        let afterRemovingCommitted = AIHunkGrouper.resultAfterRemovingFiles(["committed.swift"], in: result)
        XCTAssertEqual(afterRemovingCommitted?.groups.count, 1)
        XCTAssertEqual(afterRemovingCommitted?.groups[0].id, groupB.id)
        XCTAssertEqual(afterRemovingCommitted?.groups[0].files, [AIHunkGroupFile(path: "kept.swift", hunkIndices: [0, 2])])
        XCTAssertEqual(afterRemovingCommitted?.totalHunks, 2)
        XCTAssertEqual(afterRemovingCommitted?.totalFiles, 1)

        XCTAssertNil(AIHunkGrouper.resultAfterRemovingFiles(["committed.swift", "kept.swift"], in: result))
    }

    func testAIGroupStorageSaveLoadDeleteSymlinkAndCorruptionResilience() throws {
        let dir = try makeTempDir("storage")
        let storageFile = dir.appendingPathComponent("nested/ai-groups.json")

        let realRepo = dir.appendingPathComponent("real-repo")
        try fm.createDirectory(at: realRepo, withIntermediateDirectories: true)
        let linkRepo = dir.appendingPathComponent("link-repo")
        try fm.createSymbolicLink(at: linkRepo, withDestinationURL: realRepo)

        let group = AIHunkGroup(
            name: "持久化测试分组",
            summary: "验证读写与删除",
            files: [AIHunkGroupFile(path: "Sources/App.swift", hunkIndices: [0, 2])]
        )
        let state = PersistedAIGroupState(
            result: AIHunkGroupingResult(
                groups: [group],
                totalHunks: 2,
                totalFiles: 1,
                provider: .codex,
                model: "gpt-6-luna",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_123)
            ),
            selectedGroupID: group.id,
            selectedGroupFilePath: "Sources/App.swift",
            selectedGroupHunkIndex: 2,
            groupCommitMessages: [group.id.uuidString: "feat: custom message"],
            headOID: "deadbeef"
        )

        let writer = AIGroupStorage(fileURL: storageFile)
        writer.save(state, for: realRepo)
        XCTAssertTrue(fm.fileExists(atPath: storageFile.path))

        // Fresh storage instance reads via symlinked repo URL.
        let reader = AIGroupStorage(fileURL: storageFile)
        XCTAssertEqual(reader.load(for: linkRepo), state)
        XCTAssertEqual(reader.allKeys().count, 1)

        // Empty-groups guard deletes record and backing file.
        let emptyState = PersistedAIGroupState(
            result: AIHunkGroupingResult(
                groups: [],
                totalHunks: 0,
                totalFiles: 0,
                provider: .codex,
                model: nil,
                generatedAt: Date(timeIntervalSince1970: 1_700_000_123)
            )
        )
        reader.save(emptyState, for: realRepo)
        XCTAssertNil(reader.load(for: realRepo))
        XCTAssertFalse(fm.fileExists(atPath: storageFile.path))

        // Corrupted JSON falls back cleanly without crashing.
        try fm.createDirectory(at: storageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{corrupted-json".utf8).write(to: storageFile)
        let corruptedReader = AIGroupStorage(fileURL: storageFile)
        XCTAssertNil(corruptedReader.load(for: realRepo))
        XCTAssertTrue(corruptedReader.allKeys().isEmpty)
    }

    @MainActor
    func testProjectPersistedAIGroupStateRoundTripAndValidation() throws {
        let dir = try makeTempDir("project-state")
        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "摘要 A",
            files: [AIHunkGroupFile(path: "a.swift", hunkIndices: [0, 3])]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "摘要 B",
            files: [AIHunkGroupFile(path: "b.swift", hunkIndices: [1, 2])]
        )
        let result = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 4,
            totalFiles: 2,
            provider: .agy,
            model: "gemini-4",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )

        let sourceProject = Project(url: dir)
        sourceProject.aiGroupResult = result
        sourceProject.selectedGroupID = groupB.id
        sourceProject.selectedGroupFilePath = "b.swift"
        sourceProject.selectedGroupRowID = ChangeRow.fileID("b.swift")
        sourceProject.selectedGroupHunkIndex = 2
        sourceProject.setCommitMessage(AIHunkGrouper.defaultCommitMessage(for: groupA), for: groupA)
        sourceProject.setCommitMessage("custom commit draft B", for: groupB)
        let staleID = UUID()
        sourceProject.groupCommitMessages[staleID] = "stale draft"

        let snapshot = try XCTUnwrap(sourceProject.persistedAIGroupState(headOIDOverride: "abc1234"))
        XCTAssertEqual(snapshot.headOID, "abc1234")
        XCTAssertEqual(snapshot.groupCommitMessages, [groupB.id.uuidString: "custom commit draft B"])

        let restoredProject = Project(url: dir)
        restoredProject.restoreAIGroupState(snapshot)
        XCTAssertEqual(restoredProject.aiGroupResult, result)
        XCTAssertEqual(restoredProject.selectedGroupID, groupB.id)
        XCTAssertEqual(restoredProject.selectedGroupFilePath, "b.swift")
        XCTAssertEqual(restoredProject.selectedGroupRowID, ChangeRow.fileID("b.swift"))
        XCTAssertEqual(restoredProject.selectedGroupHunkIndex, 2)
        XCTAssertEqual(restoredProject.commitMessage(for: groupB), "custom commit draft B")
        XCTAssertEqual(restoredProject.commitMessage(for: groupA), AIHunkGrouper.defaultCommitMessage(for: groupA))
        XCTAssertNil(restoredProject.groupCommitMessages[staleID])

        // Invalid selection fields fall back cleanly to valid group/file/hunk.
        let invalidSelectionState = PersistedAIGroupState(
            result: result,
            selectedGroupID: UUID(),
            selectedGroupFilePath: "missing.swift",
            selectedGroupHunkIndex: 99,
            groupCommitMessages: [groupA.id.uuidString: AIHunkGrouper.defaultCommitMessage(for: groupA)]
        )
        let fallbackProject = Project(url: dir)
        fallbackProject.restoreAIGroupState(invalidSelectionState)
        XCTAssertEqual(fallbackProject.selectedGroupID, groupA.id)
        XCTAssertEqual(fallbackProject.selectedGroupFilePath, "a.swift")
        XCTAssertEqual(fallbackProject.selectedGroupRowID, ChangeRow.fileID("a.swift"))
        XCTAssertEqual(fallbackProject.selectedGroupHunkIndex, 0)
        XCTAssertTrue(fallbackProject.groupCommitMessages.isEmpty)
    }
}
