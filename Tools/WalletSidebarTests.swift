import Foundation

enum FixtureFailure: Error { case rejected }

@MainActor final class SelectionGate {
    var calls = 0
    var reports = 0
    var actual = "A"
    var valid = true
    var continuation: CheckedContinuation<Void, Error>?
    func run(_ id: String) async throws {
        calls += 1
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(as id: String? = nil, failure: Bool = false) {
        if let id { actual = id }
        let pending = continuation; continuation = nil
        if failure { pending?.resume(throwing: FixtureFailure.rejected) }
        else { pending?.resume() }
    }
    func select(_ id: String, in model: OathWalletSidebarModel) {
        model.select(id, currentID: actual, isValid: { _ in self.valid }, actualID: { self.actual },
            operation: run, report: { _ in self.reports += 1 })
    }
}

@main enum WalletSidebarChecks {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Sidebar condition did not settle")
    }
    @MainActor static func main() async throws {
        let model = OathWalletSidebarModel()
        // Opening captures focus exactly once; the UIKit callback cannot erase it.
        model.open(walletID: "A", searchFocused: true)
        model.willOpen(walletID: "A", searchFocused: false)
        precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .none)
        model.close()
        precondition(model.isVisible)
        precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .restoreSearch)
        precondition(!model.isVisible)
        precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .none)

        for action in [OathWalletSidebarModel.Action.addWallet, .settings, .support] {
            model.open(walletID: "A", searchFocused: true)
            model.navigate(action)
            precondition(!model.isPresented && model.isVisible) // Wait for completed animation.
            precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .navigate(action))
        }

        var changes: [String] = []
        for preference in ["EUR", "العربية"] {
            let before = changes
            model.open(walletID: "A", searchFocused: true)
            model.changePreference {
                precondition(!model.isVisible && !model.isPresented)
                changes.append(preference)
            }
            model.changePreference { preconditionFailure("One selection must produce only one write") }
            precondition(model.isVisible && !model.isPresented && changes == before)
            precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .none)
            precondition(model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true) == .none)
            precondition(changes == before + [preference])
        }
        model.open(walletID: "A", searchFocused: false)
        model.changePreference { preconditionFailure("A locked dismissal must discard the change") }
        precondition(model.didDismiss(walletID: "A", searchStillSelected: false, isUnlocked: false) == .none)
        model.open(walletID: "A", searchFocused: false)
        model.changePreference { preconditionFailure("An interrupted dismissal must discard the change") }
        model.invalidate()
        precondition(model.didDismiss(walletID: "A", searchStillSelected: false, isUnlocked: true) == .none)
        for scenario in 0..<3 {
            model.open(walletID: "A", searchFocused: true); model.close()
            precondition(model.didDismiss(walletID: scenario == 0 ? "B" : "A",
                searchStillSelected: scenario != 1, isUnlocked: scenario != 2) == .none)
        }

        let gate = SelectionGate()
        model.open(walletID: "A", searchFocused: true)
        gate.select("A", in: model)
        precondition(gate.calls == 0 && !model.isPresented)
        _ = model.didDismiss(walletID: "A", searchStillSelected: true, isUnlocked: true)
        model.open(walletID: "A", searchFocused: true)
        gate.select("B", in: model); gate.select("B", in: model); gate.select("C", in: model)
        try await wait { gate.calls == 1 }
        precondition(model.selectingID == "B")
        model.navigate(.settings)
        precondition(model.isPresented) // Cannot navigate away during selection.
        model.walletChanged(to: "B")
        precondition(model.isPresented) // Session's own change waits for operation.
        gate.finish(as: "B")
        try await wait { model.selectingID == nil }
        precondition(!model.isPresented && model.failedID == nil)
        precondition(model.didDismiss(walletID: "B", searchStillSelected: true, isUnlocked: true) == .none)

        // A rejected switch remains usable, reports once, and can retry.
        model.open(walletID: "B", searchFocused: true)
        gate.select("C", in: model); try await wait { gate.continuation != nil }
        gate.finish(failure: true); try await wait { model.selectingID == nil }
        precondition(model.isPresented && model.failedID == "C" && gate.reports == 1)
        gate.select("C", in: model); try await wait { gate.continuation != nil }
        // Session reconciliation can commit the selection even when later work throws.
        gate.finish(as: "C", failure: true); try await wait { model.selectingID == nil }
        precondition(!model.isPresented && gate.reports == 2)
        _ = model.didDismiss(walletID: "C", searchStillSelected: true, isUnlocked: true)

        // Lock/reset/background invalidate callbacks even if provider ignores cancellation.
        model.open(walletID: "C", searchFocused: true)
        gate.select("D", in: model); try await wait { gate.continuation != nil }
        model.invalidate()
        model.open(walletID: "E", searchFocused: false)
        gate.finish(as: "D", failure: true)
        try await Task.sleep(for: .milliseconds(10))
        precondition(model.isPresented && model.selectingID == nil && model.failedID == nil && gate.reports == 2)
        model.navigate(.support); model.invalidate()
        precondition(model.didDismiss(walletID: "E", searchStillSelected: true, isUnlocked: true) == .none)

        // Removal rejects results, and external selection never restores old search.
        model.open(walletID: "C", searchFocused: true)
        gate.select("F", in: model); try await wait { gate.continuation != nil }
        gate.valid = false; gate.finish()
        try await wait { model.selectingID == nil }
        precondition(!model.isPresented)
        _ = model.didDismiss(walletID: "C", searchStillSelected: true, isUnlocked: true)
        model.open(walletID: "C", searchFocused: true); model.walletChanged(to: "G")
        precondition(!model.isPresented)
        precondition(model.didDismiss(walletID: "G", searchStillSelected: true, isUnlocked: true) == .none)

        // After deleting the displayed wallet, the same drawer follows the
        // replacement and, after the last removal, still opens Recently Deleted.
        model.open(walletID: "A", searchFocused: true)
        model.walletChanged(to: "B", previousWalletIsInTrash: true)
        precondition(model.isVisible && model.isPresented)
        model.walletChanged(to: nil, previousWalletIsInTrash: true)
        precondition(model.isVisible && model.isPresented)
        model.navigate(.recentlyDeleted)
        precondition(model.didDismiss(walletID: nil, searchStillSelected: true, isUnlocked: true) == .navigate(.recentlyDeleted))
        print("PASS: production sidebar selection, focus, dismissal ordering, retry, cancellation and lifecycle checks")
    }
}
