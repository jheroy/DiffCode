import AppKit
import SwiftUI

/// Popup window showing live streaming thoughts, tool executions, status logs, and Markdown answers
/// for an AI Review or AI Grouping run, plus a composer to continue the conversation.
struct AgentConversationPopupView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let conversation = store.activeAgentConversation {
            AgentConversationBody(conversation: conversation)
        } else {
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button { store.dismissPopup() } label: {
                        Image(systemName: "xmark")
                            .font(.ui(size: 11, weight: .bold))
                            .foregroundStyle(Color.difText2)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                Spacer()
                EmptyListState(
                    symbol: "bubble.left.and.text.bubble.right",
                    title: L("No Agent Conversation Selected", "暂无可查看的 Agent 对话"),
                    detail: L("Trigger AI Review or AI Grouping first to inspect the live conversation stream.",
                              "请先点击“审查”或“AI 分组”，即可在此查看详细对话流并继续追问。")
                )
                Spacer()
            }
        }
    }
}

private struct AgentConversationBody: View {
    @Bindable var conversation: AgentConversation
    @Environment(AppStore.self) private var store
    @State private var composerFocused = false
    @State private var composerFocusToken = 1

    private var projectConversations: [AgentConversation] {
        store.projects.first(where: { $0.id == conversation.projectID })?.agentConversations ?? [conversation]
    }

    private var scrollFingerprint: Int {
        var hasher = Hasher()
        hasher.combine(conversation.id)
        hasher.combine(conversation.turns.count)
        if let last = conversation.turns.last {
            hasher.combine(last.thinking.count)
            hasher.combine(last.toolCalls.count)
            hasher.combine(last.statusNotes.count)
            hasher.combine(last.assistantText.count)
            hasher.combine(last.status.isRunning)
            hasher.combine(last.toolCalls.last?.status)
            hasher.combine(last.toolCalls.last?.output?.count ?? 0)
        }
        return hasher.finalize()
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Rectangle().fill(Color.difHairline).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(conversation.turns.enumerated()), id: \.element.id) { index, turn in
                            AgentTurnCard(
                                turn: turn,
                                turnNumber: index + 1,
                                onOpenURL: handleURL
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("agent-stream-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .onAppear {
                    proxy.scrollTo("agent-stream-bottom", anchor: .bottom)
                }
                .onChange(of: scrollFingerprint) { _, _ in
                    proxy.scrollTo("agent-stream-bottom", anchor: .bottom)
                }
            }
            .environment(\.openURL, OpenURLAction { url in
                handleURL(url)
            })

            Rectangle().fill(Color.difHairline).frame(height: 1)
            composerFooter
        }
    }

    private func handleURL(_ url: URL) -> OpenURLAction.Result {
        if url.scheme?.lowercased() == "diffcode",
           let target = ExternalOpenParser.parseURL(url) {
            store.openExternalTargets([target])
            store.dismissPopup(restoreFocus: false)
            return .handled
        }
        return .systemAction
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: conversation.kind.symbolName)
                .font(.ui(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.difAccent)

            Menu {
                ForEach(projectConversations) { item in
                    Button {
                        store.activeAgentConversationID = item.id
                    } label: {
                        HStack {
                            Text("\(item.kind.localizedTitle) · \(item.title)")
                            if item.id == conversation.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(conversation.title)
                        .font(.ui(size: 13, weight: .semibold))
                        .foregroundStyle(Color.difText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if projectConversations.count > 1 {
                        Image(systemName: "chevron.down")
                            .font(.ui(size: 9, weight: .bold))
                            .foregroundStyle(Color.difText3)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .help(L("Switch recent AI conversation", "切换最近的 AI 对话"))

            statusPill

            Text(modelBadgeText)
                .font(.ui(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4.5, style: .continuous).fill(Color.difChip))

            Spacer(minLength: 8)

            if conversation.reportFileURL != nil {
                Button {
                    store.openAgentConversationReport(conversation)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.richtext")
                            .font(.ui(size: 10.5, weight: .semibold))
                        Text(L("Open Report", "打开报告"))
                            .font(.ui(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.difAccent)
                    .padding(.horizontal, 8)
                    .frame(height: UI.s(22))
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difSelection))
                }
                .buttonStyle(.plain)
            }

            if conversation.isRunning {
                Button {
                    store.cancelAgentConversation(conversation)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                            .font(.ui(size: 9))
                        Text(L("Stop", "停止"))
                            .font(.ui(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.difRemoved)
                    .padding(.horizontal, 8)
                    .frame(height: UI.s(22))
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difRemoved.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }

            Button {
                store.dismissPopup()
            } label: {
                Image(systemName: "xmark")
                    .font(.ui(size: 10, weight: .bold))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(22), height: UI.s(22))
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip.opacity(0.7)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Close (Esc)", "关闭 (Esc)"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var modelBadgeText: String {
        if let model = conversation.model, !model.isEmpty {
            return "\(conversation.provider.executableName) · \(model)"
        }
        return conversation.provider.executableName
    }

    @ViewBuilder
    private var statusPill: some View {
        switch conversation.status {
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.45)
                    .frame(width: UI.s(10), height: UI.s(10))
                Text(L("Running", "执行中"))
                    .font(.ui(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.difAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.difSelection))

        case .completed:
            HStack(spacing: 4) {
                Circle().fill(Color.difAdded).frame(width: 6, height: 6)
                Text(L("Completed", "已完成"))
                    .font(.ui(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Color.difText2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.difChip))

        case .failed:
            HStack(spacing: 4) {
                Circle().fill(Color.difRemoved).frame(width: 6, height: 6)
                Text(L("Failed", "失败"))
                    .font(.ui(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(Color.difRemoved)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.difRemoved.opacity(0.14)))

        case .cancelled:
            HStack(spacing: 4) {
                Circle().fill(Color.difText3).frame(width: 6, height: 6)
                Text(L("Cancelled", "已取消"))
                    .font(.ui(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Color.difText3)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.difChip))
        }
    }

    // MARK: - Follow-up Composer Footer

    private var composerFooter: some View {
        let trimmedDraft = conversation.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let canSend = !conversation.isRunning && !trimmedDraft.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                AgentFollowUpEditor(
                    text: $conversation.draftMessage,
                    placeholder: conversation.isRunning
                        ? L("Agent is running… wait or click Stop before continuing.", "Agent 正在执行… 完成后或点击“停止”可继续对话。")
                        : L("Ask follow-up questions about these changes (read-only)…", "继续向 Agent 追问改动细节、风险或实现原理（只读上下文）…"),
                    focusToken: composerFocusToken,
                    onSubmit: {
                        guard canSend else { return }
                        store.sendAgentConversationFollowUp(conversation, message: conversation.draftMessage)
                    },
                    onCancel: {
                        store.dismissPopup()
                    },
                    onFocusChange: { composerFocused = $0 }
                )
                .frame(minHeight: UI.s(34), maxHeight: UI.s(76))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difChip))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(composerFocused ? Color.difAccent.opacity(0.65) : Color.difHairline, lineWidth: 1)
                )

                Button {
                    store.sendAgentConversationFollowUp(conversation, message: conversation.draftMessage)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill")
                            .font(.ui(size: 11))
                        Text(L("Send", "发送"))
                            .font(.ui(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: UI.s(30))
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.difAccent.opacity(canSend ? 1.0 : 0.38))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }

            HStack(spacing: 8) {
                Text(L("Enter to send · Shift+Enter for newline · Esc to close",
                       "Enter 发送 · Shift+Enter 换行 · Esc 关闭"))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difText3)
                Spacer()
                if let sid = conversation.remoteSessionID, !sid.isEmpty {
                    Text(L("Session: \(String(sid.prefix(8)))", "会话: \(String(sid.prefix(8)))"))
                        .font(.ui(size: 10, design: .monospaced))
                        .foregroundStyle(Color.difText3)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Turn Card & Streaming Blocks

private struct AgentTurnCard: View {
    let turn: AgentConversationTurn
    let turnNumber: Int
    let onOpenURL: (URL) -> OpenURLAction.Result

    @State private var showFullPrompt = false
    @State private var showThinking = false

    var body: some View {
        let trimmedThinking = turn.thinking.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReply = turn.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 10) {
            // User prompt header
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "person.circle.fill")
                        .font(.ui(size: 13))
                        .foregroundStyle(Color.difAccent)
                        .padding(.top, 1)
                    Text(turn.userPromptDisplay)
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundStyle(Color.difText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let full = turn.fullPrompt, full != turn.userPromptDisplay {
                        Button {
                            withAnimation(.snappy(duration: 0.16)) {
                                showFullPrompt.toggle()
                            }
                        } label: {
                            Text(showFullPrompt
                                 ? L("Hide Prompt", "收起 Prompt")
                                 : L("Full Prompt", "查看完整 Prompt"))
                                .font(.ui(size: 10.5, weight: .medium))
                                .foregroundStyle(Color.difText2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difElevated))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if showFullPrompt, let full = turn.fullPrompt {
                    ScrollView {
                        Text(full)
                            .font(.ui(size: 11, design: .monospaced))
                            .foregroundStyle(Color.difText2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difPanel))
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difSelection.opacity(0.65)))

            // Thinking section
            if !trimmedThinking.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Button {
                        withAnimation(.snappy(duration: 0.16)) {
                            showThinking.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: showThinking ? "chevron.down" : "chevron.right")
                                .font(.ui(size: 9, weight: .bold))
                            Image(systemName: "brain")
                                .font(.ui(size: 10.5))
                            Text(turn.status.isRunning && trimmedReply.isEmpty
                                 ? L("Thinking…", "思考中…")
                                 : L("Thought Process (\(trimmedThinking.count) chars)", "思考过程（\(trimmedThinking.count) 字）"))
                                .font(.ui(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.difText2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if showThinking {
                        Text(trimmedThinking)
                            .font(.ui(size: 11))
                            .foregroundStyle(Color.difText3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip.opacity(0.75)))
                    }
                }
            }

            // Tool calls timeline
            if !turn.toolCalls.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(turn.toolCalls) { call in
                        AgentToolCallRow(call: call)
                    }
                }
            }

            // Permission / internal notes
            if !turn.statusNotes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(turn.statusNotes.enumerated()), id: \.offset) { _, note in
                        HStack(spacing: 5) {
                            Image(systemName: note.lowercased().contains("denied") ? "exclamationmark.shield" : "info.circle")
                                .font(.ui(size: 10))
                                .foregroundStyle(note.lowercased().contains("denied") ? Color.difRemoved : Color.difText3)
                            Text(note)
                                .font(.ui(size: 10.5, design: .monospaced))
                                .foregroundStyle(note.lowercased().contains("denied") ? Color.difRemoved : Color.difText3)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 4)
            }

            // Assistant Markdown / streamed response
            if !trimmedReply.isEmpty {
                MarkdownStreamView(markdown: turn.assistantText)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difPanel))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.difHairline, lineWidth: 1)
                    )
            } else if turn.status.isRunning {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: UI.s(12), height: UI.s(12))
                    Text(L("Waiting for agent output… (Turn \(turnNumber))", "等待 Agent 输出…（第 \(turnNumber) 轮）"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText3)
                }
                .padding(.horizontal, 4)
            }

            // Turn failure notice
            if let errorMessage = turn.status.errorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.ui(size: 12))
                        .foregroundStyle(Color.difRemoved)
                        .padding(.top, 1)
                    Text(errorMessage)
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difRemoved.opacity(0.11)))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.difRemoved.opacity(0.35), lineWidth: 1)
                )
            }
        }
    }
}

private struct AgentToolCallRow: View {
    let call: AgentToolCallRecord
    @State private var expanded = false

    private var iconName: String {
        switch call.kind?.lowercased() {
        case "read": return "doc.text"
        case "search": return "magnifyingglass"
        case "execute": return "terminal"
        case "edit", "delete", "move": return "pencil.slash"
        default: return "wrench.and.screwdriver"
        }
    }

    private var hasDetails: Bool {
        !(call.input?.isEmpty ?? true) || !(call.output?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button {
                guard hasDetails else { return }
                withAnimation(.snappy(duration: 0.14)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.ui(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.difAccent)

                    Text(call.title)
                        .font(.ui(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    statusBadge

                    if hasDetails {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.ui(size: 8.5, weight: .bold))
                            .foregroundStyle(Color.difText3)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let input = call.input, !input.isEmpty {
                        Text(input)
                            .font(.ui(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.difText2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let output = call.output, !output.isEmpty {
                        Text(output)
                            .font(.ui(size: 10.5, design: .monospaced))
                            .foregroundStyle(Color.difText3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difPanel))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip.opacity(0.75)))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.difHairline, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        let lower = call.status.lowercased()
        if lower == "completed" {
            Image(systemName: "checkmark.circle.fill")
                .font(.ui(size: 10.5))
                .foregroundStyle(Color.difAdded)
        } else if lower == "failed" || lower == "error" || lower == "rejected" {
            Image(systemName: "xmark.circle.fill")
                .font(.ui(size: 10.5))
                .foregroundStyle(Color.difRemoved)
        } else {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.42)
                .frame(width: UI.s(10), height: UI.s(10))
        }
    }
}

/// Renders Markdown blocks cleanly with clickable `diffcode://` inline links and fenced code blocks.
private struct MarkdownStreamView: View {
    let markdown: String

    private enum Block {
        case text(String)
        case code(lang: String, content: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var textLines: [String] = []
        var codeLines: [String] = []
        var currentLang = ""
        var inCode = false

        func flushText() {
            guard !textLines.isEmpty else { return }
            result.append(.text(textLines.joined(separator: "\n")))
            textLines.removeAll()
        }

        for rawLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if !inCode {
                    flushText()
                    inCode = true
                    currentLang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLines.removeAll()
                } else {
                    result.append(.code(lang: currentLang, content: codeLines.joined(separator: "\n")))
                    inCode = false
                    currentLang = ""
                    codeLines.removeAll()
                }
            } else if inCode {
                codeLines.append(line)
            } else {
                textLines.append(line)
            }
        }
        if inCode {
            result.append(.code(lang: currentLang, content: codeLines.joined(separator: "\n")))
        } else {
            flushText()
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let lang, let content):
                    VStack(alignment: .leading, spacing: 3) {
                        if !lang.isEmpty {
                            Text(lang)
                                .font(.ui(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.difText3)
                        }
                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(content)
                                .font(.ui(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.difText)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))

                case .text(let chunk):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(chunk.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, rawLine in
                            let line = String(rawLine)
                            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                                Spacer().frame(height: 2)
                            } else {
                                markdownLine(line)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func markdownLine(_ line: String) -> some View {
        let isHeading = line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
        let displayText = isHeading
            ? line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            : line
        let font: Font = line.hasPrefix("# ")
            ? .ui(size: 14, weight: .bold)
            : (line.hasPrefix("## ")
               ? .ui(size: 13, weight: .semibold)
               : (line.hasPrefix("### ") ? .ui(size: 12, weight: .semibold) : .ui(size: 12)))

        if let attr = try? AttributedString(
            markdown: displayText,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attr)
                .font(font)
                .foregroundStyle(Color.difText)
                .tint(Color.difAccent)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(displayText)
                .font(font)
                .foregroundStyle(Color.difText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Multi-line follow-up composer: Return submits (when IME isn't composing), Shift+Return inserts newline, Esc dismisses popup.
private struct AgentFollowUpEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onFocusChange: (Bool) -> Void

    final class TextView: NSTextView {
        var placeholder = "" { didSet { needsDisplay = true } }
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
                if flags.contains(.shift) {
                    super.keyDown(with: event)
                } else {
                    onSubmit?()
                }
                return
            }
            if event.keyCode == 53 && !hasMarkedText() {
                onCancel?()
                return
            }
            super.keyDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !hasMarkedText() else { return }
            let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5), y: textContainerOrigin.y)
            (placeholder as NSString).draw(at: origin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 12 * UI.scale),
                .foregroundColor: Palette.textTertiary,
            ])
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted { onFocusChange?(true) }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted {
                onFocusChange?(false)
                needsDisplay = true
            }
            return accepted
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AgentFollowUpEditor
        var lastToken = Int.min

        init(_ parent: AgentFollowUpEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if !view.hasMarkedText(), parent.text != view.string {
                parent.text = view.string
            }
            view.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = TextView()
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 3)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        configure(view)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TextView else { return }
        context.coordinator.parent = self
        if !view.hasMarkedText() {
            configure(view)
            if view.string != text { view.string = text }
        }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async {
                view.window?.makeFirstResponder(view)
            }
        }
    }

    private func configure(_ view: TextView) {
        let font = NSFont.systemFont(ofSize: 12 * UI.scale)
        if view.font != font { view.font = font }
        view.textColor = Palette.textPrimary
        view.insertionPointColor = Palette.accent
        view.typingAttributes = [.font: font, .foregroundColor: Palette.textPrimary]
        view.placeholder = placeholder
        view.onSubmit = onSubmit
        view.onCancel = onCancel
        view.onFocusChange = onFocusChange
    }
}
