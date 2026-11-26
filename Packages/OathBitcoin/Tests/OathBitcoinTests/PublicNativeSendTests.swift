import XCTest
@testable import OathBitcoin

final class PublicNativeSendTests: XCTestCase {
    func testSignFreshFaucetFundedTestnetUTXO() throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_FRESH_UTXO_TESTNET_FIXTURE"] else {
            throw XCTSkip("Explicit newly funded UTXO testnet fixture required")
        }
        struct Output: Decodable { let txid, raw: String; let vout: Int; let value: Int64 }
        struct Fixture: Decodable {
            let chain: UTXONetwork
            let network: BitcoinSendNetwork
            let key: Data
            let sender, recipient: String
            let outputs: [Output]
        }
        let fixtureURL = URL(fileURLWithPath: path)
        let f = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        let type: BitcoinAddressType
        switch (f.chain, f.network) {
        case (.bitcoin, .testnet4), (.litecoin, .testnet): type = .nativeSegwit
        case (.bitcoincash, .chipnet), (.dogecoin, .testnet): type = .legacy
        default: throw BitcoinSendError.invalidInput
        }
        let descriptor = try f.chain.singleKey(bytes: f.key, compressed: true)
        let branch = try XCTUnwrap(descriptor.branches.first { $0.type == type })
        let source = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
        XCTAssertEqual(try BitcoinSendPlan.address(source, on: f.network, chain: f.chain), f.sender)
        let coins = try f.outputs.map { output in
            BitcoinSendCoin(accountID: "fresh-testnet", txid: output.txid, vout: output.vout,
                            value: output.value, address: source,
                            previousTransaction: try XCTUnwrap(Data(hex: output.raw)))
        }
        let amount: Int64 = f.chain == .dogecoin ? 100_000_000 : 20_000
        let plan = try BitcoinSendPlan.make(coins: coins, recipient: f.recipient, amount: amount,
                                           change: source, ratePerKVByte: f.chain == .dogecoin ? 1_000_000 : 10_000, network: f.network, chain: f.chain)
        let sourceKey = BitcoinPrivateKeySource.single(f.key, compressed: true)
        let signed = try f.chain == .bitcoincash
            ? BitcoinCashSendSigner.sign(plan) { _ in sourceKey }
            : BitcoinSendSigner.sign(plan) { _ in sourceKey }
        XCTAssertGreaterThan(signed.fee, 0)
        XCTAssertEqual(signed.fee, plan.fee)
        let result: [String: Any] = ["chain": f.chain.rawValue, "network": f.network.rawValue,
                                    "txid": signed.txid, "raw": signed.raw.hex, "fee": signed.fee,
                                    "recipient": f.recipient, "amount": amount]
        try JSONSerialization.data(withJSONObject: result).write(
            to: fixtureURL.deletingLastPathComponent().appendingPathComponent(f.chain.rawValue + "-signed.json"),
            options: .atomic)
        print("UTXO_TESTNET_SIGNED chain=\(f.chain.rawValue) txid=\(signed.txid)")
    }
}
