import AppKit
import SwiftUI

// MARK: - AppKit bridges

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Main window subclass that prevents rapid clicks on interactive title-bar controls
/// (including gaps between buttons and buttons that just became disabled) from triggering
/// AppKit's title-bar drag or double-click zoom/fill/minimize gestures, while keeping
/// blank title-bar regions fully draggable and double-click zoomable.
final class TitlebarWindow: NSWindow {
    private let interactionGuards = NSHashTable<NSView>.weakObjects()
    /// Whether the current press (`leftMouseDown` .. `leftMouseUp`) started inside a guard.
    private var mouseDownInGuard = false
    /// Whether the active multi-click sequence (`clickCount == 1, 2, ...`) started inside a guard,
    /// so slight cursor drift on click 2 cannot turn rapid button tapping into a title-bar zoom.
    private var clickSequenceStartedInGuard = false
    /// True while `super.sendEvent` is dispatching an event guarded against title-bar actions.
    private var isDispatchingGuardedEvent = false

    func registerInteractionGuard(_ view: NSView) {
        interactionGuards.add(view)
    }

    func unregisterInteractionGuard(_ view: NSView) {
        interactionGuards.remove(view)
    }

    func isPointInInteractionGuard(_ windowPoint: NSPoint) -> Bool {
        for view in interactionGuards.allObjects {
            guard view.window === self,
                  !view.isHiddenOrHasHiddenAncestor,
                  !view.bounds.isEmpty else { continue }
            let local = view.convert(windowPoint, from: nil)
            // On macOS 14+, `clipsToBounds` defaults to `false`, so `visibleRect` can exceed `bounds`;
            // require containment in both to match the view's actual visible footprint.
            if view.bounds.contains(local) && view.visibleRect.contains(local) {
                return true
            }
        }
        return false
    }

    func shouldBlockTitlebarAction(at windowPoint: NSPoint, clickCount: Int) -> Bool {
        if isDispatchingGuardedEvent || isPointInInteractionGuard(windowPoint) { return true }
        return clickCount >= 2 && clickSequenceStartedInGuard
    }

    override func performDrag(with event: NSEvent) {
        if shouldBlockTitlebarAction(at: event.locationInWindow, clickCount: event.clickCount) { return }
        super.performDrag(with: event)
    }

    override func performZoom(_ sender: Any?) {
        if isDispatchingGuardedEvent { return }
        super.performZoom(sender)
    }

    override func zoom(_ sender: Any?) {
        if isDispatchingGuardedEvent { return }
        super.zoom(sender)
    }

    override func performMiniaturize(_ sender: Any?) {
        if isDispatchingGuardedEvent { return }
        super.performMiniaturize(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        let isLeftMouse = event.type == .leftMouseDown || event.type == .leftMouseUp || event.type == .leftMouseDragged
        guard isLeftMouse else {
            super.sendEvent(event)
            return
        }

        let inGuard = isPointInInteractionGuard(event.locationInWindow)
        if event.type == .leftMouseDown {
            if event.clickCount <= 1 {
                clickSequenceStartedInGuard = inGuard
            } else if inGuard {
                clickSequenceStartedInGuard = true
            }
            mouseDownInGuard = inGuard || (event.clickCount >= 2 && clickSequenceStartedInGuard)
        }

        let guarded = mouseDownInGuard || inGuard || (event.clickCount >= 2 && clickSequenceStartedInGuard)
        defer {
            if event.type == .leftMouseUp {
                mouseDownInGuard = false
            }
        }

        guard guarded else {
            super.sendEvent(event)
            return
        }

        let wasDispatching = isDispatchingGuardedEvent
        isDispatchingGuardedEvent = true
        var disabledRecognizers: [NSGestureRecognizer] = []
        if let frameView = contentView?.superview {
            disableTitlebarRecognizers(in: frameView, collecting: &disabledRecognizers)
        }
        defer {
            for recognizer in disabledRecognizers {
                recognizer.isEnabled = true
            }
            isDispatchingGuardedEvent = wasDispatching
        }
        super.sendEvent(event)
    }

    /// Temporarily disables enabled gesture recognizers on the window frame and titlebar chrome
    /// (excluding `contentView` and its descendants) so AppKit's titlebar double-click and drag
    /// recognizers never fire for events targeting guarded toolbar controls.
    private func disableTitlebarRecognizers(in view: NSView, collecting disabled: inout [NSGestureRecognizer]) {
        for recognizer in view.gestureRecognizers where recognizer.isEnabled {
            recognizer.isEnabled = false
            disabled.append(recognizer)
        }
        for subview in view.subviews where subview !== contentView {
            disableTitlebarRecognizers(in: subview, collecting: &disabled)
        }
    }
}

/// Marks a region inside a custom title bar (such as a toolbar button group) as interactive so rapid
/// clicks, clicks on gaps between buttons, or clicks on freshly disabled buttons never bubble up to
/// AppKit's title-bar drag or double-click-to-zoom gestures.
struct TitlebarClickGuard: NSViewRepresentable {
    final class GuardView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            (window as? TitlebarWindow)?.unregisterInteractionGuard(self)
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? TitlebarWindow)?.registerInteractionGuard(self)
        }

        override func mouseDown(with event: NSEvent) {
            // Absorb stray clicks inside the guarded toolbar strip instead of bubbling up to
            // NSThemeFrame or an underlying WindowDragArea.
        }
    }

    func makeNSView(context: Context) -> GuardView { GuardView() }
    func updateNSView(_ view: GuardView, context: Context) {}
}

extension View {
    /// Protects interactive controls inside a title-bar / `WindowDragArea` from accidental
    /// window drags or double-click zoom.
    func titlebarClickGuard(horizontalOutset: CGFloat = 0) -> some View {
        background {
            TitlebarClickGuard()
                .padding(.horizontal, -horizontalOutset)
        }
    }
}

/// Lets a custom header act like a title bar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            if let window = window as? TitlebarWindow,
               window.shouldBlockTitlebarAction(at: event.locationInWindow, clickCount: event.clickCount) {
                return
            }
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}
}

/// Field editor for `SearchField` that notifies immediately when IME composition
/// marks, unmarks, or inserts text — including `unmarkText()` commits that do not
/// trigger `controlTextDidChange`.
final class SearchFieldEditor: NSTextView {
    var onMarkedTextChanged: (() -> Void)?

    override func unmarkText() {
        super.unmarkText()
        onMarkedTextChanged?()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onMarkedTextChanged?()
    }
}

/// `NSTextField` subclass that owns the dedicated `SearchFieldEditor` so `SearchFieldCell`
/// holds zero stored properties (protecting against `NSCell.copy(with:)` / `NSCopyObject` ARC corruption).
private final class SearchTextField: NSTextField {
    let customEditor: SearchFieldEditor = {
        let view = SearchFieldEditor()
        view.isFieldEditor = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        return view
    }()
}

/// Custom cell supplying the owning `SearchTextField`'s dedicated `SearchFieldEditor`.
/// IMPORTANT: Keep ZERO stored properties on `NSCell` subclasses — AppKit's `NSCopyObject`
/// bitwise-copies ivars without retaining Swift references.
private final class SearchFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? SearchTextField)?.customEditor
    }
}

/// A single-line text field that reports arrow keys, Return and Escape, so a result list
/// can be driven from the keyboard while the field keeps focus.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont = .systemFont(ofSize: 15)
    var focusToken: Int
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    var onCancel: () -> Void = {}
    var onTab: ((Bool) -> Void)?

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField
        var lastToken = Int.min
        /// Last text value synced between the AppKit field and the SwiftUI binding.
        /// Used to distinguish genuine programmatic changes from stale SwiftUI re-renders.
        var lastSyncedText: String?
        private weak var observedField: NSTextField?
        private weak var observedEditor: NSTextView?

        init(_ parent: SearchField) { self.parent = parent }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        private func observeEditor(_ editor: NSTextView?, for field: NSTextField) {
            observedField = field
            guard editor !== observedEditor else { return }
            if let previous = observedEditor {
                NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: previous)
            }
            observedEditor = editor
            if let editor {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(editorSelectionDidChange(_:)),
                    name: NSTextView.didChangeSelectionNotification,
                    object: editor
                )
            }
        }

        private func stopObservingEditor() {
            if let previous = observedEditor {
                NotificationCenter.default.removeObserver(self, name: NSTextView.didChangeSelectionNotification, object: previous)
            }
            observedEditor = nil
            observedField = nil
        }

        /// Pushes the field's live text into `parent.text` when no IME composition is active.
        @discardableResult
        func syncFromField(_ field: NSTextField) -> Bool {
            // Letters an input method is still composing (pinyin before a candidate is picked) are not the text yet.
            if SearchField.isComposing(field) { return false }
            let value = SearchField.liveText(field)
            lastSyncedText = value
            if parent.text != value {
                parent.text = value
                return true
            }
            return false
        }

        @objc private func editorSelectionDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView,
                  editor === observedEditor,
                  let field = observedField,
                  field.currentEditor() === editor else { return }
            syncFromField(field)
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let editor = (notification.userInfo?["NSFieldEditor"] as? NSTextView) ?? (field.currentEditor() as? NSTextView)
            observeEditor(editor, for: field)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if let editor = field.currentEditor() as? NSTextView {
                observeEditor(editor, for: field)
            }
            syncFromField(field)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                syncFromField(field)
            }
            stopObservingEditor()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let syncBeforeAction = {
                if let field = control as? NSTextField { self.syncFromField(field) }
            }
            switch selector {
            case #selector(NSResponder.moveUp(_:)):
                syncBeforeAction()
                parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)):
                syncBeforeAction()
                parent.onMove(1)
            case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)):
                syncBeforeAction()
                parent.onMove(-10)
            case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)):
                syncBeforeAction()
                parent.onMove(10)
            case #selector(NSResponder.insertNewline(_:)):
                syncBeforeAction()
                parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
            case #selector(NSResponder.insertTab(_:)):
                guard let onTab = parent.onTab else { return false }
                syncBeforeAction()
                onTab(false)
            case #selector(NSResponder.insertBacktab(_:)):
                guard let onTab = parent.onTab else { return false }
                syncBeforeAction()
                onTab(true)
            default: return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func makeConfiguredTextField(placeholder: String, font: NSFont, coordinator: Coordinator) -> NSTextField {
        let field = SearchTextField()
        let defaultTextColor = field.textColor
        let cell = SearchFieldCell()
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.isScrollable = true
        cell.lineBreakMode = .byTruncatingTail
        field.customEditor.onMarkedTextChanged = { [weak coordinator, weak field] in
            guard let coordinator, let field else { return }
            coordinator.syncFromField(field)
        }
        field.cell = cell
        field.textColor = defaultTextColor
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.placeholderString = placeholder
        field.delegate = coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func makeNSView(context: Context) -> NSTextField {
        Self.makeConfiguredTextField(placeholder: placeholder, font: font, coordinator: context.coordinator)
    }

    /// Whether an input method is composing in the field: its value then holds letters that are not the text yet.
    static func isComposing(_ field: NSTextField) -> Bool {
        (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
    }

    /// The live text shown in the field, reading directly from the active field editor when focused.
    static func liveText(_ field: NSTextField) -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    /// Applies `text` from SwiftUI into `field` without clobbering active IME composition or
    /// in-flight user edits, while still honoring genuine programmatic resets.
    static func applyBindingText(_ text: String, to field: NSTextField, coordinator: Coordinator) {
        // Never while composing: setting the value then ended the composition and left its letters in the field
        // (typing 你 started a search, and its results redrew the field halfway through the next word's pinyin).
        guard !isComposing(field) else { return }
        let isEditing = field.currentEditor() != nil
        let programmaticChange = coordinator.lastSyncedText != text
        if (!isEditing || programmaticChange) && liveText(field) != text {
            field.stringValue = text
            coordinator.lastSyncedText = text
        } else if coordinator.lastSyncedText == nil {
            coordinator.lastSyncedText = text
        }
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if let searchField = field as? SearchTextField {
            searchField.customEditor.onMarkedTextChanged = { [weak coordinator = context.coordinator, weak field] in
                guard let coordinator, let field else { return }
                coordinator.syncFromField(field)
            }
        }
        Self.applyBindingText(text, to: field, coordinator: context.coordinator)
        if !Self.isComposing(field) {
            if field.placeholderString != placeholder { field.placeholderString = placeholder }
            if field.font != font { field.font = font }
        }
        if context.coordinator.lastToken != focusToken {
            context.coordinator.lastToken = focusToken
            DispatchQueue.main.async {
                guard let window = field.window else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
    }
}

/// Holds the AppKit view that owns keyboard focus for a custom list.
@MainActor
final class ListFocus {
    weak var view: NSView?
    func take() {
        guard let view, let window = view.window else { return }
        if window.firstResponder !== view { window.makeFirstResponder(view) }
    }
}

/// An invisible first responder that turns key presses into a closure call.
/// AppKit focus is used instead of SwiftUI's so the lists and the canvas share one focus model.
struct KeyCatcher: NSViewRepresentable {
    var focus: ListFocus
    var focusToken: Int
    /// Tells the lists apart when asking which of them has the keyboard.
    var name = KeyboardListName.list
    var onKey: (NSEvent) -> Bool
    var onFocusChange: (Bool) -> Void
    /// ⌘A, for lists that can select several rows. Nil leaves Select All disabled.
    var onSelectAll: (() -> Void)?

    /// The newest focus request. A list that is only now being created (its tab was just shown)
    /// has no earlier token to compare with, so it checks here whether the request was meant for it.
    static var pending: (token: Int, time: CFTimeInterval) = (Int.min, 0)

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?
        var onSelectAll: (() -> Void)? { didSet { handlesSelectAll = onSelectAll != nil } }
        /// For `responds(to:)`, which is not tied to the main thread.
        nonisolated(unsafe) private var handlesSelectAll = false
        var lastToken = Int.min

        override var acceptsFirstResponder: Bool { true }
        override func selectAll(_ sender: Any?) { onSelectAll?() }
        override func responds(to selector: Selector!) -> Bool {
            if selector == #selector(selectAll(_:)) { return handlesSelectAll }
            return super.responds(to: selector)
        }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
        override func becomeFirstResponder() -> Bool { onFocusChange?(true); return true }
        override func resignFirstResponder() -> Bool { onFocusChange?(false); return true }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.identifier = NSUserInterfaceItemIdentifier(name)
        focus.view = view
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        focus.view = view
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        view.onSelectAll = onSelectAll
        if view.lastToken != focusToken {
            let first = view.lastToken == Int.min
            view.lastToken = focusToken
            let requested = Self.pending.token == focusToken && CACurrentMediaTime() - Self.pending.time < 1
            if !first || requested {
                DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
            }
        }
    }
}

// MARK: - Keyboard-driven list

enum KeyboardListName {
    static let list = "list"
    static let tree = "tree"
}

/// Which rows a click or an arrow key leaves selected in a list that allows several.
enum ListSelection {
    /// The rows from `anchor` to `target`, whichever comes first. Just `target` when the anchor is gone.
    static func range(in ids: [String], from anchor: String?, to target: String) -> Set<String> {
        guard let end = ids.firstIndex(of: target) else { return [] }
        guard let anchor, let start = ids.firstIndex(of: anchor) else { return [target] }
        return Set(ids[min(start, end)...max(start, end)])
    }

    /// ⌘-click: adds the row, or takes it out again. Returns the selection and the row that becomes the main one.
    static func toggle(_ id: String, in selected: Set<String>, ids: [String]) -> (selected: Set<String>, primary: String?) {
        var selected = selected
        if selected.contains(id) {
            selected.remove(id)
            return (selected, ids.last { selected.contains($0) })
        }
        selected.insert(id)
        return (selected, id)
    }
}

/// A lazily rendered, selectable list with arrow-key navigation.
struct KeyboardList<Row: Identifiable, Content: View>: View where Row.ID == String {
    let rows: [Row]
    @Binding var selection: String?
    /// Every selected row, for lists that act on several at once (⌘-click, ⇧-click, ⇧↑↓, ⌘A).
    /// `selection` stays the main row: the one shown elsewhere and moved by the arrow keys.
    var multiSelection: Binding<Set<String>>?
    var focusToken: Int
    var name = KeyboardListName.list
    var rowHeight: CGFloat = 24
    /// Extra keys (←/→/↩/Esc …). Return true when handled.
    var onKey: (NSEvent, Row?) -> Bool = { _, _ in false }
    /// A single click, after the row has been selected.
    var onClick: (Row) -> Void = { _ in }
    var onDoubleClick: (Row) -> Void = { _ in }
    var onLastRowAppear: (() -> Void)?
    /// Bump to centre the selected row, however far away it is.
    var revealToken = 0
    /// Reports how far the list is scrolled, in points.
    var onScroll: ((CGFloat) -> Void)?
    /// Rows that can be clicked but never selected (section headers); the arrow keys step over them.
    var canSelect: ((Row) -> Bool)?
    /// A row's right-click menu, built on the click. One AppKit view over the whole list hands it out: a SwiftUI
    /// `.contextMenu` keeps some 20 KB alive for every row ever shown, which adds up in a long list.
    var menu: ((Row) -> NSMenu?)?
    /// Files a row stands for, to drag out of the window (into Finder, a mail, a chat, another app's terminal).
    /// The same AppKit view starts the drag, so the rows carry no drag gesture of their own.
    var dragURLs: ((Row) -> [URL])?
    @ViewBuilder var content: (Row, _ selected: Bool, _ focused: Bool) -> Content

    @State private var isFocused = false
    @State private var focus = ListFocus()
    /// Where a ⇧-extended selection started.
    @State private var anchor: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        let selected = row.id == selection || (multiSelection?.wrappedValue.contains(row.id) ?? false)
                        content(row, selected, isFocused)
                            .frame(height: UI.s(rowHeight))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? (isFocused ? Color.difSelection : Color.difHover) : Color.clear)
                                    .padding(.horizontal, 6)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let flags = NSApp.currentEvent?.modifierFlags ?? []
                                focus.take()
                                if let canSelect, !canSelect(row) {
                                    onClick(row)
                                    return
                                }
                                if let multi = multiSelection, flags.contains(.command) {
                                    var current = multi.wrappedValue
                                    if let selection { current.insert(selection) }
                                    let result = ListSelection.toggle(row.id, in: current, ids: rows.map(\.id))
                                    multi.wrappedValue = result.selected
                                    anchor = row.id
                                    selection = result.primary
                                    return
                                }
                                if let multi = multiSelection, flags.contains(.shift) {
                                    multi.wrappedValue = ListSelection.range(in: rows.map(\.id), from: anchor ?? selection, to: row.id)
                                    selection = row.id
                                    return
                                }
                                pick(row.id)
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onDoubleClick(row) } else { onClick(row) }
                            }
                            .id(row.id)
                            .onAppear {
                                if row.id == rows.last?.id { onLastRowAppear?() }
                            }
                    }
                }
                .overlay {
                    if menu != nil || dragURLs != nil {
                        RowMenuCatcher(rowHeight: UI.s(rowHeight),
                                       menu: menu.map { menu in { index in rows.indices.contains(index) ? menu(rows[index]) : nil } },
                                       drag: dragURLs.map { urls in { index in rows.indices.contains(index) ? urls(rows[index]) : [] } })
                    }
                }
                .padding(.vertical, 4)
                .background(alignment: .topLeading) {
                    if let onScroll { ScrollProbe(onScroll: onScroll).frame(width: 1, height: 1) }
                }
            }
            .background(KeyCatcher(focus: focus, focusToken: focusToken, name: name, onKey: { handle($0, proxy) },
                                   onFocusChange: { isFocused = $0 },
                                   onSelectAll: multiSelection.map { multi in { multi.wrappedValue = Set(rows.map(\.id)) } }))
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
                // The main row was moved from outside (another file opened, a refresh): the rest of the selection goes.
                if let multi = multiSelection, !(id.map(multi.wrappedValue.contains) ?? multi.wrappedValue.isEmpty) {
                    multi.wrappedValue = id.map { [$0] } ?? []
                    anchor = id
                }
            }
            .onChange(of: revealToken) { _, _ in
                // After this update's layout, so rows that were just revealed can be scrolled to.
                DispatchQueue.main.async {
                    if let id = selection { withAnimation(.snappy(duration: 0.22)) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    /// A plain click or arrow key: this row and nothing else.
    private func pick(_ id: String) {
        multiSelection?.wrappedValue = [id]
        anchor = id
        selection = id
    }

    private func handle(_ event: NSEvent, _ proxy: ScrollViewProxy) -> Bool {
        let index = rows.firstIndex { $0.id == selection }
        func select(_ target: Int) {
            guard !rows.isEmpty else { return }
            var position = min(rows.count - 1, max(0, target))
            if let canSelect {
                // Step past rows that cannot be selected, in the direction of travel; stay put at either end.
                var step = position >= (index ?? -1) ? 1 : -1
                // Home and End look for the first and last selectable row.
                if target <= 0 { step = 1 } else if target >= rows.count - 1 { step = -1 }
                while rows.indices.contains(position), !canSelect(rows[position]) { position += step }
                guard rows.indices.contains(position) else { return }
            }
            let id = rows[position].id
            if let multi = multiSelection, event.modifierFlags.contains(.shift) {
                multi.wrappedValue = ListSelection.range(in: rows.map(\.id), from: anchor ?? selection, to: id)
                selection = id
            } else {
                pick(id)
            }
        }
        switch event.keyCode {
        case 125: select((index ?? -1) + 1)
        case 126: select((index ?? rows.count) - 1)
        case 121: select((index ?? -1) + 12)
        case 116: select((index ?? rows.count) - 12)
        case 115: select(0)
        case 119: select(rows.count - 1)
        default: return onKey(event, index.map { rows[$0] })
        }
        return true
    }
}

/// Lies over a list of rows of one height and gives them their right-click menu, and drags their files out of the
/// window. Only a right-click (or ⌃-click) stops here; every other click, and the scroll wheel, goes through to the
/// rows. A drag is noticed on its way to them (a local event monitor, there only while the list is on screen).
private struct RowMenuCatcher: NSViewRepresentable {
    var rowHeight: CGFloat
    var menu: ((Int) -> NSMenu?)?
    var drag: ((Int) -> [URL])?

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.rowHeight = rowHeight
        view.menuForRow = menu
        view.urlsForRow = drag
    }

    final class CatcherView: NSView, NSDraggingSource {
        var rowHeight: CGFloat = 24
        var menuForRow: ((Int) -> NSMenu?)?
        var urlsForRow: ((Int) -> [URL])? {
            didSet { if (urlsForRow == nil) != (oldValue == nil) { updateMonitor() } }
        }
        /// Removed when the view leaves its window; `deinit` only covers a view freed while still in one.
        nonisolated(unsafe) private var monitor: Any?
        /// Where a press that could become a drag started, in window coordinates, and on which row.
        private var press: (point: NSPoint, row: Int)?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let wantsMenu = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return wantsMenu ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            guard rowHeight > 0, point.y >= 0 else { return nil }
            return menuForRow?(Int(point.y / rowHeight))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateMonitor()
        }

        private func updateMonitor() {
            let wanted = window != nil && urlsForRow != nil
            if wanted, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                    self?.handle(event) ?? event
                }
            } else if !wanted, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
                press = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard event.window === window, rowHeight > 0 else { return event }
            switch event.type {
            case .leftMouseDown:
                press = nil
                let point = convert(event.locationInWindow, from: nil)
                // Only a press on this list's rows, not on something lying over it (a dropdown, a dialog).
                // `hitTest` takes a point in the coordinates of the view's superview.
                guard visibleRect.contains(point), !event.modifierFlags.contains(.control),
                      let scroll = enclosingScrollView, let content = window?.contentView, let frame = content.superview,
                      let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)), hit.isDescendant(of: scroll) else { return event }
                press = (event.locationInWindow, Int(point.y / rowHeight))
                return event
            case .leftMouseDragged:
                guard let start = press else { return event }
                let location = event.locationInWindow
                guard hypot(location.x - start.point.x, location.y - start.point.y) >= 5 else { return event }
                press = nil
                let urls = urlsForRow?(start.row) ?? []
                guard !urls.isEmpty else { return event }
                beginDrag(urls, event: event, from: convert(start.point, from: nil))
                return nil
            default:
                press = nil
                return event
            }
        }

        private func beginDrag(_ urls: [URL], event: NSEvent, from point: NSPoint) {
            let items = urls.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                let size = NSSize(width: 32, height: 32)
                icon.size = size
                // Fanned out a little, so several files look like several.
                let offset = CGFloat(min(index, 4)) * 4
                item.setDraggingFrame(NSRect(x: point.x - 16 + offset, y: point.y - 16 + offset, width: size.width, height: size.height),
                                      contents: icon)
                return item
            }
            let session = beginDraggingSession(with: items, event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
            session.draggingFormation = .pile
            #if DEBUG || DIF_HOOKS
            FileHandle.standardError.write(Data("drag: began \(urls.map(\.lastPathComponent))\n".utf8))
            #endif
        }

        /// A copy outside the app (Finder never moves a file out of the repository); nothing inside it.
        nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .generic] : []
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Reports how far the scroll view around it is scrolled. Sits inside the scrolled content and
/// listens to the clip view: SwiftUI's own geometry preferences do not change while a list scrolls on macOS.
private struct ScrollProbe: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ view: ProbeView, context: Context) { view.onScroll = onScroll }

    final class ProbeView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private weak var observed: NSClipView?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attach()
        }

        private func attach() {
            let clip = window == nil ? nil : enclosingScrollView?.contentView
            guard clip !== observed else { return }
            if let observed {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observed)
            }
            observed = clip
            guard let clip else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged),
                                                   name: NSView.boundsDidChangeNotification, object: clip)
            boundsChanged()
        }

        @objc private func boundsChanged() {
            guard let observed else { return }
            onScroll?(max(0, observed.bounds.origin.y))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Small controls

struct IconButton: View {
    var symbol: String
    var help: String
    var isActive = false
    var size: CGFloat = 13
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: size, weight: .medium))
                .foregroundStyle(isActive ? Color.difAccent : Color.difText2)
                .frame(width: UI.s(26), height: UI.s(24))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? Color.difSelection : (hovering ? Color.difHover : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A keyboard shortcut rendered as key caps.
struct KeyCaps: View {
    var shortcut: String
    var size: CGFloat = 11

    var body: some View {
        if !shortcut.isEmpty {
            Text(shortcut)
                .font(.ui(size: size, weight: .medium, design: .rounded))
                .foregroundStyle(Color.difText2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difChip))
        }
    }
}

struct StatBadge: View {
    var additions: Int?
    var deletions: Int?
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 5) {
            if let additions, additions > 0 {
                Text("+\(additions)").foregroundStyle(Color.difAdded)
            }
            if let deletions, deletions > 0 {
                Text("−\(deletions)").foregroundStyle(Color.difRemoved)
            }
        }
        .font(.ui(size: size, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .fixedSize()
    }
}

/// A file-type glyph, tinted by language family.
struct FileIcon: View {
    var path: String
    var size: CGFloat = 12

    private static let table: [String: (String, UInt32)] = [
        "kt": ("k.square.fill", 0x8B6CF6), "kts": ("k.square.fill", 0x8B6CF6),
        "java": ("j.square.fill", 0xE8833A), "swift": ("swift", 0xF05138),
        "xml": ("chevron.left.forwardslash.chevron.right", 0xE0914A),
        "html": ("chevron.left.forwardslash.chevron.right", 0xE0714A),
        "json": ("curlybraces", 0xD9A520), "yaml": ("list.bullet.indent", 0xC9566B), "yml": ("list.bullet.indent", 0xC9566B),
        "gradle": ("gearshape.fill", 0x3BA99C), "properties": ("gearshape.fill", 0x8C93A1), "toml": ("gearshape.fill", 0x8C93A1),
        "md": ("text.alignleft", 0x4C9FE8), "txt": ("text.alignleft", 0x8C93A1),
        "js": ("j.square.fill", 0xE2C12E), "ts": ("t.square.fill", 0x3D8FD9), "tsx": ("t.square.fill", 0x3D8FD9), "jsx": ("j.square.fill", 0xE2C12E),
        "py": ("p.square.fill", 0x4B8BBE), "go": ("g.square.fill", 0x2AB3CF), "rs": ("r.square.fill", 0xD9773A),
        "c": ("c.square.fill", 0x5A8FD6), "h": ("h.square.fill", 0x8D6FD1), "cpp": ("c.square.fill", 0x5A8FD6), "cc": ("c.square.fill", 0x5A8FD6),
        "m": ("m.square.fill", 0x5A8FD6), "mm": ("m.square.fill", 0x5A8FD6), "dart": ("d.square.fill", 0x2CB7F6),
        "sh": ("terminal.fill", 0x6FBF73), "css": ("number", 0x4C9FE8), "scss": ("number", 0xCF649A), "sql": ("cylinder.split.1x2.fill", 0xD9A520),
        "png": ("photo.fill", 0xB46BD6), "jpg": ("photo.fill", 0xB46BD6), "jpeg": ("photo.fill", 0xB46BD6), "webp": ("photo.fill", 0xB46BD6),
        "gif": ("photo.fill", 0xB46BD6), "svg": ("photo.fill", 0xE0914A), "pdf": ("doc.richtext.fill", 0xE5534B),
        "lock": ("lock.fill", 0x8C93A1), "proto": ("p.square.fill", 0x3BA99C), "rb": ("r.square.fill", 0xCC342D), "php": ("p.square.fill", 0x7377AD),
    ]

    var body: some View {
        let ext = (path as NSString).pathExtension.lowercased()
        let entry = Self.table[ext] ?? ("doc.fill", 0x8C93A1)
        Image(systemName: entry.0)
            .font(.ui(size: size))
            .foregroundStyle(Color(NSColor(hex: entry.1)))
            .frame(width: UI.s(size + 5), height: UI.s(size + 4))
    }
}

// MARK: - Islands & Dividers

enum IslandStyle {
    static let cornerRadius: CGFloat = 10
    static let gap: CGFloat = 7
    static let outerPadding: CGFloat = 7
}

/// Frames a workspace region as a floating rounded island card with a subtle 1pt border.
struct IslandCard: ViewModifier {
    var background: Color = .difWindow
    var cornerRadius: CGFloat = IslandStyle.cornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(background)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.difIslandBorder, lineWidth: 1))
    }
}

extension View {
    /// Frames a workspace region as a floating rounded island card.
    func islandCard(background: Color = .difWindow, cornerRadius: CGFloat = IslandStyle.cornerRadius) -> some View {
        modifier(IslandCard(background: background, cornerRadius: cornerRadius))
    }
}

/// What a divider resizes: columns sit side by side and are dragged left and right, rows are dragged up and down.
enum ResizeAxis {
    case columns, rows

    var cursor: NSCursor {
        if #available(macOS 15.0, *) { return self == .columns ? .columnResize : .rowResize }
        return self == .columns ? .resizeLeftRight : .resizeUpDown
    }
}

extension View {
    /// Asks SwiftUI for the system's resize pointer over this view (macOS 15 and later).
    @ViewBuilder
    func resizePointer(_ axis: ResizeAxis) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(axis == .columns ? .columnResize : .rowResize)
        } else {
            self
        }
    }
}

/// The part of a divider that takes the mouse. It is an AppKit view on purpose: a cursor rect is the
/// pointer mechanism that holds inside a hosting view (the terminal's and the diff's I-beam rely on it too),
/// whereas SwiftUI puts the arrow back over a cursor pushed from `onHover`.
private struct GripArea: NSViewRepresentable {
    var axis: ResizeAxis
    var onHover: (Bool) -> Void
    var onDrag: (CGFloat?) -> Void
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> GripView { GripView() }

    func updateNSView(_ view: GripView, context: Context) {
        if view.axis != axis {
            view.axis = axis
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onDrag = onDrag
        view.onDoubleClick = onDoubleClick
    }

    final class GripView: NSView {
        var axis = ResizeAxis.columns
        var onHover: ((Bool) -> Void)?
        var onDrag: ((CGFloat?) -> Void)?
        var onDoubleClick: (() -> Void)?
        private var origin: NSPoint?

        override var mouseDownCanMoveWindow: Bool { false }
        /// A divider can be dragged straight away in a window that is not active yet.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: axis.cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                                           owner: self))
        }

        override func cursorUpdate(with event: NSEvent) { axis.cursor.set() }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { if origin == nil { onHover?(false) } }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            origin = event.locationInWindow
            axis.cursor.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin else { return }
            // The pointer can outrun a divider that has reached its limit; keep its shape until the button is up.
            axis.cursor.set()
            let now = event.locationInWindow
            // Measured the way layout runs: rightwards and downwards (window coordinates grow upwards).
            onDrag?(axis == .columns ? now.x - origin.x : origin.y - now.y)
        }

        override func mouseUp(with event: NSEvent) {
            guard origin != nil else { return }
            origin = nil
            onDrag?(nil)
            onHover?(bounds.contains(convert(event.locationInWindow, from: nil)))
            window?.invalidateCursorRects(for: self)
        }
    }
}

/// The divider between two panels: either a 1px hairline or an invisible island gap with a hover/drag pill.
struct DividerGrip: View {
    var axis: ResizeAxis
    var color = Color.difBorder
    var islandGap = false
    /// The drag's translation along the axis since it began, or nil once it has ended.
    var onDrag: (CGFloat?) -> Void
    /// A double-click on the divider, where it puts something back (nil: a double-click is two clicks).
    var onDoubleClick: (() -> Void)? = nil
    @State private var hovering = false
    @State private var dragging = false

    static let grabWidth: CGFloat = 9

    var body: some View {
        let lit = hovering || dragging
        let thickness = islandGap ? IslandStyle.gap : 1
        let grabSpan = max(Self.grabWidth, thickness)
        Group {
            if islandGap {
                Color.clear
                    .frame(width: axis == .columns ? thickness : nil, height: axis == .rows ? thickness : nil)
                    .overlay {
                        Capsule()
                            .fill(dragging ? Color.difAccent.opacity(0.85) : Color.difText3.opacity(0.55))
                            .frame(width: axis == .columns ? 3 : 36, height: axis == .rows ? 3 : 36)
                            .opacity(lit ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: lit)
                            .allowsHitTesting(false)
                    }
            } else {
                Rectangle()
                    .fill(color)
                    .frame(width: axis == .columns ? 1 : nil, height: axis == .rows ? 1 : nil)
                    .overlay(
                        Rectangle()
                            .fill(lit ? Color.difAccent.opacity(0.6) : Color.clear)
                            .frame(width: axis == .columns ? 3 : nil, height: axis == .rows ? 3 : nil)
                            .allowsHitTesting(false)
                    )
            }
        }
        .overlay(
            GripArea(axis: axis, onHover: { hovering = $0 }, onDrag: { translation in
                dragging = translation != nil
                onDrag(translation)
            }, onDoubleClick: onDoubleClick)
            .frame(width: axis == .columns ? grabSpan : nil, height: axis == .rows ? grabSpan : nil)
            .resizePointer(axis)
        )
        .zIndex(1)
    }
}

/// A draggable divider that sets the width of the panel on its left.
struct ResizeHandle: View {
    @Binding var width: Double
    var range: ClosedRange<Double>
    var islandGap = false
    var onEnd: () -> Void = {}
    @State private var startWidth: Double?

    var body: some View {
        DividerGrip(axis: .columns, islandGap: islandGap) { translation in
            guard let translation else {
                startWidth = nil
                onEnd()
                return
            }
            let base = startWidth ?? width
            if startWidth == nil { startWidth = width }
            width = min(range.upperBound, max(range.lowerBound, base + translation))
        }
    }
}

/// A draggable divider that sets the height of the panel below it.
struct HorizontalResizeHandle: View {
    @Binding var height: Double
    var range: ClosedRange<Double>
    var islandGap = false
    var onEnd: () -> Void = {}
    @State private var startHeight: Double?

    var body: some View {
        DividerGrip(axis: .rows, color: .difHairline, islandGap: islandGap) { translation in
            guard let translation else {
                startHeight = nil
                onEnd()
                return
            }
            let base = startHeight ?? height
            if startHeight == nil { startHeight = height }
            height = min(range.upperBound, max(range.lowerBound, base - translation))
        }
    }
}

/// Section caption used above lists.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(size: 10.5, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Color.difText3)
    }
}

extension View {
    /// The floating-panel look shared by every popup.
    func popupPanel(cornerRadius: CGFloat = 14) -> some View {
        self
            .background(VisualEffect(material: .popover, blending: .withinWindow))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.difHairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 30, y: 14)
    }
}
