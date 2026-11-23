import SwiftUI

/// Which row sits at the top of the tree's viewport. Kept outside the panel's own state so that
/// scrolling re-renders the one-line path bar and nothing else.
@MainActor
@Observable
final class TreeScrollState {
    var topIndex = 0
}

/// The project's files as a tree, in the sidebar under the project list. Built to stay readable in a narrow column:
/// single-child directory chains share a row, indentation tightens as the tree gets deeper,
/// folders are a chevron and a name with no second icon, and a path bar says where the top row lives.
struct FileTreePanel: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store
    @State private var scroll = TreeScrollState()

    static let rowHeight: CGFloat = 22

    var body: some View {
        let _ = project.treeVersion
        let rows = project.treeRows()
        let filtering = isFiltering
        let indent = Self.indent(for: rows, width: store.settings.sidebarWidth)
        let guide = filtering ? nil : activeGuide(in: rows)
        let onScreen = store.viewer.request.flatMap { $0.root == project.url ? TreeRow.fileID($0.path) : nil }
        VStack(spacing: 0) {
            HStack(spacing: 1) {
                FilterField(text: $project.treeFilter, placeholder: L("Filter files", "筛选文件"), trailingPadding: 4)
                    .help(L("Filter files — or click in the tree and just type", "筛选文件 — 也可以点一下文件树后直接打字"))
                Group {
                    IconButton(symbol: "scope", help: L("Select Opened File (⌥F1)", "定位当前文件 (⌥F1)"),
                               isActive: store.settings.followFile, size: 12) { store.locateInTree() }
                        .contextMenu {
                            Toggle(L("Always Select Opened File", "始终定位打开的文件"), isOn: Binding(
                                get: { store.settings.followFile },
                                set: { store.settings.followFile = $0; store.settings.save() }))
                        }
                    IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: L("Collapse All", "全部折叠"), size: 11) {
                        project.treeExpanded.removeAll()
                    }
                }
                .padding(.top, 6) // level with the field, which sits lower in its own padding
            }
            .padding(.trailing, 6)
            if project.treeIndex == nil {
                Spacer()
                if project.isLoadingTree { ProgressView().controlSize(.small) }
                Spacer()
            } else if rows.isEmpty {
                EmptyListState(symbol: filtering ? "line.3.horizontal.decrease.circle" : "folder",
                               title: filtering ? L("No files match", "没有匹配的文件") : L("No files", "没有文件"), detail: "")
            } else {
                if !filtering {
                    TreePathBar(rows: rows, scroll: scroll, rootName: project.name) { row in
                        project.treeSelectedID = row.id
                        project.treeRevealToken += 1
                    }
                }
                // Rows the user picks open in the viewer; rows selected from code (locating a file) only move the highlight.
                KeyboardList(rows: rows,
                             selection: Binding(get: { project.treeSelectedID }, set: { id in
                                 project.treeSelectedID = id
                                 store.treeSelectionChanged(project)
                             }),
                             focusToken: store.treeFocusToken, name: KeyboardListName.tree,
                             rowHeight: Self.rowHeight,
                             onKey: { event, row in handleKey(event, row, rows) },
                             onClick: { row in if row.isDirectory { toggle(row) } },
                             onDoubleClick: { row in if !row.isDirectory { open(row) } },
                             revealToken: project.treeRevealToken,
                             onScroll: { offset in
                                 let index = max(0, Int((offset - 4) / UI.s(Self.rowHeight)))
                                 if scroll.topIndex != index { scroll.topIndex = index }
                             },
                             menu: { row in menu(row) },
                             dragURLs: { row in [project.url.appendingPathComponent(row.path)] }) { row, _, _ in
                    TreeRowView(row: row, indent: indent, filtering: filtering,
                                guideLevel: guide.flatMap { row.depth > $0.level && row.path.hasPrefix($0.prefix) ? $0.level : nil },
                                isFlashing: project.treeFlashID == row.id, isOnScreen: row.id == onScreen)
                }
            }
        }
        .onChange(of: project.treeFilter) { old, new in
            project.updateTreeFilter()
            // Leaving the filter: show the chosen file where it lives.
            if new.isEmpty, !old.isEmpty, let id = project.treeSelectedID, id.hasPrefix("f:") {
                project.revealInTree(String(id.dropFirst(2)), flash: false)
            }
        }
        .onAppear { project.loadTree() }
    }

    private var isFiltering: Bool {
        !project.treeFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Indentation per level. Deep trees get a tighter step, so names never get pushed out of a narrow panel.
    static func indent(for rows: [TreeRow], width: Double) -> CGFloat {
        let deepest = CGFloat(max(1, rows.reduce(0) { max($0, $1.depth) }))
        return min(UI.s(12), max(5, (CGFloat(width) * 0.3 / deepest).rounded(.down)))
    }

    /// The guide line to accent: the one that runs down from the selected row's parent.
    private func activeGuide(in rows: [TreeRow]) -> (level: Int, prefix: String)? {
        guard let id = project.treeSelectedID, let row = rows.first(where: { $0.id == id }), row.depth > 0 else { return nil }
        return (row.depth - 1, row.parentPath + "/")
    }

    /// Shows a file and hands it the keyboard. A row that a filter selected has not been opened yet.
    private func open(_ row: TreeRow) {
        project.treeSelectedID = row.id
        store.treeSelectionChanged(project)
        store.focusViewer()
    }

    private func toggle(_ row: TreeRow) {
        guard row.isDirectory else { return }
        if project.treeExpanded.contains(row.path) { project.treeExpanded.remove(row.path) } else { project.treeExpanded.insert(row.path) }
    }

    private func handleKey(_ event: NSEvent, _ row: TreeRow?, _ rows: [TreeRow]) -> Bool {
        let filtering = isFiltering
        switch event.keyCode {
        case 123: // ← close the folder, or step out to the one above
            guard let row, !filtering else { return true }
            if row.isDirectory, row.isExpanded {
                project.treeExpanded.remove(row.path)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }),
                      let parent = rows[..<index].last(where: { $0.depth < row.depth }) {
                project.treeSelectedID = parent.id
            }
            return true
        case 124: // → open the folder, or step into it
            guard let row, row.isDirectory, !filtering else { return true }
            if !row.isExpanded {
                project.treeExpanded.insert(row.path)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }), index + 1 < rows.count {
                project.treeSelectedID = rows[index + 1].id
            }
            return true
        case 36, 76: // ↩
            if let row, row.isDirectory { toggle(row) } else if let row { open(row) }
            return true
        case 53: // Esc
            guard !project.treeFilter.isEmpty else { return false }
            project.treeFilter = ""
            return true
        case 51: // ⌫ edits the filter while the tree keeps focus
            guard !project.treeFilter.isEmpty else { return false }
            project.treeFilter.removeLast()
            return true
        default:
            // Speed search, as in IntelliJ's trees: typing filters without leaving the list.
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            guard flags.isEmpty, let typed = event.characters, !typed.isEmpty,
                  typed.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-/".unicodeScalars.contains($0) }) else { return false }
            project.treeFilter += typed
            return true
        }
    }

    /// Built on the right-click, by the list's one AppKit view: a SwiftUI `.contextMenu` on every row kept some
    /// 20 KB alive for each row ever shown, and a big tree shows thousands.
    private func menu(_ row: TreeRow) -> NSMenu {
        let url = project.url.appendingPathComponent(row.path)
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) { menu.addItem(ClosureMenuItem(title, handler: action)) }
        if row.isDirectory {
            add(row.isExpanded ? L("Collapse", "折叠") : L("Expand", "展开")) { toggle(row) }
            add(L("Collapse All", "全部折叠")) { project.treeExpanded.removeAll() }
            menu.addItem(.separator())
            add(L("New Branch…", "新建分支…")) { store.newBranch(in: project) }
            if AppEnvironment.hasTerminal {
                add(L("Open Terminal Here", "在这里打开终端")) { store.terminals.open(in: project, directory: url) }
            }
        } else {
            add(L("Open", "打开")) { open(row) }
            if let change = row.change {
                add(L("Show Diff", "查看差异")) { store.showChangeDiff(change, in: project) }
            }
            if row.change?.kind != .untracked, row.change?.kind != .added {
                add(L("Show History", "查看历史")) { store.showHistory(path: row.path, in: project) }
            }
            if AppEnvironment.hasTerminal {
                add(L("Insert Path into Terminal", "把路径插入终端")) { store.terminals.insert(path: row.path, in: project) }
            }
            if let change = row.change {
                menu.addItem(.separator())
                if AppStore.canRollback(change) {
                    add(L("Rollback…", "回滚…")) { store.rollback([change], in: project) }
                }
                if AppStore.canDelete(change) {
                    add(L("Delete…", "删除…")) { store.delete([change], in: project) }
                }
            }
        }
        menu.addItem(.separator())
        add(L("Reveal in Finder", "在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        add(L("Copy Path", "复制路径")) { store.copyText(row.path) }
        return menu
    }
}

/// One line that names the folder the top of the list is inside, so a thinly indented tree never loses its place.
private struct TreePathBar: View {
    var rows: [TreeRow]
    var scroll: TreeScrollState
    var rootName: String
    var onSelect: (TreeRow) -> Void

    var body: some View {
        let enclosing = FileTree.enclosing(rows, at: min(scroll.topIndex, rows.count - 1)).last
        HStack(spacing: 5) {
            Image(systemName: enclosing == nil ? "shippingbox" : "folder")
                .font(.ui(size: 9.5, weight: .medium))
            Text(enclosing.map { $0.path.replacingOccurrences(of: "/", with: " › ") } ?? rootName)
                .font(.ui(size: 10.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.difText3)
        .padding(.horizontal, 12)
        .frame(height: UI.s(20))
        .contentShape(Rectangle())
        .onTapGesture { if let enclosing { onSelect(enclosing) } }
        .help(enclosing?.path ?? rootName)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.difHairline.opacity(0.7)).frame(height: 1) }
    }
}

private struct TreeRowView: View {
    var row: TreeRow
    var indent: CGFloat
    var filtering: Bool
    /// The depth of the guide line to draw in the accent colour, if this row is under the selection's parent.
    var guideLevel: Int?
    var isFlashing: Bool
    /// The file the viewer is showing, wherever the selection is.
    var isOnScreen = false

    private static let leading: CGFloat = 8

    var body: some View {
        HStack(spacing: 5) {
            if row.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.ui(size: 8.5, weight: .bold))
                    .foregroundStyle(Color.difText3)
                    .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                    .frame(width: UI.s(12), height: UI.s(16))
                directoryLabel
                Spacer(minLength: 4)
                if row.changedBelow > 0 {
                    Text("\(row.changedBelow)")
                        .font(.ui(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.status(.modified))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.status(.modified).opacity(0.14)))
                        .help(L("\(row.changedBelow) changed files inside", "里面有 \(row.changedBelow) 个文件有变更"))
                }
            } else {
                FileIcon(path: row.path, size: 11.5)
                    .frame(width: UI.s(12))
                Text(FuzzyHighlight.text(row.name, positions: row.positions, offset: row.path.utf8.count - row.name.utf8.count,
                                              base: Color.status(row.change?.kind), size: 12.5))
                    .font(.ui(size: 12.5, weight: isOnScreen ? .semibold : .regular))
                    .strikethrough(row.change?.kind == .deleted, color: Color.status(.deleted).opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if filtering {
                    let directory = (row.path as NSString).deletingLastPathComponent
                    if !directory.isEmpty {
                        Text(FuzzyHighlight.text(directory, positions: row.positions, offset: 0, base: Color.difText3, size: 11))
                            .font(.ui(size: 11))
                            .lineLimit(1)
                            // Keeps both ends: the module a file belongs to and the folder it sits in.
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                if let change = row.change {
                    Text(change.kind.letter)
                        .font(.ui(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.status(change.kind))
                        .frame(width: UI.s(12))
                }
            }
        }
        .padding(.leading, Self.leading + CGFloat(row.depth) * indent)
        .padding(.trailing, 12)
        .frame(maxHeight: .infinity)
        .background(alignment: .leading) {
            if row.depth > 0 {
                IndentGuides(depth: row.depth, indent: indent, origin: Self.leading + UI.s(12) / 2, active: guideLevel)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.difAccent.opacity(isFlashing ? 0.32 : 0))
                .padding(.horizontal, 6)
                .animation(.easeOut(duration: isFlashing ? 0.12 : 0.6), value: isFlashing)
        )
        .help(row.path)
    }

    /// "app/src/main" keeps its last folder at full strength and lets the rest recede.
    private var directoryLabel: some View {
        let parts = row.name.split(separator: "/", omittingEmptySubsequences: false)
        let lead = parts.count > 1 ? parts.dropLast().joined(separator: "/") + "/" : ""
        return (Text(lead).foregroundStyle(Color.difText3) + Text(String(parts.last ?? "")).foregroundStyle(Color.difText))
            .font(.ui(size: 12.5, weight: .medium))
            .lineLimit(1)
            .truncationMode(.head)
    }
}

/// Hairlines that run down from each open folder's chevron.
private struct IndentGuides: View {
    var depth: Int
    var indent: CGFloat
    var origin: CGFloat
    var active: Int?

    private struct Lines: Shape {
        var levels: [Int]
        var indent: CGFloat
        var origin: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path()
            for level in levels {
                let x = (origin + CGFloat(level) * indent).rounded() + 0.5
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            return path
        }
    }

    var body: some View {
        ZStack {
            Lines(levels: (0..<depth).filter { $0 != active }, indent: indent, origin: origin)
                .stroke(Color.difText3.opacity(0.28), lineWidth: 1)
            if let active, active < depth {
                Lines(levels: [active], indent: indent, origin: origin)
                    .stroke(Color.difAccent.opacity(0.8), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}
