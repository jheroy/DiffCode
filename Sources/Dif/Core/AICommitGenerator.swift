import Darwin
import Foundation

/// Errors thrown while collecting checked diffs or generating a commit message with `agy`.
enum AICommitError: Error, LocalizedError, Equatable, Sendable {
    case unavailableInAppStore
    case noCheckedChanges
    case cliNotFound
    case emptyResponse
    case timedOut
    case executionFailed(status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .unavailableInAppStore:
            return L("AI commit generation is unavailable in the Mac App Store edition.",
                     "Mac App Store 版本不支持 AI 生成提交信息。")
        case .noCheckedChanges:
            return L("No changes checked for commit", "未勾选任何要提交的改动")
        case .cliNotFound:
            return L("agy CLI was not found in PATH. Install agy first.",
                     "未在 PATH 中找到 agy 命令，请先安装 agy。")
        case .emptyResponse:
            return L("agy returned an empty commit message.",
                     "agy 返回的提交信息为空。")
        case .timedOut:
            return L("AI commit message generation timed out.",
                     "AI 生成提交信息超时。")
        case .executionFailed(let status, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return L("agy exited with status \(status).", "agy 异常退出（状态码 \(status)）。")
            }
            let snippet = trimmed.count > 260 ? String(trimmed.prefix(260)) + "…" : trimmed
            return L("agy failed: \(snippet)", "agy 执行失败：\(snippet)")
        }
    }
}

/// Generates commit messages from the user's checked working-tree changes using the `agy` CLI.
enum AICommitGenerator {
    /// Total diff size cap (~48 KB) so huge commits stay fast and within CLI argument & token budgets.
    static let defaultMaxTotalBytes = 48 * 1024
    /// Soft per-file diff budget when many files are checked.
    static let defaultMaxFileBytes = 12 * 1024
    /// Maximum number of checked files listed individually in the Checked Files summary.
    static let defaultMaxSummaryFiles = 200
    /// Maximum UTF-8 byte length of the Checked Files summary.
    static let defaultMaxSummaryBytes = 8 * 1024
    /// Hard upper bound for the full `--print=<prompt>` payload (well below macOS `ARG_MAX` of 1 MB).
    static let defaultMaxPromptBytes = 96 * 1024
    /// Default timeout passed to `agy --print-timeout`.
    static let defaultTimeoutSeconds = 60
    /// Delay after `SIGTERM` before escalating to `SIGKILL` for an unresponsive child process.
    static let defaultKillGracePeriod: TimeInterval = 2.0

    struct CheckedDiffPayload: Sendable, Equatable {
        /// Compact overview of every checked file (including files whose diff body was truncated).
        let summary: String
        /// Unified diff covering ONLY the checked files and checked lines/hunks.
        let diff: String
        /// Number of checked files included.
        let fileCount: Int
        /// Whether any file diff or the combined diff was truncated to stay within the size budget.
        let truncated: Bool
    }

    // MARK: - CLI Resolution

    /// Locates the `agy` executable (or specified provider executable) via login-shell PATH and common bin directories.
    static func resolveCLI(provider: AgentProvider = .agy, searchPaths: [String]? = nil) -> String? {
        LocalAgentEnvironment.availability(for: provider, searchPaths: searchPaths).executablePath
    }

    /// Arguments passed to `agy` for fast, non-interactive commit message generation.
    static func cliArguments(prompt: String, timeoutSeconds: Int = defaultTimeoutSeconds) -> [String] {
        [
            "--output-format", "text",
            "--disable-slash-commands",
            "--effort", "low",
            "--print-timeout", "\(max(5, timeoutSeconds))s",
            "--print=\(prompt)",
        ]
    }

    // MARK: - Checked-Only Diff Collection

    /// Collects the unified diff for `project`'s currently checked files and partial-file selections.
    @MainActor
    static func collectCheckedDiff(for project: Project) async throws -> CheckedDiffPayload {
        let included = project.includedChanges
        let excluded = project.excludedLines
        let root = project.url
        let isInitial = project.status.isInitial
        return try await collectCheckedDiff(
            changes: included,
            excludedLines: excluded,
            in: root,
            isInitial: isInitial
        )
    }

    /// Collects unified diffs strictly for `changes`, omitting any lines listed in `excludedLines`.
    static func collectCheckedDiff(
        changes: [FileChange],
        excludedLines: [String: Set<ChangeLine>] = [:],
        in root: URL,
        isInitial: Bool = false,
        maxTotalBytes: Int = defaultMaxTotalBytes,
        maxFileBytes: Int = defaultMaxFileBytes,
        maxSummaryFiles: Int = defaultMaxSummaryFiles,
        maxSummaryBytes: Int = defaultMaxSummaryBytes
    ) async throws -> CheckedDiffPayload {
        guard !changes.isEmpty else {
            throw AICommitError.noCheckedChanges
        }

        let totalBudget = max(1024, maxTotalBytes)
        let perFileBudget = min(totalBudget, max(maxFileBytes, totalBudget / max(1, changes.count)))
        let summaryFileCap = max(1, maxSummaryFiles)
        let summaryByteCap = max(256, maxSummaryBytes)

        var summaryLines: [String] = []
        summaryLines.reserveCapacity(min(changes.count, summaryFileCap) + 1)
        var summaryBytes = 0
        var summaryTruncated = false
        let summaryOverflowReserve = 48

        for (index, change) in changes.enumerated() {
            if summaryLines.count >= summaryFileCap {
                summaryTruncated = true
                let remaining = changes.count - index
                summaryLines.append("... and \(remaining) more file(s)")
                break
            }
            let isPartial = excludedLines[change.path]?.isEmpty == false
            var line: String
            if change.kind == .renamed, let old = change.oldPath {
                line = "R \(old) -> \(change.path)"
            } else {
                line = "\(change.kind.letter) \(change.path)"
            }
            var meta: [String] = []
            if let additions = change.additions, let deletions = change.deletions {
                meta.append("+\(additions) -\(deletions)")
            }
            if isPartial {
                meta.append("partial")
            }
            if !meta.isEmpty {
                line += " (\(meta.joined(separator: ", ")))"
            }
            let lineCost = line.utf8.count + (summaryLines.isEmpty ? 0 : 1)
            if !summaryLines.isEmpty && summaryBytes + lineCost + summaryOverflowReserve > summaryByteCap {
                summaryTruncated = true
                let remaining = changes.count - index
                summaryLines.append("... and \(remaining) more file(s)")
                break
            }
            summaryLines.append(line)
            summaryBytes += lineCost
        }

        var diffSections: [String] = []
        var usedBytes = 0
        var truncated = summaryTruncated
        var nonEmptyFiles = 0

        for (index, change) in changes.enumerated() {
            try Task.checkCancellation()

            let excluded = excludedLines[change.path] ?? []
            let rawSection: String?
            if !excluded.isEmpty {
                rawSection = try await partialFileDiff(
                    for: change,
                    excluded: excluded,
                    in: root,
                    isInitial: isInitial,
                    maxBytes: perFileBudget
                )
            } else {
                rawSection = try await wholeFileDiff(
                    for: change,
                    in: root,
                    isInitial: isInitial,
                    maxBytes: perFileBudget
                )
            }

            guard let section = rawSection, !section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            nonEmptyFiles += 1

            let remainingBudget = totalBudget - usedBytes
            if remainingBudget <= 128 {
                truncated = true
                let remainingCount = changes.count - index
                diffSections.append("... [truncated: omitted \(remainingCount) remaining file(s); see Checked Files list above]")
                break
            }

            let fileLimit = min(perFileBudget, remainingBudget)
            let clipped = truncateUTF8(section, maxBytes: fileLimit)
            if clipped.wasTruncated {
                truncated = true
            }
            diffSections.append(clipped.text)
            usedBytes += clipped.text.utf8.count + 2
        }

        guard nonEmptyFiles > 0, !diffSections.isEmpty else {
            throw AICommitError.noCheckedChanges
        }

        return CheckedDiffPayload(
            summary: summaryLines.joined(separator: "\n"),
            diff: diffSections.joined(separator: "\n\n"),
            fileCount: changes.count,
            truncated: truncated
        )
    }

    private static func wholeFileDiff(
        for change: FileChange,
        in root: URL,
        isInitial: Bool,
        maxBytes: Int
    ) async throws -> String? {
        if change.kind == .untracked {
            return formatNewFileDiff(path: change.path, in: root, maxBytes: maxBytes)
        }

        let base = isInitial ? Git.emptyTree : "HEAD"
        var paths = [change.path]
        if change.kind == .renamed, let old = change.oldPath {
            paths.insert(old, at: 0)
        }
        let args = [
            "--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "-M", "-U3", base, "--",
        ] + paths

        let output = try await Git.runString(args, in: root, okStatuses: [0, 1])
        let trimmed = output.trimmingCharacters(in: .newlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if change.kind == .added {
            return formatNewFileDiff(path: change.path, in: root, maxBytes: maxBytes)
        }
        return "diff --git a/\(change.oldPath ?? change.path) b/\(change.path)\n# \(change.kind.rawValue) file"
    }

    private static func formatNewFileDiff(path: String, in root: URL, maxBytes: Int) -> String {
        let url = root.appendingPathComponent(path)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return "diff --git a/\(path) b/\(path)\nnew file"
        }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            let dest = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return "diff --git a/\(path) b/\(path)\nnew symlink -> \(dest)"
        }
        guard fileType == .typeRegular else {
            return "diff --git a/\(path) b/\(path)\nnew file"
        }

        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let readLimit = max(4096, maxBytes + 2048)
        let data: Data
        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            data = (try? handle.read(upToCount: readLimit)) ?? Data()
        } else {
            data = (try? Data(contentsOf: url)) ?? Data()
        }

        if data.isEmpty {
            return "diff --git a/\(path) b/\(path)\nnew empty file"
        }
        if TextCodec.looksBinary(data) {
            return "diff --git a/\(path) b/\(path)\nnew binary file (\(fileSize) bytes)"
        }

        let decoded = TextCodec.decode(data)
        let lines = TextCodec.splitLines(decoded)
        var out: [String] = [
            "diff --git a/\(path) b/\(path)",
            "new file",
            "--- /dev/null",
            "+++ b/\(path)",
            "@@ -0,0 +1,\(lines.count) @@",
        ]
        out.reserveCapacity(lines.count + 6)
        for line in lines {
            out.append("+" + line)
        }
        if fileSize > data.count {
            out.append("... [truncated: omitted remaining \(fileSize - data.count) bytes of \(path)]")
        }
        return out.joined(separator: "\n")
    }

    private static func partialFileDiff(
        for change: FileChange,
        excluded: Set<ChangeLine>,
        in root: URL,
        isInitial: Bool,
        maxBytes: Int
    ) async throws -> String? {
        let sides: WorkingTree.Sides
        do {
            sides = try await WorkingTree.partialSides(of: change, in: root)
        } catch {
            // If the file is binary/UTF-16 or cannot be partially sliced, fall back to its full diff.
            return try await wholeFileDiff(for: change, in: root, isInitial: isInitial, maxBytes: maxBytes)
        }
        let relocated = WorkingTree.relocate(excluded, old: sides.oldText, new: sides.newText, hunks: sides.hunks)
        guard let partialData = WorkingTree.partialContent(
            old: sides.old,
            new: sides.new,
            hunks: sides.hunks,
            excluded: relocated.lines
        ) else {
            return try await wholeFileDiff(for: change, in: root, isInitial: isInitial, maxBytes: maxBytes)
        }
        if partialData == sides.old {
            return nil
        }

        let hasOld = change.kind != .added && change.kind != .untracked
        let hasNew = !(change.kind == .deleted && partialData.isEmpty)
        return try await unifiedDiff(
            old: sides.old,
            new: partialData,
            oldPath: change.oldPath ?? change.path,
            newPath: change.path,
            hasOld: hasOld,
            hasNew: hasNew
        )
    }

    private static func unifiedDiff(
        old: Data,
        new: Data,
        oldPath: String,
        newPath: String,
        hasOld: Bool,
        hasNew: Bool
    ) async throws -> String? {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("dif-ai-diff-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let oldFile = scratch.appendingPathComponent("old")
        let newFile = scratch.appendingPathComponent("new")
        try old.write(to: oldFile)
        try new.write(to: newFile)

        let raw = try await Git.runString(
            [
                "diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv",
                "--text", "-U3", "--diff-algorithm=histogram", "--",
                oldFile.lastPathComponent, newFile.lastPathComponent,
            ],
            in: scratch,
            okStatuses: [0, 1]
        )
        let trimmed = raw.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }

        // Rewrite temporary file names in the unified diff header to real repository paths.
        var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)
        for line in lines {
            if line.hasPrefix("diff --git ") {
                rewritten.append("diff --git a/\(oldPath) b/\(newPath)")
            } else if line.hasPrefix("index ") && rewritten.count <= 2 {
                continue
            } else if line.hasPrefix("--- ") && rewritten.count <= 3 {
                rewritten.append(hasOld ? "--- a/\(oldPath)" : "--- /dev/null")
            } else if line.hasPrefix("+++ ") && rewritten.count <= 4 {
                rewritten.append(hasNew ? "+++ b/\(newPath)" : "+++ /dev/null")
            } else {
                rewritten.append(line)
            }
        }
        lines = rewritten
        return lines.joined(separator: "\n")
    }

    private static func truncateUTF8(_ text: String, maxBytes: Int) -> (text: String, wasTruncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return (text, false) }
        let limit = max(0, maxBytes)
        let worstSuffix = "\n... [truncated: omitted \(utf8.count) bytes]"
        if limit <= worstSuffix.utf8.count {
            var end = utf8.index(utf8.startIndex, offsetBy: limit)
            while end > utf8.startIndex, end.samePosition(in: text) == nil {
                end = utf8.index(before: end)
            }
            return (String(text[..<end]), true)
        }
        let contentLimit = limit - worstSuffix.utf8.count
        var end = utf8.index(utf8.startIndex, offsetBy: contentLimit)
        while end > utf8.startIndex, end.samePosition(in: text) == nil {
            end = utf8.index(before: end)
        }
        var prefix = String(text[..<end])
        if let lastNewline = prefix.lastIndex(of: "\n") {
            prefix = String(prefix[..<lastNewline])
        }
        let omitted = max(1, utf8.count - prefix.utf8.count)
        return (prefix + "\n... [truncated: omitted \(omitted) bytes]", true)
    }

    // MARK: - Prompt & Response Cleaning

    /// Builds the prompt sent to `agy`, combining strict rules, the user's format template, file summary, and diff.
    /// Enforces a hard `maxPromptBytes` ceiling so CLI arguments stay safely below macOS `ARG_MAX`.
    static func buildPrompt(
        diff: String,
        format: String,
        summary: String,
        maxPromptBytes: Int = defaultMaxPromptBytes
    ) -> String {
        let promptCap = max(2048, maxPromptBytes)
        let rules = """
            You are generating a Git commit message based ONLY on the checked changes provided below.
            Rules:
            - Do NOT run any tools, shell commands, or read any files.
            - Strictly follow the commit message format below.
            - Output ONLY the final commit message text (no markdown code fences, no surrounding quotes, no preamble, no explanation).
            - Summarize ONLY the changes present in the diff below.
            """

        let trimmedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawFormat = trimmedFormat.isEmpty ? Settings.defaultCommitMessageFormat : trimmedFormat
        let formatCap = max(512, promptCap / 4)
        let boundedFormat = truncateUTF8(rawFormat, maxBytes: formatCap).text

        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summarySection: String?
        if trimmedSummary.isEmpty {
            summarySection = nil
        } else {
            let summaryCap = min(defaultMaxSummaryBytes, max(512, promptCap / 4))
            let boundedSummary = truncateUTF8(trimmedSummary, maxBytes: summaryCap).text
            summarySection = "## Checked Files\n\(boundedSummary)"
        }

        let diffHeader = "## Git Diff (Checked Changes Only)\n"
        var prefixSections: [String] = [rules, boundedFormat]
        if let summarySection {
            prefixSections.append(summarySection)
        }
        let prefix = prefixSections.joined(separator: "\n\n") + "\n\n" + diffHeader
        let remainingForDiff = max(256, promptCap - prefix.utf8.count)
        let boundedDiff = truncateUTF8(diff, maxBytes: remainingForDiff).text
        let full = prefix + boundedDiff
        if full.utf8.count <= promptCap {
            return full
        }
        return truncateUTF8(full, maxBytes: promptCap).text
    }

    /// Cleans LLM stdout: strips wrapping code fences, accidental label prefixes, surrounding quotes, and blank edges.
    static func cleanResponse(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Iterate up to 3 times to peel nested wrappers (e.g. "Commit message:\n```\n...\n```").
        for _ in 0..<3 {
            let before = text
            text = stripLeadingLabelPrefix(text)
            text = stripWrappingCodeFence(text)
            text = stripWrappingQuotes(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == before { break }
        }

        return text
    }

    private static func stripLeadingLabelPrefix(_ text: String) -> String {
        let prefixes = [
            "commit message:",
            "commit message：",
            "提交信息：",
            "提交信息:",
            "提交说明：",
            "提交说明:",
        ]
        let lower = text.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix) {
            let idx = text.index(text.startIndex, offsetBy: prefix.count)
            return String(text[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func stripWrappingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return text }
        let firstTrimmed = lines[0].trimmingCharacters(in: .whitespaces)
        guard firstTrimmed.hasPrefix("```") else { return text }
        // Find the closing fence on the last non-empty line.
        var lastIndex = lines.count - 1
        while lastIndex > 0 && lines[lastIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            lastIndex -= 1
        }
        guard lastIndex > 0, lines[lastIndex].trimmingCharacters(in: .whitespaces) == "```" else {
            return text
        }
        return lines[1..<lastIndex].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        guard text.count >= 2 else { return text }
        let pairs: [(Character, Character)] = [("\"", "\""), ("'", "'"), ("`", "`")]
        for (open, close) in pairs where text.first == open && text.last == close {
            let inner = String(text.dropFirst().dropLast())
            // Avoid stripping when the same quote character appears inside (e.g. `` `a` and `b` ``).
            if open == "`" && inner.contains("`") { continue }
            if open == "\"" && inner.contains("\"") { continue }
            if open == "'" && inner.contains("'") { continue }
            return inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Generation & Process Execution

    /// Collects checked working-tree diffs and generates a commit message via `LocalAgentService`
    /// (defaults to `agy` ACP; supports selecting any `AgentProvider` and optional `model`).
    static func generate(
        repoRoot: URL,
        files: [FileChange],
        excludedLines: [String: Set<ChangeLine>] = [:],
        isInitial: Bool = false,
        format: String,
        provider: AgentProvider = .agy,
        model: String? = nil,
        timeout: TimeInterval = TimeInterval(defaultTimeoutSeconds),
        service: LocalAgentService = .shared
    ) async throws -> String {
        guard !AppEnvironment.isAppStore else {
            throw AICommitError.unavailableInAppStore
        }
        try Task.checkCancellation()
        let payload = try await collectCheckedDiff(
            changes: files,
            excludedLines: excludedLines,
            in: repoRoot,
            isInitial: isInitial
        )
        return try await generate(
            from: payload,
            format: format,
            provider: provider,
            model: model,
            workingDirectory: repoRoot,
            timeoutSeconds: max(5, Int(timeout.rounded())),
            service: service
        )
    }

    /// Generates a commit message for `payload` using `LocalAgentService` (defaults to `agy` ACP).
    static func generate(
        from payload: CheckedDiffPayload,
        format: String,
        provider: AgentProvider = .agy,
        model: String? = nil,
        workingDirectory: URL? = nil,
        timeoutSeconds: Int = defaultTimeoutSeconds,
        service: LocalAgentService = .shared
    ) async throws -> String {
        guard !AppEnvironment.isAppStore else {
            throw AICommitError.unavailableInAppStore
        }
        try Task.checkCancellation()

        let prompt = buildPrompt(diff: payload.diff, format: format, summary: payload.summary)
        let workDir = workingDirectory ?? FileManager.default.temporaryDirectory

        let raw: String
        do {
            raw = try await service.generate(
                provider: provider,
                model: model,
                cwd: workDir,
                prompt: prompt,
                jsonSchema: nil,
                timeout: TimeInterval(max(5, timeoutSeconds))
            )
        } catch let error as LocalAgentError {
            throw mapAgentError(error)
        }

        let cleaned = cleanResponse(raw)
        guard !cleaned.isEmpty else {
            throw AICommitError.emptyResponse
        }
        return cleaned
    }

    /// Generates a commit message for `payload` using an explicit CLI executable path (retained for direct CLI testing).
    static func generate(
        from payload: CheckedDiffPayload,
        format: String,
        cliPath: String,
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) async throws -> String {
        guard !AppEnvironment.isAppStore else {
            throw AICommitError.unavailableInAppStore
        }
        try Task.checkCancellation()

        guard FileManager.default.isExecutableFile(atPath: cliPath) else {
            throw AICommitError.cliNotFound
        }

        let prompt = buildPrompt(diff: payload.diff, format: format, summary: payload.summary)
        let args = cliArguments(prompt: prompt, timeoutSeconds: timeoutSeconds)
        let env = environment ?? LocalAgentEnvironment.environment()
        let workDir = workingDirectory ?? FileManager.default.temporaryDirectory

        let raw = try await runCLI(
            executable: cliPath,
            arguments: args,
            environment: env,
            workingDirectory: workDir,
            timeoutSeconds: timeoutSeconds + 5
        )
        let cleaned = cleanResponse(raw)
        guard !cleaned.isEmpty else {
            throw AICommitError.emptyResponse
        }
        return cleaned
    }

    static func mapAgentError(_ error: LocalAgentError) -> AICommitError {
        switch error {
        case .unavailableInAppStore:
            return .unavailableInAppStore
        case .providerNotInstalled(.agy):
            return .cliNotFound
        case .providerNotInstalled(let provider):
            return .executionFailed(
                status: 127,
                stderr: LocalAgentError.providerNotInstalled(provider).localizedDescription
            )
        case .timedOut:
            return .timedOut
        case .emptyResponse:
            return .emptyResponse
        case .protocolError(_, let detail):
            return .executionFailed(status: 1, stderr: detail)
        case .executionFailed(_, let status, let stderr):
            return .executionFailed(status: status, stderr: stderr)
        }
    }

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false
        private var isTimedOut = false
        private var killScheduled = false
        private let killGracePeriod: TimeInterval

        init(killGracePeriod: TimeInterval = AICommitGenerator.defaultKillGracePeriod) {
            self.killGracePeriod = killGracePeriod
        }

        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
        var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return isTimedOut }

        func attach(_ p: Process) {
            lock.lock()
            process = p
            let shouldStop = isCancelled || isTimedOut
            let shouldScheduleKill = shouldStop && !killScheduled
            if shouldScheduleKill { killScheduled = true }
            lock.unlock()
            if shouldStop {
                terminate(p, scheduleKill: shouldScheduleKill)
            }
        }

        func detach() {
            lock.lock()
            process = nil
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let p = process
            let shouldScheduleKill = p != nil && !killScheduled
            if shouldScheduleKill { killScheduled = true }
            lock.unlock()
            if let p {
                terminate(p, scheduleKill: shouldScheduleKill)
            }
        }

        func markTimedOut() {
            lock.lock()
            isTimedOut = true
            let p = process
            let shouldScheduleKill = p != nil && !killScheduled
            if shouldScheduleKill { killScheduled = true }
            lock.unlock()
            if let p {
                terminate(p, scheduleKill: shouldScheduleKill)
            }
        }

        private func terminate(_ p: Process, scheduleKill: Bool) {
            guard p.isRunning else { return }
            let pid = p.processIdentifier
            p.terminate()
            guard scheduleKill, pid > 0 else { return }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod) { [self] in
                self.lock.lock()
                let stillAttached = self.process === p
                self.lock.unlock()
                if stillAttached, p.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    /// Runs an external CLI process with cancellation and timeout enforcement.
    static func runCLI(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeoutSeconds: Int,
        killGracePeriod: TimeInterval = defaultKillGracePeriod
    ) async throws -> String {
        try Task.checkCancellation()
        let box = ProcessBox(killGracePeriod: killGracePeriod)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }

                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = arguments
                    p.currentDirectoryURL = workingDirectory
                    p.environment = environment
                    p.standardInput = FileHandle.nullDevice
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    p.standardOutput = outPipe
                    p.standardError = errPipe

                    do {
                        try p.run()
                    } catch {
                        cont.resume(throwing: error)
                        return
                    }
                    box.attach(p)

                    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    watchdog.schedule(deadline: .now() + .seconds(max(1, timeoutSeconds)))
                    watchdog.setEventHandler {
                        box.markTimedOut()
                    }
                    watchdog.resume()

                    let errBuffer = OutputBuffer()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    p.waitUntilExit()
                    box.detach()
                    watchdog.cancel()

                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if box.timedOut {
                        cont.resume(throwing: AICommitError.timedOut)
                    } else if p.terminationStatus == 0 {
                        cont.resume(returning: String(decoding: outData, as: UTF8.self))
                    } else {
                        let stderrText = String(decoding: errBuffer.data, as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let stdoutText = String(decoding: outData.prefix(4096), as: UTF8.self)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let detail = stderrText.isEmpty ? stdoutText : stderrText
                        cont.resume(throwing: AICommitError.executionFailed(status: p.terminationStatus, stderr: detail))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
