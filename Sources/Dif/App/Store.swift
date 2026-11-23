import AppKit
import Observation
import SwiftUI

enum Popup: Equatable {
    case quickOpen
    case findInPath
    case goToLine
    case keymap
    case settings
    /// Branches and the commit graph, dropped down from the branch button.
    case gitGraph
    /// LSP references / multiple definitions picker with code preview.
    case references
    /// Current file structure / symbols outline with fuzzy filtering and code preview.
    case fileSymbols
    /// A question or notice (`AppStore.dialog`).
    case dialog
}

struct RecentFile: Hashable {
    var projectID: UUID
    var path: String
}

/// Application state: the project list, the viewer, and the transient popups.
@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    let settings = Settings.shared
    let viewer = ViewerModel()
    let quickOpen = QuickOpenModel()
    let finder = FindInPathModel()
    let terminals = TerminalManager()
    let gitGraph = GitGraphModel()
    let references = ReferencesPickerModel()
    let fileSymbols = FileSymbolsModel()
    /// Where each project's branch sits in the sidebar, in window coordinates: ⌥⌘B opens the graph under it.
    @ObservationIgnored var branchLabelFrames: [UUID: CGRect] = [:]

    var projects: [Project] = []
    /// The projects whose repositories inside are folded away in the sidebar, by path.
    var collapsedProjects: Set<String> = []
    /// The work tree that was selected when DiffCode last quit, until git lists it again.
    @ObservationIgnored private var awaitedSelection: String?
    var selectedProjectID: UUID? { didSet { if selectedProjectID != oldValue { terminals.updatePolling() } } }
    var popup: Popup?
    var sidebarVisible = true
    var listVisible = true
    var toast: String?
    /// A button shown with the toast ("Undo"); the toast stays up longer while it has one.
    var toastAction: ToastAction?
    var memoryMB: Double = 0
    var titlebarHeight: CGFloat = 38
    var listFocusToken = 0
    var logFilesFocusToken = 0
    /// Counts in a range of its own: the tree and the list are on screen together and must not answer each other's requests.
    var treeFocusToken = 1_000_000
    var isFullScreen = false
    /// The App Store edition found no git it may run (the developer tools are not installed).
    var gitMissing = false
    /// The question on screen, while `popup == .dialog`.
    var dialog: DialogRequest?
    var dialogFocusToken = 4_000_000
    /// Active GoLand-style 3-way merge session when resolving repository conflicts.
    var mergeSession: ThreeWayMergeSession?
    /// Where the Git graph drops down from (window coordinates, top left); nil puts it under the title bar.
    var gitGraphAnchor: CGPoint?
    /// Bumped to put the keyboard in the commit message.
    var commitFocusToken = 0
    @ObservationIgnored var commitFocusRequestedAt: CFTimeInterval = 0

    // LSP & Vim jump-list navigation (see LSPNavigation.swift).
    /// Unified Vim/IDE Back (`<C-o>` / `⌘[`) / Forward (`<C-i>` / `⌘]`) jump history stack.
    var jumpHistory = JumpHistory()
    /// True while replaying a jump via `navigateBack` / `navigateForward` (or `navigateToLSPLocation`)
    /// so intermediate file switches never push duplicate origins or wipe the forward stack.
    @ObservationIgnored var isNavigatingJumpHistory = false
    /// Active external read-only file request (sibling `go.work` repo, `$GOROOT`, `pkg/mod`…), cleared on normal navigation.
    var externalRequest: DiffRequest?
    @ObservationIgnored var definitionTask: Task<Void, Never>?

    // Local AI agents & hunk grouping (Direct edition only; see AIGroupActions.swift).
    var agentAvailabilities: [AgentAvailability] = []
    var agentAvailabilityChecked = false
    var agentModelsByProvider: [AgentProvider: [AgentModel]] = [:]
    var loadingModelsProviders: Set<AgentProvider> = []
    var agentModelErrors: [AgentProvider: String] = [:]
    @ObservationIgnored var agentAvailabilityTask: Task<Void, Never>?
    @ObservationIgnored var agentModelAttemptedProviders: Set<AgentProvider> = []
    @ObservationIgnored var agentModelLoadTokens: [AgentProvider: UInt64] = [:]
    @ObservationIgnored var agentModelLoadTasks: [AgentProvider: Task<Void, Never>] = [:]
    /// Pending hunk focus requested from the Groups tab while the target file finishes loading.
    @ObservationIgnored var pendingGroupHunkFocus: (root: URL, path: String, hunkIndex: Int)?
    @ObservationIgnored let aiGroupStorage = AIGroupStorage.shared
    @ObservationIgnored var aiGroupPersistTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored var recent: [RecentFile] = []
    /// Rollbacks and deletes that can still be undone, oldest first.
    @ObservationIgnored var undoStack: [UndoItem] = []
    /// One edit at a time: a second click while git is still working is ignored.
    @ObservationIgnored var isApplyingEdit = false
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var memoryTimer: Timer?
    @ObservationIgnored private weak var responderBeforePopup: NSResponder?
    @ObservationIgnored private var panelsBeforeMaximize: (sidebar: Bool, list: Bool)?

    private init() {
        viewer.settings = settings
        viewer.onExit = { [weak self] in
            guard let self else { return }
            // Escape returns to wherever the file was picked: the tree, the commit's file list in Log, else the changes list.
            if self.currentProject?.browsedPath != nil, self.sidebarVisible {
                self.focusTree()
            } else if self.currentProject?.tab == .log, self.listVisible {
                self.logFilesFocusToken += 1
            } else {
                self.focusList()
            }
        }
        viewer.onStepFile = { [weak self] delta in self?.stepFile(delta) ?? false }
        viewer.onToast = { [weak self] text in self?.showToast(text) }
        viewer.contextMenuProvider = { [weak self] in self?.viewerContextMenu() }
        viewer.onRevertHunk = { [weak self] index in self?.rollbackHunk(index) }
        viewer.onToggleCommitHunk = { [weak self] index in self?.toggleCommitHunk(index) }
        viewer.onDocumentChanged = { [weak self] in
            self?.viewerDocumentChanged()
            self?.applyPendingGroupHunkFocus()
        }
        // A save shows in the Changes list straight away, without waiting for the file watcher.
        viewer.onFileWritten = { [weak self] root in self?.projects.first { $0.url == root }?.refresh() }
        viewer.onCodeFontChanged = { [weak self] in self?.mergeSession?.applyCodeFont() }
        viewer.onOpenAnnotation = { [weak self] entry in self?.openAnnotation(entry) }
        viewer.onGoToDefinition = { [weak self] line, col in self?.smartLSPNavigate(line: line, character: col) }
        viewer.onVimAction = { [weak self] action, line, col in self?.handleVimAction(action, line: line, column: col) }
        viewer.onRecordJump = { [weak self] line, col in self?.recordJumpOrigin(line0Based: line, column: col) }
        viewer.onWillSwitchFile = { [weak self] previousRequest, line, col in
            self?.recordJumpOrigin(from: previousRequest, line0Based: line, column: col)
        }
        quickOpen.store = self
        quickOpen.onOpenExcelSheet = { [weak self] project, path, sheetName in
            guard let self else { return }
            self.openFile(in: project, path: path, line: nil)
            self.viewer.selectExcelSheet(sheetName)
            self.viewer.focusCanvas()
        }
        finder.store = self
        terminals.store = self
        gitGraph.store = self
        references.store = self
        fileSymbols.store = self
        restoreCachedAgentModels()
    }

    var currentProject: Project? {
        guard let id = selectedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }

    // MARK: Lifecycle

    func bootstrap() {
        restoreCachedAgentModels()
        let defaults = UserDefaults.standard
        let access = FolderAccess.shared
        access.restore()
        gitMissing = !Git.isAvailable
        for path in defaults.stringArray(forKey: "projects") ?? [] {
            if !access.covers(path) {
                // Kept, so the project is not lost; it asks for its folder when selected.
                let project = Project(url: URL(fileURLWithPath: path))
                project.needsAccess = true
                install(project)
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }
            install(Project(url: URL(fileURLWithPath: path)))
        }
        collapsedProjects = Set(defaults.stringArray(forKey: "collapsedProjects") ?? [])
        let last = defaults.string(forKey: "selectedProject")
        // A work tree was selected: it is listed once its repository has been asked for its work trees.
        if let last, !projects.contains(where: { $0.url.path == last }) { awaitedSelection = last }
        selectedProjectID = (projects.first { $0.url.path == last } ?? projects.first)?.id
        projects.forEach { $0.refresh() }
        syncViewer()

        memoryMB = Self.footprintMB()
        visibilityChanged()
    }

    /// The app came to the front or went to the back, or the window was covered or uncovered. Periodic work runs
    /// only while it can be seen, so an idle DiffCode in the background never wakes up.
    func visibilityChanged() {
        let visible = isWindowVisible
        // The memory readout: live while DiffCode is in front, one last reading when it goes to the back.
        if visible, NSApp.isActive {
            if memoryTimer == nil {
                updateMemoryReadout()
                let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateMemoryReadout() }
                }
                timer.tolerance = 1
                RunLoop.main.add(timer, forMode: .common)
                memoryTimer = timer
            }
        } else if let timer = memoryTimer {
            timer.invalidate()
            memoryTimer = nil
            updateMemoryReadout()
        }
        terminals.updatePolling()
        if visible { windowBecameVisible() }
    }

    private func updateMemoryReadout() {
        let value = Self.footprintMB()
        if abs(value - memoryMB) >= 0.5 { memoryMB = value }
    }

    private func install(_ project: Project) {
        project.onRefreshed = { [weak self] p in self?.projectDidRefresh(p) }
        project.onInclusionChanged = { [weak self, weak project] in
            if let self, let project, project === self.currentProject { self.updateCommitTicks() }
        }
        project.isVisibleProvider = { [weak self] in self?.isWindowVisible ?? true }
        project.startWatching()
        projects.append(project)
        restoreAIGroups(for: project)
    }

    func persistProjects() {
        let defaults = UserDefaults.standard
        // Work trees listed by git are not the user's list: they come back from git.
        defaults.set(projects.filter { !$0.isDerived }.map(\.url.path), forKey: "projects")
        defaults.set(currentProject?.url.path, forKey: "selectedProject")
        // Only what is still listed, so the setting does not grow with every folder ever collapsed.
        defaults.set(projects.map(\.url.path).filter(collapsedProjects.contains), forKey: "collapsedProjects")
    }

    var isWindowVisible: Bool {
        guard let window else { return true }
        return window.occlusionState.contains(.visible) && !NSApp.isHidden
    }

    /// Refreshes deferred while the window was hidden run now.
    func windowBecameVisible() {
        for project in projects where project.needsRefreshWhenVisible {
            project.refresh()
        }
    }

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    // MARK: Projects

    func presentAddProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Add", "添加")
        panel.message = L("Choose Git repositories, or a folder containing several.", "选择 Git 仓库，或包含多个仓库的文件夹。")
        guard let window else {
            if panel.runModal() == .OK { addProjects(panel.urls) }
            return
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.addProjects(panel.urls) }
        }
    }

    func addProjects(_ urls: [URL]) {
        // In the sandbox the folders just chosen are open only now: keep them open for the next launches too.
        let access = FolderAccess.shared
        urls.forEach { access.remember($0) }
        Task { @MainActor in
            var landed: Project?
            var rejected = 0
            var refusal: Git.Refusal?
            for url in urls {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
                let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
                // The repository chosen, or those in a plain folder, and the repositories inside them.
                let roots = await Git.repositories(for: directory)
                if roots.isEmpty {
                    rejected += 1
                    if refusal == nil { refusal = await Git.refusal(at: directory) }
                    // A folder with no repository in it needs no access kept. (A file keeps its own: ~/.gitconfig.)
                    if isDirectory.boolValue { access.release(url.path, keepingFor: self.projects.map(\.url.path)) }
                }
                for root in roots {
                    let path = root.standardizedFileURL.path
                    if !access.covers(path) {
                        // A folder inside the repository was chosen, but the sandbox needs the repository's own.
                        guard await self.requestAccess(to: root) else { continue }
                    }
                    if let existing = self.projects.first(where: { $0.url.path == path }) {
                        // A work tree git listed, now added by hand: it stays whatever happens to the list.
                        existing.isDerived = false
                        self.unlockGrantedProjects()
                        landed = landed ?? existing
                        continue
                    }
                    let project = Project(url: root)
                    self.install(project)
                    project.refresh()
                    landed = landed ?? project
                }
            }
            // A work tree just added goes under its repository now, not at that one's next look.
            for project in self.projects where project.worktreeOf == nil { self.syncWorktrees(of: project, force: true) }
            if let landed {
                self.select(landed)
            } else if rejected > 0 {
                if let refusal {
                    self.showRefusal(refusal)
                } else if access.isNeeded {
                    // The sandbox hides the folders above the one chosen, so a folder inside a repository looks like none.
                    self.showToast(L("No Git repository found there · choose the repository's own folder",
                                     "这里没有找到 Git 仓库 · 请选择仓库本身所在的文件夹"))
                } else {
                    self.showToast(L("No Git repository found there", "这里没有找到 Git 仓库"))
                }
            }
            self.persistProjects()
        }
    }

    func openExternalTargets(_ targets: [ExternalOpenTarget]) {
        Task { @MainActor in
            await self.openExternalTargetsAsync(targets)
        }
    }

    func openExternalTargetsAsync(_ targets: [ExternalOpenTarget]) async {
        let access = FolderAccess.shared
        let fileManager = FileManager.default
        for target in targets where fileManager.fileExists(atPath: target.fileURL.path) {
            access.remember(target.fileURL)
        }

        var landedDirectoryProject: Project?
        var landedFile: (project: Project, relativePath: String, line: Int?, column: Int?)?
        var landedExternalFile: (fileURL: URL, line: Int?, column: Int?)?
        var touchedProjects = false
        var rejected = 0
        var refusal: Git.Refusal?
        var missingFileName: String?

        func findProject(matching root: URL) -> Project? {
            let targetPath = LSPURI.canonicalFileURL(root).path
            return self.projects.first { LSPURI.canonicalFileURL($0.url).path == targetPath }
        }

        for target in targets {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: target.fileURL.path, isDirectory: &isDirectory) else {
                missingFileName = missingFileName ?? target.fileURL.lastPathComponent
                continue
            }

            if isDirectory.boolValue {
                let roots = await Git.repositories(for: target.fileURL)
                if roots.isEmpty {
                    rejected += 1
                    if refusal == nil { refusal = await Git.refusal(at: target.fileURL) }
                    access.release(target.fileURL.path, keepingFor: self.projects.map(\.url.path))
                }
                for root in roots {
                    let path = root.standardizedFileURL.path
                    if !access.covers(path) {
                        guard await self.requestAccess(to: root) else { continue }
                    }
                    if let existing = findProject(matching: root) {
                        existing.isDerived = false
                        self.unlockGrantedProjects()
                        touchedProjects = true
                        landedDirectoryProject = landedDirectoryProject ?? existing
                        continue
                    }
                    let project = Project(url: root)
                    self.install(project)
                    project.refresh()
                    touchedProjects = true
                    landedDirectoryProject = landedDirectoryProject ?? project
                }
                continue
            }

            let parentDirectory = target.fileURL.deletingLastPathComponent()
            if let root = await Git.repositoryRoot(for: parentDirectory) {
                let rootPath = root.standardizedFileURL.path
                if !access.covers(rootPath) {
                    guard await self.requestAccess(to: root) else { continue }
                }
                let project: Project
                if let existing = findProject(matching: root) {
                    existing.isDerived = false
                    self.unlockGrantedProjects()
                    project = existing
                } else {
                    let created = Project(url: root)
                    self.install(created)
                    project = created
                }
                touchedProjects = true

                if let relPath = LSPTargetResolver.relativePath(of: target.fileURL, inside: project.url) {
                    landedFile = (project, relPath, target.line, target.column)
                } else {
                    landedExternalFile = (target.fileURL, target.line, target.column)
                }
            } else {
                landedExternalFile = (target.fileURL, target.line, target.column)
            }
        }

        if touchedProjects {
            for project in self.projects where project.worktreeOf == nil {
                self.syncWorktrees(of: project, force: true)
            }
        }

        if (landedFile != nil || landedExternalFile != nil || landedDirectoryProject != nil),
           popup != nil, popup != .dialog {
            dismissPopup(restoreFocus: false)
        }

        if let file = landedFile {
            if let index = projects.firstIndex(where: { $0.id == file.project.id }) {
                let folded = ProjectTree.ancestors(of: index, parents: projectParents).map { projects[$0].url.path }
                if !collapsedProjects.isDisjoint(with: folded) { collapsedProjects.subtract(folded) }
            }
            openFile(in: file.project, path: file.relativePath, line: file.line, column: file.column)
            updateDormancy()
            file.project.refresh()
            viewer.focusCanvas()
        } else if let ext = landedExternalFile {
            openExternalFile(
                fileURL: ext.fileURL,
                repoRoot: nil,
                workspaceRoot: nil,
                displayPath: LSPTargetResolver.shortenedPath(ext.fileURL),
                line: ext.line,
                column: ext.column
            )
        } else if let project = landedDirectoryProject {
            select(project)
        } else if rejected > 0 {
            if let refusal {
                self.showRefusal(refusal)
            } else if access.isNeeded {
                self.showToast(L("No Git repository found there · choose the repository's own folder",
                                 "这里没有找到 Git 仓库 · 请选择仓库本身所在的文件夹"))
            } else {
                self.showToast(L("No Git repository found there", "这里没有找到 Git 仓库"))
            }
        } else if let missing = missingFileName {
            showToast(L("Path not found: \(missing)", "路径不存在：\(missing)"))
        }

        if touchedProjects {
            self.persistProjects()
        }
    }

    /// Git's reason for not opening a folder, in place of "No Git repository found there".
    private func showRefusal(_ refusal: Git.Refusal) {
        let copy = { [weak self] (text: String) in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.showToast(L("Copied", "已复制"))
        }
        if let command = refusal.trustCommand {
            showToast(L("Git won't open this repository: it belongs to another user", "Git 拒绝打开这个仓库：它属于另一个用户"),
                      action: ToastAction(title: L("Copy the command that trusts it", "复制信任它的命令")) { copy(command) })
        } else {
            showToast(L("Git can't open this folder: \(refusal.message)", "Git 无法打开这个文件夹：\(refusal.message)"),
                      action: ToastAction(title: L("Copy", "复制")) { copy(refusal.message) })
        }
    }

    /// The sidebar's Refresh: the project's changes, and the repositories that appeared inside it since it was
    /// added, put right below it. Only this one looks for repositories; the other refreshes stay as light as they were.
    func refreshAndDiscover(_ project: Project) {
        project.refresh()
        if project.gitDirectory != nil { syncWorktrees(of: project, force: true) }
        Task { @MainActor in
            let found = await Git.repositories(for: project.url)
            guard self.projects.contains(where: { $0.id == project.id }) else { return }
            var added = 0
            for root in found {
                let path = root.standardizedFileURL.path
                guard !self.projects.contains(where: { $0.url.path == path }) else { continue }
                let inner = Project(url: root)
                self.install(inner)
                // Below the project and the repositories of its already listed.
                let below = project.url.path + "/"
                if let last = self.projects.dropLast().lastIndex(where: { $0.id == project.id || $0.url.path.hasPrefix(below) }) {
                    self.projects.move(fromOffsets: IndexSet(integer: self.projects.count - 1), toOffset: last + 1)
                }
                inner.refresh()
                added += 1
            }
            guard added > 0 else { return }
            self.persistProjects()
            self.showToast(added == 1 ? L("Added 1 repository found inside", "已添加新发现的 1 个子仓库")
                                      : L("Added \(added) repositories found inside", "已添加新发现的 \(added) 个子仓库"))
        }
    }

    func remove(_ project: Project) {
        if mergeSession?.project.id == project.id {
            closeMergeSession(rememberDismissal: false)
        }
        // The work trees listed under it go with it; those the user added stay, on their own.
        for worktree in projects where worktree.worktreeOf == project.id {
            worktree.worktreeOf = nil
            if worktree.isDerived { remove(worktree) }
        }
        terminals.removeAll(for: project)
        project.cancelCommitMessageGeneration()
        project.cancelAIGroupGeneration()
        deletePersistedAIGroups(for: project)
        project.stopWatching()
        projects.removeAll { $0.id == project.id }
        FolderAccess.shared.release(project.url.path, keepingFor: projects.map(\.url.path))
        if selectedProjectID == project.id {
            exitExternalFileMode()
            // A work tree that went: back to its repository.
            let owner = project.worktreeOf.flatMap { id in projects.first { $0.id == id } }
            selectedProjectID = (owner ?? projects.first)?.id
            syncViewer()
        }
        persistProjects()
    }

    // MARK: The projects as a tree

    /// For each project, the one it sits under: the repository of a work tree, or the listed folder it is inside.
    private var projectParents: [Int?] {
        let owners = projects.map { project in project.worktreeOf.flatMap { id in projects.firstIndex { $0.id == id } } }
        return ProjectTree.parents(projects.map(\.url.path), owners: owners)
    }

    /// The sidebar's rows: a repository inside another one listed sits under it, a work tree under its repository.
    var projectRows: [ProjectTree.Row] {
        let owners = projects.map { project in project.worktreeOf.flatMap { id in projects.firstIndex { $0.id == id } } }
        return ProjectTree.rows(paths: projects.map(\.url.path), owners: owners, collapsed: collapsedProjects)
    }

    /// The projects next to this one under the same parent, in order (itself included).
    private func siblings(of project: Project) -> [Project] {
        let parents = projectParents
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return [] }
        return projects.indices.filter { parents[$0] == parents[index] }.map { projects[$0] }
    }

    func canMove(_ project: Project, by delta: Int) -> Bool {
        let siblings = siblings(of: project)
        guard let position = siblings.firstIndex(where: { $0.id == project.id }) else { return false }
        return siblings.indices.contains(position + delta)
    }

    /// Up or down among the projects at its level; those inside it follow, being shown under it wherever it is.
    func move(_ project: Project, by delta: Int) {
        let siblings = siblings(of: project)
        guard let position = siblings.firstIndex(where: { $0.id == project.id }), siblings.indices.contains(position + delta),
              let from = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let other = siblings[position + delta]
        projects.remove(at: from)
        guard let to = projects.firstIndex(where: { $0.id == other.id }) else { return }
        projects.insert(project, at: delta < 0 ? to : to + 1)
        persistProjects()
    }

    /// The changes in the repositories and work trees folded away under a collapsed project, to count with its own
    /// (a work tree's as they were when it was folded: it is not watched meanwhile).
    func hiddenChanges(under project: Project) -> Int {
        guard collapsedProjects.contains(project.url.path), let index = projects.firstIndex(where: { $0.id == project.id }) else { return 0 }
        return ProjectTree.descendants(of: index, parents: projectParents).reduce(0) { $0 + projects[$1].changes.count }
    }

    func toggleCollapsed(_ project: Project) {
        let path = project.url.path
        if collapsedProjects.remove(path) == nil {
            collapsedProjects.insert(path)
            // The selection would vanish with the rows: it moves to the project folded.
            if let index = projects.firstIndex(where: { $0.id == project.id }), let current = currentProject,
               ProjectTree.descendants(of: index, parents: projectParents).contains(where: { projects[$0].id == current.id }) {
                select(project)
            }
        }
        updateDormancy()
        persistProjects()
    }

    // MARK: Linked work trees

    /// A work tree git lists is watched and asked for its status only while its row is in sight or it is selected:
    /// an agent can leave dozens behind, and each would cost a watcher and a `git status` at every change.
    private func updateDormancy() {
        let visible = Set(projectRows.map { projects[$0.index].id })
        for project in projects where project.isDerived {
            let dormant = !visible.contains(project.id) && project.id != selectedProjectID
            guard dormant != project.isDormant else { continue }
            project.isDormant = dormant
            if dormant {
                project.stopWatching()
            } else {
                project.startWatching()
                project.refresh()
            }
        }
    }

    /// Looks at the repository's work trees again when the folder git keeps them in has changed (or `force`), and
    /// lists them under it: new ones appear, removed ones go. Nothing is created, removed or switched in git.
    func syncWorktrees(of main: Project, force: Bool = false) {
        guard !main.needsAccess, main.worktreeOf == nil, let gitDirectory = main.gitDirectory else { return }
        // Work trees whose folder was deleted without telling git: the folder is the truth.
        for worktree in projects where worktree.isDerived && worktree.worktreeOf == main.id
            && !FileManager.default.fileExists(atPath: worktree.url.path) {
            remove(worktree)
        }
        let folder = gitDirectory.appendingPathComponent("worktrees")
        let stamp = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
        if !force, let seen = main.worktreesStamp, seen == stamp { return }
        // Never had any, and has none: nothing to ask git.
        if stamp == nil, !projects.contains(where: { $0.worktreeOf == main.id }) {
            main.worktreesStamp = .some(nil)
            return
        }
        main.worktreesStamp = .some(stamp)
        Task { @MainActor in
            let list = await Git.worktrees(in: main.url)
            func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
            // Only the main work tree lists the others: opened alone, a linked one stays alone.
            guard self.projects.contains(where: { $0.id == main.id }), let first = list.first,
                  real(first.path) == real(main.url.path) else { return }
            let wanted = list.dropFirst().filter { !$0.isBare && !$0.isPrunable && FileManager.default.fileExists(atPath: $0.path) }
            let wantedPaths = Set(wanted.map { real($0.path) })
            for worktree in self.projects where worktree.worktreeOf == main.id && !wantedPaths.contains(real(worktree.url.path)) {
                worktree.worktreeOf = nil
                if worktree.isDerived { self.remove(worktree) }
            }
            for entry in wanted {
                if let existing = self.projects.first(where: { real($0.url.path) == real(entry.path) }) {
                    // One the user added: shown under its repository, and still theirs.
                    if existing.id != main.id { existing.worktreeOf = main.id }
                    continue
                }
                guard FolderAccess.shared.covers(entry.path) else { continue }
                let worktree = Project(url: URL(fileURLWithPath: entry.path))
                worktree.worktreeOf = main.id
                worktree.isDerived = true
                self.install(worktree)
                // Its status once, so that a folded repository counts its changes; then asleep unless in sight.
                worktree.refresh()
                if let awaited = self.awaitedSelection, real(awaited) == real(entry.path) {
                    self.awaitedSelection = nil
                    self.select(worktree)
                }
            }
            self.updateDormancy()
        }
    }

    func select(_ project: Project) {
        exitExternalFileMode()
        // Chosen from elsewhere (Quick Open, a new repository found): it must be in sight.
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            let folded = ProjectTree.ancestors(of: index, parents: projectParents).map { projects[$0].url.path }
            if !collapsedProjects.isDisjoint(with: folded) { collapsedProjects.subtract(folded) }
        }
        if selectedProjectID != project.id {
            currentProject?.cancelAIGroupGeneration()
            pendingGroupHunkFocus = nil
            selectedProjectID = project.id
            persistProjects()
        }
        updateDormancy()
        project.refresh()
        syncViewer()
    }

    func selectProject(offset: Int) {
        guard !projects.isEmpty else { return }
        let index = projects.firstIndex { $0.id == selectedProjectID } ?? 0
        select(projects[(index + offset + projects.count) % projects.count])
    }

    func refreshCurrent() {
        guard let project = currentProject else { return }
        project.invalidateFiles()
        project.refresh()
        if project.tab == .log { project.loadLog(reset: true) }
        viewer.reload()
    }

    private func projectDidRefresh(_ project: Project) {
        syncWorktrees(of: project)
        if mergeSession?.project.id == project.id {
            mergeSession?.refreshFromProjectStatus()
        }
        if project.hasLoaded,
           project.errorMessage == nil,
           project.aiGroupResult != nil,
           project.changes.isEmpty,
           !project.isCommitting,
           !project.isCommittingGroup,
           !project.isGeneratingGroups {
            let editingInProject = viewer.request?.root == project.url
                && viewer.isEditing(root: project.url, path: viewer.request?.path ?? "")
            if !editingInProject {
                clearAIGroups(for: project)
            }
        }
        let currentSig = project.status.conflictSignature
        if project.id == selectedProjectID,
           settings.autoOpenThreeWayMerge,
           project.hadLoadedBeforeLastRefresh,
           mergeSession == nil,
           let currentSig,
           currentSig != project.lastConflictSignature,
           currentSig != project.dismissedConflictSignature {
            openThreeWayMerge(in: project, automatic: true)
        }
        project.lastConflictSignature = currentSig
        guard project.id == selectedProjectID else { return }
        if sidebarVisible { project.loadTree() }
        syncViewer()
        // A merge starting or ending, or a file's tick changing with its status, changes what can be picked.
        updateCommitTicks()
    }

    // MARK: Viewer synchronisation

    /// Applies the active `Settings.semanticDiffOptions` so equality checks stay consistent with `viewer.request`.
    func resolvedRequest(_ raw: DiffRequest) -> DiffRequest {
        var request = raw
        request.semantic = settings.semanticDiffOptions
        return request
    }

    /// Synchronizes `viewer`'s group hunk filter for `upcomingRequest` without wasting work on an outgoing file:
    /// - Same file (`viewer.request == upcomingRequest`): delegates to `setHighlightedGroupHunks` so the loaded
    ///   document re-filters in place immediately.
    /// - Different file (`viewer.request != upcomingRequest`): assigns `viewer.highlightedGroupHunks` directly so
    ///   the immediately following `viewer.open(upcomingRequest)` loads with the target filter in a single pass.
    func syncGroupHunkFilter(_ hunks: Set<Int>?, for upcomingRequest: DiffRequest) {
        if viewer.request == upcomingRequest {
            viewer.setHighlightedGroupHunks(hunks)
        } else {
            viewer.highlightedGroupHunks = hunks
        }
    }

    /// Points the viewer at whatever the current project's selection implies: the file being browsed
    /// by path if there is one, otherwise the selection of the list column.
    func syncViewer() {
        if let external = externalRequest {
            let request = resolvedRequest(external)
            syncGroupHunkFilter(nil, for: request)
            if viewer.request == request {
                viewer.reloadIfStale(base: nil)
            } else {
                viewer.open(request)
            }
            return
        }
        guard let project = currentProject else {
            viewer.highlightedGroupHunks = nil
            viewer.clear()
            return
        }
        viewer.setBaseStamp(project.status.headOID)
        if let path = project.browsedPath {
            let request = resolvedRequest(plainFileRequest(for: path, in: project))
            let exists = FileManager.default.fileExists(atPath: project.url.appendingPathComponent(path).path)
            let keepingUnsaved = viewer.isDirty && viewer.request?.root == project.url && viewer.request?.path == path
            if !exists && !keepingUnsaved {
                // Deleted and committed, or gone with a checkout: nothing left to follow.
                project.browsedPath = nil
            } else {
                // Keep showing the plain file view even while it has local changes.
                markInChanges(path, in: project)
                syncGroupHunkFilter(nil, for: request)
                if request == viewer.request {
                    viewer.reloadIfStale(base: project.status.headOID)
                } else {
                    let samePlainFile = viewer.request?.path == path && viewer.request?.root == project.url && viewer.request?.source == .file
                    viewer.open(request, preserveScroll: samePlainFile)
                }
                return
            }
        }
        switch project.tab {
        case .changes:
            if let comparison = project.comparison {
                viewer.highlightedGroupHunks = nil
                syncComparison(project, comparison)
                return
            }
            if let id = project.selectedChangeID {
                if !id.hasPrefix("f:") { return } // a folder or group row; leave the viewer alone
                if let change = project.change(forPath: String(id.dropFirst(2))) {
                    show(change, in: project, groupHunks: nil)
                    return
                }
                // The file being edited left the list (typed back to what HEAD has): it stays on screen, and
                // comes back into the list with the next keystroke that changes it.
                if viewer.isEditing(root: project.url, path: String(id.dropFirst(2))) {
                    viewer.setHighlightedGroupHunks(nil)
                    viewer.reloadIfStale(base: project.status.headOID)
                    return
                }
            }
            let ordered = ChangeTree.orderedFiles(changes: project.changes, flat: settings.flatList,
                                                  filter: project.filter, splitUnversioned: true)
            if let first = ordered.first {
                project.selectedChangeID = ChangeRow.fileID(first.path)
                show(first, in: project, groupHunks: nil)
            } else {
                project.selectedChangeID = nil
                if project.hasLoaded || viewer.request?.root != project.url {
                    viewer.highlightedGroupHunks = nil
                    viewer.clear()
                }
            }
        case .groups:
            if let group = project.activeAIGroup {
                if project.selectedGroupID != group.id {
                    project.selectedGroupID = group.id
                }
                let targetFile: AIHunkGroupFile? = {
                    if let selectedPath = project.selectedGroupFilePath,
                       let match = group.files.first(where: { $0.path == selectedPath }) {
                        return match
                    }
                    return project.orderedGroupFiles(for: group, flat: settings.flatList).first ?? group.files.first
                }()
                if let file = targetFile {
                    let targetHunk = project.selectedGroupFilePath == file.path
                        ? (project.selectedGroupHunkIndex ?? file.hunkIndices.first ?? 0)
                        : (file.hunkIndices.first ?? 0)
                    if project.selectedGroupFilePath != file.path {
                        project.selectedGroupFilePath = file.path
                        project.selectedGroupRowID = ChangeRow.fileID(file.path)
                        project.selectedGroupHunkIndex = targetHunk
                    } else if project.selectedGroupRowID == nil {
                        project.selectedGroupRowID = ChangeRow.fileID(file.path)
                    }
                    let targetHunks = project.highlightedGroupHunks(for: file.path)
                    let rawRequest: DiffRequest?
                    if let change = project.change(forPath: file.path) {
                        rawRequest = project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace)
                    } else if FileManager.default.fileExists(atPath: project.url.appendingPathComponent(file.path).path) {
                        rawRequest = worktreeRequest(for: file.path, in: project)
                    } else {
                        rawRequest = nil
                    }
                    if let rawRequest {
                        let request = resolvedRequest(rawRequest)
                        if request == viewer.request {
                            viewer.setHighlightedGroupHunks(targetHunks)
                            viewer.reloadIfStale(base: project.status.headOID)
                        } else {
                            // Prime group filter before viewer.open so ViewerModel loads filtered in a single pass
                            // without re-filtering the outgoing file.
                            pendingGroupHunkFocus = (root: project.url, path: file.path, hunkIndex: targetHunk)
                            syncGroupHunkFilter(targetHunks, for: request)
                            let sameFile = viewer.request?.path == request.path && viewer.request?.root == request.root && viewer.request?.source != .file
                            viewer.open(request, preserveScroll: sameFile)
                        }
                        return
                    }
                }
            }
            if let current = viewer.request, current.root == project.url, case .worktree = current.source {
                viewer.setHighlightedGroupHunks(nil)
                viewer.reloadIfStale(base: project.status.headOID)
                return
            }
            if let first = project.changes.first {
                show(first, in: project, groupHunks: nil)
            } else if project.hasLoaded || viewer.request?.root != project.url {
                viewer.highlightedGroupHunks = nil
                viewer.clear()
            }
        case .log:
            if project.commits.isEmpty, !project.isLoadingLog { project.loadLog(reset: true) }
            let commits = project.selectedCommits
            guard !commits.isEmpty, let id = project.selectedCommitFileID,
                  let change = project.commitFiles.first(where: { ChangeRow.fileID($0.path) == id }),
                  let request = project.request(for: change, in: commits, ignoreWhitespace: settings.ignoreWhitespace) else {
                // Keep showing the previous commit's diff while the next one loads.
                var showingCommit = false
                if let current = viewer.request, current.root == project.url, current.isCommitDiff { showingCommit = true }
                if !showingCommit || commits.isEmpty || (!project.isLoadingCommit && project.commitFiles.isEmpty) {
                    viewer.highlightedGroupHunks = nil
                    viewer.clear()
                }
                return
            }
            let resolved = resolvedRequest(request)
            syncGroupHunkFilter(nil, for: resolved)
            viewer.open(resolved)
        }
    }

    private func show(_ change: FileChange, in project: Project, groupHunks: Set<Int>? = nil) {
        let request = resolvedRequest(project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace))
        syncGroupHunkFilter(groupHunks, for: request)
        if request == viewer.request {
            viewer.reloadIfStale(base: project.status.headOID)
        } else {
            // Same file, different status (e.g. untracked → added): keep the reader's place.
            let sameDiff = viewer.request?.path == request.path && viewer.request?.root == request.root && viewer.request?.source != .file
            viewer.open(request, preserveScroll: sameDiff)
        }
    }

    func changeSelectionChanged(_ project: Project) {
        guard project.id == selectedProjectID, project.tab == .changes,
              let id = project.selectedChangeID,
              let change = project.changes.first(where: { ChangeRow.fileID($0.path) == id }) else { return }
        exitExternalFileMode()
        project.browsedPath = nil
        show(change, in: project)
        noteRecent(project, change.path)
        follow(change.path, in: project)
    }

    func commitSelectionChanged(_ project: Project) {
        exitExternalFileMode()
        project.loadSelectedCommit { [weak self, weak project] in
            guard let self, let project, project.id == self.selectedProjectID, project.tab == .log else { return }
            self.syncViewer()
        }
    }

    func commitFileSelectionChanged(_ project: Project) {
        guard project.id == selectedProjectID, project.tab == .log else { return }
        exitExternalFileMode()
        syncViewer()
        if project.browsedPath == nil, let path = viewer.request?.path { follow(path, in: project) }
    }

    /// The user picked a commit or one of its files: the viewer goes back to following the Log.
    func pickedInLog(_ project: Project, commitChanged: Bool) {
        let wasExternal = externalRequest != nil
        exitExternalFileMode()
        guard project.browsedPath != nil || wasExternal else { return }
        project.browsedPath = nil
        // A click on the row that is already selected changes nothing, so nothing else would bring its diff back.
        if commitChanged { commitSelectionChanged(project) } else { commitFileSelectionChanged(project) }
    }

    /// Keeps the Changes list's highlight on the file the viewer shows, or on nothing when that file has no changes.
    func markInChanges(_ path: String, in project: Project) {
        guard project.tab == .changes else { return }
        if project.comparison != nil {
            if project.compareChanges.contains(where: { $0.path == path }) {
                for id in ChangeTree.ancestors(of: path, in: project.compareCollapsed) { project.compareCollapsed.remove(id) }
                let id = ChangeRow.fileID(path)
                if project.compareSelectedID != id { project.compareSelectedID = id }
            } else if project.compareSelectedID != nil {
                project.compareSelectedID = nil
            }
            return
        }
        if project.changes.contains(where: { $0.path == path }) {
            for id in ChangeTree.ancestors(of: path, in: project.collapsed) { project.collapsed.remove(id) }
            let id = ChangeRow.fileID(path)
            if project.selectedChangeID != id { project.selectedChangeID = id }
        } else if project.selectedChangeID != nil {
            project.selectedChangeID = nil
        }
    }

    /// "Always Select Opened File": the tree follows whatever the viewer shows.
    func follow(_ path: String, in project: Project) {
        guard settings.followFile, sidebarVisible, project.treeSelectedID != TreeRow.fileID(path) else { return }
        project.revealInTree(path, flash: false)
    }

    // MARK: File tree

    /// A plain working-tree file request (`source == .file`), regardless of whether the file has local changes.
    func plainFileRequest(for path: String, in project: Project) -> DiffRequest {
        DiffRequest(root: project.url, path: path, oldPath: nil, kind: nil, source: .file)
    }

    /// How `path` is shown from the working tree: a diff while it has local changes, otherwise the file itself.
    /// While the Changes tab compares with another commit, the diff is against that commit.
    func worktreeRequest(for path: String, in project: Project) -> DiffRequest {
        if project.tab == .changes, let comparison = project.comparison {
            if let change = project.comparedChange(path) {
                return project.request(compared: change, with: comparison, ignoreWhitespace: settings.ignoreWhitespace)
            }
            return DiffRequest(root: project.url, path: path, oldPath: nil, kind: nil, source: .file)
        }
        if let change = project.changes.first(where: { $0.path == path }) {
            return project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace)
        }
        return DiffRequest(root: project.url, path: path, oldPath: nil, kind: nil, source: .file)
    }

    /// The user picked a row in the tree. Selecting a row from code (locating a file) does not come through here.
    func treeSelectionChanged(_ project: Project) {
        guard project.id == selectedProjectID, let id = project.treeSelectedID, id.hasPrefix("f:") else { return }
        browse(String(id.dropFirst(2)), in: project, line: nil)
    }

    /// ⌥F1: select the file on screen in the tree, with its folders opened and scrolled into view.
    func locateInTree() {
        guard let project = currentProject else { return }
        guard let path = viewer.request.flatMap({ $0.root == project.url ? $0.path : nil }) else {
            focusTree()
            return
        }
        if project.revealInTree(path, flash: true) {
            focusTree()
        } else {
            showToast(L("This file is not in the working tree", "这个文件不在当前工作区里"))
        }
    }

    func setTab(_ tab: ProjectTab) {
        guard let project = currentProject else { return }
        let targetTab: ProjectTab = (AppEnvironment.isAppStore && tab == .groups) ? .changes : tab
        let wasExternal = externalRequest != nil
        exitExternalFileMode()
        if !listVisible { listVisible = true }
        if project.tab != targetTab || wasExternal {
            if targetTab != .groups { pendingGroupHunkFocus = nil }
            project.tab = targetTab
            project.browsedPath = nil
            syncViewer()
        }
        focusList()
    }

    /// Moves to the next/previous file in the active list. Returns false at either end.
    @discardableResult
    func stepFile(_ delta: Int) -> Bool {
        guard let project = currentProject else { return false }
        exitExternalFileMode()
        if let path = project.browsedPath {
            // Browsing plain files from the tree or search: walk the files the tree shows.
            let files = project.treeRows().filter { !$0.isDirectory }
            if !files.isEmpty {
                let current = files.firstIndex { $0.path == path } ?? files.firstIndex { $0.id == project.treeSelectedID }
                let index = current.map { $0 + delta } ?? (delta > 0 ? 0 : files.count - 1)
                guard index >= 0, index < files.count else { return false }
                project.treeSelectedID = files[index].id
                treeSelectionChanged(project)
                return true
            }
        }
        switch project.tab {
        case .changes where project.comparison != nil:
            let files = ChangeTree.orderedFiles(changes: project.compareChanges, flat: settings.flatList,
                                                filter: project.filter, splitUnversioned: true)
            guard let target = neighbour(in: files, of: project.compareSelectedID, delta: delta) else { return false }
            for id in ChangeTree.ancestors(of: target.path, in: project.compareCollapsed) { project.compareCollapsed.remove(id) }
            project.compareSelectedID = ChangeRow.fileID(target.path)
            compareSelectionChanged(project)
        case .changes:
            let files = ChangeTree.orderedFiles(changes: project.changes, flat: settings.flatList,
                                                filter: project.filter, splitUnversioned: true)
            guard let target = neighbour(in: files, of: project.selectedChangeID, delta: delta) else { return false }
            for id in ChangeTree.ancestors(of: target.path, in: project.collapsed) { project.collapsed.remove(id) }
            project.selectedChangeID = ChangeRow.fileID(target.path)
            changeSelectionChanged(project)
        case .groups:
            guard let groups = project.aiGroupResult?.groups, !groups.isEmpty else { return false }
            let items: [(group: AIHunkGroup, file: AIHunkGroupFile)] = groups.flatMap { group in
                project.orderedGroupFiles(for: group, flat: settings.flatList).map { (group, $0) }
            }
            guard !items.isEmpty else { return false }
            let currentIndex = items.firstIndex {
                $0.group.id == project.selectedGroupID && $0.file.path == project.selectedGroupFilePath
            }
            let nextIndex = currentIndex.map { $0 + delta } ?? (delta > 0 ? 0 : items.count - 1)
            guard items.indices.contains(nextIndex) else { return false }
            let target = items[nextIndex]
            for id in ChangeTree.ancestors(of: target.file.path, in: project.groupCollapsed) {
                project.groupCollapsed.remove(id)
            }
            openGroupItem(project: project, group: target.group, filePath: target.file.path, hunkIndex: target.file.hunkIndices.first ?? 0)
        case .log:
            let files = ChangeTree.orderedFiles(changes: project.commitFiles, flat: settings.flatList,
                                                filter: "", splitUnversioned: false)
            guard let target = neighbour(in: files, of: project.selectedCommitFileID, delta: delta) else { return false }
            for id in ChangeTree.ancestors(of: target.path, in: project.commitCollapsed) { project.commitCollapsed.remove(id) }
            project.selectedCommitFileID = ChangeRow.fileID(target.path)
            commitFileSelectionChanged(project)
        }
        return true
    }

    private func neighbour(in files: [FileChange], of selected: String?, delta: Int) -> FileChange? {
        guard !files.isEmpty else { return nil }
        let index: Int
        if let current = files.firstIndex(where: { ChangeRow.fileID($0.path) == selected }) {
            index = current + delta
        } else {
            index = delta > 0 ? 0 : files.count - 1
        }
        return index >= 0 && index < files.count ? files[index] : nil
    }

    /// Opens a file by path (from the tree, search, or LSP jump) directly as plain file content.
    func openFile(in project: Project, path: String, line: Int?, column: Int? = nil) {
        if selectedProjectID != project.id {
            currentProject?.cancelAIGroupGeneration()
            pendingGroupHunkFocus = nil
            selectedProjectID = project.id
            persistProjects()
        }
        browse(path, in: project, line: line, column: column)
        follow(path, in: project)
    }

    /// Opens a cross-file LSP jump target in `project` honoring `settings.lspJumpOpenMode`.
    /// When set to `.diff` and the target file has changes (in the active comparison or working tree),
    /// opens its diff view at `line`/`column`; otherwise falls back to plain file view.
    func openFileForLSP(in project: Project, path: String, line: Int?, column: Int? = nil) {
        guard settings.lspJumpOpenMode == .diff else {
            openFile(in: project, path: path, line: line, column: column)
            return
        }
        if selectedProjectID != project.id {
            currentProject?.cancelAIGroupGeneration()
            pendingGroupHunkFocus = nil
            selectedProjectID = project.id
            persistProjects()
        }
        if project.tab == .changes, let comparison = project.comparison {
            if let compared = project.comparedChange(path) {
                for id in ChangeTree.ancestors(of: path, in: project.compareCollapsed) {
                    project.compareCollapsed.remove(id)
                }
                project.compareSelectedID = ChangeRow.fileID(path)
                let rawRequest = project.request(
                    compared: compared,
                    with: comparison,
                    ignoreWhitespace: settings.ignoreWhitespace
                )
                openDiffForLSP(rawRequest: rawRequest, path: path, in: project, line: line, column: column)
                return
            }
            // Not part of the active comparison: fall back to plain file without cancelling comparison.
            openFile(in: project, path: path, line: line, column: column)
            return
        }
        if let change = project.change(forPath: path) {
            if project.tab != .changes { project.tab = .changes }
            for id in ChangeTree.ancestors(of: path, in: project.collapsed) {
                project.collapsed.remove(id)
            }
            project.selectedChangeID = ChangeRow.fileID(path)
            let rawRequest = project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace)
            openDiffForLSP(rawRequest: rawRequest, path: path, in: project, line: line, column: column)
            return
        }
        openFile(in: project, path: path, line: line, column: column)
    }

    private func openDiffForLSP(rawRequest: DiffRequest, path: String, in project: Project, line: Int?, column: Int?) {
        exitExternalFileMode()
        pendingGroupHunkFocus = nil
        project.browsedPath = nil
        let request = resolvedRequest(rawRequest)
        viewer.setBaseStamp(project.status.headOID)
        syncGroupHunkFilter(nil, for: request)
        noteRecent(project, path)
        viewer.open(request, line: line, column: column, preserveScroll: false)
        follow(path, in: project)
    }

    private func browse(_ path: String, in project: Project, line: Int?, column: Int? = nil) {
        exitExternalFileMode()
        pendingGroupHunkFocus = nil
        noteRecent(project, path)
        project.browsedPath = path
        viewer.setBaseStamp(project.status.headOID)
        let request = resolvedRequest(plainFileRequest(for: path, in: project))
        syncGroupHunkFilter(nil, for: request)
        markInChanges(path, in: project)
        let sameFile = viewer.request?.path == path && viewer.request?.root == project.url
        var targetLine = line
        var targetColumn = column
        if targetLine == nil, sameFile, viewer.request?.source != .file,
           viewer.isTextDocument, viewer.document != nil, !viewer.isLoading {
            let pos = viewer.currentCaretPosition()
            targetLine = pos.row + 1
            targetColumn = pos.column
        }
        let preserveScroll = sameFile && viewer.request?.source == .file && targetLine == nil
        viewer.open(request, line: targetLine, column: targetColumn, preserveScroll: preserveScroll)
    }

    /// True when the viewer is currently showing a non-plain diff/commit view of a working-tree file that exists on disk.
    var canOpenCurrentFile: Bool {
        guard let project = currentProject,
              let request = viewer.request,
              request.root == project.url,
              request.source != .file,
              !request.isExternalFile,
              !viewer.isSpreadsheet else { return false }
        let _ = project.changes
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: request.fileURL.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Opens the file currently shown in Diff / Commit view directly as editable plain file content, keeping the caret line.
    func openCurrentFile() {
        guard let project = currentProject,
              let request = viewer.request,
              request.root == project.url else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: request.fileURL.path, isDirectory: &isDir), !isDir.boolValue else {
            showToast(L("This file is not in the working tree", "这个文件不在当前工作区里"))
            return
        }
        var line: Int?
        var column: Int?
        if viewer.isTextDocument, viewer.document != nil, !viewer.isLoading {
            let pos = viewer.currentCaretPosition()
            line = pos.row + 1
            column = pos.column
            recordJumpOrigin(from: request, line0Based: pos.row, column: pos.column)
        }
        openFile(in: project, path: request.path, line: line, column: column)
        viewer.focusCanvas()
    }

    /// True when the viewer is showing a plain working-tree file that has changes to compare against.
    var canShowDiffForCurrentFile: Bool {
        guard let project = currentProject,
              let request = viewer.request,
              request.root == project.url,
              request.source == .file,
              !viewer.isSpreadsheet else { return false }
        if project.tab == .changes, project.comparison != nil {
            return project.comparedChange(request.path) != nil
        }
        return project.change(forPath: request.path) != nil
    }

    /// Switches from the current plain-file view back to its diff view, keeping the caret line.
    func showDiffForCurrentFile() {
        guard let project = currentProject,
              let request = viewer.request,
              request.root == project.url else { return }
        let path = request.path
        let diffRequest: DiffRequest
        if project.tab == .changes, let comparison = project.comparison, let compared = project.comparedChange(path) {
            project.compareSelectedID = ChangeRow.fileID(path)
            diffRequest = resolvedRequest(project.request(compared: compared, with: comparison, ignoreWhitespace: settings.ignoreWhitespace))
        } else if let change = project.change(forPath: path) {
            if project.tab != .changes { project.tab = .changes }
            if project.comparison != nil { project.comparison = nil }
            for id in ChangeTree.ancestors(of: path, in: project.collapsed) { project.collapsed.remove(id) }
            project.selectedChangeID = ChangeRow.fileID(path)
            diffRequest = resolvedRequest(project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace))
        } else {
            return
        }
        exitExternalFileMode()
        pendingGroupHunkFocus = nil
        project.browsedPath = nil
        viewer.setBaseStamp(project.status.headOID)
        syncGroupHunkFilter(nil, for: diffRequest)
        var line: Int?
        var column: Int?
        if viewer.isTextDocument, viewer.document != nil, !viewer.isLoading {
            let pos = viewer.currentCaretPosition()
            line = pos.row + 1
            column = pos.column
            recordJumpOrigin(from: request, line0Based: pos.row, column: pos.column)
        }
        noteRecent(project, path)
        viewer.open(diffRequest, line: line, column: column, preserveScroll: false)
        viewer.focusCanvas()
    }

    /// Opens the working-tree diff for `change` (for example from the file tree's context menu).
    func showChangeDiff(_ change: FileChange, in project: Project) {
        if selectedProjectID != project.id {
            currentProject?.cancelAIGroupGeneration()
            selectedProjectID = project.id
            persistProjects()
        }
        exitExternalFileMode()
        pendingGroupHunkFocus = nil
        project.browsedPath = nil
        if project.comparison != nil { endComparison(in: project) }
        if project.tab != .changes { project.tab = .changes }
        for id in ChangeTree.ancestors(of: change.path, in: project.collapsed) { project.collapsed.remove(id) }
        project.selectedChangeID = ChangeRow.fileID(change.path)
        viewer.setBaseStamp(project.status.headOID)
        show(change, in: project, groupHunks: nil)
        noteRecent(project, change.path)
        viewer.focusCanvas()
    }

    func noteRecent(_ project: Project, _ path: String) {
        let entry = RecentFile(projectID: project.id, path: path)
        recent.removeAll { $0 == entry }
        recent.insert(entry, at: 0)
        if recent.count > 40 { recent.removeLast(recent.count - 40) }
    }

    // MARK: Panels and focus

    func changeInterfaceFontSize(by delta: Double) {
        let range = Settings.uiFontRange
        let size = min(range.upperBound, max(range.lowerBound, settings.uiFontSize + delta))
        guard size != settings.uiFontSize else { return }
        settings.uiFontSize = size
        settings.save()
    }

    func changeTerminalFontSize(by delta: Double) {
        let range = Settings.terminalFontRange
        let size = min(range.upperBound, max(range.lowerBound, settings.terminalFontSize + delta))
        guard size != settings.terminalFontSize else { return }
        settings.terminalFontSize = size
        settings.save()
        terminals.applyFont(size: size, family: settings.terminalFontFamily)
    }

    /// A font family picked in Settings for code; nil puts back the default face.
    func chooseCodeFont(_ family: String?) {
        guard family != settings.codeFontFamily else { return }
        settings.codeFontFamily = family
        settings.save()
        viewer.applyCodeFont()
        finder.applyCodeFont()
        references.applyCodeFont()
        mergeSession?.applyCodeFont()
    }

    func chooseCodeFontMainWeight(_ weight: CodeFontWeight) {
        guard weight != settings.codeFontMainWeight else { return }
        settings.codeFontMainWeight = weight
        settings.save()
        viewer.applyCodeFont()
        finder.applyCodeFont()
        references.applyCodeFont()
        mergeSession?.applyCodeFont()
    }

    func chooseCodeFontBoldWeight(_ weight: CodeFontWeight) {
        guard weight != settings.codeFontBoldWeight else { return }
        settings.codeFontBoldWeight = weight
        settings.save()
        viewer.applyCodeFont()
        finder.applyCodeFont()
        references.applyCodeFont()
        mergeSession?.applyCodeFont()
    }

    func setCodeFontLigatures(_ enabled: Bool) {
        guard enabled != settings.codeFontLigatures else { return }
        settings.codeFontLigatures = enabled
        settings.save()
        viewer.applyCodeFont()
        finder.applyCodeFont()
        references.applyCodeFont()
        mergeSession?.applyCodeFont()
    }

    /// A font family picked in Settings for terminals; nil puts back the default face.
    func chooseTerminalFont(_ family: String?) {
        guard family != settings.terminalFontFamily else { return }
        settings.terminalFontFamily = family
        settings.save()
        terminals.applyFont(size: settings.terminalFontSize, family: family)
    }

    func toggleSidebar() {
        withAnimation(.snappy(duration: 0.2)) { sidebarVisible.toggle() }
    }

    /// The custom list that has the keyboard, by the name it was given ("tree", "list", …).
    var focusedListName: String? {
        (window?.firstResponder as? KeyCatcher.CatcherView)?.identifier?.rawValue
    }

    /// ⌘0 / ⌘8 / ⌘9: show that tool window, or hide the list if it is already showing it.
    func toggleTab(_ tab: ProjectTab) {
        if AppEnvironment.isAppStore && tab == .groups { return }
        guard let project = currentProject else { return }
        if listVisible, project.tab == tab {
            // As in the IDE: the first press brings the keyboard to the tool window, the next one hides it.
            if let name = focusedListName, name != KeyboardListName.tree {
                withAnimation(.snappy(duration: 0.2)) { listVisible = false }
                viewer.focusCanvas()
            } else {
                focusList()
            }
        } else {
            withAnimation(.snappy(duration: 0.2)) { listVisible = true }
            setTab(tab)
        }
    }

    /// ⌘1, the IDE's Project tool window: the file tree in the sidebar. Pressed again with the tree focused, it hides the sidebar.
    func toggleFileTree() {
        guard currentProject != nil else {
            toggleSidebar()
            return
        }
        if sidebarVisible, focusedListName == KeyboardListName.tree {
            withAnimation(.snappy(duration: 0.2)) { sidebarVisible = false }
            viewer.focusCanvas()
        } else {
            focusTree()
        }
    }

    func focusTree() {
        if !sidebarVisible { withAnimation(.snappy(duration: 0.2)) { sidebarVisible = true } }
        currentProject?.loadTree()
        treeFocusToken += 1
        KeyCatcher.pending = (treeFocusToken, CACurrentMediaTime())
    }

    func toggleMaximizeViewer() {
        withAnimation(.snappy(duration: 0.2)) {
            if let saved = panelsBeforeMaximize, !sidebarVisible, !listVisible {
                sidebarVisible = saved.sidebar
                listVisible = saved.list
                panelsBeforeMaximize = nil
            } else {
                panelsBeforeMaximize = (sidebarVisible, listVisible)
                sidebarVisible = false
                listVisible = false
            }
        }
    }

    func focusList() {
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        listFocusToken += 1
        KeyCatcher.pending = (listFocusToken, CACurrentMediaTime())
    }

    func focusViewer() {
        viewer.focusCanvas()
    }

    // MARK: Vim

    var vimModeEnabled: Bool {
        get { viewer.vimModeEnabled }
        set { viewer.setVimMode(newValue) }
    }

    func expandSelection() {
        viewer.expandSelection()
    }

    func shrinkSelection() {
        viewer.shrinkSelection()
    }

    func handleVimAction(_ action: VimAction, line: Int, column: Int) {
        switch action {
        case .goToDefinition:
            smartLSPNavigate(line: line, character: column)
        case .findReferences:
            findAllReferences(atLine: line, utf16Column: column)
        case .goToFile:
            showQuickOpen(.files)
        case .goToSymbol:
            showQuickOpen(.symbols)
        case .searchEverywhere:
            showQuickOpen(.all)
        case .findAction:
            showQuickOpen(.actions)
        case .gitPull:
            pull()
        case .gitPush:
            push()
        case .toggleGitGraph:
            toggleGitGraph()
        case .toggleMaximizeViewer:
            toggleMaximizeViewer()
        case .locateInTree:
            locateInTree()
        case .toggleFileTree:
            toggleFileTree()
        case .navigateBack:
            navigateBack()
        case .navigateForward:
            navigateForward()
        case .focusLeftPane:
            if listVisible {
                focusList()
            } else if sidebarVisible {
                focusTree()
            } else {
                focusList()
            }
        case .focusRightPane:
            focusViewer()
        case .quit:
            if popup != nil {
                dismissPopup()
            } else if viewer.findVisible {
                viewer.hideFind()
            } else if externalRequest != nil {
                exitExternalFileMode()
                syncViewer()
            } else {
                viewer.onExit?()
            }
        default:
            break
        }
    }

    // MARK: Popups

    func present(_ kind: Popup) {
        if popup == nil { responderBeforePopup = window?.firstResponder }
        // Another popup over an unanswered question cancels the question, so whoever asked hears back.
        if popup == .dialog, kind != .dialog, let request = dialog {
            dialog = nil
            request.onCancel()
        }
        if popup == .gitGraph, kind != .gitGraph { gitGraph.release() }
        if popup == .references, kind != .references { references.release() }
        if popup == .fileSymbols, kind != .fileSymbols { fileSymbols.release() }
        popup = kind
    }

    func dismissPopup(restoreFocus: Bool = true) {
        guard popup != nil else { return }
        let unanswered = popup == .dialog ? dialog : nil
        if popup == .gitGraph { gitGraph.release() }
        if popup == .references { references.release() }
        if popup == .fileSymbols { fileSymbols.release() }
        dialog = nil
        popup = nil
        if restoreFocus {
            if let responder = responderBeforePopup as? NSView, responder.window != nil {
                window?.makeFirstResponder(responder)
            } else {
                viewer.focusCanvas()
            }
        }
        unanswered?.onCancel()
    }

    func showQuickOpen(_ scope: QuickOpenModel.Scope) {
        guard currentProject != nil || scope == .actions else {
            presentAddProject()
            return
        }
        if popup == .quickOpen, quickOpen.scope == scope {
            dismissPopup()
            return
        }
        quickOpen.prepare(scope: scope)
        present(.quickOpen)
    }

    func showFindInPath() {
        guard currentProject != nil else { return }
        let selected = viewer.container?.canvas.selectedText()
        finder.prepare(seed: selected.flatMap { $0.contains("\n") || $0.isEmpty ? nil : $0 })
        present(.findInPath)
    }

    func showFileSymbols() {
        if popup == .fileSymbols {
            dismissPopup()
            return
        }
        guard viewer.isTextDocument else { return }
        fileSymbols.prepare()
        present(.fileSymbols)
    }

    func showToast(_ text: String, action: ToastAction? = nil) {
        toastWork?.cancel()
        toastAction = action
        withAnimation(.snappy(duration: 0.2)) { toast = text }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) { self?.toast = nil }
            self?.toastAction = nil
        }
        toastWork = work
        // Long enough to reach for the button when there is one.
        DispatchQueue.main.asyncAfter(deadline: .now() + (action == nil ? 2.6 : 6), execute: work)
    }

    func dismissToast() {
        toastWork?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { toast = nil }
        toastAction = nil
    }

    // MARK: File actions

    var currentFileURL: URL? {
        viewer.request.map { $0.root.appendingPathComponent($0.path) }
    }

    func copyPath(withLine: Bool = false) {
        guard let request = viewer.request else { return }
        var text = request.isExternalFile ? request.fileURL.path : request.path
        if withLine, let line = viewer.container?.canvas.currentLineNumber() { text += ":\(line)" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(L("Copied \(text)", "已复制 \(text)"))
    }

    func revealInFinder() {
        guard let url = currentFileURL else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    /// ⌥⌘T: types the file on screen — with the selected lines, if any — into the terminal, ready to hand to an agent.
    func insertReferenceInTerminal() {
        guard let project = currentProject, let request = viewer.request, request.root == project.url else { return }
        var text = Shell.quote(request.path)
        if let lines = viewer.container?.canvas.selectedLineRange() {
            text += lines.count > 1 ? ":\(lines.lowerBound)-\(lines.upperBound)" : ":\(lines.lowerBound)"
        }
        terminals.type(text + " ", in: project)
    }

    func viewerContextMenu() -> NSMenu? {
        guard viewer.request != nil else { return nil }
        let menu = NSMenu()
        if let canvas = viewer.container?.canvas, let sticky = canvas.contextStickyLine {
            menu.addItem(ClosureMenuItem(L("Jump to Line \(sticky.line + 1)", "跳转到第 \(sticky.line + 1) 行")) { [weak self, weak canvas] in
                guard let self, let canvas else { return }
                self.viewer.canvas(canvas, didClickStickyLine: sticky.line, side: sticky.side, slotIndex: 0)
            })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Hide Sticky Lines", "隐藏粘性行")) { [weak self] in
                self?.viewer.setStickyLines(false)
            })
            return menu
        }
        if AppEnvironment.hasLSP,
           let canvas = viewer.container?.canvas,
           canvas.isLSPEnabled,
           let target = canvas.contextLSPSymbol {
            menu.addItem(ClosureMenuItem(L("Go to Definition", "跳转到声明")) { [weak self] in
                self?.goToDefinition(atLine: target.line, utf16Column: target.utf16Column)
            })
            menu.addItem(ClosureMenuItem(L("Find All References", "查找所有引用")) { [weak self] in
                self?.findAllReferences(atLine: target.line, utf16Column: target.utf16Column)
            })
            menu.addItem(.separator())
        }
        if let canvas = viewer.container?.canvas, canvas.editSelection != nil {
            menu.addItem(ClosureMenuItem(L("Cut", "剪切")) { [weak canvas] in canvas?.cut(nil) })
            menu.addItem(ClosureMenuItem(L("Copy", "复制")) { [weak canvas] in canvas?.copy(nil) })
            if NSPasteboard.general.availableType(from: [.string]) != nil {
                menu.addItem(ClosureMenuItem(L("Paste", "粘贴")) { [weak canvas] in canvas?.paste(nil) })
            }
            menu.addItem(.separator())
        } else if viewer.container?.canvas.selectedText() != nil {
            menu.addItem(ClosureMenuItem(L("Copy", "复制")) { [weak self] in self?.viewer.container?.canvas.copy(nil) })
            menu.addItem(.separator())
        }
        if let project = currentProject, let change = viewerChange(in: project) {
            var added = false
            if viewer.canRevertHunks, let hunk = viewer.container?.canvas.contextHunk {
                menu.addItem(ClosureMenuItem(L("Rollback This Change", "回滚这一处变更")) { [weak self] in self?.rollbackHunk(hunk) })
                added = true
            }
            if Self.canRollback(change) {
                menu.addItem(ClosureMenuItem(L("Rollback File…", "回滚整个文件…")) { [weak self] in self?.rollback([change], in: project) })
                added = true
            }
            if Self.canDelete(change) {
                menu.addItem(ClosureMenuItem(L("Delete File…", "删除文件…")) { [weak self] in self?.delete([change], in: project) })
                added = true
            }
            if added { menu.addItem(.separator()) }
            if addCommitPickItems(to: menu, project: project) { menu.addItem(.separator()) }
        }
        if let project = currentProject { addHistoryItems(to: menu, project: project) }
        if canOpenCurrentFile {
            menu.addItem(ClosureMenuItem(L("Open File Content", "直接打开当前文件内容")) { [weak self] in self?.openCurrentFile() })
        } else if canShowDiffForCurrentFile {
            menu.addItem(ClosureMenuItem(L("Show Diff", "查看差异")) { [weak self] in self?.showDiffForCurrentFile() })
        }
        menu.addItem(ClosureMenuItem(L("Select in File Tree", "在文件树中定位")) { [weak self] in self?.locateInTree() })
        if AppEnvironment.hasTerminal {
            menu.addItem(ClosureMenuItem(L("Insert Path into Terminal", "把路径插入终端")) { [weak self] in self?.insertReferenceInTerminal() })
        }
        menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) { [weak self] in self?.revealInFinder() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) { [weak self] in self?.copyPath() })
        menu.addItem(ClosureMenuItem(L("Copy Path with Line Number", "复制路径和行号")) { [weak self] in self?.copyPath(withLine: true) })
        return menu
    }
}
