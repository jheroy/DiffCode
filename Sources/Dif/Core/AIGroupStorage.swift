import Foundation

/// A single self-contained AI grouping session inside a project (either working-tree changes,
/// a branch/commit/stash comparison, or one or more selected commits from Log).
struct AIGroupSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var source: AIHunkGroupingSource
    var result: AIHunkGroupingResult
    /// Snapshot of files at grouping time (authoritative for comparison/commits; fallback for working tree).
    var files: [FileChange]
    var selectedGroupID: UUID?
    var selectedGroupFilePath: String?
    var selectedGroupHunkIndex: Int?
    /// Per-group commit message drafts (stringified `UUID` keys for JSON stability); only used when `isCommittable`.
    var groupCommitMessages: [String: String]
    var headOID: String?
    /// Active file filter snapshot used when generating this session (`nil` for unfiltered or legacy sessions).
    var filter: AIHunkGroupingFilter?

    var isCommittable: Bool { source.isCommittable }

    var activeGroup: AIHunkGroup? {
        guard !result.groups.isEmpty else { return nil }
        if let selectedGroupID, let match = result.groups.first(where: { $0.id == selectedGroupID }) {
            return match
        }
        return result.groups.first
    }

    func change(forPath path: String) -> FileChange? {
        files.first { $0.path == path }
    }

    func baseStamp(projectHeadOID: String?) -> String? {
        switch source {
        case .workingTree:
            return projectHeadOID
        case .comparison(let comp):
            return comp.baseHash
        case .commits:
            return nil
        }
    }

    init(
        id: UUID = UUID(),
        source: AIHunkGroupingSource = .workingTree,
        result: AIHunkGroupingResult,
        files: [FileChange] = [],
        selectedGroupID: UUID? = nil,
        selectedGroupFilePath: String? = nil,
        selectedGroupHunkIndex: Int? = nil,
        groupCommitMessages: [String: String] = [:],
        headOID: String? = nil,
        filter: AIHunkGroupingFilter? = nil
    ) {
        self.id = id
        self.source = source
        self.result = result
        self.files = files
        self.selectedGroupID = selectedGroupID
        self.selectedGroupFilePath = selectedGroupFilePath
        self.selectedGroupHunkIndex = selectedGroupHunkIndex
        self.groupCommitMessages = groupCommitMessages
        self.headOID = headOID
        self.filter = filter
    }
}

/// Serializable snapshot of a repository's AI grouping sessions and active selection.
struct PersistedAIGroupState: Equatable, Codable, Sendable {
    var sessions: [AIGroupSession]
    var activeSessionID: UUID?

    init(sessions: [AIGroupSession], activeSessionID: UUID? = nil) {
        self.sessions = sessions
        self.activeSessionID = activeSessionID
    }
}

/// Persists per-repository AI hunk grouping sessions in Application Support as a versioned JSON map,
/// automatically migrating legacy v1 single-session records on load.
final class AIGroupStorage: @unchecked Sendable {
    static let shared = AIGroupStorage(fileURL: defaultFileURL)

    private struct Envelope: Codable {
        var version: Int = 2
        var records: [String: PersistedAIGroupState] = [:]
    }

    private struct LegacyPersistedAIGroupState: Codable {
        var result: AIHunkGroupingResult
        var selectedGroupID: UUID?
        var selectedGroupFilePath: String?
        var selectedGroupHunkIndex: Int?
        var groupCommitMessages: [String: String]?
        var headOID: String?
    }

    private struct LegacyEnvelope: Codable {
        var version: Int
        var records: [String: LegacyPersistedAIGroupState]
    }

    static var defaultFileURL: URL {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DiffCodeTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
                .appendingPathComponent("ai-groups.json", isDirectory: false)
        }
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
        guard let state = records[key], !state.sessions.isEmpty else {
            return nil
        }
        return state
    }

    /// Saves `state` for `repoURL`, or deletes the record if no non-empty sessions remain.
    func save(_ state: PersistedAIGroupState, for repoURL: URL) {
        let cleanedSessions = state.sessions.filter { !$0.result.groups.isEmpty }
        if cleanedSessions.isEmpty {
            delete(for: repoURL)
            return
        }
        let activeID = state.activeSessionID.flatMap { id in
            cleanedSessions.contains(where: { $0.id == id }) ? id : nil
        } ?? cleanedSessions.first?.id
        let cleaned = PersistedAIGroupState(sessions: cleanedSessions, activeSessionID: activeID)

        let key = Self.repoKey(for: repoURL)
        lock.lock()
        defer { lock.unlock() }
        ensureLoadedLocked()
        if records[key] == cleaned, FileManager.default.fileExists(atPath: fileURL.path) {
            return
        }
        records[key] = cleaned
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
        if let envelope = try? decoder.decode(Envelope.self, from: data) {
            var filtered: [String: PersistedAIGroupState] = [:]
            for (key, state) in envelope.records {
                let nonEmpty = state.sessions.filter { !$0.result.groups.isEmpty }
                guard !nonEmpty.isEmpty else { continue }
                let activeID = state.activeSessionID.flatMap { id in
                    nonEmpty.contains(where: { $0.id == id }) ? id : nil
                } ?? nonEmpty.first?.id
                filtered[key] = PersistedAIGroupState(sessions: nonEmpty, activeSessionID: activeID)
            }
            records = filtered
            return
        }

        if let legacy = try? decoder.decode(LegacyEnvelope.self, from: data) {
            var migrated: [String: PersistedAIGroupState] = [:]
            for (key, state) in legacy.records {
                guard !state.result.groups.isEmpty else { continue }
                let session = AIGroupSession(
                    source: .workingTree,
                    result: state.result,
                    files: [],
                    selectedGroupID: state.selectedGroupID,
                    selectedGroupFilePath: state.selectedGroupFilePath,
                    selectedGroupHunkIndex: state.selectedGroupHunkIndex,
                    groupCommitMessages: state.groupCommitMessages ?? [:],
                    headOID: state.headOID
                )
                migrated[key] = PersistedAIGroupState(sessions: [session], activeSessionID: session.id)
            }
            records = migrated
            return
        }

        records = [:]
    }

    private func writeLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(version: 2, records: records)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
