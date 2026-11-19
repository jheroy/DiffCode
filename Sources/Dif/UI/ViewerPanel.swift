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
        VStack(spacing: 0) {
            ViewerHeader(project: project)
            Rectangle().fill(Color.difHairline).frame(height: 1)
            if viewer.showsConflicts, let request = viewer.request, request.root == project.url {
                ConflictBar(project: project, path: request.path)
            }
            if viewer.findVisible { FindBar() }
            if let doc = viewer.document, case .text = doc.content, !doc.isPlainFile, !doc.isAddedOnly {
                PaneTitles(left: doc.leftTitle, right: doc.rightTitle, unified: store.settings.unified)
            }
            ZStack {
                // Always mounted, so switching between a diff and an image never rebuilds the canvas.
                CanvasHost { viewer.attach($0) }
                overlay(viewer)
                if let hover = viewer.annotationHover {
                    AnnotationCard(hover: hover, lineHeight: (store.settings.fontSize * 1.5).rounded())
                }
            }
            if store.settings.showLineDiffBar, let snapshot = viewer.lineDiffSnapshot {
                LineDiffBarView(
                    snapshot: snapshot,
                    theme: colorScheme == .dark ? .dark : .light,
                    codeFont: CodeFont.current(store.settings),
                    onClose: {
                        store.settings.showLineDiffBar = false
                        store.settings.save()
                    }
                )
            }
            if viewer.vimModeEnabled && viewer.isTextDocument {
                VimStatusBar(viewer: viewer)
            }
        }
        .background(Color.difWindow)
    }

    @ViewBuilder
    private func overlay(_ viewer: ViewerModel) -> some View {
        if viewer.request == nil {
            ViewerEmptyState(project: project).background(Color.difWindow)
        } else if let doc = viewer.document {
            switch doc.content {
            case .image(let old, let new):
                ImageDiffView(old: old, new: new, leftTitle: doc.leftTitle, rightTitle: doc.rightTitle).background(Color.difWindow)
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
            if viewer.request != nil {
                if viewer.loadMilliseconds > 0 {
                    // Load time, shown because being fast is the point.
                    Text(String(format: "%.0f ms", viewer.loadMilliseconds))
                        .font(.ui(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.difText3)
                        .help(L("Time to load, diff and highlight this file", "加载、比较并高亮这个文件所用的时间"))
                }
                if viewer.isTextDocument {
                    IconButton(symbol: "arrow.left", help: L("Previous file (⇧⌘[)", "上一个文件 (⇧⌘[)")) { store.stepFile(-1) }
                    IconButton(symbol: "arrow.right", help: L("Next file (⇧⌘])", "下一个文件 (⇧⌘])")) { store.stepFile(1) }
                }
                if viewer.isTextDocument, let doc = viewer.document, !doc.isPlainFile {
                    IconButton(symbol: "arrow.up", help: L("Previous Difference (⇧F7)", "上一处差异 (⇧F7)")) { viewer.stepDifference(-1) }
                    IconButton(symbol: "arrow.down", help: L("Next Difference (F7)", "下一处差异 (F7)")) { viewer.stepDifference(1) }
                    Divider().frame(height: 14)
                    IconButton(symbol: "rectangle.split.2x1", help: L("Side-by-Side (⌥⌘V)", "并排视图 (⌥⌘V)"), isActive: !store.settings.unified) {
                        if store.settings.unified { viewer.toggleUnified() }
                    }
                    IconButton(symbol: "rectangle.grid.1x2", help: L("Unified (⌥⌘V)", "合并视图 (⌥⌘V)"), isActive: store.settings.unified) {
                        if !store.settings.unified { viewer.toggleUnified() }
                    }
                    if !doc.isAddedOnly {
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
                IconButton(symbol: "magnifyingglass", help: L("Find in File (⌘F)", "在文件中查找 (⌘F)"), isActive: viewer.findVisible) {
                    if viewer.findVisible { viewer.hideFind() } else { viewer.showFind() }
                }
                if AppEnvironment.hasTerminal {
                    Divider().frame(height: 14)
                }
            }
            if AppEnvironment.hasTerminal {
                TerminalToggle(project: project)
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
            (L("Go to File", "查找文件"), "⇧⌘O"),
            (L("Find in Files", "在文件中查找"), "⇧⌘F"),
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
        case .visual, .visualLine: return Color.purple
        case .commandLine: return Color.orange
        }
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

            if case .commandLine(let prefix, let buffer) = viewer.vimMode {
                HStack(spacing: 0) {
                    Text(prefix + buffer)
                        .font(.code(11.5))
                        .foregroundStyle(Color.difText)
                    Rectangle()
                        .fill(Color.difText.opacity(0.75))
                        .frame(width: 6, height: UI.s(12))
                }
                .lineLimit(1)
            }

            Spacer(minLength: 8)

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
