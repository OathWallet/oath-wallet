import XCTest
import OathDiagnostics
@testable import OathAnkr

@MainActor final class EVMGasAllowanceFundingTests: XCTestCase {
    private let sender = "0x" + String(repeating: "1", count: 40)
    private let recipient = "0x" + String(repeating: "2", count: 40)
    private let token = "0x" + String(repeating: "3", count: 40)

    private func client(_ transport: GasAllowanceTransport) throws -> EVMSendClient {
        try EVMSendClient(network: transport.base.network,
            endpoints: [URL(string: "https://one.example")!, URL(string: "https://two.example")!],
            transport: transport)
    }

    private func quote(_ client: EVMSendClient, native: Bool = false, maximum: Bool = false) async throws -> EVMSendPlan {
        try await client.quote(sender: sender, recipient: recipient, reference: native ? "native" : token,
            decimals: native ? 18 : 6, amount: "100", maximum: maximum)
    }

    func testZeroNativeBalanceStopsBeforeGasEstimation() async throws {
        for network in EVMSendNetwork.allCases {
            let transport = GasAllowanceTransport(network: network, balance: "0", message: "insufficient funds for transfer")
            do { _ = try await quote(client(transport)); XCTFail(network.rawValue) }
            catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance, network.rawValue) }
            let estimates = await transport.base.estimates
            let broadcasts = await transport.base.broadcasts
            XCTAssertTrue(estimates.isEmpty, network.rawValue)
            XCTAssertEqual(broadcasts, 0)
        }
    }

    func testDustNativeBalanceShowsFeeShortageAcrossEveryEVMNetwork() async throws {
        for network in EVMSendNetwork.allCases {
            let transport = GasAllowanceTransport(network: network, balance: "1", message: "gas required exceeds allowance (0)")
            do { _ = try await quote(client(transport)); XCTFail(network.rawValue) }
            catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance, network.rawValue) }
            let broadcasts = await transport.base.broadcasts
            XCTAssertEqual(broadcasts, 0, network.rawValue)
            let rejected = await transport.rejections
            XCTAssertLessThanOrEqual(rejected, 1, "No provider retry for a funding rejection: \(network)")
        }
    }

    func testArbitrumTokenDustAndPartialGasFundingCanRecoverAfterDeposit() async throws {
        // These are the real Geth/Nitro envelope shapes, including a nonzero
        // allowance sufficient for a simple payment but not an ERC-20 call.
        for (balance, message) in [
            ("1", "gas required exceeds allowance (0)"),
            ("1025000000000001", "gas required exceeds allowance (25000)")
        ] {
            let transport = GasAllowanceTransport(balance: balance, message: message)
            let client = try client(transport)
            do { _ = try await quote(client); XCTFail("Accepted underfunded token quote") }
            catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
            let failures = await transport.rejections
            XCTAssertEqual(failures, 1)
            let calls = await transport.base.estimates
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(try EVMSendClient.uint(calls[0]["maxFeePerGas"]), 41_000_000_000,
                           "Preserve the real fee cap used for Arbitrum estimation")
            await transport.deposit()
            let plan = try await quote(client)
            XCTAssertGreaterThan(plan.fee, 0)
            try await client.preflight(plan)
            let broadcasts = await transport.base.broadcasts
            XCTAssertEqual(broadcasts, 0, "Quote, recovery and preflight must not submit funds")
        }
    }

    func testNativeTransferValueAndMaxUseTheActualSimulationValue() async throws {
        for maximum in [false, true] {
            let balance = maximum ? "820000000000001" : "820000000000101"
            let transport = GasAllowanceTransport(balance: balance, message: "gas required exceeds allowance (20000)")
            do { _ = try await quote(client(transport), native: true, maximum: maximum); XCTFail() }
            catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
        }
    }

    func testLegacyGasPriceAndEIP1559FeeCapBothIdentifyDust() async throws {
        for legacy in [false, true] {
            let transport = GasAllowanceTransport(balance: "1", message: "gas required exceeds allowance (0)", legacy: legacy)
            do { _ = try await quote(client(transport)); XCTFail() }
            catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
            let estimates = await transport.base.estimates
            XCTAssertFalse(try XCTUnwrap(estimates.first)[legacy ? "gasPrice" : "maxFeePerGas"].isNull)
        }
    }

    func testOtherRejectionsAndUncorroboratedAllowancesKeepTheirOriginalError() async throws {
        for (balance, message, code) in [
            ("1", "execution reverted: gas required exceeds allowance (0)", -32000),
            ("1", "gas required exceeds allowance (0)", 3),
            ("1", "gas required exceeds allowance (5000000)", -32000),
            ("1000000000000000000", "gas required exceeds allowance (25000)", -32000),
            ("1", "arbitrary provider rejection", -32000)
        ] {
            let transport = GasAllowanceTransport(balance: balance, message: message, code: code)
            do { _ = try await quote(client(transport)); XCTFail(message) }
            catch { XCTAssertEqual(error as? EVMSendError, .rpc(code), message) }
            let failures = await transport.rejections
            XCTAssertEqual(failures, 1)
        }
    }

    func testAllowanceProofRequiresExactBoundedMessageAndBalance() {
        let funding = EVMGasEstimateFunding(nativeBalance: "201", value: "100", feePerGas: 10, gasLimit: 20)
        XCTAssertTrue(funding.provesShortage("gas required exceeds allowance (10)"))
        for message in ["gas required exceeds allowance (9)", "gas required exceeds allowance (11)",
                        "gas required exceeds allowance (-1)", "gas required exceeds allowance (+10)",
                        "gas required exceeds allowance (18446744073709551616)",
                        "gas required exceeds allowance (10) extra", "gas required exceeds allowance ()",
                        String(repeating: "x", count: 129)] {
            XCTAssertFalse(funding.provesShortage(message), message)
        }
        XCTAssertFalse(funding.provesShortage(nil))
        XCTAssertFalse(EVMGasEstimateFunding(nativeBalance: "201", value: "100", feePerGas: 10, gasLimit: 10)
            .provesShortage("gas required exceeds allowance (10)"), "Do not relabel an explicit gas cap")
        XCTAssertFalse(EVMGasEstimateFunding(nativeBalance: "99", value: "100", feePerGas: 10, gasLimit: 20)
            .provesShortage("gas required exceeds allowance (0)"))
        XCTAssertFalse(EVMGasEstimateFunding(nativeBalance: "201", value: "0", feePerGas: 0, gasLimit: 20)
            .provesShortage("gas required exceeds allowance (0)"))
        XCTAssertTrue(EVMGasEstimateFunding(nativeBalance: "100000000000000000000000", value: "0",
            feePerGas: 100_000_000_000_000, gasLimit: 10_000_000_000)
            .provesShortage("gas required exceeds allowance (1000000000)"), "No UInt64 wei overflow")
    }

    func testOriginalRPCFailureRemainsPrivacyFilteredInDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_ALLOWANCE_DIAGNOSTICS_TEST"] == "1" else {
            throw XCTSkip("Run alone to isolate the process-wide diagnostics outbox")
        }
        let reports = GasAllowanceReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let transport = GasAllowanceTransport(balance: "1", message: "gas required exceeds allowance (0)")
        do { _ = try await quote(client(transport)); XCTFail() }
        catch { XCTAssertEqual(error as? SendFeeFundingError, .insufficientNativeBalance) }
        for _ in 0..<200 {
            if await reports.events.contains(where: { $0.operation == "rpc_response" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events
        XCTAssertTrue(events.contains { $0.operation == "rpc_response" && $0.error.message == "gas required exceeds allowance (0)" })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [sender, recipient, token, "nativeBalance", "maxFeePerGas", "params", "httpBody"] {
            XCTAssertFalse(encoded.contains(secret), secret)
        }
        XCTAssertTrue(encoded.contains("-32000"))
    }
}

/// Feed actual RPC error envelopes through the production decoder, quote and
/// preflight. Balance/nonce/chain/token reads use the normal production fixtures.
private actor GasAllowanceTransport: AnkrTransport {
    let base: EVMSendFixtureTransport
    let code: Int
    var message: String?
    var rejections = 0

    init(network: EVMSendNetwork = .arbitrum, balance: String, message: String, code: Int = -32000, legacy: Bool = false) {
        base = EVMSendFixtureTransport(legacy ? "legacy" : "normal", network: network, nativeBalance: balance, gasEstimate: 60_000)
        self.message = message
        self.code = code
    }

    func deposit() async {
        await base.fund("1000000000000000000")
        message = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await base.send(request)
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array ?? []
        guard let message, let estimate = calls.first(where: { $0["method"].string == "eth_estimateGas" }),
              let transaction = estimate["params"].array?.first,
              !transaction["maxFeePerGas"].isNull || !transaction["gasPrice"].isNull else { return response }
        rejections += 1
        let rows = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: response.0).array).map { row in
            row["id"] == estimate["id"] ? SolanaJSON.object([
                "jsonrpc": .string("2.0"), "id": row["id"],
                "error": .object(["code": .number(String(code)), "message": .string(message)])
            ]) : row
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows)), response.1)
    }
}

private actor GasAllowanceReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}
