import AppKit

/// Typing into the right side of the canvas, when it is a file of the working tree that can be edited.
///
/// Keys go through the text input system: input methods (Pinyin, Japanese…) compose in place through
/// NSTextInputClient, and the key bindings come back as the standard commands (moveLeft:, deleteBackward:…).
/// Positions here are lines and UTF-16 columns of the right side; the canvas maps them to its rows.
extension CodeCanvasView: @preconcurrency NSTextInputClient {
    private var lines: [String] { document?.right.lines ?? [] }
    private var lastRow: Int { max(0, lines.count - 1) }

    private func lineLength(_ row: Int) -> Int {
        row >= 0 && row < lines.count ? lines[row].utf16.count : 0
    }

    // MARK: Keys

    /// Keys that mean something different here than in a text field, as in the IDE. Everything else
    /// goes to the input method. Returns false when the canvas should treat the key as a viewer would.
    func handleEditingKey(_ event: NSEvent) -> Bool {
        guard let editor, let sel = editSelection else { return false }
        if editor.marked == nil {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let shift = flags.contains(.shift)
            switch event.keyCode {
            case 115: // Home: the start of the line (its text first), not of the file
                if flags.contains(.command) {
                    moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: shift)
                } else {
                    moveCaret(to: { self.smartLineStart($0.head) }, extend: shift)
                }
                return true
            case 119: // End
                if flags.contains(.command) {
                    moveCaret(to: { _ in self.documentEnd }, extend: shift)
                } else {
                    moveCaret(to: { TextPosition(row: $0.head.row, column: self.lineLength($0.head.row)) }, extend: shift)
                }
                return true
            case 116: // Page Up moves the caret, not just the view
                movePage(-1, extend: shift)
                return true
            case 121:
                movePage(1, extend: shift)
                return true
            case 51 where flags == .command: // ⌘⌫ deletes the line
                deleteLines()
                return true
            case 53: // Esc drops the selection; with none, it leaves the viewer as before
                guard sel.anchor != sel.head else { return false }
                setCaret(sel.head)
                return true
            default:
                break
            }
        }
        interpretKeyEvents([event])
        return true
    }

    /// One of the standard text commands. Returns false for the ones that do nothing here.
    func performEditingCommand(_ selector: Selector) -> Bool {
        guard editor != nil, editSelection != nil else { return false }
        switch NSStringFromSelector(selector) {
        case "moveLeft:", "moveBackward:":
            moveCaret(to: { self.characterBefore($0.head) }, extend: false, collapse: { min($0.anchor, $0.head) })
        case "moveRight:", "moveForward:":
            moveCaret(to: { self.characterAfter($0.head) }, extend: false, collapse: { max($0.anchor, $0.head) })
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:":
            moveCaret(to: { self.characterBefore($0.head) }, extend: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:":
            moveCaret(to: { self.characterAfter($0.head) }, extend: true)
        case "moveUp:": moveVertically(-1, extend: false)
        case "moveDown:": moveVertically(1, extend: false)
        case "moveUpAndModifySelection:": moveVertically(-1, extend: true)
        case "moveDownAndModifySelection:": moveVertically(1, extend: true)
        case "moveWordLeft:", "moveWordBackward:":
            moveCaret(to: { self.wordBefore($0.head) }, extend: false)
        case "moveWordRight:", "moveWordForward:":
            moveCaret(to: { self.wordAfter($0.head) }, extend: false)
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:":
            moveCaret(to: { self.wordBefore($0.head) }, extend: true)
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:":
            moveCaret(to: { self.wordAfter($0.head) }, extend: true)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:":
            moveCaret(to: { self.smartLineStart($0.head) }, extend: false)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:":
            moveCaret(to: { self.smartLineStart($0.head) }, extend: true)
        case "moveToBeginningOfParagraph:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: 0) }, extend: false)
        case "moveToBeginningOfParagraphAndModifySelection:", "moveParagraphBackwardAndModifySelection:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: 0) }, extend: true)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: self.lineLength($0.head.row)) }, extend: false)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
             "moveToEndOfParagraphAndModifySelection:", "moveParagraphForwardAndModifySelection:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: self.lineLength($0.head.row)) }, extend: true)
        case "moveToBeginningOfDocument:":
            moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: false)
        case "moveToBeginningOfDocumentAndModifySelection:":
            moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: true)
        case "moveToEndOfDocument:":
            moveCaret(to: { _ in self.documentEnd }, extend: false)
        case "moveToEndOfDocumentAndModifySelection:":
            moveCaret(to: { _ in self.documentEnd }, extend: true)
        case "pageUp:", "scrollPageUp:": movePage(-1, extend: false)
        case "pageDown:", "scrollPageDown:": movePage(1, extend: false)
        case "pageUpAndModifySelection:": movePage(-1, extend: true)
        case "pageDownAndModifySelection:": movePage(1, extend: true)
        case "scrollLineUp:": container?.scrollBy(dx: 0, dy: -codeFont.lineHeight)
        case "scrollLineDown:": container?.scrollBy(dx: 0, dy: codeFont.lineHeight)
        case "scrollToBeginningOfDocument:": container?.scroll(toY: 0, animated: true)
        case "scrollToEndOfDocument:": container?.scroll(toY: .greatestFiniteMagnitude, animated: true)
        case "centerSelectionInVisibleArea:":
            if let head = editSelection?.head { container?.scroll(toRow: row(forLine: head.row, side: .right), fraction: 0.5, animated: true) }
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            deleteSelection(orTo: { self.backspaceTarget($0) })
        case "deleteForward:":
            deleteSelection(orTo: { self.characterAfter($0) })
        case "deleteWordBackward:":
            deleteSelection(orTo: { self.wordBefore($0) })
        case "deleteWordForward:":
            deleteSelection(orTo: { self.wordAfter($0) })
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:":
            deleteSelection(orTo: { $0.column > 0 ? TextPosition(row: $0.row, column: 0) : self.characterBefore($0) })
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            deleteSelection(orTo: { $0.column < self.lineLength($0.row) ? TextPosition(row: $0.row, column: self.lineLength($0.row)) : self.characterAfter($0) })
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:":
            insertNewline()
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            insertTab()
        case "insertBacktab:":
            indentLines(outdent: true)
        case "transpose:":
            transpose()
        case "selectAll:":
            selectAll(nil)
        case "selectLine:", "selectParagraph:":
            if let head = editSelection?.head {
                let end = head.row < lastRow ? TextPosition(row: head.row + 1, column: 0) : TextPosition(row: head.row, column: lineLength(head.row))
                setSelection((TextPosition(row: head.row, column: 0), end))
            }
        case "cancelOperation:":
            if let sel = editSelection, sel.anchor != sel.head { setCaret(sel.head) } else { delegate?.canvasDidRequestExit(self) }
        default:
            return false
        }
        return true
    }

    // MARK: Positions

    private var documentEnd: TextPosition { TextPosition(row: lastRow, column: lineLength(lastRow)) }

    private func characterBefore(_ p: TextPosition) -> TextPosition {
        if p.column > 0 {
            return TextPosition(row: p.row, column: TextEditing.characterBoundary(in: lines[p.row] as NSString, from: p.column, forward: false))
        }
        return p.row > 0 ? TextPosition(row: p.row - 1, column: lineLength(p.row - 1)) : p
    }

    private func characterAfter(_ p: TextPosition) -> TextPosition {
        if p.column < lineLength(p.row) {
            return TextPosition(row: p.row, column: TextEditing.characterBoundary(in: lines[p.row] as NSString, from: p.column, forward: true))
        }
        return p.row < lastRow ? TextPosition(row: p.row + 1, column: 0) : p
    }

    private func wordBefore(_ p: TextPosition) -> TextPosition {
        guard p.column > 0 else { return characterBefore(p) }
        return TextPosition(row: p.row, column: TextEditing.wordBoundary(in: lines[p.row] as NSString, from: p.column, forward: false))
    }

    private func wordAfter(_ p: TextPosition) -> TextPosition {
        guard p.column < lineLength(p.row) else { return characterAfter(p) }
        return TextPosition(row: p.row, column: TextEditing.wordBoundary(in: lines[p.row] as NSString, from: p.column, forward: true))
    }

    /// The first character of the line's text, or the very start of the line when the caret is already there.
    private func smartLineStart(_ p: TextPosition) -> TextPosition {
        let indent = (TextEditing.indentation(of: lines[p.row]) as NSString).length
        return TextPosition(row: p.row, column: p.column == indent ? 0 : indent)
    }

    /// Where ⌫ deletes back to: in indentation made of spaces, the previous indent stop.
    private func backspaceTarget(_ p: TextPosition) -> TextPosition {
        guard p.column > 0, let unit = editor?.indentUnit, unit != "\t" else { return characterBefore(p) }
        let before = (lines[p.row] as NSString).substring(to: p.column)
        guard before.utf8.allSatisfy({ $0 == 32 }) else { return characterBefore(p) }
        let width = max(1, unit.utf16.count)
        return TextPosition(row: p.row, column: p.column - ((p.column - 1) % width + 1))
    }

    // MARK: Selection

    func setCaret(_ position: TextPosition) { setSelection((position, position)) }

    func setSelection(_ sel: EditorSession.Selection) {
        let a = TextEditing.clamp(sel.anchor, in: lines), b = TextEditing.clamp(sel.head, in: lines)
        selection = TextSelection(pane: .right, anchor: rowPosition(a), head: rowPosition(b))
    }

    /// Puts the caret on a line of the right side, e.g. at a change F7 moved to or a line jumped to.
    func placeCaret(line: Int, column: Int = 0) {
        guard !lines.isEmpty else { return }
        guard editor != nil || vimModeEnabled else { return }
        commitComposition()
        editor?.closeGroup()
        let clamped = TextEditing.clamp(TextPosition(row: line, column: column), in: lines)
        vimCursor = clamped
        setCaret(clamped)
        goalX = nil
    }

    private func moveCaret(to target: (EditorSession.Selection) -> TextPosition, extend: Bool,
                           collapse: ((EditorSession.Selection) -> TextPosition)? = nil) {
        guard let editor, let sel = editSelection else { return }
        editor.closeGroup()
        let head: TextPosition
        if !extend, sel.anchor != sel.head, let collapse { head = collapse(sel) } else { head = target(sel) }
        setSelection(extend ? (sel.anchor, head) : (head, head))
        goalX = nil
        revealCaret()
    }

    /// Up and down keep to the column the caret started in, as far as the lines passed allow.
    private func moveVertically(_ delta: Int, extend: Bool) {
        guard let editor, let sel = editSelection else { return }
        editor.closeGroup()
        let head = sel.head
        let x = goalX ?? xOffset(line: head.row, column: head.column)
        let row = head.row + delta
        let target: TextPosition
        if row < 0 {
            target = TextPosition(row: 0, column: 0)
        } else if row > lastRow {
            target = documentEnd
        } else {
            target = TextPosition(row: row, column: column(line: row, atX: x))
        }
        setSelection(extend ? (sel.anchor, target) : (target, target))
        goalX = x
        revealCaret()
    }

    private func movePage(_ direction: Int, extend: Bool) {
        let page = max(1, visibleLineCount - 2)
        container?.scrollBy(dx: 0, dy: CGFloat(direction * page) * codeFont.lineHeight)
        moveVertically(direction * page, extend: extend)
    }

    /// The caret's line with its line break, when nothing is selected (what ⌘C and ⌘X take then).
    func caretLineText() -> String? {
        guard editor != nil, let sel = editSelection, sel.anchor == sel.head, sel.head.row < lines.count else { return nil }
        return lines[sel.head.row] + "\n"
    }

    // MARK: Changing the text

    /// Replaces text, records it for undo and redraws; the caret goes after the new text unless told otherwise.
    @discardableResult
    private func replaceText(_ from: TextPosition, _ to: TextPosition, with text: String, kind: EditorSession.Kind,
                             caret: TextPosition? = nil) -> EditorSession.Outcome? {
        guard let editor, let before = editSelection else { return nil }
        var result: EditorSession.Outcome?
        performEdit(anchorLine: min(from, to).row) {
            let outcome = editor.replace(from: from, to: to, with: text, kind: kind, selection: before)
            result = outcome
            return [outcome]
        }
        guard let result else { return nil }
        setCaret(caret ?? result.end)
        goalX = nil
        revealCaret()
        delegate?.canvasDidEdit(self)
        return result
    }

    /// An edit a command makes for the user (a change rolled back): one undo step, with the caret at `caret`.
    func applyCommandEdit(from: TextPosition, to: TextPosition, text: String, caret: TextPosition?) {
        guard let editor else { return }
        commitComposition()
        if editSelection == nil { setCaret(from) }
        editor.closeGroup()
        replaceText(from, to, with: text, kind: .other, caret: caret)
    }

    /// Typed text, over the selection if there is one.
    private func typeText(_ text: String) {
        guard let sel = editSelection else { return }
        if vimModeEnabled && vimEngine.mode.isInsert { vimEngine.recordInsertedText(text) }
        let lower = min(sel.anchor, sel.head), upper = max(sel.anchor, sel.head)
        // A closing brace typed into a line of nothing but indentation steps out one level, as in the IDE.
        if lower == upper, text == "}", let unit = editor?.indentUnit {
            let before = (lines[lower.row] as NSString).substring(to: lower.column)
            let after = (lines[lower.row] as NSString).substring(from: lower.column)
            if before.hasSuffix(unit), before.utf8.allSatisfy({ $0 == 32 || $0 == 9 }), after.utf8.allSatisfy({ $0 == 32 || $0 == 9 }) {
                replaceText(TextPosition(row: lower.row, column: lower.column - unit.utf16.count), lower, with: text, kind: .typing)
                return
            }
        }
        replaceText(lower, upper, with: text, kind: text.contains("\n") || text.contains("\r") ? .other : .typing)
    }

    private func deleteSelection(orTo target: (TextPosition) -> TextPosition) {
        guard let sel = editSelection else { return }
        if vimModeEnabled && vimEngine.mode.isInsert { vimEngine.recordInsertBackspace() }
        if sel.anchor != sel.head {
            replaceText(sel.anchor, sel.head, with: "", kind: .other)
            return
        }
        let to = target(sel.head)
        guard to != sel.head else { NSSound.beep(); return }
        replaceText(sel.head, to, with: "", kind: .deleting)
    }

    /// ↩ keeps the indentation of the line, one level deeper after an opening bracket; between a pair of
    /// brackets the closing one moves to a line of its own.
    private func insertNewline() {
        guard let editor, let sel = editSelection else { return }
        if vimModeEnabled && vimEngine.mode.isInsert { vimEngine.recordInsertedText("\n") }
        var lower = min(sel.anchor, sel.head)
        var upper = max(sel.anchor, sel.head)
        let line = lines[lower.row] as NSString
        let before = line.substring(to: lower.column)
        var indent = TextEditing.indentation(of: lines[lower.row])
        if (indent as NSString).length > lower.column { indent = before }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        // A line left with nothing but indentation is left empty.
        if trimmed.isEmpty { lower = TextPosition(row: lower.row, column: 0) }
        let unit = editor.indentUnit
        let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]
        if let last = trimmed.last, let closer = pairs[last] {
            let rest = (lines[upper.row] as NSString).substring(from: upper.column)
            let spaces = rest.prefix { $0 == " " || $0 == "\t" }
            if rest.dropFirst(spaces.count).first == closer {
                upper = TextPosition(row: upper.row, column: upper.column + (String(spaces) as NSString).length)
                replaceText(lower, upper, with: "\n" + indent + unit + "\n" + indent, kind: .typing,
                            caret: TextPosition(row: lower.row + 1, column: (indent + unit).utf16.count))
                return
            }
            replaceText(lower, upper, with: "\n" + indent + unit, kind: .typing)
            return
        }
        replaceText(lower, upper, with: "\n" + indent, kind: .typing)
    }

    /// ⇥ indents: to the next tab stop at the caret, or every selected line by one level.
    private func insertTab() {
        guard let editor, let sel = editSelection else { return }
        guard sel.anchor == sel.head else { indentLines(outdent: false); return }
        let p = sel.head
        let unit = editor.indentUnit
        var text = unit
        if unit != "\t" {
            let width = max(1, unit.utf16.count)
            let visual = TextEditing.visualColumn(of: lines[p.row] as NSString, at: p.column)
            text = String(repeating: " ", count: width - visual % width)
        }
        replaceText(p, p, with: text, kind: .typing)
    }

    /// Indents or outdents every line the selection touches by one level, as one undo step.
    private func indentLines(outdent: Bool) {
        guard let editor, let sel = editSelection else { return }
        let lower = min(sel.anchor, sel.head), upper = max(sel.anchor, sel.head)
        var last = upper.row
        if upper.row > lower.row, upper.column == 0 { last -= 1 }
        let unit = editor.indentUnit
        let width = unit == "\t" ? 4 : max(1, unit.utf16.count)
        var edits: [(from: TextPosition, to: TextPosition, text: String)] = []
        var shifts: [Int: Int] = [:]
        // Bottom up, although no line comes or goes: each edit is given in the text as the ones before it left it.
        for row in (lower.row...last).reversed() {
            let line = lines[row] as NSString
            if outdent {
                var remove = 0
                if line.length > 0, line.character(at: 0) == 9 {
                    remove = 1
                } else {
                    while remove < width, remove < line.length, line.character(at: remove) == 32 { remove += 1 }
                }
                guard remove > 0 else { continue }
                edits.append((TextPosition(row: row, column: 0), TextPosition(row: row, column: remove), ""))
                shifts[row] = -remove
            } else {
                // Blank lines inside a block stay blank.
                guard line.length > 0 || lower.row == last else { continue }
                edits.append((TextPosition(row: row, column: 0), TextPosition(row: row, column: 0), unit))
                shifts[row] = unit.utf16.count
            }
        }
        guard !edits.isEmpty else { NSSound.beep(); return }
        func shifted(_ p: TextPosition) -> TextPosition {
            guard let delta = shifts[p.row] else { return p }
            if delta < 0 { return TextPosition(row: p.row, column: max(0, p.column + delta)) }
            // A selection of whole lines keeps starting at the start of its first line.
            return p.column == 0 && sel.anchor != sel.head ? p : TextPosition(row: p.row, column: p.column + delta)
        }
        let after = (shifted(sel.anchor), shifted(sel.head))
        performEdit(anchorLine: lower.row) { editor.replace(edits, selection: sel, after: after) }
        setSelection(after)
        goalX = nil
        revealCaret()
        delegate?.canvasDidEdit(self)
    }

    /// ⌘⌫, as in the IDE: deletes the lines the caret or the selection is on.
    func deleteLines() {
        guard let sel = editSelection else { return }
        let lower = min(sel.anchor, sel.head), upper = max(sel.anchor, sel.head)
        var last = upper.row
        if upper.row > lower.row, upper.column == 0 { last -= 1 }
        let x = goalX ?? xOffset(line: sel.head.row, column: sel.head.column)
        let from: TextPosition, to: TextPosition
        if last < lastRow {
            from = TextPosition(row: lower.row, column: 0)
            to = TextPosition(row: last + 1, column: 0)
        } else if lower.row > 0 {
            from = TextPosition(row: lower.row - 1, column: lineLength(lower.row - 1))
            to = TextPosition(row: last, column: lineLength(last))
        } else {
            from = TextPosition(row: 0, column: 0)
            to = TextPosition(row: last, column: lineLength(last))
        }
        guard from != to else { NSSound.beep(); return }
        replaceText(from, to, with: "", kind: .other)
        // The caret keeps its column, on the line that moved up into the deleted one's place.
        let row = min(lower.row, lastRow)
        setCaret(TextPosition(row: row, column: column(line: row, atX: x)))
        goalX = x
        revealCaret()
    }

    private func transpose() {
        guard let sel = editSelection, sel.anchor == sel.head else { NSSound.beep(); return }
        let p = sel.head
        let line = lines[p.row] as NSString
        guard line.length >= 2 else { NSSound.beep(); return }
        let middle = p.column >= line.length ? TextEditing.characterBoundary(in: line, from: line.length, forward: false) : max(1, p.column)
        let start = TextEditing.characterBoundary(in: line, from: middle, forward: false)
        let end = TextEditing.characterBoundary(in: line, from: middle, forward: true)
        guard start < middle, middle < end else { NSSound.beep(); return }
        let left = line.substring(with: NSRange(location: start, length: middle - start))
        let right = line.substring(with: NSRange(location: middle, length: end - middle))
        replaceText(TextPosition(row: p.row, column: start), TextPosition(row: p.row, column: end), with: right + left, kind: .other)
    }

    // MARK: Clipboard

    @objc func cut(_ sender: Any?) {
        guard editor != nil, let sel = editSelection else { NSSound.beep(); return }
        commitComposition()
        if sel.anchor == sel.head {
            // Nothing selected: the whole line, as in the IDE.
            guard let line = caretLineText() else { return }
            pasteboard.clearContents()
            pasteboard.setString(line, forType: .string)
            lineClipboard = line
            deleteLines()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(TextEditing.text(lines, from: sel.anchor, to: sel.head), forType: .string)
        lineClipboard = nil
        replaceText(sel.anchor, sel.head, with: "", kind: .other)
    }

    @objc func paste(_ sender: Any?) {
        guard editor != nil, editSelection != nil else { NSSound.beep(); return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        commitComposition()
        guard let sel = editSelection else { return }
        if let line = lineClipboard, line == text, sel.anchor == sel.head {
            // A line copied whole goes in as a line, above the caret's, and the caret stays on its text.
            let start = TextPosition(row: sel.head.row, column: 0)
            let added = TextEditing.lines(of: text).count - 1
            replaceText(start, start, with: text, kind: .other, caret: TextPosition(row: sel.head.row + added, column: sel.head.column))
            return
        }
        replaceText(sel.anchor, sel.head, with: text, kind: .other)
    }

    // MARK: Undo

    var canUndoTyping: Bool { editor?.canUndo == true || editor?.marked != nil }
    var canRedoTyping: Bool { editor?.canRedo == true }

    func undoTyping() {
        guard let editor else { return }
        commitComposition()
        guard editor.canUndo else { NSSound.beep(); return }
        stepHistory { editor.undo() }
    }

    func redoTyping() {
        guard let editor else { return }
        commitComposition()
        guard editor.canRedo else { NSSound.beep(); return }
        stepHistory { editor.redo() }
    }

    private func stepHistory(_ step: () -> (outcomes: [EditorSession.Outcome], selection: EditorSession.Selection)?) {
        var restored: EditorSession.Selection?
        performEdit(anchorLine: editSelection.map { min($0.anchor, $0.head).row } ?? 0) {
            guard let result = step() else { return [] }
            restored = result.selection
            return result.outcomes
        }
        guard let restored else { return }
        setSelection(restored)
        goalX = nil
        revealCaret()
        delegate?.canvasDidEdit(self)
    }

    // MARK: Text input client

    private static func plainString(_ string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Function keys arrive as characters of the private use area; they are not text.
        guard text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !(0xF700...0xF8FF).contains($0.value) })
        return String(scalars)
    }

    /// Ends a composition, keeping what was composed as typed text (a click elsewhere, the canvas losing
    /// the keyboard, a save).
    func commitComposition() {
        guard let taken = removeComposition() else { return }
        inputContext?.discardMarkedText()
        setCaret(taken.at)
        if !taken.text.isEmpty { typeText(taken.text) }
    }

    /// Takes the composition out of the text, unrecorded. Returns what it was and where it sat.
    private func removeComposition() -> (text: String, at: TextPosition)? {
        guard let editor, let marked = editor.marked else { return nil }
        var taken: (text: String, at: TextPosition)?
        performEdit(anchorLine: marked.row) {
            guard let removed = editor.removeMarked() else { return [] }
            taken = (removed.text, removed.at)
            return [removed.outcome]
        }
        return taken
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let editor else { return }
        let text = Self.plainString(string)
        if let taken = removeComposition() {
            setCaret(taken.at)
        } else if replacementRange.location != NSNotFound {
            setSelection((editor.position(ofOffset: replacementRange.location), editor.position(ofOffset: NSMaxRange(replacementRange))))
        }
        guard !text.isEmpty, editSelection != nil else { return }
        typeText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let editor else { return }
        let text = Self.plainString(string)
        if editor.marked == nil {
            guard !text.isEmpty else { return }
            if replacementRange.location != NSNotFound {
                setSelection((editor.position(ofOffset: replacementRange.location), editor.position(ofOffset: NSMaxRange(replacementRange))))
            }
            // Composing over a selection replaces it, as typing would.
            if let sel = editSelection, sel.anchor != sel.head {
                replaceText(sel.anchor, sel.head, with: "", kind: .typing)
            }
        }
        guard let sel = editSelection else { return }
        let start = editor.marked.map { TextPosition(row: $0.row, column: $0.range.lowerBound) } ?? min(sel.anchor, sel.head)
        performEdit(anchorLine: start.row) { [editor.setMarked(text, at: start)] }
        if let marked = editor.marked {
            let column = marked.range.lowerBound + min(max(0, selectedRange.location), marked.range.count)
            setCaret(TextPosition(row: marked.row, column: column))
        } else {
            setCaret(start)
        }
        revealCaret()
    }

    func unmarkText() {
        guard let taken = removeComposition() else { return }
        setCaret(taken.at)
        if !taken.text.isEmpty { typeText(taken.text) }
    }

    func selectedRange() -> NSRange {
        guard let editor, let sel = editSelection else { return NSRange(location: NSNotFound, length: 0) }
        let a = editor.offset(of: min(sel.anchor, sel.head)), b = editor.offset(of: max(sel.anchor, sel.head))
        return NSRange(location: a, length: b - a)
    }

    func markedRange() -> NSRange {
        guard let editor, let marked = editor.marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: editor.offset(of: TextPosition(row: marked.row, column: marked.range.lowerBound)), length: marked.range.count)
    }

    func hasMarkedText() -> Bool { editor?.marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let editor, range.location != NSNotFound else { return nil }
        let total = editor.totalLength
        let start = min(max(0, range.location), total)
        let end = min(total, start + min(max(0, range.length), 20_000))
        actualRange?.pointee = NSRange(location: start, length: end - start)
        let text = TextEditing.text(lines, from: editor.position(ofOffset: start), to: editor.position(ofOffset: end))
        return NSAttributedString(string: text, attributes: [.font: codeFont.font])
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    /// Where the input method puts its candidate window: under the composition.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let editor, let window else { return .zero }
        let location = range.location == NSNotFound ? selectedRange().location : range.location
        guard location != NSNotFound else { return .zero }
        let from = editor.position(ofOffset: location)
        var to = editor.position(ofOffset: location + max(0, range.length))
        if to.row != from.row { to = TextPosition(row: from.row, column: lineLength(from.row)) }
        let start = editor.offset(of: from)
        actualRange?.pointee = NSRange(location: start, length: editor.offset(of: to) - start)
        return window.convertToScreen(convert(viewRect(line: from.row, from: from.column, to: to.column), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let editor, let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let position = editPosition(at: local) else { return NSNotFound }
        return editor.offset(of: position)
    }

    // MARK: Vim bridge

    private func makeVimContext() -> VimContext? {
        guard let doc = document, case .text = doc.content, !doc.right.lines.isEmpty else { return nil }
        let currentLines = doc.right.lines
        let cursor = vimEngine.mode.isInsert ? (editSelection?.head ?? vimCursor) : vimCursor
        return VimContext(
            lines: currentLines,
            cursor: TextEditing.clamp(cursor, in: currentLines),
            isEditable: editor != nil,
            indentUnit: editor?.indentUnit ?? TextEditing.indentUnit(for: currentLines),
            commentPrefix: VimEngine.lineCommentPrefix(for: doc.language),
            visibleLineCount: visibleLineCount
        )
    }

    @discardableResult
    func handleVimKey(_ key: VimKey) -> Bool {
        guard vimModeEnabled, let context = makeVimContext() else { return false }
        let result = vimEngine.handleKey(key, context: context)
        guard result.handled else { return false }
        applyVimResult(result)
        return true
    }

    func vimExpandSelection() {
        guard let context = makeVimContext() else { return }
        let result = vimEngine.expandSelection(in: context)
        applyVimResult(result)
    }

    func vimShrinkSelection() {
        guard let context = makeVimContext() else { return }
        let result = vimEngine.shrinkSelection(in: context)
        applyVimResult(result)
    }

    private func applyVimResult(_ result: VimResult) {
        let nonEmptyEdits = result.edits.filter { $0.from != $0.to || !$0.text.isEmpty }
        if !nonEmptyEdits.isEmpty, let editor {
            commitComposition()
            if editSelection == nil { setCaret(vimCursor) }
            editor.closeGroup()
            if nonEmptyEdits.count == 1, let edit = nonEmptyEdits.first {
                replaceText(edit.from, edit.to, with: edit.text, kind: .other, caret: result.cursor)
            } else {
                let before = editSelection ?? (vimCursor, vimCursor)
                let tuples = nonEmptyEdits.map { ($0.from, $0.to, $0.text) }
                let targetCaret = result.cursor ?? vimCursor
                performEdit(anchorLine: nonEmptyEdits.map { min($0.from, $0.to).row }.min() ?? vimCursor.row) {
                    editor.replace(tuples, selection: before, after: (targetCaret, targetCaret))
                }
                setCaret(targetCaret)
                goalX = nil
                revealCaret()
                delegate?.canvasDidEdit(self)
            }
        }

        if !lines.isEmpty {
            isApplyingVimSelection = true
            defer { isApplyingVimSelection = false }

            if let vr = result.visualRange {
                let anchor = TextEditing.clamp(vr.anchor, in: lines)
                let head = TextEditing.clamp(vr.head, in: lines)
                vimCursor = head
                if vr.linewise {
                    let firstRow = min(anchor.row, head.row)
                    let lastRow = max(anchor.row, head.row)
                    let startPos = TextPosition(row: firstRow, column: 0)
                    let endPos = TextPosition(row: lastRow, column: lineLength(lastRow))
                    selection = TextSelection(pane: .right, anchor: rowPosition(startPos), head: rowPosition(endPos))
                } else {
                    let lo = min(anchor, head)
                    let hi = max(anchor, head)
                    let hiNS = lines[hi.row] as NSString
                    let hiEnd = hi.column < hiNS.length
                        ? TextEditing.characterBoundary(in: hiNS, from: hi.column, forward: true)
                        : hiNS.length
                    selection = TextSelection(
                        pane: .right,
                        anchor: rowPosition(lo),
                        head: rowPosition(TextPosition(row: hi.row, column: hiEnd))
                    )
                }
            } else if let newCursor = result.cursor {
                let clamped = TextEditing.clamp(newCursor, in: lines)
                vimCursor = clamped
                let rowPos = rowPosition(clamped)
                selection = TextSelection(pane: .right, anchor: rowPos, head: rowPos)
            } else if result.clearVisual {
                let clamped = TextEditing.clamp(vimCursor, in: lines)
                vimCursor = clamped
                let rowPos = rowPosition(clamped)
                selection = TextSelection(pane: .right, anchor: rowPos, head: rowPos)
            }
        }

        if result.cursor != nil || result.visualRange != nil || !result.edits.isEmpty {
            revealCaret()
        }
        refreshRelativeLineNumbersIfNeeded()
        // Force caret shape update (block <-> bar <-> replace underline) even if cursor stayed put.
        flushVimVisualState()
        reportVimStateIfNeeded(force: true)

        for action in result.actions {
            delegate?.canvas(self, performVimAction: action, line: vimCursor.row, column: vimCursor.column)
        }
    }

    private func flushVimVisualState() {
        // Trigger layer update for cursor shape changes on mode/replace transitions.
        needsDisplay = true
    }
}

extension CodeCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectedText() != nil || caretLineText() != nil
        case #selector(cut(_:)): return editSelection != nil
        case #selector(paste(_:)): return editSelection != nil && pasteboard.availableType(from: [.string]) != nil
        default: return true
        }
    }
}
