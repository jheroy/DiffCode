import Foundation

// MARK: - Errors & Models

/// Errors thrown while collecting changes, generating an AI code review report, or writing it to disk.
enum AIReviewError: Error, LocalizedError, Equatable, Sendable {
    case unavailableInAppStore
    case noChangesToReview
    case emptyResponse
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailableInAppStore:
            return L("AI code review is unavailable in the Mac App Store edition.",
                     "Mac App Store 版本不支持 AI 代码审查。")
        case .noChangesToReview:
            return L("There are no changes to review.",
                     "当前没有可审查的变更。")
        case .emptyResponse:
            return L("AI returned an empty code review report.",
                     "AI 返回的代码审查报告为空。")
        case .writeFailed(let detail):
            return L("Failed to save review report: \(detail)",
                     "保存代码审查报告失败：\(detail)")
        }
    }
}

/// Live repository HEAD/branch context supplied when reviewing changes.
struct AIReviewRepoContext: Equatable, Sendable {
    var branch: String?
    var headOID: String?

    init(branch: String? = nil, headOID: String? = nil) {
        self.branch = branch
        self.headOID = headOID
    }
}

/// Target scope for an AI code review generation pass.
enum AIReviewScope: Sendable {
    case workingTree(
        files: [FileChange],
        excludedLines: [String: Set<ChangeLine>],
        isInitial: Bool,
        isPartialSelection: Bool
    )
    case comparison(AIHunkGroupingSource.ComparisonSource, files: [FileChange])
    case group(
        group: AIHunkGroup,
        allGroups: [AIHunkGroup],
        source: AIHunkGroupingSource,
        files: [FileChange],
        isInitial: Bool
    )
    case session(
        source: AIHunkGroupingSource,
        groups: [AIHunkGroup],
        files: [FileChange],
        isInitial: Bool
    )

    var displayTitle: String {
        switch self {
        case .workingTree(_, _, _, let isPartial):
            return isPartial
                ? L("Selected Working Tree Changes", "工作区已勾选变更")
                : L("Working Tree Changes", "工作区未提交变更")
        case .comparison(let comp, _):
            if comp.isStash {
                return L("Stash: \(comp.title)", "Stash：\(comp.title)")
            }
            if let headTitle = comp.headTitle {
                return "\(comp.title) → \(headTitle)"
            }
            return comp.forkPoint
                ? L("Since fork from \(comp.title) → Working Tree", "自与 \(comp.title) 分叉 → 工作区")
                : L("Compare \(comp.title) → Working Tree", "对比 \(comp.title) → 工作区")
        case .group(let group, _, _, _, _):
            let trimmed = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? L("AI Group", "AI 分组") : trimmed
        case .session(let source, _, _, _):
            return L("Group Session: \(source.detailTitle)", "分组集：\(source.detailTitle)")
        }
    }

    var filenameSlug: String {
        switch self {
        case .workingTree(_, _, _, let isPartial):
            return isPartial ? "working-tree-selected" : "working-tree"
        case .comparison(let comp, _):
            return comp.isStash ? "stash-\(comp.title)" : "compare-\(comp.title)"
        case .group(let group, _, _, _, _):
            return "group-\(group.name)"
        case .session(let source, _, _, _):
            return "session-\(source.tabTitle)"
        }
    }

    private struct ScopedCommitsInfo {
        let commits: AIHunkGroupingSource.CommitsSource
        let totalSelectedCount: Int
        let snapshotHeadHash: String?
    }

    private static func scopedCommitsInfo(
        for group: AIHunkGroup,
        source commits: AIHunkGroupingSource.CommitsSource,
        resolvedHashes: [String]? = nil
    ) -> ScopedCommitsInfo {
        let total = commits.commitHashes.count
        let groupPaths = Set(group.files.map(\.path))
        let filteredSteps = commits.fileSteps.filter { groupPaths.contains($0.key) }

        if let resolvedHashes {
            let allowed = Set(resolvedHashes)
            let filtered = commits.commitHashes.filter { allowed.contains($0) }
            if !filtered.isEmpty {
                let narrowed = filtered.count < total
                let singleSubject = filtered.count == 1 && !narrowed ? commits.primarySubject : nil
                let scoped = AIHunkGroupingSource.CommitsSource(
                    commitHashes: filtered,
                    oldestParentHash: commits.oldestParentHash,
                    isNonContiguous: narrowed ? (filtered.count > 1 ? commits.isNonContiguous : false) : commits.isNonContiguous,
                    primarySubject: singleSubject,
                    skippedMergeCount: narrowed ? 0 : commits.skippedMergeCount,
                    fileSteps: filteredSteps
                )
                return ScopedCommitsInfo(
                    commits: scoped,
                    totalSelectedCount: total,
                    snapshotHeadHash: narrowed ? commits.commitHashes.first : nil
                )
            }
        }

        if commits.isNonContiguous && !commits.fileSteps.isEmpty {
            var matchingHashes: Set<String> = []
            var matchedSteps: [FileCommitStep] = []
            for path in groupPaths {
                if let steps = commits.fileSteps[path] {
                    for step in steps {
                        matchingHashes.insert(step.hash)
                        matchedSteps.append(step)
                    }
                }
            }
            let filtered = commits.commitHashes.filter { matchingHashes.contains($0) }
            if !filtered.isEmpty {
                let narrowed = filtered.count < total
                if filtered.count == 1, let onlyHash = filtered.first {
                    let onlyParent = matchedSteps.first(where: { $0.hash == onlyHash })?.parent
                    let scoped = AIHunkGroupingSource.CommitsSource(
                        commitHashes: filtered,
                        oldestParentHash: onlyParent,
                        isNonContiguous: false,
                        primarySubject: narrowed ? nil : commits.primarySubject,
                        skippedMergeCount: 0,
                        fileSteps: filteredSteps
                    )
                    return ScopedCommitsInfo(
                        commits: scoped,
                        totalSelectedCount: total,
                        snapshotHeadHash: nil
                    )
                }
                let scoped = AIHunkGroupingSource.CommitsSource(
                    commitHashes: filtered,
                    oldestParentHash: nil,
                    isNonContiguous: true,
                    primarySubject: nil,
                    skippedMergeCount: narrowed ? 0 : commits.skippedMergeCount,
                    fileSteps: filteredSteps
                )
                return ScopedCommitsInfo(
                    commits: scoped,
                    totalSelectedCount: total,
                    snapshotHeadHash: nil
                )
            }
        }

        return ScopedCommitsInfo(commits: commits, totalSelectedCount: total, snapshotHeadHash: nil)
    }

    /// Returns the commit hashes that will actually be listed in the prompt context (up to 50),
    /// applying `.group` file-touch filtering when applicable.
    func commitHashesForContextDisplay(resolvedGroupCommitHashes: [String]? = nil) -> [String] {
        switch self {
        case .workingTree, .comparison:
            return []
        case .group(let group, _, .commits(let commits), _, _):
            let info = Self.scopedCommitsInfo(
                for: group,
                source: commits,
                resolvedHashes: resolvedGroupCommitHashes
            )
            return Array(info.commits.commitHashes.prefix(50))
        case .group:
            return []
        case .session(.commits(let commits), _, _, _):
            return Array(commits.commitHashes.prefix(50))
        case .session:
            return []
        }
    }

    var promptContextLines: [String] {
        promptContextLines()
    }

    func promptContextLines(
        repoContext: AIReviewRepoContext = .init(),
        isChinese: Bool = true,
        resolvedGroupCommitHashes: [String]? = nil,
        commitSubjects: [String: String] = [:]
    ) -> [String] {
        var lines: [String] = []
        let source: AIHunkGroupingSource
        let isInitialRepo: Bool
        var scopedCommits: ScopedCommitsInfo? = nil

        switch self {
        case .workingTree(let files, _, let isInitial, let isPartial):
            source = .workingTree
            isInitialRepo = isInitial
            if isChinese {
                lines.append(isPartial
                    ? "审查范围：工作区中已勾选准备提交的变更（共 \(files.count) 个文件）。"
                    : "审查范围：工作区全部未提交变更（共 \(files.count) 个文件）。")
            } else {
                lines.append(isPartial
                    ? "Review scope: selected working-tree changes staged for commit (\(files.count) file(s))."
                    : "Review scope: all uncommitted working-tree changes (\(files.count) file(s)).")
            }

        case .comparison(let comp, let files):
            source = .comparison(comp)
            isInitialRepo = false
            if isChinese {
                if comp.isStash {
                    lines.append("审查范围：Stash「\(comp.title)」（共 \(files.count) 个文件）。")
                } else if let headTitle = comp.headTitle {
                    lines.append("审查范围：分支/提交对比 \(comp.title) → \(headTitle)（共 \(files.count) 个文件）。")
                } else {
                    lines.append("审查范围：与 \(comp.title) 对比当前工作区（共 \(files.count) 个文件）。")
                }
            } else {
                if comp.isStash {
                    lines.append("Review scope: Stash \"\(comp.title)\" (\(files.count) file(s)).")
                } else if let headTitle = comp.headTitle {
                    lines.append("Review scope: branch/commit comparison \(comp.title) → \(headTitle) (\(files.count) file(s)).")
                } else {
                    lines.append("Review scope: compare \(comp.title) → working tree (\(files.count) file(s)).")
                }
            }

        case .group(let group, _, let src, _, let isInitial):
            isInitialRepo = isInitial
            if case .commits(let commits) = src {
                let info = Self.scopedCommitsInfo(
                    for: group,
                    source: commits,
                    resolvedHashes: resolvedGroupCommitHashes
                )
                scopedCommits = info
                source = .commits(info.commits)
                if isChinese {
                    lines.append("审查范围：AI 逻辑分组「\(group.name)」")
                    if info.commits.commitHashes.count < info.totalSelectedCount {
                        lines.append("变更来源：本分组涉及 \(info.commits.commitHashes.count) 个提交（筛选自已选 \(info.totalSelectedCount) 个提交）")
                    } else {
                        lines.append("变更来源：\(source.detailTitle)")
                    }
                    let summary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        lines.append("分组摘要：\(summary)")
                    }
                } else {
                    lines.append("Review scope: AI logical group \"\(group.name)\"")
                    if info.commits.commitHashes.count < info.totalSelectedCount {
                        lines.append("Change source: \(info.commits.commitHashes.count) commit(s) touching this group (filtered from \(info.totalSelectedCount) selected)")
                    } else {
                        lines.append("Change source: \(source.detailTitle)")
                    }
                    let summary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        lines.append("Group summary: \(summary)")
                    }
                }
            } else {
                source = src
                if isChinese {
                    lines.append("审查范围：AI 逻辑分组「\(group.name)」")
                    lines.append("变更来源：\(src.detailTitle)")
                    let summary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        lines.append("分组摘要：\(summary)")
                    }
                } else {
                    lines.append("Review scope: AI logical group \"\(group.name)\"")
                    lines.append("Change source: \(src.detailTitle)")
                    let summary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        lines.append("Group summary: \(summary)")
                    }
                }
            }

        case .session(let src, let groups, _, let isInitial):
            source = src
            isInitialRepo = isInitial
            if isChinese {
                lines.append("审查范围：完整 AI 分组会话（\(src.detailTitle)，共 \(groups.count) 个逻辑分组）")
            } else {
                lines.append("Review scope: full AI grouping session (\(src.detailTitle), \(groups.count) logical group(s))")
            }
            for (index, group) in groups.prefix(12).enumerated() {
                let summary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let brief = summary.isEmpty ? "" : " — \(summary)"
                lines.append("  \(index + 1). \(group.name)\(brief)")
            }
            if groups.count > 12 {
                lines.append(isChinese
                    ? "  ... 其余 \(groups.count - 12) 个分组"
                    : "  ... and \(groups.count - 12) more group(s)")
            }
        }

        lines.append(contentsOf: Self.gitRevisionContextLines(
            for: source,
            isInitial: isInitialRepo,
            repoContext: repoContext,
            isChinese: isChinese,
            totalSelectedCommitCount: scopedCommits?.totalSelectedCount,
            snapshotHeadHash: scopedCommits?.snapshotHeadHash,
            commitSubjects: commitSubjects
        ))
        return lines
    }

    /// Concise Git revision summary rendered in the Markdown report metadata header.
    func revisionSummary(
        repoContext: AIReviewRepoContext = .init(),
        resolvedGroupCommitHashes: [String]? = nil
    ) -> String? {
        switch self {
        case .workingTree(_, _, let isInitial, _):
            return Self.revisionSummary(for: .workingTree, isInitial: isInitial, repoContext: repoContext)
        case .comparison(let comp, _):
            return Self.revisionSummary(for: .comparison(comp), isInitial: false, repoContext: repoContext)
        case .group(let group, _, let source, _, let isInitial):
            if case .commits(let commits) = source {
                let info = Self.scopedCommitsInfo(
                    for: group,
                    source: commits,
                    resolvedHashes: resolvedGroupCommitHashes
                )
                return Self.revisionSummary(for: .commits(info.commits), isInitial: isInitial, repoContext: repoContext)
            }
            return Self.revisionSummary(for: source, isInitial: isInitial, repoContext: repoContext)
        case .session(let source, _, _, let isInitial):
            return Self.revisionSummary(for: source, isInitial: isInitial, repoContext: repoContext)
        }
    }

    private static func revisionSummary(
        for source: AIHunkGroupingSource,
        isInitial: Bool,
        repoContext: AIReviewRepoContext
    ) -> String? {
        switch source {
        case .workingTree:
            guard !isInitial, let head = repoContext.headOID, !head.isEmpty else { return nil }
            if let branch = repoContext.branch, !branch.isEmpty {
                return "\(branch) @ \(head.prefix(7))"
            }
            return "HEAD \(head.prefix(7))"

        case .comparison(let comp):
            if comp.isStash {
                if let head = comp.headHash, !head.isEmpty {
                    return "\(comp.baseHash.prefix(7))..\(head.prefix(7))"
                }
                return String(comp.baseHash.prefix(7))
            }
            if let headHash = comp.headHash, !headHash.isEmpty {
                return "\(comp.baseHash.prefix(7))..\(headHash.prefix(7))"
            }
            if let head = repoContext.headOID, !head.isEmpty {
                return "\(comp.baseHash.prefix(7)) → WT (\(head.prefix(7)))"
            }
            return "\(comp.baseHash.prefix(7)) → WT"

        case .commits(let commits):
            if commits.commitHashes.count == 1, let sha = commits.commitHashes.first {
                return String(sha.prefix(7))
            }
            if !commits.isNonContiguous,
               let newest = commits.commitHashes.first,
               let oldest = commits.commitHashes.last {
                return "\(oldest.prefix(7))..\(newest.prefix(7))"
            }
            guard !commits.commitHashes.isEmpty else { return nil }
            let preview = commits.commitHashes.prefix(3).map { String($0.prefix(7)) }.joined(separator: ", ")
            let suffix = commits.commitHashes.count > 3 ? ", …" : ""
            return "\(commits.commitHashes.count) commits (\(preview)\(suffix))"
        }
    }

    private static func gitRevisionContextLines(
        for source: AIHunkGroupingSource,
        isInitial: Bool,
        repoContext: AIReviewRepoContext,
        isChinese: Bool,
        totalSelectedCommitCount: Int? = nil,
        snapshotHeadHash: String? = nil,
        commitSubjects: [String: String] = [:]
    ) -> [String] {
        var lines: [String] = []
        let maxListedCommits = 50

        func appendCommitList(_ hashes: [String], labelZh: String, labelEn: String) {
            let total = hashes.count
            lines.append(isChinese ? labelZh : labelEn)
            for (idx, sha) in hashes.prefix(maxListedCommits).enumerated() {
                if let subject = commitSubjects[sha], !subject.isEmpty {
                    lines.append("  \(idx + 1). \(sha)  \(subject)")
                } else {
                    lines.append("  \(idx + 1). \(sha)")
                }
            }
            if total > maxListedCommits {
                lines.append(isChinese
                    ? "  ... 其余 \(total - maxListedCommits) 个提交省略"
                    : "  ... and \(total - maxListedCommits) more commit(s) omitted")
            }
        }

        switch source {
        case .workingTree:
            if isInitial {
                lines.append(isChinese
                    ? "Git 基线：初始仓库（尚无 HEAD 提交），当前仅包含工作区未提交文件。"
                    : "Git baseline: initial repository (no HEAD commit yet); changes exist only in the working tree.")
            } else {
                let branchDesc = repoContext.branch.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (isChinese ? "(分离头指针 detached HEAD)" : "(detached HEAD)")
                let headSHA = repoContext.headOID.flatMap { $0.isEmpty ? nil : $0 } ?? "HEAD"
                if isChinese {
                    lines.append("当前分支：\(branchDesc)")
                    lines.append("当前 HEAD 提交号：\(headSHA)")
                    lines.append("查询提示：目标内容在磁盘工作区，可直接读取文件；基准版本可通过 `git show \(headSHA):<path>` 查询。")
                } else {
                    lines.append("Current branch: \(branchDesc)")
                    lines.append("Current HEAD commit SHA: \(headSHA)")
                    lines.append("Query hint: target changes are in the working tree on disk; inspect the base file with `git show \(headSHA):<path>`.")
                }
            }

        case .comparison(let comp):
            let distinctRef = (comp.targetRef != comp.title && comp.targetRef != comp.baseHash) ? comp.targetRef : nil
            if comp.isStash {
                if isChinese {
                    lines.append("Stash 名称：\(comp.title)")
                    lines.append("基准提交号（baseHash）：\(comp.baseHash)")
                    if let headHash = comp.headHash, !headHash.isEmpty {
                        lines.append("Stash 提交号（headHash）：\(headHash)")
                    }
                    if let untracked = comp.stashUntrackedHash, !untracked.isEmpty {
                        lines.append("Stash 未跟踪提交号（stashUntrackedHash）：\(untracked)")
                    }
                    let targetHint = comp.headHash ?? comp.baseHash
                    lines.append("查询提示：磁盘工作区与 Stash 快照可能不同；请用 `git show \(targetHint):<path>` 与 `git show \(comp.baseHash):<path>` 查询当时文件。")
                } else {
                    lines.append("Stash name: \(comp.title)")
                    lines.append("Base commit SHA (baseHash): \(comp.baseHash)")
                    if let headHash = comp.headHash, !headHash.isEmpty {
                        lines.append("Stash commit SHA (headHash): \(headHash)")
                    }
                    if let untracked = comp.stashUntrackedHash, !untracked.isEmpty {
                        lines.append("Stash untracked commit SHA (stashUntrackedHash): \(untracked)")
                    }
                    let targetHint = comp.headHash ?? comp.baseHash
                    lines.append("Query hint: working tree on disk may differ from the stash; query snapshots with `git show \(targetHint):<path>` and `git show \(comp.baseHash):<path>`.")
                }
            } else if let headHash = comp.headHash, !headHash.isEmpty {
                let refSuffix = distinctRef.map { " (ref: \($0))" } ?? ""
                let forkSuffix = comp.forkPoint ? (isChinese ? " [merge-base 分叉点]" : " [merge-base fork point]") : ""
                let headLabel = comp.headTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "(commit)"
                if isChinese {
                    lines.append("基准引用：\(comp.title)\(refSuffix)\(forkSuffix)")
                    lines.append("基准提交号（baseHash）：\(comp.baseHash)")
                    lines.append("目标引用：\(headLabel)")
                    lines.append("目标提交号（headHash）：\(headHash)")
                    lines.append("快照警告：当前磁盘工作区可能处于其他分支或提交；查询目标文件必须使用 `git show \(headHash):<path>`，查询基准文件使用 `git show \(comp.baseHash):<path>`。")
                } else {
                    lines.append("Base ref: \(comp.title)\(refSuffix)\(forkSuffix)")
                    lines.append("Base commit SHA (baseHash): \(comp.baseHash)")
                    lines.append("Target ref: \(headLabel)")
                    lines.append("Target commit SHA (headHash): \(headHash)")
                    lines.append("Snapshot warning: files on disk may belong to a different checkout; always inspect target files via `git show \(headHash):<path>` and base files via `git show \(comp.baseHash):<path>`.")
                }
            } else {
                let refSuffix = distinctRef.map { " (ref: \($0))" } ?? ""
                let forkSuffix = comp.forkPoint ? (isChinese ? " [merge-base 分叉点]" : " [merge-base fork point]") : ""
                let branchDesc = repoContext.branch.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (isChinese ? "(分离头指针 detached HEAD)" : "(detached HEAD)")
                let headSHA = repoContext.headOID.flatMap { $0.isEmpty ? nil : $0 }
                if isChinese {
                    lines.append("基准引用：\(comp.title)\(refSuffix)\(forkSuffix)")
                    lines.append("基准提交号（baseHash）：\(comp.baseHash)")
                    lines.append("目标范围：当前工作区（分支：\(branchDesc)" + (headSHA.map { "，HEAD 提交号：\($0)" } ?? "") + "）")
                    lines.append("查询提示：目标内容在磁盘工作区，基准历史版本请通过 `git show \(comp.baseHash):<path>` 查询。")
                } else {
                    lines.append("Base ref: \(comp.title)\(refSuffix)\(forkSuffix)")
                    lines.append("Base commit SHA (baseHash): \(comp.baseHash)")
                    lines.append("Target scope: current working tree (branch: \(branchDesc)" + (headSHA.map { ", HEAD SHA: \($0)" } ?? "") + ")")
                    lines.append("Query hint: target files live in the working tree on disk; inspect the base snapshot via `git show \(comp.baseHash):<path>`.")
                }
            }

        case .commits(let commits):
            let narrowedSuffixZh = (totalSelectedCommitCount.map { $0 > commits.commitHashes.count } ?? false)
                ? "（从已选 \(totalSelectedCommitCount!) 个提交中筛选出与本分组相关的提交）"
                : ""
            let narrowedSuffixEn = (totalSelectedCommitCount.map { $0 > commits.commitHashes.count } ?? false)
                ? " (filtered to commits touching this group from \(totalSelectedCommitCount!) selected)"
                : ""

            if commits.commitHashes.count == 1, let sha = commits.commitHashes.first {
                let parentDesc = commits.oldestParentHash.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (isChinese ? "(无父提交 / 根提交)" : "(no parent / root commit)")
                let resolvedSubject = commits.primarySubject.flatMap { $0.isEmpty ? nil : $0 } ?? commitSubjects[sha]
                let endpointSHA = snapshotHeadHash.flatMap { $0.isEmpty ? nil : $0 } ?? sha
                if isChinese {
                    lines.append("目标提交号（完整 SHA）：\(sha)\(narrowedSuffixZh)")
                    if let subject = resolvedSubject, !subject.isEmpty {
                        lines.append("提交标题：\(subject)")
                    }
                    if endpointSHA != sha {
                        lines.append("区间终点快照提交号：\(endpointSHA)")
                    }
                    lines.append("基准父提交号（parent SHA）：\(parentDesc)")
                    var hint = "快照警告：审查对象为历史提交，磁盘工作区可能已变更；请使用 `git show \(endpointSHA)` 或 `git show \(endpointSHA):<path>` 查询目标版本"
                    if let parent = commits.oldestParentHash, !parent.isEmpty {
                        hint += "，使用 `git show \(parent):<path>` 查询修改前版本。"
                    } else {
                        hint += "。"
                    }
                    lines.append(hint)
                } else {
                    lines.append("Target commit SHA: \(sha)\(narrowedSuffixEn)")
                    if let subject = resolvedSubject, !subject.isEmpty {
                        lines.append("Commit subject: \(subject)")
                    }
                    if endpointSHA != sha {
                        lines.append("Range end snapshot SHA: \(endpointSHA)")
                    }
                    lines.append("Base parent commit SHA: \(parentDesc)")
                    var hint = "Snapshot warning: reviewing a historical commit whose files may differ from disk; inspect it via `git show \(endpointSHA)` or `git show \(endpointSHA):<path>`"
                    if let parent = commits.oldestParentHash, !parent.isEmpty {
                        hint += " and the parent via `git show \(parent):<path>`."
                    } else {
                        hint += "."
                    }
                    lines.append(hint)
                }
            } else if !commits.isNonContiguous {
                let newest = snapshotHeadHash.flatMap { $0.isEmpty ? nil : $0 } ?? commits.commitHashes.first ?? "(unknown)"
                let oldest = commits.commitHashes.last ?? newest
                let parentDesc = commits.oldestParentHash.flatMap { $0.isEmpty ? nil : $0 }
                    ?? (isChinese ? "(无父提交 / 根提交)" : "(no parent / root commit)")
                let skipNote = commits.skippedMergeCount > 0
                    ? (isChinese ? "（已跳过 \(commits.skippedMergeCount) 个合并提交）" : " (\(commits.skippedMergeCount) merge commit(s) skipped)")
                    : ""
                if isChinese {
                    let headerPrefix = narrowedSuffixZh.isEmpty
                        ? "连续历史提交区间：共 \(commits.commitHashes.count) 个提交\(skipNote)"
                        : "本分组相关提交：共 \(commits.commitHashes.count) 个提交\(narrowedSuffixZh)\(skipNote)"
                    lines.append(headerPrefix)
                    lines.append("最新目标提交号（newest SHA）：\(newest)")
                    lines.append("最早涉及提交号（oldest SHA）：\(oldest)")
                    lines.append("区间基准父提交号（oldestParentHash）：\(parentDesc)")
                    appendCommitList(
                        commits.commitHashes,
                        labelZh: narrowedSuffixZh.isEmpty ? "完整提交列表（按最新 → 最早排列）：" : "本分组涉及提交列表（按最新 → 最早排列）：",
                        labelEn: narrowedSuffixEn.isEmpty ? "Full commit SHAs (newest → oldest):" : "Group commit SHAs (newest → oldest):"
                    )
                    if let parent = commits.oldestParentHash, !parent.isEmpty {
                        lines.append("快照警告：请使用 `git show \(newest):<path>` 查询区间终点文件、`git show \(parent):<path>` 查询区间起点前文件，或用 `git log --oneline \(parent)..\(newest)` 追溯提交明细。")
                    } else {
                        lines.append("快照警告：请使用 `git show \(newest):<path>` 查询区间终点文件，或用 `git show <sha>` 查看任意提交详情。")
                    }
                } else {
                    let headerPrefix = narrowedSuffixEn.isEmpty
                        ? "Contiguous historical commit range: \(commits.commitHashes.count) commit(s)\(skipNote)"
                        : "Group-relevant commits: \(commits.commitHashes.count) commit(s)\(narrowedSuffixEn)\(skipNote)"
                    lines.append(headerPrefix)
                    lines.append("Newest target commit SHA: \(newest)")
                    lines.append("Oldest touching commit SHA: \(oldest)")
                    lines.append("Range base parent SHA (oldestParentHash): \(parentDesc)")
                    appendCommitList(
                        commits.commitHashes,
                        labelZh: narrowedSuffixZh.isEmpty ? "完整提交列表（按最新 → 最早排列）：" : "本分组涉及提交列表（按最新 → 最早排列）：",
                        labelEn: narrowedSuffixEn.isEmpty ? "Full commit SHAs (newest → oldest):" : "Group commit SHAs (newest → oldest):"
                    )
                    if let parent = commits.oldestParentHash, !parent.isEmpty {
                        lines.append("Snapshot warning: inspect range end files via `git show \(newest):<path>`, base files via `git show \(parent):<path>`, or commit details via `git log --oneline \(parent)..\(newest)`.")
                    } else {
                        lines.append("Snapshot warning: inspect range end files via `git show \(newest):<path>` or individual commits via `git show <sha>`.")
                    }
                }
            } else {
                let skipNote = commits.skippedMergeCount > 0
                    ? (isChinese ? "（已跳过 \(commits.skippedMergeCount) 个合并提交）" : " (\(commits.skippedMergeCount) merge commit(s) skipped)")
                    : ""
                if isChinese {
                    lines.append("非连续多选历史提交：共 \(commits.commitHashes.count) 个提交\(narrowedSuffixZh)\(skipNote)")
                    appendCommitList(
                        commits.commitHashes,
                        labelZh: narrowedSuffixZh.isEmpty ? "已选完整提交列表（按最新 → 最早排列）：" : "本分组涉及提交列表（按最新 → 最早排列）：",
                        labelEn: narrowedSuffixEn.isEmpty ? "Selected commit SHAs (newest → oldest):" : "Group commit SHAs (newest → oldest):"
                    )
                    lines.append("查询提示：每个涉及文件的标题已标注其对应的 `[commits: <SHA>, ...]`；磁盘工作区可能与历史提交不同，请优先用 `git show <SHA>` 或 `git show <SHA>:<path>` 查询对应提交快照。")
                } else {
                    lines.append("Non-contiguous historical commit selection: \(commits.commitHashes.count) commit(s)\(narrowedSuffixEn)\(skipNote)")
                    appendCommitList(
                        commits.commitHashes,
                        labelZh: narrowedSuffixZh.isEmpty ? "已选完整提交列表（按最新 → 最早排列）：" : "本分组涉及提交列表（按最新 → 最早排列）：",
                        labelEn: narrowedSuffixEn.isEmpty ? "Selected commit SHAs (newest → oldest):" : "Group commit SHAs (newest → oldest):"
                    )
                    lines.append("Query hint: each file header below lists `[commits: <SHA>, ...]`; always use `git show <SHA>` or `git show <SHA>:<path>` rather than assuming disk matches historical snapshots.")
                }
            }
        }

        return lines
    }
}

/// Collected diff section for one changed file ready for review prompt assembly.
struct AIReviewDiffFile: Equatable, Sendable {
    let path: String
    let oldPath: String?
    let kind: FileChange.Kind
    let summaryLine: String
    let header: String
    let body: String
    let hunkCount: Int
    /// First 1-based line number suitable for linking in `diffcode://` (nil for deleted/binary/metadata changes).
    let firstTargetLine: Int?
}

/// Collected context-rich diff payload across all files in an `AIReviewScope`.
struct AIReviewPayload: Equatable, Sendable {
    let title: String
    let scopeContextLines: [String]
    let files: [AIReviewDiffFile]
    let totalHunks: Int
    let revisionSummary: String?

    init(
        title: String,
        scopeContextLines: [String],
        files: [AIReviewDiffFile],
        totalHunks: Int,
        revisionSummary: String? = nil
    ) {
        self.title = title
        self.scopeContextLines = scopeContextLines
        self.files = files
        self.totalHunks = totalHunks
        self.revisionSummary = revisionSummary
    }

    var fileCount: Int { files.count }
    var firstFilePath: String? { files.first?.path }
    var firstTargetLine: Int? {
        files.first(where: { $0.firstTargetLine != nil })?.firstTargetLine
    }
}

/// Final generated Markdown review report saved to disk.
struct AIReviewResult: Equatable, Sendable {
    let markdown: String
    let fileURL: URL
    let provider: AgentProvider
    let model: String?
    let fileCount: Int
    let hunkCount: Int
    let generatedAt: Date
    let sessionID: String?

    init(
        markdown: String,
        fileURL: URL,
        provider: AgentProvider,
        model: String?,
        fileCount: Int,
        hunkCount: Int,
        generatedAt: Date,
        sessionID: String? = nil
    ) {
        self.markdown = markdown
        self.fileURL = fileURL
        self.provider = provider
        self.model = model
        self.fileCount = fileCount
        self.hunkCount = hunkCount
        self.generatedAt = generatedAt
        self.sessionID = sessionID
    }
}

// MARK: - AI Code Reviewer

/// Collects context-rich diffs with explicit 1-based line numbers, invokes a local AI agent
/// to produce a thorough Markdown review (with conditional Mermaid diagrams & `diffcode://` magic links),
/// and saves the report to disk for opening in the user's default Markdown application.
enum AICodeReviewer {
    /// Context lines shown before and after each diff hunk.
    static let defaultContextLines = 3
    /// Maximum file size read into memory for line-level diff extraction (2 MB).
    static let defaultMaxInspectableFileBytes = 2 * 1024 * 1024
    /// Total diff body budget inside the review prompt (128 KB).
    static let defaultMaxDiffBytes = 128 * 1024
    /// Maximum characters retained per individual diff line in the prompt.
    static let defaultMaxLineCharacters = 280
    /// Default per-activity idle timeout (seconds) for AI code review generation.
    static let defaultTimeout: TimeInterval = 300
    /// Maximum number of generated Markdown reports retained per repository directory.
    static let defaultMaxRetainedFiles = 50

    // MARK: - Context-Rich Diff Collection

    /// Collects context-rich unified diffs with explicit `[L<line>]` 1-based line numbers for `scope`.
    static func collectDiff(
        repoRoot: URL,
        scope: AIReviewScope,
        repoContext: AIReviewRepoContext? = nil,
        isChinese: Bool = true,
        contextLines: Int = defaultContextLines,
        maxInspectableFileBytes: Int = defaultMaxInspectableFileBytes
    ) async throws -> AIReviewPayload {
        try Task.checkCancellation()

        var resolvedContext = repoContext ?? AIReviewRepoContext()
        let involvesWorkingTree: Bool
        switch scope {
        case .workingTree(_, _, let isInitial, _):
            involvesWorkingTree = !isInitial
        case .comparison(let comp, _):
            involvesWorkingTree = comp.headHash == nil && !comp.isStash
        case .group(_, _, let source, _, let isInitial),
             .session(let source, _, _, let isInitial):
            switch source {
            case .workingTree:
                involvesWorkingTree = !isInitial
            case .comparison(let comp):
                involvesWorkingTree = comp.headHash == nil && !comp.isStash
            case .commits:
                involvesWorkingTree = false
            }
        }
        if involvesWorkingTree && (resolvedContext.headOID?.isEmpty ?? true) {
            resolvedContext.headOID = await Git.resolveCommit("HEAD", in: repoRoot)
        }

        let entries: [(change: FileChange, filter: GroupHunkFilter?, excluded: Set<ChangeLine>, source: AIHunkGroupingSource, isInitial: Bool)]
        switch scope {
        case .workingTree(let files, let excludedLines, let isInitial, _):
            entries = files.map { change in
                (change, nil, excludedLines[change.path] ?? [], .workingTree, isInitial)
            }

        case .comparison(let comp, let files):
            let source = AIHunkGroupingSource.comparison(comp)
            entries = files.map { change in
                (change, nil, [], source, false)
            }

        case .group(let group, let allGroups, let source, let files, let isInitial):
            let changesByPath = Dictionary(files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
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
            entries = orderedPaths.compactMap { path in
                guard let filter = filtersByPath[path] else { return nil }
                if case .subset(let indices, _) = filter, indices.isEmpty {
                    return nil
                }
                let change: FileChange
                if let live = changesByPath[path] {
                    change = live
                } else if !source.isCommittable {
                    change = FileChange(path: path, oldPath: nil, kind: .modified, additions: nil, deletions: nil)
                } else {
                    return nil
                }
                return (change, filter, [], source, isInitial)
            }

        case .session(let source, _, let files, let isInitial):
            entries = files.map { change in
                (change, nil, [], source, isInitial)
            }
        }

        guard !entries.isEmpty else {
            throw AIReviewError.noChangesToReview
        }

        var buckets = [AIReviewDiffFile?](repeating: nil, count: entries.count)
        let maxConcurrency = 8

        try await withThrowingTaskGroup(of: (Int, AIReviewDiffFile?).self) { group in
            for (index, entry) in entries.enumerated() {
                if index >= maxConcurrency, let done = try await group.next() {
                    buckets[done.0] = done.1
                }
                try Task.checkCancellation()
                group.addTask {
                    try Task.checkCancellation()
                    let fileDiff = await buildReviewFileDiff(
                        for: entry.change,
                        source: entry.source,
                        isInitial: entry.isInitial,
                        groupFilter: entry.filter,
                        excludedLines: entry.excluded,
                        in: repoRoot,
                        contextLines: max(0, contextLines),
                        maxInspectableFileBytes: maxInspectableFileBytes
                    )
                    return (index, fileDiff)
                }
            }
            for try await done in group {
                buckets[done.0] = done.1
            }
        }

        let collected = buckets.compactMap { $0 }
        guard !collected.isEmpty else {
            throw AIReviewError.noChangesToReview
        }

        var resolvedGroupCommitHashes: [String]? = nil
        if case .group(let group, _, .commits(let commits), let files, _) = scope,
           !commits.isNonContiguous,
           commits.commitHashes.count > 1 {
            resolvedGroupCommitHashes = await filterContiguousCommits(
                for: group,
                source: commits,
                files: files,
                in: repoRoot
            )
        }
        let listedHashes = scope.commitHashesForContextDisplay(resolvedGroupCommitHashes: resolvedGroupCommitHashes)
        let commitSubjects = await fetchCommitSubjects(for: listedHashes, in: repoRoot)

        let totalHunks = collected.reduce(0) { $0 + $1.hunkCount }
        return AIReviewPayload(
            title: scope.displayTitle,
            scopeContextLines: scope.promptContextLines(
                repoContext: resolvedContext,
                isChinese: isChinese,
                resolvedGroupCommitHashes: resolvedGroupCommitHashes,
                commitSubjects: commitSubjects
            ),
            files: collected,
            totalHunks: totalHunks,
            revisionSummary: scope.revisionSummary(
                repoContext: resolvedContext,
                resolvedGroupCommitHashes: resolvedGroupCommitHashes
            )
        )
    }

    private static func filterContiguousCommits(
        for group: AIHunkGroup,
        source commits: AIHunkGroupingSource.CommitsSource,
        files: [FileChange],
        in repoRoot: URL
    ) async -> [String]? {
        let groupPaths = Set(group.files.map(\.path))
        guard !groupPaths.isEmpty, let newest = commits.commitHashes.first else {
            return nil
        }
        var pathSet = groupPaths
        for file in files where groupPaths.contains(file.path) {
            if let oldPath = file.oldPath, !oldPath.isEmpty {
                pathSet.insert(oldPath)
            }
        }
        let sortedPaths = pathSet.sorted()
        let allowed = Set(commits.commitHashes)
        let rangeSpec = commits.oldestParentHash.flatMap { $0.isEmpty ? nil : "\($0)..\(newest)" } ?? newest

        func runFilteredLog(excludeMerges: Bool) async -> [String] {
            var args = ["log", "--format=%H"]
            if excludeMerges {
                args.append("--no-merges")
            }
            args.append(rangeSpec)
            args.append("--")
            args.append(contentsOf: sortedPaths)
            guard let data = try? await Git.run(args, in: repoRoot) else {
                return []
            }
            let matched = Set(
                String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
            return commits.commitHashes.filter { allowed.contains($0) && matched.contains($0) }
        }

        let nonMergeFiltered = await runFilteredLog(excludeMerges: true)
        if !nonMergeFiltered.isEmpty {
            return nonMergeFiltered
        }
        let allFiltered = await runFilteredLog(excludeMerges: false)
        return allFiltered.isEmpty ? nil : allFiltered
    }

    private static func fetchCommitSubjects(for hashes: [String], in repoRoot: URL) async -> [String: String] {
        guard !hashes.isEmpty else { return [:] }
        guard let data = try? await Git.run(
            ["log", "--no-walk=unsorted", "--format=%H%x09%s"] + hashes,
            in: repoRoot
        ) else {
            return [:]
        }
        var subjects: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let tabIdx = line.firstIndex(of: "\t") else { continue }
            let hash = String(line[..<tabIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = String(line[line.index(after: tabIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty && !subject.isEmpty {
                subjects[hash] = subject
            }
        }
        return subjects
    }

    private enum LoadedSides {
        case bytes(old: Data?, new: Data?)
        case fallback(note: String)
    }

    private static func loadSides(
        for change: FileChange,
        source: AIHunkGroupingSource,
        isInitial: Bool,
        in repoRoot: URL,
        maxInspectableFileBytes: Int
    ) async -> LoadedSides {
        if change.isSubmodule {
            return .fallback(note: "[submodule]")
        }

        var oldData: Data?
        var newData: Data?

        switch source {
        case .workingTree:
            let wantOld = !isInitial && change.kind != .added && change.kind != .untracked
            let wantNew = change.kind != .deleted
            if wantOld {
                oldData = await Git.blob(rev: "HEAD", path: change.oldPath ?? change.path, in: repoRoot)
            }
            if wantNew {
                switch readWorkingTreeBytes(for: change, in: repoRoot, maxInspectableFileBytes: maxInspectableFileBytes) {
                case .data(let data): newData = data
                case .fallback(let note): return .fallback(note: note)
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
                        case .fallback(let note): return .fallback(note: note)
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
            return .fallback(note: "[large old file: \(oldData.count.byteSizeString)]")
        }
        if let newData, newData.count > maxInspectableFileBytes {
            return .fallback(note: "[large file: \(newData.count.byteSizeString)]")
        }
        if (oldData.map(TextCodec.looksBinary) ?? false) || (newData.map(TextCodec.looksBinary) ?? false) {
            let size = newData?.count ?? oldData?.count ?? 0
            return .fallback(note: "[binary file: \(size.byteSizeString)]")
        }
        if oldData == nil && newData == nil {
            return .fallback(note: "[\(change.kind.rawValue) file]")
        }
        return .bytes(old: oldData, new: newData)
    }

    private enum WorktreeReadResult {
        case data(Data)
        case fallback(String)
    }

    private static func readWorkingTreeBytes(
        for change: FileChange,
        in repoRoot: URL,
        maxInspectableFileBytes: Int
    ) -> WorktreeReadResult {
        let url = repoRoot.appendingPathComponent(change.path)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else {
            return .fallback("[\(change.kind.rawValue) file]")
        }
        let fileType = attrs[.type] as? FileAttributeType
        if fileType == .typeSymbolicLink {
            let dest = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            return .fallback("[symlink -> \(dest)]")
        }
        guard fileType == .typeRegular else {
            return .fallback("[\(change.kind.rawValue) file]")
        }
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        if fileSize > maxInspectableFileBytes {
            return .fallback("[large file: \(fileSize.byteSizeString)]")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .fallback("[\(change.kind.rawValue) file]")
        }
        return .data(data)
    }

    private struct FilteredHunk {
        let leftStart: Int
        let leftCount: Int
        let rightStart: Int
        let rightCount: Int
        let removedIndices: [Int]
        let addedIndices: [Int]
    }

    private static func buildReviewFileDiff(
        for change: FileChange,
        source: AIHunkGroupingSource,
        isInitial: Bool,
        groupFilter: GroupHunkFilter?,
        excludedLines: Set<ChangeLine>,
        in repoRoot: URL,
        contextLines: Int,
        maxInspectableFileBytes: Int
    ) async -> AIReviewDiffFile? {
        let sides = await loadSides(
            for: change,
            source: source,
            isInitial: isInitial,
            in: repoRoot,
            maxInspectableFileBytes: maxInspectableFileBytes
        )

        let commitHashes: [String]
        if case .commits(let commits) = source,
           commits.isNonContiguous,
           let steps = commits.fileSteps[change.path],
           !steps.isEmpty {
            var seen: Set<String> = []
            commitHashes = steps.map(\.hash).filter { seen.insert($0).inserted }
        } else {
            commitHashes = []
        }

        let isPartialSelection = !excludedLines.isEmpty || (groupFilter != nil && groupFilter != .all)

        func makeFallback(_ note: String, hunkCount: Int = 1, firstTargetLine: Int? = nil) -> AIReviewDiffFile {
            let header = formatFileHeader(for: change, isPartial: isPartialSelection, commitHashes: commitHashes)
            return AIReviewDiffFile(
                path: change.path,
                oldPath: change.oldPath,
                kind: change.kind,
                summaryLine: formatSummaryLine(for: change, isPartial: isPartialSelection),
                header: header,
                body: note,
                hunkCount: hunkCount,
                firstTargetLine: firstTargetLine
            )
        }

        switch sides {
        case .fallback(let note):
            if let groupFilter, !groupFilter.includesSingleFallbackHunk {
                return nil
            }
            return makeFallback(note)

        case .bytes(let oldData, let newData):
            let oldLines = oldData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []
            let newLines = newData.map { TextCodec.splitLines(TextCodec.decode($0)) } ?? []

            let rawHunks: [Hunk]
            if oldData == nil {
                if newLines.isEmpty {
                    if let groupFilter, !groupFilter.includesSingleFallbackHunk { return nil }
                    return makeFallback("@@ -0,0 +0,0 @@ (empty new file)", firstTargetLine: 1)
                }
                rawHunks = [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: newLines.count)]
            } else if newData == nil {
                if oldLines.isEmpty {
                    if let groupFilter, !groupFilter.includesSingleFallbackHunk { return nil }
                    return makeFallback("@@ -0,0 +0,0 @@ (empty deleted file)")
                }
                rawHunks = [Hunk(leftStart: 0, leftCount: oldLines.count, rightStart: 0, rightCount: 0)]
            } else {
                guard let computed = await DiffLoader.computeHunks(old: oldData, new: newData, ignoreWhitespace: false) else {
                    if let groupFilter, !groupFilter.includesSingleFallbackHunk { return nil }
                    return makeFallback("[binary or undiffable file]")
                }
                if computed.isEmpty {
                    if let groupFilter, !groupFilter.includesSingleFallbackHunk { return nil }
                    let note = (change.kind == .renamed && change.oldPath != nil)
                        ? "[renamed from \(change.oldPath!)]"
                        : "[file mode or metadata change]"
                    return makeFallback(note, firstTargetLine: newLines.isEmpty ? nil : 1)
                }
                rawHunks = computed
            }

            let includedRawIndices: Set<Int>
            if let groupFilter {
                includedRawIndices = groupFilter.resolved(for: rawHunks).includedRawIndices
            } else {
                includedRawIndices = Set(rawHunks.indices)
            }

            let relocatedExcluded = excludedLines.isEmpty
                ? Set<ChangeLine>()
                : WorkingTree.relocate(excludedLines, old: oldLines, new: newLines, hunks: rawHunks).lines

            var filteredHunks: [FilteredHunk] = []
            filteredHunks.reserveCapacity(includedRawIndices.count)
            for idx in rawHunks.indices where includedRawIndices.contains(idx) {
                let hunk = rawHunks[idx]
                let oldEnd = min(oldLines.count, hunk.leftStart + hunk.leftCount)
                let newEnd = min(newLines.count, hunk.rightStart + hunk.rightCount)
                let keptRemoved: [Int]
                let keptAdded: [Int]
                if relocatedExcluded.isEmpty {
                    keptRemoved = hunk.leftStart < oldEnd ? Array(hunk.leftStart..<oldEnd) : []
                    keptAdded = hunk.rightStart < newEnd ? Array(hunk.rightStart..<newEnd) : []
                } else {
                    keptRemoved = hunk.leftStart < oldEnd
                        ? (hunk.leftStart..<oldEnd).filter {
                            !relocatedExcluded.contains(ChangeLine(removed: true, line: $0, text: oldLines[$0]))
                        }
                        : []
                    keptAdded = hunk.rightStart < newEnd
                        ? (hunk.rightStart..<newEnd).filter {
                            !relocatedExcluded.contains(ChangeLine(removed: false, line: $0, text: newLines[$0]))
                        }
                        : []
                }
                guard !keptRemoved.isEmpty || !keptAdded.isEmpty else { continue }
                filteredHunks.append(FilteredHunk(
                    leftStart: hunk.leftStart,
                    leftCount: hunk.leftCount,
                    rightStart: hunk.rightStart,
                    rightCount: hunk.rightCount,
                    removedIndices: keptRemoved,
                    addedIndices: keptAdded
                ))
            }

            guard !filteredHunks.isEmpty else { return nil }

            let isPartial = !relocatedExcluded.isEmpty || filteredHunks.count < rawHunks.count
            let header = formatFileHeader(for: change, isPartial: isPartial, commitHashes: commitHashes)
            let body = formatContextHunks(
                filteredHunks,
                oldLines: oldLines,
                newLines: newLines,
                contextLines: contextLines
            )

            let firstLine: Int? = {
                guard newData != nil, !newLines.isEmpty else { return nil }
                if let firstAdded = filteredHunks.first(where: { !$0.addedIndices.isEmpty })?.addedIndices.first {
                    return firstAdded + 1
                }
                if let firstHunk = filteredHunks.first {
                    return min(newLines.count, max(1, firstHunk.rightStart + 1))
                }
                return nil
            }()

            return AIReviewDiffFile(
                path: change.path,
                oldPath: change.oldPath,
                kind: change.kind,
                summaryLine: formatSummaryLine(for: change, isPartial: isPartial),
                header: header,
                body: body,
                hunkCount: filteredHunks.count,
                firstTargetLine: firstLine
            )
        }
    }

    private static func formatFileHeader(
        for change: FileChange,
        isPartial: Bool,
        commitHashes: [String] = []
    ) -> String {
        var line = "### \(change.path) [\(change.kind.rawValue)]"
        if change.kind == .renamed, let oldPath = change.oldPath, oldPath != change.path {
            line += " (renamed from \(oldPath))"
        }
        var meta: [String] = []
        if let add = change.additions, let del = change.deletions {
            meta.append("+\(add) -\(del)")
        }
        if isPartial {
            meta.append("partial")
        }
        if !meta.isEmpty {
            line += " (\(meta.joined(separator: ", ")))"
        }
        if !commitHashes.isEmpty {
            line += " [commits: \(commitHashes.joined(separator: ", "))]"
        }
        return line
    }

    private static func formatSummaryLine(for change: FileChange, isPartial: Bool) -> String {
        var line = change.kind == .renamed && change.oldPath != nil
            ? "R \(change.oldPath!) -> \(change.path)"
            : "\(change.kind.letter) \(change.path)"
        var meta: [String] = []
        if let add = change.additions, let del = change.deletions {
            meta.append("+\(add) -\(del)")
        }
        if isPartial {
            meta.append("partial")
        }
        if !meta.isEmpty {
            line += " (\(meta.joined(separator: ", ")))"
        }
        return line
    }

    /// Formats `hunks` with `contextLines` of surrounding context and explicit 1-based line tags,
    /// coalescing overlapping or adjacent context windows cleanly.
    private static func formatContextHunks(
        _ hunks: [FilteredHunk],
        oldLines: [String],
        newLines: [String],
        contextLines: Int
    ) -> String {
        guard !hunks.isEmpty else { return "" }

        let useOldSideForContext = newLines.isEmpty && !oldLines.isEmpty
        var windows: [[FilteredHunk]] = []
        for hunk in hunks {
            if let lastGroup = windows.last, let prev = lastGroup.last {
                let overlaps: Bool
                if useOldSideForContext {
                    let prevEnd = min(oldLines.count, prev.leftStart + prev.leftCount + contextLines)
                    let nextStart = max(0, hunk.leftStart - contextLines)
                    overlaps = nextStart <= prevEnd
                } else {
                    let prevEnd = min(newLines.count, prev.rightStart + prev.rightCount + contextLines)
                    let nextStart = max(0, hunk.rightStart - contextLines)
                    overlaps = nextStart <= prevEnd
                }
                if overlaps {
                    windows[windows.count - 1].append(hunk)
                    continue
                }
            }
            windows.append([hunk])
        }

        var blocks: [String] = []
        blocks.reserveCapacity(windows.count)

        for window in windows {
            let first = window[0]
            let last = window[window.count - 1]
            var lines: [String] = []

            let leadStartNew = max(0, first.rightStart - contextLines)
            let leadEndNew = min(newLines.count, first.rightStart)
            let leadStartOld = max(0, first.leftStart - contextLines)
            let leadEndOld = min(oldLines.count, first.leftStart)

            let trailStartNew = min(newLines.count, last.rightStart + last.rightCount)
            let trailEndNew = min(newLines.count, trailStartNew + contextLines)
            let trailStartOld = min(oldLines.count, last.leftStart + last.leftCount)
            let trailEndOld = min(oldLines.count, trailStartOld + contextLines)

            let leadCount = useOldSideForContext ? max(0, leadEndOld - leadStartOld) : max(0, leadEndNew - leadStartNew)
            let trailCount = useOldSideForContext ? max(0, trailEndOld - trailStartOld) : max(0, trailEndNew - trailStartNew)

            var totalOldCount = leadCount + trailCount
            var totalNewCount = leadCount + trailCount
            for i in window.indices {
                totalOldCount += window[i].removedIndices.count
                totalNewCount += window[i].addedIndices.count
                if i + 1 < window.count {
                    let gapCount = useOldSideForContext
                        ? max(0, window[i + 1].leftStart - (window[i].leftStart + window[i].leftCount))
                        : max(0, window[i + 1].rightStart - (window[i].rightStart + window[i].rightCount))
                    totalOldCount += gapCount
                    totalNewCount += gapCount
                }
            }

            let dispOldStart = totalOldCount == 0
                ? max(0, first.leftStart - leadCount)
                : max(1, first.leftStart - leadCount + 1)
            let dispNewStart = totalNewCount == 0
                ? max(0, first.rightStart - leadCount)
                : max(1, first.rightStart - leadCount + 1)
            lines.append("@@ -\(dispOldStart),\(totalOldCount) +\(dispNewStart),\(totalNewCount) @@")

            if useOldSideForContext {
                for idx in leadStartOld..<leadEndOld {
                    lines.append("  [old L\(idx + 1)] \(clipLine(oldLines[idx]))")
                }
            } else {
                for idx in leadStartNew..<leadEndNew {
                    lines.append("  [L\(idx + 1)] \(clipLine(newLines[idx]))")
                }
            }

            for (i, hunk) in window.enumerated() {
                for idx in hunk.removedIndices {
                    lines.append("- [old L\(idx + 1)] \(clipLine(oldLines[idx]))")
                }
                for idx in hunk.addedIndices {
                    lines.append("+ [L\(idx + 1)] \(clipLine(newLines[idx]))")
                }
                if i + 1 < window.count {
                    let next = window[i + 1]
                    if useOldSideForContext {
                        let gapStart = min(oldLines.count, hunk.leftStart + hunk.leftCount)
                        let gapEnd = min(oldLines.count, next.leftStart)
                        if gapStart < gapEnd {
                            for idx in gapStart..<gapEnd {
                                lines.append("  [old L\(idx + 1)] \(clipLine(oldLines[idx]))")
                            }
                        }
                    } else {
                        let gapStart = min(newLines.count, hunk.rightStart + hunk.rightCount)
                        let gapEnd = min(newLines.count, next.rightStart)
                        if gapStart < gapEnd {
                            for idx in gapStart..<gapEnd {
                                lines.append("  [L\(idx + 1)] \(clipLine(newLines[idx]))")
                            }
                        }
                    }
                }
            }

            if useOldSideForContext {
                for idx in trailStartOld..<trailEndOld {
                    lines.append("  [old L\(idx + 1)] \(clipLine(oldLines[idx]))")
                }
            } else {
                for idx in trailStartNew..<trailEndNew {
                    lines.append("  [L\(idx + 1)] \(clipLine(newLines[idx]))")
                }
            }

            blocks.append(lines.joined(separator: "\n"))
        }

        return blocks.joined(separator: "\n")
    }

    private static func clipLine(_ line: String) -> String {
        guard line.count > defaultMaxLineCharacters else { return line }
        return String(line.prefix(defaultMaxLineCharacters)) + "…"
    }

    // MARK: - Prompt Construction

    /// Builds the code review prompt containing strict rules, `diffcode://` magic link specification + concrete example,
    /// conditional Mermaid flowchart/sequence-diagram instructions, and budget-bounded context diffs.
    static func buildPrompt(
        payload: AIReviewPayload,
        repoRoot: URL,
        isChinese: Bool = true,
        maxDiffBytes: Int = defaultMaxDiffBytes
    ) -> String {
        let canonicalRoot = repoRoot.standardizedFileURL.path
        let exampleRelPath = payload.firstFilePath ?? "Sources/App.swift"
        let exampleLine = payload.firstTargetLine ?? 42
        let exampleURLString = ExternalOpenParser.makeOpenURL(
            fileURL: repoRoot.appendingPathComponent(exampleRelPath),
            line: exampleLine
        )?.absoluteString ?? "diffcode://open?path=%2Fpath%2Fto%2Ffile&line=\(exampleLine)"

        let instructions: String
        if isChinese {
            instructions = """
            你是一位资深架构师与代码审查专家。请针对下方提供的 Git 变更生成一份结构清晰、技术深入、可直接用于人工 Code Review 的 Markdown 审查报告。

            ## 严格规则
            1. **仅限只读按需查询**：分析变更时如需要查看调用方、类型定义或完整文件上下文，只允许以**只读方式**读取当前仓库内文件，或执行简单的只读 Git/检索命令（例如 `git show <提交号>:<相对路径>`、`git log`、`git grep`、`rg`、`git diff`），请勿使用写文件重定向、复杂循环脚本或切换分支命令，也不要自行把审查报告写入磁盘。
            2. **快照隔离原则**：如果“审查上下文与变更文件清单”提供了历史提交号、分支/提交对比或 Stash 提交号，当前磁盘工作区可能处于其他分支或版本；查询对应版本内容时**必须**使用上下文给出的提交号配合 `git show <提交号>:<相对路径>`，切勿直接假设磁盘文件就是目标快照。
            3. **纯粹输出正文**：直接输出完整的 Markdown 文档正文（以 `# 代码审查报告：...` 开头）；禁止在正文前输出“我先查看一下……”等过程旁白，也禁止把整份报告包在 ```markdown ... ``` 外层代码围栏中。
            4. **事实准确性**：如实总结变更，不得编造不存在的文件名、符号名或行号；行号请直接采用差异中标注的 `[L行号]`（删除行标注为 `[old L行号]`）或只读查询实际确认的真实行号。

            ## DiffCode 魔术链接规范（必须使用）
            本仓库根目录绝对路径为：`\(canonicalRoot)`
            报告中每次提及具体文件、函数位置、问题点或待审查位置时，**必须**生成可点击的 DiffCode 魔术链接，点击后可在 DiffCode 中直接跳转定位：
            - 格式：`[显示文本](diffcode://open?path=<URL编码后的文件绝对路径>&line=<1起始行号>)`
            - 绝对路径拼接方式：`\(canonicalRoot)/<相对路径>`，其中 `path` 参数必须进行 URL 百分号编码（空格、中文、`+`、`&`、`#` 等特殊字符必须编码）。
            - 对于纯删除文件或无需定位到具体行号的整文件引用，可省略 `&line=` 参数：`[相对路径](diffcode://open?path=<URL编码后的文件绝对路径>)`。
            - 正确示例：`[\(exampleRelPath):\(exampleLine)](\(exampleURLString))`

            ## 报告输出结构（按此结构输出）
            # 代码审查报告：\(payload.title)

            ## 1. 变更总览
            - 用简洁明确的语言说明本次变更的核心目的、整体改动内容以及影响范围。
            - 使用 Markdown 表格列出所有涉及的文件：`文件（带 diffcode:// 链接） | 变更类型 | 核心改动说明`。

            ## 2. 详细改动解析
            - 按模块或逻辑单元深入拆解每个改动做了什么、控制流/数据流/状态如何变化、关键实现细节与边界条件处理。
            - 关键函数、数据结构和核心变更行均附带 `diffcode://` 魔术链接。

            ## 3. 流程与交互图（按复杂度条件输出）
            - **触发条件**：如果本次变更属于复杂功能——即涉及 **3 个以上功能节点/分支步骤的状态流转**，或涉及 **跨服务器/跨服务/跨进程/客户端与服务端之间的数据流转**，则**必须**在本节给出清晰的 `mermaid` 流程图（`flowchart TD` / `flowchart LR`）或时序图（`sequenceDiagram`），准确体现节点、分支或跨端交互顺序。
            - **语法注意**：包含括号 `()`、方括号 `[]` 或特殊字符的 Mermaid 节点文本请使用双引号包裹（例如 `A["handle(request)"]`），避免使用原生 HTML 标签。
            - 如果本次变更较为简单（不超过 3 个功能节点且无跨服务/跨端数据流转），请**省略第 3 节**，不要强行画无意义的简单图。

            ## 4. 潜在问题与风险
            - 认真排查逻辑 Bug、并发与竞态、空值/边界条件、错误处理遗漏、性能退化、内存/资源泄漏、安全隐患或破坏性兼容问题。
            - 按严重程度分组（例如 `🔴 严重 / Bug`、`🟡 警告 / 风险`、`🔵 建议 / 优化`），每条必须包含：`diffcode://` 定位链接、问题描述与触发条件、修复或改进建议。如果未发现明显缺陷，请明确说明并解释原因。

            ## 5. 人工审查重点关注
            - 以可勾选的清单（`- [ ] ...`）列出开发者人工 Review 时最需要重点核对的事项（核心不变量、异常分支、跨模块契约、持久化/兼容迁移、需要重点验证的测试场景），每条附带对应的 `diffcode://` 链接。
            """
        } else {
            instructions = """
            You are a senior software architect and code reviewer. Produce a thorough, actionable Markdown code review report for the Git changes provided below.

            ## Strict Rules
            1. **Read-Only Inspection Only**: When you need surrounding definitions, callers, or full file context, you MAY inspect repository files read-only or run simple read-only Git/search commands (such as `git show <sha>:<relative-path>`, `git log`, `git grep`, `rg`, `git diff`). NEVER modify, create, or delete repository files, use write redirections, run mutating shell/git commands, or write the review report to disk yourself.
            2. **Snapshot Accuracy**: When reviewing historical commits, branch/commit comparisons, or stashes, files on disk in the working tree may be at a different checkout. Always inspect those snapshots using the exact commit SHAs from the context section via `git show <target-sha>:<path>` / `git show <base-sha>:<path>`.
            3. **Clean Markdown Output**: Output the Markdown report directly (starting with `# Code Review: ...`). Do NOT prepend tool-use narration (e.g., "Let me check...") and do NOT wrap the entire response in an outer ```markdown ... ``` fence.
            4. **Be Strictly Factual**: Never invent file paths, symbol names, or line numbers. Use the explicit 1-based `[L<num>]` line numbers shown in the diff (`[old L<num>]` for deleted lines) or verified line numbers from read-only inspection.

            ## DiffCode Magic Link Specification (Required)
            The repository root path is: `\(canonicalRoot)`
            Whenever you reference a file, symbol, bug, or review checkpoint, you **MUST** emit a clickable DiffCode magic link so clicking it in a Markdown viewer jumps directly to that file and line in DiffCode:
            - Format: `[display text](diffcode://open?path=<percent-encoded-absolute-path>&line=<1-based-line>)`
            - Construct the absolute path as `\(canonicalRoot)/<relative-path>`, percent-encoding spaces and special characters in `path`.
            - Omit `&line=` for deleted files or whole-file links: `[relative/path](diffcode://open?path=<percent-encoded-absolute-path>)`.
            - Example: `[\(exampleRelPath):\(exampleLine)](\(exampleURLString))`

            ## Required Report Structure
            # Code Review: \(payload.title)

            ## 1. Summary of Changes
            - Explain clearly what changed, why, and the blast radius.
            - Include a Markdown table: `File (diffcode:// link) | Kind | Summary`.

            ## 2. Detailed Change Breakdown
            - Explain what each module/file change does, how control flow, data flow, and state transitions change, and key implementation details, linking symbols/lines via `diffcode://`.

            ## 3. Flow / Sequence Diagram (Conditional)
            - **Required when complex**: If the changes implement complex logic involving **more than 3 functional nodes/branches** OR **data flow across servers, services, processes, or client-server boundaries**, you **MUST** include a valid `mermaid` flowchart (`flowchart TD` / `flowchart LR`) or sequence diagram (`sequenceDiagram`).
            - Quote Mermaid node labels containing `()` or `[]` (e.g. `A["handle(req)"]`), and avoid raw HTML tags inside labels.
            - If the change is simple (<= 3 functional nodes and single-component), omit Section 3 entirely.

            ## 4. Potential Issues & Risks
            - Identify bugs, concurrency/race conditions, edge cases, missing error handling, performance/memory regressions, security issues, or breaking compatibility changes.
            - Categorize by severity (`🔴 Critical / Bug`, `🟡 Warning / Risk`, `🔵 Suggestion`), each with a `diffcode://` link, root cause, and concrete fix recommendation.

            ## 5. Reviewer Focus Checklist
            - Provide an actionable `- [ ]` checklist of critical invariants, edge cases, compatibility concerns, and verification points the human reviewer should verify, each linked via `diffcode://`.
            """
        }

        let summaryLines = payload.files.map(\.summaryLine).joined(separator: "\n")
        let scopeBlock = payload.scopeContextLines.joined(separator: "\n")
        let overviewHeader = isChinese
            ? "## 审查上下文与变更文件清单（共 \(payload.fileCount) 个文件，\(payload.totalHunks) 处变更）"
            : "## Review Context & Changed Files (\(payload.fileCount) files, \(payload.totalHunks) hunks)"

        var budget = max(1024, maxDiffBytes)
        var sections: [String] = []
        sections.reserveCapacity(payload.files.count)

        for (index, file) in payload.files.enumerated() {
            let remainingFiles = max(1, payload.files.count - index)
            let perFileBudget = max(256, budget / remainingFiles)
            let headerAndBody = "\(file.header)\n\(file.body)"
            let bounded = truncateUTF8(headerAndBody, maxBytes: perFileBudget).text
            sections.append(bounded)
            budget = max(0, budget - bounded.utf8.count - 2)
        }

        let diffHeading = isChinese ? "## 带行号的变更上下文 Diff" : "## Context-Rich Diff with Line Numbers"
        return """
        \(instructions)

        \(overviewHeader)
        \(scopeBlock)

        ### Files
        \(summaryLines)

        \(diffHeading)

        \(sections.joined(separator: "\n\n"))
        """
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

    // MARK: - Markdown Cleaning & Report Storage

    /// Cleans LLM Markdown output, peeling an outer ```markdown / ```md wrapper ONLY when it wraps
    /// the entire response, so internal ```mermaid and code blocks remain intact.
    static func cleanMarkdownResponse(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count >= 3 {
            let first = lines[0].trimmingCharacters(in: .whitespaces)
            let fenceLen = first.prefix(while: { $0 == "`" }).count
            if fenceLen >= 3 {
                let lang = String(first.dropFirst(fenceLen)).trimmingCharacters(in: .whitespaces).lowercased()
                let isMarkdownFence = lang == "markdown" || lang == "md"
                var lastIdx = lines.count - 1
                while lastIdx > 0 && lines[lastIdx].trimmingCharacters(in: .whitespaces).isEmpty {
                    lastIdx -= 1
                }
                let last = lines[lastIdx].trimmingCharacters(in: .whitespaces)
                let closingFence = String(repeating: "`", count: fenceLen)
                if last == closingFence {
                    let inner = lines[1..<lastIdx].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    let innerLooksMarkdown = inner.hasPrefix("#") || inner.hasPrefix(">") || inner.hasPrefix("- ") || inner.hasPrefix("**")
                    if isMarkdownFence || (lang.isEmpty && innerLooksMarkdown) {
                        text = inner
                    }
                }
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Inserts a concise metadata blockquote below the top-level heading (or at top) if not already present.
    static func withMetadataHeader(
        _ markdown: String,
        repoName: String,
        scopeTitle: String,
        revisionSummary: String? = nil,
        provider: AgentProvider,
        model: String?,
        fileCount: Int,
        hunkCount: Int,
        generatedAt: Date = Date(),
        isChinese: Bool = true
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: generatedAt)
        let modelLabel = model.flatMap { $0.isEmpty ? nil : "\(provider.displayName) · \($0)" } ?? provider.displayName
        let trimmedRevision = revisionSummary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let metaBlock: String
        if isChinese {
            let revisionPart = (trimmedRevision.map { !$0.isEmpty } ?? false) ? " ｜ **提交**：`\(trimmedRevision!)`" : ""
            metaBlock = "> **仓库**：`\(repoName)` ｜ **范围**：\(scopeTitle)\(revisionPart) ｜ **规模**：\(fileCount) 文件 / \(hunkCount) 处变更 ｜ **模型**：`\(modelLabel)` ｜ **时间**：\(timestamp)"
        } else {
            let revisionPart = (trimmedRevision.map { !$0.isEmpty } ?? false) ? " | **Commits**: `\(trimmedRevision!)`" : ""
            metaBlock = "> **Repo**: `\(repoName)` | **Scope**: \(scopeTitle)\(revisionPart) | **Changes**: \(fileCount) file(s) / \(hunkCount) hunk(s) | **Model**: `\(modelLabel)` | **Generated**: \(timestamp)"
        }

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let firstNonEmpty = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[firstNonEmpty].trimmingCharacters(in: .whitespaces).hasPrefix("# ") {
            var updated = Array(lines[...firstNonEmpty])
            updated.append("")
            updated.append(metaBlock)
            let rest = lines[(firstNonEmpty + 1)...]
            if let nextNonEmpty = rest.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                updated.append("")
                updated.append(contentsOf: lines[nextNonEmpty...])
            }
            return updated.joined(separator: "\n")
        }
        return "\(metaBlock)\n\n\(markdown)"
    }

    /// Returns the report storage directory for `repoRoot` (isolated to a temp folder under XCTest).
    static func defaultReportsDirectory(for repoRoot: URL) -> URL {
        let repoFolder = sanitizePathComponent(repoRoot.lastPathComponent, fallback: "repository")
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DiffCodeTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("reviews", isDirectory: true)
                .appendingPathComponent(repoFolder, isDirectory: true)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (Sandbox.realHome as NSString).appendingPathComponent("Library/Application Support"))
        return appSupport
            .appendingPathComponent("DiffCode", isDirectory: true)
            .appendingPathComponent("reviews", isDirectory: true)
            .appendingPathComponent(repoFolder, isDirectory: true)
    }

    /// Writes `markdown` atomically to a timestamped `.md` file inside `baseDirectory ?? defaultReportsDirectory(for: repoRoot)`
    /// and prunes oldest reports beyond `maxRetainedFiles`.
    static func writeReport(
        _ markdown: String,
        repoRoot: URL,
        scopeSlug: String,
        baseDirectory: URL? = nil,
        maxRetainedFiles: Int = defaultMaxRetainedFiles,
        now: Date = Date()
    ) throws -> URL {
        let dir = baseDirectory ?? defaultReportsDirectory(for: repoRoot)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw AIReviewError.writeFailed(error.localizedDescription)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: now)
        let slug = sanitizePathComponent(scopeSlug, fallback: "review", maxLength: 48)

        var targetURL = dir.appendingPathComponent("\(stamp)-\(slug).md", isDirectory: false)
        var counter = 2
        while fm.fileExists(atPath: targetURL.path) {
            targetURL = dir.appendingPathComponent("\(stamp)-\(slug)-\(counter).md", isDirectory: false)
            counter += 1
        }

        do {
            try Data((markdown + "\n").utf8).write(to: targetURL, options: .atomic)
        } catch {
            throw AIReviewError.writeFailed(error.localizedDescription)
        }

        pruneOldReports(in: dir, keeping: max(1, maxRetainedFiles))
        return targetURL
    }

    private static func pruneOldReports(in dir: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let mdFiles = entries.filter { $0.pathExtension.lowercased() == "md" }
        guard mdFiles.count > limit else { return }
        let sorted = mdFiles.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for oldURL in sorted.dropFirst(limit) {
            try? fm.removeItem(at: oldURL)
        }
    }

    static func sanitizePathComponent(_ raw: String, fallback: String, maxLength: Int = 64) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/\\:?\"<>|*#\n\r\t")
        var sanitized = trimmed
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .replacingOccurrences(of: " ", with: "-")
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        if sanitized.isEmpty {
            sanitized = fallback
        }
        if sanitized.count > maxLength {
            sanitized = String(sanitized.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "-._"))
        }
        return sanitized.isEmpty ? fallback : sanitized
    }

    // MARK: - End-to-End Generation

    /// Collects changes for `scope`, generates a Markdown review via `LocalAgentService`,
    /// writes it to disk, and returns the resulting `AIReviewResult`.
    static func generate(
        repoRoot: URL,
        scope: AIReviewScope,
        repoContext: AIReviewRepoContext? = nil,
        provider: AgentProvider = .agy,
        model: String? = nil,
        isChinese: Bool = true,
        toolAccess: AgentToolAccess = .readOnly,
        persistSession: Bool = true,
        reportsDirectory: URL? = nil,
        timeout: TimeInterval = defaultTimeout,
        service: LocalAgentService = .shared,
        onSummaryReady: (@Sendable (String) -> Void)? = nil,
        onPromptReady: (@Sendable (String) -> Void)? = nil,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AIReviewResult {
        guard !AppEnvironment.isAppStore else {
            throw AIReviewError.unavailableInAppStore
        }
        try Task.checkCancellation()

        let payload = try await collectDiff(
            repoRoot: repoRoot,
            scope: scope,
            repoContext: repoContext,
            isChinese: isChinese
        )
        try Task.checkCancellation()

        let summaryLines = payload.scopeContextLines.prefix(4).joined(separator: "\n")
        onSummaryReady?("\(payload.title)\n\(summaryLines)")

        let prompt = buildPrompt(payload: payload, repoRoot: repoRoot, isChinese: isChinese)
        onPromptReady?(prompt)
        let generated = try await service.generateWithSession(
            provider: provider,
            model: model,
            cwd: repoRoot,
            prompt: prompt,
            jsonSchema: nil,
            toolAccess: toolAccess,
            resumeSessionID: nil,
            persistSession: persistSession,
            timeout: timeout,
            onEvent: onEvent
        )
        let raw = generated.text
        try Task.checkCancellation()

        let cleaned = cleanMarkdownResponse(raw)
        guard !cleaned.isEmpty else {
            throw AIReviewError.emptyResponse
        }

        let now = Date()
        let finalMarkdown = withMetadataHeader(
            cleaned,
            repoName: repoRoot.lastPathComponent,
            scopeTitle: payload.title,
            revisionSummary: payload.revisionSummary,
            provider: provider,
            model: model,
            fileCount: payload.fileCount,
            hunkCount: payload.totalHunks,
            generatedAt: now,
            isChinese: isChinese
        )
        let fileURL = try writeReport(
            finalMarkdown,
            repoRoot: repoRoot,
            scopeSlug: scope.filenameSlug,
            baseDirectory: reportsDirectory,
            now: now
        )
        return AIReviewResult(
            markdown: finalMarkdown,
            fileURL: fileURL,
            provider: provider,
            model: model,
            fileCount: payload.fileCount,
            hunkCount: payload.totalHunks,
            generatedAt: now,
            sessionID: generated.sessionID
        )
    }
}
