import XCTest
import WebKit
@testable import BrowserFixture

@MainActor final class BrowserRuntimeTests: XCTestCase {
    private var model: OathBrowserModel!
    private var window: UIWindow!
    private let base = URL(string: "https://browser-fixture.invalid/")!

    override func setUp() async throws {
        model = OathBrowserModel(); model.active = true; model.prepareWebView()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController(); window.rootViewController = controller
        window.makeKeyAndVisible()
        let web = try XCTUnwrap(model.webView)
        web.frame = window.bounds; controller.view.addSubview(web)
        web.loadSimulatedRequest(URLRequest(url: base), responseHTML: """
        <!doctype html><html><head><title>Browser fixture</title></head>
        <body><a id="link" href="oathwallet://wc">Connect</a>
        <a id="window" href="oathwallet://wc" target="_blank">New window</a></body></html>
        """)
        try await eventually { self.model.title == "Browser fixture" && !self.model.loading }
    }
    override func tearDown() async throws {
        model?.clear(); window?.isHidden = true; window?.rootViewController = nil
        window = nil; model = nil
    }
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(condition(), "WebKit fixture condition timed out")
    }
    private func js(_ script: String) async throws { _ = try await model.webView!.evaluateJavaScript(script + "; void 0") }

    func testMainFrameAndNewWindowLinksEnterNativeHandoff() async throws {
        var received: [(URL, String)] = []
        model.walletLink = { received.append(($0, $1)) }
        XCTAssertEqual(model.url?.host, base.host)
        try await js("document.getElementById('link').click()")
        try await eventually { received.count == 1 }
        XCTAssertEqual(received.first?.1, base.host)
        XCTAssertEqual(model.url?.host, base.host)
        XCTAssertNil(model.issue)
        try await js("document.getElementById('window').click()")
        try await eventually { received.count == 2 }
        XCTAssertNil(model.issue)
    }
    func testIframeAndInactivePageCannotRequestWallet() async throws {
        var received = 0
        model.walletLink = { _, _ in received += 1 }
        try await js("""
        const frame = document.createElement('iframe');
        frame.srcdoc = "<script>parent.iframeRan = true; location.href='oathwallet://wc'</script>";
        document.body.appendChild(frame);
        """)
        try await Task.sleep(for: .milliseconds(350))
        let iframeRan = try await model.webView!.evaluateJavaScript("window.iframeRan === true") as? Bool
        XCTAssertEqual(iframeRan, true, "Exercise a running iframe, not just a rejected document")
        XCTAssertEqual(received, 0)
        model.active = false
        try await js("document.getElementById('link').click()")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(received, 0)
    }
    func testTemporaryStorageAndLockCleanupRejectOldView() async throws {
        let oldView = try XCTUnwrap(model.webView)
        XCTAssertFalse(oldView.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(oldView.configuration.preferences.isFraudulentWebsiteWarningEnabled)
        XCTAssertTrue(oldView.configuration.userContentController.userScripts.isEmpty)
        XCTAssertFalse(oldView.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        var received = 0
        model.walletLink = { _, _ in received += 1 }
        model.active = false; model.clear()
        XCTAssertNil(model.webView); XCTAssertNil(model.url)
        XCTAssertNil(oldView.navigationDelegate); XCTAssertNil(oldView.uiDelegate)
        model.webViewWebContentProcessDidTerminate(oldView)
        XCTAssertNil(model.issue)
        model.active = true; model.prepareWebView()
        XCTAssertFalse(model.webView === oldView)
        XCTAssertFalse(model.webView?.configuration.websiteDataStore === oldView.configuration.websiteDataStore)
        XCTAssertEqual(received, 0)
    }
    func testNativeDialogCompletesOnDeactivation() async throws {
        try await js("setTimeout(() => { window.answer = confirm('Website message'); }, 0)")
        try await eventually { self.model.dialog != nil }
        XCTAssertEqual(model.dialog?.host, base.host)
        model.active = false
        XCTAssertNil(model.dialog)
        model.resolveDialog(accept: true) // repeated/delayed UI action is harmless
        let answer = try await model.webView!.evaluateJavaScript("window.answer") as? Bool
        XCTAssertEqual(answer, false)
    }
}
