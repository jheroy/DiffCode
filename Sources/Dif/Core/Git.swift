import Foundation

/// Thin async wrapper around the `git` executable.
///
/// Shelling out keeps Dif tiny (no libgit2) and guarantees results match what the
/// user sees on the command line. Every call sets `GIT_OPTIONAL_LOCKS=0` so a
/// background refresh never takes the index lock away from the user's own git.
enum Git {
    struct Failure: Error, LocalizedError {
        let status: Int32
        let message: String
        var errorDescription: String? { message.isEmpty ? "git exited with status \(status)" : message }
    }

    /// SHA of git's well-known empty tree; used as the base of a repo with no commits.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// The system's shim, which picks the developer tools' git through xcrun.
    private static let shim = "/usr/bin/git"

    /// Resolved on first use. The shim costs ~10ms per launch and refuses to run in the App Sandbox at all,
    /// so the binary itself is used wherever one exists.
    static var executable: String {
        executableLock.lock()
        defer { executableLock.unlock() }
        if let resolvedExecutable { return resolvedExecutable }
        let found = locateExecutable()
        resolvedExecutable = found
        return found
    }

    /// Looks again, after the user installed the developer tools.
    static func relocateExecutable() {
        executableLock.lock()
        resolvedExecutable = nil
        executableLock.unlock()
    }

    private static let executableLock = NSLock()
    nonisolated(unsafe) private static var resolvedExecutable: String?

    private static func locateExecutable() -> String {
        let fm = FileManager.default
        if let found = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return found }
        guard !Sandbox.isActive else { return shim }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-f", "git"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        if (try? probe.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            probe.waitUntilExit()
            let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if probe.terminationStatus == 0, fm.isExecutableFile(atPath: path) { return path }
        }
        return shim
    }

    /// Real git binaries, in the order a shell would most likely find them: Homebrew's, then the active developer
    /// directory's (what `xcode-select -p` names), then the Command Line Tools' and Xcode's.
    static var candidates: [String] {
        var list = ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !developer.isEmpty {
            list.append(developer + "/usr/bin/git")
        }
        if let active = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            list.append(active + "/usr/bin/git")
        }
        list.append("/Library/Developer/CommandLineTools/usr/bin/git")
        list.append("/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        return list
    }

    /// False only in the sandbox with no developer tools installed: then nothing here can work.
    static var isAvailable: Bool { !Sandbox.isActive || executable != shim }

    private static let baseEnvironment: [String: String] = {
        var env = AppEnvironment.childEnvironment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["LC_ALL"] = "C"
        return env
    }()

    /// In the sandbox `$HOME` is the app's container, where git finds none of the user's settings. Once the user
    /// granted their home folder, git gets the real one and behaves as in a shell (settings, includes, global ignores);
    /// with only the settings file granted, it reads that. Checked on every launch, since a grant can come at any time.
    /// Never a file it cannot read: git stops on a settings file the sandbox refuses rather than skipping it.
    private static var environment: [String: String] {
        guard Sandbox.isActive else { return baseEnvironment }
        var env = baseEnvironment
        if Sandbox.canReadHome {
            env["HOME"] = Sandbox.realHome
        } else if FileManager.default.isReadableFile(atPath: Sandbox.globalGitConfig) {
            env["GIT_CONFIG_GLOBAL"] = Sandbox.globalGitConfig
        }
        return env
    }

    private static let baseArgs = ["--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=false"]

    /// What a background reader collected; read only after the reader is known to be done (a group wait).
    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// The parse state of a `git grep` stream, touched only by the stream's chunks, which come one at a time.
    private final class GrepState: @unchecked Sendable {
        var pending = Data()
        var total = 0
    }

    /// Lets a cancelled Swift task terminate the underlying process.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }

        func attach(_ p: Process) {
            lock.lock(); process = p; let c = isCancelled; lock.unlock()
            if c, p.isRunning { p.terminate() }
        }

        func cancel() {
            lock.lock(); isCancelled = true; let p = process; lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    private static func makeProcess(_ args: [String], in dir: URL, extraEnvironment: [String: String] = [:]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = baseArgs + args
        p.currentDirectoryURL = dir
        p.environment = extraEnvironment.isEmpty ? environment : environment.merging(extraEnvironment) { _, extra in extra }
        p.standardInput = FileHandle.nullDevice
        return p
    }

    /// Runs git and returns stdout. Throws `Failure` unless the exit status is in `okStatuses`.
    /// - Parameter environment: added to git's usual environment (`GIT_INDEX_FILE`, `GIT_EDITOR`).
    static func run(_ args: [String], in dir: URL, okStatuses: Set<Int32> = [0],
                    environment extra: [String: String] = [:]) async throws -> Data {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = makeProcess(args, in: dir, extraEnvironment: extra)
                    let out = Pipe(), err = Pipe()
                    p.standardOutput = out
                    p.standardError = err
                    do { try p.run() } catch { cont.resume(throwing: error); return }
                    box.attach(p)

                    // Drain stderr on another thread so a chatty process can't deadlock on a full pipe.
                    let errBuffer = OutputBuffer()
                    let group = DispatchGroup()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBuffer.data = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    let errData = errBuffer.data
                    p.waitUntilExit()

                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if okStatuses.contains(p.terminationStatus) {
                        cont.resume(returning: data)
                    } else {
                        var msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        // Some commands report on stdout (a merge's CONFLICT lines); keep that too, briefly.
                        let out = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !out.isEmpty, out.contains("CONFLICT") || msg.isEmpty { msg = msg.isEmpty ? out : out + "\n" + msg }
                        cont.resume(throwing: Failure(status: p.terminationStatus, message: msg))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    static func runString(_ args: [String], in dir: URL, okStatuses: Set<Int32> = [0],
                          environment extra: [String: String] = [:]) async throws -> String {
        String(decoding: try await run(args, in: dir, okStatuses: okStatuses, environment: extra), as: UTF8.self)
    }

    /// Streams stdout in chunks, one after another on a background thread. Return `false` from `onChunk` to stop
    /// early (the process is terminated).
    static func stream(_ args: [String], in dir: URL, onChunk: @escaping @Sendable (Data) -> Bool) async throws {
        let box = ProcessBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let p = makeProcess(args, in: dir)
                    let out = Pipe()
                    p.standardOutput = out
                    p.standardError = FileHandle.nullDevice
                    do { try p.run() } catch { cont.resume(throwing: error); return }
                    box.attach(p)
                    let handle = out.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        if box.cancelled || !onChunk(chunk) {
                            if p.isRunning { p.terminate() }
                            break
                        }
                    }
                    p.waitUntilExit()
                    if box.cancelled { cont.resume(throwing: CancellationError()) } else { cont.resume() }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Repository discovery

    /// The repository root containing `url`, or nil when it is not inside a work tree.
    static func repositoryRoot(for url: URL) async -> URL? {
        guard let out = try? await runString(["rev-parse", "--show-toplevel"], in: url) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// One of a repository's work trees, as `git worktree list` has it.
    struct Worktree: Equatable {
        var path: String
        /// "refs/heads/x"; nil when detached or bare.
        var branch: String?
        var isBare = false
        /// Git's record of a work tree whose folder is gone.
        var isPrunable = false
    }

    /// The repository's work trees, the main one first. Empty when git could not say.
    static func worktrees(in dir: URL) async -> [Worktree] {
        guard let text = try? await runString(["worktree", "list", "--porcelain"], in: dir) else { return [] }
        return parseWorktrees(text)
    }

    static func parseWorktrees(_ text: String) -> [Worktree] {
        var list: [Worktree] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                list.append(Worktree(path: String(line.dropFirst("worktree ".count))))
            } else if !list.isEmpty {
                if line.hasPrefix("branch ") { list[list.count - 1].branch = String(line.dropFirst("branch ".count)) }
                if line == "bare" { list[list.count - 1].isBare = true }
                if line.hasPrefix("prunable") { list[list.count - 1].isPrunable = true }
            }
        }
        return list
    }

    /// The most repositories one chosen folder adds.
    static let discoveryLimit = 60

    /// The repositories a folder the user chose stands for: the one it is in, or those directly inside a plain
    /// folder, each followed by the independent repositories inside it (a workspace that is a repository itself,
    /// with others in it).
    static func repositories(for directory: URL) async -> [URL] {
        var found: [URL] = []
        var seen = Set<String>()
        func add(_ repository: URL) async {
            guard found.count < discoveryLimit, seen.insert(repository.standardizedFileURL.path).inserted else { return }
            found.append(repository)
            for inner in await repositories(inside: repository) { await add(inner) }
        }
        if let root = await repositoryRoot(for: directory) {
            await add(root)
        } else {
            for repository in nestedRepositories(in: directory) { await add(repository) }
        }
        return found
    }

    /// The independent repositories in a repository's work tree, by what git says of its folders: one git does
    /// not track is a candidate, and an ignored one counts only when it is a repository itself, so nothing is
    /// looked for inside `node_modules` and the like. Not submodules (tracked), not hidden folders, and not linked
    /// work trees, which belong to a repository rather than stand beside it.
    static func repositories(inside repository: URL) async -> [URL] {
        let list = ["ls-files", "-z", "--others", "--exclude-standard", "--directory", "--no-empty-directory"]
        async let untrackedOutput = try? run(list, in: repository)
        async let ignoredOutput = try? run(list + ["--ignored"], in: repository)
        func folders(_ data: Data?) -> [URL] {
            (data ?? Data()).split(separator: 0).compactMap { entry in
                guard entry.last == UInt8(ascii: "/") else { return nil }
                let path = String(decoding: entry.dropLast(), as: UTF8.self)
                guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { return nil }
                return repository.appendingPathComponent(path, isDirectory: true)
            }
        }
        var found: [URL] = []
        for folder in folders(await untrackedOutput) {
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
                if isIndependentRepository(folder) { found.append(folder) }
            } else {
                found += nestedRepositories(in: folder).filter(isIndependentRepository)
            }
        }
        found += folders(await ignoredOutput).filter(isIndependentRepository)
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Whether a folder is a repository of its own: `.git` is a folder, or a file that names one elsewhere
    /// (`--separate-git-dir`). A linked work tree's `.git` file points into its repository's `worktrees`.
    static func isIndependentRepository(_ folder: URL) -> Bool {
        let dotGit = folder.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return false }
        if isDirectory.boolValue { return true }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8) else { return false }
        return !text.replacingOccurrences(of: "\\", with: "/").contains("/worktrees/")
    }

    /// Repositories directly inside a plain folder (handy for multi-repo workspaces).
    static func nestedRepositories(in url: URL, maxDepth: Int = 2) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        func scan(_ dir: URL, depth: Int) {
            guard depth <= maxDepth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if fm.fileExists(atPath: entry.appendingPathComponent(".git").path) {
                    found.append(entry)
                } else {
                    scan(entry, depth: depth + 1)
                }
                if found.count >= discoveryLimit { return }
            }
        }
        scan(url, depth: 1)
        return found
    }
}

// MARK: - Status

struct FileChange: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case modified, added, deleted, renamed, untracked, conflicted

        var letter: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .renamed: return "R"
            case .untracked: return "U"
            case .conflicted: return "!"
            }
        }
    }

    var path: String
    var oldPath: String?
    var kind: Kind
    var isSubmodule = false
    var additions: Int?
    var deletions: Int?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

struct RepoStatus: Equatable {
    var branch: String?
    var headOID: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var isInitial = false
    var changes: [FileChange] = []
    /// A merge, rebase, cherry-pick or revert that stopped for the user.
    var operation: RepoOperation?

    var conflictCount: Int { changes.reduce(0) { $0 + ($1.kind == .conflicted ? 1 : 0) } }

    /// Canonical identifier for the repository's active conflict set, or `nil` when no conflicts exist.
    var conflictSignature: String? {
        let paths = changes.filter { $0.kind == .conflicted }.map(\.path).sorted()
        guard !paths.isEmpty else { return nil }
        return "\(operation?.rawValue ?? "")|\(headOID ?? "")|" + paths.joined(separator: "\n")
    }

    var shortHead: String { headOID.map { String($0.prefix(7)) } ?? "" }
}

extension Git {
    static func status(in dir: URL, gitDirectory: URL? = nil) async throws -> RepoStatus {
        let data = try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: dir)
        var status = parseStatus(data)
        if let gitDirectory { status.operation = operation(in: gitDirectory) }
        if !status.changes.isEmpty {
            await applyNumstat(to: &status, in: dir)
        }
        return status
    }

    /// Parses `git status --porcelain=v2 --branch -z`.
    static func parseStatus(_ data: Data) -> RepoStatus {
        var status = RepoStatus()
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard let first = token.first else { continue }
            switch first {
            case "#":
                let parts = token.split(separator: " ", maxSplits: 2).map(String.init)
                guard parts.count >= 3 else { continue }
                switch parts[1] {
                case "branch.oid":
                    if parts[2] == "(initial)" { status.isInitial = true } else { status.headOID = parts[2] }
                case "branch.head":
                    status.branch = parts[2] == "(detached)" ? nil : parts[2]
                case "branch.upstream":
                    status.upstream = parts[2]
                case "branch.ab":
                    for piece in parts[2].split(separator: " ") {
                        if piece.hasPrefix("+") { status.ahead = Int(piece.dropFirst()) ?? 0 }
                        if piece.hasPrefix("-") { status.behind = Int(piece.dropFirst()) ?? 0 }
                    }
                default: break
                }
            case "1":
                // 1 XY sub mH mI mW hH hI path
                let f = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 9 else { continue }
                status.changes.append(FileChange(path: f[8], oldPath: nil, kind: kind(xy: f[1]), isSubmodule: f[2].hasPrefix("S")))
            case "2":
                // 2 XY sub mH mI mW hH hI Xscore path <NUL> origPath
                let f = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
                let orig = i < tokens.count ? tokens[i] : nil
                i += 1
                guard f.count == 10 else { continue }
                var k = kind(xy: f[1])
                var old = orig
                // A copy leaves the source in place, so present it as a plain addition.
                if f[8].hasPrefix("C") { k = .added; old = nil } else if k == .modified { k = .renamed }
                status.changes.append(FileChange(path: f[9], oldPath: old, kind: k, isSubmodule: f[2].hasPrefix("S")))
            case "u":
                // u XY sub m1 m2 m3 mW h1 h2 h3 path
                let f = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
                guard f.count == 11 else { continue }
                status.changes.append(FileChange(path: f[10], oldPath: nil, kind: .conflicted))
            case "?":
                status.changes.append(FileChange(path: String(token.dropFirst(2)), oldPath: nil, kind: .untracked))
            default:
                break
            }
        }
        status.changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return status
    }

    /// Collapses the index (X) and worktree (Y) columns into one HEAD-vs-worktree verdict,
    /// which is how Android Studio's "Changes" list presents things.
    private static func kind(xy: String) -> FileChange.Kind {
        let chars = Array(xy)
        guard chars.count == 2 else { return .modified }
        let x = chars[0], y = chars[1]
        if x == "U" || y == "U" { return .conflicted }
        if y == "D" || x == "D" { return .deleted }
        if x == "A" { return .added }
        if x == "R" { return .renamed }
        return .modified
    }

    private static func applyNumstat(to status: inout RepoStatus, in dir: URL) async {
        let base = status.isInitial ? emptyTree : "HEAD"
        var stats: [String: (Int, Int)] = [:]
        if let data = try? await run(["diff", "--numstat", "-z", "-M", base], in: dir) {
            stats = parseNumstat(data)
        }
        let root = dir
        for idx in status.changes.indices {
            let change = status.changes[idx]
            if let s = stats[change.path] {
                status.changes[idx].additions = s.0
                status.changes[idx].deletions = s.1
            } else if change.kind == .untracked, let lines = lineCount(root.appendingPathComponent(change.path)) {
                // Untracked files are invisible to `git diff`; their lines are counted directly.
                status.changes[idx].additions = lines
                status.changes[idx].deletions = 0
            }
        }
    }

    /// Lines in a text file of up to 512 KB; nil for anything bigger, binary or unreadable.
    static func lineCount(_ url: URL) -> Int? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 512 * 1024,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe), !TextCodec.looksBinary(data) else { return nil }
        return lineCount(of: data)
    }

    /// Lines as git counts them: a last line without a newline counts, a final newline adds none.
    static func lineCount(of data: Data) -> Int {
        var lines = data.reduce(into: 0) { if $1 == 0x0A { $0 += 1 } }
        if let last = data.last, last != 0x0A { lines += 1 }
        return lines
    }

    /// Parses `git diff --numstat -z`. Renames are emitted as `a\tb\t\0old\0new\0`.
    static func parseNumstat(_ data: Data) -> [String: (Int, Int)] {
        var result: [String: (Int, Int)] = [:]
        let tokens = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            i += 1
            let f = token.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard f.count == 3 else { continue }
            var path = f[2]
            if path.isEmpty, i + 1 < tokens.count {
                path = tokens[i + 1]
                i += 2
            }
            guard let added = Int(f[0]), let deleted = Int(f[1]) else { continue } // "-" marks binary
            result[path] = (added, deleted)
        }
        return result
    }
}

// MARK: - Log

struct Commit: Identifiable, Hashable {
    var hash: String
    var parents: [String]
    var author: String
    var email: String
    var date: Date
    var refs: [String]
    var subject: String
    var body: String = ""

    var id: String { hash }
    var shortHash: String { String(hash.prefix(7)) }
    var isMerge: Bool { parents.count > 1 }
}

extension Git {
    /// One commit's fields, separated by 0x1f; `logFormat` ends each record with 0x1e.
    static let logFields = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s"
    static let logFormat = logFields + "%x1e"

    /// Revision arguments for "All branches": standard branches, remotes, tags, and HEAD by default,
    /// excluding internal tool refs such as `refs/t3/*`, `refs/notes/*`, `refs/stash`.
    /// Set `includeInternalRefs: true` to pass `--all` and show every ref under `refs/`.
    static func allBranchesScope(includeInternalRefs: Bool = false) -> [String] {
        // `--ignore-missing` keeps unborn `HEAD` (e.g. an orphan branch or empty repo) from failing the whole query.
        includeInternalRefs ? ["--all"] : ["--ignore-missing", "HEAD", "--branches", "--remotes", "--tags"]
    }

    /// - Parameter ref: a full ref name (`refs/heads/x`) whose history to list instead of HEAD's. Ignored with `allBranches`.
    /// - Parameter includeInternalRefs: when `allBranches` is true, also walk internal refs such as `refs/t3/*` and `refs/stash`.
    static func log(in dir: URL, skip: Int, limit: Int, query: String, allBranches: Bool, ref: String? = nil,
                    includeInternalRefs: Bool = false) async throws -> [Commit] {
        // A full ref name never starts with "-", so it cannot be read as an option.
        let scope = allBranches ? allBranchesScope(includeInternalRefs: includeInternalRefs) : (ref.map { [$0] } ?? [])
        // Full ref names, so a local "feature/x" and a remote "origin/x" can be told apart.
        var args = ["log", "--format=\(logFormat)", "--decorate=full", "--skip=\(skip)", "--max-count=\(limit)", "--date-order"] + scope
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            // Match the subject/body or the author, case-insensitively.
            args += ["-i", "--fixed-strings", "--grep=\(q)"]
        }
        let data = try await run(args, in: dir, okStatuses: [0, 128])
        var commits = parseLog(data)
        if !q.isEmpty, skip == 0 {
            // A query that looks like a hash should also find that commit; author matches are merged in too.
            if q.count >= 4, q.allSatisfy({ $0.isHexDigit }),
               let hit = try? await run(["log", "-1", "--format=\(logFormat)", "--decorate=full", q], in: dir) {
                let direct = parseLog(hit)
                commits = direct + commits.filter { c in !direct.contains(where: { $0.hash == c.hash }) }
            }
            if let byAuthor = try? await run(["log", "--format=\(logFormat)", "--decorate=full", "--max-count=\(limit)", "-i", "--author=\(q)"]
                                             + scope, in: dir) {
                let seen = Set(commits.map(\.hash))
                commits += parseLog(byAuthor).filter { !seen.contains($0.hash) }
                commits.sort { $0.date > $1.date }
            }
        }
        return commits
    }

    static func parseLog(_ data: Data) -> [Commit] {
        data.split(separator: 0x1e, omittingEmptySubsequences: true).compactMap(parseCommit)
    }

    /// One record of `logFields`.
    static func parseCommit(_ record: Data) -> Commit? {
        let fields = record.split(separator: 0x1f, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        guard fields.count >= 7 else { return nil }
        let hash = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard hash.count >= 7 else { return nil }
        let refs = fields[5].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return Commit(
            hash: hash,
            parents: fields[1].split(separator: " ").map(String.init),
            author: fields[2],
            email: fields[3],
            date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
            refs: refs,
            subject: fields[6]
        )
    }

    static func commitBody(_ hash: String, in dir: URL) async -> String {
        ((try? await runString(["log", "-1", "--format=%B", hash], in: dir)) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Files touched by a commit, compared against its first parent (or the empty tree for a root commit).
    static func commitFiles(_ commit: Commit, in dir: URL) async throws -> [FileChange] {
        let base = commit.parents.first ?? emptyTree
        async let namesData = run(["diff", "--name-status", "-z", "-M", base, commit.hash], in: dir)
        async let statData = run(["diff", "--numstat", "-z", "-M", base, commit.hash], in: dir)
        let stats = parseNumstat((try? await statData) ?? Data())
        var changes = parseNameStatus(try await namesData)
        for idx in changes.indices {
            if let s = stats[changes[idx].path] {
                changes[idx].additions = s.0
                changes[idx].deletions = s.1
            }
        }
        return changes
    }

    /// Parses `git diff --name-status -z`: `M\0path\0`, `R100\0old\0new\0`.
    static func parseNameStatus(_ data: Data) -> [FileChange] {
        let tokens = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
        var changes: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let letter = code.first, i < tokens.count else { break }
            switch letter {
            case "R":
                guard i + 1 < tokens.count else { return changes }
                changes.append(FileChange(path: tokens[i + 1], oldPath: tokens[i], kind: .renamed))
                i += 2
            case "C":
                guard i + 1 < tokens.count else { return changes }
                changes.append(FileChange(path: tokens[i + 1], oldPath: nil, kind: .added))
                i += 2
            case "A":
                changes.append(FileChange(path: tokens[i], oldPath: nil, kind: .added)); i += 1
            case "D":
                changes.append(FileChange(path: tokens[i], oldPath: nil, kind: .deleted)); i += 1
            case "U":
                changes.append(FileChange(path: tokens[i], oldPath: nil, kind: .conflicted)); i += 1
            default:
                changes.append(FileChange(path: tokens[i], oldPath: nil, kind: .modified)); i += 1
            }
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return changes
    }

    /// Blob contents at `rev:path`, or nil when the path does not exist in that revision.
    static func blob(rev: String, path: String, in dir: URL) async -> Data? {
        try? await run(["cat-file", "blob", "\(rev):\(path)"], in: dir)
    }

    /// Every tracked and untracked-but-not-ignored file, relative to the repository root.
    static func listFiles(in dir: URL) async -> [String] {
        guard let data = try? await run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: dir) else { return [] }
        var seen = Set<String>()
        var files: [String] = []
        for token in data.split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: token, as: UTF8.self)
            if seen.insert(path).inserted { files.append(path) }
        }
        return files
    }
}

// MARK: - Grep

struct GrepHit: Hashable {
    var path: String
    var line: Int
    var column: Int
    var text: String
}

struct GrepOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    var fileMask = ""
}

extension Git {
    /// Streams `git grep` matches. Covers tracked and untracked files while honouring .gitignore.
    static func grep(_ pattern: String, options: GrepOptions, in dir: URL, limit: Int,
                     onHits: @escaping @Sendable ([GrepHit]) -> Void) async throws {
        var args = ["grep", "-n", "--column", "-I", "--untracked", "--null", "--no-color"]
        args.append(options.regex ? "-E" : "-F")
        if !options.caseSensitive { args.append("-i") }
        if options.wholeWord { args.append("-w") }
        args += ["-e", pattern]
        let masks = options.fileMask.split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" }).map(String.init)
        if !masks.isEmpty {
            args.append("--")
            args += masks.map { $0.contains("*") || $0.contains("/") ? $0 : "*\($0)*" }
        }

        let state = GrepState()
        try await stream(args, in: dir) { chunk in
            state.pending.append(chunk)
            var hits: [GrepHit] = []
            // Records are newline-terminated; hold back a trailing partial record for the next chunk.
            var cursor = state.pending.startIndex
            while let newline = state.pending[cursor...].firstIndex(of: 0x0A) {
                let record = state.pending[cursor..<newline]
                cursor = state.pending.index(after: newline)
                if let hit = parseGrepRecord(record) {
                    hits.append(hit)
                    state.total += 1
                    if state.total >= limit { break }
                }
            }
            state.pending = Data(state.pending[cursor...])
            if !hits.isEmpty { onHits(hits) }
            return state.total < limit
        }
    }

    /// One `--null` record: `path\0line\0column\0text`.
    static func parseGrepRecord(_ record: Data) -> GrepHit? {
        let parts = record.split(separator: 0, maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              let line = Int(String(decoding: parts[1], as: UTF8.self)),
              let column = Int(String(decoding: parts[2], as: UTF8.self)) else { return nil }
        var textData = parts[3]
        if textData.last == 0x0D { textData = textData.dropLast() }
        // Minified files can put megabytes on one line; keep only a window around the match.
        var col = column
        if textData.count > 400 {
            let start = max(0, column - 1 - 120)
            let end = min(textData.count, start + 400)
            textData = textData[(textData.startIndex + start)..<(textData.startIndex + end)]
            col = column - start
        }
        return GrepHit(path: String(decoding: parts[0], as: UTF8.self), line: line, column: col,
                       text: String(decoding: textData, as: UTF8.self))
    }
}

// MARK: - Tags

/// Metadata for a local Git tag, capturing enough detail to rename or restore both lightweight and annotated tags.
struct GitTagInfo: Equatable, Sendable {
    var name: String
    /// Peeled target object hash (usually a commit SHA).
    var target: String
    /// True for an annotated tag object (`objecttype == "tag"`), false for a lightweight tag.
    var isAnnotated: Bool
    /// Raw annotation message for annotated tags; nil for lightweight tags.
    var message: String?
    var taggerName: String?
    var taggerEmail: String?
    var taggerDate: String?
}

extension Git {
    /// Why `name` cannot be used as a tag name, or nil when valid. Mirrors `git check-ref-format refs/tags/<name>`.
    static func tagNameProblem(_ name: String, existing: Set<String>) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return L("Type a name", "请输入名称") }
        if existing.contains(trimmed) { return L("A tag named “\(trimmed)” already exists", "已有名为“\(trimmed)”的标签") }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        let bad = trimmed.hasPrefix("-") || trimmed.hasPrefix("/") || trimmed.hasSuffix("/") || trimmed.hasSuffix(".")
            || trimmed.hasSuffix(".lock") || trimmed.contains("..") || trimmed.contains("//") || trimmed.contains("@{")
            || trimmed == "@" || trimmed == "HEAD"
            || components.contains { $0.isEmpty || $0.hasPrefix(".") || $0.hasSuffix(".lock") }
            || trimmed.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || " ~^:?*[\\".unicodeScalars.contains($0) }
        return bad ? L("Not a valid tag name", "不是有效的标签名") : nil
    }

    /// Reads whether a local tag exists.
    static func tagExists(_ name: String, in dir: URL) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { return false }
        return (try? await run(["rev-parse", "--verify", "--quiet", "refs/tags/\(trimmed)"], in: dir)) != nil
    }

    /// Inspects a local tag (lightweight or annotated), including its peeled target commit and annotation metadata.
    static func tagInfo(_ name: String, in dir: URL) async throws -> GitTagInfo {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            throw WorkingTree.Failure(message: L("Not a valid tag name.", "不是有效的标签名。"))
        }
        let fullRef = "refs/tags/\(trimmed)"
        let format = "%(refname)%1f%(objecttype)%1f%(objectname)%1f%(*objectname)%1f%(taggername)%1f%(taggeremail)%1f%(taggerdate:raw)%1f%(contents)%00"
        let data = try await run(["for-each-ref", "--format=\(format)", fullRef], in: dir)
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            let fields = record.split(separator: 0x1f, maxSplits: 7, omittingEmptySubsequences: false).map {
                String(decoding: $0, as: UTF8.self)
            }
            guard fields.count == 8 else { continue }
            let refName = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard refName == fullRef else { continue }
            let objectType = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let objectHash = fields[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let peeledHash = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            let target = peeledHash.isEmpty ? objectHash : peeledHash
            if objectType == "tag" {
                let taggerName = fields[4].trimmingCharacters(in: .whitespacesAndNewlines)
                var taggerEmail = fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
                if taggerEmail.hasPrefix("<") { taggerEmail.removeFirst() }
                if taggerEmail.hasSuffix(">") { taggerEmail.removeLast() }
                let taggerDate = fields[6].trimmingCharacters(in: .whitespacesAndNewlines)
                return GitTagInfo(
                    name: trimmed,
                    target: target,
                    isAnnotated: true,
                    message: fields[7],
                    taggerName: taggerName.isEmpty ? nil : taggerName,
                    taggerEmail: taggerEmail.isEmpty ? nil : taggerEmail,
                    taggerDate: taggerDate.isEmpty ? nil : taggerDate
                )
            }
            return GitTagInfo(name: trimmed, target: target, isAnnotated: false)
        }
        throw WorkingTree.Failure(message: L("Tag “\(trimmed)” does not exist.", "标签“\(trimmed)”不存在。"))
    }

    /// Creates a local tag at `target` (default `HEAD`). A non-empty `message` creates an annotated tag;
    /// nil or whitespace-only creates a lightweight tag.
    static func createTag(_ name: String, at target: String = "HEAD", message: String? = nil, in dir: URL) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let problem = tagNameProblem(trimmed, existing: []) {
            throw WorkingTree.Failure(message: problem)
        }
        if await tagExists(trimmed, in: dir) {
            throw WorkingTree.Failure(message: L("A tag named “\(trimmed)” already exists", "已有名为“\(trimmed)”的标签"))
        }
        let trimmedTarget = target.trimmingCharacters(in: .whitespaces)
        let rev = trimmedTarget.isEmpty ? "HEAD" : trimmedTarget
        guard !rev.hasPrefix("-") else {
            throw WorkingTree.Failure(message: L("Invalid tag target.", "无效的标签目标。"))
        }
        let note = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if note.isEmpty {
            _ = try await run(["tag", trimmed, rev], in: dir)
        } else {
            _ = try await run(["tag", "-a", "--cleanup=verbatim", trimmed, "-m", note, rev], in: dir)
        }
    }

    /// Deletes a local tag.
    static func deleteTag(_ name: String, in dir: URL) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else {
            throw WorkingTree.Failure(message: L("Not a valid tag name.", "不是有效的标签名。"))
        }
        _ = try await run(["tag", "-d", trimmed], in: dir)
    }

    /// Restores a deleted local tag (lightweight or annotated, preserving message and tagger metadata).
    static func restoreTag(_ info: GitTagInfo, in dir: URL) async throws {
        if let problem = tagNameProblem(info.name, existing: []) {
            throw WorkingTree.Failure(message: problem)
        }
        if await tagExists(info.name, in: dir) {
            throw WorkingTree.Failure(message: L("A tag named “\(info.name)” already exists", "已有名为“\(info.name)”的标签"))
        }
        if info.isAnnotated {
            var env: [String: String] = [:]
            if let taggerName = info.taggerName, !taggerName.isEmpty { env["GIT_COMMITTER_NAME"] = taggerName }
            if let taggerEmail = info.taggerEmail, !taggerEmail.isEmpty { env["GIT_COMMITTER_EMAIL"] = taggerEmail }
            if let taggerDate = info.taggerDate, !taggerDate.isEmpty { env["GIT_COMMITTER_DATE"] = taggerDate }
            _ = try await run(["tag", "-a", "--cleanup=verbatim", info.name, "-m", info.message ?? "", info.target],
                              in: dir, environment: env)
        } else {
            _ = try await run(["tag", info.name, info.target], in: dir)
        }
    }

    /// Renames a local tag by creating the new tag first (preserving lightweight vs annotated type, message,
    /// and tagger metadata) and deleting the old tag only after creation succeeds.
    static func renameTag(_ oldName: String, to newName: String, in dir: URL) async throws {
        let oldTrimmed = oldName.trimmingCharacters(in: .whitespaces)
        let newTrimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !oldTrimmed.isEmpty, !oldTrimmed.hasPrefix("-") else {
            throw WorkingTree.Failure(message: L("Not a valid tag name.", "不是有效的标签名。"))
        }
        if let problem = tagNameProblem(newTrimmed, existing: []) {
            throw WorkingTree.Failure(message: problem)
        }
        if oldTrimmed == newTrimmed {
            throw WorkingTree.Failure(message: L("Enter a different tag name", "请输入不同的标签名"))
        }
        if await tagExists(newTrimmed, in: dir) {
            throw WorkingTree.Failure(message: L("A tag named “\(newTrimmed)” already exists", "已有名为“\(newTrimmed)”的标签"))
        }
        var info = try await tagInfo(oldTrimmed, in: dir)
        info.name = newTrimmed
        try await restoreTag(info, in: dir)
        try await deleteTag(oldTrimmed, in: dir)
    }
}
