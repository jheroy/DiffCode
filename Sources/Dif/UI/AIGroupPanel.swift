import AppKit
import SwiftUI

/// Middle-column panel for the "Groups" tab:
/// - Empty state: provider/model selector (`.grouping` task) + CTA to generate AI hunk groups.
/// - Populated state: resizable two-pane split matching `LogPanel` — top island lists logical groups,
///   bottom island renders the selected group's changed files using the same `ChangeTree` + `ChangeRowView`
///   style as the Changes tab (without commit checkboxes).
struct AIGroupPanel: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store
    /// Fraction of usable column height given to the top island (header + groups list).
    @State private var topSplitRatio: Double = Self.defaultTopRatio
    @State private var dragStartTopHeight: Double?
    @State private var filesFocusToken = 0

    private static let defaultTopRatio: Double = 0.40
    private static let minTopHeight: Double = 170
    private static let minBottomHeight: Double = 230

    var body: some View {
        Group {
            if AppEnvironment.isAppStore {
                singleCard { appStoreUnsupportedView }
            } else if let result = project.aiGroupResult, !result.groups.isEmpty {
                populatedSplitView(result: result)
            } else {
                singleCard { emptyStateView }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            guard !AppEnvironment.isAppStore else { return }
            store.ensureAgentEnvironmentReady(for: .grouping)
        }
        .onChange(of: store.settings.aiGroupingProvider) { _, provider in
            guard !AppEnvironment.isAppStore else { return }
            store.loadAgentModels(for: provider, forceRefresh: false)
        }
        .onChange(of: project.id) { oldID, _ in
            if let previous = store.project(oldID) {
                if previous.isGeneratingGroups {
                    store.cancelAIGroupGeneration(for: previous)
                }
                if previous.generatingGroupCommitID != nil {
                    store.cancelGroupCommitMessageGeneration(for: previous)
                }
            }
        }
    }

    private func singleCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            ProjectTabsHeader(project: project)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .islandCard(background: .difPanel)
    }

    // MARK: - App Store Fallback

    private var appStoreUnsupportedView: some View {
        EmptyListState(
            symbol: "sparkles.rectangle.stack",
            title: L("Unavailable in App Store Edition", "App Store 沙盒版暂不支持"),
            detail: L("The Mac App Store sandbox cannot invoke local AI agent CLIs.",
                      "App Store 沙盒版暂不支持调用本地 AI Agent 命令。")
        )
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        let hasChanges = !project.changes.isEmpty
        return ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 24)

                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.difAccent.opacity(0.12))
                        .frame(width: UI.s(42), height: UI.s(42))
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.ui(size: 19, weight: .medium))
                        .foregroundStyle(Color.difAccent)
                }

                VStack(spacing: 5) {
                    Text(L("AI Change Grouping", "AI 变更分组"))
                        .font(.ui(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.difText)
                    Text(L("Automatically organize all uncommitted hunks by feature or module.",
                           "将当前所有未提交变更按功能或模块对 Hunk 自动分组。"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)

                // Compact inline Agent Provider + Model selector for AI Grouping (independent of Commit Message).
                AgentModelSelectorCard(task: .grouping, compact: false)
                    .padding(.horizontal, 12)

                // Primary CTA button
                VStack(spacing: 6) {
                    if project.isGeneratingGroups {
                        Button {
                            store.cancelAIGroupGeneration(for: project)
                        } label: {
                            HStack(spacing: 7) {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.6)
                                    .frame(width: UI.s(13), height: UI.s(13))
                                Text(L("Grouping… Cancel", "正在分组… 点击取消"))
                                    .font(.ui(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(Color.difText)
                            .frame(maxWidth: .infinity)
                            .frame(height: UI.s(30))
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(Color.difAccent.opacity(0.45), lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            store.generateAIGroups(for: project)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "sparkles")
                                    .font(.ui(size: 11.5, weight: .semibold))
                                Text(L("Group Changes with AI", "使用 AI 分组"))
                                    .font(.ui(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: UI.s(30))
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.difAccent.opacity(hasChanges ? 1 : 0.38))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasChanges)
                    }

                    Text(hasChanges
                         ? (project.changes.count == 1
                            ? L("1 changed file ready to group", "当前有 1 个变更文件可分组")
                            : L("\(project.changes.count) changed files ready to group", "当前有 \(project.changes.count) 个变更文件可分组"))
                         : L("No uncommitted changes in working tree", "工作区暂无变更"))
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                }
                .padding(.horizontal, 12)

                if let error = project.aiGroupError, !error.isEmpty {
                    errorCard(message: error)
                        .padding(.horizontal, 12)
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Populated Two-Pane Split State

    private func populatedSplitView(result: AIHunkGroupingResult) -> some View {
        let snapshot = project.groupChangesSnapshot(flat: store.settings.flatList)
        let activeGroupID = snapshot?.group.id ?? project.selectedGroupID ?? result.groups.first?.id

        return GeometryReader { proxy in
            let gap = Double(IslandStyle.gap)
            let usable = max(0, Double(proxy.size.height) - gap)
            let safeMinTop = min(Self.minTopHeight, usable * 0.45)
            let safeMinBottom = min(Self.minBottomHeight, usable * 0.55)
            let maxTop = max(safeMinTop, usable - safeMinBottom)
            let topHeight = min(maxTop, max(safeMinTop, usable * topSplitRatio))

            VStack(spacing: 0) {
                // Top island: tabs header + compact toolbar + group list
                VStack(spacing: 0) {
                    ProjectTabsHeader(project: project)
                    topToolbar(result: result)
                    Rectangle().fill(Color.difHairline).frame(height: 1)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(result.groups) { group in
                                AIGroupRow(
                                    group: group,
                                    isSelected: group.id == activeGroupID
                                ) {
                                    store.selectAIGroup(group, in: project, openFirstFile: true)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: topHeight)
                .islandCard(background: .difPanel)

                // Draggable split handle (double-click restores default 43% / 57% split)
                DividerGrip(
                    axis: .rows,
                    islandGap: true,
                    onDrag: { translation in
                        guard let translation else {
                            dragStartTopHeight = nil
                            return
                        }
                        let start = dragStartTopHeight ?? topHeight
                        if dragStartTopHeight == nil { dragStartTopHeight = topHeight }
                        let nextTop = min(maxTop, max(safeMinTop, start + Double(translation)))
                        if usable > 0 {
                            topSplitRatio = nextTop / usable
                        }
                    },
                    onDoubleClick: {
                        withAnimation(.snappy(duration: 0.2)) {
                            topSplitRatio = Self.defaultTopRatio
                        }
                    }
                )

                // Bottom island: selected group's changed files tree/list (aligned with ChangesList)
                if let snapshot {
                    AIGroupChangesPane(
                        project: project,
                        snapshot: snapshot,
                        focusToken: filesFocusToken + store.listFocusToken
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .islandCard(background: .difPanel)
                } else {
                    EmptyListState(
                        symbol: "tray",
                        title: L("Select a group", "选择一个分组"),
                        detail: ""
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .islandCard(background: .difPanel)
                }
            }
        }
    }

    private func topToolbar(result: AIHunkGroupingResult) -> some View {
        let modelTag: String = {
            if let model = result.model, !model.isEmpty {
                return "\(result.provider.executableName) · \(model)"
            }
            return result.provider.executableName
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("\(result.groups.count) groups · \(result.totalHunks) changes",
                       "\(result.groups.count) 组 · \(result.totalHunks) 处改动"))
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)

                Text(modelTag)
                    .font(.ui(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.difText2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difChip))
                    .help(modelTag)

                Spacer(minLength: 4)

                if project.isGeneratingGroups {
                    Button {
                        store.cancelAIGroupGeneration(for: project)
                    } label: {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.5)
                                .frame(width: UI.s(11), height: UI.s(11))
                            Text(L("Cancel", "取消"))
                                .font(.ui(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color.difAccent)
                        .padding(.horizontal, 7)
                        .frame(height: UI.s(22))
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difSelection))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Cancel AI grouping", "取消 AI 分组"))
                } else {
                    let regenerateDisabled = project.changes.isEmpty || project.isCommittingGroup || project.isCommitting
                    IconButton(symbol: "sparkles",
                               help: L("Regenerate AI groups", "重新生成 AI 分组"),
                               size: 11.5) {
                        store.generateAIGroups(for: project)
                    }
                    .disabled(regenerateDisabled)
                    .opacity(regenerateDisabled ? 0.35 : 1)
                }

                IconButton(symbol: "xmark.circle",
                           help: L("Clear groups", "清空分组"),
                           size: 11.5) {
                    store.clearAIGroups(for: project)
                }
                .disabled(project.isCommittingGroup)
                .opacity(project.isCommittingGroup ? 0.35 : 1)
            }

            // Inline quick provider/model switcher for AI Grouping
            AgentModelSelectorCard(task: .grouping, compact: true)

            if let error = project.aiGroupError, !error.isEmpty {
                errorCard(message: error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func errorCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difRemoved)
                    .padding(.top, 1)
                Text(message)
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack {
                Spacer()
                Button {
                    project.aiGroupError = nil
                } label: {
                    Text(L("Dismiss", "关闭"))
                        .font(.ui(size: 11, weight: .medium))
                        .foregroundStyle(Color.difText2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip))
                }
                .buttonStyle(.plain)

                Button {
                    store.generateAIGroups(for: project)
                } label: {
                    Text(L("Retry", "重试"))
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difAccent))
                }
                .buttonStyle(.plain)
                .disabled(project.changes.isEmpty || project.isGeneratingGroups || project.isCommittingGroup || project.isCommitting)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.difRemoved.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.difRemoved.opacity(0.28), lineWidth: 1)
        )
    }
}

// MARK: - Top Pane: Group List Row

private struct AIGroupRow: View {
    let group: AIHunkGroup
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false

    var body: some View {
        let trimmedSummary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 6) {
                    Text(group.name)
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundStyle(Color.difText)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 4)

                    Text(L("\(group.fileCount)F · \(group.hunkCount)H",
                           "\(group.fileCount) 文件 · \(group.hunkCount) 处"))
                        .font(.ui(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.difAccent : Color.difText3)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                .fill(isSelected ? Color.difAccent.opacity(0.15) : Color.difChip)
                        )
                        .fixedSize()
                }

                if !trimmedSummary.isEmpty {
                    Text(trimmedSummary)
                        .font(.ui(size: 11))
                        .foregroundStyle(isSelected ? Color.difText2 : Color.difText3)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.difSelection : (hovering ? Color.difHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isSelected ? Color.difAccent.opacity(0.45) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(trimmedSummary.isEmpty ? group.name : "\(group.name)\n\(trimmedSummary)")
    }
}

// MARK: - Bottom Pane: Selected Group Changes Tree/List

private struct AIGroupChangesPane: View {
    @Bindable var project: Project
    let snapshot: Project.GroupChangesSnapshot
    var focusToken: Int
    @Environment(AppStore.self) private var store

    var body: some View {
        let group = snapshot.group
        let rows = snapshot.rows
        let flat = store.settings.flatList
        let trimmedSummary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExpandedFolder = rows.contains { $0.file == nil && $0.isExpanded }

        VStack(spacing: 0) {
            // Selected group header (mirrors CommitDetail's summary + filesBar chrome)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(group.name)
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundStyle(Color.difText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if snapshot.totalAdditions > 0 || snapshot.totalDeletions > 0 {
                        StatBadge(additions: snapshot.totalAdditions, deletions: snapshot.totalDeletions, size: 10.5)
                    }
                }
                if !trimmedSummary.isEmpty {
                    Text(trimmedSummary)
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            // Compact files toolbar: counts + expand/collapse all + tree/flat toggle
            HStack(spacing: 4) {
                Text(L("\(group.fileCount) \(group.fileCount == 1 ? "file" : "files") · \(group.hunkCount) \(group.hunkCount == 1 ? "change" : "changes")",
                       "\(group.fileCount) 个文件 · \(group.hunkCount) 处改动"))
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if !flat, !snapshot.folderIDs.isEmpty {
                    IconButton(
                        symbol: hasExpandedFolder ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                        help: hasExpandedFolder ? L("Collapse all folders", "折叠全部目录") : L("Expand all folders", "展开全部目录"),
                        size: 11
                    ) {
                        if hasExpandedFolder {
                            project.collapseAllGroupFolders(flat: flat)
                        } else {
                            project.expandAllGroupFolders()
                        }
                    }
                }
                IconButton(
                    symbol: flat ? "list.bullet" : "list.bullet.indent",
                    help: flat ? L("Group by directory", "按目录分组") : L("Flat list", "平铺列表"),
                    size: 11.5
                ) {
                    store.settings.flatList.toggle()
                    store.settings.save()
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 2)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            if rows.isEmpty {
                EmptyListState(
                    symbol: "doc.text",
                    title: L("No files in this group", "该分组暂无变更文件"),
                    detail: ""
                )
            } else {
                KeyboardList(
                    rows: rows,
                    selection: Binding(
                        get: { project.selectedGroupRowID ?? project.selectedGroupFilePath.map(ChangeRow.fileID) },
                        set: { id in handleSelectionChange(id) }
                    ),
                    focusToken: focusToken,
                    onKey: { event, row in handleKey(event, row, rows) },
                    onClick: { row in handleRowClick(row) },
                    onDoubleClick: { row in
                        if row.file != nil {
                            store.focusViewer()
                        } else {
                            toggle(row)
                        }
                    },
                    menu: { row in rowMenu(row) }
                ) { row, _, _ in
                    let hunks = row.file.flatMap { snapshot.hunksByPath[$0.path] }
                    let isSelectedFile = row.file.map { $0.path == project.selectedGroupFilePath } ?? false
                    let activeHunk = isSelectedFile ? (project.selectedGroupHunkIndex ?? hunks?.first) : nil
                    ChangeRowView(
                        row: row,
                        showDirectory: flat,
                        inclusion: nil,
                        groupHunks: hunks,
                        activeGroupHunk: activeHunk,
                        onSelectGroupHunk: row.file.map { file in
                            { hunkIdx in
                                store.openGroupItem(
                                    project: project,
                                    group: snapshot.group,
                                    filePath: file.path,
                                    hunkIndex: hunkIdx
                                )
                            }
                        }
                    ) {
                        toggle(row)
                    }
                }
            }

            Rectangle().fill(Color.difHairline).frame(height: 1)

            AIGroupCommitBox(
                project: project,
                group: group,
                hasFiles: !snapshot.changes.isEmpty
            )
        }
    }

    private func handleSelectionChange(_ id: String?) {
        project.selectedGroupRowID = id
        guard let id, id.hasPrefix("f:") else { return }
        let path = String(id.dropFirst(2))
        let hunks = snapshot.hunksByPath[path] ?? [0]
        let preferredHunk = (project.selectedGroupFilePath == path ? project.selectedGroupHunkIndex : nil)
            .flatMap { hunks.contains($0) ? $0 : nil }
            ?? hunks.first
            ?? 0
        store.openGroupItem(
            project: project,
            group: snapshot.group,
            filePath: path,
            hunkIndex: preferredHunk
        )
    }

    private func handleRowClick(_ row: ChangeRow) {
        if let file = row.file {
            // Re-open if clicking the already-selected file row after browsing elsewhere or viewing an external file.
            let needsReopen = project.browsedPath != nil
                || store.externalRequest != nil
                || store.viewer.request?.root != project.url
                || store.viewer.request?.path != file.path
            if needsReopen {
                let hunks = snapshot.hunksByPath[file.path] ?? [0]
                let targetHunk = project.selectedGroupHunkIndex.flatMap { hunks.contains($0) ? $0 : nil }
                    ?? hunks.first
                    ?? 0
                store.openGroupItem(
                    project: project,
                    group: snapshot.group,
                    filePath: file.path,
                    hunkIndex: targetHunk
                )
            }
        } else {
            toggle(row)
        }
    }

    private func toggle(_ row: ChangeRow) {
        guard row.file == nil else { return }
        if project.groupCollapsed.contains(row.id) {
            project.groupCollapsed.remove(row.id)
        } else {
            project.groupCollapsed.insert(row.id)
        }
    }

    private func handleKey(_ event: NSEvent, _ row: ChangeRow?, _ rows: [ChangeRow]) -> Bool {
        switch event.keyCode {
        case 123: // ← collapse, or move to parent folder
            guard let row else { return true }
            if row.file == nil, row.isExpanded {
                project.groupCollapsed.insert(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }),
                      let parent = rows[..<index].last(where: { $0.depth < row.depth }) {
                project.selectedGroupRowID = parent.id
            }
            return true
        case 124: // → expand folder, or step into its first child
            guard let row, row.file == nil else { return true }
            if !row.isExpanded {
                project.groupCollapsed.remove(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }), index + 1 < rows.count {
                handleSelectionChange(rows[index + 1].id)
            }
            return true
        case 49: // Space toggles folder expand/collapse
            guard let row, row.file == nil else { return false }
            toggle(row)
            return true
        case 36, 76: // ↩
            if let row, row.file == nil { toggle(row) } else { store.focusViewer() }
            return true
        default:
            return false
        }
    }

    private func rowMenu(_ row: ChangeRow) -> NSMenu? {
        let menu = NSMenu()
        if let file = row.file {
            let hunks = snapshot.hunksByPath[file.path] ?? [0]
            menu.addItem(ClosureMenuItem(L("Show Diff", "查看差异")) {
                store.openGroupItem(
                    project: project,
                    group: snapshot.group,
                    filePath: file.path,
                    hunkIndex: hunks.first ?? 0
                )
                store.focusViewer()
            })
            if file.kind != .untracked, file.kind != .added {
                menu.addItem(ClosureMenuItem(L("Show History", "查看历史")) {
                    store.showHistory(path: file.path, in: project)
                })
            }
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
            })
            menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) {
                store.copyText(file.path)
            })
            return menu
        }
        menu.addItem(ClosureMenuItem(row.isExpanded ? L("Collapse", "折叠") : L("Expand", "展开")) { toggle(row) })
        menu.addItem(ClosureMenuItem(L("Expand All", "全部展开")) { project.expandAllGroupFolders() })
        menu.addItem(ClosureMenuItem(L("Collapse All", "全部折叠")) { project.collapseAllGroupFolders(flat: store.settings.flatList) })
        return menu
    }
}

// MARK: - Bottom Pane: Direct Group Commit Box

private struct AIGroupCommitBox: View {
    @Bindable var project: Project
    let group: AIHunkGroup
    let hasFiles: Bool
    @Environment(AppStore.self) private var store
    @State private var editing = false
    @State private var focusToken = 0
    @State private var focusRequestedAt: CFTimeInterval = 0
    @State private var hoveringAI = false
    @State private var hoveringReset = false

    var body: some View {
        let currentMessage = project.commitMessage(for: group)
        let isCustomized = project.isGroupCommitMessageCustomized(for: group)
        let isGeneratingThisGroup = project.generatingGroupCommitID == group.id
        let isCommitting = project.isCommittingGroup || project.isCommitting
        let operation = project.status.operation
        let trimmed = currentMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let canCommit = hasFiles && operation == nil && !isCommitting && !trimmed.isEmpty
        let canReset = isCustomized && !isCommitting && !isGeneratingThisGroup
        let aiDisabled = !isGeneratingThisGroup && (!hasFiles || isCommitting || operation != nil)

        VStack(spacing: 0) {
            CommitMessageEditor(
                text: Binding(
                    get: { project.commitMessage(for: group) },
                    set: { project.setCommitMessage($0, for: group) }
                ),
                placeholder: L("Group commit message", "分组提交说明"),
                focusToken: focusToken,
                requestedAt: focusRequestedAt,
                onSubmit: {
                    guard canCommit else { return }
                    store.commitGroup(for: project, group: group)
                },
                onCommitAndPush: {
                    guard canCommit else { return }
                    store.commitGroup(for: project, group: group)
                },
                onCancel: { store.focusList() },
                onFocusChange: { editing = $0 }
            )
            .padding(.horizontal, 4)
            .padding(.top, 5)
            .frame(maxHeight: .infinity)

            HStack(spacing: 5) {
                Button {
                    store.resetGroupCommitMessage(for: project, group: group)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.ui(size: 10, weight: .semibold))
                        Text(L("Reset", "恢复分组描述"))
                            .font(.ui(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(canReset ? Color.difAccent : Color.difText3.opacity(0.45))
                    .padding(.horizontal, 6)
                    .frame(height: UI.s(24))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(canReset
                                  ? Color.difAccent.opacity(hoveringReset ? 0.2 : 0.12)
                                  : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canReset)
                .onHover { hoveringReset = $0 }
                .help(L("Restore generated group title and description", "恢复为已生成的分组名称和描述"))

                Spacer(minLength: 4)

                if !AppEnvironment.isAppStore {
                    Button {
                        store.generateGroupCommitMessage(for: project, group: group)
                    } label: {
                        ZStack {
                            if isGeneratingThisGroup {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.55)
                                    .frame(width: UI.s(13), height: UI.s(13))
                            } else {
                                Image(systemName: "sparkles")
                                    .font(.ui(size: 12, weight: .medium))
                                    .foregroundStyle(aiDisabled ? Color.difText3.opacity(0.6) : Color.difAccent)
                            }
                        }
                        .frame(width: UI.s(26), height: UI.s(24))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isGeneratingThisGroup
                                      ? Color.difSelection
                                      : (hoveringAI && !aiDisabled ? Color.difHover : Color.clear))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(aiDisabled)
                    .onHover { hoveringAI = $0 }
                    .help(aiHelp(isGenerating: isGeneratingThisGroup, hasFiles: hasFiles))
                }

                Button {
                    store.commitGroup(for: project, group: group)
                } label: {
                    HStack(spacing: 5) {
                        if project.isCommittingGroup {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.55)
                                .frame(width: UI.s(12), height: UI.s(12))
                        }
                        Text(L("Commit Group", "提交本组"))
                            .font(.ui(size: 11.5, weight: .semibold))
                        Text("⌘↩")
                            .font(.ui(size: 10, weight: .medium, design: .rounded))
                            .opacity(0.65)
                    }
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: UI.s(24))
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.difAccent.opacity(canCommit ? 1 : 0.38))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canCommit)
                .help(commitHelp(trimmedEmpty: trimmed.isEmpty, hasFiles: hasFiles))
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .frame(height: UI.s(100))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difChip))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(editing ? Color.difAccent.opacity(0.7) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            focusRequestedAt = CACurrentMediaTime()
            focusToken += 1
        }
        .padding(8)
    }

    private func aiHelp(isGenerating: Bool, hasFiles: Bool) -> String {
        let provider = store.settings.aiProvider(for: .commit)
        let model = store.settings.aiModel(for: provider, task: .commit)
        let agentDesc = model.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
        if isGenerating {
            return L("Generating commit message with \(agentDesc)… Click to cancel",
                     "正在使用 \(agentDesc) 生成提交信息… 点击取消")
        }
        if !hasFiles {
            return L("No changes in this group", "该分组暂无变更")
        }
        return L("Regenerate commit message with \(agentDesc)",
                 "使用 \(agentDesc) 重新生成提交信息")
    }

    private func commitHelp(trimmedEmpty: Bool, hasFiles: Bool) -> String {
        if let operation = project.status.operation {
            return L("A \(operation.command) is in progress · finish it in Changes first",
                     "正在进行 \(operation.command) · 请先在变更页完成")
        }
        if !hasFiles {
            return L("No changes in this group", "该分组暂无变更")
        }
        if trimmedEmpty {
            return L("Write a commit message first", "先写提交说明")
        }
        return L("Commit only this group's changes (⌘↩)", "仅提交该分组的变更 (⌘↩)")
    }
}

// MARK: - Inline Agent Provider & Model Picker

private struct AgentModelSelectorCard: View {
    var task: Settings.AITask
    var compact: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        let provider = store.settings.aiProvider(for: task)
        let availability = store.availability(for: provider)
        let models = store.agentModelsByProvider[provider] ?? []
        let isLoading = store.loadingModelsProviders.contains(provider)
        let modelError = store.agentModelErrors[provider]
        let selectedModel = store.settings.aiModel(for: provider, task: task)
        let defaultModel = models.first(where: \.isDefault)
        let missingModel: String? = selectedModel.flatMap { chosen in
            models.isEmpty || models.contains(where: { $0.id == chosen }) ? nil : chosen
        }

        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            if compact {
                HStack(spacing: 5) {
                    providerMenu(provider: provider, availability: availability)
                    modelMenu(provider: provider, models: models, selectedModel: selectedModel,
                              defaultModel: defaultModel, missingModel: missingModel)
                    refreshModelsButton(provider: provider, isLoading: isLoading)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(L("Agent", "助手"))
                            .font(.ui(size: 11, weight: .medium))
                            .foregroundStyle(Color.difText2)
                            .frame(width: UI.s(42), alignment: .leading)
                        providerMenu(provider: provider, availability: availability)
                    }
                    HStack(spacing: 6) {
                        Text(L("Model", "模型"))
                            .font(.ui(size: 11, weight: .medium))
                            .foregroundStyle(Color.difText2)
                            .frame(width: UI.s(42), alignment: .leading)
                        modelMenu(provider: provider, models: models, selectedModel: selectedModel,
                                  defaultModel: defaultModel, missingModel: missingModel)
                        refreshModelsButton(provider: provider, isLoading: isLoading)
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difChip.opacity(0.65)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.difHairline, lineWidth: 1)
                )
            }

            if store.agentAvailabilityChecked, availability?.isInstalled == false {
                HStack(spacing: 4) {
                    Circle().fill(Color.difRemoved).frame(width: 5, height: 5)
                    Text(L("\(provider.executableName) not found in PATH",
                           "未在 PATH 中找到 \(provider.executableName)"))
                        .font(.ui(size: 10.5))
                        .foregroundStyle(Color.difRemoved)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if let modelError, !modelError.isEmpty {
                Text(modelError)
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difRemoved)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func providerMenu(provider: AgentProvider, availability: AgentAvailability?) -> some View {
        Picker("", selection: Binding<AgentProvider>(
            get: { store.settings.aiProvider(for: task) },
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
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .help(availability?.executablePath ?? provider.displayName)
    }

    private func modelMenu(
        provider: AgentProvider,
        models: [AgentModel],
        selectedModel: String?,
        defaultModel: AgentModel?,
        missingModel: String?
    ) -> some View {
        Picker("", selection: Binding<String?>(
            get: { selectedModel },
            set: { store.selectAgentModel($0, for: provider, task: task) }
        )) {
            Text(defaultModel.map { L("Default (\($0.name))", "默认（\($0.name)）") }
                 ?? L("Auto (Default)", "自动（默认）"))
                .tag(String?.none)
            if !models.isEmpty || missingModel != nil {
                Divider()
            }
            ForEach(models) { model in
                Text(model.isDefault ? "\(model.name) (\(L("default", "默认")))" : model.name)
                    .tag(String?.some(model.id))
            }
            if let missingModel {
                Text("\(missingModel) (\(L("saved", "已保存")))")
                    .tag(String?.some(missingModel))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .frame(maxWidth: .infinity)
        .help(selectedModel ?? defaultModel?.name ?? L("Provider default model", "使用默认模型"))
    }

    private func refreshModelsButton(provider: AgentProvider, isLoading: Bool) -> some View {
        ZStack {
            IconButton(symbol: "arrow.clockwise",
                       help: L("Refresh model list", "刷新模型列表"),
                       size: 11) {
                Task {
                    await store.refreshAgentAvailability(forceRefresh: true)
                    store.loadAgentModels(for: provider, forceRefresh: true)
                }
            }
            .opacity(isLoading ? 0 : 1)
            .disabled(isLoading)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.5)
                    .frame(width: UI.s(20), height: UI.s(20))
            }
        }
    }
}
