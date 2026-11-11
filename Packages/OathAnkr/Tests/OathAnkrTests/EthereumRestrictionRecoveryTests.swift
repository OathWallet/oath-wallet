import Foundation
import XCTest
@testable import OathAnkr

private actor IdentityFeed: AnkrTransport {
    enum Reply: Equatable { case malformedError, gateway(Int), mainnet, missingResult, wrongID, missingVersion, badQuantity, wrongChain, live }
    let primary: Reply
    let alternate: Reply
    private(set) var methods: [String] = []
    private let http = AnkrHTTPTransport()

    init(_ primary: Reply, alternate: Reply = .mainnet) {
        self.primary = primary
        self.alternate = alternate
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = try XCTUnwrap(request.url?.host)
        let call = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let method = try XCTUnwrap(call["method"].string)
        methods.append(host + "/" + method)
        guard ["eth_chainId", "eth_call"].contains(method) else { throw AnkrError.invalidResponse }
        let reply = host == "rpc.ankr.com" ? primary : alternate
        if reply == .live { return try await http.sendPreservingTransportError(request) }
        var row: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": .number("1")]
        if method == "eth_call" {
            row["result"] = .string("0x" + String(repeating: "0", count: 63) + "1")
        } else {
            row["result"] = .string(reply == .wrongChain ? "0x2" : "0x1")
            if reply == .missingResult { row["result"] = nil }
            if reply == .badQuantity { row["result"] = .string("invalid") }
            if reply == .wrongID { row["id"] = .number("2") }
            if reply == .missingVersion { row["jsonrpc"] = nil }
            if reply == .malformedError { row["result"] = nil; row["error"] = .object([:]) }
            if case .gateway(let code) = reply {
                row["result"] = nil
                row["error"] = .object(["code": .number(String(code)), "message": .string("fixture")])
            }
        }
        return (try JSONEncoder().encode(SolanaJSON.object(row)), 200)
    }
}

final class EthereumRestrictionRecoveryTests: XCTestCase, @unchecked Sendable {
    private let primary = URL(string: "https://rpc.ankr.com/eth/fixture")!
    private let listed = "0x04DBA1194ee10112fE6C3207C0687DEf0e78baCf"
    private var token: StablecoinRestrictionToken { StablecoinRestrictionRegistry.tokens(network: "ethereum").first { $0.symbol == "USDC" }! }

    private func outcome(_ owner: String, _ feed: IdentityFeed) async -> StablecoinRestrictionOutcome? {
        let check = StablecoinRestrictionCheck(endpoints: ["ethereum": primary], transport: feed)
        return await check.check(.init(network: "ethereum", address: owner), tokens: [token]).first?.outcome
    }

    func testMalformedIdentityUsesOnlyIndependentlyVerifiedNodeForContractReads() async {
        for fault in [IdentityFeed.Reply.wrongID, .missingResult, .missingVersion, .badQuantity, .malformedError, .gateway(-32055), .gateway(-32603)] {
            let feed = IdentityFeed(fault)
            let result = await outcome(listed, feed)
            XCTAssertEqual(result, .restricted)
            let reads = await feed.methods
            XCTAssertEqual(reads, ["rpc.ankr.com/eth_chainId", "ethereum-rpc.publicnode.com/eth_chainId", "ethereum-rpc.publicnode.com/eth_call"])
        }
    }

    func testWrongNetworkOrTwoUnusableResponsesNeverReachContract() async {
        for feed in [IdentityFeed(.wrongChain), IdentityFeed(.gateway(-32602)), IdentityFeed(.gateway(-32050)), IdentityFeed(.gateway(-32053)), IdentityFeed(.gateway(-32099)), IdentityFeed(.missingResult, alternate: .wrongChain),
                     IdentityFeed(.missingVersion, alternate: .wrongID)] {
            let result = await outcome(listed, feed)
            XCTAssertEqual(result, .unavailable)
            let reads = await feed.methods
            XCTAssertFalse(reads.contains { $0.hasSuffix("/eth_call") })
        }
    }

    func testOwnerFormattingIsLocalAndMalformedAddressesMakeNoRequests() async {
        let formatted = " " + listed.uppercased() + "\n"
        let result = await outcome(formatted, IdentityFeed(.mainnet))
        XCTAssertEqual(result, .restricted)
        for invalid in ["", "0x123", "0x" + String(repeating: "Ｆ", count: 40), String(listed.dropLast()) + "G"] {
            let feed = IdentityFeed(.mainnet)
            let result = await outcome(invalid, feed)
            XCTAssertEqual(result, .unavailable)
            let reads = await feed.methods
            XCTAssertTrue(reads.isEmpty)
        }
    }

    func testLiveIndependentUSDCAndUSDTReadsMatchAnkrAfterIdentityFailure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ETH_RESTRICTION_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in public Ethereum reads") }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let url = URL(string: "https://rpc.ankr.com/eth")!.appendingPathComponent(try XCTUnwrap(config["AnkrAPIKey"]))
        let oracle = StablecoinRestrictionCheck(endpoints: ["ethereum": url])
        let tokens = StablecoinRestrictionRegistry.tokens(network: "ethereum")
        for owner in [listed, "0x0000000000000000000000000000000000000001", "0xf977814e90da44bfa03b6295a0616a897441acec"] {
            let account = StablecoinRestrictionAccount(network: "ethereum", address: owner)
            let fault: IdentityFeed.Reply = owner == listed ? .gateway(-32055) : .malformedError
            let feed = IdentityFeed(fault, alternate: .live)
            let recovered = await StablecoinRestrictionCheck(endpoints: ["ethereum": primary], transport: feed).check(account, tokens: tokens)
            let direct = await oracle.check(account, tokens: tokens)
            XCTAssertEqual(recovered, direct)
            XCTAssertTrue(recovered.allSatisfy { $0.outcome != .unavailable })
            if owner == listed { XCTAssertEqual(recovered.first { $0.token.symbol == "USDC" }?.outcome, .restricted) }
            let reads = await feed.methods
            XCTAssertEqual(reads.filter { $0 == "ethereum-rpc.publicnode.com/eth_call" }.count, tokens.count)
        }
    }
}
