import Darwin
import Foundation

// MARK: - Public Types

/// Local AI coding agents supported by DiffCode (Direct download edition only).
enum AgentProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case agy
    case claude
    case codex

    var id: String { rawValue }

    /// Human-readable display name shown in UI pickers and status indicators.
    var displayName: String {
        switch self {
        case .agy: return "Antigravity (ACP)"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Primary CLI executable name for this provider.
    var executableName: String { rawValue }

    /// Optional standalone ACP adapter executables checked before falling back to native CLI mode.
    var acpAdapterExecutables: [String] {
        switch self {
        case .agy: return []
        case .claude: return ["claude-agent-acp", "claude-code-acp"]
        case .codex: return ["codex-acp"]
        }
    }
}

/// Transport mechanism used to talk to a local agent.
enum AgentTransportKind: String, Codable, Hashable, Sendable {
    /// Standard Agent Client Protocol (JSON-RPC 2.0 / NDJSON over stdio).
    case acp
    /// Provider-native CLI / protocol adapter.
    case cli
}

/// Controls whether a local agent session may invoke repository inspection tools.
enum AgentToolAccess: Equatable, Hashable, Sendable {
    /// Disallow all tool calls and keep client capabilities empty.
    case disabled
    /// Allow strictly read-only inspection inside the repository (read files, search, read-only git commands).
    case readOnly
}

/// Incremental execution events emitted by live ACP/CLI agent sessions.
enum AgentStreamEvent: Equatable, Sendable {
    case sessionStarted(String)
    case thinkingDelta(String)
    case messageDelta(String)
    case toolActivity(
        id: String,
        title: String,
        kind: String?,
        input: String?,
        status: String?,
        output: String?
    )
    case statusNote(String)
}

/// Result returned by a live or resumable local agent execution turn.
struct AgentGenerateResult: Equatable, Sendable {
    let text: String
    let sessionID: String?
}

/// Streaming callback invoked off the main actor as agent events arrive.
typealias AgentStreamHandler = @Sendable (AgentStreamEvent) -> Void

/// A selectable model reported by a local agent provider.
struct AgentModel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let provider: AgentProvider
    let isDefault: Bool

    init(id: String, name: String, provider: AgentProvider, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.isDefault = isDefault
    }
}

/// Installation and transport status for a local agent provider.
struct AgentAvailability: Identifiable, Hashable, Sendable {
    var id: AgentProvider { provider }
    let provider: AgentProvider
    let isInstalled: Bool
    let executablePath: String?
    let transportKind: AgentTransportKind
}

/// Errors thrown while probing or invoking a local AI agent.
enum LocalAgentError: Error, LocalizedError, Equatable, Sendable {
    case unavailableInAppStore
    case providerNotInstalled(AgentProvider)
    case timedOut(AgentProvider)
    case emptyResponse(AgentProvider)
    case protocolError(provider: AgentProvider, detail: String)
    case executionFailed(provider: AgentProvider, status: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .unavailableInAppStore:
            return L("Local AI agents are unavailable in the Mac App Store edition.",
                     "Mac App Store 版本不支持调用本地 AI Agent。")
        case .providerNotInstalled(let provider):
            return L("\(provider.displayName) CLI (\(provider.executableName)) was not found in PATH.",
                     "未在 PATH 中找到 \(provider.displayName) 命令（\(provider.executableName)），请先安装。")
        case .timedOut(let provider):
            return L("\(provider.displayName) request timed out.",
                     "\(provider.displayName) 请求超时。")
        case .emptyResponse(let provider):
            return L("\(provider.displayName) returned an empty response.",
                     "\(provider.displayName) 返回的内容为空。")
        case .protocolError(let provider, let detail):
            let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 260 ? String(trimmed.prefix(260)) + "…" : trimmed
            if snippet.isEmpty {
                return L("\(provider.displayName) returned a protocol error.",
                         "\(provider.displayName) 协议调用失败。")
            }
            return L("\(provider.displayName) error: \(snippet)",
                     "\(provider.displayName) 错误：\(snippet)")
        case .executionFailed(let provider, let status, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return L("\(provider.displayName) exited with status \(status).",
                         "\(provider.displayName) 异常退出（状态码 \(status)）。")
            }
            let snippet = trimmed.count > 260 ? String(trimmed.prefix(260)) + "…" : trimmed
            return L("\(provider.displayName) failed: \(snippet)",
                     "\(provider.displayName) 执行失败：\(snippet)")
        }
    }
}

// MARK: - Environment & Binary Discovery

/// Enriches login-shell PATH with common agent installation directories and resolves agent binaries.
/// Caches resolved shell environment, search paths, and provider availability at process scope
/// so switching tabs/projects never re-probes the login shell or rescans PATH on the main thread.
enum LocalAgentEnvironment {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedEnvironment: [String: String]?
    nonisolated(unsafe) private static var cachedSearchPaths: [String]?
    nonisolated(unsafe) private static var cachedAvailabilities: [AgentProvider: AgentAvailability] = [:]

    /// Clears process-level environment, search path, and availability caches (used on explicit user refresh or tests).
    static func resetCache() {
        cacheLock.lock()
        cachedEnvironment = nil
        cachedSearchPaths = nil
        cachedAvailabilities.removeAll()
        cacheLock.unlock()
    }

    /// Additional directories commonly used by npm/local agent CLIs beyond `LSPBinaryLocator.fallbackDirectories`.
    static var extraSearchDirectories: [String] {
        let home = Sandbox.realHome
        return [
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
            (home as NSString).appendingPathComponent(".npm-global/bin"),
        ]
    }

    /// Deduplicated search directories in priority order, combining login-shell PATH and common bin paths.
    static func searchPaths(from environment: [String: String]? = nil, forceRefresh: Bool = false) -> [String] {
        if environment == nil, !forceRefresh {
            cacheLock.lock()
            if let cached = cachedSearchPaths {
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }
        var ordered: [String] = []
        var seen: Set<String> = []
        func appendDir(_ dir: String) {
            let trimmed = dir.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }
        for dir in LSPBinaryLocator.searchPaths(from: environment) {
            appendDir(dir)
        }
        for dir in extraSearchDirectories {
            appendDir(dir)
        }
        if environment == nil {
            cacheLock.lock()
            cachedSearchPaths = ordered
            cacheLock.unlock()
        }
        return ordered
    }

    /// Child-process environment with user login-shell variables, stripped of own-process-only keys,
    /// and guaranteed to include common agent bin directories in `PATH`.
    static func environment(forceRefresh: Bool = false) -> [String: String] {
        if !forceRefresh {
            cacheLock.lock()
            if let cached = cachedEnvironment {
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }
        if forceRefresh {
            LSPBinaryLocator.resetCache()
        }
        var env = LSPBinaryLocator.environment()
        for key in AppEnvironment.ownProcessOnlyKeys {
            env.removeValue(forKey: key)
        }
        let dirs = searchPaths(from: env)
        env["PATH"] = dirs.joined(separator: ":")
        cacheLock.lock()
        cachedEnvironment = env
        cachedSearchPaths = dirs
        cacheLock.unlock()
        return env
    }

    /// Resolves `executable` using the enriched search paths (or explicit `searchPaths` in tests).
    static func resolve(executable: String, searchPaths: [String]? = nil) -> String? {
        guard !AppEnvironment.isAppStore else { return nil }
        let paths = searchPaths ?? Self.searchPaths()
        return LSPBinaryLocator.resolve(executable: executable, searchPaths: paths)
    }

    /// Detects availability and preferred transport (ACP vs native CLI) for a single provider.
    static func availability(
        for provider: AgentProvider,
        searchPaths: [String]? = nil,
        forceRefresh: Bool = false
    ) -> AgentAvailability {
        guard !AppEnvironment.isAppStore else {
            return AgentAvailability(
                provider: provider,
                isInstalled: false,
                executablePath: nil,
                transportKind: provider == .agy ? .acp : .cli
            )
        }

        if searchPaths == nil, !forceRefresh {
            cacheLock.lock()
            if let cached = cachedAvailabilities[provider] {
                cacheLock.unlock()
                return cached
            }
            cacheLock.unlock()
        }

        let resolvedPaths = searchPaths ?? Self.searchPaths(forceRefresh: forceRefresh)
        let result = probeAvailability(for: provider, searchPaths: resolvedPaths)

        if searchPaths == nil {
            cacheLock.lock()
            cachedAvailabilities[provider] = result
            cacheLock.unlock()
        }
        return result
    }

    /// Detects availability for all supported providers in canonical order.
    static func detectAll(searchPaths: [String]? = nil, forceRefresh: Bool = false) -> [AgentAvailability] {
        guard !AppEnvironment.isAppStore else {
            return AgentProvider.allCases.map {
                AgentAvailability(
                    provider: $0,
                    isInstalled: false,
                    executablePath: nil,
                    transportKind: $0 == .agy ? .acp : .cli
                )
            }
        }

        if searchPaths == nil, !forceRefresh {
            cacheLock.lock()
            let allCached = AgentProvider.allCases.compactMap { cachedAvailabilities[$0] }
            cacheLock.unlock()
            if allCached.count == AgentProvider.allCases.count {
                return allCached
            }
        }

        if searchPaths == nil, forceRefresh {
            resetCache()
            LSPBinaryLocator.resetCache()
        }

        let resolvedPaths = searchPaths ?? Self.searchPaths(forceRefresh: forceRefresh)
        let results = AgentProvider.allCases.map { probeAvailability(for: $0, searchPaths: resolvedPaths) }

        if searchPaths == nil {
            cacheLock.lock()
            for item in results {
                cachedAvailabilities[item.provider] = item
            }
            cacheLock.unlock()
        }
        return results
    }

    private static func probeAvailability(for provider: AgentProvider, searchPaths: [String]) -> AgentAvailability {
        switch provider {
        case .agy:
            let path = resolve(executable: "agy", searchPaths: searchPaths)
            return AgentAvailability(
                provider: .agy,
                isInstalled: path != nil,
                executablePath: path,
                transportKind: .acp
            )
        case .claude, .codex:
            for adapter in provider.acpAdapterExecutables {
                if let acpPath = resolve(executable: adapter, searchPaths: searchPaths) {
                    return AgentAvailability(
                        provider: provider,
                        isInstalled: true,
                        executablePath: acpPath,
                        transportKind: .acp
                    )
                }
            }
            let cliPath = resolve(executable: provider.executableName, searchPaths: searchPaths)
            return AgentAvailability(
                provider: provider,
                isInstalled: cliPath != nil,
                executablePath: cliPath,
                transportKind: .cli
            )
        }
    }
}

// MARK: - Subprocess Primitives

/// Thread-safe lifecycle controller for child agent processes with `SIGTERM` -> `SIGKILL` escalation.
final class AgentProcessBox: @unchecked Sendable {
    static let defaultKillGracePeriod: TimeInterval = 2.0

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var isTimedOut = false
    private var killScheduled = false
    private let killGracePeriod: TimeInterval

    init(killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod) {
        self.killGracePeriod = killGracePeriod
    }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return isCancelled }
    var timedOut: Bool { lock.lock(); defer { lock.unlock() }; return isTimedOut }

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let shouldStop = isCancelled || isTimedOut
        let shouldScheduleKill = shouldStop && !killScheduled
        if shouldScheduleKill { killScheduled = true }
        lock.unlock()
        if shouldStop {
            terminate(p, scheduleKill: shouldScheduleKill)
        }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let p = process
        let shouldScheduleKill = p != nil && !killScheduled
        if shouldScheduleKill { killScheduled = true }
        lock.unlock()
        if let p {
            terminate(p, scheduleKill: shouldScheduleKill)
        }
    }

    func markTimedOut() {
        lock.lock()
        isTimedOut = true
        let p = process
        let shouldScheduleKill = p != nil && !killScheduled
        if shouldScheduleKill { killScheduled = true }
        lock.unlock()
        if let p {
            terminate(p, scheduleKill: shouldScheduleKill)
        }
    }

    /// Gracefully stops the process (used after completing a streaming control/ACP exchange).
    func requestGracefulStop() {
        lock.lock()
        let p = process
        let shouldScheduleKill = p != nil && !killScheduled
        if shouldScheduleKill { killScheduled = true }
        lock.unlock()
        if let p {
            terminate(p, scheduleKill: shouldScheduleKill)
        }
    }

    private func terminate(_ p: Process, scheduleKill: Bool) {
        guard p.isRunning else { return }
        let pid = p.processIdentifier
        p.terminate()
        guard scheduleKill, pid > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod) { [self] in
            self.lock.lock()
            let stillAttached = self.process === p
            self.lock.unlock()
            if stillAttached, p.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }
}

/// Low-level subprocess runners shared by ACP and CLI adapters.
enum AgentSubprocess {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    fileprivate final class DataBuffer: @unchecked Sendable {
        var data = Data()
    }

    /// Suppresses `SIGPIPE` on a write pipe descriptor so a crashed child never kills the host app.
    fileprivate static func disableSigPipe(on fd: Int32) {
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
    }

    /// Runs a one-shot process, optionally feeding `stdinData` asynchronously to avoid pipe deadlocks.
    static func runOneShot(
        provider: AgentProvider,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        stdinData: Data? = nil,
        timeout: TimeInterval,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> Output {
        try Task.checkCancellation()
        let box = AgentProcessBox(killGracePeriod: killGracePeriod)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }

                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = arguments
                    p.currentDirectoryURL = workingDirectory
                    p.environment = environment

                    let inPipe: Pipe? = stdinData != nil ? Pipe() : nil
                    if let inPipe {
                        p.standardInput = inPipe
                    } else {
                        p.standardInput = FileHandle.nullDevice
                    }
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    p.standardOutput = outPipe
                    p.standardError = errPipe

                    do {
                        try p.run()
                    } catch {
                        cont.resume(throwing: LocalAgentError.executionFailed(
                            provider: provider,
                            status: -1,
                            stderr: error.localizedDescription
                        ))
                        return
                    }
                    box.attach(p)

                    let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    let timeoutMs = max(500, Int(timeout * 1000))
                    watchdog.schedule(deadline: .now() + .milliseconds(timeoutMs))
                    watchdog.setEventHandler {
                        box.markTimedOut()
                    }
                    watchdog.resume()

                    let group = DispatchGroup()

                    if let inPipe, let payload = stdinData {
                        let writer = inPipe.fileHandleForWriting
                        disableSigPipe(on: writer.fileDescriptor)
                        group.enter()
                        DispatchQueue.global(qos: .utility).async {
                            writeAll(payload, to: writer.fileDescriptor)
                            try? writer.close()
                            group.leave()
                        }
                    }

                    let errBuffer = DataBuffer()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.wait()
                    p.waitUntilExit()
                    box.detach()
                    watchdog.cancel()

                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                    } else if box.timedOut {
                        cont.resume(throwing: LocalAgentError.timedOut(provider))
                    } else {
                        cont.resume(returning: Output(
                            status: p.terminationStatus,
                            stdout: outData,
                            stderr: errBuffer.data
                        ))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Writes all bytes to a POSIX file descriptor, handling partial writes and `EINTR`.
    @discardableResult
    fileprivate static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        guard fd >= 0 else { return false }
        return data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            var offset = 0
            while remaining > 0 {
                let written = Darwin.write(fd, base.advanced(by: offset), remaining)
                if written > 0 {
                    offset += written
                    remaining -= written
                } else if written == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }
}

/// Dual-timer watchdog for streaming NDJSON sessions:
/// - `idleTimer`: resets whenever a valid JSON frame is received or sent, failing fast on true stalls.
/// - `totalTimer`: absolute wall-clock cap preventing runaway infinite streams.
private final class SessionWatchdogs: @unchecked Sendable {
    private let lock = NSLock()
    private let idleTimeoutMs: Int
    private let idleTimer: DispatchSourceTimer
    private let totalTimer: DispatchSourceTimer
    private var cancelled = false

    init(
        idleTimeout: TimeInterval,
        maxTotalTimeout: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        let queue = DispatchQueue(label: "com.dif.localagent.watchdog", qos: .utility)
        let resolvedIdleMs = max(100, Int(idleTimeout * 1000))
        let resolvedTotalMs = max(resolvedIdleMs, Int(maxTotalTimeout * 1000))
        self.idleTimeoutMs = resolvedIdleMs

        let idle = DispatchSource.makeTimerSource(queue: queue)
        let total = DispatchSource.makeTimerSource(queue: queue)
        self.idleTimer = idle
        self.totalTimer = total

        idle.schedule(deadline: .now() + .milliseconds(resolvedIdleMs))
        idle.setEventHandler { [weak self] in
            self?.fireIfActive(onTimeout)
        }

        total.schedule(deadline: .now() + .milliseconds(resolvedTotalMs))
        total.setEventHandler { [weak self] in
            self?.fireIfActive(onTimeout)
        }

        idle.resume()
        total.resume()
    }

    deinit {
        cancel()
    }

    func touch() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        idleTimer.schedule(deadline: .now() + .milliseconds(idleTimeoutMs))
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        idleTimer.cancel()
        totalTimer.cancel()
        lock.unlock()
    }

    private func fireIfActive(_ onTimeout: () -> Void) {
        lock.lock()
        let active = !cancelled
        lock.unlock()
        if active {
            onTimeout()
        }
    }
}

/// Interactive NDJSON (line-delimited JSON) stdio session over a child `Process`.
/// Must only be driven from the dedicated worker thread inside `run`.
final class NDJSONProcessSession {
    /// Default absolute wall-clock cap for a streaming NDJSON session given its idle timeout.
    static func defaultMaxTotalTimeout(for idleTimeout: TimeInterval) -> TimeInterval {
        max(idleTimeout * 4, 360)
    }

    private final class LockedStdinCloser: @unchecked Sendable {
        private let pipe: Pipe
        private let lock = NSLock()
        private var closed = false

        init(pipe: Pipe) {
            self.pipe = pipe
        }

        var writableFileDescriptor: Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return nil }
            return pipe.fileHandleForWriting.fileDescriptor
        }

        func close() {
            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            closed = true
            try? pipe.fileHandleForWriting.close()
            lock.unlock()
        }
    }

    private let process: Process
    private let inPipe: Pipe
    private let stdinCloser: LockedStdinCloser
    private let outPipe: Pipe
    private let errBuffer: AgentSubprocess.DataBuffer
    private let errGroup: DispatchGroup
    private let box: AgentProcessBox
    private let watchdogs: SessionWatchdogs
    private var readBuffer = Data()
    private var eofReached = false

    private init(
        process: Process,
        inPipe: Pipe,
        outPipe: Pipe,
        errBuffer: AgentSubprocess.DataBuffer,
        errGroup: DispatchGroup,
        box: AgentProcessBox,
        watchdogs: SessionWatchdogs
    ) {
        self.process = process
        self.inPipe = inPipe
        self.stdinCloser = LockedStdinCloser(pipe: inPipe)
        self.outPipe = outPipe
        self.errBuffer = errBuffer
        self.errGroup = errGroup
        self.box = box
        self.watchdogs = watchdogs
    }

    var isCancelled: Bool { box.cancelled }
    var isTimedOut: Bool { box.timedOut }

    /// Resets the per-activity idle watchdog (called automatically on each valid JSON frame).
    func touchActivity() {
        watchdogs.touch()
    }

    /// Sends one JSON object as a compact NDJSON line terminated with `\n`.
    func sendJSON(_ object: [String: Any]) throws {
        var payload = try JSONSerialization.data(withJSONObject: object, options: [])
        payload.append(0x0A)
        guard let fd = stdinCloser.writableFileDescriptor else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EPIPE))
        }
        guard AgentSubprocess.writeAll(payload, to: fd) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        watchdogs.touch()
    }

    /// Reads the next valid JSON object line from stdout, skipping blank or non-JSON log lines.
    /// Each valid JSON frame renews the idle watchdog so active streaming never hits the idle timeout.
    /// Returns `nil` on EOF, cancellation, or timeout.
    func readNextJSONObject() -> [String: Any]? {
        let fd = outPipe.fileHandleForReading.fileDescriptor
        while !box.cancelled && !box.timedOut {
            if let newlineIdx = readBuffer.firstIndex(of: 0x0A) {
                var lineData = readBuffer[readBuffer.startIndex..<newlineIdx]
                readBuffer.removeSubrange(readBuffer.startIndex...newlineIdx)
                if lineData.last == 0x0D {
                    lineData = lineData.dropLast()
                }
                if let obj = parseJSONObject(Data(lineData)) {
                    watchdogs.touch()
                    return obj
                }
                continue
            }

            if eofReached {
                if !readBuffer.isEmpty {
                    let remaining = readBuffer
                    readBuffer.removeAll()
                    if let obj = parseJSONObject(remaining) {
                        watchdogs.touch()
                        return obj
                    }
                }
                return nil
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                readBuffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                eofReached = true
            } else if errno == EINTR {
                continue
            } else {
                eofReached = true
            }
        }
        return nil
    }

    /// Closes stdin to signal EOF to the child process.
    func closeStdin() {
        stdinCloser.close()
    }

    /// Writes raw bytes to stdin on a utility queue and closes stdin to avoid pipe deadlocks on large prompts.
    func writeStdinAndCloseAsync(_ data: Data) {
        DispatchQueue.global(qos: .utility).async { [stdinCloser] in
            if !data.isEmpty, let fd = stdinCloser.writableFileDescriptor {
                _ = AgentSubprocess.writeAll(data, to: fd)
            }
            stdinCloser.close()
        }
    }

    /// Closes stdin and shuts down the child process gracefully (escalating via `AgentProcessBox` if needed).
    func finish(graceSeconds: TimeInterval = 1.0, terminateIfStillRunning: Bool = true) -> (status: Int32, stderr: String) {
        watchdogs.cancel()
        closeStdin()

        var shutdownTimer: DispatchSourceTimer?
        if terminateIfStillRunning && process.isRunning {
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            let graceMs = max(50, Int(graceSeconds * 1000))
            timer.schedule(deadline: .now() + .milliseconds(graceMs))
            timer.setEventHandler { [box] in
                box.requestGracefulStop()
            }
            timer.resume()
            shutdownTimer = timer
        }

        // Drain any remaining stdout so child doesn't block writing before exit.
        _ = outPipe.fileHandleForReading.readDataToEndOfFile()
        errGroup.wait()
        process.waitUntilExit()
        shutdownTimer?.cancel()
        box.detach()

        let stderrText = String(decoding: errBuffer.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, stderrText)
    }

    private func parseJSONObject(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Launches a child process and runs `body` on a background queue with idle/total watchdogs & Task cancellation.
    /// - Parameters:
    ///   - timeout: Per-activity idle timeout (reset on each valid JSON frame received or sent).
    ///   - maxTotalTimeout: Hard wall-clock cap for the entire session (defaults to `max(timeout * 4, 360)`).
    static func run<T: Sendable>(
        provider: AgentProvider,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        timeout: TimeInterval,
        maxTotalTimeout: TimeInterval? = nil,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod,
        body: @escaping @Sendable (NDJSONProcessSession) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let box = AgentProcessBox(killGracePeriod: killGracePeriod)
        let resolvedMaxTotal = maxTotalTimeout ?? defaultMaxTotalTimeout(for: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    if box.cancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }

                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: executable)
                    p.arguments = arguments
                    p.currentDirectoryURL = workingDirectory
                    p.environment = environment

                    let inPipe = Pipe()
                    let outPipe = Pipe()
                    let errPipe = Pipe()
                    p.standardInput = inPipe
                    p.standardOutput = outPipe
                    p.standardError = errPipe

                    AgentSubprocess.disableSigPipe(on: inPipe.fileHandleForWriting.fileDescriptor)

                    do {
                        try p.run()
                    } catch {
                        cont.resume(throwing: LocalAgentError.executionFailed(
                            provider: provider,
                            status: -1,
                            stderr: error.localizedDescription
                        ))
                        return
                    }
                    box.attach(p)

                    let watchdogs = SessionWatchdogs(
                        idleTimeout: timeout,
                        maxTotalTimeout: resolvedMaxTotal
                    ) {
                        box.markTimedOut()
                    }
                    defer { watchdogs.cancel() }

                    let errBuffer = AgentSubprocess.DataBuffer()
                    let errGroup = DispatchGroup()
                    errGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                        errGroup.leave()
                    }

                    let session = NDJSONProcessSession(
                        process: p,
                        inPipe: inPipe,
                        outPipe: outPipe,
                        errBuffer: errBuffer,
                        errGroup: errGroup,
                        box: box,
                        watchdogs: watchdogs
                    )

                    do {
                        let value = try body(session)
                        watchdogs.cancel()
                        if box.cancelled {
                            _ = session.finish(graceSeconds: 0.1, terminateIfStillRunning: true)
                            cont.resume(throwing: CancellationError())
                        } else if box.timedOut {
                            _ = session.finish(graceSeconds: 0.1, terminateIfStillRunning: true)
                            cont.resume(throwing: LocalAgentError.timedOut(provider))
                        } else {
                            cont.resume(returning: value)
                        }
                    } catch {
                        let exitInfo = session.finish(graceSeconds: 0.2, terminateIfStillRunning: true)
                        if box.cancelled {
                            cont.resume(throwing: CancellationError())
                        } else if box.timedOut {
                            cont.resume(throwing: LocalAgentError.timedOut(provider))
                        } else if let agentError = error as? LocalAgentError {
                            cont.resume(throwing: agentError)
                        } else if exitInfo.status != 0 {
                            cont.resume(throwing: LocalAgentError.executionFailed(
                                provider: provider,
                                status: exitInfo.status,
                                stderr: exitInfo.stderr.isEmpty ? error.localizedDescription : exitInfo.stderr
                            ))
                        } else {
                            cont.resume(throwing: LocalAgentError.protocolError(
                                provider: provider,
                                detail: error.localizedDescription
                            ))
                        }
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

// MARK: - ACP Transport (JSON-RPC 2.0 / NDJSON over stdio)

/// Reason returned when a read-only shell command check rejects an ACP tool request.
struct ReadOnlyShellRejection: Error, ExpressibleByStringInterpolation, Equatable, Sendable {
    let reason: String

    init(_ reason: String) {
        self.reason = reason
    }

    init(stringLiteral value: String) {
        self.reason = value
    }
}

/// Result of evaluating an ACP server permission request against DiffCode's read-only policy.
enum ACPPermissionDecision: Equatable, Sendable {
    case allow(summary: String)
    case deny(summary: String, reason: String)

    var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

/// Implements the Agent Client Protocol (ACP) over stdio NDJSON.
/// Used natively for `agy acp --stdio` and optionally for standalone ACP adapters (`claude-agent-acp`, `codex-acp`).
enum ACPTransport {
    static let protocolVersion = 1
    static let clientName = "DiffCode"
    static let clientVersion = "1.0"

    /// Default CLI arguments to launch an ACP server for `provider`.
    static func defaultArguments(for provider: AgentProvider, executable: String) -> [String] {
        let binaryName = (executable as NSString).lastPathComponent
        if provider == .agy || binaryName == "agy" {
            return ["acp", "--stdio"]
        }
        return []
    }

    // MARK: Frame Builders & Pure Parsers (unit-testable)

    static func makeInitializeRequest(id: Int, toolAccess: AgentToolAccess = .disabled) -> [String: Any] {
        let clientCapabilities: [String: Any]
        switch toolAccess {
        case .disabled:
            clientCapabilities = [:]
        case .readOnly:
            clientCapabilities = [
                "fs": [
                    "readTextFile": true,
                    "writeTextFile": false,
                ] as [String: Any],
            ]
        }
        return [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "clientCapabilities": clientCapabilities,
                "clientInfo": [
                    "name": clientName,
                    "version": clientVersion,
                ],
            ] as [String: Any],
        ]
    }

    static func makeSessionNewRequest(id: Int, cwd: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/new",
            "params": [
                "cwd": cwd,
                "mcpServers": [Any](),
            ] as [String: Any],
        ]
    }

    static func makeSessionResumeRequest(id: Int, sessionId: String, cwd: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/resume",
            "params": [
                "sessionId": sessionId,
                "cwd": cwd,
                "mcpServers": [Any](),
            ] as [String: Any],
        ]
    }

    static func makeSessionLoadRequest(id: Int, sessionId: String, cwd: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/load",
            "params": [
                "sessionId": sessionId,
                "cwd": cwd,
                "mcpServers": [Any](),
            ] as [String: Any],
        ]
    }

    static func makeSetModelRequest(id: Int, sessionId: String, modelId: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/set_model",
            "params": [
                "sessionId": sessionId,
                "modelId": modelId,
            ],
        ]
    }

    static func makeSetConfigOptionRequest(id: Int, sessionId: String, configId: String, value: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/set_config_option",
            "params": [
                "sessionId": sessionId,
                "configId": configId,
                "value": value,
            ],
        ]
    }

    static func makeSessionPromptRequest(id: Int, sessionId: String, prompt: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/prompt",
            "params": [
                "sessionId": sessionId,
                "prompt": [
                    ["type": "text", "text": prompt],
                ],
            ] as [String: Any],
        ]
    }

    static func makeSessionCloseRequest(id: Int, sessionId: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/close",
            "params": [
                "sessionId": sessionId,
            ],
        ]
    }

    /// Extracts an integer JSON-RPC message id if present.
    static func jsonRPCID(from frame: [String: Any]) -> Int? {
        guard let raw = frame["id"] else { return nil }
        if let intVal = raw as? Int { return intVal }
        if let num = raw as? NSNumber {
            // Avoid matching JSON booleans bridged to NSNumber.
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num.intValue
        }
        if let str = raw as? String { return Int(str) }
        return nil
    }

    /// Extracts any valid JSON-RPC 2.0 `id` value (integer, number, or arbitrary string/UUID; excluding `null` and booleans).
    static func rawJSONRPCID(from frame: [String: Any]) -> Any? {
        guard let raw = frame["id"], !(raw is NSNull) else { return nil }
        if let str = raw as? String { return str }
        if let intVal = raw as? Int { return intVal }
        if let num = raw as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num
        }
        return nil
    }

    /// Builds a JSON-RPC `-32601` error reply for an unsupported server-initiated request,
    /// preserving the original `id` (integer, string, UUID, etc.) verbatim so the server never deadlocks.
    static func makeUnsupportedServerRequestReply(id: Any) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": -32601,
                "message": "Non-interactive DiffCode client does not support interactive requests",
            ] as [String: Any],
        ]
    }

    /// Parses a JSON-RPC `error` object into `(code, message)` if present.
    static func parseRPCError(from frame: [String: Any]) -> (code: Int, message: String)? {
        guard let errorObj = frame["error"] as? [String: Any] else { return nil }
        let code = (errorObj["code"] as? Int) ?? (errorObj["code"] as? NSNumber)?.intValue ?? -1
        let message = (errorObj["message"] as? String) ?? "JSON-RPC error \(code)"
        return (code, message)
    }

    /// Parses available models from a `session/new` JSON-RPC `result` dictionary.
    /// Supports both `models.availableModels` and `configOptions` (`id == "model"`).
    static func parseSessionNewModels(from result: [String: Any], provider: AgentProvider) -> [AgentModel] {
        var parsed: [AgentModel] = []
        var seen: Set<String> = []

        if let modelsObj = result["models"] as? [String: Any],
           let available = modelsObj["availableModels"] as? [[String: Any]] {
            let currentId = modelsObj["currentModelId"] as? String
            for item in available {
                guard let modelId = (item["modelId"] as? String) ?? (item["id"] as? String),
                      !modelId.isEmpty,
                      seen.insert(modelId).inserted else { continue }
                let displayName = (item["name"] as? String) ?? (item["displayName"] as? String) ?? modelId
                parsed.append(AgentModel(
                    id: modelId,
                    name: displayName.isEmpty ? modelId : displayName,
                    provider: provider,
                    isDefault: modelId == currentId
                ))
            }
        }

        if !parsed.isEmpty {
            return parsed
        }

        // Fallback: ACP `configOptions` with `id == "model"`.
        if let configOptions = result["configOptions"] as? [[String: Any]] {
            for option in configOptions {
                let optId = (option["id"] as? String) ?? (option["category"] as? String)
                guard optId == "model" else { continue }
                let currentValue = option["currentValue"] as? String
                if let choices = option["options"] as? [[String: Any]] {
                    for choice in choices {
                        // Support both flat options and option groups (`group` + `options`).
                        if let nested = choice["options"] as? [[String: Any]] {
                            for sub in nested {
                                appendConfigModel(sub, currentValue: currentValue, provider: provider, into: &parsed, seen: &seen)
                            }
                        } else {
                            appendConfigModel(choice, currentValue: currentValue, provider: provider, into: &parsed, seen: &seen)
                        }
                    }
                }
            }
        }

        return parsed
    }

    private static func appendConfigModel(
        _ item: [String: Any],
        currentValue: String?,
        provider: AgentProvider,
        into parsed: inout [AgentModel],
        seen: inout Set<String>
    ) {
        guard let modelId = (item["value"] as? String) ?? (item["modelId"] as? String) ?? (item["id"] as? String),
              !modelId.isEmpty,
              seen.insert(modelId).inserted else { return }
        let name = (item["name"] as? String) ?? (item["label"] as? String) ?? modelId
        parsed.append(AgentModel(
            id: modelId,
            name: name.isEmpty ? modelId : name,
            provider: provider,
            isDefault: modelId == currentValue
        ))
    }

    /// Extracts streamed assistant text from an ACP `session/update` notification frame.
    /// Returns `nil` for non-text or non-message updates (e.g. `agent_thought_chunk`, `usage_update`).
    static func extractAgentMessageChunk(from frame: [String: Any]) -> String? {
        guard (frame["method"] as? String) == "session/update",
              let params = frame["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              (update["sessionUpdate"] as? String) == "agent_message_chunk",
              let content = update["content"] as? [String: Any],
              (content["type"] as? String) == "text",
              let text = content["text"] as? String else {
            return nil
        }
        return text
    }

    /// Extracts the `sessionUpdate` kind (e.g. `"tool_call"`, `"agent_message_chunk"`) from a `session/update` frame.
    static func extractSessionUpdateKind(from frame: [String: Any]) -> String? {
        guard (frame["method"] as? String) == "session/update",
              let params = frame["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else {
            return nil
        }
        return update["sessionUpdate"] as? String
    }

    /// Extracts streamed assistant thought text from an ACP `session/update` notification frame.
    static func extractAgentThoughtChunk(from frame: [String: Any]) -> String? {
        guard (frame["method"] as? String) == "session/update",
              let params = frame["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              (update["sessionUpdate"] as? String) == "agent_thought_chunk",
              let content = update["content"] as? [String: Any],
              (content["type"] as? String) == "text",
              let text = content["text"] as? String else {
            return nil
        }
        return text
    }

    /// Extracts a `tool_call` or `tool_call_update` event from an ACP `session/update` frame.
    static func extractToolCallEvent(from frame: [String: Any]) -> AgentStreamEvent? {
        guard (frame["method"] as? String) == "session/update",
              let params = frame["params"] as? [String: Any],
              let update = params["update"] as? [String: Any],
              let kindTag = update["sessionUpdate"] as? String,
              kindTag == "tool_call" || kindTag == "tool_call_update" else {
            return nil
        }
        let id = ((update["toolCallId"] as? String) ?? (update["id"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedID = id.isEmpty ? "tool-\(UUID().uuidString)" : id
        let title = ((update["title"] as? String) ?? (update["name"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = (update["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = (update["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = formatCompactToolPayload(update["rawInput"])
        let output = formatCompactToolPayload(update["rawOutput"] ?? update["content"])
        return .toolActivity(
            id: resolvedID,
            title: title,
            kind: kind?.isEmpty == true ? nil : kind,
            input: input,
            status: status?.isEmpty == true ? (kindTag == "tool_call" ? "running" : nil) : status,
            output: output
        )
    }

    /// Formats arbitrary JSON tool inputs or outputs into a bounded readable snippet for live conversation UI.
    static func formatCompactToolPayload(_ raw: Any?, maxChars: Int = 4000) -> String? {
        guard let raw, !(raw is NSNull) else { return nil }
        let formatted: String
        if let str = raw as? String {
            formatted = str.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let arr = raw as? [[String: Any]] {
            let texts = arr.compactMap { part -> String? in
                if let t = part["text"] as? String, !t.isEmpty { return t }
                if let c = part["content"] as? String, !c.isEmpty { return c }
                return nil
            }
            if !texts.isEmpty {
                formatted = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if JSONSerialization.isValidJSONObject(arr),
                      let data = try? JSONSerialization.data(withJSONObject: arr, options: [.sortedKeys]) {
                formatted = String(decoding: data, as: UTF8.self)
            } else {
                formatted = ""
            }
        } else if JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]) {
            formatted = String(decoding: data, as: UTF8.self)
        } else {
            formatted = String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !formatted.isEmpty else { return nil }
        if formatted == "{}" || formatted == "[]" { return nil }
        if formatted.count > maxChars {
            return String(formatted.prefix(maxChars)) + "\n… [truncated \(formatted.count - maxChars) chars]"
        }
        return formatted
    }

    // MARK: Read-Only Tool Policy & Handlers

    private static let maxReadTextFileBytes = 2 * 1024 * 1024

    /// Canonicalizes `rawPath` (resolving relative paths against `repoRoot` and resolving symlinks on the deepest existing ancestor).
    static func canonicalizedPath(_ rawPath: String, relativeTo repoRoot: URL) -> String {
        let base = repoRoot.standardizedFileURL
        let candidate: URL
        if rawPath == "~" {
            candidate = URL(fileURLWithPath: Sandbox.realHome)
        } else if rawPath.hasPrefix("~/") {
            let rest = String(rawPath.dropFirst(2))
            candidate = URL(fileURLWithPath: (Sandbox.realHome as NSString).appendingPathComponent(rest))
        } else if rawPath.hasPrefix("/") {
            candidate = URL(fileURLWithPath: rawPath)
        } else {
            candidate = base.appendingPathComponent(rawPath)
        }
        return canonicalizeURL(candidate)
    }

    private static func canonicalizeURL(_ url: URL) -> String {
        let fm = FileManager.default
        var remaining: [String] = []
        var cursor = url
        var hops = 0
        while cursor.path != "/" && hops < 32 {
            hops += 1
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: cursor.path, isDirectory: &isDir) {
                break
            }
            if (try? fm.attributesOfItem(atPath: cursor.path)) != nil,
               let dest = try? fm.destinationOfSymbolicLink(atPath: cursor.path) {
                let parent = cursor.deletingLastPathComponent()
                cursor = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : parent.appendingPathComponent(dest)
                continue
            }
            let last = cursor.lastPathComponent
            if !last.isEmpty && last != "/" {
                remaining.append(last)
            }
            cursor.deleteLastPathComponent()
        }
        var resolved = cursor.resolvingSymlinksInPath()
        for component in remaining.reversed() {
            if component == "." { continue }
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    /// Returns true if `rawPath` resolves to `repoRoot` or a descendant path inside `repoRoot`.
    static func isPathWithinRepo(_ rawPath: String, repoRoot: URL) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0"), !trimmed.hasPrefix("$") else { return false }
        let resolved = canonicalizedPath(trimmed, relativeTo: repoRoot)
        let root = canonicalizeURL(repoRoot)
        return resolved == root || resolved.hasPrefix(root == "/" ? "/" : root + "/")
    }

    /// Validates whether `command` consists solely of read-only repository inspection commands
    /// (allowing multi-line scripts, safe local variable assignments, `for`/`if` control flow,
    /// `${VAR}` safe parameter expansion, `/dev/null` stderr suppression, `&&`/`||`/pipes).
    static func isReadOnlyShellCommand(_ command: String, repoRoot: URL) -> Bool {
        if case .success = evaluateReadOnlyShellCommand(command, repoRoot: repoRoot) {
            return true
        }
        return false
    }

    /// Evaluates whether `command` consists solely of read-only repository inspection commands,
    /// returning `.failure(reason)` with the specific rule violated when denied.
    static func evaluateReadOnlyShellCommand(_ command: String, repoRoot: URL) -> Result<Void, ReadOnlyShellRejection> {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("empty shell command")
        }
        guard !trimmed.contains("\0") else {
            return .failure("command contains NUL byte")
        }
        switch tokenizeReadOnlyCommandUnits(trimmed) {
        case .failure(let reason):
            return .failure(reason)
        case .success(let units):
            guard !units.isEmpty else {
                return .failure("empty shell command")
            }
            return validateReadOnlyUnits(units, repoRoot: repoRoot)
        }
    }

    private enum ShellQuoteState {
        case none
        case single
        case double
    }

    private static let forbiddenEnvVarNames: Set<String> = [
        "PATH", "IFS", "ENV", "BASH_ENV", "ZDOTDIR", "HOME", "SHELL",
        "EDITOR", "VISUAL", "PAGER", "CDPATH", "FPATH",
    ]

    private static func isSafeShellVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              (first >= "A" && first <= "Z") || (first >= "a" && first <= "z") || first == "_",
              name.unicodeScalars.allSatisfy({
                  ($0 >= "A" && $0 <= "Z")
                      || ($0 >= "a" && $0 <= "z")
                      || ($0 >= "0" && $0 <= "9")
                      || $0 == "_"
              }) else {
            return false
        }
        if forbiddenEnvVarNames.contains(name)
            || name.hasPrefix("GIT_")
            || name.hasPrefix("LD_")
            || name.hasPrefix("DYLD_") {
            return false
        }
        return true
    }

    private static func parseSafeLocalAssignment(_ token: String) -> (name: String, value: String)? {
        guard let eqIdx = token.firstIndex(of: "="), eqIdx > token.startIndex else {
            return nil
        }
        let name = String(token[..<eqIdx])
        let value = String(token[token.index(after: eqIdx)...])
        guard isSafeShellVariableName(name),
              !value.contains("\0"),
              !value.contains("`"),
              !value.contains("$(") else {
            return nil
        }
        return (name, value)
    }

    private static func isSafeLocalAssignment(_ token: String) -> Bool {
        parseSafeLocalAssignment(token) != nil
    }

    /// Reads `${VAR}` starting at the `{` scalar, accepting only safe variable names without modifiers.
    private static func consumeSafeCurlyVariable(
        scalars: [Unicode.Scalar],
        openBraceIndex: Int
    ) -> Result<(name: String, nextIndex: Int), ReadOnlyShellRejection> {
        let count = scalars.count
        var j = openBraceIndex + 1
        var name = ""
        while j < count && scalars[j] != "}" {
            let s = scalars[j]
            if (s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9") || s == "_" {
                name.append(Character(s))
                j += 1
            } else {
                return .failure("unsupported shell parameter expansion '${...}'")
            }
        }
        guard j < count, scalars[j] == "}", !name.isEmpty else {
            return .failure("unterminated '${' expansion")
        }
        guard isSafeShellVariableName(name) else {
            return .failure("restricted shell variable '${\(name)}' is not allowed in read-only mode")
        }
        return .success((name, j + 1))
    }

    /// Reads the next shell word after a redirection operator (`<`, `>`, `&>`, `2>&`). Returns `nil` on syntax errors or injection.
    private static func consumeRedirectionWord(
        scalars: [Unicode.Scalar],
        startIndex: Int
    ) -> (word: String, nextIndex: Int)? {
        let count = scalars.count
        var i = startIndex
        while i < count && (scalars[i] == " " || scalars[i] == "\t") {
            i += 1
        }
        guard i < count else { return nil }

        var state: ShellQuoteState = .none
        var word = ""
        var hasChars = false

        while i < count {
            let c = scalars[i]
            switch state {
            case .single:
                if c == "'" {
                    state = .none
                } else {
                    word.append(Character(c))
                    hasChars = true
                }
            case .double:
                if c == "\\" && i + 1 < count {
                    let next = scalars[i + 1]
                    if next == "\"" || next == "\\" || next == "$" || next == "`" {
                        word.append(Character(next))
                        hasChars = true
                        i += 2
                        continue
                    }
                    word.append("\\")
                    hasChars = true
                } else if c == "`" {
                    return nil
                } else if c == "$" && i + 1 < count && scalars[i + 1] == "(" {
                    return nil
                } else if c == "\"" {
                    state = .none
                } else {
                    word.append(Character(c))
                    hasChars = true
                }
            case .none:
                if c == "`" { return nil }
                if c == "$" && i + 1 < count && scalars[i + 1] == "(" { return nil }
                if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "|" || c == "&" || c == ";" || c == "<" || c == ">" || c == "(" || c == ")" {
                    break
                } else if c == "'" {
                    state = .single
                    hasChars = true
                } else if c == "\"" {
                    state = .double
                    hasChars = true
                } else if c == "\\" {
                    guard i + 1 < count else { return nil }
                    word.append(Character(scalars[i + 1]))
                    hasChars = true
                    i += 2
                    continue
                } else {
                    word.append(Character(c))
                    hasChars = true
                }
                i += 1
                continue
            }
            if state == .none && (c == " " || c == "\t" || c == "\n" || c == "\r" || c == "|" || c == "&" || c == ";" || c == "<" || c == ">" || c == "(" || c == ")") {
                break
            }
            i += 1
        }

        guard state == .none, hasChars else { return nil }
        return (word, i)
    }

    private static func tokenizeReadOnlyCommandUnits(_ command: String) -> Result<[[String]], ReadOnlyShellRejection> {
        let scalars = Array(command.unicodeScalars)
        let count = scalars.count
        var state: ShellQuoteState = .none
        var inGitRefBrace = false
        var units: [[String]] = []
        var currentUnit: [String] = []
        var currentToken = ""
        var hasToken = false
        var tokenUsedQuotesOrEscape = false
        var pendingBinaryOp = false
        var i = 0

        let forbiddenUnquoted: Set<Unicode.Scalar> = ["(", ")"]

        func flushToken() {
            if hasToken {
                currentUnit.append(currentToken)
                currentToken = ""
                hasToken = false
                tokenUsedQuotesOrEscape = false
            }
        }

        func commitUnit(requiresNonEmpty: Bool) -> Bool {
            flushToken()
            if currentUnit.isEmpty {
                return !requiresNonEmpty
            }
            units.append(currentUnit)
            currentUnit = []
            pendingBinaryOp = false
            return true
        }

        while i < count {
            let c = scalars[i]
            switch state {
            case .single:
                if c == "'" {
                    state = .none
                } else {
                    currentToken.append(Character(c))
                }
            case .double:
                if c == "\\" && i + 1 < count {
                    let next = scalars[i + 1]
                    if next == "\n" {
                        i += 2
                        continue
                    }
                    if next == "\"" || next == "\\" || next == "$" || next == "`" {
                        currentToken.append(Character(next))
                        i += 2
                        continue
                    }
                    currentToken.append("\\")
                } else if c == "`" {
                    return .failure("backtick command substitution is forbidden in read-only mode")
                } else if c == "$" && i + 1 < count && scalars[i + 1] == "(" {
                    return .failure("command substitution '$(...)' is forbidden in read-only mode")
                } else if c == "$" && i + 1 < count && scalars[i + 1] == "{" {
                    switch consumeSafeCurlyVariable(scalars: scalars, openBraceIndex: i + 1) {
                    case .success(let parsed):
                        currentToken.append("${\(parsed.name)}")
                        i = parsed.nextIndex
                        continue
                    case .failure(let reason):
                        return .failure(reason)
                    }
                } else if c == "\"" {
                    state = .none
                } else {
                    currentToken.append(Character(c))
                }
            case .none:
                if c == "`" {
                    return .failure("backtick command substitution is forbidden in read-only mode")
                }
                if c == "$" && i + 1 < count && scalars[i + 1] == "(" {
                    return .failure("command substitution '$(...)' is forbidden in read-only mode")
                }
                if forbiddenUnquoted.contains(c) {
                    return .failure("subshell parentheses '()' are forbidden in read-only mode")
                }

                // Line continuation outside quotes: `\` followed by newline (`\n` or `\r\n`)
                if c == "\\" && i + 1 < count && (scalars[i + 1] == "\n" || scalars[i + 1] == "\r") {
                    i += (scalars[i + 1] == "\r" && i + 2 < count && scalars[i + 2] == "\n") ? 3 : 2
                    continue
                }

                if inGitRefBrace {
                    if c == "}" {
                        inGitRefBrace = false
                        currentToken.append("}")
                        i += 1
                        continue
                    }
                    if c == " " || c == "\t" || c == "\n" || c == "\r" || c == "|" || c == "&" || c == ";" || c == "," || c == "'" || c == "\"" || c == "<" || c == ">" {
                        return .failure("invalid brace sequence in git ref")
                    }
                    currentToken.append(Character(c))
                    i += 1
                    continue
                }

                if c == "{" {
                    // Allow safe `${VAR}` parameter expansion and unquoted `@{...}` git ref syntax; disallow all other braces.
                    if hasToken && currentToken.hasSuffix("$") {
                        switch consumeSafeCurlyVariable(scalars: scalars, openBraceIndex: i) {
                        case .success(let parsed):
                            currentToken.append("{\(parsed.name)}")
                            i = parsed.nextIndex
                            continue
                        case .failure(let reason):
                            return .failure(reason)
                        }
                    }
                    guard hasToken, currentToken.hasSuffix("@") else {
                        return .failure("brace grouping '{ ... }' is not allowed in read-only mode")
                    }
                    inGitRefBrace = true
                    currentToken.append("{")
                } else if c == "}" {
                    return .failure("unexpected '}' in read-only command")
                } else if c == "#" && !hasToken {
                    // Comment to end of line
                    while i < count && scalars[i] != "\n" && scalars[i] != "\r" {
                        i += 1
                    }
                    continue
                } else if c == "\n" || c == "\r" {
                    if !currentUnit.isEmpty || hasToken {
                        guard commitUnit(requiresNonEmpty: true) else {
                            return .failure("invalid empty command unit")
                        }
                    }
                } else if c == ";" {
                    guard commitUnit(requiresNonEmpty: true) else {
                        return .failure("unexpected ';' in shell command")
                    }
                    pendingBinaryOp = false
                } else if c == "|" {
                    if i + 1 < count && scalars[i + 1] == "|" {
                        guard commitUnit(requiresNonEmpty: true) else {
                            return .failure("unexpected '||'")
                        }
                        pendingBinaryOp = true
                        i += 2
                        continue
                    }
                    if i + 1 < count && scalars[i + 1] == "&" {
                        return .failure("unsupported '|&' redirection operator")
                    }
                    guard commitUnit(requiresNonEmpty: true) else {
                        return .failure("unexpected '|'")
                    }
                    pendingBinaryOp = true
                } else if c == "&" {
                    if i + 1 < count && scalars[i + 1] == "&" {
                        guard commitUnit(requiresNonEmpty: true) else {
                            return .failure("unexpected '&&'")
                        }
                        pendingBinaryOp = true
                        i += 2
                        continue
                    }
                    if !hasToken, i + 1 < count && scalars[i + 1] == ">" {
                        guard let parsed = consumeRedirectionWord(scalars: scalars, startIndex: i + 2),
                              parsed.word == "/dev/null" else {
                            return .failure("output redirection '&>' is only allowed to /dev/null")
                        }
                        i = parsed.nextIndex
                        continue
                    }
                    return .failure("background '&' operator is forbidden in read-only mode")
                } else if c == ">" {
                    if i + 1 < count && scalars[i + 1] == ">" {
                        return .failure("append redirection '>>' is forbidden in read-only mode")
                    }
                    var fd = ""
                    if hasToken && !tokenUsedQuotesOrEscape && (currentToken == "1" || currentToken == "2") {
                        fd = currentToken
                        currentToken = ""
                        hasToken = false
                        tokenUsedQuotesOrEscape = false
                    } else if hasToken {
                        flushToken()
                    }
                    if i + 1 < count && scalars[i + 1] == "&" {
                        guard let target = consumeRedirectionWord(scalars: scalars, startIndex: i + 2) else {
                            return .failure("invalid fd redirection")
                        }
                        guard (fd == "2" && target.word == "1") || (fd == "1" && target.word == "2") else {
                            return .failure("fd redirection '\(fd)>&\(target.word)' is not allowed")
                        }
                        i = target.nextIndex
                        continue
                    }
                    guard fd.isEmpty || fd == "1" || fd == "2",
                          let target = consumeRedirectionWord(scalars: scalars, startIndex: i + 1),
                          target.word == "/dev/null" else {
                        return .failure("write file redirection '>' is forbidden in read-only mode")
                    }
                    i = target.nextIndex
                    continue
                } else if c == "<" {
                    if i + 1 < count && (scalars[i + 1] == "<" || scalars[i + 1] == ">" || scalars[i + 1] == "&") {
                        return .failure("heredoc/read-write redirection is not allowed in read-only mode")
                    }
                    flushToken()
                    guard let target = consumeRedirectionWord(scalars: scalars, startIndex: i + 1),
                          target.word == "/dev/null" else {
                        return .failure("input redirection '<' is only allowed from /dev/null")
                    }
                    i = target.nextIndex
                    continue
                } else if c == " " || c == "\t" {
                    flushToken()
                } else if c == "'" {
                    state = .single
                    hasToken = true
                    tokenUsedQuotesOrEscape = true
                } else if c == "\"" {
                    state = .double
                    hasToken = true
                    tokenUsedQuotesOrEscape = true
                } else if c == "\\" {
                    guard i + 1 < count else {
                        return .failure("trailing backslash escape")
                    }
                    currentToken.append(Character(scalars[i + 1]))
                    hasToken = true
                    tokenUsedQuotesOrEscape = true
                    i += 2
                    continue
                } else {
                    currentToken.append(Character(c))
                    hasToken = true
                }
            }
            i += 1
        }

        guard state == .none else {
            return .failure("unclosed quote in shell command")
        }
        guard !inGitRefBrace else {
            return .failure("unclosed '@{...}' git ref in shell command")
        }
        if hasToken || !currentUnit.isEmpty {
            guard commitUnit(requiresNonEmpty: true) else {
                return .failure("trailing empty shell unit")
            }
        }
        guard !pendingBinaryOp, !units.isEmpty else {
            return .failure("trailing binary operator or empty command")
        }
        return .success(units)
    }

    private enum ReadOnlyControlFrame {
        case forHeader(varName: String, items: [String])
        case forBody(varName: String, previousItems: [String]?)
        case ifCondition(seenElse: Bool)
        case ifBranch(seenElse: Bool)
    }

    private static func isPathOrSafeVarWithinRepo(
        _ rawPath: String,
        repoRoot: URL,
        boundVars: [String: [String]]
    ) -> Bool {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else { return false }
        if !trimmed.contains("$") {
            return isPathWithinRepo(trimmed, repoRoot: repoRoot)
        }

        var varName = ""
        var suffix = ""
        if trimmed.hasPrefix("${"), let closeIdx = trimmed.firstIndex(of: "}") {
            varName = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<closeIdx])
            suffix = String(trimmed[trimmed.index(after: closeIdx)...])
        } else if trimmed.hasPrefix("$") {
            let afterDollar = trimmed.dropFirst()
            let nameEnd = afterDollar.firstIndex { s in
                !((s >= "A" && s <= "Z") || (s >= "a" && s <= "z") || (s >= "0" && s <= "9") || s == "_")
            } ?? afterDollar.endIndex
            varName = String(afterDollar[..<nameEnd])
            suffix = String(afterDollar[nameEnd...])
        } else {
            return false
        }

        guard isSafeShellVariableName(varName),
              !suffix.contains("$"),
              suffix.isEmpty || suffix.hasPrefix("/"),
              let candidateValues = boundVars[varName],
              !candidateValues.isEmpty else {
            return false
        }
        return candidateValues.allSatisfy { base in
            isPathWithinRepo(base + suffix, repoRoot: repoRoot)
        }
    }

    private static func validateReadOnlyUnits(_ units: [[String]], repoRoot: URL) -> Result<Void, ReadOnlyShellRejection> {
        var stack: [ReadOnlyControlFrame] = []
        var boundVars: [String: [String]] = [:]

        for unit in units {
            guard let head = unit.first else { continue }

            // `for <var> in ...` MUST be immediately followed by `do`
            if let top = stack.last, case .forHeader = top, head != "do" {
                return .failure("expected 'do' after 'for ... in ...'")
            }

            switch head {
            case "for":
                guard unit.count >= 3, unit[2] == "in" else {
                    return .failure("malformed 'for' loop: expected 'for <var> in ...'")
                }
                let varName = unit[1]
                guard isSafeShellVariableName(varName) else {
                    return .failure("restricted loop variable '\(varName)' is not allowed in read-only mode")
                }
                let items = Array(unit.dropFirst(3))
                stack.append(.forHeader(varName: varName, items: items))

            case "do":
                guard let top = stack.popLast(), case .forHeader(let varName, let items) = top else {
                    return .failure("unexpected 'do' without matching 'for'")
                }
                let prev = boundVars[varName]
                boundVars[varName] = items
                stack.append(.forBody(varName: varName, previousItems: prev))
                let rest = Array(unit.dropFirst())
                if !rest.isEmpty {
                    if case .failure(let reason) = validateReadOnlySegment(rest, repoRoot: repoRoot, boundVars: &boundVars) {
                        return .failure(reason)
                    }
                }

            case "done":
                guard unit.count == 1 else {
                    return .failure("unexpected tokens after 'done'")
                }
                guard let top = stack.popLast(), case .forBody(let varName, let prev) = top else {
                    return .failure("unexpected 'done' without matching 'do'")
                }
                if let prev {
                    boundVars[varName] = prev
                } else {
                    boundVars.removeValue(forKey: varName)
                }

            case "if":
                let rest = Array(unit.dropFirst())
                guard !rest.isEmpty else {
                    return .failure("empty 'if' condition")
                }
                stack.append(.ifCondition(seenElse: false))
                if case .failure(let reason) = validateReadOnlySegment(rest, repoRoot: repoRoot, boundVars: &boundVars) {
                    return .failure(reason)
                }

            case "then":
                guard let top = stack.popLast(), case .ifCondition(let seenElse) = top else {
                    return .failure("unexpected 'then' without matching 'if'/'elif'")
                }
                stack.append(.ifBranch(seenElse: seenElse))
                let rest = Array(unit.dropFirst())
                if !rest.isEmpty {
                    if case .failure(let reason) = validateReadOnlySegment(rest, repoRoot: repoRoot, boundVars: &boundVars) {
                        return .failure(reason)
                    }
                }

            case "elif":
                guard let top = stack.popLast(), case .ifBranch(seenElse: false) = top else {
                    return .failure("unexpected 'elif' without open 'if' branch")
                }
                let rest = Array(unit.dropFirst())
                guard !rest.isEmpty else {
                    return .failure("empty 'elif' condition")
                }
                stack.append(.ifCondition(seenElse: false))
                if case .failure(let reason) = validateReadOnlySegment(rest, repoRoot: repoRoot, boundVars: &boundVars) {
                    return .failure(reason)
                }

            case "else":
                guard let top = stack.popLast(), case .ifBranch(seenElse: false) = top else {
                    return .failure("unexpected 'else' without matching 'if'")
                }
                stack.append(.ifBranch(seenElse: true))
                let rest = Array(unit.dropFirst())
                if !rest.isEmpty {
                    if case .failure(let reason) = validateReadOnlySegment(rest, repoRoot: repoRoot, boundVars: &boundVars) {
                        return .failure(reason)
                    }
                }

            case "fi":
                guard unit.count == 1 else {
                    return .failure("unexpected tokens after 'fi'")
                }
                guard let top = stack.popLast(), case .ifBranch = top else {
                    return .failure("unexpected 'fi' without matching 'if'")
                }

            case "while", "until", "case", "esac", "select", "function":
                return .failure("shell control construct '\(head)' is not allowed in read-only mode")

            default:
                if case .failure(let reason) = validateReadOnlySegment(unit, repoRoot: repoRoot, boundVars: &boundVars) {
                    return .failure(reason)
                }
            }
        }

        if let unclosed = stack.last {
            switch unclosed {
            case .forHeader, .forBody:
                return .failure("unterminated 'for' loop (missing 'done')")
            case .ifCondition, .ifBranch:
                return .failure("unterminated 'if' conditional (missing 'fi')")
            }
        }
        return .success(())
    }

    private static func validateReadOnlySegment(
        _ segment: [String],
        repoRoot: URL,
        boundVars: inout [String: [String]]
    ) -> Result<Void, ReadOnlyShellRejection> {
        var tokens = segment
        while tokens.first == "!" && tokens.count > 1 {
            tokens.removeFirst()
        }
        guard let rawExe = tokens.first, !rawExe.isEmpty else {
            return .failure("empty command segment")
        }

        // Safe standalone local variable assignment (e.g. `SHA=<40-hex>`)
        if tokens.count == 1 && !rawExe.contains("/") && rawExe.contains("=") {
            if let assigned = parseSafeLocalAssignment(rawExe) {
                boundVars[assigned.name] = [assigned.value]
                return .success(())
            }
            let varName = String(rawExe.prefix(while: { $0 != "=" }))
            return .failure("restricted variable assignment '\(varName)' is not allowed in read-only mode")
        }

        let allowedPrefixes = ["/usr/bin/", "/bin/", "/opt/homebrew/bin/", "/usr/local/bin/"]
        if rawExe.contains("/") {
            guard let matched = allowedPrefixes.first(where: { rawExe.hasPrefix($0) }) else {
                return .failure("executable path '\(rawExe)' is outside allowed system directories")
            }
            let tail = String(rawExe.dropFirst(matched.count))
            guard !tail.isEmpty, !tail.contains("/") else {
                return .failure("executable path '\(rawExe)' is not allowed")
            }
        }
        let exe = (rawExe as NSString).lastPathComponent
        let args = Array(tokens.dropFirst())

        let ok: Bool
        switch exe {
        case "git":
            ok = validateReadOnlyGit(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "sed":
            ok = validateReadOnlySed(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "head", "tail", "wc", "nl", "cut", "uniq", "tr", "fold", "paste":
            ok = validateReadOnlyTextUtil(exe: exe, args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "sort":
            ok = validateReadOnlySort(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "cat", "ls", "stat", "file", "realpath", "readlink", "comm", "rev":
            ok = validateReadOnlyFileInspect(exe: exe, args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "diff":
            ok = validateReadOnlyDiff(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "grep", "rg":
            ok = validateReadOnlySearch(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "find":
            ok = validateReadOnlyFind(args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "test", "[":
            ok = validateReadOnlyTest(exe: exe, args: args, repoRoot: repoRoot, boundVars: boundVars)
        case "echo", "printf", "pwd", "true", "false", "basename", "dirname":
            ok = true
        default:
            return .failure("command '\(exe)' is not allowed in read-only mode")
        }

        if ok {
            return .success(())
        }
        return .failure("arguments or path for '\(exe)' violated read-only policy")
    }

    private static func validateReadOnlySort(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let valueFlags: Set<String> = ["-t", "-k", "-S", "-T"]
        var fileArgs: [String] = []
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                fileArgs.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if tok == "-o" || tok.hasPrefix("-o")
                || tok == "--output" || tok.hasPrefix("--output=")
                || tok == "--compress-program" || tok.hasPrefix("--compress-program=")
                || tok == "--files0-from" || tok.hasPrefix("--files0-from=") {
                return false
            }
            if valueFlags.contains(tok) {
                guard i + 1 < args.count else { return false }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                i += 1
                continue
            }
            fileArgs.append(tok)
            i += 1
        }
        return fileArgs.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlyDiff(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let valueFlags: Set<String> = ["-U", "--unified", "-C", "--context", "-L", "--label", "-I", "-S", "-x", "--exclude"]
        var fileArgs: [String] = []
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                fileArgs.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if tok == "-o" || tok == "--output" || tok.hasPrefix("--output=") || tok.hasPrefix("-o") {
                return false
            }
            if valueFlags.contains(tok) {
                guard i + 1 < args.count else { return false }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                i += 1
                continue
            }
            fileArgs.append(tok)
            i += 1
        }
        return fileArgs.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlyTest(
        exe: String,
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        var checkArgs = args
        if exe == "[" {
            guard checkArgs.last == "]" else { return false }
            checkArgs.removeLast()
        }
        guard !checkArgs.isEmpty else { return false }

        let fileUnaryOps: Set<String> = ["-e", "-f", "-d", "-r", "-w", "-x", "-s", "-L", "-h", "-O", "-G"]
        let strUnaryOps: Set<String> = ["-n", "-z"]
        let binaryOps: Set<String> = ["=", "==", "!=", "-eq", "-ne", "-lt", "-le", "-gt", "-ge"]
        let fileBinaryOps: Set<String> = ["-nt", "-ot", "-ef"]

        var i = 0
        while i < checkArgs.count {
            let tok = checkArgs[i]
            if tok == "!" || tok == "-a" || tok == "-o" {
                i += 1
                continue
            }
            if fileUnaryOps.contains(tok) {
                guard i + 1 < checkArgs.count,
                      isPathOrSafeVarWithinRepo(checkArgs[i + 1], repoRoot: repoRoot, boundVars: boundVars) else {
                    return false
                }
                i += 2
                continue
            }
            if strUnaryOps.contains(tok) {
                guard i + 1 < checkArgs.count else { return false }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                return false
            }
            if i + 2 < checkArgs.count {
                let op = checkArgs[i + 1]
                if binaryOps.contains(op) {
                    i += 3
                    continue
                }
                if fileBinaryOps.contains(op) {
                    guard isPathOrSafeVarWithinRepo(checkArgs[i], repoRoot: repoRoot, boundVars: boundVars),
                          isPathOrSafeVarWithinRepo(checkArgs[i + 2], repoRoot: repoRoot, boundVars: boundVars) else {
                        return false
                    }
                    i += 3
                    continue
                }
            }
            // Bare value expression `[ "$SHA" ]`
            i += 1
        }
        return true
    }

    private static func validateReadOnlyFind(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let forbiddenPredicates: Set<String> = [
            "-exec", "-execdir", "-ok", "-okdir", "-delete",
            "-fprint", "-fprint0", "-fprintf", "-fls",
        ]
        var startPaths: [String] = []
        var collectingPaths = true
        for tok in args {
            let lowered = tok.lowercased()
            if forbiddenPredicates.contains(lowered) || lowered.hasPrefix("-fprint") {
                return false
            }
            if collectingPaths {
                if tok.hasPrefix("-") || tok == "!" || tok == "(" {
                    collectingPaths = false
                } else {
                    startPaths.append(tok)
                }
            }
        }
        return startPaths.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlyGit(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let allowedGlobalFlags: Set<String> = [
            "--no-pager", "-P", "--literal-pathspecs", "--glob-pathspecs",
            "--noglob-pathspecs", "--icase-pathspecs",
        ]
        var idx = 0
        while idx < args.count {
            let tok = args[idx]
            if tok == "-C" {
                guard idx + 1 < args.count else { return false }
                guard isPathOrSafeVarWithinRepo(args[idx + 1], repoRoot: repoRoot, boundVars: boundVars) else { return false }
                idx += 2
            } else if tok.hasPrefix("-C"), tok.count > 2 {
                let dir = String(tok.dropFirst(2))
                guard isPathOrSafeVarWithinRepo(dir, repoRoot: repoRoot, boundVars: boundVars) else { return false }
                idx += 1
            } else if allowedGlobalFlags.contains(tok) {
                idx += 1
            } else if tok.hasPrefix("-") {
                return false
            } else {
                break
            }
        }
        guard idx < args.count else { return false }
        let subcommand = args[idx]
        let subArgs = Array(args[(idx + 1)...])

        let forbiddenExactFlags: Set<String> = [
            "--ext-diff", "--textconv", "--output", "-o",
            "--exec", "--upload-pack", "--receive-pack", "--config-env", "--no-index",
        ]
        let forbiddenPrefixes = [
            "--output=", "--exec=", "--upload-pack=", "--receive-pack=", "--config-env=",
        ]
        for tok in subArgs {
            if forbiddenExactFlags.contains(tok) || forbiddenPrefixes.contains(where: { tok.hasPrefix($0) }) {
                return false
            }
        }

        let readOnlySubcommands: Set<String> = [
            "show", "log", "diff", "status", "rev-parse", "ls-tree", "ls-files",
            "cat-file", "blame", "merge-base", "grep", "describe", "show-ref",
            "shortlog", "rev-list", "diff-tree", "name-rev", "for-each-ref",
            "check-ignore", "count-objects",
        ]
        if readOnlySubcommands.contains(subcommand) {
            return true
        }

        switch subcommand {
        case "branch":
            let mutatingFlags: Set<String> = [
                "-d", "-D", "-m", "-M", "-c", "-C", "-f", "--force", "--delete",
                "--move", "--copy", "--set-upstream-to", "--unset-upstream",
                "--edit-description", "--create-reflog", "-u", "-t", "--track",
            ]
            for tok in subArgs {
                if mutatingFlags.contains(tok) || tok.hasPrefix("--set-upstream-to=") {
                    return false
                }
            }
            if subArgs.isEmpty { return true }
            let readOnlyDisplayFlags: Set<String> = [
                "--list", "-l", "--show-current", "-a", "--all", "-r", "--remotes",
                "-v", "-vv", "--contains", "--no-contains", "--merged", "--no-merged",
            ]
            let displayPrefixes = ["--contains=", "--no-contains=", "--merged=", "--no-merged="]
            return subArgs.contains { tok in
                readOnlyDisplayFlags.contains(tok) || displayPrefixes.contains(where: { tok.hasPrefix($0) })
            }

        case "tag":
            let mutatingFlags: Set<String> = [
                "-a", "-s", "-u", "-d", "-f", "-m", "-F",
                "--delete", "--force", "--sign", "--annotate",
            ]
            for tok in subArgs {
                if mutatingFlags.contains(tok) || tok.hasPrefix("-u") || tok.hasPrefix("-m") || tok.hasPrefix("-F") {
                    return false
                }
            }
            return subArgs.contains { $0 == "-l" || $0 == "--list" }

        case "stash":
            guard let action = subArgs.first else { return false }
            return action == "list" || action == "show"

        case "remote":
            if subArgs.isEmpty || subArgs == ["-v"] || subArgs == ["--verbose"] {
                return true
            }
            guard let action = subArgs.first else { return false }
            return action == "show" || action == "get-url"

        default:
            return false
        }
    }

    private static func isSafeSedPrintScript(_ script: String) -> Bool {
        guard !script.isEmpty,
              !script.contains("\n"),
              !script.contains("\r"),
              script.hasSuffix("p"),
              script.count >= 2 else {
            return false
        }
        return script.dropLast().unicodeScalars.allSatisfy { scalar in
            (scalar >= "0" && scalar <= "9")
                || scalar == "$"
                || scalar == ","
                || scalar == ";"
                || scalar == " "
        }
    }

    private static func validateReadOnlySed(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        var hasQuietFlag = false
        var scripts: [String] = []
        var positionalAfterScripts: [String] = []
        var usedExplicitExpression = false
        var afterDoubleDash = false
        var i = 0

        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                positionalAfterScripts.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if tok == "-i" || tok.hasPrefix("-i") || tok == "--in-place" || tok.hasPrefix("--in-place=")
                || tok == "-f" || tok.hasPrefix("-f") || tok == "--file" || tok.hasPrefix("--file=") {
                return false
            }
            if tok == "-n" || tok == "--quiet" || tok == "--silent" {
                hasQuietFlag = true
                i += 1
            } else if tok == "-e" {
                guard i + 1 < args.count else { return false }
                usedExplicitExpression = true
                scripts.append(args[i + 1])
                i += 2
            } else if tok.hasPrefix("-e"), tok.count > 2 {
                usedExplicitExpression = true
                scripts.append(String(tok.dropFirst(2)))
                i += 1
            } else if tok.hasPrefix("--expression=") {
                usedExplicitExpression = true
                scripts.append(String(tok.dropFirst("--expression=".count)))
                i += 1
            } else if tok.hasPrefix("-") {
                return false
            } else {
                positionalAfterScripts.append(tok)
                i += 1
            }
        }

        guard hasQuietFlag else { return false }
        let fileArgs: [String]
        if usedExplicitExpression {
            fileArgs = positionalAfterScripts
        } else {
            guard let implicitScript = positionalAfterScripts.first else { return false }
            scripts.append(implicitScript)
            fileArgs = Array(positionalAfterScripts.dropFirst())
        }

        guard !scripts.isEmpty, scripts.allSatisfy(isSafeSedPrintScript) else {
            return false
        }
        return fileArgs.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlyTextUtil(
        exe: String,
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let valueFlags: Set<String>
        switch exe {
        case "head": valueFlags = ["-n", "-c", "--lines", "--bytes"]
        case "tail": valueFlags = ["-n", "-c", "-b", "--lines", "--bytes"]
        case "nl": valueFlags = ["-b", "-d", "-f", "-h", "-i", "-l", "-n", "-s", "-v", "-w"]
        case "cut": valueFlags = ["-b", "-c", "-d", "-f"]
        case "uniq": valueFlags = ["-f", "-s", "-w"]
        case "fold": valueFlags = ["-w"]
        case "paste": valueFlags = ["-d"]
        default: valueFlags = [] // wc, tr
        }

        var fileArgs: [String] = []
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                fileArgs.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if tok == "-o" || tok == "--output" || tok.hasPrefix("--output=") || tok.hasPrefix("-o") {
                return false
            }
            if valueFlags.contains(tok) {
                guard i + 1 < args.count else { return false }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                i += 1
                continue
            }
            if exe != "tr" {
                fileArgs.append(tok)
            }
            i += 1
        }
        return fileArgs.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlyFileInspect(
        exe: String,
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let valueFlags: Set<String>
        switch exe {
        case "stat": valueFlags = ["-f", "-t"]
        case "file": valueFlags = ["-m", "-F"]
        case "comm": valueFlags = ["--output-delimiter"]
        default: valueFlags = []
        }

        var fileArgs: [String] = []
        var afterDoubleDash = false
        var i = 0
        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                fileArgs.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if exe == "file" && (tok == "-f" || tok == "--files-from" || tok.hasPrefix("--files-from=")) {
                return false
            }
            if valueFlags.contains(tok) {
                guard i + 1 < args.count else { return false }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                i += 1
                continue
            }
            fileArgs.append(tok)
            i += 1
        }
        return fileArgs.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func validateReadOnlySearch(
        args: [String],
        repoRoot: URL,
        boundVars: [String: [String]] = [:]
    ) -> Bool {
        let valueFlags: Set<String> = [
            "-e", "--regexp", "-A", "-B", "-C", "-m", "--max-count",
            "-g", "--glob", "--iglob", "-t", "--type", "-T", "--type-not",
            "-j", "--threads", "--color", "--colors", "--sort", "--sortr",
            "--max-filesize", "--max-depth", "--context-separator",
        ]
        var hasExplicitPattern = false
        var positional: [String] = []
        var afterDoubleDash = false
        var i = 0

        while i < args.count {
            let tok = args[i]
            if afterDoubleDash {
                positional.append(tok)
                i += 1
                continue
            }
            if tok == "--" {
                afterDoubleDash = true
                i += 1
                continue
            }
            if tok == "--pre" || tok.hasPrefix("--pre=")
                || tok == "--pre-glob" || tok.hasPrefix("--pre-glob=")
                || tok == "--preprocessor" || tok.hasPrefix("--preprocessor=")
                || tok == "--ignore-file" || tok.hasPrefix("--ignore-file=") {
                return false
            }
            if tok == "-f" || tok == "--file" {
                guard i + 1 < args.count, isPathOrSafeVarWithinRepo(args[i + 1], repoRoot: repoRoot, boundVars: boundVars) else {
                    return false
                }
                hasExplicitPattern = true
                i += 2
                continue
            }
            if tok.hasPrefix("--file=") {
                let path = String(tok.dropFirst("--file=".count))
                guard isPathOrSafeVarWithinRepo(path, repoRoot: repoRoot, boundVars: boundVars) else { return false }
                hasExplicitPattern = true
                i += 1
                continue
            }
            if tok.hasPrefix("-e") && tok.count > 2 {
                hasExplicitPattern = true
                i += 1
                continue
            }
            if tok.hasPrefix("--regexp=") {
                hasExplicitPattern = true
                i += 1
                continue
            }
            if valueFlags.contains(tok) {
                guard i + 1 < args.count else { return false }
                if tok == "-e" || tok == "--regexp" {
                    hasExplicitPattern = true
                }
                i += 2
                continue
            }
            if tok.hasPrefix("-") {
                i += 1
                continue
            }
            positional.append(tok)
            i += 1
        }

        let pathCandidates: [String]
        if hasExplicitPattern {
            pathCandidates = positional
        } else {
            // Check any positional arg beyond the pattern, and also guard suspicious path-like first args.
            var candidates: [String] = []
            if let first = positional.first,
               first.hasPrefix("/") || first.hasPrefix("../") || first == ".." || first.hasPrefix("~/") {
                candidates.append(first)
            }
            if positional.count > 1 {
                candidates.append(contentsOf: positional.dropFirst())
            }
            pathCandidates = candidates
        }
        return pathCandidates.allSatisfy { isPathOrSafeVarWithinRepo($0, repoRoot: repoRoot, boundVars: boundVars) }
    }

    private static func extractCommandString(from rawInput: Any?) -> String? {
        if let str = rawInput as? String {
            return str
        }
        guard let dict = rawInput as? [String: Any] else { return nil }
        for key in ["command", "CommandLine", "cmd", "commandLine", "script"] {
            if let cmd = dict[key] as? String {
                if !cmd.contains(" "), let args = dict["args"] as? [String], !args.isEmpty {
                    let quotedArgs = args.map { arg -> String in
                        if arg.contains(" ") || arg.contains("\t") || arg.contains("'") {
                            return "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\")
                                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
                        }
                        return arg
                    }
                    return ([cmd] + quotedArgs).joined(separator: " ")
                }
                return cmd
            }
            if let arr = dict[key] as? [String], !arr.isEmpty {
                return arr.map { arg -> String in
                    if arg.contains(" ") || arg.contains("\t") || arg.contains("'") {
                        return "\"" + arg.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
                    }
                    return arg
                }.joined(separator: " ")
            }
        }
        if let args = dict["args"] as? [String], !args.isEmpty {
            return args.joined(separator: " ")
        }
        return nil
    }

    /// Evaluates an ACP `session/request_permission` payload against the strictly read-only repository policy,
    /// returning `.allow` or `.deny` along with a human- and agent-readable explanation.
    static func evaluateReadOnlyPermission(params: [String: Any]?, repoRoot: URL) -> ACPPermissionDecision {
        let summary = describePermissionTarget(from: params)
        let toolCall = params?["toolCall"] as? [String: Any]
        let kind = ((toolCall?["kind"] as? String) ?? (params?["kind"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let rawInput = toolCall?["rawInput"] ?? params?["rawInput"]
        let locations = (toolCall?["locations"] as? [[String: Any]]) ?? (params?["locations"] as? [[String: Any]])

        if kind == "edit" || kind == "delete" || kind == "move" || kind == "write" || kind == "fetch" || kind == "switch_mode" {
            return .deny(
                summary: summary,
                reason: "tool kind '\(kind ?? "write")' is forbidden in read-only mode"
            )
        }

        if kind == "read" || kind == "search" || kind == "think" {
            var paths: [String] = []
            if let locations {
                for loc in locations {
                    if let p = loc["path"] as? String {
                        paths.append(p)
                    }
                }
            }
            if let dict = rawInput as? [String: Any] {
                let pathKeys = [
                    "path", "file_path", "filePath", "Path",
                    "directory", "dir", "SearchPath", "DirectoryPath",
                    "AbsolutePath", "TargetFile",
                ]
                for key in pathKeys {
                    if let p = dict[key] as? String {
                        paths.append(p)
                    }
                }
            }
            for p in paths where !isPathWithinRepo(p, repoRoot: repoRoot) {
                return .deny(
                    summary: summary,
                    reason: "path '\(p)' is outside repository root '\(repoRoot.standardizedFileURL.path)'"
                )
            }
            return .allow(summary: summary)
        }

        if kind == "execute" {
            guard let command = extractCommandString(from: rawInput)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !command.isEmpty else {
                return .deny(summary: summary, reason: "missing shell command for 'execute' permission request")
            }
            switch evaluateReadOnlyShellCommand(command, repoRoot: repoRoot) {
            case .success:
                return .allow(summary: summary)
            case .failure(let rejection):
                return .deny(summary: summary, reason: rejection.reason)
            }
        }

        if let command = extractCommandString(from: rawInput)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            switch evaluateReadOnlyShellCommand(command, repoRoot: repoRoot) {
            case .success:
                return .allow(summary: summary)
            case .failure(let rejection):
                return .deny(summary: summary, reason: rejection.reason)
            }
        }

        return .deny(
            summary: summary,
            reason: "tool kind '\(kind ?? "unknown")' is not permitted in read-only mode"
        )
    }

    /// Evaluates an ACP `session/request_permission` payload against the strictly read-only repository policy.
    static func isReadOnlyPermissionAllowed(params: [String: Any]?, repoRoot: URL) -> Bool {
        evaluateReadOnlyPermission(params: params, repoRoot: repoRoot).isAllowed
    }

    /// Builds the official ACP `RequestPermissionResponse` JSON-RPC frame for `session/request_permission`.
    static func makePermissionReply(id: Any, params: [String: Any]?, repoRoot: URL) -> [String: Any] {
        let allowed = isReadOnlyPermissionAllowed(params: params, repoRoot: repoRoot)
        let options = (params?["options"] as? [[String: Any]]) ?? []

        func optionID(matchingPreferredKinds kinds: [String], nameKeyword: (String) -> Bool) -> String? {
            for preferredKind in kinds {
                for option in options {
                    if (option["kind"] as? String) == preferredKind,
                       let oid = (option["optionId"] as? String) ?? (option["id"] as? String),
                       !oid.isEmpty {
                        return oid
                    }
                }
            }
            for option in options {
                if let oid = (option["optionId"] as? String) ?? (option["id"] as? String),
                   !oid.isEmpty,
                   nameKeyword(oid.lowercased()) {
                    return oid
                }
            }
            return nil
        }

        let selectedOptionID: String?
        if allowed {
            selectedOptionID = optionID(matchingPreferredKinds: ["allow_once", "allow_always"]) {
                $0.contains("allow")
            }
        } else {
            selectedOptionID = optionID(matchingPreferredKinds: ["reject_once", "reject_always"]) {
                $0.contains("reject") || $0.contains("deny")
            }
        }

        let outcome: [String: Any]
        if let selectedOptionID {
            outcome = [
                "outcome": "selected",
                "optionId": selectedOptionID,
            ]
        } else {
            outcome = [
                "outcome": "cancelled",
            ]
        }

        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "outcome": outcome,
            ] as [String: Any],
        ]
    }

    private static func jsonRPCErrorReply(id: Any, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
    }

    private static func integerParam(_ value: Any?) -> Int? {
        if let intVal = value as? Int { return intVal }
        if let num = value as? NSNumber {
            if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
            return num.intValue
        }
        if let str = value as? String { return Int(str) }
        return nil
    }

    /// Handles an ACP `fs/read_text_file` server request, enforcing repository containment and optional line/limit slicing.
    static func makeReadTextFileReply(
        id: Any,
        params: [String: Any]?,
        repoRoot: URL,
        maxBytes: Int = maxReadTextFileBytes
    ) -> [String: Any] {
        guard let rawPath = (params?["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return jsonRPCErrorReply(id: id, code: -32602, message: "Missing path parameter")
        }
        guard isPathWithinRepo(rawPath, repoRoot: repoRoot) else {
            return jsonRPCErrorReply(id: id, code: -32602, message: "Access denied: path is outside repository root")
        }

        let resolvedPath = canonicalizedPath(rawPath, relativeTo: repoRoot)
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: resolvedPath),
              (attrs[.type] as? FileAttributeType) == .typeRegular else {
            return jsonRPCErrorReply(id: id, code: -32002, message: "File not found or not a regular file: \(rawPath)")
        }
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard fileSize <= maxBytes else {
            return jsonRPCErrorReply(id: id, code: -32002, message: "File exceeds readable size limit (\(fileSize) bytes)")
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: resolvedPath)) else {
            return jsonRPCErrorReply(id: id, code: -32002, message: "Unable to read file: \(rawPath)")
        }
        guard !TextCodec.looksBinary(data) else {
            return jsonRPCErrorReply(id: id, code: -32002, message: "Cannot read binary file as text: \(rawPath)")
        }

        let decoded = TextCodec.decode(data)
        let lineParam = integerParam(params?["line"])
        let limitParam = integerParam(params?["limit"])
        let content: String
        if lineParam != nil || limitParam != nil {
            let lines = TextCodec.splitLines(decoded)
            let startLine = max(1, lineParam ?? 1)
            let startIndex = startLine - 1
            if startIndex >= lines.count {
                content = ""
            } else {
                let endIndex: Int
                if let limitParam {
                    endIndex = min(lines.count, startIndex + max(0, limitParam))
                } else {
                    endIndex = lines.count
                }
                content = lines[startIndex..<endIndex].joined(separator: "\n")
            }
        } else {
            content = decoded
        }

        return [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "content": content,
            ] as [String: Any],
        ]
    }

    /// Routes an ACP server-initiated JSON-RPC request according to `toolAccess`.
    static func handleServerRequest(
        id: Any,
        method: String,
        params: [String: Any]?,
        repoRoot: URL,
        toolAccess: AgentToolAccess
    ) -> [String: Any] {
        guard toolAccess == .readOnly else {
            return makeUnsupportedServerRequestReply(id: id)
        }
        switch method {
        case "session/request_permission":
            return makePermissionReply(id: id, params: params, repoRoot: repoRoot)
        case "fs/read_text_file":
            return makeReadTextFileReply(id: id, params: params, repoRoot: repoRoot)
        default:
            return makeUnsupportedServerRequestReply(id: id)
        }
    }

    // MARK: Live Execution

    /// Starts an ACP session, fetches models via `session/new`, closes the session, and returns the models.
    static func listModels(
        provider: AgentProvider,
        executable: String,
        arguments: [String]? = nil,
        cwd: URL,
        environment: [String: String],
        timeout: TimeInterval = 15,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> [AgentModel] {
        let args = arguments ?? defaultArguments(for: provider, executable: executable)
        return try await NDJSONProcessSession.run(
            provider: provider,
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            killGracePeriod: killGracePeriod
        ) { session in
            try session.sendJSON(makeInitializeRequest(id: 1))
            let initResp = try waitForResponse(id: 1, session: session, provider: provider)
            if let err = parseRPCError(from: initResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: "initialize failed: \(err.message)")
            }

            try session.sendJSON(makeSessionNewRequest(id: 2, cwd: cwd.path))
            let newResp = try waitForResponse(id: 2, session: session, provider: provider)
            if let err = parseRPCError(from: newResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: "session/new failed: \(err.message)")
            }
            guard let result = newResp["result"] as? [String: Any] else {
                throw LocalAgentError.protocolError(provider: provider, detail: "session/new returned no result")
            }

            let models = parseSessionNewModels(from: result, provider: provider)
            if let sessionId = result["sessionId"] as? String {
                try? session.sendJSON(makeSessionCloseRequest(id: 3, sessionId: sessionId))
            }
            _ = session.finish(graceSeconds: 0.8, terminateIfStillRunning: true)
            return models
        }
    }

    private static func describePermissionTarget(from params: [String: Any]?) -> String {
        let toolCall = params?["toolCall"] as? [String: Any]
        let kind = ((toolCall?["kind"] as? String) ?? (params?["kind"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = (toolCall?["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawInput = toolCall?["rawInput"] ?? params?["rawInput"]
        if let cmd = extractCommandString(from: rawInput)?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
            let singleLine = cmd.replacingOccurrences(of: "\n", with: " ; ")
            let clipped = singleLine.count > 120 ? String(singleLine.prefix(120)) + "…" : singleLine
            return kind.map { "\($0): \(clipped)" } ?? clipped
        }
        if let dict = rawInput as? [String: Any],
           let path = (dict["path"] as? String) ?? (dict["file_path"] as? String) ?? (dict["filePath"] as? String) {
            return kind.map { "\($0): \(path)" } ?? path
        }
        if let title, !title.isEmpty {
            return kind.map { "\($0): \(title)" } ?? title
        }
        return kind ?? "tool"
    }

    /// Runs a full ACP turn (`initialize` -> `session/new` or `session/resume`/`load` -> optional `session/set_model` -> `session/prompt` -> `session/close`).
    static func generate(
        provider: AgentProvider,
        executable: String,
        arguments: [String]? = nil,
        cwd: URL,
        model: String?,
        prompt: String,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
        try await generateWithSession(
            provider: provider,
            executable: executable,
            arguments: arguments,
            cwd: cwd,
            model: model,
            prompt: prompt,
            environment: environment,
            toolAccess: toolAccess,
            resumeSessionID: nil,
            timeout: timeout,
            maxTotalTimeout: maxTotalTimeout,
            killGracePeriod: killGracePeriod,
            onEvent: nil
        ).text
    }

    private static func makePermissionDeniedRecoveryPrompt(
        blocked: [(summary: String, reason: String)]
    ) -> String {
        let items = blocked.map { "- `\($0.summary)` — \($0.reason)" }.joined(separator: "\n")
        return """
        [DiffCode Read-Only Policy Notice]
        The previous tool call(s) failed and were NOT executed because DiffCode enforces strict read-only repository inspection:
        \(items)

        Do not treat this as a cancellation of the overall task, and do not retry the blocked command or attempt file writes/mutations.
        Continue your analysis using the existing session context, either with simple allowed read-only commands (`git show <sha>:<path>`, `git log`, `git grep`, `rg`, `nl -ba`, `sed -n`) or directly from the diff/context already provided, and output your complete final response now.
        """
    }

    /// Runs a streaming/resumable ACP turn and returns both the final assistant response and `sessionId`.
    static func generateWithSession(
        provider: AgentProvider,
        executable: String,
        arguments: [String]? = nil,
        cwd: URL,
        model: String?,
        prompt: String,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        resumeSessionID: String? = nil,
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod,
        maxPermissionDeniedRecoveries: Int = 3,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AgentGenerateResult {
        let args = arguments ?? defaultArguments(for: provider, executable: executable)
        return try await NDJSONProcessSession.run(
            provider: provider,
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            maxTotalTimeout: maxTotalTimeout,
            killGracePeriod: killGracePeriod
        ) { session in
            var nextId = 1
            var attemptDenied: [(summary: String, reason: String)] = []
            var lastDeniedPermission: (summary: String, reason: String)? = nil
            let serverRequestHandler: (Any, String, [String: Any]?) -> [String: Any] = { reqId, method, params in
                let reply = handleServerRequest(
                    id: reqId,
                    method: method,
                    params: params,
                    repoRoot: cwd,
                    toolAccess: toolAccess
                )
                if toolAccess == .readOnly {
                    if method == "session/request_permission" {
                        switch evaluateReadOnlyPermission(params: params, repoRoot: cwd) {
                        case .allow(let summary):
                            onEvent?(.statusNote("Approved read-only \(summary)"))
                        case .deny(let summary, let reason):
                            attemptDenied.append((summary, reason))
                            lastDeniedPermission = (summary, reason)
                            onEvent?(.statusNote("Blocked (\(reason)): \(summary)"))
                        }
                    } else if method == "fs/read_text_file",
                              let path = (params?["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !path.isEmpty {
                        if reply["error"] != nil {
                            onEvent?(.statusNote("Denied fs/read_text_file: \(path)"))
                        } else {
                            onEvent?(.statusNote("Read file: \(path)"))
                        }
                    }
                }
                return reply
            }

            // 1. initialize
            let initId = nextId; nextId += 1
            try session.sendJSON(makeInitializeRequest(id: initId, toolAccess: toolAccess))
            let initResp = try waitForResponse(
                id: initId,
                session: session,
                provider: provider,
                onServerRequest: serverRequestHandler
            )
            if let err = parseRPCError(from: initResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: "initialize failed: \(err.message)")
            }

            // 2. session/new or session/resume (-> session/load fallback)
            let sessionId: String
            if let resumeID = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resumeID.isEmpty {
                let resumeReqId = nextId; nextId += 1
                try session.sendJSON(makeSessionResumeRequest(id: resumeReqId, sessionId: resumeID, cwd: cwd.path))
                let resumeResp = try waitForResponse(
                    id: resumeReqId,
                    session: session,
                    provider: provider,
                    onServerRequest: serverRequestHandler,
                    onNotification: nil
                )
                if parseRPCError(from: resumeResp) == nil {
                    sessionId = ((resumeResp["result"] as? [String: Any])?["sessionId"] as? String) ?? resumeID
                } else {
                    let loadReqId = nextId; nextId += 1
                    try session.sendJSON(makeSessionLoadRequest(id: loadReqId, sessionId: resumeID, cwd: cwd.path))
                    let loadResp = try waitForResponse(
                        id: loadReqId,
                        session: session,
                        provider: provider,
                        onServerRequest: serverRequestHandler,
                        onNotification: nil
                    )
                    if let loadErr = parseRPCError(from: loadResp) {
                        throw LocalAgentError.protocolError(provider: provider, detail: "session resume/load failed: \(loadErr.message)")
                    }
                    sessionId = ((loadResp["result"] as? [String: Any])?["sessionId"] as? String) ?? resumeID
                }
            } else {
                let newId = nextId; nextId += 1
                try session.sendJSON(makeSessionNewRequest(id: newId, cwd: cwd.path))
                let newResp = try waitForResponse(
                    id: newId,
                    session: session,
                    provider: provider,
                    onServerRequest: serverRequestHandler
                )
                if let err = parseRPCError(from: newResp) {
                    throw LocalAgentError.protocolError(provider: provider, detail: "session/new failed: \(err.message)")
                }
                guard let newResult = newResp["result"] as? [String: Any],
                      let createdID = newResult["sessionId"] as? String,
                      !createdID.isEmpty else {
                    throw LocalAgentError.protocolError(provider: provider, detail: "session/new returned no sessionId")
                }
                sessionId = createdID
            }
            onEvent?(.sessionStarted(sessionId))

            // 3. session/set_model (optional)
            if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
                let setModelId = nextId; nextId += 1
                try session.sendJSON(makeSetModelRequest(id: setModelId, sessionId: sessionId, modelId: trimmedModel))
                let setModelResp = try waitForResponse(
                    id: setModelId,
                    session: session,
                    provider: provider,
                    onServerRequest: serverRequestHandler
                )
                if let err = parseRPCError(from: setModelResp) {
                    if err.code == -32601 {
                        // Fallback for ACP servers that expose model selection via config options.
                        let cfgId = nextId; nextId += 1
                        try session.sendJSON(makeSetConfigOptionRequest(
                            id: cfgId,
                            sessionId: sessionId,
                            configId: "model",
                            value: trimmedModel
                        ))
                        let cfgResp = try waitForResponse(
                            id: cfgId,
                            session: session,
                            provider: provider,
                            onServerRequest: serverRequestHandler
                        )
                        if let cfgErr = parseRPCError(from: cfgResp) {
                            throw LocalAgentError.protocolError(provider: provider, detail: "set model failed: \(cfgErr.message)")
                        }
                    } else {
                        throw LocalAgentError.protocolError(provider: provider, detail: "session/set_model failed: \(err.message)")
                    }
                }
            }

            // 4. session/prompt (with non-blocking soft-denial recovery on the same cached session)
            var currentPrompt = prompt
            var recoveryCount = 0
            var finalOutput = ""
            var finalResp: [String: Any] = [:]

            while true {
                attemptDenied.removeAll(keepingCapacity: true)
                let promptId = nextId; nextId += 1
                try session.sendJSON(makeSessionPromptRequest(id: promptId, sessionId: sessionId, prompt: currentPrompt))

                var attemptCollected = ""
                var attemptCurrentSegment = ""
                var attemptLastNonEmptySegment = ""
                var attemptSawToolCall = false
                let promptResp = try waitForResponse(
                    id: promptId,
                    session: session,
                    provider: provider,
                    onServerRequest: serverRequestHandler
                ) { frame in
                    if let thought = extractAgentThoughtChunk(from: frame) {
                        onEvent?(.thinkingDelta(thought))
                    } else if let toolEvent = extractToolCallEvent(from: frame) {
                        if extractSessionUpdateKind(from: frame) == "tool_call" {
                            attemptSawToolCall = true
                            if !attemptCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                attemptLastNonEmptySegment = attemptCurrentSegment
                            }
                            attemptCurrentSegment = ""
                        }
                        onEvent?(toolEvent)
                    } else if let chunk = extractAgentMessageChunk(from: frame) {
                        attemptCollected.append(chunk)
                        attemptCurrentSegment.append(chunk)
                        onEvent?(.messageDelta(chunk))
                    }
                }

                finalResp = promptResp
                if parseRPCError(from: promptResp) != nil {
                    break
                }

                let attemptOutput: String
                if toolAccess != .disabled && attemptSawToolCall {
                    if !attemptCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        attemptOutput = attemptCurrentSegment
                    } else if !attemptLastNonEmptySegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        attemptOutput = attemptLastNonEmptySegment
                    } else {
                        attemptOutput = attemptCollected
                    }
                } else {
                    attemptOutput = attemptCollected
                }

                let stopReason = (promptResp["result"] as? [String: Any])?["stopReason"] as? String
                let postToolEmpty = attemptSawToolCall && attemptCurrentSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let interruptedByDenial = toolAccess == .readOnly
                    && !attemptDenied.isEmpty
                    && (attemptOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || stopReason == "cancelled"
                        || postToolEmpty)

                if interruptedByDenial,
                   recoveryCount < maxPermissionDeniedRecoveries,
                   !session.isCancelled,
                   !session.isTimedOut,
                   let latestDenial = attemptDenied.last {
                    recoveryCount += 1
                    onEvent?(.statusNote("Tool call blocked (\(latestDenial.reason)); instructing agent to continue without it (\(recoveryCount)/\(maxPermissionDeniedRecoveries))…"))
                    currentPrompt = makePermissionDeniedRecoveryPrompt(blocked: attemptDenied)
                    continue
                }

                finalOutput = attemptOutput
                break
            }

            // 5. session/close
            let closeId = nextId; nextId += 1
            try? session.sendJSON(makeSessionCloseRequest(id: closeId, sessionId: sessionId))
            _ = session.finish(graceSeconds: 1.0, terminateIfStillRunning: true)

            if let err = parseRPCError(from: finalResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: err.message)
            }

            if finalOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let denied = lastDeniedPermission {
                    throw LocalAgentError.protocolError(
                        provider: provider,
                        detail: "Read-only policy rejected tool call (\(denied.summary)): \(denied.reason)"
                    )
                }
                if let result = finalResp["result"] as? [String: Any],
                   let stopReason = result["stopReason"] as? String,
                   stopReason != "end_turn" && stopReason != "max_tokens" {
                    throw LocalAgentError.protocolError(provider: provider, detail: "Stopped with reason: \(stopReason)")
                }
                throw LocalAgentError.emptyResponse(provider)
            }

            return AgentGenerateResult(text: finalOutput, sessionID: sessionId)
        }
    }

    private static func waitForResponse(
        id targetId: Int,
        session: NDJSONProcessSession,
        provider: AgentProvider,
        onServerRequest: ((_ id: Any, _ method: String, _ params: [String: Any]?) -> [String: Any])? = nil,
        onNotification: (([String: Any]) -> Void)? = nil
    ) throws -> [String: Any] {
        while let frame = session.readNextJSONObject() {
            if let rawId = rawJSONRPCID(from: frame) {
                if let method = frame["method"] as? String {
                    let reply = onServerRequest?(rawId, method, frame["params"] as? [String: Any])
                        ?? makeUnsupportedServerRequestReply(id: rawId)
                    try? session.sendJSON(reply)
                    continue
                }
                if frame["method"] != nil {
                    try? session.sendJSON(makeUnsupportedServerRequestReply(id: rawId))
                    continue
                }
                if jsonRPCID(from: frame) == targetId {
                    return frame
                }
                continue
            }
            onNotification?(frame)
        }

        if session.isCancelled {
            throw CancellationError()
        }
        if session.isTimedOut {
            throw LocalAgentError.timedOut(provider)
        }
        throw LocalAgentError.protocolError(provider: provider, detail: "ACP connection closed before response #\(targetId)")
    }
}

// MARK: - Claude CLI Adapter

/// Adapter for Claude Code CLI (`claude`).
/// - Model listing uses `stream-json` `control_request: initialize` (fast, zero tokens, safe-mode enabled).
/// - Prompt execution uses `claude -p --output-format json` without `--safe-mode` or `--bare` so user settings/proxies work.
enum ClaudeCLIAdapter {
    static let defaultListModelsTimeout: TimeInterval = 8.0

    static func listModelsArguments() -> [String] {
        [
            "-p",
            "--safe-mode",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--no-session-persistence",
            "--tools", "",
        ]
    }

    /// Read-only inspection tools and read-only git commands whitelisted for AI Code Review.
    static let readOnlyAllowedTools: [String] = [
        "Read",
        "Grep",
        "Glob",
        "Bash(git status)",
        "Bash(git status *)",
        "Bash(git show *)",
        "Bash(git log *)",
        "Bash(git diff *)",
        "Bash(git rev-parse *)",
        "Bash(git ls-tree *)",
        "Bash(git ls-files *)",
        "Bash(git cat-file *)",
        "Bash(git blame *)",
        "Bash(git merge-base *)",
        "Bash(git grep *)",
        "Bash(git describe *)",
        "Bash(git show-ref *)",
        "Bash(git shortlog *)",
        "Bash(git rev-list *)",
        "Bash(git diff-tree *)",
        "Bash(git name-rev *)",
        "Bash(git for-each-ref *)",
        "Bash(git branch --show-current)",
        "Bash(git branch --list *)",
        "Bash(git tag -l *)",
        "Bash(git stash list)",
        "Bash(git stash show *)",
    ]

    static func generateArguments(
        model: String?,
        jsonSchema: String?,
        toolAccess: AgentToolAccess = .disabled,
        streaming: Bool = false,
        resumeSessionID: String? = nil,
        persistSession: Bool = false
    ) -> [String] {
        // IMPORTANT: Do NOT pass `--safe-mode` or `--bare` during prompt execution, as they skip
        // `~/.claude/settings.json` (user proxy/environment settings).
        var args = ["-p"]
        if streaming {
            args += ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
        } else {
            args += ["--output-format", "json"]
        }
        let trimmedResume = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !persistSession && (trimmedResume?.isEmpty ?? true) {
            args += ["--no-session-persistence"]
        }
        args += ["--disable-slash-commands"]
        if let trimmedResume, !trimmedResume.isEmpty {
            args += ["--resume", trimmedResume]
        }
        if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
            args += ["--model", trimmedModel]
        }
        if let trimmedSchema = jsonSchema?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedSchema.isEmpty {
            args += ["--json-schema", trimmedSchema]
        }
        switch toolAccess {
        case .disabled:
            args += ["--tools", ""]
        case .readOnly:
            // Keep `--model` / `--json-schema` before variadic `<tools...>` flags so arguments are never swallowed.
            args += [
                "--permission-mode", "dontAsk",
                "--tools", "Read,Grep,Glob,Bash",
                "--disallowedTools", "Edit,Write,NotebookEdit,WebFetch,WebSearch",
                "--allowedTools", readOnlyAllowedTools.joined(separator: ","),
            ]
        }
        return args
    }

    static func makeControlInitializeRequest(requestId: String = "1") -> [String: Any] {
        [
            "type": "control_request",
            "request_id": requestId,
            "request": [
                "subtype": "initialize",
            ],
        ]
    }

    /// Parses Claude `control_response` JSON object into `[AgentModel]`.
    static func parseControlResponseModels(from frame: [String: Any]) -> [AgentModel]? {
        guard (frame["type"] as? String) == "control_response",
              let outerResponse = frame["response"] as? [String: Any] else {
            return nil
        }
        let innerResponse = (outerResponse["response"] as? [String: Any]) ?? outerResponse
        guard let rawModels = innerResponse["models"] as? [[String: Any]] else {
            return nil
        }

        var models: [AgentModel] = []
        var seen: Set<String> = []
        for item in rawModels {
            guard let value = (item["value"] as? String) ?? (item["id"] as? String),
                  !value.isEmpty,
                  seen.insert(value).inserted else { continue }
            let displayName = (item["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = (item["resolvedModel"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if let displayName, !displayName.isEmpty {
                name = displayName
            } else if let resolvedModel, !resolvedModel.isEmpty {
                name = resolvedModel
            } else {
                name = value
            }
            models.append(AgentModel(
                id: value,
                name: name,
                provider: .claude,
                isDefault: value == "default"
            ))
        }
        return models
    }

    /// Parses stdout from `claude -p --output-format json`.
    /// Prefers `structured_output` when present (e.g. with `--json-schema`), otherwise falls back to `result`.
    static func parseGenerateOutput(_ data: Data, hasSchema: Bool) throws -> String {
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LocalAgentError.emptyResponse(.claude)
        }

        let jsonObject: [String: Any]
        if let parsed = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []) as? [String: Any] {
            jsonObject = parsed
        } else if let lastLineObj = parseLastJSONObjectLine(from: trimmed) {
            jsonObject = lastLineObj
        } else {
            throw LocalAgentError.protocolError(provider: .claude, detail: "Invalid JSON response from claude CLI")
        }

        if let isError = jsonObject["is_error"] as? Bool, isError {
            let detail = (jsonObject["result"] as? String)
                ?? (jsonObject["error"] as? String)
                ?? "Claude CLI reported is_error=true"
            throw LocalAgentError.protocolError(provider: .claude, detail: detail)
        }

        if let structured = jsonObject["structured_output"], !(structured is NSNull) {
            if let text = structured as? String {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            } else if JSONSerialization.isValidJSONObject(structured),
                      let encoded = try? JSONSerialization.data(withJSONObject: structured, options: []) {
                let text = String(decoding: encoded, as: UTF8.self)
                if !text.isEmpty {
                    return text
                }
            }
        }

        if let result = jsonObject["result"] as? String,
           !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return result
        }

        if hasSchema {
            throw LocalAgentError.protocolError(provider: .claude, detail: "Missing structured_output in claude response")
        }
        throw LocalAgentError.emptyResponse(.claude)
    }

    private static func parseLastJSONObjectLine(from text: String) -> [String: Any]? {
        for line in text.split(separator: "\n").reversed() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(candidate.utf8), options: []) as? [String: Any] else {
                continue
            }
            return obj
        }
        return nil
    }

    static func listModels(
        executable: String,
        cwd: URL,
        environment: [String: String],
        timeout: TimeInterval = defaultListModelsTimeout,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> [AgentModel] {
        try await NDJSONProcessSession.run(
            provider: .claude,
            executable: executable,
            arguments: listModelsArguments(),
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            killGracePeriod: killGracePeriod
        ) { session in
            try session.sendJSON(makeControlInitializeRequest(requestId: "1"))
            while let frame = session.readNextJSONObject() {
                if let models = parseControlResponseModels(from: frame) {
                    _ = session.finish(graceSeconds: 0.3, terminateIfStillRunning: true)
                    return models
                }
                if (frame["type"] as? String) == "control_response",
                   let resp = frame["response"] as? [String: Any],
                   (resp["subtype"] as? String) == "error" {
                    let msg = (resp["error"] as? String) ?? "control_request initialize failed"
                    throw LocalAgentError.protocolError(provider: .claude, detail: msg)
                }
            }
            if session.isCancelled { throw CancellationError() }
            if session.isTimedOut { throw LocalAgentError.timedOut(.claude) }
            throw LocalAgentError.protocolError(provider: .claude, detail: "Claude stream ended before control_response")
        }
    }

    static func generate(
        executable: String,
        cwd: URL,
        model: String?,
        prompt: String,
        jsonSchema: String?,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
        try await generateWithSession(
            executable: executable,
            cwd: cwd,
            model: model,
            prompt: prompt,
            jsonSchema: jsonSchema,
            environment: environment,
            toolAccess: toolAccess,
            resumeSessionID: nil,
            persistSession: false,
            timeout: timeout,
            killGracePeriod: killGracePeriod,
            onEvent: nil
        ).text
    }

    /// Parses one `stream-json` NDJSON object from Claude Code CLI, updating stream deduplication state and returning final result text if `type == "result"`.
    static func parseStreamEventFrame(
        _ frame: [String: Any],
        hasSchema: Bool,
        sessionID: inout String?,
        sawPartialText: inout Bool,
        sawPartialThinking: inout Bool,
        assistantTexts: inout [String],
        onEvent: AgentStreamHandler?
    ) throws -> String? {
        if let sid = frame["session_id"] as? String, !sid.isEmpty, sessionID == nil {
            sessionID = sid
            onEvent?(.sessionStarted(sid))
        }

        let frameType = frame["type"] as? String
        switch frameType {
        case "stream_event":
            guard let event = frame["event"] as? [String: Any],
                  let eventType = event["type"] as? String else {
                return nil
            }
            if eventType == "content_block_delta", let delta = event["delta"] as? [String: Any] {
                let deltaType = delta["type"] as? String
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    sawPartialText = true
                    onEvent?(.messageDelta(text))
                } else if deltaType == "thinking_delta", let thinking = delta["thinking"] as? String {
                    sawPartialThinking = true
                    onEvent?(.thinkingDelta(thinking))
                }
            } else if eventType == "content_block_start",
                      let block = event["content_block"] as? [String: Any],
                      (block["type"] as? String) == "tool_use" {
                let id = (block["id"] as? String) ?? "claude-tool-\(UUID().uuidString)"
                let name = (block["name"] as? String) ?? "tool"
                let input = ACPTransport.formatCompactToolPayload(block["input"])
                onEvent?(.toolActivity(id: id, title: name, kind: nil, input: input, status: "running", output: nil))
            }
            return nil

        case "assistant":
            defer {
                sawPartialText = false
                sawPartialThinking = false
            }
            guard let message = frame["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else {
                return nil
            }
            var turnText = ""
            for part in content {
                switch part["type"] as? String {
                case "thinking":
                    if !sawPartialThinking, let thinking = part["thinking"] as? String, !thinking.isEmpty {
                        onEvent?(.thinkingDelta(thinking))
                    }
                case "text":
                    if let text = part["text"] as? String {
                        turnText.append(text)
                        if !sawPartialText, !text.isEmpty {
                            onEvent?(.messageDelta(text))
                        }
                    }
                case "tool_use":
                    let id = (part["id"] as? String) ?? "claude-tool-\(UUID().uuidString)"
                    let name = (part["name"] as? String) ?? "tool"
                    let input = ACPTransport.formatCompactToolPayload(part["input"])
                    onEvent?(.toolActivity(id: id, title: name, kind: nil, input: input, status: "running", output: nil))
                default:
                    break
                }
            }
            if !turnText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                assistantTexts.append(turnText)
            }
            return nil

        case "user":
            if let message = frame["message"] as? [String: Any],
               let content = message["content"] as? [[String: Any]] {
                for part in content where (part["type"] as? String) == "tool_result" {
                    guard let id = part["tool_use_id"] as? String, !id.isEmpty else { continue }
                    let isError = (part["is_error"] as? Bool) ?? false
                    let output = ACPTransport.formatCompactToolPayload(part["content"])
                    onEvent?(.toolActivity(
                        id: id,
                        title: "",
                        kind: nil,
                        input: nil,
                        status: isError ? "failed" : "completed",
                        output: output
                    ))
                }
            }
            return nil

        case "result":
            if let isError = frame["is_error"] as? Bool, isError {
                let detail = (frame["result"] as? String)
                    ?? (frame["error"] as? String)
                    ?? "Claude CLI reported is_error=true"
                throw LocalAgentError.protocolError(provider: .claude, detail: detail)
            }
            if let structured = frame["structured_output"], !(structured is NSNull) {
                if let text = structured as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
                if JSONSerialization.isValidJSONObject(structured),
                   let encoded = try? JSONSerialization.data(withJSONObject: structured, options: []) {
                    let text = String(decoding: encoded, as: UTF8.self)
                    if !text.isEmpty { return text }
                }
            }
            if let result = frame["result"] as? String, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result
            }
            if !hasSchema, let last = assistantTexts.last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return last
            }
            if hasSchema {
                throw LocalAgentError.protocolError(provider: .claude, detail: "Missing structured_output in claude response")
            }
            throw LocalAgentError.emptyResponse(.claude)

        default:
            return nil
        }
    }

    static func generateWithSession(
        executable: String,
        cwd: URL,
        model: String?,
        prompt: String,
        jsonSchema: String?,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        resumeSessionID: String? = nil,
        persistSession: Bool = false,
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AgentGenerateResult {
        if onEvent == nil && (resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) && !persistSession {
            let args = generateArguments(
                model: model,
                jsonSchema: jsonSchema,
                toolAccess: toolAccess,
                streaming: false,
                resumeSessionID: nil,
                persistSession: false
            )
            let output = try await AgentSubprocess.runOneShot(
                provider: .claude,
                executable: executable,
                arguments: args,
                environment: environment,
                workingDirectory: cwd,
                stdinData: Data(prompt.utf8),
                timeout: timeout,
                killGracePeriod: killGracePeriod
            )
            if output.status != 0 {
                if let parsed = try? parseGenerateOutput(output.stdout, hasSchema: jsonSchema != nil), !parsed.isEmpty {
                    return AgentGenerateResult(text: parsed, sessionID: nil)
                }
                let stderrText = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let stdoutText = String(decoding: output.stdout.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderrText.isEmpty ? stdoutText : stderrText
                throw LocalAgentError.executionFailed(provider: .claude, status: output.status, stderr: detail)
            }
            let text = try parseGenerateOutput(output.stdout, hasSchema: jsonSchema != nil)
            return AgentGenerateResult(text: text, sessionID: nil)
        }

        let hasSchema = jsonSchema != nil
        let args = generateArguments(
            model: model,
            jsonSchema: jsonSchema,
            toolAccess: toolAccess,
            streaming: true,
            resumeSessionID: resumeSessionID,
            persistSession: persistSession
        )
        return try await NDJSONProcessSession.run(
            provider: .claude,
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            killGracePeriod: killGracePeriod
        ) { session in
            session.writeStdinAndCloseAsync(Data(prompt.utf8))
            var capturedSessionID = resumeSessionID
            var sawPartialText = false
            var sawPartialThinking = false
            var assistantTexts: [String] = []
            var finalResultText: String? = nil

            while let frame = session.readNextJSONObject() {
                if let resultText = try parseStreamEventFrame(
                    frame,
                    hasSchema: hasSchema,
                    sessionID: &capturedSessionID,
                    sawPartialText: &sawPartialText,
                    sawPartialThinking: &sawPartialThinking,
                    assistantTexts: &assistantTexts,
                    onEvent: onEvent
                ) {
                    finalResultText = resultText
                }
            }

            let exitInfo = session.finish(graceSeconds: 0.5, terminateIfStillRunning: false)
            if session.isCancelled { throw CancellationError() }
            if session.isTimedOut { throw LocalAgentError.timedOut(.claude) }

            if let finalResultText {
                return AgentGenerateResult(text: finalResultText, sessionID: capturedSessionID)
            }
            if !hasSchema, let last = assistantTexts.last, !last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentGenerateResult(text: last, sessionID: capturedSessionID)
            }
            if exitInfo.status != 0 {
                let detail = exitInfo.stderr.isEmpty ? "Claude CLI exited with status \(exitInfo.status)" : exitInfo.stderr
                throw LocalAgentError.executionFailed(provider: .claude, status: exitInfo.status, stderr: detail)
            }
            throw LocalAgentError.emptyResponse(.claude)
        }
    }
}

// MARK: - Codex CLI Adapter

/// Adapter for OpenAI Codex CLI (`codex`).
/// - Model listing prefers `codex app-server --stdio` (`model/list`), falling back to `~/.codex/models_cache.json`.
/// - Prompt execution runs `codex exec --json --ephemeral --sandbox read-only --skip-git-repo-check -` with stdin prompt.
enum CodexCLIAdapter {
    static let defaultListModelsTimeout: TimeInterval = 10.0

    static var defaultModelsCacheURL: URL {
        URL(fileURLWithPath: (Sandbox.realHome as NSString).appendingPathComponent(".codex/models_cache.json"))
    }

    static func generateArguments(
        model: String?,
        outputSchemaPath: String?,
        toolAccess: AgentToolAccess = .disabled,
        resumeSessionID: String? = nil,
        persistSession: Bool = false
    ) -> [String] {
        let trimmedResume = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var args: [String]
        if let trimmedResume, !trimmedResume.isEmpty {
            args = [
                "exec",
                "resume",
                "--json",
                "--skip-git-repo-check",
            ]
            if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
                args += ["-m", trimmedModel]
            }
            if let outputSchemaPath, !outputSchemaPath.isEmpty {
                args += ["--output-schema", outputSchemaPath]
            }
            if toolAccess == .readOnly {
                args += [
                    "-c", "sandbox_mode=\"read-only\"",
                    "-c", "approval_policy=\"never\"",
                ]
            }
            args += [trimmedResume, "-"]
            return args
        }

        args = [
            "exec",
            "--json",
        ]
        if !persistSession {
            args.append("--ephemeral")
        }
        args += [
            "--sandbox", "read-only",
            "--skip-git-repo-check",
        ]
        if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
            args += ["-m", trimmedModel]
        }
        if let outputSchemaPath, !outputSchemaPath.isEmpty {
            args += ["--output-schema", outputSchemaPath]
        }
        if toolAccess == .readOnly {
            args += ["-c", "approval_policy=\"never\""]
        }
        args.append("-")
        return args
    }

    /// Parses `model/list` JSON-RPC `result` from `codex app-server --stdio`, filtering out `hidden == true`.
    static func parseAppServerModelList(from result: Any) -> [AgentModel] {
        let items: [[String: Any]]
        if let dict = result as? [String: Any] {
            items = (dict["data"] as? [[String: Any]])
                ?? (dict["models"] as? [[String: Any]])
                ?? []
        } else if let array = result as? [[String: Any]] {
            items = array
        } else {
            return []
        }

        var models: [AgentModel] = []
        var seen: Set<String> = []
        for item in items {
            if let hidden = item["hidden"] as? Bool, hidden { continue }
            guard let id = (item["id"] as? String) ?? (item["slug"] as? String),
                  !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            let displayName = (item["displayName"] as? String)
                ?? (item["display_name"] as? String)
                ?? id
            let isDefault = (item["isDefault"] as? Bool) ?? (item["is_default"] as? Bool) ?? false
            models.append(AgentModel(
                id: id,
                name: displayName.isEmpty ? id : displayName,
                provider: .codex,
                isDefault: isDefault
            ))
        }
        return models
    }

    /// Parses `~/.codex/models_cache.json`, filtering `visibility == "list"`.
    static func parseModelsCache(data: Data) -> [AgentModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        let items: [[String: Any]]
        if let dict = root as? [String: Any], let list = dict["models"] as? [[String: Any]] {
            items = list
        } else if let list = root as? [[String: Any]] {
            items = list
        } else {
            return []
        }

        var models: [AgentModel] = []
        var seen: Set<String> = []
        for item in items {
            if let visibility = item["visibility"] as? String, visibility != "list" {
                continue
            }
            if let hidden = item["hidden"] as? Bool, hidden {
                continue
            }
            guard let id = (item["slug"] as? String) ?? (item["id"] as? String),
                  !id.isEmpty,
                  seen.insert(id).inserted else { continue }
            let displayName = (item["display_name"] as? String)
                ?? (item["displayName"] as? String)
                ?? id
            let isDefault = (item["is_default"] as? Bool)
                ?? (item["isDefault"] as? Bool)
                ?? models.isEmpty
            models.append(AgentModel(
                id: id,
                name: displayName.isEmpty ? id : displayName,
                provider: .codex,
                isDefault: isDefault
            ))
        }
        return models
    }

    /// Parses JSONL stdout from `codex exec --json`, extracting the last completed `agent_message` text.
    static func parseExecJSONL(_ data: Data) throws -> String {
        let text = String(decoding: data, as: UTF8.self)
        var lastAgentMessage: String?
        var lastFatalError: String?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("{"),
                  let event = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: []) as? [String: Any] else {
                continue
            }
            let eventType = event["type"] as? String
            switch eventType {
            case "item.completed":
                guard let item = event["item"] as? [String: Any],
                      let itemType = item["type"] as? String else { continue }
                if itemType == "agent_message" {
                    if let msgText = item["text"] as? String, !msgText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        lastAgentMessage = msgText
                    } else if let content = item["content"] as? [[String: Any]] {
                        let joined = content.compactMap { part -> String? in
                            guard let t = part["type"] as? String, t == "text" || t == "output_text" else { return nil }
                            return part["text"] as? String
                        }.joined()
                        if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            lastAgentMessage = joined
                        }
                    }
                }
                // Intentionally ignore non-fatal `item.type == "error"` warnings when an agent_message is produced.
            case "turn.failed":
                if let err = event["error"] as? [String: Any], let msg = err["message"] as? String {
                    lastFatalError = msg
                } else if let msg = event["message"] as? String {
                    lastFatalError = msg
                }
            case "error":
                if let msg = event["message"] as? String {
                    lastFatalError = msg
                }
            default:
                break
            }
        }

        if let lastAgentMessage {
            return lastAgentMessage
        }
        if let lastFatalError {
            throw LocalAgentError.protocolError(provider: .codex, detail: lastFatalError)
        }
        throw LocalAgentError.emptyResponse(.codex)
    }

    static func listModels(
        executable: String,
        cwd: URL,
        environment: [String: String],
        cacheURL: URL = defaultModelsCacheURL,
        timeout: TimeInterval = defaultListModelsTimeout,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> [AgentModel] {
        do {
            let live = try await listModelsViaAppServer(
                executable: executable,
                cwd: cwd,
                environment: environment,
                timeout: timeout,
                killGracePeriod: killGracePeriod
            )
            if !live.isEmpty {
                return live
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Fall through to local cache below.
        }

        if let cacheData = try? Data(contentsOf: cacheURL) {
            let cached = parseModelsCache(data: cacheData)
            if !cached.isEmpty {
                return cached
            }
        }

        throw LocalAgentError.protocolError(
            provider: .codex,
            detail: "Could not retrieve Codex models via app-server or models_cache.json"
        )
    }

    private static func listModelsViaAppServer(
        executable: String,
        cwd: URL,
        environment: [String: String],
        timeout: TimeInterval,
        killGracePeriod: TimeInterval
    ) async throws -> [AgentModel] {
        try await NDJSONProcessSession.run(
            provider: .codex,
            executable: executable,
            arguments: ["app-server", "--stdio"],
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            killGracePeriod: killGracePeriod
        ) { session in
            let initReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": ACPTransport.clientName,
                        "version": ACPTransport.clientVersion,
                    ],
                ],
            ]
            try session.sendJSON(initReq)
            let initResp = try waitForJSONRPCResponse(id: 1, session: session)
            if let err = ACPTransport.parseRPCError(from: initResp) {
                throw LocalAgentError.protocolError(provider: .codex, detail: "codex initialize failed: \(err.message)")
            }

            let initializedNotif: [String: Any] = [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [String: Any](),
            ]
            try session.sendJSON(initializedNotif)

            let listReq: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "model/list",
                "params": [String: Any](),
            ]
            try session.sendJSON(listReq)
            let listResp = try waitForJSONRPCResponse(id: 2, session: session)
            _ = session.finish(graceSeconds: 0.5, terminateIfStillRunning: true)

            if let err = ACPTransport.parseRPCError(from: listResp) {
                throw LocalAgentError.protocolError(provider: .codex, detail: "codex model/list failed: \(err.message)")
            }
            guard let result = listResp["result"] else {
                return []
            }
            return parseAppServerModelList(from: result)
        }
    }

    private static func waitForJSONRPCResponse(id targetId: Int, session: NDJSONProcessSession) throws -> [String: Any] {
        while let frame = session.readNextJSONObject() {
            if let frameId = ACPTransport.jsonRPCID(from: frame), frame["method"] == nil, frameId == targetId {
                return frame
            }
        }
        if session.isCancelled { throw CancellationError() }
        if session.isTimedOut { throw LocalAgentError.timedOut(.codex) }
        throw LocalAgentError.protocolError(provider: .codex, detail: "codex app-server closed before response #\(targetId)")
    }

    static func generate(
        executable: String,
        cwd: URL,
        model: String?,
        prompt: String,
        jsonSchema: String?,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
        try await generateWithSession(
            executable: executable,
            cwd: cwd,
            model: model,
            prompt: prompt,
            jsonSchema: jsonSchema,
            environment: environment,
            toolAccess: toolAccess,
            resumeSessionID: nil,
            persistSession: false,
            timeout: timeout,
            killGracePeriod: killGracePeriod,
            onEvent: nil
        ).text
    }

    private static func extractCodexMessageText(from item: [String: Any]) -> String? {
        if let msgText = item["text"] as? String, !msgText.isEmpty {
            return msgText
        }
        if let content = item["content"] as? [[String: Any]] {
            let joined = content.compactMap { part -> String? in
                guard let t = part["type"] as? String, t == "text" || t == "output_text" else { return nil }
                return part["text"] as? String
            }.joined()
            if !joined.isEmpty { return joined }
        }
        return nil
    }

    static func generateWithSession(
        executable: String,
        cwd: URL,
        model: String?,
        prompt: String,
        jsonSchema: String?,
        environment: [String: String],
        toolAccess: AgentToolAccess = .disabled,
        resumeSessionID: String? = nil,
        persistSession: Bool = false,
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AgentGenerateResult {
        var schemaFileURL: URL?
        defer {
            if let schemaFileURL {
                try? FileManager.default.removeItem(at: schemaFileURL)
            }
        }

        if let trimmedSchema = jsonSchema?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedSchema.isEmpty {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dif-codex-schema-\(UUID().uuidString).json")
            try Data(trimmedSchema.utf8).write(to: url, options: .atomic)
            schemaFileURL = url
        }

        let trimmedResume = resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasResume = !(trimmedResume?.isEmpty ?? true)
        let args = generateArguments(
            model: model,
            outputSchemaPath: schemaFileURL?.path,
            toolAccess: toolAccess,
            resumeSessionID: resumeSessionID,
            persistSession: persistSession
        )

        if onEvent == nil && !hasResume && !persistSession {
            let output = try await AgentSubprocess.runOneShot(
                provider: .codex,
                executable: executable,
                arguments: args,
                environment: environment,
                workingDirectory: cwd,
                stdinData: Data(prompt.utf8),
                timeout: timeout,
                killGracePeriod: killGracePeriod
            )
            if output.status != 0 {
                let stderrText = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if let parsedError = extractJSONLError(from: output.stdout) {
                    throw LocalAgentError.executionFailed(provider: .codex, status: output.status, stderr: parsedError)
                }
                let stdoutText = String(decoding: output.stdout.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = stderrText.isEmpty ? stdoutText : stderrText
                throw LocalAgentError.executionFailed(provider: .codex, status: output.status, stderr: detail)
            }
            return AgentGenerateResult(text: try parseExecJSONL(output.stdout), sessionID: nil)
        }

        return try await NDJSONProcessSession.run(
            provider: .codex,
            executable: executable,
            arguments: args,
            environment: environment,
            workingDirectory: cwd,
            timeout: timeout,
            killGracePeriod: killGracePeriod
        ) { session in
            session.writeStdinAndCloseAsync(Data(prompt.utf8))
            var threadID = trimmedResume
            var emittedThinkingCounts: [String: Int] = [:]
            var emittedMessageCounts: [String: Int] = [:]
            var lastAgentMessage: String?
            var lastFatalError: String?

            while let event = session.readNextJSONObject() {
                let eventType = event["type"] as? String
                switch eventType {
                case "thread.started":
                    if let tid = event["thread_id"] as? String, !tid.isEmpty {
                        threadID = tid
                        onEvent?(.sessionStarted(tid))
                    }
                case "item.started", "item.updated", "item.completed":
                    guard let item = event["item"] as? [String: Any],
                          let itemType = item["type"] as? String else { continue }
                    let itemID = (item["id"] as? String) ?? "\(itemType)-\(UUID().uuidString)"
                    switch itemType {
                    case "reasoning":
                        if let text = extractCodexMessageText(from: item) {
                            let prev = emittedThinkingCounts[itemID] ?? 0
                            if text.count > prev {
                                let delta = String(text.dropFirst(prev))
                                emittedThinkingCounts[itemID] = text.count
                                onEvent?(.thinkingDelta(delta))
                            }
                        }
                    case "command_execution":
                        let cmd = (item["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let rawStatus = (item["status"] as? String)
                        let exitCode = (item["exit_code"] as? Int) ?? (item["exit_code"] as? NSNumber)?.intValue
                        let resolvedStatus: String
                        if eventType == "item.completed" {
                            resolvedStatus = (exitCode ?? 0) == 0 ? "completed" : "failed"
                        } else {
                            resolvedStatus = rawStatus ?? "running"
                        }
                        let output = ACPTransport.formatCompactToolPayload(item["aggregated_output"])
                        onEvent?(.toolActivity(
                            id: itemID,
                            title: cmd.isEmpty ? "shell" : cmd,
                            kind: "execute",
                            input: cmd.isEmpty ? nil : cmd,
                            status: resolvedStatus,
                            output: output
                        ))
                    case "mcp_tool_call", "file_change":
                        let title = (item["tool"] as? String) ?? (item["name"] as? String) ?? itemType
                        let status = eventType == "item.completed" ? "completed" : "running"
                        let input = ACPTransport.formatCompactToolPayload(item["arguments"] ?? item["changes"])
                        let output = ACPTransport.formatCompactToolPayload(item["result"] ?? item["error"])
                        onEvent?(.toolActivity(
                            id: itemID,
                            title: title,
                            kind: itemType == "file_change" ? "edit" : "read",
                            input: input,
                            status: status,
                            output: output
                        ))
                    case "agent_message":
                        if let fullText = extractCodexMessageText(from: item) {
                            let prev = emittedMessageCounts[itemID] ?? 0
                            if fullText.count > prev {
                                let delta = String(fullText.dropFirst(prev))
                                emittedMessageCounts[itemID] = fullText.count
                                onEvent?(.messageDelta(delta))
                            }
                            if eventType == "item.completed",
                               !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                lastAgentMessage = fullText
                            } else if lastAgentMessage == nil,
                                      !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                lastAgentMessage = fullText
                            }
                        }
                    default:
                        break
                    }
                case "turn.failed":
                    if let err = event["error"] as? [String: Any], let msg = err["message"] as? String {
                        lastFatalError = msg
                    } else if let msg = event["message"] as? String {
                        lastFatalError = msg
                    }
                case "error":
                    if let msg = event["message"] as? String {
                        lastFatalError = msg
                    }
                default:
                    break
                }
            }

            let exitInfo = session.finish(graceSeconds: 0.5, terminateIfStillRunning: false)
            if session.isCancelled { throw CancellationError() }
            if session.isTimedOut { throw LocalAgentError.timedOut(.codex) }

            if let lastAgentMessage, !lastAgentMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return AgentGenerateResult(text: lastAgentMessage, sessionID: threadID)
            }
            if let lastFatalError {
                throw LocalAgentError.protocolError(provider: .codex, detail: lastFatalError)
            }
            if exitInfo.status != 0 {
                let detail = exitInfo.stderr.isEmpty ? "Codex CLI exited with status \(exitInfo.status)" : exitInfo.stderr
                throw LocalAgentError.executionFailed(provider: .codex, status: exitInfo.status, stderr: detail)
            }
            throw LocalAgentError.emptyResponse(.codex)
        }
    }

    private static func extractJSONLError(from data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("{"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: []) as? [String: Any] else {
                continue
            }
            if (obj["type"] as? String) == "turn.failed",
               let err = obj["error"] as? [String: Any],
               let msg = err["message"] as? String {
                return msg
            }
            if (obj["type"] as? String) == "error", let msg = obj["message"] as? String {
                return msg
            }
        }
        return nil
    }
}

// MARK: - Unified Local Agent Service

/// Thread-safe facade for detecting local AI agents, listing/caching models, and running single-turn prompts.
actor LocalAgentService {
    static let shared = LocalAgentService()

    private var modelCache: [AgentProvider: [AgentModel]] = [:]
    private let searchPathsOverride: [String]?
    private let environmentOverride: [String: String]?
    private let codexCacheURL: URL

    init(
        searchPaths: [String]? = nil,
        environment: [String: String]? = nil,
        codexCacheURL: URL = CodexCLIAdapter.defaultModelsCacheURL
    ) {
        self.searchPathsOverride = searchPaths
        self.environmentOverride = environment
        self.codexCacheURL = codexCacheURL
    }

    /// Detects installation status and transport kind for all supported providers.
    nonisolated func detectAvailability(searchPaths: [String]? = nil, forceRefresh: Bool = false) -> [AgentAvailability] {
        LocalAgentEnvironment.detectAll(searchPaths: searchPaths ?? searchPathsOverride, forceRefresh: forceRefresh)
    }

    /// Detects installation status and transport kind for a single provider.
    nonisolated func availability(for provider: AgentProvider, searchPaths: [String]? = nil, forceRefresh: Bool = false) -> AgentAvailability {
        LocalAgentEnvironment.availability(for: provider, searchPaths: searchPaths ?? searchPathsOverride, forceRefresh: forceRefresh)
    }

    /// Returns cached models for `provider`, if previously fetched.
    func cachedModels(for provider: AgentProvider) -> [AgentModel]? {
        modelCache[provider]
    }

    /// Clears the in-memory model cache for one provider or all providers.
    func clearModelCache(for provider: AgentProvider? = nil) {
        if let provider {
            modelCache.removeValue(forKey: provider)
        } else {
            modelCache.removeAll()
        }
    }

    /// Lists available models for `provider`, using the in-memory cache unless `forceRefresh` is true.
    func listModels(
        provider: AgentProvider,
        cwd: URL? = nil,
        forceRefresh: Bool = false,
        timeout: TimeInterval = 15
    ) async throws -> [AgentModel] {
        guard !AppEnvironment.isAppStore else {
            throw LocalAgentError.unavailableInAppStore
        }
        try Task.checkCancellation()

        if !forceRefresh, let cached = modelCache[provider], !cached.isEmpty {
            return cached
        }

        let avail = availability(for: provider)
        guard avail.isInstalled, let executable = avail.executablePath else {
            throw LocalAgentError.providerNotInstalled(provider)
        }

        let workDir = cwd ?? FileManager.default.temporaryDirectory
        let env = environmentOverride ?? LocalAgentEnvironment.environment()

        let models: [AgentModel]
        switch avail.transportKind {
        case .acp:
            models = try await ACPTransport.listModels(
                provider: provider,
                executable: executable,
                cwd: workDir,
                environment: env,
                timeout: timeout
            )
        case .cli:
            switch provider {
            case .agy:
                models = try await ACPTransport.listModels(
                    provider: .agy,
                    executable: executable,
                    cwd: workDir,
                    environment: env,
                    timeout: timeout
                )
            case .claude:
                models = try await ClaudeCLIAdapter.listModels(
                    executable: executable,
                    cwd: workDir,
                    environment: env,
                    timeout: min(timeout, ClaudeCLIAdapter.defaultListModelsTimeout)
                )
            case .codex:
                models = try await CodexCLIAdapter.listModels(
                    executable: executable,
                    cwd: workDir,
                    environment: env,
                    cacheURL: codexCacheURL,
                    timeout: min(timeout, CodexCLIAdapter.defaultListModelsTimeout)
                )
            }
        }

        if !models.isEmpty {
            modelCache[provider] = models
        }
        return models
    }

    /// Runs a single-turn text or structured-JSON prompt against the chosen local agent provider.
    func generate(
        provider: AgentProvider,
        model: String? = nil,
        cwd: URL? = nil,
        prompt: String,
        jsonSchema: String? = nil,
        toolAccess: AgentToolAccess = .disabled,
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil
    ) async throws -> String {
        try await generateWithSession(
            provider: provider,
            model: model,
            cwd: cwd,
            prompt: prompt,
            jsonSchema: jsonSchema,
            toolAccess: toolAccess,
            resumeSessionID: nil,
            persistSession: false,
            timeout: timeout,
            maxTotalTimeout: maxTotalTimeout,
            onEvent: nil
        ).text
    }

    /// Runs a live streaming / resumable prompt turn against the chosen local agent provider.
    func generateWithSession(
        provider: AgentProvider,
        model: String? = nil,
        cwd: URL? = nil,
        prompt: String,
        jsonSchema: String? = nil,
        toolAccess: AgentToolAccess = .disabled,
        resumeSessionID: String? = nil,
        persistSession: Bool = false,
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil,
        onEvent: AgentStreamHandler? = nil
    ) async throws -> AgentGenerateResult {
        guard !AppEnvironment.isAppStore else {
            throw LocalAgentError.unavailableInAppStore
        }
        try Task.checkCancellation()

        let avail = availability(for: provider)
        guard avail.isInstalled, let executable = avail.executablePath else {
            throw LocalAgentError.providerNotInstalled(provider)
        }

        let workDir = cwd ?? FileManager.default.temporaryDirectory
        var env = environmentOverride ?? LocalAgentEnvironment.environment()
        if toolAccess == .readOnly {
            env["GIT_OPTIONAL_LOCKS"] = "0"
            env["GIT_PAGER"] = "cat"
            env["GIT_TERMINAL_PROMPT"] = "0"
        }

        let result: AgentGenerateResult
        switch avail.transportKind {
        case .acp:
            result = try await ACPTransport.generateWithSession(
                provider: provider,
                executable: executable,
                cwd: workDir,
                model: model,
                prompt: prompt,
                environment: env,
                toolAccess: toolAccess,
                resumeSessionID: resumeSessionID,
                timeout: timeout,
                maxTotalTimeout: maxTotalTimeout,
                onEvent: onEvent
            )
        case .cli:
            switch provider {
            case .agy:
                result = try await ACPTransport.generateWithSession(
                    provider: .agy,
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    environment: env,
                    toolAccess: toolAccess,
                    resumeSessionID: resumeSessionID,
                    timeout: timeout,
                    maxTotalTimeout: maxTotalTimeout,
                    onEvent: onEvent
                )
            case .claude:
                result = try await ClaudeCLIAdapter.generateWithSession(
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    jsonSchema: jsonSchema,
                    environment: env,
                    toolAccess: toolAccess,
                    resumeSessionID: resumeSessionID,
                    persistSession: persistSession,
                    timeout: timeout,
                    onEvent: onEvent
                )
            case .codex:
                result = try await CodexCLIAdapter.generateWithSession(
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    jsonSchema: jsonSchema,
                    environment: env,
                    toolAccess: toolAccess,
                    resumeSessionID: resumeSessionID,
                    persistSession: persistSession,
                    timeout: timeout,
                    onEvent: onEvent
                )
            }
        }

        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAgentError.emptyResponse(provider)
        }
        return result
    }
}
