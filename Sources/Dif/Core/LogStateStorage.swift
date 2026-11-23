import Foundation

/// The Log narrowed to one file's commits, or to the commits that changed some of its lines.
struct HistoryFilter: Equatable, Hashable, Codable, Sendable {
    /// The file's path in `rev`.
    var path: String
    /// 1-based lines of the file as `rev` has it; nil for the whole file.
    var lines: ClosedRange<Int>?
    /// Where the history starts, and where `lines` are counted.
    var rev: String = "HEAD"

    var name: String { (path as NSString).lastPathComponent }

    /// "Main.kt", "Main.kt:12-20".
    var label: String {
        guard let lines else { return name }
        return lines.count > 1 ? "\(name):\(lines.lowerBound)-\(lines.upperBound)" : "\(name):\(lines.lowerBound)"
    }
}

/// Serializable snapshot of a single Log tab's filter, commit selection, and selected file state.
struct PersistedLogTab: Equatable, Codable, Sendable {
    var id: UUID
    var history: HistoryFilter?
    var logQuery: String
    var logAuthors: [AuthorFilter]
    var logAllBranches: Bool
    var logRef: String?
    var selectedCommitID: String?
    var selectedCommitIDs: [String]
    var selectedCommitFileID: String?
    var commitCollapsed: [String]

    init(
        id: UUID = UUID(),
        history: HistoryFilter? = nil,
        logQuery: String = "",
        logAuthors: [AuthorFilter] = [],
        logAllBranches: Bool = false,
        logRef: String? = nil,
        selectedCommitID: String? = nil,
        selectedCommitIDs: [String] = [],
        selectedCommitFileID: String? = nil,
        commitCollapsed: [String] = []
    ) {
        self.id = id
        self.history = history
        self.logQuery = logQuery
        self.logAuthors = logAuthors
        self.logAllBranches = logAllBranches
        self.logRef = logRef
        self.selectedCommitID = selectedCommitID
        self.selectedCommitIDs = selectedCommitIDs
        self.selectedCommitFileID = selectedCommitFileID
        self.commitCollapsed = commitCollapsed
    }
}

/// Serializable snapshot of a repository's Log tabs and active tab selection.
struct PersistedLogState: Equatable, Codable, Sendable {
    var activeProjectTab: String?
    var activeTabID: UUID?
    var tabs: [PersistedLogTab]

    init(
        activeProjectTab: String? = nil,
        activeTabID: UUID? = nil,
        tabs: [PersistedLogTab] = []
    ) {
        self.activeProjectTab = activeProjectTab
        self.activeTabID = activeTabID
        self.tabs = tabs
    }
}

/// Persists per-repository Log tabs, filters, and commit selections in Application Support as a versioned JSON map.
final class LogStateStorage: @unchecked Sendable {
    static let shared = LogStateStorage(fileURL: defaultFileURL)

    private struct Envelope: Codable {
        var version: Int = 1
        var records: [String: PersistedLogState] = [:]
    }

    static var defaultFileURL: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DiffCodeTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("log-state.json", isDirectory: false)
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (Sandbox.realHome as NSString).appendingPathComponent("Library/Application Support"))
        return appSupport
            .appendingPathComponent("DiffCode", isDirectory: true)
            .appendingPathComponent("log-state.json", isDirectory: false)
    }

    /// Normalizes a repository URL into a stable storage key resilient to symlinks and trailing slashes.
    static func repoKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var loaded = false
    private var records: [String: PersistedLogState] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the persisted Log state for `repoURL`, returning `nil` when absent or empty.
    func load(for repoURL: URL) -> PersistedLogState? {
        let key = Self.repoKey(for: repoURL)
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        guard let state = records[key], !state.tabs.isEmpty else {
            return nil
        }
        return state
    }

    /// Saves `state` for `repoURL`, or deletes the record if no tabs remain.
    func save(_ state: PersistedLogState, for repoURL: URL) {
        if state.tabs.isEmpty {
            delete(for: repoURL)
            return
        }
        let key = Self.repoKey(for: repoURL)
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        if records[key] == state, FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        records[key] = state
        writeLocked()
    }

    /// Removes the persisted record for `repoURL` (and deletes the backing file when empty).
    func delete(for repoURL: URL) {
        let key = Self.repoKey(for: repoURL)
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        guard records.removeValue(forKey: key) != nil else { return }
        if records.isEmpty {
            try? FileManager.default.removeItem(atPath: fileURL.path)
        } else {
            writeLocked()
        }
    }

    /// Returns all repository keys currently stored on disk.
    func allKeys() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        return Set(records.keys)
    }

    private func ensureLoadedLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            records = [:]
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            records = [:]
            return
        }
        records = envelope.records.filter { !$0.value.tabs.isEmpty }
    }

    private func writeLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: 1, records: records)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
