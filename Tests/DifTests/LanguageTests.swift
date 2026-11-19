import XCTest
@testable import DifKit

/// The interface language picked in Settings, kept in the app's own `AppleLanguages`. The tests write to a
/// defaults domain of their own, emptied before and after each one, never to the test runner's. One fixed name,
/// so runs do not leave a file each in ~/Library/Preferences.
final class LanguageTests: XCTestCase {
    private let suite = "DifTests.language"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var saved: [String]? {
        defaults.persistentDomain(forName: suite)?[Settings.Language.key] as? [String]
    }

    func testEachChoiceIsSavedWhereMacOSKeepsAnAppsLanguage() {
        XCTAssertEqual(Settings.Language.stored(in: defaults, domain: suite), .system)

        Settings.Language.chinese.store(in: defaults)
        XCTAssertEqual(saved, ["zh-Hans"])
        XCTAssertEqual(Settings.Language.stored(in: defaults, domain: suite), .chinese)

        Settings.Language.english.store(in: defaults)
        XCTAssertEqual(saved, ["en"])
        XCTAssertEqual(Settings.Language.stored(in: defaults, domain: suite), .english)

        // Following the system leaves nothing of the app's own behind.
        Settings.Language.system.store(in: defaults)
        XCTAssertNil(saved)
        XCTAssertEqual(Settings.Language.stored(in: defaults, domain: suite), .system)
    }

    func testTheSystemsOwnListIsNotTakenForAChoice() {
        // A suite falls back to the system's languages, as the app's own domain does.
        XCTAssertNotNil(defaults.object(forKey: Settings.Language.key), "this Mac has no system language list to fall back to")
        XCTAssertEqual(Settings.Language.stored(in: defaults, domain: suite), .system)
    }

    func testWhatEachChoiceShows() {
        XCTAssertTrue(Settings.Language.system.isChinese(system: ["zh-Hans-CN", "en"]))
        XCTAssertFalse(Settings.Language.system.isChinese(system: ["en-US", "zh-Hans-US"]))
        XCTAssertFalse(Settings.Language.system.isChinese(system: []))
        XCTAssertTrue(Settings.Language.chinese.isChinese(system: ["en-US"]))
        XCTAssertFalse(Settings.Language.english.isChinese(system: ["zh-Hans"]))
    }

    func testALanguageSetElsewhereReadsAsWhatItShows() {
        // System Settings ▸ Language & Region ▸ Applications writes the same key, with region or script added.
        XCTAssertEqual(Settings.Language(appleLanguages: ["zh-Hans-CN"]), .chinese)
        XCTAssertEqual(Settings.Language(appleLanguages: ["zh-Hant-TW"]), .chinese)
        XCTAssertEqual(Settings.Language(appleLanguages: ["en-GB", "zh-Hans"]), .english)
        // DiffCode shows English for any other language.
        XCTAssertEqual(Settings.Language(appleLanguages: ["ja-JP"]), .english)
        XCTAssertEqual(Settings.Language(appleLanguages: []), .system)
        XCTAssertEqual(Settings.Language(appleLanguages: nil), .system)
    }

    func testTheNamesOfTheLanguagesStayInTheirOwnLanguage() {
        XCTAssertEqual(Settings.Language.english.title, "English")
        XCTAssertEqual(Settings.Language.chinese.title, "简体中文")
        XCTAssertEqual(Settings.Language.allCases, [.system, .english, .chinese])
    }
}

final class GoLandSyntaxTests: XCTestCase {
    func testTokenKindRawValuesMatchSpec() {
        let expected: [(TokenKind, UInt8)] = [
            (.plain, 0), (.keyword, 1), (.string, 2), (.comment, 3), (.number, 4),
            (.annotation, 5), (.function, 6), (.constant, 7), (.tag, 8), (.attribute, 9),
            (.type, 10), (.interface, 11), (.method, 12), (.builtin, 13), (.namespace, 14),
            (.property, 15), (.parameter, 16), (.variable, 17), (.typeParameter, 18), (.operator, 19),
            (.exportedFunction, 20), (.exportedConstant, 21), (.exportedVariable, 22),
            (.builtinType, 23), (.exportedType, 24), (.exportedProperty, 25),
        ]
        XCTAssertEqual(TokenKind.allCases.count, expected.count)
        for (index, pair) in expected.enumerated() {
            XCTAssertEqual(TokenKind.allCases[index], pair.0)
            XCTAssertEqual(pair.0.rawValue, pair.1)
        }
    }

    func testAllTokenKindsHaveThemeStylesInDarkAndLight() {
        for theme in [CanvasTheme.dark, CanvasTheme.light] {
            XCTAssertEqual(theme.syntax.count, TokenKind.allCases.count)
            XCTAssertEqual(theme.goSyntax.count, TokenKind.allCases.count)
            for kind in TokenKind.allCases {
                _ = theme.style(for: kind, language: nil)
                _ = theme.style(for: kind, language: .go)
            }

            // GoLand traits required in both Dark & Light themes:
            // - Exported functions/methods: blue & BOLD
            let expFunc = theme.style(for: .exportedFunction, language: .go)
            XCTAssertTrue(expFunc.bold)
            XCTAssertFalse(expFunc.italic)
            if let comps = expFunc.color.components, comps.count >= 3 {
                XCTAssertGreaterThan(comps[2], comps[0], "exportedFunction should be blue-dominant")
            }

            // - Unexported functions/methods & builtin funcs: ITALIC
            XCTAssertTrue(theme.style(for: .function, language: .go).italic)
            XCTAssertFalse(theme.style(for: .function, language: .go).bold)
            XCTAssertTrue(theme.style(for: .method, language: .go).italic)
            XCTAssertTrue(theme.style(for: .builtin, language: .go).italic)

            // - Function parameters & receivers: ITALIC
            XCTAssertTrue(theme.style(for: .parameter, language: .go).italic)
            XCTAssertFalse(theme.style(for: .parameter, language: .go).bold)

            // - Exported constants (decl & ref): BOLD; unexported/predeclared constants (nil/true/false): ITALIC
            XCTAssertTrue(theme.style(for: .exportedConstant, language: .go).bold)
            XCTAssertFalse(theme.style(for: .exportedConstant, language: .go).italic)
            XCTAssertTrue(theme.style(for: .constant, language: .go).italic)
            XCTAssertFalse(theme.style(for: .constant, language: .go).bold)

            // - Builtin types (int64, bool, string): magenta & BOLD
            let builtinType = theme.style(for: .builtinType, language: .go)
            XCTAssertTrue(builtinType.bold)
            XCTAssertFalse(builtinType.italic)
            if let comps = builtinType.color.components, comps.count >= 3 {
                XCTAssertGreaterThan(comps[0], comps[1], "builtinType should be magenta (red > green)")
                XCTAssertGreaterThan(comps[2], comps[1], "builtinType should be magenta (blue > green)")
            }

            // - Exported package vars: purple/indigo & BOLD
            XCTAssertTrue(theme.style(for: .exportedVariable, language: .go).bold)
            XCTAssertFalse(theme.style(for: .exportedVariable, language: .go).italic)

            // - Keywords, comments, unexported types & fields: ITALIC
            XCTAssertTrue(theme.style(for: .keyword, language: .go).italic)
            XCTAssertTrue(theme.style(for: .comment, language: .go).italic)
            XCTAssertTrue(theme.style(for: .type, language: .go).italic)
            XCTAssertTrue(theme.style(for: .property, language: .go).italic)

            // - Exported types & exported fields: upright regular
            XCTAssertFalse(theme.style(for: .exportedType, language: .go).italic)
            XCTAssertFalse(theme.style(for: .exportedType, language: .go).bold)
            XCTAssertFalse(theme.style(for: .exportedProperty, language: .go).italic)
            XCTAssertFalse(theme.style(for: .exportedProperty, language: .go).bold)
        }
    }

    private func kind(of token: String, in line: String, spans: [SyntaxSpan]) -> TokenKind? {
        let ns = line as NSString
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let r = ns.range(of: token, options: [], range: search)
            guard r.location != NSNotFound else { return nil }
            if let match = spans.first(where: { Int($0.start) == r.location && Int($0.length) == r.length }) {
                return match.kind
            }
            let nextLoc = r.location + 1
            search = NSRange(location: nextLoc, length: ns.length - nextLoc)
        }
        return nil
    }

    func testGoDeclarationsAndBuiltins() {
        let lines = [
            "package main // entry",
            "import httpAlias \"net/http\"",
            "type Reader interface {",
            "type Server[T any] struct {",
            "    Name string `json:\"name,omitempty\"`",
            "}",
            "func Handle(n int) (string, error) {",
            "func (s *Server) Start(x int) bool {",
            "func Map[T comparable](xs []T) []T {",
            "func (m *nexusBattleManager) DeleteSignup(lid int64, corps datastruct.EventNexusBattleCorps) {",
            "func (m *nexusBattleManager) MatchReadyRooms(now time.Time, isFinalMatch bool) ([]*nexusBattleRoom, error) {",
        ]
        let allSpans = Highlighter.highlight(lines, language: .detect(path: "server.go"))

        XCTAssertEqual(kind(of: "package", in: lines[0], spans: allSpans[0]), .keyword)
        XCTAssertEqual(kind(of: "main", in: lines[0], spans: allSpans[0]), .namespace)
        XCTAssertEqual(kind(of: "// entry", in: lines[0], spans: allSpans[0]), .comment)

        XCTAssertEqual(kind(of: "import", in: lines[1], spans: allSpans[1]), .keyword)
        XCTAssertEqual(kind(of: "httpAlias", in: lines[1], spans: allSpans[1]), .namespace)
        XCTAssertEqual(kind(of: "\"net/http\"", in: lines[1], spans: allSpans[1]), .string)

        XCTAssertEqual(kind(of: "type", in: lines[2], spans: allSpans[2]), .keyword)
        XCTAssertEqual(kind(of: "Reader", in: lines[2], spans: allSpans[2]), .interface)
        XCTAssertEqual(kind(of: "interface", in: lines[2], spans: allSpans[2]), .keyword)

        XCTAssertEqual(kind(of: "Server", in: lines[3], spans: allSpans[3]), .exportedType)
        XCTAssertEqual(kind(of: "any", in: lines[3], spans: allSpans[3]), .builtinType)
        XCTAssertEqual(kind(of: "struct", in: lines[3], spans: allSpans[3]), .keyword)

        XCTAssertEqual(kind(of: "string", in: lines[4], spans: allSpans[4]), .builtinType)
        XCTAssertEqual(kind(of: "`json:\"name,omitempty\"`", in: lines[4], spans: allSpans[4]), .annotation)

        XCTAssertEqual(kind(of: "Handle", in: lines[6], spans: allSpans[6]), .exportedFunction)
        XCTAssertEqual(kind(of: "n", in: lines[6], spans: allSpans[6]), .parameter)
        XCTAssertEqual(kind(of: "int", in: lines[6], spans: allSpans[6]), .builtinType)
        XCTAssertEqual(kind(of: "string", in: lines[6], spans: allSpans[6]), .builtinType)
        XCTAssertEqual(kind(of: "error", in: lines[6], spans: allSpans[6]), .builtinType)

        XCTAssertEqual(kind(of: "s", in: lines[7], spans: allSpans[7]), .parameter)
        XCTAssertEqual(kind(of: "Server", in: lines[7], spans: allSpans[7]), .exportedType)
        XCTAssertEqual(kind(of: "Start", in: lines[7], spans: allSpans[7]), .exportedFunction)
        XCTAssertEqual(kind(of: "x", in: lines[7], spans: allSpans[7]), .parameter)
        XCTAssertEqual(kind(of: "bool", in: lines[7], spans: allSpans[7]), .builtinType)

        XCTAssertEqual(kind(of: "Map", in: lines[8], spans: allSpans[8]), .exportedFunction)
        XCTAssertEqual(kind(of: "comparable", in: lines[8], spans: allSpans[8]), .builtinType)
        XCTAssertEqual(kind(of: "xs", in: lines[8], spans: allSpans[8]), .parameter)

        // GoLand reference screenshot signatures:
        XCTAssertEqual(kind(of: "m", in: lines[9], spans: allSpans[9]), .parameter)
        XCTAssertEqual(kind(of: "nexusBattleManager", in: lines[9], spans: allSpans[9]), .type)
        XCTAssertEqual(kind(of: "DeleteSignup", in: lines[9], spans: allSpans[9]), .exportedFunction)
        XCTAssertEqual(kind(of: "lid", in: lines[9], spans: allSpans[9]), .parameter)
        XCTAssertEqual(kind(of: "int64", in: lines[9], spans: allSpans[9]), .builtinType)
        XCTAssertEqual(kind(of: "corps", in: lines[9], spans: allSpans[9]), .parameter)
        XCTAssertEqual(kind(of: "datastruct", in: lines[9], spans: allSpans[9]), .namespace)
        XCTAssertEqual(kind(of: "EventNexusBattleCorps", in: lines[9], spans: allSpans[9]), .exportedType)

        XCTAssertEqual(kind(of: "MatchReadyRooms", in: lines[10], spans: allSpans[10]), .exportedFunction)
        XCTAssertEqual(kind(of: "now", in: lines[10], spans: allSpans[10]), .parameter)
        XCTAssertEqual(kind(of: "time", in: lines[10], spans: allSpans[10]), .namespace)
        XCTAssertEqual(kind(of: "Time", in: lines[10], spans: allSpans[10]), .exportedType)
        XCTAssertEqual(kind(of: "isFinalMatch", in: lines[10], spans: allSpans[10]), .parameter)
        XCTAssertEqual(kind(of: "bool", in: lines[10], spans: allSpans[10]), .builtinType)
        XCTAssertEqual(kind(of: "nexusBattleRoom", in: lines[10], spans: allSpans[10]), .type)
    }

    func testGoCallsConstantsAndRawStrings() {
        let lines = [
            "xs := make([]int, 0, len(items))",
            "ok := helper(true, false, nil, iota)",
            "srv.Stop()",
            "raw := `a\\` + `multi",
            "line`",
            "const ExportedConst = 1",
            "const (",
            "    ExportedBlockConst = 1",
            "    unexportedBlockConst = 2",
            ")",
            "pkt := message.StructToPacket(message.S_CLEAR_CHANNEL_CHAT{",
            "    Channel: datastruct.GetBattleRoomChatChannel(roomID, lid),",
            "}, message.MSG_GS_SNS_CLEAR_CHANNEL_CHAT)",
            "key := m.signupKey(lid, corps)",
            "m.lock.Lock()",
            "delete(m.state.Signups, key)",
            "grouped := make(map[string][]*nexusBattleSignupProfile)",
        ]
        let allSpans = Highlighter.highlight(lines, language: .go)

        XCTAssertEqual(kind(of: "make", in: lines[0], spans: allSpans[0]), .builtin)
        XCTAssertEqual(kind(of: "int", in: lines[0], spans: allSpans[0]), .builtinType)
        XCTAssertEqual(kind(of: "0", in: lines[0], spans: allSpans[0]), .number)
        XCTAssertEqual(kind(of: "len", in: lines[0], spans: allSpans[0]), .builtin)

        XCTAssertEqual(kind(of: "helper", in: lines[1], spans: allSpans[1]), .function)
        XCTAssertEqual(kind(of: "true", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "false", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "nil", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "iota", in: lines[1], spans: allSpans[1]), .constant)

        XCTAssertEqual(kind(of: "Stop", in: lines[2], spans: allSpans[2]), .exportedFunction)

        XCTAssertEqual(kind(of: "`a\\`", in: lines[3], spans: allSpans[3]), .string)
        XCTAssertEqual(kind(of: "`multi", in: lines[3], spans: allSpans[3]), .string)
        XCTAssertEqual(kind(of: "line`", in: lines[4], spans: allSpans[4]), .string)

        XCTAssertEqual(kind(of: "ExportedConst", in: lines[5], spans: allSpans[5]), .exportedConstant)
        XCTAssertEqual(kind(of: "ExportedBlockConst", in: lines[7], spans: allSpans[7]), .exportedConstant)
        XCTAssertEqual(kind(of: "unexportedBlockConst", in: lines[8], spans: allSpans[8]), .constant)

        XCTAssertEqual(kind(of: "StructToPacket", in: lines[10], spans: allSpans[10]), .exportedFunction)
        XCTAssertEqual(kind(of: "S_CLEAR_CHANNEL_CHAT", in: lines[10], spans: allSpans[10]), .exportedType)
        XCTAssertEqual(kind(of: "Channel", in: lines[11], spans: allSpans[11]), .exportedProperty)
        XCTAssertEqual(kind(of: "GetBattleRoomChatChannel", in: lines[11], spans: allSpans[11]), .exportedFunction)
        XCTAssertEqual(kind(of: "MSG_GS_SNS_CLEAR_CHANNEL_CHAT", in: lines[12], spans: allSpans[12]), .exportedConstant)

        XCTAssertEqual(kind(of: "signupKey", in: lines[13], spans: allSpans[13]), .method)
        XCTAssertEqual(kind(of: "lock", in: lines[14], spans: allSpans[14]), .property)
        XCTAssertEqual(kind(of: "Lock", in: lines[14], spans: allSpans[14]), .exportedFunction)
        XCTAssertEqual(kind(of: "delete", in: lines[15], spans: allSpans[15]), .builtin)
        XCTAssertEqual(kind(of: "state", in: lines[15], spans: allSpans[15]), .property)
        XCTAssertEqual(kind(of: "Signups", in: lines[15], spans: allSpans[15]), .exportedProperty)

        XCTAssertEqual(kind(of: "make", in: lines[16], spans: allSpans[16]), .builtin)
        XCTAssertEqual(kind(of: "string", in: lines[16], spans: allSpans[16]), .builtinType)
        XCTAssertEqual(kind(of: "nexusBattleSignupProfile", in: lines[16], spans: allSpans[16]), .type)
    }

    func testSyntaxOverlayRefinesGoplsTokensUsingLineTextAndModifiers() {
        // 1. Exported method decl, receiver preserved as .parameter, unexported type, param, builtinType, namespace, interface
        let sigLine = "func (m *nexusBattleManager) DeleteSignup(lid int64, corps datastruct.EventNexusBattleCorps) {"
        let sigBase = Highlighter.highlight([sigLine], language: .go)[0]
        func span(_ tok: String, in line: String, kind: LSPSemanticTokenKind, mods: LSPSemanticTokenModifiers = []) -> LSPSemanticSpan {
            let r = (line as NSString).range(of: tok)
            return LSPSemanticSpan(start: Int32(r.location), length: Int32(r.length), kind: kind, modifiers: mods)
        }
        let sigSemantic = [
            span("func", in: sigLine, kind: .keyword),
            span("m", in: sigLine, kind: .variable, mods: [.definition, .pointer]),
            span("nexusBattleManager", in: sigLine, kind: .type, mods: [.struct]),
            span("DeleteSignup", in: sigLine, kind: .method, mods: [.definition]),
            span("lid", in: sigLine, kind: .parameter, mods: [.definition]),
            span("int64", in: sigLine, kind: .builtin, mods: [.defaultLibrary]),
            span("corps", in: sigLine, kind: .parameter, mods: [.definition]),
            span("datastruct", in: sigLine, kind: .namespace),
            span("EventNexusBattleCorps", in: sigLine, kind: .type, mods: [.interface]),
        ]
        let sigMerged = SyntaxOverlay.merge(base: sigBase, semantic: sigSemantic, lineText: sigLine)
        XCTAssertEqual(kind(of: "m", in: sigLine, spans: sigMerged), .parameter)
        XCTAssertEqual(kind(of: "nexusBattleManager", in: sigLine, spans: sigMerged), .type)
        XCTAssertEqual(kind(of: "DeleteSignup", in: sigLine, spans: sigMerged), .exportedFunction)
        XCTAssertEqual(kind(of: "lid", in: sigLine, spans: sigMerged), .parameter)
        XCTAssertEqual(kind(of: "int64", in: sigLine, spans: sigMerged), .builtinType)
        XCTAssertEqual(kind(of: "corps", in: sigLine, spans: sigMerged), .parameter)
        XCTAssertEqual(kind(of: "datastruct", in: sigLine, spans: sigMerged), .namespace)
        XCTAssertEqual(kind(of: "EventNexusBattleCorps", in: sigLine, spans: sigMerged), .interface)

        // 2. Exported const (both CamelCase and SCREAMING_SNAKE via variable+readonly), unexported const, and predeclared nil
        let constLine = "x := message.MaxRetries + localConst + nil"
        let constSemantic = [
            span("x", in: constLine, kind: .variable, mods: [.definition]),
            span("message", in: constLine, kind: .namespace),
            span("MaxRetries", in: constLine, kind: .constant, mods: [.readonly]),
            span("localConst", in: constLine, kind: .constant, mods: [.readonly]),
            span("nil", in: constLine, kind: .builtin, mods: [.readonly, .defaultLibrary]),
        ]
        let constMerged = SyntaxOverlay.merge(base: [], semantic: constSemantic, lineText: constLine)
        XCTAssertEqual(kind(of: "MaxRetries", in: constLine, spans: constMerged), .exportedConstant)
        XCTAssertEqual(kind(of: "localConst", in: constLine, spans: constMerged), .constant)
        XCTAssertEqual(kind(of: "nil", in: constLine, spans: constMerged), .constant)

        // 3. Exported pkg vars (SNSAgent, CFG), struct fields (CFG.ServerId, m.lock, m.state.Signups),
        //    unexported method (signupKey), builtin func (delete)
        let callLine = "pkt.WriteS2SPacketPayload(CFG.ServerId, SNSAgent, m.lock, m.signupKey(lid))"
        let callSemantic = [
            span("pkt", in: callLine, kind: .variable),
            span("WriteS2SPacketPayload", in: callLine, kind: .method),
            span("CFG", in: callLine, kind: .variable),
            span("ServerId", in: callLine, kind: .variable),
            span("SNSAgent", in: callLine, kind: .variable),
            span("m", in: callLine, kind: .variable),
            span("lock", in: callLine, kind: .variable),
            span("signupKey", in: callLine, kind: .method),
            span("lid", in: callLine, kind: .parameter),
        ]
        let callMerged = SyntaxOverlay.merge(base: [], semantic: callSemantic, lineText: callLine)
        XCTAssertEqual(kind(of: "WriteS2SPacketPayload", in: callLine, spans: callMerged), .exportedFunction)
        XCTAssertEqual(kind(of: "CFG", in: callLine, spans: callMerged), .exportedVariable)
        XCTAssertEqual(kind(of: "ServerId", in: callLine, spans: callMerged), .exportedProperty)
        XCTAssertEqual(kind(of: "SNSAgent", in: callLine, spans: callMerged), .exportedVariable)
        XCTAssertEqual(kind(of: "lock", in: callLine, spans: callMerged), .property)
        XCTAssertEqual(kind(of: "signupKey", in: callLine, spans: callMerged), .method)
        XCTAssertEqual(kind(of: "lid", in: callLine, spans: callMerged), .parameter)

        // 4. Package-qualified exported variable (`os.Stdout`) stays .exportedVariable (preceded by .namespace)
        let pkgVarLine = "_ = os.Stdout"
        let pkgVarSemantic = [
            span("os", in: pkgVarLine, kind: .namespace),
            span("Stdout", in: pkgVarLine, kind: .variable),
        ]
        let pkgVarMerged = SyntaxOverlay.merge(base: [], semantic: pkgVarSemantic, lineText: pkgVarLine)
        XCTAssertEqual(kind(of: "os", in: pkgVarLine, spans: pkgVarMerged), .namespace)
        XCTAssertEqual(kind(of: "Stdout", in: pkgVarLine, spans: pkgVarMerged), .exportedVariable)

        // 5. Builtin func `make`/`delete` stays .builtin while builtin type `string` -> .builtinType
        let makeLine = "grouped := make(map[string][]*nexusBattleSignupProfile)"
        let makeSemantic = [
            span("grouped", in: makeLine, kind: .variable, mods: [.definition]),
            span("make", in: makeLine, kind: .builtin, mods: [.defaultLibrary]),
            span("map", in: makeLine, kind: .keyword),
            span("string", in: makeLine, kind: .builtin, mods: [.defaultLibrary]),
            span("nexusBattleSignupProfile", in: makeLine, kind: .type, mods: [.struct]),
        ]
        let makeMerged = SyntaxOverlay.merge(base: [], semantic: makeSemantic, lineText: makeLine)
        XCTAssertEqual(kind(of: "make", in: makeLine, spans: makeMerged), .builtin)
        XCTAssertEqual(kind(of: "string", in: makeLine, spans: makeMerged), .builtinType)
        XCTAssertEqual(kind(of: "nexusBattleSignupProfile", in: makeLine, spans: makeMerged), .type)

        // 6. TextBuffer.applySemanticTokens preserves Go method receiver `m` as .parameter inside the method body
        let methodLines = [
            "func (m *nexusBattleManager) DeleteSignup(lid int64) {",
            "    m.lock.Lock()",
            "}",
            "func other() { m := 1; _ = m }",
        ]
        let buf = TextBuffer(lines: methodLines)
        buf.spans = Highlighter.highlight(methodLines, language: .go)
        buf.applySemanticTokens([
            0: [
                span("m", in: methodLines[0], kind: .variable, mods: [.definition, .pointer]),
                span("DeleteSignup", in: methodLines[0], kind: .method, mods: [.definition]),
            ],
            1: [
                span("m", in: methodLines[1], kind: .variable, mods: [.pointer]),
                span("lock", in: methodLines[1], kind: .variable),
                span("Lock", in: methodLines[1], kind: .method),
            ],
            3: [
                span("m", in: methodLines[3], kind: .variable, mods: [.definition]),
            ],
        ])
        XCTAssertEqual(kind(of: "m", in: methodLines[0], spans: buf.spans(at: 0)), .parameter)
        XCTAssertEqual(kind(of: "m", in: methodLines[1], spans: buf.spans(at: 1)), .parameter)
        XCTAssertEqual(kind(of: "lock", in: methodLines[1], spans: buf.spans(at: 1)), .property)
        XCTAssertEqual(kind(of: "Lock", in: methodLines[1], spans: buf.spans(at: 1)), .exportedFunction)
        XCTAssertEqual(kind(of: "m", in: methodLines[3], spans: buf.spans(at: 3)), .variable)
    }
}
