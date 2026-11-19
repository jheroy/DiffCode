import XCTest
@testable import DifKit

final class AICommitTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? fm.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("dif-aicommit-\(prefix)-\(UUID().uuidString)")
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

    private func makeExecutableScript(_ body: String, name: String = "mock-agy") throws -> URL {
        let dir = try makeTempDir("cli")
        let script = dir.appendingPathComponent(name)
        try Data(body.utf8).write(to: script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    // MARK: - Settings Persistence

    @MainActor
    func testCommitMessageFormatDefaultPersistenceAndReset() {
        let suiteName = "dif.aicommit.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertEqual(initial.commitMessageFormat, Settings.defaultCommitMessageFormat)
        XCTAssertTrue(initial.commitMessageFormat.contains("[EMOJI]"))
        XCTAssertTrue(initial.commitMessageFormat.contains("[TYPE](topic)"))
        XCTAssertTrue(initial.commitMessageFormat.contains("GitMoji"))
        XCTAssertTrue(initial.commitMessageFormat.contains("中文"))

        let custom = "Custom format: <type>(<scope>): <subject>"
        initial.commitMessageFormat = custom
        initial.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertEqual(reloaded.commitMessageFormat, custom)
        XCTAssertEqual(reloaded.effectiveCommitMessageFormat, custom)

        // Whitespace-only falls back to default when loaded or read as effective format.
        reloaded.commitMessageFormat = "   \n\t  "
        XCTAssertEqual(reloaded.effectiveCommitMessageFormat, Settings.defaultCommitMessageFormat)
        reloaded.save()

        let afterEmpty = Settings(defaults: defaults)
        XCTAssertEqual(afterEmpty.commitMessageFormat, Settings.defaultCommitMessageFormat)

        // Custom format followed by resetCommitMessageFormat restores and persists default.
        afterEmpty.commitMessageFormat = custom
        afterEmpty.save()
        afterEmpty.resetCommitMessageFormat()
        XCTAssertEqual(afterEmpty.commitMessageFormat, Settings.defaultCommitMessageFormat)

        let afterReset = Settings(defaults: defaults)
        XCTAssertEqual(afterReset.commitMessageFormat, Settings.defaultCommitMessageFormat)
    }

    // MARK: - Prompt & Response Cleaning

    func testBuildPromptEmbedsCustomFormatSummaryAndDiff() {
        let format = "Format: [TYPE](topic): summary in Chinese"
        let summary = "M Sources/App.swift (+3 -1)"
        let diff = "diff --git a/Sources/App.swift b/Sources/App.swift\n-old\n+new"

        let prompt = AICommitGenerator.buildPrompt(diff: diff, format: format, summary: summary)
        XCTAssertTrue(prompt.contains(format))
        XCTAssertTrue(prompt.contains(summary))
        XCTAssertTrue(prompt.contains(diff))
        XCTAssertTrue(prompt.contains("Do NOT run any tools"))

        let fallbackPrompt = AICommitGenerator.buildPrompt(diff: diff, format: "   \n ", summary: "")
        XCTAssertTrue(fallbackPrompt.contains(Settings.defaultCommitMessageFormat))
    }

    func testCleanResponseHandlesFencesQuotesPrefixesAndMultiline() {
        XCTAssertEqual(
            AICommitGenerator.cleanResponse("  ✨ feat(AICommit): 新增 AI 提交信息生成功能  \n"),
            "✨ feat(AICommit): 新增 AI 提交信息生成功能"
        )

        XCTAssertEqual(
            AICommitGenerator.cleanResponse("```gitcommit\n🐛 fix(parseStatus): 修复重命名解析异常\n```"),
            "🐛 fix(parseStatus): 修复重命名解析异常"
        )

        XCTAssertEqual(
            AICommitGenerator.cleanResponse("Commit message:\n```\n♻️ refactor(CommitPanel): 拆分提交按钮布局\n```"),
            "♻️ refactor(CommitPanel): 拆分提交按钮布局"
        )

        XCTAssertEqual(
            AICommitGenerator.cleanResponse("提交信息：\"📖 docs(README): 补充 agy CLI 说明\""),
            "📖 docs(README): 补充 agy CLI 说明"
        )

        // Internal inline backticks must be preserved.
        XCTAssertEqual(
            AICommitGenerator.cleanResponse("✨ feat(CommitPanel): 添加 `sparkles` 生成按钮"),
            "✨ feat(CommitPanel): 添加 `sparkles` 生成按钮"
        )

        // Multi-line commit message with subject + body.
        let multiline = "\r\n```\r\n✨ feat(AICommit): 支持按勾选改动生成提交信息\r\n\r\n- 仅收集勾选文件与部分行差异\r\n- 设置中支持自定义提交格式\r\n```\r\n"
        XCTAssertEqual(
            AICommitGenerator.cleanResponse(multiline),
            "✨ feat(AICommit): 支持按勾选改动生成提交信息\n\n- 仅收集勾选文件与部分行差异\n- 设置中支持自定义提交格式"
        )
    }

    // MARK: - Checked-Only Diff Collection

    func testCollectCheckedDiffIncludesOnlyCheckedFilesAndUntracked() async throws {
        let root = try await makeRepo()
        try writeFile("checked.swift", content: "let value = 1\n", in: root)
        try writeFile("unchecked.swift", content: "let secret = 1\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Initial"], in: root)

        // Modify both tracked files and add one untracked file.
        try writeFile("checked.swift", content: "let value = 42\n", in: root)
        try writeFile("unchecked.swift", content: "let secret = 999\n", in: root)
        try writeFile("brand_new.swift", content: "func helloNew() {}\n", in: root)

        let status = try await Git.status(in: root)
        let project = await MainActor.run { () -> Project in
            let p = Project(url: root)
            p.status = status
            // Uncheck `unchecked.swift`, check `brand_new.swift`, keep `checked.swift` checked.
            if let unchecked = status.changes.first(where: { $0.path == "unchecked.swift" }) {
                p.setIncluded(false, [unchecked])
            }
            if let untracked = status.changes.first(where: { $0.path == "brand_new.swift" }) {
                p.setIncluded(true, [untracked])
            }
            return p
        }

        let payload = try await AICommitGenerator.collectCheckedDiff(for: project)
        XCTAssertEqual(payload.fileCount, 2)
        XCTAssertFalse(payload.truncated)

        XCTAssertTrue(payload.summary.contains("checked.swift"))
        XCTAssertTrue(payload.summary.contains("brand_new.swift"))
        XCTAssertFalse(payload.summary.contains("unchecked.swift"))

        XCTAssertTrue(payload.diff.contains("checked.swift"))
        XCTAssertTrue(payload.diff.contains("+let value = 42"))
        XCTAssertTrue(payload.diff.contains("brand_new.swift"))
        XCTAssertTrue(payload.diff.contains("+func helloNew() {}"))
        XCTAssertFalse(payload.diff.contains("unchecked.swift"))
        XCTAssertFalse(payload.diff.contains("let secret = 999"))
    }

    func testCollectCheckedDiffRespectsPartialFileExclusions() async throws {
        let root = try await makeRepo()
        let baseLines = [
            "line0",
            "line1",
            "line2",
            "line3",
            "line4",
            "line5",
            "line6",
            "line7",
            "line8",
            "line9",
        ]
        try writeFile("partial.txt", content: baseLines.joined(separator: "\n") + "\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Initial"], in: root)

        // Two separated changes: line0 -> INCLUDED_CHANGE, line9 -> EXCLUDED_CHANGE.
        var editedLines = baseLines
        editedLines[0] = "INCLUDED_CHANGE"
        editedLines[9] = "EXCLUDED_CHANGE"
        try writeFile("partial.txt", content: editedLines.joined(separator: "\n") + "\n", in: root)

        let status = try await Git.status(in: root)
        let change = try XCTUnwrap(status.changes.first(where: { $0.path == "partial.txt" }))
        let excluded: Set<ChangeLine> = [
            ChangeLine(removed: true, line: 9, text: "line9"),
            ChangeLine(removed: false, line: 9, text: "EXCLUDED_CHANGE"),
        ]

        let payload = try await AICommitGenerator.collectCheckedDiff(
            changes: [change],
            excludedLines: ["partial.txt": excluded],
            in: root
        )

        XCTAssertTrue(payload.summary.contains("partial.txt"))
        XCTAssertTrue(payload.summary.contains("partial"))
        XCTAssertTrue(payload.diff.contains("+INCLUDED_CHANGE"))
        XCTAssertTrue(payload.diff.contains("-line0"))
        XCTAssertFalse(payload.diff.contains("EXCLUDED_CHANGE"))
    }

    func testCollectCheckedDiffHandlesDeletedAndRenamedFiles() async throws {
        let root = try await makeRepo()
        try writeFile("to_delete.swift", content: "let doomed = true\n", in: root)
        try writeFile("old_name.swift", content: "func stable() -> Int {\n    return 1\n}\n", in: root)
        try await runGit(["add", "-A"], in: root)
        try await runGit(["commit", "-q", "-m", "Initial"], in: root)

        try fm.removeItem(at: root.appendingPathComponent("to_delete.swift"))
        try await runGit(["mv", "old_name.swift", "new_name.swift"], in: root)
        try writeFile("new_name.swift", content: "func stable() -> Int {\n    return 2\n}\n", in: root)

        let status = try await Git.status(in: root)
        let payload = try await AICommitGenerator.collectCheckedDiff(
            changes: status.changes,
            in: root
        )

        XCTAssertEqual(payload.fileCount, 2)
        XCTAssertTrue(payload.summary.contains("D to_delete.swift"))
        XCTAssertTrue(payload.summary.contains("R old_name.swift -> new_name.swift"))
        XCTAssertTrue(payload.diff.contains("-let doomed = true"))
        XCTAssertTrue(payload.diff.contains("rename from old_name.swift"))
        XCTAssertTrue(payload.diff.contains("rename to new_name.swift"))
        XCTAssertTrue(payload.diff.contains("+    return 2"))
    }

    func testCollectCheckedDiffHandlesEmptyAndSizeTruncation() async throws {
        let root = try await makeRepo()
        do {
            _ = try await AICommitGenerator.collectCheckedDiff(changes: [], in: root)
            XCTFail("Expected noCheckedChanges error")
        } catch let error as AICommitError {
            XCTAssertEqual(error, .noCheckedChanges)
        }

        let bigContent = (0..<200).map { "let item\($0) = \"some reasonably long swift line for truncation test\"" }.joined(separator: "\n") + "\n"
        try writeFile("big.swift", content: bigContent, in: root)
        let change = FileChange(path: "big.swift", oldPath: nil, kind: .untracked)

        let payload = try await AICommitGenerator.collectCheckedDiff(
            changes: [change],
            in: root,
            maxTotalBytes: 2048,
            maxFileBytes: 1024
        )
        XCTAssertTrue(payload.truncated)
        XCTAssertTrue(payload.diff.contains("truncated"))
        XCTAssertLessThan(payload.diff.utf8.count, 3000)
    }

    // MARK: - Mock CLI Execution, Error Handling, Cancellation & App Store Gate

    func testGenerateWithMockCLIVerifiesArgumentsAndStdoutParsing() async throws {
        let argsLog = try makeTempDir("args").appendingPathComponent("args.txt")
        let script = try makeExecutableScript(
            """
            #!/bin/sh
            for arg in "$@"; do
              printf '%s\n' "$arg" >> "\(argsLog.path)"
            done
            printf '```gitcommit\n✨ feat(AICommit): 新增 agy 提交信息生成\n```\n'
            """
        )

        let payload = AICommitGenerator.CheckedDiffPayload(
            summary: "M Sources/Dif/UI/CommitPanel.swift (+10 -0)",
            diff: "diff --git a/Sources/Dif/UI/CommitPanel.swift b/Sources/Dif/UI/CommitPanel.swift\n+AICommitButton()",
            fileCount: 1,
            truncated: false
        )
        let customFormat = "CUSTOM_FORMAT: [EMOJI] [TYPE](topic): [中文]"
        let message = try await AICommitGenerator.generate(
            from: payload,
            format: customFormat,
            cliPath: script.path,
            environment: ProcessInfo.processInfo.environment,
            timeoutSeconds: 15
        )

        XCTAssertEqual(message, "✨ feat(AICommit): 新增 agy 提交信息生成")

        let captured = try String(contentsOf: argsLog, encoding: .utf8)
        XCTAssertTrue(captured.contains("--output-format"))
        XCTAssertTrue(captured.contains("text"))
        XCTAssertTrue(captured.contains("--disable-slash-commands"))
        XCTAssertTrue(captured.contains("--effort"))
        XCTAssertTrue(captured.contains("low"))
        XCTAssertTrue(captured.contains("--print-timeout"))
        XCTAssertTrue(captured.contains("15s"))
        XCTAssertTrue(captured.contains("--print="))
        XCTAssertTrue(captured.contains(customFormat))
        XCTAssertTrue(captured.contains("+AICommitButton()"))
    }

    func testGenerateHandlesNonZeroExitAndEmptyResponse() async throws {
        let failScript = try makeExecutableScript(
            """
            #!/bin/sh
            echo "authentication required" >&2
            exit 42
            """,
            name: "fail-agy"
        )
        let payload = AICommitGenerator.CheckedDiffPayload(summary: "M a.swift", diff: "+x", fileCount: 1, truncated: false)

        do {
            _ = try await AICommitGenerator.generate(
                from: payload,
                format: Settings.defaultCommitMessageFormat,
                cliPath: failScript.path,
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected executionFailed error")
        } catch let error as AICommitError {
            XCTAssertEqual(error, .executionFailed(status: 42, stderr: "authentication required"))
        }

        let emptyScript = try makeExecutableScript(
            """
            #!/bin/sh
            printf '   \n\n  '
            """,
            name: "empty-agy"
        )
        do {
            _ = try await AICommitGenerator.generate(
                from: payload,
                format: Settings.defaultCommitMessageFormat,
                cliPath: emptyScript.path,
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected emptyResponse error")
        } catch let error as AICommitError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testGenerateCancellationTerminatesMockCLI() async throws {
        let slowScript = try makeExecutableScript(
            """
            #!/bin/sh
            sleep 30
            echo "should not finish"
            """,
            name: "slow-agy"
        )
        let payload = AICommitGenerator.CheckedDiffPayload(summary: "M a.swift", diff: "+x", fileCount: 1, truncated: false)
        let start = Date()

        let task = Task {
            try await AICommitGenerator.generate(
                from: payload,
                format: Settings.defaultCommitMessageFormat,
                cliPath: slowScript.path,
                environment: ProcessInfo.processInfo.environment,
                timeoutSeconds: 30
            )
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(start), 5.0)
        }
    }

    func testAppStoreEditionDisablesAICommitGeneration() async throws {
        let previous = AppEnvironment.edition
        AppEnvironment.edition = .appStore
        defer { AppEnvironment.edition = previous }

        XCTAssertNil(AICommitGenerator.resolveCLI(searchPaths: ["/usr/bin"]))
        let payload = AICommitGenerator.CheckedDiffPayload(summary: "M a.swift", diff: "+x", fileCount: 1, truncated: false)
        do {
            _ = try await AICommitGenerator.generate(
                from: payload,
                format: Settings.defaultCommitMessageFormat,
                cliPath: "/bin/echo",
                environment: ProcessInfo.processInfo.environment
            )
            XCTFail("Expected unavailableInAppStore error")
        } catch let error as AICommitError {
            XCTAssertEqual(error, .unavailableInAppStore)
        }
    }
}
