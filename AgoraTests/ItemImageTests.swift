import XCTest
import SwiftUI
@testable import Agora

@MainActor
private final class ImageGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "images-alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { "image-token" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class ImageHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class ItemImageTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var api: AgoraClient!
    private var store: ItemImageStore!
    private var http: URLSession!
    private let ref = ItemImageReference(kind: "inventory", id: UUID(), name: "Oat milk", category: "dairy")
    private let assetID = UUID()
    private var data: Data { UIImage(named: "Item-milk")!.pngData()! }
    private func descriptor(asset: Bool = true, status: String = "ready") -> Data {
        try! JSONSerialization.data(withJSONObject: ["status": status, "fallback": "milk", "choices": [],
            "user_selected": false, "inherited": false, "version": 1,
            "asset": asset ? ["id": assetID.uuidString, "path": "v1/item-images/assets/\(assetID)",
                              "source_url": "https://manufacturer.example/milk", "attribution": "Source image", "match_kind": "product",
                              "verification": ["version": 2, "status": "exact", "basis": "gtin"]] : NSNull()])
    }
    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ImageHTTP.self]
        http = URLSession(configuration: config)
        calendar = CalendarConnection(authorization: ImageGoogle())
        await calendar.connect()
        api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://images-api.example"), http: http)
        store = ItemImageStore(api: api, calendar: calendar)
    }
    override func tearDown() async throws {
        store.reset(); http.invalidateAndCancel(); ImageHTTP.handler = nil
    }

    func testLoadsAuthenticatedImageAndSharesCacheAcrossViews() async throws {
        let response = descriptor(), image = data
        var requests: [URLRequest] = []
        ImageHTTP.handler = { request in
            requests.append(request)
            return (200, request.url!.path.contains("/assets/") ? image : response)
        }
        async let first: Void = store.load(ref)
        async let second: Void = store.load(ref)
        _ = await (first, second)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer image-token" })
        XCTAssertNotNil(store.pictures[assetID])
        await store.load(ref)
        XCTAssertEqual(requests.count, 2)
    }

    func testVisibleInventoryAutomaticallyRecoversAfterImageServiceFailure() async throws {
        let response = descriptor(), image = data
        var reads = 0
        ImageHTTP.handler = { request in
            if request.url!.path.contains("/assets/") { return (200, image) }
            reads += 1
            return reads == 1 ? (503, Data()) : (200, response)
        }
        let observing = Task { await store.observe(ref, interval: .milliseconds(10)) }
        defer { observing.cancel() }
        for _ in 0..<100 where store.pictures[assetID] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.pictures[assetID])
        XCTAssertNil(store.loadMessages[ref])
        XCTAssertEqual(reads, 2, "Automatic checks reuse the descriptor cache after recovery")
        store.reset(context: "another-household")
        await observing.value
        XCTAssertTrue(store.pictures.isEmpty)
        XCTAssertEqual(reads, 2, "An old observer must stop when the household changes")
    }

    func testPrefetchVisitsEntireInventoryWhileFirstSearchesArePending() async throws {
        let references = (0..<12).map { ItemImageReference(kind: "inventory", id: UUID(), name: "Item \($0)") }
        let pending = Set(references.prefix(4).map { $0.id.uuidString.lowercased() })
        let ready = descriptor(), queued = descriptor(asset: false, status: "queued"), image = data
        var paths = Set<String>()
        ImageHTTP.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET", "Startup must never ask for a manual selection")
            let path = request.url!.path
            paths.insert(path)
            if path.contains("/assets/") { return (200, image) }
            return (200, pending.contains(request.url!.lastPathComponent.lowercased()) ? queued : ready)
        }
        await store.prefetch(references + references)
        XCTAssertEqual(store.descriptors.count, references.count)
        XCTAssertTrue(references.allSatisfy { paths.contains("/" + $0.path) })
        XCTAssertEqual(store.descriptors[references[0]]?.status, "queued")
        XCTAssertNotNil(store.pictures[assetID], "Later inventory images load before early searches finish")
        let count = paths.count
        await store.prefetch(references)
        XCTAssertEqual(paths.count, count)
    }

    func testAppStartupPreloadsEveryInventoryImageWithoutRenderingThumbnails() async throws {
        let inventory = InventoryStore(api: api, calendar: calendar)
        let household = UUID()
        let ids = (0..<12).map { _ in UUID() }
        let profile = try JSONSerialization.data(withJSONObject: ["households": [
            ["id": household.uuidString, "name": "Home", "locations": []] as [String: Any]
        ]])
        var rows = try JSONSerialization.data(withJSONObject: ids.enumerated().map { index, id in
            ["id": id.uuidString, "household_id": household.uuidString, "display_name": "Item \(index)",
             "unit": "unit", "status": index == 11 ? "archived" : "active"]
        })
        let template = try JSONSerialization.jsonObject(with: descriptor()) as! [String: Any], image = data
        let queued = descriptor(asset: false, status: "queued")
        var firstPending = true
        var requestedImages = Set<String>()
        ImageHTTP.handler = { request in
            let path = request.url!.path
            if path == "/v1/me" { return (200, profile) }
            if path == "/v1/inventory" { return (200, rows) }
            if path.contains("/assets/") {
                requestedImages.insert(request.url!.lastPathComponent.lowercased())
                return (200, image)
            }
            if request.url!.lastPathComponent.lowercased() == ids[0].uuidString.lowercased(), firstPending {
                firstPending = false
                return (200, queued)
            }
            var result = template
            var asset = result["asset"] as! [String: Any]
            let id = request.url!.lastPathComponent
            asset["id"] = id; asset["path"] = "v1/item-images/assets/\(id)"
            result["asset"] = asset
            return (200, try! JSONSerialization.data(withJSONObject: result))
        }
        let host = UIHostingController(rootView: ItemImageSessionSync(store: store, inventory: inventory)
            .environment(\.scenePhase, .active))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        await inventory.refresh()
        for _ in 0..<2000 where store.pictures.count < ids.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(requestedImages, Set(ids.map { $0.uuidString.lowercased() }))
        XCTAssertEqual(store.pictures.count, ids.count)
        XCTAssertEqual(store.descriptors.count, ids.count)
        let added = UUID()
        var updated = try JSONSerialization.jsonObject(with: rows) as! [[String: Any]]
        updated.append(["id": added.uuidString, "household_id": household.uuidString,
                        "display_name": "New inventory item", "unit": "unit", "status": "active"])
        rows = try JSONSerialization.data(withJSONObject: updated)
        await inventory.refresh()
        for _ in 0..<200 where store.pictures[added] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(store.pictures[added], "New inventory joins automatic loading without a screen visit")
        await calendar.signOut()
        XCTAssertTrue(store.pictures.isEmpty)
        XCTAssertTrue(store.descriptors.isEmpty)
    }

    func testNeverSendsCredentialsToExternalImagePath() async throws {
        ImageHTTP.handler = { _ in XCTFail("No network request is allowed"); return (500, Data()) }
        for path in ["https://attacker.example/a.jpg", "v1/item-images/assets/../../me", "v1/item-images/assets/not-a-uuid"] {
            do { _ = try await api.imageData(path); XCTFail("Invalid path accepted") }
            catch { XCTAssertEqual((error as? BrowserError)?.code, "invalid_image_path") }
        }
    }

    func testSignOutAndHouseholdChangeClearPrivateImages() async throws {
        let response = descriptor(), image = data
        ImageHTTP.handler = { (200, $0.url!.path.contains("/assets/") ? image : response) }
        await store.load(ref)
        XCTAssertFalse(store.pictures.isEmpty)
        store.reset(context: "another-household")
        XCTAssertTrue(store.pictures.isEmpty); XCTAssertTrue(store.descriptors.isEmpty)
        await store.load(ref)
        await calendar.signOut()
        XCTAssertTrue(store.pictures.isEmpty); XCTAssertTrue(store.descriptors.isEmpty)
    }

    func testOfflineAndOldServerKeepImagesUnresolved() async throws {
        ImageHTTP.handler = { _ in (404, Data()) }
        await store.load(ref)
        XCTAssertNil(store.descriptors[ref])
        XCTAssertEqual(store.loadMessages[ref], "The image service isn't available yet. Try again shortly.")
        let restoredResponse = descriptor(), restoredImage = data
        ImageHTTP.handler = { (200, $0.url!.path.contains("/assets/") ? restoredImage : restoredResponse) }
        await store.load(ref, force: true)
        XCTAssertNil(store.loadMessages[ref])
        XCTAssertNotNil(store.pictures[assetID])
        for kind in ["milk", "eggs", "produce", "bread", "drink", "cleaning", "cookware", "electronics", "food", "item"] {
            XCTAssertNotNil(UIImage(named: "Item-\(kind)"))
        }
        XCTAssertEqual(RepresentativeImage.kind(name: "Oatly milk", category: nil), "milk")
        XCTAssertEqual(RepresentativeImage.kind(name: "Large eggs", category: "dairy"), "eggs")
        XCTAssertEqual(RepresentativeImage.kind(name: "Rice", category: "pantry"), "food")
    }

    func testSelectionRetriesUseSameIdempotencyKeyAndInvalidateInheritedImages() async throws {
        let response = descriptor(), image = data
        var keys: [String] = []
        ImageHTTP.handler = { request in
            if request.httpMethod == "PUT" {
                keys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                return (keys.count == 1 ? 503 : 200, response)
            }
            return (200, request.url!.path.contains("/assets/") ? image : response)
        }
        await store.load(ref)
        do { try await store.select(ref, mode: "representative"); XCTFail("Expected transient error") } catch {}
        let revision = store.revision
        try await store.select(ref, mode: "representative")
        XCTAssertEqual(store.revision, revision + 1, "Visible linked thumbnails must refetch after selection")
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1])
        XCTAssertNotNil(store.descriptors[ref])
    }

    func testLegacyAutomaticImagesAreHiddenButExplicitChoicesRemainVisible() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var raw = try JSONSerialization.jsonObject(with: descriptor()) as! [String: Any]
        var asset = raw["asset"] as! [String: Any]; asset.removeValue(forKey: "verification"); raw["asset"] = asset
        var decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(decoded.displayAsset)
        XCTAssertEqual(decoded.imageLabel, "No matching image found")
        raw["user_selected"] = true
        decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNotNil(decoded.displayAsset)
        XCTAssertEqual(decoded.imageLabel, "Image you selected")
        let identity = ItemProductIdentity(name: "Whole milk", brand: "Fairlife", variant: "Whole",
                                           size: "52 fl oz", packCount: 1)
        XCTAssertEqual(identity.body["pack_count"] as? Int, 1)
        XCTAssertEqual(identity.body["size"] as? String, "52 fl oz")
        XCTAssertNil(identity.body["gtin"])
    }

    func testAutomaticBestMatchDisplaysWithoutConfirmation() async throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var raw = try JSONSerialization.jsonObject(with: descriptor()) as! [String: Any]
        var candidate = raw["asset"] as! [String: Any]
        candidate["verification"] = ["version": 2, "status": "candidate", "basis": "name_candidate"]
        candidate["title"] = "PS5 digital edition console"
        raw["choices"] = [candidate]; raw["asset"] = candidate; raw["status"] = "ready"
        raw["match_status"] = "best_match"
        var decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNotNil(decoded.displayAsset)
        XCTAssertEqual(decoded.imageLabel, "Automatically selected image")
        XCTAssertEqual(decoded.choices.first?.title, "PS5 digital edition console")
        raw["asset"] = NSNull(); raw["status"] = "fallback"; raw["match_status"] = "needs_confirmation"
        decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNotNil(decoded.displayAsset, "Existing alternatives should also appear in the main thumbnail")
        let response = try JSONSerialization.data(withJSONObject: raw), image = data
        ImageHTTP.handler = { (200, $0.url!.path.contains("/assets/") ? image : response) }
        await store.load(ref)
        XCTAssertNotNil(store.pictures[assetID], "The main thumbnail must load the automatic alternative's image bytes")
        raw["user_selected"] = true
        decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(decoded.displayAsset, "An explicit removal must remain removed")
        raw["asset"] = candidate; raw["user_selected"] = true
        decoded = try decoder.decode(ItemImageDescriptor.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNotNil(decoded.displayAsset)
    }

    func testRenderProductAndRepresentativeImages() async throws {
        let response = descriptor(), image = data
        ImageHTTP.handler = { (200, $0.url!.path.contains("/assets/") ? image : response) }
        await store.load(ref)
        let view = NavigationStack {
            List {
                Section("Inventory") {
                    HStack {
                        ItemThumbnail(kind: ref.kind, id: ref.id, name: ref.name, category: ref.category, size: 72)
                        VStack(alignment: .leading) { Text("Oatly Original oat milk").font(.headline); Text("1 carton · Fridge").foregroundStyle(.secondary) }
                    }
                    HStack { RepresentativeImage(name: "Apples").frame(width: 72, height: 72); Text("Apples"); Spacer(); Text("4 left") }
                    HStack { RepresentativeImage(name: "Cast iron skillet").frame(width: 72, height: 72); Text("Cast iron skillet") }
                }
                Section { Text("Unavailable images are shown explicitly; sample artwork is labeled.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("Item images")
        }.environment(\.itemImages, store)
        let host = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852)); window.rootViewController = host
        window.makeKeyAndVisible(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let rendered = UIGraphicsImageRenderer(size: window.bounds.size).image { window.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: rendered); attachment.name = "Item images"; attachment.lifetime = .keepAlways
        add(attachment); window.isHidden = true
    }
}
