import XCTest
import Observation
import OathDatabase
import OathAnkr
@testable import TokenLookup

private struct OfflineManagedCatalog: OathManagedTokenCatalog, OathTokenDiscovering {
    func tokens(on network: String, excluding: Set<String>) async -> [TokenDiscoveryEntry] { [] }
    func search(_ query: String, networks: Set<String>, excluding: Set<String>, limit: Int) async -> [TokenDiscoveryEntry] { [] }
    func managementEntries(query: String, networks: Set<String>) async -> [TokenDiscoveryEntry] { [] }
    func refreshIfNeeded() async -> Bool { false }
}
private struct FailedManagedProvider: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) { (Data(), 503) }
}
private struct UnexpectedManagedLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        XCTFail("Cached management queries must not make live provider requests")
        throw OathTokenLookupError.unavailable
    }
}
private struct FailingManagedLookup: OathTokenLookingUp {
    func lookup(address: String, network: OathTokenNetwork) async throws -> OathTokenDefinition {
        throw OathTokenLookupError.unavailable
    }
}
@MainActor private final class ManagedGate {
    var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { let values = waiters; waiters = []; values.forEach { $0.resume() } }
}
private actor DelayedManagedCatalog: OathManagedTokenCatalog {
    private(set) var started = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func refreshIfNeeded() async -> Bool { false }
    func managementEntries(query: String, networks: Set<String>) async -> [TokenDiscoveryEntry] {
        if networks == ["ethereum"] {
            started += 1
            await withCheckedContinuation { waiter = $0 }
        }
        return []
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor CountingManagedCatalog: OathManagedTokenCatalog {
    let catalog: TokenDiscoveryCatalog
    private(set) var calls = 0
    private var blocked: Bool
    private var waiter: CheckedContinuation<Void, Never>?
    init(_ catalog: TokenDiscoveryCatalog, blocked: Bool = false) { self.catalog = catalog; self.blocked = blocked }
    func managementEntries(query: String, networks: Set<String>) async -> [TokenDiscoveryEntry] {
        calls += 1
        if blocked { await withCheckedContinuation { waiter = $0 } }
        return await catalog.managementEntries(query: query, networks: networks)
    }
    func hasManagementEntries(networks: Set<String>) async -> Bool { await catalog.hasManagementEntries(networks: networks) }
    func refreshIfNeeded() async -> Bool { false }
    func release() { blocked = false; waiter?.resume(); waiter = nil }
}

private final class ManagementInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor final class ManageTokensTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("test.sqlite"))
        let chains = OathImportChain.allCases
        try await db.seed(networks: chains.enumerated().map { index, chain in
            .init(id: chain.id, name: chain.name, family: chain.isEVM ? "evm" : chain.id,
                symbol: chain.shortName, decimals: 18, derivationPath: "fixture", logo: chain.logoAsset,
                sortOrder: index, enabled: chain.isEnabled)
        }, assets: chains.map {
            .init(id: $0.id + ":native", networkID: $0.id, reference: "native", name: $0.name, symbol: $0.shortName, decimals: 18)
        })
        for wallet in ["one", "two"] {
            try await db.importWalletIfNeeded(.init(id: wallet, name: wallet, kind: "hd", vaultReference: wallet, createdAt: 1),
                accounts: chains.map { .init(id: wallet + $0.id, walletID: wallet, networkID: $0.id,
                    address: "public-fixture", derivationPath: "fixture") })
        }
        return (db, directory)
    }
    private func token(_ n: Int, network: String = "ethereum", decimals: Int = 6) -> AssetRecord {
        let reference = "0x" + String(format: "%040x", n + 1)
        return .init(id: network + ":" + reference, networkID: network, reference: reference,
            name: "Token " + String(format: "%04d", n), symbol: "TST", decimals: decimals)
    }
    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(predicate(), "Timed out waiting for controlled operation")
    }
    func testRowArtworkIdentityDoesNotRequireBuildingDiscoveryDefinitions() throws {
        for (network, reference) in [("ethereum", "0xABCDEFabcdefABCDEFabcdefABCDEFabcdefABCDEF"),
                                      ("solana", "So11111111111111111111111111111111111111112"),
                                      ("near", "usdt.tether-token.near")] {
            let row = OathManagedTokenRow(id: network + ":" + reference, networkID: network,
                reference: reference, name: "Fixture", symbol: "TST", logo: nil, decimals: 6, entry: nil)
            XCTAssertNil(row.token, "A visible persisted row needs no catalog definition")
            let identity = try XCTUnwrap(row.artworkIdentity)
            XCTAssertEqual(identity.networkID, network)
            XCTAssertEqual(identity.reference, network == "ethereum" ? reference.lowercased() : reference)
            XCTAssertEqual(identity.decimals, 6)
        }
        let native = OathManagedTokenRow(id: "zerog:native", networkID: "zerog", reference: "native",
            name: "0G", symbol: "0G", logo: nil, decimals: 18, entry: nil)
        XCTAssertNil(native.artworkIdentity, "Native rows never launch token metadata/image work")
    }

    func testEveryEnabledNativeChainIsManageableOfflineIncludingZeroG() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = OathManageTokensModel(catalog: OfflineManagedCatalog(), lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.refreshCatalog()
        await model.load(query: "", scope: .all)
        let enabled = Set(OathImportChain.enabledCases.map(\.id))
        XCTAssertEqual(enabled.count, 42)
        XCTAssertEqual(Set(model.rows.map(\.networkID)), enabled)
        XCTAssertEqual(model.rows.count, enabled.count)
        XCTAssertTrue(model.catalogUnavailable)
        for chain in OathImportChain.enabledCases {
            await model.load(query: "", scope: .init(chain: chain))
            XCTAssertEqual(model.rows.map(\.id), [chain.id + ":native"], chain.id)
            XCTAssertTrue(model.enabled(try XCTUnwrap(model.rows.first)))
            try await db.setAssetHidden(true, assetID: chain.id + ":native", walletID: "one")
        }
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: "", scope: .all)
        XCTAssertEqual(model.rows.count, 42)
        XCTAssertTrue(model.rows.allSatisfy { !model.enabled($0) })
        let other = try await db.managedAssets(walletID: "two", currency: "USD")
        XCTAssertTrue(other.hiddenAssetIDs.isEmpty)
    }
    func testFullCatalogPaginationStableOrderAddressSearchAndOfflineRecovery() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let seed = (0..<451).map { n in ["id": "token-\(n)", "name": token(n).name, "symbol": "tst",
            "platforms": ["ethereum": token(n).reference, "base": token(n).reference]] as [String: Any] }
        let catalog = TokenDiscoveryCatalog(transport: FailedManagedProvider(), directory: directory.appendingPathComponent("catalog"),
            seed: try JSONSerialization.data(withJSONObject: seed))
        let model = OathManageTokensModel(catalog: catalog, lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: "", scope: .all)
        XCTAssertEqual(model.rows.count, 944)
        XCTAssertEqual(model.visibleRows.count, 200)
        while model.visibleRows.count < model.rows.count { model.revealMore(after: try XCTUnwrap(model.visibleRows.last)) }
        XCTAssertEqual(model.visibleRows.count, 944)
        let before = model.rows.map(\.id)
        _ = try await db.enableManagedToken(token(450), walletID: "one")
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: "", scope: .all)
        XCTAssertEqual(model.rows.map(\.id), before, "A switch must not jump the row into a new section")
        await model.load(query: token(450).reference.uppercased(), scope: .all)
        XCTAssertEqual(Set(model.rows.map(\.networkID)), ["ethereum", "base"])
        await model.load(query: "TST", scope: .init(chain: .base))
        XCTAssertEqual(model.rows.count, 451)
        await model.refreshCatalog()
        await model.load(query: "TST", scope: .init(chain: .base))
        XCTAssertEqual(model.rows.count, 451, "Provider failure must preserve cached matches")
        let reopened = OathManageTokensModel(catalog: OfflineManagedCatalog(), lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        reopened.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await reopened.load(query: "", scope: .all)
        XCTAssertTrue(reopened.enabled(try XCTUnwrap(reopened.rows.first { $0.id == token(450).id })), "A selected token survives loss of catalog coverage")
    }
    func testWritesAreSerializedBoundedCommittedAndRetryable() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = OathManageTokensModel(catalog: OfflineManagedCatalog(), lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: "", scope: .all)
        let rows = Array(model.rows.prefix(8)), gate = ManagedGate(), operations = OathManagedTokenOperations()
        var started = 0
        for row in rows {
            operations.set(false, row: row, walletID: "one") { _, row, wallet in
                started += 1; await gate.wait(); try Task.checkCancellation()
                try await db.setAssetHidden(true, assetID: row.id, walletID: wallet)
            }
        }
        operations.set(false, row: rows[0], walletID: "one") { _,_,_ in XCTFail("Duplicate write") }
        try await until { started == 4 }
        XCTAssertEqual(operations.pending.count, 8)
        XCTAssertTrue(model.enabled(rows[0]), "No optimistic success before commit")
        gate.release(); try await until { started == 8 }; gate.release()
        try await until { operations.pending.isEmpty }
        let saved = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertEqual(saved.hiddenAssetIDs.count, 8)
        operations.set(true, row: rows[0], walletID: "one") { _,_,_ in throw StoreError.conflictingIdentity }
        try await until { operations.pending.isEmpty }
        XCTAssertTrue(operations.failed.contains("one:" + rows[0].id))
        let unchanged = try await db.managedAssets(walletID: "one", currency: "USD")
        XCTAssertEqual(saved.hiddenAssetIDs, unchanged.hiddenAssetIDs)
        operations.set(true, row: rows[0], walletID: "one") { _, row, wallet in
            try await db.setAssetHidden(false, assetID: row.id, walletID: wallet)
        }
        try await until { operations.pending.isEmpty }
        XCTAssertTrue(operations.failed.isEmpty)
    }
    func testCancellationRejectsLateCompletionAndQueueCoalescesWithoutCancellingOwners() async throws {
        let operations = OathManagedTokenOperations(), gate = ManagedGate()
        let row = OathManagedTokenRow(id: "ethereum:native", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", logo: nil, decimals: 18, entry: nil)
        var published = false
        operations.set(false, row: row, walletID: "one") { _,_,_ in
            await gate.wait(); try Task.checkCancellation(); published = true
        }
        try await until { gate.waiters.count == 1 }
        operations.cancel(); gate.release()
        await Task.yield(); XCTAssertFalse(published); XCTAssertTrue(operations.pending.isEmpty)
        let queue = OathManagedTokenRefreshQueue(), refreshGate = ManagedGate()
        var calls = 0
        queue.enqueue("ethereum") { calls += 1; await refreshGate.wait() }
        try await until { calls == 1 }
        for _ in 0..<10 { queue.enqueue("ethereum") { calls += 1 } }
        XCTAssertEqual(calls, 1)
        refreshGate.release(); try await until { calls == 2 }
        queue.cancel()
    }
    func testMissingAddressFailureIsRetryableAndDoesNotEnableAnything() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let model = OathManageTokensModel(catalog: OfflineManagedCatalog(),
            lookup: OathTokenSearchModel(service: FailingManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: token(100).reference, scope: .init(chain: .ethereum))
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.lookupFailed)
        let tracked = try await db.trackedAssets(walletID: "one")
        XCTAssertTrue(tracked.isEmpty)
        await model.load(query: "", scope: .all)
        XCTAssertFalse(model.lookupFailed)
        XCTAssertEqual(model.rows.count, 42)
    }
    func testLateCatalogResponseCannotReplaceNewChainOrDismissedPage() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = DelayedManagedCatalog()
        let model = OathManageTokensModel(catalog: catalog,
            lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        let old = Task { await model.load(query: "", scope: .init(chain: .ethereum)) }
        while await catalog.started < 1 { await Task.yield() }
        await model.load(query: "", scope: .init(chain: .base))
        XCTAssertEqual(model.rows.map(\.id), ["base:native"])
        await catalog.release(); await old.value
        XCTAssertEqual(model.rows.map(\.id), ["base:native"])
        let dismissed = Task { await model.load(query: "", scope: .init(chain: .ethereum)) }
        while await catalog.started < 2 { await Task.yield() }
        let beforeDismissal = model.rows.map(\.id)
        XCTAssertEqual(beforeDismissal, ["ethereum:native"], "Wallet rows publish before catalog completion")
        model.stop()
        dismissed.cancel()
        await catalog.release(); await dismissed.value
        XCTAssertEqual(model.rows.map(\.id), beforeDismissal)
    }
    func testWalletProjectionRefusesAnotherWalletAndCaseSensitiveReferencesStayDistinct() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        for reference in ["TokenCase", "tokencase"] {
            try await db.enableManagedToken(.init(id: "solana:" + reference, networkID: "solana", reference: reference,
                name: "Same", symbol: "SAME", decimals: 6), walletID: "one")
        }
        let model = OathManageTokensModel(catalog: OfflineManagedCatalog(), lookup: OathTokenSearchModel(service: UnexpectedManagedLookup(), catalog: OfflineManagedCatalog()))
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        model.accept(try await db.managedAssets(walletID: "two", currency: "USD"))
        await model.load(query: "Same", scope: .init(chain: .solana))
        XCTAssertEqual(Set(model.rows.map(\.reference)), ["TokenCase", "tokencase"])
        XCTAssertEqual(model.snapshot?.walletID, "one")
    }
    func testFullBundledCatalogAndEightyCommittedUpdatesDoNotRestartLoading() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_MANAGEMENT_SEED"])
        let seed = try Data(contentsOf: URL(fileURLWithPath: path))
        let catalog = CountingManagedCatalog(TokenDiscoveryCatalog(transport: FailedManagedProvider(),
            directory: directory.appendingPathComponent("catalog"), seed: seed), blocked: true)
        let model = OathManageTokensModel(catalog: catalog)
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        let revision = model.revision
        let load = Task { await model.load(query: "", scope: .all) }
        while await catalog.calls == 0 { await Task.yield() }
        XCTAssertEqual(model.rows.count, 42, "All native coins must show before disk/provider work completes")
        XCTAssertFalse(model.loading, "Wallet assets must not be replaced by a blocking spinner")
        // Use the production database observation while the initial catalog is
        // held. SwiftUI restarts only if revision changes; it must stay constant.
        let observer = Task { await model.observe(database: db, walletID: "one", currency: "USD") }
        let invalidations = ManagementInvalidations()
        withObservationTracking {
            _ = model.visibleRows
            _ = model.permittedNetworks
            _ = model.revision
            _ = model.observationFailed
            _ = model.loading
            for row in model.visibleRows { _ = model.enabled(row) }
        } onChange: { invalidations.increment() }
        let start = ContinuousClock.now
        for update in 0..<80 {
            try await db.savePrices([.init(assetID: "ethereum:native", currency: "USD", value: String(3000 + update),
                observedAt: Double(100 + update), source: "fixture")])
            try await db.saveBalances([.init(accountID: "oneethereum", assetID: "ethereum:native", networkID: "ethereum",
                amountAtomic: String(update + 1), observedAt: Double(100 + update), source: "fixture")])
        }
        try await until { model.snapshot?.holdings.first { $0.assetID == "ethereum:native" }?.balanceObservedAt == 179 }
        let updatesElapsed = start.duration(to: .now)
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.rows.count, 42)
        XCTAssertEqual(invalidations.value, 0, "80 balance/price commits must not invalidate the visible management list")
        let publishStart = ContinuousClock.now
        await catalog.release(); await load.value
        XCTAssertGreaterThan(model.rows.count, 30_000, "Regression must use the full production seed, not a tiny fixture")
        XCTAssertEqual(model.visibleRows.count, 200)
        let calls = await catalog.calls
        XCTAssertEqual(calls, 1, "80 committed price/balance updates must not request 80 catalog rebuilds")
        print("MANAGE full seed rows=\(model.rows.count), 80 committed price/balance pairs=\(updatesElapsed), catalog release to rows=\(publishStart.duration(to: .now)), catalog queries=\(calls)")
        let ids = model.rows.map(\.id)
        let beforeRefresh = model.revision
        await model.refreshCatalog()
        XCTAssertEqual(model.revision, beforeRefresh, "No-op/failed refresh must not rebuild existing cache")
        let eth = try XCTUnwrap(model.rows.first { $0.id == "ethereum:native" })
        let switchInvalidations = ManagementInvalidations()
        withObservationTracking { _ = model.enabled(eth) } onChange: { switchInvalidations.increment() }
        try await db.setAssetHidden(true, assetID: eth.id, walletID: "one")
        try await until { !model.enabled(eth) }
        XCTAssertEqual(switchInvalidations.value, 1, "Committed visibility changes must still update the switch")
        XCTAssertEqual(model.revision, revision, "Visibility changes update switches, not catalog membership")
        XCTAssertEqual(model.rows.map(\.id), ids)
        while model.visibleRows.count < model.rows.count { model.revealMore(after: try XCTUnwrap(model.visibleRows.last)) }
        XCTAssertEqual(model.visibleRows.count, ids.count)
        observer.cancel(); await observer.value
    }

    func testWalletBalanceThenActivityOrderAndCachedCatalogReuseAfterEnable() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        try await db.saveBalances(["bnb", "ethereum"].map {
            .init(accountID: "one" + $0, assetID: $0 + ":native", networkID: $0,
                amountAtomic: "1000000000000000000", observedAt: 1, source: "fixture")
        })
        try await db.savePrices([.init(assetID: "bnb:native", currency: "USD", value: "10", observedAt: 1, source: "fixture"),
                                .init(assetID: "ethereum:native", currency: "USD", value: "30", observedAt: 1, source: "fixture")])
        var batch = SyncBatch(cursor: .init(accountID: "onebase", stream: "fixture", cursor: "1", updatedAt: 1), expectedCursor: nil)
        batch.transactions = [.init(id: "base:fixture", networkID: "base", hash: "fixture", state: "confirmed", timestamp: 1, updatedAt: 1)]
        batch.activity = [.init(id: "activity", walletID: "one", accountID: "onebase", networkID: "base", transactionID: "base:fixture",
            assetID: "base:native", direction: "incoming", amountAtomic: "1", counterparty: "public-fixture", timestamp: 1)]
        _ = try await db.apply(batch)
        let seed = try JSONSerialization.data(withJSONObject: [["id": "token", "name": token(1).name, "symbol": "tst", "platforms": ["ethereum": token(1).reference]]])
        let catalog = CountingManagedCatalog(TokenDiscoveryCatalog(transport: FailedManagedProvider(), seed: seed))
        let model = OathManageTokensModel(catalog: catalog)
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        await model.load(query: "", scope: .all)
        XCTAssertEqual(Array(model.rows.prefix(3).map(\.id)), ["ethereum:native", "bnb:native", "base:native"])
        let before = model.rows.map(\.id), revision = model.revision
        try await db.enableManagedToken(token(1), walletID: "one")
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        XCTAssertEqual(model.revision, revision + 1)
        await model.load(query: "", scope: .all)
        XCTAssertEqual(model.rows.map(\.id), before)
        let calls = await catalog.calls
        XCTAssertEqual(calls, 1, "Membership changes reuse the prepared catalog for this query")
        XCTAssertTrue(model.enabled(try XCTUnwrap(model.rows.last)))
    }

    func testAlreadyCancelledLoadDoesNotReadCatalogOrReplaceVisibleRows() async throws {
        let (db, directory) = try await fixture(); defer { try? FileManager.default.removeItem(at: directory) }
        let catalog = CountingManagedCatalog(TokenDiscoveryCatalog(seed: Data()))
        let model = OathManageTokensModel(catalog: catalog)
        model.accept(try await db.managedAssets(walletID: "one", currency: "USD"))
        let gate = ManagedGate()
        let load = Task { await gate.wait(); await model.load(query: "", scope: .all) }
        try await until { !gate.waiters.isEmpty }
        load.cancel(); gate.release(); await load.value
        let calls = await catalog.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(model.rows.isEmpty)
    }

}
