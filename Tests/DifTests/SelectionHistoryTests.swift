import XCTest
@testable import DifKit

final class SelectionHistoryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-sel-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Alice")
        try git("config", "user.email", "alice@example.com")
    }

    override func tearDown() async throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: - Patch Parsing

    func testParseLineHistoryEntriesAddedModifiedDeletedRenamedAndCombined() {
        let h1 = String(repeating: "1", count: 40)
        let h2 = String(repeating: "2", count: 40)
        let h3 = String(repeating: "3", count: 40)
        let h4 = String(repeating: "4", count: 40)
        let h5 = String(repeating: "5", count: 40)
        let p0 = String(repeating: "a", count: 40)
        let p1 = String(repeating: "b", count: 40)

        let raw = [
            // 1. Merge combined diff (@@@) with multi-line commit body
            "\u{1e}DIF_LH_START\u{1f}\(h5)\u{1f}\(p0) \(p1)\u{1f}MergeBot\u{1f}merge@example.com\u{1f}1767294000\u{1f}HEAD -> refs/heads/main\u{1f}merge branch\u{1f}merge branch\n\nDetailed body line\u{1e}DIF_LH_PATCH\u{1e}\n"
            + "diff --cc Sources/App.swift\n"
            + "index 1111111,2222222..3333333\n"
            + "--- a/Sources/App.swift\n"
            + "+++ b/Sources/App.swift\n"
            + "@@@ -10,3 -12,3 +10,3 @@@ func run() {\n"
            + "  let keep = 1\n"
            + "- let oldP1 = 2\n"
            + " -let onlyP2 = 99\n"
            + "+ let merged = 3\n"
            + "  return\n",

            // 2. Rename with multiple hunks, omitted counts (@@ -5 +5 @@), CRLF, and no-newline marker
            "\u{1e}DIF_LH_START\u{1f}\(h4)\u{1f}\(h3)\u{1f}Bob\u{1f}bob@example.com\u{1f}1767293000\u{1f}\u{1f}rename and tweak\u{1f}rename and tweak\u{1e}DIF_LH_PATCH\u{1e}\r\n"
            + "diff --git a/Sources/Old.swift b/Sources/New.swift\r\n"
            + "--- a/Sources/Old.swift\r\n"
            + "+++ b/Sources/New.swift\r\n"
            + "@@ -5 +5 @@ struct S {\r\n"
            + "-let x = 1\r\n"
            + "+let x = 2\r\n"
            + "@@ -20,2 +20,3 @@ func tail() {\r\n"
            + " let start = 0\r\n"
            + "+let added = 1\r\n"
            + " let end = 2\r\n"
            + "\\ No newline at end of file\r\n",

            // 3. Single-line deletion
            "\u{1e}DIF_LH_START\u{1f}\(h3)\u{1f}\(h2)\u{1f}Alice\u{1f}alice@example.com\u{1f}1767292000\u{1f}\u{1f}remove line\u{1f}remove line\u{1e}DIF_LH_PATCH\u{1e}\n"
            + "diff --git a/Sources/Old.swift b/Sources/Old.swift\n"
            + "--- a/Sources/Old.swift\n"
            + "+++ b/Sources/Old.swift\n"
            + "@@ -8,3 +8,2 @@\n"
            + " keepA\n"
            + "-dropB\n"
            + " keepC\n",

            // 4. Added file from /dev/null
            "\u{1e}DIF_LH_START\u{1f}\(h1)\u{1f}\u{1f}Alice\u{1f}alice@example.com\u{1f}1767291000\u{1f}\u{1f}initial file\u{1f}initial file\u{1e}DIF_LH_PATCH\u{1e}\n"
            + "diff --git a/Sources/Old.swift b/Sources/Old.swift\n"
            + "new file mode 100644\n"
            + "--- /dev/null\n"
            + "+++ b/Sources/Old.swift\n"
            + "@@ -0,0 +1,2 @@\n"
            + "+line1\n"
            + "+line2\n"
        ].joined()

        let entries = Git.parseLineHistoryEntries(Data(raw.utf8))
        XCTAssertEqual(entries.count, 4)

        // Entry 0: combined merge diff ignores parent-2-only deletion (" -let onlyP2 = 99")
        let mergeEntry = entries[0]
        XCTAssertEqual(mergeEntry.commit.hash, h5)
        XCTAssertTrue(mergeEntry.commit.isMerge)
        XCTAssertEqual(mergeEntry.commit.body, "merge branch\n\nDetailed body line")
        XCTAssertEqual(mergeEntry.sectionHeader, "func run() {")
        XCTAssertEqual(mergeEntry.leftLines, ["let keep = 1", "let oldP1 = 2", "return"])
        XCTAssertEqual(mergeEntry.rightLines, ["let keep = 1", "let merged = 3", "return"])
        XCTAssertEqual(mergeEntry.leftLineNumbers, [10, 11, 12])
        XCTAssertEqual(mergeEntry.rightLineNumbers, [10, 11, 12])
        XCTAssertEqual(mergeEntry.hunks, [Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1)])

        // Entry 1: rename + multiple hunks + omitted counts + CRLF + no newline marker
        let renameEntry = entries[1]
        XCTAssertEqual(renameEntry.oldPath, "Sources/Old.swift")
        XCTAssertEqual(renameEntry.newPath, "Sources/New.swift")
        XCTAssertTrue(renameEntry.isRename)
        XCTAssertEqual(renameEntry.leftLines, ["let x = 1", "let start = 0", "let end = 2"])
        XCTAssertEqual(renameEntry.rightLines, ["let x = 2", "let start = 0", "let added = 1", "let end = 2"])
        XCTAssertEqual(renameEntry.leftLineNumbers, [5, 20, 21])
        XCTAssertEqual(renameEntry.rightLineNumbers, [5, 20, 21, 22])
        XCTAssertEqual(renameEntry.hunks, [
            Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1),
            Hunk(leftStart: 2, leftCount: 0, rightStart: 2, rightCount: 1),
        ])
        XCTAssertEqual(renameEntry.additions, 2)
        XCTAssertEqual(renameEntry.deletions, 1)

        // Entry 2: deletion
        let deleteEntry = entries[2]
        XCTAssertEqual(deleteEntry.leftLines, ["keepA", "dropB", "keepC"])
        XCTAssertEqual(deleteEntry.rightLines, ["keepA", "keepC"])
        XCTAssertEqual(deleteEntry.leftLineNumbers, [8, 9, 10])
        XCTAssertEqual(deleteEntry.rightLineNumbers, [8, 9])
        XCTAssertEqual(deleteEntry.hunks, [Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 0)])

        // Entry 3: initial file from /dev/null
        let addedEntry = entries[3]
        XCTAssertNil(addedEntry.oldPath)
        XCTAssertEqual(addedEntry.newPath, "Sources/Old.swift")
        XCTAssertFalse(addedEntry.isRename)
        XCTAssertEqual(addedEntry.leftLines, [])
        XCTAssertEqual(addedEntry.rightLines, ["line1", "line2"])
        XCTAssertEqual(addedEntry.leftLineNumbers, [])
        XCTAssertEqual(addedEntry.rightLineNumbers, [1, 2])
        XCTAssertEqual(addedEntry.hunks, [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 2)])
    }

    // MARK: - Git Integration & DiffDocument

    func testGitLineHistoryEntriesExcludesUnrelatedFileChanges() async throws {
        let initial = (1...12).map { "let line\($0) = \($0)" }.joined(separator: "\n") + "\n"
        try write("sample.swift", initial)
        try git("add", "sample.swift")
        try commit("c1: initial sample", date: "2026-01-01T10:00:00")

        // c2 modifies ONLY line 2 (unrelated to line 10).
        var c2Lines = (1...12).map { "let line\($0) = \($0)" }
        c2Lines[1] = "let line2 = 200 // unrelated edit"
        try write("sample.swift", c2Lines.joined(separator: "\n") + "\n")
        try git("add", "sample.swift")
        try commit("c2: unrelated line 2", date: "2026-01-02T10:00:00")

        // c3 modifies BOTH line 2 (unrelated) AND line 10 (selected).
        var c3Lines = c2Lines
        c3Lines[1] = "let line2 = 201 // unrelated edit again"
        c3Lines[9] = "let line10 = 1000 // tracked change"
        try write("sample.swift", c3Lines.joined(separator: "\n") + "\n")
        try git("add", "sample.swift")
        try commit("c3: update line 10 and line 2", date: "2026-01-03T10:00:00")

        let entries = try await Git.lineHistoryEntries(
            "sample.swift",
            lines: 10...10,
            rev: "HEAD",
            in: root,
            skip: 0,
            limit: 50
        )

        XCTAssertEqual(entries.map(\.commit.subject), ["c3: update line 10 and line 2", "c1: initial sample"])

        // Verify c3 preview contains ONLY the tracked region around line 10, never line 2!
        let c3 = entries[0]
        XCTAssertFalse(c3.leftLines.contains(where: { $0.contains("line2") }))
        XCTAssertFalse(c3.rightLines.contains(where: { $0.contains("line2") }))
        XCTAssertTrue(c3.leftLines.contains("let line10 = 10"))
        XCTAssertTrue(c3.rightLines.contains("let line10 = 1000 // tracked change"))
        XCTAssertEqual(c3.hunks.count, 1)

        // Verify DiffDocument line-number mapping and inline highlights
        let doc = c3.makeDiffDocument(fallbackPath: "sample.swift")
        XCTAssertEqual(doc.leftLineNumbers, c3.leftLineNumbers)
        XCTAssertEqual(doc.rightLineNumbers, c3.rightLineNumbers)
        XCTAssertEqual(doc.maxDisplayLineNumber, max(c3.leftLineNumbers.max() ?? 0, c3.rightLineNumbers.max() ?? 0))
        if let idx = c3.rightLines.firstIndex(of: "let line10 = 1000 // tracked change") {
            XCTAssertEqual(doc.displayLineNumber(side: .right, line: idx), 10)
        } else {
            XCTFail("Expected tracked line in rightLines")
        }
        XCTAssertEqual(doc.right.spans.count, c3.rightLines.count)
        XCTAssertFalse(doc.hunks[0].rightInline.isEmpty)
        XCTAssertNil(doc.editing)
        XCTAssertEqual(doc.rightTitle, c3.commit.shortHash)
    }

    // MARK: - SelectionHistoryModel

    @MainActor
    func testSelectionHistoryModelFilteringNavigationAndModePersistence() {
        let suiteName = "SelectionHistoryTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = SelectionHistoryModel(defaults: defaults)
        XCTAssertFalse(model.unified)

        let c1 = Commit(
            hash: String(repeating: "a", count: 40),
            parents: [],
            author: "Alice",
            email: "alice@example.com",
            date: Date(timeIntervalSince1970: 1_767_290_400),
            refs: ["HEAD -> refs/heads/main"],
            subject: "fix popup scrolling",
            body: "fix popup scrolling\n\nImproves keyboard navigation"
        )
        let c2 = Commit(
            hash: String(repeating: "b", count: 40),
            parents: [c1.hash],
            author: "Bob",
            email: "bob@example.com",
            date: Date(timeIntervalSince1970: 1_767_200_000),
            refs: [],
            subject: "initial commit",
            body: "initial commit"
        )
        let e1 = LineHistoryEntry(
            commit: c1,
            oldPath: "Sources/Popups.swift",
            newPath: "Sources/Popups.swift",
            leftStartLine: 40,
            rightStartLine: 40,
            leftLines: ["let x = 1"],
            rightLines: ["let x = 2"],
            leftLineNumbers: [40],
            rightLineNumbers: [40],
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            sectionHeader: "func scroll()"
        )
        let e2 = LineHistoryEntry(
            commit: c2,
            oldPath: nil,
            newPath: "Sources/Popups.swift",
            leftStartLine: 0,
            rightStartLine: 40,
            leftLines: [],
            rightLines: ["let x = 1"],
            leftLineNumbers: [],
            rightLineNumbers: [40],
            hunks: [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 1)],
            sectionHeader: ""
        )

        model.setEntriesForTesting(displayPath: "Sources/Popups.swift", displayLines: 40...42, entries: [e1, e2])
        XCTAssertEqual(model.lineRangeLabel, "L40–42")
        XCTAssertEqual(model.selectedEntry?.commit.hash, c1.hash)
        XCTAssertEqual(model.previewDocument?.rightLineNumbers, [40])

        model.move(1)
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.selectedEntry?.commit.hash, c2.hash)
        XCTAssertEqual(model.previewDocument?.left.lines, [])

        // Multi-term filter matches author + body
        model.filterQuery = "alice keyboard"
        XCTAssertEqual(model.filteredEntries.map(\.id), [c1.hash])
        XCTAssertEqual(model.selectedIndex, 0)

        // Hash filter
        model.filterQuery = "bbbb"
        XCTAssertEqual(model.filteredEntries.map(\.id), [c2.hash])

        model.filterQuery = ""
        XCTAssertEqual(model.filteredEntries.count, 2)

        // Unified toggle persists to UserDefaults
        model.toggleUnified()
        XCTAssertTrue(model.unified)
        XCTAssertEqual(defaults.object(forKey: SelectionHistoryModel.unifiedDefaultsKey) as? Bool, true)

        let reloaded = SelectionHistoryModel(defaults: defaults)
        XCTAssertTrue(reloaded.unified)
    }

    // MARK: - Git Test Helpers

    private func write(_ name: String, _ contents: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func commit(_ message: String, date: String) throws {
        try git("commit", "-q", "-m", message, environment: [
            "GIT_AUTHOR_DATE": date,
            "GIT_COMMITTER_DATE": date,
        ])
    }

    @discardableResult
    private func git(_ args: String..., environment: [String: String] = [:]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Git.executable)
        p.arguments = ["--no-pager"] + args
        p.currentDirectoryURL = root
        if !environment.isEmpty {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "SelectionHistoryTests", code: Int(p.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(decoding: errData, as: UTF8.self),
            ])
        }
        return String(decoding: data, as: UTF8.self)
    }
}
