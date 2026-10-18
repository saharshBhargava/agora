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
