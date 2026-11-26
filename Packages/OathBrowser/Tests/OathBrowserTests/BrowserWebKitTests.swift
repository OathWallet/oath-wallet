#if os(macOS)
import XCTest
import WebKit
@testable import OathBrowser

/// Host-only WebKit integration. No simulator, wallet credentials, or network access.
@MainActor final class BrowserWebKitTests: XCTestCase {
    func testRealWebKitBridgeDiscoveryEventsAndPrivateStoreIsolation() async throws {
        let harness = BrowserWebKitHarness()
        let web = harness.makeWebView()
        defer { web.configuration.userContentController.removeScriptMessageHandler(forName: "oathWallet", contentWorld: .page); web.stopLoading() }
        let loaded = expectation(description: "fixture loaded")
        harness.finished = { loaded.fulfill() }
        web.loadHTMLString("""
            <html><head><script>
            'use strict';
            window.ethereum.autoRefreshOnNetworkChange = false;
            window.early = window.oath.request({method:'eth_chainId'});
            </script></head><body><iframe srcdoc='<p>child</p>'></iframe></body></html>
            """, baseURL: URL(string: "https://example.com"))
        await fulfillment(of: [loaded], timeout: 15)
        let result = try await web.callAsyncJavaScript("""
          const early = await window.early;
          let announcement, accountsEvent = null, chainEvent = null;
          window.addEventListener('eip6963:announceProvider', e => { announcement = e.detail; });
          window.dispatchEvent(new Event('eip6963:requestProvider'));
          const wallet = announcement.provider;
          window.oath.on('accountsChanged', v => { accountsEvent = v[0]; });
          window.oath.on('chainChanged', v => { chainEvent = v; });
          window.dispatchEvent(new CustomEvent('oath:state', {detail:{accounts:['0x123'],chainId:'0x89',connected:true}}));
          let rejected = 0;
          try { await window.oath.request({method:'personal_sign',params:[]}); } catch (e) { rejected = e.code; }
          let iframeDenied = false;
          try { await document.querySelector('iframe').contentWindow.eval("window.webkit.messageHandlers.oathWallet.postMessage({method:'eth_chainId'})"); }
          catch (_) { iframeDenied = true; }
          localStorage.setItem('fixture', 'private');
          return {early, announced:announcement.info.name, accountsEvent, chainEvent, rejected, iframeDenied,
            autoRefresh:wallet.autoRefreshOnNetworkChange, sameProvider:wallet === window.oath && wallet === window.ethereum,
            frozen:Object.isFrozen(wallet), lockedAnnouncement:Object.isFrozen(announcement) && Object.isFrozen(announcement.info),
            childProvider:!!document.querySelector('iframe').contentWindow.oath};
          """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        XCTAssertEqual(result?["early"] as? String, "0x1")
        XCTAssertEqual(result?["announced"] as? String, "Oath Wallet")
        XCTAssertEqual(result?["accountsEvent"] as? String, "0x123")
        XCTAssertEqual(result?["chainEvent"] as? String, "0x89")
        XCTAssertEqual(result?["rejected"] as? Int, 4001)
        XCTAssertEqual(result?["iframeDenied"] as? Bool, true)
        XCTAssertEqual(result?["autoRefresh"] as? Bool, false)
        XCTAssertEqual(result?["sameProvider"] as? Bool, true)
        XCTAssertEqual(result?["frozen"] as? Bool, true)
        XCTAssertEqual(result?["lockedAnnouncement"] as? Bool, true)
        XCTAssertEqual(result?["childProvider"] as? Bool, false)
        XCTAssertTrue(harness.origins.allSatisfy { $0 == "https://example.com" })
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        let isolated = harness.makeWebView()
        defer { isolated.configuration.userContentController.removeScriptMessageHandler(forName: "oathWallet", contentWorld: .page); isolated.stopLoading() }
        let secondLoaded = expectation(description: "separate private store loaded")
        harness.finished = { secondLoaded.fulfill() }
        isolated.loadHTMLString("<html><body>Separate store</body></html>", baseURL: URL(string: "https://example.com"))
        await fulfillment(of: [secondLoaded], timeout: 15)
        let empty = try await isolated.evaluateJavaScript("localStorage.getItem('fixture') === null") as? Bool
        XCTAssertEqual(empty, true)
    }
}
@MainActor private final class BrowserWebKitHarness: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    var finished: (() -> Void)?
    var origins: [String] = []
    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "oathWallet")
        config.userContentController.addUserScript(.init(source: BrowserProviderScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = self; return web
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?(); finished = nil }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let origin = message.frameInfo.securityOrigin
        origins.append(origin.protocol + "://" + origin.host)
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { replyHandler(nil, "Invalid"); return }
        switch body["method"] as? String {
        case "oath_document": replyHandler(["result":"fixture-document"], nil)
        case "eth_chainId": replyHandler(["result":"0x1"], nil)
        default: replyHandler(["error":["code":4001,"message":"Request cancelled."]], nil)
        }
    }
}
#endif
