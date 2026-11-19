import Foundation

// MARK: - Sendable JSON Value

/// A `Sendable`, `Codable` representation of arbitrary JSON values for JSON-RPC 2.0 messages.
enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let list) = self, index >= 0, index < list.count else { return nil }
        return list[index]
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v) where v.rounded() == v && v >= Double(Int.min) && v <= Double(Int.max): return Int(v)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue: Codable {
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
                     ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

// MARK: - LSP Positions, Ranges & Locations

/// A 0-based position in a text document (`character` is in UTF-16 code units per LSP default encoding).
struct LSPPosition: Sendable, Codable, Equatable, Hashable {
    var line: Int
    var character: Int
}

/// A half-open range inside a text document.
struct LSPRange: Sendable, Codable, Equatable, Hashable {
    var start: LSPPosition
    var end: LSPPosition
}

/// A location inside a resource, such as a symbol definition.
struct LSPLocation: Sendable, Codable, Equatable, Hashable {
    var uri: String
    var range: LSPRange

    /// Local file URL for `uri`, when it is a `file://` URI.
    var fileURL: URL? { LSPURI.fileURL(from: uri) }
}

/// LSP `LocationLink`, returned by servers when `linkSupport` is enabled.
struct LSPLocationLink: Sendable, Codable, Equatable, Hashable {
    var originSelectionRange: LSPRange?
    var targetUri: String
    var targetRange: LSPRange
    var targetSelectionRange: LSPRange

    var asLocation: LSPLocation {
        LSPLocation(uri: targetUri, range: targetSelectionRange)
    }
}

/// Decodes all three LSP `textDocument/definition` response shapes:
/// `null`, single `Location`, `[Location]`, or `[LocationLink]`.
enum LSPDefinitionDecoder {
    static func decode(from value: JSONValue) -> [LSPLocation] {
        switch value {
        case .null:
            return []
        case .object:
            if let loc = decodeLocation(value) { return [loc] }
            if let link = decodeLocationLink(value) { return [link.asLocation] }
            return []
        case .array(let items):
            var results: [LSPLocation] = []
            results.reserveCapacity(items.count)
            for item in items {
                if let loc = decodeLocation(item) {
                    results.append(loc)
                } else if let link = decodeLocationLink(item) {
                    results.append(link.asLocation)
                }
            }
            return results
        default:
            return []
        }
    }

    static func decode(from data: Data) throws -> [LSPLocation] {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        return decode(from: value)
    }

    private static func decodePosition(_ value: JSONValue?) -> LSPPosition? {
        guard let line = value?["line"]?.intValue,
              let character = value?["character"]?.intValue else { return nil }
        return LSPPosition(line: line, character: character)
    }

    private static func decodeRange(_ value: JSONValue?) -> LSPRange? {
        guard let start = decodePosition(value?["start"]),
              let end = decodePosition(value?["end"]) else { return nil }
        return LSPRange(start: start, end: end)
    }

    private static func decodeLocation(_ value: JSONValue) -> LSPLocation? {
        guard let uri = value["uri"]?.stringValue,
              let range = decodeRange(value["range"]) else { return nil }
        return LSPLocation(uri: uri, range: range)
    }

    private static func decodeLocationLink(_ value: JSONValue) -> LSPLocationLink? {
        guard let targetUri = value["targetUri"]?.stringValue,
              let targetRange = decodeRange(value["targetRange"]) else { return nil }
        let selectionRange = decodeRange(value["targetSelectionRange"]) ?? targetRange
        let originRange = decodeRange(value["originSelectionRange"])
        return LSPLocationLink(
            originSelectionRange: originRange,
            targetUri: targetUri,
            targetRange: targetRange,
            targetSelectionRange: selectionRange
        )
    }
}

// MARK: - URI Conversion & Path Canonicalization

/// Converts cleanly between local file `URL`s and LSP `file://` URIs, handling percent-encoding and symlinks.
enum LSPURI {
    /// Resolves symlinks on the longest existing ancestor and standardizes the URL,
    /// so `/var/...` and `/private/var/...` (or `/tmp` and `/private/tmp`) always match.
    static func canonicalFileURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let fm = FileManager.default
        if fm.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        // Walk up until an existing ancestor is found, resolve symlinks there, and re-append trailing components.
        var trailing: [String] = []
        var cursor = standardized
        while cursor.path != "/" && !fm.fileExists(atPath: cursor.path) {
            trailing.append(cursor.lastPathComponent)
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in trailing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    /// Converts a local file `URL` to a canonical LSP `file://` URI string.
    static func uri(from fileURL: URL) -> String {
        let canonical = canonicalFileURL(fileURL)
        var components = URLComponents()
        components.scheme = "file"
        components.host = ""
        components.path = canonical.path
        return components.url?.absoluteString ?? canonical.absoluteString
    }

    /// Converts an LSP `file://` URI string back to a standardized local file `URL`.
    static func fileURL(from uri: String) -> URL? {
        if let url = URL(string: uri), url.isFileURL {
            return canonicalFileURL(url)
        }
        // Fallback for unescaped non-ASCII or space characters in a file:// URI.
        guard uri.hasPrefix("file://") else { return nil }
        let rawPath = String(uri.dropFirst("file://".count))
        let strippedHost: String
        if rawPath.hasPrefix("localhost/") {
            strippedHost = String(rawPath.dropFirst("localhost".count))
        } else {
            strippedHost = rawPath
        }
        let decoded = strippedHost.removingPercentEncoding ?? strippedHost
        guard !decoded.isEmpty else { return nil }
        return canonicalFileURL(URL(fileURLWithPath: decoded))
    }

    /// Canonicalizes any `file://` URI for dictionary keys and equality checks.
    static func normalize(_ uri: String) -> String {
        guard let url = fileURL(from: uri) else { return uri }
        return Self.uri(from: url)
    }

    /// Returns `true` when `child` equals `parent` or resides within `parent` on a path-component boundary.
    static func isPath(_ child: URL, inside parent: URL) -> Bool {
        let childPath = canonicalFileURL(child).path
        let parentPath = canonicalFileURL(parent).path
        if childPath == parentPath { return true }
        let prefix = parentPath == "/" ? "/" : parentPath + "/"
        return childPath.hasPrefix(prefix)
    }
}

// MARK: - Semantic Tokens

/// Semantic token categories aligned 1:1 with DiffCode's extended `TokenKind` palette.
enum LSPSemanticTokenKind: UInt8, CaseIterable, Sendable, Equatable, Hashable {
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
    case type
    case interface
    case method
    case builtin
    case namespace
    case property
    case parameter
    case variable
    case typeParameter
    case `operator`
    case exportedFunction
    case exportedConstant
    case exportedVariable
    case builtinType
    case exportedType
    case exportedProperty

    /// Maps an LSP semantic token type and modifier list (from the server's negotiated legend)
    /// into DiffCode's semantic token categories.
    static func map(tokenType: String, modifiers: [String]) -> LSPSemanticTokenKind {
        let hasDefaultLibrary = modifiers.contains("defaultLibrary")
        let hasReadonly = modifiers.contains("readonly")

        switch tokenType {
        case "namespace", "module":
            return .namespace
        case "interface":
            return hasDefaultLibrary ? .builtin : .interface
        case "type", "class", "struct", "enum":
            if hasDefaultLibrary { return .builtin }
            if modifiers.contains("interface") { return .interface }
            return .type
        case "typeParameter":
            return .typeParameter
        case "parameter":
            return .parameter
        case "variable":
            if hasDefaultLibrary { return .builtin }
            if hasReadonly { return .constant }
            return .variable
        case "property", "field":
            return .property
        case "enumMember", "constant":
            return .constant
        case "function", "event":
            return hasDefaultLibrary ? .builtin : .function
        case "method":
            return hasDefaultLibrary ? .builtin : .method
        case "macro", "decorator", "annotation", "lifetime":
            return hasDefaultLibrary ? .builtin : .annotation
        case "attribute":
            return .attribute
        case "tag":
            return .tag
        case "keyword", "modifier":
            return .keyword
        case "comment":
            return .comment
        case "string", "regexp":
            return .string
        case "number":
            return .number
        case "operator":
            return .operator
        case "builtin":
            return .builtin
        default:
            return hasDefaultLibrary ? .builtin : .plain
        }
    }
}

/// Standard and gopls semantic token modifiers preserved on decoded spans for fine-grained syntax refinement.
struct LSPSemanticTokenModifiers: OptionSet, Sendable, Equatable, Hashable {
    let rawValue: UInt16

    static let declaration    = LSPSemanticTokenModifiers(rawValue: 1 << 0)
    static let definition     = LSPSemanticTokenModifiers(rawValue: 1 << 1)
    static let readonly       = LSPSemanticTokenModifiers(rawValue: 1 << 2)
    static let defaultLibrary = LSPSemanticTokenModifiers(rawValue: 1 << 3)
    static let interface      = LSPSemanticTokenModifiers(rawValue: 1 << 4)
    static let `struct`       = LSPSemanticTokenModifiers(rawValue: 1 << 5)
    static let pointer        = LSPSemanticTokenModifiers(rawValue: 1 << 6)

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    init(names: [String]) {
        var bits: LSPSemanticTokenModifiers = []
        for name in names {
            switch name {
            case "declaration": bits.insert(.declaration)
            case "definition": bits.insert(.definition)
            case "readonly": bits.insert(.readonly)
            case "defaultLibrary": bits.insert(.defaultLibrary)
            case "interface": bits.insert(.interface)
            case "struct": bits.insert(.struct)
            case "pointer": bits.insert(.pointer)
            default: break
            }
        }
        self = bits
    }
}

/// A single LSP semantic highlight run on one line, using UTF-16 code units.
struct LSPSemanticSpan: Sendable, Equatable, Hashable {
    var start: Int32
    var length: Int32
    var kind: LSPSemanticTokenKind
    var modifiers: LSPSemanticTokenModifiers

    init(start: Int32, length: Int32, kind: LSPSemanticTokenKind, modifiers: LSPSemanticTokenModifiers = []) {
        self.start = start
        self.length = length
        self.kind = kind
        self.modifiers = modifiers
    }

    static func == (lhs: LSPSemanticSpan, rhs: LSPSemanticSpan) -> Bool {
        lhs.start == rhs.start && lhs.length == rhs.length && lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(start)
        hasher.combine(length)
        hasher.combine(kind)
    }
}

/// The token type and modifier legend announced by an LSP server in `initialize`.
struct LSPSemanticTokensLegend: Sendable, Codable, Equatable, Hashable {
    var tokenTypes: [String]
    var tokenModifiers: [String]

    /// Standard LSP 3.17 token types advertised in client capabilities.
    static let clientTokenTypes: [String] = [
        "namespace", "type", "class", "enum", "interface", "struct",
        "typeParameter", "parameter", "variable", "property", "enumMember",
        "event", "function", "method", "macro", "keyword", "modifier",
        "comment", "string", "number", "regexp", "operator", "decorator"
    ]

    /// Standard LSP 3.17 token modifiers advertised in client capabilities.
    static let clientTokenModifiers: [String] = [
        "declaration", "definition", "readonly", "static", "deprecated",
        "abstract", "async", "modification", "documentation", "defaultLibrary"
    ]
}

/// Decodes LSP relative-encoded `semanticTokens/full` integer arrays (5-tuples) into per-line spans.
enum LSPSemanticTokensDecoder {
    /// Decodes `[deltaLine, deltaStart, length, tokenTypeIdx, tokenModifiersBitmask, ...]`
    /// into `[lineIndex: [LSPSemanticSpan]]` keyed by 0-based line index.
    static func decode(data: [Int], legend: LSPSemanticTokensLegend) -> [Int: [LSPSemanticSpan]] {
        guard data.count >= 5 else { return [:] }
        var result: [Int: [LSPSemanticSpan]] = [:]
        var line = 0
        var start = 0

        let count = data.count - (data.count % 5)
        var i = 0
        var modifiers: [String] = []
        modifiers.reserveCapacity(4)

        while i < count {
            let deltaLine = data[i]
            let deltaStart = data[i + 1]
            let length = data[i + 2]
            let typeIndex = data[i + 3]
            let modifierBits = data[i + 4]
            i += 5

            line += deltaLine
            if deltaLine == 0 {
                start += deltaStart
            } else {
                start = deltaStart
            }

            guard line >= 0, start >= 0, length > 0,
                  typeIndex >= 0, typeIndex < legend.tokenTypes.count else {
                continue
            }

            modifiers.removeAll(keepingCapacity: true)
            if modifierBits != 0 {
                var bits = modifierBits
                var bitIndex = 0
                while bits != 0 && bitIndex < legend.tokenModifiers.count {
                    if (bits & 1) != 0 {
                        modifiers.append(legend.tokenModifiers[bitIndex])
                    }
                    bits >>= 1
                    bitIndex += 1
                }
            }

            let kind = LSPSemanticTokenKind.map(tokenType: legend.tokenTypes[typeIndex], modifiers: modifiers)
            guard kind != .plain else { continue }
            let span = LSPSemanticSpan(
                start: Int32(start),
                length: Int32(length),
                kind: kind,
                modifiers: LSPSemanticTokenModifiers(names: modifiers)
            )
            result[line, default: []].append(span)
        }

        return result
    }
}

// MARK: - Server Capabilities & Document Session

/// LSP `TextDocumentSyncKind`.
enum LSPTextDocumentSyncKind: Int, Sendable, Codable, Equatable, Hashable {
    case none = 0
    case full = 1
    case incremental = 2
}

/// Subset of server capabilities parsed from the `initialize` response.
struct LSPServerCapabilities: Sendable, Equatable, Hashable {
    var textDocumentSync: LSPTextDocumentSyncKind
    var definitionProvider: Bool
    var semanticTokensLegend: LSPSemanticTokensLegend?
    var semanticTokensFull: Bool

    static let empty = LSPServerCapabilities(
        textDocumentSync: .full,
        definitionProvider: false,
        semanticTokensLegend: nil,
        semanticTokensFull: false
    )

    static func parse(from initializeResult: JSONValue) -> LSPServerCapabilities {
        guard let caps = initializeResult["capabilities"] else { return .empty }

        // textDocumentSync can be an integer or an object with a `change` field.
        let syncKind: LSPTextDocumentSyncKind
        if let raw = caps["textDocumentSync"]?.intValue, let parsed = LSPTextDocumentSyncKind(rawValue: raw) {
            syncKind = parsed
        } else if let raw = caps["textDocumentSync"]?["change"]?.intValue,
                  let parsed = LSPTextDocumentSyncKind(rawValue: raw) {
            syncKind = parsed
        } else {
            syncKind = .full
        }

        // definitionProvider can be a boolean or an options object.
        let definitionProvider: Bool
        if let flag = caps["definitionProvider"]?.boolValue {
            definitionProvider = flag
        } else if caps["definitionProvider"]?.objectValue != nil {
            definitionProvider = true
        } else {
            definitionProvider = false
        }

        // semanticTokensProvider
        var legend: LSPSemanticTokensLegend?
        var fullSupport = false
        if let provider = caps["semanticTokensProvider"] {
            if let legendObj = provider["legend"] {
                let types = legendObj["tokenTypes"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let mods = legendObj["tokenModifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if !types.isEmpty {
                    legend = LSPSemanticTokensLegend(tokenTypes: types, tokenModifiers: mods)
                }
            }
            if let fullBool = provider["full"]?.boolValue {
                fullSupport = fullBool
            } else if provider["full"]?.objectValue != nil {
                fullSupport = true
            }
        }

        return LSPServerCapabilities(
            textDocumentSync: syncKind,
            definitionProvider: definitionProvider,
            semanticTokensLegend: legend,
            semanticTokensFull: fullSupport && legend != nil
        )
    }
}

/// Tracks an open document session managed by `LSPManager`.
struct LSPDocumentSession: Sendable, Equatable, Hashable {
    let uri: String
    let fileURL: URL
    let languageID: String
    var version: Int
    let workspaceRoot: URL
}
