import XCTest
@testable import DifKit

final class LogAuthorFilterTests: XCTestCase {
    func testEscapeEREHandlesAllMetacharacters() {
        let raw = #"C++ Dev (Bot) [v1.0] {a|b} ^$*+?.\"#
        let escaped = Git.escapeERE(raw)
        XCTAssertEqual(escaped, #"C\+\+ Dev \(Bot\) \[v1\.0\] \{a\|b\} \^\$\*\+\?\.\\"#)
        XCTAssertEqual(Git.escapeERE("张三"), "张三")
        XCTAssertEqual(Git.escapeERE("alice-dev_01"), "alice-dev_01")
    }

    func testParseShortlogGroupAndEmailFallback() {
        let groupRaw = """
             12\tAlice\u{1F}alice@example.com
              5\t张三\u{1F}zs@example.com
              3\tC++ Dev (Bot) [v1]\u{1F}dev+1@a.b.com
              2\tAlice\u{1F}alice@example.com
              1\tNoEmail\u{1F}
        """
        let grouped = Git.parseShortlogGroup(Data(groupRaw.utf8))
        XCTAssertEqual(grouped, [
            LogAuthor(author: AuthorFilter(name: "Alice", email: "alice@example.com"), commitCount: 14),
            LogAuthor(author: AuthorFilter(name: "张三", email: "zs@example.com"), commitCount: 5),
            LogAuthor(author: AuthorFilter(name: "C++ Dev (Bot) [v1]", email: "dev+1@a.b.com"), commitCount: 3),
            LogAuthor(author: AuthorFilter(name: "NoEmail", email: ""), commitCount: 1),
        ])

        let emailRaw = """
             10\tBob <bob@example.com>
              4\tJohn < Smith <john@example.com>
              2\tNoEmail <>
        """
        let parsedEmail = Git.parseShortlogEmail(Data(emailRaw.utf8))
        XCTAssertEqual(parsedEmail, [
            LogAuthor(author: AuthorFilter(name: "Bob", email: "bob@example.com"), commitCount: 10),
            LogAuthor(author: AuthorFilter(name: "John < Smith", email: "john@example.com"), commitCount: 4),
            LogAuthor(author: AuthorFilter(name: "NoEmail", email: ""), commitCount: 2),
        ])
    }

    func testAuthorSearchSupportsSingleMultiTermAndFuzzy() {
        let alice = AuthorFilter(name: "Alice", email: "alice@example.com")
        let bob = AuthorFilter(name: "Bob", email: "bob@example.com")
        let johnSmith = AuthorFilter(name: "John Smith", email: "jsmith@example.com")
        let zhangSan = AuthorFilter(name: "张三", email: "zhangsan@example.com")
        let liSi = AuthorFilter(name: "李四", email: "lisi@example.com")
        let wenhuxian = AuthorFilter(name: "wenhuxian", email: "whx@example.com")
        let carol = AuthorFilter(name: "Carol", email: "carol@example.com")

        let pool = [
            LogAuthor(author: alice, commitCount: 20),
            LogAuthor(author: bob, commitCount: 15),
            LogAuthor(author: johnSmith, commitCount: 12),
            LogAuthor(author: zhangSan, commitCount: 8),
            LogAuthor(author: liSi, commitCount: 6),
            LogAuthor(author: wenhuxian, commitCount: 30),
        ]

        // Empty query pins selected authors (including ones absent from current scope) first.
        let emptyResult = AuthorSearch.filter(pool, query: "", selected: [carol, bob])
        XCTAssertEqual(emptyResult.prefix(2).map(\.author), [bob, carol])
        XCTAssertEqual(emptyResult[1].commitCount, 0)
        XCTAssertEqual(emptyResult.count, pool.count + 1)

        // Single substring match by name or email.
        XCTAssertEqual(AuthorSearch.filter(pool, query: "ali", selected: []).map(\.author), [alice])
        XCTAssertEqual(AuthorSearch.filter(pool, query: "bob@example", selected: []).map(\.author), [bob])

        // Explicit multi-term separators (comma, ideographic comma, semicolon, pipe).
        XCTAssertEqual(Set(AuthorSearch.filter(pool, query: "张三、李四", selected: []).map(\.author)), [zhangSan, liSi])
        XCTAssertEqual(Set(AuthorSearch.filter(pool, query: "alice, bob", selected: []).map(\.author)), [alice, bob])
        XCTAssertEqual(Set(AuthorSearch.filter(pool, query: "alice;bob|李四", selected: []).map(\.author)), [alice, bob, liSi])

        // Full name with space stays an exact/substring match rather than splitting.
        XCTAssertEqual(AuthorSearch.filter(pool, query: "John Smith", selected: []).map(\.author), [johnSmith])

        // Space-separated multiple names fall back to OR when whole query matches no single author.
        XCTAssertEqual(Set(AuthorSearch.filter(pool, query: "Alice Bob", selected: []).map(\.author)), [alice, bob])
        XCTAssertEqual(Set(AuthorSearch.filter(pool, query: "张三 李四", selected: []).map(\.author)), [zhangSan, liSi])

        // ASCII fuzzy match works; CJK does not falsely fuzzy-match via raw UTF-8 bytes.
        XCTAssertTrue(AuthorSearch.filter(pool, query: "whx", selected: []).contains { $0.author == wenhuxian })
        XCTAssertTrue(AuthorSearch.filter(pool, query: "王五", selected: []).isEmpty)
    }

    func testContiguousLinearChainDetection() {
        func commit(_ hash: String, parents: [String]) -> Commit {
            Commit(hash: hash, parents: parents, author: "a", email: "a@x", date: Date(), refs: [], subject: hash)
        }
        let c3 = commit("3333333", parents: ["2222222"])
        let c2 = commit("2222222", parents: ["1111111"])
        let c1 = commit("1111111", parents: [])
        let cMerge = commit("4444444", parents: ["3333333", "9999999"])

        XCTAssertTrue(Git.isContiguousLinearChain([c3]))
        XCTAssertTrue(Git.isContiguousLinearChain([c3, c2, c1]))
        XCTAssertFalse(Git.isContiguousLinearChain([c3, c1]))
        XCTAssertFalse(Git.isContiguousLinearChain([cMerge, c3]))
    }

    func testParseBatchedNameStatusAndNumstat() {
        let h1 = String(repeating: "a", count: 40)
        let h2 = String(repeating: "b", count: 40)
        let h3 = String(repeating: "c", count: 40)

        let rawNames = "\u{1E}\(h1)\0\nR090\0old.txt\0new.txt\0\u{1E}\(h2)\n\u{1E}\(h3)\0\nA\0added.txt\0"
        let parsedNames = Git.parseBatchedNameStatus(Data(rawNames.utf8))
        XCTAssertEqual(parsedNames[h1], [FileChange(path: "new.txt", oldPath: "old.txt", kind: .renamed)])
        XCTAssertEqual(parsedNames[h2], [])
        XCTAssertEqual(parsedNames[h3], [FileChange(path: "added.txt", oldPath: nil, kind: .added)])

        let rawStats = "\u{1E}\(h1)\0\n3\t1\t\0old.txt\0new.txt\0\u{1E}\(h2)\n\u{1E}\(h3)\0\n5\t0\tadded.txt\0"
        let parsedStats = Git.parseBatchedNumstat(Data(rawStats.utf8))
        XCTAssertEqual(parsedStats[h1]?["new.txt"]?.0, 3)
        XCTAssertEqual(parsedStats[h1]?["new.txt"]?.1, 1)
        XCTAssertEqual(parsedStats[h2]?.isEmpty, true)
        XCTAssertEqual(parsedStats[h3]?["added.txt"]?.0, 5)
        XCTAssertEqual(parsedStats[h3]?["added.txt"]?.1, 0)
    }
}

final class LogAuthorFilterRepositoryTests: XCTestCase {
    private var root: URL!

    private let alice = AuthorFilter(name: "Alice", email: "alice@example.com")
    private let bob = AuthorFilter(name: "Bob", email: "bob@example.com")
    private let bot = AuthorFilter(name: "C++ Dev (Bot) [v1]", email: "dev+1@a.b.com")
    private let zhangSan = AuthorFilter(name: "张三", email: "zhangsan@example.com")
    private let zhang = AuthorFilter(name: "张", email: "zhang@example.com")
    private let noEmail = AuthorFilter(name: "NoEmail", email: "")
    private let carol = AuthorFilter(name: "Carol", email: "carol@example.com")

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-author-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")

        try write("f.txt", "line1\nline2\nline3\nline4\n")
        try git("add", "-A")
        try commit(by: alice, message: "alice initial", date: "2026-01-01T10:00:00Z")

        try write("f.txt", "line1\nLINE2\nline3\nline4\n")
        try git("add", "-A")
        try commit(by: bob, message: "bob edit line2", date: "2026-01-02T10:00:00Z")

        try write("notes.txt", "bot note\n")
        try git("add", "-A")
        try commit(by: bot, message: "bot [urgent] fix", date: "2026-01-03T10:00:00Z")

        try git("mv", "f.txt", "g.txt")
        try commit(by: zhangSan, message: "zhangsan rename", date: "2026-01-04T10:00:00Z")

        try write("other.txt", "zhang\n")
        try git("add", "-A")
        try commit(by: zhang, message: "zhang commit", date: "2026-01-05T10:00:00Z")

        try write("empty_email.txt", "none\n")
        try git("add", "-A")
        try commit(by: noEmail, message: "no email commit", date: "2026-01-06T10:00:00Z")

        try write("g.txt", "line1\nLINE2\nLINE3\nline4\n")
        try git("add", "-A")
        try commit(by: alice, message: "alice [urgent] line3", date: "2026-01-07T10:00:00Z")

        try git("checkout", "-q", "-b", "feature")
        try write("feature.txt", "carol\n")
        try git("add", "-A")
        try commit(by: carol, message: "carol feature", date: "2026-01-08T10:00:00Z")
        try git("checkout", "-q", "main")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    private func commit(by author: AuthorFilter, message: String, date: String) throws {
        try git(
            "-c", "user.name=\(author.name)",
            "-c", "user.email=\(author.email)",
            "commit", "-q", "-m", message, "--date=\(date)"
        )
    }

    private func git(_ arguments: String...) throws {
        try git(arguments)
    }

    private func git(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    func testAuthorsListsCountsByScopeAndHandlesEmptyRepo() async throws {
        let mainAuthors = try await Git.authors(in: root, allBranches: false)
        XCTAssertEqual(mainAuthors.first, LogAuthor(author: alice, commitCount: 2))
        XCTAssertFalse(mainAuthors.contains { $0.author == carol })

        let allAuthors = try await Git.authors(in: root, allBranches: true)
        XCTAssertTrue(allAuthors.contains(LogAuthor(author: carol, commitCount: 1)))

        let pathAuthors = try await Git.authors(in: root, allBranches: false, paths: ["g.txt", "f.txt"])
        XCTAssertEqual(Set(pathAuthors.map(\.author)), [alice, bob, zhangSan])

        let emptyRoot = FileManager.default.temporaryDirectory.appendingPathComponent("dif-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyRoot) }
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: Git.executable)
        initProc.arguments = ["init", "-q", "-b", "main"]
        initProc.currentDirectoryURL = emptyRoot
        try initProc.run()
        initProc.waitUntilExit()
        let emptyHeadAuthors = try await Git.authors(in: emptyRoot, allBranches: false)
        let emptyAllAuthors = try await Git.authors(in: emptyRoot, allBranches: true)
        XCTAssertEqual(emptyHeadAuthors, [])
        XCTAssertEqual(emptyAllAuthors, [])
    }

    func testLogFiltersMultipleAuthorsExactlyWithPagination() async throws {
        let aliceAndBob = try await Git.log(in: root, skip: 0, limit: 50, query: "", authors: [alice, bob], allBranches: false)
        XCTAssertEqual(aliceAndBob.map(\.subject), ["alice [urgent] line3", "bob edit line2", "alice initial"])

        let page = try await Git.log(in: root, skip: 1, limit: 1, query: "", authors: [alice, bob], allBranches: false)
        XCTAssertEqual(page.map(\.subject), ["bob edit line2"])

        // Selecting "张" must not accidentally match "张三".
        let onlyZhang = try await Git.log(in: root, skip: 0, limit: 50, query: "", authors: [zhang], allBranches: false)
        XCTAssertEqual(onlyZhang.map(\.subject), ["zhang commit"])

        // Regex metacharacters and empty emails match accurately.
        let special = try await Git.log(in: root, skip: 0, limit: 50, query: "", authors: [bot, noEmail], allBranches: false)
        XCTAssertEqual(special.map(\.subject), ["no email commit", "bot [urgent] fix"])

        // Branch scope still applies alongside author filtering.
        let featureOnly = try await Git.log(in: root, skip: 0, limit: 50, query: "", authors: [carol], allBranches: false)
        XCTAssertTrue(featureOnly.isEmpty)
        let acrossBranches = try await Git.log(in: root, skip: 0, limit: 50, query: "", authors: [carol, bob], allBranches: true)
        XCTAssertEqual(acrossBranches.map(\.subject), ["carol feature", "bob edit line2"])
    }

    func testLogCombinesMultipleAuthorsWithQueryAndHash() async throws {
        let urgentByAliceOrBob = try await Git.log(in: root, skip: 0, limit: 50, query: "[urgent]",
                                                   authors: [alice, bob], allBranches: false)
        XCTAssertEqual(urgentByAliceOrBob.map(\.subject), ["alice [urgent] line3"])

        let aliceHash = try await Git.runString(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let aliceShort = String(aliceHash.prefix(7))
        let zhangHash = try await Git.runString(["rev-parse", "HEAD~2"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let zhangShort = String(zhangHash.prefix(7))

        let hitAlice = try await Git.log(in: root, skip: 0, limit: 50, query: aliceShort, authors: [alice, bob], allBranches: false)
        XCTAssertEqual(hitAlice.map(\.subject), ["alice [urgent] line3"])

        let missZhang = try await Git.log(in: root, skip: 0, limit: 50, query: zhangShort, authors: [alice, bob], allBranches: false)
        XCTAssertTrue(missZhang.isEmpty)
    }

    func testFileHistoryAndLineHistoryFilterByMultipleAuthors() async throws {
        let fileFiltered = try await Git.fileHistory("g.txt", in: root, skip: 0, limit: 50, authors: [alice, bob])
        XCTAssertEqual(fileFiltered.commits.map(\.subject), ["alice [urgent] line3", "bob edit line2", "alice initial"])

        let fileSearchFiltered = try await Git.fileHistory("g.txt", in: root, skip: 0, limit: 50,
                                                           query: "line2", authors: [alice, bob])
        XCTAssertEqual(fileSearchFiltered.commits.map(\.subject), ["bob edit line2"])

        let linesFiltered = try await Git.lineHistory("g.txt", lines: 2...3, rev: "HEAD", in: root, skip: 0, limit: 50,
                                                      authors: [alice, bob])
        XCTAssertEqual(linesFiltered.map(\.subject), ["alice [urgent] line3", "bob edit line2", "alice initial"])

        let linesBobOnly = try await Git.lineHistory("g.txt", lines: 2...3, rev: "HEAD", in: root, skip: 0, limit: 50,
                                                     authors: [bob])
        XCTAssertEqual(linesBobOnly.map(\.subject), ["bob edit line2"])
    }

    func testNonContiguousAuthorSelectionExcludesOutsiderFilesAndEdits() async throws {
        let ltw = AuthorFilter(name: "ltw", email: "ltw@example.com")
        let xiwu = AuthorFilter(name: "xiwu", email: "xiwu@example.com")
        let cas = AuthorFilter(name: "cas", email: "cas@example.com")

        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-noncontig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func runRepoGit(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Git.executable)
            process.arguments = ["-c", "commit.gpgsign=false"] + args
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
        func writeRepo(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: repo.appendingPathComponent(path))
        }
        func commitRepo(by author: AuthorFilter, message: String, date: String) throws {
            try runRepoGit("-c", "user.name=\(author.name)", "-c", "user.email=\(author.email)",
                           "commit", "-q", "-m", message, "--date=\(date)")
        }

        let baseLines = (1...20).map { "line \($0)" }
        try runRepoGit("init", "-q", "-b", "main")
        try writeRepo("shared.txt", baseLines.joined(separator: "\n") + "\n")
        try writeRepo("conflict.txt", baseLines.joined(separator: "\n") + "\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: cas, message: "initial base", date: "2026-02-01T10:00:00Z")
        let baseHash = try await Git.runString(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)

        // Side branch by cas (merged later by ltw).
        try runRepoGit("checkout", "-q", "-b", "cas-side")
        try writeRepo("cas_branch.txt", "cas branch work\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: cas, message: "cas side branch", date: "2026-02-02T10:00:00Z")
        try runRepoGit("checkout", "-q", "main")

        // 1. ltw edits shared.txt line 2 and adds ltw_only.txt
        var l1 = baseLines
        l1[1] = "line 2 ltw"
        try writeRepo("shared.txt", l1.joined(separator: "\n") + "\n")
        try writeRepo("ltw_only.txt", "ltw file\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: ltw, message: "ltw step 1", date: "2026-02-03T10:00:00Z")

        // 2. cas edits shared.txt line 9 (disjoint), conflict.txt line 5, and adds cas_only.txt
        var l2 = l1
        l2[8] = "line 9 cas"
        var c2 = baseLines
        c2[4] = "line 5 cas"
        try writeRepo("shared.txt", l2.joined(separator: "\n") + "\n")
        try writeRepo("conflict.txt", c2.joined(separator: "\n") + "\n")
        try writeRepo("cas_only.txt", "cas file\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: cas, message: "cas middle", date: "2026-02-04T10:00:00Z")

        // 3. ltw merges cas-side (merge commit)
        try runRepoGit("-c", "user.name=\(ltw.name)", "-c", "user.email=\(ltw.email)",
                       "merge", "-q", "--no-ff", "cas-side", "-m", "ltw merge cas-side")

        // 4. xiwu edits shared.txt line 15 (disjoint), conflict.txt line 5 (overlaps cas), renames ltw_only.txt -> renamed.txt
        var l3 = l2
        l3[14] = "line 15 xiwu"
        var c3 = c2
        c3[4] = "line 5 xiwu"
        try writeRepo("shared.txt", l3.joined(separator: "\n") + "\n")
        try writeRepo("conflict.txt", c3.joined(separator: "\n") + "\n")
        try runRepoGit("mv", "ltw_only.txt", "renamed.txt")
        try runRepoGit("add", "-A")
        try commitRepo(by: xiwu, message: "xiwu step 2", date: "2026-02-05T10:00:00Z")

        // 5. ltw edits conflict.txt line 2 (selected earlier step so conflict.txt has 2 selected steps with overlapping cas in between)
        // Add an earlier ltw edit on conflict.txt line 12? Actually let's check all commits of ltw + xiwu:
        let filtered = try await Git.log(in: repo, skip: 0, limit: 50, query: "", authors: [ltw, xiwu], allBranches: false)
        XCTAssertEqual(filtered.count, 3)

        let summary = try await Git.commitSelectionSummary(filtered, in: repo)
        XCTAssertTrue(summary.isNonContiguous)
        XCTAssertEqual(summary.skippedMergeCount, 1)
        XCTAssertEqual(summary.files.map(\.path), ["conflict.txt", "renamed.txt", "shared.txt"])

        let sharedSteps = try XCTUnwrap(summary.fileSteps["shared.txt"])
        let sharedDoc = await DiffLoader.load(DiffRequest(
            root: repo,
            path: "shared.txt",
            oldPath: nil,
            kind: .modified,
            source: .commitSteps(sharedSteps)
        ))
        XCTAssertTrue(sharedDoc.isSyntheticReplay)
        XCTAssertNil(sharedDoc.note)
        XCTAssertEqual(sharedDoc.right.lines[1], "line 2 ltw")
        XCTAssertEqual(sharedDoc.right.lines[8], "line 9") // cas's edit is excluded!
        XCTAssertEqual(sharedDoc.right.lines[14], "line 15 xiwu")
        XCTAssertEqual(sharedDoc.hunks.count, 2)

        let renamedSteps = try XCTUnwrap(summary.fileSteps["renamed.txt"])
        let renamedChange = try XCTUnwrap(summary.files.first { $0.path == "renamed.txt" })
        XCTAssertEqual(renamedChange.kind, .added)
        let renamedDoc = await DiffLoader.load(DiffRequest(
            root: repo,
            path: renamedChange.path,
            oldPath: renamedChange.oldPath,
            kind: renamedChange.kind,
            source: .commitSteps(renamedSteps)
        ))
        XCTAssertFalse(renamedDoc.isSyntheticReplay)
        XCTAssertNil(renamedDoc.note)
        XCTAssertEqual(renamedDoc.right.lines, ["ltw file"])

        // Contiguous selection without filter preserves fast path.
        let allCommits = try await Git.log(in: repo, skip: 0, limit: 50, query: "", allBranches: false)
        let linearCommits = allCommits.filter { $0.hash != baseHash && !$0.isMerge }
        XCTAssertFalse(Git.isContiguousLinearChain(linearCommits))
        let newestSingle = try await Git.commitSelectionSummary([allCommits[0]], in: repo)
        XCTAssertFalse(newestSingle.isNonContiguous)

        // Overlapping conflict fallback test: ltw edits line 5, cas edits line 5, xiwu edits line 5.
        let conflictRepo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: conflictRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: conflictRepo) }

        func runConflictGit(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Git.executable)
            p.arguments = ["-c", "commit.gpgsign=false"] + args
            p.currentDirectoryURL = conflictRepo
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
        try runConflictGit("init", "-q", "-b", "main")
        try Data("1\n2\n3\n".utf8).write(to: conflictRepo.appendingPathComponent("f.txt"))
        try runConflictGit("add", "-A")
        try runConflictGit("-c", "user.name=\(cas.name)", "-c", "user.email=\(cas.email)", "commit", "-q", "-m", "base", "--date=2026-03-01T10:00:00Z")
        try Data("1\n2_ltw\n3\n".utf8).write(to: conflictRepo.appendingPathComponent("f.txt"))
        try runConflictGit("-c", "user.name=\(ltw.name)", "-c", "user.email=\(ltw.email)", "commit", "-q", "-am", "ltw", "--date=2026-03-02T10:00:00Z")
        try Data("1\n2_cas\n3\n".utf8).write(to: conflictRepo.appendingPathComponent("f.txt"))
        try runConflictGit("-c", "user.name=\(cas.name)", "-c", "user.email=\(cas.email)", "commit", "-q", "-am", "cas", "--date=2026-03-03T10:00:00Z")
        try Data("1\n2_xiwu\n3\n".utf8).write(to: conflictRepo.appendingPathComponent("f.txt"))
        try runConflictGit("-c", "user.name=\(xiwu.name)", "-c", "user.email=\(xiwu.email)", "commit", "-q", "-am", "xiwu", "--date=2026-03-04T10:00:00Z")

        let allConflictCommits = try await Git.log(in: conflictRepo, skip: 0, limit: 50, query: "", allBranches: false)
        XCTAssertTrue(Git.isContiguousLinearChain(allConflictCommits))
        let contiguousSummary = try await Git.commitSelectionSummary(allConflictCommits, in: conflictRepo)
        XCTAssertFalse(contiguousSummary.isNonContiguous)

        let selected = try await Git.log(in: conflictRepo, skip: 0, limit: 50, query: "", authors: [ltw, xiwu], allBranches: false)
        XCTAssertEqual(selected.count, 2)
        let conflictSummary = try await Git.commitSelectionSummary(selected, in: conflictRepo)
        let conflictSteps = try XCTUnwrap(conflictSummary.fileSteps["f.txt"])
        XCTAssertEqual(conflictSteps.count, 2)
        let conflictDoc = await DiffLoader.load(DiffRequest(
            root: conflictRepo,
            path: "f.txt",
            oldPath: nil,
            kind: .modified,
            source: .commitSteps(conflictSteps)
        ))
        XCTAssertFalse(conflictDoc.isSyntheticReplay)
        XCTAssertNotNil(conflictDoc.note)
        XCTAssertFalse(conflictDoc.right.lines.contains(where: { $0.contains("<<<<<<<") }))
    }

    func testMailmapMergesAuthorsAndFiltersAcrossLogFileHistoryAndLineHistory() async throws {
        let canonical = AuthorFilter(name: "Canonical Dev", email: "canon@example.com")
        let aliasOne = AuthorFilter(name: "Alias One", email: "old1@example.com")
        let aliasTwo = AuthorFilter(name: "Alias Two", email: "old2@example.com")
        let other = AuthorFilter(name: "Other Dev", email: "other@example.com")

        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-mailmap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        func runRepoGit(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Git.executable)
            process.arguments = ["-c", "commit.gpgsign=false", "-c", "log.mailmap=false"] + args
            process.currentDirectoryURL = repo
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(args.joined(separator: " "))")
        }
        func writeRepo(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: repo.appendingPathComponent(path))
        }
        func commitRepo(by author: AuthorFilter, message: String, date: String) throws {
            try runRepoGit("-c", "user.name=\(author.name)", "-c", "user.email=\(author.email)",
                           "commit", "-q", "-m", message, "--date=\(date)")
        }

        try runRepoGit("init", "-q", "-b", "main")
        try writeRepo("app.txt", "line1\nline2\nline3\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: aliasOne, message: "alias one initial", date: "2026-04-01T10:00:00Z")

        try writeRepo("app.txt", "line1\nline2 other\nline3\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: other, message: "other edit", date: "2026-04-02T10:00:00Z")

        try writeRepo("app.txt", "line1\nline2 alias2\nline3\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: aliasTwo, message: "alias two edit", date: "2026-04-03T10:00:00Z")

        try writeRepo("extra.txt", "canon work\n")
        try runRepoGit("add", "-A")
        try commitRepo(by: canonical, message: "canonical add", date: "2026-04-04T10:00:00Z")

        let mailmap = """
        Canonical Dev <canon@example.com> Alias One <old1@example.com>
        Canonical Dev <canon@example.com> <old2@example.com>
        """
        try writeRepo(".mailmap", mailmap)

        // 1. Git.authors merges aliases into a single canonical author with combined commit count.
        let authors = try await Git.authors(in: repo, allBranches: false)
        XCTAssertEqual(authors, [
            LogAuthor(author: canonical, commitCount: 3),
            LogAuthor(author: other, commitCount: 1),
        ])

        // 2. Git.log displays canonical author/email on every mapped commit and filters all aliases.
        let allLog = try await Git.log(in: repo, skip: 0, limit: 50, query: "", allBranches: false)
        XCTAssertEqual(allLog.count, 4)
        XCTAssertEqual(allLog.filter { AuthorFilter.from($0) == canonical }.count, 3)

        let filteredLog = try await Git.log(in: repo, skip: 0, limit: 50, query: "", authors: [canonical], allBranches: false)
        XCTAssertEqual(filteredLog.map(\.subject), ["canonical add", "alias two edit", "alias one initial"])

        let searchedByAuthor = try await Git.log(in: repo, skip: 0, limit: 50, query: "Canonical Dev", allBranches: false)
        XCTAssertEqual(searchedByAuthor.map(\.subject), ["canonical add", "alias two edit", "alias one initial"])

        // 3. Git.fileHistory merges and filters mapped commits consistently.
        let fileFiltered = try await Git.fileHistory("app.txt", in: repo, skip: 0, limit: 50, authors: [canonical])
        XCTAssertEqual(fileFiltered.commits.map(\.subject), ["alias two edit", "alias one initial"])
        XCTAssertTrue(fileFiltered.commits.allSatisfy { AuthorFilter.from($0) == canonical })

        // 4. Git.lineHistory and lineHistoryEntries respect .mailmap when filtering and displaying commits.
        let lineFiltered = try await Git.lineHistory("app.txt", lines: 2...2, rev: "HEAD", in: repo,
                                                     skip: 0, limit: 50, authors: [canonical])
        XCTAssertEqual(lineFiltered.map(\.subject), ["alias two edit", "alias one initial"])
        XCTAssertTrue(lineFiltered.allSatisfy { AuthorFilter.from($0) == canonical })

        let lineEntries = try await Git.lineHistoryEntries("app.txt", lines: 2...2, rev: "HEAD", in: repo,
                                                           skip: 0, limit: 50, authors: [canonical])
        XCTAssertEqual(lineEntries.map(\.commit.subject), ["alias two edit", "alias one initial"])
        XCTAssertTrue(lineEntries.allSatisfy { AuthorFilter.from($0.commit) == canonical })
    }
}
