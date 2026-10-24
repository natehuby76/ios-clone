import XCTest

final class IntegrationUITests: XCTestCase {
    func testConnectionOrderSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "NO", "-galaxy.app.navigationAlpha", "NO", "-galaxy.connection.mode", "automatic"]
        app.launch()
        XCTAssertTrue(app.buttons["Set order"].waitForExistence(timeout: 15))
        app.buttons["Set order"].tap()
        XCTAssertTrue(app.navigationBars["Connection order"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tunnel"].exists)
        app.buttons["Reset order"].tap()
        let drag = app.buttons["Reorder Tunnel"]
        XCTAssertTrue(drag.exists)
        drag.press(forDuration: 0.7, thenDragTo: app.buttons["Reorder Local Wi-Fi"])
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Tunnel → Local Wi-Fi → Bluetooth"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Tunnel → Local Wi-Fi → Bluetooth"].waitForExistence(timeout: 10))
        app.buttons["Set order"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Connection priority"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Reset order"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["Local Wi-Fi → Tunnel → Bluetooth"].exists)
    }
    func testDiagnosticsExport() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "YES", "-galaxy.app.navigationAlpha", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["Developer options"].waitForExistence(timeout: 10))
        app.buttons["Developer options"].tap()
        app.buttons["Dev / Logs"].tap()
        let save = app.buttons["save-diagnostics-txt"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Save diagnostics text file"; shot.lifetime = .keepAlways; add(shot)
    }
    func testActiveRoutePreview() {
        let app = XCUIApplication(); app.launchArguments = ["--preview-route"]; app.launch()
        XCTAssertTrue(app.staticTexts["Turn right onto Bremner Boulevard"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["expand-app-tabs"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Sample active route"; shot.lifetime = .keepAlways; add(shot)
    }
    func testRegularModeAndAlphaOptIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "NO", "-galaxy.app.navigationAlpha", "NO"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your comma"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["main-tab-Navigation"].exists)
        XCTAssertFalse(app.switches["navigation-alpha-toggle"].exists)
        let regular = XCTAttachment(screenshot: app.screenshot()); regular.name = "Regular StarPilot BT"; regular.lifetime = .keepAlways; add(regular)
        let developer = app.switches["developer-mode-toggle"]
        if !developer.isHittable { app.swipeUp() }
        developer.tap()
        let alpha = app.switches["navigation-alpha-toggle"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5))
        if !alpha.isHittable { app.swipeUp() }
        alpha.tap()
        XCTAssertTrue(app.buttons["expand-app-tabs"].waitForExistence(timeout: 5))
        alpha.tap()
        XCTAssertFalse(app.buttons["expand-app-tabs"].exists)
        developer.tap()
        XCTAssertFalse(app.switches["navigation-alpha-toggle"].exists)
    }
    func testNavigationAndSharedSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["-galaxy.app.developerMode", "YES", "-galaxy.app.navigationAlpha", "YES"]
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
