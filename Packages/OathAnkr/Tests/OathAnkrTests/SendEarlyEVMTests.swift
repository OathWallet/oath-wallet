import XCTest
@testable import OathAnkr

@MainActor final class SendEarlyEVMTests: XCTestCase {
    let sender = "0x" + String(repeating:"1",count:40), recipient = "0x" + String(repeating:"2",count:40)
    func testEveryEnabledEVMNativeAndTokenPreparesWithoutFeesThenQuotes() async throws {
        let networks = EVMSendNetwork.allCases.filter { !$0.isTestnet && $0 != .cronos && $0 != .arc }
        XCTAssertEqual(networks.count, 27)
        for network in networks {
            for token in [false,true] {
                let transport = EVMSendFixtureTransport(network:network)
                let client = try EVMSendClient(network:network,endpoints:[URL(string:"https://fixture.invalid")!],transport:transport)
                let reference = token ? "0x"+String(repeating:"3",count:40) : "native", decimals = token ? 6:18
                let prepared = try await client.prepareSender(sender:sender,reference:reference,decimals:decimals)
                let before = await transport.methods
                XCTAssertFalse(before.contains("eth_gasPrice")); XCTAssertFalse(before.contains("eth_estimateGas"))
                XCTAssertEqual(prepared.assetBalance,token ? "1000000":"1000000000000000000000")
                let plan = try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:"123",preparedSender:prepared)
                try plan.validate(); XCTAssertEqual(plan.amount,"123"); XCTAssertGreaterThan(plan.fee,0)
                let after = await transport.methods
                XCTAssertTrue(after.contains("eth_estimateGas") || after.contains("linea_estimateGas"))
                // HyperEVM does not provide historical state. Its fresh reads must remain.
                if network != .hyperevm {
                    XCTAssertEqual(after.filter{$0=="eth_getBalance"}.count,before.filter{$0=="eth_getBalance"}.count,network.rawValue)
                }
                let coldTransport = EVMSendFixtureTransport(network: network)
                let coldClient = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.invalid")!], transport: coldTransport)
                let cold = try await coldClient.quote(sender: sender, recipient: recipient, reference: reference, decimals: decimals, amount: "123")
                XCTAssertEqual(plan.amount, cold.amount); XCTAssertEqual(plan.fee, cold.fee)
                let coldMethods = await coldTransport.methods
                let warmMethods = Array(after.dropFirst(before.count))
                if network != .hyperevm {
                    XCTAssertLessThan(warmMethods.count, coldMethods.count, "Early verified reads must reduce Review requests on \(network.rawValue)")
                }
                let broadcasts = await transport.broadcasts; XCTAssertEqual(broadcasts,0)
            }
        }
    }
    func testArcPreparedNativeAndToken() async throws {
        for token in [false,true] {
            let transport = ArcSendFixtureTransport(), client = ArcSendClient(transport:transport)
            let reference = token ? "0x"+String(repeating:"3",count:40):"native", decimals = token ? 6:18
            let prepared = try await client.prepareSender(sender:sender,reference:reference,decimals:decimals)
            let plan = try await client.quote(sender:sender,recipient:recipient,reference:reference,decimals:decimals,amount:"123",preparedSender:prepared)
            try plan.validate(); XCTAssertEqual(plan.assetBalance,prepared.assetBalance)
        }
    }
    func testExpiredOrWrongIdentitySnapshotCannotOverrideFreshFunds() async throws {
        let transport = EVMSendFixtureTransport(network:.ethereum,nativeBalance:"1000000000000000000")
        let client = try EVMSendClient(network:.ethereum,endpoints:[URL(string:"https://fixture.invalid")!],transport:transport)
        let first = try await client.prepareSender(sender:sender,reference:"native",decimals:18)
        for age in [-60.0,60] {
            let invalid = try SendSenderSnapshot(chain:first.chain,sender:first.sender,reference:first.reference,decimals:18,assetBalance:first.assetBalance,nativeBalance:first.nativeBalance,observedAt:Date.now.addingTimeInterval(age),block:first.block)
            await transport.fund("0")
            do { _ = try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"123",preparedSender:invalid); XCTFail("Stale snapshot hid empty account") } catch { XCTAssertNotNil(error) }
        }
        for field in ["chain", "sender", "reference", "decimals"] {
            let invalid = try SendSenderSnapshot(chain: field == "chain" ? "base" : first.chain,
                sender: field == "sender" ? recipient : first.sender,
                reference: field == "reference" ? recipient : first.reference,
                decimals: field == "decimals" ? 6 : 18, assetBalance: first.assetBalance,
                nativeBalance: first.nativeBalance, observedAt: .now, block: first.block)
            do { _ = try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"123",preparedSender:invalid); XCTFail("Wrong \(field) bypassed current balance") }
            catch { XCTAssertEqual(error as? EVMSendError, .insufficientFunds) }
        }
        await transport.changeMode("reorged")
        do { _ = try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"123",preparedSender:first); XCTFail("Changed block reused old funds") }
        catch { XCTAssertEqual(error as? EVMSendError, .insufficientFunds) }
    }
    func testWrongNetworkAndDecimalsFailDuringSelection() async throws {
        for mode in ["wrongChain","decimals"] {
            let transport = EVMSendFixtureTransport(mode,network:.ethereum)
            let client = try EVMSendClient(network:.ethereum,endpoints:[URL(string:"https://fixture.invalid")!],transport:transport)
            do { _ = try await client.prepareSender(sender:sender,reference:"0x"+String(repeating:"3",count:40),decimals:6); XCTFail() } catch { XCTAssertTrue([EVMSendError.wrongNetwork,.metadataChanged].contains(error as? EVMSendError ?? .malformed)) }
        }
    }
}
