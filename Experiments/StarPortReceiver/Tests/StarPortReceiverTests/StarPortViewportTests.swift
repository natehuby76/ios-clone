import XCTest
@testable import StarPortReceiver

final class StarPortViewportTests: XCTestCase {
    func testMissingSystemInsetsReserveConfirmedLeftDockOnly() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let visible = StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [bounds, bounds], fallbackLeftInset: 60)
        XCTAssertEqual(visible, CGRect(x: 60, y: 0, width: 402, height: 277))
        XCTAssertGreaterThan(visible.minX, 49) // Measured dock in the build142 photo.
        XCTAssertEqual(visible.maxX, bounds.maxX) // Menu may overlay; no right gutter.
    }

    func testReportedDockInsetsTakePriorityOverFallback() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let reported = CGRect(x: 49, y: 0, width: 413, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [reported], fallbackLeftInset: 60), reported)
        let rightDock = CGRect(x: 0, y: 0, width: 413, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [rightDock], fallbackLeftInset: 60), rightDock)
    }

    func testFallbackKeepsPositiveViewportOnSmallScreens() {
        let bounds = CGRect(x: 20, y: 30, width: 100, height: 80)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [], fallbackLeftInset: 60), CGRect(x: 45, y: 30, width: 75, height: 80))
    }

    func testLeftFallbackPreservesReportedVerticalInsets() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let belowToolbar = CGRect(x: 0, y: 20, width: 462, height: 257)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [belowToolbar], fallbackLeftInset: 60), CGRect(x: 60, y: 20, width: 402, height: 257))
    }

    func testCarPlayContentReservesDockWithoutShrinkingToButtonColumn() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let dockExcluded = CGRect(x: 49, y: 0, width: 413, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [bounds, dockExcluded]), dockExcluded)
        // Root-view insets can arrive after the window's insets. Both orders
        // must produce the same large content viewport, rather than a sliver.
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [dockExcluded, bounds]), dockExcluded)
    }

    func testRightDockAndToolbarInsetsFollowContentCoordinates() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [
            CGRect(x: 0, y: 0, width: 413, height: 277),
            CGRect(x: 0, y: 40, width: 462, height: 237)
        ]), CGRect(x: 0, y: 40, width: 413, height: 237))
    }

    func testUnlaidOutOrOutsideGuidesDoNotErasePicture() {
        let bounds = CGRect(x: 20, y: 30, width: 462, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [
            .zero, .null, .infinite, CGRect(x: 1000, y: 1000, width: 100, height: 100)
        ]), bounds)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: .zero, contentSafeAreas: []), .zero)
    }
}
