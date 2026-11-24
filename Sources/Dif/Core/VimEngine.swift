import AppKit
import Carbon
import Foundation

// MARK: - Input Source Control (keep-english-in-normal-and-restore-in-insert)

/// Controls switching the macOS keyboard input source on Insert <-> Normal transitions.
protocol VimInputSourceControlling: AnyObject {
    func switchToEnglishAndRememberCurrent()
    func restoreRememberedInputSource()
}

extension VimInputSourceControlling {
    func switchToEnglishIfNotEnglish() {}
}

/// No-op input source controller used in unit tests so tests never mutate system keyboard layout.
final class NoOpVimInputSourceController: VimInputSourceControlling {
    func switchToEnglishAndRememberCurrent() {}
    func restoreRememberedInputSource() {}
}

/// Switches to `com.apple.keylayout.ABC` on Insert -> Normal and restores the remembered input source on Normal -> Insert.
/// Automatically becomes a no-op when running under XCTest.
final class CarbonVimInputSourceController: VimInputSourceControlling {
    private let englishID: String
    private let isTestEnvironment: Bool
    private var rememberedSourceID: String?

    init(englishID: String = "com.apple.keylayout.ABC") {
        self.englishID = englishID
        self.isTestEnvironment = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func switchToEnglishAndRememberCurrent() {
        guard !isTestEnvironment, Thread.isMainThread else { return }
        guard let currentID = currentInputSourceID() else { return }
        if currentID == englishID {
            rememberedSourceID = nil
            return
        }
        rememberedSourceID = currentID
        selectInputSource(id: englishID)
    }

    func switchToEnglishIfNotEnglish() {
        guard !isTestEnvironment, Thread.isMainThread else { return }
        guard let currentID = currentInputSourceID(), currentID != englishID else { return }
        selectInputSource(id: englishID)
    }

    func restoreRememberedInputSource() {
        guard !isTestEnvironment, Thread.isMainThread else { return }
        guard let previous = rememberedSourceID else { return }
        rememberedSourceID = nil
        selectInputSource(id: previous)
    }

    private func currentInputSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let cfString = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue()
        return cfString as String
    }

    private func selectInputSource(id: String) {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let target = list.first else {
            return
        }
        TISSelectInputSource(target)
    }
}

// MARK: - Core Types

/// Vim modal state.
enum VimMode: Equatable, Sendable {
    case normal
    case insert
    case visual
    case visualLine
    case visualBlock
    case commandLine(prefix: String, buffer: String)

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }

    var isInsert: Bool {
        if case .insert = self { return true }
        return false
    }

    var isVisual: Bool {
        switch self {
        case .visual, .visualLine, .visualBlock: return true
        default: return false
        }
    }

    var isVisualLine: Bool {
        if case .visualLine = self { return true }
        return false
    }

    var isVisualBlock: Bool {
        if case .visualBlock = self { return true }
        return false
    }

    var isCommandLine: Bool {
        if case .commandLine = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .normal: return "NORMAL"
        case .insert: return "INSERT"
        case .visual: return "VISUAL"
        case .visualLine: return "V-LINE"
        case .visualBlock: return "V-BLOCK"
        case .commandLine: return "COMMAND"
        }
    }
}

/// Snapshot of Vim UI state pushed to the status bar.
struct VimUIState: Equatable, Sendable {
    var mode: VimMode = .normal
    var pendingKeys: String = ""
    var cursorLine: Int = 1   // 1-based
    var cursorColumn: Int = 1 // 1-based
    var isReplacePending: Bool = false
}

/// Normalized keyboard input consumed by `VimEngine`.
struct VimKey: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case character(String)
        case escape
        case enter
        case backspace
        case tab
        case arrowUp
        case arrowDown
        case arrowLeft
        case arrowRight
        case pageUp
        case pageDown
        case home
        case end
    }

    var kind: Kind
    var control: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var command: Bool = false

    init(_ kind: Kind, control: Bool = false, shift: Bool = false, option: Bool = false, command: Bool = false) {
        self.kind = kind
        self.control = control
        self.shift = shift
        self.option = option
        self.command = command
    }

    init(_ char: String, control: Bool = false, shift: Bool = false, option: Bool = false, command: Bool = false) {
        self.kind = .character(char)
        self.control = control
        self.shift = shift
        self.option = option
        self.command = command
    }

    static let escape = VimKey(.escape)
    static let enter = VimKey(.enter)
    static let backspace = VimKey(.backspace)
    static let tab = VimKey(.tab)

    static func ctrl(_ char: String) -> VimKey {
        VimKey(.character(char.lowercased()), control: true)
    }

    /// Converts an AppKit `NSEvent` into a `VimKey`, returning `nil` for non-Vim function keys or `⌘`-shortcuts.
    static func from(event: NSEvent) -> VimKey? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Never intercept ⌘-modified shortcuts — AppKit menus & GoLand keymap handle them.
        if flags.contains(.command) { return nil }

        let ctrl = flags.contains(.control)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)

        switch event.keyCode {
        case 53: return VimKey(.escape, control: ctrl, shift: shift, option: opt)
        case 36, 76: return VimKey(.enter, control: ctrl, shift: shift, option: opt)
        case 51: return VimKey(.backspace, control: ctrl, shift: shift, option: opt)
        case 48: return VimKey(.tab, control: ctrl, shift: shift, option: opt)
        case 126: return VimKey(.arrowUp, control: ctrl, shift: shift, option: opt)
        case 125: return VimKey(.arrowDown, control: ctrl, shift: shift, option: opt)
        case 123: return VimKey(.arrowLeft, control: ctrl, shift: shift, option: opt)
        case 124: return VimKey(.arrowRight, control: ctrl, shift: shift, option: opt)
        case 116: return VimKey(.pageUp, control: ctrl, shift: shift, option: opt)
        case 121: return VimKey(.pageDown, control: ctrl, shift: shift, option: opt)
        case 115: return VimKey(.home, control: ctrl, shift: shift, option: opt)
        case 119: return VimKey(.end, control: ctrl, shift: shift, option: opt)
        // Function keys F1-F12: never swallow (e.g. F7 / ⇧F7 diff navigation).
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111:
            return nil
        default:
            break
        }

        if ctrl {
            // Control chords use charactersIgnoringModifiers so Ctrl+D gives "d", Ctrl+[ gives "[".
            guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return nil }
            let ch = String(raw.prefix(1))
            if let scalar = ch.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return nil }
            return VimKey(.character(ch.lowercased()), control: true, shift: shift, option: opt)
        }

        guard let chars = event.characters, !chars.isEmpty else { return nil }
        if let scalar = chars.unicodeScalars.first, (0xF700...0xF8FF).contains(scalar.value) { return nil }
        return VimKey(.character(chars), control: false, shift: shift, option: opt)
    }
}

/// High-level IDE / viewer actions dispatched by `VimEngine`.
enum VimAction: Equatable, Sendable {
    // ~/.ideavimrc navigation & IDE actions
    case goToDefinition         // gd
    case goToTypeDefinition     // gy
    case goToImplementation     // gi, gu
    case findReferences         // gr, <Space>r
    case goToFile               // <C-p>
    case goToSymbol             // gs
    case searchEverywhere       // <Space>a
    case findAction             // ga
    case gitPull                // gl
    case gitPush                // gp
    case toggleGitGraph         // gb
    case toggleMaximizeViewer   // <Space>o
    case locateInTree           // <Space>e
    case toggleFileTree         // <C-e>
    case navigateBack           // <C-o>
    case navigateForward        // <C-i>
    case focusLeftPane          // <C-h>
    case focusRightPane         // <C-l>

    // Search & Find
    case openFind               // /
    case searchWord(forward: Bool) // *, #
    case nextSearchMatch(forward: Bool, center: Bool) // n (nzz), N (Nzz)
    case clearSearchHighlights  // :noh

    // Command-line & file actions
    case save                   // :w
    case quit                   // :q
    case jumpToLine(Int)        // :<number> (1-based)

    // Viewport scrolling
    case scrollCenter           // zz
    case scrollTop              // zt
    case scrollBottom           // zb
    case scrollHalfPage(down: Bool) // <C-d>, <C-u>
    case scrollFullPage(down: Bool) // <C-f>, <C-b>

    // Undo / redo
    case undo                   // u
    case redo                   // <C-r>

    // Read-only feedback
    case readOnlyNotice
}

/// One text replacement emitted by `VimEngine`.
struct VimTextEdit: Equatable, Sendable {
    var from: TextPosition
    var to: TextPosition
    var text: String
}

/// Visual selection snapshot in right-buffer coordinates.
struct VimVisualRange: Equatable, Sendable {
    var anchor: TextPosition
    var head: TextPosition
    var linewise: Bool
    var blockwise: Bool = false
    var blockStartColumn: Int = 0
    var blockEndColumn: Int = 0
    var blockExtendToEnd: Bool = false
}

/// Register storage (unnamed register synced with system clipboard).
struct VimRegister: Equatable, Sendable {
    var text: String
    var linewise: Bool
    var blockwise: Bool = false
}

/// Context passed into `VimEngine.handleKey(_:context:)`.
struct VimContext {
    var lines: [String]
    var cursor: TextPosition
    var isEditable: Bool
    var indentUnit: String = "    "
    var commentPrefix: String = "//"
    var visibleLineCount: Int = 30
}

/// Output produced by handling one key in `VimEngine`.
struct VimResult: Equatable, Sendable {
    var handled: Bool = true
    var passThroughToInsert: Bool = false
    var edits: [VimTextEdit] = []
    var cursor: TextPosition?
    var visualRange: VimVisualRange?
    var clearVisual: Bool = false
    var actions: [VimAction] = []
    var enteredInsert: Bool = false
    var exitedInsert: Bool = false
    /// Origin cursor position to record onto the Vim jump list before applying this jump motion.
    var jumpOrigin: TextPosition? = nil

    static let ignored = VimResult(handled: false)
    static let passThrough = VimResult(handled: false, passThroughToInsert: true)
}

// MARK: - VimEngine

/// Pure Vim modal state machine tailored to the user's `~/.ideavimrc`.
/// Operates on 0-based lines and UTF-16 columns (matching `CodeCanvasView` and `TextEditing`).
final class VimEngine {
    enum Operator: Equatable {
        case delete
        case change
        case yank
        case indent
        case outdent
        case comment
    }

    private enum PendingPrefix: Equatable {
        case none
        case g
        case z
        case space
        case openBracket
        case closeBracket
        case findChar(forward: Bool, till: Bool)
        case replaceChar
        case textObject(inner: Bool)
        case visualSurround
    }

    private enum MotionKind {
        case charExclusive
        case charInclusive
        case linewise
    }

    private struct MotionOutcome {
        var target: TextPosition
        var kind: MotionKind
    }

    private enum ReplayMotion: Equatable {
        case left, right, up, down
        case wordForward, WORDForward, wordBack, WORDBack, wordEnd, WORDEnd
        case lineStart, firstNonBlank, lineEnd
        case docStart, docEnd, matchBracket
        case findChar(char: String, forward: Bool, till: Bool)
        case enclosing(open: Bool, curly: Bool)
        case method(next: Bool)
    }

    private enum InsertEntryKind: Equatable {
        case i, I, a, A, o, O
    }

    private enum DotCommand: Equatable {
        case deleteMotion(count: Int, motion: ReplayMotion)
        case deleteTextObject(inner: Bool, char: String)
        case deleteLines(count: Int)
        case deleteToEnd(count: Int)
        case deleteChars(count: Int, backward: Bool)
        case changeMotion(count: Int, motion: ReplayMotion, inserted: String)
        case changeTextObject(inner: Bool, char: String, inserted: String)
        case changeLines(count: Int, inserted: String)
        case changeToEnd(count: Int, inserted: String)
        case changeChars(count: Int, inserted: String)
        case insert(kind: InsertEntryKind, inserted: String)
        case replaceChar(count: Int, char: String)
        case put(after: Bool, count: Int)
        case joinLines(count: Int)
        case toggleCase(count: Int)
        case indentLines(count: Int, outdent: Bool)
        case commentLines(count: Int)
    }

    private struct ActiveInsertRecording {
        var buildDot: (String) -> DotCommand
        var inserted: String = ""
    }

    private struct BlockInsertSession {
        var topRow: Int
        var bottomRow: Int
        var anchorEditRow: Int
        var insertColumn: Int
        var appendToEOL: Bool
        var padShortLines: Bool
        var initialPrefix: String
        var initialSuffix: String
    }

    private struct SelectionFrame: Equatable {
        var anchor: TextPosition
        var head: TextPosition
        var wasNormal: Bool
    }

    // MARK: State

    private(set) var mode: VimMode = .normal
    private(set) var visualAnchor: TextPosition?
    private(set) var register = VimRegister(text: "", linewise: false)
    private(set) var lastFind: (char: String, forward: Bool, till: Bool)?

    private var countPrefix: String = ""
    private var operatorCountPrefix: String = ""
    private var pendingOperator: Operator?
    private var pendingPrefix: PendingPrefix = .none
    private var goalColumn: Int?
    private var visualBlockDollar: Bool = false
    private var selectionStack: [SelectionFrame] = []
    private var lastChange: DotCommand?
    private var activeInsert: ActiveInsertRecording?
    private var pendingBlockEdit: BlockInsertSession?

    private let inputSource: VimInputSourceControlling
    private let readClipboard: () -> String?
    private let writeClipboard: (String) -> Void

    init(
        inputSource: VimInputSourceControlling = CarbonVimInputSourceController(),
        readClipboard: @escaping () -> String? = { NSPasteboard.general.string(forType: .string) },
        writeClipboard: @escaping (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    ) {
        self.inputSource = inputSource
        self.readClipboard = readClipboard
        self.writeClipboard = writeClipboard
    }

    // MARK: Status bar & Cursor helpers

    var isReplaceCharPending: Bool {
        if case .replaceChar = pendingPrefix { return true }
        return false
    }

    var pendingKeysDisplay: String {
        var parts = ""
        if !operatorCountPrefix.isEmpty { parts += operatorCountPrefix }
        if let op = pendingOperator {
            switch op {
            case .delete: parts += "d"
            case .change: parts += "c"
            case .yank: parts += "y"
            case .indent: parts += ">"
            case .outdent: parts += "<"
            case .comment: parts += "gc"
            }
        }
        if !countPrefix.isEmpty { parts += countPrefix }
        switch pendingPrefix {
        case .none: break
        case .g: parts += "g"
        case .z: parts += "z"
        case .space: parts += "<Space>"
        case .openBracket: parts += "["
        case .closeBracket: parts += "]"
        case .findChar(let fwd, let till): parts += fwd ? (till ? "t" : "f") : (till ? "T" : "F")
        case .replaceChar: parts += "r"
        case .textObject(let inner): parts += inner ? "i" : "a"
        case .visualSurround: parts += "S"
        }
        return parts
    }

    func uiState(cursor: TextPosition) -> VimUIState {
        VimUIState(
            mode: mode,
            pendingKeys: pendingKeysDisplay,
            cursorLine: max(1, cursor.row + 1),
            cursorColumn: max(1, cursor.column + 1),
            isReplacePending: isReplaceCharPending
        )
    }

    /// Resets modal state (e.g. when switching documents).
    func resetToNormal(switchInputSource: Bool = false) {
        let wasInsert = mode.isInsert
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        clearPending()
        goalColumn = nil
        selectionStack.removeAll()
        activeInsert = nil
        pendingBlockEdit = nil
        if switchInputSource && wasInsert {
            inputSource.switchToEnglishAndRememberCurrent()
        }
    }

    /// Records text typed during Insert mode so `.` can replay insertions/changes.
    func recordInsertedText(_ text: String) {
        guard mode.isInsert, activeInsert != nil else { return }
        activeInsert?.inserted.append(text)
    }

    /// Records a backward delete during Insert mode for `.` replay fidelity.
    func recordInsertBackspace() {
        guard mode.isInsert, var rec = activeInsert, !rec.inserted.isEmpty else { return }
        rec.inserted.removeLast()
        activeInsert = rec
    }

    /// Programmatic expand selection (`EditorSelectWord`), e.g. from menu/shortcut or `<CR>`.
    func expandSelection(in context: VimContext) -> VimResult {
        performExpandSelection(in: context)
    }

    /// Programmatic shrink selection (`EditorUnSelectWord`), e.g. from menu/shortcut or `<BS>`.
    func shrinkSelection(in context: VimContext) -> VimResult {
        performShrinkSelection(in: context)
    }

    private func clearPending() {
        countPrefix = ""
        operatorCountPrefix = ""
        pendingOperator = nil
        pendingPrefix = .none
    }

    private func effectiveCount() -> Int {
        let opN = Int(operatorCountPrefix) ?? 1
        let mN = Int(countPrefix) ?? 1
        return max(1, min(10_000, opN * mN))
    }

    private func explicitCount() -> Int? {
        if !countPrefix.isEmpty, let n = Int(countPrefix) { return max(1, n) }
        if !operatorCountPrefix.isEmpty, let n = Int(operatorCountPrefix) { return max(1, n) }
        return nil
    }

    // MARK: Main Dispatch

    func handleKey(_ key: VimKey, context: VimContext) -> VimResult {
        switch mode {
        case .insert:
            return handleInsertKey(key, context: context)
        case .commandLine:
            return handleCommandLineKey(key, context: context)
        case .normal:
            return handleNormalKey(key, context: context)
        case .visual, .visualLine, .visualBlock:
            return handleVisualKey(key, context: context)
        }
    }

    // MARK: Insert Mode

    private func handleInsertKey(_ key: VimKey, context: VimContext) -> VimResult {
        let isExit = key.kind == .escape
            || (key.control && (key.kind == .character("[") || key.kind == .character("c")))
        guard isExit else {
            return .passThrough
        }

        mode = .normal
        clearPending()
        goalColumn = nil
        let blockSession = pendingBlockEdit
        pendingBlockEdit = nil
        let fallbackInserted = activeInsert?.inserted ?? ""
        if blockSession == nil, let rec = activeInsert {
            lastChange = rec.buildDot(rec.inserted)
        }
        activeInsert = nil
        inputSource.switchToEnglishAndRememberCurrent()

        if let session = blockSession {
            return finalizeVisualBlockInsert(session, fallbackInserted: fallbackInserted, context: context)
        }

        let clamped = clampPos(context.cursor, in: context.lines, allowPastEnd: true)
        let newCol: Int
        if clamped.column > 0 {
            newCol = prevCharCol(in: context.lines, row: clamped.row, col: clamped.column)
        } else {
            newCol = 0
        }
        return VimResult(
            handled: true,
            cursor: TextPosition(row: clamped.row, column: newCol),
            clearVisual: true,
            exitedInsert: true
        )
    }

    private func finalizeVisualBlockInsert(_ session: BlockInsertSession, fallbackInserted: String, context: VimContext) -> VimResult {
        let inserted: String
        if session.anchorEditRow >= 0 && session.anchorEditRow < context.lines.count {
            let line = context.lines[session.anchorEditRow]
            let ns = line as NSString
            let pLen = (session.initialPrefix as NSString).length
            let sLen = (session.initialSuffix as NSString).length
            if line.hasPrefix(session.initialPrefix) && line.hasSuffix(session.initialSuffix) && ns.length >= pLen + sLen {
                inserted = ns.substring(with: NSRange(location: pLen, length: ns.length - pLen - sLen))
            } else {
                inserted = fallbackInserted
            }
        } else {
            inserted = fallbackInserted
        }

        var edits: [VimTextEdit] = []
        if !inserted.isEmpty {
            for r in stride(from: session.bottomRow, through: session.topRow, by: -1) {
                guard r != session.anchorEditRow, r >= 0 && r < context.lines.count else { continue }
                let len = lineLength(context.lines, r)
                if session.appendToEOL {
                    let pos = TextPosition(row: r, column: len)
                    edits.append(VimTextEdit(from: pos, to: pos, text: inserted))
                } else if session.padShortLines {
                    if len < session.insertColumn {
                        let pad = String(repeating: " ", count: session.insertColumn - len)
                        let pos = TextPosition(row: r, column: len)
                        edits.append(VimTextEdit(from: pos, to: pos, text: pad + inserted))
                    } else {
                        let pos = TextPosition(row: r, column: session.insertColumn)
                        edits.append(VimTextEdit(from: pos, to: pos, text: inserted))
                    }
                } else if len >= session.insertColumn {
                    let pos = TextPosition(row: r, column: session.insertColumn)
                    edits.append(VimTextEdit(from: pos, to: pos, text: inserted))
                }
            }
        }

        let targetRow = max(0, min(session.topRow, context.lines.count - 1))
        let topLenBefore = lineLength(context.lines, targetRow)
        let postTopLen: Int
        if targetRow == session.anchorEditRow || inserted.isEmpty {
            postTopLen = topLenBefore
        } else if session.appendToEOL {
            postTopLen = topLenBefore + (inserted as NSString).length
        } else if session.padShortLines {
            postTopLen = max(topLenBefore, session.insertColumn) + (inserted as NSString).length
        } else if topLenBefore >= session.insertColumn {
            postTopLen = topLenBefore + (inserted as NSString).length
        } else {
            postTopLen = topLenBefore
        }
        let targetCol: Int
        if postTopLen == 0 {
            targetCol = 0
        } else if session.insertColumn >= postTopLen {
            targetCol = lastCharCol(in: context.lines, row: targetRow)
        } else {
            targetCol = session.insertColumn
        }
        return VimResult(
            handled: true,
            edits: edits,
            cursor: TextPosition(row: targetRow, column: targetCol),
            clearVisual: true,
            exitedInsert: true
        )
    }

    // MARK: Command-Line Mode

    /// Flattens multi-line clipboard text into a single-line command-line string.
    static func sanitizeCommandLinePaste(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .newlines)
        return trimmed
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    func updateCommandLineBuffer(_ text: String) {
        guard case .commandLine(let prefix, _) = mode else { return }
        mode = .commandLine(prefix: prefix, buffer: text)
    }

    @discardableResult
    func pasteIntoCommandLine(_ rawText: String) -> Bool {
        guard case .commandLine(let prefix, var buffer) = mode else { return false }
        let sanitized = Self.sanitizeCommandLinePaste(rawText)
        guard !sanitized.isEmpty else { return false }
        buffer.append(sanitized)
        mode = .commandLine(prefix: prefix, buffer: buffer)
        return true
    }

    func submitCommandLine(_ text: String? = nil, context: VimContext) -> VimResult {
        guard case .commandLine(_, let current) = mode else { return .ignored }
        let hadVisual = visualAnchor != nil
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        clearPending()
        inputSource.switchToEnglishIfNotEnglish()
        var result = executeCommandLine(text ?? current, context: context)
        if hadVisual { result.clearVisual = true }
        return result
    }

    func cancelCommandLine() -> VimResult {
        guard case .commandLine = mode else { return .ignored }
        let hadVisual = visualAnchor != nil
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        clearPending()
        inputSource.switchToEnglishIfNotEnglish()
        return VimResult(handled: true, clearVisual: hadVisual)
    }

    private func handleCommandLineKey(_ key: VimKey, context: VimContext) -> VimResult {
        guard case .commandLine(let prefix, var buffer) = mode else { return .ignored }

        if key.kind == .escape || (key.control && (key.kind == .character("[") || key.kind == .character("c"))) {
            return cancelCommandLine()
        }
        if key.control && key.kind == .character("u") {
            mode = .commandLine(prefix: prefix, buffer: "")
            return VimResult(handled: true)
        }
        if key.kind == .backspace {
            if buffer.isEmpty {
                return cancelCommandLine()
            } else {
                buffer.removeLast()
                mode = .commandLine(prefix: prefix, buffer: buffer)
            }
            return VimResult(handled: true)
        }
        if key.kind == .enter {
            return submitCommandLine(nil, context: context)
        }
        if !key.control, case .character(let s) = key.kind {
            buffer.append(s)
            mode = .commandLine(prefix: prefix, buffer: buffer)
            return VimResult(handled: true)
        }
        return VimResult(handled: true)
    }

    private func executeCommandLine(_ raw: String, context: VimContext) -> VimResult {
        let cmd = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return VimResult(handled: true) }

        // :<number> -> jump to 1-based line
        if let lineNum = Int(cmd), lineNum >= 1 {
            let maxRow = max(0, context.lines.count - 1)
            let origin = clampPos(context.cursor, in: context.lines, allowPastEnd: false)
            let targetRow = max(0, min(lineNum - 1, maxRow))
            let col = firstNonBlank(in: context.lines, row: targetRow)
            goalColumn = nil
            return VimResult(
                handled: true,
                cursor: TextPosition(row: targetRow, column: col),
                clearVisual: true,
                actions: [.jumpToLine(lineNum)],
                jumpOrigin: targetRow != origin.row ? origin : nil
            )
        }

        switch cmd {
        case "w", "write":
            return VimResult(handled: true, actions: [.save])
        case "noh", "nohl", "nohlsearch":
            return VimResult(handled: true, actions: [.clearSearchHighlights])
        case "q", "quit", "q!":
            return VimResult(handled: true, actions: [.quit])
        case "wq", "x", "wq!":
            return VimResult(handled: true, actions: [.save, .quit])
        default:
            return VimResult(handled: true)
        }
    }

    // MARK: Normal Mode

    private func handleNormalKey(_ key: VimKey, context: VimContext) -> VimResult {
        let cursor = clampPos(context.cursor, in: context.lines, allowPastEnd: false)

        // Escape / Ctrl-[ / Ctrl-c cancels any pending operator/prefix/count
        if key.kind == .escape || (key.control && (key.kind == .character("[") || key.kind == .character("c"))) {
            if pendingOperator != nil || pendingPrefix != .none || !countPrefix.isEmpty || !operatorCountPrefix.isEmpty {
                clearPending()
                return VimResult(handled: true)
            }
            selectionStack.removeAll()
            return VimResult(handled: true, clearVisual: true)
        }

        // Pending replace char (`r<char>`)
        if case .replaceChar = pendingPrefix {
            let count = effectiveCount()
            clearPending()
            guard !key.control, case .character(let ch) = key.kind, !ch.isEmpty else {
                return VimResult(handled: true)
            }
            return applyReplaceChar(ch, count: count, cursor: cursor, context: context, recordDot: true)
        }

        // Pending find char (`f`/`F`/`t`/`T`)
        if case .findChar(let forward, let till) = pendingPrefix {
            guard !key.control, case .character(let ch) = key.kind, !ch.isEmpty else {
                clearPending()
                return VimResult(handled: true)
            }
            let count = effectiveCount()
            let op = pendingOperator
            clearPending()
            lastFind = (ch, forward, till)
            let motion = ReplayMotion.findChar(char: ch, forward: forward, till: till)
            if let op {
                return applyOperator(op, motion: motion, count: count, cursor: cursor, context: context)
            }
            if let outcome = evaluateMotion(motion, count: count, from: cursor, in: context.lines, forOperator: false) {
                goalColumn = nil
                return VimResult(handled: true, cursor: outcome.target)
            }
            return VimResult(handled: true)
        }

        // Pending text object (`i`/`a` after operator)
        if case .textObject(let inner) = pendingPrefix {
            let op = pendingOperator
            clearPending()
            guard let op, !key.control, case .character(let ch) = key.kind, !ch.isEmpty else {
                return VimResult(handled: true)
            }
            return applyOperatorToTextObject(op, inner: inner, char: ch, cursor: cursor, context: context)
        }

        // Pending `g` prefix
        if case .g = pendingPrefix {
            let op = pendingOperator
            let count = explicitCount()
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                return handleGPrefix(ch, op: op, count: count, cursor: cursor, context: context)
            }
            return VimResult(handled: true)
        }

        // Pending `z` prefix
        if case .z = pendingPrefix {
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                switch ch {
                case "z": return VimResult(handled: true, actions: [.scrollCenter])
                case "t": return VimResult(handled: true, actions: [.scrollTop])
                case "b": return VimResult(handled: true, actions: [.scrollBottom])
                default: return VimResult(handled: true)
                }
            }
            return VimResult(handled: true)
        }

        // Pending `<Space>` leader prefix
        if case .space = pendingPrefix {
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                switch ch {
                case "r": return VimResult(handled: true, actions: [.findReferences])
                case "a": return VimResult(handled: true, actions: [.searchEverywhere])
                case "o": return VimResult(handled: true, actions: [.toggleMaximizeViewer])
                case "e": return VimResult(handled: true, actions: [.locateInTree])
                default: return VimResult(handled: true)
                }
            }
            return VimResult(handled: true)
        }

        // Pending `[` prefix (`[[`, `[(`, `[{`)
        if case .openBracket = pendingPrefix {
            let count = effectiveCount()
            let op = pendingOperator
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                let motion: ReplayMotion?
                switch ch {
                case "[": motion = .method(next: false)
                case "(": motion = .enclosing(open: true, curly: false)
                case "{": motion = .enclosing(open: true, curly: true)
                default: motion = nil
                }
                if let motion {
                    return runMotionOrOperator(motion, op: op, count: count, cursor: cursor, context: context)
                }
            }
            return VimResult(handled: true)
        }

        // Pending `]` prefix (`]]`, `])`, `]}`)
        if case .closeBracket = pendingPrefix {
            let count = effectiveCount()
            let op = pendingOperator
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                let motion: ReplayMotion?
                switch ch {
                case "]": motion = .method(next: true)
                case ")": motion = .enclosing(open: false, curly: false)
                case "}": motion = .enclosing(open: false, curly: true)
                default: motion = nil
                }
                if let motion {
                    return runMotionOrOperator(motion, op: op, count: count, cursor: cursor, context: context)
                }
            }
            return VimResult(handled: true)
        }

        // Control chords in Normal mode
        if key.control {
            clearPending()
            if case .character(let ch) = key.kind {
                switch ch {
                case "d": return scrollAndMoveCursor(down: true, fullPage: false, cursor: cursor, context: context)
                case "u": return scrollAndMoveCursor(down: false, fullPage: false, cursor: cursor, context: context)
                case "f": return scrollAndMoveCursor(down: true, fullPage: true, cursor: cursor, context: context)
                case "b": return scrollAndMoveCursor(down: false, fullPage: true, cursor: cursor, context: context)
                case "r":
                    guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
                    return VimResult(handled: true, actions: [.redo])
                case "o": return VimResult(handled: true, actions: [.navigateBack])
                case "i": return VimResult(handled: true, actions: [.navigateForward])
                case "p": return VimResult(handled: true, actions: [.goToFile])
                case "e": return VimResult(handled: true, actions: [.toggleFileTree])
                case "h": return VimResult(handled: true, actions: [.focusLeftPane])
                case "l": return VimResult(handled: true, actions: [.focusRightPane])
                case "v":
                    selectionStack.removeAll()
                    mode = .visualBlock
                    visualAnchor = cursor
                    visualBlockDollar = false
                    goalColumn = nil
                    return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: cursor, head: cursor))
                default: return .ignored
                }
            }
            return .ignored
        }

        // Special keys in Normal mode
        switch key.kind {
        case .enter:
            clearPending()
            return performExpandSelection(in: context)
        case .backspace:
            clearPending()
            if !selectionStack.isEmpty {
                return performShrinkSelection(in: context)
            }
            return runMotionOrOperator(.left, op: nil, count: 1, cursor: cursor, context: context)
        case .arrowLeft:
            let count = effectiveCount(); let op = pendingOperator; clearPending()
            return runMotionOrOperator(.left, op: op, count: count, cursor: cursor, context: context)
        case .arrowRight:
            let count = effectiveCount(); let op = pendingOperator; clearPending()
            return runMotionOrOperator(.right, op: op, count: count, cursor: cursor, context: context)
        case .arrowUp:
            let count = effectiveCount(); let op = pendingOperator; clearPending()
            return runMotionOrOperator(.up, op: op, count: count, cursor: cursor, context: context)
        case .arrowDown:
            let count = effectiveCount(); let op = pendingOperator; clearPending()
            return runMotionOrOperator(.down, op: op, count: count, cursor: cursor, context: context)
        case .pageDown:
            clearPending()
            return scrollAndMoveCursor(down: true, fullPage: true, cursor: cursor, context: context)
        case .pageUp:
            clearPending()
            return scrollAndMoveCursor(down: false, fullPage: true, cursor: cursor, context: context)
        case .home:
            clearPending()
            return runMotionOrOperator(.firstNonBlank, op: nil, count: 1, cursor: cursor, context: context)
        case .end:
            clearPending()
            return runMotionOrOperator(.lineEnd, op: nil, count: 1, cursor: cursor, context: context)
        case .tab:
            return .ignored
        case .escape:
            return VimResult(handled: true)
        case .character(let ch):
            return handleNormalCharacter(ch, cursor: cursor, context: context)
        }
    }

    private func handleNormalCharacter(_ ch: String, cursor: TextPosition, context: VimContext) -> VimResult {
        // Count digits
        if ch.count == 1, let c = ch.first, c >= "1" && c <= "9" {
            countPrefix.append(ch)
            return VimResult(handled: true)
        }
        if ch == "0", !countPrefix.isEmpty {
            countPrefix.append("0")
            return VimResult(handled: true)
        }

        // Operator-pending handling (doubled operators, text objects, motions)
        if let op = pendingOperator {
            // Doubled operators: dd, cc, yy, >>, <<, gcc
            if (op == .delete && ch == "d")
                || (op == .change && ch == "c")
                || (op == .yank && ch == "y")
                || (op == .indent && ch == ">")
                || (op == .outdent && ch == "<")
                || (op == .comment && ch == "c") {
                let count = effectiveCount()
                clearPending()
                return applyLinewiseOperator(op, count: count, cursor: cursor, context: context)
            }
            // Text object prefix inside operator (`di`, `da`, `ci`, `ca`, `yi`, `ya`, etc.)
            if ch == "i" || ch == "a" {
                pendingPrefix = .textObject(inner: ch == "i")
                return VimResult(handled: true)
            }
            // Prefix keys inside operator (`dg`, `d[`, `d]`, `df`, `dt`, `dF`, `dT`)
            if ch == "g" { pendingPrefix = .g; return VimResult(handled: true) }
            if ch == "[" { pendingPrefix = .openBracket; return VimResult(handled: true) }
            if ch == "]" { pendingPrefix = .closeBracket; return VimResult(handled: true) }
            if ch == "f" { pendingPrefix = .findChar(forward: true, till: false); return VimResult(handled: true) }
            if ch == "F" { pendingPrefix = .findChar(forward: false, till: false); return VimResult(handled: true) }
            if ch == "t" { pendingPrefix = .findChar(forward: true, till: true); return VimResult(handled: true) }
            if ch == "T" { pendingPrefix = .findChar(forward: false, till: true); return VimResult(handled: true) }

            let count = effectiveCount()
            clearPending()
            if let motion = simpleMotion(for: ch, hasExplicitCount: false) {
                return applyOperator(op, motion: motion, count: count, cursor: cursor, context: context)
            }
            return VimResult(handled: true)
        }

        // Normal mode without pending operator
        let count = effectiveCount()
        let explicit = explicitCount()

        switch ch {
        // Leader (Space)
        case " ":
            clearPending()
            pendingPrefix = .space
            return VimResult(handled: true)

        // Prefixes
        case "g":
            pendingPrefix = .g
            return VimResult(handled: true)
        case "z":
            clearPending()
            pendingPrefix = .z
            return VimResult(handled: true)
        case "[":
            pendingPrefix = .openBracket
            return VimResult(handled: true)
        case "]":
            pendingPrefix = .closeBracket
            return VimResult(handled: true)
        case "f":
            pendingPrefix = .findChar(forward: true, till: false)
            return VimResult(handled: true)
        case "F":
            pendingPrefix = .findChar(forward: false, till: false)
            return VimResult(handled: true)
        case "t":
            pendingPrefix = .findChar(forward: true, till: true)
            return VimResult(handled: true)
        case "T":
            pendingPrefix = .findChar(forward: false, till: true)
            return VimResult(handled: true)
        case "r":
            pendingPrefix = .replaceChar
            return VimResult(handled: true)

        // Operators
        case "d":
            beginOperator(.delete)
            return VimResult(handled: true)
        case "c":
            beginOperator(.change)
            return VimResult(handled: true)
        case "y":
            beginOperator(.yank)
            return VimResult(handled: true)
        case ">":
            beginOperator(.indent)
            return VimResult(handled: true)
        case "<":
            beginOperator(.outdent)
            return VimResult(handled: true)

        // Shorthand operators
        case "D":
            clearPending()
            return applyDeleteToEnd(count: count, cursor: cursor, context: context, enterInsert: false, recordDot: true)
        case "C":
            clearPending()
            return applyDeleteToEnd(count: count, cursor: cursor, context: context, enterInsert: true, recordDot: true)
        case "Y":
            clearPending()
            return applyLinewiseOperator(.yank, count: count, cursor: cursor, context: context)

        // Mode switches: Visual / Command-line
        case "v":
            clearPending()
            selectionStack.removeAll()
            mode = .visual
            visualAnchor = cursor
            visualBlockDollar = false
            return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: cursor, head: cursor))
        case "V":
            clearPending()
            selectionStack.removeAll()
            mode = .visualLine
            visualAnchor = cursor
            visualBlockDollar = false
            return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: cursor, head: cursor))
        case ":":
            clearPending()
            mode = .commandLine(prefix: ":", buffer: "")
            return VimResult(handled: true)

        // Insert entry
        case "i":
            clearPending()
            return enterInsertMode(kind: .i, cursor: cursor, context: context)
        case "I":
            clearPending()
            return enterInsertMode(kind: .I, cursor: cursor, context: context)
        case "a":
            clearPending()
            return enterInsertMode(kind: .a, cursor: cursor, context: context)
        case "A":
            clearPending()
            return enterInsertMode(kind: .A, cursor: cursor, context: context)
        case "o":
            clearPending()
            return enterInsertMode(kind: .o, cursor: cursor, context: context)
        case "O":
            clearPending()
            return enterInsertMode(kind: .O, cursor: cursor, context: context)
        case "s":
            clearPending()
            return applyDeleteChars(count: count, backward: false, cursor: cursor, context: context, enterInsert: true, recordDot: true)
        case "S":
            clearPending()
            return applyLinewiseOperator(.change, count: count, cursor: cursor, context: context)

        // Single-key edits
        case "x":
            clearPending()
            return applyDeleteChars(count: count, backward: false, cursor: cursor, context: context, enterInsert: false, recordDot: true)
        case "X":
            clearPending()
            return applyDeleteChars(count: count, backward: true, cursor: cursor, context: context, enterInsert: false, recordDot: true)
        case "p":
            clearPending()
            return applyPut(after: true, count: count, cursor: cursor, context: context, recordDot: true)
        case "P":
            clearPending()
            return applyPut(after: false, count: count, cursor: cursor, context: context, recordDot: true)
        case "J":
            clearPending()
            return applyJoinLines(count: count, cursor: cursor, context: context, recordDot: true)
        case "~":
            clearPending()
            return applyToggleCase(count: count, cursor: cursor, context: context, recordDot: true)
        case "u":
            clearPending()
            guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
            return VimResult(handled: true, actions: [.undo])
        case ".":
            let overrideCount = explicit
            clearPending()
            return replayLastChange(overrideCount: overrideCount, cursor: cursor, context: context)

        // Search
        case "/", "?":
            clearPending()
            return VimResult(handled: true, actions: [.openFind])
        case "*":
            clearPending()
            return VimResult(handled: true, actions: [.searchWord(forward: true)])
        case "#":
            clearPending()
            return VimResult(handled: true, actions: [.searchWord(forward: false)])
        case "n":
            clearPending()
            // nmap n nzz
            return VimResult(handled: true, actions: [.nextSearchMatch(forward: true, center: true)])
        case "N":
            clearPending()
            // nmap N Nzz
            return VimResult(handled: true, actions: [.nextSearchMatch(forward: false, center: true)])

        // Repeat f/F/t/T
        case ";":
            clearPending()
            guard let last = lastFind else { return VimResult(handled: true) }
            return runMotionOrOperator(.findChar(char: last.char, forward: last.forward, till: last.till),
                                       op: nil, count: count, cursor: cursor, context: context)
        case ",":
            clearPending()
            guard let last = lastFind else { return VimResult(handled: true) }
            return runMotionOrOperator(.findChar(char: last.char, forward: !last.forward, till: last.till),
                                       op: nil, count: count, cursor: cursor, context: context)

        // Go to line (`<N>G` or `G`)
        case "G":
            clearPending()
            let maxRow = max(0, context.lines.count - 1)
            let row = explicit.map { max(0, min($0 - 1, maxRow)) } ?? maxRow
            let col = firstNonBlank(in: context.lines, row: row)
            goalColumn = nil
            return VimResult(
                handled: true,
                cursor: TextPosition(row: row, column: col),
                jumpOrigin: row != cursor.row ? cursor : nil
            )

        default:
            clearPending()
            if let motion = simpleMotion(for: ch, hasExplicitCount: explicit != nil) {
                return runMotionOrOperator(motion, op: nil, count: count, cursor: cursor, context: context)
            }
            return VimResult(handled: true)
        }
    }

    private func beginOperator(_ op: Operator) {
        operatorCountPrefix = countPrefix
        countPrefix = ""
        pendingOperator = op
        pendingPrefix = .none
    }

    private func handleGPrefix(_ ch: String, op: Operator?, count: Int?, cursor: TextPosition, context: VimContext) -> VimResult {
        switch ch {
        case "g":
            let maxRow = max(0, context.lines.count - 1)
            let targetRow = count.map { max(0, min($0 - 1, maxRow)) } ?? 0
            if let op {
                let first = min(cursor.row, targetRow)
                let last = max(cursor.row, targetRow)
                return applyLineRangeOperator(op, firstRow: first, lastRow: last, cursor: cursor, context: context)
            }
            goalColumn = nil
            return VimResult(
                handled: true,
                cursor: TextPosition(row: targetRow, column: firstNonBlank(in: context.lines, row: targetRow)),
                jumpOrigin: targetRow != cursor.row ? cursor : nil
            )
        case "c":
            // `gc` commentary operator (waiting for `c` -> `gcc`, or motion/text object)
            if op == nil {
                beginOperator(.comment)
                return VimResult(handled: true)
            }
            return VimResult(handled: true)
        case "d":
            return VimResult(handled: true, actions: [.goToDefinition])
        case "y":
            guard op == nil else { return VimResult(handled: true) }
            return VimResult(handled: true, actions: [.goToTypeDefinition])
        case "i", "u":
            guard op == nil else { return VimResult(handled: true) }
            return VimResult(handled: true, actions: [.goToImplementation])
        case "r":
            return VimResult(handled: true, actions: [.findReferences])
        case "a":
            return VimResult(handled: true, actions: [.findAction])
        case "s":
            return VimResult(handled: true, actions: [.goToSymbol])
        case "l":
            return VimResult(handled: true, actions: [.gitPull])
        case "p":
            return VimResult(handled: true, actions: [.gitPush])
        case "b":
            return VimResult(handled: true, actions: [.toggleGitGraph])
        case "e":
            return runMotionOrOperator(.wordBack, op: op, count: count ?? 1, cursor: cursor, context: context)
        default:
            return VimResult(handled: true)
        }
    }

    // MARK: Visual Mode

    private func blockColumnBounds(anchor: TextPosition, head: TextPosition) -> (startCol: Int, endCol: Int, extendToEnd: Bool) {
        let headCol = visualBlockDollar ? head.column : (goalColumn ?? head.column)
        return (min(anchor.column, headCol), max(anchor.column, headCol), visualBlockDollar)
    }

    private func makeVisualRange(anchor: TextPosition, head: TextPosition) -> VimVisualRange {
        if mode.isVisualBlock {
            let bounds = blockColumnBounds(anchor: anchor, head: head)
            return VimVisualRange(
                anchor: anchor,
                head: head,
                linewise: false,
                blockwise: true,
                blockStartColumn: bounds.startCol,
                blockEndColumn: bounds.endCol,
                blockExtendToEnd: bounds.extendToEnd
            )
        }
        return VimVisualRange(anchor: anchor, head: head, linewise: mode.isVisualLine)
    }

    private func blockRowRange(row: Int, startCol: Int, endCol: Int, extendToEnd: Bool, lines: [String]) -> Range<Int>? {
        guard row >= 0 && row < lines.count else { return nil }
        let ns = lines[row] as NSString
        let len = ns.length
        guard len > 0, startCol < len else { return nil }
        let s = ns.rangeOfComposedCharacterSequence(at: startCol).location
        let e: Int
        if extendToEnd {
            e = len
        } else {
            let clampedEnd = min(endCol, len - 1)
            e = TextEditing.characterBoundary(in: ns, from: clampedEnd, forward: true)
        }
        guard s < e else { return nil }
        return s..<e
    }

    private func handleVisualKey(_ key: VimKey, context: VimContext) -> VimResult {
        let cursor = clampPos(context.cursor, in: context.lines, allowPastEnd: false)
        let anchor = clampPos(visualAnchor ?? cursor, in: context.lines, allowPastEnd: false)
        let isLinewise = mode.isVisualLine
        let isBlockwise = mode.isVisualBlock

        if key.kind == .escape || (key.control && (key.kind == .character("[") || key.kind == .character("c"))) {
            mode = .normal
            visualAnchor = nil
            visualBlockDollar = false
            clearPending()
            goalColumn = nil
            selectionStack.removeAll()
            return VimResult(handled: true, cursor: cursor, clearVisual: true)
        }

        // Pending `r<char>` in Visual mode
        if case .replaceChar = pendingPrefix {
            clearPending()
            guard !key.control, case .character(let ch) = key.kind, !ch.isEmpty else {
                return VimResult(handled: true)
            }
            return applyVisualReplaceChar(ch, anchor: anchor, head: cursor, context: context)
        }

        // Pending `S<char>` visual surround
        if case .visualSurround = pendingPrefix {
            clearPending()
            if !key.control, case .character(let ch) = key.kind, let pair = surroundPair(for: ch) {
                return applyVisualSurround(pair: pair, anchor: anchor, head: cursor, linewise: isLinewise, context: context)
            }
            return VimResult(handled: true)
        }

        // Pending `i`/`a` text object in visual mode (e.g. `vi"`, `vif`, `vaf`)
        if case .textObject(let inner) = pendingPrefix {
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                if let range = textObjectRange(inner: inner, char: ch, cursor: cursor, lines: context.lines) {
                    visualBlockDollar = false
                    goalColumn = nil
                    if range.linewise {
                        mode = .visualLine
                        visualAnchor = range.from
                        let head = TextPosition(row: range.to.row, column: max(0, lastCharCol(in: context.lines, row: range.to.row)))
                        return VimResult(handled: true, cursor: head, visualRange: makeVisualRange(anchor: range.from, head: head))
                    } else {
                        mode = .visual
                        let inclusiveEnd = inclusiveEndPosition(from: range.from, exclusiveEnd: range.to, in: context.lines)
                        visualAnchor = range.from
                        return VimResult(handled: true, cursor: inclusiveEnd, visualRange: makeVisualRange(anchor: range.from, head: inclusiveEnd))
                    }
                }
            }
            return VimResult(handled: true)
        }

        // Pending `g` in visual mode (`gg`, `gc`, `gd`, `gi`, `gu`, `gr`)
        if case .g = pendingPrefix {
            let explicit = explicitCount()
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                switch ch {
                case "c":
                    let first = min(anchor.row, cursor.row)
                    let last = max(anchor.row, cursor.row)
                    mode = .normal
                    visualAnchor = nil
                    visualBlockDollar = false
                    return applyToggleComment(firstRow: first, lastRow: last, context: context, recordDot: false)
                case "g":
                    let maxRow = max(0, context.lines.count - 1)
                    let row = explicit.map { max(0, min($0 - 1, maxRow)) } ?? 0
                    let target: TextPosition
                    if isBlockwise {
                        if visualBlockDollar {
                            goalColumn = nil
                            target = TextPosition(row: row, column: lastCharCol(in: context.lines, row: row))
                        } else {
                            let gCol = goalColumn ?? cursor.column
                            goalColumn = gCol
                            target = TextPosition(row: row, column: min(gCol, lastCharCol(in: context.lines, row: row)))
                        }
                    } else {
                        target = TextPosition(row: row, column: firstNonBlank(in: context.lines, row: row))
                    }
                    return VimResult(handled: true, cursor: target, visualRange: makeVisualRange(anchor: anchor, head: target))
                case "d":
                    mode = .normal; visualAnchor = nil; visualBlockDollar = false
                    return VimResult(handled: true, clearVisual: true, actions: [.goToDefinition])
                case "y":
                    mode = .normal; visualAnchor = nil; visualBlockDollar = false
                    return VimResult(handled: true, clearVisual: true, actions: [.goToTypeDefinition])
                case "i", "u":
                    mode = .normal; visualAnchor = nil; visualBlockDollar = false
                    return VimResult(handled: true, clearVisual: true, actions: [.goToImplementation])
                case "r":
                    mode = .normal; visualAnchor = nil; visualBlockDollar = false
                    return VimResult(handled: true, clearVisual: true, actions: [.findReferences])
                default:
                    return VimResult(handled: true)
                }
            }
            return VimResult(handled: true)
        }

        // Pending find char in visual mode
        if case .findChar(let forward, let till) = pendingPrefix {
            let count = effectiveCount()
            clearPending()
            if !key.control, case .character(let ch) = key.kind, !ch.isEmpty {
                lastFind = (ch, forward, till)
                if let outcome = evaluateMotion(.findChar(char: ch, forward: forward, till: till), count: count, from: cursor, in: context.lines, forOperator: false) {
                    if isBlockwise { visualBlockDollar = false }
                    return VimResult(handled: true, cursor: outcome.target, visualRange: makeVisualRange(anchor: anchor, head: outcome.target))
                }
            }
            return VimResult(handled: true)
        }

        // Pending `[` / `]` in visual mode
        if case .openBracket = pendingPrefix {
            let count = effectiveCount()
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                let motion: ReplayMotion? = ch == "[" ? .method(next: false) : (ch == "(" ? .enclosing(open: true, curly: false) : (ch == "{" ? .enclosing(open: true, curly: true) : nil))
                if let motion, let outcome = evaluateMotion(motion, count: count, from: cursor, in: context.lines, forOperator: false) {
                    if isBlockwise { visualBlockDollar = false }
                    return VimResult(handled: true, cursor: outcome.target, visualRange: makeVisualRange(anchor: anchor, head: outcome.target))
                }
            }
            return VimResult(handled: true)
        }
        if case .closeBracket = pendingPrefix {
            let count = effectiveCount()
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                let motion: ReplayMotion? = ch == "]" ? .method(next: true) : (ch == ")" ? .enclosing(open: false, curly: false) : (ch == "}" ? .enclosing(open: false, curly: true) : nil))
                if let motion, let outcome = evaluateMotion(motion, count: count, from: cursor, in: context.lines, forOperator: false) {
                    if isBlockwise { visualBlockDollar = false }
                    return VimResult(handled: true, cursor: outcome.target, visualRange: makeVisualRange(anchor: anchor, head: outcome.target))
                }
            }
            return VimResult(handled: true)
        }

        // Pending Space leader in visual mode
        if case .space = pendingPrefix {
            clearPending()
            if !key.control, case .character(let ch) = key.kind {
                switch ch {
                case "r": mode = .normal; visualAnchor = nil; visualBlockDollar = false; return VimResult(handled: true, clearVisual: true, actions: [.findReferences])
                case "a": mode = .normal; visualAnchor = nil; visualBlockDollar = false; return VimResult(handled: true, clearVisual: true, actions: [.searchEverywhere])
                case "o": mode = .normal; visualAnchor = nil; visualBlockDollar = false; return VimResult(handled: true, clearVisual: true, actions: [.toggleMaximizeViewer])
                case "e": mode = .normal; visualAnchor = nil; visualBlockDollar = false; return VimResult(handled: true, clearVisual: true, actions: [.locateInTree])
                default: return VimResult(handled: true)
                }
            }
            return VimResult(handled: true)
        }

        // Control chords in Visual mode
        if key.control {
            clearPending()
            if case .character(let ch) = key.kind {
                switch ch {
                case "d": return scrollAndMoveVisual(down: true, fullPage: false, anchor: anchor, cursor: cursor, linewise: isLinewise, context: context)
                case "u": return scrollAndMoveVisual(down: false, fullPage: false, anchor: anchor, cursor: cursor, linewise: isLinewise, context: context)
                case "f": return scrollAndMoveVisual(down: true, fullPage: true, anchor: anchor, cursor: cursor, linewise: isLinewise, context: context)
                case "b": return scrollAndMoveVisual(down: false, fullPage: true, anchor: anchor, cursor: cursor, linewise: isLinewise, context: context)
                case "e": return VimResult(handled: true, actions: [.toggleFileTree])
                case "v":
                    if isBlockwise {
                        mode = .normal
                        visualAnchor = nil
                        visualBlockDollar = false
                        goalColumn = nil
                        selectionStack.removeAll()
                        return VimResult(handled: true, cursor: cursor, clearVisual: true)
                    } else {
                        mode = .visualBlock
                        visualBlockDollar = false
                        goalColumn = nil
                        return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: anchor, head: cursor))
                    }
                default: return .ignored
                }
            }
            return .ignored
        }

        switch key.kind {
        case .enter:
            clearPending()
            return performExpandSelection(in: context)
        case .backspace:
            clearPending()
            return performShrinkSelection(in: context)
        case .arrowLeft:
            let count = effectiveCount(); clearPending()
            return moveVisual(.left, count: count, anchor: anchor, cursor: cursor, linewise: isLinewise, lines: context.lines)
        case .arrowRight:
            let count = effectiveCount(); clearPending()
            return moveVisual(.right, count: count, anchor: anchor, cursor: cursor, linewise: isLinewise, lines: context.lines)
        case .arrowUp:
            let count = effectiveCount(); clearPending()
            return moveVisual(.up, count: count, anchor: anchor, cursor: cursor, linewise: isLinewise, lines: context.lines)
        case .arrowDown:
            let count = effectiveCount(); clearPending()
            return moveVisual(.down, count: count, anchor: anchor, cursor: cursor, linewise: isLinewise, lines: context.lines)
        case .character(let ch):
            return handleVisualCharacter(ch, anchor: anchor, cursor: cursor, linewise: isLinewise, context: context)
        default:
            return VimResult(handled: true)
        }
    }

    private func handleVisualCharacter(_ ch: String, anchor: TextPosition, cursor: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        // Count digits
        if ch.count == 1, let c = ch.first, c >= "1" && c <= "9" {
            countPrefix.append(ch)
            return VimResult(handled: true)
        }
        if ch == "0", !countPrefix.isEmpty {
            countPrefix.append("0")
            return VimResult(handled: true)
        }

        let count = effectiveCount()
        let explicit = explicitCount()
        let isBlockwise = mode.isVisualBlock

        // ~/.ideavimrc:64-73 visual surround shortcuts!
        // xmap " S", xmap ' S', xmap ` S`, xmap [ S[, xmap ( S(, xmap { S{, xmap } S}, xmap ] S], xmap ) S)
        // Exclude `<` and `>` here so Visual indent (`>`) and outdent (`<`) remain reachable (`S<` / `S>` still surround).
        if let pair = surroundPair(for: ch, includeAngleBrackets: false) {
            clearPending()
            return applyVisualSurround(pair: pair, anchor: anchor, head: cursor, linewise: linewise, context: context)
        }

        switch ch {
        case "S":
            clearPending()
            pendingPrefix = .visualSurround
            return VimResult(handled: true)
        case "r":
            clearPending()
            pendingPrefix = .replaceChar
            return VimResult(handled: true)
        case "v":
            clearPending()
            visualBlockDollar = false
            if mode == .visual {
                mode = .normal
                visualAnchor = nil
                goalColumn = nil
                selectionStack.removeAll()
                return VimResult(handled: true, cursor: cursor, clearVisual: true)
            } else {
                mode = .visual
                goalColumn = nil
                return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: anchor, head: cursor))
            }
        case "V":
            clearPending()
            visualBlockDollar = false
            if mode == .visualLine {
                mode = .normal
                visualAnchor = nil
                goalColumn = nil
                selectionStack.removeAll()
                return VimResult(handled: true, cursor: cursor, clearVisual: true)
            } else {
                mode = .visualLine
                goalColumn = nil
                return VimResult(handled: true, cursor: cursor, visualRange: makeVisualRange(anchor: anchor, head: cursor))
            }
        case "o":
            clearPending()
            visualAnchor = cursor
            goalColumn = nil
            return VimResult(handled: true, cursor: anchor, visualRange: makeVisualRange(anchor: cursor, head: anchor))
        case "O":
            clearPending()
            goalColumn = nil
            if isBlockwise {
                visualBlockDollar = false
                let newAnchor = clampPos(TextPosition(row: anchor.row, column: cursor.column), in: context.lines, allowPastEnd: false)
                let newHead = clampPos(TextPosition(row: cursor.row, column: anchor.column), in: context.lines, allowPastEnd: false)
                visualAnchor = newAnchor
                return VimResult(handled: true, cursor: newHead, visualRange: makeVisualRange(anchor: newAnchor, head: newHead))
            } else {
                visualAnchor = cursor
                return VimResult(handled: true, cursor: anchor, visualRange: makeVisualRange(anchor: cursor, head: anchor))
            }
        case "I":
            clearPending()
            guard isBlockwise else { return VimResult(handled: true) }
            return applyVisualBlockInsert(append: false, anchor: anchor, head: cursor, context: context)
        case "A":
            clearPending()
            guard isBlockwise else { return VimResult(handled: true) }
            return applyVisualBlockInsert(append: true, anchor: anchor, head: cursor, context: context)
        case "i", "a":
            clearPending()
            pendingPrefix = .textObject(inner: ch == "i")
            return VimResult(handled: true)
        case " ":
            clearPending()
            pendingPrefix = .space
            return VimResult(handled: true)
        case "g":
            pendingPrefix = .g
            return VimResult(handled: true)
        case "f":
            pendingPrefix = .findChar(forward: true, till: false)
            return VimResult(handled: true)
        case "F":
            pendingPrefix = .findChar(forward: false, till: false)
            return VimResult(handled: true)
        case "t":
            pendingPrefix = .findChar(forward: true, till: true)
            return VimResult(handled: true)
        case "T":
            pendingPrefix = .findChar(forward: false, till: true)
            return VimResult(handled: true)
        case ":":
            clearPending()
            visualBlockDollar = false
            mode = .commandLine(prefix: ":", buffer: "")
            return VimResult(handled: true)

        // Operators on Visual Selection
        case "y":
            clearPending()
            return applyVisualYank(anchor: anchor, head: cursor, linewise: linewise, context: context)
        case "Y":
            clearPending()
            return applyVisualYank(anchor: anchor, head: cursor, linewise: true, context: context)
        case "d", "x":
            clearPending()
            return applyVisualDelete(anchor: anchor, head: cursor, linewise: linewise, enterInsert: false, context: context)
        case "X":
            clearPending()
            return applyVisualDelete(anchor: anchor, head: cursor, linewise: true, enterInsert: false, context: context)
        case "D":
            clearPending()
            if isBlockwise {
                return applyVisualBlockDelete(anchor: anchor, head: cursor, enterInsert: false, toEndOfLine: true, context: context)
            }
            return applyVisualDelete(anchor: anchor, head: cursor, linewise: true, enterInsert: false, context: context)
        case "c", "s":
            clearPending()
            return applyVisualDelete(anchor: anchor, head: cursor, linewise: linewise, enterInsert: true, context: context)
        case "C":
            clearPending()
            if isBlockwise {
                return applyVisualBlockDelete(anchor: anchor, head: cursor, enterInsert: true, toEndOfLine: true, context: context)
            }
            return applyVisualDelete(anchor: anchor, head: cursor, linewise: true, enterInsert: true, context: context)
        case ">":
            clearPending()
            if isBlockwise {
                return applyVisualBlockIndent(anchor: anchor, head: cursor, outdent: false, context: context)
            }
            mode = .normal; visualAnchor = nil; selectionStack.removeAll()
            return applyIndent(firstRow: min(anchor.row, cursor.row), lastRow: max(anchor.row, cursor.row), outdent: false, context: context, recordDot: false)
        case "<":
            clearPending()
            if isBlockwise {
                return applyVisualBlockIndent(anchor: anchor, head: cursor, outdent: true, context: context)
            }
            mode = .normal; visualAnchor = nil; selectionStack.removeAll()
            return applyIndent(firstRow: min(anchor.row, cursor.row), lastRow: max(anchor.row, cursor.row), outdent: true, context: context, recordDot: false)
        case "~":
            clearPending()
            return applyVisualToggleCase(anchor: anchor, head: cursor, linewise: linewise, context: context)
        case "p", "P":
            clearPending()
            return applyVisualPut(anchor: anchor, head: cursor, linewise: linewise, context: context)

        case ";":
            clearPending()
            guard let last = lastFind else { return VimResult(handled: true) }
            return moveVisual(.findChar(char: last.char, forward: last.forward, till: last.till),
                              count: count, anchor: anchor, cursor: cursor, linewise: linewise, lines: context.lines)
        case ",":
            clearPending()
            guard let last = lastFind else { return VimResult(handled: true) }
            return moveVisual(.findChar(char: last.char, forward: !last.forward, till: last.till),
                              count: count, anchor: anchor, cursor: cursor, linewise: linewise, lines: context.lines)
        case "G":
            clearPending()
            let maxRow = max(0, context.lines.count - 1)
            let row = explicit.map { max(0, min($0 - 1, maxRow)) } ?? maxRow
            let target: TextPosition
            if isBlockwise {
                if visualBlockDollar {
                    goalColumn = nil
                    target = TextPosition(row: row, column: lastCharCol(in: context.lines, row: row))
                } else {
                    let gCol = goalColumn ?? cursor.column
                    goalColumn = gCol
                    target = TextPosition(row: row, column: min(gCol, lastCharCol(in: context.lines, row: row)))
                }
            } else {
                target = TextPosition(row: row, column: firstNonBlank(in: context.lines, row: row))
            }
            return VimResult(handled: true, cursor: target, visualRange: makeVisualRange(anchor: anchor, head: target))

        default:
            clearPending()
            if let motion = simpleMotion(for: ch, hasExplicitCount: explicit != nil) {
                return moveVisual(motion, count: count, anchor: anchor, cursor: cursor, linewise: linewise, lines: context.lines)
            }
            return VimResult(handled: true)
        }
    }

    private func moveVisual(_ motion: ReplayMotion, count: Int, anchor: TextPosition, cursor: TextPosition, linewise: Bool, lines: [String]) -> VimResult {
        guard let outcome = evaluateMotion(motion, count: count, from: cursor, in: lines, forOperator: false) else {
            return VimResult(handled: true)
        }
        var target = outcome.target
        if mode.isVisualBlock {
            switch motion {
            case .lineEnd:
                visualBlockDollar = true
                goalColumn = nil
            case .up, .down:
                if visualBlockDollar {
                    goalColumn = nil
                    target = TextPosition(row: target.row, column: lastCharCol(in: lines, row: target.row))
                }
            default:
                visualBlockDollar = false
            }
        }
        return VimResult(
            handled: true,
            cursor: target,
            visualRange: makeVisualRange(anchor: anchor, head: target)
        )
    }

    // MARK: Simple Motions

    private func simpleMotion(for ch: String, hasExplicitCount: Bool) -> ReplayMotion? {
        switch ch {
        case "h": return .left
        case "l": return .right
        case "k": return .up
        case "j": return .down
        case "w": return .wordForward
        case "W": return .WORDForward
        case "b": return .wordBack
        case "B": return .WORDBack
        case "e": return .wordEnd
        case "E": return .WORDEnd
        case "0": return hasExplicitCount ? nil : .lineStart
        case "^": return .firstNonBlank
        case "$": return .lineEnd
        case "%": return .matchBracket
        // ~/.ideavimrc:81-84: ( -> [(, ) -> ]), { -> [{, } -> ]}
        case "(": return .enclosing(open: true, curly: false)
        case ")": return .enclosing(open: false, curly: false)
        case "{": return .enclosing(open: true, curly: true)
        case "}": return .enclosing(open: false, curly: true)
        default: return nil
        }
    }

    private func isJumpMotion(_ motion: ReplayMotion, from origin: TextPosition, to target: TextPosition) -> Bool {
        guard target.row != origin.row else { return false }
        switch motion {
        case .docStart, .docEnd, .matchBracket, .enclosing, .method:
            return true
        case .left, .right, .up, .down,
             .wordForward, .WORDForward, .wordBack, .WORDBack, .wordEnd, .WORDEnd,
             .lineStart, .firstNonBlank, .lineEnd, .findChar:
            return false
        }
    }

    private func runMotionOrOperator(_ motion: ReplayMotion, op: Operator?, count: Int, cursor: TextPosition, context: VimContext) -> VimResult {
        if let op {
            return applyOperator(op, motion: motion, count: count, cursor: cursor, context: context)
        }
        guard let outcome = evaluateMotion(motion, count: count, from: cursor, in: context.lines, forOperator: false) else {
            return VimResult(handled: true)
        }
        let jumpOrigin = isJumpMotion(motion, from: cursor, to: outcome.target) ? cursor : nil
        return VimResult(handled: true, cursor: outcome.target, jumpOrigin: jumpOrigin)
    }

    private func evaluateMotion(_ motion: ReplayMotion, count: Int, from cursor: TextPosition, in lines: [String], forOperator: Bool, isChange: Bool = false) -> MotionOutcome? {
        guard !lines.isEmpty else { return nil }
        let lastRow = lines.count - 1

        switch motion {
        case .left:
            goalColumn = nil
            var col = cursor.column
            for _ in 0..<count { col = prevCharCol(in: lines, row: cursor.row, col: col) }
            return MotionOutcome(target: TextPosition(row: cursor.row, column: col), kind: .charExclusive)

        case .right:
            goalColumn = nil
            let maxCol = forOperator ? lineLength(lines, cursor.row) : lastCharCol(in: lines, row: cursor.row)
            var col = cursor.column
            for _ in 0..<count {
                let next = nextCharCol(in: lines, row: cursor.row, col: col)
                col = min(maxCol, next)
            }
            return MotionOutcome(target: TextPosition(row: cursor.row, column: col), kind: .charExclusive)

        case .up:
            let gCol = goalColumn ?? cursor.column
            goalColumn = gCol
            let row = max(0, cursor.row - count)
            let col = min(gCol, lastCharCol(in: lines, row: row))
            return MotionOutcome(target: TextPosition(row: row, column: col), kind: .linewise)

        case .down:
            let gCol = goalColumn ?? cursor.column
            goalColumn = gCol
            let row = min(lastRow, cursor.row + count)
            let col = min(gCol, lastCharCol(in: lines, row: row))
            return MotionOutcome(target: TextPosition(row: row, column: col), kind: .linewise)

        case .lineStart:
            goalColumn = nil
            return MotionOutcome(target: TextPosition(row: cursor.row, column: 0), kind: .charExclusive)

        case .firstNonBlank:
            goalColumn = nil
            return MotionOutcome(target: TextPosition(row: cursor.row, column: firstNonBlank(in: lines, row: cursor.row)), kind: .charExclusive)

        case .lineEnd:
            goalColumn = nil
            let row = min(lastRow, cursor.row + max(0, count - 1))
            let col = forOperator ? lineLength(lines, row) : lastCharCol(in: lines, row: row)
            return MotionOutcome(target: TextPosition(row: row, column: col), kind: forOperator ? .charExclusive : .charInclusive)

        case .docStart:
            goalColumn = nil
            return MotionOutcome(target: TextPosition(row: 0, column: firstNonBlank(in: lines, row: 0)), kind: .linewise)

        case .docEnd:
            goalColumn = nil
            return MotionOutcome(target: TextPosition(row: lastRow, column: firstNonBlank(in: lines, row: lastRow)), kind: .linewise)

        case .wordForward:
            goalColumn = nil
            if isChange {
                // Classic Vim: `cw` acts like `ce` when starting on a non-whitespace character.
                let ns = lines[cursor.row] as NSString
                if cursor.column < ns.length && wordClass(ns.character(at: cursor.column), bigWord: false) != .space {
                    let target = moveWordEnd(from: cursor, count: count, bigWord: false, in: lines)
                    return MotionOutcome(target: target, kind: .charInclusive)
                }
            }
            let target = moveWordForward(from: cursor, count: count, bigWord: false, in: lines, forOperator: forOperator)
            return MotionOutcome(target: target, kind: .charExclusive)

        case .WORDForward:
            goalColumn = nil
            if isChange {
                let ns = lines[cursor.row] as NSString
                if cursor.column < ns.length && wordClass(ns.character(at: cursor.column), bigWord: true) != .space {
                    let target = moveWordEnd(from: cursor, count: count, bigWord: true, in: lines)
                    return MotionOutcome(target: target, kind: .charInclusive)
                }
            }
            let target = moveWordForward(from: cursor, count: count, bigWord: true, in: lines, forOperator: forOperator)
            return MotionOutcome(target: target, kind: .charExclusive)

        case .wordBack:
            goalColumn = nil
            let target = moveWordBack(from: cursor, count: count, bigWord: false, in: lines)
            return MotionOutcome(target: target, kind: .charExclusive)

        case .WORDBack:
            goalColumn = nil
            let target = moveWordBack(from: cursor, count: count, bigWord: true, in: lines)
            return MotionOutcome(target: target, kind: .charExclusive)

        case .wordEnd:
            goalColumn = nil
            let target = moveWordEnd(from: cursor, count: count, bigWord: false, in: lines)
            return MotionOutcome(target: target, kind: .charInclusive)

        case .WORDEnd:
            goalColumn = nil
            let target = moveWordEnd(from: cursor, count: count, bigWord: true, in: lines)
            return MotionOutcome(target: target, kind: .charInclusive)

        case .findChar(let ch, let forward, let till):
            goalColumn = nil
            guard let targetCol = findCharOnLine(lines[cursor.row], from: cursor.column, target: ch, forward: forward, till: till, count: count) else {
                return nil
            }
            return MotionOutcome(target: TextPosition(row: cursor.row, column: targetCol), kind: forward ? .charInclusive : .charExclusive)

        case .matchBracket:
            goalColumn = nil
            guard let match = findMatchingBracket(from: cursor, in: lines) else { return nil }
            return MotionOutcome(target: match, kind: .charInclusive)

        case .enclosing(let open, let curly):
            goalColumn = nil
            let openCh: unichar = curly ? 123 : 40  // '{' : '('
            let closeCh: unichar = curly ? 125 : 41 // '}' : ')'
            guard let pos = findEnclosingBracket(from: cursor, in: lines, open: openCh, close: closeCh, searchBackward: open, count: count) else {
                return nil
            }
            return MotionOutcome(target: pos, kind: .charExclusive)

        case .method(let next):
            goalColumn = nil
            let targetRow = findMethodLine(from: cursor.row, next: next, count: count, in: lines)
            return MotionOutcome(target: TextPosition(row: targetRow, column: firstNonBlank(in: lines, row: targetRow)), kind: .linewise)
        }
    }

    // MARK: Word Motion Algorithms

    private enum WordClass: Equatable { case space, word, punct }

    private func wordClass(_ c: unichar, bigWord: Bool) -> WordClass {
        if c == 32 || c == 9 { return .space }
        if bigWord { return .word }
        if (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80 {
            return .word
        }
        return .punct
    }

    private func moveWordForward(from start: TextPosition, count: Int, bigWord: Bool, in lines: [String], forOperator: Bool) -> TextPosition {
        var row = start.row
        var col = start.column
        let lastRow = lines.count - 1

        for step in 0..<count {
            let ns = lines[row] as NSString
            let len = ns.length
            if col >= len {
                if row < lastRow {
                    row += 1
                    col = firstNonBlank(in: lines, row: row)
                }
                continue
            }
            let startKind = wordClass(ns.character(at: col), bigWord: bigWord)
            if startKind != .space {
                while col < len && wordClass(ns.character(at: col), bigWord: bigWord) == startKind {
                    col += 1
                }
            }
            while col < len && wordClass(ns.character(at: col), bigWord: bigWord) == .space {
                col += 1
            }
            if col >= len {
                if forOperator && step == count - 1 {
                    return TextPosition(row: row, column: len)
                }
                if row < lastRow {
                    row += 1
                    col = firstNonBlank(in: lines, row: row)
                } else {
                    col = max(0, len - 1)
                }
            }
        }
        return TextPosition(row: row, column: min(col, forOperator ? lineLength(lines, row) : lastCharCol(in: lines, row: row)))
    }

    private func moveWordBack(from start: TextPosition, count: Int, bigWord: Bool, in lines: [String]) -> TextPosition {
        var row = start.row
        var col = start.column

        for _ in 0..<count {
            if col == 0 {
                if row == 0 { return TextPosition(row: 0, column: 0) }
                row -= 1
                let ns = lines[row] as NSString
                if ns.length == 0 {
                    col = 0
                    continue
                }
                col = ns.length
            }

            var ns = lines[row] as NSString
            // Skip whitespace backward, crossing lines if needed
            while true {
                while col > 0 && wordClass(ns.character(at: col - 1), bigWord: bigWord) == .space {
                    col -= 1
                }
                if col > 0 { break }
                if row == 0 { return TextPosition(row: 0, column: 0) }
                row -= 1
                ns = lines[row] as NSString
                if ns.length == 0 {
                    col = 0
                    break
                }
                col = ns.length
            }
            if col == 0 { continue }

            let kind = wordClass(ns.character(at: col - 1), bigWord: bigWord)
            while col > 0 && wordClass(ns.character(at: col - 1), bigWord: bigWord) == kind {
                col -= 1
            }
        }
        return TextPosition(row: row, column: col)
    }

    private func moveWordEnd(from start: TextPosition, count: Int, bigWord: Bool, in lines: [String]) -> TextPosition {
        var row = start.row
        var col = start.column
        let lastRow = lines.count - 1

        for _ in 0..<count {
            var ns = lines[row] as NSString
            if col + 1 < ns.length {
                col += 1
            } else if row < lastRow {
                row += 1
                col = 0
                ns = lines[row] as NSString
            } else {
                col = max(0, ns.length - 1)
                break
            }

            // Skip spaces across lines
            while true {
                while col < ns.length && wordClass(ns.character(at: col), bigWord: bigWord) == .space {
                    col += 1
                }
                if col < ns.length { break }
                if row < lastRow {
                    row += 1
                    col = 0
                    ns = lines[row] as NSString
                } else {
                    col = max(0, ns.length - 1)
                    break
                }
            }
            guard col < ns.length else { continue }
            let kind = wordClass(ns.character(at: col), bigWord: bigWord)
            while col + 1 < ns.length && wordClass(ns.character(at: col + 1), bigWord: bigWord) == kind {
                col += 1
            }
        }
        return TextPosition(row: row, column: min(col, lastCharCol(in: lines, row: row)))
    }

    // MARK: Character Find (`f`/`F`/`t`/`T`)

    private func findCharOnLine(_ line: String, from col: Int, target: String, forward: Bool, till: Bool, count: Int) -> Int? {
        guard let targetUnit = target.utf16.first else { return nil }
        let ns = line as NSString
        let len = ns.length
        guard len > 0 else { return nil }

        var remaining = count
        if forward {
            var i = col + 1
            if till, i < len, ns.character(at: i) == targetUnit {
                // Standard Vim: `;` after `t` skips past an immediately adjacent match.
                i += 1
            }
            while i < len {
                if ns.character(at: i) == targetUnit {
                    remaining -= 1
                    if remaining == 0 {
                        return till ? max(0, i - 1) : i
                    }
                }
                i += 1
            }
        } else {
            var i = col - 1
            if till, i >= 0, ns.character(at: i) == targetUnit {
                i -= 1
            }
            while i >= 0 {
                if ns.character(at: i) == targetUnit {
                    remaining -= 1
                    if remaining == 0 {
                        return till ? min(len - 1, i + 1) : i
                    }
                }
                i -= 1
            }
        }
        return nil
    }

    // MARK: Bracket & Enclosing Structure Helpers (`%`, `(`, `)`, `{`, `}`)

    private func findMatchingBracket(from cursor: TextPosition, in lines: [String]) -> TextPosition? {
        guard cursor.row >= 0 && cursor.row < lines.count else { return nil }
        let ns = lines[cursor.row] as NSString
        guard ns.length > 0 else { return nil }

        let pairs: [unichar: (match: unichar, forward: Bool)] = [
            40: (41, true),   // ( -> )
            41: (40, false),  // ) -> (
            91: (93, true),   // [ -> ]
            93: (91, false),  // ] -> [
            123: (125, true), // { -> }
            125: (123, false) // } -> {
        ]

        var startCol = min(cursor.column, ns.length - 1)
        if pairs[ns.character(at: startCol)] == nil {
            var scan = startCol + 1
            while scan < ns.length && pairs[ns.character(at: scan)] == nil { scan += 1 }
            guard scan < ns.length else { return nil }
            startCol = scan
        }

        let ch = ns.character(at: startCol)
        guard let info = pairs[ch] else { return nil }
        return scanMatchingPair(from: TextPosition(row: cursor.row, column: startCol),
                                open: info.forward ? ch : info.match,
                                close: info.forward ? info.match : ch,
                                forward: info.forward,
                                in: lines)
    }

    private func scanMatchingPair(from start: TextPosition, open: unichar, close: unichar, forward: Bool, in lines: [String]) -> TextPosition? {
        var depth = 0
        if forward {
            for r in start.row..<lines.count {
                let ns = lines[r] as NSString
                let startC = (r == start.row) ? start.column : 0
                for c in startC..<ns.length {
                    let u = ns.character(at: c)
                    if u == open { depth += 1 }
                    else if u == close {
                        depth -= 1
                        if depth == 0 { return TextPosition(row: r, column: c) }
                    }
                }
            }
        } else {
            for r in stride(from: start.row, through: 0, by: -1) {
                let ns = lines[r] as NSString
                let endC = (r == start.row) ? start.column : (ns.length - 1)
                guard endC >= 0 else { continue }
                for c in stride(from: endC, through: 0, by: -1) {
                    let u = ns.character(at: c)
                    if u == close { depth += 1 }
                    else if u == open {
                        depth -= 1
                        if depth == 0 { return TextPosition(row: r, column: c) }
                    }
                }
            }
        }
        return nil
    }

    private func findEnclosingBracket(from cursor: TextPosition, in lines: [String], open: unichar, close: unichar, searchBackward: Bool, count: Int) -> TextPosition? {
        var pos = cursor
        for _ in 0..<count {
            guard let found = findSingleEnclosingBracket(from: pos, in: lines, open: open, close: close, searchBackward: searchBackward) else {
                return pos == cursor ? nil : pos
            }
            pos = found
        }
        return pos
    }

    private func findSingleEnclosingBracket(from start: TextPosition, in lines: [String], open: unichar, close: unichar, searchBackward: Bool) -> TextPosition? {
        var depth = 0
        if searchBackward {
            var r = start.row
            var c = start.column - 1
            while r >= 0 {
                let ns = lines[r] as NSString
                if c >= ns.length { c = ns.length - 1 }
                while c >= 0 {
                    let u = ns.character(at: c)
                    if u == close {
                        depth += 1
                    } else if u == open {
                        if depth == 0 { return TextPosition(row: r, column: c) }
                        depth -= 1
                    }
                    c -= 1
                }
                r -= 1
                if r >= 0 { c = (lines[r] as NSString).length - 1 }
            }
        } else {
            var r = start.row
            var c = start.column + 1
            while r < lines.count {
                let ns = lines[r] as NSString
                while c < ns.length {
                    let u = ns.character(at: c)
                    if u == open {
                        depth += 1
                    } else if u == close {
                        if depth == 0 { return TextPosition(row: r, column: c) }
                        depth -= 1
                    }
                    c += 1
                }
                r += 1
                c = 0
            }
        }
        return nil
    }

    // MARK: Function / Method Detection (`[[`, `]]`, `if`, `af`)

    /// Detects whether `line` begins a function or method declaration (Go, Swift, Rust, Python, JS/TS, Kotlin, Ruby, C/Java).
    static func isFunctionDeclarationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
            return false
        }

        // Go / Swift: `func ...`, `func (r *Recv) ...`, `public static func ...`
        if trimmed.hasPrefix("func ") || trimmed.hasPrefix("func(") { return true }
        // Rust: `fn `, `pub fn `, `pub(crate) async fn `
        if trimmed.hasPrefix("fn ") { return true }
        // Python / Ruby: `def `, `async def `
        if trimmed.hasPrefix("def ") || trimmed.hasPrefix("async def ") { return true }
        // JS / TS: `function `, `async function `, `export function `
        if trimmed.hasPrefix("function ") || trimmed.hasPrefix("function(") { return true }
        // Kotlin: `fun `
        if trimmed.hasPrefix("fun ") { return true }

        // Modifier-prefixed declarations (Swift/Rust/JS/TS/Kotlin/Obj-C)
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        let modifiers: Set<Substring> = [
            "public", "private", "internal", "fileprivate", "open", "protected",
            "static", "class", "final", "override", "mutating", "nonmutating",
            "async", "unsafe", "const", "extern", "pub", "export", "default",
            "suspend", "inline", "operator", "infix", "tailrec", "nonisolated", "convenience", "required"
        ]
        var idx = 0
        while idx < tokens.count {
            let tok = tokens[idx]
            if tok.hasPrefix("@") || modifiers.contains(tok) || tok.hasPrefix("pub(") {
                idx += 1
                continue
            }
            if tok == "func" || tok == "fn" || tok == "def" || tok == "function" || tok == "fun"
                || tok.hasPrefix("func(") || tok.hasPrefix("init(") || tok.hasPrefix("init?(") || tok == "deinit" {
                return true
            }
            break
        }
        return false
    }

    private func findMethodLine(from row: Int, next: Bool, count: Int, in lines: [String]) -> Int {
        guard !lines.isEmpty else { return 0 }
        var current = row
        for _ in 0..<count {
            var found: Int?
            if next {
                if current + 1 < lines.count {
                    for r in (current + 1)..<lines.count where Self.isFunctionDeclarationLine(lines[r]) {
                        found = r
                        break
                    }
                }
                current = found ?? (lines.count - 1)
            } else {
                if current > 0 {
                    for r in stride(from: current - 1, through: 0, by: -1) where Self.isFunctionDeclarationLine(lines[r]) {
                        found = r
                        break
                    }
                }
                current = found ?? 0
            }
        }
        return current
    }

    /// Finds the enclosing function declaration line and its `{` ... `}` brace positions.
    private func enclosingFunctionBounds(from cursor: TextPosition, in lines: [String]) -> (declRow: Int, openBrace: TextPosition, closeBrace: TextPosition)? {
        guard !lines.isEmpty else { return nil }
        for r in stride(from: min(cursor.row, lines.count - 1), through: 0, by: -1) {
            guard Self.isFunctionDeclarationLine(lines[r]) else { continue }
            guard let openPos = findFunctionOpenBrace(startingAt: r, in: lines) else { continue }
            guard let closePos = scanMatchingPair(from: openPos, open: 123, close: 125, forward: true, in: lines) else { continue }
            if cursor.row >= r && cursor.row <= closePos.row {
                return (r, openPos, closePos)
            }
        }
        return nil
    }

    private func findFunctionOpenBrace(startingAt declRow: Int, in lines: [String]) -> TextPosition? {
        let limit = min(lines.count - 1, declRow + 8)
        for r in declRow...limit {
            let ns = lines[r] as NSString
            for c in 0..<ns.length {
                if ns.character(at: c) == 123 { // '{'
                    return TextPosition(row: r, column: c)
                }
            }
        }
        return nil
    }

    // MARK: Text Objects (`iw/aw`, `iW/aW`, `i"/a"`, `i(/a(`, `i[/a[`, `i{/a{`, `if/af`)

    private struct TextObjectRange {
        var from: TextPosition
        var to: TextPosition
        var linewise: Bool = false
    }

    private func textObjectRange(inner: Bool, char: String, cursor: TextPosition, lines: [String]) -> TextObjectRange? {
        guard !lines.isEmpty else { return nil }
        switch char {
        case "w":
            return wordTextObject(inner: inner, bigWord: false, cursor: cursor, lines: lines)
        case "W":
            return wordTextObject(inner: inner, bigWord: true, cursor: cursor, lines: lines)
        case "\"", "'", "`":
            return quoteTextObject(inner: inner, quote: char.utf16.first!, cursor: cursor, lines: lines)
        case "(", ")", "b":
            return pairTextObject(inner: inner, open: 40, close: 41, cursor: cursor, lines: lines)
        case "[", "]":
            return pairTextObject(inner: inner, open: 91, close: 93, cursor: cursor, lines: lines)
        case "{", "}", "B":
            return pairTextObject(inner: inner, open: 123, close: 125, cursor: cursor, lines: lines)
        case "f":
            return functionTextObject(inner: inner, cursor: cursor, lines: lines)
        default:
            return nil
        }
    }

    private func wordTextObject(inner: Bool, bigWord: Bool, cursor: TextPosition, lines: [String]) -> TextObjectRange? {
        let ns = lines[cursor.row] as NSString
        let len = ns.length
        guard len > 0 else { return nil }
        let pivot = min(cursor.column, len - 1)
        let kind = wordClass(ns.character(at: pivot), bigWord: bigWord)

        var start = pivot
        var end = pivot + 1
        while start > 0 && wordClass(ns.character(at: start - 1), bigWord: bigWord) == kind { start -= 1 }
        while end < len && wordClass(ns.character(at: end), bigWord: bigWord) == kind { end += 1 }

        if !inner {
            if kind != .space {
                var afterEnd = end
                while afterEnd < len && wordClass(ns.character(at: afterEnd), bigWord: bigWord) == .space { afterEnd += 1 }
                if afterEnd > end {
                    end = afterEnd
                } else {
                    while start > 0 && wordClass(ns.character(at: start - 1), bigWord: bigWord) == .space { start -= 1 }
                }
            }
        }
        return TextObjectRange(from: TextPosition(row: cursor.row, column: start), to: TextPosition(row: cursor.row, column: end))
    }

    private func quoteTextObject(inner: Bool, quote: unichar, cursor: TextPosition, lines: [String]) -> TextObjectRange? {
        let ns = lines[cursor.row] as NSString
        let len = ns.length
        guard len >= 2 else { return nil }

        // Collect unescaped quote positions on the current line.
        var positions: [Int] = []
        var i = 0
        while i < len {
            let u = ns.character(at: i)
            if u == 92 { // backslash escape
                i += 2
                continue
            }
            if u == quote { positions.append(i) }
            i += 1
        }
        guard positions.count >= 2 else { return nil }

        // Pair consecutive quotes: (0,1), (2,3), ...
        // Pick the pair enclosing cursor, or the next pair to the right on the same line (standard Vim!).
        var chosen: (Int, Int)?
        var idx = 0
        while idx + 1 < positions.count {
            let open = positions[idx], close = positions[idx + 1]
            if cursor.column >= open && cursor.column <= close {
                chosen = (open, close)
                break
            }
            if cursor.column < open && chosen == nil {
                chosen = (open, close)
                break
            }
            idx += 2
        }
        guard let (open, close) = chosen else { return nil }
        let fromCol = inner ? open + 1 : open
        let toCol = inner ? close : close + 1
        return TextObjectRange(from: TextPosition(row: cursor.row, column: fromCol),
                               to: TextPosition(row: cursor.row, column: toCol))
    }

    private func pairTextObject(inner: Bool, open: unichar, close: unichar, cursor: TextPosition, lines: [String]) -> TextObjectRange? {
        let ns = lines[cursor.row] as NSString
        var openPos: TextPosition?
        var closePos: TextPosition?

        if cursor.column < ns.length {
            let cur = ns.character(at: cursor.column)
            if cur == open {
                openPos = cursor
                closePos = scanMatchingPair(from: cursor, open: open, close: close, forward: true, in: lines)
            } else if cur == close {
                closePos = cursor
                openPos = scanMatchingPair(from: cursor, open: open, close: close, forward: false, in: lines)
            }
        }
        if openPos == nil || closePos == nil {
            if let o = findSingleEnclosingBracket(from: cursor, in: lines, open: open, close: close, searchBackward: true),
               let c = scanMatchingPair(from: o, open: open, close: close, forward: true, in: lines) {
                openPos = o
                closePos = c
            } else {
                // Fallback: look forward on current line for an opening delimiter (standard Vim `ci(`!)
                for col in cursor.column..<ns.length where ns.character(at: col) == open {
                    let candidate = TextPosition(row: cursor.row, column: col)
                    if let c = scanMatchingPair(from: candidate, open: open, close: close, forward: true, in: lines) {
                        openPos = candidate
                        closePos = c
                        break
                    }
                }
            }
        }
        guard let o = openPos, let c = closePos else { return nil }
        if inner {
            return innerPairRange(open: o, close: c, lines: lines)
        } else {
            return TextObjectRange(from: o, to: TextPosition(row: c.row, column: c.column + 1))
        }
    }

    private func innerPairRange(open: TextPosition, close: TextPosition, lines: [String]) -> TextObjectRange {
        if open.row < close.row {
            let openLine = lines[open.row] as NSString
            let afterOpen = openLine.substring(from: min(open.column + 1, openLine.length)).trimmingCharacters(in: .whitespaces)
            let closeLine = lines[close.row] as NSString
            let beforeClose = closeLine.substring(to: min(close.column, closeLine.length)).trimmingCharacters(in: .whitespaces)
            if afterOpen.isEmpty && beforeClose.isEmpty && open.row + 1 < close.row {
                return TextObjectRange(
                    from: TextPosition(row: open.row + 1, column: 0),
                    to: TextPosition(row: close.row - 1, column: lineLength(lines, close.row - 1)),
                    linewise: true
                )
            }
        }
        return TextObjectRange(from: TextPosition(row: open.row, column: open.column + 1), to: close)
    }

    private func functionTextObject(inner: Bool, cursor: TextPosition, lines: [String]) -> TextObjectRange? {
        guard let bounds = enclosingFunctionBounds(from: cursor, in: lines) else { return nil }
        if inner {
            return innerPairRange(open: bounds.openBrace, close: bounds.closeBrace, lines: lines)
        } else {
            return TextObjectRange(
                from: TextPosition(row: bounds.declRow, column: 0),
                to: TextPosition(row: bounds.closeBrace.row, column: bounds.closeBrace.column + 1),
                linewise: true
            )
        }
    }

    // MARK: Operators Execution

    private func applyOperator(_ op: Operator, motion: ReplayMotion, count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool = true, replayInserted: String? = nil) -> VimResult {
        if op != .yank && !context.isEditable {
            return VimResult(handled: true, actions: [.readOnlyNotice])
        }
        guard let outcome = evaluateMotion(motion, count: count, from: cursor, in: context.lines, forOperator: true, isChange: op == .change) else {
            return VimResult(handled: true)
        }

        if outcome.kind == .linewise || op == .indent || op == .outdent || op == .comment {
            let first = min(cursor.row, outcome.target.row)
            let last = max(cursor.row, outcome.target.row)
            return applyLineRangeOperator(op, firstRow: first, lastRow: last, cursor: cursor, context: context, recordDot: recordDot, replayInserted: replayInserted)
        }

        let (from, to) = orderedCharRange(start: cursor, outcome: outcome, lines: context.lines)
        guard from < to else { return VimResult(handled: true) }

        switch op {
        case .yank:
            let yanked = TextEditing.text(context.lines, from: from, to: to)
            setRegister(yanked, linewise: false)
            return VimResult(handled: true, cursor: from)
        case .delete:
            let removed = TextEditing.text(context.lines, from: from, to: to)
            setRegister(removed, linewise: false)
            if recordDot { lastChange = .deleteMotion(count: count, motion: motion) }
            let afterCol = min(from.column, max(0, remainingLineLengthAfterDelete(lines: context.lines, from: from, to: to) - 1))
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: TextPosition(row: from.row, column: afterCol))
        case .change:
            let removed = TextEditing.text(context.lines, from: from, to: to)
            setRegister(removed, linewise: false)
            if let replayInserted {
                let endCol = from.column + (replayInserted as NSString).length
                return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: replayInserted)],
                                 cursor: TextPosition(row: from.row, column: max(0, endCol - 1)))
            }
            if recordDot {
                activeInsert = ActiveInsertRecording(buildDot: { .changeMotion(count: count, motion: motion, inserted: $0) })
            }
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: from, enteredInsert: true)
        case .indent, .outdent, .comment:
            return VimResult(handled: true)
        }
    }

    private func applyOperatorToTextObject(_ op: Operator, inner: Bool, char: String, cursor: TextPosition, context: VimContext, recordDot: Bool = true, replayInserted: String? = nil) -> VimResult {
        if op != .yank && !context.isEditable {
            return VimResult(handled: true, actions: [.readOnlyNotice])
        }
        guard let range = textObjectRange(inner: inner, char: char, cursor: cursor, lines: context.lines) else {
            return VimResult(handled: true)
        }

        if range.linewise {
            let first = range.from.row
            let last = range.to.row
            switch op {
            case .yank:
                let yanked = context.lines[first...last].joined(separator: "\n") + "\n"
                setRegister(yanked, linewise: true)
                return VimResult(handled: true, cursor: TextPosition(row: first, column: firstNonBlank(in: context.lines, row: first)))
            case .delete:
                let yanked = context.lines[first...last].joined(separator: "\n") + "\n"
                setRegister(yanked, linewise: true)
                if recordDot { lastChange = .deleteTextObject(inner: inner, char: char) }
                let (delFrom, delTo) = lineDeletionRange(firstRow: first, lastRow: last, lines: context.lines)
                let nextRow = min(first, max(0, context.lines.count - (last - first + 1) - 1))
                return VimResult(handled: true, edits: [VimTextEdit(from: delFrom, to: delTo, text: "")], cursor: TextPosition(row: nextRow, column: 0))
            case .change:
                let yanked = context.lines[first...last].joined(separator: "\n") + "\n"
                setRegister(yanked, linewise: true)
                let indent = TextEditing.indentation(of: context.lines[first])
                let from = TextPosition(row: first, column: 0)
                let to = TextPosition(row: last, column: lineLength(context.lines, last))
                if let replayInserted {
                    let replacement = indent + replayInserted
                    return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: replacement)],
                                     cursor: TextPosition(row: first, column: max(0, (replacement as NSString).length - 1)))
                }
                if recordDot {
                    activeInsert = ActiveInsertRecording(buildDot: { .changeTextObject(inner: inner, char: char, inserted: $0) })
                }
                mode = .insert
                inputSource.restoreRememberedInputSource()
                return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: indent)],
                                 cursor: TextPosition(row: first, column: (indent as NSString).length), enteredInsert: true)
            case .indent:
                return applyIndent(firstRow: first, lastRow: last, outdent: false, context: context, recordDot: false)
            case .outdent:
                return applyIndent(firstRow: first, lastRow: last, outdent: true, context: context, recordDot: false)
            case .comment:
                return applyToggleComment(firstRow: first, lastRow: last, context: context, recordDot: false)
            }
        }

        let from = range.from
        let to = range.to
        switch op {
        case .yank:
            setRegister(TextEditing.text(context.lines, from: from, to: to), linewise: false)
            return VimResult(handled: true, cursor: from)
        case .delete:
            setRegister(TextEditing.text(context.lines, from: from, to: to), linewise: false)
            if recordDot { lastChange = .deleteTextObject(inner: inner, char: char) }
            let afterCol = min(from.column, max(0, remainingLineLengthAfterDelete(lines: context.lines, from: from, to: to) - 1))
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: TextPosition(row: from.row, column: afterCol))
        case .change:
            setRegister(TextEditing.text(context.lines, from: from, to: to), linewise: false)
            if let replayInserted {
                let endCol = from.column + (replayInserted as NSString).length
                return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: replayInserted)],
                                 cursor: TextPosition(row: from.row, column: max(0, endCol - 1)))
            }
            if recordDot {
                activeInsert = ActiveInsertRecording(buildDot: { .changeTextObject(inner: inner, char: char, inserted: $0) })
            }
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: from, enteredInsert: true)
        case .indent:
            return applyIndent(firstRow: from.row, lastRow: to.row, outdent: false, context: context, recordDot: false)
        case .outdent:
            return applyIndent(firstRow: from.row, lastRow: to.row, outdent: true, context: context, recordDot: false)
        case .comment:
            return applyToggleComment(firstRow: from.row, lastRow: to.row, context: context, recordDot: false)
        }
    }

    private func applyLinewiseOperator(_ op: Operator, count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool = true, replayInserted: String? = nil) -> VimResult {
        let first = cursor.row
        let last = min(max(0, context.lines.count - 1), first + count - 1)
        return applyLineRangeOperator(op, firstRow: first, lastRow: last, cursor: cursor, context: context, recordDot: recordDot, replayInserted: replayInserted)
    }

    private func applyLineRangeOperator(_ op: Operator, firstRow: Int, lastRow: Int, cursor: TextPosition, context: VimContext, recordDot: Bool = true, replayInserted: String? = nil) -> VimResult {
        guard !context.lines.isEmpty else { return VimResult(handled: true) }
        let first = max(0, min(firstRow, context.lines.count - 1))
        let last = max(first, min(lastRow, context.lines.count - 1))
        let count = last - first + 1

        if op != .yank && !context.isEditable {
            return VimResult(handled: true, actions: [.readOnlyNotice])
        }

        switch op {
        case .yank:
            let text = context.lines[first...last].joined(separator: "\n") + "\n"
            setRegister(text, linewise: true)
            return VimResult(handled: true, cursor: cursor)
        case .delete:
            let text = context.lines[first...last].joined(separator: "\n") + "\n"
            setRegister(text, linewise: true)
            if recordDot { lastChange = .deleteLines(count: count) }
            let (delFrom, delTo) = lineDeletionRange(firstRow: first, lastRow: last, lines: context.lines)
            var simLines = context.lines
            TextEditing.replace(&simLines, from: delFrom, to: delTo, with: "")
            let targetRow = min(first, max(0, simLines.count - 1))
            let targetCol = firstNonBlank(in: simLines, row: targetRow)
            goalColumn = nil
            return VimResult(handled: true, edits: [VimTextEdit(from: delFrom, to: delTo, text: "")], cursor: TextPosition(row: targetRow, column: targetCol))
        case .change:
            let text = context.lines[first...last].joined(separator: "\n") + "\n"
            setRegister(text, linewise: true)
            let indent = TextEditing.indentation(of: context.lines[first])
            let from = TextPosition(row: first, column: 0)
            let to = TextPosition(row: last, column: lineLength(context.lines, last))
            if let replayInserted {
                let replacement = indent + replayInserted
                return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: replacement)],
                                 cursor: TextPosition(row: first, column: max(0, (replacement as NSString).length - 1)))
            }
            if recordDot {
                activeInsert = ActiveInsertRecording(buildDot: { .changeLines(count: count, inserted: $0) })
            }
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: indent)],
                             cursor: TextPosition(row: first, column: (indent as NSString).length), enteredInsert: true)
        case .indent:
            return applyIndent(firstRow: first, lastRow: last, outdent: false, context: context, recordDot: recordDot)
        case .outdent:
            return applyIndent(firstRow: first, lastRow: last, outdent: true, context: context, recordDot: recordDot)
        case .comment:
            return applyToggleComment(firstRow: first, lastRow: last, context: context, recordDot: recordDot)
        }
    }

    // MARK: Insert Mode Entry (`i`, `I`, `a`, `A`, `o`, `O`)

    private func enterInsertMode(kind: InsertEntryKind, cursor: TextPosition, context: VimContext, replayInserted: String? = nil) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let lineLen = lineLength(context.lines, cursor.row)

        switch kind {
        case .i:
            if let replayInserted {
                return replaySimpleInsert(at: cursor, text: replayInserted)
            }
            beginInsertRecording(kind: .i)
            return VimResult(handled: true, cursor: cursor, clearVisual: true, enteredInsert: true)
        case .I:
            let pos = TextPosition(row: cursor.row, column: firstNonBlank(in: context.lines, row: cursor.row))
            if let replayInserted { return replaySimpleInsert(at: pos, text: replayInserted) }
            beginInsertRecording(kind: .I)
            return VimResult(handled: true, cursor: pos, clearVisual: true, enteredInsert: true)
        case .a:
            let col = lineLen == 0 ? 0 : nextCharCol(in: context.lines, row: cursor.row, col: cursor.column)
            let pos = TextPosition(row: cursor.row, column: col)
            if let replayInserted { return replaySimpleInsert(at: pos, text: replayInserted) }
            beginInsertRecording(kind: .a)
            return VimResult(handled: true, cursor: pos, clearVisual: true, enteredInsert: true)
        case .A:
            let pos = TextPosition(row: cursor.row, column: lineLen)
            if let replayInserted { return replaySimpleInsert(at: pos, text: replayInserted) }
            beginInsertRecording(kind: .A)
            return VimResult(handled: true, cursor: pos, clearVisual: true, enteredInsert: true)
        case .o:
            let indent = autoIndentForNewLineBelow(context.lines[cursor.row], indentUnit: context.indentUnit)
            let at = TextPosition(row: cursor.row, column: lineLen)
            if let replayInserted {
                let text = "\n" + indent + replayInserted
                let newCol = max(0, ((indent + replayInserted) as NSString).length - 1)
                return VimResult(handled: true, edits: [VimTextEdit(from: at, to: at, text: text)],
                                 cursor: TextPosition(row: cursor.row + 1, column: newCol))
            }
            beginInsertRecording(kind: .o)
            return VimResult(handled: true, edits: [VimTextEdit(from: at, to: at, text: "\n" + indent)],
                             cursor: TextPosition(row: cursor.row + 1, column: (indent as NSString).length),
                             clearVisual: true, enteredInsert: true)
        case .O:
            let indent = TextEditing.indentation(of: context.lines[cursor.row])
            let at = TextPosition(row: cursor.row, column: 0)
            if let replayInserted {
                let text = indent + replayInserted + "\n"
                let newCol = max(0, ((indent + replayInserted) as NSString).length - 1)
                return VimResult(handled: true, edits: [VimTextEdit(from: at, to: at, text: text)],
                                 cursor: TextPosition(row: cursor.row, column: newCol))
            }
            beginInsertRecording(kind: .O)
            return VimResult(handled: true, edits: [VimTextEdit(from: at, to: at, text: indent + "\n")],
                             cursor: TextPosition(row: cursor.row, column: (indent as NSString).length),
                             clearVisual: true, enteredInsert: true)
        }
    }

    private func beginInsertRecording(kind: InsertEntryKind) {
        mode = .insert
        visualAnchor = nil
        activeInsert = ActiveInsertRecording(buildDot: { .insert(kind: kind, inserted: $0) })
        inputSource.restoreRememberedInputSource()
    }

    private func replaySimpleInsert(at pos: TextPosition, text: String) -> VimResult {
        guard !text.isEmpty else { return VimResult(handled: true, cursor: pos) }
        let pieces = TextEditing.lines(of: text)
        let endRow = pos.row + pieces.count - 1
        let endCol = (pieces.count == 1 ? pos.column : 0) + (pieces[pieces.count - 1] as NSString).length
        return VimResult(handled: true, edits: [VimTextEdit(from: pos, to: pos, text: text)],
                         cursor: TextPosition(row: endRow, column: max(0, endCol - 1)))
    }

    private func autoIndentForNewLineBelow(_ line: String, indentUnit: String) -> String {
        let base = TextEditing.indentation(of: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let last = trimmed.last, last == "{" || last == "(" || last == "[" || last == ":" {
            return base + indentUnit
        }
        return base
    }

    // MARK: Single-Key Edits (`x`, `X`, `r`, `D`, `C`, `p`, `P`, `J`, `~`, `>>`, `<<`, `gcc`)

    private func applyDeleteToEnd(count: Int, cursor: TextPosition, context: VimContext, enterInsert: Bool, recordDot: Bool, replayInserted: String? = nil) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let lastRow = min(max(0, context.lines.count - 1), cursor.row + count - 1)
        let to = TextPosition(row: lastRow, column: lineLength(context.lines, lastRow))
        let removed = TextEditing.text(context.lines, from: cursor, to: to)
        setRegister(removed, linewise: false)
        if enterInsert {
            if let replayInserted {
                let endCol = cursor.column + (replayInserted as NSString).length
                return VimResult(handled: true, edits: [VimTextEdit(from: cursor, to: to, text: replayInserted)],
                                 cursor: TextPosition(row: cursor.row, column: max(0, endCol - 1)))
            }
            if recordDot {
                activeInsert = ActiveInsertRecording(buildDot: { .changeToEnd(count: count, inserted: $0) })
            }
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: cursor < to ? [VimTextEdit(from: cursor, to: to, text: "")] : [],
                             cursor: cursor, enteredInsert: true)
        }
        if recordDot { lastChange = .deleteToEnd(count: count) }
        guard cursor < to else { return VimResult(handled: true) }
        let afterCol = max(0, cursor.column - 1)
        return VimResult(handled: true, edits: [VimTextEdit(from: cursor, to: to, text: "")], cursor: TextPosition(row: cursor.row, column: afterCol))
    }

    private func applyDeleteChars(count: Int, backward: Bool, cursor: TextPosition, context: VimContext, enterInsert: Bool, recordDot: Bool, replayInserted: String? = nil) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let len = lineLength(context.lines, cursor.row)
        let from: TextPosition
        let to: TextPosition
        if backward {
            var col = cursor.column
            for _ in 0..<count { col = prevCharCol(in: context.lines, row: cursor.row, col: col) }
            from = TextPosition(row: cursor.row, column: col)
            to = cursor
        } else {
            var col = cursor.column
            for _ in 0..<count { col = nextCharCol(in: context.lines, row: cursor.row, col: col) }
            from = cursor
            to = TextPosition(row: cursor.row, column: min(len, col))
        }
        let removed = TextEditing.text(context.lines, from: from, to: to)
        if !removed.isEmpty { setRegister(removed, linewise: false) }

        if enterInsert {
            if let replayInserted {
                let endCol = from.column + (replayInserted as NSString).length
                return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: replayInserted)],
                                 cursor: TextPosition(row: from.row, column: max(0, endCol - 1)))
            }
            if recordDot {
                activeInsert = ActiveInsertRecording(buildDot: { .changeChars(count: count, inserted: $0) })
            }
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: from < to ? [VimTextEdit(from: from, to: to, text: "")] : [],
                             cursor: from, enteredInsert: true)
        }

        if recordDot { lastChange = .deleteChars(count: count, backward: backward) }
        guard from < to else { return VimResult(handled: true) }
        let newLen = len - (to.column - from.column)
        let afterCol = newLen == 0 ? 0 : min(from.column, newLen - 1)
        return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: TextPosition(row: cursor.row, column: afterCol))
    }

    private func applyReplaceChar(_ ch: String, count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let len = lineLength(context.lines, cursor.row)
        guard len > 0, cursor.column < len else { return VimResult(handled: true) }

        var endCol = cursor.column
        var replaced = 0
        for _ in 0..<count {
            guard endCol < len else { break }
            endCol = nextCharCol(in: context.lines, row: cursor.row, col: endCol)
            replaced += 1
        }
        guard replaced == count else { return VimResult(handled: true) }
        let replacement = String(repeating: ch, count: count)
        if recordDot { lastChange = .replaceChar(count: count, char: ch) }
        let caretCol = cursor.column + ((replacement as NSString).length - (ch as NSString).length)
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: cursor, to: TextPosition(row: cursor.row, column: endCol), text: replacement)],
            cursor: TextPosition(row: cursor.row, column: max(0, caretCol))
        )
    }

    private func applyPut(after: Bool, count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let reg = currentRegister()
        guard !reg.text.isEmpty else { return VimResult(handled: true) }
        if recordDot { lastChange = .put(after: after, count: count) }

        if reg.blockwise {
            let blockLines = TextEditing.lines(of: reg.text).map { String(repeating: $0, count: count) }
            guard !blockLines.isEmpty else { return VimResult(handled: true) }
            let len = lineLength(context.lines, cursor.row)
            let insertCol = after && len > 0 ? nextCharCol(in: context.lines, row: cursor.row, col: cursor.column) : cursor.column
            var edits: [VimTextEdit] = []

            let lastExistingRow = context.lines.count - 1
            let neededLastRow = cursor.row + blockLines.count - 1
            if neededLastRow > lastExistingRow {
                let overflowStart = lastExistingRow - cursor.row + 1
                let pad = String(repeating: " ", count: insertCol)
                let extra = blockLines[overflowStart...].map { pad + $0 }.joined(separator: "\n")
                let endPos = TextPosition(row: lastExistingRow, column: lineLength(context.lines, lastExistingRow))
                edits.append(VimTextEdit(from: endPos, to: endPos, text: "\n" + extra))
            }

            let existingEnd = min(lastExistingRow, neededLastRow)
            for r in stride(from: existingEnd, through: cursor.row, by: -1) {
                let piece = blockLines[r - cursor.row]
                let rowLen = lineLength(context.lines, r)
                if rowLen < insertCol {
                    let pad = String(repeating: " ", count: insertCol - rowLen)
                    let pos = TextPosition(row: r, column: rowLen)
                    edits.append(VimTextEdit(from: pos, to: pos, text: pad + piece))
                } else {
                    let ns = context.lines[r] as NSString
                    let col = insertCol < ns.length ? ns.rangeOfComposedCharacterSequence(at: insertCol).location : rowLen
                    let pos = TextPosition(row: r, column: col)
                    edits.append(VimTextEdit(from: pos, to: pos, text: piece))
                }
            }
            return VimResult(handled: true, edits: edits, cursor: TextPosition(row: cursor.row, column: insertCol))
        }

        if reg.linewise {
            var body = reg.text
            if body.hasSuffix("\n") { body.removeLast() }
            let repeated = Array(repeating: body, count: count).joined(separator: "\n")
            let firstLine = TextEditing.lines(of: repeated).first ?? ""
            let firstNonBlankCol = (TextEditing.indentation(of: firstLine) as NSString).length
            if after {
                let at = TextPosition(row: cursor.row, column: lineLength(context.lines, cursor.row))
                return VimResult(
                    handled: true,
                    edits: [VimTextEdit(from: at, to: at, text: "\n" + repeated)],
                    cursor: TextPosition(row: cursor.row + 1, column: firstNonBlankCol)
                )
            } else {
                let at = TextPosition(row: cursor.row, column: 0)
                return VimResult(
                    handled: true,
                    edits: [VimTextEdit(from: at, to: at, text: repeated + "\n")],
                    cursor: TextPosition(row: cursor.row, column: firstNonBlankCol)
                )
            }
        } else {
            let repeated = String(repeating: reg.text, count: count)
            let len = lineLength(context.lines, cursor.row)
            let insertCol = after && len > 0 ? nextCharCol(in: context.lines, row: cursor.row, col: cursor.column) : cursor.column
            let at = TextPosition(row: cursor.row, column: insertCol)
            let pieces = TextEditing.lines(of: repeated)
            let endRow = cursor.row + pieces.count - 1
            let endCol: Int
            if pieces.count == 1 {
                endCol = max(0, insertCol + (pieces[0] as NSString).length - 1)
            } else {
                endCol = max(0, (pieces[pieces.count - 1] as NSString).length - 1)
            }
            return VimResult(
                handled: true,
                edits: [VimTextEdit(from: at, to: at, text: repeated)],
                cursor: TextPosition(row: endRow, column: endCol)
            )
        }
    }

    private func applyJoinLines(count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let joinCount = max(1, count == 1 ? 1 : count - 1)
        let lastRow = min(context.lines.count - 1, cursor.row + joinCount)
        guard lastRow > cursor.row else { return VimResult(handled: true) }
        if recordDot { lastChange = .joinLines(count: count) }

        var joined = context.lines[cursor.row]
        var caretCol = (joined as NSString).length
        for r in (cursor.row + 1)...lastRow {
            let nextTrimmed = context.lines[r].drop(while: { $0 == " " || $0 == "\t" })
            if !nextTrimmed.isEmpty {
                let needsSpace = !joined.isEmpty && !joined.hasSuffix(" ") && !joined.hasSuffix("\t")
                caretCol = (joined as NSString).length
                if needsSpace { joined.append(" ") }
                joined.append(contentsOf: nextTrimmed)
            }
        }
        let from = TextPosition(row: cursor.row, column: 0)
        let to = TextPosition(row: lastRow, column: lineLength(context.lines, lastRow))
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: from, to: to, text: joined)],
            cursor: TextPosition(row: cursor.row, column: min(caretCol, max(0, (joined as NSString).length - 1)))
        )
    }

    private func applyToggleCase(count: Int, cursor: TextPosition, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let line = context.lines[cursor.row]
        let ns = line as NSString
        guard ns.length > 0, cursor.column < ns.length else { return VimResult(handled: true) }
        if recordDot { lastChange = .toggleCase(count: count) }

        var endCol = cursor.column
        for _ in 0..<count {
            guard endCol < ns.length else { break }
            endCol = nextCharCol(in: context.lines, row: cursor.row, col: endCol)
        }
        let original = ns.substring(with: NSRange(location: cursor.column, length: endCol - cursor.column))
        let toggled = toggleCaseString(original)
        let newCol = min(max(0, ns.length - 1), endCol)
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: cursor, to: TextPosition(row: cursor.row, column: endCol), text: toggled)],
            cursor: TextPosition(row: cursor.row, column: newCol)
        )
    }

    private func applyIndent(firstRow: Int, lastRow: Int, outdent: Bool, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }
        let unit = context.indentUnit
        let width = unit == "\t" ? 4 : max(1, unit.utf16.count)
        var newLines: [String] = []
        var changed = false

        for r in firstRow...lastRow {
            let line = context.lines[r]
            if outdent {
                let ns = line as NSString
                var remove = 0
                if ns.length > 0 && ns.character(at: 0) == 9 {
                    remove = 1
                } else {
                    while remove < width && remove < ns.length && ns.character(at: remove) == 32 { remove += 1 }
                }
                if remove > 0 { changed = true }
                newLines.append(ns.substring(from: remove))
            } else {
                if line.isEmpty && firstRow != lastRow {
                    newLines.append(line)
                } else {
                    changed = true
                    newLines.append(unit + line)
                }
            }
        }
        if recordDot { lastChange = .indentLines(count: lastRow - firstRow + 1, outdent: outdent) }
        guard changed else { return VimResult(handled: true, clearVisual: true) }
        let from = TextPosition(row: firstRow, column: 0)
        let to = TextPosition(row: lastRow, column: lineLength(context.lines, lastRow))
        let firstCol = (TextEditing.indentation(of: newLines[0]) as NSString).length
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: from, to: to, text: newLines.joined(separator: "\n"))],
            cursor: TextPosition(row: firstRow, column: firstCol),
            clearVisual: true
        )
    }

    /// `set commentary`: toggles line comments (`//`, `#`, etc.) across `firstRow...lastRow`.
    private func applyToggleComment(firstRow: Int, lastRow: Int, context: VimContext, recordDot: Bool) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        let prefix = context.commentPrefix.isEmpty ? "//" : context.commentPrefix
        let slice = Array(context.lines[firstRow...lastRow])
        let nonBlank = slice.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        let allCommented = !nonBlank.isEmpty && nonBlank.allSatisfy { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(prefix)
        }

        let updated: [String]
        if allCommented {
            updated = slice.map { line in
                let indent = TextEditing.indentation(of: line)
                let rest = String(line.dropFirst(indent.count))
                if rest.hasPrefix(prefix + " ") {
                    return indent + String(rest.dropFirst(prefix.count + 1))
                } else if rest.hasPrefix(prefix) {
                    return indent + String(rest.dropFirst(prefix.count))
                }
                return line
            }
        } else {
            let minIndentCount = nonBlank.map { TextEditing.indentation(of: $0).count }.min() ?? 0
            let sampleIndent = nonBlank.first.map { String(TextEditing.indentation(of: $0).prefix(minIndentCount)) } ?? ""
            updated = slice.map { line in
                if line.trimmingCharacters(in: .whitespaces).isEmpty && !nonBlank.isEmpty {
                    return line
                }
                let indentLen = min(minIndentCount, line.count)
                let head = String(line.prefix(indentLen))
                let tail = String(line.dropFirst(indentLen))
                return (head.isEmpty ? sampleIndent : head) + prefix + " " + tail
            }
        }

        if recordDot { lastChange = .commentLines(count: lastRow - firstRow + 1) }
        let from = TextPosition(row: firstRow, column: 0)
        let to = TextPosition(row: lastRow, column: lineLength(context.lines, lastRow))
        let firstCol = (TextEditing.indentation(of: updated[0]) as NSString).length
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: from, to: to, text: updated.joined(separator: "\n"))],
            cursor: TextPosition(row: firstRow, column: firstCol),
            clearVisual: true
        )
    }

    // MARK: Visual Operations & Surround

    private func visualBounds(anchor: TextPosition, head: TextPosition, linewise: Bool, lines: [String]) -> (from: TextPosition, to: TextPosition) {
        if linewise {
            let first = min(anchor.row, head.row)
            let last = max(anchor.row, head.row)
            return (TextPosition(row: first, column: 0), TextPosition(row: last, column: lineLength(lines, last)))
        }
        let lo = min(anchor, head)
        let hi = max(anchor, head)
        let hiEndCol = nextCharCol(in: lines, row: hi.row, col: hi.column)
        return (lo, TextPosition(row: hi.row, column: hiEndCol))
    }

    private func applyVisualYank(anchor: TextPosition, head: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        if mode.isVisualBlock {
            return applyVisualBlockYank(anchor: anchor, head: head, context: context)
        }
        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: linewise, lines: context.lines)
        var text = TextEditing.text(context.lines, from: from, to: to)
        if linewise { text += "\n" }
        setRegister(text, linewise: linewise)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        return VimResult(handled: true, cursor: from, clearVisual: true)
    }

    private func applyVisualDelete(anchor: TextPosition, head: TextPosition, linewise: Bool, enterInsert: Bool, context: VimContext) -> VimResult {
        if mode.isVisualBlock && !linewise {
            return applyVisualBlockDelete(anchor: anchor, head: head, enterInsert: enterInsert, toEndOfLine: false, context: context)
        }
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        if linewise {
            let first = min(anchor.row, head.row)
            let last = max(anchor.row, head.row)
            return applyLineRangeOperator(enterInsert ? .change : .delete, firstRow: first, lastRow: last, cursor: anchor, context: context, recordDot: false)
        }

        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: false, lines: context.lines)
        let removed = TextEditing.text(context.lines, from: from, to: to)
        setRegister(removed, linewise: false)
        if enterInsert {
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: from, clearVisual: true, enteredInsert: true)
        }
        let afterCol = min(from.column, max(0, remainingLineLengthAfterDelete(lines: context.lines, from: from, to: to) - 1))
        return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: "")], cursor: TextPosition(row: from.row, column: afterCol), clearVisual: true)
    }

    private func applyVisualToggleCase(anchor: TextPosition, head: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        if mode.isVisualBlock {
            return applyVisualBlockToggleCase(anchor: anchor, head: head, context: context)
        }
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }
        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: linewise, lines: context.lines)
        let text = TextEditing.text(context.lines, from: from, to: to)
        let toggled = toggleCaseString(text)
        return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: toggled)], cursor: from, clearVisual: true)
    }

    private func applyVisualPut(anchor: TextPosition, head: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        if mode.isVisualBlock {
            return applyVisualBlockPut(anchor: anchor, head: head, context: context)
        }
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }
        let reg = currentRegister()
        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: linewise, lines: context.lines)
        let replaced = TextEditing.text(context.lines, from: from, to: to)
        var insertion = reg.text
        if reg.linewise && insertion.hasSuffix("\n") { insertion.removeLast() }
        setRegister(replaced + (linewise ? "\n" : ""), linewise: linewise)
        return VimResult(handled: true, edits: [VimTextEdit(from: from, to: to, text: insertion)], cursor: from, clearVisual: true)
    }

    private func surroundPair(for ch: String, includeAngleBrackets: Bool = true) -> (open: String, close: String)? {
        switch ch {
        case "\"": return ("\"", "\"")
        case "'": return ("'", "'")
        case "`": return ("`", "`")
        case "(", ")": return ("(", ")")
        case "[", "]": return ("[", "]")
        case "{", "}": return ("{", "}")
        case "<", ">": return includeAngleBrackets ? ("<", ">") : nil
        default: return nil
        }
    }

    private func applyVisualSurround(pair: (open: String, close: String), anchor: TextPosition, head: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        if mode.isVisualBlock {
            return applyVisualBlockSurround(pair: pair, anchor: anchor, head: head, context: context)
        }
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: linewise, lines: context.lines)
        let selected = TextEditing.text(context.lines, from: from, to: to)
        let wrapped: String
        if linewise {
            let indent = TextEditing.indentation(of: context.lines[from.row])
            wrapped = "\(indent)\(pair.open)\n\(selected)\n\(indent)\(pair.close)"
        } else {
            wrapped = pair.open + selected + pair.close
        }
        return VimResult(
            handled: true,
            edits: [VimTextEdit(from: from, to: to, text: wrapped)],
            cursor: from,
            clearVisual: true
        )
    }

    // MARK: Visual Block Operations

    private func composedCharacterCount(in ns: NSString, range: Range<Int>) -> Int {
        var count = 0
        var pos = range.lowerBound
        while pos < range.upperBound {
            let next = TextEditing.characterBoundary(in: ns, from: pos, forward: true)
            if next <= pos { break }
            count += 1
            pos = next
        }
        return count
    }

    private func applyVisualReplaceChar(_ ch: String, anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let isLinewise = mode.isVisualLine
        let isBlockwise = mode.isVisualBlock
        let bounds = isBlockwise ? blockColumnBounds(anchor: anchor, head: head) : nil
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        if isBlockwise, let bounds {
            let firstRow = min(anchor.row, head.row)
            let lastRow = max(anchor.row, head.row)
            var edits: [VimTextEdit] = []
            for r in stride(from: lastRow, through: firstRow, by: -1) {
                guard let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) else {
                    continue
                }
                let charCount = composedCharacterCount(in: context.lines[r] as NSString, range: range)
                guard charCount > 0 else { continue }
                edits.append(VimTextEdit(
                    from: TextPosition(row: r, column: range.lowerBound),
                    to: TextPosition(row: r, column: range.upperBound),
                    text: String(repeating: ch, count: charCount)
                ))
            }
            let cursorCol = min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))
            return VimResult(handled: true, edits: edits, cursor: TextPosition(row: firstRow, column: cursorCol), clearVisual: true)
        }

        let (from, to) = visualBounds(anchor: anchor, head: head, linewise: isLinewise, lines: context.lines)
        var edits: [VimTextEdit] = []
        for r in stride(from: to.row, through: from.row, by: -1) {
            let len = lineLength(context.lines, r)
            let startCol = isLinewise ? 0 : (r == from.row ? min(from.column, len) : 0)
            let endCol = isLinewise ? len : (r == to.row ? min(to.column, len) : len)
            guard startCol < endCol else { continue }
            let charCount = composedCharacterCount(in: context.lines[r] as NSString, range: startCol..<endCol)
            guard charCount > 0 else { continue }
            edits.append(VimTextEdit(
                from: TextPosition(row: r, column: startCol),
                to: TextPosition(row: r, column: endCol),
                text: String(repeating: ch, count: charCount)
            ))
        }
        return VimResult(handled: true, edits: edits, cursor: from, clearVisual: true)
    }

    private func applyVisualBlockInsert(append: Bool, anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)

        if !append {
            let anchorEditRow = (firstRow...lastRow).first { lineLength(context.lines, $0) >= bounds.startCol } ?? firstRow
            let line = context.lines[anchorEditRow]
            let ns = line as NSString
            let rawCol = min(bounds.startCol, ns.length)
            let insertCol = rawCol < ns.length ? ns.rangeOfComposedCharacterSequence(at: rawCol).location : rawCol
            pendingBlockEdit = BlockInsertSession(
                topRow: firstRow,
                bottomRow: lastRow,
                anchorEditRow: anchorEditRow,
                insertColumn: insertCol,
                appendToEOL: false,
                padShortLines: false,
                initialPrefix: ns.substring(to: insertCol),
                initialSuffix: ns.substring(from: insertCol)
            )
            activeInsert = ActiveInsertRecording(buildDot: { .insert(kind: .i, inserted: $0) })
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, cursor: TextPosition(row: anchorEditRow, column: insertCol), clearVisual: true, enteredInsert: true)
        }

        if bounds.extendToEnd {
            let anchorEditRow = firstRow
            let line = context.lines[anchorEditRow]
            let eol = (line as NSString).length
            pendingBlockEdit = BlockInsertSession(
                topRow: firstRow,
                bottomRow: lastRow,
                anchorEditRow: anchorEditRow,
                insertColumn: eol,
                appendToEOL: true,
                padShortLines: false,
                initialPrefix: line,
                initialSuffix: ""
            )
            activeInsert = ActiveInsertRecording(buildDot: { .insert(kind: .A, inserted: $0) })
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, cursor: TextPosition(row: anchorEditRow, column: eol), clearVisual: true, enteredInsert: true)
        }

        let refRow = (firstRow...lastRow).first { bounds.endCol < lineLength(context.lines, $0) }
        var targetCol = refRow.map { nextCharCol(in: context.lines, row: $0, col: bounds.endCol) } ?? (bounds.endCol + 1)
        let anchorEditRow = firstRow
        let firstLine = context.lines[anchorEditRow]
        let firstNS = firstLine as NSString
        var edits: [VimTextEdit] = []
        let initialPrefix: String
        let initialSuffix: String
        if firstNS.length < targetCol {
            let pad = String(repeating: " ", count: targetCol - firstNS.length)
            let padPos = TextPosition(row: anchorEditRow, column: firstNS.length)
            edits.append(VimTextEdit(from: padPos, to: padPos, text: pad))
            initialPrefix = firstLine + pad
            initialSuffix = ""
        } else {
            if targetCol < firstNS.length {
                targetCol = firstNS.rangeOfComposedCharacterSequence(at: targetCol).location
            }
            initialPrefix = firstNS.substring(to: targetCol)
            initialSuffix = firstNS.substring(from: targetCol)
        }

        pendingBlockEdit = BlockInsertSession(
            topRow: firstRow,
            bottomRow: lastRow,
            anchorEditRow: anchorEditRow,
            insertColumn: targetCol,
            appendToEOL: false,
            padShortLines: true,
            initialPrefix: initialPrefix,
            initialSuffix: initialSuffix
        )
        activeInsert = ActiveInsertRecording(buildDot: { .insert(kind: .A, inserted: $0) })
        mode = .insert
        inputSource.restoreRememberedInputSource()
        return VimResult(handled: true, edits: edits, cursor: TextPosition(row: anchorEditRow, column: targetCol), clearVisual: true, enteredInsert: true)
    }

    private func applyVisualBlockYank(anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        var slices: [String] = []
        for r in firstRow...lastRow {
            if let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) {
                slices.append((context.lines[r] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)))
            } else {
                slices.append("")
            }
        }
        setRegister(slices.joined(separator: "\n"), linewise: false, blockwise: true)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        return VimResult(handled: true, cursor: TextPosition(row: firstRow, column: min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))), clearVisual: true)
    }

    private func applyVisualBlockDelete(anchor: TextPosition, head: TextPosition, enterInsert: Bool, toEndOfLine: Bool, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        let extendToEnd = toEndOfLine || bounds.extendToEnd
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        var slices: [String] = []
        for r in firstRow...lastRow {
            if let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: extendToEnd, lines: context.lines) {
                slices.append((context.lines[r] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)))
            } else {
                slices.append("")
            }
        }
        setRegister(slices.joined(separator: "\n"), linewise: false, blockwise: true)

        var edits: [VimTextEdit] = []
        for r in stride(from: lastRow, through: firstRow, by: -1) {
            guard let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: extendToEnd, lines: context.lines) else {
                continue
            }
            edits.append(VimTextEdit(
                from: TextPosition(row: r, column: range.lowerBound),
                to: TextPosition(row: r, column: range.upperBound),
                text: ""
            ))
        }

        if enterInsert {
            let anchorEditRow = (firstRow...lastRow).first {
                blockRowRange(row: $0, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: extendToEnd, lines: context.lines) != nil
            } ?? ((firstRow...lastRow).first { lineLength(context.lines, $0) >= bounds.startCol } ?? firstRow)

            let anchorNS = context.lines[anchorEditRow] as NSString
            let initialPrefix: String
            let initialSuffix: String
            let insertCol: Int
            if let range = blockRowRange(row: anchorEditRow, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: extendToEnd, lines: context.lines) {
                initialPrefix = anchorNS.substring(to: range.lowerBound)
                initialSuffix = anchorNS.substring(from: range.upperBound)
                insertCol = range.lowerBound
            } else {
                let rawCol = min(bounds.startCol, anchorNS.length)
                insertCol = rawCol < anchorNS.length ? anchorNS.rangeOfComposedCharacterSequence(at: rawCol).location : rawCol
                initialPrefix = anchorNS.substring(to: insertCol)
                initialSuffix = anchorNS.substring(from: insertCol)
            }
            pendingBlockEdit = BlockInsertSession(
                topRow: firstRow,
                bottomRow: lastRow,
                anchorEditRow: anchorEditRow,
                insertColumn: insertCol,
                appendToEOL: false,
                padShortLines: false,
                initialPrefix: initialPrefix,
                initialSuffix: initialSuffix
            )
            activeInsert = ActiveInsertRecording(buildDot: { .insert(kind: .i, inserted: $0) })
            mode = .insert
            inputSource.restoreRememberedInputSource()
            return VimResult(handled: true, edits: edits, cursor: TextPosition(row: anchorEditRow, column: insertCol), clearVisual: true, enteredInsert: true)
        }

        let firstLenAfter: Int
        if let firstRange = blockRowRange(row: firstRow, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: extendToEnd, lines: context.lines) {
            firstLenAfter = lineLength(context.lines, firstRow) - firstRange.count
        } else {
            firstLenAfter = lineLength(context.lines, firstRow)
        }
        let afterCol = min(bounds.startCol, max(0, firstLenAfter - 1))
        return VimResult(handled: true, edits: edits, cursor: TextPosition(row: firstRow, column: afterCol), clearVisual: true)
    }

    private func applyVisualBlockToggleCase(anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        var edits: [VimTextEdit] = []
        for r in stride(from: lastRow, through: firstRow, by: -1) {
            guard let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) else {
                continue
            }
            let original = (context.lines[r] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            edits.append(VimTextEdit(
                from: TextPosition(row: r, column: range.lowerBound),
                to: TextPosition(row: r, column: range.upperBound),
                text: toggleCaseString(original)
            ))
        }
        return VimResult(handled: true, edits: edits, cursor: TextPosition(row: firstRow, column: min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))), clearVisual: true)
    }

    private func applyVisualBlockPut(anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        let reg = currentRegister()
        let blockLines = reg.blockwise ? TextEditing.lines(of: reg.text) : []

        var replacedSlices: [String] = []
        for r in firstRow...lastRow {
            if let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) {
                replacedSlices.append((context.lines[r] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count)))
            } else {
                replacedSlices.append("")
            }
        }

        var edits: [VimTextEdit] = []
        for r in stride(from: lastRow, through: firstRow, by: -1) {
            let idx = r - firstRow
            let insertion = reg.blockwise ? (idx < blockLines.count ? blockLines[idx] : "") : reg.text
            if let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) {
                edits.append(VimTextEdit(
                    from: TextPosition(row: r, column: range.lowerBound),
                    to: TextPosition(row: r, column: range.upperBound),
                    text: insertion
                ))
            } else if lineLength(context.lines, r) >= bounds.startCol {
                let pos = TextPosition(row: r, column: bounds.startCol)
                edits.append(VimTextEdit(from: pos, to: pos, text: insertion))
            }
        }
        setRegister(replacedSlices.joined(separator: "\n"), linewise: false, blockwise: true)
        return VimResult(handled: true, edits: edits, cursor: TextPosition(row: firstRow, column: min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))), clearVisual: true)
    }

    private func applyVisualBlockIndent(anchor: TextPosition, head: TextPosition, outdent: Bool, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        if bounds.startCol == 0 {
            return applyIndent(firstRow: firstRow, lastRow: lastRow, outdent: outdent, context: context, recordDot: false)
        }
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let unit = context.indentUnit
        let width = unit == "\t" ? 4 : max(1, unit.utf16.count)
        var edits: [VimTextEdit] = []
        for r in stride(from: lastRow, through: firstRow, by: -1) {
            let ns = context.lines[r] as NSString
            guard ns.length >= bounds.startCol else { continue }
            let col = bounds.startCol < ns.length ? ns.rangeOfComposedCharacterSequence(at: bounds.startCol).location : ns.length
            if outdent {
                guard col < ns.length else { continue }
                var remove = 0
                if ns.character(at: col) == 9 {
                    remove = 1
                } else {
                    while remove < width && col + remove < ns.length && ns.character(at: col + remove) == 32 {
                        remove += 1
                    }
                }
                guard remove > 0 else { continue }
                edits.append(VimTextEdit(
                    from: TextPosition(row: r, column: col),
                    to: TextPosition(row: r, column: col + remove),
                    text: ""
                ))
            } else {
                let pos = TextPosition(row: r, column: col)
                edits.append(VimTextEdit(from: pos, to: pos, text: unit))
            }
        }
        return VimResult(
            handled: true,
            edits: edits,
            cursor: TextPosition(row: firstRow, column: min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))),
            clearVisual: true
        )
    }

    private func applyVisualBlockSurround(pair: (open: String, close: String), anchor: TextPosition, head: TextPosition, context: VimContext) -> VimResult {
        let bounds = blockColumnBounds(anchor: anchor, head: head)
        mode = .normal
        visualAnchor = nil
        visualBlockDollar = false
        selectionStack.removeAll()
        guard context.isEditable else { return VimResult(handled: true, clearVisual: true, actions: [.readOnlyNotice]) }

        let firstRow = min(anchor.row, head.row)
        let lastRow = max(anchor.row, head.row)
        var edits: [VimTextEdit] = []
        for r in stride(from: lastRow, through: firstRow, by: -1) {
            guard let range = blockRowRange(row: r, startCol: bounds.startCol, endCol: bounds.endCol, extendToEnd: bounds.extendToEnd, lines: context.lines) else {
                continue
            }
            let slice = (context.lines[r] as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            edits.append(VimTextEdit(
                from: TextPosition(row: r, column: range.lowerBound),
                to: TextPosition(row: r, column: range.upperBound),
                text: pair.open + slice + pair.close
            ))
        }
        return VimResult(handled: true, edits: edits, cursor: TextPosition(row: firstRow, column: min(bounds.startCol, lastCharCol(in: context.lines, row: firstRow))), clearVisual: true)
    }

    // MARK: Expand / Shrink Selection (`<CR>` / `<BS>`)

    private func performExpandSelection(in context: VimContext) -> VimResult {
        guard !context.lines.isEmpty else { return VimResult(handled: true) }
        let cursor = clampPos(context.cursor, in: context.lines, allowPastEnd: false)

        let currentFrom: TextPosition
        let currentTo: TextPosition // exclusive
        if mode.isVisual, let anchor = visualAnchor {
            selectionStack.append(SelectionFrame(anchor: anchor, head: cursor, wasNormal: false))
            (currentFrom, currentTo) = visualBounds(anchor: anchor, head: cursor, linewise: mode.isVisualLine, lines: context.lines)
        } else {
            selectionStack.append(SelectionFrame(anchor: cursor, head: cursor, wasNormal: true))
            currentFrom = cursor
            currentTo = cursor
        }

        let candidates = expansionCandidates(from: currentFrom, to: currentTo, in: context.lines)
        let strictlyWider = candidates.filter { cand in
            cand.from <= currentFrom && cand.to >= currentTo && (cand.from < currentFrom || cand.to > currentTo)
        }

        // Pick the smallest candidate strictly larger than the current selection.
        guard let best = strictlyWider.min(by: { rangeSpan($0.from, $0.to, lines: context.lines) < rangeSpan($1.from, $1.to, lines: context.lines) }) else {
            _ = selectionStack.popLast()
            return VimResult(handled: true)
        }

        mode = .visual
        visualAnchor = best.from
        visualBlockDollar = false
        let head = inclusiveEndPosition(from: best.from, exclusiveEnd: best.to, in: context.lines)
        return VimResult(handled: true, cursor: head, visualRange: makeVisualRange(anchor: best.from, head: head))
    }

    private func performShrinkSelection(in context: VimContext) -> VimResult {
        guard let prev = selectionStack.popLast() else {
            if mode.isVisual {
                mode = .normal
                visualAnchor = nil
                visualBlockDollar = false
                return VimResult(handled: true, cursor: context.cursor, clearVisual: true)
            }
            return VimResult(handled: true)
        }
        if prev.wasNormal {
            mode = .normal
            visualAnchor = nil
            visualBlockDollar = false
            return VimResult(handled: true, cursor: prev.head, clearVisual: true)
        }
        mode = .visual
        visualAnchor = prev.anchor
        visualBlockDollar = false
        return VimResult(handled: true, cursor: prev.head, visualRange: makeVisualRange(anchor: prev.anchor, head: prev.head))
    }

    private func expansionCandidates(from: TextPosition, to: TextPosition, in lines: [String]) -> [(from: TextPosition, to: TextPosition)] {
        var result: [(from: TextPosition, to: TextPosition)] = []
        let row = from.row
        let ns = lines[row] as NSString
        let len = ns.length

        // 1. Identifier / word under cursor
        if len > 0 {
            let pivot = min(from.column, len - 1)
            if wordClass(ns.character(at: pivot), bigWord: false) == .word {
                var s = pivot, e = pivot + 1
                while s > 0 && wordClass(ns.character(at: s - 1), bigWord: false) == .word { s -= 1 }
                while e < len && wordClass(ns.character(at: e), bigWord: false) == .word { e += 1 }
                result.append((TextPosition(row: row, column: s), TextPosition(row: row, column: e)))
            }

            // 2. Member expression (`a.b.c`, `foo->bar`, `pkg::Sym`)
            func isMemberChar(_ u: unichar) -> Bool {
                wordClass(u, bigWord: false) == .word || u == 46 /* . */
            }
            if isMemberChar(ns.character(at: pivot)) {
                var s = pivot, e = pivot + 1
                while s > 0 && isMemberChar(ns.character(at: s - 1)) { s -= 1 }
                while e < len && isMemberChar(ns.character(at: e)) { e += 1 }
                if s < e { result.append((TextPosition(row: row, column: s), TextPosition(row: row, column: e))) }
            }

            // 3. Quoted string (inner & outer) on same line
            for q: unichar in [34, 39, 96] {
                if let inner = quoteTextObject(inner: true, quote: q, cursor: from, lines: lines) {
                    result.append((inner.from, inner.to))
                }
                if let outer = quoteTextObject(inner: false, quote: q, cursor: from, lines: lines) {
                    result.append((outer.from, outer.to))
                }
            }
        }

        // 4. Enclosing brackets (walk outward through nested (), [], {})
        for (open, close): (unichar, unichar) in [(40, 41), (91, 93), (123, 125)] {
            var searchPos = from
            for _ in 0..<8 {
                guard let o = findSingleEnclosingBracket(from: searchPos, in: lines, open: open, close: close, searchBackward: true),
                      let c = scanMatchingPair(from: o, open: open, close: close, forward: true, in: lines) else { break }
                let inner = innerPairRange(open: o, close: c, lines: lines)
                result.append((inner.from, inner.to))
                result.append((o, TextPosition(row: c.row, column: c.column + 1)))
                searchPos = o
            }
        }

        // 5. Current line (trimmed, then full)
        let indentCol = firstNonBlank(in: lines, row: row)
        if indentCol < len {
            result.append((TextPosition(row: row, column: indentCol), TextPosition(row: row, column: len)))
        }
        if len > 0 {
            result.append((TextPosition(row: row, column: 0), TextPosition(row: row, column: len)))
        }

        // 6. Enclosing function (inner & outer)
        if let innerFn = functionTextObject(inner: true, cursor: from, lines: lines) {
            result.append((innerFn.from, innerFn.to))
        }
        if let outerFn = functionTextObject(inner: false, cursor: from, lines: lines) {
            result.append((outerFn.from, outerFn.to))
        }

        // 7. Entire document
        let lastRow = lines.count - 1
        result.append((TextPosition(row: 0, column: 0), TextPosition(row: lastRow, column: lineLength(lines, lastRow))))
        return result
    }

    private func rangeSpan(_ from: TextPosition, _ to: TextPosition, lines: [String]) -> Int {
        if from.row == to.row { return max(0, to.column - from.column) }
        var total = max(0, lineLength(lines, from.row) - from.column) + 1
        if from.row + 1 < to.row {
            for r in (from.row + 1)..<to.row { total += lineLength(lines, r) + 1 }
        }
        total += to.column
        return total
    }

    // MARK: Dot Repeat (`.`)

    private func replayLastChange(overrideCount: Int?, cursor: TextPosition, context: VimContext) -> VimResult {
        guard context.isEditable else { return VimResult(handled: true, actions: [.readOnlyNotice]) }
        guard let cmd = lastChange else { return VimResult(handled: true) }

        switch cmd {
        case .deleteMotion(let count, let motion):
            return applyOperator(.delete, motion: motion, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .deleteTextObject(let inner, let char):
            return applyOperatorToTextObject(.delete, inner: inner, char: char, cursor: cursor, context: context, recordDot: false)
        case .deleteLines(let count):
            return applyLinewiseOperator(.delete, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .deleteToEnd(let count):
            return applyDeleteToEnd(count: overrideCount ?? count, cursor: cursor, context: context, enterInsert: false, recordDot: false)
        case .deleteChars(let count, let backward):
            return applyDeleteChars(count: overrideCount ?? count, backward: backward, cursor: cursor, context: context, enterInsert: false, recordDot: false)
        case .changeMotion(let count, let motion, let inserted):
            return applyOperator(.change, motion: motion, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false, replayInserted: inserted)
        case .changeTextObject(let inner, let char, let inserted):
            return applyOperatorToTextObject(.change, inner: inner, char: char, cursor: cursor, context: context, recordDot: false, replayInserted: inserted)
        case .changeLines(let count, let inserted):
            return applyLinewiseOperator(.change, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false, replayInserted: inserted)
        case .changeToEnd(let count, let inserted):
            return applyDeleteToEnd(count: overrideCount ?? count, cursor: cursor, context: context, enterInsert: true, recordDot: false, replayInserted: inserted)
        case .changeChars(let count, let inserted):
            return applyDeleteChars(count: overrideCount ?? count, backward: false, cursor: cursor, context: context, enterInsert: true, recordDot: false, replayInserted: inserted)
        case .insert(let kind, let inserted):
            return enterInsertMode(kind: kind, cursor: cursor, context: context, replayInserted: inserted)
        case .replaceChar(let count, let char):
            return applyReplaceChar(char, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .put(let after, let count):
            return applyPut(after: after, count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .joinLines(let count):
            return applyJoinLines(count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .toggleCase(let count):
            return applyToggleCase(count: overrideCount ?? count, cursor: cursor, context: context, recordDot: false)
        case .indentLines(let count, let outdent):
            let first = cursor.row
            let last = min(max(0, context.lines.count - 1), first + (overrideCount ?? count) - 1)
            return applyIndent(firstRow: first, lastRow: last, outdent: outdent, context: context, recordDot: false)
        case .commentLines(let count):
            let first = cursor.row
            let last = min(max(0, context.lines.count - 1), first + (overrideCount ?? count) - 1)
            return applyToggleComment(firstRow: first, lastRow: last, context: context, recordDot: false)
        }
    }

    // MARK: Viewport Scrolling Helpers

    private func scrollAndMoveCursor(down: Bool, fullPage: Bool, cursor: TextPosition, context: VimContext) -> VimResult {
        let step = max(1, fullPage ? max(1, context.visibleLineCount - 2) : max(1, context.visibleLineCount / 2))
        let lastRow = max(0, context.lines.count - 1)
        let row = down ? min(lastRow, cursor.row + step) : max(0, cursor.row - step)
        let col = firstNonBlank(in: context.lines, row: row)
        goalColumn = nil
        let action: VimAction = fullPage ? .scrollFullPage(down: down) : .scrollHalfPage(down: down)
        return VimResult(
            handled: true,
            cursor: TextPosition(row: row, column: col),
            actions: [action],
            jumpOrigin: row != cursor.row ? cursor : nil
        )
    }

    private func scrollAndMoveVisual(down: Bool, fullPage: Bool, anchor: TextPosition, cursor: TextPosition, linewise: Bool, context: VimContext) -> VimResult {
        let step = max(1, fullPage ? max(1, context.visibleLineCount - 2) : max(1, context.visibleLineCount / 2))
        let lastRow = max(0, context.lines.count - 1)
        let row = down ? min(lastRow, cursor.row + step) : max(0, cursor.row - step)
        let col: Int
        if mode.isVisualBlock {
            if visualBlockDollar {
                goalColumn = nil
                col = lastCharCol(in: context.lines, row: row)
            } else {
                let gCol = goalColumn ?? cursor.column
                goalColumn = gCol
                col = min(gCol, lastCharCol(in: context.lines, row: row))
            }
        } else {
            col = min(cursor.column, lastCharCol(in: context.lines, row: row))
        }
        let target = TextPosition(row: row, column: col)
        let action: VimAction = fullPage ? .scrollFullPage(down: down) : .scrollHalfPage(down: down)
        return VimResult(handled: true, cursor: target, visualRange: makeVisualRange(anchor: anchor, head: target), actions: [action])
    }

    // MARK: Register & Clipboard (`set clipboard+=unnamed`)

    private func setRegister(_ text: String, linewise: Bool, blockwise: Bool = false) {
        register = VimRegister(text: text, linewise: linewise, blockwise: blockwise)
        writeClipboard(text)
    }

    private func currentRegister() -> VimRegister {
        if let system = readClipboard(), !system.isEmpty {
            if system == register.text { return register }
            return VimRegister(text: system, linewise: system.hasSuffix("\n"))
        }
        return register
    }

    // MARK: Position & String Utilities

    private func lineLength(_ lines: [String], _ row: Int) -> Int {
        guard row >= 0 && row < lines.count else { return 0 }
        return (lines[row] as NSString).length
    }

    private func lastCharCol(in lines: [String], row: Int) -> Int {
        let len = lineLength(lines, row)
        guard len > 0 else { return 0 }
        return TextEditing.characterBoundary(in: lines[row] as NSString, from: len, forward: false)
    }

    private func prevCharCol(in lines: [String], row: Int, col: Int) -> Int {
        guard row >= 0 && row < lines.count, col > 0 else { return 0 }
        return TextEditing.characterBoundary(in: lines[row] as NSString, from: col, forward: false)
    }

    private func nextCharCol(in lines: [String], row: Int, col: Int) -> Int {
        guard row >= 0 && row < lines.count else { return 0 }
        let ns = lines[row] as NSString
        guard col < ns.length else { return ns.length }
        return TextEditing.characterBoundary(in: ns, from: col, forward: true)
    }

    private func firstNonBlank(in lines: [String], row: Int) -> Int {
        guard row >= 0 && row < lines.count else { return 0 }
        let ns = lines[row] as NSString
        var i = 0
        while i < ns.length && (ns.character(at: i) == 32 || ns.character(at: i) == 9) { i += 1 }
        return i < ns.length ? i : max(0, ns.length - 1)
    }

    private func clampPos(_ p: TextPosition, in lines: [String], allowPastEnd: Bool) -> TextPosition {
        guard !lines.isEmpty else { return TextPosition(row: 0, column: 0) }
        let row = max(0, min(p.row, lines.count - 1))
        let maxCol = allowPastEnd ? lineLength(lines, row) : lastCharCol(in: lines, row: row)
        return TextPosition(row: row, column: max(0, min(p.column, maxCol)))
    }

    private func inclusiveEndPosition(from: TextPosition, exclusiveEnd: TextPosition, in lines: [String]) -> TextPosition {
        guard exclusiveEnd > from else { return from }
        if exclusiveEnd.column > 0 {
            return TextPosition(row: exclusiveEnd.row, column: prevCharCol(in: lines, row: exclusiveEnd.row, col: exclusiveEnd.column))
        }
        let prevRow = max(from.row, exclusiveEnd.row - 1)
        return TextPosition(row: prevRow, column: lastCharCol(in: lines, row: prevRow))
    }

    private func orderedCharRange(start: TextPosition, outcome: MotionOutcome, lines: [String]) -> (TextPosition, TextPosition) {
        let lo = min(start, outcome.target)
        let hi = max(start, outcome.target)
        if outcome.kind == .charInclusive {
            let endCol = nextCharCol(in: lines, row: hi.row, col: hi.column)
            return (lo, TextPosition(row: hi.row, column: endCol))
        }
        return (lo, hi)
    }

    private func lineDeletionRange(firstRow: Int, lastRow: Int, lines: [String]) -> (TextPosition, TextPosition) {
        let lastIndex = max(0, lines.count - 1)
        if lastRow < lastIndex {
            return (TextPosition(row: firstRow, column: 0), TextPosition(row: lastRow + 1, column: 0))
        } else if firstRow > 0 {
            return (TextPosition(row: firstRow - 1, column: lineLength(lines, firstRow - 1)),
                    TextPosition(row: lastRow, column: lineLength(lines, lastRow)))
        } else {
            return (TextPosition(row: 0, column: 0), TextPosition(row: lastRow, column: lineLength(lines, lastRow)))
        }
    }

    private func remainingLineLengthAfterDelete(lines: [String], from: TextPosition, to: TextPosition) -> Int {
        let tail = max(0, lineLength(lines, to.row) - to.column)
        return from.column + tail
    }

    private func toggleCaseString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            let lower = String(ch).lowercased()
            let upper = String(ch).uppercased()
            if String(ch) == lower && lower != upper {
                out.append(upper)
            } else if String(ch) == upper && lower != upper {
                out.append(lower)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Derives the line comment prefix for a `LanguageSpec` (defaulting to `//`).
    static func lineCommentPrefix(for language: LanguageSpec?) -> String {
        guard let bytes = language?.lineComments.first, !bytes.isEmpty else { return "//" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
