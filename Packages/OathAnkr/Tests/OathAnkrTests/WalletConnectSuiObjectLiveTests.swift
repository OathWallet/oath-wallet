import XCTest
@testable import OathAnkr

/// Opt-in live simulation only. The fixture must be a dedicated faucet-funded
/// testnet PTB creating a KioskOwnerCap and transferring it to a test recipient.
/// No private key, signing, execution, or physical device is used by this test.
final class WalletConnectSuiObjectLiveTests: XCTestCase, @unchecked Sendable {
    func testLiveSimulationResolvesCreatedCapabilityAndRecipient() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_SUI_OBJECT_REVIEW_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly prepared disposable testnet fixture")
        }
        struct Fixture: Decodable { let network: String, sender: String, recipient: String, transaction: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(fixture.network, "testnet")
        guard fixture.network == "testnet" else { throw SuiSendError.wrongNetwork }
        let client = try SuiSendClient(network: .testnet)
        for method in ["sui_signTransaction", "sui_signAndExecuteTransaction"] {
            let request = try WalletConnectSuiRequest(method: method, chain: "sui:testnet", account: fixture.sender,
                params: JSONEncoder().encode(["address":fixture.sender, "transaction":fixture.transaction]))
            let review = try await client.walletConnectReview(request)
            let cap = try XCTUnwrap(review.objectChanges?.first { $0.type == "0x2::kiosk::KioskOwnerCap" })
            XCTAssertTrue(cap.created)
            XCTAssertEqual(cap.after?.owner.address, fixture.recipient)
            XCTAssertEqual(cap.authority, .unknown, "Unrecognized capabilities must retain the permissions warning")
            XCTAssertEqual(cap.id.count, 66)
            try await client.walletConnectPreflight(review)
            print("PASS: live testnet simulation exposes KioskOwnerCap identity, type and recipient; preflight agrees; method=\(method)")
        }
    }
}
