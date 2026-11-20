import AppKit
import SwiftUI

struct MergeCanvasHost: NSViewRepresentable {
    let session: ThreeWayMergeSession

    func makeNSView(context: Context) -> MergeScrollContainer {
        let container = MergeScrollContainer(frame: .zero)
        session.attach(container)
        return container
    }

    func updateNSView(_ view: MergeScrollContainer, context: Context) {
        if session.canvasContainer !== view {
            session.attach(view)
        }
    }
}

struct ThreeWayMergeView: View {
    @Bindable var session: ThreeWayMergeSession
    @Environment(AppStore.self) private var store

    var body: some View {
        let _ = session.revision
        ZStack {
            Color.difIslandFrame.ignoresSafeArea()
            VStack(spacing: 0) {
                titlebar
                Rectangle().fill(Color.difHairline).frame(height: 1)
                if session.currentDocument != nil || session.currentKind != nil {
                    actionToolbar
                    Rectangle().fill(Color.difHairline).frame(height: 1)
                }
                mainContent
                Rectangle().fill(Color.difHairline).frame(height: 1)
                statusBar
            }
            .islandCard(background: .difWindow)
            .padding(IslandStyle.outerPadding)
        }
    }

    // MARK: Titlebar

    private var titlebar: some View {
        let leadingInset: CGFloat = store.isFullScreen ? 14 : 78
        return HStack(spacing: 8) {
            if session.files.count > 1 {
                IconButton(
                    symbol: "sidebar.left",
                    help: L("Toggle Conflicted Files List", "显示/隐藏冲突文件列表"),
                    isActive: session.showFileList
                ) {
                    withAnimation(.snappy(duration: 0.18)) {
                        session.showFileList.toggle()
                    }
                }
                .titlebarClickGuard(horizontalOutset: 2)
            }

            Image(systemName: "arrow.triangle.merge")
                .font(.ui(size: 13, weight: .semibold))
                .foregroundStyle(Color.orange)

            if let file = session.currentFile {
                FileIcon(path: file.path, size: 13)
                Text(file.name)
                    .font(.ui(size: 13, weight: .semibold))
                    .foregroundStyle(Color.difText)
                    .lineLimit(1)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(.ui(size: 11.5))
                        .foregroundStyle(Color.difText3)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            if let op = session.project.status.operation {
                Text(op.title)
                    .font(.ui(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.14)))
                    .fixedSize()
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if session.files.count > 1 {
                    let currentIdx = (session.files.firstIndex { $0.path == session.selectedPath } ?? 0) + 1
                    HStack(spacing: 3) {
                        IconButton(symbol: "chevron.left", help: L("Previous Conflicted File", "上一个冲突文件"), size: 11) {
                            session.stepFile(-1)
                        }
                        Text("\(currentIdx)/\(session.files.count)")
                            .font(.ui(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.difText2)
                            .monospacedDigit()
                            .fixedSize()
                        IconButton(symbol: "chevron.right", help: L("Next Conflicted File", "下一个冲突文件"), size: 11) {
                            session.stepFile(1)
                        }
                    }
                    Divider().frame(height: 14)
                }

                Button {
                    store.requestCloseMergeSession()
                } label: {
                    Text(L("Close", "关闭"))
                        .font(.ui(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.difText)
                        .padding(.horizontal, 10)
                        .frame(height: UI.s(24))
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difText.opacity(0.08)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Close 3-Way Merge (Esc)", "关闭三方合并窗口 (Esc)"))

                if session.currentDocument != nil {
                    let ready = (session.currentDocument?.unresolvedConflictCount ?? 0) == 0
                    Button {
                        session.applyCurrentFile()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.ui(size: 11, weight: .semibold))
                            Text(L("Apply", "应用并标记已解决"))
                                .font(.ui(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .frame(height: UI.s(24))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(ready ? Color.difAdded : Color.difAccent)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L("Save result and mark resolved in Git (⌘↩)", "保存合并结果并向 Git 标记为已解决 (⌘↩)"))
                }
            }
            .frame(maxHeight: .infinity)
            .titlebarClickGuard(horizontalOutset: 4)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(height: max(38, store.titlebarHeight))
        .background(WindowDragArea())
    }

    // MARK: Merge Toolbar

    private var actionToolbar: some View {
        let doc = session.currentDocument
        let conflicts = doc?.unresolvedConflictCount ?? 0
        let nonConflicts = doc?.unresolvedNonConflictCount ?? 0
        let leftNonConflicts = doc?.unresolvedLeftNonConflictCount ?? 0
        let rightNonConflicts = doc?.unresolvedRightNonConflictCount ?? 0
        let activeConflict = session.activeConflictChunkIndex

        return HStack(spacing: 8) {
            if let doc {
                // Navigation
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.up", help: L("Previous Conflict (⇧F7)", "上一处冲突 (⇧F7)"), size: 11.5) {
                        session.stepConflict(-1)
                    }
                    .disabled(doc.chunks.isEmpty)
                    .opacity(doc.chunks.isEmpty ? 0.35 : 1)

                    IconButton(symbol: "arrow.down", help: L("Next Conflict (F7)", "下一处冲突 (F7)"), size: 11.5) {
                        session.stepConflict(1)
                    }
                    .disabled(doc.chunks.isEmpty)
                    .opacity(doc.chunks.isEmpty ? 0.35 : 1)
                }

                // Live conflict & non-conflict counters
                HStack(spacing: 6) {
                    if conflicts > 0 {
                        MergeCountBadge(
                            symbol: "exclamationmark.triangle.fill",
                            text: conflicts == 1 ? L("1 conflict", "1 处冲突") : L("\(conflicts) conflicts", "\(conflicts) 处冲突"),
                            tint: .red
                        )
                    } else {
                        MergeCountBadge(
                            symbol: "checkmark.circle.fill",
                            text: L("No conflicts left", "冲突已全部解决"),
                            tint: Color.difAdded
                        )
                    }
                    if nonConflicts > 0 {
                        MergeCountBadge(
                            symbol: "arrow.triangle.branch",
                            text: nonConflicts == 1 ? L("1 auto-mergeable", "1 处非冲突") : L("\(nonConflicts) auto-mergeable", "\(nonConflicts) 处非冲突"),
                            tint: Color.difAccent
                        )
                    }
                }

                Divider().frame(height: 16)

                // Hero action: One-click merge all non-conflicting changes (GoLand's Resolve Simple Conflicts)
                HStack(spacing: 2) {
                    Button {
                        _ = session.applyAllNonConflicting()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "wand.and.stars")
                                .font(.ui(size: 11.5, weight: .semibold))
                            Text(L("Apply Non-Conflicting", "一键合并非冲突"))
                                .font(.ui(size: 11.5, weight: .semibold))
                            if nonConflicts > 0 {
                                Text("\(nonConflicts)")
                                    .font(.ui(size: 10.5, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.white.opacity(0.22)))
                            }
                        }
                        .foregroundStyle(nonConflicts > 0 ? Color.white : Color.difText3)
                        .padding(.horizontal, 10)
                        .frame(height: UI.s(24))
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(nonConflicts > 0 ? Color.difAccent : Color.difText.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(nonConflicts == 0)
                    .help(L("Automatically merge all non-conflicting changes from both sides while leaving conflicts intact",
                            "一键将左右两侧互不冲突的改动全部合并到结果中，冲突部分保持不变"))

                    Menu {
                        Button(L("Apply Non-Conflicting from Left (\(leftNonConflicts))", "仅合并左侧非冲突 (\(leftNonConflicts))")) {
                            _ = session.applyAllNonConflicting(sideFilter: .left)
                        }
                        .disabled(leftNonConflicts == 0)

                        Button(L("Apply Non-Conflicting from Right (\(rightNonConflicts))", "仅合并右侧非冲突 (\(rightNonConflicts))")) {
                            _ = session.applyAllNonConflicting(sideFilter: .right)
                        }
                        .disabled(rightNonConflicts == 0)

                        Divider()

                        Button(L("Accept All Left", "全部采用左侧")) {
                            session.acceptEntireSide(.left)
                        }
                        Button(L("Accept All Right", "全部采用右侧")) {
                            session.acceptEntireSide(.right)
                        }

                        Divider()

                        Button(L("Reset Result to Base", "重置为共同祖先")) {
                            session.resetCurrentFile()
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.ui(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.difText2)
                            .frame(width: UI.s(20), height: UI.s(24))
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.difText.opacity(0.08)))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Divider().frame(height: 16)

                // Focused conflict quick-resolution choices (Left / Right / Both L+R / Both R+L)
                HStack(spacing: 4) {
                    MergeToolbarChoiceButton(title: L("Left", "选左"), symbol: "arrow.right", enabled: activeConflict != nil) {
                        session.resolveFocusedConflict(.acceptLeft)
                    }
                    .help(L("Resolve focused conflict by taking Left", "用左侧内容解决当前冲突"))

                    MergeToolbarChoiceButton(title: L("Right", "选右"), symbol: "arrow.left", enabled: activeConflict != nil) {
                        session.resolveFocusedConflict(.acceptRight)
                    }
                    .help(L("Resolve focused conflict by taking Right", "用右侧内容解决当前冲突"))

                    MergeToolbarChoiceButton(title: L("Both L+R", "左+右"), symbol: "arrow.left.and.right", enabled: activeConflict != nil) {
                        session.resolveFocusedConflict(.acceptBothLeftFirst)
                    }
                    .help(L("Keep both sides in order: Left then Right", "两边一起保留：先左侧后右侧"))

                    MergeToolbarChoiceButton(title: L("Both R+L", "右+左"), symbol: "arrow.right.and.left", enabled: activeConflict != nil) {
                        session.resolveFocusedConflict(.acceptBothRightFirst)
                    }
                    .help(L("Keep both sides in order: Right then Left", "两边一起保留：先右侧后左侧"))
                }
            } else {
                Text(L("Choose an action for this conflicted file below", "请在下方为这个冲突文件选择处理方式"))
                    .font(.ui(size: 11.5))
                    .foregroundStyle(Color.difText2)
            }

            Spacer(minLength: 6)

            if session.currentDocument != nil {
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.uturn.backward", help: L("Undo (⌘Z)", "撤销 (⌘Z)"), size: 11.5) {
                        session.undo()
                    }
                    .disabled(!session.canUndo)
                    .opacity(session.canUndo ? 1 : 0.35)

                    IconButton(symbol: "arrow.uturn.forward", help: L("Redo (⇧⌘Z)", "重做 (⇧⌘Z)"), size: 11.5) {
                        session.redo()
                    }
                    .disabled(!session.canRedo)
                    .opacity(session.canRedo ? 1 : 0.35)
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(38))
        .background(Color.difPanel)
    }

    // MARK: Main Content

    private var mainContent: some View {
        HStack(spacing: 0) {
            if session.showFileList && session.files.count > 1 {
                ConflictedFilesSidebar(session: session)
                    .frame(width: 224)
                Rectangle().fill(Color.difHairline).frame(width: 1)
            }

            VStack(spacing: 0) {
                if session.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(L("Loading 3-way merge…", "正在加载三方合并…"))
                            .font(.ui(size: 12))
                            .foregroundStyle(Color.difText3)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let kind = session.currentKind {
                    switch kind {
                    case .text(let doc):
                        ThreeWayPaneHeaders(doc: doc, session: session)
                        Rectangle().fill(Color.difHairline).frame(height: 1)
                        MergeCanvasHost(session: session)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .binary(let leftSize, let baseSize, let rightSize):
                        NonTextConflictView(
                            symbol: "doc.zipper",
                            title: L("Binary file conflict", "二进制文件冲突"),
                            detail: binaryDetail(left: leftSize, base: baseSize, right: rightSize),
                            previewText: nil,
                            actions: [
                                (L("Keep Left (HEAD)", "保留左侧 (HEAD)"), .keepLeft, true),
                                (L("Keep Right (Incoming)", "采用右侧 (传入)"), .keepRight, false),
                            ],
                            onAction: { session.resolveNonTextConflict($0) }
                        )
                    case .image(let left, let right):
                        ImageConflictView(left: left, right: right) {
                            session.resolveNonTextConflict($0)
                        }
                    case .deletedByLeft(let rightPreview, let rightSize):
                        NonTextConflictView(
                            symbol: "trash.slash",
                            title: L("Deleted on Left (HEAD), modified on Right (Incoming)", "左侧 (HEAD) 删除了此文件，右侧 (传入) 修改了它"),
                            detail: L("Incoming version size: \(rightSize.byteSizeString)", "传入版本大小：\(rightSize.byteSizeString)"),
                            previewText: rightPreview,
                            actions: [
                                (L("Keep Incoming File", "保留右侧文件"), .keepRight, true),
                                (L("Delete File", "确认删除文件"), .deleteFile, false),
                            ],
                            onAction: { session.resolveNonTextConflict($0) }
                        )
                    case .deletedByRight(let leftPreview, let leftSize):
                        NonTextConflictView(
                            symbol: "trash.slash",
                            title: L("Modified on Left (HEAD), deleted on Right (Incoming)", "左侧 (HEAD) 修改了此文件，右侧 (传入) 删除了它"),
                            detail: L("Local version size: \(leftSize.byteSizeString)", "本地版本大小：\(leftSize.byteSizeString)"),
                            previewText: leftPreview,
                            actions: [
                                (L("Keep Local File", "保留左侧文件"), .keepLeft, true),
                                (L("Delete File", "确认删除文件"), .deleteFile, false),
                            ],
                            onAction: { session.resolveNonTextConflict($0) }
                        )
                    case .bothDeleted:
                        NonTextConflictView(
                            symbol: "trash",
                            title: L("Deleted on both sides", "左右两侧都删除了这个文件"),
                            detail: L("Confirm deleting it from the index to mark this conflict resolved.", "确认从暂存区移除该文件即可标记为已解决。"),
                            previewText: nil,
                            actions: [
                                (L("Delete File & Mark Resolved", "删除文件并标记已解决"), .deleteFile, true),
                            ],
                            onAction: { session.resolveNonTextConflict($0) }
                        )
                    case .message(let title, let detail):
                        EmptyListState(symbol: "exclamationmark.triangle", title: title, detail: detail)
                    }
                } else {
                    EmptyListState(
                        symbol: "arrow.triangle.merge",
                        title: L("No file selected", "未选择文件"),
                        detail: L("Pick a conflicted file from the list.", "请从左侧选择一个冲突文件。")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func binaryDetail(left: Int?, base: Int?, right: Int?) -> String {
        let parts: [String] = [
            left.map { L("Left: \($0.byteSizeString)", "左侧：\($0.byteSizeString)") },
            base.map { L("Base: \($0.byteSizeString)", "共同祖先：\($0.byteSizeString)") },
            right.map { L("Right: \($0.byteSizeString)", "右侧：\($0.byteSizeString)") },
        ].compactMap { $0 }
        return parts.isEmpty ? L("Choose which version to keep.", "请选择要保留的版本。") : parts.joined(separator: "  ·  ")
    }

    // MARK: Status Bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            if let hint = session.hoverHint {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.ui(size: 10.5))
                        .foregroundStyle(Color.difAccent)
                    Text(hint)
                        .font(.ui(size: 11, weight: .medium))
                        .foregroundStyle(Color.difText)
                }
            } else if session.currentDocument != nil {
                Text("Ln \(session.cursorLine), Col \(session.cursorColumn)")
                    .font(.system(size: 10.5 * UI.scale, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.difText3)
                Text(L("Center pane is directly editable", "中间结果窗格可直接编辑"))
                    .font(.ui(size: 10.5))
                    .foregroundStyle(Color.difText3)
            }

            Spacer()

            Text(L("F7 / ⇧F7 Next/Prev Conflict · ⌘Z Undo · ⌘↩ Apply · Esc Close",
                   "F7 / ⇧F7 上下冲突 · ⌘Z 撤销 · ⌘↩ 应用 · Esc 关闭"))
                .font(.ui(size: 10.5))
                .foregroundStyle(Color.difText3)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: UI.s(24))
        .background(Color.difPanel)
    }
}

// MARK: - Subviews

private struct ThreeWayPaneHeaders: View {
    let doc: ThreeWayMergeDocument
    let session: ThreeWayMergeSession

    var body: some View {
        GeometryReader { proxy in
            let w = MergeCanvasView.paneWidths(totalWidth: proxy.size.width)
            HStack(spacing: 0) {
                paneHeader(
                    title: doc.titles.left,
                    tint: Color.difAccent,
                    actionTitle: L("Use Left", "全部用左"),
                    actionHelp: L("Accept Left for all changes in this file", "将本文件全部采用左侧版本")
                ) {
                    session.acceptEntireSide(.left)
                }
                .frame(width: w.left, alignment: .leading)

                Spacer().frame(width: MergeCanvasView.bridgeWidth)

                HStack(spacing: 6) {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                    Text(doc.titles.center)
                        .font(.ui(size: 11, weight: .semibold))
                        .foregroundStyle(Color.difText)
                        .lineLimit(1)
                    if doc.isModified {
                        Circle()
                            .fill(Color.difText2)
                            .frame(width: 6, height: 6)
                            .help(L("Modified · click Apply to save", "已修改 · 点击“应用并标记已解决”以保存"))
                    }
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 10)
                .frame(width: w.center, alignment: .leading)

                Spacer().frame(width: MergeCanvasView.bridgeWidth)

                paneHeader(
                    title: doc.titles.right,
                    tint: Color.difAdded,
                    actionTitle: L("Use Right", "全部用右"),
                    actionHelp: L("Accept Right for all changes in this file", "将本文件全部采用右侧版本")
                ) {
                    session.acceptEntireSide(.right)
                }
                .frame(width: w.right, alignment: .leading)

                Spacer().frame(width: MergeCanvasView.rulerWidth)
            }
        }
        .frame(height: UI.s(26))
        .background(Color.difWindow)
    }

    private func paneHeader(title: String, tint: Color, actionTitle: String, actionHelp: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(title)
                .font(.ui(size: 11, weight: .semibold))
                .foregroundStyle(Color.difText2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Button(action: action) {
                Text(actionTitle)
                    .font(.ui(size: 10, weight: .medium))
                    .foregroundStyle(Color.difText2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.difText.opacity(0.06)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(actionHelp)
        }
        .padding(.horizontal, 10)
    }
}

private struct ConflictedFilesSidebar: View {
    let session: ThreeWayMergeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Conflicted Files", "冲突文件"))
                    .font(.ui(size: 11, weight: .semibold))
                    .foregroundStyle(Color.difText2)
                Spacer()
                Text("\(session.resolvedFileCount)/\(session.files.count)")
                    .font(.ui(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.difText3)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: UI.s(26))
            .background(Color.difPanel)

            Rectangle().fill(Color.difHairline).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(session.files) { item in
                        let selected = item.path == session.selectedPath
                        Button {
                            session.selectFile(item.path)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: item.isResolved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.ui(size: 11, weight: .semibold))
                                    .foregroundStyle(item.isResolved ? Color.difAdded : Color.orange)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name)
                                        .font(.ui(size: 11.5, weight: selected ? .semibold : .regular))
                                        .foregroundStyle(item.isResolved ? Color.difText3 : Color.difText)
                                        .lineLimit(1)
                                    if !item.directory.isEmpty {
                                        Text(item.directory)
                                            .font(.ui(size: 10))
                                            .foregroundStyle(Color.difText3)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }

                                Spacer(minLength: 4)

                                if !item.isResolved, let c = item.unresolvedConflicts {
                                    Text("\(c)")
                                        .font(.ui(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(c > 0 ? Color.red : Color.difAdded)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill((c > 0 ? Color.red : Color.difAdded).opacity(0.14)))
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(selected ? Color.difSelection : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if !item.isResolved {
                                Button(L("Accept Left (HEAD)", "采用左侧 (HEAD)")) {
                                    session.resolveNonTextConflict(.keepLeft, for: item.path)
                                }
                                Button(L("Accept Right (Incoming)", "采用右侧 (传入)")) {
                                    session.resolveNonTextConflict(.keepRight, for: item.path)
                                }
                            }
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(Color.difSidebar.opacity(0.5))
    }
}

private struct MergeCountBadge: View {
    var symbol: String
    var text: String
    var tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.ui(size: 10, weight: .semibold))
            Text(text)
                .font(.ui(size: 11, weight: .semibold))
                .fixedSize()
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: UI.s(22))
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

private struct MergeToolbarChoiceButton: View {
    var title: String
    var symbol: String
    var enabled: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.ui(size: 10, weight: .semibold))
                Text(title)
                    .font(.ui(size: 11, weight: .medium))
            }
            .foregroundStyle(enabled ? Color.difText : Color.difText3)
            .padding(.horizontal, 8)
            .frame(height: UI.s(24))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(enabled ? Color.difText.opacity(hovering ? 0.14 : 0.08) : Color.difText.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

private struct NonTextConflictView: View {
    var symbol: String
    var title: String
    var detail: String
    var previewText: String?
    var actions: [(title: String, action: NonTextConflictAction, prominent: Bool)]
    var onAction: (NonTextConflictAction) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.ui(size: 32))
                .foregroundStyle(Color.orange)
            Text(title)
                .font(.ui(size: 15, weight: .semibold))
                .foregroundStyle(Color.difText)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.ui(size: 12.5))
                .foregroundStyle(Color.difText2)
                .multilineTextAlignment(.center)

            if let previewText, !previewText.isEmpty {
                ScrollView {
                    Text(previewText)
                        .font(.code(11.5))
                        .foregroundStyle(Color.difText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxWidth: 680, maxHeight: 260)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.difPanel))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.difHairline, lineWidth: 1))
            }

            HStack(spacing: 10) {
                ForEach(actions.indices, id: \.self) { idx in
                    let item = actions[idx]
                    Button {
                        onAction(item.action)
                    } label: {
                        Text(item.title)
                            .font(.ui(size: 12, weight: .semibold))
                            .foregroundStyle(item.prominent ? Color.white : Color.difText)
                            .padding(.horizontal, 14)
                            .frame(height: UI.s(28))
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(item.prominent ? Color.difAccent : Color.difText.opacity(0.09))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ImageConflictView: View {
    var left: Data?
    var right: Data?
    var onAction: (NonTextConflictAction) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Text(L("Image file conflict", "图片文件冲突"))
                .font(.ui(size: 15, weight: .semibold))
                .foregroundStyle(Color.difText)

            HStack(spacing: 20) {
                imageCard(data: left, title: L("Left (HEAD)", "左侧 (HEAD)"), actionTitle: L("Keep Left", "保留左侧"), tint: Color.difAccent) {
                    onAction(.keepLeft)
                }
                imageCard(data: right, title: L("Right (Incoming)", "右侧 (传入)"), actionTitle: L("Keep Right", "采用右侧"), tint: Color.difAdded) {
                    onAction(.keepRight)
                }
            }
            .frame(maxWidth: 820, maxHeight: 420)

            if left == nil || right == nil {
                Button {
                    onAction(.deleteFile)
                } label: {
                    Text(L("Delete File", "删除文件"))
                        .font(.ui(size: 12, weight: .semibold))
                        .foregroundStyle(Color.difRemoved)
                        .padding(.horizontal, 14)
                        .frame(height: UI.s(28))
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.difRemoved.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func imageCard(data: Data?, title: String, actionTitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.difPanel)
                if let data, let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(16)
                } else {
                    Text(L("Deleted on this side", "此侧已删除"))
                        .font(.ui(size: 12))
                        .foregroundStyle(Color.difText3)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1))

            HStack {
                Text(title).font(.ui(size: 12, weight: .semibold)).foregroundStyle(tint)
                if let data {
                    Text(data.count.byteSizeString).font(.ui(size: 11)).foregroundStyle(Color.difText3)
                }
                Spacer()
                if data != nil {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(.ui(size: 11.5, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 12)
                            .frame(height: UI.s(24))
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
