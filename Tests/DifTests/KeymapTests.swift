import AppKit
import XCTest
@testable import DifKit

final class KeymapTests: XCTestCase {
    private struct ShortcutKey: Hashable {
        let key: String
        let modifiers: UInt
    }

    @MainActor
    func testVimSettingsDefaultsAndPersistence() throws {
        let suiteName = "KeymapTests.Vim.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertTrue(initial.vimMode, "vimMode should default to true")
        XCTAssertFalse(initial.vimRelativeLineNumbers, "vimRelativeLineNumbers should default to false")

        initial.vimMode = false
        initial.vimRelativeLineNumbers = true
        initial.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.vimMode)
        XCTAssertTrue(reloaded.vimRelativeLineNumbers)

        reloaded.vimMode = true
        reloaded.vimRelativeLineNumbers = false
        reloaded.save()

        let reloadedAgain = Settings(defaults: defaults)
        XCTAssertTrue(reloadedAgain.vimMode)
        XCTAssertFalse(reloadedAgain.vimRelativeLineNumbers)
    }

    @MainActor
    func testGoLandKeymapBindingsMatchMacOSCopy() {
        let commands = AppStore.shared.commands
        func command(_ id: String) -> AppCommand? {
            commands.first { $0.id == id }
        }

        let goToFile = command("nav.file")
        XCTAssertEqual(goToFile?.key, "p")
        XCTAssertEqual(goToFile?.modifiers, .command)

        let findInPath = command("nav.findInPath")
        XCTAssertEqual(findInPath?.key, "f")
        XCTAssertEqual(findInPath?.modifiers, .command)

        let fileSymbols = command("nav.fileSymbols")
        XCTAssertEqual(fileSymbols?.key, "r")
        XCTAssertEqual(fileSymbols?.modifiers, .command)

        let gitRefresh = command("git.refresh")
        XCTAssertNotNil(gitRefresh)
        XCTAssertTrue(gitRefresh?.key.isEmpty == true, "git.refresh should not collide with ⌘R (File Structure)")

        let terminal = command("view.terminal")
        XCTAssertEqual(terminal?.key, "t")
        XCTAssertEqual(terminal?.modifiers, .command)

        let listToggle = command("view.list")
        XCTAssertEqual(listToggle?.key, "k")
        XCTAssertEqual(listToggle?.modifiers, .command)

        let historySelection = command("git.historySelection")
        XCTAssertEqual(historySelection?.key, "b")
        XCTAssertEqual(historySelection?.modifiers, .command)

        let commit = command("git.commit")
        XCTAssertEqual(commit?.key, "c")
        XCTAssertEqual(commit?.modifiers, [.shift, .control, .option])

        let back = command("nav.back")
        XCTAssertEqual(back?.key, "[")
        XCTAssertEqual(back?.modifiers, .command)

        let forward = command("nav.forward")
        XCTAssertEqual(forward?.key, "]")
        XCTAssertEqual(forward?.modifiers, .command)

        let findAction = command("nav.action")
        XCTAssertEqual(findAction?.key, "a")
        XCTAssertEqual(findAction?.modifiers, [.command, .shift])

        let nextSplitter = command("nav.nextSplitter")
        XCTAssertEqual(nextSplitter?.key, "l")
        XCTAssertEqual(nextSplitter?.modifiers, .command)

        let prevSplitter = command("nav.prevSplitter")
        XCTAssertEqual(prevSplitter?.key, "h")
        XCTAssertEqual(prevSplitter?.modifiers, .command)

        let goToLine = command("nav.line")
        XCTAssertNotNil(goToLine)
        XCTAssertTrue(goToLine?.key.isEmpty == true, "nav.line should not collide with ⌘L (NextSplitter)")

        let newTerminal = command("term.new")
        XCTAssertNotNil(newTerminal)
        XCTAssertTrue(newTerminal?.key.isEmpty == true, "term.new should not collide with ⌘T (Toggle Terminal)")

        let toggleVim = command("view.vimMode")
        XCTAssertEqual(toggleVim?.group, .view)
    }

    @MainActor
    func testNoDuplicateShortcutsAcrossCommandsAndStandardMenus() {
        let commands = AppStore.shared.commands
        var seen: [ShortcutKey: String] = [:]

        for cmd in commands where !cmd.key.isEmpty {
            let shortcut = ShortcutKey(
                key: cmd.key.lowercased(),
                modifiers: cmd.modifiers.intersection([.command, .option, .control, .shift]).rawValue
            )
            if let existing = seen[shortcut] {
                XCTFail("Duplicate shortcut (\(cmd.shortcut)) between '\(existing)' and '\(cmd.id)'")
            }
            seen[shortcut] = cmd.id
        }

        // Standard menu items built in AppDelegate.buildMenu()
        let standardMenuItems: [(id: String, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("app.settings", ",", .command),
            ("app.hideOthers", "h", [.command, .option]),
            ("app.quit", "q", .command),
            ("edit.undo", "z", .command),
            ("edit.redo", "z", [.command, .shift]),
            ("edit.cut", "x", .command),
            ("edit.copy", "c", .command),
            ("edit.paste", "v", .command),
            ("edit.selectAll", "a", .command),
            ("edit.expandSelection", ".", .command),
            ("edit.shrinkSelection", ";", .command),
            ("edit.find", "f", [.control, .shift, .command]),
            ("edit.findNext", "g", .command),
            ("edit.findPrevious", "g", [.command, .shift]),
            ("navigate.nextChange", "\u{F701}", [.control, .option, .shift]),
            ("navigate.prevChange", "\u{F700}", [.control, .option, .shift]),
            ("window.minimize", "m", .command),
            ("window.fullScreen", "f", [.command, .control]),
            ("window.close", "w", .command),
        ]

        for item in standardMenuItems {
            let shortcut = ShortcutKey(
                key: item.key.lowercased(),
                modifiers: item.modifiers.intersection([.command, .option, .control, .shift]).rawValue
            )
            if let existing = seen[shortcut] {
                XCTFail("Menu item '\(item.id)' collides with '\(existing)'")
            }
            seen[shortcut] = item.id
        }
    }

    @MainActor
    func testToggleVimModeCommandFlipsSetting() {
        let store = AppStore.shared
        let original = store.settings.vimMode
        defer {
            store.viewer.setVimMode(original)
        }

        guard let cmd = store.commands.first(where: { $0.id == "view.vimMode" }) else {
            return XCTFail("Missing view.vimMode command")
        }
        cmd.action()
        XCTAssertEqual(store.settings.vimMode, !original)
        XCTAssertEqual(store.viewer.vimModeEnabled, !original)
        cmd.action()
        XCTAssertEqual(store.settings.vimMode, original)
        XCTAssertEqual(store.viewer.vimModeEnabled, original)
    }

    @MainActor
    func testViewerModelSyncsVimSettingsLive() throws {
        let suiteName = "KeymapTests.ViewerVimSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.vimMode = false
        settings.vimRelativeLineNumbers = true

        let viewer = ViewerModel()
        viewer.settings = settings
        XCTAssertFalse(viewer.vimModeEnabled)
        XCTAssertTrue(viewer.vimRelativeLineNumbers)

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        viewer.attach(container)
        XCTAssertFalse(container.canvas.vimModeEnabled)
        XCTAssertTrue(container.canvas.vimRelativeLineNumbers)

        viewer.setVimMode(true)
        XCTAssertTrue(settings.vimMode)
        XCTAssertTrue(viewer.vimModeEnabled)
        XCTAssertTrue(container.canvas.vimModeEnabled)

        viewer.setVimRelativeLineNumbers(false)
        XCTAssertFalse(settings.vimRelativeLineNumbers)
        XCTAssertFalse(viewer.vimRelativeLineNumbers)
        XCTAssertFalse(container.canvas.vimRelativeLineNumbers)
    }

    func testSymbolOccurrenceNavigatorWholeWordAndStepping() {
        let lines = [
            "let id = 1",
            "let windowId = valid + ID + id",
            "return id",
        ]
        let occurrences = SymbolOccurrenceNavigator.wholeWordOccurrences(of: "id", in: lines)
        XCTAssertEqual(occurrences, [
            SearchMatch(side: .right, line: 0, range: 4..<6),
            SearchMatch(side: .right, line: 1, range: 28..<30),
            SearchMatch(side: .right, line: 2, range: 7..<9),
        ])

        // Forward and backward stepping from inside a token and from its end boundary, with wrap-around.
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 0, column: 5, forward: true), 1)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 0, column: 6, forward: true), 1)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 2, column: 7, forward: true), 0)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 0, column: 4, forward: false), 2)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 1, column: 28, forward: false), 0)

        // Between tokens
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 1, column: 10, forward: true), 1)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: occurrences, fromLine: 1, column: 10, forward: false), 0)

        // Single-occurrence wraps onto itself
        let single = [SearchMatch(side: .right, line: 0, range: 4..<6)]
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: single, fromLine: 0, column: 4, forward: true), 0)
        XCTAssertEqual(SymbolOccurrenceNavigator.targetIndex(in: single, fromLine: 0, column: 4, forward: false), 0)

        // LSP highlight filtering, clamping, sorting, and deduplication
        let lsp = [
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 2, character: 7), end: LSPPosition(line: 2, character: 99)), kind: .read),
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 0, character: 4), end: LSPPosition(line: 0, character: 6)), kind: .write),
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 0, character: 4), end: LSPPosition(line: 0, character: 6)), kind: .text),
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 1, character: 3)), kind: .text),
        ]
        let converted = SymbolOccurrenceNavigator.matches(from: lsp, in: lines)
        XCTAssertEqual(converted, [
            SearchMatch(side: .right, line: 0, range: 4..<6),
            SearchMatch(side: .right, line: 2, range: 7..<9),
        ])
    }

    @MainActor
    func testViewerModelStepSymbolOccurrenceMovesCaretWrapsAndPreservesFindQuery() throws {
        let suiteName = "KeymapTests.SymbolStep.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.vimMode = true
        let viewer = ViewerModel()
        viewer.settings = settings
        viewer.findQuery = "existingFind"

        var recordedJumps: [(Int, Int)] = []
        viewer.onRecordJump = { line, col in recordedJumps.append((line, col)) }

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        container.layoutSubtreeIfNeeded()
        viewer.attach(container)

        let lines = [
            "func demo() {",
            "    let count = 1",
            "    let counter = count + 2",
            "    print(count)",
            "}",
        ]
        let doc = DiffDocument(left: TextBuffer(lines: lines), right: TextBuffer(lines: lines), hunks: [], language: .swift, isPlainFile: true)
        viewer.document = doc
        container.show(doc, mode: .sideBySide, preserveScroll: false)
        container.canvas.placeCaret(line: 1, column: 9) // inside `count`

        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 2, column: 18))
        XCTAssertEqual(container.canvas.matches.count, 3)
        XCTAssertEqual(container.canvas.currentMatch, 1)
        XCTAssertEqual(viewer.findQuery, "existingFind")
        XCTAssertEqual(recordedJumps.count, 1)

        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 3, column: 10))
        XCTAssertEqual(container.canvas.currentMatch, 2)

        // Wrap forward to first occurrence
        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 1, column: 8))
        XCTAssertEqual(container.canvas.currentMatch, 0)

        // Wrap backward to last occurrence
        viewer.stepSymbolOccurrence(forward: false)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 3, column: 10))
        XCTAssertEqual(container.canvas.currentMatch, 2)
    }

    @MainActor
    func testClickHunkSelectsFocusedHunkAndContinuesSteppingFromClickedHunk() throws {
        let suiteName = "KeymapTests.ClickHunk.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        let viewer = ViewerModel()
        viewer.settings = settings

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        container.layoutSubtreeIfNeeded()
        viewer.attach(container)

        let left = TextBuffer(lines: [
            "same0",
            "old1",
            "deleted2",
            "same3",
            "old4",
            "same5",
            "old6",
        ])
        let right = TextBuffer(lines: [
            "same0",
            "new1",
            "same3",
            "new4",
            "same5",
            "new6",
        ])
        // Hunk 0: modified line 1; Hunk 1: adjacent pure deletion at left line 2; Hunk 2: modified at left 4/right 3; Hunk 3: modified at left 6/right 5.
        let hunks = [
            Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1),
            Hunk(leftStart: 2, leftCount: 1, rightStart: 2, rightCount: 0),
            Hunk(leftStart: 4, leftCount: 1, rightStart: 3, rightCount: 1),
            Hunk(leftStart: 6, leftCount: 1, rightStart: 5, rightCount: 1),
        ]
        let doc = DiffDocument(left: left, right: right, hunks: hunks, language: .swift)
        viewer.document = doc
        viewer.hunkCount = hunks.count
        container.show(doc, mode: .sideBySide, preserveScroll: false)
        container.layoutSubtreeIfNeeded()

        let lh = container.canvas.codeFont.lineHeight
        // Side-by-side at scrollOrigin=0: left pane x=60 (line 2 is hunk 1), right pane x=600 (line 1 is hunk 0, line 3 is hunk 2, line 5 is hunk 3).
        XCTAssertEqual(container.canvas.hunkIndex(at: CGPoint(x: 600, y: 1.5 * lh)), 0)
        XCTAssertEqual(container.canvas.hunkIndex(at: CGPoint(x: 60, y: 2.5 * lh)), 1)
        XCTAssertEqual(container.canvas.hunkIndex(at: CGPoint(x: 600, y: 3.5 * lh)), 2)
        XCTAssertEqual(container.canvas.hunkIndex(at: CGPoint(x: 600, y: 5.5 * lh)), 3)
        XCTAssertNil(container.canvas.hunkIndex(at: CGPoint(x: 600, y: 0.5 * lh)))

        // Simulate scrolling/detaching, then clicking hunk 2 -> focusedHunk becomes 2 and next/prev step from 2.
        viewer.reveal(line: 1)
        viewer.canvas(container.canvas, didSelectHunk: 2)
        XCTAssertEqual(viewer.focusedHunk, 2)
        XCTAssertEqual(container.canvas.focusedHunk, 2)

        viewer.stepDifference(1)
        XCTAssertEqual(viewer.focusedHunk, 3)

        viewer.canvas(container.canvas, didSelectHunk: 2)
        viewer.stepDifference(-1)
        XCTAssertEqual(viewer.focusedHunk, 1)

        // Unified mode hit testing
        container.setMode(.unified)
        container.layoutSubtreeIfNeeded()
        let hunk2Row = container.canvas.hunkRow(2)
        XCTAssertEqual(container.canvas.hunkIndex(at: CGPoint(x: 200, y: (CGFloat(hunk2Row) + 0.5) * lh)), 2)
    }
}
