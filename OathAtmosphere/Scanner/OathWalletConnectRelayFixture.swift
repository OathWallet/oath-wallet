#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import OathDiagnostics

/// Live simulator relay harness. Uses the real encrypted vault, passcode UI,
/// session service, SDK and approval views. Imported key material is limited to
/// public test vectors; no user wallet or production installation is accessed.
struct OathWalletConnectRelayFixture: View {
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "oath.wcRelayFixture") &&
        UserDefaults.standard.string(forKey: "oath.walletTestScope").flatMap(UUID.init(uuidString:)) != nil
    }
    let session: OathWalletSession
    @State private var ready = false
    @State private var failed = false
    @State private var stage = "loading"
    @State private var failureType = ""
    @State private var service = OathWalletConnectService.shared
    @State private var browser = OathBrowserController()
    private var browserFixture: Bool { UserDefaults.standard.bool(forKey: "oath.browserFixture") }
    private struct Fixture: Decodable { let uri: String }
    var body: some View {
        Group {
            if ready && browserFixture {
                OathBrowserRoot(controller: browser, session: session, searchEngine: .duckDuckGo, showsRecentSites: true, active: true)
            } else if failed {
                Text("Relay fixture setup failed: \(stage) / \(failureType)").accessibilityIdentifier("wc.relay.failed")
            } else if ready {
                NavigationStack {
                    VStack {
                        Text("Isolated live relay check").accessibilityIdentifier("wc.relay.ready")
                        Button("Open connection") {
                            OathWalletLinkInbox.shared.receive(URL(string: "oathwallet://wc")!)
                        }.accessibilityIdentifier("wc.relay.open")
                        NavigationLink("Manage connections") {
                            OathWalletConnectPage(session: session, walletID: session.wallets.first?.id)
                        }.accessibilityIdentifier("wc.relay.manage")
                    }
                }
            } else { ProgressView() }
        }
        .task {
            do {
                // This root replaces WalletRoot, which normally owns load().
                await session.load()
                stage = "vault"
                if try await session.vault.exists() { await session.unlock([1,2,3,4,5,6]) }
                else {
                    let networks: [OathImportChain] = UserDefaults.standard.bool(forKey: "oath.wcAllEVMFixture")
                        ? OathImportChain.enabledCases.filter { chain in
                            chain.isEVM && OathWalletConnectService.blockchain(chain).map {
                                OathWalletConnectPolicy.supportsConnection($0.absoluteString)
                            } == true
                        } : [.ethereum, .arbitrum]
                    if UserDefaults.standard.bool(forKey: "oath.wcMultiNamespaceFixture") {
                        // Public BIP-39 vector, isolated from the user's vault.
                        let phrase = OathValidatedMnemonic(phrase: Array(repeating: "abandon", count: 11).joined(separator: " ") + " about", language: "english")
                        try await session.vault.create(digits: [1,2,3,4,5,6], importing: phrase)
                    } else {
                        try await session.vault.create(digits: [1,2,3,4,5,6], importing: nil,
                            privateKey: .init(bytes: Data(repeating: 1, count: 32), networks: networks))
                    }
                    stage = "home"
                    await session.finishedSetup(requiresCustomization: false)
                }
                guard session.isUnlocked else { throw OathWalletError.locked }
                if browserFixture {
                    stage = "browser"
                    await browser.load(session: session)
                    let live = UserDefaults.standard.bool(forKey: "oath.browserLive1inch")
                    let url = URL(string: live ? "https://1inch.com/" : "https://example.com/")!
                    browser.open(url)
                    if !live, let tab = browser.selected {
                        let web = browser.ensureWebView(tab)
                        web.stopLoading()
                        web.loadHTMLString(Self.browserHTML, baseURL: url)
                    }
                    ready = true
                    return
                }
                stage = "pairing-file"
                let file = URL.documentsDirectory.appendingPathComponent("walletconnect-relay-fixture.json")
                let data = try Data(contentsOf: file)
                guard data.count < 4096 else { throw OathWalletConnectService.ConfigurationFailure.invalid }
                let fixture = try JSONDecoder().decode(Fixture.self, from: data)
                try FileManager.default.removeItem(at: file)
                service.configure(session: session)
                stage = "pairing"
                ready = true
                if let url = URL(string: fixture.uri) { OathWalletLinkInbox.shared.receive(url) }
            } catch {
                OathDiagnostics.record(error, component: "walletconnect_test", operation: "relay_fixture_setup")
                failureType = String(describing: type(of: error))
                if let installationError = error as? OathInstallationSecurityError {
                    // This closed enum carries no wallet data; display only a
                    // fixed category or numeric OSStatus in the test harness.
                    switch installationError {
                    case .keychain(let status): failureType = "keychain-\(status)"
                    case .invalidKey: failureType = "invalid-installation-key"
                    case .invalidRecord: failureType = "invalid-installation-record"
                    case .unsafePath: failureType = "unsafe-installation-path"
                    }
                }
                failed = true
            }
        }.oathWalletConnectPresentation(session: session)
    }

    // A controlled dApp page exercises the actual production WebKit bridge,
    // SwiftUI sheet and encrypted vault. It never receives signing credentials.
    private static let browserHTML = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
    <style>body{font:18px system-ui;padding:24px}button{display:block;padding:18px;margin:18px 0}</style></head>
    <body><h1>Oath browser validation</h1><p id="state">Ready</p>
    <button id="connect">Connect Oath</button><button id="sign">Sign test message</button>
    <button id="disconnect">Disconnect Oath</button><script>
    let account;
    const status = text => document.getElementById('state').textContent = text;
    const run = action => action().catch(e => status('Rejected ' + e.code));
    document.getElementById('connect').onclick = () => run(async () => {
      status('Requesting accounts');
      const accounts = await window.oath.request({method:'eth_requestAccounts'});
      account = accounts[0]; status(account ? 'Connected to Oath' : 'No account');
    });
    document.getElementById('sign').onclick = () => run(async () => {
      const signature = await window.oath.request({method:'personal_sign',params:['0x4f6174682062726f777365722074657374',account]});
      status(/^0x[0-9a-fA-F]{130}$/.test(signature) ? 'Message signed' : 'Invalid signature');
    });
    document.getElementById('disconnect').onclick = () => run(async () => {
      await window.oath.request({method:'wallet_revokePermissions',params:[{eth_accounts:{}}]});
      const accounts = await window.oath.request({method:'eth_accounts'});
      status(accounts.length === 0 ? 'Disconnected from Oath' : 'Permission remained');
    });
    </script></body></html>
    """#
}
#endif
