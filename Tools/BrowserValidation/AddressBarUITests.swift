import XCTest

@MainActor final class AddressBarUITests: XCTestCase {
    func testInlineAddressStaysAboveKeyboardAndNewTabFocusesSameField() {
        let app = XCUIApplication()
        app.launch()
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertTrue(field.isHittable)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 2,
            "The address must remain above the keyboard, not behind it.")
        field.typeText("javascript:alert(1)")
        app.keyboards.buttons["Go"].tap()
        XCTAssertTrue(app.staticTexts["fixture.issue"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.exists, "Invalid input remains editable.")
        XCTAssertEqual(field.value as? String, "javascript:alert(1)")
        app.buttons["browser.address.clear"].tap()
        field.typeText("example.com")
        app.keyboards.buttons["Go"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertFalse(app.navigationBars["Website address"].exists)
        app.buttons["browser.tabs"].tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForExistence(timeout: 5))
        app.buttons["fixture.newTab"].tap()
        XCTAssertTrue(app.navigationBars["Tabs"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertLessThanOrEqual(field.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
        field.typeText("second.example")
        XCTAssertEqual(field.value as? String, "second.example")
    }
}
