import XCTest

extension XCUIApplication {
    /// Setup and Face ID now finish at the real shared customization page.
    /// Tests that need Home must explicitly apply its initial choices.
    @MainActor func completeWalletCustomization(timeout: TimeInterval = 20) {
        let identifiedApply = buttons["walletCustomize.apply"]
        // The English test fixture also supports the native toolbar's label
        // when iOS does not forward the wrapper accessibility identifier.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            identifiedApply.exists || self.navigationBars.buttons["Apply"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
        let apply = identifiedApply.exists ? identifiedApply : navigationBars.buttons["Apply"]
        XCTAssertTrue(textFields["walletCustomize.name"].exists)
        XCTAssertTrue(apply.isHittable)
        apply.tap()
    }
}
