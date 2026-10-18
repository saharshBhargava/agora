import XCTest
import SwiftUI
@testable import Agora

@MainActor
private final class ShoppingGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "shopping-alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { "shopping-token" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class ShoppingHTTP: URLProtocol {
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

private func shoppingBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor
final class ShoppingTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var inventory: InventoryStore!
    private var shopping: ShoppingStore!
    private var session: URLSession!
    private var settings: SettingsStore!
    private let household = UUID(), itemID = UUID(), inventoryID = UUID()
    private var row: [String: Any] {
        ["id": itemID.uuidString, "household_id": household.uuidString, "title": "Coffee filters", "quantity": 1,
         "source": "agent", "status": "suggested", "pinned": false, "rationale": "Useful with your coffee.",
         "evidence": [["kind": "other", "detail": "Coffee in inventory."]], "confidence": 0.8,
         "score": 350, "priority_reasons": ["Running low"], "created_at": "2026-10-17T19:00:00Z"]
    }
    private var profile: [String: Any] {
        ["households": [["id": household.uuidString, "name": "Home", "locations": []]]]
    }
    private var stock: [String: Any] {
        ["id": inventoryID.uuidString, "household_id": household.uuidString, "display_name": "Coffee beans",
         "quantity": 1, "par_level": 2, "unit": "bags", "status": "active"]
    }
    private var state: [String: Any] {
        ["household_id": household.uuidString, "last_refreshed_at": "2026-10-17T18:00:00Z",
         "next_refresh_at": "2026-10-18T00:00:00Z", "generated_count": 1]
    }
    override func setUp() async throws {
        calendar = CalendarConnection(authorization: ShoppingGoogle()); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ShoppingHTTP.self]
        session = URLSession(configuration: config)
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://shopping.example.com"), http: session)
        inventory = InventoryStore(api: api, calendar: calendar)
        shopping = ShoppingStore(api: api, inventory: inventory)
        let suite = "shopping-tests-" + UUID().uuidString
        settings = SettingsStore(keychainService: suite, defaults: UserDefaults(suiteName: suite)!)
        let profile = profile, stock = stock, row = row, state = state
        ShoppingHTTP.delay = 0
        ShoppingHTTP.handler = { request in
            switch request.url!.path {
            case "/v1/me": return (200, profile)
            case "/v1/inventory": return (200, [stock])
            case "/v1/wishlist/suggestions": return (200, [row])
            case "/v1/wishlist/refresh-status": return (200, state)
            default: return (200, [])
            }
        }
        await inventory.refresh(); await shopping.refresh()
        XCTAssertEqual(shopping.suggestions.count, 1); XCTAssertNil(shopping.error)
    }
    override func tearDown() async throws {
        session.invalidateAndCancel(); ShoppingHTTP.handler = nil; ShoppingHTTP.delay = 0
        settings = nil; shopping = nil; inventory = nil; calendar = nil
    }

    func testTargetPriceValidationAndExplicitClearing() throws {
        XCTAssertEqual(try WishlistDraft.cents("19.99"), 1999)
        XCTAssertEqual(try WishlistDraft.cents("0"), 0)
        XCTAssertNil(try WishlistDraft.cents(" "))
        for bad in ["-1", "1.001", "1e3", "NaN", "100000.01", "abc"] { XCTAssertThrowsError(try WishlistDraft.cents(bad)) }
        var draft = WishlistDraft(); draft.title = "Coffee"; draft.targetPrice = "9.95"
        let body = try draft.body(householdID: household, editing: false)
        XCTAssertEqual(body["target_price_cents"] as? Int, 995)
        XCTAssertEqual(body["household_id"] as? String, household.uuidString)
        draft.targetPrice = ""; draft.notes = ""
        let patch = try draft.body(householdID: household, editing: true)
        XCTAssertTrue(patch["target_price_cents"] is NSNull); XCTAssertTrue(patch["notes"] is NSNull)
        XCTAssertNil(patch["household_id"])
    }

    func testWishlistSaveAcceptSnoozePurchaseAndFeedback204() async throws {
        var saved = row
        ShoppingHTTP.handler = { request in
            let path = request.url!.path, body = shoppingBody(request)
            if path.hasSuffix("/feedback") {
                XCTAssertEqual(request.httpMethod, "DELETE"); return (204, nil)
            }
            if request.httpMethod == "PATCH" {
                XCTAssertTrue(body["target_price_cents"] is NSNull)
                for (key, value) in body { saved[key] = value }
            } else if path.hasSuffix("/accept") { saved["status"] = "active" }
            else if path.hasSuffix("/snooze") { saved["status"] = "snoozed"; XCTAssertEqual(body["days"] as? Int, 7) }
            else if path.hasSuffix("/purchased") { saved["status"] = "purchased" }
            else if request.httpMethod == "GET" {
                if path.hasSuffix("/refresh-status") { return (200, self.state) }
                return (200, path.hasSuffix("/suggestions") ? [] : [saved])
            }
            return (200, saved)
        }
        await shopping.act(shopping.suggestions[0], action: "snooze", body: ["days": 7])
        XCTAssertEqual(shopping.snoozed.count, 1)
        await shopping.act(shopping.snoozed[0], action: "accept")
        XCTAssertEqual(shopping.active.count, 1)
        var draft = WishlistDraft(item: shopping.active[0]); draft.targetPrice = ""
        try await shopping.save(draft, original: shopping.active[0])
        await shopping.act(shopping.active[0], action: "purchased")
        XCTAssertEqual(shopping.history.first?.status, "purchased")
        saved["my_feedback"] = "up"
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; decoder.dateDecodingStrategy = .iso8601
        let rated = try decoder.decode(WishlistItem.self, from: JSONSerialization.data(withJSONObject: saved))
        await shopping.feedback(rated, rating: "up")
        XCTAssertNil(shopping.error)
    }

    func testInventoryPollDoesNotResetShoppingAndSignOutDiscardsInflightRead() async throws {
        let oldContext = shopping.context
        await inventory.refresh()
        XCTAssertEqual(shopping.context, oldContext); XCTAssertEqual(shopping.suggestions.count, 1)
        let requested = expectation(description: "shopping read started")
        let row = row
        ShoppingHTTP.handler = { _ in requested.fulfill(); return (200, [row]) }
        ShoppingHTTP.delay = 0.15
        let task = Task { await self.shopping.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        await calendar.signOut(); await task.value
        XCTAssertFalse(shopping.canUse); XCTAssertTrue(shopping.items.isEmpty); XCTAssertNil(shopping.error)
    }

    func testRefreshRetryKeepsIdempotencyKey() async {
        var keys: [String] = [], attempts = 0
        let original = ShoppingHTTP.handler!
        ShoppingHTTP.handler = { request in
            if request.url!.path == "/v1/wishlist/refresh" {
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                attempts += 1
                if attempts == 1 { return (503, ["title": "unavailable", "detail": "Try again"]) }
                return (200, self.state)
            }
            return original(request)
        }
        await shopping.refreshSuggestions(); XCTAssertNotNil(shopping.error)
        await shopping.refreshSuggestions(); XCTAssertNil(shopping.error)
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys.first, keys.last)
    }

    func testSuggestionEvidenceAndToolArgumentsAreValidated() throws {
        let valid: [String: Any] = ["title": "Coffee filters", "category": "kitchen", "quantity": 1,
            "rationale": "For the coffee in your inventory.", "confidence": 0.8, "evidenceItemIds": [inventoryID.uuidString]]
        func encoded(_ candidate: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: ["suggestions": [candidate]]), as: UTF8.self)
        }
        XCTAssertEqual(try SuggestionService.decode(encoded(valid), inventoryIDs: [inventoryID]).count, 1)
        var invalid = valid; invalid["evidenceItemIds"] = [UUID().uuidString]
        XCTAssertThrowsError(try SuggestionService.decode(encoded(invalid), inventoryIDs: [inventoryID]))
        invalid = valid; invalid["quantity"] = 0
        XCTAssertThrowsError(try SuggestionService.decode(encoded(invalid), inventoryIDs: [inventoryID]))
        invalid = valid; invalid["rationale"] = String(repeating: "x", count: 501)
        XCTAssertThrowsError(try SuggestionService.decode(encoded(invalid), inventoryIDs: [inventoryID]))
        XCTAssertThrowsError(try ShoppingCall(["name": "shopping_context", "args": ["household_id": UUID().uuidString]]))
        let call = try ShoppingCall(["name": "shopping_suggest", "args": valid])
        let task = UUID()
        XCTAssertEqual(try call.requestKey(taskID: task), try call.requestKey(taskID: task))
    }

    func testChatSuggestionStoresEvidenceAndUpdatesInbox() async throws {
        let candidate: [String: Any] = ["title": "Coffee filters", "category": "kitchen", "quantity": 1,
            "rationale": "For the coffee in your inventory.", "confidence": 0.8, "evidenceItemIds": [inventoryID.uuidString]]
        let row = row
        ShoppingHTTP.handler = { request in
            XCTAssertEqual(request.url!.path, "/v1/wishlist/suggestions")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
            let body = shoppingBody(request)
            XCTAssertEqual(body["household_id"] as? String, self.household.uuidString)
            XCTAssertNil(body["target_price_cents"])
            XCTAssertTrue((body["evidence"] as? [[String: String]])?.first?["detail"]?.contains("Coffee beans") == true)
            return (201, row)
        }
        let result = try await shopping.execute(ShoppingCall(["name": "shopping_suggest", "args": candidate]), taskID: UUID())
        XCTAssertEqual(result["status"] as? String, "suggested"); XCTAssertEqual(shopping.suggestions.count, 1)
    }

    func testModelServiceUsesOnlyBoundedTextAndValidatesEvidence() async throws {
        let model = ShoppingModel()
        model.output = """
        {"suggestions":[{"title":"Coffee filters","category":"kitchen","quantity":1,"rationale":"For the coffee you keep.","confidence":0.8,"evidenceItemIds":["\(inventoryID.uuidString)"]}]}
        """
        let result = try await SuggestionService(client: model).generate(inventory: inventory.activeItems,
            feedback: ["do_not_suggest": [["title": "Tea"]]])
        XCTAssertEqual(result.count, 1)
        let request = try XCTUnwrap(model.lastRequest)
        XCTAssertNotNil(request.outputSchema); XCTAssertTrue(request.tools.isEmpty)
        XCTAssertTrue(request.instructions.contains("Never invent prices"))
        guard case .text(let text) = request.messages[0].content[0] else { return XCTFail("Expected text context") }
        XCTAssertTrue(text.contains("Coffee beans")); XCTAssertTrue(text.contains("do_not_suggest"))
        model.output = #"{"suggestions":[]}"#
        let empty = try await SuggestionService(client: model).generate(inventory: inventory.activeItems, feedback: [:])
        XCTAssertTrue(empty.isEmpty)
    }

    func testAdditionArgumentsRejectInventedFieldsAndBadQuantities() throws {
        for name in ShoppingCall.additions {
            var args: [String: Any] = ["title": "Eggs"]
            if name == "shopping_list_add" { args["listId"] = UUID().uuidString }
            XCTAssertNoThrow(try ShoppingCall(["name": name, "args": args]))
            for value in [true, "2", -1, Double.infinity, 10001] as [Any] {
                var invalid = args; invalid["quantity"] = value
                XCTAssertThrowsError(try ShoppingCall(["name": name, "args": invalid]))
            }
            var invalid = args; invalid["household_id"] = UUID().uuidString
            XCTAssertThrowsError(try ShoppingCall(["name": name, "args": invalid]))
            invalid = args; invalid["title"] = "  "
            XCTAssertThrowsError(try ShoppingCall(["name": name, "args": invalid]))
        }
        XCTAssertThrowsError(try ShoppingCall(["name": "wishlist_add", "args": ["title": "Eggs", "quantity": 1.5]]))
        XCTAssertThrowsError(try ShoppingCall(["name": "shopping_list_add", "args": ["title": "Eggs"]]))
    }

    func testChatInventorySaveUpdatesSharedStoreAndRequiresFreshContext() async throws {
        let taskID = UUID()
        let call = try ShoppingCall(["name": "inventory_add", "args": ["title": "Rice", "quantity": 2, "unit": "bags"]])
        do { _ = try await shopping.execute(call, taskID: taskID); XCTFail("Context required") }
        catch { XCTAssertEqual((error as? BrowserError)?.code, "context_required") }
        _ = try await shopping.execute(ShoppingCall(["name": "shopping_context", "args": [:]]), taskID: taskID)
        var saved = stock; saved["id"] = UUID().uuidString; saved["display_name"] = "Rice"; saved["quantity"] = 2; saved["unit"] = "bags"
        let original = ShoppingHTTP.handler!
        var keys: [String] = []
        ShoppingHTTP.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/v1/inventory")
                let body = shoppingBody(request)
                XCTAssertEqual(body["household_id"] as? String, self.household.uuidString)
                XCTAssertEqual(body["quantity"] as? Int, 2)
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                return (201, saved)
            }
            return original(request)
        }
        let result = try await shopping.execute(call, taskID: taskID)
        XCTAssertEqual(result["status"] as? String, "saved")
        _ = try await shopping.execute(call, taskID: taskID)
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys.first, keys.last)
        XCTAssertEqual(inventory.activeItems.filter { $0.displayName == "Rice" }.count, 1)
        XCTAssertEqual(inventory.activeItems.first { $0.displayName == "Rice" }?.quantity, 2)
    }

    func testChatWishlistSaveUpdatesActiveItemsAndDuplicateIsNotSuccess() async throws {
        let taskID = UUID()
        _ = try await shopping.execute(ShoppingCall(["name": "shopping_context", "args": [:]]), taskID: taskID)
        let call = try ShoppingCall(["name": "wishlist_add", "args": ["title": "Coffee filters"]])
        var saved = row; saved["status"] = "active"; saved["source"] = "user"
        let original = ShoppingHTTP.handler!
        ShoppingHTTP.handler = { request in
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/v1/wishlist")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
                return (201, saved)
            }
            return original(request)
        }
        _ = try await shopping.execute(call, taskID: taskID)
        XCTAssertEqual(shopping.active.count, 1)
        ShoppingHTTP.handler = { _ in (409, ["title": "already_on_wishlist", "detail": "Already on wishlist"]) }
        let result = try await shopping.execute(call, taskID: taskID)
        XCTAssertEqual(result["status"] as? String, "already_exists")
        XCTAssertEqual(shopping.active.count, 1)
    }

    func testChatTimeoutIsUncertainAndSignoutDiscardsLateSave() async throws {
        let taskID = UUID()
        _ = try await shopping.execute(ShoppingCall(["name": "shopping_context", "args": [:]]), taskID: taskID)
        let call = try ShoppingCall(["name": "inventory_add", "args": ["title": "Rice"]])
        ShoppingHTTP.handler = { _ in (503, ["title": "unavailable"]) }
        do { _ = try await shopping.execute(call, taskID: taskID); XCTFail("Must not claim success") }
        catch { XCTAssertEqual((error as? BrowserError)?.code, "outcome_unknown") }
        let requested = expectation(description: "save dispatched")
        let saved = stock
        ShoppingHTTP.delay = 0.15
        ShoppingHTTP.handler = { _ in requested.fulfill(); return (201, saved) }
        let pending = Task { try await self.shopping.execute(call, taskID: taskID) }
        await fulfillment(of: [requested], timeout: 2)
        await calendar.signOut()
        do { _ = try await pending.value; XCTFail("Late result must be discarded") } catch {}
        XCTAssertTrue(inventory.items.isEmpty); XCTAssertTrue(shopping.items.isEmpty)
    }

    func testAgentExposesAdditionToolsAndStopsOnHouseholdChange() async throws {
        let secondHousehold = UUID()
        let profile: [String: Any] = ["households": [
            ["id": household.uuidString, "name": "Home", "locations": []],
            ["id": secondHousehold.uuidString, "name": "Other home", "locations": []]
        ]]
        let original = ShoppingHTTP.handler!
        var writes = 0
        ShoppingHTTP.handler = { request in
            if request.httpMethod == "POST" { writes += 1 }
            if request.url?.path == "/v1/me" { return (200, profile) }
            return original(request)
        }
        await inventory.refresh()
        let entered = expectation(description: "model running")
        let agent = AgentCoordinator(settings: settings, browser: BrowserSession(policy: settings.policy), calendar: calendar, shopping: shopping)
        agent.modelClientOverride = ChatAdditionModel { request in
            XCTAssertTrue(ShoppingCall.additions.isSubset(of: Set(request.tools.map(\.name))))
            entered.fulfill()
            try await Task.sleep(for: .seconds(10))
            return ModelResponse(message: .init(role: .assistant, toolCalls: [
                .init(id: "late", name: "inventory_add", arguments: ["title": .string("Rice")])
            ]))
        }
        XCTAssertTrue(agent.send("Add rice to inventory"))
        await fulfillment(of: [entered], timeout: 2)
        await inventory.selectHousehold(secondHousehold)
        XCTAssertFalse(agent.running); XCTAssertTrue(agent.messages.isEmpty)
        XCTAssertEqual(writes, 0)
    }

    func testStopDuringAdditionReportsUncertainWithoutLateSuccess() async throws {
        let agent = AgentCoordinator(settings: settings, browser: BrowserSession(policy: settings.policy), calendar: calendar, shopping: shopping)
        agent.modelClientOverride = ChatAdditionModel { request in
            let name = request.messages.last?.toolResults.last?.name == "shopping_context" ? "inventory_add" : "shopping_context"
            return ModelResponse(message: .init(role: .assistant, toolCalls: [
                .init(id: UUID().uuidString, name: name, arguments: name == "inventory_add" ? ["title": .string("Rice")] : [:])
            ]))
        }
        let posted = expectation(description: "write dispatched")
        let original = ShoppingHTTP.handler!, saved = stock
        ShoppingHTTP.handler = { request in
            if request.httpMethod == "POST" {
                ShoppingHTTP.delay = 0.25
                posted.fulfill(); return (201, saved)
            }
            return original(request)
        }
        XCTAssertTrue(agent.send("Add rice to inventory"))
        await fulfillment(of: [posted], timeout: 3)
        agent.stop()
        XCTAssertFalse(agent.running); XCTAssertNil(agent.approval)
        XCTAssertTrue(agent.status.contains("may have been saved"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(agent.messages.contains { $0.tool?.status == .complete && $0.tool?.name == "Adding to inventory" })
    }

    func testShoppingViewsRenderLoadedAndEmptyStates() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for selection in ["wishlist", "suggestions"] {
            let view = UIHostingController(rootView: NavigationStack { ShoppingView(store: shopping, settings: settings, selection: selection) })
            window.rootViewController = view; window.makeKeyAndVisible()
            view.view.frame = window.bounds; view.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("shopping-\(selection).png")
            try XCTUnwrap(image.pngData()).write(to: path)
            print("Shopping screenshot: \(path.path)")
            let attachment = XCTAttachment(image: image); attachment.name = selection; attachment.lifetime = .keepAlways
            add(attachment)
        }
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://shopping.example.com"), http: session)
        let trips = TripStore(api: api, inventory: inventory, calendar: calendar)
        let lists = UIHostingController(rootView: ListsView(inventory: inventory, shopping: shopping, settings: settings, trips: trips))
        window.rootViewController = lists; window.makeKeyAndVisible()
        lists.view.frame = window.bounds; lists.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lists-overview.png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("Lists screenshot: \(path.path)")
        let attachment = XCTAttachment(image: image); attachment.name = "Lists overview"; attachment.lifetime = .keepAlways
        add(attachment)
        await calendar.signOut()
        let home = UIHostingController(rootView: HomeView(selectedTab: .constant(.home), store: inventory, shopping: shopping, settings: settings, trips: trips))
        home.loadViewIfNeeded(); home.view.layoutIfNeeded(); XCTAssertNotNil(home.view)
    }
}

@MainActor
private final class ShoppingModel: ModelClient {
    var identity = ModelIdentity(provider: .openAICompatible, model: "fixture")
    var capabilities = ModelCapabilities(structuredOutput: true)
    var output = ""
    var lastRequest: ModelRequest?
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        lastRequest = request
        return ModelResponse(message: .init(role: .assistant, content: [.text(output)]))
    }
}

@MainActor
private final class ChatAdditionModel: ModelClient {
    let identity = ModelIdentity(provider: .openAICompatible, model: "chat-fixture")
    let capabilities = ModelCapabilities(tools: true)
    let handler: (ModelRequest) async throws -> ModelResponse
    init(handler: @escaping (ModelRequest) async throws -> ModelResponse) { self.handler = handler }
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        try await handler(request)
    }
}
