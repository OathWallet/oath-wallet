import Foundation

/// One immutable presentation of an accepted quote. Native costs are kept in
/// their own units; deposits/rent belong in nativeCost, not necessarily fee.
public struct SendReviewAmounts: Sendable, Equatable {
    /// A balance increase during preparation must not enlarge the amount the
    /// user entered (including Max). They can return to Amount and choose Max
    /// again; the previous intent remains the upper bound until then.
    public static func isWithinRequestedAmount(_ delivered: String, requested: String) -> Bool {
        !EVMSendAmount.less(requested, delivered)
    }
    public struct Amount: Sendable, Equatable {
        public let atomic: String
        public let decimals: Int
        public let symbol: String
        public init(_ atomic: String, decimals: Int, symbol: String) {
            self.atomic = atomic; self.decimals = decimals; self.symbol = symbol
        }
        public var units: String {
            guard decimals > 0 else { return atomic }
            let padded = String(repeating: "0", count: max(0, decimals + 1 - atomic.count)) + atomic
            let index = padded.index(padded.endIndex, offsetBy: -decimals)
            let integer = String(padded[..<index])
            var fraction = String(padded[index...])
            while fraction.last == "0" { fraction.removeLast() }
            return integer + (fraction.isEmpty ? "" : "." + fraction)
        }
        public func value(price: Decimal?) -> Decimal? {
            guard let price, price > 0, let amount = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")),
                  !(amount * price).isNaN else { return nil }
            return amount * price
        }
    }
    public let sent: Amount
    public let fee: Amount
    public let totals: [Amount]
    public let isNative: Bool

    /// Inputs come from validated production plans, including a Max-adjusted
    /// delivered amount and any token transfer charge in assetDebit.
    public init(amount: String, assetDebit: String? = nil, decimals: Int, symbol: String,
                native: Bool, fee: String, nativeCost: String? = nil,
                nativeDecimals: Int, nativeSymbol: String) {
        sent = .init(amount, decimals: decimals, symbol: symbol)
        self.fee = .init(fee, decimals: nativeDecimals, symbol: nativeSymbol)
        isNative = native
        if native {
            totals = [.init(StellarIdentity.sum(assetDebit ?? amount, nativeCost ?? fee), decimals: decimals, symbol: symbol)]
        } else {
            totals = [.init(assetDebit ?? amount, decimals: decimals, symbol: symbol),
                      .init(nativeCost ?? fee, decimals: nativeDecimals, symbol: nativeSymbol)]
        }
    }
    public func totalValue(assetPrice: Decimal?, nativePrice: Decimal?) -> Decimal? {
        guard let asset = totals[0].value(price: assetPrice) else { return nil }
        if isNative { return asset }
        guard let gas = totals[1].value(price: nativePrice), !(asset + gas).isNaN else { return nil }
        return asset + gas
    }
}
