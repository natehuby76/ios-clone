import XCTest
@testable import StarPortReceiver

final class StarPortViewportTests: XCTestCase {
    func testMissingSystemInsetsReserveBothPossibleDockEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let visible = StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [bounds, bounds], fallbackSideInset: 60)
        XCTAssertEqual(visible, CGRect(x: 60, y: 0, width: 342, height: 277))
        XCTAssertGreaterThan(visible.minX, 49) // Measured dock in the build142 photo.
        XCTAssertLessThan(visible.maxX, bounds.maxX - 49)
    }

    func testReportedDockInsetsTakePriorityOverFallback() {
        let bounds = CGRect(x: 0, y: 0, width: 462, height: 277)
        let reported = CGRect(x: 49, y: 0, width: 413, height: 277)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [reported], fallbackSideInset: 60), reported)
    }

    func testFallbackKeepsPositiveViewportOnSmallScreens() {
        let bounds = CGRect(x: 20, y: 30, width: 100, height: 80)
        XCTAssertEqual(StarPortVideoViewport.visibleRect(bounds: bounds, contentSafeAreas: [], fallbackSideInset: 60), CGRect(x: 45, y: 30, width: 50, height: 80))
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
