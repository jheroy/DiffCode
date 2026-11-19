import XCTest
@testable import DifKit

final class WorktreeTests: XCTestCase {
    private var base: URL!
    private var repo: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-worktree-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = base.appendingPathComponent("titan")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git(repo, "init", "-q", "-b", "main")
        try Data("hello\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try git(repo, "add", "README.md")
        try git(repo, "commit", "-q", "-m", "Initial commit")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func git(_ directory: URL, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-c", "user.name=Dif Tests", "-c", "user.email=tests@example.invalid", "-c", "commit.gpgsign=false"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " "))")
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func testAddWorktreeCreatesNewBranchAndDirectory() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "tree1")
        try await Git.addWorktree(in: repo, at: destination, branch: "tree1", createBranch: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let worktrees = await Git.worktrees(in: repo)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(canonical(worktrees[1].path), canonical(destination.path))
        XCTAssertEqual(worktrees[1].branch, "refs/heads/tree1")

        let status = try await Git.status(in: destination)
        XCTAssertEqual(status.branch, "tree1")
    }

    func testAddWorktreeCreatesNewBranchFromBaseRef() async throws {
        try git(repo, "checkout", "-q", "-b", "base-branch")
        try Data("base\n".utf8).write(to: repo.appendingPathComponent("base.txt"))
        try git(repo, "add", "base.txt")
        try git(repo, "commit", "-q", "-m", "Base commit")
        let baseOID = try await Git.runString(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(repo, "checkout", "-q", "main")

        let destination = Git.defaultWorktreeURL(for: repo, branch: "feature/from-base")
        try await Git.addWorktree(in: repo, at: destination, branch: "feature/from-base", createBranch: true, baseRef: "base-branch")

        let wtOID = try await Git.runString(["rev-parse", "HEAD"], in: destination).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(wtOID, baseOID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("base.txt").path))
    }

    func testAddWorktreeChecksOutExistingBranch() async throws {
        try git(repo, "branch", "existing-feature")
        let destination = Git.defaultWorktreeURL(for: repo, branch: "existing-feature")

        try await Git.addWorktree(in: repo, at: destination, branch: "existing-feature", createBranch: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let worktrees = await Git.worktrees(in: repo)
        XCTAssertTrue(worktrees.contains { canonical($0.path) == canonical(destination.path) && $0.branch == "refs/heads/existing-feature" })
        let status = try await Git.status(in: destination)
        XCTAssertEqual(status.branch, "existing-feature")
    }

    func testRemoveCleanWorktree() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "clean-wt")
        try await Git.addWorktree(in: repo, at: destination, branch: "clean-wt", createBranch: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try await Git.removeWorktree(in: repo, at: destination, force: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let worktrees = await Git.worktrees(in: repo)
        XCTAssertEqual(worktrees.count, 1)
        XCTAssertEqual(canonical(worktrees[0].path), canonical(repo.path))
    }

    func testRemoveDirtyWorktreeRejectsWithoutForceAndSucceedsWithForce() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "dirty-wt")
        try await Git.addWorktree(in: repo, at: destination, branch: "dirty-wt", createBranch: true)
        try Data("modified\n".utf8).write(to: destination.appendingPathComponent("README.md"))
        try Data("untracked\n".utf8).write(to: destination.appendingPathComponent("notes.txt"))

        do {
            try await Git.removeWorktree(in: repo, at: destination, force: false)
            XCTFail("Expected git worktree remove without --force to fail for dirty worktree")
        } catch let failure as Git.Failure {
            XCTAssertTrue(Git.worktreeRemoveNeedsForce(failure.message), "Unexpected git error: \(failure.message)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))

        try await Git.removeWorktree(in: repo, at: destination, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let worktrees = await Git.worktrees(in: repo)
        XCTAssertEqual(worktrees.count, 1)
    }

    func testPruneWorktreesAndMainWorktreeRoot() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "prune-me")
        try await Git.addWorktree(in: repo, at: destination, branch: "prune-me", createBranch: true)

        let resolvedMain = await Git.mainWorktreeRoot(for: destination)
        XCTAssertEqual(resolvedMain.map { canonical($0.path) }, canonical(repo.path))

        try FileManager.default.removeItem(at: destination)
        let beforePrune = await Git.worktrees(in: repo)
        XCTAssertTrue(beforePrune.contains { $0.isPrunable })

        try await Git.pruneWorktrees(in: repo)
        let afterPrune = await Git.worktrees(in: repo)
        XCTAssertEqual(afterPrune.count, 1)
    }

    func testDefaultWorktreePathAndSlugGeneration() {
        XCTAssertEqual(Git.worktreeSlug(for: "tree1"), "tree1")
        XCTAssertEqual(Git.worktreeSlug(for: "alienwar"), "alienwar")
        XCTAssertEqual(Git.worktreeSlug(for: "feature/foo-bar"), "feature-foo-bar")
        XCTAssertEqual(Git.worktreeSlug(for: "fix/issue:123  test"), "fix-issue-123-test")
        XCTAssertEqual(Git.worktreeSlug(for: "  /release//v1.0/  "), "release-v1.0")
        XCTAssertEqual(Git.worktreeSlug(for: "   "), "")

        XCTAssertEqual(Git.localBranchName(forRemote: "origin/feature/x"), "feature/x")
        XCTAssertEqual(Git.localBranchName(forRemote: "main"), "main")

        XCTAssertEqual(
            Git.defaultWorktreeURL(for: URL(fileURLWithPath: "/code/titan"), branch: "tree1").path,
            "/code/titan-tree1"
        )
        XCTAssertEqual(
            Git.defaultWorktreeURL(for: URL(fileURLWithPath: "/code/war"), branch: "alienwar").path,
            "/code/war-alienwar"
        )
        XCTAssertEqual(
            Git.defaultWorktreeURL(for: URL(fileURLWithPath: "/code/app"), branch: "feature/foo-bar").path,
            "/code/app-feature-foo-bar"
        )
        XCTAssertEqual(
            Git.defaultWorktreeURL(for: URL(fileURLWithPath: "/code/app"), branch: "tree1",
                                   parentDir: URL(fileURLWithPath: "/worktrees")).path,
            "/worktrees/app-tree1"
        )
        XCTAssertEqual(
            Git.defaultWorktreeURL(for: URL(fileURLWithPath: "/code/app"), branch: "").path,
            "/code/app-worktree"
        )
    }

    @MainActor
    func testWorktreeDialogFormAutoPathAndValidation() {
        let form = WorktreeDialogForm(
            repoURL: repo,
            currentBranch: "main",
            baseRefChoices: ["main", "develop"],
            existingLocalNames: ["main", "develop"],
            existingBranchChoices: [
                .init(refName: "develop", localName: "develop", isRemote: false),
                .init(refName: "origin/release/v2", localName: "release/v2", isRemote: true),
            ]
        )

        // Initially empty new branch name is invalid.
        XCTAssertNotNil(form.branchProblem)
        XCTAssertNotNil(form.problem)

        // Typing a valid branch updates path automatically.
        form.setNewBranchName("feature/foo-bar")
        XCTAssertNil(form.branchProblem)
        XCTAssertNil(form.pathProblem)
        XCTAssertNil(form.problem)
        XCTAssertEqual(canonical(form.pathText), canonical(base.appendingPathComponent("titan-feature-foo-bar").path))

        // Duplicate local branch is rejected.
        form.setNewBranchName("main")
        XCTAssertNotNil(form.branchProblem)

        // Switching to existing branch uses its local name for default folder path.
        form.setMode(.existingBranch)
        XCTAssertNil(form.problem)
        XCTAssertEqual(canonical(form.pathText), canonical(base.appendingPathComponent("titan-develop").path))

        form.setSelectedExistingID("origin/release/v2")
        XCTAssertEqual(canonical(form.pathText), canonical(base.appendingPathComponent("titan-release-v2").path))

        // Manual edit pointing to an existing directory triggers pathProblem and stops auto-overwriting.
        form.setPathText(repo.path)
        XCTAssertNotNil(form.pathProblem)
        form.setSelectedExistingID("develop")
        XCTAssertEqual(form.pathText, repo.path)

        // Choosing a parent folder re-enables automatic folder naming inside that parent.
        let customParent = base.appendingPathComponent("custom")
        form.chooseParentFolder(customParent)
        XCTAssertEqual(canonical(form.pathText), canonical(customParent.appendingPathComponent("titan-develop").path))
        XCTAssertNil(form.pathProblem)
    }
}
