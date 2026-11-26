import XCTest

@MainActor final class NavigationUITests: XCTestCase {
    func testSwitchWalletDiscardsReceiptsButSameWalletRetainsNavigation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        func openHistory(search: Bool) {
            let button = app.tabBars.buttons["History"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            if !button.isSelected { button.tap() }
            if search {
                let field = app.searchFields["Search transactions"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                field.tap()
                field.typeText("USDC")
            }
        }
        func assertLabel(_ identifier: String, _ label: String) {
            let element = app.staticTexts[identifier]
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
            XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
        }
        for search in [false, true] {
            openHistory(search: search)
            assertLabel("history.wallet", "Wallet 1 history")
            app.buttons["transaction.row"].tap()
            assertLabel("receipt", "Wallet 1 receipt")

            app.buttons["refresh.wallet"].tap()
            assertLabel("receipt", "Wallet 1 receipt")

            app.buttons["switch.wallet"].tap()
            assertLabel("history.wallet", "Wallet 2 history")
            openHistory(search: search)
            XCTAssertFalse(app.staticTexts["receipt"].exists, "A different wallet must start at its own History root")
            app.buttons["transaction.row"].tap()
            assertLabel("receipt", "Wallet 2 receipt")

            app.buttons["switch.wallet"].tap()
            openHistory(search: search)
            assertLabel("history.wallet", "Wallet 1 history")
            XCTAssertFalse(app.staticTexts["receipt"].exists, "Switching back must not resurrect either old receipt")
            if app.buttons["Cancel"].isHittable { app.buttons["Cancel"].tap() }
            app.tabBars.buttons["Wallet"].tap()
        }
    }
}
