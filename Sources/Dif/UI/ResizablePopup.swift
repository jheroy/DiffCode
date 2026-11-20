import AppKit
import SwiftUI

/// Edges and corners on a resizable popup that a user can drag.
enum PopupResizeEdge: Equatable, Sendable {
    case bottom
    case left
    case right
    case bottomLeft
    case bottomRight
}

/// Static sizing rules and persistence key for a resizable popup kind.
struct PopupSizeSpec: Equatable, Sendable {
    let defaultSize: CGSize
    let minSize: CGSize
    let topPadding: CGFloat
    let horizontalMargin: CGFloat
    let bottomMargin: CGFloat
    let userDefaultsKey: String

    static let references = PopupSizeSpec(
        defaultSize: CGSize(width: 840, height: 540),
        minSize: CGSize(width: 560, height: 340),
        topPadding: 56,
        horizontalMargin: 48,
        bottomMargin: 32,
        userDefaultsKey: "popupSize.references"
    )

    static let fileSymbols = PopupSizeSpec(
        defaultSize: CGSize(width: 840, height: 540),
        minSize: CGSize(width: 560, height: 340),
        topPadding: 56,
        horizontalMargin: 48,
        bottomMargin: 32,
        userDefaultsKey: "popupSize.fileSymbols"
    )

    static let findInPath = PopupSizeSpec(
        defaultSize: CGSize(width: 900, height: 640),
        minSize: CGSize(width: 600, height: 380),
        topPadding: 56,
        horizontalMargin: 48,
        bottomMargin: 32,
        userDefaultsKey: "popupSize.findInPath"
    )

    static let quickOpen = PopupSizeSpec(
        defaultSize: CGSize(width: 660, height: 460),
        minSize: CGSize(width: 480, height: 280),
        topPadding: 90,
        horizontalMargin: 48,
        bottomMargin: 32,
        userDefaultsKey: "popupSize.quickOpen"
    )
}

/// Pure geometry math for clamping and symmetrically resizing centered popups.
enum PopupResizeGeometry {
    /// Clamps a proposed popup size to its minimums and the current window bounds.
    static func clampedSize(
        _ proposed: CGSize,
        spec: PopupSizeSpec,
        windowSize: CGSize
    ) -> CGSize {
        let maxWidth = max(spec.minSize.width, windowSize.width - spec.horizontalMargin)
        let maxHeight = max(spec.minSize.height, windowSize.height - spec.topPadding - spec.bottomMargin)
        let width = min(max(proposed.width, spec.minSize.width), maxWidth)
        let height = min(max(proposed.height, spec.minSize.height), maxHeight)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// Applies a drag translation (`+width` right, `+height` down) from `startSize`,
    /// resizing width symmetrically around the window's horizontal center.
    static func resized(
        from startSize: CGSize,
        edge: PopupResizeEdge,
        translation: CGSize,
        spec: PopupSizeSpec,
        windowSize: CGSize
    ) -> CGSize {
        var width = startSize.width
        var height = startSize.height

        switch edge {
        case .bottom:
            height += translation.height
        case .right:
            width += 2 * translation.width
        case .left:
            width -= 2 * translation.width
        case .bottomRight:
            width += 2 * translation.width
            height += translation.height
        case .bottomLeft:
            width -= 2 * translation.width
            height += translation.height
        }

        return clampedSize(CGSize(width: width, height: height), spec: spec, windowSize: windowSize)
    }

    /// Computes the popup's centered frame inside a window of `windowSize`.
    static func centeredRect(
        size: CGSize,
        spec: PopupSizeSpec,
        windowSize: CGSize
    ) -> CGRect {
        let clamped = clampedSize(size, spec: spec, windowSize: windowSize)
        let x = ((windowSize.width - clamped.width) / 2).rounded()
        return CGRect(x: x, y: spec.topPadding, width: clamped.width, height: clamped.height)
    }

    /// Computes a clamped top-pane height for a vertical list/preview split.
    static func splitListHeight(
        availableHeight: CGFloat,
        ratio: Double,
        minTopHeight: CGFloat = 72,
        minBottomHeight: CGFloat = 72
    ) -> CGFloat {
        let clampedRatio = min(max(ratio, 0.25), 0.75)
        let usable = max(minTopHeight + minBottomHeight, availableHeight)
        let maxTop = max(minTopHeight, usable - minBottomHeight)
        return min(max(minTopHeight, (usable * CGFloat(clampedRatio)).rounded()), maxTop)
    }
}

/// Draggable horizontal split divider between a popup's list and preview panes.
struct PopupSplitDivider: View {
    let availableHeight: CGFloat
    @Binding var ratio: Double
    var defaultRatio: Double = 0.45
    @State private var dragStartRatio: Double?

    var body: some View {
        DividerGrip(axis: .rows, color: .difHairline, onDrag: { translation in
            guard let translation else {
                dragStartRatio = nil
                return
            }
            let baseRatio = dragStartRatio ?? ratio
            if dragStartRatio == nil {
                dragStartRatio = ratio
            }
            let baseHeight = PopupResizeGeometry.splitListHeight(
                availableHeight: availableHeight,
                ratio: baseRatio
            )
            let nextRatio = Double((baseHeight + translation) / max(1, availableHeight))
            ratio = min(max(nextRatio, 0.25), 0.75)
        }, onDoubleClick: {
            ratio = defaultRatio
        })
    }
}

/// Persists per-popup user dimensions in `UserDefaults`.
enum PopupSizeStore {
    static func load(spec: PopupSizeSpec, defaults: UserDefaults = .standard) -> CGSize {
        guard let dict = defaults.dictionary(forKey: spec.userDefaultsKey),
              let width = (dict["width"] as? NSNumber)?.doubleValue,
              let height = (dict["height"] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, width > 0, height > 0 else {
            return spec.defaultSize
        }
        return CGSize(width: width, height: height)
    }

    static func save(_ size: CGSize, spec: PopupSizeSpec, defaults: UserDefaults = .standard) {
        defaults.set(["width": Double(size.width), "height": Double(size.height)], forKey: spec.userDefaultsKey)
    }

    @discardableResult
    static func reset(spec: PopupSizeSpec, defaults: UserDefaults = .standard) -> CGSize {
        defaults.removeObject(forKey: spec.userDefaultsKey)
        return spec.defaultSize
    }
}

/// Wraps a popup view in a horizontally centered, interactively resizable panel with persisted size.
struct ResizablePopup<Content: View>: View {
    let spec: PopupSizeSpec
    @ViewBuilder let content: () -> Content

    @State private var preferredSize: CGSize
    @State private var dragStartSize: CGSize?

    init(spec: PopupSizeSpec, @ViewBuilder content: @escaping () -> Content) {
        self.spec = spec
        self.content = content
        _preferredSize = State(initialValue: PopupSizeStore.load(spec: spec))
    }

    var body: some View {
        GeometryReader { proxy in
            let displayedSize = PopupResizeGeometry.clampedSize(preferredSize, spec: spec, windowSize: proxy.size)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    content()
                        .frame(width: displayedSize.width, height: displayedSize.height)
                        .popupPanel()
                        .overlay {
                            ResizeHandlesOverlay(
                                displayedSize: displayedSize,
                                onDragChanged: { edge, translation in
                                    let base = dragStartSize ?? displayedSize
                                    if dragStartSize == nil {
                                        dragStartSize = displayedSize
                                    }
                                    preferredSize = PopupResizeGeometry.resized(
                                        from: base,
                                        edge: edge,
                                        translation: translation,
                                        spec: spec,
                                        windowSize: proxy.size
                                    )
                                },
                                onDragEnded: {
                                    dragStartSize = nil
                                    PopupSizeStore.save(preferredSize, spec: spec)
                                },
                                onReset: {
                                    dragStartSize = nil
                                    preferredSize = PopupSizeStore.reset(spec: spec)
                                }
                            )
                        }
                        .padding(.top, spec.topPadding)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
        }
        .id(spec.userDefaultsKey)
    }
}

private struct ResizeHandlesOverlay: View {
    let displayedSize: CGSize
    let onDragChanged: (PopupResizeEdge, CGSize) -> Void
    let onDragEnded: () -> Void
    let onReset: () -> Void

    @State private var hoveredEdge: PopupResizeEdge?
    @State private var draggingEdge: PopupResizeEdge?

    private let cornerSize: CGFloat = 14
    private let edgeThickness: CGFloat = 8

    var body: some View {
        ZStack {
            // Left edge handle
            HStack {
                EdgeHandleView(
                    edge: .left,
                    isActive: isActive(.left),
                    onHover: { setHovered(.left, $0) },
                    onDragChanged: { setDragging(.left, $0) },
                    onDragEnded: { endDragging() }
                )
                .frame(width: edgeThickness)
                .padding(.top, 12)
                .padding(.bottom, cornerSize)
                .offset(x: -2)
                Spacer()
            }

            // Right edge handle
            HStack {
                Spacer()
                EdgeHandleView(
                    edge: .right,
                    isActive: isActive(.right),
                    onHover: { setHovered(.right, $0) },
                    onDragChanged: { setDragging(.right, $0) },
                    onDragEnded: { endDragging() }
                )
                .frame(width: edgeThickness)
                .padding(.top, 12)
                .padding(.bottom, cornerSize)
                .offset(x: 2)
            }

            // Bottom edge handle (double-click resets to default size)
            VStack {
                Spacer()
                EdgeHandleView(
                    edge: .bottom,
                    isActive: isActive(.bottom),
                    onHover: { setHovered(.bottom, $0) },
                    onDragChanged: { setDragging(.bottom, $0) },
                    onDragEnded: { endDragging() },
                    onDoubleClick: onReset
                )
                .frame(height: edgeThickness)
                .padding(.horizontal, cornerSize)
                .offset(y: 2)
            }

            // Bottom-left corner handle
            VStack {
                Spacer()
                HStack {
                    CornerHandleView(
                        edge: .bottomLeft,
                        isActive: isActive(.bottomLeft),
                        showGripMark: false,
                        onHover: { setHovered(.bottomLeft, $0) },
                        onDragChanged: { setDragging(.bottomLeft, $0) },
                        onDragEnded: { endDragging() },
                        onDoubleClick: onReset
                    )
                    .frame(width: cornerSize, height: cornerSize)
                    .offset(x: -1, y: 1)
                    Spacer()
                }
            }
            .zIndex(2)

            // Bottom-right corner handle with subtle grip mark
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CornerHandleView(
                        edge: .bottomRight,
                        isActive: isActive(.bottomRight),
                        showGripMark: true,
                        onHover: { setHovered(.bottomRight, $0) },
                        onDragChanged: { setDragging(.bottomRight, $0) },
                        onDragEnded: { endDragging() },
                        onDoubleClick: onReset
                    )
                    .frame(width: cornerSize, height: cornerSize)
                    .offset(x: 1, y: 1)
                }
            }
            .zIndex(2)
        }
        .frame(width: displayedSize.width, height: displayedSize.height)
    }

    private func isActive(_ edge: PopupResizeEdge) -> Bool {
        draggingEdge == edge || (draggingEdge == nil && hoveredEdge == edge)
    }

    private func setHovered(_ edge: PopupResizeEdge, _ hovering: Bool) {
        if hovering {
            hoveredEdge = edge
        } else if hoveredEdge == edge {
            hoveredEdge = nil
        }
    }

    private func setDragging(_ edge: PopupResizeEdge, _ translation: CGSize) {
        draggingEdge = edge
        onDragChanged(edge, translation)
    }

    private func endDragging() {
        draggingEdge = nil
        onDragEnded()
    }
}

private struct EdgeHandleView: View {
    let edge: PopupResizeEdge
    let isActive: Bool
    let onHover: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if isActive {
                Group {
                    if edge == .bottom {
                        Capsule()
                            .fill(Color.difAccent.opacity(0.55))
                            .frame(height: 2)
                            .padding(.horizontal, 12)
                    } else {
                        Capsule()
                            .fill(Color.difAccent.opacity(0.55))
                            .frame(width: 2)
                            .padding(.vertical, 12)
                    }
                }
                .allowsHitTesting(false)
            }
            PopupDragArea(
                edge: edge,
                onHover: onHover,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded,
                onDoubleClick: onDoubleClick
            )
            .popupResizePointer(edge)
        }
    }
}

private struct CornerHandleView: View {
    let edge: PopupResizeEdge
    let isActive: Bool
    let showGripMark: Bool
    let onHover: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    var onDoubleClick: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if showGripMark {
                BottomRightGripMark(isActive: isActive)
                    .allowsHitTesting(false)
            }
            PopupDragArea(
                edge: edge,
                onHover: onHover,
                onDragChanged: onDragChanged,
                onDragEnded: onDragEnded,
                onDoubleClick: onDoubleClick
            )
            .popupResizePointer(edge)
        }
    }
}

private struct BottomRightGripMark: View {
    let isActive: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            // Keep strokes strictly inside the 14pt rounded corner curve.
            path.move(to: CGPoint(x: size.width - 10, y: size.height - 3))
            path.addLine(to: CGPoint(x: size.width - 3, y: size.height - 10))
            path.move(to: CGPoint(x: size.width - 6.5, y: size.height - 3))
            path.addLine(to: CGPoint(x: size.width - 3, y: size.height - 6.5))
            let color = isActive ? Color.difAccent.opacity(0.85) : Color.difText3.opacity(0.5)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}

private extension PopupResizeEdge {
    @MainActor
    var cursor: NSCursor {
        switch self {
        case .bottom:
            if #available(macOS 15.0, *) { return .rowResize }
            return .resizeUpDown
        case .left, .right:
            if #available(macOS 15.0, *) { return .columnResize }
            return .resizeLeftRight
        case .bottomRight:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomRight, directions: .all)
            }
            return .crosshair
        case .bottomLeft:
            if #available(macOS 15.0, *) {
                return .frameResize(position: .bottomLeft, directions: .all)
            }
            return .crosshair
        }
    }
}

private extension View {
    @ViewBuilder
    func popupResizePointer(_ edge: PopupResizeEdge) -> some View {
        if #available(macOS 15.0, *) {
            switch edge {
            case .bottom:
                pointerStyle(.rowResize)
            case .left, .right:
                pointerStyle(.columnResize)
            case .bottomRight:
                pointerStyle(.frameResize(position: .bottomTrailing, directions: .all))
            case .bottomLeft:
                pointerStyle(.frameResize(position: .bottomLeading, directions: .all))
            }
        } else {
            self
        }
    }
}

/// AppKit drag & cursor-rect area using screen coordinates so centered horizontal resizing never oscillates.
private struct PopupDragArea: NSViewRepresentable {
    let edge: PopupResizeEdge
    let onHover: (Bool) -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: () -> Void
    var onDoubleClick: (() -> Void)?

    func makeNSView(context: Context) -> DragNSView {
        DragNSView(edge: edge)
    }

    func updateNSView(_ view: DragNSView, context: Context) {
        if view.edge != edge {
            view.edge = edge
            view.window?.invalidateCursorRects(for: view)
        }
        view.onHover = onHover
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
        view.onDoubleClick = onDoubleClick
    }

    final class DragNSView: NSView {
        var edge: PopupResizeEdge
        var onHover: ((Bool) -> Void)?
        var onDragChanged: ((CGSize) -> Void)?
        var onDragEnded: (() -> Void)?
        var onDoubleClick: (() -> Void)?

        private var dragOriginScreen: NSPoint?

        init(edge: PopupResizeEdge) {
            self.edge = edge
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var mouseDownCanMoveWindow: Bool { false }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: edge.cursor)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                    owner: self
                )
            )
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, dragOriginScreen != nil {
                dragOriginScreen = nil
                onDragEnded?()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func cursorUpdate(with event: NSEvent) {
            edge.cursor.set()
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            if dragOriginScreen == nil {
                onHover?(false)
            }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
                return
            }
            dragOriginScreen = NSEvent.mouseLocation
            edge.cursor.set()
            onDragChanged?(.zero)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOriginScreen else { return }
            edge.cursor.set()
            let now = NSEvent.mouseLocation
            // Screen coordinates grow upward, while popup height grows downward.
            onDragChanged?(CGSize(width: now.x - origin.x, height: origin.y - now.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard dragOriginScreen != nil else { return }
            dragOriginScreen = nil
            onDragEnded?()
            onHover?(bounds.contains(convert(event.locationInWindow, from: nil)))
            window?.invalidateCursorRects(for: self)
        }
    }
}
