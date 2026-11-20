import Foundation
import XCTest
@testable import DifKit

final class ExcelSheetIndexTests: XCTestCase {
    private func makeWorkbookData(sheets: [String]) -> Data {
        let sheetTags = sheets.enumerated().map { idx, name in
            let escaped = name
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            return #"<sheet name="\#(escaped)" sheetId="\#(idx + 1)" r:id="rId\#(idx + 1)"/>"#
        }.joined(separator: "\n    ")

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            \(sheetTags)
          </sheets>
        </workbook>
        """
        return XLSXZipArchive.create(entries: [
            ("xl/workbook.xml", Data(xml.utf8)),
        ])
    }

    private func makeLoadableWorkbookData(sheets: [String]) -> Data {
        var entries: [(String, Data)] = []
        var sheetTags = ""
        var relTags = ""
        for (idx, name) in sheets.enumerated() {
            let n = idx + 1
            let escaped = name
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            sheetTags += #"<sheet name="\#(escaped)" sheetId="\#(n)" r:id="rId\#(n)"/>"#
            relTags += #"<Relationship Id="rId\#(n)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(n).xml"/>"#
            let sheetXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
              <sheetData>
                <row r="1"><c r="A1" t="inlineStr"><is><t>Header</t></is></c></row>
                <row r="2"><c r="A2" t="inlineStr"><is><t>\(escaped)</t></is></c></row>
              </sheetData>
            </worksheet>
            """
            entries.append(("xl/worksheets/sheet\(n).xml", Data(sheetXML.utf8)))
        }
        let wbXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>\(sheetTags)</sheets>
        </workbook>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(relTags)
        </Relationships>
        """
        entries.append(("xl/workbook.xml", Data(wbXML.utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(relsXML.utf8)))
        return XLSXZipArchive.create(entries: entries)
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExcelSheetIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testExtractsSheetsSkipsTempLockFilesCachesAndRefreshesOnMtimeChange() async throws {
        try await withTempDir { dir in
            let dataDir = dir.appendingPathComponent("data")
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

            let shopURL = dataDir.appendingPathComponent("Shop.xlsx")
            let lockURL = dataDir.appendingPathComponent("~$Shop.xlsx")
            let itemsURL = dataDir.appendingPathComponent("Items.xlsx")

            try makeWorkbookData(sheets: ["IAPMonthlyCard", "DailyDeals"]).write(to: shopURL)
            try makeWorkbookData(sheets: ["ShouldBeIgnored"]).write(to: lockURL)
            try makeWorkbookData(sheets: ["Weapons", "技能表 & Buff"]).write(to: itemsURL)

            let files = [
                "README.md",
                "data/Shop.xlsx",
                "data/~$Shop.xlsx",
                "data/Items.xlsx",
                "~$RootLock.xlsx",
            ]

            let index = ExcelSheetIndex()
            let first = await index.entries(in: dir, files: files)
            XCTAssertEqual(first, [
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "IAPMonthlyCard"),
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "DailyDeals"),
                ExcelSheetEntry(path: "data/Items.xlsx", sheetName: "Weapons"),
                ExcelSheetEntry(path: "data/Items.xlsx", sheetName: "技能表 & Buff"),
            ])
            let initialParses = await index.parseCountForTesting
            XCTAssertEqual(initialParses, 2)

            // Repeated lookup with unchanged files must reuse the cache without re-parsing ZIPs.
            let second = await index.entries(in: dir, files: files)
            XCTAssertEqual(second, first)
            let afterCacheHitParses = await index.parseCountForTesting
            XCTAssertEqual(afterCacheHitParses, 2)

            // Update file contents + mtime on Shop.xlsx and verify index refreshes only that file.
            try makeWorkbookData(sheets: ["IAPMonthlyCard", "VIPPass"]).write(to: shopURL)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(5)],
                ofItemAtPath: shopURL.path
            )

            let third = await index.entries(in: dir, files: files)
            XCTAssertEqual(third, [
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "IAPMonthlyCard"),
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "VIPPass"),
                ExcelSheetEntry(path: "data/Items.xlsx", sheetName: "Weapons"),
                ExcelSheetEntry(path: "data/Items.xlsx", sheetName: "技能表 & Buff"),
            ])
            let afterMtimeParses = await index.parseCountForTesting
            XCTAssertEqual(afterMtimeParses, 3)

            // Removing Items.xlsx from the project file list removes its sheets without re-parsing Shop.xlsx.
            let fourth = await index.entries(in: dir, files: ["data/Shop.xlsx"])
            XCTAssertEqual(fourth, [
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "IAPMonthlyCard"),
                ExcelSheetEntry(path: "data/Shop.xlsx", sheetName: "VIPPass"),
            ])
            let afterPruneParses = await index.parseCountForTesting
            XCTAssertEqual(afterPruneParses, 3)
        }
    }

    @MainActor
    func testQuickOpenMatchesExcelSheetsAndInvokesCallbackOnActivate() async throws {
        try await withTempDir { dir in
            let configDir = dir.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            let workbookPath = "config/Billing.xlsx"
            try makeWorkbookData(sheets: ["IAPMonthlyCard", "StarterPack"]).write(
                to: dir.appendingPathComponent(workbookPath)
            )
            try makeWorkbookData(sheets: ["IgnoredLockSheet"]).write(
                to: configDir.appendingPathComponent("~$Billing.xlsx")
            )

            let store = AppStore.shared
            let prevProjects = store.projects
            let prevSelectedProjectID = store.selectedProjectID
            defer {
                store.projects = prevProjects
                store.selectedProjectID = prevSelectedProjectID
            }

            let project = Project(url: dir)
            store.projects = [project]
            store.selectedProjectID = project.id

            let sampleFiles = [
                "Sources/App.swift",
                workbookPath,
                "config/~$Billing.xlsx",
            ]

            var openedSheet: (UUID, String, String)?
            let model = QuickOpenModel()
            model.store = store
            model.filesProviderForTesting = { _ in sampleFiles }
            model.onOpenExcelSheet = { proj, path, sheet in
                openedSheet = (proj.id, path, sheet)
            }

            // Empty query in .files must not emit Excel sheet items.
            model.prepare(scope: .files)
            XCTAssertFalse(model.items.contains {
                if case .excelSheet = $0 { return true }
                return false
            })

            // Query "mo" matches "IAPMonthlyCard" in .files scope.
            model.query = "mo"
            let foundInFiles = await waitUntil {
                model.items.contains {
                    if case .excelSheet(let pid, let path, let sheet, _) = $0 {
                        return pid == project.id && path == workbookPath && sheet == "IAPMonthlyCard"
                    }
                    return false
                }
            }
            XCTAssertTrue(foundInFiles, "Expected IAPMonthlyCard in .files scope")

            // Verify Item.id format and non-contiguous fuzzy positions ("mo" -> M, o in IAPMonthlyCard).
            guard let sheetIndex = model.items.firstIndex(where: {
                if case .excelSheet(_, _, let sheet, _) = $0 { return sheet == "IAPMonthlyCard" }
                return false
            }) else {
                XCTFail("Expected IAPMonthlyCard item")
                return
            }
            let matchedItem = model.items[sheetIndex]
            XCTAssertEqual(matchedItem.id, "x:\(project.id.uuidString):\(workbookPath):IAPMonthlyCard")
            if case .excelSheet(_, _, _, let positions) = matchedItem {
                XCTAssertEqual(positions, [3, 4])
            }

            // Activate must invoke onOpenExcelSheet with (project, path, sheetName).
            model.activate(sheetIndex)
            XCTAssertEqual(openedSheet?.0, project.id)
            XCTAssertEqual(openedSheet?.1, workbookPath)
            XCTAssertEqual(openedSheet?.2, "IAPMonthlyCard")

            // Query non-contiguous "mc" in .all scope also matches "IAPMonthlyCard".
            model.prepare(scope: .all)
            model.query = "mc"
            let foundInAll = await waitUntil {
                model.items.contains {
                    if case .excelSheet(_, let path, let sheet, let positions) = $0 {
                        return path == workbookPath && sheet == "IAPMonthlyCard" && positions == [3, 10]
                    }
                    return false
                }
            }
            XCTAssertTrue(foundInAll, "Expected IAPMonthlyCard in .all scope for non-contiguous query 'mc'")

            // .actions scope must not include Excel sheets.
            model.setScope(.actions)
            XCTAssertFalse(model.items.contains {
                if case .excelSheet = $0 { return true }
                return false
            })
        }
    }

    @MainActor
    func testAppStoreQuickOpenExcelSheetSetsPendingSheetAndOpensWorkbook() async throws {
        try await withTempDir { dir in
            let configDir = dir.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

            let billingPath = "config/Billing.xlsx"
            let otherPath = "config/Other.xlsx"
            let billingURL = dir.appendingPathComponent(billingPath)
            let otherURL = dir.appendingPathComponent(otherPath)
            try makeLoadableWorkbookData(sheets: ["IAPMonthlyCard", "StarterPack"]).write(to: billingURL)
            try makeLoadableWorkbookData(sheets: ["StarterPack", "ExtraSheet"]).write(to: otherURL)

            let store = AppStore.shared
            let prevProjects = store.projects
            let prevSelectedProjectID = store.selectedProjectID
            let prevPopup = store.popup
            let prevRecent = store.recent
            let billingKey = store.viewer.excelSessionKey(for: billingURL)
            let otherKey = store.viewer.excelSessionKey(for: otherURL)
            defer {
                store.viewer.clear()
                store.viewer.excelSessions.removeValue(forKey: billingKey)
                store.viewer.excelSessions.removeValue(forKey: otherKey)
                store.quickOpen.filesProviderForTesting = nil
                store.quickOpen.query = ""
                store.quickOpen.items = []
                store.projects = prevProjects
                store.selectedProjectID = prevSelectedProjectID
                store.popup = prevPopup
                store.recent = prevRecent
            }

            store.viewer.clear()
            let project = Project(url: dir)
            store.projects = [project]
            store.selectedProjectID = project.id

            let sampleFiles = [otherPath, billingPath]
            store.quickOpen.filesProviderForTesting = { _ in sampleFiles }

            // First open Other.xlsx (which also has a sheet named "StarterPack") so switching to Billing.xlsx
            // proves an already-loaded workbook with a matching sheet name does not drop pendingExcelSheet.
            store.openFile(in: project, path: otherPath, line: nil)
            await store.viewer.loadTask?.value
            XCTAssertTrue(store.viewer.isSpreadsheet)

            store.popup = .quickOpen
            store.quickOpen.prepare(scope: .files)
            store.quickOpen.query = "starter"
            let foundBillingStarter = await waitUntil {
                store.quickOpen.items.contains {
                    if case .excelSheet(let pid, let path, let sheet, _) = $0 {
                        return pid == project.id && path == billingPath && sheet == "StarterPack"
                    }
                    return false
                }
            }
            XCTAssertTrue(foundBillingStarter, "Expected Billing.xlsx StarterPack in QuickOpen")

            guard let targetIndex = store.quickOpen.items.firstIndex(where: {
                if case .excelSheet(_, let path, let sheet, _) = $0 {
                    return path == billingPath && sheet == "StarterPack"
                }
                return false
            }) else {
                XCTFail("Expected StarterPack sheet item for Billing.xlsx")
                return
            }

            store.quickOpen.activate(targetIndex)
            XCTAssertNil(store.popup)
            XCTAssertEqual(store.viewer.request?.root, project.url)
            XCTAssertEqual(store.viewer.request?.path, billingPath)
            XCTAssertEqual(store.viewer.pendingExcelSheet, "StarterPack")

            await store.viewer.loadTask?.value
            XCTAssertTrue(store.viewer.isSpreadsheet)
            XCTAssertNil(store.viewer.pendingExcelSheet)
            XCTAssertEqual(store.viewer.activeExcelSession?.activeSheetName, "StarterPack")

            // Activating another sheet on the already-open workbook switches immediately.
            store.quickOpen.query = "monthly"
            let foundMonthly = await waitUntil {
                store.quickOpen.items.contains {
                    if case .excelSheet(_, let path, let sheet, _) = $0 {
                        return path == billingPath && sheet == "IAPMonthlyCard"
                    }
                    return false
                }
            }
            XCTAssertTrue(foundMonthly)
            guard let monthlyIndex = store.quickOpen.items.firstIndex(where: {
                if case .excelSheet(_, let path, let sheet, _) = $0 {
                    return path == billingPath && sheet == "IAPMonthlyCard"
                }
                return false
            }) else {
                XCTFail("Expected IAPMonthlyCard item")
                return
            }

            store.quickOpen.activate(monthlyIndex)
            XCTAssertEqual(store.viewer.activeExcelSession?.activeSheetName, "IAPMonthlyCard")
            XCTAssertNil(store.viewer.pendingExcelSheet)
        }
    }
}
