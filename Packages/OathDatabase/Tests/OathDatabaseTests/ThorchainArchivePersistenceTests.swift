import Foundation
import XCTest
import GRDB
@testable import OathAnkr
@testable import OathDatabase

extension ThorchainTests {
    private func archiveEvent(_ hash: String, archive: Bool, reference: String = "native", index: Int = 2) -> ThorchainEvent {
        .init(id: hash + (archive ? ":archive:send:0:0" : ":\(index):0"), hash: hash, reference: reference,
              amount: "123456789", direction: "incoming", counterparty: other, state: "confirmed", height: 123, timestamp: 1700000000, fee: nil)
    }
    func testArchiveMergeBothOrdersIsIdempotentAndPreservesWalletOnReopen() async throws {
        for archiveFirst in [false, true] {
            let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
            let ticket = try await db.beginThorchainSync(accountID: "a1")
            try await db.commitThorchainInventory(.init(owner: owner, holdings: [.init(reference: "native", amount: "999999999")], height: 123), ticket: ticket, catalog: .init())
            let before = try await db.pool.read { try BalanceRecord.fetchAll($0) }
            let originalWallet = try await db.pool.read { try WalletRecord.fetchAll($0) }
            let originalAccounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
            let hash = String(repeating: "A", count: 64)
            for archive in archiveFirst ? [true, false] : [false, true] {
                let stream = archive ? "archive" : "transfer.recipient"
                let cursor = try await db.thorchainCursor(ticket: ticket, stream: stream, lane: "backfill", height: 123)
                let event = archiveEvent(hash, archive: archive)
                try await db.commitThorchainHistory(.init(owner: owner, events: [event], next: nil, rawCount: 1), cursor: cursor, ticket: ticket, catalog: .init())
            }
            // Replay the archive in a later refresh; primary IDs still win.
            let cursor = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 124)
            XCTAssertFalse(cursor.complete)
            try await db.commitThorchainHistory(.init(owner: owner, events: [archiveEvent(hash, archive: true)], next: nil, rawCount: 1), cursor: cursor, ticket: ticket, catalog: .init())
            let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
            let activities = try await reopened.pool.read { try ActivityRecord.fetchAll($0) }
            XCTAssertEqual(activities.count, 1)
            XCTAssertEqual(activities.first?.id, "a1:" + hash + ":2:0")
            let after = try await reopened.pool.read { try BalanceRecord.fetchAll($0) }
            XCTAssertEqual(before, after)
            let wallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
            let accounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
            XCTAssertEqual(originalWallet, wallets); XCTAssertEqual(originalAccounts, accounts)
        }
    }
    func testArchiveRetainedUntilAllCanonicalTokenMetadataIsAvailable() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1"), hash = String(repeating: "B", count: 64)
        let archive = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 123)
        try await db.commitThorchainHistory(.init(owner: owner, events: [archiveEvent(hash, archive: true)], next: nil, rawCount: 1), cursor: archive, ticket: ticket, catalog: .init())
        let node = try await db.thorchainCursor(ticket: ticket, stream: "transfer.recipient", lane: "backfill", height: 123)
        let events = [archiveEvent(hash, archive: false), archiveEvent(hash, archive: false, reference: "x/later", index: 3)]
        try await db.commitThorchainHistory(.init(owner: owner, events: events, next: nil, rawCount: 1), cursor: node, ticket: ticket, catalog: .init())
        let saved = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        XCTAssertEqual(saved.count, 2, "Archive remains while canonical token metadata is pending")
        var catalog = ThorchainCatalog(); catalog.tokens["x/later"] = .init(reference: "x/later", name: "Later", symbol: "LATER", decimals: 6)
        try await db.commitThorchainCatalog(catalog, ticket: ticket)
        let projected = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        XCTAssertEqual(projected.count, 2)
        XCTAssertFalse(projected.contains { $0.id.contains(":archive:") })
        XCTAssertEqual(Set(projected.map(\.assetID)), ["thorchain:native", "thorchain:x/later"])
    }
    func testArchiveCursorRollbackResumeAndStaleTicketPreserveSavedRows() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1"), hash = String(repeating: "C", count: 64)
        let cursor = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 123)
        let event = archiveEvent(hash, archive: true)
        do {
            try await db.commitThorchainHistory(.init(owner: owner, events: [event], next: "999", rawCount: 1), cursor: cursor, ticket: ticket, catalog: .init())
            XCTFail("Invalid cursor must roll back")
        } catch {}
        let empty = try await db.pool.read { try ActivityRecord.fetchAll($0) }; XCTAssertTrue(empty.isEmpty)
        let unchanged = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 123)
        XCTAssertEqual(unchanged, cursor)
        try await db.commitThorchainHistory(.init(owner: owner, events: [event], next: "2", rawCount: 25), cursor: cursor, ticket: ticket, catalog: .init())
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let resumed = try await reopened.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 999)
        XCTAssertEqual(resumed.page, 2); XCTAssertEqual(resumed.height, 123)
        _ = try await db.beginThorchainSync(accountID: "a1")
        do {
            try await reopened.commitThorchainHistory(.init(owner: owner, events: [], next: nil, rawCount: 0), cursor: resumed, ticket: ticket, catalog: .init())
            XCTFail("Old generation must not complete the archive")
        } catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        let rows = try await db.pool.read { try ActivityRecord.fetchAll($0) }; XCTAssertEqual(rows.count, 1)
    }
}

extension ThorchainSendJournalTests {
    func testArchiveCannotRewriteSignedTransactionOrReviewedIntent() async throws {
        let (db, folder, plan) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        try await draft("archive-send", plan: plan, db: db)
        try await db.queueThorchainSend(sendID: "archive-send", plan: plan)
        let signed = try ThorchainSendCrypto.sign(plan, privateKey: key)
        try await db.journalThorchainSignature(sendID: "archive-send", signed: signed)
        let beforeSend = try await db.send("archive-send")
        let beforeTx = try await db.pool.read { try TransactionRecord.fetchAll($0) }
        let beforeActivity = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        let cursor = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 123)
        let event = ThorchainEvent(id: signed.hash + ":archive:execution", hash: signed.hash, reference: "native", amount: "0", direction: "outgoing", counterparty: "", state: "failed", height: 123, timestamp: 123, fee: "99999")
        try await db.commitThorchainHistory(.init(owner: plan.sender, events: [event], next: nil, rawCount: 1), cursor: cursor, ticket: ticket, catalog: .init())
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("db.sqlite"))
        let afterSend = try await reopened.send("archive-send")
        let afterTx = try await reopened.pool.read { try TransactionRecord.fetchAll($0) }
        let afterActivity = try await reopened.pool.read { try ActivityRecord.fetchAll($0) }
        XCTAssertEqual(beforeSend, afterSend); XCTAssertEqual(beforeTx, afterTx); XCTAssertEqual(beforeActivity, afterActivity)
        XCTAssertNotNil(afterSend?.signedPayload)
        XCTAssertEqual(afterSend?.signedPayload, beforeSend?.signedPayload)
    }
}

extension ThorchainTests {
    func testProtocolActionVisibilityMigrationPreservesRowsAndZeroTransferProtection() async throws {
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let ticket = try await db.beginThorchainSync(accountID: "a1")
        let cursor = try await db.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: 123)
        let actionHash = String(repeating: "E", count: 64), zeroHash = String(repeating: "F", count: 64)
        let action = ThorchainEvent(id: actionHash + ":archive:action", hash: actionHash, reference: "native", amount: "0", direction: "incoming", counterparty: "", state: "confirmed", height: 123, timestamp: 1700000000, fee: nil)
        let zero = ThorchainEvent(id: zeroHash + ":archive:send:0:0", hash: zeroHash, reference: "native", amount: "0", direction: "incoming", counterparty: other, state: "confirmed", height: 123, timestamp: 1700000000, fee: nil)
        try await db.commitThorchainHistory(.init(owner: owner, events: [action, zero], next: nil, rawCount: 2), cursor: cursor, ticket: ticket, catalog: .init())
        let rows = try await db.pool.read { try ActivityRecord.fetchAll($0) }
        let wallets = try await db.pool.read { try WalletRecord.fetchAll($0) }
        let accounts = try await db.pool.read { try AccountRecord.fetchAll($0) }
        let history = try await db.history(walletID: "w1")
        XCTAssertEqual(history.map(\.hash), [actionHash])
        // Re-create the previous visibility schema in this disposable fixture,
        // then exercise the same migration that existing installations receive.
        try await db.pool.write { sql in
            try sql.execute(sql: "DROP VIEW visibleActivity")
            try HistorySafety.createVisibilityView(sql, indexedMetadata: true)
            try sql.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='v110_thorchain_protocol_history'")
        }
        let oldHistory = try await db.history(walletID: "w1"); XCTAssertTrue(oldHistory.isEmpty)
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let newHistory = try await reopened.history(walletID: "w1")
        XCTAssertEqual(newHistory.map(\.hash), [actionHash])
        let afterRows = try await reopened.pool.read { try ActivityRecord.fetchAll($0) }
        let afterWallets = try await reopened.pool.read { try WalletRecord.fetchAll($0) }
        let afterAccounts = try await reopened.pool.read { try AccountRecord.fetchAll($0) }
        XCTAssertEqual(rows, afterRows); XCTAssertEqual(wallets, afterWallets); XCTAssertEqual(accounts, afterAccounts)
    }
}

extension ThorchainTests {
    func testLiveArchivedPagesPersistEveryVisibleTransactionAcrossReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_THOR_HISTORY_LIVE"] == "1" else { throw XCTSkip("Opt-in public history and disposable database") }
        let (db, folder) = try await fixture(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = ThorchainClient(), height = try await client.latestHeight()
        let owners = ["thor1c3nw2k7qag6j707hzda9nvh4ke032rh9cw7pq4", "thor17tkmm7rpqx94dk2vyurle708t4phjp0m4mwv2h"]
        for (index, address) in owners.enumerated() {
            let accountID = "a\(index + 1)", walletID = "w\(index + 1)"
            try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET address=? WHERE id=?", arguments: [address, accountID]) }
            let ticket = try await db.beginThorchainSync(accountID: accountID)
            try await db.commitThorchainInventory(.init(owner: address, holdings: [.init(reference: "native", amount: "12345")], height: height), ticket: ticket, catalog: .init())
            let beforeBalance = try await db.balance(accountID: accountID, assetID: "thorchain:native")
            var active = db, hashes = Set<String>(), pages = 0
            while true {
                let cursor = try await active.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: height)
                let page = try await client.history(owner: address, stream: "archive", height: cursor.height, page: cursor.page)
                hashes.formUnion(page.events.map(\.hash)); pages += 1
                try await active.commitThorchainHistory(page, cursor: cursor, ticket: ticket, catalog: .init())
                active = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
                guard page.next != nil else { break }
                guard pages < 10 else { XCTFail("Unexpected public history growth"); break }
            }
            let visible = try await active.history(walletID: walletID, limit: 200)
            XCTAssertEqual(Set(visible.map(\.hash)), hashes)
            XCTAssertEqual(hashes.count, index == 0 ? 24 : 60)
            XCTAssertEqual(visible.count, hashes.count)
            let afterBalance = try await active.balance(accountID: accountID, assetID: "thorchain:native")
            XCTAssertEqual(beforeBalance, afterBalance)
            let completed = try await active.thorchainCursor(ticket: ticket, stream: "archive", lane: "backfill", height: height)
            XCTAssertTrue(completed.complete)
            print("THOR archive persisted after reopen: \(visible.count) visible transactions, \(pages) pages, balance unchanged")
        }
    }
}
