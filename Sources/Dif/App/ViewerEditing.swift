import AppKit

/// Editing the file on screen: starting and ending the editing session, writing the text back, keeping the
/// diff current while it changes, and never losing typing to a file that changed underneath.
extension ViewerModel {
    /// Idle time after the last keystroke before the text is written.
    static var saveDelay: TimeInterval = 1.0
    /// Idle time before the diff is worked out again (by git, on the exact bytes that would be written).
    static let diffDelay: TimeInterval = 0.15
    private static let historyLimit = 8

    // MARK: Session

    /// Starts editing a freshly loaded document if its right side can be edited, with the caret where it was
    /// and the history the same text had, if it was edited before.
    func beginEditing(_ doc: DiffDocument, caret: EditorSession.Selection?) {
        let reason = doc.editing?.readOnlyReason
        if readOnlyReason != reason { readOnlyReason = reason }
        guard let request, let canvas = container?.canvas else { return }
        let key = Self.historyKey(request.root, request.path)
        guard let session = EditorSession(document: doc, root: request.root, path: request.path,
                                          ignoreWhitespace: request.ignoreWhitespace) else {
            if let reason, unsavedTexts.contains(where: { $0.key == key }) {
                onToast?(L("Your unsaved changes to this file are still kept, but it cannot be edited now: \(reason)",
                           "这个文件没保存成功的修改还暂存着，但它现在不能编辑：\(reason)"))
            }
            return
        }
        if let index = histories.lastIndex(where: { $0.key == key }) {
            session.adopt(histories[index].history)
            histories.remove(at: index)
        }
        editor = session
        canvas.editor = session
        if let caret { canvas.setSelection(caret) }
        if let index = unsavedTexts.lastIndex(where: { $0.key == key }) {
            let entry = unsavedTexts.remove(at: index)
            resume(entry.unsaved, in: session, canvas: canvas, announce: entry.announced)
        }
    }

    /// Typing that could not be written comes back (when the file is opened again, or read again), and is written
    /// as soon as it can be.
    private func resume(_ unsaved: EditorSession.Unsaved, in session: EditorSession, canvas: CodeCanvasView, announce: Bool) {
        let caret = canvas.editSelection ?? (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0))
        var changedSince = false
        canvas.performEdit(anchorLine: caret.head.row) {
            let result = session.resume(unsaved, selection: caret)
            changedSince = result.changedSince
            return result.outcomes
        }
        canvas.setSelection(caret)
        canvasDidEdit(canvas)
        if changedSince {
            onToast?(L("Changed by another program after your changes could not be saved · its version is loaded; ⌘Z brings yours back",
                       "修改没保存成功之后，文件被其他程序改了，已载入新版本；⌘Z 找回你的修改"))
        } else if announce {
            onToast?(L("Your unsaved changes are back · saving again", "没保存成功的修改已恢复，正在重新保存"))
        }
    }

    /// Lets go of the session, keeping its history for when the file is opened again.
    func endEditing() {
        saveTimer?.invalidate()
        saveTimer = nil
        diffTimer?.invalidate()
        diffTimer = nil
        diffTask?.cancel()
        diffTask = nil
        if let editor {
            container?.canvas.commitComposition()
            let key = Self.historyKey(editor.root, editor.path)
            if let history = editor.history {
                histories.removeAll { $0.key == key }
                histories.append((key, history))
                if histories.count > Self.historyLimit { histories.removeFirst(histories.count - Self.historyLimit) }
            } else if let unsaved = editor.unsaved {
                // Writing it failed (what went wrong was shown): it is kept, not thrown away with the session.
                let name = (editor.path as NSString).lastPathComponent
                let leaving = request.map { $0.root != editor.root || $0.path != editor.path } ?? true
                unsavedTexts.removeAll { $0.key == key }
                unsavedTexts.append((key, name, unsaved, leaving))
                if leaving {
                    onToast?(L("Changes to \(name) could not be saved · they are kept and come back when you open it again",
                               "“\(name)”的修改没能保存，已暂存；再次打开它时会恢复"))
                }
            }
        }
        editor = nil
        container?.canvas.editor = nil
        if isDirty { isDirty = false }
    }

    private static func historyKey(_ root: URL, _ path: String) -> String { root.path + "\u{0}" + path }

    /// Whether the viewer is editing `path` of the repository at `root` and has changed it since it was opened.
    func isEditing(root: URL, path: String) -> Bool {
        guard let editor, editor.hasEdits, let request else { return false }
        return request.root == root && request.path == path
    }

    var canEdit: Bool { editor != nil }

    private func updateDirty() {
        let dirty = editor?.isDirty ?? false
        if dirty != isDirty { isDirty = dirty }
    }

    // MARK: Canvas

    func canvasDidEdit(_ canvas: CodeCanvasView) {
        updateDirty()
        refreshConflicts()
        if let doc = document, hunkCount != doc.hunks.count { hunkCount = doc.hunks.count }
        if let focused = focusedHunk, focused >= hunkCount { focusedHunk = nil }
        scheduleSave()
        scheduleDiff()
        scheduleLSPChange()
    }

    // MARK: Writing

    /// Writes the text after a pause in the typing (not while an input method is still composing).
    func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let editor = self.editor else { return }
                if editor.marked != nil { self.scheduleSave(); return }
                self.saveEdits()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    /// ⌘S: writes now.
    func saveNow() {
        guard editor != nil else {
            if let reason = readOnlyReason { onToast?(reason) }
            return
        }
        saveEdits()
    }

    /// Writes the text on screen to the file, if anything in it is not written yet. Returns false when it could
    /// not be written (what happened is shown), true when it was written or there was nothing to write.
    ///
    /// The file must still hold what was last read or written here; if something else changed it, its version
    /// comes in instead, and ⌘Z brings back what was typed. Written in place, so the file keeps its permissions
    /// and whatever watches it sees an edit.
    @discardableResult
    func saveEdits() -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let editor, let request else { return true }
        container?.canvas.commitComposition()
        guard editor.isDirty else { return true }
        guard let data = editor.encoded() else {
            onToast?(L("Not saved: the text cannot be written in the file's encoding", "没有保存：内容无法用文件原来的编码写入"))
            return false
        }
        let fingerprint = TextCodec.fingerprint(data)
        if fingerprint == editor.diskFingerprint {
            // Typed and undone back to what the file holds.
            editor.markSaved()
            updateDirty()
            return true
        }
        guard let current = Self.readFile(editor.url) else {
            onToast?(L("Not saved: the file is gone", "没有保存：文件已经不在了"))
            return false
        }
        guard TextCodec.fingerprint(current) == editor.diskFingerprint else {
            takeDiskVersion(current)
            return false
        }
        do {
            let handle = try FileHandle(forWritingTo: editor.url)
            defer { try? handle.close() }
            // New bytes over the old, then cut to length: at no moment is the file empty.
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
        } catch {
            onToast?(L("Not saved: \(error.localizedDescription)", "保存失败：\(error.localizedDescription)"))
            return false
        }
        editor.didWrite(data)
        // Its new date is this save's, not news to reload for.
        signature = Self.signature(for: request, base: loadedStamp)
        updateDirty()
        onFileWritten?(request.root)
        notifyLSPSaved()
        // Who changed what is worked out again from the file as written.
        if annotating { scheduleAnnotations() }
        return true
    }

    /// The file changed underneath unsaved typing: its version replaces the text, as a step ⌘Z takes back.
    func takeDiskVersion(_ data: Data) {
        guard let editor, let canvas = container?.canvas else { return }
        guard data.count <= TextEditing.maxEditableBytes, let text = TextCodec.decodeForEditing(data),
              !text.lines.contains(where: { $0.utf8.count > TextEditing.maxLineBytes }) else {
            // It became something that cannot be edited here; show it as it is now.
            editor.markSaved()
            onToast?(L("The file was changed by another program and can no longer be edited here", "文件被其他程序改成了无法在这里编辑的内容"))
            reload()
            return
        }
        canvas.commitComposition()
        let caret = canvas.editSelection ?? (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0))
        canvas.performEdit(anchorLine: caret.head.row) { [editor.takeDiskVersion(text, data: data, selection: caret)] }
        canvas.setSelection(caret)
        updateDirty()
        if let doc = document, hunkCount != doc.hunks.count { hunkCount = doc.hunks.count }
        scheduleDiff()
        scheduleLSPChange()
        onToast?(L("Changed by another program · its version is loaded; ⌘Z brings yours back",
                   "文件被其他程序改了，已载入新版本；⌘Z 找回你的修改"))
    }

    static func readFile(_ url: URL) -> Data? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Saves when the window loses the keyboard or the app goes to the background, as the IDE does.
    func observeFocusChanges() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.saveEdits() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let self, let window, window === self.container?.window else { return }
                self.saveEdits()
            }
        })
    }

    // MARK: Keeping the diff current

    /// Works the diff out again after a pause in the typing. Until then the changes are moved along by the edits.
    func scheduleDiff() {
        diffTimer?.invalidate()
        let timer = Timer(timeInterval: Self.diffDelay, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.rediff() } }
        RunLoop.main.add(timer, forMode: .common)
        diffTimer = timer
    }

    private func rediff() {
        guard let editor, let doc = document, doc === editor.document, !doc.isPlainFile else { return }
        if editor.marked != nil {
            scheduleDiff()
            return
        }
        guard let data = editor.encoded() else { return }
        let version = editor.version
        let base = editor.base
        let ignoreWhitespace = editor.ignoreWhitespace
        diffTask?.cancel()
        diffTask = Task { @MainActor [weak self] in
            var computed: [Hunk]?
            if base != nil { computed = await DiffLoader.computeHunks(old: base, new: data, ignoreWhitespace: ignoreWhitespace) }
            guard let self, !Task.isCancelled, let editor = self.editor, editor.version == version, editor.document === doc else { return }
            var hunks: [Hunk]
            if base == nil {
                // A new file: every line is added; an empty one has nothing to show.
                hunks = data.isEmpty ? [] : [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: doc.right.lines.count)]
            } else if let computed {
                hunks = computed
            } else {
                return
            }
            DiffLoader.addInlineHighlights(&hunks, left: doc.left.lines, right: doc.right.lines)
            self.container?.canvas.hunksDidChange { doc.setHunks(hunks) }
            doc.note = DiffLoader.note(hunks: doc.hunks, old: base, new: data, ignoreWhitespace: ignoreWhitespace)
            if self.hunkCount != doc.hunks.count { self.hunkCount = doc.hunks.count }
            if let focused = self.focusedHunk, focused >= doc.hunks.count {
                self.focusedHunk = nil
                self.container?.canvas.focusedHunk = nil
            }
            self.diffRevision += 1
            self.onDocumentChanged?()
            if self.findVisible, !self.findQuery.isEmpty { self.runFind(reveal: false) }
        }
    }

    // MARK: Conflicts

    /// A file git is merging, shown against one of its versions: its conflict markers get buttons.
    var showsConflicts: Bool {
        guard let request, request.kind == .conflicted, case .worktree = request.source else { return false }
        return true
    }

    /// Finds the conflicts in the text on screen again (after it loaded, or was edited).
    func refreshConflicts() {
        let blocks = showsConflicts ? ConflictBlock.find(in: document?.right.lines ?? []) : []
        container?.canvas.conflicts = blocks
        if conflictCount != blocks.count { conflictCount = blocks.count }
    }

    /// Replaces conflict `index` with HEAD's lines, the incoming ones, or both: an edit of the text, which ⌘Z takes back.
    func resolveConflict(_ index: Int, choice: ConflictChoice) {
        guard let editor, let canvas = container?.canvas, let doc = document, doc === editor.document else {
            onToast?(readOnlyReason ?? L("This file cannot be edited here", "这个文件无法在这里编辑"))
            return
        }
        canvas.commitComposition()
        let lines = doc.right.lines
        let blocks = ConflictBlock.find(in: lines)
        guard blocks.indices.contains(index) else { return }
        let block = blocks[index]
        let replacement = block.resolution(choice, in: lines)
        func end(_ row: Int) -> TextPosition { TextPosition(row: row, column: lines[row].utf16.count) }
        let from: TextPosition, to: TextPosition, text: String
        if !replacement.isEmpty {
            (from, to, text) = (TextPosition(row: block.start, column: 0), end(block.end), replacement.joined(separator: "\n"))
        } else if block.end < lines.count - 1 {
            (from, to, text) = (TextPosition(row: block.start, column: 0), TextPosition(row: block.end + 1, column: 0), "")
        } else if block.start > 0 {
            (from, to, text) = (end(block.start - 1), end(block.end), "")
        } else {
            (from, to, text) = (TextPosition(row: 0, column: 0), end(block.end), "")
        }
        canvas.applyCommandEdit(from: from, to: to, text: text, caret: from)
        updateDirty()
        scheduleDiff()
        refreshConflicts()
        saveEdits()
    }

    // MARK: Rolling back a change

    /// Puts change `index` back the way the left side has it, as an edit of the text (⌘Z in the editor takes it
    /// back), and writes the file. Returns false when it could not be done or written.
    func revertHunkInEditor(_ index: Int) -> Bool {
        guard let editor, let canvas = container?.canvas, let doc = document, doc === editor.document,
              doc.hunks.indices.contains(index) else { return false }
        canvas.commitComposition()
        let hunk = doc.hunks[index]
        let left = Array(doc.left.lines[hunk.leftStart..<(hunk.leftStart + hunk.leftCount)])
        let right = doc.right.lines
        let lastRow = right.count - 1
        func end(_ row: Int) -> TextPosition { TextPosition(row: row, column: right[row].utf16.count) }
        let from: TextPosition, to: TextPosition, text: String
        if hunk.rightCount > 0 {
            let first = hunk.rightStart, last = hunk.rightStart + hunk.rightCount - 1
            if hunk.leftCount > 0 {
                (from, to, text) = (TextPosition(row: first, column: 0), end(last), left.joined(separator: "\n"))
            } else if last < lastRow {
                (from, to, text) = (TextPosition(row: first, column: 0), TextPosition(row: last + 1, column: 0), "")
            } else if first > 0 {
                (from, to, text) = (end(first - 1), end(last), "")
            } else {
                (from, to, text) = (TextPosition(row: 0, column: 0), end(last), "")
            }
        } else if right.count == 1, right[0].isEmpty {
            // Everything was deleted: the file's one empty line becomes the old lines.
            (from, to, text) = (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0), left.joined(separator: "\n"))
        } else if hunk.rightStart <= lastRow {
            let at = TextPosition(row: hunk.rightStart, column: 0)
            (from, to, text) = (at, at, left.joined(separator: "\n") + "\n")
        } else {
            (from, to, text) = (end(lastRow), end(lastRow), "\n" + left.joined(separator: "\n"))
        }
        canvas.applyCommandEdit(from: from, to: to, text: text, caret: from)
        // At the end of the file, whether it ends with a line break is part of the change too.
        if hunk.rightStart + hunk.rightCount >= right.count || hunk.leftStart + hunk.leftCount >= doc.left.lines.count,
           let base = editor.base {
            let final = TextCodec.decodeForEditing(base)?.format.finalNewline ?? (base.last == 0x0A)
            editor.setFinalNewline(final)
        }
        updateDirty()
        scheduleDiff()
        return saveEdits()
    }

    /// Whether the text on screen is, byte for byte, its left side (a change rolled back was the last one).
    var textMatchesBase: Bool {
        guard let editor, let base = editor.base, !editor.isDirty, let data = editor.encoded() else { return false }
        return data == base
    }

    /// The toast's Undo after a change was rolled back in the editor.
    func undoInEditor() {
        guard let canvas = container?.canvas, editor != nil else { return }
        canvas.undoTyping()
        saveEdits()
        focusCanvas()
    }
}
