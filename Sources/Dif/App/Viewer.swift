import AppKit
import Observation

/// Resolves and steps through occurrences of the identifier under the cursor (`⌃⌥↓` / `⌃⌥↑`).
enum SymbolOccurrenceNavigator {
    /// Whole-identifier, case-sensitive occurrences of `symbolName` in `lines`.
    static func wholeWordOccurrences(of symbolName: String, in lines: [String], side: Side = .right) -> [SearchMatch] {
        guard !symbolName.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for (lineIndex, line) in lines.enumerated() {
            for range in LSPNavigationHelper.identifierRanges(of: symbolName, in: line) {
                matches.append(SearchMatch(side: side, line: lineIndex, range: range))
            }
        }
        return matches
    }

    /// Converts single-line LSP `documentHighlight` ranges into sorted, deduplicated `SearchMatch` entries.
    static func matches(from highlights: [LSPDocumentHighlight], in lines: [String], side: Side = .right) -> [SearchMatch] {
        var result: [SearchMatch] = []
        result.reserveCapacity(highlights.count)
        for item in highlights {
            let line = item.range.start.line
            guard item.range.end.line == line, line >= 0, line < lines.count else { continue }
            let length = (lines[line] as NSString).length
            let start = max(0, min(item.range.start.character, length))
            let end = max(0, min(item.range.end.character, length))
            guard end > start else { continue }
            result.append(SearchMatch(side: side, line: line, range: start..<end))
        }
        result.sort { lhs, rhs in
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound < rhs.range.lowerBound }
            return lhs.range.upperBound < rhs.range.upperBound
        }
        var deduped: [SearchMatch] = []
        deduped.reserveCapacity(result.count)
        for match in result where deduped.last != match {
            deduped.append(match)
        }
        return deduped
    }

    /// Returns `true` when `(line, column)` or `symbolRange` lies inside/at the edge of any occurrence in `matches`.
    static func contains(line: Int, column: Int, symbolRange: Range<Int>?, in matches: [SearchMatch]) -> Bool {
        for match in matches where match.line == line {
            if column >= match.range.lowerBound && column <= match.range.upperBound {
                return true
            }
            if let sym = symbolRange, sym.lowerBound < match.range.upperBound && match.range.lowerBound < sym.upperBound {
                return true
            }
        }
        return false
    }

    /// Returns the wrap-around next (`forward == true`) or previous (`forward == false`) match index from `(line, column)`.
    static func targetIndex(in matches: [SearchMatch], fromLine line: Int, column: Int, forward: Bool) -> Int? {
        guard !matches.isEmpty else { return nil }
        if let currentIndex = matches.firstIndex(where: {
            $0.line == line && column >= $0.range.lowerBound && column < $0.range.upperBound
        }) ?? matches.firstIndex(where: {
            $0.line == line && column == $0.range.upperBound
        }) {
            return (currentIndex + (forward ? 1 : -1) + matches.count) % matches.count
        }
        if forward {
            return matches.firstIndex(where: {
                $0.line > line || ($0.line == line && $0.range.lowerBound > column)
            }) ?? 0
        }
        return matches.lastIndex(where: {
            $0.line < line || ($0.line == line && $0.range.upperBound <= column)
        }) ?? (matches.count - 1)
    }

    /// Maps `documentHighlight` ranges resolved on `diskLines` onto `snapshotLines` (e.g. left pane or historical commit)
    /// without expanding beyond the highlights returned by the language server.
    static func mapHighlightsToSnapshot(
        _ highlights: [LSPDocumentHighlight],
        diskLines: [String],
        snapshotLines: [String],
        symbolName: String,
        side: Side = .right
    ) -> [SearchMatch] {
        if diskLines == snapshotLines {
            return matches(from: highlights, in: snapshotLines, side: side)
        }
        guard let aligned = Myers.matches(diskLines, snapshotLines, maxEdits: 4000) else {
            return []
        }

        var diskToSnap: [Int: Int] = [:]
        var hunks: [(disk: Range<Int>, snap: Range<Int>)] = []
        var i = 0
        var j = 0
        let m = diskLines.count
        let n = snapshotLines.count
        while i < m || j < n {
            if i < m, j < n, aligned.a[i], aligned.b[j] {
                diskToSnap[i] = j
                i += 1
                j += 1
            } else {
                let dStart = i
                let sStart = j
                while i < m, !aligned.a[i] { i += 1 }
                while j < n, !aligned.b[j] { j += 1 }
                hunks.append((dStart..<i, sStart..<j))
            }
        }

        var result: [SearchMatch] = []
        result.reserveCapacity(highlights.count)
        for item in highlights {
            let diskLine = item.range.start.line
            guard item.range.end.line == diskLine, diskLines.indices.contains(diskLine) else { continue }
            if let snapLine = diskToSnap[diskLine] {
                let length = (snapshotLines[snapLine] as NSString).length
                let start = max(0, min(item.range.start.character, length))
                let end = max(0, min(item.range.end.character, length))
                if end > start {
                    result.append(SearchMatch(side: side, line: snapLine, range: start..<end))
                }
            } else if let hunk = hunks.first(where: { $0.disk.contains(diskLine) }),
                      !hunk.snap.isEmpty,
                      !symbolName.isEmpty {
                let trimmedDisk = diskLines[diskLine].trimmingCharacters(in: .whitespacesAndNewlines)
                let expectedSnapOffset = diskLine - hunk.disk.lowerBound
                var bestSnapLine: Int?
                var bestRanges: [Range<Int>] = []
                var bestDistance = Int.max

                for snapLine in hunk.snap {
                    guard snapshotLines[snapLine].trimmingCharacters(in: .whitespacesAndNewlines) == trimmedDisk else { continue }
                    let ranges = LSPNavigationHelper.identifierRanges(of: symbolName, in: snapshotLines[snapLine])
                    guard !ranges.isEmpty else { continue }
                    let dist = abs((snapLine - hunk.snap.lowerBound) - expectedSnapOffset)
                    if dist < bestDistance {
                        bestDistance = dist
                        bestSnapLine = snapLine
                        bestRanges = ranges
                    }
                }

                if bestSnapLine == nil, hunk.disk.count == hunk.snap.count {
                    let candidate = hunk.snap.lowerBound + expectedSnapOffset
                    let ranges = LSPNavigationHelper.identifierRanges(of: symbolName, in: snapshotLines[candidate])
                    if !ranges.isEmpty {
                        bestSnapLine = candidate
                        bestRanges = ranges
                    }
                }

                if let snapLine = bestSnapLine,
                   let chosen = bestRanges.min(by: {
                       abs($0.lowerBound - item.range.start.character) < abs($1.lowerBound - item.range.start.character)
                   }) {
                    result.append(SearchMatch(side: side, line: snapLine, range: chosen))
                }
            }
        }

        result.sort { lhs, rhs in
            if lhs.line != rhs.line { return lhs.line < rhs.line }
            if lhs.range.lowerBound != rhs.range.lowerBound { return lhs.range.lowerBound < rhs.range.lowerBound }
            return lhs.range.upperBound < rhs.range.upperBound
        }
        var deduped: [SearchMatch] = []
        deduped.reserveCapacity(result.count)
        for match in result where deduped.last != match {
            deduped.append(match)
        }
        return deduped
    }
}

/// Drives the diff/file viewer: loading documents, change navigation, in-file find.
///
/// Documents are pushed to the canvas imperatively rather than through SwiftUI state, so
/// stepping through files never pays for a view-tree diff.
@MainActor
@Observable
final class ViewerModel: CodeCanvasDelegate {
    var request: DiffRequest?
    var document: DiffDocument? {
        didSet {
            if document !== oldValue {
                activeLineDiffLocation = nil
            }
        }
    }
    var isLoading = false
    var hunkCount = 0
    var focusedHunk: Int?
    var loadMilliseconds: Double = 0
    /// Paired Left/Right line snapshot for the bottom Beyond Compare-style inline line diff bar.
    var lineDiffSnapshot: LineDiffSnapshot?
    /// Last active `(side, 0-based line)` reported by the canvas or navigation, retained across syntax/diff refreshes.
    @ObservationIgnored private var activeLineDiffLocation: (side: Side, line: Int)?
    /// Conflicts left in the file on screen, when it is one git is merging.
    var conflictCount = 0
    /// Segments temporarily expanded while `collapseUnchanged` is enabled (cleared on file switch or reload).
    var expandedFoldSegments: Set<Int> = []
    /// Hunk indices included by the active AI group filter, or `nil` when showing the full diff.
    var highlightedGroupHunks: Set<Int>?
    /// Group filter that was applied to the currently loaded/loading document.
    @ObservationIgnored private var loadedGroupHunks: Set<Int>?
    /// Raw hunk focus requested right before a group filter update arrives for the same file.
    @ObservationIgnored private var pendingRawHunkFocus: (path: String, rawIndex: Int, at: Date)?
    /// Symbols in the current file whose span overlaps at least one diff hunk.
    var changedSymbols: [ChangedFileSymbol] = []
    /// How long the last `git blame` took, for the debug hooks.
    @ObservationIgnored var blameMilliseconds: Double = 0

    var findVisible = false
    var findQuery = ""
    var findCount = 0
    var findIndex = 0
    var findFocusToken = 0

    // Vim mode (decoupled from Settings.swift so Settings.vimMode can drive these after merge).
    var vimModeEnabled: Bool = true {
        didSet {
            guard vimModeEnabled != oldValue else { return }
            container?.canvas.vimModeEnabled = vimModeEnabled
        }
    }
    var vimRelativeLineNumbers: Bool = false {
        didSet {
            guard vimRelativeLineNumbers != oldValue else { return }
            container?.canvas.vimRelativeLineNumbers = vimRelativeLineNumbers
        }
    }
    var vimCursorColorHex: String? = nil {
        didSet {
            guard vimCursorColorHex != oldValue else { return }
            container?.canvas.vimCursorColor = vimCursorColorHex.flatMap(NSColor.fromHex)?.cgColor
        }
    }
    var vimMode: VimMode = .normal
    var vimPendingKeys = ""
    var vimCursorLine = 1
    var vimCursorColumn = 1

    @ObservationIgnored weak var container: CodeScrollContainer?
    @ObservationIgnored var settings: Settings! {
        didSet {
            syncVimSettings()
            syncStickyLinesSettings()
        }
    }
    @ObservationIgnored var onExit: (() -> Void)?
    @ObservationIgnored var onStepFile: ((Int) -> Bool)?
    @ObservationIgnored var onToast: ((String) -> Void)?
    @ObservationIgnored var contextMenuProvider: (() -> NSMenu?)?
    @ObservationIgnored var onRevertHunk: ((Int) -> Void)?
    @ObservationIgnored var onToggleCommitHunk: ((Int) -> Void)?
    /// The document on screen was replaced, cleared or edited (its changes are new), or its request changed.
    @ObservationIgnored var onDocumentChanged: (() -> Void)?
    /// App-level Vim action dispatched from the canvas (`line` is 0-based, `column` is 0-based UTF-16).
    @ObservationIgnored var onVimAction: ((VimAction, Int, Int) -> Void)?
    /// Records an in-file jump origin (`line` is 0-based, `column` is 0-based UTF-16) on the unified jump list.
    @ObservationIgnored var onRecordJump: ((Int, Int) -> Void)?
    /// Fires before leaving an already-loaded file for a different file (`previousRequest`, 0-based line, 0-based UTF-16 column).
    @ObservationIgnored var onWillSwitchFile: ((DiffRequest, Int, Int) -> Void)?

    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingLine: Int?
    @ObservationIgnored private var pendingColumn: Int?
    @ObservationIgnored private var findOrigin: TextPosition?
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
    @ObservationIgnored var onCodeFontChanged: (() -> Void)?
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
    @ObservationIgnored var lspLifecycleTask: Task<Void, Never>?
    @ObservationIgnored var lspTask: Task<Void, Never>?
    @ObservationIgnored var lspDebounceTimer: Timer?
    /// ⌘+Click on a symbol in an LSP-enabled pane (`line` is 0-based, `character` is 0-based UTF-16).
    @ObservationIgnored var onGoToDefinition: ((Int, Int) -> Void)?
    @ObservationIgnored var symbolHighlightTask: Task<Void, Never>?
    @ObservationIgnored private var symbolHighlightGeneration: UInt64 = 0
    @ObservationIgnored private var symbolOccurrenceCache: (docID: ObjectIdentifier, diffRevision: Int, side: Side, symbolName: String, isSemantic: Bool, matches: [SearchMatch])?

    // Spreadsheet viewer (see ExcelViewerView.swift).
    /// Target sheet name requested before (or while) an `.xlsx` workbook finishes loading.
    var pendingExcelSheet: String?
    /// Bumped on every `selectExcelSheet(_:)` call so `ExcelViewerView` reacts even for repeated requests.
    var excelSheetSelectToken: Int = 0
    /// Per-file spreadsheet UI sessions (sheet selection, search, pinned rows, visible columns) preserved across reloads.
    @ObservationIgnored var excelSessions: [String: ExcelViewerState] = [:]

    var canvasMode: CodeCanvasView.Mode { settings.unified ? .unified : .sideBySide }

    var isTextDocument: Bool {
        if let doc = document, case .text = doc.content { return true }
        return false
    }

    var isSpreadsheet: Bool {
        if let doc = document, case .spreadsheet = doc.content { return true }
        return false
    }

    func excelSessionKey(for fileURL: URL? = nil) -> String {
        if let request {
            switch request.source {
            case .commit(let hash, _):
                return "commit:\(hash):\(request.root.standardizedFileURL.path)/\(request.path)"
            case .commitSteps(let steps):
                let hash = steps.last?.hash ?? ""
                return "commit:\(hash):\(request.root.standardizedFileURL.path)/\(request.path)"
            default:
                break
            }
        }
        if let url = fileURL ?? request?.fileURL {
            return url.standardizedFileURL.path
        }
        return request?.path ?? ""
    }

    var activeExcelSession: ExcelViewerState? {
        guard let doc = document, case .spreadsheet(_, let fileURL) = doc.content else { return nil }
        return excelSessions[excelSessionKey(for: fileURL)]
    }

    func excelSession(for key: String, workbook: XLSXWorkbook, fileURL: URL?) -> ExcelViewerState {
        if let existing = excelSessions[key] {
            if existing.fileURL != fileURL {
                existing.fileURL = fileURL
            }
            return existing
        }
        let session = ExcelViewerState(workbook: workbook, fileURL: fileURL)
        excelSessions[key] = session
        return session
    }

    func selectExcelSheet(_ name: String) {
        pendingExcelSheet = name
        excelSheetSelectToken += 1
        if !isLoading, let session = activeExcelSession {
            _ = session.selectSheet(named: name)
            pendingExcelSheet = nil
        }
    }

    /// True when single changes of the document can be put back: a local change with both sides present.
    /// Not a file in conflict: its conflicts have buttons of their own, which take a whole conflict at a time.
    var canRevertHunks: Bool {
        guard let request, let doc = document, !isLoading, request.isAgainstHead, case .text = doc.content,
              !doc.isPlainFile, !doc.isJSONNormalized, !doc.isGroupFiltered, !doc.hunks.isEmpty else { return false }
        return request.kind == .modified || request.kind == .renamed
    }

    var isJSONDocument: Bool {
        guard let request else { return false }
        return SemanticDiff.isJSONFile(language: document?.language ?? .plain, path: request.path)
    }

    var movedPairCount: Int {
        guard let doc = document, case .text = doc.content else { return 0 }
        return doc.hunks.reduce(0) { $0 + ($1.moveInfo?.role == .source ? 1 : 0) }
    }

    var activeFoldRegions: [DiffFoldRegion] {
        guard let doc = document, case .text = doc.content, !doc.isPlainFile, !doc.isAddedOnly,
              settings?.collapseUnchanged == true else { return [] }
        return doc.displayMap(expandedSegments: expandedFoldSegments, collapseEnabled: true).foldRegions
    }

    var activeFoldRegionCount: Int { activeFoldRegions.count }

    var hiddenFoldLineCount: Int {
        activeFoldRegions.reduce(0) { $0 + $1.hiddenLineCount }
    }

    var canCollapseUnchanged: Bool {
        guard let doc = document, case .text = doc.content, !doc.isPlainFile, !doc.isAddedOnly, !doc.hunks.isEmpty else {
            return false
        }
        return !doc.displayMap(expandedSegments: [], collapseEnabled: true).foldRegions.isEmpty
    }

    // MARK: Canvas attachment

    func syncVimSettings() {
        guard let settings else { return }
        vimModeEnabled = settings.vimMode
        vimRelativeLineNumbers = settings.vimRelativeLineNumbers
        vimCursorColorHex = settings.vimCursorColorHex
        container?.canvas.vimModeEnabled = vimModeEnabled
        container?.canvas.vimRelativeLineNumbers = vimRelativeLineNumbers
        container?.canvas.vimCursorColor = vimCursorColorHex.flatMap(NSColor.fromHex)?.cgColor
    }

    func setVimMode(_ enabled: Bool) {
        if let settings, settings.vimMode != enabled {
            settings.vimMode = enabled
            settings.save()
        }
        vimModeEnabled = enabled
        container?.canvas.vimModeEnabled = enabled
    }

    func setVimRelativeLineNumbers(_ enabled: Bool) {
        if let settings, settings.vimRelativeLineNumbers != enabled {
            settings.vimRelativeLineNumbers = enabled
            settings.save()
        }
        vimRelativeLineNumbers = enabled
        container?.canvas.vimRelativeLineNumbers = enabled
    }

    func setVimCursorColorHex(_ hex: String?) {
        let normalized = NSColor.normalizedHexColor(hex)
        if let settings, settings.vimCursorColorHex != normalized {
            settings.vimCursorColorHex = normalized
            settings.save()
        }
        vimCursorColorHex = normalized
        container?.canvas.vimCursorColor = normalized.flatMap(NSColor.fromHex)?.cgColor
    }

    func syncStickyLinesSettings() {
        guard let settings else { return }
        container?.canvas.stickyLinesEnabled = settings.stickyLines
        container?.canvas.stickyLinesMaxCount = settings.stickyLinesMaxCount
    }

    func setStickyLines(_ enabled: Bool) {
        if let settings, settings.stickyLines != enabled {
            settings.stickyLines = enabled
            settings.save()
        }
        container?.canvas.stickyLinesEnabled = enabled
    }

    func setStickyLinesMaxCount(_ count: Int) {
        let clamped = min(Settings.stickyLinesRange.upperBound, max(Settings.stickyLinesRange.lowerBound, count))
        if let settings, settings.stickyLinesMaxCount != clamped {
            settings.stickyLinesMaxCount = clamped
            settings.save()
        }
        container?.canvas.stickyLinesMaxCount = clamped
    }

    @discardableResult
    func refreshLineDiff(side: Side? = nil, line: Int? = nil) -> LineDiffSnapshot? {
        if let side, let line {
            activeLineDiffLocation = (side, line)
        }
        guard let doc = document, case .text = doc.content, !doc.isPlainFile, !doc.isAddedOnly else {
            activeLineDiffLocation = nil
            if lineDiffSnapshot != nil { lineDiffSnapshot = nil }
            return nil
        }
        guard settings?.showLineDiffBar ?? true else {
            return nil
        }
        let snapshot: LineDiffSnapshot?
        if let side, let line {
            snapshot = LineDiffExtractor.extract(from: doc, side: side, line: line)
                ?? LineDiffExtractor.defaultSnapshot(for: doc, focusedHunk: focusedHunk)
        } else if let loc = activeLineDiffLocation {
            snapshot = LineDiffExtractor.extract(from: doc, side: loc.side, line: loc.line)
                ?? LineDiffExtractor.defaultSnapshot(for: doc, focusedHunk: focusedHunk)
        } else {
            snapshot = LineDiffExtractor.defaultSnapshot(for: doc, focusedHunk: focusedHunk)
        }
        if lineDiffSnapshot != snapshot {
            lineDiffSnapshot = snapshot
        }
        return snapshot
    }

    func attach(_ container: CodeScrollContainer) {
        self.container = container
        container.canvas.delegate = self
        container.canvas.codeFont = CodeFont.current(settings)
        syncVimSettings()
        syncStickyLinesSettings()
        container.canvas.onActiveLineChange = { [weak self] side, line in
            self?.refreshLineDiff(side: side, line: line)
        }
        container.onUserScroll = { [weak self] in self?.detachedFromFocus = true }
        container.show(document, mode: canvasMode, preserveScroll: false)
        container.canvas.setFolding(enabled: settings.collapseUnchanged, expandedSegments: expandedFoldSegments)
        container.canvas.showsRevertButtons = canRevertHunks
        container.canvas.editor = editor
        container.canvas.isLSPEnabled = isCurrentDocumentLSPEnabled
        if let doc = document { position(doc) }
        refreshLineDiff()
        observeFocusChanges()
    }

    /// Current right-pane caret position (0-based line, 0-based UTF-16 column).
    /// When a file is mid-load with a pending jump target, returns that pending target so rapid
    /// back-to-back `<C-o>` / `<C-i>` presses record the right position instead of the previous file's caret.
    func currentCaretPosition() -> TextPosition {
        if isLoading, let pendingLine {
            return TextPosition(row: max(0, pendingLine - 1), column: max(0, pendingColumn ?? 0))
        }
        if let pos = container?.canvas.activeCaretPosition() {
            return pos
        }
        let line1 = container?.canvas.currentLineNumber() ?? max(1, vimCursorLine)
        let col0 = max(0, vimCursorColumn - 1)
        return TextPosition(row: max(0, line1 - 1), column: col0)
    }

    // MARK: Loading

    /// Shows `request`. A request that is already on screen is left alone unless a line is given.
    func open(_ rawRequest: DiffRequest, line: Int? = nil, column: Int? = nil, preserveScroll: Bool = false) {
        var request = rawRequest
        if let settings { request.semantic = settings.semanticDiffOptions }
        if request == self.request && loadedGroupHunks == highlightedGroupHunks {
            if let line, document != nil, !isLoading {
                let current = currentCaretPosition()
                if line != current.row + 1 {
                    onRecordJump?(current.row, current.column)
                }
                reveal(line: line, column: column)
            } else if line != nil {
                pendingLine = line
                pendingColumn = column
            }
            if !isLoading, document != nil {
                ensureLSPSyncedAfterEarlyReturn()
            }
            return
        }
        if let current = self.request, let editor, editor.hasEdits, !isLoading,
           loadedGroupHunks == highlightedGroupHunks,
           current.root == request.root, current.path == request.path {
            // The file being edited, asked for again because the typing changed its status: it left the list,
            // or came back. The text on screen is still right, and reloading it would only make it jump.
            if case .worktree(let a) = current.source, case .worktree(let b) = request.source, a == b, current.oldPath == request.oldPath,
               current.ignoreWhitespace == request.ignoreWhitespace, current.semantic == request.semantic {
                self.request = request
                container?.canvas.showsRevertButtons = canRevertHunks
                onDocumentChanged?()
            }
            if self.request == request {
                if let line {
                    let pos = currentCaretPosition()
                    if line != pos.row + 1 {
                        onRecordJump?(pos.row, pos.column)
                    }
                    reveal(line: line, column: column)
                }
                ensureLSPSyncedAfterEarlyReturn()
                reloadIfStale(base: baseStamp)
                return
            }
        }
        if let previousRequest = self.request, document != nil, !isLoading {
            let prevURL = LSPURI.canonicalFileURL(previousRequest.fileURL)
            let nextURL = LSPURI.canonicalFileURL(request.fileURL)
            if prevURL != nextURL {
                let pos = currentCaretPosition()
                onWillSwitchFile?(previousRequest, pos.row, pos.column)
            } else if let line {
                let pos = currentCaretPosition()
                if line != pos.row + 1 {
                    onRecordJump?(pos.row, pos.column)
                }
            }
        }
        load(request, line: line, column: column, preserveScroll: preserveScroll)
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
        clearSymbolOccurrenceState()
        annotationHover = nil
        request = nil
        endEditing()
        document = nil
        activeLineDiffLocation = nil
        lineDiffSnapshot = nil
        expandedFoldSegments = []
        changedSymbols = []
        loadedGroupHunks = nil
        pendingRawHunkFocus = nil
        isLoading = false
        hunkCount = 0
        focusedHunk = nil
        container?.show(nil, mode: canvasMode, preserveScroll: false)
        container?.canvas.showsRevertButtons = false
        container?.canvas.isLSPEnabled = false
        container?.canvas.conflicts = []
        conflictCount = 0
        pendingExcelSheet = nil
        onDocumentChanged?()
    }

    private(set) var baseStamp: String?

    func setBaseStamp(_ stamp: String?) { baseStamp = stamp }

    private func load(_ rawRequest: DiffRequest, line: Int?, column: Int? = nil, preserveScroll: Bool) {
        var request = rawRequest
        if let settings { request.semantic = settings.semanticDiffOptions }
        // Leaving the text, or reading it again: what was typed goes to the file first.
        saveEdits()
        self.request = request
        pendingLine = line
        pendingColumn = column
        loadTask?.cancel()
        isLoading = true
        let stamp = baseStamp
        let groupFilter = highlightedGroupHunks
        loadedGroupHunks = groupFilter
        loadTask = Task { @MainActor [weak self] in
            let doc = await DiffLoader.load(request, includedGroupHunks: groupFilter)
            guard let self, !Task.isCancelled, self.request == request, self.loadedGroupHunks == groupFilter else { return }
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
                    load(request, line: pendingLine, column: pendingColumn, preserveScroll: true)
                    return
                }
            }
            if sameFile, preserveScroll { caret = container?.canvas.editSelection }
        }
        let previousDoc = document
        let isSpreadsheetReload: Bool
        if preserveScroll,
           case .spreadsheet(_, let oldURL) = previousDoc?.content,
           case .spreadsheet(_, let newURL) = doc.content,
           let oldURL, let newURL {
            isSpreadsheetReload = oldURL.standardizedFileURL == newURL.standardizedFileURL
        } else {
            isSpreadsheetReload = false
        }

        let preservedLineDiffLocation = preserveScroll ? activeLineDiffLocation : nil
        endEditing()
        if let settings {
            doc.semanticOptions.collapseUnchanged = settings.collapseUnchanged
        }
        expandedFoldSegments = []
        clearSymbolOccurrenceState()
        document = doc
        activeLineDiffLocation = preservedLineDiffLocation
        isLoading = false
        hunkCount = doc.hunks.count
        loadMilliseconds = doc.loadMilliseconds
        let previousFocus = focusedHunk
        focusedHunk = nil
        armed = nil
        container?.show(doc, mode: canvasMode, preserveScroll: preserveScroll)
        container?.canvas.showsRevertButtons = canRevertHunks
        if doc.isJSONNormalized {
            readOnlyReason = doc.editing?.readOnlyReason ?? L("JSON normalized view · read-only", "JSON 语义归一化视图 · 只读")
        } else if doc.isGroupFiltered {
            readOnlyReason = doc.editing?.readOnlyReason ?? L("Group view · read-only", "分组视图 · 只读")
        } else {
            beginEditing(doc, caret: caret)
        }
        refreshChangedSymbols(for: doc)
        syncLSPForCurrentDocument()
        refreshConflicts()
        annotationHover = nil
        if annotating { loadAnnotations() }
        if case .spreadsheet(let workbook, let fileURL) = doc.content {
            if findVisible { findVisible = false }
            let key = excelSessionKey(for: fileURL)
            if let existing = excelSessions[key] {
                existing.applyWorkbook(workbook, fileURL: fileURL, isReload: true)
            } else {
                excelSessions[key] = ExcelViewerState(workbook: workbook, fileURL: fileURL)
            }
            if let pending = pendingExcelSheet {
                _ = excelSessions[key]?.selectSheet(named: pending)
                pendingExcelSheet = nil
            }
            if isSpreadsheetReload {
                let name = fileURL?.lastPathComponent ?? ((request?.path as NSString?)?.lastPathComponent ?? "")
                if !name.isEmpty {
                    onToast?(L("File reloaded: \(name)", "文件已重新加载: \(name)"))
                }
            }
        }
        if preserveScroll {
            if let previousFocus, previousFocus < doc.hunks.count {
                focusedHunk = previousFocus
                container?.canvas.focusedHunk = previousFocus
            }
        } else {
            position(doc)
        }
        refreshLineDiff()
        if findVisible, !findQuery.isEmpty { runFind(reveal: false) }
        onDocumentChanged?()
    }

    /// Initial viewport: the requested line, else the first change (as IntelliJ does).
    private func position(_ doc: DiffDocument) {
        guard let container else {
            if let line = pendingLine {
                let col = pendingColumn
                pendingLine = nil
                pendingColumn = nil
                reveal(line: line, column: col)
            }
            return
        }
        container.whenLaidOut { [weak self, weak container] in
            guard let self, let container, self.document === doc else { return }
            self.detachedFromFocus = false
            if let line = self.pendingLine {
                let col = self.pendingColumn
                self.pendingLine = nil
                self.pendingColumn = nil
                self.reveal(line: line, column: col)
            } else if !doc.hunks.isEmpty, case .text = doc.content, !doc.isPlainFile {
                var index = self.landOnLastHunk ? doc.hunks.count - 1 : 0
                if doc.isGroupFiltered,
                   let pending = self.pendingRawHunkFocus,
                   pending.path == self.request?.path,
                   Date().timeIntervalSince(pending.at) < 1.5,
                   let mapped = doc.groupHunkIndexMap[pending.rawIndex],
                   doc.hunks.indices.contains(mapped) {
                    index = mapped
                    self.pendingRawHunkFocus = nil
                }
                let hunk = doc.hunks[index]
                self.focusedHunk = index
                // Ready to type where the change is, as the IDE's diff puts its caret there.
                container.canvas.placeCaret(line: hunk.rightStart)
                container.canvas.focusedHunk = index
                if hunk.rightCount > 0 {
                    self.refreshLineDiff(side: .right, line: hunk.rightStart)
                } else if hunk.leftCount > 0 {
                    self.refreshLineDiff(side: .left, line: hunk.leftStart)
                }
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

    /// Scrolls to a 1-based line (and optional 0-based UTF-16 column) of the new side and tints it.
    func reveal(line: Int, column: Int? = nil, resetVimToNormal: Bool = false) {
        guard let doc = document, case .text = doc.content, !doc.right.lines.isEmpty else { return }
        let index = max(0, min(line - 1, doc.right.lines.count - 1))
        let nsLine = doc.right.lines[index] as NSString
        let maxCol = nsLine.length
        let targetCol: Int
        if let column {
            let inInsert = container?.canvas.vimEngine.mode.isInsert ?? false
            if vimModeEnabled && (resetVimToNormal || !inInsert) {
                let lastCol = maxCol > 0
                    ? TextEditing.characterBoundary(in: nsLine, from: maxCol, forward: false)
                    : 0
                targetCol = max(0, min(column, lastCol))
            } else {
                targetCol = max(0, min(column, maxCol))
            }
        } else {
            targetCol = 0
        }
        guard let container else {
            vimCursorLine = index + 1
            vimCursorColumn = targetCol + 1
            return
        }
        if resetVimToNormal && container.canvas.vimModeEnabled {
            container.canvas.vimEngine.resetToNormal(switchInputSource: true)
        }
        ensureLineVisible(index, side: .right)
        container.canvas.placeCaret(line: index, column: targetCol)
        if resetVimToNormal && container.canvas.vimModeEnabled {
            container.canvas.reportVimStateIfNeeded(force: true)
        }
        container.canvas.focusLine = (.right, index)
        container.scroll(toRow: container.canvas.row(forLine: index, side: .right), fraction: 0.35, animated: false)
        detachedFromFocus = true
        refreshLineDiff(side: .right, line: index)
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
        focusFilteredHunk(target)
    }

    /// Focuses a hunk by its 0-based raw hunk index (e.g. from AI Groups).
    /// When the active document is group-filtered, maps `index` through `doc.groupHunkIndexMap`
    /// so raw indices always land on the exact matching filtered hunk without clamping errors.
    func focus(hunk index: Int, animated: Bool = true) {
        guard let doc = document else {
            if let path = request?.path {
                pendingRawHunkFocus = (path, index, Date())
            }
            return
        }
        if doc.isGroupFiltered {
            if let mapped = doc.groupHunkIndexMap[index], doc.hunks.indices.contains(mapped) {
                pendingRawHunkFocus = nil
                focusFilteredHunk(mapped, animated: animated)
            } else {
                // Keep in case the group filter for a newly selected group arrives on the next UI tick.
                if let path = request?.path {
                    pendingRawHunkFocus = (path, index, Date())
                }
            }
            return
        }
        if let path = request?.path {
            pendingRawHunkFocus = (path, index, Date())
        }
        focusFilteredHunk(index, animated: animated)
    }

    /// Focuses a hunk using its direct 0-based index in `document.hunks`.
    private func focusFilteredHunk(_ index: Int, animated: Bool = true) {
        guard let container else { return }
        let origin = currentCaretPosition()
        focusedHunk = index
        detachedFromFocus = false
        if let doc = document, doc.hunks.indices.contains(index) {
            let hunk = doc.hunks[index]
            if hunk.rightCount > 0 { ensureLineVisible(hunk.rightStart, side: .right) }
            if hunk.leftCount > 0 { ensureLineVisible(hunk.leftStart, side: .left) }
            if hunk.rightStart != origin.row {
                onRecordJump?(origin.row, origin.column)
            }
            container.canvas.placeCaret(line: hunk.rightStart)
            container.canvas.focusedHunk = index
            if hunk.rightCount > 0 {
                refreshLineDiff(side: .right, line: hunk.rightStart)
            } else if hunk.leftCount > 0 {
                refreshLineDiff(side: .left, line: hunk.leftStart)
            }
        } else {
            container.canvas.focusedHunk = index
        }
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

    // MARK: SemanticDiff controls & folding

    func toggleIgnoreComments() {
        settings.ignoreComments.toggle()
        settings.save()
        syncSemanticOptions()
    }

    func toggleNormalizeJSON() {
        settings.normalizeJSON.toggle()
        settings.save()
        syncSemanticOptions()
    }

    func toggleDetectMoves() {
        settings.detectMoves.toggle()
        settings.save()
        syncSemanticOptions()
    }

    func toggleDetectRenames() {
        settings.detectRenames.toggle()
        settings.save()
        syncSemanticOptions()
    }

    func toggleCollapseUnchanged() {
        settings.collapseUnchanged.toggle()
        settings.save()
        syncSemanticOptions()
    }

    /// Reconciles the open request/document with `settings.semanticDiffOptions`.
    /// Folding toggles update the canvas immediately without reloading; structural diff options reload the diff.
    func syncSemanticOptions() {
        guard let settings else { return }
        let desired = settings.semanticDiffOptions
        guard var current = request else { return }
        guard current.semantic != desired else { return }

        let onlyCollapseChanged =
            current.semantic.ignoreComments == desired.ignoreComments
            && current.semantic.normalizeJSON == desired.normalizeJSON
            && current.semantic.detectMoves == desired.detectMoves
            && current.semantic.detectRenames == desired.detectRenames

        current.semantic = desired
        if onlyCollapseChanged {
            self.request = current
            document?.semanticOptions.collapseUnchanged = desired.collapseUnchanged
            expandedFoldSegments = []
            container?.canvas.setFolding(enabled: desired.collapseUnchanged, expandedSegments: expandedFoldSegments)
        } else {
            load(current, line: nil, preserveScroll: true)
        }
    }

    func toggleFoldSegment(_ segmentIndex: Int) {
        if expandedFoldSegments.contains(segmentIndex) {
            expandedFoldSegments.remove(segmentIndex)
        } else {
            expandedFoldSegments.insert(segmentIndex)
        }
        container?.canvas.setFolding(enabled: settings?.collapseUnchanged ?? false, expandedSegments: expandedFoldSegments)
    }

    func expandFoldSegment(_ segmentIndex: Int) {
        guard expandedFoldSegments.insert(segmentIndex).inserted else { return }
        container?.canvas.setFolding(enabled: settings?.collapseUnchanged ?? false, expandedSegments: expandedFoldSegments)
    }

    func expandAllFolds() {
        guard let doc = document else { return }
        let allRegions = doc.displayMap(expandedSegments: [], collapseEnabled: true).foldRegions
        guard !allRegions.isEmpty else { return }
        expandedFoldSegments.formUnion(allRegions.map(\.segmentIndex))
        container?.canvas.setFolding(enabled: settings?.collapseUnchanged ?? false, expandedSegments: expandedFoldSegments)
    }

    func collapseAllFolds() {
        guard !expandedFoldSegments.isEmpty || settings?.collapseUnchanged != true else { return }
        if let settings, !settings.collapseUnchanged {
            settings.collapseUnchanged = true
            settings.save()
            request?.semantic.collapseUnchanged = true
            document?.semanticOptions.collapseUnchanged = true
        }
        expandedFoldSegments = []
        container?.canvas.setFolding(enabled: true, expandedSegments: expandedFoldSegments)
    }

    private func ensureLineVisible(_ line: Int, side: Side) {
        guard settings?.collapseUnchanged == true, let doc = document else { return }
        let map = doc.displayMap(expandedSegments: expandedFoldSegments, collapseEnabled: true)
        if let region = map.foldRegion(containingLine: line, side: side) {
            expandFoldSegment(region.segmentIndex)
        }
    }

    func jumpToMoveCounterpart(forHunk hunkIndex: Int) {
        guard let doc = document, doc.hunks.indices.contains(hunkIndex),
              let move = doc.hunks[hunkIndex].moveInfo,
              doc.hunks.indices.contains(move.counterpartHunkIndex) else { return }
        let target = move.counterpartHunkIndex
        focusFilteredHunk(target, animated: true)
    }

    func stepMovedHunk() {
        guard let doc = document else { return }
        let movedIndices = doc.hunks.indices.filter { doc.hunks[$0].moveInfo != nil }
        guard !movedIndices.isEmpty else { return }
        if let current = focusedHunk, let pos = movedIndices.firstIndex(of: current) {
            let next = movedIndices[(pos + 1) % movedIndices.count]
            focusFilteredHunk(next, animated: true)
        } else {
            focusFilteredHunk(movedIndices[0], animated: true)
        }
    }

    func jumpToRenameGroup(_ group: RenameGroup) {
        guard let first = group.hunkIndices.first else { return }
        focusFilteredHunk(first, animated: true)
    }

    func setHighlightedGroupHunks(_ hunks: Set<Int>?) {
        guard highlightedGroupHunks != hunks || (request != nil && loadedGroupHunks != hunks) else { return }
        highlightedGroupHunks = hunks
        guard let req = request else { return }
        guard loadedGroupHunks != hunks else { return }

        // Fast synchronous in-memory re-filtering when switching between AI groups on the same unmodified loaded text file.
        let hasInlineEdits = (editor?.hasEdits ?? false) || (editor?.isDirty ?? false) || (editor?.version ?? 0) > 0
        if let newSet = hunks, !isLoading, !hasInlineEdits,
           let doc = document, case .text = doc.content, !doc.isPlainFile,
           let baseline = doc.groupFilterBaseline {
            saveEdits()
            loadTask?.cancel()
            loadedGroupHunks = newSet
            let filteredDoc = DiffLoader.buildGroupFiltered(
                baseline: baseline,
                includedGroupHunks: newSet,
                language: doc.language,
                semanticOptions: settings?.semanticDiffOptions ?? req.semantic,
                ignoreWhitespace: req.ignoreWhitespace,
                leftTitle: doc.leftTitle,
                rightTitle: doc.rightTitle
            )
            apply(filteredDoc, preserveScroll: false)
            return
        }

        // Switching back to full editable diff (`nil`), or re-filtering while a load is in flight.
        load(req, line: pendingLine, column: pendingColumn, preserveScroll: hunks == nil)
    }

    func refreshChangedSymbols(for doc: DiffDocument? = nil) {
        let targetDoc = doc ?? document
        guard let targetDoc, case .text = targetDoc.content, !targetDoc.isPlainFile,
              !targetDoc.hunks.isEmpty, targetDoc.language.family != .plain,
              targetDoc.right.lines.count <= 20_000 else {
            if !changedSymbols.isEmpty { changedSymbols = [] }
            return
        }
        let symbols = FileSymbolExtractor.extract(lines: targetDoc.right.lines, language: targetDoc.language)
        let changed = FileSymbolExtractor.changedSymbols(symbols: symbols, hunks: targetDoc.hunks, side: .right)
        if changedSymbols != changed { changedSymbols = changed }
    }

    func jumpToChangedSymbol(_ item: ChangedFileSymbol) {
        reveal(line: item.symbol.lineNumber, column: item.symbol.column)
        if let firstHunk = item.hunkIndices.first, let doc = document, doc.hunks.indices.contains(firstHunk) {
            focusedHunk = firstHunk
            container?.canvas.focusedHunk = firstHunk
        }
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
        onCodeFontChanged?()
    }

    func focusCanvas() {
        guard let container else { return }
        container.window?.makeFirstResponder(container.canvas)
    }

    // MARK: Find in file

    func showFind() {
        if isSpreadsheet {
            activeExcelSession?.requestSearchFocus()
            return
        }
        guard isTextDocument else { return }
        findOrigin = currentCaretPosition()
        if let selected = container?.canvas.selectedText(), !selected.isEmpty, !selected.contains("\n") {
            findQuery = selected
        }
        findVisible = true
        findFocusToken += 1
        runFind(reveal: true)
    }

    func hideFind() {
        clearSymbolOccurrenceState()
        findVisible = false
        findOrigin = nil
        findCount = 0
        findIndex = 0
        container?.canvas.setHighlightedRanges([[:], [:]], navigation: [], current: -1)
        focusCanvas()
    }

    func runFind(reveal: Bool) {
        clearSymbolOccurrenceState()
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
        if reveal, current >= 0 {
            let match = list[current]
            if match.side == .right {
                if let origin = findOrigin, match.line != origin.row {
                    onRecordJump?(origin.row, origin.column)
                    findOrigin = nil
                }
                container.canvas.placeCaret(line: match.line, column: match.range.lowerBound)
            }
            revealMatch(match)
        }
    }

    func stepFind(_ delta: Int, center: Bool = false) {
        if isSpreadsheet {
            activeExcelSession?.navigateSearch(delta)
            return
        }
        guard let canvas = container?.canvas, !canvas.matches.isEmpty else { return }
        let origin = currentCaretPosition()
        let count = canvas.matches.count
        let next = ((canvas.currentMatch + delta) % count + count) % count
        canvas.setCurrentMatch(next)
        findIndex = next + 1
        let match = canvas.matches[next]
        if match.side == .right {
            if match.line != origin.row {
                onRecordJump?(origin.row, origin.column)
            }
            findOrigin = nil
            canvas.placeCaret(line: match.line, column: match.range.lowerBound)
        }
        revealMatch(match, center: center)
        refreshLineDiff(side: match.side, line: match.line)
    }

    private func revealMatch(_ match: SearchMatch, center: Bool = false) {
        guard let container else { return }
        ensureLineVisible(match.line, side: match.side)
        let row = container.canvas.row(forLine: match.line, side: match.side)
        if center {
            container.scroll(toRow: row, fraction: 0.5, animated: false)
        } else {
            let top = container.topRow
            let lh = max(1, container.canvas.codeFont.lineHeight)
            let stickyRows = Int(ceil(container.canvas.stickyHeight(for: match.side) / lh))
            if row < top + stickyRows + 2 || row > top + container.visibleRowCount - 4 {
                container.scroll(toRow: row, fraction: 0.4, animated: true)
            }
        }
        detachedFromFocus = true
    }

    /// Vim `*` / `#`: search word under cursor and jump to next/previous occurrence centered in viewport.
    func searchWordUnderCursor(line: Int, column: Int, forward: Bool) {
        guard let container, let doc = document, case .text = doc.content,
              line >= 0, line < doc.right.lines.count else { return }
        guard let symbol = LSPNavigationHelper.extractSymbol(in: doc.right.lines[line], at: column) else { return }
        findQuery = symbol.name
        runFind(reveal: false)
        let canvas = container.canvas
        let matches = canvas.matches
        guard !matches.isEmpty else { return }

        let targetIndex: Int
        if forward {
            targetIndex = matches.firstIndex(where: {
                $0.side == .right && ($0.line > line || ($0.line == line && $0.range.lowerBound > symbol.range.lowerBound))
            }) ?? 0
        } else {
            targetIndex = matches.lastIndex(where: {
                $0.side == .right && ($0.line < line || ($0.line == line && $0.range.lowerBound < symbol.range.lowerBound))
            }) ?? (matches.count - 1)
        }
        canvas.setCurrentMatch(targetIndex)
        findIndex = targetIndex + 1
        let match = matches[targetIndex]
        if match.side == .right {
            if match.line != line {
                onRecordJump?(line, column)
            }
            canvas.placeCaret(line: match.line, column: match.range.lowerBound)
        }
        revealMatch(match, center: true)
    }

    func clearSymbolOccurrenceState() {
        symbolHighlightTask?.cancel()
        symbolHighlightTask = nil
        symbolHighlightGeneration &+= 1
        symbolOccurrenceCache = nil
    }

    /// Jumps to the next (`forward == true`) or previous (`forward == false`) occurrence of the symbol under the cursor.
    /// Uses LSP `textDocument/documentHighlight` strictly within lexical scope for LSP-enabled files;
    /// falls back to whole-word matching only when no LSP server/provider is available for the language.
    func stepSymbolOccurrence(forward: Bool) {
        guard let container, let doc = document, case .text = doc.content else { return }
        let ctx = container.canvas.symbolCursorContext() ?? (.right, currentCaretPosition().row, currentCaretPosition().column)
        let lines = doc.buffer(ctx.side).lines
        guard lines.indices.contains(ctx.line) else { return }
        let symbol = LSPNavigationHelper.extractSymbol(in: lines[ctx.line], at: ctx.column)

        let docID = ObjectIdentifier(doc)
        if let cache = symbolOccurrenceCache,
           cache.docID == docID,
           cache.diffRevision == diffRevision,
           cache.side == ctx.side {
            let hit: Bool
            if cache.isSemantic {
                hit = cache.matches.contains { match in
                    match.line == ctx.line && (
                        (ctx.column >= match.range.lowerBound && ctx.column < match.range.upperBound)
                        || (ctx.column == match.range.upperBound && symbol?.range == match.range)
                    )
                }
            } else if let symbol, cache.symbolName == symbol.name {
                hit = SymbolOccurrenceNavigator.contains(line: ctx.line, column: ctx.column, symbolRange: symbol.range, in: cache.matches)
            } else {
                hit = false
            }
            if hit {
                applySymbolOccurrenceJump(matches: cache.matches, originLine: ctx.line, originColumn: ctx.column, forward: forward)
                return
            }
        }

        guard let symbol else { return }

        if AppEnvironment.hasLSP, isCurrentDocumentLSPEnabled {
            symbolHighlightTask?.cancel()
            symbolHighlightGeneration &+= 1
            let gen = symbolHighlightGeneration
            let startRevision = diffRevision
            let symbolName = symbol.name
            let symbolRange = symbol.range
            let originLine = ctx.line
            let originColumn = ctx.column
            let originSide = ctx.side
            let queryColumn = max(symbolRange.lowerBound, min(originColumn, max(symbolRange.lowerBound, symbolRange.upperBound - 1)))
            let isSyncEnabled = isCurrentDocumentLSPSyncEnabled
            let req = request

            symbolHighlightTask = Task { @MainActor [weak self, weak doc] in
                guard let self, let doc else { return }
                let outcome: LSPDocumentHighlightResult
                var lspMatches: [SearchMatch] = []

                if originSide == .right, isSyncEnabled {
                    if let active = await self.ensureLSPDocumentSynced() {
                        guard !Task.isCancelled,
                              self.symbolHighlightGeneration == gen,
                              self.document === doc,
                              self.diffRevision == startRevision else { return }
                        let text = doc.right.lines.joined(separator: "\n")
                        outcome = await self.lspManager.documentHighlightResult(
                            fileURL: active.fileURL,
                            line: originLine,
                            character: queryColumn,
                            text: text,
                            language: active.language,
                            repoRoot: active.repoRoot
                        )
                        if case .highlights(let highlights) = outcome {
                            lspMatches = SymbolOccurrenceNavigator.matches(from: highlights, in: doc.right.lines, side: .right)
                        }
                    } else {
                        let available = await self.lspManager.isServerAvailable(for: doc.language)
                        outcome = available ? .failed : .unavailable
                    }
                } else {
                    let snapshotLines = doc.buffer(originSide).lines
                    let clickedLineText = snapshotLines.indices.contains(originLine) ? snapshotLines[originLine] : ""
                    let offsetInSymbol = max(0, min(queryColumn - symbolRange.lowerBound, max(0, symbolRange.count - 1)))
                    let refLines: [String]?
                    let queryFileURL: URL
                    let queryRepoRoot: URL?
                    let queryText: String?

                    if originSide == .left, isSyncEnabled {
                        if let active = await self.ensureLSPDocumentSynced() {
                            refLines = doc.right.lines
                            queryFileURL = active.fileURL
                            queryRepoRoot = active.repoRoot
                            queryText = doc.right.lines.joined(separator: "\n")
                        } else {
                            let available = await self.lspManager.isServerAvailable(for: doc.language)
                            guard !Task.isCancelled,
                                  self.symbolHighlightGeneration == gen,
                                  self.document === doc,
                                  self.diffRevision == startRevision else { return }
                            if available {
                                self.onToast?(L("Language server is busy — try again", "语言服务正在索引，请稍后重试"))
                            } else {
                                let fallback = SymbolOccurrenceNavigator.wholeWordOccurrences(of: symbolName, in: snapshotLines, side: originSide)
                                guard !fallback.isEmpty else { return }
                                self.symbolOccurrenceCache = (ObjectIdentifier(doc), startRevision, originSide, symbolName, false, fallback)
                                self.applySymbolOccurrenceJump(matches: fallback, originLine: originLine, originColumn: originColumn, forward: forward)
                            }
                            return
                        }
                    } else {
                        guard let req else { return }
                        let canonicalFileURL = LSPURI.canonicalFileURL(req.fileURL)
                        let canonicalRepoRoot = LSPURI.canonicalFileURL(req.lspRepoRoot ?? req.root)
                        refLines = await Task.detached(priority: .userInitiated) {
                            guard let data = try? Data(contentsOf: canonicalFileURL, options: .mappedIfSafe),
                                  !TextCodec.looksBinary(data) else {
                                return nil
                            }
                            return TextCodec.splitLines(TextCodec.decode(data))
                        }.value
                        queryFileURL = canonicalFileURL
                        queryRepoRoot = canonicalRepoRoot
                        queryText = nil
                    }

                    guard !Task.isCancelled,
                          self.symbolHighlightGeneration == gen,
                          self.document === doc,
                          self.diffRevision == startRevision else { return }

                    guard let refLines,
                          let mapped = LSPNavigationHelper.mapSymbolToWorkingTree(
                              symbolName: symbolName,
                              clickedLineText: clickedLineText,
                              clickedLine: originLine,
                              clickedStartColumn: symbolRange.lowerBound,
                              offsetInSymbol: offsetInSymbol,
                              diskLines: refLines
                          ) else {
                        let available = await self.lspManager.isServerAvailable(for: doc.language)
                        guard !Task.isCancelled,
                              self.symbolHighlightGeneration == gen,
                              self.document === doc,
                              self.diffRevision == startRevision else { return }
                        if !available {
                            let fallback = SymbolOccurrenceNavigator.wholeWordOccurrences(of: symbolName, in: snapshotLines, side: originSide)
                            guard !fallback.isEmpty else { return }
                            self.symbolOccurrenceCache = (ObjectIdentifier(doc), startRevision, originSide, symbolName, false, fallback)
                            self.applySymbolOccurrenceJump(matches: fallback, originLine: originLine, originColumn: originColumn, forward: forward)
                        }
                        return
                    }

                    outcome = await self.lspManager.documentHighlightResult(
                        fileURL: queryFileURL,
                        line: mapped.line,
                        character: mapped.character,
                        text: queryText,
                        language: doc.language,
                        repoRoot: queryRepoRoot
                    )
                    if case .highlights(let highlights) = outcome {
                        lspMatches = SymbolOccurrenceNavigator.mapHighlightsToSnapshot(
                            highlights,
                            diskLines: refLines,
                            snapshotLines: snapshotLines,
                            symbolName: symbolName,
                            side: originSide
                        )
                    }
                }

                guard !Task.isCancelled,
                      self.symbolHighlightGeneration == gen,
                      self.document === doc,
                      self.diffRevision == startRevision else { return }

                switch outcome {
                case .highlights:
                    guard !lspMatches.isEmpty,
                          SymbolOccurrenceNavigator.contains(line: originLine, column: originColumn, symbolRange: symbolRange, in: lspMatches) else {
                        return
                    }
                    self.symbolOccurrenceCache = (ObjectIdentifier(doc), startRevision, originSide, symbolName, true, lspMatches)
                    self.applySymbolOccurrenceJump(matches: lspMatches, originLine: originLine, originColumn: originColumn, forward: forward)
                case .failed:
                    self.onToast?(L("Language server is busy — try again", "语言服务正在索引，请稍后重试"))
                case .unavailable:
                    let fallback = SymbolOccurrenceNavigator.wholeWordOccurrences(of: symbolName, in: doc.buffer(originSide).lines, side: originSide)
                    guard !fallback.isEmpty else { return }
                    self.symbolOccurrenceCache = (ObjectIdentifier(doc), startRevision, originSide, symbolName, false, fallback)
                    self.applySymbolOccurrenceJump(matches: fallback, originLine: originLine, originColumn: originColumn, forward: forward)
                }
            }
            return
        }

        let matches = SymbolOccurrenceNavigator.wholeWordOccurrences(of: symbol.name, in: lines, side: ctx.side)
        guard !matches.isEmpty else { return }
        symbolOccurrenceCache = (docID, diffRevision, ctx.side, symbol.name, false, matches)
        applySymbolOccurrenceJump(matches: matches, originLine: ctx.line, originColumn: ctx.column, forward: forward)
    }

    private func applySymbolOccurrenceJump(matches: [SearchMatch], originLine: Int, originColumn: Int, forward: Bool) {
        guard let container,
              !matches.isEmpty,
              let targetIndex = SymbolOccurrenceNavigator.targetIndex(in: matches, fromLine: originLine, column: originColumn, forward: forward) else {
            return
        }
        var bySide: [[Int: [Range<Int>]]] = [[:], [:]]
        for m in matches {
            bySide[m.side.rawValue][m.line, default: []].append(m.range)
        }
        container.canvas.setHighlightedRanges(bySide, navigation: matches, current: targetIndex)
        let target = matches[targetIndex]
        if target.side == .right {
            if target.line != originLine {
                onRecordJump?(originLine, originColumn)
            }
            if container.canvas.editor != nil || container.canvas.vimModeEnabled {
                if container.canvas.vimModeEnabled, container.canvas.vimEngine.mode.isVisual {
                    container.canvas.vimEngine.resetToNormal(switchInputSource: false)
                }
                container.canvas.placeCaret(line: target.line, column: target.range.lowerBound)
                if container.canvas.vimModeEnabled {
                    container.canvas.reportVimStateIfNeeded(force: true)
                }
            } else {
                container.canvas.selectRange(side: .right, line: target.line, range: target.range)
            }
        } else {
            container.canvas.selectRange(side: .left, line: target.line, range: target.range)
        }
        revealMatch(target, center: false)
        refreshLineDiff(side: target.side, line: target.line)
    }

    func expandSelection() {
        container?.canvas.vimExpandSelection()
    }

    func shrinkSelection() {
        container?.canvas.vimShrinkSelection()
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

    func canvas(_ canvas: CodeCanvasView, didUpdateVimState state: VimUIState) {
        if vimMode != state.mode { vimMode = state.mode }
        if vimPendingKeys != state.pendingKeys { vimPendingKeys = state.pendingKeys }
        if vimCursorLine != state.cursorLine { vimCursorLine = state.cursorLine }
        if vimCursorColumn != state.cursorColumn { vimCursorColumn = state.cursorColumn }
    }

    func canvas(_ canvas: CodeCanvasView, recordJumpOrigin origin: TextPosition) {
        onRecordJump?(origin.row, origin.column)
    }

    func canvas(_ canvas: CodeCanvasView, jumpToMoveCounterpart hunkIndex: Int) {
        jumpToMoveCounterpart(forHunk: hunkIndex)
    }

    func canvas(_ canvas: CodeCanvasView, expandFoldSegment segmentIndex: Int) {
        expandFoldSegment(segmentIndex)
    }

    func canvas(_ canvas: CodeCanvasView, didSelectHunk index: Int) {
        guard let doc = document, doc.hunks.indices.contains(index) else { return }
        focusedHunk = index
        detachedFromFocus = false
        armed = nil
        canvas.focusedHunk = index
    }

    func canvas(_ canvas: CodeCanvasView, didClickStickyLine line: Int, side: Side, slotIndex: Int) {
        ensureLineVisible(line, side: side)
        if side == .right {
            let current = currentCaretPosition()
            if line != current.row {
                onRecordJump?(current.row, current.column)
            }
            canvas.placeCaret(line: line, column: 0)
            if canvas.vimModeEnabled {
                canvas.reportVimStateIfNeeded(force: true)
            }
        }
        canvas.focusLine = (side, line)
        refreshLineDiff(side: side, line: line)
        let targetY = canvas.stickyScrollTargetY(for: line, side: side, slotIndex: slotIndex)
        container?.scroll(toY: targetY, animated: true)
        detachedFromFocus = true
    }

    func canvas(_ canvas: CodeCanvasView, performVimAction action: VimAction, line: Int, column: Int) {
        switch action {
        case .openFind:
            showFind()
        case .searchWord(let forward):
            searchWordUnderCursor(line: line, column: column, forward: forward)
        case .nextSearchMatch(let forward, let center):
            if canvas.matches.isEmpty, !findQuery.isEmpty { runFind(reveal: false) }
            stepFind(forward ? 1 : -1, center: center)
        case .clearSearchHighlights:
            hideFind()
        case .save:
            saveFromVim()
        case .jumpToLine(let lineNum):
            reveal(line: lineNum, column: column)
        case .scrollCenter:
            container?.scroll(toRow: canvas.row(forLine: line, side: .right), fraction: 0.5, animated: false)
        case .scrollTop:
            container?.scroll(toY: canvas.scrollYBelowSticky(forLine: line, side: .right), animated: false)
        case .scrollBottom:
            container?.scroll(toRow: canvas.row(forLine: line, side: .right), fraction: 0.92, animated: false)
        case .scrollHalfPage(let down):
            let rows = max(1, canvas.visibleLineCount / 2)
            container?.scrollBy(dx: 0, dy: CGFloat(down ? rows : -rows) * canvas.codeFont.lineHeight)
        case .scrollFullPage(let down):
            let rows = max(1, canvas.visibleLineCount - 2)
            container?.scrollBy(dx: 0, dy: CGFloat(down ? rows : -rows) * canvas.codeFont.lineHeight)
        case .undo:
            canvas.undoTyping()
        case .redo:
            canvas.redoTyping()
        case .readOnlyNotice:
            onToast?(readOnlyReason ?? L("Read-only file", "只读文件"))
        case .goToDefinition, .findReferences, .goToFile, .goToSymbol, .searchEverywhere, .findAction,
             .gitPull, .gitPush, .toggleGitGraph, .toggleMaximizeViewer, .locateInTree,
             .toggleFileTree, .navigateBack, .navigateForward, .focusLeftPane, .focusRightPane, .quit:
            onVimAction?(action, line, column)
        }
    }

    func canvasDidMagnify(_ canvas: CodeCanvasView, by delta: CGFloat) {
        magnification += delta
        if abs(magnification) > 0.18 {
            changeFontSize(by: magnification > 0 ? 1 : -1)
            magnification = 0
        }
    }
}

extension Settings {
    /// Bridges the 5 persisted SemanticDiff preference switches into `SemanticDiffOptions`.
    var semanticDiffOptions: SemanticDiffOptions {
        SemanticDiffOptions(
            ignoreComments: ignoreComments,
            normalizeJSON: normalizeJSON,
            detectMoves: detectMoves,
            detectRenames: detectRenames,
            collapseUnchanged: collapseUnchanged
        )
    }
}
