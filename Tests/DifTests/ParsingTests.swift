import XCTest
@testable import DifKit

/// Joins records the way `git ... -z` does.
private func nulSeparated(_ parts: [String]) -> Data {
    Data((parts.joined(separator: "\0") + "\0").utf8)
}

final class StatusParsingTests: XCTestCase {
    func testBranchHeaders() {
        let status = Git.parseStatus(nulSeparated([
            "# branch.oid 1234567890abcdef1234567890abcdef12345678",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -3",
        ]))
        XCTAssertEqual(status.branch, "main")
        XCTAssertEqual(status.upstream, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 3)
        XCTAssertEqual(status.shortHead, "1234567")
        XCTAssertFalse(status.isInitial)
        XCTAssertTrue(status.changes.isEmpty)
    }

    func testDetachedHeadAndUnbornBranch() {
        let detached = Git.parseStatus(nulSeparated(["# branch.oid abcdef0123456789", "# branch.head (detached)"]))
        XCTAssertNil(detached.branch)
        XCTAssertEqual(detached.shortHead, "abcdef0")

        let unborn = Git.parseStatus(nulSeparated(["# branch.oid (initial)", "# branch.head main"]))
        XCTAssertTrue(unborn.isInitial)
        XCTAssertNil(unborn.headOID)
    }

    func testEntriesOfEveryKind() {
        let status = Git.parseStatus(nulSeparated([
            "1 .M N... 100644 100644 100644 aaaa bbbb src/Main.kt",
            "1 D. N... 100644 000000 000000 aaaa 0000 src/Old file.kt",
            "1 A. N... 000000 100644 100644 0000 bbbb src/New.kt",
            "2 R. N... 100644 100644 100644 aaaa bbbb R100 docs/new.md", "docs/old.md",
            "2 C. N... 100644 100644 100644 aaaa bbbb C90 copy.txt", "orig.txt",
            "u UU N... 100644 100644 100644 100644 a b c conflict.txt",
            "? notes/todo.txt",
        ]))
        let byPath = Dictionary(uniqueKeysWithValues: status.changes.map { ($0.path, $0) })
        XCTAssertEqual(status.changes.count, 7)
        XCTAssertEqual(byPath["src/Main.kt"]?.kind, .modified)
        XCTAssertEqual(byPath["src/Old file.kt"]?.kind, .deleted, "paths may contain spaces")
        XCTAssertEqual(byPath["src/New.kt"]?.kind, .added)
        XCTAssertEqual(byPath["docs/new.md"]?.kind, .renamed)
        XCTAssertEqual(byPath["docs/new.md"]?.oldPath, "docs/old.md")
        XCTAssertEqual(byPath["copy.txt"]?.kind, .added, "a copy is shown as a new file")
        XCTAssertNil(byPath["copy.txt"]?.oldPath)
        XCTAssertEqual(byPath["conflict.txt"]?.kind, .conflicted)
        XCTAssertEqual(byPath["notes/todo.txt"]?.kind, .untracked)
        XCTAssertNil(byPath["docs/old.md"], "the origin of a rename is not a change of its own")
    }

    func testNumstatIncludingRenamesAndBinaries() {
        let data = Data("3\t1\tsrc/a.kt\0-\t-\timg.png\05\t2\t\0old.md\0new.md\0".utf8)
        let stats = Git.parseNumstat(data)
        XCTAssertEqual(stats["src/a.kt"]?.0, 3)
        XCTAssertEqual(stats["src/a.kt"]?.1, 1)
        XCTAssertNil(stats["img.png"], "binary files report no line counts")
        XCTAssertEqual(stats["new.md"]?.0, 5, "a rename is keyed by its new path")
        XCTAssertEqual(stats["new.md"]?.1, 2)
    }

    func testLogRecords() {
        let record = ["0123456789abcdef", "aaaa bbbb", "Ada", "ada@example.invalid", "1700000000", "HEAD -> main, tag: v1.0", "Merge things"]
            .joined(separator: "\u{1f}")
        let commits = Git.parseLog(Data((record + "\u{1e}\n").utf8))
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].shortHash, "0123456")
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "tag: v1.0"])
        XCTAssertEqual(commits[0].subject, "Merge things")
        XCTAssertEqual(commits[0].date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testGrepRecord() {
        let hit = Git.parseGrepRecord(Data("src/a b.kt\u{0}12\u{0}5\u{0}    val x = 1\r".utf8))
        XCTAssertEqual(hit, GrepHit(path: "src/a b.kt", line: 12, column: 5, text: "    val x = 1"))
        XCTAssertNil(Git.parseGrepRecord(Data("no separators here".utf8)))
    }
}

final class HunkParsingTests: XCTestCase {
    func testZeroContextHeaders() {
        let diff = """
        diff --git a/x b/x
        --- a/x
        +++ b/x
        @@ -8 +8 @@
        -old
        +new
        @@ -29,0 +31,4 @@ fun context() {
        +a
        @@ -40,3 +44,0 @@
        -gone
        """
        let parsed = DiffParser.parseHunks(Data(diff.utf8))
        XCTAssertFalse(parsed.binary)
        XCTAssertEqual(parsed.hunks, [
            Hunk(leftStart: 7, leftCount: 1, rightStart: 7, rightCount: 1),
            // An insertion sits *after* the reported old line, so it starts at that index.
            Hunk(leftStart: 29, leftCount: 0, rightStart: 30, rightCount: 4),
            Hunk(leftStart: 39, leftCount: 3, rightStart: 44, rightCount: 0),
        ])
        XCTAssertEqual(parsed.hunks.map(\.kind), [.modified, .added, .deleted])
    }

    func testBinaryMarker() {
        XCTAssertTrue(DiffParser.parseHunks(Data("Binary files a/x.png and b/x.png differ\n".utf8)).binary)
    }
}

final class InlineDiffTests: XCTestCase {
    func testMyersFlagsTheCommonSubsequence() throws {
        let result = try XCTUnwrap(Myers.matches(["a", "b", "c", "d"], ["a", "c", "d", "e"], maxEdits: 10))
        XCTAssertEqual(result.a, [true, false, true, true])
        XCTAssertEqual(result.b, [true, true, true, false])
    }

    func testMyersGivesUpPastTheEditBudget() {
        XCTAssertNil(Myers.matches(Array("abcdef"), Array("uvwxyz"), maxEdits: 3))
    }

    func testChangedWordIsHighlightedOnBothSides() throws {
        let result = try XCTUnwrap(InlineDiff.compute(old: ["val limit = 50"], new: ["val limit = 20"]))
        XCTAssertEqual(result.old, [[12..<14]])
        XCTAssertEqual(result.new, [[12..<14]])
    }

    func testInsertedArgumentBridgesTheSpaceInsideIt() throws {
        let result = try XCTUnwrap(InlineDiff.compute(old: ["call(a)"], new: ["call(a, b)"]))
        XCTAssertEqual(result.old, [[]])
        XCTAssertEqual(result.new, [[6..<9]], "\", b\" is one highlight, not two")
    }

    func testReindentedLineIsNotHighlighted() throws {
        let pureIndent = try XCTUnwrap(InlineDiff.compute(old: ["foo(bar)"], new: ["        foo(bar)"]))
        XCTAssertEqual(pureIndent.old, [[]])
        XCTAssertEqual(pureIndent.new, [[0..<8]], "whitespace-only line highlights the exact added spaces")

        let indentWithEdit = try XCTUnwrap(InlineDiff.compute(old: ["foo(bar)"], new: ["        foo(baz)"]))
        XCTAssertEqual(indentWithEdit.old, [[4..<7]])
        XCTAssertEqual(indentWithEdit.new, [[12..<15]], "leading indentation stays unhighlighted when real tokens changed")
    }

    func testWhollyNewLineKeepsOnlyItsBand() throws {
        let result = try XCTUnwrap(InlineDiff.compute(old: ["alpha beta"], new: ["alpha beta", "    gamma delta"]))
        XCTAssertEqual(result.old, [[]])
        XCTAssertEqual(result.new[0], [])
        XCTAssertEqual(result.new[1], [4..<15], "wholly added line inside a mixed hunk highlights its visible text")
    }

    func testNothingInCommonMeansNoWordDiff() {
        XCTAssertNil(InlineDiff.compute(old: ["alpha"], new: ["omega"]))
    }
}

final class TextCodecTests: XCTestCase {
    func testSplitLines() {
        XCTAssertEqual(TextCodec.splitLines("a\r\nb\n"), ["a", "b"])
        XCTAssertEqual(TextCodec.splitLines("a\nb"), ["a", "b"])
        XCTAssertEqual(TextCodec.splitLines(""), [])
        XCTAssertEqual(TextCodec.splitLines("\n"), [""])
        XCTAssertEqual(TextCodec.splitLines("中文\n\nend"), ["中文", "", "end"])
    }

    func testBinaryDetection() {
        XCTAssertTrue(TextCodec.looksBinary(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
        XCTAssertFalse(TextCodec.looksBinary(Data("plain text".utf8)))
        XCTAssertFalse(TextCodec.looksBinary(Data([0xFF, 0xFE, 0x61, 0x00])), "UTF-16 has NULs but is text")
    }

    func testDecoding() {
        XCTAssertEqual(TextCodec.decode(Data([0xEF, 0xBB, 0xBF] + Array("hi".utf8))), "hi")
        XCTAssertEqual(TextCodec.decode(Data([0xFF, 0xFE, 0x68, 0x00, 0x69, 0x00])), "hi")
        XCTAssertEqual(TextCodec.decode(Data([0xD6, 0xD0, 0xCE, 0xC4])), "中文", "GB18030 fallback")
    }
}

final class SyntaxTests: XCTestCase {
    func testLanguageDetection() {
        XCTAssertEqual(LanguageSpec.detect(path: "app/src/Main.kt").name, LanguageSpec.detect(path: "x.kts").name)
        XCTAssertNotEqual(LanguageSpec.detect(path: "a.kt").name, LanguageSpec.detect(path: "a.py").name)
    }

    func testKotlinTokens() {
        let line = "val answer = 42 // why"
        let spans = Highlighter.highlight([line], language: .detect(path: "a.kt"))[0]
        func kind(of text: String) -> TokenKind? {
            let range = (line as NSString).range(of: text)
            return spans.first { Int($0.start) == range.location && Int($0.length) == range.length }?.kind
        }
        XCTAssertEqual(kind(of: "val"), .keyword)
        XCTAssertEqual(kind(of: "42"), .number)
        XCTAssertEqual(kind(of: "// why"), .comment)
    }

    func testBlockCommentCarriesAcrossLines() {
        let spans = Highlighter.highlight(["/* open", "still comment */ val x"], language: .detect(path: "a.java"))
        XCTAssertEqual(spans[1].first?.kind, .comment)
        XCTAssertEqual(spans[1].first?.start, 0)
    }
}
