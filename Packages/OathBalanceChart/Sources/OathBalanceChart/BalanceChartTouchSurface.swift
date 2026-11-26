#if os(iOS)
import SwiftUI
import UIKit

/// UIKit rejects vertical pans before recognition, leaving Home's scroll gesture
/// available. No private view-hierarchy inspection or global gesture overrides.
struct BalanceChartTouchSurface: UIViewRepresentable {
    var enabled: Bool
    var onMove: (Double) -> Void
    var onEnd: () -> Void
    func makeUIView(context: Context) -> TouchView { TouchView() }
    func updateUIView(_ view: TouchView, context: Context) {
        view.isUserInteractionEnabled = enabled
        view.onMove = onMove; view.onEnd = onEnd
    }
    static func dismantleUIView(_ view: TouchView, coordinator: ()) {
        view.onMove = nil; view.onEnd = nil
    }

    final class TouchView: UIView {
        var onMove: ((Double) -> Void)?
        var onEnd: (() -> Void)?
        private lazy var scrubPan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear; isAccessibilityElement = false
            scrubPan.maximumNumberOfTouches = 1
            addGestureRecognizer(scrubPan)
        }
        required init?(coder: NSCoder) { nil }
        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // UIKit also consults the touched view about its enclosing list's pan.
            guard gestureRecognizer === scrubPan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
            let velocity = scrubPan.velocity(in: self)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc private func pan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                guard bounds.width > 0 else { return }
                onMove?(min(1, max(0, gesture.location(in: self).x / bounds.width)))
            case .ended, .cancelled, .failed: onEnd?()
            default: break
            }
        }
    }
}
#endif
