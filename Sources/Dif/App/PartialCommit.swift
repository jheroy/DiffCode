import AppKit

/// Picking the changes, and the lines, of the file on screen that go into the next commit, as with the IDE's
/// checkboxes in the commit diff. Whatever is not picked stays in the working tree for a later commit.
extension AppStore {
    /// The file on screen, when its changes can be picked one by one: a local change against HEAD shown as text,
    /// compared exactly (whitespace too, or a pick could take in changes that are not on screen), outside a merge or rebase.
    func pickableChange(in project: Project) -> (change: FileChange, document: DiffDocument)? {
        guard project.comparison == nil, project.status.operation == nil, let request = viewer.request,
              !request.ignoreWhitespace, !request.semantic.ignoreComments,
              !viewer.isLoading, let change = viewerChange(in: project), change.kind != .conflicted, !change.isSubmodule,
              let document = viewer.document, case .text = document.content, !document.isPlainFile,
              !document.isJSONNormalized, !document.isGroupFiltered, !document.hunks.isEmpty
        else { return nil }
        return (change, document)
    }

    /// Brings the viewer's ticks up to date with what goes into the commit. While a document loads, the one on screen
    /// keeps its ticks until the new one is in.
    func updateCommitTicks() {
        guard let canvas = viewer.container?.canvas, !viewer.isLoading else { return }
        var ticks: CommitTicks?
        if let project = currentProject, let (change, _) = pickableChange(in: project) {
            var value = CommitTicks(included: project.isIncluded(change))
            for line in project.excludedLines[change.path] ?? [] {
                if line.removed { value.removed.insert(line.line) } else { value.added.insert(line.line) }
            }
            ticks = value
        }
        if canvas.commitTicks != ticks { canvas.commitTicks = ticks }
    }

    /// The document on screen changed (opened, edited, read again): the lines left out of it move with their text.
    func viewerDocumentChanged() {
        if let project = currentProject, let (change, document) = pickableChange(in: project),
           let excluded = project.excludedLines[change.path], !excluded.isEmpty {
            let moved = WorkingTree.relocate(excluded, old: document.left.lines, new: document.right.lines, hunks: document.hunks).lines
            if moved != excluded { project.excludedLines[change.path] = moved.isEmpty ? nil : moved }
        }
        updateCommitTicks()
    }

    /// The tick on change `index` was clicked: all of the change goes in, or none of it.
    /// In a file that was not ticked, the change is the only one of the file that goes in.
    func toggleCommitHunk(_ index: Int) {
        guard let project = currentProject, let (change, document) = pickableChange(in: project),
              document.hunks.indices.contains(index) else { return }
        let lines = Self.changeLines(of: [document.hunks[index]], in: document)
        var excluded = project.excludedLines[change.path] ?? []
        if !project.isIncluded(change) {
            excluded = Self.changeLines(of: document.hunks, in: document).subtracting(lines)
        } else if lines.isSubset(of: excluded) {
            excluded.subtract(lines)
        } else {
            excluded.formUnion(lines)
        }
        setExcluded(excluded, for: change, document: document, in: project)
    }

    /// The changed lines among those selected in the viewer, each with the line across from it; nil when the selection
    /// has none. A line and the one across from it are one change: left out together, a modified line stays the way
    /// HEAD has it, rather than losing its old text without getting the new.
    func selectedChangeLines() -> Set<ChangeLine>? {
        guard let project = currentProject, let (_, document) = pickableChange(in: project),
              let canvas = viewer.container?.canvas, canvas.selection?.isEmpty == false else { return nil }
        let left = document.left.lines, right = document.right.lines
        var lines = Set<ChangeLine>()
        for (side, line) in canvas.selectedSourceLines() {
            guard let hunk = document.hunks.first(where: { hunk in
                side == .left ? (hunk.leftStart..<(hunk.leftStart + hunk.leftCount)).contains(line)
                              : (hunk.rightStart..<(hunk.rightStart + hunk.rightCount)).contains(line)
            }) else { continue }
            let offset = line - (side == .left ? hunk.leftStart : hunk.rightStart)
            if offset < hunk.leftCount, hunk.leftStart + offset < left.count {
                lines.insert(ChangeLine(removed: true, line: hunk.leftStart + offset, text: left[hunk.leftStart + offset]))
            }
            if offset < hunk.rightCount, hunk.rightStart + offset < right.count {
                lines.insert(ChangeLine(removed: false, line: hunk.rightStart + offset, text: right[hunk.rightStart + offset]))
            }
        }
        return lines.isEmpty ? nil : lines
    }

    /// Puts the selected changed lines into the commit, or leaves them out of it.
    func setSelectedLines(included: Bool) {
        guard let project = currentProject, let (change, document) = pickableChange(in: project),
              let lines = selectedChangeLines() else { return }
        var excluded = project.isIncluded(change) ? project.excludedLines[change.path] ?? []
                                                  : Self.changeLines(of: document.hunks, in: document)
        if included { excluded.subtract(lines) } else { excluded.formUnion(lines) }
        setExcluded(excluded, for: change, document: document, in: project)
    }

    /// Menu items for picking what of the file on screen goes into the commit: the selected lines, or the change under
    /// the pointer.
    func addCommitPickItems(to menu: NSMenu, project: Project) -> Bool {
        guard let (change, document) = pickableChange(in: project) else { return false }
        let excluded = project.isIncluded(change) ? project.excludedLines[change.path] ?? [] : nil
        func isOut(_ line: ChangeLine) -> Bool { excluded?.contains(line) ?? true }
        if let lines = selectedChangeLines() {
            var added = false
            if lines.contains(where: isOut) {
                menu.addItem(ClosureMenuItem(L("Include Selected Lines in Commit", "提交选中的行")) { [weak self] in
                    self?.setSelectedLines(included: true)
                })
                added = true
            }
            if lines.contains(where: { !isOut($0) }) {
                menu.addItem(ClosureMenuItem(L("Exclude Selected Lines from Commit", "不提交选中的行")) { [weak self] in
                    self?.setSelectedLines(included: false)
                })
                added = true
            }
            return added
        }
        guard let index = viewer.container?.canvas.contextHunk, document.hunks.indices.contains(index) else { return false }
        let lines = Self.changeLines(of: [document.hunks[index]], in: document)
        let goesIn = project.isIncluded(change) && !lines.isSubset(of: excluded ?? [])
        menu.addItem(ClosureMenuItem(goesIn ? L("Exclude This Change from Commit", "不提交这一处变更")
                                            : L("Include This Change in Commit", "提交这一处变更")) { [weak self] in
            self?.toggleCommitHunk(index)
        })
        return true
    }

    /// Records what of a file stays out. With nothing of it left to go in, the file is simply unticked.
    private func setExcluded(_ excluded: Set<ChangeLine>, for change: FileChange, document: DiffDocument, in project: Project) {
        if Self.changeLines(of: document.hunks, in: document).isSubset(of: excluded) {
            project.setIncluded(false, [change])
            return
        }
        if !project.isIncluded(change) { project.setIncluded(true, [change]) }
        let value: Set<ChangeLine>? = excluded.isEmpty ? nil : excluded
        if project.excludedLines[change.path] != value { project.excludedLines[change.path] = value }
    }

    /// Every changed line of `hunks`, on both sides.
    private static func changeLines(of hunks: [Hunk], in document: DiffDocument) -> Set<ChangeLine> {
        let left = document.left.lines, right = document.right.lines
        var lines = Set<ChangeLine>()
        for hunk in hunks {
            for line in hunk.leftStart..<min(hunk.leftStart + hunk.leftCount, left.count) {
                lines.insert(ChangeLine(removed: true, line: line, text: left[line]))
            }
            for line in hunk.rightStart..<min(hunk.rightStart + hunk.rightCount, right.count) {
                lines.insert(ChangeLine(removed: false, line: line, text: right[line]))
            }
        }
        return lines
    }
}
