import AppKit
import Foundation
import SwiftUI

/// Local AI agent discovery, model listing, and multi-source / multi-session AI hunk grouping actions.
extension AppStore {
    // MARK: Agent Availability & Models

    func availability(for provider: AgentProvider) -> AgentAvailability? {
        agentAvailabilities.first { $0.provider == provider }
    }

    func defaultAgentModel(for provider: AgentProvider) -> AgentModel? {
        agentModelsByProvider[provider]?.first(where: \.isDefault)
    }

    /// Populates `agentModelsByProvider` from persisted settings so model pickers show cached options on launch.
    func restoreCachedAgentModels() {
        guard !AppEnvironment.isAppStore else { return }
        for provider in AgentProvider.allCases {
            let cached = settings.cachedAIModels(for: provider)
            if (agentModelsByProvider[provider]?.isEmpty ?? true), !cached.isEmpty {
                agentModelsByProvider[provider] = cached
            }
        }
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
                if !models.isEmpty {
                    self.agentModelsByProvider[provider] = models
                    self.settings.setCachedAIModels(models, for: provider)
                } else if self.agentModelsByProvider[provider]?.isEmpty ?? true {
                    self.agentModelAttemptedProviders.remove(provider)
                }
                self.agentModelErrors[provider] = nil
            } catch is CancellationError {
                if self.agentModelLoadTokens[provider] == token {
                    self.agentModelAttemptedProviders.remove(provider)
                }
            } catch {
                guard self.agentModelLoadTokens[provider] == token else { return }
                self.agentModelErrors[provider] = error.localizedDescription
                let hasCached = !(self.agentModelsByProvider[provider]?.isEmpty ?? true)
                let isNotInstalled: Bool
                if case LocalAgentError.providerNotInstalled = error {
                    isNotInstalled = true
                } else {
                    isNotInstalled = false
                }
                if !isNotInstalled && !hasCached {
                    self.agentModelAttemptedProviders.remove(provider)
                }
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

    // MARK: AI Grouping File Filter & Blacklist

    func isAIGroupingBlacklisted(_ path: String, in project: Project) -> Bool {
        settings.isAIGroupingBlacklisted(path, for: project.url)
    }

    func toggleAIGroupingBlacklist(path: String, in project: Project, pruneActiveSession: Bool = false) {
        guard !AppEnvironment.isAppStore else { return }
        let normalized = AIHunkGroupingFilter.normalizePath(path)
        guard !normalized.isEmpty else { return }
        let name = (normalized as NSString).lastPathComponent

        if settings.isAIGroupingBlacklisted(normalized, for: project.url) {
            settings.removeAIGroupingBlacklist(normalized, for: project.url)
            showToast(L("Removed \(name) from AI grouping blacklist", "已将 \(name) 移出分组黑名单"))
            return
        }

        settings.addAIGroupingBlacklist(normalized, for: project.url)

        if pruneActiveSession,
           let session = project.activeAIGroupSession {
            let matchingPaths = Set(
                session.result.groups
                    .flatMap(\.files)
                    .map(\.path)
                    .filter { AIHunkGroupingFilter.normalizePath($0) == normalized }
            )
            if !matchingPaths.isEmpty {
                let previousIndex = session.selectedGroupID.flatMap { id in
                    session.result.groups.firstIndex(where: { $0.id == id })
                }
                if let updatedResult = AIHunkGrouper.resultAfterRemovingFiles(matchingPaths, in: session.result) {
                    project.mutateAIGroupSession(id: session.id) { s in
                        s.result = updatedResult
                    }
                    reconcileAIGroupSession(
                        id: session.id,
                        removedGroupID: nil,
                        previousIndex: previousIndex,
                        in: project
                    )
                    persistAIGroups(for: project)
                    if project.id == selectedProjectID {
                        syncViewer()
                    }
                } else {
                    deleteAIGroupSession(session.id, in: project)
                }
                showToast(L("Blacklisted \(name) and removed from current grouping",
                            "已将 \(name) 加入分组黑名单并从当前分组移除"))
                return
            }
        }

        showToast(L("Added \(name) to AI grouping blacklist", "已将 \(name) 加入分组黑名单"))
    }

    func removeAIGroupingBlacklist(path: String, in project: Project) {
        guard !AppEnvironment.isAppStore else { return }
        let normalized = AIHunkGroupingFilter.normalizePath(path)
        guard settings.removeAIGroupingBlacklist(normalized, for: project.url) else { return }
        let name = (normalized as NSString).lastPathComponent
        showToast(L("Removed \(name) from AI grouping blacklist", "已将 \(name) 移出分组黑名单"))
    }

    func clearAIGroupingBlacklist(in project: Project) {
        guard !AppEnvironment.isAppStore else { return }
        guard !settings.aiGroupingBlacklist(for: project.url).isEmpty else { return }
        settings.clearAIGroupingBlacklist(for: project.url)
        showToast(L("Cleared AI grouping blacklist", "已清空分组黑名单"))
    }

    func addAIGroupingBlacklistMenuItem(
        for path: String,
        in project: Project,
        pruneActiveSession: Bool = false,
        to menu: NSMenu
    ) {
        guard !AppEnvironment.isAppStore else { return }
        let blacklisted = isAIGroupingBlacklisted(path, in: project)
        let title = blacklisted
            ? L("Remove from AI Grouping Blacklist", "移出分组黑名单")
            : L("Add to AI Grouping Blacklist", "加入分组黑名单")
        menu.addItem(ClosureMenuItem(title) { [weak self, weak project] in
            guard let self, let project else { return }
            self.toggleAIGroupingBlacklist(path: path, in: project, pruneActiveSession: pruneActiveSession)
        })
    }

    // MARK: AI Hunk Grouping (Multi-Source & Multi-Session)

    /// Generates logical AI groups for the active context: comparison if one is open, else working-tree changes.
    /// Calling again while generation is in progress cancels the active request.
    func generateAIGroups(for project: Project) {
        if project.isGeneratingGroups {
            cancelAIGroupGeneration(for: project)
            return
        }
        if let comparison = project.comparison {
            generateComparisonAIGroups(for: project, comparison: comparison)
        } else {
            generateWorkingTreeAIGroups(for: project)
        }
    }

    /// Generates logical AI groups for all uncommitted working-tree hunks in `project`.
    func generateWorkingTreeAIGroups(for project: Project, replacingSessionID: UUID? = nil) {
        guard !AppEnvironment.isAppStore else {
            showToast(AIHunkGroupingError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard !project.changes.isEmpty else {
            showToast(AIHunkGroupingError.noChangesToGroup.localizedDescription)
            return
        }
        let filter = settings.aiGroupingFilter(for: project.url)
        let filteredFiles = filter.apply(to: project.changes)
        guard !filteredFiles.isEmpty else {
            let message = AIHunkGroupingError.noMatchingFilesAfterFilter(filter.summaryText).localizedDescription
            project.aiGroupError = message
            showToast(message)
            return
        }
        // Flush any unsaved inline edits so the collected hunks match the working tree.
        guard viewer.saveEdits() else { return }

        let targetSessionID = replacingSessionID ?? project.aiGroupSessions.first(where: \.isCommittable)?.id
        let provider = settings.aiProvider(for: .grouping)
        let model = settings.aiModel(for: provider, task: .grouping)
        let repoRoot = project.url
        let headOID = project.status.headOID

        project.lastFailedGroupTarget = .workingTree
        let token = project.beginAIGroupGeneration(sessionID: targetSessionID, source: .workingTree)
        let conversation = makeGroupingConversation(
            project: project,
            source: .workingTree,
            provider: provider,
            model: model
        )
        let turnID = conversation.turns[0].id

        project.aiGroupGenerationTask = Task { @MainActor [weak self, weak project, weak conversation] in
            guard let self, let project, let conversation else { return }
            defer {
                project.finishAIGroupGeneration(token: token)
            }
            do {
                let result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                    try await AIHunkGrouper.generateGroups(
                        repoRoot: repoRoot,
                        source: .workingTree,
                        files: filteredFiles,
                        filter: filter,
                        provider: provider,
                        model: model,
                        persistSession: true,
                        onPromptReady: { [weak conversation] fullPrompt in
                            Task { @MainActor [weak conversation] in
                                conversation?.setFullPrompt(fullPrompt, forTurnID: turnID)
                            }
                        },
                        onEvent: onEvent
                    )
                }
                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                self.finalizeGroupingConversation(conversation, turnID: turnID, result: result)
                project.cancelGroupCommitMessageGeneration()
                self.applyGeneratedGroupingResult(
                    result,
                    source: .workingTree,
                    files: filteredFiles,
                    headOID: headOID,
                    replacingSessionID: targetSessionID,
                    filter: filter.isActive ? filter : nil,
                    in: project
                )
            } catch is CancellationError {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .cancelled)
            } catch {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .failed(error.localizedDescription))
                project.lastFailedGroupTarget = .workingTree
                project.aiGroupError = error.localizedDescription
                self.showToast(
                    error.localizedDescription,
                    action: ToastAction(title: L("View Stream", "查看对话")) {
                        self.openAgentConversation(conversation)
                    }
                )
            }
        }
    }

    /// Generates logical AI groups for the active branch/commit/stash comparison (or `comparison`).
    func generateComparisonAIGroups(
        for project: Project,
        comparison: Comparison? = nil,
        files: [FileChange]? = nil,
        replacingSessionID: UUID? = nil
    ) {
        guard let activeComparison = comparison ?? project.comparison else {
            showToast(AIHunkGroupingError.noChangesToGroup.localizedDescription)
            return
        }
        let compSource: AIHunkGroupingSource.ComparisonSource
        if case .comparison(let cs) = AIHunkGroupingSource.from(comparison: activeComparison) {
            compSource = cs
        } else {
            return
        }
        let preloadedFiles: [FileChange]?
        if let files {
            preloadedFiles = files
        } else if activeComparison == project.comparison && !project.isLoadingCompare && !project.compareChanges.isEmpty {
            preloadedFiles = project.compareChanges
        } else {
            preloadedFiles = nil
        }
        runComparisonAIGrouping(
            for: project,
            comparisonSource: compSource,
            stash: activeComparison.stash,
            preloadedFiles: preloadedFiles,
            replacingSessionID: replacingSessionID
        )
    }

    /// Generates logical AI groups from one or more selected Log / Git Graph commits (`commits` ordered newest first).
    func generateCommitsAIGroups(
        for project: Project,
        commits: [Commit],
        replacingSessionID: UUID? = nil
    ) {
        guard !AppEnvironment.isAppStore else {
            showToast(AIHunkGroupingError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard !commits.isEmpty else {
            showToast(AIHunkGroupingError.noChangesToGroup.localizedDescription)
            return
        }

        let orderedCommits = commits
        let hashes = orderedCommits.map(\.hash)
        let placeholderSource = AIHunkGroupingSource.commits(.init(
            commitHashes: hashes,
            oldestParentHash: orderedCommits.count == 1 ? orderedCommits[0].parents.first : nil,
            isNonContiguous: false,
            primarySubject: orderedCommits.count == 1 ? orderedCommits[0].subject : nil,
            skippedMergeCount: 0,
            fileSteps: [:]
        ))

        prepareGroupsTabForGeneration(replacingSessionID: replacingSessionID, in: project)

        let filter = settings.aiGroupingFilter(for: project.url)
        let provider = settings.aiProvider(for: .grouping)
        let model = settings.aiModel(for: provider, task: .grouping)
        let repoRoot = project.url

        project.lastFailedGroupTarget = .commits(hashes)
        let token = project.beginAIGroupGeneration(sessionID: replacingSessionID, source: placeholderSource)
        let conversation = makeGroupingConversation(
            project: project,
            source: placeholderSource,
            provider: provider,
            model: model
        )
        let turnID = conversation.turns[0].id

        project.aiGroupGenerationTask = Task { @MainActor [weak self, weak project, weak conversation] in
            guard let self, let project, let conversation else { return }
            defer {
                project.finishAIGroupGeneration(token: token)
            }
            do {
                let summary = try await Git.commitSelectionSummary(orderedCommits, in: repoRoot)
                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                guard !summary.files.isEmpty else {
                    throw AIHunkGroupingError.noChangesToGroup
                }
                let filteredFiles = filter.apply(to: summary.files)
                guard !filteredFiles.isEmpty else {
                    throw AIHunkGroupingError.noMatchingFilesAfterFilter(filter.summaryText)
                }

                let newest = orderedCommits[0]
                let oldest = orderedCommits[orderedCommits.count - 1]
                let commitsSource = AIHunkGroupingSource.CommitsSource(
                    commitHashes: hashes,
                    oldestParentHash: summary.isNonContiguous ? nil : oldest.parents.first,
                    isNonContiguous: summary.isNonContiguous,
                    primarySubject: orderedCommits.count == 1 ? newest.subject : nil,
                    skippedMergeCount: summary.skippedMergeCount,
                    fileSteps: summary.fileSteps
                )
                let source = AIHunkGroupingSource.commits(commitsSource)
                project.generatingGroupSource = source
                conversation.title = source.detailTitle

                let result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                    try await AIHunkGrouper.generateGroups(
                        repoRoot: repoRoot,
                        source: source,
                        files: filteredFiles,
                        filter: filter,
                        provider: provider,
                        model: model,
                        persistSession: true,
                        onPromptReady: { [weak conversation] fullPrompt in
                            Task { @MainActor [weak conversation] in
                                conversation?.setFullPrompt(fullPrompt, forTurnID: turnID)
                            }
                        },
                        onEvent: onEvent
                    )
                }
                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                self.finalizeGroupingConversation(conversation, turnID: turnID, result: result)
                self.applyGeneratedGroupingResult(
                    result,
                    source: source,
                    files: filteredFiles,
                    headOID: nil,
                    replacingSessionID: replacingSessionID,
                    filter: filter.isActive ? filter : nil,
                    in: project
                )
            } catch is CancellationError {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .cancelled)
            } catch {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .failed(error.localizedDescription))
                project.lastFailedGroupTarget = .commits(hashes)
                project.aiGroupError = error.localizedDescription
                self.showToast(
                    error.localizedDescription,
                    action: ToastAction(title: L("View Stream", "查看对话")) {
                        self.openAgentConversation(conversation)
                    }
                )
            }
        }
    }

    /// Re-runs AI grouping for an existing session using its recorded source.
    func regenerateAIGroupSession(_ sessionID: UUID, in project: Project) {
        guard !AppEnvironment.isAppStore else {
            showToast(AIHunkGroupingError.unavailableInAppStore.localizedDescription)
            return
        }
        if project.isGeneratingGroups {
            cancelAIGroupGeneration(for: project)
            return
        }
        guard let session = project.aiGroupSession(id: sessionID) else {
            generateAIGroups(for: project)
            return
        }
        switch session.source {
        case .workingTree:
            generateWorkingTreeAIGroups(for: project, replacingSessionID: sessionID)
        case .comparison(let compSource):
            runComparisonAIGrouping(
                for: project,
                comparisonSource: compSource,
                stash: nil,
                preloadedFiles: nil,
                replacingSessionID: sessionID
            )
        case .commits(let commitsSource):
            let hashes = commitsSource.commitHashes
            let repoRoot = project.url
            Task { @MainActor [weak self, weak project] in
                guard let self, let project else { return }
                let fetched = await Git.commits(hashes: hashes, in: repoRoot)
                let byHash = Dictionary(fetched.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
                let ordered = hashes.compactMap { byHash[$0] }
                guard !ordered.isEmpty else {
                    let message = L("Selected commits are no longer available", "所选提交已不存在")
                    project.aiGroupError = message
                    self.showToast(message)
                    return
                }
                self.generateCommitsAIGroups(for: project, commits: ordered, replacingSessionID: sessionID)
            }
        }
    }

    /// Retries the most recent failed AI grouping attempt, or falls back to the active context.
    func retryFailedAIGroupGeneration(for project: Project) {
        guard !project.isGeneratingGroups, !project.isCommittingGroup, !project.isCommitting else { return }
        switch project.lastFailedGroupTarget {
        case .workingTree:
            generateWorkingTreeAIGroups(for: project)
        case .comparison(let compSource):
            runComparisonAIGrouping(
                for: project,
                comparisonSource: compSource,
                stash: nil,
                preloadedFiles: nil,
                replacingSessionID: nil
            )
        case .commits(let hashes):
            let repoRoot = project.url
            Task { @MainActor [weak self, weak project] in
                guard let self, let project else { return }
                let fetched = await Git.commits(hashes: hashes, in: repoRoot)
                let byHash = Dictionary(fetched.map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
                let ordered = hashes.compactMap { byHash[$0] }
                guard !ordered.isEmpty else {
                    self.generateAIGroups(for: project)
                    return
                }
                self.generateCommitsAIGroups(for: project, commits: ordered)
            }
        case nil:
            generateAIGroups(for: project)
        }
    }

    private func runComparisonAIGrouping(
        for project: Project,
        comparisonSource: AIHunkGroupingSource.ComparisonSource,
        stash: StashEntry?,
        preloadedFiles: [FileChange]?,
        replacingSessionID: UUID?
    ) {
        guard !AppEnvironment.isAppStore else {
            showToast(AIHunkGroupingError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        if comparisonSource.headHash == nil {
            guard viewer.saveEdits() else { return }
        }

        prepareGroupsTabForGeneration(replacingSessionID: replacingSessionID, in: project)

        let filter = settings.aiGroupingFilter(for: project.url)
        let provider = settings.aiProvider(for: .grouping)
        let model = settings.aiModel(for: provider, task: .grouping)
        let repoRoot = project.url
        let initialSource = AIHunkGroupingSource.comparison(comparisonSource)

        project.lastFailedGroupTarget = .comparison(comparisonSource)
        let token = project.beginAIGroupGeneration(sessionID: replacingSessionID, source: initialSource)
        let conversation = makeGroupingConversation(
            project: project,
            source: initialSource,
            provider: provider,
            model: model
        )
        let turnID = conversation.turns[0].id

        project.aiGroupGenerationTask = Task { @MainActor [weak self, weak project, weak conversation] in
            guard let self, let project, let conversation else { return }
            defer {
                project.finishAIGroupGeneration(token: token)
            }
            do {
                var resolvedComp = comparisonSource
                let resolvedFiles: [FileChange]
                if let preloadedFiles {
                    resolvedFiles = preloadedFiles
                } else if resolvedComp.isStash, let headHash = resolvedComp.headHash {
                    let entry = stash ?? StashEntry(
                        hash: headHash,
                        index: 0,
                        message: resolvedComp.title,
                        date: Date(),
                        base: resolvedComp.baseHash,
                        untracked: resolvedComp.stashUntrackedHash
                    )
                    resolvedFiles = try await Git.stashFiles(entry, in: repoRoot)
                } else {
                    if resolvedComp.headHash == nil {
                        let resolvedBase = resolvedComp.forkPoint
                            ? await Git.mergeBase("HEAD", resolvedComp.targetRef, in: repoRoot)
                            : await Git.resolveCommit(resolvedComp.targetRef, in: repoRoot)
                        if let resolvedBase {
                            resolvedComp.baseHash = resolvedBase
                        }
                    }
                    resolvedFiles = try await Git.compareFiles(
                        base: resolvedComp.baseHash,
                        head: resolvedComp.headHash,
                        in: repoRoot
                    )
                }

                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                guard !resolvedFiles.isEmpty else {
                    throw AIHunkGroupingError.noChangesToGroup
                }
                let filteredFiles = filter.apply(to: resolvedFiles)
                guard !filteredFiles.isEmpty else {
                    throw AIHunkGroupingError.noMatchingFilesAfterFilter(filter.summaryText)
                }

                let finalSource = AIHunkGroupingSource.comparison(resolvedComp)
                project.generatingGroupSource = finalSource
                project.lastFailedGroupTarget = .comparison(resolvedComp)
                conversation.title = finalSource.detailTitle

                let result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                    try await AIHunkGrouper.generateGroups(
                        repoRoot: repoRoot,
                        source: finalSource,
                        files: filteredFiles,
                        filter: filter,
                        provider: provider,
                        model: model,
                        persistSession: true,
                        onPromptReady: { [weak conversation] fullPrompt in
                            Task { @MainActor [weak conversation] in
                                conversation?.setFullPrompt(fullPrompt, forTurnID: turnID)
                            }
                        },
                        onEvent: onEvent
                    )
                }
                try Task.checkCancellation()
                guard project.aiGroupGenerationToken == token else { return }
                self.finalizeGroupingConversation(conversation, turnID: turnID, result: result)
                self.applyGeneratedGroupingResult(
                    result,
                    source: finalSource,
                    files: filteredFiles,
                    headOID: nil,
                    replacingSessionID: replacingSessionID,
                    filter: filter.isActive ? filter : nil,
                    in: project
                )
            } catch is CancellationError {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .cancelled)
            } catch {
                guard project.aiGroupGenerationToken == token else { return }
                conversation.finishTurn(turnID, status: .failed(error.localizedDescription))
                project.lastFailedGroupTarget = .comparison(comparisonSource)
                project.aiGroupError = error.localizedDescription
                self.showToast(
                    error.localizedDescription,
                    action: ToastAction(title: L("View Stream", "查看对话")) {
                        self.openAgentConversation(conversation)
                    }
                )
            }
        }
    }

    private func makeGroupingConversation(
        project: Project,
        source: AIHunkGroupingSource,
        provider: AgentProvider,
        model: String?
    ) -> AgentConversation {
        let conv = AgentConversation(
            projectID: project.id,
            repoRoot: project.url,
            kind: .grouping,
            reviewTarget: nil,
            title: source.detailTitle,
            provider: provider,
            model: model,
            toolAccess: .disabled,
            initialUserPromptDisplay: "\(source.detailTitle)"
        )
        project.registerAgentConversation(conv)
        return conv
    }

    private func finalizeGroupingConversation(
        _ conversation: AgentConversation,
        turnID: UUID,
        result: AIHunkGroupingResult
    ) {
        if let sid = result.sessionID, !sid.isEmpty {
            conversation.remoteSessionID = sid
        }
        let summaryLines = result.groups.enumerated().map { idx, grp in
            let brief = grp.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(idx + 1). **\(grp.name)** (\(grp.fileCount) files, \(grp.hunkCount) hunks)" + (brief.isEmpty ? "" : " — \(brief)")
        }.joined(separator: "\n")
        let fallbackSummary = summaryLines.isEmpty
            ? L("Generated \(result.groups.count) group(s).", "已生成 \(result.groups.count) 个分组。")
            : summaryLines
        conversation.appendStatusNote(
            L("Generated \(result.groups.count) group(s) across \(result.totalHunks) hunk(s).",
              "已生成 \(result.groups.count) 个逻辑分组（共 \(result.totalHunks) 处变更）。"),
            toTurnID: turnID
        )
        conversation.finishTurn(turnID, status: .completed, finalText: fallbackSummary)
    }

    private func prepareGroupsTabForGeneration(replacingSessionID: UUID?, in project: Project) {
        exitExternalFileMode()
        if selectedProjectID != project.id {
            select(project)
        }
        project.browsedPath = nil
        if project.tab != .groups {
            project.tab = .groups
        }
        if !listVisible {
            withAnimation(.snappy(duration: 0.2)) { listVisible = true }
        }
        if project.activeGroupSessionID != replacingSessionID {
            project.activeGroupSessionID = replacingSessionID
            project.groupCollapsed.removeAll()
            project.selectedGroupRowID = nil
            pendingGroupHunkFocus = nil
            if project.id == selectedProjectID {
                syncViewer()
            }
        }
    }

    private func applyGeneratedGroupingResult(
        _ result: AIHunkGroupingResult,
        source: AIHunkGroupingSource,
        files: [FileChange],
        headOID: String?,
        replacingSessionID: UUID?,
        filter: AIHunkGroupingFilter? = nil,
        in project: Project
    ) {
        let sessionID = replacingSessionID ?? UUID()
        let firstGroup = result.groups.first
        let firstFile = firstGroup.flatMap { group in
            let tempSession = AIGroupSession(id: sessionID, source: source, result: result, files: files)
            return project.orderedGroupFiles(for: group, in: tempSession, flat: settings.flatList).first ?? group.files.first
        }

        let newSession = AIGroupSession(
            id: sessionID,
            source: source,
            result: result,
            files: files,
            selectedGroupID: firstGroup?.id,
            selectedGroupFilePath: firstFile?.path,
            selectedGroupHunkIndex: firstFile?.hunkIndices.first ?? 0,
            groupCommitMessages: [:],
            headOID: headOID,
            filter: filter
        )

        if let existingIdx = project.aiGroupSessions.firstIndex(where: { $0.id == sessionID }) {
            project.aiGroupSessions[existingIdx] = newSession
        } else {
            project.aiGroupSessions.append(newSession)
        }
        project.activeGroupSessionID = sessionID
        project.aiGroupError = nil
        project.lastFailedGroupTarget = nil
        project.groupCollapsed.removeAll()
        project.selectedGroupRowID = firstFile.map { ChangeRow.fileID($0.path) }

        if project.id == selectedProjectID, project.tab == .groups,
           let group = firstGroup, let file = firstFile {
            openGroupItem(project: project, group: group, filePath: file.path, hunkIndex: file.hunkIndices.first ?? 0)
        }
        persistAIGroups(for: project, headOIDOverride: headOID)

        let summary = result.groups.count == 1
            ? L("Grouped \(result.totalHunks) changes into 1 group", "已将 \(result.totalHunks) 处变更归为 1 组")
            : L("Grouped \(result.totalHunks) changes into \(result.groups.count) groups",
                "已将 \(result.totalHunks) 处变更分为 \(result.groups.count) 组")
        showToast(summary)
    }

    func cancelAIGroupGeneration(for project: Project) {
        project.cancelAIGroupGeneration(includeGroupCommitMessage: false)
    }

    // MARK: Session Management

    func selectAIGroupSession(_ sessionID: UUID, in project: Project) {
        guard let session = project.aiGroupSession(id: sessionID) else { return }
        if project.activeGroupSessionID != sessionID {
            project.activeGroupSessionID = sessionID
            project.aiGroupError = nil
            project.groupCollapsed.removeAll()
            project.selectedGroupRowID = session.selectedGroupFilePath.map(ChangeRow.fileID)
            schedulePersistAIGroups(for: project)
        }
        guard project.id == selectedProjectID else { return }
        if let group = session.activeGroup {
            let targetFile: AIHunkGroupFile? = {
                if let path = session.selectedGroupFilePath,
                   let existing = group.files.first(where: { $0.path == path }) {
                    return existing
                }
                return project.orderedGroupFiles(for: group, in: session, flat: settings.flatList).first ?? group.files.first
            }()
            if let file = targetFile {
                let targetHunk = session.selectedGroupFilePath == file.path
                    ? (session.selectedGroupHunkIndex ?? file.hunkIndices.first ?? 0)
                    : (file.hunkIndices.first ?? 0)
                openGroupItem(project: project, group: group, filePath: file.path, hunkIndex: targetHunk)
                return
            }
        }
        syncViewer()
    }

    /// Switches the Groups panel to the creation view so the user can start another grouping session.
    func startNewAIGroupSession(in project: Project) {
        if pendingGroupHunkFocus?.root == project.url {
            pendingGroupHunkFocus = nil
        }
        project.activeGroupSessionID = nil
        project.aiGroupError = nil
        project.groupCollapsed.removeAll()
        project.selectedGroupRowID = nil
        if project.id == selectedProjectID {
            syncViewer()
        }
    }

    /// Deletes a single grouping session from `project` without touching any other sessions or git state.
    func deleteAIGroupSession(_ sessionID: UUID, in project: Project) {
        guard !project.isCommittingGroup else { return }
        guard let previousIndex = project.aiGroupSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let removedSession = project.aiGroupSessions[previousIndex]

        if project.generatingGroupSessionID == sessionID {
            project.cancelAIGroupGeneration(includeGroupCommitMessage: removedSession.isCommittable)
        } else if removedSession.isCommittable {
            project.cancelGroupCommitMessageGeneration()
        }
        if project.isReviewing(sessionID: sessionID)
            || (project.activeGroupSessionID == sessionID && {
                if case .group = project.activeReviewTarget { return true }
                return false
            }()) {
            project.cancelAIReview()
        }

        if pendingGroupHunkFocus?.root == project.url, project.activeGroupSessionID == sessionID {
            pendingGroupHunkFocus = nil
        }

        project.aiGroupSessions.remove(at: previousIndex)

        if project.aiGroupSessions.isEmpty {
            project.activeGroupSessionID = nil
            project.selectedGroupRowID = nil
            project.groupCollapsed.removeAll()
            deletePersistedAIGroups(for: project)
            if project.id == selectedProjectID {
                viewer.setHighlightedGroupHunks(nil)
                syncViewer()
            }
            return
        }

        if project.activeGroupSessionID == sessionID {
            let nextIdx = min(max(0, previousIndex), project.aiGroupSessions.count - 1)
            let nextSession = project.aiGroupSessions[nextIdx]
            project.activeGroupSessionID = nextSession.id
            project.groupCollapsed.removeAll()
            project.selectedGroupRowID = nextSession.selectedGroupFilePath.map(ChangeRow.fileID)
        }
        persistAIGroups(for: project)

        if project.id == selectedProjectID {
            syncViewer()
        }
    }

    func deleteOtherAIGroupSessions(keeping sessionID: UUID, in project: Project) {
        guard !project.isCommittingGroup,
              let kept = project.aiGroupSession(id: sessionID) else { return }
        if let genID = project.generatingGroupSessionID, genID != sessionID {
            project.cancelAIGroupGeneration(includeGroupCommitMessage: false)
        }
        if !kept.isCommittable {
            project.cancelGroupCommitMessageGeneration()
        }
        project.aiGroupSessions = [kept]
        if project.activeGroupSessionID != sessionID {
            project.activeGroupSessionID = sessionID
            project.groupCollapsed.removeAll()
            project.selectedGroupRowID = kept.selectedGroupFilePath.map(ChangeRow.fileID)
        }
        persistAIGroups(for: project)
        if project.id == selectedProjectID {
            syncViewer()
        }
    }

    func clearAIGroups(for project: Project) {
        if pendingGroupHunkFocus?.root == project.url {
            pendingGroupHunkFocus = nil
        }
        if case .group = project.activeReviewTarget {
            project.cancelAIReview()
        } else if case .session = project.activeReviewTarget {
            project.cancelAIReview()
        }
        project.clearAIGroups()
        deletePersistedAIGroups(for: project)
        if project.id == selectedProjectID {
            viewer.setHighlightedGroupHunks(nil)
            syncViewer()
        }
    }

    /// Removes only working-tree grouping sessions (leaving comparison and commit-log sessions intact).
    func clearWorkingTreeAIGroups(for project: Project) {
        let hadActiveWT = project.activeAIGroupSession?.isCommittable == true
        if pendingGroupHunkFocus?.root == project.url, hadActiveWT {
            pendingGroupHunkFocus = nil
        }
        project.removeWorkingTreeAIGroupSessions()
        persistAIGroups(for: project)
        if project.id == selectedProjectID && hadActiveWT {
            syncViewer()
        }
    }

    /// Deletes a single logical group from the active session without touching git working-tree changes.
    func deleteAIGroup(_ group: AIHunkGroup, in project: Project) {
        guard !project.isCommittingGroup, let session = project.activeAIGroupSession else { return }
        let sessionID = session.id
        let groupID = group.id
        let previousIndex = session.result.groups.firstIndex(where: { $0.id == groupID })
        guard let updatedResult = AIHunkGrouper.resultAfterDeleting(groupID: groupID, in: session.result) else {
            deleteAIGroupSession(sessionID, in: project)
            return
        }

        if project.generatingGroupCommitID == groupID {
            project.cancelGroupCommitMessageGeneration()
        }
        if project.isReviewing(groupID: groupID) {
            project.cancelAIReview()
        }
        project.mutateAIGroupSession(id: sessionID) { s in
            s.groupCommitMessages.removeValue(forKey: groupID.uuidString)
            s.result = updatedResult
        }
        reconcileAIGroupSession(
            id: sessionID,
            removedGroupID: groupID,
            previousIndex: previousIndex,
            in: project
        )
        persistAIGroups(for: project)

        if project.id == selectedProjectID {
            syncViewer()
        }
    }

    /// Prunes or removes working-tree AI group sessions when files are committed outside the Groups tab.
    /// Non-committable sessions (comparison & commits) are unaffected.
    func updateAIGroupsAfterExternalCommit(
        committedPaths: Set<String>,
        in project: Project,
        newHeadOID: String?
    ) {
        guard !committedPaths.isEmpty else { return }
        let workingTreeIDs = project.aiGroupSessions.filter(\.isCommittable).map(\.id)
        guard !workingTreeIDs.isEmpty else { return }

        for sessionID in workingTreeIDs {
            guard let session = project.aiGroupSession(id: sessionID) else { continue }
            let previousIndex = session.selectedGroupID.flatMap { id in
                session.result.groups.firstIndex(where: { $0.id == id })
            }
            guard let updatedResult = AIHunkGrouper.resultAfterRemovingFiles(committedPaths, in: session.result) else {
                let idx = project.aiGroupSessions.firstIndex(where: { $0.id == sessionID })
                project.aiGroupSessions.removeAll { $0.id == sessionID }
                if project.activeGroupSessionID == sessionID {
                    if let firstRemaining = idx.flatMap({ i in
                        project.aiGroupSessions.isEmpty ? nil : project.aiGroupSessions[min(i, project.aiGroupSessions.count - 1)]
                    }) {
                        project.activeGroupSessionID = firstRemaining.id
                        project.selectedGroupRowID = firstRemaining.selectedGroupFilePath.map(ChangeRow.fileID)
                    } else {
                        project.activeGroupSessionID = nil
                        project.selectedGroupRowID = nil
                    }
                    project.groupCollapsed.removeAll()
                }
                continue
            }
            project.mutateAIGroupSession(id: sessionID) { s in
                s.result = updatedResult
                if let newHeadOID { s.headOID = newHeadOID }
            }
            reconcileAIGroupSession(
                id: sessionID,
                removedGroupID: nil,
                previousIndex: previousIndex,
                in: project
            )
        }
        persistAIGroups(for: project, headOIDOverride: newHeadOID)
    }

    // MARK: AI Group Persistence

    func restoreAIGroups(for project: Project) {
        guard !AppEnvironment.isAppStore else { return }
        guard let state = aiGroupStorage.load(for: project.url) else { return }
        project.restoreAIGroupState(state)
    }

    func persistAIGroups(for project: Project, headOIDOverride: String? = nil) {
        aiGroupPersistTasks.removeValue(forKey: project.id)?.cancel()
        guard !AppEnvironment.isAppStore else { return }
        if let state = project.persistedAIGroupState(headOIDOverride: headOIDOverride) {
            aiGroupStorage.save(state, for: project.url)
        } else {
            aiGroupStorage.delete(for: project.url)
        }
    }

    func schedulePersistAIGroups(for project: Project) {
        aiGroupPersistTasks.removeValue(forKey: project.id)?.cancel()
        guard !AppEnvironment.isAppStore else { return }
        aiGroupPersistTasks[project.id] = Task { @MainActor [weak self, weak project] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard let self, let project else { return }
            self.aiGroupPersistTasks.removeValue(forKey: project.id)
            self.persistAIGroups(for: project)
        }
    }

    func deletePersistedAIGroups(for project: Project) {
        aiGroupPersistTasks.removeValue(forKey: project.id)?.cancel()
        aiGroupStorage.delete(for: project.url)
    }

    func flushAllPersistedAIGroups() {
        for (_, task) in aiGroupPersistTasks {
            task.cancel()
        }
        aiGroupPersistTasks.removeAll()
        guard !AppEnvironment.isAppStore else { return }
        for project in projects where !project.aiGroupSessions.isEmpty {
            persistAIGroups(for: project)
        }
    }

    private func reconcileAIGroupSession(
        id sessionID: UUID,
        removedGroupID: UUID? = nil,
        previousIndex: Int? = nil,
        in project: Project
    ) {
        guard let session = project.aiGroupSession(id: sessionID) else { return }
        let updatedResult = session.result
        guard !updatedResult.groups.isEmpty else { return }

        let validIDs = Set(updatedResult.groups.map(\.id))
        let isActiveSession = project.activeGroupSessionID == sessionID

        project.mutateAIGroupSession(id: sessionID) { s in
            if s.groupCommitMessages.keys.contains(where: { UUID(uuidString: $0).map { !validIDs.contains($0) } ?? true }) {
                s.groupCommitMessages = s.groupCommitMessages.filter { key, _ in
                    UUID(uuidString: key).map { validIDs.contains($0) } ?? false
                }
            }

            let needsReselect = s.selectedGroupID == nil
                || (removedGroupID != nil && s.selectedGroupID == removedGroupID)
                || !validIDs.contains(s.selectedGroupID!)
            if needsReselect {
                let nextIdx = min(max(0, previousIndex ?? 0), updatedResult.groups.count - 1)
                let nextGroup = updatedResult.groups[nextIdx]
                s.selectedGroupID = nextGroup.id
                let firstFile = project.orderedGroupFiles(for: nextGroup, in: s, flat: settings.flatList).first ?? nextGroup.files.first
                s.selectedGroupFilePath = firstFile?.path
                s.selectedGroupHunkIndex = firstFile?.hunkIndices.first ?? 0
            } else if let activeID = s.selectedGroupID,
                      let activeGroup = updatedResult.groups.first(where: { $0.id == activeID }) {
                if let currentPath = s.selectedGroupFilePath,
                   let activeFile = activeGroup.files.first(where: { $0.path == currentPath }) {
                    if let hunk = s.selectedGroupHunkIndex, !activeFile.hunkIndices.contains(hunk) {
                        s.selectedGroupHunkIndex = activeFile.hunkIndices.first ?? 0
                    }
                } else if let firstFile = project.orderedGroupFiles(for: activeGroup, in: s, flat: settings.flatList).first ?? activeGroup.files.first {
                    s.selectedGroupFilePath = firstFile.path
                    s.selectedGroupHunkIndex = firstFile.hunkIndices.first ?? 0
                } else {
                    s.selectedGroupFilePath = nil
                    s.selectedGroupHunkIndex = nil
                }
            }
        }

        if let generatingID = project.generatingGroupCommitID, !validIDs.contains(generatingID), isActiveSession {
            project.cancelGroupCommitMessageGeneration()
        }
        if isActiveSession {
            if removedGroupID != nil {
                project.groupCollapsed.removeAll()
            }
            project.selectedGroupRowID = project.aiGroupSession(id: sessionID)?.selectedGroupFilePath.map(ChangeRow.fileID)
        }
    }

    /// Selects `group` in the top Groups pane, updates the bottom changes list, and opens its first file
    /// with the group's hunk filter applied in a single pass.
    func selectAIGroup(_ group: AIHunkGroup, in project: Project, openFirstFile: Bool = true) {
        guard let session = project.activeAIGroupSession else { return }
        let changedGroup = session.selectedGroupID != group.id
        if changedGroup {
            project.mutateAIGroupSession(id: session.id) { $0.selectedGroupID = group.id }
            project.groupCollapsed.removeAll()
            schedulePersistAIGroups(for: project)
        }
        guard project.id == selectedProjectID else { return }

        if !changedGroup,
           let currentPath = session.selectedGroupFilePath,
           let existingFile = group.files.first(where: { $0.path == currentPath }),
           project.browsedPath == nil,
           externalRequest == nil,
           viewer.request?.root == project.url,
           viewer.request?.path == currentPath {
            let targetHunk = session.selectedGroupHunkIndex ?? existingFile.hunkIndices.first ?? 0
            openGroupItem(project: project, group: group, filePath: existingFile.path, hunkIndex: targetHunk)
            return
        }

        guard openFirstFile,
              let firstFile = project.orderedGroupFiles(for: group, in: session, flat: settings.flatList).first ?? group.files.first else {
            return
        }
        openGroupItem(project: project, group: group, filePath: firstFile.path, hunkIndex: firstFile.hunkIndices.first ?? 0)
    }

    /// Selects a file and hunk inside an AI group, opening its diff on the right
    /// with the group's hunk filter applied synchronously and focusing raw `hunkIndex` once loaded.
    func openGroupItem(project: Project, group: AIHunkGroup, filePath: String, hunkIndex: Int) {
        guard project.id == selectedProjectID, let session = project.activeAIGroupSession else { return }
        exitExternalFileMode()
        project.browsedPath = nil
        let selectionChanged = session.selectedGroupID != group.id
            || session.selectedGroupFilePath != filePath
            || session.selectedGroupHunkIndex != hunkIndex
        project.mutateAIGroupSession(id: session.id) { s in
            s.selectedGroupID = group.id
            s.selectedGroupFilePath = filePath
            s.selectedGroupHunkIndex = hunkIndex
        }
        project.selectedGroupRowID = ChangeRow.fileID(filePath)
        if selectionChanged {
            schedulePersistAIGroups(for: project)
        }

        guard let rawRequest = project.diffRequest(for: filePath, in: session, ignoreWhitespace: settings.ignoreWhitespace) else {
            viewer.highlightedGroupHunks = nil
            viewer.clear()
            return
        }
        let request = resolvedRequest(rawRequest)
        let baseStamp = session.baseStamp(projectHeadOID: project.status.headOID)

        noteRecent(project, filePath)
        follow(filePath, in: project)
        viewer.setBaseStamp(baseStamp)

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
        let sameFile = viewer.request?.path == request.path && viewer.request?.root == request.root && viewer.request?.source != .file
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

    // MARK: Direct Group Commit (Working Tree Only)

    /// Commits ONLY the hunks belonging to `group` using its current commit message draft
    /// (without mutating Tab 1's file checkboxes or line exclusions). Only enabled for `.workingTree` sessions.
    func commitGroup(for project: Project, group: AIHunkGroup) {
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard let session = project.activeAIGroupSession, session.isCommittable else { return }
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

        // Cancel any in-flight working-tree regrouping against the old HEAD so it cannot overwrite post-commit groups.
        if project.isGeneratingGroups, project.generatingGroupSource?.isCommittable == true {
            project.cancelAIGroupGeneration(includeGroupCommitMessage: false)
        }
        if project.generatingGroupCommitID == group.id {
            project.cancelGroupCommitMessageGeneration()
        }

        let allChanges = project.changes
        let allGroups = session.result.groups
        let repoRoot = project.url
        let isInitial = project.status.isInitial
        let sessionID = session.id
        let groupID = group.id
        let groupName = group.name

        project.isCommittingGroup = true
        Task { @MainActor [weak self, weak project] in
            guard let self, let project else { return }
            defer { project.isCommittingGroup = false }
            do {
                let selection = try await AIHunkGrouper.buildCommitSelection(
                    for: group,
                    allGroups: allGroups,
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

                if let currentSession = project.aiGroupSession(id: sessionID) {
                    let previousIndex = currentSession.result.groups.firstIndex(where: { $0.id == groupID })
                    if let updatedResult = AIHunkGrouper.resultAfterCommitting(groupID: groupID, in: currentSession.result) {
                        project.mutateAIGroupSession(id: sessionID) { s in
                            s.groupCommitMessages.removeValue(forKey: groupID.uuidString)
                            s.result = updatedResult
                            s.headOID = result.hash
                        }
                        self.reconcileAIGroupSession(
                            id: sessionID,
                            removedGroupID: groupID,
                            previousIndex: previousIndex,
                            in: project
                        )
                        self.persistAIGroups(for: project, headOIDOverride: result.hash)
                    } else {
                        self.deleteAIGroupSession(sessionID, in: project)
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
        guard let session = project.activeAIGroupSession, session.isCommittable else { return }
        guard !project.isCommittingGroup, !project.isCommitting else { return }
        guard viewer.saveEdits() else { return }

        let format = settings.effectiveCommitMessageFormat
        let provider = settings.aiProvider(for: .commit)
        let model = settings.aiModel(for: provider, task: .commit)
        let allChanges = project.changes
        let allGroups = session.result.groups
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
                    allGroups: allGroups,
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
                self.persistAIGroups(for: project)
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
        persistAIGroups(for: project)
    }
}
