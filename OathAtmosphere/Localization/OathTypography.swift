import OathDiagnostics
import SwiftUI
import UIKit

/// iOS 27 can stop status-style delegation at SwiftUI's navigation controller:
/// the destination requests lightContent but the container returns default.
/// Forward through the documented container API to the visible destination.
/// This preserves SwiftUI's per-screen preference, including scrolling, without
/// changing the window theme, navigation background, or presented sheet theme.
/// https://developer.apple.com/documentation/technotes/tn3105-customizing-uistatusbar-syle
struct OathStatusBarHost<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        // Build in the caller's SwiftUI update so scene/settings observations
        // remain attached to that update rather than a deferred UIKit callback.
        self.content = content()
    }

    func makeUIViewController(context: Context) -> Controller {
        Controller(rootView: content)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.rootView = content
    }

    final class Controller: UIHostingController<Content> {
        override var childForStatusBarStyle: UIViewController? {
            var candidate = super.childForStatusBarStyle
            var visited = Set<ObjectIdentifier>()
            while let current = candidate, current !== self,
                  visited.insert(ObjectIdentifier(current)).inserted {
                if let navigation = current as? UINavigationController {
                    return navigation.visibleViewController
                }
                guard let child = current.childForStatusBarStyle else { return current }
                candidate = child
            }
            return nil
        }
    }
}

extension View {
    /// Native system fonts in every language. Text styles retain Dynamic Type;
    /// callers providing an explicit size own any scaling through ScaledMetric.
    func oathFont(_ style: Font.TextStyle, weight: Font.Weight = .regular,
                  size: CGFloat? = nil) -> some View {
        font(size.map { .system(size: $0, weight: weight) }
             ?? .system(style, design: .default, weight: weight))
    }

    func oathNativeLocalization(navigationTint: UIColor? = nil, onArtwork: Bool = false,
                                navigationBackground: Visibility = .automatic,
                                navigationMaterial: Material? = .regular,
                                systemNavigationAppearance: Bool = false, systemBackButton: Bool = false,
                                file: StaticString = #fileID, line: UInt = #line) -> some View {
        background { OathNativeLocalizationChrome(
            navigationTint: systemNavigationAppearance ? nil : navigationTint ?? (onArtwork ? .white : .label),
            systemBackButton: systemBackButton) }
            // Native symbol-only buttons read SwiftUI tint, while UIKit back
            // items read the bar tint. Set both to avoid a blue inherited accent
            // reappearing when navigation/Face ID rebuilds the native toolbar.
            .tint(systemNavigationAppearance ? nil : Color(uiColor: navigationTint ?? (onArtwork ? .white : .label)))
            .modifier(OathNativeNavigationAppearance(onArtwork: onArtwork, background: navigationBackground,
                                                      material: navigationMaterial, systemAppearance: systemNavigationAppearance))
            .modifier(OathDiagnosticScreen(file: file, line: line, active: true))
    }
}

/// Destination-scoped native chrome. Never attach an artwork preference to a
/// NavigationStack itself: it would also style the neutral screens pushed on it.
private struct OathNativeNavigationAppearance: ViewModifier {
    let onArtwork: Bool
    let background: Visibility
    let material: Material?
    let systemAppearance: Bool
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            navigationAppearance(content)
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarBackgroundVisibility(background, for: .navigationBar)
        } else {
            navigationAppearance(content)
                .statusBarHidden(false)
                .toolbarBackground(background, for: .navigationBar)
        }
    }

    @ViewBuilder private func navigationAppearance(_ content: Content) -> some View {
        if systemAppearance {
            // Leave navigation contrast to the system.
            navigationContent(content)
        } else {
            navigationContent(content)
                .toolbarColorScheme(onArtwork ? .dark : colorScheme, for: .navigationBar)
        }
    }

    @ViewBuilder private func navigationContent(_ content: Content) -> some View {
        if let material {
            content.toolbarBackground(material, for: .navigationBar)
        } else {
            // Leave the native scroll-edge appearance in charge. A clear fill
            // would override it too, rather than restoring system behavior.
            content
        }
    }
}

/// Keep the magnifier in UITextField's leading overlay. UIKit can assign it
/// to the trailing slot for an in-app RTL language, where it suppresses Clear.
/// Only relocate the built-in image; never replace custom trailing controls.
@MainActor enum OathSearchFieldLayout {
    static func normalizeLeadingImage(in searchBar: UISearchBar, rightToLeft: Bool) {
        let field = searchBar.searchTextField
        guard rightToLeft, !searchBar.showsBookmarkButton,
              let icon = field.rightView as? UIImageView else { return }
        let mode = field.rightViewMode
        field.rightView = nil
        field.rightViewMode = .never
        if field.leftView == nil {
            field.leftView = icon
            field.leftViewMode = mode
        }
    }
}

/// Uses UIKit's native semantic direction and appearance APIs for navigation
/// chrome that lives outside SwiftUI stacks. Never replaces gesture delegates,
/// swaps coordinates, flips transforms, or rebuilds the navigation hierarchy.
private struct OathNativeLocalizationChrome: UIViewControllerRepresentable {
    @Environment(\.oathLanguage) private var language
    let navigationTint: UIColor?
    let systemBackButton: Bool

    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.language = language
        controller.navigationTint = navigationTint
        controller.systemBackButton = systemBackButton
        controller.apply()
    }

    final class Controller: UIViewController {
        var language = OathLanguage.english
        var navigationTint: UIColor?
        var systemBackButton = false
        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            NotificationCenter.default.addObserver(self, selector: #selector(searchBeganEditing),
                name: UITextField.textDidBeginEditingNotification, object: nil)
        }
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); apply() }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); apply() }

        func apply() {
            OathLayoutDirection.apply(language, to: self)
            if let tabBar = tabBarController?.tabBar { OathTabBarStyle.apply(to: tabBar) }
            guard let navigation = navigationController else { return }
            OathLayoutDirection.apply(language, to: navigation)
            OathLayoutDirection.apply(language, to: navigation.navigationBar)
            let bar = navigation.navigationBar
            // Clear a previous destination's explicit tint when returning to
            // system-managed chrome; otherwise artwork white can remain stuck.
            if bar.tintColor != navigationTint { bar.tintColor = navigationTint }
            for controller in navigation.viewControllers {
                OathLayoutDirection.apply(language, to: controller)
            }
            // The source item's configuration controls Back on the *next*
            // destination. Style only our own item; a pushed screen must never
            // rewrite Home's or Asset Detail's native Back presentation.
            var owner = parent
            while let candidate = owner, !navigation.viewControllers.contains(where: { $0 === candidate }) {
                owner = candidate.parent
            }
            if let item = owner?.navigationItem {
                let displayMode: UINavigationItem.BackButtonDisplayMode = systemBackButton ? .default : .minimal
                let backTitle = systemBackButton ? nil : OathLocalizer(language).text(.back)
                if item.backButtonDisplayMode != displayMode { item.backButtonDisplayMode = displayMode }
                if item.backButtonTitle != backTitle { item.backButtonTitle = backTitle }
            }
            if let searchBar = navigation.topViewController?.navigationItem.searchController?.searchBar {
                OathLayoutDirection.apply(language, to: searchBar)
                let field = searchBar.searchTextField
                OathKeyboardAccessory.removeFromSearch(field)
                OathLayoutDirection.apply(language, to: field)
                OathSearchFieldLayout.normalizeLeadingImage(in: searchBar, rightToLeft: language.isRightToLeft)
                let font = UIFont.preferredFont(forTextStyle: .body)
                field.adjustsFontForContentSizeCategory = true
                if field.font != font { field.font = font }
            }
        }

        @objc private func searchBeganEditing(_ notification: Notification) {
            guard let field = notification.object as? UISearchTextField,
                  let window = view.window, field.window === window else { return }
            OathKeyboardAccessory.removeFromSearch(field)
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

/// Fixed source labels only; no screen text or model values enter diagnostics.
private struct OathDiagnosticScreen: ViewModifier {
    let file: StaticString
    let line: UInt
    let active: Bool
    @State private var token = UUID()
    func body(content: Content) -> some View {
        content.onAppear { if active { OathDiagnostics.screenAppeared(token, file: file, line: line) } }
            .onChange(of: active) { _, active in
                if active { OathDiagnostics.screenAppeared(token, file: file, line: line) }
                else { OathDiagnostics.screenDisappeared(token) }
            }
            .onDisappear { OathDiagnostics.screenDisappeared(token) }
    }
}

extension View {
    func oathDiagnosticsScreen(active: Bool = true, file: StaticString = #fileID, line: UInt = #line) -> some View {
        modifier(OathDiagnosticScreen(file: file, line: line, active: active))
    }
}
