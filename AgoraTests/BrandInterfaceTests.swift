import XCTest
import SwiftUI
@testable import Agora

@MainActor
private final class BrandAccount: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "brand-fixture", email: "fixture@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "fixture" }
    func idToken(for accountID: String) async throws -> String { "fixture" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class BrandHTTP: URLProtocol {
    static var response: ((URLRequest) -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let data = Self.response?(request) else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": request.url!.path.contains("/assets/") ? "image/png" : "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Render real destinations using an isolated account and deterministic image/API fixtures.
/// Attachments are reviewed visually; a successful draw alone is not a layout assertion.
@MainActor
final class BrandInterfaceTests: XCTestCase {
    func testDestinationsInLightDarkAndAccessibilitySizes() async throws {
        let account = BrandAccount()
        let calendar = CalendarConnection(authorization: account); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BrandHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); BrandHTTP.response = nil }
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://brand.example"), http: session)
        let inventory = InventoryStore(api: api, calendar: calendar)
        let shopping = ShoppingStore(api: api, inventory: inventory)
        let trips = TripStore(api: api, inventory: inventory, calendar: calendar)
        let images = ItemImageStore(api: api)
        let suite = "brand-\(UUID())", household = UUID(), milk = UUID(), bread = UUID(), wishlist = UUID(), suggestion = UUID(), list = UUID(), watch = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(keychainService: suite, defaults: defaults)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let stock: [[String: Any]] = [
            ["id": milk.uuidString, "household_id": household.uuidString, "display_name": "Organic whole milk", "category": "dairy", "unit": "cartons", "quantity": 1, "par_level": 2, "status": "active"],
            ["id": bread.uuidString, "household_id": household.uuidString, "display_name": "Whole grain sourdough", "category": "bakery", "unit": "loaves", "quantity": 2, "status": "active"]]
        let wanted: [String: Any] = ["id": wishlist.uuidString, "household_id": household.uuidString, "title": "Cast iron skillet", "category": "cookware", "quantity": 1, "target_price_cents": 2500, "source": "user", "status": "active", "pinned": false, "evidence": [], "score": 100, "priority_reasons": [], "created_at": timestamp]
        var suggested = wanted
        suggested["id"] = suggestion.uuidString; suggested["title"] = "Fresh apples"; suggested["category"] = "produce"
        suggested["status"] = "suggested"; suggested["source"] = "agent"; suggested["rationale"] = "For this week’s breakfasts."
        let shoppingList: [String: Any] = ["id": list.uuidString, "household_id": household.uuidString, "name": "Weekend groceries", "status": "open", "source": "manual", "open_count": 2, "updated_at": timestamp, "items": [
            ["id": milk.uuidString, "title": "Organic whole milk", "quantity": 2, "unit": "cartons", "checked": false],
            ["id": bread.uuidString, "title": "Whole grain sourdough", "quantity": 1, "unit": "loaf", "checked": false]]]
        let watched: [String: Any] = ["id": watch.uuidString, "wishlist_item_id": wishlist.uuidString, "household_id": household.uuidString, "title": "Cast iron skillet", "status": "active", "criteria_version": 1, "last_result": "no_match", "search_available": true, "matches": [], "runs": [],
            "criteria": ["query": "Cast iron skillet", "required_terms": [], "excluded_terms": [], "quantity": 1, "target_price_cents": 2500, "currency": "USD", "fulfillment": "delivery", "location": "US", "allowed_domains": [], "condition": "new", "allow_membership": false],
            "prices": [["id": UUID().uuidString, "title": "Cast iron skillet", "merchant": "Kitchen store", "url": "https://retailer.example/skillet", "unit_price_cents": 2999, "currency": "USD", "observed_at": timestamp, "reason": "above_target", "is_current": true, "verification_note": "Sample retailer price"]]]
        let artwork = try Dictionary(uniqueKeysWithValues: ["milk", "bread", "cookware", "produce"].map {
            ($0, try XCTUnwrap(UIImage(named: "Item-" + $0)?.pngData()))
        })
        let assets = Dictionary(uniqueKeysWithValues: artwork.keys.map { ($0, UUID()) })
        BrandHTTP.response = { request in
            let path = request.url!.path
            if path.contains("/assets/"), let kind = assets.first(where: { $0.value.uuidString == request.url!.lastPathComponent })?.key { return artwork[kind]! }
            let value: Any
            switch path {
            case "/v1/me": value = ["households": [["id": household.uuidString, "name": "Home", "locations": []]]]
            case "/v1/inventory": value = stock
            case "/v1/inventory/\(milk.uuidString)":
                var detail = stock[0]; detail["daily"] = []; detail["observations"] = []; detail["purchase_history"] = []; value = detail
            case "/v1/wishlist":
                let status = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "status" }?.value
                value = status == "active" ? [wanted] : []
            case "/v1/wishlist/suggestions": value = [suggested]
            case "/v1/wishlist/refresh-status": value = ["household_id": household.uuidString, "next_refresh_at": timestamp, "generated_count": 1]
            case "/v1/lists": value = [shoppingList]
            case "/v1/lists/\(list.uuidString)": value = shoppingList
            case "/v1/watches": value = ["watches": [watched], "search_available": true, "automatic_watches": true]
            case "/v1/watches/\(watch.uuidString)": value = watched
            default:
                if path.hasPrefix("/v1/item-images/") {
                    let id = request.url!.lastPathComponent
                    let kind = id == milk.uuidString ? "milk" : id == bread.uuidString ? "bread" : id == suggestion.uuidString ? "produce" : "cookware"
                    value = ["status": "ready", "fallback": "cookware", "choices": [], "user_selected": false, "inherited": false, "version": 1,
                        "asset": ["id": assets[kind]!.uuidString, "path": "/v1/item-images/assets/\(assets[kind]!.uuidString)", "match_kind": "representative"]]
                } else { value = [] }
            }
            return try! JSONSerialization.data(withJSONObject: value)
        }
        await inventory.refresh(); await shopping.refresh(); await shopping.watches.refresh(); await trips.refresh()
        XCTAssertNil(inventory.error, "Inventory fixture"); XCTAssertNil(shopping.error, "Wishlist fixture"); XCTAssertNil(shopping.watches.error, "Watch fixture"); XCTAssertNil(trips.error, "Trips fixture")
        XCTAssertEqual(inventory.items.count, 2); XCTAssertEqual(shopping.active.count, 1); XCTAssertEqual(trips.lists.count, 1)
        await images.prefetch([
            .init(kind: "inventory", id: milk, name: "Organic whole milk", category: "dairy"),
            .init(kind: "inventory", id: bread, name: "Whole grain sourdough", category: "bakery"),
            .init(kind: "wishlist", id: wishlist, name: "Cast iron skillet", category: "cookware"),
            .init(kind: "wishlist", id: suggestion, name: "Fresh apples", category: "produce"),
            .init(kind: "wishlist", id: wishlist, name: "Cast iron skillet"),
            .init(kind: "list", id: milk, name: "Organic whole milk"),
            .init(kind: "list", id: bread, name: "Whole grain sourdough")])
        XCTAssertFalse(images.pictures.isEmpty)

        let workspace = ChatWorkspace()
        let views: [(String, AnyView)] = [
            ("home", AnyView(HomeView(selectedTab: .constant(.home), store: inventory, shopping: shopping, settings: settings, trips: trips))),
            ("lists", AnyView(ListsView(inventory: inventory, shopping: shopping, settings: settings, trips: trips))),
            ("inventory", AnyView(InventoryView(store: inventory))),
            ("item", AnyView(NavigationStack { InventoryDetailView(store: inventory, itemID: milk) })),
            ("inventory-add", AnyView(InventoryEditor(store: inventory, original: nil))),
            ("wishlist", AnyView(NavigationStack { ShoppingView(store: shopping, settings: settings) })),
            ("suggestions", AnyView(NavigationStack { ShoppingView(store: shopping, settings: settings, selection: "suggestions") })),
            ("watch", AnyView(NavigationStack { WatchDetailView(store: shopping.watches, watchID: watch) })),
            ("watch-edit", AnyView(WatchEditor(store: shopping.watches, itemID: wishlist, watch: shopping.watches.watches.first))),
            ("trips", AnyView(NavigationStack { TripsView(store: trips) })),
            ("checklist", AnyView(NavigationStack { TripListView(store: trips, listID: list) })),
            ("new-list", AnyView(TripCreateListSheet(store: trips) { _ in })),
            ("settings", AnyView(SettingsView(settings: settings, workspace: workspace))),
            ("models", AnyView(NavigationStack { ModelSettingsView(settings: settings) })),
            ("welcome", AnyView(CalendarOnboardingView(calendar: calendar)))
        ]
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKeyAndVisible(); images.reset() }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agora-brand-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (variant, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large), ("dark", .dark, .large), ("accessible", .light, .accessibility3), ("wide", .light, .large)] {
            window.frame = CGRect(x: 0, y: 0, width: variant == "wide" ? 1024 : variant == "accessible" ? 375 : 393, height: variant == "wide" ? 768 : 852)
            for (name, view) in views {
                let host = UIHostingController(rootView: view.environment(\.itemImages, images).environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size))
                window.rootViewController = host; window.makeKeyAndVisible()
                host.view.frame = window.bounds; host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(350))
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
                }
                let name = "\(name)-\(variant)"
                try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
                let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        print("Brand review screenshots: \(directory.path)")
    }
}
