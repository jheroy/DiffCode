import AppKit
import Observation
import SwiftUI

/// The Git graph dropdown: the repository's branches and tags, and the commit graph of whichever is picked.
///
/// Loaded when the dropdown opens and dropped when another project's is opened, so nothing is kept
/// around for a dropdown that is closed.
@MainActor
@Observable
final class GitGraphModel {
    enum Scope: Hashable {
        case all
        /// HEAD, for a detached checkout that no branch row stands for.
        case head
        /// A full ref name.
        case ref(String)
    }

    struct BranchRow: Identifiable, Equatable {
        enum Kind: Equatable {
            case section(key: String, title: String, count: Int, expanded: Bool)
            case scope(Scope, title: String, symbol: String)
            case ref(GitRef)
        }

        var id: String
        var kind: Kind

        var isSelectable: Bool {
            if case .section = kind { return false }
            return true
        }
    }

    static let pageSize = 400
    /// The most commits the dropdown loads. Each row shown stays in memory while it is open (about 25 KB, so
    /// thousands of rows cost tens of megabytes); the Log, with its search, is the place for older history.
    static let maxCommits = 1200
    /// The graph column never grows wider than this many lanes; lines beyond it are cut off.
    static let maxLanes = 12

    @ObservationIgnored weak var store: AppStore?

    private(set) var projectID: UUID?
    var scope: Scope = .all
    /// Whether "All branches" also walks non-standard internal refs (`refs/t3/*`, `refs/notes/*`, `refs/stash`).
    var showInternalRefs = false
    var refs: [GitRef] = []
    var rows: [GraphRow] = []
    /// Lanes the graph column is sized for.
    var laneCount = 1
    var hasMore = false
    /// There is more history than `maxCommits`, and the dropdown stops there.
    var isCapped = false
    var isLoading = false
    var errorText: String?
    var selectedCommitID: String?
    /// Every selected commit (⌘-click), for comparing two. Includes `selectedCommitID`.
    var selectedCommitIDs: Set<String> = []
    var selectedBranchID: String? = "scope:all"
    var branchFilter = ""
    var collapsedSections: Set<String> = ["tags"]
    var graphFocusToken = 2_000_000
    var branchFocusToken = 3_000_000

    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var commits: [Commit] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var refsTask: Task<Void, Never>?

    /// Called as the dropdown opens: reloads, since commits and branches may have moved since last time.
    func prepare(for project: Project) {
        if projectID != project.id {
            projectID = project.id
            root = project.url
            scope = .all
            showInternalRefs = false
            selectedBranchID = "scope:all"
            selectedCommitID = nil
            branchFilter = ""
            refs = []
            rows = []
            commits = []
        }
        reloadRefs()
        load(reset: true)
        focusGraph()
    }

    /// Reads the branches and the graph again, keeping what is picked (after a checkout, a fetch or a push).
    func reload() {
        reloadRefs()
        load(reset: true)
    }

    /// Lets go of everything loaded; the dropdown is closed.
    func release() {
        task?.cancel()
        refsTask?.cancel()
        commits = []
        rows = []
        isLoading = false
    }

    func focusGraph() {
        graphFocusToken += 1
        KeyCatcher.pending = (graphFocusToken, CACurrentMediaTime())
    }

    func focusBranches() {
        branchFocusToken += 1
        KeyCatcher.pending = (branchFocusToken, CACurrentMediaTime())
    }

    func pick(_ row: BranchRow) {
        switch row.kind {
        case .section(let key, _, _, _):
            if collapsedSections.contains(key) { collapsedSections.remove(key) } else { collapsedSections.insert(key) }
        case .scope(let scope, _, _):
            setScope(scope, branchID: row.id)
        case .ref(let ref):
            setScope(.ref(ref.name), branchID: row.id)
        }
    }

    private func setScope(_ scope: Scope, branchID: String) {
        selectedBranchID = branchID
        guard scope != self.scope else { return }
        self.scope = scope
        selectedCommitID = nil
        load(reset: true)
    }

    var scopeTitle: String {
        switch scope {
        case .all: return L("All branches", "全部分支")
        case .head: return "HEAD"
        case .ref(let name): return refs.first { $0.name == name }?.shortName ?? name
        }
    }

    // MARK: Loading

    private func reloadRefs() {
        guard let root else { return }
        refsTask?.cancel()
        refsTask = Task { @MainActor [weak self] in
            let refs = (try? await Git.refs(in: root)) ?? []
            guard let self, !Task.isCancelled else { return }
            if refs != self.refs { self.refs = refs }
        }
    }

    /// Toggles whether internal Git refs (e.g. `refs/t3/*`, `refs/stash`) appear in "All branches" and reloads.
    func toggleInternalRefs() {
        showInternalRefs.toggle()
        if scope == .all {
            load(reset: true)
        }
    }

    func load(reset: Bool) {
        guard let root else { return }
        if isLoading, !reset { return }
        task?.cancel()
        isLoading = true
        let skip = reset ? 0 : commits.count
        let scope = self.scope
        let includeInternalRefs = self.showInternalRefs
        task = Task { @MainActor [weak self] in
            var page: [Commit] = []
            var failure: String?
            do {
                switch scope {
                case .all:
                    page = try await Git.log(in: root, skip: skip, limit: Self.pageSize, query: "",
                                             allBranches: true, includeInternalRefs: includeInternalRefs)
                case .head: page = try await Git.log(in: root, skip: skip, limit: Self.pageSize, query: "", allBranches: false)
                case .ref(let name): page = try await Git.log(in: root, skip: skip, limit: Self.pageSize, query: "", allBranches: false, ref: name)
                }
            } catch {
                failure = error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            if reset {
                self.commits = page
            } else {
                let known = Set(self.commits.map(\.hash))
                self.commits += page.filter { !known.contains($0.hash) }
            }
            self.rows = CommitGraph.layout(self.commits)
            self.laneCount = min(Self.maxLanes, max(1, self.rows.lazy.map(\.width).max() ?? 1))
            let full = page.count >= Self.pageSize
            self.hasMore = full && self.commits.count < Self.maxCommits
            self.isCapped = full && !self.hasMore
            self.errorText = failure
            self.isLoading = false
            if self.selectedCommitID == nil || !self.rows.contains(where: { $0.id == self.selectedCommitID }) {
                self.selectedCommitID = self.initialSelection()
            }
        }
    }

    /// The picked branch's tip, or the commit HEAD is on.
    private func initialSelection() -> String? {
        if case .ref(let name) = scope, let target = refs.first(where: { $0.name == name })?.target,
           rows.contains(where: { $0.id == target }) {
            return target
        }
        let head = rows.first { row in row.commit.refs.contains { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") } }
        return (head ?? rows.first)?.id
    }

    /// A row's right-click menu. Picks the row, as a right-click does in the IDE.
    func contextMenu(for row: GraphRow) -> NSMenu {
        let menu = NSMenu()
        if selectedCommitIDs.contains(row.id), let pair = store?.pickedPair(selectedCommitIDs, in: rows.map(\.commit)) {
            menu.addItem(ClosureMenuItem(L("Compare \(pair.older.shortHash) with \(pair.newer.shortHash)",
                                           "比较 \(pair.older.shortHash) 与 \(pair.newer.shortHash)")) { [weak self] in
                self?.store?.compareCommits(pair.older, pair.newer)
            })
            menu.addItem(.separator())
        } else {
            selectedCommitID = row.id
        }
        menu.addItem(ClosureMenuItem(L("Show in Log", "在历史中查看")) { [weak self] in self?.store?.showCommitInLog(row.id) })
        menu.addItem(ClosureMenuItem(L("Compare with Working Tree", "与工作区比较")) { [weak self] in
            self?.store?.compare(with: row.commit.hash, title: row.commit.shortHash, forkPoint: false)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("New Branch Here…", "在此新建分支…")) { [weak self] in
            self?.store?.newBranch(from: row.commit.hash, startTitle: row.commit.shortHash)
        })
        menu.addItem(ClosureMenuItem(L("Checkout Revision…", "检出此版本…")) { [weak self] in
            self?.store?.checkoutRevision(row.commit.hash, title: row.commit.shortHash)
        })
        menu.addItem(.separator())
        if let store, let project = projectID.flatMap({ store.project($0) }) {
            let list = rows.map(\.commit)
            store.addHistoryEditItems(to: menu, commit: row.commit, commits: store.menuCommits(row.commit, picked: selectedCommitIDs, in: list),
                                      list: list, project: project)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(L("Copy Hash", "复制哈希")) { [weak self] in self?.copy(row.commit.hash) })
        menu.addItem(ClosureMenuItem(L("Copy Message", "复制提交信息")) { [weak self] in self?.copy(row.commit.subject) })
        return menu
    }

    /// A branch's or tag's right-click menu: what changed since it, compared with the working tree.
    func branchMenu(for row: BranchRow) -> NSMenu? {
        guard case .ref(let ref) = row.kind else { return nil }
        let menu = NSMenu()
        if !(ref.kind == .local && ref.isHead) {
            let title = ref.kind == .tag ? L("Checkout Tag…", "检出标签…") : L("Checkout", "检出")
            menu.addItem(ClosureMenuItem(title) { [weak self] in self?.store?.checkout(ref) })
        }
        menu.addItem(ClosureMenuItem(L("New Branch from \(ref.shortName)…", "从 \(ref.shortName) 新建分支…")) { [weak self] in
            self?.store?.newBranch(from: ref.name, startTitle: ref.shortName)
        })
        menu.addItem(.separator())
        if ref.kind != .tag {
            menu.addItem(ClosureMenuItem(L("Show Changes Since Forking from \(ref.shortName)", "查看自与 \(ref.shortName) 分叉以来的变更")) { [weak self] in
                self?.store?.compare(with: ref.name, title: ref.shortName, forkPoint: true)
            })
        }
        menu.addItem(ClosureMenuItem(L("Compare with Working Tree", "与工作区比较")) { [weak self] in
            self?.store?.compare(with: ref.name, title: ref.shortName, forkPoint: false)
        })
        menu.addItem(.separator())
        if let store, let project = projectID.flatMap({ store.project($0) }) {
            store.addBranchEditItems(to: menu, ref: ref, project: project)
        }
        menu.addItem(ClosureMenuItem(L("Copy Name", "复制名称")) { [weak self] in self?.copy(ref.shortName) })
        return menu
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        store?.showToast(L("Copied", "已复制"))
    }

    // MARK: Branch list

    var branchRows: [BranchRow] {
        let needle = branchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let matching = needle.isEmpty ? refs : refs.filter { $0.shortName.lowercased().contains(needle) }
        var rows: [BranchRow] = [
            BranchRow(id: "scope:all", kind: .scope(.all, title: L("All branches", "全部分支"), symbol: "point.3.connected.trianglepath.dotted")),
        ]
        if !refs.isEmpty, !refs.contains(where: { $0.kind == .local && $0.isHead }) {
            rows.append(BranchRow(id: "scope:head", kind: .scope(.head, title: L("HEAD (detached)", "HEAD（游离）"), symbol: "smallcircle.filled.circle")))
        }
        let sections: [(String, String, GitRef.Kind)] = [
            ("local", L("Local", "本地分支"), .local),
            ("remote", L("Remote", "远程分支"), .remote),
            ("tags", L("Tags", "标签"), .tag),
        ]
        for (key, title, kind) in sections {
            var list = matching.filter { $0.kind == kind }
            guard !list.isEmpty else { continue }
            // The checked-out branch first; the rest stay newest first, as for-each-ref sorted them.
            if let head = list.firstIndex(where: \.isHead) { list.insert(list.remove(at: head), at: 0) }
            // While filtering, every section with a match is open.
            let expanded = !needle.isEmpty || !collapsedSections.contains(key)
            rows.append(BranchRow(id: "section:" + key, kind: .section(key: key, title: title, count: list.count, expanded: expanded)))
            if expanded {
                rows += list.map { BranchRow(id: "ref:" + $0.name, kind: .ref($0)) }
            }
        }
        return rows
    }
}

extension AppStore {
    /// ⌥⌘B: opens the current project's Git graph under its branch in the sidebar, or closes it.
    func toggleGitGraph() {
        if popup == .gitGraph {
            dismissPopup()
            return
        }
        guard let project = currentProject else { return }
        // With the sidebar hidden the dropdown takes the top left corner.
        let label = sidebarVisible ? branchLabelFrames[project.id] : nil
        openGitGraph(for: project, anchor: label.map { CGPoint(x: $0.minX, y: $0.maxY + 4) })
    }

    /// A click on a project's branch: opens that project's Git graph under it, picking the project, or closes it.
    func toggleGitGraph(for project: Project, anchor: CGPoint) {
        if popup == .gitGraph, gitGraph.projectID == project.id {
            dismissPopup()
            return
        }
        if selectedProjectID != project.id { select(project) }
        openGitGraph(for: project, anchor: anchor)
    }

    private func openGitGraph(for project: Project, anchor: CGPoint?) {
        gitGraphAnchor = anchor
        gitGraph.prepare(for: project)
        present(.gitGraph)
    }

    /// Shows a commit picked in the graph in the Log, with the same branches listed, and closes the graph.
    func showCommitInLog(_ hash: String) {
        guard let project = currentProject else { return }
        let index = gitGraph.rows.firstIndex { $0.id == hash } ?? 0
        switch gitGraph.scope {
        case .all:
            project.logAllBranches = true
            project.logRef = nil
        case .head:
            project.logAllBranches = false
            project.logRef = nil
        case .ref(let name):
            project.logAllBranches = false
            project.logRef = name
        }
        project.logQuery = ""
        dismissPopup(restoreFocus: false)
        if !listVisible { withAnimation(.snappy(duration: 0.2)) { listVisible = true } }
        project.browsedPath = nil
        project.tab = .log
        project.selectedCommitID = hash
        // Enough of the history in one go that the commit is in the list, however far down the graph it was.
        project.loadLog(reset: true, atLeast: index + 50) { [weak self, weak project] in
            guard let self, let project else { return }
            if project.commits.contains(where: { $0.hash == hash }) { project.selectedCommitID = hash }
            self.commitSelectionChanged(project)
        }
        focusList()
    }
}
