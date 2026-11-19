import AppKit

/// Go-to-definition (`⌘+Click`), cross-repo (`go.work`) / external read-only file navigation,
/// and Back (`⌘[`) / Forward (`⌘]`) jump stack for `AppStore`.
extension AppStore {
    var canNavigateBack: Bool { jumpHistory.canGoBack }
    var canNavigateForward: Bool { jumpHistory.canGoForward }

    /// Clears external read-only file mode when the user switches files, tabs, commits, or projects.
    func exitExternalFileMode() {
        if externalRequest != nil { externalRequest = nil }
    }

    /// Resolves `textDocument/definition` at a 0-based `(line, character)` position in the active LSP document.
    func goToDefinition(line: Int, character: Int) {
        guard AppEnvironment.hasLSP, let active = viewer.lspDocument, let request = viewer.request else { return }

        let origin = makeJumpLocation(from: request, line1Based: line + 1, column: character)
        definitionTask?.cancel()
        definitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.viewer.flushLSPChangeIfNeeded()
            let locations = await LSPManager.shared.definition(
                fileURL: active.fileURL,
                line: line,
                character: character
            )
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

            guard let best = LSPTargetResolver.pickBestLocation(
                from: locations,
                originFileURL: active.fileURL,
                originLine: line
            ), let targetURL = best.fileURL else {
                self.showToast(L("No definition found", "未找到定义"))
                return
            }

            let canonicalTarget = LSPURI.canonicalFileURL(targetURL)
            if canonicalTarget == active.fileURL, best.range.start.line == line {
                self.viewer.reveal(line: line + 1)
                return
            }

            let activeRef = self.currentProject.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
            let openRefs = self.projects.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
            guard let target = LSPTargetResolver.resolve(
                location: best,
                originFileURL: active.fileURL,
                originRepoRoot: active.repoRoot,
                activeProject: activeRef,
                openProjects: openRefs
            ) else {
                self.showToast(L("No definition found", "未找到定义"))
                return
            }

            self.jumpHistory.push(origin)
            self.navigate(to: target)
        }
    }

    /// `⌘[`: Navigates back to the previous recorded jump location.
    func navigateBack() {
        guard let target = jumpHistory.back(from: currentJumpLocation()) else { return }
        definitionTask?.cancel()
        jumpToLocation(target)
    }

    /// `⌘]`: Navigates forward to the next recorded jump location.
    func navigateForward() {
        guard let target = jumpHistory.forward(from: currentJumpLocation()) else { return }
        definitionTask?.cancel()
        jumpToLocation(target)
    }

    // MARK: - Navigation Helpers

    private func currentJumpLocation() -> JumpLocation? {
        guard let request = viewer.request else { return nil }
        let line = viewer.container?.canvas.currentLineNumber() ?? 1
        let col = viewer.container?.canvas.editSelection?.head.column ?? 0
        return makeJumpLocation(from: request, line1Based: line, column: col)
    }

    private func makeJumpLocation(from request: DiffRequest, line1Based: Int, column: Int) -> JumpLocation {
        let canonicalFile = LSPURI.canonicalFileURL(request.fileURL)
        if request.isExternalFile {
            return JumpLocation(
                fileURL: canonicalFile,
                projectID: nil,
                relativePath: nil,
                line: max(1, line1Based),
                column: max(0, column),
                isExternal: true
            )
        }
        let canonicalRoot = LSPURI.canonicalFileURL(request.root)
        let project = projects.first { LSPURI.canonicalFileURL($0.url) == canonicalRoot } ?? currentProject
        return JumpLocation(
            fileURL: canonicalFile,
            projectID: project?.id,
            relativePath: request.path,
            line: max(1, line1Based),
            column: max(0, column),
            isExternal: false
        )
    }

    private func navigate(to target: LSPNavigationTarget) {
        switch target {
        case .activeProject(let projectID, let relativePath, _, let line, _):
            guard let project = projects.first(where: { $0.id == projectID }) ?? currentProject else { return }
            exitExternalFileMode()
            openFile(in: project, path: relativePath, line: line)
            viewer.focusCanvas()

        case .otherProject(let projectID, let relativePath, _, let line, _):
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            exitExternalFileMode()
            uncollapseAncestors(of: project)
            openFile(in: project, path: relativePath, line: line)
            viewer.focusCanvas()

        case .externalReadOnly(let fileURL, let repoRoot, let workspaceRoot, let displayPath, let line, _):
            openExternalFile(
                fileURL: fileURL,
                repoRoot: repoRoot,
                workspaceRoot: workspaceRoot,
                displayPath: displayPath,
                line: line
            )
        }
    }

    private func jumpToLocation(_ location: JumpLocation) {
        if !location.isExternal,
           let projectID = location.projectID,
           let project = projects.first(where: { $0.id == projectID }),
           let relativePath = location.relativePath {
            exitExternalFileMode()
            uncollapseAncestors(of: project)
            openFile(in: project, path: relativePath, line: location.line)
            viewer.focusCanvas()
            return
        }

        // Re-resolve in case a project was added/removed or the location is external.
        let activeRef = currentProject.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let openRefs = projects.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let target = LSPTargetResolver.resolve(
            fileURL: location.fileURL,
            line: location.line,
            column: location.column,
            originFileURL: viewer.lspDocument?.fileURL,
            originRepoRoot: viewer.lspDocument?.repoRoot,
            activeProject: activeRef,
            openProjects: openRefs
        )
        navigate(to: target)
    }

    func openExternalFile(
        fileURL: URL,
        repoRoot: URL?,
        workspaceRoot: URL?,
        displayPath: String,
        line: Int?
    ) {
        let canonical = LSPURI.canonicalFileURL(fileURL)
        let baseRoot = repoRoot.map { LSPURI.canonicalFileURL($0) } ?? canonical.deletingLastPathComponent()
        let relPath = LSPTargetResolver.relativePath(of: canonical, inside: baseRoot) ?? canonical.lastPathComponent
        let req = DiffRequest(
            root: baseRoot,
            path: relPath,
            oldPath: nil,
            kind: nil,
            source: .externalFile(displayPath: displayPath, workspaceRoot: workspaceRoot)
        )
        externalRequest = req
        viewer.setBaseStamp(nil)
        viewer.open(req, line: line)
        viewer.focusCanvas()
    }

    private func uncollapseAncestors(of project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let owners = projects.map { p in p.worktreeOf.flatMap { id in projects.firstIndex { $0.id == id } } }
        let parents = ProjectTree.parents(projects.map(\.url.path), owners: owners)
        let folded = ProjectTree.ancestors(of: index, parents: parents).map { projects[$0].url.path }
        if !collapsedProjects.isDisjoint(with: folded) {
            collapsedProjects.subtract(folded)
        }
    }
}
