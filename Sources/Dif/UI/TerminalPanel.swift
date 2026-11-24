import SwiftUI

/// Bottom panel: the current project's terminals, side by side.
struct TerminalPanel: View {
    let project: Project
    @Environment(AppStore.self) private var store

    static let minimumPaneWidth: CGFloat = 180

    var body: some View {
        let manager = store.terminals
        let sessions = manager.sessions(for: project)
        Group {
            if sessions.isEmpty {
                empty
            } else {
                GeometryReader { proxy in
                    let dividers = CGFloat(sessions.count - 1)
                    let available = max(0, proxy.size.width - dividers)
                    let total = sessions.reduce(0) { $0 + $1.weight }
                    HStack(spacing: 0) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            TerminalPane(session: session, isFocused: manager.focusedID == session.id,
                                         isFirst: index == 0, isLast: index == sessions.count - 1)
                                .frame(width: (available * session.weight / total).rounded(.down))
                            if index < sessions.count - 1 {
                                PaneDivider(left: session, right: sessions[index + 1], pointsPerWeight: available / total)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.difWindow)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                IconButton(symbol: "plus", help: L("New Terminal (⌘T)", "新建终端 (⌘T)"), size: 11.5) { manager.open(in: project) }
                IconButton(symbol: "chevron.down", help: L("Hide Terminal (⌥F12)", "隐藏终端 (⌥F12)"), size: 11) { manager.hide() }
            }
            .padding(.trailing, 6)
            .frame(height: TerminalPane.headerHeight)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(L("No terminal open in \(project.name)", "\(project.name) 里还没有打开终端"))
                .font(.ui(size: 12.5))
                .foregroundStyle(Color.difText3)
            Button {
                store.terminals.open(in: project)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                    Text(L("New Terminal", "新建终端"))
                    KeyCaps(shortcut: "⌘T")
                }
                .font(.ui(size: 12.5, weight: .medium))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difSelection))
                .foregroundStyle(Color.difText)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TerminalPane: View {
    let session: TerminalSession
    var isFocused: Bool
    var isFirst: Bool
    var isLast: Bool
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    static var headerHeight: CGFloat { UI.s(26) }

    private var bottomCorners: CACornerMask {
        var mask: CACornerMask = []
        if isFirst { mask.insert(.layerMinXMinYCorner) }
        if isLast { mask.insert(.layerMaxXMinYCorner) }
        return mask
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(session.processName)
                    .font(.ui(size: 11.5, weight: isFocused ? .semibold : .medium))
                    .foregroundStyle(isFocused ? Color.difText : Color.difText2)
                    .lineLimit(1)
                    .fixedSize()
                if session.directory.path != store.project(session.projectID)?.url.path {
                    Text(session.directory.lastPathComponent)
                        .font(.ui(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.difChip))
                }
                if !session.subtitle.isEmpty {
                    Text(session.subtitle)
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Button {
                    store.terminals.close(session)
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(size: 8.5, weight: .bold))
                        .foregroundStyle(Color.difText3)
                        .frame(width: UI.s(18), height: UI.s(18))
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.difHover : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || isFocused ? 1 : 0)
                .help(L("Close Terminal (⌘W)", "关闭终端 (⌘W)"))
            }
            .padding(.leading, 12)
            // The last pane's header shares its right end with the panel's own buttons.
            .padding(.trailing, isLast ? UI.s(26) * 2 + 12 : 6)
            .frame(height: Self.headerHeight)
            .background(Color.difPanel)
            .overlay(alignment: .top) {
                Rectangle().fill(isFocused ? Color.difAccent : Color.clear).frame(height: 1.5)
            }
            .contentShape(Rectangle())
            .onTapGesture { store.terminals.focus(session) }
            .onHover { hovering = $0 }

            TerminalHost(session: session, bottomCorners: bottomCorners)
        }
        .contextMenu {
            Button(L("New Terminal", "新建终端")) {
                if let project = store.project(session.projectID) { store.terminals.open(in: project) }
            }
            Button(L("Clear", "清屏")) {
                store.terminals.focus(session)
                store.terminals.clearFocused()
            }
            Divider()
            Button(L("Close Terminal", "关闭终端")) { store.terminals.close(session) }
        }
    }

    private var dotColor: Color {
        if session.needsAttention { return .orange }
        if session.isBusy { return Color.difAdded }
        return Color.difText3.opacity(0.6)
    }
}

/// Dragging the line between two terminals moves width from one to the other.
private struct PaneDivider: View {
    let left: TerminalSession
    let right: TerminalSession
    var pointsPerWeight: CGFloat
    @State private var start: (left: Double, right: Double)?

    var body: some View {
        DividerGrip(axis: .columns) { translation in
            guard let translation else {
                start = nil
                return
            }
            let base = start ?? (left.weight, right.weight)
            if start == nil { start = base }
            guard pointsPerWeight > 0 else { return }
            let sum = base.left + base.right
            let floor = Double(TerminalPanel.minimumPaneWidth / pointsPerWeight)
            guard sum > floor * 2 else { return }
            let moved = base.left + Double(translation / pointsPerWeight)
            let clamped = min(sum - floor, max(floor, moved))
            left.weight = clamped
            right.weight = sum - clamped
        }
    }
}

/// Mounts a session's long-lived terminal view.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    var bottomCorners: CACornerMask

    func makeNSView(context: Context) -> TerminalContainerView {
        let view = TerminalContainerView(session: session)
        view.bottomCorners = bottomCorners
        return view
    }

    func updateNSView(_ view: TerminalContainerView, context: Context) {
        if view.bottomCorners != bottomCorners {
            view.bottomCorners = bottomCorners
        }
    }
}

final class TerminalContainerView: NSView {
    private let session: TerminalSession
    /// The right edge stays clear of the divider's grab strip, so the terminal's own pointer never competes with it.
    private static let inset = NSEdgeInsets(top: 4, left: 10, bottom: 6, right: DividerGrip.grabWidth / 2 + 1)

    var bottomCorners: CACornerMask = [] {
        didSet { applyCornerMask() }
    }

    init(session: TerminalSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        applyCornerMask()
        addSubview(session.view)
        applyTheme()
    }

    private func applyCornerMask() {
        layer?.cornerRadius = bottomCorners.isEmpty ? 0 : IslandStyle.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = bottomCorners
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        // The view may have been adopted by a newer container; only the current owner lays it out.
        guard session.view.superview === self else { return }
        let inset = Self.inset
        let frame = NSRect(x: inset.left, y: inset.bottom, width: max(0, bounds.width - inset.left - inset.right),
                           height: max(0, bounds.height - inset.top - inset.bottom))
        if session.view.frame != frame { session.view.frame = frame }
        if frame.width > 80, frame.height > 40, window != nil {
            session.startIfNeeded()
            takeFocusIfWanted()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    private func takeFocusIfWanted() {
        guard session.wantsFocus, let window else { return }
        session.wantsFocus = false
        // After this layout pass, so SwiftUI has finished mounting the panel.
        DispatchQueue.main.async { [session] in
            if session.view.window === window { window.makeFirstResponder(session.view) }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        let theme = TerminalTheme.current(for: effectiveAppearance)
        layer?.backgroundColor = NSColor(hex: theme.background).cgColor
        session.applyTheme(theme)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(session.view)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { session.view.setScrollerVisible(true) }
    override func mouseExited(with event: NSEvent) { session.view.setScrollerVisible(false) }

    /// The margin around the terminal scrolls it too.
    override func scrollWheel(with event: NSEvent) {
        if session.view.superview === self { session.view.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}
