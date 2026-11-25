import Foundation

// MARK: - Models

/// Describes a single 0-based diff hunk (or file-level fallback for binary/huge/mode-only files)
/// collected from the working tree for AI logical grouping.
struct HunkDescriptor: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case added
        case deleted
        case modified
    }

    /// Stable identifier in `"path#hunkIndex"` format (e.g. `"Sources/App.swift#0"`).
    let id: String
    let filePath: String
    let oldPath: String?
    /// 0-based hunk index matching `DiffDocument.hunks` (and `viewer.focus(hunk:)`).
    let hunkIndex: Int
    let kind: Kind
    /// 0-based start line on the left (HEAD) side.
    let oldStart: Int
    let oldCount: Int
    /// 0-based start line on the right (working tree) side.
    let newStart: Int
    let newCount: Int
    /// Unified-style header or synthetic summary (e.g. `"@@ -10,2 +10,5 @@"` or `"[binary file]"`).
    let header: String
    let addedLines: [String]
    let removedLines: [String]
    /// True when no line-level hunks could be extracted (binary, huge, symlink, submodule, or pure rename/mode change).
    let isFileLevelFallback: Bool

    init(
        filePath: String,
        oldPath: String? = nil,
        hunkIndex: Int,
        kind: Kind,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        header: String,
        addedLines: [String],
        removedLines: [String],
        isFileLevelFallback: Bool = false
    ) {
        self.id = "\(filePath)#\(hunkIndex)"
        self.filePath = filePath
        self.oldPath = oldPath
        self.hunkIndex = hunkIndex
        self.kind = kind
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.addedLines = addedLines
        self.removedLines = removedLines
        self.isFileLevelFallback = isFileLevelFallback
    }
}

/// 0-based line range anchor of a diff hunk, used to re-identify hunks across refiner splits or working-tree edits.
struct AIHunkSpan: Hashable, Codable, Sendable {
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int

    func matches(_ hunk: Hunk) -> Bool {
        if hunk.leftCount > 0 && oldCount > 0 {
            return max(hunk.leftStart, oldStart) < min(hunk.leftStart + hunk.leftCount, oldStart + oldCount)
        }
        if hunk.leftCount == 0 && oldCount == 0 {
            return hunk.rightCount > 0 && newCount > 0 && hunk.leftStart == oldStart
        }
        guard hunk.rightCount > 0 && newCount > 0 else { return false }
        let rightOverlaps = max(hunk.rightStart, newStart) < min(hunk.rightStart + hunk.rightCount, newStart + newCount)
        guard rightOverlaps else { return false }
        if hunk.leftCount == 0 {
            return hunk.leftStart >= oldStart && hunk.leftStart <= oldStart + oldCount
        }
        return oldStart >= hunk.leftStart && oldStart <= hunk.leftStart + hunk.leftCount
    }
}

/// Pairs a saved 0-based hunk index with its recorded line span.
struct AIHunkAnchor: Hashable, Sendable {
    let index: Int
    let span: AIHunkSpan
}

/// Resolved group filter applied when viewing or committing a file inside an AI group.
enum GroupHunkFilter: Equatable, Hashable, Sendable {
    case all
    case subset(indices: Set<Int>, anchors: [AIHunkAnchor] = [])

    static func indices(_ indices: Set<Int>) -> GroupHunkFilter {
        .subset(indices: indices, anchors: [])
    }

    /// Resolves live 0-based raw hunk indices matching this filter, plus a map from saved indices to live raw indices.
    func resolved(for rawHunks: [Hunk]) -> (includedRawIndices: Set<Int>, savedToLiveRaw: [Int: Int]) {
        switch self {
        case .all:
            return (Set(rawHunks.indices), [:])
        case .subset(let indices, let anchors):
            guard !anchors.isEmpty else {
                return (indices, [:])
            }
            var matched: Set<Int> = []
            var savedToLive: [Int: Int] = [:]
            for anchor in anchors {
                var firstMatch: Int?
                for (liveIdx, hunk) in rawHunks.enumerated() where anchor.span.matches(hunk) {
                    matched.insert(liveIdx)
                    if firstMatch == nil {
                        firstMatch = liveIdx
                    }
                }
                if let firstMatch, savedToLive[anchor.index] == nil {
                    savedToLive[anchor.index] = firstMatch
                }
            }
            return (matched, savedToLive)
        }
    }

    var includesSingleFallbackHunk: Bool {
        switch self {
        case .all:
            return true
        case .subset(let indices, let anchors):
            if !anchors.isEmpty {
                return anchors.contains {
                    $0.index == 0 || ($0.span.oldStart == 0 && $0.span.newStart == 0 && ($0.span.oldCount > 0 || $0.span.newCount > 0))
                }
            }
            return indices.contains(0)
        }
    }

    func merged(with other: GroupHunkFilter) -> GroupHunkFilter {
        switch (self, other) {
        case (.all, _), (_, .all):
            return .all
        case (.subset(let lhsIndices, let lhsAnchors), .subset(let rhsIndices, let rhsAnchors)):
            var combinedAnchors = lhsAnchors
            for anchor in rhsAnchors where !combinedAnchors.contains(anchor) {
                combinedAnchors.append(anchor)
            }
            return .subset(indices: lhsIndices.union(rhsIndices), anchors: combinedAnchors)
        }
    }
}

/// A file and the 0-based hunk indices belonging to a single AI logical group.
struct AIHunkGroupFile: Identifiable, Hashable, Codable, Sendable {
    var id: String { path }
    let path: String
    /// Sorted, unique 0-based hunk indices within `path`.
    let hunkIndices: [Int]
    /// `true` when this entry owns every hunk (or the whole file fallback) in `path`; `false` when split across groups.
    let coversWholeFile: Bool?
    /// Optional per-hunk 0-based line spans aligned 1:1 with `hunkIndices` for split-file re-anchoring.
    let hunkSpans: [AIHunkSpan]?

    init(
        path: String,
        hunkIndices: [Int],
        coversWholeFile: Bool? = nil,
        hunkSpans: [AIHunkSpan]? = nil
    ) {
        self.path = path
        self.hunkIndices = hunkIndices
        self.coversWholeFile = coversWholeFile
        self.hunkSpans = hunkSpans
    }

    var anchors: [AIHunkAnchor] {
        guard let spans = hunkSpans, spans.count == hunkIndices.count else { return [] }
        return zip(hunkIndices, spans).map { AIHunkAnchor(index: $0.0, span: $0.1) }
    }

    func isEffectivelyWholeFile(groupID: UUID, in allGroups: [AIHunkGroup]?) -> Bool {
        if let explicit = coversWholeFile { return explicit }
        guard let allGroups, !hunkIndices.isEmpty else { return false }
        guard hunkIndices.enumerated().allSatisfy({ $0.offset == $0.element }) else { return false }
        return !allGroups.contains { $0.id != groupID && $0.files.contains(where: { $0.path == path }) }
    }

    func hunkFilter(groupID: UUID, in allGroups: [AIHunkGroup]?) -> GroupHunkFilter {
        if isEffectivelyWholeFile(groupID: groupID, in: allGroups) {
            return .all
        }
        return .subset(indices: Set(hunkIndices), anchors: anchors)
    }
}

/// A logical/feature group of working-tree hunks produced by AI.
struct AIHunkGroup: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let name: String
    let summary: String
    let files: [AIHunkGroupFile]

    var hunkCount: Int { files.reduce(0) { $0 + $1.hunkIndices.count } }
    var fileCount: Int { files.count }

    init(id: UUID = UUID(), name: String, summary: String, files: [AIHunkGroupFile]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.files = files
    }
}

/// Complete result of an AI working-tree hunk grouping pass.
struct AIHunkGroupingResult: Equatable, Codable, Sendable {
    let groups: [AIHunkGroup]
    let totalHunks: Int
    let totalFiles: Int
    let provider: AgentProvider
    let model: String?
    let generatedAt: Date
    var sessionID: String? = nil

    enum CodingKeys: String, CodingKey {
        case groups, totalHunks, totalFiles, provider, model, generatedAt
    }
}

/// Identifies the source of changes grouped into an `AIGroupSession`.
enum AIHunkGroupingSource: Equatable, Hashable, Codable, Sendable {
    struct ComparisonSource: Equatable, Hashable, Codable, Sendable {
        var title: String
        var baseHash: String
        var targetRef: String
        var forkPoint: Bool
        var headTitle: String?
        var headHash: String?
        var stashUntrackedHash: String?
        var isStash: Bool
    }

    struct CommitsSource: Equatable, Hashable, Codable, Sendable {
        /// Selected commit hashes ordered newest first.
        var commitHashes: [String]
        /// Oldest commit's first parent hash for contiguous single/range commits (`nil` for root commit or non-contiguous).
        var oldestParentHash: String?
        var isNonContiguous: Bool
        var primarySubject: String?
        var skippedMergeCount: Int
        /// Chronological per-file commit steps (`oldest` -> `newest`) for non-contiguous selections.
        var fileSteps: [String: [FileCommitStep]]
    }

    case workingTree
    case comparison(ComparisonSource)
    case commits(CommitsSource)

    /// Only working-tree groupings support direct group commit UI & actions.
    var isCommittable: Bool {
        if case .workingTree = self { return true }
        return false
    }

    var symbolName: String {
        switch self {
        case .workingTree:
            return "square.and.pencil"
        case .comparison(let comp):
            return comp.isStash ? "tray.full" : "arrow.left.arrow.right"
        case .commits:
            return "clock.arrow.circlepath"
        }
    }

    var tabTitle: String {
        switch self {
        case .workingTree:
            return L("Working Tree", "工作区")
        case .comparison(let comp):
            if comp.isStash { return comp.title }
            if let headTitle = comp.headTitle { return "\(comp.title)..\(headTitle)" }
            return L("vs \(comp.title)", "对比 \(comp.title)")
        case .commits(let commits):
            if commits.commitHashes.count == 1, let hash = commits.commitHashes.first {
                return String(hash.prefix(7))
            }
            if !commits.isNonContiguous,
               let newest = commits.commitHashes.first,
               let oldest = commits.commitHashes.last {
                return "\(oldest.prefix(7))..\(newest.prefix(7))"
            }
            return L("\(commits.commitHashes.count) commits", "\(commits.commitHashes.count) 个提交")
        }
    }

    var detailTitle: String {
        switch self {
        case .workingTree:
            return L("Working Tree Changes", "工作区未提交变更")
        case .comparison(let comp):
            if comp.isStash {
                return L("Stash: \(comp.title)", "Stash：\(comp.title)")
            }
            if let headTitle = comp.headTitle {
                return L("\(comp.title) → \(headTitle)", "\(comp.title) → \(headTitle)")
            }
            return comp.forkPoint
                ? L("Since fork from \(comp.title) → Working Tree", "自与 \(comp.title) 分叉 → 工作区")
                : L("Compare \(comp.title) → Working Tree", "对比 \(comp.title) → 工作区")
        case .commits(let commits):
            if commits.commitHashes.count == 1, let hash = commits.commitHashes.first {
                if let subject = commits.primarySubject, !subject.isEmpty {
                    return "\(hash.prefix(7)) · \(subject)"
                }
                return L("Commit \(hash.prefix(7))", "提交 \(hash.prefix(7))")
            }
            if !commits.isNonContiguous,
               let newest = commits.commitHashes.first,
               let oldest = commits.commitHashes.last {
                return L("\(commits.commitHashes.count) commits (\(oldest.prefix(7))..\(newest.prefix(7)))",
                         "\(commits.commitHashes.count) 个提交 (\(oldest.prefix(7))..\(newest.prefix(7)))")
            }
            return L("\(commits.commitHashes.count) selected commits", "已选 \(commits.commitHashes.count) 个提交")
        }
    }

    var tooltip: String {
        switch self {
        case .workingTree:
            return L("Uncommitted working tree changes (committable by group)",
                     "工作区未提交变更（支持按分组直接提交）")
        case .comparison(let comp):
            if comp.isStash {
                return L("Stash \(comp.title) (\(comp.baseHash.prefix(7)))\nRead-only view",
                         "Stash \(comp.title) (\(comp.baseHash.prefix(7)))\n仅查看")
            }
            if let headHash = comp.headHash, let headTitle = comp.headTitle {
                return L("Comparing \(comp.title) (\(comp.baseHash.prefix(7))) → \(headTitle) (\(headHash.prefix(7)))\nRead-only view",
                         "对比 \(comp.title) (\(comp.baseHash.prefix(7))) → \(headTitle) (\(headHash.prefix(7)))\n仅查看")
            }
            return L("Comparing \(comp.title) (\(comp.baseHash.prefix(7))) → Working Tree\nRead-only view",
                     "对比 \(comp.title) (\(comp.baseHash.prefix(7))) → 工作区\n仅查看")
        case .commits(let commits):
            let hashes = commits.commitHashes.prefix(5).map { String($0.prefix(7)) }.joined(separator: ", ")
                + (commits.commitHashes.count > 5 ? "…" : "")
            if commits.commitHashes.count == 1, let subject = commits.primarySubject, !subject.isEmpty {
                return L("Commit \(hashes) · \(subject)\nRead-only view",
                         "提交 \(hashes) · \(subject)\n仅查看")
            }
            return L("\(commits.commitHashes.count) commits: \(hashes)\nRead-only view",
                     "\(commits.commitHashes.count) 个提交：\(hashes)\n仅查看")
        }
    }

    static func from(comparison: Comparison) -> AIHunkGroupingSource {
        .comparison(ComparisonSource(
            title: comparison.title,
            baseHash: comparison.base,
            targetRef: comparison.target,
            forkPoint: comparison.forkPoint,
            headTitle: comparison.other?.title,
            headHash: comparison.other?.hash,
            stashUntrackedHash: comparison.stash?.untracked,
            isStash: comparison.stash != nil
        ))
    }
}

/// Configurable file-level filter applied before AI hunk grouping.
struct AIHunkGroupingFilter: Equatable, Hashable, Codable, Sendable {
    var includePatternsRaw: String = ""
    var excludeTestFiles: Bool = false
    var excludedPaths: [String] = []

    /// Normalizes repository-relative paths by replacing backslashes and stripping leading `./` or `/`.
    static func normalizePath(_ raw: String) -> String {
        var result = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while result.hasPrefix("./") {
            result.removeFirst(2)
        }
        while result.hasPrefix("/") {
            result.removeFirst()
        }
        return result
    }

    var parsedTokens: [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；"))
        return includePatternsRaw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var excludedPathSet: Set<String> {
        Set(excludedPaths.map(Self.normalizePath).filter { !$0.isEmpty })
    }

    var isActive: Bool {
        !parsedTokens.isEmpty || excludeTestFiles || !excludedPathSet.isEmpty
    }

    var summaryText: String {
        var parts: [String] = []
        let tokens = parsedTokens
        if !tokens.isEmpty {
            parts.append(tokens.joined(separator: " "))
        }
        if excludeTestFiles {
            parts.append(L("No tests", "不含测试"))
        }
        let blacklistCount = excludedPathSet.count
        if blacklistCount > 0 {
            parts.append(L("\(blacklistCount) blacklisted", "黑名单 \(blacklistCount) 项"))
        }
        return parts.joined(separator: " · ")
    }

    var compactBadgeText: String {
        let full = summaryText
        guard full.count > 28 else { return full }
        return String(full.prefix(27)) + "…"
    }

    /// Multi-language test-file detector avoiding false positives like `contest.go`, `latest.go`, or `testclient`.
    static func isTestFile(path: String) -> Bool {
        let normalized = normalizePath(path)
        guard !normalized.isEmpty else { return false }

        let components = normalized.split(separator: "/").map(String.init)
        guard let fileName = components.last, !fileName.isEmpty else { return false }

        let testDirs: Set<String> = [
            "test", "tests", "__tests__", "spec", "specs", "testdata", "unittest", "unittests",
        ]
        for dir in components.dropLast() {
            if testDirs.contains(dir.lowercased()) {
                return true
            }
        }

        let rawStem = fileName.lastIndex(of: ".").map { String(fileName[..<$0]) } ?? fileName
        let lowerStem = rawStem.lowercased()
        if lowerStem == "test" || lowerStem == "tests" || lowerStem == "spec" || lowerStem == "specs" {
            return true
        }

        let lowerSuffixes = [
            "_test", "_tests", ".test", ".tests", "-test", "-tests",
            "_spec", "_specs", ".spec", ".specs", "-spec", "-specs",
        ]
        if lowerSuffixes.contains(where: { lowerStem.hasSuffix($0) }) {
            return true
        }

        if lowerStem.hasPrefix("test_") || lowerStem.hasPrefix("spec_") {
            return true
        }

        let camelSuffixes = ["Test", "Tests", "Spec", "Specs"]
        for suffix in camelSuffixes where rawStem.count > suffix.count && rawStem.hasSuffix(suffix) {
            return true
        }

        return false
    }

    /// Matches `pattern` (supporting `*`, `?`, and `**` directory wildcards) against `path`.
    static func matchesGlob(pattern rawPattern: String, path rawPath: String) -> Bool {
        let pattern = normalizePath(rawPattern).lowercased()
        let path = normalizePath(rawPath).lowercased()
        guard !pattern.isEmpty, !path.isEmpty else { return false }

        if pattern.contains("/") {
            let patSegs = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            let pathSegs = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            return matchSegments(patSegs, pathSegs)
        }
        let fileName = (path as NSString).lastPathComponent
        return matchesWildcardSegment(pattern, fileName)
    }

    private static func matchSegments(_ patSegs: [String], _ pathSegs: [String]) -> Bool {
        let m = patSegs.count
        let n = pathSegs.count
        var dp = Array(repeating: Array(repeating: false, count: n + 1), count: m + 1)
        dp[m][n] = true

        for pi in stride(from: m - 1, through: 0, by: -1) {
            if patSegs[pi] == "**" {
                dp[pi][n] = dp[pi + 1][n]
                for si in stride(from: n - 1, through: 0, by: -1) {
                    dp[pi][si] = dp[pi + 1][si] || dp[pi][si + 1]
                }
            } else {
                for si in stride(from: n - 1, through: 0, by: -1) {
                    dp[pi][si] = matchesWildcardSegment(patSegs[pi], pathSegs[si]) && dp[pi + 1][si + 1]
                }
            }
        }
        return dp[0][0]
    }

    private static func matchesWildcardSegment(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern)
        let t = Array(text)
        var pi = 0
        var ti = 0
        var starIdx = -1
        var matchIdx = 0

        while ti < t.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count && p[pi] == "*" {
                starIdx = pi
                matchIdx = ti
                pi += 1
            } else if starIdx != -1 {
                pi = starIdx + 1
                matchIdx += 1
                ti = matchIdx
            } else {
                return false
            }
        }

        while pi < p.count && p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }

    func matches(path: String) -> Bool {
        let normalized = Self.normalizePath(path)
        guard !normalized.isEmpty else { return false }

        if excludedPathSet.contains(normalized) {
            return false
        }
        if excludeTestFiles && Self.isTestFile(path: normalized) {
            return false
        }

        var positive: [String] = []
        var negative: [String] = []
        for token in parsedTokens {
            if token.hasPrefix("!") {
                let body = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !body.isEmpty {
                    negative.append(body)
                }
            } else {
                positive.append(token)
            }
        }

        if negative.contains(where: { Self.matchesGlob(pattern: $0, path: normalized) }) {
            return false
        }
        if !positive.isEmpty {
            return positive.contains(where: { Self.matchesGlob(pattern: $0, path: normalized) })
        }
        return true
    }

    func apply(to changes: [FileChange]) -> [FileChange] {
        guard isActive else { return changes }
        return changes.filter { matches(path: $0.path) }
    }
}

/// Errors specific to collecting hunks or parsing AI grouping output.
enum AIHunkGroupingError: Error, LocalizedError, Equatable, Sendable {
    case unavailableInAppStore
    case noChangesToGroup
    case noMatchingFilesAfterFilter(String)
    case invalidJSONResponse(String)

    var errorDescription: String? {
        switch self {
        case .unavailableInAppStore:
            return L("AI hunk grouping is unavailable in the Mac App Store edition.",
                     "Mac App Store 版本不支持 AI 变更分组。")
        case .noChangesToGroup:
            return L("There are no changes to group.",
                     "当前没有可分组的变更。")
        case .noMatchingFilesAfterFilter(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return L("No changed files match the active grouping filter.",
                         "当前没有符合分组筛选条件的变更文件。")
            }
            return L("No changed files match the grouping filter (\(trimmed)).",
                     "当前没有符合分组筛选条件的变更文件（\(trimmed)）。")
        case .invalidJSONResponse(let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return L("AI returned an invalid grouping JSON response.",
                         "AI 返回的分组 JSON 格式无效。")
            }
            let snippet = trimmed.count > 220 ? String(trimmed.prefix(220)) + "…" : trimmed
            return L("Failed to parse AI grouping response: \(snippet)",
                     "无法解析 AI 分组结果：\(snippet)")
        }
    }
}

// MARK: - AI Hunk Grouper

/// Collects working-tree hunks, prompts a local AI agent for logical grouping, and validates 100% hunk coverage.
enum AIHunkGrouper {
    /// Total diff body budget inside the grouping prompt (64 KB) while guaranteeing all hunk headers/IDs fit.
    static let defaultMaxDiffBytes = 64 * 1024
    /// Maximum file size read into memory for line-level diff extraction (2 MB); larger files become a file-level hunk.
    static let defaultMaxInspectableFileBytes = 2 * 1024 * 1024
    /// Maximum characters retained per individual diff line in the prompt.
    static let defaultMaxLineCharacters = 240
    /// Default per-activity idle timeout (seconds) for AI grouping generation.
    /// Streaming ACP sessions renew this watchdog on each incoming JSON frame up to the hard session cap.
    static let defaultTimeout: TimeInterval = 90
    /// Title used for the fallback group capturing any hunks omitted by AI.
    static let fallbackGroupName = "其他变更"

    /// Strict JSON Schema (compatible with both Claude `--json-schema` and Codex `--output-schema`).
    static let responseJSONSchema: String = """
    {"type":"object","additionalProperties":false,"required":["groups"],"properties":{"groups":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["name","summary","files"],"properties":{"name":{"type":"string"},"summary":{"type":"string"},"files":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["path","hunkIndices"],"properties":{"path":{"type":"string"},"hunkIndices":{"type":"array","items":{"type":"integer","minimum":0}}}}}}}}}}
    """

    // MARK: - Hunk Collection

    /// Extracts exact 0-based `HunkDescriptor` entries for all uncommitted working-tree changes
    /// (staged, unstaged, and untracked). Binary, huge, symlink, submodule, or metadata-only files
    /// are emitted as a single file-level descriptor at `hunkIndex = 0`.
    static func collectWorkingTreeHunks(
        repoRoot: URL,
        files: [FileChange]? = nil,
        maxInspectableFileBytes: Int = defaultMaxInspectableFileBytes
    ) async throws -> [HunkDescriptor] {
        try Task.checkCancellation()
        let changes: [FileChange]
        if let files {
            changes = files
        } else {
            let status = try await Git.status(in: repoRoot)
            changes = status.changes
        }
        return try await collectHunks(
            repoRoot: repoRoot,
            source: .workingTree,
            files: changes,
            maxInspectableFileBytes: maxInspectableFileBytes
        )
    }

    /// Extracts exact 0-based `HunkDescriptor` entries for `files` under `source` (working tree,
    /// branch/commit/stash comparison, or selected log commits), preserving `files` order.
    static func collectHunks(
        repoRoot: URL,
        source: AIHunkGroupingSource,
        files: [FileChange],
        maxInspectableFileBytes: Int = defaultMaxInspectableFileBytes
    ) async throws -> [HunkDescriptor] {
        try Task.checkCancellation()
        guard !files.isEmpty else { return [] }

        var buckets = [[HunkDescriptor]?](repeating: nil, count: files.count)
        let maxConcurrency = 8

        try await withThrowingTaskGroup(of: (Int, [HunkDescriptor]).self) { group in
            for (index, change) in files.enumerated() {
                if index >= maxConcurrency, let done = try await group.next() {
                    buckets[done.0] = done.1
                }
                try Task.checkCancellation()
                group.addTask {
                    try Task.checkCancellation()
                    let fileHunks = await collectHunks(
                        for: change,
                        source: source,
                        in: repoRoot,
                        maxInspectableFileBytes: maxInspectableFileBytes
                    )
                    return (index, fileHunks)
                }
            }
            for try await done in group {
                buckets[done.0] = done.1
            }
        }

        var descriptors: [HunkDescriptor] = []
        descriptors.reserveCapacity(files.count * 2)
        for bucket in buckets {
            if let bucket {
                descriptors.append(contentsOf: bucket)
            }
        }
        return descriptors
    }

    private enum WorktreeReadResult {
        case data(Data)
        case fallback(HunkDescriptor)
    }

    private static func readWorkingTreeBytes(
        for change: FileChange,
        in repoRoot: URL,
        maxInspectableFileBytes: Int
    ) -> WorktreeReadResult {
        let url = repoRoot.appendingPathComponent(change.path)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return .fallback(fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[\(change.kind.rawValue) file]"))
        }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            let dest = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .fallback(fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[symlink -> \(dest)]"))
        }
        guard fileType == .typeRegular else {
            return .fallback(fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[\(change.kind.rawValue) file]"))
        }
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > maxInspectableFileBytes {
            return .fallback(fallbackDescriptor(
                for: change,
                kind: descriptorKind(for: change.kind),
                header: "[large file: \(fileSize.byteSizeString)]"
            ))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .fallback(fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[\(change.kind.rawValue) file]"))
        }
        return .data(data)
    }

    private static func collectHunks(
        for change: FileChange,
        source: AIHunkGroupingSource,
        in repoRoot: URL,
        maxInspectableFileBytes: Int
    ) async -> [HunkDescriptor] {
        if change.isSubmodule {
            return [fallbackDescriptor(for: change, kind: .modified, header: "[submodule]")]
        }

        var oldData: Data?
        var newData: Data?

        switch source {
        case .workingTree:
            let wantOld = change.kind != .added && change.kind != .untracked
            let wantNew = change.kind != .deleted
            if wantOld {
                oldData = await Git.blob(rev: "HEAD", path: change.oldPath ?? change.path, in: repoRoot)
            }
            if wantNew {
                switch readWorkingTreeBytes(for: change, in: repoRoot, maxInspectableFileBytes: maxInspectableFileBytes) {
                case .data(let data): newData = data
                case .fallback(let desc): return [desc]
                }
            }

        case .comparison(let comp):
            if comp.isStash && change.kind == .untracked {
                if let untrackedRev = comp.stashUntrackedHash {
                    newData = await Git.blob(rev: untrackedRev, path: change.path, in: repoRoot)
                }
            } else {
                let wantOld = change.kind != .added && change.kind != .untracked
                let wantNew = change.kind != .deleted
                if wantOld {
                    oldData = await Git.blob(rev: comp.baseHash, path: change.oldPath ?? change.path, in: repoRoot)
                }
                if wantNew {
                    if let headHash = comp.headHash {
                        newData = await Git.blob(rev: headHash, path: change.path, in: repoRoot)
                    } else {
                        switch readWorkingTreeBytes(for: change, in: repoRoot, maxInspectableFileBytes: maxInspectableFileBytes) {
                        case .data(let data): newData = data
                        case .fallback(let desc): return [desc]
                        }
                    }
                }
            }

        case .commits(let commits):
            if commits.isNonContiguous, let steps = commits.fileSteps[change.path], !steps.isEmpty {
                if steps.count == 1 {
                    let step = steps[0]
                    let wantOld = step.kind != .added && step.parent != nil
                    let wantNew = step.kind != .deleted
                    async let oldBlob: Data? = wantOld
                        ? Git.blob(rev: step.parent!, path: step.oldPath ?? step.path, in: repoRoot)
                        : nil
                    async let newBlob: Data? = wantNew
                        ? Git.blob(rev: step.hash, path: step.path, in: repoRoot)
                        : nil
                    oldData = await oldBlob
                    newData = await newBlob
                } else {
                    let resolution = await DiffLoader.resolveCommitSteps(steps, in: repoRoot)
                    oldData = resolution.oldData
                    newData = resolution.newData
                }
            } else if let headHash = commits.commitHashes.first {
                let wantOld = change.kind != .added && commits.oldestParentHash != nil
                let wantNew = change.kind != .deleted
                async let oldBlob: Data? = wantOld
                    ? Git.blob(rev: commits.oldestParentHash!, path: change.oldPath ?? change.path, in: repoRoot)
                    : nil
                async let newBlob: Data? = wantNew
                    ? Git.blob(rev: headHash, path: change.path, in: repoRoot)
                    : nil
                oldData = await oldBlob
                newData = await newBlob
            }
        }

        if let oldData, oldData.count > maxInspectableFileBytes {
            return [fallbackDescriptor(
                for: change,
                kind: descriptorKind(for: change.kind),
                header: "[large file: \(oldData.count.byteSizeString)]"
            )]
        }

        if let newData, newData.count > maxInspectableFileBytes {
            return [fallbackDescriptor(
                for: change,
                kind: descriptorKind(for: change.kind),
                header: "[large file: \(newData.count.byteSizeString)]"
            )]
        }

        if (oldData.map(TextCodec.looksBinary) ?? false) || (newData.map(TextCodec.looksBinary) ?? false) {
            let size = newData?.count ?? oldData?.count ?? 0
            return [fallbackDescriptor(
                for: change,
                kind: descriptorKind(for: change.kind),
                header: "[binary file: \(size.byteSizeString)]"
            )]
        }

        // Neither side has readable content (e.g. submodule or missing blob on both sides).
        if oldData == nil && newData == nil {
            return [fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[\(change.kind.rawValue) file]")]
        }

        // Added / untracked file (no old blob)
        if oldData == nil {
            let lines = newData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
            if lines.isEmpty {
                return [fallbackDescriptor(for: change, kind: .added, header: "@@ -0,0 +0,0 @@ (empty new file)")]
            }
            return [HunkDescriptor(
                filePath: change.path,
                oldPath: change.oldPath,
                hunkIndex: 0,
                kind: .added,
                oldStart: 0,
                oldCount: 0,
                newStart: 0,
                newCount: lines.count,
                header: "@@ -0,0 +1,\(lines.count) @@",
                addedLines: lines,
                removedLines: []
            )]
        }

        // Deleted file (no working tree file)
        if newData == nil {
            let lines = oldData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
            if lines.isEmpty {
                return [fallbackDescriptor(for: change, kind: .deleted, header: "@@ -0,0 +0,0 @@ (empty deleted file)")]
            }
            return [HunkDescriptor(
                filePath: change.path,
                oldPath: change.oldPath,
                hunkIndex: 0,
                kind: .deleted,
                oldStart: 0,
                oldCount: lines.count,
                newStart: 0,
                newCount: 0,
                header: "@@ -1,\(lines.count) +0,0 @@",
                addedLines: [],
                removedLines: lines
            )]
        }

        guard let oldBytes = oldData, let newBytes = newData else {
            return [fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[\(change.kind.rawValue) file]")]
        }

        guard let hunks = await DiffLoader.computeHunks(old: oldBytes, new: newBytes, ignoreWhitespace: false) else {
            return [fallbackDescriptor(for: change, kind: descriptorKind(for: change.kind), header: "[binary or undiffable file]")]
        }

        if hunks.isEmpty {
            let note: String
            if change.kind == .renamed, let old = change.oldPath {
                note = "[renamed from \(old)]"
            } else {
                note = "[file mode or metadata change]"
            }
            return [fallbackDescriptor(for: change, kind: .modified, header: note)]
        }

        let oldLines = TextCodec.splitLines(TextCodec.decode(oldBytes))
        let newLines = TextCodec.splitLines(TextCodec.decode(newBytes))

        return hunks.enumerated().map { index, hunk in
            let oldEnd = min(oldLines.count, hunk.leftStart + hunk.leftCount)
            let newEnd = min(newLines.count, hunk.rightStart + hunk.rightCount)
            let removed = hunk.leftStart < oldEnd ? Array(oldLines[hunk.leftStart..<oldEnd]) : []
            let added = hunk.rightStart < newEnd ? Array(newLines[hunk.rightStart..<newEnd]) : []

            let kind: HunkDescriptor.Kind
            switch hunk.kind {
            case .added: kind = .added
            case .deleted: kind = .deleted
            case .modified: kind = .modified
            }

            let oldDispStart = hunk.leftCount == 0 ? hunk.leftStart : hunk.leftStart + 1
            let newDispStart = hunk.rightCount == 0 ? hunk.rightStart : hunk.rightStart + 1
            let header = "@@ -\(oldDispStart),\(hunk.leftCount) +\(newDispStart),\(hunk.rightCount) @@"

            return HunkDescriptor(
                filePath: change.path,
                oldPath: change.oldPath,
                hunkIndex: index,
                kind: kind,
                oldStart: hunk.leftStart,
                oldCount: hunk.leftCount,
                newStart: hunk.rightStart,
                newCount: hunk.rightCount,
                header: header,
                addedLines: added,
                removedLines: removed
            )
        }
    }

    private static func descriptorKind(for kind: FileChange.Kind) -> HunkDescriptor.Kind {
        switch kind {
        case .added, .untracked: return .added
        case .deleted: return .deleted
        case .modified, .renamed, .conflicted: return .modified
        }
    }

    private static func fallbackDescriptor(
        for change: FileChange,
        kind: HunkDescriptor.Kind,
        header: String
    ) -> HunkDescriptor {
        HunkDescriptor(
            filePath: change.path,
            oldPath: change.oldPath,
            hunkIndex: 0,
            kind: kind,
            oldStart: 0,
            oldCount: 0,
            newStart: 0,
            newCount: 0,
            header: header,
            addedLines: [],
            removedLines: [],
            isFileLevelFallback: true
        )
    }

    // MARK: - Prompt Construction (Budget-Controlled)

    /// Builds the grouping prompt, strictly capping diff body volume to `maxDiffBytes`
    /// while preserving EVERY `path#hunkIndex` header and line range so AI can assign 100% of hunks.
    static func buildPrompt(
        hunks: [HunkDescriptor],
        source: AIHunkGroupingSource = .workingTree,
        maxDiffBytes: Int = defaultMaxDiffBytes
    ) -> String {
        let introLine: String
        let overviewPrefix: String
        switch source {
        case .workingTree:
            introLine = "你是一个资深代码审查与 Git 变更整理助手。请根据下方列出的所有未提交变更 Hunk，按功能、模块或逻辑目的将它们划分为清晰合理的逻辑分组，方便开发者逐组审查和拆分提交。"
            overviewPrefix = "## 未提交变更 Hunk 清单"
        case .comparison(let comp):
            let scope = comp.isStash
                ? "Stash \(comp.title)"
                : (comp.headTitle.map { "对比 \(comp.title) 与 \($0)" } ?? "对比 \(comp.title) 与工作区")
            introLine = "你是一个资深代码审查与 Git 变更整理助手。请根据下方列出的所有对比变更 Hunk（\(scope)），按功能、模块或逻辑目的将它们划分为清晰合理的逻辑分组，方便开发者按逻辑单元审查代码。"
            overviewPrefix = "## 对比变更 Hunk 清单"
        case .commits(let commits):
            let scope = commits.commitHashes.count == 1
                ? "提交 \(commits.commitHashes[0].prefix(7))"
                : "所选 \(commits.commitHashes.count) 个历史提交"
            introLine = "你是一个资深代码审查与 Git 变更整理助手。请根据下方列出的所有历史提交变更 Hunk（\(scope)），按功能、模块或逻辑目的将它们划分为清晰合理的逻辑分组，方便开发者按逻辑单元审查代码。"
            overviewPrefix = "## 历史提交变更 Hunk 清单"
        }

        let rules = """
            \(introLine)

            严格要求：
            1. 不要调用任何工具、不要执行命令、不要读取磁盘文件，仅根据下方提供的 Hunk 信息分析。
            2. 每个分组的 `name` 使用简洁清晰的中文标题（建议 4~18 字），`summary` 用 1~2 句中文概括该组改动的意图与影响范围。
            3. 必须覆盖下方列出的**每一个** Hunk（`path` 与 `hunkIndex` 必须与清单完全一致），不得遗漏，不得重复归入多个分组，不得编造不存在的路径或索引。
            4. 同一文件的不同 Hunk 可以分到不同分组（如果它们服务于不同功能），相关联的跨文件 Hunk 应合并到同一分组。
            5. 仅输出合法 JSON（不要附加 Markdown 代码围栏或额外解释），格式严格如下：
            {"groups":[{"name":"分组名称","summary":"分组功能说明","files":[{"path":"relative/path.swift","hunkIndices":[0,1]}]}]}
            """

        // Always emit every hunk's header so AI sees all valid (path, hunkIndex) pairs.
        var headers: [String] = []
        headers.reserveCapacity(hunks.count)
        var totalHeaderBytes = 0
        for hunk in hunks {
            var line = "### \(hunk.id) [\(hunk.kind.rawValue)] \(hunk.header)"
            if let oldPath = hunk.oldPath, oldPath != hunk.filePath {
                line += " (from \(oldPath))"
            }
            headers.append(line)
            totalHeaderBytes += line.utf8.count + 2
        }

        let diffBudget = max(0, maxDiffBytes - totalHeaderBytes)
        var remainingBodyBytes = diffBudget
        var sections: [String] = []
        sections.reserveCapacity(hunks.count)

        for (idx, hunk) in hunks.enumerated() {
            let header = headers[idx]
            let remainingHunks = max(1, hunks.count - idx)
            let perHunkBudget = remainingBodyBytes / remainingHunks

            if perHunkBudget < 48 || (hunk.removedLines.isEmpty && hunk.addedLines.isEmpty) {
                sections.append(header)
                continue
            }

            let body = formatBoundedHunkBody(hunk, maxBytes: perHunkBudget)
            if body.isEmpty {
                sections.append(header)
            } else {
                sections.append("\(header)\n\(body)")
                remainingBodyBytes = max(0, remainingBodyBytes - body.utf8.count - 1)
            }
        }

        let fileCount = Set(hunks.map(\.filePath)).count
        let overview = "\(overviewPrefix)（共 \(fileCount) 个文件，\(hunks.count) 个 Hunk）"
        return "\(rules)\n\n\(overview)\n\n\(sections.joined(separator: "\n\n"))"
    }

    private static func formatBoundedHunkBody(_ hunk: HunkDescriptor, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let reserveForTruncNotice = 48
        let usable = max(0, maxBytes - reserveForTruncNotice)
        var lines: [String] = []
        var used = 0
        var omittedRemoved = 0
        var omittedAdded = 0

        for line in hunk.removedLines {
            let rendered = "-" + clipLine(line)
            let cost = rendered.utf8.count + (lines.isEmpty ? 0 : 1)
            if used + cost <= usable {
                lines.append(rendered)
                used += cost
            } else {
                omittedRemoved += 1
            }
        }

        for line in hunk.addedLines {
            let rendered = "+" + clipLine(line)
            let cost = rendered.utf8.count + (lines.isEmpty ? 0 : 1)
            if used + cost <= usable {
                lines.append(rendered)
                used += cost
            } else {
                omittedAdded += 1
            }
        }

        if omittedRemoved > 0 || omittedAdded > 0 {
            lines.append("... [truncated: omitted -\(omittedRemoved) / +\(omittedAdded) line(s)]")
        }
        return lines.joined(separator: "\n")
    }

    private static func clipLine(_ line: String) -> String {
        guard line.count > defaultMaxLineCharacters else { return line }
        return String(line.prefix(defaultMaxLineCharacters)) + "…"
    }

    // MARK: - Tolerant JSON Extraction & Fallback Validation

    /// Extracts a top-level JSON object string from raw LLM output, handling markdown fences and surrounding prose.
    static func extractJSONObjectString(from raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        // 1. Direct JSON object
        if normalized.first == "{", isValidJSONObject(normalized) {
            return normalized
        }

        // 2. Markdown fenced code blocks (```json ... ``` or ``` ... ```)
        for block in extractFencedBlocks(from: normalized) {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.first == "{", isValidJSONObject(trimmed) {
                return trimmed
            }
            if let balanced = extractFirstBalancedJSONObject(from: trimmed), isValidJSONObject(balanced) {
                return balanced
            }
        }

        // 3. Balanced brace scan across raw text (handles prose before/after JSON)
        if let balanced = extractFirstBalancedJSONObject(from: normalized), isValidJSONObject(balanced) {
            return balanced
        }

        return nil
    }

    private static func isValidJSONObject(_ text: String) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: []) else {
            return false
        }
        return obj is [String: Any]
    }

    private static func extractFencedBlocks(from text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [String] = []
        var insideFence = false
        var current: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if insideFence {
                    blocks.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                    insideFence = false
                } else {
                    insideFence = true
                    current.removeAll(keepingCapacity: true)
                }
            } else if insideFence {
                current.append(line)
            }
        }
        return blocks
    }

    private static func extractFirstBalancedJSONObject(from text: String) -> String? {
        var idx = text.startIndex
        while idx < text.endIndex {
            guard text[idx] == "{" else {
                idx = text.index(after: idx)
                continue
            }
            if let end = findMatchingBrace(in: text, from: idx) {
                let candidate = String(text[idx...end])
                if isValidJSONObject(candidate) {
                    return candidate
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    private static func findMatchingBrace(in text: String, from start: String.Index) -> String.Index? {
        var depth = 0
        var inString = false
        var escaped = false
        var cursor = start
        while cursor < text.endIndex {
            let ch = text[cursor]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
            } else {
                if ch == "\"" {
                    inString = true
                } else if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return cursor
                    }
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// Parses AI grouping JSON with fault tolerance, validates every `(path, hunkIndex)`, deduplicates assignments,
    /// and appends a fallback `"其他变更"` group if any valid hunk was omitted, guaranteeing 100% coverage.
    static func parseGroupingResponse(
        _ raw: String,
        validHunks: [HunkDescriptor],
        source: AIHunkGroupingSource = .workingTree,
        provider: AgentProvider = .agy,
        model: String? = nil,
        generatedAt: Date = Date()
    ) throws -> AIHunkGroupingResult {
        guard let jsonString = extractJSONObjectString(from: raw),
              let root = try? JSONSerialization.jsonObject(with: Data(jsonString.utf8), options: []) as? [String: Any],
              let rawGroups = root["groups"] as? [[String: Any]] else {
            throw AIHunkGroupingError.invalidJSONResponse(raw)
        }

        // Index valid hunks and preserve canonical file order.
        var validByPath: [String: Set<Int>] = [:]
        var descriptorsByKey: [String: HunkDescriptor] = [:]
        var isFallbackByPath: [String: Bool] = [:]
        var canonicalFileOrder: [String] = []
        for hunk in validHunks {
            if validByPath[hunk.filePath] == nil {
                canonicalFileOrder.append(hunk.filePath)
            }
            validByPath[hunk.filePath, default: []].insert(hunk.hunkIndex)
            descriptorsByKey[hunk.id] = hunk
            if hunk.isFileLevelFallback {
                isFallbackByPath[hunk.filePath] = true
            }
        }

        func makeGroupFile(path: String, sortedIndices: [Int]) -> AIHunkGroupFile {
            let totalValid = validByPath[path]?.count ?? 0
            let isWhole = (isFallbackByPath[path] == true) || (totalValid > 0 && sortedIndices.count == totalValid)
            if isWhole {
                return AIHunkGroupFile(
                    path: path,
                    hunkIndices: sortedIndices,
                    coversWholeFile: true,
                    hunkSpans: nil
                )
            }
            let spans: [AIHunkSpan] = sortedIndices.compactMap { idx in
                guard let desc = descriptorsByKey["\(path)#\(idx)"] else { return nil }
                return AIHunkSpan(
                    oldStart: desc.oldStart,
                    oldCount: desc.oldCount,
                    newStart: desc.newStart,
                    newCount: desc.newCount
                )
            }
            return AIHunkGroupFile(
                path: path,
                hunkIndices: sortedIndices,
                coversWholeFile: false,
                hunkSpans: spans.count == sortedIndices.count ? spans : nil
            )
        }

        var assigned: Set<String> = []
        var groups: [AIHunkGroup] = []

        for rawGroup in rawGroups {
            let rawName = (rawGroup["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = rawName.isEmpty ? "未命名分组" : rawName
            let summary = (rawGroup["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var groupFileOrder: [String] = []
            var groupHunksByPath: [String: [Int]] = [:]

            func record(path: String, index: Int) {
                guard let validSet = validByPath[path], validSet.contains(index) else { return }
                let key = "\(path)#\(index)"
                guard assigned.insert(key).inserted else { return }
                if groupHunksByPath[path] == nil {
                    groupFileOrder.append(path)
                }
                groupHunksByPath[path, default: []].append(index)
            }

            if let rawFiles = rawGroup["files"] as? [[String: Any]] {
                for fileObj in rawFiles {
                    guard let path = (fileObj["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !path.isEmpty else { continue }
                    let rawIndices = (fileObj["hunkIndices"] as? [Any])
                        ?? (fileObj["hunk_indices"] as? [Any])
                        ?? []
                    for element in rawIndices {
                        if let idx = parseIntIndex(element) {
                            record(path: path, index: idx)
                        }
                    }
                }
            } else if let rawHunkIDs = rawGroup["hunks"] as? [String] {
                // Secondary tolerance if a model responds with `"hunks": ["path#0", ...]`.
                for hunkID in rawHunkIDs {
                    if let hash = hunkID.lastIndex(of: "#"),
                       let idx = Int(hunkID[hunkID.index(after: hash)...]) {
                        let path = String(hunkID[..<hash])
                        record(path: path, index: idx)
                    }
                }
            }

            let groupFiles: [AIHunkGroupFile] = groupFileOrder.compactMap { path in
                guard let indices = groupHunksByPath[path], !indices.isEmpty else { return nil }
                return makeGroupFile(path: path, sortedIndices: indices.sorted())
            }

            if !groupFiles.isEmpty {
                groups.append(AIHunkGroup(name: name, summary: summary, files: groupFiles))
            }
        }

        // Guarantee 100% coverage: append any missed hunks into a fallback "其他变更" group.
        var missingFiles: [AIHunkGroupFile] = []
        for path in canonicalFileOrder {
            guard let validIndices = validByPath[path] else { continue }
            let missing = validIndices
                .filter { !assigned.contains("\(path)#\($0)") }
                .sorted()
            if !missing.isEmpty {
                missingFiles.append(makeGroupFile(path: path, sortedIndices: missing))
            }
        }

        if !missingFiles.isEmpty {
            let fallbackSummary = source.isCommittable
                ? "其余未被 AI 显式归类的未提交变更。"
                : "其余未被 AI 显式归类的变更。"
            groups.append(AIHunkGroup(
                name: fallbackGroupName,
                summary: fallbackSummary,
                files: missingFiles
            ))
        }

        return AIHunkGroupingResult(
            groups: groups,
            totalHunks: validHunks.count,
            totalFiles: canonicalFileOrder.count,
            provider: provider,
            model: model,
            generatedAt: generatedAt
        )
    }

    private static func parseIntIndex(_ value: Any) -> Int? {
        if let intVal = value as? Int { return intVal >= 0 ? intVal : nil }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            let intVal = num.intValue
            return intVal >= 0 ? intVal : nil
        }
        if let str = value as? String, let intVal = Int(str.trimmingCharacters(in: .whitespaces)) {
            return intVal >= 0 ? intVal : nil
        }
        return nil
    }

    // MARK: - End-to-End Generation

    /// Collects hunks for `source` and asks the selected local AI agent to group them.
    static func generateGroups(
        repoRoot: URL,
        source: AIHunkGroupingSource = .workingTree,
        files: [FileChange]? = nil,
        filter: AIHunkGroupingFilter = AIHunkGroupingFilter(),
        provider: AgentProvider = .agy,
        model: String? = nil,
        persistSession: Bool = false,
        timeout: TimeInterval = defaultTimeout,
        service: LocalAgentService = .shared,
        onPromptReady: (@Sendable (String) -> Void)? = nil,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AIHunkGroupingResult {
        guard !AppEnvironment.isAppStore else {
            throw AIHunkGroupingError.unavailableInAppStore
        }
        try Task.checkCancellation()

        let hunks: [HunkDescriptor]
        switch source {
        case .workingTree:
            let candidateFiles: [FileChange]
            if let files {
                candidateFiles = files
            } else {
                let status = try await Git.status(in: repoRoot)
                candidateFiles = status.changes
            }
            guard !candidateFiles.isEmpty else {
                throw AIHunkGroupingError.noChangesToGroup
            }
            let filteredFiles = filter.apply(to: candidateFiles)
            guard !filteredFiles.isEmpty else {
                throw AIHunkGroupingError.noMatchingFilesAfterFilter(filter.summaryText)
            }
            hunks = try await collectHunks(repoRoot: repoRoot, source: .workingTree, files: filteredFiles)
        case .comparison, .commits:
            guard let files, !files.isEmpty else {
                throw AIHunkGroupingError.noChangesToGroup
            }
            let filteredFiles = filter.apply(to: files)
            guard !filteredFiles.isEmpty else {
                throw AIHunkGroupingError.noMatchingFilesAfterFilter(filter.summaryText)
            }
            hunks = try await collectHunks(repoRoot: repoRoot, source: source, files: filteredFiles)
        }
        guard !hunks.isEmpty else {
            throw AIHunkGroupingError.noChangesToGroup
        }

        let prompt = buildPrompt(hunks: hunks, source: source)
        onPromptReady?(prompt)
        let generated = try await service.generateWithSession(
            provider: provider,
            model: model,
            cwd: repoRoot,
            prompt: prompt,
            jsonSchema: responseJSONSchema,
            toolAccess: .disabled,
            resumeSessionID: nil,
            persistSession: persistSession,
            timeout: timeout,
            onEvent: onEvent
        )

        var parsed = try parseGroupingResponse(
            generated.text,
            validHunks: hunks,
            source: source,
            provider: provider,
            model: model
        )
        parsed.sessionID = generated.sessionID
        return parsed
    }

    // MARK: - Direct Group Commit Helpers

    /// Formats the default commit message for `group` using its generated `name` as subject
    /// and `summary` (separated by a blank line) as body when non-empty and distinct from `name`.
    static func defaultCommitMessage(for group: AIHunkGroup) -> String {
        let title = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return body }
        if body.isEmpty || body == title { return title }
        return "\(title)\n\n\(body)"
    }

    /// Computes a self-contained commit selection (`files` and per-file `excludedLines`) covering ONLY
    /// the hunks belonging to `group`, without mutating any external working-tree selection state.
    static func buildCommitSelection(
        for group: AIHunkGroup,
        allGroups: [AIHunkGroup]? = nil,
        allChanges: [FileChange],
        repoRoot: URL,
        isInitial: Bool = false
    ) async throws -> (files: [FileChange], excludedLines: [String: Set<ChangeLine>]) {
        try Task.checkCancellation()
        guard !group.files.isEmpty, !allChanges.isEmpty else {
            return ([], [:])
        }

        let changesByPath = Dictionary(allChanges.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        // Merge duplicate paths defensively while preserving group file order.
        var orderedPaths: [String] = []
        var filtersByPath: [String: GroupHunkFilter] = [:]
        for file in group.files {
            let fileFilter = file.hunkFilter(groupID: group.id, in: allGroups)
            if let existing = filtersByPath[file.path] {
                filtersByPath[file.path] = existing.merged(with: fileFilter)
            } else {
                orderedPaths.append(file.path)
                filtersByPath[file.path] = fileFilter
            }
        }

        var selectedFiles: [FileChange] = []
        selectedFiles.reserveCapacity(orderedPaths.count)
        var excludedLines: [String: Set<ChangeLine>] = [:]

        for path in orderedPaths {
            try Task.checkCancellation()
            guard let change = changesByPath[path],
                  let filter = filtersByPath[path] else { continue }

            if case .subset(let indices, _) = filter, indices.isEmpty {
                continue
            }

            if filter == .all {
                selectedFiles.append(change)
                continue
            }

            // Submodules, initial (unborn) repos, added, untracked, and deleted files are single-hunk whole-file commits.
            if isInitial || change.isSubmodule
                || change.kind == .added || change.kind == .untracked || change.kind == .deleted {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            // Read HEAD and working-tree bytes using the same strategy as `collectHunks` / `WorkingTree.partialSides`.
            guard let oldData = await Git.blob(rev: "HEAD", path: change.oldPath ?? change.path, in: repoRoot) else {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            if oldData.count > defaultMaxInspectableFileBytes {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            let url = repoRoot.appendingPathComponent(change.path)
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeRegular else {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
            if fileSize > defaultMaxInspectableFileBytes {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            guard let newData = try? Data(contentsOf: url) else {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            if TextCodec.looksBinary(oldData) || TextCodec.looksBinary(newData)
                || HunkPatch.isUTF16(oldData) || HunkPatch.isUTF16(newData) {
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            guard let hunks = await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: false),
                  !hunks.isEmpty else {
                // Pure rename, mode/metadata change, or undiffable fallback -> single file-level hunk at index 0.
                if filter.includesSingleFallbackHunk {
                    selectedFiles.append(change)
                }
                continue
            }

            let validWanted = filter.resolved(for: hunks).includedRawIndices.filter { hunks.indices.contains($0) }
            guard !validWanted.isEmpty else { continue }

            selectedFiles.append(change)

            // When all raw hunks of the file belong to this group, commit the whole file without exclusions.
            if validWanted.count == hunks.count {
                continue
            }

            let oldLines = TextCodec.splitLines(TextCodec.decode(oldData))
            let newLines = TextCodec.splitLines(TextCodec.decode(newData))
            var excluded = Set<ChangeLine>()
            for (index, hunk) in hunks.enumerated() where !validWanted.contains(index) {
                for line in hunk.leftStart..<min(hunk.leftStart + hunk.leftCount, oldLines.count) {
                    excluded.insert(ChangeLine(removed: true, line: line, text: oldLines[line]))
                }
                for line in hunk.rightStart..<min(hunk.rightStart + hunk.rightCount, newLines.count) {
                    excluded.insert(ChangeLine(removed: false, line: line, text: newLines[line]))
                }
            }
            if !excluded.isEmpty {
                excludedLines[change.path] = excluded
            }
        }

        return (selectedFiles, excludedLines)
    }

    /// Removes `groupID` after it is committed and shifts 0-based hunk indices in remaining groups
    /// for any files shared with the committed group so they align with the new HEAD.
    /// Returns `nil` when no remaining groups have hunks left.
    static func resultAfterCommitting(
        groupID: UUID,
        in result: AIHunkGroupingResult
    ) -> AIHunkGroupingResult? {
        guard let committedGroup = result.groups.first(where: { $0.id == groupID }) else {
            return result.groups.isEmpty ? nil : result
        }

        var committedByPath: [String: Set<Int>] = [:]
        var committedHasCompleteSpansByPath: [String: Bool] = [:]
        var committedSpansByPath: [String: [AIHunkSpan]] = [:]
        for file in committedGroup.files {
            committedByPath[file.path, default: []].formUnion(file.hunkIndices)
            if let spans = file.hunkSpans, spans.count == file.hunkIndices.count {
                if committedHasCompleteSpansByPath[file.path] == nil {
                    committedHasCompleteSpansByPath[file.path] = true
                    committedSpansByPath[file.path] = spans
                } else if committedHasCompleteSpansByPath[file.path] == true {
                    committedSpansByPath[file.path, default: []].append(contentsOf: spans)
                }
            } else {
                committedHasCompleteSpansByPath[file.path] = false
                committedSpansByPath.removeValue(forKey: file.path)
            }
        }

        var remainingGroups: [AIHunkGroup] = []
        remainingGroups.reserveCapacity(max(0, result.groups.count - 1))

        for group in result.groups where group.id != groupID {
            var updatedFiles: [AIHunkGroupFile] = []
            updatedFiles.reserveCapacity(group.files.count)

            for file in group.files {
                guard let committedIndices = committedByPath[file.path], !committedIndices.isEmpty else {
                    if !file.hunkIndices.isEmpty {
                        updatedFiles.append(file)
                    }
                    continue
                }

                let fileHasCompleteSpans = file.hunkSpans?.count == file.hunkIndices.count
                let canShiftSpans = fileHasCompleteSpans && (committedHasCompleteSpansByPath[file.path] == true)
                let committedSpans = committedSpansByPath[file.path] ?? []

                var shiftedByIndex: [Int: AIHunkSpan?] = [:]
                for (pos, idx) in file.hunkIndices.enumerated() where !committedIndices.contains(idx) {
                    let shift = committedIndices.reduce(0) { $0 + ($1 < idx ? 1 : 0) }
                    let adjusted = idx - shift
                    guard adjusted >= 0 else { continue }
                    if shiftedByIndex[adjusted] != nil { continue }
                    var adjustedSpan: AIHunkSpan?
                    if canShiftSpans, let span = file.hunkSpans?[pos] {
                        let lineDelta = committedSpans.reduce(0) { acc, c in
                            let precedes = c.oldStart < span.oldStart
                                || (c.oldStart == span.oldStart && c.newStart < span.newStart)
                            return precedes ? acc + (c.newCount - c.oldCount) : acc
                        }
                        adjustedSpan = AIHunkSpan(
                            oldStart: max(0, span.oldStart + lineDelta),
                            oldCount: span.oldCount,
                            newStart: span.newStart,
                            newCount: span.newCount
                        )
                    }
                    shiftedByIndex[adjusted] = adjustedSpan
                }

                let uniqueSorted = shiftedByIndex.keys.sorted()
                if !uniqueSorted.isEmpty {
                    let shiftedSpans: [AIHunkSpan]? = canShiftSpans
                        ? uniqueSorted.compactMap { shiftedByIndex[$0] ?? nil }
                        : nil
                    updatedFiles.append(AIHunkGroupFile(
                        path: file.path,
                        hunkIndices: uniqueSorted,
                        coversWholeFile: file.coversWholeFile,
                        hunkSpans: shiftedSpans?.count == uniqueSorted.count ? shiftedSpans : nil
                    ))
                }
            }

            if !updatedFiles.isEmpty {
                remainingGroups.append(AIHunkGroup(
                    id: group.id,
                    name: group.name,
                    summary: group.summary,
                    files: updatedFiles
                ))
            }
        }

        return rebuildResult(from: remainingGroups, basedOn: result)
    }

    /// Removes `groupID` after manual deletion without shifting hunk indices of remaining groups.
    /// Returns `nil` when no groups remain.
    static func resultAfterDeleting(
        groupID: UUID,
        in result: AIHunkGroupingResult
    ) -> AIHunkGroupingResult? {
        let deletedPaths = Set(
            result.groups.first(where: { $0.id == groupID })?.files.map(\.path) ?? []
        )
        let remainingGroups = result.groups.compactMap { group -> AIHunkGroup? in
            guard group.id != groupID else { return nil }
            guard !deletedPaths.isEmpty else { return group }
            let pinnedFiles = group.files.map { file in
                if file.coversWholeFile == nil,
                   deletedPaths.contains(file.path),
                   !file.hunkIndices.isEmpty,
                   file.hunkIndices.enumerated().allSatisfy({ $0.offset == $0.element }) {
                    return AIHunkGroupFile(
                        path: file.path,
                        hunkIndices: file.hunkIndices,
                        coversWholeFile: false,
                        hunkSpans: file.hunkSpans
                    )
                }
                return file
            }
            return AIHunkGroup(
                id: group.id,
                name: group.name,
                summary: group.summary,
                files: pinnedFiles
            )
        }
        return rebuildResult(from: remainingGroups, basedOn: result)
    }

    /// Removes all entries matching `paths` (for example after committing whole files from the Changes tab),
    /// dropping groups that become empty. Returns `nil` when no groups remain.
    static func resultAfterRemovingFiles(
        _ paths: Set<String>,
        in result: AIHunkGroupingResult
    ) -> AIHunkGroupingResult? {
        guard !paths.isEmpty else {
            return result.groups.isEmpty ? nil : result
        }

        var remainingGroups: [AIHunkGroup] = []
        remainingGroups.reserveCapacity(result.groups.count)

        for group in result.groups {
            let keptFiles = group.files.filter { !paths.contains($0.path) && !$0.hunkIndices.isEmpty }
            if !keptFiles.isEmpty {
                remainingGroups.append(AIHunkGroup(
                    id: group.id,
                    name: group.name,
                    summary: group.summary,
                    files: keptFiles
                ))
            }
        }

        return rebuildResult(from: remainingGroups, basedOn: result)
    }

    private static func rebuildResult(
        from groups: [AIHunkGroup],
        basedOn base: AIHunkGroupingResult
    ) -> AIHunkGroupingResult? {
        guard !groups.isEmpty else { return nil }
        let totalHunks = groups.reduce(0) { $0 + $1.hunkCount }
        let totalFiles = Set(groups.flatMap { $0.files.map(\.path) }).count
        return AIHunkGroupingResult(
            groups: groups,
            totalHunks: totalHunks,
            totalFiles: totalFiles,
            provider: base.provider,
            model: base.model,
            generatedAt: base.generatedAt
        )
    }
}
