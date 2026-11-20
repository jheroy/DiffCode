import AppKit
import SwiftUI

/// A button offered next to a toast, e.g. "Undo".
struct ToastAction {
    var title: String
    var handler: () -> Void
}

/// One rollback or delete that can still be taken back.
struct UndoItem {
    var record: WorkingTree.Record
    var projectID: UUID
    /// What it was, for the toast: "Rolled back 3 files".
    var summary: String
}

/// The few edits Dif makes itself: rolling changes back, moving new files to the Trash, and undoing either.
extension AppStore {
    static let undoLimit = 20

    nonisolated static func canRollback(_ change: FileChange) -> Bool { change.kind != .untracked && !change.isSubmodule }
    nonisolated static func canDelete(_ change: FileChange) -> Bool { change.kind == .untracked || change.kind == .added }

    // MARK: What a command applies to

    /// The changes the list shows, i.e. with its filter applied.
    func visibleChanges(in project: Project) -> [FileChange] {
        let needle = project.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty ? project.changes : project.changes.filter { $0.path.lowercased().contains(needle) }
    }

    /// Every file selected in the Changes list; a selected folder or group stands for the files under it.
    func selectedChanges(in project: Project) -> [FileChange] {
        var ids = project.selectedChangeIDs
        if let primary = project.selectedChangeID { ids.insert(primary) }
        return ChangeTree.files(for: ids, in: visibleChanges(in: project))
    }

    /// What a row's context menu acts on: the whole selection when the row is part of it, otherwise just that row.
    func editTargets(for row: ChangeRow, in project: Project) -> [FileChange] {
        if project.selectedChangeIDs.count > 1, project.selectedChangeIDs.contains(row.id) {
            return selectedChanges(in: project)
        }
        return ChangeTree.files(for: [row.id], in: visibleChanges(in: project))
    }

    /// The local change the viewer is showing, if that is what it shows.
    func viewerChange(in project: Project) -> FileChange? {
        guard let request = viewer.request, request.root == project.url, request.isAgainstHead else { return nil }
        return project.changes.first { $0.path == request.path }
    }

    private var terminalHasFocus: Bool { terminals.focusedID != nil }

    /// The files a keyboard command should act on, going by where the keyboard is.
    private func contextChanges(in project: Project) -> [FileChange] {
        if let canvas = viewer.container?.canvas, window?.firstResponder === canvas {
            return viewerChange(in: project).map { [$0] } ?? []
        }
        if focusedListName == KeyboardListName.tree {
            guard let id = project.treeSelectedID, id.hasPrefix("f:") else { return [] }
            let path = String(id.dropFirst(2))
            return project.changes.filter { $0.path == path }
        }
        // While comparing with another commit, browsing AI groups, or viewing history, list-level rollback/delete is disabled.
        return project.tab == .changes && project.comparison == nil ? selectedChanges(in: project) : []
    }

    // MARK: Commands

    /// ⌥⌘Z, as in the IDE: in the diff it rolls back the change under the highlight, elsewhere the selected files.
    func rollbackInContext() {
        guard let project = currentProject, !terminalHasFocus else { return }
        if let canvas = viewer.container?.canvas, window?.firstResponder === canvas,
           viewer.canRevertHunks, let hunk = viewer.focusedHunk {
            rollbackHunk(hunk)
            return
        }
        let targets = contextChanges(in: project).filter(Self.canRollback)
        if targets.isEmpty {
            showToast(L("Select changed files to roll back", "先选中要回滚的变更文件"))
        } else {
            rollback(targets, in: project)
        }
    }

    /// ⌫ in the Changes list or the tree.
    func deleteInContext() {
        guard let project = currentProject, !terminalHasFocus else { return }
        let selected = contextChanges(in: project)
        let targets = selected.filter(Self.canDelete)
        if targets.isEmpty {
            showToast(selected.isEmpty
                ? L("Select new files to delete", "先选中要删除的新文件")
                : L("Only new files can be deleted here · ⌥⌘Z rolls changes back", "这里只能删除新增的文件 · 修改请用 ⌥⌘Z 回滚"))
        } else {
            delete(targets, in: project)
        }
    }

    func rollbackCurrentHunk() {
        guard viewer.canRevertHunks, let hunk = viewer.focusedHunk else {
            showToast(L("No change is highlighted in the diff", "diff 里没有选中的变更"))
            return
        }
        rollbackHunk(hunk)
    }

    // MARK: Rollback

    func rollback(_ changes: [FileChange], in project: Project, confirm: Bool = true) {
        let targets = changes.filter(Self.canRollback)
        guard !targets.isEmpty else { return }
        let run = { [weak self] in
            guard let self else { return }
            // Typing not yet written goes to the file first, so the backup ⌘Z restores from has it.
            guard self.viewer.saveEdits() else { return }
            self.moveSelection(awayFrom: targets.filter { $0.kind != .added }, in: project)
            self.perform(in: project, failure: L("Rollback failed", "回滚失败")) {
                let (record, failure) = try await WorkingTree.rollback(targets, in: project.url)
                let summary = targets.count == 1
                    ? L("Rolled back \(targets[0].name)", "已回滚 \(targets[0].name)")
                    : L("Rolled back \(targets.count) files", "已回滚 \(targets.count) 个文件")
                return Outcome(record: record, summary: summary, failure: failure)
            }
        }
        guard confirm else {
            run()
            return
        }
        var message = targets.count == 1
            ? L("Its local changes will be discarded. ⌘Z brings them back.", "本地修改会被丢弃，可以用 ⌘Z 撤销。")
            : L("Their local changes will be discarded. ⌘Z brings them back.", "这些文件的本地修改会被丢弃，可以用 ⌘Z 撤销。")
        if targets.contains(where: { $0.kind == .added }) {
            message += " " + L("Newly added files stay on disk, unversioned.", "新增的文件会保留在磁盘上，变为未跟踪。")
        }
        let (items, hidden) = DialogRequest.files(targets)
        ask(DialogRequest(style: .destructive, symbol: "arrow.uturn.backward",
                          title: targets.count == 1
                              ? L("Roll back “\(targets[0].name)”?", "回滚“\(targets[0].name)”？")
                              : L("Roll back \(targets.count) files?", "回滚 \(targets.count) 个文件？"),
                          message: message, items: items, hiddenCount: hidden,
                          confirmTitle: L("Roll Back", "回滚"), onConfirm: run))
    }

    /// Puts one change of the diff on screen back the way the left side has it. No question asked: ⌘Z undoes it.
    func rollbackHunk(_ index: Int) {
        guard let project = currentProject, let request = viewer.request, request.root == project.url,
              viewer.canRevertHunks, let document = viewer.document, document.hunks.indices.contains(index),
              !isApplyingEdit else { return }
        let name = (request.path as NSString).lastPathComponent
        if viewer.canEdit {
            // In the text being edited: an edit like any other, written at once, and ⌘Z in the diff takes it back.
            guard viewer.revertHunkInEditor(index) else { return }
            if viewer.textMatchesBase, request.oldPath == nil, case .worktree(let base) = request.source, base == "HEAD" {
                // With the last change gone the file is HEAD's again; drop anything still staged for it, so it leaves the list.
                Task { @MainActor [weak project] in
                    try? await WorkingTree.git(["checkout", "HEAD"], paths: [request.path], in: request.root)
                    project?.refresh()
                }
            } else {
                project.refresh()
            }
            viewer.focusCanvas()
            showToast(L("Rolled back a change in \(name)", "已回滚 \(name) 里的一处变更"),
                      action: ToastAction(title: L("Undo", "撤销")) { [weak self] in self?.viewer.undoInEditor() })
            return
        }
        let hunk = document.hunks[index]
        isApplyingEdit = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isApplyingEdit = false }
            do {
                let result = try await WorkingTree.revertHunk(request: request, hunk: hunk,
                                                              expectedLeft: document.left.lines, expectedRight: document.right.lines)
                switch result {
                case .reverted(let record):
                    self.pushUndo(UndoItem(record: record, projectID: project.id,
                                           summary: L("Rolled back a change in \((request.path as NSString).lastPathComponent)",
                                                      "已回滚 \((request.path as NSString).lastPathComponent) 里的一处变更")))
                    self.viewer.reload()
                    project.refresh()
                    self.showUndoToast()
                case .stale:
                    self.viewer.reload()
                    self.showToast(L("The file changed on disk · reloaded, nothing rolled back", "文件已在磁盘上变化 · 已重新加载，未做回滚"))
                }
            } catch {
                self.showFailure(L("Rollback failed", "回滚失败"), error)
            }
        }
    }

    // MARK: Delete

    func delete(_ changes: [FileChange], in project: Project, confirm: Bool = true) {
        let targets = changes.filter(Self.canDelete)
        guard !targets.isEmpty else { return }
        let run = { [weak self] in
            guard let self else { return }
            guard self.viewer.saveEdits() else { return }
            self.moveSelection(awayFrom: targets, in: project)
            self.perform(in: project, failure: L("Could not delete", "删除失败")) {
                let (record, failed) = try await WorkingTree.trash(targets, in: project.url)
                if record.entries.isEmpty, let first = failed.first {
                    throw WorkingTree.Failure(message: L("“\(first)” could not be moved to the Trash.", "“\(first)”无法移到废纸篓。"))
                }
                let moved = record.entries.count
                var summary = moved == 1
                    ? L("Moved \((record.entries[0].path as NSString).lastPathComponent) to the Trash",
                        "已把 \((record.entries[0].path as NSString).lastPathComponent) 移到废纸篓")
                    : L("Moved \(moved) files to the Trash", "已把 \(moved) 个文件移到废纸篓")
                if !failed.isEmpty { summary += L(" · \(failed.count) could not be moved", " · \(failed.count) 个未能移动") }
                return Outcome(record: record, summary: summary, failure: nil)
            }
        }
        guard confirm else {
            run()
            return
        }
        let (items, hidden) = DialogRequest.files(targets)
        ask(DialogRequest(style: .destructive, symbol: "trash",
                          title: targets.count == 1
                              ? L("Move “\(targets[0].name)” to the Trash?", "把“\(targets[0].name)”移到废纸篓？")
                              : L("Move \(targets.count) files to the Trash?", "把 \(targets.count) 个文件移到废纸篓？"),
                          message: L("New files only. They can be taken out of the Trash, or brought back with ⌘Z.",
                                     "只会移动新增的文件。可以从废纸篓里找回，也可以用 ⌘Z 撤销。"),
                          items: items, hiddenCount: hidden,
                          confirmTitle: L("Move to Trash", "移到废纸篓"), onConfirm: run))
    }

    // MARK: Undo

    var canUndoEdit: Bool { !undoStack.isEmpty && !isApplyingEdit }

    /// What ⌘Z would take back, for the menu.
    var undoEditTitle: String? { undoStack.last?.summary }

    func undoEdit() {
        guard !isApplyingEdit, !undoStack.isEmpty else {
            showToast(L("Nothing to undo", "没有可撤销的操作"))
            return
        }
        // The undo puts files back only if nothing changed them since; typing on screen counts once written.
        guard viewer.saveEdits(), let item = undoStack.popLast() else { return }
        isApplyingEdit = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await WorkingTree.undo(item.record)
            // An earlier operation on the same file expects to find what it left behind; it is back, with a new timestamp.
            for (path, stamp) in result.restored {
                guard let index = self.undoStack.lastIndex(where: { other in
                    other.record.root == item.record.root && other.record.entries.contains { $0.path == path }
                }) else { continue }
                for entry in self.undoStack[index].record.entries.indices where self.undoStack[index].record.entries[entry].path == path {
                    self.undoStack[index].record.entries[entry].after = stamp
                }
            }
            item.record.discard()
            self.isApplyingEdit = false
            if let project = self.project(item.projectID) {
                project.invalidateFiles()
                project.refresh()
            }
            self.viewer.reload()
            if result.skipped == 0 {
                self.showToast(L("Undone · \(item.summary)", "已撤销 · \(item.summary)"))
            } else if result.restored.isEmpty {
                self.showToast(L("Not undone: the files have changed since", "未撤销：这些文件之后又被改过"))
            } else {
                self.showToast(L("Undone, except \(result.skipped) files that have changed since",
                                 "已撤销，但有 \(result.skipped) 个文件之后又被改过，保持原样"))
            }
        }
    }

    private func pushUndo(_ item: UndoItem) {
        undoStack.append(item)
        while undoStack.count > Self.undoLimit { undoStack.removeFirst().record.discard() }
    }

    private func showUndoToast() {
        guard let item = undoStack.last else { return }
        showToast(item.summary, action: ToastAction(title: L("Undo", "撤销")) { [weak self] in self?.undoEdit() })
    }

    // MARK: Plumbing

    /// What an operation did. `failure` is set when it stopped part of the way: the record covers the part that was done.
    private struct Outcome {
        var record: WorkingTree.Record
        var summary: String
        var failure: Error?
    }

    /// Runs one operation at a time, then refreshes the project and offers to undo.
    private func perform(in project: Project, failure: String, _ work: @escaping () async throws -> Outcome) {
        guard !isApplyingEdit else { return }
        isApplyingEdit = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isApplyingEdit = false }
            do {
                let outcome = try await work()
                self.pushUndo(UndoItem(record: outcome.record, projectID: project.id, summary: outcome.summary))
                project.invalidateFiles()
                project.refresh()
                if let error = outcome.failure {
                    self.showFailure(failure, error, note: L("Part of it was done. ⌘Z takes that part back.", "有一部分已经完成，按 ⌘Z 可以撤销这一部分。"))
                } else {
                    self.showUndoToast()
                }
            } catch {
                project.refresh()
                self.showFailure(failure, error)
            }
        }
    }


    /// Before files leave the list, move its highlight to the nearest file that stays.
    private func moveSelection(awayFrom leaving: [FileChange], in project: Project) {
        let gone = Set(leaving.map { ChangeRow.fileID($0.path) })
        guard !gone.isEmpty else { return }
        let ordered = ChangeTree.orderedFiles(changes: project.changes, flat: settings.flatList,
                                              filter: project.filter, splitUnversioned: true).map { ChangeRow.fileID($0.path) }
        defer { project.selectedChangeIDs = project.selectedChangeID.map { [$0] } ?? [] }
        guard let current = project.selectedChangeID, gone.contains(current) || !current.hasPrefix("f:"),
              let last = ordered.lastIndex(where: gone.contains) else { return }
        let next = ordered[(last + 1)...].first { !gone.contains($0) } ?? ordered[..<last].last { !gone.contains($0) }
        guard let next, project.browsedPath == nil else { return }
        project.selectedChangeID = next
        if project.id == selectedProjectID, project.tab == .changes { changeSelectionChanged(project) }
    }
}
