import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor SuiObjectTransport: AnkrTransport {
    let responses: [Data]
    var calls = 0
    var queries: [String] = []
    init(_ responses: [Data]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        queries.append(String(decoding: request.httpBody ?? Data(), as: UTF8.self))
        let response = responses[min(calls, responses.count - 1)]; calls += 1
        return (response, 200)
    }
}
final class WalletConnectSuiObjectReviewTests: XCTestCase, @unchecked Sendable {
    let key = Data(repeating: 7, count: 32) // Public synthetic fixture, never funded.
    let id = try! SuiIdentity.address("0xcafe")
    let recipient = try! SuiIdentity.address("0xbeef")
    let digest = SuiSendCrypto.base58(Data(repeating: 0, count: 32))
    let treasury = "0x2::coin::TreasuryCap<0xa::example::TEST>"
    var sender: String { try! SuiSendCrypto.address(privateKey: key) }
    enum Path { case direct, result, moveCall }
    func request(_ method: String = "sui_signTransaction", path: Path = .direct, sponsored: Bool = false) throws -> WalletConnectSuiRequest {
        let ref = try SuiBCS.address(id) + SuiBCS.u64(1) + SuiBCS.vector(Data(repeating: 0, count: 32))
        let pure = try Data([0]) + SuiBCS.vector(SuiBCS.address(recipient))
        let inputs = path == .result ? [pure] : [Data([1,0]) + ref, pure]
        var commands: [Data]
        switch path {
        case .direct: commands = [Data([1]) + SuiBCS.list([SuiBCS.input(0)]) + SuiBCS.input(1)]
        case .result:
            let call = try Data([0]) + SuiBCS.address("0xa") + SuiBCS.string("factory") + SuiBCS.string("make") + Data([0,0])
            commands = [call, Data([1]) + SuiBCS.list([SuiBCS.result(0)]) + SuiBCS.input(0)]
        case .moveCall:
            commands = [try Data([0]) + SuiBCS.address("0x2") + SuiBCS.string("transfer") + SuiBCS.string("public_transfer") + SuiBCS.list([SuiBCS.type(treasury)]) + SuiBCS.list([SuiBCS.input(0), SuiBCS.input(1)])]
        }
        var bytes = Data([0,0]) + SuiBCS.list(inputs) + SuiBCS.list(commands)
        bytes += try SuiBCS.address(sender)
        bytes += try SuiBCS.list([SuiBCS.address("0x1") + SuiBCS.u64(1) + SuiBCS.vector(Data(repeating: 0, count: 32))])
        bytes += try SuiBCS.address(sponsored ? "0x55" : sender)
        bytes += SuiBCS.u64(1000) + SuiBCS.u64(10_000_000) + Data([0])
        return try .init(method: method, chain: "sui:testnet", account: sender,
                         params: JSONEncoder().encode(["address": sender, "transaction": bytes.base64EncodedString()]))
    }
    func state(type: String, owner: String, kind: String = "AddressOwner", version: Int = 1) -> [String: Any] {
        ["address": id, "version": version, "digest": digest,
         "owner": ["__typename": kind, "address": ["address": owner]],
         "asMoveObject": ["contents": ["type": ["repr": type]]], "asMovePackage": NSNull()]
    }
    func change(type: String? = nil, owner: String? = nil, created: Bool = false) -> [String: Any] {
        ["address": id, "idCreated": created, "idDeleted": false,
         "inputState": created ? NSNull() : state(type: type ?? treasury, owner: sender),
         "outputState": state(type: type ?? treasury, owner: owner ?? recipient, version: 2)]
    }
    func response(_ changes: [[String: Any]], gas: Bool = false, more: Bool = false) throws -> Data {
        let balances: [[String: Any]] = gas ? [["owner": ["address": sender], "coinType": ["repr": "0x2::sui::SUI"], "amount": "-1400"]] : []
        return try JSONSerialization.data(withJSONObject: ["data": ["chainIdentifier": SuiSendNetwork.testnet.chainIdentifier,
            "epoch": ["epochId": "100"], "simulateTransaction": ["effects": ["status": "SUCCESS",
                "gasEffects": ["gasSummary": ["computationCost": "1000", "storageCost": "500", "storageRebate": "100"]],
                "balanceChanges": ["nodes": balances, "pageInfo": ["hasNextPage": false]],
                "objectChanges": ["nodes": changes, "pageInfo": ["hasNextPage": more]]]]]])
    }
    func testCapabilitiesVisibleWithEmptyAndGasOnlyBalancesForBothSigningMethods() async throws {
        for method in ["sui_signTransaction", "sui_signAndExecuteTransaction"] {
            for gas in [false, true] {
                for (type, authority) in [(treasury, WalletConnectSuiAuthority.mint), ("0x2::package::UpgradeCap", .upgrade)] {
                    let request = try request(method)
                    let transport = SuiObjectTransport([try response([change(type: type)], gas: gas)])
                    let client = try SuiSendClient(network: .testnet, transport: transport)
                    let review = try await client.walletConnectReview(request)
                    let object = try XCTUnwrap(review.objectChanges?.first)
                    XCTAssertEqual(object.id, id); XCTAssertEqual(object.type, type)
                    XCTAssertEqual(object.authority, authority); XCTAssertEqual(object.after?.owner.address, recipient)
                    XCTAssertEqual(review.changes.count, gas ? 1 : 0)
                    XCTAssertTrue(try XCTUnwrap(review.actions?.first).contains(recipient))
                    XCTAssertTrue(try XCTUnwrap(review.actions?.first).contains(id))
                    XCTAssertFalse(try XCTUnwrap(review.actions?.first).contains("Input[1]"))
                    try await client.walletConnectPreflight(review)
                    let signed = try request.sign(privateKey: key, review: review)
                    try SuiSendCrypto.verify(XCTUnwrap(signed.transaction), sender: sender)
                    let queries = await transport.queries
                    XCTAssertTrue(queries.allSatisfy { $0.contains("objectChanges(first:512)") && $0.contains("inputState") && $0.contains("outputState") })
                }
            }
        }
    }
    func testResultAndMoveCallTransfersIncludeResolvedObjectAndRecipient() async throws {
        for path in [Path.result, .moveCall] {
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([change(created: path == .result)])]))
            let input = try request(path: path), review = try await client.walletConnectReview(input)
            XCTAssertEqual(review.objectChanges?.first?.id, id)
            XCTAssertEqual(review.objectChanges?.first?.authority, .mint)
            XCTAssertEqual(review.objectChanges?.first?.after?.owner.address, recipient)
            XCTAssertNoThrow(try input.sign(privateKey: key, review: review))
        }
    }
    func testSponsoredSigningStillShowsCapabilityTransfer() async throws {
        let input = try request(sponsored: true)
        let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([change()])]))
        let review = try await client.walletConnectReview(input)
        XCTAssertNotEqual(review.gasOwner, sender)
        XCTAssertEqual(review.objectChanges?.first?.after?.owner.address, recipient)
        XCTAssertNoThrow(try input.sign(privateKey: key, review: review))
    }
    func testUnknownAuthorityAndSpoofedFrameworkNamesStayUnknown() async throws {
        for type in ["0xa::example::OwnerCap", "0xa::coin::TreasuryCap<0xb::token::T>", "0x2::package::UpgradeCapFake", "0xa::nft::NFT"] {
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([change(type: type)])]))
            let review = try await client.walletConnectReview(request())
            XCTAssertEqual(review.objectChanges?.first?.authority, .unknown)
        }
    }
    func testMissingTruncatedDuplicateAndMalformedObjectEffectsCannotBecomeFeeOnly() async throws {
        var noType = change(); var after = state(type: treasury, owner: recipient); after.removeValue(forKey: "asMoveObject"); noType["outputState"] = after
        var wrongID = change(); wrongID["address"] = "0x123"
        var wrongVersion = change(); wrongVersion["inputState"] = state(type: treasury, owner: sender, version: 3)
        var unknownOwner = change(); unknownOwner["outputState"] = state(type: treasury, owner: recipient, kind: "FutureOwner")
        var hiddenOwner = change(); hiddenOwner["outputState"] = NSNull()
        let responses = try [response([]), response([change()], more: true), response([change(), change()]), response([noType]), response([wrongID]), response([wrongVersion]), response([unknownOwner]), response([hiddenOwner])]
        for data in responses {
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([data]))
            do { _ = try await client.walletConnectReview(request()); XCTFail("Incomplete object review accepted") }
            catch { XCTAssertTrue(error is SuiSendError) }
        }
    }
    func testRecipientAndAuthorityChangesRequireNewApprovalDespiteIdenticalBalances() async throws {
        for modified in [change(owner: try SuiIdentity.address("0x777")), change(type: "0x2::package::UpgradeCap")] {
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([change()]), try response([modified])]))
            let review = try await client.walletConnectReview(request())
            do { try await client.walletConnectPreflight(review); XCTFail("Changed authority or recipient accepted") }
            catch { XCTAssertEqual(error as? SuiSendError, .changed) }
        }
    }
    func testLegacyBalanceOnlyReviewDecodesButCannotSign() throws {
        let input = try request(), parsed = try WalletConnectSuiTransaction(input.transaction!, network: .testnet, account: sender, executing: false)
        let legacy = WalletConnectSuiReview(request: input, changes: [], details: parsed.commands, gasOwner: sender, gasBudget: parsed.gasBudget, estimatedFee: 1400, createdAt: .now)
        let decoded = try JSONDecoder().decode(WalletConnectSuiReview.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.objectChanges)
        XCTAssertThrowsError(try input.sign(privateKey: key, review: decoded)) { XCTAssertEqual($0 as? SuiSendError, .changed) }
    }
    func testDeletedSharedImmutableAndObjectOwnedEffectsAreRetained() async throws {
        for kind in ["Shared", "Immutable", "ObjectOwner", "ConsensusAddressOwner"] {
            var object = change(); object["outputState"] = state(type: treasury, owner: recipient, kind: kind)
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([object])]))
            let review = try await client.walletConnectReview(request(path: .moveCall))
            XCTAssertNotNil(review.objectChanges?.first?.after?.owner)
        }
        var deleted = change(); deleted["outputState"] = NSNull(); deleted["idDeleted"] = true
        let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response([deleted])]))
        let review = try await client.walletConnectReview(request(path: .moveCall))
        XCTAssertEqual(review.objectChanges?.first?.deleted, true)
        XCTAssertEqual(review.objectChanges?.first?.authority, .mint)
        XCTAssertNil(review.objectChanges?.first?.after)
    }
    func testEmptyOrGasOnlyEffectsCannotHideResultObjectTransfer() async throws {
        let input = try request(path: .result)
        var gas = change(type: "0x2::coin::Coin<0x2::sui::SUI>", owner: sender)
        gas["address"] = "0x1"
        var before = state(type: "0x2::coin::Coin<0x2::sui::SUI>", owner: sender)
        before["address"] = "0x1"
        var after = before; after["version"] = 2
        gas["inputState"] = before; gas["outputState"] = after
        for changes in [[], [gas]] {
            let client = try SuiSendClient(network: .testnet, transport: SuiObjectTransport([try response(changes, gas: true)]))
            do { _ = try await client.walletConnectReview(input); XCTFail("Missing result object accepted") }
            catch { XCTAssertTrue(error is SuiSendError) }
        }
    }
    func testObjectReviewDiagnosticsExcludeTransactionAndObjectData() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SUI_REPORT_CAPTURE"] == "1" else { throw XCTSkip("Dedicated recorder-capture process") }
        actor Capture: DiagnosticTransport {
            var events: [DiagnosticEvent] = []
            func upload(_ batch: [DiagnosticEvent]) async throws { events += batch }
        }
        let capture = Capture(), folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        OathDiagnostics.configure(file: folder.appendingPathComponent("reports.json"), transport: capture)
        let ready = UUID()
        for _ in 0..<100 {
            OathDiagnostics.$operationID.withValue(ready) { OathDiagnostics.record(DiagnosticFailure("ready"), component:"fixture", operation:"ready") }
            try await Task.sleep(for:.milliseconds(10))
            if await capture.events.contains(where: { $0.operationID == ready }) { break }
        }
        let input = try request()
        let client = try SuiSendClient(network:.testnet, transport:SuiObjectTransport([try response([])]))
        do { _ = try await client.walletConnectReview(input); XCTFail("Missing object accepted") } catch { XCTAssertTrue(error is SuiSendError) }
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.operation == "wc_review" }) { break }
            try await Task.sleep(for:.milliseconds(10))
        }
        await OathDiagnostics.flush()
        let events = await capture.events.filter { $0.operation == "wc_review" }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.context["chain"], "sui")
        XCTAssertEqual(events.first?.context["stage"], "object_review")
        let text = String(decoding:try JSONEncoder().encode(events),as:UTF8.self)
        for sensitive in [id, recipient, sender, input.transaction!.base64EncodedString(), treasury] { XCTAssertFalse(text.contains(sensitive)) }
    }

    func testMultipleCapabilitiesRequireEveryObjectInThePreview() async throws {
        let secondID = try SuiIdentity.address("0xca02")
        func input(_ objectID: String) throws -> Data {
            try Data([1,0]) + SuiBCS.address(objectID) + SuiBCS.u64(1) + SuiBCS.vector(Data(repeating:0,count:32))
        }
        let inputs = try [input(id), input(secondID), Data([0]) + SuiBCS.vector(SuiBCS.address(recipient))]
        let command = Data([1]) + SuiBCS.list([SuiBCS.input(0),SuiBCS.input(1)]) + SuiBCS.input(2)
        var bytes = Data([0,0]) + SuiBCS.list(inputs) + SuiBCS.list([command])
        bytes += try SuiBCS.address(sender)
        bytes += try SuiBCS.list([SuiBCS.address("0x1") + SuiBCS.u64(1) + SuiBCS.vector(Data(repeating:0,count:32))])
        bytes += try SuiBCS.address(sender)
        bytes += SuiBCS.u64(1000) + SuiBCS.u64(10_000_000) + Data([0])
        let request = try WalletConnectSuiRequest(method:"sui_signTransaction",chain:"sui:testnet",account:sender,
            params:JSONEncoder().encode(["address":sender,"transaction":bytes.base64EncodedString()]))
        var second = change(type:"0x2::package::UpgradeCap"); second["address"] = secondID
        for key in ["inputState","outputState"] {
            var value = second[key] as! [String:Any]; value["address"] = secondID; second[key] = value
        }
        let client = try SuiSendClient(network:.testnet,transport:SuiObjectTransport([try response([change(),second])]))
        let review = try await client.walletConnectReview(request)
        XCTAssertEqual(Set(review.objectChanges?.map(\.id) ?? []), [id,secondID])
        XCTAssertEqual(Set(review.objectChanges?.map(\.authority.rawValue) ?? []), ["mint","upgrade"])
        XCTAssertNoThrow(try request.sign(privateKey:key,review:review))
        let incomplete = try SuiSendClient(network:.testnet,transport:SuiObjectTransport([try response([second])]))
        do { _ = try await incomplete.walletConnectReview(request); XCTFail("Omitted one of two authority transfers") }
        catch { XCTAssertTrue(error is SuiSendError) }
    }

}
