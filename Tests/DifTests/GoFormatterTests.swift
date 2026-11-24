import Foundation
import XCTest
@testable import DifKit

final class GoFormatterTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-gofmt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeGoSession(text: String, fileURL: URL) throws -> EditorSession {
        let data = Data(text.utf8)
        let editable = try XCTUnwrap(TextCodec.decodeForEditing(data))
        let right = TextBuffer(lines: editable.lines)
        let colours = Highlighter.highlightTracking(editable.lines, language: .go)
        right.spans = colours.spans
        right.states = colours.states
        let doc = DiffDocument(left: .empty, right: right, hunks: [], language: .go, isPlainFile: true)
        doc.editing = EditInfo(format: editable.format, crlf: editable.crlf, fingerprint: TextCodec.fingerprint(data))
        return try XCTUnwrap(EditorSession(
            document: doc,
            root: fileURL.deletingLastPathComponent(),
            path: fileURL.lastPathComponent,
            ignoreWhitespace: false
        ))
    }

    func testIsGoFileDetectsExtensionCaseInsensitively() {
        XCTAssertTrue(GoFormatter.isGoFile(URL(fileURLWithPath: "/tmp/main.go")))
        XCTAssertTrue(GoFormatter.isGoFile(URL(fileURLWithPath: "/tmp/MAIN.GO")))
        XCTAssertTrue(GoFormatter.isGoFile(path: "pkg/handler_test.go"))
        XCTAssertFalse(GoFormatter.isGoFile(URL(fileURLWithPath: "/tmp/main.swift")))
        XCTAssertFalse(GoFormatter.isGoFile(URL(fileURLWithPath: "/tmp/go.mod")))
        XCTAssertFalse(GoFormatter.isGoFile(path: "README.md"))
    }

    func testMappedPositionPreservesLineAndLogicalColumnAcrossFormatting() {
        let oldLines = [
            "package main",
            "",
            "",
            "func main() {",
            "    fmt.Println( \"hi\" )",
            "}",
        ]
        let newLines = [
            "package main",
            "",
            "func main() {",
            "\tfmt.Println(\"hi\")",
            "}",
        ]

        // Caret right after `"hi"` on the reformatted call line.
        let oldPos = TextPosition(row: 4, column: 21) // `    fmt.Println( "hi"`
        let mapped = GoFormatter.mappedPosition(oldPos, from: oldLines, to: newLines)
        XCTAssertEqual(mapped, TextPosition(row: 3, column: 17)) // `\tfmt.Println("hi"`

        // Caret inside leading indentation moves to the new indentation end.
        let indentMapped = GoFormatter.mappedPosition(TextPosition(row: 4, column: 2), from: oldLines, to: newLines)
        XCTAssertEqual(indentMapped, TextPosition(row: 3, column: 1))
    }

    func testApplyFormattedTextSupportsDisjointHunksFinalNewlineUndoAndRedo() throws {
        let dir = try makeTempDir()
        let fileURL = dir.appendingPathComponent("sample.go")
        let unformatted = "package main\n\nfunc a(){\n    x:=1\n}\n\nfunc b(){\n    y:=2\n}"
        try Data(unformatted.utf8).write(to: fileURL)

        let formatted = "package main\n\nfunc a() {\n\tx := 1\n}\n\nfunc b() {\n\ty := 2\n}\n"
        let formattedData = Data(formatted.utf8)
        let formattedText = try XCTUnwrap(TextCodec.decodeForEditing(formattedData))

        let session = try makeGoSession(text: unformatted, fileURL: fileURL)
        let before: EditorSession.Selection = (TextPosition(row: 3, column: 8), TextPosition(row: 3, column: 8))
        let after: EditorSession.Selection = (TextPosition(row: 3, column: 7), TextPosition(row: 3, column: 7))

        session.applyFormattedText(formattedText, data: formattedData, selectionBefore: before, selectionAfter: after)
        XCTAssertFalse(session.isDirty)
        XCTAssertEqual(session.encoded(), formattedData)
        XCTAssertEqual(session.buffer.lines, formattedText.lines)

        let undone = try XCTUnwrap(session.undo())
        XCTAssertEqual(undone.selection.head, before.head)
        XCTAssertEqual(session.encoded(), Data(unformatted.utf8))
        XCTAssertTrue(session.isDirty)

        let redone = try XCTUnwrap(session.redo())
        XCTAssertEqual(redone.selection.head, after.head)
        XCTAssertEqual(session.encoded(), formattedData)
    }

    func testFormatSkipsNonGoFilesAndInvalidSyntax() async throws {
        let env = LSPBinaryLocator.environment()
        let paths = LSPBinaryLocator.searchPaths(from: env)
        try XCTSkipUnless(
            LSPBinaryLocator.resolve(executable: "gofmt", searchPaths: paths) != nil
                || LSPBinaryLocator.resolve(executable: "go", searchPaths: paths) != nil,
            "Go toolchain not installed"
        )

        let nonGo = await GoFormatter.format(Data("func main(){}".utf8), fileURL: URL(fileURLWithPath: "/tmp/a.txt"))
        XCTAssertNil(nonGo)

        let invalid = await GoFormatter.format(Data("package main\nfunc broken( {\n".utf8), fileURL: URL(fileURLWithPath: "/tmp/broken.go"))
        XCTAssertNil(invalid)

        let validInput = Data("package main\nfunc main(){\nx:=1\n_ = x\n}\n".utf8)
        let formatted = await GoFormatter.format(validInput, fileURL: URL(fileURLWithPath: "/tmp/valid.go"))
        XCTAssertEqual(
            formatted.map { String(decoding: $0, as: UTF8.self) },
            "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n"
        )
    }

    @MainActor
    func testViewerSaveFormatsGoFileAndLeavesNonGoFilesAlone() async throws {
        let dir = try makeTempDir()
        let goURL = dir.appendingPathComponent("main.go")
        let initialGo = "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n"
        try Data(initialGo.utf8).write(to: goURL)

        let settings = Settings(defaults: UserDefaults(suiteName: "GoFormatterTests-\(UUID().uuidString)")!)
        settings.formatGoOnSave = true

        let viewer = ViewerModel()
        viewer.settings = settings
        viewer.goFormatter = { data, url in
            guard GoFormatter.isGoFile(url) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            return Data(text.replacingOccurrences(of: "x:=2", with: "x := 2").utf8)
        }

        let goRequest = DiffRequest(root: dir, path: "main.go", source: .file)
        viewer.request = goRequest
        let goSession = try makeGoSession(text: initialGo, fileURL: goURL)
        viewer.document = goSession.document
        viewer.editor = goSession
        viewer.signature = ViewerModel.signature(for: goRequest, base: nil)

        // Simulate editing `x := 1` -> `x:=2` and saving.
        _ = goSession.replace(
            from: TextPosition(row: 3, column: 1),
            to: TextPosition(row: 3, column: 7),
            with: "x:=2",
            kind: .typing,
            selection: (TextPosition(row: 3, column: 7), TextPosition(row: 3, column: 7))
        )
        XCTAssertTrue(viewer.saveEdits(formatGo: true))
        XCTAssertEqual(try String(contentsOf: goURL, encoding: .utf8), "package main\n\nfunc main() {\n\tx:=2\n\t_ = x\n}\n")

        await viewer.formatTask?.value

        XCTAssertEqual(try String(contentsOf: goURL, encoding: .utf8), "package main\n\nfunc main() {\n\tx := 2\n\t_ = x\n}\n")
        XCTAssertFalse(goSession.isDirty)
        XCTAssertEqual(goSession.buffer.lines[3], "\tx := 2")

        // When disabled in Settings, saving does not reformat.
        settings.formatGoOnSave = false
        _ = goSession.replace(
            from: TextPosition(row: 3, column: 1),
            to: TextPosition(row: 3, column: 7),
            with: "x:=2",
            kind: .typing,
            selection: (TextPosition(row: 3, column: 7), TextPosition(row: 3, column: 7))
        )
        XCTAssertTrue(viewer.saveEdits(formatGo: true))
        await viewer.formatTask?.value
        XCTAssertEqual(try String(contentsOf: goURL, encoding: .utf8), "package main\n\nfunc main() {\n\tx:=2\n\t_ = x\n}\n")
    }
}
