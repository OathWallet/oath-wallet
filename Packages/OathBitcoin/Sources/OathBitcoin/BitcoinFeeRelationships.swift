import Foundation
import OathDiagnostics

/// Optional mempool observations for a receipt. They never change the wallet's settlement state.
public struct BitcoinFeeRelationships: Sendable, Equatable {
    public struct Replacement: Sendable, Equatable {
        public let signalsRBF: Bool?
        public let replacedBy: String?
        public let replaces: [String]
    }
    public struct Package: Sendable, Equatable {
        public let parents: [String]
        public let children: [String]
        public let otherMembers: [String]
        public let fee: Int64
        public let virtualBytes: Int64
        public var rate: Decimal { Decimal(fee) / Decimal(virtualBytes) }
    }
    public let hash: String
    public let replacement: Replacement?
    public let package: Package?
}

public struct BitcoinFeeRelationshipClient: Sendable {
    private let base: URL
    public init() { base = UTXOAPIProvider.bitcoinMempool.base }
    init(testnet4: Bool) {
        base = testnet4 ? URL(string: "https://mempool.space/testnet4/api")! : UTXOAPIProvider.bitcoinMempool.base
    }

    public func lookup(_ hash: String) async -> BitcoinFeeRelationships {
        await OathDiagnostics.$chain.withValue("bitcoin") {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                async let replacement = OathDiagnostics.attemptOptional("bitcoin_receipt_replacements") {
                    try await replacements(hash)
                }
                async let package = OathDiagnostics.attemptOptional("bitcoin_receipt_package") {
                    try await feePackage(hash)
                }
                return await .init(hash: hash, replacement: replacement, package: package)
            }
        }
    }

    private struct ReplacementReply: Decodable {
        struct Node: Decodable {
            struct Transaction: Decodable { let txid: String; let rbf: Bool? }
            let tx: Transaction
            let replaces: [Node]
        }
        let replacements: Node?
    }

    func replacements(_ hash: String) async throws -> BitcoinFeeRelationships.Replacement? {
        guard ElectrumPool.hash(hash) else { throw BitcoinError.invalidResponse }
        guard let root = try await read(ReplacementReply.self, path: "v1/tx/\(hash)/rbf")?.replacements else { return nil }
        var pending: [(ReplacementReply.Node, String?)] = [(root, nil)]
        var visited = Set<String>()
        var match: BitcoinFeeRelationships.Replacement?
        while let (node, successor) = pending.popLast() {
            let txid = node.tx.txid
            guard ElectrumPool.hash(txid), visited.insert(txid).inserted, visited.count <= 2_000 else {
                throw BitcoinError.invalidResponse
            }
            if txid == hash {
                match = .init(signalsRBF: node.tx.rbf, replacedBy: successor, replaces: node.replaces.map(\.tx.txid).sorted())
            }
            pending.append(contentsOf: node.replaces.map { ($0, txid) })
        }
        return match
    }

    struct Member: Decodable {
        let txid: String
        let fee: Int64
        let weight: Int64
        var parents: [Int]? = nil  // Dependency indexes in the cluster response only.
        var vsize: Int64 { (weight + 3) / 4 }
        var valid: Bool {
            ElectrumPool.hash(txid) && (1...4_000_000).contains(weight) && (0...2_100_000_000_000_000).contains(fee)
        }
    }
    struct PackageReply: Decodable {
        struct Cluster: Decodable {
            struct Chunk: Decodable { let txs: [Int] }
            let txs: [Member]
            let chunks: [Chunk]
            let chunkIndex: Int?
        }
        let ancestors: [Member]
        let descendants: [Member]?
        let cluster: Cluster?
        let effectiveFeePerVsize: Double?
    }
    struct Transaction: Decodable {
        struct Input: Decodable { let txid: String?; let vout: Int? }
        let txid: String
        let fee: Int64
        let weight: Int64
        let vin: [Input]
    }
    struct Spender: Decodable { let spent: Bool; let txid: String? }

    func feePackage(_ hash: String) async throws -> BitcoinFeeRelationships.Package? {
        guard ElectrumPool.hash(hash) else { throw BitcoinError.invalidResponse }
        guard let reply = try await read(PackageReply.self, path: "v1/cpfp/\(hash)") else {
            return try await archivedPackage(hash)
        }
        if let cluster = reply.cluster, let index = cluster.chunkIndex {
            return try Self.clusterPackage(cluster, index: index, hash: hash, effectiveRate: reply.effectiveFeePerVsize)
        }
        let members = reply.ancestors + (reply.descendants ?? [])
        guard !members.isEmpty else {
            // Some indexers discard the mempool package as soon as a block mines.
            return try await archivedPackage(hash)
        }
        guard members.count < 1_000, members.allSatisfy(\.valid),
              Set(members.map(\.txid)).count == members.count, !members.contains(where: { $0.txid == hash }),
              let tx = try await read(Transaction.self, path: "tx/\(hash)"), tx.txid == hash else { throw BitcoinError.invalidResponse }
        let current = Member(txid: hash, fee: tx.fee, weight: tx.weight)
        guard current.valid else { throw BitcoinError.invalidResponse }
        let inputs = Set(tx.vin.compactMap(\.txid))
        // Index ordering alone cannot tell a child from its sibling. Check the actual spend.
        let hasPossibleChild = members.contains { !inputs.contains($0.txid) }
        let outputs = hasPossibleChild ? try await read([Spender].self, path: "tx/\(hash)/outspends") : nil
        let spenders = Set((outputs ?? []).filter(\.spent).compactMap(\.txid))
        return Self.package(current: current, relatives: members, inputs: inputs, spenders: spenders,
                            effectiveRate: reply.effectiveFeePerVsize)
    }

    static func clusterPackage(_ cluster: PackageReply.Cluster, index: Int, hash: String,
                               effectiveRate: Double?) throws -> BitcoinFeeRelationships.Package? {
        guard cluster.txs.count <= 1_000, cluster.chunks.indices.contains(index) else { throw BitcoinError.invalidResponse }
        let chunk = cluster.chunks[index].txs
        guard !chunk.isEmpty, Set(chunk).count == chunk.count, chunk.allSatisfy(cluster.txs.indices.contains),
              let position = chunk.first(where: { cluster.txs[$0].txid == hash }) else { throw BitcoinError.invalidResponse }
        guard chunk.count > 1 else { return nil }
        let included = Set(chunk)
        let members = chunk.map { cluster.txs[$0] }
        guard members.allSatisfy(\.valid), Set(members.map(\.txid)).count == members.count else { throw BitcoinError.invalidResponse }
        var parents: [Int: [Int]] = [:], children: [Int: [Int]] = [:]
        for member in chunk {
            guard let inputs = cluster.txs[member].parents, inputs.allSatisfy(cluster.txs.indices.contains) else {
                throw BitcoinError.invalidResponse
            }
            parents[member] = inputs.filter(included.contains)
            for parent in parents[member] ?? [] { children[parent, default: []].append(member) }
        }
        func relatives(_ edges: [Int: [Int]]) throws -> Set<String> {
            var todo = edges[position] ?? [], found = Set<Int>()
            while let next = todo.popLast() {
                guard next != position else { throw BitcoinError.invalidResponse }
                if found.insert(next).inserted { todo += edges[next] ?? [] }
            }
            return Set(found.map { cluster.txs[$0].txid })
        }
        return try Self.package(current: cluster.txs[position], relatives: members.filter { $0.txid != hash },
                                inputs: relatives(parents), spenders: relatives(children), effectiveRate: effectiveRate)
    }

    static func package(current: Member, relatives: [Member], inputs: Set<String>, spenders: Set<String>,
                        effectiveRate: Double?) -> BitcoinFeeRelationships.Package? {
        // An ordinary spend of unconfirmed change alone does not establish a fee bump.
        guard let effectiveRate, effectiveRate.isFinite, effectiveRate > 0 else { return nil }
        let members = relatives + [current]
        let totalFee = members.reduce(Int64(0)) { $0 + $1.fee }
        let totalSize = members.reduce(Int64(0)) { $0 + $1.vsize }
        func standalone(_ member: Member) -> Double { Double(member.fee) / Double(member.vsize) }
        let paidRate = min(effectiveRate, Double(totalFee) / Double(totalSize))
        func subsidized(_ member: Member) -> Bool { standalone(member) + 0.0000001 < paidRate }
        func contributes(_ member: Member) -> Bool { standalone(member) > paidRate + 0.0000001 }
        let lowerFeeParents = relatives.filter { inputs.contains($0.txid) && subsidized($0) }.map(\.txid).sorted()
        let higherFeeChildren = relatives.filter { spenders.contains($0.txid) && contributes($0) }.map(\.txid).sorted()
        let parents = contributes(current) ? lowerFeeParents : []
        let children = subsidized(current) ? higherFeeChildren : []
        // A middle transaction can have exactly the package rate while connecting
        // a low-fee ancestor and a paying descendant. Show the package without assigning it either role.
        guard !parents.isEmpty || !children.isEmpty || (!lowerFeeParents.isEmpty && !higherFeeChildren.isEmpty) else { return nil }
        let direct = Set(parents + children)
        return .init(parents: parents, children: children, otherMembers: relatives.map(\.txid).filter { !direct.contains($0) }.sorted(),
                     fee: totalFee, virtualBytes: totalSize)
    }

    private struct BlockStatus: Decodable {
        let confirmed: Bool
        let block_hash: String?
    }
    private struct BlockSummaryEntry: Decodable {
        let txid: String
        let fee: Int64
        let vsize: Double
        let rate: Double
        let flags: UInt64
        // mempool.space TransactionFlags.cpfp_parent / cpfp_child.
        var hasChild: Bool { flags & (1 << 16) != 0 }
        var hasParent: Bool { flags & (1 << 17) != 0 }
        var member: Member? {
            let weight = vsize * 4
            guard (1...4_000_000).contains(weight), weight.rounded() == weight else { return nil }
            let member = Member(txid: txid, fee: fee, weight: Int64(weight))
            return member.valid ? member : nil
        }
    }

    private func archivedPackage(_ hash: String) async throws -> BitcoinFeeRelationships.Package? {
        guard let status = try await read(BlockStatus.self, path: "tx/\(hash)/status"),
              status.confirmed, let block = status.block_hash, ElectrumPool.hash(block) else { return nil }
        let path = "v1/block/\(block)"
        guard let selected = try await read(BlockSummaryEntry.self, path: path + "/tx/\(hash)/summary"),
              selected.txid == hash, selected.hasChild || selected.hasParent, selected.rate > 0,
              let current = selected.member else { return nil }
        guard let entries = try await read([BlockSummaryEntry].self, path: path + "/summary", byteLimit: 5_000_000) else { return nil }
        var candidates: [String: BlockSummaryEntry] = [:]
        for entry in entries where (entry.hasChild || entry.hasParent) && abs(entry.rate - selected.rate) < 0.0000001 {
            guard entry.member != nil, candidates.updateValue(entry, forKey: entry.txid) == nil else { throw BitcoinError.invalidResponse }
        }
        guard candidates.count > 1, candidates[hash] != nil else { return nil }

        // Separate fee packages in a block can have identical rates. Trace only real spends
        // reachable from this receipt, never all transactions that share the indexed rate.
        var pending = [hash], visited = Set<String>()
        var parents: [String: Set<String>] = [:], children: [String: Set<String>] = [:]
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let entry = candidates[id] else { continue }
            guard visited.count <= 64 else { return nil } // Bound on-demand archive requests; never report a partial sum.
            try Task.checkCancellation()
            if entry.hasParent {
                guard let tx = try await read(Transaction.self, path: "tx/\(id)"), tx.txid == id else { return nil }
                for parent in Set(tx.vin.compactMap(\.txid)) where candidates[parent]?.hasChild == true {
                    parents[id, default: []].insert(parent)
                    children[parent, default: []].insert(id)
                    if !visited.contains(parent) { pending.append(parent) }
                }
            }
            if entry.hasChild {
                guard let outs = try await read([Spender].self, path: "tx/\(id)/outspends") else { return nil }
                for child in Set(outs.filter(\.spent).compactMap(\.txid)) where candidates[child]?.hasParent == true {
                    parents[child, default: []].insert(id)
                    children[id, default: []].insert(child)
                    if !visited.contains(child) { pending.append(child) }
                }
            }
        }
        guard visited.count > 1 else { return nil }
        let members = visited.compactMap { candidates[$0]?.member }
        let fee = Double(members.reduce(Int64(0)) { $0 + $1.fee })
        let byteRate = fee / Double(members.reduce(Int64(0)) { $0 + $1.vsize })
        let weightRate = fee * 4 / Double(members.reduce(Int64(0)) { $0 + $1.weight })
        // The block summary can use rounded virtual sizes or fractional weight units.
        // If neither explains the published rate, this is insufficient package evidence.
        guard min(abs(selected.rate - byteRate), abs(selected.rate - weightRate)) <= 0.0000001 else { return nil }
        func reachable(_ edges: [String: Set<String>]) -> Set<String> {
            var remaining = Array(edges[hash] ?? []), found = Set<String>()
            while let id = remaining.popLast() {
                if found.insert(id).inserted { remaining += edges[id] ?? [] }
            }
            return found
        }
        return Self.package(current: current, relatives: members.filter { $0.txid != hash },
                            inputs: reachable(parents), spenders: reachable(children), effectiveRate: selected.rate)
    }

    private func read<T: Decodable>(_ type: T.Type, path: String, byteLimit: Int = 2_000_000) async throws -> T? {
        let host = "mempool.space"
        try await UTXOAPIBudget.shared.acquire(host)
        let request = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        let data: Data?
        let response: URLResponse
        do { (data, response) = try await DiagnosticHTTP.boundedData(for: request, session: .shared, maximumBytes: byteLimit) }
        catch {
            await UTXOAPIBudget.shared.release(host)
            throw OathDiagnostics.recordedForPropagation(error, component: "bitcoin_receipt", operation: "read",
                context: DiagnosticHTTP.context(request))
        }
        guard let http = response as? HTTPURLResponse else {
            await UTXOAPIBudget.shared.release(host)
            throw BitcoinError.invalidResponse
        }
        await UTXOAPIBudget.shared.finish(host, statuses: [http.statusCode], retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        if http.statusCode == 404 { return nil } // An evicted transaction or an unindexed package has no optional metadata.
        guard let data, http.statusCode == 200 else { throw BitcoinError.invalidResponse }
        return try JSONDecoder().decode(type, from: data)
    }
}
