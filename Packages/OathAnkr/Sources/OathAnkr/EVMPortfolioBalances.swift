import Foundation
import OathDiagnostics

public struct EVMBalanceAsset: Sendable, Equatable {
    public let reference: String
    public let decimals: Int
    public init(reference: String, decimals: Int) { self.reference = reference; self.decimals = decimals }
}

public struct EVMPortfolioBalances: Sendable {
    public let networkID: String
    public let owner: String
    public let height: Int64
    public let blockHash: String
    public let observedAt: Date
    public let amounts: [String: String]
    public let failedReferences: Set<String>
}

extension EVMSendClient {
    /// Recheck the pinned identity after discovery/verification waits, immediately
    /// before storage. Revalidation never rereads or substitutes token quantities.
    public func validatePortfolioBalances(_ snapshot: EVMPortfolioBalances) async throws {
        guard snapshot.networkID == network.rawValue,
              try await block(.string("0x" + String(snapshot.height, radix: 16)))["hash"].string == snapshot.blockHash else {
            throw EVMSendError.changed
        }
        try Task.checkCancellation()
    }

    /// Read-only portfolio reconciliation. Never prepares, signs or broadcasts.
    /// A failed contract leaves an explicit hole, not an invented zero.
    public func portfolioBalances(owner: String, assets: [EVMBalanceAsset], minimumHeight: Int64 = 0) async throws -> EVMPortfolioBalances {
        try await OathDiagnostics.withChain(network.rawValue) {
            let owner = try network.address(owner)
            let head = try await block(.string("latest"), requireFresh: true)
            let height = try Self.uint(head["number"])
            guard height <= UInt64(Int64.max), height >= UInt64(max(0, minimumHeight)),
                  let hash = head["hash"].string, AnkrQuantity.hash(hash) else { throw EVMSendError.changed }
            var unique: [String: Int] = ["native": 18]
            for asset in assets {
                let ref = try EVMSendIdentity.reference(asset.reference)
                guard (0...255).contains(asset.decimals), unique[ref].map({ $0 == asset.decimals }) ?? true else {
                    throw EVMSendError.metadataChanged
                }
                unique[ref] = asset.decimals
            }
            let requested = unique.sorted { $0.key < $1.key }
            let tag = SolanaJSON.string("0x" + String(height, radix: 16))
            let result = await withTaskGroup(of: (String, String?).self) { group in
                var next = 0, amounts: [String: String] = [:], failed = Set<String>()
                func enqueue() {
                    guard next < requested.count, !Task.isCancelled else { return }
                    let (reference, precision) = requested[next]; next += 1
                    group.addTask {
                        do {
                            if reference != "native", try await self.decimals(reference, tag: tag) != precision {
                                throw EVMSendError.metadataChanged
                            }
                            return (reference, try await self.balance(owner: owner, reference: reference, tag: tag))
                        } catch {
                            if !Task.isCancelled && !(error is CancellationError) {
                                OathDiagnostics.record(error, component: "portfolio_refresh", operation: "rpc_balance",
                                                       context: ["chain": self.network.rawValue])
                            }
                            return (reference, nil)
                        }
                    }
                }
                for _ in 0..<min(4, requested.count) { enqueue() }
                for await (reference, amount) in group {
                    if let amount { amounts[reference] = amount } else { failed.insert(reference) }
                    enqueue()
                }
                return (amounts, failed)
            }
            try Task.checkCancellation()
            guard try await block(tag)["hash"].string == hash else { throw EVMSendError.changed }
            return EVMPortfolioBalances(networkID: network.rawValue, owner: owner, height: Int64(height),
                blockHash: hash, observedAt: .now, amounts: result.0, failedReferences: result.1)
        }
    }
}
