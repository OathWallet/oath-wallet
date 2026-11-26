import XCTest
@testable import OathAnkr

private actor RPCMainnetTransport: AnkrTransport {
    let chain: IndexedEVMChain
    let mode: String
    let decimals: [String: Int]
    var methods: Set<String> = []
    var blocks = 0
    init(_ chain: IndexedEVMChain, mode: String = "ok") throws {
        self.chain = chain; self.mode = mode
        decimals = Dictionary(uniqueKeysWithValues: try RPCCatalogTokens.tokens(chain: chain).map { ($0.reference, $0.decimals) })
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        XCTAssertEqual(request.url?.host, "rpc.ankr.com")
        XCTAssertEqual(request.url?.path, "/" + chain.rawValue + "/fixture")
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array!
        let rows = try calls.map { call -> SolanaJSON in
            let method = try XCTUnwrap(call["method"].string), params = call["params"].array!
            methods.insert(method)
            let result: SolanaJSON
            switch method {
            case "eth_chainId": result = .string("0x" + String(mode == "wrongChain" ? 1 : chain.chainID, radix: 16))
            case "eth_getBlockByNumber":
                blocks += 1
                result = .object(["number": .string("0x64"), "hash": .string("0x" + String(repeating: mode == "reorg" && blocks > 1 ? "b" : "a", count: 64))])
            case "eth_getBalance":
                XCTAssertEqual(params.last, .string("0x64"))
                result = .string("0x20000000000001")
            case "eth_call":
                XCTAssertEqual(params.last, .string("0x64"))
                let token = try XCTUnwrap(params[0]["to"].string)
                if mode == "unavailable", params[0]["data"].string?.hasPrefix("0x70a08231") == true {
                    return .object(["jsonrpc": .string("2.0"), "id": call["id"], "error": .object(["code": .number("-32000")])])
                }
                result = params[0]["data"] == .string("0x313ce567")
                    ? .string("0x" + String(mode == "decimals" ? 255 : decimals[token] ?? 8, radix: 16))
                    : .string("0x20000000000001")
            default: throw AnkrError.invalidResponse
            }
            return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows.reversed())), 200)
    }
}

final class RPCMainnetTests: XCTestCase, @unchecked Sendable {
    private let chains: [IndexedEVMChain] = [.plasma, .worldchain, .elysium]
    private let owner = "0x1111111111111111111111111111111111111111"

    func testMainnetIdentitiesAndPinnedNativeCatalogAndCustomBalancesUseOnlyAnkrRPC() async throws {
        for chain in chains {
            let send = try XCTUnwrap(EVMSendNetwork(rawValue: chain.rawValue))
            XCTAssertFalse(send.isTestnet)
            XCTAssertEqual(send.chainID, chain.chainID)
            XCTAssertEqual(send.symbol, chain.symbol)
            XCTAssertEqual(chain.rpcPath, chain.rawValue)
            XCTAssertTrue(chain.historyStreams.isEmpty)
            let transport = try RPCMainnetTransport(chain)
            let client = try IndexedEVMClient(chain: chain, apiKey: "fixture", alchemyAPIKey: "unused", transport: transport)
            let custom = try IndexedEVMToken(reference: "0x2222222222222222222222222222222222222222", name: "Custom", symbol: "CUSTOM", decimals: 8)
            let value = try await client.inventory(owner: owner, tracked: [custom])
            XCTAssertTrue(value.complete)
            XCTAssertEqual(value.holdings.count, try RPCCatalogTokens.tokens(chain: chain).count + 2)
            XCTAssertTrue(value.holdings.allSatisfy { $0.amount == "9007199254740993" })
            let methods = await transport.methods
            XCTAssertEqual(methods, ["eth_chainId", "eth_getBlockByNumber", "eth_getBalance", "eth_call"])
            do { _ = try await client.history(owner: owner, stream: .transactions); XCTFail("No indexer is configured") }
            catch { XCTAssertEqual(error as? AnkrError, .configurationMissing) }
        }
    }

    func testWrongChainAndReorgAreRejectedAndFailedTokenReadsNeverBecomeZero() async throws {
        for chain in chains {
            for mode in ["wrongChain", "reorg"] {
                let client = try IndexedEVMClient(chain: chain, apiKey: "fixture", transport: RPCMainnetTransport(chain, mode: mode))
                do { _ = try await client.inventory(owner: owner); XCTFail(mode) }
                catch { XCTAssertEqual(error as? AnkrError, mode == "wrongChain" ? .wrongChain : .invalidResponse) }
            }
            for mode in ["unavailable", "decimals"] {
                let client = try IndexedEVMClient(chain: chain, apiKey: "fixture", transport: RPCMainnetTransport(chain, mode: mode))
                let value = try await client.inventory(owner: owner)
                XCTAssertFalse(value.complete)
                XCTAssertEqual(value.holdings.first { $0.token.reference == "native" }?.amount, "9007199254740993")
                XCTAssertTrue(value.holdings.filter { $0.token.reference != "native" }.allSatisfy { $0.amount == nil })
            }
        }
    }

    func testNativeAndTokenQuoteSignSubmitAndConfirmWithMockRPC() async throws {
        let key = Data(repeating: 1, count: 32) // Synthetic test key; never funded or sent to a provider.
        let sender = try EVMSendCrypto.address(privateKey: key)
        for chain in chains {
            let network = try XCTUnwrap(EVMSendNetwork(rawValue: chain.rawValue))
            for reference in ["native", "0x3333333333333333333333333333333333333333"] {
                let transport = EVMSendFixtureTransport(network: network, gasEstimate: reference == "native" ? 21_000 : 70_000)
                let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.invalid")!], transport: transport)
                let plan = try await client.quote(sender: sender, recipient: owner, reference: reference,
                    decimals: reference == "native" ? 18 : 6, amount: "1")
                try plan.validate()
                XCTAssertEqual(plan.network.chainID, network.chainID)
                XCTAssertEqual(plan.extraFee > 0, network == .worldchain)
                let signed = try EVMSendCrypto.sign(plan, privateKey: key)
                try EVMSendCrypto.verify(signed, plan: plan)
                await transport.configure(plan, signed)
                _ = try await client.submit(signed, plan: plan)
                await transport.changeMode("confirmed")
                let receipt = try await client.status(signed, plan: plan)
                XCTAssertEqual(receipt.outcome, .confirmed)
            }
        }
    }

    func testLiveNativeAndTokenFeeQuotes() async throws {
        guard let config = ProcessInfo.processInfo.environment["OATH_MAINNET_RPC_CONFIG"],
              let probesPath = ProcessInfo.processInfo.environment["OATH_MAINNET_QUOTE_PROBES"] else {
            throw XCTSkip("Opt-in public mainnet fee estimates")
        }
        struct Probe: Decodable {
            struct Token: Decodable { let reference: String; let decimals: Int }
            let chain: IndexedEVMChain; let candidates: [String]; let holders: [String]; let token: Token
        }
        let values = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        let key = try XCTUnwrap(values["AnkrAPIKey"])
        let probes = try JSONDecoder().decode([Probe].self, from: Data(contentsOf: URL(fileURLWithPath: probesPath)))
        XCTAssertEqual(Set(probes.map(\.chain)), Set(chains))
        for probe in probes {
            let network = try XCTUnwrap(EVMSendNetwork(rawValue: probe.chain.rawValue))
            let endpoint = URL(string: "https://rpc.ankr.com")!.appendingPathComponent(probe.chain.rpcPath).appendingPathComponent(key)
            let client = try EVMSendClient(network: network, endpoints: [endpoint])
            for token in [false, true] {
                var success = false
                for sender in (token ? probe.holders : probe.candidates).prefix(8) {
                    do {
                        let plan = try await client.quote(sender: sender, recipient: "0x000000000000000000000000000000000000dead",
                            reference: token ? probe.token.reference : "native", decimals: token ? probe.token.decimals : 18, amount: "1")
                        try plan.validate()
                        XCTAssertGreaterThan(plan.fee, 0)
                        print("MAINNET_FEE_READ chain=\(network.rawValue) token=\(token) success=true broadcasts=0")
                        success = true; break
                    } catch {
                        // Public senders can spend between sampling and quoting.
                        // Bound retries to the explicit public sample list.
                        continue
                    }
                }
                XCTAssertTrue(success, "\(network.rawValue) \(token ? "token" : "native") fee quote")
            }
        }
    }

    /// Explicit opt-in, read-only mainnet validation. No wallet secrets or broadcast.
    func testLiveMainnetInventories() async throws {
        guard let config = ProcessInfo.processInfo.environment["OATH_MAINNET_RPC_CONFIG"] else {
            throw XCTSkip("Opt-in ANKR mainnet reads")
        }
        let values = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: config)))
        let key = try XCTUnwrap(values["AnkrAPIKey"])
        for chain in chains {
            let value = try await IndexedEVMClient(chain: chain, apiKey: key).inventory(owner: "0x0000000000000000000000000000000000000001")
            XCTAssertTrue(value.complete, chain.rawValue)
            XCTAssertEqual(value.chain, chain)
            XCTAssertEqual(value.holdings.count, try RPCCatalogTokens.tokens(chain: chain).count + 1)
            XCTAssertTrue(value.holdings.allSatisfy { $0.amount != nil })
            print("MAINNET_RPC_READ chain=\(chain.rawValue) verified_holdings=\(value.holdings.count) broadcasts=0")
        }
    }
}
