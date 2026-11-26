import SwiftUI
import UIKit
import OathDatabase

/// Stable wallet and heading identities share the native list's selection,
/// swipe and reorder behavior. Category boundaries are never movable items.
struct OathWalletFamilyList<Row: View, Footer: View>: UIViewControllerRepresentable {
    let tree: WalletTree
    let editing: Bool
    let enabled: Bool
    var allowsSelectionWhileEditing = false
    var reorderingRequiresEditing = false
    let deleteTitle: String
    let onMove: ([String]) -> Void
    let onDelete: (String) -> Void
    let onSelect: (String) -> Void
    var contextMenu: (String) -> UIMenu? = { _ in nil }
    @ViewBuilder let row: (WalletTree.Row) -> Row
    @ViewBuilder let footer: () -> Footer

    func makeUIViewController(context: Context) -> UIViewController {
        WalletFamilyController(configuration: configuration(context))
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? WalletFamilyController)?.update(configuration(context))
    }

    private func configuration(_ context: Context) -> WalletFamilyController.Configuration {
        .init(tree: tree, editing: editing, enabled: enabled, allowsSelectionWhileEditing: allowsSelectionWhileEditing, reorderingRequiresEditing: reorderingRequiresEditing, deleteTitle: deleteTitle,
              reduceMotion: context.environment.accessibilityReduceMotion, onMove: onMove, onDelete: onDelete, onSelect: onSelect,
              contextMenu: contextMenu,
              heading: { category, divider in AnyView(OathWalletSectionHeader(category: category,
                title: context.environment.oathLocalizer.text(category.titleKey), showsDivider: divider)
                .environment(\.locale, context.environment.locale)
                .environment(\.layoutDirection, context.environment.layoutDirection)
                .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
                .environment(\.colorScheme, context.environment.colorScheme)) },
              row: { entry in AnyView(row(entry)
                .environment(\.locale, context.environment.locale)
                .environment(\.layoutDirection, context.environment.layoutDirection)
                .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
                .environment(\.colorScheme, context.environment.colorScheme)
                .environment(\.isEnabled, context.environment.isEnabled && enabled)) },
              footer: AnyView(footer()
                .environment(\.locale, context.environment.locale)
                .environment(\.layoutDirection, context.environment.layoutDirection)
                .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)
                .environment(\.colorScheme, context.environment.colorScheme)
                .environment(\.isEnabled, context.environment.isEnabled && enabled)))
    }
}

private final class WalletFamilyController: UICollectionViewController {
    struct Configuration {
        var tree: WalletTree
        let editing: Bool
        let enabled: Bool
        let allowsSelectionWhileEditing: Bool
        let reorderingRequiresEditing: Bool
        var canReorder: Bool { enabled && (!reorderingRequiresEditing || editing) }
        let deleteTitle: String
        let reduceMotion: Bool
        let onMove: ([String]) -> Void
        let onDelete: (String) -> Void
        let onSelect: (String) -> Void
        let contextMenu: (String) -> UIMenu?
        let heading: (WalletListCategory, Bool) -> AnyView
        let row: (WalletTree.Row) -> AnyView
        let footer: AnyView
    }
    private enum Section: Hashable { case wallets(WalletListCategory), actions }
    private enum Item: Hashable { case heading(WalletListCategory), wallet(String), actions }
    private var configuration: Configuration
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var entries: [String: WalletTree.Row] = [:]
    private var refreshScheduled = false
    private var needsRefresh = false
    private var deferredSwipeRefresh = false

    init(configuration: Configuration) {
        self.configuration = configuration
        super.init(collectionViewLayout: UICollectionViewLayout())
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let list = WalletFamilyCollectionView(frame: .zero, collectionViewLayout: collectionViewLayout)
        list.delegate = self
        list.onMovementEnded = { [weak self] in
            self?.needsRefresh = true
            self?.scheduleRefresh()
        }
        collectionView = list
        view = list
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        var layout = UICollectionLayoutListConfiguration(appearance: .plain)
        layout.showsSeparators = false
        layout.backgroundColor = .clear
        layout.trailingSwipeActionsConfigurationProvider = { [weak self] path in
            guard let self, self.configuration.enabled,
                  case let .wallet(id) = self.dataSource.itemIdentifier(for: path) else { return nil }
            let action = UIContextualAction(style: .destructive, title: self.configuration.deleteTitle) { [weak self] _, _, completion in
                // Authentication and confirmation still belong to the existing
                // removal flow. A swipe never deletes a family or removes a row optimistically.
                self?.configuration.onDelete(id)
                completion(false)
            }
            let actions = UISwipeActionsConfiguration(actions: [action])
            actions.performsFirstActionWithFullSwipe = false
            return actions
        }
        collectionView.setCollectionViewLayout(UICollectionViewCompositionalLayout.list(using: layout), animated: false)
        collectionView.backgroundColor = .clear
        collectionView.contentInset.top = 12
        collectionView.accessibilityIdentifier = "settings.wallets.list"
        updateReorderingAvailability()
        let registration = UICollectionView.CellRegistration<WalletFamilyCell, Item> { [weak self] cell, _, item in
            cell.onSwipeEnded = { [weak self] in
                guard let self, self.deferredSwipeRefresh else { return }
                self.needsRefresh = true
                self.scheduleRefresh()
            }
            self?.configure(cell, item: item)
        }
        dataSource = .init(collectionView: collectionView) { view, path, item in
            view.dequeueConfiguredReusableCell(using: registration, for: path, item: item)
        }
        dataSource.reorderingHandlers.canReorderItem = { [weak self] item in
            guard let self, self.configuration.canReorder, case let .wallet(id) = item,
                  let category = self.entries[id]?.wallet.listCategory else { return false }
            return (self.configuration.tree.sections.first { $0.category == category }?.wallets.count ?? 0) > 1
        }
        dataSource.reorderingHandlers.didReorder = { [weak self] transaction in
            guard let self else { return }
            guard self.configuration.canReorder else {
                self.needsRefresh = true
                self.scheduleRefresh()
                return
            }
            // Ignore headings and validate the complete wallet set before
            // committing. Native drag/drop paths cannot change wallet type.
            let proposed = transaction.finalSnapshot.itemIdentifiers.compactMap { item -> String? in
                if case let .wallet(id) = item { return id }
                return nil
            }
            let order = self.configuration.tree.reorderingWithinSections(proposed)
            let changed = order.sections.flatMap(\.wallets).map(\.id) != self.configuration.tree.sections.flatMap(\.wallets).map(\.id)
            self.configuration.tree = order
            // Applying inside didReorder reenters UIKit's apply queue. Defer to
            // the next main-loop turn before restoring category boundaries.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.refresh(animated: !self.configuration.reduceMotion)
                if changed && self.configuration.canReorder {
                    self.configuration.onMove(order.flattened.map(\.id))
                }
            }
        }
        refresh(animated: false)
    }

    func update(_ configuration: Configuration) {
        self.configuration = configuration
        loadViewIfNeeded()
        updateReorderingAvailability()
        // Do not replace the snapshot underneath an interactive drag. The
        // deferred layout refresh also covers a cancelled drag and external updates.
        needsRefresh = true
        scheduleRefresh()
    }

    private func updateReorderingAvailability() {
        let allowed = configuration.canReorder
        collectionView.dragInteractionEnabled = allowed
        if let list = collectionView as? WalletFamilyCollectionView {
            list.allowsReordering = allowed
            if !allowed, list.movingFamily { list.cancelInteractiveMovement() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard dataSource != nil else { return }
        if needsRefresh { scheduleRefresh() }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled, !((collectionView as? WalletFamilyCollectionView)?.movingFamily ?? false),
              !collectionView.hasActiveDrag, !collectionView.hasActiveDrop,
              !collectionView.hasUncommittedUpdates else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            guard !((self.collectionView as? WalletFamilyCollectionView)?.movingFamily ?? false),
                  !self.collectionView.hasActiveDrag, !self.collectionView.hasActiveDrop,
                  !self.collectionView.hasUncommittedUpdates else { return }
            self.refresh(animated: !self.configuration.reduceMotion)
        }
    }

    private func refresh(animated: Bool) {
        needsRefresh = false
        deferredSwipeRefresh = false
        entries = Dictionary(uniqueKeysWithValues: configuration.tree.rows.map { ($0.id, $0) })
        collectionView.isUserInteractionEnabled = configuration.enabled
        collectionView.allowsSelectionDuringEditing = configuration.allowsSelectionWhileEditing
        if collectionView.isEditing != configuration.editing {
            collectionView.isEditing = configuration.editing
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in configuration.tree.sections {
            let id = Section.wallets(section.category)
            snapshot.appendSections([id])
            snapshot.appendItems([.heading(section.category)] + section.wallets.map { .wallet($0.id) }, toSection: id)
        }
        snapshot.appendSections([.actions])
        snapshot.appendItems([.actions], toSection: .actions)
        let previous = dataSource.snapshot()
        let structureChanged = previous.sectionIdentifiers != snapshot.sectionIdentifiers
            || previous.itemIdentifiers != snapshot.itemIdentifiers
            || snapshot.itemIdentifiers.contains {
                previous.sectionIdentifier(containingItem: $0) != snapshot.sectionIdentifier(containingItem: $0)
            }
        if structureChanged {
            let removedItems = Set(previous.itemIdentifiers).subtracting(snapshot.itemIdentifiers)
            if !removedItems.isEmpty {
                // A committed removal must not animate the old row through the
                // hierarchy or anchor the viewport to the actions at the bottom.
                // Keep the current position, clamped only if the list got shorter.
                let offset = collectionView.contentOffset
                UIView.performWithoutAnimation {
                    dataSource.apply(snapshot, animatingDifferences: false)
                    collectionView.layoutIfNeeded()
                    let minimumY = -collectionView.adjustedContentInset.top
                    let maximumY = max(minimumY, collectionView.contentSize.height
                        - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
                    collectionView.setContentOffset(CGPoint(x: offset.x,
                        y: min(maximumY, max(minimumY, offset.y))), animated: false)
                }
            } else {
                dataSource.apply(snapshot, animatingDifferences: animated)
            }
        }
        // Reconfigure visible content without changing identities or selection.
        for path in collectionView.indexPathsForVisibleItems {
            if let cell = collectionView.cellForItem(at: path) as? UICollectionViewListCell,
               let item = dataSource.itemIdentifier(for: path) {
                // Replacing UIHostingConfiguration/accessories while UIKit is
                // tracking a swipe action rebuilds its content under the finger.
                // Keep the native action stable; refresh once it closes.
                if cell.configurationState.isSwiped {
                    deferredSwipeRefresh = true
                } else {
                    configure(cell, item: item)
                }
            }
        }
    }

    private func configure(_ cell: UICollectionViewListCell, item: Item) {
        // The shared SwiftUI row already draws the tree and its indentation.
        cell.indentationLevel = 0
        cell.indentationWidth = 0
        cell.backgroundConfiguration = .clear()
        switch item {
        case let .heading(category):
            cell.isAccessibilityElement = false
            cell.accessibilityIdentifier = nil
            cell.contentConfiguration = UIHostingConfiguration {
                configuration.heading(category, category != configuration.tree.sections.first?.category)
            }.margins(.all, 0)
            cell.accessories = []
        case let .wallet(id):
            guard let entry = entries[id] else { return }
            cell.isAccessibilityElement = false
            cell.accessibilityIdentifier = "settings.wallet.\(id)"
            cell.contentConfiguration = UIHostingConfiguration {
                configuration.row(entry)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { [weak self] in self?.select(id) }
            }.margins(.all, 0)
            cell.accessories = [
                .delete { [weak self] in
                    guard let self, self.configuration.enabled else { return }
                    self.configuration.onDelete(id)
                }
            ]
            if (configuration.tree.sections.first { $0.category == entry.wallet.listCategory }?.wallets.count ?? 0) > 1 {
                cell.accessories.append(.reorder())
            }
        case .actions:
            cell.isAccessibilityElement = false
            cell.accessibilityIdentifier = nil
            cell.contentConfiguration = UIHostingConfiguration { configuration.footer }.margins(.all, 0)
            cell.accessories = []
        }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard case .wallet = dataSource.itemIdentifier(for: indexPath) else { return false }
        return configuration.enabled && (!configuration.editing || configuration.allowsSelectionWhileEditing)
    }

    override func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        guard case .heading = dataSource.itemIdentifier(for: indexPath) else { return true }
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case let .wallet(id) = dataSource.itemIdentifier(for: indexPath) else { return }
        select(id)
    }

    private func select(_ id: String) {
        guard configuration.enabled, !configuration.editing || configuration.allowsSelectionWhileEditing else { return }
        configuration.onSelect(id)
    }

    override func collectionView(_ collectionView: UICollectionView,
        contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard configuration.enabled,
              let cell = collectionView.cellForItem(at: indexPath) as? UICollectionViewListCell,
              !cell.configurationState.isSwiped,
              case let .wallet(id) = dataSource.itemIdentifier(for: indexPath),
              let menu = configuration.contextMenu(id) else { return nil }
        // Let the list own both gestures. A SwiftUI context menu hosted inside
        // the moving row must not compete with UIKit's exposed swipe buttons.
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    override func collectionView(_ collectionView: UICollectionView,
        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
        atCurrentIndexPath currentIndexPath: IndexPath, toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        guard case let .wallet(id) = dataSource.itemIdentifier(for: currentIndexPath),
              let entry = entries[id],
              let sectionIndex = dataSource.index(for: .wallets(entry.wallet.listCategory)) else { return currentIndexPath }
        // Clamp movement to this category's wallet rows, excluding headers and
        // footer actions. Model normalization also covers other OS drag paths.
        let siblings = configuration.tree.rows.filter { $0.wallet.listCategory == entry.wallet.listCategory }
            .compactMap { dataSource.indexPath(for: .wallet($0.id)) }
            .filter { $0.section == sectionIndex }
        let target = proposedIndexPath.section > sectionIndex ? (siblings.map(\.item).max() ?? currentIndexPath.item)
            : proposedIndexPath.section < sectionIndex ? 0 : proposedIndexPath.item
        return siblings.min { abs($0.item - target) < abs($1.item - target) }
            ?? currentIndexPath
    }
}

private final class WalletFamilyCell: UICollectionViewListCell {
    var onSwipeEnded: (() -> Void)?
    private var wasSwiped = false

    override func updateConfiguration(using state: UICellConfigurationState) {
        super.updateConfiguration(using: state)
        let ended = wasSwiped && !state.isSwiped
        wasSwiped = state.isSwiped
        if ended {
            // Leave UIKit's configuration callback before refreshing the row.
            DispatchQueue.main.async { [weak self] in self?.onSwipeEnded?() }
        }
    }
}

/// Native interactive movement (including the edit-mode reorder handle) is
/// separate from UIDragSession. Defer snapshot refresh until the gesture ends.
private final class WalletFamilyCollectionView: UICollectionView {
    var allowsReordering = true
    private(set) var movingFamily = false
    var onMovementEnded: (() -> Void)?

    override func beginInteractiveMovementForItem(at indexPath: IndexPath) -> Bool {
        guard allowsReordering else { return false }
        movingFamily = true
        let began = super.beginInteractiveMovementForItem(at: indexPath)
        if !began { movingFamily = false }
        return began
    }

    override func endInteractiveMovement() {
        super.endInteractiveMovement()
        movingFamily = false
        onMovementEnded?()
    }

    override func cancelInteractiveMovement() {
        super.cancelInteractiveMovement()
        movingFamily = false
        onMovementEnded?()
    }
}
