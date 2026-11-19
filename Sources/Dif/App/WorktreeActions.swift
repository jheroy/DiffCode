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

            let fresh = try? await Git.status(in: project.url, gitDirectory: project.gitDirectory)
            let changes = fresh?.changes ?? project.changes
            let branchLabel = fresh?.branch ?? project.branchLabel
            let isDirty = !changes.isEmpty

            var request: DialogRequest
            if isDirty {
                let countText = changes.count == 1
                    ? L("1 uncommitted change", "1 处未提交的改动")
                    : L("\(changes.count) uncommitted changes", "\(changes.count) 处未提交的改动")
                request = DialogRequest(
                    style: .destructive,
                    symbol: "trash",
                    title: L("Delete work tree “\(project.name)”?", "删除工作树“\(project.name)”？"),
                    message: L("This work tree on “\(branchLabel)” has \(countText). Force deleting permanently discards those changes and deletes its folder from disk.\n\n\(project.url.path)",
                               "位于“\(branchLabel)”分支的该工作树有 \(countText)。强制删除会永久丢弃这些改动并从磁盘移除该目录。\n\n\(project.url.path)"),
                    confirmTitle: L("Force Delete", "强制删除")
                )
                (request.items, request.hiddenCount) = DialogRequest.files(changes, limit: 5)
                request.option = .init(
                    title: L("Force delete and discard uncommitted changes", "强制删除并丢弃未提交的改动"),
                    isOn: false,
                    required: true
                )
                request.onAnswer = { [weak self] answer in
                    self?.performDeleteWorktree(project, parentURL: parentURL, parentProject: parentProject, force: answer.option)
                }
            } else {
                request = DialogRequest(
                    style: .destructive,
                    symbol: "trash",
                    title: L("Delete work tree “\(project.name)”?", "删除工作树“\(project.name)”？"),
                    message: L("This removes the work tree and deletes its folder from disk. Branch “\(branchLabel)” is kept in Git.\n\n\(project.url.path)",
                               "这将移除该工作树并从磁盘删除其目录。分支“\(branchLabel)”会保留在 Git 中。\n\n\(project.url.path)"),
                    confirmTitle: L("Delete Worktree", "删除工作树")
                )
                request.onConfirm = { [weak self] in
                    self?.performDeleteWorktree(project, parentURL: parentURL, parentProject: parentProject, force: false)
                }
            }
            self.ask(request)
        }
    }

    private func performDeleteWorktree(_ project: Project, parentURL: URL, parentProject: Project?, force: Bool) {
        guard project.worktreeOf != nil, Self.canonicalPath(parentURL) != Self.canonicalPath(project.url) else { return }
        // Release the file watcher before git removes the directory.
        project.stopWatching()

        let owner = parentProject ?? project
        runActivity(L("Deleting work tree…", "正在删除工作树…"), in: owner) { [weak self] in
            do {
                try await Git.removeWorktree(in: parentURL, at: project.url, force: force)
                guard let self else { return }
                let name = project.name
                self.remove(project)
                if let parentProject, self.projects.contains(where: { $0.id == parentProject.id }) {
                    self.syncWorktrees(of: parentProject, force: true)
                    self.afterBranchesChanged(parentProject)
                }
                self.showToast(L("Deleted work tree \(name)", "已删除工作树 \(name)"))
            } catch {
                guard let self else { return }
                project.startWatching()
                project.refresh()
                if !force, let failure = error as? Git.Failure, Git.worktreeRemoveNeedsForce(failure.message) {
                    self.offerForceDeleteWorktree(project, parentURL: parentURL, parentProject: parentProject, error: failure)
                } else {
                    self.showFailure(L("Could not delete work tree “\(project.name)”", "无法删除工作树“\(project.name)”"), error)
                }
            }
        }
    }

    private func offerForceDeleteWorktree(
        _ project: Project,
        parentURL: URL,
        parentProject: Project?,
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
            self?.performDeleteWorktree(project, parentURL: parentURL, parentProject: parentProject, force: true)
        }
        ask(request)
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
