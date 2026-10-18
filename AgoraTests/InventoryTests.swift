import XCTest
import SwiftUI
@testable import Agora

@MainActor
private final class InventoryGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var token = "test-identity"
    var account: GoogleCalendarAccount? = .init(id: "inventory-alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused-access-token" }
    func idToken(for accountID: String) async throws -> String { token }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class InventoryHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any))!
    static var delay: TimeInterval = 0
    /// When set, overrides `delay` per request (for racing writes against a slow refresh).
    static var delayIf: ((URLRequest) -> TimeInterval)?
    private var stopped = false
    private let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, value) = Self.handler(request)
        let delay = Self.delayIf?(request) ?? Self.delay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                                 headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private func requestBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor
final class InventoryTests: XCTestCase {
    private var auth: InventoryGoogle!
    private var calendar: CalendarConnection!
    private var http: URLSession!
    private var store: InventoryStore!
    private let household = UUID(), secondHousehold = UUID(), itemID = UUID(), locationID = UUID(), merchantID = UUID()

    private var row: [String: Any] {
        ["id": itemID.uuidString, "household_id": household.uuidString, "display_name": "Milk", "unit": "cartons",
         "quantity": 1.5, "par_level": 2, "status": "active", "location_id": locationID.uuidString,
         "preferred_merchant_id": merchantID.uuidString, "observed_at": "2026-10-17T19:00:00.123456+00:00", "source": "manual"]
    }
    private var profile: [String: Any] {
        ["households": [["id": household.uuidString, "name": "Home", "locations": [["id": locationID.uuidString, "name": "Fridge", "kind": "fridge"]]],
                        ["id": secondHousehold.uuidString, "name": "Other home", "locations": []]]]
    }
    override func setUp() async throws {
        auth = InventoryGoogle(); calendar = CalendarConnection(authorization: auth)
        await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InventoryHTTP.self]
        http = URLSession(configuration: config)
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://inventory.example.com/api"), http: http)
        store = InventoryStore(api: api, calendar: calendar)
        let profile = profile, row = row
        InventoryHTTP.delay = 0
        InventoryHTTP.delayIf = nil
        InventoryHTTP.handler = { request in
            if request.url!.path.hasSuffix("/me") { return (200, profile) }
            return (200, [row])
        }
        await store.refresh()
        XCTAssertNil(store.error); XCTAssertEqual(store.items.count, 1)
    }
    override func tearDown() async throws {
        http.invalidateAndCancel(); InventoryHTTP.handler = nil; InventoryHTTP.delay = 0; InventoryHTTP.delayIf = nil
        store = nil; calendar = nil; auth = nil
    }

    func testCreateEditObserveArchiveRestoreAndSharedLowStock() async throws {
        var saved = row
        var requests: [(String, String)] = []
        let household = household
        InventoryHTTP.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-identity")
            let body = requestBody(request)
            requests.append((request.httpMethod!, request.url!.path))
            if request.url!.path.hasSuffix("/observations") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(body["quantity"] as? Double, 4)
                return (201, ["time": "2026-10-17T20:00:00Z", "quantity": 4, "source": "manual"])
            }
            if request.httpMethod == "POST" {
                XCTAssertEqual(body["household_id"] as? String, household.uuidString)
                XCTAssertEqual(body["quantity"] as? Double, 1)
            }
            for (key, value) in body { saved[key] = value }
            return (request.httpMethod == "POST" ? 201 : 200, saved)
        }
        var draft = InventoryDraft(); draft.name = "Oat milk"; draft.quantity = "1"; draft.restockLevel = "2"
        let created = try await store.save(draft, original: nil)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(created.displayName, "Oat milk"); XCTAssertTrue(store.activeItems[0].isRunningLow)
        draft = InventoryDraft(item: created); draft.name = "Unsweetened oat milk"
        let edited = try await store.save(draft, original: created)
        XCTAssertEqual(store.items[0].displayName, edited.displayName)
        try await store.updateQuantity(edited, quantity: 4)
        XCTAssertEqual(store.items[0].quantity, 4); XCTAssertFalse(store.activeItems[0].isRunningLow)
        try await store.setArchived(edited, archived: true)
        XCTAssertTrue(store.activeItems.isEmpty); XCTAssertEqual(store.items[0].status, "archived")
        try await store.setArchived(store.items[0], archived: false)
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertEqual(requests.map(\.0), ["POST", "PATCH", "POST", "PATCH", "PATCH"])
    }

    func testPatchOnlyChangedFieldsAndExplicitNulls() throws {
        let original = store.items[0]
        var draft = InventoryDraft(item: original)
        XCTAssertTrue(try draft.body(householdID: household, editing: original).isEmpty)
        draft.locationID = nil; draft.merchantID = nil; draft.restockLevel = ""
        let patch = try draft.body(householdID: household, editing: original)
        XCTAssertEqual(Set(patch.keys), ["location_id", "preferred_merchant_id", "par_level"])
        XCTAssertTrue(patch.values.allSatisfy { $0 is NSNull })
    }

    func testValidationRejectsInvalidNumbersAndAllowsUnknownAndZero() throws {
        for value in ["-1", "10001", "NaN", "inf", "abc"] { XCTAssertThrowsError(try InventoryDraft.number(value)) }
        XCTAssertNil(try InventoryDraft.number("")); XCTAssertEqual(try InventoryDraft.number("0"), 0)
        XCTAssertThrowsError(try InventoryDraft.number("", required: true))
        var draft = InventoryDraft(); draft.name = "   "
        XCTAssertThrowsError(try draft.body(householdID: household))
        draft.name = "Eggs"
        XCTAssertNil(try draft.body(householdID: household)["quantity"])
        draft.quantity = "0"
        XCTAssertEqual(try draft.body(householdID: household)["quantity"] as? Double, 0)
    }

    func testDetailDecodesHistoryDatesAndNullableGaps() async throws {
        var detail = row
        detail["daily"] = [["day": "2026-10-16T00:00:00Z", "quantity": NSNull()], ["day": "2026-10-17T00:00:00+00:00", "quantity": 1.5]]
        detail["observations"] = [["time": "2026-10-17T19:00:00.123456Z", "quantity": 1.5, "source": "scan", "confidence": 0.9]]
        detail["purchase_history"] = [["merchant": ["id": merchantID.uuidString, "name": "Corner Store", "locality": "Ballard"],
                                        "purchased_on": "2026-10-15", "observed_at": "2026-10-17T19:00:00Z", "quantity": 1.5, "detection_id": UUID().uuidString]]
        InventoryHTTP.handler = { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "days", value: "90")])
            return (200, detail)
        }
        let result = try await store.detail(itemID, days: 90)
        XCTAssertEqual(result.item.id, itemID); XCTAssertNotNil(result.item.observedAt)
        XCTAssertNil(result.daily[0].quantity); XCTAssertEqual(result.daily[1].quantity, 1.5)
        XCTAssertEqual(result.purchaseHistory[0].purchasedOn, "2026-10-15")
        XCTAssertEqual(result.purchaseHistory[0].merchant?.label, "Corner Store · Ballard")
    }

    func testHouseholdSwitchUsesQueryAndClearsPreviousItems() async {
        let profile = profile, second = secondHousehold
        InventoryHTTP.handler = { request in
            if request.url!.path.hasSuffix("/me") { return (200, profile) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "household_id", value: second.uuidString)))
            XCTAssertTrue(query.contains(URLQueryItem(name: "include_archived", value: "true")))
            return (200, [])
        }
        await store.selectHousehold(secondHousehold)
        XCTAssertEqual(store.householdID, secondHousehold); XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.locations.isEmpty)
    }

    func testFailedWritesDoNotChangeInventoryAndRefreshKeepsExistingData() async {
        let before = store.items
        InventoryHTTP.handler = { _ in (422, ["title": "invalid_request", "detail": "Quantity is invalid."]) }
        do { try await store.updateQuantity(before[0], quantity: 3); XCTFail("Expected failure") }
        catch { XCTAssertEqual(InventoryStore.message(error), "Quantity is invalid.") }
        XCTAssertEqual(store.items, before)
        await store.refresh()
        XCTAssertEqual(store.items, before); XCTAssertEqual(store.error, "Quantity is invalid.")
        XCTAssertFalse(store.loading); XCTAssertTrue(calendar.connected)
    }

    func testSignOutClearsStateAndDiscardsInflightResponse() async throws {
        let requested = expectation(description: "refresh dispatched")
        let profile = profile
        InventoryHTTP.delay = 0.2
        InventoryHTTP.handler = { _ in requested.fulfill(); return (200, profile) }
        let task = Task { await store.refresh() }
        await fulfillment(of: [requested], timeout: 2)
        await calendar.signOut()
        XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.households.isEmpty); XCTAssertNil(store.householdID)
        await task.value
        XCTAssertTrue(store.items.isEmpty); XCTAssertTrue(store.households.isEmpty); XCTAssertNil(store.error)
    }

    func testLocationsAndMerchantSearchCreateUseHouseholdAndEncodedQuery() async throws {
        let household = household, locationID = UUID(), merchantID = merchantID
        InventoryHTTP.handler = { request in
            if request.url!.path.hasSuffix("/locations") {
                XCTAssertTrue(request.url!.path.contains(household.uuidString))
                XCTAssertEqual(requestBody(request)["kind"] as? String, "freezer")
                return (201, ["id": locationID.uuidString, "name": "Garage freezer", "kind": "freezer"])
            }
            let merchant: [String: Any] = ["id": merchantID.uuidString, "name": "A&B + Market", "locality": "North"]
            if request.httpMethod == "POST" {
                XCTAssertEqual(requestBody(request)["household_id"] as? String, household.uuidString)
                return (200, ["merchant": merchant, "created": false])
            }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "q", value: "A&B + Market")))
            return (200, [merchant])
        }
        let location = try await store.addLocation(name: "Garage freezer", kind: "freezer")
        XCTAssertTrue(store.locations.contains(location))
        let found = try await store.merchants(search: "A&B + Market")
        let merchant = try await store.addMerchant(name: "A&B + Market", locality: "North")
        XCTAssertEqual(found.first, merchant)
    }

    func testAddLocationIsNotClobberedByInFlightRefresh() async throws {
        let newID = UUID()
        let staleProfile = profile
        let row = row
        InventoryHTTP.delayIf = { request in request.url!.path.contains("/locations") ? 0 : 0.25 }
        InventoryHTTP.handler = { request in
            if request.url!.path.contains("/locations") {
                return (201, ["id": newID.uuidString, "name": "Garage freezer", "kind": "freezer"])
            }
            if request.url!.path.hasSuffix("/me") { return (200, staleProfile) }
            return (200, [row])
        }
        let refresh = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        let location = try await store.addLocation(name: "Garage freezer", kind: "freezer")
        XCTAssertEqual(location.id, newID)
        XCTAssertTrue(store.locations.contains(where: { $0.id == newID }))
        await refresh.value
        XCTAssertTrue(store.locations.contains(where: { $0.id == newID }),
                      "A refresh that started before addLocation must not drop the new location")
        XCTAssertEqual(store.locations.filter { $0.id == newID }.count, 1)
    }
}

// Optional live integration: run the isolated dev API on loopback port 18765.
// Only this test transport rewrites HTTPS to loopback; production origin/auth rules stay unchanged.
private final class InventoryLiveHTTP: URLProtocol {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "inventory-live.example.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = 18765
        forwarded.url = components.url
        if request.httpBodyStream != nil {
            forwarded.httpBodyStream = nil
            forwarded.httpBody = try? JSONSerialization.data(withJSONObject: requestBody(request))
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
final class InventoryLiveTests: XCTestCase {
    func testInventoryLifecycleAgainstRealBackend() async throws {
        var login = URLRequest(url: URL(string: "http://127.0.0.1:18765/v1/dev/login")!)
        login.timeoutInterval = 2; login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["handle": "ios_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: login) }
        catch { throw XCTSkip("Isolated inventory test API is not running on localhost:18765") }
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String)
        let auth = InventoryGoogle(); auth.token = token
        let calendar = CalendarConnection(authorization: auth); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InventoryLiveHTTP.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://inventory-live.example.com"), http: http)
        let store = InventoryStore(api: api, calendar: calendar)
        await store.refresh()
        XCTAssertNil(store.error); XCTAssertNotNil(store.householdID); XCTAssertTrue(store.items.isEmpty)
        let location = try await store.addLocation(name: "Test pantry", kind: "pantry")
        let merchant = try await store.addMerchant(name: "A&B + Market", locality: "Ballard")
        let found = try await store.merchants(search: "A&B + Market")
        XCTAssertTrue(found.contains { $0.id == merchant.id })
        var draft = InventoryDraft(); draft.name = "Oat milk"; draft.quantity = "1.5"; draft.unit = "cartons"
        draft.restockLevel = "2"; draft.locationID = location.id; draft.merchantID = merchant.id
        let created = try await store.save(draft, original: nil)
        XCTAssertTrue(created.isRunningLow); XCTAssertEqual(created.preferredMerchantId, merchant.id)
        try await screenshot(NavigationStack { InventoryListView(store: store) }, name: "Inventory list")
        try await screenshot(NavigationStack { InventoryDetailView(store: store, itemID: created.id) }, name: "Inventory detail")
        try await screenshot(InventoryEditor(store: store, original: created), name: "Inventory edit")
        await store.refresh()
        XCTAssertEqual(store.items.first?.id, created.id)
        var edit = InventoryDraft(item: created); edit.name = "Unsweetened oat milk"
        edit.locationID = nil; edit.merchantID = nil; edit.restockLevel = ""
        let edited = try await store.save(edit, original: created)
        XCTAssertNil(edited.locationId); XCTAssertNil(edited.preferredMerchantId); XCTAssertNil(edited.parLevel)
        try await store.updateQuantity(edited, quantity: 0)
        XCTAssertEqual(store.items.first?.quantity, 0)
        let detail = try await store.detail(created.id, days: 7)
        XCTAssertEqual(detail.item.quantity, 0); XCTAssertEqual(detail.daily.count, 7)
        XCTAssertEqual(detail.observations.count, 2); XCTAssertEqual(detail.observations.first?.source, "manual")
        try await store.setArchived(store.items[0], archived: true)
        await store.refresh()
        XCTAssertTrue(store.activeItems.isEmpty); XCTAssertEqual(store.items.count, 1)
        try await store.setArchived(store.items[0], archived: false)
        await store.refresh()
        XCTAssertEqual(store.activeItems.count, 1)
        XCTAssertEqual(store.activeItems[0].displayName, "Unsweetened oat milk")
        await calendar.signOut()
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(store.householdID)
    }

    private func screenshot<Content: View>(_ content: Content, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: content)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class InventoryRecognitionFixture: InventoryRecognizing {
    var delay = false
    func recognize(file: URL, kind: CaptureItem.Kind, progress: @escaping @MainActor (CaptionProgress) -> Void,
                   cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> [RecognizedItem] {
        if delay { try await Task.sleep(for: .milliseconds(100)) }
        return [.init(name: "Milk", category: "dairy", unit: "cartons", quantity: 3, confidence: 0.92),
                .init(name: "Uncertain jar", category: "other", unit: "unit", quantity: 1, confidence: 0.3)]
    }
}

extension InventoryTests {
    private func captureLibrary() async throws -> (MediaLibrary, CaptureItem) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MediaLibrary(directory: directory)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 48)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        }
        try XCTUnwrap(photo.jpegData(compressionQuality: 0.8)).write(to: source)
        await library.add(file: source, kind: .image)
        return (library, try XCTUnwrap(library.items.first))
    }
    private func recognized(_ item: CaptureItem, library: MediaLibrary) async throws -> RecognitionController {
        let controller = RecognitionController()
        controller.recognize(item: item, file: library.url(for: item), model: "gemini-flash-latest",
                             provider: InventoryRecognitionFixture(), store: store)
        while controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.drafts.count, 2)
        XCTAssertEqual(controller.drafts[0].inventoryItemID, itemID)
        return controller
    }

    func testRecognitionReviewExcludesRejectedItemsAndRetriesIdenticalPersistedMetadata() async throws {
        let (library, item) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let controller = try await recognized(item, library: library)
        controller.drafts[0].quantity = "4.5"
        controller.drafts[1].included = false
        let savedRow = row, recognitionID = UUID()
        var keys: [String] = [], bodies: [NSDictionary] = []
        InventoryHTTP.handler = { request in
            XCTAssertTrue(request.url!.path.hasSuffix("/inventory/recognitions"))
            let body = requestBody(request)
            XCTAssertEqual(Set(body.keys), Set(["household_id", "captured_at", "media_kind", "model", "items"]))
            let items = body["items"] as! [[String: Any]]
            XCTAssertEqual(items.count, 1); XCTAssertEqual(items[0]["quantity"] as? Double, 4.5)
            XCTAssertEqual(items[0]["inventory_item_id"] as? String, self.itemID.uuidString)
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
            bodies.append(body as NSDictionary)
            if keys.count == 1 { return (503, ["title": "unavailable", "detail": "Try again"]) }
            var row = savedRow; row["quantity"] = 4.5
            return (201, ["recognition_id": recognitionID.uuidString, "items": [row]])
        }
        await controller.save(item: item, store: store, library: library)
        XCTAssertTrue(controller.locked); XCTAssertFalse(controller.completed)
        let reloaded = MediaLibrary(directory: library.directory); await reloaded.load()
        let saved = try XCTUnwrap(reloaded.items.first?.recognition)
        let retry = RecognitionController(); retry.restore(saved)
        // Frozen payload survives restart and cannot change even if a UI draft is mutated.
        retry.drafts[0].quantity = "99"
        await retry.save(item: item, store: store, library: reloaded)
        XCTAssertTrue(retry.completed); XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(keys[0], keys[1]); XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(store.items.first?.quantity, 4.5)
        await reloaded.load(); XCTAssertEqual(reloaded.items[0].recognition?.recognitionID, recognitionID)
        await retry.save(item: item, store: store, library: reloaded)
        XCTAssertEqual(keys.count, 2)
    }

    func testRecognitionValidationRollbackAllowsCorrectionsWithNewKey() async throws {
        let (library, item) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let controller = try await recognized(item, library: library)
        var requests = 0, keys: [String] = []
        let row = row
        InventoryHTTP.handler = { request in
            requests += 1; keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
            if requests == 1 { return (422, ["title": "invalid_request", "detail": "Invalid purchase date"]) }
            return (201, ["recognition_id": UUID().uuidString, "items": [row]])
        }
        controller.drafts[0].quantity = "-1"
        await controller.save(item: item, store: store, library: library)
        XCTAssertEqual(requests, 0)
        controller.drafts[0].quantity = "2"
        await controller.save(item: item, store: store, library: library)
        XCTAssertFalse(controller.locked); XCTAssertTrue(library.items[0].recognition!.rejected)
        await controller.save(item: item, store: store, library: library)
        XCTAssertTrue(controller.completed); XCTAssertNotEqual(keys[0], keys[1])
    }

    func testRecognitionCannotSaveWhenLocalPersistenceFailsOrAccountChanges() async throws {
        let (library, item) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let controller = try await recognized(item, library: library)
        InventoryHTTP.handler = { _ in XCTFail("No backend write is allowed"); return (500, [:]) }
        await library.remove(item)
        await controller.save(item: item, store: store, library: library)
        XCTAssertFalse(controller.locked)
        let provider = InventoryRecognitionFixture(); provider.delay = true
        let other = RecognitionController()
        other.recognize(item: item, file: library.url(for: item), model: "gemini-flash-latest", provider: provider, store: store)
        await calendar.signOut()
        while other.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(other.drafts.isEmpty)
        await controller.save(item: item, store: store, library: library)
        XCTAssertFalse(controller.completed)
    }
}

extension InventoryLiveTests {
    func testGeminiCaptureReviewSaveAgainstRealBackend() async throws {
        var login = URLRequest(url: URL(string: "http://127.0.0.1:18765/v1/dev/login")!)
        login.timeoutInterval = 2; login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: ["handle": "recognition_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)])
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: login) }
        catch { throw XCTSkip("Isolated inventory test API is not running on localhost:18765") }
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["access_token"] as? String)
        let auth = InventoryGoogle(); auth.token = token
        let calendar = CalendarConnection(authorization: auth); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [InventoryLiveHTTP.self]
        let http = URLSession(configuration: config); defer { http.invalidateAndCancel() }
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://inventory-live.example.com"), http: http)
        let store = InventoryStore(api: api, calendar: calendar); await store.refresh()
        XCTAssertNil(store.error)
        var original = InventoryDraft(); original.name = "Milk"; original.unit = "cartons"; original.quantity = "9"
        let milk = try await store.save(original, original: nil)
        let merchant = try await store.addMerchant(name: "Capture market", locality: "")
        let location = try await store.addLocation(name: "Capture pantry", kind: "pantry")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = MediaLibrary(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.8)).write(to: source)
        await library.add(file: source, kind: .image)
        let capture = try XCTUnwrap(library.items.first)
        let google = CaptionTests.MockHTTP()
        google.dataHandler = { request in
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
            let items: [[String: Any]] = [
                ["name": "Milk", "unit": "cartons", "category": "dairy", "quantity": 3, "confidence": 0.92],
                ["name": "Eggs", "unit": "unit", "category": "dairy", "quantity": 10, "confidence": 0.9],
                ["name": "Uncertain jar", "unit": "unit", "category": "other", "quantity": 1, "confidence": 0.3]]
            let text = String(data: try JSONSerialization.data(withJSONObject: ["items": items]), encoding: .utf8)!
            return (try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]]]),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let controller = RecognitionController()
        let settings = SettingsStore(keychainService: "test-auto-live-" + UUID().uuidString)
        let provider = GeminiInventoryService(key: "mock-only", model: "gemini-flash-latest", http: google)
        controller.generateIfNeeded(item: capture, file: library.url(for: capture), settings: settings, store: store, provider: provider)
        controller.setStoreName(merchant.name)
        controller.generateIfNeeded(item: capture, file: library.url(for: capture), settings: settings, store: store, provider: provider)
        while controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(controller.message); XCTAssertEqual(controller.drafts.count, 3)
        XCTAssertEqual(store.items.count, 1); XCTAssertEqual(store.items[0].quantity, 9) // Review has no writes.
        XCTAssertEqual(controller.drafts[0].inventoryItemID, milk.id)
        controller.drafts[0].quantity = "2.5"; controller.drafts[1].quantity = "12"; controller.drafts[2].included = false
        XCTAssertEqual(controller.storeName, merchant.name)
        XCTAssertNil(controller.merchant) // A typed name is resolved only when Add to inventory is tapped.
        XCTAssertEqual(google.requests.count, 1)
        controller.locationID = location.id
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"; date.locale = Locale(identifier: "en_US_POSIX")
        controller.purchasedOn = date.string(from: Date())
        try await screenshot(RecognitionView(item: capture, url: library.url(for: capture), settings: SettingsStore(),
                                             store: store, library: library, controller: controller), name: "Capture inventory review")
        await controller.save(item: capture, store: store, library: library)
        XCTAssertTrue(controller.completed, controller.message ?? "No response")
        XCTAssertEqual(store.items.count, 2)
        let detail = try await store.detail(milk.id, days: 7)
        XCTAssertEqual(detail.item.quantity, 2.5); XCTAssertEqual(detail.observations.count, 2)
        XCTAssertEqual(detail.purchaseHistory.count, 1); XCTAssertEqual(detail.purchaseHistory[0].merchant?.id, merchant.id)
        let eggs = try XCTUnwrap(store.items.first { $0.displayName == "Eggs" })
        XCTAssertEqual(eggs.quantity, 12); XCTAssertEqual(eggs.locationId, location.id)
        let saved = try XCTUnwrap(library.items.first?.recognition)
        let replay = try await store.saveRecognition(saved)
        XCTAssertEqual(replay.recognitionId, saved.recognitionID)
        let replayDetail = try await store.detail(milk.id, days: 7)
        XCTAssertEqual(replayDetail.observations.count, 2)
        await store.refresh(); XCTAssertEqual(store.items.count, 2)
        try await screenshot(NavigationStack { InventoryListView(store: store) }, name: "Inventory after capture")
        try await screenshot(NavigationStack { InventoryDetailView(store: store, itemID: milk.id) }, name: "Capture purchase history")
        let restored = MediaLibrary(directory: directory); await restored.load()
        XCTAssertEqual(restored.items.first?.recognition?.recognitionID, replay.recognitionId)
    }
}


@MainActor
private final class SuspendedInventoryRecognition: InventoryRecognizing {
    var calls = 0
    private var continuation: CheckedContinuation<[RecognizedItem], Error>?
    func recognize(file: URL, kind: CaptureItem.Kind, progress: @escaping @MainActor (CaptionProgress) -> Void,
                   cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> [RecognizedItem] {
        calls += 1; progress(.generating)
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: [.init(name: "Milk", category: "dairy", unit: "cartons", quantity: 2, confidence: 0.9)])
        continuation = nil
    }
}

extension InventoryTests {
    func testAutomaticRecognitionStartsOnceWithoutBackendAndPreservesStoreInput() async throws {
        let (library, capture) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        store.reset(accountID: nil)
        InventoryHTTP.handler = { _ in XCTFail("Recognition and typing must not call Agora"); return (500, [:]) }
        let controller = RecognitionController(), provider = SuspendedInventoryRecognition()
        defer { provider.finish() }
        let settings = SettingsStore(keychainService: "test-auto-" + UUID().uuidString)
        for _ in 0..<3 {
            controller.generateIfNeeded(item: capture, file: library.url(for: capture), settings: settings, store: store, provider: provider)
        }
        while provider.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(controller.busy); XCTAssertFalse(controller.saving)
        controller.setStoreName("Cost")
        controller.setStoreName("Costco")
        controller.purchasedOn = "2026-10-17"
        provider.finish()
        while controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.drafts.first?.name, "Milk")
        XCTAssertEqual(controller.storeName, "Costco"); XCTAssertEqual(controller.purchasedOn, "2026-10-17")
        XCTAssertNil(controller.message)
        controller.generateIfNeeded(item: capture, file: library.url(for: capture), settings: settings, store: store, provider: provider)
        XCTAssertEqual(provider.calls, 1)
    }

    func testTypedStoreIsResolvedAndAttachedOnlyOnAddToInventory() async throws {
        let (library, item) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let controller = try await recognized(item, library: library)
        controller.drafts[1].included = false
        controller.setStoreName("Costco")
        let merchantID = merchantID, row = row
        var paths: [String] = []
        InventoryHTTP.handler = { request in
            paths.append(request.url!.path)
            let body = requestBody(request)
            if request.url!.path.hasSuffix("/merchants") {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(body["name"] as? String, "Costco")
                XCTAssertEqual(body["locality"] as? String, "")
                return (200, ["merchant": ["id": merchantID.uuidString, "name": "Costco"]])
            }
            XCTAssertTrue(request.url!.path.hasSuffix("/inventory/recognitions"))
            XCTAssertEqual(body["purchased_from_merchant_id"] as? String, merchantID.uuidString)
            XCTAssertEqual((body["items"] as? [[String: Any]])?.count, 1)
            return (201, ["recognition_id": UUID().uuidString, "items": [row]])
        }
        XCTAssertTrue(paths.isEmpty)
        await controller.save(item: item, store: store, library: library)
        XCTAssertTrue(controller.completed, controller.message ?? "No message")
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(library.items[0].purchasedFrom, "Costco")
        XCTAssertEqual(library.items[0].recognition?.merchantID, merchantID)
    }

    func testStoreFieldStaysEditableAndFocusedWhenRecognitionFinishes() async throws {
        let (library, item) = try await captureLibrary()
        defer { try? FileManager.default.removeItem(at: library.directory) }
        let controller = RecognitionController(), provider = SuspendedInventoryRecognition()
        defer { provider.finish() }
        let settings = SettingsStore(keychainService: "test-auto-" + UUID().uuidString)
        controller.generateIfNeeded(item: item, file: library.url(for: item), settings: settings, store: store, provider: provider)
        while provider.calls == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: RecognitionView(item: item, url: library.url(for: item), settings: settings,
                                                                 store: store, library: library, controller: controller))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        func textFields(_ view: UIView) -> [UITextField] {
            (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(textFields)
        }
        let field = try XCTUnwrap(textFields(host.view).first { $0.placeholder?.contains("Store or website") == true })
        XCTAssertTrue(field.isEnabled, "Store must be editable before Gemini returns")
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "Costco"
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.storeName, "Costco")
        func attach(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways
            add(attachment)
        }
        attach("Entering store while Gemini identifies")
        provider.finish()
        while controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.storeName, "Costco"); XCTAssertEqual(field.text, "Costco")
        XCTAssertTrue(field.isFirstResponder, "Recognition must not dismiss the keyboard")
        XCTAssertTrue(field.isEnabled); XCTAssertEqual(provider.calls, 1)
        field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(200))
        attach("Identified item with purchase store")
    }
}
