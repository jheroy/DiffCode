import Foundation

/// One independent tab inside a project's Git Log panel, owning its filters,
/// commit selection, selected file, and cached runtime lists for instant switching.
struct LogTab: Identifiable, Equatable, Sendable {
    let id: UUID

    // Persisted configuration & selection
    var history: HistoryFilter?
    var logQuery: String
    var logAuthors: [AuthorFilter]
    var logAllBranches: Bool
    var logRef: String?
    var selectedCommitID: String?
    var selectedCommitIDs: Set<String>
    var selectedCommitFileID: String?
    var commitCollapsed: Set<String>
    /// Marks a tab restored from disk whose selection should be preserved/fetched on first load.
    var needsSelectionRestore: Bool

    // Runtime in-memory cache (not persisted)
    var commits: [Commit]
    var historyPaths: [String: String]
    var hasMoreCommits: Bool
    var commitFiles: [FileChange]
    var commitSelectionIsNonContiguous: Bool
    var commitFileSteps: [String: [FileCommitStep]]
    var commitSkippedMergeCount: Int
    var commitBody: String
    var loadedCommitSelectionIDs: Set<String>
    var hasLoadedCommitSelection: Bool
    var isStale: Bool

    init(
        id: UUID = UUID(),
        history: HistoryFilter? = nil,
        logQuery: String = "",
        logAuthors: [AuthorFilter] = [],
        logAllBranches: Bool = false,
        logRef: String? = nil,
        selectedCommitID: String? = nil,
        selectedCommitIDs: Set<String> = [],
        selectedCommitFileID: String? = nil,
        commitCollapsed: Set<String> = [],
        needsSelectionRestore: Bool = false,
        commits: [Commit] = [],
        historyPaths: [String: String] = [:],
        hasMoreCommits: Bool = true,
        commitFiles: [FileChange] = [],
        commitSelectionIsNonContiguous: Bool = false,
        commitFileSteps: [String: [FileCommitStep]] = [:],
        commitSkippedMergeCount: Int = 0,
        commitBody: String = "",
        loadedCommitSelectionIDs: Set<String> = [],
        hasLoadedCommitSelection: Bool = false,
        isStale: Bool = false
    ) {
        self.id = id
        self.history = history
        self.logQuery = logQuery
        self.logAuthors = logAuthors
        self.logAllBranches = logAllBranches
        self.logRef = logRef
        var normalizedIDs = selectedCommitIDs
        if let selectedCommitID {
            normalizedIDs.insert(selectedCommitID)
        }
        self.selectedCommitID = selectedCommitID ?? normalizedIDs.first
        self.selectedCommitIDs = normalizedIDs
        self.selectedCommitFileID = selectedCommitFileID
        self.commitCollapsed = commitCollapsed
        self.needsSelectionRestore = needsSelectionRestore
        self.commits = commits
        self.historyPaths = historyPaths
        self.hasMoreCommits = hasMoreCommits
        self.commitFiles = commitFiles
        self.commitSelectionIsNonContiguous = commitSelectionIsNonContiguous
        self.commitFileSteps = commitFileSteps
        self.commitSkippedMergeCount = commitSkippedMergeCount
        self.commitBody = commitBody
        self.loadedCommitSelectionIDs = loadedCommitSelectionIDs
        self.hasLoadedCommitSelection = hasLoadedCommitSelection
        self.isStale = isStale
    }

    init(persisted: PersistedLogTab) {
        self.init(
            id: persisted.id,
            history: persisted.history,
            logQuery: persisted.logQuery,
            logAuthors: persisted.logAuthors,
            logAllBranches: persisted.logAllBranches,
            logRef: persisted.logRef,
            selectedCommitID: persisted.selectedCommitID,
            selectedCommitIDs: Set(persisted.selectedCommitIDs),
            selectedCommitFileID: persisted.selectedCommitFileID,
            commitCollapsed: Set(persisted.commitCollapsed),
            needsSelectionRestore: persisted.selectedCommitID != nil || !persisted.selectedCommitIDs.isEmpty
        )
    }

    func persisted() -> PersistedLogTab {
        var ids = selectedCommitIDs
        if let selectedCommitID {
            ids.insert(selectedCommitID)
        }
        return PersistedLogTab(
            id: id,
            history: history,
            logQuery: logQuery,
            logAuthors: logAuthors,
            logAllBranches: logAllBranches,
            logRef: logRef,
            selectedCommitID: selectedCommitID ?? ids.first,
            selectedCommitIDs: ids.sorted(),
            selectedCommitFileID: selectedCommitFileID,
            commitCollapsed: commitCollapsed.sorted()
        )
    }

    /// Creates a duplicate tab with a new identity, copying both persisted state and cached data.
    func duplicated(id newID: UUID = UUID()) -> LogTab {
        LogTab(
            id: newID,
            history: history,
            logQuery: logQuery,
            logAuthors: logAuthors,
            logAllBranches: logAllBranches,
            logRef: logRef,
            selectedCommitID: selectedCommitID,
            selectedCommitIDs: selectedCommitIDs,
            selectedCommitFileID: selectedCommitFileID,
            commitCollapsed: commitCollapsed,
            needsSelectionRestore: needsSelectionRestore,
            commits: commits,
            historyPaths: historyPaths,
            hasMoreCommits: hasMoreCommits,
            commitFiles: commitFiles,
            commitSelectionIsNonContiguous: commitSelectionIsNonContiguous,
            commitFileSteps: commitFileSteps,
            commitSkippedMergeCount: commitSkippedMergeCount,
            commitBody: commitBody,
            loadedCommitSelectionIDs: loadedCommitSelectionIDs,
            hasLoadedCommitSelection: hasLoadedCommitSelection,
            isStale: isStale
        )
    }

    var logRefLabel: String? {
        logRef.map { ref in
            for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where ref.hasPrefix(prefix) {
                return String(ref.dropFirst(prefix.count))
            }
            return ref
        }
    }

    var isCustomized: Bool {
        history != nil
            || !logAuthors.isEmpty
            || !logQuery.trimmingCharacters(in: .whitespaces).isEmpty
            || logRef != nil
            || logAllBranches
            || selectedCommitIDs.count > 1
    }

    var hasPersistableState: Bool {
        isCustomized
            || selectedCommitID != nil
            || !selectedCommitIDs.isEmpty
            || selectedCommitFileID != nil
    }

    var symbolName: String {
        if let history {
            return history.lines == nil ? "clock.arrow.circlepath" : "text.line.first.and.arrowtriangle.forward"
        }
        if !logAuthors.isEmpty {
            return logAuthors.count > 1 ? "person.2.fill" : "person.fill"
        }
        if logRef != nil || logAllBranches {
            return "arrow.triangle.branch"
        }
        return "clock"
    }

    var displayTitle: String {
        if let history {
            return history.label
        }
        let trimmedQuery = logQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopePart: String?
        if !logAuthors.isEmpty {
            if logAuthors.count == 1 {
                scopePart = logAuthors[0].displayName
            } else {
                scopePart = L(
                    "\(logAuthors[0].displayName) +\(logAuthors.count - 1)",
                    "\(logAuthors[0].displayName) 等\(logAuthors.count)人"
                )
            }
        } else if !trimmedQuery.isEmpty {
            scopePart = trimmedQuery
        } else if let label = logRefLabel {
            scopePart = label
        } else if logAllBranches {
            scopePart = L("All", "全部分支")
        } else {
            scopePart = nil
        }

        if let scopePart {
            if selectedCommitIDs.count > 1 {
                return "\(scopePart) · \(selectedCommitIDs.count)"
            }
            return scopePart
        }
        if selectedCommitIDs.count > 1 {
            return L("\(selectedCommitIDs.count) commits", "\(selectedCommitIDs.count) 个提交")
        }
        if let id = selectedCommitID, !id.isEmpty, (commits.isEmpty || commits.first?.id != id) {
            return String(id.prefix(7))
        }
        return L("Log", "日志")
    }

    var tooltip: String {
        var parts: [String] = []
        if let history {
            let revText = history.rev == "HEAD" ? history.path : "\(history.path) @ \(history.rev.prefix(7))"
            if let lines = history.lines {
                let lineText = lines.count > 1 ? "L\(lines.lowerBound)–\(lines.upperBound)" : "L\(lines.lowerBound)"
                parts.append("\(revText) (\(lineText))")
            } else {
                parts.append(revText)
            }
        }
        if !logAuthors.isEmpty {
            parts.append(L("Authors: ", "作者：") + logAuthors.map(\.displayName).joined(separator: ", "))
        }
        let trimmedQuery = logQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            parts.append(L("Search: ", "搜索：") + trimmedQuery)
        }
        if let label = logRefLabel {
            parts.append(L("Branch: ", "分支：") + label)
        } else if logAllBranches {
            parts.append(L("All branches", "全部分支"))
        }
        if selectedCommitIDs.count > 1 {
            let ordered = commits.filter { selectedCommitIDs.contains($0.id) }.map(\.shortHash)
            let hashes = ordered.isEmpty ? selectedCommitIDs.sorted().map { String($0.prefix(7)) } : ordered
            let preview = hashes.prefix(4).joined(separator: ", ") + (hashes.count > 4 ? "…" : "")
            parts.append(L("\(selectedCommitIDs.count) commits: \(preview)", "已选 \(selectedCommitIDs.count) 个提交：\(preview)"))
        } else if let id = selectedCommitID, !id.isEmpty {
            if let commit = commits.first(where: { $0.id == id }) {
                parts.append("\(commit.shortHash) · \(commit.subject)")
            } else {
                parts.append(String(id.prefix(7)))
            }
        }
        if let fileID = selectedCommitFileID, fileID.hasPrefix("f:") {
            parts.append(String(fileID.dropFirst(2)))
        }
        return parts.isEmpty ? L("Git Log", "提交历史") : parts.joined(separator: "\n")
    }
}
