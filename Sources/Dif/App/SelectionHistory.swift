import AppKit
import Observation

/// Drives the GoLand-style Selection History popup (`⌘B`): lists commits that touched the selected lines
/// in the upper pane and renders a read-only diff restricted strictly to those lines in the lower pane.
@MainActor
@Observable
final class SelectionHistoryModel {
    nonisolated static let pageSize = 100
    nonisolated static let unifiedDefaultsKey = "selectionHistory.unified"

    var projectID: UUID?
    var projectURL: URL?
    var filter: HistoryFilter?
    var displayPath: String = ""
    var displayLines: ClosedRange<Int>?
    var entries: [LineHistoryEntry] = []
    var filterQuery: String = "" {
        didSet {
            if filterQuery != oldValue {
                rebuildFiltered(preserveSelection: true)
            }
        }
    }
    private(set) var filteredEntries: [LineHistoryEntry] = []
    var selectedIndex: Int = 0
    var focusToken: Int = 0
    var isLoading: Bool = false
    var isLoadingMore: Bool = false
    var hasMore: Bool = false
    var errorMessage: String?
    var unified: Bool
    private(set) var previewDocument: DiffDocument?

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored weak var previewContainer: CodeScrollContainer?
    @ObservationIgnored private var documentCache: [String: DiffDocument] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.unified = defaults.object(forKey: Self.unifiedDefaultsKey) as? Bool ?? false
    }

    var selectedEntry: LineHistoryEntry? {
        guard filteredEntries.indices.contains(selectedIndex) else { return nil }
        return filteredEntries[selectedIndex]
    }

    var fileName: String {
        (displayPath as NSString).lastPathComponent
    }

    var lineRangeLabel: String {
        guard let displayLines else { return "" }
        return displayLines.count > 1
            ? "L\(displayLines.lowerBound)–\(displayLines.upperBound)"
            : "L\(displayLines.lowerBound)"
    }

    var diffMode: CodeCanvasView.Mode {
        unified ? .unified : .sideBySide
    }

    /// Resets state for a new selection and loads the first page of `git log -L` commit patches.
    func prepare(project: Project, filter: HistoryFilter, displayPath: String, displayLines: ClosedRange<Int>) {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        let currentGen = generation

        self.projectID = project.id
        self.projectURL = project.url
        self.filter = filter
        self.displayPath = displayPath
        self.displayLines = displayLines
        self.unified = defaults.object(forKey: Self.unifiedDefaultsKey) as? Bool ?? (store?.settings.unified ?? false)
        self.entries = []
        self.filteredEntries = []
        self.filterQuery = ""
        self.selectedIndex = 0
        self.documentCache.removeAll()
        self.previewDocument = nil
        self.previewContainer?.show(nil, mode: diffMode, preserveScroll: false)
        self.errorMessage = nil
        self.hasMore = false
        self.isLoading = true
        self.isLoadingMore = false
        self.focusToken &+= 1

        guard let targetLines = filter.lines ?? Optional(displayLines) else {
            self.isLoading = false
            return
        }
        let repoURL = project.url
        let targetPath = filter.path
        let targetRev = filter.rev

        loadTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await Git.lineHistoryEntries(
                    targetPath,
                    lines: targetLines,
                    rev: targetRev,
                    in: repoURL,
                    skip: 0,
                    limit: Self.pageSize
                )
                guard let self, !Task.isCancelled, self.generation == currentGen else { return }
                self.entries = loaded
                self.hasMore = loaded.count >= Self.pageSize
                self.isLoading = false
                self.rebuildFiltered(preserveSelection: false)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.generation == currentGen else { return }
                self.isLoading = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Loads the next page of commits when available.
    func loadMore() {
        guard !isLoading, !isLoadingMore, hasMore,
              let repoURL = projectURL,
              let filter,
              let targetLines = filter.lines ?? displayLines else { return }

        let currentGen = generation
        let skip = entries.count
        isLoadingMore = true

        loadTask = Task { @MainActor [weak self] in
            do {
                let loaded = try await Git.lineHistoryEntries(
                    filter.path,
                    lines: targetLines,
                    rev: filter.rev,
                    in: repoURL,
                    skip: skip,
                    limit: Self.pageSize
                )
                guard let self, !Task.isCancelled, self.generation == currentGen else { return }
                let known = Set(self.entries.map(\.commit.hash))
                let appended = loaded.filter { !known.contains($0.commit.hash) }
                self.entries.append(contentsOf: appended)
                self.hasMore = loaded.count >= Self.pageSize
                self.isLoadingMore = false
                self.rebuildFiltered(preserveSelection: true)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, self.generation == currentGen else { return }
                self.isLoadingMore = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Populates entries directly for unit tests without spawning git or needing an `AppStore`.
    func setEntriesForTesting(
        displayPath: String,
        displayLines: ClosedRange<Int>,
        entries: [LineHistoryEntry],
        hasMore: Bool = false
    ) {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        self.projectID = nil
        self.projectURL = nil
        self.filter = HistoryFilter(path: displayPath, lines: displayLines)
        self.displayPath = displayPath
        self.displayLines = displayLines
        self.entries = entries
        self.hasMore = hasMore
        self.isLoading = false
        self.isLoadingMore = false
        self.errorMessage = nil
        self.filterQuery = ""
        self.documentCache.removeAll()
        self.selectedIndex = 0
        rebuildFiltered(preserveSelection: false)
    }

    func move(_ delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let next = min(filteredEntries.count - 1, max(0, selectedIndex + delta))
        guard next != selectedIndex else { return }
        selectedIndex = next
        updatePreviewForSelection()
        maybePrefetchMore()
    }

    func select(_ index: Int) {
        guard filteredEntries.indices.contains(index) else { return }
        selectedIndex = index
        updatePreviewForSelection()
        maybePrefetchMore()
    }

    func setUnified(_ value: Bool) {
        guard unified != value else { return }
        unified = value
        defaults.set(value, forKey: Self.unifiedDefaultsKey)
        previewContainer?.setMode(diffMode)
        scrollPreviewToFirstHunk()
    }

    func toggleUnified() {
        setUnified(!unified)
    }

    func activate(_ index: Int? = nil) {
        let targetIndex = index ?? selectedIndex
        guard let store,
              filteredEntries.indices.contains(targetIndex),
              let filter,
              let projectID,
              let project = store.project(projectID) else { return }
        let hash = filteredEntries[targetIndex].commit.hash
        store.dismissPopup(restoreFocus: false)
        store.showHistory(filter, in: project, select: hash)
    }

    func copyHash(_ index: Int? = nil) {
        let targetIndex = index ?? selectedIndex
        guard filteredEntries.indices.contains(targetIndex) else { return }
        store?.copyText(filteredEntries[targetIndex].commit.hash)
    }

    func copyMessage(_ index: Int? = nil) {
        let targetIndex = index ?? selectedIndex
        guard filteredEntries.indices.contains(targetIndex) else { return }
        let commit = filteredEntries[targetIndex].commit
        let text = commit.body.isEmpty ? commit.subject : commit.body
        store?.copyText(text)
    }

    func attachPreview(_ container: CodeScrollContainer) {
        previewContainer = container
        container.canvas.stickyLinesEnabled = false
        container.canvas.vimModeEnabled = false
        container.canvas.showsRevertButtons = false
        container.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
        container.show(previewDocument, mode: diffMode, preserveScroll: false)
        scrollPreviewToFirstHunk()
    }

    func applyCodeFont() {
        previewContainer?.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
    }

    /// Frees cached diff documents and cancels any active `git log -L` task when the popup closes.
    func release() {
        loadTask?.cancel()
        loadTask = nil
        generation &+= 1
        isLoading = false
        isLoadingMore = false
        hasMore = false
        errorMessage = nil
        entries = []
        filteredEntries = []
        documentCache.removeAll()
        previewDocument = nil
        previewContainer?.show(nil, mode: diffMode, preserveScroll: false)
        previewContainer = nil
    }

    nonisolated static func filterEntries(_ entries: [LineHistoryEntry], query: String) -> [LineHistoryEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entries }
        let terms = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let commit = entry.commit
            let refsText = commit.refs.joined(separator: " ")
            let old = entry.oldPath ?? ""
            let path = entry.displayPath
            return terms.allSatisfy { term in
                commit.subject.localizedCaseInsensitiveContains(term)
                    || commit.body.localizedCaseInsensitiveContains(term)
                    || commit.author.localizedCaseInsensitiveContains(term)
                    || commit.email.localizedCaseInsensitiveContains(term)
                    || commit.hash.localizedCaseInsensitiveContains(term)
                    || refsText.localizedCaseInsensitiveContains(term)
                    || path.localizedCaseInsensitiveContains(term)
                    || old.localizedCaseInsensitiveContains(term)
            }
        }
    }

    private func rebuildFiltered(preserveSelection: Bool) {
        let previousHash = preserveSelection ? selectedEntry?.commit.hash : nil
        filteredEntries = Self.filterEntries(entries, query: filterQuery)
        if let previousHash, let idx = filteredEntries.firstIndex(where: { $0.commit.hash == previousHash }) {
            selectedIndex = idx
        } else {
            selectedIndex = 0
        }
        updatePreviewForSelection()
    }

    private func maybePrefetchMore() {
        guard filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              hasMore,
              !isLoading,
              !isLoadingMore,
              selectedIndex >= max(0, filteredEntries.count - 5) else { return }
        loadMore()
    }

    private func updatePreviewForSelection() {
        guard let entry = selectedEntry else {
            previewDocument = nil
            previewContainer?.show(nil, mode: diffMode, preserveScroll: false)
            return
        }
        let doc: DiffDocument
        if let cached = documentCache[entry.commit.hash] {
            doc = cached
        } else {
            let built = entry.makeDiffDocument(fallbackPath: displayPath)
            documentCache[entry.commit.hash] = built
            doc = built
        }
        previewDocument = doc
        previewContainer?.show(doc, mode: diffMode, preserveScroll: false)
        scrollPreviewToFirstHunk()
    }

    private func scrollPreviewToFirstHunk() {
        guard let container = previewContainer,
              let doc = previewDocument,
              case .text = doc.content,
              !doc.hunks.isEmpty else { return }
        let targetHash = selectedEntry?.commit.hash
        container.whenLaidOut { [weak self, weak container] in
            guard let self, let container,
                  self.selectedEntry?.commit.hash == targetHash,
                  !doc.hunks.isEmpty else { return }
            let row = container.canvas.hunkRow(0)
            container.scroll(toRow: row, fraction: 0.18, animated: false)
        }
    }
}
