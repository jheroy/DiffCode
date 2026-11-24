import SwiftUI

/// Dims the window and floats the active popup near the top, Spotlight-style.
struct PopupLayer: View {
    var popup: Popup
    @Environment(AppStore.self) private var store

    var body: some View {
        switch popup {
        case .gitGraph:
            GitGraphLayer()
        case .dialog:
            if let request = store.dialog {
                ZStack {
                    Color.black.opacity(0.28)
                        .contentShape(Rectangle())
                        .onTapGesture { store.answerDialog(confirmed: false) }
                    DialogView(request: request)
                        .frame(width: UI.s(440))
                        .popupPanel()
                        .padding(24)
                }
            }
        default:
            ZStack(alignment: .top) {
                Color.black.opacity(0.22)
                    .contentShape(Rectangle())
                    .onTapGesture { store.dismissPopup() }
                switch popup {
                case .quickOpen:
                    ResizablePopup(spec: .quickOpen) { QuickOpenView() }
                case .findInPath:
                    ResizablePopup(spec: .findInPath) { FindInPathView() }
                case .references:
                    ResizablePopup(spec: .references) { ReferencesPopupView() }
                case .fileSymbols:
                    ResizablePopup(spec: .fileSymbols) { FileSymbolsPopupView() }
                case .selectionHistory:
                    ResizablePopup(spec: .selectionHistory) { SelectionHistoryPopupView() }
                case .goToLine, .keymap, .settings:
                    Group {
                        switch popup {
                        case .goToLine: GoToLineView().frame(width: UI.s(320))
                        case .keymap: KeymapView().frame(width: UI.s(720))
                        case .settings: SettingsView().frame(width: UI.s(540))
                        default: EmptyView()
                        }
                    }
                    .popupPanel()
                    .padding(.top, 90)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24) // so a tall popup shrinks (and scrolls) in a short window
                case .gitGraph, .dialog:
                    EmptyView()
                }
            }
        }
    }
}

// MARK: - Quick open

struct QuickOpenView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var model = store.quickOpen
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.ui(size: 15, weight: .medium)).foregroundStyle(Color.difText2)
                SearchField(text: $model.query, placeholder: placeholder(model.scope), font: .systemFont(ofSize: 16 * UI.scale),
                            focusToken: model.focusToken,
                            onMove: { model.move($0) },
                            onSubmit: { model.activate() },
                            onCancel: { store.dismissPopup() },
                            onTab: { model.cycleScope($0 ? -1 : 1) })
                    .frame(height: UI.s(24))
                if model.isIndexing { ProgressView().controlSize(.small).scaleEffect(0.7) }
                if model.scope != .recent, model.scope != .branches, model.scope != .stashes {
                    HStack(spacing: 2) {
                        ScopeTab(title: L("All", "全部"), isSelected: model.scope == .all) { model.setScope(.all) }
                        ScopeTab(title: L("Files", "文件"), isSelected: model.scope == .files) { model.setScope(.files) }
                        ScopeTab(title: L("Symbols", "符号"), isSelected: model.scope == .symbols) { model.setScope(.symbols) }
                        ScopeTab(title: L("Actions", "操作"), isSelected: model.scope == .actions) { model.setScope(.actions) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .frame(height: UI.s(52))

            Rectangle().fill(Color.difHairline).frame(height: 1)

            if model.items.isEmpty {
                Text(emptyText(model))
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                                QuickOpenRow(item: item, isSelected: index == model.selected)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.activate(index) }
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.selected) { _, index in
                        if model.items.indices.contains(index) {
                            proxy.scrollTo(model.items[index].id)
                        }
                    }
                    .onChange(of: model.items.first?.id) { _, _ in
                        if model.items.indices.contains(model.selected) {
                            proxy.scrollTo(model.items[model.selected].id, anchor: .top)
                        } else if let firstID = model.items.first?.id {
                            proxy.scrollTo(firstID, anchor: .top)
                        }
                    }
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)
            HStack(spacing: 14) {
                Hint(keys: "↑↓", text: L("Navigate", "选择"))
                if model.scope == .branches {
                    Hint(keys: "↩", text: L("Compare", "比较"))
                    Spacer()
                    Text(L("Branches compare from where they forked from HEAD · or type a commit", "分支从与 HEAD 的分叉点开始比较 · 也可输入提交哈希"))
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                } else if model.scope == .stashes {
                    Hint(keys: "↩", text: L("View", "查看"))
                    Spacer()
                    Text(L("Apply, pop or drop it from the bar over the list", "在列表上方的横条里应用、弹出或删除"))
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                } else {
                    Hint(keys: "↩", text: L("Open", "打开"))
                    Hint(keys: "⇥", text: L("Switch tab", "切换标签"))
                    Spacer()
                    Text(L("Tip: add :42 to jump to a line", "提示：末尾加 :42 可直接跳到该行"))
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(30))
        }
    }

    private func placeholder(_ scope: QuickOpenModel.Scope) -> String {
        switch scope {
        case .all: return L("Search files and actions", "搜索文件和操作")
        case .files: return L("Go to file — try abbreviations like \"mavm\"", "查找文件 — 支持缩写，例如 mavm")
        case .symbols: return L("Go to symbol — functions, types, methods…", "查找符号 — 函数、结构体、方法…")
        case .actions: return L("Find an action", "查找操作")
        case .recent: return L("Recent files", "最近的文件")
        case .branches: return L("Compare the working tree with a branch, tag or commit", "将工作区与分支、标签或提交比较")
        case .stashes: return L("Stashes", "Stash 列表")
        }
    }

    private func emptyText(_ model: QuickOpenModel) -> String {
        if model.scope == .branches {
            return model.isIndexing ? L("Reading branches…", "正在读取分支…") : L("No branches · type a commit hash", "没有分支 · 可输入提交哈希")
        }
        if model.scope == .stashes {
            if model.isIndexing { return L("Reading stashes…", "正在读取 stash…") }
            return model.query.isEmpty ? L("No stashes", "没有 stash") : L("Nothing found", "没有找到")
        }
        if model.isIndexing {
            return model.scope == .symbols ? L("Indexing symbols…", "正在索引符号…") : L("Indexing files…", "正在索引文件…")
        }
        return model.query.isEmpty ? L("Type to search", "输入以搜索") : L("Nothing found", "没有找到")
    }
}

private struct ScopeTab: View {
    var title: String
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.difText : Color.difText2)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isSelected ? Color.difChip : Color.clear))
        }
        .buttonStyle(.plain)
    }
}

private struct Hint: View {
    var keys: String
    var text: String

    var body: some View {
        HStack(spacing: 4) {
            KeyCaps(shortcut: keys, size: 10)
            Text(text).font(.ui(size: 11)).foregroundStyle(Color.difText3)
        }
    }
}

private struct QuickOpenRow: View {
    var item: QuickOpenModel.Item
    var isSelected: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 9) {
            switch item {
            case .file(let projectID, let path, let positions, let kind):
                let name = (path as NSString).lastPathComponent
                let directory = (path as NSString).deletingLastPathComponent
                FileIcon(path: path, size: 13)
                Text(FuzzyHighlight.text(name, positions: positions, offset: path.utf8.count - name.utf8.count, base: Color.status(kind)))
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(FuzzyHighlight.text(directory, positions: positions, offset: 0, base: Color.difText3, size: 11.5))
                    .font(.ui(size: 11.5))
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if projectID != store.selectedProjectID, let owner = store.project(projectID) {
                    Text(owner.name).font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                }
                if let kind {
                    Text(kind.letter).font(.ui(size: 10.5, weight: .bold, design: .rounded)).foregroundStyle(Color.status(kind))
                }
            case .excelSheet(let projectID, let path, let sheetName, let positions):
                Image(systemName: "tablecells")
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difAdded)
                    .frame(width: UI.s(18))
                Text(FuzzyHighlight.text(sheetName, positions: positions, offset: 0, base: Color.difText))
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text("(\(path))")
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 6)
                if projectID != store.selectedProjectID, let owner = store.project(projectID) {
                    Text(owner.name).font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                }
                Text(L("Sheet", "工作表"))
                    .font(.ui(size: 10, weight: .semibold))
                    .foregroundStyle(Color.difAdded)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.difAdded.opacity(0.14)))
            case .symbol(let projectID, let symbol, let positions):
                Text(symbol.kind.badge)
                    .font(.ui(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: UI.s(16), height: UI.s(16))
                    .background(Circle().fill(symbol.kind.accentColor))
                    .frame(width: UI.s(18))
                Text(FuzzyHighlight.text(symbol.name, positions: positions, offset: 0, base: Color.difText))
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(symbol.detail)
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if projectID != store.selectedProjectID, let owner = store.project(projectID) {
                    Text(owner.name).font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                }
                Text("\(symbol.path):\(symbol.line)")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: UI.s(260), alignment: .trailing)
            case .action(let command):
                Image(systemName: command.symbol)
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(18))
                Text(command.title).font(.ui(size: 13)).foregroundStyle(Color.difText).lineLimit(1)
                Spacer(minLength: 6)
                KeyCaps(shortcut: command.shortcut)
            case .ref(let ref, let positions):
                Image(systemName: ref.kind == .tag ? "tag" : (ref.kind == .remote ? "cloud" : "arrow.triangle.branch"))
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(18))
                Text(FuzzyHighlight.text(ref.shortName, positions: positions, offset: 0, base: Color.difText))
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if ref.isHead {
                    Text(L("current", "当前")).font(.ui(size: 10.5, weight: .semibold)).foregroundStyle(Color.difAdded)
                }
                Spacer(minLength: 6)
                Text(ref.date.formatted(.relative(presentation: .named)))
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
            case .revision(let text):
                Image(systemName: "number")
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(18))
                Text(L("Compare with commit “\(text)”", "与提交“\(text)”比较")).font(.ui(size: 13)).foregroundStyle(Color.difText).lineLimit(1)
                Spacer(minLength: 6)
            case .stash(let entry, let positions):
                Image(systemName: "tray.full")
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(18))
                Text(FuzzyHighlight.text(entry.title, positions: positions, offset: 0, base: Color.difText))
                    .font(.ui(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text([entry.branch.map { L("on \($0)", "在 \($0)") }, entry.untracked != nil ? L("with new files", "含新文件") : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
            case .stashChanges(let count):
                Image(systemName: "tray.and.arrow.down")
                    .font(.ui(size: 12))
                    .foregroundStyle(Color.difAccent)
                    .frame(width: UI.s(18))
                Text(L("Stash Local Changes…", "Stash 本地改动…")).font(.ui(size: 13)).foregroundStyle(Color.difText).lineLimit(1)
                Text(count == 1 ? L("1 file", "1 个文件") : L("\(count) files", "\(count) 个文件"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                Spacer(minLength: 6)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(30))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.difSelection : Color.clear)
                .padding(.horizontal, 6)
        )
    }
}

/// Text styling goes through the attribute keys (`text[Attr.Foreground.self] = …`): the shorthand
/// `text.foregroundColor = …` forms key paths that SwiftUI has not marked Sendable, which the race checker flags.
enum Attr {
    typealias Foreground = AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute
    typealias Background = AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute
    typealias Font = AttributeScopes.SwiftUIAttributes.FontAttribute
    typealias Ligature = AttributeScopes.AppKitAttributes.LigatureAttribute
}

@MainActor
enum FuzzyHighlight {
    /// Emphasises the characters the fuzzy matcher landed on. `positions` are byte offsets into the full path.
    static func text(
        _ text: String,
        positions: [Int],
        offset: Int,
        base: Color,
        size: CGFloat = 13,
        weight: Font.Weight = .regular
    ) -> AttributedString {
        var result = AttributedString(text)
        result[Attr.Foreground.self] = base
        if weight != .regular {
            result[Attr.Font.self] = .ui(size: size, weight: weight)
        }
        guard !positions.isEmpty else { return result }
        let utf8 = text.utf8
        for position in positions {
            let local = position - offset
            guard local >= 0, local < utf8.count else { continue }
            let start = utf8.index(utf8.startIndex, offsetBy: local)
            guard let lower = start.samePosition(in: text), lower < text.endIndex else { continue }
            let upper = text.index(after: lower)
            if let range = Range(lower..<upper, in: result) {
                result[range][Attr.Foreground.self] = Color.difAccent
                result[range][Attr.Font.self] = .ui(size: size, weight: .bold)
            }
        }
        return result
    }
}

// MARK: - Find in Files

/// Hosts the read-only preview canvas inside the Find in Files popup.
private struct PreviewHost: NSViewRepresentable {
    var attach: (CodeScrollContainer) -> Void

    func makeNSView(context: Context) -> CodeScrollContainer {
        let container = CodeScrollContainer(frame: .zero)
        attach(container)
        return container
    }

    func updateNSView(_ view: CodeScrollContainer, context: Context) {}
}

struct FindInPathView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("popupSplit.findInPath") private var splitRatio: Double = 0.45

    var body: some View {
        @Bindable var model = store.finder
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "text.magnifyingglass").font(.ui(size: 15, weight: .medium)).foregroundStyle(Color.difText2)
                SearchField(text: $model.query, placeholder: L("Find in files", "在文件中查找"), font: .systemFont(ofSize: 16 * UI.scale),
                            focusToken: model.focusToken,
                            onMove: { model.move($0) },
                            onSubmit: { model.activate() },
                            onCancel: { store.dismissPopup() })
                    .frame(height: UI.s(24))
                OptionToggle(label: "Aa", help: L("Match case", "区分大小写"), isOn: model.options.caseSensitive) {
                    model.options.caseSensitive.toggle()
                    model.search()
                }
                OptionToggle(label: "W", help: L("Whole words", "全词匹配"), isOn: model.options.wholeWord) {
                    model.options.wholeWord.toggle()
                    model.search()
                }
                OptionToggle(label: ".*", help: L("Regular expression", "正则表达式"), isOn: model.options.regex) {
                    model.options.regex.toggle()
                    model.search()
                }
            }
            .padding(.horizontal, 16)
            .frame(height: UI.s(52))

            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "doc").font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                    TextField(L("File mask, e.g. *.kt", "文件过滤，例如 *.kt"), text: $model.options.fileMask)
                        .textFieldStyle(.plain)
                        .font(.ui(size: 12))
                        .frame(width: UI.s(150))
                        .onSubmit { model.search() }
                }
                .padding(.horizontal, 8)
                .frame(height: UI.s(24))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                if store.projects.count > 1 {
                    HStack(spacing: 2) {
                        ScopeTab(title: L("This Project", "当前项目"), isSelected: !model.allProjects) {
                            model.allProjects = false
                            model.search()
                        }
                        ScopeTab(title: L("All Projects", "所有项目"), isSelected: model.allProjects) {
                            model.allProjects = true
                            model.search()
                        }
                    }
                }
                GoFileFilterPills(excludeTestGo: $model.excludeTestGo, onlyGoFiles: $model.onlyGoFiles)
                Spacer()
                if model.isSearching { ProgressView().controlSize(.small).scaleEffect(0.65) }
                Text(summary(model))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(model.errorText == nil ? Color.difText3 : Color.difRemoved)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            GeometryReader { geo in
                let previewHeaderHeight = UI.s(26)
                let availableHeight = max(144, geo.size.height - previewHeaderHeight - 1)
                let listHeight = PopupResizeGeometry.splitListHeight(
                    availableHeight: availableHeight,
                    ratio: splitRatio
                )

                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                                    FindHitRow(hit: hit, isSelected: index == model.selected,
                                               projectName: model.allProjects ? store.project(hit.projectID)?.name : nil)
                                        .id(index)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.select(index)
                                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { model.activate() }
                                        }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: listHeight)
                        .onChange(of: model.selected) { _, index in proxy.scrollTo(index) }
                    }

                    PopupSplitDivider(availableHeight: availableHeight, ratio: $splitRatio)

                    HStack(spacing: 6) {
                        if !model.previewPath.isEmpty {
                            FileIcon(path: model.previewPath, size: 11)
                            Text(model.previewPath).font(.ui(size: 11.5)).foregroundStyle(Color.difText2).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: previewHeaderHeight)
                    .background(Color.difPanel.opacity(0.6))

                    ZStack {
                        PreviewHost { model.attachPreview($0) }
                        if model.previewDocument == nil {
                            Color.difWindow
                            Text(model.query.count < 2 ? L("Type at least two characters", "至少输入两个字符") : (model.isSearching ? "" : L("No matches", "没有匹配项")))
                                .font(.ui(size: 12.5))
                                .foregroundStyle(Color.difText3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)
            HStack(spacing: 14) {
                Hint(keys: "↑↓", text: L("Navigate", "选择"))
                Hint(keys: "↩", text: L("Open in viewer", "在查看器中打开"))
                Hint(keys: "Esc", text: L("Close", "关闭"))
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(30))
        }
        .onChange(of: model.query) { _, _ in model.queryChanged() }
    }

    private func summary(_ model: FindInPathModel) -> String {
        if let error = model.errorText { return error }
        guard !model.hits.isEmpty else {
            return model.totalHitCount > 0
                ? L("0 of \(model.totalHitCount) matches", "0 / \(model.totalHitCount) 处匹配")
                : ""
        }
        let count = model.truncated ? "\(model.hits.count)+" : "\(model.hits.count)"
        if model.fileFilter.isActive && model.hits.count != model.totalHitCount {
            return L("\(count) / \(model.totalHitCount) matches in \(model.fileCount) files", "\(model.fileCount) 个文件中有 \(count) / \(model.totalHitCount) 处匹配")
        }
        return L("\(count) matches in \(model.fileCount) files", "\(model.fileCount) 个文件中有 \(count) 处匹配")
    }
}

private struct GoFileFilterPills: View {
    @Binding var excludeTestGo: Bool
    @Binding var onlyGoFiles: Bool

    var body: some View {
        HStack(spacing: 5) {
            FilterPillToggle(
                label: "!*test.go",
                help: L("Exclude *test.go files", "过滤 *test.go 文件"),
                isOn: excludeTestGo
            ) {
                excludeTestGo.toggle()
            }
            FilterPillToggle(
                label: "*.go",
                help: L("Go files only", "仅显示 .go 文件"),
                isOn: onlyGoFiles
            ) {
                onlyGoFiles.toggle()
            }
        }
    }
}

private struct FilterPillToggle: View {
    var label: String
    var help: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.ui(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Color.difAccent : Color.difText2)
                .padding(.horizontal, 7)
                .frame(height: UI.s(24))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Color.difAccent.opacity(0.16) : Color.difChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isOn ? Color.difAccent.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct OptionToggle: View {
    var label: String
    var help: String
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.ui(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Color.difAccent : Color.difText2)
                .frame(width: UI.s(28), height: UI.s(24))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? Color.difSelection : Color.difChip))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct FindHitRow: View {
    var hit: FindInPathModel.Hit
    var isSelected: Bool
    var projectName: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(snippet)
                .font(.code(12))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let projectName {
                Text(projectName).font(.ui(size: 10.5)).foregroundStyle(Color.difText3).lineLimit(1)
            }
            Text(hit.path)
                .font(.ui(size: 11.5))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: UI.s(280), alignment: .trailing)
            Text("\(hit.line)")
                .font(.ui(size: 11, design: .monospaced))
                .foregroundStyle(Color.difText3)
                .frame(minWidth: 34, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: UI.s(24))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.difSelection : Color.clear)
                .padding(.horizontal, 6)
        )
        .help(hit.path)
    }

    private var snippet: AttributedString {
        let ns = hit.text as NSString
        guard let match = hit.match, match.upperBound <= ns.length else {
            var plain = AttributedString(String(hit.text.prefix(240)))
            plain[Attr.Foreground.self] = Color.difText
            return plain
        }
        var before = AttributedString(ns.substring(to: match.lowerBound))
        before[Attr.Foreground.self] = Color.difText2
        var middle = AttributedString(ns.substring(with: NSRange(location: match.lowerBound, length: match.count)))
        middle[Attr.Foreground.self] = Color.difText
        middle[Attr.Background.self] = Color(NSColor(hex: 0xE8B339, alpha: 0.38))
        let tailEnd = min(ns.length, match.upperBound + 200)
        var after = AttributedString(ns.substring(with: NSRange(location: match.upperBound, length: tailEnd - match.upperBound)))
        after[Attr.Foreground.self] = Color.difText2
        return before + middle + after
    }
}

// MARK: - LSP References & Definitions Picker

struct ReferencesPopupView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("popupSplit.references") private var splitRatio: Double = 0.45

    var body: some View {
        @Bindable var model = store.references
        VStack(spacing: 0) {
            // Header: title + count + filter field + close button
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.ui(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.difAccent)

                Text(model.title)
                    .font(.ui(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(countLabel(model))
                    .font(.ui(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.difChip))

                Spacer(minLength: 8)

                GoFileFilterPills(excludeTestGo: $model.excludeTestGo, onlyGoFiles: $model.onlyGoFiles)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                    SearchField(
                        text: $model.filterQuery,
                        placeholder: L("Filter by path or code…", "按路径或代码过滤…"),
                        font: .systemFont(ofSize: 12.5 * UI.scale),
                        focusToken: model.focusToken,
                        onMove: { model.move($0) },
                        onSubmit: { model.activate() },
                        onCancel: { store.dismissPopup() }
                    )
                    .frame(width: UI.s(175), height: UI.s(20))
                    if !model.filterQuery.isEmpty {
                        Button {
                            model.filterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.ui(size: 11))
                                .foregroundStyle(Color.difText3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: UI.s(26))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))

                Button {
                    store.dismissPopup()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(Color.difText2)
                        .frame(width: UI.s(24), height: UI.s(24))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                }
                .buttonStyle(.plain)
                .help(L("Close (Esc)", "关闭 (Esc)"))
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(46))

            Rectangle().fill(Color.difHairline).frame(height: 1)

            GeometryReader { geo in
                let previewHeaderHeight = UI.s(28)
                let availableHeight = max(144, geo.size.height - previewHeaderHeight - 1)
                let listHeight = PopupResizeGeometry.splitListHeight(
                    availableHeight: availableHeight,
                    ratio: splitRatio
                )

                VStack(spacing: 0) {
                    // Top section: scrollable reference list
                    if model.filteredItems.isEmpty {
                        VStack(spacing: 6) {
                            Text(L("No matching references", "没有匹配的引用"))
                                .font(.ui(size: 12.5))
                                .foregroundStyle(Color.difText3)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: listHeight)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                        ReferenceItemRow(item: item, isSelected: index == model.selectedIndex)
                                            .id(item.id)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                model.select(index)
                                                if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                                    model.activate(index)
                                                }
                                            }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(height: listHeight)
                            .onChange(of: model.selectedIndex) { _, _ in
                                if let id = model.selectedItem?.id {
                                    proxy.scrollTo(id)
                                }
                            }
                        }
                    }

                    PopupSplitDivider(availableHeight: availableHeight, ratio: $splitRatio)

                    // Preview sub-header with path:line and explicit Jump button
                    HStack(spacing: 8) {
                        if let item = model.selectedItem {
                            FileIcon(path: item.displayPath, size: 11.5)
                            Text("\(item.displayPath):\(item.lineNumber)")
                                .font(.ui(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.difText2)
                                .lineLimit(1)
                                .truncationMode(.head)
                            if item.isDeclaration {
                                Text(L("Declaration", "声明"))
                                    .font(.ui(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.difAccent)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Color.difAccent.opacity(0.14)))
                            }
                        }
                        Spacer(minLength: 8)
                        if model.selectedItem != nil {
                            Button {
                                model.activate()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(L("Jump", "跳转"))
                                        .font(.ui(size: 11, weight: .semibold))
                                    Text("⏎")
                                        .font(.ui(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(Color.difAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difAccent.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: previewHeaderHeight)
                    .background(Color.difPanel.opacity(0.65))

                    // Bottom section: full-file syntax-highlighted code preview
                    ZStack {
                        PreviewHost { model.attachPreview($0) }
                        if model.previewDocument == nil {
                            Color.difWindow
                            Text(model.isLoadingPreviews
                                 ? L("Loading preview…", "正在加载预览…")
                                 : (model.filteredItems.isEmpty
                                    ? L("No matching references", "没有匹配的引用")
                                    : L("Preview unavailable", "无法预览该文件")))
                                .font(.ui(size: 12.5))
                                .foregroundStyle(Color.difText3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)

            // Footer hints
            HStack(spacing: 14) {
                Hint(keys: "↑↓", text: L("Preview", "预览"))
                Hint(keys: "⏎", text: L("or Double-Click Jump", "或双击跳转"))
                Hint(keys: "Esc", text: L("Close", "关闭"))
                Spacer()
                if model.isLoadingPreviews {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(30))
        }
    }

    private func countLabel(_ model: ReferencesPickerModel) -> String {
        let isFiltered = !model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.fileFilter.isActive
        if !isFiltered {
            return "\(model.items.count)"
        }
        return "\(model.filteredItems.count) / \(model.items.count)"
    }
}

private struct ReferenceItemRow: View {
    var item: ReferenceItem
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(path: item.displayPath, size: 12)

            Text(previewSnippet)
                .font(.code(12))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if item.isDeclaration {
                Text(L("Def", "声明"))
                    .font(.ui(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.difAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.difAccent.opacity(0.14)))
            }

            Spacer(minLength: 8)

            Text(item.displayPath)
                .font(.ui(size: 11.5))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 260, alignment: .trailing)

            Text(":\(item.lineNumber)")
                .font(.ui(size: 11, design: .monospaced))
                .foregroundStyle(Color.difText3)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(26))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.difSelection : Color.clear)
                .padding(.horizontal, 6)
        )
        .help("\(item.displayPath):\(item.lineNumber)")
    }

    private var previewSnippet: AttributedString {
        guard !item.linePreview.isEmpty else {
            var placeholder = AttributedString("…")
            placeholder[Attr.Foreground.self] = Color.difText3
            return placeholder
        }
        let ns = item.linePreview as NSString
        guard let match = item.matchRangeInPreview,
              match.lowerBound >= 0,
              match.upperBound <= ns.length,
              match.lowerBound < match.upperBound else {
            var plain = AttributedString(String(item.linePreview.prefix(240)))
            plain[Attr.Foreground.self] = Color.difText
            return plain
        }
        var before = AttributedString(ns.substring(to: match.lowerBound))
        before[Attr.Foreground.self] = Color.difText2
        var middle = AttributedString(ns.substring(with: NSRange(location: match.lowerBound, length: match.count)))
        middle[Attr.Foreground.self] = Color.difText
        middle[Attr.Background.self] = Color(NSColor.dyn(0xF5C242, 0xE8B339, lightAlpha: 0.42, darkAlpha: 0.36))
        let tailEnd = min(ns.length, match.upperBound + 200)
        var after = AttributedString(ns.substring(with: NSRange(location: match.upperBound, length: tailEnd - match.upperBound)))
        after[Attr.Foreground.self] = Color.difText2
        return before + middle + after
    }
}

private struct ReferenceCodePreviewView: View {
    var context: ReferencePreviewContext?
    var isLoading: Bool
    var settings: Settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme: CanvasTheme = colorScheme == .dark ? .dark : .light
        let codeFont = CodeFont.current(settings)
        ZStack {
            Color(cgColor: theme.background)
            if let context, !context.lines.isEmpty {
                let maxDigits = max(3, String(context.lines.last?.lineNumber ?? 1).count)
                let gutterWidth = max(38, CGFloat(maxDigits) * codeFont.charWidth + 16)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(context.lines) { line in
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(line.isMatchedLine ? Color.difAccent : Color.clear)
                                    .frame(width: 2.5)

                                Text("\(line.lineNumber)")
                                    .font(Font(codeFont.font))
                                    .foregroundStyle(Color(cgColor: line.isMatchedLine ? theme.gutterTextStrong : theme.gutterText))
                                    .frame(width: gutterWidth, alignment: .trailing)
                                    .padding(.trailing, 12)

                                Text(highlightedLine(line, theme: theme, language: context.language, codeFont: codeFont))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)

                                Spacer(minLength: 20)
                            }
                            .frame(minHeight: codeFont.lineHeight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.isMatchedLine ? Color(cgColor: theme.focusLine) : Color.clear)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Text(isLoading ? L("Loading preview…", "正在加载预览…") : L("Preview unavailable", "无法预览该文件"))
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText3)
            }
        }
    }

    private func highlightedLine(
        _ line: ReferencePreviewLine,
        theme: CanvasTheme,
        language: LanguageSpec,
        codeFont: CodeFont
    ) -> AttributedString {
        if line.text.isEmpty {
            var empty = AttributedString(" ")
            empty[Attr.Font.self] = Font(codeFont.regularFont as NSFont)
            return empty
        }
        var result = AttributedString(line.text)
        result[Attr.Foreground.self] = Color(cgColor: theme.text)
        result[Attr.Font.self] = Font(codeFont.regularFont as NSFont)
        result[Attr.Ligature.self] = codeFont.ligatures ? 1 : 0

        let utf16Len = (line.text as NSString).length
        let styles = theme.styles(for: language)

        for span in line.spans {
            let start = max(0, min(Int(span.start), utf16Len))
            let end = max(start, min(Int(span.start + span.length), utf16Len))
            guard end > start else { continue }
            let idx = Int(span.kind.rawValue)
            guard idx < styles.count else { continue }
            let style = styles[idx]
            if let range = utf16Range(start..<end, in: line.text, attributed: result) {
                result[range][Attr.Foreground.self] = Color(cgColor: style.color)
                if style.bold || style.italic {
                    result[range][Attr.Font.self] = Font(codeFont.ctFont(bold: style.bold, italic: style.italic) as NSFont)
                }
            }
        }

        if let hl = line.highlightRange {
            let start = max(0, min(hl.lowerBound, utf16Len))
            let end = max(start, min(hl.upperBound, utf16Len))
            if end > start, let range = utf16Range(start..<end, in: line.text, attributed: result) {
                result[range][Attr.Background.self] = Color(
                    NSColor.dyn(0xF5C242, 0xE8B339, lightAlpha: 0.44, darkAlpha: 0.38)
                )
            }
        }

        return result
    }

    private func utf16Range(
        _ range: Range<Int>,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let utf16 = text.utf16
        guard range.lowerBound >= 0, range.upperBound <= utf16.count, range.lowerBound < range.upperBound else {
            return nil
        }
        let start16 = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
        let end16 = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
        guard let start = start16.samePosition(in: text),
              let end = end16.samePosition(in: text),
              start < end else {
            return nil
        }
        return Range(start..<end, in: attributed)
    }
}

// MARK: - File Structure / Symbols Picker (⌘R)

struct FileSymbolsPopupView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("popupSplit.fileSymbols") private var splitRatio: Double = 0.45

    var body: some View {
        @Bindable var model = store.fileSymbols
        VStack(spacing: 0) {
            // Header: outline icon + filename + count badge + kind filter pills + search field + close button
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.indent")
                    .font(.ui(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.difAccent)

                Text(model.title)
                    .font(.ui(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(countLabel(model))
                    .font(.ui(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.difChip))

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    ForEach(FileSymbolFilter.allCases, id: \.self) { filter in
                        ScopeTab(title: filter.title, isSelected: model.kindFilter == filter) {
                            model.kindFilter = filter
                        }
                    }
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                    SearchField(
                        text: $model.filterQuery,
                        placeholder: L("Filter symbols…", "搜索函数 / 结构体…"),
                        font: .systemFont(ofSize: 12.5 * UI.scale),
                        focusToken: model.focusToken,
                        onMove: { model.move($0) },
                        onSubmit: { model.activate() },
                        onCancel: { store.dismissPopup() },
                        onTab: { model.cycleFilter($0 ? -1 : 1) }
                    )
                    .frame(width: UI.s(185), height: UI.s(20))
                    if !model.filterQuery.isEmpty {
                        Button {
                            model.filterQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.ui(size: 11))
                                .foregroundStyle(Color.difText3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: UI.s(26))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))

                Button {
                    store.dismissPopup()
                } label: {
                    Image(systemName: "xmark")
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(Color.difText2)
                        .frame(width: UI.s(24), height: UI.s(24))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                }
                .buttonStyle(.plain)
                .help(L("Close (Esc)", "关闭 (Esc)"))
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(46))

            Rectangle().fill(Color.difHairline).frame(height: 1)

            GeometryReader { geo in
                let previewHeaderHeight = UI.s(28)
                let availableHeight = max(144, geo.size.height - previewHeaderHeight - 1)
                let listHeight = PopupResizeGeometry.splitListHeight(
                    availableHeight: availableHeight,
                    ratio: splitRatio
                )

                VStack(spacing: 0) {
                    // Top section: scrollable symbol list
                    if model.filteredItems.isEmpty {
                        VStack(spacing: 6) {
                            Text(model.allItems.isEmpty
                                 ? L("No symbols found in this file", "当前文件中未找到符号")
                                 : L("No matching symbols", "没有匹配的符号"))
                                .font(.ui(size: 12.5))
                                .foregroundStyle(Color.difText3)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: listHeight)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(Array(model.filteredItems.enumerated()), id: \.element.id) { index, item in
                                        FileSymbolRow(
                                            item: item,
                                            positions: model.positions(for: item),
                                            isSelected: index == model.selectedIndex
                                        )
                                        .id(item.id)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.select(index)
                                            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                                model.activate(index)
                                            }
                                        }
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .frame(height: listHeight)
                            .onAppear {
                                if let id = model.selectedItem?.id {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            .onChange(of: model.selectedIndex) { _, _ in
                                if let id = model.selectedItem?.id {
                                    proxy.scrollTo(id)
                                }
                            }
                            .onChange(of: model.filteredItems.first?.id) { _, _ in
                                if let id = model.selectedItem?.id {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                            }
                        }
                    }

                    PopupSplitDivider(availableHeight: availableHeight, ratio: $splitRatio)

                    // Preview sub-header with filename : lineNumber and Jump button
                    HStack(spacing: 8) {
                        if let item = model.selectedItem {
                            FileIcon(path: model.displayPath, size: 11.5)
                            Text("\(model.title) : \(item.lineNumber)")
                                .font(.ui(size: 11.5, design: .monospaced))
                                .foregroundStyle(Color.difText2)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Text(item.kind.label)
                                .font(.ui(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(item.kind.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(item.kind.accentColor.opacity(0.14)))
                        }
                        Spacer(minLength: 8)
                        if model.selectedItem != nil {
                            Button {
                                model.activate()
                            } label: {
                                HStack(spacing: 4) {
                                    Text(L("Jump", "跳转"))
                                        .font(.ui(size: 11, weight: .semibold))
                                    Text("⏎")
                                        .font(.ui(size: 10.5, weight: .medium))
                                }
                                .foregroundStyle(Color.difAccent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difAccent.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: previewHeaderHeight)
                    .background(Color.difPanel.opacity(0.65))

                    // Bottom section: syntax-highlighted code context preview
                    ReferenceCodePreviewView(
                        context: model.previewContext,
                        isLoading: false,
                        settings: store.settings
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)

            // Footer hints
            HStack(spacing: 14) {
                Hint(keys: "↑↓", text: L("Preview", "预览"))
                Hint(keys: "⏎", text: L("or Double-Click Jump", "或双击跳转"))
                Hint(keys: "Esc", text: L("Close", "关闭"))
                Spacer()
                Hint(keys: "⇥", text: L("Filter", "切换分类"))
            }
            .padding(.horizontal, 14)
            .frame(height: UI.s(30))
        }
    }

    private func countLabel(_ model: FileSymbolsModel) -> String {
        let isFiltered = !model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.kindFilter != .all
        if !isFiltered {
            return "\(model.allItems.count)"
        }
        return "\(model.filteredItems.count) / \(model.allItems.count)"
    }
}

private struct FileSymbolRow: View {
    var item: FileSymbolItem
    var positions: [Int]
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(item.kind.badge)
                .font(.ui(size: 10.5, weight: .bold, design: .rounded))
                .foregroundStyle(item.kind.accentColor)
                .frame(width: UI.s(18), height: UI.s(18))
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(item.kind.accentColor.opacity(0.16))
                )

            Text(FuzzyHighlight.text(
                item.name,
                positions: positions,
                offset: 0,
                base: item.isExported ? Color.difText : Color.difText.opacity(0.88),
                size: 12.5,
                weight: item.isExported ? .semibold : .regular
            ))
            .font(.ui(size: 12.5, weight: item.isExported ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.code(11.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(":\(item.lineNumber)")
                .font(.ui(size: 11, design: .monospaced))
                .foregroundStyle(Color.difText3)
                .frame(minWidth: 40, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(26))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.difSelection : Color.clear)
                .padding(.horizontal, 6)
        )
        .help("\(item.kind.label) \(item.name)\(item.detail.isEmpty ? "" : " \(item.detail)") (:\(item.lineNumber))")
    }
}

// MARK: - Selection History Preview (⌘B)

struct SelectionHistoryPopupView: View {
    @Environment(AppStore.self) private var store
    @AppStorage("popupSplit.selectionHistory") private var splitRatio: Double = 0.38
    @State private var showCommitBody = false

    var body: some View {
        @Bindable var model = store.selectionHistory
        VStack(spacing: 0) {
            headerBar(model: model)
            Rectangle().fill(Color.difHairline).frame(height: 1)
            splitBody(model: model)
            Rectangle().fill(Color.difHairline).frame(height: 1)
            footerBar(model: model)
        }
        .onChange(of: model.selectedIndex) { _, _ in
            showCommitBody = false
        }
    }

    private func headerBar(model: SelectionHistoryModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.ui(size: 13.5, weight: .medium))
                .foregroundStyle(Color.difAccent)

            Text(L("History for Selection", "选中行历史"))
                .font(.ui(size: 13.5, weight: .semibold))
                .foregroundStyle(Color.difText)
                .lineLimit(1)
                .layoutPriority(1)

            if !model.fileName.isEmpty {
                HStack(spacing: 5) {
                    FileIcon(path: model.displayPath, size: 11)
                    Text(model.lineRangeLabel.isEmpty ? model.fileName : "\(model.fileName) : \(model.lineRangeLabel)")
                        .font(.ui(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip))
                .help(model.displayPath)
            }

            if !model.entries.isEmpty {
                Text(countLabel(model))
                    .font(.ui(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.difChip))
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                SearchField(
                    text: $model.filterQuery,
                    placeholder: L("Filter commits, author, hash…", "搜索提交信息、作者、哈希…"),
                    font: .systemFont(ofSize: 12.5 * UI.scale),
                    focusToken: model.focusToken,
                    onMove: { model.move($0) },
                    onSubmit: { model.activate() },
                    onCancel: { store.dismissPopup() },
                    onTab: { _ in model.toggleUnified() }
                )
                .frame(width: UI.s(210), height: UI.s(20))
                if !model.filterQuery.isEmpty {
                    Button {
                        model.filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.ui(size: 11))
                            .foregroundStyle(Color.difText3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: UI.s(26))
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))

            Button {
                store.dismissPopup()
            } label: {
                Image(systemName: "xmark")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Color.difText2)
                    .frame(width: UI.s(24), height: UI.s(24))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
            }
            .buttonStyle(.plain)
            .help(L("Close (Esc)", "关闭 (Esc)"))
        }
        .padding(.horizontal, 14)
        .frame(height: UI.s(46))
    }

    private func splitBody(model: SelectionHistoryModel) -> some View {
        GeometryReader { geo in
            let entry = model.selectedEntry
            let hasBody = entry.map { !$0.commit.body.isEmpty && $0.commit.body != $0.commit.subject } ?? false
            let previewHeaderHeight = UI.s(30)
            let bodyStripHeight: CGFloat = hasBody && showCommitBody ? UI.s(54) : 0
            let showsPaneTitles: Bool = {
                if let doc = model.previewDocument, case .text = doc.content { return true }
                return false
            }()
            let paneTitlesHeight: CGFloat = showsPaneTitles ? UI.s(22) : 0
            let availableHeight = max(144, geo.size.height - previewHeaderHeight - bodyStripHeight - paneTitlesHeight - 1)
            let listHeight = PopupResizeGeometry.splitListHeight(
                availableHeight: availableHeight,
                ratio: splitRatio
            )

            VStack(spacing: 0) {
                commitListPane(model: model, height: listHeight)

                PopupSplitDivider(availableHeight: availableHeight, ratio: $splitRatio, defaultRatio: 0.38)

                previewSubHeader(model: model, entry: entry, hasBody: hasBody, height: previewHeaderHeight)

                if hasBody && showCommitBody, let entry {
                    ScrollView {
                        Text(entry.commit.body)
                            .font(.ui(size: 11.5))
                            .foregroundStyle(Color.difText2)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(height: bodyStripHeight)
                    .background(Color.difPanel.opacity(0.45))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.difHairline.opacity(0.6)).frame(height: 1)
                    }
                }

                if let doc = model.previewDocument, case .text = doc.content {
                    SelectionHistoryPaneTitles(left: doc.leftTitle, right: doc.rightTitle, unified: model.unified)
                        .frame(height: paneTitlesHeight)
                }

                ZStack {
                    PreviewHost { model.attachPreview($0) }
                    if let doc = model.previewDocument {
                        if case .message(let title, let detail) = doc.content {
                            EmptyListState(symbol: "doc.questionmark", title: title, detail: detail)
                                .background(Color.difWindow)
                        }
                    } else {
                        Color.difWindow
                        Text(previewEmptyMessage(model))
                            .font(.ui(size: 12.5))
                            .foregroundStyle(Color.difText3)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func commitListPane(model: SelectionHistoryModel, height: CGFloat) -> some View {
        if model.isLoading && model.entries.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("Loading selection history…", "正在加载选中行历史…"))
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else if let error = model.errorMessage, model.entries.isEmpty {
            VStack(spacing: 6) {
                Text(error)
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difRemoved)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else if model.filteredEntries.isEmpty {
            VStack(spacing: 6) {
                Text(model.entries.isEmpty
                     ? L("No commits found for these lines", "这些行没有找到提交记录")
                     : L("No matching commits", "没有匹配的提交"))
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: height)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.filteredEntries.enumerated()), id: \.element.id) { index, entry in
                            SelectionHistoryCommitRow(entry: entry, isSelected: index == model.selectedIndex)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(index)
                                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                                        model.activate(index)
                                    }
                                }
                                .contextMenu {
                                    Button(L("Open in Log", "在日志中打开")) { model.activate(index) }
                                    Divider()
                                    Button(L("Copy Hash", "复制哈希")) { model.copyHash(index) }
                                    Button(L("Copy Message", "复制提交信息")) { model.copyMessage(index) }
                                }
                        }

                        if model.hasMore && model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HStack {
                                Spacer()
                                if model.isLoadingMore {
                                    ProgressView().controlSize(.small).scaleEffect(0.7)
                                } else {
                                    Button(L("Load more commits…", "加载更多提交…")) {
                                        model.loadMore()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.ui(size: 11.5, weight: .medium))
                                    .foregroundStyle(Color.difAccent)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: height)
                .onChange(of: model.selectedIndex) { _, _ in
                    if let id = model.selectedEntry?.id {
                        proxy.scrollTo(id)
                    }
                }
                .onChange(of: model.filteredEntries.first?.id) { _, _ in
                    if let id = model.selectedEntry?.id {
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
            }
        }
    }

    private func previewSubHeader(
        model: SelectionHistoryModel,
        entry: LineHistoryEntry?,
        hasBody: Bool,
        height: CGFloat
    ) -> some View {
        HStack(spacing: 8) {
            if let entry {
                let path = entry.displayPath.isEmpty ? model.displayPath : entry.displayPath
                FileIcon(path: path, size: 11.5)
                Text(entry.isRename ? "\(entry.oldPath ?? "") → \(entry.newPath ?? "")" : path)
                    .font(.ui(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.difText2)
                    .lineLimit(1)
                    .truncationMode(.head)

                if let rangeText = trackedRangeLabel(for: entry) {
                    Text(rangeText)
                        .font(.ui(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.difText2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.difChip))
                        .fixedSize()
                }

                if !entry.sectionHeader.isEmpty {
                    Text(entry.sectionHeader)
                        .font(.code(11))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if hasBody {
                Button {
                    showCommitBody.toggle()
                } label: {
                    Image(systemName: showCommitBody ? "text.bubble.fill" : "text.bubble")
                        .font(.ui(size: 11))
                        .foregroundStyle(showCommitBody ? Color.difAccent : Color.difText2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(showCommitBody ? Color.difAccent.opacity(0.14) : Color.difChip)
                        )
                }
                .buttonStyle(.plain)
                .help(L("Show full commit message", "显示完整提交说明"))
            }

            HStack(spacing: 2) {
                ScopeTab(title: L("Side-by-Side", "双栏"), isSelected: !model.unified) {
                    model.setUnified(false)
                }
                ScopeTab(title: L("Unified", "单栏"), isSelected: model.unified) {
                    model.setUnified(true)
                }
            }

            if let entry {
                Button {
                    model.copyHash()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.ui(size: 10))
                        Text(entry.commit.shortHash)
                            .font(.ui(size: 10.5, design: .monospaced))
                    }
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip))
                }
                .buttonStyle(.plain)
                .help(L("Copy commit hash", "复制提交哈希"))

                Button {
                    model.activate()
                } label: {
                    HStack(spacing: 4) {
                        Text(L("Open in Log", "在日志中打开"))
                            .font(.ui(size: 11, weight: .semibold))
                        Text("⏎")
                            .font(.ui(size: 10.5, weight: .medium))
                    }
                    .foregroundStyle(Color.difAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difAccent.opacity(0.14)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(Color.difPanel.opacity(0.65))
    }

    private func footerBar(model: SelectionHistoryModel) -> some View {
        HStack(spacing: 14) {
            Hint(keys: "↑↓", text: L("Switch Commit", "切换提交"))
            Hint(keys: "⏎", text: L("Open in Log", "在日志中打开"))
            Hint(keys: "⇥", text: L("Side-by-Side / Unified", "切换双栏 / 单栏"))
            Hint(keys: "Esc", text: L("Close", "关闭"))
            Spacer()
            if model.isLoading || model.isLoadingMore {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: UI.s(30))
    }

    private func countLabel(_ model: SelectionHistoryModel) -> String {
        let suffix = model.hasMore ? "+" : ""
        let isFiltered = !model.filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !isFiltered {
            return "\(model.entries.count)\(suffix)"
        }
        return "\(model.filteredEntries.count) / \(model.entries.count)\(suffix)"
    }

    private func previewEmptyMessage(_ model: SelectionHistoryModel) -> String {
        if model.isLoading { return L("Loading preview…", "正在加载预览…") }
        if let error = model.errorMessage, model.entries.isEmpty { return error }
        return model.entries.isEmpty
            ? L("No commits found for these lines", "这些行没有找到提交记录")
            : L("No matching commits", "没有匹配的提交")
    }

    private func trackedRangeLabel(for entry: LineHistoryEntry) -> String? {
        func format(_ range: ClosedRange<Int>) -> String {
            range.count > 1 ? "L\(range.lowerBound)–\(range.upperBound)" : "L\(range.lowerBound)"
        }
        switch (entry.leftLineRange, entry.rightLineRange) {
        case (let left?, let right?):
            return left == right ? format(right) : "\(format(left)) → \(format(right))"
        case (nil, let right?):
            return "+ \(format(right))"
        case (let left?, nil):
            return "− \(format(left))"
        case (nil, nil):
            return nil
        }
    }
}

private struct SelectionHistoryCommitRow: View {
    var entry: LineHistoryEntry
    var isSelected: Bool

    @MainActor
    private static let relativeDate: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        HStack(spacing: 8) {
            ForEach(entry.commit.refs.prefix(2), id: \.self) { ref in
                RefChip(ref: ref)
            }

            Text(entry.commit.subject)
                .font(.ui(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(Color.difText)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 8)

            if entry.additions > 0 || entry.deletions > 0 {
                HStack(spacing: 4) {
                    if entry.additions > 0 {
                        Text("+\(entry.additions)")
                            .foregroundStyle(Color.difAdded)
                    }
                    if entry.deletions > 0 {
                        Text("-\(entry.deletions)")
                            .foregroundStyle(Color.difRemoved)
                    }
                }
                .font(.code(11))
                .monospacedDigit()
                .fixedSize()
            }

            Text(entry.commit.author)
                .font(.ui(size: 11))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)

            Text(Self.relativeDate.localizedString(for: entry.commit.date, relativeTo: Date()))
                .font(.ui(size: 11))
                .foregroundStyle(Color.difText3)
                .fixedSize()

            if entry.commit.isMerge {
                Image(systemName: "arrow.triangle.merge")
                    .font(.ui(size: 9))
                    .foregroundStyle(Color.difText3)
            }

            Text(entry.commit.shortHash)
                .font(.code(11))
                .foregroundStyle(Color.difText3)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(28))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.difSelection : Color.clear)
                .padding(.horizontal, 6)
        )
        .help("\(entry.commit.shortHash) · \(entry.commit.subject)\n\(entry.commit.author)")
    }
}

private struct SelectionHistoryPaneTitles: View {
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
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.difHairline.opacity(0.6)).frame(height: 1)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.ui(size: 10.5, weight: .medium))
            .foregroundStyle(Color.difText3)
            .padding(.horizontal, 12)
            .lineLimit(1)
    }
}

// MARK: - Go to line

struct GoToLineView: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""

    var body: some View {
        let total = store.viewer.document?.right.lines.count ?? 0
        HStack(spacing: 10) {
            Image(systemName: "arrow.right.to.line").font(.ui(size: 14, weight: .medium)).foregroundStyle(Color.difText2)
            SearchField(text: $text, placeholder: L("Line number (1–\(total))", "行号 (1–\(total))"), font: .systemFont(ofSize: 15 * UI.scale),
                        focusToken: 1,
                        onSubmit: {
                            let digits = text.split(separator: ":").first.map(String.init) ?? text
                            store.dismissPopup(restoreFocus: false)
                            if let line = Int(digits.trimmingCharacters(in: .whitespaces)) {
                                store.recordCurrentJumpOriginIfDifferent(targetLine1Based: line)
                                store.viewer.reveal(line: line)
                            }
                            store.viewer.focusCanvas()
                        },
                        onCancel: { store.dismissPopup() })
                .frame(height: UI.s(22))
        }
        .padding(.horizontal, 16)
        .frame(height: UI.s(48))
    }
}

// MARK: - Keymap

struct KeymapView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let commands = store.commands
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Keymap", "快捷键")).font(.ui(size: 15, weight: .semibold)).foregroundStyle(Color.difText)
                Text(L("Aligned with GoLand's macOS keymap & ~/.ideavimrc", "与 GoLand macOS 键位及 ~/.ideavimrc 保持一致"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                Spacer()
                KeyCaps(shortcut: "Esc")
            }
            .padding(.horizontal, 20)
            .frame(height: UI.s(48))
            Rectangle().fill(Color.difHairline).frame(height: 1)
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    VStack(alignment: .leading, spacing: 18) {
                        column(commands, groups: AppEnvironment.hasTerminal ? [.navigate, .terminal] : [.navigate])
                        vimExtras
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        column(commands, groups: [.view])
                        column(commands, groups: [.git, .file])
                        extras
                    }
                }
                .padding(20)
            }
            .frame(maxHeight: 620)
        }
    }

    private func column(_ commands: [AppCommand], groups: [AppCommand.Group]) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 7) {
                    SectionLabel(text: group.title)
                    ForEach(commands.filter { $0.group == group && !$0.shortcut.isEmpty }) { command in
                        shortcutRow(command.title.replacingOccurrences(of: "…", with: ""), command.shortcut)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var extras: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: L("In the viewer", "查看器内"))
            shortcutRow(L("Next / Previous Difference", "下一处 / 上一处差异"), "⌘↓ / ⌘↑ · F7 / ⇧F7")
            shortcutRow(L("Next / Previous Change", "下一处 / 上一处变更"), "⌃⌥⇧↓ / ⌃⌥⇧↑")
            shortcutRow(L("Find in File", "在文件中查找"), "⌃⇧⌘F")
            shortcutRow(L("Next / Previous Occurrence", "下一个 / 上一个匹配"), "⌘G / ⇧⌘G")
            shortcutRow(L("Next / Previous Symbol Usage", "下一个 / 上一个符号引用"), "⌃⌥↓ / ⌃⌥↑")
            shortcutRow(L("Expand / Shrink Selection", "扩大 / 缩小选区"), "⌘. / ⌘;")
            shortcutRow(L("Find in Files (Secondary)", "在文件中查找（备用）"), "⇧⌘F")
            shortcutRow(L("File Structure", "文件结构"), "⌘R / ⌘F12")
            shortcutRow(L("Back to the File List", "回到文件列表"), "Esc / ⌘H")
            shortcutRow(L("Zoom Text", "缩放文字"), L("Pinch", "双指捏合"))
            if AppEnvironment.hasLSP {
                shortcutRow(L("Navigate Back / Forward", "后退 / 前进"), "⌥⌘← / ⌥⌘→")
                shortcutRow(L("Go to Definition / References", "跳转到声明 / 查看引用"), "⌘+Click")
                shortcutRow(L("Go to Implementation", "跳转到实现"), "⌥⌘+Click")
            }
            if AppEnvironment.hasTerminal {
                shortcutRow(L("Toggle Terminal (Secondary)", "开关终端（备用）"), "⌥F12")
                shortcutRow(L("Close Terminal (when focused)", "关闭终端（聚焦时）"), "⌘W")
                shortcutRow(L("Next / Previous Terminal (when focused)", "下一个 / 上一个终端（聚焦时）"), "⇧⌘] / ⇧⌘[")
            }
        }
    }

    private var vimExtras: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionLabel(text: "Vim (~/.ideavimrc)")
            shortcutRow(L("Leader Key", "前导键 (Leader)"), "Space")
            shortcutRow(L("Go to Definition / References", "定义 / 引用"), "gd / gr · Space r")
            shortcutRow(L("Go to Implementation / Interfaces", "跳转实现 / 接口"), "gi / gu")
            shortcutRow(L("Go to Type Definition", "跳转类型定义"), "gy")
            shortcutRow(L("Go to File / Everywhere / Action", "文件 / 随处 / 操作"), "⌘P / ⌃P · Space a · ga")
            shortcutRow(L("Go to Symbol", "查找符号"), "gs")
            shortcutRow(L("Git Pull / Push / Graph", "拉取 / 推送 / 分支树"), "gl / gp / gb")
            shortcutRow(L("Locate File / Tree / Maximize", "定位 / 文件树 / 最大化"), "Space e / ⌃E / Space o")
            shortcutRow(L("Navigate Back / Forward", "后退 / 前进"), "⌃O / ⌃I")
            shortcutRow(L("Prev / Next Function", "上一个 / 下一个函数"), "[[ / ]]")
            shortcutRow(L("Function Text Objects", "函数文本对象"), "vif / vaf")
            shortcutRow(L("Expand / Shrink Selection", "扩大 / 缩小选区"), "↩ / ⌫")
            shortcutRow(L("Toggle Comment", "切换注释"), "gcc / gc")
            shortcutRow(L("Visual Block Mode", "列选模式 (Visual Block)"), "⌃V")
            shortcutRow(L("Visual Surround", "可视化包围"), "\" ' ( { [")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shortcutRow(_ title: String, _ shortcut: String) -> some View {
        HStack {
            Text(title).font(.ui(size: 12.5)).foregroundStyle(Color.difText2).lineLimit(1)
            Spacer(minLength: 12)
            KeyCaps(shortcut: shortcut)
        }
    }
}

// MARK: - Settings

enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case editor
    case diff
    case ai

    var id: String { rawValue }

    static var visibleCases: [SettingsTab] {
        allCases.filter { tab in
            !(AppEnvironment.isAppStore && tab == .ai)
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .editor: return "textformat"
        case .diff: return "arrow.left.arrow.right"
        case .ai: return "sparkles"
        }
    }

    @MainActor var title: String {
        switch self {
        case .general: return L("General", "通用")
        case .editor: return L("Editor", "编辑器")
        case .diff: return AppEnvironment.hasLSP ? L("Diff & Jump", "对比与跳转") : L("Diff", "对比")
        case .ai: return "AI"
        }
    }
}

private struct SettingsTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol)
                    .font(.ui(size: 11.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.difAccent : Color.difText3)
                Text(tab.title)
                    .font(.ui(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.difText : Color.difText2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.difSelection : (isHovering ? Color.difHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.difAccent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("settings.selectedTab") private var selectedTabRaw: String = SettingsTab.general.rawValue
    /// Installed monospace families for the font pickers, read when Settings opens.
    @State private var families: [String] = []
    /// Weights genuinely available for the currently selected code font family.
    @State private var availableWeights: [CodeFontWeight] = CodeFontWeight.allCases
    @State private var typographyExpanded = true

    private var activeTab: SettingsTab {
        if let tab = SettingsTab(rawValue: selectedTabRaw), SettingsTab.visibleCases.contains(tab) {
            return tab
        }
        return .general
    }

    var body: some View {
        @Bindable var settings = store.settings
        let codeFont = CodeFont.current(settings)
        let previewTheme: CanvasTheme = colorScheme == .dark ? .dark : .light
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Settings", "设置")).font(.ui(size: 15, weight: .semibold)).foregroundStyle(Color.difText)
                Spacer()
                KeyCaps(shortcut: "Esc")
            }
            .padding(.horizontal, 20)
            .frame(height: UI.s(44))

            HStack(spacing: 6) {
                ForEach(SettingsTab.visibleCases) { tab in
                    SettingsTabButton(tab: tab, isSelected: activeTab == tab) {
                        selectedTabRaw = tab.rawValue
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch activeTab {
                    case .general:
                        generalTab(settings: settings)
                    case .editor:
                        editorTab(settings: settings, codeFont: codeFont, previewTheme: previewTheme)
                    case .diff:
                        diffTab(settings: settings)
                    case .ai:
                        if !AppEnvironment.isAppStore {
                            aiCommitSection(settings: settings)
                        }
                    }
                }
                .padding(20)
            }
            .frame(minHeight: UI.s(220), maxHeight: UI.s(480))
        }
        .onAppear {
            settings.reloadLanguage()
            availableWeights = MonospaceFonts.availableWeights(for: settings.codeFontFamily)
        }
        .task {
            // Fonts installed since the last time show too.
            families = await Task.detached(priority: .userInitiated) { MonospaceFonts.installed() }.value
            if !AppEnvironment.isAppStore {
                await store.refreshAgentAvailability(forceRefresh: false)
                let commitProvider = settings.aiProvider(for: .commit)
                store.loadAgentModels(for: commitProvider, forceRefresh: false)
                let groupingProvider = settings.aiProvider(for: .grouping)
                if groupingProvider != commitProvider {
                    store.loadAgentModels(for: groupingProvider, forceRefresh: false)
                }
            }
        }
        .onChange(of: settings.codeFontFamily) { _, family in
            availableWeights = MonospaceFonts.availableWeights(for: family)
        }
        .onChange(of: settings.appearance) { _, _ in
            settings.save()
            settings.applyAppearance()
        }
        .onChange(of: settings.unified) { _, _ in
            settings.save()
            store.viewer.container?.setMode(store.viewer.canvasMode)
        }
        .onChange(of: settings.lspJumpOpenMode) { _, _ in
            settings.save()
        }
        .onChange(of: settings.lspIdleTimeout) { _, _ in
            settings.save()
            store.applyLSPIdleTimeout()
        }
        .onChange(of: settings.vimMode) { _, enabled in
            settings.save()
            store.viewer.setVimMode(enabled)
        }
        .onChange(of: settings.vimRelativeLineNumbers) { _, enabled in
            settings.save()
            store.viewer.setVimRelativeLineNumbers(enabled)
        }
        .onChange(of: settings.vimCursorColorHex) { _, hex in
            settings.save()
            store.viewer.setVimCursorColorHex(hex)
        }
        .onChange(of: settings.stickyLines) { _, enabled in
            settings.save()
            store.viewer.setStickyLines(enabled)
        }
        .onChange(of: settings.stickyLinesMaxCount) { _, count in
            settings.save()
            store.viewer.setStickyLinesMaxCount(count)
        }
        .onChange(of: settings.formatGoOnSave) { _, _ in
            settings.save()
        }
        .onDisappear {
            if NSColorPanel.sharedColorPanelExists && NSColorPanel.shared.isVisible {
                NSColorPanel.shared.close()
            }
        }
        .onChange(of: settings.aiCommitProvider) { _, provider in
            if !AppEnvironment.isAppStore {
                store.loadAgentModels(for: provider, forceRefresh: false)
            }
        }
        .onChange(of: settings.aiGroupingProvider) { _, provider in
            if !AppEnvironment.isAppStore {
                store.loadAgentModels(for: provider, forceRefresh: false)
            }
        }
        .onChange(of: settings.aiGroupingIncludePatterns) { _, _ in
            settings.save()
        }
        .onChange(of: settings.aiGroupingExcludeTestFiles) { _, _ in
            settings.save()
        }
        .onChange(of: settings.commitMessageFormat) { _, _ in
            settings.save()
        }
    }

    @ViewBuilder
    private func generalTab(settings: Settings) -> some View {
        @Bindable var settings = settings
        row(L("Appearance", "外观")) {
            Picker("", selection: $settings.appearance) {
                ForEach(Settings.Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: UI.s(240))
        }
        VStack(alignment: .trailing, spacing: 8) {
            row(L("Language", "语言")) {
                Picker("", selection: Binding(get: { settings.language }, set: { settings.chooseLanguage($0) })) {
                    ForEach(Settings.Language.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: UI.s(240))
            }
            if settings.languageNeedsRestart {
                HStack(spacing: 8) {
                    Text(L("Shows after \(appName) restarts", "重启 \(appName) 后生效"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText3)
                    BannerButton(title: L("Restart Now", "立即重启"), prominent: true) { store.restart() }
                }
            }
        }
        row(L("Interface font size", "界面字号")) {
            stepper(settings.uiFontSize, down: L("Smaller", "减小"), up: L("Larger", "增大")) { store.changeInterfaceFontSize(by: $0) }
        }
        if AppEnvironment.hasTerminal {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(L("Terminal", "终端"))
                row(L("Terminal font", "终端字体")) {
                    fontPicker(settings.terminalFontFamily) { store.chooseTerminalFont($0) }
                }
                row(L("Terminal font size", "终端字号")) {
                    stepper(settings.terminalFontSize, down: L("Smaller", "减小"), up: L("Larger", "增大")) { store.changeTerminalFontSize(by: $0) }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func editorTab(settings: Settings, codeFont: CodeFont, previewTheme: CanvasTheme) -> some View {
        @Bindable var settings = settings
        row(L("Code font", "代码字体")) {
            fontPicker(settings.codeFontFamily) { store.chooseCodeFont($0) }
        }
        row(L("Code font size", "代码字号")) {
            stepper(settings.fontSize, down: "⌃⇧,", up: "⌃⇧.") { store.viewer.changeFontSize(by: $0) }
        }
        row(L("Enable ligatures", "启用连字")) {
            Toggle("", isOn: Binding(
                get: { settings.codeFontLigatures },
                set: { store.setCodeFontLigatures($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.18)) { typographyExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: typographyExpanded ? "chevron.down" : "chevron.right")
                        .font(.ui(size: 10, weight: .semibold))
                        .foregroundStyle(Color.difText3)
                        .frame(width: 12)
                    Text(L("Typography Settings", "排版设置"))
                        .font(.ui(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.difText)
                    Rectangle()
                        .fill(Color.difHairline)
                        .frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if typographyExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    row(L("Main weight", "常规字重")) {
                        weightPicker(settings.codeFontMainWeight) { store.chooseCodeFontMainWeight($0) }
                    }
                    row(L("Bold weight", "粗体字重")) {
                        weightPicker(settings.codeFontBoldWeight) { store.chooseCodeFontBoldWeight($0) }
                    }
                    TypographyPreviewView(codeFont: codeFont, theme: previewTheme)
                        .frame(height: codeFont.lineHeight * 2 + 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.difHairline, lineWidth: 1)
                        )
                }
                .padding(.leading, 18)
            }
        }
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Vim Mode", "Vim 模式"))
            VStack(alignment: .leading, spacing: 4) {
                row(L("Vim Mode", "Vim 模式")) {
                    Toggle("", isOn: $settings.vimMode)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Text(L("Normal/Insert/Visual · Space leader · ~/.ideavimrc",
                       "Normal/Insert/Visual · Space 前导键 · ~/.ideavimrc"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
            }
            if settings.vimMode {
                row(L("Relative line numbers", "相对行号")) {
                    Toggle("", isOn: $settings.vimRelativeLineNumbers)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                .padding(.leading, 12)
                row(L("Cursor color", "光标颜色")) {
                    HStack(spacing: 8) {
                        if let hex = settings.vimCursorColorHex {
                            Text(hex)
                                .font(.ui(size: 11, design: .monospaced))
                                .foregroundStyle(Color.difText3)
                            Button(L("Reset", "恢复默认")) {
                                settings.vimCursorColorHex = nil
                            }
                            .buttonStyle(.plain)
                            .font(.ui(size: 11.5))
                            .foregroundStyle(Color.difAccent)
                        } else {
                            Text(L("Theme default", "跟随主题"))
                                .font(.ui(size: 11.5))
                                .foregroundStyle(Color.difText3)
                        }
                        ColorPicker(
                            "",
                            selection: vimCursorColorBinding(settings: settings, previewTheme: previewTheme),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.top, 4)
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Sticky Lines", "粘性行"))
            VStack(alignment: .leading, spacing: 4) {
                row(L("Show sticky lines", "显示粘性行 (Sticky Lines)")) {
                    Toggle("", isOn: $settings.stickyLines)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Text(L("Pin enclosing functions, methods, structs and classes while scrolling",
                       "滚动时在顶部固定当前所在的函数、方法、结构体或类声明"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
            }
            if settings.stickyLines {
                row(L("Maximum pinned lines", "最多固定行数")) {
                    HStack(spacing: 8) {
                        IconButton(symbol: "minus", help: L("Decrease", "减少")) {
                            settings.stickyLinesMaxCount = max(
                                Settings.stickyLinesRange.lowerBound,
                                settings.stickyLinesMaxCount - 1
                            )
                        }
                        .disabled(settings.stickyLinesMaxCount <= Settings.stickyLinesRange.lowerBound)
                        Text("\(settings.stickyLinesMaxCount)")
                            .font(.ui(size: 12.5, design: .rounded))
                            .frame(width: UI.s(36))
                        IconButton(symbol: "plus", help: L("Increase", "增加")) {
                            settings.stickyLinesMaxCount = min(
                                Settings.stickyLinesRange.upperBound,
                                settings.stickyLinesMaxCount + 1
                            )
                        }
                        .disabled(settings.stickyLinesMaxCount >= Settings.stickyLinesRange.upperBound)
                    }
                }
                .padding(.leading, 12)
            }
        }
        .padding(.top, 4)
        if !AppEnvironment.isAppStore {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(L("Formatting", "格式化"))
                VStack(alignment: .leading, spacing: 4) {
                    row(L("Format Go files on save (go fmt)", "保存 Go 文件时自动执行 go fmt")) {
                        Toggle("", isOn: $settings.formatGoOnSave)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                    }
                    Text(L("Automatically runs gofmt on the current .go file after saving.",
                           "保存 .go 文件后自动对当前文件执行 go fmt 格式化。"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText3)
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func diffTab(settings: Settings) -> some View {
        @Bindable var settings = settings
        row(L("Default view", "默认视图")) {
            Picker("", selection: $settings.unified) {
                Text(L("Side-by-side", "并排")).tag(false)
                Text(L("Unified", "合并")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: UI.s(240))
        }
        row(L("Auto-open 3-way merge on conflicts", "遇到冲突时自动打开三方合并")) {
            Toggle("", isOn: Binding(
                get: { settings.autoOpenThreeWayMerge },
                set: { settings.autoOpenThreeWayMerge = $0; settings.save() }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        if AppEnvironment.hasLSP {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(L("LSP Navigation", "LSP 跳转"))
                row(L("Open jumped file as", "跳转目标打开方式")) {
                    Picker("", selection: $settings.lspJumpOpenMode) {
                        ForEach(Settings.LSPJumpOpenMode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: UI.s(240))
                }
                Text(L("Applies to cross-file LSP jumps to modified files. Same-file jumps stay in the current view.",
                       "用于跨文件 LSP 跳转到有变更的文件；当前文件内跳转始终保持在当前视图。"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .fixedSize(horizontal: false, vertical: true)
                row(L("Release idle LSP server after", "切走后释放空闲 LSP 服务")) {
                    Picker("", selection: $settings.lspIdleTimeout) {
                        ForEach(Settings.LSPIdleTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: UI.s(240))
                }
                Text(L("Open files keep their language server warm. After switching to another workspace or non-LSP file, idle servers shut down automatically after this delay.",
                       "当前打开的文件会保持语言服务常驻；切换到其他项目或非 LSP 文件后，超过该时长自动释放内存。"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 4)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.ui(size: 12.5, weight: .medium))
                .foregroundStyle(Color.difText)
            Rectangle()
                .fill(Color.difHairline)
                .frame(height: 1)
        }
    }

    private func aiCommitSection(settings: Settings) -> some View {
        @Bindable var settings = settings
        let isDefaultFormat = settings.commitMessageFormat == Settings.defaultCommitMessageFormat

        return VStack(alignment: .leading, spacing: 10) {
            sectionHeader(L("Local AI Agents", "本地 AI 助手"))

            // Provider overview cards: install status dot, ACP/CLI badge, and executable path for all 3 agents.
            HStack(spacing: 6) {
                ForEach(AgentProvider.allCases) { provider in
                    let avail = store.availability(for: provider)
                    let installed = avail?.isInstalled ?? false
                    let transportLabel = (avail?.transportKind ?? (provider == .agy ? .acp : .cli)).rawValue.uppercased()
                    let isUsed = settings.aiProvider(for: .commit) == provider || settings.aiProvider(for: .grouping) == provider
                    let pathText: String = {
                        if !store.agentAvailabilityChecked { return L("Checking…", "检测中…") }
                        if let path = avail?.executablePath { return path }
                        return L("Not found in PATH", "未在 PATH 中找到")
                    }()

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(!store.agentAvailabilityChecked
                                      ? Color.difText3.opacity(0.5)
                                      : (installed ? Color.difAdded : Color.difRemoved))
                                .frame(width: 6, height: 6)
                            Text(provider.displayName)
                                .font(.ui(size: 11, weight: isUsed ? .semibold : .medium))
                                .foregroundStyle(isUsed ? Color.difText : Color.difText2)
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            Text(transportLabel)
                                .font(.ui(size: 9, weight: .semibold, design: .rounded))
                                .foregroundStyle(isUsed ? Color.difAccent : Color.difText3)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(isUsed ? Color.difAccent.opacity(0.14) : Color.difChip)
                                )
                        }
                        Text(pathText)
                            .font(.ui(size: 10, design: avail?.executablePath != nil ? .monospaced : .default))
                            .foregroundStyle(avail?.executablePath != nil ? Color.difText3 : Color.difText3.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isUsed ? Color.difSelection.opacity(0.55) : Color.difChip.opacity(0.65))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(isUsed ? Color.difAccent.opacity(0.35) : Color.difHairline, lineWidth: 1)
                    )
                    .help(avail?.executablePath
                          ?? L("Install \(provider.executableName) CLI and ensure it is in PATH",
                               "请安装 \(provider.executableName) 并确保它在 PATH 中"))
                }
            }

            // Independent per-task Provider + Model selectors sharing the same model list cache.
            VStack(alignment: .leading, spacing: 8) {
                aiTaskConfigRow(
                    title: L("Commit Message", "提交信息"),
                    task: .commit,
                    settings: settings
                )
                aiTaskConfigRow(
                    title: L("AI Grouping", "变更分组"),
                    task: .grouping,
                    settings: settings
                )
                row(L("Grouping file filter", "分组文件过滤")) {
                    TextField(L("e.g. *.go *.sql", "如 *.go *.sql"), text: $settings.aiGroupingIncludePatterns)
                        .textFieldStyle(.roundedBorder)
                        .font(.ui(size: 11.5, design: .monospaced))
                        .frame(width: UI.s(240))
                }
                row(L("Exclude test files", "分组排除测试文件")) {
                    Toggle("", isOn: $settings.aiGroupingExcludeTestFiles)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Text(L("Supports glob patterns (*, **, ?) separated by spaces or commas, !pattern to exclude, and per-project blacklists via right-click.",
                       "支持空格或逗号分隔的通配符（如 *.go *.sql、db/**/*.sql、!*.pb.go），并支持右键文件加入项目黑名单。"))
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L("Commit format", "提交格式"))
                        .font(.ui(size: 13))
                        .foregroundStyle(Color.difText2)
                    Spacer()
                    Button {
                        settings.resetCommitMessageFormat()
                    } label: {
                        Text(L("Reset Default", "恢复默认"))
                            .font(.ui(size: 11.5, weight: .medium))
                            .foregroundStyle(isDefaultFormat ? Color.difText3 : Color.difAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDefaultFormat)
                }
                TextEditor(text: $settings.commitMessageFormat)
                    .font(.ui(size: 11.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: UI.s(140))
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difChip))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.difHairline, lineWidth: 1)
                    )
            }
        }
    }

    private func aiTaskConfigRow(title: String, task: Settings.AITask, settings: Settings) -> some View {
        let provider = settings.aiProvider(for: task)
        let availability = store.availability(for: provider)
        let models = store.agentModelsByProvider[provider] ?? []
        let isLoadingModels = store.loadingModelsProviders.contains(provider)
        let modelError = store.agentModelErrors[provider]
        let selectedModel = settings.aiModel(for: provider, task: task)
        let defaultModel = models.first(where: \.isDefault)
        let missingModel: String? = selectedModel.flatMap { chosen in
            models.contains(where: { $0.id == chosen }) ? nil : chosen
        }

        return VStack(alignment: .leading, spacing: 4) {
            row(title) {
                HStack(spacing: 6) {
                    Picker("", selection: Binding<AgentProvider>(
                        get: { settings.aiProvider(for: task) },
                        set: { store.selectAgentProvider($0, for: task) }
                    )) {
                        ForEach(AgentProvider.allCases) { item in
                            let avail = store.availability(for: item)
                            let suffix = (store.agentAvailabilityChecked && avail?.isInstalled == false)
                                ? L(" (not installed)", "（未安装）") : ""
                            Text(item.displayName + suffix).tag(item)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: UI.s(132))
                    .help(availability?.executablePath ?? provider.displayName)

                    Picker("", selection: Binding<String?>(
                        get: { selectedModel },
                        set: { store.selectAgentModel($0, for: provider, task: task) }
                    )) {
                        Text(defaultModel.map { L("Auto (\($0.name))", "默认（\($0.name)）") }
                             ?? L("Auto (Default)", "自动（默认模型）"))
                            .tag(String?.none)
                        if !models.isEmpty || missingModel != nil {
                            Divider()
                        }
                        ForEach(models) { model in
                            Text(model.isDefault ? "\(model.name) (\(L("default", "默认")))" : model.name)
                                .tag(String?.some(model.id))
                        }
                        if let missingModel {
                            Text(models.isEmpty ? missingModel : "\(missingModel) (\(L("saved", "已保存")))")
                                .tag(String?.some(missingModel))
                        }
                    }
                    .id(provider)
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: UI.s(164))

                    ZStack {
                        IconButton(symbol: "arrow.clockwise",
                                   help: L("Refresh model list", "刷新模型列表"),
                                   size: 11.5) {
                            Task {
                                await store.refreshAgentAvailability(forceRefresh: true)
                                store.loadAgentModels(for: provider, forceRefresh: true)
                            }
                        }
                        .opacity(isLoadingModels ? 0 : 1)
                        .disabled(isLoadingModels)
                        if isLoadingModels {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: UI.s(22), height: UI.s(22))
                        }
                    }
                }
            }
            if store.agentAvailabilityChecked, availability?.isInstalled == false {
                Text(L("\(provider.executableName) not found in PATH",
                       "未在 PATH 中找到 \(provider.executableName)"))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difRemoved)
                    .lineLimit(1)
            } else if let modelError, !modelError.isEmpty {
                Text(modelError)
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difRemoved)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func vimCursorColorBinding(settings: Settings, previewTheme: CanvasTheme) -> Binding<Color> {
        Binding(
            get: {
                if let hex = settings.vimCursorColorHex, let ns = NSColor.fromHex(hex) {
                    return Color(nsColor: ns)
                }
                return Color(nsColor: NSColor(cgColor: previewTheme.text) ?? .textColor)
            },
            set: { newColor in
                if let hex = NSColor(newColor).hexString {
                    settings.vimCursorColorHex = hex
                }
            }
        )
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.ui(size: 13)).foregroundStyle(Color.difText2)
            Spacer()
            content()
        }
    }

    /// "Default" and the installed monospace families. A picked family that has since been uninstalled stays in the
    /// list, marked, so the picker never shows a blank; the code falls back to the default face meanwhile.
    private func fontPicker(_ selection: String?, choose: @escaping (String?) -> Void) -> some View {
        let missing = selection.flatMap { families.isEmpty || families.contains($0) ? nil : $0 }
        let choices = families.isEmpty ? selection.map { [$0] } ?? [] : families + (missing.map { [$0] } ?? [])
        return Picker("", selection: Binding(get: { selection }, set: { choose($0) })) {
            Text(L("Default (\(MonospaceFonts.defaultName))", "默认（\(MonospaceFonts.defaultName)）")).tag(String?.none)
            Divider()
            ForEach(choices, id: \.self) { family in
                Text(family == missing ? family + L(" (not installed)", "（未安装）") : family).tag(String?.some(family))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: UI.s(240))
    }

    private func weightPicker(_ selection: CodeFontWeight, choose: @escaping (CodeFontWeight) -> Void) -> some View {
        let options = availableWeights.isEmpty ? CodeFontWeight.allCases : availableWeights
        let resolved = MonospaceFonts.nearestWeight(selection, in: options)
        return Picker("", selection: Binding(get: { resolved }, set: { choose($0) })) {
            ForEach(options) { weight in
                Text(weight.title).tag(weight)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: UI.s(240))
    }

    private func stepper(_ value: Double, down: String, up: String, change: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            IconButton(symbol: "minus", help: down) { change(-1) }
            Text("\(Int(value)) pt").font(.ui(size: 12.5, design: .rounded)).frame(width: UI.s(44))
            IconButton(symbol: "plus", help: up) { change(1) }
        }
    }
}

/// CoreText-backed live preview of the current `CodeFont` (Main weight, Bold weight, Italic, and Ligatures).
private struct TypographyPreviewView: NSViewRepresentable {
    let codeFont: CodeFont
    let theme: CanvasTheme

    func makeNSView(context: Context) -> PreviewCanvas {
        let view = PreviewCanvas()
        view.update(codeFont: codeFont, theme: theme)
        return view
    }

    func updateNSView(_ view: PreviewCanvas, context: Context) {
        view.update(codeFont: codeFont, theme: theme)
    }

    final class PreviewCanvas: NSView {
        private static let sampleLines = [
            "func DeleteSignup(lid int64) {",
            "    if lid <= 0 && ok != nil { return }",
        ]
        private static let sampleSpans = Highlighter.highlight(sampleLines, language: .go)
        private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

        private var codeFont = CodeFont(size: 12)
        private var theme: CanvasTheme = .dark
        private var ctLines: [CTLine] = []

        override var isFlipped: Bool { true }

        func update(codeFont: CodeFont, theme: CanvasTheme) {
            let needsRebuild = ctLines.isEmpty || self.codeFont != codeFont || self.theme.isDark != theme.isDark
            self.codeFont = codeFont
            self.theme = theme
            if needsRebuild {
                rebuildLines()
                needsDisplay = true
            }
        }

        private func rebuildLines() {
            let styles = theme.styles(for: .go)
            let defaultColor = styles.first?.color ?? theme.text
            let ligatureValue = codeFont.ligatures ? 1 : 0
            ctLines = Self.sampleLines.enumerated().map { index, text in
                let attributed = NSMutableAttributedString(string: text, attributes: [
                    Self.fontKey: codeFont.regularFont,
                    Self.colorKey: defaultColor,
                    .ligature: ligatureValue,
                ])
                let length = attributed.length
                let spans = index < Self.sampleSpans.count ? Self.sampleSpans[index] : []
                for span in spans where span.kind != .plain {
                    let start = Int(span.start)
                    let count = min(Int(span.length), length - start)
                    guard start < length, count > 0 else { continue }
                    let kindIndex = Int(span.kind.rawValue)
                    let style = kindIndex < styles.count ? styles[kindIndex] : TokenStyle(defaultColor)
                    let range = NSRange(location: start, length: count)
                    attributed.addAttribute(Self.colorKey, value: style.color, range: range)
                    if style.bold || style.italic {
                        attributed.addAttribute(
                            Self.fontKey,
                            value: codeFont.ctFont(bold: style.bold, italic: style.italic),
                            range: range
                        )
                    }
                }
                return CTLineCreateWithAttributedString(attributed)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(theme.background)
            ctx.fill(bounds)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            let lh = codeFont.lineHeight
            for (index, line) in ctLines.enumerated() {
                ctx.textPosition = CGPoint(x: 10, y: 8 + CGFloat(index) * lh + codeFont.baseline)
                CTLineDraw(line, ctx)
            }
        }
    }
}
