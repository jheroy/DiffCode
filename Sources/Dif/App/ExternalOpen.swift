import Foundation

/// Parsed target from a `diffcode://` URL, file URL, or CLI launch argument.
struct ExternalOpenTarget: Equatable, Sendable {
    var fileURL: URL
    /// 1-based line number (`>= 1`) when specified.
    var line: Int?
    /// 0-based UTF-16 column offset (`>= 0`) for `ViewerModel.open`/`reveal` (CLI/URL inputs are 1-based).
    var column: Int?
}

/// Parses external open requests from `diffcode://` URLs, `file://` URLs, and CLI arguments.
enum ExternalOpenParser {
    /// Parses a `file://` or `diffcode://open?path=...&line=...&column=...` URL.
    static func parseURL(_ url: URL) -> ExternalOpenTarget? {
        if url.isFileURL {
            return ExternalOpenTarget(fileURL: url.standardizedFileURL, line: nil, column: nil)
        }
        guard url.scheme?.lowercased() == "diffcode",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let host = components.host?.lowercased() ?? ""
        guard host.isEmpty || host == "open" else { return nil }
        guard let rawPath = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !rawPath.isEmpty else {
            return nil
        }
        let line = parsePositiveInt(components.queryItems?.first(where: { $0.name == "line" })?.value)
        let column = parsePositiveInt(components.queryItems?.first(where: { $0.name == "column" })?.value).map { $0 - 1 }
        return ExternalOpenTarget(
            fileURL: URL(fileURLWithPath: rawPath).standardizedFileURL,
            line: line,
            column: line != nil ? column : nil
        )
    }

    /// Parses CLI arguments (excluding argv[0]), supporting VS Code/T3 Code flags (`--goto`, `--new-window`, `--line`, `--column`),
    /// macOS launch flags (`-NS*`, `-Apple*`, `-psn_*`), `diffcode://` URLs, and `path[:line[:column]]` tokens.
    static func parseArguments(
        _ arguments: [String],
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> [ExternalOpenTarget] {
        var targets: [ExternalOpenTarget] = []
        var literalOnly = false
        var pendingLine: Int?
        var pendingColumn: Int?
        var index = 0

        func applyPending(to target: inout ExternalOpenTarget) {
            if target.line == nil, let line = pendingLine {
                target.line = line
                if target.column == nil, let col = pendingColumn {
                    target.column = col
                }
            } else if target.line != nil, target.column == nil, let col = pendingColumn {
                target.column = col
            }
            pendingLine = nil
            pendingColumn = nil
        }

        while index < arguments.count {
            let arg = arguments[index]
            if !literalOnly {
                if arg == "--" {
                    literalOnly = true
                    index += 1
                    continue
                }
                if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") {
                    index += 2
                    continue
                }
                if arg.hasPrefix("-psn_") {
                    index += 1
                    continue
                }
                if arg == "--new-window" || arg == "-n" || arg == "--reuse-window" || arg == "-r" || arg == "--wait" || arg == "-w" {
                    index += 1
                    continue
                }
                if arg == "-g" || arg == "--goto" {
                    if index + 1 < arguments.count {
                        var parsed = parsePathAndPosition(
                            arguments[index + 1],
                            currentDirectory: currentDirectory,
                            forcePositionSplit: true
                        )
                        applyPending(to: &parsed)
                        targets.append(parsed)
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }
                if arg == "--line" {
                    if index + 1 < arguments.count {
                        if let parsed = parsePositiveInt(arguments[index + 1]) {
                            pendingLine = parsed
                        }
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }
                if arg.hasPrefix("--line=") {
                    if let parsed = parsePositiveInt(String(arg.dropFirst("--line=".count))) {
                        pendingLine = parsed
                    }
                    index += 1
                    continue
                }
                if arg == "--column" {
                    if index + 1 < arguments.count {
                        if let parsed = parsePositiveInt(arguments[index + 1]) {
                            pendingColumn = parsed - 1
                        }
                        index += 2
                    } else {
                        index += 1
                    }
                    continue
                }
                if arg.hasPrefix("--column=") {
                    if let parsed = parsePositiveInt(String(arg.dropFirst("--column=".count))) {
                        pendingColumn = parsed - 1
                    }
                    index += 1
                    continue
                }
                if arg.lowercased().hasPrefix("diffcode://"),
                   let url = URL(string: arg),
                   var parsed = parseURL(url) {
                    applyPending(to: &parsed)
                    targets.append(parsed)
                    index += 1
                    continue
                }
            }

            var parsed = parsePathAndPosition(
                arg,
                currentDirectory: currentDirectory,
                forcePositionSplit: false
            )
            applyPending(to: &parsed)
            targets.append(parsed)
            index += 1
        }

        if (pendingLine != nil || pendingColumn != nil), !targets.isEmpty {
            var last = targets.removeLast()
            applyPending(to: &last)
            targets.append(last)
        }
        return targets
    }

    /// Parses a path or `path:line[:column]` token while preserving existing filenames that contain colons.
    static func parsePathAndPosition(
        _ raw: String,
        currentDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        forcePositionSplit: Bool
    ) -> ExternalOpenTarget {
        let directURL = resolvePath(raw, currentDirectory: currentDirectory)
        if FileManager.default.fileExists(atPath: directURL.path) {
            return ExternalOpenTarget(fileURL: directURL, line: nil, column: nil)
        }

        if let firstColon = raw.lastIndex(of: ":") {
            let suffix1 = String(raw[raw.index(after: firstColon)...])
            let prefix1 = String(raw[..<firstColon])
            if let num1 = parsePositiveInt(suffix1), !prefix1.isEmpty {
                let prefix1URL = resolvePath(prefix1, currentDirectory: currentDirectory)
                if FileManager.default.fileExists(atPath: prefix1URL.path) {
                    return ExternalOpenTarget(fileURL: prefix1URL, line: num1, column: nil)
                }
                if let secondColon = prefix1.lastIndex(of: ":") {
                    let suffix2 = String(prefix1[prefix1.index(after: secondColon)...])
                    let prefix2 = String(prefix1[..<secondColon])
                    if let num2 = parsePositiveInt(suffix2), !prefix2.isEmpty {
                        let prefix2URL = resolvePath(prefix2, currentDirectory: currentDirectory)
                        if FileManager.default.fileExists(atPath: prefix2URL.path) || forcePositionSplit {
                            return ExternalOpenTarget(fileURL: prefix2URL, line: num2, column: num1 - 1)
                        }
                    }
                }
                if forcePositionSplit {
                    return ExternalOpenTarget(fileURL: prefix1URL, line: num1, column: nil)
                }
            }
        }

        return ExternalOpenTarget(fileURL: directURL, line: nil, column: nil)
    }

    private static func resolvePath(_ path: String, currentDirectory: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
    }

    private static func parsePositiveInt(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(raw), value >= 1 else {
            return nil
        }
        return value
    }
}
