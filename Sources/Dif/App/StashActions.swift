import AppKit

/// The stash, as the IDE's Stash Changes and Unstash Changes: put the local changes aside, look at what a stash holds,
/// bring it back (keeping it, or dropping it once applied), or drop it.
extension AppStore {
    /// Stash Changes…: asks for an optional message, and whether new files go too.
    func stashChanges(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        if let operation = project.status.operation {
            showToast(L("Finish or abort the \(operation.command) first", "请先完成或中止当前的 \(operation.command)"))
            return
        }
        let untracked = project.changes.filter { $0.kind == .untracked }.count
        guard !project.changes.isEmpty else {
            showToast(L("No local changes to stash", "没有可暂存的本地改动"))
            return
        }
        guard viewer.saveEdits() else { return }
        let head = project.status.branch ?? project.status.shortHead
        var request = DialogRequest(style: .info, symbol: "tray.and.arrow.down",
                                    title: L("Stash local changes", "Stash 本地改动"),
                                    message: L("They are put aside, and the files go back to how \(head) has them. Bring them back from the stash list (Git ▸ Stashes…).",
                                               "改动会被放到一边，文件回到 \(head) 中的样子。之后可以从 Stash 列表（Git ▸ Stash 列表…）恢复。"),
                                    confirmTitle: L("Stash", "暂存 (Stash)"))
        (request.items, request.hiddenCount) = DialogRequest.files(project.changes, limit: 5)
        request.input = .init(placeholder: L("Message (optional)", "说明（可选）"))
        if untracked > 0 {
            // With nothing else changed, the new files are all there is to stash.
            request.option = .init(title: untracked == 1 ? L("Include 1 new file", "包括 1 个新文件（未跟踪）")
                                                         : L("Include \(untracked) new files", "包括 \(untracked) 个新文件（未跟踪）"),
                                   isOn: untracked == project.changes.count)
        }
        request.onAnswer = { [weak self] answer in
            self?.stash(message: answer.text, includeUntracked: answer.option, in: project)
        }
        ask(request)
    }

    private func stash(message: String, includeUntracked: Bool, in project: Project) {
        guard viewer.saveEdits() else { return }
        runActivity(L("Stashing…", "正在暂存…"), in: project) { [weak self] in
            do {
                let entry = try await Git.stashPush(message: message, includeUntracked: includeUntracked, in: project.url)
                guard let self else { return }
                self.afterStashChanged(project)
                guard let entry else {
                    self.showToast(L("Nothing to stash · only new files changed", "没有可暂存的改动 · 只有新文件"))
                    return
                }
                self.showToast(L("Stashed · \(entry.title)", "已暂存 · \(entry.title)"), action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                    self?.applyStash(entry, drop: true, in: project)
                })
            } catch {
                self?.afterStashChanged(project)
                self?.showFailure(L("Could not stash", "无法暂存"), error)
            }
        }
    }

    /// The stash list, in Quick Open: ↩ shows what a stash holds.
    func showStashes() {
        guard currentProject != nil else { return }
        showQuickOpen(.stashes)
    }

    /// Lists what a stash holds in the Changes tab, against the commit it was made on. The bar over the list applies,
    /// pops or drops it.
    func showStash(_ entry: StashEntry, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        startComparison(Comparison(target: entry.base, title: entry.name, forkPoint: false, base: entry.base,
                                   other: .init(target: entry.hash, title: entry.name, hash: entry.hash), stash: entry), in: project)
    }

    /// Brings a stash's changes back into the working tree; with `drop`, it leaves the list once they are in (Pop).
    func applyStash(_ entry: StashEntry, drop: Bool, in project: Project) {
        if let operation = project.status.operation {
            showToast(L("Finish or abort the \(operation.command) first", "请先完成或中止当前的 \(operation.command)"))
            return
        }
        guard viewer.saveEdits() else { return }
        runActivity(drop ? L("Popping the stash…", "正在弹出 stash…") : L("Applying the stash…", "正在应用 stash…"), in: project) { [weak self] in
            do {
                try await Git.stashApply(entry, drop: drop, in: project.url)
                guard let self else { return }
                self.leaveStash(entry, in: project)
                self.afterStashChanged(project)
                self.showToast(drop ? L("Popped · \(entry.title)", "已弹出 · \(entry.title)")
                                    : L("Applied · \(entry.title) stays in the stash list", "已应用 · \(entry.title) 仍保留在 Stash 列表中"))
            } catch {
                guard let self else { return }
                self.afterStashChanged(project)
                let message = (error as? Git.Failure)?.message ?? ""
                let clashes = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U"], in: project.url)) ?? ""
                if !clashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.leaveStash(entry, in: project)
                    self.handleConflictsDetected(in: project,
                                                 title: L("The stash clashes with your files", "这个 stash 与你的文件有冲突"),
                                                 note: L("The stash stays in the list until you drop it.", "这个 stash 会留在列表里，直到你删除它。"))
                } else if Git.refusedForLocalChanges(message) {
                    self.showFailure(L("Your local changes are in the way", "本地改动挡住了 stash"), error,
                                     note: L("Commit or stash them first, then apply this one.", "请先提交或暂存它们，再应用这个 stash。"))
                } else {
                    self.showFailure(L("Could not apply the stash", "无法应用 stash"), error)
                }
            }
        }
    }

    /// Drops a stash, once confirmed. Undo in the toast lists it again.
    func dropStash(_ entry: StashEntry, in project: Project) {
        var request = DialogRequest(style: .destructive, symbol: "trash",
                                    title: L("Drop “\(entry.title)”?", "删除“\(entry.title)”？"),
                                    message: L("It leaves the stash list, with its changes. Undo in the toast brings it back.",
                                               "它会连同改动一起从 Stash 列表中删除。可以用提示里的“撤销”恢复。"),
                                    confirmTitle: L("Drop", "删除"))
        request.onConfirm = { [weak self] in
            self?.runActivity(L("Dropping the stash…", "正在删除 stash…"), in: project) { [weak self] in
                do {
                    try await Git.stashDrop(entry, in: project.url)
                    guard let self else { return }
                    self.leaveStash(entry, in: project)
                    self.showToast(L("Dropped · \(entry.title)", "已删除 · \(entry.title)"), action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                        self?.restoreStash(entry, in: project)
                    })
                } catch {
                    self?.showFailure(L("Could not drop the stash", "无法删除 stash"), error)
                }
            }
        }
        ask(request)
    }

    private func restoreStash(_ entry: StashEntry, in project: Project) {
        runActivity(L("Restoring the stash…", "正在恢复 stash…"), in: project) { [weak self] in
            do {
                try await Git.stashRestore(entry, in: project.url)
                self?.showToast(L("Restored · \(entry.title)", "已恢复 · \(entry.title)"))
            } catch {
                self?.showFailure(L("Could not restore the stash", "无法恢复 stash"), error)
            }
        }
    }

    /// The list stops showing `entry` (it was applied or dropped): back to the local changes.
    private func leaveStash(_ entry: StashEntry, in project: Project) {
        if project.comparison?.stash?.hash == entry.hash { endComparison(in: project) }
    }

    /// Files came and went: the lists and the tree follow.
    private func afterStashChanged(_ project: Project) {
        project.invalidateFiles()
        project.refresh()
    }
}
