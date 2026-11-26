import Foundation
import SwiftUI
import XCTest
import OathDatabase
import OathSidebar
import OathTokenImages
@testable import OathAtmosphere

func makeTestDatabase() async throws -> OathDatabase {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathSQLFixture-" + UUID().uuidString)
        .appendingPathComponent("wallet.sqlite")
    let database = try await OathDatabase.open(at: url)
    try await OathDataEnvironment.seed(database)
    return database
}

@MainActor final class OathDatabaseIntegrationTests: XCTestCase {
    private struct OfflineArtwork: ArtworkTransport, TokenArtworkMetadata {
        func data(from url: URL) async throws -> Data { throw URLError(.notConnectedToInternet) }
        func sources(for token: TokenArtworkIdentity, cachedOnly: Bool) async -> [String] { [] }
    }

    #if DEBUG && targetEnvironment(simulator)
    func testWalletActionsStayBelowExistingWalletsThroughoutNavigation() async throws {
        let db = try await makeTestDatabase()
        let active = UUID()
        for (index, kind) in ["hd", "hd", "imported", "imported"].enumerated() {
            let id = index == 0 ? active.uuidString : UUID().uuidString
            try await db.importWalletIfNeeded(.init(id: id, name: "Fixture \(index)", kind: kind,
                vaultReference: "fixture-\(index)", createdAt: Double(index + 1), backedUp: true), accounts: [])
        }
        let session = try await OathWalletSession.scrollFixtureSession(database: db, walletID: active)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let settings = UIViewController()
        settings.title = "Settings"
        let nav = UINavigationController(rootViewController: settings)
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }

        func collection(in view: UIView) -> UICollectionView? {
            if let list = view as? UICollectionView { return list }
            return view.subviews.lazy.compactMap { collection(in: $0) }.first
        }
        for _ in 0..<2 {
            // Match a tap from a Settings screen that has already appeared.
            let readyBy = CACurrentMediaTime() + 2
            while settings.viewIfLoaded?.layer.presentation() == nil, CACurrentMediaTime() < readyBy {
                try await Task.sleep(for: .milliseconds(8))
            }
            _ = try XCTUnwrap(settings.viewIfLoaded?.layer.presentation())
            let page = OathWalletManagementPage(session: session, removal: OathWalletRemovalModel(session: session),
                editMode: .constant(.inactive), onWallet: { _ in }, onRecentlyDeleted: {}) {
                    OathWalletActions(identifier: "fixture", onCreate: {}, onCreateMultisig: {},
                                      onImport: {}, onImportPrivateKey: {}, onRestore: {})
                }
            let host = UIHostingController(rootView: page.oathLanguage(.english))
            nav.pushViewController(host, animated: true)
            var footerPositions: [CGFloat] = []
            var sectionCounts = Set<Int>()
            var sampledDuringPush = false
            let end = CACurrentMediaTime() + 1
            while CACurrentMediaTime() < end {
                if let view = host.viewIfLoaded, let list = collection(in: view), list.numberOfSections > 0,
                   let footer = list.cellForItem(at: IndexPath(item: 0, section: list.numberOfSections - 1)),
                   let layer = footer.layer.presentation(), let listLayer = list.layer.presentation(),
                   let root = window.layer.presentation(), window.bounds.intersects(layer.convert(layer.bounds, to: root)) {
                    sectionCounts.insert(list.numberOfSections)
                    // Local coordinates exclude the horizontal navigation push.
                    footerPositions.append(layer.convert(layer.bounds, to: listLayer).minY)
                    if host.transitionCoordinator != nil { sampledDuringPush = true }
                }
                try await Task.sleep(for: .milliseconds(8))
            }
            XCTAssertTrue(sampledDuringPush, "The actions must be visible during the navigation transition.")
            XCTAssertEqual(sectionCounts, [3], "Both wallet groups and the actions must be present on entry.")
            let top = try XCTUnwrap(footerPositions.min())
            let bottom = try XCTUnwrap(footerPositions.max())
            XCTAssertLessThanOrEqual(bottom - top, 1, "The Add Wallet options moved during the push.")
            nav.popViewController(animated: false)
        }
    }
    #endif

    func testHistoryDisplaysTokenArtworkForIncomingAndOutgoingTransfers() async throws {
        let db = try await makeTestDatabase()
        let wallet = UUID().uuidString
        let usdt = AssetRecord(id: "history-usdt", networkID: "bnb", reference: "0x55d398326f99059ff775485246999027b3197955",
                               name: "Tether", symbol: "USDT", decimals: 18)
        // Same ticker, different contract. This one's supplied artwork is magenta.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='32' height='32'><rect width='32' height='32' fill='#ff00ff'/></svg>"
        let other = AssetRecord(id: "history-other", networkID: "bnb", reference: "0x0000000000000000000000000000000000000011",
                                name: "Fixture", symbol: "USDT", decimals: 6,
                                logo: "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString())
        try await db.seed(networks: [], assets: [usdt, other])
        try await db.importWalletIfNeeded(.init(id: wallet, name: "History", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "history", walletID: wallet, networkID: "bnb", address: "fixture", derivationPath: "")])
        var batch = SyncBatch(cursor: .init(accountID: "history", stream: "fixture", cursor: "1", updatedAt: 1), expectedCursor: nil)
        for (index, asset) in [usdt, usdt, other].enumerated() {
            let id = "fixture-\(index)"
            batch.transactions.append(.init(id: id, networkID: "bnb", hash: id, state: "confirmed", timestamp: 1, updatedAt: 1))
            batch.activity.append(.init(id: id, walletID: wallet, accountID: "history", networkID: "bnb", transactionID: id,
                assetID: asset.id, direction: index == 0 ? "outgoing" : "incoming", amountAtomic: "1", counterparty: "peer", timestamp: 1))
        }
        try await db.apply(batch)
        let rows = try await db.chainHistory(walletID: wallet, currency: "USD")
        XCTAssertEqual(rows.count, 3)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let offline = OfflineArtwork()
        let loader = ArtworkLoader(directory: temporary.appendingPathComponent("images"), transport: offline,
                                   fallbackCatalog: ArtworkFallbackCatalog(transport: offline))
        let resolver = TokenArtworkResolver(loader: loader, metadata: offline, directory: temporary.appendingPathComponent("identities"))
        let history = NavigationStack {
            List {
                OathActivityRows(items: rows, currency: "USD", balancesHidden: false) { _ in }
                    .listRowInsets(EdgeInsets())
            }.listStyle(.plain)
        }
        window.rootViewController = UIHostingController(rootView: OathStatusBarHost {
            SidebarContainer(isPresented: .constant(false), closeLabel: "Close") {
                TabView { history.tabItem { Text("History") } }
                    .environment(\.oathTokenArtworkResolver, resolver)
            } sidebar: { EmptyView() }
            .environment(\.scenePhase, .active)
        })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        var colors = (green: 0, magenta: 0)
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            colors = try logoColorBands(in: window)
            if colors == (2, 1) { break }
        }
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "Synthetic token transfer logos"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(colors.green, 2, "Both transfers should display the USDT mark")
        XCTAssertEqual(colors.magenta, 1, "An unrelated contract must display its own supplied artwork")
    }

    private func logoColorBands(in window: UIWindow) throws -> (green: Int, magenta: Int) {
        // Scan the leading icon column at one pixel per point. Small direction badges
        // cannot produce a band of 12 saturated scanlines in this part of the row.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let strip = CGSize(width: 66, height: window.bounds.height)
        let image = UIGraphicsImageRenderer(size: strip, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let width = Int(strip.width), height = Int(strip.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(try XCTUnwrap(image.cgImage), in: CGRect(origin: .zero, size: strip))
            var green = 0, magenta = 0, greenRun = 0, magentaRun = 0
            for y in 0..<height {
                var greenPixels = 0, magentaPixels = 0
                for x in 26..<55 {
                    let i = (y * width + x) * 4
                    let r = Int(buffer[i]), g = Int(buffer[i + 1]), b = Int(buffer[i + 2])
                    if g > r + 45 && g >= b - 5 { greenPixels += 1 }
                    if r > g + 100 && b > g + 100 { magentaPixels += 1 }
                }
                greenRun = greenPixels >= 8 ? greenRun + 1 : 0
                magentaRun = magentaPixels >= 8 ? magentaRun + 1 : 0
                if greenRun == 12 { green += 1 }
                if magentaRun == 12 { magenta += 1 }
            }
            return (green, magenta)
        }
    }

    func testAllSupportedNetworksAreSeededOnce() async throws {
        let database = try await makeTestDatabase()
        try await OathDataEnvironment.seed(database)
        let networks = try await database.networks()
        XCTAssertEqual(networks.count, 30)
        XCTAssertEqual(Set(networks.map(\.id)), Set(OathImportChain.allCases.map(\.id)))
    }

    func testStoredProfileUsesDatabaseAccountIdentity() async throws {
        let database = try await makeTestDatabase()
        let id = UUID().uuidString
        try await database.importWalletIfNeeded(
            WalletRecord(id: id, name: "Public fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [AccountRecord(id: "account", walletID: id, networkID: "bitcoin", address: "public-fixture", derivationPath: "fixture")])
        let snapshot = try await database.snapshot(walletID: id, currency: "USD")
        let profile = try OathWalletProfile.stored(snapshot)
        XCTAssertEqual(profile.addresses.first?.accountID, "account")
        XCTAssertEqual(profile.addresses.first?.assetID, "bitcoin:native")
        XCTAssertNil(snapshot.holdings.first?.amountAtomic)
        XCTAssertEqual(snapshot.totalFiat, 0)
    }
}
