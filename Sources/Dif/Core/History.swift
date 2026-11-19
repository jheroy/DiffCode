import Foundation

// MARK: - Blame

/// Who last changed each line of a file, from `git blame --porcelain`.
struct Blame: Equatable {
    struct Entry: Equatable {
        var hash: String
        var author: String
        var email: String
        var date: Date
        var summary: String

        var shortHash: String { String(hash.prefix(7)) }
    }

    var entries: [Entry] = []
    /// The entry of each line, in order; -1 for a line that is not committed yet.
    var lines: [Int32] = []
}

extension Git {
    static let uncommittedHash = String(repeating: "0", count: 40)

    /// `rev` nil blames the file in the working tree, where lines not committed yet have no entry.
    static func blame(_ path: String, rev: String?, in dir: URL) async throws -> Blame {
        var args = ["blame", "--porcelain"]
        if let rev { args.append(rev) }
        args += ["--", path]
        return parseBlame(try await run(args, in: dir))
    }

    /// Parses `git blame --porcelain`. Each line comes as a header (`<hash> <orig> <final> [<count>]`), the commit's
    /// details the first time that commit appears, then the line itself after a tab.
    static func parseBlame(_ data: Data) -> Blame {
        var blame = Blame()
        var known: [String: Int32] = [:]
        var current: Int32 = -1
        var describing = false
        var finalLine = 0

        func isHex(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 97 && b <= 102) }
        func text(_ bytes: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[from..<to]), as: UTF8.self)
        }
        func hasPrefix(_ bytes: UnsafeBufferPointer<UInt8>, _ at: Int, _ end: Int, _ prefix: StaticString) -> Bool {
            let count = prefix.utf8CodeUnitCount
            guard end - at >= count else { return false }
            let p = prefix.utf8Start
            for k in 0..<count where bytes[at + k] != p[k] { return false }
            return true
        }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let n = bytes.count
            var start = 0
            while start < n {
                var end = start
                while end < n, bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start else { continue }
                if bytes[start] == 0x09 {
                    // The line itself.
                    guard finalLine > 0 else { continue }
                    if blame.lines.count < finalLine {
                        blame.lines.append(contentsOf: repeatElement(-1, count: finalLine - blame.lines.count))
                    }
                    blame.lines[finalLine - 1] = current
                } else if end - start >= 41, bytes[start + 40] == 0x20, (0..<40).allSatisfy({ isHex(bytes[start + $0]) }) {
                    // Header: hash, line in the original file, line in this one, [lines in the group].
                    let hash = text(bytes, start, start + 40)
                    var cursor = start + 41
                    while cursor < end, bytes[cursor] != 0x20 { cursor += 1 }
                    cursor += 1
                    var number = 0
                    while cursor < end, bytes[cursor] >= 48, bytes[cursor] <= 57 {
                        number = number * 10 + Int(bytes[cursor] - 48)
                        cursor += 1
                    }
                    finalLine = number
                    if hash == uncommittedHash {
                        current = -1
                        describing = false
                    } else if let index = known[hash] {
                        current = index
                        describing = false
                    } else {
                        current = Int32(blame.entries.count)
                        known[hash] = current
                        blame.entries.append(Blame.Entry(hash: hash, author: "", email: "", date: .distantPast, summary: ""))
                        describing = true
                    }
                } else if describing, current >= 0 {
                    let index = Int(current)
                    if hasPrefix(bytes, start, end, "author ") {
                        blame.entries[index].author = text(bytes, start + 7, end)
                    } else if hasPrefix(bytes, start, end, "author-mail ") {
                        var from = start + 12, to = end
                        if from < to, bytes[from] == 0x3C { from += 1 }      // <
                        if to > from, bytes[to - 1] == 0x3E { to -= 1 }      // >
                        blame.entries[index].email = text(bytes, from, to)
                    } else if hasPrefix(bytes, start, end, "author-time ") {
                        blame.entries[index].date = Date(timeIntervalSince1970: TimeInterval(text(bytes, start + 12, end)) ?? 0)
                    } else if hasPrefix(bytes, start, end, "summary ") {
                        blame.entries[index].summary = text(bytes, start + 8, end)
                    }
                }
            }
        }
        return blame
    }
}

// MARK: - File and line history

extension Git {
    /// `--grep` arguments for a Log search, matched case-insensitively and literally.
    static func grepArguments(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? [] : ["-i", "--fixed-strings", "--grep=\(q)"]
    }

    /// Commits that changed `path`, newest first, following it through renames, with the path the file had in each.
    /// - Parameter scope: where the history starts: nothing for HEAD, `--all`, or a revision.
    static func fileHistory(_ path: String, in dir: URL, skip: Int, limit: Int, query: String = "",
                            scope: [String] = []) async throws -> (commits: [Commit], paths: [String: String]) {
        let search = grepArguments(query)
        var args = ["log", "--format=%x1e" + logFields, "--decorate=full", "--follow", "--name-only", "-z"]
        if search.isEmpty { args += ["--skip=\(skip)", "--max-count=\(limit)"] }
        let history = parseFileHistory(try await run(args + scope + ["--", path], in: dir, okStatuses: [0, 128]))
        guard !search.isEmpty else { return history }
        // `--follow` loses the file at a rename when `--grep` hides the commit that renamed it. So the whole history
        // is read, and git says which of its commits match, looking under every name the file had.
        let names = Set(history.paths.values).union([path]).sorted()
        let out = try await runString(["log", "--format=%H"] + search + scope + ["--"] + names, in: dir, okStatuses: [0, 128])
        let matching = Set(out.split(separator: "\n").map(String.init))
        let commits = history.commits.filter { matching.contains($0.hash) }
        return (Array(commits.dropFirst(skip).prefix(limit)), history.paths)
    }

    /// Parses `git log --format=%x1e<fields> --name-only -z`: `\x1e<fields>\0\n<path>\0` per commit.
    static func parseFileHistory(_ data: Data) -> (commits: [Commit], paths: [String: String]) {
        var commits: [Commit] = []
        var paths: [String: String] = [:]
        for record in data.split(separator: 0x1e, omittingEmptySubsequences: true) {
            let nul = record.firstIndex(of: 0) ?? record.endIndex
            guard let commit = parseCommit(record[record.startIndex..<nul]) else { continue }
            commits.append(commit)
            guard nul < record.endIndex else { continue }
            var from = record.index(after: nul)
            while from < record.endIndex, record[from] == 0x0A { from = record.index(after: from) }
            let to = record[from...].firstIndex(of: 0) ?? record.endIndex
            if to > from { paths[commit.hash] = String(decoding: record[from..<to], as: UTF8.self) }
        }
        return (commits, paths)
    }

    /// Commits that changed some lines of a file (`git log -L`), newest first.
    /// - Parameters:
    ///   - lines: 1-based, in the file as `rev` has it; `path` is its path there.
    static func lineHistory(_ path: String, lines: ClosedRange<Int>, rev: String, in dir: URL, skip: Int, limit: Int,
                            query: String = "") async throws -> [Commit] {
        var args = ["log", "--format=\(logFormat)", "--decorate=full", "--skip=\(skip)", "--max-count=\(limit)", "-s",
                    "-L\(lines.lowerBound),\(lines.upperBound):\(path)"]
        args += grepArguments(query)
        // A hash or HEAD, never something that reads as an option.
        args.append(rev)
        return parseLog(try await run(args, in: dir, okStatuses: [0, 128]))
    }

    /// The history of some lines of a file in the working tree, counted in HEAD (`git log -L` needs lines of a
    /// commit). Nil when HEAD does not have the file or none of the lines.
    /// - Parameters:
    ///   - path: in the working tree; `headPath` is its path in HEAD, if it was renamed since.
    ///   - lines: 0-based, as the file is on disk.
    static func headLines(of path: String, headPath: String, lines: ClosedRange<Int>, in dir: URL) async -> ClosedRange<Int>? {
        async let head = blob(rev: "HEAD", path: headPath, in: dir)
        guard let new = try? Data(contentsOf: dir.appendingPathComponent(path)), let old = await head,
              let hunks = await DiffLoader.computeHunks(old: old, new: new, ignoreWhitespace: false) else { return nil }
        return Hunk.oldLines(forNew: lines, in: hunks, oldCount: lineCount(of: old))
    }

    /// One commit, by any name git understands.
    static func commit(_ rev: String, in dir: URL) async -> Commit? {
        guard !rev.hasPrefix("-"),
              let data = try? await run(["log", "-1", "--format=\(logFormat)", "--decorate=full", rev, "--"], in: dir) else { return nil }
        return parseLog(data).first
    }

    /// Files touched across `commits` (ordered newest first): for one commit, against its first parent; for two or
    /// more, the cumulative diff from the oldest commit's first parent (or the empty tree for a root commit) to the newest.
    static func commitFiles(_ commits: [Commit], in dir: URL) async throws -> [FileChange] {
        guard let newest = commits.first else { return [] }
        if commits.count == 1 {
            return try await commitFiles(newest, in: dir)
        }
        let oldest = commits[commits.count - 1]
        let base = oldest.parents.first ?? emptyTree
        return try await compareFiles(base: base, head: newest.hash, in: dir)
    }
}

// MARK: - Comparing with another commit

extension Git {
    /// The commit a revision names, or nil when it names none.
    static func resolveCommit(_ rev: String, in dir: URL) async -> String? {
        let name = rev.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix("-"),
              let out = try? await runString(["rev-parse", "--verify", "--quiet", name + "^{commit}"], in: dir) else { return nil }
        let hash = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.count == 40 ? hash : nil
    }

    /// Where two lines of history forked: the newest commit both contain.
    static func mergeBase(_ a: String, _ b: String, in dir: URL) async -> String? {
        guard !a.hasPrefix("-"), !b.hasPrefix("-"),
              let out = try? await runString(["merge-base", a, b], in: dir) else { return nil }
        let hash = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.count == 40 ? hash : nil
    }

    /// Everything that differs between commit `base` and the working tree: tracked files as `git diff <base>` sees
    /// them (staged or not), and untracked files, which `base` cannot have. With `head`, what differs between the
    /// two commits instead.
    static func compareFiles(base: String, head: String? = nil, in dir: URL) async throws -> [FileChange] {
        let range = [base] + (head.map { [$0] } ?? [])
        async let namesData = run(["diff", "--name-status", "-z", "-M"] + range + ["--"], in: dir)
        async let statData = run(["diff", "--numstat", "-z", "-M"] + range + ["--"], in: dir)
        async let othersData = head == nil ? run(["ls-files", "-z", "--others", "--exclude-standard"], in: dir) : Data()
        var changes = parseNameStatus(try await namesData)
        let stats = parseNumstat((try? await statData) ?? Data())
        for index in changes.indices {
            if let s = stats[changes[index].path] {
                changes[index].additions = s.0
                changes[index].deletions = s.1
            }
        }
        let tracked = Set(changes.map(\.path))
        for token in ((try? await othersData) ?? Data()).split(separator: 0, omittingEmptySubsequences: true) {
            let path = String(decoding: token, as: UTF8.self)
            guard !tracked.contains(path) else { continue }
            var change = FileChange(path: path, oldPath: nil, kind: .untracked)
            if let lines = lineCount(dir.appendingPathComponent(path)) {
                change.additions = lines
                change.deletions = 0
            }
            changes.append(change)
        }
        changes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return changes
    }
}

extension Hunk {
    /// The lines of the old text that `lines` of the new text stand for (0-based): unchanged lines one for one,
    /// changed lines the lines they replaced. Nil when all of them are new.
    /// - Parameter hunks: in order, as `git diff -U0` gives them.
    static func oldLines(forNew lines: ClosedRange<Int>, in hunks: [Hunk], oldCount: Int) -> ClosedRange<Int>? {
        var low = Int.max, high = Int.min
        // The first new line after the hunks so far, and how far its old line is from it.
        var cursor = 0, delta = 0
        func unchanged(upTo end: Int) {
            let from = max(lines.lowerBound, cursor), to = min(lines.upperBound, end)
            if from <= to {
                low = min(low, from + delta)
                high = max(high, to + delta)
            }
        }
        for h in hunks {
            unchanged(upTo: h.rightStart - 1)
            if h.rightCount > 0, h.leftCount > 0, h.rightStart <= lines.upperBound, h.rightStart + h.rightCount > lines.lowerBound {
                low = min(low, h.leftStart)
                high = max(high, h.leftStart + h.leftCount - 1)
            }
            cursor = h.rightStart + h.rightCount
            delta = h.leftStart + h.leftCount - cursor
        }
        unchanged(upTo: lines.upperBound)
        low = max(low, 0)
        high = min(high, oldCount - 1)
        return low <= high ? low...high : nil
    }
}
