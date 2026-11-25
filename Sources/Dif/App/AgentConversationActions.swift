import AppKit
import Foundation

/// Actions for opening, streaming, cancelling, and continuing multi-turn AI Agent conversations.
extension AppStore {
    /// Streams `AgentStreamEvent`s strictly FIFO into `turnID` of `conversation` while running `operation`,
    /// guaranteeing the event consumer drains all buffered events before returning or rethrowing.
    func withAgentStream<T: Sendable>(
        for conversation: AgentConversation,
        turnID: UUID,
        operation: (_ onEvent: @escaping AgentStreamHandler) async throws -> T
    ) async throws -> T {
        let (stream, continuation) = AsyncStream.makeStream(of: AgentStreamEvent.self)
        let consumer = Task { @MainActor [weak conversation] in
            guard let conversation else { return }
            for await event in stream {
                conversation.apply(event, toTurnID: turnID)
            }
        }
        do {
            let value = try await operation { event in
                continuation.yield(event)
            }
            continuation.finish()
            await consumer.value
            return value
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    /// Opens the Agent Conversation popup inspecting `conversation`.
    func openAgentConversation(_ conversation: AgentConversation) {
        activeAgentConversationID = conversation.id
        present(.agentConversation)
    }

    /// Opens the Markdown review report associated with `conversation`, if one has been saved.
    func openAgentConversationReport(_ conversation: AgentConversation) {
        guard let fileURL = conversation.reportFileURL else { return }
        if !openReviewFile(fileURL) {
            showToast(
                L("Could not open report in default Markdown app.", "无法用默认 Markdown 应用打开审查报告。"),
                action: ToastAction(title: L("Reveal in Finder", "在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            )
        }
    }

    /// Stops any currently executing initial pass or follow-up turn on `conversation`.
    func cancelAgentConversation(_ conversation: AgentConversation) {
        if conversation.followUpTask != nil {
            conversation.followUpToken &+= 1
            conversation.followUpTask?.cancel()
            conversation.followUpTask = nil
            if let lastTurn = conversation.latestTurn, lastTurn.status.isRunning {
                conversation.finishTurn(lastTurn.id, status: .cancelled)
            }
            return
        }
        if let project = projects.first(where: { $0.id == conversation.projectID }) {
            switch conversation.kind {
            case .review where project.isReviewing:
                cancelAIReview(in: project)
            case .grouping where project.isGeneratingGroups:
                cancelAIGroupGeneration(for: project)
            default:
                if let lastTurn = conversation.latestTurn, lastTurn.status.isRunning {
                    conversation.finishTurn(lastTurn.id, status: .cancelled)
                }
            }
        } else if let lastTurn = conversation.latestTurn, lastTurn.status.isRunning {
            conversation.finishTurn(lastTurn.id, status: .cancelled)
        }
    }

    /// Sends a read-only follow-up user message on an existing `AgentConversation`, resuming the native provider session
    /// when possible and falling back cleanly to a transcript-context prompt if native resume fails before output.
    func sendAgentConversationFollowUp(
        _ conversation: AgentConversation,
        message: String,
        service: LocalAgentService = .shared
    ) {
        guard !AppEnvironment.isAppStore else {
            showToast(AIReviewError.unavailableInAppStore.localizedDescription)
            return
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !conversation.isRunning else { return }

        conversation.draftMessage = ""
        let turn = AgentConversationTurn(userPromptDisplay: trimmed, fullPrompt: trimmed, status: .running)
        let turnID = turn.id
        conversation.turns.append(turn)
        conversation.status = .running

        conversation.followUpToken &+= 1
        let token = conversation.followUpToken
        let provider = conversation.provider
        let model = conversation.model
        let repoRoot = conversation.repoRoot
        let initialResumeID = conversation.remoteSessionID
        let isChinese = Localization.isChinese

        conversation.followUpTask = Task { @MainActor [weak self, weak conversation] in
            guard let self, let conversation else { return }
            defer {
                if conversation.followUpToken == token {
                    conversation.followUpTask = nil
                }
            }

            do {
                let result: AgentGenerateResult
                do {
                    result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                        try await service.generateWithSession(
                            provider: provider,
                            model: model,
                            cwd: repoRoot,
                            prompt: trimmed,
                            jsonSchema: nil,
                            toolAccess: .readOnly,
                            resumeSessionID: initialResumeID,
                            persistSession: true,
                            timeout: AICodeReviewer.defaultTimeout,
                            onEvent: onEvent
                        )
                    }
                } catch let agentError as LocalAgentError where initialResumeID != nil {
                    if case .timedOut = agentError {
                        throw agentError
                    }
                    let hasAssistantOutput = conversation.turns
                        .first(where: { $0.id == turnID })?
                        .assistantText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty == false
                    guard !hasAssistantOutput else {
                        throw agentError
                    }

                    let fallbackPrompt = conversation.buildTranscriptFallbackPrompt(
                        nextUserMessage: trimmed,
                        isChinese: isChinese
                    )
                    conversation.setFullPrompt(fallbackPrompt, forTurnID: turnID)
                    conversation.appendStatusNote(
                        L("Native session resume unavailable (\(agentError.localizedDescription)); continuing in a new read-only session with prior context.",
                          "原生会话续接不可用（\(agentError.localizedDescription)），已携带上下文开启只读新会话。"),
                        toTurnID: turnID
                    )
                    result = try await self.withAgentStream(for: conversation, turnID: turnID) { onEvent in
                        try await service.generateWithSession(
                            provider: provider,
                            model: model,
                            cwd: repoRoot,
                            prompt: fallbackPrompt,
                            jsonSchema: nil,
                            toolAccess: .readOnly,
                            resumeSessionID: nil,
                            persistSession: true,
                            timeout: AICodeReviewer.defaultTimeout,
                            onEvent: onEvent
                        )
                    }
                }

                try Task.checkCancellation()
                guard conversation.followUpToken == token else { return }
                if let sid = result.sessionID, !sid.isEmpty {
                    conversation.remoteSessionID = sid
                }
                conversation.finishTurn(turnID, status: .completed, finalText: result.text)
            } catch is CancellationError {
                guard conversation.followUpToken == token else { return }
                conversation.finishTurn(turnID, status: .cancelled)
            } catch {
                guard conversation.followUpToken == token else { return }
                conversation.finishTurn(turnID, status: .failed(error.localizedDescription))
            }
        }
    }
}
