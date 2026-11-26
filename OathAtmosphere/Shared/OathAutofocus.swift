import SwiftUI
import UIKit

extension View {
    /// Use for automatic entry focus only. Taps, Return-to-next-field and the
    /// shared keyboard's Done action continue to respond immediately.
    func oathAutofocus(when ready: Bool = true, onDisappear: (@MainActor () -> Void)? = nil,
                       _ focus: @escaping @MainActor () -> Void) -> some View {
        modifier(OathAutofocusModifier(ready: ready, focus: focus, resign: onDisappear))
    }

    /// Run once after native appearance and any enclosing transition have completed.
    /// Modal readiness may ignore decorative SwiftUI animations that never end.
    func oathAfterAppearance(when ready: Bool = true, waitForContentAnimations: Bool = true,
                             _ action: @escaping @MainActor () -> Void) -> some View {
        modifier(OathAutofocusModifier(ready: ready, focus: action, waitForContentAnimations: waitForContentAnimations))
    }
}

private struct OathAutofocusPresentationKey: EnvironmentKey {
    static let defaultValue: OathAutofocusPresentation? = nil
}

private struct OathInputFocusGateKey: EnvironmentKey {
    static let defaultValue: OathAutofocusGate? = nil
}

extension EnvironmentValues {
    var oathInputFocusGate: OathAutofocusGate? {
        get { self[OathInputFocusGateKey.self] }
        set { self[OathInputFocusGateKey.self] = newValue }
    }
    var oathAutofocusPresentation: OathAutofocusPresentation? {
        get { self[OathAutofocusPresentationKey.self] }
        set { self[OathAutofocusPresentationKey.self] = newValue }
    }
}

private struct OathAutofocusModifier: ViewModifier {
    let ready: Bool
    let focus: @MainActor () -> Void
    var resign: (@MainActor () -> Void)? = nil
    var waitForContentAnimations = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.oathAutofocusPresentation) private var presentation
    @State private var gate = OathAutofocusGate()

    func body(content: Content) -> some View {
        content
            .environment(\.oathInputFocusGate, resign == nil ? nil : gate)
            .background {
                OathAutofocusLifecycle(gate: gate, presentation: presentation,
                    enabled: ready && enabled, active: scenePhase == .active, focus: focus, resign: resign)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .transaction { [gate] transaction in
                // Covers a form swapped into an already visible sheet as well
                // as SwiftUI transitions without a new navigation controller.
                guard waitForContentAnimations, transaction.animation != nil else { return }
                let token = gate.beginAnimation()
                transaction.addAnimationCompletion(criteria: .removed) { [weak gate] in
                    Task { @MainActor in gate?.endAnimation(token) }
                }
            }
    }
}

private struct OathAutofocusLifecycle: UIViewControllerRepresentable {
    let gate: OathAutofocusGate
    let presentation: OathAutofocusPresentation?
    let enabled: Bool
    let active: Bool
    let focus: @MainActor () -> Void
    let resign: (@MainActor () -> Void)?

    func makeUIViewController(context: Context) -> Controller { Controller(gate: gate) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.observe(presentation)
        controller.resign = resign
        gate.update(enabled: enabled, active: active) { [weak controller] in
            guard let controller, controller.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                  !controller.isBeingDismissed, !controller.isMovingFromParent else { return }
            focus()
        }
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.cancel() }

    final class Controller: UIViewController {
        var resign: (@MainActor () -> Void)?
        private let gate: OathAutofocusGate
        private var presentation: OathAutofocusPresentation?
        private var observation: UUID?

        init(gate: OathAutofocusGate) {
            self.gate = gate
            super.init(nibName: nil, bundle: nil)
            gate.activate()
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            // A child added to an existing host can appear while an ancestor
            // is still presenting. UIKit supplies that ancestor's coordinator.
            // Register before completion dispatch starts, not in viewDidAppear.
            if let transition = transitionCoordinator {
                let token = gate.beginAnimation()
                let registered = transition.animate(alongsideTransition: nil) { [weak gate] _ in
                    gate?.endAnimation(token)
                }
                if !registered { gate.endAnimation(token) }
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            gate.setAppeared(true)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            gate.setAppeared(false)
            guard let resign else { return }
            // End editing on this destination as native Back starts, not after
            // SwiftUI's onDisappear (when the page may already be offscreen).
            // Do not end editing in another window or incoming destination.
            var screen: UIViewController = self
            while let parent = screen.parent, !(parent is UINavigationController) { screen = parent }
            screen.viewIfLoaded?.endEditing(true)
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.gate.permitsResponder else { return }
                resign()
            }
        }

        func observe(_ presentation: OathAutofocusPresentation?) {
            guard self.presentation !== presentation else { return }
            if let observation { self.presentation?.removeObserver(observation) }
            self.presentation = presentation
            observation = presentation?.observe { [weak gate] in gate?.setPresentationReady($0) }
            if presentation == nil { gate.setPresentationReady(true) }
        }

        func cancel() {
            if let observation { presentation?.removeObserver(observation) }
            observation = nil
            presentation = nil
            gate.invalidate()
        }
    }
}
