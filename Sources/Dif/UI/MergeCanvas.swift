import AppKit
import CoreText
import QuartzCore

@MainActor
protocol MergeCanvasDelegate: AnyObject {
    func mergeCanvas(_ canvas: MergeCanvasView, acceptSide side: MergeSide, chunk index: Int)
    func mergeCanvas(_ canvas: MergeCanvasView, ignoreSide side: MergeSide, chunk index: Int)
    func mergeCanvas(_ canvas: MergeCanvasView, resolveConflict index: Int, choice: ConflictResolutionChoice)
    func mergeCanvas(_ canvas: MergeCanvasView, focusChunk index: Int)
    func mergeCanvas(_ canvas: MergeCanvasView, hoverHint hint: String?)
    func mergeCanvas(_ canvas: MergeCanvasView, cursorMovedToLine line: Int, column: Int)
    func mergeCanvasDidEditCenter(_ canvas: MergeCanvasView)
}

// MARK: - Layers

private final class MergeStillLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

private final class MergeStillShapeLayer: CAShapeLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

private final class MergeTileLayer: CALayer {
    enum Kind { case gutter, text }

    weak var canvas: MergeCanvasView?
    var kind = Kind.text
    var pane = MergePane.center
    var index = 0
    var column = 0

    override init() { super.init() }

    override init(layer: Any) {
        super.init(layer: layer)
        guard let other = layer as? MergeTileLayer else { return }
        canvas = other.canvas
        kind = other.kind
        pane = other.pane
        index = other.index
        column = other.column
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in ctx: CGContext) {
        nonisolated(unsafe) let tile = self
        nonisolated(unsafe) let context = ctx
        MainActor.assumeIsolated { tile.canvas?.drawTile(tile, in: context) }
    }
}

private struct MergeTileKey: Hashable {
    var index: Int
    var column: Int
}

private final class MergeRectGroup {
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
                layer = MergeStillLayer()
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

private final class MergePaneLayers {
    let pane: MergePane
    let band = MergeStillLayer()
    let text = MergeStillLayer()
    /// 5 buckets: 0 = modified, 1 = added, 2 = deleted, 3 = conflict, 4 = resolved.
    let lines: [MergeRectGroup]
    let marks: [MergeRectGroup]
    let words: [MergeRectGroup]
    let focusedTop: MergeRectGroup
    let focusedBottom: MergeRectGroup
    let selection: MergeRectGroup

    var gutterTiles: [Int: MergeTileLayer] = [:]
    var textTiles: [MergeTileKey: MergeTileLayer] = [:]
    var contentWidths: [Int: CGFloat] = [:]
    var decorRows: Range<Int> = 0..<0

    init(pane: MergePane) {
        self.pane = pane
        let bandLayer = band
        let textLayer = text
        lines = (0..<5).map { _ in MergeRectGroup(host: bandLayer, z: 0) }
        marks = (0..<5).map { _ in MergeRectGroup(host: bandLayer, z: 1) }
        focusedTop = MergeRectGroup(host: bandLayer, z: 1.5)
        focusedBottom = MergeRectGroup(host: bandLayer, z: 1.5)
        words = (0..<5).map { _ in MergeRectGroup(host: textLayer, z: 0) }
        selection = MergeRectGroup(host: textLayer, z: 3)
        for layer in [bandLayer, textLayer] {
            layer.anchorPoint = .zero
            layer.masksToBounds = true
        }
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
        (lines + marks + words + [focusedTop, focusedBottom, selection]).forEach { $0.clear() }
        decorRows = 0..<0
    }
}

private final class MergeBridgeLayers {
    let host = MergeStillLayer()
    let leftBorder = MergeStillLayer()
    let rightBorder = MergeStillLayer()
    let fills: [MergeStillShapeLayer]
    let resolvedStrokes = MergeStillShapeLayer()
    let focusedOutline = MergeStillShapeLayer()

    init() {
        host.anchorPoint = .zero
        host.masksToBounds = true
        host.zPosition = 2

        leftBorder.anchorPoint = .zero
        leftBorder.zPosition = 3
        rightBorder.anchorPoint = .zero
        rightBorder.zPosition = 3
        host.addSublayer(leftBorder)
        host.addSublayer(rightBorder)

        let hostLayer = host
        fills = (0..<5).map { _ in
            let s = MergeStillShapeLayer()
            s.zPosition = 0
            hostLayer.addSublayer(s)
            return s
        }
        resolvedStrokes.fillColor = nil
        resolvedStrokes.lineWidth = 1
        resolvedStrokes.lineDashPattern = [3, 3]
        resolvedStrokes.zPosition = 0.5
        host.addSublayer(resolvedStrokes)

        focusedOutline.fillColor = nil
        focusedOutline.lineWidth = 1.5
        focusedOutline.zPosition = 1
        host.addSublayer(focusedOutline)
    }
}

struct MergeSelection: Equatable {
    var pane: MergePane
    var anchor: TextPosition
    var head: TextPosition

    var lower: TextPosition { min(anchor, head) }
    var upper: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

// MARK: - 3-Way Merge Canvas

final class MergeCanvasView: NSView {
    static let bridgeWidth: CGFloat = 46
    static let rulerWidth: CGFloat = 12
    private static let tileRows = 8
    private static let overscan = 10
    private static let textInset: CGFloat = 10
    private static let bottomPadding: CGFloat = 24
    private static let maxDisplayBytes = 6000

    private struct Dirty: OptionSet {
        let rawValue: Int
        static let scroll = Dirty(rawValue: 1)
        static let selection = Dirty(rawValue: 2)
        static let decor = Dirty(rawValue: 4)
        static let geometry = Dirty(rawValue: 8)
        static let tiles = Dirty(rawValue: 16)
        static let everything: Dirty = [.scroll, .selection, .decor, .geometry, .tiles]
    }

    enum ActionIcon: String {
        case acceptLeft
        case appendLeft
        case ignoreLeft
        case acceptRight
        case appendRight
        case ignoreRight

        var isIgnore: Bool { self == .ignoreLeft || self == .ignoreRight }
    }

    private struct ButtonHit {
        var rect: CGRect
        var chunk: Int
        var side: MergeSide
        var isIgnore: Bool
        var icon: ActionIcon
    }

    private(set) var document: ThreeWayMergeDocument?
    weak var delegate: MergeCanvasDelegate?
    weak var container: MergeScrollContainer?

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
        }
    }

    var selection: MergeSelection? {
        didSet {
            if selection != oldValue {
                invalidate(.selection)
                if let sel = selection, sel.pane == .center {
                    let lineCount = document?.center.lines.count ?? 0
                    let row = lineCount > 0 ? min(max(0, sel.head.row), lineCount - 1) : 0
                    delegate?.mergeCanvas(self, cursorMovedToLine: row + 1, column: sel.head.column + 1)
                }
            }
        }
    }

    var focusedChunk: Int? {
        didSet {
            if focusedChunk != oldValue {
                invalidate(.decor)
            }
        }
    }

    private let root = MergeStillLayer()
    private let panes = MergePane.allCases.map { MergePaneLayers(pane: $0) }
    private let leftBridge = MergeBridgeLayers()
    private let rightBridge = MergeBridgeLayers()
    private let ruler = MergeStillLayer()
    private let rulerMarks = (0..<5).map { _ in MergeStillShapeLayer() }
    private let rulerThumb = MergeStillLayer()
    private let caretLayer = MergeStillLayer()
    private let compositionUnderline: MergeRectGroup

    private var buttonLayers: [MergeStillLayer] = []
    private var buttonHits: [ButtonHit] = []
    private var buttonGlyphs: [String: CGImage] = [:]
    private var hoveredButton: (chunk: Int, side: MergeSide, isIgnore: Bool)? {
        didSet {
            if hoveredButton?.chunk != oldValue?.chunk || hoveredButton?.side != oldValue?.side || hoveredButton?.isIgnore != oldValue?.isIgnore {
                invalidate(.scroll)
                updateHoverHint()
            }
        }
    }
    private var pressedButton: (chunk: Int, side: MergeSide, isIgnore: Bool)?

    private var tileWidth: CGFloat = 512
    private var caretFrame: CGRect = .null
    private var lineCacheNew: [Int: CTLine] = [:]
    private var lineCacheOld: [Int: CTLine] = [:]
    private var lineCacheCost = 0
    private var numberCache: [Int: CTLine] = [:]
    private var cachedParagraphStyle: NSParagraphStyle?
    private var dirty: Dirty = []
    private var updateScheduled = false
    private var dragSelecting = false
    private var draggingRuler = false
    private var goalX: CGFloat?
    private var lineClipboard: String?

    private let pasteboard = NSPasteboard.general

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { document != nil }

    override init(frame: NSRect) {
        compositionUnderline = MergeRectGroup(host: panes[MergePane.center.rawValue].text, z: 3.5)
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        root.anchorPoint = .zero
        for p in panes {
            root.addSublayer(p.band)
            root.addSublayer(p.text)
        }
        root.addSublayer(leftBridge.host)
        root.addSublayer(rightBridge.host)

        ruler.anchorPoint = .zero
        ruler.zPosition = 6
        rulerThumb.anchorPoint = .zero
        rulerThumb.zPosition = 0
        rulerThumb.cornerRadius = 2
        ruler.addSublayer(rulerThumb)
        for mark in rulerMarks {
            mark.zPosition = 1
            ruler.addSublayer(mark)
        }
        root.addSublayer(ruler)

        caretLayer.zPosition = 4
        caretLayer.isHidden = true
        panes[MergePane.center.rawValue].text.addSublayer(caretLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setDocument(_ doc: ThreeWayMergeDocument?) {
        document = doc
        activeStyles = theme.styles(for: doc?.language)
        focusedChunk = nil
        hoveredButton = nil
        pressedButton = nil
        goalX = nil
        invalidateTextCaches()
        panes.forEach { $0.dropTiles(); $0.clearDecor() }
        if let doc {
            let line = doc.center.lines.isEmpty ? 0 : 0
            selection = MergeSelection(pane: .center, anchor: TextPosition(row: line, column: 0), head: TextPosition(row: line, column: 0))
        } else {
            selection = nil
        }
        invalidate(.everything)
    }

    func refreshAfterDocumentMutation(preservingAnchorLine anchorLine: Int? = nil, restoreSelection: EditorSession.Selection? = nil) {
        guard let doc = document else { return }
        let lh = codeFont.lineHeight
        let anchor = anchorLine ?? centerVisibleAnchorLine()
        let before = CGFloat(anchor) * lh - resolveScroll().center

        clearLineCache(for: .center)
        panes[MergePane.center.rawValue].dropTiles()

        if let restoreSelection {
            setCenterSelection(restoreSelection)
        } else if let sel = selection, sel.pane == .center {
            setCenterSelection((sel.anchor, sel.head))
        }

        invalidate([.decor, .selection, .scroll])
        container?.updateDocumentSize()

        if !doc.center.lines.isEmpty {
            let clampedAnchor = min(max(0, anchor), doc.center.lines.count - 1)
            for _ in 0..<4 {
                let after = CGFloat(clampedAnchor) * lh - resolveScroll().center
                guard abs(after - before) >= 0.5 else { break }
                container?.scrollBy(dx: 0, dy: after - before)
            }
        }
    }

    private func centerVisibleAnchorLine() -> Int {
        let scroll = resolveScroll()
        let row = max(0, Int((scroll.center + codeFont.lineHeight * 0.5) / codeFont.lineHeight))
        guard let doc = document, !doc.center.lines.isEmpty else { return 0 }
        return min(row, doc.center.lines.count - 1)
    }

    private func invalidateTextCaches() {
        lineCacheNew.removeAll()
        lineCacheOld.removeAll()
        lineCacheCost = 0
        numberCache.removeAll()
        buttonGlyphs.removeAll()
        cachedParagraphStyle = nil
        panes.forEach { $0.dropTiles() }
    }

    private func clearLineCache(for pane: MergePane) {
        for key in Array(lineCacheNew.keys) where (key & 0b11) == pane.rawValue {
            lineCacheNew.removeValue(forKey: key)
        }
        for key in Array(lineCacheOld.keys) where (key & 0b11) == pane.rawValue {
            lineCacheOld.removeValue(forKey: key)
        }
    }

    private func invalidate(_ flags: Dirty) {
        dirty.formUnion(flags)
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.apply()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard dark != theme.isDark else { return }
        theme = dark ? .dark : .light
        activeStyles = theme.styles(for: document?.language)
        invalidateTextCaches()
        invalidate(.everything)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewDidChangeEffectiveAppearance()
        invalidate(.everything)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didBecomeKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func keyWindowChanged() {
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

    /// Exact column widths matching `ThreeWayMergeView`'s aligned headers.
    static func paneWidths(totalWidth: CGFloat) -> (left: CGFloat, center: CGFloat, right: CGFloat) {
        let usable = max(360, totalWidth - 2 * bridgeWidth - rulerWidth)
        let base = floor(usable / 3)
        let rem = usable - base * 3
        return (base, base, base + rem)
    }

    private func digits(_ n: Int) -> Int { max(3, String(max(1, n)).count) }

    private var gutterWidth: CGFloat {
        guard let doc = document else { return 40 }
        let maxLines = max(doc.left.lines.count, max(doc.center.lines.count, doc.right.lines.count))
        return (CGFloat(digits(maxLines)) * codeFont.charWidth).rounded(.up) + 18
    }

    private func bandRect(_ pane: MergePane) -> CGRect {
        let h = bounds.height
        let w = Self.paneWidths(totalWidth: bounds.width)
        switch pane {
        case .left:
            return CGRect(x: 0, y: 0, width: w.left, height: h)
        case .center:
            return CGRect(x: w.left + Self.bridgeWidth, y: 0, width: w.center, height: h)
        case .right:
            return CGRect(x: w.left + Self.bridgeWidth + w.center + Self.bridgeWidth, y: 0, width: w.right, height: h)
        }
    }

    private func textRect(_ pane: MergePane) -> CGRect {
        let band = bandRect(pane)
        let g = gutterWidth
        return CGRect(x: band.minX + g, y: 0, width: max(0, band.width - g), height: band.height)
    }

    private var leftBridgeX: CGFloat {
        Self.paneWidths(totalWidth: bounds.width).left
    }

    private var rightBridgeX: CGFloat {
        let w = Self.paneWidths(totalWidth: bounds.width)
        return w.left + Self.bridgeWidth + w.center
    }

    private var rowCount: Int { document?.virtualLineCount ?? 0 }

    func documentSize(viewport: CGSize) -> CGSize {
        guard let doc = document else { return viewport }
        let lh = codeFont.lineHeight
        let height = CGFloat(rowCount) * lh + Self.bottomPadding
        let columns = max(doc.left.maxColumns, max(doc.center.maxColumns, doc.right.maxColumns))
        let w = Self.paneWidths(totalWidth: viewport.width)
        let available = max(1, min(w.left, min(w.center, w.right)) - gutterWidth)
        let contentWidth = CGFloat(min(columns, 4000)) * codeFont.charWidth + Self.textInset + 48
        return CGSize(width: viewport.width + max(0, contentWidth - available), height: max(height, viewport.height))
    }

    private struct Scroll {
        var left: CGFloat
        var center: CGFloat
        var right: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func pixelRound(_ v: CGFloat) -> CGFloat {
        let scale = backingScale
        return (v * scale).rounded() / scale
    }

    private func resolveScroll() -> Scroll {
        let h = bounds.height
        let lh = codeFont.lineHeight
        let pad = Self.bottomPadding
        let maxScroll = max(0, CGFloat(rowCount) * lh + pad - h)
        let y = min(max(scrollOrigin.y, 0), maxScroll)
        let overscroll = pixelRound(scrollOrigin.y - y)
        let maxX = max(0, (container?.documentWidth ?? bounds.width) - bounds.width)
        let x = pixelRound(min(max(scrollOrigin.x, 0), maxX))

        guard let doc = document else {
            let top = pixelRound(y) + overscroll
            return Scroll(left: top, center: top, right: top, x: x, y: y)
        }
        let k = maxScroll > 0 ? y / maxScroll : 0
        let anchor = k * max(0, h - pad)
        let positions = doc.panePositions(forVirtual: Double((y + anchor) / lh))

        func top(_ position: Double, _ count: Int) -> CGFloat {
            let limit = max(0, CGFloat(count) * lh + pad - h)
            return pixelRound(min(max(CGFloat(position) * lh - anchor, 0), limit)) + overscroll
        }
        return Scroll(
            left: top(positions.left, doc.left.lines.count),
            center: top(positions.center, doc.center.lines.count),
            right: top(positions.right, doc.right.lines.count),
            x: x,
            y: y
        )
    }

    private func paneScrollTop(_ pane: MergePane, in scroll: Scroll) -> CGFloat {
        switch pane {
        case .left: return scroll.left
        case .center: return scroll.center
        case .right: return scroll.right
        }
    }

    private func buffer(for pane: MergePane, in doc: ThreeWayMergeDocument) -> TextBuffer {
        switch pane {
        case .left: return doc.left
        case .center: return doc.center
        case .right: return doc.right
        }
    }

    // MARK: Text & Tiles

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

    private func ctLine(_ pane: MergePane, _ index: Int) -> CTLine {
        let key = (index << 2) | pane.rawValue
        if let line = lineCacheNew[key] { return line }
        if let line = lineCacheOld[key] {
            lineCacheNew[key] = line
            return line
        }
        let line = makeLine(pane, index)
        let cost = CTLineGetStringRange(line).length + 16
        if lineCacheNew.count >= 360 || lineCacheCost + cost > 48_000 {
            lineCacheOld = lineCacheNew
            lineCacheNew.removeAll(keepingCapacity: true)
            lineCacheCost = 0
        }
        lineCacheNew[key] = line
        lineCacheCost += cost
        return line
    }

    private func makeLine(_ pane: MergePane, _ index: Int) -> CTLine {
        guard let doc = document else { return CTLineCreateWithAttributedString(NSAttributedString()) }
        let buf = buffer(for: pane, in: doc)
        guard index >= 0, index < buf.lines.count else {
            return CTLineCreateWithAttributedString(NSAttributedString())
        }
        var text = buf.lines[index]
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
        for span in buf.spans(at: index) where span.kind != .plain {
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

    private func drawNumber(_ ctx: CGContext, _ number: Int, rightEdge: CGFloat, y: CGFloat) {
        let line = numberLine(number)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: rightEdge - width, y: y + codeFont.baseline)
        CTLineDraw(line, ctx)
    }

    fileprivate func drawTile(_ tile: MergeTileLayer, in ctx: CGContext) {
        guard let doc = document else { return }
        if !tile.contentsAreFlipped() {
            ctx.translateBy(x: 0, y: tile.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        let lh = codeFont.lineHeight
        let buf = buffer(for: tile.pane, in: doc)
        let firstRow = tile.index * Self.tileRows
        let lastRow = min(buf.lines.count, firstRow + Self.tileRows) - 1
        guard firstRow <= lastRow else { return }

        switch tile.kind {
        case .text:
            let x = Self.textInset - CGFloat(tile.column) * tileWidth
            for row in firstRow...lastRow {
                ctx.textPosition = CGPoint(x: x, y: CGFloat(row - firstRow) * lh + codeFont.baseline)
                CTLineDraw(ctLine(tile.pane, row), ctx)
            }
        case .gutter:
            let rightEdge = gutterWidth - 8
            for row in firstRow...lastRow {
                drawNumber(ctx, row + 1, rightEdge: rightEdge, y: CGFloat(row - firstRow) * lh)
            }
        }
    }

    private func makeTile(_ kind: MergeTileLayer.Kind, paneLayers: MergePaneLayers, index: Int, column: Int, frame: CGRect) -> MergeTileLayer {
        let tile = MergeTileLayer()
        tile.canvas = self
        tile.kind = kind
        tile.pane = paneLayers.pane
        tile.index = index
        tile.column = column
        tile.anchorPoint = .zero
        tile.position = frame.origin
        tile.bounds = CGRect(origin: .zero, size: frame.size)
        tile.contentsScale = backingScale
        tile.contentsFormat = .RGBA8Uint
        tile.zPosition = 5
        (kind == .gutter ? paneLayers.band : paneLayers.text).addSublayer(tile)
        tile.setNeedsDisplay()
        tile.displayIfNeeded()
        return tile
    }

    private func contentWidth(_ paneLayers: MergePaneLayers, tile index: Int, rows: Range<Int>) -> CGFloat {
        if let cached = paneLayers.contentWidths[index] { return cached }
        var widest: Double = 0
        for row in rows {
            widest = max(widest, CTLineGetTypographicBounds(ctLine(paneLayers.pane, row), nil, nil, nil))
        }
        let width = widest > 0 ? CGFloat(widest).rounded(.up) + Self.textInset + 2 : 0
        paneLayers.contentWidths[index] = width
        return width
    }

    private func updateTiles(_ paneLayers: MergePaneLayers, count: Int, top: CGFloat, x: CGFloat) {
        guard count > 0 else { paneLayers.dropTiles(); return }
        let lh = codeFont.lineHeight
        let tileHeight = lh * CGFloat(Self.tileRows)
        let first = min((count - 1) / Self.tileRows, max(0, Int(floor(top / tileHeight))))
        let last = min((count - 1) / Self.tileRows, max(first, Int(floor((top + bounds.height - 0.01) / tileHeight))))
        let textWidth = paneLayers.text.bounds.width
        let firstColumn = max(0, Int(floor(x / tileWidth)))
        let lastColumn = max(firstColumn, Int(floor((x + textWidth - 0.01) / tileWidth)))

        for (key, tile) in paneLayers.gutterTiles where key < first - 1 || key > last + 1 {
            tile.removeFromSuperlayer()
            paneLayers.gutterTiles.removeValue(forKey: key)
        }
        for (key, tile) in paneLayers.textTiles
        where key.index < first - 1 || key.index > last + 1 || key.column < firstColumn || key.column > lastColumn {
            tile.removeFromSuperlayer()
            paneLayers.textTiles.removeValue(forKey: key)
        }

        let gw = gutterWidth
        for tile in paneLayers.gutterTiles.values where tile.bounds.width != gw {
            tile.bounds.size.width = gw
            tile.setNeedsDisplay()
        }

        for index in first...last {
            let rows = (index * Self.tileRows)..<min(count, (index + 1) * Self.tileRows)
            let y = CGFloat(index) * tileHeight
            let height = CGFloat(rows.count) * lh
            if paneLayers.gutterTiles[index] == nil {
                paneLayers.gutterTiles[index] = makeTile(.gutter, paneLayers: paneLayers, index: index, column: 0,
                                                         frame: CGRect(x: 0, y: y, width: gw, height: height))
            }
            let content = contentWidth(paneLayers, tile: index, rows: rows)
            for column in firstColumn...lastColumn {
                let key = MergeTileKey(index: index, column: column)
                guard paneLayers.textTiles[key] == nil else { continue }
                let remaining = content - CGFloat(column) * tileWidth
                guard remaining > 0 else { continue }
                let width = min(tileWidth, (remaining / 32).rounded(.up) * 32)
                paneLayers.textTiles[key] = makeTile(.text, paneLayers: paneLayers, index: index, column: column,
                                                     frame: CGRect(x: CGFloat(column) * tileWidth, y: y, width: width, height: height))
            }
        }
    }

    // MARK: Rendering apply pass

    private func place(_ layer: CALayer, _ rect: CGRect) {
        layer.position = rect.origin
        layer.bounds.size = rect.size
    }

    private func visibleRows(top: CGFloat, count: Int) -> ClosedRange<Int>? {
        guard count > 0 else { return nil }
        let lh = codeFont.lineHeight
        let first = min(count - 1, max(0, Int(floor(top / lh))))
        let last = min(count - 1, max(first, Int(floor((top + bounds.height) / lh))))
        return first...last
    }

    private func apply() {
        let pending = dirty
        dirty = []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if root.superlayer == nil { layer?.addSublayer(root) }
        place(root, bounds)
        root.backgroundColor = theme.background

        guard let doc = document, bounds.width > 1, bounds.height > 1 else {
            for p in panes {
                p.band.isHidden = true
                p.text.isHidden = true
                p.dropTiles()
                p.clearDecor()
            }
            leftBridge.host.isHidden = true
            rightBridge.host.isHidden = true
            ruler.isHidden = true
            buttonHits.removeAll()
            buttonLayers.forEach { $0.isHidden = true }
            updateCaret()
            return
        }

        if pending.contains(.tiles) { panes.forEach { $0.dropTiles() } }

        for p in panes {
            p.band.isHidden = false
            p.text.isHidden = false
            place(p.band, bandRect(p.pane))
            place(p.text, textRect(p.pane))
        }

        leftBridge.host.isHidden = false
        rightBridge.host.isHidden = false
        place(leftBridge.host, CGRect(x: leftBridgeX, y: 0, width: Self.bridgeWidth, height: bounds.height))
        place(rightBridge.host, CGRect(x: rightBridgeX, y: 0, width: Self.bridgeWidth, height: bounds.height))
        for bridge in [leftBridge, rightBridge] {
            bridge.host.backgroundColor = theme.background
            bridge.leftBorder.frame = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
            bridge.rightBorder.frame = CGRect(x: Self.bridgeWidth - 1, y: 0, width: 1, height: bounds.height)
            bridge.leftBorder.backgroundColor = theme.separator
            bridge.rightBorder.backgroundColor = theme.separator
        }

        ruler.isHidden = false
        place(ruler, CGRect(x: bounds.width - Self.rulerWidth, y: 0, width: Self.rulerWidth, height: bounds.height))

        let w = Self.paneWidths(totalWidth: bounds.width)
        let widest = max(w.left, max(w.center, w.right)) - gutterWidth
        let quantised = max(256, (widest / 64).rounded(.up) * 64)
        if quantised != tileWidth {
            tileWidth = quantised
            panes.forEach { $0.dropTextTiles() }
        }

        let scroll = resolveScroll()
        let redecorate = !pending.isDisjoint(with: [.decor, .geometry, .tiles])
        let reselect = redecorate || pending.contains(.selection)

        for p in panes {
            let buf = buffer(for: p.pane, in: doc)
            let count = buf.lines.count
            let top = paneScrollTop(p.pane, in: scroll)
            p.band.bounds.origin = CGPoint(x: 0, y: top)
            p.text.bounds.origin = CGPoint(x: scroll.x, y: top)
            updateTiles(p, count: count, top: top, x: scroll.x)

            guard let visible = visibleRows(top: top, count: count) else {
                if p.pane == .center, !doc.chunks.isEmpty {
                    if redecorate || p.decorRows.isEmpty {
                        p.decorRows = 0..<1
                        rebuildDecor(p, doc, rows: 0..<0)
                        rebuildSelection(p, rows: 0..<0)
                    }
                } else {
                    p.clearDecor()
                }
                continue
            }
            let covered = p.decorRows.contains(visible.lowerBound) && p.decorRows.contains(visible.upperBound)
            if redecorate || !covered {
                p.decorRows = max(0, visible.lowerBound - Self.overscan)..<min(count, visible.upperBound + Self.overscan + 1)
                rebuildDecor(p, doc, rows: p.decorRows)
                rebuildSelection(p, rows: p.decorRows)
            } else if reselect {
                rebuildSelection(p, rows: p.decorRows)
            }
        }

        updateBridge(leftBridge, doc: doc, side: .left, scroll: scroll)
        updateBridge(rightBridge, doc: doc, side: .right, scroll: scroll)
        updateBridgeButtons(doc, scroll)
        updateRuler(doc, scroll, marks: redecorate)
        updateCaret()
    }

    // MARK: Buckets & Decor

    private func bucket(for chunk: MergeChunk, on pane: MergePane) -> Int {
        if chunk.isResolved { return 4 }
        if chunk.isConflict {
            switch pane {
            case .left: return chunk.leftState == .accepted ? 4 : 3
            case .right: return chunk.rightState == .accepted ? 4 : 3
            case .center: return 3
            }
        }
        let subkind: MergeChangeSubkind
        switch chunk.kind {
        case .leftOnly(let s): subkind = s
        case .rightOnly(let s): subkind = s
        case .bothIdentical(let s): subkind = s
        case .conflict: subkind = .modified
        }
        switch subkind {
        case .modified: return 0
        case .added: return 1
        case .deleted: return 2
        }
    }

    private func bucketFillColors() -> [CGColor] {
        [theme.modified, theme.added, theme.deleted, theme.conflict, theme.resolvedChunk]
    }

    private func bucketBorderColors() -> [CGColor] {
        [theme.modifiedBorder, theme.addedBorder, theme.deletedBorder, theme.conflictBorder, theme.resolvedBorder]
    }

    private func bucketWordColors() -> [CGColor] {
        [theme.modifiedWord, theme.addedWord, theme.deletedWord, theme.conflictWord, theme.resolvedChunk]
    }

    private func chunkRange(for chunk: MergeChunk, on pane: MergePane) -> Range<Int> {
        switch pane {
        case .left: return chunk.leftRange
        case .center: return chunk.centerRange
        case .right: return chunk.rightRange
        }
    }

    private func appendRects(_ ranges: [Range<Int>], pane: MergePane, line: Int, to rects: inout [CGRect]) {
        guard !ranges.isEmpty else { return }
        let lh = codeFont.lineHeight
        let layout = ctLine(pane, line)
        for r in ranges {
            let x0 = CTLineGetOffsetForStringIndex(layout, r.lowerBound, nil)
            let x1 = CTLineGetOffsetForStringIndex(layout, r.upperBound, nil)
            guard x1 > x0 else { continue }
            rects.append(CGRect(x: Self.textInset + x0, y: CGFloat(line) * lh + 1, width: x1 - x0, height: lh - 2))
        }
    }

    private func rebuildDecor(_ paneLayers: MergePaneLayers, _ doc: ThreeWayMergeDocument, rows: Range<Int>) {
        let lh = codeFont.lineHeight
        let bandWidth = paneLayers.band.bounds.width
        var lines = [[CGRect]](repeating: [], count: 5)
        var marks = [[CGRect]](repeating: [], count: 5)
        var words = [[CGRect]](repeating: [], count: 5)
        var focusedTopRects: [CGRect] = []
        var focusedBottomRects: [CGRect] = []
        var focusedTopColor = theme.modifiedBorder
        var focusedBottomColor = theme.modifiedBorder

        let fillColors = bucketFillColors()
        let borderColors = bucketBorderColors()
        let wordColors = bucketWordColors()
        let pane = paneLayers.pane

        for (index, chunk) in doc.chunks.enumerated() {
            if pane == .left && !chunk.hasLeftChange { continue }
            if pane == .right && !chunk.hasRightChange { continue }

            let range = chunkRange(for: chunk, on: pane)
            let b = bucket(for: chunk, on: pane)
            let isFocused = focusedChunk == index

            if range.isEmpty {
                if range.lowerBound >= max(0, rows.lowerBound - 1), range.lowerBound <= rows.upperBound + 1 {
                    let rect = CGRect(x: 0, y: max(0, CGFloat(range.lowerBound) * lh - 1), width: bandWidth, height: 2)
                    if isFocused {
                        focusedTopRects.append(rect)
                        focusedTopColor = borderColors[b]
                    } else {
                        marks[b].append(rect)
                    }
                }
                continue
            }

            if range.lowerBound > rows.upperBound { break }
            if range.upperBound < rows.lowerBound { continue }

            let a = max(range.lowerBound, rows.lowerBound)
            let end = min(range.upperBound, rows.upperBound)
            if a < end {
                let rect = CGRect(x: 0, y: CGFloat(a) * lh, width: bandWidth, height: CGFloat(end - a) * lh)
                lines[b].append(rect)
                if isFocused {
                    let bc = borderColors[b]
                    if range.lowerBound >= rows.lowerBound {
                        focusedTopRects.append(CGRect(x: 0, y: CGFloat(range.lowerBound) * lh, width: bandWidth, height: 1))
                        focusedTopColor = bc
                    }
                    if range.upperBound <= rows.upperBound {
                        focusedBottomRects.append(CGRect(x: 0, y: CGFloat(range.upperBound) * lh - 1, width: bandWidth, height: 1))
                        focusedBottomColor = bc
                    }
                }

                if !chunk.isResolved {
                    let inline: [[Range<Int>]]
                    switch pane {
                    case .left: inline = chunk.leftInline
                    case .right: inline = chunk.rightInline
                    case .center:
                        if chunk.manuallyEdited {
                            inline = []
                        } else if chunk.hasLeftChange && !chunk.hasRightChange {
                            inline = chunk.baseLeftInline
                        } else if chunk.hasRightChange && !chunk.hasLeftChange {
                            inline = chunk.baseRightInline
                        } else {
                            inline = []
                        }
                    }
                    if !inline.isEmpty {
                        let inlineEnd = min(end, range.lowerBound + inline.count)
                        var line = a
                        while line < inlineEnd {
                            let offset = line - range.lowerBound
                            appendRects(inline[offset], pane: pane, line: line, to: &words[b])
                            line += 1
                        }
                    }
                }
            }
        }

        for k in 0..<5 {
            paneLayers.lines[k].set(lines[k], color: fillColors[k])
            paneLayers.marks[k].set(marks[k], color: borderColors[k])
            paneLayers.words[k].set(words[k], color: wordColors[k], radius: 2.5)
        }
        paneLayers.focusedTop.set(focusedTopRects, color: focusedTopColor)
        paneLayers.focusedBottom.set(focusedBottomRects, color: focusedBottomColor)
    }

    private func rebuildSelection(_ paneLayers: MergePaneLayers, rows: Range<Int>) {
        var rects: [CGRect] = []
        if let sel = selection, !sel.isEmpty, sel.pane == paneLayers.pane, !rows.isEmpty {
            let lower = sel.lower
            let upper = sel.upper
            let lh = codeFont.lineHeight
            let first = max(rows.lowerBound, lower.row)
            let last = min(rows.upperBound - 1, upper.row)
            if first <= last {
                for row in first...last {
                    let layout = ctLine(paneLayers.pane, row)
                    let x0 = row == lower.row ? CTLineGetOffsetForStringIndex(layout, lower.column, nil) : 0
                    var x1: CGFloat
                    if row == upper.row {
                        x1 = CTLineGetOffsetForStringIndex(layout, upper.column, nil)
                    } else {
                        x1 = CGFloat(CTLineGetTypographicBounds(layout, nil, nil, nil)) + codeFont.charWidth
                    }
                    x1 = max(x1, x0)
                    rects.append(CGRect(x: Self.textInset + x0, y: CGFloat(row) * lh, width: x1 - x0, height: lh))
                }
            }
        }
        paneLayers.selection.set(rects, color: theme.selection)
    }

    // MARK: Bridges & Action Buttons

    private func updateBridge(_ bridge: MergeBridgeLayers, doc: ThreeWayMergeDocument, side: MergeSide, scroll: Scroll) {
        let lh = codeFont.lineHeight
        let h = bounds.height
        let x1 = Self.bridgeWidth
        let bend = Self.bridgeWidth * 0.5
        let fills = [CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath()]
        let resolvedStrokePath = CGMutablePath()
        var focusStrokePath: CGMutablePath?
        var focusStrokeColor: CGColor?

        let borderColors = bucketBorderColors()
        let fillColors = bucketFillColors()
        let sideTop = side == .left ? scroll.left : scroll.right
        let centerTop = scroll.center

        for (index, chunk) in doc.chunks.enumerated() {
            let applicable = side == .left ? chunk.hasLeftChange : chunk.hasRightChange
            guard applicable else { continue }

            let sideRange = side == .left ? chunk.leftRange : chunk.rightRange
            let centerRange = chunk.centerRange

            var l0: CGFloat
            var l1: CGFloat
            var r0: CGFloat
            var r1: CGFloat
            if side == .left {
                l0 = CGFloat(sideRange.lowerBound) * lh - sideTop
                l1 = CGFloat(sideRange.upperBound) * lh - sideTop
                r0 = CGFloat(centerRange.lowerBound) * lh - centerTop
                r1 = CGFloat(centerRange.upperBound) * lh - centerTop
                if sideRange.isEmpty { l0 -= 1; l1 += 1 }
                if centerRange.isEmpty { r0 -= 1; r1 += 1 }
            } else {
                l0 = CGFloat(centerRange.lowerBound) * lh - centerTop
                l1 = CGFloat(centerRange.upperBound) * lh - centerTop
                r0 = CGFloat(sideRange.lowerBound) * lh - sideTop
                r1 = CGFloat(sideRange.upperBound) * lh - sideTop
                if centerRange.isEmpty { l0 -= 1; l1 += 1 }
                if sideRange.isEmpty { r0 -= 1; r1 += 1 }
            }

            if min(l0, r0) > h { break }
            guard max(l1, r1) >= 0 else { continue }

            l0 = max(l0, -h); r0 = max(r0, -h)
            l1 = min(l1, 2 * h); r1 = min(r1, 2 * h)

            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: l0))
            path.addCurve(to: CGPoint(x: x1, y: r0), control1: CGPoint(x: bend, y: l0), control2: CGPoint(x: x1 - bend, y: r0))
            path.addLine(to: CGPoint(x: x1, y: r1))
            path.addCurve(to: CGPoint(x: 0, y: l1), control1: CGPoint(x: x1 - bend, y: r1), control2: CGPoint(x: bend, y: l1))
            path.closeSubpath()

            let b = bucket(for: chunk, on: side == .left ? .left : .right)
            fills[b].addPath(path)

            if b == 4 {
                resolvedStrokePath.move(to: CGPoint(x: 0, y: l0 + 0.5))
                resolvedStrokePath.addCurve(to: CGPoint(x: x1, y: r0 + 0.5), control1: CGPoint(x: bend, y: l0 + 0.5), control2: CGPoint(x: x1 - bend, y: r0 + 0.5))
                resolvedStrokePath.move(to: CGPoint(x: 0, y: l1 - 0.5))
                resolvedStrokePath.addCurve(to: CGPoint(x: x1, y: r1 - 0.5), control1: CGPoint(x: bend, y: l1 - 0.5), control2: CGPoint(x: x1 - bend, y: r1 - 0.5))
            }

            if index == focusedChunk {
                let s = CGMutablePath()
                s.move(to: CGPoint(x: 0, y: l0 + 0.5))
                s.addCurve(to: CGPoint(x: x1, y: r0 + 0.5), control1: CGPoint(x: bend, y: l0 + 0.5), control2: CGPoint(x: x1 - bend, y: r0 + 0.5))
                s.move(to: CGPoint(x: 0, y: l1 - 0.5))
                s.addCurve(to: CGPoint(x: x1, y: r1 - 0.5), control1: CGPoint(x: bend, y: l1 - 0.5), control2: CGPoint(x: x1 - bend, y: r1 - 0.5))
                focusStrokePath = s
                focusStrokeColor = borderColors[b]
            }
        }

        let scale = backingScale
        for k in 0..<5 {
            bridge.fills[k].contentsScale = scale
            bridge.fills[k].fillColor = fillColors[k]
            bridge.fills[k].path = fills[k].isEmpty ? nil : fills[k]
        }
        bridge.resolvedStrokes.contentsScale = scale
        bridge.resolvedStrokes.strokeColor = theme.resolvedBorder
        bridge.resolvedStrokes.path = resolvedStrokePath.isEmpty ? nil : resolvedStrokePath

        bridge.focusedOutline.contentsScale = scale
        bridge.focusedOutline.strokeColor = focusStrokeColor
        bridge.focusedOutline.path = focusStrokePath
    }

    private var actionButtonSize: CGFloat { min(18, max(15, (codeFont.lineHeight - 1).rounded())) }

    private func updateBridgeButtons(_ doc: ThreeWayMergeDocument, _ scroll: Scroll) {
        buttonHits.removeAll(keepingCapacity: true)
        let lh = codeFont.lineHeight
        let h = bounds.height
        let size = actionButtonSize
        let scale = backingScale
        var used = 0

        func addButton(rect: CGRect, chunkIndex: Int, side: MergeSide, isIgnore: Bool, icon: ActionIcon) {
            let hot = hoveredButton?.chunk == chunkIndex && hoveredButton?.side == side && hoveredButton?.isIgnore == isIgnore
            guard let img = buttonGlyph(icon: icon, hot: hot) else { return }
            if used == buttonLayers.count {
                let layer = MergeStillLayer()
                layer.anchorPoint = .zero
                layer.zPosition = 8
                root.addSublayer(layer)
                buttonLayers.append(layer)
            }
            let layer = buttonLayers[used]
            used += 1
            place(layer, rect)
            layer.contentsScale = scale
            layer.contents = img
            layer.isHidden = false
            buttonHits.append(ButtonHit(rect: rect, chunk: chunkIndex, side: side, isIgnore: isIgnore, icon: icon))
        }

        let lbX = leftBridgeX
        let rbX = rightBridgeX

        for (index, chunk) in doc.chunks.enumerated() {
            if chunk.isLeftUnresolved {
                let l0 = CGFloat(chunk.leftRange.lowerBound) * lh - scroll.left
                let l1 = CGFloat(chunk.leftRange.upperBound) * lh - scroll.left
                let c0 = CGFloat(chunk.centerRange.lowerBound) * lh - scroll.center
                let c1 = CGFloat(chunk.centerRange.upperBound) * lh - scroll.center
                if min(l0, c0) <= h, max(l1, c1) >= 0 {
                    let topAnchor = (l0 + c0) * 0.5
                    let bottom = max(l1, c1)
                    let y = pixelRound(max(topAnchor - size * 0.35, min(4, bottom - size - 3)))
                    let clampedY = max(2, min(h - size - 2, y))
                    let acceptIcon: ActionIcon = chunk.isAppendMode(for: .left) ? .appendLeft : .acceptLeft
                    addButton(
                        rect: CGRect(x: pixelRound(lbX + 3), y: clampedY, width: size, height: size),
                        chunkIndex: index, side: .left, isIgnore: false, icon: acceptIcon
                    )
                    addButton(
                        rect: CGRect(x: pixelRound(lbX + Self.bridgeWidth - size - 3), y: clampedY, width: size, height: size),
                        chunkIndex: index, side: .left, isIgnore: true, icon: .ignoreLeft
                    )
                }
            }

            if chunk.isRightUnresolved {
                let r0 = CGFloat(chunk.rightRange.lowerBound) * lh - scroll.right
                let r1 = CGFloat(chunk.rightRange.upperBound) * lh - scroll.right
                let c0 = CGFloat(chunk.centerRange.lowerBound) * lh - scroll.center
                let c1 = CGFloat(chunk.centerRange.upperBound) * lh - scroll.center
                if min(r0, c0) <= h, max(r1, c1) >= 0 {
                    let topAnchor = (r0 + c0) * 0.5
                    let bottom = max(r1, c1)
                    let y = pixelRound(max(topAnchor - size * 0.35, min(4, bottom - size - 3)))
                    let clampedY = max(2, min(h - size - 2, y))
                    let acceptIcon: ActionIcon = chunk.isAppendMode(for: .right) ? .appendRight : .acceptRight
                    addButton(
                        rect: CGRect(x: pixelRound(rbX + 3), y: clampedY, width: size, height: size),
                        chunkIndex: index, side: .right, isIgnore: true, icon: .ignoreRight
                    )
                    addButton(
                        rect: CGRect(x: pixelRound(rbX + Self.bridgeWidth - size - 3), y: clampedY, width: size, height: size),
                        chunkIndex: index, side: .right, isIgnore: false, icon: acceptIcon
                    )
                }
            }
        }

        for layer in buttonLayers[used...] { layer.isHidden = true }
        if let hovered = hoveredButton, !buttonHits.contains(where: { $0.chunk == hovered.chunk && $0.side == hovered.side && $0.isIgnore == hovered.isIgnore }) {
            hoveredButton = nil
        }
    }

    private func buttonGlyph(icon: ActionIcon, hot: Bool) -> CGImage? {
        let size = actionButtonSize
        let scale = backingScale
        let key = "\(icon.rawValue)|\(hot)|\(theme.isDark)|\(scale)|\(size)"
        if let cached = buttonGlyphs[key] { return cached }

        let px = Int(ceil(size * scale))
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        let pill = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: size - 1, height: size - 1), cornerWidth: 4.5, cornerHeight: 4.5, transform: nil)
        let isAppend = icon == .appendLeft || icon == .appendRight
        let bg: CGColor
        let border: CGColor
        let stroke: CGColor
        if hot {
            bg = icon.isIgnore ? theme.conflictMark : (isAppend ? theme.addedMark : theme.accent)
            border = bg
            stroke = NSColor.white.cgColor
        } else {
            bg = theme.background.copy(alpha: 0.94) ?? theme.background
            border = isAppend ? theme.addedBorder : theme.separator
            stroke = icon.isIgnore ? theme.gutterTextStrong : (isAppend ? theme.addedMark : theme.accent)
        }

        ctx.addPath(pill)
        ctx.setFillColor(bg)
        ctx.fillPath()
        ctx.addPath(pill)
        ctx.setStrokeColor(border)
        ctx.setLineWidth(1)
        ctx.strokePath()

        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(1.5)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        let mid = size * 0.5
        switch icon {
        case .acceptLeft:
            drawChevron(ctx, tipX: size * 0.44, midY: mid, halfH: size * 0.21, dx: -size * 0.18)
            drawChevron(ctx, tipX: size * 0.72, midY: mid, halfH: size * 0.21, dx: -size * 0.18)
        case .acceptRight:
            drawChevron(ctx, tipX: size * 0.28, midY: mid, halfH: size * 0.21, dx: size * 0.18)
            drawChevron(ctx, tipX: size * 0.56, midY: mid, halfH: size * 0.21, dx: size * 0.18)
        case .appendLeft:
            drawPlus(ctx, cx: size * 0.30, cy: mid, r: size * 0.15)
            drawChevron(ctx, tipX: size * 0.76, midY: mid, halfH: size * 0.19, dx: -size * 0.17)
        case .appendRight:
            drawChevron(ctx, tipX: size * 0.24, midY: mid, halfH: size * 0.19, dx: size * 0.17)
            drawPlus(ctx, cx: size * 0.70, cy: mid, r: size * 0.15)
        case .ignoreLeft, .ignoreRight:
            let r = size * 0.19
            ctx.move(to: CGPoint(x: mid - r, y: mid - r))
            ctx.addLine(to: CGPoint(x: mid + r, y: mid + r))
            ctx.move(to: CGPoint(x: mid + r, y: mid - r))
            ctx.addLine(to: CGPoint(x: mid - r, y: mid + r))
            ctx.strokePath()
        }

        let image = ctx.makeImage()
        buttonGlyphs[key] = image
        return image
    }

    private func drawChevron(_ ctx: CGContext, tipX: CGFloat, midY: CGFloat, halfH: CGFloat, dx: CGFloat) {
        ctx.move(to: CGPoint(x: tipX + dx, y: midY - halfH))
        ctx.addLine(to: CGPoint(x: tipX, y: midY))
        ctx.addLine(to: CGPoint(x: tipX + dx, y: midY + halfH))
        ctx.strokePath()
    }

    private func drawPlus(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, r: CGFloat) {
        ctx.move(to: CGPoint(x: cx - r, y: cy))
        ctx.addLine(to: CGPoint(x: cx + r, y: cy))
        ctx.move(to: CGPoint(x: cx, y: cy - r))
        ctx.addLine(to: CGPoint(x: cx, y: cy + r))
        ctx.strokePath()
    }

    private func buttonHit(at point: CGPoint) -> ButtonHit? {
        buttonHits.first { $0.rect.insetBy(dx: -2, dy: -2).contains(point) }
    }

    private func updateHoverHint() {
        guard let hovered = hoveredButton, let doc = document, doc.chunks.indices.contains(hovered.chunk) else {
            delegate?.mergeCanvas(self, hoverHint: nil)
            return
        }
        let chunk = doc.chunks[hovered.chunk]
        let hint: String
        if hovered.isIgnore {
            hint = hovered.side == .left
                ? L("Ignore Left change (✕)", "忽略左侧改动 (✕)")
                : L("Ignore Right change (✕)", "忽略右侧改动 (✕)")
        } else if chunk.isAppendMode(for: hovered.side) {
            hint = hovered.side == .left
                ? L("Append Left after accepted Right (+»)", "将左侧追加到已采纳的右侧之后 (+»)")
                : L("Append Right after accepted Left (+«)", "将右侧追加到已采纳的左侧之后 (+«)")
        } else {
            hint = hovered.side == .left
                ? L("Accept Left into Result (»)", "采用左侧改动到合并结果 (»)")
                : L("Accept Right into Result («)", "采用右侧改动到合并结果 («)")
        }
        delegate?.mergeCanvas(self, hoverHint: hint)
    }

    // MARK: Overview Ruler

    private var rulerScale: CGFloat {
        let total = CGFloat(rowCount) + Self.bottomPadding / codeFont.lineHeight
        return min(codeFont.lineHeight, bounds.height / max(1, total))
    }

    private func updateRuler(_ doc: ThreeWayMergeDocument, _ scroll: Scroll, marks: Bool) {
        let lh = codeFont.lineHeight
        let h = bounds.height
        let scale = rulerScale
        let scrollable = CGFloat(rowCount) * lh + Self.bottomPadding > h
        rulerThumb.isHidden = !scrollable
        if scrollable {
            rulerThumb.backgroundColor = theme.rulerThumb
            rulerThumb.frame = CGRect(x: 1, y: scroll.y / lh * scale, width: Self.rulerWidth - 2, height: max(12, h / lh * scale))
        }
        guard marks else { return }
        let paths = [CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for index in doc.chunks.indices {
            let chunk = doc.chunks[index]
            let vStart = doc.virtualStart(ofChunk: index)
            let span = max(1, doc.virtualSpan(ofChunk: index))
            let bucket = bucket(for: chunk, on: .center)
            let rect = CGRect(x: 3, y: CGFloat(vStart) * scale, width: Self.rulerWidth - 6, height: max(2.5, CGFloat(span) * scale))
            paths[bucket].addRect(rect)
        }
        let colors = [theme.modifiedMark, theme.addedMark, theme.deletedMark, theme.conflictMark, theme.resolvedBorder]
        for k in 0..<5 {
            rulerMarks[k].contentsScale = backingScale
            rulerMarks[k].fillColor = colors[k]
            rulerMarks[k].path = paths[k].isEmpty ? nil : paths[k]
        }
    }

    // MARK: Caret

    private func updateCaret() {
        guard let doc = document,
              let sel = selection, sel.pane == .center,
              let window, window.isKeyWindow || CodeCanvasView.assumeKeyWindow, window.firstResponder === self else {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            caretFrame = .null
            compositionUnderline.clear()
            return
        }

        let lh = codeFont.lineHeight
        let pos: TextPosition
        let x0: CGFloat
        if doc.center.lines.isEmpty {
            pos = TextPosition(row: 0, column: 0)
            x0 = Self.textInset
        } else {
            pos = TextEditing.clamp(sel.head, in: doc.center.lines)
            x0 = Self.textInset + CTLineGetOffsetForStringIndex(ctLine(.center, pos.row), pos.column, nil)
        }

        let frame = CGRect(x: pixelRound(x0 - 1), y: CGFloat(pos.row) * lh, width: 2, height: lh)
        caretLayer.backgroundColor = theme.text
        if frame != caretFrame || caretLayer.isHidden {
            caretFrame = frame
            caretLayer.frame = frame
            caretLayer.isHidden = false
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

        if let marked = doc.marked, marked.row < doc.center.lines.count {
            var rects: [CGRect] = []
            appendRects([marked.range], pane: .center, line: marked.row, to: &rects)
            compositionUnderline.set(rects.map { CGRect(x: $0.minX, y: $0.maxY - 1.5, width: $0.width, height: 1.5) }, color: theme.text)
        } else {
            compositionUnderline.clear()
        }
    }

    // MARK: Mouse & Hit Testing

    private func pane(at point: CGPoint) -> MergePane {
        let w = Self.paneWidths(totalWidth: bounds.width)
        if point.x < w.left + Self.bridgeWidth * 0.5 { return .left }
        if point.x < w.left + Self.bridgeWidth + w.center + Self.bridgeWidth * 0.5 { return .center }
        return .right
    }

    private func position(at point: CGPoint, pane: MergePane) -> TextPosition? {
        guard let doc = document else { return nil }
        let buf = buffer(for: pane, in: doc)
        if buf.lines.isEmpty {
            return pane == .center ? TextPosition(row: 0, column: 0) : nil
        }
        let scroll = resolveScroll()
        let top = paneScrollTop(pane, in: scroll)
        let rawRow = Int(floor((point.y + top) / codeFont.lineHeight))
        if rawRow < 0 { return TextPosition(row: 0, column: 0) }
        let row = min(rawRow, buf.lines.count - 1)
        let line = ctLine(pane, row)
        if rawRow >= buf.lines.count {
            return TextPosition(row: row, column: CTLineGetStringRange(line).length)
        }
        let x = point.x - (textRect(pane).minX + Self.textInset - scroll.x)
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: x, y: 0))
        return TextPosition(row: row, column: max(0, index == kCFNotFound ? 0 : index))
    }

    private func lineText(_ pane: MergePane, row: Int) -> NSString {
        guard let doc = document else { return "" }
        let buf = buffer(for: pane, in: doc)
        guard row >= 0, row < buf.lines.count else { return "" }
        return buf.lines[row] as NSString
    }

    private func wordRange(in text: NSString, at column: Int) -> Range<Int> {
        let length = text.length
        guard length > 0 else { return 0..<0 }
        func isWord(_ c: unichar) -> Bool {
            (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 0x80
        }
        let pivot = min(max(0, column), length - 1)
        guard isWord(text.character(at: pivot)) else { return pivot..<(pivot + 1) }
        var start = pivot
        var end = pivot + 1
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        while end < length, isWord(text.character(at: end)) { end += 1 }
        return start..<end
    }

    func chunkIndex(at point: CGPoint) -> Int? {
        guard let doc = document else { return nil }
        let p = pane(at: point)
        let scroll = resolveScroll()
        let top = paneScrollTop(p, in: scroll)
        let line = Int(floor((point.y + top) / codeFont.lineHeight))
        for (index, chunk) in doc.chunks.enumerated() {
            let range = chunkRange(for: chunk, on: p)
            if range.isEmpty {
                if abs(range.lowerBound - line) <= 0 { return index }
            } else if range.contains(line) {
                return index
            }
        }
        return nil
    }

    func handleMouseMoved(_ event: NSEvent?) {
        let point = event.map { convert($0.locationInWindow, from: nil) }
        let hit = point.flatMap(buttonHit(at:))
        let next: (chunk: Int, side: MergeSide, isIgnore: Bool)? = hit.map { (chunk: $0.chunk, side: $0.side, isIgnore: $0.isIgnore) }
        if next?.chunk != hoveredButton?.chunk || next?.side != hoveredButton?.side || next?.isIgnore != hoveredButton?.isIgnore {
            hoveredButton = next
        }
        if hit != nil {
            NSCursor.pointingHand.set()
        } else if let point, point.x >= bounds.width - Self.rulerWidth {
            NSCursor.arrow.set()
        } else {
            NSCursor.iBeam.set()
        }
    }

    func handleMouseDown(_ event: NSEvent) {
        window?.makeFirstResponder(self)
        commitComposition()
        document?.closeGroup()
        goalX = nil
        let point = convert(event.locationInWindow, from: nil)

        if point.x >= bounds.width - Self.rulerWidth {
            draggingRuler = true
            scrollRuler(to: point)
            return
        }
        if let hit = buttonHit(at: point) {
            pressedButton = (hit.chunk, hit.side, hit.isIgnore)
            return
        }
        let targetPane = pane(at: point)
        if let idx = chunkIndex(at: point) {
            delegate?.mergeCanvas(self, focusChunk: idx)
        }
        guard let pos = position(at: point, pane: targetPane) else {
            selection = nil
            return
        }
        switch event.clickCount {
        case 2:
            let range = wordRange(in: lineText(targetPane, row: pos.row), at: pos.column)
            selection = MergeSelection(pane: targetPane, anchor: TextPosition(row: pos.row, column: range.lowerBound), head: TextPosition(row: pos.row, column: range.upperBound))
        case 3...:
            selection = MergeSelection(pane: targetPane, anchor: TextPosition(row: pos.row, column: 0), head: TextPosition(row: pos.row, column: lineText(targetPane, row: pos.row).length))
        default:
            if event.modifierFlags.contains(.shift), let current = selection, current.pane == targetPane {
                selection = MergeSelection(pane: targetPane, anchor: current.anchor, head: pos)
            } else {
                selection = MergeSelection(pane: targetPane, anchor: pos, head: pos)
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
        guard pressedButton == nil, dragSelecting, let current = selection else { return }
        if point.y < 0 {
            container?.scrollBy(dx: 0, dy: max(-60, point.y))
        } else if point.y > bounds.height {
            container?.scrollBy(dx: 0, dy: min(60, point.y - bounds.height))
        }
        if let pos = position(at: point, pane: current.pane) {
            selection = MergeSelection(pane: current.pane, anchor: current.anchor, head: pos)
        }
    }

    func handleMouseUp(_ event: NSEvent) {
        draggingRuler = false
        dragSelecting = false
        if let pressed = pressedButton {
            pressedButton = nil
            let point = convert(event.locationInWindow, from: nil)
            if let hit = buttonHit(at: point),
               hit.chunk == pressed.chunk, hit.side == pressed.side, hit.isIgnore == pressed.isIgnore {
                if hit.isIgnore {
                    delegate?.mergeCanvas(self, ignoreSide: hit.side, chunk: hit.chunk)
                } else {
                    delegate?.mergeCanvas(self, acceptSide: hit.side, chunk: hit.chunk)
                }
            }
            return
        }
        if let current = selection, current.pane != .center, current.isEmpty {
            selection = nil
        }
    }

    func buildContextMenu(for event: NSEvent) -> NSMenu? {
        guard let doc = document else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let idx = chunkIndex(at: point), doc.chunks.indices.contains(idx) {
            let chunk = doc.chunks[idx]
            if chunk.isConflict {
                menu.addItem(ClosureMenuItem(L("Accept Left", "采用左侧")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, resolveConflict: idx, choice: .acceptLeft)
                })
                menu.addItem(ClosureMenuItem(L("Accept Right", "采用右侧")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, resolveConflict: idx, choice: .acceptRight)
                })
                menu.addItem(ClosureMenuItem(L("Accept Both (Left + Right)", "两边一起（先左后右）")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, resolveConflict: idx, choice: .acceptBothLeftFirst)
                })
                menu.addItem(ClosureMenuItem(L("Accept Both (Right + Left)", "两边一起（先右后左）")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, resolveConflict: idx, choice: .acceptBothRightFirst)
                })
                menu.addItem(ClosureMenuItem(L("Keep Base (Ignore Both)", "保留共同祖先（两边都忽略）")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, resolveConflict: idx, choice: .keepBase)
                })
                menu.addItem(.separator())
            } else if chunk.isUnresolvedNonConflict {
                let side: MergeSide = chunk.hasLeftChange ? .left : .right
                menu.addItem(ClosureMenuItem(side == .left ? L("Accept Left", "采用左侧") : L("Accept Right", "采用右侧")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, acceptSide: side, chunk: idx)
                })
                menu.addItem(ClosureMenuItem(L("Ignore Change", "忽略此改动")) { [weak self] in
                    guard let self else { return }
                    self.delegate?.mergeCanvas(self, ignoreSide: side, chunk: idx)
                })
                menu.addItem(.separator())
            }
        }
        if centerEditSelection != nil {
            menu.addItem(ClosureMenuItem(L("Cut", "剪切")) { [weak self] in self?.cut(nil) })
        }
        if selectedText() != nil || caretLineText() != nil {
            menu.addItem(ClosureMenuItem(L("Copy", "复制")) { [weak self] in self?.copy(nil) })
        }
        if centerEditSelection != nil, pasteboard.availableType(from: [.string]) != nil {
            menu.addItem(ClosureMenuItem(L("Paste", "粘贴")) { [weak self] in self?.paste(nil) })
        }
        menu.addItem(ClosureMenuItem(L("Select All", "全选")) { [weak self] in self?.selectAll(nil) })
        return menu
    }

    private func scrollRuler(to point: CGPoint) {
        let row = point.y / max(0.0001, rulerScale)
        container?.scroll(toY: row * codeFont.lineHeight - bounds.height / 2, animated: false)
    }

    // MARK: Center Editing & Selection

    var centerEditSelection: EditorSession.Selection? {
        guard let doc = document, let sel = selection, sel.pane == .center else { return nil }
        if doc.center.lines.isEmpty {
            return (TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0))
        }
        return (
            TextEditing.clamp(sel.anchor, in: doc.center.lines),
            TextEditing.clamp(sel.head, in: doc.center.lines)
        )
    }

    func setCenterSelection(_ sel: EditorSession.Selection) {
        guard let doc = document else { return }
        if doc.center.lines.isEmpty {
            selection = MergeSelection(pane: .center, anchor: TextPosition(row: 0, column: 0), head: TextPosition(row: 0, column: 0))
            return
        }
        let a = TextEditing.clamp(sel.anchor, in: doc.center.lines)
        let b = TextEditing.clamp(sel.head, in: doc.center.lines)
        selection = MergeSelection(pane: .center, anchor: a, head: b)
    }

    func setCenterCaret(_ position: TextPosition) {
        setCenterSelection((position, position))
    }

    private var centerLines: [String] { document?.center.lines ?? [] }
    private var centerLastRow: Int { max(0, centerLines.count - 1) }

    private func centerLineLength(_ row: Int) -> Int {
        row >= 0 && row < centerLines.count ? centerLines[row].utf16.count : 0
    }

    private var documentEnd: TextPosition {
        TextPosition(row: centerLastRow, column: centerLineLength(centerLastRow))
    }

    private func xOffset(line: Int, column: Int) -> CGFloat {
        guard let doc = document, line < doc.center.lines.count else { return 0 }
        return CTLineGetOffsetForStringIndex(ctLine(.center, line), column, nil)
    }

    private func column(line: Int, atX x: CGFloat) -> Int {
        guard let doc = document, line < doc.center.lines.count else { return 0 }
        let idx = CTLineGetStringIndexForPosition(ctLine(.center, line), CGPoint(x: x, y: 0))
        let len = doc.center.lines[line].utf16.count
        return idx == kCFNotFound ? 0 : min(max(0, idx), len)
    }

    func revealCenterCaret() {
        guard let container, let doc = document, let sel = centerEditSelection else { return }
        let lh = codeFont.lineHeight
        let head = sel.head
        let margin = codeFont.charWidth * 4
        let width = textRect(.center).width
        for _ in 0..<4 {
            let scroll = resolveScroll()
            let y = CGFloat(head.row) * lh - scroll.center
            var dy: CGFloat = 0
            if y < lh * 0.5 {
                dy = y - lh * 0.5
            } else if y + lh * 1.5 > bounds.height {
                dy = y + lh * 1.5 - bounds.height
            }
            var dx: CGFloat = 0
            let x = Self.textInset + xOffset(line: head.row, column: head.column) - scroll.x
            if x < margin, scroll.x > 0 {
                dx = max(-scroll.x, x - margin)
            } else if x > width - margin && !doc.center.lines.isEmpty {
                dx = x - (width - margin)
            }
            guard abs(dy) >= 0.5 || abs(dx) >= 0.5 else { break }
            container.scrollBy(dx: dx, dy: dy)
        }
    }

    private func replaceCenterText(_ from: TextPosition, _ to: TextPosition, with text: String, kind: EditorSession.Kind, caret: TextPosition? = nil) {
        guard let doc = document, let before = centerEditSelection else { return }
        let anchor = min(from, to).row
        let result = doc.replaceCenter(from: from, to: to, with: text, kind: kind, selection: before)
        refreshAfterDocumentMutation(preservingAnchorLine: anchor, restoreSelection: (caret ?? result.end, caret ?? result.end))
        goalX = nil
        revealCenterCaret()
        delegate?.mergeCanvasDidEditCenter(self)
    }

    private func typeText(_ text: String) {
        guard let sel = centerEditSelection else { return }
        let lower = min(sel.anchor, sel.head)
        let upper = max(sel.anchor, sel.head)
        if lower == upper, text == "}", let doc = document, !doc.center.lines.isEmpty, lower.row < doc.center.lines.count {
            let unit = doc.indentUnit
            let before = (doc.center.lines[lower.row] as NSString).substring(to: lower.column)
            let after = (doc.center.lines[lower.row] as NSString).substring(from: lower.column)
            if before.hasSuffix(unit), before.utf8.allSatisfy({ $0 == 32 || $0 == 9 }), after.utf8.allSatisfy({ $0 == 32 || $0 == 9 }) {
                replaceCenterText(TextPosition(row: lower.row, column: lower.column - unit.utf16.count), lower, with: text, kind: .typing)
                return
            }
        }
        replaceCenterText(lower, upper, with: text, kind: text.contains("\n") || text.contains("\r") ? .other : .typing)
    }

    private func deleteSelection(orTo target: (TextPosition) -> TextPosition) {
        guard let sel = centerEditSelection else { return }
        if sel.anchor != sel.head {
            replaceCenterText(sel.anchor, sel.head, with: "", kind: .other)
            return
        }
        let to = target(sel.head)
        guard to != sel.head else { NSSound.beep(); return }
        replaceCenterText(sel.head, to, with: "", kind: .deleting)
    }

    private func characterBefore(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty else { return p }
        if p.column > 0 {
            return TextPosition(row: p.row, column: TextEditing.characterBoundary(in: centerLines[p.row] as NSString, from: p.column, forward: false))
        }
        return p.row > 0 ? TextPosition(row: p.row - 1, column: centerLineLength(p.row - 1)) : p
    }

    private func characterAfter(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty else { return p }
        if p.column < centerLineLength(p.row) {
            return TextPosition(row: p.row, column: TextEditing.characterBoundary(in: centerLines[p.row] as NSString, from: p.column, forward: true))
        }
        return p.row < centerLastRow ? TextPosition(row: p.row + 1, column: 0) : p
    }

    private func wordBefore(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty, p.column > 0 else { return characterBefore(p) }
        return TextPosition(row: p.row, column: TextEditing.wordBoundary(in: centerLines[p.row] as NSString, from: p.column, forward: false))
    }

    private func wordAfter(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty, p.column < centerLineLength(p.row) else { return characterAfter(p) }
        return TextPosition(row: p.row, column: TextEditing.wordBoundary(in: centerLines[p.row] as NSString, from: p.column, forward: true))
    }

    private func smartLineStart(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty, p.row < centerLines.count else { return TextPosition(row: 0, column: 0) }
        let indent = (TextEditing.indentation(of: centerLines[p.row]) as NSString).length
        return TextPosition(row: p.row, column: p.column == indent ? 0 : indent)
    }

    private func backspaceTarget(_ p: TextPosition) -> TextPosition {
        guard !centerLines.isEmpty, p.column > 0, let doc = document, doc.indentUnit != "\t" else { return characterBefore(p) }
        let before = (centerLines[p.row] as NSString).substring(to: p.column)
        guard before.utf8.allSatisfy({ $0 == 32 }) else { return characterBefore(p) }
        let width = max(1, doc.indentUnit.utf16.count)
        return TextPosition(row: p.row, column: p.column - ((p.column - 1) % width + 1))
    }

    private func moveCaret(to target: (EditorSession.Selection) -> TextPosition, extend: Bool, collapse: ((EditorSession.Selection) -> TextPosition)? = nil) {
        guard let doc = document, let sel = centerEditSelection else { return }
        doc.closeGroup()
        let head: TextPosition
        if !extend, sel.anchor != sel.head, let collapse { head = collapse(sel) } else { head = target(sel) }
        setCenterSelection(extend ? (sel.anchor, head) : (head, head))
        goalX = nil
        revealCenterCaret()
    }

    private func moveVertically(_ delta: Int, extend: Bool) {
        guard let doc = document, let sel = centerEditSelection, !doc.center.lines.isEmpty else { return }
        doc.closeGroup()
        let head = sel.head
        let x = goalX ?? xOffset(line: head.row, column: head.column)
        let row = head.row + delta
        let target: TextPosition
        if row < 0 {
            target = TextPosition(row: 0, column: 0)
        } else if row > centerLastRow {
            target = documentEnd
        } else {
            target = TextPosition(row: row, column: column(line: row, atX: x))
        }
        setCenterSelection(extend ? (sel.anchor, target) : (target, target))
        goalX = x
        revealCenterCaret()
    }

    private func insertNewline() {
        guard let doc = document, let sel = centerEditSelection else { return }
        if doc.center.lines.isEmpty {
            replaceCenterText(TextPosition(row: 0, column: 0), TextPosition(row: 0, column: 0), with: "\n", kind: .typing)
            return
        }
        var lower = min(sel.anchor, sel.head)
        let upper = max(sel.anchor, sel.head)
        let line = centerLines[lower.row] as NSString
        let before = line.substring(to: lower.column)
        var indent = TextEditing.indentation(of: centerLines[lower.row])
        if (indent as NSString).length > lower.column { indent = before }
        if before.trimmingCharacters(in: .whitespaces).isEmpty { lower = TextPosition(row: lower.row, column: 0) }
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        let unit = doc.indentUnit
        if let last = trimmed.last, ["{", "[", "("].contains(last) {
            replaceCenterText(lower, upper, with: "\n" + indent + unit, kind: .typing)
            return
        }
        replaceCenterText(lower, upper, with: "\n" + indent, kind: .typing)
    }

    private func insertTab() {
        guard let doc = document, let sel = centerEditSelection else { return }
        let p = sel.head
        let unit = doc.indentUnit
        var text = unit
        if unit != "\t", p.row < centerLines.count {
            let width = max(1, unit.utf16.count)
            let visual = TextEditing.visualColumn(of: centerLines[p.row] as NSString, at: p.column)
            text = String(repeating: " ", count: width - visual % width)
        }
        replaceCenterText(min(sel.anchor, sel.head), max(sel.anchor, sel.head), with: text, kind: .typing)
    }

    func deleteLines() {
        guard let sel = centerEditSelection, !centerLines.isEmpty else { return }
        let lower = min(sel.anchor, sel.head)
        let upper = max(sel.anchor, sel.head)
        var last = upper.row
        if upper.row > lower.row, upper.column == 0 { last -= 1 }
        let from: TextPosition
        let to: TextPosition
        if last < centerLastRow {
            from = TextPosition(row: lower.row, column: 0)
            to = TextPosition(row: last + 1, column: 0)
        } else if lower.row > 0 {
            from = TextPosition(row: lower.row - 1, column: centerLineLength(lower.row - 1))
            to = TextPosition(row: last, column: centerLineLength(last))
        } else {
            from = TextPosition(row: 0, column: 0)
            to = TextPosition(row: last, column: centerLineLength(last))
        }
        guard from != to else { NSSound.beep(); return }
        replaceCenterText(from, to, with: "", kind: .other)
    }

    // MARK: Clipboard & Selection Operations

    func selectedText() -> String? {
        guard let doc = document, let sel = selection, !sel.isEmpty else { return nil }
        let buf = buffer(for: sel.pane, in: doc)
        return TextEditing.text(buf.lines, from: sel.lower, to: sel.upper)
    }

    private func caretLineText() -> String? {
        guard let sel = centerEditSelection, sel.anchor == sel.head, sel.head.row < centerLines.count else { return nil }
        return centerLines[sel.head.row] + "\n"
    }

    @objc func copy(_ sender: Any?) {
        if let text = selectedText() {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lineClipboard = nil
        } else if let line = caretLineText() {
            pasteboard.clearContents()
            pasteboard.setString(line, forType: .string)
            lineClipboard = line
        }
    }

    @objc func cut(_ sender: Any?) {
        guard centerEditSelection != nil else { NSSound.beep(); return }
        commitComposition()
        guard let sel = centerEditSelection else { return }
        if sel.anchor == sel.head {
            guard let line = caretLineText() else { return }
            pasteboard.clearContents()
            pasteboard.setString(line, forType: .string)
            lineClipboard = line
            deleteLines()
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(TextEditing.text(centerLines, from: sel.anchor, to: sel.head), forType: .string)
        lineClipboard = nil
        replaceCenterText(sel.anchor, sel.head, with: "", kind: .other)
    }

    @objc func paste(_ sender: Any?) {
        guard centerEditSelection != nil else { NSSound.beep(); return }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        commitComposition()
        guard let sel = centerEditSelection else { return }
        if let line = lineClipboard, line == text, sel.anchor == sel.head {
            let start = TextPosition(row: sel.head.row, column: 0)
            let added = TextEditing.lines(of: text).count - 1
            replaceCenterText(start, start, with: text, kind: .other, caret: TextPosition(row: sel.head.row + added, column: sel.head.column))
            return
        }
        replaceCenterText(sel.anchor, sel.head, with: text, kind: .other)
    }

    override func selectAll(_ sender: Any?) {
        guard let doc = document else { return }
        let targetPane = selection?.pane ?? .center
        if targetPane == .center { commitComposition() }
        let buf = buffer(for: targetPane, in: doc)
        guard !buf.lines.isEmpty else { return }
        let last = buf.lines.count - 1
        selection = MergeSelection(
            pane: targetPane,
            anchor: TextPosition(row: 0, column: 0),
            head: TextPosition(row: last, column: buf.lines[last].utf16.count)
        )
    }

    /// Drops an active text selection (leaving a center caret in place). Returns true if a non-empty selection was cleared.
    @discardableResult
    func clearTextSelection() -> Bool {
        guard let sel = selection, !sel.isEmpty else { return false }
        if sel.pane == .center {
            setCenterCaret(sel.head)
        } else {
            selection = nil
        }
        return true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if document != nil, handleEditingKey(event) { return }
        super.keyDown(with: event)
    }

    private func handleEditingKey(_ event: NSEvent) -> Bool {
        guard let doc = document else { return false }
        if centerEditSelection == nil {
            setCenterCaret(TextPosition(row: 0, column: 0))
        }
        guard let sel = centerEditSelection else { return false }
        if doc.marked == nil {
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let shift = flags.contains(.shift)
            switch event.keyCode {
            case 115: // Home
                if flags.contains(.command) {
                    moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: shift)
                } else {
                    moveCaret(to: { self.smartLineStart($0.head) }, extend: shift)
                }
                return true
            case 119: // End
                if flags.contains(.command) {
                    moveCaret(to: { _ in self.documentEnd }, extend: shift)
                } else {
                    moveCaret(to: { TextPosition(row: $0.head.row, column: self.centerLineLength($0.head.row)) }, extend: shift)
                }
                return true
            case 116: // Page Up
                let page = max(1, Int(bounds.height / codeFont.lineHeight) - 2)
                container?.scrollBy(dx: 0, dy: CGFloat(-page) * codeFont.lineHeight)
                moveVertically(-page, extend: shift)
                return true
            case 121: // Page Down
                let page = max(1, Int(bounds.height / codeFont.lineHeight) - 2)
                container?.scrollBy(dx: 0, dy: CGFloat(page) * codeFont.lineHeight)
                moveVertically(page, extend: shift)
                return true
            case 51 where flags == .command:
                deleteLines()
                return true
            case 53:
                if sel.anchor != sel.head {
                    setCenterCaret(sel.head)
                    return true
                }
                return false
            default:
                break
            }
        }
        interpretKeyEvents([event])
        return true
    }

    override var inputContext: NSTextInputContext? { document == nil ? nil : super.inputContext }

    override func doCommand(by selector: Selector) {
        guard document != nil else { super.doCommand(by: selector); return }
        if !performEditingCommand(selector) { NSSound.beep() }
    }

    private func performEditingCommand(_ selector: Selector) -> Bool {
        guard document != nil, centerEditSelection != nil else { return false }
        switch NSStringFromSelector(selector) {
        case "moveLeft:", "moveBackward:":
            moveCaret(to: { self.characterBefore($0.head) }, extend: false, collapse: { min($0.anchor, $0.head) })
        case "moveRight:", "moveForward:":
            moveCaret(to: { self.characterAfter($0.head) }, extend: false, collapse: { max($0.anchor, $0.head) })
        case "moveLeftAndModifySelection:", "moveBackwardAndModifySelection:":
            moveCaret(to: { self.characterBefore($0.head) }, extend: true)
        case "moveRightAndModifySelection:", "moveForwardAndModifySelection:":
            moveCaret(to: { self.characterAfter($0.head) }, extend: true)
        case "moveUp:": moveVertically(-1, extend: false)
        case "moveDown:": moveVertically(1, extend: false)
        case "moveUpAndModifySelection:": moveVertically(-1, extend: true)
        case "moveDownAndModifySelection:": moveVertically(1, extend: true)
        case "moveWordLeft:", "moveWordBackward:":
            moveCaret(to: { self.wordBefore($0.head) }, extend: false)
        case "moveWordRight:", "moveWordForward:":
            moveCaret(to: { self.wordAfter($0.head) }, extend: false)
        case "moveWordLeftAndModifySelection:", "moveWordBackwardAndModifySelection:":
            moveCaret(to: { self.wordBefore($0.head) }, extend: true)
        case "moveWordRightAndModifySelection:", "moveWordForwardAndModifySelection:":
            moveCaret(to: { self.wordAfter($0.head) }, extend: true)
        case "moveToBeginningOfLine:", "moveToLeftEndOfLine:":
            moveCaret(to: { self.smartLineStart($0.head) }, extend: false)
        case "moveToBeginningOfLineAndModifySelection:", "moveToLeftEndOfLineAndModifySelection:":
            moveCaret(to: { self.smartLineStart($0.head) }, extend: true)
        case "moveToBeginningOfParagraph:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: 0) }, extend: false)
        case "moveToBeginningOfParagraphAndModifySelection:", "moveParagraphBackwardAndModifySelection:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: 0) }, extend: true)
        case "moveToEndOfLine:", "moveToRightEndOfLine:", "moveToEndOfParagraph:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: self.centerLineLength($0.head.row)) }, extend: false)
        case "moveToEndOfLineAndModifySelection:", "moveToRightEndOfLineAndModifySelection:",
             "moveToEndOfParagraphAndModifySelection:", "moveParagraphForwardAndModifySelection:":
            moveCaret(to: { TextPosition(row: $0.head.row, column: self.centerLineLength($0.head.row)) }, extend: true)
        case "moveToBeginningOfDocument:":
            moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: false)
        case "moveToBeginningOfDocumentAndModifySelection:":
            moveCaret(to: { _ in TextPosition(row: 0, column: 0) }, extend: true)
        case "moveToEndOfDocument:":
            moveCaret(to: { _ in self.documentEnd }, extend: false)
        case "moveToEndOfDocumentAndModifySelection:":
            moveCaret(to: { _ in self.documentEnd }, extend: true)
        case "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:":
            deleteSelection(orTo: { self.backspaceTarget($0) })
        case "deleteForward:":
            deleteSelection(orTo: { self.characterAfter($0) })
        case "deleteWordBackward:":
            deleteSelection(orTo: { self.wordBefore($0) })
        case "deleteWordForward:":
            deleteSelection(orTo: { self.wordAfter($0) })
        case "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:":
            deleteSelection(orTo: { $0.column > 0 ? TextPosition(row: $0.row, column: 0) : self.characterBefore($0) })
        case "deleteToEndOfLine:", "deleteToEndOfParagraph:":
            deleteSelection(orTo: { $0.column < self.centerLineLength($0.row) ? TextPosition(row: $0.row, column: self.centerLineLength($0.row)) : self.characterAfter($0) })
        case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:", "insertParagraphSeparator:":
            insertNewline()
        case "insertTab:", "insertTabIgnoringFieldEditor:":
            insertTab()
        case "selectAll:":
            selectAll(nil)
        default:
            return false
        }
        return true
    }

    override func becomeFirstResponder() -> Bool {
        invalidate(.selection)
        return true
    }

    override func resignFirstResponder() -> Bool {
        commitComposition()
        invalidate(.selection)
        return true
    }
}

// MARK: - NSTextInputClient

extension MergeCanvasView: @preconcurrency NSTextInputClient {
    private static func plainString(_ string: Any) -> String {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard text.unicodeScalars.contains(where: { (0xF700...0xF8FF).contains($0.value) }) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !(0xF700...0xF8FF).contains($0.value) })
        return String(scalars)
    }

    func commitComposition() {
        guard let taken = removeComposition() else { return }
        inputContext?.discardMarkedText()
        setCenterCaret(taken.at)
        if !taken.text.isEmpty { typeText(taken.text) }
    }

    private func removeComposition() -> (text: String, at: TextPosition)? {
        guard let doc = document, let taken = doc.removeMarked() else { return nil }
        clearLineCache(for: .center)
        panes[MergePane.center.rawValue].dropTiles()
        invalidate([.decor, .selection, .scroll])
        return taken
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard let doc = document else { return }
        let text = Self.plainString(string)
        if let taken = removeComposition() {
            setCenterCaret(taken.at)
        } else if replacementRange.location != NSNotFound {
            setCenterSelection((doc.position(ofOffset: replacementRange.location), doc.position(ofOffset: NSMaxRange(replacementRange))))
        }
        if centerEditSelection == nil { setCenterCaret(TextPosition(row: 0, column: 0)) }
        guard !text.isEmpty else { return }
        typeText(text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let doc = document else { return }
        let text = Self.plainString(string)
        if doc.marked == nil {
            guard !text.isEmpty else { return }
            if replacementRange.location != NSNotFound {
                setCenterSelection((doc.position(ofOffset: replacementRange.location), doc.position(ofOffset: NSMaxRange(replacementRange))))
            }
            if let sel = centerEditSelection, sel.anchor != sel.head {
                replaceCenterText(sel.anchor, sel.head, with: "", kind: .typing)
            }
        }
        if centerEditSelection == nil { setCenterCaret(TextPosition(row: 0, column: 0)) }
        guard let sel = centerEditSelection else { return }
        let start = doc.marked.map { TextPosition(row: $0.row, column: $0.range.lowerBound) } ?? min(sel.anchor, sel.head)
        doc.setMarked(text, at: start)
        clearLineCache(for: .center)
        panes[MergePane.center.rawValue].dropTiles()
        invalidate([.decor, .selection, .scroll])
        if let marked = doc.marked {
            let column = marked.range.lowerBound + min(max(0, selectedRange.location), marked.range.count)
            setCenterCaret(TextPosition(row: marked.row, column: column))
        } else {
            setCenterCaret(start)
        }
        revealCenterCaret()
    }

    func unmarkText() {
        guard let taken = removeComposition() else { return }
        setCenterCaret(taken.at)
        if !taken.text.isEmpty { typeText(taken.text) }
    }

    func selectedRange() -> NSRange {
        guard let doc = document, let sel = centerEditSelection else { return NSRange(location: NSNotFound, length: 0) }
        let a = doc.offset(of: min(sel.anchor, sel.head))
        let b = doc.offset(of: max(sel.anchor, sel.head))
        return NSRange(location: a, length: b - a)
    }

    func markedRange() -> NSRange {
        guard let doc = document, let marked = doc.marked else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: doc.offset(of: TextPosition(row: marked.row, column: marked.range.lowerBound)), length: marked.range.count)
    }

    func hasMarkedText() -> Bool { document?.marked != nil }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let doc = document, range.location != NSNotFound else { return nil }
        let total = doc.totalLength
        let start = min(max(0, range.location), total)
        let end = min(total, start + min(max(0, range.length), 20_000))
        actualRange?.pointee = NSRange(location: start, length: end - start)
        let text = TextEditing.text(doc.center.lines, from: doc.position(ofOffset: start), to: doc.position(ofOffset: end))
        return NSAttributedString(string: text, attributes: [.font: codeFont.font])
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let doc = document, let window else { return .zero }
        let location = range.location == NSNotFound ? selectedRange().location : range.location
        guard location != NSNotFound else { return .zero }
        let from = doc.position(ofOffset: location)
        var to = doc.position(ofOffset: location + max(0, range.length))
        if to.row != from.row { to = TextPosition(row: from.row, column: centerLineLength(from.row)) }
        let start = doc.offset(of: from)
        actualRange?.pointee = NSRange(location: start, length: doc.offset(of: to) - start)
        let lh = codeFont.lineHeight
        let scroll = resolveScroll()
        let tr = textRect(.center)
        let x0 = xOffset(line: from.row, column: from.column)
        let x1 = xOffset(line: from.row, column: to.column)
        let viewRect = CGRect(x: tr.minX + Self.textInset + x0 - scroll.x, y: CGFloat(from.row) * lh - scroll.center, width: max(1, x1 - x0), height: lh)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let doc = document, let window else { return NSNotFound }
        let local = convert(window.convertPoint(fromScreen: point), from: nil)
        guard let pos = position(at: local, pane: .center) else { return NSNotFound }
        return doc.offset(of: pos)
    }
}

extension MergeCanvasView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)): return selectedText() != nil || caretLineText() != nil
        case #selector(cut(_:)): return centerEditSelection != nil
        case #selector(paste(_:)): return centerEditSelection != nil && pasteboard.availableType(from: [.string]) != nil
        default: return true
        }
    }
}

// MARK: - Scroll container

private final class MergeForwardingDocumentView: NSView {
    weak var canvas: MergeCanvasView?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { canvas?.handleMouseDown(event) }
    override func mouseDragged(with event: NSEvent) { canvas?.handleMouseDragged(event) }
    override func mouseUp(with event: NSEvent) { canvas?.handleMouseUp(event) }
    override func menu(for event: NSEvent) -> NSMenu? { canvas?.buildContextMenu(for: event) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard trackingAreas.isEmpty else { return }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { canvas?.handleMouseMoved(event) }
    override func mouseExited(with event: NSEvent) {
        if CodeCanvasView.keepsHoverOnExit { return }
        canvas?.handleMouseMoved(nil)
    }
}

final class MergeScrollContainer: NSView {
    let canvas = MergeCanvasView()
    let scrollView = NSScrollView()
    private let spacer = MergeForwardingDocumentView()
    private var animationTimer: Timer?
    private var laidOutActions: [() -> Void] = []

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
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveScrollStarted), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

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
    }

    private func setOrigin(_ point: CGPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        canvas.scrollOrigin = scrollView.contentView.bounds.origin
    }

    func show(_ doc: ThreeWayMergeDocument?) {
        animationTimer?.invalidate()
        canvas.setDocument(doc)
        updateDocumentSize()
        setOrigin(.zero)
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

    func scroll(toVirtualRow row: Int, fraction: CGFloat = 0.25, animated: Bool) {
        scroll(toY: CGFloat(row) * canvas.codeFont.lineHeight - bounds.height * fraction, animated: animated)
    }
}
