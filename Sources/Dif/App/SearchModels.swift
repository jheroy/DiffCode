import AppKit
import Observation

/// Thread-safe cancellation flag shared across unstructured detached tasks.
final class SearchCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

// MARK: - Quick open (Search Everywhere / Go to File / Find Action / Recent Files)

@MainActor
@Observable
final class QuickOpenModel {
    /// `branches`: the branches and tags to compare the working tree with (Compare with Branch…).
    /// `stashes`: the stash list.
    enum Scope: Equatable { case all, files, actions, recent, branches, stashes }

    enum Item: Identifiable {
        case file(projectID: UUID, path: String, positions: [Int], kind: FileChange.Kind?)
        case action(AppCommand)
        /// A branch or tag to compare with; `positions` are the matched characters of its short name.
        case ref(GitRef, positions: [Int])
        /// Whatever was typed, taken as a commit to compare with.
        case revision(String)
        /// A stash, to look at; `positions` are the matched characters of its title.
        case stash(StashEntry, positions: [Int])
        /// Stash Changes…, at the top of the stash list.
        case stashChanges(count: Int)

        var id: String {
            switch self {
            case .file(let project, let path, _, _): return "f:\(project.uuidString):\(path)"
            case .action(let command): return "a:" + command.id
            case .ref(let ref, _): return "r:" + ref.name
            case .revision(let text): return "v:" + text
            case .stash(let entry, _): return "s:" + entry.hash
            case .stashChanges: return "s:new"
            }
        }
    }

    var scope: Scope = .all
    var query = "" {
        didSet {
            if query != oldValue, !isPreparing {
                update()
            }
        }
    }
    var items: [Item] = []
    var selected = 0
    var focusToken = 0
    var isIndexing = false

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchCancelFlag: SearchCancelFlag?
    @ObservationIgnored private var searchGeneration: UInt64 = 0
    /// Test hook: overrides `project.files()` so tests can inject deterministic file lists and async delays.
    @ObservationIgnored var filesProviderForTesting: (@MainActor (Project) async -> [String])?
    /// Test hook: incremented on every `update()` invocation so tests can verify no duplicate calls in `prepare()`.
    @ObservationIgnored private(set) var updateCallCountForTesting = 0
    /// The branches and tags offered for comparing, read as the picker opens.
    @ObservationIgnored private var refs: [GitRef]?
    /// The stash list, read as it opens.
    @ObservationIgnored private var stashList: [StashEntry]?

    func prepare(scope: Scope) {
        isPreparing = true
        self.scope = scope
        // Like IntelliJ, reopening keeps the previous query selected so typing replaces it.
        if scope == .recent || scope == .actions || scope == .branches || scope == .stashes { query = "" }
        if scope == .branches { refs = nil }
        if scope == .stashes { stashList = nil }
        focusToken += 1
        isPreparing = false
        update()
    }

    func setScope(_ scope: Scope) {
        guard scope != self.scope else { return }
        self.scope = scope
        update()
    }

    func cycleScope(_ delta: Int) {
        guard scope != .branches, scope != .stashes else { return }
        let order: [Scope] = [.all, .files, .actions]
        let index = order.firstIndex(of: scope) ?? 0
        setScope(order[(index + delta + order.count) % order.count])
    }

    /// Splits a trailing ":123" line number off the query.
    private func parse(_ raw: String) -> (text: String, line: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let colon = trimmed.lastIndex(of: ":"), let line = Int(trimmed[trimmed.index(after: colon)...]), line > 0 {
            return (String(trimmed[..<colon]), line)
        }
        return (trimmed, nil)
    }

    func update() {
        updateCallCountForTesting += 1
        searchTask?.cancel()
        searchTask = nil
        searchCancelFlag?.cancel()
        searchCancelFlag = nil
        searchGeneration &+= 1
        let generation = searchGeneration
        guard let store else { return }
        let (text, _) = parse(query)
        let project = store.currentProject
        if scope == .branches {
            updateBranches(text, in: project, generation: generation)
            return
        }
        if scope == .stashes {
            updateStashes(query.trimmingCharacters(in: .whitespaces), in: project, generation: generation)
            return
        }
        let changeKinds = Dictionary(uniqueKeysWithValues: (project?.changes ?? []).map { ($0.path, $0.kind) })

        var actions: [Item] = []
        if scope == .actions || scope == .all {
            let needle = text.lowercased()
            let matched = store.commands.filter { command in
                needle.isEmpty ? scope == .actions : command.title.lowercased().contains(needle)
            }
            actions = matched.map { Item.action($0) }
        }
        if scope == .actions {
            isIndexing = false
            items = actions
            selected = 0
            return
        }
        guard let project else {
            isIndexing = false
            items = actions
            selected = 0
            return
        }

        if text.isEmpty {
            isIndexing = false
            // No query: recently viewed files first, then everything with local changes.
            var seen = Set<String>()
            var list: [Item] = []
            for entry in store.recent {
                guard let owner = store.project(entry.projectID), scope == .recent || owner.id == project.id else { continue }
                if seen.insert(owner.id.uuidString + entry.path).inserted {
                    let kind = owner.changes.first { $0.path == entry.path }?.kind
                    list.append(.file(projectID: owner.id, path: entry.path, positions: [], kind: kind))
                }
            }
            for change in project.changes where seen.insert(project.id.uuidString + change.path).inserted {
                list.append(.file(projectID: project.id, path: change.path, positions: [], kind: change.kind))
            }
            items = Array(list.prefix(60))
            selected = min(selected, max(0, items.count - 1))
            if scope == .recent, items.count > 1 { selected = 1 } // ⌘E then ↩ flips to the previous file
            return
        }

        let projectID = project.id
        let provider = filesProviderForTesting
        isIndexing = provider == nil && project.cachedFiles == nil
        let cancelFlag = SearchCancelFlag()
        searchCancelFlag = cancelFlag
        searchTask = Task { @MainActor [weak self] in
            let files: [String]
            if let provider {
                files = await provider(project)
            } else {
                files = await project.files()
            }
            guard let self, !Task.isCancelled, !cancelFlag.isCancelled, self.searchGeneration == generation else { return }
            let ranked = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    Fuzzy.rank(query: text, in: files, limit: 80, isCancelled: { cancelFlag.isCancelled })
                }.value
            } onCancel: {
                cancelFlag.cancel()
            }
            guard !Task.isCancelled, !cancelFlag.isCancelled, self.searchGeneration == generation else { return }
            self.isIndexing = false
            var list: [Item] = ranked.map { .file(projectID: projectID, path: $0.path, positions: $0.positions, kind: changeKinds[$0.path]) }
            if self.scope == .all { list += actions }
            self.items = list
            self.selected = 0
        }
    }

    /// The picker of what to compare with: local branches first (the current one at the top), then remote ones and
    /// tags; and, once something is typed that names none of them, that text as a commit.
    private func updateBranches(_ text: String, in project: Project?, generation: UInt64) {
        guard let project else {
            isIndexing = false
            items = []
            return
        }
        guard let refs else {
            isIndexing = true
            items = []
            searchTask = Task { @MainActor [weak self] in
                let refs = (try? await Git.refs(in: project.url)) ?? []
                guard let self, !Task.isCancelled, self.searchGeneration == generation, self.scope == .branches else { return }
                self.isIndexing = false
                self.refs = refs
                self.update()
            }
            return
        }
        isIndexing = false
        let order: [GitRef.Kind] = [.local, .remote, .tag]
        let sorted = refs.enumerated().sorted { a, b in
            if a.element.isHead != b.element.isHead { return a.element.isHead }
            let ka = order.firstIndex(of: a.element.kind) ?? 0, kb = order.firstIndex(of: b.element.kind) ?? 0
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var list: [Item]
        if text.isEmpty {
            list = sorted.prefix(200).map { .ref($0, positions: []) }
        } else {
            var byName: [String: GitRef] = [:]
            for ref in sorted where byName[ref.shortName] == nil { byName[ref.shortName] = ref }
            list = Fuzzy.rank(query: text, in: sorted.map(\.shortName), limit: 80).compactMap { ranked in
                byName[ranked.path].map { .ref($0, positions: ranked.positions) }
            }
            if byName[text] == nil, !text.hasPrefix("-") { list.append(.revision(text)) }
        }
        items = list
        selected = 0
    }

    /// The stash list, newest first, under Stash Changes… while there is something to stash.
    private func updateStashes(_ text: String, in project: Project?, generation: UInt64) {
        guard let project else {
            isIndexing = false
            items = []
            return
        }
        guard let stashList else {
            isIndexing = true
            items = []
            searchTask = Task { @MainActor [weak self] in
                let list = await Git.stashes(in: project.url)
                guard let self, !Task.isCancelled, self.searchGeneration == generation, self.scope == .stashes else { return }
                self.isIndexing = false
                self.stashList = list
                self.update()
            }
            return
        }
        isIndexing = false
        var list: [Item] = []
        if text.isEmpty {
            if !project.changes.isEmpty { list.append(.stashChanges(count: project.changes.count)) }
            list += stashList.map { .stash($0, positions: []) }
        } else {
            // Matched against the title, then where it was made ("main"), as typed.
            let titles = stashList.map { $0.title + "  " + ($0.branch ?? "") }
            let ranked = Fuzzy.rank(query: text, in: titles, limit: 80)
            let byTitle = Dictionary(zip(titles, stashList), uniquingKeysWith: { first, _ in first })
            list = ranked.compactMap { match in byTitle[match.path].map { .stash($0, positions: match.positions) } }
        }
        items = list
        // Straight to the newest stash rather than to Stash Changes….
        selected = list.count > 1 && text.isEmpty && !project.changes.isEmpty ? 1 : 0
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        selected = (selected + delta + items.count) % items.count
    }

    func activate(_ index: Int? = nil) {
        guard let store else { return }
        let target = index ?? selected
        guard target >= 0, target < items.count else { return }
        let (_, line) = parse(query)
        switch items[target] {
        case .file(let projectID, let path, _, _):
            guard let project = store.project(projectID) else { return }
            store.dismissPopup(restoreFocus: false)
            store.openFile(in: project, path: path, line: line)
            store.viewer.focusCanvas()
        case .action(let command):
            store.dismissPopup()
            command.action()
        case .ref(let ref, _):
            // A branch is compared from where it and HEAD forked: what this side changed, not what the other did since.
            store.compare(with: ref.name, title: ref.shortName, forkPoint: ref.kind != .tag)
        case .revision(let text):
            store.compare(with: text, title: text, forkPoint: false)
        case .stash(let entry, _):
            store.showStash(entry)
        case .stashChanges:
            store.dismissPopup()
            store.stashChanges()
        }
    }
}

// MARK: - Shared Popup File Filter

/// Filename-level toggles shared by Search and References popups.
struct PopupFileFilter: Equatable, Sendable {
    enum Scope: String, Sendable {
        case references
        case findInPath

        var excludeTestGoKey: String { "popupFilter.\(rawValue).excludeTestGo" }
        var onlyGoFilesKey: String { "popupFilter.\(rawValue).onlyGoFiles" }
    }

    var excludeTestGo: Bool = false
    var onlyGoFiles: Bool = false

    var isActive: Bool { excludeTestGo || onlyGoFiles }

    /// Returns `true` when `path` satisfies the active `excludeTestGo` and `onlyGoFiles` rules.
    func matches(path: String) -> Bool {
        let fileName = (path as NSString).lastPathComponent.lowercased()
        if onlyGoFiles && !fileName.hasSuffix(".go") {
            return false
        }
        if excludeTestGo && fileName.hasSuffix("test.go") {
            return false
        }
        return true
    }

    static func load(scope: Scope, defaults: UserDefaults = .standard) -> PopupFileFilter {
        PopupFileFilter(
            excludeTestGo: defaults.bool(forKey: scope.excludeTestGoKey),
            onlyGoFiles: defaults.bool(forKey: scope.onlyGoFilesKey)
        )
    }

    func save(scope: Scope, defaults: UserDefaults = .standard) {
        defaults.set(excludeTestGo, forKey: scope.excludeTestGoKey)
        defaults.set(onlyGoFiles, forKey: scope.onlyGoFilesKey)
    }
}

// MARK: - Find in Files

@MainActor
@Observable
final class FindInPathModel {
    struct Hit: Identifiable {
        let id: Int
        var projectID: UUID
        var path: String
        var line: Int
        var text: String
        /// Match range within `text`, in UTF-16 units.
        var match: Range<Int>?
    }

    static let limit = 3000

    var query = "" {
        didSet {
            if query != oldValue, !isPreparing {
                queryChanged()
            }
        }
    }
    var options = GrepOptions()
    var allProjects = false
    var excludeTestGo: Bool {
        didSet {
            if excludeTestGo != oldValue {
                persistAndRefilter()
            }
        }
    }
    var onlyGoFiles: Bool {
        didSet {
            if onlyGoFiles != oldValue {
                persistAndRefilter()
            }
        }
    }
    var hits: [Hit] = []
    private(set) var totalHitCount = 0
    var fileCount = 0
    var selected = 0
    var isSearching = false
    var truncated = false
    var focusToken = 0
    var previewDocument: DiffDocument?
    var previewPath = ""
    var errorText: String?

    var fileFilter: PopupFileFilter {
        PopupFileFilter(excludeTestGo: excludeTestGo, onlyGoFiles: onlyGoFiles)
    }

    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored weak var previewContainer: CodeScrollContainer?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var allHits: [Hit] = []
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var debounce: DispatchWorkItem?
    @ObservationIgnored private var generation = 0
    /// Files with visible results in the search under way (projects can share relative paths, hence the project prefix).
    @ObservationIgnored private var searchFiles: Set<String> = []
    @ObservationIgnored private var previewKey = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = PopupFileFilter.load(scope: .findInPath, defaults: defaults)
        self.excludeTestGo = saved.excludeTestGo
        self.onlyGoFiles = saved.onlyGoFiles
    }

    func prepare(seed: String?) {
        isPreparing = true
        if let seed { query = seed }
        focusToken += 1
        isPreparing = false
        if seed != nil || (hits.isEmpty && !query.isEmpty) { search() }
    }

    func queryChanged() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.search() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func search() {
        debounce?.cancel()
        searchTask?.cancel()
        generation += 1
        let token = generation
        let pattern = query
        allHits = []
        hits = []
        totalHitCount = 0
        fileCount = 0
        selected = 0
        truncated = false
        errorText = nil
        guard let store, pattern.count >= 2 || (pattern.count == 1 && !pattern.unicodeScalars.allSatisfy { $0.isASCII }) else {
            isSearching = false
            setPreview(nil)
            return
        }
        if options.regex, (try? NSRegularExpression(pattern: pattern)) == nil {
            errorText = L("Invalid regular expression", "正则表达式无效")
            isSearching = false
            return
        }
        let targets = allProjects ? store.projects : [store.currentProject].compactMap { $0 }
        let options = self.options
        let highlighter = Self.matcher(pattern: pattern, options: options)
        isSearching = true

        searchFiles = []
        // The model lives as long as the app; a newer search cancels this one.
        searchTask = Task { @MainActor [self] in
            for project in targets {
                if Task.isCancelled { return }
                let remaining = Self.limit - allHits.count
                if remaining <= 0 { break }
                let projectID = project.id
                // git grep streams results; each batch hops to the main thread and is appended immediately.
                try? await Git.grep(pattern, options: options, in: project.url, limit: remaining) { batch in
                    let converted = batch.map { hit -> (GrepHit, Range<Int>?) in (hit, highlighter(hit.text, hit.column)) }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard self.generation == token else { return }
                            self.append(converted, projectID: projectID)
                        }
                    }
                }
            }
            // Let the last batch land before declaring the search finished.
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard generation == token, !Task.isCancelled else { return }
            isSearching = false
            truncated = allHits.count >= Self.limit
            if hits.isEmpty { setPreview(nil) }
        }
    }

    /// Populates raw hits directly for unit testing filtering and selection behavior.
    func setHitsForTesting(_ rawHits: [Hit]) {
        allHits = rawHits.enumerated().map { idx, hit in
            Hit(id: idx, projectID: hit.projectID, path: hit.path, line: hit.line, text: hit.text, match: hit.match)
        }
        totalHitCount = allHits.count
        selected = 0
        rebuildFilteredHits()
    }

    /// Adds a batch of results as it arrives.
    private func append(_ batch: [(GrepHit, Range<Int>?)], projectID: UUID) {
        let first = hits.isEmpty
        let filter = fileFilter
        for (hit, match) in batch {
            let trimmed = Self.trimLeading(hit.text, match: match)
            let item = Hit(id: allHits.count, projectID: projectID, path: hit.path, line: hit.line,
                           text: trimmed.text, match: trimmed.match)
            allHits.append(item)
            if filter.matches(path: item.path) {
                hits.append(item)
                searchFiles.insert(projectID.uuidString + item.path)
            }
        }
        totalHitCount = allHits.count
        fileCount = searchFiles.count
        if first, !hits.isEmpty { loadPreview() }
    }

    private func persistAndRefilter() {
        fileFilter.save(scope: .findInPath, defaults: defaults)
        rebuildFilteredHits()
    }

    private func rebuildFilteredHits() {
        let previousID = (selected >= 0 && selected < hits.count) ? hits[selected].id : nil
        let filter = fileFilter
        let filtered = allHits.filter { filter.matches(path: $0.path) }
        hits = filtered

        var files: Set<String> = []
        for hit in filtered {
            files.insert(hit.projectID.uuidString + hit.path)
        }
        searchFiles = files
        fileCount = files.count

        if let previousID, let idx = filtered.firstIndex(where: { $0.id == previousID }) {
            selected = idx
        } else {
            selected = 0
        }

        if filtered.isEmpty {
            setPreview(nil)
        } else {
            loadPreview()
        }
    }

    /// Finds the match on a result line so it can be emphasised. Runs on the thread reading git's output.
    private static func matcher(pattern: String, options: GrepOptions) -> @Sendable (String, Int) -> Range<Int>? {
        var regexOptions: NSRegularExpression.Options = options.caseSensitive ? [] : [.caseInsensitive]
        var source = pattern
        if !options.regex {
            regexOptions.insert(.ignoreMetacharacters)
        }
        if options.wholeWord {
            source = "\\b" + (options.regex ? "(?:\(pattern))" : NSRegularExpression.escapedPattern(for: pattern)) + "\\b"
            regexOptions.remove(.ignoreMetacharacters)
        }
        let regex = try? NSRegularExpression(pattern: source, options: regexOptions)
        return { text, _ in
            guard let regex else { return nil }
            let ns = text as NSString
            let found = regex.rangeOfFirstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            guard found.location != NSNotFound, found.length > 0 else { return nil }
            return found.location..<(found.location + found.length)
        }
    }

    /// Drops indentation so matches line up in the result list.
    private static func trimLeading(_ text: String, match: Range<Int>?) -> (text: String, match: Range<Int>?) {
        let ns = text as NSString
        var skip = 0
        while skip < ns.length, ns.character(at: skip) == 32 || ns.character(at: skip) == 9 { skip += 1 }
        if let match, match.lowerBound < skip { skip = match.lowerBound }
        // Keep long lines readable by starting shortly before the match.
        if let match, match.lowerBound - skip > 60 { skip = match.lowerBound - 40 }
        guard skip > 0 else { return (text, match) }
        let trimmed = ns.substring(from: skip)
        return (trimmed, match.map { ($0.lowerBound - skip)..<($0.upperBound - skip) })
    }

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selected = min(hits.count - 1, max(0, selected + delta))
        loadPreview()
    }

    func select(_ index: Int) {
        guard index >= 0, index < hits.count else { return }
        selected = index
        loadPreview()
    }

    func activate() {
        guard let store, selected >= 0, selected < hits.count else { return }
        let hit = hits[selected]
        guard let project = store.project(hit.projectID) else { return }
        store.dismissPopup(restoreFocus: false)
        store.openFile(in: project, path: hit.path, line: hit.line)
        store.viewer.focusCanvas()
    }

    func attachPreview(_ container: CodeScrollContainer) {
        previewContainer = container
        container.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
        container.show(previewDocument, mode: .single, preserveScroll: false)
        positionPreview()
    }

    func applyCodeFont() {
        previewContainer?.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
    }

    private func setPreview(_ doc: DiffDocument?) {
        previewDocument = doc
        if doc == nil { previewPath = ""; previewKey = "" }
        previewContainer?.show(doc, mode: .single, preserveScroll: false)
    }

    private func positionPreview() {
        guard let container = previewContainer, selected < hits.count, let doc = previewDocument, case .text = doc.content else { return }
        let hit = hits[selected]
        let line = max(0, min(hit.line - 1, doc.right.lines.count - 1))
        container.whenLaidOut { [weak container] in
            guard let container else { return }
            container.canvas.focusLine = (.right, line)
            container.scroll(toRow: line, fraction: 0.4, animated: false)
        }
        // Emphasise every occurrence in the preview using the same matcher as the result list.
        let highlighter = Self.matcher(pattern: query, options: options)
        var ranges: [Int: [Range<Int>]] = [:]
        let window = max(0, line - 200)...min(doc.right.lines.count - 1, line + 200)
        for index in window {
            if let range = highlighter(doc.right.lines[index], 0) { ranges[index] = [range] }
        }
        container.canvas.setHighlightedRanges([[:], ranges], navigation: [], current: -1)
    }

    func loadPreview() {
        guard let store, selected >= 0, selected < hits.count else { return }
        let hit = hits[selected]
        guard let project = store.project(hit.projectID) else { return }
        let key = hit.projectID.uuidString + hit.path
        previewPath = (store.projects.count > 1 && allProjects ? project.name + " › " : "") + hit.path
        if key == previewKey, previewDocument != nil {
            positionPreview()
            return
        }
        previewTask?.cancel()
        let request = DiffRequest(root: project.url, path: hit.path, oldPath: nil, kind: nil, source: .file)
        previewTask = Task { @MainActor [weak self] in
            let doc = await DiffLoader.load(request)
            guard let self, !Task.isCancelled else { return }
            self.previewKey = key
            self.previewDocument = doc
            self.previewContainer?.show(doc, mode: .single, preserveScroll: false)
            self.positionPreview()
        }
    }
}
