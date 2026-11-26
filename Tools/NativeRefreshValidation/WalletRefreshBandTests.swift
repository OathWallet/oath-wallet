import QuartzCore
import XCTest
@testable import RefreshActionCore

final class WalletRefreshBandTests: XCTestCase {
    func testRecordedTravelAndSpinnerGeometry() {
        let pull = WalletRefreshMotion.bandTravel(forPull:)
        XCTAssertEqual(WalletRefreshMotion.pullDistance(translation: 200, viewport: 0), 0)
        XCTAssertEqual(WalletRefreshMotion.pullDistance(translation: -25, viewport: 800), 0)
        XCTAssertEqual(WalletRefreshMotion.pullDistance(translation: .infinity, viewport: 800), 0)
        XCTAssertEqual(WalletRefreshMotion.pullDistance(translation: 200, viewport: 800), 96.70, accuracy: 0.02)
        XCTAssertEqual(pull(-4), 0)
        XCTAssertEqual(pull(.nan), 0)
        XCTAssertEqual(pull(48), 40)
        XCTAssertEqual(pull(96), 80)
        let held = WalletRefreshMotion.Layout(travel: pull(96), safeTop: 62)
        XCTAssertEqual(held.height, 142)
        XCTAssertEqual(held.spinnerY, 98.5)
        let peak = WalletRefreshMotion.Layout(travel: pull(127), safeTop: 62)
        XCTAssertEqual(peak.height, 173)
        XCTAssertEqual(peak.spinnerY, 114)
        let sheet = WalletRefreshMotion.Layout(travel: 80, safeTop: 0)
        XCTAssertEqual(sheet.height, 80)
        XCTAssertEqual(WalletRefreshMotion.Layout(travel: 0, safeTop: 62).height, 0)
        XCTAssertEqual(WalletRefreshMotion.Layout(travel: 18, safeTop: 62).opacity, 0)
        XCTAssertEqual(held.opacity, 1)
    }

    func testPullUsesExistingSpaceBeforeMovingTheToolbar() {
        for restingTop: CGFloat in [47, 62, 77] {
            let contact = restingTop - 12
            let pull = WalletRefreshMotion.pullBeforeContact(restingTop: restingTop, safeTop: 62)
            let atContact = WalletRefreshMotion.Layout(travel: WalletRefreshMotion.bandTravel(forPull: pull), safeTop: 62)
            XCTAssertEqual(atContact.height, contact, accuracy: 0.001)
            for height in [0, 12, contact - 1, contact, contact + 1, 142, 175] as [CGFloat] {
                let travel = WalletRefreshMotion.travel(forBandHeight: height, safeTop: 62)
                let layout = WalletRefreshMotion.Layout(travel: travel, safeTop: 62)
                XCTAssertEqual(layout.height, height, accuracy: 0.001)
                XCTAssertEqual(layout.toolbarInset(restingTop: restingTop),
                               max(0, height - contact), accuracy: 0.001)
            }
        }
    }

    func testSheetToolbarOpensWithoutAnInitialJump() {
        for top: CGFloat in [0, 8, 20, 40, 150] {
            let contact = WalletRefreshMotion.pullBeforeContact(restingTop: top, safeTop: 0)
            let travel = WalletRefreshMotion.bandTravel(forPull: contact)
            let band = WalletRefreshMotion.Layout(travel: travel, safeTop: 0)
            XCTAssertEqual(band.height + min(band.height, 12), top, accuracy: 0.001)
        }
        for height: CGFloat in [0, 1, 6, 12, 80, 111] {
            let layout = WalletRefreshMotion.Layout(travel: height, safeTop: 0)
            XCTAssertEqual(layout.toolbarInset(restingTop: 0), height + min(height, 12))
        }
    }

    func testNativeReturnDurationAndSpinnerCadence() {
        XCTAssertEqual(NativeRefreshTiming.walletBand.duration, .milliseconds(3500))
        XCTAssertEqual(WalletRefreshMotion.returnDuration, 0.28)
        XCTAssertEqual(WalletRefreshMotion.spokeCount, 8)
        XCTAssertEqual(WalletRefreshMotion.stepDuration, 0.1)
        XCTAssertEqual(WalletRefreshMotion.spinnerDiameter, 29)
    }

    @MainActor func testAuroraUsesTheWalletPaletteAndContrastingInk() async throws {
        let base = CAGradientLayer(), cool = CAGradientLayer(), warm = CAGradientLayer()
        let aurora = WalletRefreshAurora(base: base, cool: cool, warm: warm)
        func assertStops(_ layer: CAGradientLayer, rgb: [[Int]], alpha: [CGFloat]) throws {
            let colors = try XCTUnwrap(layer.colors as? [CGColor])
            XCTAssertEqual(colors.count, rgb.count)
            for ((color, expected), opacity) in zip(zip(colors, rgb), alpha) {
                let components = try XCTUnwrap(color.components)
                XCTAssertEqual(components.count, 4)
                for (actual, wanted) in zip(components, expected) {
                    XCTAssertEqual(actual, CGFloat(wanted) / 255, accuracy: 1.1 / 255)
                }
                XCTAssertEqual(color.alpha, opacity, accuracy: 0.001)
            }
        }
        let poolOpacity: [CGFloat] = [1, 0.89, 0.35, 0]
        let blueInk = aurora.setColor(red: 36 / 255, green: 77 / 255, blue: 224 / 255)
        XCTAssertEqual(blueInk.components?.first, 1)
        try assertStops(base, rgb: [[26, 52, 183], [36, 77, 224], [21, 29, 147]], alpha: [1, 1, 1])
        try assertStops(cool, rgb: Array(repeating: [6, 128, 137], count: 4), alpha: poolOpacity)
        try assertStops(warm, rgb: Array(repeating: [117, 32, 236], count: 4), alpha: poolOpacity)
        XCTAssertEqual(cool.type, .radial)
        XCTAssertEqual(warm.type, .radial)

        let yellowInk = aurora.setColor(red: 1, green: 218 / 255, blue: 89 / 255)
        XCTAssertEqual(yellowInk.components?.first, 0)
        try assertStops(base, rgb: [[255, 217, 38], [255, 218, 89], [252, 234, 0]], alpha: [1, 1, 1])
        try assertStops(cool, rgb: Array(repeating: [255, 87, 76], count: 4), alpha: poolOpacity)
        try assertStops(warm, rgb: Array(repeating: [190, 255, 97], count: 4), alpha: poolOpacity)
    }

    @MainActor func testAuroraFollowsPullThenDriftsAndRespectsReduceMotion() async throws {
        let cool = CAGradientLayer(), warm = CAGradientLayer()
        let aurora = WalletRefreshAurora(base: CAGradientLayer(), cool: cool, warm: warm)
        aurora.update(pullFraction: 0.25, holding: false, motionAllowed: true)
        let earlyCenter = cool.startPoint
        aurora.update(pullFraction: 1, holding: false, motionAllowed: true)
        XCTAssertNotEqual(cool.startPoint, earlyCenter)
        XCTAssertNil(cool.animation(forKey: "startPoint"))
        aurora.update(pullFraction: 1, holding: true, motionAllowed: true)
        for layer in [cool, warm] {
            let motion = try XCTUnwrap(layer.animation(forKey: "startPoint") as? CAKeyframeAnimation)
            let extent = try XCTUnwrap(layer.animation(forKey: "endPoint") as? CAKeyframeAnimation)
            let centers = try XCTUnwrap(motion.values as? [CGPoint])
            let ends = try XCTUnwrap(extent.values as? [CGPoint])
            let first = try XCTUnwrap(centers.first), last = try XCTUnwrap(centers.last)
            XCTAssertEqual(first, layer.startPoint)
            XCTAssertEqual(first.x, last.x, accuracy: 0.0001)
            XCTAssertEqual(first.y, last.y, accuracy: 0.0001)
            let x = centers.map(\.x)
            XCTAssertGreaterThan(try XCTUnwrap(x.max()) - XCTUnwrap(x.min()), 0.4)
            XCTAssertEqual(motion.duration, 2 / 0.74, accuracy: 0.0001)
            XCTAssertEqual(motion.beginTime, extent.beginTime)
            XCTAssertEqual(centers.count, ends.count)
            for (center, end) in zip(centers, ends) {
                XCTAssertEqual(end.x - center.x, layer.endPoint.x - first.x, accuracy: 0.0001)
                XCTAssertEqual(end.y - center.y, layer.endPoint.y - first.y, accuracy: 0.0001)
            }
        }
        aurora.update(pullFraction: 1, holding: true, motionAllowed: false)
        let still = cool.startPoint
        aurora.update(pullFraction: 0.2, holding: false, motionAllowed: false)
        XCTAssertEqual(cool.startPoint, still)
        XCTAssertNil(cool.animation(forKey: "startPoint"))
        XCTAssertNil(warm.animation(forKey: "endPoint"))
        aurora.update(pullFraction: 1, holding: true, motionAllowed: true)
        aurora.update(pullFraction: 0, holding: false, motionAllowed: true)
        XCTAssertNil(warm.animation(forKey: "startPoint"))
        XCTAssertNil(cool.animation(forKey: "endPoint"))
    }
}
