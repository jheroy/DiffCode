import Foundation
import Observation

/// Identifies the origin task of a local AI agent conversation stream.
enum AgentConversationKind: String, Equatable, Hashable, Sendable {
    case review
    case grouping

    var localizedTitle: String {
        switch self {
        case .review: return L("Code Review", "代码审查")
        case .grouping: return L("AI Grouping", "AI 分组")
        }
    }

    var symbolName: String {
        switch self {
        case .review: return "doc.text.magnifyingglass"
        case .grouping: return "sparkles"
        }
    }
}

/// Lifecycle state for an agent conversation or an individual turn inside it.
enum AgentConversationStatus: Equatable, Sendable {
    case running
    case completed
    case failed(String)
    case cancelled

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Recorded tool invocation inside an agent conversation turn.
struct AgentToolCallRecord: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var kind: String?
    var input: String?
    var status: String
    var output: String?
}

/// One user -> agent interaction turn (either the initial review/grouping pass or a follow-up question).
struct AgentConversationTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    var userPromptDisplay: String
    var fullPrompt: String?
    var thinking: String = ""
    var toolCalls: [AgentToolCallRecord] = []
    var statusNotes: [String] = []
    var assistantText: String = ""
    var status: AgentConversationStatus = .running
    let startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        userPromptDisplay: String,
        fullPrompt: String? = nil,
        status: AgentConversationStatus = .running,
        startedAt: Date = Date()
    ) {
        self.id = id
        self.userPromptDisplay = userPromptDisplay
        self.fullPrompt = fullPrompt
        self.status = status
        self.startedAt = startedAt
    }
}

/// Observable conversation log and live execution stream for one AI Review or AI Grouping run,
/// supporting multi-turn follow-up conversation inside DiffCode.
@MainActor
@Observable
final class AgentConversation: Identifiable {
    let id: UUID
    let projectID: UUID
    let repoRoot: URL
    let kind: AgentConversationKind
    let reviewTarget: Project.AIReviewTarget?
    var title: String
    let provider: AgentProvider
    let model: String?
    let toolAccess: AgentToolAccess
    var remoteSessionID: String?
    var reportFileURL: URL?
    var turns: [AgentConversationTurn]
    var status: AgentConversationStatus
    var draftMessage: String = ""
    let createdAt: Date

    @ObservationIgnored var followUpTask: Task<Void, Never>?
    @ObservationIgnored var followUpToken: UInt64 = 0

    var isRunning: Bool {
        status == .running || followUpTask != nil
    }

    var hasFailed: Bool {
        status.isFailed
    }

    var latestTurn: AgentConversationTurn? {
        turns.last
    }

    init(
        id: UUID = UUID(),
        projectID: UUID,
        repoRoot: URL,
        kind: AgentConversationKind,
        reviewTarget: Project.AIReviewTarget? = nil,
        title: String,
        provider: AgentProvider,
        model: String?,
        toolAccess: AgentToolAccess,
        initialUserPromptDisplay: String,
        initialFullPrompt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.repoRoot = repoRoot
        self.kind = kind
        self.reviewTarget = reviewTarget
        self.title = title
        self.provider = provider
        self.model = model
        self.toolAccess = toolAccess
        self.turns = [
            AgentConversationTurn(
                userPromptDisplay: initialUserPromptDisplay,
                fullPrompt: initialFullPrompt,
                status: .running,
                startedAt: createdAt
            ),
        ]
        self.status = .running
        self.createdAt = createdAt
    }

    /// Applies one incremental `AgentStreamEvent` to the turn identified by `turnID`.
    func apply(_ event: AgentStreamEvent, toTurnID turnID: UUID) {
        if case .sessionStarted(let sid) = event {
            let trimmed = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                remoteSessionID = trimmed
            }
            return
        }

        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }

        switch event {
        case .sessionStarted:
            break

        case .thinkingDelta(let chunk):
            turns[index].thinking.append(chunk)

        case .messageDelta(let chunk):
            turns[index].assistantText.append(chunk)

        case .toolActivity(let toolID, let title, let kind, let input, let status, let output):
            if let existingIdx = turns[index].toolCalls.firstIndex(where: { $0.id == toolID }) {
                var record = turns[index].toolCalls[existingIdx]
                if !title.isEmpty { record.title = title }
                if let kind, !kind.isEmpty { record.kind = kind }
                if let input, !input.isEmpty { record.input = input }
                if let status, !status.isEmpty { record.status = status }
                if let output, !output.isEmpty { record.output = output }
                turns[index].toolCalls[existingIdx] = record
            } else {
                let fallbackTitle = title.isEmpty ? (kind ?? "tool") : title
                let record = AgentToolCallRecord(
                    id: toolID,
                    title: fallbackTitle,
                    kind: kind,
                    input: input,
                    status: status ?? "running",
                    output: output
                )
                turns[index].toolCalls.append(record)
            }

        case .statusNote(let note):
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            turns[index].statusNotes.append(trimmed)
        }
    }

    /// Finalizes `turnID` and conversation status, backfilling `assistantText` when non-streamed output was returned.
    func finishTurn(_ turnID: UUID, status newStatus: AgentConversationStatus, finalText: String? = nil) {
        let now = Date()
        if let index = turns.firstIndex(where: { $0.id == turnID }) {
            turns[index].status = newStatus
            turns[index].finishedAt = now
            if let finalText,
               !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               turns[index].assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                turns[index].assistantText = finalText
            }
        }
        status = newStatus
    }

    /// Appends a note line directly to a turn (e.g. saved report path or fallback notice).
    func appendStatusNote(_ note: String, toTurnID turnID: UUID) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].statusNotes.append(trimmed)
    }

    /// Updates the concise human-readable prompt summary for a turn (e.g. once commit filtering finishes).
    func setUserPromptDisplay(_ display: String, forTurnID turnID: UUID) {
        let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].userPromptDisplay = trimmed
    }

    /// Sets the expanded underlying prompt captured right before launching the agent.
    func setFullPrompt(_ prompt: String, forTurnID turnID: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == turnID }) else { return }
        turns[index].fullPrompt = prompt
    }

    /// Constructs a self-contained context prompt for follow-up turns when native provider session resume is unavailable.
    func buildTranscriptFallbackPrompt(nextUserMessage: String, isChinese: Bool) -> String {
        let canonicalRoot = repoRoot.standardizedFileURL.path
        var sections: [String] = []
        if isChinese {
            sections.append("""
            你是正在协助用户审查/分析仓库的资深工程师。以下是本次「\(title)」任务之前的对话上下文；请基于这些上下文与**只读**仓库查询回答用户的后续问题，禁止修改仓库文件。
            仓库根目录：`\(canonicalRoot)`
            如果引用具体文件位置，可使用 DiffCode 魔术链接：`[文件:行号](diffcode://open?path=<URL编码后的绝对路径>&line=<行号>)`。
            """)
        } else {
            sections.append("""
            You are continuing a local read-only engineering conversation for "\(title)". Answer the user's follow-up question below using this transcript and read-only repository inspection only (never modify files).
            Repository root: `\(canonicalRoot)`
            When referencing files/lines, you may emit clickable DiffCode links: `[file:line](diffcode://open?path=<percent-encoded-absolute-path>&line=<line>)`.
            """)
        }

        let maxTurnChars = 3500
        let maxTranscriptChars = 24_000
        var transcriptParts: [String] = []
        var totalChars = 0

        for (idx, turn) in turns.enumerated() where idx < turns.count {
            // Skip an empty running placeholder turn matching nextUserMessage
            if turn.status.isRunning && turn.userPromptDisplay == nextUserMessage && turn.assistantText.isEmpty {
                continue
            }
            var turnBlock = "### Turn \(idx + 1)\nUser: \(turn.userPromptDisplay)\n"
            if idx == 0, let full = turn.fullPrompt, !full.isEmpty {
                let contextMarker = full.range(of: "## 审查上下文") ?? full.range(of: "## Review Context")
                let diffMarker = full.range(of: "## 带行号的变更上下文") ?? full.range(of: "## Context-Rich Diff")
                if let start = contextMarker?.lowerBound {
                    let end = diffMarker?.lowerBound ?? full.endIndex
                    let slice = String(full[start..<min(end, full.index(start, offsetBy: min(1800, full.distance(from: start, to: end))))])
                    turnBlock += "\(slice)\n"
                }
            }
            let reply = turn.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reply.isEmpty {
                let clippedReply = reply.count > maxTurnChars
                    ? String(reply.prefix(maxTurnChars)) + "\n… [truncated]"
                    : reply
                turnBlock += "Assistant:\n\(clippedReply)\n"
            } else if let err = turn.status.errorMessage {
                turnBlock += "Error: \(err)\n"
            }
            if totalChars + turnBlock.count > maxTranscriptChars {
                break
            }
            transcriptParts.append(turnBlock)
            totalChars += turnBlock.count
        }

        if !transcriptParts.isEmpty {
            sections.append(transcriptParts.joined(separator: "\n"))
        }

        sections.append(isChinese
            ? "## 用户最新追问\n\(nextUserMessage)"
            : "## Follow-up Question\n\(nextUserMessage)")
        return sections.joined(separator: "\n\n")
    }
}
