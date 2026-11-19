import AppKit
import Observation

// MARK: - Pure LSP Navigation Helpers

/// Pure helpers for symbol extraction and definition-vs-reference detection.
enum LSPNavigationHelper {
    /// Returns `true` when `(fileURL, line, character)` (0-based line, 0-based UTF-16 column)
    /// lies on any of the returned `definitions`.
    static func isPositionOnDefinition(
        fileURL: URL,
        line: Int,
        character: Int,
        symbolRange: Range<Int>? = nil,
        definitions: [LSPLocation]
    ) -> Bool {
        let canonicalFile = LSPURI.canonicalFileURL(fileURL)
        for def in definitions {
            guard let defURL = def.fileURL,
                  LSPURI.canonicalFileURL(defURL) == canonicalFile else {
                continue
            }
            guard def.range.start.line == line else { continue }

            let startCol = def.range.start.character
            let endCol = def.range.end.character

            if def.range.end.line == line {
                if endCol > startCol {
                    if character >= startCol && character <= endCol {
                        return true
                    }
                    if let sym = symbolRange, sym.lowerBound < endCol && startCol < sym.upperBound {
                        return true
                    }
                } else {
                    // Zero-width range on the declaration line.
                    if character == startCol {
                        return true
                    }
                    if let sym = symbolRange, startCol >= sym.lowerBound && startCol <= sym.upperBound {
                        return true
                    }
                }
            } else if def.range.end.line > line {
                // Multi-line definition range: only match the declaration header line, never later body lines.
                if character >= startCol {
                    return true
                }
                if let sym = symbolRange, sym.upperBound >= startCol {
                    return true
                }
            }
        }
        return false
    }

    /// Extracts the identifier token name and UTF-16 range covering `utf16Column` in `line`.
    static func extractSymbol(in line: String, at utf16Column: Int) -> (name: String, range: Range<Int>)? {
        let ns = line as NSString
        let length = ns.length
        guard length > 0 else { return nil }

        func isIdent(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }

        var pivot = max(0, min(utf16Column, length - 1))
        if !isIdent(ns.character(at: pivot)), pivot > 0, isIdent(ns.character(at: pivot - 1)) {
            pivot -= 1
        }
        guard isIdent(ns.character(at: pivot)) else { return nil }

        var start = pivot
        var end = pivot + 1
        while start > 0, isIdent(ns.character(at: start - 1)) { start -= 1 }
        while end < length, isIdent(ns.character(at: end)) { end += 1 }
        let name = ns.substring(with: NSRange(location: start, length: end - start))
        guard !name.isEmpty else { return nil }
        return (name, start..<end)
    }
}

// MARK: - References / Definitions Picker Models

/// One selectable location in the References / Definitions picker popup.
struct ReferenceItem: Identifiable, Equatable, Sendable {
    let id: Int
    let location: LSPLocation
    let fileURL: URL
    /// Relative path in active repo, `<repoName>/<relPath>` for other/`go.work` repos, or shortened external path.
    let displayPath: String
    /// 1-based line number.
    let lineNumber: Int
    /// 0-based UTF-16 start column.
    let column: Int
    /// 0-based UTF-16 end column on the matched line (equals `column` when zero-width or multi-line).
    let endColumn: Int
    /// Trimmed single-line snippet of the matched line.
    var linePreview: String
    /// UTF-16 range of the matched symbol within `linePreview`.
    var matchRangeInPreview: Range<Int>?
    /// True when this location corresponds to the symbol's declaration/definition.
    let isDeclaration: Bool
}

/// One syntax-highlighted line inside the References code preview pane.
struct ReferencePreviewLine: Identifiable, Equatable, Sendable {
    let id: Int
    /// 1-based line number.
    let lineNumber: Int
    /// Tab-expanded text for crisp display.
    let text: String
    /// Syntax spans remapped to `text`'s UTF-16 coordinates.
    let spans: [SyntaxSpan]
    let isMatchedLine: Bool
    /// Highlighted symbol UTF-16 range inside `text` on the matched line.
    let highlightRange: Range<Int>?
}

/// Multi-line syntax-highlighted context around the currently selected reference.
struct ReferencePreviewContext: Equatable, Sendable {
    let fileURL: URL
    let displayPath: String
    let language: LanguageSpec
    let matchedLineNumber: Int
    let lines: [ReferencePreviewLine]

    static func == (lhs: ReferencePreviewContext, rhs: ReferencePreviewContext) -> Bool {
        lhs.fileURL == rhs.fileURL
            && lhs.displayPath == rhs.displayPath
            && lhs.language === rhs.language
            && lhs.matchedLineNumber == rhs.matchedLineNumber
            && lhs.lines == rhs.lines
    }
}

/// Cached file lines and syntax spans held in memory for the lifetime of the References popup.
struct CachedPreviewFile: Sendable {
    let lines: [String]
    let language: LanguageSpec
    let spans: [[SyntaxSpan]]
}

/// Drives the References / Definitions picker popup with filtering, keyboard navigation, and cached code preview.
@MainActor
@Observable
final class ReferencesPickerModel {
    nonisolated static let contextLinesBefore = 6
    nonisolated static let contextLinesAfter = 8

    var symbolName: String = ""
    var title: String = ""
    var filterQuery: String = "" {
        didSet {
            if filterQuery != oldValue {
                rebuildFiltered()
            }
        }
    }
    var excludeTestGo: Bool {
        didSet {
            if excludeTestGo != oldValue {
                persistAndRefilter()
            }
        }
    }
    var onlyGoFiles: Bool {
        didSet {
            if onlyGoFiles != oldValue {
                persistAndRefilter()
            }
        }
    }
    var items: [ReferenceItem] = []
    private(set) var filteredItems: [ReferenceItem] = []
    var selectedIndex: Int = 0
    var focusToken: Int = 0
    var isLoadingPreviews: Bool = false
    private(set) var previewContext: ReferencePreviewContext?

    var fileFilter: PopupFileFilter {
        PopupFileFilter(excludeTestGo: excludeTestGo, onlyGoFiles: onlyGoFiles)
    }

    @ObservationIgnored var origin: JumpLocation?
    @ObservationIgnored var originFileURL: URL?
    @ObservationIgnored var originRepoRoot: URL?
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var fileCache: [URL: CachedPreviewFile] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = PopupFileFilter.load(scope: .references, defaults: defaults)
        self.excludeTestGo = saved.excludeTestGo
        self.onlyGoFiles = saved.onlyGoFiles
    }

    var selectedItem: ReferenceItem? {
        guard filteredItems.indices.contains(selectedIndex) else { return nil }
        return filteredItems[selectedIndex]
    }

    /// Populates the picker with resolved LSP locations and begins caching file snippets & previews.
    func prepare(
        symbolName: String,
        title: String,
        locations: [LSPLocation],
        declarations: [LSPLocation] = [],
        origin: JumpLocation?,
        originFileURL: URL?,
        originRepoRoot: URL?
    ) {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        let currentGen = generation

        self.symbolName = symbolName
        self.title = title
        self.origin = origin
        self.originFileURL = originFileURL
        self.originRepoRoot = originRepoRoot
        self.fileCache.removeAll()
        self.filterQuery = ""
        self.selectedIndex = 0
        self.previewContext = nil
        self.focusToken += 1

        // Seed the in-memory cache with the currently open live document (captures unsaved edits & semantic tokens).
        if let viewer = store?.viewer,
           let activeURL = viewer.lspDocument?.fileURL,
           let doc = viewer.document,
           case .text = doc.content {
            fileCache[LSPURI.canonicalFileURL(activeURL)] = CachedPreviewFile(
                lines: doc.right.lines,
                language: doc.language,
                spans: doc.right.spans
            )
        }

        let activeRef = store?.currentProject.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let openRefs = store?.projects.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) } ?? []
        let canonicalOrigin = originFileURL.map { LSPURI.canonicalFileURL($0) }

        let deduped = LSPManager.deduplicateLocations(locations)
        var built: [ReferenceItem] = []
        built.reserveCapacity(deduped.count)

        for loc in deduped {
            guard let rawURL = loc.fileURL else { continue }
            let fileURL = LSPURI.canonicalFileURL(rawURL)
            let displayPath = Self.resolveDisplayPath(
                location: loc,
                originFileURL: originFileURL,
                originRepoRoot: originRepoRoot,
                activeProject: activeRef,
                openProjects: openRefs,
                store: store
            )
            let lineNumber = max(1, loc.range.start.line + 1)
            let column = max(0, loc.range.start.character)
            let endColumn = (loc.range.end.line == loc.range.start.line && loc.range.end.character > column)
                ? loc.range.end.character
                : column
            let isDecl = !declarations.isEmpty && LSPNavigationHelper.isPositionOnDefinition(
                fileURL: fileURL,
                line: loc.range.start.line,
                character: column,
                definitions: declarations
            )

            var previewText = ""
            var matchRange: Range<Int>? = nil
            if let cached = fileCache[fileURL], (lineNumber - 1) < cached.lines.count {
                let trimmed = Self.trimLinePreview(
                    cached.lines[lineNumber - 1],
                    column: column,
                    endColumn: endColumn,
                    symbolName: symbolName
                )
                previewText = trimmed.text
                matchRange = trimmed.matchRange
            }

            built.append(ReferenceItem(
                id: built.count,
                location: loc,
                fileURL: fileURL,
                displayPath: displayPath,
                lineNumber: lineNumber,
                column: column,
                endColumn: endColumn,
                linePreview: previewText,
                matchRangeInPreview: matchRange,
                isDeclaration: isDecl
            ))
        }

        // Order declarations first, then same-file references, then alphabetically by path and line number.
        built.sort { lhs, rhs in
            if lhs.isDeclaration != rhs.isDeclaration { return lhs.isDeclaration }
            if let canonicalOrigin {
                let lhsOrigin = lhs.fileURL == canonicalOrigin
                let rhsOrigin = rhs.fileURL == canonicalOrigin
                if lhsOrigin != rhsOrigin { return lhsOrigin }
            }
            let pathOrder = lhs.displayPath.localizedStandardCompare(rhs.displayPath)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            if lhs.lineNumber != rhs.lineNumber { return lhs.lineNumber < rhs.lineNumber }
            return lhs.column < rhs.column
        }

        // Re-index IDs cleanly after sorting.
        self.items = built.enumerated().map { idx, item in
            ReferenceItem(
                id: idx,
                location: item.location,
                fileURL: item.fileURL,
                displayPath: item.displayPath,
                lineNumber: item.lineNumber,
                column: item.column,
                endColumn: item.endColumn,
                linePreview: item.linePreview,
                matchRangeInPreview: item.matchRangeInPreview,
                isDeclaration: item.isDeclaration
            )
        }
        rebuildFiltered()

        // Collect unique uncached file URLs, prioritizing the first selected item's file for instant preview.
        var uncachedOrder: [URL] = []
        var seenURLs: Set<URL> = Set(fileCache.keys)
        if let firstURL = selectedItem?.fileURL, seenURLs.insert(firstURL).inserted {
            uncachedOrder.append(firstURL)
        }
        for item in self.items {
            if seenURLs.insert(item.fileURL).inserted {
                uncachedOrder.append(item.fileURL)
            }
        }

        guard !uncachedOrder.isEmpty else {
            isLoadingPreviews = false
            return
        }

        isLoadingPreviews = true
        let urlsToLoad = uncachedOrder
        let sym = symbolName
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for url in urlsToLoad {
                guard !Task.isCancelled, self.generation == currentGen else { return }
                let loaded = await Task.detached(priority: .userInitiated) {
                    Self.readFileForPreview(at: url)
                }.value
                guard !Task.isCancelled, self.generation == currentGen else { return }
                if let loaded {
                    self.fileCache[url] = loaded
                    self.applyLoadedFile(loaded, for: url, symbolName: sym)
                }
            }
            guard !Task.isCancelled, self.generation == currentGen else { return }
            self.isLoadingPreviews = false
        }
    }

    /// Loads items directly (primarily for unit testing filtering & preview extraction without an `AppStore`).
    func setItemsForTesting(
        symbolName: String,
        title: String,
        items: [ReferenceItem],
        cachedFiles: [URL: CachedPreviewFile] = [:]
    ) {
        loadTask?.cancel()
        loadTask = nil
        self.symbolName = symbolName
        self.title = title
        self.fileCache = cachedFiles
        self.filterQuery = ""
        self.items = items
        self.selectedIndex = 0
        rebuildFiltered()
    }

    func move(_ delta: Int) {
        guard !filteredItems.isEmpty else { return }
        let next = min(filteredItems.count - 1, max(0, selectedIndex + delta))
        guard next != selectedIndex else { return }
        selectedIndex = next
        updatePreviewForSelection()
    }

    func select(_ index: Int) {
        guard filteredItems.indices.contains(index) else { return }
        selectedIndex = index
        updatePreviewForSelection()
    }

    func activate(_ index: Int? = nil) {
        let targetIndex = index ?? selectedIndex
        guard let store, filteredItems.indices.contains(targetIndex) else { return }
        let item = filteredItems[targetIndex]
        let savedOrigin = origin
        let savedOriginFile = originFileURL
        let savedOriginRepo = originRepoRoot
        store.dismissPopup(restoreFocus: false)
        store.navigateToLSPLocation(
            item.location,
            origin: savedOrigin,
            originFileURL: savedOriginFile,
            originRepoRoot: savedOriginRepo
        )
    }

    /// Frees cached file contents when the popup closes.
    func release() {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        isLoadingPreviews = false
        fileCache.removeAll()
        previewContext = nil
    }

    private func persistAndRefilter() {
        fileFilter.save(scope: .references, defaults: defaults)
        rebuildFiltered()
    }

    private func rebuildFiltered() {
        let previousID = selectedItem?.id
        let filtered = Self.filterItems(items, query: filterQuery, fileFilter: fileFilter)
        filteredItems = filtered
        if let previousID, let idx = filtered.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
        updatePreviewForSelection()
    }

    private func applyLoadedFile(_ file: CachedPreviewFile, for url: URL, symbolName: String) {
        var didMutate = false
        for i in items.indices where items[i].fileURL == url {
            let lineIdx = items[i].lineNumber - 1
            guard lineIdx >= 0, lineIdx < file.lines.count else { continue }
            let trimmed = Self.trimLinePreview(
                file.lines[lineIdx],
                column: items[i].column,
                endColumn: items[i].endColumn,
                symbolName: symbolName
            )
            items[i].linePreview = trimmed.text
            items[i].matchRangeInPreview = trimmed.matchRange
            didMutate = true
        }
        if didMutate {
            rebuildFiltered()
        } else if selectedItem?.fileURL == url {
            updatePreviewForSelection()
        }
    }

    func updatePreviewForSelection() {
        guard let item = selectedItem else {
            previewContext = nil
            return
        }
        guard let cached = fileCache[item.fileURL] else {
            previewContext = nil
            return
        }
        previewContext = Self.extractContext(
            fileURL: item.fileURL,
            displayPath: item.displayPath,
            lines: cached.lines,
            spans: cached.spans,
            language: cached.language,
            lineNumber: item.lineNumber,
            column: item.column,
            endColumn: item.endColumn,
            symbolName: symbolName
        )
    }

    // MARK: - Pure Filtering, Snippet & Context Helpers

    /// Filters reference items by file filter toggles and space-separated case-insensitive tokens against path, line preview, and line number.
    nonisolated static func filterItems(
        _ items: [ReferenceItem],
        query: String,
        fileFilter: PopupFileFilter = PopupFileFilter()
    ) -> [ReferenceItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.isEmpty ? [] : trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fileFilter.isActive || !tokens.isEmpty else { return items }
        return items.filter { item in
            guard fileFilter.matches(path: item.displayPath) else { return false }
            return tokens.allSatisfy { token in
                item.displayPath.localizedCaseInsensitiveContains(token)
                    || item.linePreview.localizedCaseInsensitiveContains(token)
                    || "\(item.lineNumber)".contains(token)
            }
        }
    }

    /// Extracts a multi-line syntax-highlighted context window around `lineNumber` (1-based)
    /// with 4-column tab expansion and remapped syntax/highlight UTF-16 ranges.
    nonisolated static func extractContext(
        fileURL: URL,
        displayPath: String,
        lines: [String],
        spans: [[SyntaxSpan]],
        language: LanguageSpec,
        lineNumber: Int,
        column: Int,
        endColumn: Int,
        symbolName: String = "",
        linesBefore: Int = contextLinesBefore,
        linesAfter: Int = contextLinesAfter
    ) -> ReferencePreviewContext? {
        guard !lines.isEmpty else { return nil }
        let targetIdx = max(0, min(lineNumber - 1, lines.count - 1))
        let startIdx = max(0, targetIdx - max(0, linesBefore))
        let endIdx = min(lines.count - 1, targetIdx + max(0, linesAfter))

        var previewLines: [ReferencePreviewLine] = []
        previewLines.reserveCapacity(endIdx - startIdx + 1)

        for idx in startIdx...endIdx {
            let rawLine = lines[idx]
            let rawSpans = idx < spans.count ? spans[idx] : []
            let isMatched = (idx == targetIdx)

            var rawHighlight: Range<Int>? = nil
            if isMatched {
                let lineLen = (rawLine as NSString).length
                let clampedStart = max(0, min(column, lineLen))
                if endColumn > clampedStart {
                    rawHighlight = clampedStart..<min(endColumn, lineLen)
                } else if !symbolName.isEmpty {
                    let symLen = (symbolName as NSString).length
                    let candidateEnd = min(lineLen, clampedStart + symLen)
                    if candidateEnd > clampedStart {
                        rawHighlight = clampedStart..<candidateEnd
                    }
                }
            }

            let expanded = expandTabs(rawLine, spans: rawSpans, highlight: rawHighlight)
            previewLines.append(ReferencePreviewLine(
                id: idx + 1,
                lineNumber: idx + 1,
                text: expanded.text,
                spans: expanded.spans,
                isMatchedLine: isMatched,
                highlightRange: expanded.highlight
            ))
        }

        return ReferencePreviewContext(
            fileURL: fileURL,
            displayPath: displayPath,
            language: language,
            matchedLineNumber: targetIdx + 1,
            lines: previewLines
        )
    }

    /// Expands `\t` to 4-column tab stops while accurately remapping UTF-16 `SyntaxSpan`s and highlight range.
    nonisolated static func expandTabs(
        _ line: String,
        spans: [SyntaxSpan],
        highlight: Range<Int>?,
        tabWidth: Int = 4
    ) -> (text: String, spans: [SyntaxSpan], highlight: Range<Int>?) {
        guard line.utf8.contains(9) else {
            return (line, spans, highlight)
        }
        let ns = line as NSString
        let length = ns.length
        var map = [Int](repeating: 0, count: length + 1)
        var units: [unichar] = []
        units.reserveCapacity(length + 16)
        var visualCol = 0

        for i in 0..<length {
            map[i] = units.count
            let c = ns.character(at: i)
            if c == 9 {
                let spaces = tabWidth - (visualCol % tabWidth)
                for _ in 0..<spaces { units.append(32) }
                visualCol += spaces
            } else {
                units.append(c)
                visualCol += 1
            }
        }
        map[length] = units.count

        let expandedText = String(utf16CodeUnits: units, count: units.count)
        let mappedSpans: [SyntaxSpan] = spans.compactMap { span in
            let s0 = max(0, min(Int(span.start), length))
            let s1 = max(s0, min(Int(span.start + span.length), length))
            let newStart = map[s0]
            let newEnd = map[s1]
            guard newEnd > newStart else { return nil }
            return SyntaxSpan(start: Int32(newStart), length: Int32(newEnd - newStart), kind: span.kind)
        }
        let mappedHighlight: Range<Int>? = highlight.flatMap { range in
            let h0 = map[max(0, min(range.lowerBound, length))]
            let h1 = map[max(0, min(range.upperBound, length))]
            return h1 > h0 ? h0..<h1 : nil
        }
        return (expandedText, mappedSpans, mappedHighlight)
    }

    /// Trims leading indentation for single-line reference list rows while keeping the matched symbol visible.
    nonisolated static func trimLinePreview(
        _ rawLine: String,
        column: Int,
        endColumn: Int,
        symbolName: String
    ) -> (text: String, matchRange: Range<Int>?) {
        let ns = rawLine as NSString
        let length = ns.length
        guard length > 0 else { return ("", nil) }

        var rawMatch: Range<Int>? = nil
        let clampedStart = max(0, min(column, length))
        if endColumn > clampedStart {
            rawMatch = clampedStart..<min(endColumn, length)
        } else if !symbolName.isEmpty {
            let symLen = (symbolName as NSString).length
            let candidateEnd = min(length, clampedStart + symLen)
            if candidateEnd > clampedStart {
                rawMatch = clampedStart..<candidateEnd
            }
        }

        var skip = 0
        while skip < length, ns.character(at: skip) == 32 || ns.character(at: skip) == 9 {
            skip += 1
        }
        if let match = rawMatch, match.lowerBound < skip {
            skip = match.lowerBound
        }
        if let match = rawMatch, match.lowerBound - skip > 56 {
            skip = match.lowerBound - 36
        }

        let sliced = skip > 0 ? ns.substring(from: skip) : rawLine
        let shiftedMatch = rawMatch.map { ($0.lowerBound - skip)..<($0.upperBound - skip) }
        let expanded = expandTabs(sliced, spans: [], highlight: shiftedMatch, tabWidth: 2)
        return (expanded.text, expanded.highlight)
    }

    private static func resolveDisplayPath(
        location: LSPLocation,
        originFileURL: URL?,
        originRepoRoot: URL?,
        activeProject: LSPTargetResolver.ProjectRef?,
        openProjects: [LSPTargetResolver.ProjectRef],
        store: AppStore?
    ) -> String {
        guard let rawURL = location.fileURL else { return location.uri }
        let target = LSPTargetResolver.resolve(
            fileURL: rawURL,
            line: max(1, location.range.start.line + 1),
            column: max(0, location.range.start.character),
            originFileURL: originFileURL,
            originRepoRoot: originRepoRoot,
            activeProject: activeProject,
            openProjects: openProjects
        )
        switch target {
        case .activeProject(_, let rel, _, _, _):
            return rel
        case .otherProject(let projectID, let rel, _, _, _):
            if let name = store?.project(projectID)?.name, !name.isEmpty {
                return "\(name)/\(rel)"
            }
            return rel
        case .externalReadOnly(_, _, _, let display, _, _):
            return display
        }
    }

    nonisolated private static func readFileForPreview(at url: URL) -> CachedPreviewFile? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= DiffLoader.maxTextBytes,
              !TextCodec.looksBinary(data) else {
            return nil
        }
        let text = TextCodec.decode(data)
        let lines = TextCodec.splitLines(text)
        let language = LanguageSpec.detect(path: url.path)
        let spans = Highlighter.highlight(lines, language: language)
        return CachedPreviewFile(lines: lines, language: language, spans: spans)
    }
}

// MARK: - AppStore LSP Navigation

/// Go-to-definition (`⌘+Click` / context menu), Find All References + Preview Picker,
/// cross-repo (`go.work`) / external read-only file navigation, and Back (`⌘[`) / Forward (`⌘]`) jump stack.
extension AppStore {
    var canNavigateBack: Bool { jumpHistory.canGoBack }
    var canNavigateForward: Bool { jumpHistory.canGoForward }

    /// Clears external read-only file mode when the user switches files, tabs, commits, or projects.
    func exitExternalFileMode() {
        if externalRequest != nil { externalRequest = nil }
    }

    /// Smart `⌘+Click` handler:
    /// - If the clicked position IS the symbol's definition/declaration, queries `textDocument/references`
    ///   and opens the References Picker Popup with preview.
    /// - If the clicked position is a reference, jumps directly to a single definition or opens the picker
    ///   when multiple definitions are returned.
    func smartLSPNavigate(line: Int, character: Int) {
        guard AppEnvironment.hasLSP, viewer.isCurrentDocumentLSPEnabled, let request = viewer.request else { return }

        let symbol = symbolAt(line: line, utf16Column: character)
        let origin = makeJumpLocation(from: request, line1Based: line + 1, column: character)
        let lsp = viewer.lspManager

        definitionTask?.cancel()
        definitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let active = await self.viewer.ensureLSPDocumentSynced() else { return }
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }
            let liveText = self.viewer.document?.right.lines.joined(separator: "\n")
            let rawDefs = await lsp.definition(
                fileURL: active.fileURL,
                line: line,
                character: character,
                text: liveText,
                language: active.language,
                repoRoot: active.repoRoot
            )
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

            let defs = LSPManager.deduplicateLocations(rawDefs).filter { $0.fileURL != nil }
            let isOnDef = LSPNavigationHelper.isPositionOnDefinition(
                fileURL: active.fileURL,
                line: line,
                character: character,
                symbolRange: symbol?.range,
                definitions: defs
            )

            if isOnDef {
                var refs = await lsp.references(
                    fileURL: active.fileURL,
                    line: line,
                    character: character,
                    includeDeclaration: false,
                    text: liveText,
                    language: active.language,
                    repoRoot: active.repoRoot
                )
                guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

                refs = refs.filter { $0.fileURL != nil }
                if refs.isEmpty {
                    // Fallback: some servers require includeDeclaration: true; filter out the clicked definition itself.
                    let allRefs = await lsp.references(
                        fileURL: active.fileURL,
                        line: line,
                        character: character,
                        includeDeclaration: true,
                        text: liveText,
                        language: active.language,
                        repoRoot: active.repoRoot
                    ).filter { $0.fileURL != nil }
                    guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

                    let nonSelf = allRefs.filter { loc in
                        !LSPNavigationHelper.isPositionOnDefinition(
                            fileURL: active.fileURL,
                            line: line,
                            character: character,
                            symbolRange: symbol?.range,
                            definitions: [loc]
                        )
                    }
                    refs = nonSelf
                }

                guard !refs.isEmpty else {
                    self.showToast(L("No references found", "未找到引用"))
                    return
                }

                let name = symbol?.name ?? ""
                let title = name.isEmpty
                    ? L("References", "所有引用")
                    : L("References to \(name)", "引用：\(name)")
                self.presentReferencesPicker(
                    symbolName: name,
                    title: title,
                    locations: refs,
                    declarations: defs,
                    origin: origin,
                    originFileURL: active.fileURL,
                    originRepoRoot: active.repoRoot
                )
                return
            }

            guard !defs.isEmpty else {
                self.showToast(L("No definition found", "未找到定义"))
                return
            }

            if defs.count == 1 {
                self.navigateToLSPLocation(
                    defs[0],
                    origin: origin,
                    originFileURL: active.fileURL,
                    originRepoRoot: active.repoRoot
                )
            } else {
                let name = symbol?.name ?? ""
                let title = name.isEmpty
                    ? L("Definitions", "声明列表")
                    : L("Definitions of \(name)", "声明：\(name)")
                self.presentReferencesPicker(
                    symbolName: name,
                    title: title,
                    locations: defs,
                    declarations: defs,
                    origin: origin,
                    originFileURL: active.fileURL,
                    originRepoRoot: active.repoRoot
                )
            }
        }
    }

    /// Explicit "Go to Definition" (e.g. from context menu): always resolves `textDocument/definition`.
    func goToDefinition(atLine line: Int, utf16Column character: Int) {
        guard AppEnvironment.hasLSP, viewer.isCurrentDocumentLSPEnabled, let request = viewer.request else { return }

        let symbol = symbolAt(line: line, utf16Column: character)
        let origin = makeJumpLocation(from: request, line1Based: line + 1, column: character)
        let lsp = viewer.lspManager

        definitionTask?.cancel()
        definitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let active = await self.viewer.ensureLSPDocumentSynced() else { return }
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }
            let liveText = self.viewer.document?.right.lines.joined(separator: "\n")
            let rawDefs = await lsp.definition(
                fileURL: active.fileURL,
                line: line,
                character: character,
                text: liveText,
                language: active.language,
                repoRoot: active.repoRoot
            )
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

            let defs = LSPManager.deduplicateLocations(rawDefs).filter { $0.fileURL != nil }
            guard !defs.isEmpty else {
                self.showToast(L("No definition found", "未找到定义"))
                return
            }

            if defs.count == 1 {
                self.navigateToLSPLocation(
                    defs[0],
                    origin: origin,
                    originFileURL: active.fileURL,
                    originRepoRoot: active.repoRoot
                )
            } else {
                let name = symbol?.name ?? ""
                let title = name.isEmpty
                    ? L("Definitions", "声明列表")
                    : L("Definitions of \(name)", "声明：\(name)")
                self.presentReferencesPicker(
                    symbolName: name,
                    title: title,
                    locations: defs,
                    declarations: defs,
                    origin: origin,
                    originFileURL: active.fileURL,
                    originRepoRoot: active.repoRoot
                )
            }
        }
    }

    /// Compatibility overload forwarding to `goToDefinition(atLine:utf16Column:)`.
    func goToDefinition(line: Int, character: Int) {
        goToDefinition(atLine: line, utf16Column: character)
    }

    /// Explicit "Find All References" (e.g. from context menu): resolves `textDocument/references`
    /// with `includeDeclaration: true` and presents the References Picker Popup with preview.
    func findAllReferences(atLine line: Int, utf16Column character: Int) {
        guard AppEnvironment.hasLSP, viewer.isCurrentDocumentLSPEnabled, let request = viewer.request else { return }

        let symbol = symbolAt(line: line, utf16Column: character)
        let origin = makeJumpLocation(from: request, line1Based: line + 1, column: character)
        let lsp = viewer.lspManager

        definitionTask?.cancel()
        definitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let active = await self.viewer.ensureLSPDocumentSynced() else { return }
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }
            let liveText = self.viewer.document?.right.lines.joined(separator: "\n")
            async let refsTask = lsp.references(
                fileURL: active.fileURL,
                line: line,
                character: character,
                includeDeclaration: true,
                text: liveText,
                language: active.language,
                repoRoot: active.repoRoot
            )
            async let defsTask = lsp.definition(
                fileURL: active.fileURL,
                line: line,
                character: character,
                text: liveText,
                language: active.language,
                repoRoot: active.repoRoot
            )
            let (rawRefs, rawDefs) = await (refsTask, defsTask)
            guard !Task.isCancelled, self.viewer.lspDocument?.fileURL == active.fileURL else { return }

            let refs = LSPManager.deduplicateLocations(rawRefs).filter { $0.fileURL != nil }
            guard !refs.isEmpty else {
                self.showToast(L("No references found", "未找到引用"))
                return
            }

            let name = symbol?.name ?? ""
            let title = name.isEmpty
                ? L("References", "所有引用")
                : L("References to \(name)", "引用：\(name)")
            self.presentReferencesPicker(
                symbolName: name,
                title: title,
                locations: refs,
                declarations: rawDefs,
                origin: origin,
                originFileURL: active.fileURL,
                originRepoRoot: active.repoRoot
            )
        }
    }

    /// Presents the References / Definitions picker popup with code preview.
    func presentReferencesPicker(
        symbolName: String,
        title: String,
        locations: [LSPLocation],
        declarations: [LSPLocation] = [],
        origin: JumpLocation?,
        originFileURL: URL?,
        originRepoRoot: URL?
    ) {
        references.prepare(
            symbolName: symbolName,
            title: title,
            locations: locations,
            declarations: declarations,
            origin: origin,
            originFileURL: originFileURL,
            originRepoRoot: originRepoRoot
        )
        present(.references)
    }

    /// Navigates to an `LSPLocation` (active repo, other open project, `go.work` sibling repo, or external file),
    /// pushing `origin` onto `jumpHistory` when moving to a new file or line.
    func navigateToLSPLocation(
        _ location: LSPLocation,
        origin: JumpLocation?,
        originFileURL: URL?,
        originRepoRoot: URL?
    ) {
        guard let targetURL = location.fileURL else {
            showToast(L("No definition found", "未找到定义"))
            return
        }

        let canonicalTarget = LSPURI.canonicalFileURL(targetURL)
        let targetLine0 = location.range.start.line
        let targetCol = max(0, location.range.start.character)

        if let activeFile = viewer.lspDocument?.fileURL,
           canonicalTarget == activeFile,
           let origin,
           origin.fileURL == canonicalTarget,
           origin.line == targetLine0 + 1 {
            viewer.reveal(line: targetLine0 + 1, column: targetCol)
            viewer.focusCanvas()
            return
        }

        let activeRef = currentProject.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let openRefs = projects.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let fallbackOriginFile = originFileURL ?? viewer.lspDocument?.fileURL ?? canonicalTarget
        let fallbackOriginRepo = originRepoRoot ?? viewer.lspDocument?.repoRoot
        guard let target = LSPTargetResolver.resolve(
            location: location,
            originFileURL: fallbackOriginFile,
            originRepoRoot: fallbackOriginRepo,
            activeProject: activeRef,
            openProjects: openRefs
        ) else {
            showToast(L("No definition found", "未找到定义"))
            return
        }

        if let origin {
            jumpHistory.push(origin)
        }
        isNavigatingJumpHistory = true
        defer { isNavigatingJumpHistory = false }
        navigate(to: target)
    }

    /// Records an in-file jump origin (`line0Based`, `column`) on the unified jump list unless currently walking jump history.
    func recordJumpOrigin(line0Based: Int, column: Int) {
        guard !isNavigatingJumpHistory, let request = viewer.request else { return }
        let origin = makeJumpLocation(from: request, line1Based: line0Based + 1, column: column)
        jumpHistory.push(origin)
    }

    /// Records a cross-file jump origin (`previousRequest`, `line0Based`, `column`) unless currently walking jump history.
    func recordJumpOrigin(from request: DiffRequest, line0Based: Int, column: Int) {
        guard !isNavigatingJumpHistory else { return }
        let origin = makeJumpLocation(from: request, line1Based: line0Based + 1, column: column)
        jumpHistory.push(origin)
    }

    /// Records the current viewer caret as a jump origin when jumping to a different 1-based line in the same file.
    func recordCurrentJumpOriginIfDifferent(targetLine1Based: Int) {
        guard !isNavigatingJumpHistory, let request = viewer.request else { return }
        let pos = viewer.currentCaretPosition()
        guard targetLine1Based != pos.row + 1 else { return }
        let origin = makeJumpLocation(from: request, line1Based: pos.row + 1, column: pos.column)
        jumpHistory.push(origin)
    }

    /// `<C-o>` / `⌘[`: Navigates back to the previous recorded jump location.
    func navigateBack() {
        guard let target = jumpHistory.back(from: currentJumpLocation()) else { return }
        definitionTask?.cancel()
        isNavigatingJumpHistory = true
        defer { isNavigatingJumpHistory = false }
        jumpToLocation(target)
    }

    /// `<C-i>` / `⌘]`: Navigates forward to the next recorded jump location.
    func navigateForward() {
        guard let target = jumpHistory.forward(from: currentJumpLocation()) else { return }
        definitionTask?.cancel()
        isNavigatingJumpHistory = true
        defer { isNavigatingJumpHistory = false }
        jumpToLocation(target)
    }

    // MARK: - Navigation Helpers

    private func symbolAt(line: Int, utf16Column: Int) -> (name: String, range: Range<Int>)? {
        guard let doc = viewer.document,
              case .text = doc.content,
              line >= 0,
              line < doc.right.lines.count else { return nil }
        return LSPNavigationHelper.extractSymbol(in: doc.right.lines[line], at: utf16Column)
    }

    private func currentJumpLocation() -> JumpLocation? {
        guard let request = viewer.request else { return nil }
        let pos = viewer.currentCaretPosition()
        return makeJumpLocation(from: request, line1Based: pos.row + 1, column: pos.column)
    }

    private func makeJumpLocation(from request: DiffRequest, line1Based: Int, column: Int) -> JumpLocation {
        let canonicalFile = LSPURI.canonicalFileURL(request.fileURL)
        if request.isExternalFile {
            return JumpLocation(
                fileURL: canonicalFile,
                projectID: nil,
                relativePath: nil,
                line: max(1, line1Based),
                column: max(0, column),
                isExternal: true
            )
        }
        let canonicalRoot = LSPURI.canonicalFileURL(request.root)
        let project = projects.first { LSPURI.canonicalFileURL($0.url) == canonicalRoot } ?? currentProject
        return JumpLocation(
            fileURL: canonicalFile,
            projectID: project?.id,
            relativePath: request.path,
            line: max(1, line1Based),
            column: max(0, column),
            isExternal: false
        )
    }

    private func navigate(to target: LSPNavigationTarget) {
        switch target {
        case .activeProject(let projectID, let relativePath, _, let line, let column):
            guard let project = projects.first(where: { $0.id == projectID }) ?? currentProject else { return }
            exitExternalFileMode()
            openFile(in: project, path: relativePath, line: line, column: column)
            viewer.focusCanvas()

        case .otherProject(let projectID, let relativePath, _, let line, let column):
            guard let project = projects.first(where: { $0.id == projectID }) else { return }
            exitExternalFileMode()
            uncollapseAncestors(of: project)
            openFile(in: project, path: relativePath, line: line, column: column)
            viewer.focusCanvas()

        case .externalReadOnly(let fileURL, let repoRoot, let workspaceRoot, let displayPath, let line, let column):
            openExternalFile(
                fileURL: fileURL,
                repoRoot: repoRoot,
                workspaceRoot: workspaceRoot,
                displayPath: displayPath,
                line: line,
                column: column
            )
        }
    }

    private func jumpToLocation(_ location: JumpLocation) {
        let targetURL = LSPURI.canonicalFileURL(location.fileURL)
        if let currentRequest = viewer.request,
           LSPURI.canonicalFileURL(currentRequest.fileURL) == targetURL,
           viewer.document != nil,
           !viewer.isLoading {
            // Same currently open file: restore exact caret + scroll in-place without reloading from disk or losing edits.
            viewer.reveal(line: location.line, column: location.column, resetVimToNormal: true)
            viewer.focusCanvas()
            return
        }

        if !location.isExternal,
           let projectID = location.projectID,
           let project = projects.first(where: { $0.id == projectID }),
           let relativePath = location.relativePath {
            exitExternalFileMode()
            uncollapseAncestors(of: project)
            openFile(in: project, path: relativePath, line: location.line, column: location.column)
            viewer.focusCanvas()
            return
        }

        // Re-resolve in case a project was added/removed or the location is external.
        let activeRef = currentProject.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let openRefs = projects.map { LSPTargetResolver.ProjectRef(id: $0.id, rootURL: $0.url) }
        let target = LSPTargetResolver.resolve(
            fileURL: location.fileURL,
            line: location.line,
            column: location.column,
            originFileURL: viewer.lspDocument?.fileURL,
            originRepoRoot: viewer.lspDocument?.repoRoot,
            activeProject: activeRef,
            openProjects: openRefs
        )
        navigate(to: target)
    }

    func openExternalFile(
        fileURL: URL,
        repoRoot: URL?,
        workspaceRoot: URL?,
        displayPath: String,
        line: Int?,
        column: Int? = nil
    ) {
        let canonical = LSPURI.canonicalFileURL(fileURL)
        let baseRoot = repoRoot.map { LSPURI.canonicalFileURL($0) } ?? canonical.deletingLastPathComponent()
        let relPath = LSPTargetResolver.relativePath(of: canonical, inside: baseRoot) ?? canonical.lastPathComponent
        let req = DiffRequest(
            root: baseRoot,
            path: relPath,
            oldPath: nil,
            kind: nil,
            source: .externalFile(displayPath: displayPath, workspaceRoot: workspaceRoot)
        )
        externalRequest = req
        viewer.setBaseStamp(nil)
        viewer.open(req, line: line, column: column)
        viewer.focusCanvas()
    }

    private func uncollapseAncestors(of project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let owners = projects.map { p in p.worktreeOf.flatMap { id in projects.firstIndex { $0.id == id } } }
        let parents = ProjectTree.parents(projects.map(\.url.path), owners: owners)
        let folded = ProjectTree.ancestors(of: index, parents: parents).map { projects[$0].url.path }
        if !collapsedProjects.isDisjoint(with: folded) {
            collapsedProjects.subtract(folded)
        }
    }
}
