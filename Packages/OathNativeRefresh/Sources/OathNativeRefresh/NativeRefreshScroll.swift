import SwiftUI
import UIKit
import OathDiagnostics

public enum NativeRefreshFeedback: Sendable { case pullStep, started, succeeded, failed, finished }

/// A native List keeps content hit testing aligned with UIRefreshControl's
/// inset during refresh. Supply long collections as direct ForEach rows so the
/// system can reuse cells; do not put them in one enclosing stack.
public struct NativeRefreshScroll<Content: View>: View {
    @State private var attachmentOwner = AttachmentOwner()
    @Environment(\.walletRefreshHost) private var navigationHost
    private let identifier: String
    private let tint: UIColor
    private let indicator: NativeRefreshIndicator
    private let timing: NativeRefreshTiming
    private let labels: NativeRefreshLabels
    private let isEnabled: Bool
    private let refreshIdentity: String?
    private let action: @MainActor @Sendable () async throws -> Void
    private let onFailure: @MainActor () -> Void
    private let onScroll: @MainActor (CGFloat) -> Void
    private let onDraggingChanged: @MainActor (Bool) -> Void
    private let onPresentationChanged: @MainActor (Bool) -> Void
    private let feedback: @MainActor (NativeRefreshFeedback) -> Void
    private let content: Content

    public init(identifier: String, tint: UIColor,
                indicator: NativeRefreshIndicator = .system,
                timing: NativeRefreshTiming = .untilFinished,
                labels: NativeRefreshLabels = .english,
                isEnabled: Bool = true, refreshIdentity: String? = nil,
                action: @escaping @MainActor @Sendable () async throws -> Void,
                onFailure: @escaping @MainActor () -> Void,
                onScroll: @escaping @MainActor (CGFloat) -> Void,
                onDraggingChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                onPresentationChanged: @escaping @MainActor (Bool) -> Void = { _ in },
                feedback: @escaping @MainActor (NativeRefreshFeedback) -> Void = { _ in },
                @ViewBuilder content: () -> Content) {
        self.identifier = identifier
        self.tint = tint
        self.indicator = indicator
        self.timing = timing
        self.labels = labels
        self.isEnabled = isEnabled
        self.refreshIdentity = refreshIdentity
        self.action = action
        self.onFailure = onFailure
        self.onScroll = onScroll
        self.onDraggingChanged = onDraggingChanged
        self.onPresentationChanged = onPresentationChanged
        self.feedback = feedback
        self.content = content()
    }

    public var body: some View {
        if indicator == .walletBand && navigationHost == nil {
            scrollContent.walletRefreshNavigation()
        } else {
            scrollContent
        }
    }

    @ViewBuilder private var refreshableRows: some View {
        if indicator == .walletBand {
            // The navigation inset owns this style's hold. A second inset
            // from UIRefreshControl would move every row down twice.
            rows
        } else {
            rows.refreshable { await attachmentOwner.controller?.refreshFromSystem() }
        }
    }

    private var rows: some View {
        // ScrollView.refreshable shifts rendered content but leaves SwiftUI
        // button targets at the pre-refresh origin on affected iOS versions.
        // Native list cells move their content and interaction geometry together.
        List {
            content
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .navigationLinkIndicatorVisibility(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.all, 0, for: .scrollContent)
        .scrollContentBackground(.hidden)
    }

    private var scrollContent: some View {
        refreshableRows.scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier(identifier)
        .background(Attachment(owner: attachmentOwner, configure: configure))
    }

    private final class AttachmentOwner {
        weak var controller: Controller?
    }

    private struct Attachment: UIViewControllerRepresentable {
        let owner: AttachmentOwner
        let configure: @MainActor (Controller, EnvironmentValues) -> Void
        func makeUIViewController(context: Context) -> Controller {
            // UIKit objects are created once by the representable, not by each
            // transient SwiftUI View initializer during a balance update.
            let controller = Controller()
            owner.controller = controller
            configure(controller, context.environment)
            return controller
        }
        func updateUIViewController(_ controller: Controller, context: Context) {
            configure(controller, context.environment)
        }
        static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
            controller.detach()
        }
    }

    private func configure(_ controller: Controller, environment: EnvironmentValues) {
        controller.loadViewIfNeeded()
        controller.identifier = identifier
        let enabled = isEnabled && environment.scenePhase == .active
        controller.requestedEnabled = enabled
        if controller.refreshIdentity != refreshIdentity || controller.indicator != indicator || controller.timing != timing
            || controller.bandHost !== environment.walletRefreshHost
            || (controller.enabled && !enabled) {
            controller.stop()
        }
        controller.refreshIdentity = refreshIdentity
        controller.bandHost = environment.walletRefreshHost
        if controller.indicator != indicator { controller.indicatorView?.removeFromSuperview() }
        controller.indicator = indicator
        controller.indicatorView?.accessibilityIdentifier = identifier + ".brand"
        controller.timing = timing
        controller.enabled = enabled
        if controller.model.isActive != enabled { controller.model.isActive = enabled }
        if controller.model.labels != labels { controller.model.labels = labels }
        controller.tint = tint
        controller.indicatorLayoutDirection = environment.layoutDirection
        controller.indicatorLocale = environment.locale
        if indicator == .oathLogo {
            controller.logoIndicatorView.configuration = UIHostingConfiguration {
                AnyView(BrandedRefreshIndicator(model: controller.model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .environment(\.locale, environment.locale)
                    .environment(\.layoutDirection, environment.layoutDirection)
                    .environment(\.colorScheme, environment.colorScheme))
            }.margins(.all, 0)
        }
        controller.action = action
        controller.onFailure = onFailure
        controller.onScroll = onScroll
        controller.onDraggingChanged = onDraggingChanged
        controller.onPresentationChanged = onPresentationChanged
        controller.feedback = feedback
        controller.attachIfPossible()
        controller.positionIndicator()
    }

    @MainActor public final class Controller: UIViewController {
        private weak var attachedScroll: UIScrollView?
        private lazy var unattachedScroll = UIScrollView()
        fileprivate var scroll: UIScrollView { attachedScroll ?? unattachedScroll }
        private var offsetObservation: NSKeyValueObservation?
        private var restingTopInset: CGFloat?
        private lazy var unattachedControl = UIRefreshControl()
        fileprivate var control: UIRefreshControl { scroll.refreshControl ?? unattachedControl }
        fileprivate var tint = UIColor.label
        fileprivate var indicatorLayoutDirection: LayoutDirection = .leftToRight
        fileprivate var indicatorLocale = Locale.current
        fileprivate var identifier = ""
        fileprivate lazy var ringIndicatorView = ProgressRingRefreshIndicator(frame: .zero)
        fileprivate var indicatorView: UIView? {
            switch indicator {
            case .progressRing: ringIndicatorView
            case .oathLogo: logoIndicatorView
            case .system, .walletBand: nil
            }
        }
        fileprivate lazy var logoIndicatorView: UIView & UIContentView = UIHostingConfiguration {
            AnyView(BrandedRefreshIndicator(model: self.model))
        }.margins(.all, 0).makeContentView()
        fileprivate let model = RefreshIndicatorModel()
        fileprivate var indicator: NativeRefreshIndicator = .system
        fileprivate weak var bandHost: WalletRefreshHost?
        private var trackingBandPull = false
        private var pullViewportHeight: CGFloat = 0
        fileprivate var timing: NativeRefreshTiming = .untilFinished
        fileprivate var enabled = true
        fileprivate var requestedEnabled = true
        fileprivate var refreshIdentity: String?
        fileprivate var action: (@MainActor @Sendable () async throws -> Void)?
        fileprivate var onFailure: (@MainActor () -> Void)?
        fileprivate var onScroll: (@MainActor (CGFloat) -> Void)?
        fileprivate var onDraggingChanged: (@MainActor (Bool) -> Void)?
        fileprivate var onPresentationChanged: (@MainActor (Bool) -> Void)?
        private var isPresentingRefresh = false
        private var isDragging = false

        /// Loading presentation only: excludes the result hold and any provider
        /// work continuing after the brief deadline. Cancellation also resets it.
        private func updatePresentation(_ value: Bool) {
            guard isPresentingRefresh != value else { return }
            isPresentingRefresh = value
            // Like dragging, stop can run inside a representable update. Keep
            // ordered observation mutations outside SwiftUI's update pass.
            let callback = onPresentationChanged
            DispatchQueue.main.async { callback?(value) }
        }

        private func updateDragging(_ value: Bool) {
            guard isDragging != value else { return }
            isDragging = value
            // stop() also runs during representable updates and teardown.
            // Deliver state changes on the next main-loop turn, in order,
            // without mutating SwiftUI observation during that update.
            let callback = onDraggingChanged
            DispatchQueue.main.async { callback?(value) }
        }
        fileprivate var feedback: (@MainActor (NativeRefreshFeedback) -> Void)?
        private let presentation = RefreshPresentation()
        private let backgroundRefresh = BackgroundRefresh()
        private var work: Task<Void, Never>?
        private var activeRequest: UUID?
        private var pullFeedback = RefreshPullFeedback()
        private var pullGesture = RefreshPullGesture()

        public override func loadView() {
            let anchor = RefreshScrollAnchor()
            anchor.attached = { [weak self] in self?.attachIfPossible() }
            view = anchor
        }

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        fileprivate func attachIfPossible() {
            guard isViewLoaded, let window = view.window, let screen = parent?.viewIfLoaded,
                  view.isDescendant(of: screen) else { return }
            if let attachedScroll, attachedScroll.window === window, attachedScroll.isDescendant(of: screen) {
                styleControl()
                return
            }
            if offsetObservation != nil {
                let wasEnabled = enabled
                detach()
                enabled = wasEnabled
            }
            var ancestor: UIView? = view
            while let candidate = ancestor {
                if let target = findScroll(in: candidate) {
                    attachedScroll = target
                    restingTopInset = target.adjustedContentInset.top
                    pullGesture.observe(position: target.contentOffset.y + target.adjustedContentInset.top,
                                        isPanning: false)
                    presentation.attach(target)
                    styleControl()
                    // Observe public geometry; never replace SwiftUI's delegate
                    // or gesture recognizer, which own laziness and scrolling.
                    offsetObservation = target.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                        MainActor.assumeIsolated { self?.scrollViewDidScroll(scroll) }
                    }
                    target.panGestureRecognizer.addTarget(self, action: #selector(panChanged))
                    return
                }
                // The sidebar list can mount before Home's list in the same window.
                // Wait for our screen to finish mounting instead of borrowing its sibling.
                if candidate === screen { break }
                ancestor = candidate.superview
            }
        }

        /// The anchor belongs to the viewport, never a reusable row. Resolve
        /// the refreshable scroll in the nearest owning view branch. A SwiftUI
        /// background anchor can have a different safe-area frame from List,
        /// so its frame is not used to reposition content or to test touches.
        private func findScroll(in candidate: UIView) -> UIScrollView? {
            guard !candidate.isHidden else { return nil }
            if let scroll = candidate as? UIScrollView,
               scroll.window === view.window,
               (indicator == .walletBand ? scroll is UICollectionView || scroll is UITableView : scroll.refreshControl != nil),
               scroll.accessibilityIdentifier == nil || scroll.accessibilityIdentifier == identifier {
                return scroll
            }
            for child in candidate.subviews {
                if let scroll = findScroll(in: child) { return scroll }
            }
            return nil
        }

        fileprivate func detach() {
            stop()
            offsetObservation = nil
            if let target = attachedScroll {
                target.panGestureRecognizer.removeTarget(self, action: #selector(panChanged))
            }
            indicatorView?.removeFromSuperview()
            attachedScroll = nil
            restingTopInset = nil
        }

        @objc private func panChanged(_ pan: UIPanGestureRecognizer) {
            switch pan.state {
            case .began:
                pullGesture.beginPan()
                pullViewportHeight = scroll.bounds.height
                updateDragging(enabled)
                trackingBandPull = indicator == .walletBand && enabled && activeRequest == nil
                    && pullGesture.allowsRefresh && !model.cycle.isReturning
            case .changed:
                if trackingBandPull { followBandPull(pan) }
            case .ended, .cancelled, .failed:
                if trackingBandPull {
                    trackingBandPull = false
                    if activeRequest != nil {
                        bandHost?.hold(tint: tint, owner: self, scroll: scroll)
                    } else {
                        bandHost?.releasePartial(owner: self)
                        model.resetIfNeeded()
                    }
                }
                pullGesture.endPan(at: restingPosition)
                pullFeedback = RefreshPullFeedback()
                updateDragging(false)
            default: break
            }
        }

        private var restingPosition: CGFloat {
            if indicator == .walletBand { return scroll.contentOffset.y + scroll.adjustedContentInset.top }
            return scroll.contentOffset.y + (restingTopInset ?? scroll.adjustedContentInset.top)
        }

        private func followBandPull(_ pan: UIPanGestureRecognizer) {
            let distance = WalletRefreshMotion.pullDistance(translation: pan.translation(in: view.window).y,
                                                           viewport: pullViewportHeight)
            bandHost?.follow(distance: distance, tint: tint, owner: self, scroll: scroll)
            if activeRequest == nil {
                var cycle = model.cycle
                cycle.pull(distance: distance, isDragging: true)
                let starts = cycle.beginIfFilled(isDragging: true, eligible: action != nil)
                if cycle != model.cycle { model.cycle = cycle }
                if starts { startRefresh() }
            }
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            enabled = requestedEnabled
            if model.isActive != enabled { model.isActive = enabled }
            attachIfPossible()
            presentation.attach(scroll)
        }

        public override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attachIfPossible()
        }

        public override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if indicator == .walletBand { stop() }
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            stop()
        }

        public override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attachIfPossible()
            positionIndicator()
        }

        public func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if indicator == .walletBand {
                let position = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                let pan = scrollView.panGestureRecognizer.state
                pullGesture.observe(position: position, isPanning: pan == .began || pan == .changed)
                onScroll?(-position)
                return
            }
            if activeRequest == nil && !control.isRefreshing && !model.cycle.isReturning {
                restingTopInset = scrollView.adjustedContentInset.top
            }
            let origin = -(scrollView.contentOffset.y + (restingTopInset ?? scrollView.adjustedContentInset.top))
            onScroll?(origin)
            guard indicator != .system else { return }
            let panState = scrollView.panGestureRecognizer.state
            pullGesture.observe(position: -origin, isPanning: panState == .began || panState == .changed)
            if indicator == .progressRing, origin <= 0, model.cycle.phase == .idle { return }
            let allowsPull = pullGesture.allowsRefresh
            var cycle = model.cycle
            if !allowsPull && (cycle.phase == .idle || cycle.phase == .pulling) {
                cycle.reset()
            } else {
                cycle.pull(distance: origin, isDragging: scrollView.isDragging && enabled && allowsPull)
            }
            // Gesture feedback is semantic; only the app's preference-aware driver
            // touches hardware. Bounce, loading and layout updates stay silent.
            if pullFeedback.update(progress: cycle.progress,
                                   isDragging: scrollView.isDragging,
                                   eligible: indicator == .progressRing && enabled && allowsPull
                                       && activeRequest == nil && !cycle.isReturning
                                       && (cycle.phase == .idle || cycle.phase == .pulling)) {
                feedback?(.pullStep)
            }
            // A filled ring is the activation threshold, not just decoration
            // ahead of UIKit's separate threshold. Keep all motion in UIKit.
            let startsRing = cycle.beginIfFilled(isDragging: scrollView.isDragging,
                eligible: indicator == .progressRing && enabled && allowsPull
                    && activeRequest == nil && action != nil)
            if cycle != model.cycle { model.cycle = cycle }
            if startsRing { startRefresh() }
            positionIndicator()
        }


        private var positionedIdleRing = false

        fileprivate func positionIndicator() {
            guard let indicatorView, isViewLoaded, let nativeControl = attachedScroll?.refreshControl else { return }
            let idleRing = indicator == .progressRing && model.cycle.phase == .idle
            if idleRing && positionedIdleRing && restingPosition >= 0 &&
                ringIndicatorView.superview === nativeControl { return }
            positionedIdleRing = idleRing
            // Keep the visual inside UIRefreshControl for its entire lifetime,
            // exactly like the logo. UIKit owns reveal, inset and return motion.
            if indicatorView.superview !== nativeControl {
                indicatorView.backgroundColor = .clear
                indicatorView.isUserInteractionEnabled = false
                indicatorView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                nativeControl.addSubview(indicatorView)
            }
            if indicator == .progressRing {
                ringIndicatorView.update(cycle: model.cycle, tint: tint, labels: model.labels,
                                         layoutDirection: indicatorLayoutDirection, locale: indicatorLocale,
                                         active: enabled, reduceMotion: UIAccessibility.isReduceMotionEnabled)
            }
            indicatorView.frame = nativeControl.bounds
            let distance = max(0, -(scroll.contentOffset.y + (restingTopInset ?? scroll.adjustedContentInset.top)))
            indicatorView.alpha = indicator != .system && model.cycle.phase != .idle
                ? (model.cycle.phase == .pulling || model.cycle.isReturning ? min(1, distance / 24) : 1) : 0
        }

        fileprivate func stop() {
            enabled = false
            trackingBandPull = false
            bandHost?.reset(owner: self)
            updatePresentation(false)
            updateDragging(false)
            activeRequest = nil
            work?.cancel()
            work = nil
            pullFeedback = RefreshPullFeedback()
            pullGesture = RefreshPullGesture()
            backgroundRefresh.cancel()
            presentation.detach()
            model.resetIfNeeded()
            if let control = attachedScroll?.refreshControl, control.isRefreshing { control.endRefreshing() }
            positionIndicator()
        }

        private func styleControl() {
            // Re-seed after a screen returns or refresh is re-enabled without
            // requiring an offset change first. Never change a live pan's gate.
            let panState = scroll.panGestureRecognizer.state
            if panState != .began && panState != .changed {
                pullGesture.observe(position: restingPosition, isPanning: false)
            }
            scroll.accessibilityIdentifier = identifier
            if let control = scroll.refreshControl {
                control.accessibilityIdentifier = identifier + ".refresh"
                control.tintColor = indicator == .system ? tint : .clear
                control.isEnabled = enabled
                control.accessibilityElementsHidden = indicator != .system
            }
            scroll.accessibilityCustomActions = indicator != .system ? [
                UIAccessibilityCustomAction(name: model.labels.pull, target: self,
                    selector: #selector(accessibilityRefresh))
            ] : nil
            positionIndicator()
        }

        fileprivate func refreshFromSystem() async {
            attachIfPossible()
            guard enabled else { control.endRefreshing(); return }
            // A later native callback joins the request already started by the
            // full ring; it must not run the action or activation feedback twice.
            if activeRequest == nil {
                // UIKit may emit its release event after a navigation swipe has
                // crossed the top. It must not bypass the gesture-start gate.
                if indicator != .system && !pullGesture.allowsRefresh {
                    control.endRefreshing()
                    return
                }
                if indicator != .system, !model.cycle.begin() {
                    // A threshold event during the result's return is not a
                    // new user request and must not pin the control open.
                    control.endRefreshing()
                    return
                }
                startRefresh()
            }
            await work?.value
        }

        @objc fileprivate func accessibilityRefresh() -> Bool {
            guard enabled, attachedScroll != nil, indicator == .walletBand || attachedScroll?.refreshControl != nil,
                  activeRequest == nil, model.cycle.begin() else { return false }
            startRefresh()
            if indicator == .walletBand { return true }
            // Only an explicit accessibility action needs programmatic reveal.
            // Touch gestures never write offsets or manually change insets.
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                y: -(restingTopInset ?? scroll.adjustedContentInset.top)
                    - control.bounds.height), animated: true)
            return true
        }

        private func startRefresh() {
            guard enabled, activeRequest == nil, let action else { return }
            let request = UUID()
            activeRequest = request
            updatePresentation(true)
            feedback?(.started)
            presentation.attach(scroll)
            let startedAt = CACurrentMediaTime()
            model.startedAt = .now
            if indicator == .walletBand {
                if !trackingBandPull { bandHost?.hold(tint: tint, owner: self, scroll: scroll) }
                UIAccessibility.post(notification: .announcement, argument: model.labels.refreshing)
            } else if !control.isRefreshing { control.beginRefreshing() }
            positionIndicator()
            work = Task { [weak self] in
                guard let self else { return }
                if let duration = timing.duration {
                    await presentTimedRefresh(request: request, duration: duration, action: action)
                    return
                }
                let outcome = await RefreshAction.run(action: action,
                    isCurrent: { self.activeRequest == request })
                guard outcome != .cancelled else {
                    if activeRequest == request { stop() }
                    return
                }
                let failed = outcome == .failed
                guard !Task.isCancelled, activeRequest == request else { return }
                await presentation.finishPresentation(startedAt: startedAt)
                guard !Task.isCancelled, activeRequest == request else { return }
                guard await presentResult(request: request, outcome: outcome) else { return }
                control.endRefreshing()
                activeRequest = nil
                work = nil
                scrollViewDidScroll(scroll)
                if failed { onFailure?() }
            }
        }

        private func presentResult(request: UUID, outcome: RefreshAction.Outcome?) async -> Bool {
            let failed = outcome == .failed
            let event: NativeRefreshFeedback = failed ? .failed : (outcome == nil ? .finished : .succeeded)
            if indicator == .walletBand {
                if scroll.isTracking || scroll.isDragging {
                    await presentation.finishPresentation(startedAt: CACurrentMediaTime(),
                        minimumDuration: 0, releaseOnly: true)
                }
                guard !Task.isCancelled, activeRequest == request else { return false }
                model.cycle.finishPresentation()
                updatePresentation(false)
                feedback?(event)
                if outcome != nil {
                    UIAccessibility.post(notification: .announcement,
                        argument: failed ? model.labels.failed : model.labels.succeeded)
                }
                await bandHost?.close(owner: self)
                guard !Task.isCancelled, activeRequest == request else { return false }
                model.resetIfNeeded()
                return true
            }
            updatePresentation(false)
            if indicator != .system {
                if outcome == nil { model.cycle.acknowledge() }
                else { model.cycle.complete(succeeded: !failed) }
                positionIndicator()
                if indicator == .progressRing && !UIAccessibility.isReduceMotionEnabled {
                    await presentation.finishPresentation(startedAt: CACurrentMediaTime(),
                        minimumDuration: ProgressRingRefreshIndicator.transitionDuration)
                    guard !Task.isCancelled, activeRequest == request else { return false }
                }
                feedback?(event)
                // A timed check acknowledges the request, never announces that
                // data has finished updating when the provider is still running.
                UIAccessibility.post(notification: .announcement,
                    argument: failed ? model.labels.failed : (outcome == nil ? model.labels.refreshing : model.labels.succeeded))
                await presentation.finishPresentation(startedAt: CACurrentMediaTime(),
                    minimumDuration: indicator == .progressRing ? ProgressRingRefreshIndicator.resultHoldDuration : 0.65)
                guard !Task.isCancelled, activeRequest == request else { return false }
                model.cycle.returnToRest()
            } else {
                feedback?(event)
            }
            return true
        }

        private func presentTimedRefresh(request: UUID, duration: Duration,
                                         action: @escaping @MainActor @Sendable () async throws -> Void) async {
            let outcome: RefreshAction.Outcome?
            do {
                outcome = try await backgroundRefresh.present(for: duration, action: action, onCompletion: { [weak self] result in
                    // This callback can arrive after the animation is gone.
                    // RefreshAction still reports the original failure, and
                    // ownership cancellation suppresses obsolete callbacks.
                    if result == .failed { self?.onFailure?() }
                })
            } catch is CancellationError {
                // The presentation timer only throws for lifecycle cancellation.
                return
            } catch {
                OathDiagnostics.record(error, component: "OathNativeRefresh", operation: "briefPresentation")
                if activeRequest == request { stop() }
                return
            }
            guard !Task.isCancelled, activeRequest == request else { return }
            guard outcome != .cancelled else { stop(); return }
            // A pending action acknowledges this gesture at the fixed deadline;
            // the separately owned provider task continues and publishes data.
            guard await presentResult(request: request, outcome: outcome) else { return }
            attachedScroll?.refreshControl?.endRefreshing()
            activeRequest = nil
            work = nil
            scrollViewDidScroll(scroll)
        }
    }
}

/// A background anchor affects neither content sizing nor hit testing.
private final class RefreshScrollAnchor: UIView {
    var attached: (() -> Void)?
    override func didMoveToWindow() { super.didMoveToWindow(); attached?() }
    override func didMoveToSuperview() { super.didMoveToSuperview(); attached?() }
}
