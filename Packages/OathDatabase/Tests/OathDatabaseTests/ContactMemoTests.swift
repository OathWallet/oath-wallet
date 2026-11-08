import XCTest
import GRDB
@testable import OathDatabase

final class ContactMemoTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("contacts.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: ["xrpl", "stellar", "ethereum"].enumerated().map { index, network in
            .init(id: network, name: network, family: network, symbol: "TEST", decimals: 6, derivationPath: "fixture", logo: "fixture", sortOrder: index)
        }, assets: [])
        return (db, url)
    }

    func testMigrateExistingContactsWithoutChangingWalletsOrAddresses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("contacts.sqlite")
        var configuration = Configuration()
        configuration.prepareDatabase { $0.add(function: HistorySafety.metadataFunction) }
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        try Schema.migrator.migrate(queue, upTo: "v107_solana_unix_timestamps")
        let contactID = UUID().uuidString, addressID = UUID().uuidString
        try await queue.write { db in
            try NetworkRecord(id: "xrpl", name: "XRP", family: "xrpl", symbol: "XRP", decimals: 6, derivationPath: "fixture", logo: "fixture", sortOrder: 0).insert(db)
            try WalletRecord(id: "fixture-wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1).insert(db)
            try db.execute(sql: "INSERT INTO contacts(id,name,searchText,createdAt,updatedAt,revision) VALUES(?,?,?,1,1,1)", arguments: [contactID, "Legacy", "Legacy"])
            try db.execute(sql: "INSERT INTO contactAddresses(id,contactID,networkID,address,addressKey,label,position) VALUES(?,?,'xrpl','legacy-fixture','legacy-fixture','',0)", arguments: [addressID, contactID])
        }
        let db = try await OathDatabase.open(at: url)
        let saved = try await db.contact(contactID)
        XCTAssertEqual(saved?.contact.revision, 1)
        XCTAssertEqual(saved?.addresses.first?.id, addressID)
        XCTAssertEqual(saved?.addresses.first?.address, "legacy-fixture")
        XCTAssertNil(saved?.addresses.first?.memo)
        XCTAssertNil(saved?.addresses.first?.memoType)
        let wallets = try await db.wallets()
        XCTAssertEqual(wallets.map(\.id), ["fixture-wallet"])
        var input = try XCTUnwrap(saved?.addresses.first?.input)
        input.memo = "0"
        _ = try await db.saveContact(id: contactID, name: "Legacy", addresses: [input], expectedRevision: 1)
        let reopened = try await OathDatabase.open(at: url)
        let updated = try await reopened.contact(contactID)
        XCTAssertEqual(updated?.addresses.first?.memo, "0")
    }

    func testSaveEditReopenAndRecipientProjectionPreserveMemoAndType() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for (network, value, type) in [("xrpl", "4294967295", nil), ("stellar", "Invoice أحمد", "text"),
            ("stellar", "18446744073709551615", "id"), ("stellar", String(repeating: "ab", count: 32), "hash"),
            ("stellar", String(repeating: "cd", count: 32), "returnHash")] as [(String, String, String?)] {
            let saved = try await db.saveContact(id: UUID().uuidString, name: "Fixture", addresses: [
                .init(networkID: network, address: "public-fixture", memo: value, memoType: type)])
            let record = try XCTUnwrap(saved.addresses.first)
            XCTAssertEqual(record.memo, value); XCTAssertEqual(record.memoType, type)
            XCTAssertEqual(record.input.memo, value); XCTAssertEqual(record.input.memoType, type)
            let renamed = try await db.saveContact(id: saved.contact.id, name: "Renamed", addresses: saved.addresses.map(\.input), expectedRevision: 1)
            let reopened = try await OathDatabase.open(at: url)
            let loaded = try await reopened.contact(saved.contact.id)
            XCTAssertEqual(loaded, renamed)
            let recipients = try await reopened.sendRecipients(networkID: network)
            let recipient = try XCTUnwrap(recipients.first { $0.contactID == saved.contact.id })
            XCTAssertEqual(recipient.memo, value); XCTAssertEqual(recipient.memoType, type)
            XCTAssertEqual(SendRecipient(address: record, contactName: "Renamed"), recipient)
            var cleared = record.input; cleared.memo = ""
            let edited = try await db.saveContact(id: saved.contact.id, name: "Renamed", addresses: [cleared], expectedRevision: 2)
            XCTAssertNil(edited.addresses.first?.memo); XCTAssertNil(edited.addresses.first?.memoType)
        }
    }

    func testMemoIsPartOfDestinationIdentityAndReceiptLookup() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let saved = try await db.saveContact(id: UUID().uuidString, name: "Exchange", addresses: [
            .init(networkID: "xrpl", address: "exchange-fixture", memo: "42"),
            .init(networkID: "xrpl", address: "exchange-fixture", memo: "43"),
            .init(networkID: "xrpl", address: "exchange-fixture")])
        XCTAssertEqual(saved.addresses.count, 3)
        XCTAssertEqual(Set(saved.addresses.map(\.addressKey)).count, 3)
        for (memo, expected) in [("42", true), ("00042", true), ("43", true), ("", true), ("44", false)] {
            var changes = db.observeContactAddress(networkID: "xrpl", address: "exchange-fixture", memo: memo).makeAsyncIterator()
            let exists = try await changes.next(); XCTAssertEqual(exists, expected)
        }
        do {
            _ = try await db.saveContact(id: UUID().uuidString, name: "Duplicate", addresses: [.init(networkID: "xrpl", address: "exchange-fixture", memo: "00042")], rejectExistingAddresses: true)
            XCTFail("Equivalent routing tags must not duplicate a receipt contact")
        } catch { XCTAssertEqual(error as? ContactStoreError, .duplicateAddress) }
        let another = try await db.saveContact(id: UUID().uuidString, name: "Different", addresses: [.init(networkID: "xrpl", address: "exchange-fixture", memo: "44")], rejectExistingAddresses: true)
        XCTAssertEqual(another.addresses.first?.memo, "44")
        let types = try await db.saveContact(id: UUID().uuidString, name: "Types", addresses: [
            .init(networkID: "stellar", address: "stellar-fixture", memo: "42", memoType: "text"),
            .init(networkID: "stellar", address: "stellar-fixture", memo: "42", memoType: "id")])
        XCTAssertEqual(types.addresses.count, 2, "Text and ID are different routing destinations")
    }

    func testProtocolBoundsAndInvalidMemosDoNotWrite() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let bad: [(String, String, String?)] = [
            ("xrpl", "4294967296", nil), ("xrpl", "-1", nil), ("xrpl", "1.0", nil), ("xrpl", " 1", nil), ("xrpl", "١", nil), ("xrpl", "42", "text"),
            ("stellar", "18446744073709551616", "id"), ("stellar", "-1", "id"), ("stellar", String(repeating: "أ", count: 15), "text"),
            ("stellar", "a\nb", "text"), ("stellar", String(repeating: "g", count: 64), "hash"), ("stellar", "abcd", "returnHash"),
            ("stellar", "42", "unknown"), ("ethereum", "42", nil)]
        for (network, value, type) in bad {
            let id = UUID().uuidString
            do {
                _ = try await db.saveContact(id: id, name: "Fixture", addresses: [.init(networkID: network, address: "public-fixture", memo: value, memoType: type)])
                XCTFail("Invalid routing memo accepted")
            } catch { XCTAssertEqual(error as? ContactStoreError, .invalidMemo) }
            let persisted = try await db.contact(id); XCTAssertNil(persisted)
        }
        XCTAssertEqual(try ContactRoutingMemo(networkID: "xrpl", value: "0000").value, "0")
        XCTAssertEqual(try ContactRoutingMemo(networkID: "stellar", value: String(repeating: "أ", count: 14), type: "text").value.utf8.count, 28)
        XCTAssertEqual(try ContactRoutingMemo(networkID: "stellar", value: "  text  ", type: "text").value, "  text  ")
    }
}
