import SwiftUI
import UIKit

extension View {
    /// Apply to the NavigationStack that owns the refreshable screens. Its
    /// native toolbar participates in the top inset; bottom bars keep their anchors.
    public func walletRefreshNavigation() -> some View {
        modifier(WalletRefreshNavigation())
    }
}

private struct WalletRefreshHostKey: EnvironmentKey {
    static let defaultValue: WalletRefreshHost? = nil
}

extension EnvironmentValues {
    var walletRefreshHost: WalletRefreshHost? {
        get { self[WalletRefreshHostKey.self] }
        set { self[WalletRefreshHostKey.self] = newValue }
    }
}

private struct WalletRefreshNavigation: ViewModifier {
    @State private var host = WalletRefreshHost()

    func body(content: Content) -> some View {
        content
            .environment(\.walletRefreshHost, host)
            .overlay {
                WalletRefreshCanvas(host: host)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

private struct WalletRefreshCanvas: UIViewRepresentable {
    let host: WalletRefreshHost

    func makeUIView(context: Context) -> WalletRefreshBandView {
        let view = WalletRefreshBandView()
        host.canvas = view
        return view
    }

    func updateUIView(_ view: WalletRefreshBandView, context: Context) {}
}

@MainActor private final class RefreshTopInset {
    private weak var controller: UIViewController?
    private var baseline: CGFloat = 0
    private var lastTop: CGFloat?

    func attach(_ next: UIViewController?) {
        guard controller !== next else { return }
        apply(0)
        controller = next
        baseline = next?.additionalSafeAreaInsets.top ?? 0
        lastTop = nil
    }

    func apply(_ travel: CGFloat) {
        guard let controller else { return }
        var insets = controller.additionalSafeAreaInsets
        if let lastTop, abs(insets.top - lastTop) > 0.001 {
            baseline = insets.top
        }
        let top = baseline + travel
        lastTop = top
        guard abs(insets.top - top) > 0.001 else { return }
        insets.top = top
        controller.additionalSafeAreaInsets = insets
    }

    func layoutIfNeeded() {
        controller?.viewIfLoaded?.layoutIfNeeded()
    }
}

/// UIKit updates a list's automatic top inset from its navigation bar. During
/// a bar animation that inset can still describe the previous bar position.
/// Keep the list's resting insets for the gesture and move its real viewport
/// with the toolbar. Scrolling, cell hit testing and bottom overlays stay native.
@MainActor private struct RefreshListViewport {
    private let scroll: UIScrollView
    private let behavior: UIScrollView.ContentInsetAdjustmentBehavior
    private let originalInset: UIEdgeInsets
    private let restingInset: UIEdgeInsets

    init(_ scroll: UIScrollView) {
        self.scroll = scroll
        behavior = scroll.contentInsetAdjustmentBehavior
        originalInset = scroll.contentInset
        restingInset = scroll.adjustedContentInset
        let offset = scroll.contentOffset
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.contentInset = restingInset
        scroll.contentOffset = offset
    }

    func move(by inset: CGFloat, pull: CGFloat?) {
        // After contact, transfer the existing rubber-band distance into the
        // real inset. Resizing an empty cell or inserting its first assets can
        // then pin the list to the top without discarding any visible travel.
        let top = restingInset.top + inset + (pull ?? 0)
        let previousTop = scroll.contentInset.top
        let topChanged = abs(top - previousTop) > 0.001
        guard topChanged || (pull ?? 0) > 0 else { return }
        let position = pull == nil ? scroll.contentOffset.y + previousTop : 0
        if topChanged { scroll.contentInset.top = top }
        scroll.bounds.origin.y = position - top
    }

    func restore() {
        let position = scroll.contentOffset.y + scroll.adjustedContentInset.top
        scroll.contentInset = originalInset
        scroll.contentInsetAdjustmentBehavior = behavior
        scroll.contentOffset.y = position - scroll.adjustedContentInset.top
    }
}

@MainActor final class WalletRefreshHost {
    weak var canvas: WalletRefreshBandView?
    private weak var owner: UIViewController?
    private weak var scroll: UIScrollView?
    private let barInset = RefreshTopInset()
    private var list: RefreshListViewport?
    private var restingTop: CGFloat = 0
    private var travel: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private var completion: CheckedContinuation<Void, Never>?

    func follow(distance: CGFloat, tint: UIColor, owner sender: UIViewController, scroll: UIScrollView) {
        let offset = WalletRefreshMotion.bandTravel(forPull: distance)
        guard offset > 0 || owner === sender else { return }
        claim(sender, tint: tint, scroll: scroll)
        stopAnimation()
        setTravel(offset, pull: distance)
    }

    func hold(tint: UIColor, owner sender: UIViewController, scroll: UIScrollView) {
        claim(sender, tint: tint, scroll: scroll)
        canvas?.setHolding(true)
        animate(to: WalletRefreshMotion.hold)
    }

    func releasePartial(owner sender: UIViewController) {
        guard owner === sender else { return }
        animate(to: 0)
    }

    func close(owner sender: UIViewController) async {
        guard owner === sender, !Task.isCancelled else { return }
        stopAnimation()
        await withCheckedContinuation { continuation in
            completion = continuation
            animate(to: 0)
        }
    }

    func reset(owner sender: UIViewController) {
        guard owner === sender else { return }
        stopAnimation()
        setTravel(0)
        clearOwner()
    }

    private func claim(_ sender: UIViewController, tint: UIColor, scroll: UIScrollView) {
        if owner !== sender {
            stopAnimation()
            setTravel(0)
            clearOwner()
            barInset.attach(sender.navigationController)
            if let canvas, let bar = sender.navigationController?.navigationBar, !bar.isHidden {
                restingTop = max(0, bar.convert(bar.bounds, to: canvas).minY)
            } else {
                restingTop = canvas?.safeTop ?? 0
            }
            owner = sender
            self.scroll = scroll
        }
        canvas?.setColor(tint)
    }

    private func clearOwner() {
        canvas?.setHolding(false)
        barInset.layoutIfNeeded()
        list?.restore()
        list = nil
        scroll = nil
        barInset.attach(nil)
        owner = nil
    }

    private func setTravel(_ value: CGFloat, pull: CGFloat? = nil) {
        travel = value
        let safeTop = canvas?.safeTop ?? 0
        let layout = WalletRefreshMotion.Layout(travel: value, safeTop: safeTop)
        let inset = layout.toolbarInset(restingTop: restingTop)
        if inset > 0, list == nil, let scroll {
            list = RefreshListViewport(scroll)
        }
        barInset.apply(inset)
        let leadingPull = pull.map { min($0, WalletRefreshMotion.pullBeforeContact(restingTop: restingTop, safeTop: safeTop)) }
        list?.move(by: inset, pull: leadingPull)
        canvas?.setTravel(value, followingPull: pull != nil)
    }

    private func animate(to value: CGFloat) {
        if animator != nil { stopAnimation() }
        barInset.layoutIfNeeded()
        if abs(travel - value) < 0.1 && list == nil {
            setTravel(value)
            finishAnimation()
            return
        }
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.12 : WalletRefreshMotion.returnDuration
        let animation = UIViewPropertyAnimator(duration: duration, curve: .easeInOut) { [weak self] in
            self?.setTravel(value)
            self?.barInset.layoutIfNeeded()
        }
        animation.isUserInteractionEnabled = true
        animation.addCompletion { [weak self, weak animation] _ in
            guard let self, self.animator === animation else { return }
            self.animator = nil
            self.finishAnimation()
        }
        animator = animation
        canvas?.isSettling = true
        animation.startAnimation()
    }

    private func finishAnimation() {
        canvas?.isSettling = false
        if travel == 0 { clearOwner() }
        completeWaiter()
    }

    private func stopAnimation() {
        guard let animation = animator else { return }
        let visible = canvas?.displayedTravel ?? travel
        animator = nil
        animation.stopAnimation(true)
        UIView.performWithoutAnimation {
            setTravel(visible)
            barInset.layoutIfNeeded()
        }
        canvas?.isSettling = false
        completeWaiter()
    }

    private func completeWaiter() {
        completion?.resume()
        completion = nil
    }
}
