import SwiftUI
import UIKit

/// Adds a downward-swipe shortcut to a native fullScreenCover. The cover owns
/// presentation, safe areas and dismissal animation; no custom modal or animator.
/// Pass the dismiss action from the flow's root, so pushed pages close the flow.
struct OathSwipeDownDismiss: UIViewControllerRepresentable {
    var isEnabled = true
    let dismiss: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.isDismissEnabled = isEnabled
        controller.onDismiss = dismiss
        controller.attach()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.detach()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var isDismissEnabled = true
        var onDismiss: (() -> Void)?
        private weak var modal: UIViewController?
        private weak var touchedScroll: UIScrollView?
        private var requestedDismissal = false
        private lazy var pan: UIPanGestureRecognizer = {
            let gesture = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
            gesture.maximumNumberOfTouches = 1
            gesture.cancelsTouchesInView = false
            gesture.delegate = self
            return gesture
        }()

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            attach()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            attach()
        }

        func attach() {
            // Not yet attached, covered by another screen, cancelled gestures
            // and teardown are normal lifecycle, not diagnostic failures. Never
            // log gesture samples or user input to OathDiagnostics.
            guard viewIfLoaded?.window != nil else { return }
            var owner: UIViewController = self
            while let parent = owner.parent { owner = parent }
            guard owner !== self, owner.presentingViewController != nil else { return }
            if modal !== owner {
                detach()
                modal = owner
                owner.view.addGestureRecognizer(pan)
            }
            pan.isEnabled = isDismissEnabled && !requestedDismissal
        }

        func detach() {
            pan.view?.removeGestureRecognizer(pan)
            touchedScroll = nil
            modal = nil
            requestedDismissal = false
        }

        private var canDismiss: Bool {
            guard isDismissEnabled, !requestedDismissal, let modal,
                  modal.viewIfLoaded?.window != nil, modal.presentingViewController != nil,
                  !modal.isBeingPresented, !modal.isBeingDismissed,
                  !modal.isModalInPresentation else { return false }
            return !hasActivePresentationOrTransition(modal)
        }

        private func hasActivePresentationOrTransition(_ controller: UIViewController) -> Bool {
            controller.presentedViewController != nil || controller.transitionCoordinator != nil ||
                controller.children.contains(where: hasActivePresentationOrTransition)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchedScroll = nil
            guard canDismiss, let modal else { return false }
            var ancestor = touch.view
            while let view = ancestor {
                // Editing, selection and adjustable controls retain their gestures.
                if view is UITextField || view is UITextView || view is UISlider || view is UISwitch { return false }
                if let scroll = view as? UIScrollView {
                    guard scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 1 else { return false }
                    if touchedScroll == nil { touchedScroll = scroll }
                }
                if view === modal.view { break }
                ancestor = view.superview
            }
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard canDismiss, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            return velocity.y > 0 && velocity.y > abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer === touchedScroll?.panGestureRecognizer
        }

        @objc private func drag(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended, canDismiss, let view = gesture.view else { return }
            let distance = gesture.translation(in: view)
            let velocity = gesture.velocity(in: view)
            let threshold = min(140, view.bounds.height * 0.18)
            guard distance.y > abs(distance.x), velocity.y >= 0,
                  distance.y >= threshold || (distance.y >= 50 && velocity.y >= 900) else { return }
            requestedDismissal = true
            view.endEditing(true)
            onDismiss?()
        }
    }
}
