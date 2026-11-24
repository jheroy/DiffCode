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
        XCTAssertEqual(result.groups[0].files, [
            AIHunkGroupFile(
                path: "Sources/Auth.swift",
                hunkIndices: [0],
                coversWholeFile: false,
                hunkSpans: [AIHunkSpan(oldStart: 0, oldCount: 1, newStart: 0, newCount: 2)]
            ),
        ])

        let fallback = result.groups[1]
        XCTAssertEqual(fallback.name, AIHunkGrouper.fallbackGroupName)
        XCTAssertEqual(fallback.files, [
            AIHunkGroupFile(
                path: "Sources/Auth.swift",
                hunkIndices: [1],
                coversWholeFile: false,
                hunkSpans: [AIHunkSpan(oldStart: 20, oldCount: 0, newStart: 21, newCount: 3)]
            ),
            AIHunkGroupFile(path: "Sources/UI.swift", hunkIndices: [0], coversWholeFile: true, hunkSpans: nil),
            AIHunkGroupFile(path: "Tests/AuthTests.swift", hunkIndices: [0], coversWholeFile: true, hunkSpans: nil),
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
        XCTAssertEqual(result.groups[1].files, [
            AIHunkGroupFile(path: "b.swift", hunkIndices: [0], coversWholeFile: true, hunkSpans: nil),
        ])
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
        let sessionWT = AIGroupSession(
            source: .workingTree,
            result: AIHunkGroupingResult(
                groups: [group],
                totalHunks: 2,
                totalFiles: 1,
                provider: .codex,
                model: "gpt-6-luna",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_123)
            ),
            files: [FileChange(path: "Sources/App.swift", oldPath: nil, kind: .modified)],
            selectedGroupID: group.id,
            selectedGroupFilePath: "Sources/App.swift",
            selectedGroupHunkIndex: 2,
            groupCommitMessages: [group.id.uuidString: "feat: custom message"],
            headOID: "deadbeef"
        )
        let compareGroup = AIHunkGroup(
            name: "对比分组",
            summary: "分支对比改动",
            files: [AIHunkGroupFile(path: "Sources/Other.swift", hunkIndices: [0])]
        )
        let sessionComp = AIGroupSession(
            source: .comparison(.init(
                title: "main",
                baseHash: "1111111111111111111111111111111111111111",
                targetRef: "refs/heads/main",
                forkPoint: false,
                headTitle: nil,
                headHash: nil,
                stashUntrackedHash: nil,
                isStash: false
            )),
            result: AIHunkGroupingResult(
                groups: [compareGroup],
                totalHunks: 1,
                totalFiles: 1,
                provider: .agy,
                model: "gemini-4",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_200)
            ),
            files: [FileChange(path: "Sources/Other.swift", oldPath: nil, kind: .modified)],
            selectedGroupID: compareGroup.id,
            selectedGroupFilePath: "Sources/Other.swift",
            selectedGroupHunkIndex: 0
        )
        let state = PersistedAIGroupState(
            sessions: [sessionWT, sessionComp],
            activeSessionID: sessionComp.id
        )

        let writer = AIGroupStorage(fileURL: storageFile)
        writer.save(state, for: realRepo)
        XCTAssertTrue(fm.fileExists(atPath: storageFile.path))

        // Fresh storage instance reads via symlinked repo URL.
        let reader = AIGroupStorage(fileURL: storageFile)
        XCTAssertEqual(reader.load(for: linkRepo), state)
        XCTAssertEqual(reader.allKeys().count, 1)

        // Removing one session keeps the other intact.
        reader.save(PersistedAIGroupState(sessions: [sessionComp], activeSessionID: sessionComp.id), for: realRepo)
        let remaining = try XCTUnwrap(reader.load(for: realRepo))
        XCTAssertEqual(remaining.sessions.count, 1)
        XCTAssertEqual(remaining.sessions[0].id, sessionComp.id)

        // Empty-sessions guard deletes record and backing file.
        let emptyState = PersistedAIGroupState(sessions: [], activeSessionID: nil)
        reader.save(emptyState, for: realRepo)
        XCTAssertNil(reader.load(for: realRepo))
        XCTAssertFalse(fm.fileExists(atPath: storageFile.path))

        // Legacy v1 single-session JSON migrates automatically into a `.workingTree` session.
        let legacyJSON: [String: Any] = [
            "version": 1,
            "records": [
                AIGroupStorage.repoKey(for: realRepo): [
                    "result": [
                        "groups": [[
                            "id": group.id.uuidString,
                            "name": group.name,
                            "summary": group.summary,
                            "files": [["path": "Sources/App.swift", "hunkIndices": [0, 2]]],
                        ]],
                        "totalHunks": 2,
                        "totalFiles": 1,
                        "provider": "codex",
                        "model": "gpt-6-luna",
                        "generatedAt": "2023-11-14T22:15:23Z",
                    ],
                    "selectedGroupID": group.id.uuidString,
                    "selectedGroupFilePath": "Sources/App.swift",
                    "selectedGroupHunkIndex": 2,
                    "groupCommitMessages": [group.id.uuidString: "legacy draft"],
                    "headOID": "deadbeef",
                ],
            ],
        ]
        try fm.createDirectory(at: storageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyJSON, options: []).write(to: storageFile)
        let migratedReader = AIGroupStorage(fileURL: storageFile)
        let migrated = try XCTUnwrap(migratedReader.load(for: realRepo))
        XCTAssertEqual(migrated.sessions.count, 1)
        XCTAssertEqual(migrated.sessions[0].source, .workingTree)
        XCTAssertEqual(migrated.sessions[0].result.groups, [group])
        XCTAssertEqual(migrated.sessions[0].groupCommitMessages[group.id.uuidString], "legacy draft")
        XCTAssertEqual(migrated.activeSessionID, migrated.sessions[0].id)

        // Corrupted JSON falls back cleanly without crashing.
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
        let wtResult = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 4,
            totalFiles: 2,
            provider: .agy,
            model: "gemini-4",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_500)
        )
        let wtSession = AIGroupSession(
            source: .workingTree,
            result: wtResult,
            files: [
                FileChange(path: "a.swift", oldPath: nil, kind: .modified),
                FileChange(path: "b.swift", oldPath: nil, kind: .modified),
            ],
            selectedGroupID: groupB.id,
            selectedGroupFilePath: "b.swift",
            selectedGroupHunkIndex: 2
        )

        let compGroup = AIHunkGroup(
            name: "对比分组",
            summary: "对比提交",
            files: [AIHunkGroupFile(path: "c.swift", hunkIndices: [0])]
        )
        let compSession = AIGroupSession(
            source: .comparison(.init(
                title: "main",
                baseHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                targetRef: "refs/heads/main",
                forkPoint: false,
                headTitle: nil,
                headHash: nil,
                stashUntrackedHash: nil,
                isStash: false
            )),
            result: AIHunkGroupingResult(
                groups: [compGroup],
                totalHunks: 1,
                totalFiles: 1,
                provider: .claude,
                model: "sonnet",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_600)
            ),
            files: [FileChange(path: "c.swift", oldPath: nil, kind: .modified)],
            selectedGroupID: compGroup.id,
            selectedGroupFilePath: "c.swift",
            selectedGroupHunkIndex: 0,
            groupCommitMessages: [compGroup.id.uuidString: "should be stripped"]
        )

        let sourceProject = Project(url: dir)
        sourceProject.aiGroupSessions = [wtSession, compSession]
        sourceProject.activeGroupSessionID = wtSession.id
        sourceProject.selectedGroupRowID = ChangeRow.fileID("b.swift")
        sourceProject.setCommitMessage(AIHunkGrouper.defaultCommitMessage(for: groupA), for: groupA)
        sourceProject.setCommitMessage("custom commit draft B", for: groupB)
        let staleID = UUID()
        sourceProject.mutateAIGroupSession(id: wtSession.id) {
            $0.groupCommitMessages[staleID.uuidString] = "stale draft"
        }

        let snapshot = try XCTUnwrap(sourceProject.persistedAIGroupState(headOIDOverride: "abc1234"))
        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.sessions[0].headOID, "abc1234")
        XCTAssertEqual(snapshot.sessions[0].groupCommitMessages, [groupB.id.uuidString: "custom commit draft B"])
        XCTAssertTrue(snapshot.sessions[1].groupCommitMessages.isEmpty, "Non-committable sessions must not keep commit drafts")

        let restoredProject = Project(url: dir)
        restoredProject.restoreAIGroupState(snapshot)
        XCTAssertEqual(restoredProject.aiGroupSessions.count, 2)
        XCTAssertEqual(restoredProject.activeGroupSessionID, wtSession.id)
        XCTAssertEqual(restoredProject.aiGroupResult, wtResult)
        XCTAssertEqual(restoredProject.selectedGroupID, groupB.id)
        XCTAssertEqual(restoredProject.selectedGroupFilePath, "b.swift")
        XCTAssertEqual(restoredProject.selectedGroupRowID, ChangeRow.fileID("b.swift"))
        XCTAssertEqual(restoredProject.selectedGroupHunkIndex, 2)
        XCTAssertEqual(restoredProject.commitMessage(for: groupB), "custom commit draft B")
        XCTAssertEqual(restoredProject.commitMessage(for: groupA), AIHunkGrouper.defaultCommitMessage(for: groupA))
        XCTAssertNil(restoredProject.activeAIGroupSession?.groupCommitMessages[staleID.uuidString])

        // Removing working-tree sessions preserves comparison/commit sessions and updates active selection.
        restoredProject.removeWorkingTreeAIGroupSessions()
        XCTAssertEqual(restoredProject.aiGroupSessions.count, 1)
        XCTAssertEqual(restoredProject.activeGroupSessionID, compSession.id)
        XCTAssertFalse(restoredProject.activeAIGroupSession?.isCommittable ?? true)

        // Invalid selection fields fall back cleanly to valid session/group/file/hunk.
        let brokenWT = AIGroupSession(
            source: .workingTree,
            result: wtResult,
            files: wtSession.files,
            selectedGroupID: UUID(),
            selectedGroupFilePath: "missing.swift",
            selectedGroupHunkIndex: 99,
            groupCommitMessages: [groupA.id.uuidString: AIHunkGrouper.defaultCommitMessage(for: groupA)]
        )
        let invalidSelectionState = PersistedAIGroupState(
            sessions: [brokenWT],
            activeSessionID: UUID()
        )
        let fallbackProject = Project(url: dir)
        fallbackProject.restoreAIGroupState(invalidSelectionState)
        XCTAssertEqual(fallbackProject.activeGroupSessionID, brokenWT.id)
        XCTAssertEqual(fallbackProject.selectedGroupID, groupA.id)
        XCTAssertEqual(fallbackProject.selectedGroupFilePath, "a.swift")
        XCTAssertEqual(fallbackProject.selectedGroupRowID, ChangeRow.fileID("a.swift"))
        XCTAssertEqual(fallbackProject.selectedGroupHunkIndex, 0)
        XCTAssertTrue(fallbackProject.activeAIGroupSession?.groupCommitMessages.isEmpty ?? false)
    }

    // MARK: - Comparison & Commit-Log Hunk Collection + DiffLoader Alignment

    func testCollectHunksForComparisonOnCleanWorkingTreeAndCommitPair() async throws {
        let root = try await makeRepo()
        try writeFile("file.swift", content: (0..<12).map { "line\($0)" }.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Base"], in: root)
        let baseHash = try await runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        try await runGit(["checkout", "-q", "-b", "feature"], in: root)
        var lines = (0..<12).map { "line\($0)" }
        lines[1] = "line1_feature"
        lines[10] = "line10_feature"
        try writeFile("file.swift", content: lines.joined(separator: "\n") + "\n", in: root)
        try writeFile("added.swift", content: "let x = 1\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Feature changes"], in: root)
        let headHash = try await runGit(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)

        // Working tree itself is completely clean.
        let status = try await Git.status(in: root)
        XCTAssertTrue(status.changes.isEmpty)

        // 1. Branch/commit vs clean working tree comparison
        let compFiles = try await Git.compareFiles(base: baseHash, head: nil, in: root)
        let compSource = AIHunkGroupingSource.comparison(.init(
            title: "main",
            baseHash: baseHash,
            targetRef: "main",
            forkPoint: false,
            headTitle: nil,
            headHash: nil,
            stashUntrackedHash: nil,
            isStash: false
        ))
        XCTAssertFalse(compSource.isCommittable)
        let compHunks = try await AIHunkGrouper.collectHunks(repoRoot: root, source: compSource, files: compFiles)
        XCTAssertEqual(compHunks.filter { $0.filePath == "file.swift" }.map(\.hunkIndex), [0, 1])
        XCTAssertEqual(compHunks.filter { $0.filePath == "added.swift" }.map(\.hunkIndex), [0])

        // 2. Commit vs commit comparison
        let twoCommitFiles = try await Git.compareFiles(base: baseHash, head: headHash, in: root)
        let twoCommitSource = AIHunkGroupingSource.comparison(.init(
            title: String(baseHash.prefix(7)),
            baseHash: baseHash,
            targetRef: baseHash,
            forkPoint: false,
            headTitle: String(headHash.prefix(7)),
            headHash: headHash,
            stashUntrackedHash: nil,
            isStash: false
        ))
        XCTAssertFalse(twoCommitSource.isCommittable)
        let twoCommitHunks = try await AIHunkGrouper.collectHunks(repoRoot: root, source: twoCommitSource, files: twoCommitFiles)
        XCTAssertEqual(twoCommitHunks.count, 3)
    }

    @MainActor
    func testCollectHunksForContiguousAndNonContiguousCommitsMatchesDiffLoader() async throws {
        let root = try await makeRepo()
        let baseLines = (0..<16).map { "row\($0)" }
        try writeFile("notes.swift", content: baseLines.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "c0 base"], in: root)

        // c1 edits row1
        var c1Lines = baseLines
        c1Lines[1] = "row1_c1"
        try writeFile("notes.swift", content: c1Lines.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "c1 edit top"], in: root)

        // c2 (skipped in non-contiguous selection) edits row7
        var c2Lines = c1Lines
        c2Lines[7] = "row7_c2"
        try writeFile("notes.swift", content: c2Lines.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "c2 edit middle"], in: root)

        // c3 edits row14
        var c3Lines = c2Lines
        c3Lines[14] = "row14_c3"
        try writeFile("notes.swift", content: c3Lines.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "c3 edit bottom"], in: root)

        let commits = try await Git.log(in: root, skip: 0, limit: 10, query: "", allBranches: false)
        // Newest first: [c3, c2, c1, c0]
        XCTAssertEqual(commits.count, 4)
        let c3 = commits[0]
        let c2 = commits[1]
        let c1 = commits[2]

        // Contiguous selection [c3, c2, c1]
        let contigSummary = try await Git.commitSelectionSummary([c3, c2, c1], in: root)
        XCTAssertFalse(contigSummary.isNonContiguous)
        let contigSource = AIHunkGroupingSource.commits(.init(
            commitHashes: [c3.hash, c2.hash, c1.hash],
            oldestParentHash: c1.parents.first,
            isNonContiguous: false,
            primarySubject: nil,
            skippedMergeCount: 0,
            fileSteps: [:]
        ))
        XCTAssertFalse(contigSource.isCommittable)
        let contigHunks = try await AIHunkGrouper.collectHunks(repoRoot: root, source: contigSource, files: contigSummary.files)
        XCTAssertEqual(contigHunks.map(\.hunkIndex), [0, 1, 2])

        // Non-contiguous selection [c3, c1] (skips c2)
        let nonContigSummary = try await Git.commitSelectionSummary([c3, c1], in: root)
        XCTAssertTrue(nonContigSummary.isNonContiguous)
        let nonContigSource = AIHunkGroupingSource.commits(.init(
            commitHashes: [c3.hash, c1.hash],
            oldestParentHash: nil,
            isNonContiguous: true,
            primarySubject: nil,
            skippedMergeCount: 0,
            fileSteps: nonContigSummary.fileSteps
        ))
        let nonContigHunks = try await AIHunkGrouper.collectHunks(repoRoot: root, source: nonContigSource, files: nonContigSummary.files)
        XCTAssertEqual(nonContigHunks.map(\.hunkIndex), [0, 1])

        // Verify DiffLoader builds matching filtered document using Project.diffRequest
        let project = Project(url: root)
        let group = AIHunkGroup(
            name: "Selected",
            summary: "Non-contiguous hunk #1",
            files: [AIHunkGroupFile(path: "notes.swift", hunkIndices: [1])]
        )
        let session = AIGroupSession(
            source: nonContigSource,
            result: AIHunkGroupingResult(
                groups: [group],
                totalHunks: 1,
                totalFiles: 1,
                provider: .agy,
                model: nil,
                generatedAt: Date()
            ),
            files: nonContigSummary.files
        )
        let req = try XCTUnwrap(project.diffRequest(for: "notes.swift", in: session, ignoreWhitespace: false))
        let doc = await DiffLoader.load(req, includedGroupHunks: .indices([1]))
        XCTAssertTrue(doc.isGroupFiltered)
        XCTAssertEqual(doc.hunks.count, 1)
        XCTAssertEqual(doc.groupHunkIndexMap[1], 0)
        XCTAssertTrue(doc.right.lines.contains("row14_c3"))
        XCTAssertFalse(doc.right.lines.contains("row7_c2"))
    }

    // MARK: - Legacy Whole-File Inference, Span Shifting & Re-anchoring

    @MainActor
    func testLegacyJSONDecodingAndWholeFileInference() throws {
        // Legacy persisted JSON lacks `coversWholeFile` and `hunkSpans`.
        let groupWholeID = UUID()
        let groupSplitAID = UUID()
        let groupSplitBID = UUID()
        let legacyJSON = """
        {
          "activeSessionID": null,
          "sessions": [
            {
              "id": "\(UUID().uuidString)",
              "source": {"workingTree": {}},
              "files": [],
              "groupCommitMessages": {},
              "result": {
                "groups": [
                  {
                    "id": "\(groupWholeID.uuidString)",
                    "name": "唯一归属分组",
                    "summary": "整文件归属（含 >2MB fallback 与 split 漂移）",
                    "files": [
                      {"path": "common.go", "hunkIndices": [0, 1, 2, 3, 4, 5]},
                      {"path": "MsgType.lua", "hunkIndices": [0]},
                      {"path": "split.go", "hunkIndices": [0]}
                    ]
                  },
                  {
                    "id": "\(groupSplitAID.uuidString)",
                    "name": "拆分分组 A",
                    "summary": "split.go 其余 hunk",
                    "files": [
                      {"path": "split.go", "hunkIndices": [1, 2]}
                    ]
                  },
                  {
                    "id": "\(groupSplitBID.uuidString)",
                    "name": "非零起始",
                    "summary": "非 0 起始索引即使单组也不视为整文件",
                    "files": [
                      {"path": "partial_only.go", "hunkIndices": [1]}
                    ]
                  }
                ],
                "totalHunks": 11,
                "totalFiles": 4,
                "provider": "agy",
                "generatedAt": "2026-11-22T04:49:03Z"
              }
            }
          ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(PersistedAIGroupState.self, from: Data(legacyJSON.utf8))
        let dir = try makeTempDir("legacy-infer")
        let project = Project(url: dir)
        project.tab = .groups
        project.restoreAIGroupState(state)

        // Group 1 (sole owner of common.go [0..5] and MsgType.lua [0], but shares split.go [0]).
        project.selectedGroupID = groupWholeID
        XCTAssertEqual(project.highlightedGroupHunks(for: "common.go"), .all)
        XCTAssertEqual(project.highlightedGroupHunks(for: "MsgType.lua"), .all)
        XCTAssertEqual(project.highlightedGroupHunks(for: "split.go"), .indices([0]))

        // Group 2 (split.go [1, 2]).
        project.selectedGroupID = groupSplitAID
        XCTAssertEqual(project.highlightedGroupHunks(for: "split.go"), .indices([1, 2]))

        // Group 3 (partial_only.go [1] does not start at 0).
        project.selectedGroupID = groupSplitBID
        XCTAssertEqual(project.highlightedGroupHunks(for: "partial_only.go"), .indices([1]))
    }

    func testResultAfterDeletingPinsLegacySharedFileToPartial() {
        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "旧记录含 split.go #0",
            files: [AIHunkGroupFile(path: "split.go", hunkIndices: [0])]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "旧记录含 split.go #1",
            files: [AIHunkGroupFile(path: "split.go", hunkIndices: [1])]
        )
        let result = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 2,
            totalFiles: 1,
            provider: .agy,
            model: nil,
            generatedAt: Date()
        )

        let afterDeleteB = AIHunkGrouper.resultAfterDeleting(groupID: groupB.id, in: result)
        XCTAssertEqual(afterDeleteB?.groups.count, 1)
        let remainingFile = afterDeleteB?.groups[0].files.first
        XCTAssertEqual(remainingFile?.coversWholeFile, false)
        XCTAssertEqual(
            remainingFile?.hunkFilter(groupID: groupA.id, in: afterDeleteB?.groups),
            .indices([0]),
            "Deleting sibling group must not promote legacy partial slice to .all"
        )
    }

    func testResultAfterCommittingShiftsHunkSpans() {
        let span0 = AIHunkSpan(oldStart: 10, oldCount: 2, newStart: 10, newCount: 5) // +3 lines delta
        let span1 = AIHunkSpan(oldStart: 30, oldCount: 1, newStart: 33, newCount: 1)
        let span2 = AIHunkSpan(oldStart: 50, oldCount: 4, newStart: 53, newCount: 2)

        let groupA = AIHunkGroup(
            name: "分组 A",
            summary: "提交 hunk 0 和 hunk 2",
            files: [
                AIHunkGroupFile(
                    path: "shared.go",
                    hunkIndices: [0, 2],
                    coversWholeFile: false,
                    hunkSpans: [span0, span2]
                ),
            ]
        )
        let groupB = AIHunkGroup(
            name: "分组 B",
            summary: "保留 hunk 1",
            files: [
                AIHunkGroupFile(
                    path: "shared.go",
                    hunkIndices: [1],
                    coversWholeFile: false,
                    hunkSpans: [span1]
                ),
            ]
        )
        let result = AIHunkGroupingResult(
            groups: [groupA, groupB],
            totalHunks: 3,
            totalFiles: 1,
            provider: .agy,
            model: nil,
            generatedAt: Date()
        )

        let afterA = AIHunkGrouper.resultAfterCommitting(groupID: groupA.id, in: result)
        let keptFile = afterA?.groups.first?.files.first
        XCTAssertEqual(keptFile?.hunkIndices, [0])
        XCTAssertEqual(keptFile?.coversWholeFile, false)
        // Only span0 precedes span1, so span1.oldStart shifts by +(5 - 2) = +3 -> 33.
        XCTAssertEqual(keptFile?.hunkSpans, [AIHunkSpan(oldStart: 33, oldCount: 1, newStart: 33, newCount: 1)])
    }

    func testBuildCommitSelectionWithWholeFileAndSplitSpanReanchoring() async throws {
        let repo = try await makeRepo()
        let baseLines = (0..<20).map { "line\($0)" }
        try writeFile("whole.go", content: baseLines.joined(separator: "\n") + "\n", in: repo)
        try writeFile("split.go", content: baseLines.joined(separator: "\n") + "\n", in: repo)
        try await runGit(["add", "-A"], in: repo)
        try await runGit(["commit", "-q", "-m", "Init"], in: repo)

        // whole.go has 2 hunks now even though saved legacy entry claims only [0] (single-group sole owner -> .all).
        var wholeEdited = baseLines
        wholeEdited[1] = "whole_1"
        wholeEdited[16] = "whole_16"
        try writeFile("whole.go", content: wholeEdited.joined(separator: "\n") + "\n", in: repo)

        // split.go originally had 2 hunks at lines 2 and 16, and later gained an extra hunk at line 8 (so old hunk 1 became live hunk 2).
        var splitEdited = baseLines
        splitEdited[2] = "split_2"
        splitEdited[8] = "split_8_extra"
        splitEdited[16] = "split_16"
        try writeFile("split.go", content: splitEdited.joined(separator: "\n") + "\n", in: repo)

        let status = try await Git.status(in: repo)
        let groupWholeAndTail = AIHunkGroup(
            name: "整文件与尾部",
            summary: "whole.go 整文件 + split.go 尾部锚点",
            files: [
                AIHunkGroupFile(path: "whole.go", hunkIndices: [0]),
                AIHunkGroupFile(
                    path: "split.go",
                    hunkIndices: [1],
                    coversWholeFile: false,
                    hunkSpans: [AIHunkSpan(oldStart: 16, oldCount: 1, newStart: 16, newCount: 1)]
                ),
            ]
        )
        let groupSplitHead = AIHunkGroup(
            name: "split.go 头部",
            summary: "split.go 头部 hunk",
            files: [
                AIHunkGroupFile(
                    path: "split.go",
                    hunkIndices: [0],
                    coversWholeFile: false,
                    hunkSpans: [AIHunkSpan(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1)]
                ),
            ]
        )
        let allGroups = [groupWholeAndTail, groupSplitHead]

        let selection = try await AIHunkGrouper.buildCommitSelection(
            for: groupWholeAndTail,
            allGroups: allGroups,
            allChanges: status.changes,
            repoRoot: repo,
            isInitial: status.isInitial
        )
        XCTAssertEqual(selection.files.map(\.path), ["whole.go", "split.go"])
        XCTAssertNil(selection.excludedLines["whole.go"], "Whole-file group must include all live hunks without exclusions")
        let excludedSplit = try XCTUnwrap(selection.excludedLines["split.go"])
        XCTAssertFalse(excludedSplit.contains(ChangeLine(removed: false, line: 16, text: "split_16")))
        XCTAssertTrue(excludedSplit.contains(ChangeLine(removed: false, line: 2, text: "split_2")))
        XCTAssertTrue(excludedSplit.contains(ChangeLine(removed: false, line: 8, text: "split_8_extra")))
    }

    // MARK: - AI Grouping File Filter, Test Exclusion & Blacklist

    func testAIHunkGroupingFilterGlobPatternsAndNegation() {
        let goAndSQL = AIHunkGroupingFilter(includePatternsRaw: "*.go *.sql", excludeTestFiles: false)
        XCTAssertTrue(goAndSQL.isActive)
        XCTAssertTrue(goAndSQL.matches(path: "gamecore/net/common.go"))
        XCTAssertTrue(goAndSQL.matches(path: "db/gameserver/000124_add_player_transfer.up.sql"))
        XCTAssertTrue(goAndSQL.matches(path: "PKG/UPPER.GO"))
        XCTAssertFalse(goAndSQL.matches(path: "message/MsgType.lua"))
        XCTAssertFalse(goAndSQL.matches(path: "go.mod"))

        // Comma, semicolon, and Chinese punctuation separators + `!` negation.
        let separatorsAndNeg = AIHunkGroupingFilter(includePatternsRaw: "*.go，*.sql; !*pb.go, !db/legacy/*.sql")
        XCTAssertTrue(separatorsAndNeg.matches(path: "gamecore/net/common.go"))
        XCTAssertFalse(separatorsAndNeg.matches(path: "message/proto.pb.go"))
        XCTAssertTrue(separatorsAndNeg.matches(path: "db/gameserver/001.sql"))
        XCTAssertFalse(separatorsAndNeg.matches(path: "db/legacy/old.sql"))

        // Directory glob segment matching (`*` vs `**`, and rejecting `a/**/b` on `a/xb`).
        let directChild = AIHunkGroupingFilter(includePatternsRaw: "db/*.sql")
        XCTAssertTrue(directChild.matches(path: "db/init.sql"))
        XCTAssertFalse(directChild.matches(path: "db/gameserver/001.sql"))

        let recursive = AIHunkGroupingFilter(includePatternsRaw: "db/**/*.sql")
        XCTAssertTrue(recursive.matches(path: "db/init.sql"))
        XCTAssertTrue(recursive.matches(path: "db/gameserver/001.sql"))
        XCTAssertFalse(recursive.matches(path: "db/x.sql/other.txt"))

        let segmentAnchor = AIHunkGroupingFilter(includePatternsRaw: "a/**/b")
        XCTAssertTrue(segmentAnchor.matches(path: "a/b"))
        XCTAssertTrue(segmentAnchor.matches(path: "a/sub/b"))
        XCTAssertFalse(segmentAnchor.matches(path: "a/xb"))

        // `?` single character wildcard.
        let singleChar = AIHunkGroupingFilter(includePatternsRaw: "file?.go")
        XCTAssertTrue(singleChar.matches(path: "file1.go"))
        XCTAssertFalse(singleChar.matches(path: "file12.go"))

        // Negation only (no positive globs) matches everything except excluded pattern.
        let negOnly = AIHunkGroupingFilter(includePatternsRaw: "!*.lua")
        XCTAssertTrue(negOnly.matches(path: "gamecore/net/common.go"))
        XCTAssertFalse(negOnly.matches(path: "message/MsgType.lua"))
    }

    func testAIHunkGroupingFilterExcludeTestFiles() {
        let noTests = AIHunkGroupingFilter(excludeTestFiles: true)
        XCTAssertTrue(noTests.isActive)

        // Should exclude multi-language test files & test directories.
        XCTAssertFalse(noTests.matches(path: "gamecore/playertransfer/audit_test.go"))
        XCTAssertFalse(noTests.matches(path: "test.go"))
        XCTAssertFalse(noTests.matches(path: "Tests/DifTests/AIHunkGrouperTests.swift"))
        XCTAssertFalse(noTests.matches(path: "Sources/FooTests.swift"))
        XCTAssertFalse(noTests.matches(path: "src/UserServiceTest.java"))
        XCTAssertFalse(noTests.matches(path: "web/button.test.ts"))
        XCTAssertFalse(noTests.matches(path: "web/card.spec.tsx"))
        XCTAssertFalse(noTests.matches(path: "scripts/test_migration.py"))
        XCTAssertFalse(noTests.matches(path: "src/__tests__/modal.js"))
        XCTAssertFalse(noTests.matches(path: "testdata/fixture.json"))

        // Should NOT falsely exclude production files containing "test" substrings.
        XCTAssertTrue(noTests.matches(path: "gamecore/net/common.go"))
        XCTAssertTrue(noTests.matches(path: "appprivate/testclient/msg.go"))
        XCTAssertTrue(noTests.matches(path: "gamecore/player/contest.go"))
        XCTAssertTrue(noTests.matches(path: "gamecore/player/latest.go"))
        XCTAssertTrue(noTests.matches(path: "pkg/manifest.go"))
        XCTAssertTrue(noTests.matches(path: "pkg/testing.go"))
    }

    func testAIHunkGroupingFilterBlacklistAndGenerateGroupsIntegration() async throws {
        let repo = try await makeRepo()
        try writeFile("keep.go", content: "package main\nfunc keep() int { return 1 }\n", in: repo)
        try writeFile("keep_test.go", content: "package main\nfunc testKeep() {}\n", in: repo)
        try writeFile("skip.go", content: "package main\nfunc skip() int { return 1 }\n", in: repo)
        try writeFile("schema.sql", content: "CREATE TABLE t (id INT);\n", in: repo)
        try writeFile("notes.md", content: "# Notes\n", in: repo)
        try await runGit(["add", "-A"], in: repo)
        try await runGit(["commit", "-q", "-m", "Init"], in: repo)

        try writeFile("keep.go", content: "package main\nfunc keep() int { return 2 }\n", in: repo)
        try writeFile("keep_test.go", content: "package main\nfunc testKeep() { _ = 1 }\n", in: repo)
        try writeFile("skip.go", content: "package main\nfunc skip() int { return 2 }\n", in: repo)
        try writeFile("schema.sql", content: "CREATE TABLE t (id BIGINT);\n", in: repo)
        try writeFile("notes.md", content: "# Updated Notes\n", in: repo)

        let binDir = try makeTempDir("mock-filter-bin")
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
                        {"name": "业务与数据库", "summary": "保留的 Go 与 SQL 文件", "files": [
                            {"path": "keep.go", "hunkIndices": [0]},
                            {"path": "schema.sql", "hunkIndices": [0]}
                        ]}
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

        // 1. Filter matching 0 files throws `noMatchingFilesAfterFilter`.
        let impossibleFilter = AIHunkGroupingFilter(includePatternsRaw: "*.rs")
        do {
            _ = try await AIHunkGrouper.generateGroups(repoRoot: repo, filter: impossibleFilter, provider: .agy, service: service)
            XCTFail("Expected noMatchingFilesAfterFilter")
        } catch let error as AIHunkGroupingError {
            guard case .noMatchingFilesAfterFilter(let detail) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertTrue(detail.contains("*.rs"))
        }

        // 2. Active filter (`*.go *.sql`, exclude tests, blacklist `./skip.go` and `skip.go`)
        //    must pass ONLY `keep.go` and `schema.sql` to grouping.
        let normFilter = AIHunkGroupingFilter(
            includePatternsRaw: "*.go *.sql",
            excludeTestFiles: true,
            excludedPaths: ["./skip.go", "skip.go"]
        )
        let result = try await AIHunkGrouper.generateGroups(
            repoRoot: repo,
            filter: normFilter,
            provider: .agy,
            service: service
        )
        XCTAssertEqual(result.totalFiles, 2)
        XCTAssertEqual(result.totalHunks, 2)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].files.map(\.path), ["keep.go", "schema.sql"])
    }

    @MainActor
    func testSettingsAIGroupingFilterAndPerRepoBlacklistPersistence() throws {
        let suiteName = "AIHunkGrouperTests.Settings.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dir = try makeTempDir("settings-blacklist")
        let realRepo = dir.appendingPathComponent("real-repo")
        try fm.createDirectory(at: realRepo, withIntermediateDirectories: true)
        let linkRepo = dir.appendingPathComponent("link-repo")
        try fm.createSymbolicLink(at: linkRepo, withDestinationURL: realRepo)
        let otherRepo = dir.appendingPathComponent("other-repo")
        try fm.createDirectory(at: otherRepo, withIntermediateDirectories: true)

        let settings = Settings(defaults: defaults)
        settings.aiGroupingIncludePatterns = "*.go *.sql"
        settings.aiGroupingExcludeTestFiles = true
        XCTAssertTrue(settings.addAIGroupingBlacklist("./gamecore/net/common.go", for: realRepo))
        XCTAssertFalse(settings.addAIGroupingBlacklist("gamecore/net/common.go", for: linkRepo), "Duplicate via symlink must be ignored")
        XCTAssertTrue(settings.addAIGroupingBlacklist("db\\001.sql", for: linkRepo))
        XCTAssertTrue(settings.addAIGroupingBlacklist("only_other.go", for: otherRepo))
        settings.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.aiGroupingIncludePatterns, "*.go *.sql")
        XCTAssertTrue(reloaded.aiGroupingExcludeTestFiles)
        XCTAssertEqual(reloaded.aiGroupingBlacklist(for: realRepo), ["db/001.sql", "gamecore/net/common.go"])
        XCTAssertTrue(reloaded.isAIGroupingBlacklisted("gamecore/net/common.go", for: linkRepo))
        XCTAssertFalse(reloaded.isAIGroupingBlacklisted("only_other.go", for: realRepo))

        let builtFilter = reloaded.aiGroupingFilter(for: linkRepo)
        XCTAssertEqual(builtFilter.includePatternsRaw, "*.go *.sql")
        XCTAssertTrue(builtFilter.excludeTestFiles)
        XCTAssertEqual(builtFilter.excludedPaths, ["db/001.sql", "gamecore/net/common.go"])

        XCTAssertTrue(reloaded.removeAIGroupingBlacklist("db/001.sql", for: realRepo))
        XCTAssertEqual(reloaded.aiGroupingBlacklist(for: realRepo), ["gamecore/net/common.go"])
        reloaded.clearAIGroupingBlacklist(for: linkRepo)
        XCTAssertTrue(reloaded.aiGroupingBlacklist(for: realRepo).isEmpty)

        // Verify AIGroupSession Codable round-trip both with and without `filter`.
        let group = AIHunkGroup(name: "G", summary: "S", files: [AIHunkGroupFile(path: "a.go", hunkIndices: [0], coversWholeFile: true)])
        let res = AIHunkGroupingResult(groups: [group], totalHunks: 1, totalFiles: 1, provider: .agy, model: nil, generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let withFilter = AIGroupSession(source: .workingTree, result: res, filter: builtFilter)
        let withoutFilter = AIGroupSession(source: .workingTree, result: res, filter: nil)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode(AIGroupSession.self, from: enc.encode(withFilter)), withFilter)
        XCTAssertEqual(try dec.decode(AIGroupSession.self, from: enc.encode(withoutFilter)), withoutFilter)
    }
}
