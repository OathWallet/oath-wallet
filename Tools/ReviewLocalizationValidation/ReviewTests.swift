import XCTest
import CryptoKit
@testable import OathAnkr
@testable import ReviewCore

final class ReviewTests: XCTestCase {
    let publicKey = Data(repeating: 7, count: 32)
    func transaction(_ actions: [Data]) throws -> Data {
        try NearSendCrypto.text("sender.testnet") + Data([0]) + publicKey + NearSendCrypto.le(UInt64(1)) + NearSendCrypto.text("receiver.testnet") + Data(repeating: 3, count: 32) + NearSendCrypto.le(UInt32(actions.count)) + actions.reduce(Data(), +)
    }
    var languages: [OathLocalizer] {
        let bundle = Bundle(path: ProcessInfo.processInfo.environment["OATH_REVIEW_TRANSLATIONS"]!)!
        return OathLanguage.allCases.map { OathLocalizer($0, bundle: bundle) }
    }
    func testAllNearActionsRenderInEveryLanguageWithoutChangingValues() throws {
        let full = Data([5,0]) + publicKey + NearSendCrypto.le(UInt64(0)) + Data([1])
        let limited = try Data([5,0]) + publicKey + NearSendCrypto.le(UInt64(0)) + Data([0,1]) + NearSendCrypto.u128("250000000000000000000000") + NearSendCrypto.text("contract.testnet") + NearSendCrypto.le(UInt32(1)) + NearSendCrypto.text("Transfer_Arguments")
        let unlimited = Data([5,0]) + publicKey + NearSendCrypto.le(UInt64(0)) + Data([0,0]) + NearSendCrypto.text("contract.testnet") + NearSendCrypto.le(UInt32(0))
        let args = Data("{\"memo\":\"Transfer Deposit Arguments\"}".utf8)
        var actions = [Data([0]), Data([1]) + NearSendCrypto.blob(Data([0,97,115,109]))]
        actions.append(try NearSendCrypto.call("ft_transfer", args, 1, "1"))
        actions.append(try Data([3]) + NearSendCrypto.u128("1000000000000000000000000"))
        actions.append(try Data([4]) + NearSendCrypto.u128("1") + Data([0]) + publicKey)
        actions += [full, limited, unlimited, Data([6,0]) + publicKey, Data([7]) + NearSendCrypto.text("beneficiary.testnet")]
        let tx = try WalletConnectNearTransaction(transaction(actions))
        let keys: [OathStringKey] = [.wcNearCreateAccount,.wcNearDeployContract,.wcContractCall,.send,.wcNearStake,.wcNearAddKey,.wcNearAddKey,.wcNearAddKey,.wcNearDeleteKey,.wcNearDeleteAccount]
        XCTAssertEqual(languages.count, 57)
        for strings in languages {
            let rows = tx.actions.map { OathWalletConnectReviewLocalization.nearAction($0, strings: strings) }
            for (row,key) in zip(rows,keys) { XCTAssertTrue(row.hasPrefix(strings.text(key)), strings.language.rawValue) }
            XCTAssertTrue(rows[2].contains(String(decoding: args, as: UTF8.self)))
            XCTAssertTrue(rows[2].contains("ft_transfer"))
            XCTAssertTrue(rows[2].contains("0.000000000000000000000001 NEAR"))
            XCTAssertTrue(rows[3].contains("1 NEAR"))
            XCTAssertTrue(rows[5].contains(strings.text(.wcNearFullAccess)))
            XCTAssertTrue(rows[6].contains("Transfer_Arguments"))
            XCTAssertTrue(rows[6].contains("0.25 NEAR"))
            XCTAssertTrue(rows[7].contains(strings.text(.permissionUnlimited)))
            XCTAssertTrue(rows[7].contains(strings.text(.wcAllMethods)))
            XCTAssertTrue(rows[9].contains("beneficiary.testnet"))
            XCTAssertTrue(rows[8].contains(NearSendCrypto.keyString(publicKey)))
            if strings.language != .english { XCTAssertFalse(rows[5].contains("FULL ACCESS")) }
            if strings.language.isRightToLeft { XCTAssertTrue(rows[2].contains("\u{2066}ft_transfer\u{2069}")) }
        }
    }
    func testBinaryAndBidiArgumentsStayExactBase64() throws {
        for data in [Data([255,0,128]), Data("\u{202E}hidden".utf8)] {
            let tx = try WalletConnectNearTransaction(transaction([NearSendCrypto.call("execute", data, 1, "0")]))
            for strings in languages {
                let text = OathWalletConnectReviewLocalization.nearAction(tx.actions[0], strings: strings)
                XCTAssertTrue(text.contains(data.base64EncodedString()))
                XCTAssertFalse(text.contains("\u{202E}"))
            }
        }
    }
    func testSavedLegacyReviewReparsesOriginalBytes() throws {
        let bytes = try transaction([Data([0])])
        let request = try WalletConnectNearRequest(method: "near_signTransaction", chain: "near:testnet", account: "sender.testnet", params: JSONEncoder().encode(NearJSON.object(["transaction": WalletConnectNearRequest.buffer(bytes)])))
        let review = WalletConnectNearReview(request: request, fee: "1", transactions: [try WalletConnectNearTransaction(bytes)], createdAt: .now)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(review)) as! [String: Any]
        var txs = object["transactions"] as! [[String: Any]]
        var actions = txs[0]["actions"] as! [[String: Any]]; actions[0].removeValue(forKey: "display")
        txs[0]["actions"] = actions; object["transactions"] = txs
        let saved = try JSONDecoder().decode(WalletConnectNearReview.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(saved.transactions[0].actions[0].display)
        let reparsed = try saved.request.transactions.map(WalletConnectNearTransaction.init)
        XCTAssertNotNil(reparsed[0].actions[0].display)
        for strings in languages {
            XCTAssertEqual(OathWalletConnectReviewLocalization.nearAction(reparsed[0].actions[0], strings: strings), strings.text(.wcNearCreateAccount))
        }
    }
    func testSuiMissingMetadataUsesLocalizedBaseUnitLabel() throws {
        let type = "0x2::sui::SUI", owner = "0x" + String(repeating: "1", count: 64)
        let row = owner + "\n-1234567890 atomic " + type
        for strings in languages {
            let raw = OathWalletConnectReviewLocalization.suiChange(row, tokens: [:], strings: strings)
            XCTAssertTrue(raw.hasPrefix(strings.text(.wcAtomicAmount)))
            XCTAssertTrue(raw.contains("-1234567890")); XCTAssertTrue(raw.contains(type)); XCTAssertTrue(raw.contains(owner))
            XCTAssertFalse(raw.contains(" atomic "))
            let token = SuiToken(reference: "native", name: "Sui", symbol: "SUI", decimals: 9, logo: nil, description: nil)
            let formatted = OathWalletConnectReviewLocalization.suiChange(row, tokens: [try SuiIdentity.reference(type): token], strings: strings)
            XCTAssertTrue(formatted.contains("−1.23456789 SUI"))
        }
    }
    func testSuiObjectIdentityAuthorityAndRecipientRenderInAllLanguages() throws {
        let id = try SuiIdentity.address("0xcafe"), sender = try SuiIdentity.address("0x123"), recipient = try SuiIdentity.address("0xbeef")
        for (type, key) in [("0x2::coin::TreasuryCap<0xa::coin::T>", OathStringKey.wcSuiMintAuthority),
                            ("0x2::package::UpgradeCap", .wcSuiUpgradeAuthority),
                            ("0xa::permissions::OwnerCap", .wcSuiUnknownAuthority)] {
            let before = WalletConnectSuiObjectState(version: 1, digest: "fixture", type: type, owner: .init(kind: .address, address: sender))
            let after = WalletConnectSuiObjectState(version: 2, digest: "fixture", type: type, owner: .init(kind: .address, address: recipient))
            let object = WalletConnectSuiObjectChange(id: id, created: false, deleted: false, before: before, after: after)
            XCTAssertEqual(OathWalletConnectReviewLocalization.suiAuthorityWarning(object.authority), key)
            for strings in languages {
                let rows = OathWalletConnectReviewLocalization.suiObjectFields(object, strings: strings)
                XCTAssertTrue(rows.contains { $0.title == strings.text(.wcSuiObjectID) && $0.value == id && $0.leftToRight })
                XCTAssertTrue(rows.contains { $0.title == strings.text(.assetType) && $0.value == type })
                XCTAssertTrue(rows.contains { $0.title == strings.text(.sendRecipient) && $0.value == recipient && $0.leftToRight })
                XCTAssertFalse(strings.text(key).isEmpty)
                XCTAssertNotEqual(strings.text(key), key.rawValue)
                if strings.language != .english { XCTAssertNotEqual(strings.text(key), OathLocalizer(.english, bundle: strings.bundle).text(key)) }
            }
        }
    }

    func testSuiObjectPermissionsAndOwnersUseEveryLanguage() {
        let english = languages.first { $0.language == .english }!
        let id = "0x" + String(repeating: "1", count: 64)
        let address = "0x" + String(repeating: "2", count: 64)
        let owners: [(WalletConnectSuiObjectOwner, OathStringKey?)] = [
            (.init(kind: .address, address: address), nil),
            (.init(kind: .consensusAddress, address: address), nil),
            (.init(kind: .object, address: id), .wcSuiObjectOwner),
            (.init(kind: .shared, address: nil), .wcSuiShared),
            (.init(kind: .immutable, address: nil), .wcSuiImmutable)
        ]
        for strings in languages {
            for (owner, key) in owners {
                let state = WalletConnectSuiObjectState(version: 1, digest: "synthetic", type: "0x2::package::UpgradeCap", owner: owner)
                let change = WalletConnectSuiObjectChange(id: id, created: false, deleted: false, before: state, after: state)
                let fields = OathWalletConnectReviewLocalization.suiObjectFields(change, strings: strings)
                XCTAssertEqual(fields[0].title, strings.text(.wcSuiObjectID))
                XCTAssertEqual(fields[0].value, id)
                XCTAssertEqual(fields[1].value, "0x2::package::UpgradeCap")
                if let key {
                    XCTAssertTrue(fields.contains { $0.title.contains(strings.text(key)) || $0.value == strings.text(key) })
                } else { XCTAssertEqual(fields.last?.value, address) }
                if [.shared, .immutable].contains(owner.kind) { XCTAssertEqual(fields.last?.leftToRight, false) }
                else { XCTAssertEqual(fields.last?.leftToRight, true) }
                let removed = WalletConnectSuiObjectChange(id: id, created: false, deleted: true, before: state, after: nil)
                let last = OathWalletConnectReviewLocalization.suiObjectFields(removed, strings: strings).last
                XCTAssertEqual(last?.value, strings.text(.wcSuiRemoved))
                XCTAssertEqual(last?.leftToRight, false)
            }
            for (authority, key) in [(WalletConnectSuiAuthority.mint, OathStringKey.wcSuiMintAuthority), (.upgrade, .wcSuiUpgradeAuthority), (.unknown, .wcSuiUnknownAuthority)] {
                XCTAssertEqual(OathWalletConnectReviewLocalization.suiAuthorityWarning(authority), key)
                if strings.language != .english { XCTAssertNotEqual(strings.text(key), english.text(key)) }
            }
        }
        XCTAssertNil(OathWalletConnectReviewLocalization.suiAuthorityWarning(.coin))
        XCTAssertNil(OathWalletConnectReviewLocalization.suiAuthorityWarning(.package))
    }

    func testSuiCommandPresentationPreservesResolvedRecipientWithoutEnglishProse() throws {
        // Independent SDK fixture also used by the protocol signature tests.
        let bytes = Data(base64Encoded: "AAACAAhAQg8AAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAICAgABAQAAAQECAAABAQCgzMi8yD9sYoNAE0+FRqIeBhj9GqoCQyu6RUxKLCIz2gEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoMzIvMg/bGKDQBNPhUaiHgYY/RqqAkMrukVMSiwiM9roAwAAAAAAAICWmAAAAAAAAA==")!
        let tx = try WalletConnectSuiTransaction(bytes, network: .testnet, account: "0xa0ccc8bcc83f6c628340134f8546a21e0618fd1aaa02432bba454c4a2c2233da", executing: false)
        let rows = try OathWalletConnectReviewLocalization.suiActions(tx)
        XCTAssertEqual(rows.count, tx.commands.count)
        let values = try rows.map { try JSONDecoder().decode(NearJSON.self, from: Data($0.utf8)) }
        XCTAssertEqual(values[0], tx.displayData["commands"].array?[0])
        XCTAssertEqual(values[1]["TransferObjects"]["recipient"].string, tx.transfers[0].recipient)
        XCTAssertEqual(values[1]["TransferObjects"]["objects"].array, tx.transfers[0].objects.map(NearJSON.string))
        XCTAssertEqual(values[1]["TransferObjects"]["address"].string, "Input[1]")
        XCTAssertFalse(rows.joined().contains(" to "))
        XCTAssertFalse(rows.joined().contains(" amounts "))
    }
}
