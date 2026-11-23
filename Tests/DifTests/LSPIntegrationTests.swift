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
            "func greet(name string) {",
            "    msg := name",
            "}",
        ]
        let buffer = TextBuffer(lines: lines)
        buffer.spans = Highlighter.highlight(lines, language: .go)
        let originalLine2 = buffer.spans(at: 2)

        // First semantic overlay colours body identifier `msg` as .variable
        let firstChanged = buffer.applySemanticTokens([
            2: [LSPSemanticSpan(start: 4, length: 3, kind: .variable)],
        ])
        XCTAssertEqual(firstChanged, IndexSet(integer: 2))
        XCTAssertTrue(buffer.spans(at: 2).contains(SyntaxSpan(start: 4, length: 3, kind: .variable)))

        // Applying identical semantic tokens again reports zero changed lines
        let noopChanged = buffer.applySemanticTokens([
            2: [LSPSemanticSpan(start: 4, length: 3, kind: .variable)],
        ])
        XCTAssertTrue(noopChanged.isEmpty)

        // Subsequent empty semantic tokens cleanly revert to the preserved base Lexer spans
        let reverted = buffer.applySemanticTokens([:])
        XCTAssertEqual(reverted, IndexSet(integer: 2))
        XCTAssertEqual(buffer.spans(at: 2), originalLine2)
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

    // MARK: - 7. Smart ⌘+Click Definition Detection & References Picker Model

    func testIsPositionOnDefinitionMatchingAndNonMatchingCases() throws {
        let dir = try makeTempDir(prefix: "dif-pos-def")
        let fileA = dir.appendingPathComponent("greet.go")
        let fileB = dir.appendingPathComponent("main.go")
        try writeFile(fileA, contents: "package repob\nfunc Greet() { Greet() }\n")
        try writeFile(fileB, contents: "package main\nfunc main() { Greet() }\n")

        let defLoc = LSPLocation(
            uri: LSPURI.uri(from: fileA),
            range: LSPRange(
                start: LSPPosition(line: 1, character: 5),
                end: LSPPosition(line: 1, character: 10)
            )
        )

        // Clicking start, middle, or end of the definition symbol -> true
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(fileURL: fileA, line: 1, character: 5, definitions: [defLoc]))
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(fileURL: fileA, line: 1, character: 7, definitions: [defLoc]))
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(fileURL: fileA, line: 1, character: 10, definitions: [defLoc]))

        // Clicking a recursive call on the SAME line (`Greet()` at col 15..<20) -> false
        XCTAssertFalse(LSPNavigationHelper.isPositionOnDefinition(
            fileURL: fileA, line: 1, character: 17, symbolRange: 15..<20, definitions: [defLoc]
        ))

        // Clicking a reference on a different line in the same file -> false
        XCTAssertFalse(LSPNavigationHelper.isPositionOnDefinition(fileURL: fileA, line: 4, character: 7, definitions: [defLoc]))

        // Clicking same line & column in a different file -> false
        XCTAssertFalse(LSPNavigationHelper.isPositionOnDefinition(fileURL: fileB, line: 1, character: 7, definitions: [defLoc]))

        // Non-canonical path (`dir/./greet.go`) matches canonical definition URL -> true
        let nonCanonical = dir.appendingPathComponent("./greet.go")
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(fileURL: nonCanonical, line: 1, character: 6, definitions: [defLoc]))

        // Zero-width definition range matches exact character or covering symbolRange
        let zeroWidthDef = LSPLocation(
            uri: LSPURI.uri(from: fileA),
            range: LSPRange(
                start: LSPPosition(line: 1, character: 5),
                end: LSPPosition(line: 1, character: 5)
            )
        )
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(
            fileURL: fileA, line: 1, character: 5, definitions: [zeroWidthDef]
        ))
        XCTAssertTrue(LSPNavigationHelper.isPositionOnDefinition(
            fileURL: fileA, line: 1, character: 8, symbolRange: 5..<10, definitions: [zeroWidthDef]
        ))
        XCTAssertFalse(LSPNavigationHelper.isPositionOnDefinition(
            fileURL: fileA, line: 1, character: 16, symbolRange: 15..<20, definitions: [zeroWidthDef]
        ))

        // Symbol extraction helper
        let extracted = LSPNavigationHelper.extractSymbol(in: "func DeleteSignup(id string) {", at: 8)
        XCTAssertEqual(extracted?.name, "DeleteSignup")
        XCTAssertEqual(extracted?.range, 5..<17)
    }

    @MainActor
    func testReferencesPickerModelFilteringAndContextSnippetExtraction() throws {
        let dir = try makeTempDir(prefix: "dif-refs-model")
        let fileA = dir.appendingPathComponent("repoA/main.go")
        let fileB = dir.appendingPathComponent("repoB/greet.go")

        let linesA: [String] = (1...25).map { idx in
            if idx == 12 {
                return "\tmsg := repob.Greet(\"world\")"
            }
            return "\t// line \(idx)"
        }
        let spansA = Highlighter.highlight(linesA, language: .go)

        let item0 = ReferenceItem(
            id: 0,
            location: LSPLocation(
                uri: LSPURI.uri(from: fileB),
                range: LSPRange(start: LSPPosition(line: 3, character: 5), end: LSPPosition(line: 3, character: 10))
            ),
            fileURL: fileB,
            displayPath: "repoB/greet.go",
            lineNumber: 4,
            column: 5,
            endColumn: 10,
            linePreview: "func Greet(name string) string {",
            matchRangeInPreview: 5..<10,
            isDeclaration: true
        )
        let item1 = ReferenceItem(
            id: 1,
            location: LSPLocation(
                uri: LSPURI.uri(from: fileA),
                range: LSPRange(start: LSPPosition(line: 11, character: 14), end: LSPPosition(line: 11, character: 19))
            ),
            fileURL: fileA,
            displayPath: "repoA/main.go",
            lineNumber: 12,
            column: 14,
            endColumn: 19,
            linePreview: "msg := repob.Greet(\"world\")",
            matchRangeInPreview: 13..<18,
            isDeclaration: false
        )

        // Filtering by path, code snippet, line number, and multi-token query
        XCTAssertEqual(ReferencesPickerModel.filterItems([item0, item1], query: "").count, 2)
        // "repoB" matches item0 via displayPath and item1 via linePreview (`repob.Greet`)
        XCTAssertEqual(ReferencesPickerModel.filterItems([item0, item1], query: "repoB").map(\.id), [0, 1])
        XCTAssertEqual(ReferencesPickerModel.filterItems([item0, item1], query: "greet.go").map(\.id), [0])
        XCTAssertEqual(ReferencesPickerModel.filterItems([item0, item1], query: "WORLD").map(\.id), [1])
        XCTAssertEqual(ReferencesPickerModel.filterItems([item0, item1], query: "main.go 12").map(\.id), [1])
        XCTAssertTrue(ReferencesPickerModel.filterItems([item0, item1], query: "nonexistent").isEmpty)

        // Context snippet extraction: 6 lines before (6..11) + matched (12) + 8 lines after (13..20) = 15 lines
        let ctx = try XCTUnwrap(ReferencesPickerModel.extractContext(
            fileURL: fileA,
            displayPath: "repoA/main.go",
            lines: linesA,
            spans: spansA,
            language: .go,
            lineNumber: 12,
            column: 14,
            endColumn: 19,
            symbolName: "Greet"
        ))
        XCTAssertEqual(ctx.lines.count, 15)
        XCTAssertEqual(ctx.lines.first?.lineNumber, 6)
        XCTAssertEqual(ctx.lines.last?.lineNumber, 20)
        XCTAssertEqual(ctx.matchedLineNumber, 12)

        let matchedLines = ctx.lines.filter(\.isMatchedLine)
        XCTAssertEqual(matchedLines.count, 1)
        let matched = try XCTUnwrap(matchedLines.first)
        XCTAssertEqual(matched.lineNumber, 12)
        // Leading `\t` expanded to 4 spaces (+3 UTF-16 shift), so `Greet` moves from 14..<19 to 17..<22
        XCTAssertEqual(matched.text, "    msg := repob.Greet(\"world\")")
        XCTAssertEqual(matched.highlightRange, 17..<22)
        let nsMatched = matched.text as NSString
        XCTAssertEqual(nsMatched.substring(with: NSRange(location: 17, length: 5)), "Greet")
        // Verify syntax spans were preserved and shifted accurately (string `"world"` starts at 23)
        XCTAssertTrue(matched.spans.contains { $0.kind == .string && $0.start == 23 })

        // Clamping near top of file (line 2 -> starts at line 1)
        let topCtx = try XCTUnwrap(ReferencesPickerModel.extractContext(
            fileURL: fileA,
            displayPath: "repoA/main.go",
            lines: linesA,
            spans: spansA,
            language: .go,
            lineNumber: 2,
            column: 1,
            endColumn: 1,
            symbolName: "line"
        ))
        XCTAssertEqual(topCtx.lines.first?.lineNumber, 1)
        XCTAssertEqual(topCtx.lines.last?.lineNumber, 10)

        // trimLinePreview removes leading indentation and adjusts highlight range
        let trimmed = ReferencesPickerModel.trimLinePreview("\t\tmsg := repob.Greet(\"world\")", column: 15, endColumn: 20, symbolName: "Greet")
        XCTAssertEqual(trimmed.text, "msg := repob.Greet(\"world\")")
        XCTAssertEqual(trimmed.matchRange, 13..<18)

        // Interactive model navigation & filtering updates previewContext from cache
        let model = ReferencesPickerModel()
        let linesB = ["package repob", "", "// Greet", "func Greet(name string) string {", "\treturn name", "}"]
        let cache: [URL: CachedPreviewFile] = [
            fileA: CachedPreviewFile(lines: linesA, language: .go, spans: spansA),
            fileB: CachedPreviewFile(lines: linesB, language: .go, spans: Highlighter.highlight(linesB, language: .go)),
        ]
        model.setItemsForTesting(symbolName: "Greet", title: "References to Greet", items: [item0, item1], cachedFiles: cache)
        XCTAssertEqual(model.selectedItem?.id, 0)
        XCTAssertEqual(model.previewContext?.matchedLineNumber, 4)

        model.move(1)
        XCTAssertEqual(model.selectedItem?.id, 1)
        XCTAssertEqual(model.previewContext?.matchedLineNumber, 12)

        model.filterQuery = "greet.go"
        XCTAssertEqual(model.filteredItems.map(\.id), [0])
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.previewContext?.matchedLineNumber, 4)
        XCTAssertEqual(model.previewDocument?.right.lines, linesB)
        XCTAssertEqual(model.previewDocument?.isPlainFile, true)

        // Full-file canvas preview & same-file navigation
        model.filterQuery = ""
        let item2 = ReferenceItem(
            id: 2,
            location: LSPLocation(
                uri: LSPURI.uri(from: fileA),
                range: LSPRange(start: LSPPosition(line: 22, character: 14), end: LSPPosition(line: 22, character: 19))
            ),
            fileURL: fileA,
            displayPath: "repoA/main.go",
            lineNumber: 23,
            column: 14,
            endColumn: 19,
            linePreview: "msg := repob.Greet(\"world\")",
            matchRangeInPreview: 13..<18,
            isDeclaration: false
        )
        model.setItemsForTesting(symbolName: "Greet", title: "References to Greet", items: [item0, item1, item2], cachedFiles: cache)
        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        container.layoutSubtreeIfNeeded()
        model.attachPreview(container)
        XCTAssertTrue(container.canvas.document === model.previewDocument)
        XCTAssertEqual(model.previewDocument?.right.lines, linesB)
        XCTAssertEqual(container.canvas.focusLine?.side, .right)
        XCTAssertEqual(container.canvas.focusLine?.line, 3)

        model.move(1)
        let docFileA = try XCTUnwrap(model.previewDocument)
        XCTAssertEqual(docFileA.right.lines, linesA)
        XCTAssertTrue(container.canvas.document === docFileA)
        XCTAssertEqual(container.canvas.focusLine?.line, 11)

        // Same-file move reuses the cached DiffDocument and updates focusLine
        model.move(1)
        XCTAssertTrue(model.previewDocument === docFileA)
        XCTAssertEqual(container.canvas.focusLine?.line, 22)

        model.release()
        XCTAssertNil(model.previewDocument)
        XCTAssertNil(container.canvas.document)
    }

    @MainActor
    func testViewerContextMenuIncludesLSPItemsOnlyOnDirectEditionWithSymbol() async throws {
        let originalEdition = AppEnvironment.edition
        defer { AppEnvironment.edition = originalEdition }

        let dir = try makeTempDir(prefix: "dif-ctx-menu")
        let file = dir.appendingPathComponent("sample.go")
        try writeFile(file, contents: "package main\nfunc Greet() {}\n")

        let store = AppStore.shared
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevContainer = store.viewer.container
        defer {
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.viewer.container = prevContainer
        }

        let req = DiffRequest(root: dir, path: "sample.go", oldPath: nil, kind: nil, source: .file)
        let doc = await DiffLoader.load(req)
        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 600, height: 240))
        container.layoutSubtreeIfNeeded()
        container.show(doc, mode: .single, preserveScroll: false)
        container.canvas.isLSPEnabled = true

        store.viewer.request = req
        store.viewer.document = doc
        store.viewer.container = container

        let target = CodeCanvasView.LSPHoverTarget(row: 1, line: 1, column: 6, range: 5..<10)

        // Direct edition + eligible symbol -> prepends Go to Definition & Find All References
        AppEnvironment.edition = .direct
        container.canvas.noteContextLSPSymbol(target)
        let directMenu = try XCTUnwrap(store.viewerContextMenu())
        XCTAssertGreaterThanOrEqual(directMenu.items.count, 3)
        XCTAssertEqual(directMenu.items[0].title, L("Go to Definition", "跳转到声明"))
        XCTAssertEqual(directMenu.items[1].title, L("Find All References", "查找所有引用"))
        XCTAssertTrue(directMenu.items[2].isSeparatorItem)

        // No symbol under pointer -> LSP items omitted
        container.canvas.noteContextLSPSymbol(nil)
        let noSymbolMenu = try XCTUnwrap(store.viewerContextMenu())
        XCTAssertFalse(noSymbolMenu.items.contains { $0.title == L("Go to Definition", "跳转到声明") })
        XCTAssertFalse(noSymbolMenu.items.contains { $0.title == L("Find All References", "查找所有引用") })

        // App Store edition -> LSP items never shown even if target is set
        AppEnvironment.edition = .appStore
        container.canvas.noteContextLSPSymbol(target)
        let appStoreMenu = try XCTUnwrap(store.viewerContextMenu())
        XCTAssertFalse(appStoreMenu.items.contains { $0.title == L("Go to Definition", "跳转到声明") })
        XCTAssertFalse(appStoreMenu.items.contains { $0.title == L("Find All References", "查找所有引用") })
    }

    @MainActor
    func testSmartLSPNavigateOnDefinitionOpensReferencesAndOnReferenceJumps() async throws {
        let originalEdition = AppEnvironment.edition
        AppEnvironment.edition = .direct
        defer { AppEnvironment.edition = originalEdition }

        let dir = try makeTempDir(prefix: "dif-smart-click")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let greetFile = repo.appendingPathComponent("greet.go")
        let mainFile = repo.appendingPathComponent("main.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(greetFile, contents: "package repo\nfunc Greet() {}\n")
        try writeFile(mainFile, contents: "package repo\nfunc main() { Greet() }\n")

        let greetURI = LSPURI.uri(from: greetFile)
        let mainURI = LSPURI.uri(from: mainFile)
        let script = dir.appendingPathComponent("mock-smart-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, sys

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
            return json.loads(sys.stdin.buffer.read(n).decode("utf-8")) if n > 0 else None

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
            if method == "initialize":
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "definitionProvider": True,
                            "referencesProvider": True,
                        }
                    },
                })
            elif method == "textDocument/definition":
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": [{
                        "uri": "\(greetURI)",
                        "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}},
                    }],
                })
            elif method == "textDocument/references":
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": [{
                        "uri": "\(mainURI)",
                        "range": {"start": {"line": 1, "character": 14}, "end": {"line": 1, "character": 19}},
                    }],
                })
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])

        let store = AppStore.shared
        let prevManager = store.viewer.lspManager
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevLSPDoc = store.viewer.lspDocument
        let prevPopup = store.popup
        let prevExternal = store.externalRequest
        let prevHistory = store.jumpHistory
        defer {
            store.definitionTask?.cancel()
            store.dismissPopup(restoreFocus: false)
            store.viewer.lspManager = prevManager
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.viewer.lspDocument = prevLSPDoc
            store.popup = prevPopup
            store.externalRequest = prevExternal
            store.jumpHistory = prevHistory
        }

        store.viewer.lspManager = manager
        store.jumpHistory.clear()

        // 1. Open greet.go (where Greet is defined on line 1, col 5..<10)
        let reqGreet = DiffRequest(root: repo, path: "greet.go", oldPath: nil, kind: nil, source: .file)
        let docGreet = await DiffLoader.load(reqGreet)
        store.viewer.request = reqGreet
        store.viewer.document = docGreet
        store.viewer.syncLSPForCurrentDocument()
        await store.viewer.lspTask?.value

        // Smart ⌘+Click ON the definition (`Greet` at line 1, col 6) -> opens References Picker Popup!
        store.smartLSPNavigate(line: 1, character: 6)
        await store.definitionTask?.value

        XCTAssertEqual(store.popup, .references)
        XCTAssertEqual(store.references.symbolName, "Greet")
        XCTAssertEqual(store.references.items.count, 1)
        XCTAssertEqual(store.references.items.first?.fileURL, mainFile)
        XCTAssertEqual(store.references.origin?.fileURL, greetFile)
        XCTAssertEqual(store.references.origin?.line, 2)

        // Dismiss popup, open main.go (reference site at line 1, col 15)
        store.dismissPopup(restoreFocus: false)
        let reqMain = DiffRequest(root: repo, path: "main.go", oldPath: nil, kind: nil, source: .file)
        let docMain = await DiffLoader.load(reqMain)
        store.viewer.request = reqMain
        store.viewer.document = docMain
        store.viewer.syncLSPForCurrentDocument()
        await store.viewer.lspTask?.value

        // Smart ⌘+Click ON the reference (`Greet` at line 1, col 15) -> jumps directly to greet.go (no popup) & pushes origin!
        store.smartLSPNavigate(line: 1, character: 15)
        await store.definitionTask?.value

        XCTAssertNil(store.popup)
        XCTAssertTrue(store.jumpHistory.canGoBack)
        XCTAssertEqual(store.jumpHistory.backStack.last?.fileURL, mainFile)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 2)

        await manager.shutdownAll()
    }

    // MARK: - 5. LSP Lifecycle & Self-Healing Regression Tests

    @MainActor
    func testNotifySavedAndFlushDuringInFlightDidOpenNeverOrphansDocument() async throws {
        let originalEdition = AppEnvironment.edition
        AppEnvironment.edition = .direct
        defer { AppEnvironment.edition = originalEdition }

        let dir = try makeTempDir(prefix: "dif-lsp-cancel-open")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let fileA = repo.appendingPathComponent("main.go")
        let fileB = repo.appendingPathComponent("target.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(fileA, contents: "package repo\nfunc main() { Target() }\n")
        try writeFile(fileB, contents: "package repo\nfunc Target() {}\n")

        let targetURI = LSPURI.uri(from: fileB)
        let script = dir.appendingPathComponent("strict-open-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, sys, time

        open_docs = {}

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
            return json.loads(sys.stdin.buffer.read(n).decode("utf-8")) if n > 0 else None

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
                time.sleep(0.08)
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "definitionProvider": True,
                        }
                    },
                })
            elif method == "textDocument/didOpen":
                td = params.get("textDocument", {})
                open_docs[td.get("uri", "")] = td.get("version", 1)
            elif method == "textDocument/didChange":
                td = params.get("textDocument", {})
                uri = td.get("uri", "")
                if uri in open_docs:
                    open_docs[uri] = td.get("version", open_docs[uri])
            elif method == "textDocument/didClose":
                uri = params.get("textDocument", {}).get("uri", "")
                open_docs.pop(uri, None)
            elif method == "textDocument/definition":
                uri = params.get("textDocument", {}).get("uri", "")
                # Only resolve when the server actually received didOpen for this file (like gopls).
                if uri in open_docs:
                    send_msg({
                        "jsonrpc": "2.0",
                        "id": msg_id,
                        "result": [{
                            "uri": "\(targetURI)",
                            "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 11}},
                        }],
                    })
                else:
                    send_msg({"jsonrpc": "2.0", "id": msg_id, "result": []})
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])
        defer { Task { await manager.shutdownAll() } }

        let viewer = ViewerModel()
        viewer.settings = Settings.shared
        viewer.lspManager = manager

        let reqA = DiffRequest(root: repo, path: "main.go", oldPath: nil, kind: nil, source: .file)
        let docA = await DiffLoader.load(reqA)
        viewer.request = reqA
        viewer.document = docA

        // Start syncLSPForCurrentDocument (cold server start takes ~80ms) and immediately fire save + flush
        // while didOpen is still in-flight! Previously this cancelled didOpen and permanently wedged fileA.
        viewer.syncLSPForCurrentDocument()
        viewer.scheduleLSPChange()
        viewer.notifyLSPSaved()
        viewer.scheduleLSPChange()
        await viewer.flushLSPChangeIfNeeded()
        await viewer.lspTask?.value

        let uriA = LSPURI.uri(from: fileA)
        let session = await manager.openSession(forURI: uriA)
        XCTAssertNotNil(session, "notifyLSPSaved / flushLSPChangeIfNeeded during in-flight didOpen must never orphan the document")

        let defs = await manager.definition(fileURL: fileA, line: 1, character: 15, language: .go, repoRoot: repo)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.fileURL.map { LSPURI.canonicalFileURL($0) }, fileB)

        await manager.shutdownAll()
    }

    func testReopeningSameFileSendsStrictlyMonotonicDidChangeVersions() async throws {
        let dir = try makeTempDir(prefix: "dif-lsp-monotonic-ver")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let fileA = repo.appendingPathComponent("main.go")
        let logFile = dir.appendingPathComponent("versions.log")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(fileA, contents: "package repo\nfunc A() {}\n")

        let script = dir.appendingPathComponent("version-log-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, sys

        LOG_PATH = \(String(reflecting: logFile.path))

        def log(line):
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\\n")

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
            return json.loads(sys.stdin.buffer.read(n).decode("utf-8")) if n > 0 else None

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
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": {"capabilities": {"textDocumentSync": 1}}})
            elif method in ("textDocument/didOpen", "textDocument/didChange"):
                td = params.get("textDocument", {})
                log(f"{method}:{td.get('version')}")
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])
        defer { Task { await manager.shutdownAll() } }

        // Initial open v1 -> edit v5 -> reopen same file with reset version=1 -> stale didChange version=2
        _ = await manager.didOpen(fileURL: fileA, text: "package repo\nfunc A() {}\n", version: 1, language: .go, repoRoot: repo)
        await manager.didChange(fileURL: fileA, version: 5, text: "package repo\nfunc B() {}\n", language: .go, repoRoot: repo)
        _ = await manager.didOpen(fileURL: fileA, text: "package repo\nfunc C() {}\n", version: 1, language: .go, repoRoot: repo)
        await manager.didChange(fileURL: fileA, version: 2, text: "package repo\nfunc D() {}\n", language: .go, repoRoot: repo)

        let session = await manager.openSession(forURI: LSPURI.uri(from: fileA))
        XCTAssertEqual(session?.version, 7)

        await manager.shutdownAll()

        let entries = try String(contentsOf: logFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(entries, [
            "textDocument/didOpen:1",
            "textDocument/didChange:5",
            "textDocument/didChange:6",
            "textDocument/didChange:7",
        ])
    }

    @MainActor
    func testEnsureLSPDocumentSyncedSelfHealsAfterServerRestartOrClose() async throws {
        let originalEdition = AppEnvironment.edition
        AppEnvironment.edition = .direct
        defer { AppEnvironment.edition = originalEdition }

        let dir = try makeTempDir(prefix: "dif-lsp-self-heal")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let fileA = repo.appendingPathComponent("main.go")
        let fileB = repo.appendingPathComponent("helper.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(fileA, contents: "package repo\nfunc main() { Helper() }\n")
        try writeFile(fileB, contents: "package repo\nfunc Helper() {}\n")

        let helperURI = LSPURI.uri(from: fileB)
        let script = dir.appendingPathComponent("heal-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, sys

        open_docs = set()

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
            return json.loads(sys.stdin.buffer.read(n).decode("utf-8")) if n > 0 else None

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
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {"capabilities": {"textDocumentSync": 1, "definitionProvider": True}},
                })
            elif method == "textDocument/didOpen":
                open_docs.add(params.get("textDocument", {}).get("uri", ""))
            elif method == "textDocument/didClose":
                open_docs.discard(params.get("textDocument", {}).get("uri", ""))
            elif method == "textDocument/definition":
                uri = params.get("textDocument", {}).get("uri", "")
                res = [{
                    "uri": "\(helperURI)",
                    "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 11}},
                }] if uri in open_docs else []
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": res})
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])
        defer { Task { await manager.shutdownAll() } }

        let viewer = ViewerModel()
        viewer.settings = Settings.shared
        viewer.lspManager = manager

        let reqA = DiffRequest(root: repo, path: "main.go", oldPath: nil, kind: nil, source: .file)
        let docA = await DiffLoader.load(reqA)
        viewer.request = reqA
        viewer.document = docA
        viewer.syncLSPForCurrentDocument()
        await viewer.lspTask?.value

        // Simulate idle-reap / server restart wiping LSPManager state while ViewerModel still holds fileA.
        await manager.shutdownAll()
        let closedSession = await manager.openSession(forURI: LSPURI.uri(from: fileA))
        XCTAssertNil(closedSession)

        // ensureLSPDocumentSynced must re-open fileA transparently.
        let synced = await viewer.ensureLSPDocumentSynced()
        XCTAssertNotNil(synced)
        let healedSession = await manager.openSession(forURI: LSPURI.uri(from: fileA))
        XCTAssertNotNil(healedSession)

        // Direct definition query after didClose also self-heals via LSPManager.ensureDocumentOpen.
        await manager.didClose(fileURL: fileA)
        let defs = await manager.definition(fileURL: fileA, line: 1, character: 15, language: .go, repoRoot: repo)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs.first?.fileURL.map { LSPURI.canonicalFileURL($0) }, fileB)

        await manager.shutdownAll()
    }

    // MARK: - 6. History Commit Diff LSP Navigation & Diff JumpHistory Round-Trip Tests

    func testMapSymbolToWorkingTreeHandlesShiftedAndRemovedSymbols() {
        let diskLines = [
            "package repo",
            "// added comment 1",
            "// added comment 2",
            "func main() { checkLeagueEvolveTimeWithLock(tableMgr, league, now) }",
            "func other() { checkLeagueEvolveTimeWithLock(nil, nil, now) }",
        ]

        // 1. Shifted lines: commit had call at line 1, working tree has exact trimmed line at line 3.
        let shifted = LSPNavigationHelper.mapSymbolToWorkingTree(
            symbolName: "checkLeagueEvolveTimeWithLock",
            clickedLineText: "func main() { checkLeagueEvolveTimeWithLock(tableMgr, league, now) }",
            clickedLine: 1,
            clickedStartColumn: 14,
            offsetInSymbol: 5,
            diskLines: diskLines
        )
        XCTAssertEqual(shifted?.line, 3)
        XCTAssertEqual(shifted?.symbolRange, 14..<43)
        XCTAssertEqual(shifted?.character, 19)

        // 2. Modified line near clicked line: falls back to nearest identifier match.
        let modified = LSPNavigationHelper.mapSymbolToWorkingTree(
            symbolName: "checkLeagueEvolveTimeWithLock",
            clickedLineText: "func main() { checkLeagueEvolveTimeWithLock(oldArg) }",
            clickedLine: 3,
            clickedStartColumn: 14,
            offsetInSymbol: 0,
            diskLines: diskLines
        )
        XCTAssertEqual(modified?.line, 3)
        XCTAssertEqual(modified?.symbolRange, 14..<43)

        // 3. Removed symbol: returns nil.
        let missing = LSPNavigationHelper.mapSymbolToWorkingTree(
            symbolName: "deletedHelper",
            clickedLineText: "deletedHelper()",
            clickedLine: 1,
            clickedStartColumn: 0,
            offsetInSymbol: 0,
            diskLines: diskLines
        )
        XCTAssertNil(missing)
    }

    @MainActor
    func testCommitDiffEnablesWorkingTreeLSPNavigationAndBackRestoresExactCommitDiff() async throws {
        let originalEdition = AppEnvironment.edition
        AppEnvironment.edition = .direct
        defer { AppEnvironment.edition = originalEdition }

        let dir = try makeTempDir(prefix: "dif-lsp-history-nav")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let fileMain = repo.appendingPathComponent("main.go")
        let fileHelper = repo.appendingPathComponent("helper.go")
        try writeFile(repo.appendingPathComponent("go.mod"), contents: "module example.com/repo\ngo 1.22\n")
        try writeFile(fileHelper, contents: "package repo\nfunc Helper() {}\n")
        try writeFile(fileMain, contents: "package repo\nfunc main() { Helper() }\n")

        func git(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " ")) failed")
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        _ = try git("init")
        _ = try git("config", "user.name", "Tester")
        _ = try git("config", "user.email", "tester@example.com")
        _ = try git("add", ".")
        _ = try git("commit", "-m", "init")
        let parentHash = try git("rev-parse", "HEAD")

        try writeFile(fileMain, contents: "package repo\n// commit line\nfunc main() { Helper() }\n")
        _ = try git("add", "main.go")
        _ = try git("commit", "-m", "second")
        let commitHash = try git("rev-parse", "HEAD")

        // Working tree shifts the call down by 2 more lines compared to the commit snapshot.
        let diskMainText = "package repo\n// wt 1\n// wt 2\n// commit line\nfunc main() { Helper() }\n"
        try writeFile(fileMain, contents: diskMainText)

        let helperURI = LSPURI.uri(from: fileHelper)
        let logFile = dir.appendingPathComponent("history-lsp.log")
        let script = dir.appendingPathComponent("history-lsp.py")
        let source = """
        #!/usr/bin/env python3
        import json, sys

        LOG_PATH = \(String(reflecting: logFile.path))

        def log(line):
            with open(LOG_PATH, "a", encoding="utf-8") as f:
                f.write(line + "\\n")

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
            return json.loads(sys.stdin.buffer.read(n).decode("utf-8")) if n > 0 else None

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
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": {"capabilities": {"textDocumentSync": 1, "definitionProvider": True}}})
            elif method == "textDocument/didOpen":
                td = params.get("textDocument", {})
                log("didOpen:" + json.dumps({"uri": td.get("uri"), "text": td.get("text")}))
            elif method == "textDocument/definition":
                pos = params.get("position", {})
                log(f"definition:{pos.get('line')}:{pos.get('character')}")
                send_msg({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": [{
                        "uri": "\(helperURI)",
                        "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 11}},
                    }],
                })
            elif method == "shutdown":
                send_msg({"jsonrpc": "2.0", "id": msg_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(script, contents: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [script.path],
            environment: AppEnvironment.childEnvironment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: server])
        defer { Task { await manager.shutdownAll() } }

        let store = AppStore.shared
        let prevProjects = store.projects
        let prevSelectedID = store.selectedProjectID
        let prevManager = store.viewer.lspManager
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevLSPDoc = store.viewer.lspDocument
        let prevHistory = store.jumpHistory
        let prevExternal = store.externalRequest
        defer {
            store.definitionTask?.cancel()
            store.viewer.lspManager = prevManager
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedID
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.viewer.lspDocument = prevLSPDoc
            store.jumpHistory = prevHistory
            store.externalRequest = prevExternal
        }

        let project = Project(url: repo)
        project.tab = .log
        store.projects = [project]
        store.selectedProjectID = project.id
        store.viewer.lspManager = manager
        store.jumpHistory.clear()

        let commitReq = store.resolvedRequest(DiffRequest(
            root: project.url,
            path: "main.go",
            oldPath: nil,
            kind: .modified,
            source: .commit(hash: commitHash, parent: parentHash)
        ))
        let commitDoc = await DiffLoader.load(commitReq)
        store.viewer.request = commitReq
        store.viewer.document = commitDoc
        store.viewer.syncLSPForCurrentDocument()

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        container.layoutSubtreeIfNeeded()
        store.viewer.attach(container)
        container.canvas.flush()

        XCTAssertTrue(store.viewer.isCurrentDocumentLSPEnabled)
        XCTAssertFalse(store.viewer.isCurrentDocumentLSPSyncEnabled)
        XCTAssertTrue(container.canvas.isLSPEnabled)
        XCTAssertNil(store.viewer.lspDocument, "Historical commit diff must never open a live LSP buffer")

        // Verify right-click context menu shows Go to Definition & Find All References on commit diff.
        container.canvas.noteContextLSPSymbol(CodeCanvasView.LSPHoverTarget(row: 2, line: 2, column: 15, range: 14..<20))
        let menuTitles = store.viewerContextMenu()?.items.map(\.title) ?? []
        XCTAssertTrue(menuTitles.contains("跳转到声明") || menuTitles.contains("Go to Definition"))
        XCTAssertTrue(menuTitles.contains("查找所有引用") || menuTitles.contains("Find All References"))

        // Click `Helper` at line 2, col 15 in the commit diff -> maps to line 4 in working tree on disk!
        store.smartLSPNavigate(line: 2, character: 15)
        await store.definitionTask?.value

        XCTAssertEqual(store.viewer.request?.path, "helper.go")
        XCTAssertTrue(store.jumpHistory.canGoBack)
        XCTAssertEqual(store.jumpHistory.backStack.last?.request, commitReq)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 3)

        // Ctrl-O / navigateBack restores the exact historical commit diff!
        store.navigateBack()
        XCTAssertEqual(store.viewer.request, commitReq)
        XCTAssertEqual(project.tab, .log)
        XCTAssertNil(project.browsedPath)

        // Ctrl-I / navigateForward jumps forward back to helper.go!
        store.navigateForward()
        XCTAssertEqual(store.viewer.request?.path, "helper.go")

        await manager.shutdownAll()

        let logs = try String(contentsOf: logFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertTrue(logs.contains("definition:4:15"), "Should query working-tree line 4, got \(logs)")
        let openLog = try XCTUnwrap(logs.first(where: { $0.hasPrefix("didOpen:") }))
        XCTAssertTrue(openLog.contains("// wt 1"), "didOpen must use disk working-tree text, never historical snapshot")

        // Deleted commit file must disable LSP navigation.
        let deletedCommitReq = store.resolvedRequest(DiffRequest(
            root: repo,
            path: "main.go",
            oldPath: nil,
            kind: .deleted,
            source: .commit(hash: commitHash, parent: parentHash)
        ))
        store.viewer.request = deletedCommitReq
        XCTAssertFalse(store.viewer.isCurrentDocumentLSPEnabled)
    }

    @MainActor
    func testOpenCurrentFileFromDiffSupportsBackAndForwardToExactDiff() async throws {
        let dir = try makeTempDir(prefix: "dif-open-current-back")
        let repo = dir.appendingPathComponent("repo", isDirectory: true)
        let fileMain = repo.appendingPathComponent("main.go")
        try writeFile(fileMain, contents: "package repo\nfunc a() {}\nfunc b() {}\n")

        func git(_ args: String...) throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = repo
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        _ = try git("init")
        _ = try git("config", "user.name", "Tester")
        _ = try git("config", "user.email", "tester@example.com")
        _ = try git("add", ".")
        _ = try git("commit", "-m", "init")
        let parentHash = try git("rev-parse", "HEAD")

        try writeFile(fileMain, contents: "package repo\nfunc a() {}\nfunc b() { a() }\n")
        _ = try git("add", "main.go")
        _ = try git("commit", "-m", "second")
        let commitHash = try git("rev-parse", "HEAD")

        let store = AppStore.shared
        let prevProjects = store.projects
        let prevSelectedID = store.selectedProjectID
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevHistory = store.jumpHistory
        let prevExternal = store.externalRequest
        defer {
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedID
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.jumpHistory = prevHistory
            store.externalRequest = prevExternal
        }

        let project = Project(url: repo)
        project.tab = .log
        store.projects = [project]
        store.selectedProjectID = project.id
        store.jumpHistory.clear()

        let commitReq = store.resolvedRequest(DiffRequest(
            root: project.url,
            path: "main.go",
            oldPath: nil,
            kind: .modified,
            source: .commit(hash: commitHash, parent: parentHash)
        ))
        let commitDoc = await DiffLoader.load(commitReq)
        store.viewer.request = commitReq
        store.viewer.document = commitDoc
        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 900, height: 300))
        container.layoutSubtreeIfNeeded()
        store.viewer.attach(container)
        container.canvas.placeCaret(line: 2, column: 11)

        store.openCurrentFile()
        XCTAssertEqual(store.viewer.request?.source, .file)
        XCTAssertEqual(project.browsedPath, "main.go")
        XCTAssertTrue(store.jumpHistory.canGoBack)

        store.navigateBack()
        XCTAssertEqual(store.viewer.request, commitReq)
        XCTAssertNil(project.browsedPath)
        XCTAssertEqual(project.tab, .log)

        store.navigateForward()
        XCTAssertEqual(store.viewer.request?.source, .file)
        XCTAssertEqual(project.browsedPath, "main.go")
    }
}
