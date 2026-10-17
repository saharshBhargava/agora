import XCTest
import AVFoundation
@testable import Agora

@MainActor
final class CaptionTests: XCTestCase {
    final class MockHTTP: CaptionHTTPClient {
        var requests: [URLRequest] = []
        var dataHandler: (URLRequest) throws -> (Data, HTTPURLResponse) = { request in (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
        var uploadHandler: (URLRequest, URL) throws -> Data = { _, _ in Data() }
        var streamHandler: (@MainActor (Data) throws -> Void) async throws -> Void = { _ in }
        var cleanupWasCancelled = false
        func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if request.httpMethod == "DELETE" { cleanupWasCancelled = Task.isCancelled }
            return try dataHandler(request)
        }
        func upload(_ request: URLRequest, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
            requests.append(request); progress(0.5); progress(1)
            return (try uploadHandler(request, file), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func stream(_ request: URLRequest, event: @escaping @MainActor (Data) throws -> Void) async throws {
            requests.append(request); try await streamHandler(event)
        }
    }
    private func chunk(_ text: String, finish: String? = nil, thought: Bool = false) throws -> Data {
        var candidate: [String: Any] = ["content": ["parts": [["text": text, "thought": thought]]]]
        if let finish { candidate["finishReason"] = finish }
        return try JSONSerialization.data(withJSONObject: ["candidates": [candidate]])
    }
    private func photo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 12, height: 12))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }
    private func movie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        for _ in 0..<100 { if input.isReadyForMoreMediaData { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600)); input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        return url
    }
    func testSSEFramingAndVisibleTextOnly() throws {
        var decoder = CaptionSSEDecoder()
        XCTAssertNil(try decoder.consume(": keepalive"))
        XCTAssertNil(try decoder.consume("data: {\"candidates\": []}"))
        XCTAssertNotNil(try decoder.consume(""))
        var accumulator = CaptionResponseAccumulator()
        try accumulator.consume(chunk("private reasoning", thought: true))
        try accumulator.consume(chunk("A blue "))
        try accumulator.consume(chunk("square.", finish: "STOP"))
        XCTAssertEqual(try accumulator.result(), "A blue square.")
        var incomplete = CaptionResponseAccumulator()
        try incomplete.consume(chunk("unfinished"))
        XCTAssertThrowsError(try incomplete.result())
        XCTAssertThrowsError(try incomplete.consume(chunk("", finish: "MAX_TOKENS")))
    }
    func testNetworkStreamPreservesEventBoundaries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CaptionStreamFixture.self]
        let client = URLSessionCaptionHTTPClient(configuration: configuration)
        var accumulator = CaptionResponseAccumulator()
        var updates: [String] = []
        try await client.stream(URLRequest(url: URL(string: "https://caption.test/stream")!)) { data in
            try accumulator.consume(data)
            updates.append(accumulator.text)
        }
        XCTAssertEqual(updates, ["A café ", "A café ☕."])
        XCTAssertEqual(try accumulator.result(), "A café ☕.")
    }
    func testByteFramingSupportsAllLineEndingsAndMultilineEvents() throws {
        for separator in ["\n", "\r\n", "\r"] {
            var decoder = CaptionSSEByteDecoder()
            let stream = ": keepalive" + separator + "data: {" + separator + "data: \"value\": 1}" + separator + separator + "data: [DONE]" + separator + separator
            var events: [Data] = []
            for byte in stream.utf8 { if let event = try decoder.consume(byte) { events.append(event) } }
            if let event = try decoder.finish() { events.append(event) }
            XCTAssertEqual(events.count, 1)
            let object = try JSONSerialization.jsonObject(with: XCTUnwrap(events.first)) as? [String: Int]
            XCTAssertEqual(object?["value"], 1)
        }
    }
    func testPhotoCaptionStreamsWithoutBrowserToolsAndRetries503() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let http = MockHTTP()
        var attempts = 0
        http.streamHandler = { event in
            attempts += 1
            if attempts == 1 { throw CaptionHTTPFailure(status: 503) }
            try event(self.chunk("A blue ")); try event(self.chunk("square.", finish: "STOP"))
        }
        let service = GeminiCaptionService(key: "test-key", model: "gemini-flash-latest", http: http, delay: { _ in })
        var partials: [String] = [], stages: [CaptionProgress] = []
        let result = try await service.caption(file: file, kind: .image, style: .short, instruction: "Be factual", progress: { stages.append($0) }, text: { partials.append($0) }, cleanupNotice: { _ in XCTFail("No remote image upload") })
        XCTAssertEqual(result, "A blue square."); XCTAssertEqual(attempts, 2)
        XCTAssertTrue(partials.contains("A blue ")); XCTAssertTrue(stages.contains(.retrying))
        let request = try XCTUnwrap(http.requests.last)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
        XCTAssertNil(body["tools"])
        let contents = body["contents"] as! [[String: Any]]
        let parts = contents[0]["parts"] as! [[String: Any]]
        XCTAssertEqual((parts[0]["inlineData"] as? [String: Any])?["mimeType"] as? String, "image/jpeg")
    }
    private func videoHTTP() -> MockHTTP {
        let http = MockHTTP()
        http.dataHandler = { request in
            let headers = request.url!.path.contains("upload") ? ["X-Goog-Upload-URL": "https://generativelanguage.googleapis.com/upload/session"] : [:]
            let payload = request.httpMethod == "GET" ? #"{"name":"files/test-video","uri":"https://generativelanguage.googleapis.com/v1beta/files/test-video","mimeType":"video/mp4","state":"ACTIVE"}"# : "{}"
            return (Data(payload.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
        }
        http.uploadHandler = { request, _ in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
            return Data(#"{"file":{"name":"files/test-video","uri":"https://generativelanguage.googleapis.com/v1beta/files/test-video","mimeType":"video/mp4","state":"PROCESSING"}}"#.utf8)
        }
        return http
    }
    func testVideoUploadProcessingCaptionAndDeletion() async throws {
        let file = try await movie(); defer { try? FileManager.default.removeItem(at: file) }
        let http = videoHTTP()
        http.streamHandler = { event in try event(self.chunk("A short clip.", finish: "STOP")) }
        let service = GeminiCaptionService(key: "test-key", model: "gemini-flash-latest", http: http, delay: { _ in })
        var stages: [CaptionProgress] = []
        let result = try await service.caption(file: file, kind: .video, style: .detailed, instruction: "", progress: { stages.append($0) }, text: { _ in }, cleanupNotice: { _ in XCTFail("Cleanup should succeed") })
        XCTAssertEqual(result, "A short clip.")
        XCTAssertTrue(stages.contains(.uploading(0.5))); XCTAssertTrue(stages.contains(.processing)); XCTAssertTrue(stages.contains(.cleaningUp))
        XCTAssertEqual(http.requests.last?.httpMethod, "DELETE")
        XCTAssertFalse(http.cleanupWasCancelled)
    }
    func testCancellationStillDeletesUploadedVideo() async throws {
        let file = try await movie(); defer { try? FileManager.default.removeItem(at: file) }
        let http = videoHTTP(); var started = false
        http.streamHandler = { _ in started = true; try await Task.sleep(for: .seconds(60)) }
        let service = GeminiCaptionService(key: "test-key", model: "gemini-flash-latest", http: http, delay: { _ in })
        let task = Task { try await service.caption(file: file, kind: .video, style: .short, instruction: "", progress: { _ in }, text: { _ in }, cleanupNotice: { _ in }) }
        for _ in 0..<100 { if started { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(started); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(http.requests.last?.httpMethod, "DELETE"); XCTAssertFalse(http.cleanupWasCancelled)
    }
    func testProcessingDeadlineCleansUpWithoutGenerating() async throws {
        let file = try await movie(); defer { try? FileManager.default.removeItem(at: file) }
        let http = videoHTTP()
        http.streamHandler = { _ in XCTFail("Must not generate before processing finishes") }
        let service = GeminiCaptionService(key: "test-key", model: "gemini-flash-latest", http: http, processingLimit: 0.02)
        do {
            _ = try await service.caption(file: file, kind: .video, style: .short, instruction: "", progress: { _ in }, text: { _ in }, cleanupNotice: { _ in })
            XCTFail("Expected deadline")
        } catch { XCTAssertEqual((error as? CaptionFailure)?.code, "stage_timeout") }
        XCTAssertEqual(http.requests.last?.httpMethod, "DELETE")
    }
    func testUploadRejectsUntrustedDestination() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let http = MockHTTP()
        http.dataHandler = { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["X-Goog-Upload-URL": "https://example.com/collect"])!)
        }
        http.uploadHandler = { _, _ in XCTFail("Must not send media"); return Data() }
        let service = GeminiCaptionService(key: "test-key", model: "gemini-flash-latest", http: http)
        do { _ = try await service.upload(file, progress: { _ in }); XCTFail("Expected invalid destination") }
        catch { XCTAssertEqual((error as? CaptionFailure)?.code, "invalid_upload_url") }
    }
    func testCaptionPersistenceAndLegacyLibraryDecoding() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let repository = MediaRepository(directory: directory)
        let items = try await repository.add(file: file, kind: .image)
        let saved = SavedCaption(text: "A square", style: .short, model: "test-model", generatedAt: Date())
        _ = try await repository.saveCaption(saved, for: items[0].id)
        let reloaded = try await MediaRepository(directory: directory).load()
        XCTAssertEqual(reloaded[0].caption, saved)
        let legacy = #"[{"id":"00000000-0000-0000-0000-000000000001","kind":"image","filename":"old.jpg","createdAt":0}]"#
        XCTAssertNil(try JSONDecoder().decode([CaptureItem].self, from: Data(legacy.utf8))[0].caption)
        _ = try await repository.remove(items[0])
        do { _ = try await repository.saveCaption(saved, for: items[0].id); XCTFail("Do not resurrect deleted items") } catch { XCTAssertTrue(error is CaptureFailure) }
    }
    func testRetryClassificationDoesNotRetryAuthenticationOrQuota() {
        XCTAssertFalse(GeminiCaptionService.isRetryable(CaptionHTTPFailure(status: 401)))
        XCTAssertFalse(GeminiCaptionService.isRetryable(CaptionHTTPFailure(status: 429)))
        XCTAssertFalse(GeminiCaptionService.isRetryable(CancellationError()))
        XCTAssertTrue(GeminiCaptionService.isRetryable(URLError(.timedOut)))
    }
}

@MainActor
final class CaptionControllerTests: XCTestCase {
    final class FakeCaptionService: CaptionGenerating {
        var fail = false
        var wait = false
        var started = false
        func caption(file: URL, kind: CaptureItem.Kind, style: CaptionStyle, instruction: String,
                     progress: @escaping @MainActor (CaptionProgress) -> Void,
                     text: @escaping @MainActor (String) -> Void,
                     cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> String {
            started = true; progress(.generating); text("New caption")
            if wait { try await Task.sleep(for: .seconds(60)) }
            if fail { throw CaptionHTTPFailure(status: 503) }
            return "New caption"
        }
    }
    private var item: CaptureItem { CaptureItem(id: UUID(), kind: .image, filename: "sample.jpg", createdAt: Date()) }
    private var previous: SavedCaption { SavedCaption(text: "Previous caption", style: .short, model: "test", generatedAt: Date()) }
    private func settled(_ controller: CaptionController) async throws {
        for _ in 0..<100 { if !controller.busy { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Caption task did not settle")
    }
    func testFailurePreservesExistingCaption() async throws {
        let controller = CaptionController(), provider = FakeCaptionService(); provider.fail = true
        controller.restore(previous)
        controller.start(item: item, file: URL(fileURLWithPath: "/unused"), model: "test", provider: provider) { _ in XCTFail("Must not save failed response") }
        try await settled(controller)
        XCTAssertEqual(controller.draft, "Previous caption")
        XCTAssertTrue(controller.partialText.isEmpty)
        XCTAssertNotNil(controller.message)
    }
    func testCancelDoesNotSavePartialCaption() async throws {
        let controller = CaptionController(), provider = FakeCaptionService(); provider.wait = true
        controller.restore(previous)
        controller.start(item: item, file: URL(fileURLWithPath: "/unused"), model: "test", provider: provider) { _ in XCTFail("Must not save cancelled response") }
        for _ in 0..<100 { if provider.started { break }; try await Task.sleep(for: .milliseconds(10)) }
        controller.cancel(); try await settled(controller)
        XCTAssertEqual(controller.draft, "Previous caption")
        XCTAssertTrue(controller.partialText.isEmpty)
    }
    func testSaveFailureRetainsGeneratedDraftForRetry() async throws {
        let controller = CaptionController(), provider = FakeCaptionService()
        controller.start(item: item, file: URL(fileURLWithPath: "/unused"), model: "test", provider: provider) { _ in throw CocoaError(.fileWriteOutOfSpace) }
        try await settled(controller)
        XCTAssertEqual(controller.draft, "New caption")
        XCTAssertTrue(controller.hasEdits)
        XCTAssertTrue(controller.message?.contains("saving failed") == true)
    }
}

private final class CaptionStreamFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "caption.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let first = #"data: {"candidates":[{"content":{"parts":[{"text":"A café "}]}}]}"#
        let last = #"data: {"candidates":[{"content":{"parts":[{"text":"☕."}]},"finishReason":"STOP"}]}"#
        // Deliberately fragment UTF-8 characters and CRLF separators across deliveries.
        for byte in (first + "\r\n\r\n" + last + "\n\n").utf8 {
            client?.urlProtocol(self, didLoad: Data([byte]))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
