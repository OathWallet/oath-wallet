import OathDiagnostics
import SwiftUI
import OathDatabase
import Observation

/// Uses the wallet Settings row, spacing and native navigation stack. Reads
/// saved metadata only; restoring visibility never waits for a provider.
struct OathHiddenAssetsPage: View {
    let session: OathWalletSession
    let walletID: String
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var assets: [AssetRecord] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var restoring: Set<String> = []

    var body: some View {
        OathEmptyStateScrollView(centersContent: loaded && assets.isEmpty) {
            if loaded && assets.isEmpty {
                OathEmptyState(strings.text(.hiddenAssetsEmpty), systemImage: "eye")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(assets, id: \.id) { asset in
                        OathButton(feedback: nil) { restore(asset) } label: {
                            OathListRow {
                                OathBadgedAssetLogo(networkID: asset.networkID, isNative: asset.reference == "native",
                                    source: asset.logo, symbol: asset.symbol, identity: nil, size: 38)
                            } content: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(strings.invariant(asset.name)).oathFont(.body)
                                    Text(strings.invariant(OathImportChain(rawValue: asset.networkID)?.name ?? asset.networkID))
                                        .oathFont(.subheadline).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                            } accessory: {
                                Text(strings.text(.showAsset)).oathFont(.body).foregroundStyle(OathOnboardingColors.blue)
                            }
                        }
                        .buttonStyle(OathSettingsRowButtonStyle())
                        .disabled(restoring.contains(asset.id) || !session.isUnlocked || session.changingWallet)
                        .accessibilityIdentifier("walletSettings.hiddenAsset.show")
                    }
                }
                .padding(.vertical, 12).frame(maxWidth: 700).frame(maxWidth: .infinity)
            }
        }
        .task(id: session.isUnlocked) {
            guard session.isUnlocked else { assets = []; loaded = false; return }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do {
                    let database = try await session.vault.database()
                    for try await values in database.observeHiddenAssets(walletID: walletID) {
                        guard !Task.isCancelled, session.isUnlocked else { return }
                        withAnimation(reduceMotion ? nil : .default) { assets = values; loaded = true }
                    }
                } catch is CancellationError { /* Settings dismissed or wallet locked. */ }
                catch {
                    OathDiagnostics.record(error, component: "asset_visibility", operation: "observe_hidden")
                    failed = true
                }
            }
        }
        .alert(strings.text(.preferencesSaveFailed), isPresented: $failed) {
            OathButton(strings.text(.done), feedback: nil) { failed = false }
        }
    }

    private func restore(_ asset: AssetRecord) {
        guard restoring.insert(asset.id).inserted else { return }
        Task {
            defer { restoring.remove(asset.id) }
            await OathDiagnostics.$chain.withValue(asset.networkID) {
                await OathDiagnostics.$operationID.withValue(UUID()) {
                    do { try await session.setAssetHidden(false, assetID: asset.id, walletID: walletID) }
                    catch is CancellationError { /* Session transition, no user-facing error. */ }
                    catch {
                        OathDiagnostics.record(error, component: "asset_visibility", operation: "show")
                        failed = true
                    }
                }
            }
        }
    }
}

/// Read both sections for the same render, including the very first snapshot.
/// A drag temporarily overrides the order while the session saves it.
struct OathWalletManagementSnapshot {
    let tree: WalletTree
    let deletedCount: Int

    @MainActor init(session: OathWalletSession, pendingOrder: [String]?) {
        let current = WalletTree(session.wallets)
        tree = pendingOrder.map { current.reordering($0) } ?? current
        deletedCount = session.recentlyDeletedWallets.count
    }
}

/// Both wallet lists lead to the same retained-wallet management screen.
struct OathRecentlyDeletedWalletsRow: View {
    let count: Int
    let onSelect: () -> Void
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        OathButton(action: onSelect) {
            OathSettingsRow(title: strings.text(.recentlyDeleted), icon: "trash",
                value: strings.number(count))
        }
        .buttonStyle(OathSettingsRowButtonStyle())
        .accessibilityIdentifier("wallets.recentlyDeleted")
    }
}

extension WalletListCategory {
    var titleKey: OathStringKey {
        switch self {
        case .wallets: .wallets
        case .imported: .importedWallets
        case .privateKey: .privateKeyWallets
        case .passphrase: .passphraseWallets
        }
    }
}

/// The same heading and Settings rule in native lists, the drawer and backups.
/// Headers are presentation, not wallet selections or reorder/delete targets.
struct OathWalletSectionHeader: View {
    let category: WalletListCategory
    let title: String
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsDivider { OathSettingsSectionRule().accessibilityHidden(true) }
            Text(title)
                .oathFont(.subheadline, weight: .semibold)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 10)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("wallets.section." + category.rawValue)
        }
        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
        .selectionDisabled(true).deleteDisabled(true).moveDisabled(true)
    }
}

/// Shared always-visible presentation for wallet-only rows.
struct OathWalletTreeRows<Row: View>: View {
    let tree: WalletTree
    @ViewBuilder let row: (WalletRecord) -> Row
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        let sections = tree.sections
        ForEach(sections) { section in
            OathWalletSectionHeader(category: section.category, title: strings.text(section.category.titleKey),
                                    showsDivider: section.id != sections.first?.id)
            ForEach(section.tree.rows) { entry in
                OathWalletTreeRow(entry: entry) { row(entry.wallet) }
            }
        }
    }
}

struct OathWalletTreeRow<Content: View>: View {
    private let depth: Int
    private let continuingAncestorDepths: [Int]
    private let hasFollowingSibling: Bool
    private let hasChildren: Bool
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .body) private var iconSize = 38.0
    @ScaledMetric(relativeTo: .body) private var indentation = 28.0

    init(entry: WalletTree.Row, hasChildren: Bool? = nil, @ViewBuilder content: @escaping () -> Content) {
        depth = entry.depth
        continuingAncestorDepths = entry.continuingAncestorDepths
        hasFollowingSibling = entry.hasFollowingSibling
        self.hasChildren = hasChildren ?? entry.hasChildren
        self.content = content
    }

    /// Account children reuse the wallet tree's geometry without pretending to
    /// be separate stored wallets or changing their parent's reorder identity.
    init(childOf parent: WalletTree.Row, hasFollowingSibling: Bool, @ViewBuilder content: @escaping () -> Content) {
        depth = parent.depth + 1
        continuingAncestorDepths = parent.continuingAncestorDepths
            + (parent.depth > 0 && parent.hasFollowingSibling ? [parent.depth - 1] : [])
        self.hasFollowingSibling = hasFollowingSibling
        hasChildren = false
        self.content = content
    }

    var body: some View {
        content()
            .padding(.leading, CGFloat(depth) * indentation)
            .overlay {
                OathWalletTreeBranches(depth: depth, continuingAncestorDepths: continuingAncestorDepths,
                    hasFollowingSibling: hasFollowingSibling, hasChildren: hasChildren,
                    iconSize: iconSize, indentation: indentation)
                    .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// Decorative connectors only. Native buttons and List editing keep their own
/// hit targets, accessibility and independent deletion/selection semantics.
private struct OathWalletTreeBranches: Shape {
    let depth: Int
    let continuingAncestorDepths: [Int]
    let hasFollowingSibling: Bool
    let hasChildren: Bool
    let iconSize: CGFloat
    let indentation: CGFloat
    // SwiftUI mirrors the path natively; mirroring its points too would undo it.
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = 20 + iconSize / 2
        func point(_ depth: Int, _ y: CGFloat, offset: CGFloat = 0) -> CGPoint {
            let x = origin + CGFloat(depth) * indentation + offset
            return CGPoint(x: rect.minX + x, y: y)
        }
        for depth in continuingAncestorDepths {
            path.move(to: point(depth, rect.minY))
            path.addLine(to: point(depth, rect.maxY))
        }
        if depth > 0 {
            let parent = depth - 1
            path.move(to: point(parent, rect.minY))
            path.addLine(to: point(parent, hasFollowingSibling ? rect.maxY : rect.midY))
            path.move(to: point(parent, rect.midY))
            path.addLine(to: point(depth, rect.midY, offset: -iconSize / 2 - 4))
        }
        if hasChildren {
            path.move(to: point(depth, rect.midY + iconSize / 2 + 4))
            path.addLine(to: point(depth, rect.maxY))
        }
        return path
    }
}

struct OathWalletManagementPage<Actions: View>: View {
    let session: OathWalletSession
    let removal: OathWalletRemovalModel
    @Binding var editMode: EditMode
    let onWallet: (String) -> Void
    let onRecentlyDeleted: () -> Void
    @ViewBuilder let actions: () -> Actions
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingOrder: [String]?
    @State private var failed = false
    @State private var balances = OathWalletListBalances()
    var body: some View {
        let rows = OathWalletManagementSnapshot(session: session, pendingOrder: pendingOrder)
        OathWalletFamilyList(tree: rows.tree, editing: editMode.isEditing,
            enabled: session.isUnlocked && !session.changingWallet && pendingOrder == nil && !removal.busy && scenePhase != .background,
            deleteTitle: strings.text(.delete), onMove: move, onDelete: { id in
                guard scenePhase != .background, !removal.busy else { return }
                removal.begin(.init(ids: [id], permanently: false), reason: strings.text(.walletRemovalAuthentication))
            }, onSelect: { id in
                guard scenePhase != .background, !removal.busy, !editMode.isEditing else { return }
                OathHaptics.shared.play(.selection)
                onWallet(id)
            }) { entry in
                OathWalletTreeRow(entry: entry) {
                    OathWalletListRow(wallet: entry.wallet, session: session, balances: balances,
                                      showsDisclosure: !editMode.isEditing)
                }
                .oathLanguage(strings.language)
            } footer: {
                VStack(spacing: 0) {
                    if rows.deletedCount > 0 {
                        OathSettingsListSectionRule()
                        OathRecentlyDeletedWalletsRow(count: rows.deletedCount) {
                            guard scenePhase != .background, !removal.busy else { return }
                            onRecentlyDeleted()
                        }
                    }
                    if !rows.tree.roots.isEmpty || rows.deletedCount > 0 { OathSettingsListSectionRule() }
                    actions()
                }
                .oathLanguage(strings.language)
            }
        .id(strings.language.isRightToLeft)
        .environment(\.editMode, $editMode)
        .disabled(!session.isUnlocked || session.changingWallet || pendingOrder != nil || removal.confirming)
        .oathInteractionBlocked(removal.busy)
        .task(id: balances.scope(session: session)) { await balances.observe(session: session) }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: { Text(strings.text(.walletChangeFailedDetail)) }
        .accessibilityIdentifier("settings.wallets.list")
    }

    private func move(_ proposed: [String]) {
        guard pendingOrder == nil, session.isUnlocked, !removal.busy, scenePhase != .background else { return }
        let current = WalletTree(session.wallets)
        let ids = current.reordering(proposed).flattened.map(\.id)
        guard ids != current.flattened.map(\.id) else { return }
        pendingOrder = ids
        Task {
            defer { pendingOrder = nil }
            await OathDiagnostics.$operationID.withValue(UUID()) {
                do { try await session.reorderWallets(ids) }
                catch is CancellationError { /* Session locked or changed during the local commit. */ }
                catch { OathDiagnostics.record(error, component: "wallet_list", operation: "reorder_family"); failed = true }
            }
        }
    }
}

/// Shared by Settings and the Home wallet switcher. Opening either list reads
/// cached portfolios; it never changes the selected wallet to obtain a total.
@MainActor @Observable
final class OathWalletListBalances {
    @MainActor @Observable final class RowValue {
        var value: WalletValuation?
    }
    // Stable cells observe only their own value, not a shared totals dictionary.
    @ObservationIgnored private var rows: [String: RowValue] = [:]
    @ObservationIgnored private var observationID = UUID()

    func scope(session: OathWalletSession) -> [String] {
        session.isUnlocked ? session.wallets.map(\.id).sorted() : []
    }

    func observe(session: OathWalletSession, walletIDs: Set<String>? = nil) async {
        let token = UUID()
        observationID = token
        let ids = Set(scope(session: session)).intersection(walletIDs ?? Set(scope(session: session)))
        guard !ids.isEmpty else { return }
        if let snapshot = session.portfolio, snapshot.selectedAccountIdentity == nil {
            row(snapshot.wallet.id).value = WalletValuation(snapshot: snapshot)
        }
        do {
            let database = try await session.vault.database()
            let currency = session.portfolio?.currency ?? Locale.autoupdatingCurrent.currency?.identifier ?? "USD"
            for try await summaries in database.observeWalletAndAccountValuations(walletIDs: ids, currency: currency) {
                guard !Task.isCancelled, token == observationID, session.isUnlocked else { return }
                let present = Set(summaries.map(\.id))
                for (id, row) in rows where !present.contains(id) && row.value != nil { row.value = nil }
                for summary in summaries {
                    let row = row(summary.id)
                    if row.value != summary { row.value = summary }
                }
                rows = rows.filter { present.contains($0.key) }
            }
        } catch { OathDiagnostics.record(error);
            // Preserve committed cached values on a read interruption. A new
            // presentation retries, and an app lock cancels this view's task.
        }
    }

    func amount(walletID: String, selection: HomeAccountSelection? = nil, session: OathWalletSession, locale: Locale = .autoupdatingCurrent) -> String {
        let value = row(selection?.balanceID(walletID: walletID) ?? walletID).value
        let currency = value?.currency ?? session.homePortfolio.currency
        let amounts = OathAssetAmounts(native: nil, fiat: value?.totalFiat, currencyCode: value?.currency)
        return String(OathAssetAmountFormat(locale: locale, selectedCurrencyCode: currency).fiat(amounts).characters)
    }

    private func row(_ id: String) -> RowValue {
        if let value = rows[id] { return value }
        let value = RowValue()
        rows[id] = value
        return value
    }
}

struct OathWalletListRow: View {
    let wallet: WalletRecord
    let session: OathWalletSession
    let balances: OathWalletListBalances
    var showsDisclosure = true
    var isWorking = false
    var compact = false
    var representsSelectedAccount = false
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dynamicTypeSize) private var typeSize
    private var isActive: Bool {
        wallet.id == session.displayedProfile?.id.uuidString
            && (session.selectedHomeAccount == nil || representsSelectedAccount)
    }
    private var amount: String { balances.amount(walletID: wallet.id, session: session) }

    var body: some View {
        OathListRow {
            OathWalletListIcon(colorHex: wallet.colorHex, isActive: isActive)
        } content: {
            if compact || typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    name
                    balance
                }
                Spacer(minLength: 0)
            } else {
                name.frame(maxWidth: .infinity, alignment: .leading)
                balance.layoutPriority(1)
            }
        } accessory: {
            if isWorking {
                ProgressView().accessibilityHidden(true)
            } else if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .accessibilityLabel(session.walletName(wallet, strings: strings))
        .accessibilityValue([session.balancesHidden ? strings.text(.balanceHidden) : amount,
                             isActive ? strings.text(.currentWallet) : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var name: some View {
        Text(session.walletName(wallet, strings: strings))
            .oathFont(.body).foregroundStyle(.primary)
            .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).truncationMode(.tail)
    }

    private var balance: some View {
        Text(amount)
            .oathFont(.body, weight: .medium)
            .foregroundStyle(.primary).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.75)
            .environment(\.layoutDirection, .leftToRight)
            .oathBalanceConcealed(session.balancesHidden)
            .accessibilityIdentifier("wallet.balance.\(wallet.id)")
    }
}

/// Lists use the wallet color. Artwork toolbars can override the foreground for contrast.
struct OathWalletSymbol: View {
    let colorHex: String?
    // Lists provide an illustration size; toolbars inherit native SF metrics.
    var size: CGFloat? = nil

    var body: some View {
        Group {
            if let size {
                Image(systemName: "appclip")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "appclip")
            }
        }
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color(uiColor: OathWalletAccent.color(colorHex)))
    }
}

struct OathWalletListIcon: View {
    let colorHex: String?
    var isActive = false
    @Environment(\.layoutDirection) private var layoutDirection
    @ScaledMetric(relativeTo: .body) private var size = 38.0

    var body: some View {
        OathWalletSymbol(colorHex: colorHex, size: size)
            .overlay(alignment: .bottomTrailing) {
                if isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: size * 0.44, height: size * 0.44)
                        .background(.blue, in: Circle())
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 2))
                        .offset(x: size * (layoutDirection == .rightToLeft ? -0.07 : 0.07), y: size * 0.07)
                }
            }
            .accessibilityHidden(true)
    }
}

struct OathRecentlyDeletedWalletsPage: View {
    let session: OathWalletSession
    let removal: OathWalletRemovalModel
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: Set<String> = []
    @State private var restoring = false
    @State private var failed = false
    private var wallets: [WalletRecord] { session.recentlyDeletedWallets }
    private var allSelected: Bool { !wallets.isEmpty && selection == Set(wallets.map(\.id)) }
    private var canModifySelection: Bool {
        !selection.isEmpty && !restoring && !removal.confirming && session.isUnlocked && !session.changingWallet
    }

    var body: some View {
        Group {
            if wallets.isEmpty {
                OathEmptyStateScrollView {
                    Text(strings.text(.recentlyDeletedDetail)).oathFont(.subheadline)
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                } content: {
                    OathEmptyState(strings.text(.recentlyDeletedEmpty), systemImage: "trash")
                }
            } else {
                let sections = WalletTree(wallets).sections
                List(selection: $selection) {
                    Section {
                        ForEach(sections) { section in
                            OathWalletSectionHeader(category: section.category, title: strings.text(section.category.titleKey),
                                                    showsDivider: section.id != sections.first?.id)
                            ForEach(section.wallets, id: \.id) { wallet in
                                OathSettingsRow(title: session.walletName(wallet, strings: strings), icon: "square.3.layers.3d",
                                    accessory: .none, subtitle: deletionDate(wallet))
                                    .tag(wallet.id)
                                    .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                                    .accessibilityIdentifier("wallets.deleted.\(wallet.id)")
                            }
                        }
                    } header: {
                        Text(strings.text(.recentlyDeletedDetail)).oathFont(.subheadline)
                            .textCase(nil).padding(.vertical, 12)
                    }
                }
                .id(strings.language.isRightToLeft)
                .listStyle(.plain).scrollContentBackground(.hidden)
                .environment(\.editMode, .constant(.active))
                .environment(\.defaultMinListRowHeight, 0)
            }
        }
        .toolbar {
            if wallets.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    OathButton(strings.text(allSelected ? .deselectAllWallets : .selectAllWallets)) {
                        guard scenePhase != .background, !removal.busy else { return }
                        selection = allSelected ? [] : Set(wallets.map(\.id))
                    }.disabled(restoring || removal.confirming)
                    .oathInteractionBlocked(removal.busy)
                    .oathNeutralControl()
                    .accessibilityIdentifier("wallets.deleted.selectAll")
                }
            }
        }
        .oathBottomActions(isPresented: !wallets.isEmpty) {
            VStack(spacing: OathActionMetrics.spacing) {
                OathBottomAction(title: strings.text(.recoverWallets), identifier: "wallets.deleted.restore",
                                 isEnabled: canModifySelection, isWorking: restoring,
                                 isInteractionBlocked: removal.busy) {
                    guard canModifySelection, !removal.busy, scenePhase != .background else { return }
                    let ids = selection
                    restoring = true
                    Task {
                        await OathDiagnostics.$operationID.withValue(UUID()) {
                            defer { restoring = false }
                            do { try await session.recoverDeletedWallets(ids); selection = [] }
                            catch {
                                OathDiagnostics.record(error, component: "wallets", operation: "restore")
                                failed = true
                            }
                        }
                    }
                }
                OathBottomAction(title: strings.text(.deleteWalletsPermanently), identifier: "wallets.deleted.delete",
                                 role: .destructive, appearance: .secondary, isEnabled: canModifySelection,
                                 isInteractionBlocked: removal.busy) {
                    guard canModifySelection, !removal.busy, scenePhase != .background else { return }
                    removal.begin(.init(ids: selection, permanently: true), reason: strings.text(.walletRemovalAuthentication))
                }
            }
        }
        .toolbar(.hidden, for: .bottomBar)
        .disabled(!session.isUnlocked || session.changingWallet)
        .oathInteractionBlocked(removal.busy)
        .onChange(of: wallets) { _, updated in selection.formIntersection(updated.map(\.id)) }
        .oathHapticFeedback(.error, trigger: failed, when: failed)
        .alert(strings.text(.walletChangeFailed), isPresented: $failed) {
            if #available(iOS 26.0, *) {
                OathButton(role: .confirm) {}
                    .accessibilityLabel(strings.text(.done))
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            } else {
                OathButton(strings.text(.done)) {}
                    .accessibilityIdentifier("confirmation.done")
                    .oathConfirmationControl()
            }
        } message: { Text(strings.text(.walletChangeFailedDetail)) }
        .animation(reduceMotion ? nil : .default, value: wallets.map(\.id))
    }

    private func deletionDate(_ wallet: WalletRecord) -> String {
        guard let date = wallet.deletedAt else { return "" }
        let expiry = Date(timeIntervalSince1970: date + OathVaultContents.retention)
        return strings.format(.walletDeletionDate, expiry.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(strings.language.locale)))
    }
}
