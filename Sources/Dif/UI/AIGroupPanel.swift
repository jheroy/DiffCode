import AppKit
import SwiftUI

/// Middle-column panel for the "Groups" tab:
/// - Session tab bar when one or more grouping sessions exist (`Working Tree`, `Comparison`, `Commits`).
/// - Empty / creation state: source selector (active comparison vs working tree), provider/model selector, and CTA.
/// - Populated state: resizable two-pane split matching `LogPanel` — top island lists logical groups,
///   bottom island renders the selected group's changed files and shows the commit box ONLY for working-tree sessions.
struct AIGroupPanel: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store
    /// Fraction of usable column height given to the top island (header + groups list).
    @State private var topSplitRatio: Double = Self.defaultTopRatio
    @State private var dragStartTopHeight: Double?
    @State private var filesFocusToken = 0
    @State private var preferWorkingTreeInCreation = false

    private static let defaultTopRatio: Double = 0.40
    private static let minTopHeight: Double = 196
    private static let minBottomHeight: Double = 230

    var body: some View {
        Group {
            if AppEnvironment.isAppStore {
                singleCard { appStoreUnsupportedView }
            } else if let session = project.activeAIGroupSession, !session.result.groups.isEmpty {
                populatedSplitView(session: session)
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
            preferWorkingTreeInCreation = false
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
            if !AppEnvironment.isAppStore, !project.aiGroupSessions.isEmpty {
                AIGroupSessionBar(project: project)
            }
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

    // MARK: - Empty / Creation State

    private var emptyStateView: some View {
        let filter = store.settings.aiGroupingFilter(for: project.url)
        let comparison = project.comparison
        let hasComparison = comparison != nil
        let matchedCompareCount = hasComparison ? filter.apply(to: project.compareChanges).count : 0
        let matchedWorkingCount = filter.apply(to: project.changes).count
        let hasCompareChanges = hasComparison && !project.compareChanges.isEmpty
        let hasWorkingChanges = !project.changes.isEmpty
        let useComparisonSource = hasComparison && (!preferWorkingTreeInCreation || !hasWorkingChanges)
        let isGeneratingNewSession = project.isGeneratingGroups && project.generatingGroupSessionID == nil
        let hasTargetChanges: Bool = {
            if useComparisonSource {
                return !project.isLoadingCompare && matchedCompareCount > 0
            }
            return matchedWorkingCount > 0
        }()

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
                    Text(useComparisonSource
                         ? L("Organize compared changes by feature or module (read-only view).",
                             "将当前对比变更按功能或模块对 Hunk 自动分组（仅查看）。")
                         : L("Automatically organize all uncommitted hunks by feature or module.",
                             "将当前未提交变更按功能或模块对 Hunk 自动分组。"))
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 12)

                if !isGeneratingNewSession, let comparison {
                    let compSource = AIHunkGroupingSource.from(comparison: comparison)
                    if hasCompareChanges && hasWorkingChanges {
                        creationSourcePicker(
                            comparisonLabel: compSource.tabTitle,
                            useComparison: useComparisonSource
                        )
                        .padding(.horizontal, 12)
                    } else {
                        creationSourceChip(source: compSource)
                            .padding(.horizontal, 12)
                    }
                }

                // Compact inline Agent Provider + Model selector for AI Grouping (independent of Commit Message).
                AgentModelSelectorCard(task: .grouping, compact: false)
                    .padding(.horizontal, 12)

                // File glob filter, test-file exclusion toggle, and per-project blacklist manager.
                AIGroupFilterCard(project: project, compact: false)
                    .padding(.horizontal, 12)

                // Primary CTA button + live stream access
                VStack(spacing: 6) {
                    if isGeneratingNewSession {
                        HStack(spacing: 6) {
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

                            if let groupConv = project.activeGroupingConversation {
                                AgentStreamPillButton(
                                    isRunning: groupConv.isRunning,
                                    hasError: groupConv.hasFailed,
                                    compactIconOnly: false,
                                    help: L("Open AI grouping conversation stream", "打开 AI 分组对话流")
                                ) {
                                    store.openAgentConversation(groupConv)
                                }
                            }
                        }

                        if let source = project.generatingGroupSource {
                            Text(source.detailTitle)
                                .font(.ui(size: 11))
                                .foregroundStyle(Color.difText3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Button {
                                if useComparisonSource {
                                    store.generateComparisonAIGroups(for: project)
                                } else {
                                    store.generateWorkingTreeAIGroups(for: project)
                                }
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
                                        .fill(Color.difAccent.opacity(hasTargetChanges ? 1 : 0.38))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!hasTargetChanges)

                            if let groupConv = project.activeGroupingConversation {
                                AgentStreamPillButton(
                                    isRunning: groupConv.isRunning,
                                    hasError: groupConv.hasFailed,
                                    compactIconOnly: false,
                                    help: L("Open AI grouping conversation stream and continue chat",
                                            "打开 AI 分组对话流并继续对话")
                                ) {
                                    store.openAgentConversation(groupConv)
                                }
                            }
                        }

                        Text(creationStatusCaption(
                            useComparison: useComparisonSource,
                            isLoadingCompare: project.isLoadingCompare,
                            compareCount: project.compareChanges.count,
                            matchedCompareCount: matchedCompareCount,
                            workingCount: project.changes.count,
                            matchedWorkingCount: matchedWorkingCount,
                            filterActive: filter.isActive
                        ))
                        .font(.ui(size: 11))
                        .foregroundStyle(Color.difText3)
                        .multilineTextAlignment(.center)
                    }
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

    private func creationSourcePicker(comparisonLabel: String, useComparison: Bool) -> some View {
        HStack(spacing: 4) {
            sourceTogglePill(
                symbol: project.comparison?.stash != nil ? "tray.full" : "arrow.left.arrow.right",
                title: comparisonLabel,
                selected: useComparison
            ) {
                preferWorkingTreeInCreation = false
            }
            sourceTogglePill(
                symbol: "square.and.pencil",
                title: L("Working Tree", "工作区"),
                selected: !useComparison
            ) {
                preferWorkingTreeInCreation = true
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difChip.opacity(0.65)))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.difHairline, lineWidth: 1)
        )
    }

    private func sourceTogglePill(symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.ui(size: 10, weight: .semibold))
                Text(title)
                    .font(.ui(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(selected ? Color.difAccent : Color.difText2)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(selected ? Color.difSelection : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func creationSourceChip(source: AIHunkGroupingSource) -> some View {
        HStack(spacing: 6) {
            Image(systemName: source.symbolName)
                .font(.ui(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.difAccent)
            Text(source.detailTitle)
                .font(.ui(size: 11, weight: .medium))
                .foregroundStyle(Color.difText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(L("Read-only", "仅查看"))
                .font(.ui(size: 9.5, weight: .semibold))
                .foregroundStyle(Color.difText2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.difChip))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difSelection.opacity(0.75)))
        .help(source.tooltip)
    }

    private func creationStatusCaption(
        useComparison: Bool,
        isLoadingCompare: Bool,
        compareCount: Int,
        matchedCompareCount: Int,
        workingCount: Int,
        matchedWorkingCount: Int,
        filterActive: Bool
    ) -> String {
        if useComparison {
            if isLoadingCompare && compareCount == 0 {
                return L("Loading compared changes…", "正在加载对比变更…")
            }
            if compareCount == 0 {
                return L("No differences in current comparison", "当前比较暂无差异")
            }
            if filterActive {
                if matchedCompareCount == 0 {
                    return L("0 of \(compareCount) compared files match filter",
                             "当前 \(compareCount) 个对比文件中无匹配筛选条件的文件")
                }
                return L("\(matchedCompareCount) of \(compareCount) compared files match filter (read-only)",
                         "当前筛选后 \(matchedCompareCount) / \(compareCount) 个对比文件可分组（仅查看）")
            }
            return compareCount == 1
                ? L("1 compared file ready to group (read-only)", "当前对比有 1 个变更文件可分组（仅查看）")
                : L("\(compareCount) compared files ready to group (read-only)", "当前对比有 \(compareCount) 个变更文件可分组（仅查看）")
        }
        if workingCount == 0 {
            return L("No uncommitted changes · compare with a branch or select commits in Log",
                     "工作区暂无变更 · 可与分支比较或在历史中选择提交分组")
        }
        if filterActive {
            if matchedWorkingCount == 0 {
                return L("0 of \(workingCount) changed files match filter",
                         "当前 \(workingCount) 个变更文件中无匹配筛选条件的文件")
            }
            return L("\(matchedWorkingCount) of \(workingCount) changed files match filter",
                     "当前筛选后 \(matchedWorkingCount) / \(workingCount) 个变更文件可分组")
        }
        return workingCount == 1
            ? L("1 changed file ready to group", "当前有 1 个变更文件可分组")
            : L("\(workingCount) changed files ready to group", "当前有 \(workingCount) 个变更文件可分组")
    }

    // MARK: - Populated Two-Pane Split State

    private func populatedSplitView(session: AIGroupSession) -> some View {
        let result = session.result
        let snapshot = project.groupChangesSnapshot(flat: store.settings.flatList)
        let activeGroupID = snapshot?.group.id ?? session.selectedGroupID ?? result.groups.first?.id

        return GeometryReader { proxy in
            let gap = Double(IslandStyle.gap)
            let usable = max(0, Double(proxy.size.height) - gap)
            let safeMinTop = min(Self.minTopHeight, usable * 0.45)
            let safeMinBottom = min(Self.minBottomHeight, usable * 0.55)
            let maxTop = max(safeMinTop, usable - safeMinBottom)
            let topHeight = min(maxTop, max(safeMinTop, usable * topSplitRatio))

            VStack(spacing: 0) {
                // Top island: tabs header + session tabs + compact toolbar + group list
                VStack(spacing: 0) {
                    ProjectTabsHeader(project: project)
                    AIGroupSessionBar(project: project)
                    topToolbar(session: session)
                    Rectangle().fill(Color.difHairline).frame(height: 1)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(result.groups) { group in
                                let rowConv = project.reviewConversation(forGroupID: group.id)
                                AIGroupRow(
                                    group: group,
                                    isSelected: group.id == activeGroupID,
                                    canDelete: !project.isCommittingGroup,
                                    isReviewing: project.isReviewing(groupID: group.id),
                                    reviewHelp: groupReviewHelp(group: group, isReviewing: project.isReviewing(groupID: group.id)),
                                    reviewConversation: rowConv,
                                    onSelect: {
                                        store.selectAIGroup(group, in: project, openFirstFile: true)
                                    },
                                    onReview: {
                                        store.reviewGroup(group, in: session, project: project)
                                    },
                                    onOpenStream: rowConv.map { conv in
                                        { store.openAgentConversation(conv) }
                                    },
                                    onDelete: {
                                        store.deleteAIGroup(group, in: project)
                                    },
                                    onDeleteSession: {
                                        store.deleteAIGroupSession(session.id, in: project)
                                    },
                                    onClearAll: {
                                        store.clearAIGroups(for: project)
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: topHeight)
                .islandCard(background: .difPanel)

                // Draggable split handle (double-click restores default split)
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

                // Bottom island: selected group's changed files tree/list (commit box only for working tree)
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

    private func topToolbar(session: AIGroupSession) -> some View {
        let result = session.result
        let modelTag: String = {
            if let model = result.model, !model.isEmpty {
                return "\(result.provider.executableName) · \(model)"
            }
            return result.provider.executableName
        }()
        let isGeneratingThis = project.isGeneratingGroups

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

                if isGeneratingThis {
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
                    let regenerateDisabled = (session.isCommittable && project.changes.isEmpty)
                        || project.isCommittingGroup
                        || project.isCommitting
                    IconButton(symbol: "sparkles",
                               help: L("Regenerate AI groups", "重新生成 AI 分组"),
                               size: 11.5) {
                        store.regenerateAIGroupSession(session.id, in: project)
                    }
                    .disabled(regenerateDisabled)
                    .opacity(regenerateDisabled ? 0.35 : 1)
                }

                if let groupConv = project.activeGroupingConversation {
                    AgentStreamPillButton(
                        isRunning: groupConv.isRunning,
                        hasError: groupConv.hasFailed,
                        compactIconOnly: !isGeneratingThis,
                        help: L("Open AI grouping conversation stream and continue chat",
                                "打开 AI 分组对话流并继续对话")
                    ) {
                        store.openAgentConversation(groupConv)
                    }
                }

                IconButton(symbol: "trash",
                           help: L("Delete this grouping", "删除当前分组集"),
                           size: 11.5) {
                    store.deleteAIGroupSession(session.id, in: project)
                }
                .disabled(project.isCommittingGroup)
                .opacity(project.isCommittingGroup ? 0.35 : 1)
            }

            // Source indicator chip (Working Tree / Comparison / Selected Commits)
            HStack(spacing: 5) {
                Image(systemName: session.source.symbolName)
                    .font(.ui(size: 9.5, weight: .semibold))
                    .foregroundStyle(Color.difAccent)
                Text(session.source.detailTitle)
                    .font(.ui(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.difText2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let sessionFilter = session.filter, sessionFilter.isActive {
                    Text(sessionFilter.compactBadgeText)
                        .font(.ui(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.difText2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.difChip))
                        .help(sessionFilter.summaryText)
                }
                if !session.isCommittable {
                    Text(L("Read-only", "仅查看"))
                        .font(.ui(size: 9.5, weight: .semibold))
                        .foregroundStyle(Color.difText2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.difChip))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difSelection.opacity(0.65)))
            .help(session.source.tooltip)

            // Inline quick provider/model switcher for AI Grouping
            AgentModelSelectorCard(task: .grouping, compact: true)

            // Compact file filter, test exclusion, and per-project blacklist popover
            AIGroupFilterCard(project: project, compact: true)

            if let error = project.aiGroupError, !error.isEmpty {
                errorCard(message: error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func groupReviewHelp(group: AIHunkGroup, isReviewing: Bool) -> String {
        let agentDesc = store.aiReviewAgentDescription()
        if isReviewing {
            return L("Generating code review report for “\(group.name)” with \(agentDesc)… Click to cancel",
                     "正在使用 \(agentDesc) 生成分组「\(group.name)」的代码审查报告… 点击取消")
        }
        return L("Review “\(group.name)” with \(agentDesc) and open Markdown report",
                 "使用 \(agentDesc) 审查分组「\(group.name)」并生成打开 Markdown 报告")
    }

    private func errorCard(message: String) -> some View {
        let retryDisabled = project.isGeneratingGroups || project.isCommittingGroup || project.isCommitting
        return VStack(alignment: .leading, spacing: 6) {
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
                    store.retryFailedAIGroupGeneration(for: project)
                } label: {
                    Text(L("Retry", "重试"))
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difAccent))
                }
                .buttonStyle(.plain)
                .disabled(retryDisabled)
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

// MARK: - Top Pane: Multi-Session Tab Bar

private struct AIGroupSessionBar: View {
    @Bindable var project: Project
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(project.aiGroupSessions) { session in
                                let isActive = session.id == project.activeGroupSessionID
                                let isGeneratingThis = project.isGeneratingGroups
                                    && project.generatingGroupSessionID == session.id
                                AIGroupSessionPill(
                                    session: session,
                                    isActive: isActive,
                                    isGenerating: isGeneratingThis,
                                    canDelete: !project.isCommittingGroup,
                                    onSelect: { store.selectAIGroupSession(session.id, in: project) },
                                    onDelete: { store.deleteAIGroupSession(session.id, in: project) }
                                )
                                .id(session.id)
                                .contextMenu {
                                    let isReviewingSession = project.isReviewing(sessionID: session.id)
                                    Button {
                                        store.reviewAIGroupSession(session, in: project)
                                    } label: {
                                        Label(
                                            isReviewingSession
                                                ? L("Cancel Code Review", "取消代码审查")
                                                : L("Review Grouping Session with AI", "AI 审查此分组集"),
                                            systemImage: "doc.text.magnifyingglass"
                                        )
                                    }

                                    Divider()

                                    Button(L("Regenerate", "重新分组")) {
                                        store.regenerateAIGroupSession(session.id, in: project)
                                    }
                                    .disabled(project.isCommittingGroup || project.isCommitting)

                                    Divider()

                                    Button(role: .destructive) {
                                        store.deleteAIGroupSession(session.id, in: project)
                                    } label: {
                                        Label(L("Delete This Grouping", "删除此分组集"), systemImage: "trash")
                                    }
                                    .disabled(project.isCommittingGroup)

                                    if project.aiGroupSessions.count > 1 {
                                        Button(L("Delete Other Groupings", "删除其他分组集")) {
                                            store.deleteOtherAIGroupSessions(keeping: session.id, in: project)
                                        }
                                        .disabled(project.isCommittingGroup)

                                        Button(role: .destructive) {
                                            store.clearAIGroups(for: project)
                                        } label: {
                                            Label(L("Clear All Groupings", "清空全部分组集"), systemImage: "xmark.circle")
                                        }
                                        .disabled(project.isCommittingGroup)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        if let activeID = project.activeGroupSessionID {
                            proxy.scrollTo(activeID)
                        }
                    }
                    .onChange(of: project.activeGroupSessionID) { _, id in
                        if let id {
                            withAnimation(.snappy(duration: 0.18)) {
                                proxy.scrollTo(id)
                            }
                        }
                    }
                }

                IconButton(symbol: "plus", help: L("New Grouping", "新建分组"), size: 10.5) {
                    store.startNewAIGroupSession(in: project)
                }
                .padding(.trailing, 4)
            }
            .frame(height: UI.s(30))

            Rectangle().fill(Color.difHairline).frame(height: 1)
        }
    }
}

private struct AIGroupSessionPill: View {
    let session: AIGroupSession
    let isActive: Bool
    let isGenerating: Bool
    let canDelete: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var closeHovering = false

    var body: some View {
        HStack(spacing: 3) {
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    if isGenerating {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.45)
                            .frame(width: UI.s(10), height: UI.s(10))
                    } else {
                        Image(systemName: session.source.symbolName)
                            .font(.ui(size: 10, weight: .semibold))
                            .foregroundStyle(isActive ? Color.difAccent : Color.difText3)
                    }
                    Text(session.source.tabTitle)
                        .font(.ui(size: 11.5, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isActive ? Color.difText : Color.difText2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: UI.s(145), alignment: .leading)
                }
                .padding(.leading, 7)
                .padding(.trailing, canDelete ? 2 : 7)
                .padding(.vertical, 3.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.ui(size: 8, weight: .bold))
                        .foregroundStyle(closeHovering ? Color.difText : Color.difText3)
                        .frame(width: UI.s(15), height: UI.s(15))
                        .background(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .fill(closeHovering ? Color.difHover : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .onHover { closeHovering = $0 }
                .help(L("Delete this grouping", "删除此分组集"))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.difChip : (hovering ? Color.difHover : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? Color.difHairline : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .help(session.source.tooltip)
    }
}

// MARK: - Top Pane: Group List Row

private struct AIGroupRow: View {
    let group: AIHunkGroup
    let isSelected: Bool
    let canDelete: Bool
    let isReviewing: Bool
    let reviewHelp: String
    let reviewConversation: AgentConversation?
    let onSelect: () -> Void
    let onReview: () -> Void
    let onOpenStream: (() -> Void)?
    let onDelete: () -> Void
    let onDeleteSession: () -> Void
    let onClearAll: () -> Void

    @State private var hovering = false
    @State private var hoveringDelete = false

    var body: some View {
        let trimmedSummary = group.summary.trimmingCharacters(in: .whitespacesAndNewlines)

        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .center, spacing: 6) {
                Text(group.name)
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if isReviewing || hovering {
                    AIReviewPillButton(
                        isReviewing: isReviewing,
                        isDisabled: !isReviewing && group.files.isEmpty,
                        compactIconOnly: true,
                        help: reviewHelp,
                        action: onReview
                    )
                }

                if let reviewConversation, let onOpenStream,
                   reviewConversation.isRunning || reviewConversation.hasFailed || isReviewing || hovering {
                    AgentStreamPillButton(
                        isRunning: reviewConversation.isRunning,
                        hasError: reviewConversation.hasFailed,
                        compactIconOnly: true,
                        help: L("Open group review conversation stream", "打开该分组的审查对话流"),
                        action: onOpenStream
                    )
                }

                if hovering && canDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.ui(size: 10, weight: .medium))
                            .foregroundStyle(hoveringDelete ? Color.difRemoved : Color.difText3)
                            .frame(width: UI.s(20), height: UI.s(18))
                            .background(
                                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                                    .fill(hoveringDelete ? Color.difRemoved.opacity(0.14) : Color.difChip.opacity(0.8))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveringDelete = $0 }
                    .help(L("Delete this group", "删除该分组"))
                }

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
        .onTapGesture(perform: onSelect)
        .onHover {
            hovering = $0
            if !$0 { hoveringDelete = false }
        }
        .contextMenu {
            Button(action: onReview) {
                Label(
                    isReviewing
                        ? L("Cancel Code Review", "取消代码审查")
                        : L("Review Group with AI", "AI 审查此分组"),
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .disabled(!isReviewing && group.files.isEmpty)
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label(L("Delete Group", "删除此分组"), systemImage: "trash")
            }
            .disabled(!canDelete)
            Divider()
            Button(role: .destructive, action: onDeleteSession) {
                Label(L("Delete This Grouping", "删除当前分组集"), systemImage: "trash.slash")
            }
            .disabled(!canDelete)
            Button(role: .destructive, action: onClearAll) {
                Label(L("Clear All Groupings", "清空全部分组集"), systemImage: "xmark.circle")
            }
            .disabled(!canDelete)
        }
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
                if !AppEnvironment.isAppStore, let session = project.activeAIGroupSession {
                    let isReviewingGroup = project.isReviewing(groupID: group.id)
                    let reviewDisabled = !isReviewingGroup && snapshot.changes.isEmpty
                    let agentDesc = store.aiReviewAgentDescription()
                    AIReviewPillButton(
                        isReviewing: isReviewingGroup,
                        isDisabled: reviewDisabled,
                        compactIconOnly: false,
                        help: isReviewingGroup
                            ? L("Generating code review report for “\(group.name)” with \(agentDesc)… Click to cancel",
                                "正在使用 \(agentDesc) 生成分组「\(group.name)」的代码审查报告… 点击取消")
                            : L("Review “\(group.name)” with \(agentDesc) and open Markdown report",
                                "使用 \(agentDesc) 审查分组「\(group.name)」并生成打开 Markdown 报告")
                    ) {
                        store.reviewGroup(group, in: session, project: project)
                    }
                    if let reviewConv = project.reviewConversation(forGroupID: group.id)
                        ?? project.reviewConversation(for: .session(session.id)) {
                        AgentStreamPillButton(
                            isRunning: reviewConv.isRunning,
                            hasError: reviewConv.hasFailed,
                            compactIconOnly: false,
                            help: L("Open AI review conversation stream and continue chat",
                                    "打开 AI 审查对话流并继续对话")
                        ) {
                            store.openAgentConversation(reviewConv)
                        }
                    }
                }
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

            if snapshot.isCommittable {
                Rectangle().fill(Color.difHairline).frame(height: 1)

                AIGroupCommitBox(
                    project: project,
                    group: group,
                    hasFiles: !snapshot.changes.isEmpty
                )
            }
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
            if let session = project.aiGroupSession(id: snapshot.sessionID),
               let req = project.diffRequest(for: file.path, in: session, ignoreWhitespace: store.settings.ignoreWhitespace),
               let filter = store.historyFilter(for: req, lines: nil, in: project) {
                menu.addItem(ClosureMenuItem(L("Show History", "查看历史")) {
                    store.showHistory(filter, in: project)
                })
            } else if snapshot.isCommittable, file.kind != .untracked, file.kind != .added {
                menu.addItem(ClosureMenuItem(L("Show History", "查看历史")) {
                    store.showHistory(path: file.path, in: project)
                })
            }
            menu.addItem(.separator())
            store.addAIGroupingBlacklistMenuItem(for: file.path, in: project, pruneActiveSession: true, to: menu)
            menu.addItem(.separator())
            let fileURL = project.url.appendingPathComponent(file.path)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                menu.addItem(ClosureMenuItem(L("Reveal in Finder", "在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                })
            }
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
                    set: {
                        project.setCommitMessage($0, for: group)
                        store.schedulePersistAIGroups(for: project)
                    }
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
            models.contains(where: { $0.id == chosen }) ? nil : chosen
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
                Text(models.isEmpty ? missingModel : "\(missingModel) (\(L("saved", "已保存")))")
                    .tag(String?.some(missingModel))
            }
        }
        .id(provider)
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

// MARK: - AI Grouping File Filter & Per-Project Blacklist

private struct AIGroupFilterCard: View {
    @Bindable var project: Project
    var compact: Bool
    @Environment(AppStore.self) private var store
    @State private var showBlacklist = false

    private var patternTooltip: String {
        L("Only group files matching these globs (e.g. *.go *.sql, db/**/*.sql, !*.pb.go). Leave empty for all files.",
          "仅对匹配通配符的文件进行分组（如 *.go *.sql、db/**/*.sql、!*.pb.go），留空表示全部文件。")
    }

    private var includeBinding: Binding<String> {
        Binding(
            get: { store.settings.aiGroupingIncludePatterns },
            set: {
                guard store.settings.aiGroupingIncludePatterns != $0 else { return }
                store.settings.aiGroupingIncludePatterns = $0
                store.settings.save()
            }
        )
    }

    var body: some View {
        let blacklist = store.settings.aiGroupingBlacklist(for: project.url)
        let excludeTests = store.settings.aiGroupingExcludeTestFiles

        if compact {
            HStack(spacing: 5) {
                patternField(height: UI.s(22), fontSize: 10.5)

                compactTogglePill(
                    label: L("No tests", "不含测试"),
                    help: L("Exclude test files from AI grouping", "分组时排除测试文件"),
                    isOn: excludeTests
                ) {
                    store.settings.aiGroupingExcludeTestFiles.toggle()
                    store.settings.save()
                }

                if !blacklist.isEmpty {
                    blacklistButton(count: blacklist.count, compact: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(L("Filter", "筛选"))
                        .font(.ui(size: 11, weight: .medium))
                        .foregroundStyle(Color.difText2)
                        .frame(width: UI.s(42), alignment: .leading)
                    patternField(height: UI.s(24), fontSize: 11)
                }

                HStack(spacing: 6) {
                    Color.clear.frame(width: UI.s(42), height: 1)

                    compactTogglePill(
                        label: L("Exclude test files", "排除测试文件"),
                        help: L("Exclude test files (*_test.go, *Tests.swift, tests/, etc.)",
                                "排除测试文件（*_test.go、*Tests.swift、tests/ 目录等）"),
                        isOn: excludeTests
                    ) {
                        store.settings.aiGroupingExcludeTestFiles.toggle()
                        store.settings.save()
                    }

                    if !blacklist.isEmpty {
                        blacklistButton(count: blacklist.count, compact: false)
                    }

                    Spacer(minLength: 0)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difChip.opacity(0.65)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.difHairline, lineWidth: 1)
            )
        }
    }

    private func patternField(height: CGFloat, fontSize: CGFloat) -> some View {
        let hasText = !store.settings.aiGroupingIncludePatterns.isEmpty
        return HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.ui(size: 9.5, weight: .medium))
                .foregroundStyle(hasText ? Color.difAccent : Color.difText3)
            TextField(L("e.g. *.go *.sql", "如 *.go *.sql"), text: includeBinding)
                .textFieldStyle(.plain)
                .font(.ui(size: fontSize, design: .monospaced))
                .foregroundStyle(Color.difText)
            if hasText {
                Button {
                    store.settings.aiGroupingIncludePatterns = ""
                    store.settings.save()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.ui(size: 10))
                        .foregroundStyle(Color.difText3)
                }
                .buttonStyle(.plain)
                .help(L("Clear file filter", "清空文件过滤"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(hasText ? Color.difAccent.opacity(0.4) : Color.difHairline, lineWidth: 1)
        )
        .help(patternTooltip)
    }

    private func compactTogglePill(
        label: String,
        help: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.ui(size: 10.5, weight: isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color.difAccent : Color.difText2)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(height: UI.s(compact ? 22 : 24))
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? Color.difAccent.opacity(0.16) : Color.difChip)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isOn ? Color.difAccent.opacity(0.45) : Color.difHairline, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(help)
    }

    private func blacklistButton(count: Int, compact: Bool) -> some View {
        Button {
            showBlacklist.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "nosign")
                    .font(.ui(size: 9.5, weight: .semibold))
                Text(compact ? "\(count)" : L("Blacklist (\(count))", "黑名单 (\(count))"))
                    .font(.ui(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(Color.difRemoved)
            .padding(.horizontal, 6)
            .frame(height: UI.s(compact ? 22 : 24))
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.difRemoved.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.difRemoved.opacity(0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(L("Manage blacklisted files excluded from AI grouping", "管理不参与 AI 分组的黑名单文件"))
        .popover(isPresented: $showBlacklist, arrowEdge: .trailing) {
            AIGroupBlacklistPopover(project: project, isPresented: $showBlacklist)
        }
    }
}

private struct AIGroupBlacklistPopover: View {
    @Bindable var project: Project
    @Binding var isPresented: Bool
    @Environment(AppStore.self) private var store

    var body: some View {
        let paths = store.settings.aiGroupingBlacklist(for: project.url)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "nosign")
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Color.difRemoved)
                Text(L("AI Grouping Blacklist", "分组黑名单"))
                    .font(.ui(size: 12, weight: .semibold))
                    .foregroundStyle(Color.difText)
                Text("\(paths.count)")
                    .font(.ui(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.difText3)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.difChip))
                Spacer()
                if !paths.isEmpty {
                    Button {
                        store.clearAIGroupingBlacklist(in: project)
                        isPresented = false
                    } label: {
                        Text(L("Clear All", "清空"))
                            .font(.ui(size: 11, weight: .medium))
                            .foregroundStyle(Color.difRemoved)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Text(L("Right-click any file to add or remove it.", "右键点击任意文件可加入或移出黑名单。"))
                .font(.ui(size: 10.5))
                .foregroundStyle(Color.difText3)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            if paths.isEmpty {
                Text(L("No blacklisted files", "暂无黑名单文件"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(paths, id: \.self) { path in
                            let nsPath = path as NSString
                            let fileName = nsPath.lastPathComponent
                            let dir = nsPath.deletingLastPathComponent
                            HStack(spacing: 6) {
                                FileIcon(path: path, size: 12)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(fileName)
                                        .font(.ui(size: 11.5, weight: .medium))
                                        .foregroundStyle(Color.difText)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if !dir.isEmpty {
                                        Text(dir)
                                            .font(.ui(size: 10))
                                            .foregroundStyle(Color.difText3)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }
                                Spacer(minLength: 4)
                                Button {
                                    store.removeAIGroupingBlacklist(path: path, in: project)
                                    if store.settings.aiGroupingBlacklist(for: project.url).isEmpty {
                                        isPresented = false
                                    }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.ui(size: 9, weight: .bold))
                                        .foregroundStyle(Color.difText3)
                                        .frame(width: UI.s(18), height: UI.s(18))
                                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difChip))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help(L("Remove from blacklist", "移出黑名单"))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.difChip.opacity(0.45)))
                            .help(path)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
            }
        }
        .frame(width: 320)
    }
}
