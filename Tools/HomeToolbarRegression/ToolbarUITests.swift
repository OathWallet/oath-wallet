import XCTest

@MainActor final class ToolbarUITests: XCTestCase {
    func testMeasuredReplacementAndPrivacy() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let wallet = app.navigationBars.buttons["wallet.sidebar.open"]
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        func expect(_ value: String) {
            let predicate = NSPredicate(format: "value == %@", value)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: wallet)], timeout: 5), .completed)
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        expect("")
        capture("wallet-name")
        wallet.tap()
        XCTAssertEqual(app.staticTexts["probe.opens"].label, "Opened 1")
        app.buttons["Partial"].tap()
        expect("")
        app.buttons["Hidden"].tap()
        expect("$1,234.56")
        capture("balance")
        app.buttons["Deep"].tap()
        expect("$1,234.56")
        app.buttons["Privacy"].tap()
        expect("Balance hidden")
        capture("hidden-balance")
        app.buttons["Partial"].tap()
        expect("")
        app.buttons["Top"].tap()
        app.buttons["Rename"].tap()
        app.buttons["Theme"].tap()
        expect("")
        XCTAssertTrue(wallet.label.contains("A very long wallet name"))
        XCTAssertTrue(wallet.isHittable)
        XCTAssertTrue(app.navigationBars.buttons["home.history"].isHittable)
        capture("long-name-dark")
    }
}
