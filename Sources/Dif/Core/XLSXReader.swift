import Foundation
import zlib

// MARK: - Errors

enum XLSXError: LocalizedError, Equatable, Sendable {
    case invalidArchive(String)
    case unsupportedCompression(UInt16)
    case decompressionFailed(String)
    case invalidXML(String)
    case missingWorkbook

    var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason): return "Invalid XLSX archive: \(reason)"
        case .unsupportedCompression(let method): return "Unsupported ZIP compression method: \(method)"
        case .decompressionFailed(let reason): return "Failed to decompress XLSX entry: \(reason)"
        case .invalidXML(let reason): return "Invalid XLSX XML: \(reason)"
        case .missingWorkbook: return "Workbook definition (xl/workbook.xml) not found"
        }
    }
}

// MARK: - Data Model

/// Zero-based cell address within a sheet.
/// Matches `ExcelFileEditor.kt`: `row == -1` denotes the header row (Excel row 1),
/// and `row >= 0` denotes data rows (Excel row 2+).
struct XLSXCellAddress: Hashable, Sendable {
    let row: Int
    let col: Int
}

struct XLSXSheet: Equatable, Sendable {
    let name: String
    let headers: [String]
    let rows: [[String]]
    let comments: [XLSXCellAddress: String]

    /// Returns the display text for a cell (`row == -1` for header, `row >= 0` for data row).
    func cellValue(row: Int, col: Int) -> String {
        guard col >= 0 else { return "" }
        if row == -1 {
            return col < headers.count ? headers[col] : ""
        }
        guard row >= 0, row < rows.count, col < rows[row].count else { return "" }
        return rows[row][col]
    }

    /// Returns the comment attached to `(row, col)`, if any (`row == -1` for header).
    func comment(row: Int, col: Int) -> String? {
        comments[XLSXCellAddress(row: row, col: col)]
    }

    /// Formats the selected cells as TSV matching `ExcelFileEditor.kt:1542-1594`:
    /// - Filters `columns` to those present in `visibleColumns` (preserving order).
    /// - Single cell selection returns the raw cell string without quoting.
    /// - Multi-cell selection outputs tab-separated columns and newline-separated rows,
    ///   quoting and double-escaping `"` for any cell containing `\t`, `\n`, `\r`, or `"`.
    func formatTSV(rows selectedRows: [Int], columns selectedColumns: [Int], visibleColumns: Set<Int>) -> String {
        let validRows = selectedRows.filter { $0 == -1 || ($0 >= 0 && $0 < self.rows.count) }
        let visibleCols = selectedColumns.filter { $0 >= 0 && $0 < headers.count && visibleColumns.contains($0) }
        guard !validRows.isEmpty, !visibleCols.isEmpty else { return "" }

        if validRows.count == 1, visibleCols.count == 1 {
            return cellValue(row: validRows[0], col: visibleCols[0])
        }

        var result = ""
        result.reserveCapacity(validRows.count * visibleCols.count * 12)
        for (rIndex, row) in validRows.enumerated() {
            if rIndex > 0 { result.append("\n") }
            for (cIndex, col) in visibleCols.enumerated() {
                if cIndex > 0 { result.append("\t") }
                let value = cellValue(row: row, col: col)
                if value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\"" }) {
                    result.append("\"")
                    result.append(value.replacingOccurrences(of: "\"", with: "\"\""))
                    result.append("\"")
                } else {
                    result.append(value)
                }
            }
        }
        return result
    }
}

struct XLSXWorkbook: Equatable, Sendable {
    let sheets: [XLSXSheet]

    /// Searches all sheets in order: headers first (`row == -1`), then data rows (`row >= 0`) left-to-right.
    /// Empty queries and invalid regular expressions return `[]` without throwing.
    func search(query: String, mode: XLSXSearchMode) -> [XLSXSearchMatch] {
        guard !query.isEmpty else { return [] }

        let predicate: (String) -> Bool
        switch mode {
        case .caseInsensitive:
            predicate = { text in
                !text.isEmpty && text.range(of: query, options: .caseInsensitive) != nil
            }
        case .caseSensitive:
            predicate = { text in
                !text.isEmpty && text.contains(query)
            }
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                return []
            }
            predicate = { text in
                guard !text.isEmpty else { return false }
                let range = NSRange(location: 0, length: text.utf16.count)
                return regex.firstMatch(in: text, options: [], range: range) != nil
            }
        }

        var matches: [XLSXSearchMatch] = []
        for (sheetIndex, sheet) in sheets.enumerated() {
            for (col, header) in sheet.headers.enumerated() {
                if predicate(header) {
                    matches.append(XLSXSearchMatch(sheetIndex: sheetIndex, row: -1, col: col))
                }
            }
            for (rowIndex, row) in sheet.rows.enumerated() {
                for (col, value) in row.enumerated() {
                    if predicate(value) {
                        matches.append(XLSXSearchMatch(sheetIndex: sheetIndex, row: rowIndex, col: col))
                    }
                }
            }
        }
        return matches
    }
}

enum XLSXSearchMode: String, CaseIterable, Identifiable, Sendable {
    case caseInsensitive
    case caseSensitive
    case regex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .caseInsensitive: return L("Case Insensitive", "不区分大小写")
        case .caseSensitive: return L("Case Sensitive", "区分大小写")
        case .regex: return L("Regex", "正则表达式")
        }
    }
}

struct XLSXSearchMatch: Equatable, Hashable, Sendable {
    let sheetIndex: Int
    /// `-1` for column header match, `0+` for data row match.
    let row: Int
    let col: Int
}

// MARK: - Zero-Dependency ZIP Reader & Writer

struct XLSXZipArchive: Sendable {
    struct Entry: Sendable {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private let data: Data
    private let entriesByKey: [String: Entry]
    let entryNames: [String]

    init(url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        try self.init(data: data)
    }

    init(data: Data) throws {
        self.data = data
        guard data.count >= 22 else {
            throw XLSXError.invalidArchive("File is too small to be a ZIP archive")
        }

        let (entries, names) = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> ([String: Entry], [String]) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw XLSXError.invalidArchive("Empty buffer")
            }
            let count = raw.count

            // 1. Locate End of Central Directory (EOCD) scanning backwards from tail.
            let minEOCDOffset = max(0, count - 22 - 65_535)
            var eocdOffset = -1
            var cursor = count - 22
            while cursor >= minEOCDOffset {
                if Self.readUInt32LE(base, cursor) == 0x06054b50 {
                    let commentLen = Int(Self.readUInt16LE(base, cursor + 20))
                    if cursor + 22 + commentLen == count {
                        eocdOffset = cursor
                        break
                    }
                }
                cursor -= 1
            }
            guard eocdOffset >= 0 else {
                throw XLSXError.invalidArchive("End of Central Directory record not found")
            }

            var totalEntries = UInt64(Self.readUInt16LE(base, eocdOffset + 10))
            var cdSize = UInt64(Self.readUInt32LE(base, eocdOffset + 12))
            var cdOffset = UInt64(Self.readUInt32LE(base, eocdOffset + 16))

            // 2. Check for ZIP64 EOCD Locator immediately before EOCD.
            if eocdOffset >= 20, Self.readUInt32LE(base, eocdOffset - 20) == 0x07064b50 {
                let zip64EOCDOffset = Self.readUInt64LE(base, eocdOffset - 20 + 8)
                if zip64EOCDOffset <= UInt64(count), UInt64(count) - zip64EOCDOffset >= 56 {
                    let z64 = Int(zip64EOCDOffset)
                    if Self.readUInt32LE(base, z64) == 0x06064b50 {
                        if totalEntries == 0xFFFF {
                            totalEntries = Self.readUInt64LE(base, z64 + 32)
                        }
                        if cdSize == 0xFFFFFFFF {
                            cdSize = Self.readUInt64LE(base, z64 + 40)
                        }
                        if cdOffset == 0xFFFFFFFF {
                            cdOffset = Self.readUInt64LE(base, z64 + 48)
                        }
                    }
                }
            }

            guard cdOffset <= UInt64(count),
                  cdSize <= UInt64(count) - cdOffset else {
                throw XLSXError.invalidArchive("Central Directory bounds exceed archive size")
            }

            // 3. Parse Central Directory entries.
            var pos = Int(cdOffset)
            let cdEnd = pos + Int(cdSize)
            var dict: [String: Entry] = [:]
            var names: [String] = []
            let reserve = Int(min(totalEntries, 16_384))
            dict.reserveCapacity(reserve)
            names.reserveCapacity(reserve)

            var parsed = UInt64(0)
            while pos + 46 <= cdEnd && (totalEntries == 0 || parsed < totalEntries) {
                guard Self.readUInt32LE(base, pos) == 0x02014b50 else {
                    throw XLSXError.invalidArchive("Invalid Central Directory header signature")
                }
                let method = Self.readUInt16LE(base, pos + 10)
                let compSize32 = Self.readUInt32LE(base, pos + 20)
                let uncompSize32 = Self.readUInt32LE(base, pos + 24)
                let nameLen = Int(Self.readUInt16LE(base, pos + 28))
                let extraLen = Int(Self.readUInt16LE(base, pos + 30))
                let commentLen = Int(Self.readUInt16LE(base, pos + 32))
                let localOffset32 = Self.readUInt32LE(base, pos + 42)

                let headerTotal = 46 + nameLen + extraLen + commentLen
                guard pos + headerTotal <= cdEnd else {
                    throw XLSXError.invalidArchive("Truncated Central Directory entry")
                }

                let nameStart = pos + 46
                let nameBytes = UnsafeBufferPointer(start: base + nameStart, count: nameLen)
                let name = String(decoding: nameBytes, as: UTF8.self)

                var compSize = UInt64(compSize32)
                var uncompSize = UInt64(uncompSize32)
                var localOffset = UInt64(localOffset32)

                // Parse ZIP64 Extended Information Extra Field (0x0001) when sentinel values are present.
                if compSize32 == 0xFFFFFFFF || uncompSize32 == 0xFFFFFFFF || localOffset32 == 0xFFFFFFFF {
                    let extraStart = nameStart + nameLen
                    let extraEnd = extraStart + extraLen
                    var ep = extraStart
                    while ep + 4 <= extraEnd {
                        let fieldID = Self.readUInt16LE(base, ep)
                        let fieldSize = Int(Self.readUInt16LE(base, ep + 2))
                        let fieldData = ep + 4
                        let fieldEnd = fieldData + fieldSize
                        guard fieldEnd <= extraEnd else { break }
                        if fieldID == 0x0001 {
                            var fp = fieldData
                            if uncompSize32 == 0xFFFFFFFF, fp + 8 <= fieldEnd {
                                uncompSize = Self.readUInt64LE(base, fp)
                                fp += 8
                            }
                            if compSize32 == 0xFFFFFFFF, fp + 8 <= fieldEnd {
                                compSize = Self.readUInt64LE(base, fp)
                                fp += 8
                            }
                            if localOffset32 == 0xFFFFFFFF, fp + 8 <= fieldEnd {
                                localOffset = Self.readUInt64LE(base, fp)
                            }
                            break
                        }
                        ep = fieldEnd
                    }
                }

                let entry = Entry(
                    name: name,
                    compressionMethod: method,
                    compressedSize: compSize,
                    uncompressedSize: uncompSize,
                    localHeaderOffset: localOffset
                )
                let key = Self.normalizePath(name)
                dict[key] = entry
                names.append(name)

                pos += headerTotal
                parsed += 1
            }

            return (dict, names)
        }

        self.entriesByKey = entries
        self.entryNames = names
    }

    func containsEntry(named path: String) -> Bool {
        entriesByKey[Self.normalizePath(path)] != nil
    }

    func readEntry(named path: String) throws -> Data? {
        guard let entry = entriesByKey[Self.normalizePath(path)] else { return nil }
        return try read(entry)
    }

    private func read(_ entry: Entry) throws -> Data {
        let totalSize = UInt64(data.count)
        guard entry.localHeaderOffset <= totalSize,
              totalSize - entry.localHeaderOffset >= 30 else {
            throw XLSXError.invalidArchive("Local file header out of bounds for \(entry.name)")
        }

        let (dataStart, dataEnd) = try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Int, Int) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw XLSXError.invalidArchive("Empty buffer")
            }
            let lh = Int(entry.localHeaderOffset)
            guard Self.readUInt32LE(base, lh) == 0x04034b50 else {
                throw XLSXError.invalidArchive("Invalid local file header signature for \(entry.name)")
            }
            let nameLen = UInt64(Self.readUInt16LE(base, lh + 26))
            let extraLen = UInt64(Self.readUInt16LE(base, lh + 28))
            let payloadStart = entry.localHeaderOffset + 30 + nameLen + extraLen
            guard payloadStart <= totalSize,
                  entry.compressedSize <= totalSize - payloadStart else {
                throw XLSXError.invalidArchive("Compressed payload exceeds archive bounds for \(entry.name)")
            }
            return (Int(payloadStart), Int(payloadStart + entry.compressedSize))
        }

        switch entry.compressionMethod {
        case 0: // Stored
            return data.subdata(in: dataStart..<dataEnd)
        case 8: // Deflate
            return try Self.inflateRaw(data: data, range: dataStart..<dataEnd, expectedSize: entry.uncompressedSize)
        default:
            throw XLSXError.unsupportedCompression(entry.compressionMethod)
        }
    }

    /// Normalizes a ZIP path to a lowercase canonical lookup key (stripping leading `/` and resolving `..` / `.`).
    static func normalizePath(_ path: String) -> String {
        let replaced = path.replacingOccurrences(of: "\\", with: "/")
        var parts: [Substring] = []
        for component in replaced.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(component)
            }
        }
        return parts.joined(separator: "/").lowercased()
    }

    /// Resolves a `.rels` target path relative to an owning part path (e.g. `../comments1.xml` relative to
    /// `xl/worksheets/sheet1.xml` -> `xl/comments1.xml`).
    static func resolvePath(_ target: String, relativeTo basePath: String) -> String {
        let cleanTarget = target.replacingOccurrences(of: "\\", with: "/")
        if cleanTarget.hasPrefix("/") {
            return normalizePath(cleanTarget)
        }
        let normalizedBase = normalizePath(basePath)
        if let lastSlash = normalizedBase.lastIndex(of: "/") {
            let dir = normalizedBase[..<lastSlash]
            return normalizePath("\(dir)/\(cleanTarget)")
        }
        return normalizePath(cleanTarget)
    }

    /// Builds a valid ZIP archive in memory (used by tests and tooling).
    static func create(entries: [(name: String, data: Data)], compress: Bool = true) -> Data {
        var output = Data()
        var centralDirectory = Data()

        for (name, payload) in entries {
            let nameBytes = Data(name.utf8)
            let crc = Self.computeCRC32(payload)
            let method: UInt16
            let storedBytes: Data
            if compress, !payload.isEmpty, let deflated = try? Self.deflateRaw(payload) {
                method = 8
                storedBytes = deflated
            } else {
                method = 0
                storedBytes = payload
            }

            let localOffset = UInt32(output.count)

            // Local file header (30 bytes)
            Self.appendUInt32LE(&output, 0x04034b50)
            Self.appendUInt16LE(&output, 20) // version needed
            Self.appendUInt16LE(&output, 0x0800) // UTF-8 filename flag
            Self.appendUInt16LE(&output, method)
            Self.appendUInt16LE(&output, 0) // mod time
            Self.appendUInt16LE(&output, 0) // mod date
            Self.appendUInt32LE(&output, crc)
            Self.appendUInt32LE(&output, UInt32(storedBytes.count))
            Self.appendUInt32LE(&output, UInt32(payload.count))
            Self.appendUInt16LE(&output, UInt16(nameBytes.count))
            Self.appendUInt16LE(&output, 0) // extra length
            output.append(nameBytes)
            output.append(storedBytes)

            // Central directory header (46 bytes)
            Self.appendUInt32LE(&centralDirectory, 0x02014b50)
            Self.appendUInt16LE(&centralDirectory, 20) // version made by
            Self.appendUInt16LE(&centralDirectory, 20) // version needed
            Self.appendUInt16LE(&centralDirectory, 0x0800) // UTF-8 flag
            Self.appendUInt16LE(&centralDirectory, method)
            Self.appendUInt16LE(&centralDirectory, 0)
            Self.appendUInt16LE(&centralDirectory, 0)
            Self.appendUInt32LE(&centralDirectory, crc)
            Self.appendUInt32LE(&centralDirectory, UInt32(storedBytes.count))
            Self.appendUInt32LE(&centralDirectory, UInt32(payload.count))
            Self.appendUInt16LE(&centralDirectory, UInt16(nameBytes.count))
            Self.appendUInt16LE(&centralDirectory, 0) // extra length
            Self.appendUInt16LE(&centralDirectory, 0) // comment length
            Self.appendUInt16LE(&centralDirectory, 0) // disk number
            Self.appendUInt16LE(&centralDirectory, 0) // internal attrs
            Self.appendUInt32LE(&centralDirectory, 0) // external attrs
            Self.appendUInt32LE(&centralDirectory, localOffset)
            centralDirectory.append(nameBytes)
        }

        let cdOffset = UInt32(output.count)
        let cdSize = UInt32(centralDirectory.count)
        output.append(centralDirectory)

        // End of Central Directory (22 bytes)
        Self.appendUInt32LE(&output, 0x06054b50)
        Self.appendUInt16LE(&output, 0) // disk number
        Self.appendUInt16LE(&output, 0) // cd start disk
        Self.appendUInt16LE(&output, UInt16(entries.count))
        Self.appendUInt16LE(&output, UInt16(entries.count))
        Self.appendUInt32LE(&output, cdSize)
        Self.appendUInt32LE(&output, cdOffset)
        Self.appendUInt16LE(&output, 0) // comment length

        return output
    }

    // MARK: zlib Helpers

    /// Upper bound for a single decompressed XML entry (guards against zip bombs).
    static let maxDecompressedEntryBytes = 256 * 1024 * 1024

    static func inflateRaw(
        data: Data,
        range: Range<Int>,
        expectedSize: UInt64,
        maxOutputBytes: Int = maxDecompressedEntryBytes
    ) throws -> Data {
        if range.isEmpty { return Data() }

        let hardCap = max(1, maxOutputBytes)
        let hinted = Int(min(expectedSize, UInt64(hardCap)))
        let initialCapacity = min(max(hinted, min(256, hardCap)), min(64 * 1024 * 1024, hardCap))
        var output = Data(count: initialCapacity)

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else {
            throw XLSXError.decompressionFailed("inflateInit2 failed with status \(initStatus)")
        }
        defer { inflateEnd(&stream) }

        var totalOut = 0
        try data.withUnsafeBytes { (rawIn: UnsafeRawBufferPointer) in
            guard let inBase = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw XLSXError.decompressionFailed("Missing input buffer")
            }
            stream.next_in = UnsafeMutablePointer(mutating: inBase.advanced(by: range.lowerBound))
            stream.avail_in = uInt(range.count)

            while true {
                if totalOut >= output.count {
                    // Allow growing 1 byte past hardCap so an entry of exact size `hardCap` can emit Z_STREAM_END.
                    let ceiling = hardCap + 1
                    guard output.count < ceiling else {
                        throw XLSXError.decompressionFailed("Entry exceeds maximum decompressed size (\(hardCap) bytes)")
                    }
                    let nextSize = min(ceiling, max(output.count * 2, output.count + 65_536))
                    output.count = nextSize
                }
                let remaining = output.count - totalOut
                let status: Int32 = output.withUnsafeMutableBytes { rawOut in
                    guard let outBase = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outBase.advanced(by: totalOut)
                    stream.avail_out = uInt(min(remaining, Int(UInt32.max)))
                    return inflate(&stream, Z_NO_FLUSH)
                }

                totalOut = Int(stream.total_out)
                if totalOut > hardCap {
                    throw XLSXError.decompressionFailed("Entry exceeds maximum decompressed size (\(hardCap) bytes)")
                }

                if status == Z_STREAM_END {
                    break
                } else if status == Z_OK {
                    if stream.avail_out == 0 {
                        continue
                    }
                    if stream.avail_in == 0 {
                        throw XLSXError.decompressionFailed("Truncated deflate stream")
                    }
                } else if status == Z_BUF_ERROR && stream.avail_out == 0 {
                    continue
                } else {
                    throw XLSXError.decompressionFailed("inflate failed with status \(status)")
                }
            }
        }

        output.count = totalOut
        return output
    }

    private static func deflateRaw(_ input: Data) throws -> Data {
        if input.isEmpty { return Data() }

        var stream = z_stream()
        let initStatus = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard initStatus == Z_OK else {
            throw XLSXError.decompressionFailed("deflateInit2 failed with status \(initStatus)")
        }
        defer { deflateEnd(&stream) }

        let bound = Int(deflateBound(&stream, uLong(input.count))) + 16
        var output = Data(count: bound)
        var totalOut = 0

        try input.withUnsafeBytes { rawIn in
            guard let inBase = rawIn.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            stream.next_in = UnsafeMutablePointer(mutating: inBase)
            stream.avail_in = uInt(input.count)

            while true {
                if totalOut >= output.count {
                    output.count = output.count * 2 + 64
                }
                let remaining = output.count - totalOut
                let status: Int32 = output.withUnsafeMutableBytes { rawOut in
                    guard let outBase = rawOut.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return Z_MEM_ERROR
                    }
                    stream.next_out = outBase.advanced(by: totalOut)
                    stream.avail_out = uInt(min(remaining, Int(UInt32.max)))
                    return deflate(&stream, Z_FINISH)
                }
                totalOut = Int(stream.total_out)
                if status == Z_STREAM_END {
                    break
                } else if status != Z_OK {
                    throw XLSXError.decompressionFailed("deflate failed with status \(status)")
                }
            }
        }

        output.count = totalOut
        return output
    }

    private static func computeCRC32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            let crc = zlib.crc32(0, base, uInt(raw.count))
            return UInt32(truncatingIfNeeded: crc)
        }
    }

    // MARK: Little-Endian Primitives

    @inline(__always)
    private static func readUInt16LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        UInt16(base[offset]) | (UInt16(base[offset + 1]) << 8)
    }

    @inline(__always)
    private static func readUInt32LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        UInt32(base[offset])
            | (UInt32(base[offset + 1]) << 8)
            | (UInt32(base[offset + 2]) << 16)
            | (UInt32(base[offset + 3]) << 24)
    }

    @inline(__always)
    private static func readUInt64LE(_ base: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        UInt64(readUInt32LE(base, offset)) | (UInt64(readUInt32LE(base, offset + 4)) << 32)
    }

    private static func appendUInt16LE(_ data: inout Data, _ v: UInt16) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
    }

    private static func appendUInt32LE(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(truncatingIfNeeded: v))
        data.append(UInt8(truncatingIfNeeded: v >> 8))
        data.append(UInt8(truncatingIfNeeded: v >> 16))
        data.append(UInt8(truncatingIfNeeded: v >> 24))
    }
}

// MARK: - Streaming UTF-8 XML Scanner

/// Low-overhead, zero-DOM streaming XML scanner over raw UTF-8 bytes.
/// Allocates no dictionaries per tag and handles namespaces, comments, CDATA, PIs, and XML entities.
private struct FastXMLScanner {
    struct ByteSlice {
        let start: Int
        let end: Int
        var isEmpty: Bool { start >= end }
        var count: Int { end - start }
    }

    struct Attribute {
        let name: ByteSlice
        let value: ByteSlice
    }

    private let base: UnsafePointer<UInt8>
    private let count: Int
    private var pos: Int

    init(base: UnsafePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
        // Skip optional UTF-8 BOM (EF BB BF).
        if count >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF {
            self.pos = 3
        } else {
            self.pos = 0
        }
    }

    enum Token {
        case startElement(localName: ByteSlice, attrStart: Int, attrEnd: Int, selfClosing: Bool)
        case endElement(localName: ByteSlice)
        case text(ByteSlice, isCDATA: Bool)
    }

    mutating func nextToken() -> Token? {
        while pos < count {
            if base[pos] == 0x3C { // '<'
                let next = pos + 1
                guard next < count else { pos = count; return nil }
                let ch = base[next]

                if ch == 0x2F { // "</" end tag
                    pos = next + 1
                    let nameStart = pos
                    while pos < count && !Self.isSpace(base[pos]) && base[pos] != 0x3E { pos += 1 }
                    let local = localNameSlice(start: nameStart, end: pos)
                    while pos < count && base[pos] != 0x3E { pos += 1 }
                    if pos < count { pos += 1 } // consume '>'
                    return .endElement(localName: local)
                }

                if ch == 0x3F { // "<?" processing instruction
                    pos = next + 1
                    while pos + 1 < count {
                        if base[pos] == 0x3F && base[pos + 1] == 0x3E {
                            pos += 2
                            break
                        }
                        pos += 1
                    }
                    if pos + 1 >= count { pos = count }
                    continue
                }

                if ch == 0x21 { // "<!" comment, CDATA, or DOCTYPE
                    if next + 2 < count && base[next + 1] == 0x2D && base[next + 2] == 0x2D {
                        // <!-- ... -->
                        pos = next + 3
                        while pos + 2 < count {
                            if base[pos] == 0x2D && base[pos + 1] == 0x2D && base[pos + 2] == 0x3E {
                                pos += 3
                                break
                            }
                            pos += 1
                        }
                        if pos + 2 >= count { pos = count }
                        continue
                    }
                    if next + 7 < count
                        && base[next + 1] == 0x5B // '['
                        && base[next + 2] == 0x43 // 'C'
                        && base[next + 3] == 0x44 // 'D'
                        && base[next + 4] == 0x41 // 'A'
                        && base[next + 5] == 0x54 // 'T'
                        && base[next + 6] == 0x41 // 'A'
                        && base[next + 7] == 0x5B // '['
                    {
                        pos = next + 8
                        let textStart = pos
                        while pos + 2 < count {
                            if base[pos] == 0x5D && base[pos + 1] == 0x5D && base[pos + 2] == 0x3E {
                                let slice = ByteSlice(start: textStart, end: pos)
                                pos += 3
                                return .text(slice, isCDATA: true)
                            }
                            pos += 1
                        }
                        let slice = ByteSlice(start: textStart, end: count)
                        pos = count
                        return .text(slice, isCDATA: true)
                    }
                    // DOCTYPE or other declaration: skip to matching '>' (handling [...] subset).
                    pos = next + 1
                    var inBrackets = false
                    while pos < count {
                        let b = base[pos]
                        if b == 0x5B { inBrackets = true }
                        else if b == 0x5D { inBrackets = false }
                        else if b == 0x3E && !inBrackets { pos += 1; break }
                        pos += 1
                    }
                    continue
                }

                // Start tag: <name attrs...> or <name attrs.../>
                pos = next
                let nameStart = pos
                while pos < count && !Self.isSpace(base[pos]) && base[pos] != 0x3E && base[pos] != 0x2F {
                    pos += 1
                }
                let local = localNameSlice(start: nameStart, end: pos)
                let attrStart = pos

                // Scan to closing '>' respecting single/double quoted attribute values.
                var quote: UInt8 = 0
                while pos < count {
                    let b = base[pos]
                    if quote != 0 {
                        if b == quote { quote = 0 }
                    } else if b == 0x22 || b == 0x27 { // '"' or '\''
                        quote = b
                    } else if b == 0x3E { // '>'
                        break
                    }
                    pos += 1
                }
                let tagClose = pos
                var attrEnd = tagClose
                var selfClosing = false
                if attrEnd > attrStart && base[attrEnd - 1] == 0x2F {
                    selfClosing = true
                    attrEnd -= 1
                }
                if pos < count { pos += 1 } // consume '>'
                return .startElement(localName: local, attrStart: attrStart, attrEnd: attrEnd, selfClosing: selfClosing)
            } else {
                let textStart = pos
                while pos < count && base[pos] != 0x3C { pos += 1 }
                return .text(ByteSlice(start: textStart, end: pos), isCDATA: false)
            }
        }
        return nil
    }

    @inline(__always)
    func forEachAttribute(start: Int, end: Int, _ body: (ByteSlice, ByteSlice) -> Void) {
        var i = start
        while i < end {
            while i < end && Self.isSpace(base[i]) { i += 1 }
            if i >= end { break }
            let nameStart = i
            while i < end && !Self.isSpace(base[i]) && base[i] != 0x3D { i += 1 }
            let nameEnd = i
            while i < end && Self.isSpace(base[i]) { i += 1 }
            guard i < end && base[i] == 0x3D else { break } // '='
            i += 1
            while i < end && Self.isSpace(base[i]) { i += 1 }
            guard i < end else { break }
            let q = base[i]
            guard q == 0x22 || q == 0x27 else { break }
            i += 1
            let valStart = i
            while i < end && base[i] != q { i += 1 }
            let valEnd = i
            if i < end { i += 1 }
            body(ByteSlice(start: nameStart, end: nameEnd), ByteSlice(start: valStart, end: valEnd))
        }
    }

    @inline(__always)
    func localNameSlice(start: Int, end: Int) -> ByteSlice {
        var s = start
        var i = start
        while i < end {
            if base[i] == 0x3A { // ':'
                s = i + 1
            }
            i += 1
        }
        return ByteSlice(start: s, end: end)
    }

    @inline(__always)
    func equalsASCII(_ slice: ByteSlice, _ literal: StaticString) -> Bool {
        let len = literal.utf8CodeUnitCount
        guard slice.count == len else { return false }
        return literal.withUTF8Buffer { lit in
            for i in 0..<len where base[slice.start + i] != lit[i] {
                return false
            }
            return true
        }
    }

    @inline(__always)
    func localEqualsASCII(_ slice: ByteSlice, _ literal: StaticString) -> Bool {
        equalsASCII(localNameSlice(start: slice.start, end: slice.end), literal)
    }

    /// Decodes a UTF-8 slice, resolving XML entities only if `&` is present.
    func decodeString(_ slice: ByteSlice, decodeEntities: Bool = true) -> String {
        guard !slice.isEmpty else { return "" }
        if !decodeEntities || !containsAmpersand(slice) {
            return String(decoding: UnsafeBufferPointer(start: base + slice.start, count: slice.count), as: UTF8.self)
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(slice.count)
        var i = slice.start
        while i < slice.end {
            if base[i] == 0x26 { // '&'
                var semi = i + 1
                let limit = min(slice.end, i + 12)
                while semi < limit && base[semi] != 0x3B { semi += 1 }
                if semi < limit && base[semi] == 0x3B {
                    let entityLen = semi - (i + 1)
                    if let scalar = decodeEntity(start: i + 1, length: entityLen) {
                        for u in scalar.utf8 { bytes.append(u) }
                        i = semi + 1
                        continue
                    }
                }
            }
            bytes.append(base[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Parses a non-negative base-10 ASCII integer directly from a byte slice.
    @inline(__always)
    func parseASCIIInt(_ slice: ByteSlice) -> Int? {
        guard !slice.isEmpty else { return nil }
        var value = 0
        var i = slice.start
        while i < slice.end {
            let b = base[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let (mul, o1) = value.multipliedReportingOverflow(by: 10)
            let (add, o2) = mul.addingReportingOverflow(Int(b - 0x30))
            if o1 || o2 { return nil }
            value = add
            i += 1
        }
        return value
    }

    /// Excel worksheet bounds: 16,384 columns (`XFD`) and 1,048,576 rows.
    static let maxColumns = 16_384
    static let maxRows = 1_048_576

    /// Parses an Excel cell reference like `AB12` into zero-based `(row, col)`.
    /// Rejects arithmetic overflows and coordinates outside Excel's limits (`XFD` / `1_048_576`).
    @inline(__always)
    func parseCellRef(_ slice: ByteSlice) -> (row: Int, col: Int)? {
        guard !slice.isEmpty else { return nil }
        var i = slice.start
        var col = 0
        var hasLetters = false
        while i < slice.end {
            let b = base[i]
            let letterVal: Int
            if b >= 0x41 && b <= 0x5A { // 'A'...'Z'
                letterVal = Int(b - 0x41) + 1
            } else if b >= 0x61 && b <= 0x7A { // 'a'...'z'
                letterVal = Int(b - 0x61) + 1
            } else {
                break
            }
            let (mul, o1) = col.multipliedReportingOverflow(by: 26)
            let (add, o2) = mul.addingReportingOverflow(letterVal)
            if o1 || o2 || add > Self.maxColumns { return nil }
            col = add
            hasLetters = true
            i += 1
        }
        guard hasLetters, i < slice.end else { return nil }
        var row = 0
        var hasDigits = false
        while i < slice.end {
            let b = base[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let (mul, o1) = row.multipliedReportingOverflow(by: 10)
            let (add, o2) = mul.addingReportingOverflow(Int(b - 0x30))
            if o1 || o2 || add > Self.maxRows { return nil }
            row = add
            hasDigits = true
            i += 1
        }
        guard hasDigits, row > 0, col > 0 else { return nil }
        return (row - 1, col - 1)
    }

    @inline(__always)
    private func containsAmpersand(_ slice: ByteSlice) -> Bool {
        var i = slice.start
        while i < slice.end {
            if base[i] == 0x26 { return true }
            i += 1
        }
        return false
    }

    private func decodeEntity(start: Int, length: Int) -> Unicode.Scalar? {
        guard length > 0 else { return nil }
        if base[start] == 0x23 { // '#'
            guard length >= 2 else { return nil }
            var code: UInt32 = 0
            if base[start + 1] == 0x78 || base[start + 1] == 0x58 { // 'x' or 'X'
                guard length >= 3 else { return nil }
                for k in (start + 2)..<(start + length) {
                    let b = base[k]
                    let digit: UInt32
                    if b >= 0x30 && b <= 0x39 { digit = UInt32(b - 0x30) }
                    else if b >= 0x41 && b <= 0x46 { digit = UInt32(b - 0x41) + 10 }
                    else if b >= 0x61 && b <= 0x66 { digit = UInt32(b - 0x61) + 10 }
                    else { return nil }
                    code = (code << 4) | digit
                    if code > 0x10FFFF { return nil }
                }
            } else {
                for k in (start + 1)..<(start + length) {
                    let b = base[k]
                    guard b >= 0x30 && b <= 0x39 else { return nil }
                    code = code * 10 + UInt32(b - 0x30)
                    if code > 0x10FFFF { return nil }
                }
            }
            return Unicode.Scalar(code)
        }
        let slice = ByteSlice(start: start, end: start + length)
        if equalsASCII(slice, "amp") { return "&" }
        if equalsASCII(slice, "lt") { return "<" }
        if equalsASCII(slice, "gt") { return ">" }
        if equalsASCII(slice, "quot") { return "\"" }
        if equalsASCII(slice, "apos") { return "'" }
        return nil
    }

    @inline(__always)
    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D
    }
}

// MARK: - XLSX Reader

enum XLSXReader {
    static func parse(url: URL) throws -> XLSXWorkbook {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try parse(data: data)
    }

    static func parse(data: Data) throws -> XLSXWorkbook {
        let archive = try XLSXZipArchive(data: data)

        // 1. Locate workbook.xml (prefer standard path, fall back to _rels/.rels).
        let workbookPath = resolveWorkbookPath(in: archive)
        guard let workbookData = try archive.readEntry(named: workbookPath) else {
            throw XLSXError.missingWorkbook
        }
        let workbookMeta = parseWorkbookXML(workbookData)

        // 2. Parse workbook relationships (r:id -> target path).
        let workbookRelsPath = relsPath(for: workbookPath)
        let workbookRels: [Relationship]
        if let relsData = try archive.readEntry(named: workbookRelsPath) {
            workbookRels = parseRelationshipsXML(relsData, basePartPath: workbookPath)
        } else {
            workbookRels = []
        }
        var relById: [String: Relationship] = [:]
        relById.reserveCapacity(workbookRels.count)
        for rel in workbookRels {
            relById[rel.id] = rel
        }

        // 3. Parse sharedStrings.xml (optional).
        let sharedStringsPath = workbookRels.first(where: { $0.type.hasSuffix("/sharedStrings") })?.targetPath
            ?? "xl/sharedStrings.xml"
        let sharedStrings: [String]
        if let ssData = try archive.readEntry(named: sharedStringsPath) {
            sharedStrings = parseSharedStringsXML(ssData)
        } else {
            sharedStrings = []
        }

        // 4. Parse styles.xml (optional) to detect date-formatted cells.
        let stylesPath = workbookRels.first(where: { $0.type.hasSuffix("/styles") })?.targetPath
            ?? "xl/styles.xml"
        let styleTable: StyleTable
        if let stylesData = try archive.readEntry(named: stylesPath) {
            styleTable = parseStylesXML(stylesData)
        } else {
            styleTable = StyleTable(cellXfIsDate: [])
        }

        // 5. Parse each worksheet in exact workbook order.
        var sheets: [XLSXSheet] = []
        sheets.reserveCapacity(workbookMeta.sheets.count)
        for (index, sheetInfo) in workbookMeta.sheets.enumerated() {
            let sheetPath = relById[sheetInfo.relId]?.targetPath
                ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let sheetData = try archive.readEntry(named: sheetPath) else {
                sheets.append(XLSXSheet(name: sheetInfo.name, headers: [], rows: [], comments: [:]))
                continue
            }

            let comments = try loadComments(forSheetAt: sheetPath, in: archive)
            let sheet = parseWorksheetXML(
                sheetData,
                name: sheetInfo.name,
                sharedStrings: sharedStrings,
                styleTable: styleTable,
                use1904DateSystem: workbookMeta.use1904DateSystem,
                comments: comments
            )
            sheets.append(sheet)
        }

        return XLSXWorkbook(sheets: sheets)
    }

    /// Ultra-fast sheet-name extractor for Quick Open indexing.
    /// Reads ONLY the ZIP Central Directory and `xl/workbook.xml` without decompressing
    /// `sharedStrings.xml`, `styles.xml`, or any worksheet XML.
    static func sheetNames(at url: URL) -> [String] {
        guard let archive = try? XLSXZipArchive(url: url) else { return [] }
        return extractSheetNames(from: archive)
    }

    static func sheetNames(data: Data) -> [String] {
        guard let archive = try? XLSXZipArchive(data: data) else { return [] }
        return extractSheetNames(from: archive)
    }

    private static func extractSheetNames(from archive: XLSXZipArchive) -> [String] {
        let workbookPath = resolveWorkbookPath(in: archive)
        guard let workbookData = try? archive.readEntry(named: workbookPath) else { return [] }
        return parseWorkbookXML(workbookData).sheets.map(\.name)
    }

    // MARK: Internal Structures

    private struct SheetEntry {
        let name: String
        let relId: String
    }

    private struct WorkbookMeta {
        let sheets: [SheetEntry]
        let use1904DateSystem: Bool
    }

    private struct Relationship {
        let id: String
        let type: String
        let targetPath: String
    }

    private struct StyleTable {
        let cellXfIsDate: [Bool]

        @inline(__always)
        func isDateStyle(_ styleIndex: Int) -> Bool {
            styleIndex >= 0 && styleIndex < cellXfIsDate.count && cellXfIsDate[styleIndex]
        }
    }

    private enum CellType: UInt8 {
        case number = 0
        case sharedString
        case inlineString
        case boolean
        case formulaString
        case error
        case isoDate
    }

    // MARK: Path Helpers

    private static func resolveWorkbookPath(in archive: XLSXZipArchive) -> String {
        if archive.containsEntry(named: "xl/workbook.xml") {
            return "xl/workbook.xml"
        }
        if let rootRelsData = try? archive.readEntry(named: "_rels/.rels") {
            let rels = parseRelationshipsXML(rootRelsData, basePartPath: "")
            if let wb = rels.first(where: { $0.type.hasSuffix("/officeDocument") }) {
                return wb.targetPath
            }
        }
        return "xl/workbook.xml"
    }

    private static func relsPath(for partPath: String) -> String {
        let normalized = XLSXZipArchive.normalizePath(partPath)
        if let slash = normalized.lastIndex(of: "/") {
            let dir = normalized[..<slash]
            let file = normalized[normalized.index(after: slash)...]
            return "\(dir)/_rels/\(file).rels"
        }
        return "_rels/\(normalized).rels"
    }

    // MARK: workbook.xml

    private static func parseWorkbookXML(_ data: Data) -> WorkbookMeta {
        var sheets: [SheetEntry] = []
        var use1904 = false

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)
            while let token = scanner.nextToken() {
                guard case .startElement(let local, let attrStart, let attrEnd, _) = token else { continue }
                if scanner.equalsASCII(local, "workbookPr") {
                    scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                        if scanner.localEqualsASCII(name, "date1904") {
                            if scanner.equalsASCII(val, "1") || scanner.equalsASCII(val, "true") {
                                use1904 = true
                            }
                        }
                    }
                } else if scanner.equalsASCII(local, "sheet") {
                    var sheetName = ""
                    var relId = ""
                    scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                        if scanner.localEqualsASCII(name, "name") {
                            sheetName = scanner.decodeString(val)
                        } else if scanner.localEqualsASCII(name, "id") {
                            relId = scanner.decodeString(val)
                        }
                    }
                    if !sheetName.isEmpty || !relId.isEmpty {
                        sheets.append(SheetEntry(name: sheetName, relId: relId))
                    }
                }
            }
        }

        return WorkbookMeta(sheets: sheets, use1904DateSystem: use1904)
    }

    // MARK: .rels XML

    private static func parseRelationshipsXML(_ data: Data, basePartPath: String) -> [Relationship] {
        var result: [Relationship] = []

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)
            while let token = scanner.nextToken() {
                guard case .startElement(let local, let attrStart, let attrEnd, _) = token,
                      scanner.equalsASCII(local, "Relationship") else { continue }
                var id = ""
                var type = ""
                var target = ""
                scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                    if scanner.localEqualsASCII(name, "Id") {
                        id = scanner.decodeString(val)
                    } else if scanner.localEqualsASCII(name, "Type") {
                        type = scanner.decodeString(val)
                    } else if scanner.localEqualsASCII(name, "Target") {
                        target = scanner.decodeString(val)
                    }
                }
                if !target.isEmpty {
                    let resolved = XLSXZipArchive.resolvePath(target, relativeTo: basePartPath)
                    result.append(Relationship(id: id, type: type, targetPath: resolved))
                }
            }
        }

        return result
    }

    // MARK: sharedStrings.xml

    private static func parseSharedStringsXML(_ data: Data) -> [String] {
        var strings: [String] = []

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)
            var inSI = false
            var inT = false
            var phoneticDepth = 0
            var current = ""

            while let token = scanner.nextToken() {
                switch token {
                case .startElement(let local, let attrStart, let attrEnd, let selfClosing):
                    if scanner.equalsASCII(local, "sst") {
                        scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                            if scanner.localEqualsASCII(name, "uniqueCount"),
                               let n = scanner.parseASCIIInt(val), n > 0 {
                                strings.reserveCapacity(min(n, 2_000_000))
                            }
                        }
                    } else if scanner.equalsASCII(local, "si") {
                        if selfClosing {
                            strings.append("")
                        } else {
                            inSI = true
                            current.removeAll(keepingCapacity: true)
                        }
                    } else if inSI {
                        if scanner.equalsASCII(local, "rPh") {
                            if !selfClosing { phoneticDepth += 1 }
                        } else if phoneticDepth == 0 && scanner.equalsASCII(local, "t") {
                            if !selfClosing { inT = true }
                        }
                    }
                case .endElement(let local):
                    if scanner.equalsASCII(local, "t") {
                        inT = false
                    } else if scanner.equalsASCII(local, "rPh") {
                        if phoneticDepth > 0 { phoneticDepth -= 1 }
                    } else if scanner.equalsASCII(local, "si") {
                        if inSI {
                            strings.append(current)
                            inSI = false
                        }
                    }
                case .text(let slice, let isCDATA):
                    if inSI && inT && phoneticDepth == 0 {
                        current.append(scanner.decodeString(slice, decodeEntities: !isCDATA))
                    }
                }
            }
        }

        return strings
    }

    // MARK: styles.xml

    private static func parseStylesXML(_ data: Data) -> StyleTable {
        var customFormats: [Int: String] = [:]
        var xfNumFmtIds: [Int] = []

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)
            var inCellXfs = false

            while let token = scanner.nextToken() {
                switch token {
                case .startElement(let local, let attrStart, let attrEnd, let selfClosing):
                    if scanner.equalsASCII(local, "numFmt") {
                        var id: Int?
                        var code = ""
                        scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                            if scanner.localEqualsASCII(name, "numFmtId") {
                                id = scanner.parseASCIIInt(val)
                            } else if scanner.localEqualsASCII(name, "formatCode") {
                                code = scanner.decodeString(val)
                            }
                        }
                        if let id {
                            customFormats[id] = code
                        }
                    } else if scanner.equalsASCII(local, "cellXfs") {
                        if !selfClosing { inCellXfs = true }
                    } else if inCellXfs && scanner.equalsASCII(local, "xf") {
                        var numFmtId = 0
                        scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                            if scanner.localEqualsASCII(name, "numFmtId"), let parsed = scanner.parseASCIIInt(val) {
                                numFmtId = parsed
                            }
                        }
                        xfNumFmtIds.append(numFmtId)
                    }
                case .endElement(let local):
                    if scanner.equalsASCII(local, "cellXfs") {
                        inCellXfs = false
                    }
                case .text:
                    break
                }
            }
        }

        let isDateFlags = xfNumFmtIds.map { isExcelDateFormat(numFmtId: $0, customFormats: customFormats) }
        return StyleTable(cellXfIsDate: isDateFlags)
    }

    static func isExcelDateFormat(numFmtId: Int, customFormats: [Int: String]) -> Bool {
        // Built-in Excel date & time format IDs (including CJK localized date IDs 27-36, 50-58).
        if (14...22).contains(numFmtId)
            || (45...47).contains(numFmtId)
            || (27...36).contains(numFmtId)
            || (50...58).contains(numFmtId) {
            return true
        }
        guard let rawCode = customFormats[numFmtId], !rawCode.isEmpty else { return false }
        return isDateFormatCode(rawCode)
    }

    private static func isDateFormatCode(_ formatCode: String) -> Bool {
        // Inspect the first (positive) section before any ';'.
        let bytes = Array(formatCode.utf8)
        let n = bytes.count
        var i = 0
        var inQuotes = false

        while i < n {
            let b = bytes[i]
            if inQuotes {
                if b == 0x22 { inQuotes = false } // '"'
                i += 1
                continue
            }
            if b == 0x3B { break } // ';' next format section
            if b == 0x22 { // '"'
                inQuotes = true
                i += 1
                continue
            }
            if b == 0x5C || b == 0x5F || b == 0x2A { // '\', '_', '*' escape next char
                i += 2
                continue
            }
            if b == 0x5B { // '[' locale/color or elapsed time [h]/[m]/[s]
                var close = i + 1
                while close < n && bytes[close] != 0x5D { close += 1 }
                if close < n {
                    // Check elapsed time tokens like [h], [hh], [m], [mm], [s], [ss]
                    let innerLen = close - (i + 1)
                    if innerLen == 1 || innerLen == 2 {
                        let c0 = bytes[i + 1] | 0x20
                        let allSame = (innerLen == 1) || ((bytes[i + 2] | 0x20) == c0)
                        if allSame && (c0 == 0x68 || c0 == 0x6D || c0 == 0x73) { // h, m, s
                            return true
                        }
                    }
                    i = close + 1
                    continue
                }
            }
            let lower = b | 0x20
            if lower == 0x79 || lower == 0x6D || lower == 0x64 || lower == 0x68 || lower == 0x73 {
                // y, m, d, h, s
                return true
            }
            i += 1
        }
        return false
    }

    // MARK: commentsN.xml

    private static func loadComments(forSheetAt sheetPath: String, in archive: XLSXZipArchive) throws -> [XLSXCellAddress: String] {
        let sheetRelsPath = relsPath(for: sheetPath)
        guard let relsData = try archive.readEntry(named: sheetRelsPath) else { return [:] }
        let rels = parseRelationshipsXML(relsData, basePartPath: sheetPath)
        guard let commentRel = rels.first(where: { $0.type.hasSuffix("/comments") }),
              let commentsData = try archive.readEntry(named: commentRel.targetPath) else {
            return [:]
        }
        return parseCommentsXML(commentsData)
    }

    private static func parseCommentsXML(_ data: Data) -> [XLSXCellAddress: String] {
        var result: [XLSXCellAddress: String] = [:]

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)
            var currentRef: (row: Int, col: Int)?
            var inText = false
            var inT = false
            var phoneticDepth = 0
            var buffer = ""

            while let token = scanner.nextToken() {
                switch token {
                case .startElement(let local, let attrStart, let attrEnd, let selfClosing):
                    if scanner.equalsASCII(local, "comment") {
                        currentRef = nil
                        buffer.removeAll(keepingCapacity: true)
                        scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                            if scanner.localEqualsASCII(name, "ref") {
                                currentRef = scanner.parseCellRef(val)
                            }
                        }
                    } else if currentRef != nil && scanner.equalsASCII(local, "text") {
                        if !selfClosing { inText = true }
                    } else if inText {
                        if scanner.equalsASCII(local, "rPh") {
                            if !selfClosing { phoneticDepth += 1 }
                        } else if phoneticDepth == 0 && scanner.equalsASCII(local, "t") {
                            if !selfClosing { inT = true }
                        }
                    }
                case .endElement(let local):
                    if scanner.equalsASCII(local, "t") {
                        inT = false
                    } else if scanner.equalsASCII(local, "rPh") {
                        if phoneticDepth > 0 { phoneticDepth -= 1 }
                    } else if scanner.equalsASCII(local, "text") {
                        inText = false
                    } else if scanner.equalsASCII(local, "comment") {
                        if let ref = currentRef, !buffer.isEmpty {
                            // Map Excel 0-based row -> viewer row (row 0 -> -1 header, row 1+ -> 0+ data).
                            result[XLSXCellAddress(row: ref.row - 1, col: ref.col)] = buffer
                        }
                        currentRef = nil
                        inText = false
                        inT = false
                    }
                case .text(let slice, let isCDATA):
                    if inText && inT && phoneticDepth == 0 {
                        buffer.append(scanner.decodeString(slice, decodeEntities: !isCDATA))
                    }
                }
            }
        }

        return result
    }

    // MARK: sheetN.xml

    private static func parseWorksheetXML(
        _ data: Data,
        name: String,
        sharedStrings: [String],
        styleTable: StyleTable,
        use1904DateSystem: Bool,
        comments: [XLSXCellAddress: String]
    ) -> XLSXSheet {
        var headerCells: [Int: String] = [:]
        var dataRows: [[(col: Int, value: String)]] = []
        var maxNonEmptyCol = -1

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var scanner = FastXMLScanner(base: base, count: raw.count)

            var inSheetData = false
            var inRow = false
            var rowValid = true
            var rowHasExplicitIndex = false
            var currentRowIndex = -1
            var nextCol = 0
            var currentRowCells: [(col: Int, value: String)] = []

            var inCell = false
            var cellValid = true
            var cellCol = 0
            var cellRow = 0
            var cellType: CellType = .number
            var cellStyle = 0

            var inV = false
            var inIS = false
            var inT = false
            var phoneticDepth = 0
            var valueBuf = ""

            @inline(__always)
            func commitCell() {
                guard cellValid, cellCol >= 0, cellCol < FastXMLScanner.maxColumns, !valueBuf.isEmpty else { return }
                let resolved: String
                switch cellType {
                case .sharedString:
                    if let idx = Int(valueBuf), idx >= 0, idx < sharedStrings.count {
                        resolved = sharedStrings[idx]
                    } else {
                        resolved = ""
                    }
                case .inlineString, .formulaString, .error, .isoDate:
                    resolved = valueBuf
                case .boolean:
                    resolved = (valueBuf == "1" || valueBuf == "true" || valueBuf == "TRUE") ? "true" : "false"
                case .number:
                    resolved = formatNumericValue(
                        valueBuf,
                        isDate: styleTable.isDateStyle(cellStyle),
                        use1904: use1904DateSystem
                    )
                }

                guard !resolved.isEmpty else { return }
                if cellCol > maxNonEmptyCol { maxNonEmptyCol = cellCol }
                if cellRow == 0 {
                    headerCells[cellCol] = resolved
                } else if cellRow > 0, cellRow < FastXMLScanner.maxRows {
                    currentRowCells.append((cellCol, resolved))
                }
            }

            scanLoop: while let token = scanner.nextToken() {
                switch token {
                case .startElement(let local, let attrStart, let attrEnd, let selfClosing):
                    if !inSheetData {
                        if scanner.equalsASCII(local, "sheetData") && !selfClosing {
                            inSheetData = true
                        }
                        continue
                    }

                    if !inRow {
                        if scanner.equalsASCII(local, "row") {
                            var explicitRow: Int?
                            var explicitInvalid = false
                            scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                                if scanner.localEqualsASCII(name, "r") {
                                    if let r = scanner.parseASCIIInt(val), r > 0, r <= FastXMLScanner.maxRows {
                                        explicitRow = r - 1
                                    } else {
                                        explicitInvalid = true
                                    }
                                }
                            }
                            if explicitInvalid {
                                rowValid = false
                                rowHasExplicitIndex = true
                            } else {
                                rowHasExplicitIndex = explicitRow != nil
                                currentRowIndex = explicitRow ?? (currentRowIndex + 1)
                                rowValid = currentRowIndex >= 0 && currentRowIndex < FastXMLScanner.maxRows
                            }
                            nextCol = 0
                            if !selfClosing {
                                inRow = true
                                currentRowCells.removeAll(keepingCapacity: true)
                            }
                        }
                        continue
                    }

                    if !inCell {
                        if scanner.equalsASCII(local, "c") {
                            cellRow = currentRowIndex
                            cellCol = nextCol
                            cellValid = rowValid && cellRow >= 0 && cellRow < FastXMLScanner.maxRows && cellCol < FastXMLScanner.maxColumns
                            cellType = .number
                            cellStyle = 0

                            scanner.forEachAttribute(start: attrStart, end: attrEnd) { name, val in
                                if scanner.localEqualsASCII(name, "r") {
                                    if let parsed = scanner.parseCellRef(val) {
                                        cellRow = parsed.row
                                        cellCol = parsed.col
                                        if !rowHasExplicitIndex {
                                            currentRowIndex = parsed.row
                                            rowValid = true
                                        }
                                        cellValid = rowValid
                                    } else {
                                        cellValid = false
                                    }
                                } else if scanner.localEqualsASCII(name, "t") {
                                    if scanner.equalsASCII(val, "s") { cellType = .sharedString }
                                    else if scanner.equalsASCII(val, "inlineStr") { cellType = .inlineString }
                                    else if scanner.equalsASCII(val, "b") { cellType = .boolean }
                                    else if scanner.equalsASCII(val, "str") { cellType = .formulaString }
                                    else if scanner.equalsASCII(val, "e") { cellType = .error }
                                    else if scanner.equalsASCII(val, "d") { cellType = .isoDate }
                                    else { cellType = .number }
                                } else if scanner.localEqualsASCII(name, "s") {
                                    if let s = scanner.parseASCIIInt(val) {
                                        cellStyle = s
                                    }
                                }
                            }
                            if cellValid {
                                nextCol = cellCol + 1
                            }
                            if !selfClosing {
                                inCell = true
                                inV = false
                                inIS = false
                                inT = false
                                phoneticDepth = 0
                                valueBuf.removeAll(keepingCapacity: true)
                            }
                        }
                        continue
                    }

                    // Inside <c>
                    if scanner.equalsASCII(local, "v") {
                        if !selfClosing { inV = true }
                    } else if scanner.equalsASCII(local, "is") {
                        if !selfClosing { inIS = true }
                    } else if inIS {
                        if scanner.equalsASCII(local, "rPh") {
                            if !selfClosing { phoneticDepth += 1 }
                        } else if phoneticDepth == 0 && scanner.equalsASCII(local, "t") {
                            if !selfClosing { inT = true }
                        }
                    }

                case .endElement(let local):
                    if !inSheetData { continue }
                    if inCell {
                        if scanner.equalsASCII(local, "v") {
                            inV = false
                        } else if scanner.equalsASCII(local, "t") {
                            inT = false
                        } else if scanner.equalsASCII(local, "rPh") {
                            if phoneticDepth > 0 { phoneticDepth -= 1 }
                        } else if scanner.equalsASCII(local, "is") {
                            inIS = false
                        } else if scanner.equalsASCII(local, "c") {
                            commitCell()
                            inCell = false
                            inV = false
                            inIS = false
                            inT = false
                        }
                    } else if inRow && scanner.equalsASCII(local, "row") {
                        if rowValid, currentRowIndex > 0, currentRowIndex < FastXMLScanner.maxRows, !currentRowCells.isEmpty {
                            let targetIndex = currentRowIndex - 1
                            // Pad skipped blank rows so data row indices stay aligned with Excel row numbers & comments.
                            if targetIndex > dataRows.count {
                                dataRows.append(contentsOf: repeatElement([], count: targetIndex - dataRows.count))
                            }
                            if targetIndex == dataRows.count {
                                dataRows.append(currentRowCells)
                            } else {
                                dataRows[targetIndex].append(contentsOf: currentRowCells)
                            }
                        }
                        inRow = false
                    } else if scanner.equalsASCII(local, "sheetData") {
                        inSheetData = false
                        // Stop early once </sheetData> closes; nothing after it contains cell values.
                        break scanLoop
                    }

                case .text(let slice, let isCDATA):
                    if inCell && (inV || (inIS && inT && phoneticDepth == 0)) {
                        valueBuf.append(scanner.decodeString(slice, decodeEntities: !isCDATA))
                    }
                }
            }
        }

        // Trim trailing completely-empty rows (Excel often writes blank styled rows at the tail).
        while let last = dataRows.last, last.isEmpty {
            dataRows.removeLast()
        }

        guard maxNonEmptyCol >= 0 else {
            return XLSXSheet(name: name, headers: [], rows: [], comments: comments)
        }

        let colCount = maxNonEmptyCol + 1
        var headers: [String] = []
        headers.reserveCapacity(colCount)
        for col in 0..<colCount {
            if let h = headerCells[col], !h.isEmpty {
                headers.append(h)
            } else {
                headers.append("Col \(col)")
            }
        }

        var rows: [[String]] = []
        rows.reserveCapacity(dataRows.count)
        let emptyRow = [String](repeating: "", count: colCount)
        for sparseRow in dataRows {
            if sparseRow.isEmpty {
                rows.append(emptyRow)
                continue
            }
            var row = emptyRow
            for (col, value) in sparseRow where col < colCount {
                row[col] = value
            }
            rows.append(row)
        }

        return XLSXSheet(name: name, headers: headers, rows: rows, comments: comments)
    }

    // MARK: Number & Date Formatting

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Excel's maximum valid date serial (exclusive, corresponds to 9999-12-31 in the 1900 date system).
    private static let maxExcelDateSerial: Double = 2_958_466.0

    static func formatNumericValue(_ raw: String, isDate: Bool, use1904: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let num = Double(trimmed) else { return raw }

        if isDate, num.isFinite, num >= 0, num < maxExcelDateSerial {
            return formatExcelDate(num, use1904: use1904)
        }

        guard num.isFinite else { return raw }

        // Exact integer within Int64 safe bounds (matches ExcelFileEditor.kt:470).
        if num == 0 { return "0" }
        if num >= -9_223_372_036_854_775_808.0,
           num < 9_223_372_036_854_775_808.0,
           num.rounded(.towardZero) == num {
            return String(Int64(num))
        }

        let direct = String(num)
        // Excel writes IEEE-754 doubles (17 digits) with binary rounding noise like `0.30000000000000004`.
        // Trim to Excel's 15 significant digits when the direct string exceeds 15 significant digits.
        if countSignificantDigits(direct) > 15 {
            return String(format: "%.15g", locale: posixLocale, num)
        }
        return direct
    }

    private static func countSignificantDigits(_ text: String) -> Int {
        var digits = 0
        var started = false
        for b in text.utf8 {
            if b == 0x65 || b == 0x45 { break } // 'e' or 'E'
            if b >= 0x30 && b <= 0x39 {
                if !started && b == 0x30 { continue }
                started = true
                digits += 1
            }
        }
        return digits
    }

    /// Converts an Excel serial date number into `yyyy-MM-dd`, `HH:mm:ss`, or `yyyy-MM-dd HH:mm:ss`
    /// using exact Gregorian civil-date math (supporting both 1900 and 1904 date systems).
    static func formatExcelDate(_ serial: Double, use1904: Bool) -> String {
        guard serial.isFinite, serial >= 0, serial < maxExcelDateSerial else {
            return String(serial)
        }
        var wholeDays = Int64(floor(serial))
        let fraction = serial - Double(wholeDays)
        var totalSeconds = Int((fraction * 86_400.0).rounded())

        if totalSeconds >= 86_400 {
            wholeDays += 1
            totalSeconds -= 86_400
        } else if totalSeconds < 0 {
            totalSeconds = 0
        }

        let hour = totalSeconds / 3600
        let minute = (totalSeconds % 3600) / 60
        let second = totalSeconds % 60

        // Time-only serial in 1900 system (0 <= serial < 1).
        if !use1904 && wholeDays == 0 {
            return formatTime(hour: hour, minute: minute, second: second)
        }

        // Days since Unix epoch (1970-01-01):
        // - 1904 system: 1904-01-01 is -24107 days from 1970-01-01.
        // - 1900 system: Excel treats 1900 as a leap year (serial 60 = fictitious 1900-02-29).
        //   * serial >= 60 -> base 1899-12-30 (-25569)
        //   * serial <  60 -> base 1899-12-31 (-25568)
        let daysSinceEpoch: Int64
        if use1904 {
            daysSinceEpoch = wholeDays - 24_107
        } else if wholeDays >= 60 {
            daysSinceEpoch = wholeDays - 25_569
        } else {
            daysSinceEpoch = wholeDays - 25_568
        }

        let (year, month, day) = civilDateFromDaysSinceEpoch(daysSinceEpoch)
        let dateStr = formatDate(year: year, month: month, day: day)
        if totalSeconds == 0 {
            return dateStr
        }
        return "\(dateStr) \(formatTime(hour: hour, minute: minute, second: second))"
    }

    /// Howard Hinnant's proleptic Gregorian algorithm (days since 1970-01-01 -> (year, month, day)).
    private static func civilDateFromDaysSinceEpoch(_ zInput: Int64) -> (Int, Int, Int) {
        let z = zInput + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let year = y + (m <= 2 ? 1 : 0)
        return (Int(year), Int(m), Int(d))
    }

    private static func formatDate(year: Int, month: Int, day: Int) -> String {
        "\(pad4(year))-\(pad2(month))-\(pad2(day))"
    }

    private static func formatTime(hour: Int, minute: Int, second: Int) -> String {
        "\(pad2(hour)):\(pad2(minute)):\(pad2(second))"
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func pad4(_ value: Int) -> String {
        if value < 10 { return "000\(value)" }
        if value < 100 { return "00\(value)" }
        if value < 1000 { return "0\(value)" }
        return "\(value)"
    }
}
