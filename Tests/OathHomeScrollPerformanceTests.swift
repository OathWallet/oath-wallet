#if DEBUG && targetEnvironment(simulator)
import XCTest

final class OathHomeScrollPerformanceTests: XCTestCase {
    @MainActor func testAccountLongPressPresentsSheetWithoutSelectingAccount() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-oath-home-scroll-fixture", "-oath-hd-account-fixture",
            "-oath.walletTestScope", UUID().uuidString, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["wallet.sidebar.open"].waitForExistence(timeout: 30))
        app.buttons["wallet.sidebar.open"].tap()
        for family in ["evm", "solana"] {
            let row = app.buttons["sidebar.account.\(family).0"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.press(forDuration: 0.7)
            XCTAssertTrue(app.navigationBars["Account details"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Derivation path"].exists)
            XCTAssertTrue(app.buttons["hdAccount.rename"].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "account-details-" + family; attachment.lifetime = .keepAlways; add(attachment)
            app.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.isHittable, "Long press must not also select the account and close the sidebar")
        }
    }

    @MainActor func testIdleScrolling() { measureHome(updating: false) }
    @MainActor func testUpdatingScrolling() { measureHome(updating: true) }

    /// The production gesture, refresh presentation, session coordinator and SQL
    /// observer run unchanged; only remote providers are replaced by local commits.
    @MainActor func testScrollingDuringPullRefresh() {
        let app = launch(updating: false)
        defer { app.terminate() }
        pullAndCheckBand(in: app)
        let status = app.staticTexts["fixture.refresh.state"]
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'running'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 5), .completed)
        swipe(app)
        let report = app.staticTexts["fixture.scroll.sample"]
        let sample = report.value as? String ?? ""
        print("HOME_PULL_REFRESH_SAMPLE elapsed_s gap_ms_per_s drag_updates coast_updates \(sample)")
        let fields = sample.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(fields.count, 4)
        XCTAssertGreaterThan(fields.count == 4 ? fields[2] + fields[3] : 0, 0,
                             "Balances must update during the post-release scroll")
        let homeChanges = Int(app.staticTexts["fixture.home.bodyChanges"].label) ?? -1
        print("HOME_PULL_REFRESH_ROOT_BODY_UPDATES \(homeChanges)")
        XCTAssertGreaterThanOrEqual(homeChanges, 0)
        XCTAssertLessThanOrEqual(homeChanges, 2, "Balance commits must not rebuild the Home navigation/sidebar/list root")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'completed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 20), .completed)
    }

    @MainActor func testPullFromEmptyHomeRevealsBandAndLoadsAssets() {
        let app = launch(updating: false, startsEmpty: true)
        defer { app.terminate() }
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Receive")).count, 1)
        let scanner = app.buttons["home.scanner"]
        let restingY = scanner.frame.midY
        let status = app.staticTexts["fixture.refresh.state"]
        XCTAssertEqual(status.label, "idle")
        pullAndCheckBand(in: app)
        XCTAssertTrue(app.buttons["home.token.bench-0"].waitForExistence(timeout: 8))
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(scanner.frame.midY - restingY) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 6), .completed)
        let complete = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'completed'"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [complete], timeout: 20), .completed)
    }

    @MainActor private func pullAndCheckBand(in app: XCUIApplication) {
        let scanner = app.buttons["home.scanner"]
        let restingY = scanner.frame.midY
        let chart = app.descendants(matching: .any)["home.balanceChart"].firstMatch
        XCTAssertTrue(chart.isHittable)
        let start = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 400, thenHoldForDuration: 0)
        assertBandSettles(above: scanner, from: restingY)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Home refresh band"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func assertBandSettles(above button: XCUIElement, from restingY: CGFloat) {
        let held = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(button.frame.midY - restingY - 92) <= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [held], timeout: 2.5), .completed, "The refresh band must settle above the toolbar")
    }

    @MainActor func testPullingInHistoryLeavesHomeRefreshIdle() {
        let app = launch(updating: false)
        defer { app.terminate() }
        let tabs = app.tabBars.firstMatch
        tabs.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars.buttons["history.filters"].waitForExistence(timeout: 5))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 400, thenHoldForDuration: 0)
        tabs.buttons["Wallet"].tap()
        let status = app.staticTexts["fixture.refresh.state"]
        XCTAssertEqual(status.label, "idle", "Pulling in History must leave the wallet refresh idle")
        let chart = app.descendants(matching: .any)["home.balanceChart"].firstMatch
        let right = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let left = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        right.press(forDuration: 0.05, thenDragTo: left, withVelocity: 180, thenHoldForDuration: 0.2)
        XCTAssertEqual(status.label, "idle", "Scrubbing the chart must leave the wallet refresh idle")
        pullAndCheckBand(in: app)
        XCTAssertEqual(status.label, "running")
    }

    @MainActor private func launch(updating: Bool, verifyRows: Bool = false, startsEmpty: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-oath-home-scroll-fixture", "-oath.walletTestScope", UUID().uuidString,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if updating { app.launchArguments.append("-oath-scroll-updating") }
        if verifyRows { app.launchArguments.append("-oath-scroll-verify") }
        if startsEmpty { app.launchArguments.append("-oath-empty-home-fixture") }
        app.launch()
        let initialContent = startsEmpty
            ? app.descendants(matching: .any)["home.empty.assets"].firstMatch
            : app.buttons["home.token.bench-0"]
        XCTAssertTrue(initialContent.waitForExistence(timeout: 30))
        return app
    }

    @MainActor private func swipe(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.81))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.27))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 850, thenHoldForDuration: 0)
    }

    @MainActor func testVisibleUpdatesAndSidebarRestore() {
        let app = launch(updating: true, verifyRows: true)
        defer { app.terminate() }
        swipe(app)
        let report = app.staticTexts["fixture.scroll.sample"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "[0-9.]+ [0-9.]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+"), object: report)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 7), .completed)
        let sample = report.value as? String ?? ""
        let fields = sample.split(separator: " ").compactMap { Double($0) }
        XCTAssertEqual(fields.count, 6)
        XCTAssertTrue(fields.dropFirst(2).allSatisfy { $0 > 0 }, "Expected total and visible row updates in both gesture phases: \(sample)")
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.token.bench-'"))
        let anchor = rows.allElementsBoundByIndex.first {
            $0.frame.midY > app.frame.height * 0.35 && $0.frame.midY < app.frame.height * 0.75 && $0.isHittable
        }
        guard let anchor else { return XCTFail("No visible middle asset after scrolling") }
        let id = anchor.identifier, y = anchor.frame.midY
        let row = app.buttons[id]
        let changing = rows.allElementsBoundByIndex.first {
            Int($0.identifier.components(separatedBy: "-").last ?? "").map { $0.isMultiple(of: 4) } == true && $0.isHittable
        }
        guard let changing else { return XCTFail("No visible updating asset") }
        let before = changing.label
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: changing)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertEqual(row.frame.midY, y, accuracy: 1)
        app.buttons["wallet.sidebar.open"].tap()
        let wallet = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'wallet.balance.'")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        let oldAmount = wallet.value as? String ?? ""
        XCTAssertFalse(oldAmount.isEmpty)
        let newAmount = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", oldAmount), object: wallet)
        XCTAssertEqual(XCTWaiter.wait(for: [newAmount], timeout: 5), .completed)
        let close = app.buttons["sidebar.dismiss"]
        XCTAssertTrue(close.isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.5)).tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.frame.midY, y, accuracy: 1)
    }

    @MainActor private func measureHome(updating: Bool) {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        options.invocationOptions = [.manuallyStart, .manuallyStop]
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            let app = launch(updating: updating)
            startMeasuring()
            swipe(app)
            stopMeasuring()
            let report = app.staticTexts["fixture.scroll.sample"]
            if (report.value as? String ?? "").isEmpty {
                let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value MATCHES %@", "[0-9.]+ [0-9.]+ [0-9]+ [0-9]+"), object: report)
                XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 7), .completed)
            }
            let sample = report.value as? String ?? ""
            let fields = sample.split(separator: " ").compactMap { Double($0) }
            XCTAssertEqual(fields.count, 4, "Expected a complete drag/deceleration interval")
            if fields.count == 4 {
                XCTAssertGreaterThan(fields[0], 0)
            }
            print("HOME_SCROLL_SAMPLE updating=\(updating) elapsed_s gap_ms_per_s drag_updates coast_updates \(sample)")
            app.terminate()
        }
    }
}
#endif
