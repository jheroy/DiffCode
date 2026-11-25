import Foundation
import XCTest
@testable import DifKit

final class AICodeReviewerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(_ prefix: String = "dif-ai-review") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeRepo(prefix: String = "dif-ai-review-repo") throws -> URL {
        let dir = try makeTempDir(prefix)
        try runGit(["init", "-q", "-b", "main"], in: dir)
        return dir
    }

    private func writeFile(_ relPath: String, content: String, in root: URL) throws {
        let url = root.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    private func runGit(_ arguments: [String], in dir: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = [
            "-c", "user.name=Dif Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "commit.gpgsign=false",
        ] + arguments
        p.currentDirectoryURL = dir
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func gitOutput(_ arguments: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = arguments
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Independent Review Model Settings

    @MainActor
    func testSettingsReviewProviderAndModelAreIndependentFromCommitAndGrouping() {
        let suiteName = "dif-review-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.setAIProvider(.agy, for: .commit)
        settings.setAIModel("gemini-3.8-flash", for: .agy, task: .commit)

        settings.setAIProvider(.claude, for: .grouping)
        settings.setAIModel("claude-sonnet-4-5", for: .claude, task: .grouping)

        settings.setAIProvider(.codex, for: .review)
        settings.setAIModel("gpt-5.3-codex", for: .codex, task: .review)

        XCTAssertEqual(settings.aiProvider(for: .commit), .agy)
        XCTAssertEqual(settings.aiProvider(for: .grouping), .claude)
        XCTAssertEqual(settings.aiProvider(for: .review), .codex)

        XCTAssertEqual(settings.aiModel(for: .agy, task: .commit), "gemini-3.8-flash")
        XCTAssertEqual(settings.aiModel(for: .claude, task: .grouping), "claude-sonnet-4-5")
        XCTAssertEqual(settings.aiModel(for: .codex, task: .review), "gpt-5.3-codex")
        XCTAssertNil(settings.aiModel(for: .codex, task: .commit))
        XCTAssertNil(settings.aiModel(for: .codex, task: .grouping))

        // Reload from persisted defaults to verify round-trip independence.
        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.aiProvider(for: .commit), .agy)
        XCTAssertEqual(reloaded.aiProvider(for: .grouping), .claude)
        XCTAssertEqual(reloaded.aiProvider(for: .review), .codex)
        XCTAssertEqual(reloaded.aiModel(for: .agy, task: .commit), "gemini-3.8-flash")
        XCTAssertEqual(reloaded.aiModel(for: .claude, task: .grouping), "claude-sonnet-4-5")
        XCTAssertEqual(reloaded.aiModel(for: .codex, task: .review), "gpt-5.3-codex")
    }

    // MARK: - Context-Rich Diff Collection

    func testCollectWorkingTreeDiffIncludesContextExactLineNumbersAndRespectsExcludedLines() async throws {
        let repo = try makeRepo()
        let initialLines = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try writeFile("Sources/Worker.swift", content: initialLines, in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Initial"], in: repo)

        var updated = (1...20).map { "line \($0)" }
        updated[3] = "line 4 updated"     // 0-based index 3 -> 1-based L4
        updated[15] = "line 16 unchecked" // 0-based index 15 -> 1-based L16 (will be excluded)
        try writeFile("Sources/Worker.swift", content: updated.joined(separator: "\n") + "\n", in: repo)

        let status = try await Git.status(in: repo)
        let excluded: [String: Set<ChangeLine>] = [
            "Sources/Worker.swift": [
                ChangeLine(removed: true, line: 15, text: "line 16"),
                ChangeLine(removed: false, line: 15, text: "line 16 unchecked"),
            ],
        ]

        let payload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .workingTree(
                files: status.changes,
                excludedLines: excluded,
                isInitial: false,
                isPartialSelection: true
            ),
            contextLines: 2
        )

        XCTAssertEqual(payload.fileCount, 1)
        XCTAssertEqual(payload.totalHunks, 1)
        let file = try XCTUnwrap(payload.files.first)
        XCTAssertEqual(file.firstTargetLine, 4)
        XCTAssertTrue(file.body.contains("  [L2] line 2"))
        XCTAssertTrue(file.body.contains("- [old L4] line 4"))
        XCTAssertTrue(file.body.contains("+ [L4] line 4 updated"))
        XCTAssertTrue(file.body.contains("  [L6] line 6"))
        XCTAssertFalse(file.body.contains("line 16 unchecked"))
    }

    func testCollectGroupDiffAcrossWorkingTreeComparisonAndCommits() async throws {
        let repo = try makeRepo()
        let baseLines = (1...25).map { "let item\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try writeFile("Split.swift", content: baseLines, in: repo)
        try writeFile("Other.swift", content: "let other = 1\n", in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Base"], in: repo)
        let baseHash = try gitOutput(["rev-parse", "HEAD"], in: repo)

        var featureLines = (1...25).map { "let item\($0) = \($0)" }
        featureLines[1] = "let item2 = 200"   // hunk 0
        featureLines[21] = "let item22 = 220" // hunk 1
        try writeFile("Split.swift", content: featureLines.joined(separator: "\n") + "\n", in: repo)
        try writeFile("Other.swift", content: "let other = 2\n", in: repo)

        // 1. Working tree group targeting only hunk 1 of Split.swift
        let wtStatus = try await Git.status(in: repo)
        let groupA = AIHunkGroup(
            name: "Group A",
            summary: "Update item22",
            files: [AIHunkGroupFile(path: "Split.swift", hunkIndices: [1], coversWholeFile: false, hunkSpans: nil)]
        )
        let groupB = AIHunkGroup(
            name: "Group B",
            summary: "Update item2 and Other",
            files: [
                AIHunkGroupFile(path: "Split.swift", hunkIndices: [0], coversWholeFile: false, hunkSpans: nil),
                AIHunkGroupFile(path: "Other.swift", hunkIndices: [0], coversWholeFile: true, hunkSpans: nil),
            ]
        )

        let wtPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .group(
                group: groupA,
                allGroups: [groupA, groupB],
                source: .workingTree,
                files: wtStatus.changes,
                isInitial: false
            )
        )
        XCTAssertEqual(wtPayload.fileCount, 1)
        XCTAssertEqual(wtPayload.totalHunks, 1)
        XCTAssertTrue(wtPayload.files[0].body.contains("+ [L22] let item22 = 220"))
        XCTAssertFalse(wtPayload.files[0].body.contains("item2 = 200"))

        // Commit changes and test comparison + commits sources
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Feature changes"], in: repo)
        let headHash = try gitOutput(["rev-parse", "HEAD"], in: repo)

        let compFiles = try await Git.compareFiles(base: baseHash, head: headHash, in: repo)
        let compSource = AIHunkGroupingSource.ComparisonSource(
            title: "Base",
            baseHash: baseHash,
            targetRef: baseHash,
            forkPoint: false,
            headTitle: "HEAD",
            headHash: headHash,
            stashUntrackedHash: nil,
            isStash: false
        )
        let compPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .group(
                group: groupA,
                allGroups: [groupA, groupB],
                source: .comparison(compSource),
                files: compFiles,
                isInitial: false
            )
        )
        XCTAssertEqual(compPayload.fileCount, 1)
        XCTAssertTrue(compPayload.files[0].body.contains("+ [L22] let item22 = 220"))
        XCTAssertFalse(compPayload.files[0].body.contains("item2 = 200"))

        let commitsSource = AIHunkGroupingSource.CommitsSource(
            commitHashes: [headHash],
            oldestParentHash: baseHash,
            isNonContiguous: false,
            primarySubject: "Feature changes",
            skippedMergeCount: 0,
            fileSteps: [:]
        )
        let commitPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .group(
                group: groupA,
                allGroups: [groupA, groupB],
                source: .commits(commitsSource),
                files: compFiles,
                isInitial: false
            )
        )
        XCTAssertEqual(commitPayload.fileCount, 1)
        XCTAssertTrue(commitPayload.files[0].body.contains("+ [L22] let item22 = 220"))
        XCTAssertFalse(commitPayload.files[0].body.contains("item2 = 200"))

        // Verify full SHAs in comparison-grouped and commits-grouped context lines.
        let compCtx = compPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(compCtx.contains(baseHash))
        XCTAssertTrue(compCtx.contains(headHash))
        let commitCtx = commitPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(commitCtx.contains(headHash))
        XCTAssertTrue(commitCtx.contains(baseHash))
    }

    func testCollectDiffIncludesFullCommitHashesAndRevisionMetadataAcrossAllScopes() async throws {
        let repo = try makeRepo()
        try writeFile("Alpha.swift", content: "let a = 1\n", in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Commit 1"], in: repo)
        let c1 = try gitOutput(["rev-parse", "HEAD"], in: repo)

        try writeFile("Alpha.swift", content: "let a = 2\n", in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Commit 2"], in: repo)
        let c2 = try gitOutput(["rev-parse", "HEAD"], in: repo)

        try writeFile("Beta.swift", content: "let b = 1\n", in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Commit 3"], in: repo)
        let c3 = try gitOutput(["rev-parse", "HEAD"], in: repo)

        // 1. Working tree with nil repoContext resolves HEAD automatically
        try writeFile("Beta.swift", content: "let b = 2\n", in: repo)
        let wtStatus = try await Git.status(in: repo)
        let wtPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .workingTree(files: wtStatus.changes, excludedLines: [:], isInitial: false, isPartialSelection: false),
            repoContext: AIReviewRepoContext(branch: "main", headOID: nil)
        )
        let wtContext = wtPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(wtContext.contains("main"))
        XCTAssertTrue(wtContext.contains(c3))
        XCTAssertTrue(wtPayload.revisionSummary?.contains(String(c3.prefix(7))) == true)

        // 2. Two-commit comparison
        let compFiles = try await Git.compareFiles(base: c1, head: c3, in: repo)
        let twoCommitSource = AIHunkGroupingSource.ComparisonSource(
            title: "v1",
            baseHash: c1,
            targetRef: "refs/heads/base",
            forkPoint: true,
            headTitle: "main",
            headHash: c3,
            stashUntrackedHash: nil,
            isStash: false
        )
        let compPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .comparison(twoCommitSource, files: compFiles)
        )
        let compContext = compPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(compContext.contains(c1))
        XCTAssertTrue(compContext.contains(c3))
        XCTAssertTrue(compContext.contains("refs/heads/base"))
        XCTAssertTrue(compContext.contains("git show \(c3):"))

        // 3. Comparison vs working tree
        let vsWTFiles = try await Git.compareFiles(base: c1, head: nil, in: repo)
        let vsWTSource = AIHunkGroupingSource.ComparisonSource(
            title: "base",
            baseHash: c1,
            targetRef: "refs/heads/base",
            forkPoint: false,
            headTitle: nil,
            headHash: nil,
            stashUntrackedHash: nil,
            isStash: false
        )
        let vsWTPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .comparison(vsWTSource, files: vsWTFiles),
            repoContext: AIReviewRepoContext(branch: "main", headOID: c3)
        )
        let vsWTContext = vsWTPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(vsWTContext.contains(c1))
        XCTAssertTrue(vsWTContext.contains(c3))

        // 4. Stash comparison
        let stashSource = AIHunkGroupingSource.ComparisonSource(
            title: "WIP on main",
            baseHash: c2,
            targetRef: c2,
            forkPoint: false,
            headTitle: "stash@{0}",
            headHash: c3,
            stashUntrackedHash: c1,
            isStash: true
        )
        let stashPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .comparison(stashSource, files: compFiles)
        )
        let stashContext = stashPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(stashContext.contains(c2))
        XCTAssertTrue(stashContext.contains(c3))
        XCTAssertTrue(stashContext.contains(c1))

        // 5. Session with contiguous commit range & non-contiguous commits
        let contiguousGroup = AIHunkGroup(
            name: "Range Group",
            summary: "c2..c3",
            files: compFiles.map { AIHunkGroupFile(path: $0.path, hunkIndices: [0], coversWholeFile: true, hunkSpans: nil) }
        )
        let contiguousCommits = AIHunkGroupingSource.CommitsSource(
            commitHashes: [c3, c2],
            oldestParentHash: c1,
            isNonContiguous: false,
            primarySubject: nil,
            skippedMergeCount: 0,
            fileSteps: [:]
        )
        let rangeSessionPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .session(source: .commits(contiguousCommits), groups: [contiguousGroup], files: compFiles, isInitial: false)
        )
        let rangeCtx = rangeSessionPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(rangeCtx.contains(c3))
        XCTAssertTrue(rangeCtx.contains(c2))
        XCTAssertTrue(rangeCtx.contains(c1))
        XCTAssertEqual(rangeSessionPayload.revisionSummary, "\(c2.prefix(7))..\(c3.prefix(7))")

        // Non-contiguous commits with per-file commit SHA annotation
        let stepAlpha = FileCommitStep(hash: c2, parent: c1, path: "Alpha.swift", oldPath: nil, kind: .modified)
        let stepBeta = FileCommitStep(hash: c3, parent: c2, path: "Beta.swift", oldPath: nil, kind: .added)
        let nonContigCommits = AIHunkGroupingSource.CommitsSource(
            commitHashes: [c3, c2],
            oldestParentHash: nil,
            isNonContiguous: true,
            primarySubject: nil,
            skippedMergeCount: 0,
            fileSteps: ["Alpha.swift": [stepAlpha], "Beta.swift": [stepBeta]]
        )
        let nonContigPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .session(source: .commits(nonContigCommits), groups: [contiguousGroup], files: compFiles, isInitial: false)
        )
        let nonContigCtx = nonContigPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(nonContigCtx.contains(c3))
        XCTAssertTrue(nonContigCtx.contains(c2))
        let alphaHeader = nonContigPayload.files.first { $0.path == "Alpha.swift" }?.header ?? ""
        XCTAssertTrue(alphaHeader.contains("[commits: \(c2)]"))
        let betaHeader = nonContigPayload.files.first { $0.path == "Beta.swift" }?.header ?? ""
        XCTAssertTrue(betaHeader.contains("[commits: \(c3)]"))
    }

    // MARK: - Prompt, Markdown Cleaning & File Output

    func testBuildPromptIncludesMagicLinkFormatDiagramCriteriaAndReviewSections() {
        let repoRoot = URL(fileURLWithPath: "/tmp/My Repo/diffcode")
        let payload = AIReviewPayload(
            title: "Auth Refactor",
            scopeContextLines: ["审查范围：AI 逻辑分组「Auth Refactor」"],
            files: [
                AIReviewDiffFile(
                    path: "Sources/Auth Client.swift",
                    oldPath: nil,
                    kind: .modified,
                    summaryLine: "M Sources/Auth Client.swift (+10 -2)",
                    header: "### Sources/Auth Client.swift [modified]",
                    body: "@@ -10,2 +10,3 @@\n+ [L11] let token = fetch()",
                    hunkCount: 1,
                    firstTargetLine: 11
                ),
            ],
            totalHunks: 1
        )

        let zhPrompt = AICodeReviewer.buildPrompt(payload: payload, repoRoot: repoRoot, isChinese: true)
        XCTAssertTrue(zhPrompt.contains("只读"))
        XCTAssertTrue(zhPrompt.contains("git show"))
        XCTAssertFalse(zhPrompt.contains("不要调用任何工具"))
        XCTAssertTrue(zhPrompt.contains("diffcode://open?path="))
        XCTAssertTrue(zhPrompt.contains("diffcode://open?path=/tmp/My%20Repo/diffcode/Sources/Auth%20Client.swift&line=11"))
        XCTAssertTrue(zhPrompt.contains("3 个以上功能节点"))
        XCTAssertTrue(zhPrompt.contains("跨服务器"))
        XCTAssertTrue(zhPrompt.contains("mermaid"))
        XCTAssertTrue(zhPrompt.contains("sequenceDiagram"))
        XCTAssertTrue(zhPrompt.contains("潜在问题与风险"))
        XCTAssertTrue(zhPrompt.contains("人工审查重点关注"))

        let enPrompt = AICodeReviewer.buildPrompt(payload: payload, repoRoot: repoRoot, isChinese: false)
        XCTAssertTrue(enPrompt.contains("Read-Only Inspection Only"))
        XCTAssertTrue(enPrompt.contains("git show"))
        XCTAssertFalse(enPrompt.contains("Do NOT invoke any tools"))
        XCTAssertTrue(enPrompt.contains("diffcode://open?path=/tmp/My%20Repo/diffcode/Sources/Auth%20Client.swift&line=11"))
        XCTAssertTrue(enPrompt.contains("more than 3 functional nodes"))
        XCTAssertTrue(enPrompt.contains("across servers"))
        XCTAssertTrue(enPrompt.contains("Potential Issues & Risks"))
        XCTAssertTrue(enPrompt.contains("Reviewer Focus Checklist"))

        let headered = AICodeReviewer.withMetadataHeader(
            "# Code Review: Auth Refactor\n\nBody",
            repoName: "diffcode",
            scopeTitle: "Auth Refactor",
            revisionSummary: "abc1234..def5678",
            provider: .claude,
            model: "sonnet",
            fileCount: 1,
            hunkCount: 1,
            isChinese: false
        )
        XCTAssertTrue(headered.contains("**Commits**: `abc1234..def5678`"))
    }

    func testCleanMarkdownResponsePreservesInnerMermaidFences() {
        let wrapped = """
        ```markdown
        # 代码审查报告：Auth

        ## 3. 流程与交互图
        ```mermaid
        sequenceDiagram
            Client->>Server: Request
        ```

        ## 4. 潜在问题与风险
        - 无明显问题
        ```
        """
        let cleaned = AICodeReviewer.cleanMarkdownResponse(wrapped)
        XCTAssertFalse(cleaned.hasPrefix("```markdown"))
        XCTAssertTrue(cleaned.hasPrefix("# 代码审查报告：Auth"))
        XCTAssertTrue(cleaned.contains("```mermaid"))
        XCTAssertTrue(cleaned.contains("sequenceDiagram"))
        XCTAssertTrue(cleaned.hasSuffix("- 无明显问题"))

        let raw = "# Code Review\n\n```swift\nlet x = 1\n```"
        XCTAssertEqual(AICodeReviewer.cleanMarkdownResponse(raw), raw)
    }

    func testWriteReportCreatesSanitizedMarkdownAndPrunesOldReports() throws {
        let repo = try makeTempDir("repo-root")
        let reportsDir = try makeTempDir("reports-out")

        var createdURLs: [URL] = []
        for idx in 1...4 {
            let url = try AICodeReviewer.writeReport(
                "# Report \(idx)",
                repoRoot: repo,
                scopeSlug: "group:Auth/Fix*Test?",
                baseDirectory: reportsDir,
                maxRetainedFiles: 2,
                now: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + idx * 10))
            )
            createdURLs.append(url)
        }

        let remaining = try FileManager.default.contentsOfDirectory(at: reportsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(remaining.count, 2)
        for url in remaining {
            XCTAssertTrue(url.lastPathComponent.contains("group-Auth-Fix-Test"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURLs[3].path))
    }

    // MARK: - End-to-End Generation & Store Action

    @MainActor
    func testEndToEndGenerateAndStoreReviewActionOpensGeneratedMarkdown() async throws {
        let repo = try makeRepo()
        try writeFile("Service.swift", content: "func greet() -> String { \"hi\" }\n", in: repo)
        try runGit(["add", "-A"], in: repo)
        try runGit(["commit", "-q", "-m", "Initial"], in: repo)
        try writeFile("Service.swift", content: "func greet() -> String { \"hello\" }\n", in: repo)

        let binDir = try makeTempDir("acp-review-bin")
        let agyURL = binDir.appendingPathComponent("agy")
        let mockACP = """
        #!/usr/bin/env python3
        import json, sys

        def emit(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        selected_model = None
        for raw in sys.stdin:
            msg = json.loads(raw)
            m = msg.get("method")
            i = msg.get("id")
            if m == "initialize":
                emit({"jsonrpc":"2.0","id":i,"result":{"protocolVersion":1}})
            elif m == "session/new":
                emit({"jsonrpc":"2.0","id":i,"result":{"sessionId":"s-review"}})
            elif m == "session/set_model":
                selected_model = msg["params"]["modelId"]
                emit({"jsonrpc":"2.0","id":i,"result":{}})
            elif m == "session/prompt":
                # Exercise read-only tool inspection during review generation
                emit({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"tool_call","toolCallId":"tc-r1"}}})
                emit({"jsonrpc":"2.0","id":"fs-r1","method":"fs/read_text_file","params":{"sessionId":"s-review","path":"Service.swift","line":1,"limit":5}})
                fs_resp = json.loads(sys.stdin.readline())
                assert "hello" in fs_resp["result"]["content"]
                emit({"jsonrpc":"2.0","id":"perm-r1","method":"session/request_permission","params":{"toolCall":{"kind":"execute","rawInput":{"command":"git show HEAD:Service.swift"}},"options":[{"optionId":"allow_once","kind":"allow_once"}]}})
                perm_resp = json.loads(sys.stdin.readline())
                assert perm_resp["result"]["outcome"]["optionId"] == "allow_once"
                reply = f"# 代码审查报告：测试\\n\\n使用模型 {selected_model}，[Service.swift:1](diffcode://open?path=/{'tmp'}/Service.swift&line=1)"
                emit({"jsonrpc":"2.0","method":"session/update","params":{"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":reply}}}})
                emit({"jsonrpc":"2.0","id":i,"result":{"stopReason":"end_turn"}})
            elif m == "session/close":
                emit({"jsonrpc":"2.0","id":i,"result":{}})
                break
        """
        try Data(mockACP.utf8).write(to: agyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let store = AppStore.shared
        let prevOpener = store.openReviewFile
        let prevProvider = store.settings.aiProvider(for: .review)
        let prevModel = store.settings.aiModel(for: .agy, task: .review)
        let prevToast = store.toast
        defer {
            store.openReviewFile = prevOpener
            store.settings.setAIProvider(prevProvider, for: .review)
            store.settings.setAIModel(prevModel, for: .agy, task: .review)
            store.toast = prevToast
        }

        store.settings.setAIProvider(.agy, for: .review)
        store.settings.setAIModel("gemini-4-argon", for: .agy, task: .review)

        var openedURLs: [URL] = []
        store.openReviewFile = { url in
            openedURLs.append(url)
            return true
        }

        let project = Project(url: repo)
        let status = try await Git.status(in: repo)
        project.status = status

        store.runAIReview(
            in: project,
            target: .workingTree,
            scope: .workingTree(
                files: status.changes,
                excludedLines: [:],
                isInitial: false,
                isPartialSelection: false
            ),
            service: service
        )

        await project.aiReviewTask?.value
        XCTAssertNil(project.activeReviewTarget)
        XCTAssertEqual(openedURLs.count, 1)
        let reportURL = try XCTUnwrap(openedURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path))
        let content = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(content.contains("gemini-4-argon"))
        XCTAssertTrue(content.contains("diffcode://open?path="))

        let conversation = try XCTUnwrap(project.activeReviewConversation)
        XCTAssertEqual(conversation.status, .completed)
        XCTAssertEqual(conversation.reportFileURL, reportURL)
        XCTAssertFalse(conversation.turns.isEmpty)
        XCTAssertFalse(conversation.turns.first?.fullPrompt?.isEmpty ?? true)

        store.openAgentConversation(conversation)
        XCTAssertEqual(store.popup, .agentConversation)
        XCTAssertEqual(store.activeAgentConversationID, conversation.id)

        let fallbackPrompt = conversation.buildTranscriptFallbackPrompt(
            nextUserMessage: "请检查是否有性能回退",
            isChinese: true
        )
        XCTAssertTrue(fallbackPrompt.contains("请检查是否有性能回退"))
    }

    @MainActor
    func testAgentConversationFollowUpNativeResumeAndFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-conv-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = tempDir.appendingPathComponent("repo")
        let binDir = tempDir.appendingPathComponent("bin")
        let stateDir = tempDir.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        func runGit(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }

        try runGit(["init"])
        try runGit(["config", "user.email", "test@example.com"])
        try runGit(["config", "user.name", "Test User"])
        let sourceDir = repo.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let targetFile = sourceDir.appendingPathComponent("App.swift")
        try Data("let v = 1\n".utf8).write(to: targetFile)
        try runGit(["add", "."])
        try runGit(["commit", "-m", "init"])
        try Data("let v = 2\n// changed\n".utf8).write(to: targetFile)

        let agyURL = binDir.appendingPathComponent("agy")
        let modeFile = stateDir.appendingPathComponent("mode.txt")
        try Data("native".utf8).write(to: modeFile)

        let mockACP = """
        #!/usr/bin/env python3
        import json, sys, pathlib

        mode_file = pathlib.Path("\(modeFile.path)")
        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}
            mode = mode_file.read_text().strip() if mode_file.exists() else "native"

            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": f"sess-{mode}"}})
            elif method in ("session/set_model", "session/set_config_option"):
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif method in ("session/resume", "session/load"):
                if mode == "fallback":
                    send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32001, "message": "Session expired"}})
                else:
                    send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif method == "session/prompt":
                sid = params.get("sessionId", "")
                prompt = "".join(item.get("text", "") for item in params.get("prompt", []) if isinstance(item, dict))
                if mode == "fail-init":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    continue
                if "FOLLOWUP_FALLBACK" in prompt and "NATIVE-FOLLOWUP-OK" in prompt and sid == "sess-fallback":
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "FALLBACK-FOLLOWUP-OK"}}}})
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    continue
                if "FOLLOWUP_NATIVE" in prompt:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "NATIVE-FOLLOWUP-OK"}}}})
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    continue
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "# Review\\n[Sources/App.swift:1](diffcode://open?path=Sources/App.swift&line=1)"}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        """
        try Data(mockACP.utf8).write(to: agyURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyURL.path)

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let store = AppStore.shared
        let prevOpener = store.openReviewFile
        let prevProvider = store.settings.aiProvider(for: .review)
        let prevModel = store.settings.aiModel(for: .agy, task: .review)
        defer {
            store.openReviewFile = prevOpener
            store.settings.setAIProvider(prevProvider, for: .review)
            store.settings.setAIModel(prevModel, for: .agy, task: .review)
            store.dismissPopup()
        }
        store.openReviewFile = { _ in true }
        store.settings.setAIProvider(.agy, for: .review)
        store.settings.setAIModel("gemini-4-argon", for: .agy, task: .review)

        let project = Project(url: repo)
        let status = try await Git.status(in: repo)
        project.status = status

        store.runAIReview(
            in: project,
            target: .workingTree,
            scope: .workingTree(
                files: status.changes,
                excludedLines: [:],
                isInitial: false,
                isPartialSelection: false
            ),
            service: service
        )
        await project.aiReviewTask?.value

        let conversation = try XCTUnwrap(project.activeReviewConversation)
        XCTAssertEqual(conversation.remoteSessionID, "sess-native")
        XCTAssertEqual(conversation.turns.count, 1)

        // 1. Native session resume follow-up
        store.sendAgentConversationFollowUp(conversation, message: "FOLLOWUP_NATIVE", service: service)
        await conversation.followUpTask?.value
        XCTAssertEqual(conversation.turns.count, 2)
        XCTAssertEqual(conversation.latestTurn?.status, .completed)
        XCTAssertEqual(conversation.latestTurn?.assistantText, "NATIVE-FOLLOWUP-OK")

        // 2. Native resume fails -> automatic transcript fallback in a fresh session
        try Data("fallback".utf8).write(to: modeFile)
        store.sendAgentConversationFollowUp(conversation, message: "FOLLOWUP_FALLBACK", service: service)
        await conversation.followUpTask?.value
        XCTAssertEqual(conversation.turns.count, 3)
        XCTAssertEqual(conversation.latestTurn?.status, .completed)
        XCTAssertEqual(conversation.latestTurn?.assistantText, "FALLBACK-FOLLOWUP-OK")
        XCTAssertEqual(conversation.remoteSessionID, "sess-fallback")

        // 3. Initial failure records error and keeps conversation openable
        try Data("fail-init".utf8).write(to: modeFile)
        store.runAIReview(
            in: project,
            target: .workingTree,
            scope: .workingTree(
                files: status.changes,
                excludedLines: [:],
                isInitial: false,
                isPartialSelection: false
            ),
            service: service
        )
        await project.aiReviewTask?.value
        XCTAssertNotNil(project.aiReviewError)
        XCTAssertEqual(project.activeReviewConversation?.hasFailed, true)
    }

    func testGroupScopeFiltersCommitsToGroupFilesAndAttachesSubjects() async throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-grp-commits-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func git(_ args: [String]) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try git(["init"])
        _ = try git(["config", "user.email", "test@example.com"])
        _ = try git(["config", "user.name", "Test User"])
        try Data("let a = 1\n".utf8).write(to: repo.appendingPathComponent("Target.swift"))
        try Data("let b = 1\n".utf8).write(to: repo.appendingPathComponent("Other.swift"))
        _ = try git(["add", "."])
        _ = try git(["commit", "-m", "initial commit"])
        let c1 = try git(["rev-parse", "HEAD"])

        try Data("let b = 2\n".utf8).write(to: repo.appendingPathComponent("Other.swift"))
        _ = try git(["commit", "-am", "unrelated update 1"])
        let c2 = try git(["rev-parse", "HEAD"])

        try Data("let a = 2\n".utf8).write(to: repo.appendingPathComponent("Target.swift"))
        _ = try git(["commit", "-am", "fix target bug"])
        let c3 = try git(["rev-parse", "HEAD"])

        try Data("let b = 3\n".utf8).write(to: repo.appendingPathComponent("Other.swift"))
        _ = try git(["commit", "-am", "unrelated update 2"])
        let c4 = try git(["rev-parse", "HEAD"])

        let targetGroup = AIHunkGroup(
            name: "Target Bugfix",
            summary: "Fixes Target.swift only",
            files: [AIHunkGroupFile(path: "Target.swift", hunkIndices: [0], coversWholeFile: true, hunkSpans: nil)]
        )
        let diffFiles = try await Git.compareFiles(base: c1, head: c4, in: repo)

        // 1. Contiguous range [c4, c3, c2] scoped to Target Bugfix -> only c3 should be listed + subject attached
        let contigCommits = AIHunkGroupingSource.CommitsSource(
            commitHashes: [c4, c3, c2],
            oldestParentHash: c1,
            isNonContiguous: false,
            primarySubject: nil,
            skippedMergeCount: 0,
            fileSteps: [:]
        )
        let contigPayload = try await AICodeReviewer.collectDiff(
            repoRoot: repo,
            scope: .group(group: targetGroup, allGroups: [targetGroup], source: .commits(contigCommits), files: diffFiles, isInitial: false)
        )
        let contigContext = contigPayload.scopeContextLines.joined(separator: "\n")
        XCTAssertTrue(contigContext.contains(c3))
        XCTAssertTrue(contigContext.contains("fix target bug"))
        XCTAssertFalse(contigContext.contains(c2))
        XCTAssertEqual(contigPayload.revisionSummary, String(c3.prefix(7)))

        // 2. Non-contiguous multi-commit selection with 10 SHAs, only c3 touching Target.swift
        let extraSHAs = (1...8).map { String(format: "%040x", $0) }
        let nonContigCommits = AIHunkGroupingSource.CommitsSource(
            commitHashes: [c4, c3, c2] + extraSHAs,
            oldestParentHash: nil,
            isNonContiguous: true,
            primarySubject: nil,
            skippedMergeCount: 2,
            fileSteps: [
                "Target.swift": [FileCommitStep(hash: c3, parent: c2, path: "Target.swift", oldPath: nil, kind: .modified)],
                "Other.swift": [FileCommitStep(hash: c4, parent: c3, path: "Other.swift", oldPath: nil, kind: .modified)]
            ]
        )
        let nonContigScope = AIReviewScope.group(
            group: targetGroup,
            allGroups: [targetGroup],
            source: .commits(nonContigCommits),
            files: diffFiles,
            isInitial: false
        )
        let nonContigLines = nonContigScope.promptContextLines().joined(separator: "\n")
        XCTAssertTrue(nonContigLines.contains(c3))
        XCTAssertFalse(nonContigLines.contains(c4))
        XCTAssertFalse(nonContigLines.contains(extraSHAs[0]))
        XCTAssertTrue(nonContigLines.contains("1"))
        XCTAssertTrue(nonContigLines.contains("11"))
        XCTAssertEqual(nonContigScope.revisionSummary(), String(c3.prefix(7)))
    }
}
