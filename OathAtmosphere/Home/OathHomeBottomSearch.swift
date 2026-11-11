import SwiftUI
import UIKit

enum OathHomeTab: Hashable { case wallet, history, browser, search }

/// Install inside the Wallet tab, before Search can be selected. SwiftUI's tab
/// selection transaction does not animate the UIKit content-controller change.
/// Keep SwiftUI's delegate in the chain so selection, search and tab ownership
/// continue to belong to TabView; only supply the entry animation for Search.
struct OathSearchTabTransition: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.install() }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.detach() }

    final class Controller: UIViewController {
        private let transitionDelegate = Delegate()
        private weak var owner: UITabBarController?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            install()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        func install() {
            guard let tabs = tabBarController else { return }
            if owner !== tabs { detach(); owner = tabs }
            guard tabs.delegate !== transitionDelegate else { return }
            // A replacement Wallet root can attach before its old bridge is
            // dismantled. Forward to the original owner, never another bridge.
            if let previous = tabs.delegate as? Delegate {
                transitionDelegate.forwarded = previous.forwarded
            } else {
                transitionDelegate.forwarded = tabs.delegate
            }
            tabs.delegate = transitionDelegate
        }

        func detach() {
            if let owner, owner.delegate === transitionDelegate { owner.delegate = transitionDelegate.forwarded }
            transitionDelegate.forwarded = nil
            owner = nil
        }
    }

    private final class Delegate: NSObject, UITabBarControllerDelegate {
        weak var forwarded: (any UITabBarControllerDelegate)?

        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { forwarded?.responds(to: selector) == true }
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            // UIKit queries and invokes its controller delegate on the main thread.
            let target = MainActor.assumeIsolated { forwarded }
            return target?.responds(to: selector) == true ? target : super.forwardingTarget(for: selector)
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              animationControllerForTransitionFrom fromVC: UIViewController,
                              to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
            // Modern tabs do not use the legacy viewControllers collection.
            // Identify the native search role; iOS 17 declares Search last.
            let isSearch: Bool
            if #available(iOS 18, *) {
                isSearch = toVC.tab is UISearchTab
            } else {
                isSearch = tabBarController.viewControllers?.last === toVC
            }
            // Leaving Search retains the existing asset/Close routing.
            if isSearch, fromVC !== toVC {
                return SearchAnimator()
            }
            return forwarded?.tabBarController?(tabBarController, animationControllerForTransitionFrom: fromVC, to: toVC)
        }

        func tabBarController(_ tabBarController: UITabBarController,
                              interactionControllerFor animationController: any UIViewControllerAnimatedTransitioning)
            -> (any UIViewControllerInteractiveTransitioning)? {
            if animationController is SearchAnimator { return nil }
            return forwarded?.tabBarController?(tabBarController, interactionControllerFor: animationController)
        }
    }

    private final class SearchAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.25 }

        func animateTransition(using context: any UIViewControllerContextTransitioning) {
            // UIKit may omit views during controller teardown. Complete that
            // cancelled lifecycle without reporting a user action as an error.
            guard let destination = context.viewController(forKey: .to),
                  let toView = context.view(forKey: .to), let fromView = context.view(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            toView.frame = context.finalFrame(for: destination)
            UIView.transition(with: context.containerView, duration: transitionDuration(using: context),
                              options: [.transitionCrossDissolve, .curveEaseInOut]) {
                fromView.removeFromSuperview()
                context.containerView.addSubview(toView)
            } completion: { _ in
                if context.transitionWasCancelled {
                    toView.removeFromSuperview()
                    context.containerView.addSubview(fromView)
                }
                context.completeTransition(!context.transitionWasCancelled)
            }
        }
    }
}

/// Own only native tab icon colors; retain the system's glass and selection pill.
@MainActor enum OathTabBarStyle {
    static let walletSymbol = UIImage(systemName: "wallet.bifold") == nil ? "wallet.pass" : "wallet.bifold"
    static let selectedColor = UIColor.label
    static let unselectedColor = makeUnselectedColor()

    // Native color providers can be evaluated off the main thread.
    nonisolated private static func makeUnselectedColor() -> UIColor {
        UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 0.68 : 0.35, alpha: 1)
        }
    }

    static func apply(to bar: UITabBar) {
        if bar.tintColor != selectedColor { bar.tintColor = selectedColor }
        if bar.unselectedItemTintColor != unselectedColor { bar.unselectedItemTintColor = unselectedColor }
        if let updated = updatedAppearance(bar.standardAppearance) { bar.standardAppearance = updated }
        if let current = bar.scrollEdgeAppearance, let updated = updatedAppearance(current) {
            bar.scrollEdgeAppearance = updated
        }
    }

    private static func updatedAppearance(_ original: UITabBarAppearance) -> UITabBarAppearance? {
        let layouts = [original.stackedLayoutAppearance, original.inlineLayoutAppearance,
                       original.compactInlineLayoutAppearance]
        guard layouts.contains(where: { $0.selected.iconColor != selectedColor || $0.normal.iconColor != unselectedColor })
        else { return nil }
        let copy = original.copy()
        for layout in [copy.stackedLayoutAppearance, copy.inlineLayoutAppearance, copy.compactInlineLayoutAppearance] {
            layout.selected.iconColor = selectedColor
            layout.normal.iconColor = unselectedColor
        }
        return copy
    }
}

/// The system search-role tab supplies the separate trailing control, keyboard,
/// cancellation and safe area. No floating field or toolbar spacer is installed.
struct OathSearchTabActivation: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.tabViewSearchActivation(.searchTabSelection)
        } else {
            content
        }
    }
}

/// Keep one search controller for history on the dedicated search stack.
/// Asset search supplies its own native bottom row and disables this controller.
/// Explicit toolbar placement prevents fallback to the navigation drawer when
/// native search deactivates or the selected search context changes.
/// The presentation binding lets navigation end history search through SwiftUI;
/// resigning the keyboard alone leaves the search controller active.
struct OathHomeSearchField: ViewModifier {
    @Binding var query: String
    @Binding var isPresented: Bool
    let prompt: String
    var isEnabled = true

    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(text: $query, isPresented: $isPresented, placement: .toolbar, prompt: Text(prompt))
        } else { content }
    }
}
