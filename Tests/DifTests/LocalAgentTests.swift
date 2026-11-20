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
}
