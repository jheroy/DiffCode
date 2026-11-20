import XCTest
@testable import DifKit

final class XLSXTests: XCTestCase {

    // MARK: - Helpers

    private func makeMinimalXLSX(
        sheets: [(name: String, xml: String, commentsXML: String?)] = [],
        sharedStringsXML: String? = nil,
        stylesXML: String? = nil,
        date1904: Bool = false,
        compress: Bool = true
    ) -> Data {
        var entries: [(name: String, data: Data)] = []

        var sheetElements = ""
        var wbRelElements = ""
        for (idx, sheet) in sheets.enumerated() {
            let n = idx + 1
            let rId = "rId\(n)"
            sheetElements += "<sheet name=\"\(xmlEscape(sheet.name))\" sheetId=\"\(n)\" r:id=\"\(rId)\"/>"
            wbRelElements += "<Relationship Id=\"\(rId)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            entries.append(("xl/worksheets/sheet\(n).xml", Data(sheet.xml.utf8)))

            if let comments = sheet.commentsXML {
                let sheetRels = """
                <?xml version="1.0" encoding="UTF-8"?>
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
                  <Relationship Id="rIdC1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/comments" Target="../comments\(n).xml"/>
                </Relationships>
                """
                entries.append(("xl/worksheets/_rels/sheet\(n).xml.rels", Data(sheetRels.utf8)))
                entries.append(("xl/comments\(n).xml", Data(comments.utf8)))
            }
        }

        if let ss = sharedStringsXML {
            wbRelElements += "<Relationship Id=\"rIdSS\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" Target=\"sharedStrings.xml\"/>"
            entries.append(("xl/sharedStrings.xml", Data(ss.utf8)))
        }

        if let st = stylesXML {
            wbRelElements += "<Relationship Id=\"rIdST\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            entries.append(("xl/styles.xml", Data(st.utf8)))
        }

        let wbPr = date1904 ? "<workbookPr date1904=\"1\"/>" : "<workbookPr/>"
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          \(wbPr)
          <sheets>\(sheetElements)</sheets>
        </workbook>
        """
        let wbRelsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          \(wbRelElements)
        </Relationships>
        """

        entries.append(("xl/workbook.xml", Data(workbookXML.utf8)))
        entries.append(("xl/_rels/workbook.xml.rels", Data(wbRelsXML.utf8)))
        return XLSXZipArchive.create(entries: entries, compress: compress)
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func withTempDir(_ body: (URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-xlsx-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try await body(dir)
    }

    // MARK: - 1. ZIP Archive Tests

    func testZipStoredAndDeflateAndPathResolution() throws {
        let payloadA = Data(repeating: 0x41, count: 4096) // highly compressible
        let payloadB = Data("Hello 世界!\nLine 2".utf8)
        let payloadEmpty = Data()

        for compress in [false, true] {
            var zipData = XLSXZipArchive.create(entries: [
                ("XL/Workbook.xml", payloadA),
                ("xl/comments1.xml", payloadB),
                ("xl/empty.xml", payloadEmpty),
            ], compress: compress)

            // Append a ZIP comment to verify EOCD tail scanning handles non-empty comments.
            let comment = Data("Custom trailing ZIP comment!".utf8)
            let commentLenPos = zipData.count - 2
            zipData[commentLenPos] = UInt8(comment.count & 0xFF)
            zipData[commentLenPos + 1] = UInt8((comment.count >> 8) & 0xFF)
            zipData.append(comment)

            let archive = try XLSXZipArchive(data: zipData)
            XCTAssertEqual(try archive.readEntry(named: "/xl/workbook.xml"), payloadA)
            XCTAssertEqual(try archive.readEntry(named: "xl/worksheets/../comments1.xml"), payloadB)
            XCTAssertEqual(try archive.readEntry(named: "XL\\EMPTY.XML"), payloadEmpty)
            XCTAssertNil(try archive.readEntry(named: "xl/missing.xml"))
        }

        XCTAssertEqual(
            XLSXZipArchive.resolvePath("../comments1.xml", relativeTo: "xl/worksheets/sheet1.xml"),
            "xl/comments1.xml"
        )
        XCTAssertEqual(
            XLSXZipArchive.resolvePath("/xl/worksheets/sheet2.xml", relativeTo: "xl/workbook.xml"),
            "xl/worksheets/sheet2.xml"
        )
        XCTAssertEqual(
            XLSXZipArchive.resolvePath("worksheets/sheet1.xml", relativeTo: "xl/workbook.xml"),
            "xl/worksheets/sheet1.xml"
        )
    }

    func testZip64ExtraFieldSupport() throws {
        // Build a valid single-entry stored ZIP whose Central Directory uses 0xFFFFFFFF sentinels
        // and supplies true sizes & offset in a ZIP64 Extended Information Extra Field (0x0001).
        let payload = Data("ZIP64 payload".utf8)
        let name = Data("xl/test.txt".utf8)

        var out = Data()
        func u16(_ v: UInt16) {
            out.append(UInt8(v & 0xFF))
            out.append(UInt8((v >> 8) & 0xFF))
        }
        func u32(_ v: UInt32) {
            for shift in stride(from: 0, through: 24, by: 8) {
                out.append(UInt8((v >> shift) & 0xFF))
            }
        }
        func u64(_ v: UInt64) {
            for shift in stride(from: 0, through: 56, by: 8) {
                out.append(UInt8((v >> shift) & 0xFF))
            }
        }

        // Local file header at offset 0
        u32(0x04034b50); u16(45); u16(0); u16(0); u16(0); u16(0)
        u32(0); u32(UInt32(payload.count)); u32(UInt32(payload.count))
        u16(UInt16(name.count)); u16(0)
        out.append(name)
        out.append(payload)

        let cdOffset = UInt32(out.count)
        // Central directory header with ZIP64 sentinels + 0x0001 extra field (24 bytes of 3x UInt64)
        u32(0x02014b50); u16(45); u16(45); u16(0); u16(0); u16(0); u16(0)
        u32(0)
        u32(0xFFFFFFFF) // compressedSize sentinel
        u32(0xFFFFFFFF) // uncompressedSize sentinel
        u16(UInt16(name.count))
        u16(28)         // extra length: 4 header + 24 data
        u16(0); u16(0); u16(0); u32(0)
        u32(0xFFFFFFFF) // localHeaderOffset sentinel
        out.append(name)
        // ZIP64 Extra Field (0x0001)
        u16(0x0001); u16(24)
        u64(UInt64(payload.count)) // uncompressed size
        u64(UInt64(payload.count)) // compressed size
        u64(0)                     // local header offset

        let cdSize = UInt32(out.count) - cdOffset
        // EOCD
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(cdSize); u32(cdOffset); u16(0)

        let archive = try XLSXZipArchive(data: out)
        XCTAssertEqual(try archive.readEntry(named: "xl/test.txt"), payload)
    }

    func testInvalidArchiveThrows() {
        XCTAssertThrowsError(try XLSXReader.parse(data: Data("not a zip".utf8)))
        let emptyZip = XLSXZipArchive.create(entries: [("dummy.txt", Data("hi".utf8))])
        XCTAssertThrowsError(try XLSXReader.parse(data: emptyZip)) { error in
            XCTAssertEqual(error as? XLSXError, .missingWorkbook)
        }
    }

    // MARK: - 2. Full Cell Types, Rich Text, Entities & Cached Formulas

    func testCellTypesSharedStringsRichTextAndFormulas() throws {
        let sharedStrings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" uniqueCount="5">
          <si><t>ID</t></si>
          <si><t xml:space="preserve"> Name &amp; Title </t></si>
          <si><r><t>Hello </t></r><r><t xml:space="preserve">World!</t></r><rPh sb="0" eb="1"><t>IGNORED_PHONETIC</t></rPh></si>
          <si><t>Line1&#10;Line2 &lt;ok&gt;</t></si>
          <si/>
        </sst>
        """

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="s"><v>0</v></c>
              <c r="B1" t="s"><v>1</v></c>
              <c r="C1" t="inlineStr"><is><t>Active</t></is></c>
              <c r="D1" t="inlineStr"><is><r><t>Score</t></r></is></c>
              <c r="E1" t="inlineStr"><is><t>FormulaStr</t></is></c>
              <c r="F1" t="inlineStr"><is><t>FormulaNum</t></is></c>
              <c r="G1" t="inlineStr"><is><t>Err</t></is></c>
            </row>
            <row r="2">
              <c r="A2"><v>42.0</v></c>
              <c r="B2" t="s"><v>2</v></c>
              <c r="C2" t="b"><v>1</v></c>
              <c r="D2"><v>0.30000000000000004</v></c>
              <c r="E2" t="str"><f>CONCAT("a","b")</f><v>ab</v></c>
              <c r="F2"><f>SUM(A2:A2)</f><v>42</v></c>
              <c r="G2" t="e"><f>1/0</f><v>#DIV/0!</v></c>
            </row>
            <row r="3">
              <c r="A3"><v>-0.0</v></c>
              <c r="B3" t="s"><v>3</v></c>
              <c r="C3" t="b"><v>0</v></c>
              <c r="D3"><v>3.14159</v></c>
              <c r="E3" t="s"><v>4</v></c>
              <c r="F3"><f>1+2</f></c>
              <c r="G3" t="inlineStr"><is><t><![CDATA[raw <tag> & text]]></t></is></c>
            </row>
          </sheetData>
        </worksheet>
        """

        let data = makeMinimalXLSX(
            sheets: [("Config", sheetXML, nil)],
            sharedStringsXML: sharedStrings
        )
        let wb = try XLSXReader.parse(data: data)
        XCTAssertEqual(wb.sheets.count, 1)

        let sheet = wb.sheets[0]
        XCTAssertEqual(sheet.name, "Config")
        XCTAssertEqual(sheet.headers, ["ID", " Name & Title ", "Active", "Score", "FormulaStr", "FormulaNum", "Err"])
        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.rows[0], ["42", "Hello World!", "true", "0.3", "ab", "42", "#DIV/0!"])
        XCTAssertEqual(sheet.rows[1], ["0", "Line1\nLine2 <ok>", "false", "3.14159", "", "", "raw <tag> & text"])
    }

    // MARK: - 3. Excel Date Serials (1900 & 1904 Systems)

    func testExcelDates1900And1904() throws {
        let stylesXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="2">
            <numFmt numFmtId="164" formatCode="yyyy&quot;年&quot;m&quot;月&quot;d&quot;日&quot;"/>
            <numFmt numFmtId="165" formatCode="#,##0.00"/>
          </numFmts>
          <cellStyleXfs count="1">
            <xf numFmtId="14"/>
          </cellStyleXfs>
          <cellXfs count="5">
            <xf numFmtId="0"/>
            <xf numFmtId="14"/>
            <xf numFmtId="22"/>
            <xf numFmtId="164"/>
            <xf numFmtId="165"/>
          </cellXfs>
        </styleSheet>
        """

        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>Date</t></is></c>
              <c r="B1" t="inlineStr"><is><t>DateTime</t></is></c>
              <c r="C1" t="inlineStr"><is><t>CustomDate</t></is></c>
              <c r="D1" t="inlineStr"><is><t>Currency</t></is></c>
              <c r="E1" t="inlineStr"><is><t>TimeOnly</t></is></c>
            </row>
            <row r="2">
              <c r="A2" s="1"><v>45292</v></c>
              <c r="B2" s="2"><v>45292.5</v></c>
              <c r="C2" s="3"><v>61</v></c>
              <c r="D2" s="4"><v>45292</v></c>
              <c r="E2" s="2"><v>0.25</v></c>
            </row>
            <row r="3">
              <c r="A3" s="1"><v>1</v></c>
              <c r="B3" s="1"><v>59</v></c>
              <c r="C3" s="2"><v>45292.999999</v></c>
            </row>
          </sheetData>
        </worksheet>
        """

        // 1900 date system
        let wb1900 = try XLSXReader.parse(data: makeMinimalXLSX(
            sheets: [("Dates", sheetXML, nil)],
            stylesXML: stylesXML,
            date1904: false
        ))
        let s1900 = wb1900.sheets[0]
        XCTAssertEqual(s1900.rows[0], ["2024-01-01", "2024-01-01 12:00:00", "1900-03-01", "45292", "06:00:00"])
        XCTAssertEqual(s1900.rows[1], ["1900-01-01", "1900-02-28", "2024-01-02", "", ""])

        // 1904 date system: 43830 -> 2024-01-01, 0 -> 1904-01-01
        let sheet1904XML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>D1</t></is></c>
              <c r="B1" t="inlineStr"><is><t>D2</t></is></c>
            </row>
            <row r="2">
              <c r="A2" s="1"><v>43830</v></c>
              <c r="B2" s="1"><v>0</v></c>
            </row>
          </sheetData>
        </worksheet>
        """
        let wb1904 = try XLSXReader.parse(data: makeMinimalXLSX(
            sheets: [("MacDates", sheet1904XML, nil)],
            stylesXML: stylesXML,
            date1904: true
        ))
        XCTAssertEqual(wb1904.sheets[0].rows[0], ["2024-01-01", "1904-01-01"])
    }

    // MARK: - 4. Sparse Columns, Header Fallback & Namespace Prefixes

    func testSparseColumnsHeaderFallbackAndPrefixedNamespaces() throws {
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:worksheet xmlns:x="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <x:sheetData>
            <x:row r="1">
              <x:c r="A1" t="inlineStr"><x:is><x:t>First</x:t></x:is></x:c>
              <x:c r="C1" t="inlineStr"><x:is><x:t>Third</x:t></x:is></x:c>
            </x:row>
            <x:row r="2">
              <x:c r="A2"><x:v>10</x:v></x:c>
              <x:c r="AA2" t="inlineStr"><x:is><x:t>FarCol</x:t></x:is></x:c>
            </x:row>
            <x:row>
              <x:c t="inlineStr"><x:is><x:t>Seq0</x:t></x:is></x:c>
              <x:c t="inlineStr"><x:is><x:t>Seq1</x:t></x:is></x:c>
            </x:row>
          </x:sheetData>
        </x:worksheet>
        """

        let wb = try XLSXReader.parse(data: makeMinimalXLSX(sheets: [("Sparse", sheetXML, nil)]))
        let sheet = wb.sheets[0]
        // AA is column index 26 -> 27 total columns.
        XCTAssertEqual(sheet.headers.count, 27)
        XCTAssertEqual(sheet.headers[0], "First")
        XCTAssertEqual(sheet.headers[1], "Col 1")
        XCTAssertEqual(sheet.headers[2], "Third")
        XCTAssertEqual(sheet.headers[26], "Col 26")

        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.rows[0].count, 27)
        XCTAssertEqual(sheet.rows[0][0], "10")
        XCTAssertEqual(sheet.rows[0][1], "")
        XCTAssertEqual(sheet.rows[0][26], "FarCol")

        XCTAssertEqual(sheet.rows[1][0], "Seq0")
        XCTAssertEqual(sheet.rows[1][1], "Seq1")
    }

    // MARK: - 5. Comments Extraction

    func testCommentsHeaderAndDataMapping() throws {
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>Key</t></is></c>
              <c r="B1" t="inlineStr"><is><t>Value</t></is></c>
            </row>
            <row r="2">
              <c r="A2" t="inlineStr"><is><t>k1</t></is></c>
              <c r="B2" t="inlineStr"><is><t>v1</t></is></c>
            </row>
          </sheetData>
        </worksheet>
        """

        let commentsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <comments xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <commentList>
            <comment ref="A1">
              <text><r><t>Header note: </t></r><r><t>unique key</t></r></text>
            </comment>
            <comment ref="B2">
              <text><t>Data cell comment</t></text>
            </comment>
            <comment ref="C5">
              <text><t>Row 5 comment</t></text>
            </comment>
          </commentList>
        </comments>
        """

        let wb = try XLSXReader.parse(data: makeMinimalXLSX(sheets: [("Notes", sheetXML, commentsXML)]))
        let sheet = wb.sheets[0]
        XCTAssertEqual(sheet.comment(row: -1, col: 0), "Header note: unique key")
        XCTAssertEqual(sheet.comment(row: 0, col: 1), "Data cell comment")
        XCTAssertEqual(sheet.comment(row: 3, col: 2), "Row 5 comment")
        XCTAssertNil(sheet.comment(row: 0, col: 0))
    }

    // MARK: - 6. Ultra-Fast sheetNames(at:)

    func testFastSheetNamesSkipsWorksheetsAndSharedStrings() async throws {
        // Put ONLY xl/workbook.xml in the ZIP (no worksheets, no sharedStrings) to prove
        // sheetNames(at:) only inspects the ZIP Central Directory + xl/workbook.xml.
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="Items" sheetId="1" r:id="rId1"/>
            <sheet name="技能表 &amp; Buff" sheetId="2" r:id="rId2"/>
            <sheet name="Localization" sheetId="3" r:id="rId3"/>
          </sheets>
        </workbook>
        """
        let zip = XLSXZipArchive.create(entries: [
            ("xl/workbook.xml", Data(workbookXML.utf8)),
        ])

        try await withTempDir { dir in
            let fileURL = dir.appendingPathComponent("config.xlsx")
            try zip.write(to: fileURL)
            XCTAssertEqual(XLSXReader.sheetNames(at: fileURL), ["Items", "技能表 & Buff", "Localization"])
            XCTAssertEqual(XLSXReader.sheetNames(at: dir.appendingPathComponent("missing.xlsx")), [])
        }
    }

    // MARK: - 7. Search Parity Tests

    func testSearchAcrossSheetsModesAndInvalidRegex() {
        let s0 = XLSXSheet(
            name: "Heroes",
            headers: ["HeroID", "HeroName"],
            rows: [
                ["1001", "Knight"],
                ["1002", "heroic Mage"],
            ],
            comments: [:]
        )
        let s1 = XLSXSheet(
            name: "Skills",
            headers: ["SkillID", "Desc"],
            rows: [
                ["2001", "Hero Strike"],
            ],
            comments: [:]
        )
        let wb = XLSXWorkbook(sheets: [s0, s1])

        XCTAssertTrue(wb.search(query: "", mode: .caseInsensitive).isEmpty)

        // Case-insensitive: headers first (-1), then data rows left-to-right across sheets
        XCTAssertEqual(wb.search(query: "hero", mode: .caseInsensitive), [
            XLSXSearchMatch(sheetIndex: 0, row: -1, col: 0),
            XLSXSearchMatch(sheetIndex: 0, row: -1, col: 1),
            XLSXSearchMatch(sheetIndex: 0, row: 1, col: 1),
            XLSXSearchMatch(sheetIndex: 1, row: 0, col: 1),
        ])

        // Case-sensitive
        XCTAssertEqual(wb.search(query: "Hero", mode: .caseSensitive), [
            XLSXSearchMatch(sheetIndex: 0, row: -1, col: 0),
            XLSXSearchMatch(sheetIndex: 0, row: -1, col: 1),
            XLSXSearchMatch(sheetIndex: 1, row: 0, col: 1),
        ])

        // Regex (case-insensitive matching ExcelFileEditor.kt:1126)
        XCTAssertEqual(wb.search(query: "^[12]00[12]$", mode: .regex), [
            XLSXSearchMatch(sheetIndex: 0, row: 0, col: 0),
            XLSXSearchMatch(sheetIndex: 0, row: 1, col: 0),
            XLSXSearchMatch(sheetIndex: 1, row: 0, col: 0),
        ])
        XCTAssertEqual(wb.search(query: "mage$", mode: .regex), [
            XLSXSearchMatch(sheetIndex: 0, row: 1, col: 1),
        ])

        // Invalid regex never crashes
        XCTAssertEqual(wb.search(query: "[unclosed(", mode: .regex), [])
    }

    // MARK: - 8. TSV Formatting Tests

    func testTSVFormattingSingleMultiQuotingAndHiddenColumns() {
        let sheet = XLSXSheet(
            name: "T",
            headers: ["A", "B", "C", "D"],
            rows: [
                ["plain", "has\ttab", "hidden", "say \"hi\""],
                ["line1\nline2", "r\rcr", "skip", "end"],
            ],
            comments: [:]
        )

        // Empty / all-hidden selections
        XCTAssertEqual(sheet.formatTSV(rows: [], columns: [0], visibleColumns: [0, 1]), "")
        XCTAssertEqual(sheet.formatTSV(rows: [0], columns: [2], visibleColumns: [0, 1, 3]), "")

        // Single cell returns raw value WITHOUT quoting (even with quotes/tabs/newlines)
        XCTAssertEqual(sheet.formatTSV(rows: [0], columns: [1], visibleColumns: [0, 1, 2, 3]), "has\ttab")
        XCTAssertEqual(sheet.formatTSV(rows: [0], columns: [3], visibleColumns: [0, 1, 2, 3]), "say \"hi\"")

        // Multi-cell skips hidden column 2 and quotes cells with \t, \n, \r, or "
        let tsv = sheet.formatTSV(rows: [0, 1], columns: [0, 1, 2, 3], visibleColumns: [0, 1, 3])
        let expected = [
            "plain\t\"has\ttab\"\t\"say \"\"hi\"\"\"",
            "\"line1\nline2\"\t\"r\rcr\"\tend",
        ].joined(separator: "\n")
        XCTAssertEqual(tsv, expected)
    }

    // MARK: - 9. DiffLoader Integration Tests

    func testDiffLoaderLoadsXLSXAsSingleSpreadsheetNeverTwoPaneDiff() async throws {
        XCTAssertTrue(DiffLoader.isSpreadsheetPath("data/Items.xlsx"))
        XCTAssertTrue(DiffLoader.isSpreadsheetPath("CONFIG.XLSX"))
        XCTAssertFalse(DiffLoader.isSpreadsheetPath("data/Items.xls"))
        XCTAssertFalse(DiffLoader.isSpreadsheetPath("README.md"))

        let v1Sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>Version</t></is></c></row>
            <row r="2"><c r="A2"><v>1</v></c></row>
          </sheetData>
        </worksheet>
        """
        let v2Sheet = """
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
            <row r="1"><c r="A1" t="inlineStr"><is><t>Version</t></is></c></row>
            <row r="2"><c r="A2"><v>2</v></c></row>
          </sheetData>
        </worksheet>
        """
        let xlsxV1 = makeMinimalXLSX(sheets: [("Meta", v1Sheet, nil)])
        let xlsxV2 = makeMinimalXLSX(sheets: [("Meta", v2Sheet, nil)])

        try await withTempDir { repo in
            // Initialize a real git repo and commit v1, then modify working tree to v2.
            _ = try await Git.run(["init", "-q"], in: repo)
            _ = try await Git.run(["config", "user.email", "test@example.com"], in: repo)
            _ = try await Git.run(["config", "user.name", "Test"], in: repo)

            let fileURL = repo.appendingPathComponent("config.xlsx")
            try xlsxV1.write(to: fileURL)
            _ = try await Git.run(["add", "config.xlsx"], in: repo)
            _ = try await Git.run(["commit", "-q", "-m", "v1"], in: repo)
            let commitHash = String(decoding: try await Git.run(["rev-parse", "HEAD"], in: repo), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Modify working tree to v2.
            try xlsxV2.write(to: fileURL)

            // 1. Working tree modified file -> single spreadsheet (v2), isPlainFile == true, no hunks!
            let wtRequest = DiffRequest(root: repo, path: "config.xlsx", kind: .modified, source: .worktree(base: "HEAD"))
            let wtDoc = await DiffLoader.load(wtRequest)
            XCTAssertTrue(wtDoc.isPlainFile)
            XCTAssertTrue(wtDoc.hunks.isEmpty)
            if case .spreadsheet(let wb, let resolvedURL) = wtDoc.content {
                XCTAssertEqual(wb.sheets.count, 1)
                XCTAssertEqual(wb.sheets[0].rows, [["2"]])
                XCTAssertEqual(resolvedURL?.standardizedFileURL, fileURL.standardizedFileURL)
            } else {
                XCTFail("Expected .spreadsheet content for working tree modified .xlsx")
            }

            // 2. Plain file request
            let fileDoc = await DiffLoader.load(DiffRequest(root: repo, path: "config.xlsx", source: .file))
            XCTAssertTrue(fileDoc.isPlainFile)
            if case .spreadsheet(let wb, _) = fileDoc.content {
                XCTAssertEqual(wb.sheets[0].rows, [["2"]])
            } else {
                XCTFail("Expected .spreadsheet content for plain .xlsx file")
            }

            // 3. Commit request loads committed blob (v1) with nil fileURL
            let commitDoc = await DiffLoader.load(
                DiffRequest(root: repo, path: "config.xlsx", kind: .added, source: .commit(hash: commitHash, parent: nil))
            )
            XCTAssertTrue(commitDoc.isPlainFile)
            if case .spreadsheet(let wb, let resolvedURL) = commitDoc.content {
                XCTAssertEqual(wb.sheets[0].rows, [["1"]])
                XCTAssertNil(resolvedURL)
            } else {
                XCTFail("Expected .spreadsheet content for commit .xlsx")
            }

            // 4. Corrupt .xlsx returns friendly .message (never binary noise)
            try Data("corrupted xlsx bytes".utf8).write(to: fileURL)
            let corruptDoc = await DiffLoader.load(wtRequest)
            if case .message(let title, let detail) = corruptDoc.content {
                XCTAssertFalse(title.isEmpty)
                XCTAssertFalse(detail.isEmpty)
            } else {
                XCTFail("Expected friendly .message for corrupt .xlsx")
            }

            // 5. Deleted working tree .xlsx returns .message
            try FileManager.default.removeItem(at: fileURL)
            let deletedDoc = await DiffLoader.load(
                DiffRequest(root: repo, path: "config.xlsx", kind: .deleted, source: .worktree(base: "HEAD"))
            )
            if case .message(let title, _) = deletedDoc.content {
                XCTAssertFalse(title.isEmpty)
            } else {
                XCTFail("Expected .message for deleted .xlsx")
            }

            // 6. Commit that deleted the .xlsx falls back to parent blob
            _ = try await Git.run(["rm", "-q", "config.xlsx"], in: repo)
            _ = try await Git.run(["commit", "-q", "-m", "delete xlsx"], in: repo)
            let deleteCommitHash = String(decoding: try await Git.run(["rev-parse", "HEAD"], in: repo), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let deletedCommitDoc = await DiffLoader.load(
                DiffRequest(root: repo, path: "config.xlsx", kind: .deleted, source: .commit(hash: deleteCommitHash, parent: commitHash))
            )
            XCTAssertTrue(deletedCommitDoc.isPlainFile)
            if case .spreadsheet(let wb, let resolvedURL) = deletedCommitDoc.content {
                XCTAssertEqual(wb.sheets[0].rows, [["1"]])
                XCTAssertNil(resolvedURL)
            } else {
                XCTFail("Expected parent .spreadsheet fallback for deleted commit .xlsx")
            }
        }
    }

    func testMultiSheetOrderWithSwappedRelationshipIDsAndEmptySheet() throws {
        let workbookXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
                  xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <sheets>
            <sheet name="FirstByOrder" sheetId="2" r:id="rId2"/>
            <sheet name="EmptySheet" sheetId="3" r:id="rId3"/>
            <sheet name="SecondByOrder" sheetId="1" r:id="rId1"/>
          </sheets>
        </workbook>
        """
        let wbRels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="/xl/worksheets/sheet_a.xml"/>
          <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet_b.xml"/>
          <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet_empty.xml"/>
        </Relationships>
        """
        let sheetA = """
        <worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>FromA</t></is></c></row></sheetData></worksheet>
        """
        let sheetB = """
        <worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>FromB</t></is></c></row></sheetData></worksheet>
        """
        let sheetEmpty = "<worksheet><sheetData/></worksheet>"

        let data = XLSXZipArchive.create(entries: [
            ("xl/workbook.xml", Data(workbookXML.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(wbRels.utf8)),
            ("xl/worksheets/sheet_a.xml", Data(sheetA.utf8)),
            ("xl/worksheets/sheet_b.xml", Data(sheetB.utf8)),
            ("xl/worksheets/sheet_empty.xml", Data(sheetEmpty.utf8)),
        ])

        let wb = try XLSXReader.parse(data: data)
        XCTAssertEqual(wb.sheets.map(\.name), ["FirstByOrder", "EmptySheet", "SecondByOrder"])
        XCTAssertEqual(wb.sheets[0].headers, ["FromB"])
        XCTAssertEqual(wb.sheets[1].headers, [])
        XCTAssertEqual(wb.sheets[1].rows, [])
        XCTAssertEqual(wb.sheets[2].headers, ["FromA"])
        XCTAssertEqual(XLSXReader.sheetNames(data: data), ["FirstByOrder", "EmptySheet", "SecondByOrder"])
    }

    // MARK: - 10. Performance Smoke Tests

    func testPerformance5000RowsBy20Cols() throws {
        let rowCount = 5_000
        let colCount = 20
        let colLetters = (0..<colCount).map { String(UnicodeScalar(65 + $0)!) }

        var ss = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" uniqueCount=\"20\">"
        for i in 0..<20 {
            ss += "<si><t>SharedText_\(i)</t></si>"
        }
        ss += "</sst>"

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        xml.reserveCapacity(rowCount * colCount * 42)
        xml += "<row r=\"1\">"
        for c in 0..<colCount {
            xml += "<c r=\"\(colLetters[c])1\" t=\"inlineStr\"><is><t>Header_\(c)</t></is></c>"
        }
        xml += "</row>"
        for r in 0..<rowCount {
            let excelRow = r + 2
            xml += "<row r=\"\(excelRow)\">"
            for c in 0..<colCount {
                if c % 3 == 0 {
                    xml += "<c r=\"\(colLetters[c])\(excelRow)\"><v>\(r * colCount + c)</v></c>"
                } else if c % 3 == 1 {
                    xml += "<c r=\"\(colLetters[c])\(excelRow)\" t=\"s\"><v>\((r + c) % 20)</v></c>"
                } else {
                    xml += "<c r=\"\(colLetters[c])\(excelRow)\"><v>\(Double(r) + 0.25)</v></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"

        let xlsxData = makeMinimalXLSX(sheets: [("BigSheet", xml, nil)], sharedStringsXML: ss, compress: true)

        let start = CFAbsoluteTimeGetCurrent()
        let wb = try XLSXReader.parse(data: xlsxData)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(wb.sheets.count, 1)
        XCTAssertEqual(wb.sheets[0].headers.count, colCount)
        XCTAssertEqual(wb.sheets[0].rows.count, rowCount)
        XCTAssertEqual(wb.sheets[0].rows[0][0], "0")
        XCTAssertEqual(wb.sheets[0].rows[rowCount - 1][1], "SharedText_\((rowCount - 1 + 1) % 20)")
        XCTAssertLessThan(elapsed, 0.5, "Parsing 5,000x20 sheet took \(String(format: "%.3f", elapsed))s (budget: 0.5s)")
    }
}
