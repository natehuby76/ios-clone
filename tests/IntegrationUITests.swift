import XCTest

final class IntegrationUITests: XCTestCase {
    func testNavigationAndSharedSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["main-tab-Navigation"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Integrated navigation"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Navigation options"].tap()
        app.buttons["Reset navigation"].tap()
        XCTAssertTrue(app.staticTexts["Phone navigation cleared. Comma is not verified; its route was left unchanged."].waitForExistence(timeout: 5))
        app.buttons["Navigation options"].tap()
        app.buttons["Copy diagnostic report"].tap()
        XCTAssertTrue(app.staticTexts["Diagnostic report copied."].waitForExistence(timeout: 5))
        app.buttons["bluetooth-connection-status"].tap()
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Share phone location"].exists)
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].exists)
        app.buttons["main-tab-Settings"].tap()
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Shared settings"; settings.lifetime = .keepAlways; add(settings)
    }
}
