import Foundation
import Observation

/// What the list column shows. The file tree lives in the sidebar and is always there.
enum ProjectTab: String { case changes, log }

/// The Log narrowed to one file's commits, or to the commits that changed some of its lines.
struct HistoryFilter: Equatable {
    /// The file's path in `rev`.
    var path: String
    /// 1-based lines of the file as `rev` has it; nil for the whole file.
    var lines: ClosedRange<Int>?
    /// Where the history starts, and where `lines` are counted.
    var rev: String = "HEAD"

    var name: String { (path as NSString).lastPathComponent }

    /// "Main.kt", "Main.kt:12-20".
    var label: String {
        guard let lines else { return name }
        return lines.count > 1 ? "\(name):\(lines.lowerBound)-\(lines.upperBound)" : "\(name):\(lines.lowerBound)"
    }
}

/// The Changes tab comparing the working tree with another commit or branch instead of HEAD:
/// everything that changed since then, committed or not, as when reviewing what an agent did.
/// Or comparing two commits with each other, picked together in the Log or the Git graph.
struct Comparison: Equatable {
    /// What was picked: a full ref name or a commit hash. Resolved again on each refresh, since a branch moves.
    var target: String
    /// "main", "a1b2c3d".
    var title: String
    /// Compare with where HEAD and `target` forked, so commits made on `target` since then do not show, reversed.
    var forkPoint: Bool
    /// The commit compared with.
    var base: String
    /// The newer end, when two commits are compared; nil for the working tree.
    var other: End?
    /// The stash shown, when the list holds what a stash put aside (against the commit it was made on).
    var stash: StashEntry?

    struct End: Equatable {
        var target: String
        var title: String
        var hash: String
    }

    /// The commit on the right, or nil for the working tree.
    var head: String? { other?.hash }
}

/// A repository in the sidebar, with its live status and per-project UI state.
@MainActor
@Observable
final class Project: Identifiable {
    let id = UUID()
    let url: URL
    var name: String

    var status = RepoStatus()
    var hasLoaded = false
    var isRefreshing = false
    var errorMessage: String?
    /// The sandbox no longer opens this project's folder (Mac App Store edition): it stays listed, but nothing in it
    /// can be read until the user grants it again.
    var needsAccess = false

    /// A linked work tree shown under its repository: the project of the main work tree.
    var worktreeOf: UUID?
    /// Listed because git has it as a work tree, not because the user added it: never saved, and gone with the work tree.
    var isDerived = false
    /// Folded away in the sidebar (only a derived work tree is): no watching and no status until it is in sight.
    @ObservationIgnored var isDormant = false
    /// When the folder git keeps its work trees in last changed, as of the last look at them (nil: never looked).
    @ObservationIgnored var worktreesStamp: Date??

    var tab: ProjectTab = .changes

    // Local changes
    var selectedChangeID: String?
    /// Every selected row of the Changes list, for commands that act on several files. Includes `selectedChangeID`.
    var selectedChangeIDs: Set<String> = []
    var collapsed: Set<String> = []
    var filter = ""

    // Commit
    /// Ticks the user changed. Everything else follows the default: tracked changes ticked, unversioned files not.
    var commitOverrides: [String: Bool] = [:] {
        didSet { onInclusionChanged?() }
    }
    /// Changed lines left out of the next commit, by file: the rest of a ticked file goes in.
    var excludedLines: [String: Set<ChangeLine>] = [:] {
        didSet { onInclusionChanged?() }
    }
    /// Called when what goes into the next commit changes, so the viewer's ticks follow.
    @ObservationIgnored var onInclusionChanged: (() -> Void)?
    var commitMessage = ""
    var isCommitting = false
    /// The last commit made here in this session, while it can still be undone.
    var lastCommit: WorkingTree.CommitResult?
    /// The next commit replaces the last one (Amend), starting from its message.
    var amend = false
    /// Remote branches that already have the commit Amend would replace.
    var amendPushedTo: [String] = []
    /// What was in the message box before Amend filled in the last commit's message, and that message.
    @ObservationIgnored var amendDraft: (before: String, filled: String)?

    // Branches and remotes
    /// What is running against the repository's branches or remotes, shown by the branch: "Pushing…".
    var activity: String?
    /// A network operation, which can be stopped; a checkout runs to its end.
    var activityCancellable = false
    @ObservationIgnored var activityTask: Task<Void, Never>?
    /// `.git`, or a linked worktree's own directory, where git keeps the marker of a merge in progress.
    @ObservationIgnored private(set) var gitDirectory: URL?
    /// What the left side shows for a file in conflict.
    var conflictBase: ConflictBase = .head
    /// The merge message put in the box, so that it goes again if the merge is abandoned rather than committed.
    @ObservationIgnored private var prefilledMessage: String?

    /// A file opened by its path (from the tree or a search) rather than picked in the Changes or Log list.
    /// The viewer keeps following it: a diff while it has local changes, the plain file otherwise.
    var browsedPath: String?

    // Files
    var treeSelectedID: String?
    var treeExpanded: Set<String> = []
    var treeFilter = ""
    var treeMatches: [Fuzzy.Ranked] = []
    /// Bumped whenever the file index is rebuilt.
    var treeVersion = 0
    var isLoadingTree = false
    /// Bumped to scroll the tree to its selection.
    var treeRevealToken = 0
    /// The row that was just located, highlighted briefly.
    var treeFlashID: String?

    // Log
    var commits: [Commit] = []
    /// Every selected commit (⌘-click, ⇧-click, ⌘A). Includes `selectedCommitID` when one is active.
    var selectedCommitIDs: Set<String> = []
    var logQuery = ""
    var logAllBranches = false
    /// A branch or tag whose history the Log lists instead of HEAD's (a full ref name), picked in the Git graph.
    var logRef: String?
    var hasMoreCommits = true
    var isLoadingLog = false
    var selectedCommitID: String? {
        didSet {
            if let id = selectedCommitID {
                if !selectedCommitIDs.contains(id) {
                    selectedCommitIDs = [id]
                }
            } else if !selectedCommitIDs.isEmpty {
                selectedCommitIDs = []
            }
        }
    }
    var commitFiles: [FileChange] = []
    var commitBody = ""
    var isLoadingCommit = false
    var selectedCommitFileID: String?
    var commitCollapsed: Set<String> = []

    // History
    /// The Log lists this file's (or these lines') commits instead of a branch's.
    var history: HistoryFilter?
    /// The path the history's file had in each commit listed (it may have been renamed).
    @ObservationIgnored var historyPaths: [String: String] = [:]

    // Comparison
    /// The Changes tab lists what differs from this commit instead of the local changes.
    var comparison: Comparison?
    var compareChanges: [FileChange] = []
    var compareSelectedID: String?
    var compareCollapsed: Set<String> = []
    var isLoadingCompare = false
    var compareError: String?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var logTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var commitLoadGeneration = 0
    @ObservationIgnored private var compareTask: Task<Void, Never>?
    @ObservationIgnored private var fileIndex: [String]?
    @ObservationIgnored private var fileIndexStale = true
    @ObservationIgnored private var fileIndexTask: Task<[String], Never>?
    @ObservationIgnored private(set) var treeIndex: FileTreeIndex?
    @ObservationIgnored private var treeTask: Task<Void, Never>?
    @ObservationIgnored private var treeFilterTask: Task<Void, Never>?
    @ObservationIgnored private var treeReloadQueued = false
    @ObservationIgnored private var treeStamp: String?
    @ObservationIgnored private var treeForceReload = false
    /// Set while the window is hidden; the refresh runs when it comes back.
    @ObservationIgnored var needsRefreshWhenVisible = false

    /// Called on the main thread after each status refresh.
    @ObservationIgnored var onRefreshed: ((Project) -> Void)?
    /// Called on the main thread when watched files change (before the debounced refresh).
    @ObservationIgnored var isVisibleProvider: () -> Bool = { true }

    static let logPageSize = 200

    init(url: URL) {
        self.url = url.standardizedFileURL
        self.name = url.lastPathComponent
    }

    var changes: [FileChange] { status.changes }

    /// Whether `change` goes into the next commit.
    func isIncluded(_ change: FileChange) -> Bool {
        commitOverrides[change.path] ?? (change.kind != .untracked)
    }

    var includedChanges: [FileChange] { changes.filter(isIncluded) }

    /// A file's tick in the Changes list: mixed when some of its lines stay out of the commit.
    func inclusion(_ change: FileChange) -> Inclusion {
        guard isIncluded(change) else { return .off }
        return excludedLines[change.path]?.isEmpty == false ? .mixed : .on
    }

    /// The files of `changes` that are on disk, to drag out of the window.
    func existingURLs(_ changes: [FileChange]) -> [URL] {
        changes.compactMap { change in
            guard change.kind != .deleted else { return nil }
            let url = url.appendingPathComponent(change.path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    /// Ticks or unticks whole files: lines picked in them before are forgotten.
    func setIncluded(_ included: Bool, _ changes: [FileChange]) {
        var overrides = commitOverrides, excluded = excludedLines
        for change in changes {
            let standard = change.kind != .untracked
            overrides[change.path] = included == standard ? nil : included
            excluded[change.path] = nil
        }
        if overrides != commitOverrides { commitOverrides = overrides }
        if excluded != excludedLines { excludedLines = excluded }
    }

    /// "main", "origin/main", "v1.0" for the Log's branch filter.
    var logRefLabel: String? {
        logRef.map { ref in
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
            return ref
        }
    }
    var branchLabel: String {
        status.branch ?? (status.headOID.map { String($0.prefix(7)) } ?? (status.isInitial ? L("no commits", "无提交") : "—"))
    }

    // MARK: Watching and refresh

    func startWatching() {
        guard watcher == nil, !needsAccess, !isDormant else { return }
        watcher = FileWatcher(root: url) { [weak self] _, gitStateChanged in
            let project = self
            DispatchQueue.main.async {
                guard let self = project else { return }
                self.fileIndexStale = true
                if gitStateChanged, !self.commits.isEmpty { self.logStale = true }
                self.scheduleRefresh()
            }
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    @ObservationIgnored var logStale = false

    /// Coalesces bursts of file events (a build can produce thousands) into at most ~1 refresh/second.
    func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let delay = max(0.25, 1.0 - Date().timeIntervalSince(lastRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.isVisibleProvider() {
                self.refresh()
            } else {
                self.needsRefreshWhenVisible = true
            }
        }
    }

    func refresh() {
        guard !needsAccess, !isDormant else { return }
        if refreshTask != nil {
            refreshQueued = true
            return
        }
        isRefreshing = true
        needsRefreshWhenVisible = false
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.gitDirectory == nil { self.gitDirectory = await Git.gitDirectory(in: self.url) }
                let fresh = try await Git.status(in: self.url, gitDirectory: self.gitDirectory)
                // A merge that stopped for conflicts has its commit message ready; it goes in the box, as in the IDE.
                if fresh.operation == .merge, self.status.operation != .merge,
                   self.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let directory = self.gitDirectory, let prepared = Git.preparedMessage(in: directory) {
                    self.commitMessage = prepared
                    self.prefilledMessage = prepared
                } else if fresh.operation != .merge, let prefilled = self.prefilledMessage {
                    if self.commitMessage == prefilled { self.commitMessage = "" }
                    self.prefilledMessage = nil
                }
                if fresh != self.status { self.status = fresh }
                // Ticks of files that are no longer changed mean nothing, and must not come back if the file changes again.
                let paths = Set(fresh.changes.map(\.path))
                if self.commitOverrides.keys.contains(where: { !paths.contains($0) }) {
                    self.commitOverrides = self.commitOverrides.filter { paths.contains($0.key) }
                }
                if self.excludedLines.keys.contains(where: { !paths.contains($0) }) {
                    self.excludedLines = self.excludedLines.filter { paths.contains($0.key) }
                }
                self.errorMessage = nil
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.hasLoaded = true
            self.isRefreshing = false
            self.lastRefresh = Date()
            self.refreshTask = nil
            if self.logStale, self.tab == .log {
                self.logStale = false
                self.loadLog(reset: true)
            }
            // Files edited, or a commit made: what differs from the commit compared with changes too.
            // Two commits compared with each other stay as they are.
            if let comparison = self.comparison, comparison.other == nil { self.loadComparison() }
            self.onRefreshed?(self)
            if self.refreshQueued {
                self.refreshQueued = false
                self.scheduleRefresh()
            }
        }
    }

    // MARK: Requests

    func request(for change: FileChange, ignoreWhitespace: Bool) -> DiffRequest {
        let base = change.kind == .conflicted ? conflictBase.rev : (status.isInitial ? Git.emptyTree : "HEAD")
        return DiffRequest(root: url, path: change.path, oldPath: change.oldPath, kind: change.kind,
                           source: .worktree(base: base), ignoreWhitespace: ignoreWhitespace)
    }

    func request(for change: FileChange, in commit: Commit, ignoreWhitespace: Bool) -> DiffRequest {
        DiffRequest(root: url, path: change.path, oldPath: change.oldPath, kind: change.kind,
                    source: .commit(hash: commit.hash, parent: commit.parents.first), ignoreWhitespace: ignoreWhitespace)
    }

    /// Diff request for `change` across `commits` (ordered newest first): for one commit, against its first parent;
    /// for several, from the oldest commit's first parent (nil for a root commit) to the newest commit.
    func request(for change: FileChange, in commits: [Commit], ignoreWhitespace: Bool) -> DiffRequest? {
        guard let newest = commits.first, let oldest = commits.last else { return nil }
        return DiffRequest(root: url, path: change.path, oldPath: change.oldPath, kind: change.kind,
                           source: .commit(hash: newest.hash, parent: oldest.parents.first), ignoreWhitespace: ignoreWhitespace)
    }

    var selectedCommit: Commit? {
        guard let id = selectedCommitID else { return nil }
        return commits.first { $0.id == id }
    }

    /// Selected commits in list order (newest first).
    var selectedCommits: [Commit] {
        if !selectedCommitIDs.isEmpty {
            let ordered = commits.filter { selectedCommitIDs.contains($0.id) }
            if !ordered.isEmpty { return ordered }
        }
        return selectedCommit.map { [$0] } ?? []
    }

    /// Ordered hashes of the active commit selection, for observing single and multi-selection changes together.
    var commitSelectionIDs: [String] {
        selectedCommits.map(\.id)
    }

    // MARK: Log

    /// - Parameters:
    ///   - atLeast: load this many commits in one go, so a commit picked further down (in the Git graph) is in the list.
    ///   - completion: runs once the page is in place, unless a newer load replaced this one.
    func loadLog(reset: Bool, atLeast: Int = 0, completion: (() -> Void)? = nil) {
        if isLoadingLog, !reset { return }
        logTask?.cancel()
        isLoadingLog = true
        let skip = reset ? 0 : commits.count
        let query = logQuery, all = logAllBranches, ref = logRef, history = self.history
        let limit = max(Self.logPageSize, atLeast)
        let knowsPaths = !historyPaths.isEmpty
        logTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var page: [Commit] = []
            var paths: [String: String] = [:]
            if let history {
                if let lines = history.lines {
                    async let commits = Git.lineHistory(history.path, lines: lines, rev: history.rev, in: self.url,
                                                        skip: skip, limit: limit, query: query)
                    // `git log -L` cannot name the file in each commit; the file's own history can.
                    if reset || !knowsPaths {
                        paths = (try? await Git.fileHistory(history.path, in: self.url, skip: 0, limit: 5000, scope: [history.rev]))?.paths ?? [:]
                    }
                    page = (try? await commits) ?? []
                } else {
                    // From the commit asked for (a file deleted since, say), otherwise from what the Log lists.
                    let scope = history.rev != "HEAD" ? [history.rev] : (all ? ["--all"] : (ref.map { [$0] } ?? []))
                    let result = try? await Git.fileHistory(history.path, in: self.url, skip: skip, limit: limit, query: query, scope: scope)
                    page = result?.commits ?? []
                    paths = result?.paths ?? [:]
                }
            } else {
                page = (try? await Git.log(in: self.url, skip: skip, limit: limit, query: query, allBranches: all, ref: ref)) ?? []
            }
            if Task.isCancelled { return }
            if reset { self.historyPaths = paths } else { self.historyPaths.merge(paths) { old, _ in old } }
            if reset {
                self.commits = page
            } else {
                let known = Set(self.commits.map(\.hash))
                self.commits += page.filter { !known.contains($0.hash) }
            }
            self.hasMoreCommits = page.count >= limit
            self.isLoadingLog = false
            if reset, self.selectedCommit == nil {
                self.selectedCommitID = self.commits.first?.id
            } else if reset {
                let known = Set(self.commits.map(\.id))
                self.selectedCommitIDs = self.selectedCommitIDs.intersection(known)
                if self.selectedCommitIDs.isEmpty, let id = self.selectedCommitID {
                    self.selectedCommitIDs = [id]
                }
            }
            completion?()
        }
    }

    /// Loads the file list of the selected commit or commit range. `completion` runs once the list is in place.
    func loadSelectedCommit(completion: @escaping () -> Void) {
        commitTask?.cancel()
        commitLoadGeneration += 1
        let generation = commitLoadGeneration
        let selected = selectedCommits
        guard let primary = selected.first else {
            isLoadingCommit = false
            commitFiles = []
            commitBody = ""
            selectedCommitFileID = nil
            completion()
            return
        }
        let selectionIDs = selected.map(\.id)
        isLoadingCommit = true
        commitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let filesResult = Git.commitFiles(selected, in: self.url)
            async let bodyResult: String = selected.count == 1 ? Git.commitBody(primary.hash, in: self.url) : ""
            let files = (try? await filesResult) ?? []
            let body = await bodyResult
            if Task.isCancelled || self.commitLoadGeneration != generation || self.commitSelectionIDs != selectionIDs { return }
            self.isLoadingCommit = false
            self.commitFiles = files
            self.commitBody = body
            // A file's history shows that file in each commit, under whatever name it had there.
            if let history = self.history {
                let candidates: [String] = selected.count == 1
                    ? [self.historyPaths[primary.hash] ?? history.path, history.path]
                    : selected.compactMap { self.historyPaths[$0.hash] } + [history.path]
                if let file = files.first(where: { candidates.contains($0.path) })
                    ?? files.first(where: { f in f.oldPath.map { candidates.contains($0) } ?? false }) {
                    self.selectedCommitFileID = ChangeRow.fileID(file.path)
                    completion()
                    return
                }
            }
            let keep = self.selectedCommitFileID.flatMap { id in files.contains { ChangeRow.fileID($0.path) == id } ? id : nil }
            self.selectedCommitFileID = keep ?? ChangeTree.orderedFiles(changes: files, flat: false, filter: "", splitUnversioned: false)
                .first.map { ChangeRow.fileID($0.path) }
            completion()
        }
    }

    // MARK: Comparison

    /// Lists what differs from the commit compared with, resolving it again first: a branch may have moved,
    /// and a fork point moves with HEAD.
    func loadComparison() {
        guard let comparison else {
            compareTask?.cancel()
            compareChanges = []
            isLoadingCompare = false
            return
        }
        compareTask?.cancel()
        if compareChanges.isEmpty { isLoadingCompare = true }
        compareTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var current = comparison
            let resolved = comparison.forkPoint
                ? await Git.mergeBase("HEAD", comparison.target, in: self.url)
                : await Git.resolveCommit(comparison.target, in: self.url)
            if let resolved { current.base = resolved }
            if let other = comparison.other, let hash = await Git.resolveCommit(other.target, in: self.url) {
                current.other?.hash = hash
            }
            let files = if let stash = comparison.stash {
                try? await Git.stashFiles(stash, in: self.url)
            } else {
                try? await Git.compareFiles(base: current.base, head: current.head, in: self.url)
            }
            guard !Task.isCancelled, let active = self.comparison, active.target == comparison.target,
                  active.forkPoint == comparison.forkPoint else { return }
            if current != active { self.comparison = current }
            if let files {
                if files != self.compareChanges { self.compareChanges = files }
                self.compareError = resolved == nil ? L("\(comparison.title) no longer exists · showing the last commit found",
                                                        "\(comparison.title) 已不存在 · 显示的是上次找到的提交") : nil
            } else {
                self.compareError = L("Could not compare with \(comparison.title)", "无法与 \(comparison.title) 比较")
            }
            self.isLoadingCompare = false
            self.onRefreshed?(self)
        }
    }

    /// The local change or compared file shown for `path` while comparing.
    func comparedChange(_ path: String) -> FileChange? {
        compareChanges.first { $0.path == path }
    }

    func request(compared change: FileChange, with comparison: Comparison, ignoreWhitespace: Bool) -> DiffRequest {
        var source: DiffRequest.Source = comparison.head.map { .commit(hash: $0, parent: comparison.base) } ?? .worktree(base: comparison.base)
        // A stash's new files are in a commit of their own.
        if change.kind == .untracked, let untracked = comparison.stash?.untracked {
            source = .commit(hash: untracked, parent: comparison.base)
        }
        return DiffRequest(root: url, path: change.path, oldPath: change.oldPath, kind: change.kind, source: source,
                           ignoreWhitespace: ignoreWhitespace)
    }

    // MARK: File index (Go to File)

    /// Every file in the repository. Serves the cached list instantly and refreshes it when stale.
    func files() async -> [String] {
        if let cached = fileIndex, !fileIndexStale { return cached }
        if let running = fileIndexTask { return await running.value }
        let task = Task<[String], Never> { [url] in await Git.listFiles(in: url) }
        fileIndexTask = task
        let list = await task.value
        await MainActor.run {
            self.fileIndex = list
            self.fileIndexStale = false
            self.fileIndexTask = nil
        }
        return list
    }

    var cachedFiles: [String]? { fileIndex }

    /// Forces the next `files()` call, and the tree, to list the repository again.
    func invalidateFiles() {
        fileIndexStale = true
        treeForceReload = true
    }

    // MARK: File tree

    /// Changes whenever the set of files in the working tree may have: HEAD moved, or something was added,
    /// removed, renamed or is untracked. Edits to tracked files leave it alone, so an agent rewriting
    /// files never makes the tree list the repository again.
    private var listingStamp: String {
        var stamp = status.headOID ?? "-"
        for change in status.changes where change.kind != .modified {
            stamp += "\n\(change.kind.rawValue) \(change.path)"
        }
        return stamp
    }

    /// Builds the tree from the current file listing; a no-op when the tree is already up to date.
    /// Waits for the first status, which the listing is keyed on; the refresh that delivers it calls again.
    func loadTree() {
        guard hasLoaded else { return }
        let stamp = listingStamp
        if treeIndex != nil, !treeForceReload, stamp == treeStamp { return }
        if treeTask != nil {
            treeReloadQueued = true
            return
        }
        if treeIndex != nil { fileIndexStale = true }
        treeForceReload = false
        treeStamp = stamp
        isLoadingTree = treeIndex == nil
        treeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let first = self.treeIndex == nil
            let list = await self.files()
            if list != self.treeIndex?.paths {
                let index = await Task.detached(priority: .userInitiated) { FileTreeIndex(paths: list) }.value
                self.treeIndex = index
                self.treeVersion += 1
                if !self.treeFilter.isEmpty { self.updateTreeFilter() }
            }
            self.isLoadingTree = false
            self.treeTask = nil
            // A file located before the tree existed can only be scrolled to now.
            if first, self.treeSelectedID != nil { self.treeRevealToken += 1 }
            if self.treeReloadQueued {
                self.treeReloadQueued = false
                self.loadTree()
            }
        }
    }

    /// The rows the tree shows right now: the fuzzy matches while filtering, otherwise the open directories.
    func treeRows() -> [TreeRow] {
        guard let index = treeIndex else { return [] }
        if !treeFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            return FileTree.rows(matches: treeMatches, changes: changes)
        }
        return FileTree.rows(index: index, expanded: treeExpanded, changes: changes)
    }

    func updateTreeFilter() {
        treeFilterTask?.cancel()
        let query = treeFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let index = treeIndex else {
            treeMatches = []
            return
        }
        let paths = index.paths
        treeFilterTask = Task { @MainActor [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) {
                Fuzzy.rank(query: query, in: paths, limit: 200, isCancelled: { Task.isCancelled })
            }.value
            guard let self, !Task.isCancelled else { return }
            self.treeMatches = ranked
            // Keep the selection on a visible row so ↩ always opens something.
            if !ranked.contains(where: { TreeRow.fileID($0.path) == self.treeSelectedID }) {
                self.treeSelectedID = ranked.first.map { TreeRow.fileID($0.path) }
            }
        }
    }

    /// Opens the directories above `path`, selects it and scrolls it into view.
    /// Returns false when the working tree has no such file.
    @discardableResult
    func revealInTree(_ path: String, flash: Bool) -> Bool {
        if let index = treeIndex, !index.paths.contains(path) { return false }
        if !treeFilter.isEmpty {
            treeFilter = ""
            treeMatches = []
        }
        for directory in FileTree.ancestors(of: path) { treeExpanded.insert(directory) }
        let id = TreeRow.fileID(path)
        treeSelectedID = id
        treeRevealToken += 1
        if flash {
            treeFlashID = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                if self?.treeFlashID == id { self?.treeFlashID = nil }
            }
        }
        return true
    }
}
