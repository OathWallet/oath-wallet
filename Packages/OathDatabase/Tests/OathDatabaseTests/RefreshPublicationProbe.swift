import Foundation
import XCTest
@testable import OathDatabase

/// Tests the same coordinator and live SQLite observation used by Home. No
/// reopening, polling replacement database, or test-only session implementation.
@MainActor final class RefreshPublicationProbe {
    private let coordinator = PortfolioRefreshCoordinator<WalletSnapshot>()
    private(set) var snapshot: WalletSnapshot?
    init(_ database: OathDatabase, wallet: String, currency: String = "USD") {
        coordinator.observe(stream: { database.observeWallet(walletID: wallet, currency: currency) }, isCurrent: { true },
            publish: { [weak self] in self?.snapshot = $0 }, exhausted: { XCTFail("Portfolio observation exhausted") })
    }
    func expect(_ reference: String = "native", amount: String, network: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if snapshot?.holdings.contains(where: { $0.networkID == network && $0.reference == reference && $0.amountAtomic == amount }) == true { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Committed \(network) \(reference) balance did not reach the open portfolio", file: file, line: line)
    }
    func stop() { coordinator.stop() }
}
