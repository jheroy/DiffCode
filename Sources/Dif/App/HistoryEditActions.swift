import AppKit

/// Rewriting history from the Log and the Git graph, as the IDE's menus do: cherry-pick, revert and reset; merging,
/// rebasing, renaming and deleting branches. Each is git's own command, and the toast after it offers Undo while
/// nothing else has moved.
extension AppStore {
    // MARK: Undo

    /// The toast after the branch moved, with Undo.
    private func announce(_ text: String, undoing move: HeadMove, in project: Project) {
        guard move.before != move.after else { return showToast(text) }
        showToast(text, action: ToastAction(title: L("Undo", "撤销")) { [weak self] in self?.undo(move, in: project) })
    }

    /// Puts the branch back where a cherry-pick, revert, reset, merge or rebase made here found it.
    func undo(_ move: HeadMove, in project: Project) {
        guard viewer.saveEdits() else { return }
        runActivity(L("Undoing…", "正在撤销…"), in: project) { [weak self] in
            do {
                try await Git.undoHeadMove(move, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                let name = move.branch ?? "HEAD"
                self.showToast(L("Undone · \(name) is back at \(move.before.prefix(7))", "已撤销 · \(name) 回到了 \(move.before.prefix(7))"))
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not undo", "无法撤销"), error)
            }
        }
    }

    /// Nothing half done is in the way, and what was typed is saved.
    private func readyToRewrite(_ project: Project) -> Bool {
        if let operation = project.status.operation {
            showToast(L("Finish or abort the \(operation.command) first", "请先完成或中止当前的 \(operation.command)"))
            return false
        }
        if let running = project.activity {
            showToast(L("Wait for “\(running)” to finish", "请等“\(running)”完成"))
            return false
        }
        return viewer.saveEdits()
    }

    /// After a cherry-pick, revert, merge or rebase failed: it stopped at conflicts (and waits in the banner), local
    /// changes were in the way, or git said why.
    /// - Parameter retry: does it again with the local changes put aside and back (`--autostash`).
    private func reportStop(of operation: RepoOperation, _ error: Error, in project: Project, retry: (() -> Void)? = nil) async {
        let message = (error as? Git.Failure)?.message ?? ""
        if let directory = project.gitDirectory, Git.operation(in: directory) != nil {
            let clashes = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U"], in: project.url)) ?? ""
            if !clashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let title: String
                switch operation {
                case .merge: title = L("The merge stopped at conflicts", "合并在冲突处停下了")
                case .rebase: title = L("The rebase stopped at conflicts", "变基在冲突处停下了")
                case .cherryPick: title = L("The cherry-pick stopped at conflicts", "拣选在冲突处停下了")
                case .revert: title = L("The revert stopped at conflicts", "还原在冲突处停下了")
                }
                showConflictsNotice(title, note: operation == .merge
                    ? L("Then commit to finish the merge, or Abort above the list to go back.", "然后提交即可完成合并；或点列表上方的“中止”回到开始之前。")
                    : L("Then Continue above the list; Skip leaves that commit out, Abort goes back to the start.",
                        "然后点列表上方的“继续”；“跳过”会略过这个提交，“中止”回到开始之前。"))
            } else {
                // Stopped with nothing to resolve: the commit brings in nothing the branch does not have.
                var request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle",
                                            title: L("A commit brings in nothing new", "有个提交没有带来新的改动"),
                                            message: L("Its changes are already in the branch. Skip it above the list to go on, or Abort to go back to the start.",
                                                       "它的改动分支里已经有了。点列表上方的“跳过”继续，或“中止”回到开始之前。"),
                                            confirmTitle: L("OK", "好"), cancelTitle: nil)
                request.output = message
                ask(request)
            }
        } else if Git.refusedForLocalChanges(message), let retry {
            var request = DialogRequest(style: .caution, symbol: "tray.and.arrow.down",
                                        title: L("Your local changes are in the way", "本地改动挡住了操作"),
                                        message: L("Put them aside, \(operation.command), then put them back? Where they clash, the files show up as conflicts to resolve.",
                                                   "先把它们放到一边，执行 \(operation.command)，再放回来？有冲突的文件会显示为冲突，待你解决。"),
                                        confirmTitle: L("Stash and Go On", "暂存后继续"))
            request.output = message
            request.onConfirm = retry
            ask(request)
        } else if Git.refusedForLocalChanges(message) {
            showFailure(L("Your local changes are in the way", "本地改动挡住了操作"), error,
                        note: L("Commit them, or put them aside with Git ▸ Stash Changes…, then try again.",
                                "请先提交它们，或用 Git ▸ Stash 改动… 暂存起来，再重试。"))
        } else {
            let title: String
            switch operation {
            case .merge: title = L("Merge failed", "合并失败")
            case .rebase: title = L("Rebase failed", "变基失败")
            case .cherryPick: title = L("Cherry-pick failed", "拣选失败")
            case .revert: title = L("Revert failed", "还原失败")
            }
            showFailure(title, error)
        }
    }

    /// Skip in the banner: leaves out the commit the rebase, cherry-pick or revert stopped at, and goes on.
    /// Asks first when that throws away changes (conflict resolutions).
    func skipOperation(in project: Project? = nil, confirmed: Bool = false) {
        guard let project = project ?? currentProject, let operation = project.status.operation, operation != .merge else { return }
        guard viewer.saveEdits() else { return }
        if !confirmed, !project.status.changes.isEmpty {
            var request = DialogRequest(style: .destructive, symbol: "forward.end",
                                        title: L("Skip this commit?", "跳过这个提交？"),
                                        message: L("Its changes are left out of the \(operation.command), and so are the conflict resolutions made for it. The \(operation.command) goes on with the next commit.",
                                                   "它的改动不会进入这次 \(operation.command)，为它解决的冲突也一并丢弃。之后从下一个提交继续。"),
                                        confirmTitle: L("Skip", "跳过"))
            request.onConfirm = { [weak self] in self?.skipOperation(in: project, confirmed: true) }
            ask(request)
            return
        }
        runActivity(L("Skipping…", "正在跳过…"), in: project) { [weak self] in
            do {
                try await Git.skipOperation(operation, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showToast(L("Skipped · the \(operation.command) is done", "已跳过 · \(operation.command) 已完成"))
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                await self.reportStop(of: operation, error, in: project)
            }
        }
    }

    // MARK: Commits

    /// The commits a menu on `commit` acts on: every picked one when it is one of them, else itself; newest first.
    func menuCommits(_ commit: Commit, picked: Set<String>, in list: [Commit]) -> [Commit] {
        guard picked.count > 1, picked.contains(commit.hash) else { return [commit] }
        return list.filter { picked.contains($0.hash) }
    }

    /// Applies `commits` (newest first, as the lists run) on top of HEAD, oldest first, as new commits. Merge commits,
    /// and commits whose changes HEAD already has, are left out.
    func cherryPick(_ commits: [Commit], in project: Project) {
        guard readyToRewrite(project) else { return }
        runActivity(L("Cherry-picking…", "正在拣选…"), in: project) { [weak self] in
            let root = project.url
            var picks: [Commit] = []
            var leftOut = 0
            for commit in commits.reversed() {
                let contained = commit.isMerge ? true : await Git.isAncestor(commit.hash, of: "HEAD", in: root)
                if contained {
                    leftOut += 1
                } else {
                    picks.append(commit)
                }
            }
            let applied = await Git.alreadyApplied(picks.map(\.hash), in: root)
            leftOut += applied.count
            picks.removeAll { applied.contains($0.hash) }
            guard let self else { return }
            guard !picks.isEmpty else {
                self.showToast(commits.allSatisfy(\.isMerge) ? L("Merge commits can't be cherry-picked", "合并提交不能拣选")
                                                              : L("The current branch already has these changes", "当前分支已经有这些改动"))
                return
            }
            do {
                let move = try await Git.cherryPick(picks.map(\.hash), in: root)
                self.afterBranchesChanged(project)
                var text = picks.count == 1 ? L("Cherry-picked \(picks[0].shortHash)", "已拣选 \(picks[0].shortHash)")
                                            : L("Cherry-picked \(picks.count) commits", "已拣选 \(picks.count) 个提交")
                if leftOut > 0 { text += L(" · \(leftOut) left out", " · 略过 \(leftOut) 个") }
                self.announce(text, undoing: move, in: project)
            } catch {
                self.afterBranchesChanged(project)
                await self.reportStop(of: .cherryPick, error, in: project)
            }
        }
    }

    /// Adds commits that undo `commits` (newest first), each with git's "Revert …" message. Only commits of the
    /// current branch can be, and not merges.
    func revert(_ commits: [Commit], in project: Project) {
        guard readyToRewrite(project) else { return }
        runActivity(L("Reverting…", "正在还原…"), in: project) { [weak self] in
            let root = project.url
            var picks: [Commit] = []
            for commit in commits where !commit.isMerge {
                if await Git.isAncestor(commit.hash, of: "HEAD", in: root) { picks.append(commit) }
            }
            guard let self else { return }
            guard !picks.isEmpty else {
                self.showToast(commits.allSatisfy(\.isMerge) ? L("Merge commits can't be reverted here", "合并提交不能在这里还原")
                                                              : L("Only commits of the current branch can be reverted", "只能还原当前分支上的提交"))
                return
            }
            do {
                let move = try await Git.revert(picks.map(\.hash), in: root)
                self.afterBranchesChanged(project)
                var text = picks.count == 1 ? L("Reverted \(picks[0].shortHash)", "已还原 \(picks[0].shortHash)")
                                            : L("Reverted \(picks.count) commits", "已还原 \(picks.count) 个提交")
                let leftOut = commits.count - picks.count
                if leftOut > 0 { text += L(" · \(leftOut) left out", " · 略过 \(leftOut) 个") }
                self.announce(text, undoing: move, in: project)
            } catch {
                self.afterBranchesChanged(project)
                await self.reportStop(of: .revert, error, in: project)
            }
        }
    }

    /// "Reset Current Branch to Here…": says which commits leave the branch, and asks how far the reset goes.
    func resetCurrentBranch(to commit: Commit, in project: Project) {
        guard readyToRewrite(project) else { return }
        Task { @MainActor [weak self] in
            let root = project.url
            guard let head = try? await Git.head(in: root) else { return }
            let name = await Git.currentBranch(in: root) ?? "HEAD"
            guard let self else { return }
            guard head != commit.hash else {
                self.showToast(L("\(name) is already at \(commit.shortHash)", "\(name) 已经在 \(commit.shortHash)"))
                return
            }
            let leaving = await Git.commits("\(commit.hash)..HEAD", in: root, limit: 200)
            let gained = await Git.count("HEAD..\(commit.hash)", in: root)
            let unpushed = await Git.count("\(commit.hash)..HEAD", "--not", "--remotes", in: root)
            let pushed = max(0, leaving.count - unpushed)

            var lines: [String] = []
            if leaving.isEmpty {
                lines.append(L("No commit leaves \(name).", "不会有提交离开 \(name)。"))
            } else {
                lines.append(leaving.count == 1 ? L("1 commit leaves \(name):", "有 1 个提交将离开 \(name)：")
                                                : L("\(leaving.count) commits leave \(name):", "有 \(leaving.count) 个提交将离开 \(name)："))
            }
            if gained > 0 {
                lines.insert(gained == 1 ? L("\(name) gains 1 commit it does not have.", "\(name) 会多出 1 个它原本没有的提交。")
                                         : L("\(name) gains \(gained) commits it does not have.", "\(name) 会多出 \(gained) 个它原本没有的提交。"), at: 0)
            }
            if pushed > 0 {
                lines.append(L("\(pushed) of them are already on the remote: \(name) will be behind it, and only a force push could take them off there.",
                               "其中 \(pushed) 个已经推送到远程：\(name) 会落后于远程，只有强制推送才能把它们从远程去掉。"))
            }
            var request = DialogRequest(style: .caution, symbol: "arrow.uturn.backward.circle",
                                        title: L("Reset \(name) to \(commit.shortHash)?", "将 \(name) 重置到 \(commit.shortHash)？"),
                                        message: lines.joined(separator: "\n"), confirmTitle: L("Reset", "重置"))
            request.items = leaving.prefix(5).map { DialogRequest.Item(title: $0.subject, detail: $0.shortHash, symbol: "minus.circle") }
            request.hiddenCount = max(0, leaving.count - 5)
            request.choices = ResetMode.allCases.map { DialogRequest.Choice(title: $0.title, detail: $0.detail, destructive: $0 == .hard) }
            request.choice = ResetMode.allCases.firstIndex(of: .mixed) ?? 0
            request.onAnswer = { [weak self] answer in
                self?.reset(to: commit, mode: ResetMode.allCases[answer.choice], name: name, in: project)
            }
            self.ask(request)
        }
    }

    private func reset(to commit: Commit, mode: ResetMode, name: String, in project: Project) {
        guard readyToRewrite(project) else { return }
        runActivity(L("Resetting…", "正在重置…"), in: project) { [weak self] in
            do {
                let move = try await Git.reset(to: commit.hash, mode: mode, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.announce(L("Reset \(name) to \(commit.shortHash) (\(mode.title))", "已将 \(name) 重置到 \(commit.shortHash)（\(mode.title)）"),
                              undoing: move, in: project)
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showFailure(L("Could not reset \(name)", "无法重置 \(name)"), error,
                                 note: mode == .keep ? L("Keep refuses when your local changes are in files those commits changed. Pick Mixed to keep both, or stash them first.",
                                                         "如果本地改动所在的文件也被那些提交改过，Keep 会拒绝。可以改用 Mixed 两者都保留，或先暂存本地改动。") : nil)
            }
        }
    }

    // MARK: Branches

    /// Merges `ref` into the current branch ("Merge into Current"), with git's own message.
    func merge(_ ref: GitRef, in project: Project, autostash: Bool = false) {
        guard readyToRewrite(project) else { return }
        guard let current = project.status.branch else {
            showToast(L("No branch is checked out (detached HEAD) · nothing to merge into", "当前不在任何分支上（游离 HEAD）· 无法合并"))
            return
        }
        runActivity(L("Merging \(ref.shortName)…", "正在合并 \(ref.shortName)…"), in: project) { [weak self] in
            do {
                let (outcome, move) = try await Git.merge(ref.name, autostash: autostash, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                switch outcome {
                case .upToDate:
                    self.showToast(L("\(current) already has everything in \(ref.shortName)", "\(current) 已包含 \(ref.shortName) 的全部提交"))
                case .fastForward:
                    self.announce(L("Merged \(ref.shortName) into \(current) · fast-forward", "已将 \(ref.shortName) 合并到 \(current) · 快进"), undoing: move, in: project)
                case .merged:
                    self.announce(L("Merged \(ref.shortName) into \(current)", "已将 \(ref.shortName) 合并到 \(current)"), undoing: move, in: project)
                }
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                await self.reportStop(of: .merge, error, in: project, retry: autostash ? nil : { [weak self] in
                    self?.merge(ref, in: project, autostash: true)
                })
            }
        }
    }

    /// Replays the current branch's own commits on top of `ref` ("Rebase Current onto Selected"). Asks first when
    /// some of them were pushed: they would have to be force-pushed.
    func rebase(onto ref: GitRef, in project: Project, autostash: Bool = false, confirmed: Bool = false) {
        guard readyToRewrite(project) else { return }
        guard let current = project.status.branch else {
            showToast(L("No branch is checked out (detached HEAD) · nothing to rebase", "当前不在任何分支上（游离 HEAD）· 无法变基"))
            return
        }
        Task { @MainActor [weak self] in
            let root = project.url
            if !confirmed {
                let own = await Git.count("\(ref.name)..HEAD", in: project.url)
                let unpushed = await Git.count("\(ref.name)..HEAD", "--not", "--remotes", in: root)
                if own > unpushed {
                    var request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle",
                                                title: L("Rebase pushed commits?", "变基已推送的提交？"),
                                                message: own - unpushed == 1
                                                    ? L("A commit of \(current) that would be replayed is already on the remote. Afterwards it is a new commit, and \(current) can only be pushed by force.",
                                                        "\(current) 上要重放的提交中，有 1 个已经推送到远程。变基后它会变成新的提交，\(current) 只能强制推送。")
                                                    : L("\(own - unpushed) commits of \(current) that would be replayed are already on the remote. Afterwards they are new commits, and \(current) can only be pushed by force.",
                                                        "\(current) 上要重放的提交中，有 \(own - unpushed) 个已经推送到远程。变基后它们会变成新的提交，\(current) 只能强制推送。"),
                                                confirmTitle: L("Rebase", "变基"))
                    request.onConfirm = { [weak self] in self?.rebase(onto: ref, in: project, autostash: autostash, confirmed: true) }
                    self?.ask(request)
                    return
                }
            }
            self?.runActivity(L("Rebasing onto \(ref.shortName)…", "正在变基到 \(ref.shortName)…"), in: project) { [weak self] in
                do {
                    let move = try await Git.rebase(onto: ref.name, autostash: autostash, in: root)
                    guard let self else { return }
                    self.afterBranchesChanged(project)
                    if move.before == move.after {
                        self.showToast(L("\(current) is already on top of \(ref.shortName)", "\(current) 已经在 \(ref.shortName) 之上"))
                    } else {
                        self.announce(L("Rebased \(current) onto \(ref.shortName)", "已将 \(current) 变基到 \(ref.shortName)"), undoing: move, in: project)
                    }
                } catch {
                    guard let self else { return }
                    self.afterBranchesChanged(project)
                    await self.reportStop(of: .rebase, error, in: project, retry: autostash ? nil : { [weak self] in
                        self?.rebase(onto: ref, in: project, autostash: true, confirmed: true)
                    })
                }
            }
        }
    }

    func renameBranch(_ ref: GitRef, in project: Project) {
        guard ref.kind == .local else { return }
        Task { @MainActor [weak self] in
            let existing = Set(((try? await Git.refs(in: project.url)) ?? []).filter { $0.kind == .local && $0.name != ref.name }.map(\.shortName))
            guard let self else { return }
            var request = DialogRequest(style: .info, symbol: "pencil",
                                        title: L("Rename \(ref.shortName)", "重命名 \(ref.shortName)"),
                                        message: ref.upstream.map { L("It goes on following \($0); the remote branch keeps its name.", "它仍然跟踪 \($0)；远程分支的名称不变。") } ?? "",
                                        confirmTitle: L("Rename", "重命名"))
            request.input = .init(placeholder: L("Branch name", "分支名"), text: ref.shortName,
                                  problem: { $0 == ref.shortName ? nil : Git.branchNameProblem($0, existing: existing) })
            request.onSubmit = { [weak self] name in
                guard name != ref.shortName else { return }
                self?.rename(ref.shortName, to: name, in: project, undoable: true)
            }
            self.ask(request)
        }
    }

    private func rename(_ name: String, to newName: String, in project: Project, undoable: Bool) {
        runActivity(L("Renaming \(name)…", "正在重命名 \(name)…"), in: project) { [weak self] in
            do {
                try await Git.renameBranch(name, to: newName, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                let text = L("Renamed \(name) to \(newName)", "已将 \(name) 重命名为 \(newName)")
                if undoable {
                    self.showToast(text, action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                        self?.rename(newName, to: name, in: project, undoable: false)
                    })
                } else {
                    self.showToast(text)
                }
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not rename \(name)", "无法重命名 \(name)"), error)
            }
        }
    }

    /// Deletes a local branch; Undo in the toast brings it back. One whose commits are in no other branch is only
    /// deleted once confirmed.
    func deleteBranch(_ ref: GitRef, in project: Project, force: Bool = false) {
        guard ref.kind == .local else { return }
        guard !ref.isHead else {
            showToast(L("\(ref.shortName) is checked out · check out another branch first", "\(ref.shortName) 正处于检出状态 · 请先检出别的分支"))
            return
        }
        runActivity(L("Deleting \(ref.shortName)…", "正在删除 \(ref.shortName)…"), in: project) { [weak self] in
            let root = project.url
            do {
                try await Git.deleteBranch(ref.shortName, force: force, in: root)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showToast(L("Deleted \(ref.shortName)", "已删除 \(ref.shortName)"), action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                    self?.restoreBranch(ref, in: project)
                })
            } catch {
                guard let self else { return }
                guard !force, Git.isNotFullyMerged((error as? Git.Failure)?.message ?? "") else {
                    self.showFailure(L("Could not delete \(ref.shortName)", "无法删除 \(ref.shortName)"), error)
                    return
                }
                // Its own commits: on it, and on no other branch.
                let own = await Git.commits(ref.target, "--not", "--exclude=\(ref.shortName)", "--branches", "--remotes", in: root, limit: 200)
                var request = DialogRequest(style: .destructive, symbol: "trash",
                                            title: L("\(ref.shortName) is not fully merged", "\(ref.shortName) 还没有完全合并"),
                                            message: own.isEmpty
                                                ? L("Its commits are not in \(ref.upstream ?? "the current branch") yet. Delete it anyway?",
                                                    "它的提交还不在 \(ref.upstream ?? "当前分支") 里。仍然删除？")
                                                : L("These commits are on no other branch. Delete it anyway? Undo in the toast brings it back.",
                                                    "这些提交不在任何其他分支上。仍然删除？可以用提示里的“撤销”恢复。"),
                                            confirmTitle: L("Delete Anyway", "仍然删除"))
                request.items = own.prefix(5).map { DialogRequest.Item(title: $0.subject, detail: $0.shortHash, symbol: "smallcircle.filled.circle") }
                request.hiddenCount = max(0, own.count - 5)
                request.onConfirm = { [weak self] in self?.deleteBranch(ref, in: project, force: true) }
                self.ask(request)
            }
        }
    }

    private func restoreBranch(_ ref: GitRef, in project: Project) {
        runActivity(L("Restoring \(ref.shortName)…", "正在恢复 \(ref.shortName)…"), in: project) { [weak self] in
            do {
                try await Git.restoreBranch(ref.shortName, at: ref.target, upstream: ref.upstream, in: project.url)
                self?.afterBranchesChanged(project)
                self?.showToast(L("Restored \(ref.shortName)", "已恢复 \(ref.shortName)"))
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not restore \(ref.shortName)", "无法恢复 \(ref.shortName)"), error)
            }
        }
    }

    /// Deletes a branch on its remote, for everyone, once confirmed. Undo in the toast pushes it back.
    func deleteRemoteBranch(_ ref: GitRef, in project: Project) {
        guard ref.kind == .remote else { return }
        Task { @MainActor [weak self] in
            let remotes = await Git.remotes(in: project.url)
            guard let self, let (remote, branch) = Git.splitRemoteBranch(ref.shortName, remotes: remotes) else { return }
            guard !Git.protectedBranches.contains(branch) else {
                self.showToast(L("DiffCode doesn't delete \(ref.shortName)", "DiffCode 不会删除 \(ref.shortName)"))
                return
            }
            var request = DialogRequest(style: .destructive, symbol: "trash",
                                        title: L("Delete \(branch) from \(remote)?", "从 \(remote) 删除 \(branch)？"),
                                        message: L("The branch goes away on the server, for everyone who uses it. Local branches stay.",
                                                   "服务器上的这个分支会被删除，所有使用它的人都会受影响。本地分支保留。"),
                                        confirmTitle: L("Delete", "删除"))
            request.onConfirm = { [weak self] in
                self?.runActivity(L("Deleting \(ref.shortName)…", "正在删除 \(ref.shortName)…"), cancellable: true, in: project) { [weak self] in
                    do {
                        try await Git.deleteRemoteBranch(branch, remote: remote, in: project.url)
                        guard let self else { return }
                        self.afterBranchesChanged(project)
                        self.showToast(L("Deleted \(ref.shortName)", "已删除 \(ref.shortName)"), action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                            self?.restoreRemoteBranch(branch, remote: remote, at: ref.target, in: project)
                        })
                    } catch is CancellationError {
                        self?.afterBranchesChanged(project)
                    } catch {
                        guard let self else { return }
                        self.afterBranchesChanged(project)
                        self.showFailure(L("Could not delete \(ref.shortName)", "无法删除 \(ref.shortName)"), error, note: self.remoteNote(error))
                    }
                }
            }
            self.ask(request)
        }
    }

    private func restoreRemoteBranch(_ branch: String, remote: String, at hash: String, in project: Project) {
        runActivity(L("Pushing \(branch) back…", "正在推回 \(branch)…"), cancellable: true, in: project) { [weak self] in
            do {
                try await Git.restoreRemoteBranch(branch, remote: remote, at: hash, in: project.url)
                self?.afterBranchesChanged(project)
                self?.showToast(L("Restored \(remote)/\(branch)", "已恢复 \(remote)/\(branch)"))
            } catch is CancellationError {
                self?.afterBranchesChanged(project)
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showFailure(L("Could not restore \(remote)/\(branch)", "无法恢复 \(remote)/\(branch)"), error, note: self.remoteNote(error))
            }
        }
    }

    // MARK: Menus

    /// Which of `list` HEAD has: HEAD and its ancestors among them, found through their parents. Nil when HEAD is not
    /// in the list, and so nothing can be told.
    static func commitsInHead(_ list: [Commit], head: String?) -> Set<String>? {
        guard let head else { return nil }
        let byHash = Dictionary(list.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        guard byHash[head] != nil else { return nil }
        var seen = Set<String>()
        var stack = [head]
        while let hash = stack.popLast() {
            guard let commit = byHash[hash], seen.insert(hash).inserted else { continue }
            stack += commit.parents
        }
        return seen
    }

    /// Cherry-pick, Revert and Reset for a commit's right-click menu (the Log's and the Git graph's).
    /// - Parameters:
    ///   - commits: what the menu acts on (`menuCommits`), newest first; reset takes the clicked one.
    ///   - list: the commits on screen, to tell which the current branch has (`commitsInHead`).
    func addHistoryEditItems(to menu: NSMenu, commit: Commit, commits: [Commit], list: [Commit], project: Project) {
        let several = commits.count > 1
        let inHead = Self.commitsInHead(list, head: project.status.headOID)
        // Picking brings in what the branch does not have; reverting takes out what it has.
        let pickable = commits.filter { !$0.isMerge && inHead?.contains($0.hash) != true }
        let revertible = commits.filter { !$0.isMerge && inHead?.contains($0.hash) != false }
        let cherryPick = ClosureMenuItem(several ? L("Cherry-Pick \(pickable.count) Commits", "拣选 \(pickable.count) 个提交 (Cherry-Pick)")
                                                 : L("Cherry-Pick", "拣选到当前分支 (Cherry-Pick)")) { [weak self] in
            self?.cherryPick(pickable, in: project)
        }
        cherryPick.isEnabled = !pickable.isEmpty
        menu.addItem(cherryPick)
        let revert = ClosureMenuItem(several ? L("Revert \(revertible.count) Commits", "还原 \(revertible.count) 个提交 (Revert)")
                                             : L("Revert Commit", "还原提交 (Revert)")) { [weak self] in
            self?.revert(revertible, in: project)
        }
        revert.isEnabled = !revertible.isEmpty
        menu.addItem(revert)
        let name = project.status.branch ?? "HEAD"
        let reset = ClosureMenuItem(L("Reset \(name) to Here…", "将 \(name) 重置到这里…")) { [weak self] in
            self?.resetCurrentBranch(to: commit, in: project)
        }
        reset.isEnabled = !several && commit.hash != project.status.headOID
        menu.addItem(reset)
    }

    /// Merge, Rebase, Rename and Delete for a branch's right-click menu in the Git graph.
    func addBranchEditItems(to menu: NSMenu, ref: GitRef, project: Project) {
        let current = project.status.branch
        if ref.kind != .tag, !(ref.kind == .local && ref.isHead), let current {
            menu.addItem(ClosureMenuItem(L("Merge \(ref.shortName) into \(current)", "将 \(ref.shortName) 合并到 \(current)")) { [weak self] in
                self?.merge(ref, in: project)
            })
            menu.addItem(ClosureMenuItem(L("Rebase \(current) onto \(ref.shortName)", "将 \(current) 变基到 \(ref.shortName)")) { [weak self] in
                self?.rebase(onto: ref, in: project)
            })
            menu.addItem(.separator())
        }
        switch ref.kind {
        case .local:
            menu.addItem(ClosureMenuItem(L("Rename…", "重命名…")) { [weak self] in self?.renameBranch(ref, in: project) })
            let delete = ClosureMenuItem(L("Delete", "删除")) { [weak self] in self?.deleteBranch(ref, in: project) }
            delete.isEnabled = !ref.isHead
            menu.addItem(delete)
            menu.addItem(.separator())
        case .remote:
            let remote = ref.shortName.split(separator: "/", maxSplits: 1).first.map(String.init) ?? "origin"
            let branch = ref.shortName.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let delete = ClosureMenuItem(L("Delete from \(remote)…", "从 \(remote) 删除…")) { [weak self] in self?.deleteRemoteBranch(ref, in: project) }
            delete.isEnabled = !Git.protectedBranches.contains(branch) && branch != "HEAD"
            menu.addItem(delete)
            menu.addItem(.separator())
        case .tag:
            menu.addItem(ClosureMenuItem(L("Rename…", "重命名…")) { [weak self] in self?.renameTag(ref, in: project) })
            menu.addItem(ClosureMenuItem(L("Delete…", "删除…")) { [weak self] in self?.deleteTag(ref, in: project) })
            menu.addItem(.separator())
        }
    }
}
