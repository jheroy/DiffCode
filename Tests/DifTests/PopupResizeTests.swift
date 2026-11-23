import XCTest
@testable import DifKit

final class PopupResizeTests: XCTestCase {
    private let windowSize = CGSize(width: 1440, height: 900)

    func testSpecsHaveExpectedDefaultsAndMinimums() {
        XCTAssertEqual(PopupSizeSpec.references.defaultSize, CGSize(width: 840, height: 540))
        XCTAssertEqual(PopupSizeSpec.references.minSize, CGSize(width: 560, height: 340))
        XCTAssertEqual(PopupSizeSpec.references.userDefaultsKey, "popupSize.references")

        XCTAssertEqual(PopupSizeSpec.findInPath.defaultSize, CGSize(width: 900, height: 640))
        XCTAssertEqual(PopupSizeSpec.findInPath.minSize, CGSize(width: 600, height: 380))
        XCTAssertEqual(PopupSizeSpec.findInPath.userDefaultsKey, "popupSize.findInPath")

        XCTAssertEqual(PopupSizeSpec.quickOpen.defaultSize, CGSize(width: 660, height: 460))
        XCTAssertEqual(PopupSizeSpec.quickOpen.minSize, CGSize(width: 480, height: 280))
        XCTAssertEqual(PopupSizeSpec.quickOpen.userDefaultsKey, "popupSize.quickOpen")

        XCTAssertEqual(PopupSizeSpec.selectionHistory.defaultSize, CGSize(width: 960, height: 640))
        XCTAssertEqual(PopupSizeSpec.selectionHistory.minSize, CGSize(width: 640, height: 400))
        XCTAssertEqual(PopupSizeSpec.selectionHistory.userDefaultsKey, "popupSize.selectionHistory")
    }

    func testBottomEdgeHeightDrag() {
        let spec = PopupSizeSpec.references
        let taller = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottom,
            translation: CGSize(width: 40, height: 120),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(taller, CGSize(width: 840, height: 660))

        let shorter = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottom,
            translation: CGSize(width: -30, height: -100),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(shorter, CGSize(width: 840, height: 440))
    }

    func testRightAndLeftEdgeSymmetricalWidthDragPreservesHorizontalCenter() {
        let spec = PopupSizeSpec.findInPath

        // Dragging right edge outward by +50 increases total width by 100.
        let widenedRight = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .right,
            translation: CGSize(width: 50, height: 20),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(widenedRight, CGSize(width: 1000, height: 640))

        let rightRect = PopupResizeGeometry.centeredRect(size: widenedRight, spec: spec, windowSize: windowSize)
        XCTAssertEqual(rightRect.midX, windowSize.width / 2, accuracy: 0.5)

        // Dragging left edge outward by -60 increases total width by 120.
        let widenedLeft = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .left,
            translation: CGSize(width: -60, height: -25),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(widenedLeft, CGSize(width: 1020, height: 640))

        let leftRect = PopupResizeGeometry.centeredRect(size: widenedLeft, spec: spec, windowSize: windowSize)
        XCTAssertEqual(leftRect.midX, windowSize.width / 2, accuracy: 0.5)

        // Dragging left edge inward by +40 shrinks total width by 80.
        let narrowedLeft = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .left,
            translation: CGSize(width: 40, height: 0),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(narrowedLeft, CGSize(width: 820, height: 640))
    }

    func testCornerDragsResizeWidthSymmetricallyAndHeightTogether() {
        let spec = PopupSizeSpec.quickOpen

        let bottomRight = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottomRight,
            translation: CGSize(width: 45, height: 80),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(bottomRight, CGSize(width: 750, height: 540))
        let brRect = PopupResizeGeometry.centeredRect(size: bottomRight, spec: spec, windowSize: windowSize)
        XCTAssertEqual(brRect.midX, windowSize.width / 2, accuracy: 0.5)

        let bottomLeft = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottomLeft,
            translation: CGSize(width: -35, height: 90),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(bottomLeft, CGSize(width: 730, height: 550))
        let blRect = PopupResizeGeometry.centeredRect(size: bottomLeft, spec: spec, windowSize: windowSize)
        XCTAssertEqual(blRect.midX, windowSize.width / 2, accuracy: 0.5)
    }

    func testMinAndMaxWindowClamping() {
        let spec = PopupSizeSpec.references

        // Below minimum clamps to minSize.
        let clampedMin = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottomRight,
            translation: CGSize(width: -500, height: -500),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(clampedMin, spec.minSize)

        // Above window bounds clamps to (window.width - 48, window.height - topPadding - 32).
        let clampedMax = PopupResizeGeometry.resized(
            from: spec.defaultSize,
            edge: .bottomRight,
            translation: CGSize(width: 1000, height: 1000),
            spec: spec,
            windowSize: windowSize
        )
        XCTAssertEqual(
            clampedMax,
            CGSize(width: windowSize.width - 48, height: windowSize.height - spec.topPadding - 32)
        )

        // Shrinking the window clamps a large saved size without crashing below minSize.
        let tinyWindow = CGSize(width: 500, height: 350)
        let clampedTiny = PopupResizeGeometry.clampedSize(spec.defaultSize, spec: spec, windowSize: tinyWindow)
        XCTAssertEqual(clampedTiny, spec.minSize)
    }

    func testUserDefaultsRoundTripAndReset() {
        let suiteName = "PopupResizeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for spec in [PopupSizeSpec.references, .findInPath, .quickOpen, .selectionHistory] {
            // Unset returns default size.
            XCTAssertEqual(PopupSizeStore.load(spec: spec, defaults: defaults), spec.defaultSize)

            // Save & load round-trip.
            let custom = CGSize(width: spec.defaultSize.width + 80, height: spec.defaultSize.height + 110)
            PopupSizeStore.save(custom, spec: spec, defaults: defaults)
            XCTAssertEqual(PopupSizeStore.load(spec: spec, defaults: defaults), custom)

            // Reset clears persistence and returns default size.
            let resetSize = PopupSizeStore.reset(spec: spec, defaults: defaults)
            XCTAssertEqual(resetSize, spec.defaultSize)
            XCTAssertEqual(PopupSizeStore.load(spec: spec, defaults: defaults), spec.defaultSize)
        }
    }

    func testSplitListHeightClampsRatioBounds() {
        let available: CGFloat = 400
        XCTAssertEqual(PopupResizeGeometry.splitListHeight(availableHeight: available, ratio: 0.45), 180)
        XCTAssertEqual(PopupResizeGeometry.splitListHeight(availableHeight: available, ratio: 0.1), 100)
        XCTAssertEqual(PopupResizeGeometry.splitListHeight(availableHeight: available, ratio: 0.95), 300)
    }
}
