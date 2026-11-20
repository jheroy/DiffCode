import XCTest
@testable import DifKit

final class TagTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUp() async throws {
        root = fm.temporaryDirectory.appendingPathComponent("dif-tag-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try git("init", "-q", "-b", "main")
        try git("config", "user.name", "Dif Tests")
        try git("config", "user.email", "tests@example.invalid")
        try git("config", "commit.gpgsign", "false")
        try git("config", "tag.gpgSign", "false")
        try write("file.txt", "initial\n")
        try git("add", "file.txt")
        try git("commit", "-q", "-m", "Initial commit")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path))
    }

    @discardableResult
    private func git(_ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = arguments
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

    private func commit(_ text: String, _ message: String) throws -> String {
        try write("file.txt", text)
        try git("add", "file.txt")
        try git("commit", "-q", "-m", message)
        return try git("rev-parse", "HEAD")
    }

    func testTagNameValidation() {
        let existing: Set<String> = ["v1.0.0", "release/2026"]

        XCTAssertNil(Git.tagNameProblem("v2.0.0", existing: existing))
        XCTAssertNil(Git.tagNameProblem("release/2026-05", existing: existing))
        XCTAssertNil(Git.tagNameProblem("v1.0-rc.1_build", existing: existing))
        XCTAssertNil(Git.tagNameProblem("  v2.1  ", existing: existing))

        XCTAssertNotNil(Git.tagNameProblem("", existing: existing))
        XCTAssertNotNil(Git.tagNameProblem("   ", existing: existing))
        XCTAssertNotNil(Git.tagNameProblem("v1.0.0", existing: existing))
        XCTAssertNotNil(Git.tagNameProblem("release/2026", existing: existing))

        let invalid = [
            "-v1", "/v1", "v1/", "v1.", "v1.lock", "a/b.lock", "v1..v2", "a//b",
            "v1@{0}", "@", "HEAD", "a/.hidden", "v1 0", "v1~1", "v1^2",
            "v1:x", "v1?x", "v1*x", "v1[0]", "v1\\x",
        ]
        for candidate in invalid {
            XCTAssertNotNil(Git.tagNameProblem(candidate, existing: []), "Expected '\(candidate)' to be rejected")
        }
    }

    func testLightweightTagCreateRenameDeleteAndRestore() async throws {
        let firstCommit = try git("rev-parse", "HEAD")

        try await Git.createTag("v1.0", at: "HEAD", message: "   \n  ", in: root)
        let created = try await Git.tagInfo("v1.0", in: root)
        XCTAssertEqual(created.name, "v1.0")
        XCTAssertEqual(created.target, firstCommit)
        XCTAssertFalse(created.isAnnotated)
        XCTAssertNil(created.message)

        // Move HEAD ahead so we verify rename preserves the original tagged commit, not HEAD.
        let secondCommit = try commit("second\n", "Second commit")
        XCTAssertNotEqual(firstCommit, secondCommit)

        try await Git.renameTag("v1.0", to: "v1.1", in: root)
        let oldExists = await Git.tagExists("v1.0", in: root)
        let newExists = await Git.tagExists("v1.1", in: root)
        XCTAssertFalse(oldExists)
        XCTAssertTrue(newExists)

        let renamed = try await Git.tagInfo("v1.1", in: root)
        XCTAssertEqual(renamed.target, firstCommit)
        XCTAssertFalse(renamed.isAnnotated)
        XCTAssertNil(renamed.message)

        let refs = try await Git.refs(in: root).filter { $0.kind == .tag }
        XCTAssertEqual(refs.map(\.shortName), ["v1.1"])
        XCTAssertEqual(refs.first?.target, firstCommit)

        try await Git.deleteTag("v1.1", in: root)
        let existsAfterDelete = await Git.tagExists("v1.1", in: root)
        XCTAssertFalse(existsAfterDelete)

        try await Git.restoreTag(renamed, in: root)
        let restored = try await Git.tagInfo("v1.1", in: root)
        XCTAssertEqual(restored, renamed)
    }

    func testAnnotatedTagCreateRenamePreservesMessageAndTaggerMetadata() async throws {
        let firstCommit = try git("rev-parse", "HEAD")
        let note = "Release 2.0\n\n# Highlights\n- Keeps comment lines verbatim"

        try await Git.createTag("v2.0", at: "HEAD", message: note, in: root)
        let created = try await Git.tagInfo("v2.0", in: root)
        XCTAssertTrue(created.isAnnotated)
        XCTAssertEqual(created.target, firstCommit)
        XCTAssertEqual(created.message?.trimmingCharacters(in: .newlines), note)
        XCTAssertEqual(created.taggerName, "Dif Tests")
        XCTAssertEqual(created.taggerEmail, "tests@example.invalid")
        XCTAssertNotNil(created.taggerDate)

        // Advance HEAD and change repo author so we verify rename preserves the original tagger identity.
        _ = try commit("second\n", "Second commit")
        try git("config", "user.name", "Someone Else")
        try git("config", "user.email", "other@example.invalid")

        try await Git.renameTag("v2.0", to: "v2.0.1", in: root)
        let oldExists = await Git.tagExists("v2.0", in: root)
        let newExists = await Git.tagExists("v2.0.1", in: root)
        XCTAssertFalse(oldExists)
        XCTAssertTrue(newExists)

        let renamed = try await Git.tagInfo("v2.0.1", in: root)
        XCTAssertTrue(renamed.isAnnotated)
        XCTAssertEqual(renamed.target, firstCommit)
        XCTAssertEqual(renamed.message, created.message)
        XCTAssertEqual(renamed.taggerName, created.taggerName)
        XCTAssertEqual(renamed.taggerEmail, created.taggerEmail)
        XCTAssertEqual(renamed.taggerDate, created.taggerDate)

        try await Git.deleteTag("v2.0.1", in: root)
        let existsAfterDelete = await Git.tagExists("v2.0.1", in: root)
        XCTAssertFalse(existsAfterDelete)

        try await Git.restoreTag(renamed, in: root)
        let restored = try await Git.tagInfo("v2.0.1", in: root)
        XCTAssertEqual(restored, renamed)
    }

    func testTagInfoDistinguishesPrefixNamedTags() async throws {
        let firstCommit = try git("rev-parse", "HEAD")
        try await Git.createTag("release/1", at: firstCommit, message: nil, in: root)

        let secondCommit = try commit("second\n", "Second commit")
        try await Git.createTag("release/1-rc1", at: secondCommit, message: "RC release", in: root)

        // `for-each-ref refs/tags/release` matches children under the namespace, so exact matching must reject "release".
        do {
            _ = try await Git.tagInfo("release", in: root)
            XCTFail("Expected non-existent namespace prefix 'release' to throw")
        } catch {}

        let releaseInfo = try await Git.tagInfo("release/1", in: root)
        XCTAssertEqual(releaseInfo.name, "release/1")
        XCTAssertEqual(releaseInfo.target, firstCommit)
        XCTAssertFalse(releaseInfo.isAnnotated)

        let rcInfo = try await Git.tagInfo("release/1-rc1", in: root)
        XCTAssertEqual(rcInfo.name, "release/1-rc1")
        XCTAssertEqual(rcInfo.target, secondCommit)
        XCTAssertTrue(rcInfo.isAnnotated)
        XCTAssertEqual(rcInfo.message?.trimmingCharacters(in: .newlines), "RC release")
    }

    func testErrorCasesPreserveExistingTags() async throws {
        let firstCommit = try git("rev-parse", "HEAD")
        try await Git.createTag("v1.0", at: firstCommit, message: "First", in: root)
        let secondCommit = try commit("second\n", "Second commit")
        try await Git.createTag("v2.0", at: secondCommit, message: nil, in: root)

        // Duplicate create fails without overwriting existing tag.
        do {
            try await Git.createTag("v1.0", at: secondCommit, message: "Overwrite", in: root)
            XCTFail("Expected duplicate tag creation to throw")
        } catch {}
        let stillV1 = try await Git.tagInfo("v1.0", in: root)
        XCTAssertEqual(stillV1.target, firstCommit)
        XCTAssertEqual(stillV1.message?.trimmingCharacters(in: .newlines), "First")

        // Invalid create fails.
        do {
            try await Git.createTag("bad..tag", at: "HEAD", in: root)
            XCTFail("Expected invalid tag name to throw")
        } catch {}

        // Rename to same name fails and leaves tag intact.
        do {
            try await Git.renameTag("v1.0", to: "v1.0", in: root)
            XCTFail("Expected renaming tag to same name to throw")
        } catch {}
        let v1ExistsAfterSame = await Git.tagExists("v1.0", in: root)
        XCTAssertTrue(v1ExistsAfterSame)

        // Rename to existing tag fails and leaves both tags intact.
        do {
            try await Git.renameTag("v1.0", to: "v2.0", in: root)
            XCTFail("Expected renaming tag to existing name to throw")
        } catch {}
        let v1AfterConflict = try await Git.tagInfo("v1.0", in: root)
        let v2AfterConflict = try await Git.tagInfo("v2.0", in: root)
        XCTAssertEqual(v1AfterConflict.target, firstCommit)
        XCTAssertEqual(v2AfterConflict.target, secondCommit)

        // Rename to invalid name fails and leaves old tag intact.
        do {
            try await Git.renameTag("v1.0", to: "invalid name", in: root)
            XCTFail("Expected renaming tag to invalid name to throw")
        } catch {}
        let v1ExistsAfterInvalid = await Git.tagExists("v1.0", in: root)
        XCTAssertTrue(v1ExistsAfterInvalid)

        // Rename and delete on missing tag fail cleanly.
        do {
            try await Git.renameTag("nonexistent", to: "v3.0", in: root)
            XCTFail("Expected renaming nonexistent tag to throw")
        } catch {}
        do {
            try await Git.deleteTag("nonexistent", in: root)
            XCTFail("Expected deleting nonexistent tag to throw")
        } catch {}
    }

    @MainActor
    func testTagDialogFormValidation() {
        let form = TagDialogForm(targetLabel: "HEAD (main)", existingTagNames: ["v1.0"])
        XCTAssertNotNil(form.problem)

        form.name = "v1.0"
        XCTAssertNotNil(form.problem)

        form.name = "bad..name"
        XCTAssertNotNil(form.problem)

        form.name = "  v1.1  "
        form.message = "  Release notes\n"
        XCTAssertNil(form.problem)
        XCTAssertEqual(form.trimmedName, "v1.1")
        XCTAssertEqual(form.trimmedMessage, "Release notes")
    }
}
