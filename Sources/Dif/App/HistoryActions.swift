import AppKit
import SwiftUI

/// A file's history and its lines' history (in the Log), Annotate, and comparing the working tree with another
/// commit or branch (in the Changes tab).
extension AppStore {
    // MARK: History

    /// Lists in the Log the commits that changed a file, or some of its lines, in a dedicated switchable tab
    /// (reusing an existing tab with the same `filter`) so existing Log selections and filters are preserved.
    /// - Parameter hash: a commit to pick instead of the newest (one clicked in the Annotate column or Selection History).
    func showHistory(_ filter: HistoryFilter, in project: Project, select hash: String? = nil) {
        exitExternalFileMode()
        if selectedProjectID != project.id {
            selectedProjectID = project.id
        }
        project.syncActiveLogTabFromLive()

        if let existing = project.logTabs.first(where: { $0.history == filter }) {
            _ = project.switchLogTab(to: existing.id)
            project.browsedPath = nil
            project.tab = .log
            if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
            let isStale = project.logTabs.first(where: { $0.id == existing.id })?.isStale ?? false
            if let hash {
                project.selectedCommitFileID = nil
                project.hasLoadedCommitSelection = false
                project.setCommitSelection(primary: hash, ids: [hash])
                if project.commits.contains(where: { $0.hash == hash }), !isStale {
                    project.logRevealToken &+= 1
                    commitSelectionChanged(project)
                } else {
                    project.loadLog(
                        reset: true,
                        atLeast: 2000,
                        restorePrimary: hash,
                        restoreSelection: [hash]
                    ) { [weak self, weak project] in
                        guard let self, let project, project.history == filter else { return }
                        self.commitSelectionChanged(project)
                    }
                }
            } else if project.commits.isEmpty || isStale {
                loadActiveLogTab(for: project)
            } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
                commitSelectionChanged(project)
            } else {
                syncViewer()
            }
            persistLogState(for: project)
            focusList()
            return
        }

        let newTab = LogTab(
            history: filter,
            selectedCommitID: hash,
            selectedCommitIDs: hash.map { [$0] } ?? [],
            needsSelectionRestore: hash != nil
        )
        project.addAndActivateLogTab(newTab)
        project.browsedPath = nil
        project.tab = .log
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        let targetTabID = newTab.id
        project.loadLog(
            reset: true,
            atLeast: hash == nil ? 0 : 2000,
            restorePrimary: hash,
            restoreSelection: hash.map { [$0] } ?? []
        ) { [weak self, weak project] in
            guard let self, let project, project.activeLogTabID == targetTabID, project.history == filter else { return }
            self.commitSelectionChanged(project)
        }
        persistLogState(for: project)
        focusList()
    }

    /// Closes the current file/line history tab (returning to the previous tab) or resets it to the full Log.
    func endHistory() {
        exitExternalFileMode()
        guard let project = currentProject, project.history != nil else { return }
        closeLogTab(project.activeLogTabID, in: project)
    }

    /// Loads the currently active Log tab's commits and syncs commit files/viewer, restoring persisted selections when needed.
    func loadActiveLogTab(
        for project: Project,
        preserveExistingSelection: Bool = false,
        forceCommitReload: Bool = false
    ) {
        let targetTabID = project.activeLogTabID
        let shouldRestore = project.needsLogSelectionRestore || preserveExistingSelection
        let restorePrimary = shouldRestore ? project.selectedCommitID : nil
        let restoreSelection = shouldRestore ? project.selectedCommitIDs : []
        let minLoad = (restorePrimary != nil || !restoreSelection.isEmpty)
            ? max(Project.logPageSize, min(max(project.commits.count, 500), 2000))
            : 0
        project.loadLog(
            reset: true,
            atLeast: minLoad,
            restorePrimary: restorePrimary,
            restoreSelection: restoreSelection
        ) { [weak self, weak project] in
            guard let self, let project, project.activeLogTabID == targetTabID else { return }
            if project.id == self.selectedProjectID, project.tab == .log {
                self.commitSelectionChanged(project, force: forceCommitReload)
            } else {
                project.loadSelectedCommit(force: forceCommitReload) {}
            }
        }
    }

    func selectLogTab(_ id: UUID, in project: Project) {
        exitExternalFileMode()
        guard project.switchLogTab(to: id) else { return }
        project.browsedPath = nil
        if project.tab != .log { project.tab = .log }
        let isStale = project.logTabs.first(where: { $0.id == id })?.isStale ?? false
        if project.commits.isEmpty || isStale {
            loadActiveLogTab(for: project)
        } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
            commitSelectionChanged(project)
        } else {
            syncViewer()
        }
        persistLogState(for: project)
    }

    func newLogTab(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        exitExternalFileMode()
        let tab = LogTab()
        project.addAndActivateLogTab(tab)
        project.browsedPath = nil
        if project.tab != .log { project.tab = .log }
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        loadActiveLogTab(for: project)
        persistLogState(for: project)
        focusList()
    }

    func duplicateLogTab(_ id: UUID, in project: Project) {
        exitExternalFileMode()
        project.syncActiveLogTabFromLive()
        guard let source = project.logTabs.first(where: { $0.id == id }) else { return }
        let copy = source.duplicated()
        project.addAndActivateLogTab(copy)
        project.browsedPath = nil
        if project.tab != .log { project.tab = .log }
        if copy.commits.isEmpty || copy.isStale {
            loadActiveLogTab(for: project)
        } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
            commitSelectionChanged(project)
        } else {
            syncViewer()
        }
        persistLogState(for: project)
    }

    func closeLogTab(_ id: UUID, in project: Project) {
        exitExternalFileMode()
        let result = project.closeLogTab(id)
        if result.changedActive {
            project.browsedPath = nil
            let isStale = project.logTabs.first(where: { $0.id == project.activeLogTabID })?.isStale ?? false
            if result.resetOnlyTab || project.commits.isEmpty || isStale {
                loadActiveLogTab(for: project)
            } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
                commitSelectionChanged(project)
            } else {
                syncViewer()
            }
        }
        persistLogState(for: project)
    }

    func closeOtherLogTabs(keeping id: UUID, in project: Project) {
        exitExternalFileMode()
        project.syncActiveLogTabFromLive()
        guard let kept = project.logTabs.first(where: { $0.id == id }) else { return }
        let switched = project.activeLogTabID != id
        project.logTabs = [kept]
        project.logTabMRU.removeAll()
        if switched {
            project.applyLogTabToLive(kept)
            project.browsedPath = nil
            if project.tab != .log { project.tab = .log }
            if kept.commits.isEmpty || kept.isStale {
                loadActiveLogTab(for: project)
            } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
                commitSelectionChanged(project)
            } else {
                syncViewer()
            }
        }
        persistLogState(for: project)
    }

    func closeHistoryLogTabs(in project: Project) {
        exitExternalFileMode()
        project.syncActiveLogTabFromLive()
        let remaining = project.logTabs.filter { $0.history == nil }
        let activeRemoved = project.history != nil
        if remaining.isEmpty {
            let fresh = LogTab()
            project.logTabs = [fresh]
            project.logTabMRU.removeAll()
            project.applyLogTabToLive(fresh)
            project.browsedPath = nil
            loadActiveLogTab(for: project)
        } else {
            project.logTabs = remaining
            let survivingIDs = Set(remaining.map(\.id))
            project.logTabMRU.removeAll { !survivingIDs.contains($0) }
            if activeRemoved {
                let nextID = project.logTabMRU.last(where: { survivingIDs.contains($0) }) ?? remaining[0].id
                if let nextTab = remaining.first(where: { $0.id == nextID }) {
                    project.applyLogTabToLive(nextTab)
                    project.browsedPath = nil
                    if nextTab.commits.isEmpty || nextTab.isStale {
                        loadActiveLogTab(for: project)
                    } else if !project.hasLoadedCommitSelection && !project.selectedCommits.isEmpty {
                        commitSelectionChanged(project)
                    } else {
                        syncViewer()
                    }
                }
            }
        }
        persistLogState(for: project)
    }

    func closeActiveLogTab() {
        guard let project = currentProject, project.tab == .log else { return }
        closeLogTab(project.activeLogTabID, in: project)
    }

    func cycleLogTab(_ delta: Int) {
        guard let project = currentProject,
              project.tab == .log,
              project.logTabs.count > 1,
              let index = project.logTabs.firstIndex(where: { $0.id == project.activeLogTabID }) else { return }
        let next = (index + delta + project.logTabs.count) % project.logTabs.count
        selectLogTab(project.logTabs[next].id, in: project)
    }

    // MARK: Log Persistence

    func restoreLogState(for project: Project) {
        guard let state = logStateStorage.load(for: project.url) else { return }
        project.restoreLogState(state)
    }

    func persistLogState(for project: Project) {
        logPersistTasks.removeValue(forKey: project.id)?.cancel()
        if let state = project.persistedLogState() {
            logStateStorage.save(state, for: project.url)
        } else {
            logStateStorage.delete(for: project.url)
        }
    }

    func schedulePersistLogState(for project: Project) {
        logPersistTasks.removeValue(forKey: project.id)?.cancel()
        logPersistTasks[project.id] = Task { @MainActor [weak self, weak project] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self, let project else { return }
            self.logPersistTasks.removeValue(forKey: project.id)
            self.persistLogState(for: project)
        }
    }

    func deletePersistedLogState(for project: Project) {
        logPersistTasks.removeValue(forKey: project.id)?.cancel()
        logStateStorage.delete(for: project.url)
    }

    func flushAllPersistedLogStates() {
        for (_, task) in logPersistTasks {
            task.cancel()
        }
        logPersistTasks.removeAll()
        for project in projects {
            persistLogState(for: project)
        }
    }

    /// The history of the file on screen.
    func showHistoryForCurrentFile() {
        guard let project = currentProject, let request = viewer.request, request.root == project.url else { return }
        guard let filter = historyFilter(for: request, lines: nil, in: project) else {
            showToast(L("Not committed yet · no history", "这个文件还没有提交过 · 没有历史"))
            return
        }
        showHistory(filter, in: project)
    }

    /// Opens the GoLand-style Selection History preview popup for the selected lines (or current caret line).
    func showHistoryForSelection() {
        if popup == .selectionHistory {
            dismissPopup()
            return
        }
        guard let project = currentProject, let request = viewer.request, request.root == project.url,
              let canvas = viewer.container?.canvas else { return }
        guard let selected = selectedLinesForHistory(in: canvas) else {
            showHistoryForCurrentFile()
            return
        }
        let displayPath = selected.side == .left ? (request.oldPath ?? request.path) : request.path
        let displayLines = (selected.range.lowerBound + 1)...(selected.range.upperBound + 1)
        let notCommitted = L("These lines are not committed yet · no history", "这些行还没有提交过 · 没有历史")
        guard !countsInHead(request, side: selected.side) else {
            // The screen does not show these lines next to HEAD's, so git matches them up from the file on disk.
            guard !isNewSinceHead(request.path, in: project), viewer.saveEdits() else {
                if isNewSinceHead(request.path, in: project) { showToast(notCommitted) }
                return
            }
            let headPath = project.changes.first { $0.path == request.path }?.oldPath ?? request.path
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let lines = await Git.headLines(of: request.path, headPath: headPath, lines: selected.range, in: project.url) else {
                    self.showToast(notCommitted)
                    return
                }
                let filter = HistoryFilter(path: headPath, lines: (lines.lowerBound + 1)...(lines.upperBound + 1))
                self.presentSelectionHistory(project: project, filter: filter, displayPath: displayPath, displayLines: displayLines)
            }
            return
        }
        guard let filter = historyFilter(for: request, lines: selected, in: project) else {
            showToast(notCommitted)
            return
        }
        presentSelectionHistory(project: project, filter: filter, displayPath: displayPath, displayLines: displayLines)
    }

    func presentSelectionHistory(project: Project, filter: HistoryFilter, displayPath: String, displayLines: ClosedRange<Int>) {
        selectionHistory.prepare(project: project, filter: filter, displayPath: displayPath, displayLines: displayLines)
        present(.selectionHistory)
    }

    /// Resolves the 0-based line range for Selection History from either an active selection/caret or Vim cursor.
    private func selectedLinesForHistory(in canvas: CodeCanvasView) -> (side: Side, range: ClosedRange<Int>)? {
        if let selected = canvas.selectedLines() {
            return selected
        }
        if canvas.vimModeEnabled,
           let doc = canvas.document,
           case .text = doc.content,
           !doc.right.lines.isEmpty {
            let line = max(0, min(canvas.vimCursor.row, doc.right.lines.count - 1))
            return (.right, line...line)
        }
        return nil
    }

    /// Lines of the working tree that the screen does not show next to HEAD's: in a plain file, or in the working
    /// tree compared with another commit. Their history is counted from HEAD all the same, so that it lists the
    /// commits after that one too.
    func countsInHead(_ request: DiffRequest, side: Side) -> Bool {
        switch request.source {
        case .file: return true
        case .externalFile: return false
        case .worktree: return side == .right && !request.isAgainstHead
        case .commit, .commitSteps: return false
        }
    }

    /// A file HEAD does not have.
    func isNewSinceHead(_ path: String, in project: Project) -> Bool {
        guard let local = project.changes.first(where: { $0.path == path }) else { return false }
        return local.kind == .untracked || local.kind == .added
    }

    /// Whether the selected lines may have a history, without asking git.
    func selectionMayHaveHistory(_ request: DiffRequest, _ lines: (side: Side, range: ClosedRange<Int>), in project: Project) -> Bool {
        countsInHead(request, side: lines.side) ? !isNewSinceHead(request.path, in: project)
                                                 : historyFilter(for: request, lines: lines, in: project) != nil
    }

    /// The history of a file in the project, by its path in the working tree.
    func showHistory(path: String, in project: Project) {
        if let change = project.changes.first(where: { $0.path == path }), change.kind == .untracked || change.kind == .added {
            showToast(L("Not committed yet · no history", "这个文件还没有提交过 · 没有历史"))
            return
        }
        let local = project.changes.first { $0.path == path }
        showHistory(HistoryFilter(path: local?.oldPath ?? path), in: project)
    }

    /// What to list for the history of the file a document shows, or of some of its lines (0-based, on one side).
    /// Nil when there is nothing committed to list, and for lines that `countsInHead`, which need git to match up.
    func historyFilter(for request: DiffRequest, lines: (side: Side, range: ClosedRange<Int>)?, in project: Project) -> HistoryFilter? {
        func oneBased(_ range: ClosedRange<Int>) -> ClosedRange<Int> { (range.lowerBound + 1)...(range.upperBound + 1) }
        switch request.source {
        case .externalFile:
            return nil
        case .file, .worktree:
            if isNewSinceHead(request.path, in: project) || (request.kind == .untracked && !project.changes.contains { $0.path == request.path }) {
                return nil
            }
            let headPath = project.changes.first { $0.path == request.path }?.oldPath ?? request.path
            guard let lines else {
                // The whole file: its history up to HEAD, under the name HEAD knows it by.
                return HistoryFilter(path: headPath)
            }
            guard case .worktree(let base) = request.source, base != Git.emptyTree else { return nil }
            if lines.side == .left {
                // Lines of the version compared with, where their history starts.
                return HistoryFilter(path: request.oldPath ?? request.path, lines: oneBased(lines.range), rev: base)
            }
            guard request.isAgainstHead, let doc = viewer.document, let mapped = doc.leftLines(forRight: lines.range) else { return nil }
            return HistoryFilter(path: headPath, lines: oneBased(mapped), rev: "HEAD")
        case .commit(let hash, let parent):
            guard let lines else {
                if request.kind == .deleted {
                    return parent.map { HistoryFilter(path: request.oldPath ?? request.path, rev: $0) }
                }
                // From HEAD while the file is still there under that name, which shows what came after too.
                let exists = FileManager.default.fileExists(atPath: project.url.appendingPathComponent(request.path).path)
                return HistoryFilter(path: request.path, rev: exists ? "HEAD" : hash)
            }
            if lines.side == .left {
                guard let parent else { return nil }
                return HistoryFilter(path: request.oldPath ?? request.path, lines: oneBased(lines.range), rev: parent)
            }
            return HistoryFilter(path: request.path, lines: oneBased(lines.range), rev: hash)
        case .commitSteps(let steps):
            guard let newest = steps.last, let oldest = steps.first else { return nil }
            guard let lines else {
                if request.kind == .deleted {
                    return oldest.parent.map { HistoryFilter(path: request.oldPath ?? request.path, rev: $0) }
                }
                let exists = FileManager.default.fileExists(atPath: project.url.appendingPathComponent(request.path).path)
                return HistoryFilter(path: request.path, rev: exists ? "HEAD" : newest.hash)
            }
            if viewer.document?.isSyntheticReplay == true { return nil }
            if lines.side == .left {
                guard let parent = oldest.parent else { return nil }
                return HistoryFilter(path: request.oldPath ?? request.path, lines: oneBased(lines.range), rev: parent)
            }
            return HistoryFilter(path: request.path, lines: oneBased(lines.range), rev: newest.hash)
        }
    }

    /// A line's commit was clicked in the Annotate column: the file's history, with that commit picked.
    func openAnnotation(_ entry: LineAnnotations.Entry) {
        guard let project = currentProject, let request = viewer.request, request.root == project.url else { return }
        let filter = historyFilter(for: request, lines: nil, in: project) ?? HistoryFilter(path: request.path)
        showHistory(filter, in: project, select: entry.hash)
    }

    // MARK: Comparison

    /// The Changes tab lists everything that differs between `target` and the working tree, committed or not.
    /// - Parameters:
    ///   - target: a full ref name or a commit hash.
    ///   - forkPoint: compare with where HEAD and `target` forked (for a branch), rather than with `target` itself.
    func compare(with target: String, title: String, forkPoint: Bool, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let base = forkPoint ? await Git.mergeBase("HEAD", target, in: project.url) : await Git.resolveCommit(target, in: project.url)
            guard let base else {
                self.showToast(forkPoint ? L("\(title) and HEAD have no commit in common", "\(title) 和 HEAD 没有共同的提交")
                                         : L("No commit named “\(title)”", "找不到“\(title)”这个提交"))
                return
            }
            self.startComparison(Comparison(target: target, title: title, forkPoint: forkPoint, base: base), in: project)
        }
    }

    /// The Changes tab lists what differs between two commits, the older one on the left (as the IDE's Compare Versions).
    func compareCommits(_ older: Commit, _ newer: Commit, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        startComparison(Comparison(target: older.hash, title: older.shortHash, forkPoint: false, base: older.hash,
                                   other: .init(target: newer.hash, title: newer.shortHash, hash: newer.hash)), in: project)
    }

    /// Shows `comparison` in the project's Changes tab, from the top.
    func startComparison(_ comparison: Comparison, in project: Project) {
        exitExternalFileMode()
        if popup == .gitGraph || popup == .quickOpen { dismissPopup(restoreFocus: false) }
        if selectedProjectID != project.id { select(project) }
        project.comparison = comparison
        project.compareChanges = []
        project.compareSelectedID = nil
        project.compareCollapsed = []
        project.compareError = nil
        project.browsedPath = nil
        project.tab = .changes
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        project.loadComparison()
        focusList()
    }

    /// The two commits picked together in a list, older first (lists run newest first), or nil unless exactly two are.
    func pickedPair(_ ids: Set<String>, in list: [Commit]) -> (older: Commit, newer: Commit)? {
        guard ids.count == 2 else { return nil }
        let picked = list.enumerated().filter { ids.contains($0.element.hash) }
        guard picked.count == 2 else { return nil }
        return (picked[1].element, picked[0].element)
    }

    /// Back to the local changes.
    func endComparison(in project: Project? = nil, sync: Bool = true) {
        exitExternalFileMode()
        guard let project = project ?? currentProject, project.comparison != nil else { return }
        project.comparison = nil
        project.compareChanges = []
        project.compareSelectedID = nil
        project.compareError = nil
        project.loadComparison()
        if sync { syncViewer() }
    }

    /// Picks a branch or tag (or types a commit) to compare the working tree with.
    func showComparePicker() {
        guard currentProject != nil else { return }
        showQuickOpen(.branches)
    }

    func compareSelectionChanged(_ project: Project) {
        guard project.id == selectedProjectID, project.tab == .changes, let comparison = project.comparison,
              let id = project.compareSelectedID,
              let change = project.compareChanges.first(where: { ChangeRow.fileID($0.path) == id }) else { return }
        exitExternalFileMode()
        project.browsedPath = nil
        showCompared(change, with: comparison, in: project)
        noteRecent(project, change.path)
    }

    func showCompared(_ change: FileChange, with comparison: Comparison, in project: Project) {
        let request = resolvedRequest(project.request(compared: change, with: comparison, ignoreWhitespace: settings.ignoreWhitespace))
        if request == viewer.request {
            viewer.reloadIfStale(base: comparison.base)
        } else {
            let sameDiff = viewer.request?.path == request.path && viewer.request?.root == request.root && viewer.request?.source != .file
            viewer.open(request, preserveScroll: sameDiff)
        }
    }

    /// The comparison list's part of `syncViewer`.
    func syncComparison(_ project: Project, _ comparison: Comparison) {
        if let id = project.compareSelectedID {
            if !id.hasPrefix("f:") { return } // a folder or group row; leave the viewer alone
            if let change = project.compareChanges.first(where: { ChangeRow.fileID($0.path) == id }) {
                showCompared(change, with: comparison, in: project)
                return
            }
            if viewer.isEditing(root: project.url, path: String(id.dropFirst(2))) {
                viewer.reloadIfStale(base: comparison.base)
                return
            }
        }
        let ordered = ChangeTree.orderedFiles(changes: project.compareChanges, flat: settings.flatList,
                                              filter: project.filter, splitUnversioned: true)
        if let first = ordered.first {
            project.compareSelectedID = ChangeRow.fileID(first.path)
            showCompared(first, with: comparison, in: project)
        } else if !project.isLoadingCompare {
            project.compareSelectedID = nil
            viewer.clear()
        }
    }

    // MARK: Menus

    /// A commit's right-click menu in the Log.
    func logCommitMenu(_ commit: Commit, in project: Project) -> NSMenu {
        let menu = NSMenu()
        if project.selectedCommitIDs.contains(commit.hash), let pair = pickedPair(project.selectedCommitIDs, in: project.commits) {
            menu.addItem(ClosureMenuItem(L("Compare \(pair.older.shortHash) with \(pair.newer.shortHash)",
                                           "比较 \(pair.older.shortHash) 与 \(pair.newer.shortHash)")) { [weak self] in
                self?.compareCommits(pair.older, pair.newer, in: project)
            })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("Compare with Working Tree", "与工作区比较")) { [weak self] in
            self?.compare(with: commit.hash, title: commit.shortHash, forkPoint: false, in: project)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("New Branch Here…", "在此新建分支…")) { [weak self] in
            self?.newBranch(from: commit.hash, startTitle: commit.shortHash, in: project)
        })
        menu.addItem(ClosureMenuItem(L("Checkout Revision…", "检出此版本…")) { [weak self] in
            self?.checkoutRevision(commit.hash, title: commit.shortHash, in: project)
        })
        menu.addItem(.separator())
        addHistoryEditItems(to: menu, commit: commit, commits: menuCommits(commit, picked: project.selectedCommitIDs, in: project.commits),
                            list: project.commits, project: project)
        menu.addItem(.separator())
        let author = AuthorFilter.from(commit)
        if project.logAuthors.contains(author) {
            menu.addItem(ClosureMenuItem(L("Remove Author “\(author.displayName)” from Filter", "从筛选中移除作者“\(author.displayName)”")) { [weak project] in
                project?.removeLogAuthor(author)
            })
        } else {
            let title = project.logAuthors.isEmpty
                ? L("Filter by Author “\(author.displayName)”", "按作者“\(author.displayName)”筛选")
                : L("Add Author “\(author.displayName)” to Filter", "将作者“\(author.displayName)”加入筛选")
            menu.addItem(ClosureMenuItem(title) { [weak project] in
                project?.toggleLogAuthor(author)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Copy Hash", "复制哈希")) { [weak self] in self?.copyText(commit.hash) })
        menu.addItem(ClosureMenuItem(L("Copy Message", "复制提交信息")) { [weak self] in self?.copyText(commit.subject) })
        return menu
    }

    /// A file's right-click menu in a commit's or commit range's file list.
    func commitFileMenu(_ change: FileChange, in commits: [Commit], project: Project) -> NSMenu {
        let menu = NSMenu()
        if let request = project.request(for: change, in: commits, ignoreWhitespace: settings.ignoreWhitespace) {
            let history = ClosureMenuItem(L("Show History", "查看历史")) { [weak self] in
                guard let self, let filter = self.historyFilter(for: request, lines: nil, in: project) else { return }
                self.showHistory(filter, in: project)
            }
            history.isEnabled = historyFilter(for: request, lines: nil, in: project) != nil
            menu.addItem(history)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) { [weak self] in self?.copyText(change.path) })
        return menu
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(L("Copied", "已复制"))
    }

    /// History, Annotate and comparison items for the viewer's right-click menu.
    func addHistoryItems(to menu: NSMenu, project: Project) {
        guard let request = viewer.request, request.root == project.url else { return }
        let annotate = ClosureMenuItem(L("Annotate with Git Blame", "逐行追溯 (Blame)")) { [weak self] in self?.viewer.toggleAnnotate() }
        annotate.state = viewer.annotating ? .on : .off
        annotate.isEnabled = viewer.annotating || viewer.canAnnotate
        menu.addItem(annotate)
        let file = ClosureMenuItem(L("Show History", "查看历史")) { [weak self] in self?.showHistoryForCurrentFile() }
        file.isEnabled = historyFilter(for: request, lines: nil, in: project) != nil
        menu.addItem(file)
        if let canvas = viewer.container?.canvas, let lines = selectedLinesForHistory(in: canvas) {
            let selection = ClosureMenuItem(L("Show History for Selection", "查看所选内容的历史")) { [weak self] in
                self?.showHistoryForSelection()
            }
            selection.isEnabled = selectionMayHaveHistory(request, lines, in: project)
            menu.addItem(selection)
        }
        menu.addItem(.separator())
    }
}

extension DiffDocument {
    /// The lines of the left side that `lines` of the right side stand for (0-based). Nil when all of them are new.
    func leftLines(forRight lines: ClosedRange<Int>) -> ClosedRange<Int>? {
        Hunk.oldLines(forNew: lines, in: hunks, oldCount: left.lines.count)
    }
}
