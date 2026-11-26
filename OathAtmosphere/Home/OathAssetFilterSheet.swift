import SwiftUI
import UIKit
import OathDatabase
import OathDiagnostics

extension PortfolioFilter.Sort {
    var title: OathStringKey {
        switch self {
        case .recommended: .assetFilterRecommended
        case .highestValue: .assetFilterHighestValue
        case .lowestValue: .assetFilterLowestValue
        case .nameAscending: .assetFilterNameAscending
        case .nameDescending: .assetFilterNameDescending
        case .mostActive: .assetFilterMostActive
        }
    }
}

/// Native controls apply immediately through a session-owned, serialized writer.
/// Closing or navigating within the sheet never discards a valid selection.
struct OathAssetFilterSheet: View {
    let session: OathWalletSession
    let walletID: String
    let currency: String
    @State private var management: ManagedAssetsSnapshot?
    private let filters: OathAssetFilterModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    init(session: OathWalletSession, walletID: String, currency: String, selection: PortfolioFilter) {
        self.session = session; self.walletID = walletID; self.currency = currency
        filters = session.assetFilterEditor(walletID: walletID, currency: currency, selection: selection)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<PortfolioFilter, Value>) -> Binding<Value> {
        Binding(get: { filters.selection[keyPath: keyPath] }, set: { filters.set(keyPath, to: $0) })
    }

    private var networks: [OathImportChain] {
        Set((session.portfolio?.accounts ?? []).compactMap { OathImportChain(rawValue: $0.networkID) }).filter(\.isEnabled)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var networkLabel: String {
        if filters.selection.networkIDs.isEmpty { return strings.text(.assetFilterAllNetworks) }
        if filters.selection.networkIDs.count == 1, let network = networks.first(where: { filters.selection.networkIDs.contains($0.id) }) {
            return strings.invariant(network.name)
        }
        return strings.format(.historySelectedCount, strings.number(filters.selection.networkIDs.count))
    }

    var body: some View {
        NavigationStack {
            OathAssetFilterSettingsPage {
                NavigationLink {
                    OathAssetFilterChoices(title: .assetFilterSort,
                        choices: PortfolioFilter.Sort.allCases, selection: binding(\.sort), titleForChoice: { $0.title })
                } label: {
                    OathSettingsRow(title: strings.text(.assetFilterSort), icon: "arrow.up.arrow.down",
                                    value: strings.text(filters.selection.sort.title))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.sort")
                NavigationLink {
                    OathAssetNetworkFilter(networks: networks, selected: binding(\.networkIDs))
                } label: {
                    OathSettingsRow(title: strings.text(.historyNetworks), icon: "network", value: networkLabel)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.networks")

                OathSettingsSectionRule()
                NavigationLink {
                    OathManageTokensScreen(session: session, walletID: walletID, currency: currency)
                } label: {
                    OathSettingsRow(title: strings.text(.manageTokens), icon: "slider.horizontal.3")
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityIdentifier("assets.filter.manageTokens")

                OathSettingsSectionRule()
                Toggle(isOn: binding(\.groupsTokensByChain)) {
                    OathSettingsRow(title: strings.text(.assetFilterGroupTokens), icon: "list.bullet.indent", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.groupTokens")
                Toggle(isOn: binding(\.hidesUnverifiedTokens)) {
                    OathSettingsRow(title: strings.text(.assetFilterHideUnverified), icon: "checkmark.shield", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.hideUnverified")
                Toggle(isOn: binding(\.hidesZeroBalances)) {
                    OathSettingsRow(title: strings.text(.assetFilterHideZero), icon: "eye.slash", accessory: .none)
                }
                .oathSwitchStyle()
                .padding(.trailing, 20)
                .accessibilityIdentifier("assets.filter.hideZero")
                OathSettingsFooter { Text(strings.text(.assetFilterBalanceDetail)) }

                OathSettingsSectionRule()
                OathSettingsFooter {
                    Text(strings.format(.assetFilterValueRange, currency))
                        .oathFont(.subheadline, weight: .medium)
                }
                OathInputGroup {
                    valueField(.historyMinimum, text: Binding(get: { filters.minimum }, set: { filters.setMinimum($0) }), identifier: "assets.filter.minimum")
                    OathInputSeparator()
                    valueField(.historyMaximum, text: Binding(get: { filters.maximum }, set: { filters.setMaximum($0) }), identifier: "assets.filter.maximum")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                OathSettingsFooter {
                    Text(strings.text(.assetFilterValueDetail))
                    if filters.hasInvalidRange {
                        Text(strings.text(.historyInvalidRange)).foregroundStyle(.red)
                            .accessibilityIdentifier("assets.filter.invalid")
                    }
                }
                OathSettingsSectionRule()
                if filters.saveFailed {
                    OathSettingsFooter {
                        Text(strings.text(.assetFilterSaveFailed)).foregroundStyle(.red)
                            .accessibilityIdentifier("assets.filter.saveError")
                        OathButton(strings.text(.tryAgain)) { filters.retry() }
                            .accessibilityIdentifier("assets.filter.retry")
                    }
                }
                if let management {
                    OathSettingsRow(title: strings.text(.assetFilterMatches), icon: "line.3.horizontal.decrease",
                        value: strings.number(management.matchingCount(filter: filters.selection, currency: currency,
                            locale: strings.language.locale)), accessory: .none)
                        .accessibilityIdentifier("assets.filter.matches")
                }

            }
            .task(id: currency) {
                do {
                    let database = try await session.vault.database()
                    for try await value in database.observeManagedAssets(walletID: walletID, currency: currency) {
                        try Task.checkCancellation()
                        guard session.portfolio?.wallet.id == walletID else { return }
                        management = value
                    }
                } catch is CancellationError { }
                catch { OathDiagnostics.record(error, component: "asset_filters", operation: "observe_management") }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(strings.text(.assetFilterTitle))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    OathCloseButton { dismiss() }.accessibilityIdentifier("assets.filter.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    OathButton(strings.text(.assetFilterReset), feedback: .selection) { filters.reset() }
                        .oathFont(.body, weight: .medium)
                        .disabled(!filters.canReset)
                        .accessibilityLabel(strings.text(.historyResetFilters))
                        .accessibilityIdentifier("assets.filter.reset")
                }
            }
            .onChange(of: currency, initial: true) { _, value in
                filters.updateCurrency(value)
            }
            .oathNativeLocalization()
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .oathLanguage(strings.language)
    }

    private func valueField(_ title: OathStringKey, text: Binding<String>, identifier: String) -> some View {
        HStack {
            Text(strings.text(title)).fixedSize(horizontal: false, vertical: true)
            TextField(strings.text(.historyNoLimit), text: text)
                .multilineTextAlignment(.trailing)
                .keyboardType(.decimalPad)
                .accessibilityLabel(strings.format(.assetFilterValueLabel, strings.text(title), currency))
                .accessibilityIdentifier(identifier)
                .frame(minHeight: OathInputMetrics.minimumContentHeight)
        }
        .oathInputRow()
    }
}

/// Same canvas, row spacing and readable width as Settings, without Form cards.
private struct OathAssetFilterSettingsPage<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(spacing: 0, content: content)
                .padding(.vertical, 12)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
    }
}

private struct OathAssetFilterChoices<Choice: Hashable>: View {
    let title: OathStringKey
    let choices: [Choice]
    @Binding var selection: Choice
    let titleForChoice: (Choice) -> OathStringKey
    @Environment(\.dismiss) private var dismiss
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathAssetFilterSettingsPage {
            ForEach(choices, id: \.self) { choice in
                OathButton(feedback: .selection) { selection = choice; dismiss() } label: {
                    OathSettingsRow(title: strings.text(titleForChoice(choice)), accessory: .selection(selection == choice))
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(selection == choice ? .isSelected : [])
            }
        }
        .navigationTitle(strings.text(title))
        .navigationBarTitleDisplayMode(.inline)
        .oathNativeLocalization()
    }
}

private struct OathAssetNetworkFilter: View {
    let networks: [OathImportChain]
    @Binding var selected: Set<String>
    @State private var query = ""
    @Environment(\.oathLocalizer) private var strings

    private var matches: [OathImportChain] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return networks.filter { query.isEmpty || $0.searchTerms.localizedStandardContains(query) }
    }

    var body: some View {
        List {
            OathButton(feedback: .selection) { selected.removeAll() } label: {
                OathSettingsRow(title: strings.text(.assetFilterAllNetworks), icon: "network",
                                accessory: .selection(selected.isEmpty))
            }
            .buttonStyle(OathSettingsRowButtonStyle())
            .accessibilityAddTraits(selected.isEmpty ? .isSelected : [])
            .accessibilityIdentifier("assets.filter.network.all")
            .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            OathSettingsListSectionRule()
            ForEach(matches) { network in
                OathButton(feedback: .selection) {
                    if selected.contains(network.id) { selected.remove(network.id) }
                    else { selected.insert(network.id) }
                    if selected == Set(networks.map(\.id)) { selected.removeAll() }
                } label: {
                    OathSettingsRow(title: strings.invariant(network.name),
                                    accessory: .selection(selected.contains(network.id)), networkLogo: network.logoAsset)
                }
                .buttonStyle(OathSettingsRowButtonStyle())
                .accessibilityAddTraits(selected.contains(network.id) ? .isSelected : [])
                .accessibilityIdentifier("assets.filter.network.\(network.id)")
                .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
            }
        }
        .id(strings.language.isRightToLeft)
        .listStyle(.plain).scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .background(Color(uiColor: OathSurfaceColors.canvas).ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if matches.isEmpty && !query.isEmpty {
                OathEmptyState(strings.text(.noSearchResults), systemImage: "magnifyingglass",
                               description: strings.format(.noSearchResultsDetail, query))
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(strings.text(.historyNetworks))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text(strings.text(.assetFilterSearchNetworks)))
        .oathNativeLocalization()
    }
}

/// A section action owns only its button bounds. Embedding a whole UIToolbar
/// here adds toolbar margins inside the section's existing horizontal padding.
struct OathAssetsFilterButton: View {
    let activeCount: Int
    let isEnabled: Bool
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        control
            .overlay(alignment: .topTrailing) {
                if activeCount > 0 {
                    Text(verbatim: strings.number(activeCount))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color(uiColor: .systemRed), in: Capsule())
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .disabled(!isEnabled)
            .accessibilityLabel(strings.text(.assetFilterTitle))
            .accessibilityValue(strings.format(.historyActiveCount, strings.number(activeCount)))
            .accessibilityIdentifier("home.assetFilters")
    }

    @ViewBuilder private var control: some View {
        if #available(iOS 26, *) {
            button.glassEffect(.regular.interactive(isEnabled), in: .circle)
        } else {
            button
        }
    }

    private var button: some View {
        OathButton(action: action) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.body)
                .imageScale(.large)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
