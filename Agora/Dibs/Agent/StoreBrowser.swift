import UIKit
import WebKit

/// An offscreen WKWebView the price worker drives. Ported from Agora/Browser/BrowserSession.swift
/// without the chat, presentation, screenshot and human-takeover pieces: nobody watches this view.
///
/// The view lives in a hidden-behind window (390x844, below the app's window level) so pages lay
/// out and render like on a phone. It uses the default website data store so cookies persist.
@MainActor
final class StoreBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    let world = WKContentWorld.world(name: "DibsBrowserTools")
    var policy: DibsBrowserPolicy
    private(set) var isOpen = false
    private(set) var privateMode = false
    private(set) var epoch: UInt64 = 0
    private(set) var documentEpoch: UInt64 = 0
    private var pending: [UUID: (Result<String, Error>) -> Void] = [:]
    private var navigationFailure: String?
    private var activeNavigation: WKNavigation?
    private var hostWindow: UIWindow?
    private var rulesAttached = false
    /// HTTP status of the last main-frame response (429 or 403 means QFC is rate-limiting).
    private(set) var lastStatus: Int?

    /// Images, fonts and media are not needed to read prices; skipping them renders search pages faster.
    static let lightRules = #"[{"trigger":{"url-filter":".*","resource-type":["image","font","media"]},"action":{"type":"block"}}]"#
    private static var compiledRules: WKContentRuleList?

    private func attachRules() async {
        guard !rulesAttached else { return }
        rulesAttached = true
        if Self.compiledRules == nil {
            Self.compiledRules = try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "DibsLightPages", encodedContentRuleList: Self.lightRules)
        }
        if let rules = Self.compiledRules { webView.configuration.userContentController.add(rules) }
    }

    static let viewport = CGRect(x: 0, y: 0, width: 390, height: 844)

    init(policy: DibsBrowserPolicy = DibsBrowserPolicy()) {
        self.policy = policy
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        if let url = Bundle.main.url(forResource: "DibsBrowserScripts", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        } else {
            PriceLog.event("price browser scripts missing from bundle")
        }
        webView = WKWebView(frame: Self.viewport, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Puts the web view in a window behind the app's own window so WebKit renders it.
    private func attach() {
        guard hostWindow == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        let window = UIWindow(windowScene: scene)
        window.frame = Self.viewport
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.isUserInteractionEnabled = false
        let host = UIViewController()
        host.view.frame = Self.viewport
        webView.frame = Self.viewport
        host.view.addSubview(webView)
        window.rootViewController = host
        window.isHidden = false
        hostWindow = window
    }

    func close() {
        epoch &+= 1
        webView.stopLoading()
        settleAll(DibsBrowserError("stale_session"))
        webView.loadHTMLString("", baseURL: nil)
        isOpen = false
        privateMode = false
    }

    private func settleAll(_ error: Error) {
        let completions = Array(pending.values)
        pending.removeAll()
        completions.forEach { $0(.failure(error)) }
    }

    private func finish(_ id: UUID, _ result: Result<String, Error>) {
        guard let completion = pending.removeValue(forKey: id) else { return }
        completion(result)
    }

    func bridge(_ request: [String: Any], mutation: Bool = false) async throws -> [String: Any] {
        guard isOpen else { throw DibsBrowserError("no_browser") }
        let capturedEpoch = epoch, capturedDocument = documentEpoch
        let raw: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let id = UUID()
            pending[id] = { continuation.resume(with: $0) }
            webView.callAsyncJavaScript("return JSON.stringify(globalThis.appBrowser.dispatch(request));",
                                        arguments: ["request": request], in: nil, in: world) { [weak self] result in
                switch result {
                case .success(let value):
                    if let s = value as? String { self?.finish(id, .success(s)) }
                    else { self?.finish(id, .failure(DibsBrowserError("observation_unavailable"))) }
                case .failure(let error):
                    self?.finish(id, .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.pending[id] != nil else { return }
                self.finish(id, .failure(DibsBrowserError(mutation ? "outcome_unknown" : "timeout")))
            }
        }
        guard epoch == capturedEpoch else { throw DibsBrowserError("stale_session") }
        guard mutation || documentEpoch == capturedDocument else { throw DibsBrowserError("stale_reference") }
        guard let data = raw.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DibsBrowserError("observation_unavailable")
        }
        if let error = result["error"] as? String {
            if error.contains("user_action_required") { privateMode = true }
            throw DibsBrowserError(error)
        }
        return result
    }

    /// Runs an async script body (which returns a JSON string) in the tools content world.
    /// Navigation away from the page fails it; `timeout` bounds the wait.
    func evaluate(_ body: String, arguments: [String: Any], timeout: Duration) async throws -> [String: Any] {
        guard isOpen else { throw DibsBrowserError("no_browser") }
        let raw: String = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let id = UUID()
            pending[id] = { continuation.resume(with: $0) }
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: world) { [weak self] result in
                switch result {
                case .success(let value):
                    if let s = value as? String { self?.finish(id, .success(s)) }
                    else { self?.finish(id, .failure(DibsBrowserError("script_result"))) }
                case .failure(let error):
                    let info = (error as NSError).userInfo
                    if let message = info["WKJavaScriptExceptionMessage"] as? String {
                        let line = info["WKJavaScriptExceptionLineNumber"].map { " line \($0)" } ?? ""
                        self?.finish(id, .failure(DibsBrowserError("script_exception", message + line)))
                    } else {
                        self?.finish(id, .failure(error))
                    }
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finish(id, .failure(DibsBrowserError("timeout")))
            }
        }
        guard let data = raw.data(using: .utf8), let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DibsBrowserError("script_result")
        }
        return result
    }

    func observe() async throws -> [String: Any] {
        guard !privateMode else { throw DibsBrowserError("user_action_required", "Private page. Open a different page.") }
        var result = try await bridge(["operation": "observe"])
        result["url"] = DibsBrowserPolicy.safeURL(webView.url)
        if let lastStatus { result["httpStatus"] = lastStatus }
        return result
    }

    /// Loads `url` and returns as soon as the new document commits (or loading ends), with a
    /// first observation. The page keeps rendering; callers poll `observe` for the content.
    func open(_ url: URL) async throws -> [String: Any] {
        try policy.validate(url)
        attach()
        await attachRules()
        isOpen = true
        privateMode = false
        navigationFailure = nil
        let savedEpoch = epoch, startDocument = documentEpoch
        webView.load(URLRequest(url: url))
        let deadline = ContinuousClock.now + .seconds(15)
        repeat {
            try await Task.sleep(for: .milliseconds(100))
            try Task.checkCancellation()
            guard epoch == savedEpoch else { throw DibsBrowserError("stale_session") }
            if let navigationFailure { throw DibsBrowserError("navigation_failed", navigationFailure) }
            if documentEpoch != startDocument || !webView.isLoading {
                do { return try await observe() } catch let error as DibsBrowserError where !error.code.contains("user_action_required") {
                    // Committed but not readable yet (redirect or empty body): report it as loading.
                    return ["url": DibsBrowserPolicy.safeURL(webView.url), "loading": true, "text": "",
                            "note": "Page is loading. Call browser_wait_for or browser_observe."]
                }
            }
        } while ContinuousClock.now < deadline
        webView.stopLoading(); throw DibsBrowserError("timeout")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        let mainFrame = action.targetFrame?.isMainFrame ?? true
        if url.absoluteString == "about:blank" { decisionHandler(mainFrame && isOpen ? .cancel : .allow); return }
        guard mainFrame else { decisionHandler(.allow); return }
        do { try policy.validate(url) } catch {
            PriceLog.event("price browser blocked \(DibsBrowserPolicy.safeURL(url))")
            navigationFailure = error.localizedDescription
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame { lastStatus = (response.response as? HTTPURLResponse)?.statusCode }
        if response.isForMainFrame && !response.canShowMIMEType {
            navigationFailure = "Downloads are not supported."
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        activeNavigation = navigation
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        documentEpoch &+= 1
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        navigationFailure = error.localizedDescription
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === activeNavigation else { return }
        // A redirect we cancelled already recorded why.
        if navigationFailure == nil { navigationFailure = error.localizedDescription }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        PriceLog.event("price browser renderer terminated")
        epoch &+= 1
        settleAll(DibsBrowserError("web_process_terminated"))
        isOpen = false
    }

    // MARK: WKUIDelegate (no popups, no dialogs)

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, (try? policy.validate(url)) != nil { webView.load(URLRequest(url: url)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        completionHandler(nil)
    }
}
