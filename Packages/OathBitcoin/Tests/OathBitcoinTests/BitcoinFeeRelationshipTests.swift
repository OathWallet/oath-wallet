import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinFeeRelationshipTests: XCTestCase {
    private typealias Member = BitcoinFeeRelationshipClient.Member
    private let parent = String(repeating: "a", count: 64)
    private let child = String(repeating: "b", count: 64)
    private let sibling = String(repeating: "c", count: 64)

    func testPackageUsesEachVirtualSizeAndOnlyLabelsAnActualSpend() throws {
        let p = Member(txid: parent, fee: 110, weight: 439)
        let c = Member(txid: child, fee: 330, weight: 437)
        let s = Member(txid: sibling, fee: 110, weight: 440)
        let result = try XCTUnwrap(BitcoinFeeRelationshipClient.package(current: p, relatives: [s, c],
            inputs: [], spenders: [child], effectiveRate: 1.67))
        XCTAssertEqual(result.children, [child])
        XCTAssertEqual(result.otherMembers, [sibling])
        XCTAssertEqual(result.fee, 550)
        XCTAssertEqual(result.virtualBytes, 330)
        XCTAssertEqual(result.rate, Decimal(550) / 330)
        XCTAssertNil(BitcoinFeeRelationshipClient.package(current: p, relatives: [c], inputs: [],
                                                         spenders: [], effectiveRate: 2))
        XCTAssertNil(BitcoinFeeRelationshipClient.package(current: c, relatives: [p], inputs: [parent],
                                                         spenders: [], effectiveRate: 1))
    }

    func testIntermediateAtThePackageRateShowsTheOtherMembers() throws {
        let p = Member(txid: parent, fee: 100, weight: 400)
        let middle = Member(txid: sibling, fee: 200, weight: 400)
        let c = Member(txid: child, fee: 300, weight: 400)
        let result = try XCTUnwrap(BitcoinFeeRelationshipClient.package(current: middle, relatives: [p, c],
            inputs: [parent], spenders: [child], effectiveRate: 2))
        XCTAssertEqual(result.parents, [])
        XCTAssertEqual(result.children, [])
        XCTAssertEqual(result.otherMembers, [parent, child].sorted())
        XCTAssertEqual(result.rate, 2)
    }

    func testPendingIndexSeparatesFeeChunksAndFollowsInputIndexes() throws {
        let p = Member(txid: parent, fee: 440, weight: 437, parents: [])
        let c = Member(txid: child, fee: 3_300, weight: 437, parents: [0])
        let s = Member(txid: sibling, fee: 110, weight: 437, parents: [0])
        let cluster = BitcoinFeeRelationshipClient.PackageReply.Cluster(txs: [p, c, s],
            chunks: [.init(txs: [0, 1]), .init(txs: [2])], chunkIndex: 0)
        let parentResult = try XCTUnwrap(BitcoinFeeRelationshipClient.clusterPackage(cluster, index: 0,
            hash: parent, effectiveRate: 17.11670480549199))
        XCTAssertEqual(parentResult.children, [child])
        XCTAssertEqual(parentResult.otherMembers, [])
        XCTAssertEqual(parentResult.rate, 17)
        let childResult = try BitcoinFeeRelationshipClient.clusterPackage(cluster, index: 0, hash: child, effectiveRate: 17.11670480549199)
        XCTAssertEqual(childResult?.parents, [parent])
        XCTAssertNil(try BitcoinFeeRelationshipClient.clusterPackage(cluster, index: 1, hash: sibling, effectiveRate: 1))
        XCTAssertThrowsError(try BitcoinFeeRelationshipClient.clusterPackage(cluster, index: 0, hash: sibling, effectiveRate: 1))
    }

    private struct TestnetProof: Decodable {
        struct Transaction: Decodable { let id: String; let fee: Int64; let vbytes: Int64; let raw: Data }
        let transactions: [Transaction]
        let fundingValue: Int64
        static func load() throws -> Self {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "receipt-testnet4", withExtension: "json"))
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        }
    }

    func testSignedTestnet4ReplacementAndChildInputsAndFees() throws {
        let recorded = try TestnetProof.load()
        let proof = recorded.transactions
        XCTAssertEqual(proof.count, 3)
        let decoded = try proof.map { try BitcoinTransactions.details($0.raw, network: .bitcoin) }
        XCTAssertEqual(decoded.map(\.txid), proof.map(\.id))
        XCTAssertEqual(decoded.map(\.signalsRBF), [true, true, false])
        XCTAssertEqual(decoded[0].inputs, decoded[1].inputs)
        XCTAssertEqual(decoded[2].inputs.map(\.outpoint), [proof[1].id + ":0"])
        let parentOutput = try XCTUnwrap(decoded[1].outputs.first)
        for i in proof.indices {
            let input = i == 2 ? parentOutput.value : recorded.fundingValue
            XCTAssertEqual(input - decoded[i].outputs.reduce(0) { $0 + $1.value }, proof[i].fee)
        }
    }

    /// Read the public Testnet4 index for the exact transactions in the signed fixture.
    func testPublicTestnet4OriginalReplacementAndFeePayingChild() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_RECEIPT_TESTNET"] == "1" else {
            throw XCTSkip("Set OATH_BITCOIN_RECEIPT_TESTNET=1 for live Testnet4 receipt verification")
        }
        let proof = try TestnetProof.load().transactions
        let client = BitcoinFeeRelationshipClient(testnet4: true)
        let original = await client.lookup(proof[0].id)
        let parent = await client.lookup(proof[1].id)
        let child = await client.lookup(proof[2].id)
        XCTAssertEqual(original.replacement?.replacedBy, proof[1].id)
        XCTAssertEqual(parent.replacement?.replaces, [proof[0].id])
        XCTAssertEqual(parent.package?.children, [proof[2].id])
        XCTAssertEqual(child.package?.parents, [proof[1].id])
        for result in [parent, child] {
            XCTAssertEqual(result.package?.fee, proof[1].fee + proof[2].fee)
            XCTAssertEqual(result.package?.virtualBytes, proof[1].vbytes + proof[2].vbytes)
        }
    }
}
