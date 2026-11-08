import Foundation

/// Metadata is stored independently of the interface language. Never persist an
/// English UI placeholder as if it were an asset's real name. A missing/unsafe
/// name uses its valid symbol, then its abbreviated identity. Real token names
/// (including a token actually named "Token") are preserved.
enum TokenMetadataName {
    static func name(_ name: String, symbol: String, reference: String) -> String {
        // Optional metadata validation is expected; it is not a provider failure.
        if let value = try? TronIdentity.clean(name) { return value }
        if let value = try? TronIdentity.clean(symbol, limit: 64) { return value }
        return reference.count > 24 ? String(reference.prefix(12)) + "…" + String(reference.suffix(8)) : reference
    }
}
