/// Eligibility is fixed for the entire pan. Crossing the top while returning
/// from lower content is navigation, not a new pull-to-refresh gesture.
struct RefreshPullGesture {
    private var previousPosition: Double?
    private var wasPanning = false
    private(set) var allowsRefresh = false

    /// Position is contentOffset.y + the resting adjusted top inset. Observe
    /// idle/decelerating offsets too: UIKit can move content before the first
    /// `.began` callback, so that callback must use the preceding position.
    mutating func observe(position: Double, isPanning: Bool) {
        if isPanning { beginPan() } else { endPan(at: position) }
    }

    mutating func beginPan() {
        guard !wasPanning else { return }
        allowsRefresh = previousPosition.map { $0.isFinite && $0 <= 1 } ?? false
        wasPanning = true
    }

    mutating func endPan(at position: Double) {
        previousPosition = position
        wasPanning = false
    }
}
