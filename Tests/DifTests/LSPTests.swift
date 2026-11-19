import Foundation
import XCTest
@testable import DifKit

final class LSPTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func makeTempDir(prefix: String = "dif-lsp-test") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let canonical = LSPURI.canonicalFileURL(dir)
        tempDirs.append(canonical)
        return canonical
    }

    private func writeFile(_ url: URL, contents: String, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    // MARK: - 1. JSON-RPC Content-Length Framing

    func testFramingRoundTripAndMultiByteUTF8() throws {
        let json = #"{"jsonrpc":"2.0","id":1,"result":{"text":"你好世界 🚀 café"}}"#
        let payload = Data(json.utf8)
        let frame = LSPMessageFraming.encode(payload)

        // Content-Length must be in UTF-8 bytes, not character count.
        let headerPrefix = "Content-Length: \(payload.count)\r\n\r\n"
        XCTAssertTrue(frame.starts(with: Data(headerPrefix.utf8)))
        XCTAssertGreaterThan(payload.count, json.count)

        var parser = LSPMessageFraming.Parser()
        let decoded = try parser.append(frame)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], payload)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testFramingPartialChunksAndConcatenatedMessages() throws {
        let msg1 = Data(#"{"jsonrpc":"2.0","id":1,"result":"first"}"#.utf8)
        let msg2 = Data(#"{"jsonrpc":"2.0","id":2,"result":"第二条🎉"}"#.utf8)
        let msg3 = Data(#"{"jsonrpc":"2.0","method":"window/logMessage","params":{}}"#.utf8)

        var combined = Data()
        combined.append(LSPMessageFraming.encode(msg1))
        // Include extra Content-Type header and lowercase content-length for msg2
        combined.append(Data("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\ncontent-length: \(msg2.count)\r\n\r\n".utf8))
        combined.append(msg2)
        combined.append(LSPMessageFraming.encode(msg3))

        // Feed byte-by-byte to stress partial headers and partial multi-byte bodies.
        var byteParser = LSPMessageFraming.Parser()
        var byteMessages: [Data] = []
        for byte in combined {
            byteMessages.append(contentsOf: try byteParser.append(Data([byte])))
        }
        XCTAssertEqual(byteMessages, [msg1, msg2, msg3])
        XCTAssertEqual(byteParser.bufferedByteCount, 0)

        // Feed all three concatenated in a single chunk.
        var bulkParser = LSPMessageFraming.Parser()
        let bulkMessages = try bulkParser.append(combined)
        XCTAssertEqual(bulkMessages, [msg1, msg2, msg3])
        XCTAssertEqual(bulkParser.bufferedByteCount, 0)
    }

    func testFramingMalformedHeaderThrows() {
        var parser = LSPMessageFraming.Parser()
        XCTAssertThrowsError(try parser.append(Data("X-Other: 42\r\n\r\n{}".utf8))) { error in
            guard case LSPTransportError.malformedMessage = error else {
                return XCTFail("Expected malformedMessage, got \(error)")
            }
        }

        var parser2 = LSPMessageFraming.Parser()
        XCTAssertThrowsError(try parser2.append(Data("Content-Length: notanumber\r\n\r\n{}".utf8))) { error in
            guard case LSPTransportError.malformedMessage = error else {
                return XCTFail("Expected malformedMessage, got \(error)")
            }
        }
    }

    // MARK: - 2. go.work Parser & Upward Discovery

    func testGoWorkParserHandlesSingleBlockCommentsQuotesAndRelativePaths() throws {
        let base = try makeTempDir(prefix: "dif-gowork-parse")
        let workspaceDir = base.appendingPathComponent("ws", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)

        let content = """
        // Leading comment
        go 1.22.1
        toolchain go1.22.1

        use ./modA // inline comment

        use (
            ./modB
            ../sibling-repo // external repo
            "./dir with spaces"
            `../raw//not-a-comment`
        )

        replace (
            example.com/foo => ./local-foo
            example.com/bar => ../local-bar
        )

        use ( ./single-line-block )
        """

        let roots = GoWorkspaceResolver.parseGoWork(content: content, baseDirectory: workspaceDir)
        let crlfRoots = GoWorkspaceResolver.parseGoWork(
            content: content.replacingOccurrences(of: "\n", with: "\r\n"),
            baseDirectory: workspaceDir
        )
        let expected = [
            LSPURI.canonicalFileURL(workspaceDir.appendingPathComponent("modA")),
            LSPURI.canonicalFileURL(workspaceDir.appendingPathComponent("modB")),
            LSPURI.canonicalFileURL(base.appendingPathComponent("sibling-repo")),
            LSPURI.canonicalFileURL(workspaceDir.appendingPathComponent("dir with spaces")),
            LSPURI.canonicalFileURL(base.appendingPathComponent("raw/not-a-comment")),
            LSPURI.canonicalFileURL(workspaceDir.appendingPathComponent("single-line-block")),
        ]
        XCTAssertEqual(roots, expected)
        XCTAssertEqual(crlfRoots, expected)
    }

    func testGoWorkUpwardDiscoveryAndCrossRepoResolution() throws {
        let root = try makeTempDir(prefix: "dif-gowork-discover")
        let repoA = root.appendingPathComponent("repoA", isDirectory: true)
        let repoB = root.appendingPathComponent("repoB", isDirectory: true)
        let repoAB = root.appendingPathComponent("repoAB", isDirectory: true)

        let goWorkURL = root.appendingPathComponent("go.work")
        try writeFile(goWorkURL, contents: """
        go 1.22

        use (
            ./repoA
            ./repoB
        )
        """)
        let fileA = repoA.appendingPathComponent("pkg/service/handler.go")
        let fileB = repoB.appendingPathComponent("lib/util.go")
        let fileAB = repoAB.appendingPathComponent("main.go")
        try writeFile(fileA, contents: "package service\n")
        try writeFile(fileB, contents: "package lib\n")
        try writeFile(fileAB, contents: "package main\n")

        // Walk upward from deep inside repoA to root/go.work
        let info = try XCTUnwrap(GoWorkspaceResolver.resolve(for: fileA, repoRoot: repoA))
        XCTAssertEqual(info.rootURL, root)
        XCTAssertEqual(info.goWorkURL, goWorkURL)
        XCTAssertEqual(info.memberRoots, [repoA, repoB])

        // Check workspace roots and cross-repo containingRepoRoot
        let roots = GoWorkspaceResolver.workspaceRoots(for: fileA, repoRoot: repoA)
        XCTAssertTrue(roots.contains(repoA))
        XCTAssertTrue(roots.contains(repoB))

        XCTAssertEqual(
            GoWorkspaceResolver.containingRepoRoot(for: fileB, relativeTo: fileA, repoRoot: repoA),
            repoB
        )
        XCTAssertEqual(
            GoWorkspaceResolver.containingRepoRoot(for: fileA, relativeTo: fileA, repoRoot: repoA),
            repoA
        )

        // Path-component boundary check: repoAB is NOT inside repoA
        XCTAssertFalse(LSPURI.isPath(fileAB, inside: repoA))
        XCTAssertNil(info.containingMemberRoot(for: fileAB))
    }

    func testGoWorkInsideRepoReferencingSiblingRepo() throws {
        let root = try makeTempDir(prefix: "dif-gowork-sibling")
        let repoA = root.appendingPathComponent("repoA", isDirectory: true)
        let repoB = root.appendingPathComponent("repoB", isDirectory: true)
        let fileA = repoA.appendingPathComponent("main.go")
        let fileB = repoB.appendingPathComponent("helper.go")

        try writeFile(repoA.appendingPathComponent("go.work"), contents: """
        go 1.22

        use (
            .
            ../repoB
        )
        """)
        try writeFile(fileA, contents: "package main\n")
        try writeFile(fileB, contents: "package repob\n")

        let info = try XCTUnwrap(GoWorkspaceResolver.resolve(for: fileA, repoRoot: repoA))
        XCTAssertEqual(info.rootURL, repoA)
        XCTAssertEqual(info.memberRoots, [repoA, repoB])
        XCTAssertEqual(
            GoWorkspaceResolver.containingRepoRoot(for: fileB, relativeTo: fileA, repoRoot: repoA),
            repoB
        )
    }

    func testGoWorkspaceFallbackToGoModThenRepoRoot() throws {
        let root = try makeTempDir(prefix: "dif-gomod-fallback")
        let repo = root.appendingPathComponent("myrepo", isDirectory: true)
        let subMod = repo.appendingPathComponent("services/api", isDirectory: true)
        let goFile = subMod.appendingPathComponent("cmd/main.go")
        let plainFile = repo.appendingPathComponent("tools/script.go")

        try writeFile(subMod.appendingPathComponent("go.mod"), contents: "module example.com/api\n\ngo 1.22\n")
        try writeFile(goFile, contents: "package main\n")
        try writeFile(plainFile, contents: "package tools\n")

        // Falls back to nearest go.mod when no go.work exists
        XCTAssertEqual(GoWorkspaceResolver.workspaceRoot(for: goFile, repoRoot: repo), subMod)
        // Falls back to repoRoot when neither go.work nor go.mod exists
        XCTAssertEqual(GoWorkspaceResolver.workspaceRoot(for: plainFile, repoRoot: repo), repo)
    }

    // MARK: - 3. Semantic Tokens Mapping & Delta Decoding

    func testSemanticTokenKindMappingAndDefaultLibrary() {
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "namespace", modifiers: []), .namespace)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "type", modifiers: []), .type)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "struct", modifiers: []), .type)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "interface", modifiers: []), .interface)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "typeParameter", modifiers: []), .typeParameter)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "parameter", modifiers: []), .parameter)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "variable", modifiers: []), .variable)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "variable", modifiers: ["readonly"]), .constant)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "property", modifiers: []), .property)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "function", modifiers: []), .function)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "method", modifiers: []), .method)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "keyword", modifiers: []), .keyword)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "comment", modifiers: []), .comment)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "string", modifiers: []), .string)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "number", modifiers: []), .number)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "operator", modifiers: []), .operator)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "unknownToken", modifiers: []), .plain)

        // defaultLibrary maps builtins like len, make, append, string, int, error, nil -> .builtin
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "function", modifiers: ["defaultLibrary"]), .builtin)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "type", modifiers: ["defaultLibrary"]), .builtin)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "interface", modifiers: ["defaultLibrary"]), .builtin)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "variable", modifiers: ["readonly", "defaultLibrary"]), .builtin)
        // keyword and namespace keep their own kinds even if defaultLibrary were attached
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "keyword", modifiers: ["defaultLibrary"]), .keyword)
        XCTAssertEqual(LSPSemanticTokenKind.map(tokenType: "namespace", modifiers: ["defaultLibrary"]), .namespace)
    }

    func testSemanticTokensFullDeltaDecoding() {
        let legend = LSPSemanticTokensLegend(
            tokenTypes: ["namespace", "type", "function", "variable", "keyword", "method"],
            tokenModifiers: ["definition", "readonly", "defaultLibrary"]
        )
        // Bitmasks: definition = 1, readonly = 2, defaultLibrary = 4
        let data: [Int] = [
            // Line 0: col 0 len 4 `func` (keyword)
            0, 0, 4, 4, 0,
            // Line 0: col 5 len 4 `main` (function + definition) -> deltaStart = 5
            0, 5, 4, 2, 1,
            // Line 2: col 4 len 3 `len` (function + defaultLibrary) -> deltaLine = 2, start resets to 4
            2, 4, 3, 2, 4,
            // Line 2: col 8 len 3 `fmt` (namespace) -> deltaLine = 0, deltaStart = 4 => col 8
            0, 4, 3, 0, 0,
            // Line 2: col 12 len 7 `Println` (function) -> deltaLine = 0, deltaStart = 4 => col 12
            0, 4, 7, 2, 0,
            // Line 5: col 1 len 3 `MAX` (variable + definition + readonly = bitmask 3) -> constant
            3, 1, 3, 3, 3,
            // Line 5: col 10 len 6 `string` (type + defaultLibrary = bitmask 4) -> builtin
            0, 9, 6, 1, 4,
            // Out-of-bounds type index ignored safely
            1, 0, 2, 99, 0,
        ]

        let decoded = LSPSemanticTokensDecoder.decode(data: data, legend: legend)
        XCTAssertEqual(decoded.keys.sorted(), [0, 2, 5])
        XCTAssertEqual(decoded[0], [
            LSPSemanticSpan(start: 0, length: 4, kind: .keyword),
            LSPSemanticSpan(start: 5, length: 4, kind: .function),
        ])
        XCTAssertEqual(decoded[2], [
            LSPSemanticSpan(start: 4, length: 3, kind: .builtin),
            LSPSemanticSpan(start: 8, length: 3, kind: .namespace),
            LSPSemanticSpan(start: 12, length: 7, kind: .function),
        ])
        XCTAssertEqual(decoded[5], [
            LSPSemanticSpan(start: 1, length: 3, kind: .constant),
            LSPSemanticSpan(start: 10, length: 6, kind: .builtin),
        ])
    }

    // MARK: - 4. textDocument/definition Decoding

    func testDefinitionDecodingAllThreeShapesAndNull() throws {
        // 1. null
        XCTAssertEqual(LSPDefinitionDecoder.decode(from: .null), [])

        // 2. Single Location
        let singleJSON = """
        {
          "uri": "file:///tmp/a.go",
          "range": {
            "start": { "line": 10, "character": 5 },
            "end": { "line": 10, "character": 12 }
          }
        }
        """
        let single = try LSPDefinitionDecoder.decode(from: Data(singleJSON.utf8))
        XCTAssertEqual(single, [
            LSPLocation(
                uri: "file:///tmp/a.go",
                range: LSPRange(
                    start: LSPPosition(line: 10, character: 5),
                    end: LSPPosition(line: 10, character: 12)
                )
            ),
        ])

        // 3. [Location]
        let arrayJSON = """
        [
          {
            "uri": "file:///tmp/a.go",
            "range": { "start": { "line": 1, "character": 0 }, "end": { "line": 1, "character": 4 } }
          },
          {
            "uri": "file:///tmp/b.go",
            "range": { "start": { "line": 20, "character": 2 }, "end": { "line": 20, "character": 8 } }
          }
        ]
        """
        let array = try LSPDefinitionDecoder.decode(from: Data(arrayJSON.utf8))
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0].uri, "file:///tmp/a.go")
        XCTAssertEqual(array[1].uri, "file:///tmp/b.go")
        XCTAssertEqual(array[1].range.start, LSPPosition(line: 20, character: 2))

        // 4. [LocationLink] -> uses targetUri and targetSelectionRange
        let linkJSON = """
        [
          {
            "originSelectionRange": { "start": { "line": 3, "character": 1 }, "end": { "line": 3, "character": 6 } },
            "targetUri": "file:///tmp/repoB/greet.go",
            "targetRange": { "start": { "line": 4, "character": 0 }, "end": { "line": 8, "character": 1 } },
            "targetSelectionRange": { "start": { "line": 4, "character": 5 }, "end": { "line": 4, "character": 10 } }
          }
        ]
        """
        let links = try LSPDefinitionDecoder.decode(from: Data(linkJSON.utf8))
        XCTAssertEqual(links, [
            LSPLocation(
                uri: "file:///tmp/repoB/greet.go",
                range: LSPRange(
                    start: LSPPosition(line: 4, character: 5),
                    end: LSPPosition(line: 4, character: 10)
                )
            ),
        ])
    }

    // MARK: - 5. URI Conversion, Registry & Binary Locator

    func testURIRoundTripWithSpacesAndUnicode() throws {
        let dir = try makeTempDir(prefix: "dif-uri test 中文")
        let file = dir.appendingPathComponent("hello 世界.go")
        try writeFile(file, contents: "package main\n")

        let uri = LSPURI.uri(from: file)
        XCTAssertTrue(uri.hasPrefix("file:///"))
        XCTAssertFalse(uri.contains(" "))

        let roundTripped = try XCTUnwrap(LSPURI.fileURL(from: uri))
        XCTAssertEqual(roundTripped, file)
    }

    func testServerRegistryMappingsAndPythonFallbackPriority() throws {
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .go)?.candidates.first?.executableName, "gopls")
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .go)?.candidates.first?.arguments, ["serve"])
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .go)?.initializationOptions?["semanticTokens"]?.boolValue, true)

        XCTAssertEqual(LSPServerRegistry.descriptor(for: .rust)?.candidates.first?.executableName, "rust-analyzer")
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .swift)?.candidates.first?.executableName, "sourcekit-lsp")
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .javascript)?.candidates.first?.executableName, "typescript-language-server")
        XCTAssertEqual(LSPServerRegistry.descriptor(for: .cFamily)?.candidates.first?.executableName, "clangd")
        XCTAssertEqual(
            LSPServerRegistry.descriptor(for: .python)?.candidates.map(\.executableName),
            ["basedpyright-langserver", "pyright-langserver", "pylsp"]
        )

        // Verify candidate fallback priority against isolated temp bin dir
        let binDir = try makeTempDir(prefix: "dif-py-bins")
        let pylsp = binDir.appendingPathComponent("pylsp")
        try writeFile(pylsp, contents: "#!/bin/sh\nexit 0\n", executable: true)

        let firstResolved = try XCTUnwrap(
            LSPServerRegistry.resolveServer(for: LSPServerRegistry.python, searchPaths: [binDir.path], environment: [:])
        )
        XCTAssertEqual(firstResolved.executablePath, pylsp.path)

        let basedpyright = binDir.appendingPathComponent("basedpyright-langserver")
        try writeFile(basedpyright, contents: "#!/bin/sh\nexit 0\n", executable: true)
        let secondResolved = try XCTUnwrap(
            LSPServerRegistry.resolveServer(for: LSPServerRegistry.python, searchPaths: [binDir.path], environment: [:])
        )
        XCTAssertEqual(secondResolved.executablePath, basedpyright.path)
    }

    func testParseMarkedNullDelimitedEnvIgnoresBannerNoise() {
        var raw = Data("Now using version go1.24.4\n".utf8)
        raw.append(Data("__DIF_LSP_ENV_START__".utf8))
        raw.append(Data("PATH=/custom/bin:/usr/bin".utf8))
        raw.append(0)
        raw.append(Data("GOPATH=/Users/dev/go".utf8))
        raw.append(0)
        raw.append(Data("__DIF_LSP_ENV_END__trailing noise".utf8))

        let parsed = LSPBinaryLocator.parseMarkedNullDelimitedEnv(raw)
        XCTAssertEqual(parsed?["PATH"], "/custom/bin:/usr/bin")
        XCTAssertEqual(parsed?["GOPATH"], "/Users/dev/go")
    }

    // MARK: - 6. End-to-End Mock Stdio LSP Server

    func testMockStdioServerLifecycleConcurrencyServerRequestsCancellationAndIdleReaper() async throws {
        let dir = try makeTempDir(prefix: "dif-mock-lsp")
        let scriptURL = dir.appendingPathComponent("mock_lsp.py")
        let sourceURL = dir.appendingPathComponent("sample.go")
        let targetURL = dir.appendingPathComponent("target.go")
        try writeFile(sourceURL, contents: "package main\nfunc main() { _ = len(\"hi\") }\n")
        try writeFile(targetURL, contents: "package main\nfunc Helper() {}\n")

        let targetURI = LSPURI.uri(from: targetURL)
        let mockServerScript = """
        #!/usr/bin/env python3
        import json, sys, time

        def send(msg):
            body = json.dumps(msg).encode("utf-8")
            header = f"Content-Length: {len(body)}\\r\\n\\r\\n".encode("ascii")
            sys.stdout.buffer.write(header + body)
            sys.stdout.buffer.flush()

        def read_msg():
            headers = {}
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line in (b"\\r\\n", b"\\n"):
                    break
                if b":" in line:
                    k, v = line.decode("ascii").split(":", 1)
                    headers[k.strip().lower()] = v.strip()
            length = int(headers.get("content-length", "0"))
            body = sys.stdin.buffer.read(length)
            if not body:
                return None
            return json.loads(body.decode("utf-8"))

        opened_docs = {}
        server_req_id = 100
        seen_server_responses = {}

        # Write something to stderr to verify stderr suppression/capture doesn't break stdout framing.
        sys.stderr.write("mock-lsp-started\\n")
        sys.stderr.flush()

        while True:
            msg = read_msg()
            if msg is None:
                break

            # Track responses from client to our server-to-client requests.
            if "method" not in msg and "id" in msg:
                seen_server_responses[msg["id"]] = msg.get("result")
                continue

            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}

            if method == "initialize":
                # Proactively issue server-to-client requests before replying to initialize!
                for srv_method, srv_params in [
                    ("workspace/configuration", {"items": [{"section": "gopls"}]}),
                    ("client/registerCapability", {"registrations": []}),
                    ("window/workDoneProgress/create", {"token": "tok-1"}),
                ]:
                    server_req_id += 1
                    send({"jsonrpc": "2.0", "id": server_req_id, "method": srv_method, "params": srv_params})
                    # Wait for the client to respond to ensure client never deadlocks on server requests.
                    reply = read_msg()
                    assert reply is not None and reply.get("id") == server_req_id

                init_opts = params.get("initializationOptions") or {}
                assert init_opts.get("semanticTokens") is True, f"missing semanticTokens init option: {init_opts}"

                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "definitionProvider": True,
                            "semanticTokensProvider": {
                                "legend": {
                                    "tokenTypes": ["keyword", "function", "type", "variable"],
                                    "tokenModifiers": ["definition", "readonly", "defaultLibrary"],
                                },
                                "full": True,
                            },
                        }
                    },
                })
            elif method == "textDocument/didOpen":
                td = params["textDocument"]
                opened_docs[td["uri"]] = td["text"]
            elif method == "textDocument/didChange":
                td = params["textDocument"]
                opened_docs[td["uri"]] = params["contentChanges"][0]["text"]
            elif method == "textDocument/didSave":
                pass
            elif method == "textDocument/didClose":
                opened_docs.pop(params["textDocument"]["uri"], None)
            elif method == "textDocument/semanticTokens/full":
                uri = params["textDocument"]["uri"]
                text = opened_docs.get(uri, "")
                # Return different tokens after didChange so we prove didChange updated server state.
                if "UPDATED" in text:
                    data = [0, 0, 7, 2, 0] # line 0, col 0, len 7, type
                else:
                    data = [0, 0, 7, 0, 0, 1, 0, 4, 0, 0, 0, 5, 4, 1, 1, 0, 13, 3, 1, 4]
                send({"jsonrpc": "2.0", "id": req_id, "result": {"data": data}})
            elif method == "textDocument/definition":
                # Return LocationLink to exercise link decoding end-to-end.
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": [{
                        "targetUri": "\(targetURI)",
                        "targetRange": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 16}},
                        "targetSelectionRange": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 11}},
                    }],
                })
            elif method == "custom/echo":
                send({"jsonrpc": "2.0", "id": req_id, "result": params})
            elif method == "custom/hang":
                # Do not reply; client will cancel this request.
                pass
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockServerScript, executable: true)

        // Part A: Direct transport tests (stderr capture, concurrent requests, cancellation)
        let transport = LSPTransport(
            executable: "/usr/bin/python3",
            arguments: [scriptURL.path],
            onServerRequest: { method, params in
                LSPTransport.defaultServerRequestResponse(
                    method: method,
                    params: params,
                    configurationSettings: .object(["semanticTokens": .bool(true)])
                )
            }
        )
        try await transport.start()
        let initResp = try await transport.request(
            method: "initialize",
            params: .object(["initializationOptions": .object(["semanticTokens": .bool(true)])]),
            timeout: .seconds(5)
        )
        XCTAssertNotNil(initResp["capabilities"])

        // Concurrent requests
        async let r1 = transport.request(method: "custom/echo", params: .object(["v": .int(1)]), timeout: .seconds(5))
        async let r2 = transport.request(method: "custom/echo", params: .object(["v": .int(2)]), timeout: .seconds(5))
        async let r3 = transport.request(method: "custom/echo", params: .object(["v": .int(3)]), timeout: .seconds(5))
        let (v1, v2, v3) = try await (r1, r2, r3)
        XCTAssertEqual(v1["v"]?.intValue, 1)
        XCTAssertEqual(v2["v"]?.intValue, 2)
        XCTAssertEqual(v3["v"]?.intValue, 3)

        // Cancellation
        let cancelTask = Task<JSONValue, any Error> {
            try await transport.request(method: "custom/hang", params: .null)
        }
        try await Task.sleep(for: .milliseconds(60))
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            XCTFail("Expected cancelled request to throw")
        } catch let error as LSPTransportError {
            XCTAssertEqual(error, .cancelled)
        }

        // Stderr captured cleanly
        let stderrText = await transport.recentStderr()
        XCTAssertTrue(stderrText.contains("mock-lsp-started"), "stderr was: \(stderrText)")

        await transport.shutdown()
        let runningAfterShutdown = await transport.isRunning
        XCTAssertFalse(runningAfterShutdown)

        // Part B: Full LSPManager flow + gating + idle reaper
        let mockResolved = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(
            isEnabled: true,
            idleTimeout: .milliseconds(250),
            serverOverrides: [LSPServerRegistry.go.id: mockResolved]
        )

        let session = await manager.didOpen(fileURL: sourceURL, text: "package main\nfunc main() { _ = len(\"hi\") }\n", repoRoot: dir)
        XCTAssertNotNil(session)
        let runningCount = await manager.runningServerCount()
        XCTAssertEqual(runningCount, 1)

        let rawSpans = await manager.semanticTokens(fileURL: sourceURL)
        let spans = try XCTUnwrap(rawSpans)
        XCTAssertEqual(spans[0], [LSPSemanticSpan(start: 0, length: 7, kind: .keyword)])
        XCTAssertEqual(spans[1], [
            LSPSemanticSpan(start: 0, length: 4, kind: .keyword),
            LSPSemanticSpan(start: 5, length: 4, kind: .function),
            LSPSemanticSpan(start: 18, length: 3, kind: .builtin),
        ])

        await manager.didChange(fileURL: sourceURL, version: 2, text: "UPDATED")
        await manager.didSave(fileURL: sourceURL, text: "UPDATED")
        let rawUpdatedSpans = await manager.semanticTokens(fileURL: sourceURL)
        let updatedSpans = try XCTUnwrap(rawUpdatedSpans)
        XCTAssertEqual(updatedSpans[0], [LSPSemanticSpan(start: 0, length: 7, kind: .type)])

        let defs = await manager.definition(fileURL: sourceURL, line: 1, character: 10)
        XCTAssertEqual(defs.count, 1)
        XCTAssertEqual(defs[0].fileURL, targetURL)
        XCTAssertEqual(defs[0].range.start, LSPPosition(line: 1, character: 5))

        await manager.didClose(fileURL: sourceURL)
        let closedSession = await manager.openSession(forURI: LSPURI.uri(from: sourceURL))
        XCTAssertNil(closedSession)

        // Wait for idle reaper to shut down the inactive server automatically.
        try await Task.sleep(for: .milliseconds(450))
        let countAfterReap = await manager.runningServerCount()
        XCTAssertEqual(countAfterReap, 0)

        // Verify isEnabled == false gating prevents launching any server.
        await manager.setEnabled(false)
        let gatedSession = await manager.didOpen(fileURL: sourceURL, text: "package main\n", repoRoot: dir)
        XCTAssertNil(gatedSession)
        let gatedCount = await manager.runningServerCount()
        XCTAssertEqual(gatedCount, 0)

        await manager.shutdownAll()
    }

    // MARK: - 7. Real gopls Cross-Repo go.work Integration Test

    func testRealGoplsMultiRepoGoWorkSemanticTokensAndCrossRepoDefinition() async throws {
        guard let goplsResolved = LSPServerRegistry.resolveServer(for: LSPServerRegistry.go),
              LSPBinaryLocator.resolve(executable: "go") != nil else {
            throw XCTSkip("gopls or go toolchain not installed in PATH")
        }
        _ = goplsResolved

        let root = try makeTempDir(prefix: "dif-real-gopls")
        let repoA = root.appendingPathComponent("repoA", isDirectory: true)
        let repoB = root.appendingPathComponent("repoB", isDirectory: true)

        try writeFile(root.appendingPathComponent("go.work"), contents: """
        go 1.21

        use (
            ./repoA
            ./repoB
        )
        """)

        try writeFile(repoB.appendingPathComponent("go.mod"), contents: """
        module example.com/repob

        go 1.21
        """)

        let greetURL = repoB.appendingPathComponent("greet.go")
        let greetCode = """
        package repob

        // Greet returns a greeting for name.
        func Greet(name string) string {
        \treturn "hello " + name
        }
        """
        try writeFile(greetURL, contents: greetCode)

        try writeFile(repoA.appendingPathComponent("go.mod"), contents: """
        module example.com/repoa

        go 1.21

        require example.com/repob v0.0.0
        """)

        let mainURL = repoA.appendingPathComponent("main.go")
        let mainCode = """
        package main

        import "example.com/repob"

        func main() {
        \tmsg := repob.Greet("world")
        \t_ = len(msg)
        }
        """
        try writeFile(mainURL, contents: mainCode)

        let manager = LSPManager(isEnabled: true)
        // Open main.go passing ONLY repoA as repoRoot; LSPManager must discover parent go.work!
        let session = await manager.didOpen(fileURL: mainURL, text: mainCode, repoRoot: repoA)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.workspaceRoot, root)

        // 1. Semantic tokens from real gopls
        var tokens: [Int: [LSPSemanticSpan]]?
        for _ in 0..<5 {
            tokens = await manager.semanticTokens(fileURL: mainURL)
            if let tokens, !tokens.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let semanticMap = try XCTUnwrap(tokens, "Expected gopls to return semantic tokens")
        let allKinds = Set(semanticMap.values.flatMap { $0.map(\.kind) })
        XCTAssertTrue(allKinds.contains(.namespace), "Expected .namespace in gopls tokens, got: \(allKinds)")
        XCTAssertTrue(allKinds.contains(.function), "Expected .function in gopls tokens, got: \(allKinds)")
        XCTAssertTrue(allKinds.contains(.builtin), "Expected .builtin (for len) in gopls tokens, got: \(allKinds)")

        // 2. Cross-repo textDocument/definition from repoA/main.go -> repoB/greet.go
        // Line 5 (0-based): `\tmsg := repob.Greet("world")` -> `Greet` starts at UTF-16 column 14
        let defs = await manager.definition(fileURL: mainURL, line: 5, character: 15)
        XCTAssertFalse(defs.isEmpty, "Expected gopls to resolve cross-repo definition for repob.Greet")
        let target = try XCTUnwrap(defs.first)
        XCTAssertEqual(target.fileURL, greetURL)
        XCTAssertEqual(target.range.start.line, 3) // 0-based line of `func Greet(name string) string {`

        // 3. Verify UI helper detects the target lives in repoB (a different repo from repoA)
        let targetRepo = manager.containingRepoRoot(for: try XCTUnwrap(target.fileURL), relativeTo: mainURL, repoRoot: repoA)
        XCTAssertEqual(targetRepo, repoB)

        await manager.shutdownAll()
        let remaining = await manager.runningServerCount()
        XCTAssertEqual(remaining, 0)
    }
}
