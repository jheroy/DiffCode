import Foundation

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
