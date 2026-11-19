import Foundation

/// Semantic class of a highlighted run. The raw value indexes the theme's colour table.
enum TokenKind: UInt8, CaseIterable, Sendable {
    case plain = 0
    case keyword
    case string
    case comment
    case number
    case annotation
    case function
    case constant
    case tag
    case attribute
    case type          // 10: structs, named types, classes, enums
    case interface     // 11: interfaces
    case method        // 12: method declarations & calls
    case builtin       // 13: builtin functions & predeclared types (len, make, error, string, int, ...)
    case namespace     // 14: packages / modules / namespaces
    case property      // 15: struct fields / object properties
    case parameter     // 16: function/method parameters
    case variable      // 17: local / package variables
    case typeParameter // 18: generic type parameters
    case `operator`    // 19: operators
}

/// A coloured run inside one line, in UTF-16 units (what CoreText wants).
struct SyntaxSpan: Equatable, Sendable {
    var start: Int32
    var length: Int32
    var kind: TokenKind
}

/// Describes just enough of a language's lexical structure to colour it.
///
/// This is a deliberately small hand-rolled lexer rather than tree-sitter: it needs no
/// grammars on disk, tokenizes ~1M lines/sec, and a diff viewer only needs the broad strokes.
/// Built once into the static definitions below and never changed after, so it is shared across threads freely.
final class LanguageSpec: @unchecked Sendable {
    enum Family { case cLike, markup, yaml, markdown, keyValue, plain }

    let name: String
    let family: Family
    var keywords: Set<String> = []
    var typeKeywords: Set<String> = []
    var builtinKeywords: Set<String> = []
    var constantKeywords: Set<String> = []
    var defKeywords: Set<String> = []
    var lineComments: [[UInt8]] = []
    var blockOpen: [UInt8] = []
    var blockClose: [UInt8] = []
    var quotes: Set<UInt8> = [UInt8(ascii: "\""), UInt8(ascii: "'")]
    var multilineQuotes: Set<UInt8> = []
    var tripleQuotes = false
    var annotations = false
    var preprocessor = false
    var dollarVars = false
    var propertyKeys = false
    var caseInsensitive = false
    var declByShape = false
    var lifetimes = false
    var goReceivers = false
    private(set) var maxKeywordLength = 0

    init(_ name: String, _ family: Family, configure: (LanguageSpec) -> Void = { _ in }) {
        self.name = name
        self.family = family
        configure(self)
        maxKeywordLength = keywords
            .union(typeKeywords)
            .union(builtinKeywords)
            .union(constantKeywords)
            .map(\.utf8.count).max() ?? 0
    }

    func keywords(_ list: String) { keywords.formUnion(list.split(separator: " ").map(String.init)) }
    func types(_ list: String) { typeKeywords.formUnion(list.split(separator: " ").map(String.init)) }
    func builtins(_ list: String) { builtinKeywords.formUnion(list.split(separator: " ").map(String.init)) }
    func constants(_ list: String) { constantKeywords.formUnion(list.split(separator: " ").map(String.init)) }
    func defs(_ list: String) { defKeywords.formUnion(list.split(separator: " ").map(String.init)) }
    func slashComments() {
        lineComments = [Array("//".utf8)]
        blockOpen = Array("/*".utf8)
        blockClose = Array("*/".utf8)
    }
    func hashComments() { lineComments = [Array("#".utf8)] }
}

extension LanguageSpec {
    static let plain = LanguageSpec("Text", .plain)

    static let kotlin = LanguageSpec("Kotlin", .cLike) {
        $0.keywords("""
        abstract actual annotation as break by catch class companion const constructor continue crossinline data \
        delegate do dynamic else enum expect external false final finally for fun get if import in infix init inline \
        inner interface internal is lateinit noinline null object open operator out override package private protected \
        public reified return sealed set super suspend tailrec this throw true try typealias typeof val value var \
        vararg when where while field it
        """)
        $0.defs("fun")
        $0.slashComments()
        $0.tripleQuotes = true
        $0.annotations = true
    }

    static let java = LanguageSpec("Java", .cLike) {
        $0.keywords("""
        abstract assert break case catch class const continue default do else enum extends final finally for goto if \
        implements import instanceof interface native new package private protected public return static strictfp \
        super switch synchronized this throw throws transient try volatile while true false null record sealed \
        permits yield non-sealed
        """)
        $0.types("boolean byte char double float int long short void var")
        $0.slashComments()
        $0.tripleQuotes = true
        $0.annotations = true
        $0.declByShape = true
    }

    static let swift = LanguageSpec("Swift", .cLike) {
        $0.keywords("""
        actor any as associatedtype async await break case catch class continue convenience default defer deinit \
        didSet do dynamic else enum extension fallthrough false fileprivate final for func get guard if import in \
        indirect infix init inout internal is isolated lazy let mutating nil nonisolated nonmutating open operator \
        optional override postfix precedencegroup prefix private protocol public repeat required rethrows return \
        self Self set some static struct subscript super switch throw throws true try typealias unowned var weak \
        where while willSet consuming borrowing macro
        """)
        $0.defs("func")
        $0.slashComments()
        $0.tripleQuotes = true
        $0.annotations = true
        $0.preprocessor = true
        $0.quotes = [UInt8(ascii: "\"")]
    }

    static let javascript = LanguageSpec("JavaScript", .cLike) {
        $0.keywords("""
        abstract any as async await boolean break case catch class const constructor continue debugger declare \
        default delete do else enum export extends false finally for from function get if implements import in \
        infer instanceof interface is keyof let module namespace never new null number object of package private \
        protected public readonly require return satisfies set static string super switch symbol this throw true \
        try type typeof undefined unique unknown var void while with yield
        """)
        $0.defs("function")
        $0.slashComments()
        $0.quotes = [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`")]
        $0.multilineQuotes = [UInt8(ascii: "`")]
        $0.annotations = true
    }

    static let python = LanguageSpec("Python", .cLike) {
        $0.keywords("""
        False None True and as assert async await break case class continue def del elif else except finally for \
        from global if import in is lambda match nonlocal not or pass raise return self try while with yield
        """)
        $0.defs("def class")
        $0.hashComments()
        $0.tripleQuotes = true
        $0.annotations = true
    }

    static let go = LanguageSpec("Go", .cLike) {
        $0.keywords("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map \
        package range return select struct switch type var
        """)
        $0.builtins("""
        bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string \
        uint uint8 uint16 uint32 uint64 uintptr any comparable \
        append cap clear close complex copy delete imag len make max min new panic print println real recover
        """)
        $0.constants("true false nil iota")
        $0.defs("func")
        $0.slashComments()
        $0.quotes = [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`")]
        $0.multilineQuotes = [UInt8(ascii: "`")]
        $0.goReceivers = true
    }

    static let rust = LanguageSpec("Rust", .cLike) {
        $0.keywords("""
        as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod \
        move mut pub ref return self Self static struct super trait true type unsafe use where while union macro_rules
        """)
        $0.types("bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize")
        $0.defs("fn")
        $0.slashComments()
        $0.lifetimes = true
        $0.preprocessor = false
    }

    static let cFamily = LanguageSpec("C/C++", .cLike) {
        $0.keywords("""
        alignas alignof and asm break case catch class co_await co_return co_yield concept const const_cast \
        consteval constexpr constinit continue decltype default delete do dynamic_cast else enum explicit export \
        extern false final for friend goto if inline mutable namespace new noexcept not nullptr operator or \
        override private protected public register reinterpret_cast requires return sizeof static static_assert \
        static_cast struct switch template this thread_local throw true try typedef typeid typename union using \
        virtual volatile while NULL nil self super id instancetype YES NO
        """)
        $0.types("auto bool char char8_t char16_t char32_t double float int long short signed unsigned void wchar_t size_t BOOL")
        $0.slashComments()
        $0.preprocessor = true
        $0.annotations = true // Objective-C @interface, @property …
        $0.declByShape = true
    }

    static let csharp = LanguageSpec("C#", .cLike) {
        $0.keywords("""
        abstract as async await base break case catch checked class const continue default delegate do else enum \
        event explicit extern false finally fixed for foreach get goto if implicit in interface internal is lock \
        namespace new null operator out override params partial private protected public readonly record ref \
        return sealed set sizeof stackalloc static struct switch this throw true try typeof unchecked unsafe using \
        virtual volatile when where while yield
        """)
        $0.types("bool byte char decimal double dynamic float int long object sbyte short string uint ulong ushort var void")
        $0.slashComments()
        $0.preprocessor = true
        $0.declByShape = true
    }

    static let dart = LanguageSpec("Dart", .cLike) {
        $0.keywords("""
        abstract as assert async await base break case catch class const continue covariant default deferred do \
        else enum export extends extension external factory false final finally for get hide if implements import \
        in interface is late library mixin new null on operator part required rethrow return sealed set show \
        static super switch sync this throw true try typedef when while with yield
        """)
        $0.types("bool double dynamic int num var void")
        $0.slashComments()
        $0.tripleQuotes = true
        $0.annotations = true
        $0.declByShape = true
    }

    static let groovy = LanguageSpec("Groovy", .cLike) {
        $0.keywords("""
        abstract as assert break case catch class const continue def default do else enum extends false final \
        finally for goto if implements import in instanceof interface native new null package private protected \
        public return static super switch synchronized this throw throws trait transient true try volatile while
        """)
        $0.types("boolean byte char double float int long short void var")
        $0.defs("def")
        $0.slashComments()
        $0.tripleQuotes = true
        $0.annotations = true
    }

    static let ruby = LanguageSpec("Ruby", .cLike) {
        $0.keywords("""
        alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not \
        or redo rescue retry return self super then true undef unless until when while yield require include attr_accessor
        """)
        $0.defs("def class module")
        $0.hashComments()
    }

    static let php = LanguageSpec("PHP", .cLike) {
        $0.keywords("""
        abstract and array as break callable case catch class clone const continue declare default do echo else \
        elseif empty enddeclare endfor endforeach endif endswitch endwhile enum extends false final finally fn for \
        foreach function global goto if implements include include_once instanceof insteadof interface isset list \
        match namespace new null or print private protected public readonly require require_once return static \
        switch throw trait true try unset use var while xor yield
        """)
        $0.defs("function")
        $0.lineComments = [Array("//".utf8), Array("#".utf8)]
        $0.blockOpen = Array("/*".utf8)
        $0.blockClose = Array("*/".utf8)
        $0.dollarVars = true
    }

    static let shell = LanguageSpec("Shell", .cLike) {
        $0.keywords("""
        if then else elif fi for while until do done case esac function in select time return exit export local \
        readonly declare unset shift source alias echo printf read set cd eval exec trap true false
        """)
        $0.hashComments()
        $0.dollarVars = true
        $0.quotes = [UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: "`")]
        $0.multilineQuotes = [UInt8(ascii: "\""), UInt8(ascii: "'")]
    }

    static let sql = LanguageSpec("SQL", .cLike) {
        $0.keywords("""
        add all alter and as asc begin between by case check column commit constraint create cross database default \
        delete desc distinct drop else end exists foreign from full group having if in index inner insert into is \
        join key left like limit not null offset on or order outer primary references right rollback select set \
        table then transaction union unique update values view when where with
        """)
        $0.types("bigint blob boolean char date datetime decimal double float int integer real text time timestamp varchar")
        $0.lineComments = [Array("--".utf8)]
        $0.blockOpen = Array("/*".utf8)
        $0.blockClose = Array("*/".utf8)
        $0.caseInsensitive = true
    }

    static let css = LanguageSpec("CSS", .cLike) {
        $0.keywords("important inherit initial unset none auto")
        $0.slashComments()
        $0.annotations = true
        $0.propertyKeys = false
    }

    static let lua = LanguageSpec("Lua", .cLike) {
        $0.keywords("and break do else elseif end false for function goto if in local nil not or repeat return then true until while")
        $0.defs("function")
        $0.lineComments = [Array("--".utf8)]
    }

    static let proto = LanguageSpec("Protobuf", .cLike) {
        $0.keywords("""
        syntax package import option message enum service rpc returns repeated optional required oneof map reserved \
        extend extensions stream true false public weak
        """)
        $0.types("bool bytes double fixed32 fixed64 float int32 int64 sfixed32 sfixed64 sint32 sint64 string uint32 uint64")
        $0.slashComments()
    }

    static let json = LanguageSpec("JSON", .cLike) {
        $0.keywords("true false null")
        $0.slashComments()
        $0.quotes = [UInt8(ascii: "\"")]
        $0.propertyKeys = true
    }

    static let cmake = LanguageSpec("CMake", .cLike) {
        $0.keywords("if else elseif endif foreach endforeach while endwhile function endfunction macro endmacro set return include ON OFF TRUE FALSE AND OR NOT")
        $0.hashComments()
        $0.dollarVars = true
        $0.quotes = [UInt8(ascii: "\"")]
    }

    static let xml = LanguageSpec("XML", .markup)
    static let yaml = LanguageSpec("YAML", .yaml)
    static let markdown = LanguageSpec("Markdown", .markdown)
    static let keyValue = LanguageSpec("Config", .keyValue)

    private static let byExtension: [String: LanguageSpec] = {
        var map: [String: LanguageSpec] = [:]
        func add(_ spec: LanguageSpec, _ exts: String) { for e in exts.split(separator: " ") { map[String(e)] = spec } }
        add(kotlin, "kt kts")
        add(java, "java aidl")
        add(swift, "swift")
        add(javascript, "js jsx ts tsx mjs cjs mts cts vue svelte")
        add(python, "py pyi pyw bzl bazel")
        add(go, "go")
        add(rust, "rs")
        add(cFamily, "c h cc cpp cxx hpp hh hxx m mm inl metal glsl vert frag")
        add(csharp, "cs")
        add(dart, "dart")
        add(groovy, "gradle groovy")
        add(ruby, "rb podspec gemspec rake")
        add(php, "php")
        add(shell, "sh bash zsh fish command")
        add(sql, "sql")
        add(css, "css scss less sass")
        add(lua, "lua")
        add(proto, "proto")
        add(json, "json json5 jsonc webmanifest map arb")
        add(cmake, "cmake")
        add(xml, "xml html htm xhtml svg plist storyboard xib iml xsd xsl xslt pom csproj jsp vsdx")
        add(yaml, "yaml yml")
        add(markdown, "md markdown mdx")
        add(keyValue, "properties ini toml cfg conf env pro gitconfig editorconfig lock")
        return map
    }()

    private static let byFileName: [String: LanguageSpec] = [
        "Podfile": ruby, "Gemfile": ruby, "Fastfile": ruby, "Rakefile": ruby, "Appfile": ruby,
        "Dockerfile": shell, "Makefile": shell, "makefile": shell, "gradlew": shell, "Jenkinsfile": groovy,
        "CMakeLists.txt": cmake, ".gitignore": keyValue, ".gitattributes": keyValue, ".gitmodules": keyValue,
        ".zshrc": shell, ".bashrc": shell, ".bash_profile": shell, "BUILD": python, "WORKSPACE": python,
    ]

    static func detect(path: String) -> LanguageSpec {
        let name = (path as NSString).lastPathComponent
        if let spec = byFileName[name] { return spec }
        let ext = (name as NSString).pathExtension.lowercased()
        if let spec = byExtension[ext] { return spec }
        if name.hasPrefix(".env") { return keyValue }
        if name.hasPrefix("Dockerfile") { return shell }
        return plain
    }
}

// MARK: - Lexer

enum Highlighter {
    /// Lines longer than this are left uncoloured; they are almost always minified or generated.
    static let maxLineBytes = 4000

    /// What the lexer carries from one line into the next: an open comment, string or fence.
    struct State: Equatable {
        enum Mode: UInt8 { case normal, blockComment, string, markupComment, markupTag, markupString, cdata, fence }
        var mode: Mode = .normal
        var delimiter: UInt8 = 0
        var triple = false
    }

    static func highlight(_ lines: [String], language: LanguageSpec) -> [[SyntaxSpan]] {
        guard language.family != .plain else { return [] }
        var result = [[SyntaxSpan]](repeating: [], count: lines.count)
        var state = State()
        var spans: [SyntaxSpan] = []
        for index in lines.indices {
            scan(lines[index], language, &state, &spans)
            if !spans.isEmpty { result[index] = spans }
        }
        return result
    }

    /// As `highlight`, also giving the lexer state at the start of every line and after the last one,
    /// which is what lets an edit re-colour only the lines it affects.
    static func highlightTracking(_ lines: [String], language: LanguageSpec) -> (spans: [[SyntaxSpan]], states: [State]) {
        var result = [[SyntaxSpan]](repeating: [], count: lines.count)
        var states: [State] = []
        states.reserveCapacity(lines.count + 1)
        var state = State()
        var spans: [SyntaxSpan] = []
        for index in lines.indices {
            states.append(state)
            guard language.family != .plain else { continue }
            scan(lines[index], language, &state, &spans)
            if !spans.isEmpty { result[index] = spans }
        }
        states.append(state)
        return (result, states)
    }

    /// Re-colours lines `first..<first + count`, which changed, and then the lines after them for as long as
    /// the lexer state coming into a line differs from what it was before (a comment opened or closed).
    ///
    /// `spans` and `states` must already have the new number of lines (`states` one more); the entries for
    /// the changed lines can be anything. Returns the lines whose colours were recomputed.
    @discardableResult
    static func rehighlight(_ lines: [String], language: LanguageSpec, from first: Int, count: Int,
                            spans: inout [[SyntaxSpan]], states: inout [State]) -> Range<Int> {
        guard language.family != .plain, first >= 0, first < lines.count,
              spans.count == lines.count, states.count == lines.count + 1 else { return first..<first }
        var state = states[first]
        var line = first
        var scratch: [SyntaxSpan] = []
        while line < lines.count {
            if line >= first + count, states[line] == state { break }
            states[line] = state
            scan(lines[line], language, &state, &scratch)
            spans[line] = scratch
            line += 1
        }
        if line == lines.count { states[lines.count] = state }
        return first..<line
    }

    /// Colours one line, carrying the lexer state over from the line before. Leaves the spans in `spans`.
    private static func scan(_ line: String, _ language: LanguageSpec, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        spans.removeAll(keepingCapacity: true)
        if line.isEmpty { return }
        var line = line
        line.withUTF8 { buf in
            guard buf.count <= maxLineBytes else { return }
            switch language.family {
            case .cLike: scanCLike(buf, language, &state, &spans)
            case .markup: scanMarkup(buf, &state, &spans)
            case .yaml: scanYAML(buf, &spans)
            case .markdown: scanMarkdown(buf, &state, &spans)
            case .keyValue: scanKeyValue(buf, &spans)
            case .plain: break
            }
            if !spans.isEmpty { convertToUTF16(buf, &spans) }
        }
    }

    /// Spans are produced in byte offsets; rewrite them as UTF-16 offsets when the line is not pure ASCII.
    private static func convertToUTF16(_ buf: UnsafeBufferPointer<UInt8>, _ spans: inout [SyntaxSpan]) {
        var ascii = true
        for b in buf where b >= 0x80 { ascii = false; break }
        if ascii { return }
        var map = [Int32](repeating: 0, count: buf.count + 1)
        var units: Int32 = 0
        for i in 0..<buf.count {
            map[i] = units
            let b = buf[i]
            if b & 0xC0 != 0x80 { units += b >= 0xF0 ? 2 : 1 }
        }
        map[buf.count] = units
        for i in spans.indices {
            let start = Int(spans[i].start), end = min(buf.count, start + Int(spans[i].length))
            spans[i].start = map[start]
            spans[i].length = map[end] - map[start]
        }
    }

    @inline(__always) private static func isDigit(_ c: UInt8) -> Bool { c >= 48 && c <= 57 }
    @inline(__always) private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
    }
    @inline(__always) private static func isIdentPart(_ c: UInt8) -> Bool { isIdentStart(c) || isDigit(c) }
    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 }

    @inline(__always)
    private static func emit(_ spans: inout [SyntaxSpan], _ start: Int, _ end: Int, _ kind: TokenKind) {
        if end > start { spans.append(SyntaxSpan(start: Int32(start), length: Int32(end - start), kind: kind)) }
    }

    private static func matches(_ buf: UnsafeBufferPointer<UInt8>, _ at: Int, _ pattern: [UInt8]) -> Bool {
        guard !pattern.isEmpty, at + pattern.count <= buf.count else { return false }
        for k in 0..<pattern.count where buf[at + k] != pattern[k] { return false }
        return true
    }

    private static func find(_ buf: UnsafeBufferPointer<UInt8>, from: Int, _ pattern: [UInt8]) -> Int? {
        guard !pattern.isEmpty, buf.count >= pattern.count else { return nil }
        var i = from
        let last = buf.count - pattern.count
        while i <= last {
            if buf[i] == pattern[0], matches(buf, i, pattern) { return i }
            i += 1
        }
        return nil
    }

    /// Index just past the closing delimiter of a string starting after `from`, or nil if it runs off the line.
    private static func stringEnd(_ buf: UnsafeBufferPointer<UInt8>, from: Int, delimiter: UInt8, triple: Bool, raw: Bool = false) -> Int? {
        var j = from
        let n = buf.count
        while j < n {
            let c = buf[j]
            if !raw && c == 92 { j += 2; continue } // backslash escape
            if c == delimiter {
                if !triple { return j + 1 }
                if j + 2 < n, buf[j + 1] == delimiter, buf[j + 2] == delimiter { return j + 3 }
            }
            j += 1
        }
        return nil
    }

    // MARK: C-like

    private enum GoDecl { case none, packageName, importAlias, typeName, funcOrReceiver, methodName }

    private static func scanCLike(_ buf: UnsafeBufferPointer<UInt8>, _ spec: LanguageSpec,
                                  _ state: inout State, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = 0
        var prevNonSpace: UInt8 = 0

        switch state.mode {
        case .blockComment:
            if let close = find(buf, from: 0, spec.blockClose) {
                i = close + spec.blockClose.count
                emit(&spans, 0, i, .comment)
                state.mode = .normal
            } else {
                emit(&spans, 0, n, .comment)
                return
            }
        case .string:
            let raw = spec.goReceivers && state.delimiter == 96
            if let end = stringEnd(buf, from: 0, delimiter: state.delimiter, triple: state.triple, raw: raw) {
                emit(&spans, 0, end, .string)
                i = end
                prevNonSpace = state.delimiter
                state.mode = .normal
            } else {
                emit(&spans, 0, n, .string)
                return
            }
        default:
            state.mode = .normal
        }

        var expectName = false     // the next identifier names a declaration (`fun foo`)
        var previousTypeish = false // previous token could be a return type (`String foo(`)
        var sawContent = false
        var goDecl = GoDecl.none

        while i < n {
            let c = buf[i]
            if isSpace(c) { i += 1; continue }

            if spec.lineComments.contains(where: { matches(buf, i, $0) }) {
                emit(&spans, i, n, .comment)
                return
            }
            if matches(buf, i, spec.blockOpen) {
                if let close = find(buf, from: i + spec.blockOpen.count, spec.blockClose) {
                    let end = close + spec.blockClose.count
                    emit(&spans, i, end, .comment)
                    i = end
                    continue
                }
                emit(&spans, i, n, .comment)
                state.mode = .blockComment
                return
            }

            if spec.quotes.contains(c) {
                // Rust lifetimes (`'a`) look like an unterminated char literal.
                if spec.lifetimes, c == 39 {
                    let isChar = (i + 2 < n && buf[i + 2] == 39) || (i + 1 < n && buf[i + 1] == 92)
                    if !isChar { i += 1; prevNonSpace = c; sawContent = true; continue }
                }
                let triple = spec.tripleQuotes && i + 2 < n && buf[i + 1] == c && buf[i + 2] == c
                let bodyStart = triple ? i + 3 : i + 1
                let raw = spec.goReceivers && c == 96
                if let end = stringEnd(buf, from: bodyStart, delimiter: c, triple: triple, raw: raw) {
                    var kind = TokenKind.string
                    if spec.propertyKeys {
                        var k = end
                        while k < n, isSpace(buf[k]) { k += 1 }
                        if k < n, buf[k] == 58 { kind = .attribute }
                    } else if raw, isGoStructTag(buf, start: i, end: end, prevByte: prevNonSpace) {
                        kind = .annotation
                    }
                    emit(&spans, i, end, kind)
                    i = end
                } else {
                    emit(&spans, i, n, .string)
                    if triple || spec.multilineQuotes.contains(c) {
                        state.mode = .string
                        state.delimiter = c
                        state.triple = triple
                    }
                    return
                }
                goDecl = .none
                prevNonSpace = c
                previousTypeish = false
                sawContent = true
                continue
            }

            if isDigit(c) || (c == 46 && i + 1 < n && isDigit(buf[i + 1])) {
                var j = i + 1
                while j < n {
                    let d = buf[j]
                    if isIdentPart(d) && d < 0x80 { j += 1; continue }
                    if d == 46, j + 1 < n, isDigit(buf[j + 1]) { j += 1; continue }
                    break
                }
                emit(&spans, i, j, .number)
                i = j
                goDecl = .none
                prevNonSpace = buf[j - 1]
                previousTypeish = false
                sawContent = true
                continue
            }

            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdentPart(buf[j]) { j += 1 }
                let length = j - i
                var kind = TokenKind.plain
                var typeish = true
                if length <= spec.maxKeywordLength {
                    var word = String(decoding: UnsafeBufferPointer(rebasing: buf[i..<j]), as: UTF8.self)
                    if spec.caseInsensitive { word = word.lowercased() }
                    if spec.keywords.contains(word) {
                        kind = .keyword
                        typeish = false
                        if spec.goReceivers {
                            switch word {
                            case "func": goDecl = .funcOrReceiver
                            case "type": goDecl = .typeName
                            case "package": goDecl = .packageName
                            case "import": goDecl = .importAlias
                            default: goDecl = .none
                            }
                            emit(&spans, i, j, kind)
                            i = j
                            prevNonSpace = buf[j - 1]
                            previousTypeish = false
                            sawContent = true
                            continue
                        } else if spec.defKeywords.contains(word) {
                            expectName = true
                            emit(&spans, i, j, kind)
                            i = j
                            prevNonSpace = buf[j - 1]
                            previousTypeish = false
                            sawContent = true
                            continue
                        }
                    } else if spec.goReceivers {
                        if goDecl != .none {
                            kind = resolveGoDecl(&goDecl, buf, start: i, end: j)
                        } else if spec.builtinKeywords.contains(word) {
                            kind = .builtin
                        } else if spec.constantKeywords.contains(word) {
                            kind = .constant
                            typeish = false
                        }
                    } else if spec.typeKeywords.contains(word) {
                        kind = .keyword
                    } else if spec.builtinKeywords.contains(word) {
                        kind = .builtin
                    } else if spec.constantKeywords.contains(word) {
                        kind = .constant
                        typeish = false
                    }
                }
                if kind == .plain {
                    var k = j
                    while k < n, isSpace(buf[k]) { k += 1 }
                    let next: UInt8 = k < n ? buf[k] : 0
                    if spec.goReceivers {
                        if goDecl != .none {
                            kind = resolveGoDecl(&goDecl, buf, start: i, end: j)
                        } else if next == 40 || (next == 91 && isGoGenericCall(buf, from: k)) {
                            kind = prevNonSpace == 46 ? .method : .function
                        } else if length >= 2, isConstantName(buf, i, j) {
                            kind = .constant
                        }
                    } else if expectName {
                        // `fun Receiver.name()` — keep waiting for the real name after the dot.
                        if next == 46 || next == 60 {
                            typeish = false
                        } else {
                            kind = .function
                            expectName = false
                        }
                    } else if spec.declByShape, previousTypeish, next == 40 {
                        kind = .function
                    } else if length >= 2, isConstantName(buf, i, j) {
                        kind = .constant
                    }
                }
                if kind != .plain { emit(&spans, i, j, kind) }
                previousTypeish = typeish
                prevNonSpace = buf[j - 1]
                i = j
                sawContent = true
                continue
            }

            if c == 64, spec.annotations, i + 1 < n, isIdentStart(buf[i + 1]) { // @Annotation
                var j = i + 1
                while j < n, isIdentPart(buf[j]) || buf[j] == 46 || buf[j] == 58 { j += 1 }
                emit(&spans, i, j, .annotation)
                i = j
                prevNonSpace = buf[j - 1]
                sawContent = true
                continue
            }

            if c == 35, spec.preprocessor, !sawContent { // #include, #if …
                var j = i + 1
                while j < n, isSpace(buf[j]) { j += 1 }
                while j < n, isIdentPart(buf[j]) { j += 1 }
                emit(&spans, i, j, .annotation)
                i = j
                prevNonSpace = buf[j - 1]
                sawContent = true
                continue
            }

            if c == 36, spec.dollarVars, i + 1 < n { // $VAR, ${VAR}
                var j = i + 1
                if buf[j] == 123 {
                    while j < n, buf[j] != 125 { j += 1 }
                    if j < n { j += 1 }
                } else {
                    while j < n, isIdentPart(buf[j]) { j += 1 }
                }
                if j > i + 1 { emit(&spans, i, j, .constant) }
                i = max(j, i + 1)
                prevNonSpace = buf[i - 1]
                sawContent = true
                continue
            }

            // Punctuation.
            if spec.goReceivers, goDecl == .funcOrReceiver {
                if c == 40, let after = scanGoReceiver(buf, openParen: i, spec: spec, spans: &spans) {
                    goDecl = .methodName
                    prevNonSpace = 41
                    sawContent = true
                    i = after
                    continue
                }
                goDecl = .none
            } else if spec.goReceivers, goDecl != .none {
                goDecl = .none
            }

            if expectName {
                if c == 60 { // skip generic parameters: `fun <T> name()`
                    var j = i + 1
                    while j < n, buf[j] != 62 { j += 1 }
                    i = min(n, j + 1)
                    continue
                }
                if c == 40 {
                    expectName = false
                } else if c != 46 && c != 42 && c != 38 {
                    expectName = false
                }
            }
            // `>` and `]` close generic and array types, `*`/`&` decorate pointer types.
            previousTypeish = (c == 62 || c == 93 || c == 42 || c == 38) && previousTypeish || (c == 62 || c == 93)
            prevNonSpace = c
            sawContent = true
            i += 1
        }
    }

    private static func resolveGoDecl(_ goDecl: inout GoDecl, _ buf: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> TokenKind {
        let decl = goDecl
        goDecl = .none
        switch decl {
        case .funcOrReceiver: return .function
        case .methodName: return .method
        case .packageName: return .namespace
        case .importAlias: return (end - start == 1 && buf[start] == 95) ? .plain : .namespace
        case .typeName: return isGoInterfaceDecl(buf, after: end) ? .interface : .type
        case .none: return .plain
        }
    }

    private static func isGoStructTag(_ buf: UnsafeBufferPointer<UInt8>, start: Int, end: Int, prevByte: UInt8) -> Bool {
        guard prevByte != 0,
              isIdentPart(prevByte) || prevByte == 93 || prevByte == 125 || prevByte == 41 || prevByte == 42
        else { return false }
        var k = start + 1
        let limit = end - 1
        while k < limit, isSpace(buf[k]) { k += 1 }
        guard k < limit, isIdentStart(buf[k]), buf[k] < 0x80 else { return false }
        k += 1
        while k < limit, isIdentPart(buf[k]), buf[k] < 0x80 { k += 1 }
        return k + 1 < limit && buf[k] == 58 && buf[k + 1] == 34
    }

    private static func isGoInterfaceDecl(_ buf: UnsafeBufferPointer<UInt8>, after identEnd: Int) -> Bool {
        let n = buf.count
        var k = identEnd
        while k < n, isSpace(buf[k]) { k += 1 }
        if k < n, buf[k] == 91 { // skip generic `[T any]`
            var depth = 0
            while k < n {
                if buf[k] == 91 { depth += 1 } else if buf[k] == 93 {
                    depth -= 1
                    if depth == 0 { k += 1; break }
                }
                k += 1
            }
            while k < n, isSpace(buf[k]) { k += 1 }
        }
        guard k < n, isIdentStart(buf[k]) else { return false }
        let wordStart = k
        while k < n, isIdentPart(buf[k]) { k += 1 }
        return k - wordStart == 9 && matches(buf, wordStart, Array("interface".utf8))
    }

    private static func isGoGenericCall(_ buf: UnsafeBufferPointer<UInt8>, from openBracket: Int) -> Bool {
        let n = buf.count
        var k = openBracket
        var depth = 0
        while k < n {
            if buf[k] == 91 { depth += 1 } else if buf[k] == 93 {
                depth -= 1
                if depth == 0 { k += 1; break }
            }
            k += 1
        }
        guard depth == 0 else { return false }
        while k < n, isSpace(buf[k]) { k += 1 }
        return k < n && buf[k] == 40
    }

    /// Scans `func (r *Recv) Name(...)`; returns the index just past `)` when a method name follows, else nil.
    private static func scanGoReceiver(_ buf: UnsafeBufferPointer<UInt8>, openParen: Int,
                                       spec: LanguageSpec, spans: inout [SyntaxSpan]) -> Int? {
        let n = buf.count
        var k = openParen + 1
        var depth = 1
        while k < n, depth > 0 {
            if buf[k] == 40 { depth += 1 } else if buf[k] == 41 { depth -= 1 }
            k += 1
        }
        guard depth == 0 else { return nil }
        let closeParen = k - 1

        var m = k
        while m < n, isSpace(buf[m]) { m += 1 }
        guard m < n, isIdentStart(buf[m]) else { return nil }
        let nameStart = m
        while m < n, isIdentPart(buf[m]) { m += 1 }
        let nameWord = String(decoding: UnsafeBufferPointer(rebasing: buf[nameStart..<m]), as: UTF8.self)
        guard !spec.keywords.contains(nameWord) else { return nil }
        var afterName = m
        while afterName < n, isSpace(buf[afterName]) { afterName += 1 }
        guard afterName < n, buf[afterName] == 40 || buf[afterName] == 91 else { return nil }

        // Highlight receiver parameter and receiver type inside `(r *Recv[T])`.
        var topIdents: [(Int, Int)] = []
        var typeParamIdents: [(Int, Int)] = []
        var p = openParen + 1
        var bracketDepth = 0
        while p < closeParen {
            let b = buf[p]
            if b == 91 { bracketDepth += 1; p += 1; continue }
            if b == 93 { bracketDepth = max(0, bracketDepth - 1); p += 1; continue }
            if isIdentStart(b) {
                var q = p + 1
                while q < closeParen, isIdentPart(buf[q]) { q += 1 }
                if bracketDepth == 0 {
                    topIdents.append((p, q))
                } else {
                    typeParamIdents.append((p, q))
                }
                p = q
                continue
            }
            p += 1
        }
        if topIdents.count >= 2 {
            emit(&spans, topIdents[0].0, topIdents[0].1, .parameter)
            emit(&spans, topIdents.last!.0, topIdents.last!.1, .type)
        } else if let only = topIdents.first {
            emit(&spans, only.0, only.1, .type)
        }
        for (ts, te) in typeParamIdents {
            let w = String(decoding: UnsafeBufferPointer(rebasing: buf[ts..<te]), as: UTF8.self)
            emit(&spans, ts, te, spec.builtinKeywords.contains(w) ? .builtin : .typeParameter)
        }
        return closeParen + 1
    }

    /// SCREAMING_SNAKE identifiers read as constants.
    private static func isConstantName(_ buf: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> Bool {
        var letters = 0
        for k in from..<to {
            let c = buf[k]
            if c >= 65 && c <= 90 { letters += 1 } else if !(isDigit(c) || c == 95) { return false }
        }
        return letters >= 2
    }

    // MARK: XML / HTML

    private static let commentOpen = Array("<!--".utf8)
    private static let commentClose = Array("-->".utf8)
    private static let cdataOpen = Array("<![CDATA[".utf8)
    private static let cdataClose = Array("]]>".utf8)

    @inline(__always) private static func isNameChar(_ c: UInt8) -> Bool {
        isIdentPart(c) || c == 45 || c == 46 || c == 58
    }

    private static func scanMarkup(_ buf: UnsafeBufferPointer<UInt8>, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = 0
        if state.mode != .markupComment && state.mode != .markupTag && state.mode != .markupString && state.mode != .cdata {
            state.mode = .normal
        }
        while i < n {
            switch state.mode {
            case .markupComment:
                if let close = find(buf, from: i, commentClose) {
                    emit(&spans, i, close + 3, .comment)
                    i = close + 3
                    state.mode = .normal
                } else {
                    emit(&spans, i, n, .comment)
                    return
                }
            case .cdata:
                if let close = find(buf, from: i, cdataClose) {
                    emit(&spans, close, close + 3, .tag)
                    i = close + 3
                    state.mode = .normal
                } else {
                    return
                }
            case .markupString:
                var j = i
                while j < n, buf[j] != state.delimiter { j += 1 }
                if j < n {
                    emit(&spans, i, j + 1, .string)
                    i = j + 1
                    state.mode = .markupTag
                } else {
                    emit(&spans, i, n, .string)
                    return
                }
            case .markupTag:
                let c = buf[i]
                if isSpace(c) { i += 1; continue }
                if c == 62 { // >
                    emit(&spans, i, i + 1, .tag)
                    i += 1
                    state.mode = .normal
                } else if (c == 47 || c == 63) && i + 1 < n && buf[i + 1] == 62 { // /> or ?>
                    emit(&spans, i, i + 2, .tag)
                    i += 2
                    state.mode = .normal
                } else if c == 34 || c == 39 {
                    state.delimiter = c
                    var j = i + 1
                    while j < n, buf[j] != c { j += 1 }
                    if j < n {
                        emit(&spans, i, j + 1, .string)
                        i = j + 1
                    } else {
                        emit(&spans, i, n, .string)
                        state.mode = .markupString
                        return
                    }
                } else if isNameChar(c) {
                    var j = i
                    var colon = -1
                    while j < n, isNameChar(buf[j]) {
                        if buf[j] == 58, colon < 0 { colon = j }
                        j += 1
                    }
                    if colon > i { // namespace prefix, e.g. android:
                        emit(&spans, i, colon + 1, .constant)
                        emit(&spans, colon + 1, j, .attribute)
                    } else {
                        emit(&spans, i, j, .attribute)
                    }
                    i = j
                } else {
                    i += 1
                }
            default:
                let c = buf[i]
                if c == 60 { // <
                    if matches(buf, i, commentOpen) {
                        state.mode = .markupComment
                        continue
                    }
                    if matches(buf, i, cdataOpen) {
                        emit(&spans, i, i + cdataOpen.count, .tag)
                        i += cdataOpen.count
                        state.mode = .cdata
                        continue
                    }
                    var j = i + 1
                    if j < n, buf[j] == 47 || buf[j] == 63 || buf[j] == 33 { j += 1 }
                    while j < n, isNameChar(buf[j]) { j += 1 }
                    emit(&spans, i, j, .tag)
                    i = j
                    state.mode = .markupTag
                } else if c == 38 { // &entity;
                    var j = i + 1
                    while j < n, j - i < 12, buf[j] != 59, !isSpace(buf[j]) { j += 1 }
                    if j < n, buf[j] == 59 { emit(&spans, i, j + 1, .constant); i = j + 1 } else { i += 1 }
                } else {
                    i += 1
                }
            }
        }
    }

    // MARK: YAML

    private static func scanYAML(_ buf: UnsafeBufferPointer<UInt8>, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = 0
        while i < n, isSpace(buf[i]) { i += 1 }
        while i + 1 < n, buf[i] == 45, isSpace(buf[i + 1]) { // "- " list markers
            i += 2
            while i < n, isSpace(buf[i]) { i += 1 }
        }
        if i >= n { return }
        if buf[i] == 35 { emit(&spans, i, n, .comment); return }

        // key:
        if buf[i] != 34 && buf[i] != 39 {
            var j = i
            while j < n {
                if buf[j] == 58, j + 1 == n || isSpace(buf[j + 1]) { break }
                if buf[j] == 35, j > 0, isSpace(buf[j - 1]) { j = n; break }
                j += 1
            }
            if j < n {
                emit(&spans, i, j, .keyword)
                i = j + 1
            }
        }
        scanScalars(buf, from: i, &spans)
    }

    /// Colours strings, numbers, booleans and trailing `#` comments in a value position.
    private static func scanScalars(_ buf: UnsafeBufferPointer<UInt8>, from: Int, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = from
        while i < n {
            let c = buf[i]
            if isSpace(c) { i += 1; continue }
            if c == 35, i == 0 || isSpace(buf[i - 1]) { emit(&spans, i, n, .comment); return }
            if c == 34 || c == 39 {
                let end = stringEnd(buf, from: i + 1, delimiter: c, triple: false) ?? n
                emit(&spans, i, end, .string)
                i = end
                continue
            }
            if c == 38 || c == 42, i + 1 < n, isIdentStart(buf[i + 1]) { // &anchor / *alias
                var j = i + 1
                while j < n, isIdentPart(buf[j]) || buf[j] == 45 { j += 1 }
                emit(&spans, i, j, .annotation)
                i = j
                continue
            }
            var j = i
            while j < n, !isSpace(buf[j]), buf[j] != 44, buf[j] != 93, buf[j] != 125 { j += 1 }
            if j > i {
                if isNumberToken(buf, i, j) {
                    emit(&spans, i, j, .number)
                } else if j - i <= 5 {
                    let word = String(decoding: UnsafeBufferPointer(rebasing: buf[i..<j]), as: UTF8.self).lowercased()
                    if ["true", "false", "null", "yes", "no", "on", "off", "~"].contains(word) { emit(&spans, i, j, .keyword) }
                }
                i = j
            } else {
                i += 1
            }
        }
    }

    private static func isNumberToken(_ buf: UnsafeBufferPointer<UInt8>, _ from: Int, _ to: Int) -> Bool {
        var digits = 0
        for k in from..<to {
            let c = buf[k]
            if isDigit(c) { digits += 1 } else if !(c == 46 || c == 45 || c == 43 || c == 95 || c == 101 || c == 120) { return false }
        }
        return digits > 0
    }

    // MARK: Markdown

    private static func scanMarkdown(_ buf: UnsafeBufferPointer<UInt8>, _ state: inout State, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = 0
        while i < n, isSpace(buf[i]) { i += 1 }
        let isFence = i + 2 < n && (buf[i] == 96 || buf[i] == 126) && buf[i + 1] == buf[i] && buf[i + 2] == buf[i]
        if state.mode == .fence {
            emit(&spans, 0, n, .string)
            if isFence { state.mode = .normal }
            return
        }
        state.mode = .normal
        if isFence {
            emit(&spans, 0, n, .string)
            state.mode = .fence
            return
        }
        if i >= n { return }
        if buf[i] == 35 { emit(&spans, i, n, .keyword); return }           // # heading
        if buf[i] == 62 { emit(&spans, i, n, .comment); return }           // > quote
        if (buf[i] == 45 || buf[i] == 42 || buf[i] == 43), i + 1 < n, isSpace(buf[i + 1]) { // bullets
            emit(&spans, i, i + 1, .keyword)
            i += 2
        } else if isDigit(buf[i]) {
            var j = i
            while j < n, isDigit(buf[j]) { j += 1 }
            if j < n, buf[j] == 46 { emit(&spans, i, j + 1, .keyword); i = j + 1 }
        }
        while i < n {
            let c = buf[i]
            if c == 96 { // `code`
                var j = i + 1
                while j < n, buf[j] != 96 { j += 1 }
                let end = min(n, j + 1)
                emit(&spans, i, end, .string)
                i = end
            } else if c == 93, i + 1 < n, buf[i + 1] == 40 { // ](url)
                var j = i + 2
                while j < n, buf[j] != 41 { j += 1 }
                emit(&spans, i + 2, j, .function)
                i = min(n, j + 1)
            } else if c == 42, i + 1 < n, buf[i + 1] == 42 { // **bold**
                if let close = find(buf, from: i + 2, [42, 42]) {
                    emit(&spans, i, close + 2, .constant)
                    i = close + 2
                } else {
                    i += 2
                }
            } else {
                i += 1
            }
        }
    }

    // MARK: key = value

    private static func scanKeyValue(_ buf: UnsafeBufferPointer<UInt8>, _ spans: inout [SyntaxSpan]) {
        let n = buf.count
        var i = 0
        while i < n, isSpace(buf[i]) { i += 1 }
        if i >= n { return }
        let c = buf[i]
        if c == 35 || c == 59 || c == 33 { emit(&spans, i, n, .comment); return }
        if c == 91 { // [section]
            var j = i
            while j < n, buf[j] != 93 { j += 1 }
            emit(&spans, i, min(n, j + 1), .tag)
            scanScalars(buf, from: min(n, j + 1), &spans)
            return
        }
        var j = i
        while j < n, buf[j] != 61, buf[j] != 58 { j += 1 }
        if j < n {
            var keyEnd = j
            while keyEnd > i, isSpace(buf[keyEnd - 1]) { keyEnd -= 1 }
            emit(&spans, i, keyEnd, .keyword)
            scanScalars(buf, from: j + 1, &spans)
        }
    }
}
