#!/usr/bin/env python3
"""Run the production permission coordinator's lifecycle against a fake OS.

Only the financial executor is replaced with deliberately uncooperative work.
The start method, expiration callback and completion defer are copied verbatim.
No UIKit, device, wallet, network, or transaction is used.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "OathAtmosphere/Permissions/OathPermissionBatchCoordinator.swift").read_text()


def block(text, marker):
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]


start = block(source, "    func start(")
cleanup = block(source[source.index("    private func run("):], "        defer {")
end = block(source, "    private func endBackgroundAssertion(") if "    private func endBackgroundAssertion(" in source else ""

harness = r'''
import Foundation

struct UIBackgroundTaskIdentifier: Equatable { let rawValue: Int; static let invalid = Self(rawValue: -1) }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var callbacks: [@MainActor () -> Void] = []
    var ended: [UIBackgroundTaskIdentifier] = []
    func beginBackgroundTask(withName: String, expirationHandler: @escaping @MainActor () -> Void) -> UIBackgroundTaskIdentifier {
        callbacks.append(expirationHandler)
        return .init(rawValue: callbacks.count)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) { ended.append(id) }
}
struct PermissionBatchItem { let walletID: String }
enum PermissionError: Error { case changed }
enum OathDiagnostics { static func record(_ error: any Error, component: String, operation: String) {} }
actor Database { func savePermissionBatch(_ items: [PermissionBatchItem]) throws {} }
actor OathWalletVault {
    func database() throws -> Database { Database() }
    func endPermissionBatch(_ authorization: UUID) {}
}
@MainActor final class Coordinator {
    private(set) var runningWalletID: String?
    private var job: Task<Void, Never>?
    private var assertion: UIBackgroundTaskIdentifier = .invalid
    var release: CheckedContinuation<Void, Never>?
    var cancellationObserved = false
    START
    END
    private func run(_ items: [PermissionBatchItem], authorization: UUID, vault: OathWalletVault) async {
        CLEANUP
        await withCheckedContinuation { release = $0 }
        cancellationObserved = Task.isCancelled
    }
}
@main struct Check {
    @MainActor static func main() async throws {
        var failed = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failed += 1; print("FAIL: " + message) }
        }
        func settle(_ condition: () -> Bool) async throws {
            for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
            check(condition(), "executor settled")
        }
        let os = UIApplication.shared, coordinator = Coordinator(), vault = OathWalletVault()
        try await coordinator.start([.init(walletID: "fixture")], authorization: UUID(), vault: vault)
        try await settle { coordinator.release != nil }
        os.callbacks[0]()
        check(os.ended == [.init(rawValue: 1)], "expiration must end the assertion before returning, even with blocked cleanup")
        check(coordinator.runningWalletID != nil, "expiration must retain ownership until unsigned work has stopped")
        os.callbacks[0]()
        check(os.ended.count == 1, "duplicate expiration must not end the same assertion twice")
        let release = coordinator.release; coordinator.release = nil; release?.resume()
        try await settle { coordinator.runningWalletID == nil }
        check(coordinator.cancellationObserved, "expiration cancels executor")
        check(os.ended.count == 1, "completion after expiration must not double-end")
        coordinator.cancellationObserved = false
        try await coordinator.start([.init(walletID: "fixture")], authorization: UUID(), vault: vault)
        try await settle { coordinator.release != nil }
        let next = coordinator.release; coordinator.release = nil; next?.resume()
        try await settle { coordinator.runningWalletID == nil }
        check(os.ended == [.init(rawValue: 1), .init(rawValue: 2)], "ordinary completion ends its own assertion")
        check(!coordinator.cancellationObserved, "ordinary completion is not cancelled")
        print("Background expiration lifecycle: \(failed) failures")
        if failed != 0 { exit(1) }
    }
}
'''.replace("START", start).replace("CLEANUP", cleanup).replace("END", end)

with tempfile.TemporaryDirectory(prefix="oath-expiration-") as directory:
    swift = Path(directory) / "Check.swift"
    binary = Path(directory) / "check"
    swift.write_text(harness)
    subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
