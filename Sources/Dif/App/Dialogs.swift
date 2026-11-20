import AppKit
import Observation

/// Live form state for the New Worktree dialog, rendered inside `DialogView`.
@MainActor
@Observable
final class WorktreeDialogForm {
    enum Mode: Int, CaseIterable, Hashable {
        case newBranch
        case existingBranch
    }

    struct ExistingBranchOption: Identifiable, Hashable {
        var id: String { refName }
        /// Branch name passed to git (`feature/x` for local, `origin/feature/x` for remote).
        var refName: String
        /// Local branch name (`feature/x`), used for tracking and default folder naming.
        var localName: String
        var isRemote: Bool
    }

    let repoURL: URL
    let repoName: String
    let currentBranch: String?
    let baseRefChoices: [String]
    let existingLocalNames: Set<String>
    let existingBranchChoices: [ExistingBranchOption]

    var mode: Mode = .newBranch
    var newBranchName = ""
    /// Empty string means `HEAD`.
    var baseRef = ""
    var selectedExistingID: String
    var baseDirectory: URL
    var pathText: String
    var pathManuallyEdited = false

    init(
        repoURL: URL,
        currentBranch: String?,
        baseRefChoices: [String],
        existingLocalNames: Set<String>,
        existingBranchChoices: [ExistingBranchOption]
    ) {
        let standardized = repoURL.standardizedFileURL
        self.repoURL = standardized
        self.repoName = standardized.lastPathComponent
        self.currentBranch = currentBranch
        self.baseRefChoices = baseRefChoices
        self.existingLocalNames = existingLocalNames
        self.existingBranchChoices = existingBranchChoices
        self.selectedExistingID = existingBranchChoices.first?.id ?? ""
        self.baseDirectory = standardized.deletingLastPathComponent()
        self.pathText = Git.defaultWorktreeURL(for: standardized, branch: "", parentDir: standardized.deletingLastPathComponent()).path
    }

    var selectedExistingOption: ExistingBranchOption? {
        existingBranchChoices.first { $0.id == selectedExistingID }
    }

    private var activeSlugSource: String {
        switch mode {
        case .newBranch: return newBranchName
        case .existingBranch: return selectedExistingOption?.localName ?? ""
        }
    }

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        syncDefaultPathIfAutomatic()
    }

    func setNewBranchName(_ value: String) {
        newBranchName = value
        syncDefaultPathIfAutomatic()
    }

    func setSelectedExistingID(_ id: String) {
        selectedExistingID = id
        syncDefaultPathIfAutomatic()
    }

    func setPathText(_ value: String) {
        pathText = value
        pathManuallyEdited = true
    }

    func chooseParentFolder(_ folder: URL) {
        FolderAccess.shared.remember(folder)
        baseDirectory = folder.standardizedFileURL
        pathManuallyEdited = false
        syncDefaultPathIfAutomatic()
    }

    private func syncDefaultPathIfAutomatic() {
        guard !pathManuallyEdited else { return }
        pathText = Git.defaultWorktreeURL(for: repoURL, branch: activeSlugSource, parentDir: baseDirectory).path
    }

    var resolvedURL: URL {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    var branchProblem: String? {
        switch mode {
        case .newBranch:
            return Git.branchNameProblem(newBranchName, existing: existingLocalNames)
        case .existingBranch:
            return selectedExistingOption == nil ? L("Choose a branch", "请选择一个分支") : nil
        }
    }

    var pathProblem: String? {
        let trimmed = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return L("Enter a folder path", "请输入目录路径") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expanded) {
            return L("A file or folder already exists at this path", "该路径已存在文件或文件夹")
        }
        return nil
    }

    var problem: String? {
        branchProblem ?? pathProblem
    }
}

/// Live form state for the New Tag dialog, rendered inside `DialogView`.
@MainActor
@Observable
final class TagDialogForm {
    let targetLabel: String
    let existingTagNames: Set<String>

    var name = ""
    var message = ""

    init(targetLabel: String, existingTagNames: Set<String>) {
        self.targetLabel = targetLabel
        self.existingTagNames = existingTagNames
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    var problem: String? { Git.tagNameProblem(name, existing: existingTagNames) }
}

/// A question or a notice shown inside the window, in DiffCode's own style, instead of a system alert.
struct DialogRequest {
    enum Style {
        /// Throws work away (roll back, delete): the confirm button is red.
        case destructive
        /// Stops something running (a terminal, quitting with jobs), or reports a failure.
        case caution
        case info
    }

    /// A line in the dialog's list: a file, or a running program.
    struct Item: Hashable {
        var title: String
        var detail = ""
        /// A file's path, for its icon.
        var path: String?
        var kind: FileChange.Kind?
        /// Used when there is no file to take an icon from.
        var symbol: String?
    }

    var style: Style
    var symbol: String
    var title: String
    var message = ""
    /// Multi-line risk/warning callouts rendered in a tinted callout box above items and options.
    var warnings: [String] = []
    var items: [Item] = []
    /// Items left out of the list: "…and 12 more".
    var hiddenCount = 0
    /// A program's own words (git's error, a hook's output), shown as they are, in monospace.
    var output: String?
    var confirmTitle: String
    /// Nil for a notice with a single button.
    var cancelTitle: String? = L("Cancel", "取消")
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
    /// A third answer, between Cancel and the confirm button ("Rebase" beside "Merge").
    var alternateTitle: String?
    var onAlternate: () -> Void = {}
    /// A line to type (a branch name). The confirm button hands it to `onSubmit`, and `onConfirm` is not called.
    var input: Input?
    var onSubmit: (String) -> Void = { _ in }

    struct Input {
        var placeholder: String
        var text = ""
        /// Why the text cannot be used yet, shown under the field; nil when it can.
        var problem: (String) -> String? = { _ in nil }
    }

    /// Ways to do it, one of which is picked (the modes of a reset); ↑ and ↓ move the pick.
    var choices: [Choice] = []
    var choice = 0
    /// A box to tick ("Include untracked files").
    var option: Option?
    /// Rich form for creating a linked Git work tree.
    var worktreeForm: WorktreeDialogForm?
    /// Rich form for creating a Git tag (name + optional annotation message).
    var tagForm: TagDialogForm?
    /// Called on confirm with everything that was answered, in place of `onConfirm` and `onSubmit`.
    var onAnswer: ((Answer) -> Void)?

    struct Choice: Hashable {
        var title: String
        var detail = ""
        /// Throws work away: the confirm button turns red while it is picked.
        var destructive = false
    }

    struct Option {
        var title: String
        var isOn = false
        /// When true, the confirm button stays disabled until this option is ticked.
        var required = false
    }

    struct Answer {
        var text: String
        var choice: Int
        var option: Bool
    }

    /// The first few files as list items, and how many did not fit.
    static func files(_ changes: [FileChange], limit: Int = 6) -> (items: [Item], hidden: Int) {
        let items = changes.prefix(limit).map { change in
            Item(title: change.name, detail: change.directory, path: change.path, kind: change.kind)
        }
        return (Array(items), max(0, changes.count - limit))
    }
}

extension AppStore {
    /// Shows `request`. A newer question replaces an older one, which counts as cancelled.
    func ask(_ request: DialogRequest) {
        if popup == .dialog, let current = dialog {
            dialog = nil
            current.onCancel()
        }
        dialog = request
        present(.dialog)
        dialogFocusToken += 1
        KeyCatcher.pending = (dialogFocusToken, CACurrentMediaTime())
    }

    /// The user's answer. Escape, a click outside and Cancel all come here as `false`.
    /// - Parameter text: what was typed, for a dialog that asks for a line.
    func answerDialog(confirmed: Bool, text: String? = nil) {
        guard let request = dialog else { return }
        var typed = ""
        if confirmed {
            if let input = request.input {
                typed = (text ?? input.text).trimmingCharacters(in: .whitespaces)
                guard input.problem(typed) == nil else { return }
            }
            if let option = request.option, option.required, !option.isOn { return }
            if let form = request.worktreeForm, form.problem != nil { return }
            if let tagForm = request.tagForm, tagForm.problem != nil { return }
        }
        dialog = nil
        dismissPopup()
        guard confirmed else { return request.onCancel() }
        if let onAnswer = request.onAnswer {
            onAnswer(DialogRequest.Answer(text: typed, choice: request.choice, option: request.option?.isOn ?? false))
        } else if request.input != nil {
            request.onSubmit(typed)
        } else {
            request.onConfirm()
        }
    }

    /// Picks one of the dialog's choices.
    func pickDialogChoice(_ index: Int) {
        guard let count = dialog?.choices.count, count > 0 else { return }
        dialog?.choice = min(max(0, index), count - 1)
    }

    func toggleDialogOption() {
        guard dialog?.option != nil else { return }
        dialog?.option?.isOn.toggle()
    }

    func answerDialogAlternate() {
        guard let request = dialog, request.alternateTitle != nil else { return }
        dialog = nil
        dismissPopup()
        request.onAlternate()
    }

    /// Reports a failure. Git's own message is shown as it is; DiffCode's are plain sentences.
    func showFailure(_ title: String, _ error: Error, note: String? = nil) {
        var request = DialogRequest(style: .caution, symbol: "exclamationmark.triangle", title: title,
                                    confirmTitle: L("OK", "好"), cancelTitle: nil)
        if error is Git.Failure {
            request.output = error.localizedDescription
            request.message = note ?? ""
        } else {
            request.message = [error.localizedDescription, note].compactMap { $0 }.joined(separator: "\n\n")
        }
        ask(request)
    }
}
