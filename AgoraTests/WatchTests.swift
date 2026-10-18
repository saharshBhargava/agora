import XCTest
import SwiftUI
@testable import Agora

@MainActor
private final class WatchGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "watch-alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { "watch-token" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class WatchHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any?))!
    static var delay: TimeInterval = 0
    private var stopped = false
    private let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, value) = Self.handler(request)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [self] in
            lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            if let value { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private func watchBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor
final class WatchTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var inventory: InventoryStore!
    private var store: WatchStore!
    private var session: URLSession!
    private let household = UUID(), itemID = UUID(), watchID = UUID(), notificationID = UUID()
    private var row: [String: Any] {
        ["id": watchID.uuidString, "wishlist_item_id": itemID.uuidString, "household_id": household.uuidString,
         "title": "Sony WH-1000XM5 black", "status": "active", "criteria_version": 1,
         "confirmed_at": "2026-10-17T19:00:00Z", "last_result": "matched", "search_available": true,
         "next_check_at": "2026-10-18T00:00:00Z", "last_successful_at": "2026-10-17T20:00:00Z", "matches": [offer], "runs": [],
         "criteria": ["query": "Sony WH-1000XM5", "required_terms": ["black"], "excluded_terms": ["case only"], "quantity": 1,
                      "target_price_cents": 24900, "currency": "USD", "fulfillment": "delivery", "location": "Seattle, WA 98107",
                      "allowed_domains": [], "condition": "new", "allow_membership": false],
         "subscription": ["push_enabled": false, "timezone": "America/Los_Angeles", "daily_cap": 3, "cooldown_hours": 24]]
    }
    private var offer: [String: Any] {
        ["id": UUID().uuidString, "watch_id": watchID.uuidString, "criteria_version": 1, "is_current": true,
         "title": "Sony WH-1000XM5 wireless headphones · Black", "url": "https://electronics.example.com/sony-wh1000xm5",
         "merchant": "Northwest Electronics", "unit_price_cents": 23900, "total_price_cents": 25812,
         "currency": "USD", "quantity": 1, "shipping_cents": 0, "tax_cents": 1912,
         "fulfillment": "delivery", "location": "Seattle, WA 98107", "condition": "new",
         "observed_at": "2026-10-17T20:00:00Z", "matched_at": "2026-10-17T20:01:00Z",
         "evidence": ["WH-1000XM5 model and black variant confirmed on retailer page."],
         "reason": "Exact model and color, new condition, below your $249 per-item target."]
    }
    private var notification: [String: Any] {
        ["id": notificationID.uuidString, "household_id": household.uuidString, "watch_id": watchID.uuidString,
         "title": "Headphones at your target", "body": "A verified offer meets your criteria.", "created_at": "2026-10-17T20:00:00Z"]
    }
    override func setUp() async throws {
        calendar = CalendarConnection(authorization: WatchGoogle()); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [WatchHTTP.self]
        session = URLSession(configuration: config)
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://watch.example.com"), http: session)
        inventory = InventoryStore(api: api, calendar: calendar); store = WatchStore(api: api, inventory: inventory)
        let household = household, row = row
        WatchHTTP.delay = 0
        WatchHTTP.handler = { request in
            switch request.url!.path {
            case "/v1/me": return (200, ["households": [["id": household.uuidString, "name": "Home", "locations": []]]])
            case "/v1/watches": return (200, ["watches": [row], "search_available": true])
            default: return (200, [])
            }
        }
        await inventory.refresh(); await store.refresh()
        XCTAssertEqual(store.watches.count, 1); XCTAssertNil(store.error)
    }
    override func tearDown() async throws {
        session.invalidateAndCancel(); WatchHTTP.handler = nil; WatchHTTP.delay = 0
        store = nil; inventory = nil; calendar = nil
    }
    private var draft: WatchDraft {
        var value = WatchDraft(); value.query = "Sony WH-1000XM5 black"; value.location = "Seattle, WA 98107"
        value.targetPrice = "249.00"; value.requiredTerms = "black, WH-1000XM5"; return value
    }
    func testReviewAndExactProductValidation() throws {
        XCTAssertThrowsError(try draft.body(confirmed: false))
        var value = draft
        let body = try value.body(confirmed: true), criteria = try XCTUnwrap(body["criteria"] as? [String: Any])
        XCTAssertEqual(criteria["target_price_cents"] as? Int, 24900)
        XCTAssertEqual(criteria["required_terms"] as? [String], ["black", "WH-1000XM5"])
        XCTAssertTrue(criteria["max_total_cents"] is NSNull)
        value.location = " "; XCTAssertThrowsError(try value.body(confirmed: true))
        value = draft; value.targetPrice = "0"; XCTAssertThrowsError(try value.body(confirmed: true))
        value = draft; value.productURL = "https://user:password@example.com/item"; XCTAssertThrowsError(try value.body(confirmed: true))
        value = draft; value.allowedDomains = "https://retailer.com/item"; XCTAssertThrowsError(try value.body(confirmed: true))
        value = draft; value.quietHours = true; value.quietStart = 8; value.quietEnd = 8; XCTAssertThrowsError(try value.body(confirmed: true))
    }
    func testDiscoveryUnavailableRequiresSuccessfulCapabilityResponse() async throws {
        XCTAssertTrue(store.hasLoadedCapabilities); XCTAssertFalse(store.discoveryUnavailable)
        WatchHTTP.handler = { _ in (404, ["detail": "Not Found"]) }
        await store.refresh()
        XCTAssertFalse(store.hasLoadedCapabilities); XCTAssertFalse(store.discoveryUnavailable)
        XCTAssertTrue(store.error?.contains("connected service") == true)
        WatchHTTP.handler = { _ in (200, ["watches": [], "search_available": true, "discovery_available": false]) }
        await store.refresh()
        XCTAssertTrue(store.hasLoadedCapabilities); XCTAssertTrue(store.discoveryUnavailable); XCTAssertNil(store.error)
        WatchHTTP.handler = { _ in (200, ["watches": [], "search_available": true, "discovery_available": false,
                                         "discovery_status": "model_not_configured"]) }
        await store.refresh()
        XCTAssertTrue(store.discoveryExplanation.contains("model connection"))
        WatchHTTP.handler = { _ in (200, ["watches": [], "search_available": true, "discovery_available": false,
                                         "discovery_status": "search_not_configured"]) }
        await store.refresh()
        XCTAssertTrue(store.discoveryExplanation.contains("web search provider"))
        WatchHTTP.handler = { _ in (503, ["detail": "Service temporarily unavailable"]) }
        await store.refresh()
        XCTAssertFalse(store.hasLoadedCapabilities); XCTAssertFalse(store.discoveryUnavailable); XCTAssertNotNil(store.error)
        WatchHTTP.handler = { _ in (200, ["watches": [], "search_available": true, "discovery_available": true]) }
        await store.refresh()
        XCTAssertTrue(store.hasLoadedCapabilities); XCTAssertFalse(store.discoveryUnavailable); XCTAssertNil(store.error)
        await calendar.signOut()
        XCTAssertFalse(store.hasLoadedCapabilities); XCTAssertFalse(store.discoveryUnavailable)
        XCTAssertNil(store.discoveryStatus)
    }
    func testConfirmedWatchPauseResumeAndQueuedCheckRetry() async throws {
        var row = row, keys: [String] = [], checks = 0
        WatchHTTP.handler = { request in
            let body = watchBody(request), path = request.url!.path
            if path.hasSuffix("/check") {
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!); checks += 1
                if checks == 1 { return (503, ["title": "unavailable", "detail": "Try again"]) }
                return (202, ["watch_id": self.watchID.uuidString, "run_id": UUID().uuidString, "status": "queued"])
            }
            if request.httpMethod == "PUT" {
                XCTAssertEqual(path, "/v1/wishlist/\(self.itemID)/watch"); XCTAssertEqual(body["confirmed"] as? Bool, true)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "reviewed-key")
            }
            if request.httpMethod == "PATCH" { row["status"] = body["status"] }
            return (200, row)
        }
        try await store.save(draft, itemID: itemID, confirmed: true, key: "reviewed-key")
        await store.setPaused(store.watches[0], paused: true); XCTAssertEqual(store.watches[0].status, "paused")
        await store.setPaused(store.watches[0], paused: false); XCTAssertEqual(store.watches[0].status, "active")
        await store.checkNow(store.watches[0]); XCTAssertNotNil(store.error)
        await store.checkNow(store.watches[0]); XCTAssertNil(store.error); XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys.first, keys.last)
        XCTAssertNil(store.notice, "A completed detail read should clear the queued message")
    }
    func testInboxReadAndAccountChangeDiscardInflightWatches() async throws {
        var notification = notification
        WatchHTTP.handler = { request in
            if request.url!.path.hasSuffix("/read") { notification["read_at"] = "2026-10-17T21:00:00Z"; return (200, notification) }
            return (200, [notification])
        }
        await store.refreshInbox(); XCTAssertEqual(store.notifications.count, 1)
        await store.markRead(store.notifications[0]); XCTAssertNil(store.error)
        XCTAssertNotNil(store.notifications[0].readAt)
        let started = expectation(description: "watch request started"), row = row
        WatchHTTP.handler = { _ in started.fulfill(); return (200, ["watches": [row], "search_available": true]) }; WatchHTTP.delay = 0.15
        let task = Task { await self.store.refresh() }
        await fulfillment(of: [started], timeout: 2); await calendar.signOut(); await task.value
        XCTAssertFalse(store.canUse); XCTAssertTrue(store.watches.isEmpty); XCTAssertTrue(store.notifications.isEmpty)
        XCTAssertNil(store.error); XCTAssertFalse(store.loading)
    }
    func testOfferValidityAndNoMatchFailureAreDistinct() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
        var value = row; value["last_result"] = "no_match"
        let noMatch = try decoder.decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertTrue(noMatch.resultLabel.contains("No offers"))
        value["last_result"] = "failed"
        let failure = try decoder.decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertTrue(failure.resultLabel.contains("failed")); XCTAssertNotEqual(noMatch.resultLabel, failure.resultLabel)
        value["search_available"] = false
        let unavailable = try decoder.decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertTrue(unavailable.resultLabel.contains("unavailable"))
        value["subscription"] = NSNull(); value["confirmed_at"] = NSNull()
        let sharedWatch = try decoder.decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(sharedWatch.subscription); XCTAssertNil(sharedWatch.confirmedAt)
        let editable = WatchDraft(watch: sharedWatch)
        XCTAssertEqual(editable.query, sharedWatch.criteria.query); XCTAssertFalse(editable.pushEnabled)
        let offer: [String: Any] = ["id": UUID().uuidString, "watch_id": watchID.uuidString, "criteria_version": 1, "is_current": true,
            "title": "Sony WH-1000XM5 black", "url": "javascript:alert(1)", "merchant": "Headphone Shop",
            "unit_price_cents": 23900, "total_price_cents": 25812, "currency": "USD", "quantity": 1,
            "shipping_cents": 0, "tax_cents": 1912, "fulfillment": "delivery", "location": "Seattle, WA 98107",
            "condition": "new", "observed_at": "2026-10-17T20:00:00Z", "matched_at": "2026-10-17T20:01:00Z",
            "evidence": ["Model and color verified on product page"], "reason": "The exact model meets the unit-price target."]
        var staleOffer = offer; staleOffer["id"] = UUID().uuidString; staleOffer["criteria_version"] = 0
        value["matches"] = [offer, staleOffer]
        let matched = try decoder.decode(PriceWatch.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertEqual(matched.currentOffers.count, 1); XCTAssertEqual(matched.historicalOffers.count, 1); XCTAssertNil(matched.currentOffers[0].safeURL)
    }
    func testBrowserReviewRequiresExplicitCurrentConfirmedSourceAndSurfacesFailures() async throws {
        let firstURL = URL(string: "https://shop.example.com/choose-variant")!
        let secondURL = URL(string: "https://store.example.com/login")!
        let run: [String: Any] = ["id": UUID().uuidString, "criteria_version": 1, "status": "succeeded",
            "created_at": "2026-10-17T20:00:00Z", "offer_count": 0, "match_count": 0,
            "interaction_urls": [firstURL.absoluteString, "javascript:alert(1)", "https://127.0.0.1/cart", firstURL.absoluteString]]
        var older = run; older["id"] = UUID().uuidString; older["created_at"] = "2026-10-17T19:00:00Z"
        older["interaction_urls"] = [secondURL.absoluteString]
        var current = row; current["runs"] = [older, run]
        WatchHTTP.handler = { _ in (200, ["watches": [current], "search_available": true]) }
        var opened: [URL] = []
        store.browserReviewHandler = { opened.append($0) }
        await store.refresh()
        XCTAssertEqual(store.watches[0].browserReviewURLs, [firstURL]); XCTAssertTrue(opened.isEmpty)
        XCTAssertNil(store.browserReviewRequestID)
        store.reviewInBrowser(watchID: watchID, url: firstURL)
        XCTAssertEqual(opened, [firstURL]); XCTAssertNotNil(store.browserReviewRequestID); XCTAssertNil(store.error)
        let request = store.browserReviewRequestID
        store.reviewInBrowser(watchID: watchID, url: secondURL)
        XCTAssertEqual(opened, [firstURL]); XCTAssertNotNil(store.error); XCTAssertEqual(store.browserReviewRequestID, request)
        store.browserReviewHandler = { _ in throw BrowserError("browser_unavailable", "Could not open the shared browser.") }
        store.reviewInBrowser(watchID: watchID, url: firstURL)
        XCTAssertTrue(store.error?.contains("Could not open") == true); XCTAssertEqual(store.browserReviewRequestID, request)
        current["criteria_version"] = 2; await store.refresh()
        XCTAssertTrue(store.watches[0].browserReviewURLs.isEmpty, "Older research must not hand off after criteria change")
        current["criteria_version"] = 1
        current["confirmed_at"] = NSNull(); await store.refresh()
        XCTAssertTrue(store.watches[0].browserReviewURLs.isEmpty)
        store.reviewInBrowser(watchID: watchID, url: firstURL)
        XCTAssertEqual(opened, [firstURL])
        await calendar.signOut(); XCTAssertNil(store.browserReviewRequestID)
        store.reviewInBrowser(watchID: watchID, url: firstURL)
        XCTAssertEqual(opened, [firstURL])
    }

    func testWatchScreensRender() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        var row = row
        row["runs"] = [["id": UUID().uuidString, "criteria_version": 1, "status": "succeeded",
            "created_at": "2026-10-17T20:00:00Z", "offer_count": 1, "match_count": 1,
            "interaction_urls": ["https://electronics.example.com/choose-variant"]]]
        let notification = notification
        WatchHTTP.handler = { request in
            if request.url!.path == "/v1/notifications" { return (200, [notification]) }
            if request.url!.path == "/v1/watches" { return (200, ["watches": [row], "search_available": true]) }
            return (200, row)
        }
        await store.refresh()
        let views: [(String, AnyView)] = [
            ("watches", AnyView(NavigationStack { WatchListView(store: store) })),
            ("watch-detail", AnyView(NavigationStack { WatchDetailView(store: store, watchID: watchID) })),
            ("watch-criteria", AnyView(WatchEditor(store: store, itemID: itemID, watch: store.watches[0]))),
            ("watch-inbox", AnyView(NavigationStack { WatchInboxView(store: store) }))]
        for (name, view) in views {
            let hosting = UIHostingController(rootView: view); window.rootViewController = hosting; window.makeKeyAndVisible()
            hosting.view.frame = window.bounds; hosting.view.layoutIfNeeded(); try await Task.sleep(for: .milliseconds(200))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
            try XCTUnwrap(image.pngData()).write(to: path)
            print("Watch screenshot: \(path.path)")
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}

// This transport exists only in the test bundle; production keeps HTTPS and redirect checks.
private final class WatchLiveHTTP: URLProtocol {
    static var destination = URL(string: "http://127.0.0.1:18767")!
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "watch-live.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        let original = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        var target = URLComponents(url: Self.destination, resolvingAgainstBaseURL: false)!
        target.path = original.path; target.percentEncodedQuery = original.percentEncodedQuery
        forwarded.url = target.url
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            forwarded.httpBodyStream = nil; forwarded.httpBody = data
        }
        forwardedTask = URLSession.shared.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }
    override func stopLoading() { forwardedTask?.cancel() }
}

@MainActor
private final class WatchLiveSession: DemoSessionStoring {
    var session: DemoSession?
    func load() throws -> DemoSession? { session }
    func save(_ session: DemoSession?) throws { self.session = session }
}

@MainActor
final class WatchLiveTests: XCTestCase {
    func testConfirmedWatchMatchesInboxRestartAndWishlistInvalidationAgainstRealBackend() async throws {
        if let configured = ProcessInfo.processInfo.environment["AGORA_WATCH_LIVE_URL"], let url = URL(string: configured) { WatchLiveHTTP.destination = url }
        var probe = URLRequest(url: WatchLiveHTTP.destination.appendingPathComponent("healthz")); probe.timeoutInterval = 2
        do { _ = try await URLSession.shared.data(for: probe) }
        catch { throw XCTSkip("Start the isolated watch API with worker enabled on port 18767.") }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [WatchLiveHTTP.self]
        let http = URLSession(configuration: configuration); defer { http.invalidateAndCancel() }
        let origin = URL(string: "https://watch-live.example.com")!, session = WatchLiveSession()
        let calendar = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await calendar.connectDemo(handle: "demo", password: "")
        XCTAssertTrue(calendar.connected, calendar.message ?? "Sign in failed")
        let api = AgoraClient(calendar: calendar, baseURL: origin, http: http)
        let inventory = InventoryStore(api: api, calendar: calendar); await inventory.refresh()
        XCTAssertNil(inventory.error)
        let shopping = ShoppingStore(api: api, inventory: inventory), store = shopping.watches
        let title = "Lodge 12-inch cast iron skillet · " + UUID().uuidString.prefix(8)
        var wishlist = WishlistDraft(); wishlist.title = title; wishlist.quantity = 1; wishlist.targetPrice = "35.00"
        try await shopping.save(wishlist)
        let item = try XCTUnwrap(shopping.active.first { $0.title == title })
        var draft = WatchDraft(item: item); draft.productURL = "https://www.lodgecastiron.com/product/round-cast-iron-classic-skillet"
        draft.requiredTerms = "Lodge, 12-inch"; draft.excludedTerms = "used, lid only"; draft.location = "Seattle, WA 98107"
        draft.maxTotal = "40.00"; draft.pushEnabled = false
        XCTAssertThrowsError(try draft.body(confirmed: false))
        try await store.save(draft, itemID: item.id, confirmed: true, key: UUID().uuidString)
        var watch = try XCTUnwrap(store.watches.first { $0.wishlistItemId == item.id })
        XCTAssertNotNil(watch.confirmedAt); XCTAssertEqual(watch.criteria.targetPriceCents, 3500)
        XCTAssertEqual(watch.criteria.requiredTerms, ["lodge", "12-inch"])
        await store.checkNow(watch); XCTAssertNil(store.error)
        for _ in 0..<40 {
            await store.detail(watch.id)
            watch = try XCTUnwrap(store.watches.first { $0.id == watch.id })
            if !watch.currentOffers.isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(watch.lastResult, "matched", store.error ?? watch.lastError ?? "No match completed")
        XCTAssertNotNil(watch.lastSuccessfulAt)
        let offer = try XCTUnwrap(watch.currentOffers.first)
        XCTAssertLessThanOrEqual(offer.unitPriceCents, watch.criteria.targetPriceCents)
        XCTAssertEqual(offer.quantity, 1); XCTAssertEqual(offer.fulfillment, "delivery"); XCTAssertEqual(offer.condition, "new")
        XCTAssertNotNil(offer.safeURL); XCTAssertFalse(offer.evidence.isEmpty)
        await store.refreshInbox(); XCTAssertNil(store.error)
        let notification = try XCTUnwrap(store.notifications.first { $0.watchId == watch.id })
        await store.markRead(notification); XCTAssertNil(store.error)
        XCTAssertNotNil(store.notifications.first { $0.id == notification.id }?.readAt)
        try await render(WatchDetailView(store: store, watchID: watch.id), name: "watch-live-verified-offer")
        try await render(WatchInboxView(store: store), name: "watch-live-inbox")
        await store.setPaused(watch, paused: true); XCTAssertNil(store.error)
        XCTAssertEqual(store.watches.first { $0.id == watch.id }?.status, "paused")
        await store.setPaused(try XCTUnwrap(store.watches.first { $0.id == watch.id }), paused: false)
        XCTAssertNil(store.error)

        let restoredCalendar = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await restoredCalendar.refresh()
        let restoredAPI = AgoraClient(calendar: restoredCalendar, baseURL: origin, http: http)
        let restoredInventory = InventoryStore(api: restoredAPI, calendar: restoredCalendar); await restoredInventory.refresh()
        let restored = WatchStore(api: restoredAPI, inventory: restoredInventory); await restored.refresh(); await restored.refreshInbox()
        let persisted = try XCTUnwrap(restored.watches.first { $0.id == watch.id })
        XCTAssertEqual(persisted.status, "active"); XCTAssertEqual(persisted.criteria.targetPriceCents, 3500)
        XCTAssertFalse(persisted.currentOffers.isEmpty)
        XCTAssertNotNil(restored.notifications.first { $0.id == notification.id }?.readAt)

        let alertCount = restored.notifications.filter { $0.watchId == watch.id }.count
        var edit = WishlistDraft(item: item); edit.title += " with lid"
        try await shopping.save(edit, original: item)
        await restored.detail(watch.id)
        let invalidated = try XCTUnwrap(restored.watches.first { $0.id == watch.id })
        XCTAssertEqual(invalidated.status, "paused"); XCTAssertNil(invalidated.confirmedAt)
        XCTAssertTrue(invalidated.currentOffers.isEmpty)
        await restored.setPaused(invalidated, paused: false)
        XCTAssertNotNil(restored.error, "A changed parent must require explicit reconfirmation")
        do {
            _ = try await restoredAPI.request("v1/watches/\(watch.id)/check", method: "POST", key: UUID().uuidString)
            XCTFail("An invalidated watch must reject manual checks until reconfirmed")
        } catch let error as BrowserError { XCTAssertEqual(error.status, 409) }
        await restored.refreshInbox()
        XCTAssertEqual(restored.notifications.filter { $0.watchId == watch.id }.count, alertCount)
        await calendar.signOut(); XCTAssertTrue(store.watches.isEmpty); XCTAssertTrue(store.notifications.isEmpty)
    }
    private func render<Content: View>(_ content: Content, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack { content })
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)) }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
        try XCTUnwrap(image.pngData()).write(to: path); print("Watch live screenshot: \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
