import Foundation
import XCTest
@testable import OathAnkr

private actor GatewayFailureFeed: AnkrTransport {
    let code: Int, chainSlot: Bool, backupChain: String, live: Bool
    let failureHost: String
    let http = AnkrHTTPTransport()
    var requests: [(String, SolanaJSON)] = []
    init(code: Int = -32056, chainSlot: Bool = true, backupChain: String = "0x1", live: Bool = false, failureHost: String = "rpc.ankr.com") {
        self.code = code; self.chainSlot = chainSlot; self.backupChain = backupChain; self.live = live
        self.failureHost = failureHost
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let host = try XCTUnwrap(request.url?.host)
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        requests.append((host, body))
        if host != "rpc.ankr.com", live { return try await http.sendPreservingTransportError(request) }
        func reply(_ call: SolanaJSON) -> SolanaJSON {
            let chain = call["method"].string == "eth_chainId"
            if host == failureHost, chain == chainSlot {
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number(String(code)), "message": .string("Gateway fixture failure")])])
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(chain ? backupChain : "0x2a")])
        }
        return (try JSONEncoder().encode(body.array.map { .array($0.map(reply)) } ?? reply(body)), 200)
    }
}

final class EVMGatewayFallbackTests: XCTestCase, @unchecked Sendable {
    let primary = URL(string: "https://rpc.ankr.com/eth/fixture")!
    let backup = URL(string: "https://backup.example")!
    let params: [SolanaJSON] = [.string("0x1111111111111111111111111111111111111111"), .string("0x123")]

    func testGatewayProxyFailureUsesFallbackForPinnedRead() async throws {
        for chainSlot in [true, false] {
            let feed = GatewayFailureFeed(chainSlot: chainSlot)
            let client = try EVMSendClient(network: .ethereum, endpoints: [primary, backup], transport: feed)
            let value = try await client.rpc("eth_getBalance", params)
            XCTAssertEqual(value, .string("0x2a"))
            let requests = await feed.requests
            XCTAssertEqual(requests.map(\.0), ["rpc.ankr.com", "backup.example"])
            XCTAssertEqual(requests.first?.1, requests.last?.1, "Fallback must preserve the exact pinned read")
        }
    }

    func testDocumentedTemporaryGatewayFailuresRecoverButOtherRPCRejectionsDoNot() async throws {
        for code in [-32603, -32055, -32056, -32057, -32059, -32061, -32063, -32064, -32065, -32071, -32072, -32073, -32076] {
            let feed = GatewayFailureFeed(code: code)
            let client = try EVMSendClient(network: .ethereum, endpoints: [primary, backup], transport: feed)
            let value = try await client.rpc("eth_getBalance", params)
            XCTAssertEqual(value, .string("0x2a"))
            let count = await feed.requests.count
            XCTAssertEqual(count, 2, "Each endpoint is attempted once")
        }
        for code in [-32602, -32000, -32003, -32049, -32050, -32051, -32052, -32053, -32054, -32062, -32074, -32075, -32090, 3] {
            let feed = GatewayFailureFeed(code: code)
            let client = try EVMSendClient(network: .ethereum, endpoints: [primary, backup], transport: feed)
            do { _ = try await client.rpc("eth_getBalance", params); XCTFail("Deterministic rejection must remain terminal") }
            catch { XCTAssertEqual(error as? EVMSendError, .rpc(code)) }
            let count = await feed.requests.count
            XCTAssertEqual(count, 1)
        }
    }

    func testGatewayFailureNeverReplaysBroadcastOrUnrecognizedMethod() async throws {
        for method in ["eth_sendRawTransaction", "eth_sendTransaction", "wallet_sendCalls"] {
            for chainSlot in [true, false] {
                let feed = GatewayFailureFeed(chainSlot: chainSlot)
                let client = try EVMSendClient(network: .ethereum, endpoints: [primary, backup], transport: feed)
                do { _ = try await client.rpc(method, [.string("0xfixture")]); XCTFail() }
                catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32056)) }
                let requests = await feed.requests
                XCTAssertTrue(requests.allSatisfy { $0.0 == "rpc.ankr.com" })
                XCTAssertLessThanOrEqual(requests.count, 2, "At most chain preflight plus one fixture broadcast")
            }
        }
    }

    func testFallbackStillRejectsWrongChainAndMissingBackupNeverReturnsZero() async throws {
        let wrong = GatewayFailureFeed(backupChain: "0x89")
        let client = try EVMSendClient(network: .ethereum, endpoints: [primary, backup], transport: wrong)
        do { _ = try await client.rpc("eth_getBalance", params); XCTFail() }
        catch { XCTAssertEqual(error as? EVMSendError, .wrongNetwork) }
        let feed = GatewayFailureFeed()
        let isolated = try EVMSendClient(network: .ethereum, endpoints: [primary], transport: feed)
        do { _ = try await isolated.rpc("eth_getBalance", params); XCTFail() }
        catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32056)) }
        let count = await feed.requests.count
        XCTAssertEqual(count, 1)
    }

    func testAnkrGatewayCodesDoNotChangeOtherProvidersErrorSemantics() async throws {
        let feed = GatewayFailureFeed(failureHost: "other.example")
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://other.example")!, backup], transport: feed)
        do { _ = try await client.rpc("eth_getBalance", params); XCTFail() }
        catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32056)) }
        let count = await feed.requests.count
        XCTAssertEqual(count, 1)
    }

}
