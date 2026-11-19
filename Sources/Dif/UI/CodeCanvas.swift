import AppKit
import CoreText
import QuartzCore

struct TextPosition: Comparable {
    var row: Int
    var column: Int // UTF-16 offset within the row's text

    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.row != b.row ? a.row < b.row : a.column < b.column
    }
}

struct TextSelection: Equatable {
    var pane: Side
    var anchor: TextPosition
    var head: TextPosition

    var lower: TextPosition { min(anchor, head) }
    var upper: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

struct SearchMatch: Equatable {
    var side: Side
    var line: Int
    var range: Range<Int>
}

/// What of a local change goes into the next commit, for the ticks on its changes.
struct CommitTicks: Equatable {
    /// The file is ticked in the Changes list.
    var included: Bool
    /// Lines of HEAD's side, and of the working tree's, that stay out of the commit.
    var removed: Set<Int> = []
    var added: Set<Int> = []

    func isExcluded(_ side: Side, _ line: Int) -> Bool {
        !included || (side == .left ? removed : added).contains(line)
    }
}

@MainActor
protocol CodeCanvasDelegate: AnyObject {
    func canvasDidRequestExit(_ canvas: CodeCanvasView)
    func canvasContextMenu(_ canvas: CodeCanvasView) -> NSMenu?
    func canvasDidMagnify(_ canvas: CodeCanvasView, by delta: CGFloat)
    /// The button on change `index` was clicked: put it back the way the left side has it.
    func canvas(_ canvas: CodeCanvasView, revertHunk index: Int)
    /// A conflict's button was clicked: keep HEAD's lines, the incoming ones, or both.
    func canvas(_ canvas: CodeCanvasView, resolveConflict index: Int, choice: ConflictChoice)
    /// The commit tick of change `index` was clicked.
    func canvas(_ canvas: CodeCanvasView, toggleCommitHunk index: Int)
    /// The text was changed here: typed, pasted, undone… (not while an input method is still composing).
    func canvasDidEdit(_ canvas: CodeCanvasView)
    /// The pointer moved onto (or off, with nil) the Annotate label of a line; `anchor` is where the line's label
    /// ends, in the canvas's coordinates.
    func canvas(_ canvas: CodeCanvasView, hoverAnnotation entry: LineAnnotations.Entry?, anchor: CGPoint)
    /// The Annotate label of a line was clicked.
    func canvas(_ canvas: CodeCanvasView, openAnnotation entry: LineAnnotations.Entry)
    /// ⌘+Click on a symbol in an LSP-enabled pane (`line` is 0-based buffer line, `character` is 0-based UTF-16 offset).
    func canvas(_ canvas: CodeCanvasView, goToDefinitionAt line: Int, character: Int)
}

// MARK: - Layers

/// A layer that never animates implicitly: everything on the canvas is positioned by hand.
private class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

private final class StillShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// A strip of rasterised glyphs. It is drawn exactly once; after that the compositor only moves it.
private final class TileLayer: CALayer {
    enum Kind { case gutter, text }

    weak var canvas: CodeCanvasView?
    var kind = Kind.text
    var pane = Side.right
    var index = 0
    var column = 0

    override init() { super.init() }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let other = layer as? TileLayer else { return }
        canvas = other.canvas
        kind = other.kind
        pane = other.pane
        index = other.index
        column = other.column
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? { nil }
    override func draw(in ctx: CGContext) {
        // Tiles draw synchronously (no drawsAsynchronously) when the main thread commits the layer tree.
        nonisolated(unsafe) let tile = self, context = ctx
        MainActor.assumeIsolated { tile.canvas?.drawTile(tile, in: context) }
    }
}

private struct TileKey: Hashable {
    var index: Int
    var column: Int
}

/// A reusable set of solid rectangles (change bands, word highlights, selection…).
/// Plain colour layers cost the compositor nothing to keep around and nothing to scroll.
private final class RectGroup {
    private let host: CALayer
    private let z: CGFloat
    private var layers: [CALayer] = []

    init(host: CALayer, z: CGFloat) {
        self.host = host
        self.z = z
    }

    func set(_ rects: [CGRect], color: CGColor, radius: CGFloat = 0) {
        for (i, rect) in rects.enumerated() {
            let layer: CALayer
            if i < layers.count {
                layer = layers[i]
            } else {
                layer = StillLayer()
                layer.zPosition = z
                host.addSublayer(layer)
                layers.append(layer)
            }
            layer.frame = rect
            layer.backgroundColor = color
            layer.cornerRadius = radius > 0 ? min(radius, rect.width / 2) : 0
        }
        if layers.count > rects.count {
            for layer in layers[rects.count...] { layer.removeFromSuperlayer() }
            layers.removeSubrange(rects.count...)
        }
    }

    func clear() {
        guard !layers.isEmpty else { return }
        layers.forEach { $0.removeFromSuperlayer() }
        layers.removeAll()
    }
}

/// The layers of one pane. `band` spans the pane including its gutter and scrolls vertically;
/// `text` covers only the text area and scrolls both ways.
private final class Pane {
    let side: Side
    let band = StillLayer()
    let text = StillLayer()
    let focus = StillLayer()
    let lines: [RectGroup]
    /// Pales the bands of lines that stay out of the commit.
    let excluded: RectGroup
    let marks: [RectGroup]
    let words: [RectGroup]
    let hits: RectGroup
    let currentHit: RectGroup
    let selection: RectGroup

    var gutterTiles: [Int: TileLayer] = [:]
    var textTiles: [TileKey: TileLayer] = [:]
    /// Width of the widest line in each row of tiles, so a tile is only as wide as its text.
    var contentWidths: [Int: CGFloat] = [:]
    /// Rows the rectangle groups currently describe.
    var decorRows: Range<Int> = 0..<0

    init(side: Side) {
        self.side = side
        let band = self.band, text = self.text
        lines = (0..<3).map { _ in RectGroup(host: band, z: 0) }
        excluded = RectGroup(host: band, z: 0.5)
        marks = (0..<3).map { _ in RectGroup(host: band, z: 1) }
        words = (0..<3).map { _ in RectGroup(host: text, z: 0) }
        hits = RectGroup(host: text, z: 1)
        currentHit = RectGroup(host: text, z: 2)
        selection = RectGroup(host: text, z: 3)
        for layer in [band, text] {
            layer.anchorPoint = .zero
            layer.masksToBounds = true
        }
        focus.zPosition = 2
        focus.isHidden = true
        band.addSublayer(focus)
    }

    func dropTextTiles() {
        textTiles.values.forEach { $0.removeFromSuperlayer() }
        textTiles.removeAll()
    }

    func dropGutterTiles() {
        gutterTiles.values.forEach { $0.removeFromSuperlayer() }
        gutterTiles.removeAll()
    }

    func dropTiles() {
        dropTextTiles()
        dropGutterTiles()
        contentWidths.removeAll()
        decorRows = 0..<0
    }

    func clearDecor() {
        (lines + marks + words + [excluded, hits, currentHit, selection]).forEach { $0.clear() }
        focus.isHidden = true
        decorRows = 0..<0
    }
}

// MARK: - Canvas

/// Shows a diff (side-by-side or unified) or a plain file.
///
/// Nothing here redraws while scrolling. Text is rasterised once into small tiles (eight rows
/// each, only as wide as their longest line) and the GPU compositor moves them; change bands,
/// word highlights, search hits and the selection are plain colour layers underneath the
/// glyphs, and the connectors are shape layers. A scroll step therefore costs a few layer
/// moves plus rasterising whatever rows just came into view, and memory stays proportional to
/// the viewport rather than to how often it is repainted.
///
/// Scrolling physics come from a transparent NSScrollView on top (see `CodeScrollContainer`);
/// this view only reads the offset. In side-by-side mode the panes are not padded to equal
/// height — each pane's offset is derived from one virtual scroll position, which is what
/// makes the IntelliJ-style curved connectors possible.
final class CodeCanvasView: NSView {
    enum Mode { case sideBySide, unified, single }

    private struct Dirty: OptionSet {
        let rawValue: Int
        static let scroll = Dirty(rawValue: 1)
        static let selection = Dirty(rawValue: 2)
        /// Bands, word highlights, search hits, focus markers.
        static let decor = Dirty(rawValue: 4)
        static let geometry = Dirty(rawValue: 8)
        /// Rasterised text is stale (document, font, theme or display scale changed).
        static let tiles = Dirty(rawValue: 16)
        static let everything: Dirty = [.scroll, .selection, .decor, .geometry, .tiles]
    }

    private(set) var document: DiffDocument?
    private var requestedMode: Mode = .sideBySide
    weak var delegate: CodeCanvasDelegate?
    weak var container: CodeScrollContainer?

    var codeFont = CodeFont(size: 12) {
        didSet {
            guard codeFont != oldValue else { return }
            invalidateTextCaches()
            container?.updateDocumentSize()
            invalidate(.everything)
        }
    }

    private(set) var theme: CanvasTheme = .dark
    private var activeStyles: [TokenStyle] = CanvasTheme.dark.syntax

    var scrollOrigin: CGPoint = .zero {
        didSet {
            guard scrollOrigin != oldValue else { return }
            invalidate(.scroll)
            // A line's details describe the line that was under the pointer, which has just moved away.
            if hoveredAnnotationLine != nil { setHoveredAnnotation(nil) }
            if lspHover != nil { clearLSPHover() }
        }
    }

    var selection: TextSelection? {
        didSet { if selection != oldValue { invalidate(.selection) } }
    }

    var focusedHunk: Int? {
        didSet { if focusedHunk != oldValue { invalidate(.decor) } }
    }

    /// A line to tint, e.g. the target of "go to line" or a search hit.
    var focusLine: (side: Side, line: Int)? {
        didSet { invalidate(.decor) }
    }

    /// Gives every change a small button that puts it back the way the left side has it.
    var showsRevertButtons = false {
        didSet { if showsRevertButtons != oldValue { invalidate(.decor) } }
    }
    /// The change that was under the pointer when the context menu was last asked for.
    private(set) var contextHunk: Int?
    /// The eligible LSP symbol that was under the pointer when the context menu was last asked for.
    private(set) var contextLSPSymbol: LSPHoverTarget?

    /// Gives every change a tick for the next commit, and pales the lines that stay out of it.
    var commitTicks: CommitTicks? {
        didSet {
            guard commitTicks != oldValue else { return }
            tickStateCache = nil
            invalidate(.decor)
        }
    }
    private var tickLayers: [StillLayer] = []
    private var tickHits: [(rect: CGRect, hunk: Int)] = []
    private var tickGlyphs: [String: CGImage] = [:]
    private var tickStateCache: [Inclusion]?
    private var hoveredTick: Int? {
        didSet { if hoveredTick != oldValue { invalidate(.scroll) } }
    }
    private var pressedTick: Int?

    /// Conflicts git left in the right side's text (a file being merged), each given buttons that resolve it.
    var conflicts: [ConflictBlock] = [] {
        didSet { if conflicts != oldValue { invalidate(.decor) } }
    }
    private var conflictLayers: [StillLayer] = []
    private var conflictHits: [(rect: CGRect, block: Int, choice: ConflictChoice)] = []
    private var conflictGlyphs: [String: CGImage] = [:]
    private var hoveredConflict: (block: Int, choice: ConflictChoice)? {
        didSet { if hoveredConflict?.block != oldValue?.block || hoveredConflict?.choice != oldValue?.choice { invalidate(.scroll) } }
    }
    private var pressedConflict: (block: Int, choice: ConflictChoice)?

    /// Who last changed each line of the right side, in a column before its line numbers (Annotate).
    var annotations: LineAnnotations? {
        didSet {
            guard annotations != oldValue else { return }
            annotationLabels.removeAll()
            if hoveredAnnotationLine != nil { setHoveredAnnotation(nil) }
            // Only the right pane's gutter shows them; the text moves over when the column's width changes.
            panes[1].dropGutterTiles()
            if annotations?.columns != oldValue?.columns {
                container?.updateDocumentSize()
                invalidate([.geometry, .scroll, .decor, .selection])
            } else {
                invalidate(.scroll)
            }
        }
    }
    private var annotationLabels: [Int32: CTLine] = [:]
    private var hoveredAnnotationLine: Int?
    /// Counts edits of the right side, so that work started before one can tell it is out of date.
    private(set) var editCount = 0

    private(set) var matches: [SearchMatch] = []
    private(set) var currentMatch = -1
    private var matchesByLine: [[Int: [Range<Int>]]] = [[:], [:]]

    /// Cost of the most recent layer update, including any tiles it had to rasterise.
    private(set) var lastUpdateMilliseconds: Double = 0
    /// Tiles rasterised since launch; lets the benchmark tell moves from repaints.
    private(set) var tilesRasterised = 0

    // Layout constants.
    let rulerWidth: CGFloat = 12
    let connectorWidth: CGFloat = 44
    let textInset: CGFloat = 10
    var bottomPadding: CGFloat { codeFont.lineHeight * 3 }

    private static let tileRows = 8
    /// Rows beyond the viewport that overlays are prepared for, so they are rebuilt only now and then.
    private static let overscan = 24
    private static let kinds: [Hunk.Kind] = [.modified, .added, .deleted]
    private static let removedMark = NSColor(hex: 0xE5534B).cgColor

    private var lineCacheNew: [Int: CTLine] = [:]
    private var lineCacheOld: [Int: CTLine] = [:]
    private var lineCacheCost = 0
    private var numberCache: [Int: CTLine] = [:]
    private var signLines: [CTLine] = []
    /// Virtual row at which each hunk starts, in the current mode.
    private var hunkRows: [Int] = []
    private var draggingRuler = false
    private var dragSelecting = false

    private let root = StillLayer()
    private let panes = [Pane(side: .left), Pane(side: .right)]
    private let connector = StillLayer()
    private var ribbons: [StillShapeLayer] = []
    private let ruler = StillLayer()
    private let rulerThumb = StillLayer()
    private var rulerMarks: [StillShapeLayer] = []
    private var revertLayers: [StillLayer] = []
    /// Where the visible revert buttons are, for clicks and hovering.
    private var revertHits: [(rect: CGRect, hunk: Int)] = []
    private var revertGlyphs: [String: CGImage] = [:]
    private var hoveredRevert: Int? {
        didSet { if hoveredRevert != oldValue { invalidate(.scroll) } }
    }
    private var pressedRevert: Int?
    private var tileWidth: CGFloat = 512
    private var dirty: Dirty = .everything

    /// Set while the right side can be edited: the canvas then has a caret there and takes typing.
    var editor: EditorSession? {
        didSet {
            goalX = nil
            invalidate(.selection)
        }
    }
    /// Where vertical caret moves try to stay, so passing a short line does not pull the caret left for good.
    var goalX: CGFloat?
    /// The last whole line copied with no selection, so pasting it can go in as a line, as in the IDE.
    var lineClipboard: String?
    /// Where cut, copy and paste go: the clipboard (tests swap in a pasteboard of their own).
    var pasteboard = NSPasteboard.general
    private let caretLayer = StillLayer()
    private var compositionUnderline: RectGroup!
    private var caretFrame: CGRect = .null

    /// An eligible symbol currently underlined under ⌘+Hover (or right-clicked) on the right/live pane.
    struct LSPHoverTarget: Equatable {
        var row: Int
        var line: Int
        var column: Int
        var range: Range<Int>

        /// 0-based UTF-16 column offset on `line`.
        var utf16Column: Int { column }
    }

    /// True while the right pane shows a live LSP-backed workspace file (never HEAD left pane, commits, or App Store).
    var isLSPEnabled = false {
        didSet {
            if !isLSPEnabled {
                clearLSPHover()
                contextLSPSymbol = nil
            }
        }
    }
    private(set) var lspHover: LSPHoverTarget?
    private var lspHoverUnderline: RectGroup!
    private var lastMousePoint: CGPoint?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.anchorPoint = .zero
        root.isOpaque = true
        root.masksToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        for pane in panes { root.addSublayer(pane.band) }
        for pane in panes { root.addSublayer(pane.text) }

        connector.anchorPoint = .zero
        connector.masksToBounds = true
        for _ in 0..<3 {
            let ribbon = StillShapeLayer()
            ribbon.strokeColor = nil
            connector.addSublayer(ribbon)
            ribbons.append(ribbon)
        }
        root.addSublayer(connector)

        ruler.anchorPoint = .zero
        rulerThumb.cornerRadius = 3
        ruler.addSublayer(rulerThumb)
        for _ in 0..<3 {
            let mark = StillShapeLayer()
            mark.strokeColor = nil
            ruler.addSublayer(mark)
            rulerMarks.append(mark)
        }
        root.addSublayer(ruler)

        // Above the glyphs (z 5), so it shows on top of the text it sits in.
        caretLayer.zPosition = 6
        caretLayer.isHidden = true
        panes[1].text.addSublayer(caretLayer)
        compositionUnderline = RectGroup(host: panes[1].text, z: 7)
        lspHoverUnderline = RectGroup(host: panes[1].text, z: 7)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func updateLayer() { apply() }

    private func invalidate(_ what: Dirty) {
        dirty.formUnion(what)
        needsDisplay = true
    }

    /// Brings the layers up to date immediately instead of at the next display pass.
    func flush() { apply() }

    // MARK: Configuration

    var mode: Mode {
        guard let doc = document else { return .single }
        return doc.isPlainFile ? .single : requestedMode
    }

    func setDocument(_ doc: DiffDocument?, mode: Mode) {
        document = doc
        activeStyles = theme.styles(for: doc?.language)
        editor = nil
        annotations = nil
        requestedMode = mode
        selection = nil
        focusedHunk = nil
        focusLine = nil
        matches = []
        matchesByLine = [[:], [:]]
        currentMatch = -1
        clearLSPHover()
        contextLSPSymbol = nil
        invalidateTextCaches()
        rebuildHunkRows()
        invalidate(.everything)
    }

    func setMode(_ mode: Mode) {
        guard mode != requestedMode else { return }
        // The caret stays on its line; rows mean different things in the two layouts.
        let caret = editSelection
        requestedMode = mode
        selection = nil
        clearLSPHover()
        rebuildHunkRows()
        if let caret { selection = TextSelection(pane: .right, anchor: rowPosition(caret.anchor), head: rowPosition(caret.head)) }
        invalidate(.everything)
    }

    /// Invalidates cached CoreText lines and text tiles for the changed 0-based buffer lines on `side`
    /// without touching scroll offset, selection, or caret.
    func invalidateSyntax(side: Side, lines changedLines: IndexSet) {
        guard let doc = document, case .text = doc.content, !changedLines.isEmpty else { return }
        for key in Array(lineCacheNew.keys) where (key & 1) == side.rawValue && changedLines.contains(key >> 1) {
            lineCacheNew.removeValue(forKey: key)
        }
        for key in Array(lineCacheOld.keys) where (key & 1) == side.rawValue && changedLines.contains(key >> 1) {
            lineCacheOld.removeValue(forKey: key)
        }

        let tileRows = Self.tileRows
        switch mode {
        case .sideBySide:
            let pane = panes[side.rawValue]
            let tiles = Set(changedLines.map { $0 / tileRows })
            for (key, tile) in pane.textTiles where tiles.contains(key.index) {
                tile.removeFromSuperlayer()
                pane.textTiles.removeValue(forKey: key)
            }
            for index in tiles { pane.contentWidths.removeValue(forKey: index) }
        case .single:
            guard side == .right else { return }
            let pane = panes[1]
            let tiles = Set(changedLines.map { $0 / tileRows })
            for (key, tile) in pane.textTiles where tiles.contains(key.index) {
                tile.removeFromSuperlayer()
                pane.textTiles.removeValue(forKey: key)
            }
            for index in tiles { pane.contentWidths.removeValue(forKey: index) }
        case .unified:
            let pane = panes[1]
            let rows = doc.unifiedRows
            var tiles = Set<Int>()
            for key in pane.textTiles.keys {
                let first = key.index * tileRows
                let last = min(rows.count, first + tileRows)
                guard first < last else { continue }
                for r in first..<last {
                    let row = rows[r]
                    let line = side == .left ? (row.kind == .removed ? Int(row.left) : -1)
                                             : (row.kind == .removed ? -1 : Int(row.right))
                    if line >= 0, changedLines.contains(line) {
                        tiles.insert(key.index)
                        break
                    }
                }
            }
            for (key, tile) in pane.textTiles where tiles.contains(key.index) {
                tile.removeFromSuperlayer()
                pane.textTiles.removeValue(forKey: key)
            }
            for index in tiles { pane.contentWidths.removeValue(forKey: index) }
        }
        invalidate(.scroll)
    }

    func setCurrentMatch(_ index: Int) {
        currentMatch = index
        invalidate(.decor)
    }

    /// All occurrences on a side, including ones that are not navigation stops.
    func setHighlightedRanges(_ bySide: [[Int: [Range<Int>]]], navigation: [SearchMatch], current: Int) {
        matches = navigation
        currentMatch = current
        matchesByLine = bySide
        invalidate(.decor)
    }

    private func invalidateTextCaches() {
        lineCacheNew.removeAll()
        lineCacheOld.removeAll()
        lineCacheCost = 0
        numberCache.removeAll()
        signLines.removeAll()
        annotationLabels.removeAll()
        cachedParagraphStyle = nil
    }

    private func rebuildHunkRows() {
        tickStateCache = nil
        guard let doc = document else { hunkRows = []; return }
        switch mode {
        case .sideBySide:
            var rows = [Int](repeating: 0, count: doc.hunks.count)
            for s in doc.segments where s.hunk >= 0 { rows[s.hunk] = s.virtualStart }
            hunkRows = rows
        case .unified:
            var rows = [Int](repeating: 0, count: doc.hunks.count)
            var seen = -1
            for (index, row) in doc.unifiedRows.enumerated() where row.hunk > Int32(seen) {
                seen = Int(row.hunk)
                rows[seen] = index
            }
            hunkRows = rows
        case .single:
            hunkRows = []
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != theme.isDark else { return }
        theme = dark ? .dark : .light
        activeStyles = theme.styles(for: document?.language)
        if let hover = lspHover { setLSPHover(hover) }
        invalidateTextCaches()
        invalidate(.everything)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        invalidate(.everything)
        // The caret shows only while the window has the keyboard.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func keyWindowChanged() {
        clearLSPHover()
        invalidate(.selection)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        invalidate(.everything)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { invalidate([.geometry, .scroll]) }
    }

    // MARK: Geometry

    var rowCount: Int {
        guard let doc = document, case .text = doc.content else { return 0 }
        switch mode {
        case .sideBySide: return doc.virtualLineCount
        case .unified: return doc.unifiedRows.count
        case .single: return doc.right.lines.count
        }
    }

    func hunkRow(_ index: Int) -> Int {
        index >= 0 && index < hunkRows.count ? hunkRows[index] : 0
    }

    /// Row (in the current mode's scroll space) that shows `line` of `side`.
    func row(forLine line: Int, side: Side) -> Int {
        guard let doc = document else { return 0 }
        switch mode {
        case .sideBySide: return Int(doc.virtualPosition(of: line, side: side))
        case .unified: return doc.unifiedRow(ofLine: line, side: side)
        case .single: return line
        }
    }

    private func digits(_ n: Int) -> Int { max(3, String(max(1, n)).count) }

    /// Whole points, so every layer below it lands on a pixel boundary.
    private var gutterWidth: CGFloat {
        guard let doc = document else { return 40 }
        return (CGFloat(digits(max(doc.left.lines.count, doc.right.lines.count))) * codeFont.charWidth).rounded(.up) + 20
    }

    private var paneWidth: CGFloat { floor((bounds.width - rulerWidth - connectorWidth) / 2) }

    private func textRect(_ pane: Side) -> CGRect {
        let h = bounds.height, g = gutterWidth, a = annotationWidth
        switch mode {
        case .sideBySide:
            let half = paneWidth
            if pane == .left { return CGRect(x: 0, y: 0, width: max(0, half - g), height: h) }
            let x = half + connectorWidth + a + g
            return CGRect(x: x, y: 0, width: max(0, bounds.width - rulerWidth - x), height: h)
        case .unified:
            let x = a + unifiedGutterWidth
            return CGRect(x: x, y: 0, width: max(0, bounds.width - rulerWidth - x), height: h)
        case .single:
            return CGRect(x: a + g, y: 0, width: max(0, bounds.width - rulerWidth - a - g), height: h)
        }
    }

    private func bandRect(_ pane: Side) -> CGRect {
        let h = bounds.height
        guard mode == .sideBySide else { return CGRect(x: 0, y: 0, width: max(0, bounds.width - rulerWidth), height: h) }
        let half = paneWidth
        if pane == .left { return CGRect(x: 0, y: 0, width: half, height: h) }
        return CGRect(x: half + connectorWidth, y: 0, width: max(0, bounds.width - rulerWidth - half - connectorWidth), height: h)
    }

    /// Position and width of a pane's gutter, relative to its band.
    private func gutterSpan(_ pane: Side) -> (x: CGFloat, width: CGFloat) {
        switch mode {
        case .sideBySide: return pane == .left ? (paneWidth - gutterWidth, gutterWidth) : (0, annotationWidth + gutterWidth)
        case .unified: return (0, annotationWidth + unifiedGutterWidth)
        case .single: return (0, annotationWidth + gutterWidth)
        }
    }

    /// Width of the Annotate column (date and author, in the code font) at the start of the right pane's gutter.
    private var annotationWidth: CGFloat {
        guard let annotations, document != nil else { return 0 }
        return (CGFloat(annotations.columns) * codeFont.charWidth).rounded(.up) + 16
    }

    /// Where the Annotate column starts, in the canvas's coordinates.
    private var annotationX: CGFloat { mode == .sideBySide ? paneWidth + connectorWidth : 0 }

    private var unifiedNumberWidth: CGFloat { gutterWidth - 6 }
    private var unifiedGutterWidth: CGFloat { unifiedNumberWidth * 2 + 18 }

    /// Size of the scrollable space for the current document.
    func documentSize(viewport: CGSize) -> CGSize {
        guard let doc = document, case .text = doc.content else { return viewport }
        let lh = codeFont.lineHeight
        let height = CGFloat(rowCount) * lh + bottomPadding
        let columns: Int
        let available: CGFloat
        switch mode {
        case .sideBySide:
            columns = max(doc.left.maxColumns, doc.right.maxColumns)
            available = min(textRect(.left).width, textRect(.right).width)
        case .unified:
            columns = max(doc.left.maxColumns, doc.right.maxColumns)
            available = textRect(.right).width
        case .single:
            columns = doc.right.maxColumns
            available = textRect(.right).width
        }
        let contentWidth = CGFloat(min(columns, 4000)) * codeFont.charWidth + textInset + 48
        return CGSize(width: viewport.width + max(0, contentWidth - available), height: max(height, viewport.height))
    }

    private struct Scroll {
        var left: CGFloat   // content y shown at the top of the left pane
        var right: CGFloat
        var x: CGFloat
        var y: CGFloat      // clamped virtual scroll offset
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func pixelRound(_ v: CGFloat) -> CGFloat {
        let scale = backingScale
        return (v * scale).rounded() / scale
    }

    /// Resolves the scroll offset into per-pane offsets.
    ///
    /// Side-by-side: an anchor line slides from the top of the viewport (at the start of the
    /// file) to the bottom (at the end). Both panes are positioned so the lines corresponding to
    /// the anchor's virtual position sit at the anchor, which keeps unchanged code level across
    /// the divider while each pane still starts and ends flush.
    private func resolveScroll() -> Scroll {
        let h = bounds.height
        let lh = codeFont.lineHeight
        let pad = bottomPadding
        let maxScroll = max(0, CGFloat(rowCount) * lh + pad - h)
        let y = min(max(scrollOrigin.y, 0), maxScroll)
        let overscroll = pixelRound(scrollOrigin.y - y)
        let maxX = max(0, (container?.documentWidth ?? bounds.width) - bounds.width)
        let x = pixelRound(min(max(scrollOrigin.x, 0), maxX))

        guard mode == .sideBySide, let doc = document else {
            let top = pixelRound(y) + overscroll
            return Scroll(left: top, right: top, x: x, y: y)
        }
        let k = maxScroll > 0 ? y / maxScroll : 0
        let anchor = k * max(0, h - pad)
        let positions = doc.panePositions(forVirtual: Double((y + anchor) / lh))
        func top(_ position: Double, _ count: Int) -> CGFloat {
            let limit = max(0, CGFloat(count) * lh + pad - h)
            return pixelRound(min(max(CGFloat(position) * lh - anchor, 0), limit)) + overscroll
        }
        return Scroll(left: top(positions.left, doc.left.lines.count),
                      right: top(positions.right, doc.right.lines.count), x: x, y: y)
    }

    /// Maps a row in a pane to the buffer line it displays.
    private func source(pane: Side, row: Int) -> (side: Side, line: Int)? {
        guard let doc = document, row >= 0 else { return nil }
        switch mode {
        case .sideBySide:
            return row < doc.buffer(pane).lines.count ? (pane, row) : nil
        case .unified:
            guard row < doc.unifiedRows.count else { return nil }
            let r = doc.unifiedRows[row]
            return r.kind == .removed ? (.left, Int(r.left)) : (.right, Int(r.right))
        case .single:
            return row < doc.right.lines.count ? (.right, row) : nil
        }
    }

    private func paneRowCount(_ pane: Side) -> Int {
        guard let doc = document else { return 0 }
        switch mode {
        case .sideBySide: return doc.buffer(pane).lines.count
        case .unified: return doc.unifiedRows.count
        case .single: return doc.right.lines.count
        }
    }

    private func visibleRows(top: CGFloat, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lh = codeFont.lineHeight
        let first = min(count - 1, max(0, Int(floor(top / lh))))
        let last = min(count - 1, max(first, Int(floor((top + bounds.height) / lh))))
        return first...last
    }

    /// Index of the first hunk that ends at or after `line` on `side`.
    private func firstHunk(_ doc: DiffDocument, side: Side, endingAtOrAfter line: Int) -> Int {
        var lo = 0, hi = doc.hunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let h = doc.hunks[mid]
            let end = side == .left ? h.leftStart + h.leftCount : h.rightStart + h.rightCount
            if end < line { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func kindIndex(_ kind: Hunk.Kind) -> Int {
        switch kind {
        case .modified: return 0
        case .added: return 1
        case .deleted: return 2
        }
    }

    // MARK: Text

    private static let maxDisplayBytes = 6000

    private func ctLine(_ side: Side, _ index: Int) -> CTLine {
        let key = index << 1 | side.rawValue
        if let line = lineCacheNew[key] { return line }
        if let line = lineCacheOld[key] {
            lineCacheNew[key] = line
            return line
        }
        let line = makeLine(side, index)
        // Two generations: when the young one fills, the old one is dropped. Lines still in use
        // get promoted on their next lookup. The budget is in characters as well as lines,
        // because a laid-out line costs memory in proportion to its length.
        let cost = CTLineGetStringRange(line).length + 16
        if lineCacheNew.count >= 320 || lineCacheCost + cost > 48_000 {
            lineCacheOld = lineCacheNew
            lineCacheNew.removeAll(keepingCapacity: true)
            lineCacheCost = 0
        }
        lineCacheNew[key] = line
        lineCacheCost += cost
        return line
    }

    private var cachedParagraphStyle: NSParagraphStyle?

    /// Tab stops every four columns; CoreText honours these when laying out a line.
    private var paragraphStyle: NSParagraphStyle {
        if let style = cachedParagraphStyle { return style }
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = codeFont.charWidth * 4
        cachedParagraphStyle = style
        return style
    }

    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)

    private func makeLine(_ side: Side, _ index: Int) -> CTLine {
        guard let doc = document, index >= 0, index < doc.buffer(side).lines.count else {
            return CTLineCreateWithAttributedString(NSAttributedString())
        }
        let buffer = doc.buffer(side)
        var text = buffer.lines[index]
        if text.utf8.count > Self.maxDisplayBytes {
            text = String(text.prefix(Self.maxDisplayBytes / 2)) + " …"
        }
        let styles = activeStyles
        let defaultColor = styles.first?.color ?? theme.text
        let attributed = NSMutableAttributedString(string: text, attributes: [
            Self.fontKey: codeFont.regularFont,
            Self.colorKey: defaultColor,
            .paragraphStyle: paragraphStyle,
            .ligature: codeFont.ligatures ? 1 : 0,
        ])
        let length = attributed.length
        for span in buffer.spans(at: index) where span.kind != .plain {
            let start = Int(span.start)
            let count = min(Int(span.length), length - start)
            guard start < length, count > 0 else { continue }
            let kindIndex = Int(span.kind.rawValue)
            let style = kindIndex < styles.count ? styles[kindIndex] : TokenStyle(defaultColor)
            let range = NSRange(location: start, length: count)
            attributed.addAttribute(Self.colorKey, value: style.color, range: range)
            if style.bold || style.italic {
                attributed.addAttribute(Self.fontKey, value: codeFont.ctFont(bold: style.bold, italic: style.italic), range: range)
            }
        }
        return CTLineCreateWithAttributedString(attributed)
    }

    private func numberLine(_ number: Int) -> CTLine {
        if let line = numberCache[number] { return line }
        if numberCache.count > 1500 { numberCache.removeAll(keepingCapacity: true) }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: [
            .font: codeFont.font, Self.colorKey: theme.gutterText,
        ]))
        numberCache[number] = line
        return line
    }

    private func signLine(added: Bool) -> CTLine {
        if signLines.isEmpty {
            signLines = [
                CTLineCreateWithAttributedString(NSAttributedString(string: "+", attributes: [
                    .font: codeFont.font, Self.colorKey: theme.addedMark])),
                CTLineCreateWithAttributedString(NSAttributedString(string: "−", attributes: [
                    .font: codeFont.font, Self.colorKey: Self.removedMark])),
            ]
        }
        return signLines[added ? 0 : 1]
    }

    // MARK: Tiles

    private func drawNumber(_ ctx: CGContext, _ number: Int, rightEdge: CGFloat, y: CGFloat) {
        let line = numberLine(number)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: rightEdge - width, y: y + codeFont.baseline)
        CTLineDraw(line, ctx)
    }

    /// Rasterises one tile. Only glyphs go in here; everything coloured behind them is a layer.
    fileprivate func drawTile(_ tile: TileLayer, in ctx: CGContext) {
        guard let doc = document else { return }
        tilesRasterised += 1
        if !tile.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: tile.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let lh = codeFont.lineHeight
        let firstRow = tile.index * Self.tileRows
        let lastRow = min(paneRowCount(tile.pane), firstRow + Self.tileRows) - 1
        guard firstRow <= lastRow else { return }

        switch tile.kind {
        case .text:
            let x = textInset - CGFloat(tile.column) * tileWidth
            for row in firstRow...lastRow {
                guard let src = source(pane: tile.pane, row: row) else { continue }
                ctx.textPosition = CGPoint(x: x, y: CGFloat(row - firstRow) * lh + codeFont.baseline)
                CTLineDraw(ctLine(src.side, src.line), ctx)
            }
        case .gutter:
            // The Annotate column comes first in the right pane's gutter.
            let shift = tile.pane == .right ? annotationWidth : 0
            if shift > 0, let annotations { drawAnnotations(annotations, in: ctx, rows: firstRow...lastRow) }
            if mode == .unified {
                let numberWidth = unifiedNumberWidth
                for row in firstRow...lastRow {
                    let r = doc.unifiedRows[row]
                    let y = CGFloat(row - firstRow) * lh
                    if r.left >= 0 { drawNumber(ctx, Int(r.left) + 1, rightEdge: shift + numberWidth - 4, y: y) }
                    if r.right >= 0 { drawNumber(ctx, Int(r.right) + 1, rightEdge: shift + numberWidth * 2 - 4, y: y) }
                    if r.kind != .context {
                        ctx.textPosition = CGPoint(x: shift + numberWidth * 2 + 4, y: y + codeFont.baseline)
                        CTLineDraw(signLine(added: r.kind == .added), ctx)
                    }
                }
            } else {
                // Line numbers hug the divider on both sides, as in IntelliJ.
                let rightEdge = shift + gutterWidth - 10
                for row in firstRow...lastRow {
                    drawNumber(ctx, row + 1, rightEdge: rightEdge, y: CGFloat(row - firstRow) * lh)
                }
            }
        }
    }

    // MARK: Annotate

    /// The line of the right side that a row of the right pane shows, if it shows one.
    private func rightLine(row: Int) -> Int? {
        guard let doc = document, row >= 0 else { return nil }
        switch mode {
        case .sideBySide, .single:
            return row < doc.right.lines.count ? row : nil
        case .unified:
            guard row < doc.unifiedRows.count else { return nil }
            let line = doc.unifiedRows[row].right
            return line >= 0 ? Int(line) : nil
        }
    }

    /// A bar by every line that has a commit, darker the newer the commit, and the date and author on the first line
    /// of each run of lines from one commit.
    private func drawAnnotations(_ annotations: LineAnnotations, in ctx: CGContext, rows: ClosedRange<Int>) {
        let lh = codeFont.lineHeight
        for row in rows {
            guard let line = rightLine(row: row), let index = annotations.index(atLine: line) else { continue }
            let entry = annotations.entries[Int(index)]
            let y = CGFloat(row - rows.lowerBound) * lh
            let first = annotations.isRunStart(line)
            ctx.setFillColor(theme.accent.copy(alpha: 0.18 + 0.72 * CGFloat(entry.recency)) ?? theme.accent)
            // A hairline gap where one commit's lines end and the next one's begin.
            ctx.fill(CGRect(x: 4, y: y + (first ? 1 : 0), width: 3, height: lh - (first ? 1 : 0)))
            if first {
                ctx.textPosition = CGPoint(x: 12, y: y + codeFont.baseline)
                CTLineDraw(annotationLabel(index, entry), ctx)
            }
        }
    }

    private func annotationLabel(_ index: Int32, _ entry: LineAnnotations.Entry) -> CTLine {
        if let line = annotationLabels[index] { return line }
        let colour = entry.recency >= 0.75 ? theme.gutterTextStrong : theme.gutterText
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: entry.label, attributes: [
            .font: codeFont.font, Self.colorKey: colour, .ligature: 0,
        ]))
        annotationLabels[index] = line
        return line
    }

    #if DEBUG || DIF_HOOKS
    /// The middle of a line's Annotate label, in the canvas's coordinates (for the debug hooks).
    func annotationPoint(line: Int) -> CGPoint? {
        guard annotationWidth > 0, annotations?.index(atLine: line) != nil else { return nil }
        let row = mode == .unified ? editRow(forLine: line) : line
        let y = (CGFloat(row) + 0.5) * codeFont.lineHeight - resolveScroll().right
        guard y > 0, y < bounds.height else { return nil }
        return CGPoint(x: annotationX + annotationWidth / 2, y: y)
    }
    #endif

    /// The line whose Annotate label is under `point`, if there is one with a commit.
    private func annotatedLine(at point: CGPoint) -> Int? {
        let width = annotationWidth
        guard width > 0, let annotations, point.x >= annotationX, point.x < annotationX + width else { return nil }
        let row = Int(floor((point.y + resolveScroll().right) / codeFont.lineHeight))
        guard let line = rightLine(row: row), annotations.index(atLine: line) != nil else { return nil }
        return line
    }

    private func setHoveredAnnotation(_ line: Int?) {
        hoveredAnnotationLine = line
        guard let line, let entry = annotations?.entry(atLine: line) else {
            delegate?.canvas(self, hoverAnnotation: nil, anchor: .zero)
            return
        }
        let lh = codeFont.lineHeight
        let row = mode == .unified ? editRow(forLine: line) : line
        let anchor = CGPoint(x: annotationX + annotationWidth, y: CGFloat(row) * lh - resolveScroll().right)
        delegate?.canvas(self, hoverAnnotation: entry, anchor: anchor)
    }

    private func makeTile(_ kind: TileLayer.Kind, pane: Pane, index: Int, column: Int, frame: CGRect) -> TileLayer {
        let tile = TileLayer()
        tile.canvas = self
        tile.kind = kind
        tile.pane = pane.side
        tile.index = index
        tile.column = column
        tile.anchorPoint = .zero
        tile.position = frame.origin
        tile.bounds = CGRect(origin: .zero, size: frame.size)
        tile.contentsScale = backingScale
        tile.contentsFormat = .RGBA8Uint
        tile.zPosition = 5
        (kind == .gutter ? pane.band : pane.text).addSublayer(tile)
        tile.setNeedsDisplay()
        tile.displayIfNeeded()
        return tile
    }

    /// Width of the widest line in a row of tiles, text inset included; zero if the rows are blank.
    private func contentWidth(_ pane: Pane, tile index: Int, rows: Range<Int>) -> CGFloat {
        if let cached = pane.contentWidths[index] { return cached }
        var widest = 0.0
        for row in rows {
            guard let src = source(pane: pane.side, row: row) else { continue }
            widest = max(widest, CTLineGetTypographicBounds(ctLine(src.side, src.line), nil, nil, nil))
        }
        let width = widest > 0 ? CGFloat(widest).rounded(.up) + textInset + 2 : 0
        pane.contentWidths[index] = width
        return width
    }

    /// Creates the tiles that just scrolled into view and releases the ones that left.
    private func updateTiles(_ pane: Pane, top: CGFloat, x: CGFloat) {
        let count = paneRowCount(pane.side)
        guard count > 0 else { pane.dropTiles(); return }
        let lh = codeFont.lineHeight
        let tileHeight = lh * CGFloat(Self.tileRows)
        let first = min((count - 1) / Self.tileRows, max(0, Int(floor(top / tileHeight))))
        let last = min((count - 1) / Self.tileRows, max(first, Int(floor((top + bounds.height - 0.01) / tileHeight))))
        let textWidth = pane.text.bounds.width
        let firstColumn = max(0, Int(floor(x / tileWidth)))
        let lastColumn = max(firstColumn, Int(floor((x + textWidth - 0.01) / tileWidth)))

        // One tile of slack vertically, so nudging back and forth does not thrash.
        for (key, tile) in pane.gutterTiles where key < first - 1 || key > last + 1 {
            tile.removeFromSuperlayer()
            pane.gutterTiles.removeValue(forKey: key)
        }
        for (key, tile) in pane.textTiles
        where key.index < first - 1 || key.index > last + 1 || key.column < firstColumn || key.column > lastColumn {
            tile.removeFromSuperlayer()
            pane.textTiles.removeValue(forKey: key)
        }

        let gutter = gutterSpan(pane.side)
        // The left pane's numbers sit against the divider, which moves whenever the viewer's width does
        // (a panel dragged or hidden, the window resized): the tiles that exist have to move with it.
        for tile in pane.gutterTiles.values where tile.position.x != gutter.x { tile.position.x = gutter.x }
        for index in first...last {
            let rows = (index * Self.tileRows)..<min(count, (index + 1) * Self.tileRows)
            let y = CGFloat(index) * tileHeight
            let height = CGFloat(rows.count) * lh
            if pane.gutterTiles[index] == nil {
                pane.gutterTiles[index] = makeTile(.gutter, pane: pane, index: index, column: 0,
                                                   frame: CGRect(x: gutter.x, y: y, width: gutter.width, height: height))
            }
            let content = contentWidth(pane, tile: index, rows: rows)
            for column in firstColumn...lastColumn {
                let key = TileKey(index: index, column: column)
                guard pane.textTiles[key] == nil else { continue }
                let remaining = content - CGFloat(column) * tileWidth
                guard remaining > 0 else { continue }
                let width = min(tileWidth, (remaining / 32).rounded(.up) * 32)
                pane.textTiles[key] = makeTile(.text, pane: pane, index: index, column: column,
                                               frame: CGRect(x: CGFloat(column) * tileWidth, y: y, width: width, height: height))
            }
        }
    }

    // MARK: Layer updates

    private func place(_ layer: CALayer, _ rect: CGRect) {
        layer.position = rect.origin
        layer.bounds.size = rect.size
    }

    private func apply() {
        let started = CACurrentMediaTime()
        let pending = dirty
        dirty = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            CATransaction.commit()
            lastUpdateMilliseconds = (CACurrentMediaTime() - started) * 1000
        }

        // The view's own backing layer stays empty; AppKit owns it, we own everything below `root`.
        if root.superlayer == nil { layer?.addSublayer(root) }
        place(root, bounds)
        root.backgroundColor = theme.background
        guard let doc = document, case .text = doc.content, bounds.width > 1, bounds.height > 1 else {
            for pane in panes {
                pane.band.isHidden = true
                pane.text.isHidden = true
                pane.dropTiles()
                pane.clearDecor()
            }
            connector.isHidden = true
            ruler.isHidden = true
            revertHits.removeAll()
            revertLayers.forEach { $0.isHidden = true }
            tickHits.removeAll()
            tickLayers.forEach { $0.isHidden = true }
            conflictHits.removeAll()
            conflictLayers.forEach { $0.isHidden = true }
            updateCaret()
            return
        }

        let currentMode = mode
        if pending.contains(.tiles) { panes.forEach { $0.dropTiles() } }

        // Geometry.
        for pane in panes {
            place(pane.band, bandRect(pane.side))
            place(pane.text, textRect(pane.side))
        }
        connector.isHidden = currentMode != .sideBySide
        place(connector, CGRect(x: paneWidth, y: 0, width: connectorWidth, height: bounds.height))
        ruler.isHidden = false
        place(ruler, CGRect(x: bounds.width - rulerWidth, y: 0, width: rulerWidth, height: bounds.height))
        let widest = currentMode == .sideBySide ? max(textRect(.left).width, textRect(.right).width) : textRect(.right).width
        let quantised = max(256, (widest / 64).rounded(.up) * 64)
        if quantised != tileWidth {
            tileWidth = quantised
            panes.forEach { $0.dropTextTiles() }
        }

        let scroll = resolveScroll()
        let redecorate = !pending.isDisjoint(with: [.decor, .geometry, .tiles])
        let reselect = redecorate || pending.contains(.selection)

        for pane in panes {
            let active = currentMode == .sideBySide || pane.side == .right
            pane.band.isHidden = !active
            pane.text.isHidden = !active
            guard active else {
                pane.dropTiles()
                pane.clearDecor()
                continue
            }
            let top = pane.side == .left ? scroll.left : scroll.right
            pane.band.bounds.origin = CGPoint(x: 0, y: top)
            pane.text.bounds.origin = CGPoint(x: scroll.x, y: top)
            updateTiles(pane, top: top, x: scroll.x)

            let count = paneRowCount(pane.side)
            guard let visible = visibleRows(top: top, count: count) else {
                pane.clearDecor()
                continue
            }
            let covered = pane.decorRows.contains(visible.lowerBound) && pane.decorRows.contains(visible.upperBound)
            if redecorate || !covered {
                pane.decorRows = max(0, visible.lowerBound - Self.overscan)..<min(count, visible.upperBound + Self.overscan + 1)
                rebuildDecor(pane, doc, rows: pane.decorRows)
                rebuildSelection(pane, rows: pane.decorRows)
            } else if reselect {
                rebuildSelection(pane, rows: pane.decorRows)
            }
        }

        if currentMode == .sideBySide { updateConnectors(doc, scroll) }
        updateRuler(doc, scroll, marks: redecorate)
        updateRevertButtons(doc, scroll)
        updateConflictButtons(doc, scroll)
        updateCaret()
    }

    // MARK: Caret

    /// The caret: at the moving end of the selection in the right side, while the keyboard is here and
    /// the text can be edited. It blinks on the compositor, so a blinking caret costs the app nothing.
    private func updateCaret() {
        guard let editor, let doc = document, case .text = doc.content, let sel = selection,
              mode != .sideBySide || sel.pane == .right, let src = source(pane: .right, row: sel.head.row), src.side == .right,
              let window, window.isKeyWindow || Self.assumeKeyWindow, window.firstResponder === self else {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            caretFrame = .null
            compositionUnderline.clear()
            return
        }
        let lh = codeFont.lineHeight
        let x = textInset + CTLineGetOffsetForStringIndex(ctLine(.right, src.line), sel.head.column, nil)
        let frame = CGRect(x: pixelRound(x - 1), y: CGFloat(sel.head.row) * lh, width: 2, height: lh)
        if frame != caretFrame || caretLayer.isHidden {
            caretFrame = frame
            caretLayer.frame = frame
            caretLayer.isHidden = false
            // Solid while it moves, blinking once it rests.
            caretLayer.removeAllAnimations()
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.calculationMode = .discrete
            blink.values = [1, 0]
            blink.keyTimes = [0, 0.5]
            blink.duration = 1.06
            blink.repeatCount = .infinity
            blink.beginTime = CACurrentMediaTime() + 0.55
            blink.fillMode = .backwards
            caretLayer.add(blink, forKey: "blink")
        }
        caretLayer.backgroundColor = theme.text

        // What an input method is still composing is underlined in place.
        if let marked = editor.marked {
            let row = editRow(forLine: marked.row)
            var rects: [CGRect] = []
            appendRects([marked.range], side: .right, line: marked.row, row: row, to: &rects)
            compositionUnderline.set(rects.map { CGRect(x: $0.minX, y: $0.maxY - 1.5, width: $0.width, height: 1.5) }, color: theme.text)
        } else {
            compositionUnderline.clear()
        }
    }

    /// Lets a test run that the system keeps in the background show its caret anyway. Set only by the debug hooks.
    static var assumeKeyWindow = false
    /// Keeps hover states when AppKit reports the (real, elsewhere) pointer leaving. Set only by the debug hooks.
    static var keepsHoverOnExit = false

    /// Whether the caret is showing (it blinks; this says nothing of the phase). For the debug hooks.
    var isCaretShown: Bool { !caretLayer.isHidden }
    var caretRect: CGRect { caretFrame }

    // MARK: Editing support

    /// The selection as lines of the right side, when it is somewhere that can be edited.
    var editSelection: EditorSession.Selection? {
        guard editor != nil, let sel = selection, mode != .sideBySide || sel.pane == .right else { return nil }
        return (linePosition(sel.anchor), linePosition(sel.head))
    }

    /// A row of the right pane as a line of the right side. In the unified view a row of removed lines
    /// stands for the start of the next line that is still there.
    func linePosition(_ position: TextPosition) -> TextPosition {
        guard let doc = document, !doc.right.lines.isEmpty else { return TextPosition(row: 0, column: 0) }
        guard mode == .unified else { return TextEditing.clamp(position, in: doc.right.lines) }
        let rows = doc.unifiedRows
        guard !rows.isEmpty else { return TextPosition(row: 0, column: 0) }
        var row = min(max(0, position.row), rows.count - 1)
        if rows[row].right >= 0 { return TextEditing.clamp(TextPosition(row: Int(rows[row].right), column: position.column), in: doc.right.lines) }
        while row < rows.count, rows[row].right < 0 { row += 1 }
        if row < rows.count { return TextPosition(row: Int(rows[row].right), column: 0) }
        let last = doc.right.lines.count - 1
        return TextPosition(row: last, column: doc.right.lines[last].utf16.count)
    }

    /// A position in the right side as a row of the right pane.
    func rowPosition(_ position: TextPosition) -> TextPosition {
        TextPosition(row: editRow(forLine: position.row), column: position.column)
    }

    func editRow(forLine line: Int) -> Int {
        guard let doc = document, mode == .unified else { return line }
        return doc.unifiedRow(ofLine: line, side: .right)
    }

    /// Distance of a column from the start of the right side's line, as laid out.
    func xOffset(line: Int, column: Int) -> CGFloat {
        CTLineGetOffsetForStringIndex(ctLine(.right, line), column, nil)
    }

    /// The column nearest to a distance from the start of the right side's line.
    func column(line: Int, atX x: CGFloat) -> Int {
        let index = CTLineGetStringIndexForPosition(ctLine(.right, line), CGPoint(x: x, y: 0))
        let length = document.map { line < $0.right.lines.count ? $0.right.lines[line].utf16.count : 0 } ?? 0
        return index == kCFNotFound ? 0 : min(max(0, index), length)
    }

    /// The right side's position under a point of the canvas.
    func editPosition(at point: CGPoint) -> TextPosition? {
        position(at: point, pane: .right).map(linePosition)
    }

    /// Where part of a line of the right side is on screen, in the canvas's coordinates.
    func viewRect(line: Int, from: Int, to: Int) -> CGRect {
        let lh = codeFont.lineHeight
        let scroll = resolveScroll()
        let text = textRect(.right)
        let x0 = xOffset(line: line, column: from), x1 = xOffset(line: line, column: to)
        return CGRect(x: text.minX + textInset + x0 - scroll.x, y: CGFloat(editRow(forLine: line)) * lh - scroll.right,
                      width: max(1, x1 - x0), height: lh)
    }

    var visibleLineCount: Int { max(1, Int(bounds.height / codeFont.lineHeight)) }

    var gutterDigits: Int { document.map { digits(max($0.left.lines.count, $0.right.lines.count)) } ?? 3 }

    /// Runs an edit of the right side and redraws what it touched. `anchorLine` (a line above the edit, or
    /// its first line) stays where it is on screen: in the side-by-side view the panes are lined up through
    /// the changes, and a change growing by a line must not make the text being typed jump.
    func performEdit(anchorLine: Int, _ edit: () -> [EditorSession.Outcome]) {
        let lh = codeFont.lineHeight
        let before = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
        let digitsBefore = gutterDigits
        let outcomes = edit()
        guard !outcomes.isEmpty else { return }
        textDidChange(outcomes, gutterDigitsBefore: digitsBefore)
        guard mode == .sideBySide, let count = document?.right.lines.count, anchorLine < count else { return }
        for _ in 0..<4 {
            let after = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
            guard abs(after - before) >= 0.5 else { break }
            container?.scrollBy(dx: 0, dy: after - before)
        }
    }

    /// Redraws what edits of the right side touched, and only that: the rewritten lines' tiles, the
    /// tiles below when lines came or went, and the overlays.
    private func textDidChange(_ outcomes: [EditorSession.Outcome], gutterDigitsBefore: Int) {
        guard let doc = document, !outcomes.isEmpty else { return }
        clearLSPHover()
        let right = panes[1]
        var firstShifted = Int.max
        var rows = IndexSet()
        for outcome in outcomes {
            let raw = outcome.raw
            if raw.removed != raw.inserted { firstShifted = min(firstShifted, raw.start) }
            rows.insert(integersIn: raw.start..<(raw.start + raw.inserted))
            rows.insert(integersIn: outcome.recoloured)
        }
        // Laid-out lines are cached by line number: those that changed, and every one below a shift, are stale.
        let stale: (Int) -> Bool = { line in line >= firstShifted || rows.contains(line) }
        for key in Array(lineCacheNew.keys) where key & 1 == Side.right.rawValue && stale(key >> 1) { lineCacheNew.removeValue(forKey: key) }
        for key in Array(lineCacheOld.keys) where key & 1 == Side.right.rawValue && stale(key >> 1) { lineCacheOld.removeValue(forKey: key) }

        if mode == .unified || gutterDigits != gutterDigitsBefore {
            // Rows of the unified view interleave both sides and move with every hunk; a wider gutter moves everything.
            right.dropTiles()
            if gutterDigits != gutterDigitsBefore { panes[0].dropTiles() }
        } else {
            let tileRows = Self.tileRows
            var tiles = Set(rows.map { $0 / tileRows })
            if firstShifted != Int.max {
                let from = firstShifted / tileRows
                tiles.formUnion(right.textTiles.keys.map(\.index).filter { $0 >= from })
                for (index, tile) in right.gutterTiles where index >= from {
                    tile.removeFromSuperlayer()
                    right.gutterTiles.removeValue(forKey: index)
                }
                for index in right.contentWidths.keys where index >= from { right.contentWidths.removeValue(forKey: index) }
            }
            for (key, tile) in right.textTiles where tiles.contains(key.index) {
                tile.removeFromSuperlayer()
                right.textTiles.removeValue(forKey: key)
            }
            for index in tiles { right.contentWidths.removeValue(forKey: index) }
        }
        // Search hits and a "go to line" tint describe the text as it was.
        if !matchesByLine[1].isEmpty || !matches.isEmpty {
            matches = []
            matchesByLine = [[:], [:]]
            currentMatch = -1
        }
        if focusLine != nil { focusLine = nil }
        if let focused = focusedHunk, focused >= doc.hunks.count { focusedHunk = nil }
        if var mapped = annotations {
            // Changed lines are not committed any more; the rest keep their commit (the next save blames again).
            // A line break typed at the start of a line moves that line down without changing it.
            for outcome in outcomes { mapped.apply(outcome.change) }
            annotations = mapped
        }
        editCount += 1
        rebuildHunkRows()
        invalidate([.decor, .selection, .scroll])
        container?.updateDocumentSize()
    }

    /// New hunks for the text on screen (the real diff, back from git): the line with the caret, or the
    /// top line, stays where it is on screen while the two sides line up again around it.
    func hunksDidChange(_ change: () -> Void) {
        clearLSPHover()
        guard let doc = document else { change(); return }
        let lh = codeFont.lineHeight
        let caret = editSelection
        let anchorLine = caret?.head.row ?? Int((resolveScroll().right + lh / 2) / lh)
        let before = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
        change()
        if let focused = focusedHunk, focused >= doc.hunks.count { focusedHunk = nil }
        rebuildHunkRows()
        if mode == .unified { panes[1].dropTiles() }
        if let caret { selection = TextSelection(pane: .right, anchor: rowPosition(caret.anchor), head: rowPosition(caret.head)) }
        invalidate([.decor, .selection, .scroll])
        container?.updateDocumentSize()
        for _ in 0..<4 {
            let after = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
            guard abs(after - before) >= 0.5 else { break }
            container?.scrollBy(dx: 0, dy: after - before)
        }
    }

    /// Scrolls just enough to bring the caret into view, with a little room around it.
    func revealCaret() {
        guard let container, let sel = selection, editor != nil, mode != .sideBySide || sel.pane == .right else { return }
        let lh = codeFont.lineHeight
        let margin = codeFont.charWidth * 4
        let width = textRect(.right).width
        for _ in 0..<4 {
            let scroll = resolveScroll()
            let y = CGFloat(sel.head.row) * lh - scroll.right
            var dy: CGFloat = 0
            if y < lh * 0.5 {
                dy = y - lh * 0.5
            } else if y + lh * 1.5 > bounds.height {
                dy = y + lh * 1.5 - bounds.height
            }
            var dx: CGFloat = 0
            let line = linePosition(sel.head)
            let x = textInset + xOffset(line: line.row, column: line.column) - scroll.x
            if x < margin, scroll.x > 0 {
                dx = max(-scroll.x, x - margin)
            } else if x > width - margin {
                dx = x - (width - margin)
            }
            guard abs(dy) >= 0.5 || abs(dx) >= 0.5 else { break }
            container.scrollBy(dx: dx, dy: dy)
        }
    }

    /// Rectangles covering `ranges` of a line, in the text layer's coordinates.
    private func appendRects(_ ranges: [Range<Int>], side: Side, line: Int, row: Int, to rects: inout [CGRect]) {
        guard !ranges.isEmpty else { return }
        let lh = codeFont.lineHeight
        let layout = ctLine(side, line)
        for r in ranges {
            let x0 = CTLineGetOffsetForStringIndex(layout, r.lowerBound, nil)
            let x1 = CTLineGetOffsetForStringIndex(layout, r.upperBound, nil)
            guard x1 > x0 else { continue }
            rects.append(CGRect(x: textInset + x0, y: CGFloat(row) * lh + 1, width: x1 - x0, height: lh - 2))
        }
    }

    /// Change bands, word-level highlights, search hits and focus markers for a window of rows.
    private func rebuildDecor(_ pane: Pane, _ doc: DiffDocument, rows: Range<Int>) {
        let lh = codeFont.lineHeight
        let bandWidth = pane.band.bounds.width
        var lines = [[CGRect]](repeating: [], count: 3)
        var marks = lines, words = lines
        var excluded: [CGRect] = []
        let ticks = commitTicks
        var lineColors = Self.kinds.map { theme.line($0) }
        let markColors = Self.kinds.map { theme.mark($0) }
        var wordColors = Self.kinds.map { theme.word($0) }

        switch mode {
        case .sideBySide:
            let side = pane.side
            var index = firstHunk(doc, side: side, endingAtOrAfter: rows.lowerBound)
            while index < doc.hunks.count {
                let hunk = doc.hunks[index]
                let start = side == .left ? hunk.leftStart : hunk.rightStart
                let n = side == .left ? hunk.leftCount : hunk.rightCount
                if start > rows.upperBound { break }
                let k = kindIndex(hunk.kind)
                if n == 0 {
                    marks[k].append(CGRect(x: 0, y: CGFloat(start) * lh - 1, width: bandWidth, height: 2))
                } else {
                    // Clipped to the window so a huge hunk never makes a huge layer.
                    let a = max(start, rows.lowerBound), b = min(start + n, rows.upperBound)
                    if a < b {
                        let y = CGFloat(a) * lh, height = CGFloat(b - a) * lh
                        lines[k].append(CGRect(x: 0, y: y, width: bandWidth, height: height))
                        if let ticks { appendExcluded(ticks, side: side, lines: a..<b, row: a, width: bandWidth, to: &excluded) }
                        let inline = side == .left ? hunk.leftInline : hunk.rightInline
                        // `inline` may be empty or shorter than the hunk.
                        var line = a
                        let inlineEnd = min(b, start + inline.count)
                        while line < inlineEnd {
                            // A line that stays out of the commit is pale, without the words that changed in it.
                            if ticks?.isExcluded(side, line) != true {
                                appendRects(inline[line - start], side: side, line: line, row: line, to: &words[k])
                            }
                            line += 1
                        }
                    }
                }
                index += 1
            }

        case .unified:
            lineColors = [theme.added, theme.removedLine, theme.removedLine]
            wordColors = [theme.addedWord, theme.removedWord, theme.removedWord]
            let data = doc.unifiedRows
            let end = min(rows.upperBound, data.count)
            var row = rows.lowerBound
            while row < end {
                let first = data[row]
                guard first.kind != .context else { row += 1; continue }
                var next = row + 1
                while next < end, data[next].kind == first.kind, data[next].hunk == first.hunk { next += 1 }
                let group = first.kind == .added ? 0 : 1
                let rect = CGRect(x: 0, y: CGFloat(row) * lh, width: bandWidth, height: CGFloat(next - row) * lh)
                lines[group].append(rect)
                if let ticks {
                    let side: Side = first.kind == .added ? .right : .left
                    let firstLine = Int(side == .left ? first.left : first.right)
                    appendExcluded(ticks, side: side, lines: firstLine..<(firstLine + next - row), row: row, width: bandWidth, to: &excluded)
                }
                if first.hunk >= 0, Int(first.hunk) < doc.hunks.count {
                    let hunk = doc.hunks[Int(first.hunk)]
                    for i in row..<next {
                        if first.kind == .removed {
                            let line = Int(data[i].left), offset = line - hunk.leftStart
                            if offset >= 0, offset < hunk.leftInline.count, ticks?.isExcluded(.left, line) != true {
                                appendRects(hunk.leftInline[offset], side: .left, line: line, row: i, to: &words[1])
                            }
                        } else {
                            let line = Int(data[i].right), offset = line - hunk.rightStart
                            if offset >= 0, offset < hunk.rightInline.count, ticks?.isExcluded(.right, line) != true {
                                appendRects(hunk.rightInline[offset], side: .right, line: line, row: i, to: &words[0])
                            }
                        }
                    }
                }
                row = next
            }

        case .single:
            break
        }

        var hits: [CGRect] = [], current: [CGRect] = []
        if !matchesByLine[0].isEmpty || !matchesByLine[1].isEmpty {
            let active = currentMatch >= 0 && currentMatch < matches.count ? matches[currentMatch] : nil
            for row in rows where hits.count < 2000 {
                guard let src = source(pane: pane.side, row: row),
                      let ranges = matchesByLine[src.side.rawValue][src.line] else { continue }
                appendRects(ranges, side: src.side, line: src.line, row: row, to: &hits)
                if let active, active.side == src.side, active.line == src.line {
                    appendRects([active.range], side: src.side, line: src.line, row: row, to: &current)
                }
            }
        }

        var focusRow: Int?
        if let focus = focusLine {
            switch mode {
            case .sideBySide: if focus.side == pane.side { focusRow = focus.line }
            case .unified: focusRow = doc.unifiedRow(ofLine: focus.line, side: focus.side)
            case .single: if focus.side == .right { focusRow = focus.line }
            }
        }
        if let focusRow {
            let text = textRect(pane.side)
            pane.focus.isHidden = false
            pane.focus.backgroundColor = theme.focusLine
            pane.focus.frame = CGRect(x: text.minX - bandRect(pane.side).minX, y: CGFloat(focusRow) * lh, width: text.width, height: lh)
        } else {
            pane.focus.isHidden = true
        }

        for k in 0..<3 {
            pane.lines[k].set(lines[k], color: lineColors[k])
            pane.marks[k].set(marks[k], color: markColors[k])
            pane.words[k].set(words[k], color: wordColors[k], radius: 2.5)
        }
        pane.excluded.set(excluded, color: theme.background.copy(alpha: 0.62) ?? theme.background)
        pane.hits.set(hits, color: theme.searchMatch, radius: 2.5)
        pane.currentHit.set(current, color: theme.searchCurrent, radius: 2.5)
    }

    /// Rectangles over the lines of `lines` (shown from `row` on) that stay out of the commit, one per run of them.
    private func appendExcluded(_ ticks: CommitTicks, side: Side, lines: Range<Int>, row: Int, width: CGFloat, to rects: inout [CGRect]) {
        let lh = codeFont.lineHeight
        func add(_ run: Range<Int>) {
            rects.append(CGRect(x: 0, y: CGFloat(row + run.lowerBound - lines.lowerBound) * lh, width: width, height: CGFloat(run.count) * lh))
        }
        guard ticks.included else { add(lines); return }
        let out = side == .left ? ticks.removed : ticks.added
        guard !out.isEmpty else { return }
        var start: Int?
        for line in lines {
            if out.contains(line) {
                if start == nil { start = line }
            } else if let first = start {
                add(first..<line)
                start = nil
            }
        }
        if let first = start { add(first..<lines.upperBound) }
    }

    private func rebuildSelection(_ pane: Pane, rows: Range<Int>) {
        var rects: [CGRect] = []
        if let sel = selection, !sel.isEmpty, mode != .sideBySide || sel.pane == pane.side, !rows.isEmpty {
            let lower = sel.lower, upper = sel.upper
            let lh = codeFont.lineHeight
            let first = max(rows.lowerBound, lower.row), last = min(rows.upperBound - 1, upper.row)
            if first <= last {
                for row in first...last {
                    guard let src = source(pane: pane.side, row: row) else { continue }
                    let layout = ctLine(src.side, src.line)
                    let x0 = row == lower.row ? CTLineGetOffsetForStringIndex(layout, lower.column, nil) : 0
                    var x1: CGFloat
                    if row == upper.row {
                        x1 = CTLineGetOffsetForStringIndex(layout, upper.column, nil)
                    } else {
                        // Reaches one cell past the end, standing in for the line break.
                        x1 = CGFloat(CTLineGetTypographicBounds(layout, nil, nil, nil)) + codeFont.charWidth
                    }
                    x1 = max(x1, x0)
                    rects.append(CGRect(x: textInset + x0, y: CGFloat(row) * lh, width: x1 - x0, height: lh))
                }
            }
        }
        pane.selection.set(rects, color: theme.selection)
    }

    /// The curved ribbons joining each change across the divider.
    private func updateConnectors(_ doc: DiffDocument, _ scroll: Scroll) {
        let lh = codeFont.lineHeight
        let h = bounds.height
        let x1 = connectorWidth
        let bend = connectorWidth * 0.5
        let firstLeft = max(0, Int(floor(scroll.left / lh))), firstRight = max(0, Int(floor(scroll.right / lh)))
        var index = min(firstHunk(doc, side: .left, endingAtOrAfter: firstLeft),
                        firstHunk(doc, side: .right, endingAtOrAfter: firstRight))
        let fills = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        while index < doc.hunks.count {
            let hunk = doc.hunks[index]
            var l0 = CGFloat(hunk.leftStart) * lh - scroll.left
            var l1 = l0 + CGFloat(hunk.leftCount) * lh
            var r0 = CGFloat(hunk.rightStart) * lh - scroll.right
            var r1 = r0 + CGFloat(hunk.rightCount) * lh
            if min(l0, r0) > h { break }
            if max(l1, r1) >= 0 {
                if hunk.leftCount == 0 { l0 -= 1; l1 += 1 }
                if hunk.rightCount == 0 { r0 -= 1; r1 += 1 }
                // Ends far outside the viewport are pulled in; the curve looks the same where it is visible.
                l0 = max(l0, -h); r0 = max(r0, -h); l1 = min(l1, 2 * h); r1 = min(r1, 2 * h)
                let path = CGMutablePath()
                path.move(to: CGPoint(x: 0, y: l0))
                path.addCurve(to: CGPoint(x: x1, y: r0), control1: CGPoint(x: bend, y: l0), control2: CGPoint(x: x1 - bend, y: r0))
                path.addLine(to: CGPoint(x: x1, y: r1))
                path.addCurve(to: CGPoint(x: 0, y: l1), control1: CGPoint(x: x1 - bend, y: r1), control2: CGPoint(x: bend, y: l1))
                path.closeSubpath()
                fills[kindIndex(hunk.kind)].addPath(path)
            }
            index += 1
        }
        let scale = backingScale
        for k in 0..<3 {
            ribbons[k].contentsScale = scale
            ribbons[k].fillColor = theme.line(Self.kinds[k])
            ribbons[k].path = fills[k].isEmpty ? nil : fills[k]
        }
    }

    // MARK: Revert buttons

    /// Follows the code font, within reason.
    private var revertSize: CGFloat { min(18, max(13, (codeFont.lineHeight - 2).rounded())) }

    private var tickSize: CGFloat { min(15, max(12, (codeFont.lineHeight - 4).rounded())) }

    /// One button per visible change: in the ribbon between the panes, or at the right edge in the unified view.
    /// With commit ticks, each change has its tick too: at the left end of the ribbon, or before the button.
    private func updateRevertButtons(_ doc: DiffDocument, _ scroll: Scroll) {
        revertHits.removeAll(keepingCapacity: true)
        tickHits.removeAll(keepingCapacity: true)
        let sideBySide = mode == .sideBySide
        let reverts = showsRevertButtons, ticks = commitTicks != nil
        guard reverts || ticks, sideBySide || mode == .unified, !doc.hunks.isEmpty else {
            revertLayers.forEach { $0.isHidden = true }
            tickLayers.forEach { $0.isHidden = true }
            return
        }
        let lh = codeFont.lineHeight, h = bounds.height, size = revertSize, box = tickSize, scale = backingScale
        let x: CGFloat, tickX: CGFloat
        if sideBySide {
            x = pixelRound(reverts && ticks ? paneWidth + connectorWidth - size - 4 : paneWidth + (connectorWidth - size) / 2)
            tickX = pixelRound(reverts && ticks ? paneWidth + 4 : paneWidth + (connectorWidth - box) / 2)
        } else {
            x = pixelRound(bounds.width - rulerWidth - size - 10)
            tickX = pixelRound(reverts ? x - box - 6 : bounds.width - rulerWidth - box - 10)
        }
        let states = ticks ? tickStates(doc) : []
        var index = 0
        if sideBySide {
            index = min(firstHunk(doc, side: .left, endingAtOrAfter: max(0, Int(floor(scroll.left / lh)))),
                        firstHunk(doc, side: .right, endingAtOrAfter: max(0, Int(floor(scroll.right / lh)))))
        } else {
            // The first change that reaches down to the top of the viewport.
            let topRow = Int(floor(scroll.right / lh))
            var lo = 0, hi = doc.hunks.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if hunkRow(mid) + doc.hunks[mid].leftCount + doc.hunks[mid].rightCount < topRow { lo = mid + 1 } else { hi = mid }
            }
            index = lo
        }
        var used = 0, usedTicks = 0
        while index < doc.hunks.count {
            let hunk = doc.hunks[index]
            let bottom: CGFloat // where the change ends, in view coordinates
            let rest: CGFloat   // where its button sits while the change starts on screen
            if sideBySide {
                let l0 = CGFloat(hunk.leftStart) * lh - scroll.left, r0 = CGFloat(hunk.rightStart) * lh - scroll.right
                if min(l0, r0) > h { break }
                bottom = max(l0 + CGFloat(hunk.leftCount) * lh, r0 + CGFloat(hunk.rightCount) * lh)
                // Midway along the top edge of the ribbon; a side with no lines is just a hairline there.
                let left = l0 + (hunk.leftCount > 0 ? lh / 2 : 0), right = r0 + (hunk.rightCount > 0 ? lh / 2 : 0)
                rest = (left + right) / 2 - size / 2
            } else {
                let top = CGFloat(hunkRow(index)) * lh - scroll.right
                if top > h { break }
                bottom = top + CGFloat(hunk.leftCount + hunk.rightCount) * lh
                rest = top + (lh - size) / 2
            }
            // A change taller than the viewport keeps its buttons in sight for as long as any of it is.
            let y = pixelRound(max(rest, min(3, bottom - size - 3)))
            if bottom >= 0, ticks, index < states.count {
                let rect = CGRect(x: tickX, y: pixelRound(y + (size - box) / 2), width: box, height: box)
                if usedTicks == tickLayers.count {
                    let layer = StillLayer()
                    layer.anchorPoint = .zero
                    root.addSublayer(layer)
                    tickLayers.append(layer)
                }
                let layer = tickLayers[usedTicks]
                usedTicks += 1
                place(layer, rect)
                layer.contentsScale = scale
                layer.contents = tickGlyph(states[index], hot: hoveredTick == index)
                layer.isHidden = false
                tickHits.append((rect, index))
            }
            if bottom >= 0, reverts {
                let rect = CGRect(x: x, y: y, width: size, height: size)
                if used == revertLayers.count {
                    let layer = StillLayer()
                    layer.anchorPoint = .zero
                    layer.cornerRadius = 4
                    layer.contentsGravity = .center
                    root.addSublayer(layer)
                    revertLayers.append(layer)
                }
                let layer = revertLayers[used]
                used += 1
                let hot = hoveredRevert == index
                place(layer, rect)
                layer.contentsScale = scale
                layer.contents = revertGlyph(hot: hot)
                // Over code (unified view) the button needs a ground of its own; in the ribbon it does not.
                layer.backgroundColor = hot ? theme.accent : (sideBySide ? nil : theme.background)
                layer.borderWidth = sideBySide || hot ? 0 : 1
                layer.borderColor = theme.separator
                layer.isHidden = false
                revertHits.append((rect, index))
            }
            index += 1
        }
        for layer in revertLayers[used...] { layer.isHidden = true }
        for layer in tickLayers[usedTicks...] { layer.isHidden = true }
        if let hovered = hoveredRevert, !revertHits.contains(where: { $0.hunk == hovered }) { hoveredRevert = nil }
        if let hovered = hoveredTick, !tickHits.contains(where: { $0.hunk == hovered }) { hoveredTick = nil }
    }

    /// Each change's tick: on when all of it goes into the commit, off when none of it does.
    private func tickStates(_ doc: DiffDocument) -> [Inclusion] {
        if let cached = tickStateCache, cached.count == doc.hunks.count { return cached }
        guard let ticks = commitTicks else { return [] }
        func count(_ range: Range<Int>, in lines: Set<Int>) -> Int {
            range.count < lines.count ? range.filter(lines.contains).count : lines.filter(range.contains).count
        }
        let states = doc.hunks.map { hunk -> Inclusion in
            guard ticks.included else { return .off }
            let left = hunk.leftStart..<(hunk.leftStart + hunk.leftCount), right = hunk.rightStart..<(hunk.rightStart + hunk.rightCount)
            let out = count(left, in: ticks.removed) + count(right, in: ticks.added)
            return out == 0 ? .on : (out == left.count + right.count ? .off : .mixed)
        }
        tickStateCache = states
        return states
    }

    /// The tick, drawn like the ones in the Changes list.
    private func tickGlyph(_ state: Inclusion, hot: Bool) -> CGImage? {
        let scale = backingScale, size = tickSize
        let key = "\(state)|\(hot)|\(theme.isDark)|\(scale)|\(size)"
        if let cached = tickGlyphs[key] { return cached }
        guard let context = CGContext(data: nil, width: Int(ceil(size * scale)), height: Int(ceil(size * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let box = CGPath(roundedRect: CGRect(x: 0.75, y: 0.75, width: size - 1.5, height: size - 1.5),
                         cornerWidth: 3.5, cornerHeight: 3.5, transform: nil)
        if state == .off {
            context.addPath(box)
            context.setFillColor(theme.background)
            context.fillPath()
            context.addPath(box)
            context.setStrokeColor(hot ? theme.accent : theme.gutterTextStrong)
            context.setLineWidth(1.3)
            context.strokePath()
        } else {
            context.addPath(box)
            context.setFillColor(hot ? (theme.accent.copy(alpha: 0.82) ?? theme.accent) : theme.accent)
            context.fillPath()
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(max(1.6, size * 0.13))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if state == .on {
                context.move(to: CGPoint(x: size * 0.28, y: size * 0.51))
                context.addLine(to: CGPoint(x: size * 0.44, y: size * 0.35))
                context.addLine(to: CGPoint(x: size * 0.73, y: size * 0.66))
            } else {
                context.move(to: CGPoint(x: size * 0.3, y: size * 0.5))
                context.addLine(to: CGPoint(x: size * 0.7, y: size * 0.5))
            }
            context.strokePath()
        }
        let image = context.makeImage()
        tickGlyphs[key] = image
        return image
    }

    private func tickHit(at point: CGPoint) -> Int? {
        tickHits.first { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }?.hunk
    }

    // MARK: Conflict buttons

    private static let conflictChoices: [(ConflictChoice, String)] = [
        (.ours, L("Keep HEAD", "保留 HEAD")), (.theirs, L("Take Incoming", "采用传入")), (.both, L("Both", "两者都要")),
    ]

    /// Three buttons on each conflict's `<<<<<<<` line, at the right edge of the text that can be edited.
    private func updateConflictButtons(_ doc: DiffDocument, _ scroll: Scroll) {
        conflictHits.removeAll(keepingCapacity: true)
        guard !conflicts.isEmpty, mode != .single || doc.isPlainFile else {
            conflictLayers.forEach { $0.isHidden = true }
            return
        }
        let lh = codeFont.lineHeight, h = bounds.height, scale = backingScale
        let right = bounds.width - rulerWidth - 10
        var used = 0
        for (index, block) in conflicts.enumerated() {
            let row = mode == .unified ? doc.unifiedRow(ofLine: block.start, side: .right) : block.start
            let top = CGFloat(row) * lh - scroll.right
            guard top > -lh, top < h else { continue }
            var x = right
            for (choice, title) in Self.conflictChoices.reversed() {
                let hot = hoveredConflict?.block == index && hoveredConflict?.choice == choice
                guard let image = conflictGlyph(title, hot: hot, prominent: choice != .both) else { continue }
                let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
                x -= size.width
                let rect = CGRect(x: pixelRound(x), y: pixelRound(top + (lh - size.height) / 2), width: size.width, height: size.height)
                x -= 6
                if used == conflictLayers.count {
                    let layer = StillLayer()
                    layer.anchorPoint = .zero
                    layer.zPosition = 8
                    root.addSublayer(layer)
                    conflictLayers.append(layer)
                }
                let layer = conflictLayers[used]
                used += 1
                place(layer, rect)
                layer.contentsScale = scale
                layer.contents = image
                layer.isHidden = false
                conflictHits.append((rect, index, choice))
            }
        }
        for layer in conflictLayers[used...] { layer.isHidden = true }
    }

    private func conflictGlyph(_ title: String, hot: Bool, prominent: Bool) -> CGImage? {
        let scale = backingScale
        let fontSize = max(10, min(13, codeFont.size - 1))
        let key = "\(title)|\(hot)|\(prominent)|\(theme.isDark)|\(scale)|\(fontSize)"
        if let cached = conflictGlyphs[key] { return cached }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let ink: NSColor = hot ? .white : (prominent ? NSColor(cgColor: theme.accent) ?? .systemBlue : NSColor(cgColor: theme.gutterTextStrong) ?? .gray)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width + 14), height: ceil(min(codeFont.lineHeight - 2, textSize.height + 4)))
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let pill = CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5), cornerWidth: size.height / 2,
                          cornerHeight: size.height / 2, transform: nil)
        context.addPath(pill)
        context.setFillColor(hot ? theme.accent : theme.background)
        context.fillPath()
        if !hot {
            context.addPath(pill)
            context.setStrokeColor(prominent ? theme.accent.copy(alpha: 0.7) ?? theme.accent : theme.separator)
            context.setLineWidth(1)
            context.strokePath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: 7, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        conflictGlyphs[key] = image
        return image
    }

    private func conflictHit(at point: CGPoint) -> (block: Int, choice: ConflictChoice)? {
        conflictHits.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }.map { ($0.block, $0.choice) }
    }

    private func revertGlyph(hot: Bool) -> CGImage? {
        let scale = backingScale, size = revertSize
        let key = "\(hot)|\(theme.isDark)|\(scale)|\(size)"
        if let cached = revertGlyphs[key] { return cached }
        let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.62, weight: .bold)
        guard let symbol = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let rect = CGRect(origin: .zero, size: symbol.size)
        guard let context = CGContext(data: nil, width: Int(ceil(rect.width * scale)), height: Int(ceil(rect.height * scale)),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        symbol.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        // Keep the symbol's shape, replace its colour.
        context.setBlendMode(.sourceIn)
        context.setFillColor(hot ? NSColor.white.cgColor : theme.gutterTextStrong)
        context.fill(rect)
        let image = context.makeImage()
        revertGlyphs[key] = image
        return image
    }

    private func revertHit(at point: CGPoint) -> Int? {
        revertHits.first { $0.rect.insetBy(dx: -3, dy: -3).contains(point) }?.hunk
    }

    /// The change shown at `point`, if there is one there.
    func hunkIndex(at point: CGPoint) -> Int? {
        guard let doc = document, case .text = doc.content, point.x < bounds.width - rulerWidth else { return nil }
        if let hit = revertHit(at: point) ?? tickHit(at: point) { return hit }
        let side = pane(at: point)
        let scroll = resolveScroll()
        let row = Int(floor((point.y + (side == .left ? scroll.left : scroll.right)) / codeFont.lineHeight))
        guard row >= 0, row < paneRowCount(side) else { return nil }
        switch mode {
        case .unified:
            let hunk = Int(doc.unifiedRows[row].hunk)
            return hunk >= 0 ? hunk : nil
        case .sideBySide:
            let index = firstHunk(doc, side: side, endingAtOrAfter: row)
            guard index < doc.hunks.count else { return nil }
            let hunk = doc.hunks[index]
            let start = side == .left ? hunk.leftStart : hunk.rightStart
            let count = side == .left ? hunk.leftCount : hunk.rightCount
            return row >= start && row < start + count ? index : nil
        case .single:
            return nil
        }
    }

    /// Remembers what the pointer is over, for the context menu that is about to be built.
    func noteContextMenu(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        contextHunk = hunkIndex(at: point)
        contextLSPSymbol = lspSymbolTarget(at: point)
    }

    /// The change a context menu is for, set directly (the debug hooks build menus without a click).
    func noteContextHunk(_ index: Int?) { contextHunk = index }

    /// The LSP symbol a context menu is for, set directly (for tests and debug hooks).
    func noteContextLSPSymbol(_ target: LSPHoverTarget?) { contextLSPSymbol = target }

    /// What each visible commit tick shows, top to bottom, for the debug hooks: "0:on 1:mixed".
    var visibleTickStates: String {
        guard let doc = document else { return "" }
        let states = tickStates(doc)
        return tickHits.map { "\($0.hunk):\(states.indices.contains($0.hunk) ? "\(states[$0.hunk])" : "?")" }.joined(separator: " ")
    }

    func handleMouseMoved(_ event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        lastMousePoint = point
        let line = point.flatMap(annotatedLine(at:))
        if line != hoveredAnnotationLine { setHoveredAnnotation(line) }
        let hit = point.flatMap(revertHit(at:))
        if hit != hoveredRevert { hoveredRevert = hit }
        let tick = point.flatMap(tickHit(at:))
        if tick != hoveredTick { hoveredTick = tick }
        let conflict = point.flatMap(conflictHit(at:))
        if conflict?.block != hoveredConflict?.block || conflict?.choice != hoveredConflict?.choice { hoveredConflict = conflict }
        let commandOnly = event.map { Self.isCommandOnly($0.modifierFlags) } ?? false
        let buttonHit = hit != nil || tick != nil || conflict != nil || line != nil
        if let point, commandOnly, !buttonHit {
            updateLSPHover(at: point)
        } else {
            clearLSPHover()
        }
        // The canvas is one big text cursor rectangle; over a button, commit, or ⌘-hovered symbol it should look clickable.
        guard let point else { return }
        if hit != nil || tick != nil || conflict != nil {
            NSCursor.arrow.set()
        } else if line != nil || lspHover != nil {
            NSCursor.pointingHand.set()
        } else if annotationWidth > 0, point.x >= annotationX, point.x < annotationX + annotationWidth {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        handleFlagsChanged(event)
    }

    /// Updates ⌘+Hover visual feedback immediately when ⌘ is pressed or released while the pointer is stationary.
    func handleFlagsChanged(_ event: NSEvent) {
        guard isLSPEnabled, let doc = document, case .text = doc.content else {
            clearLSPHover()
            return
        }
        let point: CGPoint?
        if let window {
            let loc = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            point = bounds.contains(loc) ? loc : nil
        } else {
            point = lastMousePoint.flatMap { bounds.contains($0) ? $0 : nil }
        }
        guard let point else {
            clearLSPHover()
            return
        }
        let commandOnly = Self.isCommandOnly(event.modifierFlags)
        let overControl = revertHit(at: point) != nil || tickHit(at: point) != nil
            || conflictHit(at: point) != nil || annotatedLine(at: point) != nil
        if commandOnly && !overControl {
            updateLSPHover(at: point)
        } else {
            clearLSPHover()
        }
        if revertHit(at: point) != nil || tickHit(at: point) != nil || conflictHit(at: point) != nil {
            NSCursor.arrow.set()
        } else if annotatedLine(at: point) != nil || lspHover != nil {
            NSCursor.pointingHand.set()
        } else if annotationWidth > 0, point.x >= annotationX, point.x < annotationX + annotationWidth {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    private static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .option, .control, .shift]) == .command
    }

    private func updateLSPHover(at point: CGPoint) {
        let target = lspSymbolTarget(at: point)
        if target != lspHover {
            setLSPHover(target)
        }
    }

    func clearLSPHover() {
        guard lspHover != nil else { return }
        setLSPHover(nil)
    }

    private func setLSPHover(_ target: LSPHoverTarget?) {
        lspHover = target
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let target else {
            lspHoverUnderline.clear()
            return
        }
        let lh = codeFont.lineHeight
        let layout = ctLine(.right, target.line)
        let x0 = CTLineGetOffsetForStringIndex(layout, target.range.lowerBound, nil)
        let x1 = CTLineGetOffsetForStringIndex(layout, target.range.upperBound, nil)
        guard x1 > x0 else {
            lspHoverUnderline.clear()
            return
        }
        let y = CGFloat(target.row) * lh + min(lh - 1.5, codeFont.baseline + 2)
        let rect = CGRect(x: textInset + x0, y: pixelRound(y), width: x1 - x0, height: 1.25)
        lspHoverUnderline.set([rect], color: theme.accent)
    }

    /// Returns the eligible identifier symbol under `point` on the LSP-enabled right/live pane, or `nil`.
    func lspSymbolTarget(at point: CGPoint) -> LSPHoverTarget? {
        guard isLSPEnabled, let doc = document, case .text = doc.content else { return nil }
        let rightRect = textRect(.right)
        guard point.x >= rightRect.minX, point.x < rightRect.maxX else { return nil }
        if mode == .sideBySide, pane(at: point) != .right { return nil }

        let count = paneRowCount(.right)
        guard count > 0 else { return nil }
        let scroll = resolveScroll()
        let rawRow = Int(floor((point.y + scroll.right) / codeFont.lineHeight))
        guard rawRow >= 0, rawRow < count else { return nil }
        guard let src = source(pane: .right, row: rawRow), src.side == .right else { return nil }
        guard src.line >= 0, src.line < doc.right.lines.count else { return nil }

        let text = doc.right.lines[src.line] as NSString
        guard text.length > 0 else { return nil }

        let layout = ctLine(.right, src.line)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(layout, nil, nil, nil))
        let x = point.x - (rightRect.minX + textInset - scroll.x)
        guard x >= 0, x <= lineWidth else { return nil }

        guard let pos = position(at: point, pane: .right) else { return nil }
        var col = pos.column
        if col >= text.length || (col > 0 && CTLineGetOffsetForStringIndex(layout, col, nil) > x) {
            col -= 1
        }
        guard col >= 0, col < text.length else { return nil }

        guard let range = Self.symbolRange(in: text, spans: doc.right.spans(at: src.line), at: col) else { return nil }
        return LSPHoverTarget(row: rawRow, line: src.line, column: col, range: range)
    }

    /// Finds the UTF-16 identifier range covering `column` in `text`, excluding non-identifiers,
    /// pure numbers, comments, strings, keywords, operators, and backtick struct tags.
    static func symbolRange(in text: NSString, spans: [SyntaxSpan], at column: Int) -> Range<Int>? {
        let length = text.length
        guard length > 0, column >= 0, column < length else { return nil }
        func isIdentChar(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        guard isIdentChar(text.character(at: column)) else { return nil }
        var start = column
        var end = column + 1
        while start > 0, isIdentChar(text.character(at: start - 1)) { start -= 1 }
        while end < length, isIdentChar(text.character(at: end)) { end += 1 }

        // Reject pure numeric literals (e.g. `123`, `0xFF`).
        if isDigit(text.character(at: start)) { return nil }

        // Check whether the covering syntax span forbids jump (comments, strings, numbers, keywords, operators, struct tags).
        for span in spans {
            let sStart = Int(span.start)
            let sEnd = sStart + Int(span.length)
            if sEnd <= column { continue }
            if sStart > column { break }
            switch span.kind {
            case .comment, .string, .number, .keyword, .operator:
                return nil
            case .annotation:
                if sStart < length, text.character(at: sStart) == 96 { return nil } // Go struct tag (`json:"..."`)
            default:
                break
            }
        }
        return start..<end
    }

    /// Overview of every change in the file, plus the viewport position.
    private func updateRuler(_ doc: DiffDocument, _ scroll: Scroll, marks: Bool) {
        let total = rowCount
        ruler.isHidden = total == 0
        guard total > 0 else { return }
        let lh = codeFont.lineHeight
        let h = bounds.height
        let scale = rulerScale

        let scrollable = CGFloat(total) * lh + bottomPadding > h
        rulerThumb.isHidden = !scrollable
        if scrollable {
            rulerThumb.backgroundColor = theme.rulerThumb
            rulerThumb.frame = CGRect(x: 1, y: scroll.y / lh * scale, width: rulerWidth - 2, height: max(12, h / lh * scale))
        }
        guard marks else { return }
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for (index, hunk) in doc.hunks.enumerated() where index < hunkRows.count {
            let span = mode == .unified ? hunk.leftCount + hunk.rightCount : max(hunk.leftCount, hunk.rightCount)
            paths[kindIndex(hunk.kind)].addRect(CGRect(x: 3, y: CGFloat(hunkRows[index]) * scale,
                                                       width: rulerWidth - 6, height: max(2, CGFloat(span) * scale)))
        }
        for k in 0..<3 {
            rulerMarks[k].contentsScale = backingScale
            rulerMarks[k].fillColor = theme.mark(Self.kinds[k])
            rulerMarks[k].path = paths[k].isEmpty ? nil : paths[k]
        }
    }

    /// Points per row on the overview ruler.
    private var rulerScale: CGFloat {
        let total = CGFloat(rowCount) + bottomPadding / codeFont.lineHeight
        return min(codeFont.lineHeight, bounds.height / max(1, total))
    }

    // MARK: Hit testing and selection

    private func pane(at point: CGPoint) -> Side {
        guard mode == .sideBySide else { return .right }
        return point.x < paneWidth + connectorWidth / 2 ? .left : .right
    }

    private func position(at point: CGPoint, pane: Side) -> TextPosition? {
        let count = paneRowCount(pane)
        guard count > 0 else { return nil }
        let scroll = resolveScroll()
        let top = pane == .left ? scroll.left : scroll.right
        let rawRow = Int(floor((point.y + top) / codeFont.lineHeight))
        if rawRow < 0 { return TextPosition(row: 0, column: 0) }
        let row = min(rawRow, count - 1)
        guard let src = source(pane: pane, row: row) else { return nil }
        let line = ctLine(src.side, src.line)
        if rawRow >= count {
            return TextPosition(row: row, column: CTLineGetStringRange(line).length)
        }
        let x = point.x - (textRect(pane).minX + textInset - scroll.x)
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return TextPosition(row: row, column: max(0, index == kCFNotFound ? 0 : index))
    }

    private func rowText(pane: Side, row: Int) -> NSString {
        guard let doc = document, let src = source(pane: pane, row: row) else { return "" }
        return doc.buffer(src.side).lines[src.line] as NSString
    }

    private func wordRange(in text: NSString, at column: Int) -> Range<Int> {
        let length = text.length
        guard length > 0 else { return 0..<0 }
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }
        let pivot = min(max(0, column), length - 1)
        guard isWord(text.character(at: pivot)) else { return pivot..<(pivot + 1) }
        var start = pivot, end = pivot + 1
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < length, isWord(text.character(at: end)) { end += 1 }
        return start..<end
    }

    func handleMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        // A click ends whatever an input method was composing, the way it does in any text view.
        commitComposition()
        editor?.closeGroup()
        goalX = nil
        let point = convert(event.locationInWindow, from: nil)
        if point.x >= bounds.width - rulerWidth {
            draggingRuler = true
            scrollRuler(to: point)
            return
        }
        if let hunk = tickHit(at: point) {
            pressedTick = hunk
            return
        }
        if let hunk = revertHit(at: point) {
            pressedRevert = hunk
            return
        }
        if let hit = conflictHit(at: point) {
            pressedConflict = hit
            return
        }
        if annotationWidth > 0, point.x >= annotationX, point.x < annotationX + annotationWidth {
            // The Annotate column: a click on a line with a commit shows that commit; it never selects text.
            if let line = annotatedLine(at: point), let entry = annotations?.entry(atLine: line) {
                setHoveredAnnotation(nil)
                delegate?.canvas(self, openAnnotation: entry)
            }
            return
        }
        if isLSPEnabled, event.clickCount == 1, Self.isCommandOnly(event.modifierFlags),
           let target = lspSymbolTarget(at: point) {
            clearLSPHover()
            dragSelecting = false
            delegate?.canvas(self, goToDefinitionAt: target.line, character: target.column)
            return
        }
        let side = pane(at: point)
        guard let pos = position(at: point, pane: side) else { selection = nil; return }
        switch event.clickCount {
        case 2:
            let range = wordRange(in: rowText(pane: side, row: pos.row), at: pos.column)
            selection = TextSelection(pane: side, anchor: TextPosition(row: pos.row, column: range.lowerBound),
                                      head: TextPosition(row: pos.row, column: range.upperBound))
        case 3...:
            selection = TextSelection(pane: side, anchor: TextPosition(row: pos.row, column: 0),
                                      head: TextPosition(row: pos.row, column: rowText(pane: side, row: pos.row).length))
        default:
            if event.modifierFlags.contains(.shift), let current = selection, current.pane == side {
                selection = TextSelection(pane: side, anchor: current.anchor, head: pos)
            } else {
                selection = TextSelection(pane: side, anchor: pos, head: pos)
            }
            dragSelecting = true
        }
    }

    func handleMouseDragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingRuler {
            scrollRuler(to: point)
            return
        }
        guard pressedRevert == nil, pressedTick == nil, pressedConflict == nil, dragSelecting, let current = selection else { return }
        if point.y < 0 {
            container?.scrollBy(dx: 0, dy: max(-60, point.y))
        } else if point.y > bounds.height {
            container?.scrollBy(dx: 0, dy: min(60, point.y - bounds.height))
        }
        if let pos = position(at: point, pane: current.pane) {
            selection = TextSelection(pane: current.pane, anchor: current.anchor, head: pos)
        }
    }

    func handleMouseUp(_ event: NSEvent) {
        draggingRuler = false
        dragSelecting = false
        if let pressed = pressedTick {
            pressedTick = nil
            if tickHit(at: convert(event.locationInWindow, from: nil)) == pressed {
                delegate?.canvas(self, toggleCommitHunk: pressed)
            }
            return
        }
        if let pressed = pressedRevert {
            pressedRevert = nil
            // Like any button: it fires only if the pointer is still on it when released.
            if revertHit(at: convert(event.locationInWindow, from: nil)) == pressed {
                delegate?.canvas(self, revertHunk: pressed)
            }
            return
        }
        if let pressed = pressedConflict {
            pressedConflict = nil
            if let hit = conflictHit(at: convert(event.locationInWindow, from: nil)), hit.block == pressed.block, hit.choice == pressed.choice {
                delegate?.canvas(self, resolveConflict: pressed.block, choice: pressed.choice)
            }
            return
        }
        guard let current = selection else { return }
        if editor != nil, mode != .sideBySide || current.pane == .right {
            // In the text that can be edited an empty selection is the caret. In the unified view a click on a
            // removed line (which is not in the file any more) lands on the line that follows it.
            if mode == .unified, current.isEmpty {
                let caret = rowPosition(linePosition(current.head))
                selection = TextSelection(pane: .right, anchor: caret, head: caret)
            }
            return
        }
        if current.isEmpty { selection = nil }
    }

    private func scrollRuler(to point: CGPoint) {
        let row = point.y / max(0.0001, rulerScale)
        container?.scroll(toY: row * codeFont.lineHeight - bounds.height / 2, animated: false)
    }

    func selectedText() -> String? {
        guard let sel = selection, !sel.isEmpty else { return nil }
        let lower = sel.lower, upper = sel.upper
        var parts: [String] = []
        for row in lower.row...upper.row {
            let text = rowText(pane: sel.pane, row: row)
            let start = row == lower.row ? min(lower.column, text.length) : 0
            let end = row == upper.row ? min(upper.column, text.length) : text.length
            parts.append(text.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
        return parts.joined(separator: "\n")
    }

    /// 1-based line number of the selection start (or visible focus line / top visible line) on the new side.
    func currentLineNumber() -> Int {
        if let sel = selection, let src = source(pane: sel.pane, row: sel.lower.row) { return src.line + 1 }
        let scroll = resolveScroll()
        if let focus = focusLine, focus.side == .right {
            let focusRow = row(forLine: focus.line, side: .right)
            if let visible = visibleRows(top: scroll.right, count: paneRowCount(.right)), visible.contains(focusRow) {
                return focus.line + 1
            }
        }
        let row = max(0, Int((scroll.right + bounds.height * 0.3) / codeFont.lineHeight))
        if let src = source(pane: .right, row: min(row, max(0, paneRowCount(.right) - 1))) { return src.line + 1 }
        return 1
    }

    /// The lines the selection covers on one side (0-based), or the caret's line when nothing is selected. In the
    /// unified view, the side that has lines in the selection, the right one when both do.
    func selectedLines() -> (side: Side, range: ClosedRange<Int>)? {
        guard let doc = document, case .text = doc.content, let sel = selection else { return nil }
        var upper = sel.upper.row
        // A selection that ends at the very start of a line does not take that line.
        if upper > sel.lower.row, sel.upper.column == 0 { upper -= 1 }
        switch mode {
        case .sideBySide, .single:
            let side: Side = mode == .single ? .right : sel.pane
            let count = doc.buffer(side).lines.count
            guard count > 0 else { return nil }
            return (side, min(sel.lower.row, count - 1)...min(upper, count - 1))
        case .unified:
            let rows = doc.unifiedRows
            guard !rows.isEmpty else { return nil }
            var right: ClosedRange<Int>?, left: ClosedRange<Int>?
            for row in min(sel.lower.row, rows.count - 1)...min(upper, rows.count - 1) {
                let r = rows[row]
                if r.right >= 0 {
                    let line = Int(r.right)
                    right = right.map { min($0.lowerBound, line)...max($0.upperBound, line) } ?? line...line
                } else if r.left >= 0 {
                    let line = Int(r.left)
                    left = left.map { min($0.lowerBound, line)...max($0.upperBound, line) } ?? line...line
                }
            }
            if let right { return (.right, right) }
            return left.map { (.left, $0) }
        }
    }

    /// Every line the selection covers, each with its side (the unified view has both), or the caret's line.
    func selectedSourceLines() -> [(side: Side, line: Int)] {
        guard let sel = selection else { return [] }
        var upper = sel.upper.row
        // A selection that ends at the very start of a line does not take that line.
        if upper > sel.lower.row, sel.upper.column == 0 { upper -= 1 }
        return (sel.lower.row...upper).compactMap { source(pane: sel.pane, row: $0) }
    }

    /// The 1-based line numbers the selection covers, when it touches real lines.
    func selectedLineRange() -> ClosedRange<Int>? {
        guard let sel = selection, !sel.isEmpty else { return nil }
        var first: Int?, last: Int?
        for row in sel.lower.row...sel.upper.row {
            guard let src = source(pane: sel.pane, row: row) else { continue }
            if first == nil { first = src.line + 1 }
            last = src.line + 1
        }
        guard let first, let last else { return nil }
        return first...last
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else {
            // As in the IDE: with nothing selected in the text being edited, ⌘C copies the whole line.
            if let line = caretLineText() {
                pasteboard.clearContents()
                pasteboard.setString(line, forType: .string)
                lineClipboard = line
            }
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        lineClipboard = nil
    }

    override func selectAll(_ sender: Any?) {
        if let doc = document, editor != nil, mode != .sideBySide || selection?.pane != .left {
            commitComposition()
            let last = doc.right.lines.count - 1
            guard last >= 0 else { return }
            selection = TextSelection(pane: .right, anchor: rowPosition(TextPosition(row: 0, column: 0)),
                                      head: rowPosition(TextPosition(row: last, column: doc.right.lines[last].utf16.count)))
            return
        }
        let side = selection?.pane ?? .right
        let count = paneRowCount(side)
        guard count > 0 else { return }
        selection = TextSelection(pane: side, anchor: TextPosition(row: 0, column: 0),
                                  head: TextPosition(row: count - 1, column: rowText(pane: side, row: count - 1).length))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if editor != nil, handleEditingKey(event) { return }
        guard let container else { super.keyDown(with: event); return }
        let lh = codeFont.lineHeight
        let page = max(lh, bounds.height - lh * 2)
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 125: // down
            if command { container.scroll(toY: .greatestFiniteMagnitude, animated: true) } else { container.scrollBy(dx: 0, dy: lh * 3) }
        case 126: // up
            if command { container.scroll(toY: 0, animated: true) } else { container.scrollBy(dx: 0, dy: -lh * 3) }
        case 123: container.scrollBy(dx: -codeFont.charWidth * 8, dy: 0)
        case 124: container.scrollBy(dx: codeFont.charWidth * 8, dy: 0)
        case 121: container.scroll(toY: container.scrollY + page, animated: true)
        case 116: container.scroll(toY: container.scrollY - page, animated: true)
        case 49:
            container.scroll(toY: container.scrollY + (event.modifierFlags.contains(.shift) ? -page : page), animated: true)
        case 115: container.scroll(toY: 0, animated: true)
        case 119: container.scroll(toY: .greatestFiniteMagnitude, animated: true)
        case 53: delegate?.canvasDidRequestExit(self)
        default: super.keyDown(with: event)
        }
    }

    /// Only text that can be edited takes part in input methods; a read-only view gets keys as keys.
    override var inputContext: NSTextInputContext? { editor == nil ? nil : super.inputContext }

    /// Key bindings (arrows, ⌫, ↩, ⌥←…) come back from the text input system as standard commands.
    override func doCommand(by selector: Selector) {
        guard editor != nil else { super.doCommand(by: selector); return }
        if !performEditingCommand(selector) { NSSound.beep() }
    }

    override func becomeFirstResponder() -> Bool {
        invalidate(.selection)
        return true
    }

    override func resignFirstResponder() -> Bool {
        // Whatever an input method was composing goes in as typed, rather than being lost.
        commitComposition()
        invalidate(.selection)
        return true
    }
}

// MARK: - Scroll container

/// The transparent scroll view's document. It has no content of its own; it only gives the
/// scroll view something to scroll and forwards mouse input to the canvas underneath.
private final class ForwardingDocumentView: NSView {
    weak var canvas: CodeCanvasView?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { canvas?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { canvas?.handleMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let canvas else { return nil }
        canvas.noteContextMenu(event)
        return canvas.delegate?.canvasContextMenu(canvas)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // One area that follows the visible rect by itself. Replacing it each time AppKit asks (whenever anything
        // in the window changes, such as a hover card appearing) would report the pointer leaving and lose the hover.
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseMoved(with event: NSEvent) { canvas?.handleMouseMoved(event) }
    override func mouseExited(with event: NSEvent) {
        // AppKit reports leaving by where the real pointer is, which a test run's queued moves never take there.
        if CodeCanvasView.keepsHoverOnExit { return }
        canvas?.handleMouseMoved(nil)
    }
    override func magnify(with event: NSEvent) {
        guard let canvas else { return }
        canvas.delegate?.canvasDidMagnify(canvas, by: event.magnification)
    }
    override func resetCursorRects() {
        // Stops short of the edges: the dividers around the viewer reach a few points over it,
        // and there the resize pointer has to win over the I-beam.
        addCursorRect(visibleRect.insetBy(dx: DividerGrip.grabWidth / 2 + 1, dy: DividerGrip.grabWidth / 2 + 1), cursor: .iBeam)
    }
}

/// Hosts the canvas and supplies native scrolling (momentum, rubber-banding, scrollers).
final class CodeScrollContainer: NSView {
    let canvas = CodeCanvasView()
    let scrollView = NSScrollView()
    private let spacer = ForwardingDocumentView()
    private var animationTimer: Timer?
    /// Called when the user scrolls by hand, so keyboard navigation can re-anchor to the viewport.
    var onUserScroll: (() -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        canvas.container = self
        addSubview(canvas)

        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = true
        spacer.canvas = canvas
        scrollView.documentView = spacer
        addSubview(scrollView)

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted),
                                               name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var laidOutActions: [() -> Void] = []

    /// Runs `action` once the view has a real size (immediately if it already does).
    /// Scroll positions computed before the first layout pass would be meaningless.
    func whenLaidOut(_ action: @escaping () -> Void) {
        if bounds.height > 1 { action() } else { laidOutActions.append(action) }
    }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        scrollView.frame = bounds
        updateDocumentSize()
        if bounds.height > 1, !laidOutActions.isEmpty {
            let actions = laidOutActions
            laidOutActions = []
            actions.forEach { $0() }
        }
    }

    var documentWidth: CGFloat { spacer.frame.width }
    var scrollY: CGFloat { scrollView.contentView.bounds.origin.y }
    private var maxScrollY: CGFloat { max(0, spacer.frame.height - scrollView.contentView.bounds.height) }
    private var maxScrollX: CGFloat { max(0, spacer.frame.width - scrollView.contentView.bounds.width) }

    func updateDocumentSize() {
        let size = canvas.documentSize(viewport: bounds.size)
        if spacer.frame.size != size {
            spacer.setFrameSize(size)
            // Shrinking the document can leave the clip view past the new end.
            let origin = scrollView.contentView.bounds.origin
            let clamped = CGPoint(x: min(origin.x, maxScrollX), y: min(origin.y, maxScrollY))
            if clamped != origin { setOrigin(clamped) }
        }
    }

    @objc private func clipBoundsChanged() {
        canvas.scrollOrigin = scrollView.contentView.bounds.origin
    }

    @objc private func liveScrollStarted() {
        animationTimer?.invalidate()
        animationTimer = nil
        onUserScroll?()
    }

    private func setOrigin(_ point: CGPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.scrollOrigin = scrollView.contentView.bounds.origin
    }

    /// Replaces the document. `preserveScroll` keeps the viewport where it was (used for live reloads).
    func show(_ doc: DiffDocument?, mode: CodeCanvasView.Mode, preserveScroll: Bool) {
        animationTimer?.invalidate()
        let origin = scrollView.contentView.bounds.origin
        canvas.setDocument(doc, mode: mode)
        updateDocumentSize()
        if preserveScroll {
            setOrigin(CGPoint(x: min(origin.x, maxScrollX), y: min(origin.y, maxScrollY)))
        } else {
            setOrigin(.zero)
        }
    }

    func setMode(_ mode: CodeCanvasView.Mode) {
        canvas.setMode(mode)
        updateDocumentSize()
    }

    func scrollBy(dx: CGFloat, dy: CGFloat) {
        animationTimer?.invalidate()
        let origin = scrollView.contentView.bounds.origin
        setOrigin(CGPoint(x: min(max(0, origin.x + dx), maxScrollX), y: min(max(0, origin.y + dy), maxScrollY)))
    }

    func scroll(toY target: CGFloat, animated: Bool) {
        animationTimer?.invalidate()
        animationTimer = nil
        let destination = min(max(0, target), maxScrollY)
        let start = scrollView.contentView.bounds.origin
        guard animated, abs(destination - start.y) > 1, window != nil else {
            setOrigin(CGPoint(x: start.x, y: destination))
            return
        }
        // A short ease-out; long jumps are capped so they still feel instant.
        let began = CACurrentMediaTime()
        let duration = 0.16
        let from = abs(destination - start.y) > 2400 ? destination - (destination > start.y ? 2400 : -2400) : start.y
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            let t = min(1, (CACurrentMediaTime() - began) / duration)
            MainActor.assumeIsolated {
                guard let self else { return }
                let eased = 1 - pow(1 - t, 3)
                self.setOrigin(CGPoint(x: self.scrollView.contentView.bounds.origin.x, y: from + (destination - from) * eased))
                if t >= 1 { self.animationTimer = nil }
            }
            if t >= 1 || self == nil { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Scrolls so `row` sits `fraction` of the way down the viewport.
    func scroll(toRow row: Int, fraction: CGFloat = 0.25, animated: Bool) {
        scroll(toY: CGFloat(row) * canvas.codeFont.lineHeight - bounds.height * fraction, animated: animated)
    }

    /// Row currently at the top of the viewport.
    var topRow: Int { Int(scrollY / canvas.codeFont.lineHeight) }
    var visibleRowCount: Int { Int(bounds.height / canvas.codeFont.lineHeight) }
}
