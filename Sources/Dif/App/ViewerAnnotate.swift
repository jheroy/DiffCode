import AppKit

/// The commit of a line under the pointer in the Annotate column, and where its card goes (the end of the
/// line's label, in the canvas's coordinates).
struct AnnotationHover: Equatable {
    var entry: LineAnnotations.Entry
    var anchor: CGPoint
}

/// Annotate (git blame): who last changed each line of the right side, in a column before its line numbers.
///
/// A mode, like Ignore Whitespace: once on, every file opened is annotated until it is turned off. The blame is
/// read from git in the background; while the text is edited the annotations follow the edits (rewritten lines
/// count as not committed), and each save reads the blame again from the file as written.
extension ViewerModel {
    func toggleAnnotate() {
        annotating.toggle()
        if annotating {
            loadAnnotations(explicit: true)
        } else {
            blameTimer?.invalidate()
            blameTask?.cancel()
            isBlaming = false
            annotationHover = nil
            annotationColumns = nil
            container?.canvas.annotations = nil
        }
    }

    /// Whether the file on screen can be annotated: it has commits, and the side shown exists.
    var canAnnotate: Bool { blameTarget() != nil }

    /// What `git blame` reads for the document on screen: the file in the working tree (rev nil) or in a commit.
    private func blameTarget() -> (path: String, rev: String?)? {
        guard let request, let doc = document, case .text = doc.content, !isLoading else { return nil }
        switch request.source {
        case .file:
            return (request.path, nil)
        case .externalFile:
            return nil
        case .worktree:
            // A file never committed has nothing to tell; one added since the commit compared with may well have.
            if request.kind == .deleted || request.kind == .untracked { return nil }
            if request.isAgainstHead, request.kind == .added { return nil }
            return (request.path, nil)
        case .commit(let hash, _):
            if request.kind == .deleted { return nil }
            return (request.path, hash)
        case .commitSteps(let steps):
            if request.kind == .deleted || doc.isSyntheticReplay { return nil }
            return steps.last.map { ($0.path, $0.hash) }
        }
    }

    /// Reads the blame again a moment after a save, when no more typing follows.
    func scheduleAnnotations() {
        blameTimer?.invalidate()
        let timer = Timer(timeInterval: 0.35, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.loadAnnotations() } }
        RunLoop.main.add(timer, forMode: .common)
        blameTimer = timer
    }

    /// Runs `git blame` for the document on screen and shows the result, unless the text changed meanwhile.
    /// - Parameter explicit: the user just asked; say so when there is nothing to show.
    func loadAnnotations(explicit: Bool = false) {
        blameTimer?.invalidate()
        guard annotating, let request, let canvas = container?.canvas, let doc = document else { return }
        blameTask?.cancel()
        guard let target = blameTarget() else {
            canvas.annotations = nil
            isBlaming = false
            if explicit, request.kind == .untracked || request.kind == .added {
                onToast?(L("Not committed yet · nothing to annotate", "这个文件还没有提交过 · 没有可追溯的记录"))
            }
            return
        }
        // Blame reads the file on disk, so what was typed goes there first.
        if target.rev == nil, editor?.isDirty == true, !saveEdits() { return }
        if canvas.annotations == nil, let columns = annotationColumns {
            canvas.annotations = .placeholder(columns: columns, lineCount: doc.right.lines.count)
        }
        let edits = canvas.editCount
        isBlaming = true
        blameTask = Task { @MainActor [weak self] in
            let started = CACurrentMediaTime()
            let blame = try? await Git.blame(target.path, rev: target.rev, in: request.root)
            guard let self, !Task.isCancelled, self.request == request, self.document === doc,
                  let canvas = self.container?.canvas else { return }
            self.isBlaming = false
            // Typed meanwhile: the annotations already follow the typing, and the next save reads the blame again.
            guard canvas.editCount == edits else { return }
            guard let blame else {
                canvas.annotations = nil
                if explicit { self.onToast?(L("Could not annotate this file", "无法追溯这个文件")) }
                return
            }
            let annotations = LineAnnotations(blame: blame, lineCount: doc.right.lines.count)
            self.annotationColumns = annotations.columns
            canvas.annotations = annotations
            self.blameMilliseconds = (CACurrentMediaTime() - started) * 1000
        }
    }
}
