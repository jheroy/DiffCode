import AppKit
import Foundation

/// Creating and removing linked Git work trees from the sidebar.
extension AppStore {
    /// Opens the New Worktree dialog targeting `project`'s main repository.
    func presentNewWorktree(for project: Project) {
        guard !project.needsAccess, !gitMissing else { return }
        let ownerProject = project.worktreeOf.flatMap { self.project($0) } ?? (project.worktreeOf == nil ? project : nil)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mainURL: URL
            if let ownerProject {
                mainURL = ownerProject.url
            } else {
                mainURL = (await Git.mainWorktreeRoot(for: project.url)) ?? project.url
            }
            let mainProject = ownerProject ?? self.projects.first {
                Self.canonicalPath($0.url) == Self.canonicalPath(mainURL)
            }
            async let refsTask = (try? await Git.refs(in: mainURL)) ?? []
            async let worktreesTask = Git.worktrees(in: mainURL)
            let refs = await refsTask
            let worktrees = await worktreesTask

            let localRefs = refs.filter { $0.kind == .local }
            let remoteRefs = refs.filter { $0.kind == .remote }
            let localNames = Set(localRefs.map(\.shortName))
            let currentBranch = localRefs.first(where: \.isHead)?.shortName ?? mainProject?.status.branch

            let checkedOut: Set<String> = Set(worktrees.compactMap { entry in
                guard !entry.isPrunable, let branch = entry.branch, branch.hasPrefix("refs/heads/") else { return nil }
                return String(branch.dropFirst("refs/heads/".count))
            })

            let baseRefChoices = localRefs.map(\.shortName) + remoteRefs.map(\.shortName)
            var existingChoices: [WorktreeDialogForm.ExistingBranchOption] = localRefs
                .filter { !checkedOut.contains($0.shortName) }
                .map { .init(refName: $0.shortName, localName: $0.shortName, isRemote: false) }

            var seenRemoteLocals = Set<String>()
            for ref in remoteRefs {
                let local = Git.localBranchName(forRemote: ref.shortName)
                guard !localNames.contains(local), seenRemoteLocals.insert(local).inserted else { continue }
                existingChoices.append(.init(refName: ref.shortName, localName: local, isRemote: true))
            }

            let form = WorktreeDialogForm(
                repoURL: mainURL,
                currentBranch: currentBranch,
                baseRefChoices: baseRefChoices,
                existingLocalNames: localNames,
                existingBranchChoices: existingChoices
            )
            var request = DialogRequest(
                style: .info,
                symbol: "square.on.square",
                title: L("New Worktree", "新建工作树"),
                message: L("Create a linked work tree for \(form.repoName).", "为 \(form.repoName) 创建一个新的工作树。"),
                confirmTitle: L("Create", "创建")
            )
            request.worktreeForm = form
            request.onConfirm = { [weak self] in
                self?.createWorktree(from: form, mainProject: mainProject)
            }
            self.ask(request)
        }
    }

    /// Lets the user pick a parent folder for a new work tree inside the New Worktree dialog.
    func chooseWorktreeParentFolder(for form: WorktreeDialogForm) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = form.baseDirectory
        panel.prompt = L("Choose", "选择")
        panel.message = L("Choose the folder where the new work tree will be created.", "选择用于存放新工作树的父目录。")
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url {
                form.chooseParentFolder(url)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    private func createWorktree(from form: WorktreeDialogForm, mainProject: Project?) {
        let repoURL = form.repoURL
        let destination = form.resolvedURL
        let branch: String
        let createBranch: Bool
        let baseRef: String?

        switch form.mode {
        case .newBranch:
            branch = form.newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
            createBranch = true
            baseRef = form.baseRef.isEmpty ? nil : form.baseRef
        case .existingBranch:
            guard let option = form.selectedExistingOption else { return }
            if option.isRemote {
                branch = option.localName
                createBranch = true
                baseRef = option.refName
            } else {
                branch = option.refName
                createBranch = false
                baseRef = nil
            }
        }

        let perform: @MainActor () async -> Void = { [weak self] in
            guard let self else { return }
            let parentDir = destination.deletingLastPathComponent()
            if FolderAccess.shared.isNeeded, !FolderAccess.shared.covers(parentDir.path) {
                let granted = await self.requestWorktreeFolderAccess(parentDir)
                guard granted else {
                    self.showToast(L("Folder access is needed to create the work tree there",
                                     "需要授权访问该文件夹才能在那里创建工作树"))
                    return
                }
            }
            do {
                try await Git.addWorktree(
                    in: repoURL,
                    at: destination,
                    branch: branch,
                    createBranch: createBranch,
                    baseRef: baseRef
                )
                await self.registerCreatedWorktree(at: destination, under: mainProject)
                self.showToast(L("Created work tree \(destination.lastPathComponent)",
                                 "已创建工作树 \(destination.lastPathComponent)"))
            } catch {
                self.showFailure(L("Could not create work tree", "无法创建工作树"), error)
            }
        }

        if let mainProject {
            runActivity(L("Creating work tree…", "正在创建工作树…"), in: mainProject, perform)
        } else {
            Task { @MainActor in await perform() }
        }
    }

    /// Expands the parent repository, refreshes its work tree list, and selects the newly created work tree.
    private func registerCreatedWorktree(at destination: URL, under mainProject: Project?) async {
        let targetKey = Self.canonicalPath(destination)
        if let mainProject, projects.contains(where: { $0.id == mainProject.id }) {
            collapsedProjects.remove(mainProject.url.path)
            syncWorktrees(of: mainProject, force: true)
            afterBranchesChanged(mainProject)

            // Wait briefly for `syncWorktrees`'s async task to install the derived work tree entry.
            for _ in 0..<50 {
                if let created = projects.first(where: { Self.canonicalPath($0.url) == targetKey }) {
                    select(created)
                    return
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        // Fallback when the main repository isn't listed (e.g. a standalone linked work tree) or hasn't loaded yet.
        if let existing = projects.first(where: { Self.canonicalPath($0.url) == targetKey }) {
            select(existing)
        } else {
            addProjects([destination])
        }
    }

    /// Asks for confirmation before removing a linked work tree from Git and deleting its folder from disk.
    /// Offers an optional checkbox to also delete its local branch, and shows a second destructive confirmation
    /// whenever uncommitted changes or unmerged commits on the branch to be deleted are detected.
    func confirmDeleteWorktree(_ project: Project) {
        // Never allow deleting a main repository via Delete Worktree.
        guard project.worktreeOf != nil, !project.needsAccess, !gitMissing else { return }
        let parentProject = project.worktreeOf.flatMap { self.project($0) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolvedParentURL: URL?
            if let parentURL = parentProject?.url {
                resolvedParentURL = parentURL
            } else {
                resolvedParentURL = await Git.mainWorktreeRoot(for: project.url)
            }
            guard let parentURL = resolvedParentURL, Self.canonicalPath(parentURL) != Self.canonicalPath(project.url) else {
                self.showToast(L("Cannot delete the main repository as a work tree", "不能将主仓库作为工作树删除"))
                return
            }

            let worktreeExists = FileManager.default.fileExists(atPath: project.url.path)
            async let worktreeBranchTask = Worktree.currentBranch(in: project.url)
            async let mainBranchTask = Worktree.currentBranch(in: parentURL)
            let liveWorktreeBranch = await worktreeBranchTask
            let worktreeBranch = worktreeExists ? liveWorktreeBranch : project.status.branch
            let mainBranch = await mainBranchTask

            // Only offer branch deletion for a local branch checked out in this work tree
            // that is not currently checked out in the main repository.
            let deletableBranch: String? = {
                guard let branch = worktreeBranch, !branch.isEmpty, branch != mainBranch else { return nil }
                return branch
            }()

            let message: String
            if deletableBranch != nil {
                message = L(
                    "This removes the work tree and deletes its folder from disk. You can also choose to delete its local branch below.\n\n\(project.url.path)",
                    "这将移除该工作树并从磁盘删除其目录。你也可以在下方选择是否同时删除对应本地分支。\n\n\(project.url.path)"
                )
            } else {
                message = L(
                    "This removes the work tree and deletes its folder from disk.\n\n\(project.url.path)",
                    "这将移除该工作树并从磁盘删除其目录。\n\n\(project.url.path)"
                )
            }

            var request = DialogRequest(
                style: .destructive,
                symbol: "trash",
                title: L("Delete work tree “\(project.name)”?", "删除工作树“\(project.name)”？"),
                message: message,
                confirmTitle: L("Delete Worktree", "删除工作树")
            )
            if let deletableBranch {
                request.option = .init(
                    title: L("Also delete branch \"\(deletableBranch)\"", "同时删除分支「\(deletableBranch)」"),
                    isOn: false,
                    required: false
                )
            }
            request.onAnswer = { [weak self] answer in
                let branchToDelete = answer.option ? deletableBranch : nil
                self?.handleDeleteWorktreeConfirmation(
                    project,
                    parentURL: parentURL,
                    parentProject: parentProject,
                    worktreeBranch: worktreeBranch,
                    deleteBranch: branchToDelete
                )
            }
            self.ask(request)
        }
    }

    /// Inspects the live work tree and branch state after the first confirmation and either removes immediately
    /// (when safe) or presents a second destructive confirmation detailing every detected risk.
    private func handleDeleteWorktreeConfirmation(
        _ project: Project,
        parentURL: URL,
        parentProject: Project?,
        worktreeBranch: String?,
        deleteBranch: String?
    ) {
        guard project.worktreeOf != nil, Self.canonicalPath(parentURL) != Self.canonicalPath(project.url) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let inspection = await Worktree.inspectRemoval(
                worktreeURL: project.url,
                repoRoot: parentURL,
                branchName: deleteBranch ?? worktreeBranch
            )
            if inspection.requiresForceConfirmation(deleteBranch: deleteBranch != nil) {
                let changes: [FileChange]
                if inspection.hasUncommittedChanges {
                    changes = (try? await Git.status(in: project.url, gitDirectory: project.gitDirectory))?.changes
                        ?? project.changes
                } else {
                    changes = []
                }
                self.presentForceDeleteWorktreeConfirmation(
                    project,
                    parentURL: parentURL,
                    parentProject: parentProject,
                    inspection: inspection,
                    deleteBranch: deleteBranch,
                    changes: changes
                )
            } else {
                self.performDeleteWorktree(
                    project,
                    parentURL: parentURL,
                    parentProject: parentProject,
                    forceWorktree: false,
                    deleteBranch: deleteBranch,
                    forceBranch: false
                )
            }
        }
    }

    private func presentForceDeleteWorktreeConfirmation(
        _ project: Project,
        parentURL: URL,
        parentProject: Project?,
        inspection: WorktreeRemovalInspection,
        deleteBranch: String?,
        changes: [FileChange]
    ) {
        let hasDirty = inspection.hasUncommittedChanges
        let hasUnmerged = deleteBranch != nil && inspection.hasUnmergedCommits

        var warnings: [String] = []
        if hasDirty {
            let count = inspection.uncommittedChangeCount
            warnings.append(L(
                count == 1
                    ? "This work tree still has 1 uncommitted change, which will be permanently lost after force deletion."
                    : "This work tree still has \(count) uncommitted changes, which will be permanently lost after force deletion.",
                "该 Worktree 仍有 \(count) 项未提交变更，强制删除后将永久丢失。"
            ))
        }
        if hasUnmerged, let branch = deleteBranch {
            let count = inspection.unmergedCommitCount
            warnings.append(L(
                count == 1
                    ? "Branch \"\(branch)\" contains 1 unmerged commit, which may be unrecoverable after force deletion."
                    : "Branch \"\(branch)\" contains \(count) unmerged commits, which may be unrecoverable after force deletion.",
                "分支「\(branch)」包含 \(count) 个未合并提交，强制删除后这些提交可能无法找回。"
            ))
        }

        let title: String
        if hasDirty && hasUnmerged {
            title = L("Confirm force deletion of “\(project.name)”?", "确认强制删除“\(project.name)”？")
        } else if hasDirty {
            title = L("“\(project.name)” has uncommitted changes", "“\(project.name)”包含未提交变更")
        } else if let branch = deleteBranch {
            title = L("Branch “\(branch)” has unmerged commits", "分支「\(branch)」包含未合并提交")
        } else {
            title = L("Confirm force deletion of “\(project.name)”?", "确认强制删除“\(project.name)”？")
        }

        let message: String
        if let branch = deleteBranch {
            message = L(
                "Force deleting work tree “\(project.name)” and branch \"\(branch)\" cannot be undone.\n\n\(project.url.path)",
                "强制删除工作树“\(project.name)”及分支「\(branch)」后无法撤销，请再次确认。\n\n\(project.url.path)"
            )
        } else {
            message = L(
                "Force deleting work tree “\(project.name)” will permanently discard local changes and remove its folder from disk.\n\n\(project.url.path)",
                "强制删除工作树“\(project.name)”将永久丢弃本地变更并从磁盘移除该目录，请再次确认。\n\n\(project.url.path)"
            )
        }

        var request = DialogRequest(
            style: .destructive,
            symbol: "exclamationmark.triangle",
            title: title,
            message: message,
            confirmTitle: L("Force Delete", "强制删除")
        )
        request.warnings = warnings
        if hasDirty && !changes.isEmpty {
            (request.items, request.hiddenCount) = DialogRequest.files(changes, limit: 5)
        }
        request.onConfirm = { [weak self] in
            self?.performDeleteWorktree(
                project,
                parentURL: parentURL,
                parentProject: parentProject,
                forceWorktree: hasDirty,
                deleteBranch: deleteBranch,
                forceBranch: hasUnmerged
            )
        }
        ask(request)
    }

    private func performDeleteWorktree(
        _ project: Project,
        parentURL: URL,
        parentProject: Project?,
        forceWorktree: Bool,
        deleteBranch: String?,
        forceBranch: Bool
    ) {
        guard project.worktreeOf != nil, Self.canonicalPath(parentURL) != Self.canonicalPath(project.url) else { return }
        // Release the file watcher before git removes the directory.
        project.stopWatching()

        let owner = parentProject ?? project
        runActivity(L("Deleting work tree…", "正在删除工作树…"), in: owner) { [weak self] in
            do {
                try await Worktree.remove(
                    worktreeURL: project.url,
                    repoRoot: parentURL,
                    forceWorktree: forceWorktree,
                    deleteBranch: deleteBranch,
                    forceBranch: forceBranch
                )
                guard let self else { return }
                let name = project.name
                self.finishRemovedWorktree(project, parentProject: parentProject)
                if let branch = deleteBranch {
                    self.showToast(L("Deleted work tree \(name) and branch \(branch)",
                                     "已删除工作树 \(name) 及分支「\(branch)」"))
                } else {
                    self.showToast(L("Deleted work tree \(name)", "已删除工作树 \(name)"))
                }
            } catch let removalError as Worktree.RemovalError {
                guard let self else { return }
                switch removalError.stage {
                case .worktree:
                    project.startWatching()
                    project.refresh()
                    if !forceWorktree, let failure = removalError.underlying as? Git.Failure,
                       Git.worktreeRemoveNeedsForce(failure.message) {
                        self.offerForceDeleteWorktree(
                            project,
                            parentURL: parentURL,
                            parentProject: parentProject,
                            deleteBranch: deleteBranch,
                            forceBranch: forceBranch,
                            error: failure
                        )
                    } else {
                        self.showFailure(
                            L("Could not delete work tree “\(project.name)”", "无法删除工作树“\(project.name)”"),
                            removalError.underlying
                        )
                    }
                case .branch(let branch):
                    // The work tree itself was already removed; still remove it from the sidebar and refresh.
                    let name = project.name
                    self.finishRemovedWorktree(project, parentProject: parentProject)
                    if !forceBranch, let failure = removalError.underlying as? Git.Failure,
                       Git.isNotFullyMerged(failure.message) {
                        self.offerForceDeleteBranchAfterWorktreeRemoval(
                            worktreeName: name,
                            branch: branch,
                            parentURL: parentURL,
                            parentProject: parentProject,
                            error: failure
                        )
                    } else {
                        self.showFailure(
                            L("Deleted work tree “\(name)”, but could not delete branch \"\(branch)\"",
                              "已删除工作树“\(name)”，但无法删除分支「\(branch)」"),
                            removalError.underlying
                        )
                    }
                }
            } catch {
                guard let self else { return }
                project.startWatching()
                project.refresh()
                self.showFailure(L("Could not delete work tree “\(project.name)”", "无法删除工作树“\(project.name)”"), error)
            }
        }
    }

    private func finishRemovedWorktree(_ project: Project, parentProject: Project?) {
        remove(project)
        if let parentProject, projects.contains(where: { $0.id == parentProject.id }) {
            syncWorktrees(of: parentProject, force: true)
            afterBranchesChanged(parentProject)
        }
    }

    private func offerForceDeleteWorktree(
        _ project: Project,
        parentURL: URL,
        parentProject: Project?,
        deleteBranch: String?,
        forceBranch: Bool,
        error: Git.Failure
    ) {
        var request = DialogRequest(
            style: .destructive,
            symbol: "exclamationmark.triangle",
            title: L("“\(project.name)” has uncommitted changes", "“\(project.name)”包含未提交的改动"),
            message: L("Git refused to remove this work tree cleanly. Force delete to discard local changes and remove its folder from disk?\n\n\(project.url.path)",
                       "Git 拒绝直接移除此工作树。要强制删除以丢弃本地改动并移除磁盘目录吗？\n\n\(project.url.path)"),
            confirmTitle: L("Force Delete", "强制删除")
        )
        request.output = error.message
        request.onConfirm = { [weak self] in
            self?.performDeleteWorktree(
                project,
                parentURL: parentURL,
                parentProject: parentProject,
                forceWorktree: true,
                deleteBranch: deleteBranch,
                forceBranch: forceBranch
            )
        }
        ask(request)
    }

    private func offerForceDeleteBranchAfterWorktreeRemoval(
        worktreeName: String,
        branch: String,
        parentURL: URL,
        parentProject: Project?,
        error: Git.Failure
    ) {
        var request = DialogRequest(
            style: .destructive,
            symbol: "exclamationmark.triangle",
            title: L("Branch “\(branch)” is not fully merged", "分支「\(branch)」尚未完全合并"),
            message: L("Work tree “\(worktreeName)” was deleted, but Git refused to delete branch \"\(branch)\" because it is not fully merged. Force delete this branch anyway?",
                       "工作树“\(worktreeName)”已删除，但 Git 拒绝安全删除分支「\(branch)」，因为它尚未完全合并。要强制删除该分支吗？"),
            confirmTitle: L("Force Delete", "强制删除")
        )
        request.output = error.message
        request.onConfirm = { [weak self] in
            self?.forceDeleteBranchAfterWorktreeRemoval(branch, parentURL: parentURL, parentProject: parentProject)
        }
        ask(request)
    }

    private func forceDeleteBranchAfterWorktreeRemoval(
        _ branch: String,
        parentURL: URL,
        parentProject: Project?
    ) {
        let perform: @MainActor () async -> Void = { [weak self] in
            do {
                try await Git.deleteBranch(branch, force: true, in: parentURL)
                guard let self else { return }
                if let parentProject, self.projects.contains(where: { $0.id == parentProject.id }) {
                    self.afterBranchesChanged(parentProject)
                }
                self.showToast(L("Deleted branch \(branch)", "已删除分支「\(branch)」"))
            } catch {
                guard let self else { return }
                if let parentProject, self.projects.contains(where: { $0.id == parentProject.id }) {
                    self.afterBranchesChanged(parentProject)
                }
                self.showFailure(L("Could not delete branch \"\(branch)\"", "无法删除分支「\(branch)」"), error)
            }
        }
        if let parentProject, projects.contains(where: { $0.id == parentProject.id }) {
            runActivity(L("Deleting branch \(branch)…", "正在删除分支「\(branch)」…"), in: parentProject, perform)
        } else {
            Task { @MainActor in await perform() }
        }
    }

    private func requestWorktreeFolderAccess(_ folder: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            FolderAccess.shared.requestAccess(
                to: folder,
                message: L("\(appName) needs access to “\(folder.lastPathComponent)” to create a work tree there.",
                           "\(appName) 需要访问「\(folder.lastPathComponent)」才能在其中创建工作树。"),
                window: window
            ) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
