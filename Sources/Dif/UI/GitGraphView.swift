import SwiftUI

/// Places the dropdown under the branch that opened it, inside the window, over everything else. A click outside closes it.
struct GitGraphLayer: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GeometryReader { proxy in
            let window = proxy.size
            let width = min(UI.s(940), window.width - 16)
            let anchor = store.gitGraphAnchor ?? CGPoint(x: store.sidebarVisible ? 12 : 78, y: store.titlebarHeight + 4)
            let top = min(anchor.y, window.height * 0.4)
            let height = min(UI.s(580), window.height - top - 12)
            let left = min(max(8, anchor.x), window.width - width - 8)
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.06)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissPopup() }
                GitGraphDropdown()
                    .frame(width: width, height: height)
                    .popupPanel(cornerRadius: 12)
                    .offset(x: left, y: top)
            }
        }
    }
}

struct GitGraphDropdown: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let model = store.gitGraph
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                BranchList(model: model)
                    .frame(width: UI.s(230))
                Rectangle().fill(Color.difHairline).frame(width: 1)
                CommitGraphList(model: model)
            }
            Rectangle().fill(Color.difHairline).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", L("Select", "选择"))
                hint("↩", L("Show in Log", "在历史中查看"))
                hint("⇥", L("Branches ⇄ commits", "分支 ⇄ 提交"))
                hint("Esc", L("Close", "关闭"))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small).scaleEffect(0.6) }
                Text(summary(model))
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                if model.scope == .all {
                    IconButton(symbol: model.showInternalRefs ? "eye" : "eye.slash",
                               help: model.showInternalRefs
                                   ? L("Hide internal refs (e.g. refs/t3/*, stash)", "隐藏内部引用（如 refs/t3/*、stash）")
                                   : L("Show internal refs (e.g. refs/t3/*, stash)", "显示内部引用（如 refs/t3/*、stash）"),
                               isActive: model.showInternalRefs,
                               size: 11.5) {
                        model.toggleInternalRefs()
                    }
                }
                if let project = store.currentProject, project.id == model.projectID {
                    RemoteButtons(project: project)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(34))
        }
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            KeyCaps(shortcut: keys, size: 10)
            Text(text).font(.ui(size: 11)).foregroundStyle(Color.difText3)
        }
    }

    private func summary(_ model: GitGraphModel) -> String {
        if model.isCapped {
            return L("\(model.scopeTitle) · latest \(model.rows.count) commits · older ones in the Log",
                     "\(model.scopeTitle) · 最近 \(model.rows.count) 个提交 · 更早的在「历史」里")
        }
        let count = model.hasMore ? "\(model.rows.count)+" : "\(model.rows.count)"
        return L("\(model.scopeTitle) · \(count) commits", "\(model.scopeTitle) · \(count) 个提交")
    }
}

/// Fetch, Pull and Push for the project whose graph is open; while one runs, what it is and a way to stop it.
private struct RemoteButtons: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            Rectangle().fill(Color.difHairline).frame(width: 1, height: UI.s(16)).padding(.horizontal, 4)
            if let activity = project.activity {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(activity).font(.ui(size: 11.5)).foregroundStyle(Color.difText2).lineLimit(1)
                if project.activityCancellable {
                    FooterButton(symbol: "xmark", title: L("Stop", "停止"), help: L("Stop it", "停止")) { store.cancelActivity(in: project) }
                }
            } else {
                FooterButton(symbol: "arrow.triangle.2.circlepath", title: L("Fetch", "获取"),
                             help: L("Fetch every remote’s branches", "获取所有远程的分支")) { store.fetch(in: project) }
                FooterButton(symbol: "arrow.down", title: project.status.behind > 0 ? L("Pull \(project.status.behind)", "拉取 \(project.status.behind)") : L("Pull", "拉取"),
                             help: L("Update the branch from its upstream", "从上游更新当前分支")) { store.pull(in: project) }
                FooterButton(symbol: "arrow.up", title: project.status.ahead > 0 ? L("Push \(project.status.ahead)", "推送 \(project.status.ahead)") : L("Push", "推送"),
                             help: L("Push the branch (⇧⌘K)", "推送当前分支 (⇧⌘K)")) {
                    store.dismissPopup(restoreFocus: false)
                    store.push(in: project)
                }
            }
        }
    }
}

private struct FooterButton: View {
    var symbol: String
    var title: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.ui(size: 10, weight: .semibold))
                Text(title).font(.ui(size: 11.5, weight: .medium))
            }
            .foregroundStyle(hovering ? Color.difText : Color.difText2)
            .padding(.horizontal, 7)
            .frame(height: UI.s(22))
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Color.difHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Branches

private struct BranchList: View {
    @Bindable var model: GitGraphModel

    var body: some View {
        let rows = model.branchRows
        VStack(spacing: 0) {
            FilterField(text: $model.branchFilter, placeholder: L("Filter branches", "筛选分支"))
            KeyboardList(rows: rows, selection: Binding(get: { model.selectedBranchID }, set: { id in
                             if let row = rows.first(where: { $0.id == id }) { model.pick(row) }
                         }),
                         focusToken: model.branchFocusToken, name: "branches", rowHeight: 26,
                         onKey: { event, _ in
                             switch event.keyCode {
                             case 48, 124: // ⇥ or →: over to the commits
                                 model.focusGraph()
                                 return true
                             default:
                                 return false
                             }
                         },
                         onClick: { row in if !row.isSelectable { model.pick(row) } },
                         canSelect: { $0.isSelectable },
                         menu: { row in model.branchMenu(for: row) }) { row, _, _ in
                BranchRowView(row: row, projectID: model.projectID)
            }
        }
    }
}

private struct BranchRowView: View {
    var row: GitGraphModel.BranchRow
    var projectID: UUID?
    @Environment(AppStore.self) private var store
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            switch row.kind {
            case .section(_, let title, let count, let expanded):
                Image(systemName: "chevron.right")
                    .font(.ui(size: 8, weight: .bold))
                    .foregroundStyle(Color.difText3)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: UI.s(12))
                Text(title.uppercased())
                    .font(.ui(size: 10.5, weight: .semibold))
                    .kerning(0.5)
                    .foregroundStyle(Color.difText3)
                Text("\(count)").font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                Spacer(minLength: 0)
            case .scope(_, let title, let symbol):
                Image(systemName: symbol)
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(16))
                Text(title).font(.ui(size: 12.5, weight: .medium)).foregroundStyle(Color.difText)
                Spacer(minLength: 0)
            case .ref(let ref):
                Spacer().frame(width: UI.s(10))
                Image(systemName: symbol(ref))
                    .font(.ui(size: 10.5, weight: ref.isHead ? .bold : .regular))
                    .foregroundStyle(ref.isHead ? Color.difAdded : Color.difText3)
                    .frame(width: UI.s(16))
                Text(ref.shortName)
                    .font(.ui(size: 12.5, weight: ref.isHead ? .semibold : .regular))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if ref.kind == .tag, hovering, let project = projectID.flatMap({ store.project($0) }) {
                    HStack(spacing: 2) {
                        TagRowActionButton(symbol: "pencil", help: L("Rename Tag…", "重命名标签…")) {
                            store.renameTag(ref, in: project)
                        }
                        TagRowActionButton(symbol: "trash", help: L("Delete Tag…", "删除标签…"), destructive: true) {
                            store.deleteTag(ref, in: project)
                        }
                    }
                } else {
                    if ref.ahead > 0 { Text("↑\(ref.ahead)").font(.ui(size: 10.5, weight: .medium)).foregroundStyle(Color.difText2) }
                    if ref.behind > 0 { Text("↓\(ref.behind)").font(.ui(size: 10.5, weight: .medium)).foregroundStyle(Color.difText2) }
                    if ref.upstreamGone {
                        Image(systemName: "cloud.slash").font(.ui(size: 10)).foregroundStyle(Color.difText3)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(help)
    }

    private func symbol(_ ref: GitRef) -> String {
        if ref.isHead { return "checkmark" }
        switch ref.kind {
        case .local: return "arrow.triangle.branch"
        case .remote: return "cloud"
        case .tag: return "tag"
        }
    }

    private var help: String {
        guard case .ref(let ref) = row.kind else { return "" }
        var lines = [ref.shortName]
        if let upstream = ref.upstream {
            lines.append(ref.upstreamGone ? L("Upstream \(upstream) is gone", "上游 \(upstream) 已不存在") : L("Tracking \(upstream)", "跟踪 \(upstream)"))
        }
        return lines.joined(separator: "\n")
    }
}

private struct TagRowActionButton: View {
    var symbol: String
    var help: String
    var destructive = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.ui(size: 10, weight: .medium))
                .foregroundStyle(hovering ? (destructive ? Color.difRemoved : Color.difText) : Color.difText2)
                .frame(width: UI.s(18), height: UI.s(18))
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? Color.difText.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Commit graph

private struct CommitGraphList: View {
    let model: GitGraphModel
    @Environment(AppStore.self) private var store

    var body: some View {
        if model.rows.isEmpty {
            if model.isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyListState(symbol: "point.3.connected.trianglepath.dotted",
                               title: model.errorText == nil ? L("No commits yet", "还没有提交") : L("Could not read the history", "无法读取提交历史"),
                               detail: model.errorText ?? "")
            }
        } else {
            let lanes = model.laneCount
            @Bindable var model = model
            KeyboardList(rows: model.rows, selection: Binding(get: { model.selectedCommitID }, set: { model.selectedCommitID = $0 }),
                         multiSelection: $model.selectedCommitIDs,
                         focusToken: model.graphFocusToken, name: "graph", rowHeight: 26,
                         onKey: { event, row in
                             switch event.keyCode {
                             case 36, 76:
                                 if let row { store.showCommitInLog(row.id) }
                                 return true
                             case 48, 123: // ⇥ or ←: over to the branches
                                 model.focusBranches()
                                 return true
                             default:
                                 return false
                             }
                         },
                         onDoubleClick: { row in store.showCommitInLog(row.id) },
                         onLastRowAppear: { if model.hasMore { model.load(reset: false) } }) { row, _, _ in
                GraphRowView(row: row, lanes: lanes, model: model)
            }
        }
    }
}

private struct GraphRowView: View {
    let row: GraphRow
    let lanes: Int
    let model: GitGraphModel

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        let commit = row.commit
        HStack(spacing: 8) {
            Color.clear.frame(width: GraphLanes.width(lanes: lanes)) // the lanes are drawn by the overlay
            ForEach(commit.refs.prefix(3), id: \.self) { ref in RefChip(ref: ref) }
            if commit.refs.count > 3 {
                Text("+\(commit.refs.count - 3)").font(.ui(size: 10, weight: .semibold)).foregroundStyle(Color.difText3)
            }
            Text(commit.subject)
                .font(.ui(size: 12.5))
                .foregroundStyle(Color.difText)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(commit.author)
                .font(.ui(size: 11.5))
                .foregroundStyle(Color.difText3)
                .lineLimit(1)
                .frame(width: UI.s(104), alignment: .leading)
            Text(Self.relative.localizedString(for: commit.date, relativeTo: Date()))
                .font(.ui(size: 11.5))
                .foregroundStyle(Color.difText3)
                .lineLimit(1)
                .frame(width: UI.s(70), alignment: .trailing)
            Text(commit.shortHash)
                .font(.code(11))
                .foregroundStyle(Color.difText3)
                .frame(width: UI.s(58), alignment: .trailing)
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .overlay(GraphLanes(row: row, inset: 8, model: model))
        .help("\(commit.subject)\n\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.shortHash)")
    }
}

/// One row's slice of the graph. Rows are drawn independently; their lines meet at the row edges.
/// Lies over a whole row of the graph: draws the lanes at its leading edge, and gives the row its right-click menu.
///
/// Built to stay small, since every row that has been shown stays alive in the lazy list. The lanes are vector
/// layers, one per colour (a SwiftUI `Canvas` cost about 145 MB for a second or two each time the dropdown opened
/// or closed, as its first use starts up GPU rendering). The menu is an AppKit one built on the click: SwiftUI's
/// `.contextMenu` kept some 20 KB per row, most of the dropdown's memory once a few thousand rows had been seen.
struct GraphLanes: NSViewRepresentable {
    let row: GraphRow
    /// Where the first lane starts.
    var inset: CGFloat = 0
    weak var model: GitGraphModel?

    static var laneWidth: CGFloat { UI.s(14) }
    static func width(lanes: Int) -> CGFloat { CGFloat(lanes) * laneWidth + 6 }

    static let palette: [NSColor] = [0x5C92F7, 0x57B46F, 0xE5A04B, 0xB57BEE, 0xEF6F8E, 0x3DBFC6, 0xD9B43B, 0xE5736B]
        .map { NSColor(hex: $0) }

    static func color(_ index: Int) -> NSColor { palette[index % palette.count] }

    final class LanesView: NSView {
        var row: GraphRow? {
            didSet { if row != oldValue { needsDisplay = true } }
        }
        var inset: CGFloat = 0 {
            didSet { if inset != oldValue { needsDisplay = true } }
        }
        weak var model: GitGraphModel?
        private var drawnSize: CGSize = .zero

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override var isFlipped: Bool { true }
        override var wantsUpdateLayer: Bool { true }

        /// Only a right-click (or ⌃-click) stops here; every other click goes through to the row underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let wantsMenu = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return wantsMenu ? super.hitTest(point) : nil
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let row, let model else { return nil }
            return model.contextMenu(for: row)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func layout() {
            super.layout()
            if bounds.size != drawnSize { needsDisplay = true }
        }

        override func updateLayer() {
            guard let layer else { return }
            drawnSize = bounds.size
            effectiveAppearance.performAsCurrentDrawingAppearance { self.rebuild(in: layer) }
        }

        private func rebuild(in layer: CALayer) {
            layer.sublayers = nil
            guard let row, bounds.height > 0 else { return }
            let lane = GraphLanes.laneWidth
            func x(_ index: Int) -> CGFloat { inset + 3 + lane * (CGFloat(index) + 0.5) }
            let height = bounds.height
            let mid = (height / 2).rounded()
            // The layer's own coordinates run bottom-up whatever the view's do; draw top-down and flip once.
            func y(_ value: CGFloat) -> CGFloat { layer.isGeometryFlipped ? value : height - value }

            var lines: [Int: CGMutablePath] = [:]
            for segment in row.segments {
                let start: CGPoint, end: CGPoint
                switch segment.span {
                case .through:
                    start = CGPoint(x: x(segment.from), y: 0)
                    end = CGPoint(x: x(segment.from), y: height)
                case .intoNode:
                    start = CGPoint(x: x(segment.from), y: 0)
                    end = CGPoint(x: x(segment.to), y: mid)
                case .outOfNode:
                    start = CGPoint(x: x(segment.from), y: mid)
                    end = CGPoint(x: x(segment.to), y: height)
                }
                let path = lines[segment.color] ?? CGMutablePath()
                path.move(to: CGPoint(x: start.x, y: y(start.y)))
                if start.x == end.x {
                    path.addLine(to: CGPoint(x: end.x, y: y(end.y)))
                } else {
                    // An S-bend that leaves and arrives vertically, so lanes flow into each other.
                    let bend = (end.y - start.y) * 0.6
                    path.addCurve(to: CGPoint(x: end.x, y: y(end.y)),
                                  control1: CGPoint(x: start.x, y: y(start.y + bend)),
                                  control2: CGPoint(x: end.x, y: y(end.y - bend)))
                }
                lines[segment.color] = path
            }
            for (color, path) in lines.sorted(by: { $0.key < $1.key }) {
                let shape = CAShapeLayer()
                shape.path = path
                shape.fillColor = nil
                shape.strokeColor = GraphLanes.color(color).cgColor
                shape.lineWidth = 1.6
                shape.lineCap = .round
                layer.addSublayer(shape)
            }

            let center = CGPoint(x: x(row.column), y: y(mid))
            let color = GraphLanes.color(row.color).cgColor
            func circle(_ radius: CGFloat) -> CGPath {
                CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            }
            func dot(_ path: CGPath, fill: CGColor?, stroke: CGColor? = nil, width: CGFloat = 0) {
                let shape = CAShapeLayer()
                shape.path = path
                shape.fillColor = fill
                shape.strokeColor = stroke
                shape.lineWidth = width
                layer.addSublayer(shape)
            }
            let background = Palette.window.cgColor
            if row.commit.refs.contains(where: { $0 == "HEAD" || $0.hasPrefix("HEAD -> ") }) {
                // The checked-out commit: a ring around the dot.
                dot(circle(5.5), fill: background, stroke: color, width: 2)
                dot(circle(2.5), fill: color)
            } else if row.commit.isMerge {
                dot(circle(3.5), fill: background, stroke: color, width: 1.6)
            } else {
                dot(circle(4), fill: color)
            }
        }
    }

    func makeNSView(context: Context) -> LanesView {
        let view = LanesView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: LanesView, context: Context) {
        view.row = row
        view.inset = inset
        view.model = model
    }
}
