import Foundation
import OathDiagnostics

/// Only an already-observed provider cooldown is expected control flow.
private enum ThorchainArchiveDeferral: Error, DiagnosticControlFlowError {
    case cooldown
    var isExpectedDiagnosticControlFlow: Bool { true }
}

actor ThorchainArchiveRequests {
    static let shared = ThorchainArchiveRequests(spacing: .seconds(2))
    private let spacing: Duration
    private var nextStart: ContinuousClock.Instant = .now
    private var cooldown: ContinuousClock.Instant?
    init(spacing: Duration = .zero) { self.spacing = spacing }
    func reserve() async throws {
        while true {
            try Task.checkCancellation()
            let now = ContinuousClock.now
            if let cooldown, now < cooldown { throw ThorchainArchiveDeferral.cooldown }
            if now >= nextStart { nextStart = now.advanced(by: spacing); return }
            try await Task.sleep(for: now.duration(to: nextStart))
        }
    }
    func deferRequests(milliseconds: Int) {
        cooldown = .now.advanced(by: .milliseconds(min(300_000, max(2_000, milliseconds))))
    }

}

extension ThorchainClient {
    static let historyArchive = URL(string: "https://api.viewblock.io/thorchain")!
    private static let archivePermits = AnkrPermits(count: 4)

    /// The node's transaction index can be pruned without returning an error.
    /// Always merge this independent archive, including after successful empty
    /// node results. Archive data never supplies balances or signing parameters.
    func archivedHistory(owner: String, height: Int64, lowerHeight: Int64, page: Int) async throws -> ThorchainHistoryPage {
        do {
            let json = try await archiveRead(path: "addresses/\(owner)/txs", query: [.init(name: "page", value: String(page))])
            let listing = try Self.archiveListing(json, page: page)
            var events: [ThorchainEvent] = []
            for row in listing.docs {
                let identity = try Self.archiveIdentity(row)
                guard (lowerHeight...height).contains(identity.height) else { continue }
                events += try Self.decodeArchivedTransaction(row, owner: owner, upperHeight: height)
            }
            let reachedLower = try listing.docs.last.map { try Self.archiveIdentity($0).height < lowerHeight } ?? false
            return .init(owner: owner, events: events,
                         next: !reachedLower && page < listing.pages ? String(page + 1) : nil, rawCount: listing.docs.count)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            OathDiagnostics.record(error, component: "ThorchainClient", operation: "archive_history", context: ["chain": "thorchain", "stage": "archive_validation"])
            throw error
        }
    }

    private func archiveRead(path: String, query: [URLQueryItem] = []) async throws -> SolanaJSON {
        try await Self.archivePermits.acquire()
        do {
            try await archiveRequests.reserve()
            let value = try await read(Self.historyArchive, path: path, query: query)
            await Self.archivePermits.release()
            return value
        } catch {
            // diagnostics: thorchain-archive-permit-cleanup. archivedHistory
            // reports the unchanged failure; this scope only releases capacity.
            await Self.archivePermits.release()
            throw error
        }
    }

    static func archiveIdentity(_ row: SolanaJSON) throws -> (hash: String, height: Int64, timestamp: Double) {
        guard let hash = row["hash"].string, hash.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let height = row["height"].text.flatMap(Int64.init), height > 0,
              let milliseconds = row["timestamp"].text.flatMap(UInt64.init), milliseconds > 0,
              milliseconds <= 253402300799000 else { throw ThorchainError.malformed }
        return (hash.uppercased(), height, Double(milliseconds) / 1000)
    }

    static func archiveListing(_ json: SolanaJSON, page: Int) throws -> (docs: [SolanaJSON], pages: Int) {
        guard page > 0, page <= 100_000, let docs = json["docs"].array, docs.count <= 25,
              let total = json["total"].text.flatMap(Int.init), (0...2_500_000).contains(total),
              let pages = json["pages"].text.flatMap(Int.init), pages == (total + 24) / 25,
              let returned = json["page"].text.flatMap(Int.init), returned == page || (total == 0 && returned == 0),
              docs.count == min(25, max(0, total - (page - 1) * 25)) else { throw ThorchainError.incomplete }
        var hashes = Set<String>(), previous = Int64.max
        for row in docs {
            let identity = try archiveIdentity(row)
            guard hashes.insert(identity.hash).inserted, identity.height <= previous else { throw ThorchainError.incomplete }
            previous = identity.height
        }
        return (docs, pages)
    }

    /// The archive is an indexed explorer, not a cryptographic receipt proof.
    /// Accept explicit bank sends and executed THOR outbounds only. Deposits,
    /// failed messages and protocol associations remain zero-value actions;
    /// memos, estimates and USD input values never imply a completed transfer.
    static func decodeArchivedTransaction(_ tx: SolanaJSON, owner: String, upperHeight: Int64) throws -> [ThorchainEvent] {
        _ = try ThorchainIdentity.address(owner)
        let identity = try archiveIdentity(tx)
        guard identity.height <= upperHeight else { throw ThorchainError.malformed }
        let messages = tx["msgs"].array
        if !tx["msgs"].isNull && messages == nil { throw ThorchainError.malformed }
        let code = tx["code"].text.flatMap(UInt64.init)
        if messages != nil && code == nil { throw ThorchainError.malformed }
        if !tx["code"].isNull && code == nil { throw ThorchainError.malformed }
        if let messages, messages.count > 100 { throw ThorchainError.malformed }
        if let code {
            guard tx["status"].string == (code == 0 ? "success" : "error") else { throw ThorchainError.malformed }
        }
        let state = code == nil || code == 0 ? "confirmed" : "failed"
        let signer = tx["signer"].string
        if let signer { _ = try ThorchainIdentity.address(signer) }
        var nodeAssociation = false
        var belongs = signer == owner, output: [ThorchainEvent] = []
        var fee: String?
        if signer == owner, let gas = tx["fees"]["gas"]["data"].array {
            var sum: UInt64 = 0
            for coin in gas where coin["asset"].string?.uppercased() == "THOR.RUNE" {
                guard let n = UInt64(try ThorchainIdentity.amount(coin["amount"])) else { throw ThorchainError.malformed }
                let next = sum.addingReportingOverflow(n); guard !next.overflow else { throw ThorchainError.malformed }; sum = next.partialValue
            }
            if sum > 0 { fee = String(sum) }
        }
        func append(_ suffix: String, sender: String, recipient: String, reference: String, amount: String) {
            output.append(.init(id: identity.hash + ":archive:" + suffix, hash: identity.hash, reference: reference,
                amount: amount, direction: sender == owner ? (recipient == owner ? "self" : "outgoing") : "incoming",
                counterparty: sender == owner ? recipient : sender, state: state, height: identity.height,
                timestamp: identity.timestamp, fee: fee))
        }
        func isNodeAssociation(_ memo: String) throws -> Bool {
            let parts = memo.split(separator: ":", omittingEmptySubsequences: false).map {
                // Failed node actions can contain the whitespace mistake that
                // caused rejection. They remain zero-value failed actions.
                state == "failed" ? String($0).trimmingCharacters(in: .whitespacesAndNewlines) : String($0)
            }
            guard let action = parts.first?.uppercased(), ["BOND", "UNBOND", "REBOND"].contains(action),
                  (2...4).contains(parts.count) else { return false }
            let providerIndex = action == "UNBOND" ? 3 : 2
            guard parts[1] == owner || (parts.count > providerIndex && parts[providerIndex] == owner) else { return false }
            _ = try ThorchainIdentity.address(parts[1])
            return true
        }
        for (index, msg) in (messages ?? []).enumerated() {
            guard let type = msg["@type"].string else { throw ThorchainError.malformed }
            if ["/types.MsgSend", "/cosmos.bank.v1beta1.MsgSend"].contains(type) {
                let sender = try ThorchainIdentity.address(msg["from_address"].string ?? "")
                let recipient = try ThorchainIdentity.address(msg["to_address"].string ?? "")
                guard let coins = msg["amount"].array, !coins.isEmpty, coins.count <= 100 else { throw ThorchainError.malformed }
                let owned = sender == owner || recipient == owner
                belongs = belongs || owned
                for (coinIndex, coin) in coins.enumerated() {
                    guard let denom = coin["denom"].string, let ref = try ThorchainIdentity.bankDenom(asset: denom) else { throw ThorchainError.malformed }
                    let amount = try ThorchainIdentity.amount(coin["amount"])
                    if owned && state == "confirmed" { append("send:\(index):\(coinIndex)", sender: sender, recipient: recipient, reference: ref, amount: amount) }
                }
            } else if type == "/types.MsgDeposit" {
                if !belongs { nodeAssociation = try isNodeAssociation(msg["memo"].string ?? ""); belongs = nodeAssociation }
            } else if msg["sender"].string == owner {
                belongs = true
            }
        }
        // Legacy native sends carried protocol memos on the transaction,
        // before MsgDeposit. Require the archive's node-action classification
        // and the documented exact address positions; never a memo substring.
        if !belongs, messages != nil, tx["types"].array?.contains(.string("node")) == true {
            nodeAssociation = try isNodeAssociation(tx["memo"]["raw"].string ?? tx["memo"].string ?? "")
            belongs = nodeAssociation
        }
        if let outbounds = tx["outbounds"].array {
            guard outbounds.count <= 100 else { throw ThorchainError.malformed }
            for (index, outbound) in outbounds.enumerated() where outbound["chain"].string == "THOR" {
                let sender = try ThorchainIdentity.address(outbound["from"].string ?? "")
                let recipient = try ThorchainIdentity.address(outbound["to"].string ?? "")
                guard sender == owner || recipient == owner else { continue }
                guard let ref = try ThorchainIdentity.bankDenom(asset: outbound["asset"].string ?? ""),
                      let executedHeight = outbound["height"].text.flatMap(Int64.init), executedHeight > 0,
                      let executedTime = outbound["timestamp"].text.flatMap(UInt64.init), executedTime > 0,
                      outbound["estimate"] != .bool(true) else { throw ThorchainError.malformed }
                belongs = true
                let amount = try ThorchainIdentity.amount(outbound["amount"])
                // An outbound not yet inside the pinned view is retried on a
                // later refresh. Do not turn pending/estimated output into cash.
                if executedHeight <= upperHeight && state == "confirmed", messages == nil {
                    append("out:\(index)", sender: sender, recipient: recipient, reference: ref, amount: amount)
                }
            }
        } else if !tx["outbounds"].isNull { throw ThorchainError.malformed }
        guard belongs else { throw ThorchainError.wrongOwner }
        if messages == nil && output.isEmpty { throw ThorchainError.incomplete }
        if output.isEmpty {
            output.append(.init(id: identity.hash + (nodeAssociation ? ":archive:action" : ":archive:execution"), hash: identity.hash, reference: "native", amount: "0",
                direction: signer == owner ? "outgoing" : "incoming", counterparty: "", state: state,
                height: identity.height, timestamp: identity.timestamp, fee: fee))
        }
        return output
    }
}
