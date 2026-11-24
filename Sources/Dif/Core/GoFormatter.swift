import Foundation

/// Runs `gofmt` (falling back to `go fmt`) on Go source files and computes minimal edits and caret mappings
/// so formatting after save updates the active editor session cleanly without losing cursor position or undo history.
enum GoFormatter {
    /// Returns `true` when `url` points to a `.go` source file.
    static func isGoFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "go"
    }

    /// Returns `true` when `path` has a `.go` extension.
    static func isGoFile(path: String) -> Bool {
        (path as NSString).pathExtension.lowercased() == "go"
    }

    /// Formats `data` using `gofmt` (or `go fmt` fallback) when `fileURL` is a `.go` file.
    /// Returns `nil` if no formatter binary is installed, `data` has syntax errors, or formatting was cancelled.
    static func format(
        _ data: Data,
        fileURL: URL,
        executablePath: String? = nil,
        environment: [String: String]? = nil
    ) async -> Data? {
        guard isGoFile(fileURL) else { return nil }
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let env = environment ?? LSPBinaryLocator.environment()
                    let paths = LSPBinaryLocator.searchPaths(from: env)

                    if let explicit = executablePath {
                        let result = runGofmtStdin(data, executable: explicit, directory: fileURL.deletingLastPathComponent(), environment: env, box: box)
                        cont.resume(returning: result)
                        return
                    }

                    if let gofmtPath = LSPBinaryLocator.resolve(executable: "gofmt", searchPaths: paths) {
                        let result = runGofmtStdin(data, executable: gofmtPath, directory: fileURL.deletingLastPathComponent(), environment: env, box: box)
                        cont.resume(returning: result)
                        return
                    }

                    if let goPath = LSPBinaryLocator.resolve(executable: "go", searchPaths: paths) {
                        let siblingGofmt = URL(fileURLWithPath: goPath)
                            .deletingLastPathComponent()
                            .appendingPathComponent("gofmt")
                            .path
                        if FileManager.default.isExecutableFile(atPath: siblingGofmt) {
                            let result = runGofmtStdin(data, executable: siblingGofmt, directory: fileURL.deletingLastPathComponent(), environment: env, box: box)
                            cont.resume(returning: result)
                            return
                        }
                        let result = runGoFmtTempFile(data, goExecutable: goPath, environment: env, box: box)
                        cont.resume(returning: result)
                        return
                    }

                    cont.resume(returning: nil)
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: - Line Alignment & Caret Mapping

    /// Computes disjoint changed line hunks `(oldRange, newRange)` between `oldLines` and `newLines`.
    static func minimalHunks(from oldLines: [String], to newLines: [String]) -> [(oldRange: Range<Int>, newRange: Range<Int>)] {
        guard oldLines != newLines else { return [] }
        guard let aligned = Myers.matches(oldLines, newLines, maxEdits: 4000) else {
            return [(0..<oldLines.count, 0..<newLines.count)]
        }
        var hunks: [(oldRange: Range<Int>, newRange: Range<Int>)] = []
        var i = 0
        var j = 0
        let m = oldLines.count
        let n = newLines.count
        while i < m || j < n {
            if i < m, j < n, aligned.a[i], aligned.b[j] {
                i += 1
                j += 1
            } else {
                let oldStart = i
                let newStart = j
                while i < m, !aligned.a[i] { i += 1 }
                while j < n, !aligned.b[j] { j += 1 }
                hunks.append((oldStart..<i, newStart..<j))
            }
        }
        return hunks
    }

    /// Maps a caret position from `oldLines` onto `newLines`, preserving both the enclosing line and the
    /// logical non-whitespace offset within that line when indentation or spacing changes.
    static func mappedPosition(_ position: TextPosition, from oldLines: [String], to newLines: [String]) -> TextPosition {
        guard !oldLines.isEmpty, !newLines.isEmpty else { return TextPosition(row: 0, column: 0) }
        let clampedOld = TextEditing.clamp(position, in: oldLines)
        let newRow = mappedRow(clampedOld.row, from: oldLines, to: newLines)
        let newCol = mappedColumn(clampedOld.column, from: oldLines[clampedOld.row], to: newLines[newRow])
        return TextPosition(row: newRow, column: newCol)
    }

    private static func mappedRow(_ oldRow: Int, from oldLines: [String], to newLines: [String]) -> Int {
        guard oldLines != newLines else { return min(oldRow, newLines.count - 1) }
        guard let aligned = Myers.matches(oldLines, newLines, maxEdits: 4000) else {
            return min(max(0, newLines.count - 1), oldRow)
        }
        var i = 0
        var j = 0
        let m = oldLines.count
        let n = newLines.count
        while i < m || j < n {
            if i < m, j < n, aligned.a[i], aligned.b[j] {
                if i == oldRow { return j }
                i += 1
                j += 1
            } else {
                let oldStart = i
                let newStart = j
                while i < m, !aligned.a[i] { i += 1 }
                while j < n, !aligned.b[j] { j += 1 }
                if oldRow >= oldStart && oldRow < i {
                    if newStart < j {
                        return min(j - 1, newStart + (oldRow - oldStart))
                    }
                    return min(max(0, n - 1), newStart)
                }
            }
        }
        return min(max(0, n - 1), oldRow)
    }

    private static func mappedColumn(_ oldColumn: Int, from oldLine: String, to newLine: String) -> Int {
        let oldUnits = Array(oldLine.utf16)
        let newUnits = Array(newLine.utf16)
        let clampedOldCol = max(0, min(oldColumn, oldUnits.count))
        if oldLine == newLine { return clampedOldCol }

        func isWhitespace(_ unit: UInt16) -> Bool {
            unit == 0x20 || unit == 0x09 || unit == 0x0D || unit == 0x0A
        }

        var nonWSCount = 0
        for idx in 0..<clampedOldCol where !isWhitespace(oldUnits[idx]) {
            nonWSCount += 1
        }
        if nonWSCount == 0 {
            if clampedOldCol == 0 { return 0 }
            return newUnits.firstIndex(where: { !isWhitespace($0) }) ?? newUnits.count
        }

        var seen = 0
        for (idx, unit) in newUnits.enumerated() where !isWhitespace(unit) {
            seen += 1
            if seen == nonWSCount {
                return idx + 1
            }
        }
        return newUnits.count
    }

    // MARK: - Subprocess Execution

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }

    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var isCancelled = false

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }

        func attach(_ p: Process) {
            lock.lock()
            process = p
            let c = isCancelled
            lock.unlock()
            if c, p.isRunning { p.terminate() }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let p = process
            lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    private static func runGofmtStdin(
        _ data: Data,
        executable: String,
        directory: URL,
        environment: [String: String],
        box: ProcessBox
    ) -> Data? {
        guard !box.cancelled else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = []
        p.environment = environment
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir), isDir.boolValue {
            p.currentDirectoryURL = directory
        }

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return nil
        }
        box.attach(p)

        let group = DispatchGroup()
        let errBuffer = OutputBuffer()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let writer = inPipe.fileHandleForWriting
            if !data.isEmpty {
                try? writer.write(contentsOf: data)
            }
            try? writer.close()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()

        guard !box.cancelled, p.terminationStatus == 0 else { return nil }
        return outData
    }

    private static func runGoFmtTempFile(
        _ data: Data,
        goExecutable: String,
        environment: [String: String],
        box: ProcessBox
    ) -> Data? {
        guard !box.cancelled else { return nil }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dif-gofmt-\(UUID().uuidString)", isDirectory: true)
        let tempFile = tempDir.appendingPathComponent("format.go")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try data.write(to: tempFile)
        } catch {
            return nil
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: goExecutable)
        p.arguments = ["fmt", tempFile.path]
        p.currentDirectoryURL = tempDir
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
        } catch {
            return nil
        }
        box.attach(p)
        p.waitUntilExit()

        guard !box.cancelled, p.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: tempFile)
    }
}
