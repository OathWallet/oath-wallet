import SwiftUI
// The real link parser/inbox are covered by CheckScanner.py --links. This tiny
// boundary recognizes only this fixture's synthetic URI; no relay or vault exists.
enum OathStringKey { case browserInvalidAddress, browserLoadFailed }
enum OathWalletLink {
    case connections
    var isWalletConnect: Bool { true }
    static func parse(_ url: URL) -> Self? { url.absoluteString == "oathwallet://wc" ? .connections : nil }
}
@main struct BrowserFixture: App {
    var body: some Scene { WindowGroup { Text("WebKit browser regression fixture") } }
}
