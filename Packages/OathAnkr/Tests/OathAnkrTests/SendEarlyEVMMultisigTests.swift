import XCTest
@testable import OathAnkr

@MainActor final class SendEarlyEVMMultisigTests: XCTestCase {
    func testEveryEnabledEVMMultisigPreparesBeforeFeesAndRetainsPolicyChecks() async throws {
        let owners = try [21, 22].map { try EVMSendCrypto.address(privateKey: Data(repeating: UInt8($0), count: 32)) }
        let policy = try EVMMultisigPolicy(required: 2, owners: owners, salt: Data(repeating: 1, count: 32), executor: EVMSendCrypto.address(privateKey: Data(repeating: 9, count: 32)))
        let runtimeURL = try XCTUnwrap(Bundle.module.url(forResource: "Safe141Runtime", withExtension: "json", subdirectory: "Fixtures/SendPreparation"))
        let runtime = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: runtimeURL))
        // Published Safe 1.4.1 artifact code must pass the production pinned hashes.
        let networks = EVMSendNetwork.allCases.filter { !$0.isTestnet && $0 != .cronos }
        XCTAssertEqual(networks.count, 28)
        for network in networks {
            for token in [false, true] {
                let transport = SafePreparationFixture(network: network, policy: policy, runtime: runtime)
                let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.invalid")!], transport: transport)
                let state = try await client.multisigState(policy); XCTAssertTrue(state.configured)
                let reference = token ? "0x" + String(repeating: "3", count: 40) : "native", decimals = token ? 6 : 18
                let prepared = try await client.prepareSender(sender: policy.address, reference: reference, decimals: decimals)
                let early = await transport.methods
                XCTAssertFalse(early.contains("eth_gasPrice") || early.contains("eth_estimateGas") || early.contains("linea_estimateGas"))
                let plan = try await client.quoteMultisig(policy: policy, recipient: "0x" + String(repeating: "a", count: 40), reference: reference, decimals: decimals, amount: "123", preparedSender: prepared)
                try plan.validate(); XCTAssertEqual(plan.amount, "123"); XCTAssertNotNil(plan.multisig)
                await transport.installGuard()
                do { _ = try await client.quoteMultisig(policy: policy, recipient: plan.recipient, reference: reference, decimals: decimals, amount: "123", preparedSender: prepared); XCTFail("Prepared balance bypassed a changed Safe policy on \(network.rawValue)") }
                catch { XCTAssertEqual(error as? EVMSendError, .changed) }
            }
        }
    }
}

private actor SafePreparationFixture: AnkrTransport {
    let base: EVMSendFixtureTransport
    let policy: EVMMultisigPolicy
    let runtime: [String: String]
    var methods: [String] = []
    var hasGuard = false
    init(network: EVMSendNetwork, policy: EVMMultisigPolicy, runtime: [String: String]) {
        base = .init(network: network); self.policy = policy; self.runtime = runtime
    }
    func installGuard() { hasGuard = true }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        var responses: [SolanaJSON] = []
        for call in payload.array ?? [payload] {
            let method = try XCTUnwrap(call["method"].string), params = call["params"].array ?? []
            methods.append(method)
            var result: SolanaJSON?
            if method == "eth_getCode" {
                let address = params[0].string
                result = .string(address == EVMMultisigPolicy.factory ? runtime["factory"]! : address == EVMMultisigPolicy.singleton ? runtime["singleton"]! : "0x" + EVMMultisigPolicy.proxyRuntime)
            } else if method == "eth_getStorageAt" {
                if params[1].string == "0x0" { result = .string(try "0x" + TronSendCrypto.hex(SafeABI.address(EVMMultisigPolicy.singleton))) }
                else { result = .string("0x" + String(repeating: "0", count: 63) + (hasGuard ? "1" : "0")) }
            } else if method == "eth_call", params[0]["to"].string == (try policy.address) {
                let data = params[0]["data"].string ?? ""
                func selector(_ text: String) -> String { "0x" + TronSendCrypto.hex(SafeABI.selector(text)) }
                if data == selector("getOwners()") {
                    result = .string(try "0x" + TronSendCrypto.hex(SafeABI.uint(32) + SafeABI.uint(policy.owners.count) + policy.owners.map(SafeABI.address).reduce(Data(), +)))
                } else if data == selector("getThreshold()") { result = .string("0x" + String(policy.required, radix: 16)) }
                else if data == selector("nonce()") { result = .string("0x0") }
                else if data.hasPrefix(selector("getModulesPaginated(address,uint256)")) {
                    result = .string(try "0x" + TronSendCrypto.hex(SafeABI.uint(64) + SafeABI.uint(1) + SafeABI.uint(0)))
                }
            }
            if let result {
                responses.append(.object(["jsonrpc": .string("2.0"), "id": call["id"], "result": result]))
            } else {
                var forwarded = request; forwarded.httpBody = try JSONEncoder().encode(call)
                let (data, status) = try await base.send(forwarded); XCTAssertEqual(status, 200)
                responses.append(try JSONDecoder().decode(SolanaJSON.self, from: data))
            }
        }
        return (try JSONEncoder().encode(payload.array == nil ? responses[0] : .array(responses)), 200)
    }
}
