import SwiftUI

/// Hosts the AppKit canvas. The canvas is created once and fed documents imperatively by `ViewerModel`.
struct CanvasHost: NSViewRepresentable {
    var attach: (CodeScrollContainer) -> Void

    func makeNSView(context: Context) -> CodeScrollContainer {
        let container = CodeScrollContainer(frame: .zero)
        attach(container)
        return container
    }

    func updateNSView(_ view: CodeScrollContainer, context: Context) {}
}

/// Right column: the diff or file viewer.
struct ViewerPanel: View {
    let project: Project
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let viewer = store.viewer
        let highlightedGroupHunks: Set<Int>? = viewer.request.flatMap {
            $0.root == project.url ? project.highlightedGroupHunks(for: $0.path) : nil
        }
        VStack(spacing: 0) {
            ViewerHeader(project: project)
            Rectangle().fill(Color.difHairline).frame(height: 1)
            if viewer.showsConflicts, let request = viewer.request, request.root == project.url {
                ConflictBar(project: project, path: request.path)
            }
            if viewer.findVisible && !viewer.isSpreadsheet { FindBar() }
            if let doc = viewer.document, case .text = doc.content, !doc.isPlainFile, !doc.isAddedOnly {
                PaneTitles(left: doc.leftTitle, right: doc.rightTitle, unified: store.settings.unified)
            }
            if viewer.isTextDocument, let doc = viewer.document, !doc.isPlainFile {
                SemanticStatusBar(viewer: viewer, doc: doc)
            }
            ZStack {
                // Always mounted, so switching between a diff and an image never rebuilds the canvas.
                CanvasHost { viewer.attach($0) }
                overlay(viewer)
                if let hover = viewer.annotationHover {
                    AnnotationCard(hover: hover, lineHeight: (store.settings.fontSize * 1.5).rounded())
                }
            }
            if store.settings.showLineDiffBar, !viewer.isSpreadsheet, let snapshot = viewer.lineDiffSnapshot {
                LineDiffBarView(
                    snapshot: snapshot,
                    theme: colorScheme == .dark ? .dark : .light,
                    codeFont: CodeFont.current(store.settings),
                    onClose: {
                        store.settings.showLineDiffBar = false
                        store.settings.save()
                    },
                    onJumpToMoveCounterpart: { hunkIndex in
                        viewer.jumpToMoveCounterpart(forHunk: hunkIndex)
                    }
                )
            }
            if viewer.vimModeEnabled && viewer.isTextDocument {
                VimStatusBar(viewer: viewer)
            }
        }
        .background(Color.difWindow)
        .onAppear {
            viewer.setHighlightedGroupHunks(highlightedGroupHunks)
        }
        .onChange(of: highlightedGroupHunks) { _, newValue in
            viewer.setHighlightedGroupHunks(newValue)
        }
        .onChange(of: store.settings.semanticDiffOptions) { _, _ in
            viewer.syncSemanticOptions()
        }
        .onChange(of: viewer.diffRevision) { _, _ in
            viewer.refreshChangedSymbols()
        }
    }

    @ViewBuilder
    private func overlay(_ viewer: ViewerModel) -> some View {
        if viewer.request == nil {
            ViewerEmptyState(project: project).background(Color.difWindow)
        } else if let doc = viewer.document {
            switch doc.content {
            case .image(let old, let new):
                ImageDiffView(old: old, new: new, leftTitle: doc.leftTitle, rightTitle: doc.rightTitle).background(Color.difWindow)
            case .spreadsheet(let workbook, let fileURL):
                ExcelViewerView(
                    workbook: workbook,
                    fileURL: fileURL,
                    sessionKey: viewer.excelSessionKey(for: fileURL),
                    viewer: viewer
                )
                .background(Color.difWindow)
            case .message(let title, let detail):
                EmptyListState(symbol: "doc.questionmark", title: title, detail: detail).background(Color.difWindow)
            case .text:
                let _ = viewer.diffRevision
                if let note = doc.note {
                    VStack {
                        Text(note)
                            .font(.ui(size: 11.5, weight: .medium))
                            .foregroundStyle(Color.difText2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.difElevated).shadow(color: .black.opacity(0.2), radius: 6, y: 2))
                            .padding(.top, 10)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Over a file git is merging: how many conflicts are left, which version the left side shows, and Mark as Resolved.
private struct ConflictBar: View {
    @Bindable var project: Project
    let path: String
    @Environment(AppStore.self) private var store

    var body: some View {
        let count = store.viewer.conflictCount
        HStack(spacing: 10) {
            Image(systemName: count > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(count > 0 ? Color.orange : Color.difAdded)
            Text(count == 0 ? L("No conflicts left", "冲突已全部处理") : (count == 1 ? L("1 conflict", "1 处冲突") : L("\(count) conflicts", "\(count) 处冲突")))
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(Color.difText)
                .fixedSize()
            Text(L("Left:", "左侧：")).font(.ui(size: 11.5)).foregroundStyle(Color.difText3).fixedSize()
            Picker("", selection: Binding(get: { project.conflictBase }, set: { base in
                project.conflictBase = base
                store.syncViewer()
            })) {
                ForEach(ConflictBase.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(L("What the left side shows: HEAD’s version, the common ancestor, or the incoming one", "左侧显示的版本：HEAD 的、共同祖先的，或传入的"))
            Spacer(minLength: 8)
            Button {
                store.openThreeWayMerge(in: project, focusing: path)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.merge")
                        .font(.ui(size: 10.5, weight: .semibold))
                    Text(L("3-Way Merge…", "三方合并…"))
                        .font(.ui(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 10)
                .frame(height: UI.s(24))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difAccent))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            Button {
                store.markResolved(path, in: project)
            } label: {
                Text(L("Mark as Resolved", "标记为已解决"))
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundStyle(count == 0 ? Color.white : Color.difText)
                    .padding(.horizontal, 10)
                    .frame(height: UI.s(24))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(count == 0 ? Color.difAccent : Color.difText.opacity(0.1)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(36))
        .background((count > 0 ? Color.orange : Color.difAdded).opacity(0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.difHairline).frame(height: 1) }
    }
}

private struct ViewerHeader: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        let viewer = store.viewer
        HStack(spacing: 8) {
            if store.canNavigateBack || store.canNavigateForward {
                HStack(spacing: 2) {
                    IconButton(symbol: "chevron.left", help: L("Navigate Back (⌘[)", "后退 (⌘[)"), size: 11) {
                        store.navigateBack()
                    }
                    .disabled(!store.canNavigateBack)
                    .opacity(store.canNavigateBack ? 1 : 0.35)
                    IconButton(symbol: "chevron.right", help: L("Navigate Forward (⌘])", "前进 (⌘])"), size: 11) {
                        store.navigateForward()
                    }
                    .disabled(!store.canNavigateForward)
                    .opacity(store.canNavigateForward ? 1 : 0.35)
                }
                .frame(maxHeight: .infinity)
                .titlebarClickGuard(horizontalOutset: 4)
                Divider().frame(height: 14)
            }
            if let request = viewer.request {
                FileIcon(path: request.path, size: 13)
                PathLabel(request: request)
                if viewer.isDirty {
                    // Typed and not yet written; it goes to the file a moment after typing stops.
                    Circle()
                        .fill(Color.difText2)
                        .frame(width: UI.s(7), height: UI.s(7))
                        .help(L("Not saved yet · saved when you pause, or with ⌘S", "尚未写入 · 停止输入片刻后自动保存，或按 ⌘S"))
                }
                if let reason = viewer.readOnlyReason {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill").font(.ui(size: 9))
                        Text(reason).font(.ui(size: 10.5))
                    }
                    .foregroundStyle(Color.difText3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.difText3.opacity(0.12)))
                    .lineLimit(1)
                    .fixedSize()
                }
                if let doc = viewer.document, case .text = doc.content, !doc.isPlainFile {
                    // The diff of text being edited changes in place; this follows it.
                    let _ = viewer.diffRevision
                    StatBadge(additions: doc.additions, deletions: doc.deletions)
                    if viewer.hunkCount > 0 {
                        Text(differenceLabel(viewer))
                            .font(.ui(size: 11))
                            .foregroundStyle(Color.difText3)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            } else {
                Text(project.name).font(.ui(size: 13, weight: .medium)).foregroundStyle(Color.difText2)
            }
            Spacer(minLength: 8)
            if viewer.request != nil, viewer.loadMilliseconds > 0 {
                // Load time, shown because being fast is the point.
                Text(String(format: "%.0f ms", viewer.loadMilliseconds))
                    .font(.ui(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.difText3)
                    .help(L("Time to load, diff and highlight this file", "加载、比较并高亮这个文件所用的时间"))
            }
            if viewer.request != nil || AppEnvironment.hasTerminal {
                HStack(spacing: 8) {
                    if viewer.request != nil {
                        if viewer.isTextDocument || viewer.isSpreadsheet {
                            IconButton(symbol: "arrow.left", help: L("Previous file (⇧⌘[)", "上一个文件 (⇧⌘[)")) { store.stepFile(-1) }
                            IconButton(symbol: "arrow.right", help: L("Next file (⇧⌘])", "下一个文件 (⇧⌘])")) { store.stepFile(1) }
                        }
                        if viewer.isTextDocument, let doc = viewer.document, !doc.isPlainFile {
                            IconButton(symbol: "arrow.up", help: L("Previous Difference (⇧F7)", "上一处差异 (⇧F7)")) { viewer.stepDifference(-1) }
                            IconButton(symbol: "arrow.down", help: L("Next Difference (F7)", "下一处差异 (F7)")) { viewer.stepDifference(1) }
                            Divider().frame(height: 14)
                            if !doc.isAddedOnly {
                                IconButton(symbol: "rectangle.split.2x1", help: L("Side-by-Side (⌥⌘V)", "并排视图 (⌥⌘V)"), isActive: !store.settings.unified) {
                                    if store.settings.unified { viewer.toggleUnified() }
                                }
                                IconButton(symbol: "rectangle.grid.1x2", help: L("Unified (⌥⌘V)", "合并视图 (⌥⌘V)"), isActive: store.settings.unified) {
                                    if !store.settings.unified { viewer.toggleUnified() }
                                }
                                IconButton(symbol: "rectangle.split.1x2",
                                           help: L("Toggle inline line diff", "显示/隐藏底部行内对比"),
                                           isActive: store.settings.showLineDiffBar) {
                                    store.settings.showLineDiffBar.toggle()
                                    store.settings.save()
                                    if store.settings.showLineDiffBar {
                                        viewer.refreshLineDiff()
                                    }
                                }
                            }
                            IconButton(symbol: "space", help: L("Ignore Whitespace (⌥⌘W)", "忽略空白差异 (⌥⌘W)"), isActive: store.settings.ignoreWhitespace) {
                                viewer.toggleWhitespace()
                            }
                            IconButton(symbol: "text.bubble", help: L("Ignore Comment Changes", "忽略注释变更"), isActive: store.settings.ignoreComments) {
                                viewer.toggleIgnoreComments()
                            }
                            if !doc.isAddedOnly {
                                IconButton(symbol: "rectangle.compress.vertical",
                                           help: L("Collapse Unchanged Lines", "折叠未变更行"),
                                           isActive: store.settings.collapseUnchanged) {
                                    viewer.toggleCollapseUnchanged()
                                }
                            }
                            SemanticOptionsMenu(viewer: viewer)
                            Divider().frame(height: 14)
                        } else if viewer.isTextDocument {
                            Divider().frame(height: 14)
                        }
                        if viewer.isTextDocument {
                            let available = viewer.annotating || viewer.canAnnotate
                            IconButton(symbol: "person.text.rectangle", help: L("Annotate with Git Blame", "逐行追溯 (Blame)：每行最后由谁在何时修改"),
                                       isActive: viewer.annotating, size: 12.5) {
                                viewer.toggleAnnotate()
                            }
                            .disabled(!available)
                            .opacity(available ? 1 : 0.35)
                            .overlay(alignment: .bottomTrailing) {
                                if viewer.isBlaming {
                                    ProgressView().controlSize(.mini).scaleEffect(0.5).offset(x: 3, y: 3).allowsHitTesting(false)
                                }
                            }
                        }
                        if !viewer.isSpreadsheet {
                            IconButton(symbol: "magnifyingglass", help: L("Find in File (⌃⇧⌘F)", "在文件中查找 (⌃⇧⌘F)"), isActive: viewer.findVisible) {
                                if viewer.findVisible { viewer.hideFind() } else { viewer.showFind() }
                            }
                        }
                        if let request = viewer.request, request.source != .file, !request.isExternalFile, !viewer.isSpreadsheet {
                            let canOpen = store.canOpenCurrentFile
                            IconButton(
                                symbol: "doc.plaintext",
                                help: canOpen
                                    ? L("Open File Content", "直接打开当前文件内容")
                                    : L("This file is not in the working tree", "这个文件不在当前工作区里"),
                                size: 12.5
                            ) {
                                store.openCurrentFile()
                            }
                            .disabled(!canOpen)
                            .opacity(canOpen ? 1 : 0.35)
                        } else if store.canShowDiffForCurrentFile {
                            IconButton(
                                symbol: "arrow.left.arrow.right",
                                help: L("Show Diff (⌘D)", "查看差异 (⌘D)"),
                                size: 12
                            ) {
                                store.showDiffForCurrentFile()
                            }
                        }
                        if AppEnvironment.hasTerminal {
                            Divider().frame(height: 14)
                        }
                    }
                    if AppEnvironment.hasTerminal {
                        TerminalToggle(project: project)
                    }
                }
                .frame(maxHeight: .infinity)
                .titlebarClickGuard(horizontalOutset: 4)
            }
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 10)
        .frame(height: store.titlebarHeight)
        .background(WindowDragArea())
    }

    /// Leave room for the traffic lights when this header is the leftmost thing in the window.
    private var leadingInset: CGFloat {
        (!store.sidebarVisible && !store.listVisible && !store.isFullScreen) ? 84 : 14
    }

    private func differenceLabel(_ viewer: ViewerModel) -> String {
        let total = viewer.hunkCount
        if let focused = viewer.focusedHunk {
            return L("\(focused + 1) of \(total) differences", "第 \(focused + 1) / \(total) 处差异")
        }
        return total == 1 ? L("1 difference", "1 处差异") : L("\(total) differences", "\(total) 处差异")
    }
}

/// Shows and hides the terminals. Lights up while they are shown, and carries a dot when one rings while they are hidden.
private struct TerminalToggle: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        let terminals = store.terminals
        IconButton(symbol: "terminal", help: terminals.isVisible ? L("Hide Terminal (⌥F12)", "隐藏终端 (⌥F12)") : L("Show Terminal (⌥F12)", "显示终端 (⌥F12)"),
                   isActive: terminals.isVisible, size: 12.5) {
            terminals.toggle()
        }
        .overlay(alignment: .topTrailing) {
            if !terminals.isVisible, terminals.needsAttention(project) {
                Circle().fill(Color.orange).frame(width: 6, height: 6).offset(x: -3, y: 3).allowsHitTesting(false)
            }
        }
    }
}

private struct PathLabel: View {
    var request: DiffRequest

    var body: some View {
        let shown = request.displayPath
        let name = (shown as NSString).lastPathComponent
        let directory = (shown as NSString).deletingLastPathComponent
        HStack(spacing: 6) {
            Text(name)
                .font(.ui(size: 13, weight: .semibold))
                .foregroundStyle(Color.status(request.kind))
                .lineLimit(1)
                .layoutPriority(2)
            if let old = request.oldPath, old != request.path {
                Text("← " + (old as NSString).lastPathComponent)
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
            }
            if !directory.isEmpty {
                Text(directory)
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .help(request.isExternalFile ? request.fileURL.path : (request.oldPath.map { "\($0) → \(request.path)" } ?? request.path))
    }
}

/// The commit of the line under the pointer in the Annotate column: what it was, who made it and when.
/// Placed under the line, beside the column; it never takes the pointer, so moving along the column stays smooth.
private struct AnnotationCard: View {
    var hover: AnnotationHover
    var lineHeight: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = min(UI.s(360), max(200, proxy.size.width - 24))
            let height = UI.s(96)
            let x = min(max(8, hover.anchor.x + 4), max(8, proxy.size.width - width - 8))
            let below = hover.anchor.y + lineHeight + 4
            let y = below + height > proxy.size.height ? max(4, hover.anchor.y - height - 4) : below
            card
                .frame(width: width, alignment: .leading)
                .offset(x: x, y: y)
        }
        .allowsHitTesting(false)
    }

    private var card: some View {
        let entry = hover.entry
        return VStack(alignment: .leading, spacing: 5) {
            Text(entry.summary.isEmpty ? entry.shortHash : entry.summary)
                .font(.ui(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.difText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                Text(entry.author).lineLimit(1)
                Text("·")
                Text(entry.date.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                Text("(" + entry.date.formatted(.relative(presentation: .named)) + ")").lineLimit(1)
            }
            .font(.ui(size: 11))
            .foregroundStyle(Color.difText2)
            HStack(spacing: 6) {
                Text(entry.shortHash).font(.code(10.5)).foregroundStyle(Color.difAccent)
                Text(L("Click to show this commit", "点击查看这个提交")).font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.difElevated)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.difHairline, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Revision labels above each pane.
private struct PaneTitles: View {
    var left: String
    var right: String
    var unified: Bool

    var body: some View {
        HStack(spacing: 0) {
            if unified {
                label("\(left) → \(right)")
                Spacer()
            } else {
                label(left).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 44)
                label(right).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 12)
            }
        }
        .frame(height: UI.s(22))
        .background(Color.difWindow)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.difHairline.opacity(0.6)).frame(height: 1) }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 10.5, weight: .medium))
            .foregroundStyle(Color.difText3)
            .padding(.horizontal, 12)
            .lineLimit(1)
    }
}

private struct FindBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var viewer = store.viewer
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.ui(size: 12)).foregroundStyle(Color.difText3)
            SearchField(text: $viewer.findQuery, placeholder: L("Find in file", "在文件中查找"),
                        font: .systemFont(ofSize: 13 * UI.scale), focusToken: viewer.findFocusToken,
                        onMove: { viewer.stepFind($0 > 0 ? 1 : -1) },
                        onSubmit: { viewer.stepFind(NSEvent.modifierFlags.contains(.shift) ? -1 : 1) },
                        onCancel: { viewer.hideFind() })
                .frame(height: UI.s(20))
            Text(viewer.findQuery.isEmpty ? "" : (viewer.findCount == 0 ? L("No results", "无结果") : "\(viewer.findIndex)/\(viewer.findCount)"))
                .font(.ui(size: 11, design: .rounded))
                .foregroundStyle(viewer.findCount == 0 ? Color.difRemoved : Color.difText3)
                .fixedSize()
            IconButton(symbol: "chevron.up", help: L("Previous (⇧⌘G)", "上一个 (⇧⌘G)"), size: 11) { viewer.stepFind(-1) }
            IconButton(symbol: "chevron.down", help: L("Next (⌘G)", "下一个 (⌘G)"), size: 11) { viewer.stepFind(1) }
            IconButton(symbol: "xmark", help: L("Close (Esc)", "关闭 (Esc)"), size: 11) { viewer.hideFind() }
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(34))
        .background(Color.difPanel)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.difHairline).frame(height: 1) }
        .onChange(of: viewer.findQuery) { _, _ in viewer.runFind(reveal: true) }
    }
}

/// Shown when nothing is open: the shortcuts worth knowing, as in an empty IntelliJ editor.
private struct ViewerEmptyState: View {
    let project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        let hints: [(String, String)] = [
            (L("Search Everywhere", "随处搜索"), L("Double ⇧", "双击 ⇧")),
            (L("Go to File", "查找文件"), "⌘P"),
            (L("Find in Files", "在文件中查找"), "⌘F"),
            (L("Recent Files", "最近的文件"), "⌘E"),
            (L("Next / Previous Difference", "下一处 / 上一处差异"), "F7 / ⇧F7"),
            (L("Git Log", "提交历史"), "⌘9"),
        ]
        VStack(spacing: 22) {
            if project.hasLoaded, project.changes.isEmpty, project.tab == .changes {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.ui(size: 34))
                        .foregroundStyle(Color.difAdded.opacity(0.85))
                    Text(L("Working tree clean", "工作区很干净"))
                        .font(.ui(size: 15, weight: .medium))
                        .foregroundStyle(Color.difText2)
                }
            } else if project.tab == .groups {
                VStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.ui(size: 32))
                        .foregroundStyle(Color.difAccent.opacity(0.8))
                    Text(L("Select a file or hunk in a group", "在左侧点击分组内的文件或改动块查看代码"))
                        .font(.ui(size: 14, weight: .medium))
                        .foregroundStyle(Color.difText2)
                    Text(L("Only hunks belonging to the selected group are shown in the diff.", "右侧仅显示当前选中分组的改动，其他改动自动隐藏。"))
                        .font(.ui(size: 12))
                        .foregroundStyle(Color.difText3)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                ForEach(hints, id: \.0) { hint in
                    GridRow {
                        Text(hint.0).font(.ui(size: 13)).foregroundStyle(Color.difText2)
                        KeyCaps(shortcut: hint.1, size: 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Before/after for image files.
private struct ImageDiffView: View {
    var old: Data?
    var new: Data?
    var leftTitle: String
    var rightTitle: String

    var body: some View {
        HStack(spacing: 16) {
            if let old { ImagePane(data: old, title: leftTitle.isEmpty ? L("Before", "之前") : leftTitle, tint: Color.difRemoved) }
            if let new { ImagePane(data: new, title: rightTitle.isEmpty ? L("Current", "当前") : rightTitle, tint: Color.difAdded) }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImagePane: View {
    var data: Data
    var title: String
    var tint: Color

    var body: some View {
        let image = NSImage(data: data)
        let pixels: CGSize = {
            guard let rep = image?.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return .zero }
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }()
        VStack(spacing: 10) {
            GeometryReader { proxy in
                // Fit the pane, but never magnify beyond 4x: icons stay inspectable, nothing turns to mush.
                let fit = pixels == .zero ? 1 : min((proxy.size.width - 24) / pixels.width, (proxy.size.height - 24) / pixels.height)
                let scale = max(0.01, min(fit, 4))
                ZStack {
                    Checkerboard()
                    if let image, pixels != .zero {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(scale > 1 ? .none : .high)
                            .frame(width: pixels.width * scale, height: pixels.height * scale)
                    } else {
                        Text(L("Cannot preview this image", "无法预览该图片")).font(.ui(size: 12)).foregroundStyle(Color.difText3)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .bottomTrailing) {
                    if pixels != .zero {
                        Text("\(Int((scale * 100).rounded()))%")
                            .font(.ui(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.difText2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.difElevated.opacity(0.9)))
                            .padding(8)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.5), lineWidth: 1))
            HStack(spacing: 8) {
                Text(title).font(.ui(size: 12, weight: .semibold)).foregroundStyle(tint)
                if pixels != .zero {
                    Text("\(Int(pixels.width)) × \(Int(pixels.height))")
                }
                Text(data.count.byteSizeString)
            }
            .font(.ui(size: 11.5, design: .rounded))
            .foregroundStyle(Color.difText2)
        }
    }
}

/// The transparency grid behind an image. A pattern colour on a bare layer: the compositor
/// tiles one 20 pt image, so the grid costs no backing store however large the pane is.
private struct Checkerboard: NSViewRepresentable {
    final class PatternView: NSView {
        override var wantsUpdateLayer: Bool { true }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func updateLayer() {
            // Colours are resolved to concrete values here so the grid follows light/dark changes.
            var base = CGColor(gray: 0.5, alpha: 1), check = CGColor(gray: 0.6, alpha: 1)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                base = Palette.panel.cgColor
                check = Palette.hover.cgColor
            }
            let cell = 10, scale = 2
            let side = cell * 2 * scale
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(base)
            ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
            ctx.setFillColor(check)
            ctx.fill(CGRect(x: 0, y: 0, width: cell * scale, height: cell * scale))
            ctx.fill(CGRect(x: cell * scale, y: cell * scale, width: cell * scale, height: cell * scale))
            guard let tile = ctx.makeImage() else { return }
            let image = NSImage(cgImage: tile, size: NSSize(width: cell * 2, height: cell * 2))
            layer?.backgroundColor = NSColor(patternImage: image).cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    func makeNSView(context: Context) -> PatternView { PatternView(frame: .zero) }
    func updateNSView(_ view: PatternView, context: Context) {}
}

/// Compact Vim status footer bar: mode pill, active `:` command line, pending key buffer, and Ln/Col indicator.
private struct VimStatusBar: View {
    let viewer: ViewerModel

    private var pillColor: Color {
        switch viewer.vimMode {
        case .normal: return Color.difAccent
        case .insert: return Color.difAdded
        case .visual, .visualLine, .visualBlock: return Color.purple
        case .commandLine: return Color.orange
        }
    }

    private var commandNSFont: NSFont {
        let scaled = 11.5 * UI.scale
        if let family = Settings.shared.codeFontFamily, let font = MonospaceFonts.regular(family, size: scaled) {
            return font
        }
        return NSFont(name: "JetBrainsMono-Regular", size: scaled) ?? .monospacedSystemFont(ofSize: scaled, weight: .regular)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(viewer.vimMode.label)
                .font(.system(size: 10 * UI.scale, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(pillColor))
                .fixedSize()

            if case .commandLine(let prefix, _) = viewer.vimMode {
                HStack(spacing: 1) {
                    Text(prefix)
                        .font(.code(11.5))
                        .foregroundStyle(Color.difText)
                        .fixedSize()
                    VimCommandField(
                        text: Binding(
                            get: { viewer.vimCommandBuffer },
                            set: { viewer.updateVimCommandBuffer($0) }
                        ),
                        font: commandNSFont,
                        focusToken: viewer.vimCommandFocusToken,
                        onSubmit: { viewer.submitVimCommand($0) },
                        onCancel: { viewer.cancelVimCommand(restoreFocus: true) },
                        onEndEditingExternally: { viewer.cancelVimCommand(restoreFocus: false) }
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: UI.s(16))
                }
            } else {
                Spacer(minLength: 8)
            }

            if !viewer.vimPendingKeys.isEmpty {
                Text(viewer.vimPendingKeys)
                    .font(.code(11))
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.difText.opacity(0.08)))
                    .fixedSize()
            }

            Text("Ln \(viewer.vimCursorLine), Col \(viewer.vimCursorColumn)")
                .font(.system(size: 10.5 * UI.scale, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.difText3)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: UI.s(22))
        .background(Color.difPanel)
        .overlay(alignment: .top) { Rectangle().fill(Color.difHairline).frame(height: 1) }
    }
}

// MARK: - SemanticDiff toolbar menu & status strip

/// Compact menu in `ViewerHeader` exposing all Stage 1 SemanticDiff toggles and fold actions.
private struct SemanticOptionsMenu: View {
    let viewer: ViewerModel
    @Environment(AppStore.self) private var store
    @State private var hovered = false

    private var hasActiveFilter: Bool {
        store.settings.ignoreComments
            || (viewer.isJSONDocument && store.settings.normalizeJSON)
            || store.settings.collapseUnchanged
    }

    var body: some View {
        Menu {
            Toggle(L("Ignore Comment Changes", "忽略注释变更"), isOn: Binding(
                get: { store.settings.ignoreComments },
                set: { _ in viewer.toggleIgnoreComments() }
            ))
            Toggle(L("Collapse Unchanged Lines", "折叠未变更行"), isOn: Binding(
                get: { store.settings.collapseUnchanged },
                set: { _ in viewer.toggleCollapseUnchanged() }
            ))
            Toggle(L("Detect Moved Code Blocks", "检测移动代码块"), isOn: Binding(
                get: { store.settings.detectMoves },
                set: { _ in viewer.toggleDetectMoves() }
            ))
            Toggle(L("Highlight Cross-Hunk Renames", "高亮跨区块重命名"), isOn: Binding(
                get: { store.settings.detectRenames },
                set: { _ in viewer.toggleDetectRenames() }
            ))
            if viewer.isJSONDocument {
                Divider()
                Toggle(L("Normalize JSON Structure (Read-Only)", "JSON 语义规范化（只读）"), isOn: Binding(
                    get: { store.settings.normalizeJSON },
                    set: { _ in viewer.toggleNormalizeJSON() }
                ))
            }
            if viewer.activeFoldRegionCount > 0 || !viewer.expandedFoldSegments.isEmpty {
                Divider()
                Button(L("Expand All Folds", "展开全部折叠")) {
                    viewer.expandAllFolds()
                }
                .disabled(viewer.activeFoldRegionCount == 0)
                Button(L("Collapse All Unchanged", "重新折叠未变更行")) {
                    viewer.collapseAllFolds()
                }
                .disabled(!viewer.canCollapseUnchanged || viewer.expandedFoldSegments.isEmpty)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12 * UI.scale, weight: .medium))
                .foregroundStyle(hasActiveFilter ? Color.difAccent : (hovered ? Color.difText : Color.difText2))
                .frame(width: UI.s(26), height: UI.s(24))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hasActiveFilter ? Color.difAccent.opacity(0.14) : (hovered ? Color.difHover : Color.clear))
                )
                .overlay(alignment: .topTrailing) {
                    if hasActiveFilter {
                        Circle()
                            .fill(Color.difAccent)
                            .frame(width: 5, height: 5)
                            .offset(x: -3, y: 3)
                            .allowsHitTesting(false)
                    }
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(L("Semantic Diff Options", "语义 Diff 选项"))
    }
}

/// Slim status bar shown above the canvas only when SemanticDiff metadata or changed symbols are present.
private struct SemanticStatusBar: View {
    let viewer: ViewerModel
    let doc: DiffDocument
    @Environment(AppStore.self) private var store
    @State private var showRenamePopover = false

    private var hasItems: Bool {
        doc.isGroupFiltered
            || doc.hiddenCommentHunkCount > 0
            || doc.isJSONNormalized
            || viewer.movedPairCount > 0
            || !doc.renameGroups.isEmpty
            || viewer.hiddenFoldLineCount > 0
            || !viewer.changedSymbols.isEmpty
    }

    var body: some View {
        let _ = viewer.diffRevision
        if hasItems {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if doc.isGroupFiltered {
                        HStack(spacing: 4) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 9.5 * UI.scale, weight: .semibold))
                            Text(L("Group view (current group only · read-only)", "分组视图（仅显示本组改动 · 只读）"))
                                .font(.ui(size: 10.5, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color.difAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Color.difAccent.opacity(0.10)))
                        .overlay(Capsule().strokeBorder(Color.difAccent.opacity(0.28), lineWidth: 0.75))
                        .fixedSize()
                        .help(L("Showing only changes belonging to the selected AI group", "当前仅展示所选 AI 分组的改动，其他改动已完全隐藏"))
                    }

                    if doc.hiddenCommentHunkCount > 0 {
                        let count = doc.hiddenCommentHunkCount
                        SemanticPill(
                            symbol: "text.bubble",
                            label: count == 1
                                ? L("1 comment change hidden", "已隐藏 1 处注释变更")
                                : L("\(count) comment changes hidden", "已隐藏 \(count) 处注释变更"),
                            tint: Color.difAccent,
                            bg: Color.difAccent.opacity(0.10),
                            border: Color.difAccent.opacity(0.28),
                            help: L("Click to show comment changes", "点击取消隐藏，显示注释变更")
                        ) {
                            viewer.toggleIgnoreComments()
                        }
                    }

                    if doc.isJSONNormalized {
                        SemanticPill(
                            symbol: "curlybraces",
                            label: L("JSON Normalized (Read-Only)", "JSON 已规范化（只读）"),
                            tint: Color.difAccent,
                            bg: Color.difAccent.opacity(0.10),
                            border: Color.difAccent.opacity(0.28),
                            help: L("Click to return to raw editable JSON", "点击关闭规范化，恢复原始可编辑 JSON")
                        ) {
                            viewer.toggleNormalizeJSON()
                        }
                    }

                    if viewer.movedPairCount > 0 {
                        let count = viewer.movedPairCount
                        SemanticPill(
                            symbol: "arrow.left.arrow.right",
                            label: count == 1
                                ? L("1 moved block", "检测到 1 处移动")
                                : L("\(count) moved blocks", "检测到 \(count) 处移动"),
                            tint: Color.difMovedAccent,
                            bg: Color.difMovedBg,
                            border: Color.difMovedBorder.opacity(0.65),
                            help: L("Click to jump between moved blocks", "点击在移动代码块之间跳转")
                        ) {
                            viewer.stepMovedHunk()
                        }
                    }

                    if !doc.renameGroups.isEmpty {
                        let count = doc.renameGroups.count
                        SemanticPill(
                            symbol: "tag",
                            label: count == 1
                                ? L("1 rename group", "1 组重命名")
                                : L("\(count) rename groups", "\(count) 组重命名"),
                            tint: Color.difRenameAccent(at: doc.renameGroups[0].colorIndex),
                            bg: Color.difRenameAccent(at: doc.renameGroups[0].colorIndex).opacity(0.12),
                            border: Color.difRenameAccent(at: doc.renameGroups[0].colorIndex).opacity(0.35),
                            help: L("Inspect and jump to cross-hunk identifier renames", "查看并跳转到跨区块标识符重命名")
                        ) {
                            showRenamePopover.toggle()
                        }
                        .popover(isPresented: $showRenamePopover, arrowEdge: .bottom) {
                            RenameGroupsPopover(groups: doc.renameGroups) { group in
                                showRenamePopover = false
                                viewer.jumpToRenameGroup(group)
                            }
                        }
                    }

                    if viewer.hiddenFoldLineCount > 0 {
                        let hidden = viewer.hiddenFoldLineCount
                        SemanticPill(
                            symbol: "rectangle.expand.vertical",
                            label: L("\(hidden) lines folded · Expand", "已折叠 \(hidden) 行 · 展开"),
                            tint: Color.difFoldText,
                            bg: Color.difFoldBg,
                            border: Color.difHairline,
                            help: L("Expand all collapsed unchanged sections", "展开全部折叠的未变更代码段")
                        ) {
                            viewer.expandAllFolds()
                        }
                    }

                    if !viewer.changedSymbols.isEmpty {
                        ChangedSymbolsMenu(symbols: viewer.changedSymbols) { item in
                            viewer.jumpToChangedSymbol(item)
                        } onShowAll: {
                            store.showFileSymbols()
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: UI.s(26))
            .background(Color.difPanel.opacity(0.65))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.difHairline.opacity(0.75)).frame(height: 1) }
        }
    }
}

private struct SemanticPill: View {
    var symbol: String
    var label: String
    var tint: Color
    var bg: Color
    var border: Color
    var help: String
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5 * UI.scale, weight: .semibold))
                Text(label)
                    .font(.ui(size: 10.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(hovered ? tint.opacity(0.18) : bg))
            .overlay(Capsule().strokeBorder(border, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct RenameGroupsPopover: View {
    let groups: [RenameGroup]
    let onSelect: (RenameGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Detected Cross-Hunk Renames", "检测到的跨区块重命名"))
                .font(.ui(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.difText2)
                .padding(.horizontal, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(groups) { group in
                        Button {
                            onSelect(group)
                        } label: {
                            HStack(spacing: 7) {
                                Circle()
                                    .fill(Color.difRenameAccent(at: group.colorIndex))
                                    .frame(width: 7, height: 7)
                                Text(group.oldName)
                                    .font(.code(11))
                                    .foregroundStyle(Color.difText2)
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.difText3)
                                Text(group.newName)
                                    .font(.code(11, weight: .semibold))
                                    .foregroundStyle(Color.difText)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                Text("×\(group.occurrenceCount)")
                                    .font(.ui(size: 10, weight: .medium, design: .rounded))
                                    .foregroundStyle(Color.difRenameAccent(at: group.colorIndex))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.difRenameAccent(at: group.colorIndex).opacity(0.14)))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difHover))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(10)
        .frame(minWidth: 260, maxWidth: 380)
    }
}

private struct ChangedSymbolsMenu: View {
    let symbols: [ChangedFileSymbol]
    let onSelect: (ChangedFileSymbol) -> Void
    let onShowAll: () -> Void
    @State private var hovered = false

    var body: some View {
        let count = symbols.count
        Menu {
            ForEach(symbols.prefix(40)) { item in
                Button {
                    onSelect(item)
                } label: {
                    let hunks = item.hunkIndices.count
                    let suffix = hunks == 1 ? L("1 change", "1 处改动") : L("\(hunks) changes", "\(hunks) 处改动")
                    Text("\(item.symbol.name)  ·  L\(item.symbol.lineNumber) (\(suffix))")
                }
            }
            Divider()
            Button(L("All File Symbols… (⌘R)", "全部文件符号… (⌘R)")) {
                onShowAll()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "function")
                    .font(.system(size: 9.5 * UI.scale, weight: .semibold))
                Text(count == 1 ? L("1 changed symbol", "1 个变更符号") : L("\(count) changed symbols", "\(count) 个变更符号"))
                    .font(.ui(size: 10.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8 * UI.scale, weight: .semibold))
            }
            .foregroundStyle(Color.difText2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(hovered ? Color.difHover : Color.difChip))
            .overlay(Capsule().strokeBorder(Color.difHairline, lineWidth: 0.75))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .help(L("Jump to symbols modified in this diff", "跳转到本次变更涉及的符号"))
    }
}
