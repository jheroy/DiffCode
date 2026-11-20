import Foundation

/// Risk summary inspected before removing a linked Git work tree (and optionally its local branch).
struct WorktreeRemovalInspection: Equatable, Sendable {
    /// Staged, unstaged, and untracked entries inside the work tree directory.
    var uncommittedChangeCount: Int
    /// Local branch currently checked out in the work tree, or `nil` when detached HEAD.
    var branchName: String?
    /// Commits reachable from `branchName` that are not contained in any other local branch,
    /// its configured upstream, or the main repository's HEAD.
    var unmergedCommitCount: Int

    var hasUncommittedChanges: Bool { uncommittedChangeCount > 0 }
    var hasUnmergedCommits: Bool { unmergedCommitCount > 0 }

    /// Whether proceeding with removal requires a destructive second confirmation.
    func requiresForceConfirmation(deleteBranch: Bool) -> Bool {
        hasUncommittedChanges || (deleteBranch && hasUnmergedCommits)
    }
}

/// High-level work tree removal inspection and execution helpers built on `Git.run`.
enum Worktree {
    /// Structured error distinguishing work tree removal failure from post-removal branch deletion failure.
    struct RemovalError: Error, LocalizedError, Sendable {
        enum Stage: Equatable, Sendable {
            case worktree
            case branch(String)
        }

        let stage: Stage
        let underlying: Error

        var worktreeRemoved: Bool {
            if case .branch = stage { return true }
            return false
        }

        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Inspects a linked work tree for uncommitted changes and unmerged commits on its local branch.
    static func inspectRemoval(
        worktreeURL: URL,
        repoRoot: URL,
        branchName: String? = nil
    ) async -> WorktreeRemovalInspection {
        async let uncommittedTask = countUncommittedChanges(in: worktreeURL)
        async let branchTask = resolveWorktreeBranch(explicit: branchName, worktreeURL: worktreeURL)
        let resolvedBranch = await branchTask
        let unmergedCount: Int
        if let resolvedBranch {
            unmergedCount = await countUnmergedCommits(branch: resolvedBranch, in: repoRoot)
        } else {
            unmergedCount = 0
        }
        return WorktreeRemovalInspection(
            uncommittedChangeCount: await uncommittedTask,
            branchName: resolvedBranch,
            unmergedCommitCount: unmergedCount
        )
    }

    /// Removes a linked work tree and, when requested, deletes its local branch afterwards.
    ///
    /// Git refuses to delete a branch that is still checked out in a work tree, so the work tree is always
    /// removed first. If removing the work tree succeeds but deleting the branch fails, throws
    /// `RemovalError(stage: .branch(branch), underlying:)`.
    static func remove(
        worktreeURL: URL,
        repoRoot: URL,
        forceWorktree: Bool = false,
        deleteBranch branchName: String? = nil,
        forceBranch: Bool = false
    ) async throws {
        do {
            try await Git.removeWorktree(in: repoRoot, at: worktreeURL, force: forceWorktree)
        } catch {
            throw RemovalError(stage: .worktree, underlying: error)
        }
        if let branch = normalizedBranchName(branchName) {
            do {
                try await Git.deleteBranch(branch, force: forceBranch, in: repoRoot)
            } catch {
                throw RemovalError(stage: .branch(branch), underlying: error)
            }
        }
    }

    /// Local branch currently checked out in `dir`, or `nil` when detached HEAD or unavailable.
    static func currentBranch(in dir: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: dir.path),
              let out = try? await Git.runString(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir) else {
            return nil
        }
        return normalizedBranchName(out)
    }

    /// Parses `git status --porcelain=v1 -z` output into the number of uncommitted entries.
    static func countPorcelainV1ZChanges(_ data: Data) -> Int {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true)
        var count = 0
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            // Each porcelain v1 entry begins with "XY <path>".
            guard token.count >= 3 else { continue }
            let x = token[token.startIndex]
            let y = token[token.index(after: token.startIndex)]
            if x == UInt8(ascii: "!") && y == UInt8(ascii: "!") { continue }
            count += 1
            // Renames and copies in `-z` mode emit an extra NUL-terminated source path.
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C")
                || y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                i += 1
            }
        }
        return count
    }

    private static func normalizedBranchName(_ raw: String?) -> String? {
        guard var trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.hasPrefix("refs/heads/") {
            trimmed = String(trimmed.dropFirst("refs/heads/".count))
        }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return nil }
        return trimmed
    }

    private static func countUncommittedChanges(in worktreeURL: URL) async -> Int {
        guard FileManager.default.fileExists(atPath: worktreeURL.path),
              let data = try? await Git.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: worktreeURL) else {
            return 0
        }
        return countPorcelainV1ZChanges(data)
    }

    private static func resolveWorktreeBranch(explicit: String?, worktreeURL: URL) async -> String? {
        if let normalized = normalizedBranchName(explicit) {
            return normalized
        }
        return await currentBranch(in: worktreeURL)
    }

    private static func countUnmergedCommits(branch: String, in repoRoot: URL) async -> Int {
        let fullRef = "refs/heads/\(branch)"
        guard let branchOID = try? await Git.runString(["rev-parse", "--verify", "--quiet", fullRef], in: repoRoot)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !branchOID.isEmpty else {
            return 0
        }

        // Exclude every commit already reachable from:
        // 1. Any other local branch (`--exclude=<branch> --branches`),
        // 2. The branch's configured upstream ref (if still present),
        // 3. The main repository's HEAD (if valid and not pointing to this branch itself).
        var args = ["rev-list", "--count", fullRef, "--not", "--exclude=\(branch)", "--branches"]

        if let upstreamOutput = try? await Git.runString(
            ["for-each-ref", "--format=%(refname)\t%(upstream)", fullRef],
            in: repoRoot
        ) {
            for line in upstreamOutput.split(separator: "\n", omittingEmptySubsequences: true) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, String(parts[0]) == fullRef else { continue }
                let upstreamRef = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !upstreamRef.isEmpty,
                   let upstreamOID = try? await Git.runString(
                       ["rev-parse", "--verify", "--quiet", upstreamRef],
                       in: repoRoot
                   ).trimmingCharacters(in: .whitespacesAndNewlines),
                   !upstreamOID.isEmpty {
                    args.append(upstreamOID)
                }
                break
            }
        }

        let mainHeadRef = (try? await Git.runString(["symbolic-ref", "--quiet", "HEAD"], in: repoRoot))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if mainHeadRef != fullRef,
           let mainHeadOID = try? await Git.runString(["rev-parse", "--verify", "--quiet", "HEAD"], in: repoRoot)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !mainHeadOID.isEmpty {
            args.append(mainHeadOID)
        }

        guard let out = try? await Git.runString(args, in: repoRoot) else { return 0 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

/// Creating, removing and pruning Git work trees, plus naming helpers for new work tree directories.
extension Git {
    /// Adds a linked work tree at `path` for `repoDir`.
    /// - Parameters:
    ///   - repoDir: The main repository (or any existing work tree of it).
    ///   - path: Destination folder for the new work tree (must not already exist as a non-empty directory).
    ///   - branch: Branch name to create (`createBranch == true`) or existing branch/ref to check out (`createBranch == false`).
    ///   - createBranch: When true, runs `git worktree add -b <branch> <path> [baseRef]`.
    ///     When false, runs `git worktree add <path> <branch>`.
    ///   - baseRef: Optional starting commit/ref when creating a new branch; defaults to `HEAD` when nil or blank.
    static func addWorktree(
        in repoDir: URL,
        at path: URL,
        branch: String,
        createBranch: Bool,
        baseRef: String? = nil
    ) async throws {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        var args = ["worktree", "add"]
        if createBranch {
            args += ["-b", trimmedBranch, path.path]
            if let base = baseRef?.trimmingCharacters(in: .whitespacesAndNewlines), !base.isEmpty {
                args.append(base)
            }
        } else {
            args += [path.path, trimmedBranch]
        }
        _ = try await run(args, in: repoDir)
    }

    /// Removes a linked work tree at `worktreeDir` from `repoDir`.
    /// Pass `force: true` to remove a work tree that has modified or untracked files.
    static func removeWorktree(in repoDir: URL, at worktreeDir: URL, force: Bool = false) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreeDir.path)
        _ = try await run(args, in: repoDir)
    }

    /// Prunes administrative files for work trees whose directories no longer exist on disk.
    static func pruneWorktrees(in repoDir: URL) async throws {
        _ = try await run(["worktree", "prune"], in: repoDir)
    }

    /// Local and remote branches in `repoDir`, ordered most-recently-committed first.
    static func branches(in repoDir: URL) async throws -> [GitRef] {
        try await refs(in: repoDir).filter { $0.kind == .local || $0.kind == .remote }
    }

    /// The main work tree's root directory for `dir` (works whether `dir` is the main repo or a linked work tree).
    static func mainWorktreeRoot(for dir: URL) async -> URL? {
        if let first = await worktrees(in: dir).first, !first.isBare {
            return URL(fileURLWithPath: first.path).standardizedFileURL
        }
        guard let out = try? await runString(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: dir) else {
            return nil
        }
        let common = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !common.isEmpty else { return nil }
        let commonURL = URL(fileURLWithPath: common).standardizedFileURL
        return commonURL.lastPathComponent == ".git" ? commonURL.deletingLastPathComponent() : nil
    }

    /// Turns a branch name such as `feature/foo-bar` into a safe directory-name suffix (`feature-foo-bar`).
    static func worktreeSlug(for branch: String) -> String {
        let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var result = ""
        var previousWasDash = false
        for scalar in trimmed.unicodeScalars {
            let isSeparator = scalar == "/" || scalar == "\\" || scalar == ":" || scalar == "*"
                || scalar == "?" || scalar == "\"" || scalar == "<" || scalar == ">" || scalar == "|"
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || scalar.value < 0x20 || scalar.value == 0x7F
            if isSeparator || scalar == "-" {
                if !result.isEmpty, !previousWasDash {
                    result.append("-")
                    previousWasDash = true
                }
            } else {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    }

    /// Strips the remote name from a remote-tracking branch (`origin/feature/x` -> `feature/x`).
    static func localBranchName(forRemote remoteBranch: String) -> String {
        remoteBranch.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? remoteBranch
    }

    /// Default path for a new work tree beside `repoDir`: `<parent>/<repoName>-<slug>`.
    static func defaultWorktreeURL(for repoDir: URL, branch: String, parentDir: URL? = nil) -> URL {
        let repo = repoDir.standardizedFileURL
        let parent = (parentDir ?? repo.deletingLastPathComponent()).standardizedFileURL
        let repoName = repo.lastPathComponent
        let slug = worktreeSlug(for: branch)
        let folderName = slug.isEmpty ? "\(repoName)-worktree" : "\(repoName)-\(slug)"
        return parent.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Whether a `git worktree remove` failure indicates uncommitted/untracked changes requiring `--force`.
    static func worktreeRemoveNeedsForce(_ message: String) -> Bool {
        message.contains("--force") || message.contains("modified or untracked files")
    }
}
