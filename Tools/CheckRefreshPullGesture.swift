import Foundation

@main struct CheckRefreshPullGesture {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        for initialPosition in [2.0, 40, 180, 1_500, 50_000] {
            var gate = RefreshPullGesture()
            var cycle = RefreshCycle()
            var feedback = RefreshPullFeedback()
            gate.observe(position: initialPosition, isPanning: false)
            for position in [initialPosition, 0, -12, -24, -48, -120, 20, -90] {
                gate.observe(position: position, isPanning: true)
                check(!gate.allowsRefresh, "Returning to the top cannot rearm within the same swipe")
                cycle.pull(distance: -position, isDragging: gate.allowsRefresh,
                           activationDistance: RefreshCycle.activationDistance)
                check(cycle.phase == .idle, "Navigation never fills or starts the ring")
                check(!feedback.update(progress: cycle.progress, isDragging: true, eligible: gate.allowsRefresh), "Navigation emits no pull ticks")
            }
            for position in [-80.0, -20, 0] {
                gate.observe(position: position, isPanning: false)
                check(!gate.allowsRefresh, "Release and rebound cannot authorize a native refresh event")
            }
            gate.observe(position: -15, isPanning: true)
            check(gate.allowsRefresh, "A fresh swipe at the top can refresh")
            cycle.pull(distance: 72, isDragging: gate.allowsRefresh, activationDistance: RefreshCycle.activationDistance)
            check(gate.allowsRefresh && cycle.begin(), "Next intentional pull starts normally")
        }
        for position in [0.0, 0.5, 1, -10] {
            var gate = RefreshPullGesture()
            gate.observe(position: position, isPanning: false)
            gate.observe(position: -60, isPanning: true)
            check(gate.allowsRefresh, "Top and top-edge rounding allow an intentional pull")
            gate.observe(position: -70, isPanning: false)
            check(gate.allowsRefresh, "Release callback retains this gesture's eligibility")
        }
        var gate = RefreshPullGesture()
        gate.observe(position: -100, isPanning: true)
        check(!gate.allowsRefresh, "Attaching mid-gesture without a starting sample is conservative")
        gate.observe(position: .nan, isPanning: false)
        gate.observe(position: -100, isPanning: true)
        check(!gate.allowsRefresh, "Invalid starting geometry never authorizes refresh")
        gate = RefreshPullGesture()
        gate.observe(position: 0, isPanning: false)
        gate.observe(position: 200, isPanning: false)
        gate.observe(position: -70, isPanning: true)
        check(!gate.allowsRefresh, "A drag interrupting deceleration uses the latest position")
        gate.endPan(at: 200)
        gate.beginPan()
        gate.observe(position: -100, isPanning: true)
        gate.beginPan() // KVO and target delivery can arrive in either order.
        check(!gate.allowsRefresh, "Crossing the top before the pan target cannot arm a navigation gesture")
        gate.endPan(at: 0) // An end/cancel can arrive without a final offset.
        gate.beginPan()
        check(gate.allowsRefresh, "A stationary release reseeds the next drag")
        print("Passed \(checks) gesture-origin and ring integration checks on the host.")
    }
}
