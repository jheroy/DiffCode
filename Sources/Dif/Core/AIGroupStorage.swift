import Foundation

/// Serializable snapshot of a repository's active AI hunk grouping state, selection, and per-group drafts.
struct PersistedAIGroupState: Equatable, Codable, Sendable {
    var result: AIHunkGroupingResult
    var selectedGroupID: UUID?
    var selectedGroupFilePath: String?
    var selectedGroupHunkIndex: Int?
    var groupCommitMessages: [String: String]
    var headOID: String?

    init(
        result: AIHunkGroupingResult,
        selectedGroupID: UUID? = nil,
        selectedGroupFilePath: String? = nil,
        selectedGroupHunkIndex: Int? = nil,
        groupCommitMessages: [String: String] = [:],
        headOID: String? = nil
    ) {
        self.result = result
        self.selectedGroupID = selectedGroupID
        self.selectedGroupFilePath = selectedGroupFilePath
        self.selectedGroupHunkIndex = selectedGroupHunkIndex
        self.groupCommitMessages = groupCommitMessages
        self.headOID = headOID
    }
}

/// Persists per-repository AI hunk grouping results in Application Support as a versioned JSON map.
final class AIGroupStorage: @unchecked Sendable {
    static let shared = AIGroupStorage(fileURL: defaultFileURL)

    private struct Envelope: Codable {
        var version: Int = 1
        var records: [String: PersistedAIGroupState] = [:]
    }

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (Sandbox.realHome as NSString).appendingPathComponent("Library/Application Support"))
        return appSupport
            .appendingPathComponent("DiffCode", isDirectory: true)
            .appendingPathComponent("ai-groups.json", isDirectory: false)
    }

    /// Normalizes a repository URL into a stable storage key resilient to symlinks and trailing slashes.
    static func repoKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var loaded = false
    private var records: [String: PersistedAIGroupState] = [:]

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Loads the persisted grouping state for `repoURL`, returning `nil` when absent or empty.
    func load(for repoURL: URL) -> PersistedAIGroupState? {
        let key = Self.repoKey(for: repoURL)
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        guard let state = records[key], !state.result.groups.isEmpty else {
            return nil
        }
        return state
    }

    /// Saves `state` for `repoURL`, or deletes the record if no groups remain.
    func save(_ state: PersistedAIGroupState, for repoURL: URL) {
        if state.result.groups.isEmpty {
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
            try? FileManager.default.removeItem(at: fileURL)
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
        records = envelope.records.filter { !$0.value.result.groups.isEmpty }
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
