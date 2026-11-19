import Darwin
import Foundation

// MARK: - JSON-RPC Types & Errors

/// A JSON-RPC 2.0 request/response identifier (integer or string).
enum LSPJSONRPCID: Sendable, Equatable, Hashable, Codable {
    case int(Int)
    case string(String)

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected int or string JSON-RPC id")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let i): try container.encode(i)
        case .string(let s): try container.encode(s)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .int(let i): return .int(i)
        case .string(let s): return .string(s)
        }
    }

    static func from(_ value: JSONValue?) -> LSPJSONRPCID? {
        guard let value else { return nil }
        switch value {
        case .int(let i): return .int(i)
        case .string(let s): return .string(s)
        case .double(let d) where d.rounded() == d: return .int(Int(d))
        default: return nil
        }
    }
}

/// JSON-RPC 2.0 error object returned by an LSP server.
struct LSPJSONRPCError: Error, LocalizedError, Sendable, Equatable, Hashable, Codable {
    let code: Int
    let message: String
    let data: JSONValue?

    var errorDescription: String? {
        "LSP error (\(code)): \(message)"
    }
}

/// Errors thrown by `LSPTransport` and message framing.
enum LSPTransportError: Error, LocalizedError, Sendable, Equatable {
    case launchFailed(String)
    case notRunning
    case closed
    case cancelled
    case timeout
    case malformedMessage(String)
    case rpcError(LSPJSONRPCError)
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch LSP server: \(msg)"
        case .notRunning: return "LSP server is not running"
        case .closed: return "LSP transport closed"
        case .cancelled: return "LSP request cancelled"
        case .timeout: return "LSP request timed out"
        case .malformedMessage(let msg): return "Malformed LSP message: \(msg)"
        case .rpcError(let err): return err.errorDescription
        case .encodingFailed(let msg): return "Failed to encode LSP message: \(msg)"
        }
    }
}

// MARK: - Content-Length Framing

/// Encodes and incrementally parses LSP `Content-Length: N\r\n\r\n` stdio frames.
enum LSPMessageFraming {
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n

    /// Wraps a UTF-8 JSON payload with its `Content-Length` header.
    static func encode(_ payload: Data) -> Data {
        let header = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        var frame = Data(capacity: header.count + payload.count)
        frame.append(header)
        frame.append(payload)
        return frame
    }

    /// Incremental streaming parser supporting arbitrary chunk splits, multi-byte UTF-8,
    /// extra headers (`Content-Type`), and concatenated messages in one chunk.
    struct Parser: Sendable {
        private var buffer = Data()

        init() {}

        /// Appends newly received bytes and returns all complete message bodies available.
        mutating func append(_ chunk: Data) throws -> [Data] {
            if !chunk.isEmpty {
                buffer.append(chunk)
            }
            var messages: [Data] = []
            while true {
                guard let headerRange = buffer.range(of: LSPMessageFraming.headerTerminator) else {
                    break
                }
                let headerData = buffer[buffer.startIndex..<headerRange.lowerBound]
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    buffer.removeAll(keepingCapacity: false)
                    throw LSPTransportError.malformedMessage("Non-UTF8 header")
                }
                let contentLength = try parseContentLength(from: headerText)
                let bodyStart = headerRange.upperBound
                let available = buffer.endIndex - bodyStart
                guard available >= contentLength else {
                    break
                }
                let bodyEnd = bodyStart + contentLength
                let body = Data(buffer[bodyStart..<bodyEnd])
                buffer.removeSubrange(buffer.startIndex..<bodyEnd)
                messages.append(body)
            }
            return messages
        }

        var bufferedByteCount: Int { buffer.count }

        private func parseContentLength(from headerText: String) throws -> Int {
            var length: Int?
            for rawLine in headerText.components(separatedBy: .newlines) where !rawLine.isEmpty {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "content-length" {
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard let parsed = Int(value), parsed >= 0 else {
                        throw LSPTransportError.malformedMessage("Invalid Content-Length: \(value)")
                    }
                    length = parsed
                }
            }
            guard let length else {
                throw LSPTransportError.malformedMessage("Missing Content-Length header")
            }
            return length
        }
    }
}

// MARK: - Internal Thread-Safe I/O Helpers

private final class StdinWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var closed = false
    private let queue = DispatchQueue(label: "dif.lsp.stdin", qos: .userInitiated)

    init(handle: FileHandle) {
        self.handle = handle
        // Prevent SIGPIPE from terminating the app if an LSP server exits unexpectedly.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LSPTransportError.closed)
                    return
                }
                do {
                    try self.writeSync(data)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func writeSync(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let handle else { throw LSPTransportError.closed }
        let fd = handle.fileDescriptor
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            let total = rawBuffer.count
            while offset < total {
                let written = Darwin.write(fd, base.advanced(by: offset), total - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw LSPTransportError.closed
                }
            }
        }
    }

    func close() {
        lock.lock()
        let toClose = handle
        handle = nil
        closed = true
        lock.unlock()
        try? toClose?.close()
    }
}

private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int

    init(maxBytes: Int = 64 * 1024) {
        self.maxBytes = maxBytes
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > maxBytes {
            data.removeFirst(data.count - maxBytes)
        }
        lock.unlock()
    }

    func snapshot() -> String {
        lock.lock()
        let copy = data
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
    }
}

// MARK: - JSON-RPC 2.0 Stdio Transport

/// Async/await JSON-RPC 2.0 client communicating with an LSP server process over stdio.
actor LSPTransport {
    typealias NotificationHandler = @Sendable (String, JSONValue?) -> Void
    typealias ServerRequestHandler = @Sendable (String, JSONValue?) async throws -> JSONValue
    typealias ExitHandler = @Sendable (Int32) -> Void

    let executable: String
    let arguments: [String]
    let environment: [String: String]?
    let workingDirectory: URL?

    private let onNotification: NotificationHandler?
    private let onServerRequest: ServerRequestHandler?
    private let onExit: ExitHandler?

    private var process: Process?
    private var writer: StdinWriter?
    private let stderrBuffer = StderrBuffer()
    private var readerTask: Task<Void, Never>?
    private var serverRequestTasks: [UUID: Task<Void, Never>] = [:]

    private var nextID: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
    private var cancelledIDs: Set<Int> = []
    private var isStarted = false
    private var isShutDown = false

    init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        onNotification: NotificationHandler? = nil,
        onServerRequest: ServerRequestHandler? = nil,
        onExit: ExitHandler? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.onNotification = onNotification
        self.onServerRequest = onServerRequest
        self.onExit = onExit
    }

    /// True while the underlying process is running and accepting requests.
    var isRunning: Bool {
        isStarted && !isShutDown && (process?.isRunning ?? false)
    }

    /// Launches the child LSP process and starts reading framed JSON-RPC messages from stdout.
    func start() throws {
        guard !isStarted else { return }
        guard !isShutDown else { throw LSPTransportError.closed }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment {
            proc.environment = environment
        }
        if let workingDirectory {
            proc.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            throw LSPTransportError.launchFailed("\(executable): \(error.localizedDescription)")
        }

        self.process = proc
        self.writer = StdinWriter(handle: stdinPipe.fileHandleForWriting)
        self.isStarted = true

        // Capture stderr silently on a dedicated background queue so it never blocks the server or pollutes console.
        let errBuffer = self.stderrBuffer
        let stderrQueue = DispatchQueue(label: "dif.lsp.stderr", qos: .utility)
        stderrQueue.async {
            let handle = stderrPipe.fileHandleForReading
            let fd = handle.fileDescriptor
            var chunk = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 {
                    errBuffer.append(Data(chunk[0..<n]))
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? handle.close()
        }

        // Stream framed stdout messages in strict FIFO order into an AsyncStream consumed by this actor.
        let (frameStream, frameContinuation) = AsyncStream<Data>.makeStream()
        let stdoutQueue = DispatchQueue(label: "dif.lsp.stdout", qos: .userInitiated)
        stdoutQueue.async {
            let handle = stdoutPipe.fileHandleForReading
            let fd = handle.fileDescriptor
            var parser = LSPMessageFraming.Parser()
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 {
                    do {
                        let frames = try parser.append(Data(chunk[0..<n]))
                        for frame in frames {
                            frameContinuation.yield(frame)
                        }
                    } catch {
                        break
                    }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            try? handle.close()
            frameContinuation.finish()
        }

        readerTask = Task { [weak self] in
            for await frame in frameStream {
                guard let self else { break }
                await self.handleIncomingFrame(frame)
            }
            await self?.handleTransportEOF()
        }
    }

    /// Sends a JSON-RPC 2.0 request and awaits its response, supporting concurrency, cancellation, and optional timeout.
    func request(
        method: String,
        params: JSONValue? = nil,
        timeout: Duration? = nil
    ) async throws -> JSONValue {
        guard isStarted, !isShutDown, let writer else {
            throw isShutDown ? LSPTransportError.closed : LSPTransportError.notRunning
        }
        if Task.isCancelled {
            throw LSPTransportError.cancelled
        }

        let id = nextID
        nextID += 1

        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
        ]
        if let params {
            payload["params"] = params
        }

        let encoded: Data
        do {
            let body = try JSONEncoder().encode(JSONValue.object(payload))
            encoded = LSPMessageFraming.encode(body)
        } catch {
            throw LSPTransportError.encodingFailed(error.localizedDescription)
        }

        let timeoutTask: Task<Void, Never>? = timeout.map { duration in
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await self?.failPending(id: id, error: LSPTransportError.timeout, sendCancel: true)
            }
        }
        defer { timeoutTask?.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, any Error>) in
                if !self.isStarted || self.isShutDown {
                    continuation.resume(throwing: LSPTransportError.closed)
                    return
                }
                if self.cancelledIDs.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: LSPTransportError.cancelled)
                    return
                }
                self.pending[id] = continuation

                Task { [weak self] in
                    do {
                        try await writer.write(encoded)
                    } catch {
                        await self?.failPending(id: id, error: error, sendCancel: false)
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.failPending(id: id, error: LSPTransportError.cancelled, sendCancel: true)
            }
        }
    }

    /// Sends a JSON-RPC 2.0 notification (no response expected).
    func notify(method: String, params: JSONValue? = nil) async throws {
        guard isStarted, !isShutDown, let writer else {
            throw isShutDown ? LSPTransportError.closed : LSPTransportError.notRunning
        }
        var payload: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            payload["params"] = params
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(JSONValue.object(payload))
        } catch {
            throw LSPTransportError.encodingFailed(error.localizedDescription)
        }
        try await writer.write(LSPMessageFraming.encode(body))
    }

    /// Performs a graceful LSP shutdown (`shutdown` request + `exit` notification + process termination).
    func shutdown() async {
        guard !isShutDown else { return }

        if isStarted, process?.isRunning == true {
            _ = try? await request(method: "shutdown", params: .null, timeout: .seconds(2))
            try? await notify(method: "exit", params: nil)
        }

        isShutDown = true
        writer?.close()
        writer = nil

        for (_, task) in serverRequestTasks {
            task.cancel()
        }
        serverRequestTasks.removeAll()

        failAllPending(with: LSPTransportError.closed)

        if let proc = process {
            await terminateProcess(proc)
        }
        readerTask?.cancel()
        readerTask = nil
    }

    /// Returns captured trailing stderr output from the server process.
    func recentStderr() -> String {
        stderrBuffer.snapshot()
    }

    // MARK: - Incoming Message Dispatch

    private func handleIncomingFrame(_ data: Data) async {
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let obj) = message else {
            return
        }

        let method = obj["method"]?.stringValue
        let rawID = obj["id"]

        if let method, let rpcID = LSPJSONRPCID.from(rawID) {
            // Server-to-client request: reply asynchronously so the reader loop never stalls.
            let params = obj["params"]
            let token = UUID()
            let handler = self.onServerRequest
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.processServerRequest(id: rpcID, method: method, params: params, handler: handler, token: token)
            }
            serverRequestTasks[token] = task
        } else if let rpcID = LSPJSONRPCID.from(rawID) {
            // Response to one of our client requests.
            guard case .int(let intID) = rpcID else { return }
            cancelledIDs.remove(intID)
            guard let continuation = pending.removeValue(forKey: intID) else { return }
            if let errorVal = obj["error"], !errorVal.isNull {
                let code = errorVal["code"]?.intValue ?? -32603
                let message = errorVal["message"]?.stringValue ?? "Unknown LSP error"
                let rpcError = LSPJSONRPCError(code: code, message: message, data: errorVal["data"])
                continuation.resume(throwing: LSPTransportError.rpcError(rpcError))
            } else {
                continuation.resume(returning: obj["result"] ?? .null)
            }
        } else if let method {
            // Server notification.
            onNotification?(method, obj["params"])
        }
    }

    private func processServerRequest(
        id: LSPJSONRPCID,
        method: String,
        params: JSONValue?,
        handler: ServerRequestHandler?,
        token: UUID
    ) async {
        defer { serverRequestTasks.removeValue(forKey: token) }
        guard !isShutDown else { return }

        var response: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": id.jsonValue,
        ]
        do {
            let result: JSONValue
            if let handler {
                result = try await handler(method, params)
            } else {
                result = Self.defaultServerRequestResponse(method: method, params: params)
            }
            response["result"] = result
        } catch let rpcError as LSPJSONRPCError {
            var errObj: [String: JSONValue] = [
                "code": .int(rpcError.code),
                "message": .string(rpcError.message),
            ]
            if let data = rpcError.data { errObj["data"] = data }
            response["error"] = .object(errObj)
        } catch {
            response["error"] = .object([
                "code": .int(-32603),
                "message": .string(error.localizedDescription),
            ])
        }

        guard !isShutDown, let writer,
              let body = try? JSONEncoder().encode(JSONValue.object(response)) else {
            return
        }
        try? await writer.write(LSPMessageFraming.encode(body))
    }

    /// Graceful default responses for standard server-to-client requests so servers like `gopls` never block.
    static func defaultServerRequestResponse(
        method: String,
        params: JSONValue?,
        configurationSettings: JSONValue? = nil
    ) -> JSONValue {
        switch method {
        case "workspace/configuration":
            let count = params?["items"]?.arrayValue?.count ?? 0
            let itemValue = configurationSettings ?? .null
            return .array(Array(repeating: itemValue, count: count))
        case "client/registerCapability",
             "client/unregisterCapability",
             "window/workDoneProgress/create",
             "window/showMessageRequest",
             "workspace/semanticTokens/refresh",
             "workspace/inlayHint/refresh",
             "workspace/codeLens/refresh",
             "workspace/diagnostic/refresh":
            return .null
        default:
            return .null
        }
    }

    // MARK: - Cancellation & Termination

    private func failPending(id: Int, error: any Error, sendCancel: Bool) async {
        if let continuation = pending.removeValue(forKey: id) {
            continuation.resume(throwing: error)
            if sendCancel, !isShutDown {
                try? await notify(method: "$/cancelRequest", params: .object(["id": .int(id)]))
            }
        } else if sendCancel {
            cancelledIDs.insert(id)
        }
    }

    private func failAllPending(with error: any Error) {
        let outstanding = pending
        pending.removeAll()
        cancelledIDs.removeAll()
        for (_, continuation) in outstanding {
            continuation.resume(throwing: error)
        }
    }

    private func handleTransportEOF() {
        let wasShutDown = isShutDown
        isShutDown = true
        writer?.close()
        writer = nil
        failAllPending(with: LSPTransportError.closed)

        if !wasShutDown, let proc = process {
            let status: Int32 = proc.isRunning ? -1 : proc.terminationStatus
            onExit?(status)
        }
    }

    private func terminateProcess(_ proc: Process) async {
        guard proc.isRunning else { return }
        // Give the server a brief grace period to exit after `exit` notification.
        let deadline = ContinuousClock.now + .milliseconds(400)
        while proc.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        if proc.isRunning {
            proc.terminate()
            let termDeadline = ContinuousClock.now + .milliseconds(400)
            while proc.isRunning && ContinuousClock.now < termDeadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }
}
