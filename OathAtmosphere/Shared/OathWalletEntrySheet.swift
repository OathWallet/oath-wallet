import SwiftUI
import UIKit

enum OathWalletEntrySize { case fitted, atLeastMedium, large }

/// A single sheet owns the detents and the focus barrier across all its entry pages.
@MainActor final class OathWalletEntryPresentation {
    let autofocus = OathAutofocusPresentation()
    private weak var sheet: UISheetPresentationController?
    private var size: OathWalletEntrySize?
    private var height: CGFloat = 0
    private let identifier = UISheetPresentationController.Detent.Identifier("oath.addWallet")

    func needsInitialSize(for target: UISheetPresentationController) -> Bool { sheet !== target }

    func resize(_ target: UISheetPresentationController, size: OathWalletEntrySize,
                height: CGFloat, reduceMotion: Bool) {
        let first = sheet !== target
        let changesDetents = first || self.size != size
        guard changesDetents || self.height != height else { return }
        sheet = target
        self.size = size
        self.height = height
        let changes = {
            if !changesDetents {
                target.invalidateDetents()
                return
            }
            if size == .large {
                target.detents = [.large()]
                target.selectedDetentIdentifier = .large
            } else {
                let fitted = UISheetPresentationController.Detent.custom(identifier: self.identifier) { [weak self] context in
                    let minimum = size == .atLeastMedium
                        ? UISheetPresentationController.Detent.medium().resolvedValue(in: context) ?? context.maximumDetentValue
                        : 0
                    return min(max(self?.height ?? context.maximumDetentValue, minimum), context.maximumDetentValue)
                }
                target.detents = size == .atLeastMedium ? [fitted, .large()] : [fitted]
                target.selectedDetentIdentifier = self.identifier
            }
            target.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        if first || reduceMotion {
            changes()
        } else {
            let token = autofocus.begin()
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak autofocus] in
                Task { @MainActor in autofocus?.end(token) }
            }
            target.animateChanges(changes)
            CATransaction.commit()
        }
    }
}

extension EnvironmentValues {
    @Entry var oathWalletEntryPresentation: OathWalletEntryPresentation? = nil
}

extension View {
    /// Apply to the natural content inside a scroll view, or to a full-height list.
    func oathWalletEntryContent(_ size: OathWalletEntrySize = .fitted) -> some View {
        modifier(OathWalletEntryContent(size: size))
    }
}

private struct OathWalletEntryContent: ViewModifier {
    let size: OathWalletEntrySize
    @Environment(\.oathWalletEntryPresentation) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let presentation {
            content
                .fixedSize(horizontal: false, vertical: size != .large)
                .background {
                    GeometryReader { geometry in
                        OathWalletEntrySheet(presentation: presentation, size: size,
                            height: geometry.size.height, reduceMotion: reduceMotion)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            content
        }
    }
}

private struct OathWalletEntrySheet: UIViewControllerRepresentable {
    let presentation: OathWalletEntryPresentation
    let size: OathWalletEntrySize
    let height: CGFloat
    let reduceMotion: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.measure = { sheet, navigationHeight, appeared in
            guard appeared || presentation.needsInitialSize(for: sheet),
                  size == .large || (height.isFinite && height > 0) else { return }
            presentation.resize(sheet, size: size, height: size == .large ? 0 : ceil(height + navigationHeight),
                                reduceMotion: reduceMotion)
        }
        controller.scheduleUpdate()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.measure = nil }

    final class Controller: UIViewController {
        var measure: ((UISheetPresentationController, CGFloat, Bool) -> Void)?
        private var appearing = false
        private var visible = false
        private var scheduled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            appearing = true
            scheduleUpdate()
        }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            visible = true
            scheduleUpdate()
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            appearing = false
            visible = false
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            scheduleUpdate()
        }
        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                guard self.appearing, self.viewIfLoaded?.window != nil, let measure = self.measure else { return }
                var ancestor = self.parent
                while let controller = ancestor {
                    if controller.presentingViewController?.presentedViewController === controller,
                       let sheet = controller.presentationController as? UISheetPresentationController {
                        guard !controller.isBeingDismissed else { return }
                        // Measure the bar independently of the scrolling form and keyboard.
                        let bar = self.navigationController?.navigationBar
                        let height = bar.map { $0.convert($0.bounds, to: controller.view).maxY } ?? 0
                        measure(sheet, max(controller.view.safeAreaInsets.top, height), self.visible)
                        return
                    }
                    ancestor = controller.parent
                }
            }
        }
    }
}
