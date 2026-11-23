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
                            authors: [AuthorFilter] = [], scope: [String] = []) async throws -> (commits: [Commit], paths: [String: String]) {
        let search = grepArguments(query)
        let hasFilter = !search.isEmpty || !authors.isEmpty
        var args = ["log", "--format=%x1e" + logFields, "--decorate=full", "--follow", "--name-only", "-z"]
        if !hasFilter { args += ["--skip=\(skip)", "--max-count=\(limit)"] }
        let history = parseFileHistory(try await run(args + scope + ["--", path], in: dir, okStatuses: [0, 128]))
        guard hasFilter else { return history }
        var commits = history.commits
        if !authors.isEmpty {
            let allowed = Set(authors)
            commits = commits.filter { allowed.contains(AuthorFilter.from($0)) }
        }
        if !search.isEmpty {
            // `--follow` loses the file at a rename when `--grep` hides the commit that renamed it. So the whole history
            // is read, and git says which of its commits match, looking under every name the file had.
            let names = Set(history.paths.values).union([path]).sorted()
            let out = try await runString(["log", "--format=%H"] + search + scope + ["--"] + names, in: dir, okStatuses: [0, 128])
            let matching = Set(out.split(separator: "\n").map(String.init))
            commits = commits.filter { matching.contains($0.hash) }
        }
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
                            query: String = "", authors: [AuthorFilter] = []) async throws -> [Commit] {
        var args = ["log", "--format=\(logFormat)", "--decorate=full", "--skip=\(skip)", "--max-count=\(limit)", "-s",
                    "-L\(lines.lowerBound),\(lines.upperBound):\(path)"]
        args += authorFilterArguments(authors, query: query)
        // A hash or HEAD, never something that reads as an option.
        args.append(rev)
        return parseLog(try await run(args, in: dir, okStatuses: [0, 128]))
    }

    private static let lineHistoryStartMarker = Data([0x1E]) + Data("DIF_LH_START\u{1F}".utf8)
    private static let lineHistoryPatchMarker = Data("\u{1E}DIF_LH_PATCH\u{1E}".utf8)
    private static let lineHistoryFormat = "%x1eDIF_LH_START%x1f" + logFields + "%x1f%B%x1eDIF_LH_PATCH%x1e"

    /// Commits that changed some lines of a file (`git log -L`), newest first, including each commit's
    /// tracked-line patch restricted strictly to those lines.
    static func lineHistoryEntries(_ path: String, lines: ClosedRange<Int>, rev: String, in dir: URL,
                                   skip: Int, limit: Int, query: String = "",
                                   authors: [AuthorFilter] = []) async throws -> [LineHistoryEntry] {
        guard !rev.hasPrefix("-") else { return [] }
        var args = ["log", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
                    "--format=\(lineHistoryFormat)", "--decorate=full", "--skip=\(skip)", "--max-count=\(limit)",
                    "-L\(lines.lowerBound),\(lines.upperBound):\(path)"]
        args += authorFilterArguments(authors, query: query)
        args.append(rev)
        return parseLineHistoryEntries(try await run(args, in: dir, okStatuses: [0, 128]))
    }

    /// Parses output produced by `git log --format=<lineHistoryFormat> -L...`.
    static func parseLineHistoryEntries(_ data: Data) -> [LineHistoryEntry] {
        var entries: [LineHistoryEntry] = []
        for record in splitData(data, by: lineHistoryStartMarker) {
            guard let patchMarkerRange = record.range(of: lineHistoryPatchMarker) else { continue }
            let headerData = record[record.startIndex..<patchMarkerRange.lowerBound]
            let patchData = record[patchMarkerRange.upperBound..<record.endIndex]
            let fields = headerData.split(separator: 0x1F, maxSplits: 7, omittingEmptySubsequences: false)
            guard fields.count >= 7 else { continue }

            let hash = String(decoding: fields[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard hash.count >= 7 else { continue }
            let parents = String(decoding: fields[1], as: UTF8.self).split(separator: " ").map(String.init)
            let author = String(decoding: fields[2], as: UTF8.self)
            let email = String(decoding: fields[3], as: UTF8.self)
            let date = Date(timeIntervalSince1970: TimeInterval(String(decoding: fields[4], as: UTF8.self)) ?? 0)
            let refs = String(decoding: fields[5], as: UTF8.self)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let subject = String(decoding: fields[6], as: UTF8.self)
            let body = fields.count >= 8
                ? String(decoding: fields[7], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                : ""

            let commit = Commit(
                hash: hash,
                parents: parents,
                author: author,
                email: email,
                date: date,
                refs: refs,
                subject: subject,
                body: body
            )
            let patchText = patchData.isEmpty ? "" : TextCodec.decode(Data(patchData))
            entries.append(parseLineHistoryPatch(patchText, commit: commit))
        }
        return entries
    }

    private static func splitData(_ data: Data, by separator: Data) -> [Data] {
        guard !data.isEmpty, !separator.isEmpty else { return [] }
        var slices: [Data] = []
        var cursor = data.startIndex
        while cursor < data.endIndex {
            guard let range = data.range(of: separator, in: cursor..<data.endIndex) else {
                slices.append(Data(data[cursor..<data.endIndex]))
                break
            }
            if range.lowerBound > cursor {
                slices.append(Data(data[cursor..<range.lowerBound]))
            }
            cursor = range.upperBound
        }
        return slices
    }

    private struct ParsedHunkHeader {
        var oldStart: Int
        var oldCount: Int
        var newStart: Int
        var newCount: Int
        var prefixWidth: Int
        var section: String
    }

    private static func parseHunkHeader(_ line: Substring) -> ParsedHunkHeader? {
        let atCount = line.prefix(while: { $0 == "@" }).count
        guard atCount >= 2 else { return nil }
        let markers = String(repeating: "@", count: atCount)
        guard line.hasPrefix(markers + " ") else { return nil }
        let afterPrefix = line.dropFirst(atCount + 1)
        guard let closeRange = afterPrefix.range(of: " " + markers) else { return nil }
        let rangesPart = afterPrefix[..<closeRange.lowerBound]
        let section = afterPrefix[closeRange.upperBound...].trimmingCharacters(in: .whitespaces)
        let tokens = rangesPart.split(separator: " ", omittingEmptySubsequences: true)
        guard let oldToken = tokens.first(where: { $0.hasPrefix("-") }),
              let newToken = tokens.last(where: { $0.hasPrefix("+") }),
              let oldRange = parseHunkRangeToken(oldToken, prefix: "-"),
              let newRange = parseHunkRangeToken(newToken, prefix: "+") else {
            return nil
        }
        return ParsedHunkHeader(
            oldStart: oldRange.start,
            oldCount: oldRange.count,
            newStart: newRange.start,
            newCount: newRange.count,
            prefixWidth: max(1, atCount - 1),
            section: section
        )
    }

    private static func parseHunkRangeToken(_ token: Substring, prefix: Character) -> (start: Int, count: Int)? {
        guard token.first == prefix else { return nil }
        let body = token.dropFirst()
        let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard let start = Int(parts[0]) else { return nil }
        let count: Int
        if parts.count == 2 {
            guard let parsedCount = Int(parts[1]) else { return nil }
            count = parsedCount
        } else {
            count = 1
        }
        return (start, count)
    }

    private static func parsePatchHeaderPath(_ raw: String, prefix: String) -> String? {
        let cleaned = raw.hasSuffix("\t") ? String(raw.dropLast()) : raw
        if cleaned == "/dev/null" { return nil }
        if cleaned.hasPrefix(prefix) { return String(cleaned.dropFirst(prefix.count)) }
        return cleaned
    }

    private static func parseLineHistoryPatch(_ patchText: String, commit: Commit) -> LineHistoryEntry {
        var oldPath: String?
        var newPath: String?
        var sawOldHeader = false
        var sawNewHeader = false
        var fallbackOldPath: String?
        var fallbackNewPath: String?

        var leftLines: [String] = []
        var rightLines: [String] = []
        var leftLineNumbers: [Int] = []
        var rightLineNumbers: [Int] = []
        var hunks: [Hunk] = []
        var sectionHeader = ""
        var firstLeftStart: Int?
        var firstRightStart: Int?

        var inHunk = false
        var prefixWidth = 1
        var remainingOld = 0
        var remainingNew = 0
        var curOldLine = 1
        var curNewLine = 1

        var pendingLeftStart: Int?
        var pendingLeftCount = 0
        var pendingRightStart: Int?
        var pendingRightCount = 0

        func flushPendingHunk() {
            guard pendingLeftCount > 0 || pendingRightCount > 0 else { return }
            let ls = pendingLeftStart ?? leftLines.count
            let rs = pendingRightStart ?? rightLines.count
            hunks.append(Hunk(leftStart: ls, leftCount: pendingLeftCount, rightStart: rs, rightCount: pendingRightCount))
            pendingLeftStart = nil
            pendingLeftCount = 0
            pendingRightStart = nil
            pendingRightCount = 0
        }

        func appendContext(_ text: String) {
            flushPendingHunk()
            leftLines.append(text)
            leftLineNumbers.append(curOldLine)
            curOldLine += 1
            rightLines.append(text)
            rightLineNumbers.append(curNewLine)
            curNewLine += 1
        }

        func appendRemoved(_ text: String) {
            if pendingLeftStart == nil { pendingLeftStart = leftLines.count }
            if pendingRightStart == nil { pendingRightStart = rightLines.count }
            leftLines.append(text)
            leftLineNumbers.append(curOldLine)
            curOldLine += 1
            pendingLeftCount += 1
        }

        func appendAdded(_ text: String) {
            if pendingLeftStart == nil { pendingLeftStart = leftLines.count }
            if pendingRightStart == nil { pendingRightStart = rightLines.count }
            rightLines.append(text)
            rightLineNumbers.append(curNewLine)
            curNewLine += 1
            pendingRightCount += 1
        }

        let lines = TextCodec.splitLines(patchText)
        for lineStr in lines {
            let line = Substring(lineStr)

            if inHunk {
                if line.hasPrefix("\\ No newline at end of file") {
                    continue
                }
                var stillInHunk = remainingOld > 0 || remainingNew > 0
                if !stillInHunk && prefixWidth >= 2 && line.count >= prefixWidth
                    && !line.hasPrefix("diff --git ") && !line.hasPrefix("@@")
                    && !line.hasPrefix("--- ") && !line.hasPrefix("+++ ")
                    && line.prefix(prefixWidth).allSatisfy({ $0 == " " || $0 == "-" || $0 == "+" }) {
                    stillInHunk = true
                }

                if stillInHunk {
                    if prefixWidth == 1 {
                        if line.isEmpty {
                            if remainingOld > 0 && remainingNew > 0 {
                                appendContext("")
                                remainingOld -= 1
                                remainingNew -= 1
                                continue
                            }
                        } else if let marker = line.first {
                            let content = String(line.dropFirst())
                            switch marker {
                            case " ":
                                appendContext(content)
                                remainingOld = max(0, remainingOld - 1)
                                remainingNew = max(0, remainingNew - 1)
                                continue
                            case "-":
                                appendRemoved(content)
                                remainingOld = max(0, remainingOld - 1)
                                continue
                            case "+":
                                appendAdded(content)
                                remainingNew = max(0, remainingNew - 1)
                                continue
                            default:
                                break
                            }
                        }
                    } else if line.count >= prefixWidth {
                        let prefix = Array(line.prefix(prefixWidth))
                        if prefix.allSatisfy({ $0 == " " || $0 == "-" || $0 == "+" }) {
                            let content = String(line.dropFirst(prefixWidth))
                            if prefix.contains("-") {
                                if prefix[0] == "-" {
                                    appendRemoved(content)
                                    remainingOld = max(0, remainingOld - 1)
                                }
                            } else if prefix[0] == "+" {
                                appendAdded(content)
                                remainingNew = max(0, remainingNew - 1)
                            } else {
                                appendContext(content)
                                remainingOld = max(0, remainingOld - 1)
                                remainingNew = max(0, remainingNew - 1)
                            }
                            continue
                        }
                    } else if line.isEmpty && remainingOld > 0 && remainingNew > 0 {
                        appendContext("")
                        remainingOld -= 1
                        remainingNew -= 1
                        continue
                    }
                }

                flushPendingHunk()
                inHunk = false
            }

            if let header = parseHunkHeader(line) {
                flushPendingHunk()
                if firstLeftStart == nil { firstLeftStart = header.oldStart }
                if firstRightStart == nil { firstRightStart = header.newStart }
                if sectionHeader.isEmpty && !header.section.isEmpty {
                    sectionHeader = header.section
                }
                inHunk = true
                prefixWidth = header.prefixWidth
                remainingOld = header.oldCount
                remainingNew = header.newCount
                curOldLine = max(1, header.oldStart)
                curNewLine = max(1, header.newStart)
                continue
            }

            if line.hasPrefix("diff --git ") {
                let rest = line.dropFirst(11)
                if let bRange = rest.range(of: " b/") {
                    let aPart = rest[..<bRange.lowerBound]
                    let bPart = rest[bRange.upperBound...]
                    if fallbackOldPath == nil {
                        fallbackOldPath = aPart.hasPrefix("a/") ? String(aPart.dropFirst(2)) : String(aPart)
                    }
                    if fallbackNewPath == nil {
                        fallbackNewPath = String(bPart)
                    }
                }
            } else if line.hasPrefix("--- ") {
                sawOldHeader = true
                oldPath = parsePatchHeaderPath(String(line.dropFirst(4)), prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                sawNewHeader = true
                newPath = parsePatchHeaderPath(String(line.dropFirst(4)), prefix: "b/")
            }
        }

        flushPendingHunk()

        return LineHistoryEntry(
            commit: commit,
            oldPath: sawOldHeader ? oldPath : fallbackOldPath,
            newPath: sawNewHeader ? newPath : fallbackNewPath,
            leftStartLine: firstLeftStart ?? (leftLineNumbers.first ?? 0),
            rightStartLine: firstRightStart ?? (rightLineNumbers.first ?? 0),
            leftLines: leftLines,
            rightLines: rightLines,
            leftLineNumbers: leftLineNumbers,
            rightLineNumbers: rightLineNumbers,
            hunks: hunks,
            sectionHeader: sectionHeader
        )
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

    /// Looks up specific commits by hash in a single git invocation, falling back per-hash if any object is missing.
    static func commits(hashes: [String], in dir: URL) async -> [Commit] {
        var seen: Set<String> = []
        var cleaned: [String] = []
        for raw in hashes {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), seen.insert(trimmed).inserted else { continue }
            cleaned.append(trimmed)
        }
        guard !cleaned.isEmpty else { return [] }

        let args = ["log", "--no-walk=unsorted", "--ignore-missing", "--format=\(logFormat)", "--decorate=full"] + cleaned + ["--"]
        if let data = try? await run(args, in: dir) {
            return parseLog(data)
        }
        var recovered: [Commit] = []
        recovered.reserveCapacity(cleaned.count)
        for hash in cleaned {
            if let item = await commit(hash, in: dir) {
                recovered.append(item)
            }
        }
        return recovered
    }
}

/// One commit returned by `git log -L`, carrying both commit metadata and the patch restricted to the tracked lines.
struct LineHistoryEntry: Identifiable, Equatable, Sendable {
    var commit: Commit
    var oldPath: String?
    var newPath: String?
    var leftStartLine: Int
    var rightStartLine: Int
    var leftLines: [String]
    var rightLines: [String]
    var leftLineNumbers: [Int]
    var rightLineNumbers: [Int]
    var hunks: [Hunk]
    var sectionHeader: String

    var id: String { commit.hash }

    var displayPath: String { newPath ?? oldPath ?? "" }

    var isRename: Bool {
        guard let oldPath, let newPath else { return false }
        return oldPath != newPath
    }

    var additions: Int { hunks.reduce(0) { $0 + $1.rightCount } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.leftCount } }

    var leftLineRange: ClosedRange<Int>? {
        guard let first = leftLineNumbers.first, let last = leftLineNumbers.last else { return nil }
        return min(first, last)...max(first, last)
    }

    var rightLineRange: ClosedRange<Int>? {
        guard let first = rightLineNumbers.first, let last = rightLineNumbers.last else { return nil }
        return min(first, last)...max(first, last)
    }

    /// Builds a read-only `DiffDocument` showing only the excerpt diff for the tracked lines, with original line numbers.
    func makeDiffDocument(fallbackPath: String) -> DiffDocument {
        if leftLines.isEmpty && rightLines.isEmpty {
            let doc = DiffDocument.message(
                L("No line changes in first-parent diff", "相对第一父提交无行变更"),
                detail: commit.subject
            )
            doc.leftTitle = commit.parents.first.map { String($0.prefix(7)) } ?? L("Empty", "空")
            doc.rightTitle = commit.shortHash
            return doc
        }
        let path = displayPath.isEmpty ? fallbackPath : displayPath
        let language = LanguageSpec.detect(path: path)
        let leftBuffer = TextBuffer(lines: leftLines)
        leftBuffer.spans = Highlighter.highlight(leftLines, language: language)
        let rightBuffer = TextBuffer(lines: rightLines)
        rightBuffer.spans = Highlighter.highlight(rightLines, language: language)
        var resolvedHunks = hunks
        DiffLoader.addInlineHighlights(&resolvedHunks, left: leftLines, right: rightLines)

        let doc = DiffDocument(left: leftBuffer, right: rightBuffer, hunks: resolvedHunks, language: language)
        doc.editing = nil
        doc.leftLineNumbers = leftLineNumbers
        doc.rightLineNumbers = rightLineNumbers
        doc.leftTitle = (oldPath == nil && leftLines.isEmpty)
            ? L("Empty", "空")
            : (commit.parents.first.map { String($0.prefix(7)) } ?? L("Empty", "空"))
        doc.rightTitle = (newPath == nil && rightLines.isEmpty)
            ? L("Deleted", "已删除")
            : commit.shortHash
        return doc
    }
}

/// A single commit's touch on a file when aggregating non-contiguous Log commit selections.
struct FileCommitStep: Equatable, Hashable, Sendable {
    var hash: String
    /// First parent hash, or nil for a root commit.
    var parent: String?
    /// File path at `hash`.
    var path: String
    /// Previous path at `parent` when renamed in this commit.
    var oldPath: String?
    var kind: FileChange.Kind
}

/// Aggregated file list and per-file commit steps for a Log commit selection.
struct CommitSelectionSummary: Equatable, Sendable {
    var isNonContiguous: Bool
    var files: [FileChange]
    /// Chronological steps (oldest → newest) per final `path`; empty for contiguous selections.
    var fileSteps: [String: [FileCommitStep]]
    var skippedMergeCount: Int
}

extension Git {
    /// True when `commits` (ordered newest first) forms an unbroken linear single-parent chain.
    static func isContiguousLinearChain(_ commits: [Commit]) -> Bool {
        guard commits.count >= 2 else { return true }
        for i in 0..<(commits.count - 1) {
            let commit = commits[i]
            guard commit.parents.count == 1, commit.parents[0] == commits[i + 1].hash else {
                return false
            }
        }
        return true
    }

    /// Parses batched `git log --no-walk=unsorted -m --first-parent --format=%x1e%H --name-status -z -M`.
    static func parseBatchedNameStatus(_ data: Data) -> [String: [FileChange]] {
        var result: [String: [FileChange]] = [:]
        for (hash, body) in splitBatchedCommitRecords(data) {
            result[hash] = body.isEmpty ? [] : parseNameStatus(body)
        }
        return result
    }

    /// Parses batched `git log --no-walk=unsorted -m --first-parent --format=%x1e%H --numstat -z -M`.
    static func parseBatchedNumstat(_ data: Data) -> [String: [String: (Int, Int)]] {
        var result: [String: [String: (Int, Int)]] = [:]
        for (hash, body) in splitBatchedCommitRecords(data) {
            result[hash] = body.isEmpty ? [:] : parseNumstat(body)
        }
        return result
    }

    private static func splitBatchedCommitRecords(_ data: Data) -> [(hash: String, body: Data)] {
        var records: [(String, Data)] = []
        for record in data.split(separator: 0x1E, omittingEmptySubsequences: true) {
            let hashEnd = record.firstIndex(where: { $0 == 0x00 || $0 == 0x0A }) ?? record.endIndex
            let hash = String(decoding: record[record.startIndex..<hashEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard hash.count >= 7 else { continue }
            var bodyStart = hashEnd
            while bodyStart < record.endIndex, record[bodyStart] == 0x00 || record[bodyStart] == 0x0A {
                bodyStart = record.index(after: bodyStart)
            }
            let body = bodyStart < record.endIndex ? Data(record[bodyStart...]) : Data()
            records.append((hash, body))
        }
        return records
    }

    /// Aggregated summary of `commits` (ordered newest first): uses the fast range diff for single commits
    /// or contiguous linear chains, and exact per-commit aggregation for non-contiguous selections.
    static func commitSelectionSummary(_ commits: [Commit], in dir: URL) async throws -> CommitSelectionSummary {
        guard let newest = commits.first else {
            return CommitSelectionSummary(isNonContiguous: false, files: [], fileSteps: [:], skippedMergeCount: 0)
        }
        if commits.count == 1 {
            return CommitSelectionSummary(
                isNonContiguous: false,
                files: try await commitFiles(newest, in: dir),
                fileSteps: [:],
                skippedMergeCount: 0
            )
        }
        if isContiguousLinearChain(commits) {
            let oldest = commits[commits.count - 1]
            let base = oldest.parents.first ?? emptyTree
            let files = try await compareFiles(base: base, head: newest.hash, in: dir)
            return CommitSelectionSummary(isNonContiguous: false, files: files, fileSteps: [:], skippedMergeCount: 0)
        }

        // Skip merge commits when non-merge commits exist so merge parents do not pull in other authors' branch work.
        let nonMerges = commits.filter { !$0.isMerge }
        let skippedMergeCount = nonMerges.isEmpty ? 0 : commits.count - nonMerges.count
        let targetCommits = nonMerges.isEmpty ? commits : nonMerges

        var nameStatusByHash: [String: [FileChange]] = [:]
        var numstatByHash: [String: [String: (Int, Int)]] = [:]
        let batchSize = 400
        let hashes = targetCommits.map(\.hash)
        var offset = 0
        while offset < hashes.count {
            let end = min(hashes.count, offset + batchSize)
            let chunk = Array(hashes[offset..<end])
            offset = end
            async let namesData = run(
                ["log", "--no-walk=unsorted", "-m", "--first-parent", "--format=%x1e%H", "--name-status", "-z", "-M"]
                    + chunk + ["--"],
                in: dir
            )
            async let statsData = run(
                ["log", "--no-walk=unsorted", "-m", "--first-parent", "--format=%x1e%H", "--numstat", "-z", "-M"]
                    + chunk + ["--"],
                in: dir
            )
            let chunkNames = parseBatchedNameStatus(try await namesData)
            let chunkStats = parseBatchedNumstat((try? await statsData) ?? Data())
            nameStatusByHash.merge(chunkNames) { _, new in new }
            numstatByHash.merge(chunkStats) { _, new in new }
        }

        struct FileGroup {
            var path: String
            var initialOldPath: String?
            var firstKind: FileChange.Kind
            var lastKind: FileChange.Kind
            var additions: Int?
            var deletions: Int?
            var steps: [FileCommitStep]
            var isActive = true
        }

        var groups: [FileGroup] = []
        var indexByPath: [String: Int] = [:]

        for commit in targetCommits.reversed() {
            let changes = nameStatusByHash[commit.hash] ?? []
            let stats = numstatByHash[commit.hash] ?? [:]
            for change in changes {
                let step = FileCommitStep(
                    hash: commit.hash,
                    parent: commit.parents.first,
                    path: change.path,
                    oldPath: change.oldPath,
                    kind: change.kind
                )
                let stat = stats[change.path]
                let lookupPath = change.oldPath ?? change.path

                if let existingIdx = indexByPath[lookupPath], groups[existingIdx].isActive {
                    if lookupPath != change.path {
                        indexByPath.removeValue(forKey: lookupPath)
                        if let occupiedIdx = indexByPath[change.path], occupiedIdx != existingIdx {
                            groups[occupiedIdx].isActive = false
                        }
                        indexByPath[change.path] = existingIdx
                    }
                    groups[existingIdx].path = change.path
                    groups[existingIdx].lastKind = change.kind
                    if let stat {
                        groups[existingIdx].additions = (groups[existingIdx].additions ?? 0) + stat.0
                        groups[existingIdx].deletions = (groups[existingIdx].deletions ?? 0) + stat.1
                    }
                    groups[existingIdx].steps.append(step)
                } else {
                    if let occupiedIdx = indexByPath[change.path] {
                        groups[occupiedIdx].isActive = false
                    }
                    let newIdx = groups.count
                    groups.append(FileGroup(
                        path: change.path,
                        initialOldPath: change.oldPath ?? change.path,
                        firstKind: change.kind,
                        lastKind: change.kind,
                        additions: stat?.0,
                        deletions: stat?.1,
                        steps: [step]
                    ))
                    indexByPath[change.path] = newIdx
                }
            }
        }

        var files: [FileChange] = []
        var fileSteps: [String: [FileCommitStep]] = [:]
        for group in groups where group.isActive {
            let netKind: FileChange.Kind
            let netOldPath: String?
            if group.firstKind == .added {
                netKind = group.lastKind == .deleted ? .deleted : .added
                netOldPath = nil
            } else if group.lastKind == .deleted {
                netKind = .deleted
                netOldPath = (group.initialOldPath != group.path) ? group.initialOldPath : nil
            } else if let initial = group.initialOldPath, initial != group.path {
                netKind = .renamed
                netOldPath = initial
            } else {
                netKind = .modified
                netOldPath = nil
            }
            files.append(FileChange(
                path: group.path,
                oldPath: netOldPath,
                kind: netKind,
                additions: group.additions,
                deletions: group.deletions
            ))
            fileSteps[group.path] = group.steps
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return CommitSelectionSummary(
            isNonContiguous: true,
            files: files,
            fileSteps: fileSteps,
            skippedMergeCount: skippedMergeCount
        )
    }

    /// Files touched across `commits` (ordered newest first): for one commit, against its first parent; for two or
    /// more contiguous commits, the cumulative diff from the oldest commit's first parent to the newest; for
    /// non-contiguous commits, aggregated strictly from the selected commits.
    static func commitFiles(_ commits: [Commit], in dir: URL) async throws -> [FileChange] {
        try await commitSelectionSummary(commits, in: dir).files
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
