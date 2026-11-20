import XCTest
@testable import DifKit

@MainActor
final class ExcelViewerTests: XCTestCase {

    // MARK: - Fixtures

    private func makeSampleWorkbook() -> XLSXWorkbook {
        let sheet1 = XLSXSheet(
            name: "Items",
            headers: ["ID", "Name", "Price", "Note"],
            rows: [
                ["1001", "Apple", "3.5", "Fresh"],
                ["1002", "Banana", "2.0", "Has\ttab"],
                ["1003", "Apricot", "5.0", "Line1\nLine2"],
                ["1004", "Cherry", "8.0", "Quoted \"ok\""],
            ],
            comments: [
                XLSXCellAddress(row: -1, col: 1): "Item display name",
                XLSXCellAddress(row: 0, col: 2): "USD price",
            ]
        )
        let sheet2 = XLSXSheet(
            name: "IAPMonthlyCard",
            headers: ["CardID", "Title", "Bonus"],
            rows: [
                ["M1", "Gold Apple Pass", "300"],
                ["M2", "Silver Pass", "100"],
            ],
            comments: [:]
        )
        let sheet3 = XLSXSheet(
            name: "EmptyRowsHeaderOnly",
            headers: ["AppleHeader", "Other"],
            rows: [],
            comments: [:]
        )
        return XLSXWorkbook(sheets: [sheet1, sheet2, sheet3])
    }

    private func makeMinimalXLSXFile(at url: URL, sheets: [(name: String, headers: [String], rows: [[String]])]) throws {
        var entries: [(name: String, data: Data)] = []
        var sheetElements = ""
        var relElements = ""

        for (idx, sheet) in sheets.enumerated() {
            let n = idx + 1
            let rId = "rId\(n)"
            sheetElements += "<sheet name=\"\(sheet.name)\" sheetId=\"\(n)\" r:id=\"\(rId)\"/>"
            relElements += "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"

            var rowsXML = ""
            let allRows = [sheet.headers] + sheet.rows
            for (rIdx, cells) in allRows.enumerated() {
                let rowNum = rIdx + 1
                var cellsXML = ""
                for (cIdx, value) in cells.enumerated() {
                    let colLetter = String(UnicodeScalar(65 + cIdx)!)
                    cellsXML += "<c r=\"\(colLetter)\(rowNum)\" t=\"inlineStr\"><is><t>\(value)</t></is></c>"
                }
                rowsXML += "<row r=\"\(rowNum)\">\(cellsXML)</row>"
            }
            let sheetXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>\(rowsXML)</sheetData>
            </worksheet>
            """
            entries.append(("xl/worksheets/sheet\(n).xml", Data(sheetXML.utf8)))
        }

        let wbXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(sheetElements)</sheets>
        </workbook>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(relElements)
        </Relationships>
        """
        entries.append(("xl/workbook.xml", Data(wbXML.utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(relsXML.utf8)))

        let zipData = XLSXZipArchive.create(entries: entries, compress: true)
        try zipData.write(to: url)
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "com.dif.tests.excel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - 1. Sheet Switching & Pending Sheet Consumption

    func testSheetSwitchingAndFiltering() {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())
        XCTAssertEqual(state.activeSheetIndex, 0)
        XCTAssertEqual(state.activeSheetName, "Items")

        state.selectCell(row: 1, col: 1)
        XCTAssertNotNil(state.selection)

        // Switching sheets clears selection and updates active sheet.
        state.selectSheet(at: 1)
        XCTAssertEqual(state.activeSheetIndex, 1)
        XCTAssertEqual(state.activeSheetName, "IAPMonthlyCard")
        XCTAssertNil(state.selection)

        // Out-of-bounds index is safely ignored.
        state.selectSheet(at: 99)
        XCTAssertEqual(state.activeSheetIndex, 1)

        // Exact name switch
        XCTAssertTrue(state.selectSheet(named: "EmptyRowsHeaderOnly"))
        XCTAssertEqual(state.activeSheetIndex, 2)
        XCTAssertFalse(state.selectSheet(named: "DoesNotExist"))
        XCTAssertEqual(state.activeSheetIndex, 2)

        // Fuzzy & substring sheet switcher filtering
        let all = state.filterSheets(query: "")
        XCTAssertEqual(all.map(\.name), ["Items", "IAPMonthlyCard", "EmptyRowsHeaderOnly"])

        let fuzzy = state.filterSheets(query: "imc")
        XCTAssertEqual(fuzzy.first?.name, "IAPMonthlyCard")

        let sub = state.filterSheets(query: "monthly")
        XCTAssertEqual(sub.map(\.name), ["IAPMonthlyCard"])
    }

    func testViewerModelPendingExcelSheetSelection() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-excel-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("Config.xlsx")
        try makeMinimalXLSXFile(at: fileURL, sheets: [
            (name: "Alpha", headers: ["K", "V"], rows: [["a", "1"]]),
            (name: "Beta", headers: ["K", "V"], rows: [["b", "2"]]),
        ])

        let viewer = ViewerModel()
        viewer.settings = Settings.shared

        // Request a sheet BEFORE the workbook finishes loading (Quick Open flow).
        viewer.selectExcelSheet("Beta")
        XCTAssertEqual(viewer.pendingExcelSheet, "Beta")
        let token1 = viewer.excelSheetSelectToken

        let req = DiffRequest(root: dir, path: "Config.xlsx", source: .file)
        viewer.open(req)
        await viewer.loadTask?.value

        XCTAssertTrue(viewer.isSpreadsheet)
        XCTAssertNil(viewer.pendingExcelSheet, "Pending sheet should be consumed once workbook loads")
        XCTAssertEqual(viewer.activeExcelSession?.activeSheetName, "Beta")

        // Request another sheet AFTER load -> switches immediately.
        viewer.selectExcelSheet("Alpha")
        XCTAssertEqual(viewer.excelSheetSelectToken, token1 + 1)
        XCTAssertNil(viewer.pendingExcelSheet)
        XCTAssertEqual(viewer.activeExcelSession?.activeSheetName, "Alpha")
    }

    // MARK: - 2. Cross-Sheet Search Navigation (Header vs Cell + Wraparound)

    func testCrossSheetSearchNavigationAndWraparound() {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())

        // "apple" appears in:
        // 0: sheet 0, row 0, col 1 ("Apple")
        // 1: sheet 1, row 0, col 1 ("Gold Apple Pass")
        // 2: sheet 2, row -1, col 0 ("AppleHeader") — header match on 0-row sheet!
        state.updateSearch(query: "apple", mode: .caseInsensitive)

        XCTAssertEqual(state.searchMatches.count, 3)
        XCTAssertEqual(state.currentMatchIndex, 0)
        XCTAssertEqual(state.resultsLabelText, "1/3")
        XCTAssertEqual(state.activeSheetIndex, 0)
        XCTAssertEqual(state.selection, .single(row: 0, col: 1))
        XCTAssertNil(state.highlightedHeaderColumn)
        XCTAssertEqual(state.scrollTarget, ExcelScrollTarget(sheetIndex: 0, row: 0, col: 1, center: true))

        // Next -> switches automatically to sheet 1
        state.navigateSearch(1)
        XCTAssertEqual(state.currentMatchIndex, 1)
        XCTAssertEqual(state.resultsLabelText, "2/3")
        XCTAssertEqual(state.activeSheetIndex, 1)
        XCTAssertEqual(state.selection, .single(row: 0, col: 1))
        XCTAssertNil(state.highlightedHeaderColumn)

        // Next -> switches to sheet 2 header match (row == -1, 0 data rows)
        state.navigateSearch(1)
        XCTAssertEqual(state.currentMatchIndex, 2)
        XCTAssertEqual(state.resultsLabelText, "3/3")
        XCTAssertEqual(state.activeSheetIndex, 2)
        XCTAssertEqual(state.highlightedHeaderColumn, 0)
        XCTAssertNil(state.selection)
        XCTAssertEqual(state.scrollTarget, ExcelScrollTarget(sheetIndex: 2, row: -1, col: 0, center: true))

        // Next -> wraps around to index 0 (sheet 0)
        state.navigateSearch(1)
        XCTAssertEqual(state.currentMatchIndex, 0)
        XCTAssertEqual(state.activeSheetIndex, 0)

        // Previous -> wraps around backwards to index 2 (sheet 2)
        state.navigateSearch(-1)
        XCTAssertEqual(state.currentMatchIndex, 2)
        XCTAssertEqual(state.activeSheetIndex, 2)

        // Header match on a sheet WITH rows selects the entire column (0..<rowCount)
        state.updateSearch(query: "Price", mode: .caseSensitive)
        XCTAssertEqual(state.searchMatches, [XLSXSearchMatch(sheetIndex: 0, row: -1, col: 2)])
        XCTAssertEqual(state.activeSheetIndex, 0)
        XCTAssertEqual(state.highlightedHeaderColumn, 2)
        XCTAssertEqual(state.selection, ExcelCellSelection(
            anchor: ExcelCellCoordinate(row: 0, col: 2),
            extent: ExcelCellCoordinate(row: 3, col: 2)
        ))

        // Regex search mode
        state.updateSearch(query: "^100[24]$", mode: .regex)
        XCTAssertEqual(state.searchMatches.count, 2)
        XCTAssertEqual(state.searchMatches[0], XLSXSearchMatch(sheetIndex: 0, row: 1, col: 0))
        XCTAssertEqual(state.searchMatches[1], XLSXSearchMatch(sheetIndex: 0, row: 3, col: 0))

        // Clear search
        state.clearSearch()
        XCTAssertTrue(state.searchMatches.isEmpty)
        XCTAssertEqual(state.currentMatchIndex, -1)
        XCTAssertNil(state.highlightedHeaderColumn)
    }

    // MARK: - 3. Column Visibility Toggle

    func testColumnVisibilityToggleAndPerSheetIsolation() {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())

        XCTAssertEqual(state.visibleColumns(for: 0), Set([0, 1, 2, 3]))
        XCTAssertEqual(state.hiddenColumnCount(sheetIndex: 0), 0)

        state.toggleColumn(1)
        XCTAssertFalse(state.isColumnVisible(1))
        XCTAssertEqual(state.visibleColumnIndices(), [0, 2, 3])
        XCTAssertEqual(state.hiddenColumnCount(), 1)

        // Sheet 1 remains unaffected
        XCTAssertEqual(state.visibleColumns(for: 1), Set([0, 1, 2]))

        state.clearAllColumns()
        XCTAssertTrue(state.visibleColumns(for: 0).isEmpty)
        XCTAssertEqual(state.hiddenColumnCount(sheetIndex: 0), 4)

        state.selectAllColumns()
        XCTAssertEqual(state.visibleColumns(for: 0), Set([0, 1, 2, 3]))
        XCTAssertEqual(state.hiddenColumnCount(sheetIndex: 0), 0)
    }

    // MARK: - 4. Pin / Unpin / Unpin All Rows

    func testPinUnpinAndSortedOrder() {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())

        XCTAssertFalse(state.hasPinnedRows())
        XCTAssertFalse(state.areAllRowsPinned([1, 2]))

        // Pin out of order -> sortedPinnedRows must always be ascending.
        state.pinRows([3, 0, 2])
        XCTAssertEqual(state.sortedPinnedRows(), [0, 2, 3])
        XCTAssertTrue(state.hasPinnedRows())

        // areAllRowsPinned toggle logic
        XCTAssertTrue(state.areAllRowsPinned([0, 2]))
        XCTAssertFalse(state.areAllRowsPinned([0, 1]))

        // Unpin via pinned-table visual index (pinned index 1 corresponds to original row 2)
        state.unpinPinnedTableRows([1])
        XCTAssertEqual(state.sortedPinnedRows(), [0, 3])

        // Unpin specific original row
        state.unpinRows([0])
        XCTAssertEqual(state.sortedPinnedRows(), [3])

        // Unpin all
        state.unpinAllRows()
        XCTAssertTrue(state.sortedPinnedRows().isEmpty)
        XCTAssertFalse(state.hasPinnedRows())
    }

    // MARK: - 5. Selection TSV Copy Respecting Hidden Columns

    func testSelectionTSVCopyRespectsHiddenColumnsAndPinnedRows() {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())

        // Single cell returns raw value without TSV quoting.
        state.selectCell(row: 3, col: 3)
        XCTAssertEqual(state.formattedSelectionTSV(fromPinned: false), "Quoted \"ok\"")

        // Multi-cell rectangular selection skipping hidden column 1 ("Name")
        state.toggleColumn(1) // hide Name; visible columns = [0, 2, 3]
        state.selection = ExcelCellSelection(
            anchor: ExcelCellCoordinate(row: 0, col: 0),
            extent: ExcelCellCoordinate(row: 2, col: 3)
        )
        let tsv = state.formattedSelectionTSV(fromPinned: false)
        XCTAssertEqual(
            tsv,
            "1001\t3.5\tFresh\n1002\t2.0\t\"Has\ttab\"\n1003\t5.0\t\"Line1\nLine2\""
        )

        // Pinned table selection maps pinned visual rows to original rows and still skips hidden col 1.
        state.pinRows([3, 0]) // sortedPinnedRows = [0, 3]
        state.pinnedSelection = ExcelCellSelection(
            anchor: ExcelCellCoordinate(row: 0, col: 0),
            extent: ExcelCellCoordinate(row: 1, col: 3)
        )
        let pinnedTSV = state.formattedSelectionTSV(fromPinned: true)
        XCTAssertEqual(
            pinnedTSV,
            "1001\t3.5\tFresh\n1004\t8.0\t\"Quoted \"\"ok\"\"\""
        )
    }

    // MARK: - 6. Reload State Preservation & Toast

    func testReloadStatePreservationInStateAndViewerModel() async throws {
        let state = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: makeIsolatedDefaults())
        state.selectSheet(named: "Items")
        state.updateSearch(query: "Apple", mode: .caseSensitive)
        state.pinRows([0, 2, 3])
        state.toggleColumn(2) // hide Price

        // Simulate reload where:
        // - "Items" moved to sheet index 1
        // - "Items" now has only 2 rows (row 2 and row 3 are out of bounds and must be pruned!)
        // - "Items" gained a 5th column (col 4 should default to visible while col 2 stays hidden)
        let reloadedWorkbook = XLSXWorkbook(sheets: [
            XLSXSheet(name: "PrependedSheet", headers: ["X"], rows: [["1"]], comments: [:]),
            XLSXSheet(
                name: "Items",
                headers: ["ID", "Name", "Price", "Note", "Extra"],
                rows: [
                    ["1001", "Apple", "4.0", "Updated", "E1"],
                    ["1002", "Banana", "2.5", "Updated2", "E2"],
                ],
                comments: [:]
            ),
        ])

        state.applyWorkbook(reloadedWorkbook, isReload: true)

        // Active sheet preserved by name even though its index shifted from 0 -> 1.
        XCTAssertEqual(state.activeSheetIndex, 1)
        XCTAssertEqual(state.activeSheetName, "Items")
        // Search query & mode preserved, matches re-evaluated.
        XCTAssertEqual(state.searchQuery, "Apple")
        XCTAssertEqual(state.searchMode, .caseSensitive)
        XCTAssertEqual(state.searchMatches, [XLSXSearchMatch(sheetIndex: 1, row: 0, col: 1)])
        // Pinned rows clamped to new row count (0 kept; 2 & 3 dropped).
        XCTAssertEqual(state.sortedPinnedRows(), [0])
        // Hidden column 2 stays hidden, new column 4 is visible.
        XCTAssertFalse(state.isColumnVisible(2))
        XCTAssertTrue(state.isColumnVisible(4))

        // End-to-end ViewerModel reload test verifying reload toast & session preservation.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-excel-reload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileURL = dir.appendingPathComponent("Prices.xlsx")
        try makeMinimalXLSXFile(at: fileURL, sheets: [
            (name: "SheetA", headers: ["Col1", "Col2"], rows: [["r0", "v0"], ["r1", "v1"], ["r2", "v2"]]),
            (name: "SheetB", headers: ["Key", "Val"], rows: [["k0", "foo"], ["k1", "bar"], ["k2", "baz"]]),
        ])

        let viewer = ViewerModel()
        viewer.settings = Settings.shared
        var toasts: [String] = []
        viewer.onToast = { toasts.append($0) }

        let req = DiffRequest(root: dir, path: "Prices.xlsx", source: .file)
        viewer.open(req)
        await viewer.loadTask?.value

        guard let session = viewer.activeExcelSession else {
            return XCTFail("Expected activeExcelSession after opening xlsx")
        }
        session.selectSheet(named: "SheetB")
        session.updateSearch(query: "bar", mode: .caseInsensitive)
        session.pinRows([0, 2])
        XCTAssertTrue(toasts.isEmpty)

        // Rewrite file on disk with only 2 rows in SheetB and reload.
        try makeMinimalXLSXFile(at: fileURL, sheets: [
            (name: "SheetA", headers: ["Col1", "Col2"], rows: [["r0", "v0"]]),
            (name: "SheetB", headers: ["Key", "Val"], rows: [["k0", "foo"], ["k1", "bar-new"]]),
        ])
        viewer.reload()
        await viewer.loadTask?.value

        XCTAssertEqual(viewer.activeExcelSession?.activeSheetName, "SheetB")
        XCTAssertEqual(viewer.activeExcelSession?.searchQuery, "bar")
        XCTAssertEqual(viewer.activeExcelSession?.sortedPinnedRows(), [0])
        XCTAssertEqual(toasts.count, 1)
        XCTAssertTrue(toasts[0].contains("Prices.xlsx"))
    }

    // MARK: - 7. Hide Bottom Tabs Persistence

    func testHideBottomTabsPersistsInUserDefaults() {
        let defaults = makeIsolatedDefaults()
        let state1 = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: defaults)
        XCTAssertFalse(state1.hideBottomTabs)

        state1.hideBottomTabs = true
        XCTAssertTrue(defaults.bool(forKey: ExcelViewerState.hideBottomTabsKey))

        let state2 = ExcelViewerState(workbook: makeSampleWorkbook(), defaults: defaults)
        XCTAssertTrue(state2.hideBottomTabs)
    }
}
