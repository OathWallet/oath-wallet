import OathDiagnostics
import SwiftUI
import UIKit

/// Native controls hosted in a system safe-area bar. The chain button
/// uses native constraints to follow the field through initial presentation and
/// keyboard changes. No field overlays, frame copying or custom background.
struct OathAssetSearchBar: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let prompt: String
    let chain: OathImportChain?
    let chainTitle: String
    let chainLabel: String
    var onCancel: (() -> Void)? = nil
    let chooseChain: (_ wasSearching: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SearchRow {
        let row = SearchRow()
        let bar = row.searchBar
        bar.delegate = context.coordinator
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.spellCheckingType = .no
        bar.searchTextField.smartQuotesType = .no
        bar.searchTextField.smartDashesType = .no
        bar.searchTextField.adjustsFontForContentSizeCategory = true
        bar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }

    func updateUIView(_ row: SearchRow, context: Context) {
        let bar = row.searchBar
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.updating = true
        defer { coordinator.updating = false }
        coordinator.focus.update(focused: focused, enabled: context.environment.isEnabled)
        let direction: UISemanticContentAttribute = context.environment.oathLanguage.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
        row.configure(chain: chain, title: chainTitle, label: chainLabel, direction: direction,
                      scale: context.environment.displayScale, action: chooseChain)
        row.configureClose(label: context.environment.oathLocalizer.text(.close),
                           action: onCancel == nil ? nil : { [weak coordinator, weak bar] in
            guard let coordinator, let bar else { return }
            coordinator.cancelSearch(bar)
        })
        row.isUserInteractionEnabled = context.environment.isEnabled
        bar.semanticContentAttribute = direction
        bar.searchTextField.semanticContentAttribute = direction
        bar.searchTextField.textAlignment = .natural
        OathSearchFieldLayout.normalizeLeadingImage(in: bar, rightToLeft: context.environment.oathLanguage.isRightToLeft)
        bar.tintColor = .label
        bar.placeholder = prompt
        bar.searchTextField.font = .preferredFont(forTextStyle: .body)
        bar.searchTextField.accessibilityIdentifier = "search.asset.field"
        bar.searchTextField.accessibilityLabel = prompt
        bar.isUserInteractionEnabled = context.environment.isEnabled
        if bar.text != text, bar.searchTextField.markedTextRange == nil || text.isEmpty {
            if text.isEmpty { bar.searchTextField.unmarkText(); bar.searchTextField.undoManager?.removeAllActions() }
            bar.text = text
        }
        // UISearchBar's Cancel belongs to editing and UIKit disables it when
        // editing ends. Home owns a separate native Close for screen dismissal.
        let showsCancel = onCancel == nil && (focused || !text.isEmpty)
        if bar.showsCancelButton != showsCancel {
            bar.setShowsCancelButton(showsCancel, animated: bar.window != nil)
        }
        bar.wantsFocus = focused && context.environment.isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SearchRow, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: max(0, width), height: max(56, ceil(UIFont.preferredFont(forTextStyle: .body).lineHeight + 24)))
    }

    static func dismantleUIView(_ row: SearchRow, coordinator: Coordinator) {
        let bar = row.searchBar
        row.action = nil
        row.closeAction = nil
        coordinator.focus.invalidate()
        bar.delegate = nil
        bar.wantsFocus = false
        bar.searchTextField.resignFirstResponder()
    }

    final class SearchRow: UIView {
        let searchBar = SearchBar()
        let chainButton = UIButton(type: .system)
        let closeButton = UIButton(type: .close)
        var action: ((Bool) -> Void)?
        var closeAction: (() -> Void)?
        private var configurationID = ""
        private lazy var fullWidthSearch = searchBar.trailingAnchor.constraint(equalTo: trailingAnchor)
        private lazy var searchBesideClose = searchBar.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isAccessibilityElement = false
            addSubview(chainButton)
            addSubview(searchBar)
            addSubview(closeButton)
            chainButton.translatesAutoresizingMaskIntoConstraints = false
            searchBar.translatesAutoresizingMaskIntoConstraints = false
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.isHidden = true
            chainButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            chainButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            searchBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
            searchBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let minimumWidth = chainButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44)
            minimumWidth.priority = .defaultHigh
            // UIKit owns the field and its constraints. Constrain only our
            // sibling button to the public field anchors, without changing or
            // laying out any search-bar-managed view from another subtree.
            NSLayoutConstraint.activate([
                chainButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                chainButton.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
                minimumWidth,
                chainButton.centerYAnchor.constraint(equalTo: searchBar.searchTextField.centerYAnchor),
                chainButton.heightAnchor.constraint(equalTo: searchBar.searchTextField.heightAnchor),
                searchBar.leadingAnchor.constraint(equalTo: chainButton.trailingAnchor),
                fullWidthSearch,
                searchBar.topAnchor.constraint(equalTo: topAnchor),
                searchBar.bottomAnchor.constraint(equalTo: bottomAnchor),
                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                closeButton.centerYAnchor.constraint(equalTo: searchBar.searchTextField.centerYAnchor),
                closeButton.heightAnchor.constraint(equalTo: searchBar.searchTextField.heightAnchor),
                closeButton.widthAnchor.constraint(equalTo: closeButton.heightAnchor)
            ])
            chainButton.addTarget(self, action: #selector(selectChain), for: .touchUpInside)
            chainButton.accessibilityIdentifier = "search.chain.filter"
            chainButton.titleLabel?.lineBreakMode = .byTruncatingTail
            chainButton.titleLabel?.adjustsFontForContentSizeCategory = true
            var closeConfiguration: UIButton.Configuration
            if #available(iOS 26, *) { closeConfiguration = .glass() }
            else { closeConfiguration = .gray() }
            closeConfiguration.cornerStyle = .capsule
            closeConfiguration.baseForegroundColor = .label
            closeConfiguration.image = UIImage(systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            closeButton.configuration = closeConfiguration
            closeButton.accessibilityIdentifier = "search.asset.close"
            closeButton.addTarget(self, action: #selector(closeSearch), for: .touchUpInside)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        func configureClose(label: String, action: (() -> Void)?) {
            closeAction = action
            closeButton.accessibilityLabel = label
            let visible = action != nil
            guard closeButton.isHidden == visible else { return }
            fullWidthSearch.isActive = false
            searchBesideClose.isActive = false
            closeButton.isHidden = !visible
            if visible { searchBesideClose.isActive = true }
            else { fullWidthSearch.isActive = true }
        }

        @objc private func closeSearch() { closeAction?() }

        func configure(chain: OathImportChain?, title: String, label: String,
                       direction: UISemanticContentAttribute, scale: CGFloat, action: @escaping (Bool) -> Void) {
            self.action = action
            semanticContentAttribute = direction
            chainButton.semanticContentAttribute = direction
            let id = "\(chain?.id ?? "all"):\(title):\(label):\(scale):\(traitCollection.preferredContentSizeCategory.rawValue)"
            if id != configurationID {
                configurationID = id
                var config: UIButton.Configuration
                if #available(iOS 26, *) { config = .glass() }
                else { config = .gray() }
                config.title = title
                config.baseForegroundColor = .label
                config.imagePadding = 5
                config.contentInsets = .init(top: 0, leading: 14, bottom: 0, trailing: 14)
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var attributes = attributes
                    let font = UIFont.preferredFont(forTextStyle: .subheadline)
                    attributes.font = UIFont(descriptor: font.fontDescriptor.addingAttributes([
                        .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.medium]
                    ]), size: 0)
                    return attributes
                }
                if let chain {
                    config.image = OathNetworkLogo.renderedImage(asset: chain.logoAsset, size: 20, scale: scale)
                    if config.image == nil {
                        OathDiagnostics.record(DiagnosticFailure("missing_chain_logo"), component: "asset_search",
                            operation: "load_chain_logo", context: ["chain": chain.id])
                    }
                } else {
                    config.image = UIImage(systemName: "square.grid.2x2",
                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 20))
                }
                chainButton.configuration = config
                chainButton.accessibilityLabel = label
                chainButton.accessibilityValue = title
            }
            setNeedsLayout()
        }

        @objc private func selectChain() {
            // Capture actual editing before resignation delivers focus=false.
            let wasSearching = searchBar.searchTextField.isFirstResponder
            searchBar.searchTextField.resignFirstResponder()
            action?(wasSearching)
        }
    }

    final class SearchBar: UISearchBar {
        var wantsFocus = false { didSet { if wantsFocus != oldValue { synchronizeFocus() } } }
        private var focusScheduled = false
        override func didMoveToWindow() { super.didMoveToWindow(); synchronizeFocus() }
        private func synchronizeFocus() {
            guard !focusScheduled else { return }
            focusScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.focusScheduled = false
                guard self.window != nil else { return }
                if self.wantsFocus, !self.searchTextField.isFirstResponder { self.searchTextField.becomeFirstResponder() }
                else if !self.wantsFocus, self.searchTextField.isFirstResponder { self.searchTextField.resignFirstResponder() }
            }
        }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: OathAssetSearchBar
        var updating = false
        let focus = OathTextInputFocus()
        init(_ parent: OathAssetSearchBar) { self.parent = parent }
        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            guard !updating else { return }
            parent.text = searchText
        }
        func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { reportFocus(true, from: searchBar) }
        func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { reportFocus(false, from: searchBar) }
        private func reportFocus(_ value: Bool, from bar: UISearchBar) {
            focus.receive(value) { [weak self, weak bar] value in
                guard let self, let bar, bar.delegate === self,
                      bar.searchTextField.isFirstResponder == value, self.parent.focused != value else { return }
                self.parent.focused = value
            }
        }
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { endEditing(searchBar) }
        func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
            cancelSearch(searchBar)
        }
        func cancelSearch(_ searchBar: UISearchBar) {
            parent.text = ""
            searchBar.text = ""
            endEditing(searchBar)
            // Cancelling the search is distinct from losing keyboard focus
            // (for example, when opening the chain picker).
            parent.onCancel?()
        }
        private func endEditing(_ bar: UISearchBar) {
            focus.cancelPending()
            parent.focused = false
            bar.searchTextField.resignFirstResponder()
        }
    }
}
