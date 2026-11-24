import Foundation

/// What git is in the middle of: a merge, rebase, cherry-pick or revert that stopped for the user to resolve conflicts.
enum RepoOperation: String, Equatable, Sendable {
    case merge, rebase, cherryPick, revert

    /// "Merging", for the banner over the Changes list.
    var title: String {
        switch self {
        case .merge: return L("Merging", "正在合并")
        case .rebase: return L("Rebasing", "正在变基")
        case .cherryPick: return L("Cherry-picking", "正在拣选")
        case .revert: return L("Reverting", "正在还原")
        }
    }

    /// The git command that continues or abandons it.
    var command: String {
        switch self {
        case .merge: return "merge"
        case .rebase: return "rebase"
        case .cherryPick: return "cherry-pick"
        case .revert: return "revert"
        }
    }
}

/// How a pull joins the branch with what came in, when they have both moved on.
enum PullMode: Equatable, Sendable {
    /// Whatever the user's git settings say (`pull.rebase`, `pull.ff`).
    case configured
    case merge
    case rebase
}

/// Branches, remotes and git's interrupted operations. Each runs git as the user would in a terminal; nothing here
/// forces anything (no `--force`, no `reset --hard`).
extension Git {
    /// The repository's own directory: `.git`, or a linked worktree's directory inside the main one.
    static func gitDirectory(in dir: URL) async -> URL? {
        guard let out = try? await runString(["rev-parse", "--absolute-git-dir"], in: dir) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// What git is in the middle of, from the marker files it keeps in its directory.
    static func operation(in gitDirectory: URL) -> RepoOperation? {
        let fm = FileManager.default
        func exists(_ name: String) -> Bool { fm.fileExists(atPath: gitDirectory.appendingPathComponent(name).path) }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        return nil
    }

    /// The message git prepared for the commit that finishes a merge (`MERGE_MSG`), without its comment lines.
    static func preparedMessage(in gitDirectory: URL) -> String? {
        guard let text = try? String(contentsOf: gitDirectory.appendingPathComponent("MERGE_MSG"), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("#") }
        let message = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    // MARK: Branches

    /// Why `name` cannot be a new branch, or nil when it can. Mirrors `git check-ref-format --branch`, without a process.
    static func branchNameProblem(_ name: String, existing: Set<String>) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return L("Type a name", "请输入名称") }
        if existing.contains(trimmed) { return L("A branch named “\(trimmed)” already exists", "已有名为“\(trimmed)”的分支") }
        let bad = trimmed.hasPrefix("-") || trimmed.hasPrefix("/") || trimmed.hasSuffix("/") || trimmed.hasSuffix(".")
            || trimmed.hasSuffix(".lock") || trimmed.contains("..") || trimmed.contains("//") || trimmed.contains("@{")
            || trimmed == "@" || trimmed == "HEAD" || trimmed.split(separator: "/").contains { $0.hasPrefix(".") }
            || trimmed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || " ~^:?*[\\".unicodeScalars.contains($0) }
        return bad ? L("Not a valid branch name", "不是有效的分支名") : nil
    }

    static func switchBranch(_ name: String, in dir: URL) async throws {
        _ = try await run(["switch", "--quiet", "--no-guess", name], in: dir)
    }

    /// Creates `name` at `start` (HEAD when nil) and switches to it.
    static func createBranch(_ name: String, at start: String?, in dir: URL) async throws {
        _ = try await run(["switch", "--quiet", "--no-track", "-c", name] + (start.map { [$0] } ?? []), in: dir)
    }

    /// A local branch following the remote branch `remote` ("origin/feature"), switched to.
    static func trackBranch(_ remote: String, as local: String, in dir: URL) async throws {
        _ = try await run(["switch", "--quiet", "-c", local, "--track", remote], in: dir)
    }

    /// Checks out a commit with no branch (a detached HEAD), to look at or build an old version.
    static func detach(at commit: String, in dir: URL) async throws {
        _ = try await run(["switch", "--quiet", "--detach", commit], in: dir)
    }

    /// The files a checkout refused to overwrite, from git's message; empty when that was not why it failed.
    static func overwrittenFiles(_ message: String) -> [String] {
        guard message.contains("would be overwritten by") else { return [] }
        var files: [String] = []
        var listing = false
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.contains("would be overwritten by") { listing = true; continue }
            guard listing else { continue }
            if line.hasPrefix("\t") { files.append(line.trimmingCharacters(in: .whitespaces)) } else if !files.isEmpty { break }
        }
        return files
    }

    // MARK: Stash (for a checkout that carries the local changes over)

    static func stash(message: String, in dir: URL) async throws {
        _ = try await run(["stash", "push", "--quiet", "--message", message], in: dir)
    }

    static func unstash(in dir: URL) async throws {
        _ = try await run(["stash", "pop", "--quiet"], in: dir)
    }

    // MARK: Remotes

    static func remotes(in dir: URL) async -> [String] {
        let out = (try? await runString(["remote"], in: dir)) ?? ""
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Brings every remote's branches up to date, dropping the ones deleted there.
    static func fetch(in dir: URL) async throws {
        _ = try await run(["fetch", "--all", "--prune", "--quiet"], in: dir)
    }

    /// - Parameter autostash: puts local changes aside first and back afterwards.
    static func pull(mode: PullMode, autostash: Bool, in dir: URL) async throws {
        var args = ["pull", "--quiet"]
        switch mode {
        case .configured: break
        case .merge: args += ["--no-rebase", "--ff"]
        case .rebase: args.append("--rebase")
        }
        // A merge commit takes git's own message; there is no editor to ask.
        if mode != .rebase { args.append("--no-edit") }
        if autostash { args.append("--autostash") }
        _ = try await run(args, in: dir, environment: ["GIT_EDITOR": "true", "GIT_MERGE_AUTOEDIT": "no"])
    }

    /// Pushes the current branch to its upstream, or to `remote` under its own name (then tracked from there).
    static func push(branch: String, setUpstreamTo remote: String?, in dir: URL) async throws {
        var args = ["push", "--quiet"]
        if let remote { args += ["--set-upstream", remote, "HEAD:refs/heads/" + branch] }
        _ = try await run(args, in: dir)
    }

    /// Commits a push would send: those not on the upstream, or with none, those on no branch of `remote`.
    static func outgoingCommits(upstream: String?, remote: String?, in dir: URL, limit: Int = 50) async -> [Commit] {
        var args = ["log", "--format=\(logFormat)", "--max-count=\(limit)"]
        if upstream != nil {
            args += ["@{upstream}..HEAD"]
        } else if let remote {
            args += ["HEAD", "--not", "--remotes=\(remote)"]
        } else {
            args += ["HEAD"]
        }
        guard let data = try? await run(args, in: dir) else { return [] }
        return parseLog(data)
    }

    /// Why a push was turned away, in git's words: the remote has commits the branch does not.
    static func isRejectedAsBehind(_ message: String) -> Bool {
        message.contains("[rejected]") && (message.contains("non-fast-forward") || message.contains("fetch first"))
    }

    /// Unmerged (conflicted) paths in the working tree, sorted for deterministic display.
    static func conflictedPaths(in dir: URL) async -> [String] {
        let out = (try? await runString(["diff", "--name-only", "--diff-filter=U", "-z"], in: dir)) ?? ""
        return out.split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Resolves the pull strategy to use during automatic push reconciliation, honoring `branch.<name>.rebase`
    /// and `pull.rebase`, and defaulting to explicit merge when unset so Git 2.27+ never aborts on divergent branches.
    static func autoPullMode(for branch: String, in dir: URL) async -> PullMode {
        func configValue(_ key: String) async -> String? {
            guard let raw = try? await runString(["config", "--get", key], in: dir) else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let resolved: String
        if let branchSetting = await configValue("branch.\(branch).rebase") {
            resolved = branchSetting.lowercased()
        } else {
            resolved = (await configValue("pull.rebase") ?? "").lowercased()
        }
        switch resolved {
        case "true", "yes", "on", "1", "merges", "preserve", "interactive":
            return .rebase
        default:
            return .merge
        }
    }

    enum PushAutoPullPhase: Sendable {
        case pushing
        case pulling
    }

    enum PushAutoPullError: Error, Sendable {
        case pullFailed(Error)
        case pushFailed(Error)
    }

    enum PushAutoPullResult: Equatable, Sendable {
        case pushed(didAutoPull: Bool, pulledCommits: Int)
        case conflicts(operation: RepoOperation?, paths: [String], autostashClash: Bool)
        case emptyOperationStop(operation: RepoOperation, message: String)
        case rejectedAsBehind(message: String)
    }

    /// Pushes `branch`, automatically pulling (`--autostash`) and retrying when the remote has new commits.
    /// Stops and reports `.conflicts` when pulling or restoring autostashed local changes hits conflicts.
    static func pushWithAutoPull(
        branch: String,
        setUpstreamTo remote: String?,
        allowAutoPull: Bool,
        pullFirst: Bool = false,
        maxPullRetries: Int = 2,
        in dir: URL,
        onPhase: (@MainActor @Sendable (PushAutoPullPhase) async -> Void)? = nil
    ) async throws -> PushAutoPullResult {
        let canAutoPull = allowAutoPull && remote == nil
        var pullsDone = 0
        var totalPulledCommits = 0
        var needPullNow = canAutoPull && pullFirst

        while true {
            if needPullNow {
                needPullNow = false
                pullsDone += 1
                await onPhase?(.pulling)
                let before = await resolveCommit("HEAD", in: dir)
                let mode = await autoPullMode(for: branch, in: dir)
                do {
                    try await pull(mode: mode, autostash: true, in: dir)
                    if let before, let after = await resolveCommit("HEAD", in: dir), before != after,
                       let out = try? await runString(["rev-list", "--count", "\(before)..@{upstream}"], in: dir),
                       let count = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        totalPulledCommits += count
                    }
                    let clashes = await conflictedPaths(in: dir)
                    if !clashes.isEmpty {
                        return .conflicts(operation: nil, paths: clashes, autostashClash: true)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let gitDir = await gitDirectory(in: dir)
                    let activeOp = gitDir.flatMap { operation(in: $0) }
                    let clashes = await conflictedPaths(in: dir)
                    if let activeOp {
                        if !clashes.isEmpty {
                            return .conflicts(operation: activeOp, paths: clashes, autostashClash: false)
                        }
                        return .emptyOperationStop(operation: activeOp, message: error.localizedDescription)
                    }
                    if !clashes.isEmpty {
                        return .conflicts(operation: nil, paths: clashes, autostashClash: true)
                    }
                    throw PushAutoPullError.pullFailed(error)
                }
            }

            await onPhase?(.pushing)
            do {
                try await push(branch: branch, setUpstreamTo: remote, in: dir)
                return .pushed(didAutoPull: pullsDone > 0, pulledCommits: totalPulledCommits)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as Failure where isRejectedAsBehind(failure.message) {
                if canAutoPull, pullsDone < maxPullRetries {
                    needPullNow = true
                    continue
                }
                return .rejectedAsBehind(message: failure.message)
            } catch {
                throw PushAutoPullError.pushFailed(error)
            }
        }
    }

    // MARK: Interrupted operations

    static func continueOperation(_ operation: RepoOperation, in dir: URL) async throws {
        // The commit message is git's own, as prepared; no editor opens.
        _ = try await run([operation.command, "--continue"], in: dir, environment: ["GIT_EDITOR": "true"])
    }

    static func abortOperation(_ operation: RepoOperation, in dir: URL) async throws {
        _ = try await run([operation.command, "--abort"], in: dir)
    }
}

// MARK: - Conflicts

/// The two versions of a file in conflict: HEAD's, and the one being merged in (the incoming commit, branch or stash).
enum ConflictSide {
    case ours, theirs

    var flag: String { self == .ours ? "--ours" : "--theirs" }
}

extension Git {
    /// Tells git a file in conflict is resolved, as it now is on disk.
    static func markResolved(_ paths: [String], in dir: URL) async throws {
        _ = try await run(["--literal-pathspecs", "add", "--"] + paths, in: dir)
    }

    /// Resolves a delete/modify or both-deleted conflict by removing the path from the index and working tree.
    static func removeResolved(_ paths: [String], in dir: URL) async throws {
        _ = try await run(["--literal-pathspecs", "rm", "-f", "-q", "--ignore-unmatch", "--"] + paths, in: dir)
    }

    /// Resolves a file in conflict by taking one side whole.
    static func takeSide(_ side: ConflictSide, path: String, in dir: URL) async throws {
        _ = try await run(["--literal-pathspecs", "checkout", side.flag, "--", path], in: dir)
        try await markResolved([path], in: dir)
    }

    /// Whether `data` still has git's conflict markers in it (a line starting with `<<<<<<< ` or `>>>>>>> `).
    static func hasConflictMarkers(_ data: Data) -> Bool {
        var atLineStart = true
        var index = data.startIndex
        while index < data.endIndex {
            let byte = data[index]
            if atLineStart, byte == UInt8(ascii: "<") || byte == UInt8(ascii: ">") {
                let end = data.index(index, offsetBy: 8, limitedBy: data.endIndex) ?? data.endIndex
                let run = data[index..<end]
                if run.count == 8, run.dropLast().allSatisfy({ $0 == byte }), run.last == UInt8(ascii: " ") || run.last == 0x0A || run.last == 0x0D {
                    return true
                }
            }
            atLineStart = byte == 0x0A
            index = data.index(after: index)
        }
        return false
    }
}

/// One conflict git wrote into a file: HEAD's lines, the base's (with `merge.conflictStyle = diff3`), the incoming
/// lines, between marker lines. Line numbers are 0-based rows of the file.
struct ConflictBlock: Equatable {
    /// The `<<<<<<<` line.
    var start: Int
    /// The `|||||||` line, when the common ancestor's lines are shown too.
    var base: Int?
    /// The `=======` line.
    var middle: Int
    /// The `>>>>>>>` line.
    var end: Int

    var ours: Range<Int> { (start + 1)..<(base ?? middle) }
    var theirs: Range<Int> { (middle + 1)..<end }

    /// Every complete conflict in `lines`, in order. A marker line is seven of its character, then a space or nothing.
    static func find(in lines: [String]) -> [ConflictBlock] {
        func marker(_ line: String, _ character: Character) -> Bool {
            guard line.count >= 7 else { return false }
            let prefix = line.prefix(7)
            guard prefix.allSatisfy({ $0 == character }) else { return false }
            return line.count == 7 || line.dropFirst(7).first == " " || line.dropFirst(7).first == "\r"
        }
        var blocks: [ConflictBlock] = []
        var start: Int?, base: Int?, middle: Int?
        for (index, line) in lines.enumerated() {
            guard let first = line.first, first == "<" || first == "|" || first == "=" || first == ">" else { continue }
            if marker(line, "<") {
                (start, base, middle) = (index, nil, nil)
            } else if start != nil, middle == nil, base == nil, marker(line, "|") {
                base = index
            } else if start != nil, middle == nil, marker(line, "=") {
                middle = index
            } else if let s = start, let m = middle, marker(line, ">") {
                blocks.append(ConflictBlock(start: s, base: base, middle: m, end: index))
                (start, base, middle) = (nil, nil, nil)
            }
        }
        return blocks
    }

    /// The lines that replace the whole block for `choice`.
    func resolution(_ choice: ConflictChoice, in lines: [String]) -> [String] {
        switch choice {
        case .ours: return Array(lines[ours])
        case .theirs: return Array(lines[theirs])
        case .both: return Array(lines[ours]) + Array(lines[theirs])
        }
    }
}

enum ConflictChoice: Equatable { case ours, theirs, both }

/// Which version of a file in conflict the left side of the viewer shows; the right side is the file itself.
enum ConflictBase: String, CaseIterable {
    case head, base, incoming

    /// For `git cat-file`: HEAD's version, or the index stage git keeps for the conflict (1 base, 3 incoming).
    var rev: String {
        switch self {
        case .head: return "HEAD"
        case .base: return ":1"
        case .incoming: return ":3"
        }
    }

    var title: String {
        switch self {
        case .head: return "HEAD"
        case .base: return L("Base", "共同祖先")
        case .incoming: return L("Incoming", "传入")
        }
    }
}
