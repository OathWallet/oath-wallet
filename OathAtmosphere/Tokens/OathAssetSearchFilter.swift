import SwiftUI
import UIKit

/// Home asset search follows the keyboard at the bottom. Send/Receive use the
/// shared row's default top placement. Keep the keyboard safe area enabled so
/// the system positions this row; no keyboard notifications or offsets.
struct OathHomeAssetSearch: ViewModifier {
    @Binding var query: String
    @Binding var scope: OathAssetSearchScope
    @Binding var isPresented: Bool
    @Binding var selectedTab: OathHomeTab

    func body(content: Content) -> some View {
        content.modifier(OathAssetSearchFilter(query: $query, scope: $scope,
            searchPresentation: $isPresented, edge: .bottom, onCancel: {
                query = ""
                scope = .all
                isPresented = false
                selectedTab = .wallet
            }))
    }
}

/// The same native search row serves Home search and the Send/Receive pickers.
/// It belongs to the search screen, not the wallet's persistent asset filters.
struct OathAssetSearchFilter: ViewModifier {
    @Binding var query: String
    @Binding var scope: OathAssetSearchScope
    var searchPresentation: Binding<Bool>? = nil
    var permittedNetworks: Set<OathImportChain>? = nil
    var edge: VerticalEdge = .top
    var onCancel: (() -> Void)? = nil
    @State private var showsNetworks = false
    @State private var focused = false
    @State private var wasSearchingBeforeNetworks = false
    @State private var selectedNetwork = false
    @Environment(\.oathLocalizer) private var strings

    private var searchFocus: Binding<Bool> { searchPresentation ?? $focused }

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26, *) {
                content.safeAreaBar(edge: edge, spacing: 0) { searchRow }
            } else {
                content.safeAreaInset(edge: edge, spacing: 0) { searchRow }
            }
        }
            .sheet(isPresented: $showsNetworks, onDismiss: {
                // Resume only a search interrupted by choosing a chain. Wait
                // for dismissal so its search field no longer owns the keyboard.
                let resumeSearch = wasSearchingBeforeNetworks && selectedNetwork
                wasSearchingBeforeNetworks = false
                selectedNetwork = false
                if resumeSearch { searchFocus.wrappedValue = true }
            }) {
                OathSearchChainSheet(scope: $scope, permittedNetworks: permittedNetworks,
                                     onSelection: { selectedNetwork = true })
                    .oathLanguage(strings.language)
            }
            .onDisappear { searchFocus.wrappedValue = false }
    }

    private var searchRow: some View {
        OathAssetSearchBar(text: $query, focused: searchFocus,
            prompt: strings.text(.searchAssets), chain: scope.chain,
            chainTitle: scope.chain.map { strings.invariant($0.shortName) } ?? strings.text(.assetSearchAll),
            chainLabel: strings.text(.historyNetworks), onCancel: onCancel) { wasSearching in
                wasSearchingBeforeNetworks = wasSearching
                selectedNetwork = false
                searchFocus.wrappedValue = false
                OathHaptics.shared.play(.selection)
                showsNetworks = true
            }
            .padding(.horizontal, 12).padding(.bottom, 8)
        // safeAreaBar supplies the system scroll-edge treatment. An explicit
        // material/background here would introduce a separate frosted rectangle.
    }
}

private struct OathSearchChainSheet: View {
    @Binding var scope: OathAssetSearchScope
    let permittedNetworks: Set<OathImportChain>?
    let onSelection: () -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    private var networks: [OathImportChain] {
        let allowed = OathAssetSearchScope.all.networks(permitted: permittedNetworks)
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return OathImportChain.enabledCases.filter {
            allowed.contains($0) && (text.isEmpty || $0.searchTerms.localizedStandardContains(text))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                row(nil)
                ForEach(networks) { row($0) }
            }
            .id(strings.language.isRightToLeft)
            .listStyle(.plain).scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
            .navigationTitle(strings.text(.historyNetworks))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(strings.text(.assetFilterSearchNetworks)))
            .scrollDismissesKeyboard(.interactively)
            .toolbar { ToolbarItem(placement: .topBarLeading) {
                OathCloseButton { dismiss() }.accessibilityIdentifier("search.chain.close")
            } }
            .oathNativeLocalization()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .oathDiagnosticsScreen()
    }

    private func row(_ chain: OathImportChain?) -> some View {
        OathButton(feedback: .selection) {
            scope = .init(chain: chain)
            onSelection()
            dismiss()
        } label: {
            OathSettingsRow(title: chain.map { strings.invariant($0.name) } ?? strings.text(.assetSearchAll),
                icon: chain == nil ? "square.grid.2x2" : nil, accessory: .selection(scope.chain == chain),
                networkLogo: chain?.logoAsset)
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityAddTraits(scope.chain == chain ? .isSelected : [])
        .accessibilityIdentifier("search.chain." + (chain?.id ?? "all"))
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}
