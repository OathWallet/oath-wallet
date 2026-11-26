import XCTest

/// Run only on a disposable simulator with simulated Face ID enrolled. The
/// host supplies a simulated match or rejection at the corresponding marker.
final class OathWalletUnlockUITests: XCTestCase {
    @MainActor func testAutomaticFaceIDUnlockReachesHomeAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en",
                               "-oath.walletTestScope", UUID().uuidString]
        let previousAppearance = XCUIDevice.shared.appearance
        defer { app.terminate(); XCUIDevice.shared.appearance = previousAppearance }
        XCUIDevice.shared.appearance = .light
        app.launch()
        let create = app.buttons["onboarding.createWallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        XCTAssertFalse(app.staticTexts["passcode.notice"].exists)
        XCTAssertFalse(app.buttons["passcode.startOver"].exists)
        enterPIN(app)
        let confirmation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
            object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 8), .completed)
        enterPIN(app)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if system.alerts.firstMatch.waitForExistence(timeout: 3) {
            for title in ["Allow", "OK"] where system.alerts.buttons[title].exists {
                system.alerts.buttons[title].tap()
                break
            }
        }
        print("OATH_FACE_ID_ENROLLMENT_READY")
        let color = app.buttons["walletCustomize.color.8B36C9"]
        XCTAssertTrue(color.waitForExistence(timeout: 40))
        color.tap()
        app.completeWalletCustomization(timeout: 40)
        let receive = app.buttons["home.receive"]
        let backupClose = app.buttons["home.backupOffer.close"]
        if backupClose.waitForExistence(timeout: 8) { backupClose.tap() }
        XCTAssertTrue(receive.waitForExistence(timeout: 40))
        XCTAssertFalse(app.alerts["Passcode set"].exists)
        app.terminate()
        print("OATH_FACE_ID_COLD_LAUNCH")
        app.launch()
        let coldPhrase = assertGreeting(in: app)
        print("OATH_FACE_ID_UNLOCK_READY")
        assertHittable(receive)
        print("OATH_FACE_ID_COLD_HOME")
        app.buttons["wallet.sidebar.open"].tap()
        let settings = app.buttons["wallet.sidebar.settings"]
        assertHittable(settings)
        settings.tap()
        let appearance = app.buttons["settings.appearance"]
        assertHittable(appearance)
        appearance.tap()
        let dark = app.buttons["settings.appearance.dark"]
        assertHittable(dark)
        dark.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: dark)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        assertHittable(appearance)
        app.buttons["options.close"].tap()
        assertHittable(receive)
        receive.tap()
        let close = app.buttons["receive.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        backgroundAndReturn(app)
        let warmPhrase = assertGreeting(in: app)
        XCTAssertNotEqual(coldPhrase, warmPhrase)
        XCTAssertFalse(close.exists && close.isHittable)
        print("OATH_FACE_ID_WARM_MATCH_READY")
        assertHittable(close)
        close.tap()
        XCTAssertTrue(receive.isHittable)

        backgroundAndReturn(app)
        XCTAssertNotEqual(warmPhrase, assertGreeting(in: app))
        print("OATH_FACE_ID_REJECTION_READY")
        // Some OS versions offer a retry after a nonmatch. Choose the
        // system's app-passcode fallback when that sheet is present.
        let retry = system.buttons["Try Face ID Again"].firstMatch
        if retry.waitForExistence(timeout: 5) {
            let fallback = system.buttons["Enter Passcode"].firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 3))
            fallback.tap()
        }
        let keypad = app.buttons["keypad.digit.0"]
        XCTAssertTrue(keypad.waitForExistence(timeout: 6))
        XCTAssertFalse(app.staticTexts["wallet.unlock.greeting"].exists)
        XCTAssertFalse(receive.exists && receive.isHittable)
        enterPIN(app)
        assertHittable(receive)
    }

    @MainActor private func assertHittable(_ element: XCUIElement,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 16), .completed, file: file, line: line)
    }

    @MainActor private func assertGreeting(in app: XCUIApplication) -> String {
        let greeting = app.staticTexts["wallet.unlock.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["wallet.unlock.title"].exists)
        XCTAssertFalse(app.buttons["keypad.digit.0"].exists)
        let home = app.buttons["home.receive"]
        XCTAssertFalse(home.exists && home.isHittable)
        return greeting.label
    }

    @MainActor private func backgroundAndReturn(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.state == .runningBackgroundSuspended)
        app.activate()
    }

    @MainActor private func enterPIN(_ app: XCUIApplication) {
        for digit in [2, 9, 4, 8, 1, 6] { app.buttons["keypad.digit.\(digit)"].tap() }
    }
}
