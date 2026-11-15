import XCTest
@testable import StarPortReceiver

final class StarPortViewportTests: XCTestCase {
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
