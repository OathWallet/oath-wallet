import Foundation

@main struct CheckRefreshPullFeedback {
    static func main() {
        var policy = RefreshPullFeedback()
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); checks += 1
        }
        for (progress, tick) in [(0.0, false), (0.24, false), (0.25, true),
                                 (0.26, false), (0.2, false), (0.25, false),
                                 (0.5, true), (0.74, false), (0.75, true),
                                 (0.99, false), (1.0, false), (1.2, false)] {
            check(policy.update(progress: progress, isDragging: true, eligible: true) == tick,
                  "Each quarter emits once; threshold uses activation feedback")
        }
        for progress in [0.8, 0.6, 0.9, 0.0] {
            check(!policy.update(progress: progress, isDragging: false, eligible: true),
                  "Release and bounce are silent")
        }
        check(policy.update(progress: 0.8, isDragging: true, eligible: true), "Fast pull emits one step")
        check(!policy.update(progress: 0.8, isDragging: true, eligible: true), "No duplicate on layout")
        check(!policy.update(progress: 0, isDragging: true, eligible: true), "Reversing stays silent")
        check(!policy.update(progress: 0.75, isDragging: true, eligible: true), "No jitter retrigger")
        check(!policy.update(progress: 0, isDragging: false, eligible: true), "End cancelled pull")
        check(policy.update(progress: 0.25, isDragging: true, eligible: true), "Next gesture rearms")
        for progress in [0.5, 0.75, 1.0] {
            check(!policy.update(progress: progress, isDragging: true, eligible: false),
                  "Disabled, loading and returning states are silent")
        }
        policy = RefreshPullFeedback()
        for progress in [Double.nan, .infinity, -.infinity, -1] {
            check(!policy.update(progress: progress, isDragging: true, eligible: true), "Invalid input is silent")
        }
        check(!policy.update(progress: 1, isDragging: true, eligible: true), "Fast threshold never doubles activation")
        print("Passed \(checks) pull haptic policy checks on the host.")
    }
}
