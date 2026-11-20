import Foundation

/// One symbol found anywhere in a project, for Go to Symbol (`⌥⌘O`, Vim `gs`).
struct ProjectSymbol: Sendable, Equatable {
    /// Repository-relative path.
    let path: String
    let name: String
    let detail: String
    let kind: FileSymbolKind
    /// 1-based line.
    let line: Int
    /// 0-based UTF-16 column of the name.
    let column: Int
    let isExported: Bool
}

/// Project-wide symbol index built with `FileSymbolExtractor`, cached per file by size and modification date,
/// so reopening Go to Symbol only rereads the files that changed.
final class SymbolIndex: @unchecked Sendable {
    static let shared = SymbolIndex()

    /// Larger files are almost always generated or minified.
    static let maxFileBytes = 1_000_000

    private struct Entry {
        var size: Int
        var modified: Date
        var symbols: [ProjectSymbol]
    }

    private let lock = NSLock()
    private var cache: [String: [String: Entry]] = [:]

    /// Whether `path` is in a language the extractor understands.
    static func isIndexable(_ path: String) -> Bool {
        let language = LanguageSpec.detect(path: path)
        switch language.name {
        case "Go", "Swift", "Rust", "JavaScript", "Python", "C/C++": return true
        default: return language.family == .cLike
        }
    }

    /// Every symbol in `files` under `root`. Returns nil when cancelled.
    func symbols(root: URL, files: [String], isCancelled: @escaping @Sendable () -> Bool) -> [ProjectSymbol]? {
        let candidates = files.filter(Self.isIndexable)
        let rootKey = root.standardizedFileURL.path
        lock.lock()
        let previous = cache[rootKey] ?? [:]
        lock.unlock()

        final class Results: @unchecked Sendable {
            var entries: [Entry?]
            init(count: Int) { entries = [Entry?](repeating: nil, count: count) }
        }
        let results = Results(count: candidates.count)
        let resultLock = NSLock()
        let chunk = 64
        let chunks = (candidates.count + chunk - 1) / chunk
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            if isCancelled() { return }
            var local: [(Int, Entry)] = []
            for i in (c * chunk)..<min(candidates.count, (c + 1) * chunk) {
                let path = candidates[i]
                let url = root.appendingPathComponent(path)
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let size = values.fileSize, size <= Self.maxFileBytes,
                      let modified = values.contentModificationDate else { continue }
                if let old = previous[path], old.size == size, old.modified == modified {
                    local.append((i, old))
                    continue
                }
                local.append((i, Entry(size: size, modified: modified, symbols: Self.extract(url: url, path: path))))
            }
            resultLock.lock()
            for (i, entry) in local { results.entries[i] = entry }
            resultLock.unlock()
        }
        if isCancelled() { return nil }

        var fresh: [String: Entry] = [:]
        fresh.reserveCapacity(candidates.count)
        var all: [ProjectSymbol] = []
        for (i, entry) in results.entries.enumerated() {
            guard let entry else { continue }
            fresh[candidates[i]] = entry
            all += entry.symbols
        }
        lock.lock()
        cache[rootKey] = fresh
        lock.unlock()
        return all
    }

    private static func extract(url: URL, path: String) -> [ProjectSymbol] {
        guard let data = try? Data(contentsOf: url), !TextCodec.looksBinary(data) else { return [] }
        let lines = TextCodec.splitLines(TextCodec.decode(data))
        return FileSymbolExtractor.extract(lines: lines, language: LanguageSpec.detect(path: path)).map {
            ProjectSymbol(path: path, name: $0.name, detail: $0.detail, kind: $0.kind,
                          line: $0.lineNumber, column: $0.column, isExported: $0.isExported)
        }
    }

    struct Ranked: Sendable {
        let symbol: ProjectSymbol
        /// UTF-8 offsets of the matched characters in `symbol.name`.
        let positions: [Int]
    }

    /// Best `limit` matches of `query` against symbol names: exact, then prefix, then fuzzy; types and
    /// exported names first on ties. `Type.method` queries match the last segment and prefer
    /// symbols whose receiver or file mentions `Type`.
    static func rank(query: String, in symbols: [ProjectSymbol], limit: Int,
                     isCancelled: () -> Bool = { false }) -> [Ranked] {
        var text = query.trimmingCharacters(in: .whitespaces)
        var container = ""
        if let dot = text.lastIndex(of: "."), text.index(after: dot) < text.endIndex {
            container = String(text[..<dot]).lowercased()
            text = String(text[text.index(after: dot)...])
        }
        let lowered = text.lowercased()
        let q = Array(lowered.utf8).filter { $0 != 32 }
        guard !q.isEmpty else { return [] }
        var scored: [(score: Int, index: Int)] = []
        for (index, symbol) in symbols.enumerated() {
            if index & 0x3FF == 0, isCancelled() { return [] }
            guard let m = Fuzzy.match(query: q, candidate: symbol.name, wantPositions: false) else { continue }
            var score = m.score
            let name = symbol.name.lowercased()
            if name == lowered { score += 10_000 } else if name.hasPrefix(lowered) { score += 5_000 }
            if !container.isEmpty,
               symbol.detail.lowercased().contains(container) || symbol.path.lowercased().contains(container) {
                score += 20_000
            }
            if symbol.isExported { score += 50 }
            switch symbol.kind {
            case .struct, .interface, .class, .enum, .type: score += 100
            default: break
            }
            scored.append((score, index))
        }
        scored.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let a = symbols[$0.index], b = symbols[$1.index]
            if a.name.utf8.count != b.name.utf8.count { return a.name.utf8.count < b.name.utf8.count }
            return a.path < b.path
        }
        return scored.prefix(limit).map { entry in
            let symbol = symbols[entry.index]
            let positions = Fuzzy.match(query: q, candidate: symbol.name, wantPositions: true)?.positions ?? []
            return Ranked(symbol: symbol, positions: positions)
        }
    }
}
