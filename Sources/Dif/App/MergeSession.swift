import AppKit
import Observation
import SwiftUI

struct MergeFileItem: Identifiable, Equatable {
    var path: String
    var isResolved = false
    var unresolvedConflicts: Int?
    var unresolvedNonConflicts: Int?

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

@MainActor
@Observable
final class ThreeWayMergeSession: MergeCanvasDelegate {
    let project: Project
    var files: [MergeFileItem]
    var selectedPath: String?
    var isLoading = false
    var focusedChunk: Int?
    var revision = 0
    var hoverHint: String?
    var cursorLine = 1
    var cursorColumn = 1
    var showFileList: Bool
    var ignoreWhitespace: Bool

    @ObservationIgnored var loadedFiles: [String: ConflictFileKind] = [:]
    @ObservationIgnored weak var canvasContainer: MergeScrollContainer?
    @ObservationIgnored weak var store: AppStore?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(project: Project, paths: [String], focusing: String? = nil, store: AppStore) {
        self.project = project
        self.store = store
        self.files = paths.map { MergeFileItem(path: $0) }
        self.showFileList = paths.count > 1
        self.ignoreWhitespace = store.settings.ignoreWhitespace
        let initial = focusing.flatMap { p in paths.contains(p) ? p : nil } ?? paths.first
        if let initial {
            selectFile(initial)
        }
    }

    var currentFile: MergeFileItem? {
        guard let selectedPath else { return nil }
        return files.first { $0.path == selectedPath }
    }

    var currentKind: ConflictFileKind? {
        guard let selectedPath else { return nil }
        return loadedFiles[selectedPath]
    }

    var currentDocument: ThreeWayMergeDocument? {
        guard case .text(let doc) = currentKind else { return nil }
        return doc
    }

    var resolvedFileCount: Int {
        files.filter(\.isResolved).count
    }

    var unresolvedFileCount: Int {
        files.filter { !$0.isResolved }.count
    }

    var canUndo: Bool {
        currentDocument?.canUndo ?? false
    }

    var canRedo: Bool {
        currentDocument?.canRedo ?? false
    }

    var hasUnsavedChanges: Bool {
        for item in files where !item.isResolved {
            if case .text(let doc) = loadedFiles[item.path], doc.isModified {
                return true
            }
        }
        return false
    }

    /// Returns the currently focused chunk index if it is an unresolved conflict, otherwise the first unresolved conflict.
    var activeConflictChunkIndex: Int? {
        guard let doc = currentDocument else { return nil }
        if let focused = focusedChunk, doc.chunks.indices.contains(focused), doc.chunks[focused].isConflict {
            return focused
        }
        return doc.chunks.firstIndex(where: \.isUnresolvedConflict)
            ?? doc.chunks.firstIndex(where: \.isConflict)
    }

    func attach(_ container: MergeScrollContainer) {
        canvasContainer = container
        container.canvas.delegate = self
        container.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
        syncCanvasDocument(autoFocus: true)
    }

    func applyCodeFont() {
        canvasContainer?.canvas.codeFont = CodeFont.current(store?.settings ?? .shared)
    }

    // MARK: File selection & loading

    func selectFile(_ path: String) {
        guard files.contains(where: { $0.path == path }) else { return }
        if selectedPath == path, loadedFiles[path] != nil, !isLoading {
            focusCanvas()
            return
        }
        canvasContainer?.canvas.commitComposition()
        selectedPath = path
        focusedChunk = nil
        hoverHint = nil
        cursorLine = 1
        cursorColumn = 1

        if let cached = loadedFiles[path] {
            isLoading = false
            updateCounts(for: path, kind: cached)
            syncCanvasDocument(autoFocus: true)
            revision &+= 1
            return
        }

        loadTask?.cancel()
        isLoading = true
        canvasContainer?.show(nil)
        let root = project.url
        let operation = project.status.operation
        let branch = project.status.branch
        let gitDir = project.gitDirectory
        let ignoreWS = ignoreWhitespace

        loadTask = Task { @MainActor [weak self] in
            let kind = await ThreeWayMergeLoader.load(
                path: path,
                in: root,
                operation: operation,
                branch: branch,
                gitDirectory: gitDir,
                ignoreWhitespace: ignoreWS
            )
            guard let self, !Task.isCancelled else { return }
            self.loadedFiles[path] = kind
            self.updateCounts(for: path, kind: kind)
            guard self.selectedPath == path else { return }
            self.isLoading = false
            self.syncCanvasDocument(autoFocus: true)
            self.revision &+= 1
        }
    }

    func reloadCurrentFile() {
        guard let path = selectedPath else { return }
        loadedFiles.removeValue(forKey: path)
        selectFile(path)
    }

    func stepFile(_ delta: Int) {
        guard !files.isEmpty else { return }
        let idx = files.firstIndex { $0.path == selectedPath } ?? 0
        let next = (idx + delta + files.count) % files.count
        selectFile(files[next].path)
    }

    private func syncCanvasDocument(autoFocus: Bool) {
        guard let container = canvasContainer else { return }
        guard case .text(let doc) = currentKind else {
            container.show(nil)
            return
        }
        container.show(doc)
        if autoFocus {
            container.whenLaidOut { [weak self, weak doc] in
                guard let self, let doc, self.currentDocument === doc else { return }
                let target = doc.chunks.firstIndex(where: \.isUnresolvedConflict)
                    ?? doc.chunks.firstIndex(where: \.isUnresolved)
                    ?? (doc.chunks.isEmpty ? nil : 0)
                if let target {
                    self.focusChunk(target, animated: false)
                }
                self.focusCanvas()
            }
        }
    }

    func focusCanvas() {
        guard let canvas = canvasContainer?.canvas else { return }
        canvas.window?.makeFirstResponder(canvas)
    }

    // MARK: Navigation

    func stepConflict(_ delta: Int) {
        guard let doc = currentDocument, !doc.chunks.isEmpty else { return }
        // Prefer stepping through unresolved conflicts; when none remain, step through remaining unresolved changes.
        let candidates: [Int]
        let unresolvedConflicts = doc.chunks.indices.filter { doc.chunks[$0].isUnresolvedConflict }
        if !unresolvedConflicts.isEmpty {
            candidates = unresolvedConflicts
        } else {
            let unresolvedAny = doc.chunks.indices.filter { doc.chunks[$0].isUnresolved }
            candidates = !unresolvedAny.isEmpty ? unresolvedAny : Array(doc.chunks.indices)
        }
        guard !candidates.isEmpty else { return }

        let target: Int
        if let current = focusedChunk {
            if delta > 0 {
                target = candidates.first(where: { $0 > current }) ?? candidates.first!
            } else {
                target = candidates.last(where: { $0 < current }) ?? candidates.last!
            }
        } else {
            target = delta > 0 ? candidates.first! : candidates.last!
        }
        focusChunk(target, animated: true)
    }

    func focusChunk(_ index: Int, animated: Bool = true) {
        guard let doc = currentDocument, doc.chunks.indices.contains(index) else { return }
        focusedChunk = index
        canvasContainer?.canvas.focusedChunk = index
        let chunk = doc.chunks[index]
        if !doc.center.lines.isEmpty {
            let caretRow = min(chunk.centerRange.lowerBound, doc.center.lines.count - 1)
            canvasContainer?.canvas.setCenterCaret(TextPosition(row: max(0, caretRow), column: 0))
        }
        let vStart = doc.virtualStart(ofChunk: index)
        canvasContainer?.scroll(toVirtualRow: vStart, fraction: 0.28, animated: animated)
    }

    // MARK: Merge Operations

    func acceptSide(_ side: MergeSide, chunk index: Int) {
        guard let doc = currentDocument, let path = selectedPath else { return }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        let anchor = doc.chunks.indices.contains(index) ? doc.chunks[index].centerRange.lowerBound : 0
        guard doc.acceptSide(side, chunkIndex: index, selection: sel) else { return }
        afterChunkMutation(path: path, doc: doc, anchorLine: anchor, mutatedChunk: index)
    }

    func ignoreSide(_ side: MergeSide, chunk index: Int) {
        guard let doc = currentDocument, let path = selectedPath else { return }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        let anchor = doc.chunks.indices.contains(index) ? doc.chunks[index].centerRange.lowerBound : 0
        guard doc.ignoreSide(side, chunkIndex: index, selection: sel) else { return }
        afterChunkMutation(path: path, doc: doc, anchorLine: anchor, mutatedChunk: index)
    }

    func resolveConflict(_ index: Int, choice: ConflictResolutionChoice) {
        guard let doc = currentDocument, let path = selectedPath else { return }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        let anchor = doc.chunks.indices.contains(index) ? doc.chunks[index].centerRange.lowerBound : 0
        guard doc.resolveConflict(index, choice: choice, selection: sel) else { return }
        afterChunkMutation(path: path, doc: doc, anchorLine: anchor, mutatedChunk: index)
    }

    func resolveFocusedConflict(_ choice: ConflictResolutionChoice) {
        guard let target = activeConflictChunkIndex else { return }
        resolveConflict(target, choice: choice)
    }

    @discardableResult
    func applyAllNonConflicting(sideFilter: MergeSide? = nil) -> Int {
        guard let doc = currentDocument, let path = selectedPath else { return 0 }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        let applied = doc.applyAllNonConflicting(sideFilter: sideFilter, selection: sel)
        guard applied > 0 else {
            store?.showToast(L("No non-conflicting changes left", "没有可合并的非冲突变更了"))
            return 0
        }
        updateCounts(for: path, kind: .text(doc))
        canvas?.refreshAfterDocumentMutation()
        revision &+= 1
        if let nextConflict = doc.chunks.firstIndex(where: \.isUnresolvedConflict) {
            focusChunk(nextConflict, animated: true)
            let leftConflicts = doc.unresolvedConflictCount
            store?.showToast(leftConflicts == 1
                ? L("Merged \(applied) non-conflicting · 1 conflict left", "已合并 \(applied) 处非冲突变更 · 剩余 1 处冲突")
                : L("Merged \(applied) non-conflicting · \(leftConflicts) conflicts left", "已合并 \(applied) 处非冲突变更 · 剩余 \(leftConflicts) 处冲突"))
        } else {
            store?.showToast(L("Merged all \(applied) non-conflicting changes", "已合并全部 \(applied) 处非冲突变更"))
        }
        return applied
    }

    func acceptEntireSide(_ side: MergeSide) {
        guard let doc = currentDocument, let path = selectedPath else {
            resolveNonTextConflict(side == .left ? .keepLeft : .keepRight)
            return
        }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        let count = doc.acceptAll(side, selection: sel)
        guard count > 0 else { return }
        updateCounts(for: path, kind: .text(doc))
        canvas?.refreshAfterDocumentMutation()
        revision &+= 1
        store?.showToast(side == .left ? L("Accepted Left for all changes", "已对所有变更采用左侧版本")
                                       : L("Accepted Right for all changes", "已对所有变更采用右侧版本"))
    }

    func resetCurrentFile() {
        guard let doc = currentDocument, let path = selectedPath else { return }
        let canvas = canvasContainer?.canvas
        canvas?.commitComposition()
        let sel = canvas?.centerEditSelection ?? defaultSelection(in: doc)
        guard doc.resetToBase(selection: sel) else { return }
        updateCounts(for: path, kind: .text(doc))
        canvas?.refreshAfterDocumentMutation()
        revision &+= 1
        if let first = doc.chunks.firstIndex(where: \.isUnresolvedConflict) ?? doc.chunks.indices.first {
            focusChunk(first, animated: true)
        }
        store?.showToast(L("Reset to common ancestor", "已重置为共同祖先版本"))
    }

    func undo() {
        guard let doc = currentDocument, let path = selectedPath else { return }
        canvasContainer?.canvas.commitComposition()
        guard let restored = doc.undo() else { return }
        updateCounts(for: path, kind: .text(doc))
        canvasContainer?.canvas.refreshAfterDocumentMutation(restoreSelection: restored)
        canvasContainer?.canvas.revealCenterCaret()
        revision &+= 1
    }

    func redo() {
        guard let doc = currentDocument, let path = selectedPath else { return }
        canvasContainer?.canvas.commitComposition()
        guard let restored = doc.redo() else { return }
        updateCounts(for: path, kind: .text(doc))
        canvasContainer?.canvas.refreshAfterDocumentMutation(restoreSelection: restored)
        canvasContainer?.canvas.revealCenterCaret()
        revision &+= 1
    }

    private func afterChunkMutation(path: String, doc: ThreeWayMergeDocument, anchorLine: Int, mutatedChunk: Int) {
        updateCounts(for: path, kind: .text(doc))
        canvasContainer?.canvas.refreshAfterDocumentMutation(preservingAnchorLine: anchorLine)
        revision &+= 1
        if doc.chunks[mutatedChunk].isResolved {
            if let next = doc.chunks.indices.first(where: { $0 > mutatedChunk && doc.chunks[$0].isUnresolvedConflict })
                ?? doc.chunks.firstIndex(where: \.isUnresolvedConflict) {
                focusChunk(next, animated: true)
            }
        } else {
            focusChunk(mutatedChunk, animated: false)
        }
    }

    // MARK: Applying & Completing

    func applyCurrentFile(force: Bool = false) {
        guard let path = selectedPath, let kind = loadedFiles[path] else { return }
        guard case .text(let doc) = kind else { return }
        canvasContainer?.canvas.commitComposition()

        if !force {
            let conflicts = doc.unresolvedConflictCount
            if conflicts > 0 {
                var request = DialogRequest(
                    style: .caution,
                    symbol: "exclamationmark.triangle",
                    title: conflicts == 1
                        ? L("1 conflict is still unresolved", "还有 1 处冲突未解决")
                        : L("\(conflicts) conflicts are still unresolved", "还有 \(conflicts) 处冲突未解决"),
                    message: L("If you apply now, the Result pane as shown will be saved and marked resolved in Git.",
                               "如果现在应用，将按当前“合并结果”窗格的内容写入文件并向 Git 标记为已解决。"),
                    confirmTitle: L("Apply Anyway", "仍然应用")
                )
                request.onConfirm = { [weak self] in self?.applyCurrentFile(force: true) }
                store?.ask(request)
                return
            }

            let nonConflicts = doc.unresolvedNonConflictCount
            if nonConflicts > 0 {
                var request = DialogRequest(
                    style: .info,
                    symbol: "wand.and.stars",
                    title: nonConflicts == 1
                        ? L("1 non-conflicting change is not merged yet", "还有 1 处非冲突变更尚未合并")
                        : L("\(nonConflicts) non-conflicting changes are not merged yet", "还有 \(nonConflicts) 处非冲突变更尚未合并"),
                    message: L("Merge the remaining non-conflicting changes into the result before saving?",
                               "是否在保存前先将剩余的非冲突变更一起合并到结果中？"),
                    confirmTitle: L("Merge Non-Conflicting & Apply", "合并非冲突并应用")
                )
                request.alternateTitle = L("Apply as Is", "按当前结果应用")
                request.onConfirm = { [weak self] in
                    guard let self else { return }
                    _ = self.applyAllNonConflicting()
                    self.applyCurrentFile(force: true)
                }
                request.onAlternate = { [weak self] in
                    self?.applyCurrentFile(force: true)
                }
                store?.ask(request)
                return
            }
        }

        guard let data = doc.encodedCenterData() else {
            store?.showToast(L("Could not encode merged text in the file's encoding", "无法用文件原编码保存合并结果"))
            return
        }

        let fileURL = project.url.appendingPathComponent(path)
        let root = project.url
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                try await Git.markResolved([path], in: root)
                doc.markSaved()
                self.markFileResolvedAndAdvance(path: path)
            } catch {
                self.store?.showFailure(L("Could not apply merge result", "无法应用合并结果"), error)
            }
        }
    }

    func resolveNonTextConflict(_ action: NonTextConflictAction, for targetPath: String? = nil) {
        guard let path = targetPath ?? selectedPath else { return }
        let root = project.url
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch action {
                case .keepLeft:
                    try await Git.takeSide(.ours, path: path, in: root)
                case .keepRight:
                    try await Git.takeSide(.theirs, path: path, in: root)
                case .deleteFile:
                    try await Git.removeResolved([path], in: root)
                }
                self.markFileResolvedAndAdvance(path: path)
            } catch {
                self.store?.showFailure(L("Could not resolve \((path as NSString).lastPathComponent)",
                                          "无法解决 \((path as NSString).lastPathComponent)"), error)
            }
        }
    }

    private func markFileResolvedAndAdvance(path: String) {
        if let idx = files.firstIndex(where: { $0.path == path }) {
            files[idx].isResolved = true
            files[idx].unresolvedConflicts = 0
            files[idx].unresolvedNonConflicts = 0
        }
        project.refresh()
        store?.syncViewer()
        revision &+= 1

        let name = (path as NSString).lastPathComponent
        if let next = files.first(where: { !$0.isResolved }) {
            store?.showToast(L("Resolved \(name) · \(unresolvedFileCount) file(s) remaining",
                               "已解决 \(name) · 还剩 \(unresolvedFileCount) 个文件"))
            selectFile(next.path)
            return
        }

        // All conflicted files in this session have been resolved.
        let operation = project.status.operation
        let shouldResumePush = project.pendingPushAfterPull != nil
        store?.closeMergeSession(rememberDismissal: false)
        if shouldResumePush {
            store?.resumePendingPushAfterConflictsResolved(in: project)
            return
        }
        if let operation, operation != .merge {
            store?.showToast(
                L("All conflicts resolved · continue \(operation.command)", "所有冲突已解决 · 可以继续 \(operation.command)"),
                action: ToastAction(title: L("Continue", "继续")) { [weak store, weak project] in
                    guard let store, let project else { return }
                    store.continueOperation(in: project)
                }
            )
        } else if operation == .merge {
            store?.showToast(L("All conflicts resolved · commit to finish the merge", "所有冲突已解决 · 提交即可完成合并"))
        } else {
            store?.showToast(L("All conflicts resolved", "所有冲突已解决"))
        }
    }

    func refreshFromProjectStatus() {
        let stillConflicted = Set(project.status.changes.filter { $0.kind == .conflicted }.map(\.path))
        var changed = false
        for idx in files.indices {
            let shouldBeResolved = !stillConflicted.contains(files[idx].path)
            if files[idx].isResolved != shouldBeResolved {
                files[idx].isResolved = shouldBeResolved
                changed = true
            }
        }
        for path in stillConflicted.sorted() where !files.contains(where: { $0.path == path }) {
            files.append(MergeFileItem(path: path))
            changed = true
        }
        if changed { revision &+= 1 }
    }

    func release() {
        loadTask?.cancel()
        loadTask = nil
        loadedFiles.removeAll()
        canvasContainer?.show(nil)
        canvasContainer = nil
    }

    // MARK: MergeCanvasDelegate

    func mergeCanvas(_ canvas: MergeCanvasView, acceptSide side: MergeSide, chunk index: Int) {
        acceptSide(side, chunk: index)
    }

    func mergeCanvas(_ canvas: MergeCanvasView, ignoreSide side: MergeSide, chunk index: Int) {
        ignoreSide(side, chunk: index)
    }

    func mergeCanvas(_ canvas: MergeCanvasView, resolveConflict index: Int, choice: ConflictResolutionChoice) {
        resolveConflict(index, choice: choice)
    }

    func mergeCanvas(_ canvas: MergeCanvasView, focusChunk index: Int) {
        focusedChunk = index
        canvas.focusedChunk = index
    }

    func mergeCanvas(_ canvas: MergeCanvasView, hoverHint hint: String?) {
        hoverHint = hint
    }

    func mergeCanvas(_ canvas: MergeCanvasView, cursorMovedToLine line: Int, column: Int) {
        cursorLine = line
        cursorColumn = column
    }

    func mergeCanvasDidEditCenter(_ canvas: MergeCanvasView) {
        if let path = selectedPath, let doc = currentDocument {
            updateCounts(for: path, kind: .text(doc))
        }
        revision &+= 1
    }

    private func defaultSelection(in doc: ThreeWayMergeDocument) -> EditorSession.Selection {
        if let sel = canvasContainer?.canvas.centerEditSelection { return sel }
        let row = doc.center.lines.isEmpty ? 0 : 0
        return (TextPosition(row: row, column: 0), TextPosition(row: row, column: 0))
    }

    private func updateCounts(for path: String, kind: ConflictFileKind) {
        guard let idx = files.firstIndex(where: { $0.path == path }) else { return }
        if case .text(let doc) = kind {
            files[idx].unresolvedConflicts = doc.unresolvedConflictCount
            files[idx].unresolvedNonConflicts = doc.unresolvedNonConflictCount
        }
    }
}

// MARK: - AppStore orchestration & auto-open

extension AppStore {
    /// Opens the 3-way merge window/overlay for `project`'s conflicted files.
    func openThreeWayMerge(in project: Project? = nil, focusing path: String? = nil, automatic: Bool = false) {
        guard let project = project ?? currentProject else { return }
        let paths = project.status.changes.filter { $0.kind == .conflicted }.map(\.path)
        if !paths.isEmpty {
            openThreeWayMerge(in: project, paths: paths, focusing: path, automatic: automatic)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let out = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U", "-z"], in: project.url)) ?? ""
            let freshPaths = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            guard !freshPaths.isEmpty else {
                if !automatic {
                    self.showToast(L("No conflicted files in this repository", "当前仓库没有冲突文件"))
                }
                return
            }
            self.openThreeWayMerge(in: project, paths: freshPaths, focusing: path, automatic: automatic)
        }
    }

    func openThreeWayMerge(in project: Project, paths: [String], focusing path: String? = nil, automatic: Bool = false) {
        guard !paths.isEmpty else { return }
        if let existing = mergeSession, existing.project.id == project.id {
            existing.refreshFromProjectStatus()
            if let path { existing.selectFile(path) }
            return
        }
        if popup != nil { dismissPopup(restoreFocus: false) }
        _ = viewer.saveEdits()
        if !automatic {
            project.dismissedConflictSignature = nil
        }
        let session = ThreeWayMergeSession(project: project, paths: paths, focusing: path, store: self)
        mergeSession = session
    }

    /// Called immediately whenever a Git operation (merge, rebase, pull, cherry-pick, revert, smart checkout, stash pop) stops on conflicts.
    func handleConflictsDetected(in project: Project, title: String, note: String?) {
        project.dismissedConflictSignature = nil
        project.refresh()
        guard settings.autoOpenThreeWayMerge else {
            showConflictsNotice(title, note: note)
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let out = (try? await Git.runString(["diff", "--name-only", "--diff-filter=U", "-z"], in: project.url)) ?? ""
            let paths = out.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !paths.isEmpty {
                project.lastConflictSignature = "\(project.status.operation?.rawValue ?? "")|\(project.status.headOID ?? "")|" + paths.joined(separator: "\n")
                self.openThreeWayMerge(in: project, paths: paths, automatic: true)
                self.showToast(title)
            } else {
                self.showConflictsNotice(title, note: note)
            }
        }
    }

    func requestCloseMergeSession(confirmed: Bool = false) {
        guard let session = mergeSession else { return }
        if !confirmed, session.hasUnsavedChanges {
            var request = DialogRequest(
                style: .caution,
                symbol: "exclamationmark.triangle",
                title: L("Discard unsaved merge edits?", "放弃未应用的合并编辑？"),
                message: L("Changes made in the 3-way merge viewer have not been applied to the working tree yet.",
                           "三方合并视图中的修改还没有应用到工作区文件。"),
                confirmTitle: L("Discard & Close", "放弃并关闭")
            )
            request.onConfirm = { [weak self] in
                self?.closeMergeSession(rememberDismissal: true)
            }
            ask(request)
            return
        }
        closeMergeSession(rememberDismissal: true)
    }

    func closeMergeSession(rememberDismissal: Bool) {
        guard let session = mergeSession else { return }
        if rememberDismissal {
            session.project.dismissedConflictSignature = session.project.status.conflictSignature
                ?? session.project.lastConflictSignature
        }
        session.release()
        mergeSession = nil
        viewer.focusCanvas()
    }
}
