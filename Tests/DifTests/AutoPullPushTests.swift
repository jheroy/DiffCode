import XCTest
@testable import DifKit

final class AutoPullPushTests: XCTestCase {
    private var root: URL!
    private var remoteURL: URL!
    private var localURL: URL!
    private var teammateURL: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("dif-autopull-tests-\(UUID().uuidString)")
        remoteURL = root.appendingPathComponent("remote.git")
        localURL = root.appendingPathComponent("local")
        teammateURL = root.appendingPathComponent("teammate")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try runGit(["init", "--bare", "-q", "-b", "main", remoteURL.path], in: root)
        try runGit(["clone", "-q", remoteURL.path, localURL.path], in: root)
        try configureIdentity(in: localURL, name: "Local Dev", email: "local@example.invalid")
        try write("base.txt", "line1\nline2\n", in: localURL)
        try write("other.txt", "other0\n", in: localURL)
        try write("unticked.txt", "unticked0\n", in: localURL)
        try runGit(["add", "-A"], in: localURL)
        try runGit(["commit", "-q", "-m", "Initial import"], in: localURL)
        try runGit(["push", "-q", "-u", "origin", "main"], in: localURL)

        try runGit(["clone", "-q", remoteURL.path, teammateURL.path], in: root)
        try configureIdentity(in: teammateURL, name: "Teammate", email: "teammate@example.invalid")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func configureIdentity(in dir: URL, name: String, email: String) throws {
        try runGit(["config", "user.name", name], in: dir)
        try runGit(["config", "user.email", email], in: dir)
        try runGit(["config", "commit.gpgsign", "false"], in: dir)
    }

    private func write(_ path: String, _ text: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in dir: URL) throws -> String {
        try String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in dir: URL, allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 && !allowFailure {
            let msg = String(decoding: errData, as: UTF8.self)
            XCTFail("git \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(msg)")
        }
        return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func unsetConfig(_ key: String, in dir: URL) {
        _ = try? runGit(["config", "--unset-all", key], in: dir, allowFailure: true)
    }

    private func changes(in dir: URL) async throws -> [String: FileChange] {
        Dictionary(uniqueKeysWithValues: try await Git.status(in: dir).changes.map { ($0.path, $0) })
    }

    func testPushSucceedsDirectlyWhenRemoteHasNoNewCommits() async throws {
        try write("other.txt", "other1\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local change", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: false, pulledCommits: 0))

        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushAutoPullsAndMergesWhenRemoteHasNewCommitsWithUnsetPullRebase() async throws {
        unsetConfig("pull.rebase", in: localURL)
        unsetConfig("pull.ff", in: localURL)

        try write("base.txt", "line1\nfrom-teammate\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate commit"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("other.txt", "from-local\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local commit", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: true, pulledCommits: 1))

        let parents = try runGit(["rev-list", "--parents", "-n", "1", "HEAD"], in: localURL).split(separator: " ")
        XCTAssertEqual(parents.count, 3, "Merge pull creates a merge commit with 2 parents")
        XCTAssertEqual(try read("base.txt", in: localURL), "line1\nfrom-teammate\n")
        XCTAssertEqual(try read("other.txt", in: localURL), "from-local\n")
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushAutoPullsAndMergesEvenWhenPullFFOnlyIsConfigured() async throws {
        unsetConfig("pull.rebase", in: localURL)
        try runGit(["config", "pull.ff", "only"], in: localURL)

        try write("base.txt", "line1\nfrom-teammate\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate commit"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("other.txt", "from-local\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local commit", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: true, pulledCommits: 1))

        let parents = try runGit(["rev-list", "--parents", "-n", "1", "HEAD"], in: localURL).split(separator: " ")
        XCTAssertEqual(parents.count, 3, "Merge pull creates a merge commit with 2 parents")
        XCTAssertEqual(try read("base.txt", in: localURL), "line1\nfrom-teammate\n")
        XCTAssertEqual(try read("other.txt", in: localURL), "from-local\n")
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushAutoPullsAndRebasesWhenPullRebaseIsTrue() async throws {
        try runGit(["config", "pull.rebase", "true"], in: localURL)
        try runGit(["config", "pull.ff", "only"], in: localURL)

        try write("base.txt", "line1\nfrom-teammate\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate commit"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("other.txt", "from-local\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local commit", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: true, pulledCommits: 1))

        let parents = try runGit(["rev-list", "--parents", "-n", "1", "HEAD"], in: localURL).split(separator: " ")
        XCTAssertEqual(parents.count, 2, "Rebase pull replays linear commit with 1 parent")
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushWithPullFirstReconcilesAlreadyFetchedIncomingCommits() async throws {
        unsetConfig("pull.rebase", in: localURL)
        try write("base.txt", "line1\nteammate-fetched\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate commit"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try await Git.fetch(in: localURL)
        try write("other.txt", "local-after-fetch\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local commit", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, pullFirst: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: true, pulledCommits: 1))
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushAutoPullAutostashesAndRestoresUntickedLocalChanges() async throws {
        unsetConfig("pull.rebase", in: localURL)
        try write("base.txt", "line1\nteammate-base\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate change"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("other.txt", "committed-file\n", in: localURL)
        try write("unticked.txt", "wip-local-edit\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Commit other only", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(result, .pushed(didAutoPull: true, pulledCommits: 1))
        XCTAssertEqual(try read("unticked.txt", in: localURL), "wip-local-edit\n")
        XCTAssertEqual(try read("base.txt", in: localURL), "line1\nteammate-base\n")
    }

    func testPushAutoPullReturnsMergeConflictsAndCompletesAfterResolution() async throws {
        unsetConfig("pull.rebase", in: localURL)
        try write("base.txt", "teammate-version\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate edits base.txt"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("base.txt", "local-version\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local edits base.txt", changes: [try XCTUnwrap(now["base.txt"])], in: localURL)

        let conflictResult = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(conflictResult, .conflicts(operation: .merge, paths: ["base.txt"], autostashClash: false))

        try write("base.txt", "merged-version\n", in: localURL)
        try await Git.markResolved(["base.txt"], in: localURL)
        try await Git.continueOperation(.merge, in: localURL)

        let afterResult = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(afterResult, .pushed(didAutoPull: false, pulledCommits: 0))
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testCommitMergeRestoresMergeAutostashWhenPresent() async throws {
        unsetConfig("pull.rebase", in: localURL)
        try write("base.txt", "teammate-version\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate edits base.txt"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("base.txt", "local-version\n", in: localURL)
        try write("unticked.txt", "wip-dirty-change\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local edits base.txt", changes: [try XCTUnwrap(now["base.txt"])], in: localURL)

        let conflictResult = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(conflictResult, .conflicts(operation: .merge, paths: ["base.txt"], autostashClash: false))

        try write("base.txt", "resolved-with-autostash\n", in: localURL)
        try await Git.markResolved(["base.txt"], in: localURL)
        let mergeCommit = try await WorkingTree.commitMerge(message: "Custom merge commit", adding: [], in: localURL)
        XCTAssertFalse(mergeCommit.hash.isEmpty)
        XCTAssertEqual(try read("unticked.txt", in: localURL), "wip-dirty-change\n")
        let logMsg = try runGit(["log", "-1", "--format=%s"], in: localURL)
        XCTAssertEqual(logMsg, "Custom merge commit")
        let clashes = await Git.conflictedPaths(in: localURL)
        XCTAssertTrue(clashes.isEmpty)
    }

    func testPushAutoPullReturnsRebaseConflictsAndCompletesAfterContinue() async throws {
        try runGit(["config", "pull.rebase", "true"], in: localURL)
        try write("base.txt", "teammate-rebase\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate edits base.txt"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try write("base.txt", "local-rebase\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local edits base.txt", changes: [try XCTUnwrap(now["base.txt"])], in: localURL)

        let conflictResult = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(conflictResult, .conflicts(operation: .rebase, paths: ["base.txt"], autostashClash: false))

        try write("base.txt", "rebased-merged\n", in: localURL)
        try await Git.markResolved(["base.txt"], in: localURL)
        try await Git.continueOperation(.rebase, in: localURL)

        let afterResult = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: nil, allowAutoPull: true, in: localURL)
        XCTAssertEqual(afterResult, .pushed(didAutoPull: false, pulledCommits: 0))
        let localHead = try runGit(["rev-parse", "HEAD"], in: localURL)
        let remoteHead = try runGit(["rev-parse", "refs/heads/main"], in: remoteURL)
        XCTAssertEqual(localHead, remoteHead)
    }

    func testPushWithoutUpstreamReturnsRejectedAsBehindInsteadOfAutoPulling() async throws {
        try write("base.txt", "teammate-remote\n", in: teammateURL)
        try runGit(["add", "base.txt"], in: teammateURL)
        try runGit(["commit", "-q", "-m", "Teammate commit"], in: teammateURL)
        try runGit(["push", "-q", "origin", "main"], in: teammateURL)

        try runGit(["branch", "--unset-upstream", "main"], in: localURL)
        try write("other.txt", "local-no-upstream\n", in: localURL)
        let now = try await changes(in: localURL)
        _ = try await WorkingTree.commit(message: "Local without upstream", changes: [try XCTUnwrap(now["other.txt"])], in: localURL)

        let result = try await Git.pushWithAutoPull(branch: "main", setUpstreamTo: "origin", allowAutoPull: true, in: localURL)
        guard case .rejectedAsBehind = result else {
            return XCTFail("Expected .rejectedAsBehind, got \(result)")
        }
    }
}
