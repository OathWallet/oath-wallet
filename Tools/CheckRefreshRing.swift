import Foundation

@main struct CheckRefreshRing {
    static func main() {
        var checks = 0
        func check(_ result: Bool, _ message: String) {
            precondition(result, message); checks += 1
        }
        var cycle = RefreshCycle()
        for distance in [0.0, 18, 36, 48, 54, 71.9] {
            cycle.pull(distance: distance, isDragging: true, activationDistance: RefreshCycle.activationDistance)
            check(abs(cycle.progress - distance / RefreshCycle.activationDistance) < 0.0001, "Stroke follows the pull distance")
            check(!cycle.beginIfFilled(isDragging: true, eligible: true), "Incomplete ring never refreshes")
        }
        cycle.pull(distance: 0, isDragging: false, activationDistance: RefreshCycle.activationDistance)
        check(cycle.phase == .idle, "Short pull cancels cleanly")
        cycle.pull(distance: 96, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        check(cycle.progress == 1, "Ring is full at exactly 96 points")
        check(!cycle.beginIfFilled(isDragging: false, eligible: true), "Rebound cannot activate a full ring")
        check(!cycle.beginIfFilled(isDragging: true, eligible: false), "Navigation cannot activate a full ring")
        check(cycle.beginIfFilled(isDragging: true, eligible: true), "Full ring starts without further travel or release")
        for distance in [120.0, 96, 40, 0, 150] {
            cycle.pull(distance: distance, isDragging: true, activationDistance: RefreshCycle.activationDistance)
            check(cycle.phase == .refreshing, "Holding or reversing retains the native request")
            check(!cycle.begin(), "Native release cannot duplicate the threshold request")
            check(!cycle.beginIfFilled(isDragging: true, eligible: true), "Held ring cannot duplicate activation")
        }
        cycle.complete(succeeded: true)
        cycle.returnToRest()
        cycle.pull(distance: 0, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        check(cycle.isReturning, "Completion stays latched while finger remains down")
        cycle.pull(distance: 150, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        check(cycle.phase != .refreshing, "A held gesture cannot rearm after completion")
        cycle.pull(distance: 0, isDragging: false, activationDistance: RefreshCycle.activationDistance)
        check(cycle.phase == .idle, "Rest rearms the next gesture")
        cycle.pull(distance: 180, isDragging: false, activationDistance: RefreshCycle.activationDistance)
        check(cycle.phase == .idle, "Bounce cannot refresh")
        cycle.pull(distance: .nan, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        cycle.pull(distance: .infinity, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        check(cycle.phase == .idle, "Invalid geometry cannot arm the ring")
        cycle.pull(distance: 200, isDragging: true, activationDistance: RefreshCycle.activationDistance)
        check(cycle.progress == 1 && cycle.beginIfFilled(isDragging: true, eligible: true), "Fast pulls clamp and activate once")
        cycle.complete(succeeded: false)
        check(cycle.phase == .failed, "Failure retains its true outcome")
        cycle.reset()
        check(cycle.begin(), "VoiceOver can refresh without a drag")
        print("Passed \(checks) progress-ring lifecycle checks on the host.")
    }
}
