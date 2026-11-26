import XCTest
import SwiftUI

extension Sheet: Identifiable {
    var id: String { switch self {
    case .backup(let id, _): "backup-" + id.uuidString
    case .editor: "editor"
    default: "security"
    } }
}
@MainActor @Observable final class NativeFixture {
    let home = Home()
    var mounted = false
    var angle = 0.0
    var ticks = 0
    var appeared = 0
    var dismissed = 0
}
struct Fixture: View {
    @Bindable var model: NativeFixture
    @Bindable var home: Home
    var body: some View {
        Group {
            if model.mounted {
                NavigationStack {
                    VStack {
                        Text("Synthetic Home")
                        Circle().fill(.blue).frame(width: 50, height: 50)
                            .offset(x: model.angle)
                        Text("Background updates: \(model.ticks)")
                    }
                    // PRODUCTION_BACKUP_APPEARANCE
                }
            } else { Color.clear }
        }
        .onChange(of: home.nextSecurityNotice, initial: true) { _, _ in home.presentNextSecurityNotice() }
        .onChange(of: home.sheet?.id) { _, id in if let id { home.presentedSheetID = id } }
        .sheet(item: $home.sheet, onDismiss: { model.dismissed += 1; home.dismiss() }) { sheet in
            Text(sheet == .editor ? "Import wallet" : "Back up your wallet")
                .presentationDetents([.medium])
                .onAppear { if case .backup = sheet { model.appeared += 1 } }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
                model.ticks += 1
            }
        }
        .environment(\.scenePhase, .active)
    }
}
@MainActor final class NativeBackupTests: XCTestCase {
    func testPresentationWhileHomeLoopsAndAfterImportDismissal() async throws {
        let model = NativeFixture()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: Fixture(model: model, home: model.home))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        withAnimation(.linear(duration: 10).repeatForever(autoreverses: true)) {
            model.mounted = true; model.angle = 20
        }
        try await wait { model.home.session.vault.db.calls == 1 }
        let first = model.home.profile!.id
        model.home.currentWallet?.pendingBackupOffer = nil
        model.home.session.vault.db.finish(first)
        try await wait { model.appeared == 1 }
        let tick = model.ticks
        try await wait { model.ticks > tick + 5 }
        XCTAssertTrue(model.home.shouldPreparePortfolio)
        model.home.sheet = nil
        try await wait { model.dismissed == 1 && host.presentedViewController == nil }
        model.home.sheet = .editor
        try await wait { host.presentedViewController?.isBeingPresented == false && host.presentedViewController != nil }
        let second = UUID()
        model.home.select(second, offer: .cloudOnly)
        XCTAssertEqual(model.home.session.vault.db.calls, 1)
        model.home.sheet = nil
        try await wait { model.dismissed == 2 && model.home.session.vault.db.calls == 2 }
        model.home.currentWallet?.pendingBackupOffer = nil
        model.home.session.vault.db.finish(second)
        try await wait { model.appeared == 2 }
        let whilePresented = model.ticks
        try await wait { model.ticks > whilePresented + 5 }
        model.home.sheet = nil
        try await wait { model.dismissed == 3 && host.presentedViewController == nil }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(model.appeared, 2)
        XCTAssertEqual(model.home.session.vault.db.calls, 2)
    }
    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            if ContinuousClock.now > deadline { XCTFail("Native backup lifecycle timed out"); throw CocoaError(.coderInvalidValue) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
