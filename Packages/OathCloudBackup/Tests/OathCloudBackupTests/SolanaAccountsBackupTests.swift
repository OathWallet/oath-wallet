import XCTest
@testable import OathCloudBackup

final class SolanaAccountsBackupTests: XCTestCase {
    private func wallet(path: String = "m/44'/501'/3'/0'", network: String = "solana", selected: String? = nil, fixed: Bool? = true) -> BackupWallet {
        .init(id: UUID(), name: "Fixture", mnemonic: "public synthetic fixture", language: "english", createdAt: Date(),
            accounts: [.init(network: network, derivationPath: path, index: 1, solanaReceivePath: selected, solanaPathOnly: fixed)])
    }

    func testIndependentAccountPolicyRoundTripsInForwardProtectedBackup() throws {
        let original = wallet(selected: "m/44'/501'/3'/0'")
        let data = try BackupDocument.seal(original, password: "synthetic-password")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let header = try XCTUnwrap(json["header"] as? [String: Any])
        XCTAssertEqual(header["version"] as? Int, 22)
        let reopened = try BackupDocument.open(data, password: "synthetic-password")
        XCTAssertEqual(reopened.accounts, original.accounts)
        let legacy = try BackupDocument.seal(wallet(fixed: nil), password: "synthetic-password")
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [String: Any])
        XCTAssertEqual((oldJSON["header"] as? [String: Any])?["version"] as? Int, 1)
    }

    func testRejectsInvalidFixedPathsAndCrossAccountReceiveSelection() throws {
        for value in [wallet(path: "m/44'/501'/1'/0"), wallet(path: "m/1'/2147483648'"),
                      wallet(path: "m/01'"), wallet(network: "ethereum"), wallet(selected: "m/44'/501'/9'/0'")] {
            XCTAssertThrowsError(try BackupDocument.seal(value, password: "synthetic-password"))
        }
    }
}
