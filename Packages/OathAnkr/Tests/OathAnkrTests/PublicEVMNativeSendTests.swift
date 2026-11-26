import XCTest
@testable import OathAnkr

final class PublicEVMNativeSendTests: XCTestCase, @unchecked Sendable {
    func testPublicTestnetProfilesKeepDistinctChainIDsAndMainnetFeePolicies() {
        let profiles: [(EVMSendNetwork, EVMSendNetwork, UInt64)] = [
            (.taikoHoodi, .taiko, 167013), (.gnosisChiado, .gnosis, 10200), (.hyperevmTestnet, .hyperevm, 998), (.robinhoodTestnet, .robinhood, 46630),
            (.bnbTestnet, .bnb, 97), (.avalancheFuji, .avalanche, 43113), (.polygonAmoy, .polygon, 80002),
            (.telosTestnet, .telos, 41), (.somniaTestnet, .somnia, 50312), (.flareCoston2, .flare, 114),
            (.baseSepolia, .base, 84532), (.optimismSepolia, .optimism, 11155420), (.unichainSepolia, .unichain, 1301),
            (.monadTestnet, .monad, 10143), (.xlayerTestnet, .xlayer, 1952), (.lineaSepolia, .linea, 59141)
        ]
        for (testnet, mainnet, id) in profiles {
            XCTAssertTrue(testnet.isTestnet)
            XCTAssertFalse(mainnet.isTestnet)
            XCTAssertEqual(testnet.chainID, id)
            XCTAssertNotEqual(id, mainnet.chainID)
            XCTAssertEqual(testnet.oracle, mainnet.oracle)
            XCTAssertEqual(testnet.finalityTag, mainnet.finalityTag)
        }
    }

    func testFreshPublicTestnetNativeSend() async throws {
        try await verifyTransfer(fixtureVariable: "OATH_NATIVE_EVM_TESTNET_FIXTURE", isToken: false)
    }

    func testWorldPlasmaAndElysiumTestnets() {
        let profiles: [(EVMSendNetwork, UInt64, String, Bool)] = [
            (.worldchainSepolia, 4801, "ETH", true),
            (.plasmaTestnet, 9746, "XPL", false),
            (.elysiumTestnet, 99801, "HYPE", false)
        ]
        for (network, chainID, symbol, opStack) in profiles {
            XCTAssertTrue(network.isTestnet)
            XCTAssertEqual(network.chainID, chainID)
            XCTAssertEqual(network.symbol, symbol)
            XCTAssertEqual(network.opStack, opStack)
        }
    }

    func testFreshPublicTestnetERC20Send() async throws {
        try await verifyTransfer(fixtureVariable: "OATH_ERC20_TESTNET_FIXTURE", isToken: true)
    }

    func testElysiumTestnetForkNativeAndERC20Transfers() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_LOCAL_PORT"] != nil else {
            throw XCTSkip("Explicit local Elysium fork required")
        }
        try await verifyTransfer(fixtureVariable: "OATH_ELYSIUM_FORK_NATIVE", isToken: false, localFork: true)
        try await verifyTransfer(fixtureVariable: "OATH_ELYSIUM_FORK_ERC20", isToken: true, localFork: true)
    }

    /// Read-only verification of past public transfers. This fixture contains only
    /// chain names, public addresses, transaction hashes and amounts in base units.
    func testReceivedTransfersAgainstHistoryAndBlockBalances() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_EVM_TESTNET_RECEIPTS"] else {
            throw XCTSkip("Public transfer receipts required")
        }
        struct Transfer: Decodable {
            let network: EVMSendNetwork
            let hash, sender, recipient, reference, amount: String
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let transfers = try JSONDecoder().decode([Transfer].self, from: data)
        XCTAssertFalse(transfers.isEmpty)
        for transfer in transfers {
            let client = try testClient(for: transfer.network)
            let history = try await client.historyEvidence(hash: transfer.hash, includeExecution: false)
            let receipt = history.receipt
            let tx = history.transaction
            let tag = receipt["blockNumber"]
            let height = try EVMSendClient.uint(tag)
            XCTAssertEqual(receipt["transactionHash"].string, transfer.hash)
            XCTAssertEqual(receipt["status"].string, "0x1")
            XCTAssertEqual(tx["hash"].string, transfer.hash)
            XCTAssertEqual(tx["from"].string?.lowercased(), transfer.sender.lowercased())
            XCTAssertEqual(tx["blockHash"].string, receipt["blockHash"].string)
            let recipient = try EVMSendIdentity.address(transfer.recipient)
            let reference = try EVMSendIdentity.reference(transfer.reference)
            let canonical = try await client.block(tag, full: reference == "native")
            XCTAssertEqual(canonical["hash"].string, receipt["blockHash"].string)
            XCTAssertEqual(tx["to"].string?.lowercased(), reference == "native" ? recipient : reference)
            if reference == "native" {
                XCTAssertEqual(try EVMSendClient.quantity(tx["value"]), transfer.amount)
                let transactions = try XCTUnwrap(canonical["transactions"].array)
                let incoming = transactions.filter { $0["to"].string?.lowercased() == recipient }
                XCTAssertTrue(incoming.contains { $0["hash"].string == transfer.hash })
            } else {
                let padding = "0x" + String(repeating: "0", count: 24)
                let senderTopic = padding + transfer.sender.lowercased().dropFirst(2)
                let recipientTopic = padding + recipient.dropFirst(2)
                let topics = [EVMSendIdentity.transferTopic, senderTopic, recipientTopic]
                let logs = try XCTUnwrap(receipt["logs"].array)
                let log = try XCTUnwrap(logs.first {
                    $0["address"].string?.lowercased() == reference && $0["topics"].array?.compactMap(\.string) == topics
                })
                XCTAssertEqual(try EVMSendClient.quantity(log["data"]), transfer.amount)
                // Start with only the recipient and block, as when discovering an incoming token.
                let filter: SolanaJSON = .object(["fromBlock": tag, "toBlock": tag,
                    "topics": .array([.string(EVMSendIdentity.transferTopic), .null, .string(recipientTopic)])])
                let matches = try await client.rpc("eth_getLogs", [filter])
                let incoming = try XCTUnwrap(matches.array)
                XCTAssertTrue(incoming.contains {
                    $0["transactionHash"].string == transfer.hash && $0["address"].string?.lowercased() == reference
                })
            }
            guard height > 0 else { throw EVMSendError.malformed }
            let previous = height - 1
            let before = try await client.balance(owner: recipient, reference: reference,
                                                   tag: .string("0x" + String(previous, radix: 16)))
            let after = try await client.balance(owner: recipient, reference: reference, tag: tag)
            XCTAssertEqual(after, try EVMSendAmount.add(before, transfer.amount))
        }
    }

    private func verifyTransfer(fixtureVariable: String, isToken: Bool, localFork: Bool = false) async throws {
        guard let path = ProcessInfo.processInfo.environment[fixtureVariable] else {
            throw XCTSkip("Explicit disposable public EVM testnet fixture required")
        }
        struct Fixture: Decodable {
            let network, sender, recipient: String
            let key: Data
            let amount, reference: String?
            let decimals: Int?
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard let network = EVMSendNetwork(rawValue: fixture.network), network.isTestnet,
              !localFork || network == .elysiumTestnet,
              try EVMSendCrypto.address(privateKey: fixture.key) == fixture.sender.lowercased() else {
            throw EVMSendError.configuration
        }
        let reference = try EVMSendIdentity.reference(fixture.reference ?? "native")
        let decimals = try isToken ? XCTUnwrap(fixture.decimals) : 18
        guard (reference != "native") == isToken else { throw EVMSendError.configuration }
        let client = try testClient(for: network, localFork: localFork)
        struct Submission: Codable { let plan: EVMSendPlan; let signed: EVMSignedSend }
        let journal = URL(fileURLWithPath: path).appendingPathExtension("submission")
        let plan: EVMSendPlan
        let signed: EVMSignedSend
        var receipt: EVMSendReceipt
        let amount = fixture.amount ?? "1000000000000000"
        if FileManager.default.fileExists(atPath: journal.path) {
            let previous = try JSONDecoder().decode(Submission.self, from: Data(contentsOf: journal))
            plan = previous.plan
            signed = previous.signed
            guard plan.network == network, plan.sender == fixture.sender.lowercased(),
                  plan.recipient == fixture.recipient.lowercased(), plan.reference == reference,
                  plan.decimals == decimals, plan.amount == amount else { throw EVMSendError.changed }
            receipt = try await client.submit(signed, plan: plan)
        } else {
            let before = try await client.balance(owner: fixture.recipient, reference: reference)
            guard before == "0" else { throw EVMSendError.changed }
            let sender = try await client.prepareSender(sender: fixture.sender, reference: reference, decimals: decimals)
            plan = try await client.quote(sender: fixture.sender, recipient: fixture.recipient, reference: reference,
                                          decimals: decimals, amount: amount, preparedSender: sender)
            try await client.preflight(plan)
            signed = try EVMSendCrypto.sign(plan, privateKey: fixture.key)
            try JSONEncoder().encode(Submission(plan: plan, signed: signed)).write(to: journal, options: .withoutOverwriting)
            receipt = try await client.submit(signed, plan: plan, reconcileFirst: false)
        }
        // L1 and rollup finality can lag inclusion by many minutes.
        func waitForFinality(_ initial: EVMSendReceipt) async throws -> EVMSendReceipt {
            var latest = initial
            let deadline = ContinuousClock.now.advanced(by: .seconds(45 * 60))
            while (latest.outcome == .accepted || latest.outcome == .unknown) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .seconds(10))
                latest = try await client.status(signed, plan: plan)
            }
            return latest
        }
        receipt = try await waitForFinality(receipt)
        guard receipt.outcome == .confirmed else {
            XCTFail("Finality was not established for \(signed.hash), outcome \(receipt.outcome)")
            return
        }
        let balance = try await client.balance(owner: fixture.recipient, reference: reference)
        XCTAssertEqual(balance, plan.amount)
        let replay = try await waitForFinality(client.submit(signed, plan: plan))
        XCTAssertEqual(replay.outcome, .confirmed)
        let afterReplay = try await client.balance(owner: fixture.recipient, reference: reference)
        XCTAssertEqual(afterReplay, balance)
        print("EVM_\(localFork ? "FORK" : "TESTNET")_\(isToken ? "ERC20" : "NATIVE") network=\(network.rawValue) hash=\(signed.hash) outcome=\(receipt.outcome)")
    }

    private func testClient(for network: EVMSendNetwork, localFork: Bool = false) throws -> EVMSendClient {
        let endpoint: String
        switch network {
        case .worldchainSepolia: endpoint = "https://worldchain-sepolia.g.alchemy.com/public"
        case .plasmaTestnet: endpoint = "https://testnet-rpc.plasma.to"
        case .elysiumTestnet: endpoint = "https://testnet-rpc.elysium.kinetiq.xyz"
        case .taikoHoodi: endpoint = "https://rpc.hoodi.taiko.xyz"
        case .gnosisChiado: endpoint = "https://rpc.chiadochain.net"
        case .hyperevmTestnet: endpoint = "https://rpc.hyperliquid-testnet.xyz/evm"
        case .robinhoodTestnet: endpoint = "https://rpc.testnet.chain.robinhood.com"
        case .bnbTestnet: endpoint = "https://bsc-testnet.bnbchain.org"
        case .polygonAmoy: endpoint = "https://polygon-amoy-bor-rpc.publicnode.com"
        case .avalancheFuji: endpoint = "https://api.avax-test.network/ext/bc/C/rpc"
        case .monadTestnet: endpoint = "https://testnet-rpc.monad.xyz"
        case .xlayerTestnet: endpoint = "https://testrpc.xlayer.tech/terigon"
        case .lineaSepolia: endpoint = "https://rpc.sepolia.linea.build"
        case .somniaTestnet: endpoint = "https://dream-rpc.somnia.network"
        case .flareCoston2: endpoint = "https://coston2-api.flare.network/ext/C/rpc"
        case .baseSepolia: endpoint = "https://sepolia.base.org"
        case .optimismSepolia: endpoint = "https://sepolia.optimism.io"
        case .unichainSepolia: endpoint = "https://sepolia.unichain.org"
        case .telosTestnet: endpoint = "https://rpc.testnet.telos.net"
        case .ethereumSepolia: endpoint = "https://ethereum-sepolia-rpc.publicnode.com"
        case .arbitrumSepolia: endpoint = "https://sepolia-rollup.arbitrum.io/rpc"
        case .celoSepolia: endpoint = "https://forno.celo-sepolia.celo-testnet.org"
        case .zerogGalileo: endpoint = "https://evmrpc-testnet.0g.ai"
        case .chilizSpicy: endpoint = "https://spicy-rpc.chiliz.com"
        case .filecoinCalibration: endpoint = "https://api.calibration.node.glif.io/rpc/v1"
        case .iotexTestnet: endpoint = "https://babel-api.testnet.iotex.io"
        case .seiTestnet: endpoint = "https://evm-rpc-testnet.sei-apis.com"
        default: throw EVMSendError.configuration
        }
        let transport: any AnkrTransport
        switch network {
        case .monadTestnet: transport = PacedTestnetTransport(interval: .milliseconds(650))
        case .plasmaTestnet: transport = PacedTestnetTransport(interval: .seconds(1))
        default: transport = AnkrHTTPTransport()
        }
        return try EVMSendClient(network: network, endpoints: [try XCTUnwrap(URL(string: endpoint))],
                                       transport: localFork ? EVMLocalTransport() : transport)
    }
}

// Respect the public endpoints' quotas even when the client issues parallel reads.
private actor PacedTestnetTransport: AnkrTransport {
    private let transport = AnkrHTTPTransport()
    private let interval: Duration
    private var nextRequest = ContinuousClock.now

    init(interval: Duration) { self.interval = interval }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let start = max(.now, nextRequest)
        nextRequest = start.advanced(by: interval)
        try await ContinuousClock().sleep(until: start)
        return try await transport.sendPreservingTransportError(request)
    }
}
