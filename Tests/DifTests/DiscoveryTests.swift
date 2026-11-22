import XCTest
@testable import DifKit

/// Which repositories a chosen folder adds (issue #5): a workspace that is a repository itself, with others in it.
final class DiscoveryTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("dif-discovery-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let workspace = base.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try git(workspace, "init", "-q", "-b", "main")
        try Data("api/\nweb/\nnode_modules/\nvendor/\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        try Data("# Docs\n".utf8).write(to: workspace.appendingPathComponent("docs/readme.md"))
        try git(workspace, "add", "-A")
        try git(workspace, "commit", "-q", "-m", "Workspace")
        // Ignored repositories, one not ignored below a tracked folder, one below an untracked folder.
        for path in ["api", "web", "docs/handbook", "tools/deep/thing"] { try repository(path) }
        // A repository inside a repository found, and one in a folder that one ignores.
        try Data("build/\n".utf8).write(to: workspace.appendingPathComponent("api/.gitignore"))
        for path in ["api/services/core", "api/build"] { try repository(path) }
        // Not looked for: below an ignored folder that is no repository, in a hidden folder, a linked work tree.
        for path in ["vendor/dependency", "node_modules/package", ".cache/clone"] { try repository(path) }
        try git(workspace, "worktree", "add", "-q", "linked", "-b", "linked")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func repository(_ path: String) throws {
        let url = base.appendingPathComponent("workspace/" + path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git(url, "init", "-q", "-b", "main")
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

    private func names(_ found: [URL]) -> [String] {
        let prefix = base.path + "/"
        return found.map { $0.resolvingSymlinksInPath().path }.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
    }

    private let expected = ["workspace", "workspace/api", "workspace/api/build", "workspace/api/services/core",
                            "workspace/docs/handbook", "workspace/tools/deep/thing", "workspace/web"]

    func testARepositoryBringsTheRepositoriesInsideIt() async {
        let found = await Git.repositories(for: base.appendingPathComponent("workspace"))
        XCTAssertEqual(names(found), expected)
    }

    func testAFolderInsideTheRepositoryAddsTheSame() async {
        let found = await Git.repositories(for: base.appendingPathComponent("workspace/docs"))
        XCTAssertEqual(names(found), expected)
    }

    func testAPlainFolderLooksInsideTheRepositoriesItFinds() async {
        let found = await Git.repositories(for: base)
        XCTAssertEqual(names(found), expected)
    }

    func testARepositoryWithNothingInsideIsAddedAlone() async {
        let found = await Git.repositories(for: base.appendingPathComponent("workspace/web"))
        XCTAssertEqual(names(found), ["workspace/web"])
    }

    /// Issue #7: a repository git refuses (here one it takes for another user's) says why, instead of "none there".
    func testARefusedRepositorySaysWhy() async throws {
        let workspace = base.appendingPathComponent("workspace")
        // Without the machine's own settings, where `safe.directory = *` would trust every folder.
        let empty = base.appendingPathComponent("empty.gitconfig")
        try Data().write(to: empty)
        let isolated = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": empty.path, "GIT_TEST_ASSUME_DIFFERENT_OWNER": "1"]
        let refused = await Git.refusal(at: workspace, environment: isolated)
        XCTAssertTrue(refused?.message.hasPrefix("detected dubious ownership") ?? false, "\(String(describing: refused))")
        XCTAssertEqual(refused?.trustCommand?.hasPrefix("git config --global --add safe.directory"), true)
        // A repository git takes, and a folder that is none, have nothing to explain.
        let fine = await Git.refusal(at: workspace)
        XCTAssertNil(fine)
        let plain = base.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let none = await Git.refusal(at: plain)
        XCTAssertNil(none)
        XCTAssertEqual(Git.parseRefusal("fatal: something else went wrong\n")?.message, "something else went wrong")
    }
}
