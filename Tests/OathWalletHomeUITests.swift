import XCTest
import UIKit
import Vision

/// Uses a fresh Keychain namespace and public test phrases on one disposable
/// simulator. Never reveals or screenshots a randomly generated recovery phrase.
final class OathWalletHomeUITests: XCTestCase {
    @MainActor private func submitBrowserAddress(_ input: String, in app: XCUIApplication) {
        let embedded = app.descendants(matching: .any).matching(identifier: "browser.address").firstMatch
        let field = embedded.exists && embedded.isHittable ? embedded : app.toolbars.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap()
        field.typeText(input)
        app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Go", "Search", "go", "search"])).firstMatch.tap()
    }

    @MainActor private func launchHomeTabs(browserEnabled: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-oath-home-scroll-fixture", "-oath-sidebar-wallets", "-oath.walletTestScope",
                               UUID().uuidString, "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en"]
        if browserEnabled { app.launchArguments.append("-oath-test-browser") }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Wallet"].waitForExistence(timeout: 35))
        return app
    }

    @MainActor private func launchBrowserFixture() -> XCUIApplication {
        let app = launchHomeTabs(browserEnabled: true)
        app.tabBars.buttons["Browser"].tap()
        XCTAssertTrue(app.buttons["browser.favorite.add"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor func testHistoryReplacesBrowserInWalletNavigation() {
        continueAfterFailure = false
        let app = launchHomeTabs()
        defer { app.terminate() }
        let tabs = app.tabBars.buttons
        let wallet = tabs["Wallet"], history = tabs["History"], search = tabs["Search"]
        XCTAssertEqual(tabs.allElementsBoundByIndex.map(\.label), ["Wallet", "History", "Search"])
        XCTAssertFalse(app.navigationBars.buttons["home.history"].exists)

        history.tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["history.filters"].isHittable)
        XCTAssertTrue(wallet.isHittable)
        XCTAssertTrue(history.isSelected)
        let transactions = app.searchFields["Search transactions"]
        transactions.tap()
        transactions.typeText("test transfer")
        XCTAssertEqual(transactions.value as? String, "test transfer")
        XCTAssertFalse(app.buttons["search.chain.filter"].isHittable)
        closeSearch(in: app)
        search.tap()
        XCTAssertTrue(app.searchFields["search.asset.field"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["search.chain.filter"].isHittable)
        app.buttons["search.asset.close"].tap()
        XCTAssertTrue(wallet.isSelected)

        app.buttons["wallet.sidebar.open"].tap()
        app.buttons["wallet.sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.currency"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.language"].exists)
        XCTAssertFalse(app.buttons["settings.browser"].exists)
    }

    @MainActor func testBrowserStartFavoritesAndTabNavigation() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let add = app.buttons["browser.favorite.add"]
        let tabs = app.buttons["browser.tabs"]
        let wallet = app.tabBars.buttons["Wallet"]
        let addressField = app.descendants(matching: .any).matching(identifier: "browser.address").firstMatch
        let tabCards = app.buttons.matching(identifier: "browser.tab.close")
        XCTAssertTrue(wallet.isHittable)
        XCTAssertTrue(app.tabBars.buttons["Browser"].isSelected)
        XCTAssertTrue(app.tabBars.buttons["Search"].isHittable)
        XCTAssertFalse(app.navigationBars.buttons["browser.start.close"].exists)
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        XCTAssertTrue(addressField.isHittable)
        XCTAssertTrue(tabs.isHittable)
        XCTAssertGreaterThanOrEqual(tabs.frame.minX - addressField.frame.maxX, 4)
        XCTAssertGreaterThanOrEqual(tabs.frame.width, 44)
        XCTAssertLessThanOrEqual(addressField.frame.maxY, wallet.frame.minY)
        XCTAssertLessThanOrEqual(tabs.frame.maxY, wallet.frame.minY)
        XCTAssertLessThan(wallet.frame.minY - tabs.frame.maxY, 44)
        XCTAssertEqual(addressField.frame.midY, tabs.frame.midY, accuracy: 8)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.buttons["browser.start.connections"].exists)
        addressField.tap()
        let cancelAddress = app.buttons["browser.address.cancel"]
        XCTAssertTrue(cancelAddress.waitForExistence(timeout: 5))
        cancelAddress.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        tabs.tap()
        XCTAssertTrue(app.staticTexts["No open tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(wallet.isHittable)
        app.buttons["browser.tabs.done"].tap()
        add.tap()
        let address = app.textFields["browser.favorite.address"]
        address.tap()
        address.typeText("example.org")
        let name = app.textFields["browser.favorite.name"]
        name.tap()
        name.typeText("Example")
        app.buttons["browser.favorite.save"].tap()
        let favorite = app.buttons["browser.favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertEqual(favorite.label, "Example")
        XCTAssertFalse(app.webViews.firstMatch.exists)
        favorite.tap()
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        XCTAssertFalse(wallet.isHittable)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        wallet.tap()
        XCTAssertFalse(tabs.isHittable)
        app.tabBars.buttons["Browser"].tap()
        XCTAssertTrue(favorite.waitForExistence(timeout: 5))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        submitBrowserAddress("example.org", in: app)
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        tabs.tap()
        XCTAssertTrue(tabCards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(tabCards.count, 1)
        app.buttons["browser.tabs.done"].tap()
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["browser.tabs.new"].waitForExistence(timeout: 5))
        app.buttons["browser.tabs.exit"].tap()
        app.buttons["browser.start.library"].tap()
        let bookmark = app.buttons["browser.library.bookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        bookmark.swipeLeft()
        app.buttons["Delete"].tap()
        app.buttons["browser.library.close"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(favorite.exists)
    }

    @MainActor func testBrowserStartUsesSelectedSearchEngineAndKeepsOpenTabs() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let browser = app.tabBars.buttons["Browser"]
        let tabs = app.buttons["browser.tabs"], newTab = app.buttons["browser.tabs.new"]
        submitBrowserAddress("example.org", in: app)
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        app.tabBars.buttons["Wallet"].tap()
        app.navigationBars.buttons["wallet.sidebar.open"].tap()
        app.buttons["wallet.sidebar.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        app.buttons["settings.browser"].tap()
        XCTAssertTrue(app.buttons["settings.searchEngine"].waitForExistence(timeout: 5))
        app.buttons["settings.searchEngine"].tap()
        XCTAssertTrue(app.buttons["settings.searchEngine.duckDuckGo"].isSelected)
        let brave = app.buttons["settings.searchEngine.brave"]
        brave.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: brave)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["options.close"].tap()
        browser.tap()
        XCTAssertTrue(app.buttons["browser.favorite.add"].waitForExistence(timeout: 5))
        tabs.tap()
        newTab.tap()
        XCTAssertFalse(app.webViews.firstMatch.exists)
        submitBrowserAddress("native browser test", in: app)
        XCTAssertTrue(app.navigationBars["search.brave.com"].waitForExistence(timeout: 8))
        let field = app.toolbars.searchFields.firstMatch
        field.tap()
        let typedURL = URLComponents(string: field.value as? String ?? "")
        XCTAssertEqual(typedURL?.host, "search.brave.com")
        XCTAssertEqual(typedURL?.queryItems?.first(where: { $0.name == "q" })?.value, "native browser test")
        app.terminate()
        app.launch()
        XCTAssertTrue(browser.waitForExistence(timeout: 35))
        browser.tap()
        XCTAssertTrue(app.buttons["browser.favorite.add"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        tabs.tap()
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "browser.tab.close").count, 2)
    }

    @MainActor func testBrowserRecentSitesCanBeHiddenAndRemoved() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let add = app.buttons["browser.favorite.add"]
        add.tap()
        let address = app.textFields["browser.favorite.address"]
        address.tap()
        address.typeText("example.org")
        app.buttons["browser.favorite.save"].tap()
        let favorite = app.buttons["browser.favorite"]
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Example Domain"), object: favorite)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 25), .completed)
        favorite.tap()
        XCTAssertTrue(app.webViews.links.firstMatch.waitForExistence(timeout: 20))
        app.navigationBars.buttons["BackButton"].tap()

        let recent = app.buttons["browser.recent"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertEqual(recent.label, "Example Domain")
        func toggleRecents() {
            app.tabBars.buttons["Wallet"].tap()
            app.navigationBars.buttons["wallet.sidebar.open"].tap()
            app.buttons["wallet.sidebar.settings"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            app.buttons["settings.browser"].tap()
            let toggle = app.switches["settings.browser.showRecentSites"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            toggle.tap()
            app.navigationBars.buttons.firstMatch.tap()
            app.buttons["options.close"].tap()
            app.tabBars.buttons["Browser"].tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
        }
        toggleRecents()
        XCTAssertFalse(recent.exists)
        app.terminate()
        app.launch()
        let browser = app.tabBars.buttons["Browser"]
        XCTAssertTrue(browser.waitForExistence(timeout: 35))
        browser.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(recent.exists)
        toggleRecents()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.press(forDuration: 0.8)
        app.buttons["Remove from Recents"].tap()
        XCTAssertFalse(recent.exists)
        XCTAssertTrue(favorite.exists)
    }

    @MainActor func testBrowserPrivateStartAndLibraryAcrossEntries() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let browser = app.tabBars.buttons["Browser"]
        let tabs = app.buttons["browser.tabs"], newTab = app.buttons["browser.tabs.new"]
        let add = app.buttons["browser.favorite.add"]
        let privateGroup = app.segmentedControls.buttons["Private"]
        tabs.tap()
        privateGroup.tap()
        newTab.tap()
        XCTAssertFalse(add.exists)
        XCTAssertFalse(app.buttons["browser.start.library"].exists)
        submitBrowserAddress("example.org", in: app)
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        app.tabBars.buttons["Wallet"].tap()
        browser.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 8))
        XCTAssertFalse(add.exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
        tabs.tap()
        XCTAssertTrue(privateGroup.isSelected)
        XCTAssertEqual(app.buttons.matching(identifier: "browser.tab.close").count, 1)
        app.terminate()
        app.launch()
        XCTAssertTrue(browser.waitForExistence(timeout: 35))
        browser.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        tabs.tap()
        privateGroup.tap()
        XCTAssertTrue(app.staticTexts["No open tabs"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["0 Tabs"].tap()
        app.buttons["browser.tabs.done"].tap()
        app.buttons["browser.start.library"].tap()
        XCTAssertTrue(app.buttons["browser.library.tabs"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(browser.waitForExistence(timeout: 35))
        browser.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["browser.library.tabs"].exists)
    }

    @MainActor func testBrowserReturnsToTheSelectedPreviewWhenSwitchingTabs() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let browser = app.tabBars.buttons["Browser"]
        submitBrowserAddress("example.com", in: app)

        let tabs = app.buttons["browser.tabs"]
        let newTab = app.buttons["browser.tabs.new"]
        let previews = app.buttons.matching(identifier: "browser.tab.preview")
        let first = previews.matching(NSPredicate(format: "value == %@", "example.com")).firstMatch
        let second = previews.matching(NSPredicate(format: "value == %@", "duckduckgo.com")).firstMatch
        XCTAssertTrue(app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 15))
        tabs.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(first.isSelected)
        newTab.tap()
        submitBrowserAddress("duckduckgo.com", in: app)
        XCTAssertTrue(app.navigationBars["duckduckgo.com"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 15))
        tabs.tap()
        XCTAssertTrue(second.waitForExistence(timeout: 8))
        XCTAssertTrue(second.isSelected)
        XCTAssertLessThan(first.frame.midX, second.frame.midX)
        first.tap()
        XCTAssertTrue(app.navigationBars["example.com"].waitForExistence(timeout: 8))
        tabs.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 8))
        XCTAssertTrue(first.isSelected)
        second.tap()
        XCTAssertTrue(app.navigationBars["duckduckgo.com"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        app.buttons["browser.tabs.exit"].tap()
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(browser.waitForExistence(timeout: 8))
        XCTAssertTrue(browser.isHittable)
    }

    @MainActor func testBrowserOwnsTheBottomToolbarAndRestoresTabsOnBack() {
        continueAfterFailure = false
        let app = launchBrowserFixture()
        defer { app.terminate() }
        let browserTab = app.tabBars.buttons["Browser"]
        submitBrowserAddress("example.com/?mode=read#details", in: app)

        let toolbar = app.toolbars.containing(.button, identifier: "browser.tabs").firstMatch
        let field = app.searchFields.firstMatch
        let tabs = toolbar.buttons["browser.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 12))
        XCTAssertTrue(field.waitForExistence(timeout: 5), toolbar.debugDescription)
        XCTAssertTrue(tabs.isHittable)
        XCTAssertFalse(browserTab.isHittable)
        let webView = app.webViews.firstMatch
        XCTAssertGreaterThanOrEqual(webView.frame.maxY, app.frame.maxY - 1,
                                    "The webpage should extend behind the bottom toolbar")
        XCTAssertLessThan(webView.frame.minY, app.navigationBars.firstMatch.frame.maxY,
                          "The top bar needs webpage content underneath its native scroll edge")
        XCTAssertEqual(toolbar.frame.width, app.frame.width, accuracy: 1)
        XCTAssertLessThanOrEqual(toolbar.buttons["browser.back"].frame.minX - app.frame.minX, 44)
        XCTAssertLessThanOrEqual(app.frame.maxX - tabs.frame.maxX, 44)
        let restingWidth = field.frame.width
        XCTAssertGreaterThan(restingWidth, app.frame.width / 3)
        XCTAssertGreaterThan(field.frame.minX, toolbar.buttons["browser.forward"].frame.maxX)
        XCTAssertLessThan(field.frame.maxX, tabs.frame.minX)
        for control in [toolbar.buttons["browser.back"], toolbar.buttons["browser.forward"], tabs] {
            XCTAssertTrue(control.exists)
            XCTAssertEqual(control.frame.midY, field.frame.midY, accuracy: 12)
        }
        // Revisiting the same live tab from Wallet keeps WebKit's own history.
        XCTAssertTrue(app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 15))
        app.navigationBars.buttons["BackButton"].tap()
        app.tabBars.buttons["Wallet"].tap()
        browserTab.tap()
        tabs.tap()
        app.buttons["browser.tabs.done"].tap()
        submitBrowserAddress("example.org", in: app)
        let webBack = toolbar.buttons["browser.back"], webForward = toolbar.buttons["browser.forward"]
        let canGoBack = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: webBack)
        XCTAssertEqual(XCTWaiter.wait(for: [canGoBack], timeout: 15), .completed)
        webBack.tap()
        XCTAssertTrue(app.navigationBars["example.com"].waitForExistence(timeout: 8))
        webForward.tap()
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        webBack.tap()
        XCTAssertTrue(app.navigationBars["example.com"].waitForExistence(timeout: 8))
        capture("wallet-browser-native-toolbar", app)
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "https://example.com/?mode=read#details")
        XCTAssertGreaterThan(field.frame.width, restingWidth)
        XCTAssertFalse(tabs.isHittable)
        capture("wallet-browser-selected-address", app)
        field.typeText("replace.example")
        XCTAssertEqual(field.value as? String, "replace.example", "The first tap should select the entire URL")
        let clearAddress = field.buttons.firstMatch
        XCTAssertTrue(clearAddress.isHittable)
        clearAddress.tap()
        XCTAssertTrue(app.keyboards.firstMatch.exists)
        let closeEditor = app.toolbars.buttons.matching(NSPredicate(format: "label ==[c] 'Close'")).firstMatch
        XCTAssertTrue(closeEditor.isHittable)
        XCTAssertGreaterThanOrEqual(closeEditor.frame.minX, field.frame.maxX)
        closeEditor.tap()
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertTrue(app.navigationBars["example.com"].exists)
        field.tap()
        XCTAssertEqual(field.value as? String, "https://example.com/?mode=read#details")
        field.typeText("https://example.org/?entry=toolbar")
        XCTAssertEqual(field.value as? String, "https://example.org/?entry=toolbar")
        app.keyboards.buttons.matching(NSPredicate(format: "label IN %@", ["Go", "Search", "go", "search"])).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 10))
        XCTAssertTrue(tabs.isHittable)
        XCTAssertTrue(app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 15))
        webView.swipeUp()
        capture("wallet-browser-top-scroll-edge", app)
        tabs.tap()
        let newTab = app.buttons["browser.tabs.new"]
        let examplePreview = app.buttons.matching(identifier: "browser.tab.preview")
            .matching(NSPredicate(format: "value == %@", "example.org")).firstMatch
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Bookmarks"].exists)
        newTab.tap()
        submitBrowserAddress("duckduckgo.com", in: app)
        XCTAssertTrue(app.navigationBars["duckduckgo.com"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts.firstMatch.waitForExistence(timeout: 15))
        webView.swipeUp()
        capture("wallet-browser-toolbar-over-page", app)
        tabs.tap()
        let closeButtons = app.buttons.matching(identifier: "browser.tab.close")
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 6))
        XCTAssertEqual(closeButtons.count, 2)
        XCTAssertEqual(app.buttons.matching(identifier: "browser.tab.preview").count, 2)
        XCTAssertEqual(closeButtons.element(boundBy: 0).frame.midY, closeButtons.element(boundBy: 1).frame.midY, accuracy: 2)
        capture("wallet-browser-tab-previews", app)
        let privateTabs = app.segmentedControls.buttons["Private"]
        privateTabs.tap()
        XCTAssertTrue(app.staticTexts["No open tabs"].waitForExistence(timeout: 5))
        XCTAssertFalse(examplePreview.exists)
        newTab.tap()
        submitBrowserAddress("example.org", in: app)
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        tabs.tap()
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        XCTAssertEqual(closeButtons.count, 1)
        app.segmentedControls.buttons["2 Tabs"].tap()
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 5))
        examplePreview.tap()
        XCTAssertTrue(app.navigationBars["example.org"].waitForExistence(timeout: 8))
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        app.buttons["browser.tabs.exit"].tap()
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(browserTab.waitForExistence(timeout: 8))
        XCTAssertTrue(browserTab.isHittable)
        XCTAssertFalse(tabs.exists)

        // Both Tabs entry points use the grid. The library retains its own
        // bookmarks and history, and can hand over after its sheet closes.
        browserTab.tap()
        tabs.tap()
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 8))
        closeButtons.element(boundBy: 1).tap()
        XCTAssertEqual(closeButtons.count, 1)
        app.buttons["browser.tabs.done"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        app.buttons["browser.menu"].tap()
        app.buttons["browser.library"].tap()
        let libraryTabs = app.buttons["browser.library.tabs"]
        XCTAssertTrue(libraryTabs.waitForExistence(timeout: 5))
        libraryTabs.tap()
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 8))
        examplePreview.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 12))
        XCTAssertFalse(browserTab.isHittable)
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(newTab.waitForExistence(timeout: 5))
        app.buttons["browser.tabs.exit"].tap()
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(browserTab.waitForExistence(timeout: 8))
        XCTAssertTrue(browserTab.isHittable)

        // A restored regular tab has its last rendered image before visiting it.
        // The private tab and its image belonged only to the previous session.
        app.terminate()
        app.launch()
        XCTAssertTrue(browserTab.waitForExistence(timeout: 35))
        browserTab.tap()
        tabs.tap()
        XCTAssertTrue(examplePreview.waitForExistence(timeout: 8))
        XCTAssertEqual(closeButtons.count, 1)
        privateTabs.tap()
        XCTAssertTrue(app.staticTexts["No open tabs"].waitForExistence(timeout: 5))
        app.segmentedControls.buttons["1 Tab"].tap()
        closeButtons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No open tabs"].waitForExistence(timeout: 5))
        app.buttons["browser.tabs.done"].tap()
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(browserTab.waitForExistence(timeout: 8))
        XCTAssertTrue(browserTab.isHittable)
    }

    @MainActor func testHomeCrossfadeBetweenSummaryAndAssets() {
        continueAfterFailure = false
        let device = XCUIDevice.shared
        let previousAppearance = device.appearance
        defer { device.appearance = previousAppearance }
        device.appearance = .light
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let receive = app.buttons["home.receive"]
        let assets = app.staticTexts["Assets"].firstMatch
        XCTAssertTrue(assets.waitForExistence(timeout: 8))
        XCTAssertTrue(receive.isHittable)
        XCTAssertTrue(app.buttons["home.send"].isHittable)
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let scale = CGFloat(image.width) / app.frame.width
        let from = ceil(receive.frame.maxY + 8)
        let to = floor(assets.frame.minY - 20)
        XCTAssertGreaterThan(to - from, 60)
        let crop = image.cropping(to: CGRect(x: CGFloat(image.width) * 0.48, y: from * scale,
            width: CGFloat(image.width) * 0.04, height: (to - from) * scale))!
        // One average sample per point avoids compression/dithering noise. The
        // cobalt fixture should blend over a region, not jump through a band.
        let height = Int(to - from)
        var samples = [UInt8](repeating: 0, count: height * 4)
        samples.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: height,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.interpolationQuality = .high
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: height))
        }
        let intermediateRows = stride(from: 0, to: samples.count, by: 4).filter {
            let darkest = min(samples[$0], samples[$0 + 1], samples[$0 + 2])
            return (90...220).contains(darkest)
        }.count
        XCTAssertGreaterThanOrEqual(intermediateRows, 55, "The fade must not collapse to a narrow colored/white stripe")
        print("OATH_HOME_FADE_INTERMEDIATE_POINTS=\(intermediateRows)")
        capture("home-crossfade-light", app)

        let resting = screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
        XCTAssertLessThanOrEqual(max(resting.r, resting.g, resting.b) - min(resting.r, resting.g, resting.b), 2)
        XCTAssertGreaterThan(resting.r, 235)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists,
                       "Native search must not attach the form keyboard accessory")
        capture("home-search-native-keyboard", app)
        app.buttons["close"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        // A short pull must move the same boundary with the actions and settle
        // without a gap; it does not need to trigger a wallet/network refresh.
        let originalTop = receive.frame.minY
        let scroll = app.scrollViews["home.scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 45)),
                    withVelocity: .slow, thenHoldForDuration: 0.2)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(receive.frame.minY - originalTop) < 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
        capture("home-crossfade-after-pull", app)

        // Exercise the actual persisted appearance choice, including returning
        // from its full-screen presentation to the existing Home scroll host.
        app.buttons["home.settings"].tap()
        let appearance = app.buttons["settings.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
        let darkOption = app.buttons["settings.appearance.dark"]
        XCTAssertTrue(darkOption.waitForExistence(timeout: 5))
        darkOption.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: darkOption)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        let close = app.buttons["options.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let appearanceChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let pixel = self.screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
            return max(pixel.r, pixel.g, pixel.b) < 65
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [appearanceChanged], timeout: 8), .completed)
        XCTAssertTrue(receive.isHittable)
        let dark = screenPixel(x: 0.5, y: (assets.frame.minY - 8) / app.frame.height)
        XCTAssertLessThanOrEqual(max(dark.r, dark.g, dark.b) - min(dark.r, dark.g, dark.b), 2)
        capture("home-crossfade-dark", app)

        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 5))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        app.cells["language.choice.ar"].tap()
        app.buttons["options.close"].tap()
        capture("home-crossfade-arabic", app)
        app.searchFields.firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        capture("home-search-native-keyboard-arabic", app)
    }

    @MainActor func testPullBlurReturnsToOriginalHome() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let phrase = app.textViews["recovery.phrase"]
        XCTAssertTrue(phrase.waitForExistence(timeout: 8))
        phrase.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let settings = app.buttons["home.settings"]
        let receive = app.buttons["home.receive"]
        let toolbarTop = settings.frame.minY
        let receiveTop = receive.frame.minY
        let scroll = app.scrollViews["home.scroll"]
        capture("pull-blur-before", app)
        for (name, distance, hold): (String, CGFloat, TimeInterval) in [
            ("short", 45, 1.0), ("refresh", 250, 3.0)
        ] {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(receive.frame.minY - receiveTop) < 1
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
            XCTAssertTrue(receive.isHittable)
            capture("pull-blur-after-\(name)", app)
        }
        scroll.swipeUp(velocity: .slow)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        capture("pull-blur-normal-scroll", app)
    }

    #if DEBUG && targetEnvironment(simulator)
    @MainActor private func openFixtureSidebar(extraWallets: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-oath-home-scroll-fixture", "-oath-sidebar-wallets", "-oath.walletTestScope",
                               UUID().uuidString, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if let extraWallets { app.launchArguments += ["-oath.sidebarExtraWallets", String(extraWallets)] }
        app.launch()
        let open = app.navigationBars.buttons["wallet.sidebar.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForExistence(timeout: 5))
        return app
    }

    @MainActor func testSidebarResortRequiresTwoActiveWallets() {
        continueAfterFailure = false
        for extraWallets in 0...1 {
            let app = openFixtureSidebar(extraWallets: extraWallets)
            defer { app.terminate() }
            XCTAssertTrue(app.buttons["wallets.recentlyDeleted"].exists)
            let menus = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sidebar.walletMenu."))
            XCTAssertEqual(menus.count, 1 + extraWallets)
            menus.firstMatch.tap()
            XCTAssertTrue(app.buttons["Customize Wallet"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["Resort Wallet"].exists, extraWallets == 1)
        }
    }

    @MainActor func testSidebarWalletMenuTargetsInactiveWallet() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let keyMenu = app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000003"]
        XCTAssertTrue(keyMenu.waitForExistence(timeout: 5))
        keyMenu.tap()
        XCTAssertTrue(app.buttons["Reveal Private Key"].exists)
        XCTAssertFalse(app.buttons["Reveal Recovery Phrase"].exists)
        let settings = app.buttons["Wallet settings"]
        let resort = app.buttons["Resort Wallet"]
        let delete = app.buttons["Delete Wallet"]
        XCTAssertTrue(delete.exists)
        XCTAssertLessThan(settings.frame.maxY, resort.frame.minY)
        XCTAssertLessThan(resort.frame.maxY, delete.frame.minY)
        capture("sidebar-wallet-menu", app)
        app.buttons["Customize Wallet"].tap()
        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 8))
        XCTAssertEqual(editor.value as? String, "Fixture wallet 3")
    }

    @MainActor func testSidebarRecentlyDeletedOpensAsSheetAndAppSettingsOpensFullScreen() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let close = app.navigationBars.buttons["options.close"]
        app.buttons["wallets.recentlyDeleted"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertLessThan(close.frame.midY, app.frame.height / 4)
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Deleted fixture wallet")).firstMatch.exists)
        close.tap()
        let open = app.navigationBars.buttons["wallet.sidebar.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["wallet.sidebar.addWallet"].tap()
        let addClose = app.navigationBars.buttons["wallets.close"]
        XCTAssertTrue(addClose.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(addClose.frame.midY, app.frame.height / 2)
        addClose.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        app.buttons["wallet.sidebar.settings"].tap()
        XCTAssertTrue(app.buttons["settings.currency"].waitForExistence(timeout: 5))
        XCTAssertLessThan(close.frame.midY, app.frame.height / 4)
    }

    @MainActor func testSidebarAddWalletResizesBetweenEntrySteps() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        app.buttons["wallet.sidebar.addWallet"].tap()
        let close = app.navigationBars.buttons["wallets.close"]
        let back = app.navigationBars.buttons["BackButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let menuTop = close.frame.midY
        XCTAssertGreaterThan(menuTop, app.frame.height / 2)

        func backToMenu() {
            back.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertEqual(close.frame.midY, menuTop, accuracy: 4)
            XCTAssertFalse(app.keyboards.firstMatch.exists)
        }

        app.buttons["wallets.restore"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloudRestore.list"].waitForExistence(timeout: 8))
        XCTAssertGreaterThan(back.frame.midY, app.frame.height / 3)
        backToMenu()

        app.buttons["wallets.import"].tap()
        XCTAssertTrue(app.textViews["recovery.phrase"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        backToMenu()

        app.buttons["wallets.importPrivateKey"].tap()
        let chain = app.descendants(matching: .any).matching(identifier: "import.choice.evm").firstMatch
        XCTAssertTrue(chain.waitForExistence(timeout: 8))
        XCTAssertLessThan(back.frame.midY, menuTop - 80)
        chain.tap()
        let keyField = app.descendants(matching: .any).matching(identifier: "privateKeyImport.field").firstMatch
        XCTAssertTrue(keyField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(chain.waitForExistence(timeout: 5))
        backToMenu()

        app.buttons["wallets.create"].tap()
        let name = app.textFields["walletCustomize.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let customizeTop = app.navigationBars["Customize Wallet"].frame.minY
        XCTAssertLessThan(customizeTop, menuTop - 40)
        XCTAssertGreaterThan(customizeTop, app.frame.height / 3)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testSidebarStaysOpenAfterCancellingOrDenyingWalletDeletion() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let menu = app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000003"]
        let dialog = app.alerts["Remove Wallet?"]
        let settingsRow = app.buttons["walletSettings.customize"]
        menu.tap()
        app.buttons["Delete Wallet"].tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Fixture wallet 3")).firstMatch.exists)
        XCTAssertFalse(settingsRow.exists)
        dialog.buttons["Cancel"].tap()
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        app.buttons["Delete Wallet"].tap()
        dialog.buttons["Remove Wallet"].tap()
        // The keyless fixture rejects authorization. Dismissing that error
        // must return directly to the same usable row in the open drawer.
        let denied = app.alerts.staticTexts["Couldn’t save your wallet changes. Please try again."]
        XCTAssertTrue(denied.waitForExistence(timeout: 8))
        XCTAssertFalse(settingsRow.exists)
        app.alerts.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].exists)
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.buttons["Resort Wallet"].isHittable)
    }

    @MainActor func testRecoveryWarningClosesFromWalletMenuAndGoesBackFromSettings() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let menu = app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000001"]
        let warning = app.buttons["recoveryDisclosure.understand"]
        let close = app.navigationBars.buttons["options.close"]
        let switcher = app.navigationBars.buttons["wallet.sidebar.open"]

        menu.tap()
        app.buttons["Reveal Recovery Phrase"].tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertTrue(close.isHittable)
        XCTAssertLessThan(close.frame.midY, app.frame.height / 4)
        close.tap()
        XCTAssertTrue(switcher.waitForExistence(timeout: 5))
        XCTAssertFalse(warning.exists)
        switcher.tap()

        menu.tap()
        app.buttons["Wallet settings"].tap()
        let recoveryRow = app.buttons["walletSettings.recovery"]
        XCTAssertTrue(recoveryRow.waitForExistence(timeout: 5))
        recoveryRow.tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 5))
        XCTAssertFalse(close.exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(recoveryRow.waitForExistence(timeout: 5))
    }

    @MainActor func testSidebarMenusDismissWhenAppBackgrounds() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let switcher = app.navigationBars.buttons["wallet.sidebar.open"]
        let drawer = app.buttons["sidebar.dismiss"]

        func leaveAndReopen(menuItem: XCUIElement) {
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
            XCUIDevice.shared.press(.home)
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
            app.activate()
            XCTAssertTrue(menuItem.waitForNonExistence(timeout: 5), "The menu survived its sidebar closing")
            XCTAssertFalse(drawer.exists)
            switcher.tap()
            XCTAssertTrue(drawer.waitForExistence(timeout: 5))
            XCTAssertFalse(menuItem.exists)
        }

        app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000001"].tap()
        leaveAndReopen(menuItem: app.buttons["Customize Wallet"])
        app.buttons["wallet.sidebar.settings"].press(forDuration: 0.8)
        app.buttons["Language"].tap()
        leaveAndReopen(menuItem: app.buttons["Device language"])
    }

    @MainActor func testSidebarReorderPrivateKeysWithinGroup() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        func menu(_ digit: Int) -> XCUIElement {
            app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-00000000000" + String(digit)]
        }
        XCTAssertLessThan(menu(2).frame.midY, menu(3).frame.midY)
        XCTAssertLessThan(menu(3).frame.midY, menu(4).frame.midY)
        let y3 = menu(3).frame.midY, y4 = menu(4).frame.midY
        let x = menu(3).frame.midX
        menu(3).tap()
        app.buttons["Resort Wallet"].tap()
        let done = app.buttons["sidebar.sort.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertFalse(menu(3).exists)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let handle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reorder'")).firstMatch
        let handleX = handle.exists ? handle.frame.midX : x
        origin.withOffset(CGVector(dx: handleX, dy: y3)).press(forDuration: 0.6,
            thenDragTo: origin.withOffset(CGVector(dx: handleX, dy: y4 + 9)), withVelocity: .slow,
            thenHoldForDuration: 0.4)
        done.tap()
        XCTAssertTrue(menu(3).waitForExistence(timeout: 5))
        XCTAssertLessThan(menu(4).frame.midY, menu(3).frame.midY)
        app.buttons["sidebar.dismiss"].tap()
        app.navigationBars.buttons["wallet.sidebar.open"].tap()
        XCTAssertLessThan(menu(2).frame.midY, menu(4).frame.midY)
        XCTAssertLessThan(menu(4).frame.midY, menu(3).frame.midY)
    }

    @MainActor func testSidebarHelpAndContactWarning() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let help = app.buttons["wallet.sidebar.support"]
        help.press(forDuration: 0.8)
        app.buttons["Contact Support"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Never include private keys'")).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(help.isHittable)
        help.press(forDuration: 0.8)
        app.buttons["Contact Support"].tap()
        alert.buttons["Accept & Continue"].tap()
        // A disposable simulator has no configured Mail account: the native
        // contact presenter offers the real support address without sending mail.
        XCTAssertTrue(app.alerts.staticTexts.containing(NSPredicate(format: "label CONTAINS 'care@oathwallet.org'"))
            .firstMatch.waitForExistence(timeout: 10))
        app.alerts.buttons["Cancel"].tap()
        app.navigationBars.buttons["wallet.sidebar.open"].tap()
        help.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 12))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars.buttons["wallet.sidebar.open"].isHittable)
    }

    @MainActor func testSidebarSettingsSubmenusUpdatePreferences() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let settings = app.buttons["wallet.sidebar.settings"]
        let dismiss = app.buttons["sidebar.dismiss"]
        let open = app.navigationBars.buttons["wallet.sidebar.open"]
        settings.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["Face ID & Passcode"].exists)
        app.buttons["Currency"].tap()
        let euroChoice = app.buttons.matching(NSPredicate(format: "label CONTAINS '(EUR)'")).firstMatch
        XCTAssertTrue(euroChoice.waitForExistence(timeout: 5))
        euroChoice.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
        open.tap()
        settings.press(forDuration: 0.8)
        app.buttons["Currency"].tap()
        XCTAssertTrue(euroChoice.isSelected)
        app.buttons.matching(NSPredicate(format: "label CONTAINS '(USD)'")).firstMatch.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        open.tap()
        settings.press(forDuration: 0.8)
        app.buttons["Language"].tap()
        app.buttons["العربية"].tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        let localized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "المحافظ"),
                                                  object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [localized], timeout: 6), .completed)
        open.tap()
        XCTAssertTrue(app.navigationBars["المحافظ"].waitForExistence(timeout: 6))
    }

    @MainActor func testWalletListStaysReadableWhenSwitchingFromArabicToEnglish() throws {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let open = app.navigationBars.buttons["wallet.sidebar.open"]
        let settings = app.buttons["wallet.sidebar.settings"]
        let menu = app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000001"]

        func chooseLanguage(menu title: String, choice: String) {
            settings.press(forDuration: 0.8)
            app.buttons[title].tap()
            app.buttons[choice].tap()
            XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForNonExistence(timeout: 5))
        }

        func checkRows(rightToLeft: Bool) throws {
            let screenshot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = rightToLeft ? "wallet-list-arabic" : "wallet-list-english"
            attachment.lifetime = .keepAlways
            add(attachment)
            // Accessibility labels can still be correct when a cell is rendered backwards.
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            let image = try XCTUnwrap(screenshot.image.cgImage)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let names = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
            XCTAssertTrue(names.contains { $0.contains("fixture wallet") }, "A wallet name must be readable in the rendered list")
            XCTAssertTrue(menu.isHittable)
            if rightToLeft {
                XCTAssertLessThan(menu.frame.midX, settings.frame.midX)
            } else {
                XCTAssertGreaterThan(menu.frame.midX, settings.frame.midX)
            }
        }

        chooseLanguage(menu: "Language", choice: "العربية")
        let arabicHome = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", "المحافظ"),
                                                   object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [arabicHome], timeout: 6), .completed)
        // Start with a list created in RTL, as on an existing Arabic installation.
        app.terminate()
        app.launch()
        XCTAssertTrue(open.waitForExistence(timeout: 30))
        open.tap()
        XCTAssertTrue(app.navigationBars["المحافظ"].waitForExistence(timeout: 5))
        try checkRows(rightToLeft: true)
        chooseLanguage(menu: "اللغة", choice: "لغة الجهاز")
        open.tap()
        XCTAssertTrue(app.navigationBars["Wallets"].waitForExistence(timeout: 5))
        try checkRows(rightToLeft: false)
    }

    @MainActor func testNativeSidebarMenuActionsAfterSwitchingToArabic() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        let settings = app.buttons["wallet.sidebar.settings"]
        let opener = app.navigationBars.buttons["wallet.sidebar.open"]
        func openLanguageMenu(_ title: String) {
            settings.press(forDuration: 0.8)
            app.buttons[title].tap()
        }
        openLanguageMenu("Language")
        XCTAssertTrue(app.buttons["Device language"].waitForExistence(timeout: 5))
        app.buttons["العربية"].tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForNonExistence(timeout: 5))
        opener.tap()
        XCTAssertTrue(app.navigationBars["المحافظ"].waitForExistence(timeout: 5))
        app.buttons["sidebar.walletMenu.00000000-0000-4000-8000-000000000001"].tap()
        XCTAssertTrue(app.buttons["تخصيص المحفظة"].exists)
        XCTAssertTrue(app.buttons["حذف المحفظة"].isHittable)
        capture("arabic-wallet-options", app)
        app.buttons["حذف المحفظة"].tap()
        let removal = app.alerts["هل تريد إزالة المحفظة؟"]
        XCTAssertTrue(removal.waitForExistence(timeout: 5))
        removal.buttons["إلغاء"].tap()
        app.buttons["wallet.sidebar.support"].press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["التواصل مع الدعم"].exists)
        capture("arabic-help-options", app)
        app.buttons["التواصل مع الدعم"].tap()
        let warning = app.alerts.firstMatch
        XCTAssertTrue(warning.buttons["موافقة ومتابعة"].waitForExistence(timeout: 5))
        warning.buttons["إلغاء"].tap()
        settings.tap()
        XCTAssertTrue(app.buttons["settings.currency"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        opener.tap()
        settings.press(forDuration: 0.8)
        capture("arabic-settings-options", app)
        app.buttons["العملة"].tap()
        capture("arabic-currency-options", app)
        let euro = app.buttons.matching(NSPredicate(format: "label CONTAINS 'EUR'")).firstMatch
        euro.tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForNonExistence(timeout: 5))
        opener.tap()
        openLanguageMenu("اللغة")
        capture("arabic-language-options", app)
        XCTAssertTrue(app.buttons["لغة الجهاز"].waitForExistence(timeout: 5))
        app.buttons["لغة الجهاز"].tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForNonExistence(timeout: 5))
        opener.tap()
        openLanguageMenu("Language")
        XCTAssertTrue(app.buttons["Device language"].waitForExistence(timeout: 5))
    }

    @MainActor func testSidebarSecurityDeniesKeylessFixture() {
        continueAfterFailure = false
        let app = openFixtureSidebar()
        defer { app.terminate() }
        app.buttons["wallet.sidebar.settings"].press(forDuration: 0.8)
        app.buttons["Face ID & Passcode"].tap()
        // This fixture deliberately has no vault envelope or authentication
        // credential. It must never be allowed into the Security page.
        XCTAssertTrue(app.alerts.staticTexts["Your wallet could not be opened. Please try again."]
            .waitForExistence(timeout: 8))
        XCTAssertFalse(app.descendants(matching: .any)["security.screen"].exists)
        XCTAssertFalse(app.buttons["settings.security"].exists)
    }

    @MainActor func testWalletSwitcherReopensAfterSheetAndForeground() {
        continueAfterFailure = false
        let appearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = appearance }
        let app = openFixtureSidebar()
        defer { app.terminate() }

        let switcher = app.navigationBars.buttons["wallet.sidebar.open"]
        let dismiss = app.buttons["sidebar.dismiss"]
        let phase = app.staticTexts["fixture.scenePhase"]
        func assertActiveHome() {
            XCTAssertEqual(app.state, .runningForeground)
            let active = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'active'"), object: phase)
            XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 5), .completed)
            if #available(iOS 26, *) { assertWalletGlyphOverArtwork(switcher, in: app) }
        }
        func openAndClose(_ stage: String) {
            let available = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: switcher)
            XCTAssertEqual(XCTWaiter.wait(for: [available], timeout: 5), .completed, stage)
            switcher.tap()
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5), stage)
            dismiss.tap()
            XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5), stage)
        }
        dismiss.tap()
        XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
        assertActiveHome()
        guard let initialDepartures = Int(phase.value as? String ?? "") else {
            return XCTFail("The Home fixture did not report its scene transitions")
        }
        func changeLanguage(menu: String, choice: String, walletLabel: String) {
            switcher.tap()
            XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
            app.buttons["wallet.sidebar.settings"].press(forDuration: 0.8)
            app.buttons[menu].tap()
            app.buttons[choice].tap()
            XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5))
            let translated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label BEGINSWITH %@", walletLabel), object: switcher)
            XCTAssertEqual(XCTWaiter.wait(for: [translated], timeout: 6), .completed)
            assertActiveHome()
            XCTAssertEqual(phase.value as? String, String(initialDepartures), "Changing language should keep the scene active")
            XCTAssertTrue(app.buttons["home.scanner"].isEnabled)
            XCTAssertTrue(app.buttons["home.receive"].isHittable)
            capture("Home after choosing " + choice, app)
        }
        changeLanguage(menu: "Language", choice: "العربية", walletLabel: "المحافظ")
        changeLanguage(menu: "اللغة", choice: "لغة الجهاز", walletLabel: "Wallets")
        openAndClose("Home after restoring English")
        app.buttons["home.assetFilters"].tap()
        let close = app.buttons["assets.filter.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        openAndClose("Home after dismissing asset filters")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) ||
                      app.state == .runningBackgroundSuspended)
        app.activate()
        openAndClose("Home after foregrounding")
        assertActiveHome()
        XCTAssertGreaterThan(Int(phase.value as? String ?? "") ?? -1, initialDepartures)
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Wallet"].tap()
        openAndClose("Home after leaving History")
    }

    @MainActor func testNativeHomeAndAssetToolbarsAndBackNavigation() {
        continueAfterFailure = false
        let previousAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = .light
        defer { XCUIDevice.shared.appearance = previousAppearance }
        let app = XCUIApplication()
        app.launchArguments = ["-oath-home-scroll-fixture", "-oath.walletTestScope", UUID().uuidString,
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }

        let bars = app.navigationBars
        let wallet = bars.buttons["wallet.sidebar.open"]
        let row = app.buttons["home.token.bench-0"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        XCTAssertTrue(wallet.isHittable)
        XCTAssertTrue(app.tabBars.buttons["History"].isHittable)
        XCTAssertTrue(app.buttons["home.scanner"].isHittable)
        // The system glass extends beyond its button's accessibility frame.
        // Exercise both axes of the 44 pt hit target on the actual toolbar.
        let drawerDismiss = app.buttons["sidebar.dismiss"]
        for offset in [CGVector(dx: 21, dy: 0), CGVector(dx: 0, dy: 21)] {
            wallet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(offset).tap()
            XCTAssertTrue(drawerDismiss.waitForExistence(timeout: 5))
            drawerDismiss.tap()
            XCTAssertTrue(drawerDismiss.waitForNonExistence(timeout: 5))
        }
        let homeSendFrame = app.buttons["home.send"].frame
        let homeReceiveFrame = app.buttons["home.receive"].frame
        capture("Home toolbar over artwork", app)
        if #available(iOS 26, *) {
            assertWalletGlyphOverArtwork(wallet, in: app)
        }

        row.tap()
        let detail = bars["Asset 00"]
        let info = detail.buttons["asset.information"]
        XCTAssertTrue(info.waitForExistence(timeout: 8))
        XCTAssertTrue(detail.buttons["asset.scanner"].isHittable)
        XCTAssertEqual(app.buttons["asset.send"].frame, homeSendFrame)
        XCTAssertEqual(app.buttons["asset.receive"].frame, homeReceiveFrame)
        let networkBar = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Asset 00 on Ethereum")).firstMatch
        XCTAssertFalse(networkBar.exists)
        let balance = app.staticTexts["asset.fiatBalance"]
        XCTAssertTrue(balance.exists)
        XCTAssertLessThanOrEqual(detail.frame.maxY, balance.frame.minY)
        let initialBalanceY = balance.frame.midY
        capture("Asset Detail toolbar over artwork", app)
        app.swipeUp()
        XCTAssertTrue(!balance.isHittable || balance.frame.midY < initialBalanceY)
        info.tap()
        let close = app.buttons["options.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        let back = detail.buttons["Back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))

        row.tap()
        XCTAssertTrue(info.waitForExistence(timeout: 5))
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable)
        XCTAssertFalse(app.buttons["sidebar.dismiss"].isHittable)
        app.swipeUp()
        XCTAssertTrue(wallet.isHittable)
        capture("Home toolbar over assets", app)
        if #available(iOS 26, *) {
            let glyph = screenPixel(x: wallet.frame.midX / app.frame.width, y: wallet.frame.midY / app.frame.height)
            XCTAssertLessThan(max(glyph.r, glyph.g, glyph.b), 80, "The wallet icon must be dark over the light list")
        }

        app.tabBars.buttons["History"].tap()
        let history = bars["History"]
        let filters = history.buttons["history.filters"]
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertFalse(history.buttons["Back"].exists)
        XCTAssertTrue(app.tabBars.buttons["Wallet"].isHittable)
        filters.tap()
        app.buttons["Sent"].tap()
        app.buttons["history.filter.apply"].tap()
        XCTAssertTrue(filters.waitForExistence(timeout: 5))
        XCTAssertTrue((filters.value as? String)?.contains("1") == true)
        capture("Activity toolbar with an active filter", app)
        app.tabBars.buttons["Wallet"].tap()
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        XCTAssertTrue(app.buttons["sidebar.dismiss"].waitForExistence(timeout: 5))
    }
    #endif

    @MainActor func testShortAndHeldRefreshMotion() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments.removeAll { $0 == "-oath-artwork-reduce-motion" }
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        let top = app.buttons["home.settings"].frame.minY
        let scroll = app.scrollViews["home.scroll"]
        capture("motion-begin", app)
        for (depth, hold) in [(0.24, 0.0), (0.42, 0.0), (0.72, 2.0), (0.64, 0.0)] {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: depth))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: hold)
            XCTAssertTrue(app.buttons["home.receive"].isHittable)
            XCTAssertEqual(app.buttons["home.settings"].frame.minY, top, accuracy: 1)
        }
        capture("motion-end", app)
        // A shorter body after native bottom-search filtering must still size
        // itself, bounce, and keep its opaque lower surface behind the rows.
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(search.frame.midY, app.frame.height * 0.75)
        search.tap()
        search.typeText("Solana\n")
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        capture("motion-filtered", app)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.18))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.6)
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        app.buttons["close"].tap()
        XCTAssertTrue(app.buttons["home.network.bitcoin"].waitForExistence(timeout: 5))
        scroll.swipeUp()
        XCTAssertEqual(app.buttons["home.settings"].frame.minY, top, accuracy: 1)
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
    }

    @MainActor func testNativeHomeBarsAndAssetSearch() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 8))
        XCTAssertTrue(tabs.buttons["Wallet"].isSelected)
        XCTAssertTrue(tabs.buttons["History"].exists)
        XCTAssertFalse(tabs.buttons["Browser"].exists)
        XCTAssertTrue(tabs.buttons["Search"].exists)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "Wallet must not have a persistent search field")
        XCTAssertTrue(app.navigationBars.buttons["wallet.sidebar.open"].isHittable)

        tabs.buttons["Search"].tap()
        let assetSearch = app.searchFields.firstMatch
        XCTAssertTrue(assetSearch.waitForExistence(timeout: 5))
        assertBottomSearch(assetSearch, in: app)
        assetSearch.tap(); assetSearch.typeText("Solana")
        XCTAssertTrue(app.buttons["home.network.solana"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        app.buttons["home.network.solana"].tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Wallet"].isSelected)
        XCTAssertFalse(app.searchFields.firstMatch.isHittable, "Back returns to Home with search closed")
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        tabs.buttons["Search"].tap()
        XCTAssertTrue(assetSearch.waitForExistence(timeout: 5))
        XCTAssertEqual(assetSearch.value as? String, assetSearch.placeholderValue)
        assertBottomSearch(assetSearch, in: app)
        closeSearch(in: app)
        tabs.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 8))
        XCTAssertTrue(tabs.buttons["History"].isSelected)
        let historySearch = app.searchFields["Search transactions"]
        XCTAssertTrue(historySearch.waitForExistence(timeout: 5))
        historySearch.tap(); historySearch.typeText("no-matching-transaction-id")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.network.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["keyboard.keyboardDone"].exists)
        closeSearch(in: app)
        tabs.buttons["Wallet"].tap()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.searchFields.firstMatch.isHittable)
        tabs.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields["Search assets or contract address"].waitForExistence(timeout: 5))
        assertBottomSearch(app.searchFields.firstMatch, in: app)
    }

    @MainActor private func assertBottomSearch(_ field: XCUIElement, in app: XCUIApplication) {
        let keyboard = app.keyboards.firstMatch
        let bottom = keyboard.exists ? keyboard.frame.minY : app.frame.maxY
        XCTAssertGreaterThan(field.frame.midY, app.frame.height * 0.4,
                             "Native tab search must not fall back to the top navigation drawer")
        XCTAssertLessThan(bottom - field.frame.maxY, 160)
    }

    @MainActor private func closeSearch(in app: XCUIApplication) {
        let close = app.buttons["Close"]
        if close.isHittable { close.tap() }
        else if app.buttons["Cancel"].isHittable { app.buttons["Cancel"].tap() }
    }

    /// Keep the real renderer running: a still screenshot after release cannot
    /// detect a one-frame safe-area gap during UIKit's refresh inset changes.
    /// The recording checks BOTH the status bar and the card/button boundary at
    /// every frame, including release. Checking the top alone missed clipping.
    @MainActor func testLiveHeaderRemainsCoveredAcrossRepeatedRefreshes() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launchArguments.removeAll { $0 == "-oath-artwork-reduce-motion" }
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        let toolbarTop = settings.frame.minY
        XCTAssertEqual(app.navigationBars.count, 1)
        capture("refresh-live-begin", app)

        let scroll = app.scrollViews["home.scroll"]
        for (index, depth) in [0.34, 0.64, 0.42, 0.70, 0.55, 0.64].enumerated() {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: depth))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: index.isMultiple(of: 2) ? .fast : .slow,
                        thenHoldForDuration: index.isMultiple(of: 2) ? 0 : 0.4)
            XCTAssertTrue(app.buttons["home.receive"].isHittable)
            XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        }
        capture("refresh-live-end", app)
        // The stationary full-screen artwork must not leak below a short body.
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Solana\n")
        XCTAssertTrue(app.buttons["home.network.solana"].isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        capture("refresh-short-content", app)
        app.buttons["close"].tap()
        scroll.swipeUp()
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        XCTAssertTrue(settings.isHittable)
        capture("refresh-live-scrolled", app)
        app.terminate()
    }

    @MainActor func testContinuousHeaderPullToRefreshAndPinnedToolbar() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        let settings = app.buttons["home.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertEqual(app.navigationBars.count, 1)
        XCTAssertFalse(app.staticTexts["Self-custodial wallet"].exists)
        XCTAssertFalse(app.staticTexts["26 networks"].exists)
        // The balance amount retains a truthful accessibility description, but
        // there is no visible balance-unavailable caption or action anymore.
        XCTAssertFalse(app.buttons["Balance unavailable"].exists)
        let toolbarTop = settings.frame.minY
        XCTAssertTrue(settings.isHittable)
        capture("home-continuous-header", app)

        let scroll = app.scrollViews["home.scroll"]
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.16))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 3)
        XCTAssertTrue(app.buttons["home.receive"].isHittable)
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        capture("home-after-refresh", app)

        scroll.swipeUp()
        XCTAssertEqual(settings.frame.minY, toolbarTop, accuracy: 1)
        XCTAssertTrue(settings.isHittable)
        capture("home-pinned-toolbar", app)
        settings.tap()
        XCTAssertTrue(app.buttons["options.close"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        app.terminate()
    }

    @MainActor func testCreatePersistUnlockAndReceive() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.createWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.createWallet"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        capture("home-created", app)
        app.buttons["home.network.bitcoin"].tap()
        let address = app.staticTexts["receive.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        let before = address.label
        XCTAssertTrue(before.hasPrefix("bc1q"))
        XCTAssertTrue(app.images["receive.qr"].exists)
        capture("receive-bitcoin", app)
        app.buttons["options.close"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["wallet.unlock.title"].waitForExistence(timeout: 15))
        enterPIN(app, digits: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(app.staticTexts["Incorrect passcode. Try again."].waitForExistence(timeout: 8))
        enterPIN(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        app.buttons["home.network.bitcoin"].tap()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, before)
        app.buttons["options.close"].tap()
        app.terminate()
    }

    @MainActor func testImportLeadsToKnownAddressesAndArabicHome() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        let submit = app.buttons["recovery.import"]
        for _ in 0..<3 where !submit.isHittable { app.swipeUp() }
        submit.tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 15))
        app.buttons["home.network.ethereum"].tap()
        let address = app.staticTexts["receive.address"]
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertEqual(address.label, "0x9858EfFD232B4033E47d90003D41EC34EcaEda94")
        capture("receive-ethereum-fixture", app)
        app.buttons["options.close"].tap()
        capture("home-imported", app)
        let search = app.searchFields["Search assets"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Solana\n")
        let solana = app.buttons["home.network.solana"]
        for _ in 0..<3 where !solana.isHittable { app.swipeUp() }
        XCTAssertTrue(solana.isHittable)
        XCTAssertFalse(app.buttons["home.network.bitcoin"].exists)
        solana.tap()
        XCTAssertTrue(address.waitForExistence(timeout: 8))
        XCTAssertFalse(address.label.hasPrefix("0x"))
        app.buttons["options.close"].tap()
        app.terminate()

        // Same wallet, only change native locale/layout and Dynamic Type.
        app.launchArguments += ["-oath.languagePreference", "ar",
                                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["keypad.digit.2"].waitForExistence(timeout: 15))
        enterPIN(app)
        let receive = app.buttons["home.receive"]
        XCTAssertTrue(receive.waitForExistence(timeout: 15))
        for _ in 0..<4 where !receive.isHittable { app.swipeUp() }
        XCTAssertTrue(receive.isHittable)
        XCTAssertTrue(app.staticTexts["الرصيد الإجمالي"].exists)
        capture("home-arabic-accessibility", app)
        receive.tap()
        let bitcoin = app.buttons["receive.network.bitcoin"]
        // The content-sized sheet remains scrollable at the largest font size.
        for _ in 0..<8 where !bitcoin.isHittable { app.swipeUp() }
        XCTAssertTrue(bitcoin.isHittable)
        XCTAssertTrue(app.buttons["options.close"].isHittable)
        capture("receive-picker-arabic-accessibility", app)
        bitcoin.tap()
        XCTAssertTrue(app.staticTexts["receive.address"].waitForExistence(timeout: 8))
        capture("receive-bitcoin-arabic-accessibility", app)
        let copy = app.buttons["receive.copy"]
        for _ in 0..<5 where !copy.isHittable { app.scrollViews["options.scrollContent"].swipeUp() }
        XCTAssertTrue(copy.isHittable)
        app.terminate()
    }

    @MainActor func testRecoveryDisclosureRequiresAcknowledgementAndPasscode() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 15))
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.wallets"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.backup"].exists)
        app.buttons["settings.wallets"].tap()
        let wallet = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.wallet.")).firstMatch
        XCTAssertTrue(wallet.waitForExistence(timeout: 5))
        wallet.tap()
        let recovery = app.buttons["walletSettings.recovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 5))
        if !recovery.isHittable { app.swipeUp() }
        recovery.tap()
        let understand = app.buttons["recoveryDisclosure.understand"]
        XCTAssertTrue(understand.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        let close = app.buttons["options.close"]
        let initialTop = close.frame.minY
        understand.tap()
        // This test's isolated fixture has no biometric enrollment.
        XCTAssertTrue(app.buttons["keypad.digit.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        enterPIN(app, digits: [0, 0, 0, 0, 0, 0])
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons.firstMatch.tap()
        XCTAssertFalse(app.buttons["recoveryDisclosure.copy"].exists)
        enterPIN(app)
        let copy = app.buttons["recoveryDisclosure.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["recoveryDisclosure.word.1"].exists
                      || app.staticTexts["recoveryDisclosure.word.1"].exists)
        XCTAssertTrue(app.otherElements["recoveryDisclosure.word.12"].exists
                      || app.staticTexts["recoveryDisclosure.word.12"].exists)
        XCTAssertTrue(app.staticTexts["Never share or lose your recovery phrase."].exists)
        XCTAssertEqual(close.frame.minY, initialTop, accuracy: 1,
                       "The full-screen Settings navigation stays pinned when recovery words appear")
        XCTAssertTrue(copy.isHittable)
        copy.tap()
        XCTAssertTrue(app.buttons["recoveryDisclosure.copy"].staticTexts["Copied"].exists)
        app.navigationBars.buttons.matching(NSPredicate(format: "identifier != %@", "options.close")).firstMatch.tap()
        XCTAssertTrue(app.buttons["keypad.digit.1"].waitForExistence(timeout: 5))
        XCTAssertFalse(copy.exists, "Going back must require authentication again")
        close.tap()
        XCTAssertTrue(app.buttons["home.receive"].isHittable)
        app.terminate()
    }

    @MainActor func testTransactionNativeChromeAndSharing() {
        continueAfterFailure = false
        let app = configuredApp()
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.importWallet"].waitForExistence(timeout: 15))
        app.buttons["onboarding.importWallet"].tap()
        let field = app.textViews["recovery.phrase"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        // Published BIP39 vector; never a user's wallet.
        field.typeText(String(repeating: "abandon ", count: 11) + "about")
        app.buttons["recovery.keyboardDone"].tap()
        app.buttons["recovery.import"].tap()
        finishSetup(app)
        app.buttons["home.settings"].tap()
        app.buttons["settings.language"].tap()
        let languageSearch = app.searchFields["settings.languageSearch"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 5))
        languageSearch.tap(); languageSearch.typeText("Arabic")
        app.cells["language.choice.ar"].tap()
        app.buttons["options.close"].tap()
        let bitcoin = app.buttons["home.network.bitcoin"]
        XCTAssertTrue(bitcoin.waitForExistence(timeout: 10))
        for _ in 0..<3 where !bitcoin.isHittable { app.scrollViews["home.scroll"].swipeUp() }
        bitcoin.tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        let transaction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'asset.transaction.' AND label CONTAINS %@", "تم الاستلام")).firstMatch
        app.scrollViews["asset.scroll"].swipeUp()
        XCTAssertTrue(transaction.waitForExistence(timeout: 90), "Public Bitcoin activity is needed for this navigation check")
        for _ in 0..<4 where !transaction.isHittable { app.scrollViews["asset.scroll"].swipeUp() }
        transaction.tap()
        let export = app.buttons["transaction.share"]
        XCTAssertTrue(export.waitForExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["transaction.assetLogo"].exists)
        XCTAssertEqual(app.navigationBars.count, 1)
        XCTAssertTrue(app.navigationBars.buttons["transaction.share"].exists)
        XCTAssertFalse(app.staticTexts["القيمة التقديرية بالسعر الحالي"].exists)
        let copy = app.buttons["transaction.copy.asset.transaction_id"]
        XCTAssertTrue(copy.waitForExistence(timeout: 8))
        for _ in 0..<2 where !copy.isHittable { app.scrollViews.firstMatch.swipeUp() }
        copy.tap()
        XCTAssertEqual(copy.frame.width, 44, accuracy: 1)
        XCTAssertFalse(app.buttons["transaction.explorer"].exists, "Explorer belongs in the menu, not the receipt")
        capture("transaction-arabic-native-chrome", app)
        export.tap()
        XCTAssertTrue(app.buttons["transaction.explorer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transaction.shareLink"].exists)
        app.buttons["transaction.shareImage"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10), app.debugDescription)
        capture("transaction-native-image-share", app)
        app.buttons["header.closeButton"].tap()
        XCTAssertTrue(export.isHittable)
        export.tap()
        app.buttons["transaction.shareLink"].tap()
        XCTAssertTrue(app.cells["Copy"].waitForExistence(timeout: 10), app.debugDescription)
        capture("transaction-native-link-share", app)
        app.buttons["header.closeButton"].tap()
        app.navigationBars.buttons["BackButton"].tap()
        XCTAssertTrue(app.buttons["asset.information"].waitForExistence(timeout: 8))
        for _ in 0..<3 { app.scrollViews["asset.scroll"].swipeDown() }
        capture("transaction-return-to-artwork", app)
        app.terminate()
    }

    @MainActor private func configuredApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath.walletTestScope", UUID().uuidString,
                               "-oath-artwork-reduce-motion"]
        return app
    }

    @MainActor private func finishSetup(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["passcode.title"].waitForExistence(timeout: 8))
        enterPIN(app)
        let confirmation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Confirm Passcode"),
                                                     object: app.staticTexts["passcode.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [confirmation], timeout: 8), .completed)
        enterPIN(app)
        // No biometrics are enrolled in this disposable simulator for these
        // tests. The production flow still automatically checks availability.
        app.completeWalletCustomization()
        XCTAssertTrue(app.buttons["home.receive"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.alerts["Passcode set"].exists)
    }

    @MainActor private func enterPIN(_ app: XCUIApplication, digits: [Int] = [2, 9, 4, 8, 1, 6]) {
        for digit in digits { app.buttons["keypad.digit.\(digit)"].tap() }
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func assertWalletGlyphOverArtwork(_ wallet: XCUIElement, in app: XCUIApplication) {
        let screenshot = XCUIScreen.main.screenshot().image.cgImage!
        let scale = CGFloat(screenshot.width) / app.frame.width
        let region = CGRect(x: (wallet.frame.midX - 15) * scale, y: (wallet.frame.midY - 15) * scale,
                            width: 30 * scale, height: 30 * scale)
        let crop = screenshot.cropping(to: region)!
        // Sample at one pixel per point. Only the glyph is white inside the blue glass.
        let side = 30
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        var ink = CGRect.null
        for y in 0..<side {
            for x in 0..<side {
                let i = 4 * (side * y + x)
                if min(pixels[i], pixels[i + 1], pixels[i + 2]) > 200 {
                    ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        XCTAssertEqual(ink.width, 24, accuracy: 1)
        XCTAssertEqual(ink.height, 24, accuracy: 1)
    }

    @MainActor private func screenPixel(x: CGFloat, y: CGFloat) -> (r: Int, g: Int, b: Int) {
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let point = CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y, width: 1, height: 1)
        let pixel = image.cropping(to: point)!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (Int(rgba[0]), Int(rgba[1]), Int(rgba[2]))
    }
}
