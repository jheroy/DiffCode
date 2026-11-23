import AppKit
import XCTest
@testable import DifKit

final class StickyLinesTests: XCTestCase {
    // MARK: - Scope Extraction

    func testGoExtractionHandlesFunctionsMethodsStructsInterfacesAndMultilineSignatures() {
        let source = """
        package service

        const Version = "1.0"

        type Tiny struct{}

        type Service interface {
        \tRun(ctx context.Context) error
        \tStop() error
        }

        type (
        \tManager struct {
        \t\tdb string
        \t\tmu int
        \t}
        )

        func Stub() {}

        func (m *Manager) Process(
        \tpayload interface{},
        \topts struct{ dryRun bool },
        ) error {
        \tstep1 := payload
        \t_ = step1
        \treturn nil
        }

        func (c *Cache[K, V]) Get(key K) (V, bool) {
        \tvar zero V
        \treturn zero, false
        }
        """
        let lines = source.components(separatedBy: "\n")
        let scopes = StickyLinesEngine.extractScopes(lines: lines, language: .go)

        // Constants (`Version`) and 1-2 line declarations (`Tiny`, `Stub`) are omitted.
        XCTAssertFalse(scopes.contains { lines[$0.startLine].contains("Version") })
        XCTAssertFalse(scopes.contains { lines[$0.startLine].contains("Tiny") })
        XCTAssertFalse(scopes.contains { lines[$0.startLine].contains("Stub") })

        let headers = scopes.map { lines[$0.startLine].trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(headers.contains("type Service interface {"))
        XCTAssertTrue(headers.contains("Manager struct {"))
        XCTAssertTrue(headers.contains("func (m *Manager) Process("))
        XCTAssertTrue(headers.contains("func (c *Cache[K, V]) Get(key K) (V, bool) {"))

        // Multi-line signature with `interface{}` and `struct{ dryRun bool }` must resolve endLine to the closing `}` of Process.
        if let processIdx = lines.firstIndex(where: { $0.contains("func (m *Manager) Process(") }),
           let processScope = scopes.first(where: { $0.startLine == processIdx }) {
            let bodyEnd = processIdx + 7
            XCTAssertEqual(processScope.endLine, bodyEnd)
            XCTAssertEqual(lines[processScope.endLine], "}")
        } else {
            XCTFail("Expected Process scope")
        }
    }

    func testSwiftRustTypeScriptPythonCppAndJavaExtraction() {
        let swift = """
        struct Outer {
            class Inner {
                init(value: Int) {
                    let a = value
                    print(a)
                }
                func run() {
                    let x = 1
                    print(x)
                }
            }
        }
        """
        let swiftLines = swift.components(separatedBy: "\n")
        let swiftScopes = StickyLinesEngine.extractScopes(lines: swiftLines, language: .swift)
        XCTAssertEqual(swiftScopes.map(\.depth), [0, 1, 2, 2])
        XCTAssertTrue(swiftLines[swiftScopes[0].startLine].contains("struct Outer"))
        XCTAssertTrue(swiftLines[swiftScopes[1].startLine].contains("class Inner"))
        XCTAssertTrue(swiftLines[swiftScopes[2].startLine].contains("init(value: Int)"))
        XCTAssertTrue(swiftLines[swiftScopes[3].startLine].contains("func run()"))

        let rust = """
        mod engine {
            pub struct Runner {
                id: i32,
                name: String,
            }
            impl Runner {
                pub fn start(&self) {
                    let ok = true;
                    println!("{}", ok);
                }
            }
        }
        """
        let rustLines = rust.components(separatedBy: "\n")
        let rustScopes = StickyLinesEngine.extractScopes(lines: rustLines, language: .rust)
        XCTAssertEqual(rustScopes.map(\.depth), [0, 1, 1, 2])
        XCTAssertTrue(rustLines[rustScopes[0].startLine].contains("mod engine"))
        XCTAssertTrue(rustLines[rustScopes[2].startLine].contains("impl Runner"))
        XCTAssertTrue(rustLines[rustScopes[3].startLine].contains("pub fn start"))

        let ts = """
        export class AuthClient {
            async login(user: string): Promise<void> {
                describe("nested call", () => {
                    console.log(user);
                });
                return;
            }
        }
        export const boot = async () => {
            const client = new AuthClient();
            await client.login("a");
        }
        """
        let tsLines = ts.components(separatedBy: "\n")
        let tsScopes = StickyLinesEngine.extractScopes(lines: tsLines, language: .javascript)
        let tsHeaders = tsScopes.map { tsLines[$0.startLine].trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(tsHeaders.contains("export class AuthClient {"))
        XCTAssertTrue(tsHeaders.contains("async login(user: string): Promise<void> {"))
        XCTAssertTrue(tsHeaders.contains("export const boot = async () => {"))
        XCTAssertFalse(tsHeaders.contains { $0.hasPrefix("describe(") })

        let py = """
        class Service:
            def run(self):
                x = 1
                return x
        """
        let pyLines = py.components(separatedBy: "\n")
        let pyScopes = StickyLinesEngine.extractScopes(lines: pyLines, language: .python)
        XCTAssertEqual(pyScopes.count, 2)
        XCTAssertEqual(pyScopes[0].depth, 0)
        XCTAssertEqual(pyScopes[1].depth, 1)
        XCTAssertEqual(pyScopes[0].endLine, pyScopes[1].endLine)

        let cpp = """
        namespace core {
        class Engine {
            void start() {
                int x = 1;
                x++;
            }
        };
        }
        """
        let cppLines = cpp.components(separatedBy: "\n")
        let cppScopes = StickyLinesEngine.extractScopes(lines: cppLines, language: .cFamily)
        XCTAssertEqual(cppScopes.map(\.depth), [0, 1, 2])
        XCTAssertTrue(cppLines[cppScopes[0].startLine].contains("namespace core"))
        XCTAssertTrue(cppLines[cppScopes[1].startLine].contains("class Engine"))
        XCTAssertTrue(cppLines[cppScopes[2].startLine].contains("void start()"))

        let java = """
        public class Greeter {
            public void greet(String name) {
                String msg = "hi " + name;
                System.out.println(msg);
            }
        }
        """
        let javaLines = java.components(separatedBy: "\n")
        let javaScopes = StickyLinesEngine.extractScopes(lines: javaLines, language: .java)
        XCTAssertEqual(javaScopes.map(\.depth), [0, 1])
        XCTAssertTrue(javaLines[javaScopes[1].startLine].contains("public void greet"))
    }

    // MARK: - Sticky Resolution & Push-Out Physics

    func testResolvePinningPushOutAndCaps() {
        let lh: CGFloat = 20
        let outer = StickyDisplayScope(headerRow: 0, endRow: 20, sourceSide: .right, sourceLine: 0)
        let inner = StickyDisplayScope(headerRow: 3, endRow: 10, sourceSide: .right, sourceLine: 3)
        let deep = StickyDisplayScope(headerRow: 5, endRow: 10, sourceSide: .right, sourceLine: 5)
        let scopes = [outer, inner, deep]

        // At scrollTop <= 0: nothing pinned.
        XCTAssertEqual(
            StickyLinesEngine.resolve(scopes: scopes, scrollTop: 0, lineHeight: lh, viewportHeight: 500, maxLines: 5),
            .empty
        )

        // Just past line 0: outer pinned at y=0.
        let r1 = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 10, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(r1.slots.count, 1)
        XCTAssertEqual(r1.slots[0].scope.sourceLine, 0)
        XCTAssertEqual(r1.slots[0].y, 0)
        XCTAssertEqual(r1.height, 20)

        // When inner header (row 3 -> y=60) scrolls above slot 1 (scrollTop + 20 > 60 => scrollTop = 50), inner pins at y=20.
        let r2 = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 50, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(r2.slots.map(\.scope.sourceLine), [0, 3])
        XCTAssertEqual(r2.slots.map(\.y), [0, 20])
        XCTAssertEqual(r2.height, 40)

        // All 3 nested scopes pinned at y = 0, 20, 40 when scrollTop = 90.
        let r3 = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 90, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(r3.slots.map(\.scope.sourceLine), [0, 3, 5])
        XCTAssertEqual(r3.slots.map(\.y), [0, 20, 40])
        XCTAssertEqual(r3.height, 60)

        // Inner & deep share endRow = 10 -> endScreenY = 200 - scrollTop.
        // At scrollTop = 150: endScreenY = 50 -> endScreenY - lh = 30.
        // Slot 1 (nominal 20) stays at 20; Slot 2 (nominal 40) pushes up to y = 30!
        let rPush = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 150, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(rPush.slots.map(\.scope.sourceLine), [0, 3, 5])
        XCTAssertEqual(rPush.slots.map(\.y), [0, 20, 30])
        XCTAssertEqual(rPush.height, 50)

        // At scrollTop = 170: endScreenY = 30 -> endScreenY - lh = 10.
        // Deep slot would fall below slotTopY (170 + 40 = 210 > 200), so only [outer(y=0), inner(y=10)] remain, smoothly pushed!
        let rPush2 = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 170, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(rPush2.slots.map(\.scope.sourceLine), [0, 3])
        XCTAssertEqual(rPush2.slots.map(\.y), [0, 10])
        XCTAssertEqual(rPush2.height, 30)

        // At scrollTop = 190: endScreenY = 10 -> slot 1 vanishes (190 + 20 = 210 > 200), only outer remains.
        let rAfter = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 190, lineHeight: lh, viewportHeight: 500, maxLines: 5)
        XCTAssertEqual(rAfter.slots.map(\.scope.sourceLine), [0])
        XCTAssertEqual(rAfter.slots.map(\.y), [0])

        // Max lines cap = 2.
        let rCap = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 90, lineHeight: lh, viewportHeight: 500, maxLines: 2)
        XCTAssertEqual(rCap.slots.map(\.scope.sourceLine), [0, 3])

        // Viewport height cap: 120pt / 20pt / 3 = 2 max slots even when maxLines = 5.
        let rSmall = StickyLinesEngine.resolve(scopes: scopes, scrollTop: 90, lineHeight: lh, viewportHeight: 120, maxLines: 5)
        XCTAssertEqual(rSmall.slots.map(\.scope.sourceLine), [0, 3])
    }

    func testShiftScopesAcrossEdits() {
        let scopes = [
            StickyScope(startLine: 1, endLine: 4, kind: .function, depth: 0),
            StickyScope(startLine: 6, endLine: 20, kind: .class, depth: 0),
            StickyScope(startLine: 8, endLine: 14, kind: .method, depth: 1),
            StickyScope(startLine: 22, endLine: 30, kind: .function, depth: 0),
        ]

        // Insert 3 lines inside method (at line 10): first stays, enclosing class & method expand, trailing function shifts down.
        let inserted = StickyLinesEngine.shiftScopes(scopes, by: LineEdit(start: 10, removed: 0, inserted: 3))
        XCTAssertEqual(inserted[0], StickyScope(startLine: 1, endLine: 4, kind: .function, depth: 0))
        XCTAssertEqual(inserted[1], StickyScope(startLine: 6, endLine: 23, kind: .class, depth: 0))
        XCTAssertEqual(inserted[2], StickyScope(startLine: 8, endLine: 17, kind: .method, depth: 1))
        XCTAssertEqual(inserted[3], StickyScope(startLine: 25, endLine: 33, kind: .function, depth: 0))

        // Delete lines 7...9 (consumes method header at line 8): method is dropped while outer class shrinks.
        let deleted = StickyLinesEngine.shiftScopes(scopes, by: LineEdit(start: 7, removed: 3, inserted: 0))
        XCTAssertEqual(deleted.count, 3)
        XCTAssertEqual(deleted[1], StickyScope(startLine: 6, endLine: 17, kind: .class, depth: 0))
        XCTAssertEqual(deleted[2], StickyScope(startLine: 19, endLine: 27, kind: .function, depth: 0))
    }

    // MARK: - Settings Persistence

    @MainActor
    func testSettingsPersistenceAndClamping() throws {
        let suiteName = "StickyLinesTests.Settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = Settings(defaults: defaults)
        XCTAssertTrue(initial.stickyLines)
        XCTAssertEqual(initial.stickyLinesMaxCount, 5)

        initial.stickyLines = false
        initial.stickyLinesMaxCount = 8
        initial.save()

        let reloaded = Settings(defaults: defaults)
        XCTAssertFalse(reloaded.stickyLines)
        XCTAssertEqual(reloaded.stickyLinesMaxCount, 8)

        defaults.set(99, forKey: "stickyLinesMaxCount")
        let clampedHigh = Settings(defaults: defaults)
        XCTAssertEqual(clampedHigh.stickyLinesMaxCount, Settings.stickyLinesRange.upperBound)

        defaults.set(0, forKey: "stickyLinesMaxCount")
        let clampedLow = Settings(defaults: defaults)
        XCTAssertEqual(clampedLow.stickyLinesMaxCount, Settings.stickyLinesRange.lowerBound)
    }

    // MARK: - Canvas, Modes, Click Jump, Caret & Context Menu Integration

    @MainActor
    func testCanvasStickyIntegrationModesClickJumpAndRevealCaret() throws {
        let suiteName = "StickyLinesTests.Canvas.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = Settings(defaults: defaults)
        let viewer = ViewerModel()
        viewer.settings = settings

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 920, height: 220))
        container.layoutSubtreeIfNeeded()
        viewer.attach(container)

        var lines: [String] = [
            "package demo",
            "type Engine struct {",
            "\tid int",
            "}",
            "func (e *Engine) Run() {",
        ]
        for i in 1...40 {
            lines.append("\tstep\(i) := \(i)")
        }
        lines.append("}")
        lines.append("func Tail() {")
        lines.append("\treturn")
        lines.append("}")

        let leftBuf = TextBuffer(lines: lines)
        var rightLines = lines
        rightLines[12] = "\tstep8 := 800"
        rightLines[32] = "\tstep28 := 2800"
        let rightBuf = TextBuffer(lines: rightLines)
        let hunks = [
            Hunk(leftStart: 12, leftCount: 1, rightStart: 12, rightCount: 1),
            Hunk(leftStart: 32, leftCount: 1, rightStart: 32, rightCount: 1),
        ]
        let doc = DiffDocument(left: leftBuf, right: rightBuf, hunks: hunks, language: .go)

        viewer.request = DiffRequest(root: URL(fileURLWithPath: "/tmp"), path: "engine.go", oldPath: nil, kind: .modified, source: .file)
        viewer.document = doc
        viewer.hunkCount = hunks.count
        container.show(doc, mode: .sideBySide, preserveScroll: false)
        container.layoutSubtreeIfNeeded()
        container.canvas.flush()

        let lh = container.canvas.codeFont.lineHeight
        XCTAssertEqual(container.canvas.visibleStickyLines.left.count, 0)
        XCTAssertEqual(container.canvas.visibleStickyLines.right.count, 0)

        // Scroll inside `Run` (line index 4).
        container.scroll(toY: 12 * lh, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.left.map(\.scope.sourceLine), [4])
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])
        XCTAssertEqual(container.canvas.stickyHeight(for: .right), lh)

        // Clicking sticky header for `Run` un-pins it and lands caret on line 4.
        viewer.canvas(container.canvas, didClickStickyLine: 4, side: .right, slotIndex: 0)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.activeCaretPosition()?.row, 4)
        XCTAssertTrue(container.canvas.visibleStickyLines.right.isEmpty)

        // Unified mode pins properly.
        container.setMode(.unified)
        container.scroll(toY: 14 * lh, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])

        // Folding mode keeps sticky scopes aligned with folded display rows.
        settings.collapseUnchanged = true
        viewer.syncSemanticOptions()
        container.canvas.setFolding(enabled: true, expandedSegments: [])
        container.scroll(toY: 8 * lh, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])

        // revealCaret keeps caret below sticky line when moving up.
        container.canvas.setFolding(enabled: false, expandedSegments: [])
        container.setMode(.sideBySide)
        container.scroll(toY: 12 * lh, animated: false)
        container.canvas.flush()
        container.canvas.placeCaret(line: 12, column: 0)
        container.canvas.revealCaret()
        container.canvas.flush()
        let caretScreenY = CGFloat(container.canvas.editRow(forLine: 12)) * lh - container.scrollY
        XCTAssertGreaterThanOrEqual(caretScreenY, container.canvas.stickyHeight(for: .right))

        // Vim `zt` (`scrollYBelowSticky`) places line 12 right below sticky header `Run`.
        let ztY = container.canvas.scrollYBelowSticky(forLine: 12, side: .right)
        container.scroll(toY: ztY, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])
        XCTAssertGreaterThanOrEqual(CGFloat(12) * lh - container.scrollY, container.canvas.stickyHeight(for: .right) - 0.5)

        // Plain file (.single) mode & live edit shifting (`performEdit`).
        let plainDoc = DiffDocument(left: .empty, right: TextBuffer(lines: lines), hunks: [], language: .go, isPlainFile: true)
        plainDoc.editing = EditInfo(format: TextFormat(), crlf: nil, fingerprint: Data(), base: nil, readOnlyReason: nil)
        viewer.document = plainDoc
        container.show(plainDoc, mode: .single, preserveScroll: false)
        container.canvas.editor = EditorSession(document: plainDoc, root: URL(fileURLWithPath: "/tmp"), path: "plain.go", ignoreWhitespace: false)
        container.scroll(toY: 44 * lh, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])
        container.canvas.performEdit(anchorLine: 10) {
            guard let ed = container.canvas.editor else { return [] }
            return [ed.replace(from: TextPosition(row: 10, column: 0), to: TextPosition(row: 10, column: 0), with: "\t// a\n\t// b\n", kind: .typing, selection: (TextPosition(row: 10, column: 0), TextPosition(row: 10, column: 0)))]
        }
        container.scroll(toY: 46 * lh, animated: false)
        container.canvas.flush()
        XCTAssertEqual(container.canvas.visibleStickyLines.right.map(\.scope.sourceLine), [4])

        // Disabling stickyLines clears overlays.
        viewer.setStickyLines(false)
        container.canvas.flush()
        XCTAssertTrue(container.canvas.visibleStickyLines.right.isEmpty)
        XCTAssertEqual(container.canvas.stickyHeight(for: .right), 0)
    }

    @MainActor
    func testCommandAndContextMenuForStickyLine() {
        let store = AppStore.shared
        let savedSticky = store.settings.stickyLines
        let savedRequest = store.viewer.request
        let savedDocument = store.viewer.document
        let savedContainer = store.viewer.container
        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        container.layoutSubtreeIfNeeded()
        defer {
            store.viewer.setStickyLines(savedSticky)
            container.canvas.noteContextStickyLine(nil)
            store.viewer.container = savedContainer
            store.viewer.request = savedRequest
            store.viewer.document = savedDocument
        }

        guard let cmd = store.commands.first(where: { $0.id == "view.stickyLines" }) else {
            return XCTFail("Missing view.stickyLines command")
        }
        cmd.action()
        XCTAssertEqual(store.settings.stickyLines, !savedSticky)
        cmd.action()
        XCTAssertEqual(store.settings.stickyLines, savedSticky)

        let doc = DiffDocument(left: .empty, right: TextBuffer(lines: ["func A() {", "\treturn", "}"]), hunks: [], language: .go, isPlainFile: true)
        store.viewer.container = container
        store.viewer.request = DiffRequest(root: URL(fileURLWithPath: "/tmp"), path: "a.go", oldPath: nil, kind: nil, source: .file)
        store.viewer.document = doc
        container.show(doc, mode: .single, preserveScroll: false)
        container.canvas.noteContextStickyLine((side: .right, line: 0))
        let menuTitles = store.viewerContextMenu()?.items.map(\.title) ?? []
        XCTAssertTrue(menuTitles.contains { $0.contains("1") })
        XCTAssertTrue(menuTitles.contains { $0.contains("Sticky Lines") || $0.contains("粘性行") })
    }
}
