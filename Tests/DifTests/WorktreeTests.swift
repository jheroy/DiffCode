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

    private func branchExists(_ name: String, in directory: URL) async -> Bool {
        (try? await Git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: directory)) != nil
    }

    func testInspectAndRemoveCleanWorktreeWithMergedBranch() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "merged-feat")
        try await Git.addWorktree(in: repo, at: destination, branch: "merged-feat", createBranch: true)
        try Data("feature work\n".utf8).write(to: destination.appendingPathComponent("feature.txt"))
        try git(destination, "add", "feature.txt")
        try git(destination, "commit", "-q", "-m", "Feature commit")
        try git(repo, "merge", "-q", "merged-feat")

        // Dirty the main repository to verify inspection stays scoped to the linked work tree.
        try Data("main dirty\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try Data("main untracked\n".utf8).write(to: repo.appendingPathComponent("main-temp.txt"))

        let inspection = await Worktree.inspectRemoval(
            worktreeURL: destination,
            repoRoot: repo,
            branchName: "merged-feat"
        )
        XCTAssertEqual(inspection.uncommittedChangeCount, 0)
        XCTAssertEqual(inspection.branchName, "merged-feat")
        XCTAssertEqual(inspection.unmergedCommitCount, 0)
        XCTAssertFalse(inspection.hasUncommittedChanges)
        XCTAssertFalse(inspection.hasUnmergedCommits)
        XCTAssertFalse(inspection.requiresForceConfirmation(deleteBranch: false))
        XCTAssertFalse(inspection.requiresForceConfirmation(deleteBranch: true))

        try await Worktree.remove(
            worktreeURL: destination,
            repoRoot: repo,
            forceWorktree: false,
            deleteBranch: "merged-feat",
            forceBranch: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stillExists = await branchExists("merged-feat", in: repo)
        XCTAssertFalse(stillExists)
    }

    func testInspectAndForceRemoveDirtyWorktree() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "dirty-inspect")
        try await Git.addWorktree(in: repo, at: destination, branch: "dirty-inspect", createBranch: true)

        // Modified tracked file, staged new file, and untracked file -> 3 uncommitted changes.
        try Data("changed\n".utf8).write(to: destination.appendingPathComponent("README.md"))
        try Data("staged\n".utf8).write(to: destination.appendingPathComponent("staged.txt"))
        try git(destination, "add", "staged.txt")
        try Data("untracked\n".utf8).write(to: destination.appendingPathComponent("notes.txt"))

        let inspection = await Worktree.inspectRemoval(
            worktreeURL: destination,
            repoRoot: repo,
            branchName: "dirty-inspect"
        )
        XCTAssertEqual(inspection.uncommittedChangeCount, 3)
        XCTAssertTrue(inspection.hasUncommittedChanges)
        XCTAssertEqual(inspection.branchName, "dirty-inspect")
        XCTAssertEqual(inspection.unmergedCommitCount, 0)
        XCTAssertTrue(inspection.requiresForceConfirmation(deleteBranch: false))
        XCTAssertTrue(inspection.requiresForceConfirmation(deleteBranch: true))

        try await Worktree.remove(
            worktreeURL: destination,
            repoRoot: repo,
            forceWorktree: true,
            deleteBranch: "dirty-inspect",
            forceBranch: false
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stillExists = await branchExists("dirty-inspect", in: repo)
        XCTAssertFalse(stillExists)
    }

    func testInspectAndForceRemoveUnmergedBranchWorktree() async throws {
        let destination = Git.defaultWorktreeURL(for: repo, branch: "unmerged-feat")
        try await Git.addWorktree(in: repo, at: destination, branch: "unmerged-feat", createBranch: true)

        try Data("commit 1\n".utf8).write(to: destination.appendingPathComponent("one.txt"))
        try git(destination, "add", "one.txt")
        try git(destination, "commit", "-q", "-m", "Unmerged commit 1")

        try Data("commit 2\n".utf8).write(to: destination.appendingPathComponent("two.txt"))
        try git(destination, "add", "two.txt")
        try git(destination, "commit", "-q", "-m", "Unmerged commit 2")

        // Also verifies branch auto-detection when branchName is omitted.
        let inspection = await Worktree.inspectRemoval(
            worktreeURL: destination,
            repoRoot: repo,
            branchName: nil
        )
        XCTAssertEqual(inspection.uncommittedChangeCount, 0)
        XCTAssertEqual(inspection.branchName, "unmerged-feat")
        XCTAssertEqual(inspection.unmergedCommitCount, 2)
        XCTAssertFalse(inspection.hasUncommittedChanges)
        XCTAssertTrue(inspection.hasUnmergedCommits)
        XCTAssertFalse(inspection.requiresForceConfirmation(deleteBranch: false))
        XCTAssertTrue(inspection.requiresForceConfirmation(deleteBranch: true))

        // Safe delete without forceBranch removes the work tree first, then fails at `.branch` stage.
        let partialDest = Git.defaultWorktreeURL(for: repo, branch: "unmerged-partial")
        try await Git.addWorktree(in: repo, at: partialDest, branch: "unmerged-partial", createBranch: true)
        try Data("partial\n".utf8).write(to: partialDest.appendingPathComponent("p.txt"))
        try git(partialDest, "add", "p.txt")
        try git(partialDest, "commit", "-q", "-m", "Partial unmerged commit")

        do {
            try await Worktree.remove(
                worktreeURL: partialDest,
                repoRoot: repo,
                forceWorktree: false,
                deleteBranch: "unmerged-partial",
                forceBranch: false
            )
            XCTFail("Expected safe branch delete to fail for unmerged branch")
        } catch let error as Worktree.RemovalError {
            XCTAssertEqual(error.stage, .branch("unmerged-partial"))
            XCTAssertTrue(error.worktreeRemoved)
            XCTAssertFalse(FileManager.default.fileExists(atPath: partialDest.path))
            let branchStillThere = await branchExists("unmerged-partial", in: repo)
            XCTAssertTrue(branchStillThere)
        }

        // Force delete (`git branch -D`) succeeds for worktree + unmerged branch.
        try await Worktree.remove(
            worktreeURL: destination,
            repoRoot: repo,
            forceWorktree: false,
            deleteBranch: "unmerged-feat",
            forceBranch: true
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let stillExists = await branchExists("unmerged-feat", in: repo)
        XCTAssertFalse(stillExists)
    }

    func testInspectDetachedHeadWorktree() async throws {
        let destination = base.appendingPathComponent("titan-detached")
        try git(repo, "worktree", "add", "--detach", destination.path, "HEAD")

        let inspection = await Worktree.inspectRemoval(
            worktreeURL: destination,
            repoRoot: repo,
            branchName: nil
        )
        XCTAssertNil(inspection.branchName)
        XCTAssertEqual(inspection.uncommittedChangeCount, 0)
        XCTAssertEqual(inspection.unmergedCommitCount, 0)
        XCTAssertFalse(inspection.hasUncommittedChanges)
        XCTAssertFalse(inspection.hasUnmergedCommits)
        XCTAssertFalse(inspection.requiresForceConfirmation(deleteBranch: true))
    }

    func testInspectUnmergedCommitsWithUpstreamOtherBranchAndDetachedMain() async throws {
        // 1. Upstream contains the branch's commit -> 0 unmerged; extra local commit -> 1 unmerged.
        let bareRemote = base.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: bareRemote, withIntermediateDirectories: true)
        try git(bareRemote, "init", "-q", "--bare", "-b", "main")
        try git(repo, "remote", "add", "origin", bareRemote.path)
        try git(repo, "push", "-q", "-u", "origin", "main")

        let upstreamWT = Git.defaultWorktreeURL(for: repo, branch: "pushed-feat")
        try await Git.addWorktree(in: repo, at: upstreamWT, branch: "pushed-feat", createBranch: true)
        try Data("pushed\n".utf8).write(to: upstreamWT.appendingPathComponent("pushed.txt"))
        try git(upstreamWT, "add", "pushed.txt")
        try git(upstreamWT, "commit", "-q", "-m", "Pushed commit")
        try git(upstreamWT, "push", "-q", "-u", "origin", "pushed-feat")

        let pushedInspection = await Worktree.inspectRemoval(
            worktreeURL: upstreamWT,
            repoRoot: repo,
            branchName: "pushed-feat"
        )
        XCTAssertEqual(pushedInspection.unmergedCommitCount, 0)

        try Data("local only\n".utf8).write(to: upstreamWT.appendingPathComponent("local.txt"))
        try git(upstreamWT, "add", "local.txt")
        try git(upstreamWT, "commit", "-q", "-m", "Local unpushed commit")

        let unpushedInspection = await Worktree.inspectRemoval(
            worktreeURL: upstreamWT,
            repoRoot: repo,
            branchName: "pushed-feat"
        )
        XCTAssertEqual(unpushedInspection.unmergedCommitCount, 1)

        // 2. Merged into another local branch `develop` (not `main`) -> 0 unmerged.
        try git(repo, "branch", "develop", "pushed-feat")
        let mergedIntoOther = await Worktree.inspectRemoval(
            worktreeURL: upstreamWT,
            repoRoot: repo,
            branchName: "pushed-feat"
        )
        XCTAssertEqual(mergedIntoOther.unmergedCommitCount, 0)

        // 3. Only one local branch left while main repo is on detached HEAD -> compares against main HEAD.
        try await Git.removeWorktree(in: repo, at: upstreamWT, force: false)
        try git(repo, "branch", "-D", "pushed-feat")
        try git(repo, "branch", "-D", "develop")

        let soloWT = Git.defaultWorktreeURL(for: repo, branch: "solo-feat")
        try await Git.addWorktree(in: repo, at: soloWT, branch: "solo-feat", createBranch: true)
        try Data("solo\n".utf8).write(to: soloWT.appendingPathComponent("solo.txt"))
        try git(soloWT, "add", "solo.txt")
        try git(soloWT, "commit", "-q", "-m", "Solo commit")
        try git(repo, "checkout", "-q", "--detach", "main")
        try git(repo, "branch", "-D", "main")

        let soloInspection = await Worktree.inspectRemoval(
            worktreeURL: soloWT,
            repoRoot: repo,
            branchName: "solo-feat"
        )
        XCTAssertEqual(soloInspection.unmergedCommitCount, 1)
    }

    func testCountPorcelainV1ZChangesHandlesRenamesAndSpaces() {
        let payload = Data(" M README.md\0?? new file.txt\0R  new name.txt\0old name.txt\0A  staged.swift\0".utf8)
        XCTAssertEqual(Worktree.countPorcelainV1ZChanges(payload), 4)
        XCTAssertEqual(Worktree.countPorcelainV1ZChanges(Data()), 0)
    }
}
