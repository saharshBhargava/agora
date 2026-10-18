import XCTest
import SwiftUI
@testable import Agora

// Only this test transport rewrites the synthetic HTTPS origin to an isolated local API.
private final class ImageLiveHTTP: URLProtocol {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "images-live.example.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var forwarded = request
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = 18765
        forwarded.url = components.url
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
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
private final class ImageLiveSession: DemoSessionStoring {
    var session: DemoSession?
    func load() throws -> DemoSession? { session }
    func save(_ session: DemoSession?) throws { self.session = session }
}

@MainActor
final class ItemImageLiveTests: XCTestCase {
    func testImagesPersistAcrossAppRestartAndLinkedListsAgainstRealBackend() async throws {
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:18765/healthz")!)
        probe.timeoutInterval = 2
        do { _ = try await URLSession.shared.data(for: probe) }
        catch { throw XCTSkip("Start the isolated API with tests.support.ios_inventory_server on port 18765.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageLiveHTTP.self]
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let origin = URL(string: "https://images-live.example.com")!
        let session = ImageLiveSession()
        let calendar = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await calendar.connectDemo(handle: "demo", password: "")
        XCTAssertTrue(calendar.connected, calendar.message ?? "Start tests.support.ios_inventory_server on port 18765.")
        let api = AgoraClient(calendar: calendar, baseURL: origin, http: http)
        let inventory = InventoryStore(api: api, calendar: calendar)
        await inventory.refresh()
        XCTAssertNil(inventory.error)
        let item = try XCTUnwrap(inventory.items.first { $0.displayName.contains("milk") })
        let ref = ItemImageReference(kind: "inventory", id: item.id, name: item.displayName, category: item.category)
        let images = ItemImageStore(api: api, calendar: calendar)
        await images.load(ref)
        let initial = try XCTUnwrap(images.descriptors[ref])
        XCTAssertEqual(initial.status, "ready")
        XCTAssertEqual(initial.asset?.matchKind, "representative")
        XCTAssertNotNil(images.pictures[try XCTUnwrap(initial.asset).id])

        let photo = try XCTUnwrap(UIImage(named: "Item-milk")?.jpegData(compressionQuality: 0.9))
        try await images.select(ref, mode: "photo", photo: photo)
        let selected = try XCTUnwrap(images.descriptors[ref]?.asset)
        XCTAssertEqual(selected.matchKind, "photo")
        XCTAssertNotNil(images.pictures[selected.id])
        let list = try await api.request("v1/lists", method: "POST", body: ["household_id": item.householdId.uuidString, "name": "Image integration"])
        let listID = try XCTUnwrap(list["id"] as? String)
        let line = try await api.request("v1/lists/\(listID)/items", method: "POST", body: ["inventory_item_id": item.id.uuidString, "quantity": 1])
        let lineID = try XCTUnwrap((line["id"] as? String).flatMap(UUID.init(uuidString:)))
        let lineRef = ItemImageReference(kind: "list", id: lineID, name: item.displayName)
        await images.load(lineRef)
        XCTAssertEqual(images.descriptors[lineRef]?.asset?.id, selected.id)
        XCTAssertEqual(images.descriptors[lineRef]?.inherited, true)

        let restored = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await restored.refresh()
        let restoredAPI = AgoraClient(calendar: restored, baseURL: origin, http: http)
        let restoredImages = ItemImageStore(api: restoredAPI, calendar: restored)
        await restoredImages.load(ref)
        XCTAssertEqual(restoredImages.descriptors[ref]?.asset?.id, selected.id)
        XCTAssertNotNil(restoredImages.pictures[selected.id])
        try await restoredImages.select(ref, mode: "representative")
        XCTAssertEqual(restoredImages.descriptors[ref]?.userSelected, true)
        XCTAssertNil(restoredImages.descriptors[ref]?.asset)
        await restoredImages.load(lineRef)
        XCTAssertNil(restoredImages.descriptors[lineRef]?.asset)
        XCTAssertEqual(restoredImages.descriptors[lineRef]?.fallback, "milk")
        let exactIdentity = ItemProductIdentity(name: "Sony WH-1000XM5 Headphones Black", brand: "Sony",
                                                model: "WH-1000XM5", color: "Black")
        try await restoredImages.select(lineRef, mode: "automatic", identity: exactIdentity)
        XCTAssertEqual(restoredImages.descriptors[lineRef]?.identity, exactIdentity)
        XCTAssertEqual(restoredImages.descriptors[lineRef]?.inherited, false)
        XCTAssertEqual(restoredImages.descriptors[lineRef]?.matchStatus, "unresolved")
        let persisted = try await restoredAPI.fetch(lineRef.path, as: ItemImageDescriptor.self)
        XCTAssertEqual(persisted.identity, exactIdentity)
        XCTAssertNil(persisted.displayAsset)
        // Leave the seeded account ready for the other live integration tests.
        if let original = initial.choices.first {
            try await restoredImages.select(ref, mode: "candidate", asset: original.id)
        }
        await restored.signOut()
        XCTAssertTrue(restoredImages.pictures.isEmpty)
        XCTAssertTrue(restoredImages.descriptors.isEmpty)
    }
}
