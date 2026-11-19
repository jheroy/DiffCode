import SwiftUI

/// Left column: the projects, and under them the file tree of the one that is selected.
struct SidebarView: View {
    @Environment(AppStore.self) private var store
    /// The projects' height when a drag of the divider under them began.
    @State private var dragStart: CGFloat?
    @State private var topChromeHeight: CGFloat = 60
    @State private var footerHeight: CGFloat = 35

    var body: some View {
        GeometryReader { proxy in
            if let project = store.currentProject, !project.needsAccess, !store.gitMissing {
                let room = max(0, proxy.size.height - topChromeHeight - footerHeight)
                // The projects take the room they need, up to about a third; once the divider has been
                // dragged, exactly that much, blank space and all. The tree keeps at least its bar.
                let height = Self.projectsHeight(count: store.projectRows.count,
                                                 available: proxy.size.height,
                                                 chosen: store.settings.projectsHeight,
                                                 room: room,
                                                 dividerHeight: IslandStyle.gap)
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        projectsHeader
                            .background(heightReader { value in
                                if abs(topChromeHeight - value) > 0.5 { topChromeHeight = value }
                            })
                        projects.frame(height: height)
                    }
                    .islandCard(background: .difSidebar)

                    DividerGrip(axis: .rows, islandGap: true, onDrag: { translation in
                        guard let translation else {
                            dragStart = nil
                            store.settings.save()
                            return
                        }
                        let start = dragStart ?? height
                        if dragStart == nil { dragStart = height }
                        store.settings.projectsHeight = Self.clampedChoice(start + translation, room: room, dividerHeight: IslandStyle.gap)
                    }, onDoubleClick: {
                        // Back to the height that follows the number of projects.
                        store.settings.projectsHeight = nil
                        store.settings.save()
                    })

                    VStack(spacing: 0) {
                        FileTreePanel(project: project)
                            .id(project.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        sidebarFooter
                            .background(heightReader { value in
                                if abs(footerHeight - value) > 0.5 { footerHeight = value }
                            })
                    }
                    .islandCard(background: .difSidebar)
                }
            } else {
                VStack(spacing: 0) {
                    projectsHeader
                    projects
                    sidebarFooter
                }
                .islandCard(background: .difSidebar)
            }
        }
    }

    private var projectsHeader: some View {
        VStack(spacing: 0) {
            // Clear space for the traffic lights (offset by the outer island frame padding); still draggable.
            WindowDragArea().frame(height: store.isFullScreen ? 10 : max(26, store.titlebarHeight - IslandStyle.outerPadding))

            HStack {
                SectionLabel(text: L("Projects", "项目"))
                Spacer()
                IconButton(symbol: "plus", help: L("Add Project (⌘N)", "添加项目 (⌘N)"), size: 12) { store.presentAddProject() }
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.bottom, 4)
        }
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.5)
            SidebarFooter()
        }
    }

    private func heightReader(_ onChange: @escaping (CGFloat) -> Void) -> some View {
        GeometryReader { geo in
            Color.clear.onChange(of: geo.size.height, initial: true) { _, value in
                onChange(value)
            }
        }
    }

    private var projects: some View {
        ScrollView {
            LazyVStack(spacing: Self.rowSpacing) {
                let rows = store.projectRows
                // Room for the arrows only when something can be folded, so a plain list looks as it always did.
                let nested = rows.contains { $0.hasChildren || $0.depth > 0 }
                ForEach(rows.map { ProjectRowItem(project: store.projects[$0.index], row: $0) }) { item in
                    let (project, row) = (item.project, item.row)
                    ProjectRow(project: project, isSelected: project.id == store.selectedProjectID,
                               depth: row.depth, hasChildren: row.hasChildren, nested: nested,
                               parent: row.parent.map { store.projects[$0] })
                        .frame(height: Self.rowHeight)
                        .id(project.id)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, Self.bottomPadding)
        }
    }

    static var rowHeight: CGFloat { UI.s(40) }
    private static let rowSpacing: CGFloat = 2
    private static let bottomPadding: CGFloat = 6

    /// The file tree's least: its filter bar and the project's name under it, so it can be put nearly out of the
    /// way and still be found.
    static var treeMinimum: CGFloat { UI.s(56) }

    /// What a drag of the divider may ask for: a row and a half at least, and room left for the tree's bar.
    static func clampedChoice(_ height: CGFloat, room: CGFloat, dividerHeight: CGFloat = 1) -> Double {
        let step = rowHeight + rowSpacing
        return Double(max(step * 1.5, min(height, room - dividerHeight - treeMinimum)).rounded())
    }

    /// Every project when they fit; otherwise a cut that leaves half a row showing, so the list reads as scrollable.
    /// A height the user dragged to (`chosen`) is kept as it is, even where it leaves room below the projects: that
    /// room takes folders dropped to add them. `room` is what the projects, the divider and the tree share.
    static func projectsHeight(count: Int, available: CGFloat, chosen: Double? = nil, room: CGFloat = .infinity, dividerHeight: CGFloat = 1) -> CGFloat {
        let step = rowHeight + rowSpacing
        let all = CGFloat(max(1, count)) * step - rowSpacing + bottomPadding
        if let chosen {
            return CGFloat(clampedChoice(CGFloat(chosen), room: room, dividerHeight: dividerHeight))
        }
        let limit = max(step * 2.5, min(step * 6.5, available * 0.34))
        return max(0, min(room - dividerHeight - treeMinimum, all <= limit ? all : ((limit / step - 0.5).rounded(.down) + 0.5) * step))
    }
}

/// The branch under a project's name. A click opens that project's branches and commit graph just below it.
private struct BranchLabel: View {
    let project: Project
    @Environment(AppStore.self) private var store
    @State private var hovering = false
    @State private var frame: CGRect = .zero

    var body: some View {
        let open = store.popup == .gitGraph && store.gitGraph.projectID == project.id
        let lit = hovering || open
        Button {
            store.toggleGitGraph(for: project, anchor: CGPoint(x: frame.minX, y: frame.maxY + 4))
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.triangle.branch").font(.ui(size: 9, weight: .semibold))
                Text(project.branchLabel).font(.ui(size: 11)).lineLimit(1).truncationMode(.middle)
                if let activity = project.activity {
                    // A checkout, fetch, pull or push at work.
                    ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: UI.s(10), height: UI.s(10))
                        .help(activity)
                } else {
                    // Commits not yet pushed, and not yet pulled.
                    if project.status.ahead > 0 { Text("↑\(project.status.ahead)").font(.ui(size: 10.5, weight: .medium)).fixedSize() }
                    if project.status.behind > 0 { Text("↓\(project.status.behind)").font(.ui(size: 10.5, weight: .medium)).fixedSize() }
                }
                if let operation = project.status.operation {
                    Text(operation.title).font(.ui(size: 10.5, weight: .medium)).foregroundStyle(Color.orange).lineLimit(1).fixedSize()
                }
                // Always laid out, so nothing moves when it appears.
                Image(systemName: "chevron.down").font(.ui(size: 7, weight: .bold)).opacity(lit ? 1 : 0)
            }
            .foregroundStyle(lit ? Color.difText : Color.difText2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(lit ? Color.difText.opacity(0.1) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The text stays in line with the project name; only the highlight reaches past it.
        .padding(.horizontal, -4)
        .onHover { hovering = $0 }
        .help(help)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { remember(proxy.frame(in: .global)) }
                .onChange(of: proxy.frame(in: .global)) { _, value in remember(value) }
        })
    }

    private var help: String {
        let tracking = project.status.upstream.map { L("Tracking \($0)", "跟踪 \($0)") }
        let action = L("Branches and commit graph (⌥⌘B)", "分支与提交树 (⌥⌘B)")
        return [tracking, action].compactMap { $0 }.joined(separator: "\n")
    }

    private func remember(_ value: CGRect) {
        frame = value
        store.branchLabelFrames[project.id] = value
    }
}

/// A row of the projects' tree, known by its project whatever its place.
private struct ProjectRowItem: Identifiable {
    let project: Project
    let row: ProjectTree.Row
    var id: UUID { project.id }
}

private struct ProjectRow: View {
    let project: Project
    var isSelected: Bool
    var depth = 0
    var hasChildren = false
    /// Whether any project is inside another: then every row leaves room for the arrow.
    var nested = false
    var parent: Project?
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    /// Under its parent a repository goes by its path from there ("services/core"); a work tree by its folder's
    /// name, wherever that folder is.
    private var title: String {
        guard let parent, project.worktreeOf == nil, project.url.path.hasPrefix(parent.url.path + "/") else { return project.name }
        return String(project.url.path.dropFirst(parent.url.path.count + 1))
    }

    var body: some View {
        let collapsed = store.collapsedProjects.contains(project.url.path)
        let changes = project.changes.count + store.hiddenChanges(under: project)
        HStack(spacing: 9) {
            if nested {
                Group {
                    if hasChildren {
                        Button { store.toggleCollapsed(project) } label: {
                            Image(systemName: "chevron.right")
                                .font(.ui(size: 9, weight: .semibold))
                                .rotationEffect(.degrees(collapsed ? 0 : 90))
                                .foregroundStyle(Color.difText3)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(collapsed ? L("Expand", "展开") : L("Collapse", "折叠"))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: UI.s(12))
                .padding(.leading, CGFloat(depth) * UI.s(14) - 3)
                .padding(.trailing, -5)
            }
            if project.worktreeOf != nil {
                // A work tree of the repository above, not a repository of its own: a quiet mark, no monogram.
                RoundedRectangle(cornerRadius: UI.s(24) * 0.28, style: .continuous)
                    .fill(Color.difChip)
                    .frame(width: UI.s(24), height: UI.s(24))
                    .overlay(Image(systemName: "square.on.square").font(.ui(size: 11, weight: .medium)).foregroundStyle(Color.difText2))
            } else {
                ProjectAvatar(name: project.name)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.ui(size: 13, weight: .medium))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                BranchLabel(project: project)
            }
            Spacer(minLength: 4)
            if hovering, !project.needsAccess, !store.gitMissing {
                RowRemoteActions(project: project)
            }
            if store.terminals.hasSessions(project) {
                // A terminal is open here; orange once it rings for attention (an agent waiting on you).
                let waiting = store.terminals.needsAttention(project)
                Image(systemName: waiting ? "terminal.fill" : "terminal")
                    .font(.ui(size: 10, weight: .medium))
                    .foregroundStyle(waiting ? Color.orange : Color.difText3)
                    .help(waiting ? L("A terminal here wants attention", "这里有终端在等你") : L("Has open terminals", "有打开的终端"))
            }
            if project.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.ui(size: 11))
                    .foregroundStyle(.orange)
                    .help(project.errorMessage ?? "")
            } else if changes > 0 {
                Text("\(changes)")
                    .font(.ui(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : Color.difText2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(isSelected ? Color.difAccent : Color.difChip))
            }
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.difSelection : (hovering ? Color.difHover : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { store.select(project) }
        .onHover { hovering = $0 }
        .help(collapsed && changes > project.changes.count
              ? project.url.path + "\n" + L("\(changes - project.changes.count) changes folded away under it",
                                             "折叠起来的项目里有 \(changes - project.changes.count) 处改动")
              : (project.worktreeOf != nil ? L("Work tree", "工作树") + " · " + project.url.path : project.url.path))
        .contextMenu {
            if !project.needsAccess, !store.gitMissing {
                Button(L("New Branch…", "新建分支…")) { store.newBranch(in: project) }
                Button(L("New Worktree…", "新建工作树…")) { store.presentNewWorktree(for: project) }
                Divider()
            }
            Button(L("Reveal in Finder", "在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
            Button(L("Copy Path", "复制路径")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.url.path, forType: .string)
            }
            Button(L("Refresh", "刷新")) { store.refreshAndDiscover(project) }
            Divider()
            if hasChildren {
                Button(collapsed ? L("Expand", "展开") : L("Collapse", "折叠")) { store.toggleCollapsed(project) }
            }
            // A work tree git lists follows git: nothing to order or to remove here.
            if !project.isDerived {
                Button(L("Move Up", "上移")) { store.move(project, by: -1) }.disabled(!store.canMove(project, by: -1))
                Button(L("Move Down", "下移")) { store.move(project, by: 1) }.disabled(!store.canMove(project, by: 1))
                Divider()
            }
            if project.worktreeOf != nil, !project.needsAccess, !store.gitMissing {
                Button(L("Delete Worktree…", "删除工作树（移除磁盘目录）…"), role: .destructive) {
                    store.confirmDeleteWorktree(project)
                }
            }
            if !project.isDerived {
                Button(L("Remove from \(appName)", "从 \(appName) 中移除"), role: .destructive) { store.remove(project) }
            }
        }
    }
}

/// Compact Pull / Push buttons shown on hover in a project or work tree sidebar row.
private struct RowRemoteActions: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            if let activity = project.activity {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: UI.s(18), height: UI.s(18))
                    .help(activity)
            } else {
                RowActionButton(symbol: "arrow.down", help: pullHelp, highlighted: project.status.behind > 0) {
                    store.pull(in: project)
                }
                RowActionButton(symbol: "arrow.up", help: pushHelp, highlighted: project.status.ahead > 0) {
                    store.push(in: project)
                }
            }
        }
    }

    private var pullHelp: String {
        let behind = project.status.behind
        if let upstream = project.status.upstream {
            return behind > 0
                ? L("Pull \(behind) \(behind == 1 ? "commit" : "commits") from \(upstream)", "从 \(upstream) 拉取 \(behind) 个提交")
                : L("Pull from \(upstream)", "从 \(upstream) 拉取")
        }
        return behind > 0 ? L("Pull (\(behind) behind)", "拉取（落后 \(behind) 个提交）") : L("Pull", "拉取")
    }

    private var pushHelp: String {
        let ahead = project.status.ahead
        if let upstream = project.status.upstream {
            return ahead > 0
                ? L("Push \(ahead) \(ahead == 1 ? "commit" : "commits") to \(upstream)", "推送 \(ahead) 个提交到 \(upstream)")
                : L("Push to \(upstream)", "推送到 \(upstream)")
        }
        return ahead > 0 ? L("Push (\(ahead) ahead)", "推送（领先 \(ahead) 个提交）") : L("Push", "推送")
    }
}

private struct RowActionButton: View {
    var symbol: String
    var help: String
    var highlighted = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: 10.5, weight: .semibold))
                .foregroundStyle(highlighted ? Color.difAccent : (hovering ? Color.difText : Color.difText2))
                .frame(width: UI.s(20), height: UI.s(20))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Color.difText.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A coloured monogram so projects are recognisable at a glance.
struct ProjectAvatar: View {
    var name: String
    var size: CGFloat = 24

    private static let gradients: [(UInt32, UInt32)] = [
        (0x5B8DEF, 0x3A5FD9), (0x34C8A0, 0x1E9E84), (0xF2994A, 0xE5683B), (0xB57BEE, 0x8B55D6),
        (0xEF6F8E, 0xD9456E), (0x4FC3E8, 0x2D95D1), (0xE6B93D, 0xD9952A), (0x7ED06F, 0x4DAE4E),
    ]

    var body: some View {
        // A stable hash: `hashValue` is reseeded on every launch, which would reshuffle the colours.
        let seed = name.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
        let pair = Self.gradients[abs(seed) % Self.gradients.count]
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: [Color(NSColor(hex: pair.0)), Color(NSColor(hex: pair.1))],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: UI.s(size), height: UI.s(size))
            .overlay(
                Text(String(name.first ?? "?").uppercased())
                    .font(.ui(size: size * 0.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

private struct SidebarFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            // The whole point of Dif is being light; keep the number honest and visible.
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill").font(.ui(size: 9))
                Text(String(format: "%.0f MB", store.memoryMB)).font(.ui(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Color.difText3)
            .help(L("Memory used by \(appName) right now", "\(appName) 当前占用的内存"))
            Spacer()
            IconButton(symbol: "keyboard", help: L("Keymap Reference (⌘/)", "快捷键一览 (⌘/)"), size: 12) { store.present(.keymap) }
            IconButton(symbol: "gearshape", help: L("Settings (⌘,)", "设置 (⌘,)"), size: 12) { store.present(.settings) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: UI.s(34))
    }
}

/// Shown when there are no projects yet.
struct WelcomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            // The app's own icon; its tile fills about 80% of the image (Apple's grid), so it shows at about 54 pt.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: UI.s(68), height: UI.s(68))
            VStack(spacing: 6) {
                Text(L("Welcome to \(appName)", "欢迎使用 \(appName)"))
                    .font(.ui(size: 22, weight: .semibold))
                    .foregroundStyle(Color.difText)
                Text(L("A featherweight viewer for Git changes.", "一个极轻量的 Git 变更查看器。"))
                    .font(.ui(size: 13))
                    .foregroundStyle(Color.difText2)
            }
            Button {
                store.presentAddProject()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                    Text(L("Add a Git Repository", "添加 Git 仓库"))
                    KeyCaps(shortcut: "⌘N")
                }
                .font(.ui(size: 13, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.difSelection))
                .foregroundStyle(Color.difText)
            }
            .buttonStyle(.plain)
            Text(L("…or drop folders anywhere in this window", "…或者把文件夹拖进这个窗口"))
                .font(.ui(size: 12))
                .foregroundStyle(Color.difText3)
            if FolderAccess.shared.isNeeded {
                // The sandbox asks once per folder chosen; the folder of all the repositories asks once for all of them.
                Text(L("Tip: choose the folder that holds all your repositories. \(appName) finds every one in it, and you grant access only once.",
                       "提示：直接选存放所有仓库的文件夹，\(appName) 会找出其中的每个仓库，只需授权一次。"))
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
    }
}
