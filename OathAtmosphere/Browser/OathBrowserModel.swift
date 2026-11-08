import Foundation
import Observation
import OathDiagnostics
@preconcurrency import WebKit

/// WebKit owns page execution. Wallet requests leave WebKit through the existing
/// bounded native inbox; this model has no signer, key access or JS message bridge.
@MainActor @Observable final class OathBrowserModel: NSObject, WKNavigationDelegate, WKUIDelegate, OathBrowserPage {
    private(set) var webView: WKWebView?
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var loading = false
    private(set) var progress = 0.0
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    var issue: OathStringKey?
    var externalURL: URL?
    var dialog: Dialog?
    var dialogText = ""
    var active = false { didSet { if !active { resolveDialog(accept: false) } } }
    @ObservationIgnored var walletLink: ((URL, String) -> Void)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var dialogCompletion: ((Bool, String) -> Void)?
    @ObservationIgnored private var operation = UUID()
    @ObservationIgnored private var reportedFailure = false
    @ObservationIgnored private var currentNavigation: WKNavigation?

    struct Dialog: Identifiable {
        enum Kind { case alert, confirm, prompt }
        let id = UUID()
        let host: String
        let message: String
        let kind: Kind
    }

    func open(_ input: String) {
        guard active, let target = OathBrowserPolicy.website(input, allowsBareHost: true),
              case .website = OathBrowserPolicy.destination(target) else { issue = .browserInvalidAddress; return }
        prepareWebView()
        issue = nil
        webView?.load(URLRequest(url: target))
    }

    func back() { guard active else { return }; webView?.goBack() }
    func forward() { guard active else { return }; webView?.goForward() }
    func reload() { guard active else { return }; issue = nil; webView?.reload() }
    func stop() { webView?.stopLoading(); loading = false }

    func clear() {
        resolveDialog(accept: false)
        externalURL = nil
        observations.removeAll(); currentNavigation = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView = nil; url = nil; title = ""; issue = nil
        loading = false; progress = 0; canGoBack = false; canGoForward = false
    }

    func prepareWebView() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isOpaque = false
        webView = view
        observations = [view.observe(\.estimatedProgress, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor in self?.update(from: view) }
        }, view.observe(\.url, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor in self?.update(from: view) }
        }, view.observe(\.title, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor in self?.update(from: view) }
        }, view.observe(\.isLoading, options: [.new]) { [weak self, weak view] _, _ in
            Task { @MainActor in self?.update(from: view) }
        }]
    }

    private func update(from view: WKWebView?) {
        guard let view, view === webView else { return }
        url = view.url.flatMap { OathBrowserPolicy.website($0.absoluteString) }
        title = OathBrowserPolicy.displayTitle(view.title ?? "", fallback: url?.host ?? "")
        loading = view.isLoading; progress = view.estimatedProgress
        canGoBack = view.canGoBack; canGoForward = view.canGoForward
    }

    private func trustedSource(_ action: WKNavigationAction, in view: WKWebView) -> Bool {
        trustedFrame(action.sourceFrame, in: view)
    }

    private func trustedFrame(_ frame: WKFrameInfo, in view: WKWebView) -> Bool {
        let origin = frame.securityOrigin
        let port = origin.port == 0 || origin.port == 443 ? "" : ":\(origin.port)"
        return OathBrowserPolicy.canRequestWallet(sourceIsMainFrame: frame.isMainFrame,
            sourceOrigin: origin.protocol + "://" + origin.host.lowercased() + port,
            currentURL: view.url, active: active && view === webView)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard webView === self.webView, let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Empty documents are ordinary WebKit iframe/window scaffolding. They
        // grant no wallet authority: trustedFrame still requires public HTTPS.
        if target.absoluteString == "about:blank" ||
            (target.absoluteString == "about:srcdoc" && navigationAction.targetFrame?.isMainFrame == false) {
            decisionHandler(active ? .allow : .cancel); return
        }
        switch OathBrowserPolicy.destination(target) {
        case .website:
            // Background resources may finish, but new top-level navigation only
            // happens while the user is interacting with the browser.
            if navigationAction.targetFrame?.isMainFrame != false && !active { decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        case .wallet:
            decisionHandler(.cancel)
            guard trustedSource(navigationAction, in: webView),
                  let host = OathBrowserPolicy.connectionAuthority(webView.url),
                  let route = OathWalletLink.parse(target), route.isWalletConnect else { return }
            walletLink?(target, host)
        case .external:
            decisionHandler(.cancel)
            guard trustedSource(navigationAction, in: webView), navigationAction.navigationType == .linkActivated,
                  externalURL == nil else { return }
            externalURL = target
        case .blocked:
            decisionHandler(.cancel)
            if active, navigationAction.targetFrame?.isMainFrame != false { issue = .browserInvalidAddress }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        // Downloads never execute or silently leave files in the wallet container.
        guard webView === self.webView else { decisionHandler(.cancel); return }
        if navigationResponse.canShowMIMEType { decisionHandler(.allow) }
        else { decisionHandler(.cancel); if navigationResponse.isForMainFrame { issue = .browserLoadFailed } }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard active, webView === self.webView, navigationAction.targetFrame == nil,
              let target = navigationAction.request.url else { return nil }
        // A user-requested web window stays in the same browser and passes the
        // normal navigation policy again. No native API is exposed to the page.
        if case .website = OathBrowserPolicy.destination(target) { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        currentNavigation = navigation
        operation = UUID(); reportedFailure = false; issue = nil
        resolveDialog(accept: false); update(from: webView)
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { update(from: webView) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation, from: webView) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error, navigation: navigation, from: webView) }

    private func failed(_ error: Error, navigation: WKNavigation?, from view: WKWebView) {
        guard view === webView, navigation === currentNavigation else { return }
        let value = error as NSError
        // User stops, superseded loads and policy cancellation are expected.
        guard !(value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled) else { return }
        if !reportedFailure {
            reportedFailure = true
            // WebKit NSError userInfo/descriptions can contain whole page URLs,
            // query tokens and page text. Preserve domain/code, never these fields.
            OathDiagnostics.$operationID.withValue(operation) {
                OathDiagnostics.record(NSError(domain: value.domain == NSURLErrorDomain ? NSURLErrorDomain : WKError.errorDomain,
                    code: value.code, userInfo: nil), component: "browser", operation: "navigate")
            }
        }
        loading = false; issue = .browserLoadFailed
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        OathDiagnostics.record(DiagnosticFailure("web_content_process_terminated"), component: "browser", operation: "render")
        loading = false; issue = .browserLoadFailed; resolveDialog(accept: false)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // The wallet's QR camera permission is never inherited by a website.
        decisionHandler(.deny)
    }
    func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    private func presentDialog(_ kind: Dialog.Kind, message: String, defaultText: String = "", frame: WKFrameInfo, view: WKWebView,
                               completion: @escaping (Bool, String) -> Void) {
        guard dialog == nil, trustedFrame(frame, in: view) else {
            completion(false, ""); return
        }
        dialogCompletion = completion; dialogText = String(defaultText.prefix(2_048))
        dialog = Dialog(host: url?.host ?? "", message: String(message.prefix(2_048)), kind: kind)
    }
    func resolveDialog(accept: Bool) {
        let callback = dialogCompletion, text = dialogText
        dialogCompletion = nil; dialog = nil; dialogText = ""
        callback?(accept, text)
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        presentDialog(.alert, message: message, frame: frame, view: webView) { _, _ in completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        presentDialog(.confirm, message: message, frame: frame, view: webView) { accept, _ in completionHandler(accept) }
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        presentDialog(.prompt, message: prompt, defaultText: defaultText ?? "", frame: frame, view: webView) { accept, text in completionHandler(accept ? text : nil) }
    }
}
