import AppKit

/// Tracks the live document currently synchronized with `LSPManager`.
struct ActiveLSPDocument: Equatable {
    let fileURL: URL
    let language: LanguageSpec
    let repoRoot: URL?
    var version: Int

    static func == (lhs: ActiveLSPDocument, rhs: ActiveLSPDocument) -> Bool {
        lhs.fileURL == rhs.fileURL
            && lhs.language === rhs.language
            && lhs.repoRoot == rhs.repoRoot
            && lhs.version == rhs.version
    }
}

/// Async LSP document synchronization and semantic highlighting overlay for `ViewerModel`.
///
/// Only active on live workspace files (single-file / external read-only browsing and working-tree
/// right pane) and gated on `AppEnvironment.hasLSP`. Historical commit diffs and the HEAD left pane
/// never attach to LSP.
///
/// All document lifecycle notifications (`didClose`, `didOpen`, `didChange`, `didSave`) are chained
/// sequentially through `lspTask` so rapid switches (e.g. `A -> B -> A` via `⌘[`) can never deliver
/// a stale `didClose(A)` after the newer `didOpen(A)`.
extension ViewerModel {
    /// Debounce delay after keystrokes before sending `didChange` and refreshing semantic tokens.
    static let lspChangeDelay: TimeInterval = 0.18

    /// Whether the currently displayed document is eligible for LSP semantic tokens and `⌘+Click` navigation.
    var isCurrentDocumentLSPEnabled: Bool {
        guard AppEnvironment.hasLSP,
              let request,
              let doc = document,
              case .text = doc.content,
              request.isLiveFile,
              LSPServerRegistry.descriptor(for: doc.language) != nil else {
            return false
        }
        return true
    }

    /// Synchronizes LSP document state whenever a new document is applied in the viewer.
    func syncLSPForCurrentDocument() {
        let enabled = isCurrentDocumentLSPEnabled
        container?.canvas.isLSPEnabled = enabled

        guard enabled, let request, let doc = document else {
            closeLSPDocument()
            return
        }

        let fileURL = LSPURI.canonicalFileURL(request.fileURL)
        let repoRoot = request.lspRepoRoot.map { LSPURI.canonicalFileURL($0) }
        let previousURL = lspDocument.flatMap { $0.fileURL != fileURL ? $0.fileURL : nil }

        lspDebounceTimer?.invalidate()
        lspDebounceTimer = nil
        let previousTask = lspTask
        previousTask?.cancel()
        lspGeneration &+= 1
        let gen = lspGeneration

        let nextVersion: Int
        if let previous = lspDocument, previous.fileURL == fileURL {
            nextVersion = previous.version + 1
        } else {
            nextVersion = 1
        }

        let active = ActiveLSPDocument(fileURL: fileURL, language: doc.language, repoRoot: repoRoot, version: nextVersion)
        lspDocument = active
        let text = doc.right.lines.joined(separator: "\n")
        let manager = lspManager

        lspTask = Task { @MainActor [weak self, weak doc] in
            await previousTask?.value
            if let oldURL = previousURL {
                await manager.didClose(fileURL: oldURL)
            }
            guard let self, let doc, !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            await manager.didOpen(
                fileURL: fileURL,
                text: text,
                version: nextVersion,
                language: doc.language,
                repoRoot: repoRoot
            )
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            guard let tokens = await manager.semanticTokens(fileURL: fileURL) else { return }
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            let changed = doc.right.applySemanticTokens(tokens)
            if !changed.isEmpty {
                self.container?.canvas.invalidateSyntax(side: .right, lines: changed)
            }
        }
    }

    /// Closes any active LSP document and cancels pending semantic token fetches in FIFO order.
    func closeLSPDocument() {
        lspDebounceTimer?.invalidate()
        lspDebounceTimer = nil
        let previousTask = lspTask
        previousTask?.cancel()
        lspGeneration &+= 1
        if let active = lspDocument {
            lspDocument = nil
            let oldURL = active.fileURL
            let manager = lspManager
            lspTask = Task { @MainActor in
                await previousTask?.value
                await manager.didClose(fileURL: oldURL)
            }
        } else {
            lspTask = nil
        }
    }

    /// Schedules a debounced `didChange` + `semanticTokens` refresh after an edit.
    func scheduleLSPChange() {
        guard AppEnvironment.hasLSP, lspDocument != nil, document != nil else { return }
        lspDebounceTimer?.invalidate()
        let timer = Timer(timeInterval: Self.lspChangeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lspDebounceTimer = nil
                if self.editor?.marked != nil {
                    self.scheduleLSPChange()
                    return
                }
                self.pushLSPChangeAndRefreshTokens()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        lspDebounceTimer = timer
    }

    /// Immediately flushes any pending debounced `didChange` notification (e.g. before `definition`).
    func flushLSPChangeIfNeeded() async {
        if lspDebounceTimer == nil {
            await lspTask?.value
            return
        }
        lspDebounceTimer?.invalidate()
        lspDebounceTimer = nil
        guard var active = lspDocument, let doc = document, case .text = doc.content else { return }
        active.version += 1
        lspDocument = active
        let text = doc.right.lines.joined(separator: "\n")
        let previousTask = lspTask
        previousTask?.cancel()
        let manager = lspManager
        let flushTask = Task { @MainActor in
            await previousTask?.value
            await manager.didChange(fileURL: active.fileURL, version: active.version, text: text)
        }
        lspTask = flushTask
        await flushTask.value
    }

    /// Notifies LSP that the active document was saved to disk, flushing any pending change first.
    func notifyLSPSaved() {
        guard AppEnvironment.hasLSP, let active = lspDocument, let doc = document, case .text = doc.content else { return }
        let hadPendingChange = lspDebounceTimer != nil
        lspDebounceTimer?.invalidate()
        lspDebounceTimer = nil

        var updated = active
        if hadPendingChange {
            updated.version += 1
            lspDocument = updated
        }
        let previousTask = lspTask
        previousTask?.cancel()
        lspGeneration &+= 1
        let gen = lspGeneration
        let text = doc.right.lines.joined(separator: "\n")
        let fileURL = updated.fileURL
        let version = updated.version
        let manager = lspManager

        lspTask = Task { @MainActor [weak self, weak doc] in
            await previousTask?.value
            guard let self, let doc, !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            if hadPendingChange {
                await manager.didChange(fileURL: fileURL, version: version, text: text)
            }
            await manager.didSave(fileURL: fileURL, text: text)
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            guard let tokens = await manager.semanticTokens(fileURL: fileURL) else { return }
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            let changed = doc.right.applySemanticTokens(tokens)
            if !changed.isEmpty {
                self.container?.canvas.invalidateSyntax(side: .right, lines: changed)
            }
        }
    }

    private func pushLSPChangeAndRefreshTokens() {
        guard AppEnvironment.hasLSP, var active = lspDocument, let doc = document, case .text = doc.content else { return }
        active.version += 1
        lspDocument = active
        let previousTask = lspTask
        previousTask?.cancel()
        lspGeneration &+= 1
        let gen = lspGeneration
        let text = doc.right.lines.joined(separator: "\n")
        let fileURL = active.fileURL
        let version = active.version
        let manager = lspManager

        lspTask = Task { @MainActor [weak self, weak doc] in
            await previousTask?.value
            guard let self, let doc, !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            await manager.didChange(fileURL: fileURL, version: version, text: text)
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            guard let tokens = await manager.semanticTokens(fileURL: fileURL) else { return }
            guard !Task.isCancelled, self.lspGeneration == gen, self.document === doc else { return }
            let changed = doc.right.applySemanticTokens(tokens)
            if !changed.isEmpty {
                self.container?.canvas.invalidateSyntax(side: .right, lines: changed)
            }
        }
    }
}
