import XCTest
import SwiftUI
@testable import OathSidebar

final class SidebarMotionTests: XCTestCase {
    @MainActor func testDrawerInputCoalescesWithoutRepublishingFront() async {
        let hosts = SidebarHosts()
        let home = SidebarHostedRoot(source: hosts.front, initial: AnyView(Text("Home")))
        let drawer = SidebarHostedRoot(source: hosts.drawer, initial: AnyView(Text("Wallets")))
        var frontChanges = 0, drawerChanges = 0
        let frontSubscription = home.source.objectWillChange.sink { frontChanges += 1 }
        let drawerSubscription = drawer.source.objectWillChange.sink { drawerChanges += 1 }
        hosts.drawer.submit(AnyView(Text("$1.00")))
        hosts.drawer.submit(AnyView(Text("$2.00")))
        XCTAssertEqual(drawerChanges, 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(drawerChanges, 1)
        XCTAssertEqual(frontChanges, 0)
        XCTAssertTrue(home.source === hosts.front && drawer.source === hosts.drawer)
        withExtendedLifetime((frontSubscription, drawerSubscription)) {}
    }

    func testImpactDuringDragBeforeReleaseInBothDirections() {
        for rtl in [false, true] {
            var motion = SidebarMotion()
            var feedback = SidebarEndpointFeedback()
            motion.resize(windowWidth: 440, rightToLeft: rtl)
            let fullDrag = motion.sign * motion.width
            motion.beginDrag()
            motion.drag(translationX: 0.5 * fullDrag)
            XCTAssertNil(feedback.reachedEndpoint(at: motion.progress))
            motion.drag(translationX: 0.95 * fullDrag)
            XCTAssertTrue(motion.isDragging)
            XCTAssertEqual(feedback.reachedEndpoint(at: motion.progress), true)
            motion.endDrag(velocityX: 0, cancelled: false)
            motion.settle()
            XCTAssertNil(feedback.reachedEndpoint(at: motion.progress))

            motion.beginDrag()
            motion.drag(translationX: -0.96 * fullDrag)
            XCTAssertTrue(motion.isDragging)
            XCTAssertEqual(feedback.reachedEndpoint(at: motion.progress), false)
            motion.endDrag(velocityX: 0, cancelled: false)
            motion.settle()
            XCTAssertNil(feedback.reachedEndpoint(at: motion.progress))
        }
    }

    func testSpringCrossingsReversalsAndInstantTransitions() {
        var feedback = SidebarEndpointFeedback()
        // A partial reveal returns to its origin without landing on the open edge.
        for position in [0.0, 0.4, 0.81, 0.5, 0.0] {
            XCTAssertNil(feedback.reachedEndpoint(at: position))
        }
        XCTAssertEqual(feedback.reachedEndpoint(at: 0.95), true)
        // Rounding, spring overshoot, interruption and re-entry at the same edge.
        for position in [0.97, 1.01, 1.0, 0.7, 0.98, 0.3] {
            XCTAssertNil(feedback.reachedEndpoint(at: position))
        }
        XCTAssertEqual(feedback.reachedEndpoint(at: 0.05), false)
        XCTAssertNil(feedback.reachedEndpoint(at: 0))
        // Reduce Motion or a missed display frame can jump directly to the endpoint.
        XCTAssertEqual(feedback.reachedEndpoint(at: 1), true)
        XCTAssertNil(feedback.reachedEndpoint(at: 1))
        // A silent lifecycle reset synchronizes the next opening.
        feedback = SidebarEndpointFeedback(isOpen: false)
        XCTAssertNil(feedback.reachedEndpoint(at: .nan))
        XCTAssertEqual(feedback.reachedEndpoint(at: 1), true)
    }

    func testOnlyChangesOfSettledEndpointReportCompletion() {
        for rtl in [false, true] {
            var motion = SidebarMotion()
            motion.resize(windowWidth: 440, rightToLeft: rtl)
            let direction = rtl ? -1.0 : 1.0
            XCTAssertFalse(motion.settle(), "Initial closed layout")

            motion.beginDrag()
            motion.drag(translationX: direction * 250)
            motion.endDrag(velocityX: 0, cancelled: true)
            XCTAssertFalse(motion.settle(), "Cancelled opening")

            motion.request(open: true)
            motion.capture(progress: 0.7)
            motion.request(open: false)
            XCTAssertFalse(motion.settle(), "Reversal before opening finished")

            motion.beginDrag()
            motion.drag(translationX: direction * 320)
            motion.endDrag(velocityX: 0, cancelled: false)
            XCTAssertTrue(motion.settle(), "Fully opened by swipe")
            motion.resize(windowWidth: 390, rightToLeft: rtl)
            XCTAssertFalse(motion.settle(), "Already open after resizing")

            motion.beginDrag()
            motion.drag(translationX: -direction * 280)
            motion.endDrag(velocityX: 0, cancelled: true)
            XCTAssertFalse(motion.settle(), "Cancelled closing")
            motion.request(open: false)
            XCTAssertTrue(motion.settle(), "Fully closed by button")
            XCTAssertFalse(motion.settle(), "Repeated close")
            motion.request(open: true)
            XCTAssertTrue(motion.settle(), "Can reopen immediately, including with Reduce Motion")
            motion.reset()
            XCTAssertFalse(motion.settle(), "Reset does not leave a pending close")
        }
    }

    func testOpeningClosingAndCancelledDrag() {
        var motion = SidebarMotion()
        motion.resize(windowWidth: 440, rightToLeft: false)
        XCTAssertEqual(motion.width, 320)
        motion.beginDrag(); motion.drag(translationX: 200)
        XCTAssertEqual(motion.progress, 0.625)
        XCTAssertTrue(motion.endDrag(velocityX: 0, cancelled: false))
        motion.settle()
        XCTAssertEqual(motion.contentTranslation, 320)
        motion.beginDrag(); motion.drag(translationX: -250)
        XCTAssertTrue(motion.endDrag(velocityX: -900, cancelled: true))
        motion.settle()
        XCTAssertEqual(motion.progress, 1)
        motion.beginDrag(); motion.drag(translationX: -20)
        XCTAssertFalse(motion.endDrag(velocityX: -600, cancelled: false))
        motion.settle()
        XCTAssertEqual(motion.progress, 0)
    }

    func testRTLResizeAndProgressBounds() {
        var motion = SidebarMotion()
        motion.resize(windowWidth: 440, rightToLeft: true)
        motion.beginDrag(); motion.drag(translationX: -160)
        XCTAssertEqual(motion.progress, 0.5)
        XCTAssertEqual(motion.contentTranslation, -160)
        XCTAssertEqual(motion.sidebarScale, 0.985, accuracy: 0.001)
        motion.resize(windowWidth: 1024, rightToLeft: true)
        XCTAssertEqual(motion.width, 360)
        XCTAssertEqual(motion.contentTranslation, -180)
        motion.drag(translationX: -900)
        XCTAssertEqual(motion.progress, 1)
        motion.drag(translationX: 900)
        XCTAssertEqual(motion.progress, 0)
        motion.capture(progress: .nan)
        XCTAssertEqual(motion.progress, 0)
        motion.resize(windowWidth: -20, rightToLeft: false)
        XCTAssertEqual(motion.width, 0)
        motion.resize(windowWidth: .infinity, rightToLeft: false)
        XCTAssertEqual(motion.width, 0)
        motion.reset()
        XCTAssertFalse(motion.isDragging)
    }

    func testInterruptedAnimationCanReverseWithoutJumping() {
        var motion = SidebarMotion()
        motion.resize(windowWidth: 440, rightToLeft: false)
        motion.request(open: true)
        motion.capture(progress: 0.4)
        motion.beginDrag(); motion.drag(translationX: -64)
        XCTAssertEqual(motion.progress, 0.2, accuracy: 0.001)
        XCTAssertFalse(motion.endDrag(velocityX: -500, cancelled: false))
        motion.capture(progress: 0.1)
        motion.beginDrag(); motion.drag(translationX: 64)
        XCTAssertEqual(motion.progress, 0.3, accuracy: 0.001)
        XCTAssertTrue(motion.endDrag(velocityX: 500, cancelled: false))
        motion.settle()
        XCTAssertEqual(motion.progress, 1)
    }

    func testGestureEligibilityProtectsScrollingControlsAndBack() {
        func begin(_ x: Double, _ y: Double = 0, rtl: Bool = false, open: Bool = false,
                   allowed: Bool = true, back: Bool = false, control: Bool = false, transitioning: Bool = false) -> Bool {
            SidebarMotion.canBegin(velocityX: x, velocityY: y, rightToLeft: rtl,
                isOpen: open, allowed: allowed, nativeBack: back, protectedControl: control, transitioning: transitioning)
        }
        XCTAssertTrue(begin(200))
        XCTAssertFalse(begin(-200))
        XCTAssertTrue(begin(-200, rtl: true))
        XCTAssertFalse(begin(200, rtl: true))
        XCTAssertFalse(begin(200, 190))
        XCTAssertFalse(begin(10))
        XCTAssertFalse(begin(200, back: true))
        XCTAssertFalse(begin(200, control: true))
        XCTAssertFalse(begin(200, allowed: false))
        XCTAssertTrue(begin(-200, open: true, back: true))
        XCTAssertTrue(begin(200, rtl: true, open: true))
        XCTAssertTrue(begin(200, open: true, transitioning: true))
        XCTAssertTrue(begin(-200, open: true, transitioning: true))
        XCTAssertFalse(begin(10, 200, open: true, transitioning: true))
    }

    func testSidebarRevealsBeneathScreenAndMirrorsInRTL() {
        for rtl in [false, true] {
            var motion = SidebarMotion()
            motion.resize(windowWidth: 440, rightToLeft: rtl)
            let sign = rtl ? -1.0 : 1.0
            for progress in [0.0, 0.25, 0.5, 0.75, 1] {
                motion.capture(progress: progress)
                XCTAssertEqual(motion.contentTranslation, sign * 320 * progress, accuracy: 0.001)
                XCTAssertEqual(motion.sidebarScale, 0.97 + 0.03 * progress, accuracy: 0.001)
                XCTAssertEqual(motion.sidebarOpacity(at: progress), 0.5 + 0.5 * progress)
                XCTAssertEqual(motion.contentVeilOpacity(at: progress), 0.5 * progress)
            }
            motion.reset()
            XCTAssertEqual(motion.contentTranslation, 0)
            motion.resize(windowWidth: 200, rightToLeft: rtl)
            XCTAssertEqual(motion.width, 200 * 8 / 11, accuracy: 0.001)
            XCTAssertEqual(motion.sidebarScale, 0.97, accuracy: 0.001)
        }
    }

    func testSpringCarriesReleaseVelocityInBothDirections() {
        for rtl in [false, true] {
            var motion = SidebarMotion()
            motion.resize(windowWidth: 440, rightToLeft: rtl)
            motion.capture(progress: 0.25)
            let sign = rtl ? -1.0 : 1.0
            XCTAssertEqual(motion.springVelocity(velocityX: sign * 480, opening: true), 2)
            XCTAssertEqual(motion.springVelocity(velocityX: -sign * 400, opening: false), 5)
            // A slow drag that hasn't crossed the threshold can settle back
            // against the last finger velocity; the signed velocity is retained.
            XCTAssertEqual(motion.springVelocity(velocityX: sign * 80, opening: false), -1)
            XCTAssertEqual(motion.springVelocity(velocityX: 0, opening: true), 0)
            XCTAssertEqual(motion.springVelocity(velocityX: .infinity, opening: true), 0)
            XCTAssertEqual(motion.springVelocity(velocityX: .nan, opening: false), 0)
            XCTAssertEqual(motion.springVelocity(velocityX: sign * 999_999, opening: true), 12)
            motion.capture(progress: 0.999)
            XCTAssertEqual(motion.springVelocity(velocityX: sign * 800, opening: true), 0)
            motion.settle()
            XCTAssertEqual(motion.springVelocity(velocityX: 200, opening: false), 0)
        }
    }
}
