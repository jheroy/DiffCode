import SwiftUI

/// A question or notice in DiffCode's own style: what it is about, the files it touches, and two clear buttons.
/// ↩ answers yes, Esc (or a click outside) no.
struct DialogView: View {
    let request: DialogRequest
    @Environment(AppStore.self) private var store
    @State private var focus = ListFocus()
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var tint: Color {
        switch request.style {
        case .destructive: return Color.difRemoved
        case .caution: return Color.orange
        case .info: return Color.difAccent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A title alone sits level with the icon; with a message under it, the two start together.
            HStack(alignment: request.message.isEmpty ? .center : .top, spacing: 14) {
                Image(systemName: request.symbol)
                    .font(.ui(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: UI.s(38), height: UI.s(38))
                    .background(Circle().fill(tint.opacity(0.15)))
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.title)
                        .font(.ui(size: 15, weight: .semibold))
                        .foregroundStyle(Color.difText)
                        .fixedSize(horizontal: false, vertical: true)
                    if !request.message.isEmpty {
                        Text(request.message)
                            .font(.ui(size: 12.5))
                            .foregroundStyle(Color.difText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            if !request.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(request.warnings.enumerated()), id: \.offset) { _, warning in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.ui(size: 11.5, weight: .semibold))
                                .foregroundStyle(tint)
                                .padding(.top, 1.5)
                            Text(warning)
                                .font(.ui(size: 12))
                                .foregroundStyle(Color.difText)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(tint.opacity(0.28), lineWidth: 1)
                )
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            if !request.items.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(request.items.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Rectangle().fill(Color.difHairline).frame(height: 1).padding(.leading, 36) }
                        ItemRow(item: item)
                    }
                    if request.hiddenCount > 0 {
                        Rectangle().fill(Color.difHairline).frame(height: 1)
                        Text(L("…and \(request.hiddenCount) more", "…以及另外 \(request.hiddenCount) 个"))
                            .font(.ui(size: 11.5))
                            .foregroundStyle(Color.difText3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .frame(height: UI.s(28))
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.difChip))
                .padding(.horizontal, 20)
                .padding(.top, 16)
            }

            if !request.choices.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(request.choices.enumerated()), id: \.offset) { index, choice in
                        if index > 0 { Rectangle().fill(Color.difHairline).frame(height: 1).padding(.leading, 36) }
                        ChoiceRow(choice: choice, picked: index == request.choice) { store.pickDialogChoice(index) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.difChip))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            if let input = request.input {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let unchangedInitial = !input.text.isEmpty && trimmed == input.text
                let problem = (text.isEmpty || unchangedInitial) ? nil : input.problem(trimmed)
                VStack(alignment: .leading, spacing: 5) {
                    TextField(input.placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .font(.ui(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: UI.s(30))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(problem != nil ? Color.difRemoved.opacity(0.8) : Color.difAccent.opacity(fieldFocused ? 0.7 : 0), lineWidth: 1.5))
                        .focused($fieldFocused)
                        .onSubmit { store.answerDialog(confirmed: true, text: text) }
                        .onExitCommand { store.answerDialog(confirmed: false) }
                    Text(problem ?? " ")
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difRemoved)
                        .lineLimit(1)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .onAppear {
                    text = input.text
                    // After the dialog's own key catcher has taken the keyboard.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
                }
            }

            if let form = request.worktreeForm {
                WorktreeFormView(form: form)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            if let tagForm = request.tagForm {
                TagFormView(form: tagForm)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }

            if let option = request.option {
                Toggle(isOn: Binding(get: { option.isOn }, set: { _ in store.toggleDialogOption() })) {
                    Text(option.title)
                        .font(.ui(size: 12.5))
                        .foregroundStyle(Color.difText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(.horizontal, 20)
                .padding(.top, request.input == nil ? 14 : 2)
            }

            if let output = request.output, !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.code(11.5))
                        .foregroundStyle(Color.difText2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.difChip))
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }

            HStack(spacing: 10) {
                Spacer()
                if let cancel = request.cancelTitle {
                    DialogButton(title: cancel, keys: "Esc", style: .plain) { store.answerDialog(confirmed: false) }
                }
                if let alternate = request.alternateTitle {
                    DialogButton(title: alternate, keys: "", style: .plain) { store.answerDialogAlternate() }
                }
                let inputBlocked = request.input.map { $0.problem(text.trimmingCharacters(in: .whitespaces)) != nil } ?? false
                let optionBlocked = request.option.map { $0.required && !$0.isOn } ?? false
                let formBlocked = request.worktreeForm?.problem != nil || request.tagForm?.problem != nil
                let blocked = inputBlocked || optionBlocked || formBlocked
                let destructive = request.style == .destructive
                    || (request.choices.indices.contains(request.choice) && request.choices[request.choice].destructive)
                DialogButton(title: request.confirmTitle, keys: "↩", style: destructive ? .destructive : .primary) {
                    store.answerDialog(confirmed: true, text: text)
                }
                .disabled(blocked)
                .opacity(blocked ? 0.45 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 18)
        }
        .background(
            KeyCatcher(focus: focus, focusToken: store.dialogFocusToken, name: "dialog", onKey: { event in
                switch event.keyCode {
                case 36, 76:
                    store.answerDialog(confirmed: true, text: text)
                    return true
                case 125, 126:
                    guard !request.choices.isEmpty else { return false }
                    store.pickDialogChoice(request.choice + (event.keyCode == 125 ? 1 : -1))
                    return true
                default:
                    return false
                }
            }, onFocusChange: { _ in })
        )
    }
}

/// One of the dialog's choices: a radio button, its name, and what it does.
private struct ChoiceRow: View {
    var choice: DialogRequest.Choice
    var picked: Bool
    var pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .strokeBorder(picked ? Color.difAccent : Color.difText3, lineWidth: picked ? UI.s(4.5) : 1.2)
                    .frame(width: UI.s(14), height: UI.s(14))
                    .padding(.top, UI.s(1.5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.ui(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.difText)
                    if !choice.detail.isEmpty {
                        Text(choice.detail)
                            .font(.ui(size: 11.5))
                            .foregroundStyle(Color.difText2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ItemRow: View {
    var item: DialogRequest.Item

    var body: some View {
        HStack(spacing: 8) {
            if let path = item.path {
                FileIcon(path: path, size: 12)
            } else {
                Image(systemName: item.symbol ?? "doc")
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(17), height: UI.s(16))
            }
            Text(item.title)
                .font(.ui(size: 12.5, weight: .medium))
                .foregroundStyle(item.kind.map { Color.status($0) } ?? Color.difText)
                .lineLimit(1)
                .layoutPriority(1)
            Text(item.detail)
                .font(.ui(size: 11.5))
                .foregroundStyle(Color.difText3)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if let kind = item.kind {
                Text(kind.letter)
                    .font(.ui(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.status(kind))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(30))
        .help(item.path ?? item.detail)
    }
}

struct DialogButton: View {
    enum Style { case plain, primary, destructive }

    var title: String
    var keys: String
    var style: Style
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.ui(size: 12.5, weight: .semibold))
                Text(keys)
                    .font(.ui(size: 10.5, weight: .medium, design: .rounded))
                    .opacity(0.6)
            }
            .foregroundStyle(style == .plain ? Color.difText : Color.white)
            .padding(.horizontal, 14)
            .frame(minWidth: UI.s(84))
            .frame(height: UI.s(30))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        switch style {
        case .plain: return hovering ? Color.difText.opacity(0.14) : Color.difChip
        case .primary: return Color.difAccent.opacity(hovering ? 0.85 : 1)
        case .destructive: return Color(NSColor(hex: 0xD9453C)).opacity(hovering ? 0.85 : 1)
        }
    }
}

private struct WorktreeFormView: View {
    @Bindable var form: WorktreeDialogForm
    @Environment(AppStore.self) private var store
    @FocusState private var branchFocused: Bool
    @FocusState private var pathFocused: Bool
    @State private var chooseHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: Binding(get: { form.mode }, set: { form.setMode($0) })) {
                Text(L("New branch", "新建分支")).tag(WorktreeDialogForm.Mode.newBranch)
                Text(L("Existing branch", "已有分支")).tag(WorktreeDialogForm.Mode.existingBranch)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch form.mode {
            case .newBranch:
                let branchError = form.newBranchName.isEmpty ? nil : form.branchProblem
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L("Branch name", "分支名"))
                    TextField(L("e.g. feature/my-task", "例如 feature/my-task"),
                              text: Binding(get: { form.newBranchName }, set: { form.setNewBranchName($0) }))
                        .textFieldStyle(.plain)
                        .font(.ui(size: 13))
                        .padding(.horizontal, 10)
                        .frame(height: UI.s(30))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(branchError != nil ? Color.difRemoved.opacity(0.8)
                                                             : Color.difAccent.opacity(branchFocused ? 0.7 : 0),
                                          lineWidth: 1.5))
                        .focused($branchFocused)
                        .onSubmit { store.answerDialog(confirmed: true) }
                        .onExitCommand { store.answerDialog(confirmed: false) }
                    if let branchError {
                        Text(branchError)
                            .font(.ui(size: 11))
                            .foregroundStyle(Color.difRemoved)
                            .lineLimit(1)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L("Base branch", "基于分支"))
                    Picker("", selection: $form.baseRef) {
                        Text(form.currentBranch.map { "HEAD (\($0))" } ?? "HEAD").tag("")
                        if !form.baseRefChoices.isEmpty {
                            Divider()
                            ForEach(form.baseRefChoices, id: \.self) { ref in
                                Text(ref).tag(ref)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .existingBranch:
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L("Branch", "分支"))
                    if form.existingBranchChoices.isEmpty {
                        Text(L("All local branches are already checked out in a work tree.",
                               "所有本地分支都已在工作树中检出。"))
                            .font(.ui(size: 12))
                            .foregroundStyle(Color.difText3)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                    } else {
                        Picker("", selection: Binding(get: { form.selectedExistingID }, set: { form.setSelectedExistingID($0) })) {
                            ForEach(form.existingBranchChoices) { option in
                                Text(option.refName).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            let pathError = form.pathProblem
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L("Location", "目录位置"))
                HStack(spacing: 8) {
                    TextField(L("Folder path", "目录路径"),
                              text: Binding(get: { form.pathText }, set: { form.setPathText($0) }))
                        .textFieldStyle(.plain)
                        .font(.code(12))
                        .padding(.horizontal, 10)
                        .frame(height: UI.s(30))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(pathError != nil ? Color.difRemoved.opacity(0.8)
                                                           : Color.difAccent.opacity(pathFocused ? 0.7 : 0),
                                          lineWidth: 1.5))
                        .focused($pathFocused)
                        .onSubmit { store.answerDialog(confirmed: true) }
                        .onExitCommand { store.answerDialog(confirmed: false) }

                    Button {
                        store.chooseWorktreeParentFolder(for: form)
                    } label: {
                        Text(L("Choose…", "选择…"))
                            .font(.ui(size: 12, weight: .medium))
                            .foregroundStyle(Color.difText)
                            .padding(.horizontal, 10)
                            .frame(height: UI.s(30))
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(chooseHovering ? Color.difText.opacity(0.14) : Color.difChip))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { chooseHovering = $0 }
                }
                Text(pathError ?? " ")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difRemoved)
                    .lineLimit(1)
            }
        }
        .onAppear {
            guard form.mode == .newBranch else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { branchFocused = true }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 11.5, weight: .medium))
            .foregroundStyle(Color.difText2)
    }
}

private struct TagFormView: View {
    @Bindable var form: TagDialogForm
    @Environment(AppStore.self) private var store
    @FocusState private var nameFocused: Bool
    @FocusState private var messageFocused: Bool

    var body: some View {
        let nameError = form.name.isEmpty ? nil : form.problem
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L("Tag name", "标签名"))
                TextField(L("e.g. v1.0.0", "例如 v1.0.0"), text: $form.name)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: UI.s(30))
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(nameError != nil ? Color.difRemoved.opacity(0.8)
                                                       : Color.difAccent.opacity(nameFocused ? 0.7 : 0),
                                      lineWidth: 1.5))
                    .focused($nameFocused)
                    .onSubmit { store.answerDialog(confirmed: true) }
                    .onExitCommand { store.answerDialog(confirmed: false) }
                Text(nameError ?? " ")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difRemoved)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L("Message (optional)", "附注消息（可选）"))
                TextField(L("Leave empty for a lightweight tag", "留空则创建轻量标签"),
                          text: $form.message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.ui(size: 12.5))
                    .lineLimit(2...4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.difAccent.opacity(messageFocused ? 0.7 : 0), lineWidth: 1.5))
                    .focused($messageFocused)
                    .onSubmit { store.answerDialog(confirmed: true) }
                    .onExitCommand { store.answerDialog(confirmed: false) }
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 11.5, weight: .medium))
            .foregroundStyle(Color.difText2)
    }
}
