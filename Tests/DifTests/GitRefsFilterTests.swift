import XCTest
@testable import DifKit

/// Filtering non-standard internal Git refs (`refs/t3/*`, `refs/notes/*`, `refs/stash`) out of "All branches" by default.
final class GitRefsFilterTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dif-refs-filter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = [
            "-c", "user.name=Dif Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "commit.gpgsign=false",
        ] + arguments
        process.currentDirectoryURL = root
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed: \(stderr)")
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates an orphan commit not reachable from any branch/tag and points `ref` at it.
    private func createOrphanRef(_ ref: String, file: String, content: String, message: String) throws -> String {
        let tmp = root.appendingPathComponent(".git/tmp-blob-\(UUID().uuidString)")
        try Data(content.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let blobHash = try git("hash-object", "-w", tmp.path)
        let treeInput = "100644 blob \(blobHash)\t\(file)\n"
        let treeHash = try gitWithInput(treeInput, "mktree")
        let commitHash = try git("commit-tree", treeHash, "-m", message)
        try git("update-ref", ref, commitHash)
        return commitHash
    }

    private func gitWithInput(_ input: String, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = [
            "-c", "user.name=Dif Tests",
            "-c", "user.email=tests@example.invalid",
            "-c", "commit.gpgsign=false",
        ] + arguments
        process.currentDirectoryURL = root
        let stdin = Pipe()
        let out = Pipe()
        let err = Pipe()
        process.standardInput = stdin
        process.standardOutput = out
        process.standardError = err
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed: \(stderr)")
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testAllBranchesScopeHelpers() {
        XCTAssertEqual(Git.allBranchesScope(), ["--ignore-missing", "HEAD", "--branches", "--remotes", "--tags"])
        XCTAssertEqual(Git.allBranchesScope(includeInternalRefs: false), ["--ignore-missing", "HEAD", "--branches", "--remotes", "--tags"])
        XCTAssertEqual(Git.allBranchesScope(includeInternalRefs: true), ["--all"])
    }

    func testAllBranchesExcludesInternalRefsByDefaultAndIncludesWhenRequested() async throws {
        try git("init", "-q", "-b", "main")
        try write("app.txt", "main 1\n")
        try git("add", "app.txt")
        try git("commit", "-q", "-m", "main commit")
        let mainHash = try git("rev-parse", "HEAD")

        try git("checkout", "-q", "-b", "feature")
        try write("app.txt", "feature 1\n")
        try git("commit", "-aq", "-m", "feature commit")
        let featureHash = try git("rev-parse", "HEAD")

        try git("checkout", "-q", "main")
        try git("checkout", "-q", "--detach", mainHash)
        try write("detached.txt", "detached\n")
        try git("add", "detached.txt")
        try git("commit", "-q", "-m", "detached commit")
        let detachedHash = try git("rev-parse", "HEAD")

        try git("checkout", "-q", "main")
        try git("tag", "v1.0", featureHash)
        let tagTargetHash = featureHash

        // Re-create a detached commit not pointed to by any branch/tag, then keep HEAD on it to verify HEAD is included.
        try git("checkout", "-q", "--detach", detachedHash)

        // Internal T3 checkpoint ref pointing to an unrelated orphan commit.
        let t3Hash = try createOrphanRef("refs/t3/orchestration-v2/checkpoint/1",
                                         file: "app.txt",
                                         content: "t3 internal checkpoint\n",
                                         message: "t3 checkpoint 1")

        // Default `allBranches: true` excludes `refs/t3/*` while keeping main, feature, tag, and detached HEAD.
        let standard = try await Git.log(in: root, skip: 0, limit: 50, query: "", allBranches: true)
        let standardHashes = Set(standard.map(\.hash))
        XCTAssertTrue(standardHashes.contains(mainHash))
        XCTAssertTrue(standardHashes.contains(featureHash))
        XCTAssertTrue(standardHashes.contains(tagTargetHash))
        XCTAssertTrue(standardHashes.contains(detachedHash))
        XCTAssertFalse(standardHashes.contains(t3Hash))

        // `includeInternalRefs: true` includes the `refs/t3/...` checkpoint commit as well.
        let withInternal = try await Git.log(in: root, skip: 0, limit: 50, query: "", allBranches: true, includeInternalRefs: true)
        let internalHashes = Set(withInternal.map(\.hash))
        XCTAssertTrue(internalHashes.contains(mainHash))
        XCTAssertTrue(internalHashes.contains(featureHash))
        XCTAssertTrue(internalHashes.contains(detachedHash))
        XCTAssertTrue(internalHashes.contains(t3Hash))

        // File history using `Git.allBranchesScope(includeInternalRefs: false)` also excludes internal refs.
        let fileHistoryStandard = try await Git.fileHistory("app.txt", in: root, skip: 0, limit: 50,
                                                            scope: Git.allBranchesScope(includeInternalRefs: false))
        let fileHistoryHashes = Set(fileHistoryStandard.commits.map(\.hash))
        XCTAssertTrue(fileHistoryHashes.contains(mainHash))
        XCTAssertTrue(fileHistoryHashes.contains(featureHash))
        XCTAssertFalse(fileHistoryHashes.contains(t3Hash))
    }

    func testUnbornHeadWithAndWithoutCommits() async throws {
        try git("init", "-q", "-b", "main")

        // Empty repository with unborn HEAD returns empty without throwing.
        let empty = try await Git.log(in: root, skip: 0, limit: 50, query: "", allBranches: true)
        XCTAssertTrue(empty.isEmpty)

        // Commit on `main`, then switch to an unborn orphan branch: `main` is still returned.
        try write("readme.md", "hi\n")
        try git("add", "readme.md")
        try git("commit", "-q", "-m", "initial")
        let mainHash = try git("rev-parse", "HEAD")

        try git("checkout", "-q", "--orphan", "unborn")
        let commits = try await Git.log(in: root, skip: 0, limit: 50, query: "", allBranches: true)
        XCTAssertEqual(commits.map(\.hash), [mainHash])
    }

    @MainActor
    func testGitGraphModelToggleInternalRefs() async throws {
        try git("init", "-q", "-b", "main")
        try write("a.txt", "one\n")
        try git("add", "a.txt")
        try git("commit", "-q", "-m", "main commit")
        let mainHash = try git("rev-parse", "HEAD")
        let t3Hash = try createOrphanRef("refs/t3/orchestration-v2/checkpoint/1",
                                         file: "a.txt",
                                         content: "checkpoint\n",
                                         message: "t3 checkpoint")

        let model = GitGraphModel()
        XCTAssertFalse(model.showInternalRefs)
        let project = Project(url: root)
        model.prepare(for: project)

        try await waitUntil { !model.isLoading && !model.rows.isEmpty }
        XCTAssertEqual(Set(model.rows.map(\.id)), [mainHash])

        model.toggleInternalRefs()
        XCTAssertTrue(model.showInternalRefs)
        try await waitUntil { !model.isLoading && model.rows.contains(where: { $0.id == t3Hash }) }
        XCTAssertEqual(Set(model.rows.map(\.id)), [mainHash, t3Hash])
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 3.0, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
