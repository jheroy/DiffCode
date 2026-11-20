import AppKit
import SwiftUI

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private var handler: (() -> Void)?

    convenience init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.keyEquivalentModifierMask = modifiers
        self.target = self
        self.handler = handler
    }

    @objc private func fire() { handler?() }
}

/// A user-invocable action. One table feeds the menu bar, Find Action, and the keymap sheet,
/// so a shortcut can never be documented one way and bound another.
struct AppCommand: Identifiable {
    enum Group: String, CaseIterable {
        case file, view, navigate, git, terminal

        var title: String {
            switch self {
            case .file: return L("File", "文件")
            case .view: return L("View", "视图")
            case .navigate: return L("Navigate", "导航")
            case .git: return "Git"
            case .terminal: return L("Terminal", "终端")
            }
        }
    }

    let id: String
    let title: String
    let symbol: String
    let group: Group
    var key = ""
    var modifiers: NSEvent.ModifierFlags = []
    /// Shown instead of the derived label, for shortcuts that are not menu key equivalents (double Shift).
    var shortcutLabel: String?
    var separatorBefore = false
    let action: () -> Void

    var shortcut: String {
        shortcutLabel ?? KeyLabel.describe(key: key, modifiers: modifiers)
    }
}

enum KeyLabel {
    static func function(_ n: Int) -> String {
        String(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!)
    }

    static func describe(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard let scalar = key.unicodeScalars.first else { return "" }
        var label = ""
        if modifiers.contains(.control) { label += "⌃" }
        if modifiers.contains(.option) { label += "⌥" }
        if modifiers.contains(.shift) { label += "⇧" }
        if modifiers.contains(.command) { label += "⌘" }
        let value = Int(scalar.value)
        if value >= NSF1FunctionKey, value <= NSF35FunctionKey {
            label += "F\(value - NSF1FunctionKey + 1)"
        } else {
            switch key {
            case "\r": label += "↩"
            case " ": label += "Space"
            default: label += key.uppercased()
            }
        }
        return label
    }
}

extension AppStore {
    /// Shortcuts mirror the user's GoLand macOS keymap (`macOS copy.xml`) wherever an equivalent action exists.
    var commands: [AppCommand] {
        let viewer = self.viewer
        return [
            // File
            AppCommand(id: "project.add", title: L("Add Project…", "添加项目…"), symbol: "plus.rectangle.on.folder", group: .file,
                       key: "n", modifiers: .command) { [weak self] in self?.presentAddProject() },
            AppCommand(id: "git.refresh", title: L("Refresh", "刷新"), symbol: "arrow.clockwise", group: .file) { [weak self] in self?.refreshCurrent() },
            // Edits are written on their own a moment after typing stops; this writes them now.
            AppCommand(id: "file.save", title: L("Save", "保存"), symbol: "square.and.arrow.down", group: .file,
                       key: "s", modifiers: .command) { viewer.saveNow() },
            AppCommand(id: "file.reveal", title: L("Reveal in Finder", "在 Finder 中显示"), symbol: "folder", group: .file,
                       separatorBefore: true) { [weak self] in
                self?.revealInFinder()
            },
            AppCommand(id: "file.copyPath", title: L("Copy Path", "复制路径"), symbol: "doc.on.doc", group: .file,
                       key: "c", modifiers: [.command, .shift]) { [weak self] in self?.copyPath() },
            AppCommand(id: "file.copyReference", title: L("Copy Path with Line Number", "复制路径和行号"), symbol: "number", group: .file,
                       key: "c", modifiers: [.command, .shift, .option]) { [weak self] in self?.copyPath(withLine: true) },

            // View
            AppCommand(id: "view.projects", title: L("Sidebar", "侧边栏"), symbol: "sidebar.left", group: .view,
                       key: "s", modifiers: [.command, .control]) { [weak self] in self?.toggleSidebar() },
            // ⌘K toggles the Changes / History list panel, except when a terminal has focus (clears terminal buffer).
            AppCommand(id: "view.list", title: L("Toggle Changes / History Panel", "显示/隐藏 变更/历史栏"), symbol: "sidebar.right", group: .view,
                       key: "k", modifiers: .command) { [weak self] in
                guard let self else { return }
                if self.terminals.focusedID != nil {
                    self.terminals.clearFocused()
                } else {
                    let hiding = self.listVisible
                    withAnimation(.snappy(duration: 0.2)) { self.listVisible.toggle() }
                    if hiding, let name = self.focusedListName, name != KeyboardListName.tree {
                        self.viewer.focusCanvas()
                    }
                }
            },
            AppCommand(id: "view.files", title: L("Project Files", "项目文件"), symbol: "folder", group: .view,
                       key: "1", modifiers: .command) { [weak self] in self?.toggleFileTree() },
            AppCommand(id: "view.changes", title: L("Local Changes", "本地变更"), symbol: "list.bullet.indent", group: .view,
                       key: "0", modifiers: .command) { [weak self] in self?.toggleTab(.changes) },
            AppCommand(id: "view.groups", title: L("AI Change Groups", "AI 变更分组"), symbol: "sparkles.rectangle.stack", group: .view,
                       key: "8", modifiers: .command) { [weak self] in self?.toggleTab(.groups) },
            AppCommand(id: "view.log", title: L("Git Log", "提交历史"), symbol: "clock.arrow.circlepath", group: .view,
                       key: "9", modifiers: .command) { [weak self] in self?.toggleTab(.log) },
            AppCommand(id: "view.terminal", title: L("Terminal", "终端"), symbol: "terminal", group: .view,
                       key: "t", modifiers: .command) { [weak self] in self?.terminals.toggle() },
            AppCommand(id: "view.maximize", title: L("Hide All Tool Windows", "隐藏所有工具栏"), symbol: "arrow.up.left.and.arrow.down.right",
                       group: .view, key: KeyLabel.function(12), modifiers: [.command, .shift]) { [weak self] in self?.toggleMaximizeViewer() },
            AppCommand(id: "view.unified", title: L("Toggle Side-by-Side / Unified", "切换 并排 / 合并 视图"), symbol: "rectangle.split.2x1",
                       group: .view, key: "v", modifiers: [.command, .option], separatorBefore: true) { viewer.toggleUnified() },
            AppCommand(id: "view.whitespace", title: L("Ignore Whitespace", "忽略空白差异"), symbol: "space", group: .view,
                       key: "w", modifiers: [.command, .option]) { viewer.toggleWhitespace() },
            AppCommand(id: "view.flat", title: L("Toggle Tree / Flat List", "切换 目录树 / 平铺列表"), symbol: "list.bullet", group: .view) { [weak self] in
                guard let self else { return }
                self.settings.flatList.toggle()
                self.settings.save()
            },
            AppCommand(id: "view.vimMode", title: L("Toggle Vim Mode", "切换 Vim 模式"), symbol: "v.square", group: .view) { [weak self] in
                guard let self else { return }
                self.viewer.setVimMode(!self.settings.vimMode)
            },
            AppCommand(id: "view.lineDiffBar", title: L("Toggle Inline Line Diff Bar", "显示/隐藏 底部行内对比栏"), symbol: "rectangle.split.1x2", group: .view) { [weak self] in
                guard let self else { return }
                self.settings.showLineDiffBar.toggle()
                self.settings.save()
                if self.settings.showLineDiffBar {
                    self.viewer.refreshLineDiff()
                }
            },
            AppCommand(id: "view.fontUp", title: L("Increase Font Size", "增大字号"), symbol: "textformat.size.larger", group: .view,
                       key: ".", modifiers: [.control, .shift], separatorBefore: true) { viewer.changeFontSize(by: 1) },
            AppCommand(id: "view.fontDown", title: L("Decrease Font Size", "减小字号"), symbol: "textformat.size.smaller", group: .view,
                       key: ",", modifiers: [.control, .shift]) { viewer.changeFontSize(by: -1) },
            AppCommand(id: "view.uiFontUp", title: L("Increase Interface Font Size", "增大界面字号"), symbol: "plus.magnifyingglass", group: .view) { [weak self] in
                self?.changeInterfaceFontSize(by: 1)
            },
            AppCommand(id: "view.uiFontDown", title: L("Decrease Interface Font Size", "减小界面字号"), symbol: "minus.magnifyingglass", group: .view) { [weak self] in
                self?.changeInterfaceFontSize(by: -1)
            },
            AppCommand(id: "view.theme", title: L("Switch Light / Dark Theme", "切换 浅色 / 深色 主题"), symbol: "circle.lefthalf.filled", group: .view) { [weak self] in
                guard let self else { return }
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.settings.appearance = dark ? .light : .dark
                self.settings.save()
                self.settings.applyAppearance()
            },

            // Navigate
            AppCommand(id: "nav.everywhere", title: L("Search Everywhere", "随处搜索"), symbol: "magnifyingglass", group: .navigate,
                       shortcutLabel: "⇧⇧") { [weak self] in self?.showQuickOpen(.all) },
            AppCommand(id: "nav.file", title: L("Go to File…", "查找文件…"), symbol: "doc.text.magnifyingglass", group: .navigate,
                       key: "p", modifiers: .command) { [weak self] in self?.showQuickOpen(.files) },
            AppCommand(id: "nav.symbol", title: L("Go to Symbol…", "查找符号…"), symbol: "curlybraces", group: .navigate,
                       key: "o", modifiers: [.command, .option]) { [weak self] in self?.showQuickOpen(.symbols) },
            AppCommand(id: "nav.findInPath", title: L("Find in Files…", "在文件中查找…"), symbol: "text.magnifyingglass", group: .navigate,
                       key: "f", modifiers: .command) { [weak self] in self?.showFindInPath() },
            AppCommand(id: "nav.action", title: L("Find Action…", "查找操作…"), symbol: "command", group: .navigate,
                       key: "a", modifiers: [.command, .shift]) { [weak self] in self?.showQuickOpen(.actions) },
            AppCommand(id: "nav.recent", title: L("Recent Files", "最近的文件"), symbol: "clock", group: .navigate,
                       key: "e", modifiers: .command) { [weak self] in self?.showQuickOpen(.recent) },
            AppCommand(id: "nav.fileSymbols", title: L("File Structure…", "文件结构…"), symbol: "list.bullet.indent", group: .navigate,
                       key: "r", modifiers: .command) { [weak self] in self?.showFileSymbols() },
            AppCommand(id: "nav.line", title: L("Go to Line…", "跳转到行…"), symbol: "arrow.right.to.line", group: .navigate) { [weak self] in
                guard let self, self.viewer.isTextDocument else { return }
                self.present(.goToLine)
            },
            AppCommand(id: "nav.nextSplitter", title: L("Focus Viewer", "聚焦查看器"), symbol: "rectangle.righthalf.inset.filled", group: .navigate,
                       key: "l", modifiers: .command, separatorBefore: true) { [weak self] in self?.focusViewer() },
            AppCommand(id: "nav.prevSplitter", title: L("Focus File List", "聚焦文件列表"), symbol: "rectangle.lefthalf.inset.filled", group: .navigate,
                       key: "h", modifiers: .command) { [weak self] in
                guard let self else { return }
                if self.focusedListName == KeyboardListName.list, self.sidebarVisible {
                    self.focusTree()
                } else {
                    self.focusList()
                }
            },
            AppCommand(id: "nav.back", title: L("Navigate Back", "后退"), symbol: "chevron.left", group: .navigate,
                       key: "[", modifiers: .command, separatorBefore: true) { [weak self] in self?.navigateBack() },
            AppCommand(id: "nav.forward", title: L("Navigate Forward", "前进"), symbol: "chevron.right", group: .navigate,
                       key: "]", modifiers: .command) { [weak self] in self?.navigateForward() },
            AppCommand(id: "nav.nextDiff", title: L("Next Difference", "下一处差异"), symbol: "arrow.down", group: .navigate,
                       key: KeyLabel.function(7), separatorBefore: true) { viewer.stepDifference(1) },
            AppCommand(id: "nav.prevDiff", title: L("Previous Difference", "上一处差异"), symbol: "arrow.up", group: .navigate,
                       key: KeyLabel.function(7), modifiers: .shift) { viewer.stepDifference(-1) },
            // In the IDE these keys mean "next tab" wherever you are; with a terminal focused they walk the terminals.
            AppCommand(id: "nav.nextFile", title: L("Compare Next File", "下一个文件"), symbol: "arrow.right.doc.on.clipboard", group: .navigate,
                       key: "]", modifiers: [.command, .shift]) { [weak self] in
                guard let self, !self.terminals.cycle(1) else { return }
                self.stepFile(1)
            },
            AppCommand(id: "nav.prevFile", title: L("Compare Previous File", "上一个文件"), symbol: "arrow.left.doc.on.clipboard", group: .navigate,
                       key: "[", modifiers: [.command, .shift]) { [weak self] in
                guard let self, !self.terminals.cycle(-1) else { return }
                self.stepFile(-1)
            },
            AppCommand(id: "nav.locate", title: L("Select Opened File in Tree", "在文件树中定位当前文件"), symbol: "scope", group: .navigate,
                       key: KeyLabel.function(1), modifiers: .option) { [weak self] in self?.locateInTree() },
            AppCommand(id: "nav.showDiff", title: L("Show Diff", "查看差异"), symbol: "arrow.left.arrow.right", group: .navigate,
                       key: "d", modifiers: .command, separatorBefore: true) { [weak self] in self?.focusViewer() },
            AppCommand(id: "nav.nextProject", title: L("Next Project", "下一个项目"), symbol: "chevron.down.square", group: .navigate,
                       key: "]", modifiers: [.command, .option]) { [weak self] in self?.selectProject(offset: 1) },
            AppCommand(id: "nav.prevProject", title: L("Previous Project", "上一个项目"), symbol: "chevron.up.square", group: .navigate,
                       key: "[", modifiers: [.command, .option]) { [weak self] in self?.selectProject(offset: -1) },
            AppCommand(id: "help.keymap", title: L("Keymap Reference", "快捷键一览"), symbol: "keyboard", group: .navigate,
                       key: "/", modifiers: .command, separatorBefore: true) { [weak self] in self?.present(.keymap) },

            // Git. Dif reads the repository and otherwise leaves it alone; these are the exceptions.
            AppCommand(id: "git.commit", title: L("Commit…", "提交…"), symbol: "checkmark.circle", group: .git,
                       key: "c", modifiers: [.shift, .control, .option]) { [weak self] in self?.focusCommitMessage() },
            AppCommand(id: "git.commitPush", title: L("Commit and Push…", "提交并推送…"), symbol: "arrow.up.circle", group: .git,
                       key: "\r", modifiers: [.command, .shift]) { [weak self] in self?.commitCurrent(thenPush: true) },
            AppCommand(id: "git.amend", title: L("Amend Last Commit", "修改上次提交 (Amend)"), symbol: "pencil.circle",
                       group: .git) { [weak self] in self?.toggleAmend() },
            AppCommand(id: "git.undoCommit", title: L("Undo Last Commit", "撤销上次提交"), symbol: "arrow.uturn.backward.circle",
                       group: .git) { [weak self] in self?.undoLastCommit() },
            AppCommand(id: "git.push", title: L("Push…", "推送…"), symbol: "arrow.up", group: .git,
                       key: "k", modifiers: [.command, .shift], separatorBefore: true) { [weak self] in self?.push() },
            AppCommand(id: "git.pull", title: L("Update Project (Pull)", "更新项目 (拉取)"), symbol: "arrow.down", group: .git) { [weak self] in
                self?.pull()
            },
            AppCommand(id: "git.fetch", title: L("Fetch", "获取远程更新"), symbol: "arrow.triangle.2.circlepath", group: .git) { [weak self] in
                self?.fetch()
            },
            AppCommand(id: "git.newBranch", title: L("New Branch…", "新建分支…"), symbol: "arrow.triangle.branch", group: .git) { [weak self] in
                self?.newBranch()
            },
            AppCommand(id: "git.stash", title: L("Stash Changes…", "Stash 改动…"), symbol: "tray.and.arrow.down", group: .git,
                       separatorBefore: true) { [weak self] in self?.stashChanges() },
            AppCommand(id: "git.stashes", title: L("Stashes…", "Stash 列表…"), symbol: "tray.full", group: .git) { [weak self] in
                self?.showStashes()
            },
            AppCommand(id: "git.continue", title: L("Continue Merge / Rebase", "继续合并 / 变基"), symbol: "play.circle", group: .git,
                       separatorBefore: true) { [weak self] in
                self?.continueOperation()
            },
            AppCommand(id: "git.abort", title: L("Abort Merge / Rebase…", "中止合并 / 变基…"), symbol: "xmark.octagon", group: .git) { [weak self] in
                self?.abortOperation()
            },
            AppCommand(id: "git.graph", title: L("Branches and Git Graph…", "分支与 Git 树…"), symbol: "point.3.connected.trianglepath.dotted", group: .git,
                       key: "b", modifiers: [.command, .option], separatorBefore: true) { [weak self] in self?.toggleGitGraph() },
            AppCommand(id: "git.annotate", title: L("Annotate with Git Blame", "逐行追溯 (Blame)"), symbol: "person.text.rectangle",
                       group: .git, separatorBefore: true) { viewer.toggleAnnotate() },
            AppCommand(id: "git.history", title: L("Show History for Current File", "查看当前文件的历史"), symbol: "clock.arrow.circlepath",
                       group: .git) { [weak self] in self?.showHistoryForCurrentFile() },
            AppCommand(id: "git.historySelection", title: L("Show History for Selection", "查看所选内容的历史"),
                       symbol: "text.line.first.and.arrowtriangle.forward", group: .git,
                       key: "b", modifiers: .command) { [weak self] in self?.showHistoryForSelection() },
            AppCommand(id: "git.compare", title: L("Compare with Branch…", "与分支比较…"), symbol: "arrow.left.arrow.right",
                       group: .git) { [weak self] in self?.showComparePicker() },
            AppCommand(id: "git.endCompare", title: L("Stop Comparing", "退出比较"), symbol: "xmark.circle", group: .git) { [weak self] in
                self?.endComparison()
            },
            AppCommand(id: "git.rollback", title: L("Rollback…", "回滚…"), symbol: "arrow.uturn.backward", group: .git,
                       key: "z", modifiers: [.command, .option], separatorBefore: true) { [weak self] in self?.rollbackInContext() },
            AppCommand(id: "git.rollbackHunk", title: L("Rollback Current Change", "回滚当前这处变更"), symbol: "arrow.uturn.backward.square",
                       group: .git) { [weak self] in self?.rollbackCurrentHunk() },
            AppCommand(id: "git.delete", title: L("Delete New Files…", "删除新增的文件…"), symbol: "trash", group: .git,
                       shortcutLabel: "⌫") { [weak self] in self?.deleteInContext() },
            AppCommand(id: "git.undo", title: L("Undo Rollback / Delete", "撤销回滚 / 删除"), symbol: "arrow.uturn.forward", group: .git,
                       shortcutLabel: "⌘Z", separatorBefore: true) { [weak self] in self?.undoEdit() },

            // Terminal
            AppCommand(id: "term.new", title: L("New Terminal", "新建终端"), symbol: "plus.rectangle", group: .terminal) { [weak self] in
                self?.terminals.openInCurrentProject()
            },
            AppCommand(id: "term.focus", title: L("Focus Terminal", "聚焦终端"), symbol: "terminal", group: .terminal) { [weak self] in
                self?.terminals.focusActive()
            },
            AppCommand(id: "term.insertPath", title: L("Insert File Path into Terminal", "把当前文件路径插入终端"), symbol: "text.insert", group: .terminal,
                       key: "t", modifiers: [.command, .option]) { [weak self] in self?.insertReferenceInTerminal() },
            // ⌘K belongs to Toggle Changes / History Panel; with a terminal focused, it clears the terminal.
            AppCommand(id: "term.clear", title: L("Clear Terminal", "清空终端"), symbol: "clear", group: .terminal,
                       shortcutLabel: "⌘K", separatorBefore: true) { [weak self] in self?.terminals.clearFocused() },
            AppCommand(id: "term.close", title: L("Close Terminal", "关闭终端"), symbol: "xmark.rectangle", group: .terminal) { [weak self] in
                _ = self?.terminals.closeFocused()
            },
        ]
        .filter { AppEnvironment.hasTerminal || ($0.group != .terminal && $0.id != "view.terminal") }
        .filter { AppEnvironment.hasLSP || ($0.id != "nav.back" && $0.id != "nav.forward") }
        .filter { !AppEnvironment.isAppStore || $0.id != "view.groups" }
        + editionCommands
    }

    /// The App Store edition reaches only the folders it was given.
    private var editionCommands: [AppCommand] {
        guard FolderAccess.shared.isNeeded else { return [] }
        return [
            AppCommand(id: "project.grantAccess", title: L("Grant Folder Access…", "授权访问文件夹…"), symbol: "lock.open", group: .file,
                       separatorBefore: true) { [weak self] in self?.presentGrantFolderAccess() },
        ]
    }
}
