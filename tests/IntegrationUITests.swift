import XCTest

final class IntegrationUITests: XCTestCase {
    func testActiveRoutePreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-route"]; app.launch()
        XCTAssertTrue(app.staticTexts["Turn right onto Bremner Boulevard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["expand-app-tabs"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Sample active route"; shot.lifetime = .keepAlways; add(shot)
    }
    func testGalaxyTogglesPreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-galaxy"]; app.launch()
        let toggles = app.webViews.buttons["Toggles"]
        XCTAssertTrue(toggles.waitForExistence(timeout: 20)); toggles.tap()
        XCTAssertTrue(app.buttons["expand-app-tabs"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Galaxy toggles offline"; shot.lifetime = .keepAlways; add(shot)
    }
    func testNavigationAndSharedSettings() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["main-tab-Navigation"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].waitForExistence(timeout: 10))
        XCTAssertTrue(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons["bluetooth-connection-status"])], timeout: 10) == .completed)
        Thread.sleep(forTimeInterval: 0.7) // Capture the settled compact header, not its transition.
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
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Navigation"].tap()
        XCTAssertTrue(app.buttons["bluetooth-connection-status"].exists)
        if app.buttons["expand-app-tabs"].isHittable { app.buttons["expand-app-tabs"].tap() }
        app.buttons["main-tab-Settings"].tap()
        XCTAssertTrue(app.staticTexts["Your comma"].exists)
        let settings = XCTAttachment(screenshot: app.screenshot()); settings.name = "Shared settings"; settings.lifetime = .keepAlways; add(settings)
    }
}
