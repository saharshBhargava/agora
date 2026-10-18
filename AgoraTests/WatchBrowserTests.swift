import XCTest
import WebKit
import SwiftUI
@testable import Agora

@MainActor
private final class BrowserWatchGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var token = "watch-token"
    var account: GoogleCalendarAccount? = .init(id: "browser-watch-user", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { token }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class BrowserWatchHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class RetailerFixtureBrowser: BrowserSession {
    var html = "<main><h1>Xbox Series X</h1><span class='price'>USD $499.99</span></main>"
    var opened: [URL] = []
    var finalURLOverride: URL?
    var onOpen: (() async -> Void)?
    override func open(_ url: URL) async throws -> [String: Any] {
        try policy.validate(url); opened.append(url)
        await onOpen?()
        try Task.checkCancellation()
        let epoch = epoch, lease = lease, previousDocument = documentEpoch
        webView.loadHTMLString(html, baseURL: finalURLOverride ?? url)
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            try await Task.sleep(for: .milliseconds(50))
            try check(epoch: epoch, lease: lease)
            if documentEpoch != previousDocument,
               (try? await webView.evaluateJavaScript("document.readyState")) as? String == "complete",
               (try? await webView.evaluateJavaScript("document.querySelector('main') !== null")) as? Bool == true {
                return try await observe()
            }
        } while ContinuousClock.now < deadline
        throw BrowserError("timeout")
    }
}

@MainActor
final class WatchBrowserTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var inventory: InventoryStore!
    private var store: WatchStore!
    private var browser: RetailerFixtureBrowser!
    private var api: AgoraClient!
    private var http: URLSession!
    private var runner: WatchBrowserRunner!
    private var row: [String: Any] = [:]
    private var posted: [[String: Any]] = []
    private var claims = 0
    private let household = UUID(), watchID = UUID(), runID = UUID()
    private var allowStart = true
    func testBrowserTriesTheFifthDiscoveredRetailerAfterBlockedPages() async throws {
        let urls = (1...5).map { "https://shop\($0).example/products/console" }
        row["browser_fallback"] = ["run_id": runID.uuidString, "status": "pending", "urls": urls]
        browser.onOpen = { [unowned self] in
            browser.html = browser.opened.count < 5
                ? "<title>Access denied</title><main>Blocked</main>"
                : "<main><h1>Xbox Series X</h1><span class='price'>USD $499.99</span></main>"
        }
        await store.refresh(poll: false)
        await runner.check(store.watches[0])
        XCTAssertEqual(browser.opened.map(\.absoluteString), urls)
        let pages = try XCTUnwrap(posted.first?["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?["source_url"] as? String, urls.last)
    }
    override func setUp() async throws {
        calendar = CalendarConnection(authorization: BrowserWatchGoogle()); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BrowserWatchHTTP.self]
        http = URLSession(configuration: config)
        api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://api.example.com"), http: http)
        inventory = InventoryStore(api: api, calendar: calendar)
        store = WatchStore(api: api, inventory: inventory)
        browser = RetailerFixtureBrowser(policy: BrowserPolicy())
        row = ["id": watchID.uuidString, "wishlist_item_id": UUID().uuidString, "household_id": household.uuidString,
               "title": "Xbox Series X", "status": "active", "criteria_version": 1,
               "confirmed_at": "2026-10-18T00:00:00Z", "last_result": "failed", "search_available": true,
               "matches": [], "prices": [], "runs": [],
               "browser_fallback": ["run_id": runID.uuidString, "status": "pending", "urls": ["https://retailer.example/console"]],
               "criteria": ["query": "Xbox Series X", "required_terms": [], "excluded_terms": [], "quantity": 1,
                            "currency": "USD", "fulfillment": "delivery", "location": "US", "condition": "new",
                            "allow_membership": false, "allowed_domains": []]]
        BrowserWatchHTTP.handler = { [unowned self] request in
            switch request.url!.path {
            case "/v1/me": return (200, ["households": [["id": household.uuidString, "name": "Home", "locations": []]]])
            case "/v1/watches": return (200, ["watches": [row], "search_available": true])
            case let path where path.hasSuffix("/browser-claim"):
                claims += 1
                return (200, ["run_id": runID.uuidString, "token": UUID().uuidString,
                              "expires_at": ISO8601DateFormatter().string(from: Date().addingTimeInterval(120)),
                              "urls": (row["browser_fallback"] as! [String: Any])["urls"]!])
            case let path where path.hasSuffix("/browser-result"):
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
                }
                posted.append((try! JSONSerialization.jsonObject(with: data)) as! [String: Any])
                return (200, ["status": "completed", "price_count": 1])
            default: return (200, [:])
            }
        }
        await inventory.refresh(); await store.refresh(poll: false)
        runner = WatchBrowserRunner(api: api, browser: browser, store: store) { [unowned self] in allowStart }
    }
    override func tearDown() async throws {
        browser.close(); await calendar.signOut(); http.invalidateAndCancel()
        runner = nil; store = nil; inventory = nil; api = nil; browser = nil; calendar = nil
        BrowserWatchHTTP.handler = nil
    }
    func testHiddenBackupUsesActualSharedWebViewAndPostsRenderedPrice() async throws {
        let identity = ObjectIdentifier(browser.webView)
        browser.onOpen = { [unowned self] in
            XCTAssertEqual(browser.state.presentation, .hidden)
            XCTAssertTrue(browser.state.busy)
        }
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(ObjectIdentifier(browser.webView), identity)
        XCTAssertEqual(claims, 1); XCTAssertEqual(posted.count, 1)
        let pages = try XCTUnwrap(posted.first?["pages"] as? [[String: Any]])
        let products = try XCTUnwrap(pages.first?["products"] as? [[String: Any]])
        XCTAssertEqual(products.first?["name"] as? String, "Xbox Series X")
        let offer = try XCTUnwrap(products.first?["offers"] as? [String: Any])
        XCTAssertEqual(offer["price"] as? String, "499.99")
        XCTAssertFalse(browser.state.isOpen); XCTAssertFalse(browser.state.busy)
    }
    func testExistingChatPageIsNotNavigatedOrClaimed() async throws {
        browser.state.isOpen = true; browser.state.presentation = .hidden
        browser.webView.loadHTMLString("<input id='saved' value='keep me'>", baseURL: URL(string: "https://chat.example"))
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? await browser.webView.evaluateJavaScript("document.getElementById('saved') !== null")) as? Bool != true,
              ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(claims, 0); XCTAssertTrue(browser.opened.isEmpty)
        let value = try await browser.webView.evaluateJavaScript("document.getElementById('saved').value")
        XCTAssertEqual(value as? String, "keep me")
        XCTAssertTrue(store.browserFallbackStatus[watchID]?.contains("waiting") == true)
    }
    func testChatWorkAndDemoDoNotStartBrowserBackup() async throws {
        allowStart = false
        await runner.check(try XCTUnwrap(store.watches.first))
        allowStart = true; row["simulation_disclosure"] = "Demo prices are simulated."
        await store.refresh(poll: false); await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(claims, 0); XCTAssertTrue(browser.opened.isEmpty)
    }
    func testHumanTakeoverDiscardsEvidenceAndLeavesBrowserAvailable() async throws {
        browser.onOpen = { [unowned self] in browser.humanInteraction() }
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(claims, 1); XCTAssertTrue(posted.isEmpty)
        XCTAssertTrue(browser.state.isOpen); XCTAssertNil(browser.priceResearchID)
    }
    func testAccountChangeDiscardsEvidence() async throws {
        browser.onOpen = { [unowned self] in await calendar.signOut() }
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertTrue(posted.isEmpty); XCTAssertTrue(store.watches.isEmpty)
        XCTAssertFalse(browser.state.isOpen)
    }
    func testCancellationDoesNotSubmitPartialOrStaleEvidence() async throws {
        browser.onOpen = { try? await Task.sleep(for: .seconds(2)) }
        let watch = try XCTUnwrap(store.watches.first)
        let task = Task { await runner.check(watch) }
        try await Task.sleep(for: .milliseconds(150)); task.cancel(); await task.value
        XCTAssertTrue(posted.isEmpty); XCTAssertFalse(browser.state.isOpen)
    }
    func testPrivatePageDoesNotUploadFormsOrProductEvidence() async throws {
        browser.html = "<main><h1>Xbox Series X</h1><input type='password' value='never-upload'><span class='price'>$1.00</span></main>"
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(posted.first?["outcome"] as? String, "interaction_required")
        XCTAssertEqual((posted.first?["pages"] as? [Any])?.count, 0)
    }
    func testAmbiguousPricesDoNotBecomeAProductPrice() async throws {
        browser.html = "<main><h1>PS5 consoles</h1><span class='price'>USD $499.99</span><span class='price'>USD $699.99</span></main>"
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(posted.first?["outcome"] as? String, "unavailable")
        XCTAssertEqual((posted.first?["pages"] as? [Any])?.count, 0)
    }
    func testJavaScriptRenderedStructuredProductIsReadAfterPageLoad() async throws {
        browser.html = """
        <main><h1>Xbox Series X</h1></main><input value='never-upload'><script>
        setTimeout(() => { const s=document.createElement('script'); s.type='application/ld+json';
        s.textContent=JSON.stringify({'@type':'Product',name:'Xbox Series X',offers:{'@type':'Offer',price:'499.99',priceCurrency:'USD'}}); document.head.appendChild(s); }, 300);
        </script>
        """
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual((posted.first?["pages"] as? [Any])?.count, 1)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: posted), encoding: .utf8)!
        XCTAssertFalse(serialized.contains("never-upload"))
        XCTAssertTrue(serialized.contains("499.99"))
    }
    func testGenericSplitPriceOnUSStorefront() async throws {
        row["browser_fallback"] = ["run_id": runID.uuidString, "status": "pending", "urls": ["https://retailer.example/en-us/products/ceramic-mug"]]
        browser.html = """
        <html lang="en-US"><main><h1>Ceramic mug</h1><div class="price-text"><sup>$</sup><br><span>24</span><br><sup>95</sup></div></main></html>
        """
        await store.refresh(poll: false); await runner.check(try XCTUnwrap(store.watches.first))
        let pages = try XCTUnwrap(posted.first?["pages"] as? [[String: Any]])
        let products = try XCTUnwrap(pages.first?["products"] as? [[String: Any]])
        XCTAssertEqual(products.first?["name"] as? String, "Ceramic mug")
        XCTAssertEqual((products.first?["offers"] as? [String: Any])?["price"] as? String, "24.95")
    }
    func testUnspecifiedDollarCurrencyStaysUnresolved() async throws {
        browser.html = "<main><h1>Ceramic mug</h1><span class='price'>$24.95</span></main>"
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(posted.first?["outcome"] as? String, "unavailable")
    }
    func testBlockedRetailerDoesNotPreventNextRetailer() async throws {
        row["browser_fallback"] = ["run_id": runID.uuidString, "status": "pending", "urls": ["https://blocked.example/p/mug", "https://retailer.example/p/mug"]]
        browser.onOpen = { [unowned self] in
            browser.html = browser.opened.count == 1 ? "<title>Access denied</title><main>Blocked</main>" : "<main><h1>Ceramic mug</h1><span class='price'>USD $24.95</span></main>"
        }
        await store.refresh(poll: false); await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(browser.opened.count, 2)
        let pages = try XCTUnwrap(posted.first?["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?["source_url"] as? String, "https://retailer.example/p/mug")
    }
    func testNewChatCancelsBrowserBackupWithoutUploadingEvidence() async throws {
        browser.onOpen = { [unowned self] in browser.cancelPriceResearch() }
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertTrue(posted.isEmpty); XCTAssertFalse(browser.state.isOpen)
        XCTAssertNil(browser.priceResearchID)
    }
    func testCrossHostRedirectDoesNotDiscardAnotherRetailersEvidence() async throws {
        row["browser_fallback"] = ["run_id": runID.uuidString, "status": "pending", "urls": ["https://redirect.example/p/mug", "https://retailer.example/p/mug"]]
        browser.onOpen = { [unowned self] in
            browser.finalURLOverride = browser.opened.count == 1 ? URL(string: "https://unapproved.example/p/mug") : nil
        }
        await store.refresh(poll: false); await runner.check(try XCTUnwrap(store.watches.first))
        let pages = try XCTUnwrap(posted.first?["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages.first?["source_url"] as? String, "https://retailer.example/p/mug")
    }
    func testFinishedServerWorkClearsStaleLocalProgress() async throws {
        store.setBrowserStatus("Trying the browser backup…", for: watchID)
        row["browser_fallback"] = ["run_id": runID.uuidString, "status": "completed", "urls": []]
        await store.refresh(poll: false)
        XCTAssertNil(store.browserFallbackStatus[watchID])
        XCTAssertFalse(store.hasPendingWork)
        await runner.check(try XCTUnwrap(store.watches.first))
        XCTAssertEqual(claims, 0)
    }
}

@MainActor
final class WatchBrowserLiveTests: XCTestCase {
    func testSaveServerFailureSharedBrowserAndPersistedPriceAgainstRealAPI() async throws {
        guard let origin = ProcessInfo.processInfo.environment["AGORA_WATCH_BROWSER_LIVE_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("Run with the disposable ios_watch_browser_server and AGORA_WATCH_BROWSER_LIVE_URL.")
        }
        var request = URLRequest(url: origin.appendingPathComponent("v1/dev/login"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["handle": "browserlive" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(10)])
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let login = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let authorization = BrowserWatchGoogle(); authorization.token = try XCTUnwrap(login["access_token"] as? String)
        let calendar = CalendarConnection(authorization: authorization); await calendar.refresh()
        let api = AgoraClient(calendar: calendar, baseURL: origin)
        let inventory = InventoryStore(api: api, calendar: calendar); await inventory.refresh()
        let store = WatchStore(api: api, inventory: inventory)
        _ = try await api.request("v1/wishlist", method: "POST", body: ["title": "Xbox Series X", "target_price_cents": 55000])
        let deadline = ContinuousClock.now + .seconds(20)
        repeat {
            await store.refresh(poll: false)
            if store.watches.first?.browserFallback?.status == "pending" { break }
            try await Task.sleep(for: .milliseconds(200))
        } while ContinuousClock.now < deadline
        let watch = try XCTUnwrap(store.watches.first)
        XCTAssertEqual(watch.browserFallback?.status, "pending")
        XCTAssertFalse(watch.isChecking)
        let browser = RetailerFixtureBrowser(policy: BrowserPolicy())
        browser.html = """
        <main><h1>Xbox Series X</h1></main><script>
        setTimeout(() => { document.querySelector('main').insertAdjacentHTML('beforeend','<span class="price">USD $499.99</span>'); }, 250);
        </script>
        """
        let sharedIdentity = ObjectIdentifier(browser.webView)
        let runner = WatchBrowserRunner(api: api, browser: browser, store: store) { calendar.connected }
        await runner.check(watch)
        XCTAssertEqual(ObjectIdentifier(browser.webView), sharedIdentity)
        XCTAssertFalse(browser.state.isOpen)
        await store.refresh(poll: false)
        let completed = try XCTUnwrap(store.watches.first)
        XCTAssertEqual(completed.browserFallback?.status, "completed")
        XCTAssertEqual(completed.currentPrices.first?.unitPriceCents, 49999)
        XCTAssertEqual(completed.currentPrices.first?.comparison(target: 55000), "$50.01 below your target")
        XCTAssertEqual(completed.currentPrices.first?.provenance, "device_browser")
        XCTAssertTrue(completed.matches.isEmpty)
        let restored = WatchStore(api: api, inventory: inventory); await restored.refresh(poll: false)
        XCTAssertEqual(restored.watches.first?.currentPrices.first?.unitPriceCents, 49999)
        await restored.refreshInbox(); XCTAssertTrue(restored.notifications.isEmpty)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        let controller = UIHostingController(rootView: NavigationStack { WatchDetailView(store: restored, watchID: completed.id) })
        window.rootViewController = controller; window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(500)); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image); attachment.name = "watch-browser-price-comparison"
        attachment.lifetime = .keepAlways; add(attachment)
        try image.pngData()?.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("watch-browser-price-comparison.png"))
        browser.close(); await calendar.signOut()
    }
}

@MainActor
final class WatchRetailerProbeTests: XCTestCase {
    func testLiveConsolePagesWithTheSharedBrowser() async throws {
        guard ProcessInfo.processInfo.environment["AGORA_WATCH_BROWSER_RETAILERS"] == "1" else {
            throw XCTSkip("Opt-in live retailer diagnostic.")
        }
        let browser = BrowserSession(policy: BrowserPolicy())
        let owner = try browser.beginPriceResearch(), epoch = browser.epoch, lease = browser.lease
        defer { browser.endPriceResearch(owner, epoch: epoch, lease: lease) }
        try await browser.preparePriceResearch(owner)
        let supplied = ProcessInfo.processInfo.environment["AGORA_WATCH_BROWSER_PROBE_URLS"]
        let sources = supplied?.components(separatedBy: "\n").filter { !$0.isEmpty } ?? [
            "https://www.microsoft.com/en-us/d/xbox-series-x/8wj714n3rbtl",
            "https://direct.playstation.com/en-us/buy-consoles/playstation5-digital-edition-console-825-gb"]
        for source in sources {
            let started = Date()
            do {
                _ = try await browser.open(URL(string: source)!)
                var products: [[String: Any]] = []
                let deadline = ContinuousClock.now + .seconds(8)
                repeat {
                    products = (try await browser.priceEvidence())["products"] as? [[String: Any]] ?? []
                    if !products.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(300))
                } while ContinuousClock.now < deadline
                if products.isEmpty {
                    let diagnostic = try? await browser.webView.evaluateJavaScript("JSON.stringify({title:document.title,lang:document.documentElement.lang,candidates:Array.from(document.querySelectorAll('[class*=price i],[data-testid*=price i],[itemprop=price]')).slice(0,20).map(e=>({tag:e.tagName,cls:e.className,text:e.innerText?.slice(0,180),content:e.getAttribute('content')}))})")
                    print("RETAILER_DOM " + (diagnostic as? String ?? "unavailable"))
                }
                let summary = try JSONSerialization.data(withJSONObject: ["source": source, "seconds": Date().timeIntervalSince(started), "products": products])
                print("RETAILER_PROBE " + String(data: summary, encoding: .utf8)!)
            } catch {
                print("RETAILER_PROBE source=\(source) seconds=\(Date().timeIntervalSince(started)) error=\((error as? BrowserError)?.code ?? "network_error")")
                browser.state.privateMode = false
            }
        }
    }
}
