import AppKit
import SwiftUI

/// Committing from the bottom of the Changes list, and taking the last commit back.
extension AppStore {
    /// ⌘K, the IDE's Commit: puts the keyboard in the commit message. In a terminal it clears the screen instead,
    /// as ⌘K does in every Mac terminal.
    func commitShortcut() {
        if terminals.focusedID != nil {
            terminals.clearFocused()
        } else {
            focusCommitMessage()
        }
    }

    func focusCommitMessage() {
        guard let project = currentProject else { return }
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        if project.tab != .changes {
            // Not through setTab: that hands the keyboard to the list, and the message would lose the race.
            project.tab = .changes
            project.browsedPath = nil
            syncViewer()
        }
        guard !project.changes.isEmpty || project.amend else {
            showToast(L("Nothing to commit", "没有可提交的改动"))
            return
        }
        commitFocusRequestedAt = CACurrentMediaTime()
        commitFocusToken += 1
    }

    /// The Amend box under the commit message: the next commit replaces the last one, and its message fills the box
    /// (what was typed there comes back when Amend goes off again, if the message was left as it was).
    func setAmend(_ on: Bool, in project: Project? = nil) {
        guard let project = project ?? currentProject, on != project.amend else { return }
        guard on else {
            project.amend = false
            project.amendPushedTo = []
            if let draft = project.amendDraft, project.commitMessage == draft.filled { project.commitMessage = draft.before }
            project.amendDraft = nil
            return
        }
        if let operation = project.status.operation {
            showToast(L("A \(operation.command) is in progress · finish it first", "正在进行 \(operation.command) · 请先完成它"))
            return
        }
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            guard let head = try? await Git.head(in: project.url) else {
                self.showToast(L("There is no commit to amend yet", "还没有可以修改的提交"))
                return
            }
            let message = await Git.commitBody(head, in: project.url)
            let pushed = await Git.remoteBranches(containing: head, in: project.url)
            guard !project.amend else { return }
            project.amend = true
            project.amendPushedTo = pushed
            project.amendDraft = (project.commitMessage, message)
            project.commitMessage = message
            if project.id == self.selectedProjectID { self.focusCommitMessage() }
        }
    }

    func toggleAmend() {
        guard let project = currentProject else { return }
        setAmend(!project.amend, in: project)
    }

    /// Commits the ticked files with the message typed below the list.
    /// - Parameter thenPush: Commit and Push: the push dialog follows a commit that went through.
    func commitCurrent(thenPush: Bool = false) {
        guard let project = currentProject, !project.isCommitting else { return }
        if let operation = project.status.operation {
            guard operation == .merge else {
                showToast(L("A \(operation.command) is in progress · Continue it above the list", "正在进行 \(operation.command) · 请用列表上方的“继续”"))
                return
            }
            guard project.status.conflictCount == 0 else {
                showToast(L("Resolve the conflicts first", "请先解决冲突"))
                return
            }
            commitMerge(in: project, thenPush: thenPush)
            return
        }
        let message = project.commitMessage
        let targets = project.includedChanges
        let amend = project.amend
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(L("Write a commit message first", "先写提交说明"))
            focusCommitMessage()
            return
        }
        guard !targets.isEmpty || amend else {
            showToast(L("Tick the files to commit", "先勾选要提交的文件"))
            return
        }
        // What was just typed is part of what gets committed.
        guard viewer.saveEdits() else { return }
        // Files with lines left out go in part; the rest as they are.
        let partial = targets.compactMap { change in
            project.excludedLines[change.path].flatMap { $0.isEmpty ? nil : WorkingTree.PartialFile(change: change, excluded: $0) }
        }
        let whole = targets.filter { project.excludedLines[$0.path]?.isEmpty != false }
        project.isCommitting = true
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer { project.isCommitting = false }
            do {
                let result = partial.isEmpty
                    ? try await WorkingTree.commit(message: message, changes: targets, amend: amend, in: project.url)
                    : try await WorkingTree.commit(message: message, whole: whole, partial: partial, amend: amend, in: project.url)
                project.lastCommit = result
                let wasAmendPushed = amend && !project.amendPushedTo.isEmpty
                let draft = project.amendDraft
                if amend {
                    project.amend = false
                    project.amendPushedTo = []
                    project.amendDraft = nil
                }
                // What stays out of a file was picked against the old HEAD; what is left of it is a change like any other.
                let committed = Set(targets.map(\.path))
                if project.excludedLines.keys.contains(where: committed.contains) {
                    project.excludedLines = project.excludedLines.filter { !committed.contains($0.key) }
                }
                // Only if nobody started a new message while git was at work. After an amend, what was being
                // written before comes back.
                if project.commitMessage == message { project.commitMessage = amend ? (draft?.before ?? "") : "" }
                if !targets.isEmpty {
                    self.updateAIGroupsAfterExternalCommit(
                        committedPaths: committed,
                        in: project,
                        newHeadOID: result.hash
                    )
                }
                self.afterHistoryChanged(project)
                let files = result.fileCount == 1 ? L("1 file", "1 个文件") : L("\(result.fileCount) files", "\(result.fileCount) 个文件")
                let part = partial.isEmpty ? "" : L(", \(partial.count) in part", "（\(partial.count) 个部分提交）")
                if let amended = result.amended {
                    let added = result.fileCount == 0 ? "" : L(" with \(files)\(part)", "，加入 \(files)\(part)")
                    self.showToast(L("Amended \(amended.prefix(7))\(added) · now \(result.shortHash)", "已修改 \(amended.prefix(7))\(added) · 现为 \(result.shortHash)"),
                                   action: ToastAction(title: L("Undo Amend", "撤销修改")) { [weak self] in self?.undoLastCommit() })
                } else {
                    self.showToast(L("Committed \(files)\(part) · \(result.shortHash)", "已提交 \(files)\(part) · \(result.shortHash)"),
                                   action: ToastAction(title: L("Undo Commit", "撤销提交")) { [weak self] in self?.undoLastCommit() })
                }
                if thenPush { self.push(in: project, autoReconcile: !wasAmendPushed) }
            } catch {
                project.refresh()
                self.showFailure(L("Commit failed", "提交失败"), error, note: self.sandboxNote(for: error))
            }
        }
    }

    /// The commit that finishes a merge: the merge's staged result plus the ticked files, with the message in the box
    /// (git's prepared one, unless the user rewrote it).
    private func commitMerge(in project: Project, thenPush: Bool) {
        let message = project.commitMessage
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showToast(L("Write a commit message first", "先写提交说明"))
            focusCommitMessage()
            return
        }
        guard viewer.saveEdits() else { return }
        let targets = project.includedChanges
        project.isCommitting = true
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer { project.isCommitting = false }
            do {
                let result = try await WorkingTree.commitMerge(message: message, adding: targets, in: project.url)
                project.pendingPushAfterPull = nil
                // Undoing a merge commit would not bring the merge back, only its changes: not offered.
                project.lastCommit = nil
                // Lines picked before the merge were picked against the old HEAD.
                if !project.excludedLines.isEmpty { project.excludedLines = [:] }
                if project.commitMessage == message { project.commitMessage = "" }
                if project.aiGroupResult != nil {
                    self.clearAIGroups(for: project)
                }
                let clashes = await Git.conflictedPaths(in: project.url)
                if !clashes.isEmpty {
                    await project.refreshAndWait()
                    self.afterHistoryChanged(project)
                    if thenPush, let branch = project.status.branch, let upstream = project.status.upstream {
                        project.pendingPushAfterPull = Project.PendingPushAfterPull(branch: branch, target: upstream, remote: nil)
                    }
                    self.handleConflictsDetected(
                        in: project,
                        title: L("Merge committed · your local changes clash with what came in", "合并已提交 · 本地改动与合并后的内容冲突"),
                        note: L("Your changes also stay in git's stash until you drop it.", "你的改动也仍保存在 git 的 stash 里，直到你删除它。")
                    )
                    return
                }
                self.afterHistoryChanged(project)
                self.showToast(L("Merge committed · \(result.shortHash)", "合并已提交 · \(result.shortHash)"))
                if thenPush { self.push(in: project, autoReconcile: true) }
            } catch {
                project.refresh()
                self.showFailure(L("Commit failed", "提交失败"), error, note: self.sandboxNote(for: error))
            }
        }
    }

    var canUndoCommit: Bool { currentProject?.lastCommit != nil }

    /// Moves the branch back past the commit made here; its changes come back, staged, and so does its message.
    func undoLastCommit() {
        guard let project = currentProject, let result = project.lastCommit else {
            showToast(L("No commit made here to undo", "没有可撤销的提交"))
            return
        }
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            do {
                try await WorkingTree.undoCommit(result, in: project.url)
                project.lastCommit = nil
                if project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    project.commitMessage = result.message
                }
                self.afterHistoryChanged(project)
                if let amended = result.amended {
                    self.showToast(L("Amend undone · \(amended.prefix(7)) is back; what it added is staged", "已撤销修改 · \(amended.prefix(7)) 已恢复，新加入的改动在暂存区"))
                } else {
                    self.showToast(L("Commit undone · the changes are back in the list", "已撤销提交 · 改动已放回列表"))
                }
            } catch {
                project.lastCommit = nil
                self.showFailure(L("Could not undo the commit", "无法撤销提交"), error)
            }
        }
    }

    private func afterHistoryChanged(_ project: Project) {
        project.invalidateFiles()
        project.logStale = true
        project.refresh()
        if project.tab == .log { project.loadLog(reset: true) }
    }

    /// Space in the Changes list: ticks or unticks the selected files, all the same way.
    func toggleIncludedSelection(in project: Project) {
        let targets = selectedChanges(in: project)
        guard !targets.isEmpty else { return }
        project.setIncluded(!targets.allSatisfy { project.inclusion($0) == .on }, targets)
    }

    /// Generates a commit message for the project's currently checked changes using the configured local AI agent.
    /// Calling again while generation is in progress cancels the running request.
    func generateCommitMessage(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        if project.isGeneratingCommitMessage {
            cancelCommitMessageGeneration(in: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AICommitError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommitting else { return }
        guard !project.includedChanges.isEmpty else {
            showToast(AICommitError.noCheckedChanges.localizedDescription)
            return
        }
        // Save any unsaved inline edits so the diff reflects what will actually be committed.
        guard viewer.saveEdits() else { return }

        let format = settings.effectiveCommitMessageFormat
        let provider = settings.aiProvider(for: .commit)
        let model = settings.aiModel(for: provider, task: .commit)
        let repoRoot = project.url
        let token = project.beginCommitMessageGeneration()
        project.commitMessageGenerationTask = Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer {
                project.finishCommitMessageGeneration(token: token)
            }
            do {
                let payload = try await AICommitGenerator.collectCheckedDiff(for: project)
                try Task.checkCancellation()
                let generated = try await AICommitGenerator.generate(
                    from: payload,
                    format: format,
                    provider: provider,
                    model: model,
                    workingDirectory: repoRoot
                )
                try Task.checkCancellation()
                guard project.commitMessageGenerationID == token else { return }
                project.commitMessage = generated
                if project.id == self.selectedProjectID {
                    self.focusCommitMessage()
                }
                self.showToast(L("Commit message generated", "已生成提交信息"))
            } catch is CancellationError {
                // Cancelled by user or project switch; preserve any existing draft silently.
            } catch {
                guard project.commitMessageGenerationID == token else { return }
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// Cancels any active AI commit message generation for `project`, terminating the underlying agent process.
    func cancelCommitMessageGeneration(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        project.cancelCommitMessageGeneration()
    }
}
