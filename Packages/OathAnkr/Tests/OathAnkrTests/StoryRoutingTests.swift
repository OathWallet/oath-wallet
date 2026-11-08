import XCTest
@testable import OathAnkr

private actor StoryRPCFixture: AnkrTransport {
    var methods: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [[String: Any]])
        let replies = try calls.map { call -> [String: Any] in
            let method = try XCTUnwrap(call["method"] as? String)
            methods.append(method)
            let value: Any
            switch method {
            case "eth_chainId": value = "0x5ea"
            case "eth_blockNumber": value = "0x64"
            case "eth_getLogs": value = [] as [String]
            default: throw AnkrError.invalidResponse
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": value]
        }
        return (try JSONSerialization.data(withJSONObject: replies), 200)
    }
}
private struct StoryQuoteFixture: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "coins.llama.fi", request.url?.path.hasSuffix("coingecko:story-2") == true else {
            throw AnkrError.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: ["coins": ["coingecko:story-2": ["price": 1.23,
            "confidence": 1, "timestamp": Int(Date().timeIntervalSince1970)]]]), 200)
    }
}
final class StoryRoutingTests: XCTestCase, @unchecked Sendable {
    func testPermissionsUseWorkingRPCAndRetainPartialCoverage() async throws {
        let transport = StoryRPCFixture()
        let client = try EVMSendClient(network: .story, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        let result = try await PermissionDiscovery(apiKey: "fixture", transport: transport).evm(network: .story,
            owner: "0x1111111111111111111111111111111111111111", client: client)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.permissions.isEmpty)
        let methods = await transport.methods
        XCTAssertTrue(methods.contains("eth_getLogs"))
        XCTAssertFalse(methods.contains { $0.hasPrefix("ankr_") })
    }
    func testStoryNativeQuoteUsesExactCoinIdentity() async throws {
        let price = try await IndexedEVMMarkets(chain: .story, transport: StoryQuoteFixture()).nativePrice()
        XCTAssertEqual(price.chain, .story)
        XCTAssertEqual(price.reference, "native")
        XCTAssertEqual(price.usd, "1.23")
    }
    func testLiveStoryPermissionsUseStandardRPC() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only Story permissions") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        let key = try XCTUnwrap(config["AnkrAPIKey"] as? String)
        let endpoint = URL(string: "https://rpc.ankr.com/story_mainnet")!.appendingPathComponent(key)
        let client = try EVMSendClient(network: .story, endpoints: [endpoint])
        let scan = try await PermissionDiscovery(apiKey: key).evm(network: .story,
            owner: "0xF977814e90dA44bFA03b6295A0616a897441aceC", client: client)
        XCTAssertEqual(scan.coverage, .partial)
    }
    func testLiveStoryInventoryAndAllHistoryStreams() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only Story check") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        let client = try IndexedEVMClient(chain: .story, apiKey: XCTUnwrap(config["AnkrAPIKey"] as? String))
        // Widely published exchange address; no installed wallet is accessed.
        let owner = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        let inventory = try await client.inventory(owner: owner, tracked: [try IndexedEVMToken(
            reference: IndexedEVMChain.story.wrappedNative, name: "Wrapped IP", symbol: "WIP", decimals: 18)])
        XCTAssertTrue(inventory.complete)
        XCTAssertGreaterThan(inventory.block, 0)
        XCTAssertNotNil(inventory.holdings.first { $0.token.reference == "native" }?.amount)
        XCTAssertNotNil(inventory.holdings.first { $0.token.reference == IndexedEVMChain.story.wrappedNative }?.amount)
        for stream in IndexedEVMChain.story.historyStreams {
            let page = try await client.history(owner: owner, stream: stream)
            XCTAssertEqual(page.chain, .story)
        }
        let quote = try await IndexedEVMMarkets(chain: .story).nativePrice()
        XCTAssertEqual(quote.chain, .story)
        XCTAssertNotNil(Decimal(string: quote.usd))
    }

    func testLiveStoryBalancesMatchIndependentRPCAtSameBlock() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public read-only Story comparison") }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as! [String: Any]
        let client = try IndexedEVMClient(chain: .story, apiKey: XCTUnwrap(config["AnkrAPIKey"] as? String))
        let owner = "0xF977814e90dA44bFA03b6295A0616a897441aceC"
        let inventory = try await client.inventory(owner: owner, tracked: [try IndexedEVMToken(
            reference: IndexedEVMChain.story.wrappedNative, name: "Wrapped IP", symbol: "WIP", decimals: 18)])
        XCTAssertTrue(inventory.complete)
        let holdings = Array(inventory.holdings.filter { $0.amount != nil }.prefix(20))
        XCTAssertTrue(holdings.contains { $0.token.reference == "native" })
        XCTAssertTrue(holdings.contains { $0.token.reference == IndexedEVMChain.story.wrappedNative })
        let block = "0x" + String(inventory.block, radix: 16)
        var calls: [[String: Any]] = [["jsonrpc": "2.0", "id": 0, "method": "eth_chainId", "params": []]]
        for (i, holding) in holdings.enumerated() {
            let native = holding.token.reference == "native"
            let params: [Any] = native ? [owner, block] : [["to": holding.token.reference,
                "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2).lowercased()], block]
            calls.append(["jsonrpc": "2.0", "id": i + 1, "method": native ? "eth_getBalance" : "eth_call", "params": params])
        }
        var request = URLRequest(url: URL(string: "https://mainnet.storyrpc.io")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: calls)
        let (data, status) = try await AnkrHTTPTransport().send(request)
        XCTAssertEqual(status, 200)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(rows.count, calls.count)
        for id in 0...holdings.count {
            let matching = rows.filter { ($0["id"] as? Int) == id }
            XCTAssertEqual(matching.count, 1)
            let result = try XCTUnwrap(matching.first?["result"] as? String)
            let expected = try id == 0 ? "1514" : XCTUnwrap(holdings[id - 1].amount)
            XCTAssertEqual(try AnkrQuantity.decimal(result), expected)
        }
        print("Story independent RPC: \(holdings.count) exact balances matched at block \(inventory.block)")
    }
}
