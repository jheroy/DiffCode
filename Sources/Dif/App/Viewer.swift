import AppKit
import Observation

/// Drives the diff/file viewer: loading documents, change navigation, in-file find.
///
/// Documents are pushed to the canvas imperatively rather than through SwiftUI state, so
/// stepping through files never pays for a view-tree diff.
@MainActor
@Observable
final class ViewerModel: CodeCanvasDelegate {
    var request: DiffRequest?
    var document: DiffDocument?
    var isLoading = false
    var hunkCount = 0
    var focusedHunk: Int?
    var loadMilliseconds: Double = 0
    /// Conflicts left in the file on screen, when it is one git is merging.
    var conflictCount = 0
    /// How long the last `git blame` took, for the debug hooks.
    @ObservationIgnored var blameMilliseconds: Double = 0

    var findVisible = false
    var findQuery = ""
    var findCount = 0
    var findIndex = 0
    var findFocusToken = 0

    @ObservationIgnored weak var container: CodeScrollContainer?
    @ObservationIgnored var settings: Settings!
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored var onStepFile: ((Int) -> Bool)?
    @ObservationIgnored var onToast: ((String) -> Void)?
    @ObservationIgnored var contextMenuProvider: (() -> NSMenu?)?
    @ObservationIgnored var onRevertHunk: ((Int) -> Void)?
    @ObservationIgnored var onToggleCommitHunk: ((Int) -> Void)?
    /// The document on screen was replaced, cleared or edited (its changes are new), or its request changed.
    @ObservationIgnored var onDocumentChanged: (() -> Void)?

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLine: Int?
    @ObservationIgnored private var landOnLastHunk = false
    @ObservationIgnored private var detachedFromFocus = false
    @ObservationIgnored private var armed: (delta: Int, at: Date)?
    @ObservationIgnored var signature: String?
    @ObservationIgnored private var magnification: CGFloat = 0

    // Editing the file on screen (see ViewerEditing.swift). Observed only where the header shows it.
    /// The text on screen has changes that are not in the file yet.
    var isDirty = false
    /// Why the working tree file on screen cannot be edited, when it cannot.
    var readOnlyReason: String?
    /// Moves on whenever the diff of the text being edited is recomputed, so the counts in the header follow.
    var diffRevision = 0
    @ObservationIgnored var editor: EditorSession?
    @ObservationIgnored var saveTimer: Timer?
    @ObservationIgnored var diffTimer: Timer?
    @ObservationIgnored var diffTask: Task<Void, Never>?
    /// Undo histories of files edited earlier, most recent last, so ⌘Z still works after coming back to one.
    @ObservationIgnored var histories: [(key: String, history: EditorSession.History)] = []
    /// Typing that could not be written when its file was left (the disk full, say), kept until the file is opened again.
    /// `announced`: the file was left with them (and told so), rather than read again.
    @ObservationIgnored var unsavedTexts: [(key: String, name: String, unsaved: EditorSession.Unsaved, announced: Bool)] = []
    /// The base the document on screen was loaded against.
    @ObservationIgnored var loadedStamp: String?
    @ObservationIgnored var onFileWritten: ((URL) -> Void)?
    @ObservationIgnored var observers: [NSObjectProtocol] = []

    // Annotate (see ViewerAnnotate.swift).
    /// Annotations are on: every file opened shows who last changed each line, until they are turned off.
    var annotating = false
    var isBlaming = false
    /// The commit of the line under the pointer in the Annotate column, and where its card goes.
    var annotationHover: AnnotationHover?
    @ObservationIgnored var blameTask: Task<Void, Never>?
    @ObservationIgnored var blameTimer: Timer?
    /// Width of the last column shown, kept for the next file so its text does not move when its blame arrives.
    @ObservationIgnored var annotationColumns: Int?
    /// A line's commit was clicked in the Annotate column.
    @ObservationIgnored var onOpenAnnotation: ((LineAnnotations.Entry) -> Void)?

    // LSP (see ViewerLSP.swift).
    @ObservationIgnored var lspManager: LSPManager = .shared
    @ObservationIgnored var lspDocument: ActiveLSPDocument?
    @ObservationIgnored var lspGeneration: UInt64 = 0
    @ObservationIgnored var lspTask: Task<Void, Never>?
    @ObservationIgnored var lspDebounceTimer: Timer?
    /// ⌘+Click on a symbol in an LSP-enabled pane (`line` is 0-based, `character` is 0-based UTF-16).
    @ObservationIgnored var onGoToDefinition: ((Int, Int) -> Void)?

    var canvasMode: CodeCanvasView.Mode { settings.unified ? .unified : .sideBySide }

    var isTextDocument: Bool {
        if let doc = document, case .text = doc.content { return true }
        return false
    }

    /// True when single changes of the document can be put back: a local change with both sides present.
    /// Not a file in conflict: its conflicts have buttons of their own, which take a whole conflict at a time.
    var canRevertHunks: Bool {
        guard let request, let doc = document, !isLoading, request.isAgainstHead, case .text = doc.content,
              !doc.isPlainFile, !doc.hunks.isEmpty else { return false }
        return request.kind == .modified || request.kind == .renamed
    }

    // MARK: Canvas attachment

    func attach(_ container: CodeScrollContainer) {
        self.container = container
        container.canvas.delegate = self
        container.canvas.codeFont = CodeFont.current(settings)
        container.onUserScroll = { [weak self] in self?.detachedFromFocus = true }
        container.show(document, mode: canvasMode, preserveScroll: false)
        container.canvas.showsRevertButtons = canRevertHunks
        container.canvas.editor = editor
        container.canvas.isLSPEnabled = isCurrentDocumentLSPEnabled
        if let doc = document { position(doc) }
        observeFocusChanges()
    }

    // MARK: Loading

    /// Shows `request`. A request that is already on screen is left alone unless a line is given.
    func open(_ request: DiffRequest, line: Int? = nil, preserveScroll: Bool = false) {
        if request == self.request {
            if let line, document != nil, !isLoading { reveal(line: line) } else if line != nil { pendingLine = line }
            return
        }
        if let current = self.request, let editor, editor.hasEdits, !isLoading,
           current.root == request.root, current.path == request.path {
            // The file being edited, asked for again because the typing changed its status: it left the list,
            // or came back. The text on screen is still right, and reloading it would only make it jump.
            if case .worktree(let a) = current.source, case .worktree(let b) = request.source, a == b, current.oldPath == request.oldPath,
               current.ignoreWhitespace == request.ignoreWhitespace {
                self.request = request
                container?.canvas.showsRevertButtons = canRevertHunks
                onDocumentChanged?()
            }
            if current.source == .file || request.source == .file || self.request == request {
                if let line { reveal(line: line) }
                reloadIfStale(base: baseStamp)
                return
            }
        }
        load(request, line: line, preserveScroll: preserveScroll)
    }

    func reload() {
        guard let request else { return }
        load(request, line: nil, preserveScroll: true)
    }

    /// Reloads when the file on disk (or the base revision) changed since it was loaded.
    ///
    /// While the file is being edited, a new date alone is not news (saving here changes it): only a change of
    /// what the file holds is. Then unsaved typing is never thrown away: the file's new text comes in as a step
    /// that ⌘Z takes back.
    func reloadIfStale(base: String?) {
        guard let request, !isLoading else { return }
        if case .commit = request.source { return }
        let current = Self.signature(for: request, base: base)
        guard current != signature else { return }
        guard let editor, document === editor.document else { reload(); return }
        let baseMoved = base != loadedStamp
        let data = Self.readFile(editor.url)
        if let data, TextCodec.fingerprint(data) == editor.diskFingerprint {
            // The file holds what was read or written here.
            if baseMoved {
                // Committed, say: the same text against a new base. Typing is written first; the history comes along.
                if saveEdits() { reload() }
            } else {
                signature = current
            }
            return
        }
        guard editor.isDirty || editor.marked != nil else {
            reload()
            return
        }
        guard let data else {
            signature = current
            onToast?(L("The file was deleted · your changes are kept here, not written", "文件已被删除 · 修改还在这里，没有写入"))
            return
        }
        takeDiskVersion(data)
        signature = current
        if baseMoved { reload() }
    }

    func clear() {
        saveEdits()
        loadTask?.cancel()
        blameTask?.cancel()
        closeLSPDocument()
        annotationHover = nil
        request = nil
        endEditing()
        document = nil
        isLoading = false
        hunkCount = 0
        focusedHunk = nil
        container?.show(nil, mode: canvasMode, preserveScroll: false)
        container?.canvas.showsRevertButtons = false
        container?.canvas.isLSPEnabled = false
        container?.canvas.conflicts = []
        conflictCount = 0
        onDocumentChanged?()
    }

    private(set) var baseStamp: String?

    func setBaseStamp(_ stamp: String?) { baseStamp = stamp }

    private func load(_ request: DiffRequest, line: Int?, preserveScroll: Bool) {
        // Leaving the text, or reading it again: what was typed goes to the file first.
        saveEdits()
        self.request = request
        pendingLine = line
        loadTask?.cancel()
        isLoading = true
        let stamp = baseStamp
        loadTask = Task { @MainActor [weak self] in
            let doc = await DiffLoader.load(request)
            guard let self, !Task.isCancelled, self.request == request else { return }
            self.signature = Self.signature(for: request, base: stamp)
            self.loadedStamp = stamp
            self.apply(doc, preserveScroll: preserveScroll)
        }
    }

    private func apply(_ doc: DiffDocument, preserveScroll: Bool) {
        // Typing that went on while this was loading.
        var caret: EditorSession.Selection?
        if let previous = editor, let request {
            let sameFile = previous.root == request.root && previous.path == request.path
            if previous.isDirty {
                let saved = saveEdits()
                if saved, sameFile {
                    // What was just read is older than what is on screen: read it again.
                    load(request, line: pendingLine, preserveScroll: true)
                    return
                }
            }
            if sameFile, preserveScroll { caret = container?.canvas.editSelection }
        }
        endEditing()
        document = doc
        isLoading = false
        hunkCount = doc.hunks.count
        loadMilliseconds = doc.loadMilliseconds
        let previousFocus = focusedHunk
        focusedHunk = nil
        armed = nil
        container?.show(doc, mode: canvasMode, preserveScroll: preserveScroll)
        container?.canvas.showsRevertButtons = canRevertHunks
        beginEditing(doc, caret: caret)
        syncLSPForCurrentDocument()
        refreshConflicts()
        annotationHover = nil
        if annotating { loadAnnotations() }
        if preserveScroll {
            if let previousFocus, previousFocus < doc.hunks.count {
                focusedHunk = previousFocus
                container?.canvas.focusedHunk = previousFocus
            }
        } else {
            position(doc)
        }
        if findVisible, !findQuery.isEmpty { runFind(reveal: false) }
        onDocumentChanged?()
    }

    /// Initial viewport: the requested line, else the first change (as IntelliJ does).
    private func position(_ doc: DiffDocument) {
        guard let container else { return }
        container.whenLaidOut { [weak self, weak container] in
            guard let self, let container, self.document === doc else { return }
            self.detachedFromFocus = false
            if let line = self.pendingLine {
                self.pendingLine = nil
                self.reveal(line: line)
            } else if !doc.hunks.isEmpty, case .text = doc.content, !doc.isPlainFile {
                let index = self.landOnLastHunk ? doc.hunks.count - 1 : 0
                self.focusedHunk = index
                container.canvas.focusedHunk = index
                // Ready to type where the change is, as the IDE's diff puts its caret there.
                container.canvas.placeCaret(line: doc.hunks[index].rightStart)
                let row = container.canvas.hunkRow(index)
                if row > container.visibleRowCount / 3 {
                    container.scroll(toRow: row, fraction: 0.2, animated: false)
                }
            } else if container.canvas.editSelection == nil {
                container.canvas.placeCaret(line: 0)
            }
            self.landOnLastHunk = false
        }
    }

    static func signature(for request: DiffRequest, base: String?) -> String {
        let url = request.root.appendingPathComponent(request.path)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? -1)|\(base ?? "")"
    }

    // MARK: Navigation

    /// Scrolls to a 1-based line of the new side and tints it.
    func reveal(line: Int) {
        guard let container, let doc = document, case .text = doc.content, !doc.right.lines.isEmpty else { return }
        let index = max(0, min(line - 1, doc.right.lines.count - 1))
        container.canvas.placeCaret(line: index)
        container.canvas.focusLine = (.right, index)
        container.scroll(toRow: container.canvas.row(forLine: index, side: .right), fraction: 0.35, animated: false)
        detachedFromFocus = true
    }

    func stepDifference(_ delta: Int) {
        guard let container, let doc = document, case .text = doc.content, !doc.hunks.isEmpty else {
            stepFileWithConfirmation(delta)
            return
        }
        let canvas = container.canvas
        let count = doc.hunks.count
        var target: Int
        if let current = focusedHunk, !detachedFromFocus {
            target = current + delta
        } else if delta > 0 {
            // After manual scrolling, continue from what is on screen rather than the old focus.
            let top = container.topRow
            target = (0..<count).first { canvas.hunkRow($0) > top } ?? count
        } else {
            let limit = container.topRow + container.visibleRowCount / 4
            target = (0..<count).last { canvas.hunkRow($0) < limit } ?? -1
        }
        guard target >= 0, target < count else {
            stepFileWithConfirmation(delta)
            return
        }
        armed = nil
        focus(hunk: target)
    }

    func focus(hunk index: Int, animated: Bool = true) {
        guard let container else { return }
        focusedHunk = index
        detachedFromFocus = false
        container.canvas.focusedHunk = index
        if let doc = document, doc.hunks.indices.contains(index) { container.canvas.placeCaret(line: doc.hunks[index].rightStart) }
        container.scroll(toRow: container.canvas.hunkRow(index), fraction: 0.25, animated: animated)
    }

    /// At the last change the first press only hints; a second press moves to the next file.
    private func stepFileWithConfirmation(_ delta: Int) {
        if hunkCount == 0 || (armed?.delta == delta && Date().timeIntervalSince(armed!.at) < 3) {
            armed = nil
            landOnLastHunk = delta < 0
            if onStepFile?(delta) != true {
                landOnLastHunk = false
                onToast?(delta > 0 ? L("No more changed files", "没有更多变更文件了") : L("Already at the first file", "已经是第一个文件"))
            }
        } else {
            armed = (delta, Date())
            onToast?(delta > 0
                ? L("Last change · press F7 again for the next file", "已是最后一处变更 · 再按 F7 进入下一个文件")
                : L("First change · press ⇧F7 again for the previous file", "已是第一处变更 · 再按 ⇧F7 回到上一个文件"))
        }
    }

    // MARK: View options

    func toggleUnified() {
        settings.unified.toggle()
        settings.save()
        guard let container else { return }
        let focused = focusedHunk
        container.setMode(canvasMode)
        if let focused, focused < hunkCount {
            container.scroll(toRow: container.canvas.hunkRow(focused), fraction: 0.25, animated: false)
        }
        if findVisible { runFind(reveal: false) }
    }

    func toggleWhitespace() {
        settings.ignoreWhitespace.toggle()
        settings.save()
        guard var request else { return }
        request.ignoreWhitespace = settings.ignoreWhitespace
        load(request, line: nil, preserveScroll: true)
    }

    func changeFontSize(by delta: Double) {
        let size = min(28, max(9, settings.fontSize + delta))
        guard size != settings.fontSize else { return }
        settings.fontSize = size
        settings.save()
        applyCodeFont()
    }

    /// Draws the code in the font Settings asks for now.
    func applyCodeFont() {
        container?.canvas.codeFont = CodeFont.current(settings)
    }

    func focusCanvas() {
        guard let container else { return }
        container.window?.makeFirstResponder(container.canvas)
    }

    // MARK: Find in file

    func showFind() {
        guard isTextDocument else { return }
        if let selected = container?.canvas.selectedText(), !selected.isEmpty, !selected.contains("\n") {
            findQuery = selected
        }
        findVisible = true
        findFocusToken += 1
        runFind(reveal: true)
    }

    func hideFind() {
        findVisible = false
        findCount = 0
        findIndex = 0
        container?.canvas.setHighlightedRanges([[:], [:]], navigation: [], current: -1)
        focusCanvas()
    }

    func runFind(reveal: Bool) {
        guard let container, let doc = document, case .text = doc.content, !findQuery.isEmpty else {
            findCount = 0
            findIndex = 0
            container?.canvas.setHighlightedRanges([[:], [:]], navigation: [], current: -1)
            return
        }
        let query = findQuery
        // Smart case: an uppercase letter in the query makes the search case-sensitive.
        let options: NSString.CompareOptions = query == query.lowercased() ? [.caseInsensitive] : []
        let queryBytes = query.utf8.count
        var bySide: [[Int: [Range<Int>]]] = [[:], [:]]
        var navigation: [(key: Double, match: SearchMatch)] = []

        for side in [Side.left, Side.right] {
            if side == .left, doc.isPlainFile { continue }
            let lines = doc.buffer(side).lines
            // The left side repeats every unchanged line; only its changed lines are navigation stops.
            var hunkIndex = 0
            for (index, line) in lines.enumerated() where line.utf8.count >= queryBytes {
                let text = line as NSString
                var ranges: [Range<Int>] = []
                var search = NSRange(location: 0, length: text.length)
                while search.length > 0 {
                    let found = text.range(of: query, options: options, range: search)
                    if found.location == NSNotFound { break }
                    ranges.append(found.location..<(found.location + found.length))
                    let next = found.location + max(1, found.length)
                    search = NSRange(location: next, length: max(0, text.length - next))
                }
                guard !ranges.isEmpty else { continue }
                bySide[side.rawValue][index] = ranges
                var isStop = side == .right
                if side == .left {
                    while hunkIndex < doc.hunks.count, doc.hunks[hunkIndex].leftStart + doc.hunks[hunkIndex].leftCount <= index { hunkIndex += 1 }
                    isStop = hunkIndex < doc.hunks.count && doc.hunks[hunkIndex].leftStart <= index
                }
                if isStop {
                    let key = doc.virtualPosition(of: index, side: side) + (side == .right ? 0.5 : 0)
                    for range in ranges { navigation.append((key, SearchMatch(side: side, line: index, range: range))) }
                }
            }
        }
        navigation.sort { $0.key != $1.key ? $0.key < $1.key : $0.match.range.lowerBound < $1.match.range.lowerBound }
        let list = navigation.map(\.match)

        // Start from the first match at or below the top of the viewport.
        var current = list.isEmpty ? -1 : 0
        let top = container.topRow
        if let ahead = list.firstIndex(where: { container.canvas.row(forLine: $0.line, side: $0.side) >= top }) { current = ahead }
        container.canvas.setHighlightedRanges(bySide, navigation: list, current: current)
        findCount = list.count
        findIndex = current + 1
        if reveal, current >= 0 { revealMatch(list[current]) }
    }

    func stepFind(_ delta: Int) {
        guard let canvas = container?.canvas, !canvas.matches.isEmpty else { return }
        let count = canvas.matches.count
        let next = ((canvas.currentMatch + delta) % count + count) % count
        canvas.setCurrentMatch(next)
        findIndex = next + 1
        revealMatch(canvas.matches[next])
    }

    private func revealMatch(_ match: SearchMatch) {
        guard let container else { return }
        let row = container.canvas.row(forLine: match.line, side: match.side)
        let top = container.topRow
        if row < top + 2 || row > top + container.visibleRowCount - 4 {
            container.scroll(toRow: row, fraction: 0.4, animated: true)
        }
        detachedFromFocus = true
    }

    // MARK: CodeCanvasDelegate

    func canvasDidRequestExit(_ canvas: CodeCanvasView) {
        if findVisible { hideFind() } else { onExit?() }
    }

    func canvasContextMenu(_ canvas: CodeCanvasView) -> NSMenu? { contextMenuProvider?() }

    func canvas(_ canvas: CodeCanvasView, resolveConflict index: Int, choice: ConflictChoice) {
        resolveConflict(index, choice: choice)
    }

    func canvas(_ canvas: CodeCanvasView, toggleCommitHunk index: Int) {
        onToggleCommitHunk?(index)
    }

    func canvas(_ canvas: CodeCanvasView, revertHunk index: Int) {
        guard canRevertHunks else { return }
        focusedHunk = index
        canvas.focusedHunk = index
        onRevertHunk?(index)
    }

    func canvas(_ canvas: CodeCanvasView, hoverAnnotation entry: LineAnnotations.Entry?, anchor: CGPoint) {
        let hover = entry.map { AnnotationHover(entry: $0, anchor: anchor) }
        if hover != annotationHover { annotationHover = hover }
    }

    func canvas(_ canvas: CodeCanvasView, openAnnotation entry: LineAnnotations.Entry) {
        annotationHover = nil
        onOpenAnnotation?(entry)
    }

    func canvas(_ canvas: CodeCanvasView, goToDefinitionAt line: Int, character: Int) {
        onGoToDefinition?(line, character)
    }

    func canvasDidMagnify(_ canvas: CodeCanvasView, by delta: CGFloat) {
        magnification += delta
        if abs(magnification) > 0.18 {
            changeFontSize(by: magnification > 0 ? 1 : -1)
            magnification = 0
        }
    }
}
