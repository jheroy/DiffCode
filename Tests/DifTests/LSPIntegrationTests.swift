import AppKit
import Foundation
import XCTest
@testable import DifKit

final class LSPIntegrationTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(prefix: String = "dif-lsp-ui-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canonical = LSPURI.canonicalFileURL(dir)
        tempDirs.append(canonical)
        return canonical
    }

    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - 1. SyntaxOverlay.merge & 1:1 TokenKind Mapping

    func testSemanticTokenKindMatchesTokenKindOneToOne() {
        XCTAssertEqual(LSPSemanticTokenKind.allCases.count, TokenKind.allCases.count)
        for lspKind in LSPSemanticTokenKind.allCases {
            let mapped = TokenKind(rawValue: lspKind.rawValue)
            XCTAssertNotNil(mapped, "Missing TokenKind for rawValue \(lspKind.rawValue) (\(lspKind))")
            XCTAssertEqual(String(describing: mapped!), String(describing: lspKind))

            let span = LSPSemanticSpan(start: 2, length: 5, kind: lspKind)
            let converted = SyntaxOverlay.convert(span)
            XCTAssertEqual(converted, SyntaxSpan(start: 2, length: 5, kind: mapped!))
        }
    }

    func testSyntaxOverlayMergesSemanticOverLexerPreservingKeywordsStringsAndComments() {
        // Example line: `func foo(s string) { return "bar" } // foo`
        let base: [SyntaxSpan] = [
            SyntaxSpan(start: 0, length: 4, kind: .keyword),     // func
            SyntaxSpan(start: 5, length: 3, kind: .function),    // foo
            SyntaxSpan(start: 11, length: 6, kind: .builtin),    // string
            SyntaxSpan(start: 21, length: 6, kind: .keyword),    // return
            SyntaxSpan(start: 28, length: 5, kind: .string),     // "bar"
            SyntaxSpan(start: 36, length: 6, kind: .comment),    // // foo
        ]
        // Semantic tokens:
        // - `foo` -> .method (overrides Lexer .function)
        // - `s` -> .parameter (fills uncoloured identifier gap)
        // - bogus/overlapping .variable inside `"bar"` string and `// foo` comment (must be ignored!)
        let semantic: [LSPSemanticSpan] = [
            LSPSemanticSpan(start: 39, length: 3, kind: .variable),   // inside comment -> skipped
            LSPSemanticSpan(start: 29, length: 3, kind: .variable),   // inside string -> skipped
            LSPSemanticSpan(start: 9, length: 1, kind: .parameter),   // s
            LSPSemanticSpan(start: 5, length: 3, kind: .method),      // foo
        ]

        let merged = SyntaxOverlay.merge(base: base, semantic: semantic)

        XCTAssertEqual(merged, [
            SyntaxSpan(start: 0, length: 4, kind: .keyword),
            SyntaxSpan(start: 5, length: 3, kind: .method),
            SyntaxSpan(start: 9, length: 1, kind: .parameter),
            SyntaxSpan(start: 11, length: 6, kind: .builtin),
            SyntaxSpan(start: 21, length: 6, kind: .keyword),
            SyntaxSpan(start: 28, length: 5, kind: .string),
            SyntaxSpan(start: 36, length: 6, kind: .comment),
        ])
        assertSortedAndNonOverlapping(merged)
    }

    func testSyntaxOverlaySplitsPartiallyOverlappingBaseSpans() {
        let base: [SyntaxSpan] = [
            SyntaxSpan(start: 0, length: 10, kind: .variable),
            SyntaxSpan(start: 12, length: 8, kind: .type),
        ]
        let semantic: [LSPSemanticSpan] = [
            LSPSemanticSpan(start: 3, length: 4, kind: .property),   // splits [0,10) into [0,3), [3,7), [7,10)
            LSPSemanticSpan(start: 10, length: 5, kind: .namespace), // overlaps [12,15), leaving [15,20)
        ]

        let merged = SyntaxOverlay.merge(base: base, semantic: semantic)

        XCTAssertEqual(merged, [
            SyntaxSpan(start: 0, length: 3, kind: .variable),
            SyntaxSpan(start: 3, length: 4, kind: .property),
            SyntaxSpan(start: 7, length: 3, kind: .variable),
            SyntaxSpan(start: 10, length: 5, kind: .namespace),
            SyntaxSpan(start: 15, length: 5, kind: .type),
        ])
        assertSortedAndNonOverlapping(merged)
    }

    func testTextBufferApplySemanticTokensDoesNotCompoundAcrossRefreshes() {
        let lines = [
            "package main",
            "func greet(name string) {}",
        ]
        let buffer = TextBuffer(lines: lines)
        buffer.spans = Highlighter.highlight(lines, language: .go)
        let originalLine1 = buffer.spans(at: 1)

        // First semantic overlay colours `name` as .parameter
        let firstChanged = buffer.applySemanticTokens([
            1: [LSPSemanticSpan(start: 11, length: 4, kind: .parameter)],
        ])
        XCTAssertEqual(firstChanged, IndexSet(integer: 1))
        XCTAssertTrue(buffer.spans(at: 1).contains(SyntaxSpan(start: 11, length: 4, kind: .parameter)))

        // Applying identical semantic tokens again reports zero changed lines
        let noopChanged = buffer.applySemanticTokens([
            1: [LSPSemanticSpan(start: 11, length: 4, kind: .parameter)],
        ])
        XCTAssertTrue(noopChanged.isEmpty)

        // Subsequent empty semantic tokens cleanly revert to the preserved base Lexer spans
        let reverted = buffer.applySemanticTokens([:])
        XCTAssertEqual(reverted, IndexSet(integer: 1))
        XCTAssertEqual(buffer.spans(at: 1), originalLine1)
    }

    private func assertSortedAndNonOverlapping(_ spans: [SyntaxSpan], file: StaticString = #filePath, line: UInt = #line) {
        for i in 1..<spans.count {
            let prev = spans[i - 1]
            let curr = spans[i]
            XCTAssertLessThanOrEqual(prev.start + prev.length, curr.start,
                                     "Overlapping or unsorted spans: \(prev) followed by \(curr)",
                                     file: file, line: line)
        }
    }

    // MARK: - 2. JumpHistory

    func testJumpHistoryPushBackForwardAndClearingForward() {
        var history = JumpHistory(maxEntries: 10)
        XCTAssertFalse(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        let pA = UUID()
        let loc1 = JumpLocation(fileURL: URL(fileURLWithPath: "/tmp/a.go"), projectID: pA, relativePath: "a.go", line: 10, column: 4, isExternal: false)
        let loc2 = JumpLocation(fileURL: URL(fileURLWithPath: "/tmp/b.go"), projectID: pA, relativePath: "b.go", line: 20, column: 2, isExternal: false)
        let loc3 = JumpLocation(fileURL: URL(fileURLWithPath: "/tmp/c.go"), projectID: nil, relativePath: nil, line: 30, column: 0, isExternal: true)
        let loc4 = JumpLocation(fileURL: URL(fileURLWithPath: "/tmp/d.go"), projectID: pA, relativePath: "d.go", line: 40, column: 1, isExternal: false)

        // Jump loc1 -> loc2 -> loc3
        history.push(loc1)
        history.push(loc2)
        XCTAssertTrue(history.canGoBack)
        XCTAssertFalse(history.canGoForward)

        // Back from loc3 -> lands on loc2
        let back1 = history.back(from: loc3)
        XCTAssertEqual(back1?.line, 20)
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        // Back from loc2 -> lands on loc1
        let back2 = history.back(from: loc2)
        XCTAssertEqual(back2?.line, 10)
        XCTAssertFalse(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        // Forward from loc1 -> lands on loc2
        let fwd1 = history.forward(from: loc1)
        XCTAssertEqual(fwd1?.line, 20)
        XCTAssertTrue(history.canGoBack)
        XCTAssertTrue(history.canGoForward)

        // Pushing a new jump from loc2 clears forward stack
        history.push(loc4)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.backStack.count, 2)
        XCTAssertEqual(history.backStack.last?.line, 40)
    }

    func testJumpHistoryBoundsAndDeduplication() throws {
        let dir = try makeTempDir(prefix: "dif-jump-dedup")
        let file = dir.appendingPathComponent("main.go")
        try writeFile(file, contents: "package main\n")

        var history = JumpHistory(maxEntries: 3)

        // Duplicate consecutive push at same file & line deduplicates
        let a = JumpLocation(fileURL: file, projectID: nil, relativePath: nil, line: 5, column: 1, isExternal: false)
        let aSameLineDifferentCol = JumpLocation(fileURL: file, projectID: nil, relativePath: nil, line: 5, column: 9, isExternal: false)
        history.push(a)
        history.push(aSameLineDifferentCol)
        XCTAssertEqual(history.backStack.count, 1)
        XCTAssertEqual(history.backStack.last?.column, 9)

        // Exceeding maxEntries drops oldest entries
        for line in [10, 20, 30, 40] {
            history.push(JumpLocation(fileURL: file, projectID: nil, relativePath: nil, line: line, column: 0, isExternal: false))
        }
        XCTAssertEqual(history.backStack.map(\.line), [20, 30, 40])
    }

    // MARK: - 3. go.work Cross-Repo & External Read-Only Target Resolution

    func testGoWorkCrossRepoTargetResolution() throws {
        let root = try makeTempDir(prefix: "dif-gowork-nav")
        let repoA = root.appendingPathComponent("repoA", isDirectory: true)
        let repoB = root.appendingPathComponent("repoB", isDirectory: true)
        let repoC = root.appendingPathComponent("repoC", isDirectory: true)
        let stdlibDir = root.appendingPathComponent("goroot/src/fmt", isDirectory: true)

        try writeFile(root.appendingPathComponent("go.work"), contents: """
        go 1.22

        use (
            ./repoA
            ./repoB
            ./repoC
        )
        """)
        let fileA = repoA.appendingPathComponent("cmd/main.go")
        let fileAOther = repoA.appendingPathComponent("internal/helper.go")
        let fileB = repoB.appendingPathComponent("pkg/greet.go")
        let fileC = repoC.appendingPathComponent("lib/util.go")
        let fileStdlib = stdlibDir.appendingPathComponent("print.go")

        try writeFile(repoA.appendingPathComponent("go.mod"), contents: "module example.com/repoA\ngo 1.22\n")
        try writeFile(repoB.appendingPathComponent("go.mod"), contents: "module example.com/repoB\ngo 1.22\n")
        try writeFile(repoC.appendingPathComponent("go.mod"), contents: "module example.com/repoC\ngo 1.22\n")
        try writeFile(fileA, contents: "package main\n")
        try writeFile(fileAOther, contents: "package internal\n")
        try writeFile(fileB, contents: "package pkg\n")
        try writeFile(fileC, contents: "package lib\n")
        try writeFile(fileStdlib, contents: "package fmt\n")

        let idA = UUID()
        let idB = UUID()
        let refA = LSPTargetResolver.ProjectRef(id: idA, rootURL: repoA)
        let refB = LSPTargetResolver.ProjectRef(id: idB, rootURL: repoB)
        // Note: repoA and repoB are open in DiffCode; repoC is in go.work but NOT added to DiffCode.
        let openProjects = [refA, refB]

        func makeLoc(_ url: URL, line0: Int, col: Int = 5) -> LSPLocation {
            LSPLocation(
                uri: LSPURI.uri(from: url),
                range: LSPRange(
                    start: LSPPosition(line: line0, character: col),
                    end: LSPPosition(line: line0, character: col + 4)
                )
            )
        }

        // Case 1: Inside currently active project (repoA)
        let targetSame = LSPTargetResolver.resolve(
            location: makeLoc(fileAOther, line0: 14),
            originFileURL: fileA,
            originRepoRoot: repoA,
            activeProject: refA,
            openProjects: openProjects
        )
        XCTAssertEqual(targetSame, .activeProject(
            projectID: idA,
            relativePath: "internal/helper.go",
            fileURL: fileAOther,
            line: 15,
            column: 5
        ))

        // Case 2: Inside another open Project in AppStore.projects (repoB)
        let targetOther = LSPTargetResolver.resolve(
            location: makeLoc(fileB, line0: 7),
            originFileURL: fileA,
            originRepoRoot: repoA,
            activeProject: refA,
            openProjects: openProjects
        )
        XCTAssertEqual(targetOther, .otherProject(
            projectID: idB,
            relativePath: "pkg/greet.go",
            fileURL: fileB,
            line: 8,
            column: 5
        ))

        // Case 3a: Inside sibling go.work repo NOT in openProjects (repoC) -> external read-only with repoC/lib/util.go
        let targetSibling = LSPTargetResolver.resolve(
            location: makeLoc(fileC, line0: 21),
            originFileURL: fileA,
            originRepoRoot: repoA,
            activeProject: refA,
            openProjects: openProjects
        )
        XCTAssertEqual(targetSibling, .externalReadOnly(
            fileURL: fileC,
            repoRoot: repoC,
            workspaceRoot: root,
            displayPath: "repoC/lib/util.go",
            line: 22,
            column: 5
        ))

        // Case 3b: External stdlib file outside go.work -> external read-only preserving go.work workspaceRoot
        let targetStdlib = LSPTargetResolver.resolve(
            location: makeLoc(fileStdlib, line0: 99),
            originFileURL: fileA,
            originRepoRoot: repoA,
            activeProject: refA,
            openProjects: openProjects
        )
        guard case .externalReadOnly(let resolvedURL, _, let workspaceRoot, let displayPath, let line, let col) = targetStdlib else {
            return XCTFail("Expected externalReadOnly target, got \(String(describing: targetStdlib))")
        }
        XCTAssertEqual(resolvedURL, fileStdlib)
        XCTAssertEqual(workspaceRoot, root, "Should retain go.work root so chained jumps reuse running gopls")
        XCTAssertTrue(displayPath.hasSuffix("fmt/print.go"), "Unexpected displayPath: \(displayPath)")
        XCTAssertEqual(line, 100)
        XCTAssertEqual(col, 5)

        // pickBestLocation skips clicked origin when another target is available
        let originLoc = makeLoc(fileA, line0: 3)
        let picked = LSPTargetResolver.pickBestLocation(
            from: [originLoc, makeLoc(fileB, line0: 7)],
            originFileURL: fileA,
            originLine: 3
        )
        XCTAssertEqual(picked?.fileURL, fileB)
    }

    // MARK: - 4. Edition Gating (`Dif` vs `DifAppStore`)

    @MainActor
    func testAppEnvironmentHasLSPAndEditionGating() async throws {
        let originalEdition = AppEnvironment.edition
        defer { AppEnvironment.edition = originalEdition }

        // Direct edition
        AppEnvironment.edition = .direct
        XCTAssertTrue(AppEnvironment.hasLSP)
        XCTAssertEqual(AppEnvironment.hasLSP, AppEnvironment.hasTerminal)
        let directEnabled = await LSPManager.shared.isEffectivelyEnabled
        XCTAssertTrue(directEnabled)
        XCTAssertTrue(AppStore.shared.commands.contains { $0.id == "nav.back" })
        XCTAssertTrue(AppStore.shared.commands.contains { $0.id == "nav.forward" })

        // Mac App Store sandboxed edition
        AppEnvironment.edition = .appStore
        XCTAssertFalse(AppEnvironment.hasLSP)
        XCTAssertEqual(AppEnvironment.hasLSP, AppEnvironment.hasTerminal)
        let storeEnabled = await LSPManager.shared.isEffectivelyEnabled
        XCTAssertFalse(storeEnabled)
        XCTAssertFalse(AppStore.shared.commands.contains { $0.id == "nav.back" })
        XCTAssertFalse(AppStore.shared.commands.contains { $0.id == "nav.forward" })

        // Verify LSPManager.shared never opens documents or spawns servers in AppStore edition
        let dir = try makeTempDir(prefix: "dif-appstore-gate")
        let goFile = dir.appendingPathComponent("main.go")
        try writeFile(goFile, contents: "package main\nfunc main() {}\n")
        let session = await LSPManager.shared.didOpen(fileURL: goFile, text: "package main\n", language: .go, repoRoot: dir)
        XCTAssertNil(session)
        let running = await LSPManager.shared.runningServerCount()
        XCTAssertEqual(running, 0)
    }

    // MARK: - 5. Symbol Hit-Testing & External File Loader

    @MainActor
    func testSymbolRangeExcludesCommentsStringsKeywordsNumbersAndStructTags() {
        let line = #"func greet(count int) string { return "hello" } // greet 123"#
        let nsLine = line as NSString
        let spans = Highlighter.highlight([line], language: .go).first ?? []

        // `func` (keyword) -> nil
        XCTAssertNil(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: 1))
        // `greet` (function) -> 5..<10
        XCTAssertEqual(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: 6), 5..<10)
        // `count` (plain identifier) -> 11..<16
        XCTAssertEqual(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: 12), 11..<16)
        // `int` (builtin) -> 17..<20 (jumpable to builtin.go)
        XCTAssertEqual(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: 18), 17..<20)
        // `"hello"` (string) -> nil
        let helloIdx = nsLine.range(of: "hello").location
        XCTAssertNil(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: helloIdx))
        // `// greet` (comment) -> nil
        let commentIdx = nsLine.range(of: "// greet").location + 4
        XCTAssertNil(CodeCanvasView.symbolRange(in: nsLine, spans: spans, at: commentIdx))

        // Struct tag backtick annotation -> nil, while field type `string` -> eligible
        let structLine = #"    Name string `json:"name"`"#
        let nsStruct = structLine as NSString
        let structSpans = Highlighter.highlight([structLine], language: .go).first ?? []
        let nameIdx = nsStruct.range(of: "Name").location
        XCTAssertEqual(CodeCanvasView.symbolRange(in: nsStruct, spans: structSpans, at: nameIdx), nameIdx..<(nameIdx + 4))
        let jsonIdx = nsStruct.range(of: "json").location
        XCTAssertNil(CodeCanvasView.symbolRange(in: nsStruct, spans: structSpans, at: jsonIdx))
    }

    func testExternalReadOnlyFileLoadsWithoutEditingAndSupportsLSP() async throws {
        let dir = try makeTempDir(prefix: "dif-ext-file")
        let file = dir.appendingPathComponent("greet.go")
        try writeFile(file, contents: "package greet\n\nfunc Hello() string { return \"hi\" }\n")

        let request = DiffRequest(
            root: dir,
            path: "greet.go",
            oldPath: nil,
            kind: nil,
            source: .externalFile(displayPath: "repoB/greet.go", workspaceRoot: dir)
        )
        XCTAssertTrue(request.isExternalFile)
        XCTAssertTrue(request.isLiveFile)
        XCTAssertEqual(request.displayPath, "repoB/greet.go")
        XCTAssertEqual(request.lspRepoRoot, dir)

        let doc = await DiffLoader.load(request)
        XCTAssertTrue(doc.isPlainFile)
        XCTAssertNotNil(doc.editing?.readOnlyReason)
        // Read-only external file must refuse EditorSession creation
        XCTAssertNil(EditorSession(document: doc, root: dir, path: "greet.go", ignoreWhitespace: false))
        XCTAssertEqual(doc.right.lines.count, 3)
    }

    @MainActor
    func testCanvasInvalidateSyntaxPreservesScrollSelectionAndCaret() {
        let lines = (0..<40).map { "var item\($0) = compute(\($0))" }
        let buf = TextBuffer(lines: lines)
        buf.spans = Highlighter.highlight(lines, language: .go)
        let doc = DiffDocument(left: .empty, right: buf, hunks: [], language: .go, isPlainFile: true)

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        container.layoutSubtreeIfNeeded()
        container.show(doc, mode: .single, preserveScroll: false)
        container.scroll(toRow: 15, fraction: 0.2, animated: false)
        container.canvas.flush()

        let sel = TextSelection(
            pane: .right,
            anchor: TextPosition(row: 16, column: 4),
            head: TextPosition(row: 16, column: 10)
        )
        container.canvas.selection = sel
        let scrollBefore = container.canvas.scrollOrigin

        let changed = doc.right.applySemanticTokens([
            16: [LSPSemanticSpan(start: 4, length: 6, kind: .variable)],
        ])
        XCTAssertEqual(changed, IndexSet(integer: 16))

        container.canvas.invalidateSyntax(side: .right, lines: changed)
        container.canvas.flush()

        XCTAssertEqual(container.canvas.scrollOrigin, scrollBefore)
        XCTAssertEqual(container.canvas.selection, sel)
    }

    @MainActor
    func testCanvasLSPSymbolTargetOnlyActiveOnRightLivePane() {
        let leftLines = ["func oldFunc() {}"]
        let rightLines = ["func newFunc() {}"]
        let leftBuf = TextBuffer(lines: leftLines)
        leftBuf.spans = Highlighter.highlight(leftLines, language: .go)
        let rightBuf = TextBuffer(lines: rightLines)
        rightBuf.spans = Highlighter.highlight(rightLines, language: .go)
        let hunks = [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)]
        let doc = DiffDocument(left: leftBuf, right: rightBuf, hunks: hunks, language: .go, isPlainFile: false)

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 240))
        container.layoutSubtreeIfNeeded()
        container.show(doc, mode: .sideBySide, preserveScroll: false)
        container.canvas.flush()

        let lh = container.canvas.codeFont.lineHeight
        let cw = container.canvas.codeFont.charWidth
        let y = lh * 0.5

        // Left pane click point over `oldFunc`
        let leftPoint = CGPoint(x: container.canvas.textInset + cw * 6, y: y)
        // Right pane click point over `newFunc`
        let rightX = container.canvas.viewRect(line: 0, from: 5, to: 12).midX
        let rightPoint = CGPoint(x: rightX, y: y)

        // Disabled -> neither pane hits
        container.canvas.isLSPEnabled = false
        XCTAssertNil(container.canvas.lspSymbolTarget(at: leftPoint))
        XCTAssertNil(container.canvas.lspSymbolTarget(at: rightPoint))

        // Enabled in side-by-side -> ONLY right pane hits, left pane (HEAD) stays nil
        container.canvas.isLSPEnabled = true
        XCTAssertNil(container.canvas.lspSymbolTarget(at: leftPoint))
        let hit = container.canvas.lspSymbolTarget(at: rightPoint)
        XCTAssertEqual(hit?.line, 0)
        XCTAssertEqual(hit?.range, 5..<12)

        // Enabled in unified mode -> row 0 is removed (HEAD) -> nil; row 1 is added (working tree) -> hits!
        container.setMode(.unified)
        container.canvas.flush()
        let unifiedX = container.canvas.viewRect(line: 0, from: 5, to: 12).midX
        XCTAssertNil(container.canvas.lspSymbolTarget(at: CGPoint(x: unifiedX, y: lh * 0.5)),
                     "Removed HEAD line in unified mode must not be LSP-clickable")
        let unifiedHit = container.canvas.lspSymbolTarget(at: CGPoint(x: unifiedX, y: lh * 1.5))
        XCTAssertEqual(unifiedHit?.line, 0)
        XCTAssertEqual(unifiedHit?.range, 5..<12)
    }

    @MainActor
    func testDiffRequestLiveFileEligibility() {
        let root = URL(fileURLWithPath: "/tmp/repo")
        let plain = DiffRequest(root: root, path: "main.go", oldPath: nil, kind: nil, source: .file)
        let wtModified = DiffRequest(root: root, path: "main.go", oldPath: nil, kind: .modified, source: .worktree(base: "HEAD"))
        let wtDeleted = DiffRequest(root: root, path: "main.go", oldPath: nil, kind: .deleted, source: .worktree(base: "HEAD"))
        let commitDiff = DiffRequest(root: root, path: "main.go", oldPath: nil, kind: .modified, source: .commit(hash: "abc", parent: "def"))
        let external = DiffRequest(root: root, path: "greet.go", oldPath: nil, kind: nil, source: .externalFile(displayPath: "repoB/greet.go", workspaceRoot: root))

        XCTAssertTrue(plain.isLiveFile)
        XCTAssertTrue(wtModified.isLiveFile)
        XCTAssertFalse(wtDeleted.isLiveFile)
        XCTAssertFalse(commitDiff.isLiveFile)
        XCTAssertTrue(external.isLiveFile)
    }

    // MARK: - 6. Concurrency & Ordering Regression Tests

    private func makeMockLSPServer(in dir: URL, initDelaySeconds: Double, logFile: URL) throws -> LSPResolvedServer {
        let script = dir.appendingPathComponent("mock-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, os, sys, time

        LOG_PATH = \(String(reflecting: logFile.path))
        INIT_DELAY = \(initDelaySeconds)

        def log(entry):
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(entry + "\\n")
                f.flush()

        def read_msg():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line in (b"\\r\\n", b"\\n"):
                    break
                k, _, v = line.decode("utf-8", "replace").partition(":")
                headers[k.strip().lower()] = v.strip()
            n = int(headers.get("content-length", "0"))
            if n <= 0:
                return None
            body = sys.stdin.buffer.read(n)
            return json.loads(body.decode("utf-8"))

        def send_msg(obj):
            raw = json.dumps(obj).encode("utf-8")
            sys.stdout.buffer.write(f"Content-Length: {len(raw)}\\r\\n\\r\\n".encode("ascii") + raw)
            sys.stdout.buffer.flush()

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            msg_id = msg.get("id")
            params = msg.get("params") or {}
            if method == "initialize":
                if INIT_DELAY > 0:
                    time.sleep(INIT_DELAY)
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "definitionProvider": True,
                            "semanticTokensProvider": {
                                "legend": {
                                    "tokenTypes": ["function", "variable", "parameter"],
                                    "tokenModifiers": []
                                },
                                "full": True
                            }
                        }
                    }
                })
            elif method == "textDocument/didOpen":
                uri = params.get("textDocument", {}).get("uri", "")
                log(f"didOpen:{uri}")
            elif method == "textDocument/didClose":
                uri = params.get("textDocument", {}).get("uri", "")
                log(f"didClose:{uri}")
            elif method == "textDocument/semanticTokens/full":
                # Emit one token on line 0, col 5, len 4, type 0 (function)
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": {"data": [0, 5, 4, 0, 0]}})
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
    }

    func testLSPManagerColdStartConcurrentOpenAndCancellation() async throws {
        let dir = try makeTempDir(prefix: "dif-lsp-coldstart")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let logFile = dir.appendingPathComponent("events.log")
        let file1 = repo.appendingPathComponent("a.go")
        let file2 = repo.appendingPathComponent("b.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(file1, contents: "package repo\nfunc Alpha() {}\n")
        try writeFile(file2, contents: "package repo\nfunc Beta() {}\n")

        let server = try makeMockLSPServer(in: dir, initDelaySeconds: 0.15, logFile: logFile)
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])
        defer { Task { await manager.shutdownAll() } }

        // Start cold initialization with file1, then join with file2 and cancel file1 mid-initialize.
        let task1 = Task {
            await manager.didOpen(fileURL: file1, text: "package repo\nfunc Alpha() {}\n", language: .go, repoRoot: repo)
        }
        try await Task.sleep(for: .milliseconds(30))
        let task2 = Task {
            await manager.didOpen(fileURL: file2, text: "package repo\nfunc Beta() {}\n", language: .go, repoRoot: repo)
        }
        try await Task.sleep(for: .milliseconds(15))
        task1.cancel()

        _ = await task1.value
        let session2 = await task2.value

        XCTAssertNotNil(session2, "file2 must receive an active session even when file1 started initialization and was cancelled")
        let count = await manager.runningServerCount()
        XCTAssertEqual(count, 1)
        let open1 = await manager.openSession(forURI: LSPURI.uri(from: file1))
        let open2 = await manager.openSession(forURI: LSPURI.uri(from: file2))
        XCTAssertNil(open1, "Cancelled file1 open must not register a stale session")
        XCTAssertNotNil(open2, "file2 must remain registered in servers[key].openDocuments")

        let tokens2 = await manager.semanticTokens(fileURL: file2)
        XCTAssertEqual(tokens2?[0]?.first?.kind, .function)

        await manager.shutdownAll()
    }

    func testLSPManagerShutdownDuringColdStartDoesNotLeakServer() async throws {
        let dir = try makeTempDir(prefix: "dif-lsp-shutdown-race")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let logFile = dir.appendingPathComponent("events.log")
        let file1 = repo.appendingPathComponent("a.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(file1, contents: "package repo\n")

        let server = try makeMockLSPServer(in: dir, initDelaySeconds: 0.15, logFile: logFile)
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])

        let openTask = Task {
            await manager.didOpen(fileURL: file1, text: "package repo\n", language: .go, repoRoot: repo)
        }
        try await Task.sleep(for: .milliseconds(30))
        await manager.shutdownAll()
        _ = await openTask.value

        let count = await manager.runningServerCount()
        XCTAssertEqual(count, 0, "Server completing initialize during shutdownAll must not leak into servers")
        let session = await manager.openSession(forURI: LSPURI.uri(from: file1))
        XCTAssertNil(session)
    }

    @MainActor
    func testViewerLSPRapidSwitchBackSerializesCloseBeforeReopen() async throws {
        let dir = try makeTempDir(prefix: "dif-lsp-rapid-switch")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let logFile = dir.appendingPathComponent("events.log")
        let fileA = repo.appendingPathComponent("a.go")
        let fileB = repo.appendingPathComponent("b.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(fileA, contents: "func work() {}\n")
        try writeFile(fileB, contents: "func peer() {}\n")

        let server = try makeMockLSPServer(in: dir, initDelaySeconds: 0.0, logFile: logFile)
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])

        let viewer = ViewerModel()
        viewer.settings = Settings.shared
        viewer.lspManager = manager

        let reqA = DiffRequest(root: repo, path: "a.go", oldPath: nil, kind: nil, source: .file)
        let reqB = DiffRequest(root: repo, path: "b.go", oldPath: nil, kind: nil, source: .file)
        let docA1 = await DiffLoader.load(reqA)
        let docB = await DiffLoader.load(reqB)
        let docA2 = await DiffLoader.load(reqA)

        // Open A and wait for server startup & initial open
        viewer.request = reqA
        viewer.document = docA1
        viewer.syncLSPForCurrentDocument()
        await viewer.lspTask?.value

        // Rapidly switch A -> B -> A without awaiting in between (simulates jump + immediate ⌘[)
        viewer.request = reqB
        viewer.document = docB
        viewer.syncLSPForCurrentDocument()

        viewer.request = reqA
        viewer.document = docA2
        viewer.syncLSPForCurrentDocument()
        await viewer.lspTask?.value

        let uriA = LSPURI.uri(from: fileA)
        let sessionA = await manager.openSession(forURI: uriA)
        XCTAssertNotNil(sessionA, "a.go must remain open after rapid A -> B -> A switch")
        XCTAssertTrue(docA2.right.spans(at: 0).contains(SyntaxSpan(start: 5, length: 4, kind: .function)),
                      "Semantic tokens must still be applied to a.go after rapid switch back")

        let events = (try? String(contentsOf: logFile, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        let aEvents = events.filter { $0.hasSuffix(uriA) }
        XCTAssertEqual(aEvents.last, "didOpen:\(uriA)", "Final lifecycle event for a.go must be didOpen, got: \(aEvents)")

        await manager.shutdownAll()
    }

    func testSingleModuleGoExternalTargetReusesOriginWorkspaceRoot() throws {
        let dir = try makeTempDir(prefix: "dif-single-mod-ext")
        let repo = dir.appendingPathComponent("myapp", isDirectory: true)
        let gorootSrc = dir.appendingPathComponent("goroot/src", isDirectory: true)
        let mainFile = repo.appendingPathComponent("main.go")
        let stdlibFile = gorootSrc.appendingPathComponent("fmt/print.go")

        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/myapp\ngo 1.22\n")
        try writeFile(mainFile, contents: "package main\n")
        // Real $GOROOT/src has its own go.mod
        try writeFile(gorootSrc.appendingPathComponent("go.mod"), contents: "module std\ngo 1.22\n")
        try writeFile(stdlibFile, contents: "package fmt\n")

        let ref = LSPTargetResolver.ProjectRef(id: UUID(), rootURL: repo)
        let loc = LSPLocation(
            uri: LSPURI.uri(from: stdlibFile),
            range: LSPRange(start: LSPPosition(line: 0, character: 0), end: LSPPosition(line: 0, character: 7))
        )

        let target = LSPTargetResolver.resolve(
            location: loc,
            originFileURL: mainFile,
            originRepoRoot: repo,
            activeProject: ref,
            openProjects: [ref]
        )
        guard case .externalReadOnly(_, _, let workspaceRoot, _, _, _) = target else {
            return XCTFail("Expected externalReadOnly target")
        }
        XCTAssertEqual(workspaceRoot, repo, "Single-module Go repo must keep origin workspaceRoot for $GOROOT/pkg/mod")
        XCTAssertEqual(
            GoWorkspaceResolver.workspaceRoot(for: stdlibFile, repoRoot: workspaceRoot),
            repo,
            "GoWorkspaceResolver must stay on origin module root so gopls is reused"
        )
    }
}
