import Foundation

/// Presentation only: never infer wallet provenance from an editable name.
public enum WalletListCategory: String, CaseIterable, Sendable {
    case wallets, imported, privateKey, passphrase
}

extension WalletRecord {
    public var listCategory: WalletListCategory {
        if kind == "privateKey" { return .privateKey }
        // Electrum seed-password wallets retain their derivation kind. Their
        // authenticated family projection supplies the passphrase name group.
        if kind == "passphrase" || nameGroup == "passphrase" { return .passphrase }
        if ["imported", "aezeed", "electrum", "electrum2fa"].contains(kind) || nameGroup == "imported" {
            return .imported
        }
        return .wallets
    }
}

public struct WalletListSection: Identifiable, Sendable {
    public let category: WalletListCategory
    public let wallets: [WalletRecord]
    public var id: WalletListCategory { category }
    public var tree: WalletTree { WalletTree(wallets) }
}

extension WalletTree {
    /// Fixed section order, preserving each wallet's saved order inside its
    /// section. Empty sections disappear; every wallet remains selectable.
    public var sections: [WalletListSection] {
        let groups = Dictionary(grouping: flattened, by: \.listCategory)
        return WalletListCategory.allCases.compactMap { category in
            guard let wallets = groups[category], !wallets.isEmpty else { return nil }
            return WalletListSection(category: category, wallets: wallets)
        }
    }

    /// Native drag paths can propose cross-section positions. Restore section
    /// order without changing provenance, and reject incomplete/stale snapshots.
    public func reorderingWithinSections(_ ids: [String]) -> WalletTree {
        guard ids.count == flattened.count, Set(ids) == Set(flattened.map(\.id)) else { return self }
        return WalletTree(reordering(ids).sections.flatMap(\.wallets))
    }
}
