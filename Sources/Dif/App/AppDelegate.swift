import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private let store = AppStore.shared
    private var monitor: Any?
    private var shiftDownAt: TimeInterval?
    private var lastShiftTap: TimeInterval?
    private var pendingURLs: [URL] = []
    private var launched = false
    /// Set once quitting was agreed to (or, in an unattended test run, is not to be asked about).
    var quitConfirmed = false
    /// Restart (Settings, after a language change): once the quit goes through, DiffCode opens again.
    var relaunchAfterQuit = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.settings.applyAppearance()
        buildMenu()
        makeWindow()
        store.bootstrap()
        store.terminals.attach(to: window)
        installEventMonitor()
        AppEnvironment.updater?.start()
        launched = true

        // `dif <path>` from a terminal: every non-flag argument is a repository to open.
        var urls = pendingURLs
        var skipNext = false
        for argument in CommandLine.arguments.dropFirst() {
            if skipNext { skipNext = false; continue }
            if argument.hasPrefix("-") { skipNext = argument.hasPrefix("-NS") || argument.hasPrefix("-Apple"); continue }
            urls.append(URL(fileURLWithPath: argument))
        }
        if !urls.isEmpty { store.addProjects(urls) }
        #if DEBUG || DIF_HOOKS
        DebugHooks.run(store: store, window: window)
        #endif
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if launched { store.addProjects(urls) } else { pendingURLs += urls }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting takes every terminal down with it, so ask before killing an agent or a build mid-run.
    ///
    /// The quit is called off and asked about in the window; agreeing quits again. Not `.terminateLater`: that
    /// waits for the answer in a nested event loop, and when the quit came from code already running on the
    /// main queue, nothing queued behind it (the question's own focus and updates among them) could run.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A restart that has to ask first goes ahead only on a yes: a no calls it off along with the quit.
        let restarting = relaunchAfterQuit
        // Typing not yet written goes to the file; if it cannot (or could not, in a file left since), ask rather than lose it.
        let viewer = store.viewer
        var unsaved = viewer.unsavedTexts.map { DialogRequest.Item(title: $0.name, symbol: "doc.text") }
        if !quitConfirmed, !viewer.saveEdits(), let path = viewer.request?.path {
            unsaved.insert(DialogRequest.Item(title: (path as NSString).lastPathComponent, symbol: "doc.text"), at: 0)
        }
        if !quitConfirmed, !unsaved.isEmpty {
            relaunchAfterQuit = false
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            store.ask(DialogRequest(style: .caution, symbol: "exclamationmark.triangle",
                                    title: restarting ? L("Restart \(appName)? Your latest changes could not be saved.", "重启 \(appName)？最近的修改没能保存。")
                                                      : L("Quit \(appName)? Your latest changes could not be saved.", "退出 \(appName)？最近的修改没能保存。"),
                                    message: restarting ? L("Restarting discards them.", "重启会丢弃这些修改。")
                                                        : L("Quitting discards them.", "退出会丢弃这些修改。"),
                                    items: unsaved,
                                    confirmTitle: restarting ? L("Restart Anyway", "仍然重启") : L("Quit Anyway", "仍然退出"),
                                    onConfirm: { [weak self] in self?.quitAgreed(restarting: restarting) }))
            return .terminateCancel
        }
        let busy = store.terminals.busySessions
        guard !busy.isEmpty, !quitConfirmed else { return .terminateNow }
        relaunchAfterQuit = false
        busy.forEach { $0.pollForeground() }
        // The question is asked in the window, so the window has to be where the user can see it.
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        let items = busy.map { session in
            DialogRequest.Item(title: session.processName, detail: store.project(session.projectID)?.name ?? session.directory.lastPathComponent,
                               symbol: "terminal")
        }
        let title: String
        switch (restarting, busy.count == 1) {
        case (false, true): title = L("Quit \(appName)? A terminal is still running a program.", "退出 \(appName)？还有一个终端正在运行程序。")
        case (false, false): title = L("Quit \(appName)? \(busy.count) terminals are still running programs.", "退出 \(appName)？还有 \(busy.count) 个终端正在运行程序。")
        case (true, true): title = L("Restart \(appName)? A terminal is still running a program.", "重启 \(appName)？还有一个终端正在运行程序。")
        case (true, false): title = L("Restart \(appName)? \(busy.count) terminals are still running programs.", "重启 \(appName)？还有 \(busy.count) 个终端正在运行程序。")
        }
        store.ask(DialogRequest(style: .caution, symbol: "power", title: title,
                                message: restarting ? L("Restarting terminates them.", "重启会终止它们。") : L("Quitting terminates them.", "退出会终止它们。"),
                                items: items,
                                confirmTitle: restarting ? L("Restart", "重启") : L("Quit", "退出"),
                                onConfirm: { [weak self] in self?.quitAgreed(restarting: restarting) }))
        return .terminateCancel
    }

    /// The question was answered yes: quit (and open again, for a restart) without asking twice.
    private func quitAgreed(restarting: Bool) {
        quitConfirmed = true
        relaunchAfterQuit = restarting
        NSApp.terminate(nil)
    }

    /// Opens DiffCode again once this process is gone: a shell waits for the pid to exit (20 s at most), then
    /// opens the app bundle, or starts the binary again for a bare build. `DIF_` test settings stay behind.
    private func relaunchWhenGone() {
        let bundle = Bundle.main.bundleURL
        let isApp = bundle.pathExtension == "app"
        let target = isApp ? bundle.path : (Bundle.main.executablePath ?? CommandLine.arguments[0])
        let start = isApp ? "exec /usr/bin/open \"$2\"" : "exec \"$2\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 200 ]; do sleep 0.1; i=$((i+1)); done; \(start)",
                             "sh", String(ProcessInfo.processInfo.processIdentifier), target]
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("DIF_") }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Edit ▸ Undo (⌘Z). In a text field it undoes the typing, as anywhere on the Mac; elsewhere it takes back
    /// the last rollback or delete.
    ///
    /// Not `undo:` itself: the window answers that one before the app delegate is ever asked, and with nothing
    /// typed to undo it disables the item, so ⌘Z never reached the rollbacks.
    @objc func undoTypingOrEdit(_ sender: Any?) {
        if let manager = textUndoManager {
            if manager.canUndo { manager.undo() }
        } else if let canvas = editingCanvas, canvas.canUndoTyping {
            // Typing in the diff, and changes rolled back there.
            canvas.undoTyping()
        } else {
            store.undoEdit()
        }
    }

    /// Edit ▸ Redo (⇧⌘Z): in a text field, its own; in the diff, the typing undone there.
    @objc func redoTyping(_ sender: Any?) {
        if let manager = textUndoManager {
            if manager.canRedo { manager.redo() }
        } else if let canvas = editingCanvas, canvas.canRedoTyping {
            canvas.redoTyping()
        }
    }

    /// The undo stack of the text field being typed in, if one is.
    private var textUndoManager: UndoManager? {
        guard let text = store.window?.firstResponder as? NSTextView, text.window != nil else { return nil }
        return text.undoManager
    }

    /// The diff, when it has the keyboard and its text can be edited.
    private var editingCanvas: CodeCanvasView? {
        guard let canvas = store.viewer.container?.canvas, store.window?.firstResponder === canvas, canvas.editor != nil else { return nil }
        return canvas
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.settings.save()
        store.terminals.terminateAll()
        if AppEnvironment.hasLSP {
            // Best-effort clean shutdown of language servers without hanging app quit.
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                await LSPManager.shared.shutdownAll()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 0.5)
        }
        DiffLoader.cleanup()
        // Here, not when Restart is clicked: by now nothing can call the quit off.
        if relaunchAfterQuit { relaunchWhenGone() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        store.visibilityChanged()
    }

    func applicationDidResignActive(_ notification: Notification) {
        store.visibilityChanged()
    }

    func applicationDidHide(_ notification: Notification) {
        store.visibilityChanged()
    }

    func applicationDidUnhide(_ notification: Notification) {
        store.visibilityChanged()
    }

    // MARK: Window

    private func makeWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 880, height: 520)
        window.backgroundColor = Palette.window
        // A diff viewer has no use for wide colour; 8-bit sRGB halves the size of every backing store.
        window.depthLimit = .twentyfourBitRGB
        window.colorSpace = .sRGB

        // An empty compact toolbar gives the title bar enough height to centre the traffic lights on our headers.
        let toolbar = NSToolbar(identifier: "main")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact

        let host = NSHostingView(rootView: RootView().environment(store))
        host.sizingOptions = []
        window.contentView = host
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("DifMainWindow")

        store.window = window
        let titlebar = window.frame.height - window.contentLayoutRect.height
        if titlebar > 20 { store.titlebarHeight = titlebar }
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        store.visibilityChanged()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { store.isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { store.isFullScreen = false }

    // MARK: Events

    /// Watches for a double tap of Shift (Search Everywhere), Escape while a popup is open,
    /// GoLand secondary shortcuts, and mouse side navigation buttons.
    private func installEventMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .flagsChanged:
                if self.store.popup == nil {
                    self.store.viewer.container?.canvas.handleFlagsChanged(event)
                } else {
                    self.store.viewer.container?.canvas.clearLSPHover()
                }
                let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
                let isShift = event.keyCode == 56 || event.keyCode == 60
                if isShift, flags == .shift {
                    self.shiftDownAt = event.timestamp
                } else if isShift, flags.isEmpty, let down = self.shiftDownAt, event.timestamp - down < 0.3 {
                    // A quick press-and-release with no other key in between counts as one tap.
                    self.shiftDownAt = nil
                    if let last = self.lastShiftTap, event.timestamp - last < 0.45 {
                        self.lastShiftTap = nil
                        self.store.showQuickOpen(.all)
                    } else {
                        self.lastShiftTap = event.timestamp
                    }
                } else {
                    self.shiftDownAt = nil
                    self.lastShiftTap = nil
                }
            case .keyDown:
                self.shiftDownAt = nil
                self.lastShiftTap = nil
                // Escape while an input method composes is the input method's: it drops the composition.
                let composing = (self.store.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
                if event.keyCode == 53, self.store.popup != nil, !composing {
                    self.store.dismissPopup()
                    return nil
                }
                if !composing, self.handleSecondaryShortcut(event) {
                    return nil
                }
            case .otherMouseDown:
                self.shiftDownAt = nil
                self.lastShiftTap = nil
                if self.store.popup == nil {
                    if event.buttonNumber == 3 {
                        self.store.navigateBack()
                        return nil
                    } else if event.buttonNumber == 4 {
                        self.store.navigateForward()
                        return nil
                    }
                }
            default:
                self.shiftDownAt = nil
                self.lastShiftTap = nil
            }
            return event
        }
    }

    /// Handles GoLand secondary shortcuts that share an action with a primary menu equivalent.
    private func handleSecondaryShortcut(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // Find in Files secondary: ⇧⌘F (alongside ⌘F in Navigate menu).
        if mods == [.shift, .command], chars == "f" {
            store.showFindInPath()
            return true
        }

        // Toggle Terminal secondary: ⌥F12 (alongside ⌘T in View menu).
        if AppEnvironment.hasTerminal, store.popup == nil,
           mods == .option, event.keyCode == 111 || chars == KeyLabel.function(12) {
            store.terminals.toggle()
            return true
        }

        // Find Action secondary: ⌃⌥A (alongside ⇧⌘A in Navigate menu).
        if store.popup == nil, store.terminals.focusedID == nil,
           mods == [.control, .option], chars == "a" {
            store.showQuickOpen(.actions)
            return true
        }

        // Navigate Back / Forward secondary: ⌥⌘← / ⌥⌘→.
        if store.popup == nil, mods == [.option, .command] {
            if event.keyCode == 123 {
                store.navigateBack()
                return true
            }
            if event.keyCode == 124 {
                store.navigateForward()
                return true
            }
        }

        // Navigate Back / Forward via ⌃O / ⌃I when not in a text field, terminal, or Vim-handled canvas.
        if store.popup == nil, store.terminals.focusedID == nil,
           mods == .control,
           !(store.window?.firstResponder is NSTextView),
           !(store.settings.vimMode && store.window?.firstResponder === store.viewer.container?.canvas) {
            if chars == "o" {
                store.navigateBack()
                return true
            }
            if chars == "i" {
                store.navigateForward()
                return true
            }
        }

        // Next / Previous Diff via ⌘↓ / ⌘↑ when viewer is active (not in a popup, terminal, text field, or list).
        if store.popup == nil, store.terminals.focusedID == nil,
           !(store.window?.firstResponder is NSTextView),
           store.focusedListName == nil,
           store.viewer.isTextDocument,
           mods == .command {
            if event.keyCode == 125 {
                store.viewer.stepDifference(1)
                return true
            }
            if event.keyCode == 126 {
                store.viewer.stepDifference(-1)
                return true
            }
        }

        return false
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(ClosureMenuItem(L("About \(appName)", "关于 \(appName)"), key: "", modifiers: []) {
            // The standard panel takes its name from the bundle; a bare build (swift run) has none.
            // The credits carry the licenses of the open-source software inside (see Acknowledgements).
            NSApp.orderFrontStandardAboutPanel(options: [.applicationName: appName, .credits: Acknowledgements.credits()])
            NSApp.activate()
        })
        if MainActor.assumeIsolated({ AppEnvironment.updater != nil }) {
            appMenu.addItem(withTitle: L("Check for Updates…", "检查更新…"), action: #selector(checkForUpdates(_:)), keyEquivalent: "").target = self
        }
        appMenu.addItem(.separator())
        appMenu.addItem(ClosureMenuItem(L("Settings…", "设置…"), key: ",", modifiers: .command) { [store] in store.present(.settings) })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Hide \(appName)", "隐藏 \(appName)"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        let hideOthers = appMenu.addItem(withTitle: L("Hide Others", "隐藏其他"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: L("Show All", "全部显示"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit \(appName)", "退出 \(appName)"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(appMenu, title: appName, to: main)

        let commands = store.commands
        add(menu(for: .file, commands), title: AppCommand.Group.file.title, to: main)

        let edit = NSMenu()
        edit.addItem(withTitle: L("Undo", "撤销"), action: #selector(undoTypingOrEdit(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: L("Redo", "重做"), action: #selector(redoTyping(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy", "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(ClosureMenuItem(L("Expand Selection", "扩大选区"), key: ".", modifiers: .command) { [store] in
            guard store.popup == nil, store.terminals.focusedID == nil else { return }
            store.viewer.expandSelection()
        })
        edit.addItem(ClosureMenuItem(L("Shrink Selection", "缩小选区"), key: ";", modifiers: .command) { [store] in
            guard store.popup == nil, store.terminals.focusedID == nil else { return }
            store.viewer.shrinkSelection()
        })
        edit.addItem(.separator())
        edit.addItem(ClosureMenuItem(L("Find…", "查找…"), key: "f", modifiers: [.control, .shift, .command]) { [store] in store.viewer.showFind() })
        edit.addItem(ClosureMenuItem(L("Find Next", "查找下一个"), key: "g", modifiers: .command) { [store] in store.viewer.stepFind(1) })
        edit.addItem(ClosureMenuItem(L("Find Previous", "查找上一个"), key: "g", modifiers: [.command, .shift]) { [store] in store.viewer.stepFind(-1) })
        add(edit, title: L("Edit", "编辑"), to: main)

        add(menu(for: .view, commands), title: AppCommand.Group.view.title, to: main)
        let navigate = menu(for: .navigate, commands)
        // F7 needs Fn on most Mac keyboards, so the IDE's "Next/Previous Change" chord works too.
        for (title, key, delta) in [("Next Change", "\u{F701}", 1), ("Previous Change", "\u{F700}", -1)] {
            let item = ClosureMenuItem(title, key: key, modifiers: [.control, .option, .shift]) { [store] in store.viewer.stepDifference(delta) }
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            navigate.addItem(item)
        }
        add(navigate, title: AppCommand.Group.navigate.title, to: main)
        add(menu(for: .git, commands), title: AppCommand.Group.git.title, to: main)
        if AppEnvironment.hasTerminal {
            add(menu(for: .terminal, commands), title: AppCommand.Group.terminal.title, to: main)
        }

        let windowMenu = NSMenu()
        windowMenu.addItem(withTitle: L("Minimize", "最小化"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("Zoom", "缩放"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windowMenu.addItem(withTitle: L("Enter Full Screen", "进入全屏"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        windowMenu.addItem(.separator())
        // ⌘W closes the terminal that has the keyboard, and the window otherwise.
        windowMenu.addItem(ClosureMenuItem(L("Close", "关闭"), key: "w", modifiers: .command) { [store] in
            if !store.terminals.closeFocused() { NSApp.keyWindow?.performClose(nil) }
        })
        add(windowMenu, title: L("Window", "窗口"), to: main)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func add(_ menu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        main.addItem(item)
    }

    /// Shifted punctuation must be given as the shifted character for AppKit to match it reliably.
    private static let shifted: [String: String] = ["]": "}", "[": "{", ".": ">", ",": "<", "/": "?"]

    private func menu(for group: AppCommand.Group, _ commands: [AppCommand]) -> NSMenu {
        let menu = NSMenu()
        for command in commands where command.group == group {
            if command.separatorBefore { menu.addItem(.separator()) }
            var key = command.key
            var modifiers = command.modifiers
            if modifiers.contains(.shift), let replacement = Self.shifted[key] {
                key = replacement
                modifiers.remove(.shift)
            }
            let title = command.shortcutLabel.map { "\(command.title)    \($0)" } ?? command.title
            menu.addItem(ClosureMenuItem(title, key: key, modifiers: modifiers, handler: command.action))
        }
        return menu
    }
}

extension AppDelegate: NSMenuItemValidation {
    @objc func checkForUpdates(_ sender: Any?) {
        MainActor.assumeIsolated { AppEnvironment.updater?.checkForUpdates() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates(_:)) {
            return MainActor.assumeIsolated { AppEnvironment.updater?.canCheckForUpdates ?? false }
        }
        if item.action == #selector(redoTyping(_:)) {
            if store.terminals.focusedID != nil { return false }
            if let manager = textUndoManager { return manager.canRedo }
            return editingCanvas?.canRedoTyping ?? false
        }
        guard item.action == #selector(undoTypingOrEdit(_:)) else { return true }
        item.title = L("Undo", "撤销")
        // ⌘Z typed into a terminal is the terminal's, and not a request to change files.
        if store.terminals.focusedID != nil { return false }
        if let manager = textUndoManager { return manager.canUndo }
        if let canvas = editingCanvas, canvas.canUndoTyping { return true }
        guard store.canUndoEdit else { return false }
        item.title = L("Undo Rollback / Delete", "撤销回滚 / 删除")
        return true
    }
}

extension AppStore {
    /// Quits and opens DiffCode again, for a language change. Quitting may ask first (programs still running in
    /// terminals, typing that could not be saved); a no keeps DiffCode open.
    func restart() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }
        delegate.relaunchAfterQuit = true
        NSApp.terminate(nil)
    }
}
