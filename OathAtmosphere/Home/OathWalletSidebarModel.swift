import Foundation
import Observation

/// Flow ownership is independent of gesture frames and wallet database updates.
/// Injected operations are the session's real selection and reconciliation APIs.
@MainActor @Observable final class OathWalletSidebarModel {
    enum WalletAction: String { case customize, revealRecoveryPhrase, revealPrivateKey, settings }
    enum Action: Equatable {
        case addWallet, settings, security, support, contactSupport, recentlyDeleted
        case wallet(WalletAction, String)
    }
    enum Completion: Equatable { case navigate(Action), restoreSearch, none }
    private enum PendingAction {
        case navigate(Action)
        case changePreference(@MainActor () -> Void)
    }
    private(set) var isPresented = false
    private(set) var isVisible = false
    private(set) var selectingID: String?
    private(set) var failedID: String?
    private var pendingAction: PendingAction?
    private var sourceWalletID: String?
    private var restoreSearch = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var selection: Task<Void, Never>?

    func willOpen(walletID: String?, searchFocused: Bool) {
        guard !isVisible else { return }
        isVisible = true
        sourceWalletID = walletID
        restoreSearch = searchFocused
        pendingAction = nil
        failedID = nil
    }

    func open(walletID: String?, searchFocused: Bool) {
        willOpen(walletID: walletID, searchFocused: searchFocused)
        isPresented = true
    }

    func setPresented(_ presented: Bool) { isPresented = presented }
    func close() { isPresented = false }

    func navigate(_ action: Action) {
        dismiss(then: .navigate(action))
    }

    func changePreference(_ change: @escaping @MainActor () -> Void) {
        dismiss(then: .changePreference(change))
    }

    private func dismiss(then action: PendingAction) {
        guard isVisible, selectingID == nil, pendingAction == nil else { return }
        pendingAction = action
        restoreSearch = false
        close()
    }

    /// UIKit calls this after hiding the drawer and returning focus to Home.
    func didDismiss(walletID: String?, searchStillSelected: Bool, isUnlocked: Bool) -> Completion {
        guard isVisible, !isPresented else { return .none }
        isVisible = false
        let action = pendingAction
        let shouldRestoreSearch = restoreSearch && sourceWalletID == walletID && searchStillSelected
        pendingAction = nil; restoreSearch = false; sourceWalletID = nil
        guard isUnlocked else { return .none }
        switch action {
        case .navigate(let destination): return .navigate(destination)
        case .changePreference(let change):
            change()
            return .none
        case nil: return shouldRestoreSearch ? .restoreSearch : .none
        }
    }

    func walletChanged(to id: String?, previousWalletIsInTrash: Bool = false) {
        guard sourceWalletID != id else { return }
        restoreSearch = false
        pendingAction = nil
        if previousWalletIsInTrash {
            // Moving the displayed wallet can select its successor or leave only Recently Deleted.
            sourceWalletID = id
            failedID = nil
        } else if selectingID == nil {
            // A selection owns its completion. Other external switches leave the old context.
            close()
        }
    }

    func select(_ id: String, currentID: String?,
                isValid: @escaping @MainActor (String) -> Bool,
                actualID: @escaping @MainActor () -> String?,
                operation: @escaping @MainActor (String) async throws -> Void,
                report: @escaping @MainActor (Error) -> Void) {
        guard isVisible, selectingID == nil, isValid(id) else { return }
        if id == currentID { close(); return }
        let ticket = generation
        selectingID = id; failedID = nil; restoreSearch = false; pendingAction = nil
        selection = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation(id)
                try Task.checkCancellation()
                guard let self, self.generation == ticket else { return }
                self.selection = nil; self.selectingID = nil
                guard isValid(id) else { self.close(); return }
                if actualID() == id { self.close() }
                else { self.failedID = id }
            } catch {
                guard let self, self.generation == ticket, !Task.isCancelled else { return }
                self.selection = nil; self.selectingID = nil
                // Cancellation and session teardown are normal lifecycle events.
                guard !(error is CancellationError), isValid(id) else { return }
                // diagnostics: sidebar-selection-reconciliation. The injected
                // session boundary records the original failure before throwing.
                report(error)
                if actualID() == id { self.close() }
                else { self.failedID = id }
            }
        }
    }

    func invalidate() {
        generation = UUID()
        selection?.cancel(); selection = nil
        selectingID = nil; failedID = nil; pendingAction = nil
        restoreSearch = false; sourceWalletID = nil
        isPresented = false; isVisible = false
    }
}
