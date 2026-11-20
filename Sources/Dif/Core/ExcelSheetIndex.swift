import Foundation

/// A single sheet discovered in a project's `.xlsx` workbook.
struct ExcelSheetEntry: Equatable, Sendable {
    let path: String
    let sheetName: String
}

/// Thread-safe lazy cache mapping `.xlsx` workbooks to their sheet names.
///
/// First lookup reads only each workbook's ZIP Central Directory + `xl/workbook.xml`
/// via `XLSXReader.sheetNames(at:)` in parallel; subsequent lookups reuse cached
/// sheet names unless a file's modification timestamp, size, or project file list changes.
actor ExcelSheetIndex {
    static let shared = ExcelSheetIndex()

    private struct FileStamp: Equatable, Sendable {
        let mtimeSeconds: Int
        let mtimeNanoseconds: Int
        let size: Int64
    }

    private struct CachedWorkbook: Sendable {
        let fileMtime: Date?
        let stamp: FileStamp
        let sheets: [String]
    }

    private var cache: [URL: CachedWorkbook] = [:]
    private var projectURLs: [URL: Set<URL>] = [:]
    private(set) var parseCountForTesting = 0

    init() {}

    /// Returns `true` for `.xlsx` files excluding Excel temporary lock files (`~$...`).
    static func isIndexableSpreadsheetPath(_ path: String) -> Bool {
        guard DiffLoader.isSpreadsheetPath(path) else { return false }
        let fileName = (path as NSString).lastPathComponent
        return !fileName.hasPrefix("~$")
    }

    /// Returns all sheet entries across indexable `.xlsx` files in `files` relative to `root`.
    func entries(in root: URL, files: [String]) async -> [ExcelSheetEntry] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let spreadsheetPaths = files.filter { Self.isIndexableSpreadsheetPath($0) }

        if spreadsheetPaths.isEmpty {
            pruneRemovedFiles(for: canonicalRoot, activeURLs: [])
            return []
        }

        struct Target {
            let relativePath: String
            let canonicalURL: URL
            let hasFile: Bool
        }

        var targets: [Target] = []
        targets.reserveCapacity(spreadsheetPaths.count)
        var misses: [(url: URL, mtime: Date?, stamp: FileStamp)] = []
        var queuedMissURLs = Set<URL>()
        var activeURLs = Set<URL>()

        for path in spreadsheetPaths {
            let fileURL = canonicalRoot.appendingPathComponent(path).standardizedFileURL
            activeURLs.insert(fileURL)
            let metadata = Self.fileMetadata(at: fileURL)
            targets.append(Target(relativePath: path, canonicalURL: fileURL, hasFile: metadata != nil))

            guard let metadata else {
                cache.removeValue(forKey: fileURL)
                continue
            }
            if let cached = cache[fileURL], cached.stamp == metadata.stamp {
                continue
            }
            if queuedMissURLs.insert(fileURL).inserted {
                misses.append((url: fileURL, mtime: metadata.mtime, stamp: metadata.stamp))
            }
        }

        pruneRemovedFiles(for: canonicalRoot, activeURLs: activeURLs)

        if !misses.isEmpty {
            let parsed = await withTaskGroup(
                of: (URL, Date?, FileStamp, [String]).self,
                returning: [(URL, Date?, FileStamp, [String])].self
            ) { group in
                for miss in misses {
                    group.addTask {
                        guard !Task.isCancelled else {
                            return (miss.url, miss.mtime, miss.stamp, [])
                        }
                        let sheets = XLSXReader.sheetNames(at: miss.url)
                        return (miss.url, miss.mtime, miss.stamp, sheets)
                    }
                }
                var results: [(URL, Date?, FileStamp, [String])] = []
                results.reserveCapacity(misses.count)
                for await item in group {
                    results.append(item)
                }
                return results
            }

            if Task.isCancelled { return [] }

            for (url, mtime, stamp, sheets) in parsed {
                parseCountForTesting += 1
                if let current = Self.fileMetadata(at: url), current.stamp == stamp {
                    cache[url] = CachedWorkbook(fileMtime: mtime, stamp: stamp, sheets: sheets)
                }
            }
        }

        var result: [ExcelSheetEntry] = []
        result.reserveCapacity(targets.count * 2)
        for target in targets {
            guard target.hasFile, let sheets = cache[target.canonicalURL]?.sheets else { continue }
            for sheetName in sheets {
                result.append(ExcelSheetEntry(path: target.relativePath, sheetName: sheetName))
            }
        }
        return result
    }

    /// Ranks sheet entries matching `query` using `Fuzzy.match` on `sheetName`.
    static func rankSheets(
        query: String,
        in entries: [ExcelSheetEntry],
        limit: Int = 40,
        isCancelled: () -> Bool = { false }
    ) -> [(entry: ExcelSheetEntry, score: Int, positions: [Int])] {
        let q = Array(query.lowercased().utf8).filter { $0 != 32 }
        guard !q.isEmpty, !entries.isEmpty else { return [] }

        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(min(entries.count, 256))
        for (index, entry) in entries.enumerated() {
            if index & 0x3FF == 0, isCancelled() { return [] }
            if let match = Fuzzy.match(query: q, candidate: entry.sheetName, wantPositions: false) {
                scored.append((match.score, index))
            }
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = entries[$0.index], rhs = entries[$1.index]
            if lhs.sheetName.utf8.count != rhs.sheetName.utf8.count {
                return lhs.sheetName.utf8.count < rhs.sheetName.utf8.count
            }
            return lhs.path < rhs.path
        }
        return scored.prefix(limit).compactMap { item in
            let entry = entries[item.index]
            guard let match = Fuzzy.match(query: q, candidate: entry.sheetName, wantPositions: true) else { return nil }
            return (entry: entry, score: match.score, positions: match.positions)
        }
    }

    private func pruneRemovedFiles(for root: URL, activeURLs: Set<URL>) {
        let previous = projectURLs[root] ?? []
        if activeURLs.isEmpty {
            projectURLs.removeValue(forKey: root)
        } else {
            projectURLs[root] = activeURLs
        }
        let removed = previous.subtracting(activeURLs)
        guard !removed.isEmpty else { return }
        for url in removed {
            let referencedElsewhere = projectURLs.values.contains { $0.contains(url) }
            if !referencedElsewhere {
                cache.removeValue(forKey: url)
            }
        }
    }

    private nonisolated static func fileMetadata(at url: URL) -> (mtime: Date?, stamp: FileStamp)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let sec = st.st_mtimespec.tv_sec
        let nsec = st.st_mtimespec.tv_nsec
        let date = Date(timeIntervalSince1970: TimeInterval(sec) + TimeInterval(nsec) / 1_000_000_000)
        let stamp = FileStamp(mtimeSeconds: Int(sec), mtimeNanoseconds: Int(nsec), size: Int64(st.st_size))
        return (date, stamp)
    }
}
