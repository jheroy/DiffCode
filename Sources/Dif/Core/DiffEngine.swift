import Foundation

/// One side of a comparison (or the whole of a plain file).
final class TextBuffer {
    private(set) var lines: [String]
    var spans: [[SyntaxSpan]] = []
    /// Base Lexer spans preserved separately once LSP semantic tokens are overlaid,
    /// so subsequent semantic refreshes re-merge cleanly without compounding.
    var baseSpans: [[SyntaxSpan]]?
    /// The lexer state at the start of each line and after the last, for buffers that can be edited:
    /// an edit then re-colours only the lines it affects.
    var states: [Highlighter.State]?
    /// Widest line, in approximate monospace columns. Drives the horizontal scroll extent.
    /// Grows as lines are edited wider; never shrinks until the file is read again.
    private(set) var maxColumns: Int

    /// Shared and never edited: a side that does not exist.
    nonisolated(unsafe) static let empty = TextBuffer(lines: [])

    init(lines: [String]) {
        self.lines = lines
        var widest = 0
        for line in lines where line.utf8.count * 4 > widest { // cannot beat the current maximum even if all tabs
            widest = max(widest, Self.columns(of: line))
        }
        maxColumns = widest
    }

    static func columns(of line: String) -> Int {
        var cols = 0
        for b in line.utf8 {
            if b == 9 { cols += 4 - cols % 4 } else if b & 0xC0 != 0x80 { cols += b >= 0xE0 ? 2 : 1 }
        }
        return cols
    }

    func spans(at line: Int) -> [SyntaxSpan] {
        line < spans.count ? spans[line] : []
    }

    /// Replaces text; see `TextEditing.replace`. Colours are the caller's to bring up to date.
    @discardableResult
    func replace(from: TextPosition, to: TextPosition, with text: String) -> (end: TextPosition, raw: LineEdit, change: LineEdit) {
        precondition(self !== TextBuffer.empty, "the shared empty buffer is never edited")
        let count = lines.count
        let result = TextEditing.replace(&lines, from: from, to: to, with: text)
        let raw = result.raw
        for row in raw.start..<(raw.start + raw.inserted) {
            maxColumns = max(maxColumns, Self.columns(of: lines[row]))
        }
        if count > 0, spans.count == count {
            spans.replaceSubrange(raw.start..<(raw.start + raw.removed), with: repeatElement([], count: raw.inserted))
        } else {
            spans = []
        }
        if count > 0, baseSpans?.count == count {
            baseSpans!.replaceSubrange(raw.start..<(raw.start + raw.removed), with: repeatElement([], count: raw.inserted))
        } else {
            baseSpans = nil
        }
        if count > 0, states?.count == count + 1 {
            // The states going into the first rewritten line, and into the line after them, are kept.
            states!.replaceSubrange((raw.start + 1)..<(raw.start + raw.removed),
                                    with: repeatElement(Highlighter.State(), count: raw.inserted - 1))
        } else {
            states = nil
        }
        return result
    }

    /// Merges per-line LSP semantic spans over the preserved base Lexer spans.
    /// Returns the 0-based line indices whose displayed spans changed.
    @discardableResult
    func applySemanticTokens(_ semanticByLine: [Int: [LSPSemanticSpan]]) -> IndexSet {
        guard !lines.isEmpty else { return IndexSet() }
        if baseSpans == nil || baseSpans?.count != lines.count {
            if spans.count == lines.count {
                baseSpans = spans
            } else {
                baseSpans = [[SyntaxSpan]](repeating: [], count: lines.count)
            }
        }
        if spans.count != lines.count {
            spans = baseSpans!
        }
        let base = baseSpans!
        var changed = IndexSet()
        for line in 0..<lines.count {
            let merged: [SyntaxSpan]
            if let sem = semanticByLine[line], !sem.isEmpty {
                merged = SyntaxOverlay.merge(base: base[line], semantic: sem)
            } else {
                merged = base[line]
            }
            if spans[line] != merged {
                spans[line] = merged
                changed.insert(line)
            }
        }
        return changed
    }
}

/// What it takes to edit the right side of a document and write it back.
struct EditInfo {
    var format = TextFormat()
    var crlf: [Bool]?
    /// Fingerprint of the bytes the right side was read from.
    var fingerprint = Data()
    /// The left side's bytes, to diff against as the text changes; nil when there is no left side.
    var base: Data?
    /// Why the right side stays read-only, when it does.
    var readOnlyReason: String?
}

struct Hunk: Equatable {
    enum Kind { case added, deleted, modified }

    var leftStart: Int
    var leftCount: Int
    var rightStart: Int
    var rightCount: Int
    /// Changed character ranges (UTF-16) per line of the hunk, for word-level highlighting.
    var leftInline: [[Range<Int>]] = []
    var rightInline: [[Range<Int>]] = []

    var kind: Kind {
        if leftCount == 0 { return .added }
        if rightCount == 0 { return .deleted }
        return .modified
    }
}

/// A run of lines that scrolls as a unit. Unchanged runs have equal counts on both sides;
/// a hunk occupies `max(leftCount, rightCount)` virtual lines so the shorter side scrolls
/// proportionally slower and the two panes stay aligned without padding.
struct Segment {
    var virtualStart: Int
    var leftStart: Int
    var leftCount: Int
    var rightStart: Int
    var rightCount: Int
    var hunk: Int // -1 for unchanged runs

    var span: Int { max(leftCount, rightCount) }
}

struct UnifiedRow {
    enum Kind: UInt8 { case context, removed, added }
    var kind: Kind
    var left: Int32   // -1 when absent
    var right: Int32
    var hunk: Int32
}

enum Side: Int { case left = 0, right = 1 }

final class DiffDocument {
    enum Content {
        case text
        case image(old: Data?, new: Data?)
        case message(title: String, detail: String)
    }

    let left: TextBuffer
    let right: TextBuffer
    private(set) var hunks: [Hunk]
    private(set) var segments: [Segment]
    private(set) var virtualLineCount: Int
    let language: LanguageSpec
    let content: Content
    /// True for a plain file view (no comparison).
    let isPlainFile: Bool
    var leftTitle = ""
    var rightTitle = ""
    var note: String?
    var loadMilliseconds: Double = 0
    /// Set when the right side is a file in the working tree: how to write it back, or why it cannot be.
    var editing: EditInfo?

    private var unifiedCache: [UnifiedRow]?
    var unifiedRows: [UnifiedRow] {
        if let cached = unifiedCache { return cached }
        let rows = buildUnifiedRows()
        unifiedCache = rows
        return rows
    }

    var additions: Int { hunks.reduce(0) { $0 + $1.rightCount } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.leftCount } }

    init(left: TextBuffer, right: TextBuffer, hunks: [Hunk], language: LanguageSpec,
         content: Content = .text, isPlainFile: Bool = false) {
        self.left = left
        self.right = right
        self.language = language
        self.content = content
        self.isPlainFile = isPlainFile
        (self.hunks, segments, virtualLineCount) = Self.layout(hunks, leftCount: left.lines.count, rightCount: right.lines.count)
    }

    /// New hunks for the same two sides, e.g. after the right side was edited (its buffer is shared, so it already has the new lines).
    func setHunks(_ hunks: [Hunk]) {
        (self.hunks, segments, virtualLineCount) = Self.layout(hunks, leftCount: left.lines.count, rightCount: right.lines.count)
        unifiedCache = nil
    }

    private static func layout(_ hunks: [Hunk], leftCount: Int, rightCount: Int) -> ([Hunk], [Segment], Int) {
        // Clamp defensively: the file may have changed between reading it and diffing it.
        var clean: [Hunk] = []
        var lpos = 0, rpos = 0
        for var h in hunks {
            h.leftStart = min(max(h.leftStart, lpos), leftCount)
            h.rightStart = min(max(h.rightStart, rpos), rightCount)
            h.leftCount = max(0, min(h.leftCount, leftCount - h.leftStart))
            h.rightCount = max(0, min(h.rightCount, rightCount - h.rightStart))
            if h.leftCount == 0 && h.rightCount == 0 { continue }
            clean.append(h)
            lpos = h.leftStart + h.leftCount
            rpos = h.rightStart + h.rightCount
        }

        var segs: [Segment] = []
        var v = 0
        lpos = 0; rpos = 0
        for (index, h) in clean.enumerated() {
            let gapL = h.leftStart - lpos, gapR = h.rightStart - rpos
            if gapL > 0 || gapR > 0 {
                segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: gapL, rightStart: rpos, rightCount: gapR, hunk: -1))
                v += max(gapL, gapR)
            }
            segs.append(Segment(virtualStart: v, leftStart: h.leftStart, leftCount: h.leftCount,
                                rightStart: h.rightStart, rightCount: h.rightCount, hunk: index))
            v += max(h.leftCount, h.rightCount)
            lpos = h.leftStart + h.leftCount
            rpos = h.rightStart + h.rightCount
        }
        let tailL = leftCount - lpos, tailR = rightCount - rpos
        if tailL > 0 || tailR > 0 {
            segs.append(Segment(virtualStart: v, leftStart: lpos, leftCount: tailL, rightStart: rpos, rightCount: tailR, hunk: -1))
            v += max(tailL, tailR)
        }
        return (clean, segs, v)
    }

    static func message(_ title: String, detail: String = "") -> DiffDocument {
        DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain, content: .message(title: title, detail: detail))
    }

    func buffer(_ side: Side) -> TextBuffer { side == .left ? left : right }

    // MARK: Scroll mapping

    private func segmentIndex(forVirtual v: Double) -> Int? {
        guard !segments.isEmpty else { return nil }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(segments[mid].virtualStart) <= v { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Fractional line positions on each side for a virtual line position.
    func panePositions(forVirtual v: Double) -> (left: Double, right: Double) {
        guard let idx = segmentIndex(forVirtual: v) else { return (0, 0) }
        let s = segments[idx]
        let span = Double(s.span)
        let t = span > 0 ? min(1, max(0, (v - Double(s.virtualStart)) / span)) : 0
        return (Double(s.leftStart) + t * Double(s.leftCount), Double(s.rightStart) + t * Double(s.rightCount))
    }

    /// The virtual line position at which `line` of `side` sits.
    func virtualPosition(of line: Int, side: Side) -> Double {
        guard !segments.isEmpty else { return 0 }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = side == .left ? segments[mid].leftStart : segments[mid].rightStart
            if start <= line { lo = mid } else { hi = mid - 1 }
        }
        let s = segments[lo]
        let start = side == .left ? s.leftStart : s.rightStart
        let count = side == .left ? s.leftCount : s.rightCount
        guard count > 0 else { return Double(s.virtualStart) }
        let t = min(1, Double(line - start) / Double(count))
        return Double(s.virtualStart) + t * Double(s.span)
    }

    func virtualStart(ofHunk index: Int) -> Int {
        segments.first(where: { $0.hunk == index })?.virtualStart ?? 0
    }

    private func buildUnifiedRows() -> [UnifiedRow] {
        var rows: [UnifiedRow] = []
        rows.reserveCapacity(virtualLineCount + hunks.count * 4)
        for s in segments {
            if s.hunk < 0 {
                for k in 0..<min(s.leftCount, s.rightCount) {
                    rows.append(UnifiedRow(kind: .context, left: Int32(s.leftStart + k), right: Int32(s.rightStart + k), hunk: -1))
                }
                // Only an empty file's one blank line has no partner on the left; it still needs a row to type on.
                for k in s.leftCount..<max(s.leftCount, s.rightCount) {
                    rows.append(UnifiedRow(kind: .context, left: -1, right: Int32(s.rightStart + k), hunk: -1))
                }
            } else {
                for k in 0..<s.leftCount {
                    rows.append(UnifiedRow(kind: .removed, left: Int32(s.leftStart + k), right: -1, hunk: Int32(s.hunk)))
                }
                for k in 0..<s.rightCount {
                    rows.append(UnifiedRow(kind: .added, left: -1, right: Int32(s.rightStart + k), hunk: Int32(s.hunk)))
                }
            }
        }
        return rows
    }

    /// First unified row belonging to a hunk.
    func unifiedRow(ofHunk index: Int) -> Int {
        unifiedRows.firstIndex(where: { $0.hunk == Int32(index) }) ?? 0
    }

    func unifiedRow(ofLine line: Int, side: Side) -> Int {
        let target = Int32(line)
        // Rows are sorted by line on each side, so a linear scan from an estimate is unnecessary; just search.
        var lo = 0, hi = unifiedRows.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            var probe = mid
            // Skip rows that have no line on the requested side.
            while probe <= hi, (side == .left ? unifiedRows[probe].left : unifiedRows[probe].right) < 0 { probe += 1 }
            if probe > hi { hi = mid - 1; continue }
            let value = side == .left ? unifiedRows[probe].left : unifiedRows[probe].right
            if value == target { return probe }
            if value < target { best = probe; lo = probe + 1 } else { hi = mid - 1 }
        }
        return best
    }
}

// MARK: - Hunk parsing

enum DiffParser {
    /// Extracts hunks from unified diff output produced with `-U0`.
    static func parseHunks(_ data: Data) -> (hunks: [Hunk], binary: Bool) {
        var hunks: [Hunk] = []
        var binary = false
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let buf = raw.bindMemory(to: UInt8.self)
            let n = buf.count
            var i = 0
            while i < n {
                var end = i
                while end < n, buf[end] != 0x0A { end += 1 }
                if end - i > 4, buf[i] == 0x40, buf[i + 1] == 0x40, buf[i + 2] == 0x20, buf[i + 3] == 0x2D { // "@@ -"
                    var p = i + 4
                    func number() -> Int {
                        var value = 0
                        while p < end, buf[p] >= 48, buf[p] <= 57 { value = value * 10 + Int(buf[p] - 48); p += 1 }
                        return value
                    }
                    let a = number()
                    var b = 1
                    if p < end, buf[p] == 0x2C { p += 1; b = number() }
                    while p < end, buf[p] != 0x2B { p += 1 } // '+'
                    p += 1
                    let c = number()
                    var d = 1
                    if p < end, buf[p] == 0x2C { p += 1; d = number() }
                    // With zero lines on a side, git reports the line *after which* the change sits.
                    hunks.append(Hunk(leftStart: b == 0 ? a : a - 1, leftCount: b,
                                      rightStart: d == 0 ? c : c - 1, rightCount: d))
                } else if end - i > 12, buf[i] == 0x42, buf[i + 1] == 0x69, buf[i + 2] == 0x6E, buf[i + 3] == 0x61 { // "Bina"
                    binary = true
                }
                i = end + 1
            }
        }
        return (hunks, binary)
    }
}

// MARK: - Word-level diff

enum InlineDiff {
    private struct Token {
        var line: Int32
        var start: Int32
        var length: Int32
        var hash: UInt64
        var isSpace: Bool
    }

    static let maxTokens = 3000

    private static func tokenize(_ lines: ArraySlice<String>) -> [Token]? {
        var tokens: [Token] = []
        for (lineIndex, line) in lines.enumerated() {
            if lineIndex > 0 {
                tokens.append(Token(line: Int32(lineIndex - 1), start: -1, length: 0, hash: 0x9E3779B97F4A7C15, isSpace: true))
            }
            var start = 0
            var hash: UInt64 = 0xcbf29ce484222325
            var cls = -1 // 0 word, 1 space
            var i = 0
            func flush(_ end: Int) {
                if cls >= 0, end > start {
                    tokens.append(Token(line: Int32(lineIndex), start: Int32(start), length: Int32(end - start),
                                        hash: hash ^ UInt64(end - start), isSpace: cls == 1))
                }
                cls = -1
                hash = 0xcbf29ce484222325
            }
            for unit in line.utf16 {
                let c: Int
                if unit == 32 || unit == 9 {
                    c = 1
                } else if (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122) || unit == 95
                            || (unit >= 0x80 && unit < 0x2E80) || (unit >= 0xDC00 && unit <= 0xDFFF) {
                    c = 0
                } else {
                    c = 2 // punctuation and CJK: one token per unit
                }
                if c == 2 {
                    flush(i)
                    // A high surrogate starts a pair; let the low surrogate (class 0) join it.
                    start = i
                    hash = (0xcbf29ce484222325 ^ UInt64(unit)) &* 0x100000001b3
                    if unit >= 0xD800 && unit <= 0xDBFF {
                        cls = 0
                    } else {
                        cls = 0
                        flush(i + 1)
                    }
                } else {
                    if c != cls { flush(i); start = i; cls = c }
                    hash = (hash ^ UInt64(unit)) &* 0x100000001b3
                }
                i += 1
            }
            flush(i)
            if tokens.count > maxTokens { return nil }
        }
        return tokens
    }

    /// Returns per-line changed ranges for both sides of a modified hunk, or nil when the
    /// two sides share nothing worth aligning (whole-line colouring says enough).
    static func compute(old: ArraySlice<String>, new: ArraySlice<String>) -> (old: [[Range<Int>]], new: [[Range<Int>]])? {
        guard let a = tokenize(old), let b = tokenize(new), !a.isEmpty, !b.isEmpty else { return nil }
        guard let (matchedA, matchedB) = Myers.matches(a.map(\.hash), b.map(\.hash), maxEdits: 600) else { return nil }

        var common = 0
        for (i, t) in a.enumerated() where matchedA[i] && !t.isSpace { common += 1 }
        if common == 0 { return nil }

        func ranges(_ tokens: [Token], _ matched: [Bool], lineCount: Int) -> [[Range<Int>]] {
            var result = [[Range<Int>]](repeating: [], count: lineCount)
            // Extent of each line's visible text, to spot lines that changed from end to end.
            var extents = [Range<Int>?](repeating: nil, count: lineCount)
            var open: (line: Int, start: Int, end: Int)?
            func close() {
                if let o = open { result[o.line].append(o.start..<o.end) }
                open = nil
            }
            for (i, t) in tokens.enumerated() {
                if t.start < 0 { close(); continue } // line break
                // Whitespace never starts or ends a range (re-indented code would otherwise light up
                // as solid blocks), but a space between two changed words is bridged so they merge.
                if t.isSpace { continue }
                let line = Int(t.line)
                let tokenEnd = Int(t.start + t.length)
                extents[line] = (extents[line]?.lowerBound ?? Int(t.start))..<tokenEnd
                if !matched[i] {
                    let end = Int(t.start + t.length)
                    if let o = open, o.line == line {
                        open = (line, o.start, end)
                    } else {
                        close()
                        open = (line, Int(t.start), end)
                    }
                } else {
                    close()
                }
            }
            close()
            // A line that differs in its entirety gains nothing from a second, darker highlight
            // on top of its band; keeping those lines plain makes the partial edits stand out.
            for line in 0..<lineCount where result[line].count == 1 && result[line][0] == extents[line] {
                result[line] = []
            }
            return result
        }
        return (ranges(a, matchedA, lineCount: old.count), ranges(b, matchedB, lineCount: new.count))
    }
}

/// Myers' O(ND) diff, used for word-level alignment inside a hunk.
enum Myers {
    /// Flags which elements of `a` and `b` belong to the longest common subsequence.
    /// Returns nil when more than `maxEdits` edits would be needed.
    static func matches<T: Equatable>(_ a: [T], _ b: [T], maxEdits: Int) -> (a: [Bool], b: [Bool])? {
        var matchedA = [Bool](repeating: false, count: a.count)
        var matchedB = [Bool](repeating: false, count: b.count)

        // Trim the common prefix and suffix; real edits are usually a small middle.
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] {
            matchedA[prefix] = true; matchedB[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
            matchedA[a.count - 1 - suffix] = true; matchedB[b.count - 1 - suffix] = true
            suffix += 1
        }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        if n == 0 || m == 0 { return (matchedA, matchedB) }

        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var solvedAt = -1

        outer: for d in 0...limit {
            trace.append(v)
            var k = -d
            while k <= d {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[offset + k] = x
                if x >= n, y >= m { solvedAt = d; break outer }
                k += 2
            }
        }
        guard solvedAt >= 0 else { return nil }

        var x = n, y = m
        var d = solvedAt
        while d >= 0 {
            let snapshot = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && snapshot[offset + k - 1] < snapshot[offset + k + 1]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = d == 0 ? 0 : snapshot[offset + prevK]
            let prevY = d == 0 ? 0 : prevX - prevK
            while x > prevX, y > prevY {
                x -= 1; y -= 1
                matchedA[prefix + x] = true
                matchedB[prefix + y] = true
            }
            x = prevX; y = prevY
            d -= 1
        }
        return (matchedA, matchedB)
    }
}

// MARK: - Loading

struct DiffRequest: Equatable {
    enum Source: Equatable {
        /// `base` (normally HEAD) against the working tree.
        case worktree(base: String)
        /// A commit against its first parent (nil parent means a root commit).
        case commit(hash: String, parent: String?)
        /// A plain file from the working tree, no comparison.
        case file
        /// An external read-only file opened via LSP navigation (sibling `go.work` repo, `$GOROOT`, `pkg/mod`…).
        case externalFile(displayPath: String, workspaceRoot: URL?)
    }

    var root: URL
    var path: String
    var oldPath: String?
    var kind: FileChange.Kind?
    var source: Source
    var ignoreWhitespace = false

    /// A local change as the Changes list has it: the working tree against HEAD, not against another commit.
    var isAgainstHead: Bool {
        if case .worktree(let base) = source { return base == "HEAD" || base == Git.emptyTree }
        return false
    }

    var isExternalFile: Bool {
        if case .externalFile = source { return true }
        return false
    }

    var fileURL: URL {
        root.appendingPathComponent(path)
    }

    /// True when the right side represents a live file on disk eligible for LSP semantic highlighting & navigation.
    var isLiveFile: Bool {
        switch source {
        case .file, .externalFile: return true
        case .worktree: return kind != .deleted
        case .commit: return false
        }
    }

    /// Repository or workspace root passed to `LSPManager` for workspace/go.work discovery.
    var lspRepoRoot: URL? {
        switch source {
        case .externalFile(_, let workspaceRoot): return workspaceRoot
        case .file, .worktree: return root
        case .commit: return nil
        }
    }

    /// Path shown in the viewer header (`<repo>/<relPath>` or `~/...` for external files).
    var displayPath: String {
        if case .externalFile(let display, _) = source { return display }
        return path
    }
}

enum DiffLoader {
    static let maxTextBytes = 12 * 1024 * 1024
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "heic", "ico", "icns", "pdf"]

    private static let scratch: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dif-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// A directory of this process's own, removed when the app quits.
    static var scratchDirectory: URL { scratch }

    static func cleanup() {
        try? FileManager.default.removeItem(at: scratch)
    }

    static func load(_ request: DiffRequest) async -> DiffDocument {
        let started = DispatchTime.now()
        let doc = await build(request)
        doc.loadMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        return doc
    }

    private static func readWorktree(_ root: URL, _ path: String) -> Data? {
        let url = root.appendingPathComponent(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func build(_ request: DiffRequest) async -> DiffDocument {
        let root = request.root
        let language = LanguageSpec.detect(path: request.path)
        let ext = (request.path as NSString).pathExtension.lowercased()

        var oldData: Data?
        var newData: Data?
        var leftTitle = "", rightTitle = ""

        switch request.source {
        case .file, .externalFile:
            newData = readWorktree(root, request.path)
            guard let data = newData else {
                return .message(L("File not found", "文件不存在"), detail: request.displayPath)
            }
            if imageExtensions.contains(ext) {
                return DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain,
                                    content: .image(old: nil, new: data), isPlainFile: true)
            }
            if TextCodec.looksBinary(data) {
                return .message(L("Binary file", "二进制文件"), detail: data.count.byteSizeString)
            }
            if data.count > maxTextBytes {
                return .message(L("File too large to display", "文件过大，无法显示"), detail: data.count.byteSizeString)
            }
            if request.isExternalFile {
                let buffer = await makeBuffer(data, language)
                let doc = DiffDocument(left: .empty, right: buffer, hunks: [], language: language, isPlainFile: true)
                doc.editing = EditInfo(readOnlyReason: L("Read-only", "只读"))
                return doc
            }
            let (buffer, editing) = await makeWorktreeSide(data, language, url: root.appendingPathComponent(request.path), base: nil)
            let doc = DiffDocument(left: .empty, right: buffer, hunks: [], language: language, isPlainFile: true)
            doc.editing = editing
            return doc

        case .worktree(let base):
            let hasOld = request.kind != .added && request.kind != .untracked
            let hasNew = request.kind != .deleted
            async let old: Data? = hasOld ? Git.blob(rev: base, path: request.oldPath ?? request.path, in: root) : nil
            if hasNew { newData = readWorktree(root, request.path) }
            oldData = await old
            // A commit compared with is named by its short hash, as in a commit's own diff.
            switch base {
            case Git.emptyTree: leftTitle = L("Empty", "空")
            case ConflictBase.base.rev: leftTitle = L("Base (common ancestor)", "共同祖先")
            case ConflictBase.incoming.rev: leftTitle = L("Incoming", "传入的版本")
            default: leftTitle = base.count == 40 && base.allSatisfy(\.isHexDigit) ? String(base.prefix(7)) : base
            }
            rightTitle = request.kind == .conflicted ? L("Result (Working Tree)", "合并结果（工作区）") : L("Working Tree", "工作区")

        case .commit(let hash, let parent):
            let hasOld = request.kind != .added && parent != nil
            let hasNew = request.kind != .deleted
            async let old: Data? = hasOld ? Git.blob(rev: parent ?? "", path: request.oldPath ?? request.path, in: root) : nil
            async let new: Data? = hasNew ? Git.blob(rev: hash, path: request.path, in: root) : nil
            oldData = await old
            newData = await new
            leftTitle = parent.map { String($0.prefix(7)) } ?? L("Empty", "空")
            rightTitle = String(hash.prefix(7))
        }

        func finish(_ doc: DiffDocument) -> DiffDocument {
            doc.leftTitle = leftTitle
            doc.rightTitle = rightTitle
            return doc
        }

        if oldData == nil && newData == nil {
            return finish(.message(L("Nothing to show", "没有可显示的内容"),
                                   detail: L("The file does not exist on either side.", "文件在两侧都不存在。")))
        }
        if imageExtensions.contains(ext) {
            return finish(DiffDocument(left: .empty, right: .empty, hunks: [], language: .plain,
                                       content: .image(old: oldData, new: newData)))
        }
        if (oldData.map(TextCodec.looksBinary) ?? false) || (newData.map(TextCodec.looksBinary) ?? false) {
            let sizes = [oldData?.count.byteSizeString, newData?.count.byteSizeString].compactMap { $0 }.joined(separator: " → ")
            return finish(.message(L("Binary file changed", "二进制文件有变化"), detail: sizes))
        }
        if max(oldData?.count ?? 0, newData?.count ?? 0) > maxTextBytes {
            return finish(.message(L("File too large to diff", "文件过大，无法比较"),
                                   detail: max(oldData?.count ?? 0, newData?.count ?? 0).byteSizeString))
        }

        // Decode and highlight both sides in parallel. The working tree side is read so that it can be edited.
        let (oldBytes, newBytes) = (oldData, newData)
        var worktreeURL: URL?
        if case .worktree = request.source, newBytes != nil { worktreeURL = root.appendingPathComponent(request.path) }
        let url = worktreeURL
        async let leftBuffer: TextBuffer = makeBuffer(oldBytes, language)
        async let rightSide: (TextBuffer, EditInfo?) = makeRightSide(newBytes, language, worktree: url, base: oldBytes)
        async let rawHunks: [Hunk]? = computeHunks(old: oldBytes, new: newBytes, ignoreWhitespace: request.ignoreWhitespace)
        let left = await leftBuffer
        let (right, editing) = await rightSide

        var hunks: [Hunk]
        if oldData == nil {
            // A new file: every line is added. An empty one has nothing to show, though it has a line to type on.
            hunks = (newData?.isEmpty ?? true) ? [] : [Hunk(leftStart: 0, leftCount: 0, rightStart: 0, rightCount: right.lines.count)]
            _ = await rawHunks
        } else if newData == nil {
            hunks = left.lines.isEmpty ? [] : [Hunk(leftStart: 0, leftCount: left.lines.count, rightStart: 0, rightCount: 0)]
            _ = await rawHunks
        } else if let computed = await rawHunks {
            hunks = computed
        } else {
            return finish(.message(L("Could not compute diff", "无法计算差异"), detail: request.path))
        }
        addInlineHighlights(&hunks, left: left.lines, right: right.lines)

        let doc = DiffDocument(left: left, right: right, hunks: hunks, language: language)
        doc.editing = editing
        doc.note = note(hunks: hunks, old: oldData, new: newData, ignoreWhitespace: request.ignoreWhitespace)
        return finish(doc)
    }

    /// Word-level highlights for the changed lines of each modified hunk (left alone above 200 lines a side).
    static func addInlineHighlights(_ hunks: inout [Hunk], left: [String], right: [String]) {
        for index in hunks.indices where hunks[index].kind == .modified {
            let h = hunks[index]
            guard h.leftCount <= 200, h.rightCount <= 200,
                  h.leftStart + h.leftCount <= left.count, h.rightStart + h.rightCount <= right.count,
                  let inline = InlineDiff.compute(old: left[h.leftStart..<(h.leftStart + h.leftCount)],
                                                  new: right[h.rightStart..<(h.rightStart + h.rightCount)]) else { continue }
            hunks[index].leftInline = inline.old
            hunks[index].rightInline = inline.new
        }
    }

    /// Said over a diff with no differences in it, when both sides exist. The lines can be the same while the bytes
    /// are not: line endings git converts (`core.autocrlf`), or the same text in another encoding.
    static func note(hunks: [Hunk], old: Data?, new: Data?, ignoreWhitespace: Bool) -> String? {
        guard hunks.isEmpty, let old, let new else { return nil }
        if old == new { return L("Contents are identical", "内容完全相同") }
        return ignoreWhitespace ? L("Only whitespace differs", "仅空白字符不同")
                                : L("Only line endings or encoding differ", "仅换行符或编码不同")
    }

    private static func makeRightSide(_ data: Data?, _ language: LanguageSpec, worktree url: URL?, base: Data?) async -> (TextBuffer, EditInfo?) {
        if let data, let url { return await makeWorktreeSide(data, language, url: url, base: base) }
        return (await makeBuffer(data, language), nil)
    }

    /// The working tree side of a document: decoded so that it can be written back where that is possible,
    /// and highlighted keeping the lexer states that editing needs. Otherwise read as any other side, with the reason.
    private static func makeWorktreeSide(_ data: Data, _ language: LanguageSpec, url: URL, base: Data?) async -> (TextBuffer, EditInfo?) {
        var info = EditInfo()
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        if type == .typeSymbolicLink {
            info.readOnlyReason = L("A symbolic link · read-only", "符号链接 · 只读")
        } else if !FileManager.default.isWritableFile(atPath: url.path) {
            // Read-only permissions, or locked in the Finder.
            info.readOnlyReason = L("No permission to write it · read-only", "没有写入权限 · 只读")
        } else if data.count > TextEditing.maxEditableBytes {
            info.readOnlyReason = L("Larger than 4 MB · read-only", "文件超过 4 MB · 只读")
        } else if let text = TextCodec.decodeForEditing(data) {
            if text.lines.contains(where: { $0.utf8.count > TextEditing.maxLineBytes }) {
                info.readOnlyReason = L("Has lines too long to edit · read-only", "有过长的行 · 只读")
            } else {
                info.format = text.format
                info.crlf = text.crlf
                info.fingerprint = TextCodec.fingerprint(data)
                info.base = base
                let buffer = TextBuffer(lines: text.lines)
                let colours = Highlighter.highlightTracking(text.lines, language: language)
                buffer.spans = colours.spans
                buffer.states = colours.states
                return (buffer, info)
            }
        } else {
            info.readOnlyReason = L("Its encoding cannot be written back exactly · read-only", "编码无法原样写回 · 只读")
        }
        return (await makeBuffer(data, language), info)
    }

    private static func makeBuffer(_ data: Data?, _ language: LanguageSpec) async -> TextBuffer {
        guard let data else { return .empty }
        let buffer = TextBuffer(lines: TextCodec.splitLines(TextCodec.decode(data)))
        if data.count <= 4 * 1024 * 1024 {
            buffer.spans = Highlighter.highlight(buffer.lines, language: language)
        }
        return buffer
    }

    /// Line-level hunks via `git diff --no-index` on the exact bytes being displayed, so the
    /// hunks always agree with the text on screen regardless of filters, renames or repo state.
    /// Nil when git could not compare them.
    /// - Parameter environment: added to git's (tests give it settings of their own).
    static func computeHunks(old: Data?, new: Data?, ignoreWhitespace: Bool,
                             environment: [String: String] = [:]) async -> [Hunk]? {
        guard var old, var new else { return [] }
        if old == new { return [] }
        // Git takes UTF-16 for binary (it is full of zero bytes). As UTF-8 the lines are the same lines.
        if HunkPatch.isUTF16(old) || HunkPatch.isUTF16(new) {
            old = Data(TextCodec.decode(old).utf8)
            new = Data(TextCodec.decode(new).utf8)
            if old == new { return [] }
        }
        let id = UUID().uuidString
        let a = scratch.appendingPathComponent("\(id).a"), b = scratch.appendingPathComponent("\(id).b")
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try old.write(to: a)
            try new.write(to: b)
        } catch {
            return nil
        }
        // DiffCode shows these files as text. The user's own gitattributes still apply to them: without `--text` a
        // rule such as `*.a binary` (in common templates) has git call them binary, and a textconv driver would compare
        // something else than what is shown.
        var args = ["diff", "--no-index", "--no-color", "--no-ext-diff", "--no-textconv", "--text", "-U0",
                    "--diff-algorithm=histogram"]
        if ignoreWhitespace { args.append("-w") }
        args += [a.lastPathComponent, b.lastPathComponent]
        guard let output = try? await Git.run(args, in: scratch, okStatuses: [0, 1], environment: environment) else { return nil }
        let parsed = DiffParser.parseHunks(output)
        // Files git did not compare line by line are not files without differences.
        return parsed.binary ? nil : parsed.hunks
    }
}
