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
        }

        // GoLand Dark traits
        XCTAssertFalse(CanvasTheme.dark.style(for: .keyword, language: .go).bold)
        XCTAssertTrue(CanvasTheme.dark.style(for: .comment, language: .go).italic)
        XCTAssertTrue(CanvasTheme.dark.style(for: .constant, language: .go).italic)
        XCTAssertTrue(CanvasTheme.dark.style(for: .interface, language: .go).italic)

        // GoLand Light traits
        XCTAssertTrue(CanvasTheme.light.style(for: .keyword, language: .go).bold)
        XCTAssertTrue(CanvasTheme.light.style(for: .comment, language: .go).italic)
        XCTAssertTrue(CanvasTheme.light.style(for: .constant, language: .go).italic)
        XCTAssertTrue(CanvasTheme.light.style(for: .interface, language: .go).italic)
    }

    private func kind(of token: String, in line: String, spans: [SyntaxSpan]) -> TokenKind? {
        let range = (line as NSString).range(of: token)
        return spans.first { Int($0.start) == range.location && Int($0.length) == range.length }?.kind
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

        XCTAssertEqual(kind(of: "Server", in: lines[3], spans: allSpans[3]), .type)
        XCTAssertEqual(kind(of: "any", in: lines[3], spans: allSpans[3]), .builtin)
        XCTAssertEqual(kind(of: "struct", in: lines[3], spans: allSpans[3]), .keyword)

        XCTAssertEqual(kind(of: "string", in: lines[4], spans: allSpans[4]), .builtin)
        XCTAssertEqual(kind(of: "`json:\"name,omitempty\"`", in: lines[4], spans: allSpans[4]), .annotation)

        XCTAssertEqual(kind(of: "Handle", in: lines[6], spans: allSpans[6]), .function)
        XCTAssertEqual(kind(of: "int", in: lines[6], spans: allSpans[6]), .builtin)
        XCTAssertEqual(kind(of: "string", in: lines[6], spans: allSpans[6]), .builtin)
        XCTAssertEqual(kind(of: "error", in: lines[6], spans: allSpans[6]), .builtin)

        XCTAssertEqual(kind(of: "s", in: lines[7], spans: allSpans[7]), .parameter)
        XCTAssertEqual(kind(of: "Server", in: lines[7], spans: allSpans[7]), .type)
        XCTAssertEqual(kind(of: "Start", in: lines[7], spans: allSpans[7]), .method)
        XCTAssertEqual(kind(of: "bool", in: lines[7], spans: allSpans[7]), .builtin)

        XCTAssertEqual(kind(of: "Map", in: lines[8], spans: allSpans[8]), .function)
        XCTAssertEqual(kind(of: "comparable", in: lines[8], spans: allSpans[8]), .builtin)
    }

    func testGoCallsConstantsAndRawStrings() {
        let lines = [
            "xs := make([]int, 0, len(items))",
            "ok := helper(true, false, nil, iota)",
            "srv.Stop()",
            "raw := `a\\` + `multi",
            "line`",
        ]
        let allSpans = Highlighter.highlight(lines, language: .go)

        XCTAssertEqual(kind(of: "make", in: lines[0], spans: allSpans[0]), .builtin)
        XCTAssertEqual(kind(of: "int", in: lines[0], spans: allSpans[0]), .builtin)
        XCTAssertEqual(kind(of: "0", in: lines[0], spans: allSpans[0]), .number)
        XCTAssertEqual(kind(of: "len", in: lines[0], spans: allSpans[0]), .builtin)

        XCTAssertEqual(kind(of: "helper", in: lines[1], spans: allSpans[1]), .function)
        XCTAssertEqual(kind(of: "true", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "false", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "nil", in: lines[1], spans: allSpans[1]), .constant)
        XCTAssertEqual(kind(of: "iota", in: lines[1], spans: allSpans[1]), .constant)

        XCTAssertEqual(kind(of: "Stop", in: lines[2], spans: allSpans[2]), .method)

        XCTAssertEqual(kind(of: "`a\\`", in: lines[3], spans: allSpans[3]), .string)
        XCTAssertEqual(kind(of: "`multi", in: lines[3], spans: allSpans[3]), .string)
        XCTAssertEqual(kind(of: "line`", in: lines[4], spans: allSpans[4]), .string)
    }
}
