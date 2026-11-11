#if canImport(UIKit)
import SwiftUI
import UIKit

public enum SidebarFeedback {
    case prepare(open: Bool)
    case impact(open: Bool)
}

/// Public UIKit containment keeps both SwiftUI trees mounted. Only their root
/// transforms change while dragging. Wallet data and routes belong to the app.
public struct SidebarContainer<Content: View, Sidebar: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.locale) private var locale
    @Environment(\.openURL) private var openURL
    @State private var hosts = SidebarHosts()
    private let content: Content
    private let sidebar: Sidebar
    private let configuration: SidebarConfiguration

    public init(isPresented: Binding<Bool>, isEnabled: Bool = true, allowsOpeningSwipe: Bool = true,
                closeLabel: String, onWillOpen: @escaping () -> Void = {},
                onFeedback: @escaping (SidebarFeedback) -> Void = { _ in },
                onSettled: @escaping (Bool) -> Void = { _ in },
                onDismiss: @escaping () -> Void = {},
                @ViewBuilder content: () -> Content, @ViewBuilder sidebar: () -> Sidebar) {
        self.content = content()
        self.sidebar = sidebar()
        configuration = SidebarConfiguration(isPresented: isPresented, isEnabled: isEnabled,
            allowsOpeningSwipe: allowsOpeningSwipe, closeLabel: closeLabel, onWillOpen: onWillOpen,
            onFeedback: onFeedback, onSettled: onSettled, onDismiss: onDismiss)
    }

    public var body: some View {
        // The outer host must span the screen: an inset UIKit host clips child
        // backgrounds and tells its children that the system insets are zero.
        // The child hosting controllers own native safe-area and keyboard
        // avoidance. Resizing this outer bridge for the keyboard as well would
        // apply that adjustment twice and lift the search toolbar too far.
        let front = forwardEnvironment(to: content)
        let drawer = forwardEnvironment(to: sidebar)
        SidebarControllerBridge(hosts: hosts, configuration: configuration,
                                initialFront: { AnyView(front) }, initialDrawer: { AnyView(drawer) })
            .ignoresSafeArea(.all)
            .background {
                // Independent SwiftUI inputs. An endpoint or gesture configuration update
                // doesn't supply new content to either hosting controller.
                ZStack {
                    SidebarHostInput(source: hosts.front, content: front)
                    SidebarHostInput(source: hosts.drawer, content: drawer)
                }
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
    }

    private func forwardEnvironment<V: View>(to child: V) -> some View {
        // Each hosting controller owns its native appearance and presentation.
        // Bridge the owning scene and the caller's interaction and language choices.
        child
            .environment(\.scenePhase, scenePhase)
            .disabled(!isEnabled)
            .environment(\.layoutDirection, layoutDirection)
            .environment(\.locale, locale)
            .environment(\.openURL, openURL)
    }
}

/// The hosting roots and their native navigation controllers live for the entire
/// presentation. SwiftUI updates each subtree's value/environment at its own boundary.
private struct SidebarHostInput<Content: View>: UIViewRepresentable {
    let source: SidebarHostSource
    let content: Content

    func makeUIView(context: Context) -> UIView {
        let placeholder = UIView(frame: .zero)
        placeholder.isUserInteractionEnabled = false
        placeholder.accessibilityElementsHidden = true
        return placeholder
    }
    func updateUIView(_ view: UIView, context: Context) {
        source.submit(AnyView(content))
    }
}

private struct SidebarConfiguration {
    @Binding var isPresented: Bool
    let isEnabled: Bool
    let allowsOpeningSwipe: Bool
    let closeLabel: String
    let onWillOpen: () -> Void
    let onFeedback: (SidebarFeedback) -> Void
    let onSettled: (Bool) -> Void
    let onDismiss: () -> Void
}

private struct SidebarControllerBridge: UIViewControllerRepresentable {
    let hosts: SidebarHosts
    let configuration: SidebarConfiguration
    let initialFront: () -> AnyView
    let initialDrawer: () -> AnyView
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func makeUIViewController(context: Context) -> SidebarViewController {
        let controller = SidebarViewController(
            content: AnyView(SidebarHostedRoot(source: hosts.front, initial: initialFront())),
            sidebar: AnyView(SidebarHostedRoot(source: hosts.drawer, initial: initialDrawer())))
        configure(controller)
        return controller
    }

    func updateUIViewController(_ controller: SidebarViewController, context: Context) {
        configure(controller)
        controller.scheduleUpdate(open: configuration.isPresented)
    }

    private func configure(_ controller: SidebarViewController) {
        controller.enabled = configuration.isEnabled
        controller.allowsOpeningSwipe = configuration.allowsOpeningSwipe
        controller.rightToLeft = direction == .rightToLeft
        controller.reduceMotion = reduceMotion
        controller.increasedContrast = contrast == .increased
        controller.closeLabel = configuration.closeLabel
        controller.onWillOpen = configuration.onWillOpen
        controller.onFeedback = configuration.onFeedback
        controller.onSettled = configuration.onSettled
        controller.onChange = { configuration.isPresented = $0 }
        controller.onDismiss = configuration.onDismiss
    }

    static func dismantleUIViewController(_ controller: SidebarViewController, coordinator: ()) {
        controller.tearDown()
    }
}

@MainActor public final class SidebarViewController: UIViewController, UIGestureRecognizerDelegate {
    fileprivate let content: UIHostingController<AnyView>
    fileprivate let sidebar: UIHostingController<AnyView>
    fileprivate var enabled = true
    fileprivate var allowsOpeningSwipe = true
    fileprivate var rightToLeft = false
    fileprivate var reduceMotion = false
    fileprivate var increasedContrast = false
    fileprivate var closeLabel = ""
    fileprivate var onWillOpen: () -> Void = {}
    fileprivate var onFeedback: (SidebarFeedback) -> Void = { _ in }
    fileprivate var onSettled: (Bool) -> Void = { _ in }
    fileprivate var onChange: (Bool) -> Void = { _ in }
    fileprivate var onDismiss: () -> Void = {}
    private let contentSurface = UIView()
    private let contentShadow = UIView()
    private let sidebarSurface = UIView()
    private let shield = UIButton(type: .custom)
    private var motion = SidebarMotion()
    private var endpointFeedback = SidebarEndpointFeedback()
    private var feedbackDisplayLink: CADisplayLink?
    private var animator: UIViewPropertyAnimator?
    private var constraints: [NSLayoutConstraint] = []
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarLeading: NSLayoutConstraint!
    private var sidebarTrailing: NSLayoutConstraint!
    private var covered = false
    private var disposed = false
    private var pan: UIPanGestureRecognizer!
    private var wantsOpen = false
    private var scheduledOpen: Bool?
    private var lastSize = CGSize.zero
    private var lastDirection = false
    private weak var previousAccessibilityFocus: NSObject?

    fileprivate init(content: AnyView, sidebar: AnyView) {
        self.content = UIHostingController(rootView: content)
        self.sidebar = UIHostingController(rootView: sidebar)
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = true
        for surface in [sidebarSurface, contentShadow, contentSurface] {
            surface.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(surface)
        }
        // The foreground is a full-height rounded screen above the rear plane.
        // Shadow the empty, opaque rounded surface, never the live wallet tree.
        // This preserves continuous corners without a mismatched circular path
        // or a per-frame snapshot / shadow-path rebuild.
        contentSurface.backgroundColor = .systemBackground
        contentSurface.layer.cornerCurve = .continuous
        contentShadow.backgroundColor = .systemBackground
        contentShadow.layer.cornerCurve = .continuous
        contentShadow.isUserInteractionEnabled = false
        contentShadow.accessibilityElementsHidden = true
        contentShadow.layer.shadowColor = UIColor.black.cgColor
        contentShadow.layer.shadowOffset = .zero
        contentShadow.layer.shadowRadius = 12
        contentShadow.alpha = 0
        updateShadowAppearance()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) {
            (self: Self, _: UITraitCollection) in self.updateShadowAppearance()
        }
        sidebarWidth = sidebarSurface.widthAnchor.constraint(equalToConstant: 0)
        sidebarLeading = sidebarSurface.leftAnchor.constraint(equalTo: view.leftAnchor)
        sidebarTrailing = sidebarSurface.rightAnchor.constraint(equalTo: view.rightAnchor)
        constraints = [
            contentSurface.topAnchor.constraint(equalTo: view.topAnchor),
            contentSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentSurface.leftAnchor.constraint(equalTo: view.leftAnchor),
            contentSurface.rightAnchor.constraint(equalTo: view.rightAnchor),
            contentShadow.topAnchor.constraint(equalTo: view.topAnchor),
            contentShadow.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentShadow.leftAnchor.constraint(equalTo: view.leftAnchor),
            contentShadow.rightAnchor.constraint(equalTo: view.rightAnchor),
            sidebarSurface.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarSurface.bottomAnchor.constraint(equalTo: view.bottomAnchor), sidebarWidth
        ]
        NSLayoutConstraint.activate(constraints)
        embed(sidebar, in: sidebarSurface)
        embed(content, in: contentSurface)
        shield.translatesAutoresizingMaskIntoConstraints = false
        // The reference recedes toward the canvas (white in light appearance,
        // dark in dark appearance), rather than placing a black scrim on it.
        shield.backgroundColor = .systemBackground
        shield.addTarget(self, action: #selector(close), for: .touchUpInside)
        shield.accessibilityIdentifier = "sidebar.dismiss"
        contentSurface.addSubview(shield)
        NSLayoutConstraint.activate([
            shield.topAnchor.constraint(equalTo: contentSurface.topAnchor),
            shield.bottomAnchor.constraint(equalTo: contentSurface.bottomAnchor),
            shield.leftAnchor.constraint(equalTo: contentSurface.leftAnchor),
            shield.rightAnchor.constraint(equalTo: contentSurface.rightAnchor)
        ])
        pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        sidebarSurface.isHidden = true
        shield.isHidden = true
        sidebarSurface.accessibilityElementsHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
    }

    private func embed(_ child: UIViewController, in surface: UIView) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        child.view.backgroundColor = .clear
        surface.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: surface.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            child.view.leftAnchor.constraint(equalTo: surface.leftAnchor),
            child.view.rightAnchor.constraint(equalTo: surface.rightAnchor)
        ])
        child.didMove(toParent: self)
    }

    public override var childForStatusBarStyle: UIViewController? { covered ? sidebar : content }
    public override var childForStatusBarHidden: UIViewController? { content }
    public override var childForHomeIndicatorAutoHidden: UIViewController? { content }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.size != lastSize || rightToLeft != lastDirection else { return }
        let resume = animator != nil || motion.isDragging
        stopAtCurrentPosition()
        if motion.isDragging { pan.isEnabled = false; pan.isEnabled = true }
        lastSize = view.bounds.size; lastDirection = rightToLeft
        motion.resize(windowWidth: view.bounds.width, rightToLeft: rightToLeft)
        sidebarWidth.constant = motion.width
        sidebarLeading.isActive = !rightToLeft
        sidebarTrailing.isActive = rightToLeft
        apply(progress: motion.progress)
        if resume || wantsOpen { transition(open: wantsOpen, animated: false) }
    }

    fileprivate func scheduleUpdate(open: Bool) {
        let alreadyScheduled = scheduledOpen != nil
        scheduledOpen = open
        guard !alreadyScheduled else { return }
        // Opening resigns the first responder and invokes the flow's focus
        // callback. Perform that outside updateUIViewController so it cannot
        // mutate SwiftUI state during its own update. Coalesce to the latest
        // request and discard pending work when the container is removed.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disposed, let open = self.scheduledOpen else { return }
            self.scheduledOpen = nil
            self.update(open: open)
        }
    }

    private func update(open: Bool) {
        guard !disposed else { return }
        loadViewIfNeeded()
        if rightToLeft != lastDirection { view.setNeedsLayout() }
        shield.accessibilityLabel = closeLabel
        wantsOpen = open && enabled
        if !enabled {
            if open {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.disposed, !self.enabled else { return }
                    self.onChange(false)
                }
            }
            if motion.isDragging { pan.isEnabled = false; pan.isEnabled = true }
            transition(open: false, animated: false)
        } else if !motion.isDragging, motion.targetOpen != wantsOpen {
            transition(open: wantsOpen, animated: view.window != nil)
        }
    }

    private func beginCoverage() {
        guard !covered else { return }
        covered = true
        stopForegroundScrolling(in: content.view)
        content.view.isUserInteractionEnabled = false
        setScreenCorners(exposed: true)
        previousAccessibilityFocus = UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject
        sidebarSurface.isHidden = false
        sidebarSurface.accessibilityElementsHidden = false
        sidebarSurface.accessibilityViewIsModal = true
        content.view.accessibilityElementsHidden = true
        shield.isHidden = false
        onWillOpen()
        view.endEditing(true)
        setNeedsStatusBarAppearanceUpdate()
    }

    private func stopForegroundScrolling(in view: UIView) {
        if let scroll = view as? UIScrollView {
            let scrollPan = scroll.panGestureRecognizer
            if scrollPan.state == .began || scrollPan.state == .changed {
                scrollPan.isEnabled = false
                scrollPan.isEnabled = true
            }
            if #available(iOS 17.4, *) {
                scroll.stopScrollingAndZooming()
            } else {
                scroll.setContentOffset(scroll.contentOffset, animated: false)
            }
        }
        for child in view.subviews {
            stopForegroundScrolling(in: child)
        }
    }

    private func complete(open: Bool) {
        stopFeedbackTracking()
        motion.request(open: open)
        let changed = motion.settle()
        apply(progress: motion.progress)
        reportEndpoint(at: motion.progress)
        if open {
            UIAccessibility.post(notification: .screenChanged, argument: sidebar.view)
        } else if covered {
            dismissSidebarMenus()
            covered = false
            setScreenCorners(exposed: false)
            sidebarSurface.isHidden = true
            sidebarSurface.accessibilityElementsHidden = true
            sidebarSurface.accessibilityViewIsModal = false
            content.view.isUserInteractionEnabled = true
            content.view.accessibilityElementsHidden = false
            shield.isHidden = true
            setNeedsStatusBarAppearanceUpdate()
            UIAccessibility.post(notification: .screenChanged, argument: previousAccessibilityFocus)
            previousAccessibilityFocus = nil
            // This completion can run during updateUIViewController on lifecycle
            // shutdown. Defer publication outside the SwiftUI update transaction.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.disposed, !self.covered else { return }
                self.onDismiss()
            }
        }
        if changed, enabled, view.window != nil { onSettled(open) }
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard covered, let scene = notification.object as? UIWindowScene,
              scene === viewIfLoaded?.window?.windowScene else { return }
        dismissSidebarMenus()
    }

    // Dismiss while the source is still visible. A menu is presented outside
    // the drawer, and its dismissal animation can be suspended with the scene.
    private func dismissSidebarMenus() {
        func dismiss(in view: UIView) {
            for case let menu as UIContextMenuInteraction in view.interactions {
                menu.dismissMenu()
            }
            for child in view.subviews { dismiss(in: child) }
        }
        UIView.performWithoutAnimation { dismiss(in: sidebarSurface) }
    }

    private func apply(progress: Double) {
        contentSurface.transform = CGAffineTransform(translationX: motion.contentTranslation(at: progress), y: 0)
        contentShadow.transform = contentSurface.transform
        contentShadow.alpha = progress
        let scale = reduceMotion ? 1 : motion.sidebarScale(at: progress)
        // Scale the rendered rear plane, not its UIView geometry. A view
        // transform changes the hosting controller's safe-area insets and
        // relays out its SwiftUI content as the drawer moves.
        sidebarSurface.layer.sublayerTransform = CATransform3DMakeScale(scale, scale, 1)
        sidebarSurface.alpha = increasedContrast ? 1 : motion.sidebarOpacity(at: progress)
        shield.alpha = motion.contentVeilOpacity(at: progress)
    }

    private func setScreenCorners(exposed: Bool) {
        // Keep the same physical screen outline for the whole interaction. Its
        // corners become visible as the screen moves, not as a second morph.
        // Removing the mask at rest preserves edge-to-edge native content.
        let radius = exposed ? SidebarMotion.exposedCornerRadius : 0
        contentSurface.layer.cornerRadius = radius
        contentSurface.clipsToBounds = exposed
        contentShadow.layer.cornerRadius = radius
    }

    private func updateShadowAppearance() {
        let isDark = traitCollection.userInterfaceStyle == .dark
        let isHighContrast = traitCollection.accessibilityContrast == .high
        contentShadow.layer.shadowOpacity = isHighContrast ? 0.6 : (isDark ? 0.5 : 0.16)
    }

    private func stopAtCurrentPosition() {
        stopFeedbackTracking()
        guard let animator else { return }
        let position = contentSurface.layer.presentation()?.affineTransform().tx ?? contentSurface.transform.tx
        animator.stopAnimation(true)
        self.animator = nil
        motion.capture(progress: motion.width > 0 ? position / (motion.sign * motion.width) : 0)
        apply(progress: motion.progress)
    }

    private func prepareFeedback(open: Bool) {
        if enabled, view.window != nil, endpointFeedback.isOpen != open {
            onFeedback(.prepare(open: open))
        }
    }

    private func reportEndpoint(at progress: Double) {
        if let open = endpointFeedback.reachedEndpoint(at: progress), enabled, view.window != nil {
            onFeedback(.impact(open: open))
        }
    }

    @objc private func sampleAnimatedPosition() {
        guard motion.width > 0, let layer = contentSurface.layer.presentation() else { return }
        let progress = layer.affineTransform().tx / (motion.sign * motion.width)
        reportEndpoint(at: progress)
        if endpointFeedback.isOpen == motion.targetOpen { stopFeedbackTracking() }
    }

    private func stopFeedbackTracking() {
        feedbackDisplayLink?.invalidate()
        feedbackDisplayLink = nil
    }

    private func transition(open: Bool, animated: Bool = true, velocityX: Double = 0) {
        guard !disposed else { return }
        stopAtCurrentPosition()
        motion.request(open: open)
        if animated {
            prepareFeedback(open: open)
        } else {
            // Layout and lifecycle can snap to an endpoint without user input.
            endpointFeedback = SidebarEndpointFeedback(isOpen: open)
        }
        if open { beginCoverage() }
        guard animated, !reduceMotion, abs(motion.progress - (open ? 1 : 0)) > 0.001 else {
            complete(open: open); return
        }
        // A critically damped UIKit spring settles without the old bounce. Its
        // initial velocity continues the user's drag instead of stopping first.
        let timing = UISpringTimingParameters(dampingRatio: 1,
            initialVelocity: CGVector(dx: motion.springVelocity(velocityX: velocityX, opening: open), dy: 0))
        let animation = UIViewPropertyAnimator(duration: SidebarMotion.settlingDuration, timingParameters: timing)
        animation.addAnimations { [weak self] in
            self?.apply(progress: open ? 1 : 0)
        }
        animator = animation
        animation.addCompletion { [weak self, weak animation] position in
            guard let self, let animation, self.animator === animation, position == .end else { return }
            self.animator = nil
            self.complete(open: open)
        }
        animation.startAnimation()
        if endpointFeedback.isOpen != open, enabled, view.window != nil {
            let link = CADisplayLink(target: self, selector: #selector(sampleAnimatedPosition))
            feedbackDisplayLink = link
            link.add(to: .main, forMode: .common)
        }
    }

    @objc private func close() {
        wantsOpen = false
        onChange(false)
        transition(open: false)
    }

    public override func accessibilityPerformEscape() -> Bool {
        guard covered else { return false }
        close(); return true
    }

    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopAtCurrentPosition()
            motion.beginDrag()
            prepareFeedback(open: gesture.velocity(in: view).x * motion.sign > 0)
            beginCoverage()
            // Include the translation that established horizontal intent; do
            // not lose the first movement and make the screen trail the finger.
            fallthrough
        case .changed:
            motion.drag(translationX: gesture.translation(in: view).x)
            apply(progress: motion.progress)
            reportEndpoint(at: motion.progress)
        case .ended, .cancelled, .failed:
            guard motion.isDragging else { return }
            wantsOpen = motion.endDrag(velocityX: gesture.velocity(in: view).x, cancelled: gesture.state != .ended)
            onChange(wantsOpen)
            transition(open: wantsOpen, velocityX: gesture.state == .ended ? gesture.velocity(in: view).x : 0)
        default: break
        }
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, enabled, view.window != nil,
              !hasPresentation(in: content), !hasPresentation(in: sidebar) else { return false }
        let velocity = pan.velocity(in: view)
        return SidebarMotion.canBegin(velocityX: velocity.x, velocityY: velocity.y,
            rightToLeft: rightToLeft, isOpen: covered,
            allowed: covered || allowsOpeningSwipe, nativeBack: hasBackStack(in: content), protectedControl: false,
            transitioning: animator != nil)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === pan else { return true }
        // Do not even join the touch sequence owned by a pushed navigation
        // page. Waiting until shouldBegin can delay its native edge/content pop.
        guard covered || (allowsOpeningSwipe && !hasBackStack(in: content)) else { return false }
        var candidate = touch.view
        while let current = candidate, current !== view {
            if current is UITextField || current is UITextView { return false }
            // Buttons/switches/sliders keep their own touch sequences. The
            // dismissal shield intentionally remains draggable.
            if current is UIControl, current !== shield { return false }
            if let scroll = current as? UIScrollView,
               scroll.contentSize.width > scroll.bounds.width + 1 { return false }
            candidate = current.superview
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, !covered else { return false }
        if isNativeBack(other, in: content) { return true }
        // UITableView/UICollectionView install row-action recognizers alongside
        // their ordinary scroll pan. Give those public recognizers priority.
        if let scroll = other.view as? UIScrollView, other !== scroll.panGestureRecognizer {
            return other is UIPanGestureRecognizer || other is UISwipeGestureRecognizer
        }
        return false
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // A vertical list waits for the drawer's direction check. Vertical swipes
        // immediately go to the list; an accepted drawer swipe owns that touch.
        guard gestureRecognizer === pan, let scroll = other.view as? UIScrollView,
              other === scroll.panGestureRecognizer,
              scroll.contentSize.width <= scroll.bounds.width + 1 else { return false }
        return scroll.isDescendant(of: contentSurface) || scroll.isDescendant(of: sidebarSurface)
    }

    private func hasBackStack(in controller: UIViewController) -> Bool {
        if let tabs = controller as? UITabBarController {
            return tabs.selectedViewController.map { hasBackStack(in: $0) } ?? false
        }
        if let navigation = controller as? UINavigationController {
            return navigation.viewControllers.count > 1 || navigation.transitionCoordinator != nil
        }
        return controller.children.contains {
            $0.viewIfLoaded?.window != nil && $0.viewIfLoaded?.isHidden == false && hasBackStack(in: $0)
        }
    }

    private func hasPresentation(in controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains { hasPresentation(in: $0) }
    }

    private func isNativeBack(_ gesture: UIGestureRecognizer, in controller: UIViewController) -> Bool {
        if let navigation = controller as? UINavigationController, navigation.viewControllers.count > 1 {
            if gesture === navigation.interactivePopGestureRecognizer { return true }
            if #available(iOS 26, *), gesture === navigation.interactiveContentPopGestureRecognizer { return true }
        }
        return controller.children.contains { isNativeBack(gesture, in: $0) }
    }

    fileprivate func tearDown() {
        disposed = true
        NotificationCenter.default.removeObserver(self, name: UIScene.willDeactivateNotification, object: nil)
        if covered { dismissSidebarMenus() }
        stopFeedbackTracking()
        scheduledOpen = nil
        animator?.stopAnimation(true); animator = nil
        onWillOpen = {}; onChange = { _ in }; onDismiss = {}
        onSettled = { _ in }
        onFeedback = { _ in }
        for child in [content, sidebar] {
            child.willMove(toParent: nil)
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
    }
}
#endif
