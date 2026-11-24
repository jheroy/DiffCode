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
        XCTAssertEqual(
            LSPServerRegistry.descriptor(for: .go)?.candidates.first?.arguments,
            ["-remote=auto", "-remote.listen.timeout=2m"]
        )
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

    func testGoplsLightweightDescriptorConfiguration() throws {
        let goDesc = LSPServerRegistry.go
        let cmd = try XCTUnwrap(goDesc.candidates.first)
        XCTAssertEqual(cmd.executableName, "gopls")
        XCTAssertEqual(cmd.arguments, ["-remote=auto", "-remote.listen.timeout=2m"])
        XCTAssertEqual(goDesc.extraEnvironment, ["GOGC": "50", "GOMEMLIMIT": "1GiB"])
        XCTAssertEqual(goDesc.initializationOptions, goDesc.configurationSettings)

        for label in ["initializationOptions", "configurationSettings"] {
            let settings = try XCTUnwrap(
                label == "initializationOptions" ? goDesc.initializationOptions : goDesc.configurationSettings,
                "Missing \(label) on gopls descriptor"
            )
            XCTAssertEqual(settings["semanticTokens"]?.boolValue, true)
            XCTAssertEqual(settings["diagnosticsTrigger"]?.stringValue, "Save")
            XCTAssertEqual(settings["staticcheck"]?.boolValue, false)
            XCTAssertEqual(settings["vulncheck"]?.stringValue, "Off")
            XCTAssertEqual(settings["analysisProgressReporting"]?.boolValue, false)
            XCTAssertEqual(settings["completeFunctionCalls"]?.boolValue, false)
            XCTAssertEqual(settings["experimentalPostfixCompletions"]?.boolValue, false)
            XCTAssertEqual(settings["hoverKind"]?.stringValue, "NoDocumentation")
            XCTAssertEqual(settings["linksInHover"]?.boolValue, false)
            XCTAssertEqual(settings["hints"]?.objectValue, [:])

            let codelenses = try XCTUnwrap(settings["codelenses"]?.objectValue)
            for lens in ["generate", "regenerate_cgo", "run_govulncheck", "tidy", "upgrade_dependency", "vendor"] {
                XCTAssertEqual(codelenses[lens]?.boolValue, false, "Expected codelens \(lens) disabled")
            }

            let analyses = try XCTUnwrap(settings["analyses"]?.objectValue)
            XCTAssertFalse(analyses.isEmpty, "Expected explicit disabled analyzers map")
            XCTAssertNil(analyses["none"], "gopls does not support analyses.none; analyzers must be disabled explicitly")
            for (name, val) in analyses {
                XCTAssertEqual(val.boolValue, false, "Expected analyzer \(name) to be false")
            }
            for key in ["printf", "unreachable", "unusedparams", "unusedvariable", "modernize", "nilness", "copylocks"] {
                XCTAssertEqual(analyses[key]?.boolValue, false, "Expected default-on analyzer \(key) disabled")
            }

            let filters = try XCTUnwrap(settings["directoryFilters"]?.arrayValue).compactMap(\.stringValue)
            XCTAssertEqual(filters, ["-**/node_modules", "-**/.git", "-**/dist", "-**/build", "-**/testdata"])
            XCTAssertFalse(filters.contains(where: { $0.contains("vendor") }), "Do not exclude vendor directories")
        }
    }

    func testServerEnvironmentMergeRespectsUserOverrides() throws {
        // Direct merge helper: injects missing defaults and preserves user overrides.
        let defaults = ["GOGC": "50", "GOMEMLIMIT": "1GiB"]
        let mergedEmpty = LSPServerRegistry.mergedEnvironment(base: ["PATH": "/usr/bin"], defaults: defaults)
        XCTAssertEqual(mergedEmpty["PATH"], "/usr/bin")
        XCTAssertEqual(mergedEmpty["GOGC"], "50")
        XCTAssertEqual(mergedEmpty["GOMEMLIMIT"], "1GiB")

        let mergedOverride = LSPServerRegistry.mergedEnvironment(
            base: ["PATH": "/usr/bin", "GOGC": "200", "GOMEMLIMIT": "4GiB"],
            defaults: defaults
        )
        XCTAssertEqual(mergedOverride["GOGC"], "200")
        XCTAssertEqual(mergedOverride["GOMEMLIMIT"], "4GiB")

        let mergedPartial = LSPServerRegistry.mergedEnvironment(
            base: ["GOGC": "off"],
            defaults: defaults
        )
        XCTAssertEqual(mergedPartial["GOGC"], "off")
        XCTAssertEqual(mergedPartial["GOMEMLIMIT"], "1GiB")

        // Verify resolveServer(for: .go) merges extraEnvironment while preserving caller overrides.
        let binDir = try makeTempDir(prefix: "dif-gopls-env")
        let fakeGopls = binDir.appendingPathComponent("gopls")
        try writeFile(fakeGopls, contents: "#!/bin/sh\nexit 0\n", executable: true)

        let resolvedDefaults = try XCTUnwrap(
            LSPServerRegistry.resolveServer(
                for: LSPServerRegistry.go,
                searchPaths: [binDir.path],
                environment: ["PATH": binDir.path]
            )
        )
        XCTAssertEqual(resolvedDefaults.arguments, ["-remote=auto", "-remote.listen.timeout=2m"])
        XCTAssertEqual(resolvedDefaults.environment["GOGC"], "50")
        XCTAssertEqual(resolvedDefaults.environment["GOMEMLIMIT"], "1GiB")

        let resolvedUserOverride = try XCTUnwrap(
            LSPServerRegistry.resolveServer(
                for: LSPServerRegistry.go,
                searchPaths: [binDir.path],
                environment: ["PATH": binDir.path, "GOGC": "100"]
            )
        )
        XCTAssertEqual(resolvedUserOverride.environment["GOGC"], "100")
        XCTAssertEqual(resolvedUserOverride.environment["GOMEMLIMIT"], "1GiB")
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

        // 4. Cross-repo textDocument/references from repoB/greet.go (definition) -> finds call site in repoA/main.go
        let greetSession = await manager.didOpen(fileURL: greetURL, text: greetCode, repoRoot: repoB)
        XCTAssertNotNil(greetSession)

        var refsWithoutDecl: [LSPLocation] = []
        for _ in 0..<5 {
            refsWithoutDecl = await manager.references(fileURL: greetURL, line: 3, character: 6, includeDeclaration: false)
            if !refsWithoutDecl.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(
            refsWithoutDecl.contains { $0.fileURL == mainURL && $0.range.start.line == 5 },
            "Expected gopls references(includeDeclaration: false) on repoB/greet.go:Greet to find repoA/main.go:5, got: \(refsWithoutDecl)"
        )

        let refsWithDecl = await manager.references(fileURL: greetURL, line: 3, character: 6, includeDeclaration: true)
        XCTAssertTrue(
            refsWithDecl.contains { $0.fileURL == greetURL && $0.range.start.line == 3 },
            "Expected gopls references(includeDeclaration: true) to include declaration in repoB/greet.go:3, got: \(refsWithDecl)"
        )
        XCTAssertTrue(
            refsWithDecl.contains { $0.fileURL == mainURL && $0.range.start.line == 5 },
            "Expected gopls references(includeDeclaration: true) to include cross-repo call site in repoA/main.go:5, got: \(refsWithDecl)"
        )

        // 5. Verify gopls launched in -remote=auto lightweight mode with zero flag/option errors on stderr
        let stderr = await manager.recentStderr(forFileURL: mainURL) ?? ""
        let lowerStderr = stderr.lowercased()
        XCTAssertFalse(lowerStderr.contains("flag provided but not defined"), "Unexpected gopls flag error on stderr: \(stderr)")
        XCTAssertFalse(lowerStderr.contains("invalid settings"), "Unexpected gopls invalid settings on stderr: \(stderr)")
        XCTAssertFalse(lowerStderr.contains("unexpected setting"), "Unexpected gopls option warning on stderr: \(stderr)")
        XCTAssertFalse(lowerStderr.contains("unknown"), "Unexpected gopls unknown-option message on stderr: \(stderr)")

        await manager.shutdownAll()
        let remaining = await manager.runningServerCount()
        XCTAssertEqual(remaining, 0)

        // 6. Verify direct LSPTransport handshake with gopls lightweight options produces zero Invalid settings notifications
        final class NotificationCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var messages: [(type: Int, message: String)] = []
            func append(type: Int, message: String) {
                lock.lock()
                messages.append((type, message))
                lock.unlock()
            }
            func snapshot() -> [(type: Int, message: String)] {
                lock.lock()
                defer { lock.unlock() }
                return messages
            }
        }
        let notifications = NotificationCollector()
        let directTransport = LSPTransport(
            executable: goplsResolved.executablePath,
            arguments: goplsResolved.arguments,
            environment: goplsResolved.environment,
            workingDirectory: root,
            onNotification: { method, params in
                if method == "window/showMessage",
                   let msg = params?["message"]?.stringValue {
                    let msgType = params?["type"]?.intValue ?? 3
                    notifications.append(type: msgType, message: msg)
                }
            },
            onServerRequest: { method, params in
                LSPTransport.defaultServerRequestResponse(
                    method: method,
                    params: params,
                    configurationSettings: LSPServerRegistry.go.configurationSettings
                )
            }
        )
        try await directTransport.start()
        var directInitParams: [String: JSONValue] = [
            "processId": .int(Int(ProcessInfo.processInfo.processIdentifier)),
            "rootUri": .string(LSPURI.uri(from: root)),
            "workspaceFolders": .array([
                .object(["uri": .string(LSPURI.uri(from: root)), "name": .string(root.lastPathComponent)]),
            ]),
            "capabilities": .object([
                "workspace": .object(["workspaceFolders": .bool(true), "configuration": .bool(true)]),
            ]),
        ]
        if let initOptions = LSPServerRegistry.go.initializationOptions {
            directInitParams["initializationOptions"] = initOptions
        }
        _ = try await directTransport.request(method: "initialize", params: .object(directInitParams), timeout: .seconds(15))
        try await directTransport.notify(method: "initialized", params: .object([:]))
        try await Task.sleep(for: .milliseconds(300))

        let directStderr = await directTransport.recentStderr()
        XCTAssertFalse(directStderr.lowercased().contains("flag provided but not defined"), "Unexpected direct stderr: \(directStderr)")
        XCTAssertFalse(directStderr.lowercased().contains("unexpected setting"), "Unexpected direct stderr: \(directStderr)")
        let errorMessages = notifications.snapshot().filter { entry in
            entry.type <= 2 || entry.message.localizedCaseInsensitiveContains("invalid settings") || entry.message.localizedCaseInsensitiveContains("unexpected setting")
        }
        XCTAssertTrue(errorMessages.isEmpty, "gopls reported settings warnings/errors: \(errorMessages)")
        await directTransport.shutdown()
    }

    // MARK: - 8. Mock LSP Server textDocument/references (Dedup, includeDeclaration, Null/Empty, Gating)

    func testMockStdioServerReferencesDedupIncludeDeclarationAndEmptyResponses() async throws {
        let dir = try makeTempDir(prefix: "dif-mock-refs")
        let scriptURL = dir.appendingPathComponent("mock_refs_lsp.py")
        let declURL = dir.appendingPathComponent("greet.go")
        let callerAURL = dir.appendingPathComponent("caller_a.go")
        let callerBURL = dir.appendingPathComponent("caller_b.go")
        try writeFile(declURL, contents: "package demo\nfunc Greet() {}\n")
        try writeFile(callerAURL, contents: "package demo\nfunc a() { Greet() }\n")
        try writeFile(callerBURL, contents: "package demo\nfunc b() { Greet() }\n")

        let declURI = LSPURI.uri(from: declURL)
        let callerAURI = LSPURI.uri(from: callerAURL)
        let callerBURI = LSPURI.uri(from: callerBURL)
        // Non-canonical duplicate URI with redundant `/./` segment to verify canonical deduplication
        let callerADupURI = "file://" + dir.path + "/./caller_a.go"

        let mockServerScript = """
        #!/usr/bin/env python3
        import json, sys

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

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}

            if method == "initialize":
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "definitionProvider": True,
                            "referencesProvider": True,
                        }
                    },
                })
            elif method == "textDocument/references":
                pos = params.get("position") or {}
                ctx = params.get("context") or {}
                line = pos.get("line", 0)
                include_decl = bool(ctx.get("includeDeclaration", False))
                if line == 99:
                    send({"jsonrpc": "2.0", "id": req_id, "result": None})
                elif line == 98:
                    send({"jsonrpc": "2.0", "id": req_id, "result": []})
                else:
                    locs = []
                    if include_decl:
                        locs.append({
                            "uri": "\(declURI)",
                            "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}},
                        })
                    # Include intentional exact and non-canonical duplicates to test dedup & stable ordering
                    locs.extend([
                        {
                            "uri": "\(callerBURI)",
                            "range": {"start": {"line": 1, "character": 11}, "end": {"line": 1, "character": 16}},
                        },
                        {
                            "uri": "\(callerAURI)",
                            "range": {"start": {"line": 1, "character": 11}, "end": {"line": 1, "character": 16}},
                        },
                        {
                            "uri": "\(callerADupURI)",
                            "range": {"start": {"line": 1, "character": 11}, "end": {"line": 1, "character": 16}},
                        },
                        {
                            "uri": "\(callerBURI)",
                            "range": {"start": {"line": 1, "character": 11}, "end": {"line": 1, "character": 16}},
                        },
                    ])
                    send({"jsonrpc": "2.0", "id": req_id, "result": locs})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockServerScript, executable: true)

        let mockResolved = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(
            isEnabled: true,
            serverOverrides: [LSPServerRegistry.go.id: mockResolved]
        )

        let session = await manager.didOpen(fileURL: declURL, text: "package demo\nfunc Greet() {}\n", repoRoot: dir)
        XCTAssertNotNil(session)

        // includeDeclaration: true -> declaration + deduped callers in stable order (decl, callerB, callerA)
        let withDecl = await manager.references(fileURL: declURL, line: 1, character: 6, includeDeclaration: true)
        XCTAssertEqual(withDecl.count, 3)
        XCTAssertEqual(withDecl.map(\.fileURL), [declURL, callerBURL, callerAURL])

        // includeDeclaration: false -> deduped callers only (callerB, callerA)
        let withoutDecl = await manager.references(fileURL: declURL, line: 1, character: 6, includeDeclaration: false)
        XCTAssertEqual(withoutDecl.count, 2)
        XCTAssertEqual(withoutDecl.map(\.fileURL), [callerBURL, callerAURL])

        // null and empty array responses -> []
        let nullRefs = await manager.references(fileURL: declURL, line: 99, character: 0)
        XCTAssertTrue(nullRefs.isEmpty)
        let emptyRefs = await manager.references(fileURL: declURL, line: 98, character: 0)
        XCTAssertTrue(emptyRefs.isEmpty)

        // Disabled manager gating -> []
        await manager.setEnabled(false)
        let gatedRefs = await manager.references(fileURL: declURL, line: 1, character: 6)
        XCTAssertTrue(gatedRefs.isEmpty)

        await manager.shutdownAll()
    }

    // MARK: - 9. LSPDocumentHighlight Decoding, Capabilities & Gating

    func testDocumentHighlightDecoderAndServerCapabilities() {
        XCTAssertTrue(LSPDocumentHighlightDecoder.decode(from: .null).isEmpty)

        let payload: JSONValue = .array([
            .object([
                "range": .object([
                    "start": .object(["line": .int(2), "character": .int(4)]),
                    "end": .object(["line": .int(2), "character": .int(9)]),
                ]),
                "kind": .int(3),
            ]),
            .object([
                "range": .object([
                    "start": .object(["line": .int(5), "character": .int(10)]),
                    "end": .object(["line": .int(5), "character": .int(15)]),
                ]),
            ]),
            .object(["invalid": .bool(true)]),
        ])
        let decoded = LSPDocumentHighlightDecoder.decode(from: payload)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].range, LSPRange(start: LSPPosition(line: 2, character: 4), end: LSPPosition(line: 2, character: 9)))
        XCTAssertEqual(decoded[0].kind, .write)
        XCTAssertNil(decoded[1].kind)

        let capTrue = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["documentHighlightProvider": .bool(true)]),
        ]))
        XCTAssertTrue(capTrue.documentHighlightProvider)

        let capObj = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["documentHighlightProvider": .object(["workDoneProgress": .bool(true)])]),
        ]))
        XCTAssertTrue(capObj.documentHighlightProvider)

        let capFalse = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["documentHighlightProvider": .bool(false)]),
        ]))
        XCTAssertFalse(capFalse.documentHighlightProvider)
        XCTAssertFalse(LSPServerCapabilities.empty.documentHighlightProvider)

        let implTrue = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["implementationProvider": .bool(true)]),
        ]))
        XCTAssertTrue(implTrue.implementationProvider)

        let implObj = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["implementationProvider": .object(["documentSelector": .array([])])]),
        ]))
        XCTAssertTrue(implObj.implementationProvider)

        let implFalse = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["implementationProvider": .bool(false)]),
        ]))
        XCTAssertFalse(implFalse.implementationProvider)
        XCTAssertFalse(LSPServerCapabilities.empty.implementationProvider)

        let typeTrue = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["typeDefinitionProvider": .bool(true)]),
        ]))
        XCTAssertTrue(typeTrue.typeDefinitionProvider)

        let typeObj = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["typeDefinitionProvider": .object(["documentSelector": .array([])])]),
        ]))
        XCTAssertTrue(typeObj.typeDefinitionProvider)

        let typeFalse = LSPServerCapabilities.parse(from: .object([
            "capabilities": .object(["typeDefinitionProvider": .bool(false)]),
        ]))
        XCTAssertFalse(typeFalse.typeDefinitionProvider)
        XCTAssertFalse(LSPServerCapabilities.empty.typeDefinitionProvider)
    }

    func testMockStdioServerDocumentHighlightReturnsRangesAndRespectsCapability() async throws {
        let dir = try makeTempDir(prefix: "dif-mock-highlight")
        let scriptURL = dir.appendingPathComponent("mock_hl_lsp.py")
        let fileURL = dir.appendingPathComponent("main.go")
        let source = "package demo\nfunc run() {\n\tcount := 1\n\t_ = count\n}\n"
        try writeFile(fileURL, contents: source)

        let mockServerScript = """
        #!/usr/bin/env python3
        import json, sys

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

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}
            if method == "initialize":
                caps = params.get("capabilities") or {}
                assert "documentHighlight" in (caps.get("textDocument") or {})
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "documentHighlightProvider": True,
                        }
                    },
                })
            elif method == "textDocument/documentHighlight":
                line = (params.get("position") or {}).get("line", 0)
                if line == 99:
                    send({"jsonrpc": "2.0", "id": req_id, "result": None})
                elif line == 97:
                    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": -32603, "message": "busy"}})
                else:
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [
                            {"range": {"start": {"line": 2, "character": 1}, "end": {"line": 2, "character": 6}}, "kind": 3},
                            {"range": {"start": {"line": 3, "character": 5}, "end": {"line": 3, "character": 10}}, "kind": 2},
                        ],
                    })
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockServerScript, executable: true)

        let mockResolved = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(
            isEnabled: true,
            serverOverrides: [LSPServerRegistry.go.id: mockResolved]
        )

        let session = await manager.didOpen(fileURL: fileURL, text: source, repoRoot: dir)
        XCTAssertNotNil(session)

        let highlights = await manager.documentHighlight(fileURL: fileURL, line: 2, character: 2)
        XCTAssertEqual(highlights.count, 2)
        XCTAssertEqual(highlights[0].kind, .write)
        XCTAssertEqual(highlights[0].range.start, LSPPosition(line: 2, character: 1))
        XCTAssertEqual(highlights[1].kind, .read)
        XCTAssertEqual(highlights[1].range.start, LSPPosition(line: 3, character: 5))

        let nullResult = await manager.documentHighlightResult(fileURL: fileURL, line: 99, character: 0)
        XCTAssertEqual(nullResult, .highlights([]))

        let errResult = await manager.documentHighlightResult(fileURL: fileURL, line: 97, character: 0)
        XCTAssertEqual(errResult, .failed)

        await manager.setEnabled(false)
        let disabledResult = await manager.documentHighlightResult(fileURL: fileURL, line: 2, character: 2)
        XCTAssertEqual(disabledResult, .unavailable)

        await manager.shutdownAll()
    }

    // MARK: - 10. textDocument/implementation (Mock Shapes, Capability, Error & Real gopls go.work)

    func testMockStdioServerImplementationShapesDedupCapabilityAndGating() async throws {
        let dir = try makeTempDir(prefix: "dif-mock-impl")
        let scriptURL = dir.appendingPathComponent("mock_impl_lsp.py")
        let ifaceURL = dir.appendingPathComponent("greeter.go")
        let implAURL = dir.appendingPathComponent("impl_a.go")
        let implBURL = dir.appendingPathComponent("impl_b.go")
        try writeFile(ifaceURL, contents: "package demo\ntype Greeter interface { Greet() }\n")
        try writeFile(implAURL, contents: "package demo\ntype ImplA struct{}\nfunc (ImplA) Greet() {}\n")
        try writeFile(implBURL, contents: "package demo\ntype ImplB struct{}\nfunc (ImplB) Greet() {}\n")

        let implAURI = LSPURI.uri(from: implAURL)
        let implBURI = LSPURI.uri(from: implBURL)
        let implADupURI = "file://" + dir.path + "/./impl_a.go"

        let mockServerScript = """
        #!/usr/bin/env python3
        import json, sys

        IMPL_CAP = sys.argv[1] == "1"

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
            return json.loads(body.decode("utf-8")) if body else None

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}
            if method == "initialize":
                td = (params.get("capabilities") or {}).get("textDocument") or {}
                impl_cap = td.get("implementation") or {}
                assert impl_cap.get("linkSupport") is True
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "implementationProvider": IMPL_CAP,
                        }
                    },
                })
            elif method == "textDocument/implementation":
                line = (params.get("position") or {}).get("line", 0)
                if line == 1:
                    # Single Location
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "uri": "\(implAURI)",
                            "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}},
                        },
                    })
                elif line == 2:
                    # [Location] with canonical duplicate
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [
                            {"uri": "\(implAURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}}},
                            {"uri": "\(implADupURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}}},
                            {"uri": "\(implBURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}}},
                        ],
                    })
                elif line == 3:
                    # [LocationLink]
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [{
                            "originSelectionRange": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 7}},
                            "targetUri": "\(implBURI)",
                            "targetRange": {"start": {"line": 2, "character": 0}, "end": {"line": 2, "character": 25}},
                            "targetSelectionRange": {"start": {"line": 2, "character": 13}, "end": {"line": 2, "character": 18}},
                        }],
                    })
                elif line == 4:
                    send({"jsonrpc": "2.0", "id": req_id, "result": None})
                elif line == 5:
                    send({"jsonrpc": "2.0", "id": req_id, "result": []})
                elif line == 6:
                    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": 0, "message": "not a method"}})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockServerScript, executable: true)

        let enabledServer = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path, "1"],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: enabledServer])
        let session = await manager.didOpen(fileURL: ifaceURL, text: "package demo\ntype Greeter interface { Greet() }\n", repoRoot: dir)
        XCTAssertNotNil(session)

        let single = await manager.implementation(fileURL: ifaceURL, line: 1, character: 6)
        XCTAssertEqual(single.map(\.fileURL), [implAURL])

        let multiple = await manager.implementation(fileURL: ifaceURL, line: 2, character: 6)
        XCTAssertEqual(multiple.count, 2)
        XCTAssertEqual(multiple.map(\.fileURL), [implAURL, implBURL])

        let link = await manager.implementation(fileURL: ifaceURL, line: 3, character: 6)
        XCTAssertEqual(link.map(\.fileURL), [implBURL])
        XCTAssertEqual(link.first?.range.start, LSPPosition(line: 2, character: 13))

        let nullImpls = await manager.implementation(fileURL: ifaceURL, line: 4, character: 0)
        XCTAssertTrue(nullImpls.isEmpty)
        let emptyImpls = await manager.implementation(fileURL: ifaceURL, line: 5, character: 0)
        XCTAssertTrue(emptyImpls.isEmpty)
        let errImpls = await manager.implementation(fileURL: ifaceURL, line: 6, character: 0)
        XCTAssertTrue(errImpls.isEmpty)

        await manager.setEnabled(false)
        let disabledImpls = await manager.implementation(fileURL: ifaceURL, line: 1, character: 6)
        XCTAssertTrue(disabledImpls.isEmpty)
        await manager.shutdownAll()

        // implementationProvider: false -> skips RPC and returns []
        let noProviderServer = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path, "0"],
            environment: ProcessInfo.processInfo.environment
        )
        let noProviderManager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: noProviderServer])
        _ = await noProviderManager.didOpen(fileURL: ifaceURL, text: "package demo\n", repoRoot: dir)
        let unsupported = await noProviderManager.implementation(fileURL: ifaceURL, line: 1, character: 6)
        XCTAssertTrue(unsupported.isEmpty)
        await noProviderManager.shutdownAll()
    }

    func testRealGoplsGoWorkInterfaceImplementations() async throws {
        guard LSPServerRegistry.resolveServer(for: LSPServerRegistry.go) != nil,
              LSPBinaryLocator.resolve(executable: "go") != nil else {
            throw XCTSkip("gopls or go toolchain not installed in PATH")
        }

        let root = try makeTempDir(prefix: "dif-real-gopls-impl")
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

        let greeterURL = repoB.appendingPathComponent("greeter.go")
        let greeterCode = """
        package repob

        type Greeter interface {
        \tGreet(name string) string
        }
        """
        try writeFile(greeterURL, contents: greeterCode)

        try writeFile(repoA.appendingPathComponent("go.mod"), contents: """
        module example.com/repoa

        go 1.21

        require example.com/repob v0.0.0
        """)

        let implURL = repoA.appendingPathComponent("impl.go")
        let implCode = """
        package main

        import "example.com/repob"

        type FormalGreeter struct{}

        func (FormalGreeter) Greet(name string) string {
        \treturn "Hello, " + name
        }

        type CasualGreeter struct{}

        func (CasualGreeter) Greet(name string) string {
        \treturn "Hi, " + name
        }

        func Run(g repob.Greeter) string {
        \treturn g.Greet("world")
        }
        """
        try writeFile(implURL, contents: implCode)

        let manager = LSPManager(isEnabled: true)
        _ = await manager.didOpen(fileURL: greeterURL, text: greeterCode, repoRoot: repoB)
        _ = await manager.didOpen(fileURL: implURL, text: implCode, repoRoot: repoA)

        // 1. Interface declaration `Greeter` -> FormalGreeter & CasualGreeter in repoA/impl.go
        var typeImpls: [LSPLocation] = []
        for _ in 0..<8 {
            typeImpls = await manager.implementation(fileURL: greeterURL, line: 2, character: 6, repoRoot: repoB)
            if typeImpls.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(typeImpls.contains { $0.fileURL == implURL && $0.range.start.line == 4 }, "Expected FormalGreeter, got: \(typeImpls)")
        XCTAssertTrue(typeImpls.contains { $0.fileURL == implURL && $0.range.start.line == 10 }, "Expected CasualGreeter, got: \(typeImpls)")

        // 2. Interface method `Greet` -> both concrete `Greet` methods
        let ifaceMethodImpls = await manager.implementation(fileURL: greeterURL, line: 3, character: 2, repoRoot: repoB)
        XCTAssertTrue(ifaceMethodImpls.contains { $0.fileURL == implURL && $0.range.start.line == 6 }, "Expected FormalGreeter.Greet, got: \(ifaceMethodImpls)")
        XCTAssertTrue(ifaceMethodImpls.contains { $0.fileURL == implURL && $0.range.start.line == 12 }, "Expected CasualGreeter.Greet, got: \(ifaceMethodImpls)")

        // 3. Interface method call `g.Greet("world")` -> both concrete `Greet` methods
        let callImpls = await manager.implementation(fileURL: implURL, line: 17, character: 11, repoRoot: repoA)
        XCTAssertTrue(callImpls.contains { $0.fileURL == implURL && $0.range.start.line == 6 }, "Expected FormalGreeter.Greet from call site, got: \(callImpls)")
        XCTAssertTrue(callImpls.contains { $0.fileURL == implURL && $0.range.start.line == 12 }, "Expected CasualGreeter.Greet from call site, got: \(callImpls)")

        // 4. Concrete struct & method -> interface & interface method in repoB/greeter.go
        let structIfaces = await manager.implementation(fileURL: implURL, line: 4, character: 6, repoRoot: repoA)
        XCTAssertTrue(structIfaces.contains { $0.fileURL == greeterURL && $0.range.start.line == 2 }, "Expected Greeter interface, got: \(structIfaces)")

        let methodIfaces = await manager.implementation(fileURL: implURL, line: 6, character: 22, repoRoot: repoA)
        XCTAssertTrue(methodIfaces.contains { $0.fileURL == greeterURL && $0.range.start.line == 3 }, "Expected Greeter.Greet, got: \(methodIfaces)")

        // 5. Plain function `Run` -> returns [] cleanly instead of propagating RPC error
        let plainFuncImpls = await manager.implementation(fileURL: implURL, line: 16, character: 6, repoRoot: repoA)
        XCTAssertTrue(plainFuncImpls.isEmpty)

        await manager.shutdownAll()
    }

    // MARK: - 11. textDocument/typeDefinition (Mock Shapes, Capability, Error & Real gopls go.work)

    func testMockStdioServerTypeDefinitionShapesDedupCapabilityAndGating() async throws {
        let dir = try makeTempDir(prefix: "dif-mock-typedef")
        let scriptURL = dir.appendingPathComponent("mock_typedef_lsp.py")
        let mainURL = dir.appendingPathComponent("main.go")
        let userURL = dir.appendingPathComponent("user.go")
        let adminURL = dir.appendingPathComponent("admin.go")
        try writeFile(mainURL, contents: "package demo\nfunc run() {}\n")
        try writeFile(userURL, contents: "package demo\ntype User struct{}\n")
        try writeFile(adminURL, contents: "package demo\ntype Admin struct{}\n")

        let userURI = LSPURI.uri(from: userURL)
        let adminURI = LSPURI.uri(from: adminURL)
        let userDupURI = "file://" + dir.path + "/./user.go"

        let mockServerScript = """
        #!/usr/bin/env python3
        import json, sys

        TYPEDEF_CAP = sys.argv[1] == "1"

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
            return json.loads(body.decode("utf-8")) if body else None

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            params = msg.get("params") or {}
            if method == "initialize":
                td = (params.get("capabilities") or {}).get("textDocument") or {}
                typedef_cap = td.get("typeDefinition") or {}
                assert typedef_cap.get("linkSupport") is True
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "capabilities": {
                            "textDocumentSync": 1,
                            "typeDefinitionProvider": TYPEDEF_CAP,
                        }
                    },
                })
            elif method == "textDocument/typeDefinition":
                line = (params.get("position") or {}).get("line", 0)
                if line == 1:
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "uri": "\(userURI)",
                            "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 9}},
                        },
                    })
                elif line == 2:
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [
                            {"uri": "\(userURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 9}}},
                            {"uri": "\(userDupURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 9}}},
                            {"uri": "\(adminURI)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}}},
                        ],
                    })
                elif line == 3:
                    send({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": [{
                            "originSelectionRange": {"start": {"line": 3, "character": 0}, "end": {"line": 3, "character": 4}},
                            "targetUri": "\(adminURI)",
                            "targetRange": {"start": {"line": 1, "character": 0}, "end": {"line": 1, "character": 19}},
                            "targetSelectionRange": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}},
                        }],
                    })
                elif line == 4:
                    send({"jsonrpc": "2.0", "id": req_id, "result": None})
                elif line == 5:
                    send({"jsonrpc": "2.0", "id": req_id, "result": []})
                elif line == 6:
                    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": 0, "message": "no type definition for n"}})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockServerScript, executable: true)

        let enabledServer = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path, "1"],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: enabledServer])
        let session = await manager.didOpen(fileURL: mainURL, text: "package demo\nfunc run() {}\n", repoRoot: dir)
        XCTAssertNotNil(session)

        let single = await manager.typeDefinition(fileURL: mainURL, line: 1, character: 5)
        XCTAssertEqual(single.map(\.fileURL), [userURL])

        let multiple = await manager.typeDefinition(fileURL: mainURL, line: 2, character: 5)
        XCTAssertEqual(multiple.count, 2)
        XCTAssertEqual(multiple.map(\.fileURL), [userURL, adminURL])

        let link = await manager.typeDefinition(fileURL: mainURL, line: 3, character: 5)
        XCTAssertEqual(link.map(\.fileURL), [adminURL])
        XCTAssertEqual(link.first?.range.start, LSPPosition(line: 1, character: 5))

        let nullTargets = await manager.typeDefinition(fileURL: mainURL, line: 4, character: 0)
        XCTAssertTrue(nullTargets.isEmpty)
        let emptyTargets = await manager.typeDefinition(fileURL: mainURL, line: 5, character: 0)
        XCTAssertTrue(emptyTargets.isEmpty)
        let errTargets = await manager.typeDefinition(fileURL: mainURL, line: 6, character: 0)
        XCTAssertTrue(errTargets.isEmpty)

        await manager.setEnabled(false)
        let disabledTargets = await manager.typeDefinition(fileURL: mainURL, line: 1, character: 5)
        XCTAssertTrue(disabledTargets.isEmpty)
        await manager.shutdownAll()

        let noProviderServer = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path, "0"],
            environment: ProcessInfo.processInfo.environment
        )
        let noProviderManager = LSPManager(isEnabled: true, serverOverrides: [LSPServerRegistry.go.id: noProviderServer])
        _ = await noProviderManager.didOpen(fileURL: mainURL, text: "package demo\n", repoRoot: dir)
        let unsupported = await noProviderManager.typeDefinition(fileURL: mainURL, line: 1, character: 5)
        XCTAssertTrue(unsupported.isEmpty)
        await noProviderManager.shutdownAll()
    }

    func testRealGoplsGoWorkTypeDefinition() async throws {
        guard LSPServerRegistry.resolveServer(for: LSPServerRegistry.go) != nil,
              LSPBinaryLocator.resolve(executable: "go") != nil else {
            throw XCTSkip("gopls or go toolchain not installed in PATH")
        }

        let root = try makeTempDir(prefix: "dif-real-gopls-typedef")
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

        let userURL = repoB.appendingPathComponent("user.go")
        let userCode = """
        package repob

        type User struct {
        \tName string
        }
        """
        try writeFile(userURL, contents: userCode)

        try writeFile(repoA.appendingPathComponent("go.mod"), contents: """
        module example.com/repoa

        go 1.21

        require example.com/repob v0.0.0
        """)

        let appURL = repoA.appendingPathComponent("app.go")
        let appCode = """
        package main

        import "example.com/repob"

        func Demo(u *repob.User) {
        \tv := repob.User{Name: "alice"}
        \t_ = v.Name
        \t_ = u.Name
        \tn := 42
        \t_ = n
        }
        """
        try writeFile(appURL, contents: appCode)

        let manager = LSPManager(isEnabled: true)
        _ = await manager.didOpen(fileURL: userURL, text: userCode, repoRoot: repoB)
        _ = await manager.didOpen(fileURL: appURL, text: appCode, repoRoot: repoA)

        // 1. Parameter pointer `u` (*repob.User) -> repoB/user.go:User
        var paramTargets: [LSPLocation] = []
        for _ in 0..<8 {
            paramTargets = await manager.typeDefinition(fileURL: appURL, line: 4, character: 10, repoRoot: repoA)
            if !paramTargets.isEmpty { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTAssertTrue(paramTargets.contains { $0.fileURL == userURL && $0.range.start.line == 2 }, "Expected User struct for param u, got: \(paramTargets)")

        // 2. Local variable `v` (repob.User) -> repoB/user.go:User
        let localTargets = await manager.typeDefinition(fileURL: appURL, line: 6, character: 5, repoRoot: repoA)
        XCTAssertTrue(localTargets.contains { $0.fileURL == userURL && $0.range.start.line == 2 }, "Expected User struct for local var v, got: \(localTargets)")

        // 3. Builtin int variable `n` -> returns [] cleanly instead of propagating RPC error
        let builtinTargets = await manager.typeDefinition(fileURL: appURL, line: 9, character: 5, repoRoot: repoA)
        XCTAssertTrue(builtinTargets.isEmpty)

        await manager.shutdownAll()
    }

    func testIdleReaperKeepsPinnedDocumentsWarmRespectsDynamicTimeoutAndReapsEphemeral() async throws {
        let dir = try makeTempDir(prefix: "dif-idle-pin")
        let scriptURL = dir.appendingPathComponent("mock_idle_lsp.py")
        let fileURL = dir.appendingPathComponent("main.go")
        let source = "package main\nfunc Greet() {}\nfunc main() { Greet() }\n"
        try writeFile(fileURL, contents: source)
        let uri = LSPURI.uri(from: fileURL)

        let mockScript = """
        #!/usr/bin/env python3
        import json, sys

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
            return json.loads(body.decode("utf-8")) if body else None

        while True:
            msg = read_msg()
            if msg is None:
                break
            method = msg.get("method")
            req_id = msg.get("id")
            if method == "initialize":
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"capabilities": {"textDocumentSync": 1, "definitionProvider": True}},
                })
            elif method == "textDocument/definition":
                send({
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": [{"uri": "\(uri)", "range": {"start": {"line": 1, "character": 5}, "end": {"line": 1, "character": 10}}}],
                })
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": req_id, "result": None})
            elif method == "exit":
                break
        """
        try writeFile(scriptURL, contents: mockScript, executable: true)

        let mockResolved = LSPResolvedServer(
            descriptor: LSPServerRegistry.go,
            executablePath: "/usr/bin/python3",
            arguments: [scriptURL.path],
            environment: ProcessInfo.processInfo.environment
        )
        let manager = LSPManager(
            isEnabled: true,
            idleTimeout: .milliseconds(200),
            serverOverrides: [LSPServerRegistry.go.id: mockResolved]
        )

        // 1. Pinned live document stays warm past idleTimeout
        let session = await manager.didOpen(fileURL: fileURL, text: source, repoRoot: dir)
        XCTAssertEqual(session?.isPinned, true)
        try await Task.sleep(for: .milliseconds(350))
        let countWhilePinned = await manager.runningServerCount()
        XCTAssertEqual(countWhilePinned, 1)

        // 2. Closing (switching away) unpins and allows idle reaper to shut down
        await manager.didClose(fileURL: fileURL)
        try await Task.sleep(for: .milliseconds(350))
        let countAfterClose = await manager.runningServerCount()
        XCTAssertEqual(countAfterClose, 0)

        // 3. setIdleTimeout(nil) ("Never") prevents reaping even after didClose
        _ = await manager.didOpen(fileURL: fileURL, text: source, repoRoot: dir)
        await manager.setIdleTimeout(nil)
        await manager.didClose(fileURL: fileURL)
        try await Task.sleep(for: .milliseconds(350))
        let countWithNever = await manager.runningServerCount()
        XCTAssertEqual(countWithNever, 1)

        // 4. Reducing timeout dynamically reaps already-idle unpinned server immediately
        await manager.setIdleTimeout(.milliseconds(150))
        let countAfterTighten = await manager.runningServerCount()
        XCTAssertEqual(countAfterTighten, 0)

        // 5. Ephemeral one-shot query (e.g. historical commit diff) opens unpinned and still gets reaped
        let defs = await manager.definition(fileURL: fileURL, line: 2, character: 15, repoRoot: dir)
        XCTAssertEqual(defs.count, 1)
        let ephemeralSession = await manager.openSession(forURI: uri)
        XCTAssertEqual(ephemeralSession?.isPinned, false)
        try await Task.sleep(for: .milliseconds(350))
        let countAfterEphemeral = await manager.runningServerCount()
        XCTAssertEqual(countAfterEphemeral, 0)

        await manager.shutdownAll()
    }
}
