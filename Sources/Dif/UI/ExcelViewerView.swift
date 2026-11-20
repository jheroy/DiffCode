import AppKit
import Observation
import SwiftUI

// MARK: - Cell Coordinates & Selection Models

struct ExcelCellCoordinate: Equatable, Hashable, Sendable {
    var row: Int
    var col: Int
}

struct ExcelCellSelection: Equatable, Sendable {
    var anchor: ExcelCellCoordinate
    var extent: ExcelCellCoordinate

    var rowRange: ClosedRange<Int> { min(anchor.row, extent.row)...max(anchor.row, extent.row) }
    var colRange: ClosedRange<Int> { min(anchor.col, extent.col)...max(anchor.col, extent.col) }

    var selectedRows: [Int] { Array(rowRange) }
    var selectedColumns: [Int] { Array(colRange) }

    var rowCount: Int { rowRange.count }
    var colCount: Int { colRange.count }
    var isSingleCell: Bool { anchor == extent }

    func contains(row: Int, col: Int) -> Bool {
        rowRange.contains(row) && colRange.contains(col)
    }

    static func single(row: Int, col: Int) -> ExcelCellSelection {
        let coord = ExcelCellCoordinate(row: row, col: col)
        return ExcelCellSelection(anchor: coord, extent: coord)
    }
}

struct ExcelScrollTarget: Equatable, Sendable {
    let sheetIndex: Int
    /// `-1` for column header match, `0+` for data row.
    let row: Int
    let col: Int
    let center: Bool
}

// MARK: - Observable State / ViewModel

@MainActor
@Observable
final class ExcelViewerState {
    static let hideBottomTabsKey = "excelViewer.hideBottomTabs"

    private let defaults: UserDefaults

    var workbook: XLSXWorkbook
    var fileURL: URL?
    var workbookRevision: Int = 0

    var activeSheetIndex: Int = 0

    // Cross-sheet search
    var searchQuery: String = ""
    var searchMode: XLSXSearchMode = .caseInsensitive
    var searchMatches: [XLSXSearchMatch] = []
    var currentMatchIndex: Int = -1
    var searchFocusToken: Int = 0

    // Active-sheet match cache for O(1) cell rendering lookups
    @ObservationIgnored private(set) var activeSheetMatchSet: Set<XLSXCellAddress> = []
    @ObservationIgnored private var lastSearchedQuery: String = ""
    @ObservationIgnored private var lastSearchedMode: XLSXSearchMode = .caseInsensitive
    @ObservationIgnored private var lastSearchedRevision: Int = -1

    // Per-sheet column visibility (sheetIndex -> set of visible column indices)
    var visibleColumns: [Int: Set<Int>] = [:]
    var columnVisibilityRevision: Int = 0

    // Per-sheet pinned rows (sheetIndex -> set of original 0-based data row indices)
    var pinnedRows: [Int: Set<Int>] = [:]
    var pinnedRowsRevision: Int = 0

    // Selection state for the active sheet
    var selection: ExcelCellSelection?
    var pinnedSelection: ExcelCellSelection?
    var highlightedHeaderColumn: Int?
    var selectionRevision: Int = 0

    // Imperative scroll request consumed by ExcelGridHostView
    var scrollTarget: ExcelScrollTarget?
    var scrollToken: Int = 0

    // Bottom tabs visibility persisted in UserDefaults
    var hideBottomTabs: Bool {
        didSet {
            guard hideBottomTabs != oldValue else { return }
            defaults.set(hideBottomTabs, forKey: Self.hideBottomTabsKey)
        }
    }

    init(workbook: XLSXWorkbook, fileURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.workbook = workbook
        self.fileURL = fileURL
        self.hideBottomTabs = defaults.bool(forKey: Self.hideBottomTabsKey)
        initializeSheetMaps(for: workbook)
    }

    private func initializeSheetMaps(for workbook: XLSXWorkbook) {
        visibleColumns.removeAll()
        pinnedRows.removeAll()
        for (idx, sheet) in workbook.sheets.enumerated() {
            visibleColumns[idx] = Set(0..<sheet.headers.count)
            pinnedRows[idx] = []
        }
    }

    // MARK: Computed Helpers

    var activeSheet: XLSXSheet? {
        guard workbook.sheets.indices.contains(activeSheetIndex) else { return nil }
        return workbook.sheets[activeSheetIndex]
    }

    var activeSheetName: String {
        activeSheet?.name ?? ""
    }

    var currentMatch: XLSXSearchMatch? {
        guard searchMatches.indices.contains(currentMatchIndex) else { return nil }
        return searchMatches[currentMatchIndex]
    }

    var resultsLabelText: String {
        if searchMatches.isEmpty {
            return L("0 results", "0 结果")
        }
        let displayIndex = currentMatchIndex >= 0 ? currentMatchIndex + 1 : 1
        return "\(displayIndex)/\(searchMatches.count)"
    }

    // MARK: Sheet Selection

    func selectSheet(at index: Int) {
        guard workbook.sheets.indices.contains(index) else { return }
        if activeSheetIndex != index {
            activeSheetIndex = index
            selection = nil
            pinnedSelection = nil
            highlightedHeaderColumn = nil
            selectionRevision += 1
            rebuildActiveSheetMatchSet()
        }
    }

    @discardableResult
    func selectSheet(named name: String) -> Bool {
        guard let idx = workbook.sheets.firstIndex(where: { $0.name == name }) else { return false }
        selectSheet(at: idx)
        return true
    }

    /// Filters sheets for the Sheet Switcher popover using case-insensitive substring + `Fuzzy.match`.
    func filterSheets(query: String) -> [(index: Int, name: String)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return workbook.sheets.enumerated().map { ($0.offset, $0.element.name) }
        }
        let lowerQuery = trimmed.lowercased()
        let queryBytes = Array(lowerQuery.utf8).filter { $0 != 32 }

        var scored: [(index: Int, name: String, score: Int)] = []
        scored.reserveCapacity(workbook.sheets.count)
        for (idx, sheet) in workbook.sheets.enumerated() {
            let name = sheet.name
            let hasSubstring = name.localizedCaseInsensitiveContains(trimmed)
            let fuzzyScore = queryBytes.isEmpty ? nil : Fuzzy.match(query: queryBytes, candidate: name, wantPositions: false)?.score
            if hasSubstring || fuzzyScore != nil {
                var total = fuzzyScore ?? 0
                if hasSubstring { total += 2_000 }
                if name.lowercased().hasPrefix(lowerQuery) { total += 1_000 }
                scored.append((idx, name, total))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.index < b.index
        }
        return scored.map { ($0.index, $0.name) }
    }

    // MARK: Cross-Sheet Search

    func requestSearchFocus() {
        searchFocusToken += 1
    }

    func updateSearch(query: String? = nil, mode: XLSXSearchMode? = nil) {
        if let query { searchQuery = query }
        if let mode { searchMode = mode }
        performSearch(jumpToFirst: true)
    }

    func clearSearch() {
        searchQuery = ""
        searchMatches = []
        currentMatchIndex = -1
        highlightedHeaderColumn = nil
        activeSheetMatchSet = []
        lastSearchedQuery = ""
        lastSearchedMode = searchMode
        lastSearchedRevision = workbookRevision
        selectionRevision += 1
    }

    func performSearch(jumpToFirst: Bool = true, force: Bool = false) {
        if !force,
           searchQuery == lastSearchedQuery,
           searchMode == lastSearchedMode,
           workbookRevision == lastSearchedRevision {
            return
        }
        lastSearchedQuery = searchQuery
        lastSearchedMode = searchMode
        lastSearchedRevision = workbookRevision

        guard !searchQuery.isEmpty else {
            searchMatches = []
            currentMatchIndex = -1
            highlightedHeaderColumn = nil
            activeSheetMatchSet = []
            selectionRevision += 1
            return
        }

        searchMatches = workbook.search(query: searchQuery, mode: searchMode)
        if searchMatches.isEmpty {
            currentMatchIndex = -1
            highlightedHeaderColumn = nil
            rebuildActiveSheetMatchSet()
            selectionRevision += 1
            return
        }

        if jumpToFirst {
            currentMatchIndex = 0
            goToMatch(at: 0)
        } else {
            if let onCurrentSheet = searchMatches.firstIndex(where: { $0.sheetIndex == activeSheetIndex }) {
                currentMatchIndex = onCurrentSheet
            } else {
                currentMatchIndex = min(max(0, currentMatchIndex), searchMatches.count - 1)
            }
            rebuildActiveSheetMatchSet()
            selectionRevision += 1
        }
    }

    func navigateSearch(_ delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let count = searchMatches.count
        if currentMatchIndex < 0 {
            currentMatchIndex = delta >= 0 ? 0 : count - 1
        } else {
            currentMatchIndex = ((currentMatchIndex + delta) % count + count) % count
        }
        goToMatch(at: currentMatchIndex)
    }

    private func goToMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        let match = searchMatches[index]
        if activeSheetIndex != match.sheetIndex {
            activeSheetIndex = match.sheetIndex
            pinnedSelection = nil
        }
        rebuildActiveSheetMatchSet()

        guard let sheet = activeSheet else { return }
        if match.row == -1 {
            // Header match: highlight/select entire column and scroll horizontally to it.
            highlightedHeaderColumn = match.col
            if !sheet.rows.isEmpty {
                selection = ExcelCellSelection(
                    anchor: ExcelCellCoordinate(row: 0, col: match.col),
                    extent: ExcelCellCoordinate(row: sheet.rows.count - 1, col: match.col)
                )
            } else {
                selection = nil
            }
            scrollTarget = ExcelScrollTarget(sheetIndex: match.sheetIndex, row: -1, col: match.col, center: true)
        } else {
            highlightedHeaderColumn = nil
            selection = .single(row: match.row, col: match.col)
            scrollTarget = ExcelScrollTarget(sheetIndex: match.sheetIndex, row: match.row, col: match.col, center: true)
        }
        pinnedSelection = nil
        selectionRevision += 1
        scrollToken += 1
    }

    private func rebuildActiveSheetMatchSet() {
        var set: Set<XLSXCellAddress> = []
        for match in searchMatches where match.sheetIndex == activeSheetIndex {
            set.insert(XLSXCellAddress(row: match.row, col: match.col))
        }
        activeSheetMatchSet = set
    }

    // MARK: Column Visibility

    func visibleColumns(for sheetIndex: Int? = nil) -> Set<Int> {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return [] }
        if let existing = visibleColumns[idx] {
            return existing
        }
        return Set(0..<workbook.sheets[idx].headers.count)
    }

    func visibleColumnIndices(for sheetIndex: Int? = nil) -> [Int] {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return [] }
        let set = visibleColumns(for: idx)
        return (0..<workbook.sheets[idx].headers.count).filter { set.contains($0) }
    }

    func isColumnVisible(_ col: Int, sheetIndex: Int? = nil) -> Bool {
        visibleColumns(for: sheetIndex).contains(col)
    }

    func toggleColumn(_ col: Int, sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx),
              col >= 0, col < workbook.sheets[idx].headers.count else { return }
        var set = visibleColumns(for: idx)
        if set.contains(col) {
            set.remove(col)
        } else {
            set.insert(col)
        }
        visibleColumns[idx] = set
        columnVisibilityRevision += 1
    }

    func setColumnVisible(_ col: Int, visible: Bool, sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx),
              col >= 0, col < workbook.sheets[idx].headers.count else { return }
        var set = visibleColumns(for: idx)
        let changed = visible ? set.insert(col).inserted : (set.remove(col) != nil)
        guard changed else { return }
        visibleColumns[idx] = set
        columnVisibilityRevision += 1
    }

    func selectAllColumns(sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return }
        visibleColumns[idx] = Set(0..<workbook.sheets[idx].headers.count)
        columnVisibilityRevision += 1
    }

    func clearAllColumns(sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return }
        visibleColumns[idx] = []
        columnVisibilityRevision += 1
    }

    func hiddenColumnCount(sheetIndex: Int? = nil) -> Int {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return 0 }
        let total = workbook.sheets[idx].headers.count
        return max(0, total - visibleColumns(for: idx).count)
    }

    // MARK: Pinned Rows

    func sortedPinnedRows(for sheetIndex: Int? = nil) -> [Int] {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return [] }
        let rowCount = workbook.sheets[idx].rows.count
        let set = pinnedRows[idx] ?? []
        return set.filter { $0 >= 0 && $0 < rowCount }.sorted()
    }

    func hasPinnedRows(sheetIndex: Int? = nil) -> Bool {
        !sortedPinnedRows(for: sheetIndex).isEmpty
    }

    func areAllRowsPinned(_ rows: [Int], sheetIndex: Int? = nil) -> Bool {
        guard !rows.isEmpty else { return false }
        let idx = sheetIndex ?? activeSheetIndex
        let set = pinnedRows[idx] ?? []
        return rows.allSatisfy { set.contains($0) }
    }

    func pinRows(_ rows: [Int], sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return }
        let rowCount = workbook.sheets[idx].rows.count
        var set = pinnedRows[idx] ?? []
        var changed = false
        for r in rows where r >= 0 && r < rowCount {
            if set.insert(r).inserted { changed = true }
        }
        guard changed else { return }
        pinnedRows[idx] = set
        pinnedRowsRevision += 1
    }

    func unpinRows(_ rows: [Int], sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard workbook.sheets.indices.contains(idx) else { return }
        var set = pinnedRows[idx] ?? []
        var changed = false
        for r in rows {
            if set.remove(r) != nil { changed = true }
        }
        guard changed else { return }
        pinnedRows[idx] = set
        if idx == activeSheetIndex { pinnedSelection = nil }
        pinnedRowsRevision += 1
    }

    func unpinPinnedTableRows(_ pinnedIndices: [Int], sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        let sorted = sortedPinnedRows(for: idx)
        let originalRows = pinnedIndices.compactMap { sorted.indices.contains($0) ? sorted[$0] : nil }
        unpinRows(originalRows, sheetIndex: idx)
    }

    func unpinAllRows(sheetIndex: Int? = nil) {
        let idx = sheetIndex ?? activeSheetIndex
        guard !(pinnedRows[idx]?.isEmpty ?? true) else { return }
        pinnedRows[idx] = []
        if idx == activeSheetIndex { pinnedSelection = nil }
        pinnedRowsRevision += 1
    }

    // MARK: Selection & TSV Formatting

    func selectCell(row: Int, col: Int) {
        guard let sheet = activeSheet,
              row >= 0, row < sheet.rows.count,
              col >= 0, col < sheet.headers.count else { return }
        selection = .single(row: row, col: col)
        pinnedSelection = nil
        highlightedHeaderColumn = nil
        selectionRevision += 1
    }

    func selectAllCells() {
        guard let sheet = activeSheet, !sheet.rows.isEmpty else { return }
        let visCols = visibleColumnIndices()
        guard let firstCol = visCols.first, let lastCol = visCols.last else { return }
        selection = ExcelCellSelection(
            anchor: ExcelCellCoordinate(row: 0, col: firstCol),
            extent: ExcelCellCoordinate(row: sheet.rows.count - 1, col: lastCol)
        )
        pinnedSelection = nil
        highlightedHeaderColumn = nil
        selectionRevision += 1
    }

    func clearSelection() {
        selection = nil
        pinnedSelection = nil
        highlightedHeaderColumn = nil
        selectionRevision += 1
    }

    func formattedSelectionTSV(fromPinned: Bool = false) -> String {
        guard let sheet = activeSheet else { return "" }
        let vis = visibleColumns(for: activeSheetIndex)
        if fromPinned {
            guard let sel = pinnedSelection else { return "" }
            let sorted = sortedPinnedRows(for: activeSheetIndex)
            let originalRows = sel.selectedRows.compactMap { sorted.indices.contains($0) ? sorted[$0] : nil }
            return sheet.formatTSV(rows: originalRows, columns: sel.selectedColumns, visibleColumns: vis)
        } else {
            guard let sel = selection else { return "" }
            return sheet.formatTSV(rows: sel.selectedRows, columns: sel.selectedColumns, visibleColumns: vis)
        }
    }

    // MARK: Disk Reload Preservation

    /// Replaces the workbook (e.g. after a disk reload) while preserving active sheet name,
    /// search query & mode, pinned rows (within new row bounds), and column visibility.
    func applyWorkbook(_ newWorkbook: XLSXWorkbook, fileURL: URL? = nil, isReload: Bool) {
        let previousSheetName = activeSheet?.name
        let previousSheetIndex = activeSheetIndex

        var previousPinnedByName: [String: Set<Int>] = [:]
        var previousVisibleByName: [String: Set<Int>] = [:]
        var previousColCountByName: [String: Int] = [:]
        for (idx, sheet) in workbook.sheets.enumerated() {
            if let pinned = pinnedRows[idx], !pinned.isEmpty {
                previousPinnedByName[sheet.name] = pinned
            }
            if let vis = visibleColumns[idx] {
                previousVisibleByName[sheet.name] = vis
            }
            previousColCountByName[sheet.name] = sheet.headers.count
        }

        self.workbook = newWorkbook
        if let fileURL { self.fileURL = fileURL }

        var nextVisible: [Int: Set<Int>] = [:]
        var nextPinned: [Int: Set<Int>] = [:]

        for (idx, sheet) in newWorkbook.sheets.enumerated() {
            let newColCount = sheet.headers.count
            if isReload, let prevVis = previousVisibleByName[sheet.name] {
                let oldColCount = previousColCountByName[sheet.name] ?? newColCount
                var merged = prevVis.filter { $0 >= 0 && $0 < newColCount }
                if newColCount > oldColCount {
                    for extraCol in oldColCount..<newColCount { merged.insert(extraCol) }
                }
                nextVisible[idx] = merged
            } else {
                nextVisible[idx] = Set(0..<newColCount)
            }

            if isReload, let prevPinned = previousPinnedByName[sheet.name] {
                nextPinned[idx] = prevPinned.filter { $0 >= 0 && $0 < sheet.rows.count }
            } else {
                nextPinned[idx] = []
            }
        }

        visibleColumns = nextVisible
        pinnedRows = nextPinned

        if let name = previousSheetName, let matchIdx = newWorkbook.sheets.firstIndex(where: { $0.name == name }) {
            activeSheetIndex = matchIdx
        } else if newWorkbook.sheets.indices.contains(previousSheetIndex) {
            activeSheetIndex = previousSheetIndex
        } else {
            activeSheetIndex = 0
        }

        // Clamp or clear selections to fit new dimensions.
        if let sheet = activeSheet, let sel = selection {
            if sel.rowRange.upperBound >= sheet.rows.count || sel.colRange.upperBound >= sheet.headers.count {
                selection = nil
            }
        } else {
            selection = nil
        }
        pinnedSelection = nil
        highlightedHeaderColumn = nil

        workbookRevision += 1
        if isReload && !searchQuery.isEmpty {
            performSearch(jumpToFirst: false, force: true)
        } else if !isReload {
            searchQuery = ""
            searchMatches = []
            currentMatchIndex = -1
            activeSheetMatchSet = []
            lastSearchedQuery = ""
            lastSearchedMode = searchMode
            lastSearchedRevision = workbookRevision
        }

        columnVisibilityRevision += 1
        pinnedRowsRevision += 1
        selectionRevision += 1
    }
}

// MARK: - Helpers

private func excelCopyToPasteboard(_ text: String, toast: ((String) -> Void)? = nil) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(text, forType: .string)
    if let toast {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let preview = singleLine.count > 30 ? String(singleLine.prefix(30)) + "..." : singleLine
        toast(L("Copied: \(preview)", "已复制: \(preview)"))
    }
}

// MARK: - Top-Level ExcelViewerView

struct ExcelViewerView: View {
    let workbook: XLSXWorkbook
    let fileURL: URL?
    let sessionKey: String
    let viewer: ViewerModel

    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    @State private var showSheetPopover = false
    @State private var showColumnsPopover = false

    private var state: ExcelViewerState {
        viewer.excelSession(for: sessionKey, workbook: workbook, fileURL: fileURL)
    }

    var body: some View {
        let session = state
        VStack(spacing: 0) {
            ExcelToolbar(
                state: session,
                fileURL: fileURL,
                showSheetPopover: $showSheetPopover,
                showColumnsPopover: $showColumnsPopover
            )
            Rectangle().fill(Color.difHairline).frame(height: 1)

            if session.workbook.sheets.isEmpty {
                EmptyListState(
                    symbol: "tablecells",
                    title: L("Empty Workbook", "空工作簿"),
                    detail: L("This spreadsheet contains no worksheets.", "此表格不包含任何工作表。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let sheet = session.activeSheet, sheet.headers.isEmpty && sheet.rows.isEmpty {
                EmptyListState(
                    symbol: "tablecells",
                    title: sheet.name,
                    detail: L("This worksheet is empty.", "此工作表为空。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ExcelTableContainerView(
                    state: session,
                    codeFont: CodeFont.current(store.settings),
                    isDark: colorScheme == .dark,
                    onToast: { store.showToast($0) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !session.hideBottomTabs && !session.workbook.sheets.isEmpty {
                Rectangle().fill(Color.difHairline).frame(height: 1)
                ExcelBottomTabsBar(state: session) { copiedName in
                    excelCopyToPasteboard(copiedName) { store.showToast($0) }
                }
            }
        }
        .background(Color.difWindow)
        .onAppear {
            consumePendingSheet(on: session)
        }
        .onChange(of: viewer.excelSheetSelectToken) { _, _ in
            consumePendingSheet(on: session)
        }
        .onChange(of: session.workbookRevision) { _, _ in
            consumePendingSheet(on: session)
        }
    }

    private func consumePendingSheet(on session: ExcelViewerState) {
        guard let target = viewer.pendingExcelSheet else { return }
        _ = session.selectSheet(named: target)
        viewer.pendingExcelSheet = nil
    }
}

// MARK: - Top Toolbar

private struct ExcelToolbar: View {
    @Bindable var state: ExcelViewerState
    let fileURL: URL?
    @Binding var showSheetPopover: Bool
    @Binding var showColumnsPopover: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Left: Cross-Sheet Search
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText3)
                    SearchField(
                        text: $state.searchQuery,
                        placeholder: L("Search cells or headers…", "搜索单元格或表头…"),
                        font: .systemFont(ofSize: 12 * UI.scale),
                        focusToken: state.searchFocusToken,
                        onMove: { state.navigateSearch($0 > 0 ? 1 : -1) },
                        onSubmit: { state.navigateSearch(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) },
                        onCancel: {
                            if !state.searchQuery.isEmpty { state.clearSearch() }
                        }
                    )
                    .frame(minWidth: UI.s(150), idealWidth: UI.s(220), maxWidth: UI.s(280), maxHeight: UI.s(20))

                    if !state.searchQuery.isEmpty {
                        Button {
                            state.clearSearch()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.ui(size: 11))
                                .foregroundStyle(Color.difText3)
                        }
                        .buttonStyle(.plain)
                        .help(L("Clear Search", "清空搜索"))
                    }
                }
                .padding(.horizontal, 7)
                .frame(height: UI.s(24))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.difWindow)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.difHairline, lineWidth: 1)
                )

                // Search mode picker
                Menu {
                    ForEach(XLSXSearchMode.allCases) { mode in
                        Button {
                            state.updateSearch(mode: mode)
                        } label: {
                            if state.searchMode == mode {
                                Label(mode.displayName, systemImage: "checkmark")
                            } else {
                                Text(mode.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(state.searchMode.displayName)
                            .font(.ui(size: 11, weight: .medium))
                            .foregroundStyle(Color.difText2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.ui(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.difText3)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: UI.s(24))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L("Search Mode", "搜索模式"))

                // Results counter
                Text(state.resultsLabelText)
                    .font(.ui(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(!state.searchQuery.isEmpty && state.searchMatches.isEmpty ? Color.difRemoved : Color.difText3)
                    .fixedSize()
                    .padding(.horizontal, 2)

                // Prev / Next match
                HStack(spacing: 2) {
                    IconButton(symbol: "chevron.up", help: L("Previous Match (⇧⌘G / ⌘P)", "上一个匹配 (⇧⌘G / ⌘P)"), size: 11) {
                        state.navigateSearch(-1)
                    }
                    .disabled(state.searchMatches.isEmpty)
                    .opacity(state.searchMatches.isEmpty ? 0.35 : 1)

                    IconButton(symbol: "chevron.down", help: L("Next Match (⌘G / ⌘N)", "下一个匹配 (⌘G / ⌘N)"), size: 11) {
                        state.navigateSearch(1)
                    }
                    .disabled(state.searchMatches.isEmpty)
                    .opacity(state.searchMatches.isEmpty ? 0.35 : 1)
                }
            }

            Spacer(minLength: 8)

            // Right: Actions
            HStack(spacing: 6) {
                // Hide Tabs toggle
                Button {
                    state.hideBottomTabs.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: state.hideBottomTabs ? "checkmark.square.fill" : "square")
                            .font(.ui(size: 11))
                            .foregroundStyle(state.hideBottomTabs ? Color.difAccent : Color.difText3)
                        Text(L("Hide Tabs", "隐藏标签"))
                            .font(.ui(size: 11.5))
                            .foregroundStyle(Color.difText2)
                    }
                    .padding(.horizontal, 7)
                    .frame(height: UI.s(24))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help(L("Hide or show the bottom worksheet tabs", "隐藏或显示底部工作表标签栏"))

                // Sheet Switcher Popover button
                if !state.workbook.sheets.isEmpty {
                    Button {
                        showSheetPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "tablecells")
                                .font(.ui(size: 10.5))
                                .foregroundStyle(Color.difAccent)
                            Text(state.activeSheetName.isEmpty ? L("Sheets", "工作表") : state.activeSheetName)
                                .font(.ui(size: 11.5, weight: .medium))
                                .foregroundStyle(Color.difText)
                                .lineLimit(1)
                                .frame(maxWidth: UI.s(150))
                            Image(systemName: "chevron.down")
                                .font(.ui(size: 8.5, weight: .semibold))
                                .foregroundStyle(Color.difText3)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: UI.s(24))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Switch Worksheet", "切换工作表"))
                    .popover(isPresented: $showSheetPopover, arrowEdge: .bottom) {
                        ExcelSheetSwitcherPopover(state: state) {
                            showSheetPopover = false
                        }
                    }
                }

                // Columns Filter Popover button
                if let sheet = state.activeSheet, !sheet.headers.isEmpty {
                    let total = sheet.headers.count
                    let visible = state.visibleColumns(for: state.activeSheetIndex).count
                    let filtered = visible < total
                    Button {
                        showColumnsPopover.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.ui(size: 11))
                                .foregroundStyle(filtered ? Color.difAccent : Color.difText3)
                            Text(filtered
                                 ? L("Columns (\(visible)/\(total))", "列筛选 (\(visible)/\(total))")
                                 : L("Columns", "列筛选"))
                                .font(.ui(size: 11.5, weight: filtered ? .semibold : .regular))
                                .foregroundStyle(filtered ? Color.difAccent : Color.difText)
                            Image(systemName: "chevron.down")
                                .font(.ui(size: 8.5, weight: .semibold))
                                .foregroundStyle(Color.difText3)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: UI.s(24))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(filtered ? Color.difSelection : Color.difChip)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Show or hide columns in the current sheet", "显示或隐藏当前工作表的列"))
                    .popover(isPresented: $showColumnsPopover, arrowEdge: .bottom) {
                        ExcelColumnsFilterPopover(state: state)
                    }
                }

                // Open External button
                if let fileURL {
                    Button {
                        NSWorkspace.shared.open(fileURL)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.ui(size: 11))
                                .foregroundStyle(Color.difText2)
                            Text(L("Open External", "外部打开"))
                                .font(.ui(size: 11.5))
                                .foregroundStyle(Color.difText)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: UI.s(24))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help(L("Open this file in the system default application", "使用系统默认应用打开此文件"))
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: UI.s(36))
        .background(Color.difPanel)
        .onChange(of: state.searchQuery) { _, _ in
            state.performSearch(jumpToFirst: true)
        }
    }
}

// MARK: - Sheet Switcher Popover

private struct ExcelSheetSwitcherPopover: View {
    let state: ExcelViewerState
    let onDismiss: () -> Void

    @State private var query = ""
    @State private var highlightedRow = 0
    @State private var focusToken = 1

    private var filteredSheets: [(index: Int, name: String)] {
        state.filterSheets(query: query)
    }

    var body: some View {
        let items = filteredSheets
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                SearchField(
                    text: $query,
                    placeholder: L("Search sheet…", "搜索工作表…"),
                    font: .systemFont(ofSize: 12.5 * UI.scale),
                    focusToken: focusToken,
                    onMove: { delta in
                        guard !items.isEmpty else { return }
                        highlightedRow = max(0, min(items.count - 1, highlightedRow + delta))
                    },
                    onSubmit: {
                        if items.indices.contains(highlightedRow) {
                            state.selectSheet(at: items[highlightedRow].index)
                            onDismiss()
                        }
                    },
                    onCancel: {
                        onDismiss()
                    }
                )
                .frame(height: UI.s(20))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            if items.isEmpty {
                Text(L("No matching sheets", "没有匹配的工作表"))
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(items.enumerated()), id: \.element.index) { offset, item in
                                let isActive = item.index == state.activeSheetIndex
                                let isHighlighted = offset == highlightedRow
                                let sheet = state.workbook.sheets[item.index]
                                HStack(spacing: 8) {
                                    Image(systemName: isActive ? "checkmark" : "tablecells")
                                        .font(.ui(size: 10.5, weight: isActive ? .semibold : .regular))
                                        .foregroundStyle(isActive ? Color.difAccent : Color.difText3)
                                        .frame(width: UI.s(14))
                                    Text(item.name)
                                        .font(.ui(size: 12, weight: isActive ? .semibold : .regular))
                                        .foregroundStyle(Color.difText)
                                        .lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text("\(sheet.rows.count)×\(sheet.headers.count)")
                                        .font(.ui(size: 10.5, design: .rounded))
                                        .foregroundStyle(Color.difText3)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: UI.s(26))
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(isHighlighted ? Color.difSelection : Color.clear)
                                )
                                .contentShape(Rectangle())
                                .id(item.index)
                                .onTapGesture {
                                    state.selectSheet(at: item.index)
                                    onDismiss()
                                }
                            }
                        }
                        .padding(5)
                    }
                    .onChange(of: highlightedRow) { _, newValue in
                        if items.indices.contains(newValue) {
                            proxy.scrollTo(items[newValue].index)
                        }
                    }
                }
            }
        }
        .frame(width: UI.s(300), height: UI.s(340))
        .background(Color.difElevated)
        .onAppear {
            if let currentPos = items.firstIndex(where: { $0.index == state.activeSheetIndex }) {
                highlightedRow = currentPos
            } else {
                highlightedRow = 0
            }
            focusToken += 1
        }
        .onChange(of: query) { _, _ in
            highlightedRow = 0
        }
    }
}

// MARK: - Columns Filter Popover

private struct ExcelColumnsFilterPopover: View {
    let state: ExcelViewerState

    @State private var query = ""
    @State private var focusToken = 1

    var body: some View {
        let headers = state.activeSheet?.headers ?? []
        let visibleSet = state.visibleColumns(for: state.activeSheetIndex)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [(index: Int, name: String)] = headers.enumerated().compactMap { idx, name in
            if trimmed.isEmpty || name.localizedCaseInsensitiveContains(trimmed) {
                return (idx, name)
            }
            return nil
        }

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                SearchField(
                    text: $query,
                    placeholder: L("Filter columns…", "筛选列…"),
                    font: .systemFont(ofSize: 12 * UI.scale),
                    focusToken: focusToken
                )
                .frame(height: UI.s(20))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            if filtered.isEmpty {
                Text(L("No matching columns", "没有匹配的列"))
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filtered, id: \.index) { col in
                            let isVisible = visibleSet.contains(col.index)
                            HStack(spacing: 8) {
                                Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                                    .font(.ui(size: 12))
                                    .foregroundStyle(isVisible ? Color.difAccent : Color.difText3)
                                Text(col.name)
                                    .font(.ui(size: 12))
                                    .foregroundStyle(isVisible ? Color.difText : Color.difText3)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: UI.s(24))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                state.toggleColumn(col.index)
                            }
                        }
                    }
                    .padding(5)
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)

            HStack(spacing: 8) {
                Button(L("All", "全选")) {
                    state.selectAllColumns()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L("None", "清空")) {
                    state.clearAllColumns()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("\(visibleSet.count)/\(headers.count)")
                    .font(.ui(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.difText3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
        .frame(width: UI.s(270), height: UI.s(340))
        .background(Color.difElevated)
        .onAppear { focusToken += 1 }
    }
}

// MARK: - Bottom Sheet Tabs Bar

private struct ExcelBottomTabsBar: View {
    let state: ExcelViewerState
    let onCopySheetName: (String) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(state.workbook.sheets.enumerated()), id: \.offset) { idx, sheet in
                        let isActive = idx == state.activeSheetIndex
                        Text(sheet.name)
                            .font(.ui(size: 11.5, weight: isActive ? .semibold : .regular))
                            .foregroundStyle(isActive ? Color.difText : Color.difText2)
                            .lineLimit(1)
                            .padding(.horizontal, 11)
                            .frame(height: UI.s(26))
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(isActive ? Color.difWindow : Color.clear)
                            )
                            .overlay(alignment: .bottom) {
                                if isActive {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.difAccent)
                                        .frame(height: 2)
                                        .padding(.horizontal, 6)
                                }
                            }
                            .contentShape(Rectangle())
                            .id(idx)
                            .help(L("Click to switch · Double-click to copy name", "单击切换 · 双击复制工作表名"))
                            .onTapGesture {
                                state.selectSheet(at: idx)
                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                    onCopySheetName(sheet.name)
                                }
                            }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
            }
            .frame(height: UI.s(30))
            .background(Color.difPanel)
            .onChange(of: state.activeSheetIndex) { _, newIndex in
                withAnimation(.snappy(duration: 0.16)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

// MARK: - AppKit 2D Grid Bridge (`NSViewRepresentable`)

struct ExcelTableContainerView: NSViewRepresentable {
    let state: ExcelViewerState
    let codeFont: CodeFont
    let isDark: Bool
    let onToast: (String) -> Void

    @MainActor
    final class Coordinator {
        weak var lastState: ExcelViewerState?
        var lastWorkbookRevision = -1
        var lastSheetIndex = -1
        var lastVisibilityRevision = -1
        var lastPinnedRevision = -1
        var lastSelectionRevision = -1
        var lastScrollToken = -1
        var lastIsDark: Bool?
        var lastFontSize: CGFloat = 0
        var lastFontName: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ExcelGridHostView {
        let host = ExcelGridHostView(frame: .zero)
        host.onToast = onToast
        return host
    }

    func updateNSView(_ host: ExcelGridHostView, context: Context) {
        let coord = context.coordinator
        host.onToast = onToast

        let cellFont = makeCellFont(from: codeFont)
        let headerFont = NSFont.systemFont(ofSize: max(11, min(14, cellFont.pointSize)), weight: .semibold)
        let stateChanged = coord.lastState !== state
        let fontChanged = coord.lastFontSize != cellFont.pointSize || coord.lastFontName != cellFont.fontName
        let themeChanged = coord.lastIsDark != isDark
        let workbookChanged = stateChanged || coord.lastWorkbookRevision != state.workbookRevision
        let sheetChanged = stateChanged || coord.lastSheetIndex != state.activeSheetIndex
        let visibilityChanged = stateChanged || coord.lastVisibilityRevision != state.columnVisibilityRevision
        let pinnedChanged = stateChanged || coord.lastPinnedRevision != state.pinnedRowsRevision
        let selectionChanged = stateChanged || coord.lastSelectionRevision != state.selectionRevision
        let scrollChanged = coord.lastScrollToken != state.scrollToken || (stateChanged && state.scrollTarget != nil)

        coord.lastState = state
        host.state = state

        if fontChanged || themeChanged {
            host.applyStyle(cellFont: cellFont, headerFont: headerFont, isDark: isDark)
            coord.lastFontSize = cellFont.pointSize
            coord.lastFontName = cellFont.fontName
            coord.lastIsDark = isDark
        }

        if workbookChanged {
            host.resetCachedColumnWidths()
            coord.lastWorkbookRevision = state.workbookRevision
        }

        if workbookChanged || sheetChanged {
            host.reloadActiveSheet()
            coord.lastSheetIndex = state.activeSheetIndex
            coord.lastVisibilityRevision = state.columnVisibilityRevision
            coord.lastPinnedRevision = state.pinnedRowsRevision
            coord.lastSelectionRevision = state.selectionRevision
        } else {
            if visibilityChanged {
                host.applyColumnVisibility()
                coord.lastVisibilityRevision = state.columnVisibilityRevision
            }
            if pinnedChanged {
                host.reloadPinnedRows()
                coord.lastPinnedRevision = state.pinnedRowsRevision
            }
            if selectionChanged || themeChanged || fontChanged {
                host.refreshHighlightsAndSelection()
                coord.lastSelectionRevision = state.selectionRevision
            }
        }

        if scrollChanged, let target = state.scrollTarget {
            coord.lastScrollToken = state.scrollToken
            host.scrollTo(target)
        }
    }

    private func makeCellFont(from codeFont: CodeFont) -> NSFont {
        let targetSize = max(11, min(18, codeFont.size - 1))
        return NSFont(descriptor: codeFont.font.fontDescriptor, size: targetSize)
            ?? NSFont.monospacedSystemFont(ofSize: targetSize, weight: .regular)
    }
}

// MARK: - AppKit Cell View (Zero-Subview CoreGraphics Renderer)

private final class ExcelCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ExcelCellView")

    var text: String = ""
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var textColor: NSColor = Palette.textPrimary
    var backgroundColor: NSColor = Palette.window
    var selectionTint: NSColor = Palette.selection
    var matchTint: NSColor = NSColor(cgColor: CanvasTheme.dark.searchMatch) ?? .systemYellow
    var currentMatchTint: NSColor = NSColor(cgColor: CanvasTheme.dark.searchCurrent) ?? .systemOrange
    var accentBorderColor: NSColor = Palette.accent
    var gridColor: NSColor = Palette.hairline
    var isSelected: Bool = false
    var isSearchMatch: Bool = false
    var isCurrentSearchMatch: Bool = false
    var hasComment: Bool = false

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .left
        return style
    }()

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        backgroundColor.setFill()
        bounds.fill()

        if isSearchMatch && !isCurrentSearchMatch {
            matchTint.setFill()
            bounds.fill()
        }

        if isSelected {
            selectionTint.setFill()
            bounds.fill()
        }

        if isCurrentSearchMatch {
            currentMatchTint.setFill()
            bounds.fill()
        }

        // Subtle right + bottom gridlines
        gridColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()

        if isCurrentSearchMatch {
            accentBorderColor.setStroke()
            let inset = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(rect: inset)
            path.lineWidth = 1.5
            path.stroke()
        }

        // Single-line display text (newlines folded to spaces for crisp row height; raw text copied on ⌘C).
        if !text.isEmpty {
            let display: NSString
            if text.contains("\n") || text.contains("\r") {
                display = text
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ") as NSString
            } else {
                display = text as NSString
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: Self.paragraphStyle,
            ]
            let lineH = ceil(font.ascender - font.descender + font.leading)
            let textY = floor((bounds.height - lineH) / 2)
            let rightInset: CGFloat = hasComment ? 10 : 6
            let textRect = NSRect(
                x: 6,
                y: max(1, textY),
                width: max(0, bounds.width - 6 - rightInset),
                height: min(bounds.height, lineH + 2)
            )
            display.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
        }

        // Crisp 6x6 red corner triangle for cell comments
        if hasComment {
            NSColor.systemRed.setFill()
            let tri = NSBezierPath()
            let s: CGFloat = 6
            tri.move(to: NSPoint(x: bounds.maxX - s, y: 0))
            tri.line(to: NSPoint(x: bounds.maxX, y: 0))
            tri.line(to: NSPoint(x: bounds.maxX, y: s))
            tri.close()
            tri.fill()
        }
    }
}

// MARK: - AppKit Header Cell & Header View (Red Comment Triangle, Tooltips, Click-to-Copy)

/// Custom table header cell for Excel columns.
/// IMPORTANT: Keep ONLY trivial bitwise-copy-safe value properties (`Bool` flags) on this
/// `NSCell` subclass — NEVER add Swift reference-counted stored properties (`NSColor`, `String`,
/// objects, etc.), because `NSCell.copy(with:)` uses `NSCopyObject` (raw `memcpy`) without
/// retaining Swift ivars, causing a double-free `SIGSEGV` in `__ivar_destroyer` on dealloc.
final class ExcelHeaderCell: NSTableHeaderCell {
    var hasComment: Bool = false
    var isSearchMatch: Bool = false
    var isHighlightedMatch: Bool = false
    var isDark: Bool = true

    private static let darkHeaderBackground = NSColor(hex: 0x27292D)
    private static let lightHeaderBackground = NSColor(hex: 0xF4F6F9)
    private static let darkHeaderText = NSColor(hex: 0xDFE1E5)
    private static let lightHeaderText = NSColor(hex: 0x1F2329)
    private static let darkGridColor = NSColor(hex: 0x35373C)
    private static let lightGridColor = NSColor(hex: 0xE6E8EE)

    private static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .left
        return style
    }()

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let canvasTheme: CanvasTheme = isDark ? .dark : .light
        let headerBackgroundColor = isDark ? Self.darkHeaderBackground : Self.lightHeaderBackground
        let headerTextColor = isDark ? Self.darkHeaderText : Self.lightHeaderText
        let gridColor = isDark ? Self.darkGridColor : Self.lightGridColor
        let matchTint = NSColor(cgColor: canvasTheme.searchMatch) ?? NSColor.systemYellow.withAlphaComponent(0.35)
        let currentMatchTint = NSColor(cgColor: canvasTheme.searchCurrent) ?? NSColor.systemOrange.withAlphaComponent(0.65)
        let accentColor = NSColor(cgColor: canvasTheme.accent) ?? .controlAccentColor

        headerBackgroundColor.setFill()
        cellFrame.fill()

        if isHighlightedMatch {
            currentMatchTint.setFill()
            cellFrame.fill()
        } else if isSearchMatch {
            matchTint.setFill()
            cellFrame.fill()
        }

        // Right + bottom hairline borders
        gridColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY, width: 1, height: cellFrame.height).fill()
        NSRect(x: cellFrame.minX, y: cellFrame.maxY - 1, width: cellFrame.width, height: 1).fill()

        if isHighlightedMatch {
            accentColor.setFill()
            NSRect(x: cellFrame.minX, y: cellFrame.maxY - 2, width: cellFrame.width, height: 2).fill()
        }

        let titleFont = self.font ?? NSFont.systemFont(ofSize: 12, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
            .foregroundColor: headerTextColor,
            .paragraphStyle: Self.paragraphStyle,
        ]
        let lineH = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
        let textY = cellFrame.minY + floor((cellFrame.height - lineH) / 2)
        let rightInset: CGFloat = hasComment ? 10 : 6
        let textRect = NSRect(
            x: cellFrame.minX + 6,
            y: textY,
            width: max(0, cellFrame.width - 6 - rightInset),
            height: lineH + 2
        )
        (stringValue as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)

        if hasComment {
            NSColor.systemRed.setFill()
            let tri = NSBezierPath()
            let s: CGFloat = 6
            tri.move(to: NSPoint(x: cellFrame.maxX - s, y: cellFrame.minY))
            tri.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.minY))
            tri.line(to: NSPoint(x: cellFrame.maxX, y: cellFrame.minY + s))
            tri.close()
            tri.fill()
        }
    }
}

private final class ExcelTableHeaderView: NSTableHeaderView {
    var commentProvider: ((Int) -> String?)?
    var onHeaderClicked: ((Int) -> Void)?
    private var toolTipTag: NSView.ToolTipTag?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tag = toolTipTag {
            removeToolTip(tag)
        }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let tag = toolTipTag {
            removeToolTip(tag)
        }
        toolTipTag = addToolTip(bounds, owner: self, userData: nil)
    }

    override func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let col = column(at: point)
        guard col >= 0 else { return "" }
        return commentProvider?(col) ?? ""
    }

    override func mouseDown(with event: NSEvent) {
        let localStart = convert(event.locationInWindow, from: nil)
        let startCol = column(at: localStart)
        let startWidths = tableView?.tableColumns.map(\.width) ?? []

        super.mouseDown(with: event)

        let endWidths = tableView?.tableColumns.map(\.width) ?? []
        let didResize = startWidths != endWidths
        let endCol: Int
        if let upEvent = NSApp.currentEvent {
            endCol = column(at: convert(upEvent.locationInWindow, from: nil))
        } else {
            endCol = startCol
        }
        if !didResize, event.clickCount == 1, startCol >= 0, endCol == startCol {
            onHeaderClicked?(startCol)
        }
    }
}

// MARK: - AppKit 2D Selectable Table View

private final class ExcelGridTableView: NSTableView {
    var isPinnedTable = false
    var cellSelection: ExcelCellSelection?
    var onSelectionChange: ((ExcelCellSelection?) -> Void)?
    var onCopySelection: (() -> Void)?
    var onSelectAllCells: (() -> Void)?
    var onBuildContextMenu: ((Int, Int) -> NSMenu?)?
    var onNavigateSearch: ((Int) -> Void)?
    var hasActiveSearchQuery: (() -> Bool)?

    private var isDraggingSelection = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        let c = column(at: point)
        guard r >= 0, c >= 0 else { return }

        if event.modifierFlags.contains(.shift), let existing = cellSelection {
            cellSelection = ExcelCellSelection(anchor: existing.anchor, extent: ExcelCellCoordinate(row: r, col: c))
        } else {
            cellSelection = .single(row: r, col: c)
        }
        isDraggingSelection = true
        onSelectionChange?(cellSelection)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingSelection, let existing = cellSelection else { return }
        autoscroll(with: event)
        let rawPoint = convert(event.locationInWindow, from: nil)
        let clampedX = min(max(bounds.minX + 1, rawPoint.x), max(bounds.minX + 1, bounds.maxX - 1))
        let clampedY = min(max(bounds.minY + 1, rawPoint.y), max(bounds.minY + 1, bounds.maxY - 1))
        let point = NSPoint(x: clampedX, y: clampedY)

        var r = row(at: point)
        var c = column(at: point)
        if r < 0 && numberOfRows > 0 {
            r = rawPoint.y < 0 ? 0 : numberOfRows - 1
        }
        if c < 0 {
            c = nearestVisibleColumn(to: clampedX)
        }
        guard r >= 0, c >= 0 else { return }

        let next = ExcelCellSelection(anchor: existing.anchor, extent: ExcelCellCoordinate(row: r, col: c))
        if next != cellSelection {
            cellSelection = next
            onSelectionChange?(next)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingSelection = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let r = row(at: point)
        let c = column(at: point)
        guard r >= 0, c >= 0 else { return nil }

        // Preserve existing multi-cell selection when right-clicking inside it; otherwise select clicked cell.
        if let current = cellSelection, current.contains(row: r, col: c) {
            // Keep existing selection.
        } else {
            cellSelection = .single(row: r, col: c)
            onSelectionChange?(cellSelection)
        }
        return onBuildContextMenu?(r, c)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let extend = mods.contains(.shift)

        switch event.keyCode {
        case 126: // Up
            moveSelection(dRow: -1, dCol: 0, extend: extend)
        case 125: // Down
            moveSelection(dRow: 1, dCol: 0, extend: extend)
        case 123: // Left
            moveSelection(dRow: 0, dCol: -1, extend: extend)
        case 124: // Right
            moveSelection(dRow: 0, dCol: 1, extend: extend)
        default:
            super.keyDown(with: event)
        }
    }

    @objc func copy(_ sender: Any?) {
        onCopySelection?()
    }

    @objc override func selectAll(_ sender: Any?) {
        onSelectAllCells?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command && chars == "c" {
            copy(nil)
            return true
        }
        if mods == .command && chars == "a" {
            selectAll(nil)
            return true
        }
        if mods == .command && chars == "g" {
            onNavigateSearch?(1)
            return true
        }
        if mods == [.command, .shift] && chars == "g" {
            onNavigateSearch?(-1)
            return true
        }
        if mods == .command && chars == "n", hasActiveSearchQuery?() == true {
            onNavigateSearch?(1)
            return true
        }
        if mods == .command && chars == "p", hasActiveSearchQuery?() == true {
            onNavigateSearch?(-1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func moveSelection(dRow: Int, dCol: Int, extend: Bool) {
        guard numberOfRows > 0 else { return }
        let visibleCols = tableColumns.enumerated().compactMap { $0.element.isHidden ? nil : $0.offset }
        guard !visibleCols.isEmpty else { return }

        let current = cellSelection ?? ExcelCellSelection.single(row: 0, col: visibleCols[0])
        let base = current.extent
        let nextRow = max(0, min(numberOfRows - 1, base.row + dRow))

        let nextCol: Int
        if dCol != 0 {
            if let pos = visibleCols.firstIndex(of: base.col) {
                let nextPos = max(0, min(visibleCols.count - 1, pos + dCol))
                nextCol = visibleCols[nextPos]
            } else {
                nextCol = visibleCols[0]
            }
        } else {
            nextCol = visibleCols.contains(base.col) ? base.col : visibleCols[0]
        }

        let targetCoord = ExcelCellCoordinate(row: nextRow, col: nextCol)
        cellSelection = extend
            ? ExcelCellSelection(anchor: current.anchor, extent: targetCoord)
            : ExcelCellSelection(anchor: targetCoord, extent: targetCoord)
        onSelectionChange?(cellSelection)
        scrollRowToVisible(nextRow)
        if !tableColumns[nextCol].isHidden {
            scrollColumnToVisible(nextCol)
        }
    }

    private func nearestVisibleColumn(to x: CGFloat) -> Int {
        var bestCol = -1
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (idx, col) in tableColumns.enumerated() where !col.isHidden {
            let r = rect(ofColumn: idx)
            let dist = abs(r.midX - x)
            if dist < bestDist {
                bestDist = dist
                bestCol = idx
            }
        }
        return bestCol
    }
}

// MARK: - Host View (Synced Header + Frozen Pinned Rows + Scrollable Body)

@MainActor
final class ExcelGridHostView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    var state: ExcelViewerState?
    var onToast: ((String) -> Void)?

    private let headerContainer = NSView()
    private let headerScrollView = NSScrollView()
    private let headerTableView = NSTableView()
    private let customHeaderView = ExcelTableHeaderView()

    private let pinnedScrollView = NSScrollView()
    private let pinnedTableView = ExcelGridTableView()
    private let pinnedDivider = NSView()

    private let mainScrollView = NSScrollView()
    private let mainTableView = ExcelGridTableView()

    private var cellFont: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    private var headerFont: NSFont = .systemFont(ofSize: 12, weight: .semibold)
    private var isDark = true
    private var rowHeight: CGFloat = 24
    private let headerHeight: CGFloat = 26

    // Cached column widths per sheetIndex so switching sheets preserves user-resized widths.
    private var cachedColumnWidths: [Int: [CGFloat]] = [:]
    private var columnIndexByID: [NSUserInterfaceItemIdentifier: Int] = [:]
    private var isSyncingHorizontalScroll = false
    private var isSyncingColumnWidths = false

    // Local keyDown monitor for ⌘N / ⌘P / ⌘G / ⇧⌘G while viewing Excel (including from the search box).
    nonisolated(unsafe) private var keyMonitor: Any?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            installKeyMonitorIfNeeded()
        } else {
            removeKeyMonitor()
        }
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyDown(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let window = self.window, window.isKeyWindow, let state else { return event }
        // Don't hijack shortcuts when a modal popup (Quick Open, Settings, etc.) or another window is active.
        if AppStore.shared.popup != nil || AppStore.shared.terminals.focusedID != nil {
            return event
        }
        // Only intercept when focus is inside the Excel viewer (search field or grid) or when an active search query exists.
        let responderView = window.firstResponder as? NSView
        let isInSearchField = responderView is SearchFieldEditor
        let isInGrid = responderView === mainTableView || responderView === pinnedTableView || (responderView?.isDescendant(of: self) ?? false)
        guard isInSearchField || isInGrid else { return event }

        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command && chars == "n", !state.searchQuery.isEmpty {
            state.navigateSearch(1)
            return nil
        }
        if mods == .command && chars == "p", !state.searchQuery.isEmpty {
            state.navigateSearch(-1)
            return nil
        }
        if mods == .command && chars == "g" {
            state.navigateSearch(1)
            return nil
        }
        if mods == [.command, .shift] && chars == "g" {
            state.navigateSearch(-1)
            return nil
        }
        return event
    }

    private func setupViews() {
        wantsLayer = true

        // 1. Header container + header-only NSTableView (drives native column resize + horizontal sync)
        headerContainer.wantsLayer = true
        headerContainer.clipsToBounds = true
        addSubview(headerContainer)

        customHeaderView.frame = NSRect(x: 0, y: 0, width: 100, height: headerHeight)
        customHeaderView.commentProvider = { [weak self] col in
            self?.state?.activeSheet?.comment(row: -1, col: col)
        }
        customHeaderView.onHeaderClicked = { [weak self] col in
            guard let self, let sheet = self.state?.activeSheet,
                  col >= 0, col < sheet.headers.count else { return }
            excelCopyToPasteboard(sheet.headers[col], toast: self.onToast)
        }

        configureBaseTable(headerTableView)
        headerTableView.headerView = customHeaderView
        headerTableView.dataSource = self
        headerTableView.delegate = self

        headerScrollView.documentView = headerTableView
        headerScrollView.hasHorizontalScroller = false
        headerScrollView.hasVerticalScroller = false
        headerScrollView.drawsBackground = false
        headerScrollView.borderType = .noBorder
        headerScrollView.contentView.postsBoundsChangedNotifications = true
        headerContainer.addSubview(headerScrollView)

        // 2. Pinned rows table (frozen directly below header)
        configureBaseTable(pinnedTableView)
        pinnedTableView.isPinnedTable = true
        pinnedTableView.headerView = nil
        pinnedTableView.dataSource = self
        pinnedTableView.delegate = self
        wireTableCallbacks(pinnedTableView)

        pinnedScrollView.documentView = pinnedTableView
        pinnedScrollView.hasHorizontalScroller = false
        pinnedScrollView.hasVerticalScroller = true
        pinnedScrollView.autohidesScrollers = true
        pinnedScrollView.drawsBackground = true
        pinnedScrollView.borderType = .noBorder
        pinnedScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(pinnedScrollView)

        pinnedDivider.wantsLayer = true
        addSubview(pinnedDivider)

        // 3. Main scrollable body table
        configureBaseTable(mainTableView)
        mainTableView.isPinnedTable = false
        mainTableView.headerView = nil
        mainTableView.dataSource = self
        mainTableView.delegate = self
        wireTableCallbacks(mainTableView)

        mainScrollView.documentView = mainTableView
        mainScrollView.hasHorizontalScroller = true
        mainScrollView.hasVerticalScroller = true
        mainScrollView.autohidesScrollers = true
        mainScrollView.drawsBackground = true
        mainScrollView.borderType = .noBorder
        mainScrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(mainScrollView)

        // Sync horizontal scrolling across header, pinned rows, and main body.
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: mainScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: pinnedScrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: headerScrollView.contentView
        )
    }

    private func configureBaseTable(_ table: NSTableView) {
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.rowHeight = rowHeight
        table.backgroundColor = .clear
    }

    private func wireTableCallbacks(_ table: ExcelGridTableView) {
        let isPinned = table.isPinnedTable
        table.onSelectionChange = { [weak self] sel in
            guard let self, let state = self.state else { return }
            if isPinned {
                state.pinnedSelection = sel
                if sel != nil {
                    state.selection = nil
                    state.highlightedHeaderColumn = nil
                    self.mainTableView.cellSelection = nil
                }
            } else {
                state.selection = sel
                state.highlightedHeaderColumn = nil
                if sel != nil {
                    state.pinnedSelection = nil
                    self.pinnedTableView.cellSelection = nil
                }
            }
            self.refreshVisibleCells()
            self.refreshHeaderAppearance()
        }

        table.onCopySelection = { [weak self] in
            guard let self, let state = self.state else { return }
            let text = state.formattedSelectionTSV(fromPinned: isPinned)
            guard !text.isEmpty else { return }
            excelCopyToPasteboard(text, toast: self.onToast)
        }

        table.onSelectAllCells = { [weak self] in
            guard let self, let state = self.state else { return }
            if isPinned {
                let pinnedCount = state.sortedPinnedRows().count
                let visCols = state.visibleColumnIndices()
                guard pinnedCount > 0, let first = visCols.first, let last = visCols.last else { return }
                let sel = ExcelCellSelection(
                    anchor: ExcelCellCoordinate(row: 0, col: first),
                    extent: ExcelCellCoordinate(row: pinnedCount - 1, col: last)
                )
                state.pinnedSelection = sel
                state.selection = nil
                self.pinnedTableView.cellSelection = sel
                self.mainTableView.cellSelection = nil
            } else {
                state.selectAllCells()
                self.mainTableView.cellSelection = state.selection
                self.pinnedTableView.cellSelection = nil
            }
            self.refreshVisibleCells()
        }

        table.onBuildContextMenu = { [weak self] row, col in
            guard let self else { return nil }
            return isPinned ? self.buildPinnedContextMenu(clickedRow: row) : self.buildMainContextMenu(clickedRow: row, clickedCol: col)
        }

        table.onNavigateSearch = { [weak self] delta in
            self?.state?.navigateSearch(delta)
        }

        table.hasActiveSearchQuery = { [weak self] in
            !(self?.state?.searchQuery.isEmpty ?? true)
        }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let pinnedCount = state?.sortedPinnedRows().count ?? 0
        let hasPinned = pinnedCount > 0
        let maxPinnedH = max(rowHeight, floor((h - headerHeight) * 0.45))
        let pinnedH: CGFloat = hasPinned ? min(CGFloat(pinnedCount) * rowHeight, maxPinnedH) : 0
        let dividerH: CGFloat = hasPinned ? 1 : 0

        headerContainer.frame = NSRect(x: 0, y: 0, width: w, height: headerHeight)
        // Extra 2pt height keeps headerScrollView's clipView non-zero so horizontal scrolling always engages.
        headerScrollView.frame = NSRect(x: 0, y: 0, width: w, height: headerHeight + 2)

        pinnedScrollView.isHidden = !hasPinned
        pinnedDivider.isHidden = !hasPinned
        if hasPinned {
            pinnedScrollView.frame = NSRect(x: 0, y: headerHeight, width: w, height: pinnedH)
            pinnedDivider.frame = NSRect(x: 0, y: headerHeight + pinnedH, width: w, height: dividerH)
        }

        let mainY = headerHeight + pinnedH + dividerH
        mainScrollView.frame = NSRect(x: 0, y: mainY, width: w, height: max(0, h - mainY))

        syncHorizontalScroll(from: mainScrollView.contentView)
    }

    // MARK: Styling & Theme

    private var theme: CanvasTheme { isDark ? .dark : .light }

    private var pinnedRowBackground: NSColor {
        isDark ? NSColor(hex: 0x2B2D30) : NSColor(hex: 0xF3F5F8)
    }

    private var cellBackground: NSColor {
        isDark ? NSColor(hex: 0x1E1F22) : NSColor(hex: 0xFFFFFF)
    }

    private var headerBackground: NSColor {
        isDark ? NSColor(hex: 0x27292D) : NSColor(hex: 0xF4F6F9)
    }

    private var cellTextColor: NSColor {
        isDark ? NSColor(hex: 0xDFE1E5) : NSColor(hex: 0x1F2329)
    }

    private var gridLineColor: NSColor {
        isDark ? NSColor(hex: 0x35373C) : NSColor(hex: 0xE6E8EE)
    }

    private var selectionTintColor: NSColor {
        isDark ? NSColor(hex: 0x548AF7, alpha: 0.28) : NSColor(hex: 0x3574F0, alpha: 0.16)
    }

    private var matchTintColor: NSColor {
        NSColor(cgColor: theme.searchMatch) ?? NSColor.systemYellow.withAlphaComponent(0.35)
    }

    private var currentMatchTintColor: NSColor {
        NSColor(cgColor: theme.searchCurrent) ?? NSColor.systemOrange.withAlphaComponent(0.65)
    }

    private var accentColor: NSColor {
        NSColor(cgColor: theme.accent) ?? .controlAccentColor
    }

    func applyStyle(cellFont: NSFont, headerFont: NSFont, isDark: Bool) {
        self.cellFont = cellFont
        self.headerFont = headerFont
        self.isDark = isDark
        self.rowHeight = max(22, ceil(cellFont.pointSize * 1.65))

        mainTableView.rowHeight = rowHeight
        pinnedTableView.rowHeight = rowHeight

        layer?.backgroundColor = cellBackground.cgColor
        headerContainer.layer?.backgroundColor = headerBackground.cgColor
        mainScrollView.backgroundColor = cellBackground
        pinnedScrollView.backgroundColor = pinnedRowBackground
        pinnedDivider.layer?.backgroundColor = (isDark ? NSColor(hex: 0x4E5157) : NSColor(hex: 0xC9CDD6)).cgColor

        refreshHeaderAppearance()
        refreshVisibleCells()
        needsLayout = true
    }

    func resetCachedColumnWidths() {
        cachedColumnWidths.removeAll()
    }

    // MARK: Sheet & Column Management

    func reloadActiveSheet() {
        guard let state, let sheet = state.activeSheet else {
            rebuildColumns(headers: [], widths: [], visible: [])
            mainTableView.reloadData()
            pinnedTableView.reloadData()
            needsLayout = true
            return
        }

        let sheetIdx = state.activeSheetIndex
        let widths: [CGFloat]
        if let cached = cachedColumnWidths[sheetIdx], cached.count == sheet.headers.count {
            widths = cached
        } else {
            widths = computeInitialColumnWidths(for: sheet)
            cachedColumnWidths[sheetIdx] = widths
        }

        let visibleSet = state.visibleColumns(for: sheetIdx)
        rebuildColumns(headers: sheet.headers, widths: widths, visible: visibleSet)

        mainTableView.cellSelection = state.selection
        pinnedTableView.cellSelection = state.pinnedSelection

        headerTableView.reloadData()
        pinnedTableView.reloadData()
        mainTableView.reloadData()

        // Reset scroll to top-left when switching sheets (scrollTo will adjust if driven by search).
        mainScrollView.contentView.setBoundsOrigin(.zero)
        mainScrollView.reflectScrolledClipView(mainScrollView.contentView)
        syncHorizontalScroll(from: mainScrollView.contentView)

        refreshHeaderAppearance()
        needsLayout = true
    }

    func applyColumnVisibility() {
        guard let state, let sheet = state.activeSheet else { return }
        let visibleSet = state.visibleColumns(for: state.activeSheetIndex)
        isSyncingColumnWidths = true
        defer { isSyncingColumnWidths = false }

        for colIdx in 0..<sheet.headers.count {
            let hidden = !visibleSet.contains(colIdx)
            if colIdx < headerTableView.tableColumns.count {
                headerTableView.tableColumns[colIdx].isHidden = hidden
            }
            if colIdx < pinnedTableView.tableColumns.count {
                pinnedTableView.tableColumns[colIdx].isHidden = hidden
            }
            if colIdx < mainTableView.tableColumns.count {
                mainTableView.tableColumns[colIdx].isHidden = hidden
            }
        }
        customHeaderView.needsDisplay = true
        pinnedTableView.tile()
        mainTableView.tile()
        syncHorizontalScroll(from: mainScrollView.contentView)
    }

    func reloadPinnedRows() {
        pinnedTableView.cellSelection = state?.pinnedSelection
        pinnedTableView.reloadData()
        needsLayout = true
        layoutSubtreeIfNeeded()
        syncHorizontalScroll(from: mainScrollView.contentView)
    }

    func refreshHighlightsAndSelection() {
        mainTableView.cellSelection = state?.selection
        pinnedTableView.cellSelection = state?.pinnedSelection
        refreshHeaderAppearance()
        refreshVisibleCells()
    }

    private func rebuildColumns(headers: [String], widths: [CGFloat], visible: Set<Int>) {
        isSyncingColumnWidths = true
        defer { isSyncingColumnWidths = false }

        columnIndexByID.removeAll(keepingCapacity: true)
        for table in [headerTableView, pinnedTableView, mainTableView] {
            while let last = table.tableColumns.last {
                table.removeTableColumn(last)
            }
        }

        for (idx, title) in headers.enumerated() {
            let width = idx < widths.count ? widths[idx] : 120
            let isHidden = !visible.contains(idx)
            let colID = NSUserInterfaceItemIdentifier("col_\(idx)")
            columnIndexByID[colID] = idx

            let hCol = NSTableColumn(identifier: colID)
            let hCell = ExcelHeaderCell(textCell: title)
            hCell.font = headerFont
            hCell.isDark = isDark
            hCol.headerCell = hCell
            hCol.title = title
            hCol.minWidth = 44
            hCol.maxWidth = 1200
            hCol.width = width
            hCol.resizingMask = .userResizingMask
            hCol.isHidden = isHidden
            headerTableView.addTableColumn(hCol)

            for bodyTable in [pinnedTableView, mainTableView] {
                let bCol = NSTableColumn(identifier: colID)
                bCol.title = title
                bCol.minWidth = 44
                bCol.maxWidth = 1200
                bCol.width = width
                bCol.resizingMask = .userResizingMask
                bCol.isHidden = isHidden
                bodyTable.addTableColumn(bCol)
            }
        }

        headerTableView.tile()
        pinnedTableView.tile()
        mainTableView.tile()
    }

    private func computeInitialColumnWidths(for sheet: XLSXSheet) -> [CGFloat] {
        let minW: CGFloat = 60
        let maxW: CGFloat = 460
        let sampleRows = min(sheet.rows.count, 100)
        let headerAttrs: [NSAttributedString.Key: Any] = [.font: headerFont]
        let cellAttrs: [NSAttributedString.Key: Any] = [.font: cellFont]

        var widths: [CGFloat] = []
        widths.reserveCapacity(sheet.headers.count)

        for col in 0..<sheet.headers.count {
            var w = max(minW, (sheet.headers[col] as NSString).size(withAttributes: headerAttrs).width + 28)
            if w < maxW {
                for row in 0..<sampleRows {
                    let val = sheet.cellValue(row: row, col: col)
                    guard !val.isEmpty else { continue }
                    if val.count > 90 {
                        w = maxW
                        break
                    }
                    let measured = (val as NSString).size(withAttributes: cellAttrs).width + 18
                    if measured > w {
                        w = measured
                        if w >= maxW {
                            w = maxW
                            break
                        }
                    }
                }
            }
            widths.append(min(maxW, max(minW, ceil(w))))
        }
        return widths
    }

    private func refreshHeaderAppearance() {
        guard let state, let sheet = state.activeSheet else { return }
        let activeMatch = state.currentMatch
        let sheetIdx = state.activeSheetIndex

        for (colIdx, col) in headerTableView.tableColumns.enumerated() {
            guard let cell = col.headerCell as? ExcelHeaderCell else { continue }
            cell.font = headerFont
            cell.isDark = isDark
            cell.hasComment = sheet.comment(row: -1, col: colIdx) != nil
            cell.isSearchMatch = state.activeSheetMatchSet.contains(XLSXCellAddress(row: -1, col: colIdx))
            cell.isHighlightedMatch = (state.highlightedHeaderColumn == colIdx)
                || (activeMatch?.sheetIndex == sheetIdx && activeMatch?.row == -1 && activeMatch?.col == colIdx)
        }
        customHeaderView.needsDisplay = true
    }

    private func refreshVisibleCells() {
        refreshVisibleCells(in: mainTableView, isPinned: false)
        if !pinnedScrollView.isHidden {
            refreshVisibleCells(in: pinnedTableView, isPinned: true)
        }
    }

    private func refreshVisibleCells(in tableView: ExcelGridTableView, isPinned: Bool) {
        let visibleRect = tableView.visibleRect
        let rowRange = tableView.rows(in: visibleRect)
        guard rowRange.length > 0 else { return }
        let colIndexes = tableView.columnIndexes(in: visibleRect)

        for row in rowRange.location..<(rowRange.location + rowRange.length) {
            colIndexes.forEach { col in
                if let cell = tableView.view(atColumn: col, row: row, makeIfNecessary: false) as? ExcelCellView {
                    configureCell(cell, row: row, col: col, isPinned: isPinned)
                    cell.needsDisplay = true
                }
            }
        }
    }

    // MARK: Scrolling to Target Cell / Header

    func scrollTo(_ target: ExcelScrollTarget) {
        guard let state, state.activeSheetIndex == target.sheetIndex else { return }
        layoutSubtreeIfNeeded()

        // Horizontal scroll to column if visible
        if target.col >= 0, target.col < mainTableView.tableColumns.count,
           !mainTableView.tableColumns[target.col].isHidden {
            let colRect = mainTableView.rect(ofColumn: target.col)
            let clipBounds = mainScrollView.contentView.bounds
            var targetX = clipBounds.origin.x
            if target.center || colRect.minX < clipBounds.minX || colRect.maxX > clipBounds.maxX {
                let docW = mainTableView.bounds.width
                let maxX = max(0, docW - clipBounds.width)
                targetX = min(maxX, max(0, colRect.midX - clipBounds.width / 2))
            }

            var targetY = clipBounds.origin.y
            if target.row >= 0, target.row < mainTableView.numberOfRows {
                let rowRect = mainTableView.rect(ofRow: target.row)
                if target.center || rowRect.minY < clipBounds.minY || rowRect.maxY > clipBounds.maxY {
                    let docH = mainTableView.bounds.height
                    let maxY = max(0, docH - clipBounds.height)
                    targetY = min(maxY, max(0, rowRect.midY - clipBounds.height / 2))
                }
            }

            mainScrollView.contentView.setBoundsOrigin(NSPoint(x: targetX, y: targetY))
            mainScrollView.reflectScrolledClipView(mainScrollView.contentView)
            syncHorizontalScroll(from: mainScrollView.contentView)
        } else if target.row >= 0, target.row < mainTableView.numberOfRows {
            mainTableView.scrollRowToVisible(target.row)
        }

        refreshHeaderAppearance()
        refreshVisibleCells()
    }

    // MARK: Horizontal Scroll & Column Width Sync

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        guard !isSyncingHorizontalScroll,
              let sourceClip = notification.object as? NSClipView else { return }
        syncHorizontalScroll(from: sourceClip)
    }

    private func syncHorizontalScroll(from sourceClip: NSClipView) {
        guard !isSyncingHorizontalScroll else { return }
        isSyncingHorizontalScroll = true
        defer { isSyncingHorizontalScroll = false }

        let targetX = max(0, sourceClip.bounds.origin.x)
        let pairs: [(NSClipView, NSScrollView)] = [
            (headerScrollView.contentView, headerScrollView),
            (pinnedScrollView.contentView, pinnedScrollView),
            (mainScrollView.contentView, mainScrollView),
        ]
        for (clip, scroll) in pairs where clip !== sourceClip {
            let desiredX: CGFloat
            if scroll === mainScrollView {
                let docWidth = scroll.documentView?.bounds.width ?? 0
                let maxX = max(0, docWidth - clip.bounds.width)
                desiredX = min(maxX, targetX)
            } else {
                desiredX = targetX
            }
            if abs(clip.bounds.origin.x - desiredX) > 0.25 {
                clip.setBoundsOrigin(NSPoint(x: desiredX, y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
            }
        }
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard !isSyncingColumnWidths,
              let sourceTable = notification.object as? NSTableView,
              let resizedCol = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              let colIdx = sourceTable.tableColumns.firstIndex(where: { $0 === resizedCol }) else { return }

        let newWidth = resizedCol.width
        isSyncingColumnWidths = true
        defer { isSyncingColumnWidths = false }

        for other in [headerTableView, pinnedTableView, mainTableView] where other !== sourceTable {
            if colIdx < other.tableColumns.count {
                other.tableColumns[colIdx].width = newWidth
            }
        }
        if let sheetIdx = state?.activeSheetIndex {
            var widths = cachedColumnWidths[sheetIdx] ?? headerTableView.tableColumns.map(\.width)
            if colIdx < widths.count {
                widths[colIdx] = newWidth
                cachedColumnWidths[sheetIdx] = widths
            }
        }
        syncHorizontalScroll(from: mainScrollView.contentView)
    }

    // MARK: NSTableViewDataSource & Delegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        guard let state, let sheet = state.activeSheet else { return 0 }
        if tableView === headerTableView { return 0 }
        if tableView === pinnedTableView { return state.sortedPinnedRows().count }
        return sheet.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard tableView !== headerTableView, let tableColumn,
              let colIdx = columnIndexByID[tableColumn.identifier] else { return nil }
        let isPinned = (tableView === pinnedTableView)

        let cell: ExcelCellView
        if let recycled = tableView.makeView(withIdentifier: ExcelCellView.identifier, owner: self) as? ExcelCellView {
            cell = recycled
        } else {
            cell = ExcelCellView(frame: .zero)
            cell.identifier = ExcelCellView.identifier
        }
        configureCell(cell, row: row, col: colIdx, isPinned: isPinned)
        return cell
    }

    private func configureCell(_ cell: ExcelCellView, row: Int, col: Int, isPinned: Bool) {
        guard let state, let sheet = state.activeSheet else { return }
        let originalRow: Int
        if isPinned {
            let sorted = state.sortedPinnedRows()
            guard sorted.indices.contains(row) else { return }
            originalRow = sorted[row]
        } else {
            originalRow = row
        }

        let value = sheet.cellValue(row: originalRow, col: col)
        let comment = sheet.comment(row: originalRow, col: col)
        let addr = XLSXCellAddress(row: originalRow, col: col)
        let isMatch = state.activeSheetMatchSet.contains(addr)
        let isCurrent: Bool
        if let current = state.currentMatch,
           current.sheetIndex == state.activeSheetIndex,
           current.row == originalRow,
           current.col == col {
            isCurrent = true
        } else {
            isCurrent = false
        }

        let sel = isPinned ? state.pinnedSelection : state.selection
        let isSelected = sel?.contains(row: row, col: col) ?? false

        cell.text = value
        cell.font = cellFont
        cell.textColor = cellTextColor
        cell.backgroundColor = isPinned ? pinnedRowBackground : cellBackground
        cell.selectionTint = selectionTintColor
        cell.matchTint = matchTintColor
        cell.currentMatchTint = currentMatchTintColor
        cell.accentBorderColor = accentColor
        cell.gridColor = gridLineColor
        cell.isSelected = isSelected
        cell.isSearchMatch = isMatch
        cell.isCurrentSearchMatch = isCurrent
        cell.hasComment = comment != nil
        cell.toolTip = comment
    }

    // MARK: Context Menus

    private func buildMainContextMenu(clickedRow: Int, clickedCol: Int) -> NSMenu? {
        guard let state else { return nil }
        let sel = state.selection ?? .single(row: clickedRow, col: clickedCol)
        let isMulti = sel.rowCount > 1 || sel.colCount > 1
        let selectedRows = sel.selectedRows

        let menu = NSMenu()
        let copyTitle = isMulti ? L("Copy Selection", "复制选中内容") : L("Copy Cell", "复制单元格")
        menu.addItem(ClosureMenuItem(copyTitle) { [weak self] in
            guard let self, let state = self.state else { return }
            let text = state.formattedSelectionTSV(fromPinned: false)
            if !text.isEmpty {
                excelCopyToPasteboard(text, toast: self.onToast)
            }
        })

        menu.addItem(.separator())

        if state.areAllRowsPinned(selectedRows) {
            let title = selectedRows.count > 1 ? L("Unpin Selected Rows", "取消固定选中行") : L("Unpin Row", "取消固定行")
            menu.addItem(ClosureMenuItem(title) { [weak self] in
                self?.state?.unpinRows(selectedRows)
            })
        } else {
            let title = selectedRows.count > 1 ? L("Pin Selected Rows", "固定选中行") : L("Pin Row", "固定行")
            menu.addItem(ClosureMenuItem(title) { [weak self] in
                self?.state?.pinRows(selectedRows)
            })
        }

        if state.hasPinnedRows() {
            menu.addItem(ClosureMenuItem(L("Unpin All Rows", "取消全部固定行")) { [weak self] in
                self?.state?.unpinAllRows()
            })
        }

        return menu
    }

    private func buildPinnedContextMenu(clickedRow: Int) -> NSMenu? {
        guard let state else { return nil }
        let sel = state.pinnedSelection ?? .single(row: clickedRow, col: 0)
        let isMulti = sel.rowCount > 1 || sel.colCount > 1
        let selectedPinnedIndices = sel.selectedRows

        let menu = NSMenu()
        let copyTitle = isMulti ? L("Copy Selection", "复制选中内容") : L("Copy Cell", "复制单元格")
        menu.addItem(ClosureMenuItem(copyTitle) { [weak self] in
            guard let self, let state = self.state else { return }
            let text = state.formattedSelectionTSV(fromPinned: true)
            if !text.isEmpty {
                excelCopyToPasteboard(text, toast: self.onToast)
            }
        })

        menu.addItem(.separator())

        let unpinTitle = selectedPinnedIndices.count > 1 ? L("Unpin Selected Rows", "取消固定选中行") : L("Unpin Row", "取消固定行")
        menu.addItem(ClosureMenuItem(unpinTitle) { [weak self] in
            self?.state?.unpinPinnedTableRows(selectedPinnedIndices)
        })

        if state.hasPinnedRows() {
            menu.addItem(ClosureMenuItem(L("Unpin All Rows", "取消全部固定行")) { [weak self] in
                self?.state?.unpinAllRows()
            })
        }

        return menu
    }
}
