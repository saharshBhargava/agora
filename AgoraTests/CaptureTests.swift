import XCTest
import SwiftUI
import UIKit
import PDFKit
@testable import Agora

@MainActor
final class CaptureTests: XCTestCase {
    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testPhotoImportPersistsAndDoesNotModifyOriginal() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.9)); try data.write(to: source)
        let directory = root.appendingPathComponent("library")
        let repository = MediaRepository(directory: directory)
        let items = try await repository.add(file: source, kind: .image)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .image)
        let saved = directory.appendingPathComponent(items[0].filename)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertNotNil(MediaLibrary.thumbnail(saved))
        let restored = try await MediaRepository(directory: directory).load()
        XCTAssertEqual(restored, items)
        let remaining = try await repository.remove(items[0])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertEqual(try Data(contentsOf: source), data)
    }
    func testMultipageScanPDFRemainsMultipageAfterImport() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("scan.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).writePDF(to: source) { context in
            context.beginPage(); context.beginPage()
        }
        let directory = root.appendingPathComponent("library")
        let items = try await MediaRepository(directory: directory).add(file: source, kind: .document)
        let document = PDFDocument(url: directory.appendingPathComponent(items[0].filename))
        XCTAssertEqual(document?.pageCount, 2)
    }
    func testUnsupportedImportDoesNotCreateLibraryEntry() async throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt"); try Data("not a picture".utf8).write(to: source)
        let repository = MediaRepository(directory: root.appendingPathComponent("library"))
        do { _ = try await repository.add(file: source, kind: .image); XCTFail("Expected unsupported file") }
        catch { XCTAssertTrue(error is CaptureFailure) }
        let items = try await repository.load()
        XCTAssertTrue(items.isEmpty)
    }
    func testCameraAndMicrophonePurposeStringsAreBundled() {
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String ?? "").isEmpty)
        XCTAssertFalse((Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String ?? "").isEmpty)
    }

    func testUnavailableCameraReturnsAnErrorWithoutConfiguringAnImagePicker() async throws {
        for video in [false, true] {
            guard CameraPicker.availableCamera(video: video) == nil else { continue }
            let completed = expectation(description: "Unavailable camera reports an error")
            let picker = CameraPicker(video: video) { result in
                guard case .failure(let error) = result else { XCTFail("Expected camera error"); completed.fulfill(); return }
                XCTAssertEqual(error.localizedDescription, CaptureFailure.cameraUnavailable.localizedDescription)
                completed.fulfill()
            }
            let controller = picker.makeController(coordinator: picker.makeCoordinator())
            XCTAssertFalse(controller is UIImagePickerController, "Do not set unavailable camera properties: UIKit throws an exception")
            await fulfillment(of: [completed], timeout: 2)
        }
    }

    func testCameraVideoResultCopiesTemporaryFileBeforeReview() throws {
        let root = try fixtureDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.mov")
        // This tests ownership of picker bytes, not video decoding.
        let bytes = Data("camera-result-fixture".utf8)
        try bytes.write(to: source)
        var result: Result<(URL, CaptureItem.Kind)?, Error>?
        let coordinator = CameraPicker.Coordinator { result = $0 }
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.mediaURL: source])
        let (file, kind) = try XCTUnwrap(try XCTUnwrap(result).get())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(kind, .video)
        XCTAssertNotEqual(file, source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}


extension CaptureTests {
    func testCameraPhotoResultReturnsTheNewLibraryItemForImmediateReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        var result: Result<(URL, CaptureItem.Kind)?, Error>?
        let coordinator = CameraPicker.Coordinator { result = $0 }
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: image])
        let (file, kind) = try XCTUnwrap(try XCTUnwrap(result).get())
        defer { try? FileManager.default.removeItem(at: file) }
        let library = MediaLibrary(directory: directory)
        let first = await library.add(file: file, kind: kind)
        let second = await library.add(file: file, kind: kind)
        let capture = try XCTUnwrap(second)
        XCTAssertEqual(capture.kind, .image)
        XCTAssertNotEqual(first?.id, capture.id)
        XCTAssertEqual(library.items.first?.id, capture.id)
        XCTAssertNotNil(MediaLibrary.thumbnail(library.url(for: capture)))
    }
}

extension CaptureTests {
    func testScanQueueReviewsPhotosAndVideosInOrderAndLeavesDocumentsInLibrary() {
        let photo = CaptureItem(id: UUID(), kind: .image, filename: "photo.jpg", createdAt: Date())
        let video = CaptureItem(id: UUID(), kind: .video, filename: "video.mov", createdAt: Date())
        let pdf = CaptureItem(id: UUID(), kind: .document, filename: "document.pdf", createdAt: Date())
        var queue = ScanReviewQueue()
        queue.enqueue([photo, pdf, video, photo])
        XCTAssertEqual(queue.next()?.id, photo.id)
        XCTAssertEqual(queue.next()?.id, video.id)
        XCTAssertNil(queue.next())
        queue.enqueue([photo, video]); queue.clear()
        XCTAssertNil(queue.next(), "Closing a batch or switching accounts must abandon automatic review")
    }

    func testRecentScanStatusDistinguishesPendingRejectedConfirmedAndOtherAccounts() {
        let household = UUID()
        var item = CaptureItem(id: UUID(), kind: .image, filename: "photo.jpg", createdAt: Date())
        XCTAssertEqual(item.scanStatus(accountID: "alice", householdID: household), "Needs review")
        var saved = SavedRecognition(key: UUID(), accountID: "alice", householdID: household, capturedAt: Date(),
            mediaKind: "photos", model: "fixture", locationID: nil, merchantID: nil, purchasedOn: nil, items: [])
        item.recognition = saved
        XCTAssertEqual(item.scanStatus(accountID: "alice", householdID: household), "Check save status")
        saved.rejected = true; item.recognition = saved
        XCTAssertEqual(item.scanStatus(accountID: "alice", householdID: household), "Needs review")
        saved.rejected = false; saved.recognitionID = UUID(); item.recognition = saved
        XCTAssertEqual(item.scanStatus(accountID: "alice", householdID: household), "Added to inventory")
        XCTAssertEqual(item.scanStatus(accountID: "bob", householdID: household), "Saved review in another household or account")
        XCTAssertEqual(item.scanStatus(accountID: "alice", householdID: UUID()), "Saved review in another household or account")
    }
}

@MainActor
private final class ScanGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "scan-alice", email: "scan@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { "scan-fixture" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class ScanHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        let data = request.url!.path.hasSuffix("/inventory") ? Data("[]".utf8) : try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class ScanRecognition: InventoryRecognizing {
    func recognize(file: URL, kind: CaptureItem.Kind, progress: @escaping @MainActor (CaptionProgress) -> Void,
                   cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> [RecognizedItem] {
        [.init(name: "Organic whole milk", category: "Dairy", unit: "cartons", quantity: 2, confidence: 0.95),
         .init(name: "Jar of pasta sauce", category: "Pantry", unit: "jars", quantity: 1, confidence: 0.4)]
    }
}

extension CaptureTests {
    func testScanReviewAndConfirmationRenderWithConfirmedMetadataOnly() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let household = UUID(), resultID = UUID()
        let calendar = CalendarConnection(authorization: ScanGoogle()); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ScanHTTP.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ScanHTTP.handler = nil }
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://scan.example"), http: session)
        let inventory = InventoryStore(api: api, calendar: calendar)
        var saves = 0
        ScanHTTP.handler = { request in
            if request.url!.path.hasSuffix("/me") {
                return (200, ["households": [["id": household.uuidString, "name": "Home", "locations": []]]])
            }
            if request.httpMethod == "POST" {
                saves += 1
                XCTAssertTrue(request.url!.path.hasSuffix("/inventory/recognitions"))
                XCTAssertNotNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
                return (201, ["recognition_id": resultID.uuidString, "items": [
                    ["id": UUID().uuidString, "household_id": household.uuidString,
                     "display_name": "Organic whole milk", "unit": "cartons", "quantity": 2, "status": "active"]]])
            }
            return (200, [:])
        }
        await inventory.refresh()
        XCTAssertEqual(inventory.householdID, household)
        let suite = "scan-render-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(keychainService: suite, defaults: defaults)
        let library = MediaLibrary(directory: directory.appendingPathComponent("library"))
        let photo = directory.appendingPathComponent("milk.jpg")
        try XCTUnwrap(UIImage(named: "Item-milk")?.jpegData(compressionQuality: 0.9)).write(to: photo)
        let imported = await library.add(file: photo, kind: .image)
        let item = try XCTUnwrap(imported)
        var queue = ScanReviewQueue(); queue.enqueue([item])
        let reviewItem = try XCTUnwrap(queue.next())
        let controller = RecognitionController()
        controller.generateIfNeeded(item: reviewItem, file: library.url(for: reviewItem), settings: settings,
                                    store: inventory, provider: ScanRecognition())
        for _ in 0..<100 where controller.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(controller.drafts.count, 2)
        XCTAssertEqual(saves, 0, "Import and recognition must not save inventory without confirmation")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        func capture<V: View>(_ view: V, name: String, scrollToBottom: Bool = false) async throws {
            let host = UIHostingController(rootView: view.tint(.teal))
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            if scrollToBottom {
                func findScroll(_ view: UIView) -> UIScrollView? {
                    if let scroll = view as? UIScrollView { return scroll }
                    return view.subviews.lazy.compactMap(findScroll).first
                }
                let scroll = try XCTUnwrap(findScroll(host.view))
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)), animated: false)
                try await Task.sleep(for: .milliseconds(200))
            }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("scan-\(name).png")
            try XCTUnwrap(image.pngData()).write(to: path)
            print("Scan screenshot: \(path.path)")
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await capture(CaptureView(settings: settings, inventory: inventory, library: library), name: "landing")
        try await capture(CaptureView(settings: settings, inventory: inventory, library: library)
            .environment(\.dynamicTypeSize, .accessibility1), name: "landing-large")
        try await capture(RecognitionView(item: item, url: library.url(for: item), settings: settings, store: inventory,
                                         library: library, controller: controller), name: "review")
        try await capture(RecognitionView(item: item, url: library.url(for: item), settings: settings, store: inventory,
                                         library: library, controller: controller).environment(\.dynamicTypeSize, .accessibility1), name: "review-large")
        try await capture(RecognitionView(item: item, url: library.url(for: item), settings: settings, store: inventory,
                                         library: library, controller: controller).environment(\.dynamicTypeSize, .accessibility1),
                          name: "review-large-items", scrollToBottom: true)
        controller.drafts[1].included = false
        await controller.save(item: item, store: inventory, library: library)
        XCTAssertTrue(controller.completed, controller.message ?? "Save failed")
        XCTAssertEqual(saves, 1)
        let saved = try XCTUnwrap(library.items.first?.recognition)
        XCTAssertEqual(saved.items.count, 1)
        XCTAssertEqual(saved.items[0].displayName, "Organic whole milk")
        XCTAssertEqual(saved.recognitionID, resultID)
        XCTAssertTrue(inventory.activeItems.contains { $0.displayName == "Organic whole milk" && $0.quantity == 2 })
        XCTAssertFalse(saved.body.keys.contains("media"))
        try await capture(RecognitionView(item: item, url: library.url(for: item), settings: settings, store: inventory,
                                         library: library, controller: controller, onScanMore: {}), name: "success")
        await controller.save(item: item, store: inventory, library: library)
        XCTAssertEqual(saves, 1, "The confirmation must not allow a second save")
    }
}
