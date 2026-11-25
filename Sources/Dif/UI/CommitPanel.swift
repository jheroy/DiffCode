import AppKit
import SwiftUI

/// Whether a row's files go into the next commit.
enum Inclusion: Equatable { case on, mixed, off }

/// The tick in front of a row of the Changes list.
struct CommitCheckbox: View {
    var state: Inclusion
    var action: () -> Void

    var body: some View {
        let on = state != .off
        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(on ? Color.difAccent : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .strokeBorder(on ? Color.clear : Color.difText3.opacity(0.9), lineWidth: 1.2)
            )
            .overlay {
                if state != .off {
                    Image(systemName: state == .on ? "checkmark" : "minus")
                        .font(.ui(size: 7.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: UI.s(12), height: UI.s(12))
            .frame(width: UI.s(18), height: UI.s(18))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(on ? L("Leave out of the commit (Space)", "不提交 (空格)") : L("Include in the commit (Space)", "提交 (空格)"))
    }
}

/// The bottom island of the Changes column: what will be committed, then the message box with the Commit button in it.
struct CommitPanel: View {
    @Bindable var project: Project
    /// The height of the Changes area (excluding header and island gap), so the box never squeezes the list out.
    var columnHeight: CGFloat
    @Environment(AppStore.self) private var store
    @State private var editing = false

    /// Maximum height of the commit message editor box for the current Changes column height.
    static func heightCeiling(columnHeight: CGFloat) -> Double {
        max(Settings.commitBoxRange.lowerBound, min(Settings.commitBoxRange.upperBound, Double(columnHeight) - 220))
    }

    var body: some View {
        @Bindable var settings = store.settings
        let included = project.includedChanges
        // Lines left out of a file do not count.
        let out = included.compactMap { project.excludedLines[$0.path] }
        let partial = out.filter { !$0.isEmpty }.count
        let outAdded = out.reduce(0) { $0 + $1.filter { !$0.removed }.count }, outRemoved = out.reduce(0) { $0 + $1.filter(\.removed).count }
        let added = max(0, included.reduce(0) { $0 + ($1.additions ?? 0) } - outAdded)
        let deleted = max(0, included.reduce(0) { $0 + ($1.deletions ?? 0) } - outRemoved)
        let operation = project.status.operation
        let merging = operation == .merge
        let amend = project.amend && operation == nil
        let canCommit = (merging ? project.status.conflictCount == 0 : ((!included.isEmpty || amend) && operation == nil)) && !project.isCommitting
            && !project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The list keeps at least a few rows.
        let ceiling = Self.heightCeiling(columnHeight: columnHeight)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(merging ? L("Finishing the merge: what it brought, plus the ticked files", "完成合并：合并带来的改动，加上勾选的文件")
                             : amend ? amendSummary(included: included.count, partial: partial)
                             : L("\(included.count) of \(project.changes.count) files to commit", "将提交 \(included.count) / \(project.changes.count) 个文件")
                               + (partial == 0 ? "" : L(" · \(partial) in part", " · \(partial) 个部分提交")))
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !AppEnvironment.isAppStore {
                    let isReviewing = project.activeReviewTarget == .workingTree
                    let reviewDisabled = !isReviewing && project.changes.isEmpty
                    AIReviewPillButton(
                        isReviewing: isReviewing,
                        isDisabled: reviewDisabled,
                        compactIconOnly: false,
                        help: aiReviewHelp(isReviewing: isReviewing, hasChanges: !project.changes.isEmpty, hasChecked: !included.isEmpty)
                    ) {
                        store.reviewWorkingTreeChanges(in: project)
                    }
                    if let reviewConv = project.reviewConversation(for: .workingTree) {
                        AgentStreamPillButton(
                            isRunning: reviewConv.isRunning,
                            hasError: reviewConv.hasFailed,
                            compactIconOnly: false,
                            help: L("Open AI review conversation stream and continue chat",
                                    "打开 AI 审查对话流并继续对话")
                        ) {
                            store.openAgentConversation(reviewConv)
                        }
                    }
                }
                StatBadge(additions: added, deletions: deleted)
            }
            if amend, let remote = project.amendPushedTo.first {
                Label(L("\(project.status.shortHead) is already on \(remote) · it can then only be pushed by force",
                        "\(project.status.shortHead) 已推送到 \(remote) · 修改后只能强制推送"), systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                CommitMessageEditor(text: $project.commitMessage,
                                    placeholder: L("Commit message", "提交说明"),
                                    focusToken: store.commitFocusToken,
                                    requestedAt: store.commitFocusRequestedAt,
                                    onSubmit: { store.commitCurrent() },
                                    onCommitAndPush: { store.commitCurrent(thenPush: true) },
                                    onCancel: { store.focusList() },
                                    onFocusChange: { editing = $0 })
                    .padding(.horizontal, 4)
                    .padding(.top, 5)
                    .frame(maxHeight: .infinity)
                buttonRow(canCommit: canCommit, included: included.count, amend: amend)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .padding(.bottom, 6)
            }
            .frame(height: min(settings.commitBoxHeight, ceiling))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difChip))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(editing ? Color.difAccent.opacity(0.7) : Color.clear, lineWidth: 1.5)
            )
            // A click on the box around the text, by the buttons, still means "write here".
            .contentShape(Rectangle())
            .onTapGesture { store.focusCommitMessage() }
        }
        .padding(10)
        .onChange(of: project.id) { oldID, _ in
            if let previous = store.project(oldID), previous.isGeneratingCommitMessage {
                store.cancelCommitMessageGeneration(in: previous)
            }
        }
    }

    private func amendSummary(included: Int, partial: Int) -> String {
        let head = project.status.shortHead
        if included == 0 { return L("Amending \(head): new message only", "修改 \(head)：只改提交说明") }
        return L("Amending \(head), adding \(included) of \(project.changes.count) files", "修改 \(head)，加入 \(included) / \(project.changes.count) 个文件")
            + (partial == 0 ? "" : L(" · \(partial) in part", " · \(partial) 个部分提交"))
    }

    /// Inside the box, under the text: Amend and taking back the last commit on the left, Commit & Commit and Push on the right.
    private func buttonRow(canCommit: Bool, included: Int, amend: Bool) -> some View {
        HStack(spacing: 5) {
            if project.status.operation == nil, !project.status.isInitial || project.amend {
                Toggle(isOn: Binding(get: { project.amend }, set: { store.setAmend($0, in: project) })) {
                    Text(L("Amend", "修改上次提交"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .padding(.leading, 4)
                .help(L("Replace the last commit with this one: its changes plus the ticked files, with this message",
                        "用这次提交替换上一次提交：保留它的改动，加上勾选的文件，并使用这里的提交说明"))
            }
            if let last = project.lastCommit {
                Button { store.undoLastCommit() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward").font(.ui(size: 9.5, weight: .semibold))
                        Text(L("Undo \(last.shortHash)", "撤销 \(last.shortHash)")).font(.ui(size: 11.5)).lineLimit(1)
                    }
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 5)
                    .frame(height: UI.s(24))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(last.amended != nil ? L("Undo the amend; the replaced commit comes back", "撤销这次修改，被替换的提交会恢复")
                                          : L("Undo the commit just made; its changes come back to the list", "撤销刚才的提交，改动会回到列表里"))
            }
            Spacer(minLength: 4)
            if !AppEnvironment.isAppStore {
                AICommitButton(
                    isGenerating: project.isGeneratingCommitMessage,
                    isDisabled: !project.isGeneratingCommitMessage && (included == 0 || project.isCommitting),
                    help: aiCommitHelp(included: included)
                ) {
                    store.generateCommitMessage(in: project)
                }
            }
            Button { store.commitCurrent(thenPush: true) } label: {
                Text(L("Commit & Push", "提交并推送"))
                    .font(.ui(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(Color.difAccent.opacity(canCommit ? 1 : 0.4))
                    .padding(.horizontal, 9)
                    .frame(height: UI.s(24))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.difAccent.opacity(canCommit ? 0.14 : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.difAccent.opacity(canCommit ? 0.35 : 0.14), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .help(commitPushHelp(canCommit: canCommit, included: included, amend: amend))
            Button { store.commitCurrent() } label: {
                HStack(spacing: 6) {
                    if project.isCommitting {
                        ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: UI.s(12), height: UI.s(12))
                    }
                    Text(project.status.operation == .merge ? L("Commit Merge", "提交合并")
                         : amend ? L("Amend Commit", "修改提交") : L("Commit", "提交")).font(.ui(size: 12, weight: .semibold))
                    Text("⌘↩").font(.ui(size: 10, weight: .medium, design: .rounded)).opacity(0.65)
                }
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: UI.s(24))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difAccent.opacity(canCommit ? 1 : 0.38)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canCommit)
            .help(commitHelp(included: included, amend: amend))
        }
    }

    private func commitPushHelp(canCommit: Bool, included: Int, amend: Bool) -> String {
        canCommit ? L("Commit and Push (⇧⌘↩)", "提交并推送 (⇧⌘↩)") : commitHelp(included: included, amend: amend)
    }

    private func commitHelp(included: Int, amend: Bool) -> String {
        if let operation = project.status.operation {
            if operation != .merge { return L("A \(operation.command) is in progress · Continue it above the list", "正在进行 \(operation.command) · 请用列表上方的“继续”") }
            if project.status.conflictCount > 0 { return L("Resolve the conflicts first", "请先解决冲突") }
        } else if included == 0, !amend { return L("Tick the files to commit", "先勾选要提交的文件") }
        if amend, !project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L("Replace the last commit (⌘↩)", "替换上一次提交 (⌘↩)")
        }
        if project.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return L("Write a commit message first", "先写提交说明") }
        return L("Commit the ticked files (⌘↩)", "提交勾选的文件 (⌘↩)")
    }

    private func aiCommitHelp(included: Int) -> String {
        let provider = store.settings.aiProvider(for: .commit)
        let model = store.settings.aiModel(for: provider, task: .commit)
        let agentDesc = model.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
        if project.isGeneratingCommitMessage {
            return L("Generating commit message with \(agentDesc)… Click to cancel",
                     "正在使用 \(agentDesc) 生成提交信息… 点击取消")
        }
        if included == 0 {
            return L("Tick the files to commit first", "先勾选要提交的文件")
        }
        return L("Generate commit message with \(agentDesc)",
                 "使用 \(agentDesc) 生成提交信息")
    }

    private func aiReviewHelp(isReviewing: Bool, hasChanges: Bool, hasChecked: Bool) -> String {
        let agentDesc = store.aiReviewAgentDescription()
        if isReviewing {
            return L("Generating code review report with \(agentDesc)… Click to cancel",
                     "正在使用 \(agentDesc) 生成代码审查报告… 点击取消")
        }
        if !hasChanges {
            return L("No working tree changes to review", "工作区暂无可审查的变更")
        }
        if hasChecked {
            return L("Review checked changes with \(agentDesc) and open Markdown report",
                     "使用 \(agentDesc) 审查已勾选变更并生成打开 Markdown 报告")
        }
        return L("Review all working tree changes with \(agentDesc) and open Markdown report",
                 "使用 \(agentDesc) 审查工作区全部变更并生成打开 Markdown 报告")
    }
}

private struct AICommitButton: View {
    var isGenerating: Bool
    var isDisabled: Bool
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: UI.s(13), height: UI.s(13))
                } else {
                    Image(systemName: "sparkles")
                        .font(.ui(size: 12, weight: .medium))
                        .foregroundStyle(isDisabled ? Color.difText3.opacity(0.6) : Color.difAccent)
                }
            }
            .frame(width: UI.s(26), height: UI.s(24))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isGenerating ? Color.difSelection : (hovering && !isDisabled ? Color.difHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A plain multi-line text view: ⌘↩ submits, ⇧⌘↩ commits and pushes, Esc goes back to the list, ⇥ moves on rather than typing a tab.
struct CommitMessageEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var focusToken: Int
    /// When the focus was asked for: an editor that is only now being created takes it if the request is fresh.
    var requestedAt: CFTimeInterval
    var onSubmit: () -> Void
    var onCommitAndPush: () -> Void
    var onCancel: () -> Void
    var onFocusChange: (Bool) -> Void

    final class TextView: NSTextView {
        var placeholder = "" { didSet { needsDisplay = true } }
        var onSubmit: (() -> Void)?
        var onCommitAndPush: (() -> Void)?
        var onCancel: (() -> Void)?
        var onFocusChange: ((Bool) -> Void)?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 36 || event.keyCode == 76, flags.contains(.command) {
                if flags.contains(.shift) {
                    onCommitAndPush?()
                } else {
                    onSubmit?()
                }
                return
            }
            if event.keyCode == 53, !hasMarkedText() {
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
                .font: font ?? NSFont.systemFont(ofSize: 12.5),
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
        var parent: CommitMessageEditor
        var lastToken = Int.min

        init(_ parent: CommitMessageEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            // Letters an input method is still composing are not the message yet.
            if !view.hasMarkedText(), parent.text != view.string { parent.text = view.string }
            view.needsDisplay = true
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
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
        view.identifier = NSUserInterfaceItemIdentifier("commitMessage")
        view.delegate = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.textContainerInset = NSSize(width: 2, height: 2)
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
        // Never while an input method composes: replacing the text then threw the composition away, so pinyin typed
        // while the changes refreshed was lost.
        if !view.hasMarkedText() {
            configure(view)
            if view.string != text { view.string = text }
        }
        if context.coordinator.lastToken != focusToken {
            let first = context.coordinator.lastToken == Int.min
            context.coordinator.lastToken = focusToken
            if !first || CACurrentMediaTime() - requestedAt < 1 {
                DispatchQueue.main.async {
                    view.window?.makeFirstResponder(view)
                    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
                }
            }
        }
    }

    private func configure(_ view: TextView) {
        let font = NSFont.systemFont(ofSize: 12.5 * UI.scale)
        if view.font != font { view.font = font }
        view.textColor = Palette.textPrimary
        view.insertionPointColor = Palette.accent
        view.typingAttributes = [.font: font, .foregroundColor: Palette.textPrimary]
        view.placeholder = placeholder
        view.onSubmit = onSubmit
        view.onCommitAndPush = onCommitAndPush
        view.onCancel = onCancel
        view.onFocusChange = onFocusChange
    }
}
