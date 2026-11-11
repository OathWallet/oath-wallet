import Foundation
import XCTest
@testable import OathAnkr

/// Simulate only the primary's stale head; backup reads use real HTTPS.
private actor ScrollStaleHeadFeed: AnkrTransport {
    let staleOfficial: Bool
    init(staleOfficial: Bool = false) { self.staleOfficial = staleOfficial }
    let http = AnkrHTTPTransport()
    var primaryReads = 0, backupReads = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        XCTAssertFalse(calls.contains { $0["method"].string == "eth_sendRawTransaction" })
        if request.url?.host == "rpc.ankr.com" || (staleOfficial && request.url?.host == "rpc.scroll.io") {
            primaryReads += 1
            XCTAssertEqual(calls.last?["method"].string, "eth_getBlockByNumber")
            XCTAssertEqual(calls.last?["params"].array?.first, .string("latest"))
            let old = "0x" + String(Int(Date.now.timeIntervalSince1970) - 600, radix: 16)
            let block: SolanaJSON = .object(["number": .string("0x1"), "hash": .string("0x" + String(repeating: "a", count: 64)), "timestamp": .string(old)])
            return (try JSONEncoder().encode(SolanaJSON.array([
                .object(["jsonrpc": .string("2.0"), "id": .number("0"), "result": .string("0x82750")]),
                .object(["jsonrpc": .string("2.0"), "id": .number("1"), "result": block])])), 200)
        }
        XCTAssertEqual(request.url?.host, staleOfficial ? "scroll-rpc.publicnode.com" : "rpc.scroll.io")
        backupReads += 1
        return try await http.sendPreservingTransportError(request)
    }
}

final class ScrollBalanceFallbackTests: XCTestCase, @unchecked Sendable {
    func testOnlyWalletReadWithThreeMatchingBoundedHeadsAcceptsIdleScroll() async throws {
        try await PortfolioIdleHeadChecks.verifyPolicy(.scroll)
    }

    func testLiveQuietTipPreservesBlockTimeAndExactFundedAndEmptyBalances() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SCROLL_FALLBACK_LIVE"] == "1" else { throw XCTSkip("Opt-in archive reads") }
        try await PortfolioIdleHeadChecks.verifyArchive(.scroll,
            token: EVMBalanceAsset(reference: "0x5300000000000000000000000000000000000004", decimals: 18),
            emptyOwner: "0x1111111111111111111111111111111111111111")
    }

    func testWithoutBackupRejectsStaleHeadInsteadOfReturningZero() async throws {
        let feed = ScrollStaleHeadFeed()
        let client = try EVMSendClient(network: .scroll, endpoints: [URL(string: "https://rpc.ankr.com/scroll/fixture")!], transport: feed)
        do {
            _ = try await client.portfolioBalances(owner: "0x1111111111111111111111111111111111111111", assets: [])
            XCTFail("Stale head must not fabricate an empty balance")
        } catch { XCTAssertEqual(error as? EVMSendError, .expired) }
        let primary = await feed.primaryReads, backup = await feed.backupReads
        XCTAssertEqual(primary, 1); XCTAssertEqual(backup, 0)
    }

    func testLiveFundedAndUnfundedScrollBalancesRecoverStalePrimary() async throws {
        try await verifyLiveBalances(staleOfficial: false)
    }

    func testLiveIndependentNodeAfterTwoStaleHeads() async throws {
        try await verifyLiveBalances(staleOfficial: true)
    }

    private func verifyLiveBalances(staleOfficial: Bool) async throws {
        guard ProcessInfo.processInfo.environment["OATH_SCROLL_FALLBACK_LIVE"] == "1" else { throw XCTSkip("Opt-in public Scroll balance reads") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let primary = URL(string: "https://rpc.ankr.com/scroll")!.appendingPathComponent(key)
        let discovery = try AnkrClient(apiKey: key)
        let oracle = try EVMSendClient(network: .scroll, endpoints: [primary])
        for (index, owner) in ["0xF977814e90dA44bFA03b6295A0616a897441aceC", "0x1111111111111111111111111111111111111111"].enumerated() {
            let page = try await discovery.balances(chain: .scroll, address: owner)
            let assets = page.value.assets.prefix(8).map { EVMBalanceAsset(reference: $0.reference, decimals: $0.tokenDecimals) }
            if index == 0 { XCTAssertGreaterThan(assets.count, 1) }
            let backup = try XCTUnwrap(EVMSendNetwork.scroll.portfolioRecoveryEndpoints.first {
                $0.host == (staleOfficial ? "scroll-rpc.publicnode.com" : "rpc.scroll.io")
            })
            try await PortfolioIdleHeadChecks.waitForFreshBackup(.scroll, endpoint: backup)
            let feed = ScrollStaleHeadFeed(staleOfficial: staleOfficial)
            let client = try EVMSendClient(network: .scroll, endpoints: [primary] + EVMSendNetwork.scroll.portfolioRecoveryEndpoints, transport: feed)
            let snapshot = try await client.portfolioBalances(owner: owner, assets: assets, propagateReportedHeadFailure: true)
            XCTAssertTrue(snapshot.failedReferences.isEmpty)
            let tag = SolanaJSON.string("0x" + String(snapshot.height, radix: 16))
            for (reference, amount) in snapshot.amounts {
                let expected = try await oracle.balance(owner: owner.lowercased(), reference: reference, tag: tag)
                XCTAssertEqual(amount, expected)
            }
            try await client.validatePortfolioBalances(snapshot)
            if index == 1 { XCTAssertEqual(snapshot.amounts["native"], "0") }
            let primaryReads = await feed.primaryReads, backupReads = await feed.backupReads
            XCTAssertEqual(primaryReads, staleOfficial ? 2 : 1); XCTAssertGreaterThan(backupReads, 1)
            print("LIVE_SCROLL public case \(index): \(snapshot.amounts.count) exact native/token balances matched ANKR at fallback block, staleOfficial=\(staleOfficial)")
        }
    }
}
