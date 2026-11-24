import Foundation

/// Committing the files ticked in the Changes list, and taking that commit back.
extension WorkingTree {
    struct CommitResult: Equatable {
        var hash: String
        /// The first commit of the repository: undoing it leaves the branch unborn.
        var isRoot: Bool
        var fileCount: Int
        var message: String
        /// The commit this one replaced (Amend): undoing brings it back.
        var amended: String? = nil

        var shortHash: String { String(hash.prefix(7)) }
    }

    /// Commits exactly `changes`, as they are on disk, like Android Studio's commit does.
    ///
    /// Uses `git commit --only`, so whatever else is staged stays staged and out of this commit.
    /// New files are added first (and taken out of the index again if the commit fails, e.g. a hook refuses it).
    /// A rename brings its old path along, or the old file's removal would stay behind.
    /// - Parameter amend: replaces the last commit with one that has these changes too, and this message (Amend).
    ///   With no changes, only the message changes.
    static func commit(message: String, changes: [FileChange], amend: Bool = false, in root: URL) async throws -> CommitResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Failure(message: L("Write a commit message first.", "先写提交说明。"))
        }
        guard !changes.isEmpty || amend else {
            throw Failure(message: L("Tick the files to commit first.", "先勾选要提交的文件。"))
        }
        let amended = amend ? try await amendTarget(in: root) : nil
        var paths: [String] = []
        for change in changes {
            paths.append(change.path)
            if change.kind == .renamed, let old = change.oldPath { paths.append(old) }
        }
        let untracked = changes.filter { $0.kind == .untracked }.map(\.path)

        let directory = try makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let messageFile = directory.appendingPathComponent("message")
        let pathsFile = directory.appendingPathComponent("paths")
        try Data((text + "\n").utf8).write(to: messageFile)
        // NUL-separated, so any file name is passed exactly; no command line is long enough to matter.
        try Data(Array(paths.joined(separator: "\0").utf8) + [0]).write(to: pathsFile)

        try await git(["add"], paths: untracked, in: root)
        do {
            var args = ["--literal-pathspecs", "commit", "--quiet", "--only", "--file=\(messageFile.path)"]
            if amend { args.append("--amend") }
            // Amending with no files: `--only` and no paths takes nothing that is staged, just the new message.
            if !paths.isEmpty { args += ["--pathspec-from-file=\(pathsFile.path)", "--pathspec-file-nul"] }
            _ = try await Git.run(args, in: root)
        } catch {
            try? await git(["rm", "--cached", "-q", "--ignore-unmatch"], paths: untracked, in: root)
            throw error
        }
        let hash = try await Git.runString(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let line = try await Git.runString(["rev-list", "--parents", "-n", "1", hash], in: root)
        let isRoot = line.split(separator: " ").count <= 1
        return CommitResult(hash: hash, isRoot: isRoot, fileCount: changes.count, message: text, amended: amended)
    }

    /// The commit an amend replaces: HEAD, which must exist.
    private static func amendTarget(in root: URL) async throws -> String {
        guard let head = try? await Git.head(in: root) else {
            throw Failure(message: L("There is no commit to amend yet.", "还没有可以修改的提交。"))
        }
        return head
    }

    /// Commits `whole` as they are on disk and `partial` without the lines left out of them; the working tree is not touched.
    ///
    /// The commit is put together in an index of DiffCode's own, started from HEAD, so whatever is staged stays staged
    /// and out of it, as with `commit --only`. Afterwards the real index takes what was committed for these paths:
    /// the lines left out of a file show as changed still.
    /// Nothing happens if a partial file changed in a way its picked lines cannot be found in again.
    /// - Parameter amend: replaces the last commit, which the commit is then started from (Amend).
    static func commit(message: String, whole: [FileChange], partial: [PartialFile], amend: Bool = false,
                       in root: URL) async throws -> CommitResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Failure(message: L("Write a commit message first.", "先写提交说明。"))
        }
        let amended = amend ? try await amendTarget(in: root) : nil
        // Every partial file's content first: if one cannot be worked out, nothing is done.
        var contents: [(path: String, data: Data)] = []
        for file in partial {
            let change = file.change
            let sides = try await partialSides(of: change, in: root)
            let moved = relocate(file.excluded, old: sides.oldText, new: sides.newText, hunks: sides.hunks)
            guard moved.lost == 0,
                  let data = partialContent(old: sides.old, new: sides.new, hunks: sides.hunks, excluded: moved.lines) else {
                throw Failure(message: L("“\(change.name)” changed after its lines were picked. Look at it again before committing.",
                                         "“\(change.name)”在选好行之后又改过了。请再看一眼再提交。"))
            }
            contents.append((change.path, data))
        }

        var paths: [String] = []
        for change in whole + partial.map(\.change) {
            paths.append(change.path)
            if change.kind == .renamed, let old = change.oldPath { paths.append(old) }
        }
        let partialPaths = contents.map(\.path)

        let directory = try makeBackupDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let messageFile = directory.appendingPathComponent("message")
        try Data((text + "\n").utf8).write(to: messageFile)
        let index = directory.appendingPathComponent("index")
        let environment = ["GIT_INDEX_FILE": index.path]

        let unborn = (try? await Git.run(["rev-parse", "--verify", "--quiet", "HEAD"], in: root)) == nil
        if unborn {
            _ = try await Git.run(["read-tree", "--empty"], in: root, environment: environment)
        } else {
            // Started from a copy of the real index, whose file stamps carry over to the files HEAD has as they are:
            // the commit (and its hooks) then need not read every file of the working tree again.
            var started = false
            if let real = try? await Git.runString(["rev-parse", "--git-path", "index"], in: root) {
                let name = real.trimmingCharacters(in: .newlines)
                let url = name.hasPrefix("/") ? URL(fileURLWithPath: name) : root.appendingPathComponent(name)
                if (try? FileManager.default.copyItem(at: url, to: index)) != nil,
                   (try? await Git.run(["read-tree", "-m", "HEAD"], in: root, environment: environment)) != nil {
                    started = true
                }
            }
            if !started {
                try? FileManager.default.removeItem(at: index)
                _ = try await Git.run(["read-tree", "HEAD"], in: root, environment: environment)
            }
        }

        // The modes HEAD has, for a partial file the working tree no longer has (deleted, in part).
        let headModes = try await stagedModes(partialPaths, in: root, environment: environment)
        try await git(["add", "-A"], paths: paths, in: root, environment: environment)
        let modes = try await stagedModes(partialPaths, in: root, environment: environment)
        for (number, item) in contents.enumerated() {
            let mode = modes[item.path] ?? headModes[item.path] ?? "100644"
            guard mode == "100644" || mode == "100755" else {
                throw Failure(message: L("“\((item.path as NSString).lastPathComponent)” can only be committed whole.",
                                         "“\((item.path as NSString).lastPathComponent)”只能整个提交。"))
            }
            let file = directory.appendingPathComponent("part\(number)")
            try item.data.write(to: file)
            // `--path`: the content goes through the file's filters (line endings) the way `git add` would take it.
            let hash = try await Git.runString(["hash-object", "-w", "--path=\(item.path)", file.path], in: root)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await Git.run(["update-index", "--add", "--cacheinfo", "\(mode),\(hash),\(item.path)"],
                                  in: root, environment: environment)
        }
        _ = try await Git.run(["commit", "--quiet", "--file=\(messageFile.path)"] + (amend ? ["--amend"] : []),
                              in: root, environment: environment)

        // The real index follows the commit for these paths (as `commit --only` leaves it); anything else staged stays.
        try? await git(["reset", "--quiet"], paths: paths, in: root)
        let hash = try await Git.runString(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        var isRoot = unborn
        if !isRoot {
            // An amended first commit is still the first.
            let line = try await Git.runString(["rev-list", "--parents", "-n", "1", hash], in: root)
            isRoot = line.split(separator: " ").count <= 1
        }
        return CommitResult(hash: hash, isRoot: isRoot, fileCount: whole.count + partial.count, message: text, amended: amended)
    }

    /// `path → mode` of the entries the index has for `paths`.
    private static func stagedModes(_ paths: [String], in root: URL, environment: [String: String]) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let data = try await Git.run(["--literal-pathspecs", "ls-files", "--stage", "-z", "--"] + paths, in: root, environment: environment)
        var modes: [String: String] = [:]
        for record in data.split(separator: 0, omittingEmptySubsequences: true) {
            // "<mode> <hash> <stage>\t<path>"
            guard let tab = record.firstIndex(of: 0x09) else { continue }
            let fields = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(separator: " ")
            guard let mode = fields.first else { continue }
            modes[String(decoding: record[(tab + 1)...], as: UTF8.self)] = String(mode)
        }
        return modes
    }

    /// Finishes a merge that stopped for conflicts. Git commits a merge whole (it refuses a partial one), so this is
    /// what the merge staged, conflicts resolved, plus the ticked files, which are added first.
    static func commitMerge(message: String, adding changes: [FileChange], in root: URL) async throws -> CommitResult {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw Failure(message: L("Write a commit message first.", "先写提交说明。"))
        }
        var paths: [String] = []
        for change in changes {
            paths.append(change.path)
            if change.kind == .renamed, let old = change.oldPath { paths.append(old) }
        }
        try await git(["add", "-A"], paths: paths, in: root)
        let gitDir = await Git.gitDirectory(in: root)
        let hasAutoStash: Bool
        if let gitDir {
            let fileExists = FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("MERGE_AUTOSTASH").path)
            if fileExists {
                hasAutoStash = true
            } else {
                hasAutoStash = (try? await Git.run(["rev-parse", "--verify", "--quiet", "MERGE_AUTOSTASH"], in: root)) != nil
            }
        } else {
            hasAutoStash = false
        }
        if let gitDir, hasAutoStash {
            // `git commit` leaves MERGE_AUTOSTASH behind; `git merge --continue` commits the merge and restores it.
            try Data((text + "\n").utf8).write(to: gitDir.appendingPathComponent("MERGE_MSG"))
            do {
                _ = try await Git.run(["merge", "--continue"], in: root, environment: ["GIT_EDITOR": "true"])
            } catch {
                if Git.operation(in: gitDir) == .merge {
                    throw error
                }
            }
        } else {
            let directory = try makeBackupDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let messageFile = directory.appendingPathComponent("message")
            try Data((text + "\n").utf8).write(to: messageFile)
            _ = try await Git.run(["commit", "--quiet", "--file=\(messageFile.path)"], in: root)
        }
        let hash = try await Git.runString(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommitResult(hash: hash, isRoot: false, fileCount: changes.count, message: text)
    }

    /// Takes back a commit made here: the branch moves back one commit and the changes stay, staged.
    /// Refuses when anything has happened since (a new commit, a checkout) or the commit was pushed.
    static func undoCommit(_ result: CommitResult, in root: URL) async throws {
        let head = (try? await Git.runString(["rev-parse", "HEAD"], in: root))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head == result.hash else {
            throw Failure(message: L("HEAD has moved since that commit, so it was left alone.", "这次提交之后 HEAD 已经变了，所以没有撤销。"))
        }
        let remote = try await Git.runString(["branch", "-r", "--contains", result.hash], in: root)
        guard remote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure(message: L("That commit has already been pushed, so it was left alone.", "这次提交已经推送到远程，所以没有撤销。"))
        }
        if let amended = result.amended {
            // The commit that was amended comes back; what the amend added stays, staged.
            _ = try await Git.run(["reset", "--soft", "--quiet", amended], in: root)
        } else if result.isRoot {
            _ = try await Git.run(["update-ref", "-d", "HEAD", result.hash], in: root)
        } else {
            _ = try await Git.run(["reset", "--soft", "--quiet", result.hash + "^"], in: root)
        }
    }
}

/// A changed line of a file, against HEAD: one that HEAD has and the working tree does not (`removed`), or the other
/// way round. Its text comes along, so that a line number that no longer holds it is never trusted.
struct ChangeLine: Hashable {
    var removed: Bool
    /// 0-based: in HEAD's version of the file for a removed line, in the working tree's for an added one.
    var line: Int
    var text: String
}

/// Committing part of a file: some of its changed lines stay out of the commit, and in the working tree.
extension WorkingTree {
    struct PartialFile {
        var change: FileChange
        var excluded: Set<ChangeLine>
    }

    struct Sides {
        var old: Data
        var new: Data
        var oldText: [String]
        var newText: [String]
        /// The exact differences, whitespace included.
        var hunks: [Hunk]
    }

    /// The two versions a local change compares, as the viewer has them: HEAD's (none for a new file) and the
    /// working tree's (none for a deleted one).
    static func partialSides(of change: FileChange, in root: URL) async throws -> Sides {
        let hasOld = change.kind != .added && change.kind != .untracked
        let hasNew = change.kind != .deleted
        var old = Data(), new = Data()
        if hasOld {
            guard let blob = await Git.blob(rev: "HEAD", path: change.oldPath ?? change.path, in: root) else {
                throw Failure(message: L("HEAD has no “\(change.name)”.", "HEAD 里没有“\(change.name)”。"))
            }
            old = blob
        }
        if hasNew {
            let url = root.appendingPathComponent(change.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular, let data = try? Data(contentsOf: url) else {
                throw Failure(message: L("“\(change.name)” can only be committed whole.", "“\(change.name)”只能整个提交。"))
            }
            new = data
        }
        if HunkPatch.isUTF16(old) || HunkPatch.isUTF16(new) {
            throw Failure(message: L("UTF-16 files can only be committed whole.", "UTF-16 文件只能整个提交。"))
        }
        let oldText = TextCodec.splitLines(TextCodec.decode(old)), newText = TextCodec.splitLines(TextCodec.decode(new))
        var hunks: [Hunk]
        if !hasOld {
            hunks = newText.isEmpty ? [] : [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: newText.count)]
        } else if !hasNew {
            hunks = oldText.isEmpty ? [] : [Hunk(leftStart: 0, leftCount: oldText.count, rightStart: 0, rightCount: 0)]
        } else {
            guard let computed = await DiffLoader.computeHunks(old: old, new: new, ignoreWhitespace: false) else {
                throw Failure(message: L("Could not compare “\(change.name)” with HEAD.", "无法把“\(change.name)”和 HEAD 比较。"))
            }
            hunks = computed
        }
        return Sides(old: old, new: new, oldText: oldText, newText: newText, hunks: hunks)
    }

    /// Finds the lines of `excluded` in the two versions as they are now: the working tree's may have been edited since
    /// they were picked, moving its lines. An added line is looked for nearby by its text.
    /// - Returns: the lines where they are now, and how many could not be found. A removed line that is no longer a change
    ///   (put back in the working tree) is simply dropped: it stays either way.
    static func relocate(_ excluded: Set<ChangeLine>, old: [String], new: [String], hunks: [Hunk]) -> (lines: Set<ChangeLine>, lost: Int) {
        guard !excluded.isEmpty else { return ([], 0) }
        var removedLines = IndexSet(), addedLines = IndexSet()
        for hunk in hunks {
            removedLines.insert(integersIn: hunk.leftStart..<(hunk.leftStart + hunk.leftCount))
            addedLines.insert(integersIn: hunk.rightStart..<(hunk.rightStart + hunk.rightCount))
        }
        var result = Set<ChangeLine>()
        var lost = 0
        var missing: [ChangeLine] = []
        for line in excluded {
            if line.removed {
                guard old.indices.contains(line.line), old[line.line] == line.text else { lost += 1; continue }
                if removedLines.contains(line.line) { result.insert(line) }
            } else if new.indices.contains(line.line), new[line.line] == line.text, addedLines.contains(line.line) {
                result.insert(line)
            } else {
                missing.append(line)
            }
        }
        guard !missing.isEmpty else { return (result, lost) }
        // Where each text is an added line now, for the lines that moved.
        let wanted = Set(missing.map(\.text))
        var places: [String: [Int]] = [:]
        for index in addedLines where index < new.count && wanted.contains(new[index]) {
            places[new[index], default: []].append(index)
        }
        var taken = Set(result.filter { !$0.removed }.map(\.line))
        for line in missing.sorted(by: { $0.line < $1.line }) {
            let nearest = places[line.text]?.filter { !taken.contains($0) }.min { abs($0 - line.line) < abs($1 - line.line) }
            guard let nearest else { lost += 1; continue }
            taken.insert(nearest)
            result.insert(ChangeLine(removed: false, line: nearest, text: line.text))
        }
        return (result, lost)
    }

    /// What a commit takes of a file when the lines of `excluded` stay out of it: the working tree's version (`new`),
    /// with each of those lines the way HEAD's (`old`) has it. A removed line stays; an added one does not come.
    ///
    /// Within a change the two sides go row by row, so a modified line that stays out keeps its place among the lines
    /// that go in. Bytes are copied as they are, so encodings and line endings stay what they were.
    /// Returns nil when `hunks` do not fit the two versions, or a line of `excluded` does not hold its text.
    static func partialContent(old: Data, new: Data, hunks: [Hunk], excluded: Set<ChangeLine>) -> Data? {
        guard !HunkPatch.isUTF16(old), !HunkPatch.isUTF16(new) else { return nil }
        let oldLines = HunkPatch.lineRanges(old), newLines = HunkPatch.lineRanges(new)
        let oldText = TextCodec.splitLines(TextCodec.decode(old)), newText = TextCodec.splitLines(TextCodec.decode(new))
        guard oldText.count == oldLines.count, newText.count == newLines.count else { return nil }
        var kept = Set<Int>(), dropped = Set<Int>()
        for line in excluded {
            let text = line.removed ? oldText : newText
            guard text.indices.contains(line.line), text[line.line] == line.text else { return nil }
            if line.removed { kept.insert(line.line) } else { dropped.insert(line.line) }
        }

        // Only a file's last line may lack its line break; one that is no longer last gets one, in the file's style.
        let crlf = Data([0x0D, 0x0A])
        let newline = new.range(of: crlf) != nil || (!new.contains(0x0A) && old.range(of: crlf) != nil) ? crlf : Data([0x0A])
        var result = Data()
        result.reserveCapacity(new.count)
        var open = false
        func put(_ data: Data, _ range: Range<Int>) {
            if open { result.append(newline) }
            let bytes = data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
            result.append(bytes)
            open = bytes.last != 0x0A
        }

        var oldPos = 0, newPos = 0
        for hunk in hunks {
            guard hunk.leftStart >= oldPos, hunk.rightStart >= newPos, hunk.leftStart - oldPos == hunk.rightStart - newPos,
                  hunk.leftCount >= 0, hunk.rightCount >= 0,
                  hunk.leftStart + hunk.leftCount <= oldLines.count, hunk.rightStart + hunk.rightCount <= newLines.count else { return nil }
            for index in newPos..<hunk.rightStart { put(new, newLines[index]) }
            for row in 0..<max(hunk.leftCount, hunk.rightCount) {
                if row < hunk.leftCount, kept.contains(hunk.leftStart + row) { put(old, oldLines[hunk.leftStart + row]) }
                if row < hunk.rightCount, !dropped.contains(hunk.rightStart + row) { put(new, newLines[hunk.rightStart + row]) }
            }
            oldPos = hunk.leftStart + hunk.leftCount
            newPos = hunk.rightStart + hunk.rightCount
        }
        guard oldLines.count - oldPos == newLines.count - newPos else { return nil }
        for index in newPos..<newLines.count { put(new, newLines[index]) }
        return result
    }
}
