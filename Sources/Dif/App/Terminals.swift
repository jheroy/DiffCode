import AppKit
import Darwin
import Observation
import SwiftTerm

// MARK: - Shell helpers

enum Shell {
    /// The user's login shell, as the account database has it (a GUI app's `$SHELL` can be missing or stale).
    static let path: String = {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let candidate = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return "/bin/zsh"
    }()

    static var name: String { (path as NSString).lastPathComponent }

    /// Quotes `text` so a POSIX shell reads it back as one word. Plain paths are left as they are.
    static func quote(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-+@:,%=")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment a terminal starts with: the app's own, described as an xterm, with UTF-8 guaranteed.
    static func environment(directory: String) -> [String] {
        var env = AppEnvironment.childEnvironment
        for key in env.keys where key.hasPrefix("DIF_") || key == "TERM_SESSION_ID" || key == "OLDPWD" { env[key] = nil }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = appName
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        env["SHELL"] = path
        env["PWD"] = directory
        // Launched from Finder there is no locale at all, and without one CJK text turns into question marks.
        if env["LANG"] == nil, env["LC_ALL"] == nil, env["LC_CTYPE"] == nil {
            env["LANG"] = defaultLocale()
        }
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func defaultLocale() -> String {
        let locale = Locale.current
        if let language = locale.language.languageCode?.identifier, let region = locale.region?.identifier {
            let candidate = "\(language)_\(region).UTF-8"
            if FileManager.default.fileExists(atPath: "/usr/share/locale/\(candidate)") { return candidate }
        }
        return "en_US.UTF-8"
    }
}

// MARK: - Theme

struct TerminalTheme {
    let background: UInt32
    let foreground: UInt32
    let cursor: UInt32
    let selection: NSColor
    /// The 16 ANSI colours: black, red, green, yellow, blue, magenta, cyan, white, then their bright versions.
    let ansi: [UInt32]

    static let dark = TerminalTheme(
        background: 0x1E1F22, foreground: 0xBCBEC4, cursor: 0x548AF7,
        selection: NSColor(hex: 0x2F65CA, alpha: 0.55),
        ansi: [0x2B2D30, 0xF75464, 0x6AAB73, 0xD6BF55, 0x56A8F5, 0xC77DBB, 0x2AACB8, 0xBCBEC4,
               0x6F737A, 0xFA6675, 0x7EC482, 0xE0CE6B, 0x70B7FF, 0xD897CE, 0x4FC4CF, 0xF0F1F2])

    static let light = TerminalTheme(
        background: 0xFFFFFF, foreground: 0x1F2329, cursor: 0x3574F0,
        selection: NSColor(hex: 0x3574F0, alpha: 0.28),
        ansi: [0x1F2329, 0xC7392F, 0x1E8A34, 0x9A7300, 0x1F5FD0, 0x9A3FA6, 0x17858A, 0x8C8F99,
               0x5A5E69, 0xE5534B, 0x2DA44E, 0xB8860B, 0x3574F0, 0xB85CC4, 0x1BA3A8, 0xA2A6B3])

    static func current(for appearance: NSAppearance) -> TerminalTheme {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }
}

// MARK: - View

/// SwiftTerm's terminal view, plus what Dif adds: a silent bell that flags the pane, and dropped files
/// typed in as quoted paths. The program it shows is run by `PTYProcess`, not by SwiftTerm.
final class DifTerminalView: TerminalView, @preconcurrency TerminalViewDelegate {
    var onBell: (() -> Void)?
    /// Keystrokes, pasted text and the terminal's own replies, on their way to the program.
    var onInput: ((ArraySlice<UInt8>) -> Void)?
    var onResize: (() -> Void)?
    var onTitle: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        terminalDelegate = self
    }

    override func bell(source: Terminal) {
        onBell?()
    }

    /// The size the program is told its terminal has.
    var windowSize: winsize {
        let terminal = getTerminal()
        func clamp(_ value: CGFloat) -> UInt16 { UInt16(max(0, min(value.rounded(), CGFloat(UInt16.max)))) }
        return winsize(ws_row: clamp(CGFloat(terminal.rows)), ws_col: clamp(CGFloat(terminal.cols)),
                       ws_xpixel: clamp(frame.width), ws_ypixel: clamp(frame.height))
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?()
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    /// A program asked to put text on the clipboard (OSC 52), which is how a coding agent's "copy" works.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// A plain layer instead of AppKit's own backing layer. On current macOS the stock one answers the
    /// first `draw(_:)` with a pool of 4 MB graphics tiles (over 100 MB for a few seconds, 15 MB for good);
    /// through a plain layer the same drawing costs only the pixels it covers.
    override func makeBackingLayer() -> CALayer {
        let layer = CALayer()
        layer.contentsFormat = .RGBA8Uint
        layer.needsDisplayOnBoundsChange = true
        layer.masksToBounds = true
        return layer
    }

    // With a layer of our own, AppKit no longer turns view invalidation into layer invalidation; do it here.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        super.setNeedsDisplay(invalidRect)
        guard let layer else { return }
        let dirty = invalidRect.insetBy(dx: -1, dy: -1).intersection(bounds)
        // SwiftTerm sometimes passes its frame (superview coordinates) to mean "everything".
        if invalidRect == frame || dirty.isEmpty || (dirty.width >= bounds.width - 2 && dirty.height >= bounds.height - 2) {
            layer.setNeedsDisplay()
        } else {
            layer.setNeedsDisplay(dirty)
        }
    }

    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue { layer?.setNeedsDisplay() }
        }
    }

    private var pointerInside = false

    /// The scrollbar only shows while the pointer is over the terminal.
    func setScrollerVisible(_ visible: Bool) {
        pointerInside = visible
        refreshScroller()
    }

    /// …and only when there is something to scroll: an empty track down the side is just noise.
    func refreshScroller() {
        for case let scroller as NSScroller in subviews {
            let alpha: CGFloat = pointerInside && scroller.isEnabled ? 1 : 0
            if scroller.alphaValue != alpha { scroller.animator().alphaValue = alpha }
        }
    }

    // MARK: Wheel

    /// What a trackpad has moved that does not yet add up to a whole line.
    private var wheelRemainder: CGFloat = 0
    private var wheelMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // SwiftTerm's own `scrollWheel` cannot be overridden from outside it, so the wheel is taken before it.
        if window != nil, wheelMonitor == nil {
            wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.wheel(event) else { return event }
                return nil
            }
        } else if window == nil, let wheelMonitor {
            NSEvent.removeMonitor(wheelMonitor)
            self.wheelMonitor = nil
        }
    }

    /// Scrolling, as other Mac terminals do it. A program that asked for the mouse gets the wheel as its buttons
    /// 4 and 5. A program on the alternate screen, where there is no scrollback to move (coding agents such as
    /// Codex, `less`, `man`), gets it as arrow keys: what such programs ask for with mode 1007, and what Terminal
    /// and iTerm2 do there anyway. SwiftTerm itself only ever moves the scrollback, so in those the wheel did
    /// nothing. Anywhere else the event goes on to SwiftTerm, which moves the scrollback; `true` means it was used.
    func wheel(_ event: NSEvent) -> Bool {
        let terminal = getTerminal()
        let reporting = allowMouseReporting && terminal.mouseMode != .off
        guard reporting || terminal.isCurrentBufferAlternate else {
            wheelRemainder = 0
            return false
        }
        // Only over this terminal or its margin, and not over something lying on it (a popup, a dialog).
        // `hitTest` takes a point in the coordinates of the view's superview.
        guard event.window === window, let content = window?.contentView, let frame = content.superview,
              let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)), hit.isDescendant(of: superview ?? self) else { return false }
        let rows = max(1, terminal.rows), cols = max(1, terminal.cols)
        let lines = wheelLines(for: event, rows: rows)
        guard lines != 0 else { return true }
        if reporting {
            let point = convert(event.locationInWindow, from: nil)
            let col = min(cols - 1, max(0, Int(point.x / (bounds.width / CGFloat(cols)))))
            let row = min(rows - 1, max(0, Int((bounds.height - point.y) / (bounds.height / CGFloat(rows)))))
            let flags = event.modifierFlags
            let button = terminal.encodeButton(button: lines > 0 ? 4 : 5, release: false, shift: flags.contains(.shift),
                                               meta: flags.contains(.option), control: flags.contains(.control))
            for _ in 0..<abs(lines) { terminal.sendEvent(buttonFlags: button, x: col, y: row) }
        } else {
            let application = terminal.applicationCursor
            let key = lines > 0 ? (application ? "\u{1b}OA" : "\u{1b}[A") : (application ? "\u{1b}OB" : "\u{1b}[B")
            send(txt: String(repeating: key, count: abs(lines)))
        }
        return true
    }

    /// Whole lines, upwards positive, at most a screenful. A wheel's notches are lines already, one at least each;
    /// a trackpad's points add up until they make a line, so a slow swipe still moves.
    private func wheelLines(for event: NSEvent, rows: Int) -> Int {
        let delta = event.scrollingDeltaY
        guard event.hasPreciseScrollingDeltas else {
            wheelRemainder = 0
            guard delta != 0 else { return 0 }
            return (delta > 0 ? 1 : -1) * min(rows, max(1, Int(abs(delta).rounded())))
        }
        // A new swipe, or a turn the other way, starts from nothing.
        if event.phase == .began || (delta != 0 && wheelRemainder != 0 && (delta > 0) != (wheelRemainder > 0)) {
            wheelRemainder = 0
        }
        wheelRemainder += delta
        let lineHeight = max(1, bounds.height / CGFloat(rows))
        let lines = Int(wheelRemainder / lineHeight)
        wheelRemainder -= CGFloat(lines) * lineHeight
        return max(-rows, min(rows, lines))
    }

    func enableFileDrops() {
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        send(txt: urls.map { Shell.quote($0.path) }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }

    /// The scroller SwiftTerm installs is the classic always-visible one; the overlay style suits the rest of the app.
    func useOverlayScroller() {
        for case let scroller as NSScroller in subviews {
            scroller.scrollerStyle = .overlay
            scroller.alphaValue = 0
        }
    }
}

// MARK: - Session

/// One terminal: a shell running in a project directory, and the view that shows it.
/// The view lives here, not in SwiftUI, so switching projects or hiding the panel never restarts a shell.
@MainActor
@Observable
final class TerminalSession: Identifiable {
    let id = UUID()
    let projectID: UUID
    let directory: URL

    /// Set by the running program (OSC 0/2); empty until one does.
    var title = ""
    /// The program in the foreground: the shell itself, or whatever it is running.
    var processName = Shell.name
    /// Something other than the shell is in the foreground.
    var isBusy = false
    /// The terminal rang its bell while it was not being looked at.
    var needsAttention = false
    /// Share of the panel's width, relative to the other terminals.
    var weight: Double = 1

    @ObservationIgnored let view: DifTerminalView
    @ObservationIgnored weak var manager: TerminalManager?
    @ObservationIgnored private(set) var isStarted = false
    @ObservationIgnored private(set) var hasEnded = false
    /// Take keyboard focus as soon as the view is in a window.
    @ObservationIgnored var wantsFocus = false
    @ObservationIgnored private var exitSource: DispatchSourceProcess?
    @ObservationIgnored private var pty: PTYProcess?
    @ObservationIgnored private var startedAt = Date.distantPast

    init(projectID: UUID, directory: URL, fontSize: Double, fontFamily: String?) {
        self.projectID = projectID
        self.directory = directory
        view = DifTerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 260))
        view.font = Self.font(size: fontSize, family: fontFamily)
        view.enableFileDrops()
        view.useOverlayScroller()
        view.onBell = { [weak self] in self?.rang() }
        view.onInput = { [weak self] bytes in self?.pty?.write(bytes) }
        view.onResize = { [weak self] in
            guard let self, let pty = self.pty else { return }
            pty.resize(self.view.windowSize)
        }
        view.onTitle = { [weak self] title in
            guard let self, self.title != title else { return }
            self.title = title
        }
        applyTheme(TerminalTheme.current(for: NSApp.effectiveAppearance))
    }

    /// `family`: a family picked in Settings (a Nerd Font, say, for the icons in a shell prompt), or nil for the
    /// default face.
    static func font(size: Double, family: String?) -> NSFont {
        MonospaceFonts.font(family: family, size: size)
    }

    var displayTitle: String { title.isEmpty ? processName : title }

    /// What the program says it is doing, when that adds something to its name.
    var subtitle: String { title == processName ? "" : title }

    /// Launches the shell. Called once the view has its real size, so the first prompt is laid out for it.
    func startIfNeeded() {
        guard !isStarted else { return }
        isStarted = true
        // SwiftTerm allocates every scrollback line up front, at the current width. Sizing the history
        // only now, when the width is final, avoids re-flowing thousands of empty lines on first layout.
        view.getTerminal().changeHistorySize(TerminalManager.scrollbackLines)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let start = exists ? directory.path : NSHomeDirectory()
        // A leading dash in argv[0] is how a shell is told it is a login shell, which is what loads the user's PATH.
        guard let pty = PTYProcess.spawn(executable: Shell.path, arguments: ["-" + Shell.name],
                                         environment: Shell.environment(directory: start),
                                         directory: start, size: view.windowSize) else {
            couldNotStart()
            return
        }
        pty.onData = { [weak view] bytes in view?.feed(byteArray: bytes) }
        self.pty = pty
        startedAt = Date()
        // The pane closes when the shell exits, whatever it leaves running on the terminal behind it.
        let pid = pty.pid
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in self?.shellExited(pid) }
        source.activate()
        exitSource = source
    }

    private func couldNotStart() {
        hasEnded = true
        view.feed(text: L("Could not start \(Shell.path).", "无法启动 \(Shell.path)。") + "\r\n")
    }

    private func shellExited(_ pid: pid_t) {
        exitSource?.cancel()
        exitSource = nil
        guard !hasEnded else { return }
        hasEnded = true
        var status: Int32 = 0
        let reaped = waitpid(pid, &status, WNOHANG) == pid
        pty?.close()
        pty = nil
        // Status 127 straight away is the child saying it could not run the shell at all.
        // Leave the pane up with the reason, instead of having it blink out of existence.
        let exitCode = (status >> 8) & 0xFF
        if reaped, status & 0x7F == 0, exitCode == 127, Date().timeIntervalSince(startedAt) < 2 {
            hasEnded = false
            couldNotStart()
            return
        }
        manager?.sessionEnded(self)
    }

    func applyTheme(_ theme: TerminalTheme) {
        func color(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257, green: UInt16((hex >> 8) & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
        }
        view.installColors(theme.ansi.map(color))
        view.nativeBackgroundColor = NSColor(hex: theme.background)
        view.nativeForegroundColor = NSColor(hex: theme.foreground)
        view.caretColor = NSColor(hex: theme.cursor)
        view.selectedTextBackgroundColor = theme.selection
        view.layer?.backgroundColor = NSColor(hex: theme.background).cgColor
        view.needsDisplay = true
    }

    /// Refreshes `processName` and `isBusy` from the terminal's foreground process group.
    func pollForeground() {
        view.refreshScroller()
        guard !hasEnded, let pty, let foreground = pty.foregroundGroup else { return }
        let busy = foreground != pty.pid
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(foreground, &buffer, UInt32(buffer.count))
        var name = length > 0 ? String(cString: buffer) : Shell.name
        if name.hasPrefix("-") { name.removeFirst() }
        if busy != isBusy { isBusy = busy }
        if name != processName { processName = name }
    }

    /// True when closing would kill something the user started.
    var hasForegroundJob: Bool {
        guard !hasEnded, let pty, let foreground = pty.foregroundGroup else { return false }
        return foreground != pty.pid
    }

    private func rang() {
        let focused = view.window?.firstResponder === view && NSApp.isActive
        if !focused {
            needsAttention = true
            // A bell is how a coding agent says "your turn". Nudge the Dock icon if Dif is in the background.
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// Ends the shell and everything it started.
    func terminate() {
        guard !hasEnded else { return }
        hasEnded = true
        exitSource?.cancel()
        exitSource = nil
        guard let pty else { return }
        self.pty = nil
        let pid = pty.pid
        // Hang up first, as closing a terminal window does; an interactive shell ignores a plain SIGTERM.
        kill(pid, SIGHUP)
        // Giving up the terminal makes the kernel hang up on whatever is still in the foreground.
        pty.close()
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0) // reap it, so no zombie lingers until Dif quits
        }
    }
}

// MARK: - Manager

/// Every open terminal, grouped by project, and the panel that shows the current project's.
@MainActor
@Observable
final class TerminalManager {
    /// Lines of history per terminal. Each costs about 26 bytes per column whether used or not
    /// (≈ 8 MB for a full-width terminal), so this is a budget, not a free number.
    static let scrollbackLines = 2000

    var sessions: [TerminalSession] = [] { didSet { updatePolling() } }
    var isVisible = false { didSet { if isVisible != oldValue { updatePolling() } } }
    /// The terminal that has keyboard focus, if one does.
    var focusedID: UUID?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var lastActive: [UUID: UUID] = [:]
    @ObservationIgnored private var focusObservation: NSKeyValueObservation?
    @ObservationIgnored private var pollTimer: Timer?

    func sessions(for project: Project) -> [TerminalSession] {
        sessions.filter { $0.projectID == project.id }
    }

    func hasSessions(_ project: Project) -> Bool { sessions.contains { $0.projectID == project.id } }

    func needsAttention(_ project: Project) -> Bool { sessions.contains { $0.projectID == project.id && $0.needsAttention } }

    var focused: TerminalSession? { focusedID.flatMap { id in sessions.first { $0.id == id } } }

    /// The terminal that commands act on: the focused one, else the one last used in this project.
    func active(for project: Project) -> TerminalSession? {
        let own = sessions(for: project)
        if let focused, focused.projectID == project.id { return focused }
        if let id = lastActive[project.id], let session = own.first(where: { $0.id == id }) { return session }
        return own.last
    }

    // MARK: Window

    /// Follows keyboard focus, so the panel knows which terminal is live.
    func attach(to window: NSWindow) {
        focusObservation = window.observe(\.firstResponder, options: [.new]) { [weak self] window, _ in
            // The first responder only ever changes on the main thread, and KVO reports it there.
            MainActor.assumeIsolated {
                guard let self else { return }
                let responder = window.firstResponder
                let session = self.sessions.first { $0.view === responder }
                if self.focusedID != session?.id { self.focusedID = session?.id }
                if let session {
                    self.lastActive[session.projectID] = session.id
                    if session.needsAttention { session.needsAttention = false }
                }
            }
        }
        updatePolling()
    }

    /// The running program's name and busy state are polled only while a terminal of the current project is on
    /// screen; with no terminal, a hidden panel or a covered window there is nothing to look at and no timer.
    func updatePolling() {
        let needed = isVisible && store.map { store in
            store.isWindowVisible && store.currentProject.map { hasSessions($0) } == true
        } == true
        if needed, pollTimer == nil {
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            poll()
        } else if !needed, let timer = pollTimer {
            timer.invalidate()
            pollTimer = nil
        }
    }

    private func poll() {
        guard isVisible, let store, store.isWindowVisible, let project = store.currentProject else { return }
        for session in sessions(for: project) { session.pollForeground() }
    }

    // MARK: Actions

    /// ⌥F12, as in the IDE: show and focus the terminal, or hide it when it already has focus.
    func toggle() {
        guard AppEnvironment.hasTerminal, let store, let project = store.currentProject else { return }
        if isVisible, focused?.projectID == project.id {
            hide()
        } else {
            isVisible = true
            if let session = active(for: project) { focus(session) } else { open(in: project) }
        }
    }

    func hide() {
        guard isVisible else { return }
        let hadFocus = focusedID != nil
        isVisible = false
        if hadFocus { store?.viewer.focusCanvas() }
    }

    /// Opens a new terminal beside the others and gives it the keyboard.
    @discardableResult
    func open(in project: Project, directory: URL? = nil) -> TerminalSession? {
        guard AppEnvironment.hasTerminal else { return nil }
        let session = TerminalSession(projectID: project.id, directory: directory ?? project.url,
                                      fontSize: store?.settings.terminalFontSize ?? 12,
                                      fontFamily: store?.settings.terminalFontFamily)
        session.manager = self
        sessions.append(session)
        isVisible = true
        focus(session)
        return session
    }

    func openInCurrentProject() {
        guard let project = store?.currentProject else { return }
        open(in: project)
    }

    func focus(_ session: TerminalSession) {
        lastActive[session.projectID] = session.id
        if let window = session.view.window {
            window.makeFirstResponder(session.view)
        } else {
            session.wantsFocus = true // its container takes focus when SwiftUI mounts it
        }
    }

    func focusActive() {
        guard let project = store?.currentProject, let session = active(for: project) else { return }
        if !isVisible { isVisible = true }
        focus(session)
    }

    /// Moves focus to the neighbouring terminal. Returns false when no terminal has focus.
    func cycle(_ delta: Int) -> Bool {
        guard let focused, let project = store?.project(focused.projectID) else { return false }
        let own = sessions(for: project)
        guard own.count > 1, let index = own.firstIndex(where: { $0.id == focused.id }) else { return true }
        focus(own[(index + delta + own.count) % own.count])
        return true
    }

    /// Closes a terminal, asking first when that would kill a running program.
    func close(_ session: TerminalSession) {
        guard session.hasForegroundJob, let store else {
            remove(session)
            return
        }
        session.pollForeground()
        store.ask(DialogRequest(style: .caution, symbol: "terminal", title: L("Close this terminal?", "关闭这个终端？"),
                                message: L("This program is still running and will be terminated.", "这个程序仍在运行，关闭终端会终止它。"),
                                items: [.init(title: session.processName, detail: session.directory.path, symbol: "terminal")],
                                confirmTitle: L("Close Terminal", "关闭终端"),
                                onConfirm: { [weak self] in self?.remove(session) }))
    }

    /// ⌘W: closes the focused terminal. Returns false when no terminal has focus.
    func closeFocused() -> Bool {
        guard let focused else { return false }
        close(focused)
        return true
    }

    /// ⌘K: wipes the screen and scrollback, then asks the program to draw itself again.
    func clearFocused() {
        guard let session = focused ?? store?.currentProject.flatMap({ active(for: $0) }) else { return }
        session.view.feed(text: "\u{1B}[H\u{1B}[2J\u{1B}[3J")
        session.view.send(txt: "\u{0C}")
    }

    /// Types `text` into the project's active terminal without running it.
    func type(_ text: String, in project: Project) {
        guard let session = active(for: project) ?? open(in: project) else { return }
        isVisible = true
        // A terminal that has not started yet has nothing to read the text; wait for its shell.
        let delay: TimeInterval = session.isStarted ? 0 : 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            session.view.send(txt: text)
            self?.focus(session)
        }
    }

    func insert(path: String, in project: Project) {
        type(Shell.quote(path) + " ", in: project)
    }

    private func remove(_ session: TerminalSession) {
        session.terminate()
        sessionEnded(session)
    }

    /// The shell exited, or the terminal was closed: drop the pane and pass focus on.
    func sessionEnded(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let wasFocused = focusedID == session.id
        sessions.remove(at: index)
        if lastActive[session.projectID] == session.id { lastActive[session.projectID] = nil }
        guard let store else { return }
        let remaining = sessions.filter { $0.projectID == session.projectID }
        if let next = remaining.last {
            if wasFocused { focus(next) }
        } else if store.currentProject?.id == session.projectID {
            isVisible = false
            if wasFocused { store.viewer.focusCanvas() }
        }
    }

    func removeAll(for project: Project) {
        for session in sessions(for: project) {
            session.terminate()
            sessions.removeAll { $0.id == session.id }
        }
        lastActive[project.id] = nil
    }

    /// Terminals with a program running in them, for the quit confirmation.
    var busySessions: [TerminalSession] { sessions.filter(\.hasForegroundJob) }

    func terminateAll() {
        sessions.forEach { $0.terminate() }
    }

    func applyFont(size: Double, family: String?) {
        let font = TerminalSession.font(size: size, family: family)
        for session in sessions { session.view.font = font }
    }
}
