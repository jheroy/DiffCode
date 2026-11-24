import Foundation
import Observation

/// What the list column shows. The file tree lives in the sidebar and is always there.
enum ProjectTab: String { case changes, groups, log }

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

    var status = RepoStatus() {
        didSet {
            changesVersion &+= 1
            cachedChangesByPath = nil
            cachedGroupSnapshot = nil
        }
    }
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
    /// Whether AI commit message generation (`agy`) is currently running for this project.
    var isGeneratingCommitMessage = false
    @ObservationIgnored var commitMessageGenerationTask: Task<Void, Never>?
    /// Monotonic token isolating each AI commit generation attempt so a late `defer` from a cancelled
    /// request can never clear a newer request's spinner, task handle, or generated text.
    @ObservationIgnored var commitMessageGenerationID = 0
    /// The last commit made here in this session, while it can still be undone.
    var lastCommit: WorkingTree.CommitResult?
    /// The next commit replaces the last one (Amend), starting from its message.
    var amend = false
    /// Remote branches that already have the commit Amend would replace.
    var amendPushedTo: [String] = []
    /// What was in the message box before Amend filled in the last commit's message, and that message.
    @ObservationIgnored var amendDraft: (before: String, filled: String)?

    /// Branch and remote target waiting for a push once auto-pull conflicts are resolved in 3-way merge.
    struct PendingPushAfterPull: Equatable, Sendable {
        var branch: String
        var target: String
        var remote: String?
    }

    // Branches and remotes
    /// What is running against the repository's branches or remotes, shown by the branch: "Pushing…".
    var activity: String?
    /// A network operation, which can be stopped; a checkout runs to its end.
    var activityCancellable = false
    @ObservationIgnored var activityTask: Task<Void, Never>?
    /// Set when an auto-pull before push stopped on conflicts; cleared or resumed once conflicts are resolved.
    @ObservationIgnored var pendingPushAfterPull: PendingPushAfterPull?
    /// `.git`, or a linked worktree's own directory, where git keeps the marker of a merge in progress.
    @ObservationIgnored private(set) var gitDirectory: URL?
    /// What the left side shows for a file in conflict.
    var conflictBase: ConflictBase = .head
    /// Conflict signature dismissed by the user so background refreshes do not repeatedly re-open 3-way merge.
    @ObservationIgnored var dismissedConflictSignature: String?
    /// Most recently observed conflict signature from `status`.
    @ObservationIgnored var lastConflictSignature: String?
    /// Tracks whether `hasLoaded` was already true before the most recent `refresh()` completed.
    @ObservationIgnored var hadLoadedBeforeLastRefresh = false
    /// The merge message put in the box, so that it goes again if the merge is abandoned rather than committed.
    @ObservationIgnored private var prefilledMessage: String?

    /// A file opened as plain file content (from the tree, search, LSP jump, or the viewer header's Open File action)
    /// rather than picked in Changes, Groups, or Log. Stays in plain-file view even when the file has local changes.
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
    /// Selected authors to filter the Log by (OR across selected entries).
    var logAuthors: [AuthorFilter] = []
    /// Cached authors available in the current Log scope for the author picker.
    var availableLogAuthors: [LogAuthor] = []
    var isLoadingLogAuthors = false
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
    var commitSelectionIsNonContiguous = false
    @ObservationIgnored var commitFileSteps: [String: [FileCommitStep]] = [:]
    var commitSkippedMergeCount = 0
    var commitBody = ""
    var isLoadingCommit = false
    var selectedCommitFileID: String?
    var commitCollapsed: Set<String> = []

    // History
    /// The Log lists this file's (or these lines') commits instead of a branch's.
    var history: HistoryFilter?
    /// The path the history's file had in each commit listed (it may have been renamed).
    @ObservationIgnored var historyPaths: [String: String] = [:]

    // Log tabs
    var logTabs: [LogTab]
    var activeLogTabID: UUID
    var logRevealToken = 0
    @ObservationIgnored var logTabMRU: [UUID] = []
    @ObservationIgnored var needsLogSelectionRestore = false
    @ObservationIgnored var hasLoadedCommitSelection = false

    // AI Hunk Grouping
    /// Latest AI logical grouping of uncommitted hunks (restored from disk on project load when present).
    var aiGroupResult: AIHunkGroupingResult? = nil {
        didSet {
            aiGroupVersion &+= 1
            cachedGroupHunkSets = [:]
            cachedGroupSnapshot = nil
        }
    }
    var isGeneratingGroups = false
    /// Monotonic token preventing stale/cancelled AI grouping tasks from mutating state.
    @ObservationIgnored var aiGroupGenerationToken: UInt64 = 0
    @ObservationIgnored var aiGroupGenerationTask: Task<Void, Never>?
    var aiGroupError: String? = nil
    var selectedGroupID: UUID? = nil
    var selectedGroupRowID: String? = nil
    var groupCollapsed: Set<String> = []
    var selectedGroupFilePath: String? = nil
    var selectedGroupHunkIndex: Int? = nil
    /// Per-group commit message drafts isolated by group ID (absent entries default to `AIHunkGrouper.defaultCommitMessage(for:)`).
    var groupCommitMessages: [UUID: String] = [:]
    var isCommittingGroup: Bool = false
    /// Group ID whose commit message is currently being generated by AI, if any.
    var generatingGroupCommitID: UUID? = nil
    /// Monotonic token preventing stale/cancelled group commit message generation tasks from mutating state.
    @ObservationIgnored var groupCommitMessageToken: UInt64 = 0
    @ObservationIgnored var groupCommitMessageTask: Task<Void, Never>?

    /// Cached indexes for O(1) lookups and avoiding O(N*M) tree rebuilds across SwiftUI renders / project switches.
    @ObservationIgnored private var changesVersion: UInt64 = 0
    @ObservationIgnored private var aiGroupVersion: UInt64 = 0
    @ObservationIgnored private var cachedChangesByPath: [String: FileChange]?
    @ObservationIgnored private var cachedGroupHunkSets: [UUID: [String: Set<Int>]] = [:]
    @ObservationIgnored private var cachedGroupSnapshot: (key: GroupSnapshotKey, snapshot: GroupChangesSnapshot)?

    private struct GroupSnapshotKey: Equatable {
        let aiGroupVersion: UInt64
        let changesVersion: UInt64
        let groupID: UUID
        let flat: Bool
        let collapsed: Set<String>
    }

    /// Precomputed bottom-pane model for the currently selected AI group (cached per `(group, changesVersion, flat, collapsed)`).
    struct GroupChangesSnapshot {
        let group: AIHunkGroup
        let changes: [FileChange]
        let rows: [ChangeRow]
        let hunksByPath: [String: [Int]]
        let folderIDs: Set<String>
        let totalAdditions: Int
        let totalDeletions: Int
    }

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
    @ObservationIgnored private var logLoadGeneration = 0
    @ObservationIgnored private var logAuthorsTask: Task<Void, Never>?
    @ObservationIgnored private var logAuthorsScopeKey: String?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var commitLoadGeneration = 0
    @ObservationIgnored private var loadedCommitSelectionIDs: Set<String> = []
    @ObservationIgnored private var loadingCommitSelectionIDs: [String]?
    @ObservationIgnored private var pendingCommitCompletions: [() -> Void] = []
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
    /// Called on the main thread when Log tabs, filters, or selections change.
    @ObservationIgnored var onLogStateChanged: ((Project) -> Void)?
    /// Called on the main thread when watched files change (before the debounced refresh).
    @ObservationIgnored var isVisibleProvider: () -> Bool = { true }

    static let logPageSize = 200

    init(url: URL) {
        let initialTab = LogTab()
        self.logTabs = [initialTab]
        self.activeLogTabID = initialTab.id
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

    /// Starts a new AI commit message generation attempt, returning its unique token.
    func beginCommitMessageGeneration() -> Int {
        commitMessageGenerationTask?.cancel()
        commitMessageGenerationID += 1
        isGeneratingCommitMessage = true
        return commitMessageGenerationID
    }

    /// Clears generation state only when `token` is still the active generation attempt.
    @discardableResult
    func finishCommitMessageGeneration(token: Int) -> Bool {
        guard commitMessageGenerationID == token else { return false }
        isGeneratingCommitMessage = false
        commitMessageGenerationTask = nil
        return true
    }

    /// Cancels any active AI commit message generation and invalidates its token immediately.
    func cancelCommitMessageGeneration() {
        commitMessageGenerationID += 1
        commitMessageGenerationTask?.cancel()
        commitMessageGenerationTask = nil
        isGeneratingCommitMessage = false
    }

    /// Starts a new AI hunk grouping attempt, cancelling any running one and returning its unique token.
    func beginAIGroupGeneration() -> UInt64 {
        aiGroupGenerationTask?.cancel()
        aiGroupGenerationToken &+= 1
        isGeneratingGroups = true
        aiGroupError = nil
        return aiGroupGenerationToken
    }

    /// Clears grouping spinner/task handle only if `token` still matches the active request.
    @discardableResult
    func finishAIGroupGeneration(token: UInt64) -> Bool {
        guard aiGroupGenerationToken == token else { return false }
        isGeneratingGroups = false
        aiGroupGenerationTask = nil
        return true
    }

    /// Cancels any active AI hunk grouping request and invalidates its token immediately.
    func cancelAIGroupGeneration(includeGroupCommitMessage: Bool = true) {
        aiGroupGenerationToken &+= 1
        aiGroupGenerationTask?.cancel()
        aiGroupGenerationTask = nil
        isGeneratingGroups = false
        if includeGroupCommitMessage {
            cancelGroupCommitMessageGeneration()
        }
    }

    /// Returns the commit message draft for `group`, falling back to its generated title + summary.
    func commitMessage(for group: AIHunkGroup) -> String {
        groupCommitMessages[group.id] ?? AIHunkGrouper.defaultCommitMessage(for: group)
    }

    /// Updates the commit message draft for `group`, removing redundant overrides matching the default text.
    func setCommitMessage(_ text: String, for group: AIHunkGroup) {
        let defaultText = AIHunkGrouper.defaultCommitMessage(for: group)
        if text == defaultText {
            if groupCommitMessages[group.id] != nil {
                groupCommitMessages.removeValue(forKey: group.id)
            }
        } else if groupCommitMessages[group.id] != text {
            groupCommitMessages[group.id] = text
        }
    }

    /// Whether `group` has a user-edited or AI-regenerated commit message differing from its default group description.
    func isGroupCommitMessageCustomized(for group: AIHunkGroup) -> Bool {
        guard let draft = groupCommitMessages[group.id] else { return false }
        return draft != AIHunkGrouper.defaultCommitMessage(for: group)
    }

    /// Restores `group`'s commit message back to `AIHunkGrouper.defaultCommitMessage(for:)`.
    func resetCommitMessage(for group: AIHunkGroup) {
        groupCommitMessages.removeValue(forKey: group.id)
    }

    /// Starts a new AI commit message generation attempt for `groupID`, cancelling any running one.
    func beginGroupCommitMessageGeneration(for groupID: UUID) -> UInt64 {
        groupCommitMessageTask?.cancel()
        groupCommitMessageToken &+= 1
        generatingGroupCommitID = groupID
        return groupCommitMessageToken
    }

    /// Clears group commit message generation state only if `token` still matches the active request.
    @discardableResult
    func finishGroupCommitMessageGeneration(token: UInt64) -> Bool {
        guard groupCommitMessageToken == token else { return false }
        generatingGroupCommitID = nil
        groupCommitMessageTask = nil
        return true
    }

    /// Cancels any active AI commit message generation for a group and invalidates its token immediately.
    func cancelGroupCommitMessageGeneration() {
        groupCommitMessageToken &+= 1
        groupCommitMessageTask?.cancel()
        groupCommitMessageTask = nil
        generatingGroupCommitID = nil
    }

    /// Clears the current AI grouping result, selection, per-group drafts, and error state.
    func clearAIGroups() {
        cancelAIGroupGeneration(includeGroupCommitMessage: true)
        aiGroupResult = nil
        aiGroupError = nil
        selectedGroupID = nil
        selectedGroupRowID = nil
        groupCollapsed.removeAll()
        selectedGroupFilePath = nil
        selectedGroupHunkIndex = nil
        groupCommitMessages.removeAll()
    }

    /// Captures a serializable snapshot of the active AI grouping result, selection, and customized drafts.
    func persistedAIGroupState(headOIDOverride: String? = nil) -> PersistedAIGroupState? {
        guard let result = aiGroupResult, !result.groups.isEmpty else { return nil }
        let groupsByID = Dictionary(uniqueKeysWithValues: result.groups.map { ($0.id, $0) })
        var serializedDrafts: [String: String] = [:]
        for (groupID, draft) in groupCommitMessages {
            guard let group = groupsByID[groupID],
                  draft != AIHunkGrouper.defaultCommitMessage(for: group) else { continue }
            serializedDrafts[groupID.uuidString] = draft
        }
        return PersistedAIGroupState(
            result: result,
            selectedGroupID: selectedGroupID,
            selectedGroupFilePath: selectedGroupFilePath,
            selectedGroupHunkIndex: selectedGroupHunkIndex,
            groupCommitMessages: serializedDrafts,
            headOID: headOIDOverride ?? status.headOID
        )
    }

    /// Restores a previously persisted AI grouping result, validating active group, file, hunk, and drafts.
    func restoreAIGroupState(_ state: PersistedAIGroupState) {
        guard !state.result.groups.isEmpty else { return }
        aiGroupResult = state.result
        aiGroupError = nil
        groupCollapsed.removeAll()

        let groupsByID = Dictionary(uniqueKeysWithValues: state.result.groups.map { ($0.id, $0) })
        var restoredDrafts: [UUID: String] = [:]
        for (rawID, draft) in state.groupCommitMessages {
            guard let uuid = UUID(uuidString: rawID),
                  let group = groupsByID[uuid],
                  draft != AIHunkGrouper.defaultCommitMessage(for: group) else { continue }
            restoredDrafts[uuid] = draft
        }
        groupCommitMessages = restoredDrafts

        let activeGroup = state.selectedGroupID.flatMap { groupsByID[$0] } ?? state.result.groups.first
        selectedGroupID = activeGroup?.id

        if let activeGroup {
            let matchedFile = state.selectedGroupFilePath.flatMap { path in
                activeGroup.files.first { $0.path == path }
            } ?? activeGroup.files.first
            if let file = matchedFile {
                selectedGroupFilePath = file.path
                selectedGroupRowID = ChangeRow.fileID(file.path)
                if let savedHunk = state.selectedGroupHunkIndex, file.hunkIndices.contains(savedHunk) {
                    selectedGroupHunkIndex = savedHunk
                } else {
                    selectedGroupHunkIndex = file.hunkIndices.first ?? 0
                }
            } else {
                selectedGroupFilePath = nil
                selectedGroupRowID = nil
                selectedGroupHunkIndex = nil
            }
        } else {
            selectedGroupFilePath = nil
            selectedGroupRowID = nil
            selectedGroupHunkIndex = nil
        }
    }

    /// O(1) lookup of a working-tree `FileChange` by repository-relative path, cached per `changesVersion`.
    func change(forPath path: String) -> FileChange? {
        if let cached = cachedChangesByPath {
            return cached[path]
        }
        let dict = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        cachedChangesByPath = dict
        return dict[path]
    }

    /// Currently active AI group (`selectedGroupID` if present in `aiGroupResult`, else the first group).
    var activeAIGroup: AIHunkGroup? {
        guard let groups = aiGroupResult?.groups, !groups.isEmpty else { return nil }
        if let id = selectedGroupID, let match = groups.first(where: { $0.id == id }) {
            return match
        }
        return groups.first
    }

    /// Returns the 0-based hunk indices belonging to the currently selected AI group for `path`,
    /// or `nil` when not viewing the Groups tab or when `path` is not part of the selected group.
    func highlightedGroupHunks(for path: String) -> Set<Int>? {
        guard tab == .groups,
              let groupID = selectedGroupID else {
            return nil
        }
        return groupHunkSets(for: groupID)[path]
    }

    private func groupHunkSets(for groupID: UUID) -> [String: Set<Int>] {
        if let cached = cachedGroupHunkSets[groupID] {
            return cached
        }
        guard let group = aiGroupResult?.groups.first(where: { $0.id == groupID }) else {
            return [:]
        }
        let built = Dictionary(
            group.files.map { ($0.path, Set($0.hunkIndices)) },
            uniquingKeysWith: { first, second in first.union(second) }
        )
        cachedGroupHunkSets[groupID] = built
        return built
    }

    /// Returns the cached `GroupChangesSnapshot` for the active AI group, avoiding O(N*M) lookups
    /// and repeated `ChangeTree.rows` builds across SwiftUI redraws and project switches.
    func groupChangesSnapshot(flat: Bool) -> GroupChangesSnapshot? {
        guard let group = activeAIGroup else { return nil }
        let key = GroupSnapshotKey(
            aiGroupVersion: aiGroupVersion,
            changesVersion: changesVersion,
            groupID: group.id,
            flat: flat,
            collapsed: groupCollapsed
        )
        if let cached = cachedGroupSnapshot, cached.key == key {
            return cached.snapshot
        }

        var groupChanges: [FileChange] = []
        groupChanges.reserveCapacity(group.files.count)
        var hunksByPath: [String: [Int]] = [:]
        hunksByPath.reserveCapacity(group.files.count)
        var totalAdditions = 0
        var totalDeletions = 0

        for file in group.files {
            let resolved = change(forPath: file.path)
                ?? FileChange(path: file.path, oldPath: nil, kind: .modified, additions: nil, deletions: nil)
            groupChanges.append(resolved)
            hunksByPath[file.path] = file.hunkIndices
            totalAdditions += resolved.additions ?? 0
            totalDeletions += resolved.deletions ?? 0
        }

        let rows = ChangeTree.rows(
            changes: groupChanges,
            flat: flat,
            collapsed: groupCollapsed,
            filter: "",
            splitUnversioned: false
        )
        let folderIDs: Set<String> = flat ? [] : Self.commitFolderIDs(for: groupChanges)

        let snapshot = GroupChangesSnapshot(
            group: group,
            changes: groupChanges,
            rows: rows,
            hunksByPath: hunksByPath,
            folderIDs: folderIDs,
            totalAdditions: totalAdditions,
            totalDeletions: totalDeletions
        )
        cachedGroupSnapshot = (key, snapshot)
        return snapshot
    }

    /// Files of `group` in the same display order used by the bottom changes tree/list.
    func orderedGroupFiles(for group: AIHunkGroup, flat: Bool) -> [AIHunkGroupFile] {
        guard !group.files.isEmpty else { return [] }
        let byPath = Dictionary(group.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let groupChanges = group.files.map { file in
            change(forPath: file.path)
                ?? FileChange(path: file.path, oldPath: nil, kind: .modified, additions: nil, deletions: nil)
        }
        let ordered = ChangeTree.orderedFiles(changes: groupChanges, flat: flat, filter: "", splitUnversioned: false)
        return ordered.compactMap { byPath[$0.path] }
    }

    func collapseAllGroupFolders(flat: Bool) {
        guard let snapshot = groupChangesSnapshot(flat: flat) else { return }
        groupCollapsed = snapshot.folderIDs
    }

    func expandAllGroupFolders() {
        groupCollapsed.removeAll()
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
                if gitStateChanged {
                    if !self.commits.isEmpty { self.logStale = true }
                    self.markInactiveLogTabsStale()
                }
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
                if fresh.conflictCount == 0 {
                    self.dismissedConflictSignature = nil
                }
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
            self.hadLoadedBeforeLastRefresh = self.hasLoaded
            self.hasLoaded = true
            self.isRefreshing = false
            self.lastRefresh = Date()
            self.refreshTask = nil
            if self.logStale, self.tab == .log {
                self.logStale = false
                self.logAuthorsScopeKey = nil
                self.loadLog(
                    reset: true,
                    atLeast: max(Self.logPageSize, min(self.commits.count, 2000)),
                    restorePrimary: self.selectedCommitID,
                    restoreSelection: self.selectedCommitIDs
                )
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

    /// Refreshes git status immediately and awaits completion so external-open callers inspect up-to-date `changes`.
    func refreshAndWait() async {
        guard !needsAccess, !isDormant else { return }
        if let running = refreshTask {
            await running.value
        }
        refreshQueued = false
        refresh()
        if let running = refreshTask {
            await running.value
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
    /// for contiguous commits, from the oldest commit's first parent to the newest commit; for non-contiguous
    /// selections, only the selected commits' steps for this file.
    func request(for change: FileChange, in commits: [Commit], ignoreWhitespace: Bool) -> DiffRequest? {
        guard let newest = commits.first, let oldest = commits.last else { return nil }
        if commitSelectionIsNonContiguous, let steps = commitFileSteps[change.path], !steps.isEmpty {
            if steps.count == 1 {
                let step = steps[0]
                return DiffRequest(root: url, path: step.path, oldPath: step.oldPath, kind: step.kind,
                                   source: .commit(hash: step.hash, parent: step.parent), ignoreWhitespace: ignoreWhitespace)
            }
            return DiffRequest(root: url, path: change.path, oldPath: change.oldPath, kind: change.kind,
                               source: .commitSteps(steps), ignoreWhitespace: ignoreWhitespace)
        }
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

    // MARK: Log & Log Tabs

    /// Updates `selectedCommitIDs` before `selectedCommitID` so `selectedCommitID.didSet` never drops multi-selection.
    func setCommitSelection(primary: String?, ids: Set<String>) {
        var normalized = ids
        if let primary {
            normalized.insert(primary)
        }
        let resolvedPrimary = primary ?? normalized.first
        if selectedCommitIDs != normalized {
            selectedCommitIDs = normalized
        }
        if selectedCommitID != resolvedPrimary {
            selectedCommitID = resolvedPrimary
        }
    }

    /// Returns the live snapshot for the active Log tab, or the stored snapshot for any inactive tab.
    func liveLogTabSnapshot(for id: UUID) -> LogTab {
        guard id == activeLogTabID else {
            return logTabs.first(where: { $0.id == id }) ?? LogTab(id: id)
        }
        let stored = logTabs.first(where: { $0.id == id })
        return LogTab(
            id: id,
            history: history,
            logQuery: logQuery,
            logAuthors: logAuthors,
            logAllBranches: logAllBranches,
            logRef: logRef,
            selectedCommitID: selectedCommitID,
            selectedCommitIDs: selectedCommitIDs,
            selectedCommitFileID: selectedCommitFileID,
            commitCollapsed: commitCollapsed,
            needsSelectionRestore: needsLogSelectionRestore,
            commits: commits,
            historyPaths: historyPaths,
            hasMoreCommits: hasMoreCommits,
            commitFiles: commitFiles,
            commitSelectionIsNonContiguous: commitSelectionIsNonContiguous,
            commitFileSteps: commitFileSteps,
            commitSkippedMergeCount: commitSkippedMergeCount,
            commitBody: commitBody,
            loadedCommitSelectionIDs: loadedCommitSelectionIDs,
            hasLoadedCommitSelection: hasLoadedCommitSelection,
            isStale: stored?.isStale ?? false
        )
    }

    /// Writes the Project's active Log properties into `logTabs` for `activeLogTabID`.
    func syncActiveLogTabFromLive() {
        let snapshot = liveLogTabSnapshot(for: activeLogTabID)
        if let index = logTabs.firstIndex(where: { $0.id == activeLogTabID }) {
            logTabs[index] = snapshot
        } else {
            logTabs.append(snapshot)
        }
    }

    /// Loads `tab` into the Project's live Log properties and cancels any previous tab's in-flight tasks.
    func applyLogTabToLive(_ tab: LogTab) {
        logTask?.cancel()
        logTask = nil
        logLoadGeneration &+= 1
        isLoadingLog = false

        logAuthorsTask?.cancel()
        logAuthorsTask = nil
        isLoadingLogAuthors = false
        logAuthorsScopeKey = nil

        commitTask?.cancel()
        commitTask = nil
        commitLoadGeneration += 1
        loadingCommitSelectionIDs = nil
        pendingCommitCompletions.removeAll()
        isLoadingCommit = false

        activeLogTabID = tab.id
        history = tab.history
        historyPaths = tab.historyPaths
        logQuery = tab.logQuery
        logAuthors = tab.logAuthors
        logAllBranches = tab.logAllBranches
        logRef = tab.logRef
        commits = tab.commits
        hasMoreCommits = tab.hasMoreCommits
        commitFiles = tab.commitFiles
        commitSelectionIsNonContiguous = tab.commitSelectionIsNonContiguous
        commitFileSteps = tab.commitFileSteps
        commitSkippedMergeCount = tab.commitSkippedMergeCount
        commitBody = tab.commitBody
        selectedCommitFileID = tab.selectedCommitFileID
        commitCollapsed = tab.commitCollapsed
        loadedCommitSelectionIDs = tab.loadedCommitSelectionIDs
        hasLoadedCommitSelection = tab.hasLoadedCommitSelection
        needsLogSelectionRestore = tab.needsSelectionRestore
        logStale = tab.isStale

        setCommitSelection(primary: tab.selectedCommitID, ids: tab.selectedCommitIDs)
        logRevealToken &+= 1
    }

    /// Switches to another Log tab if it exists and is not already active.
    @discardableResult
    func switchLogTab(to id: UUID) -> Bool {
        guard id != activeLogTabID,
              let targetIndex = logTabs.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let outgoingID = activeLogTabID
        syncActiveLogTabFromLive()
        logTabMRU.removeAll { $0 == outgoingID || $0 == id }
        logTabMRU.append(outgoingID)
        applyLogTabToLive(logTabs[targetIndex])
        return true
    }

    /// Appends `tab` to `logTabs` and activates it, preserving the outgoing tab in MRU order.
    func addAndActivateLogTab(_ tab: LogTab) {
        let outgoingID = activeLogTabID
        syncActiveLogTabFromLive()
        logTabMRU.removeAll { $0 == outgoingID || $0 == tab.id }
        logTabMRU.append(outgoingID)
        logTabs.append(tab)
        applyLogTabToLive(tab)
    }

    /// Closes `id` (or resets the sole tab to a clean default Log tab).
    func closeLogTab(_ id: UUID) -> (changedActive: Bool, resetOnlyTab: Bool) {
        syncActiveLogTabFromLive()
        guard let index = logTabs.firstIndex(where: { $0.id == id }) else {
            return (false, false)
        }
        if logTabs.count == 1 {
            let fresh = LogTab()
            logTabs = [fresh]
            logTabMRU.removeAll()
            applyLogTabToLive(fresh)
            return (true, true)
        }
        let wasActive = (id == activeLogTabID)
        logTabs.remove(at: index)
        logTabMRU.removeAll { $0 == id }
        if wasActive {
            let nextID = logTabMRU.last(where: { candidate in logTabs.contains { $0.id == candidate } })
                ?? logTabs[max(0, index - 1)].id
            if let nextTab = logTabs.first(where: { $0.id == nextID }) {
                applyLogTabToLive(nextTab)
            }
            return (true, false)
        }
        return (false, false)
    }

    func markInactiveLogTabsStale() {
        for index in logTabs.indices where logTabs[index].id != activeLogTabID && !logTabs[index].commits.isEmpty {
            logTabs[index].isStale = true
        }
    }

    func persistedLogState() -> PersistedLogState? {
        syncActiveLogTabFromLive()
        if tab == .changes, logTabs.count == 1, !logTabs[0].hasPersistableState {
            return nil
        }
        return PersistedLogState(
            activeProjectTab: tab.rawValue,
            activeTabID: activeLogTabID,
            tabs: logTabs.map { $0.persisted() }
        )
    }

    func restoreLogState(_ state: PersistedLogState) {
        guard !state.tabs.isEmpty else { return }
        let restored = state.tabs.map { LogTab(persisted: $0) }
        logTabs = restored
        logTabMRU.removeAll()
        let activeTab = state.activeTabID.flatMap { targetID in restored.first { $0.id == targetID } } ?? restored[0]
        applyLogTabToLive(activeTab)
        if let rawTab = state.activeProjectTab,
           let restoredTab = ProjectTab(rawValue: rawTab),
           !(AppEnvironment.isAppStore && restoredTab == .groups) {
            tab = restoredTab
        }
    }

    func toggleLogAuthor(_ author: AuthorFilter) {
        needsLogSelectionRestore = false
        if let index = logAuthors.firstIndex(of: author) {
            logAuthors.remove(at: index)
        } else {
            logAuthors.append(author)
        }
        onLogStateChanged?(self)
        loadLog(reset: true)
    }

    func addLogAuthors(_ authors: [AuthorFilter]) {
        let existing = Set(logAuthors)
        let additions = authors.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        needsLogSelectionRestore = false
        logAuthors.append(contentsOf: additions)
        onLogStateChanged?(self)
        loadLog(reset: true)
    }

    func removeLogAuthor(_ author: AuthorFilter) {
        let countBefore = logAuthors.count
        logAuthors.removeAll { $0 == author }
        if logAuthors.count != countBefore {
            needsLogSelectionRestore = false
            onLogStateChanged?(self)
            loadLog(reset: true)
        }
    }

    func clearLogAuthors() {
        guard !logAuthors.isEmpty else { return }
        needsLogSelectionRestore = false
        logAuthors.removeAll()
        onLogStateChanged?(self)
        loadLog(reset: true)
    }

    func loadLogAuthors(force: Bool = false) {
        let scopeKey = [
            status.headOID ?? "",
            logAllBranches ? "1" : "0",
            logRef ?? "",
            history?.path ?? "",
            history?.rev ?? "",
            history?.lines.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "",
        ].joined(separator: "\u{1F}")
        if !force, logAuthorsScopeKey == scopeKey, !availableLogAuthors.isEmpty, !logStale {
            return
        }
        logAuthorsTask?.cancel()
        isLoadingLogAuthors = true
        let all = logAllBranches
        let ref = logRef
        let history = self.history
        let knownPaths = historyPaths
        logAuthorsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let result: [LogAuthor]
            if let history {
                let scopeAll = history.rev == "HEAD" && all
                let scopeRef: String? = history.rev != "HEAD" ? history.rev : (scopeAll ? nil : ref)
                let paths = Array(Set(knownPaths.values).union([history.path])).sorted()
                result = (try? await Git.authors(in: self.url, allBranches: scopeAll, ref: scopeRef, paths: paths)) ?? []
            } else {
                result = (try? await Git.authors(in: self.url, allBranches: all, ref: ref)) ?? []
            }
            if Task.isCancelled { return }
            self.availableLogAuthors = result
            self.logAuthorsScopeKey = scopeKey
            self.isLoadingLogAuthors = false
        }
    }

    /// - Parameters:
    ///   - atLeast: load this many commits in one go, so a commit picked further down (in the Git graph) is in the list.
    ///   - restorePrimary: optional primary commit hash to preserve/locate after resetting.
    ///   - restoreSelection: optional full commit hash set to preserve/locate after resetting.
    ///   - completion: runs once the page is in place, unless a newer load replaced this one.
    func loadLog(
        reset: Bool,
        atLeast: Int = 0,
        restorePrimary: String? = nil,
        restoreSelection: Set<String> = [],
        completion: (() -> Void)? = nil
    ) {
        if isLoadingLog, !reset { return }
        logTask?.cancel()
        logLoadGeneration &+= 1
        let generation = logLoadGeneration
        let targetTabID = activeLogTabID
        isLoadingLog = true

        let skip = reset ? 0 : commits.count
        let query = logQuery, authors = logAuthors, all = logAllBranches, ref = logRef, history = self.history
        let initialLimit = max(Self.logPageSize, atLeast)
        let knowsPaths = !historyPaths.isEmpty

        let desiredPrimary = reset ? (restorePrimary ?? (needsLogSelectionRestore ? selectedCommitID : nil)) : nil
        var desiredSelection: Set<String> = reset
            ? (!restoreSelection.isEmpty ? restoreSelection : (needsLogSelectionRestore ? selectedCommitIDs : []))
            : []
        if let desiredPrimary {
            desiredSelection.insert(desiredPrimary)
        }

        let repoURL = url

        func fetchPage(pageLimit: Int, needsPaths: Bool) async -> (commits: [Commit], paths: [String: String]) {
            if let history {
                if let lines = history.lines {
                    async let loadedCommits = Git.lineHistory(history.path, lines: lines, rev: history.rev, in: repoURL,
                                                              skip: skip, limit: pageLimit, query: query, authors: authors)
                    // `git log -L` cannot name the file in each commit; the file's own history can.
                    let loadedPaths: [String: String]
                    if needsPaths {
                        loadedPaths = (try? await Git.fileHistory(history.path, in: repoURL, skip: 0, limit: 5000, scope: [history.rev]))?.paths ?? [:]
                    } else {
                        loadedPaths = [:]
                    }
                    return ((try? await loadedCommits) ?? [], loadedPaths)
                } else {
                    let scope = history.rev != "HEAD" ? [history.rev] : (all ? Git.allBranchesScope(includeInternalRefs: false) : (ref.map { [$0] } ?? []))
                    let result = try? await Git.fileHistory(history.path, in: repoURL, skip: skip, limit: pageLimit,
                                                            query: query, authors: authors, scope: scope)
                    return (result?.commits ?? [], result?.paths ?? [:])
                }
            } else {
                let loaded = (try? await Git.log(in: repoURL, skip: skip, limit: pageLimit, query: query, authors: authors,
                                                 allBranches: all, ref: ref)) ?? []
                return (loaded, [:])
            }
        }

        logTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var effectiveLimit = initialLimit
            let first = await fetchPage(pageLimit: effectiveLimit, needsPaths: reset || !knowsPaths)
            if Task.isCancelled || self.logLoadGeneration != generation || self.activeLogTabID != targetTabID { return }

            var page = first.commits
            var paths = first.paths
            var rawPageCount = page.count

            if reset, !desiredSelection.isEmpty {
                var missing = desiredSelection.subtracting(Set(page.map(\.hash)))
                if !missing.isEmpty, rawPageCount >= effectiveLimit, effectiveLimit < 2000 {
                    effectiveLimit = 2000
                    let deeper = await fetchPage(pageLimit: effectiveLimit, needsPaths: false)
                    if Task.isCancelled || self.logLoadGeneration != generation || self.activeLogTabID != targetTabID { return }
                    page = deeper.commits
                    if !deeper.paths.isEmpty { paths = deeper.paths }
                    rawPageCount = page.count
                    missing = desiredSelection.subtracting(Set(page.map(\.hash)))
                }
                if !missing.isEmpty {
                    var extra = await Git.commits(hashes: Array(missing), in: repoURL)
                    if Task.isCancelled || self.logLoadGeneration != generation || self.activeLogTabID != targetTabID { return }
                    if !authors.isEmpty {
                        let allowed = Set(authors)
                        extra = extra.filter { allowed.contains(AuthorFilter.from($0)) }
                    }
                    let existing = Set(page.map(\.hash))
                    let uniqueExtra = extra.filter { !existing.contains($0.hash) }.sorted { $0.date > $1.date }
                    if !uniqueExtra.isEmpty {
                        if history != nil {
                            page.insert(contentsOf: uniqueExtra, at: 0)
                        } else {
                            page.append(contentsOf: uniqueExtra)
                        }
                    }
                }
            }

            if reset { self.historyPaths = paths } else { self.historyPaths.merge(paths) { old, _ in old } }
            if reset {
                self.commits = page
            } else {
                let known = Set(self.commits.map(\.hash))
                self.commits += page.filter { !known.contains($0.hash) }
            }
            self.hasMoreCommits = rawPageCount >= effectiveLimit
            self.isLoadingLog = false
            self.logStale = false
            self.needsLogSelectionRestore = false

            if reset {
                if !desiredSelection.isEmpty {
                    let known = Set(self.commits.map(\.id))
                    let surviving = desiredSelection.intersection(known)
                    if !surviving.isEmpty {
                        let resolvedPrimary = (desiredPrimary.flatMap { surviving.contains($0) ? $0 : nil })
                            ?? self.commits.first(where: { surviving.contains($0.id) })?.id
                        self.setCommitSelection(primary: resolvedPrimary, ids: surviving)
                        if self.loadedCommitSelectionIDs != surviving {
                            self.hasLoadedCommitSelection = false
                        }
                        self.logRevealToken &+= 1
                    } else {
                        let firstID = self.commits.first?.id
                        self.setCommitSelection(primary: firstID, ids: firstID.map { [$0] } ?? [])
                        self.hasLoadedCommitSelection = false
                    }
                } else if self.selectedCommit == nil {
                    let firstID = self.commits.first?.id
                    self.setCommitSelection(primary: firstID, ids: firstID.map { [$0] } ?? [])
                    self.hasLoadedCommitSelection = false
                } else {
                    let known = Set(self.commits.map(\.id))
                    var surviving = self.selectedCommitIDs.intersection(known)
                    if surviving.isEmpty, let id = self.selectedCommitID, known.contains(id) {
                        surviving = [id]
                    }
                    if surviving.isEmpty {
                        let firstID = self.commits.first?.id
                        self.setCommitSelection(primary: firstID, ids: firstID.map { [$0] } ?? [])
                    } else {
                        let resolvedPrimary = (self.selectedCommitID.flatMap { surviving.contains($0) ? $0 : nil })
                            ?? self.commits.first(where: { surviving.contains($0.id) })?.id
                        self.setCommitSelection(primary: resolvedPrimary, ids: surviving)
                    }
                    if self.loadedCommitSelectionIDs != Set(self.commitSelectionIDs) {
                        self.hasLoadedCommitSelection = false
                    }
                }
            }

            if let idx = self.logTabs.firstIndex(where: { $0.id == targetTabID }) {
                self.logTabs[idx].isStale = false
            }
            self.syncActiveLogTabFromLive()
            completion?()
            self.onLogStateChanged?(self)
        }
    }

    /// Loads the file list of the selected commit or commit range. `completion` runs once the list is in place.
    func loadSelectedCommit(force: Bool = false, completion: @escaping () -> Void) {
        let targetTabID = activeLogTabID
        let selected = selectedCommits
        guard let primary = selected.first else {
            commitTask?.cancel()
            commitTask = nil
            commitLoadGeneration += 1
            loadingCommitSelectionIDs = nil
            pendingCommitCompletions.removeAll()
            isLoadingCommit = false
            commitFiles = []
            commitSelectionIsNonContiguous = false
            commitFileSteps = [:]
            commitSkippedMergeCount = 0
            commitBody = ""
            selectedCommitFileID = nil
            commitCollapsed.removeAll()
            loadedCommitSelectionIDs = []
            hasLoadedCommitSelection = false
            syncActiveLogTabFromLive()
            completion()
            return
        }

        let selectionIDs = selected.map(\.id)
        let selectionSet = Set(selectionIDs)

        if !force, hasLoadedCommitSelection, loadedCommitSelectionIDs == selectionSet {
            commitTask?.cancel()
            commitTask = nil
            commitLoadGeneration += 1
            loadingCommitSelectionIDs = nil
            pendingCommitCompletions.removeAll()
            isLoadingCommit = false
            completion()
            return
        }

        if !force, isLoadingCommit, loadingCommitSelectionIDs == selectionIDs {
            pendingCommitCompletions.append(completion)
            return
        }

        commitTask?.cancel()
        commitLoadGeneration += 1
        let generation = commitLoadGeneration
        loadingCommitSelectionIDs = selectionIDs
        pendingCommitCompletions = [completion]
        isLoadingCommit = true
        let isInitialRestore = loadedCommitSelectionIDs.isEmpty

        commitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            async let summaryResult = Git.commitSelectionSummary(selected, in: self.url)
            async let bodyResult: String = selected.count == 1 ? Git.commitBody(primary.hash, in: self.url) : ""
            let summary = (try? await summaryResult) ?? CommitSelectionSummary(
                isNonContiguous: false, files: [], fileSteps: [:], skippedMergeCount: 0
            )
            let files = summary.files
            let body = await bodyResult
            if Task.isCancelled
                || self.commitLoadGeneration != generation
                || self.activeLogTabID != targetTabID
                || self.commitSelectionIDs != selectionIDs {
                return
            }

            self.isLoadingCommit = false
            self.loadingCommitSelectionIDs = nil
            self.commitSelectionIsNonContiguous = summary.isNonContiguous
            self.commitFileSteps = summary.fileSteps
            self.commitSkippedMergeCount = summary.skippedMergeCount
            self.commitFiles = files
            self.commitBody = body

            // Reset collapsed folders when switching to an unrelated commit selection; otherwise prune stale IDs.
            if !self.loadedCommitSelectionIDs.isEmpty && self.loadedCommitSelectionIDs.isDisjoint(with: selectionSet) {
                self.commitCollapsed.removeAll()
            } else {
                self.commitCollapsed.formIntersection(Self.commitFolderIDs(for: files))
            }
            self.loadedCommitSelectionIDs = selectionSet
            self.hasLoadedCommitSelection = true

            let keep = self.selectedCommitFileID.flatMap { id in
                files.contains { ChangeRow.fileID($0.path) == id } ? id : nil
            }
            if isInitialRestore, let keep {
                self.selectedCommitFileID = keep
            } else if let history = self.history {
                // A file's history shows that file in each commit, under whatever name it had there.
                let candidates: [String] = selected.count == 1
                    ? [self.historyPaths[primary.hash] ?? history.path, history.path]
                    : selected.compactMap { self.historyPaths[$0.hash] } + [history.path]
                if let file = files.first(where: { candidates.contains($0.path) })
                    ?? files.first(where: { f in f.oldPath.map { candidates.contains($0) } ?? false }) {
                    self.selectedCommitFileID = ChangeRow.fileID(file.path)
                } else {
                    self.selectedCommitFileID = keep ?? ChangeTree.orderedFiles(changes: files, flat: false, filter: "", splitUnversioned: false)
                        .first.map { ChangeRow.fileID($0.path) }
                }
            } else {
                self.selectedCommitFileID = keep ?? ChangeTree.orderedFiles(changes: files, flat: false, filter: "", splitUnversioned: false)
                    .first.map { ChangeRow.fileID($0.path) }
            }

            self.syncActiveLogTabFromLive()
            let completions = self.pendingCommitCompletions
            self.pendingCommitCompletions.removeAll()
            completions.forEach { $0() }
        }
    }

    /// Directory row IDs for `files` when grouped by directory (`splitUnversioned: false`).
    nonisolated static func commitFolderIDs(for files: [FileChange]) -> Set<String> {
        let rows = ChangeTree.rows(changes: files, flat: false, collapsed: [], filter: "", splitUnversioned: false)
        return Set(rows.compactMap { row -> String? in
            if case .directory = row.kind { return row.id }
            return nil
        })
    }

    var commitFolderIDs: Set<String> {
        Self.commitFolderIDs(for: commitFiles)
    }

    func collapseAllCommitFolders() {
        commitCollapsed = commitFolderIDs
        onLogStateChanged?(self)
    }

    func expandAllCommitFolders() {
        commitCollapsed.removeAll()
        onLogStateChanged?(self)
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
