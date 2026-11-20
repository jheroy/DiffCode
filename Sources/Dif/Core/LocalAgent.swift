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

    private let process: Process
    private let inPipe: Pipe
    private let outPipe: Pipe
    private let errBuffer: AgentSubprocess.DataBuffer
    private let errGroup: DispatchGroup
    private let box: AgentProcessBox
    private let watchdogs: SessionWatchdogs
    private var stdinClosed = false
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
        let fd = inPipe.fileHandleForWriting.fileDescriptor
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
        guard !stdinClosed else { return }
        stdinClosed = true
        try? inPipe.fileHandleForWriting.close()
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

    static func makeInitializeRequest(id: Int) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion,
                "clientCapabilities": [String: Any](),
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

    /// Runs a full ACP single-turn prompt (`initialize` -> `session/new` -> optional `session/set_model` -> `session/prompt` -> `session/close`).
    static func generate(
        provider: AgentProvider,
        executable: String,
        arguments: [String]? = nil,
        cwd: URL,
        model: String?,
        prompt: String,
        environment: [String: String],
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
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

            // 1. initialize
            let initId = nextId; nextId += 1
            try session.sendJSON(makeInitializeRequest(id: initId))
            let initResp = try waitForResponse(id: initId, session: session, provider: provider)
            if let err = parseRPCError(from: initResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: "initialize failed: \(err.message)")
            }

            // 2. session/new
            let newId = nextId; nextId += 1
            try session.sendJSON(makeSessionNewRequest(id: newId, cwd: cwd.path))
            let newResp = try waitForResponse(id: newId, session: session, provider: provider)
            if let err = parseRPCError(from: newResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: "session/new failed: \(err.message)")
            }
            guard let newResult = newResp["result"] as? [String: Any],
                  let sessionId = newResult["sessionId"] as? String,
                  !sessionId.isEmpty else {
                throw LocalAgentError.protocolError(provider: provider, detail: "session/new returned no sessionId")
            }

            // 3. session/set_model (optional)
            if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
                let setModelId = nextId; nextId += 1
                try session.sendJSON(makeSetModelRequest(id: setModelId, sessionId: sessionId, modelId: trimmedModel))
                let setModelResp = try waitForResponse(id: setModelId, session: session, provider: provider)
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
                        let cfgResp = try waitForResponse(id: cfgId, session: session, provider: provider)
                        if let cfgErr = parseRPCError(from: cfgResp) {
                            throw LocalAgentError.protocolError(provider: provider, detail: "set model failed: \(cfgErr.message)")
                        }
                    } else {
                        throw LocalAgentError.protocolError(provider: provider, detail: "session/set_model failed: \(err.message)")
                    }
                }
            }

            // 4. session/prompt
            let promptId = nextId; nextId += 1
            try session.sendJSON(makeSessionPromptRequest(id: promptId, sessionId: sessionId, prompt: prompt))
            var collected = ""
            let promptResp = try waitForResponse(id: promptId, session: session, provider: provider) { frame in
                if let chunk = extractAgentMessageChunk(from: frame) {
                    collected.append(chunk)
                }
            }

            // 5. session/close
            let closeId = nextId; nextId += 1
            try? session.sendJSON(makeSessionCloseRequest(id: closeId, sessionId: sessionId))
            _ = session.finish(graceSeconds: 1.0, terminateIfStillRunning: true)

            if let err = parseRPCError(from: promptResp) {
                throw LocalAgentError.protocolError(provider: provider, detail: err.message)
            }

            if collected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let result = promptResp["result"] as? [String: Any],
                   let stopReason = result["stopReason"] as? String,
                   stopReason != "end_turn" && stopReason != "max_tokens" {
                    throw LocalAgentError.protocolError(provider: provider, detail: "Stopped with reason: \(stopReason)")
                }
                throw LocalAgentError.emptyResponse(provider)
            }

            return collected
        }
    }

    private static func waitForResponse(
        id targetId: Int,
        session: NDJSONProcessSession,
        provider: AgentProvider,
        onNotification: (([String: Any]) -> Void)? = nil
    ) throws -> [String: Any] {
        while let frame = session.readNextJSONObject() {
            if let rawId = rawJSONRPCID(from: frame) {
                if frame["method"] != nil {
                    // Server-initiated JSON-RPC request (e.g. tool permission with int or string/UUID id):
                    // decline immediately with the exact original id so the server never hangs.
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

    static func generateArguments(model: String?, jsonSchema: String?) -> [String] {
        // IMPORTANT: Do NOT pass `--safe-mode` or `--bare` during prompt execution, as they skip
        // `~/.claude/settings.json` (user proxy/environment settings).
        var args = [
            "-p",
            "--output-format", "json",
            "--no-session-persistence",
            "--tools", "",
            "--disable-slash-commands",
        ]
        if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
            args += ["--model", trimmedModel]
        }
        if let trimmedSchema = jsonSchema?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedSchema.isEmpty {
            args += ["--json-schema", trimmedSchema]
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
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
        let args = generateArguments(model: model, jsonSchema: jsonSchema)
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
            // Claude sometimes emits structured JSON with `is_error: true` on stdout even on non-zero exit.
            if let parsed = try? parseGenerateOutput(output.stdout, hasSchema: jsonSchema != nil), !parsed.isEmpty {
                return parsed
            }
            let stderrText = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let stdoutText = String(decoding: output.stdout.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            throw LocalAgentError.executionFailed(provider: .claude, status: output.status, stderr: detail)
        }
        return try parseGenerateOutput(output.stdout, hasSchema: jsonSchema != nil)
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

    static func generateArguments(model: String?, outputSchemaPath: String?) -> [String] {
        var args = [
            "exec",
            "--json",
            "--ephemeral",
            "--sandbox", "read-only",
            "--skip-git-repo-check",
        ]
        if let trimmedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedModel.isEmpty {
            args += ["-m", trimmedModel]
        }
        if let outputSchemaPath, !outputSchemaPath.isEmpty {
            args += ["--output-schema", outputSchemaPath]
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
        timeout: TimeInterval = 60,
        killGracePeriod: TimeInterval = AgentProcessBox.defaultKillGracePeriod
    ) async throws -> String {
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

        let args = generateArguments(model: model, outputSchemaPath: schemaFileURL?.path)
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
            // If codex already emitted a valid agent_message before a benign teardown warning, still honor non-zero errors first.
            let stderrText = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedError = extractJSONLError(from: output.stdout) {
                throw LocalAgentError.executionFailed(provider: .codex, status: output.status, stderr: parsedError)
            }
            let stdoutText = String(decoding: output.stdout.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = stderrText.isEmpty ? stdoutText : stderrText
            throw LocalAgentError.executionFailed(provider: .codex, status: output.status, stderr: detail)
        }

        return try parseExecJSONL(output.stdout)
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
        timeout: TimeInterval = 60,
        maxTotalTimeout: TimeInterval? = nil
    ) async throws -> String {
        guard !AppEnvironment.isAppStore else {
            throw LocalAgentError.unavailableInAppStore
        }
        try Task.checkCancellation()

        let avail = availability(for: provider)
        guard avail.isInstalled, let executable = avail.executablePath else {
            throw LocalAgentError.providerNotInstalled(provider)
        }

        let workDir = cwd ?? FileManager.default.temporaryDirectory
        let env = environmentOverride ?? LocalAgentEnvironment.environment()

        let response: String
        switch avail.transportKind {
        case .acp:
            response = try await ACPTransport.generate(
                provider: provider,
                executable: executable,
                cwd: workDir,
                model: model,
                prompt: prompt,
                environment: env,
                timeout: timeout,
                maxTotalTimeout: maxTotalTimeout
            )
        case .cli:
            switch provider {
            case .agy:
                response = try await ACPTransport.generate(
                    provider: .agy,
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    environment: env,
                    timeout: timeout,
                    maxTotalTimeout: maxTotalTimeout
                )
            case .claude:
                response = try await ClaudeCLIAdapter.generate(
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    jsonSchema: jsonSchema,
                    environment: env,
                    timeout: timeout
                )
            case .codex:
                response = try await CodexCLIAdapter.generate(
                    executable: executable,
                    cwd: workDir,
                    model: model,
                    prompt: prompt,
                    jsonSchema: jsonSchema,
                    environment: env,
                    timeout: timeout
                )
            }
        }

        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAgentError.emptyResponse(provider)
        }
        return response
    }
}
