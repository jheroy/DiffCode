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
    func testLSPIdleTimeoutDefaultsAndPersistence() throws {
        let suiteName = "KeymapTests.LSPIdle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertEqual(initial.lspIdleTimeout, .minutes15)
        XCTAssertEqual(Settings.LSPIdleTimeout.minutes5.duration, .seconds(300))
        XCTAssertEqual(Settings.LSPIdleTimeout.minutes15.duration, .seconds(900))
        XCTAssertEqual(Settings.LSPIdleTimeout.minutes30.duration, .seconds(1800))
        XCTAssertEqual(Settings.LSPIdleTimeout.hour1.duration, .seconds(3600))
        XCTAssertNil(Settings.LSPIdleTimeout.never.duration)

        for option in Settings.LSPIdleTimeout.allCases {
            initial.lspIdleTimeout = option
            initial.save()
            let reloaded = Settings(defaults: defaults)
            XCTAssertEqual(reloaded.lspIdleTimeout, option)
        }
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

    func testSymbolOccurrenceNavigatorMapHighlightsToSnapshotRespectsScope() {
        let diskLines = [
            "package demo",
            "func alpha() int {",
            "\tx := 1",
            "\ty := x + 2",
            "\treturn x + y",
            "}",
            "func beta() int {",
            "\tx := 10",
            "\treturn x",
            "}",
        ]
        let snapshotLines = [
            "package demo",
            "// added comment shifting lines",
            "func alpha() int {",
            "\tx := 99",
            "\ty := x + 2",
            "\treturn x + y",
            "}",
            "func beta() int {",
            "\tx := 10",
            "\treturn x",
            "}",
        ]
        // gopls only returned `x` inside `alpha()`, never `beta()`.
        let alphaHighlights = [
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 2, character: 1), end: LSPPosition(line: 2, character: 2)), kind: .write),
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 3, character: 6), end: LSPPosition(line: 3, character: 7)), kind: .read),
            LSPDocumentHighlight(range: LSPRange(start: LSPPosition(line: 4, character: 8), end: LSPPosition(line: 4, character: 9)), kind: .read),
        ]
        let mapped = SymbolOccurrenceNavigator.mapHighlightsToSnapshot(
            alphaHighlights,
            diskLines: diskLines,
            snapshotLines: snapshotLines,
            symbolName: "x",
            side: .left
        )
        XCTAssertEqual(mapped, [
            SearchMatch(side: .left, line: 3, range: 1..<2),
            SearchMatch(side: .left, line: 4, range: 6..<7),
            SearchMatch(side: .left, line: 5, range: 8..<9),
        ])
    }

    @MainActor
    func testViewerModelStepSymbolOccurrenceRespectsGoScopeAndNeverFallsBackOnErrorOrEmpty() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-keymap-lsp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let canonicalDir = LSPURI.canonicalFileURL(dir)
        let scriptURL = canonicalDir.appendingPathComponent("mock_scope_lsp.py")
        let fileURL = canonicalDir.appendingPathComponent("main.go")
        let source = """
        package main
        import "fmt"
        func alpha() int {
        \tx := 1
        \tif true {
        \t\tx := 2
        \t\t_ = x
        \t}
        \tfmt.Println(x)
        \treturn x
        }
        func beta() int {
        \tx := 10
        \treturn x
        }
        """
        try source.write(to: fileURL, atomically: true, encoding: .utf8)

        let mockScript = """
        #!/usr/bin/env python3
        import json, sys

        def send(msg):
            body = json.dumps(msg).encode("utf-8")
            header = f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("ascii")
            sys.stdout.buffer.write(header + body)
            sys.stdout.buffer.flush()

        def read_msg():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line in (b"\\r\\n", b"\\n"):
                    break
                if b":" in line:
                    k, v = line.decode("ascii").split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            length = int(headers.get("content-length", "0"))
            body = sys.stdin.buffer.read(length)
            return json.loads(body.decode("utf-8")) if body else None

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}
            if method == "initialize":
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "documentHighlightProvider": True,
                        }
                    },
                })
            elif method == "textDocument/documentHighlight":
                pos = params.get("position") or {}
                line = pos.get("line", 0)
                char = pos.get("character", 0)
                if line in (3, 8, 9) and char in (1, 13, 8):
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [
                            {"range": {"start": {"line": 3, "character": 1}, "end": {"line": 3, "character": 2}}, "kind": 3},
                            {"range": {"start": {"line": 8, "character": 13}, "end": {"line": 8, "character": 14}}, "kind": 2},
                            {"range": {"start": {"line": 9, "character": 8}, "end": {"line": 9, "character": 9}}, "kind": 2},
                        ],
                    })
                elif line == 8 and char in (1, 2, 3): # fmt -> returns `"fmt"` on line 1 (7..12) and `fmt` on line 8 (1..4)
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [
                            {"range": {"start": {"line": 1, "character": 7}, "end": {"line": 1, "character": 12}}, "kind": 1},
                            {"range": {"start": {"line": 8, "character": 1}, "end": {"line": 8, "character": 4}}, "kind": 2},
                        ],
                    })
                elif line == 12: # simulate busy/error
                    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32603, "message": "busy"}})
                else:
                    send({"jsonrpc": "2.0", "id": req_id, "result": []})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try mockScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let mockResolved = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(
            isEnabled: true,
            serverOverrides: [LSPServerRegistry.go.id: mockResolved]
        )

        let suiteName = "KeymapTests.LSPScope.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        settings.vimMode = true
        let viewer = ViewerModel()
        viewer.settings = settings
        viewer.lspManager = manager
        var toasts: [String] = []
        viewer.onToast = { toasts.append($0) }

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        container.layoutSubtreeIfNeeded()
        viewer.attach(container)

        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let doc = DiffDocument(left: TextBuffer(lines: lines), right: TextBuffer(lines: lines), hunks: [], language: .go, isPlainFile: true)
        viewer.request = DiffRequest(root: canonicalDir, path: "main.go", kind: nil, source: .file)
        viewer.document = doc
        container.show(doc, mode: .sideBySide, preserveScroll: false)
        viewer.syncLSPForCurrentDocument()

        // 1. Outer `x` (line 3, col 1) must cycle ONLY across lines 3, 8, 9 (never shadowed line 5/6 or beta's 12/13).
        container.canvas.placeCaret(line: 3, column: 1)
        viewer.stepSymbolOccurrence(forward: true)
        await viewer.symbolHighlightTask?.value
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 8, column: 13))
        XCTAssertEqual(container.canvas.matches.map(\.line), [3, 8, 9])

        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 9, column: 8))
        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 3, column: 1))

        // 2. Clamped column at upper edge of `fmt` (col 4 on `.` in `fmt.Println`) hits `fmt` and cycles onto `"fmt"` cleanly.
        container.canvas.placeCaret(line: 8, column: 4)
        viewer.stepSymbolOccurrence(forward: true)
        await viewer.symbolHighlightTask?.value
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 1, column: 7))
        viewer.stepSymbolOccurrence(forward: true)
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 8, column: 1))

        // 3. Empty `[]` from LSP (shadowed line 5) must NOT fall back to whole-word cross-scope matches.
        container.canvas.placeCaret(line: 5, column: 2)
        viewer.stepSymbolOccurrence(forward: true)
        await viewer.symbolHighlightTask?.value
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 5, column: 2))

        // 4. RPC failure (line 12) must NOT fall back to whole-word cross-scope matches and emits busy toast.
        container.canvas.placeCaret(line: 12, column: 1)
        viewer.stepSymbolOccurrence(forward: true)
        await viewer.symbolHighlightTask?.value
        XCTAssertEqual(container.canvas.activeCaretPosition(), TextPosition(row: 12, column: 1))
        XCTAssertFalse(toasts.isEmpty)

        await manager.shutdownAll()
    }
}
