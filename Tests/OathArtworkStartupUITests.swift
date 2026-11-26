import XCTest
import UIKit

/// Native welcome artwork and navigation checks.
final class OathArtworkStartupUITests: XCTestCase {
    /// The 27.0 startup check cannot exercise GeometryProxy.reservedRegions.
    /// Verify the newer layout branch without fixed screenshot coordinates,
    /// which differ between the Duo and the ordinary phone simulator.
    @MainActor
    func testOnboardingRemainsResponsiveOnReservedRegionRuntime() throws {
        guard #available(iOS 27.1, *) else { throw XCTSkip("Requires the reserved-region runtime") }
        continueAfterFailure = false
        let app = launch(arguments: [])
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let create = app.buttons["onboarding.createWallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable)
        XCTAssertTrue(app.buttons["onboarding.importWallet"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.consent"].firstMatch.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["onboarding.importWallet"].tap()
        XCTAssertTrue(app.textViews["recovery.phrase"].waitForExistence(timeout: 5))
        // On the Duo, the native Back control lives beside the content rather
        // than inside the top navigation bar. Select its system identifier.
        let back = app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable)
    }

    /// Perspective transforms and native glass compositing need a real render;
    /// arithmetic tests alone cannot prove the logos are visible or clipped.
    @MainActor
    func testWelcomeStreamAndActionsSurviveNavigation() async throws {
        continueAfterFailure = false
        let app = launch(arguments: [])
        defer { app.terminate() }
        let create = app.buttons["onboarding.createWallet"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(create.isHittable)
        XCTAssertTrue(app.buttons["onboarding.importWallet"].isHittable)
        XCTAssertTrue(app.buttons["onboarding.moreOptions"].isHittable)
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.consent"].firstMatch.exists)
        let before = XCUIScreen.main.screenshot()
        attach(before, name: "Welcome chain stream")
        try await Task.sleep(for: .seconds(1.5))
        let after = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(changedArtworkPixels(before, after), 500, "Chain tiles must advance")
        attach(after, name: "Welcome stream advancing")
        app.buttons["onboarding.importWallet"].tap()
        XCTAssertTrue(app.textViews["recovery.phrase"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCTAssertTrue(create.isHittable, "Returning must not replay the opening cover")
        app.buttons["onboarding.moreOptions"].tap()
        XCTAssertTrue(app.buttons["onboarding.restoreICloud"].waitForExistence(timeout: 5))
        app.buttons["options.close"].tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(1))
        let resumed = XCUIScreen.main.screenshot()
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(changedArtworkPixels(resumed, XCUIScreen.main.screenshot()), 500,
                             "The stream resumes after foregrounding")
    }

    @MainActor
    func testReducedMotionWelcomeIsStaticAndUsable() async throws {
        continueAfterFailure = false
        let app = launch(arguments: ["-oath-artwork-reduce-motion"])
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["onboarding.createWallet"].waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(1))
        let before = XCUIScreen.main.screenshot()
        try await Task.sleep(for: .seconds(1))
        XCTAssertLessThan(changedArtworkPixels(before, XCUIScreen.main.screenshot()), 30,
                          "Reduce Motion must stop the perspective animation")
        XCTAssertTrue(app.buttons["onboarding.importWallet"].isHittable)
        XCTAssertTrue(app.buttons["onboarding.moreOptions"].isHittable)
        attach(before, name: "Welcome reduced motion")
    }

    @MainActor private func changedArtworkPixels(_ first: XCUIScreenshot, _ second: XCUIScreenshot) -> Int {
        let a = pixels(first.image), b = pixels(second.image)
        var changed = 0
        // Upper artwork only; exclude status indicators, copy and native controls.
        for y in 75..<260 {
            for x in 15..<285 {
                let offset = (y * 300 + x) * 4
                if (0..<3).contains(where: { abs(Int(a[offset + $0]) - Int(b[offset + $0])) > 12 }) { changed += 1 }
            }
        }
        return changed
    }

    @MainActor private func attach(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launch(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-oath.languagePreference", "en", "-oath-artwork-diagnostics",
                               "-oath.walletTestScope", UUID().uuidString] + arguments
        app.launch()
        return app
    }

    @MainActor
    private func pixels(_ image: UIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 300 * 650 * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 300, height: 650, bitsPerComponent: 8,
                                    bytesPerRow: 300 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: 300, height: 650))
        }
        return bytes
    }
}
