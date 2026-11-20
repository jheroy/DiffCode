import AppKit
import SwiftUI
import XCTest
@testable import DifKit

@MainActor
final class TitlebarClickGuardTests: XCTestCase {
    private struct HeaderFixture: View {
        let onPrimaryClick: () -> Void
        let disableAfterFirstClick: Bool
        @State private var primaryDisabled = false

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    HStack(spacing: 8) {
                        IconButton(symbol: "arrow.down", help: "Next") {
                            onPrimaryClick()
                            if disableAfterFirstClick { primaryDisabled = true }
                        }
                        .disabled(primaryDisabled)

                        IconButton(symbol: "person.text.rectangle", help: "Annotate") {}
                            .disabled(true)
                    }
                    .frame(maxHeight: .infinity)
                    .titlebarClickGuard(horizontalOutset: 4)
                }
                .padding(.trailing, 10)
                .frame(height: 38)
                .background(WindowDragArea())
                Spacer()
            }
            .padding(IslandStyle.outerPadding)
            .ignoresSafeArea()
        }
    }

    private func makeWindow<V: View>(rootView: V) -> TitlebarWindow {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let window = TitlebarWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 600, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "test-main")
        window.toolbarStyle = .unifiedCompact

        let host = NSHostingView(rootView: rootView)
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    private func sendClick(
        in window: NSWindow,
        at point: NSPoint,
        clickCount: Int,
        eventNumber: inout Int,
        timestamp: TimeInterval
    ) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: 1
        )!
        eventNumber += 1
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: timestamp + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: 0
        )!
        eventNumber += 1
        window.sendEvent(down)
        window.sendEvent(up)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    func testGuardedToolbarButtonsAndGapsBlockTitlebarActionsWhileBlankAreaRemainsDraggable() {
        var clicks = 0
        let window = makeWindow(rootView: HeaderFixture(onPrimaryClick: { clicks += 1 }, disableAfterFirstClick: false))
        defer { window.close() }

        let initialFrame = window.frame
        // Right edge of header content = 600 - 7 (outerPadding) - 10 (trailing) = 583
        // Disabled button: x=[557, 583] (center 570); 8pt gap: x=[549, 557] (center 553);
        // Enabled button: x=[523, 549] (center 536). Header y=[355, 393] (center 374).
        let enabledButton = NSPoint(x: 536, y: 374)
        let gapBetweenButtons = NSPoint(x: 553, y: 374)
        let disabledButton = NSPoint(x: 570, y: 374)
        let topBandAboveButton = NSPoint(x: 536, y: 390)
        let bottomBandBelowButton = NSPoint(x: 536, y: 357)
        let outsetLeftOfGroup = NSPoint(x: 520, y: 374)
        let blankHeaderSpacer = NSPoint(x: 200, y: 374)

        XCTAssertTrue(window.isPointInInteractionGuard(enabledButton))
        XCTAssertTrue(window.isPointInInteractionGuard(gapBetweenButtons))
        XCTAssertTrue(window.isPointInInteractionGuard(disabledButton))
        XCTAssertTrue(window.isPointInInteractionGuard(topBandAboveButton))
        XCTAssertTrue(window.isPointInInteractionGuard(bottomBandBelowButton))
        XCTAssertTrue(window.isPointInInteractionGuard(outsetLeftOfGroup))
        XCTAssertFalse(window.isPointInInteractionGuard(blankHeaderSpacer))
        XCTAssertFalse(window.shouldBlockTitlebarAction(at: blankHeaderSpacer, clickCount: 1))
        XCTAssertFalse(window.shouldBlockTitlebarAction(at: blankHeaderSpacer, clickCount: 2))

        // Rapid 3-click on enabled button: all 3 actions fire, frame never zooms.
        var eventNo = 1
        let t0 = ProcessInfo.processInfo.systemUptime
        for click in 1...3 {
            sendClick(in: window, at: enabledButton, clickCount: click, eventNumber: &eventNo, timestamp: t0 + Double(click - 1) * 0.04)
        }
        XCTAssertEqual(clicks, 3)
        XCTAssertEqual(window.frame, initialFrame)

        // Click 1 in guard followed by click 2 drifting into blank spacer still blocks titlebar action.
        XCTAssertTrue(window.shouldBlockTitlebarAction(at: blankHeaderSpacer, clickCount: 2))

        // Double-click on gap, disabled button, and top band never zooms.
        for (idx, pt) in [gapBetweenButtons, disabledButton, topBandAboveButton].enumerated() {
            let base = t0 + Double(idx + 1) * 0.5
            sendClick(in: window, at: pt, clickCount: 1, eventNumber: &eventNo, timestamp: base)
            sendClick(in: window, at: pt, clickCount: 2, eventNumber: &eventNo, timestamp: base + 0.04)
        }
        XCTAssertEqual(window.frame, initialFrame)

        // A fresh clickCount == 1 in blank header resets the guard sequence so blank double-click works.
        sendClick(in: window, at: blankHeaderSpacer, clickCount: 1, eventNumber: &eventNo, timestamp: t0 + 3.0)
        XCTAssertFalse(window.shouldBlockTitlebarAction(at: blankHeaderSpacer, clickCount: 2))

        // Frame gesture recognizers are always re-enabled after guarded dispatch.
        if let frameView = window.contentView?.superview {
            XCTAssertTrue(frameView.gestureRecognizers.allSatisfy(\.isEnabled))
        }
    }

    func testButtonBecomingDisabledAfterFirstClickDoesNotTriggerTitlebarZoom() {
        var clicks = 0
        let window = makeWindow(rootView: HeaderFixture(onPrimaryClick: { clicks += 1 }, disableAfterFirstClick: true))
        defer { window.close() }

        let initialFrame = window.frame
        let buttonPoint = NSPoint(x: 536, y: 374)
        var eventNo = 1
        let t0 = ProcessInfo.processInfo.systemUptime

        sendClick(in: window, at: buttonPoint, clickCount: 1, eventNumber: &eventNo, timestamp: t0)
        sendClick(in: window, at: buttonPoint, clickCount: 2, eventNumber: &eventNo, timestamp: t0 + 0.04)

        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(window.frame, initialFrame)
    }

    func testGuardUnregistersWhenRemovedFromWindow() {
        let window = TitlebarWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let guardView = TitlebarClickGuard.GuardView(frame: NSRect(x: 100, y: 200, width: 80, height: 36))
        window.contentView?.addSubview(guardView)
        XCTAssertTrue(window.isPointInInteractionGuard(NSPoint(x: 140, y: 218)))
        XCTAssertFalse(window.isPointInInteractionGuard(NSPoint(x: 20, y: 218)))

        guardView.removeFromSuperview()
        XCTAssertFalse(window.isPointInInteractionGuard(NSPoint(x: 140, y: 218)))
    }
}
