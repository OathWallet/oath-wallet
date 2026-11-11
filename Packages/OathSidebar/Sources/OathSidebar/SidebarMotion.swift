import Foundation

/// The final few percent of a spring can take many frames. A landing is felt
/// when the drawer enters the destination edge, once per crossing.
struct SidebarEndpointFeedback {
    private(set) var isOpen = false

    mutating func reachedEndpoint(at progress: Double) -> Bool? {
        guard progress.isFinite else { return nil }
        if isOpen ? progress <= 0.06 : progress >= 0.94 {
            isOpen.toggle()
            return isOpen
        }
        return nil
    }
}

/// Geometry and gesture decisions shared by the UIKit container and host tests.
/// Progress is local to the container: a drag never publishes SwiftUI row state.
public struct SidebarMotion: Equatable, Sendable {
    public private(set) var progress: Double = 0
    public private(set) var targetOpen = false
    public private(set) var isDragging = false
    public private(set) var width: Double = 0
    public private(set) var rightToLeft = false
    private var dragOrigin: Double = 0
    private var dragReturnOpen = false
    private var settledOpen = false

    public init() {}
    // The reference reveals 320 points of a 440-point window. Keep that
    // proportion on compact windows, with a useful maximum on larger ones.
    public static let revealFraction = 8.0 / 11.0
    public static let settlingDuration = 0.4
    public static let exposedCornerRadius = 40.0
    public var sign: Double { rightToLeft ? -1 : 1 }
    public var contentTranslation: Double { contentTranslation(at: progress) }
    public var sidebarScale: Double { sidebarScale(at: progress) }

    public func contentTranslation(at progress: Double) -> Double {
        sign * width * progress
    }

    // The rear plane stays in place; it approaches at a small scale instead of
    // sliding alongside the foreground like a navigation push.
    public func sidebarScale(at progress: Double) -> Double { 0.97 + 0.03 * progress }
    public func sidebarOpacity(at progress: Double) -> Double { 0.5 + 0.5 * progress }
    public func contentVeilOpacity(at progress: Double) -> Double { 0.5 * progress }

    /// UIKit spring velocity is points/second divided by the remaining travel,
    /// not by the full drawer width. Keep a near-complete flick from producing
    /// an extreme spring velocity, and use no momentum for cancelled gestures.
    public func springVelocity(velocityX: Double, opening: Bool) -> Double {
        let distance = contentTranslation(at: opening ? 1 : 0) - contentTranslation
        guard velocityX.isFinite, abs(distance) >= 1 else { return 0 }
        return min(12, max(-12, velocityX / distance))
    }

    public mutating func resize(windowWidth: Double, rightToLeft: Bool) {
        width = min(max(0, windowWidth.isFinite ? windowWidth : 0) * Self.revealFraction, 360)
        self.rightToLeft = rightToLeft
    }

    public static func canBegin(velocityX: Double, velocityY: Double, rightToLeft: Bool,
                                isOpen: Bool, allowed: Bool, nativeBack: Bool,
                                protectedControl: Bool, transitioning: Bool = false) -> Bool {
        guard allowed, !protectedControl, abs(velocityX) > 20,
              abs(velocityX) > abs(velocityY) * 1.5 else { return false }
        let leadingVelocity = velocityX * (rightToLeft ? -1 : 1)
        if isOpen && transitioning { return true }
        return isOpen ? leadingVelocity < 0 : (!nativeBack && leadingVelocity > 0)
    }

    public mutating func capture(progress: Double) {
        self.progress = min(1, max(0, progress.isFinite ? progress : 0))
    }

    public mutating func request(open: Bool) { targetOpen = open }

    public mutating func beginDrag() {
        dragOrigin = progress
        dragReturnOpen = targetOpen
        isDragging = true
    }

    public mutating func drag(translationX: Double) {
        guard isDragging, width > 0 else { return }
        capture(progress: dragOrigin + sign * translationX / width)
    }

    @discardableResult public mutating func endDrag(velocityX: Double, cancelled: Bool) -> Bool {
        guard isDragging else { return targetOpen }
        isDragging = false
        let velocity = velocityX * sign
        targetOpen = cancelled ? dragReturnOpen :
            (abs(velocity) > 450 ? velocity > 0 : progress >= 0.5)
        return targetOpen
    }

    /// Returns true once when a transition finishes at a different endpoint.
    @discardableResult public mutating func settle() -> Bool {
        progress = targetOpen ? 1 : 0
        isDragging = false
        let changed = settledOpen != targetOpen
        settledOpen = targetOpen
        return changed
    }

    public mutating func reset() {
        request(open: false)
        settle()
    }
}
