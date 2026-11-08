import XCTest
import OathDiagnostics
import OathAnkr
@testable import OathDatabase
@testable import ContactValidation

private actor ContactReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
    func clear() { events = [] }
}

@MainActor final class ContactValidationTests: XCTestCase {
    func testMemoDraftsPersistEditAndClearWhenChangingNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        OathDataEnvironment.shared.value = db
        try await db.seed(networks: ["xrpl", "stellar", "near"].enumerated().map { index, network in
            .init(id: network, name: network, family: network, symbol: "TEST", decimals: 6, derivationPath: "fixture", logo: "fixture", sortOrder: index)
        }, assets: [])
        let xrp = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
        let stellar = try StellarSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        for (network, value, type) in [("xrpl", "0", StellarSendMemoType.text), ("stellar", "Invoice", .text),
            ("stellar", "18446744073709551615", .id), ("stellar", String(repeating: "ab", count: 32), .hash),
            ("stellar", String(repeating: "cd", count: 32), .returnHash)] {
            let saved = try await db.saveContact(id: UUID().uuidString, name: "Fixture", addresses: [])
            let model = OathContactAddressModel(snapshot: saved)
            await model.loadNetworks(); model.chooseNetwork(network)
            model.draft.address = network == "xrpl" ? xrp : stellar
            model.draft.memo = value
            if network == "stellar" { model.stellarMemoType = type }
            XCTAssertNotNil(model.memoKind)
            let result = await model.save(); XCTAssertTrue(result)
            let persisted = try await db.contact(saved.contact.id)
            let snapshot = try XCTUnwrap(persisted), address = try XCTUnwrap(snapshot.addresses.first)
            XCTAssertEqual(address.memo, value)
            XCTAssertEqual(address.memoType, network == "stellar" ? type.rawValue : nil)
            let edit = OathContactAddressModel(snapshot: snapshot, address: address)
            await edit.loadNetworks()
            XCTAssertEqual(edit.draft.memo, value)
            XCTAssertEqual(edit.stellarMemoType, type)
            edit.chooseNetwork(network)
            XCTAssertEqual(edit.draft.memo, value, "Reopening the same network preserves the draft")
            edit.chooseNetwork("near")
            XCTAssertEqual(edit.draft.memo, ""); XCTAssertNil(edit.draft.memoType); XCTAssertNil(edit.memoKind)
            let unchanged = try await db.contact(saved.contact.id)
            XCTAssertEqual(unchanged, snapshot, "Changing/cancelling a draft never mutates its saved memo")
            let rename = OathContactEditorModel(snapshot: snapshot)
            rename.name = "Renamed"
            let renamed = await rename.save(); XCTAssertTrue(renamed)
            let afterRename = try await db.contact(saved.contact.id)
            XCTAssertEqual(afterRename?.addresses.first?.memo, value)
            XCTAssertEqual(afterRename?.addresses.first?.memoType, address.memoType)
        }
        let quick = OathContactEditorModel(recipient: .init(networkID: "stellar", address: stellar, memo: "42", memoType: "id"))
        quick.name = "Receipt"
        XCTAssertEqual(quick.memo, "42"); XCTAssertEqual(quick.memoType, .id)
        let added = await quick.save(); XCTAssertTrue(added)
        let receipt = try await db.contact(quick.id)
        XCTAssertEqual(receipt?.addresses.first?.memo, "42"); XCTAssertEqual(receipt?.addresses.first?.memoType, "id")
    }

    func testDetailReorderAndBatchRemovalPersistWithoutChangingOtherContacts() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        OathDataEnvironment.shared.value = db
        try await db.seed(networks: [.init(id: "near", name: "NEAR Protocol", family: "near", symbol: "NEAR",
            decimals: 24, derivationPath: "fixture", logo: "near", sortOrder: 0)], assets: [])
        let saved = try await db.saveContact(id: UUID().uuidString, name: "Fixture contact", addresses: [
            .init(networkID: "near", address: "alice.near", label: "Personal"),
            .init(networkID: "near", address: "bob.near", label: "Work"),
            .init(networkID: "near", address: "charlie.near", label: "Savings")
        ])
        let other = try await db.saveContact(id: UUID().uuidString, name: "Other contact", addresses: [
            .init(networkID: "near", address: "other.near")
        ])
        let model = OathContactDetailModel(id: saved.contact.id)
        let order = [saved.addresses[2].id, saved.addresses[0].id, saved.addresses[1].id]
        var result = await model.reorderAddresses(order, from: saved)
        XCTAssertTrue(result)
        let reordered = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(reordered.addresses.map(\.id), order)
        XCTAssertEqual(reordered.addresses.map(\.address), ["charlie.near", "alice.near", "bob.near"])
        XCTAssertEqual(reordered.addresses.map(\.label), ["Savings", "Personal", "Work"])
        XCTAssertEqual(reordered.contact.name, saved.contact.name)
        let recipient = SendRecipient(address: reordered.addresses[0], contactName: reordered.contact.name)
        XCTAssertEqual(recipient.id, saved.addresses[2].id)
        XCTAssertEqual(recipient.contactID, saved.contact.id)
        XCTAssertEqual(recipient.networkID, "near")
        XCTAssertEqual(recipient.label, "Savings")

        result = await model.reorderAddresses([order[0], order[0], order[1]], from: reordered)
        XCTAssertFalse(result, "Duplicate or missing IDs cannot replace the saved address list")
        result = await model.removeAddresses([UUID().uuidString], from: reordered)
        XCTAssertFalse(result, "An unrelated selection cannot delete addresses")
        let canceled = Task { await model.removeAddresses(Set(order), from: reordered) }
        canceled.cancel()
        result = await canceled.value
        XCTAssertFalse(result)
        var persisted = try await db.contact(saved.contact.id)
        XCTAssertEqual(persisted, reordered, "Invalid selections and cancellation leave storage intact")

        result = await model.removeAddresses([order[0], order[2]], from: reordered)
        XCTAssertTrue(result)
        let remaining = try XCTUnwrap(model.snapshot)
        XCTAssertEqual(remaining.addresses.map(\.id), [order[1]])
        let reopened = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        persisted = try await reopened.contact(saved.contact.id)
        XCTAssertEqual(persisted, remaining, "Order and removals survive reopening")
        let unchanged = try await reopened.contact(other.contact.id)
        XCTAssertEqual(unchanged, other, "Only the edited contact changes")
        result = await model.removeAddresses([order[1]], from: remaining)
        XCTAssertTrue(result)
        persisted = try await db.contact(saved.contact.id)
        XCTAssertNotNil(persisted, "Removing the last address keeps the contact")
        XCTAssertTrue(persisted?.addresses.isEmpty == true)
    }

    private func verifyDetailWritesRejectStaleEditsAndReportStorageFailuresPrivately(_ capture: ContactReports) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        // The production reporter is configured once per process. Reuse that
        // transport after the preceding test's events have finished uploading.
        await capture.clear()
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        OathDataEnvironment.shared.value = db
        try await db.seed(networks: [.init(id: "near", name: "NEAR Protocol", family: "near", symbol: "NEAR",
            decimals: 24, derivationPath: "fixture", logo: "near", sortOrder: 0)], assets: [])
        let saved = try await db.saveContact(id: UUID().uuidString, name: "Private fixture contact", addresses: [
            .init(networkID: "near", address: "alice.near", label: "Private label"),
            .init(networkID: "near", address: "bob.near")
        ])
        let model = OathContactDetailModel(id: saved.contact.id)
        let order = saved.addresses.map(\.id).reversed()
        var result = await model.reorderAddresses(Array(order), from: saved)
        XCTAssertTrue(result)
        let current = try XCTUnwrap(model.snapshot)
        result = await model.removeAddresses([saved.addresses[0].id], from: saved)
        XCTAssertFalse(result)
        XCTAssertEqual(model.failure, .contactChanged)
        var persisted = try await db.contact(saved.contact.id)
        XCTAssertEqual(persisted, current, "A stale selection cannot overwrite a newer edit")
        try await db.pool.write {
            try $0.execute(sql: "CREATE TRIGGER fail_contact_write BEFORE INSERT ON contactAddresses BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END")
        }
        result = await model.removeAddresses([current.addresses[0].id], from: current)
        XCTAssertFalse(result)
        XCTAssertEqual(model.failure, .contactsSaveFailed)
        XCTAssertFalse(model.deleting, "A failed write releases the editing controls")
        persisted = try await db.contact(saved.contact.id)
        XCTAssertEqual(persisted, current, "A failed replacement rolls back all address removals")
        for _ in 0..<100 {
            if await capture.events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy {
            $0.component == "address_book" && $0.operation == "remove_addresses"
                && $0.context["chain"] == "near" && $0.operationID != nil
        })
        XCTAssertEqual(Set(events.compactMap(\.operationID)).count, 2)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for field in [saved.contact.id, saved.contact.name, "Private label", "alice.near", "bob.near", "INSERT INTO"] {
            XCTAssertFalse(encoded.contains(field), "Diagnostics must not expose address-book fields or SQL")
        }
    }

    func testUserValidationKeepsFeedbackWithoutReportsAndDatabaseFailureStillReports() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = ContactReports()
        OathDiagnostics.configure(file: dir.appendingPathComponent("reports.json"), transport: capture)
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("contacts.sqlite"))
        OathDataEnvironment.shared.value = db
        try await db.seed(networks: [.init(id: "near", name: "NEAR Protocol", family: "near", symbol: "NEAR",
            decimals: 24, derivationPath: "fixture", logo: "near", sortOrder: 0)], assets: [])
        let saved = try await db.saveContact(id: UUID().uuidString, name: "Private fixture contact", addresses: [])
        let address = OathContactAddressModel(snapshot: saved)
        await address.loadNetworks()
        address.chooseNetwork("near")
        for invalid in ["", "wrong..near", "alice.near word", "alice.near\u{202E}"] {
            address.draft.address = invalid
            let count = OathHaptics.shared.events.count
            let result = await address.save()
            XCTAssertFalse(result)
            XCTAssertEqual(address.failure, .contactAddressInvalid)
            XCTAssertEqual(OathHaptics.shared.events.count, count + 1)
            XCTAssertEqual(OathHaptics.shared.events.last, .error)
        }
        var stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.count, 0, "Validation never persists a draft")
        address.draft.address = "alice.near"
        address.draft.label = String(repeating: "x", count: 101)
        var result = await address.save()
        XCTAssertFalse(result); XCTAssertEqual(address.failure, .contactLabelInvalid)
        address.draft.label = ""
        result = await address.save()
        XCTAssertTrue(result); XCTAssertNil(address.failure)
        XCTAssertEqual(OathHaptics.shared.events.last, .success)
        stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.first?.address, "alice.near")
        let duplicate = OathContactAddressModel(snapshot: try XCTUnwrap(stored))
        await duplicate.loadNetworks(); duplicate.chooseNetwork("near")
        duplicate.draft.address = "alice.near"
        result = await duplicate.save()
        XCTAssertFalse(result); XCTAssertEqual(duplicate.failure, .contactDuplicateAddress)
        let editor = OathContactEditorModel()
        editor.name = " "
        result = await editor.save()
        XCTAssertFalse(result); XCTAssertEqual(editor.failure, .contactNameInvalid)
        // Invalid memo input is form validation, not diagnostic content.
        let memoDraft = OathContactAddressModel(snapshot: try XCTUnwrap(stored))
        await memoDraft.loadNetworks(); memoDraft.chooseNetwork("near")
        memoDraft.draft.address = "memo.near"
        memoDraft.draft.memo = "private memo fixture"
        result = await memoDraft.save()
        XCTAssertFalse(result); XCTAssertEqual(memoDraft.failure, .sendMemoInvalid)
        let fullContact = try await db.saveContact(id: UUID().uuidString, name: "Address limit fixture",
            addresses: (0..<50).map { .init(networkID: "near", address: "contact\($0).near") })
        let overflow = OathContactAddressModel(snapshot: fullContact)
        await overflow.loadNetworks(); overflow.chooseNetwork("near")
        overflow.draft.address = "contact50.near"
        result = await overflow.save()
        XCTAssertFalse(result); XCTAssertEqual(overflow.failure, .contactAddressLimit)
        try await Task.sleep(for: .milliseconds(200))
        let validationEvents = await capture.events
        XCTAssertTrue(validationEvents.isEmpty, "Invalid fields are normal validation, not app failures")

        // A genuine SQLite failure must still leave the contact unchanged and
        // retain safe chain/operation context. No fake storage implementation.
        try await db.pool.write { connection in
            try connection.execute(sql: "CREATE TRIGGER fail_contact_write BEFORE INSERT ON contactAddresses BEGIN SELECT RAISE(ABORT, 'fixture storage failure'); END")
        }
        let failed = OathContactAddressModel(snapshot: try XCTUnwrap(stored))
        await failed.loadNetworks(); failed.chooseNetwork("near")
        failed.draft.address = "bob.near"
        result = await failed.save()
        XCTAssertFalse(result); XCTAssertEqual(failed.failure, .contactsSaveFailed)
        XCTAssertEqual(OathHaptics.shared.events.last, .error)
        stored = try await db.contact(saved.contact.id)
        XCTAssertEqual(stored?.addresses.map(\.address), ["alice.near"])
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.domain == "GRDB.DatabaseError" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await capture.events
        let event = try XCTUnwrap(events.first { $0.error.domain == "GRDB.DatabaseError" })
        XCTAssertEqual(event.component, "address_book")
        XCTAssertEqual(event.operation, "save_address")
        XCTAssertEqual(event.context["chain"], "near")
        XCTAssertNotNil(event.operationID)
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [saved.contact.name, saved.contact.id, "alice.near", "bob.near", "INSERT INTO", "CREATE TRIGGER"] {
            XCTAssertFalse(encoded.contains(secret), "Diagnostics must not contain field values or SQL")
        }
        try await db.pool.write { try $0.execute(sql: "DROP TRIGGER fail_contact_write") }
        let stale = OathContactAddressModel(snapshot: saved)
        await stale.loadNetworks(); stale.chooseNetwork("near")
        stale.draft.address = "charlie.near"
        result = await stale.save()
        XCTAssertFalse(result); XCTAssertEqual(stale.failure, .contactChanged)
        for _ in 0..<100 {
            if await capture.events.contains(where: { $0.error.message == "conflict" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let conflict = await capture.events.first { $0.error.message == "conflict" }
        XCTAssertNotNil(conflict, "Revision conflicts must not be silently classified as invalid fields")
        XCTAssertNotEqual(event.operationID, conflict?.operationID)
        let canceled = Task { await failed.save() }
        canceled.cancel()
        result = await canceled.value
        XCTAssertFalse(result)
        try await Task.sleep(for: .milliseconds(100))
        let finalEvents = await capture.events
        XCTAssertEqual(finalEvents.count, 2, "Only the SQLite failure and revision conflict are app reports")
        try await verifyDetailWritesRejectStaleEditsAndReportStorageFailuresPrivately(capture)
    }
}
