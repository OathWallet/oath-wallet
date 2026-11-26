import Foundation

/// Distances are in points. The recording's 142 pt hold includes the phone's
/// 62 pt top safe area. Only the remaining 80 pt belongs to refresh.
enum WalletRefreshMotion {
    static let hold: CGFloat = 80
    private static let toolbarSpacing: CGFloat = 12
    static let returnDuration: TimeInterval = 0.28
    static let spinnerDiameter: CGFloat = 29
    static let stepDuration: TimeInterval = 0.1
    static let spokeCount = 8

    /// Apply elastic resistance to finger travel in the fixed window. Reading
    /// overscroll from the moving list would feed its own layout back into the pull.
    static func pullDistance(translation: CGFloat, viewport: CGFloat) -> CGFloat {
        guard translation.isFinite, viewport.isFinite, translation > 0, viewport > 0 else { return 0 }
        let resisted = translation * 0.55
        return viewport * resisted / (viewport + resisted)
    }

    static func bandTravel(forPull distance: CGFloat) -> CGFloat {
        guard distance.isFinite, distance > 0 else { return 0 }
        let threshold = RefreshCycle.activationDistance
        return min(distance, threshold) * hold / threshold + max(0, distance - threshold)
    }

    struct Layout {
        let height: CGFloat
        let spinnerY: CGFloat
        let opacity: CGFloat

        init(travel: CGFloat, safeTop: CGFloat) {
            let heldHeight = safeTop + WalletRefreshMotion.hold
            height = travel + safeTop * min(1, travel / WalletRefreshMotion.hold)
            // Before the hold the spokes follow the lower edge. During overpull
            // they travel half as far as that edge, centered in the extra space.
            spinnerY = height - 43.5 - max(0, height - heldHeight) / 2
            opacity = min(1, max(0, (height - heldHeight + 32) / 32))
        }

        /// Consume the space above the resting toolbar before displacing it.
        /// On sheets with little or no top safe area the gap opens continuously.
        func toolbarInset(restingTop: CGFloat) -> CGFloat {
            max(0, height + min(WalletRefreshMotion.toolbarSpacing, height) - restingTop)
        }
    }

    static func travel(forBandHeight height: CGFloat, safeTop: CGFloat) -> CGFloat {
        let heldHeight = hold + safeTop
        return height <= heldHeight ? max(0, height) * hold / heldHeight : height - safeTop
    }

    /// The list can rubber-band this far before the colored edge meets the
    /// toolbar. Beyond contact, both should move by the same displacement.
    static func pullBeforeContact(restingTop: CGFloat, safeTop: CGFloat) -> CGFloat {
        let height = restingTop - min(toolbarSpacing, restingTop / 2)
        let travel = travel(forBandHeight: height, safeTop: safeTop)
        return min(travel, hold) * RefreshCycle.activationDistance / hold + max(0, travel - hold)
    }
}
