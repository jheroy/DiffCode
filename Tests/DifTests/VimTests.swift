import AppKit
import XCTest
@testable import DifKit

// MARK: - Test Doubles

private final class SpyInputSourceController: VimInputSourceControlling {
    var switchToEnglishCount = 0
    var restoreCount = 0

    func switchToEnglishAndRememberCurrent() { switchToEnglishCount += 1 }
    func restoreRememberedInputSource() { restoreCount += 1 }
}

private final class VimHarness {
    var lines: [String]
    var cursor: TextPosition
    var isEditable: Bool
    var indentUnit: String
    var commentPrefix: String
    var clipboard: String = ""
    var visualRange: VimVisualRange?
    var actions: [VimAction] = []
    let inputSpy = SpyInputSourceController()
    let engine: VimEngine

    init(
        _ text: String,
        cursor: TextPosition = TextPosition(row: 0, column: 0),
        isEditable: Bool = true,
        indentUnit: String = "    ",
        commentPrefix: String = "//"
    ) {
        self.lines = TextEditing.lines(of: text)
        self.cursor = cursor
        self.isEditable = isEditable
        self.indentUnit = indentUnit
        self.commentPrefix = commentPrefix
        var box: VimHarness?
        self.engine = VimEngine(
            inputSource: inputSpy,
            readClipboard: { box?.clipboard },
            writeClipboard: { box?.clipboard = $0 }
        )
        box = self
    }

    var text: String { lines.joined(separator: "\n") }

    @discardableResult
    func send(_ key: VimKey) -> VimResult {
        let ctx = VimContext(
            lines: lines,
            cursor: cursor,
            isEditable: isEditable,
            indentUnit: indentUnit,
            commentPrefix: commentPrefix,
            visibleLineCount: 20
        )
        let result = engine.handleKey(key, context: ctx)
        if result.passThroughToInsert, case .character(let ch) = key.kind, !key.control, isEditable {
            TextEditing.replace(&lines, from: cursor, to: cursor, with: ch)
            cursor = TextPosition(row: cursor.row, column: cursor.column + (ch as NSString).length)
            engine.recordInsertedText(ch)
            return result
        }
        if !result.edits.isEmpty {
            for edit in result.edits {
                TextEditing.replace(&lines, from: edit.from, to: edit.to, with: edit.text)
            }
        }
        if let vr = result.visualRange {
            visualRange = vr
            cursor = TextEditing.clamp(vr.head, in: lines)
        } else if result.clearVisual {
            visualRange = nil
            if let c = result.cursor { cursor = TextEditing.clamp(c, in: lines) }
        } else if let c = result.cursor {
            cursor = TextEditing.clamp(c, in: lines)
        }
        actions.append(contentsOf: result.actions)
        return result
    }

    func type(_ seq: String) {
        for ch in seq {
            send(VimKey(String(ch)))
        }
    }

    func selectedVisualText() -> String? {
        guard let vr = visualRange else { return nil }
        if vr.linewise {
            let first = min(vr.anchor.row, vr.head.row)
            let last = max(vr.anchor.row, vr.head.row)
            return lines[first...last].joined(separator: "\n")
        }
        let lo = min(vr.anchor, vr.head)
        let hi = max(vr.anchor, vr.head)
        let hiNS = lines[hi.row] as NSString
        let hiEnd = hi.column < hiNS.length
            ? TextEditing.characterBoundary(in: hiNS, from: hi.column, forward: true)
            : hiNS.length
        return TextEditing.text(lines, from: lo, to: TextPosition(row: hi.row, column: hiEnd))
    }
}

// MARK: - VimTests

final class VimTests: XCTestCase {
    private func p(_ row: Int, _ col: Int) -> TextPosition { TextPosition(row: row, column: col) }

    // MARK: 1. Normal Motions & Counts

    func testBasicMotionsAndCounts() {
        let h = VimHarness("  alpha beta gamma\nsecond line\nthird line\nfourth line\nfifth line\nsixth line")
        h.type("5j")
        XCTAssertEqual(h.cursor.row, 5)
        h.type("2k")
        XCTAssertEqual(h.cursor.row, 3)
        h.type("gg")
        XCTAssertEqual(h.cursor, p(0, 2))
        h.type("0")
        XCTAssertEqual(h.cursor, p(0, 0))
        h.type("^")
        XCTAssertEqual(h.cursor, p(0, 2))
        h.type("$")
        XCTAssertEqual(h.cursor, p(0, 17))
        h.type("3h")
        XCTAssertEqual(h.cursor, p(0, 14))
        h.type("2l")
        XCTAssertEqual(h.cursor, p(0, 16))
        h.type("G")
        XCTAssertEqual(h.cursor.row, 5)
        h.type("3G")
        XCTAssertEqual(h.cursor.row, 2)
    }

    func testWordAndWORDMotions() {
        let h = VimHarness("foo.bar baz_qux  end")
        h.type("w") // '.'
        XCTAssertEqual(h.cursor, p(0, 3))
        h.type("w") // 'bar'
        XCTAssertEqual(h.cursor, p(0, 4))
        h.type("e") // end of 'bar'
        XCTAssertEqual(h.cursor, p(0, 6))
        h.type("w") // 'baz_qux'
        XCTAssertEqual(h.cursor, p(0, 8))
        h.type("b") // 'bar'
        XCTAssertEqual(h.cursor, p(0, 4))
        h.type("0")
        h.type("W") // skips 'foo.bar' as one WORD -> 'baz_qux'
        XCTAssertEqual(h.cursor, p(0, 8))
        h.type("E") // end of 'baz_qux'
        XCTAssertEqual(h.cursor, p(0, 14))
        h.type("B") // back to 'baz_qux'
        XCTAssertEqual(h.cursor, p(0, 8))
        h.type("B") // back to 'foo.bar'
        XCTAssertEqual(h.cursor, p(0, 0))
    }

    func testFindCharAndRepeat() {
        let h = VimHarness("a, b, c, d, e")
        h.type("f,")
        XCTAssertEqual(h.cursor, p(0, 1))
        h.type(";")
        XCTAssertEqual(h.cursor, p(0, 4))
        h.type("2;")
        XCTAssertEqual(h.cursor, p(0, 10))
        h.type(",")
        XCTAssertEqual(h.cursor, p(0, 7))
        h.type("0")
        h.type("tc")
        XCTAssertEqual(h.cursor, p(0, 5))
        h.type("$")
        h.type("Fb")
        XCTAssertEqual(h.cursor, p(0, 3))
        h.type("T,")
        XCTAssertEqual(h.cursor, p(0, 2))
    }

    func testMatchingAndEnclosingBracketMotions() {
        let code = """
        func outer(a int, b int) {
            if (a > 0) {
                fmt.Println(a + b)
            }
        }
        """
        let h = VimHarness(code, cursor: p(0, 10)) // on '('
        h.type("%")
        XCTAssertEqual(h.cursor, p(0, 23)) // matching ')'
        h.type("%")
        XCTAssertEqual(h.cursor, p(0, 10)) // back to '('

        // Enclosing unmatched brackets: ~/.ideavimrc:81-84 `( -> [(`, `) -> ])`, `{ -> [{`, `} -> ]}`
        h.cursor = p(2, 22) // inside `Println(a + b)` on '+'
        h.type("(")
        XCTAssertEqual(h.cursor, p(2, 19)) // '(' of Println(...)
        h.type(")")
        XCTAssertEqual(h.cursor, p(2, 25)) // ')' of Println(...)

        h.cursor = p(2, 12)
        h.type("{")
        XCTAssertEqual(h.cursor, p(1, 15)) // '{' of `if (a > 0) {`
        h.type("{")
        XCTAssertEqual(h.cursor, p(0, 25)) // '{' of `func outer`
        h.type("}")
        XCTAssertEqual(h.cursor, p(4, 0)) // closing '}' of `func outer`
    }

    func testMethodJumpsAcrossLanguages() {
        let code = """
        package main

        func first() {
            x := 1
        }

        func (s *Srv) second() {
            y := 2
        }

        public static func third() {
            let z = 3
        }
        """
        let h = VimHarness(code, cursor: p(0, 0))
        h.type("]]")
        XCTAssertEqual(h.cursor.row, 2)
        h.type("]]")
        XCTAssertEqual(h.cursor.row, 6)
        h.type("]]")
        XCTAssertEqual(h.cursor.row, 10)
        h.type("[[")
        XCTAssertEqual(h.cursor.row, 6)
        h.type("[[")
        XCTAssertEqual(h.cursor.row, 2)
    }

    // MARK: 2. Operators, Text Objects, Commentary, Put, Dot-Repeat

    func testDeleteLinesWordAndClipboardSync() {
        let h = VimHarness("one\ntwo\nthree\nfour")
        h.type("dd")
        XCTAssertEqual(h.text, "two\nthree\nfour")
        XCTAssertEqual(h.clipboard, "one\n")

        h.type("2dd")
        XCTAssertEqual(h.text, "four")
        XCTAssertEqual(h.clipboard, "two\nthree\n")

        h.type("p")
        XCTAssertEqual(h.text, "four\ntwo\nthree")
    }

    func testDeleteWordAndPutCharwise() {
        let h = VimHarness("hello world swift")
        h.type("dw")
        XCTAssertEqual(h.text, "world swift")
        XCTAssertEqual(h.clipboard, "hello ")
        h.type("$")
        h.type("p")
        XCTAssertEqual(h.text, "world swifthello ")

        let h2 = VimHarness("abc def")
        h2.type("ye")
        XCTAssertEqual(h2.clipboard, "abc")
        h2.type("0P")
        XCTAssertEqual(h2.text, "abcabc def")
    }

    func testTextObjectsQuotesAndBrackets() {
        let h1 = VimHarness("let msg = \"hello world\"")
        h1.cursor = p(0, 14) // inside quotes
        h1.type("ci\"")
        XCTAssertEqual(h1.engine.mode, .insert)
        h1.type("hi")
        h1.send(.escape)
        XCTAssertEqual(h1.engine.mode, .normal)
        XCTAssertEqual(h1.text, "let msg = \"hi\"")

        let h2 = VimHarness("call(alpha, beta)")
        h2.cursor = p(0, 7)
        h2.type("di(")
        XCTAssertEqual(h2.text, "call()")
        XCTAssertEqual(h2.clipboard, "alpha, beta")

        let h3 = VimHarness("func f() {\n    return 42\n}")
        h3.cursor = p(1, 5)
        h3.type("yi{")
        XCTAssertEqual(h3.clipboard, "    return 42\n")
    }

    func testFunctionTextObjectsDafCifYifVif() {
        let goCode = """
        package main

        func greet(name string) {
            msg := "hi " + name
            println(msg)
        }

        func next() {}
        """

        // yif
        let hYif = VimHarness(goCode, cursor: p(3, 8))
        hYif.type("yif")
        XCTAssertEqual(hYif.clipboard, "    msg := \"hi \" + name\n    println(msg)\n")

        // vif
        let hVif = VimHarness(goCode, cursor: p(4, 4))
        hVif.type("vif")
        XCTAssertTrue(hVif.engine.mode.isVisual)
        XCTAssertEqual(hVif.selectedVisualText(), "    msg := \"hi \" + name\n    println(msg)")

        // cif
        let hCif = VimHarness(goCode, cursor: p(3, 6))
        hCif.type("cif")
        XCTAssertEqual(hCif.engine.mode, .insert)
        hCif.type("return")
        hCif.send(.escape)
        XCTAssertEqual(hCif.lines[2], "func greet(name string) {")
        XCTAssertEqual(hCif.lines[3], "    return")
        XCTAssertEqual(hCif.lines[4], "}")

        // daf
        let hDaf = VimHarness(goCode, cursor: p(3, 6))
        hDaf.type("daf")
        XCTAssertFalse(hDaf.text.contains("func greet"))
        XCTAssertTrue(hDaf.text.contains("func next() {}"))
    }

    func testCommentaryGccAndVisualGc() {
        let h = VimHarness("    let a = 1\n    let b = 2\n    let c = 3", commentPrefix: "//")
        h.type("gcc")
        XCTAssertEqual(h.lines[0], "    // let a = 1")
        // Toggle back off
        h.type("gcc")
        XCTAssertEqual(h.lines[0], "    let a = 1")

        // Visual-line gc across 2 lines
        h.type("Vjgc")
        XCTAssertEqual(h.lines[0], "    // let a = 1")
        XCTAssertEqual(h.lines[1], "    // let b = 2")
        XCTAssertEqual(h.lines[2], "    let c = 3")
        XCTAssertEqual(h.engine.mode, .normal)

        // Toggle both back off
        h.type("Vjgc")
        XCTAssertEqual(h.lines[0], "    let a = 1")
        XCTAssertEqual(h.lines[1], "    let b = 2")

        // Python `#` prefix
        let py = VimHarness("  x = 1", commentPrefix: "#")
        py.type("gcc")
        XCTAssertEqual(py.lines[0], "  # x = 1")
    }

    func testIndentOutdentJoinToggleCaseReplaceAndDotRepeat() {
        let h = VimHarness("alpha\nbeta\ngamma")
        h.type(">>")
        XCTAssertEqual(h.lines[0], "    alpha")
        h.type("j.") // dot-repeat >>
        XCTAssertEqual(h.lines[1], "    beta")
        h.type("<<")
        XCTAssertEqual(h.lines[1], "beta")

        // Join lines
        let hJ = VimHarness("hello\n    world\n  !")
        hJ.type("J")
        XCTAssertEqual(hJ.text, "hello world\n  !")
        hJ.type(".")
        XCTAssertEqual(hJ.text, "hello world !")

        // Toggle case `~`
        let hCase = VimHarness("aBc")
        hCase.type("3~")
        XCTAssertEqual(hCase.text, "AbC")

        // Replace char `r` + pending cursor indicator + `.`
        let hR = VimHarness("foo")
        hR.type("r")
        XCTAssertTrue(hR.engine.isReplaceCharPending)
        hR.type("b")
        XCTAssertFalse(hR.engine.isReplaceCharPending)
        XCTAssertEqual(hR.text, "boo")
        hR.type("l.")
        XCTAssertEqual(hR.text, "bbo")

        // Change + dot repeat (`ci"` then `.`)
        let hDot = VimHarness("a = \"one\"\nb = \"two\"")
        hDot.cursor = p(0, 5)
        hDot.type("ci\"X")
        hDot.send(.escape)
        XCTAssertEqual(hDot.lines[0], "a = \"X\"")
        hDot.cursor = p(1, 5)
        hDot.type(".")
        XCTAssertEqual(hDot.lines[1], "b = \"X\"")
    }

    // MARK: 3. Visual Mode, Surround & Expand/Shrink Selection

    func testVisualSurroundShortcuts() {
        let h1 = VimHarness("hello world")
        h1.type("ve\"")
        XCTAssertEqual(h1.text, "\"hello\" world")
        XCTAssertEqual(h1.engine.mode, .normal)

        let h2 = VimHarness("hello world")
        h2.type("ve'")
        XCTAssertEqual(h2.text, "'hello' world")

        let h3 = VimHarness("hello world")
        h3.type("ve(")
        XCTAssertEqual(h3.text, "(hello) world")

        let h4 = VimHarness("hello world")
        h4.type("ve{")
        XCTAssertEqual(h4.text, "{hello} world")

        let h5 = VimHarness("hello world")
        h5.type("ve[")
        XCTAssertEqual(h5.text, "[hello] world")

        let h6 = VimHarness("hello world")
        h6.type("veS)")
        XCTAssertEqual(h6.text, "(hello) world")
    }

    func testExpandAndShrinkSelection() {
        let code = """
        func demo() {
            val := obj.field
        }
        """
        let h = VimHarness(code, cursor: p(1, 16)) // on 'f' in `field`

        // 1st <CR>: word `field`
        h.send(.enter)
        XCTAssertEqual(h.engine.mode, .visual)
        XCTAssertEqual(h.selectedVisualText(), "field")

        // 2nd <CR>: member expr `obj.field`
        h.send(.enter)
        XCTAssertEqual(h.selectedVisualText(), "obj.field")

        // 3rd <CR>: trimmed line `val := obj.field`
        h.send(.enter)
        XCTAssertEqual(h.selectedVisualText(), "val := obj.field")

        // <BS> shrinks back step-by-step
        h.send(.backspace)
        XCTAssertEqual(h.selectedVisualText(), "obj.field")

        h.send(.backspace)
        XCTAssertEqual(h.selectedVisualText(), "field")

        h.send(.backspace)
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertNil(h.visualRange)
    }

    // MARK: 4. ~/.ideavimrc Leader, g-Prefix & Ctrl Action Dispatches

    func testIdeaVimActionDispatches() {
        let h = VimHarness("func main() {}")

        h.type("gd")
        XCTAssertEqual(h.actions.last, .goToDefinition)

        h.type("gr")
        XCTAssertEqual(h.actions.last, .findReferences)

        h.type(" r")
        XCTAssertEqual(h.actions.last, .findReferences)

        h.type(" a")
        XCTAssertEqual(h.actions.last, .searchEverywhere)

        h.type(" e")
        XCTAssertEqual(h.actions.last, .locateInTree)

        h.type(" o")
        XCTAssertEqual(h.actions.last, .toggleMaximizeViewer)

        h.type("ga")
        XCTAssertEqual(h.actions.last, .findAction)

        h.type("gs")
        XCTAssertEqual(h.actions.last, .goToSymbol)

        h.type("gl")
        XCTAssertEqual(h.actions.last, .gitPull)

        h.type("gp")
        XCTAssertEqual(h.actions.last, .gitPush)

        h.type("gb")
        XCTAssertEqual(h.actions.last, .toggleGitGraph)

        h.send(.ctrl("o"))
        XCTAssertEqual(h.actions.last, .navigateBack)

        h.send(.ctrl("i"))
        XCTAssertEqual(h.actions.last, .navigateForward)

        h.send(.ctrl("p"))
        XCTAssertEqual(h.actions.last, .goToFile)

        h.send(.ctrl("e"))
        XCTAssertEqual(h.actions.last, .toggleFileTree)

        h.send(.ctrl("h"))
        XCTAssertEqual(h.actions.last, .focusLeftPane)

        h.send(.ctrl("l"))
        XCTAssertEqual(h.actions.last, .focusRightPane)

        // nmap n nzz / nmap N Nzz
        h.type("n")
        XCTAssertEqual(h.actions.last, .nextSearchMatch(forward: true, center: true))

        h.type("N")
        XCTAssertEqual(h.actions.last, .nextSearchMatch(forward: false, center: true))
    }

    // MARK: 5. Command Line & Insert <-> Normal Transitions

    func testCommandLineAndInsertTransitions() {
        let lines = (1...60).map { "line \($0)" }.joined(separator: "\n")
        let h = VimHarness(lines)

        // :42 jumps to line 42 (0-based row 41)
        h.type(":42")
        XCTAssertEqual(h.engine.mode, .commandLine(prefix: ":", buffer: "42"))
        h.send(.enter)
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.cursor.row, 41)
        XCTAssertEqual(h.actions.last, .jumpToLine(42))

        // :w saves
        h.type(":w")
        h.send(.enter)
        XCTAssertEqual(h.actions.last, .save)

        // :noh clears highlights
        h.type(":noh")
        h.send(.enter)
        XCTAssertEqual(h.actions.last, .clearSearchHighlights)

        // Insert <-> Normal transitions (i, a, o, O, Esc, Ctrl-[, Ctrl-c) & input source spy
        h.cursor = p(0, 0)
        h.type("i")
        XCTAssertEqual(h.engine.mode, .insert)
        XCTAssertEqual(h.inputSpy.restoreCount, 1)
        h.send(.escape)
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.inputSpy.switchToEnglishCount, 1)

        h.type("a")
        XCTAssertEqual(h.engine.mode, .insert)
        XCTAssertEqual(h.cursor, p(0, 1))
        h.send(.ctrl("["))
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.inputSpy.switchToEnglishCount, 2)

        h.type("o")
        XCTAssertEqual(h.engine.mode, .insert)
        XCTAssertEqual(h.cursor.row, 1)
        h.send(.ctrl("c"))
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.inputSpy.switchToEnglishCount, 3)

        let beforeCount = h.lines.count
        h.type("O")
        XCTAssertEqual(h.engine.mode, .insert)
        XCTAssertEqual(h.lines.count, beforeCount + 1)
        h.send(.escape)
        XCTAssertEqual(h.engine.mode, .normal)
    }

    func testReadOnlyBufferAllowsNavigationAndActionsBlocksMutations() {
        let h = VimHarness("func foo() {\n    bar()\n}", isEditable: false)

        // Navigation, visual, yank, and IDE actions work on read-only
        h.type("j")
        XCTAssertEqual(h.cursor.row, 1)
        h.type("yy")
        XCTAssertEqual(h.clipboard, "    bar()\n")
        h.type("gd")
        XCTAssertEqual(h.actions.last, .goToDefinition)
        h.type(" r")
        XCTAssertEqual(h.actions.last, .findReferences)

        // Mutating commands cleanly no-op with readOnlyNotice
        let original = h.text
        h.type("dd")
        XCTAssertEqual(h.text, original)
        XCTAssertEqual(h.actions.last, .readOnlyNotice)
        h.type("i")
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.actions.last, .readOnlyNotice)
    }

    // MARK: 6. Added File Single-Pane Mode & Canvas Integration

    @MainActor
    func testAddedFileUsesSinglePaneMode() {
        let canvas = CodeCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        // Newly added / untracked file: empty left buffer, only added hunk, isPlainFile == false
        let addedRight = TextBuffer(lines: ["package main", "", "func hello() {}"])
        let addedDoc = DiffDocument(
            left: .empty,
            right: addedRight,
            hunks: [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 3)],
            language: .go,
            isPlainFile: false
        )
        XCTAssertTrue(CodeCanvasView.isAddedOnlyDocument(addedDoc))
        canvas.setDocument(addedDoc, mode: .sideBySide)
        XCTAssertEqual(canvas.mode, .single)

        // Normal modified diff stays side-by-side
        let modLeft = TextBuffer(lines: ["old"])
        let modRight = TextBuffer(lines: ["new"])
        let modDoc = DiffDocument(
            left: modLeft,
            right: modRight,
            hunks: [Hunk(leftStart: 0, leftCount: 1, rightStart: 0, rightCount: 1)],
            language: .go,
            isPlainFile: false
        )
        XCTAssertFalse(CodeCanvasView.isAddedOnlyDocument(modDoc))
        canvas.setDocument(modDoc, mode: .sideBySide)
        XCTAssertEqual(canvas.mode, .sideBySide)

        // Vim motions work seamlessly on the single-pane added document
        canvas.setDocument(addedDoc, mode: .sideBySide)
        XCTAssertTrue(canvas.handleVimKey(VimKey("j")))
        XCTAssertEqual(canvas.vimCursor.row, 1)
        XCTAssertTrue(canvas.handleVimKey(VimKey("]")))
        XCTAssertTrue(canvas.handleVimKey(VimKey("]")))
        XCTAssertEqual(canvas.vimCursor.row, 2)
    }

    func testCommandModifiedKeyNeverHijackedByVim() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "p",
            charactersIgnoringModifiers: "p",
            isARepeat: false,
            keyCode: 35
        ) else {
            XCTFail("Could not construct NSEvent")
            return
        }
        XCTAssertNil(VimKey.from(event: event))
    }

    // MARK: 7. Verifier Regression Tests

    func testVisualIndentOutdentAndAngleBracketSurround() {
        let h = VimHarness("alpha\nbeta\ngamma", indentUnit: "    ")
        // Vj> indents lines 0 and 1 instead of wrapping in <...>
        h.type("Vj>")
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.text, "    alpha\n    beta\ngamma")

        // Vj< outdents lines 0 and 1 back
        h.type("Vj<")
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.text, "alpha\nbeta\ngamma")

        // S< and S> still surround with angle brackets
        h.type("veS<")
        XCTAssertEqual(h.engine.mode, .normal)
        XCTAssertEqual(h.text, "<alpha>\nbeta\ngamma")
    }

    @MainActor
    func testNonInsertVimModesNeverMutateBufferOnUnhandledKeys() throws {
        let data = Data("hello world\nsecond line\n".utf8)
        let editable = try XCTUnwrap(TextCodec.decodeForEditing(data))
        let right = TextBuffer(lines: editable.lines)
        let doc = DiffDocument(left: .empty, right: right, hunks: [], language: .plain, isPlainFile: true)
        doc.editing = EditInfo(format: editable.format, crlf: editable.crlf, fingerprint: TextCodec.fingerprint(data))
        let session = try XCTUnwrap(EditorSession(document: doc, root: URL(fileURLWithPath: "/tmp"), path: "vim.txt", ignoreWhitespace: false))

        let canvas = CodeCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        canvas.vimModeEnabled = true
        canvas.setDocument(doc, mode: .single)
        canvas.editor = session
        canvas.placeCaret(line: 0, column: 2)

        func makeKey(_ chars: String, ignoring: String? = nil, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: chars,
                charactersIgnoringModifiers: ignoring ?? chars,
                isARepeat: false,
                keyCode: keyCode
            ))
        }

        // Normal mode: Tab, ⌃K, ⌃T, and Forward Delete must not fall through to editing.
        canvas.keyDown(with: try makeKey("\t", keyCode: 48))
        canvas.keyDown(with: try makeKey("\u{0B}", ignoring: "k", modifiers: [.control], keyCode: 40))
        canvas.keyDown(with: try makeKey("\u{14}", ignoring: "t", modifiers: [.control], keyCode: 17))
        canvas.keyDown(with: try makeKey("\u{F728}", keyCode: 117))
        XCTAssertEqual(doc.right.lines, ["hello world", "second line"])

        // Visual mode: ⌃O and Tab must not insert newlines/tabs into the buffer.
        XCTAssertTrue(canvas.handleVimKey(VimKey("v")))
        XCTAssertEqual(canvas.vimEngine.mode, .visual)
        canvas.keyDown(with: try makeKey("\u{0F}", ignoring: "o", modifiers: [.control], keyCode: 31))
        canvas.keyDown(with: try makeKey("\t", keyCode: 48))
        XCTAssertEqual(doc.right.lines, ["hello world", "second line"])
    }

    @MainActor
    func testExpandShrinkSelectionResetsAfterExternalCursorMoveWhenVimDisabled() {
        let doc = DiffDocument(
            left: .empty,
            right: TextBuffer(lines: ["alpha beta gamma"]),
            hunks: [],
            language: .swift,
            isPlainFile: true
        )
        let canvas = CodeCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        canvas.vimModeEnabled = false
        canvas.setDocument(doc, mode: .single)

        // Expand on "alpha"
        canvas.setCaret(TextPosition(row: 0, column: 1))
        canvas.vimExpandSelection()
        XCTAssertEqual(canvas.selectedText(), "alpha")

        // Move caret externally to "beta" (simulating click or arrow move while Vim is off)
        canvas.setCaret(TextPosition(row: 0, column: 7))
        canvas.vimExpandSelection()
        XCTAssertEqual(canvas.selectedText(), "beta", "Expand selection should start fresh at the new caret position")

        // Shrink collapses back cleanly rather than restoring stale "alpha"
        canvas.vimShrinkSelection()
        XCTAssertNil(canvas.selectedText())
    }

    @MainActor
    func testBackwardVisualSelectionTracksMovingHeadLine() {
        let doc = DiffDocument(
            left: TextBuffer(lines: ["line0", "line1", "line2"]),
            right: TextBuffer(lines: ["line0", "line1_mod", "line2"]),
            hunks: [Hunk(leftStart: 1, leftCount: 1, rightStart: 1, rightCount: 1)],
            language: .plain
        )
        let canvas = CodeCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        var reported: [(Side, Int)] = []
        canvas.onActiveLineChange = { side, line in reported.append((side, line)) }
        canvas.vimModeEnabled = true
        canvas.setDocument(doc, mode: .sideBySide)

        canvas.placeCaret(line: 2, column: 2)
        reported.removeAll()
        XCTAssertTrue(canvas.handleVimKey(VimKey("v")))
        XCTAssertTrue(canvas.handleVimKey(VimKey("k")))
        XCTAssertEqual(canvas.selection?.head.row, 1)
        XCTAssertEqual(reported.last?.0, .right)
        XCTAssertEqual(reported.last?.1, 1)

        XCTAssertTrue(canvas.handleVimKey(VimKey("k")))
        XCTAssertEqual(canvas.selection?.head.row, 0)
        XCTAssertEqual(reported.last?.1, 0)

        // Exit Visual and verify backward Visual-Line (V + k) tracks moving head too.
        XCTAssertTrue(canvas.handleVimKey(VimKey(.escape)))
        canvas.placeCaret(line: 2, column: 0)
        reported.removeAll()
        XCTAssertTrue(canvas.handleVimKey(VimKey("V")))
        XCTAssertTrue(canvas.handleVimKey(VimKey("k")))
        XCTAssertEqual(canvas.selection?.head.row, 1)
        XCTAssertEqual(reported.last?.1, 1)
    }

    // MARK: 8. Vim Jump-List (<C-o> / <C-i>) Regression Tests

    func testVimEngineJumpMotionsEmitJumpOriginWhileStepMotionsDoNot() {
        let code = """
        package main

        func first() {
            alpha := 1
            beta := 2
            gamma := 3
        }

        func second() {
            if (true) {
                delta := 4
            }
        }

        func third() {
            omega := 5
        }
        """
        let h = VimHarness(code, cursor: p(0, 0))

        // Step-by-step motions must NOT emit jumpOrigin: hjkl, w/b/e, 0/^/$, f/F/t/T
        for key in ["j", "j", "l", "w", "b", "e", "$", "0", "^", "f(", "k", "h"] {
            var lastResult = VimResult.ignored
            for ch in key {
                lastResult = h.send(VimKey(String(ch)))
            }
            XCTAssertNil(lastResult.jumpOrigin, "Step motion '\(key)' must not push onto jump list")
        }

        // G pushes origin
        h.cursor = p(1, 0)
        let gEnd = h.send(VimKey("G"))
        XCTAssertEqual(gEnd.jumpOrigin, p(1, 0))
        XCTAssertEqual(h.cursor.row, 16)

        // gg pushes origin
        let gFirst = h.send(VimKey("g"))
        XCTAssertNil(gFirst.jumpOrigin)
        let ggRes = h.send(VimKey("g"))
        XCTAssertEqual(ggRes.jumpOrigin, p(16, 0))
        XCTAssertEqual(h.cursor.row, 0)

        // <N>G pushes origin
        h.send(VimKey("1"))
        h.send(VimKey("0"))
        let tenG = h.send(VimKey("G"))
        XCTAssertEqual(tenG.jumpOrigin, p(0, 0))
        XCTAssertEqual(h.cursor.row, 9)

        // [[ and ]] push origin
        h.send(VimKey("]"))
        let nextFn = h.send(VimKey("]"))
        XCTAssertEqual(nextFn.jumpOrigin?.row, 9)
        XCTAssertEqual(h.cursor.row, 14)

        h.send(VimKey("["))
        let prevFn = h.send(VimKey("["))
        XCTAssertEqual(prevFn.jumpOrigin?.row, 14)
        XCTAssertEqual(h.cursor.row, 8)

        // % across lines pushes origin
        h.cursor = p(2, 13) // '{' on `func first() {`
        let matchRes = h.send(VimKey("%"))
        XCTAssertEqual(matchRes.jumpOrigin, p(2, 13))
        XCTAssertEqual(h.cursor.row, 6) // '}'

        // { and } across lines push origin
        h.cursor = p(4, 4) // inside `func first()`
        let openBrace = h.send(VimKey("{"))
        XCTAssertEqual(openBrace.jumpOrigin, p(4, 4))
        XCTAssertEqual(h.cursor.row, 2)

        // :<N> pushes origin
        h.cursor = p(2, 5)
        h.type(":15")
        let cmdRes = h.send(.enter)
        XCTAssertEqual(cmdRes.jumpOrigin, p(2, 5))
        XCTAssertEqual(h.cursor.row, 14)

        // <C-u> / <C-d> push origin
        let halfUp = h.send(.ctrl("u"))
        XCTAssertEqual(halfUp.jumpOrigin?.row, 14)
        XCTAssertLessThan(h.cursor.row, 14)
    }

    @MainActor
    func testWithinFileVimJumpListWalksBackAndForwardWithoutLosingEdits() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-vim-jumplist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("sample.go")
        let content = (1...60).map { i in
            if i == 10 { return "func alpha() { targetWord() }" }
            if i == 35 { return "func beta()  { targetWord() }" }
            if i == 55 { return "func gamma() { return }" }
            return "// line \(i)"
        }.joined(separator: "\n") + "\n"
        try content.write(to: fileA, atomically: true, encoding: .utf8)

        let store = AppStore.shared
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevContainer = store.viewer.container
        let prevHistory = store.jumpHistory
        let prevExternal = store.externalRequest
        let prevProjects = store.projects
        let prevSelectedID = store.selectedProjectID
        defer {
            store.viewer.loadTask?.cancel()
            store.viewer.clear()
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.viewer.container = prevContainer
            store.jumpHistory = prevHistory
            store.externalRequest = prevExternal
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedID
        }

        let project = Project(url: dir)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.jumpHistory.clear()

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        container.layoutSubtreeIfNeeded()
        store.viewer.attach(container)
        store.viewer.vimModeEnabled = true

        store.openFile(in: project, path: "sample.go", line: 10, column: 15)
        await store.viewer.loadTask?.value
        let loadedDoc = try XCTUnwrap(store.viewer.document)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(9, 15))

        // Step motions (j/l/w) must NOT push onto jumpHistory
        XCTAssertTrue(container.canvas.handleVimKey(VimKey("l")))
        XCTAssertTrue(container.canvas.handleVimKey(VimKey("h")))
        XCTAssertFalse(store.jumpHistory.canGoBack)

        // `*` on `targetWord` at line 10 col 15 -> jumps to line 35 col 15 and records line 10 col 15
        XCTAssertTrue(container.canvas.handleVimKey(VimKey("*")))
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(34, 15))
        XCTAssertEqual(store.jumpHistory.backStack.count, 1)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 10)
        XCTAssertEqual(store.jumpHistory.backStack.last?.column, 15)

        // `G` jumps to last line (60) and records line 35 col 15
        XCTAssertTrue(container.canvas.handleVimKey(VimKey("G")))
        XCTAssertEqual(container.canvas.activeCaretPosition()?.row, 59)
        XCTAssertEqual(store.jumpHistory.backStack.count, 2)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 35)
        XCTAssertEqual(store.jumpHistory.backStack.last?.column, 15)

        // `<C-o>` returns to line 35 col 15 in-place (same DiffDocument instance, no reload!)
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("o")))
        XCTAssertTrue(store.viewer.document === loadedDoc, "Same-file <C-o> must not reload document from disk")
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(34, 15))
        XCTAssertTrue(store.jumpHistory.canGoForward)

        // `<C-o>` again returns to line 10 col 15
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("o")))
        XCTAssertTrue(store.viewer.document === loadedDoc)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(9, 15))
        XCTAssertFalse(store.jumpHistory.canGoBack)
        XCTAssertEqual(store.jumpHistory.forwardStack.count, 2)

        // `<C-i>` walks forward to line 35 col 15 without corrupting forwardStack
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("i")))
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(34, 15))
        XCTAssertEqual(store.jumpHistory.forwardStack.count, 1)

        // `<C-i>` walks forward to line 60
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("i")))
        XCTAssertEqual(container.canvas.activeCaretPosition()?.row, 59)
        XCTAssertFalse(store.jumpHistory.canGoForward)
    }

    @MainActor
    func testCrossFileAndWithinFileJumpHistoryRoundTrip() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-cross-file-jumplist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let fileA = dir.appendingPathComponent("fileA.go")
        let fileB = dir.appendingPathComponent("fileB.go")
        let linesA = (1...30).map { "    // fileA line \($0)" }.joined(separator: "\n") + "\n"
        let linesB = (1...120).map { "    // fileB line \($0)" }.joined(separator: "\n") + "\n"
        try linesA.write(to: fileA, atomically: true, encoding: .utf8)
        try linesB.write(to: fileB, atomically: true, encoding: .utf8)

        let canonicalA = LSPURI.canonicalFileURL(fileA)
        let canonicalB = LSPURI.canonicalFileURL(fileB)

        let store = AppStore.shared
        let prevReq = store.viewer.request
        let prevDoc = store.viewer.document
        let prevContainer = store.viewer.container
        let prevHistory = store.jumpHistory
        let prevExternal = store.externalRequest
        let prevProjects = store.projects
        let prevSelectedID = store.selectedProjectID
        defer {
            store.viewer.loadTask?.cancel()
            store.viewer.clear()
            store.viewer.request = prevReq
            store.viewer.document = prevDoc
            store.viewer.container = prevContainer
            store.jumpHistory = prevHistory
            store.externalRequest = prevExternal
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedID
        }

        let project = Project(url: dir)
        store.projects = [project]
        store.selectedProjectID = project.id
        store.jumpHistory.clear()

        let container = CodeScrollContainer(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        container.layoutSubtreeIfNeeded()
        store.viewer.attach(container)
        store.viewer.vimModeEnabled = true

        // 1. Open fileA at line 10, col 7
        store.openFile(in: project, path: "fileA.go", line: 10, column: 7)
        await store.viewer.loadTask?.value
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalA)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(9, 7))

        // 2. Switch to fileB at line 42 (simulating Quick Open / Find in Files / sidebar click)
        store.openFile(in: project, path: "fileB.go", line: 42, column: 4)
        await store.viewer.loadTask?.value
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalB)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(41, 4))
        XCTAssertEqual(store.jumpHistory.backStack.count, 1)
        XCTAssertEqual(store.jumpHistory.backStack.last?.fileURL, canonicalA)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 10)
        XCTAssertEqual(store.jumpHistory.backStack.last?.column, 7)

        // 3. In fileB, jump to line 120 via `G`
        XCTAssertTrue(container.canvas.handleVimKey(VimKey("G")))
        XCTAssertEqual(container.canvas.activeCaretPosition()?.row, 119)
        XCTAssertEqual(store.jumpHistory.backStack.count, 2)
        XCTAssertEqual(store.jumpHistory.backStack.last?.fileURL, canonicalB)
        XCTAssertEqual(store.jumpHistory.backStack.last?.line, 42)
        XCTAssertEqual(store.jumpHistory.backStack.last?.column, 4)

        // 4. `<C-o>` returns to fileB:42 col 4
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("o")))
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalB)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(41, 4))

        // 5. `<C-o>` returns to fileA:10 col 7
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("o")))
        await store.viewer.loadTask?.value
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalA)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(9, 7))
        XCTAssertEqual(store.jumpHistory.forwardStack.count, 2)

        // 6. `<C-i>` goes forward to fileB:42 col 4
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("i")))
        await store.viewer.loadTask?.value
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalB)
        XCTAssertEqual(container.canvas.activeCaretPosition(), p(41, 4))

        // 7. `<C-i>` goes forward to fileB:120
        XCTAssertTrue(container.canvas.handleVimKey(.ctrl("i")))
        XCTAssertEqual(store.viewer.request.map { LSPURI.canonicalFileURL($0.fileURL) }, canonicalB)
        XCTAssertEqual(container.canvas.activeCaretPosition()?.row, 119)
        XCTAssertFalse(store.jumpHistory.canGoForward)
    }
}
