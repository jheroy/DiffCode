import Foundation

// MARK: - Server Registry

/// An executable name and command-line arguments for launching an LSP server.
struct LSPServerCommand: Sendable, Equatable, Hashable {
    let executableName: String
    let arguments: [String]
}

/// Static configuration for one language server family.
struct LSPServerDescriptor: Sendable, Equatable, Hashable {
    /// Canonical identifier used as part of `LSPManager`'s server cache key (e.g. `"go"`, `"rust"`).
    let id: String
    /// `LanguageSpec.name` values handled by this server (e.g. `["Go"]`, `["JavaScript", "TypeScript"]`).
    let languageNames: [String]
    /// LSP `languageId` values handled by this server (e.g. `["typescript", "typescriptreact", "javascript"]`).
    let languageIDs: [String]
    /// Candidate executables checked in preference order; the first installed binary wins.
    let candidates: [LSPServerCommand]
    /// Default LSP `languageId` when opening a document.
    let defaultLanguageID: String
    /// Optional `initializationOptions` payload sent in the `initialize` request.
    let initializationOptions: JSONValue?
    /// Optional configuration payload returned for server-to-client `workspace/configuration` requests.
    let configurationSettings: JSONValue?
    /// Default environment variables injected when launching the server if not already set in the user's environment.
    let extraEnvironment: [String: String]

    init(
        id: String,
        languageNames: [String],
        languageIDs: [String],
        candidates: [LSPServerCommand],
        defaultLanguageID: String,
        initializationOptions: JSONValue?,
        configurationSettings: JSONValue?,
        extraEnvironment: [String: String] = [:]
    ) {
        self.id = id
        self.languageNames = languageNames
        self.languageIDs = languageIDs
        self.candidates = candidates
        self.defaultLanguageID = defaultLanguageID
        self.initializationOptions = initializationOptions
        self.configurationSettings = configurationSettings
        self.extraEnvironment = extraEnvironment
    }
}

/// A resolved, ready-to-launch LSP server binary and environment.
struct LSPResolvedServer: Sendable, Equatable, Hashable {
    let descriptor: LSPServerDescriptor
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]
}

/// Built-in mapping from DiffCode `LanguageSpec` names / LSP language IDs to language servers.
enum LSPServerRegistry {
    /// Lightweight `gopls` settings tailored for DiffCode: keeps semantic highlighting, definition,
    /// references, and `go.work` cross-repo navigation intact while disabling unused diagnostics,
    /// analyzers, codelenses, inlay hints, hover docs, and completion extras to minimize RAM/CPU.
    private static let goplsLightweightSettings: JSONValue = .object([
        // gopls disables semantic tokens unless `semanticTokens: true` is explicitly requested.
        "semanticTokens": .bool(true),
        // Avoid workspace-wide diagnostics on every keystroke; only run on save.
        "diagnosticsTrigger": .string("Save"),
        "staticcheck": .bool(false),
        "vulncheck": .string("Off"),
        "analysisProgressReporting": .bool(false),
        "completeFunctionCalls": .bool(false),
        "experimentalPostfixCompletions": .bool(false),
        "hoverKind": .string("NoDocumentation"),
        "linksInHover": .bool(false),
        "hints": .object([:]),
        "codelenses": .object([
            "generate": .bool(false),
            "regenerate_cgo": .bool(false),
            "run_govulncheck": .bool(false),
            "tidy": .bool(false),
            "upgrade_dependency": .bool(false),
            "vendor": .bool(false),
        ]),
        // Explicitly disable all default-on gopls analyzers (`analyses: {"none": true}` is not supported by gopls).
        "analyses": .object([
            "appends": .bool(false),
            "asmdecl": .bool(false),
            "assign": .bool(false),
            "atomic": .bool(false),
            "atomicalign": .bool(false),
            "bools": .bool(false),
            "buildtag": .bool(false),
            "cgocall": .bool(false),
            "composites": .bool(false),
            "copylocks": .bool(false),
            "deepequalerrors": .bool(false),
            "defers": .bool(false),
            "deprecated": .bool(false),
            "directive": .bool(false),
            "embed": .bool(false),
            "errorsas": .bool(false),
            "fillreturns": .bool(false),
            "framepointer": .bool(false),
            "gofix": .bool(false),
            "hostport": .bool(false),
            "httpresponse": .bool(false),
            "ifaceassert": .bool(false),
            "infertypeargs": .bool(false),
            "loopclosure": .bool(false),
            "lostcancel": .bool(false),
            "maprange": .bool(false),
            "modernize": .bool(false),
            "nilfunc": .bool(false),
            "nilness": .bool(false),
            "nonewvars": .bool(false),
            "noresultvalues": .bool(false),
            "printf": .bool(false),
            "recursiveiter": .bool(false),
            "shift": .bool(false),
            "sigchanyzer": .bool(false),
            "simplifycompositelit": .bool(false),
            "simplifyrange": .bool(false),
            "simplifyslice": .bool(false),
            "slog": .bool(false),
            "sortslice": .bool(false),
            "stdmethods": .bool(false),
            "stdversion": .bool(false),
            "stringintconv": .bool(false),
            "structtag": .bool(false),
            "testinggoroutine": .bool(false),
            "tests": .bool(false),
            "timeformat": .bool(false),
            "unmarshal": .bool(false),
            "unreachable": .bool(false),
            "unsafeptr": .bool(false),
            "unusedfunc": .bool(false),
            "unusedparams": .bool(false),
            "unusedresult": .bool(false),
            "unusedvariable": .bool(false),
            "unusedwrite": .bool(false),
            "waitgroup": .bool(false),
            "yield": .bool(false),
        ]),
        "directoryFilters": .array([
            .string("-**/node_modules"),
            .string("-**/.git"),
            .string("-**/dist"),
            .string("-**/build"),
            .string("-**/testdata"),
        ]),
    ])

    static let go = LSPServerDescriptor(
        id: "go",
        languageNames: ["Go"],
        languageIDs: ["go", "gomod", "gowork"],
        // Shared daemon mode (`-remote=auto` must precede subcommand; default subcommand is `serve`).
        // `-remote.listen.timeout=2m` ensures the shared daemon exits promptly once all clients disconnect.
        candidates: [LSPServerCommand(executableName: "gopls", arguments: ["-remote=auto", "-remote.listen.timeout=2m"])],
        defaultLanguageID: "go",
        initializationOptions: goplsLightweightSettings,
        configurationSettings: goplsLightweightSettings,
        extraEnvironment: [
            "GOGC": "50",
            "GOMEMLIMIT": "1GiB",
        ]
    )

    static let rust = LSPServerDescriptor(
        id: "rust",
        languageNames: ["Rust"],
        languageIDs: ["rust"],
        candidates: [LSPServerCommand(executableName: "rust-analyzer", arguments: [])],
        defaultLanguageID: "rust",
        initializationOptions: nil,
        configurationSettings: nil
    )

    static let swift = LSPServerDescriptor(
        id: "swift",
        languageNames: ["Swift"],
        languageIDs: ["swift"],
        candidates: [LSPServerCommand(executableName: "sourcekit-lsp", arguments: [])],
        defaultLanguageID: "swift",
        initializationOptions: nil,
        configurationSettings: nil
    )

    static let typescript = LSPServerDescriptor(
        id: "typescript",
        languageNames: ["JavaScript", "TypeScript"],
        languageIDs: ["typescript", "typescriptreact", "javascript", "javascriptreact"],
        candidates: [LSPServerCommand(executableName: "typescript-language-server", arguments: ["--stdio"])],
        defaultLanguageID: "typescript",
        initializationOptions: nil,
        configurationSettings: nil
    )

    static let python = LSPServerDescriptor(
        id: "python",
        languageNames: ["Python"],
        languageIDs: ["python"],
        candidates: [
            LSPServerCommand(executableName: "basedpyright-langserver", arguments: ["--stdio"]),
            LSPServerCommand(executableName: "pyright-langserver", arguments: ["--stdio"]),
            LSPServerCommand(executableName: "pylsp", arguments: ["--stdio"]),
        ],
        defaultLanguageID: "python",
        initializationOptions: nil,
        configurationSettings: nil
    )

    static let cFamily = LSPServerDescriptor(
        id: "cpp",
        languageNames: ["C/C++", "C", "C++"],
        languageIDs: ["c", "cpp", "objective-c", "objective-cpp"],
        candidates: [LSPServerCommand(executableName: "clangd", arguments: [])],
        defaultLanguageID: "cpp",
        initializationOptions: nil,
        configurationSettings: nil
    )

    static let builtIn: [LSPServerDescriptor] = [go, rust, swift, typescript, python, cFamily]

    static func descriptor(forLanguageName name: String) -> LSPServerDescriptor? {
        builtIn.first { $0.languageNames.contains(name) }
    }

    static func descriptor(for language: LanguageSpec) -> LSPServerDescriptor? {
        descriptor(forLanguageName: language.name)
    }

    static func descriptor(forLanguageID languageID: String) -> LSPServerDescriptor? {
        let lower = languageID.lowercased()
        return builtIn.first { $0.languageIDs.contains(lower) }
    }

    /// Returns the exact LSP `languageId` for a file URL and detected `LanguageSpec`.
    static func languageID(for fileURL: URL, language: LanguageSpec? = nil) -> String {
        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "go": return "go"
        case "rs": return "rust"
        case "swift": return "swift"
        case "ts", "mts", "cts": return "typescript"
        case "tsx": return "typescriptreact"
        case "js", "mjs", "cjs": return "javascript"
        case "jsx": return "javascriptreact"
        case "py", "pyi", "pyw": return "python"
        case "c": return "c"
        case "m": return "objective-c"
        case "mm": return "objective-cpp"
        case "cc", "cpp", "cxx", "hpp", "hh", "hxx", "h", "inl": return "cpp"
        default:
            let spec = language ?? LanguageSpec.detect(path: fileURL.path)
            if let desc = descriptor(for: spec) {
                return desc.defaultLanguageID
            }
            return spec.name.lowercased()
        }
    }

    /// Merges default environment variables into `base` without overriding keys already present in `base`.
    static func mergedEnvironment(
        base: [String: String],
        defaults: [String: String]
    ) -> [String: String] {
        guard !defaults.isEmpty else { return base }
        var merged = base
        for (key, value) in defaults where merged[key] == nil {
            merged[key] = value
        }
        return merged
    }

    /// Resolves the first installed server binary for `descriptor`, or `nil` if none is installed.
    static func resolveServer(
        for descriptor: LSPServerDescriptor,
        searchPaths: [String]? = nil,
        environment: [String: String]? = nil
    ) -> LSPResolvedServer? {
        let baseEnv = environment ?? LSPBinaryLocator.environment()
        let paths = searchPaths ?? LSPBinaryLocator.searchPaths(from: baseEnv)
        let effectiveEnv = mergedEnvironment(base: baseEnv, defaults: descriptor.extraEnvironment)
        for candidate in descriptor.candidates {
            if let binary = LSPBinaryLocator.resolve(executable: candidate.executableName, searchPaths: paths) {
                return LSPResolvedServer(
                    descriptor: descriptor,
                    executablePath: binary,
                    arguments: candidate.arguments,
                    environment: effectiveEnv
                )
            }
        }
        return nil
    }
}

// MARK: - Login-Shell PATH & Binary Locator

/// Locates installed LSP binaries using the user's real login-shell PATH plus common toolchain directories.
enum LSPBinaryLocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedEnvironment: [String: String]?

    private static let envStartMarker = "__DIF_LSP_ENV_START__"
    private static let envEndMarker = "__DIF_LSP_ENV_END__"

    /// Common user and Homebrew toolchain bin directories searched in addition to the shell's PATH.
    static var fallbackDirectories: [String] {
        let home = Sandbox.realHome
        return [
            (home as NSString).appendingPathComponent("go/bin"),
            (home as NSString).appendingPathComponent(".cargo/bin"),
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/go/bin",
            "/usr/bin",
        ]
    }

    /// Returns the child process environment enriched with the user's real login-shell variables and PATH.
    /// Cached after the first probe so subsequent LSP launches pay zero shell startup cost.
    static func environment() -> [String: String] {
        lock.lock()
        if let cached = cachedEnvironment {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = buildEnvironment()

        lock.lock()
        if cachedEnvironment == nil {
            cachedEnvironment = resolved
        }
        let result = cachedEnvironment ?? resolved
        lock.unlock()
        return result
    }

    /// Clears the cached shell environment (e.g. after the user installs a new LSP server or in tests).
    static func resetCache() {
        lock.lock()
        cachedEnvironment = nil
        lock.unlock()
    }

    /// Returns deduplicated executable search directories in priority order.
    static func searchPaths(from environment: [String: String]? = nil) -> [String] {
        let env = environment ?? Self.environment()
        var ordered: [String] = []
        var seen: Set<String> = []

        func appendPath(_ dir: String) {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        if let pathVar = env["PATH"] {
            for entry in pathVar.split(separator: ":") {
                appendPath(String(entry))
            }
        }
        for fallback in fallbackDirectories {
            appendPath(fallback)
        }
        return ordered
    }

    /// Searches `searchPaths` (or the user's resolved PATH) for an executable binary named `executable`.
    static func resolve(executable: String, searchPaths: [String]? = nil) -> String? {
        let fm = FileManager.default
        if executable.contains("/") {
            return fm.isExecutableFile(atPath: executable) ? executable : nil
        }
        let dirs = searchPaths ?? Self.searchPaths()
        for dir in dirs {
            let candidate = (dir as NSString).appendingPathComponent(executable)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue,
               fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    // MARK: Shell Probing

    private static func buildEnvironment() -> [String: String] {
        var env = AppEnvironment.childEnvironment
        if !Sandbox.isActive {
            // Probe interactive login shell first (loads ~/.zprofile + ~/.zshrc, picking up gvm/nvm/pyenv/asdf),
            // falling back to non-interactive login shell if interactive init times out.
            let probed = probeShellEnvironment(interactive: true, timeout: 3.5)
                ?? probeShellEnvironment(interactive: false, timeout: 2.0)
            if let probed {
                for (key, value) in probed where !AppEnvironment.ownProcessOnlyKeys.contains(key) {
                    env[key] = value
                }
            }
        }
        // Guarantee fallback directories are appended to PATH so child tools (e.g. `go` spawned by `gopls`) are found.
        let mergedPaths = searchPaths(from: env)
        env["PATH"] = mergedPaths.joined(separator: ":")
        return env
    }

    private static func probeShellEnvironment(interactive: Bool, timeout: TimeInterval) -> [String: String]? {
        let shellPath = Shell.path
        let shellName = Shell.name
        let command = "printf '\(envStartMarker)'; /usr/bin/env -0; printf '\(envEndMarker)'"

        let args: [String]
        switch shellName {
        case "fish":
            args = ["-l", "-c", command]
        case "zsh", "bash":
            args = interactive ? ["-l", "-i", "-c", command] : ["-l", "-c", command]
        default:
            args = ["-l", "-c", command]
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        var probeEnv = AppEnvironment.childEnvironment
        probeEnv["HOME"] = Sandbox.realHome
        proc.environment = probeEnv

        do {
            try proc.run()
        } catch {
            return nil
        }

        // Drain stdout on a background queue so we can enforce a hard timeout without pipe deadlocks.
        final class OutputBox: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            func set(_ data: Data) { lock.lock(); bytes = data; lock.unlock() }
            func get() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let box = OutputBox()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            box.set(data)
            done.signal()
        }

        let waitResult = done.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            if proc.isRunning { proc.terminate() }
            return nil
        }
        proc.waitUntilExit()
        return parseMarkedNullDelimitedEnv(box.get())
    }

    /// Parses `/usr/bin/env -0` output framed between `envStartMarker` and `envEndMarker`.
    static func parseMarkedNullDelimitedEnv(_ data: Data) -> [String: String]? {
        let startToken = Data(envStartMarker.utf8)
        let endToken = Data(envEndMarker.utf8)
        guard let startRange = data.range(of: startToken),
              let endRange = data.range(of: endToken, in: startRange.upperBound..<data.endIndex) else {
            return nil
        }
        let payload = data[startRange.upperBound..<endRange.lowerBound]
        var env: [String: String] = [:]
        var cursor = payload.startIndex
        while cursor < payload.endIndex {
            let nextNull = payload[cursor...].firstIndex(of: 0) ?? payload.endIndex
            if nextNull > cursor {
                let entryData = payload[cursor..<nextNull]
                let entry = String(decoding: entryData, as: UTF8.self)
                if let eq = entry.firstIndex(of: "=") {
                    let key = String(entry[..<eq])
                    let value = String(entry[entry.index(after: eq)...])
                    if !key.isEmpty {
                        env[key] = value
                    }
                }
            }
            if nextNull == payload.endIndex { break }
            cursor = payload.index(after: nextNull)
        }
        return env.isEmpty ? nil : env
    }
}

// MARK: - go.work Multi-Repo Workspace Discovery

/// Describes a discovered Go multi-module workspace defined by a `go.work` file.
struct GoWorkspaceInfo: Sendable, Equatable, Hashable {
    /// Directory containing `go.work` (canonicalized).
    let rootURL: URL
    /// Resolved directories listed in `use` directives (canonicalized, deduplicated, order preserved).
    let memberRoots: [URL]
    /// Full path to the `go.work` file (canonicalized).
    let goWorkURL: URL

    /// Returns `true` if `url` resides inside any `use` member directory or inside `rootURL` itself.
    func contains(_ url: URL) -> Bool {
        if memberRoots.contains(where: { LSPURI.isPath(url, inside: $0) }) {
            return true
        }
        return LSPURI.isPath(url, inside: rootURL)
    }

    /// Returns the most specific `memberRoot` containing `url`, if any.
    func containingMemberRoot(for url: URL) -> URL? {
        var best: URL?
        for root in memberRoots where LSPURI.isPath(url, inside: root) {
            if let current = best {
                if root.path.count > current.path.count {
                    best = root
                }
            } else {
                best = root
            }
        }
        return best
    }
}

/// Discovers and parses `go.work` workspaces (single-line and block `use` directives)
/// so `gopls` and DiffCode's UI can navigate across multiple repositories seamlessly.
enum GoWorkspaceResolver {
    /// Parses `use` directives in a `go.work` file and resolves each path relative to `baseDirectory`.
    ///
    /// Supports:
    /// - Single-line `use ./modA` and `use "../repo B"` and ``use `./raw path` ``
    /// - Block `use ( ./modA \n ../repoB )` (single-line or multi-line, multiple blocks)
    /// - Line comments (`// ...`) outside strings
    /// - Ignores non-`use` directives (`go`, `toolchain`, `replace (...)`, `godebug`)
    static func parseGoWork(content: String, baseDirectory: URL) -> [URL] {
        let canonicalBase = LSPURI.canonicalFileURL(baseDirectory)
        let lines = tokenizeLines(content)

        var rawPaths: [String] = []
        var mode: BlockMode = .none

        enum BlockMode {
            case none
            case useBlock
            case ignoredBlock
        }

        for tokens in lines {
            guard !tokens.isEmpty else { continue }
            var idx = 0

            if mode == .none {
                guard case .word(let directive) = tokens[0] else { continue }
                idx = 1
                if directive == "use" {
                    if idx < tokens.count, tokens[idx] == .openParen {
                        mode = .useBlock
                        idx += 1
                    } else if idx < tokens.count, let path = tokens[idx].stringContent {
                        rawPaths.append(path)
                        continue
                    } else {
                        continue
                    }
                } else {
                    if tokens.contains(.openParen) && !tokens.contains(.closeParen) {
                        mode = .ignoredBlock
                    }
                    continue
                }
            }

            // Inside either a `use (...)` block or another directive's `(...)` block.
            while idx < tokens.count {
                let token = tokens[idx]
                idx += 1
                if token == .closeParen {
                    mode = .none
                    break
                }
                if mode == .useBlock, let path = token.stringContent {
                    rawPaths.append(path)
                }
            }
        }

        var result: [URL] = []
        var seen: Set<String> = []
        for raw in rawPaths {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let url: URL
            if trimmed.hasPrefix("/") {
                url = URL(fileURLWithPath: trimmed)
            } else {
                url = URL(fileURLWithPath: trimmed, relativeTo: canonicalBase)
            }
            let canonical = LSPURI.canonicalFileURL(url)
            if seen.insert(canonical.path).inserted {
                result.append(canonical)
            }
        }
        return result
    }

    /// Walks upward from `fileURL`'s directory (and `repoRoot`, if provided) to find the nearest
    /// covering `go.work` workspace.
    static func resolve(for fileURL: URL, repoRoot: URL? = nil) -> GoWorkspaceInfo? {
        let canonicalFile = LSPURI.canonicalFileURL(fileURL)
        let canonicalRepo = repoRoot.map { LSPURI.canonicalFileURL($0) }

        let fileDir = directoryURL(for: canonicalFile)
        var candidateDirs: [URL] = []
        var visited: Set<String> = []

        func collectAncestors(startingAt start: URL) {
            var cursor = start
            while true {
                if visited.insert(cursor.path).inserted {
                    candidateDirs.append(cursor)
                }
                let parent = cursor.deletingLastPathComponent().standardizedFileURL
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }

        collectAncestors(startingAt: fileDir)
        if let canonicalRepo {
            collectAncestors(startingAt: directoryURL(for: canonicalRepo))
        }

        let fm = FileManager.default
        for dir in candidateDirs {
            let goWorkURL = dir.appendingPathComponent("go.work")
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: goWorkURL.path, isDirectory: &isDir), !isDir.boolValue,
                  let content = try? String(contentsOf: goWorkURL, encoding: .utf8) else {
                continue
            }
            let memberRoots = parseGoWork(content: content, baseDirectory: dir)
            let info = GoWorkspaceInfo(
                rootURL: LSPURI.canonicalFileURL(dir),
                memberRoots: memberRoots,
                goWorkURL: LSPURI.canonicalFileURL(goWorkURL)
            )
            let coversFile = info.contains(canonicalFile)
            let coversRepo = canonicalRepo.map { info.contains($0) } ?? false
            if coversFile || coversRepo {
                return info
            }
        }
        return nil
    }

    /// Returns the workspace root to initialize `gopls` with:
    /// 1. Covering `go.work` directory, if found
    /// 2. Nearest `go.mod` directory walking upward from `fileURL`
    /// 3. `repoRoot` (or `fileURL`'s parent directory)
    static func workspaceRoot(for fileURL: URL, repoRoot: URL? = nil) -> URL {
        if let info = resolve(for: fileURL, repoRoot: repoRoot) {
            return info.rootURL
        }
        let canonicalFile = LSPURI.canonicalFileURL(fileURL)
        let canonicalRepo = repoRoot.map { LSPURI.canonicalFileURL($0) }
        // When an external file (e.g. $GOROOT or ~/go/pkg/mod) is opened with an explicit Go module `repoRoot`,
        // stay on that origin module root so `gopls` is reused instead of spawning a second server.
        if let canonicalRepo, !LSPURI.isPath(canonicalFile, inside: canonicalRepo) {
            let repoGoMod = canonicalRepo.appendingPathComponent("go.mod").path
            if FileManager.default.fileExists(atPath: repoGoMod) {
                return canonicalRepo
            }
        }
        let boundary = canonicalRepo.flatMap { LSPURI.isPath(canonicalFile, inside: $0) ? $0 : nil }
        if let goModDir = nearestDirectory(containing: "go.mod", from: directoryURL(for: canonicalFile), stoppingAt: boundary) {
            return goModDir
        }
        return canonicalRepo ?? directoryURL(for: canonicalFile)
    }

    /// Returns all workspace roots associated with `fileURL`/`repoRoot` (for UI multi-repo awareness).
    static func workspaceRoots(for fileURL: URL, repoRoot: URL? = nil) -> [URL] {
        if let info = resolve(for: fileURL, repoRoot: repoRoot) {
            var roots: [URL] = []
            var seen: Set<String> = []
            for member in info.memberRoots where seen.insert(member.path).inserted {
                roots.append(member)
            }
            if seen.insert(info.rootURL.path).inserted {
                roots.append(info.rootURL)
            }
            return roots
        }
        return [workspaceRoot(for: fileURL, repoRoot: repoRoot)]
    }

    /// Identifies which repository/module root contains `targetURL` inside a known `GoWorkspaceInfo`.
    static func containingRepoRoot(for targetURL: URL, in workspace: GoWorkspaceInfo) -> URL? {
        if let member = workspace.containingMemberRoot(for: targetURL) {
            return member
        }
        if LSPURI.isPath(targetURL, inside: workspace.rootURL) {
            return workspace.rootURL
        }
        return nil
    }

    /// Identifies which repository/module root contains a definition jump target `targetURL`,
    /// checking the active `go.work` workspace first, then `repoRoot`, then nearest `.git` or `go.mod`.
    static func containingRepoRoot(for targetURL: URL, relativeTo fileURL: URL, repoRoot: URL? = nil) -> URL? {
        let canonicalTarget = LSPURI.canonicalFileURL(targetURL)
        if let info = resolve(for: fileURL, repoRoot: repoRoot),
           let root = containingRepoRoot(for: canonicalTarget, in: info) {
            return root
        }
        if let repoRoot {
            let canonicalRepo = LSPURI.canonicalFileURL(repoRoot)
            if LSPURI.isPath(canonicalTarget, inside: canonicalRepo) {
                return canonicalRepo
            }
        }
        let targetDir = directoryURL(for: canonicalTarget)
        if let gitRoot = nearestDirectory(containing: ".git", from: targetDir, stoppingAt: nil, allowDirectoryEntry: true) {
            return gitRoot
        }
        if let modRoot = nearestDirectory(containing: "go.mod", from: targetDir, stoppingAt: nil) {
            return modRoot
        }
        return nil
    }

    // MARK: Helpers

    fileprivate static func directoryURL(for url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            return isDir.boolValue ? url : url.deletingLastPathComponent().standardizedFileURL
        }
        // Heuristic for not-yet-existing paths: treat paths with an extension as files.
        return url.pathExtension.isEmpty ? url : url.deletingLastPathComponent().standardizedFileURL
    }

    fileprivate static func nearestDirectory(
        containing entryName: String,
        from startDir: URL,
        stoppingAt boundary: URL?,
        allowDirectoryEntry: Bool = false
    ) -> URL? {
        let fm = FileManager.default
        let canonicalBoundary = boundary.map { LSPURI.canonicalFileURL($0) }
        var cursor = LSPURI.canonicalFileURL(startDir)
        while true {
            let candidate = cursor.appendingPathComponent(entryName)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
               allowDirectoryEntry || !isDir.boolValue {
                return cursor
            }
            if let canonicalBoundary, cursor.path == canonicalBoundary.path {
                break
            }
            let parent = cursor.deletingLastPathComponent().standardizedFileURL
            if parent.path == cursor.path { break }
            cursor = parent
        }
        return nil
    }

    // MARK: go.work Lexer

    private enum Token: Equatable {
        case word(String)
        case quoted(String)
        case openParen
        case closeParen

        var stringContent: String? {
            switch self {
            case .word(let s), .quoted(let s): return s
            case .openParen, .closeParen: return nil
            }
        }
    }

    private static func tokenizeLines(_ content: String) -> [[Token]] {
        var result: [[Token]] = []
        var currentLine: [Token] = []
        // Iterate UnicodeScalars so CRLF ("\r\n") is never fused into a single Swift Character.
        let scalars = Array(content.unicodeScalars)
        let n = scalars.count
        var i = 0

        func flushLine() {
            if !currentLine.isEmpty {
                result.append(currentLine)
                currentLine = []
            }
        }

        while i < n {
            let c = scalars[i]
            if c == "\n" {
                flushLine()
                i += 1
                continue
            }
            if c == "\r" || c == " " || c == "\t" {
                i += 1
                continue
            }
            // Line comment `// ...`
            if c == "/", i + 1 < n, scalars[i + 1] == "/" {
                while i < n && scalars[i] != "\n" { i += 1 }
                continue
            }
            if c == "(" {
                currentLine.append(.openParen)
                i += 1
                continue
            }
            if c == ")" {
                currentLine.append(.closeParen)
                i += 1
                continue
            }
            // Double-quoted string with backslash escapes
            if c == "\"" {
                i += 1
                var value = ""
                while i < n && scalars[i] != "\"" && scalars[i] != "\n" {
                    if scalars[i] == "\\", i + 1 < n {
                        i += 1
                        value.unicodeScalars.append(scalars[i])
                    } else {
                        value.unicodeScalars.append(scalars[i])
                    }
                    i += 1
                }
                if i < n && scalars[i] == "\"" { i += 1 }
                currentLine.append(.quoted(value))
                continue
            }
            // Backtick raw string
            if c == "`" {
                i += 1
                var value = ""
                while i < n && scalars[i] != "`" {
                    value.unicodeScalars.append(scalars[i])
                    i += 1
                }
                if i < n && scalars[i] == "`" { i += 1 }
                currentLine.append(.quoted(value))
                continue
            }
            // Bare word
            var word = ""
            while i < n {
                let ch = scalars[i]
                if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "(" || ch == ")" || ch == "\"" || ch == "`" {
                    break
                }
                if ch == "/", i + 1 < n, scalars[i + 1] == "/" {
                    break
                }
                word.unicodeScalars.append(ch)
                i += 1
            }
            if !word.isEmpty {
                currentLine.append(.word(word))
            }
        }
        flushLine()
        return result
    }
}

// MARK: - General Workspace Resolution

/// Resolved workspace root and folders passed during LSP `initialize`.
struct LSPWorkspaceContext: Sendable, Equatable, Hashable {
    let rootURL: URL
    let workspaceFolders: [URL]
    let goWorkspace: GoWorkspaceInfo?
}

/// Resolves the appropriate LSP workspace root & workspace folders for any supported language.
enum LSPWorkspaceResolver {
    static func resolve(
        fileURL: URL,
        descriptor: LSPServerDescriptor,
        repoRoot: URL? = nil
    ) -> LSPWorkspaceContext {
        let canonicalFile = LSPURI.canonicalFileURL(fileURL)
        let canonicalRepo = repoRoot.map { LSPURI.canonicalFileURL($0) }

        if descriptor.id == LSPServerRegistry.go.id {
            if let goWork = GoWorkspaceResolver.resolve(for: canonicalFile, repoRoot: canonicalRepo) {
                // Passing the go.work root in `rootUri` and `workspaceFolders` lets gopls load all `use` modules
                // (including sibling/relative `../other-repo` entries) under one unified workspace view.
                return LSPWorkspaceContext(
                    rootURL: goWork.rootURL,
                    workspaceFolders: [goWork.rootURL],
                    goWorkspace: goWork
                )
            }
            let root = GoWorkspaceResolver.workspaceRoot(for: canonicalFile, repoRoot: canonicalRepo)
            return LSPWorkspaceContext(rootURL: root, workspaceFolders: [root], goWorkspace: nil)
        }

        let startDir = GoWorkspaceResolver.directoryURL(for: canonicalFile)
        let boundary = canonicalRepo.flatMap { LSPURI.isPath(canonicalFile, inside: $0) ? $0 : nil }

        let markerFiles: [String]
        switch descriptor.id {
        case LSPServerRegistry.rust.id:
            markerFiles = ["Cargo.toml"]
        case LSPServerRegistry.swift.id:
            markerFiles = ["Package.swift"]
        case LSPServerRegistry.typescript.id:
            markerFiles = ["tsconfig.json", "jsconfig.json", "package.json"]
        case LSPServerRegistry.python.id:
            markerFiles = ["pyrightconfig.json", "pyproject.toml"]
        case LSPServerRegistry.cFamily.id:
            markerFiles = ["compile_commands.json"]
        default:
            markerFiles = []
        }

        for marker in markerFiles {
            if let found = GoWorkspaceResolver.nearestDirectory(containing: marker, from: startDir, stoppingAt: boundary) {
                return LSPWorkspaceContext(rootURL: found, workspaceFolders: [found], goWorkspace: nil)
            }
        }

        let fallback = canonicalRepo ?? startDir
        return LSPWorkspaceContext(rootURL: fallback, workspaceFolders: [fallback], goWorkspace: nil)
    }
}
