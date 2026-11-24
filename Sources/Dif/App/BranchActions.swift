import AppKit
import SwiftUI

/// Switching and creating branches, talking to remotes (fetch, pull, push), and finishing or abandoning a merge or
/// rebase that stopped for conflicts. Each step is git's own command, run as the user would in a terminal; nothing is
/// forced, and a refusal shows git's words.
extension AppStore {
    // MARK: Running

    /// Runs `work` as the project's one branch or remote operation, named by its branch (`title`) until it ends.
    /// - Parameter cancellable: a network operation, which the Git graph offers to stop.
    func runActivity(_ title: String, cancellable: Bool = false, in project: Project,
                             _ work: @escaping @MainActor () async -> Void) {
        if let running = project.activity {
            showToast(L("Wait for “\(running)” to finish", "请等“\(running)”完成"))
            return
        }
        project.activity = title
        project.activityCancellable = cancellable
        project.activityTask = Task { @MainActor [weak project] in
            await work()
            project?.activity = nil
            project?.activityTask = nil
        }
    }

    func cancelActivity(in project: Project) {
        guard project.activityCancellable else { return }
        project.activityTask?.cancel()
    }

    /// HEAD or the branches moved: the lists, the tree and an open Git graph follow.
    func afterBranchesChanged(_ project: Project) {
        project.invalidateFiles()
        project.logStale = true
        project.refresh()
        if project.tab == .log { project.loadLog(reset: true) }
        if popup == .gitGraph, gitGraph.projectID == project.id { gitGraph.reload() }
    }

    /// What to try when git could not reach or sign in to a remote.
    func remoteNote(_ error: Error) -> String? {
        let message = error.localizedDescription
        if Sandbox.isActive, !Sandbox.canReadHome,
           message.contains("ssh") || message.contains("Permission denied") || message.contains("Host key") {
            return L("The App Store version can use your SSH keys and settings only once you grant your home folder: File ▸ Grant Folder Access…",
                     "App Store 版需要你授权个人文件夹后才能使用 SSH 密钥与设置：文件 ▸ 授权访问文件夹…")
        }
        if message.contains("terminal prompts disabled") || message.contains("could not read Username")
            || message.contains("could not read Password") || message.contains("Authentication failed") {
            return L("Git could not ask for a password here. Run the same command once in a terminal, so that your keychain or credential helper remembers it.",
                     "Git 在这里无法询问密码。请在终端里运行一次同样的命令，让钥匙串或凭据助手记住它。")
        }
        if message.contains("Permission denied (publickey") || message.contains("Host key verification failed")
            || message.contains("passphrase") {
            return L("SSH could not sign in on its own. Add your key to the agent (ssh-add --apple-use-keychain), or connect once in a terminal to accept the server's key.",
                     "SSH 无法自动登录。请把密钥加入 agent（ssh-add --apple-use-keychain），或在终端里连接一次以接受服务器指纹。")
        }
        return sandboxNote(for: error)
    }

    // MARK: Checkout

    /// Switches to a branch. A remote branch gets a local branch of the same name that follows it, as in the IDE;
    /// a tag is checked out without a branch.
    func checkout(_ ref: GitRef, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        switch ref.kind {
        case .local:
            guard !ref.isHead else {
                showToast(L("\(ref.shortName) is already checked out", "已经在 \(ref.shortName) 上"))
                return
            }
            switchTo(ref.shortName, in: project) { try await Git.switchBranch(ref.shortName, in: project.url) }
        case .remote:
            // "origin/feature/x" becomes "feature/x".
            let local = ref.shortName.split(separator: "/", maxSplits: 1).dropFirst().first.map(String.init) ?? ref.shortName
            Task { @MainActor [weak self] in
                let refs = (try? await Git.refs(in: project.url)) ?? []
                guard let self else { return }
                if let existing = refs.first(where: { $0.kind == .local && $0.shortName == local }) {
                    if existing.upstream == ref.shortName {
                        if existing.isHead {
                            self.showToast(L("\(local) is already checked out", "已经在 \(local) 上"))
                        } else {
                            self.switchTo(local, in: project) { try await Git.switchBranch(local, in: project.url) }
                        }
                    } else {
                        // The name is taken by a branch that follows something else: pick another.
                        self.newBranch(from: ref.name, startTitle: ref.shortName, tracking: ref.shortName, in: project)
                    }
                } else {
                    self.switchTo(local, in: project) { try await Git.trackBranch(ref.shortName, as: local, in: project.url) }
                }
            }
        case .tag:
            checkoutRevision(ref.target, title: ref.shortName, in: project)
        }
    }

    /// Checks out a commit without a branch, after saying what that means.
    func checkoutRevision(_ hash: String, title: String, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        var request = DialogRequest(style: .caution, symbol: "smallcircle.filled.circle",
                                    title: L("Check out \(title) without a branch?", "不带分支检出 \(title)？"),
                                    message: L("HEAD will point at the commit itself (a detached HEAD), to look at or build that version. Commits made there belong to no branch: create a branch first to keep them.",
                                               "HEAD 将直接指向这个提交（游离 HEAD），适合查看或构建这个版本。在这里做的提交不属于任何分支：要保留它们，请先新建分支。"),
                                    confirmTitle: L("Check Out", "检出"))
        request.onConfirm = { [weak self] in
            self?.switchTo(title, in: project) { try await Git.detach(at: hash, in: project.url) }
        }
        ask(request)
    }

    /// Asks for a name, then creates a branch at `start` (HEAD when nil) and switches to it, local changes and all.
    /// - Parameter tracking: a remote branch the new one follows.
    func newBranch(from start: String? = nil, startTitle: String? = nil, tracking: String? = nil, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        Task { @MainActor [weak self] in
            let existing = Set(((try? await Git.refs(in: project.url)) ?? []).filter { $0.kind == .local }.map(\.shortName))
            guard let self else { return }
            var request = DialogRequest(style: .info, symbol: "arrow.triangle.branch",
                                        title: startTitle.map { L("New branch from \($0)", "从 \($0) 新建分支") } ?? L("New branch", "新建分支"),
                                        message: L("It is checked out right away; your local changes come along.", "创建后立即检出，本地改动会一起带过去。"),
                                        confirmTitle: L("Create", "创建"))
            request.input = .init(placeholder: L("Branch name", "分支名"), problem: { Git.branchNameProblem($0, existing: existing) })
            request.onSubmit = { [weak self] name in
                self?.switchTo(name, in: project) {
                    if let tracking {
                        try await Git.trackBranch(tracking, as: name, in: project.url)
                    } else {
                        try await Git.createBranch(name, at: start, in: project.url)
                    }
                }
            }
            self.ask(request)
        }
    }

    /// Runs a checkout. When local changes are in the way, offers to carry them over (Smart Checkout).
    private func switchTo(_ title: String, in project: Project, _ attempt: @escaping () async throws -> Void) {
        guard project.status.operation == nil else {
            showToast(L("Finish or abort the \(project.status.operation!.command) first", "请先完成或中止当前的 \(project.status.operation!.command)"))
            return
        }
        guard viewer.saveEdits() else { return }
        runActivity(L("Checking out \(title)…", "正在检出 \(title)…"), in: project) { [weak self] in
            do {
                try await attempt()
                guard let self else { return }
                project.pendingPushAfterPull = nil
                self.afterBranchesChanged(project)
                self.showToast(L("Checked out \(title)", "已检出 \(title)"))
            } catch {
                guard let self else { return }
                let message = (error as? Git.Failure)?.message ?? ""
                let files = Git.overwrittenFiles(message)
                if !files.isEmpty, !message.contains("untracked working tree files") {
                    self.offerSmartCheckout(title, files: files, in: project, attempt)
                } else {
                    self.showFailure(L("Could not check out \(title)", "无法检出 \(title)"), error)
                }
            }
        }
    }

    private func offerSmartCheckout(_ title: String, files: [String], in project: Project, _ attempt: @escaping () async throws -> Void) {
        var request = DialogRequest(style: .caution, symbol: "arrow.triangle.branch",
                                    title: L("Your changes would be overwritten by \(title)", "检出 \(title) 会覆盖你的本地改动"),
                                    message: L("Smart Checkout puts your changes aside, checks out \(title), then puts them back. Where they clash, the files show up as conflicts to resolve.",
                                               "智能检出会先把改动放到一边，检出 \(title) 后再放回来。有冲突的文件会显示为冲突，待你解决。"),
                                    confirmTitle: L("Smart Checkout", "智能检出"))
        (request.items, request.hiddenCount) = DialogRequest.files(files.map { FileChange(path: $0, oldPath: nil, kind: .modified) })
        request.onConfirm = { [weak self] in self?.smartCheckout(title, in: project, attempt) }
        ask(request)
    }

    private func smartCheckout(_ title: String, in project: Project, _ attempt: @escaping () async throws -> Void) {
        runActivity(L("Checking out \(title)…", "正在检出 \(title)…"), in: project) { [weak self] in
            do {
                try await Git.stash(message: "DiffCode: before checking out \(title)", in: project.url)
            } catch {
                self?.showFailure(L("Could not put your changes aside", "无法暂存你的改动"), error)
                return
            }
            do {
                try await attempt()
            } catch {
                // Could not switch after all: the changes go back where they were.
                try? await Git.unstash(in: project.url)
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not check out \(title)", "无法检出 \(title)"), error)
                return
            }
            do {
                try await Git.unstash(in: project.url)
                self?.afterBranchesChanged(project)
                self?.showToast(L("Checked out \(title) · your changes came along", "已检出 \(title) · 本地改动已带过来"))
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                let clashes = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U"], in: project.url)) ?? ""
                if self.settings.autoOpenThreeWayMerge, !clashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.handleConflictsDetected(
                        in: project,
                        title: L("Checked out \(title) · some of your changes clash with it", "已检出 \(title) · 部分本地改动与它冲突"),
                        note: L("Your changes also stay in git's stash (stash@{0}) until you drop it.", "你的改动也仍保存在 git 的 stash（stash@{0}）里，直到你删除它。")
                    )
                } else {
                    var request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle",
                                                title: L("Checked out \(title) · some of your changes clash with it", "已检出 \(title) · 部分本地改动与它冲突"),
                                                message: L("The clashing files are marked as conflicts in the Changes list: resolve them there. Your changes also stay in git's stash (stash@{0}) until you drop it.",
                                                           "冲突的文件已在变更列表中标出，请在那里解决。你的改动也仍保存在 git 的 stash（stash@{0}）里，直到你删除它。"),
                                                confirmTitle: L("OK", "好"), cancelTitle: nil)
                    request.output = error.localizedDescription
                    self.ask(request)
                }
            }
        }
    }

    // MARK: Remotes

    /// Brings every remote's branches up to date.
    func fetch(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        runActivity(L("Fetching…", "正在获取…"), cancellable: true, in: project) { [weak self] in
            do {
                try await Git.fetch(in: project.url)
                let counts = try? await Git.runString(["rev-list", "--left-right", "--count", "HEAD...@{upstream}"], in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                let behind = counts.flatMap { Int($0.split(whereSeparator: \.isWhitespace).last ?? "") } ?? 0
                self.showToast(behind > 0 ? L("Fetched · ↓\(behind) to pull", "已获取 · 有 \(behind) 个提交可拉取") : L("Fetched · up to date", "已获取 · 已是最新"))
            } catch is CancellationError {
                self?.afterBranchesChanged(project)
            } catch {
                guard let self else { return }
                self.showFailure(L("Fetch failed", "获取失败"), error, note: self.remoteNote(error))
            }
        }
    }

    /// Update Project: brings the upstream's commits into the current branch.
    func pull(in project: Project? = nil, mode: PullMode = .configured, autostash: Bool = false) {
        guard let project = project ?? currentProject else { return }
        guard let branch = project.status.branch else {
            showToast(L("No branch is checked out (detached HEAD) · nothing to pull into", "当前不在任何分支上（游离 HEAD）· 无法拉取"))
            return
        }
        guard let upstream = project.status.upstream else {
            showToast(L("\(branch) follows no remote branch · push it first", "\(branch) 没有跟踪的远程分支 · 请先推送"))
            return
        }
        if let operation = project.status.operation {
            showToast(L("Finish or abort the \(operation.command) first", "请先完成或中止当前的 \(operation.command)"))
            return
        }
        guard viewer.saveEdits() else { return }
        runActivity(L("Pulling…", "正在拉取…"), cancellable: true, in: project) { [weak self] in
            let before = await Git.resolveCommit("HEAD", in: project.url)
            do {
                try await Git.pull(mode: mode, autostash: autostash, in: project.url)
                let after = await Git.resolveCommit("HEAD", in: project.url)
                var count = 0
                // What came in from the upstream, not the merge commit or replayed commits of one's own.
                if let before, let after, before != after,
                   let out = try? await Git.runString(["rev-list", "--count", "\(before)..@{upstream}"], in: project.url) {
                    count = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                }
                let clashes = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U"], in: project.url)) ?? ""
                guard let self else { return }
                self.afterBranchesChanged(project)
                if !clashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // The pull went through, but putting the local changes back clashed with it.
                    self.handleConflictsDetected(in: project,
                                                 title: L("Pulled · your local changes clash with what came in", "已拉取 · 本地改动与拉下来的内容冲突"),
                                                 note: L("Your changes also stay in git's stash until you drop it.", "你的改动也仍保存在 git 的 stash 里，直到你删除它。"))
                } else if before == after {
                    self.showToast(L("Already up to date with \(upstream)", "已是最新，与 \(upstream) 一致"))
                } else {
                    self.showToast(count == 1 ? L("Pulled 1 commit from \(upstream)", "已从 \(upstream) 拉取 1 个提交")
                                              : L("Pulled \(count) commits from \(upstream)", "已从 \(upstream) 拉取 \(count) 个提交"))
                }
            } catch is CancellationError {
                self?.afterBranchesChanged(project)
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                let message = (error as? Git.Failure)?.message ?? ""
                if message.contains("divergent branches") {
                    self.askHowToReconcile(branch, upstream, in: project, autostash: autostash)
                } else if !autostash, message.contains("would be overwritten by merge") || message.contains("cannot pull with rebase")
                            || message.contains("commit or stash them") || message.contains("commit your changes or stash them") {
                    self.offerAutostashPull(upstream, mode: mode, in: project, error: error)
                } else if let directory = project.gitDirectory, Git.operation(in: directory) != nil {
                    self.handleConflictsDetected(in: project, title: L("The pull stopped at conflicts", "拉取在冲突处停下了"), note: nil)
                } else {
                    self.showFailure(L("Pull failed", "拉取失败"), error, note: self.remoteNote(error))
                }
            }
        }
    }

    private func askHowToReconcile(_ branch: String, _ upstream: String, in project: Project, autostash: Bool) {
        var request = DialogRequest(style: .info, symbol: "arrow.triangle.merge",
                                    title: L("\(branch) and \(upstream) both have new commits", "\(branch) 与 \(upstream) 各有新提交"),
                                    message: L("Merge joins them with a merge commit. Rebase replays your commits on top of \(upstream).",
                                               "合并：用一个合并提交把两边连起来。变基：把你的提交重新接在 \(upstream) 之后。"),
                                    confirmTitle: L("Merge", "合并"))
        request.alternateTitle = L("Rebase", "变基")
        request.onConfirm = { [weak self] in self?.pull(in: project, mode: .merge, autostash: autostash) }
        request.onAlternate = { [weak self] in self?.pull(in: project, mode: .rebase, autostash: autostash) }
        ask(request)
    }

    private func offerAutostashPull(_ upstream: String, mode: PullMode, in project: Project, error: Error) {
        var request = DialogRequest(style: .caution, symbol: "tray.and.arrow.down",
                                    title: L("Your local changes are in the way", "本地改动挡住了拉取"),
                                    message: L("Put them aside, pull from \(upstream), then put them back? Where they clash, the files show up as conflicts to resolve.",
                                               "先把它们放到一边，从 \(upstream) 拉取，再放回来？有冲突的文件会显示为冲突，待你解决。"),
                                    confirmTitle: L("Stash, Pull, Put Back", "暂存后拉取再恢复"))
        request.output = error.localizedDescription
        request.onConfirm = { [weak self] in self?.pull(in: project, mode: mode, autostash: true) }
        ask(request)
    }

    func showConflictsNotice(_ title: String, note: String?) {
        let request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle", title: title,
                                    message: [L("The files in conflict are marked in the Changes list. Open one to pick a side for each conflict, then mark it resolved.",
                                                "冲突的文件已在变更列表中标出。打开文件为每处冲突选择保留哪一边，然后标记为已解决。"), note]
                                        .compactMap { $0 }.joined(separator: "\n\n"),
                                    confirmTitle: L("OK", "好"), cancelTitle: nil)
        ask(request)
    }

    /// ⇧⌘K: lists the commits a push would send, and pushes them on ↩.
    /// - Parameter autoReconcile: when true (Commit & Push), automatically pulls & integrates incoming commits
    ///   instead of halting on the divergent-branches dialog.
    func push(in project: Project? = nil, autoReconcile: Bool = false) {
        guard let project = project ?? currentProject else { return }
        guard let branch = project.status.branch else {
            showToast(L("No branch is checked out (detached HEAD) · nothing to push", "当前不在任何分支上（游离 HEAD）· 无法推送"))
            return
        }
        Task { @MainActor [weak self] in
            let remotes = await Git.remotes(in: project.url)
            let upstream = project.status.upstream
            // With no upstream yet: the only remote, or "origin" among several.
            let remote = upstream != nil ? nil : (remotes.count == 1 ? remotes.first : (remotes.contains("origin") ? "origin" : nil))
            guard let self else { return }
            guard upstream != nil || remote != nil else {
                self.showToast(remotes.isEmpty ? L("This repository has no remote to push to", "这个仓库没有可推送的远程")
                                               : L("Several remotes and no upstream · push once in a terminal to pick one", "有多个远程且没有上游 · 请先在终端里推送一次以选定远程"))
                return
            }
            let commits = await Git.outgoingCommits(upstream: upstream, remote: remote, in: project.url)
            let target = upstream ?? "\(remote ?? "origin")/\(branch)"
            var incoming: [Commit] = []
            if let upstream {
                // The upstream has commits the branch does not: auto-pull on Commit & Push, or offer Pull & Push / Force Push.
                incoming = await Git.incomingCommits(in: project.url)
                if !incoming.isEmpty {
                    if commits.isEmpty {
                        self.showToast(L("Nothing to push · \(upstream) has commits to pull", "没有要推送的提交 · \(upstream) 有可拉取的提交"))
                        return
                    }
                    if !autoReconcile {
                        let protected = await Git.upstreamTarget(of: branch, in: project.url).map { Git.protectedBranches.contains($0.branch) } ?? true
                        let expected = await Git.resolveCommit("@{upstream}", in: project.url)
                        self.offerReconcile(branch: branch, upstream: upstream, target: target, outgoingCount: commits.count, incoming: incoming,
                                            forceTo: protected || Git.protectedBranches.contains(branch) ? nil : expected, in: project)
                        return
                    }
                }
            }
            guard !commits.isEmpty || upstream == nil else {
                self.showToast(L("Nothing to push · \(branch) is level with \(target)", "没有要推送的提交 · \(branch) 与 \(target) 一致"))
                return
            }
            let title: String
            if upstream == nil {
                title = L("Push \(branch) to \(remote ?? "origin")?", "把 \(branch) 推送到 \(remote ?? "origin")？")
            } else {
                title = commits.count == 1 ? L("Push 1 commit to \(target)?", "推送 1 个提交到 \(target)？")
                                           : L("Push \(commits.count) commits to \(target)?", "推送 \(commits.count) 个提交到 \(target)？")
            }
            var request = DialogRequest(style: .info, symbol: "arrow.up.circle", title: title, confirmTitle: L("Push", "推送"))
            if upstream == nil {
                request.message = commits.isEmpty
                    ? L("\(target) is created at a commit the remote already has, and \(branch) follows it from now on.",
                        "将在远程已有的提交上创建 \(target)，此后 \(branch) 跟踪它。")
                    : L("\(target) does not exist yet: it is created, and \(branch) follows it from now on.",
                        "\(target) 还不存在：将创建它，此后 \(branch) 跟踪它。")
            } else if !incoming.isEmpty {
                request.confirmTitle = L("Pull & Push", "拉取并推送")
                request.message = incoming.count == 1
                    ? L("\(target) has 1 new commit. Pushing will automatically pull and integrate it first.",
                        "\(target) 有 1 个新提交，推送前将自动拉取并合并。")
                    : L("\(target) has \(incoming.count) new commits. Pushing will automatically pull and integrate them first.",
                        "\(target) 有 \(incoming.count) 个新提交，推送前将自动拉取并合并。")
            }
            request.items = commits.prefix(6).map { DialogRequest.Item(title: $0.subject, detail: $0.shortHash, symbol: "smallcircle.filled.circle") }
            request.hiddenCount = max(0, commits.count - 6)
            let pullFirst = !incoming.isEmpty
            request.onConfirm = { [weak self] in
                self?.performPush(branch: branch, remote: remote, target: target, count: commits.count,
                                  allowAutoPull: remote == nil, pullFirst: pullFirst, in: project)
            }
            self.ask(request)
        }
    }

    /// The branch and its upstream have both moved on. Pulling is the way, unless the branch was rewritten on
    /// purpose (amend, rebase, reset): then Force Push replaces the upstream's commits.
    /// - Parameter forceTo: the upstream's commit a force push may replace; nil where force is not offered (main, master).
    private func offerReconcile(branch: String, upstream: String, target: String, outgoingCount: Int, incoming: [Commit], forceTo: String?, in project: Project) {
        var request = DialogRequest(style: .caution, symbol: "arrow.triangle.branch",
                                    title: L("\(branch) and \(upstream) have both moved on", "\(branch) 与 \(upstream) 各自有了新提交"),
                                    message: forceTo == nil
                                        ? L("\(upstream) has the commits below, which \(branch) does not. Pull & Push integrates them first, then pushes.",
                                            "\(upstream) 有下面这些 \(branch) 没有的提交。拉取并推送会先拉取合并它们，然后再推送。")
                                        : L("\(upstream) has the commits below, which \(branch) does not. Pull & Push integrates them first, then pushes. If \(branch) was rewritten on purpose (amend, rebase, reset), Force Push replaces them on the remote instead.",
                                            "\(upstream) 有下面这些 \(branch) 没有的提交。拉取并推送会先拉取合并它们，然后再推送。如果 \(branch) 是有意改写的（修改提交、变基、重置），可以用“强制推送”在远程替换掉它们。"),
                                    confirmTitle: L("Pull & Push", "拉取并推送"))
        request.items = incoming.prefix(5).map { DialogRequest.Item(title: $0.subject, detail: $0.shortHash, symbol: "smallcircle.filled.circle") }
        request.hiddenCount = max(0, incoming.count - 5)
        request.onConfirm = { [weak self] in
            self?.performPush(branch: branch, remote: nil, target: target, count: outgoingCount, allowAutoPull: true, pullFirst: true, in: project)
        }
        if let forceTo {
            request.alternateTitle = L("Force Push…", "强制推送…")
            request.onAlternate = { [weak self] in
                self?.confirmForcePush(branch: branch, upstream: upstream, incoming: incoming, expected: forceTo, in: project)
            }
        }
        ask(request)
    }

    private func confirmForcePush(branch: String, upstream: String, incoming: [Commit], expected: String, in project: Project) {
        var request = DialogRequest(style: .destructive, symbol: "exclamationmark.triangle",
                                    title: L("Force push \(branch) to \(upstream)?", "强制推送 \(branch) 到 \(upstream)？"),
                                    message: L("\(upstream) becomes \(branch) as it is here, and the commits below go off the remote, for everyone who uses it. If someone pushed to \(upstream) since it was last fetched, nothing is overwritten.",
                                               "\(upstream) 会变成本地 \(branch) 的样子，下面这些提交会从远程去掉，影响所有使用它的人。如果上次获取后有人推送过 \(upstream)，则不会覆盖任何内容。"),
                                    confirmTitle: L("Force Push", "强制推送"))
        request.items = incoming.prefix(5).map { DialogRequest.Item(title: $0.subject, detail: $0.shortHash, symbol: "minus.circle") }
        request.hiddenCount = max(0, incoming.count - 5)
        request.onConfirm = { [weak self] in
            self?.runActivity(L("Force pushing…", "正在强制推送…"), cancellable: true, in: project) { [weak self] in
                do {
                    try await Git.forcePush(branch: branch, expected: expected, in: project.url)
                    guard let self else { return }
                    self.afterBranchesChanged(project)
                    self.showToast(L("Force-pushed \(branch) to \(upstream)", "已强制推送 \(branch) 到 \(upstream)"))
                } catch is CancellationError {
                    self?.afterBranchesChanged(project)
                } catch {
                    guard let self else { return }
                    self.afterBranchesChanged(project)
                    let stale = (error as? Git.Failure)?.message.contains("stale info") == true
                    self.showFailure(L("Force push failed", "强制推送失败"), error,
                                     note: stale ? L("\(upstream) has moved on since it was last fetched, so nothing was overwritten. Fetch, look at what came in, then decide again.",
                                                     "\(upstream) 在上次获取后又有了新提交，所以没有覆盖任何内容。请先获取，看看新来的提交，再决定。")
                                                 : self.remoteNote(error))
                }
            }
        }
        ask(request)
    }

    private func performPush(branch: String, remote: String?, target: String, count: Int,
                             allowAutoPull: Bool = false, pullFirst: Bool = false, in project: Project) {
        let initialTitle = pullFirst ? L("Pulling remote commits…", "正在自动拉取远端提交…") : L("Pushing…", "正在推送…")
        runActivity(initialTitle, cancellable: true, in: project) { [weak self] in
            guard let self else { return }
            await self.runPushWithAutoPull(
                branch: branch,
                remote: remote,
                target: target,
                count: count,
                allowAutoPull: allowAutoPull,
                pullFirst: pullFirst,
                afterConflictResolution: false,
                in: project
            )
        }
    }

    private func runPushWithAutoPull(
        branch: String,
        remote: String?,
        target: String,
        count: Int,
        allowAutoPull: Bool,
        pullFirst: Bool,
        afterConflictResolution: Bool,
        in project: Project
    ) async {
        do {
            let outcome = try await Git.pushWithAutoPull(
                branch: branch,
                setUpstreamTo: remote,
                allowAutoPull: allowAutoPull,
                pullFirst: pullFirst,
                in: project.url
            ) { @MainActor [weak project] phase in
                switch phase {
                case .pushing:
                    project?.activity = L("Pushing…", "正在推送…")
                case .pulling:
                    project?.activity = L("Pulling remote commits…", "正在自动拉取远端提交…")
                }
            }
            switch outcome {
            case .pushed(let didAutoPull, let pulledCommits):
                project.pendingPushAfterPull = nil
                afterBranchesChanged(project)
                if afterConflictResolution {
                    showToast(L("Resolved conflicts and pushed to \(target)", "冲突已解决并推送到 \(target)"))
                } else if didAutoPull {
                    if pulledCommits > 0 {
                        let pulledText = pulledCommits == 1 ? L("1 commit", "1 个提交") : L("\(pulledCommits) commits", "\(pulledCommits) 个提交")
                        showToast(L("Pulled \(pulledText) and pushed to \(target)", "已自动拉取 \(pulledText)并推送到 \(target)"))
                    } else {
                        showToast(L("Auto-pulled and pushed to \(target)", "已自动拉取并推送到 \(target)"))
                    }
                } else if count == 0 {
                    showToast(L("Pushed \(branch) to \(target)", "已推送 \(branch) 到 \(target)"))
                } else {
                    showToast(count == 1 ? L("Pushed 1 commit to \(target)", "已推送 1 个提交到 \(target)")
                                         : L("Pushed \(count) commits to \(target)", "已推送 \(count) 个提交到 \(target)"))
                }
            case .conflicts(let operation, _, let autostashClash):
                project.pendingPushAfterPull = Project.PendingPushAfterPull(branch: branch, target: target, remote: remote)
                await project.refreshAndWait()
                afterBranchesChanged(project)
                if autostashClash || operation == nil {
                    handleConflictsDetected(
                        in: project,
                        title: L("Pulled · your local changes clash with what came in", "已拉取 · 本地改动与拉下来的内容冲突"),
                        note: L("Your changes also stay in git's stash until you drop it.", "你的改动也仍保存在 git 的 stash 里，直到你删除它。")
                    )
                } else {
                    handleConflictsDetected(
                        in: project,
                        title: L("Auto-pull hit conflicts · resolve to finish pushing", "自动拉取遇到冲突 · 解决后将继续推送"),
                        note: nil
                    )
                }
            case .emptyOperationStop(_, let message):
                project.pendingPushAfterPull = nil
                await project.refreshAndWait()
                afterBranchesChanged(project)
                var request = DialogRequest(
                    style: .caution,
                    symbol: "exclamationmark.triangle",
                    title: L("A commit brings in nothing new", "有个提交没有带来新的改动"),
                    message: L("Its changes are already in the branch. Skip it above the list to go on, or Abort to go back to the start.",
                               "它的改动分支里已经有了。点列表上方的“跳过”继续，或“中止”回到开始之前。"),
                    confirmTitle: L("OK", "好"),
                    cancelTitle: nil
                )
                request.output = message
                ask(request)
            case .rejectedAsBehind(let message):
                project.pendingPushAfterPull = nil
                afterBranchesChanged(project)
                var request = DialogRequest(
                    style: .caution,
                    symbol: "arrow.down.circle",
                    title: L("Push rejected: \(target) has commits you don't have", "推送被拒绝：\(target) 有你本地没有的提交"),
                    message: L("Pull them first, then push again.", "请先拉取，再推送。"),
                    confirmTitle: L("Pull", "拉取")
                )
                request.output = message
                request.onConfirm = { [weak self] in self?.pull(in: project) }
                ask(request)
            }
        } catch is CancellationError {
            project.pendingPushAfterPull = nil
            afterBranchesChanged(project)
        } catch let error as Git.PushAutoPullError {
            project.pendingPushAfterPull = nil
            afterBranchesChanged(project)
            switch error {
            case .pullFailed(let inner):
                showFailure(L("Pull failed", "拉取失败"), inner, note: remoteNote(inner))
            case .pushFailed(let inner):
                showFailure(L("Push failed", "推送失败"), inner, note: remoteNote(inner))
            }
        } catch {
            project.pendingPushAfterPull = nil
            afterBranchesChanged(project)
            showFailure(L("Push failed", "推送失败"), error, note: remoteNote(error))
        }
    }

    /// Finishes the interrupted merge/rebase and completes the pending push after all conflicts were resolved in 3-way merge.
    func resumePendingPushAfterConflictsResolved(in project: Project) {
        guard let pending = project.pendingPushAfterPull else { return }
        guard viewer.saveEdits() else { return }
        runActivity(L("Finishing merge and pushing…", "正在完成合并并推送…"), cancellable: true, in: project) { [weak self] in
            guard let self else { return }
            await project.refreshAndWait()
            let remaining = await Git.conflictedPaths(in: project.url)
            if !remaining.isEmpty {
                self.afterBranchesChanged(project)
                self.handleConflictsDetected(
                    in: project,
                    title: L("Conflicts remain · resolve to finish pushing", "仍有冲突未解决 · 解决后将继续推送"),
                    note: nil
                )
                return
            }
            guard project.status.branch == pending.branch else {
                project.pendingPushAfterPull = nil
                return
            }
            let gitDir: URL?
            if let existingGitDir = project.gitDirectory {
                gitDir = existingGitDir
            } else {
                gitDir = await Git.gitDirectory(in: project.url)
            }
            let activeOp = gitDir.flatMap { Git.operation(in: $0) }
            if activeOp == .merge || activeOp == .rebase, let op = activeOp {
                project.activity = op == .merge
                    ? L("Committing merge and pushing…", "正在提交合并并推送…")
                    : L("Continuing rebase and pushing…", "正在继续变基并推送…")
                do {
                    try await Git.continueOperation(op, in: project.url)
                } catch is CancellationError {
                    project.pendingPushAfterPull = nil
                    self.afterBranchesChanged(project)
                    return
                } catch {
                    await project.refreshAndWait()
                    self.afterBranchesChanged(project)
                    let newOp = gitDir.flatMap { Git.operation(in: $0) }
                    let clashes = await Git.conflictedPaths(in: project.url)
                    if newOp != nil, !clashes.isEmpty {
                        self.handleConflictsDetected(
                            in: project,
                            title: L("More conflicts · resolve to finish pushing", "又遇到新的冲突 · 解决后将继续推送"),
                            note: nil
                        )
                        return
                    }
                    if newOp == nil, !clashes.isEmpty {
                        self.handleConflictsDetected(
                            in: project,
                            title: L("Pulled · your local changes clash with what came in", "已拉取 · 本地改动与拉下来的内容冲突"),
                            note: L("Your changes also stay in git's stash until you drop it.", "你的改动也仍保存在 git 的 stash 里，直到你删除它。")
                        )
                        return
                    }
                    project.pendingPushAfterPull = nil
                    self.showFailure(L("Could not continue the \(op.command)", "无法继续 \(op.command)"), error)
                    return
                }
                if op == .merge {
                    project.lastCommit = nil
                    if !project.excludedLines.isEmpty { project.excludedLines = [:] }
                    if project.aiGroupSessions.contains(where: \.isCommittable) {
                        self.clearWorkingTreeAIGroups(for: project)
                    }
                }
                let postClashes = await Git.conflictedPaths(in: project.url)
                if !postClashes.isEmpty {
                    await project.refreshAndWait()
                    self.afterBranchesChanged(project)
                    self.handleConflictsDetected(
                        in: project,
                        title: L("Pulled · your local changes clash with what came in", "已拉取 · 本地改动与拉下来的内容冲突"),
                        note: L("Your changes also stay in git's stash until you drop it.", "你的改动也仍保存在 git 的 stash 里，直到你删除它。")
                    )
                    return
                }
            } else if activeOp != nil {
                project.pendingPushAfterPull = nil
                return
            }

            await project.refreshAndWait()
            let outgoing = await Git.outgoingCommits(upstream: project.status.upstream, remote: pending.remote, in: project.url)
            await self.runPushWithAutoPull(
                branch: pending.branch,
                remote: pending.remote,
                target: pending.target,
                count: outgoing.count,
                allowAutoPull: pending.remote == nil,
                pullFirst: false,
                afterConflictResolution: true,
                in: project
            )
        }
    }

    // MARK: Merge or rebase in progress

    /// Continue in the banner: the rebase, cherry-pick or revert goes on; a merge is finished by committing it.
    func continueOperation(in project: Project? = nil) {
        guard let project = project ?? currentProject, let operation = project.status.operation else { return }
        guard project.status.conflictCount == 0 else {
            showToast(L("Resolve the conflicts first", "请先解决冲突"))
            return
        }
        project.pendingPushAfterPull = nil
        if operation == .merge {
            focusCommitMessage()
            commitCurrent()
            return
        }
        guard viewer.saveEdits() else { return }
        runActivity(L("Continuing the \(operation.command)…", "正在继续 \(operation.command)…"), in: project) { [weak self] in
            do {
                try await Git.continueOperation(operation, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showToast(L("Done", "已完成"))
            } catch {
                guard let self else { return }
                self.afterBranchesChanged(project)
                if let directory = project.gitDirectory, Git.operation(in: directory) != nil,
                   let clashes = try? await Git.runString(["diff", "--name-only", "--diff-filter=U"], in: project.url),
                   !clashes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.handleConflictsDetected(in: project, title: L("Stopped at more conflicts", "又在冲突处停下了"), note: nil)
                } else {
                    self.showFailure(L("Could not continue the \(operation.command)", "无法继续 \(operation.command)"), error)
                }
            }
        }
    }

    /// Abort in the banner: back to how things were before the merge or rebase started.
    func abortOperation(in project: Project? = nil) {
        guard let project = project ?? currentProject, let operation = project.status.operation else { return }
        var request = DialogRequest(style: .destructive, symbol: "xmark.octagon",
                                    title: L("Abort the \(operation.command)?", "中止 \(operation.command)？"),
                                    message: L("The branch goes back to where it was before the \(operation.command) started, and what it brought in is dropped, conflict resolutions included.",
                                               "分支会回到 \(operation.command) 开始之前的状态，它带来的改动（包括已解决的冲突）都会丢弃。"),
                                    confirmTitle: L("Abort", "中止"))
        request.onConfirm = { [weak self] in
            self?.runActivity(L("Aborting…", "正在中止…"), in: project) { [weak self] in
                do {
                    try await Git.abortOperation(operation, in: project.url)
                    project.pendingPushAfterPull = nil
                    self?.afterBranchesChanged(project)
                    self?.showToast(L("Aborted · back to where you were", "已中止 · 回到了开始之前"))
                } catch {
                    self?.afterBranchesChanged(project)
                    self?.showFailure(L("Could not abort the \(operation.command)", "无法中止 \(operation.command)"), error)
                }
            }
        }
        ask(request)
    }
}

// MARK: - Conflicts

extension AppStore {
    /// Tells git the file is resolved. Asks first if it still has conflict markers in it.
    func markResolved(_ path: String, in project: Project) {
        guard viewer.saveEdits() else { return }
        let url = project.url.appendingPathComponent(path)
        let resolve: () -> Void = { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    try await Git.markResolved([path], in: project.url)
                    project.refresh()
                    self?.showToast(L("Marked \((path as NSString).lastPathComponent) as resolved", "已将 \((path as NSString).lastPathComponent) 标记为已解决"))
                } catch {
                    self?.showFailure(L("Could not mark it as resolved", "无法标记为已解决"), error)
                }
            }
        }
        if let data = try? Data(contentsOf: url), Git.hasConflictMarkers(data) {
            var request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle",
                                        title: L("\((path as NSString).lastPathComponent) still has conflict markers", "\((path as NSString).lastPathComponent) 里还有冲突标记"),
                                        message: L("Lines starting with <<<<<<< or >>>>>>> are still in the file. Mark it as resolved anyway?",
                                                   "文件里还有以 <<<<<<< 或 >>>>>>> 开头的行。仍然标记为已解决？"),
                                        confirmTitle: L("Mark as Resolved", "标记为已解决"))
            request.onConfirm = { resolve() }
            ask(request)
        } else {
            resolve()
        }
    }

    /// Resolves a file by taking HEAD's version, or the incoming one, whole.
    func takeSide(_ side: ConflictSide, path: String, in project: Project) {
        let name = (path as NSString).lastPathComponent
        var request = DialogRequest(style: .caution, symbol: "arrow.triangle.merge",
                                    title: side == .ours ? L("Keep HEAD’s version of \(name)?", "保留 HEAD 版本的 \(name)？")
                                                         : L("Take the incoming version of \(name)?", "采用传入版本的 \(name)？"),
                                    message: L("The other side’s changes to this file are dropped, and so are edits made to it during the merge.",
                                               "另一边对这个文件的改动会被丢弃，合并过程中对它的编辑也会丢弃。"),
                                    confirmTitle: side == .ours ? L("Keep HEAD’s", "保留 HEAD 的") : L("Take Incoming", "采用传入的"))
        request.onConfirm = { [weak self] in
            Task { @MainActor [weak self] in
                do {
                    try await Git.takeSide(side, path: path, in: project.url)
                    project.refresh()
                    self?.syncViewer()
                    self?.showToast(L("Resolved \(name)", "已解决 \(name)"))
                } catch {
                    self?.showFailure(L("Could not resolve \(name)", "无法解决 \(name)"), error)
                }
            }
        }
        ask(request)
    }
}

// MARK: - Tags

extension AppStore {
    /// Opens a dialog to create a local tag (lightweight or annotated) at `start` (HEAD when nil).
    func newTag(from start: String? = nil, startTitle: String? = nil, in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        let target = start ?? "HEAD"
        Task { @MainActor [weak self] in
            guard await Git.resolveCommit(target, in: project.url) != nil else {
                self?.showToast(L("Cannot create a tag · this repository has no commits yet", "无法创建标签 · 该仓库还没有任何提交"))
                return
            }
            let existing = Set(((try? await Git.refs(in: project.url)) ?? []).filter { $0.kind == .tag }.map(\.shortName))
            guard let self else { return }
            let targetLabel = startTitle ?? project.status.branch.map { "HEAD (\($0))" } ?? "HEAD"
            let form = TagDialogForm(targetLabel: targetLabel, existingTagNames: existing)
            var request = DialogRequest(style: .info, symbol: "tag",
                                        title: startTitle.map { L("New tag on \($0)", "在 \($0) 上新建标签") } ?? L("New tag", "新建标签"),
                                        message: L("Creates a tag on \(targetLabel). Add a message for an annotated tag, or leave it empty for a lightweight tag.",
                                                   "将在 \(targetLabel) 上创建标签。填写附注消息可创建附注标签，留空则创建轻量标签。"),
                                        confirmTitle: L("Create", "创建"))
            request.tagForm = form
            request.onConfirm = { [weak self] in
                let name = form.trimmedName
                let message = form.trimmedMessage
                self?.createTag(name, at: target, message: message.isEmpty ? nil : message, in: project)
            }
            self.ask(request)
        }
    }

    private func createTag(_ name: String, at target: String, message: String?, in project: Project) {
        runActivity(L("Creating tag \(name)…", "正在创建标签 \(name)…"), in: project) { [weak self] in
            do {
                try await Git.createTag(name, at: target, message: message, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showToast(L("Created tag \(name)", "已创建标签 \(name)"))
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not create tag \(name)", "无法创建标签 \(name)"), error)
            }
        }
    }

    /// Prompts for a new name and renames a local tag, preserving lightweight vs annotated type and message.
    func renameTag(_ ref: GitRef, in project: Project) {
        guard ref.kind == .tag else { return }
        Task { @MainActor [weak self] in
            let existing = Set(((try? await Git.refs(in: project.url)) ?? []).filter { $0.kind == .tag && $0.name != ref.name }.map(\.shortName))
            let info = try? await Git.tagInfo(ref.shortName, in: project.url)
            guard let self else { return }
            let message = info?.isAnnotated == true
                ? L("The annotated tag's message and tagger details are preserved. Remote tags are not changed.",
                    "附注标签的消息和创建者信息会被保留，不会修改远程标签。")
                : L("Renames the local tag. Remote tags are not changed.",
                    "重命名本地标签，不会修改远程标签。")
            var request = DialogRequest(style: .info, symbol: "pencil",
                                        title: L("Rename tag \(ref.shortName)", "重命名标签 \(ref.shortName)"),
                                        message: message,
                                        confirmTitle: L("Rename", "重命名"))
            request.input = .init(placeholder: L("Tag name", "标签名"), text: ref.shortName, problem: { candidate in
                let trimmed = candidate.trimmingCharacters(in: .whitespaces)
                if trimmed == ref.shortName {
                    return L("Enter a different tag name", "请输入不同的标签名")
                }
                return Git.tagNameProblem(trimmed, existing: existing)
            })
            request.onSubmit = { [weak self] newName in
                guard newName != ref.shortName else { return }
                self?.performRenameTag(ref.shortName, to: newName, in: project, undoable: true)
            }
            self.ask(request)
        }
    }

    private func performRenameTag(_ oldName: String, to newName: String, in project: Project, undoable: Bool) {
        runActivity(L("Renaming tag \(oldName)…", "正在重命名标签 \(oldName)…"), in: project) { [weak self] in
            do {
                try await Git.renameTag(oldName, to: newName, in: project.url)
                guard let self else { return }
                self.syncTagSelectionAfterRename(oldName, to: newName, in: project)
                self.afterBranchesChanged(project)
                let text = L("Renamed tag \(oldName) to \(newName)", "已将标签 \(oldName) 重命名为 \(newName)")
                if undoable {
                    self.showToast(text, action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                        self?.performRenameTag(newName, to: oldName, in: project, undoable: false)
                    })
                } else {
                    self.showToast(text)
                }
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not rename tag \(oldName)", "无法重命名标签 \(oldName)"), error)
            }
        }
    }

    /// Confirms and deletes a local tag; Undo in the toast restores it (including annotation metadata).
    func deleteTag(_ ref: GitRef, in project: Project) {
        guard ref.kind == .tag else { return }
        var request = DialogRequest(style: .destructive, symbol: "trash",
                                    title: L("Delete tag \(ref.shortName)?", "删除标签 \(ref.shortName)？"),
                                    message: L("The local tag is removed. The commit itself stays, and remote tags are not changed.",
                                               "将删除本地标签。提交本身不受影响，远程标签也不会改变。"),
                                    confirmTitle: L("Delete", "删除"))
        request.onConfirm = { [weak self] in
            self?.runActivity(L("Deleting tag \(ref.shortName)…", "正在删除标签 \(ref.shortName)…"), in: project) { [weak self] in
                let backup = try? await Git.tagInfo(ref.shortName, in: project.url)
                do {
                    try await Git.deleteTag(ref.shortName, in: project.url)
                    guard let self else { return }
                    self.syncTagSelectionAfterDelete(ref.shortName, in: project)
                    self.afterBranchesChanged(project)
                    let text = L("Deleted tag \(ref.shortName)", "已删除标签 \(ref.shortName)")
                    if let backup {
                        self.showToast(text, action: ToastAction(title: L("Undo", "撤销")) { [weak self] in
                            self?.restoreTag(backup, in: project)
                        })
                    } else {
                        self.showToast(text)
                    }
                } catch {
                    self?.afterBranchesChanged(project)
                    self?.showFailure(L("Could not delete tag \(ref.shortName)", "无法删除标签 \(ref.shortName)"), error)
                }
            }
        }
        ask(request)
    }

    private func restoreTag(_ info: GitTagInfo, in project: Project) {
        runActivity(L("Restoring tag \(info.name)…", "正在恢复标签 \(info.name)…"), in: project) { [weak self] in
            do {
                try await Git.restoreTag(info, in: project.url)
                guard let self else { return }
                self.afterBranchesChanged(project)
                self.showToast(L("Restored tag \(info.name)", "已恢复标签 \(info.name)"))
            } catch {
                self?.afterBranchesChanged(project)
                self?.showFailure(L("Could not restore tag \(info.name)", "无法恢复标签 \(info.name)"), error)
            }
        }
    }

    private func syncTagSelectionAfterRename(_ oldName: String, to newName: String, in project: Project) {
        let oldRef = "refs/tags/\(oldName)"
        let newRef = "refs/tags/\(newName)"
        var touched = false
        if project.logRef == oldRef {
            project.logRef = newRef
            touched = true
        }
        for i in project.logTabs.indices where project.logTabs[i].logRef == oldRef {
            project.logTabs[i].logRef = newRef
            touched = true
        }
        if touched { schedulePersistLogState(for: project) }
        if gitGraph.projectID == project.id, gitGraph.scope == .ref(oldRef) {
            gitGraph.scope = .ref(newRef)
            gitGraph.selectedBranchID = "ref:" + newRef
        }
    }

    private func syncTagSelectionAfterDelete(_ name: String, in project: Project) {
        let deletedRef = "refs/tags/\(name)"
        var touched = false
        if project.logRef == deletedRef {
            project.logRef = nil
            touched = true
        }
        for i in project.logTabs.indices where project.logTabs[i].logRef == deletedRef {
            project.logTabs[i].logRef = nil
            touched = true
        }
        if touched { schedulePersistLogState(for: project) }
        if gitGraph.projectID == project.id, gitGraph.scope == .ref(deletedRef) {
            gitGraph.scope = .all
            gitGraph.selectedBranchID = "scope:all"
        }
    }
}
