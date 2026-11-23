import AppKit
import CoreText
import QuartzCore

struct TextPosition: Comparable, Sendable {
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
    /// Vim modal state, pending keys, or cursor position changed.
    func canvas(_ canvas: CodeCanvasView, didUpdateVimState state: VimUIState)
    /// A Vim command triggered an IDE / viewer action (`line` is 0-based, `column` is 0-based UTF-16).
    func canvas(_ canvas: CodeCanvasView, performVimAction action: VimAction, line: Int, column: Int)
    /// Records a jump origin (0-based right-pane line & UTF-16 column) before a Vim jump motion or distant click.
    func canvas(_ canvas: CodeCanvasView, recordJumpOrigin origin: TextPosition)
    /// The move badge on change `hunkIndex` was clicked: jump to its paired counterpart hunk.
    func canvas(_ canvas: CodeCanvasView, jumpToMoveCounterpart hunkIndex: Int)
    /// A collapsed unchanged-code fold bar was clicked: expand `segmentIndex`.
    func canvas(_ canvas: CodeCanvasView, expandFoldSegment segmentIndex: Int)
    /// The user clicked inside change `index`: switch the focused hunk to it without scrolling.
    func canvas(_ canvas: CodeCanvasView, didSelectHunk index: Int)
    /// A pinned sticky header line was clicked (`line` is 0-based buffer line on `side`, `slotIndex` is 0-based slot).
    func canvas(_ canvas: CodeCanvasView, didClickStickyLine line: Int, side: Side, slotIndex: Int)
}

// MARK: - Layers

/// A layer that never animates implicitly: everything on the canvas is positioned by hand.
private class StillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

private final class StillShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

private final class StillGradientLayer: CAGradientLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

/// Rasterises one sticky header row's gutter or syntax-highlighted text with the same CoreText pipeline as `TileLayer`.
private final class StickyTileLayer: CALayer {
    enum Kind { case gutter, text }

    weak var canvas: CodeCanvasView?
    var kind = Kind.text
    var paneSide = Side.right
    var sourceSide = Side.right
    var sourceLine = 0
    var unifiedRowIndex: Int?
    var isHovered = false
    var drawOffsetX: CGFloat = 0

    override init() { super.init() }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let other = layer as? StickyTileLayer else { return }
        canvas = other.canvas
        kind = other.kind
        paneSide = other.paneSide
        sourceSide = other.sourceSide
        sourceLine = other.sourceLine
        unifiedRowIndex = other.unifiedRowIndex
        isHovered = other.isHovered
        drawOffsetX = other.drawOffsetX
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in ctx: CGContext) {
        nonisolated(unsafe) let tile = self, context = ctx
        MainActor.assumeIsolated { tile.canvas?.drawStickyTile(tile, in: context) }
    }
}

private final class StickySlotRow {
    let rowLayer = StillLayer()
    let diffTintLayer = StillLayer()
    let textClipLayer = StillLayer()
    let textLayer = StickyTileLayer()
    let gutterLayer = StickyTileLayer()
    var renderKey = ""

    init(slotIndex: Int, paneSide: Side) {
        rowLayer.anchorPoint = .zero
        rowLayer.masksToBounds = true
        rowLayer.zPosition = CGFloat(20 - slotIndex)

        diffTintLayer.anchorPoint = .zero
        diffTintLayer.zPosition = 0.5
        diffTintLayer.isHidden = true
        rowLayer.addSublayer(diffTintLayer)

        textClipLayer.anchorPoint = .zero
        textClipLayer.masksToBounds = true
        textClipLayer.zPosition = 1
        rowLayer.addSublayer(textClipLayer)

        textLayer.kind = .text
        textLayer.paneSide = paneSide
        textLayer.anchorPoint = .zero
        textClipLayer.addSublayer(textLayer)

        gutterLayer.kind = .gutter
        gutterLayer.paneSide = paneSide
        gutterLayer.anchorPoint = .zero
        gutterLayer.zPosition = 2
        rowLayer.addSublayer(gutterLayer)
    }
}

private final class StickyPaneOverlay {
    let side: Side
    let container = StillLayer()
    let border = StillLayer()
    let shadow = StillGradientLayer()
    var slots: [StickySlotRow] = []

    init(side: Side) {
        self.side = side
        container.anchorPoint = .zero
        container.masksToBounds = true
        container.zPosition = 12
        container.isHidden = true

        shadow.anchorPoint = .zero
        shadow.zPosition = 12.1
        shadow.startPoint = CGPoint(x: 0.5, y: 0)
        shadow.endPoint = CGPoint(x: 0.5, y: 1)
        shadow.isHidden = true

        border.anchorPoint = .zero
        border.zPosition = 12.2
        border.isHidden = true
    }
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

    func set(_ rects: [CGRect], color: CGColor, radius: CGFloat = 0, borderColor: CGColor? = nil, borderWidth: CGFloat = 0) {
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
            layer.borderColor = borderColor
            layer.borderWidth = borderWidth
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
    /// 4 colour buckets: modified (0), added (1), deleted (2), moved (3).
    let lines: [RectGroup]
    /// Pales the bands of lines that stay out of the commit.
    let excluded: RectGroup
    let marks: [RectGroup]
    let focusedTop: RectGroup
    let focusedBottom: RectGroup
    /// Subtle frame + tint highlighting both ends of a hovered move connector pair.
    let moveHighlight: RectGroup
    let words: [RectGroup]
    /// Cross-hunk identifier rename highlights (6 coordinated palette slots).
    let renames: [RectGroup]
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
        lines = (0..<4).map { _ in RectGroup(host: band, z: 0) }
        excluded = RectGroup(host: band, z: 0.5)
        marks = (0..<4).map { _ in RectGroup(host: band, z: 1) }
        focusedTop = RectGroup(host: band, z: 1.5)
        focusedBottom = RectGroup(host: band, z: 1.5)
        moveHighlight = RectGroup(host: band, z: 1.55)
        words = (0..<4).map { _ in RectGroup(host: text, z: 0) }
        renames = (0..<RenameGroup.paletteCount).map { _ in RectGroup(host: text, z: 0.6) }
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
        (lines + marks + words + renames
            + [excluded, focusedTop, focusedBottom, moveHighlight, hits, currentHit, selection]).forEach { $0.clear() }
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
            stickyRenderEpoch &+= 1
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
        didSet {
            if selection != oldValue {
                if !isApplyingVimSelection {
                    if !vimModeEnabled, vimEngine.mode.isVisual {
                        vimEngine.resetToNormal(switchInputSource: false)
                    }
                    if let sel = selection, mode != .sideBySide || sel.pane == .right {
                        vimCursor = linePosition(sel.head)
                    }
                }
                refreshRelativeLineNumbersIfNeeded()
                invalidate(.selection)
                reportVimStateIfNeeded()
                if let sel = selection, let src = source(pane: sel.pane, row: sel.head.row) {
                    notifyActiveLine(side: src.side, line: src.line)
                }
            }
        }
    }

    var focusedHunk: Int? {
        didSet {
            if focusedHunk != oldValue {
                invalidate(.decor)
                if let index = focusedHunk, let doc = document, doc.hunks.indices.contains(index) {
                    let h = doc.hunks[index]
                    if h.rightCount > 0 {
                        notifyActiveLine(side: .right, line: h.rightStart, force: true)
                    } else if h.leftCount > 0 {
                        notifyActiveLine(side: .left, line: h.leftStart, force: true)
                    }
                }
            }
        }
    }

    /// A line to tint, e.g. the target of "go to line" or a search hit.
    var focusLine: (side: Side, line: Int)? {
        didSet { invalidate(.decor) }
    }

    // MARK: SemanticDiff folding, move connectors & move badges

    private enum PaneDisplayRow: Equatable {
        case line(side: Side, line: Int)
        case foldBar(DiffFoldRegion)
    }

    private enum UnifiedDisplayRow {
        case unified(UnifiedRow)
        case foldBar(DiffFoldRegion)
    }

    private struct FoldedSegment {
        var segmentIndex: Int
        var virtualStart: Int
        var leftRowStart: Int
        var leftRowCount: Int
        var rightRowStart: Int
        var rightRowCount: Int
        var leftLineStart: Int
        var leftLineCount: Int
        var rightLineStart: Int
        var rightLineCount: Int
        var hunk: Int
        var foldRegion: DiffFoldRegion?
        var leftFoldRow: Int?
        var rightFoldRow: Int?
        var span: Int { max(leftRowCount, rightRowCount) }
    }

    private(set) var collapseUnchanged: Bool = false
    private(set) var expandedFoldSegments: Set<Int> = []
    private var isFoldingActive: Bool = false
    private var foldedSegments: [FoldedSegment] = []
    private var foldedVirtualLineCount: Int = 0
    private var leftPaneRows: [PaneDisplayRow] = []
    private var rightPaneRows: [PaneDisplayRow] = []
    private var unifiedDisplayRows: [UnifiedDisplayRow] = []
    private var hunkLeftDisplayStart: [Int] = []
    private var hunkRightDisplayStart: [Int] = []

    private var foldBarLayers: [StillLayer] = []
    private var foldBarHits: [(rect: CGRect, segmentIndex: Int)] = []
    private var foldBarGlyphs: [String: CGImage] = [:]
    private var hoveredFoldSegment: Int? {
        didSet { if hoveredFoldSegment != oldValue { invalidate(.scroll) } }
    }
    private var pressedFoldSegment: Int?

    private struct MovePair {
        var pairID: Int
        var sourceHunk: Int
        var targetHunk: Int
    }

    private struct MoveConnectorHit {
        var pairID: Int
        var sourceHunk: Int
        var targetHunk: Int
        var bothVisible: Bool
        var clickSourceHunk: Int
        var fillPath: CGPath
        var spineSamples: [CGPoint]
        var bounds: CGRect
    }

    private final class MoveConnectorLayerSet {
        let fill = StillShapeLayer()
        let stroke = StillShapeLayer()

        init(host: CALayer) {
            fill.strokeColor = nil
            fill.zPosition = 0.2

            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineJoin = .round
            stroke.zPosition = 1.2

            host.addSublayer(fill)
            host.addSublayer(stroke)
        }

        func setHidden(_ hidden: Bool) {
            fill.isHidden = hidden
            stroke.isHidden = hidden
        }

        func setZPositions(fill fillZ: CGFloat, stroke strokeZ: CGFloat) {
            fill.zPosition = fillZ
            stroke.zPosition = strokeZ
        }
    }

    private var movePairs: [MovePair] = []
    private var moveConnectorLayers: [MoveConnectorLayerSet] = []
    private var moveConnectorHits: [MoveConnectorHit] = []
    private var hoveredMoveConnector: Int? {
        didSet { if hoveredMoveConnector != oldValue { invalidate([.scroll, .decor]) } }
    }
    private var pressedMoveConnector: MoveConnectorHit?

    private var moveBadgeLayers: [StillLayer] = []
    private var moveBadgeHits: [(rect: CGRect, hunk: Int)] = []
    private var moveBadgeGlyphs: [String: CGImage] = [:]
    private var hoveredMoveBadge: Int? {
        didSet { if hoveredMoveBadge != oldValue { invalidate([.scroll, .decor]) } }
    }
    private var pressedMoveBadge: Int?

    /// Pair ID currently hovered via either a bridge move curve or a move badge.
    private var activeHoveredMovePairID: Int? {
        if let hoveredMoveConnector { return hoveredMoveConnector }
        if let badge = hoveredMoveBadge, let doc = document, doc.hunks.indices.contains(badge) {
            return doc.hunks[badge].moveInfo?.pairID
        }
        return nil
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
            stickyRenderEpoch &+= 1
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
    private var strongNumberCache: [Int: CTLine] = [:]
    private var signLines: [CTLine] = []

    // MARK: Sticky Lines state

    var stickyLinesEnabled: Bool = true {
        didSet {
            guard stickyLinesEnabled != oldValue else { return }
            if stickyLinesEnabled {
                if !stickyScopesLoaded {
                    rebuildStickyBufferScopes()
                }
            } else {
                stickyReextractTimer?.invalidate()
                stickyReextractTimer = nil
                hoveredSticky = nil
                pressedSticky = nil
                contextStickyLine = nil
                stickyHits.removeAll(keepingCapacity: true)
                stickyLayoutByPane = [.empty, .empty]
            }
            invalidate(.scroll)
        }
    }
    var stickyLinesMaxCount: Int = StickyLinesEngine.defaultMaxLines {
        didSet {
            let clamped = min(Settings.stickyLinesRange.upperBound, max(Settings.stickyLinesRange.lowerBound, stickyLinesMaxCount))
            if stickyLinesMaxCount != clamped {
                stickyLinesMaxCount = clamped
                return
            }
            guard stickyLinesMaxCount != oldValue else { return }
            invalidate(.scroll)
        }
    }
    private let stickyOverlays = [StickyPaneOverlay(side: .left), StickyPaneOverlay(side: .right)]
    private var leftStickyScopes: [StickyScope] = []
    private var rightStickyScopes: [StickyScope] = []
    private var stickyScopesLoaded = false
    private var leftStickyDisplayScopes: [StickyDisplayScope] = []
    private var rightStickyDisplayScopes: [StickyDisplayScope] = []
    private var stickyLayoutByPane: [StickyLayoutResult] = [.empty, .empty]
    private var stickyHits: [(rect: CGRect, pane: Side, slotIndex: Int, scope: StickyDisplayScope)] = []
    private var hoveredSticky: (pane: Side, slotIndex: Int)? {
        didSet {
            if hoveredSticky?.pane != oldValue?.pane || hoveredSticky?.slotIndex != oldValue?.slotIndex {
                invalidate(.scroll)
            }
        }
    }
    private var pressedSticky: (pane: Side, slotIndex: Int, scope: StickyDisplayScope)?
    private(set) var contextStickyLine: (side: Side, line: Int)?
    private var stickyRenderEpoch: UInt64 = 0
    private var stickyReextractTimer: Timer?
    /// Virtual row at which each hunk starts, in the current mode.
    private var hunkRows: [Int] = []
    private var draggingRuler = false
    private var dragSelecting = false

    private let root = StillLayer()
    private let panes = [Pane(side: .left), Pane(side: .right)]
    private let connector = StillLayer()
    private var ribbons: [StillShapeLayer] = []
    private let ribbonOutline = StillShapeLayer()
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

    // MARK: Vim state

    let vimEngine = VimEngine()
    var vimModeEnabled: Bool = true {
        didSet {
            guard vimModeEnabled != oldValue else { return }
            if !vimModeEnabled {
                vimEngine.resetToNormal(switchInputSource: false)
            }
            if vimRelativeLineNumbers {
                panes[1].dropGutterTiles()
                invalidate(.scroll)
            }
            invalidate(.selection)
            reportVimStateIfNeeded(force: true)
        }
    }
    var vimRelativeLineNumbers: Bool = false {
        didSet {
            guard vimRelativeLineNumbers != oldValue else { return }
            lastRelativeCursorLine = -1
            panes[1].dropGutterTiles()
            invalidate(.scroll)
        }
    }
    var vimCursorColor: CGColor? = nil {
        didSet {
            guard vimCursorColor != oldValue else { return }
            invalidate(.selection)
        }
    }
    var vimCursor = TextPosition(row: 0, column: 0)
    var isApplyingVimSelection = false
    private var lastReportedVimState: VimUIState?
    private var lastRelativeCursorLine = -1

    func reportVimStateIfNeeded(force: Bool = false) {
        let state = vimEngine.uiState(cursor: vimCursor)
        if force || state != lastReportedVimState {
            lastReportedVimState = state
            delegate?.canvas(self, didUpdateVimState: state)
        }
    }

    func refreshRelativeLineNumbersIfNeeded() {
        guard vimModeEnabled && vimRelativeLineNumbers else { return }
        if vimCursor.row != lastRelativeCursorLine {
            lastRelativeCursorLine = vimCursor.row
            panes[1].dropGutterTiles()
            invalidate(.scroll)
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
        for _ in 0..<4 {
            let ribbon = StillShapeLayer()
            ribbon.strokeColor = nil
            connector.addSublayer(ribbon)
            ribbons.append(ribbon)
        }
        ribbonOutline.fillColor = nil
        ribbonOutline.lineWidth = 1
        ribbonOutline.zPosition = 1
        connector.addSublayer(ribbonOutline)
        root.addSublayer(connector)

        ruler.anchorPoint = .zero
        rulerThumb.cornerRadius = 3
        ruler.addSublayer(rulerThumb)
        for _ in 0..<4 {
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

        for overlay in stickyOverlays {
            root.addSublayer(overlay.container)
            root.addSublayer(overlay.shadow)
            root.addSublayer(overlay.border)
        }
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

    /// Fires whenever the active line (0-based buffer line on `.left` or `.right`) changes via click, caret/Vim motion,
    /// focused hunk change, document load, edit, rediff, or syntax invalidation.
    var onActiveLineChange: ((Side, Int) -> Void)?
    private var activeLineLocation: (side: Side, line: Int)?
    private var suppressActiveLineNotify = false

    private func notifyActiveLine(side: Side, line: Int, force: Bool = false) {
        guard !suppressActiveLineNotify else { return }
        guard let doc = document, case .text = doc.content else { return }
        let count = doc.buffer(side).lines.count
        guard count > 0 else { return }
        let clamped = max(0, min(line, count - 1))
        let changed = activeLineLocation?.side != side || activeLineLocation?.line != clamped
        if force || changed {
            activeLineLocation = (side, clamped)
            onActiveLineChange?(side, clamped)
        }
    }

    private func notifyActiveLineFromCurrentState(force: Bool = false) {
        guard let doc = document, case .text = doc.content else { return }
        if let loc = activeLineLocation {
            let count = doc.buffer(loc.side).lines.count
            if count > 0 {
                notifyActiveLine(side: loc.side, line: min(loc.line, count - 1), force: force)
                return
            }
        }
        if let sel = selection, let src = source(pane: sel.pane, row: sel.head.row) {
            notifyActiveLine(side: src.side, line: src.line, force: force)
            return
        }
        if !doc.hunks.isEmpty {
            let idx = focusedHunk.flatMap { doc.hunks.indices.contains($0) ? $0 : nil } ?? 0
            let h = doc.hunks[idx]
            if h.rightCount > 0 {
                notifyActiveLine(side: .right, line: h.rightStart, force: force)
            } else if h.leftCount > 0 {
                notifyActiveLine(side: .left, line: h.leftStart, force: force)
            }
            return
        }
        if !doc.right.lines.isEmpty {
            notifyActiveLine(side: .right, line: 0, force: force)
        } else if !doc.left.lines.isEmpty {
            notifyActiveLine(side: .left, line: 0, force: force)
        }
    }

    /// True when `doc` is a newly added / untracked file whose left side has no lines and all hunks are additions.
    static func isAddedOnlyDocument(_ doc: DiffDocument) -> Bool {
        doc.isAddedOnly
    }

    var mode: Mode {
        guard let doc = document else { return .single }
        return (doc.isPlainFile || doc.isAddedOnly) ? .single : requestedMode
    }

    func setDocument(_ doc: DiffDocument?, mode: Mode) {
        document = doc
        activeStyles = theme.styles(for: doc?.language)
        editor = nil
        annotations = nil
        requestedMode = mode
        collapseUnchanged = doc?.semanticOptions.collapseUnchanged ?? false
        expandedFoldSegments = []
        hoveredFoldSegment = nil
        pressedFoldSegment = nil
        hoveredMoveBadge = nil
        pressedMoveBadge = nil
        hoveredMoveConnector = nil
        pressedMoveConnector = nil
        vimEngine.resetToNormal(switchInputSource: false)
        vimCursor = TextPosition(row: 0, column: 0)
        lastRelativeCursorLine = -1
        activeLineLocation = nil
        selection = nil
        focusedHunk = nil
        focusLine = nil
        matches = []
        matchesByLine = [[:], [:]]
        currentMatch = -1
        clearLSPHover()
        contextLSPSymbol = nil
        stickyReextractTimer?.invalidate()
        stickyReextractTimer = nil
        hoveredSticky = nil
        pressedSticky = nil
        contextStickyLine = nil
        stickyHits.removeAll(keepingCapacity: true)
        stickyLayoutByPane = [.empty, .empty]
        invalidateTextCaches()
        rebuildFoldLayout()
        rebuildHunkRows()
        if stickyLinesEnabled {
            rebuildStickyBufferScopes()
        } else {
            leftStickyScopes.removeAll(keepingCapacity: true)
            rightStickyScopes.removeAll(keepingCapacity: true)
            leftStickyDisplayScopes.removeAll(keepingCapacity: true)
            rightStickyDisplayScopes.removeAll(keepingCapacity: true)
            stickyScopesLoaded = false
            stickyRenderEpoch &+= 1
        }
        invalidate(.everything)
        reportVimStateIfNeeded(force: true)
        if doc != nil {
            notifyActiveLineFromCurrentState(force: true)
        }
    }

    func setMode(_ mode: Mode) {
        guard mode != requestedMode else { return }
        // The caret stays on its line; rows mean different things in the two layouts.
        let caret = editSelection
        requestedMode = mode
        selection = nil
        clearLSPHover()
        rebuildFoldLayout()
        rebuildHunkRows()
        if stickyLinesEnabled { rebuildStickyDisplayScopes() }
        if let caret { selection = TextSelection(pane: .right, anchor: rowPosition(caret.anchor), head: rowPosition(caret.head)) }
        invalidate(.everything)
    }

    /// Updates unchanged-region folding without reloading the document, keeping the caret and viewport anchored.
    func setFolding(enabled: Bool, expandedSegments: Set<Int>) {
        guard enabled != collapseUnchanged || expandedSegments != expandedFoldSegments else { return }
        let caret = editSelection
        let anchorLine: Int?
        let beforeY: CGFloat?
        let lh = codeFont.lineHeight
        if let doc = document, case .text = doc.content, !doc.right.lines.isEmpty {
            let line = caret?.head.row ?? (source(pane: .right, row: max(0, Int((resolveScroll().right + lh / 2) / lh)))?.line)
            anchorLine = line
            beforeY = line.map { CGFloat(editRow(forLine: $0)) * lh - resolveScroll().right }
        } else {
            anchorLine = nil
            beforeY = nil
        }
        collapseUnchanged = enabled
        expandedFoldSegments = expandedSegments
        hoveredFoldSegment = nil
        pressedFoldSegment = nil
        clearLSPHover()
        rebuildFoldLayout()
        rebuildHunkRows()
        if stickyLinesEnabled { rebuildStickyDisplayScopes() }
        if let caret {
            selection = TextSelection(pane: .right, anchor: rowPosition(caret.anchor), head: rowPosition(caret.head))
        } else if selection != nil {
            selection = nil
        }
        container?.updateDocumentSize()
        invalidate(.everything)
        if let anchorLine, let beforeY {
            for _ in 0..<4 {
                let after = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
                guard abs(after - beforeY) >= 0.5 else { break }
                container?.scrollBy(dx: 0, dy: after - beforeY)
            }
        }
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
            let tiles: Set<Int>
            if isFoldingActive {
                var set = Set<Int>()
                for line in changedLines {
                    set.insert(displayRow(forLine: line, side: side) / tileRows)
                }
                tiles = set
            } else {
                tiles = Set(changedLines.map { $0 / tileRows })
            }
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
            let rowCount = paneRowCount(.right)
            var tiles = Set<Int>()
            for key in pane.textTiles.keys {
                let first = key.index * tileRows
                let last = min(rowCount, first + tileRows)
                guard first < last else { continue }
                for r in first..<last {
                    guard let src = source(pane: .right, row: r), src.side == side else { continue }
                    if changedLines.contains(src.line) {
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
        stickyRenderEpoch &+= 1
        invalidate(.scroll)
        notifyActiveLineFromCurrentState(force: true)
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
        strongNumberCache.removeAll()
        signLines.removeAll()
        annotationLabels.removeAll()
        cachedParagraphStyle = nil
        stickyRenderEpoch &+= 1
    }

    private func rebuildFoldLayout() {
        foldedSegments.removeAll(keepingCapacity: true)
        leftPaneRows.removeAll(keepingCapacity: true)
        rightPaneRows.removeAll(keepingCapacity: true)
        unifiedDisplayRows.removeAll(keepingCapacity: true)
        hunkLeftDisplayStart.removeAll(keepingCapacity: true)
        hunkRightDisplayStart.removeAll(keepingCapacity: true)
        foldedVirtualLineCount = 0

        guard let doc = document, case .text = doc.content, mode != .single, collapseUnchanged else {
            isFoldingActive = false
            return
        }
        let map = doc.displayMap(expandedSegments: expandedFoldSegments, collapseEnabled: true)
        guard !map.foldRegions.isEmpty else {
            isFoldingActive = false
            return
        }
        isFoldingActive = true

        var foldBySegment: [Int: DiffFoldRegion] = [:]
        foldBySegment.reserveCapacity(map.foldRegions.count)
        for region in map.foldRegions {
            foldBySegment[region.segmentIndex] = region
        }

        hunkLeftDisplayStart = [Int](repeating: 0, count: doc.hunks.count)
        hunkRightDisplayStart = [Int](repeating: 0, count: doc.hunks.count)
        foldedSegments.reserveCapacity(doc.segments.count)

        var virtualRow = 0
        for (segIndex, seg) in doc.segments.enumerated() {
            let leftRowStart = leftPaneRows.count
            let rightRowStart = rightPaneRows.count
            var leftFoldRow: Int?
            var rightFoldRow: Int?

            if let region = foldBySegment[segIndex] {
                let lPrefixEnd = max(seg.leftStart, min(region.leftRange.lowerBound, seg.leftStart + seg.leftCount))
                let lSuffixStart = max(lPrefixEnd, min(region.leftRange.upperBound, seg.leftStart + seg.leftCount))
                if seg.leftStart < lPrefixEnd {
                    for l in seg.leftStart..<lPrefixEnd { leftPaneRows.append(.line(side: .left, line: l)) }
                }
                leftFoldRow = leftPaneRows.count
                leftPaneRows.append(.foldBar(region))
                if lSuffixStart < seg.leftStart + seg.leftCount {
                    for l in lSuffixStart..<(seg.leftStart + seg.leftCount) { leftPaneRows.append(.line(side: .left, line: l)) }
                }

                let rPrefixEnd = max(seg.rightStart, min(region.rightRange.lowerBound, seg.rightStart + seg.rightCount))
                let rSuffixStart = max(rPrefixEnd, min(region.rightRange.upperBound, seg.rightStart + seg.rightCount))
                if seg.rightStart < rPrefixEnd {
                    for r in seg.rightStart..<rPrefixEnd { rightPaneRows.append(.line(side: .right, line: r)) }
                }
                rightFoldRow = rightPaneRows.count
                rightPaneRows.append(.foldBar(region))
                if rSuffixStart < seg.rightStart + seg.rightCount {
                    for r in rSuffixStart..<(seg.rightStart + seg.rightCount) { rightPaneRows.append(.line(side: .right, line: r)) }
                }
            } else {
                if seg.leftCount > 0 {
                    for l in seg.leftStart..<(seg.leftStart + seg.leftCount) {
                        leftPaneRows.append(.line(side: .left, line: l))
                    }
                }
                if seg.rightCount > 0 {
                    for r in seg.rightStart..<(seg.rightStart + seg.rightCount) {
                        rightPaneRows.append(.line(side: .right, line: r))
                    }
                }
                if seg.hunk >= 0, seg.hunk < doc.hunks.count {
                    hunkLeftDisplayStart[seg.hunk] = leftRowStart
                    hunkRightDisplayStart[seg.hunk] = rightRowStart
                }
            }

            let lRowCount = leftPaneRows.count - leftRowStart
            let rRowCount = rightPaneRows.count - rightRowStart
            let foldedSeg = FoldedSegment(
                segmentIndex: segIndex,
                virtualStart: virtualRow,
                leftRowStart: leftRowStart,
                leftRowCount: lRowCount,
                rightRowStart: rightRowStart,
                rightRowCount: rRowCount,
                leftLineStart: seg.leftStart,
                leftLineCount: seg.leftCount,
                rightLineStart: seg.rightStart,
                rightLineCount: seg.rightCount,
                hunk: seg.hunk,
                foldRegion: foldBySegment[segIndex],
                leftFoldRow: leftFoldRow,
                rightFoldRow: rightFoldRow
            )
            foldedSegments.append(foldedSeg)
            virtualRow += foldedSeg.span
        }
        foldedVirtualLineCount = virtualRow

        if mode == .unified {
            let rawRows = doc.unifiedRows
            unifiedDisplayRows.reserveCapacity(rawRows.count)
            var emitted = Set<Int>()
            for uRow in rawRows {
                if uRow.kind == .context {
                    let region: DiffFoldRegion? =
                        (uRow.right >= 0 ? map.foldRegion(containingLine: Int(uRow.right), side: .right) : nil)
                        ?? (uRow.left >= 0 ? map.foldRegion(containingLine: Int(uRow.left), side: .left) : nil)
                    if let region {
                        if emitted.insert(region.segmentIndex).inserted {
                            unifiedDisplayRows.append(.foldBar(region))
                        }
                        continue
                    }
                }
                unifiedDisplayRows.append(.unified(uRow))
            }
        }
    }

    private func rebuildHunkRows() {
        tickStateCache = nil
        guard let doc = document else {
            hunkRows = []
            movePairs = []
            return
        }
        var sourcesByPair: [Int: Int] = [:]
        var targetsByPair: [Int: Int] = [:]
        for (idx, h) in doc.hunks.enumerated() {
            guard let move = h.moveInfo else { continue }
            switch move.role {
            case .source: sourcesByPair[move.pairID] = idx
            case .target: targetsByPair[move.pairID] = idx
            }
        }
        movePairs = sourcesByPair.keys.sorted().compactMap { pairID in
            guard let src = sourcesByPair[pairID], let dst = targetsByPair[pairID] else { return nil }
            return MovePair(pairID: pairID, sourceHunk: src, targetHunk: dst)
        }
        switch mode {
        case .sideBySide:
            var rows = [Int](repeating: 0, count: doc.hunks.count)
            if isFoldingActive {
                for s in foldedSegments where s.hunk >= 0 && s.hunk < rows.count { rows[s.hunk] = s.virtualStart }
            } else {
                for s in doc.segments where s.hunk >= 0 { rows[s.hunk] = s.virtualStart }
            }
            hunkRows = rows
        case .unified:
            var rows = [Int](repeating: 0, count: doc.hunks.count)
            var seen = -1
            if isFoldingActive {
                for (index, item) in unifiedDisplayRows.enumerated() {
                    if case .unified(let row) = item, row.hunk > Int32(seen) {
                        seen = Int(row.hunk)
                        if seen < rows.count { rows[seen] = index }
                    }
                }
            } else {
                for (index, row) in doc.unifiedRows.enumerated() where row.hunk > Int32(seen) {
                    seen = Int(row.hunk)
                    rows[seen] = index
                }
            }
            hunkRows = rows
        case .single:
            hunkRows = []
        }
    }

    /// Display row in `.sideBySide` pane space for 0-based buffer `line` on `side`.
    private func displayRow(forLine line: Int, side: Side) -> Int {
        guard isFoldingActive, !foldedSegments.isEmpty else { return line }
        let clampedLine = max(0, line)
        var lo = 0, hi = foldedSegments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = side == .left ? foldedSegments[mid].leftLineStart : foldedSegments[mid].rightLineStart
            if start <= clampedLine { lo = mid } else { hi = mid - 1 }
        }
        var idx = lo
        while idx >= 0 {
            let s = foldedSegments[idx]
            let start = side == .left ? s.leftLineStart : s.rightLineStart
            let count = side == .left ? s.leftLineCount : s.rightLineCount
            let rowStart = side == .left ? s.leftRowStart : s.rightRowStart
            if count > 0, clampedLine >= start, clampedLine < start + count {
                if let region = s.foldRegion, let foldRow = (side == .left ? s.leftFoldRow : s.rightFoldRow) {
                    let foldRange = side == .left ? region.leftRange : region.rightRange
                    if foldRange.contains(clampedLine) { return foldRow }
                    if clampedLine < foldRange.lowerBound { return rowStart + (clampedLine - start) }
                    return foldRow + 1 + (clampedLine - foldRange.upperBound)
                }
                return rowStart + (clampedLine - start)
            }
            if start < clampedLine && count > 0 { break }
            idx -= 1
        }
        let maxRow = max(0, (side == .left ? leftPaneRows.count : rightPaneRows.count) - 1)
        return min(clampedLine, maxRow)
    }

    private func hunkDisplayStart(_ hunkIndex: Int, side: Side) -> Int {
        guard let doc = document, doc.hunks.indices.contains(hunkIndex) else { return 0 }
        if isFoldingActive {
            return side == .left ? hunkLeftDisplayStart[hunkIndex] : hunkRightDisplayStart[hunkIndex]
        }
        let h = doc.hunks[hunkIndex]
        return side == .left ? h.leftStart : h.rightStart
    }

    private func foldedVirtualPosition(of line: Int, side: Side) -> Double {
        let targetRow = displayRow(forLine: line, side: side)
        guard !foldedSegments.isEmpty else { return Double(targetRow) }
        var lo = 0, hi = foldedSegments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            let start = side == .left ? foldedSegments[mid].leftRowStart : foldedSegments[mid].rightRowStart
            if start <= targetRow { lo = mid } else { hi = mid - 1 }
        }
        let s = foldedSegments[lo]
        let start = side == .left ? s.leftRowStart : s.rightRowStart
        let count = side == .left ? s.leftRowCount : s.rightRowCount
        guard count > 0 else { return Double(s.virtualStart) }
        let t = min(1.0, max(0.0, Double(targetRow - start) / Double(count)))
        return Double(s.virtualStart) + Double(s.span) * t
    }

    private func foldedPanePositions(forVirtual v: Double) -> (left: Double, right: Double) {
        guard !foldedSegments.isEmpty else { return (0, 0) }
        if v <= 0 { return (0, 0) }
        if v >= Double(foldedVirtualLineCount) {
            return (Double(leftPaneRows.count), Double(rightPaneRows.count))
        }
        var lo = 0, hi = foldedSegments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if Double(foldedSegments[mid].virtualStart) <= v { lo = mid } else { hi = mid - 1 }
        }
        let s = foldedSegments[lo]
        let span = max(1, s.span)
        let t = min(1.0, max(0.0, (v - Double(s.virtualStart)) / Double(span)))
        return (Double(s.leftRowStart) + Double(s.leftRowCount) * t,
                Double(s.rightRowStart) + Double(s.rightRowCount) * t)
    }

    private func unifiedDisplayRow(forLine line: Int, side: Side) -> Int {
        guard let doc = document else { return 0 }
        guard isFoldingActive else { return doc.unifiedRow(ofLine: line, side: side) }
        for (idx, item) in unifiedDisplayRows.enumerated() {
            switch item {
            case .unified(let r):
                let candidate = side == .left ? Int(r.left) : Int(r.right)
                if candidate == line { return idx }
                if candidate > line { return idx }
            case .foldBar(let region):
                let range = side == .left ? region.leftRange : region.rightRange
                if range.contains(line) { return idx }
                if range.lowerBound > line { return idx }
            }
        }
        return max(0, unifiedDisplayRows.count - 1)
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
        stickyRenderEpoch &+= 1
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
        case .sideBySide: return isFoldingActive ? foldedVirtualLineCount : doc.virtualLineCount
        case .unified: return isFoldingActive ? unifiedDisplayRows.count : doc.unifiedRows.count
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
        case .sideBySide:
            return isFoldingActive ? Int(foldedVirtualPosition(of: line, side: side)) : Int(doc.virtualPosition(of: line, side: side))
        case .unified:
            return unifiedDisplayRow(forLine: line, side: side)
        case .single:
            return line
        }
    }

    private func digits(_ n: Int) -> Int { max(3, String(max(1, n)).count) }

    /// Whole points, so every layer below it lands on a pixel boundary.
    private var gutterWidth: CGFloat {
        guard let doc = document else { return 40 }
        return (CGFloat(digits(doc.maxDisplayLineNumber)) * codeFont.charWidth).rounded(.up) + 20
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
        resolveScroll(forOrigin: scrollOrigin)
    }

    private func resolveScroll(forOrigin origin: CGPoint) -> Scroll {
        let h = bounds.height
        let lh = codeFont.lineHeight
        let pad = bottomPadding
        let maxScroll = max(0, CGFloat(rowCount) * lh + pad - h)
        let y = min(max(origin.y, 0), maxScroll)
        let overscroll = pixelRound(origin.y - y)
        let maxX = max(0, (container?.documentWidth ?? bounds.width) - bounds.width)
        let x = pixelRound(min(max(origin.x, 0), maxX))

        guard mode == .sideBySide, let doc = document else {
            let top = pixelRound(y) + overscroll
            return Scroll(left: top, right: top, x: x, y: y)
        }
        let k = maxScroll > 0 ? y / maxScroll : 0
        let anchor = k * max(0, h - pad)
        let positions = isFoldingActive
            ? foldedPanePositions(forVirtual: Double((y + anchor) / lh))
            : doc.panePositions(forVirtual: Double((y + anchor) / lh))
        let leftTotal = isFoldingActive ? leftPaneRows.count : doc.left.lines.count
        let rightTotal = isFoldingActive ? rightPaneRows.count : doc.right.lines.count
        func top(_ position: Double, _ count: Int) -> CGFloat {
            let limit = max(0, CGFloat(count) * lh + pad - h)
            return pixelRound(min(max(CGFloat(position) * lh - anchor, 0), limit)) + overscroll
        }
        return Scroll(left: top(positions.left, leftTotal),
                      right: top(positions.right, rightTotal), x: x, y: y)
    }

    /// Maps a row in a pane to the buffer line it displays.
    private func source(pane: Side, row: Int) -> (side: Side, line: Int)? {
        guard let doc = document, row >= 0 else { return nil }
        switch mode {
        case .sideBySide:
            if isFoldingActive {
                let rows = pane == .left ? leftPaneRows : rightPaneRows
                guard row < rows.count, case .line(let s, let l) = rows[row] else { return nil }
                return l < doc.buffer(s).lines.count ? (s, l) : nil
            }
            return row < doc.buffer(pane).lines.count ? (pane, row) : nil
        case .unified:
            if isFoldingActive {
                guard row < unifiedDisplayRows.count, case .unified(let r) = unifiedDisplayRows[row] else { return nil }
                return r.kind == .removed ? (.left, Int(r.left)) : (.right, Int(r.right))
            }
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
        case .sideBySide:
            if isFoldingActive { return pane == .left ? leftPaneRows.count : rightPaneRows.count }
            return doc.buffer(pane).lines.count
        case .unified:
            return isFoldingActive ? unifiedDisplayRows.count : doc.unifiedRows.count
        case .single:
            return doc.right.lines.count
        }
    }

    private func visibleRows(top: CGFloat, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lh = codeFont.lineHeight
        let first = min(count - 1, max(0, Int(floor(top / lh))))
        let last = min(count - 1, max(first, Int(floor((top + bounds.height) / lh))))
        return first...last
    }

    /// Index of the first hunk whose displayed end on `side` is at or after `displayRow`.
    private func firstHunk(_ doc: DiffDocument, side: Side, endingAtOrAfter row: Int) -> Int {
        var lo = 0, hi = doc.hunks.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let h = doc.hunks[mid]
            let start = hunkDisplayStart(mid, side: side)
            let count = side == .left ? h.leftCount : h.rightCount
            if start + count < row { lo = mid + 1 } else { hi = mid }
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

    /// Colour bucket index for a hunk: 0 = modified, 1 = added, 2 = deleted, 3 = moved.
    private func hunkBucket(_ hunk: Hunk) -> Int {
        hunk.moveInfo != nil ? 3 : kindIndex(hunk.kind)
    }

    /// Staggers the vertical connector lane inside the bridge when multiple move pairs coexist,
    /// snapped to half-points so 1pt vertical strokes stay crisp.
    private func moveConnectorLaneX(forPairID pairID: Int, totalPairs: Int) -> CGFloat {
        let x1 = connectorWidth
        let raw: CGFloat
        if totalPairs <= 1 {
            raw = x1 * 0.5
        } else {
            let fractions: [CGFloat] = [0.50, 0.38, 0.62, 0.44, 0.56]
            let slot = ((pairID % fractions.count) + fractions.count) % fractions.count
            raw = x1 * fractions[slot]
        }
        return floor(raw) + 0.5
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

    private func numberLine(_ number: Int, strong: Bool = false) -> CTLine {
        if strong {
            if let line = strongNumberCache[number] { return line }
            if strongNumberCache.count > 256 { strongNumberCache.removeAll(keepingCapacity: true) }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(number), attributes: [
                .font: codeFont.font, Self.colorKey: theme.gutterTextStrong,
            ]))
            strongNumberCache[number] = line
            return line
        }
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

    private func drawNumber(_ ctx: CGContext, _ number: Int, rightEdge: CGFloat, y: CGFloat, strong: Bool = false) {
        let line = numberLine(number, strong: strong)
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
                let useRelative = vimModeEnabled && vimRelativeLineNumbers
                let activeLine = vimCursor.row
                for row in firstRow...lastRow {
                    let r: UnifiedRow
                    if isFoldingActive {
                        guard row < unifiedDisplayRows.count, case .unified(let uRow) = unifiedDisplayRows[row] else { continue }
                        r = uRow
                    } else {
                        r = doc.unifiedRows[row]
                    }
                    let y = CGFloat(row - firstRow) * lh
                    if r.left >= 0 {
                        drawNumber(ctx, doc.displayLineNumber(side: .left, line: Int(r.left)), rightEdge: shift + numberWidth - 4, y: y)
                    }
                    if r.right >= 0 {
                        let lineIdx = Int(r.right)
                        let absNum = doc.displayLineNumber(side: .right, line: lineIdx)
                        let shown = useRelative ? (lineIdx == activeLine ? absNum : abs(lineIdx - activeLine)) : absNum
                        drawNumber(ctx, shown, rightEdge: shift + numberWidth * 2 - 4, y: y)
                    }
                    if r.kind != .context {
                        ctx.textPosition = CGPoint(x: shift + numberWidth * 2 + 4, y: y + codeFont.baseline)
                        CTLineDraw(signLine(added: r.kind == .added), ctx)
                    }
                }
            } else {
                // Line numbers hug the divider on both sides, as in IntelliJ.
                let rightEdge = shift + gutterWidth - 10
                let useRelative = vimModeEnabled && vimRelativeLineNumbers && tile.pane == .right
                let activeLine = vimCursor.row
                for row in firstRow...lastRow {
                    guard let src = source(pane: tile.pane, row: row) else { continue }
                    let lineIdx = src.line
                    let absNum = doc.displayLineNumber(side: src.side, line: lineIdx)
                    let shown = useRelative ? (lineIdx == activeLine ? absNum : abs(lineIdx - activeLine)) : absNum
                    drawNumber(ctx, shown, rightEdge: rightEdge, y: CGFloat(row - firstRow) * lh)
                }
            }
        }
    }

    // MARK: Annotate

    /// The line of the right side that a row of the right pane shows, if it shows one.
    private func rightLine(row: Int) -> Int? {
        guard let doc = document, row >= 0 else { return nil }
        switch mode {
        case .sideBySide:
            if isFoldingActive {
                guard row < rightPaneRows.count, case .line(_, let l) = rightPaneRows[row] else { return nil }
                return l < doc.right.lines.count ? l : nil
            }
            return row < doc.right.lines.count ? row : nil
        case .single:
            return row < doc.right.lines.count ? row : nil
        case .unified:
            if isFoldingActive {
                guard row < unifiedDisplayRows.count, case .unified(let r) = unifiedDisplayRows[row] else { return nil }
                return r.right >= 0 ? Int(r.right) : nil
            }
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
        let row = editRow(forLine: line)
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
        let row = editRow(forLine: line)
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
            foldBarHits.removeAll()
            foldBarLayers.forEach { $0.isHidden = true }
            moveBadgeHits.removeAll()
            moveBadgeLayers.forEach { $0.isHidden = true }
            moveConnectorHits.removeAll()
            moveConnectorLayers.forEach { $0.setHidden(true) }
            hideStickyOverlays()
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

        if currentMode == .sideBySide {
            updateConnectors(doc, scroll)
        } else {
            moveConnectorHits.removeAll(keepingCapacity: true)
            moveConnectorLayers.forEach { $0.setHidden(true) }
        }
        updateRuler(doc, scroll, marks: redecorate)
        updateFoldBars(doc, scroll)
        updateRevertButtons(doc, scroll)
        updateStickyLines(doc, scroll)
        updateMoveBadges(doc, scroll)
        updateConflictButtons(doc, scroll)
        updateCaret()
    }

    // MARK: Caret

    /// The caret: at the moving end of the selection in the right side, while the keyboard is here and
    /// the text can be edited (or Vim mode is active on any text document).
    private func updateCaret() {
        guard let doc = document, case .text = doc.content, !doc.right.lines.isEmpty,
              editor != nil || vimModeEnabled,
              let window, window.isKeyWindow || Self.assumeKeyWindow, window.firstResponder === self else {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            caretFrame = .null
            compositionUnderline.clear()
            return
        }

        let headPos: TextPosition
        if vimModeEnabled {
            if mode == .sideBySide, let sel = selection, sel.pane != .right {
                caretLayer.isHidden = true
                caretLayer.removeAllAnimations()
                caretFrame = .null
                compositionUnderline.clear()
                return
            }
            let clamped = TextEditing.clamp(vimCursor, in: doc.right.lines)
            headPos = rowPosition(clamped)
        } else {
            guard let sel = selection, mode != .sideBySide || sel.pane == .right else {
                caretLayer.isHidden = true
                caretLayer.removeAllAnimations()
                caretFrame = .null
                compositionUnderline.clear()
                return
            }
            headPos = sel.head
        }

        guard let src = source(pane: .right, row: headPos.row), src.side == .right else {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            caretFrame = .null
            compositionUnderline.clear()
            return
        }

        let lh = codeFont.lineHeight
        let lineLayout = ctLine(.right, src.line)
        let x0 = textInset + CTLineGetOffsetForStringIndex(lineLayout, headPos.column, nil)

        let frame: CGRect
        let color: CGColor
        let cornerRadius: CGFloat
        let shouldBlink: Bool

        if vimModeEnabled {
            let lineNS = doc.right.lines[src.line] as NSString
            let nextCol = headPos.column < lineNS.length
                ? TextEditing.characterBoundary(in: lineNS, from: headPos.column, forward: true)
                : headPos.column
            let x1 = nextCol > headPos.column
                ? textInset + CTLineGetOffsetForStringIndex(lineLayout, nextCol, nil)
                : x0 + codeFont.charWidth
            let isTab = headPos.column < lineNS.length && lineNS.character(at: headPos.column) == 0x09
            // On tabs, place block/underline carets in the trailing single-character cell (like GoLand IdeaVim).
            let blockX = isTab ? max(x0, x1 - codeFont.charWidth) : x0
            let charWidth = isTab ? codeFont.charWidth : max(codeFont.charWidth, x1 - x0)
            let baseColor = vimCursorColor ?? theme.text

            switch vimEngine.mode {
            case .insert:
                // guicursor=i:ver1 -> crisp 1.5pt vertical bar
                frame = CGRect(x: pixelRound(x0 - 0.75), y: CGFloat(headPos.row) * lh, width: 1.5, height: lh)
                color = baseColor
                cornerRadius = 0
                shouldBlink = true
            case .normal where vimEngine.isReplaceCharPending:
                // guicursor=r:hor50 -> half-height underline block
                frame = CGRect(x: pixelRound(blockX), y: pixelRound(CGFloat(headPos.row) * lh + lh * 0.5),
                               width: pixelRound(charWidth), height: pixelRound(lh * 0.5))
                color = baseColor.copy(alpha: baseColor.alpha * 0.65) ?? baseColor
                cornerRadius = 1
                shouldBlink = false
            case .normal:
                // Normal mode: translucent block cursor
                frame = CGRect(x: pixelRound(blockX), y: CGFloat(headPos.row) * lh,
                               width: pixelRound(charWidth), height: lh)
                color = baseColor.copy(alpha: baseColor.alpha * 0.42) ?? baseColor
                cornerRadius = 1
                shouldBlink = false
            case .visual, .visualLine:
                // guicursor=v:hor10 -> underline caret indicator alongside selection highlight
                let h = max(2, (lh * 0.14).rounded())
                frame = CGRect(x: pixelRound(blockX), y: CGFloat(headPos.row) * lh + lh - h,
                               width: pixelRound(charWidth), height: h)
                color = baseColor
                cornerRadius = 0
                shouldBlink = false
            case .commandLine:
                frame = CGRect(x: pixelRound(blockX), y: CGFloat(headPos.row) * lh,
                               width: pixelRound(charWidth), height: lh)
                color = baseColor.copy(alpha: baseColor.alpha * 0.25) ?? baseColor
                cornerRadius = 1
                shouldBlink = false
            }
        } else {
            frame = CGRect(x: pixelRound(x0 - 1), y: CGFloat(headPos.row) * lh, width: 2, height: lh)
            color = theme.text
            cornerRadius = 0
            shouldBlink = true
        }

        let needsAnimationReset = frame != caretFrame || caretLayer.isHidden || (shouldBlink != (caretLayer.animation(forKey: "blink") != nil))
        caretLayer.cornerRadius = cornerRadius
        caretLayer.backgroundColor = color
        if needsAnimationReset {
            caretFrame = frame
            caretLayer.frame = frame
            caretLayer.isHidden = false
            caretLayer.removeAllAnimations()
            if shouldBlink {
                // Solid while it moves, blinking once it rests.
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
        }

        // What an input method is still composing is underlined in place.
        if let marked = editor?.marked {
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
    var caretColor: CGColor? { caretLayer.backgroundColor }

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
        switch mode {
        case .single:
            return TextEditing.clamp(position, in: doc.right.lines)
        case .sideBySide:
            guard isFoldingActive else { return TextEditing.clamp(position, in: doc.right.lines) }
            guard !rightPaneRows.isEmpty else { return TextPosition(row: 0, column: 0) }
            let row = min(max(0, position.row), rightPaneRows.count - 1)
            switch rightPaneRows[row] {
            case .line(_, let line):
                return TextEditing.clamp(TextPosition(row: line, column: position.column), in: doc.right.lines)
            case .foldBar(let region):
                return TextEditing.clamp(TextPosition(row: region.rightRange.lowerBound, column: 0), in: doc.right.lines)
            }
        case .unified:
            if isFoldingActive {
                guard !unifiedDisplayRows.isEmpty else { return TextPosition(row: 0, column: 0) }
                var row = min(max(0, position.row), unifiedDisplayRows.count - 1)
                while row < unifiedDisplayRows.count {
                    switch unifiedDisplayRows[row] {
                    case .unified(let r):
                        if r.right >= 0 {
                            let col = row == position.row ? position.column : 0
                            return TextEditing.clamp(TextPosition(row: Int(r.right), column: col), in: doc.right.lines)
                        }
                    case .foldBar(let region):
                        return TextEditing.clamp(TextPosition(row: region.rightRange.lowerBound, column: 0), in: doc.right.lines)
                    }
                    row += 1
                }
                let last = doc.right.lines.count - 1
                return TextPosition(row: last, column: doc.right.lines[last].utf16.count)
            }
            let rows = doc.unifiedRows
            guard !rows.isEmpty else { return TextPosition(row: 0, column: 0) }
            var row = min(max(0, position.row), rows.count - 1)
            if rows[row].right >= 0 { return TextEditing.clamp(TextPosition(row: Int(rows[row].right), column: position.column), in: doc.right.lines) }
            while row < rows.count, rows[row].right < 0 { row += 1 }
            if row < rows.count { return TextPosition(row: Int(rows[row].right), column: 0) }
            let last = doc.right.lines.count - 1
            return TextPosition(row: last, column: doc.right.lines[last].utf16.count)
        }
    }

    /// A position in the right side as a row of the right pane.
    func rowPosition(_ position: TextPosition) -> TextPosition {
        TextPosition(row: editRow(forLine: position.row), column: position.column)
    }

    func editRow(forLine line: Int) -> Int {
        guard document != nil else { return line }
        switch mode {
        case .single: return line
        case .sideBySide: return isFoldingActive ? displayRow(forLine: line, side: .right) : line
        case .unified: return unifiedDisplayRow(forLine: line, side: .right)
        }
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

    var gutterDigits: Int { document.map { digits($0.maxDisplayLineNumber) } ?? 3 }

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

        if mode == .unified || isFoldingActive || gutterDigits != gutterDigitsBefore {
            // Rows of the unified or folded view can shift across segments; a wider gutter moves everything.
            right.dropTiles()
            if isFoldingActive || gutterDigits != gutterDigitsBefore { panes[0].dropTiles() }
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
        stickyRenderEpoch &+= 1
        rebuildFoldLayout()
        rebuildHunkRows()
        if stickyLinesEnabled {
            for outcome in outcomes {
                rightStickyScopes = StickyLinesEngine.shiftScopes(rightStickyScopes, by: outcome.raw)
            }
            rebuildStickyDisplayScopes()
            scheduleStickyReextract()
        }
        invalidate([.decor, .selection, .scroll])
        container?.updateDocumentSize()
        notifyActiveLineFromCurrentState(force: true)
    }

    /// New hunks for the text on screen (the real diff, back from git): the line with the caret, or the
    /// top line, stays where it is on screen while the two sides line up again around it.
    func hunksDidChange(_ change: () -> Void) {
        clearLSPHover()
        guard let doc = document else { change(); return }
        let lh = codeFont.lineHeight
        let caret = editSelection
        let anchorLine = caret?.head.row ?? (source(pane: .right, row: max(0, Int((resolveScroll().right + lh / 2) / lh)))?.line ?? 0)
        let before = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
        let wasFolded = isFoldingActive
        change()
        if let focused = focusedHunk, focused >= doc.hunks.count { focusedHunk = nil }
        stickyRenderEpoch &+= 1
        rebuildFoldLayout()
        rebuildHunkRows()
        if stickyLinesEnabled { rebuildStickyDisplayScopes() }
        if mode == .unified || wasFolded || isFoldingActive {
            panes[1].dropTiles()
            if wasFolded || isFoldingActive { panes[0].dropTiles() }
        }
        if let caret { selection = TextSelection(pane: .right, anchor: rowPosition(caret.anchor), head: rowPosition(caret.head)) }
        invalidate([.decor, .selection, .scroll])
        container?.updateDocumentSize()
        for _ in 0..<4 {
            let after = CGFloat(editRow(forLine: anchorLine)) * lh - resolveScroll().right
            guard abs(after - before) >= 0.5 else { break }
            container?.scrollBy(dx: 0, dy: after - before)
        }
        notifyActiveLineFromCurrentState(force: true)
    }

    /// Scrolls just enough to bring the caret into view, with a little room around it.
    func revealCaret() {
        guard let container, let doc = document, !doc.right.lines.isEmpty else { return }
        guard editor != nil || vimModeEnabled else { return }
        let headRow: Int
        let line: TextPosition
        if vimModeEnabled {
            if mode == .sideBySide, let sel = selection, sel.pane != .right { return }
            line = TextEditing.clamp(vimCursor, in: doc.right.lines)
            headRow = editRow(forLine: line.row)
        } else {
            guard let sel = selection, mode != .sideBySide || sel.pane == .right else { return }
            headRow = sel.head.row
            line = linePosition(sel.head)
        }
        let lh = codeFont.lineHeight
        let margin = codeFont.charWidth * 4
        let width = textRect(.right).width
        for _ in 0..<4 {
            let scroll = resolveScroll()
            let stickyH = stickyHeight(for: .right, at: scroll)
            let topClearance = min(stickyH + lh * 0.5, max(lh * 0.5, bounds.height - lh * 2))
            let y = CGFloat(headRow) * lh - scroll.right
            var dy: CGFloat = 0
            if y < topClearance {
                dy = y - topClearance
            } else if y + lh * 1.5 > bounds.height {
                dy = y + lh * 1.5 - bounds.height
            }
            var dx: CGFloat = 0
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

    /// Change bands, word-level highlights, rename boxes, search hits and focus markers for a window of rows.
    private func rebuildDecor(_ pane: Pane, _ doc: DiffDocument, rows: Range<Int>) {
        let lh = codeFont.lineHeight
        let bandWidth = pane.band.bounds.width
        var lines = [[CGRect]](repeating: [], count: 4)
        var marks = [[CGRect]](repeating: [], count: 4)
        var words = [[CGRect]](repeating: [], count: 4)
        var renameRects = [[CGRect]](repeating: [], count: RenameGroup.paletteCount)
        var moveHoverRects: [CGRect] = []
        var excluded: [CGRect] = []
        var focusedTopRects: [CGRect] = [], focusedBottomRects: [CGRect] = []
        var focusedTopColor = theme.focusedBorder(.modified), focusedBottomColor = theme.focusedBorder(.modified)
        let ticks = commitTicks
        var lineColors = [theme.modified, theme.added, theme.deleted, theme.moved]
        let markColors = lineColors
        var wordColors = [theme.modifiedWord, theme.addedWord, theme.deletedWord, theme.movedWord]
        let hasRenames = !doc.renameGroups.isEmpty
        let hoveredMovePair = activeHoveredMovePairID
        let focusedMovePairID: Int? = focusedHunk.flatMap { idx in
            doc.hunks.indices.contains(idx) ? doc.hunks[idx].moveInfo?.pairID : nil
        }

        switch mode {
        case .sideBySide:
            let side = pane.side
            var index = firstHunk(doc, side: side, endingAtOrAfter: rows.lowerBound)
            while index < doc.hunks.count {
                let hunk = doc.hunks[index]
                let displayStart = hunkDisplayStart(index, side: side)
                let lineStart = side == .left ? hunk.leftStart : hunk.rightStart
                let n = side == .left ? hunk.leftCount : hunk.rightCount
                if displayStart > rows.upperBound { break }
                let k = hunkBucket(hunk)
                let isFocused = focusedHunk == index
                    || (focusedMovePairID != nil && hunk.moveInfo?.pairID == focusedMovePairID)
                if n == 0 {
                    // Moved source/target blocks never draw a fake 0-height gap hairline on the opposite pane.
                    if hunk.moveInfo == nil {
                        let rect = CGRect(x: 0, y: CGFloat(displayStart) * lh - 1, width: bandWidth, height: 2)
                        if isFocused {
                            focusedTopRects.append(rect)
                            focusedTopColor = theme.focusedBorder(for: hunk)
                        } else {
                            marks[k].append(rect)
                        }
                    }
                } else {
                    // Clipped to the window so a huge hunk never makes a huge layer.
                    let a = max(displayStart, rows.lowerBound), b = min(displayStart + n, rows.upperBound)
                    if a < b {
                        let y = CGFloat(a) * lh, height = CGFloat(b - a) * lh
                        let rect = CGRect(x: 0, y: y, width: bandWidth, height: height)
                        lines[k].append(rect)
                        if let move = hunk.moveInfo, let hoveredMovePair, move.pairID == hoveredMovePair {
                            moveHoverRects.append(rect)
                        }
                        if isFocused {
                            let borderColor = theme.focusedBorder(for: hunk)
                            if displayStart >= rows.lowerBound {
                                focusedTopRects.append(CGRect(x: 0, y: CGFloat(displayStart) * lh, width: bandWidth, height: 1))
                                focusedTopColor = borderColor
                            }
                            if displayStart + n <= rows.upperBound {
                                focusedBottomRects.append(CGRect(x: 0, y: CGFloat(displayStart + n) * lh - 1, width: bandWidth, height: 1))
                                focusedBottomColor = borderColor
                            }
                        }
                        let lineA = lineStart + (a - displayStart)
                        let lineB = lineStart + (b - displayStart)
                        if let ticks { appendExcluded(ticks, side: side, lines: lineA..<lineB, row: a, width: bandWidth, to: &excluded) }
                        let inline: [[Range<Int>]]
                        if let move = hunk.moveInfo, let moveInline = move.inlineDiff, hunk.kind != .modified {
                            inline = (side == .left && move.role == .source) ? moveInline.source
                                : ((side == .right && move.role == .target) ? moveInline.target : [])
                        } else {
                            inline = side == .left ? hunk.leftInline : hunk.rightInline
                        }
                        // `inline` may be empty or shorter than the hunk.
                        var r = a
                        let inlineEndRow = min(b, displayStart + inline.count)
                        while r < inlineEndRow {
                            let offset = r - displayStart
                            let line = lineStart + offset
                            // A line that stays out of the commit is pale, without the words that changed in it.
                            if ticks?.isExcluded(side, line) != true {
                                let rawRanges = inline[offset]
                                let filteredRanges: [Range<Int>]
                                if hasRenames, !rawRanges.isEmpty {
                                    filteredRanges = rawRanges.filter {
                                        doc.renameColorIndex(hunkIndex: index, side: side, lineIndex: line, range: $0) == nil
                                    }
                                } else {
                                    filteredRanges = rawRanges
                                }
                                appendRects(filteredRanges, side: side, line: line, row: r, to: &words[k])
                            }
                            r += 1
                        }
                    }
                }
                index += 1
            }

        case .unified:
            lineColors = [theme.added, theme.removedLine, theme.removedLine, theme.moved]
            wordColors = [theme.addedWord, theme.removedWord, theme.removedWord, theme.movedWord]
            let totalRows = paneRowCount(.right)
            let end = min(rows.upperBound, totalRows)
            func unifiedRowAt(_ idx: Int) -> UnifiedRow? {
                if isFoldingActive {
                    guard idx < unifiedDisplayRows.count, case .unified(let r) = unifiedDisplayRows[idx] else { return nil }
                    return r
                }
                return doc.unifiedRows[idx]
            }
            var row = rows.lowerBound
            while row < end {
                guard let first = unifiedRowAt(row), first.kind != .context else { row += 1; continue }
                var next = row + 1
                while next < end, let u = unifiedRowAt(next), u.kind == first.kind, u.hunk == first.hunk { next += 1 }
                let hunkIdx = Int(first.hunk)
                let hunk: Hunk? = (hunkIdx >= 0 && hunkIdx < doc.hunks.count) ? doc.hunks[hunkIdx] : nil
                let isMoved = hunk?.moveInfo != nil
                let group = isMoved ? 3 : (first.kind == .added ? 0 : 1)
                let rect = CGRect(x: 0, y: CGFloat(row) * lh, width: bandWidth, height: CGFloat(next - row) * lh)
                lines[group].append(rect)
                if let move = hunk?.moveInfo, let hoveredMovePair, move.pairID == hoveredMovePair {
                    moveHoverRects.append(rect)
                }
                if let ticks {
                    let side: Side = first.kind == .added ? .right : .left
                    let firstLine = Int(side == .left ? first.left : first.right)
                    appendExcluded(ticks, side: side, lines: firstLine..<(firstLine + next - row), row: row, width: bandWidth, to: &excluded)
                }
                if let hunk {
                    for i in row..<next {
                        guard let u = unifiedRowAt(i) else { continue }
                        if first.kind == .removed {
                            let line = Int(u.left), offset = line - hunk.leftStart
                            let inlineArr: [[Range<Int>]] = (isMoved && hunk.kind != .modified && hunk.moveInfo?.role == .source)
                                ? (hunk.moveInfo?.inlineDiff?.source ?? [])
                                : hunk.leftInline
                            if offset >= 0, offset < inlineArr.count, ticks?.isExcluded(.left, line) != true {
                                let raw = inlineArr[offset]
                                let filtered = hasRenames ? raw.filter {
                                    doc.renameColorIndex(hunkIndex: hunkIdx, side: .left, lineIndex: line, range: $0) == nil
                                } : raw
                                let wordSlot = isMoved ? 3 : 1
                                appendRects(filtered, side: .left, line: line, row: i, to: &words[wordSlot])
                            }
                        } else {
                            let line = Int(u.right), offset = line - hunk.rightStart
                            let inlineArr: [[Range<Int>]] = (isMoved && hunk.kind != .modified && hunk.moveInfo?.role == .target)
                                ? (hunk.moveInfo?.inlineDiff?.target ?? [])
                                : hunk.rightInline
                            if offset >= 0, offset < inlineArr.count, ticks?.isExcluded(.right, line) != true {
                                let raw = inlineArr[offset]
                                let filtered = hasRenames ? raw.filter {
                                    doc.renameColorIndex(hunkIndex: hunkIdx, side: .right, lineIndex: line, range: $0) == nil
                                } : raw
                                let wordSlot = isMoved ? 3 : 0
                                appendRects(filtered, side: .right, line: line, row: i, to: &words[wordSlot])
                            }
                        }
                    }
                }
                row = next
            }
            if let focused = focusedHunk, doc.hunks.indices.contains(focused), focused < hunkRows.count {
                let hunk = doc.hunks[focused]
                let hunkStart = hunkRows[focused]
                let hunkEnd = hunkStart + hunk.leftCount + hunk.rightCount
                if hunkStart < hunkEnd, hunkEnd <= totalRows, hunkStart < end, hunkEnd > rows.lowerBound {
                    if hunkStart >= rows.lowerBound {
                        focusedTopRects.append(CGRect(x: 0, y: CGFloat(hunkStart) * lh, width: bandWidth, height: 1))
                        focusedTopColor = hunk.moveInfo != nil ? theme.movedBorder : (hunk.leftCount > 0 ? theme.removedBorder : theme.addedBorder)
                    }
                    if hunkEnd <= end {
                        focusedBottomRects.append(CGRect(x: 0, y: CGFloat(hunkEnd) * lh - 1, width: bandWidth, height: 1))
                        focusedBottomColor = hunk.moveInfo != nil ? theme.movedBorder : (hunk.rightCount > 0 ? theme.addedBorder : theme.removedBorder)
                    }
                }
            }

        case .single:
            break
        }

        // Cross-hunk identifier rename highlights (coordinated 6-color fill + 1pt rounded border).
        if hasRenames, mode != .single {
            let slotCount = RenameGroup.paletteCount
            for row in rows {
                guard let src = source(pane: pane.side, row: row) else { continue }
                if ticks?.isExcluded(src.side, src.line) == true { continue }
                let occs = doc.renameOccurrences(side: src.side, lineIndex: src.line)
                guard !occs.isEmpty else { continue }
                let layout = ctLine(src.side, src.line)
                for occ in occs {
                    let x0 = CTLineGetOffsetForStringIndex(layout, occ.range.lowerBound, nil)
                    let x1 = CTLineGetOffsetForStringIndex(layout, occ.range.upperBound, nil)
                    guard x1 > x0 else { continue }
                    let slot = ((occ.colorIndex % slotCount) + slotCount) % slotCount
                    let rect = CGRect(x: max(0, textInset + x0 - 1), y: CGFloat(row) * lh + 1,
                                      width: (x1 - x0) + 2, height: lh - 2)
                    renameRects[slot].append(rect)
                }
            }
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
            case .sideBySide: if focus.side == pane.side { focusRow = displayRow(forLine: focus.line, side: focus.side) }
            case .unified: focusRow = unifiedDisplayRow(forLine: focus.line, side: focus.side)
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

        for k in 0..<4 {
            pane.lines[k].set(lines[k], color: lineColors[k])
            pane.marks[k].set(marks[k], color: markColors[k])
            pane.words[k].set(words[k], color: wordColors[k], radius: 2.5)
        }
        for slot in 0..<RenameGroup.paletteCount {
            let style = theme.renameStyle(at: slot)
            pane.renames[slot].set(renameRects[slot], color: style.fill, radius: 3, borderColor: style.border, borderWidth: 1)
        }
        pane.moveHighlight.set(
            moveHoverRects,
            color: theme.movedAccent.copy(alpha: theme.isDark ? 0.10 : 0.07) ?? theme.moved,
            borderColor: theme.movedBorder.copy(alpha: theme.isDark ? 0.92 : 0.85) ?? theme.movedBorder,
            borderWidth: 1
        )
        pane.focusedTop.set(focusedTopRects, color: focusedTopColor)
        pane.focusedBottom.set(focusedBottomRects, color: focusedBottomColor)
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

    /// The curved ribbons joining each change across the divider, plus SemanticDiff-style
    /// cross-position curves connecting paired moved blocks.
    private func updateConnectors(_ doc: DiffDocument, _ scroll: Scroll) {
        let lh = codeFont.lineHeight
        let h = bounds.height
        let x1 = connectorWidth
        let bend = connectorWidth * 0.5
        let firstLeft = max(0, Int(floor(scroll.left / lh))), firstRight = max(0, Int(floor(scroll.right / lh)))
        var index = min(firstHunk(doc, side: .left, endingAtOrAfter: firstLeft),
                        firstHunk(doc, side: .right, endingAtOrAfter: firstRight))
        let fills = [CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath()]
        var outlinePath: CGMutablePath?
        var outlineColor: CGColor?
        while index < doc.hunks.count {
            let hunk = doc.hunks[index]
            var l0 = CGFloat(hunkDisplayStart(index, side: .left)) * lh - scroll.left
            var l1 = l0 + CGFloat(hunk.leftCount) * lh
            var r0 = CGFloat(hunkDisplayStart(index, side: .right)) * lh - scroll.right
            var r1 = r0 + CGFloat(hunk.rightCount) * lh
            if min(l0, r0) > h { break }
            // Moved blocks use cross-position S-curves below instead of fake 0-height gap ribbons.
            if hunk.moveInfo != nil {
                index += 1
                continue
            }
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
                let bucket = hunkBucket(hunk)
                fills[bucket].addPath(path)

                if index == focusedHunk {
                    let stroke = CGMutablePath()
                    let topL = l0 + 0.5, topR = r0 + 0.5
                    let botL = l1 - 0.5, botR = r1 - 0.5
                    stroke.move(to: CGPoint(x: 0, y: topL))
                    stroke.addCurve(to: CGPoint(x: x1, y: topR), control1: CGPoint(x: bend, y: topL), control2: CGPoint(x: x1 - bend, y: topR))
                    stroke.move(to: CGPoint(x: 0, y: botL))
                    stroke.addCurve(to: CGPoint(x: x1, y: botR), control1: CGPoint(x: bend, y: botL), control2: CGPoint(x: x1 - bend, y: botR))
                    outlinePath = stroke
                    outlineColor = theme.focusedBorder(for: hunk)
                }
            }
            index += 1
        }
        let scale = backingScale
        let colors = [theme.modified, theme.added, theme.deleted, theme.moved]
        for k in 0..<4 {
            ribbons[k].contentsScale = scale
            ribbons[k].fillColor = colors[k]
            ribbons[k].path = fills[k].isEmpty ? nil : fills[k]
        }
        ribbonOutline.contentsScale = scale
        ribbonOutline.strokeColor = outlineColor
        ribbonOutline.path = outlinePath
        updateMoveConnectors(doc, scroll)
    }

    /// Smooth diff-style funnels at each visible moved block joined by a restrained 1pt
    /// connecting line along the bridge's lane, matching regular diff ribbons in geometry and tone.
    private func updateMoveConnectors(_ doc: DiffDocument, _ scroll: Scroll) {
        moveConnectorHits.removeAll(keepingCapacity: true)
        guard !movePairs.isEmpty, bounds.height > 1 else {
            moveConnectorLayers.forEach { $0.setHidden(true) }
            if hoveredMoveConnector != nil { hoveredMoveConnector = nil }
            return
        }

        let lh = codeFont.lineHeight
        let h = bounds.height
        let x1 = connectorWidth
        let scale = backingScale
        let hoveredPair = activeHoveredMovePairID
        let totalPairs = movePairs.count
        let maxLead: CGFloat = 16.0
        let unselectedHalfWidth: CGFloat = 1.0
        let kappa: CGFloat = 0.55228475

        func visibleMid(top: CGFloat, bottom: CGFloat) -> CGFloat {
            let visTop = max(top, 0)
            let visBot = min(bottom, h)
            return (visTop + visBot) * 0.5
        }

        func appendCubicSamples(p0: CGPoint, c1: CGPoint, c2: CGPoint, p3: CGPoint, steps: Int = 6, to pts: inout [CGPoint]) {
            if pts.isEmpty { pts.append(p0) }
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                let mt = 1 - t
                let mt2 = mt * mt
                let t2 = t * t
                let x = mt2 * mt * p0.x + 3 * mt2 * t * c1.x + 3 * mt * t2 * c2.x + t2 * t * p3.x
                let y = mt2 * mt * p0.y + 3 * mt2 * t * c1.y + 3 * mt * t2 * c2.y + t2 * t * p3.y
                pts.append(CGPoint(x: x, y: y))
            }
        }

        func addHorizToVert(_ path: CGMutablePath, from p0: CGPoint, to p3: CGPoint) {
            let c1 = CGPoint(x: p0.x + (p3.x - p0.x) * kappa, y: p0.y)
            let c2 = CGPoint(x: p3.x, y: p3.y + (p0.y - p3.y) * kappa)
            path.addCurve(to: p3, control1: c1, control2: c2)
        }

        func addVertToHoriz(_ path: CGMutablePath, from p0: CGPoint, to p3: CGPoint) {
            let c1 = CGPoint(x: p0.x, y: p0.y + (p3.y - p0.y) * kappa)
            let c2 = CGPoint(x: p3.x + (p0.x - p3.x) * kappa, y: p3.y)
            path.addCurve(to: p3, control1: c1, control2: c2)
        }

        func sampleHorizToVert(from p0: CGPoint, to p3: CGPoint, steps: Int = 8, to pts: inout [CGPoint]) {
            let c1 = CGPoint(x: p0.x + (p3.x - p0.x) * kappa, y: p0.y)
            let c2 = CGPoint(x: p3.x, y: p3.y + (p0.y - p3.y) * kappa)
            appendCubicSamples(p0: p0, c1: c1, c2: c2, p3: p3, steps: steps, to: &pts)
        }

        func sampleVertToHoriz(from p0: CGPoint, to p3: CGPoint, steps: Int = 8, to pts: inout [CGPoint]) {
            let c1 = CGPoint(x: p0.x, y: p0.y + (p3.y - p0.y) * kappa)
            let c2 = CGPoint(x: p3.x + (p0.x - p3.x) * kappa, y: p3.y)
            appendCubicSamples(p0: p0, c1: c1, c2: c2, p3: p3, steps: steps, to: &pts)
        }

        func addEdgeChevron(x: CGFloat, pointingUp: Bool, to stroke: CGMutablePath) {
            let tipY: CGFloat = pointingUp ? 1.5 : (h - 1.5)
            let inward: CGFloat = pointingUp ? 1 : -1
            let halfW: CGFloat = 2.8
            let armH: CGFloat = 3.0
            stroke.move(to: CGPoint(x: x - halfW, y: tipY + inward * armH))
            stroke.addLine(to: CGPoint(x: x, y: tipY))
            stroke.addLine(to: CGPoint(x: x + halfW, y: tipY + inward * armH))
        }

        var used = 0
        for pair in movePairs {
            guard doc.hunks.indices.contains(pair.sourceHunk),
                  doc.hunks.indices.contains(pair.targetHunk) else { continue }
            let src = doc.hunks[pair.sourceHunk]
            let dst = doc.hunks[pair.targetHunk]
            let rawSrcTop = CGFloat(hunkDisplayStart(pair.sourceHunk, side: .left)) * lh - scroll.left
            let rawSrcBottom = rawSrcTop + CGFloat(max(1, src.leftCount)) * lh
            let rawDstTop = CGFloat(hunkDisplayStart(pair.targetHunk, side: .right)) * lh - scroll.right
            let rawDstBottom = rawDstTop + CGFloat(max(1, dst.rightCount)) * lh

            let srcVisible = rawSrcBottom >= 0 && rawSrcTop <= h
            let dstVisible = rawDstBottom >= 0 && rawDstTop <= h
            guard srcVisible || dstVisible else { continue }

            let l0 = max(rawSrcTop, -h), l1 = min(rawSrcBottom, 2 * h)
            let r0 = max(rawDstTop, -h), r1 = min(rawDstBottom, 2 * h)

            let laneX = moveConnectorLaneX(forPairID: pair.pairID, totalPairs: totalPairs)
            let isHovered = hoveredPair == pair.pairID
            let isFocused = focusedHunk == pair.sourceHunk || focusedHunk == pair.targetHunk
            let isActive = isFocused || isHovered
            let hw = unselectedHalfWidth

            let fillPath = CGMutablePath()
            let strokePath = CGMutablePath()
            var spineSamples: [CGPoint] = []
            let clickSourceHunk: Int

            if srcVisible && dstVisible {
                let lMid = visibleMid(top: rawSrcTop, bottom: rawSrcBottom)
                let rMid = visibleMid(top: rawDstTop, bottom: rawDstBottom)
                let dir: CGFloat = rMid >= lMid ? 1 : -1
                let nearGap = dir < 0 ? (l0 - r1) : (r0 - l1)

                if nearGap < 14 {
                    let bend = x1 * 0.5
                    fillPath.move(to: CGPoint(x: 0, y: l0))
                    fillPath.addCurve(to: CGPoint(x: x1, y: r0), control1: CGPoint(x: bend, y: l0), control2: CGPoint(x: x1 - bend, y: r0))
                    fillPath.addLine(to: CGPoint(x: x1, y: r1))
                    fillPath.addCurve(to: CGPoint(x: 0, y: l1), control1: CGPoint(x: x1 - bend, y: r1), control2: CGPoint(x: bend, y: l1))
                    fillPath.closeSubpath()

                    if isActive {
                        let topL = min(l0 + 0.5, lMid), botL = max(l1 - 0.5, lMid)
                        let topR = min(r0 + 0.5, rMid), botR = max(r1 - 0.5, rMid)
                        strokePath.move(to: CGPoint(x: 0, y: topL))
                        strokePath.addCurve(to: CGPoint(x: x1, y: topR), control1: CGPoint(x: bend, y: topL), control2: CGPoint(x: x1 - bend, y: topR))
                        strokePath.move(to: CGPoint(x: 0, y: botL))
                        strokePath.addCurve(to: CGPoint(x: x1, y: botR), control1: CGPoint(x: bend, y: botL), control2: CGPoint(x: x1 - bend, y: botR))
                    }

                    appendCubicSamples(
                        p0: CGPoint(x: 0, y: lMid),
                        c1: CGPoint(x: bend, y: lMid),
                        c2: CGPoint(x: x1 - bend, y: rMid),
                        p3: CGPoint(x: x1, y: rMid),
                        steps: 10,
                        to: &spineSamples
                    )
                } else {
                    let lead = min(maxLead, nearGap * 0.45)
                    let yJoinL: CGFloat = dir < 0 ? (l0 - lead) : (l1 + lead)
                    let yJoinR: CGFloat = dir < 0 ? (r1 + lead) : (r0 - lead)

                    if !isActive {
                        let xInner = dir < 0 ? (laneX - hw) : (laneX + hw)
                        let xOuter = dir < 0 ? (laneX + hw) : (laneX - hw)
                        fillPath.move(to: CGPoint(x: 0, y: l0))
                        addHorizToVert(fillPath, from: CGPoint(x: 0, y: l0), to: CGPoint(x: xInner, y: yJoinL))
                        fillPath.addLine(to: CGPoint(x: xInner, y: yJoinR))
                        addVertToHoriz(fillPath, from: CGPoint(x: xInner, y: yJoinR), to: CGPoint(x: x1, y: r0))
                        fillPath.addLine(to: CGPoint(x: x1, y: r1))
                        addHorizToVert(fillPath, from: CGPoint(x: x1, y: r1), to: CGPoint(x: xOuter, y: yJoinR))
                        fillPath.addLine(to: CGPoint(x: xOuter, y: yJoinL))
                        addVertToHoriz(fillPath, from: CGPoint(x: xOuter, y: yJoinL), to: CGPoint(x: 0, y: l1))
                        fillPath.closeSubpath()
                    } else {
                        let joinL = CGPoint(x: laneX, y: yJoinL)
                        let joinR = CGPoint(x: laneX, y: yJoinR)
                        fillPath.move(to: CGPoint(x: 0, y: l0))
                        addHorizToVert(fillPath, from: CGPoint(x: 0, y: l0), to: joinL)
                        addVertToHoriz(fillPath, from: joinL, to: CGPoint(x: 0, y: l1))
                        fillPath.closeSubpath()

                        fillPath.move(to: joinR)
                        addVertToHoriz(fillPath, from: joinR, to: CGPoint(x: x1, y: r0))
                        fillPath.addLine(to: CGPoint(x: x1, y: r1))
                        addHorizToVert(fillPath, from: CGPoint(x: x1, y: r1), to: joinR)
                        fillPath.closeSubpath()

                        let topL = min(l0 + 0.5, lMid), botL = max(l1 - 0.5, lMid)
                        let topR = min(r0 + 0.5, rMid), botR = max(r1 - 0.5, rMid)
                        strokePath.move(to: CGPoint(x: 0, y: topL))
                        addHorizToVert(strokePath, from: CGPoint(x: 0, y: topL), to: joinL)
                        strokePath.move(to: CGPoint(x: 0, y: botL))
                        addHorizToVert(strokePath, from: CGPoint(x: 0, y: botL), to: joinL)

                        strokePath.move(to: joinL)
                        strokePath.addLine(to: joinR)

                        strokePath.move(to: joinR)
                        addVertToHoriz(strokePath, from: joinR, to: CGPoint(x: x1, y: topR))
                        strokePath.move(to: joinR)
                        addVertToHoriz(strokePath, from: joinR, to: CGPoint(x: x1, y: botR))
                    }

                    sampleHorizToVert(from: CGPoint(x: 0, y: lMid), to: CGPoint(x: laneX, y: yJoinL), to: &spineSamples)
                    spineSamples.append(CGPoint(x: laneX, y: yJoinR))
                    sampleVertToHoriz(from: CGPoint(x: laneX, y: yJoinR), to: CGPoint(x: x1, y: rMid), to: &spineSamples)
                }
                clickSourceHunk = (focusedHunk == pair.targetHunk) ? pair.targetHunk : pair.sourceHunk
            } else if srcVisible {
                let lMid = visibleMid(top: rawSrcTop, bottom: rawSrcBottom)
                let goingUp = rawDstBottom < 0
                let edgeY: CGFloat = goingUp ? 0 : h
                let availNear = goingUp ? (l0 - edgeY) : (edgeY - l1)
                let showChevron = isActive && abs(edgeY - lMid) > 10
                let endY: CGFloat = showChevron ? (goingUp ? 1.5 : (h - 1.5)) : edgeY
                let yJoinL: CGFloat
                if availNear >= 4 {
                    let lead = min(maxLead, availNear * 0.65)
                    yJoinL = goingUp ? max(endY, l0 - lead) : min(endY, l1 + lead)
                } else {
                    yJoinL = goingUp ? min(l0, endY) : max(l1, endY)
                }

                if !isActive {
                    let xInner = goingUp ? (laneX - hw) : (laneX + hw)
                    let xOuter = goingUp ? (laneX + hw) : (laneX - hw)
                    fillPath.move(to: CGPoint(x: 0, y: l0))
                    addHorizToVert(fillPath, from: CGPoint(x: 0, y: l0), to: CGPoint(x: xInner, y: yJoinL))
                    fillPath.addLine(to: CGPoint(x: xInner, y: endY))
                    fillPath.addLine(to: CGPoint(x: xOuter, y: endY))
                    fillPath.addLine(to: CGPoint(x: xOuter, y: yJoinL))
                    addVertToHoriz(fillPath, from: CGPoint(x: xOuter, y: yJoinL), to: CGPoint(x: 0, y: l1))
                    fillPath.closeSubpath()
                } else {
                    let joinL = CGPoint(x: laneX, y: yJoinL)
                    fillPath.move(to: CGPoint(x: 0, y: l0))
                    addHorizToVert(fillPath, from: CGPoint(x: 0, y: l0), to: joinL)
                    addVertToHoriz(fillPath, from: joinL, to: CGPoint(x: 0, y: l1))
                    fillPath.closeSubpath()

                    let topL = min(l0 + 0.5, lMid), botL = max(l1 - 0.5, lMid)
                    strokePath.move(to: CGPoint(x: 0, y: topL))
                    addHorizToVert(strokePath, from: CGPoint(x: 0, y: topL), to: joinL)
                    strokePath.move(to: CGPoint(x: 0, y: botL))
                    addHorizToVert(strokePath, from: CGPoint(x: 0, y: botL), to: joinL)
                    if abs(endY - yJoinL) > 0.25 {
                        strokePath.move(to: joinL)
                        strokePath.addLine(to: CGPoint(x: laneX, y: endY))
                    }
                    if showChevron {
                        addEdgeChevron(x: laneX, pointingUp: goingUp, to: strokePath)
                    }
                }

                sampleHorizToVert(from: CGPoint(x: 0, y: lMid), to: CGPoint(x: laneX, y: yJoinL), to: &spineSamples)
                if abs(endY - yJoinL) > 0.25 {
                    spineSamples.append(CGPoint(x: laneX, y: endY))
                }
                clickSourceHunk = pair.sourceHunk
            } else {
                let rMid = visibleMid(top: rawDstTop, bottom: rawDstBottom)
                let fromAbove = rawSrcBottom < 0
                let edgeY: CGFloat = fromAbove ? 0 : h
                let availNear = fromAbove ? (r0 - edgeY) : (edgeY - r1)
                let showChevron = isActive && abs(rMid - edgeY) > 10
                let startY: CGFloat = showChevron ? (fromAbove ? 1.5 : (h - 1.5)) : edgeY
                let yJoinR: CGFloat
                if availNear >= 4 {
                    let lead = min(maxLead, availNear * 0.65)
                    yJoinR = fromAbove ? max(startY, r0 - lead) : min(startY, r1 + lead)
                } else {
                    yJoinR = fromAbove ? min(r0, startY) : max(r1, startY)
                }

                if !isActive {
                    let xTop = fromAbove ? (laneX + hw) : (laneX - hw)
                    let xBot = fromAbove ? (laneX - hw) : (laneX + hw)
                    fillPath.move(to: CGPoint(x: xBot, y: startY))
                    fillPath.addLine(to: CGPoint(x: xTop, y: startY))
                    fillPath.addLine(to: CGPoint(x: xTop, y: yJoinR))
                    addVertToHoriz(fillPath, from: CGPoint(x: xTop, y: yJoinR), to: CGPoint(x: x1, y: r0))
                    fillPath.addLine(to: CGPoint(x: x1, y: r1))
                    addHorizToVert(fillPath, from: CGPoint(x: x1, y: r1), to: CGPoint(x: xBot, y: yJoinR))
                    fillPath.closeSubpath()
                } else {
                    let joinR = CGPoint(x: laneX, y: yJoinR)
                    fillPath.move(to: joinR)
                    addVertToHoriz(fillPath, from: joinR, to: CGPoint(x: x1, y: r0))
                    fillPath.addLine(to: CGPoint(x: x1, y: r1))
                    addHorizToVert(fillPath, from: CGPoint(x: x1, y: r1), to: joinR)
                    fillPath.closeSubpath()

                    if showChevron {
                        addEdgeChevron(x: laneX, pointingUp: fromAbove, to: strokePath)
                    }
                    if abs(yJoinR - startY) > 0.25 {
                        strokePath.move(to: CGPoint(x: laneX, y: startY))
                        strokePath.addLine(to: joinR)
                    }
                    let topR = min(r0 + 0.5, rMid), botR = max(r1 - 0.5, rMid)
                    strokePath.move(to: joinR)
                    addVertToHoriz(strokePath, from: joinR, to: CGPoint(x: x1, y: topR))
                    strokePath.move(to: joinR)
                    addVertToHoriz(strokePath, from: joinR, to: CGPoint(x: x1, y: botR))
                }

                spineSamples.append(CGPoint(x: laneX, y: startY))
                if abs(yJoinR - startY) > 0.25 {
                    spineSamples.append(CGPoint(x: laneX, y: yJoinR))
                }
                sampleVertToHoriz(from: CGPoint(x: laneX, y: yJoinR), to: CGPoint(x: x1, y: rMid), to: &spineSamples)
                clickSourceHunk = pair.targetHunk
            }

            if used == moveConnectorLayers.count {
                moveConnectorLayers.append(MoveConnectorLayerSet(host: connector))
            }
            let layerSet = moveConnectorLayers[used]
            used += 1

            let fillColor: CGColor
            let strokeColor: CGColor
            let lineWidth: CGFloat
            let lineCap: CAShapeLayerLineCap
            if isHovered {
                fillColor = theme.moved.copy(alpha: theme.isDark ? 0.28 : 0.20) ?? theme.moved
                strokeColor = theme.movedBorder.copy(alpha: theme.isDark ? 0.92 : 0.85) ?? theme.movedBorder
                lineWidth = 1.5
                lineCap = .round
                layerSet.setZPositions(fill: 0.6, stroke: 2.2)
            } else if isFocused {
                fillColor = theme.moved
                strokeColor = theme.movedBorder
                lineWidth = 1.0
                lineCap = .round
                layerSet.setZPositions(fill: 0.4, stroke: 1.6)
            } else {
                fillColor = theme.moved
                strokeColor = theme.moved
                lineWidth = 1.0
                lineCap = .round
                layerSet.setZPositions(fill: 0.1, stroke: 0.15)
            }

            layerSet.fill.contentsScale = scale
            layerSet.fill.fillColor = fillColor
            layerSet.fill.path = fillPath.isEmpty ? nil : fillPath

            layerSet.stroke.contentsScale = scale
            layerSet.stroke.strokeColor = strokeColor
            layerSet.stroke.lineWidth = lineWidth
            layerSet.stroke.lineCap = lineCap
            layerSet.stroke.path = strokePath.isEmpty ? nil : strokePath
            layerSet.setHidden(false)

            var hitBounds = fillPath.isEmpty ? CGRect.null : fillPath.boundingBoxOfPath
            for pt in spineSamples {
                hitBounds = hitBounds.union(CGRect(origin: pt, size: .zero))
            }
            if !hitBounds.isNull {
                hitBounds = hitBounds.insetBy(dx: -7, dy: -7)
            }
            moveConnectorHits.append(MoveConnectorHit(
                pairID: pair.pairID,
                sourceHunk: pair.sourceHunk,
                targetHunk: pair.targetHunk,
                bothVisible: srcVisible && dstVisible,
                clickSourceHunk: clickSourceHunk,
                fillPath: fillPath,
                spineSamples: spineSamples,
                bounds: hitBounds
            ))
        }

        for layerSet in moveConnectorLayers[used...] {
            layerSet.setHidden(true)
        }
        if let hovered = hoveredMoveConnector, !moveConnectorHits.contains(where: { $0.pairID == hovered }) {
            hoveredMoveConnector = nil
        }
    }

    private func moveConnectorHit(at point: CGPoint) -> MoveConnectorHit? {
        guard mode == .sideBySide, !moveConnectorHits.isEmpty else { return nil }
        let local = CGPoint(x: point.x - paneWidth, y: point.y)
        guard local.x >= 0, local.x <= connectorWidth else { return nil }
        let maxDistSq: CGFloat = 6.5 * 6.5
        var best: (hit: MoveConnectorHit, distSq: CGFloat)?
        for hit in moveConnectorHits where hit.bounds.contains(local) {
            if hit.fillPath.contains(local) {
                return hit
            }
            let pts = hit.spineSamples
            guard pts.count >= 2 else { continue }
            var minDistSq = CGFloat.greatestFiniteMagnitude
            for i in 0..<(pts.count - 1) {
                let d2 = Self.pointToSegmentDistanceSquared(local, pts[i], pts[i + 1])
                if d2 < minDistSq { minDistSq = d2 }
            }
            if minDistSq <= maxDistSq, best == nil || minDistSq < best!.distSq {
                best = (hit, minDistSq)
            }
        }
        return best?.hit
    }

    private static func pointToSegmentDistanceSquared(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x, vy = b.y - a.y
        let lenSq = vx * vx + vy * vy
        guard lenSq > 1e-6 else {
            let dx = p.x - a.x, dy = p.y - a.y
            return dx * dx + dy * dy
        }
        let t = min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / lenSq))
        let px = a.x + t * vx, py = a.y + t * vy
        let dx = p.x - px, dy = p.y - py
        return dx * dx + dy * dy
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
                let l0 = CGFloat(hunkDisplayStart(index, side: .left)) * lh - scroll.left
                let r0 = CGFloat(hunkDisplayStart(index, side: .right)) * lh - scroll.right
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
        guard !conflicts.isEmpty, mode != .single || doc.isPlainFile || Self.isAddedOnlyDocument(doc) else {
            conflictLayers.forEach { $0.isHidden = true }
            return
        }
        let lh = codeFont.lineHeight, h = bounds.height, scale = backingScale
        let right = bounds.width - rulerWidth - 10
        var used = 0
        for (index, block) in conflicts.enumerated() {
            let row = editRow(forLine: block.start)
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

    // MARK: Move badges

    private func updateMoveBadges(_ doc: DiffDocument, _ scroll: Scroll) {
        moveBadgeHits.removeAll(keepingCapacity: true)
        guard mode == .sideBySide || mode == .unified, !doc.hunks.isEmpty else {
            moveBadgeLayers.forEach { $0.isHidden = true }
            return
        }
        let lh = codeFont.lineHeight, h = bounds.height, scale = backingScale
        let sideBySide = mode == .sideBySide
        var index = 0
        if sideBySide {
            index = min(firstHunk(doc, side: .left, endingAtOrAfter: max(0, Int(floor(scroll.left / lh)))),
                        firstHunk(doc, side: .right, endingAtOrAfter: max(0, Int(floor(scroll.right / lh)))))
        } else {
            let topRow = Int(floor(scroll.right / lh))
            var lo = 0, hi = doc.hunks.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if hunkRow(mid) + doc.hunks[mid].leftCount + doc.hunks[mid].rightCount < topRow { lo = mid + 1 } else { hi = mid }
            }
            index = lo
        }
        var used = 0
        while index < doc.hunks.count {
            let hunk = doc.hunks[index]
            let l0 = sideBySide ? CGFloat(hunkDisplayStart(index, side: .left)) * lh - scroll.left : 0
            let r0 = sideBySide ? CGFloat(hunkDisplayStart(index, side: .right)) * lh - scroll.right : CGFloat(hunkRow(index)) * lh - scroll.right
            if sideBySide {
                if min(l0, r0) > h { break }
            } else {
                if r0 > h { break }
            }
            guard let move = hunk.moveInfo else { index += 1; continue }
            let hot = hoveredMoveBadge == index || activeHoveredMovePairID == move.pairID
            let title = Self.moveBadgeTitle(for: move)
            guard let image = moveBadgeGlyph(title, hot: hot) else { index += 1; continue }
            let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)

            let rect: CGRect
            if sideBySide {
                let isSource = move.role == .source && hunk.leftCount > 0
                let topY: CGFloat
                let bottomY: CGFloat
                let rightEdge: CGFloat
                if isSource {
                    topY = l0
                    bottomY = topY + CGFloat(hunk.leftCount) * lh
                    rightEdge = textRect(.left).maxX - 8
                } else {
                    topY = r0
                    bottomY = topY + CGFloat(max(1, hunk.rightCount)) * lh
                    rightEdge = bounds.width - rulerWidth - 10
                }
                guard topY <= h, bottomY >= 0 else { index += 1; continue }
                let topPad = stickyHeight(for: isSource ? .left : .right) + 3
                let rest = topY + (lh - size.height) / 2
                let y = pixelRound(max(rest, min(topPad, bottomY - size.height - 3)))
                let minX = isSource ? 8 : (textRect(.right).minX + 8)
                rect = CGRect(x: pixelRound(max(minX, rightEdge - size.width)), y: y, width: size.width, height: size.height)
            } else {
                let topY = r0
                let bottomY = topY + CGFloat(max(1, hunk.leftCount + hunk.rightCount)) * lh
                guard bottomY >= 0 else { index += 1; continue }
                var rightEdge = bounds.width - rulerWidth - 10
                if showsRevertButtons { rightEdge -= revertSize + 8 }
                if commitTicks != nil { rightEdge -= tickSize + 8 }
                let topPad = stickyHeight(for: .right) + 3
                let rest = topY + (lh - size.height) / 2
                let y = pixelRound(max(rest, min(topPad, bottomY - size.height - 3)))
                rect = CGRect(x: pixelRound(max(textRect(.right).minX + 8, rightEdge - size.width)), y: y, width: size.width, height: size.height)
            }

            if used == moveBadgeLayers.count {
                let layer = StillLayer()
                layer.anchorPoint = .zero
                layer.zPosition = 8
                root.addSublayer(layer)
                moveBadgeLayers.append(layer)
            }
            let layer = moveBadgeLayers[used]
            used += 1
            place(layer, rect)
            layer.contentsScale = scale
            layer.contents = image
            layer.opacity = 1.0
            layer.isHidden = false
            moveBadgeHits.append((rect, index))
            index += 1
        }
        for layer in moveBadgeLayers[used...] { layer.isHidden = true }
        if let hovered = hoveredMoveBadge, !moveBadgeHits.contains(where: { $0.hunk == hovered }) { hoveredMoveBadge = nil }
    }

    private static func moveBadgeTitle(for move: HunkMoveInfo) -> String {
        let pct = Int((move.similarity * 100).rounded())
        let tweaked = move.similarity < 0.999 || move.inlineDiff != nil
        switch move.role {
        case .source:
            return tweaked
                ? L("↗ Moved \(pct)% · edited", "↗ 移动源 \(pct)% · 有微调")
                : L("↗ Moved · 100%", "↗ 移动源 · 100%")
        case .target:
            return tweaked
                ? L("↘ Moved \(pct)% · edited", "↘ 移动目标 \(pct)% · 有微调")
                : L("↘ Moved · 100%", "↘ 移动目标 · 100%")
        }
    }

    private func moveBadgeGlyph(_ title: String, hot: Bool) -> CGImage? {
        let scale = backingScale
        let fontSize = max(9.5, min(11.5, codeFont.size - 1.5))
        let key = "\(title)|\(hot)|\(theme.isDark)|\(scale)|\(fontSize)"
        if let cached = moveBadgeGlyphs[key] { return cached }
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let ink: NSColor = hot ? .white : (NSColor(cgColor: theme.movedAccent) ?? .systemPurple)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width + 14), height: ceil(min(codeFont.lineHeight - 2, textSize.height + 4)))
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let pill = CGPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                          cornerWidth: size.height / 2, cornerHeight: size.height / 2, transform: nil)
        context.addPath(pill)
        context.setFillColor(hot ? theme.movedAccent : theme.background)
        context.fillPath()
        if !hot {
            context.addPath(pill)
            context.setFillColor(theme.moved)
            context.fillPath()
            context.addPath(pill)
            context.setStrokeColor(theme.movedBorder)
            context.setLineWidth(1)
            context.strokePath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: CGPoint(x: 7, y: (size.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        let image = context.makeImage()
        moveBadgeGlyphs[key] = image
        return image
    }

    private func moveBadgeHit(at point: CGPoint) -> Int? {
        moveBadgeHits.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }?.hunk
    }

    // MARK: Sticky Lines

    var visibleStickyLines: (left: [StickyLineSlot], right: [StickyLineSlot]) {
        (stickyLayoutByPane[0].slots, stickyLayoutByPane[1].slots)
    }

    func stickyHeight(for pane: Side) -> CGFloat {
        stickyLayoutByPane[pane.rawValue].height
    }

    private func stickyHeight(for pane: Side, at scroll: Scroll) -> CGFloat {
        guard stickyLinesEnabled, document != nil else { return 0 }
        let currentMode = mode
        guard currentMode == .sideBySide || pane == .right else { return 0 }
        let scopes = pane == .left ? leftStickyDisplayScopes : rightStickyDisplayScopes
        let top = pane == .left ? scroll.left : scroll.right
        return StickyLinesEngine.resolve(
            scopes: scopes,
            scrollTop: top,
            lineHeight: codeFont.lineHeight,
            viewportHeight: bounds.height,
            maxLines: stickyLinesMaxCount
        ).height
    }

    private func hideStickyOverlays() {
        stickyHits.removeAll(keepingCapacity: true)
        stickyLayoutByPane = [.empty, .empty]
        hoveredSticky = nil
        pressedSticky = nil
        for overlay in stickyOverlays {
            overlay.container.isHidden = true
            overlay.border.isHidden = true
            overlay.shadow.isHidden = true
            for slot in overlay.slots { slot.rowLayer.isHidden = true }
        }
    }

    private func scheduleStickyReextract() {
        stickyReextractTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.stickyLinesEnabled,
                      let doc = self.document, case .text = doc.content else { return }
                self.rightStickyScopes = StickyLinesEngine.extractScopes(lines: doc.right.lines, language: doc.language)
                self.rebuildStickyDisplayScopes()
                self.invalidate(.scroll)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        stickyReextractTimer = timer
    }

    private func rebuildStickyBufferScopes() {
        stickyReextractTimer?.invalidate()
        stickyReextractTimer = nil
        guard let doc = document, case .text = doc.content else {
            leftStickyScopes.removeAll(keepingCapacity: true)
            rightStickyScopes.removeAll(keepingCapacity: true)
            leftStickyDisplayScopes.removeAll(keepingCapacity: true)
            rightStickyDisplayScopes.removeAll(keepingCapacity: true)
            stickyScopesLoaded = false
            stickyRenderEpoch &+= 1
            return
        }
        rightStickyScopes = StickyLinesEngine.extractScopes(lines: doc.right.lines, language: doc.language)
        leftStickyScopes = (!doc.isPlainFile && !doc.left.lines.isEmpty)
            ? StickyLinesEngine.extractScopes(lines: doc.left.lines, language: doc.language)
            : []
        stickyScopesLoaded = true
        rebuildStickyDisplayScopes()
    }

    private func rebuildStickyDisplayScopes() {
        stickyRenderEpoch &+= 1
        guard let doc = document, case .text = doc.content else {
            leftStickyDisplayScopes.removeAll(keepingCapacity: true)
            rightStickyDisplayScopes.removeAll(keepingCapacity: true)
            return
        }

        switch mode {
        case .single:
            leftStickyDisplayScopes.removeAll(keepingCapacity: true)
            rightStickyDisplayScopes = rightStickyScopes.map {
                StickyDisplayScope(headerRow: $0.startLine, endRow: $0.endLine, sourceSide: .right, sourceLine: $0.startLine)
            }

        case .sideBySide:
            if !isFoldingActive {
                leftStickyDisplayScopes = leftStickyScopes.map {
                    StickyDisplayScope(headerRow: $0.startLine, endRow: $0.endLine, sourceSide: .left, sourceLine: $0.startLine)
                }
                rightStickyDisplayScopes = rightStickyScopes.map {
                    StickyDisplayScope(headerRow: $0.startLine, endRow: $0.endLine, sourceSide: .right, sourceLine: $0.startLine)
                }
            } else {
                leftStickyDisplayScopes = mapFoldedSideScopes(leftStickyScopes, side: .left)
                rightStickyDisplayScopes = mapFoldedSideScopes(rightStickyScopes, side: .right)
            }

        case .unified:
            leftStickyDisplayScopes.removeAll(keepingCapacity: true)
            var leftLineToRow = [Int](repeating: -1, count: doc.left.lines.count)
            var rightLineToRow = [Int](repeating: -1, count: doc.right.lines.count)
            var isRemovedRow: [Bool]

            if isFoldingActive {
                isRemovedRow = [Bool](repeating: false, count: unifiedDisplayRows.count)
                for (rowIdx, item) in unifiedDisplayRows.enumerated() {
                    switch item {
                    case .unified(let r):
                        if r.left >= 0, Int(r.left) < leftLineToRow.count {
                            leftLineToRow[Int(r.left)] = rowIdx
                        }
                        if r.right >= 0, Int(r.right) < rightLineToRow.count {
                            rightLineToRow[Int(r.right)] = rowIdx
                        }
                        isRemovedRow[rowIdx] = (r.kind == .removed)
                    case .foldBar(let region):
                        for l in region.leftRange where l >= 0 && l < leftLineToRow.count {
                            leftLineToRow[l] = rowIdx
                        }
                        for r in region.rightRange where r >= 0 && r < rightLineToRow.count {
                            rightLineToRow[r] = rowIdx
                        }
                    }
                }
            } else {
                let rawRows = doc.unifiedRows
                isRemovedRow = [Bool](repeating: false, count: rawRows.count)
                for (rowIdx, r) in rawRows.enumerated() {
                    if r.left >= 0, Int(r.left) < leftLineToRow.count {
                        leftLineToRow[Int(r.left)] = rowIdx
                    }
                    if r.right >= 0, Int(r.right) < rightLineToRow.count {
                        rightLineToRow[Int(r.right)] = rowIdx
                    }
                    isRemovedRow[rowIdx] = (r.kind == .removed)
                }
            }

            func mapScopes(_ scopes: [StickyScope], side: Side, table: [Int]) -> [StickyDisplayScope] {
                var out: [StickyDisplayScope] = []
                out.reserveCapacity(scopes.count)
                for s in scopes where s.startLine < table.count && s.endLine < table.count {
                    let h = table[s.startLine]
                    let e = table[s.endLine]
                    if h >= 0 && e >= h + 2 {
                        out.append(StickyDisplayScope(headerRow: h, endRow: e, sourceSide: side, sourceLine: s.startLine))
                    }
                }
                return out
            }

            let rightMapped = mapScopes(rightStickyScopes, side: .right, table: rightLineToRow)
            if doc.right.lines.isEmpty && !doc.left.lines.isEmpty {
                rightStickyDisplayScopes = mapScopes(leftStickyScopes, side: .left, table: leftLineToRow)
            } else if !leftStickyScopes.isEmpty {
                let leftMapped = mapScopes(leftStickyScopes, side: .left, table: leftLineToRow)
                var combined = rightMapped
                for lScope in leftMapped {
                    guard lScope.headerRow < isRemovedRow.count, isRemovedRow[lScope.headerRow] else { continue }
                    let overlapsNewScope = rightMapped.contains { rScope in
                        rScope.headerRow >= lScope.headerRow && rScope.headerRow <= lScope.endRow
                    }
                    if !overlapsNewScope {
                        combined.append(lScope)
                    }
                }
                combined.sort { lhs, rhs in
                    if lhs.headerRow != rhs.headerRow { return lhs.headerRow < rhs.headerRow }
                    if lhs.endRow != rhs.endRow { return lhs.endRow > rhs.endRow }
                    return lhs.sourceSide == .right && rhs.sourceSide != .right
                }
                var normalized: [StickyDisplayScope] = []
                normalized.reserveCapacity(combined.count)
                var stack: [StickyDisplayScope] = []
                for item in combined {
                    if let last = normalized.last, last.headerRow == item.headerRow { continue }
                    while let top = stack.last, item.headerRow >= top.endRow { stack.removeLast() }
                    let clampedEnd = stack.last.map { min(item.endRow, $0.endRow) } ?? item.endRow
                    guard clampedEnd >= item.headerRow + 2 else { continue }
                    let scope = StickyDisplayScope(headerRow: item.headerRow, endRow: clampedEnd, sourceSide: item.sourceSide, sourceLine: item.sourceLine)
                    normalized.append(scope)
                    stack.append(scope)
                }
                rightStickyDisplayScopes = normalized
            } else {
                rightStickyDisplayScopes = rightMapped
            }
        }
    }

    private func mapFoldedSideScopes(_ scopes: [StickyScope], side: Side) -> [StickyDisplayScope] {
        var out: [StickyDisplayScope] = []
        out.reserveCapacity(scopes.count)
        for s in scopes {
            let h = displayRow(forLine: s.startLine, side: side)
            let e = displayRow(forLine: s.endLine, side: side)
            if e >= h + 2 {
                out.append(StickyDisplayScope(headerRow: h, endRow: e, sourceSide: side, sourceLine: s.startLine))
            }
        }
        var normalized: [StickyDisplayScope] = []
        normalized.reserveCapacity(out.count)
        var stack: [StickyDisplayScope] = []
        for item in out {
            if let last = normalized.last, last.headerRow == item.headerRow { continue }
            while let top = stack.last, item.headerRow >= top.endRow { stack.removeLast() }
            let clampedEnd = stack.last.map { min(item.endRow, $0.endRow) } ?? item.endRow
            guard clampedEnd >= item.headerRow + 2 else { continue }
            let scope = StickyDisplayScope(headerRow: item.headerRow, endRow: clampedEnd, sourceSide: item.sourceSide, sourceLine: item.sourceLine)
            normalized.append(scope)
            stack.append(scope)
        }
        return normalized
    }

    private func unifiedRowForDisplayIndex(_ rowIndex: Int) -> UnifiedRow? {
        guard let doc = document, rowIndex >= 0 else { return nil }
        if isFoldingActive {
            guard rowIndex < unifiedDisplayRows.count, case .unified(let uRow) = unifiedDisplayRows[rowIndex] else { return nil }
            return uRow
        }
        guard rowIndex < doc.unifiedRows.count else { return nil }
        return doc.unifiedRows[rowIndex]
    }

    private func stickyDiffColor(for scope: StickyDisplayScope, in doc: DiffDocument) -> CGColor? {
        guard !doc.isPlainFile else { return nil }
        switch mode {
        case .single:
            return nil
        case .sideBySide:
            var idx = firstHunk(doc, side: scope.sourceSide, endingAtOrAfter: scope.headerRow)
            while idx < doc.hunks.count {
                let hunk = doc.hunks[idx]
                let start = hunkDisplayStart(idx, side: scope.sourceSide)
                if start > scope.headerRow { break }
                let count = scope.sourceSide == .left ? hunk.leftCount : hunk.rightCount
                if count > 0, scope.headerRow >= start, scope.headerRow < start + count {
                    return theme.line(for: hunk)
                }
                idx += 1
            }
            return nil
        case .unified:
            guard let uRow = unifiedRowForDisplayIndex(scope.headerRow), uRow.kind != .context else { return nil }
            let hunkIdx = Int(uRow.hunk)
            if hunkIdx >= 0, hunkIdx < doc.hunks.count, doc.hunks[hunkIdx].moveInfo != nil {
                return theme.moved
            }
            return uRow.kind == .added ? theme.added : theme.removedLine
        }
    }

    private func updateStickyLines(_ doc: DiffDocument, _ scroll: Scroll) {
        stickyHits.removeAll(keepingCapacity: true)
        guard stickyLinesEnabled else {
            hideStickyOverlays()
            return
        }
        if !stickyScopesLoaded {
            rebuildStickyBufferScopes()
        }

        let lh = codeFont.lineHeight
        let scale = backingScale
        let currentMode = mode
        let shadowClear = theme.stickyShadow.copy(alpha: 0) ?? theme.stickyShadow

        for paneIndex in 0..<2 {
            let overlay = stickyOverlays[paneIndex]
            let side = overlay.side
            let active = currentMode == .sideBySide || side == .right
            guard active else {
                stickyLayoutByPane[paneIndex] = .empty
                overlay.container.isHidden = true
                overlay.border.isHidden = true
                overlay.shadow.isHidden = true
                continue
            }

            let scopes = side == .left ? leftStickyDisplayScopes : rightStickyDisplayScopes
            let top = side == .left ? scroll.left : scroll.right
            let layout = StickyLinesEngine.resolve(
                scopes: scopes,
                scrollTop: top,
                lineHeight: lh,
                viewportHeight: bounds.height,
                maxLines: stickyLinesMaxCount
            )
            stickyLayoutByPane[paneIndex] = layout

            guard !layout.slots.isEmpty, layout.height >= 0.5 else {
                overlay.container.isHidden = true
                overlay.border.isHidden = true
                overlay.shadow.isHidden = true
                for slot in overlay.slots { slot.rowLayer.isHidden = true }
                continue
            }

            let band = bandRect(side)
            let textR = textRect(side)
            let gutter = gutterSpan(side)
            let overlayHeight = pixelRound(layout.height)
            let textClipX = textR.minX - band.minX
            let textClipW = textR.width

            place(overlay.container, CGRect(x: band.minX, y: 0, width: band.width, height: overlayHeight))
            overlay.container.isHidden = false

            place(overlay.border, CGRect(x: band.minX, y: max(0, overlayHeight - 1), width: band.width, height: 1))
            overlay.border.backgroundColor = theme.stickyBorder
            overlay.border.isHidden = false

            place(overlay.shadow, CGRect(x: band.minX, y: overlayHeight, width: band.width, height: 6))
            overlay.shadow.colors = [theme.stickyShadow, shadowClear]
            overlay.shadow.isHidden = false

            for slot in layout.slots {
                let sIdx = slot.slotIndex
                while overlay.slots.count <= sIdx {
                    let row = StickySlotRow(slotIndex: overlay.slots.count, paneSide: side)
                    row.textLayer.canvas = self
                    row.gutterLayer.canvas = self
                    overlay.container.addSublayer(row.rowLayer)
                    overlay.slots.append(row)
                }
                let row = overlay.slots[sIdx]
                let rowY = pixelRound(slot.y)
                let isHovered = hoveredSticky?.pane == side && hoveredSticky?.slotIndex == sIdx
                let scope = slot.scope

                place(row.rowLayer, CGRect(x: 0, y: rowY, width: band.width, height: lh))
                row.rowLayer.backgroundColor = isHovered ? theme.stickyHoverBg : theme.stickyBg
                row.rowLayer.isHidden = false

                if !isHovered, let diffColor = stickyDiffColor(for: scope, in: doc) {
                    place(row.diffTintLayer, CGRect(x: 0, y: 0, width: band.width, height: lh))
                    row.diffTintLayer.backgroundColor = diffColor
                    row.diffTintLayer.isHidden = false
                } else {
                    row.diffTintLayer.isHidden = true
                }

                place(row.gutterLayer, CGRect(x: gutter.x, y: 0, width: gutter.width, height: lh))
                place(row.textClipLayer, CGRect(x: textClipX, y: 0, width: textClipW, height: lh))

                let lineLayout = ctLine(scope.sourceSide, scope.sourceLine)
                let lineWidth = ceil(CGFloat(CTLineGetTypographicBounds(lineLayout, nil, nil, nil))) + textInset + 4
                let drawOffsetX: CGFloat
                if lineWidth <= 4096 {
                    let tileW = max(textClipW, lineWidth)
                    drawOffsetX = 0
                    place(row.textLayer, CGRect(x: -scroll.x, y: 0, width: tileW, height: lh))
                } else {
                    drawOffsetX = -scroll.x
                    place(row.textLayer, CGRect(x: 0, y: 0, width: textClipW, height: lh))
                }

                let unifiedIdx: Int? = currentMode == .unified ? scope.headerRow : nil
                let key = "\(stickyRenderEpoch)|\(scope.sourceSide.rawValue)|\(scope.sourceLine)|\(unifiedIdx ?? -1)|\(isHovered ? 1 : 0)|\(Int(gutter.width))|\(Int(row.textLayer.bounds.width))|\(Int(drawOffsetX))"
                if row.renderKey != key {
                    row.renderKey = key
                    row.gutterLayer.paneSide = side
                    row.gutterLayer.sourceSide = scope.sourceSide
                    row.gutterLayer.sourceLine = scope.sourceLine
                    row.gutterLayer.unifiedRowIndex = unifiedIdx
                    row.gutterLayer.isHovered = isHovered
                    row.gutterLayer.contentsScale = scale
                    row.gutterLayer.setNeedsDisplay()
                    row.gutterLayer.displayIfNeeded()

                    row.textLayer.paneSide = side
                    row.textLayer.sourceSide = scope.sourceSide
                    row.textLayer.sourceLine = scope.sourceLine
                    row.textLayer.unifiedRowIndex = unifiedIdx
                    row.textLayer.isHovered = isHovered
                    row.textLayer.drawOffsetX = drawOffsetX
                    row.textLayer.contentsScale = scale
                    row.textLayer.setNeedsDisplay()
                    row.textLayer.displayIfNeeded()
                }

                let visMinY = max(0, rowY)
                let visMaxY = min(overlayHeight, rowY + lh)
                if visMaxY > visMinY {
                    stickyHits.append((
                        rect: CGRect(x: band.minX, y: visMinY, width: band.width, height: visMaxY - visMinY),
                        pane: side,
                        slotIndex: sIdx,
                        scope: scope
                    ))
                }
            }

            for extra in overlay.slots[layout.slots.count...] {
                extra.rowLayer.isHidden = true
            }
        }

        if let hovered = hoveredSticky,
           !stickyHits.contains(where: { $0.pane == hovered.pane && $0.slotIndex == hovered.slotIndex }) {
            hoveredSticky = nil
        }
    }

    fileprivate func drawStickyTile(_ tile: StickyTileLayer, in ctx: CGContext) {
        guard let doc = document else { return }
        if !tile.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: tile.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        switch tile.kind {
        case .text:
            ctx.textPosition = CGPoint(x: textInset + tile.drawOffsetX, y: codeFont.baseline)
            CTLineDraw(ctLine(tile.sourceSide, tile.sourceLine), ctx)

        case .gutter:
            let shift = tile.paneSide == .right ? annotationWidth : 0
            if shift > 0, tile.sourceSide == .right, let annotations,
               let index = annotations.index(atLine: tile.sourceLine) {
                let entry = annotations.entries[Int(index)]
                let first = annotations.isRunStart(tile.sourceLine)
                ctx.setFillColor(theme.accent.copy(alpha: 0.18 + 0.72 * CGFloat(entry.recency)) ?? theme.accent)
                ctx.fill(CGRect(x: 4, y: first ? 1 : 0, width: 3, height: codeFont.lineHeight - (first ? 1 : 0)))
                if first {
                    ctx.textPosition = CGPoint(x: 12, y: codeFont.baseline)
                    CTLineDraw(annotationLabel(index, entry), ctx)
                }
            }
            let useStrong = tile.isHovered
            if mode == .unified {
                let numberWidth = unifiedNumberWidth
                if let rowIdx = tile.unifiedRowIndex, let r = unifiedRowForDisplayIndex(rowIdx) {
                    if r.left >= 0 {
                        drawNumber(ctx, doc.displayLineNumber(side: .left, line: Int(r.left)), rightEdge: shift + numberWidth - 4, y: 0, strong: useStrong)
                    }
                    if r.right >= 0 {
                        drawNumber(ctx, doc.displayLineNumber(side: .right, line: Int(r.right)), rightEdge: shift + numberWidth * 2 - 4, y: 0, strong: useStrong)
                    }
                    if r.kind != .context {
                        ctx.textPosition = CGPoint(x: shift + numberWidth * 2 + 4, y: codeFont.baseline)
                        CTLineDraw(signLine(added: r.kind == .added), ctx)
                    }
                } else if tile.sourceSide == .left {
                    drawNumber(ctx, doc.displayLineNumber(side: .left, line: tile.sourceLine), rightEdge: shift + numberWidth - 4, y: 0, strong: useStrong)
                } else {
                    drawNumber(ctx, doc.displayLineNumber(side: .right, line: tile.sourceLine), rightEdge: shift + numberWidth * 2 - 4, y: 0, strong: useStrong)
                }
            } else {
                let rightEdge = shift + gutterWidth - 10
                drawNumber(ctx, doc.displayLineNumber(side: tile.sourceSide, line: tile.sourceLine), rightEdge: rightEdge, y: 0, strong: useStrong)
            }
        }
    }

    private func stickyHit(at point: CGPoint) -> (pane: Side, slotIndex: Int, scope: StickyDisplayScope)? {
        // Iterate reversed so higher-z shallower slots match first if overlapping during push-out.
        for hit in stickyHits.reversed() where hit.rect.contains(point) {
            return (hit.pane, hit.slotIndex, hit.scope)
        }
        return nil
    }

    /// Computes the virtual scroll offset `y` that reveals `line` (0-based) on `side` directly below
    /// `slotIndex` shallower ancestor sticky headers so `line` itself is not pinned or covered.
    func stickyScrollTargetY(for line: Int, side: Side, slotIndex: Int) -> CGFloat {
        let lh = codeFont.lineHeight
        guard lh > 0, document != nil else { return 0 }
        let targetRow: Int
        switch mode {
        case .single:
            targetRow = max(0, line)
        case .sideBySide:
            targetRow = displayRow(forLine: line, side: side)
        case .unified:
            targetRow = unifiedDisplayRow(forLine: line, side: side)
        }
        let desiredPaneTop = max(0, CGFloat(targetRow - max(0, slotIndex)) * lh)
        guard desiredPaneTop > 0 else { return 0 }

        let maxScroll = max(0, CGFloat(rowCount) * lh + bottomPadding - bounds.height)
        guard mode == .sideBySide, maxScroll > 0 else {
            return min(desiredPaneTop, maxScroll)
        }

        // Binary-search `y` in `[0, maxScroll]` so `paneTop` lands at or just below `desiredPaneTop`,
        // ensuring the target declaration line is un-pinned and sits cleanly at `slotIndex * lh`.
        var lo: CGFloat = 0
        var hi: CGFloat = maxScroll
        var bestY: CGFloat = 0
        var bestPaneTop: CGFloat = -1
        for _ in 0..<24 {
            let mid = (lo + hi) * 0.5
            let s = resolveScroll(forOrigin: CGPoint(x: scrollOrigin.x, y: mid))
            let paneTop = side == .left ? s.left : s.right
            if paneTop <= desiredPaneTop {
                if paneTop > bestPaneTop {
                    bestPaneTop = paneTop
                    bestY = mid
                }
                lo = mid
            } else {
                hi = mid
            }
        }
        return bestY
    }

    /// Computes the virtual scroll offset `y` for Vim `zt` so `line` sits right below any enclosing sticky lines.
    func scrollYBelowSticky(forLine line: Int, side: Side) -> CGFloat {
        guard stickyLinesEnabled else {
            return CGFloat(row(forLine: line, side: side)) * codeFont.lineHeight
        }
        let lh = codeFont.lineHeight
        let targetRow: Int
        switch mode {
        case .single:
            targetRow = max(0, line)
        case .sideBySide:
            targetRow = displayRow(forLine: line, side: side)
        case .unified:
            targetRow = unifiedDisplayRow(forLine: line, side: side)
        }
        let limit = min(stickyLinesMaxCount, Int(floor(bounds.height / max(1, lh))) / 3)
        let scopes = (mode == .sideBySide && side == .left) ? leftStickyDisplayScopes : rightStickyDisplayScopes
        var ancestorCount = 0
        for scope in scopes where scope.headerRow < targetRow && scope.endRow > targetRow {
            ancestorCount += 1
        }
        let effectiveSlots = min(ancestorCount, max(0, limit))
        return stickyScrollTargetY(for: line, side: side, slotIndex: effectiveSlots)
    }

    // MARK: Fold bars

    private func updateFoldBars(_ doc: DiffDocument, _ scroll: Scroll) {
        foldBarHits.removeAll(keepingCapacity: true)
        guard isFoldingActive else {
            foldBarLayers.forEach { $0.isHidden = true }
            return
        }
        let lh = codeFont.lineHeight, h = bounds.height, scale = backingScale
        let fullWidth = max(0, bounds.width - rulerWidth)
        var used = 0

        func placeFoldBar(rect: CGRect, region: DiffFoldRegion) {
            guard rect.width > 12, rect.maxY >= 0, rect.minY <= h else { return }
            let hot = hoveredFoldSegment == region.segmentIndex
            guard let image = foldBarGlyph(hiddenCount: region.hiddenLineCount, width: rect.width, height: lh, hot: hot) else { return }
            if used == foldBarLayers.count {
                let layer = StillLayer()
                layer.anchorPoint = .zero
                layer.zPosition = 7.5
                root.addSublayer(layer)
                foldBarLayers.append(layer)
            }
            let layer = foldBarLayers[used]
            used += 1
            place(layer, rect)
            layer.contentsScale = scale
            layer.contents = image
            layer.isHidden = false
            foldBarHits.append((rect, region.segmentIndex))
        }

        switch mode {
        case .sideBySide:
            let leftBand = bandRect(.left)
            let rightBand = bandRect(.right)
            for seg in foldedSegments {
                guard let region = seg.foldRegion, let lRow = seg.leftFoldRow, let rRow = seg.rightFoldRow else { continue }
                let lY = CGFloat(lRow) * lh - scroll.left
                let rY = CGFloat(rRow) * lh - scroll.right
                if max(lY, rY) < -lh { continue }
                if min(lY, rY) > h { break }
                if abs(lY - rY) <= 1.5 {
                    placeFoldBar(rect: CGRect(x: 0, y: pixelRound(rY), width: fullWidth, height: lh), region: region)
                } else {
                    placeFoldBar(rect: CGRect(x: leftBand.minX, y: pixelRound(lY), width: leftBand.width, height: lh), region: region)
                    placeFoldBar(rect: CGRect(x: rightBand.minX, y: pixelRound(rY), width: rightBand.width, height: lh), region: region)
                }
            }
        case .unified:
            guard let visible = visibleRows(top: scroll.right, count: unifiedDisplayRows.count) else { break }
            for row in visible {
                if case .foldBar(let region) = unifiedDisplayRows[row] {
                    let y = CGFloat(row) * lh - scroll.right
                    placeFoldBar(rect: CGRect(x: 0, y: pixelRound(y), width: fullWidth, height: lh), region: region)
                }
            }
        case .single:
            break
        }

        for layer in foldBarLayers[used...] { layer.isHidden = true }
        if let hovered = hoveredFoldSegment, !foldBarHits.contains(where: { $0.segmentIndex == hovered }) { hoveredFoldSegment = nil }
    }

    private func foldBarGlyph(hiddenCount: Int, width: CGFloat, height: CGFloat, hot: Bool) -> CGImage? {
        let scale = backingScale
        let quantWidth = max(32, Int(ceil(width)))
        let hInt = max(14, Int(ceil(height)))
        let key = "\(hiddenCount)|\(quantWidth)|\(hInt)|\(hot)|\(theme.isDark)|\(scale)"
        if let cached = foldBarGlyphs[key] { return cached }
        if foldBarGlyphs.count > 120 { foldBarGlyphs.removeAll(keepingCapacity: true) }
        guard let context = CGContext(data: nil, width: Int(CGFloat(quantWidth) * scale), height: Int(CGFloat(hInt) * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let rect = CGRect(x: 0, y: 0, width: CGFloat(quantWidth), height: CGFloat(hInt))
        context.setFillColor(hot ? theme.foldHoverBg : theme.foldBg)
        context.fill(rect)
        context.setFillColor(theme.foldBorder)
        context.fill(CGRect(x: 0, y: 0, width: rect.width, height: 1))
        context.fill(CGRect(x: 0, y: rect.height - 1, width: rect.width, height: 1))

        let label = L("⋯ Expand \(hiddenCount) unchanged lines ⋯", "⋯ 展开 \(hiddenCount) 行未变更代码 ⋯")
        let font = NSFont.systemFont(ofSize: max(10, min(12, codeFont.size - 1)), weight: .medium)
        let ink = NSColor(cgColor: hot ? theme.accent : theme.foldText) ?? .secondaryLabelColor
        let attr = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
        let textSize = attr.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attr.draw(at: CGPoint(x: max(12, (rect.width - textSize.width) / 2), y: (rect.height - textSize.height) / 2))
        NSGraphicsContext.restoreGraphicsState()

        let image = context.makeImage()
        foldBarGlyphs[key] = image
        return image
    }

    private func foldBarHit(at point: CGPoint) -> Int? {
        foldBarHits.first { $0.rect.contains(point) }?.segmentIndex
    }

    /// The change shown at `point`, if there is one there.
    func hunkIndex(at point: CGPoint) -> Int? {
        guard let doc = document, case .text = doc.content, point.x < bounds.width - rulerWidth else { return nil }
        if let hit = revertHit(at: point) ?? tickHit(at: point) ?? moveBadgeHit(at: point) { return hit }
        let side = pane(at: point)
        let scroll = resolveScroll()
        let row = Int(floor((point.y + (side == .left ? scroll.left : scroll.right)) / codeFont.lineHeight))
        guard row >= 0, row < paneRowCount(side) else { return nil }
        switch mode {
        case .unified:
            if isFoldingActive {
                guard row < unifiedDisplayRows.count, case .unified(let u) = unifiedDisplayRows[row] else { return nil }
                return u.hunk >= 0 ? Int(u.hunk) : nil
            }
            let hunk = Int(doc.unifiedRows[row].hunk)
            return hunk >= 0 ? hunk : nil
        case .sideBySide:
            var index = firstHunk(doc, side: side, endingAtOrAfter: row)
            while index < doc.hunks.count {
                let hunk = doc.hunks[index]
                let start = hunkDisplayStart(index, side: side)
                if start > row { break }
                let count = side == .left ? hunk.leftCount : hunk.rightCount
                if count > 0, row >= start, row < start + count { return index }
                index += 1
            }
            return nil
        case .single:
            return nil
        }
    }

    /// Remembers what the pointer is over, for the context menu that is about to be built.
    func noteContextMenu(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let sticky = stickyHit(at: point) {
            contextStickyLine = (sticky.scope.sourceSide, sticky.scope.sourceLine)
            contextHunk = nil
            contextLSPSymbol = nil
        } else {
            contextStickyLine = nil
            contextHunk = hunkIndex(at: point)
            contextLSPSymbol = lspSymbolTarget(at: point)
        }
    }

    /// The change a context menu is for, set directly (the debug hooks build menus without a click).
    func noteContextHunk(_ index: Int?) { contextHunk = index }

    /// The LSP symbol a context menu is for, set directly (for tests and debug hooks).
    func noteContextLSPSymbol(_ target: LSPHoverTarget?) { contextLSPSymbol = target }

    /// The sticky line a context menu is for, set directly (for tests and debug hooks).
    func noteContextStickyLine(_ target: (side: Side, line: Int)?) { contextStickyLine = target }

    /// What each visible commit tick shows, top to bottom, for the debug hooks: "0:on 1:mixed".
    var visibleTickStates: String {
        guard let doc = document else { return "" }
        let states = tickStates(doc)
        return tickHits.map { "\($0.hunk):\(states.indices.contains($0.hunk) ? "\(states[$0.hunk])" : "?")" }.joined(separator: " ")
    }

    func handleMouseMoved(_ event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        lastMousePoint = point
        if let point, let sticky = stickyHit(at: point) {
            hoveredSticky = (sticky.pane, sticky.slotIndex)
            if hoveredAnnotationLine != nil { setHoveredAnnotation(nil) }
            if hoveredRevert != nil { hoveredRevert = nil }
            if hoveredTick != nil { hoveredTick = nil }
            if hoveredConflict != nil { hoveredConflict = nil }
            if hoveredMoveBadge != nil { hoveredMoveBadge = nil }
            if hoveredFoldSegment != nil { hoveredFoldSegment = nil }
            if hoveredMoveConnector != nil { hoveredMoveConnector = nil }
            clearLSPHover()
            NSCursor.pointingHand.set()
            return
        }
        if hoveredSticky != nil { hoveredSticky = nil }
        let line = point.flatMap(annotatedLine(at:))
        if line != hoveredAnnotationLine { setHoveredAnnotation(line) }
        let hit = point.flatMap(revertHit(at:))
        if hit != hoveredRevert { hoveredRevert = hit }
        let tick = point.flatMap(tickHit(at:))
        if tick != hoveredTick { hoveredTick = tick }
        let conflict = point.flatMap(conflictHit(at:))
        if conflict?.block != hoveredConflict?.block || conflict?.choice != hoveredConflict?.choice { hoveredConflict = conflict }
        let moveBadge = point.flatMap(moveBadgeHit(at:))
        if moveBadge != hoveredMoveBadge { hoveredMoveBadge = moveBadge }
        let foldHit = point.flatMap(foldBarHit(at:))
        if foldHit != hoveredFoldSegment { hoveredFoldSegment = foldHit }
        let moveConnector = (hit == nil && tick == nil && conflict == nil && moveBadge == nil && foldHit == nil)
            ? point.flatMap(moveConnectorHit(at:))
            : nil
        if moveConnector?.pairID != hoveredMoveConnector { hoveredMoveConnector = moveConnector?.pairID }
        let commandOnly = event.map { Self.isCommandOnly($0.modifierFlags) } ?? false
        let buttonHit = hit != nil || tick != nil || conflict != nil || moveBadge != nil || foldHit != nil || moveConnector != nil || line != nil
        if let point, commandOnly, !buttonHit {
            updateLSPHover(at: point)
        } else {
            clearLSPHover()
        }
        // The canvas is one big text cursor rectangle; over a button, commit, fold bar, move badge/connector, or ⌘-hovered symbol it should look clickable.
        guard let point else { return }
        if hit != nil || tick != nil || conflict != nil {
            NSCursor.arrow.set()
        } else if moveBadge != nil || moveConnector != nil || foldHit != nil || line != nil || lspHover != nil {
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
        if stickyHit(at: point) != nil {
            clearLSPHover()
            NSCursor.pointingHand.set()
            return
        }
        let commandOnly = Self.isCommandOnly(event.modifierFlags)
        let overControl = revertHit(at: point) != nil || tickHit(at: point) != nil
            || conflictHit(at: point) != nil || moveBadgeHit(at: point) != nil
            || moveConnectorHit(at: point) != nil
            || foldBarHit(at: point) != nil || annotatedLine(at: point) != nil
        if commandOnly && !overControl {
            updateLSPHover(at: point)
        } else {
            clearLSPHover()
        }
        if revertHit(at: point) != nil || tickHit(at: point) != nil || conflictHit(at: point) != nil {
            NSCursor.arrow.set()
        } else if moveBadgeHit(at: point) != nil || moveConnectorHit(at: point) != nil || foldBarHit(at: point) != nil || annotatedLine(at: point) != nil || lspHover != nil {
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
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for (index, hunk) in doc.hunks.enumerated() where index < hunkRows.count {
            let span = mode == .unified ? hunk.leftCount + hunk.rightCount : max(hunk.leftCount, hunk.rightCount)
            let bucket = hunkBucket(hunk)
            let rect = CGRect(
                x: 3,
                y: CGFloat(hunkRows[index]) * scale,
                width: rulerWidth - 6,
                height: max(2, CGFloat(span) * scale)
            )
            paths[bucket].addRect(rect)
        }
        let markColors = [theme.modifiedMark, theme.addedMark, theme.deletedMark, theme.movedMark]
        for k in 0..<4 {
            rulerMarks[k].contentsScale = backingScale
            rulerMarks[k].fillColor = markColors[k]
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
        if let hit = stickyHit(at: point) {
            pressedSticky = hit
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
        if let hunk = moveBadgeHit(at: point) {
            pressedMoveBadge = hunk
            return
        }
        if let seg = foldBarHit(at: point) {
            pressedFoldSegment = seg
            return
        }
        if let hit = moveConnectorHit(at: point) {
            pressedMoveConnector = hit
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
        if let clickedHunk = hunkIndex(at: point) {
            delegate?.canvas(self, didSelectHunk: clickedHunk)
        }
        let side = pane(at: point)
        let previousCaret = activeCaretPosition()
        guard let pos = position(at: point, pane: side) else { selection = nil; return }
        if !event.modifierFlags.contains(.shift),
           mode != .sideBySide || side == .right,
           let prev = previousCaret {
            let newPos = linePosition(pos)
            if abs(newPos.row - prev.row) >= 5 {
                delegate?.canvas(self, recordJumpOrigin: prev)
            }
        }
        if vimEngine.mode.isVisual || vimEngine.mode.isCommandLine {
            vimEngine.resetToNormal(switchInputSource: false)
        }
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
        if let src = source(pane: side, row: pos.row) {
            notifyActiveLine(side: src.side, line: src.line)
        }
        if vimModeEnabled { reportVimStateIfNeeded() }
    }

    func handleMouseDragged(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if draggingRuler {
            scrollRuler(to: point)
            return
        }
        guard pressedRevert == nil, pressedTick == nil, pressedConflict == nil, pressedMoveBadge == nil, pressedMoveConnector == nil, pressedFoldSegment == nil, pressedSticky == nil, dragSelecting, let current = selection else { return }
        let topEdge = stickyHeight(for: current.pane)
        if point.y < topEdge {
            container?.scrollBy(dx: 0, dy: max(-60, point.y - topEdge))
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
        if let pressed = pressedSticky {
            pressedSticky = nil
            if let hit = stickyHit(at: convert(event.locationInWindow, from: nil)),
               hit.pane == pressed.pane, hit.slotIndex == pressed.slotIndex {
                delegate?.canvas(self, didClickStickyLine: pressed.scope.sourceLine, side: pressed.scope.sourceSide, slotIndex: pressed.slotIndex)
            }
            return
        }
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
        if let pressed = pressedMoveBadge {
            pressedMoveBadge = nil
            if moveBadgeHit(at: convert(event.locationInWindow, from: nil)) == pressed {
                delegate?.canvas(self, jumpToMoveCounterpart: pressed)
            }
            return
        }
        if let pressed = pressedMoveConnector {
            pressedMoveConnector = nil
            let pt = convert(event.locationInWindow, from: nil)
            if let hit = moveConnectorHit(at: pt), hit.pairID == pressed.pairID {
                let sourceHunk: Int
                if hit.bothVisible {
                    if focusedHunk == hit.sourceHunk {
                        sourceHunk = hit.sourceHunk
                    } else if focusedHunk == hit.targetHunk {
                        sourceHunk = hit.targetHunk
                    } else {
                        sourceHunk = pt.x >= paneWidth + connectorWidth * 0.5 ? hit.targetHunk : hit.sourceHunk
                    }
                } else {
                    sourceHunk = hit.clickSourceHunk
                }
                delegate?.canvas(self, jumpToMoveCounterpart: sourceHunk)
            }
            return
        }
        if let pressed = pressedFoldSegment {
            pressedFoldSegment = nil
            if foldBarHit(at: convert(event.locationInWindow, from: nil)) == pressed {
                delegate?.canvas(self, expandFoldSegment: pressed)
            }
            return
        }
        guard let current = selection else { return }
        if (editor != nil || vimModeEnabled), mode != .sideBySide || current.pane == .right {
            // In editable text or Vim mode an empty selection is the caret. In the unified view a click on a
            // removed line (which is not in the file any more) lands on the line that follows it.
            if mode == .unified, current.isEmpty {
                let caret = rowPosition(linePosition(current.head))
                if caret != current.head {
                    suppressActiveLineNotify = true
                    selection = TextSelection(pane: .right, anchor: caret, head: caret)
                    suppressActiveLineNotify = false
                }
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

    /// Active right-pane caret position (0-based line, 0-based UTF-16 column), when a caret or Vim cursor exists.
    func activeCaretPosition() -> TextPosition? {
        guard let doc = document, case .text = doc.content, !doc.right.lines.isEmpty else { return nil }
        if let editSel = editSelection {
            return TextEditing.clamp(editSel.head, in: doc.right.lines)
        }
        if let sel = selection, mode != .sideBySide || sel.pane == .right {
            return linePosition(sel.head)
        }
        if vimModeEnabled {
            return TextEditing.clamp(vimCursor, in: doc.right.lines)
        }
        return nil
    }

    /// Selects a single-line UTF-16 range on `side`, mapping `line` (0-based) into the active pane's display rows.
    func selectRange(side: Side, line: Int, range: Range<Int>) {
        guard let doc = document, case .text = doc.content else { return }
        let lines = doc.buffer(side).lines
        guard lines.indices.contains(line) else { return }
        let len = (lines[line] as NSString).length
        let startCol = max(0, min(range.lowerBound, len))
        let endCol = max(startCol, min(range.upperBound, len))
        let displayR: Int
        switch mode {
        case .sideBySide:
            displayR = displayRow(forLine: line, side: side)
        case .unified:
            displayR = unifiedDisplayRow(forLine: line, side: side)
        case .single:
            guard side == .right else { return }
            displayR = line
        }
        let targetPane: Side = mode == .sideBySide ? side : .right
        selection = TextSelection(
            pane: targetPane,
            anchor: TextPosition(row: displayR, column: startCol),
            head: TextPosition(row: displayR, column: endCol)
        )
        if targetPane == .right, vimModeEnabled {
            vimCursor = TextPosition(row: line, column: startCol)
        }
        goalX = nil
    }

    /// Returns the active pane, 0-based buffer line, and 0-based UTF-16 column for symbol occurrence stepping.
    func symbolCursorContext() -> (side: Side, line: Int, column: Int)? {
        guard let doc = document, case .text = doc.content else { return nil }
        if mode == .sideBySide, let sel = selection, sel.pane == .left,
           let src = source(pane: .left, row: sel.lower.row) {
            let col = sel.lower.row == sel.upper.row ? sel.lower.column : sel.head.column
            return (.left, src.line, col)
        }
        if let sel = selection, !sel.isEmpty, sel.lower.row == sel.upper.row,
           mode != .sideBySide || sel.pane == .right,
           let src = source(pane: sel.pane, row: sel.lower.row), src.side == .right {
            return (.right, src.line, sel.lower.column)
        }
        if let pos = activeCaretPosition() {
            return (.right, pos.row, pos.column)
        }
        return nil
    }

    /// 1-based line number of the active caret (or selection start / visible focus line / top visible line) on the new side.
    func currentLineNumber() -> Int {
        if let pos = activeCaretPosition() { return pos.row + 1 }
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
            if isFoldingActive && mode == .sideBySide {
                let rowTotal = paneRowCount(side)
                guard rowTotal > 0 else { return nil }
                var range: ClosedRange<Int>?
                for row in min(sel.lower.row, rowTotal - 1)...min(upper, rowTotal - 1) {
                    guard let src = source(pane: side, row: row) else { continue }
                    range = range.map { min($0.lowerBound, src.line)...max($0.upperBound, src.line) } ?? src.line...src.line
                }
                return range.map { (side, $0) }
            }
            let count = doc.buffer(side).lines.count
            guard count > 0 else { return nil }
            return (side, min(sel.lower.row, count - 1)...min(upper, count - 1))
        case .unified:
            let rowTotal = paneRowCount(.right)
            guard rowTotal > 0 else { return nil }
            var right: ClosedRange<Int>?, left: ClosedRange<Int>?
            for row in min(sel.lower.row, rowTotal - 1)...min(upper, rowTotal - 1) {
                let r: UnifiedRow
                if isFoldingActive {
                    guard case .unified(let u) = unifiedDisplayRows[row] else { continue }
                    r = u
                } else {
                    r = doc.unifiedRows[row]
                }
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
        if vimModeEnabled, let doc = document, case .text = doc.content, !doc.right.lines.isEmpty {
            // Never hijack ⌘-modified shortcuts — let AppKit menus / GoLand shortcuts handle them.
            if !event.modifierFlags.contains(.command) {
                if vimEngine.mode.isInsert {
                    // In Insert mode, only Esc / ⌃[ / ⌃c (when not composing IME) exit to Normal.
                    if editor?.marked == nil, let key = VimKey.from(event: event),
                       key.kind == .escape || (key.control && (key.kind == .character("[") || key.kind == .character("c"))) {
                        if handleVimKey(key) { return }
                    }
                    // All other Insert keys go straight through NSTextInputClient / IME untouched.
                    if editor != nil, handleEditingKey(event) { return }
                } else {
                    if let key = VimKey.from(event: event), handleVimKey(key) { return }
                    // Allow function keys (F1–F35) through to the responder chain while never falling
                    // through to `handleEditingKey` (which would mutate the buffer outside Insert mode).
                    if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
                       Int(scalar.value) >= NSF1FunctionKey, Int(scalar.value) <= NSF35FunctionKey {
                        super.keyDown(with: event)
                    }
                    return
                }
            }
        }
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
