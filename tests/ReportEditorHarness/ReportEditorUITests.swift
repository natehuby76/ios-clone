import XCTest

final class ReportEditorUITests: XCTestCase {
    func testDescriptionStaysAboveKeyboardAndKeyboardDismissPreservesDraft() {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Open report"].tap()
        let editor = app.descendants(matching: .any).matching(identifier: "report-description").firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        for _ in 0..<4 where !editor.isHittable { app.swipeUp() }
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText("Connection drops when I open Galaxy. It reconnects after a few seconds.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let editorFrame = editor.frame
        let keyboardFrame = app.keyboards.firstMatch.frame
        XCTAssertGreaterThanOrEqual(editorFrame.minY, 0)
        XCTAssertLessThanOrEqual(editorFrame.maxY, keyboardFrame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Report description above keyboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertFalse(app.buttons["Hide keyboard"].exists)
        let done = app.keyboards.buttons["Done"]
        XCTAssertTrue(done.isHittable)
        done.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)], timeout: 5), .completed)
        XCTAssertTrue((editor.value as? String ?? "").contains("Connection drops"))
        editor.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        editor.typeText(" Still testing.")
        XCTAssertTrue((editor.value as? String ?? "").contains("Still testing."))
    }
}
