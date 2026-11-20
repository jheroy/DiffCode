import SwiftUI

/// Middle column: a project's local changes, AI change groups, or its commit log.
struct ProjectPanel: View {
    @Bindable var project: Project

    var body: some View {
        switch project.tab {
        case .changes:
            if project.comparison != nil { ComparisonList(project: project) } else { ChangesList(project: project) }
        case .groups:
            AIGroupPanel(project: project)
        case .log:
            LogPanel(project: project)
        }
    }
}

/// Top tab bar (`Changes` / `Groups` / `Log`) + toolbar buttons + hairline, rendered inside the top island card.
struct ProjectTabsHeader: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Color.difHairline).frame(height: 1)
        }
    }

    /// The top row, level with the window's title bar: the two tabs, then the list's own buttons.
    /// The project's name and branch are in the sidebar; they are not repeated here.
    ///
    /// The column can be narrow, and with the sidebar hidden the traffic lights take part of it: rather than
    /// run under them, the row sheds the buttons that have a shortcut elsewhere, least needed first.
    private var tabs: some View {
        ViewThatFits(in: .horizontal) {
            tabRow(buttons: .all)
            tabRow(buttons: .refresh)
            tabRow(buttons: .none)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // With the sidebar hidden this row is under the window's traffic lights.
        .padding(.leading, store.sidebarVisible || store.isFullScreen ? 8 : 78)
        .padding(.trailing, 8)
        .frame(height: store.titlebarHeight)
        .clipped()
        .background(WindowDragArea())
    }

    private enum RowButtons { case all, refresh, none }

    private func tabRow(buttons: RowButtons) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                TabButton(title: L("Changes", "变更"), count: project.comparison != nil ? project.compareChanges.count : project.changes.count,
                          shortcut: "⌘0", isSelected: project.tab == .changes) {
                    store.setTab(.changes)
                }
                if !AppEnvironment.isAppStore {
                    TabButton(title: L("Groups", "分组"), count: project.aiGroupResult?.groups.count,
                              shortcut: "⌘8", isSelected: project.tab == .groups) {
                        store.setTab(.groups)
                    }
                }
                TabButton(title: L("Log", "历史"), count: nil, shortcut: "⌘9", isSelected: project.tab == .log) {
                    store.setTab(.log)
                }
            }
            .frame(maxHeight: .infinity)
            .titlebarClickGuard(horizontalOutset: 4)
            Spacer(minLength: 0)
            if buttons != .none {
                HStack(spacing: 4) {
                    if buttons == .all, project.tab == .changes, project.comparison == nil {
                        let targets = store.selectedChanges(in: project).filter(AppStore.canRollback)
                        IconButton(symbol: "arrow.uturn.backward", help: L("Rollback… (⌥⌘Z)", "回滚… (⌥⌘Z)"), size: 11.5) {
                            store.rollback(targets, in: project)
                        }
                        .disabled(targets.isEmpty)
                        .opacity(targets.isEmpty ? 0.35 : 1)
                    }
                    // The spinner takes the button's place, so nothing shifts while a refresh runs.
                    ZStack {
                        IconButton(symbol: "arrow.clockwise", help: L("Refresh", "刷新"), size: 11.5) { store.refreshCurrent() }
                            .opacity(project.isRefreshing ? 0 : 1)
                        if project.isRefreshing {
                            ProgressView().controlSize(.small).scaleEffect(0.6).allowsHitTesting(false)
                        }
                    }
                    if buttons == .all, project.tab == .changes {
                        IconButton(symbol: "tray.full", help: L("Stashes…", "Stash 列表…"), size: 11.5) { store.showStashes() }
                    }
                    if buttons == .all, project.tab != .groups || project.aiGroupResult != nil {
                        IconButton(symbol: store.settings.flatList ? "list.bullet" : "list.bullet.indent",
                                   help: L("Toggle Tree / Flat List", "切换 目录树 / 平铺列表"), size: 12) {
                            store.settings.flatList.toggle()
                            store.settings.save()
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .titlebarClickGuard(horizontalOutset: 4)
            }
        }
    }
}

private struct TabButton: View {
    var title: String
    var count: Int?
    var shortcut: String
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.ui(size: 12, weight: isSelected ? .semibold : .medium))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.ui(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Color.difAccent : Color.difText3)
                }
            }
            .foregroundStyle(isSelected ? Color.difText : Color.difText2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.difChip : (hovering ? Color.difHover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(title) (\(shortcut))")
    }
}

// MARK: - Local changes

struct ChangesList: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var settings = store.settings
        let rows = ChangeTree.rows(changes: project.changes, flat: store.settings.flatList, collapsed: project.collapsed,
                                   filter: project.filter, splitUnversioned: true)
        let ticks = inclusion(for: rows)
        GeometryReader { proxy in
            let showsCommit = !project.changes.isEmpty || project.amend
            let availableHeight = max(0, proxy.size.height - store.titlebarHeight - 1 - IslandStyle.gap)
            let ceiling = CommitPanel.heightCeiling(columnHeight: availableHeight)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ProjectTabsHeader(project: project)
                    if let operation = project.status.operation {
                        OperationBanner(project: project, operation: operation)
                    }
                    if project.changes.count > 8 || !project.filter.isEmpty {
                        FilterField(text: $project.filter, placeholder: L("Filter files", "筛选文件"))
                    }
                    if let message = project.errorMessage, project.changes.isEmpty {
                        EmptyListState(symbol: "exclamationmark.triangle", title: L("Could not read repository", "无法读取仓库"), detail: message)
                    } else if project.changes.isEmpty {
                        if project.hasLoaded {
                            EmptyListState(symbol: "checkmark.seal", title: L("Working tree clean", "工作区很干净"),
                                           detail: L("Nothing to compare. Press ⌘9 to browse history.", "没有改动。按 ⌘9 查看提交历史。"))
                        } else {
                            Spacer()
                        }
                    } else if rows.isEmpty {
                        EmptyListState(symbol: "line.3.horizontal.decrease.circle", title: L("No files match", "没有匹配的文件"), detail: "")
                    } else {
                        KeyboardList(rows: rows, selection: $project.selectedChangeID, multiSelection: $project.selectedChangeIDs,
                                     focusToken: store.listFocusToken,
                                     onKey: { event, row in handleKey(event, row, rows) },
                                     onDoubleClick: { row in
                                         if row.file != nil { store.focusViewer() } else { toggle(row) }
                                     },
                                     menu: { row in rowMenu(row) },
                                     dragURLs: { row in project.existingURLs(store.editTargets(for: row, in: project)) }) { row, _, _ in
                            ChangeRowView(row: row, showDirectory: store.settings.flatList, inclusion: ticks[row.id],
                                          onToggleInclusion: { toggleInclusion(row) }) { toggle(row) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .islandCard(background: .difPanel)

                if showsCommit {
                    HorizontalResizeHandle(height: $settings.commitBoxHeight,
                                           range: Settings.commitBoxRange.lowerBound...ceiling,
                                           islandGap: true) { settings.save() }
                    CommitPanel(project: project, columnHeight: availableHeight)
                        .islandCard(background: .difPanel)
                }
            }
        }
        .onChange(of: project.selectedChangeID) { _, _ in store.changeSelectionChanged(project) }
    }

    private func toggle(_ row: ChangeRow) {
        guard row.file == nil else { return }
        if project.collapsed.contains(row.id) { project.collapsed.remove(row.id) } else { project.collapsed.insert(row.id) }
    }

    /// Each row's tick: a file's own, or for a folder or group whether all, some or none of the files under it go in.
    private func inclusion(for rows: [ChangeRow]) -> [String: Inclusion] {
        let visible = store.visibleChanges(in: project)
        var result: [String: Inclusion] = [:]
        for row in rows {
            if let file = row.file {
                result[row.id] = project.inclusion(file)
            } else {
                let ticks = ChangeTree.files(for: [row.id], in: visible).map(project.inclusion)
                result[row.id] = ticks.allSatisfy { $0 == .off } ? .off : (ticks.allSatisfy { $0 == .on } ? .on : .mixed)
            }
        }
        return result
    }

    private func toggleInclusion(_ row: ChangeRow) {
        let files = ChangeTree.files(for: [row.id], in: store.visibleChanges(in: project))
        guard !files.isEmpty else { return }
        // A partly ticked file or folder becomes wholly ticked, as a mixed checkbox does.
        project.setIncluded(!files.allSatisfy { project.inclusion($0) == .on }, files)
    }

    private func handleKey(_ event: NSEvent, _ row: ChangeRow?, _ rows: [ChangeRow]) -> Bool {
        switch event.keyCode {
        case 123: // ← collapse, or move to the parent row
            guard let row else { return true }
            if row.file == nil, row.isExpanded {
                project.collapsed.insert(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }),
                      let parent = rows[..<index].last(where: { $0.depth < row.depth }) {
                project.selectedChangeID = parent.id
            }
            return true
        case 124: // → expand
            if let row, row.file == nil, !row.isExpanded { project.collapsed.remove(row.id) }
            return true
        case 36, 76: // ↩
            if let row, row.file == nil { toggle(row) } else { store.focusViewer() }
            return true
        case 53:
            if !project.filter.isEmpty { project.filter = ""; return true }
            return false
        case 51, 117: // ⌫ and ⌦: new files go to the Trash
            store.deleteInContext()
            return true
        case 49: // Space ticks or unticks the selection for the commit, as in the IDE
            store.toggleIncludedSelection(in: project)
            return true
        default:
            return false
        }
    }

    /// "Rollback…" and "Delete…" for whatever the menu applies to: the selection if the row is in it, else the row.
    private func addEditItems(_ row: ChangeRow, to menu: NSMenu) {
        let targets = store.editTargets(for: row, in: project)
        let rollback = targets.filter(AppStore.canRollback)
        let delete = targets.filter(AppStore.canDelete)
        if !rollback.isEmpty {
            menu.addItem(ClosureMenuItem(rollback.count == 1 ? L("Rollback…", "回滚…")
                                                             : L("Rollback \(rollback.count) Files…", "回滚 \(rollback.count) 个文件…")) {
                store.rollback(rollback, in: project)
            })
        }
        if !delete.isEmpty {
            menu.addItem(ClosureMenuItem(delete.count == 1 ? L("Delete…", "删除…")
                                                           : L("Delete \(delete.count) Files…", "删除 \(delete.count) 个文件…")) {
                store.delete(delete, in: project)
            })
        }
        if !rollback.isEmpty || !delete.isEmpty { menu.addItem(.separator()) }
    }

    /// Built on the right-click (see `KeyboardList.menu`), rather than a SwiftUI menu kept on every row.
    private func rowMenu(_ row: ChangeRow) -> NSMenu {
        let menu = NSMenu()
        if let file = row.file, file.kind == .conflicted {
            menu.addItem(ClosureMenuItem(L("Resolve…", "解决冲突…")) {
                project.selectedChangeID = row.id
                store.focusViewer()
            })
            menu.addItem(ClosureMenuItem(L("Mark as Resolved", "标记为已解决")) { store.markResolved(file.path, in: project) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Keep HEAD’s Version", "保留 HEAD 的版本")) { store.takeSide(.ours, path: file.path, in: project) })
            menu.addItem(ClosureMenuItem(L("Take Incoming Version", "采用传入的版本")) { store.takeSide(.theirs, path: file.path, in: project) })
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
            })
            menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) { store.copyText(file.path) })
            return menu
        }
        if let file = row.file {
            menu.addItem(ClosureMenuItem(L("Show Diff", "查看差异")) {
                project.selectedChangeID = row.id
                store.focusViewer()
            })
            if file.kind != .untracked, file.kind != .added {
                menu.addItem(ClosureMenuItem(L("Show History", "查看历史")) { store.showHistory(path: file.path, in: project) })
            }
            menu.addItem(.separator())
            addEditItems(row, to: menu)
            menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
            })
            menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) { store.copyText(file.path) })
        } else {
            addEditItems(row, to: menu)
            menu.addItem(ClosureMenuItem(row.isExpanded ? L("Collapse", "折叠") : L("Expand", "展开")) { toggle(row) })
            menu.addItem(ClosureMenuItem(L("Expand All", "全部展开")) { project.collapsed.removeAll() })
        }
        return menu
    }
}

/// Over the Changes list while git is in the middle of a merge or rebase: how many files are still in conflict, and
/// the way out either side (Continue, or Abort back to the start).
private struct OperationBanner: View {
    let project: Project
    let operation: RepoOperation
    @Environment(AppStore.self) private var store

    var body: some View {
        let conflicts = project.status.conflictCount
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: conflicts > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.ui(size: 12, weight: .semibold))
                .foregroundStyle(conflicts > 0 ? Color.orange : Color.difAdded)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.difText)
                Text(detail(conflicts))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difText2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if operation != .merge {
                BannerButton(title: L("Continue", "继续"), prominent: true) { store.continueOperation(in: project) }
                    .disabled(conflicts > 0 || project.activity != nil)
                    .opacity(conflicts > 0 ? 0.45 : 1)
                BannerButton(title: L("Skip", "跳过"), prominent: false) { store.skipOperation(in: project) }
                    .disabled(project.activity != nil)
                    .help(L("Leave out the commit it stopped at, and go on", "略过停下的这个提交，继续后面的"))
            }
            BannerButton(title: L("Abort", "中止"), prominent: false) { store.abortOperation(in: project) }
                .disabled(project.activity != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill((conflicts > 0 ? Color.orange : Color.difAdded).opacity(0.13)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func detail(_ conflicts: Int) -> String {
        if conflicts > 0 {
            return conflicts == 1 ? L("1 file in conflict · open it to pick a side", "1 个文件有冲突 · 打开它选择保留哪一边")
                                  : L("\(conflicts) files in conflict · open each to pick a side", "\(conflicts) 个文件有冲突 · 逐个打开选择保留哪一边")
        }
        return operation == .merge ? L("All resolved · commit to finish the merge", "冲突已全部解决 · 提交即可完成合并")
                                   : L("All resolved · continue", "冲突已全部解决 · 可以继续")
    }
}

struct BannerButton: View {
    var title: String
    var prominent: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : Color.difText)
                .padding(.horizontal, 9)
                .frame(height: UI.s(22))
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(prominent ? Color.difAccent.opacity(hovering ? 0.85 : 1) : Color.difText.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A filter the list is under, with ✕ to drop it: the branch the Log lists, or the file whose history it lists.
struct FilterChip: View {
    var symbol: String
    var text: String
    var help: String
    var clearHelp: String
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.ui(size: 9.5, weight: .semibold))
            Text(text).font(.ui(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            Button(action: onClear) {
                Image(systemName: "xmark").font(.ui(size: 8, weight: .bold)).padding(3).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(clearHelp)
        }
        .foregroundStyle(Color.difAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.difSelection))
        .help(help)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.top, 4)
    }
}

// MARK: - Comparison

/// The Changes tab while it compares the working tree with another commit or branch: every file that differs from
/// it, committed since or not. Nothing here rolls back or commits; ✕ goes back to the local changes.
struct ComparisonList: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        let rows = ChangeTree.rows(changes: project.compareChanges, flat: store.settings.flatList, collapsed: project.compareCollapsed,
                                   filter: project.filter, splitUnversioned: true)
        VStack(spacing: 0) {
            ProjectTabsHeader(project: project)
            if let comparison = project.comparison {
                if let stash = comparison.stash {
                    StashBanner(entry: stash, project: project)
                } else {
                    ComparisonBanner(comparison: comparison) { store.endComparison() }
                }
            }
            if project.compareChanges.count > 8 || !project.filter.isEmpty {
                FilterField(text: $project.filter, placeholder: L("Filter files", "筛选文件"))
            }
            if project.compareChanges.isEmpty {
                if project.isLoadingCompare {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                } else if let error = project.compareError {
                    EmptyListState(symbol: "exclamationmark.triangle", title: error, detail: "")
                } else {
                    let title = project.comparison?.title ?? ""
                    EmptyListState(symbol: "equal.circle", title: L("No differences", "没有差异"),
                                   detail: project.comparison?.other.map { other in
                                       L("\(title) and \(other.title) have the same files.", "\(title) 与 \(other.title) 的文件完全相同。")
                                   } ?? L("The working tree is the same as \(title).", "工作区与 \(title) 完全相同。"))
                }
            } else if rows.isEmpty {
                EmptyListState(symbol: "line.3.horizontal.decrease.circle", title: L("No files match", "没有匹配的文件"), detail: "")
            } else {
                KeyboardList(rows: rows, selection: $project.compareSelectedID, focusToken: store.listFocusToken,
                             onKey: { event, row in handleKey(event, row, rows) },
                             onDoubleClick: { row in
                                 if row.file != nil { store.focusViewer() } else { toggle(row) }
                             },
                             menu: { row in menu(row) },
                             dragURLs: { row in
                                 // Only a comparison with the working tree has its files on disk.
                                 guard project.comparison?.head == nil else { return [] }
                                 return project.existingURLs(row.file.map { [$0] } ?? [])
                             }) { row, _, _ in
                    ChangeRowView(row: row, showDirectory: store.settings.flatList) { toggle(row) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .islandCard(background: .difPanel)
        .onChange(of: project.compareSelectedID) { _, _ in store.compareSelectionChanged(project) }
    }

    private func toggle(_ row: ChangeRow) {
        guard row.file == nil else { return }
        if project.compareCollapsed.contains(row.id) { project.compareCollapsed.remove(row.id) } else { project.compareCollapsed.insert(row.id) }
    }

    private func handleKey(_ event: NSEvent, _ row: ChangeRow?, _ rows: [ChangeRow]) -> Bool {
        switch event.keyCode {
        case 123: // ← collapse, or move to the parent row
            guard let row else { return true }
            if row.file == nil, row.isExpanded {
                project.compareCollapsed.insert(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }),
                      let parent = rows[..<index].last(where: { $0.depth < row.depth }) {
                project.compareSelectedID = parent.id
            }
            return true
        case 124: // → expand
            if let row, row.file == nil, !row.isExpanded { project.compareCollapsed.remove(row.id) }
            return true
        case 36, 76: // ↩
            if let row, row.file == nil { toggle(row) } else { store.focusViewer() }
            return true
        case 53:
            if !project.filter.isEmpty { project.filter = ""; return true }
            return false
        default:
            return false
        }
    }

    private func menu(_ row: ChangeRow) -> NSMenu? {
        let menu = NSMenu()
        guard let file = row.file else {
            menu.addItem(ClosureMenuItem(row.isExpanded ? L("Collapse", "折叠") : L("Expand", "展开")) { toggle(row) })
            menu.addItem(ClosureMenuItem(L("Expand All", "全部展开")) { project.compareCollapsed.removeAll() })
            return menu
        }
        menu.addItem(ClosureMenuItem(L("Show Diff", "查看差异")) {
            project.compareSelectedID = row.id
            store.focusViewer()
        })
        if file.kind != .untracked {
            menu.addItem(ClosureMenuItem(L("Show History", "查看历史")) { store.showHistory(path: file.path, in: project) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) {
            NSWorkspace.shared.activateFileViewerSelecting([project.url.appendingPathComponent(file.path)])
        })
        menu.addItem(ClosureMenuItem(L("Copy Path", "复制路径")) { store.copyText(file.path) })
        return menu
    }
}

/// What the Changes tab compares with, over its list.
private struct ComparisonBanner: View {
    var comparison: Comparison
    var onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.ui(size: 10.5, weight: .semibold))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.ui(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.difAccent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(comparison.other.map { other in
                    L("\(String(comparison.base.prefix(7))) → \(String(other.hash.prefix(7))), what the later commits changed",
                      "\(String(comparison.base.prefix(7))) → \(String(other.hash.prefix(7)))，其间提交的全部改动")
                } ?? L("\(String(comparison.base.prefix(7))) → working tree, commits included",
                       "\(String(comparison.base.prefix(7))) → 工作区，含其间的提交"))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.ui(size: 9, weight: .bold)).foregroundStyle(Color.difText2)
                    .padding(4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Stop comparing · back to the local changes", "退出比较 · 回到本地变更"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difSelection))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .help(comparison.other.map { "\(comparison.base)\n\($0.hash)" } ?? comparison.base)
    }

    private var headline: String {
        if let other = comparison.other {
            return L("Comparing \(comparison.title) with \(other.title)", "比较 \(comparison.title) 与 \(other.title)")
        }
        return comparison.forkPoint ? L("Since forking from \(comparison.title)", "自从与 \(comparison.title) 分叉以来")
                                    : L("Compared with \(comparison.title)", "与 \(comparison.title) 比较")
    }
}

/// Over the list while it shows what a stash holds: the stash, and what to do with it.
private struct StashBanner: View {
    var entry: StashEntry
    var project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "tray.full")
                    .font(.ui(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.difAccent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.ui(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.difAccent)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text([entry.name, entry.branch.map { L("on \($0)", "在 \($0) 上") }, entry.date.formatted(.relative(presentation: .named))]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(size: 10.5))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { store.endComparison(in: project) } label: {
                    Image(systemName: "xmark").font(.ui(size: 9, weight: .bold)).foregroundStyle(Color.difText2)
                        .padding(4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Close · back to the local changes", "关闭 · 回到本地变更"))
            }
            HStack(spacing: 6) {
                BannerButton(title: L("Apply", "应用"), prominent: true) { store.applyStash(entry, drop: false, in: project) }
                    .help(L("Bring its changes back; it stays in the list", "恢复它的改动；它仍留在列表里"))
                BannerButton(title: L("Pop", "弹出"), prominent: false) { store.applyStash(entry, drop: true, in: project) }
                    .help(L("Bring its changes back, then drop it", "恢复它的改动，然后从列表删除"))
                Spacer(minLength: 4)
                BannerButton(title: L("Drop…", "删除…"), prominent: false) { store.dropStash(entry, in: project) }
                    .help(L("Delete it from the list without applying it", "不应用，直接从列表删除"))
            }
            .disabled(project.activity != nil)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difSelection))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .help("\(entry.name) \(entry.hash)")
    }
}

struct FilterField: View {
    @Binding var text: String
    var placeholder: String
    /// Smaller when buttons follow the field on the same line.
    var trailingPadding: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(Color.difText3)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.ui(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.ui(size: 11)).foregroundStyle(Color.difText3)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: UI.s(26))
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip))
        .padding(.leading, 8)
        .padding(.trailing, trailingPadding)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

struct ChangeRowView: View {
    var row: ChangeRow
    var showDirectory: Bool
    /// The commit tick; nil where there is nothing to commit (a commit's own file list).
    var inclusion: Inclusion? = nil
    var onToggleInclusion: () -> Void = {}
    /// Optional 0-based hunk indices belonging to the active AI group for this file row (shown as jump badges when > 1).
    var groupHunks: [Int]? = nil
    var activeGroupHunk: Int? = nil
    var onSelectGroupHunk: ((Int) -> Void)? = nil
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Spacer().frame(width: CGFloat(row.depth) * 12 + 6)
            switch row.kind {
            case .group(let title, let count):
                chevron
                tick
                Text(title).font(.ui(size: 12, weight: .semibold)).foregroundStyle(Color.difText)
                Text(count == 1 ? L("1 file", "1 个文件") : L("\(count) files", "\(count) 个文件"))
                    .font(.ui(size: 11)).foregroundStyle(Color.difText3)
                Spacer(minLength: 0)
            case .directory(let name, let count):
                chevron
                tick
                Image(systemName: "folder.fill").font(.ui(size: 11)).foregroundStyle(Color(NSColor(hex: 0x7C9CCB)))
                Text(name).font(.ui(size: 12.5)).foregroundStyle(Color.difText2).lineLimit(1).truncationMode(.head)
                Text("\(count)").font(.ui(size: 10.5)).foregroundStyle(Color.difText3)
                Spacer(minLength: 0)
            case .file(let change):
                Spacer().frame(width: UI.s(12))
                tick
                FileIcon(path: change.path)
                Text(change.name)
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.status(change.kind))
                    .strikethrough(change.kind == .deleted, color: Color.status(.deleted).opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if showDirectory, !change.directory.isEmpty {
                    Text(change.directory).font(.ui(size: 11)).foregroundStyle(Color.difText3).lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 4)
                if let hunks = groupHunks, hunks.count > 1, let onSelectGroupHunk {
                    GroupHunkBadges(
                        hunks: hunks,
                        activeHunk: activeGroupHunk,
                        fileName: change.name,
                        onSelect: onSelectGroupHunk
                    )
                }
                StatBadge(additions: change.additions, deletions: change.deletions, size: 10.5)
                Text(change.kind.letter)
                    .font(.ui(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.status(change.kind))
                    .frame(width: UI.s(14))
            }
        }
        .padding(.trailing, 14)
        .help(helpText)
    }

    private var helpText: String {
        guard let change = row.file else { return "" }
        if let old = change.oldPath { return "\(old) → \(change.path)" }
        return change.path
    }

    @ViewBuilder
    private var tick: some View {
        if let inclusion {
            CommitCheckbox(state: inclusion, action: onToggleInclusion)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.ui(size: 8.5, weight: .bold))
            .foregroundStyle(Color.difText3)
            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            .frame(width: UI.s(12), height: UI.s(16))
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)
    }
}

/// Compact inline `#1` `#2` hunk jump badges shown on multi-hunk files in the Groups tab's changes list.
private struct GroupHunkBadges: View {
    var hunks: [Int]
    var activeHunk: Int?
    var fileName: String
    var onSelect: (Int) -> Void

    private static let maxInline = 3

    var body: some View {
        let inline = hunks.count <= Self.maxInline ? hunks : Array(hunks.prefix(2))
        let overflowCount = hunks.count - inline.count
        HStack(spacing: 3) {
            ForEach(inline, id: \.self) { hunkIdx in
                let isActive = activeHunk == hunkIdx
                Text("#\(hunkIdx + 1)")
                    .font(.ui(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.white : Color.difText2)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(isActive ? Color.difAccent : Color.difChip)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(hunkIdx) }
                    .help(L("Jump to hunk #\(hunkIdx + 1) in \(fileName)",
                            "跳转到 \(fileName) 的第 \(hunkIdx + 1) 处变更"))
            }
            if overflowCount > 0 {
                let overflowActive = activeHunk.map { !inline.contains($0) } ?? false
                Menu {
                    ForEach(hunks, id: \.self) { hunkIdx in
                        Button {
                            onSelect(hunkIdx)
                        } label: {
                            if activeHunk == hunkIdx {
                                Label("#\(hunkIdx + 1)", systemImage: "checkmark")
                            } else {
                                Text("#\(hunkIdx + 1)")
                            }
                        }
                    }
                } label: {
                    Text("+\(overflowCount)")
                        .font(.ui(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(overflowActive ? Color.white : Color.difText3)
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(overflowActive ? Color.difAccent : Color.difChip)
                        )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("All \(hunks.count) hunks in \(fileName)",
                        "\(fileName) 的全部 \(hunks.count) 处变更"))
            }
        }
        .fixedSize()
    }
}

struct EmptyListState: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.ui(size: 28, weight: .light)).foregroundStyle(Color.difText3)
            Text(title).font(.ui(size: 13, weight: .medium)).foregroundStyle(Color.difText2)
            if !detail.isEmpty {
                Text(detail).font(.ui(size: 11.5)).foregroundStyle(Color.difText3).multilineTextAlignment(.center).lineLimit(4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Log

/// Pure layout math for `CommitDetail` height fitting and drag clamping inside `LogPanel`.
enum CommitDetailLayout {
    static let minHeight: Double = 120
    /// `KeyboardList` adds `.padding(.vertical, 4)` (8 pt) around rows; 2 pt extra prevents unnecessary scrollbar flicker.
    static let listPadding: Double = 10
    static let defaultChromeHeight: Double = 72

    static func minCommitListHeight(commitRowHeight: Double) -> Double {
        max(140, max(0, commitRowHeight) * 3.5 + 8)
    }

    static func maxHeight(availableHeight: Double, minCommitListHeight: Double, dividerHeight: Double = 1) -> Double {
        max(0, availableHeight - max(0, minCommitListHeight) - max(0, dividerHeight))
    }

    static func clampedHeight(_ height: Double, minHeight: Double = Self.minHeight, maxHeight: Double) -> Double {
        let safeMax = max(0, maxHeight)
        let safeMin = min(max(0, minHeight), safeMax)
        return min(safeMax, max(safeMin, height))
    }

    static func fittedHeight(
        rowCount: Int,
        rowHeight: Double,
        chromeHeight: Double,
        listPadding: Double = Self.listPadding,
        minHeight: Double = Self.minHeight,
        maxHeight: Double
    ) -> Double {
        let count = max(0, rowCount)
        let rowsHeight = count > 0 ? Double(count) * max(0, rowHeight) + max(0, listPadding) : 0
        let ideal = max(0, chromeHeight) + rowsHeight
        return clampedHeight(ideal, minHeight: minHeight, maxHeight: maxHeight)
    }
}

struct LogPanel: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store
    @State private var manualFilesHeight: Double?
    @State private var dragStartHeight: Double?
    @State private var topChromeHeight: Double = 75
    @State private var chromeHeight: Double = CommitDetailLayout.defaultChromeHeight
    @State private var filesFocusToken = 0
    @State private var searchWork: DispatchWorkItem?

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(0, Double(proxy.size.height) - topChromeHeight)
            let minCommitListHeight = CommitDetailLayout.minCommitListHeight(commitRowHeight: Double(UI.s(44)))
            let maxHeight = CommitDetailLayout.maxHeight(
                availableHeight: availableHeight,
                minCommitListHeight: minCommitListHeight,
                dividerHeight: Double(IslandStyle.gap)
            )
            let rows = ChangeTree.rows(changes: project.commitFiles, flat: store.settings.flatList,
                                       collapsed: project.commitCollapsed, filter: "", splitUnversioned: false)
            let autoHeight = CommitDetailLayout.fittedHeight(
                rowCount: rows.count,
                rowHeight: Double(UI.s(24)),
                chromeHeight: chromeHeight,
                maxHeight: maxHeight
            )
            let detailHeight = manualFilesHeight.map {
                CommitDetailLayout.clampedHeight($0, minHeight: CommitDetailLayout.minHeight, maxHeight: maxHeight)
            } ?? autoHeight

            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        ProjectTabsHeader(project: project)
                        HStack(spacing: 4) {
                            FilterField(text: Binding(get: { project.logQuery }, set: { value in
                                project.logQuery = value
                                scheduleSearch()
                            }), placeholder: L("Search message, author or hash", "搜索提交信息、作者或哈希"))
                            IconButton(symbol: "arrow.triangle.branch", help: L("Show all branches", "显示所有分支"),
                                       isActive: project.logAllBranches, size: 11.5) {
                                project.logAllBranches.toggle()
                                if project.logAllBranches { project.logRef = nil }
                                project.loadLog(reset: true)
                            }
                            .padding(.top, 6)
                            .padding(.trailing, 6)
                        }
                        if let history = project.history {
                            // The Log lists one file's commits (or its lines'); ✕ goes back to the branch.
                            FilterChip(symbol: history.lines == nil ? "clock.arrow.circlepath" : "text.line.first.and.arrowtriangle.forward",
                                       text: L("History of \(history.label)", "\(history.label) 的历史"),
                                       help: history.rev == "HEAD" ? history.path : "\(history.path) @ \(history.rev.prefix(7))",
                                       clearHelp: L("Back to the whole Log", "回到完整历史")) { store.endHistory() }
                        }
                        if let label = project.logRefLabel {
                            // The Log lists a branch picked in the Git graph; ✕ goes back to the current branch.
                            FilterChip(symbol: "arrow.triangle.branch", text: label, help: label,
                                       clearHelp: L("Back to the current branch", "回到当前分支")) {
                                project.logRef = nil
                                project.loadLog(reset: true)
                            }
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                                let measured = Double(height)
                                if abs(topChromeHeight - measured) > 0.5 {
                                    topChromeHeight = measured
                                }
                            }
                        }
                    )
                    if project.commits.isEmpty {
                        if project.isLoadingLog {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        } else if let history = project.history {
                            EmptyListState(symbol: "clock", title: history.lines == nil ? L("No commits changed this file", "没有提交改动过这个文件")
                                                                                         : L("No commits changed these lines", "没有提交改动过这些行"),
                                           detail: project.logQuery.isEmpty ? "" : L("Nothing matches the search.", "没有符合搜索条件的提交。"))
                        } else {
                            EmptyListState(symbol: "clock", title: L("No commits", "没有提交"), detail: "")
                        }
                    } else {
                        KeyboardList(rows: project.commits,
                                     selection: Binding(get: { project.selectedCommitID }, set: { id in
                                         project.selectedCommitID = id
                                         store.pickedInLog(project, commitChanged: true)
                                     }),
                                     multiSelection: Binding(get: { project.selectedCommitIDs }, set: { ids in
                                         project.selectedCommitIDs = ids
                                         store.pickedInLog(project, commitChanged: true)
                                     }),
                                     focusToken: store.listFocusToken, rowHeight: 44,
                                     onKey: { event, _ in
                                         if event.keyCode == 124 || event.keyCode == 36 { filesFocusToken += 1; return true }
                                         return false
                                     },
                                     onDoubleClick: { _ in filesFocusToken += 1 },
                                     onLastRowAppear: { if project.hasMoreCommits { project.loadLog(reset: false) } },
                                     menu: { commit in store.logCommitMenu(commit, in: project) }) { commit, _, _ in
                            CommitRowView(commit: commit)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .islandCard(background: .difPanel)

                if !project.commits.isEmpty, !project.selectedCommits.isEmpty {
                    DividerGrip(
                        axis: .rows,
                        islandGap: true,
                        onDrag: { translation in
                            guard let translation else {
                                dragStartHeight = nil
                                return
                            }
                            let start = dragStartHeight ?? detailHeight
                            if dragStartHeight == nil { dragStartHeight = detailHeight }
                            manualFilesHeight = CommitDetailLayout.clampedHeight(
                                start - Double(translation),
                                minHeight: CommitDetailLayout.minHeight,
                                maxHeight: maxHeight
                            )
                        },
                        onDoubleClick: {
                            withAnimation(.snappy(duration: 0.2)) {
                                manualFilesHeight = nil
                            }
                        }
                    )
                    CommitDetail(
                        project: project,
                        focusToken: filesFocusToken,
                        rows: rows,
                        onChromeHeightChange: { height in
                            if abs(chromeHeight - height) > 0.5 {
                                chromeHeight = height
                            }
                        }
                    )
                    .frame(height: detailHeight)
                    .islandCard(background: .difPanel)
                    .animation(dragStartHeight == nil ? .snappy(duration: 0.2) : nil, value: rows.count)
                    .animation(dragStartHeight == nil ? .snappy(duration: 0.2) : nil, value: chromeHeight)
                }
            }
        }
        .onChange(of: project.id) { _, _ in
            manualFilesHeight = nil
        }
        .onChange(of: project.commitSelectionIDs) { _, _ in
            withAnimation(.snappy(duration: 0.2)) {
                manualFilesHeight = nil
            }
            store.commitSelectionChanged(project)
        }
        .onChange(of: project.selectedCommitFileID) { _, _ in store.commitFileSelectionChanged(project) }
        .onAppear {
            // A load already running (one asked for by the Git graph) is not replaced by a plain one.
            if project.commits.isEmpty {
                if !project.isLoadingLog { project.loadLog(reset: true) }
            } else if project.commitFiles.isEmpty {
                store.commitSelectionChanged(project)
            }
        }
    }

    private func scheduleSearch() {
        searchWork?.cancel()
        let work = DispatchWorkItem { project.loadLog(reset: true) }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
}

private struct CommitRowView: View {
    var commit: Commit

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                ForEach(commit.refs.prefix(3), id: \.self) { ref in RefChip(ref: ref) }
                Text(commit.subject)
                    .font(.ui(size: 12.5))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(commit.author).lineLimit(1)
                Text("·")
                Text(Self.relative.localizedString(for: commit.date, relativeTo: Date()))
                Spacer(minLength: 4)
                if commit.isMerge {
                    Image(systemName: "arrow.triangle.merge").font(.ui(size: 9))
                }
                Text(commit.shortHash).font(.code(10.5))
            }
            .font(.ui(size: 11))
            .foregroundStyle(Color.difText3)
        }
        .padding(.horizontal, 14)
    }
}

/// A branch or tag on a commit, as `git log --decorate=full --format=%D` names them:
/// "HEAD -> refs/heads/main", "refs/remotes/origin/main", "tag: refs/tags/v1", "HEAD".
struct RefChip: View {
    var ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        let isTag = ref.hasPrefix("tag: ")
        let isRemote = ref.hasPrefix("refs/remotes/")
        let label = Self.label(ref)
        // Remote branches in a quieter colour than local ones; the checked-out one in green.
        let tint: Color = isTag ? Color(NSColor(hex: 0xD9A520))
            : isHead ? Color.difAdded
            : isRemote ? Color(NSColor(hex: 0x9A7FE0))
            : Color.difAccent
        Text(label)
            .font(.ui(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tint.opacity(0.16)))
            .fixedSize()
    }

    static func label(_ ref: String) -> String {
        let name = ref.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(of: "tag: ", with: "")
        for prefix in ["refs/heads/", "refs/remotes/", "refs/tags/"] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}

/// The selected commit's (or commit range's) summary and changed files.
private struct CommitDetail: View {
    @Bindable var project: Project
    var focusToken: Int
    var rows: [ChangeRow]
    var onChromeHeightChange: (Double) -> Void
    @Environment(AppStore.self) private var store

    var body: some View {
        let folderIDs = store.settings.flatList ? [] : project.commitFolderIDs
        let selectedCommits = project.selectedCommits
        VStack(spacing: 0) {
            chrome(folderIDs: folderIDs, selectedCommits: selectedCommits)
            KeyboardList(rows: rows,
                         selection: Binding(get: { project.selectedCommitFileID }, set: { id in
                             project.selectedCommitFileID = id
                             store.pickedInLog(project, commitChanged: false)
                         }),
                         focusToken: focusToken + store.logFilesFocusToken,
                         onKey: { event, row in handleKey(event, row, rows) },
                         onClick: { row in
                             if row.file == nil { toggle(row) }
                         },
                         onDoubleClick: { row in
                             if row.file != nil { store.focusViewer() }
                         },
                         menu: { row in rowMenu(row) }) { row, _, _ in
                ChangeRowView(row: row, showDirectory: store.settings.flatList) { toggle(row) }
            }
        }
    }

    private func chrome(folderIDs: Set<String>, selectedCommits: [Commit]) -> some View {
        VStack(spacing: 0) {
            if selectedCommits.count > 1, let newest = selectedCommits.first, let oldest = selectedCommits.last {
                let fileCount = project.commitFiles.count
                let added = project.commitFiles.reduce(0) { $0 + ($1.additions ?? 0) }
                let deleted = project.commitFiles.reduce(0) { $0 + ($1.deletions ?? 0) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L("\(selectedCommits.count) commits · \(fileCount == 1 ? "1 file" : "\(fileCount) files")",
                               "已选 \(selectedCommits.count) 个提交 · \(fileCount) 个文件"))
                            .font(.ui(size: 12, weight: .medium))
                            .foregroundStyle(Color.difText)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        StatBadge(additions: added, deletions: deleted)
                    }
                    HStack(spacing: 6) {
                        Text("\(oldest.shortHash)..\(newest.shortHash)")
                            .font(.code(10.5))
                        Spacer()
                        Button {
                            let range = "\(oldest.parents.first ?? Git.emptyTree)..\(newest.hash)"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(range, forType: .string)
                            store.showToast(L("Copied \(oldest.shortHash)..\(newest.shortHash)",
                                              "已复制 \(oldest.shortHash)..\(newest.shortHash)"))
                        } label: {
                            Image(systemName: "doc.on.doc").font(.ui(size: 9))
                        }
                        .buttonStyle(.plain)
                        .help(L("Copy commit range", "复制提交范围"))
                    }
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Rectangle().fill(Color.difHairline).frame(height: 1)
            } else if let commit = selectedCommits.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.commitBody.isEmpty ? commit.subject : project.commitBody)
                        .font(.ui(size: 12))
                        .foregroundStyle(Color.difText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 6) {
                        Text(commit.author)
                        Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.hash, forType: .string)
                            store.showToast(L("Copied \(commit.shortHash)", "已复制 \(commit.shortHash)"))
                        } label: {
                            HStack(spacing: 3) {
                                Text(commit.shortHash).font(.code(10.5))
                                Image(systemName: "doc.on.doc").font(.ui(size: 9))
                            }
                        }
                        .buttonStyle(.plain)
                        .help(L("Copy full hash", "复制完整哈希"))
                    }
                    .font(.ui(size: 11))
                    .foregroundStyle(Color.difText3)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                Rectangle().fill(Color.difHairline).frame(height: 1)
            }
            if !selectedCommits.isEmpty {
                filesBar(rows: rows, folderIDs: folderIDs, multiCommit: selectedCommits.count > 1)
                Rectangle().fill(Color.difHairline).frame(height: 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.height, initial: true) { _, height in
                    onChromeHeightChange(Double(height))
                }
            }
        )
    }

    private func filesBar(rows: [ChangeRow], folderIDs: Set<String>, multiCommit: Bool) -> some View {
        let fileCount = project.commitFiles.count
        let hasExpandedFolder = rows.contains { $0.file == nil && $0.isExpanded }
        return HStack(spacing: 4) {
            if multiCommit {
                Text(store.settings.flatList ? L("Flat list", "平铺列表") : L("Directory tree", "目录树"))
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
            } else {
                Text(fileCount == 1 ? L("1 file", "1 个文件") : L("\(fileCount) files", "\(fileCount) 个文件"))
                    .font(.ui(size: 11, weight: .medium))
                    .foregroundStyle(Color.difText3)
                    .lineLimit(1)
                if fileCount > 0 {
                    let added = project.commitFiles.reduce(0) { $0 + ($1.additions ?? 0) }
                    let deleted = project.commitFiles.reduce(0) { $0 + ($1.deletions ?? 0) }
                    StatBadge(additions: added, deletions: deleted, size: 10.5)
                }
            }
            Spacer(minLength: 4)
            if !store.settings.flatList, !folderIDs.isEmpty {
                IconButton(symbol: hasExpandedFolder ? "rectangle.compress.vertical" : "rectangle.expand.vertical",
                           help: hasExpandedFolder ? L("Collapse all folders", "折叠全部目录") : L("Expand all folders", "展开全部目录"),
                           size: 11) {
                    if hasExpandedFolder {
                        project.collapseAllCommitFolders()
                    } else {
                        project.expandAllCommitFolders()
                    }
                }
            }
            IconButton(symbol: store.settings.flatList ? "list.bullet" : "list.bullet.indent",
                       help: store.settings.flatList ? L("Group by directory", "按目录分组") : L("Flat list", "平铺列表"),
                       size: 11.5) {
                store.settings.flatList.toggle()
                store.settings.save()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
    }

    private func handleKey(_ event: NSEvent, _ row: ChangeRow?, _ rows: [ChangeRow]) -> Bool {
        switch event.keyCode {
        case 123: // ← collapse, move to parent row, or return to commit list
            guard let row else { store.focusList(); return true }
            if row.file == nil, row.isExpanded {
                project.commitCollapsed.insert(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }),
                      let parent = rows[..<index].last(where: { $0.depth < row.depth }) {
                project.selectedCommitFileID = parent.id
            } else {
                store.focusList()
            }
            return true
        case 124: // → expand folder, or step into its first child
            guard let row, row.file == nil else { return true }
            if !row.isExpanded {
                project.commitCollapsed.remove(row.id)
            } else if let index = rows.firstIndex(where: { $0.id == row.id }), index + 1 < rows.count {
                project.selectedCommitFileID = rows[index + 1].id
            }
            return true
        case 49: // Space toggles folder expand/collapse
            guard let row, row.file == nil else { return false }
            toggle(row)
            return true
        case 36, 76: // ↩
            if let row, row.file == nil { toggle(row) } else { store.focusViewer() }
            return true
        case 53: // Esc
            store.focusList()
            return true
        default:
            return false
        }
    }

    private func rowMenu(_ row: ChangeRow) -> NSMenu? {
        if let file = row.file {
            let commits = project.selectedCommits
            guard !commits.isEmpty else { return nil }
            return store.commitFileMenu(file, in: commits, project: project)
        }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(row.isExpanded ? L("Collapse", "折叠") : L("Expand", "展开")) { toggle(row) })
        menu.addItem(ClosureMenuItem(L("Expand All", "全部展开")) { project.expandAllCommitFolders() })
        menu.addItem(ClosureMenuItem(L("Collapse All", "全部折叠")) { project.collapseAllCommitFolders() })
        return menu
    }

    private func toggle(_ row: ChangeRow) {
        guard row.file == nil else { return }
        if project.commitCollapsed.contains(row.id) { project.commitCollapsed.remove(row.id) } else { project.commitCollapsed.insert(row.id) }
    }
}
