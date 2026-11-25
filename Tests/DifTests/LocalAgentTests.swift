import XCTest
@testable import DifKit

final class LocalAgentTests: XCTestCase {
    private let fm = FileManager.default
    private var tempDirs: [URL] = []

    override func tearDown() async throws {
        for dir in tempDirs {
            try? fm.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir(_ prefix: String) throws -> URL {
        let dir = fm.temporaryDirectory.appendingPathComponent("dif-localagent-\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeExecutable(_ body: String, name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Provider & Availability Detection

    func testProviderMetadataAndAvailabilityDetection() throws {
        XCTAssertEqual(AgentProvider.agy.displayName, "Antigravity (ACP)")
        XCTAssertEqual(AgentProvider.claude.displayName, "Claude Code")
        XCTAssertEqual(AgentProvider.codex.displayName, "Codex")

        let binDir = try makeTempDir("bin")
        _ = try makeExecutable("#!/bin/sh\nexit 0\n", name: "agy", in: binDir)
        _ = try makeExecutable("#!/bin/sh\nexit 0\n", name: "claude", in: binDir)
        _ = try makeExecutable("#!/bin/sh\nexit 0\n", name: "codex-acp", in: binDir)

        let all = LocalAgentEnvironment.detectAll(searchPaths: [binDir.path])
        XCTAssertEqual(all.count, 3)

        let agy = try XCTUnwrap(all.first { $0.provider == .agy })
        XCTAssertTrue(agy.isInstalled)
        XCTAssertEqual(agy.transportKind, .acp)
        XCTAssertEqual(agy.executablePath, binDir.appendingPathComponent("agy").path)

        let claude = try XCTUnwrap(all.first { $0.provider == .claude })
        XCTAssertTrue(claude.isInstalled)
        XCTAssertEqual(claude.transportKind, .cli)
        XCTAssertEqual(claude.executablePath, binDir.appendingPathComponent("claude").path)

        let codex = try XCTUnwrap(all.first { $0.provider == .codex })
        XCTAssertTrue(codex.isInstalled)
        XCTAssertEqual(codex.transportKind, .acp)
        XCTAssertEqual(codex.executablePath, binDir.appendingPathComponent("codex-acp").path)

        // When claude-agent-acp is present, it takes precedence over CLI.
        _ = try makeExecutable("#!/bin/sh\nexit 0\n", name: "claude-agent-acp", in: binDir)
        let claudeACP = LocalAgentEnvironment.availability(for: .claude, searchPaths: [binDir.path])
        XCTAssertEqual(claudeACP.transportKind, .acp)
        XCTAssertEqual(claudeACP.executablePath, binDir.appendingPathComponent("claude-agent-acp").path)
    }

    func testAppStoreEditionDisablesAllLocalAgents() async throws {
        let previous = AppEnvironment.edition
        AppEnvironment.edition = .appStore
        defer { AppEnvironment.edition = previous }

        let binDir = try makeTempDir("appstore-bin")
        _ = try makeExecutable("#!/bin/sh\nexit 0\n", name: "agy", in: binDir)

        let avail = LocalAgentEnvironment.detectAll(searchPaths: [binDir.path])
        XCTAssertTrue(avail.allSatisfy { !$0.isInstalled && $0.executablePath == nil })

        let service = LocalAgentService(searchPaths: [binDir.path], environment: ProcessInfo.processInfo.environment)
        do {
            _ = try await service.listModels(provider: .agy)
            XCTFail("Expected unavailableInAppStore")
        } catch let error as LocalAgentError {
            XCTAssertEqual(error, .unavailableInAppStore)
        }

        do {
            _ = try await service.generate(provider: .agy, prompt: "hi")
            XCTFail("Expected unavailableInAppStore")
        } catch let error as LocalAgentError {
            XCTAssertEqual(error, .unavailableInAppStore)
        }
    }

    // MARK: - ACP Frame Parsing

    func testACPParseSessionNewModelsFromAvailableModelsAndConfigOptions() {
        let primaryResult: [String: Any] = [
            "sessionId": "sess-1",
            "models": [
                "currentModelId": "gemini-4-neon-high",
                "availableModels": [
                    ["modelId": "gemini-4-neon-high", "name": "Gemini 4 Neon (High)"],
                    ["modelId": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash (Low)"],
                ],
            ],
        ]
        let models = ACPTransport.parseSessionNewModels(from: primaryResult, provider: .agy)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0], AgentModel(id: "gemini-4-neon-high", name: "Gemini 4 Neon (High)", provider: .agy, isDefault: true))
        XCTAssertEqual(models[1], AgentModel(id: "gemini-3.8-flash-low", name: "Gemini 3.8 Flash (Low)", provider: .agy, isDefault: false))

        let configFallbackResult: [String: Any] = [
            "sessionId": "sess-2",
            "configOptions": [
                [
                    "id": "mode",
                    "currentValue": "default",
                    "options": [["value": "default", "name": "Default"]],
                ],
                [
                    "id": "model",
                    "currentValue": "claude-sonnet-5-5",
                    "options": [
                        [
                            "group": "Claude",
                            "options": [
                                ["value": "claude-sonnet-5-5", "name": "Claude Sonnet 5.5"],
                                ["value": "claude-opus-5-5", "name": "Claude Opus 5.5"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let configModels = ACPTransport.parseSessionNewModels(from: configFallbackResult, provider: .claude)
        XCTAssertEqual(configModels.count, 2)
        XCTAssertEqual(configModels[0].id, "claude-sonnet-5-5")
        XCTAssertTrue(configModels[0].isDefault)
        XCTAssertEqual(configModels[1].id, "claude-opus-5-5")
        XCTAssertFalse(configModels[1].isDefault)
    }

    func testACPExtractAgentMessageChunkFiltersOtherUpdates() {
        let msgFrame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "s1",
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "text", "text": "Hello "],
                ],
            ],
        ]
        XCTAssertEqual(ACPTransport.extractAgentMessageChunk(from: msgFrame), "Hello ")

        let thoughtFrame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "update": [
                    "sessionUpdate": "agent_thought_chunk",
                    "content": ["type": "text", "text": "thinking..."],
                ],
            ],
        ]
        XCTAssertNil(ACPTransport.extractAgentMessageChunk(from: thoughtFrame))

        let nonTextFrame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "update": [
                    "sessionUpdate": "agent_message_chunk",
                    "content": ["type": "image", "data": "..."],
                ],
            ],
        ]
        XCTAssertNil(ACPTransport.extractAgentMessageChunk(from: nonTextFrame))
    }

    // MARK: - Mock ACP End-to-End (listModels, generate, set_model fallback, cancellation)

    func testACPEndToEndWithMockServer() async throws {
        let binDir = try makeTempDir("acp-mock")
        let logFile = binDir.appendingPathComponent("rpc.log")
        let mockAgy = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys

            log_path = \(String(reflecting: logFile.path))
            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                with open(log_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps({"method": msg.get("method"), "params": msg.get("params")}) + "\\n")
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1, "agentInfo": {"name": "MockACP"}}})
                elif method == "session/new":
                    emit({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "sessionId": "sid-42",
                            "models": {
                                "currentModelId": "gemini-4-neon-high",
                                "availableModels": [
                                    {"modelId": "gemini-4-neon-high", "name": "Gemini 4 Neon"},
                                    {"modelId": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash"}
                                ]
                            }
                        }
                    })
                elif method == "session/set_model":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {}})
                elif method == "session/prompt":
                    # Interleave a thought chunk, an interactive server request (should be declined safely), and two text chunks.
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "internal"}}}})
                    emit({"jsonrpc": "2.0", "id": 999, "method": "session/request_permission", "params": {"tool": "bash"}})
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "✨ feat(ACP): "}}}})
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "接入流式响应"}}}})
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
                elif method == "session/close":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    break
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )

        // 1. listModels + cache verification
        let models = try await service.listModels(provider: .agy, cwd: binDir)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].id, "gemini-4-neon-high")
        XCTAssertTrue(models[0].isDefault)
        let cached = await service.cachedModels(for: .agy)
        XCTAssertEqual(cached, models)

        // 2. generate with explicit model
        let output = try await service.generate(
            provider: .agy,
            model: "gemini-3.8-flash-low",
            cwd: binDir,
            prompt: "Write a commit message"
        )
        XCTAssertEqual(output, "✨ feat(ACP): 接入流式响应")

        let logText = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(logText.contains("\"method\": \"initialize\""))
        XCTAssertTrue(logText.contains("\"method\": \"session/new\""))
        XCTAssertTrue(logText.contains("\"method\": \"session/set_model\""))
        XCTAssertTrue(logText.contains("\"modelId\": \"gemini-3.8-flash-low\""))
        XCTAssertTrue(logText.contains("\"method\": \"session/prompt\""))
        XCTAssertTrue(logText.contains("\"method\": \"session/close\""))
        XCTAssertTrue(fm.isExecutableFile(atPath: mockAgy.path))
    }

    // MARK: - ACP Streaming Idle/Total Timeouts & String-ID Server Requests

    func testACPStreamingRenewsIdleTimeoutBeyondSingleWindow() async throws {
        let binDir = try makeTempDir("acp-stream-renew")
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys, time

            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1}})
                elif method == "session/new":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sid-stream"}})
                elif method == "session/prompt":
                    # Stream 6 thought chunks spaced 0.25s apart (~1.5s total > 0.6s idleTimeout).
                    for i in range(6):
                        time.sleep(0.25)
                        emit({
                            "jsonrpc": "2.0",
                            "method": "session/update",
                            "params": {"update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": f"step {i}"}}}
                        })
                    emit({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "{\\"groups\\":[]}"}}}
                    })
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
                elif method == "session/close":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    break
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let started = Date()
        let output = try await service.generate(
            provider: .agy,
            cwd: binDir,
            prompt: "stream test",
            timeout: 0.6,
            maxTotalTimeout: 6.0
        )
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(output, #"{"groups":[]}"#)
        XCTAssertGreaterThanOrEqual(elapsed, 1.2, "Expected active streaming to outlive single 0.6s idle window")
    }

    func testACPSilentStallTimesOutAtIdleTimeout() async throws {
        let binDir = try makeTempDir("acp-idle-stall")
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys, time

            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1}})
                elif method == "session/new":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sid-stall"}})
                elif method == "session/prompt":
                    time.sleep(8.0)
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let started = Date()
        do {
            _ = try await service.generate(
                provider: .agy,
                cwd: binDir,
                prompt: "stall test",
                timeout: 0.5,
                maxTotalTimeout: 6.0
            )
            XCTFail("Expected LocalAgentError.timedOut(.agy)")
        } catch let error as LocalAgentError {
            XCTAssertEqual(error, .timedOut(.agy))
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 3.0, "Silent stall should fail at ~0.5s idleTimeout, not wait for 6s maxTotalTimeout")
        }
    }

    func testACPInfiniteStreamEnforcesMaxTotalTimeoutCap() async throws {
        let binDir = try makeTempDir("acp-total-cap")
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys, time

            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1}})
                elif method == "session/new":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sid-loop"}})
                elif method == "session/prompt":
                    i = 0
                    while True:
                        time.sleep(0.15)
                        emit({
                            "jsonrpc": "2.0",
                            "method": "session/update",
                            "params": {"update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": f"loop {i}"}}}
                        })
                        i += 1
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let started = Date()
        do {
            _ = try await service.generate(
                provider: .agy,
                cwd: binDir,
                prompt: "infinite stream test",
                timeout: 0.8,
                maxTotalTimeout: 1.4
            )
            XCTFail("Expected LocalAgentError.timedOut(.agy) at maxTotalTimeout cap")
        } catch let error as LocalAgentError {
            XCTAssertEqual(error, .timedOut(.agy))
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertGreaterThanOrEqual(elapsed, 1.1, "Should survive past 0.8s idle window until ~1.4s total cap")
            XCTAssertLessThan(elapsed, 4.0, "Hard maxTotalTimeout cap must terminate runaway streams promptly")
        }
    }

    func testACPServerInitiatedRequestWithStringUUIDIDRepliesVerbatimWithoutDeadlock() async throws {
        // Pure helper checks
        XCTAssertEqual(ACPTransport.rawJSONRPCID(from: ["id": "req-uuid-1"]) as? String, "req-uuid-1")
        XCTAssertEqual(ACPTransport.rawJSONRPCID(from: ["id": 42]) as? Int, 42)
        XCTAssertNil(ACPTransport.rawJSONRPCID(from: ["id": NSNull()]))
        XCTAssertNil(ACPTransport.rawJSONRPCID(from: ["id": true]))
        let sampleReply = ACPTransport.makeUnsupportedServerRequestReply(id: "req-uuid-1")
        XCTAssertEqual(sampleReply["id"] as? String, "req-uuid-1")

        // End-to-end check: server blocks waiting for client's reply to string-UUID request before finishing prompt.
        let binDir = try makeTempDir("acp-uuid-req")
        let replyLog = binDir.appendingPathComponent("reply.json")
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys

            reply_log = \(String(reflecting: replyLog.path))
            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            while True:
                raw = sys.stdin.readline()
                if not raw:
                    break
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1}})
                elif method == "session/new":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sid-uuid"}})
                elif method == "session/prompt":
                    # Send server-initiated request with non-numeric string/UUID id and wait synchronously for client reply.
                    emit({"jsonrpc": "2.0", "id": "req-uuid-1", "method": "session/request_permission", "params": {"tool": "read_file"}})
                    reply_line = sys.stdin.readline()
                    reply_obj = json.loads(reply_line)
                    with open(reply_log, "w", encoding="utf-8") as f:
                        json.dump(reply_obj, f)
                    assert reply_obj.get("id") == "req-uuid-1", f"unexpected id: {reply_obj}"
                    assert isinstance(reply_obj.get("error"), dict), f"expected error reply: {reply_obj}"
                    emit({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "uuid-ok"}}}
                    })
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
                elif method == "session/close":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    break
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment
        )
        let output = try await service.generate(
            provider: .agy,
            cwd: binDir,
            prompt: "uuid request test",
            timeout: 5.0
        )
        XCTAssertEqual(output, "uuid-ok")

        let replyData = try Data(contentsOf: replyLog)
        let replyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: replyData) as? [String: Any])
        XCTAssertEqual(replyJSON["id"] as? String, "req-uuid-1")
        let errObj = try XCTUnwrap(replyJSON["error"] as? [String: Any])
        XCTAssertEqual(errObj["code"] as? Int, -32601)
    }

    // MARK: - Claude CLI Adapter Parsing & End-to-End

    func testClaudeCLIAdapterArgumentsAndParsing() throws {
        let genArgs = ClaudeCLIAdapter.generateArguments(model: "sonnet", jsonSchema: "{\"type\":\"object\"}")
        XCTAssertFalse(genArgs.contains("--safe-mode"), "Prompt execution must NOT pass --safe-mode")
        XCTAssertFalse(genArgs.contains("--bare"), "Prompt execution must NOT pass --bare")
        XCTAssertTrue(genArgs.contains("--model"))
        XCTAssertTrue(genArgs.contains("sonnet"))
        XCTAssertTrue(genArgs.contains("--json-schema"))
        XCTAssertTrue(genArgs.contains("--disable-slash-commands"))

        let listArgs = ClaudeCLIAdapter.listModelsArguments()
        XCTAssertTrue(listArgs.contains("--safe-mode"))
        XCTAssertTrue(listArgs.contains("stream-json"))

        let controlFrame: [String: Any] = [
            "type": "control_response",
            "response": [
                "subtype": "success",
                "request_id": "1",
                "response": [
                    "models": [
                        ["value": "default", "resolvedModel": "claude-opus-5-5", "displayName": "Default (Opus 5.5)"],
                        ["value": "sonnet", "resolvedModel": "claude-sonnet-5-5", "displayName": "Sonnet"],
                        ["value": "haiku", "resolvedModel": "claude-haiku-5-5"],
                    ],
                ],
            ],
        ]
        let parsedModels = try XCTUnwrap(ClaudeCLIAdapter.parseControlResponseModels(from: controlFrame))
        XCTAssertEqual(parsedModels.count, 3)
        XCTAssertEqual(parsedModels[0], AgentModel(id: "default", name: "Default (Opus 5.5)", provider: .claude, isDefault: true))
        XCTAssertEqual(parsedModels[1], AgentModel(id: "sonnet", name: "Sonnet", provider: .claude, isDefault: false))
        XCTAssertEqual(parsedModels[2], AgentModel(id: "haiku", name: "claude-haiku-5-5", provider: .claude, isDefault: false))

        // Prefers structured_output when present
        let structuredJSON = Data(#"{"type":"result","is_error":false,"result":"prose","structured_output":{"groups":[]}}"#.utf8)
        let structuredText = try ClaudeCLIAdapter.parseGenerateOutput(structuredJSON, hasSchema: true)
        XCTAssertEqual(structuredText, #"{"groups":[]}"#)

        // Plain result when no structured_output
        let plainJSON = Data(#"{"type":"result","is_error":false,"result":"🐛 fix(core): 修复边界条件"}"#.utf8)
        XCTAssertEqual(try ClaudeCLIAdapter.parseGenerateOutput(plainJSON, hasSchema: false), "🐛 fix(core): 修复边界条件")

        // Detects is_error
        let errJSON = Data(#"{"type":"result","is_error":true,"result":"API rate limited"}"#.utf8)
        XCTAssertThrowsError(try ClaudeCLIAdapter.parseGenerateOutput(errJSON, hasSchema: false)) { err in
            XCTAssertEqual(err as? LocalAgentError, .protocolError(provider: .claude, detail: "API rate limited"))
        }
    }

    func testClaudeCLIEndToEndWithMockScript() async throws {
        let binDir = try makeTempDir("claude-mock")
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys

            args = sys.argv[1:]
            if "--input-format" in args:
                line = sys.stdin.readline()
                req = json.loads(line)
                assert req["request"]["subtype"] == "initialize"
                resp = {
                    "type": "control_response",
                    "response": {
                        "subtype": "success",
                        "request_id": req["request_id"],
                        "response": {
                            "models": [
                                {"value": "default", "displayName": "Default"},
                                {"value": "sonnet", "displayName": "Sonnet 5.5"}
                            ]
                        }
                    }
                }
                sys.stdout.write(json.dumps(resp) + "\\n")
                sys.stdout.flush()
            else:
                assert "--safe-mode" not in args
                assert "--bare" not in args
                prompt = sys.stdin.read()
                if "--json-schema" in args:
                    out = {"type": "result", "is_error": False, "structured_output": {"echo": prompt.strip()}}
                else:
                    out = {"type": "result", "is_error": False, "result": "claude:" + prompt.strip()}
                sys.stdout.write(json.dumps(out) + "\\n")
                sys.stdout.flush()
            """,
            name: "claude",
            in: binDir
        )

        let service = LocalAgentService(searchPaths: [binDir.path], environment: ProcessInfo.processInfo.environment)
        let models = try await service.listModels(provider: .claude, cwd: binDir)
        XCTAssertEqual(models.map(\.id), ["default", "sonnet"])

        let plain = try await service.generate(provider: .claude, model: "sonnet", cwd: binDir, prompt: "hello")
        XCTAssertEqual(plain, "claude:hello")

        let structured = try await service.generate(
            provider: .claude,
            model: "sonnet",
            cwd: binDir,
            prompt: "schema-test",
            jsonSchema: "{\"type\":\"object\"}"
        )
        XCTAssertTrue(structured.contains("\"echo\":\"schema-test\""))
    }

    // MARK: - Codex CLI Adapter Parsing & End-to-End

    func testCodexCLIAdapterParsing() throws {
        let appServerResult: [String: Any] = [
            "data": [
                ["id": "gpt-6-luna", "displayName": "GPT-6 Luna", "hidden": false, "isDefault": true],
                ["id": "gpt-internal", "displayName": "Internal", "hidden": true, "isDefault": false],
                ["id": "gpt-5.6-terra", "displayName": "GPT-5.6 Terra", "hidden": false, "isDefault": false],
            ],
        ]
        let liveModels = CodexCLIAdapter.parseAppServerModelList(from: appServerResult)
        XCTAssertEqual(liveModels.map(\.id), ["gpt-6-luna", "gpt-5.6-terra"])
        XCTAssertTrue(liveModels[0].isDefault)
        XCTAssertFalse(liveModels[1].isDefault)

        let cacheJSON = Data(
            """
            {
              "models": [
                {"slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list"},
                {"slug": "hidden-model", "display_name": "Hidden", "visibility": "hide"},
                {"slug": "gpt-5.6-terra", "display_name": "GPT-5.6-Terra", "visibility": "list"}
              ]
            }
            """.utf8
        )
        let cacheModels = CodexCLIAdapter.parseModelsCache(data: cacheJSON)
        XCTAssertEqual(cacheModels.map(\.id), ["gpt-6-luna", "gpt-5.6-terra"])
        XCTAssertEqual(cacheModels.map(\.name), ["GPT-6-Luna", "GPT-5.6-Terra"])
        XCTAssertTrue(cacheModels[0].isDefault)

        let jsonl = Data(
            """
            {"type":"thread.started","thread_id":"t1"}
            {"type":"item.completed","item":{"id":"i0","type":"error","message":"non-fatal warning"}}
            {"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"first draft"}}
            {"type":"item.completed","item":{"id":"i2","type":"agent_message","text":"{\\"ok\\":true}"}}
            {"type":"turn.completed","usage":{"input_tokens":10}}
            """.utf8
        )
        XCTAssertEqual(try CodexCLIAdapter.parseExecJSONL(jsonl), #"{"ok":true}"#)
    }

    func testCodexCLIEndToEndWithAppServerCacheFallbackAndSchemaCleanup() async throws {
        let binDir = try makeTempDir("codex-mock")
        let schemaPathLog = binDir.appendingPathComponent("schema_path.txt")
        let cacheURL = binDir.appendingPathComponent("models_cache.json")
        try Data(
            """
            {"models":[{"slug":"cached-gpt","display_name":"Cached GPT","visibility":"list"}]}
            """.utf8
        ).write(to: cacheURL)

        // 1. Working app-server + exec mock
        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, os, sys

            args = sys.argv[1:]
            if args[:2] == ["app-server", "--stdio"]:
                for line in sys.stdin:
                    msg = json.loads(line)
                    m = msg.get("method")
                    if m == "initialize":
                        sys.stdout.write(json.dumps({"jsonrpc":"2.0","id":msg["id"],"result":{}}) + "\\n")
                        sys.stdout.flush()
                    elif m == "model/list":
                        sys.stdout.write(json.dumps({
                            "jsonrpc":"2.0",
                            "id":msg["id"],
                            "result":{"data":[{"id":"gpt-6-luna","displayName":"GPT-6 Luna","hidden":False,"isDefault":True}]}
                        }) + "\\n")
                        sys.stdout.flush()
                        break
            elif args[:1] == ["exec"]:
                prompt = sys.stdin.read()
                if "--output-schema" in args:
                    idx = args.index("--output-schema")
                    schema_file = args[idx + 1]
                    assert os.path.exists(schema_file)
                    with open(\(String(reflecting: schemaPathLog.path)), "w") as f:
                        f.write(schema_file)
                sys.stdout.write(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"codex:" + prompt.strip()}}) + "\\n")
                sys.stdout.write(json.dumps({"type":"turn.completed"}) + "\\n")
                sys.stdout.flush()
            """,
            name: "codex",
            in: binDir
        )

        let service = LocalAgentService(
            searchPaths: [binDir.path],
            environment: ProcessInfo.processInfo.environment,
            codexCacheURL: cacheURL
        )
        let liveModels = try await service.listModels(provider: .codex, cwd: binDir)
        XCTAssertEqual(liveModels.map(\.id), ["gpt-6-luna"])

        let generated = try await service.generate(
            provider: .codex,
            model: "gpt-6-luna",
            cwd: binDir,
            prompt: "group changes",
            jsonSchema: "{\"type\":\"object\"}"
        )
        XCTAssertEqual(generated, "codex:group changes")

        // Verify temporary schema file was deleted after exec finished.
        let recordedSchemaPath = try String(contentsOf: schemaPathLog, encoding: .utf8)
        XCTAssertFalse(fm.fileExists(atPath: recordedSchemaPath), "Temporary Codex schema file must be cleaned up")

        // 2. Failing app-server falls back to models_cache.json
        _ = try makeExecutable(
            """
            #!/bin/sh
            exit 1
            """,
            name: "codex",
            in: binDir
        )
        let fallbackModels = try await service.listModels(provider: .codex, cwd: binDir, forceRefresh: true)
        XCTAssertEqual(fallbackModels.map(\.id), ["cached-gpt"])
    }

    // MARK: - Read-Only Tool Access Policy & Adapters

    func testACPInitializeCapabilitiesForToolAccessModes() {
        let disabledReq = ACPTransport.makeInitializeRequest(id: 1, toolAccess: .disabled)
        let disabledParams = disabledReq["params"] as? [String: Any]
        let disabledCaps = disabledParams?["clientCapabilities"] as? [String: Any]
        XCTAssertTrue(disabledCaps?.isEmpty ?? false)

        let readOnlyReq = ACPTransport.makeInitializeRequest(id: 2, toolAccess: .readOnly)
        let readOnlyParams = readOnlyReq["params"] as? [String: Any]
        let readOnlyCaps = readOnlyParams?["clientCapabilities"] as? [String: Any]
        let fsCaps = readOnlyCaps?["fs"] as? [String: Any]
        XCTAssertEqual(fsCaps?["readTextFile"] as? Bool, true)
        XCTAssertEqual(fsCaps?["writeTextFile"] as? Bool, false)
    }

    func testACPReadOnlyShellValidatorAllowsSafeReadsAndRejectsMutations() throws {
        let repo = try makeTempDir("shell-policy")

        // Allowed read-only inspection & safe pipes
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git show 0123456789abcdef:Sources/App.swift", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git show 0123456789abcdef:Sources/App.swift | sed -n '1,50p'", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git --no-pager log --oneline -n 10", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git diff abc..def -- Sources/Dif", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git branch --show-current", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git branch -a", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git tag -l 'v*'", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git stash show stash@{0}", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("rg \"foo\" Sources", repoRoot: repo))
        XCTAssertTrue(ACPTransport.isReadOnlyShellCommand("git -C . status", repoRoot: repo))

        // Rejected mutations, escapes, and injection attempts
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git checkout main", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git reset --hard", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git commit -m x", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git branch -D foo", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git branch new-branch", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git tag v1.0", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git stash", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git -c core.fsmonitor=id status", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git -C /etc status", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git diff --ext-diff a b", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git diff --output=/tmp/x a b", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git diff --no-index /etc/passwd /etc/hosts", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git show HEAD:a; rm -rf /", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git show HEAD:a && touch x", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git show HEAD:a > /tmp/x", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git show HEAD:`id`", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("rg $(id) Sources", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("sed -i '' 's/a/b/' Sources/App.swift", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("sed -n '1e id' Sources/App.swift", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("rg --pre=sh foo", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("cat /etc/passwd", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("cat ../../secret", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("{ git status; }", repoRoot: repo))
        XCTAssertFalse(ACPTransport.isReadOnlyShellCommand("git show stash@{0,1}", repoRoot: repo))
    }

    func testACPPermissionReplyAndReadTextFileHandler() throws {
        let repo = try makeTempDir("acp-fs-perm")
        let sub = repo.appendingPathComponent("Sources")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let fileURL = sub.appendingPathComponent("Sample.swift")
        try Data("line1\nline2\nline3\nline4\n".utf8).write(to: fileURL)

        let options: [[String: Any]] = [
            ["optionId": "allow_once", "kind": "allow_once", "name": "Allow once"],
            ["optionId": "reject_once", "kind": "reject_once", "name": "Reject once"],
        ]

        // 1. In-repo read permission -> selected allow_once (double-nested outcome)
        let readPerm = ACPTransport.makePermissionReply(
            id: "perm-1",
            params: [
                "toolCall": [
                    "kind": "read",
                    "rawInput": ["path": fileURL.path],
                ],
                "options": options,
            ],
            repoRoot: repo
        )
        XCTAssertEqual(readPerm["id"] as? String, "perm-1")
        let readOutcome = ((readPerm["result"] as? [String: Any])?["outcome"] as? [String: Any])
        XCTAssertEqual(readOutcome?["outcome"] as? String, "selected")
        XCTAssertEqual(readOutcome?["optionId"] as? String, "allow_once")

        // 2. Read-only git command -> allow_once
        let gitPerm = ACPTransport.makePermissionReply(
            id: "perm-2",
            params: [
                "toolCall": [
                    "kind": "execute",
                    "rawInput": ["command": "git show HEAD:Sources/Sample.swift"],
                ],
                "options": options,
            ],
            repoRoot: repo
        )
        let gitOutcome = ((gitPerm["result"] as? [String: Any])?["outcome"] as? [String: Any])
        XCTAssertEqual(gitOutcome?["optionId"] as? String, "allow_once")

        // 3. Edit / outside-repo read / mutating execute -> reject_once
        for badToolCall: [String: Any] in [
            ["kind": "edit", "rawInput": ["path": fileURL.path]],
            ["kind": "read", "rawInput": ["path": "/etc/passwd"]],
            ["kind": "execute", "rawInput": ["command": "git reset --hard"]],
        ] {
            let reply = ACPTransport.makePermissionReply(
                id: 77,
                params: ["toolCall": badToolCall, "options": options],
                repoRoot: repo
            )
            let outcome = ((reply["result"] as? [String: Any])?["outcome"] as? [String: Any])
            XCTAssertEqual(outcome?["outcome"] as? String, "selected")
            XCTAssertEqual(outcome?["optionId"] as? String, "reject_once")
        }

        // 4. fs/read_text_file line/limit slicing & outside path error
        let sliceReply = ACPTransport.makeReadTextFileReply(
            id: 10,
            params: ["path": "Sources/Sample.swift", "line": 2, "limit": 2],
            repoRoot: repo
        )
        let slicedContent = (sliceReply["result"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(slicedContent, "line2\nline3")

        let escapeReply = ACPTransport.makeReadTextFileReply(
            id: 11,
            params: ["path": "../../etc/passwd"],
            repoRoot: repo
        )
        XCTAssertNotNil(escapeReply["error"])
        let escapeOutsideReply = ACPTransport.makeReadTextFileReply(
            id: 12,
            params: ["path": "/etc/passwd"],
            repoRoot: repo
        )
        XCTAssertNotNil(escapeOutsideReply["error"])
    }

    func testACPReadOnlyEndToEndHandlesFSToolsPermissionsAndStripsNarration() async throws {
        let binDir = try makeTempDir("acp-ro-bin")
        let repo = try makeTempDir("acp-ro-repo")
        let targetFile = repo.appendingPathComponent("Context.swift")
        try Data("alpha\nbeta\ngamma\ndelta\n".utf8).write(to: targetFile)
        let logFile = binDir.appendingPathComponent("tool_log.json")

        _ = try makeExecutable(
            """
            #!/usr/bin/env python3
            import json, sys

            log_path = \(String(reflecting: logFile.path))
            def emit(obj):
                sys.stdout.write(json.dumps(obj) + "\\n")
                sys.stdout.flush()

            logs = {}
            for raw in sys.stdin:
                raw = raw.strip()
                if not raw:
                    continue
                msg = json.loads(raw)
                method = msg.get("method")
                req_id = msg.get("id")
                if method == "initialize":
                    logs["caps"] = msg.get("params", {}).get("clientCapabilities", {})
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"protocolVersion": 1}})
                elif method == "session/new":
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"sessionId": "sid-ro"}})
                elif method == "session/prompt":
                    # Pre-tool narration
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Let me read Context.swift first..."}}}})
                    # Tool call #1: fs/read_text_file
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "tool_call", "toolCallId": "tc-1"}}})
                    emit({"jsonrpc": "2.0", "id": "fs-1", "method": "fs/read_text_file", "params": {"sessionId": "sid-ro", "path": "Context.swift", "line": 2, "limit": 2}})
                    logs["fs_reply"] = json.loads(sys.stdin.readline())
                    # Tool call #2: allowed read-only git permission
                    emit({"jsonrpc": "2.0", "id": "perm-allow", "method": "session/request_permission", "params": {"toolCall": {"kind": "execute", "rawInput": {"command": "git show HEAD:Context.swift"}}, "options": [{"optionId": "allow_once", "kind": "allow_once"}, {"optionId": "reject_once", "kind": "reject_once"}]}})
                    logs["perm_allow_reply"] = json.loads(sys.stdin.readline())
                    # Tool call #3: disallowed edit permission
                    emit({"jsonrpc": "2.0", "id": "perm-deny", "method": "session/request_permission", "params": {"toolCall": {"kind": "edit", "rawInput": {"path": "Context.swift"}}, "options": [{"optionId": "allow_once", "kind": "allow_once"}, {"optionId": "reject_once", "kind": "reject_once"}]}})
                    logs["perm_deny_reply"] = json.loads(sys.stdin.readline())
                    # Final report
                    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "# 代码审查报告：最终正文"}}}})
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {"stopReason": "end_turn"}})
                elif method == "session/close":
                    with open(log_path, "w", encoding="utf-8") as f:
                        json.dump(logs, f)
                    emit({"jsonrpc": "2.0", "id": req_id, "result": {}})
                    break
            """,
            name: "agy",
            in: binDir
        )

        let service = LocalAgentService(searchPaths: [binDir.path], environment: ProcessInfo.processInfo.environment)
        let output = try await service.generate(
            provider: .agy,
            cwd: repo,
            prompt: "review",
            toolAccess: .readOnly,
            timeout: 5.0
        )
        XCTAssertEqual(output, "# 代码审查报告：最终正文")
        XCTAssertFalse(output.contains("Let me read"))

        let logData = try Data(contentsOf: logFile)
        let logs = try XCTUnwrap(JSONSerialization.jsonObject(with: logData) as? [String: Any])
        let capsFS = (logs["caps"] as? [String: Any])?["fs"] as? [String: Any]
        XCTAssertEqual(capsFS?["readTextFile"] as? Bool, true)
        let fsContent = ((logs["fs_reply"] as? [String: Any])?["result"] as? [String: Any])?["content"] as? String
        XCTAssertEqual(fsContent, "beta\ngamma")
        let allowOutcome = (((logs["perm_allow_reply"] as? [String: Any])?["result"] as? [String: Any])?["outcome"] as? [String: Any])
        XCTAssertEqual(allowOutcome?["optionId"] as? String, "allow_once")
        let denyOutcome = (((logs["perm_deny_reply"] as? [String: Any])?["result"] as? [String: Any])?["outcome"] as? [String: Any])
        XCTAssertEqual(denyOutcome?["optionId"] as? String, "reject_once")
    }

    func testClaudeAndCodexArgumentsForReadOnlyToolAccess() {
        let claudeDisabled = ClaudeCLIAdapter.generateArguments(model: "sonnet", jsonSchema: nil, toolAccess: .disabled)
        XCTAssertTrue(claudeDisabled.contains("--tools"))
        if let idx = claudeDisabled.firstIndex(of: "--tools") {
            XCTAssertEqual(claudeDisabled[idx + 1], "")
        }

        let claudeReadOnly = ClaudeCLIAdapter.generateArguments(model: "sonnet", jsonSchema: nil, toolAccess: .readOnly)
        XCTAssertFalse(claudeReadOnly.contains("--safe-mode"))
        XCTAssertFalse(claudeReadOnly.contains("--bare"))
        XCTAssertTrue(claudeReadOnly.contains("--permission-mode"))
        XCTAssertTrue(claudeReadOnly.contains("dontAsk"))
        XCTAssertTrue(claudeReadOnly.contains("Read,Grep,Glob,Bash"))
        XCTAssertTrue(claudeReadOnly.contains("--disallowedTools"))
        XCTAssertTrue(claudeReadOnly.contains("--allowedTools"))
        let modelIdx = claudeReadOnly.firstIndex(of: "--model")
        let allowedIdx = claudeReadOnly.firstIndex(of: "--allowedTools")
        XCTAssertNotNil(modelIdx)
        XCTAssertNotNil(allowedIdx)
        XCTAssertLessThan(modelIdx!, allowedIdx!)

        let codexDisabled = CodexCLIAdapter.generateArguments(model: "gpt-5.3-codex", outputSchemaPath: nil, toolAccess: .disabled)
        XCTAssertFalse(codexDisabled.contains("-c"))
        XCTAssertTrue(codexDisabled.contains("read-only"))

        let codexReadOnly = CodexCLIAdapter.generateArguments(model: "gpt-5.3-codex", outputSchemaPath: nil, toolAccess: .readOnly)
        XCTAssertTrue(codexReadOnly.contains("read-only"))
        XCTAssertTrue(codexReadOnly.contains("-c"))
        XCTAssertTrue(codexReadOnly.contains("approval_policy=\"never\""))
        XCTAssertEqual(codexReadOnly.last, "-")
    }

    func testACPReadOnlyShellValidatorSupportsCompoundsRedirectsAndLocalVars() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let allowed = [
            "rg -n \"origin_server_id|OriginServerId\" datastruct/ gamecore/ app/ sql/ migrations/ 2>/dev/null || rg -n \"origin_server_id\" .",
            "SHA=0123456789abcdef0123456789abcdef01234567\necho \"=== diff ===\"\ngit show $SHA:Sources/App.swift | nl -ba",
            "find . -maxdepth 2 -name \"*.swift\"",
            "sort Sources/App.swift",
            "git status && git log -n 5",
            "git show HEAD:Sources/App.swift 2>&1"
        ]
        for cmd in allowed {
            XCTAssertTrue(ACPTransport.isReadOnlyShellCommand(cmd, repoRoot: repo), "Expected allow: \(cmd)")
        }

        let denied = [
            "git show HEAD:Sources/App.swift > /tmp/out.txt",
            "git show HEAD:Sources/App.swift 2> err.log",
            "git show HEAD:Sources/App.swift; rm -rf /",
            "git show HEAD:Sources/App.swift && touch hacked.txt",
            "PATH=/tmp/evil git status",
            "GIT_SSH_COMMAND=id git status",
            "find . -delete",
            "find . -exec id {} +",
            "sort -o out.txt Sources/App.swift"
        ]
        for cmd in denied {
            XCTAssertFalse(ACPTransport.isReadOnlyShellCommand(cmd, repoRoot: repo), "Expected deny: \(cmd)")
        }
    }

    func testACPStreamingEventsPermissionErrorAndSessionResumeFallback() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-acp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockScript = tempDir.appendingPathComponent("mock-acp.py")
        let python = """
        #!/usr/bin/env python3
        import json, sys, os

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}

            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess-acp-1"}})
            elif method in ("session/set_model", "session/set_config_option"):
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif method == "session/resume":
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
            elif method == "session/load":
                sid = params.get("sessionId", "sess-acp-1")
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "REPLAYED-HISTORY"}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif method == "session/prompt":
                sid = params.get("sessionId", "sess-acp-1")
                prompt_text = ""
                for item in params.get("prompt", []):
                    if isinstance(item, dict):
                        prompt_text += item.get("text", "")
                if os.environ.get("MOCK_DENY_EDIT") == "1":
                    send({"jsonrpc": "2.0", "id": 9001, "method": "session/request_permission", "params": {
                        "sessionId": sid,
                        "toolCall": {"toolCallId": "tc-edit", "kind": "edit", "title": "edit file"},
                        "options": [{"optionId": "allow_once", "kind": "allow_once"}, {"optionId": "reject_once", "kind": "reject_once"}]
                    }})
                    _ = sys.stdin.readline()
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}})
                    continue
                if "FOLLOWUP" in prompt_text:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "FOLLOWUP-ACP-OK"}}}})
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    continue
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Checking refs..."}}}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call", "toolCallId": "tc-1", "kind": "execute", "title": "rg foo", "status": "in_progress", "rawInput": {"command": "rg -n foo . 2>/dev/null || rg -n foo src/"}}}})
                send({"jsonrpc": "2.0", "id": 9002, "method": "session/request_permission", "params": {
                    "sessionId": sid,
                    "toolCall": {"toolCallId": "tc-1", "kind": "execute", "title": "rg foo", "rawInput": {"command": "rg -n foo . 2>/dev/null || rg -n foo src/"}},
                    "options": [{"optionId": "allow_once", "kind": "allow_once"}, {"optionId": "reject_once", "kind": "reject_once"}]
                }})
                perm_reply = json.loads(sys.stdin.readline())
                outcome = (((perm_reply.get("result") or {}).get("outcome") or {}).get("optionId"))
                if outcome != "allow_once":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "cancelled"}})
                    continue
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "tool_call_update", "toolCallId": "tc-1", "status": "completed", "rawOutput": "match:1"}}})
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ACP-STREAM-OK"}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        """
        try python.write(to: mockScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)

        final class EventRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [AgentStreamEvent] = []
            func append(_ event: AgentStreamEvent) {
                lock.lock()
                storage.append(event)
                lock.unlock()
            }
            var events: [AgentStreamEvent] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        let recorder = EventRecorder()
        let first = try await ACPTransport.generateWithSession(
            provider: .agy,
            executable: mockScript.path,
            arguments: [],
            cwd: tempDir,
            model: "default",
            prompt: "Review",
            environment: ProcessInfo.processInfo.environment,
            toolAccess: .readOnly,
            resumeSessionID: nil,
            timeout: 5,
            maxTotalTimeout: 10,
            killGracePeriod: 0.2
        ) { event in
            recorder.append(event)
        }
        let events = recorder.events
        XCTAssertEqual(first.text, "ACP-STREAM-OK")
        XCTAssertEqual(first.sessionID, "sess-acp-1")
        XCTAssertTrue(events.contains(.sessionStarted("sess-acp-1")))
        XCTAssertTrue(events.contains(.thinkingDelta("Checking refs...")))
        XCTAssertTrue(events.contains(.messageDelta("ACP-STREAM-OK")))
        XCTAssertTrue(events.contains {
            if case .toolActivity(id: "tc-1", title: _, kind: _, input: _, status: "completed", output: _) = $0 {
                return true
            }
            return false
        })

        let resumed = try await ACPTransport.generateWithSession(
            provider: .agy,
            executable: mockScript.path,
            arguments: [],
            cwd: tempDir,
            model: "default",
            prompt: "FOLLOWUP",
            environment: ProcessInfo.processInfo.environment,
            toolAccess: .readOnly,
            resumeSessionID: "sess-acp-1",
            timeout: 5,
            maxTotalTimeout: 10,
            killGracePeriod: 0.2,
            onEvent: nil
        )
        XCTAssertEqual(resumed.text, "FOLLOWUP-ACP-OK")

        do {
            _ = try await ACPTransport.generateWithSession(
                provider: .agy,
                executable: mockScript.path,
                arguments: [],
                cwd: tempDir,
                model: "default",
                prompt: "Edit test",
                environment: ProcessInfo.processInfo.environment.merging(["MOCK_DENY_EDIT": "1"]) { _, new in new },
                toolAccess: .readOnly,
                resumeSessionID: nil,
                timeout: 5,
                maxTotalTimeout: 10,
                killGracePeriod: 0.2,
                onEvent: nil
            )
            XCTFail("Expected denied permission error")
        } catch {
            let desc = error.localizedDescription.lowercased()
            XCTAssertTrue(desc.contains("edit") || desc.contains("只读") || desc.contains("permission"))
        }
    }

    func testClaudeAndCodexStreamingAndResumeAdapters() async throws {
        let claudeArgs = ClaudeCLIAdapter.generateArguments(
            model: "claude-sonnet-4-6",
            jsonSchema: nil,
            toolAccess: .readOnly,
            streaming: true,
            resumeSessionID: "c-sess-1",
            persistSession: true
        )
        XCTAssertTrue(claudeArgs.contains("stream-json"))
        XCTAssertTrue(claudeArgs.contains("--verbose"))
        XCTAssertTrue(claudeArgs.contains("--include-partial-messages"))
        XCTAssertTrue(claudeArgs.contains("--resume"))
        XCTAssertTrue(claudeArgs.contains("c-sess-1"))
        XCTAssertFalse(claudeArgs.contains("--no-session-persistence"))

        let codexArgs = CodexCLIAdapter.generateArguments(
            model: "gpt-5.3-codex",
            outputSchemaPath: nil,
            toolAccess: .readOnly,
            resumeSessionID: "x-sess-1",
            persistSession: true
        )
        XCTAssertEqual(Array(codexArgs.prefix(2)), ["exec", "resume"])
        XCTAssertTrue(codexArgs.contains("x-sess-1"))
        XCTAssertEqual(codexArgs.last, "-")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockClaude = tempDir.appendingPathComponent("mock-claude.sh")
        let claudeScript = """
        #!/bin/sh
        cat >/dev/null
        echo '{"type":"system","subtype":"init","session_id":"c-sess-1"}'
        echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"Thinking..."}}}'
        echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"CLAUDE-"}}}'
        echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"OK"}}}'
        echo '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"cu1","name":"Bash","input":{"command":"git status"}},{"type":"text","text":"CLAUDE-OK"}]}}'
        echo '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"cu1","content":"clean"}]}}'
        echo '{"type":"result","session_id":"c-sess-1","result":"CLAUDE-OK"}'
        """
        try claudeScript.write(to: mockClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockClaude.path)

        final class EventRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [AgentStreamEvent] = []
            func append(_ event: AgentStreamEvent) {
                lock.lock()
                storage.append(event)
                lock.unlock()
            }
            var events: [AgentStreamEvent] {
                lock.lock()
                defer { lock.unlock() }
                return storage
            }
        }

        let claudeRecorder = EventRecorder()
        let claudeRes = try await ClaudeCLIAdapter.generateWithSession(
            executable: mockClaude.path,
            cwd: tempDir,
            model: "claude-sonnet-4-6",
            prompt: "Review",
            jsonSchema: nil,
            environment: ProcessInfo.processInfo.environment,
            toolAccess: .readOnly,
            resumeSessionID: nil,
            persistSession: true,
            timeout: 5,
            killGracePeriod: 0.2
        ) { claudeRecorder.append($0) }
        let claudeEvents = claudeRecorder.events
        XCTAssertEqual(claudeRes.sessionID, "c-sess-1")
        XCTAssertEqual(claudeRes.text, "CLAUDE-OK")
        XCTAssertTrue(claudeEvents.contains(.sessionStarted("c-sess-1")))
        XCTAssertTrue(claudeEvents.contains(.thinkingDelta("Thinking...")))
        XCTAssertTrue(claudeEvents.contains(.messageDelta("CLAUDE-")))
        XCTAssertTrue(claudeEvents.contains(.messageDelta("OK")))

        let mockCodex = tempDir.appendingPathComponent("mock-codex.sh")
        let codexScript = """
        #!/bin/sh
        cat >/dev/null
        echo '{"type":"thread.started","thread_id":"x-thread-1"}'
        echo '{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"Checking diff"}}'
        echo '{"type":"item.started","item":{"id":"cmd1","type":"command_execution","command":"git diff --stat","status":"in_progress"}}'
        echo '{"type":"item.completed","item":{"id":"cmd1","type":"command_execution","command":"git diff --stat","status":"completed","aggregated_output":"1 file"}}'
        echo '{"type":"item.completed","item":{"id":"m1","type":"agent_message","text":"CODEX-OK"}}'
        """
        try codexScript.write(to: mockCodex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockCodex.path)

        let codexRecorder = EventRecorder()
        let codexRes = try await CodexCLIAdapter.generateWithSession(
            executable: mockCodex.path,
            cwd: tempDir,
            model: "gpt-5.3-codex",
            prompt: "Review",
            jsonSchema: nil,
            environment: ProcessInfo.processInfo.environment,
            toolAccess: .readOnly,
            resumeSessionID: nil,
            persistSession: true,
            timeout: 5,
            killGracePeriod: 0.2
        ) { codexRecorder.append($0) }
        let codexEvents = codexRecorder.events
        XCTAssertEqual(codexRes.sessionID, "x-thread-1")
        XCTAssertEqual(codexRes.text, "CODEX-OK")
        XCTAssertTrue(codexEvents.contains(.sessionStarted("x-thread-1")))
        XCTAssertTrue(codexEvents.contains(.thinkingDelta("Checking diff")))
        XCTAssertTrue(codexEvents.contains(.messageDelta("CODEX-OK")))
    }

    func testACPReadOnlyShellValidatorSupportsForIfAndCurlyVariables() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("dif-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }

        let allowed = [
            "SHA=b384d72f30c2c9768a7da35331382d3ac8253fe8 ; echo \"=== Check git show for key commits on the 8 files ===\" ; for c in 66e239fc19ef61fbac6777eb5d968a4dd7a50d72 dc2a806f7b095a68b7c711e2209ccd1c5414908d; do git log -1 --format=\"%h %s\" \"$c\"; done",
            "SHA=b384d72f30c2c9768a7da35331382d3ac8253fe8\ngit show \"${SHA}:Sources/App.swift\" | nl -ba",
            "for f in Sources/App.swift Sources/Other.swift; do cat \"$f\"; done",
            "if [ -f Sources/App.swift ]; then echo ok; else echo missing; fi",
            "diff -u Sources/A.swift Sources/B.swift"
        ]
        for cmd in allowed {
            XCTAssertTrue(ACPTransport.isReadOnlyShellCommand(cmd, repoRoot: repo), "Expected allow: \(cmd)")
        }

        let denied = [
            "for f in /etc/passwd; do cat \"$f\"; done",
            "for PATH in /tmp; do git status; done",
            "for c in a b; do rm -rf \"$c\"; done",
            "echo ${PATH:=evil}",
            "for f in a b; do echo \"$f\"",
            "while true; do git status; done",
            "cat \"$UNBOUND_SECRET\""
        ]
        for cmd in denied {
            XCTAssertFalse(ACPTransport.isReadOnlyShellCommand(cmd, repoRoot: repo), "Expected deny: \(cmd)")
            if case .failure = ACPTransport.evaluateReadOnlyShellCommand(cmd, repoRoot: repo) {
                // Expected structured reason
            } else {
                XCTFail("Expected structured failure reason for: \(cmd)")
            }
        }
    }

    func testACPSoftDenialRecoveryContinuesSameSession() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-softdeny-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mockScript = tempDir.appendingPathComponent("mock-softdeny.py")
        let python = """
        #!/usr/bin/env python3
        import json, sys, os

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\\n")
            sys.stdout.flush()

        prompt_count = 0
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            mid = msg.get("id")
            method = msg.get("method")
            params = msg.get("params") or {}

            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "sess-soft-1"}})
            elif method in ("session/set_model", "session/set_config_option"):
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif method == "session/prompt":
                sid = params.get("sessionId", "sess-soft-1")
                prompt_text = "".join(item.get("text", "") for item in params.get("prompt", []) if isinstance(item, dict))
                prompt_count += 1
                always_fail = os.environ.get("MOCK_ALWAYS_BLOCKED") == "1"
                if prompt_count == 1 or always_fail:
                    send({"jsonrpc": "2.0", "id": 7000 + prompt_count, "method": "session/request_permission", "params": {
                        "sessionId": sid,
                        "toolCall": {"toolCallId": f"tc-{prompt_count}", "kind": "edit", "title": "write report.md"},
                        "options": [{"optionId": "allow", "kind": "allow_once"}, {"optionId": "deny", "kind": "reject_once"}]
                    }})
                    _ = sys.stdin.readline()
                    send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
                    continue
                if "DiffCode Read-Only Policy Notice" in prompt_text:
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "RECOVERED-AFTER-BLOCK"}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
        """
        try Data(python.utf8).write(to: mockScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockScript.path)

        let res = try await ACPTransport.generateWithSession(
            provider: .agy,
            executable: mockScript.path,
            arguments: [],
            cwd: tempDir,
            model: "default",
            prompt: "Review",
            environment: ProcessInfo.processInfo.environment,
            toolAccess: .readOnly,
            resumeSessionID: nil,
            timeout: 5,
            maxTotalTimeout: 10,
            killGracePeriod: 0.2
        )
        XCTAssertEqual(res.text, "RECOVERED-AFTER-BLOCK")
        XCTAssertEqual(res.sessionID, "sess-soft-1")

        do {
            _ = try await ACPTransport.generateWithSession(
                provider: .agy,
                executable: mockScript.path,
                arguments: [],
                cwd: tempDir,
                model: "default",
                prompt: "Review",
                environment: ProcessInfo.processInfo.environment.merging(["MOCK_ALWAYS_BLOCKED": "1"]) { _, new in new },
                toolAccess: .readOnly,
                resumeSessionID: nil,
                timeout: 5,
                maxTotalTimeout: 10,
                killGracePeriod: 0.2,
                maxPermissionDeniedRecoveries: 1
            )
            XCTFail("Expected repeated denials to fail once maxPermissionDeniedRecoveries is exhausted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Read-only policy rejected tool call"))
        }
    }
}
