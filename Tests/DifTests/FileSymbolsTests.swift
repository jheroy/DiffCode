import Foundation
import XCTest
@testable import DifKit

final class FileSymbolsTests: XCTestCase {
    // MARK: - Go Symbol Extraction

    func testGoExtractsFunctionsMethodsTypesAndConstants() {
        let source = """
        package service

        import "context"

        const Version = "1.0.0"

        const (
        \t_ = iota
        \tStatusPending Status = iota
        \tStatusActive
        \tMaxFlags = FlagA |
        \t\tFlagB
        )

        type Status int
        type ID = int64

        type Manager struct {
        \tdb string
        }

        type Pair[K comparable, V any] struct {
        \tKey K
        \tVal V
        }

        type Reader interface {
        \tRead(p []byte) (int, error)
        }

        type (
        \t// grouped declarations
        \tGroupedStruct struct {
        \t\tField int
        \t}
        \tGroupedIface interface {
        \t\tClose() error
        \t}
        \tGroupedAlias = string
        \tGroupedType uint64
        )

        func NewManager(dsn string) *Manager {
        \tconst localConst = 42
        \tclosure := func() int { return localConst }
        \t_ = closure()
        \treturn &Manager{db: dsn}
        }

        func MapSlice[T any, U comparable](in []T, fn func(T) U) []U {
        \treturn nil
        }

        func (m *Manager) DeleteSignup(ctx context.Context, lid int64) error {
        \treturn nil
        }

        func (m Manager) helper() string {
        \treturn m.db
        }

        func (*Manager) Close() error {
        \treturn nil
        }

        func (c *Cache[K, V]) Get(key K) (V, bool) {
        \tvar zero V
        \treturn zero, false
        }
        """

        let lines = source.components(separatedBy: "\n")
        let symbols = FileSymbolExtractor.extract(lines: lines, language: .go)

        let summary = symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertEqual(summary, [
            "constant:Version",
            "constant:StatusPending",
            "constant:StatusActive",
            "constant:MaxFlags",
            "type:Status",
            "type:ID",
            "struct:Manager",
            "struct:Pair",
            "interface:Reader",
            "struct:GroupedStruct",
            "interface:GroupedIface",
            "type:GroupedAlias",
            "type:GroupedType",
            "function:NewManager",
            "function:MapSlice",
            "method:DeleteSignup",
            "method:helper",
            "method:Close",
            "method:Get",
        ])

        // Verify exported flags and exact UTF-16 column range for pointer receiver method.
        let deleteSignup = try? XCTUnwrap(symbols.first { $0.name == "DeleteSignup" })
        XCTAssertEqual(deleteSignup?.kind, .method)
        XCTAssertEqual(deleteSignup?.isExported, true)
        XCTAssertTrue(deleteSignup?.detail.contains("(*Manager)") == true)
        XCTAssertTrue(deleteSignup?.detail.contains("lid int64") == true)
        if let sym = deleteSignup {
            let lineNS = lines[sym.lineNumber - 1] as NSString
            let extracted = lineNS.substring(with: NSRange(location: sym.column, length: sym.endColumn - sym.column))
            XCTAssertEqual(extracted, "DeleteSignup")
        }

        // Verify unexported method.
        let helper = symbols.first { $0.name == "helper" }
        XCTAssertEqual(helper?.isExported, false)
        XCTAssertTrue(helper?.detail.hasPrefix("(Manager)") == true)

        // Verify generic receiver method.
        let cacheGet = symbols.first { $0.name == "Get" }
        XCTAssertEqual(cacheGet?.kind, .method)
        XCTAssertTrue(cacheGet?.detail.hasPrefix("(*Cache[K, V])") == true)

        // Verify generic struct detail.
        let pair = symbols.first { $0.name == "Pair" }
        XCTAssertEqual(pair?.kind, .struct)
        XCTAssertEqual(pair?.detail, "[K comparable, V any] struct")
    }

    func testGoIgnoresCommentsAndRawBacktickStrings() {
        let source = """
        package ignore

        // func CommentedLine() {}
        // type CommentedType struct {}
        /*
        func InBlockComment() {}
        type AlsoInBlock struct {}
        const BlockConst = 1
        */
        const Template = `
        func InsideRawString() {}
        type RawStruct struct {}
        const RawConst = 2
        `

        const InlineStr = "func InsideDoubleQuotes() {}"

        /* leading block comment */ func RealFunc() {}
        """

        let lines = source.components(separatedBy: "\n")
        let symbols = FileSymbolExtractor.extract(lines: lines, language: .go)

        XCTAssertEqual(symbols.map(\.name), ["Template", "InlineStr", "RealFunc"])
        XCTAssertEqual(symbols.map(\.kind), [.constant, .constant, .function])

        // Check exact UTF-16 column for RealFunc after leading inline block comment.
        let realFunc = symbols[2]
        let lineNS = lines[realFunc.lineNumber - 1] as NSString
        XCTAssertEqual(
            lineNS.substring(with: NSRange(location: realFunc.column, length: realFunc.endColumn - realFunc.column)),
            "RealFunc"
        )
    }

    // MARK: - Other Languages Smoke Tests

    func testSwiftExtractionSmoke() {
        let source = """
        import Foundation

        // func CommentedOut() {}
        let doc = \"\"\"
        struct NotARealStruct {}
        \"\"\"

        @MainActor
        public struct Widget: Sendable {
            func render() {}
            private func helper() {}
        }

        protocol Renderable {}
        actor Engine {}
        enum Mode { case fast }
        typealias WidgetID = String
        extension Widget: Renderable {}
        func topLevel() {}
        """

        let symbols = FileSymbolExtractor.extract(lines: source.components(separatedBy: "\n"), language: .swift)
        let summary = symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertEqual(summary, [
            "struct:Widget",
            "method:render",
            "method:helper",
            "interface:Renderable",
            "class:Engine",
            "enum:Mode",
            "type:WidgetID",
            "type:Widget",
            "function:topLevel",
        ])
        XCTAssertEqual(symbols.first { $0.name == "helper" }?.isExported, false)
        XCTAssertEqual(symbols.first { $0.name == "Widget" }?.isExported, true)
    }

    func testPythonExtractionSmoke() {
        let source = """
        # def commented_fn(): pass

        \"\"\"
        class FakeClass:
            def fake_method(self):
                pass
        \"\"\"

        def top_func(a, b):
            return a + b

        class Service:
            def __init__(self, url):
                self.url = url

            async def fetch_data(self, id: int) -> dict:
                return {}

        async def run_all():
            pass
        """

        let symbols = FileSymbolExtractor.extract(lines: source.components(separatedBy: "\n"), language: .python)
        let summary = symbols.map { "\($0.kind.rawValue):\($0.name)" }
        XCTAssertEqual(summary, [
            "function:top_func",
            "class:Service",
            "method:__init__",
            "method:fetch_data",
            "function:run_all",
        ])
        XCTAssertEqual(symbols.first { $0.name == "__init__" }?.isExported, false)
        XCTAssertEqual(symbols.first { $0.name == "fetch_data" }?.isExported, true)
    }

    func testRustAndTypeScriptExtractionSmoke() {
        let rustSource = """
        pub struct Store<'a> { name: &'a str }
        pub enum State { Idle }
        pub trait Runner { fn run(&self); }
        impl<'a> Runner for Store<'a> {
            fn run(&self) {}
        }
        pub fn start() {}
        """
        let rustSymbols = FileSymbolExtractor.extract(lines: rustSource.components(separatedBy: "\n"), language: .rust)
        XCTAssertTrue(rustSymbols.contains { $0.kind == .struct && $0.name == "Store" })
        XCTAssertTrue(rustSymbols.contains { $0.kind == .enum && $0.name == "State" })
        XCTAssertTrue(rustSymbols.contains { $0.kind == .interface && $0.name == "Runner" })
        XCTAssertTrue(rustSymbols.contains { $0.kind == .type && $0.name == "Store" && $0.detail.contains("impl") })
        XCTAssertTrue(rustSymbols.contains { $0.kind == .function && $0.name == "start" })

        let tsSource = """
        export interface User { id: string }
        export type UserID = string
        export enum Role { Admin }
        export class AuthClient {}
        export function login(u: string) {}
        export const logout = async (id: string) => {}
        """
        let tsSymbols = FileSymbolExtractor.extract(lines: tsSource.components(separatedBy: "\n"), language: .javascript)
        XCTAssertEqual(tsSymbols.map { "\($0.kind.rawValue):\($0.name)" }, [
            "interface:User",
            "type:UserID",
            "enum:Role",
            "class:AuthClient",
            "function:login",
            "function:logout",
        ])

        let cppSource = """
        #include <string>
        struct Node { int val; };
        class Engine { };
        enum class Mode { Fast, Safe };
        int compute(int a, int b) {
            return a + b;
        }
        void Engine::start() {
        }
        """
        let cppSymbols = FileSymbolExtractor.extract(lines: cppSource.components(separatedBy: "\n"), language: .cFamily)
        XCTAssertEqual(cppSymbols.map { "\($0.kind.rawValue):\($0.name)" }, [
            "struct:Node",
            "class:Engine",
            "enum:Mode",
            "function:compute",
            "method:start",
        ])
        XCTAssertEqual(PopupSizeSpec.fileSymbols.defaultSize, CGSize(width: 840, height: 540))
        XCTAssertEqual(PopupSizeSpec.fileSymbols.minSize, CGSize(width: 560, height: 340))
        XCTAssertEqual(PopupSizeSpec.fileSymbols.userDefaultsKey, "popupSize.fileSymbols")
    }

    // MARK: - FileSymbolsModel Tests

    @MainActor
    func testModelPreselectsNearestSymbolToCursorLine() {
        let lines = [
            "package app",                                    // 1
            "",                                               // 2
            "type Manager struct {",                          // 3
            "\tid int",                                       // 4
            "}",                                              // 5
            "",                                               // 6
            "func (m *Manager) Start() {",                    // 7
            "\t// line 8",                                    // 8
            "\t// line 9",                                    // 9
            "}",                                              // 10
            "",                                               // 11
            "func (m *Manager) Stop() {",                     // 12
            "\t// line 13",                                   // 13
            "}",                                              // 14
        ]
        let model = FileSymbolsModel()

        // Cursor above first symbol selects index 0 (Manager).
        model.prepare(title: "manager.go", lines: lines, language: .go, cursorLine: 1)
        XCTAssertEqual(model.selectedItem?.name, "Manager")

        // Cursor inside Start() body (line 9) selects Start.
        model.prepare(title: "manager.go", lines: lines, language: .go, cursorLine: 9)
        XCTAssertEqual(model.selectedItem?.name, "Start")

        // Cursor on exact declaration line 12 selects Stop.
        model.prepare(title: "manager.go", lines: lines, language: .go, cursorLine: 12)
        XCTAssertEqual(model.selectedItem?.name, "Stop")
    }

    @MainActor
    func testModelFuzzyFilterMatchesNameAndReceiverDetailAndKindPills() {
        let lines = [
            "package app",
            "type AuthManager struct {}",
            "type Cache struct {}",
            "const DefaultTTL = 60",
            "func (m *AuthManager) DeleteSignup(lid int64) error { return nil }",
            "func (c *Cache) EvictAll() {}",
            "func parseToken(raw string) string { return raw }",
        ]
        let model = FileSymbolsModel()
        model.prepare(title: "auth.go", lines: lines, language: .go, cursorLine: 1)
        XCTAssertEqual(model.allItems.count, 6)

        // Fuzzy query on camelCase humps of function name.
        model.filterQuery = "DS"
        XCTAssertEqual(model.filteredItems.first?.name, "DeleteSignup")
        XCTAssertFalse(model.positions(for: model.filteredItems[0]).isEmpty)

        // Query matching receiver name in detail (`AuthManager` matches both type & its method).
        model.filterQuery = "AuthManager"
        let names = model.filteredItems.map(\.name)
        XCTAssertTrue(names.contains("AuthManager"))
        XCTAssertTrue(names.contains("DeleteSignup"))

        // Combine text query with `.functions` kind filter pill -> only `DeleteSignup` remains!
        model.kindFilter = .functions
        XCTAssertEqual(model.filteredItems.map(\.name), ["DeleteSignup"])

        // Switch to `.types` with empty query -> only struct/type entries remain in file order.
        model.filterQuery = ""
        model.kindFilter = .types
        XCTAssertEqual(model.filteredItems.map(\.name), ["AuthManager", "Cache"])

        // Cycle filter cycles cleanly through all cases.
        model.cycleFilter(1)
        XCTAssertEqual(model.kindFilter, .all)
        XCTAssertEqual(model.filteredItems.count, 6)
    }

    @MainActor
    func testModelBuildsHighlightedPreviewContext() throws {
        let lines = [
            "package demo",
            "",
            "// DeleteSignup removes a signup record.",
            "func (m *Manager) DeleteSignup(lid int64) error {",
            "\treturn nil",
            "}",
        ]
        let model = FileSymbolsModel()
        model.prepare(
            title: "demo.go",
            displayPath: "pkg/demo.go",
            fileURL: URL(fileURLWithPath: "/tmp/demo.go"),
            lines: lines,
            language: .go,
            cursorLine: 4
        )

        let ctx = try XCTUnwrap(model.previewContext)
        XCTAssertEqual(ctx.matchedLineNumber, 4)
        XCTAssertEqual(ctx.displayPath, "pkg/demo.go")
        let matched = try XCTUnwrap(ctx.lines.first { $0.isMatchedLine })
        XCTAssertEqual(matched.lineNumber, 4)
        let hl = try XCTUnwrap(matched.highlightRange)
        let nsLine = matched.text as NSString
        XCTAssertEqual(nsLine.substring(with: NSRange(location: hl.lowerBound, length: hl.count)), "DeleteSignup")
        XCTAssertFalse(matched.spans.isEmpty)
    }

    @MainActor
    func testActivatePushesJumpHistoryOriginAndRevealsTargetLine() {
        let store = AppStore.shared
        let savedRequest = store.viewer.request
        let savedDocument = store.viewer.document
        let savedPopup = store.popup
        let savedHistory = store.jumpHistory
        let savedCursorLine = store.viewer.vimCursorLine
        let savedCursorCol = store.viewer.vimCursorColumn
        defer {
            store.viewer.request = savedRequest
            store.viewer.document = savedDocument
            store.popup = savedPopup
            store.jumpHistory = savedHistory
            store.viewer.vimCursorLine = savedCursorLine
            store.viewer.vimCursorColumn = savedCursorCol
            store.fileSymbols.release()
        }

        let lines = [
            "package jump",
            "func First() {}",
            "",
            "func Second() {}",
            "",
            "func Third() {}",
        ]
        let buf = TextBuffer(lines: lines)
        buf.spans = Highlighter.highlight(lines, language: .go)
        let doc = DiffDocument(left: .empty, right: buf, hunks: [], language: .go, isPlainFile: true)
        let req = DiffRequest(root: URL(fileURLWithPath: "/tmp"), path: "jump.go", oldPath: nil, kind: nil, source: .file)

        store.jumpHistory = JumpHistory()
        store.viewer.request = req
        store.viewer.document = doc
        store.viewer.vimCursorLine = 2
        store.viewer.vimCursorColumn = 1

        store.showFileSymbols()
        XCTAssertEqual(store.popup, .fileSymbols)
        XCTAssertEqual(store.fileSymbols.selectedItem?.name, "First")

        // Select `Third` (line 6) and activate.
        guard let thirdIndex = store.fileSymbols.filteredItems.firstIndex(where: { $0.name == "Third" }) else {
            return XCTFail("Expected symbol Third")
        }
        store.fileSymbols.activate(thirdIndex)

        XCTAssertNil(store.popup)
        XCTAssertTrue(store.jumpHistory.canGoBack, "Activating a symbol should push the origin onto jumpHistory")
        XCTAssertEqual(store.viewer.vimCursorLine, 6)

        // Navigating back pops the origin line (line 2).
        let backTarget = store.jumpHistory.back(from: nil)
        XCTAssertEqual(backTarget?.line, 2)
    }

    @MainActor
    func testPrepareFallsBackToLeftSideForDeletedOnlyDocument() {
        let store = AppStore.shared
        let savedRequest = store.viewer.request
        let savedDocument = store.viewer.document
        defer {
            store.viewer.request = savedRequest
            store.viewer.document = savedDocument
            store.fileSymbols.release()
        }

        let leftLines = [
            "package deleted",
            "type Legacy struct {}",
            "func OldEntry() {}",
        ]
        let leftBuf = TextBuffer(lines: leftLines)
        leftBuf.spans = Highlighter.highlight(leftLines, language: .go)
        let doc = DiffDocument(left: leftBuf, right: .empty, hunks: [], language: .go, isPlainFile: false)
        let req = DiffRequest(root: URL(fileURLWithPath: "/tmp"), path: "deleted.go", oldPath: nil, kind: .deleted, source: .file)

        store.viewer.request = req
        store.viewer.document = doc
        store.fileSymbols.prepare()

        XCTAssertEqual(store.fileSymbols.allItems.map(\.name), ["Legacy", "OldEntry"])
        XCTAssertNotNil(store.fileSymbols.previewContext)
    }
}
