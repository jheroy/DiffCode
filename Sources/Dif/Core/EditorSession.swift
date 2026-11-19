import Foundation

/// The editing state of the file on screen: undo history, what has been written, and what it takes to
/// write the text back exactly. The text itself is the document's right buffer, which the canvas draws,
/// so an edit changes what is on screen with no copy in between.
final class EditorSession {
    typealias Selection = (anchor: TextPosition, head: TextPosition)

    enum Kind { case typing, deleting, other }

    /// One replacement, enough to make it again or take it back.
    struct Change {
        var from: TextPosition
        /// End of the replaced text, before the change.
        var removedEnd: TextPosition
        /// End of the new text, after the change.
        var insertedEnd: TextPosition
        var removed: String
        var inserted: String
    }

    /// What one ⌘Z takes back: a run of typing, a paste, an indent of several lines…
    struct Group {
        var changes: [Change]
        var kind: Kind
        var selectionBefore: Selection
        var selectionAfter: Selection
        /// Whether the last line ended with a line break before and after, when the group changed that.
        var finalNewline: (before: Bool, after: Bool)?
        var time: TimeInterval
    }

    /// What an edit did to the lines, for redrawing them.
    struct Outcome {
        var raw: LineEdit
        var change: LineEdit
        /// Lines whose colours were recomputed (an opened comment can recolour many).
        var recoloured: Range<Int>
        var end: TextPosition
    }

    static let undoLimit = 300

    let root: URL
    let path: String
    let document: DiffDocument
    var buffer: TextBuffer { document.right }
    private(set) var format: TextFormat
    private(set) var crlf: [Bool]?
    /// The left side's bytes, which the text is diffed against as it changes.
    let base: Data?
    let ignoreWhitespace: Bool
    /// What the file held when it was last read or written here.
    private(set) var diskFingerprint: Data

    /// Counts changes to the text, to tell whether what is on screen has been written and whether a diff is still current.
    private(set) var version = 0
    private(set) var savedVersion = 0
    var isDirty: Bool { version != savedVersion }
    /// Edited here at some point since it was opened.
    private(set) var hasEdits = false

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    /// The last group may still take more typing.
    private var groupOpen = false
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Text an input method is composing. It sits in the buffer so that it is drawn in place,
    /// but it is not part of the file: nothing is saved or diffed while it is there.
    private(set) var marked: (row: Int, range: Range<Int>)?

    private(set) lazy var indentUnit = TextEditing.indentUnit(for: buffer.lines)

    /// UTF-16 offset of each line's start, for the input method's ranges; valid below `validStarts`.
    private var lineStarts: [Int] = [0]
    private var validStarts = 1

    var url: URL { root.appendingPathComponent(path) }
    var isPlainFile: Bool { document.isPlainFile }

    init?(document: DiffDocument, root: URL, path: String, ignoreWhitespace: Bool) {
        guard let info = document.editing, info.readOnlyReason == nil, case .text = document.content,
              document.right !== TextBuffer.empty, !document.right.lines.isEmpty else { return nil }
        self.document = document
        self.root = root
        self.path = path
        self.ignoreWhitespace = ignoreWhitespace
        format = info.format
        crlf = info.crlf
        base = info.base
        diskFingerprint = info.fingerprint
    }

    // MARK: Editing

    /// Replaces text and records it for undo. `selection` is what undoing restores.
    @discardableResult
    func replace(from: TextPosition, to: TextPosition, with text: String, kind: Kind, selection: Selection) -> Outcome {
        let lines = buffer.lines
        let a = TextEditing.clamp(min(from, to), in: lines), b = TextEditing.clamp(max(from, to), in: lines)
        let removed = TextEditing.text(lines, from: a, to: b)
        let outcome = apply(from: a, to: b, text: text)
        record(Change(from: a, removedEnd: b, insertedEnd: outcome.end, removed: removed, inserted: text),
               kind: kind, before: selection, after: (outcome.end, outcome.end))
        return outcome
    }

    /// Several replacements as one undo step, each given in the text as it stands after the ones before it.
    func replace(_ edits: [(from: TextPosition, to: TextPosition, text: String)], selection: Selection, after: Selection) -> [Outcome] {
        guard !edits.isEmpty else { return [] }
        var changes: [Change] = []
        var outcomes: [Outcome] = []
        for edit in edits {
            let lines = buffer.lines
            let a = TextEditing.clamp(min(edit.from, edit.to), in: lines), b = TextEditing.clamp(max(edit.from, edit.to), in: lines)
            let removed = TextEditing.text(lines, from: a, to: b)
            let outcome = apply(from: a, to: b, text: edit.text)
            changes.append(Change(from: a, removedEnd: b, insertedEnd: outcome.end, removed: removed, inserted: edit.text))
            outcomes.append(outcome)
        }
        closeGroup()
        push(Group(changes: changes, kind: .other, selectionBefore: selection, selectionAfter: after, time: Self.now))
        return outcomes
    }

    /// Whether the file ends with a line break, as part of the last undo step (a rollback at the end of the file needs it).
    func setFinalNewline(_ value: Bool) {
        guard value != format.finalNewline else { return }
        let before = format.finalNewline
        format.finalNewline = value
        version += 1
        if !undoStack.isEmpty { undoStack[undoStack.count - 1].finalNewline = (before, value) }
    }

    /// Ends the run of typing that keystrokes are being added to: the caret moved, or something else happened.
    func closeGroup() { groupOpen = false }

    @discardableResult
    func undo() -> (outcomes: [Outcome], selection: Selection)? {
        guard marked == nil, let group = undoStack.popLast() else { return nil }
        closeGroup()
        var outcomes: [Outcome] = []
        for change in group.changes.reversed() {
            outcomes.append(apply(from: change.from, to: change.insertedEnd, text: change.removed))
        }
        if let finalNewline = group.finalNewline { format.finalNewline = finalNewline.before }
        redoStack.append(group)
        return (outcomes, group.selectionBefore)
    }

    @discardableResult
    func redo() -> (outcomes: [Outcome], selection: Selection)? {
        guard marked == nil, let group = redoStack.popLast() else { return nil }
        closeGroup()
        var outcomes: [Outcome] = []
        for change in group.changes {
            outcomes.append(apply(from: change.from, to: change.removedEnd, text: change.inserted))
        }
        if let finalNewline = group.finalNewline { format.finalNewline = finalNewline.after }
        undoStack.append(group)
        return (outcomes, group.selectionAfter)
    }

    /// Replaces the whole text with what is on disk now, as one undo step, so that ⌘Z brings back what was here.
    /// The text then matches the file again.
    func takeDiskVersion(_ text: EditableText, data: Data, selection: Selection) -> Outcome {
        let outcome = replace(from: TextPosition(row: 0, column: 0), to: endOfText, with: text.lines.joined(separator: "\n"),
                              kind: .other, selection: selection)
        closeGroup()
        format = text.format
        crlf = text.crlf
        if crlf != nil, crlf!.count != buffer.lines.count { crlf = nil }
        didWrite(data)
        return outcome
    }

    /// The text was changed by something else, while nothing here was unsaved: it is simply the new text,
    /// and the history (which describes the old one) is dropped.
    func replaceWithoutHistory(_ text: EditableText, data: Data) -> Outcome {
        let outcome = apply(from: TextPosition(row: 0, column: 0), to: endOfText, text: text.lines.joined(separator: "\n"))
        format = text.format
        crlf = text.crlf
        if crlf != nil, crlf!.count != buffer.lines.count { crlf = nil }
        undoStack.removeAll()
        redoStack.removeAll()
        groupOpen = false
        didWrite(data)
        return outcome
    }

    // MARK: History across sessions

    /// An undo history, for a later session of the same text to take up: the file opened again, or read
    /// again because the diff's base moved.
    struct History {
        fileprivate var undo: [Group]
        fileprivate var redo: [Group]
        /// The bytes the history ends with.
        let fingerprint: Data
    }

    /// The history, while what is on screen is exactly what the file holds.
    var history: History? {
        guard hasEdits, !isDirty, marked == nil else { return nil }
        return History(undo: undoStack, redo: redoStack, fingerprint: diskFingerprint)
    }

    /// Takes up a history that ends with exactly this session's text. Returns whether it did.
    @discardableResult
    func adopt(_ history: History) -> Bool {
        guard !hasEdits, history.fingerprint == diskFingerprint else { return false }
        undoStack = history.undo
        redoStack = history.redo
        hasEdits = true
        return true
    }

    /// Typing that could not be written, for a later session of the same file to carry on with.
    struct Unsaved {
        fileprivate let lines: [String]
        fileprivate let format: TextFormat
        fileprivate let crlf: [Bool]?
        fileprivate let undo: [Group]
        fileprivate let redo: [Group]
        /// What the file held when it was last read or written.
        fileprivate let fingerprint: Data
    }

    var unsaved: Unsaved? {
        guard isDirty, marked == nil else { return nil }
        return Unsaved(lines: buffer.lines, format: format, crlf: crlf, undo: undoStack, redo: redoStack, fingerprint: diskFingerprint)
    }

    /// Carries on with typing that could not be written. Over the text it was typed over, it simply comes back,
    /// unsaved, with its history. If the file has changed since, the file's text stays, and the typing is one ⌘Z
    /// away, as with any change underneath. Returns whether the file had changed.
    @discardableResult
    func resume(_ unsaved: Unsaved, selection: Selection) -> (outcomes: [Outcome], changedSince: Bool) {
        guard !hasEdits, marked == nil else { return ([], false) }
        let disk = (lines: buffer.lines, format: format, crlf: crlf)
        var outcomes = [apply(from: TextPosition(row: 0, column: 0), to: endOfText, text: unsaved.lines.joined(separator: "\n"))]
        format = unsaved.format
        crlf = unsaved.crlf
        undoStack = unsaved.undo
        redoStack = unsaved.redo
        groupOpen = false
        hasEdits = true
        guard unsaved.fingerprint != diskFingerprint else { return (outcomes, false) }
        outcomes.append(replace(from: TextPosition(row: 0, column: 0), to: endOfText, with: disk.lines.joined(separator: "\n"),
                                kind: .other, selection: selection))
        closeGroup()
        format = disk.format
        crlf = disk.crlf
        savedVersion = version
        return (outcomes, true)
    }

    private var endOfText: TextPosition {
        let last = buffer.lines.count - 1
        return TextPosition(row: last, column: buffer.lines[last].utf16.count)
    }

    // MARK: Composition

    /// Shows `text` as the input method's composition, replacing the previous one, or starting at `position`.
    /// Not recorded, saved or diffed. An empty `text` ends the composition, leaving nothing behind.
    func setMarked(_ text: String, at position: TextPosition) -> Outcome {
        // A composition is one line; an input method has no business putting line breaks in it.
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let start: TextPosition, end: TextPosition
        if let marked {
            start = TextPosition(row: marked.row, column: marked.range.lowerBound)
            end = TextPosition(row: marked.row, column: marked.range.upperBound)
        } else {
            start = TextEditing.clamp(position, in: buffer.lines)
            end = start
        }
        let outcome = apply(from: start, to: end, text: flat)
        let length = (flat as NSString).length
        marked = length > 0 ? (start.row, start.column..<(start.column + length)) : nil
        return outcome
    }

    /// Takes the composition out of the text again. Returns what it was and where it sat.
    func removeMarked() -> (text: String, at: TextPosition, outcome: Outcome)? {
        guard let marked else { return nil }
        let start = TextPosition(row: marked.row, column: marked.range.lowerBound)
        let end = TextPosition(row: marked.row, column: marked.range.upperBound)
        let text = TextEditing.text(buffer.lines, from: start, to: end)
        let outcome = apply(from: start, to: end, text: "")
        self.marked = nil
        return (text, start, outcome)
    }

    // MARK: Writing

    /// The file's new bytes. Nil while something is being composed (it is not part of the file yet),
    /// or if the text cannot be put in the file's encoding.
    func encoded() -> Data? {
        guard marked == nil else { return nil }
        return TextCodec.encode(buffer.lines, format: format, crlf: crlf)
    }

    /// `data` is now what the file holds and what is on screen.
    func didWrite(_ data: Data) {
        diskFingerprint = TextCodec.fingerprint(data)
        savedVersion = version
    }

    /// Typing was undone back to what the file holds: nothing to write after all.
    func markSaved() { savedVersion = version }

    // MARK: Offsets for the input method

    /// The whole text as one string of UTF-16 units, lines joined by single line breaks.
    func offset(of position: TextPosition) -> Int {
        let p = TextEditing.clamp(position, in: buffer.lines)
        return lineStart(p.row) + p.column
    }

    func position(ofOffset offset: Int) -> TextPosition {
        let lines = buffer.lines
        guard !lines.isEmpty else { return TextPosition(row: 0, column: 0) }
        let target = max(0, offset)
        while validStarts < lines.count, lineStart(validStarts - 1) <= target { _ = lineStart(validStarts) }
        var lo = 0, hi = validStarts - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= target { lo = mid } else { hi = mid - 1 }
        }
        return TextPosition(row: lo, column: min(target - lineStarts[lo], lines[lo].utf16.count))
    }

    var totalLength: Int {
        let last = buffer.lines.count - 1
        return lineStart(last) + buffer.lines[last].utf16.count
    }

    private func lineStart(_ row: Int) -> Int {
        let lines = buffer.lines
        let row = min(max(0, row), lines.count - 1)
        while validStarts <= row {
            let previous = validStarts - 1
            let start = lineStarts[previous] + lines[previous].utf16.count + 1
            if validStarts < lineStarts.count { lineStarts[validStarts] = start } else { lineStarts.append(start) }
            validStarts += 1
        }
        return lineStarts[row]
    }

    // MARK: Plumbing

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Changes the text without recording it, keeping everything that follows from the text in step:
    /// colours, line endings, the diff's hunks (moved until the real diff is back), the offsets.
    private func apply(from: TextPosition, to: TextPosition, text: String) -> Outcome {
        let result = buffer.replace(from: from, to: to, with: text)
        let raw = result.raw
        if crlf != nil, raw.start + raw.removed <= crlf!.count {
            // The last rewritten line keeps the ending it had; lines added in between get the file's usual one.
            let last = crlf![raw.start + raw.removed - 1]
            let added = [Bool](repeating: format.newline == "\r\n", count: raw.inserted - 1)
            crlf!.replaceSubrange(raw.start..<(raw.start + raw.removed), with: added + [last])
        }
        var recoloured = raw.start..<(raw.start + raw.inserted)
        if buffer.states != nil, buffer.baseSpans != nil, buffer.baseSpans!.count == buffer.lines.count {
            let range = Highlighter.rehighlight(buffer.lines, language: document.language, from: raw.start, count: raw.inserted,
                                                spans: &buffer.baseSpans!, states: &buffer.states!)
            if buffer.spans.count == buffer.lines.count {
                for row in range {
                    buffer.spans[row] = buffer.baseSpans![row]
                }
            }
            recoloured = min(recoloured.lowerBound, range.lowerBound)..<max(recoloured.upperBound, range.upperBound)
        } else if buffer.states != nil, buffer.spans.count == buffer.lines.count {
            let range = Highlighter.rehighlight(buffer.lines, language: document.language, from: raw.start, count: raw.inserted,
                                                spans: &buffer.spans, states: &buffer.states!)
            recoloured = min(recoloured.lowerBound, range.lowerBound)..<max(recoloured.upperBound, range.upperBound)
        }
        if !document.isPlainFile { document.setHunks(TextEditing.adjust(document.hunks, for: result.change)) }
        version += 1
        validStarts = min(validStarts, raw.start + 1)
        return Outcome(raw: raw, change: result.change, recoloured: recoloured, end: result.end)
    }

    private func record(_ change: Change, kind: Kind, before: Selection, after: Selection) {
        let now = Self.now
        if groupOpen, kind != .other, var last = undoStack.last, last.kind == kind, now - last.time < 4,
           let previous = last.changes.last, continues(previous, change, kind) {
            last.changes.append(change)
            last.selectionAfter = after
            last.time = now
            undoStack[undoStack.count - 1] = last
            redoStack.removeAll()
            hasEdits = true
        } else {
            push(Group(changes: [change], kind: kind, selectionBefore: before, selectionAfter: after, time: now))
        }
        groupOpen = kind != .other
    }

    private func push(_ group: Group) {
        undoStack.append(group)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        hasEdits = true
    }

    /// Typing goes on where the last keystroke left the caret; deleting backwards ends where the last deletion
    /// began, deleting forwards begins where it began.
    private func continues(_ previous: Change, _ next: Change, _ kind: Kind) -> Bool {
        switch kind {
        case .typing: return next.removed.isEmpty && next.from == previous.insertedEnd && !next.inserted.contains("\n")
        case .deleting: return next.inserted.isEmpty && (next.removedEnd == previous.from || next.from == previous.from)
        case .other: return false
        }
    }
}
