import AppKit
import Foundation

/// AI Code Review actions for Working Tree changes, Branch/Commit/Stash comparisons, AI Groups, and Grouping Sessions.
extension AppStore {
    /// Human-readable description of the agent & model currently configured for `.review`.
    func aiReviewAgentDescription() -> String {
        let provider = settings.aiProvider(for: .review)
        let model = settings.aiModel(for: provider, task: .review)
        return model.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
    }

    /// Reviews whatever context the user is currently looking at (selected AI group when in Groups, else active Changes / Comparison).
    func reviewActiveContext(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        if project.tab == .groups,
           let session = project.activeAIGroupSession,
           let group = session.activeGroup {
            reviewGroup(group, in: session, project: project)
        } else {
            reviewChanges(in: project)
        }
    }

    /// Reviews the active Changes view: comparison/stash if open, otherwise working-tree changes.
    /// Calling again while a Changes review is in progress cancels it.
    func reviewChanges(in project: Project? = nil) {
        guard let project = project ?? currentProject else { return }
        if project.isReviewingChanges {
            cancelAIReview(in: project)
            return
        }
        if let comparison = project.comparison {
            reviewComparisonChanges(in: project, comparison: comparison)
        } else {
            reviewWorkingTreeChanges(in: project)
        }
    }

    /// Reviews the working-tree changes in `project` (prioritizing ticked files/lines; falls back to all changes if none are ticked).
    func reviewWorkingTreeChanges(in project: Project) {
        if project.activeReviewTarget == .workingTree {
            cancelAIReview(in: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AIReviewError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !project.changes.isEmpty else {
            showToast(AIReviewError.noChangesToReview.localizedDescription)
            return
        }
        guard viewer.saveEdits() else { return }

        let included = project.includedChanges
        let filesToReview = included.isEmpty ? project.changes : included
        let excludedToReview = included.isEmpty ? [:] : project.excludedLines
        let isPartial = !included.isEmpty && (included.count < project.changes.count || !project.excludedLines.isEmpty)

        runAIReview(
            in: project,
            target: .workingTree,
            scope: .workingTree(
                files: filesToReview,
                excludedLines: excludedToReview,
                isInitial: project.status.isInitial,
                isPartialSelection: isPartial
            )
        )
    }

    /// Reviews the active branch, commit, or stash comparison in `project`.
    func reviewComparisonChanges(in project: Project, comparison: Comparison? = nil) {
        if project.activeReviewTarget == .comparison {
            cancelAIReview(in: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AIReviewError.unavailableInAppStore.localizedDescription)
            return
        }
        guard let activeComparison = comparison ?? project.comparison,
              !project.isLoadingCompare,
              !project.compareChanges.isEmpty else {
            showToast(AIReviewError.noChangesToReview.localizedDescription)
            return
        }
        if activeComparison.head == nil {
            guard viewer.saveEdits() else { return }
        }
        guard case .comparison(let compSource) = AIHunkGroupingSource.from(comparison: activeComparison) else {
            return
        }
        runAIReview(
            in: project,
            target: .comparison,
            scope: .comparison(compSource, files: project.compareChanges)
        )
    }

    /// Reviews a single AI logical `group` inside `session` of `project`.
    func reviewGroup(_ group: AIHunkGroup, in session: AIGroupSession, project: Project) {
        if project.isReviewing(groupID: group.id) {
            cancelAIReview(in: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AIReviewError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !group.files.isEmpty else {
            showToast(AIReviewError.noChangesToReview.localizedDescription)
            return
        }
        if session.isCommittable {
            guard viewer.saveEdits() else { return }
        }
        let files = session.isCommittable ? project.changes : session.files
        runAIReview(
            in: project,
            target: .group(group.id),
            scope: .group(
                group: group,
                allGroups: session.result.groups,
                source: session.source,
                files: files,
                isInitial: project.status.isInitial
            )
        )
    }

    /// Reviews all changes across an entire AI grouping `session` in `project`.
    func reviewAIGroupSession(_ session: AIGroupSession, in project: Project) {
        if project.isReviewing(sessionID: session.id) {
            cancelAIReview(in: project)
            return
        }
        guard !AppEnvironment.isAppStore else {
            showToast(AIReviewError.unavailableInAppStore.localizedDescription)
            return
        }
        guard !session.result.groups.isEmpty else {
            showToast(AIReviewError.noChangesToReview.localizedDescription)
            return
        }
        if session.isCommittable {
            guard viewer.saveEdits() else { return }
        }
        let files = session.isCommittable ? project.changes : session.files
        runAIReview(
            in: project,
            target: .session(session.id),
            scope: .session(
                source: session.source,
                groups: session.result.groups,
                files: files,
                isInitial: project.status.isInitial
            )
        )
    }

    /// Cancels any active AI code review run in `project`.
    func cancelAIReview(in project: Project) {
        guard project.isReviewing else { return }
        project.cancelAIReview()
        showToast(L("Code review cancelled", "已取消代码审查"))
    }

    /// Launches `AICodeReviewer.generate` asynchronously, streams live agent activity into an `AgentConversation`,
    /// opens the saved `.md` file with the default Markdown app, and shows actionable toast feedback.
    func runAIReview(
        in project: Project,
        target: Project.AIReviewTarget,
        scope: AIReviewScope,
        service: LocalAgentService = .shared
    ) {
        let provider = settings.aiProvider(for: .review)
        let model = settings.aiModel(for: provider, task: .review)
        let repoRoot = project.url
        let repoContext = AIReviewRepoContext(
            branch: project.status.branch,
            headOID: project.status.headOID
        )
        let isChinese = Localization.isChinese
        let token = project.beginAIReview(target: target)

        let summaryLines = scope.promptContextLines(repoContext: repoContext, isChinese: isChinese)
            .prefix(4)
            .joined(separator: "\n")
        let conversation = AgentConversation(
            projectID: project.id,
            repoRoot: repoRoot,
            kind: .review,
            reviewTarget: target,
            title: scope.displayTitle,
            provider: provider,
            model: model,
            toolAccess: .readOnly,
            initialUserPromptDisplay: "\(scope.displayTitle)\n\(summaryLines)"
        )
        project.registerAgentConversation(conversation)
        let turnID = conversation.turns[0].id

        showToast(L("Generating review report with \(aiReviewAgentDescription())…",
                    "正在使用 \(aiReviewAgentDescription()) 生成代码审查报告…"))

        project.aiReviewTask = Task { @MainActor [weak self, weak project, weak conversation] in
            guard let self, let project, let conversation else { return }
            defer {
                project.finishAIReview(token: token)
            }
            do {
                let result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                    try await AICodeReviewer.generate(
                        repoRoot: repoRoot,
                        scope: scope,
                        repoContext: repoContext,
                        provider: provider,
                        model: model,
                        isChinese: isChinese,
                        persistSession: true,
                        service: service,
                        onSummaryReady: { [weak conversation] summary in
                            Task { @MainActor [weak conversation] in
                                conversation?.setUserPromptDisplay(summary, forTurnID: turnID)
                            }
                        },
                        onPromptReady: { [weak conversation] fullPrompt in
                            Task { @MainActor [weak conversation] in
                                conversation?.setFullPrompt(fullPrompt, forTurnID: turnID)
                            }
                        },
                        onEvent: onEvent
                    )
                }
                try Task.checkCancellation()
                guard project.aiReviewToken == token else { return }

                conversation.reportFileURL = result.fileURL
                if let sid = result.sessionID, !sid.isEmpty {
                    conversation.remoteSessionID = sid
                }
                let fileName = result.fileURL.lastPathComponent
                conversation.appendStatusNote(
                    L("Saved review report: \(fileName)", "已保存审查报告：\(fileName)"),
                    toTurnID: turnID
                )
                conversation.finishTurn(turnID, status: .completed, finalText: result.markdown)

                let opened = self.openReviewFile(result.fileURL)
                let message = opened
                    ? L("Review report opened: \(fileName)", "已生成并用默认应用打开审查报告：\(fileName)")
                    : L("Review report saved: \(fileName)", "审查报告已保存：\(fileName)")
                self.showToast(
                    message,
                    action: ToastAction(title: opened ? L("Reveal in Finder", "在 Finder 中显示") : L("Open Report", "打开报告")) {
                        if opened {
                            NSWorkspace.shared.activateFileViewerSelecting([result.fileURL])
                        } else {
                            self.openAgentConversationReport(conversation)
                        }
                    }
                )
            } catch is CancellationError {
                guard project.aiReviewToken == token else { return }
                conversation.finishTurn(turnID, status: .cancelled)
            } catch {
                guard project.aiReviewToken == token else { return }
                project.aiReviewError = error.localizedDescription
                conversation.finishTurn(turnID, status: .failed(error.localizedDescription))
                self.showToast(
                    error.localizedDescription,
                    action: ToastAction(title: L("View Stream", "查看对话")) {
                        self.openAgentConversation(conversation)
                    }
                )
            }
        }
    }
}
