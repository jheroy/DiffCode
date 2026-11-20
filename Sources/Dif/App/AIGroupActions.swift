import Foundation

/// Local AI agent discovery, model listing, and AI working-tree hunk grouping actions.
extension AppStore {
    // MARK: Agent Availability & Models

    func availability(for provider: AgentProvider) -> AgentAvailability? {
        agentAvailabilities.first { $0.provider == provider }
    }

    func defaultAgentModel(for provider: AgentProvider) -> AgentModel? {
        agentModelsByProvider[provider]?.first(where: \.isDefault)
    }

    /// Ensures agent availability and models for `task`'s provider have been loaded at least once.
    /// Fast-paths immediately with zero allocations when already cached or attempted, so switching
    /// back to a grouped project never blocks or re-probes the environment.
    func ensureAgentEnvironmentReady(for task: Settings.AITask = .grouping) {
        guard !AppEnvironment.isAppStore else { return }
        let provider = settings.aiProvider(for: task)
        let needAvailability = !agentAvailabilityChecked && agentAvailabilityTask == nil
        let needModels = (agentModelsByProvider[provider]?.isEmpty ?? true)
            && !loadingModelsProviders.contains(provider)
            && !agentModelAttemptedProviders.contains(provider)
        guard needAvailability || needModels else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.agentAvailabilityChecked {
                await self.refreshAgentAvailability(forceRefresh: false)
            }
            self.loadAgentModels(for: self.settings.aiProvider(for: task), forceRefresh: false)
        }
    }

    /// Probes local CLI/ACP availability for all supported providers off the main thread (no-op in App Store edition).
    /// Reuses cached results unless `forceRefresh` is true, and coalesces concurrent non-forced calls.
    func refreshAgentAvailability(forceRefresh: Bool = false) async {
        guard !AppEnvironment.isAppStore else {
            agentAvailabilities = []
            agentAvailabilityChecked = true
            return
        }
        if !forceRefresh {
            if agentAvailabilityChecked { return }
            if let existing = agentAvailabilityTask {
                await existing.value
                return
            }
        }
        let task = Task<Void, Never> { @MainActor [weak self] in
            let detected = await Task.detached(priority: .utility) {
                LocalAgentService.shared.detectAvailability(forceRefresh: forceRefresh)
            }.value
            guard let self else { return }
            self.agentAvailabilities = detected
            self.agentAvailabilityChecked = true
            self.agentAvailabilityTask = nil
        }
        agentAvailabilityTask = task
        await task.value
    }

    /// Fetches and caches selectable models for `provider` via `LocalAgentService`.
    func loadAgentModels(for provider: AgentProvider, forceRefresh: Bool = false) {
        guard !AppEnvironment.isAppStore else { return }
        if !forceRefresh {
            if let cached = agentModelsByProvider[provider], !cached.isEmpty {
                return
            }
            if loadingModelsProviders.contains(provider) || agentModelAttemptedProviders.contains(provider) {
                return
            }
        }
        agentModelAttemptedProviders.insert(provider)
        agentModelLoadTasks[provider]?.cancel()
        let token = (agentModelLoadTokens[provider] ?? 0) &+ 1
        agentModelLoadTokens[provider] = token
        loadingModelsProviders.insert(provider)
        agentModelErrors[provider] = nil
        let cwd = currentProject?.url

        agentModelLoadTasks[provider] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.agentModelLoadTokens[provider] == token {
                    self.loadingModelsProviders.remove(provider)
                    self.agentModelLoadTasks[provider] = nil
                }
            }
            do {
                let models = try await LocalAgentService.shared.listModels(
                    provider: provider,
                    cwd: cwd,
                    forceRefresh: forceRefresh
                )
                try Task.checkCancellation()
                guard self.agentModelLoadTokens[provider] == token else { return }
                self.agentModelsByProvider[provider] = models
                self.agentModelErrors[provider] = nil
            } catch is CancellationError {
                // Superseded by a newer refresh or provider switch.
            } catch {
                guard self.agentModelLoadTokens[provider] == token else { return }
                self.agentModelErrors[provider] = error.localizedDescription
            }
        }
    }

    func selectAgentProvider(_ provider: AgentProvider, for task: Settings.AITask = .grouping) {
        guard settings.aiProvider(for: task) != provider else { return }
        settings.setAIProvider(provider, for: task)
        if !AppEnvironment.isAppStore {
            loadAgentModels(for: provider, forceRefresh: false)
        }
    }

    func selectAgentModel(_ model: String?, for provider: AgentProvider, task: Settings.AITask = .grouping) {
        settings.setAIModel(model, for: provider, task: task)
    }

    // MARK: AI Hunk Grouping

    /// Generates logical AI groups for all uncommitted working-tree hunks in `project`.
    /// Calling again while generation is in progress cancels the active request.
    func generateAIGroups(for project: Project) {
        if project.isGeneratingGroups {
            cancelAIGroupGeneration(for: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AIHunkGroupingError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard !project.changes.isEmpty else {
            showToast(AIHunkGroupingError.noChangesToGroup.localizedDescription)
            return
        }
        // Flush any unsaved inline edits so the collected hunks match the working tree.
        guard viewer.saveEdits() else { return }

        let provider = settings.aiProvider(for: .grouping)
        let model = settings.aiModel(for: provider, task: .grouping)
        let files = project.changes
        let repoRoot = project.url
        let token = project.beginAIGroupGeneration()

        project.aiGroupGenerationTask = Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer {
                project.finishAIGroupGeneration(token: token)
            }
            do {
                let result = try await AIHunkGrouper.generateGroups(
                    repoRoot: repoRoot,
                    files: files,
                    provider: provider,
                    model: model
                )
                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                project.cancelGroupCommitMessageGeneration()
                project.groupCommitMessages.removeAll()
                project.aiGroupResult = result
                project.aiGroupError = nil
                project.groupCollapsed.removeAll()

                let chosenGroup: AIHunkGroup?
                if let currentID = project.selectedGroupID,
                   let existing = result.groups.first(where: { $0.id == currentID }) {
                    chosenGroup = existing
                } else {
                    chosenGroup = result.groups.first
                }
                project.selectedGroupID = chosenGroup?.id
                project.selectedGroupFilePath = nil
                project.selectedGroupRowID = nil
                project.selectedGroupHunkIndex = nil

                if let group = chosenGroup {
                    if project.id == self.selectedProjectID, project.tab == .groups {
                        self.selectAIGroup(group, in: project, openFirstFile: true)
                    } else if let firstFile = project.orderedGroupFiles(for: group, flat: self.settings.flatList).first ?? group.files.first {
                        project.selectedGroupFilePath = firstFile.path
                        project.selectedGroupRowID = ChangeRow.fileID(firstFile.path)
                        project.selectedGroupHunkIndex = firstFile.hunkIndices.first ?? 0
                    }
                }

                let summary = result.groups.count == 1
                    ? L("Grouped \(result.totalHunks) changes into 1 group", "已将 \(result.totalHunks) 处变更归为 1 组")
                    : L("Grouped \(result.totalHunks) changes into \(result.groups.count) groups",
                        "已将 \(result.totalHunks) 处变更分为 \(result.groups.count) 组")
                self.showToast(summary)
            } catch is CancellationError {
                // Cancelled by user or project switch.
            } catch {
                guard project.aiGroupGenerationToken == token else { return }
                project.aiGroupError = error.localizedDescription
                self.showToast(error.localizedDescription)
            }
        }
    }

    func cancelAIGroupGeneration(for project: Project) {
        project.cancelAIGroupGeneration(includeGroupCommitMessage: false)
    }

    func clearAIGroups(for project: Project) {
        if pendingGroupHunkFocus?.root == project.url {
            pendingGroupHunkFocus = nil
        }
        project.clearAIGroups()
        if project.id == selectedProjectID {
            viewer.setHighlightedGroupHunks(nil)
        }
    }

    /// Selects `group` in the top Groups pane, updates the bottom changes list, and opens its first file
    /// with the group's hunk filter applied in a single pass.
    func selectAIGroup(_ group: AIHunkGroup, in project: Project, openFirstFile: Bool = true) {
        let changedGroup = project.selectedGroupID != group.id
        if changedGroup {
            project.selectedGroupID = group.id
            project.groupCollapsed.removeAll()
        }
        guard project.id == selectedProjectID else { return }

        if !changedGroup,
           let currentPath = project.selectedGroupFilePath,
           let existingFile = group.files.first(where: { $0.path == currentPath }),
           project.browsedPath == nil,
           externalRequest == nil,
           viewer.request?.root == project.url,
           viewer.request?.path == currentPath {
            let targetHunk = project.selectedGroupHunkIndex ?? existingFile.hunkIndices.first ?? 0
            openGroupItem(project: project, group: group, filePath: existingFile.path, hunkIndex: targetHunk)
            return
        }

        guard openFirstFile,
              let firstFile = project.orderedGroupFiles(for: group, flat: settings.flatList).first ?? group.files.first else {
            return
        }
        openGroupItem(project: project, group: group, filePath: firstFile.path, hunkIndex: firstFile.hunkIndices.first ?? 0)
    }

    /// Selects a file and hunk inside an AI group, opening the working-tree diff on the right
    /// with the group's hunk filter applied synchronously and focusing raw `hunkIndex` once loaded.
    func openGroupItem(project: Project, group: AIHunkGroup, filePath: String, hunkIndex: Int) {
        guard project.id == selectedProjectID else { return }
        exitExternalFileMode()
        project.browsedPath = nil
        if project.selectedGroupID != group.id {
            project.selectedGroupID = group.id
        }
        project.selectedGroupFilePath = filePath
        project.selectedGroupRowID = ChangeRow.fileID(filePath)
        project.selectedGroupHunkIndex = hunkIndex

        let rawRequest: DiffRequest
        if let change = project.change(forPath: filePath) {
            rawRequest = project.request(for: change, ignoreWhitespace: settings.ignoreWhitespace)
        } else {
            rawRequest = worktreeRequest(for: filePath, in: project)
        }
        let request = resolvedRequest(rawRequest)

        noteRecent(project, filePath)
        follow(filePath, in: project)
        viewer.setBaseStamp(project.status.headOID)

        let targetHunks = project.highlightedGroupHunks(for: filePath)
        let sameRequest = viewer.request == request

        if sameRequest {
            pendingGroupHunkFocus = (root: project.url, path: filePath, hunkIndex: hunkIndex)
            viewer.setHighlightedGroupHunks(targetHunks)
            if !viewer.isLoading, pendingGroupHunkFocus != nil, let doc = viewer.document {
                pendingGroupHunkFocus = nil
                if !doc.hunks.isEmpty {
                    // Pass raw hunkIndex directly; ViewerModel maps via groupHunkIndexMap when group-filtered.
                    viewer.focus(hunk: hunkIndex, animated: true)
                }
            }
            return
        }

        // Prime group hunk filter before viewer.open so ViewerModel loads filtered in one pass
        // without running a wasted re-filter on the outgoing file.
        pendingGroupHunkFocus = (root: project.url, path: filePath, hunkIndex: hunkIndex)
        syncGroupHunkFilter(targetHunks, for: request)
        let sameFile = viewer.request?.path == request.path && viewer.request?.root == request.root
        viewer.open(request, preserveScroll: sameFile)
    }

    /// Completes any deferred hunk focus requested by `openGroupItem` once `ViewerModel` finishes loading.
    func applyPendingGroupHunkFocus() {
        guard let pending = pendingGroupHunkFocus,
              !viewer.isLoading,
              let request = viewer.request,
              request.root == pending.root,
              request.path == pending.path else { return }
        pendingGroupHunkFocus = nil
        guard let doc = viewer.document, !doc.hunks.isEmpty else { return }
        // Pass raw hunkIndex directly without clamping; ViewerModel maps it when group-filtered.
        let target = pending.hunkIndex
        if let container = viewer.container {
            container.whenLaidOut { [weak self] in
                guard let self,
                      let current = self.viewer.request,
                      current.root == pending.root,
                      current.path == pending.path,
                      let currentDoc = self.viewer.document,
                      !currentDoc.hunks.isEmpty else { return }
                self.viewer.focus(hunk: target, animated: false)
            }
        } else {
            viewer.focus(hunk: target, animated: false)
        }
    }

    // MARK: Direct Group Commit

    /// Commits ONLY the hunks belonging to `group` using its current commit message draft
    /// (without mutating Tab 1's file checkboxes or line exclusions).
    func commitGroup(for project: Project, group: AIHunkGroup) {
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        if let operation = project.status.operation {
            showToast(L("A \(operation.command) is in progress · finish it in Changes first",
                        "正在进行 \(operation.command) · 请先在变更页完成"))
            return
        }

        let trimmed = project.commitMessage(for: group).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast(L("Write a commit message first", "先写提交说明"))
            return
        }

        // Flush any unsaved inline edits so the diff committed matches the working tree.
        guard viewer.saveEdits() else { return }

        // Cancel any in-flight regrouping against the old HEAD so it cannot overwrite the post-commit groups.
        if project.isGeneratingGroups {
            project.cancelAIGroupGeneration(includeGroupCommitMessage: false)
        }
        if project.generatingGroupCommitID == group.id {
            project.cancelGroupCommitMessageGeneration()
        }

        let allChanges = project.changes
        let repoRoot = project.url
        let isInitial = project.status.isInitial
        let groupID = group.id
        let groupName = group.name

        project.isCommittingGroup = true
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer { project.isCommittingGroup = false }
            do {
                let selection = try await AIHunkGrouper.buildCommitSelection(
                    for: group,
                    allChanges: allChanges,
                    repoRoot: repoRoot,
                    isInitial: isInitial
                )
                guard !selection.files.isEmpty else {
                    project.refresh()
                    self.showToast(L("No uncommitted changes remain in this group",
                                     "该分组已没有可提交的未提交变更"))
                    return
                }

                let partial = selection.files.compactMap { change in
                    selection.excludedLines[change.path].flatMap {
                        $0.isEmpty ? nil : WorkingTree.PartialFile(change: change, excluded: $0)
                    }
                }
                let whole = selection.files.filter { selection.excludedLines[$0.path]?.isEmpty != false }

                let result = partial.isEmpty
                    ? try await WorkingTree.commit(message: trimmed, changes: selection.files, amend: false, in: repoRoot)
                    : try await WorkingTree.commit(message: trimmed, whole: whole, partial: partial, amend: false, in: repoRoot)

                project.lastCommit = result
                project.groupCommitMessages.removeValue(forKey: groupID)

                if let currentResult = project.aiGroupResult {
                    let previousIndex = currentResult.groups.firstIndex(where: { $0.id == groupID })
                    let updatedResult = AIHunkGrouper.resultAfterCommitting(groupID: groupID, in: currentResult)
                    project.aiGroupResult = updatedResult

                    if let updatedResult {
                        let validIDs = Set(updatedResult.groups.map(\.id))
                        if project.groupCommitMessages.keys.contains(where: { !validIDs.contains($0) }) {
                            project.groupCommitMessages = project.groupCommitMessages.filter { validIDs.contains($0.key) }
                        }
                        if let generatingID = project.generatingGroupCommitID, !validIDs.contains(generatingID) {
                            project.cancelGroupCommitMessageGeneration()
                        }

                        let needsReselect = project.selectedGroupID == nil
                            || project.selectedGroupID == groupID
                            || !validIDs.contains(project.selectedGroupID!)
                        if needsReselect {
                            let nextIdx = min(previousIndex ?? 0, updatedResult.groups.count - 1)
                            let nextGroup = updatedResult.groups[nextIdx]
                            project.selectedGroupID = nextGroup.id
                            project.groupCollapsed.removeAll()
                            project.selectedGroupFilePath = nil
                            project.selectedGroupRowID = nil
                            project.selectedGroupHunkIndex = nil
                            if let firstFile = project.orderedGroupFiles(for: nextGroup, flat: self.settings.flatList).first ?? nextGroup.files.first {
                                project.selectedGroupFilePath = firstFile.path
                                project.selectedGroupRowID = ChangeRow.fileID(firstFile.path)
                                project.selectedGroupHunkIndex = firstFile.hunkIndices.first ?? 0
                            }
                        } else if let activeID = project.selectedGroupID,
                                  let activeGroup = updatedResult.groups.first(where: { $0.id == activeID }) {
                            if let currentPath = project.selectedGroupFilePath,
                               let activeFile = activeGroup.files.first(where: { $0.path == currentPath }) {
                                if let hunk = project.selectedGroupHunkIndex, !activeFile.hunkIndices.contains(hunk) {
                                    project.selectedGroupHunkIndex = activeFile.hunkIndices.first ?? 0
                                }
                            } else if let firstFile = project.orderedGroupFiles(for: activeGroup, flat: self.settings.flatList).first ?? activeGroup.files.first {
                                project.selectedGroupFilePath = firstFile.path
                                project.selectedGroupRowID = ChangeRow.fileID(firstFile.path)
                                project.selectedGroupHunkIndex = firstFile.hunkIndices.first ?? 0
                            } else {
                                project.selectedGroupFilePath = nil
                                project.selectedGroupRowID = nil
                                project.selectedGroupHunkIndex = nil
                            }
                        }
                    } else {
                        project.cancelGroupCommitMessageGeneration()
                        project.groupCommitMessages.removeAll()
                        project.selectedGroupID = nil
                        project.selectedGroupRowID = nil
                        project.selectedGroupFilePath = nil
                        project.selectedGroupHunkIndex = nil
                        project.groupCollapsed.removeAll()
                        if project.id == self.selectedProjectID {
                            self.pendingGroupHunkFocus = nil
                            self.viewer.setHighlightedGroupHunks(nil)
                        }
                    }
                }

                project.invalidateFiles()
                project.logStale = true
                project.refresh()
                if project.tab == .log { project.loadLog(reset: true) }
                if project.id == self.selectedProjectID {
                    self.syncViewer()
                }
                self.showToast(L("Committed group “\(groupName)” · \(result.shortHash)",
                                 "已提交分组「\(groupName)」· \(result.shortHash)"))
            } catch {
                project.refresh()
                self.showFailure(L("Commit failed", "提交失败"), error, note: self.sandboxNote(for: error))
            }
        }
    }

    /// Generates a new AI commit message for `group`'s exact hunks using the configured `.commit` provider/model.
    /// Calling again while generation is running for the same group cancels the active request.
    func generateGroupCommitMessage(for project: Project, group: AIHunkGroup) {
        if project.generatingGroupCommitID == group.id {
            cancelGroupCommitMessageGeneration(for: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AICommitError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard viewer.saveEdits() else { return }

        let format = settings.effectiveCommitMessageFormat
        let provider = settings.aiProvider(for: .commit)
        let model = settings.aiModel(for: provider, task: .commit)
        let allChanges = project.changes
        let repoRoot = project.url
        let isInitial = project.status.isInitial
        let token = project.beginGroupCommitMessageGeneration(for: group.id)

        project.groupCommitMessageTask = Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer {
                project.finishGroupCommitMessageGeneration(token: token)
            }
            do {
                let selection = try await AIHunkGrouper.buildCommitSelection(
                    for: group,
                    allChanges: allChanges,
                    repoRoot: repoRoot,
                    isInitial: isInitial
                )
                try Task.checkCancellation()
                guard !selection.files.isEmpty else {
                    throw AICommitError.noCheckedChanges
                }
                let generated = try await AICommitGenerator.generate(
                    repoRoot: repoRoot,
                    files: selection.files,
                    excludedLines: selection.excludedLines,
                    isInitial: isInitial,
                    format: format,
                    provider: provider,
                    model: model
                )
                try Task.checkCancellation()
                guard project.groupCommitMessageToken == token else { return }
                project.setCommitMessage(generated, for: group)
                self.showToast(L("Commit message generated", "已生成提交信息"))
            } catch is CancellationError {
                // Cancelled by user or project switch; keep existing draft intact.
            } catch {
                guard project.groupCommitMessageToken == token else { return }
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// Cancels any active AI commit message generation for a group in `project`.
    func cancelGroupCommitMessageGeneration(for project: Project) {
        project.cancelGroupCommitMessageGeneration()
    }

    /// Restores `group`'s commit message back to its generated group title and description.
    func resetGroupCommitMessage(for project: Project, group: AIHunkGroup) {
        if project.generatingGroupCommitID == group.id {
            project.cancelGroupCommitMessageGeneration()
        }
        project.resetCommitMessage(for: group)
    }
}
