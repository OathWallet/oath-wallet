import XCTest

final class WalletBandUITests: XCTestCase {
    @MainActor func testPullMovesToolbarAndRowsTogetherWithFixedBottomControls() {
        for pale in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = pale ? ["--pale"] : []
            app.launch()
            let history = app.buttons["history"], receive = app.buttons["receive"]
            let address = app.staticTexts["address"], work = app.staticTexts["work"]
            XCTAssertTrue(receive.waitForExistence(timeout: 5))
            let navY = history.frame.midY, rowY = receive.frame.midY
            let addressY = address.frame.midY, tabY = app.tabBars.firstMatch.frame.midY
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.33))
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: 38)),
                         withVelocity: .fast, thenHoldForDuration: 0.1)
            XCTAssertEqual(work.label, "Requests 0 · Completed 0")
            origin.press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: 277)),
                         withVelocity: .fast, thenHoldForDuration: 0.12)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = pale ? "Dark-pale-wallet" : "Light-blue-wallet"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertEqual(work.label, "Requests 1 · Completed 0")
            let heldTravel: CGFloat = 92
            XCTAssertEqual(history.frame.midY - navY, heldTravel, accuracy: 2)
            XCTAssertEqual(receive.frame.midY - rowY, heldTravel, accuracy: 2)
            XCTAssertEqual(address.frame.midY, addressY, accuracy: 2)
            XCTAssertEqual(app.tabBars.firstMatch.frame.midY, tabY, accuracy: 2)
            let zero = app.coordinate(withNormalizedOffset: .zero)
            zero.withOffset(CGVector(dx: receive.frame.midX, dy: rowY + heldTravel)).tap()
            zero.withOffset(CGVector(dx: history.frame.midX, dy: navY + heldTravel)).tap()
            XCTAssertEqual(receive.label, "Receive 1")
            XCTAssertEqual(history.label, "History 1")
            let returned = NSPredicate { _, _ in abs(history.frame.midY - navY) < 2 }
            expectation(for: returned, evaluatedWith: history)
            waitForExpectations(timeout: 5)
            XCTAssertEqual(receive.frame.midY, rowY, accuracy: 2)
            XCTAssertEqual(work.label, "Requests 1 · Completed 0")
            expectation(for: NSPredicate(format: "label == %@", "Requests 1 · Completed 1"), evaluatedWith: work)
            waitForExpectations(timeout: 5)
            app.terminate()
        }
    }
}
