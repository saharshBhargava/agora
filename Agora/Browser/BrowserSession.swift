import SwiftUI
import WebKit

@MainActor
final class BrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var state = BrowserState()
    let webView: WKWebView
    let world = WKContentWorld.world(name: "AgoraBrowserTools")
    var policy: BrowserPolicy
    var onHumanInteraction: (() -> Void)?
    private(set) var epoch: UInt64 = 0
    private(set) var lease: UInt64 = 0
    private(set) var documentEpoch: UInt64 = 0
    private(set) var lastObservation: [String: Any] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var pending: [UUID: (Result<Any?, Error>) -> Void] = [:]
    private var navigationFailure: String?
    private var activeNavigation: WKNavigation?

    init(policy: BrowserPolicy) {
        self.policy = policy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let source = try! String(contentsOf: Bundle.main.url(forResource: "BrowserScripts", withExtension: "js")!, encoding: .utf8)
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakScriptHandler(self), contentWorld: world, name: "humanActivity")
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observations = [webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.publish() } },
                        webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.publish() } },
                        webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.publish() } }]
    }
    private func publish() {
        state.title = webView.title ?? "Browser"; state.url = webView.url
        state.progress = webView.estimatedProgress
        state.canGoBack = webView.canGoBack; state.canGoForward = webView.canGoForward
    }
    /// Presentation never revokes the agent lease or transfers page ownership.
    func setPresentationFromUser(_ presentation: BrowserPresentation) {
        state.presentation = presentation
        switch presentation {
        case .expanded: AppLog.event(.browser, "presentation.expanded")
        case .thumbnail: AppLog.event(.browser, "presentation.thumbnail")
        case .hidden: AppLog.event(.browser, "presentation.hidden")
        }
    }
    func revoke() { lease &+= 1 }
    func humanInteraction() {
        AppLog.event(.browser, "human.interaction")
        revoke(); onHumanInteraction?()
        state.status = "You have control · Resume in chat when ready"
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.frameInfo.isMainFrame { humanInteraction() }
    }
    func check(epoch expected: UInt64, lease expectedLease: UInt64) throws {
        try Task.checkCancellation()
        guard epoch == expected, lease == expectedLease else { throw BrowserError("cancelled", "Browser ownership changed.") }
    }
    func close() {
        AppLog.event(.browser, "session.closed", count: pending.count)
        epoch &+= 1; revoke(); webView.stopLoading()
        settleAll(BrowserError("stale_session"))
        webView.loadHTMLString("", baseURL: nil)
        state = BrowserState()
    }
    func clearWebsiteData() async {
        AppLog.event(.browser, "website_data.clear")
        close()
        await webView.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
    private func settleAll(_ error: Error) {
        let completions = Array(pending.values); pending.removeAll()
        completions.forEach { $0(.failure(error)) }
    }
    private func finish(_ id: UUID, _ result: Result<Any?, Error>) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        if case .failure(let error) = result { AppLog.failure(.browser, "native_operation.failed", error: error) }
        completion(result)
    }
    func bridge(_ request: [String: Any], mutation: Bool = false) async throws -> [String: Any] {
        guard state.isOpen else { throw BrowserError("no_browser") }
        let capturedEpoch = epoch, capturedDocument = documentEpoch
        let raw: Any? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let id = UUID()
            pending[id] = { continuation.resume(with: $0) }
            webView.callAsyncJavaScript("return JSON.stringify(globalThis.appBrowser.dispatch(request));", arguments: ["request": request], in: nil, in: world) { [weak self] result in
                self?.finish(id, result.map { Optional($0) })
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.pending[id] != nil else { return }
                self.revoke()
                if mutation { self.state.status = "Outcome unknown. Inspect the page before resuming." }
                self.finish(id, .failure(BrowserError(mutation ? "outcome_unknown" : "timeout")))
            }
        }
        guard epoch == capturedEpoch else { throw BrowserError("stale_session") }
        guard mutation || documentEpoch == capturedDocument else { throw BrowserError("stale_reference") }
        guard let string = raw as? String, let data = string.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BrowserError("observation_unavailable") }
        if let error = result["error"] as? String {
            if error.contains("user_action_required") { state.privateMode = true }
            throw BrowserError(error)
        }
        return result
    }
    func observe() async throws -> [String: Any] {
        guard !state.privateMode else { throw BrowserError("user_action_required", "Private mode is on. Finish directly, then Resume.") }
        var result = try await bridge(["operation": "observe"])
        result["url"] = BrowserPolicy.safeURL(webView.url)
        lastObservation = result
        return result
    }
    func resume() async throws {
        AppLog.event(.browser, "session.resume")
        if state.isOpen {
            let result = try await bridge(["operation": "privacy"])
            guard result["private"] as? Bool != true else { throw BrowserError("user_action_required", "Leave the login/payment page before resuming.") }
            _ = try await bridge(["operation": "invalidate"])
        }
        state.privateMode = false; revoke(); state.status = "Ready"
    }
    func open(_ url: URL) async throws -> [String: Any] {
        try policy.validate(url)
        if !state.isOpen { state.isOpen = true; state.presentation = .thumbnail }
        navigationFailure = nil
        webView.load(URLRequest(url: url))
        let savedEpoch = epoch, savedLease = lease
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            try await Task.sleep(for: .milliseconds(200))
            try check(epoch: savedEpoch, lease: savedLease)
            if let navigationFailure { throw BrowserError("navigation_failed", navigationFailure) }
            if !webView.isLoading { return try await observe() }
        } while ContinuousClock.now < deadline
        webView.stopLoading(); throw BrowserError("timeout")
    }
    func screenshot() async throws -> [String: Any] {
        let observation = try await observe()
        guard state.presentation != .hidden, webView.bounds.width > 0 else { throw BrowserError("observation_unavailable", "Show Browser before taking a screenshot.") }
        let savedEpoch = epoch, savedLease = lease
        let configuration = WKSnapshotConfiguration(); configuration.snapshotWidth = NSNumber(value: 720 / max(webView.traitCollection.displayScale, 1))
        let document = documentEpoch
        let captured: Any? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
            let id = UUID()
            pending[id] = { continuation.resume(with: $0) }
            webView.takeSnapshot(with: configuration) { [weak self] image, error in
                if let error { self?.finish(id, .failure(error)) }
                else if let image { self?.finish(id, .success(image)) }
                else { self?.finish(id, .failure(BrowserError("observation_unavailable"))) }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finish(id, .failure(BrowserError("timeout")))
            }
        }
        guard let image = captured as? UIImage, document == documentEpoch else { throw BrowserError("stale_reference") }
        try check(epoch: savedEpoch, lease: savedLease)
        _ = try await observe() // Recheck private-page policy after asynchronous capture.
        guard let data = image.jpegData(compressionQuality: 0.6), data.count < 2_000_000 else { throw BrowserError("observation_unavailable") }
        return ["image": data.base64EncodedString(), "mimeType": "image/jpeg", "screenshotId": UUID().uuidString,
                "documentId": observation["documentId"] ?? "", "viewport": observation["viewport"] ?? [:],
                "pixelWidth": image.cgImage?.width ?? 0, "pixelHeight": image.cgImage?.height ?? 0]
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(state.isOpen ? .cancel : .allow); return }
        do { try policy.validate(url) } catch {
            AppLog.failure(.browser, "navigation.blocked", error: error)
            navigationFailure = error.localizedDescription; state.status = error.localizedDescription
            decisionHandler(.cancel); return
        }
        if action.navigationType == .linkActivated && !state.busy { humanInteraction() }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !response.canShowMIMEType { navigationFailure = "Downloads are not supported; use Safari."; decisionHandler(.cancel) }
        else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { AppLog.event(.browser, "navigation.started"); activeNavigation = navigation; publish() }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { guard navigation === activeNavigation else { return }; documentEpoch &+= 1; lastObservation = [:]; AppLog.event(.browser, "navigation.committed"); publish() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { guard navigation === activeNavigation else { return }; AppLog.event(.browser, "navigation.finished"); publish() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { guard navigation === activeNavigation else { return }; AppLog.failure(.browser, "navigation.failed", error: error); navigationFailure = error.localizedDescription; publish() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { guard navigation === activeNavigation else { return }; AppLog.failure(.browser, "navigation.failed", error: error); navigationFailure = error.localizedDescription; publish() }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        AppLog.failure(.browser, "renderer.terminated", error: BrowserError("web_process_terminated"))
        epoch &+= 1; humanInteraction(); settleAll(BrowserError("web_process_terminated"))
        state.status = "Browser process stopped. Reload the page to recover."
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, (try? policy.validate(url)) != nil { webView.load(URLRequest(url: url)) }
        else { state.status = "Popup destination unsupported. Use a public HTTPS website without embedded credentials." }
        return nil
    }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        humanInteraction(); state.status = "Website alert dismissed. Continue directly in the browser."; completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        humanInteraction(); state.status = "Website confirmation declined. Complete this step in Safari."; completionHandler(false)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        humanInteraction(); state.status = "Website prompt unsupported. Complete this step in Safari."; completionHandler(nil)
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
