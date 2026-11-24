import Foundation

/// Coordinates per-workspace LSP server processes, document synchronization,
/// semantic token decoding, go-to-definition queries, and idle server reaping.
actor LSPManager {
    /// Shared app-wide manager (enabled in Direct edition, disabled in sandboxed App Store edition).
    static let shared = LSPManager(respectsEdition: true)

    private struct ServerKey: Hashable, Sendable {
        let serverID: String
        let rootPath: String
    }

    private struct ServerInstance {
        let key: ServerKey
        let descriptor: LSPServerDescriptor
        let workspace: LSPWorkspaceContext
        let transport: LSPTransport
        let capabilities: LSPServerCapabilities
        var lastActivity: ContinuousClock.Instant
        var openDocuments: [String: LSPDocumentSession]
    }

    /// Global gating flag. Defaults to `AppEnvironment.hasLSP` (`true` in Direct edition, `false` in App Store edition).
    private(set) var isEnabled: Bool
    private let respectsEdition: Bool
    private var idleTimeout: Duration?
    private let serverOverrides: [String: LSPResolvedServer]

    private struct PendingStart {
        let id: UUID
        let task: Task<ServerInstance?, Never>
    }

    private var servers: [ServerKey: ServerInstance] = [:]
    private var starting: [ServerKey: PendingStart] = [:]
    private var unavailableServerIDs: Set<String> = []
    private var documentToServer: [String: ServerKey] = [:]
    private var reaperTask: Task<Void, Never>?

    init(
        isEnabled: Bool = AppEnvironment.hasLSP,
        idleTimeout: Duration? = .seconds(300),
        serverOverrides: [String: LSPResolvedServer] = [:],
        respectsEdition: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.respectsEdition = respectsEdition
        self.idleTimeout = idleTimeout
        self.serverOverrides = serverOverrides
    }

    /// Effective runtime enablement: `LSPManager.shared` also respects `AppEnvironment.hasLSP` dynamically
    /// so the sandboxed App Store edition can never spawn language server processes.
    var isEffectivelyEnabled: Bool {
        isEnabled && (!respectsEdition || AppEnvironment.hasLSP)
    }

    /// Enables or disables LSP support at runtime. Disabling immediately shuts down all running servers.
    func setEnabled(_ enabled: Bool) async {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            await shutdownAll()
        }
    }

    /// Returns the current idle release timeout (`nil` disables automatic shutdown).
    func currentIdleTimeout() -> Duration? {
        idleTimeout
    }

    /// Updates the idle release timeout at runtime (`nil` keeps idle servers alive until quit).
    func setIdleTimeout(_ timeout: Duration?) async {
        guard idleTimeout != timeout else { return }
        idleTimeout = timeout
        reaperTask?.cancel()
        reaperTask = nil
        guard timeout != nil, !servers.isEmpty else { return }
        let stillHasServers = await reapIdleServers()
        if stillHasServers {
            ensureReaperRunning()
        }
    }

    /// Clears the negative binary-availability cache (e.g. after a user installs an LSP server).
    func resetAvailabilityCache() {
        unavailableServerIDs.removeAll()
        LSPBinaryLocator.resetCache()
    }

    /// Number of currently live LSP server processes managed by this instance.
    func runningServerCount() -> Int {
        servers.count
    }

    /// Returns whether an LSP server binary is configured and installed for `language`.
    func isServerAvailable(for language: LanguageSpec) -> Bool {
        guard isEffectivelyEnabled, let descriptor = LSPServerRegistry.descriptor(for: language) else { return false }
        if serverOverrides[descriptor.id] != nil { return true }
        if unavailableServerIDs.contains(descriptor.id) { return false }
        return LSPServerRegistry.resolveServer(for: descriptor) != nil
    }

    /// Returns the capabilities of the server currently owning `uri`, if one is running.
    func capabilities(forURI uri: String) -> LSPServerCapabilities? {
        let normalized = LSPURI.normalize(uri)
        guard let key = documentToServer[normalized] else { return nil }
        return servers[key]?.capabilities
    }

    /// Returns the currently tracked document session for `uri`, if open.
    func openSession(forURI uri: String) -> LSPDocumentSession? {
        let normalized = LSPURI.normalize(uri)
        guard let key = documentToServer[normalized] else { return nil }
        return servers[key]?.openDocuments[normalized]
    }

    /// Returns captured trailing stderr output for the server currently owning `uri`, if running.
    func recentStderr(forURI uri: String) async -> String? {
        let normalized = LSPURI.normalize(uri)
        guard let key = documentToServer[normalized],
              let server = servers[key] else { return nil }
        return await server.transport.recentStderr()
    }

    /// Convenience `fileURL` overload for `recentStderr`.
    func recentStderr(forFileURL fileURL: URL) async -> String? {
        await recentStderr(forURI: LSPURI.uri(from: fileURL))
    }

    // MARK: - Workspace Queries (UI Helpers)

    /// Returns all workspace / member roots associated with `fileURL` (including all `go.work` repos).
    nonisolated func workspaceRoots(for fileURL: URL, repoRoot: URL? = nil) -> [URL] {
        GoWorkspaceResolver.workspaceRoots(for: fileURL, repoRoot: repoRoot)
    }

    /// Returns the repository/module root containing a definition jump target `targetURL`,
    /// allowing the UI to detect cross-repo jumps inside a `go.work` workspace.
    nonisolated func containingRepoRoot(for targetURL: URL, relativeTo fileURL: URL, repoRoot: URL? = nil) -> URL? {
        GoWorkspaceResolver.containingRepoRoot(for: targetURL, relativeTo: fileURL, repoRoot: repoRoot)
    }

    /// Returns discovered `go.work` workspace info for `fileURL`/`repoRoot`, if any.
    nonisolated func goWorkspace(for fileURL: URL, repoRoot: URL? = nil) -> GoWorkspaceInfo? {
        GoWorkspaceResolver.resolve(for: fileURL, repoRoot: repoRoot)
    }

    // MARK: - Document Lifecycle

    /// Opens (or updates if already open) a document in the appropriate LSP server.
    func didOpen(
        uri: String,
        languageId: String,
        version: Int,
        text: String,
        workspaceRoot: URL? = nil,
        isPinned: Bool = true
    ) async {
        guard isEffectivelyEnabled else { return }
        guard let fileURL = LSPURI.fileURL(from: uri) else { return }
        let normalizedURI = LSPURI.uri(from: fileURL)

        let descriptor = LSPServerRegistry.descriptor(forLanguageID: languageId)
            ?? LSPServerRegistry.descriptor(for: LanguageSpec.detect(path: fileURL.path))
        guard let descriptor else { return }

        let workspace = LSPWorkspaceResolver.resolve(fileURL: fileURL, descriptor: descriptor, repoRoot: workspaceRoot)
        guard !Task.isCancelled else { return }
        guard let server = await ensureServer(descriptor: descriptor, workspace: workspace) else { return }
        let key = server.key
        guard !Task.isCancelled, isEffectivelyEnabled, servers[key] != nil else { return }

        // If already open on the same server, send didChange (or close+reopen if language changed)
        // because LSP servers such as gopls reject duplicate didOpen notifications and ignore
        // didChange notifications whose version is <= the last seen version.
        if let existingKey = documentToServer[normalizedURI], existingKey == key,
           let existing = servers[key]?.openDocuments[normalizedURI] {
            if existing.languageID == languageId {
                if isPinned {
                    servers[key]?.openDocuments[normalizedURI]?.isPinned = true
                }
                let monotonicVersion = max(version, existing.version + 1)
                await didChange(uri: normalizedURI, version: monotonicVersion, text: text)
                return
            } else {
                await didClose(uri: normalizedURI)
            }
        } else if documentToServer[normalizedURI] != nil {
            await didClose(uri: normalizedURI)
        }

        let params: JSONValue = .object([
            "textDocument": .object([
                "uri": .string(normalizedURI),
                "languageId": .string(languageId),
                "version": .int(version),
                "text": .string(text),
            ]),
        ])

        do {
            try await server.transport.notify(method: "textDocument/didOpen", params: params)
            let session = LSPDocumentSession(
                uri: normalizedURI,
                fileURL: fileURL,
                languageID: languageId,
                version: version,
                workspaceRoot: workspace.rootURL,
                isPinned: isPinned
            )
            servers[key]?.openDocuments[normalizedURI] = session
            servers[key]?.lastActivity = .now
            documentToServer[normalizedURI] = key
        } catch {
            // Transport died mid-write; exit handler will clean up.
        }
    }

    /// Convenience overload taking a local `fileURL` and optional `LanguageSpec`/`repoRoot`.
    @discardableResult
    func didOpen(
        fileURL: URL,
        text: String,
        version: Int = 1,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil,
        isPinned: Bool = true
    ) async -> LSPDocumentSession? {
        let uri = LSPURI.uri(from: fileURL)
        let langID = LSPServerRegistry.languageID(for: fileURL, language: language)
        await didOpen(uri: uri, languageId: langID, version: version, text: text, workspaceRoot: repoRoot, isPinned: isPinned)
        return openSession(forURI: uri)
    }

    /// Sends a full-document `textDocument/didChange` notification for an open document.
    /// If the document is not currently open (e.g. server restarted or an earlier `didOpen` was skipped),
    /// automatically opens it with `text` instead of dropping the update.
    func didChange(
        uri: String,
        version: Int,
        text: String,
        languageId: String? = nil,
        workspaceRoot: URL? = nil
    ) async {
        guard isEffectivelyEnabled else { return }
        let normalizedURI = LSPURI.normalize(uri)
        guard let key = documentToServer[normalizedURI],
              let server = servers[key] else {
            if let fileURL = LSPURI.fileURL(from: normalizedURI) {
                let resolvedLangID = languageId ?? LSPServerRegistry.languageID(for: fileURL, language: nil)
                await didOpen(
                    uri: normalizedURI,
                    languageId: resolvedLangID,
                    version: max(1, version),
                    text: text,
                    workspaceRoot: workspaceRoot
                )
            }
            return
        }

        guard server.capabilities.textDocumentSync != .none else { return }

        let effectiveVersion: Int
        if let existing = server.openDocuments[normalizedURI] {
            effectiveVersion = max(version, existing.version + 1)
        } else {
            effectiveVersion = max(1, version)
        }

        let params: JSONValue = .object([
            "textDocument": .object([
                "uri": .string(normalizedURI),
                "version": .int(effectiveVersion),
            ]),
            "contentChanges": .array([
                .object(["text": .string(text)]),
            ]),
        ])

        do {
            try await server.transport.notify(method: "textDocument/didChange", params: params)
            servers[key]?.openDocuments[normalizedURI]?.version = effectiveVersion
            servers[key]?.lastActivity = .now
        } catch {
            // Ignore write failure on dying transport.
        }
    }

    /// Convenience `fileURL` overload for `didChange`.
    func didChange(
        fileURL: URL,
        version: Int,
        text: String,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async {
        let langID = language.map { LSPServerRegistry.languageID(for: fileURL, language: $0) }
        await didChange(
            uri: LSPURI.uri(from: fileURL),
            version: version,
            text: text,
            languageId: langID,
            workspaceRoot: repoRoot
        )
    }

    /// Sends a `textDocument/didSave` notification for an open document, auto-reopening it first if needed.
    func didSave(
        uri: String,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async {
        guard isEffectivelyEnabled else { return }
        let normalizedURI = LSPURI.normalize(uri)
        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot,
            isPinnedOnAutoOpen: true
        ) else { return }

        var payload: [String: JSONValue] = [
            "textDocument": .object(["uri": .string(normalizedURI)]),
        ]
        if let text {
            payload["text"] = .string(text)
        }

        do {
            try await server.transport.notify(method: "textDocument/didSave", params: .object(payload))
            servers[key]?.lastActivity = .now
        } catch {
            // Ignore write failure on dying transport.
        }
    }

    /// Convenience `fileURL` overload for `didSave`.
    func didSave(
        fileURL: URL,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async {
        await didSave(uri: LSPURI.uri(from: fileURL), text: text, language: language, workspaceRoot: repoRoot)
    }

    /// Sends `textDocument/didClose` and removes document tracking.
    func didClose(uri: String) async {
        let normalizedURI = LSPURI.normalize(uri)
        guard let key = documentToServer.removeValue(forKey: normalizedURI) else { return }
        // Stamp lastActivity before unpinning and before awaiting notify so a concurrent reaper tick
        // always starts the idle countdown from the close/switch-away instant.
        servers[key]?.lastActivity = .now
        servers[key]?.openDocuments.removeValue(forKey: normalizedURI)
        guard let server = servers[key] else { return }

        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
        ])
        try? await server.transport.notify(method: "textDocument/didClose", params: params)
        servers[key]?.lastActivity = .now
        ensureReaperRunning()
    }

    /// Convenience `fileURL` overload for `didClose`.
    func didClose(fileURL: URL) async {
        await didClose(uri: LSPURI.uri(from: fileURL))
    }

    // MARK: - Semantic Tokens & Definition

    /// Requests full semantic tokens for an open document and decodes them into per-line spans.
    func semanticTokens(uri: String) async -> [Int: [LSPSemanticSpan]]? {
        guard isEffectivelyEnabled else { return nil }
        let normalizedURI = LSPURI.normalize(uri)
        guard let key = documentToServer[normalizedURI],
              let server = servers[key],
              server.capabilities.semanticTokensFull,
              let legend = server.capabilities.semanticTokensLegend else {
            return nil
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/semanticTokens/full",
                params: params,
                timeout: .seconds(15)
            )
            servers[key]?.lastActivity = .now
            guard let rawData = response["data"]?.arrayValue else { return nil }
            let ints = rawData.compactMap(\.intValue)
            return LSPSemanticTokensDecoder.decode(data: ints, legend: legend)
        } catch {
            return nil
        }
    }

    /// Convenience `fileURL` overload for `semanticTokens`.
    func semanticTokens(fileURL: URL) async -> [Int: [LSPSemanticSpan]]? {
        await semanticTokens(uri: LSPURI.uri(from: fileURL))
    }

    /// Ensures `normalizedURI` has an open document session on a running LSP server, auto-reopening it
    /// from `text` or disk if the server restarted, was idle-reaped, or an earlier `didOpen` never ran.
    private func ensureDocumentOpen(
        normalizedURI: String,
        text: String?,
        language: LanguageSpec?,
        workspaceRoot: URL?,
        isPinnedOnAutoOpen: Bool = false
    ) async -> (key: ServerKey, server: ServerInstance)? {
        if let key = documentToServer[normalizedURI],
           let server = servers[key] {
            if await server.transport.isRunning {
                return (key, server)
            } else {
                evictServer(key: key)
            }
        }
        guard let fileURL = LSPURI.fileURL(from: normalizedURI) else { return nil }
        let resolvedText: String
        if let text {
            resolvedText = text
        } else if let data = try? Data(contentsOf: fileURL) {
            resolvedText = TextCodec.decode(data)
        } else {
            return nil
        }
        let langID = LSPServerRegistry.languageID(for: fileURL, language: language)
        await didOpen(
            uri: normalizedURI,
            languageId: langID,
            version: 1,
            text: resolvedText,
            workspaceRoot: workspaceRoot,
            isPinned: isPinnedOnAutoOpen
        )
        guard let key = documentToServer[normalizedURI],
              let server = servers[key] else {
            return nil
        }
        return (key, server)
    }

    /// Resolves `textDocument/definition` at a 0-based `(line, character)` UTF-16 position.
    func definition(
        uri: String,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> [LSPLocation] {
        guard isEffectivelyEnabled else { return [] }
        let normalizedURI = LSPURI.normalize(uri)
        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) else {
            return []
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
            "position": .object([
                "line": .int(line),
                "character": .int(character),
            ]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/definition",
                params: params,
                timeout: .seconds(10)
            )
            servers[key]?.lastActivity = .now
            return LSPDefinitionDecoder.decode(from: response)
        } catch {
            return []
        }
    }

    /// Convenience `fileURL` overload for `definition`.
    func definition(
        fileURL: URL,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> [LSPLocation] {
        await definition(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Resolves `textDocument/implementation` at a 0-based `(line, character)` UTF-16 position.
    func implementation(
        uri: String,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> [LSPLocation] {
        guard isEffectivelyEnabled else { return [] }
        let normalizedURI = LSPURI.normalize(uri)
        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) else {
            return []
        }
        guard server.capabilities.implementationProvider else {
            return []
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
            "position": .object([
                "line": .int(line),
                "character": .int(character),
            ]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/implementation",
                params: params,
                timeout: .seconds(15)
            )
            servers[key]?.lastActivity = .now
            let decoded = LSPDefinitionDecoder.decode(from: response)
            return Self.deduplicateLocations(decoded)
        } catch {
            return []
        }
    }

    /// Convenience `fileURL` overload for `implementation`.
    func implementation(
        fileURL: URL,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> [LSPLocation] {
        await implementation(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Resolves `textDocument/typeDefinition` at a 0-based `(line, character)` UTF-16 position.
    func typeDefinition(
        uri: String,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> [LSPLocation] {
        guard isEffectivelyEnabled else { return [] }
        let normalizedURI = LSPURI.normalize(uri)
        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) else {
            return []
        }
        guard server.capabilities.typeDefinitionProvider else {
            return []
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
            "position": .object([
                "line": .int(line),
                "character": .int(character),
            ]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/typeDefinition",
                params: params,
                timeout: .seconds(10)
            )
            servers[key]?.lastActivity = .now
            let decoded = LSPDefinitionDecoder.decode(from: response)
            return Self.deduplicateLocations(decoded)
        } catch {
            return []
        }
    }

    /// Convenience `fileURL` overload for `typeDefinition`.
    func typeDefinition(
        fileURL: URL,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> [LSPLocation] {
        await typeDefinition(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Resolves `textDocument/references` at a 0-based `(line, character)` UTF-16 position.
    func references(
        uri: String,
        line: Int,
        character: Int,
        includeDeclaration: Bool = true,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> [LSPLocation] {
        guard isEffectivelyEnabled else { return [] }
        let normalizedURI = LSPURI.normalize(uri)
        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) else {
            return []
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
            "position": .object([
                "line": .int(line),
                "character": .int(character),
            ]),
            "context": .object([
                "includeDeclaration": .bool(includeDeclaration),
            ]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/references",
                params: params,
                timeout: .seconds(15)
            )
            servers[key]?.lastActivity = .now
            let decoded = LSPDefinitionDecoder.decode(from: response)
            return Self.deduplicateLocations(decoded)
        } catch {
            return []
        }
    }

    /// Convenience `fileURL` overload for `references`.
    func references(
        fileURL: URL,
        line: Int,
        character: Int,
        includeDeclaration: Bool = true,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> [LSPLocation] {
        await references(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            includeDeclaration: includeDeclaration,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Resolves `textDocument/documentHighlight` at a 0-based `(line, character)` UTF-16 position,
    /// distinguishing valid highlights from unavailability (`unavailable`) vs transient RPC failure/timeout (`failed`).
    func documentHighlightResult(
        uri: String,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> LSPDocumentHighlightResult {
        guard isEffectivelyEnabled else { return .unavailable }
        let normalizedURI = LSPURI.normalize(uri)
        let fileURL = LSPURI.fileURL(from: normalizedURI)
        let descriptor = language.flatMap { LSPServerRegistry.descriptor(for: $0) }
            ?? fileURL.flatMap { LSPServerRegistry.descriptor(for: LanguageSpec.detect(path: $0.path)) }
        guard let descriptor else { return .unavailable }
        if serverOverrides[descriptor.id] == nil, unavailableServerIDs.contains(descriptor.id) {
            return .unavailable
        }

        guard let (key, server) = await ensureDocumentOpen(
            normalizedURI: normalizedURI,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) else {
            return unavailableServerIDs.contains(descriptor.id) ? .unavailable : .failed
        }
        guard server.capabilities.documentHighlightProvider else {
            return .unavailable
        }

        servers[key]?.lastActivity = .now
        let params: JSONValue = .object([
            "textDocument": .object(["uri": .string(normalizedURI)]),
            "position": .object([
                "line": .int(line),
                "character": .int(character),
            ]),
        ])

        do {
            let response = try await server.transport.request(
                method: "textDocument/documentHighlight",
                params: params,
                timeout: .seconds(10)
            )
            servers[key]?.lastActivity = .now
            return .highlights(LSPDocumentHighlightDecoder.decode(from: response))
        } catch {
            return .failed
        }
    }

    /// Convenience `fileURL` overload for `documentHighlightResult`.
    func documentHighlightResult(
        fileURL: URL,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> LSPDocumentHighlightResult {
        await documentHighlightResult(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Resolves `textDocument/documentHighlight` at a 0-based `(line, character)` UTF-16 position.
    func documentHighlight(
        uri: String,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        workspaceRoot: URL? = nil
    ) async -> [LSPDocumentHighlight] {
        switch await documentHighlightResult(
            uri: uri,
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: workspaceRoot
        ) {
        case .highlights(let highlights):
            return highlights
        case .unavailable, .failed:
            return []
        }
    }

    /// Convenience `fileURL` overload for `documentHighlight`.
    func documentHighlight(
        fileURL: URL,
        line: Int,
        character: Int,
        text: String? = nil,
        language: LanguageSpec? = nil,
        repoRoot: URL? = nil
    ) async -> [LSPDocumentHighlight] {
        await documentHighlight(
            uri: LSPURI.uri(from: fileURL),
            line: line,
            character: character,
            text: text,
            language: language,
            workspaceRoot: repoRoot
        )
    }

    /// Deduplicates identical `(canonicalFileURL, range.start.line, range.start.character)` entries
    /// while preserving stable first-seen order.
    nonisolated static func deduplicateLocations(_ locations: [LSPLocation]) -> [LSPLocation] {
        struct Key: Hashable {
            let path: String
            let line: Int
            let character: Int
        }
        var seen: Set<Key> = []
        seen.reserveCapacity(locations.count)
        var result: [LSPLocation] = []
        result.reserveCapacity(locations.count)
        for loc in locations {
            let keyPath = loc.fileURL.map { LSPURI.canonicalFileURL($0).path } ?? LSPURI.normalize(loc.uri)
            let key = Key(path: keyPath, line: loc.range.start.line, character: loc.range.start.character)
            if seen.insert(key).inserted {
                result.append(loc)
            }
        }
        return result
    }

    // MARK: - Shutdown & Idle Reaping

    /// Gracefully shuts down all active LSP server processes and clears internal state.
    func shutdownAll() async {
        reaperTask?.cancel()
        reaperTask = nil

        let inFlight = starting
        starting.removeAll()
        for (_, pending) in inFlight {
            pending.task.cancel()
        }

        let active = servers
        servers.removeAll()
        documentToServer.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for (_, instance) in active {
                group.addTask {
                    await instance.transport.shutdown()
                }
            }
            for (_, pending) in inFlight {
                group.addTask {
                    _ = await pending.task.value
                }
            }
        }
    }

    // MARK: - Server Startup & Initialization

    private func ensureServer(
        descriptor: LSPServerDescriptor,
        workspace: LSPWorkspaceContext
    ) async -> ServerInstance? {
        guard isEffectivelyEnabled else { return nil }
        let key = ServerKey(serverID: descriptor.id, rootPath: workspace.rootURL.path)

        if let existing = servers[key] {
            if await existing.transport.isRunning {
                servers[key]?.lastActivity = .now
                return servers[key]
            } else {
                evictServer(key: key)
            }
        }

        if let pendingStart = starting[key] {
            return await pendingStart.task.value
        }

        if serverOverrides[descriptor.id] == nil && unavailableServerIDs.contains(descriptor.id) {
            return nil
        }

        let startID = UUID()
        let startTask = Task<ServerInstance?, Never> { [weak self] in
            guard let self else { return nil }
            let instance = await self.launchAndInitializeServer(key: key, descriptor: descriptor, workspace: workspace)
            return await self.finishServerStart(key: key, startID: startID, instance: instance)
        }
        starting[key] = PendingStart(id: startID, task: startTask)
        return await startTask.value
    }

    /// Atomically publishes a newly initialized server into `servers[key]` before any waiter resumes,
    /// or tears it down if `shutdownAll()` / disablement superseded this startup.
    private func finishServerStart(
        key: ServerKey,
        startID: UUID,
        instance: ServerInstance?
    ) async -> ServerInstance? {
        let stillCurrent = starting[key]?.id == startID
        if stillCurrent {
            starting.removeValue(forKey: key)
        }
        guard let instance else { return nil }
        guard stillCurrent, !Task.isCancelled, isEffectivelyEnabled else {
            await instance.transport.shutdown()
            return nil
        }
        servers[key] = instance
        ensureReaperRunning()
        return instance
    }

    private func launchAndInitializeServer(
        key: ServerKey,
        descriptor: LSPServerDescriptor,
        workspace: LSPWorkspaceContext
    ) async -> ServerInstance? {
        let resolved: LSPResolvedServer?
        if let override = serverOverrides[descriptor.id] {
            resolved = override
        } else {
            resolved = await Task.detached(priority: .userInitiated) {
                LSPServerRegistry.resolveServer(for: descriptor)
            }.value
        }

        guard let resolved else {
            unavailableServerIDs.insert(descriptor.id)
            return nil
        }

        let configSettings = descriptor.configurationSettings
        let effectiveEnvironment = LSPServerRegistry.mergedEnvironment(
            base: resolved.environment,
            defaults: descriptor.extraEnvironment
        )
        let transport = LSPTransport(
            executable: resolved.executablePath,
            arguments: resolved.arguments,
            environment: effectiveEnvironment,
            workingDirectory: workspace.rootURL,
            onNotification: nil,
            onServerRequest: { method, params in
                LSPTransport.defaultServerRequestResponse(
                    method: method,
                    params: params,
                    configurationSettings: configSettings
                )
            },
            onExit: { [weak self] _ in
                Task { await self?.evictServer(key: key) }
            }
        )

        guard !Task.isCancelled else { return nil }
        do {
            try await transport.start()
        } catch {
            return nil
        }

        guard !Task.isCancelled else {
            await transport.shutdown()
            return nil
        }

        let initParams = Self.buildInitializeParams(descriptor: descriptor, workspace: workspace)
        do {
            let initResult = try await transport.request(
                method: "initialize",
                params: initParams,
                timeout: .seconds(15)
            )
            guard !Task.isCancelled else {
                await transport.shutdown()
                return nil
            }
            let capabilities = LSPServerCapabilities.parse(from: initResult)
            try await transport.notify(method: "initialized", params: .object([:]))
            return ServerInstance(
                key: key,
                descriptor: descriptor,
                workspace: workspace,
                transport: transport,
                capabilities: capabilities,
                lastActivity: .now,
                openDocuments: [:]
            )
        } catch {
            await transport.shutdown()
            return nil
        }
    }

    private static func buildInitializeParams(
        descriptor: LSPServerDescriptor,
        workspace: LSPWorkspaceContext
    ) -> JSONValue {
        let rootURI = LSPURI.uri(from: workspace.rootURL)
        let folders: [JSONValue] = workspace.workspaceFolders.map { folder in
            .object([
                "uri": .string(LSPURI.uri(from: folder)),
                "name": .string(folder.lastPathComponent),
            ])
        }

        var params: [String: JSONValue] = [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": .object([
                "name": .string("DiffCode"),
                "version": .string("1.0"),
            ]),
            "rootPath": .string(workspace.rootURL.path),
            "rootUri": .string(rootURI),
            "workspaceFolders": .array(folders),
            "capabilities": .object([
                "general": .object([
                    "positionEncodings": .array([.string("utf-16")]),
                ]),
                "workspace": .object([
                    "workspaceFolders": .bool(true),
                    "configuration": .bool(true),
                ]),
                "textDocument": .object([
                    "synchronization": .object([
                        "dynamicRegistration": .bool(false),
                        "willSave": .bool(false),
                        "willSaveWaitUntil": .bool(false),
                        "didSave": .bool(true),
                    ]),
                    "definition": .object([
                        "dynamicRegistration": .bool(false),
                        "linkSupport": .bool(true),
                    ]),
                    "typeDefinition": .object([
                        "dynamicRegistration": .bool(false),
                        "linkSupport": .bool(true),
                    ]),
                    "implementation": .object([
                        "dynamicRegistration": .bool(false),
                        "linkSupport": .bool(true),
                    ]),
                    "references": .object([
                        "dynamicRegistration": .bool(false),
                    ]),
                    "documentHighlight": .object([
                        "dynamicRegistration": .bool(false),
                    ]),
                    "semanticTokens": .object([
                        "dynamicRegistration": .bool(false),
                        "requests": .object([
                            "range": .bool(false),
                            "full": .bool(true),
                        ]),
                        "tokenTypes": .array(LSPSemanticTokensLegend.clientTokenTypes.map { .string($0) }),
                        "tokenModifiers": .array(LSPSemanticTokensLegend.clientTokenModifiers.map { .string($0) }),
                        "formats": .array([.string("relative")]),
                        "overlappingTokenSupport": .bool(false),
                        "multilineTokenSupport": .bool(false),
                    ]),
                ]),
            ]),
        ]

        if let initOptions = descriptor.initializationOptions {
            params["initializationOptions"] = initOptions
        }

        return .object(params)
    }

    private func evictServer(key: ServerKey) {
        servers.removeValue(forKey: key)
        documentToServer = documentToServer.filter { $0.value != key }
        if servers.isEmpty {
            reaperTask?.cancel()
            reaperTask = nil
        }
    }

    private func ensureReaperRunning() {
        guard reaperTask == nil, !servers.isEmpty, let idleTimeout else { return }
        let checkInterval = Self.reaperInterval(for: idleTimeout)
        reaperTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: checkInterval)
                guard !Task.isCancelled, let self else { break }
                let stillHasServers = await self.reapIdleServers()
                if !stillHasServers { break }
            }
        }
    }

    private static func reaperInterval(for idleTimeout: Duration) -> Duration {
        let half = idleTimeout / 2
        let maxInterval: Duration = .seconds(30)
        let minInterval: Duration = .milliseconds(50)
        if half > maxInterval { return maxInterval }
        if half < minInterval { return minInterval }
        return half
    }

    private func reapIdleServers() async -> Bool {
        guard let idleTimeout else {
            reaperTask = nil
            return false
        }
        let now = ContinuousClock.now
        var toShutdown: [ServerInstance] = []
        for (key, instance) in servers {
            let hasPinnedDocument = instance.openDocuments.values.contains(where: \.isPinned)
            if !hasPinnedDocument, now - instance.lastActivity >= idleTimeout {
                toShutdown.append(instance)
                evictServer(key: key)
            }
        }
        for instance in toShutdown {
            await instance.transport.shutdown()
        }
        if servers.isEmpty {
            reaperTask = nil
            return false
        }
        return true
    }
}
