import XCTest
@testable import DifKit

/// Blame, the Annotate column, line mapping, and file and line history.
final class HistoryTests: XCTestCase {
    private let a = String(repeating: "a", count: 40)
    private let b = String(repeating: "b", count: 40)

    // MARK: Parsing blame

    func testBlamePorcelainIsReadPerLine() {
        let porcelain = """
        \(a) 1 1 2
        author Alice
        author-mail <alice@example.com>
        author-time 1767290400
        author-tz -0800
        committer Alice
        committer-mail <alice@example.com>
        committer-time 1767290400
        committer-tz -0800
        summary first
        boundary
        filename f.txt
        \tone
        \(a) 2 2
        \ttwo
        \(b) 3 3 1
        author Bob
        author-mail <bob@example.com>
        author-time 1772388000
        author-tz -0800
        committer Bob
        committer-mail <bob@example.com>
        committer-time 1772388000
        committer-tz -0800
        summary second change
        previous \(a) f.txt
        filename f.txt
        \tTHREE
        \(Git.uncommittedHash) 4 4 1
        author Not Committed Yet
        author-mail <not.committed.yet>
        author-time 1773000000
        author-tz -0800
        committer Not Committed Yet
        committer-mail <not.committed.yet>
        committer-time 1773000000
        committer-tz -0800
        summary Version of f.txt from f.txt
        filename f.txt
        \tfour
        \(a) 5 5 1
        filename f.txt
        \tauthor five, a line that looks like a header

        """
        let blame = Git.parseBlame(Data(porcelain.utf8))
        XCTAssertEqual(blame.lines, [0, 0, 1, -1, 0])
        XCTAssertEqual(blame.entries.map(\.author), ["Alice", "Bob"])
        XCTAssertEqual(blame.entries.map(\.email), ["alice@example.com", "bob@example.com"])
        XCTAssertEqual(blame.entries.map(\.summary), ["first", "second change"])
        XCTAssertEqual(blame.entries[1].date, Date(timeIntervalSince1970: 1772388000))
        XCTAssertEqual(blame.entries[0].shortHash, "aaaaaaa")
    }

    func testEmptyBlameHasNoLines() {
        XCTAssertEqual(Git.parseBlame(Data()), Blame())
    }

    // MARK: The Annotate column

    private func entry(_ hash: String, _ author: String, _ time: TimeInterval) -> Blame.Entry {
        Blame.Entry(hash: hash, author: author, email: "", date: Date(timeIntervalSince1970: time), summary: "s")
    }

    func testAnnotationsRankCommitsByAgeAndLabelThem() {
        let c = String(repeating: "c", count: 40)
        let blame = Blame(entries: [entry(a, "Alice", 300), entry(b, "Bob", 100), entry(c, "Carol", 200)], lines: [0, 1, 2, -1])
        let annotations = LineAnnotations(blame: blame, lineCount: 4)
        XCTAssertEqual(annotations.entries.map(\.recency), [1, 0, 0.5])
        XCTAssertEqual(annotations.entries[0].label, LineAnnotations.dateText(Date(timeIntervalSince1970: 300)) + " Alice")
        // "yyyy-MM-dd " and the widest name, at least four cells.
        XCTAssertEqual(annotations.columns, 11 + 5)
        XCTAssertNil(annotations.entry(atLine: 3))
        XCTAssertNil(annotations.entry(atLine: 9))
        XCTAssertEqual(annotations.entry(atLine: 1)?.author, "Bob")
    }

    func testOneCommitIsTheNewest() {
        let annotations = LineAnnotations(blame: Blame(entries: [entry(a, "Al", 1)], lines: [0]), lineCount: 1)
        XCTAssertEqual(annotations.entries[0].recency, 1)
        XCTAssertEqual(annotations.columns, 11 + 4)
    }

    func testAnnotationsMatchTheLinesOnScreen() {
        let blame = Blame(entries: [entry(a, "Alice", 1)], lines: [0, 0, 0])
        XCTAssertEqual(LineAnnotations(blame: blame, lineCount: 5).lines, [0, 0, 0, -1, -1])
        XCTAssertEqual(LineAnnotations(blame: blame, lineCount: 2).lines, [0, 0])
        XCTAssertEqual(LineAnnotations(blame: blame, lineCount: 0).lines, [])
    }

    func testLongNamesAreCutToKeepTheColumnNarrow() {
        // "…" counts as two cells, as any character outside ASCII and Latin does.
        XCTAssertEqual(LineAnnotations.cut("Bartholomew Longname", to: 12), "Bartholome…")
        XCTAssertEqual(TextBuffer.columns(of: LineAnnotations.cut("Bartholomew Longname", to: 12)), 12)
        XCTAssertEqual(LineAnnotations.cut("张三丰李四王五", to: 12), "张三丰李四…")
        XCTAssertEqual(TextBuffer.columns(of: LineAnnotations.cut("张三丰李四王五", to: 12)), 12)
        XCTAssertEqual(LineAnnotations.cut("Bob", to: 12), "Bob")
        let blame = Blame(entries: [entry(a, "Bartholomew Longname", 1)], lines: [0])
        XCTAssertEqual(LineAnnotations(blame: blame, lineCount: 1).columns, 11 + 12)
    }

    func testRunsStartWhereTheCommitChanges() {
        let annotations = LineAnnotations(entries: [], lines: [0, 0, 1, 1, -1, -1, 0], columns: 16)
        XCTAssertEqual((0..<7).filter(annotations.isRunStart), [0, 2, 4, 6])
    }

    func testEditsMarkTheChangedLinesAsNotCommitted() {
        var annotations = LineAnnotations(entries: [], lines: [0, 1, 2, 3], columns: 16)
        annotations.apply(LineEdit(start: 1, removed: 1, inserted: 2))   // line 1 rewritten as two
        XCTAssertEqual(annotations.lines, [0, -1, -1, 2, 3])
        annotations.apply(LineEdit(start: 0, removed: 2, inserted: 0))   // two lines deleted
        XCTAssertEqual(annotations.lines, [-1, 2, 3])
        annotations.apply(LineEdit(start: 3, removed: 0, inserted: 1))   // a line added at the end
        XCTAssertEqual(annotations.lines, [-1, 2, 3, -1])
        annotations.apply(LineEdit(start: 9, removed: 5, inserted: 0))   // out of range: nothing to do
        XCTAssertEqual(annotations.lines, [-1, 2, 3, -1])
    }

    // MARK: Matching lines up

    func testUnchangedLinesMapOneForOne() {
        XCTAssertEqual(Hunk.oldLines(forNew: 3...5, in: [], oldCount: 10), 3...5)
    }

    func testLinesBelowAnInsertionMoveUp() {
        let inserted = [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 2)]
        XCTAssertEqual(Hunk.oldLines(forNew: 4...5, in: inserted, oldCount: 10), 2...3)
        XCTAssertNil(Hunk.oldLines(forNew: 0...1, in: inserted, oldCount: 10))
        XCTAssertEqual(Hunk.oldLines(forNew: 1...2, in: inserted, oldCount: 10), 0...0)
    }

    func testChangedLinesStandForTheLinesTheyReplaced() {
        let modified = [Hunk(leftStart: 3, leftCount: 2, rightStart: 3, rightCount: 1)]
        XCTAssertEqual(Hunk.oldLines(forNew: 3...3, in: modified, oldCount: 10), 3...4)
        XCTAssertEqual(Hunk.oldLines(forNew: 4...4, in: modified, oldCount: 10), 5...5)
        XCTAssertEqual(Hunk.oldLines(forNew: 2...4, in: modified, oldCount: 10), 2...5)
    }

    func testDeletedLinesInsideTheSelectionAreIncluded() {
        let deleted = [Hunk(leftStart: 2, leftCount: 3, rightStart: 2, rightCount: 0)]
        XCTAssertEqual(Hunk.oldLines(forNew: 1...2, in: deleted, oldCount: 10), 1...5)
        XCTAssertEqual(Hunk.oldLines(forNew: 2...2, in: deleted, oldCount: 10), 5...5)
    }

    func testLinesPastTheOldTextAreLeftOut() {
        XCTAssertEqual(Hunk.oldLines(forNew: 2...9, in: [], oldCount: 4), 2...3)
        XCTAssertNil(Hunk.oldLines(forNew: 5...6, in: [], oldCount: 4))
    }

    func testDocumentMapsItsRightSideToItsLeft() {
        let doc = DiffDocument(left: TextBuffer(lines: ["a", "b", "c"]), right: TextBuffer(lines: ["new", "a", "B", "c"]),
                               hunks: [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: 1),
                                       Hunk(leftStart: 1, leftCount: 1, rightStart: 2, rightCount: 1)],
                               language: .plain)
        XCTAssertEqual(doc.leftLines(forRight: 1...1), 0...0)
        XCTAssertEqual(doc.leftLines(forRight: 2...3), 1...2)
        XCTAssertNil(doc.leftLines(forRight: 0...0))
    }

    func testLinesAreCountedAsGitCountsThem() {
        XCTAssertEqual(Git.lineCount(of: Data("a\nb\n".utf8)), 2)
        XCTAssertEqual(Git.lineCount(of: Data("a\nb".utf8)), 2)
        XCTAssertEqual(Git.lineCount(of: Data()), 0)
    }
}

/// History, blame and comparisons against a real repository built in a temporary directory: a file committed,
/// changed by someone else, renamed and changed again, then a branch with work of its own.
final class HistoryRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try write("f.txt", "one\ntwo\nthree\nfour\nfive\nsix\n")
        try git("add", "-A")
        try commit("first", date: "2026-01-01T10:00:00")
        try write("f.txt", "one\nTWO\nthree\nfour\nfive\nsix\n")
        try git("-c", "user.name=Bob", "-c", "user.email=bob@example.com", "commit", "-q", "-am", "second", "--date=2026-03-01T10:00:00")
        try git("mv", "f.txt", "g.txt")
        try commit("rename", date: "2026-04-01T10:00:00")
        try write("g.txt", "one\nTWO\nthree\nFOUR\nfive\nsix\n")
        try git("add", "-A")
        try commit("four", date: "2026-05-01T10:00:00")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func commit(_ message: String, date: String) throws {
        try git("commit", "-q", "-m", message, "--date=\(date)")
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-c", "user.name=Alice", "-c", "user.email=alice@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func hash(_ rev: String) async throws -> String {
        try await Git.runString(["rev-parse", rev], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testBlameNamesTheCommitOfEachLineAndLeavesNewLinesOut() async throws {
        try write("g.txt", "zero\none\nTWO\nthree\nFOUR\nfive\nsix\n")
        let blame = try await Git.blame("g.txt", rev: nil, in: root)
        let authors = blame.lines.map { $0 < 0 ? "-" : blame.entries[Int($0)].author }
        XCTAssertEqual(authors, ["-", "Alice", "Bob", "Alice", "Alice", "Alice", "Alice"])
        XCTAssertEqual(blame.entries[Int(blame.lines[4])].summary, "four")
        XCTAssertEqual(blame.entries[Int(blame.lines[1])].summary, "first")

        // In a commit: as the file was then.
        let old = try await Git.blame("f.txt", rev: try await hash("HEAD~3"), in: root)
        XCTAssertEqual(old.lines.count, 6)
        XCTAssertEqual(Set(old.lines), [0])
    }

    func testFileHistoryFollowsRenamesAndNamesTheFileInEachCommit() async throws {
        let (commits, paths) = try await Git.fileHistory("g.txt", in: root, skip: 0, limit: 50)
        XCTAssertEqual(commits.map(\.subject), ["four", "rename", "second", "first"])
        XCTAssertEqual(commits.map(\.author), ["Alice", "Alice", "Bob", "Alice"])
        XCTAssertEqual(paths[commits[0].hash], "g.txt")
        XCTAssertEqual(paths[commits[1].hash], "g.txt")
        XCTAssertEqual(paths[commits[2].hash], "f.txt")
        XCTAssertEqual(paths[commits[3].hash], "f.txt")

        // Searched: commits from before the rename are found too, though the rename itself does not match.
        let searched = try await Git.fileHistory("g.txt", in: root, skip: 0, limit: 50, query: "SECOND")
        XCTAssertEqual(searched.commits.map(\.subject), ["second"])
        let firstAndFour = try await Git.fileHistory("g.txt", in: root, skip: 0, limit: 50, query: "f")
        XCTAssertEqual(firstAndFour.commits.map(\.subject), ["four", "first"])
        let secondPage = try await Git.fileHistory("g.txt", in: root, skip: 1, limit: 1, query: "f")
        XCTAssertEqual(secondPage.commits.map(\.subject), ["first"])
        let page = try await Git.fileHistory("g.txt", in: root, skip: 1, limit: 2)
        XCTAssertEqual(page.commits.map(\.subject), ["rename", "second"])
    }

    func testLineHistoryListsOnlyTheCommitsThatChangedThoseLines() async throws {
        let two = try await Git.lineHistory("g.txt", lines: 2...2, rev: "HEAD", in: root, skip: 0, limit: 50)
        XCTAssertEqual(two.map(\.subject), ["second", "first"])
        let four = try await Git.lineHistory("g.txt", lines: 4...4, rev: "HEAD", in: root, skip: 0, limit: 50)
        XCTAssertEqual(four.map(\.subject), ["four", "first"])
        // Past the end of the file: nothing, rather than an error.
        let none = try await Git.lineHistory("g.txt", lines: 40...41, rev: "HEAD", in: root, skip: 0, limit: 50)
        XCTAssertEqual(none, [])
    }

    func testWorkingTreeLinesAreCountedInHead() async throws {
        try write("g.txt", "zero\none\nTWO\nthree\nFOUR!\nfive\nsix\n")
        let moved = await Git.headLines(of: "g.txt", headPath: "g.txt", lines: 1...2, in: root)
        XCTAssertEqual(moved, 0...1)
        let changed = await Git.headLines(of: "g.txt", headPath: "g.txt", lines: 4...4, in: root)
        XCTAssertEqual(changed, 3...3)
        let new = await Git.headLines(of: "g.txt", headPath: "g.txt", lines: 0...0, in: root)
        XCTAssertNil(new)
        let missing = await Git.headLines(of: "g.txt", headPath: "nope.txt", lines: 1...1, in: root)
        XCTAssertNil(missing)
    }

    func testOneCommitByName() async throws {
        let commit = await Git.commit("HEAD~1", in: root)
        XCTAssertEqual(commit?.subject, "rename")
        let none = await Git.commit("no-such-thing", in: root)
        XCTAssertNil(none)
        let option = await Git.commit("--all", in: root)
        XCTAssertNil(option)
    }

    func testComparingWithTheForkPointIncludesCommittedAndUncommittedWork() async throws {
        let mainTip = try await hash("main")
        try git("checkout", "-q", "-b", "work")
        try write("n.txt", "new\nfile\n")
        try write("g.txt", "one\nTWO\nthree\nFOUR\nfive\nsix\nseven\n")
        try git("add", "-A")
        try commit("work", date: "2026-06-01T10:00:00")
        try git("checkout", "-q", "main")
        try write("m.txt", "main moves\n")
        try git("add", "-A")
        try commit("main moves", date: "2026-06-02T10:00:00")
        try git("checkout", "-q", "work")
        try write("g.txt", "one\nTWO\nthree\nFOUR\nfive\nsix\nseven\neight\n")
        try write("u.txt", "untracked\n")

        let resolved = await Git.resolveCommit("main", in: root)
        let mainNow = try await hash("main")
        XCTAssertEqual(resolved, mainNow)
        let none = await Git.resolveCommit("no-such-branch", in: root)
        XCTAssertNil(none)
        let option = await Git.resolveCommit("--all", in: root)
        XCTAssertNil(option)

        let base = await Git.mergeBase("HEAD", "refs/heads/main", in: root)
        XCTAssertEqual(base, mainTip)
        let changes = try await Git.compareFiles(base: try XCTUnwrap(base), in: root)
        XCTAssertEqual(changes.map(\.path), ["g.txt", "n.txt", "u.txt"])
        XCTAssertEqual(changes.map(\.kind), [.modified, .added, .untracked])
        XCTAssertEqual(changes.map(\.additions), [2, 2, 1])
        XCTAssertEqual(changes.map(\.deletions), [0, 0, 0])
    }
}

/// Multi-commit selection in the Log: combined changed files, cumulative diffs, and Store/Project state.
final class MultiCommitSelectionTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-multi-commit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        // c1 (root): a.txt, keep.txt
        try write("a.txt", "one\n")
        try write("keep.txt", "k1\n")
        try git("add", "-A")
        try commit("c1 root", date: "2026-01-01T10:00:00")
        // c2: modify a.txt, add b.txt, add temp.txt
        try write("a.txt", "one\ntwo\n")
        try write("b.txt", "b1\n")
        try write("temp.txt", "t1\n")
        try git("add", "-A")
        try commit("c2 add and modify", date: "2026-01-02T10:00:00")
        // c3: rename b.txt -> b2.txt with edit, modify keep.txt
        try git("mv", "b.txt", "b2.txt")
        try write("b2.txt", "b1\nb2\n")
        try write("keep.txt", "k1\nk2\n")
        try git("add", "-A")
        try commit("c3 rename and modify", date: "2026-01-03T10:00:00")
        // c4: delete temp.txt, add c.txt, modify a.txt
        try git("rm", "-q", "temp.txt")
        try write("c.txt", "c1\n")
        try write("a.txt", "one\ntwo\nthree\n")
        try git("add", "-A")
        try commit("c4 delete add modify", date: "2026-01-04T10:00:00")
        // c5: modify c.txt
        try write("c.txt", "c1\nc2\n")
        try git("add", "-A")
        try commit("c5 modify c", date: "2026-01-05T10:00:00")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func commit(_ message: String, date: String) throws {
        try git("commit", "-q", "-m", message, "--date=\(date)")
    }

    private func git(_ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-c", "user.name=Alice", "-c", "user.email=alice@example.com", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testMultiCommitFileListCombinesAddedModifiedRenamedAndDeletedFiles() async throws {
        let commits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
        // Newest first: [c5, c4, c3, c2, c1]
        XCTAssertEqual(commits.map(\.subject), ["c5 modify c", "c4 delete add modify", "c3 rename and modify", "c2 add and modify", "c1 root"])
        let c5 = commits[0], c4 = commits[1], c3 = commits[2], c2 = commits[3], c1 = commits[4]

        // Single commit delegates cleanly to single-commit behavior.
        let single = try await Git.commitFiles([c3], in: root)
        let singleDirect = try await Git.commitFiles(c3, in: root)
        XCTAssertEqual(single, singleDirect)

        // [c4, c3]: base is c2, head is c4 -> a.txt (M), b2.txt (R b.txt -> b2.txt), c.txt (A), keep.txt (M), temp.txt (D).
        let span34 = try await Git.commitFiles([c4, c3], in: root)
        XCTAssertEqual(span34.map(\.path), ["a.txt", "b2.txt", "c.txt", "keep.txt", "temp.txt"])
        XCTAssertEqual(span34.map(\.kind), [.modified, .renamed, .added, .modified, .deleted])
        XCTAssertEqual(span34.first { $0.path == "b2.txt" }?.oldPath, "b.txt")

        // [c4, c3, c2]: base is c1, head is c4 -> temp.txt was added in c2 and deleted in c4 so it cancels out.
        let span234 = try await Git.commitFiles([c4, c3, c2], in: root)
        XCTAssertEqual(span234.map(\.path), ["a.txt", "b2.txt", "c.txt", "keep.txt"])
        XCTAssertEqual(span234.map(\.kind), [.modified, .added, .added, .modified])

        // Root commit as oldest: [c2, c1] -> base is empty tree, every file at c2 is added.
        let rootSpan = try await Git.commitFiles([c2, c1], in: root)
        XCTAssertEqual(rootSpan.map(\.path), ["a.txt", "b.txt", "keep.txt", "temp.txt"])
        XCTAssertEqual(rootSpan.map(\.kind), [.added, .added, .added, .added])

        // Non-empty single commit at end still unaffected.
        let c5Files = try await Git.commitFiles([c5], in: root)
        XCTAssertEqual(c5Files.map(\.path), ["c.txt"])
    }

    @MainActor
    func testMultiCommitFileDiffCoversCumulativeChangesAndEdgeCases() async throws {
        let commits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
        let c4 = commits[1], c3 = commits[2], c2 = commits[3], c1 = commits[4]
        let project = Project(url: root)
        project.commits = commits

        let span34 = try await Git.commitFiles([c4, c3], in: root)

        // Modified file across [c4, c3]: c2 ("one\ntwo\n") -> c4 ("one\ntwo\nthree\n")
        let modChange = try XCTUnwrap(span34.first { $0.path == "a.txt" })
        let modReq = try XCTUnwrap(project.request(for: modChange, in: [c4, c3], ignoreWhitespace: false))
        XCTAssertEqual(modReq.source, .commit(hash: c4.hash, parent: c2.hash))
        let modDoc = await DiffLoader.load(modReq)
        XCTAssertEqual(modDoc.left.lines, ["one", "two"])
        XCTAssertEqual(modDoc.right.lines, ["one", "two", "three"])
        XCTAssertEqual(modDoc.leftTitle, c2.shortHash)
        XCTAssertEqual(modDoc.rightTitle, c4.shortHash)

        // Renamed + modified file across [c4, c3]: b.txt at c2 -> b2.txt at c4
        let renChange = try XCTUnwrap(span34.first { $0.path == "b2.txt" })
        let renReq = try XCTUnwrap(project.request(for: renChange, in: [c4, c3], ignoreWhitespace: false))
        let renDoc = await DiffLoader.load(renReq)
        XCTAssertEqual(renDoc.left.lines, ["b1"])
        XCTAssertEqual(renDoc.right.lines, ["b1", "b2"])

        // Added file across [c4, c3]: left empty, right at c4
        let addChange = try XCTUnwrap(span34.first { $0.path == "c.txt" })
        let addReq = try XCTUnwrap(project.request(for: addChange, in: [c4, c3], ignoreWhitespace: false))
        let addDoc = await DiffLoader.load(addReq)
        XCTAssertEqual(addDoc.left.lines, [])
        XCTAssertEqual(addDoc.right.lines, ["c1"])

        // Deleted file across [c4, c3]: left at c2, right empty
        let delChange = try XCTUnwrap(span34.first { $0.path == "temp.txt" })
        let delReq = try XCTUnwrap(project.request(for: delChange, in: [c4, c3], ignoreWhitespace: false))
        let delDoc = await DiffLoader.load(delReq)
        XCTAssertEqual(delDoc.left.lines, ["t1"])
        XCTAssertEqual(delDoc.right.lines, [])

        // Root commit as oldest [c2, c1]: parent is nil, left empty with Empty title, right at c2
        let rootSpan = try await Git.commitFiles([c2, c1], in: root)
        let rootMod = try XCTUnwrap(rootSpan.first { $0.path == "a.txt" })
        let rootReq = try XCTUnwrap(project.request(for: rootMod, in: [c2, c1], ignoreWhitespace: false))
        XCTAssertEqual(rootReq.source, .commit(hash: c2.hash, parent: nil))
        let rootDoc = await DiffLoader.load(rootReq)
        XCTAssertEqual(rootDoc.left.lines, [])
        XCTAssertEqual(rootDoc.right.lines, ["one", "two"])
        XCTAssertEqual(rootDoc.leftTitle, L("Empty", "空"))
        XCTAssertEqual(rootDoc.rightTitle, c2.shortHash)
    }

    @MainActor
    func testProjectAndStoreUpdateCommitFilesAndViewerForMultiSelection() async throws {
        let commits = try await Git.log(in: root, skip: 0, limit: 20, query: "", allBranches: false)
        let c5 = commits[0], c4 = commits[1], c3 = commits[2], c2 = commits[3]

        let store = AppStore.shared
        let prevProjects = store.projects
        let prevSelectedProjectID = store.selectedProjectID
        let prevRequest = store.viewer.request
        defer {
            store.projects = prevProjects
            store.selectedProjectID = prevSelectedProjectID
            if let prevRequest {
                store.viewer.open(prevRequest)
            } else {
                store.viewer.clear()
            }
        }

        let project = Project(url: root)
        project.commits = commits
        project.tab = .log
        store.projects = [project]
        store.selectedProjectID = project.id

        // Start with single commit c4 and pick a.txt.
        project.selectedCommitID = c4.id
        await loadCommitAndWait(project, store: store)
        XCTAssertEqual(project.commitFiles.map(\.path), ["a.txt", "c.txt", "temp.txt"])
        project.selectedCommitFileID = ChangeRow.fileID("a.txt")

        // Extend to multi-selection [c4, c3]: a.txt remains present, so selection is preserved and viewer points to c2..c4.
        project.selectedCommitID = c3.id
        project.selectedCommitIDs = [c4.id, c3.id]
        XCTAssertEqual(project.selectedCommits.map(\.id), [c4.id, c3.id])
        await loadCommitAndWait(project, store: store)
        XCTAssertEqual(project.commitFiles.map(\.path), ["a.txt", "b2.txt", "c.txt", "keep.txt", "temp.txt"])
        XCTAssertEqual(project.selectedCommitFileID, ChangeRow.fileID("a.txt"))
        XCTAssertEqual(store.viewer.request?.path, "a.txt")
        XCTAssertEqual(store.viewer.request?.source, .commit(hash: c4.hash, parent: c2.hash))

        // Switch to single commit c5 (only touches c.txt): stale a.txt selection falls back to c.txt.
        project.selectedCommitID = c5.id
        XCTAssertEqual(project.selectedCommitIDs, [c5.id])
        await loadCommitAndWait(project, store: store)
        XCTAssertEqual(project.commitFiles.map(\.path), ["c.txt"])
        XCTAssertEqual(project.selectedCommitFileID, ChangeRow.fileID("c.txt"))
        XCTAssertEqual(store.viewer.request?.source, .commit(hash: c5.hash, parent: c4.hash))

        // Rapid selection change: start [c4, c3], immediately override with [c5] before first finishes.
        project.selectedCommitID = c3.id
        project.selectedCommitIDs = [c4.id, c3.id]
        store.commitSelectionChanged(project)
        project.selectedCommitID = c5.id
        await loadCommitAndWait(project, store: store)
        XCTAssertEqual(project.commitFiles.map(\.path), ["c.txt"])
        XCTAssertEqual(store.viewer.request?.source, .commit(hash: c5.hash, parent: c4.hash))
    }

    @MainActor
    private func loadCommitAndWait(_ project: Project, store: AppStore) async {
        await withCheckedContinuation { continuation in
            project.loadSelectedCommit {
                store.syncViewer()
                continuation.resume()
            }
        }
    }
}

/// Directory-tree grouping, collapse/expand, and flat-list switching for commit file lists.
final class HistoryFileTreeTests: XCTestCase {
    private let nestedFiles = [
        FileChange(path: "a/b/c.go", oldPath: nil, kind: .modified),
        FileChange(path: "a/d.go", oldPath: nil, kind: .added),
        FileChange(path: "root.go", oldPath: nil, kind: .deleted),
    ]

    func testCommitFilesProduceDirectoryTreeWhenGroupedAndOnlyFilesWhenFlat() {
        let treeRows = ChangeTree.rows(changes: nestedFiles, flat: false, collapsed: [], filter: "", splitUnversioned: false)
        XCTAssertEqual(treeRows.map(\.id), [
            "d:c:a",
            "d:c:a/b",
            ChangeRow.fileID("a/b/c.go"),
            ChangeRow.fileID("a/d.go"),
            ChangeRow.fileID("root.go"),
        ])
        XCTAssertEqual(treeRows.map(\.depth), [0, 1, 2, 1, 0])
        if case .directory(let name, let count) = treeRows[0].kind {
            XCTAssertEqual(name, "a")
            XCTAssertEqual(count, 2)
        } else {
            XCTFail("Expected directory row for a")
        }

        let flatRows = ChangeTree.rows(changes: nestedFiles, flat: true, collapsed: [], filter: "", splitUnversioned: false)
        XCTAssertEqual(flatRows.compactMap(\.file).map(\.path), ["a/b/c.go", "a/d.go", "root.go"])
        XCTAssertFalse(flatRows.contains { $0.file == nil })
    }

    func testCollapsingDirectoryHidesDescendantsAndExpandingRestoresThem() {
        let collapsedSubdir = ChangeTree.rows(changes: nestedFiles, flat: false, collapsed: ["d:c:a/b"], filter: "", splitUnversioned: false)
        XCTAssertEqual(collapsedSubdir.map(\.id), [
            "d:c:a",
            "d:c:a/b",
            ChangeRow.fileID("a/d.go"),
            ChangeRow.fileID("root.go"),
        ])
        XCTAssertEqual(collapsedSubdir[1].isExpanded, false)

        let collapsedParent = ChangeTree.rows(changes: nestedFiles, flat: false, collapsed: ["d:c:a"], filter: "", splitUnversioned: false)
        XCTAssertEqual(collapsedParent.map(\.id), [
            "d:c:a",
            ChangeRow.fileID("root.go"),
        ])
        XCTAssertEqual(collapsedParent[0].isExpanded, false)

        let restored = ChangeTree.rows(changes: nestedFiles, flat: false, collapsed: [], filter: "", splitUnversioned: false)
        XCTAssertEqual(restored.compactMap(\.file).map(\.path), ["a/b/c.go", "a/d.go", "root.go"])
    }

    @MainActor
    func testCollapseAllAndExpandAllHelpersAcrossNestedDirectories() {
        let project = Project(url: URL(fileURLWithPath: "/tmp"))
        project.commitFiles = nestedFiles

        XCTAssertEqual(Project.commitFolderIDs(for: nestedFiles), ["d:c:a", "d:c:a/b"])
        XCTAssertEqual(project.commitFolderIDs, ["d:c:a", "d:c:a/b"])

        project.collapseAllCommitFolders()
        XCTAssertEqual(project.commitCollapsed, ["d:c:a", "d:c:a/b"])
        let collapsedRows = ChangeTree.rows(changes: project.commitFiles, flat: false, collapsed: project.commitCollapsed,
                                            filter: "", splitUnversioned: false)
        XCTAssertEqual(collapsedRows.map(\.id), ["d:c:a", ChangeRow.fileID("root.go")])

        project.expandAllCommitFolders()
        XCTAssertEqual(project.commitCollapsed, [])
        let expandedRows = ChangeTree.rows(changes: project.commitFiles, flat: false, collapsed: project.commitCollapsed,
                                           filter: "", splitUnversioned: false)
        XCTAssertEqual(expandedRows.compactMap(\.file).map(\.path), ["a/b/c.go", "a/d.go", "root.go"])
    }

    @MainActor
    func testMultiCommitRealRepoFilesGroupByDirectoryAndResetOrPruneCollapsedState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-history-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func git(_ arguments: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Git.executable)
            process.arguments = ["-c", "user.name=Alice", "-c", "user.email=alice@example.com", "-c", "commit.gpgsign=false"] + arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
        }

        func write(_ path: String, _ text: String) throws {
            let fileURL = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL)
        }

        try git("init", "-q", "-b", "main")
        try write("root.go", "package main\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "c1 init")

        try write("a/d.go", "package a\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "c2 add a/d.go")

        try write("a/b/c.go", "package b\n")
        try git("add", "-A")
        try git("commit", "-q", "-m", "c3 add a/b/c.go")

        let commits = try await Git.log(in: root, skip: 0, limit: 10, query: "", allBranches: false)
        XCTAssertEqual(commits.count, 3)
        let c3 = commits[0], c2 = commits[1], c1 = commits[2]

        let project = Project(url: root)
        project.commits = commits

        // Select c3 (single commit with compacted directory a/b).
        project.selectedCommitID = c3.id
        await withCheckedContinuation { continuation in
            project.loadSelectedCommit { continuation.resume() }
        }
        XCTAssertEqual(project.commitFolderIDs, ["d:c:a/b"])
        project.collapseAllCommitFolders()
        XCTAssertEqual(project.commitCollapsed, ["d:c:a/b"])

        // Extend to overlapping multi-selection [c3, c2]: a/b stays collapsed while new parent a is expanded.
        project.selectedCommitID = c2.id
        project.selectedCommitIDs = [c3.id, c2.id]
        await withCheckedContinuation { continuation in
            project.loadSelectedCommit { continuation.resume() }
        }
        XCTAssertEqual(project.commitFolderIDs, ["d:c:a", "d:c:a/b"])
        XCTAssertEqual(project.commitCollapsed, ["d:c:a/b"])
        let multiRows = ChangeTree.rows(changes: project.commitFiles, flat: false, collapsed: project.commitCollapsed,
                                        filter: "", splitUnversioned: false)
        XCTAssertEqual(multiRows.map(\.id), ["d:c:a", "d:c:a/b", ChangeRow.fileID("a/d.go")])

        // Switch to unrelated commit c1: stale collapsed state resets cleanly.
        project.selectedCommitID = c1.id
        await withCheckedContinuation { continuation in
            project.loadSelectedCommit { continuation.resume() }
        }
        XCTAssertEqual(project.commitCollapsed, [])
    }
}
