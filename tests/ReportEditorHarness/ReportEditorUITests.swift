import XCTest

final class ReportEditorUITests: XCTestCase {
    func testDescriptionStaysAboveKeyboardAndKeyboardDismissPreservesDraft() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open report"].tap()
        let editor = app.textViews["report-description"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for _ in 0..<4 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("Connection drops when I open Galaxy.\nIt reconnects after a few seconds.")
        let visible = NSPredicate { _, _ in
            editor.frame.minY >= 0 && editor.frame.maxY <= app.keyboards.firstMatch.frame.minY
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: editor)], timeout: 5), .completed)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Report description above keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let done = app.buttons["Hide keyboard"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 5), .completed)
        XCTAssertTrue((editor.value as? String ?? "").contains("Connection drops"))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("\nStill testing.")
        XCTAssertTrue((editor.value as? String ?? "").contains("Still testing."))
    }
}
