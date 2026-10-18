import XCTest
import AVFoundation
@testable import Agora

@MainActor
final class GeminiModelTests: XCTestCase {
    final class HTTP: CaptionHTTPClient {
        var requests: [URLRequest] = []
        var responseHeaders: [String: String] = [:]
        var asyncHandler: ((URLRequest) async throws -> (Data, Int))?
        var uploadHandler: ((URLRequest, URL) throws -> (Data, Int))?
        var handler: (URLRequest) throws -> (Data, Int) = { _ in
            (try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": "A blue scene."]]]]]]), 200)
        }
        func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let result: (Data, Int)
            if let asyncHandler { result = try await asyncHandler(request) }
            else { result = try handler(request) }
            return (result.0, HTTPURLResponse(url: request.url!, statusCode: result.1, httpVersion: nil, headerFields: responseHeaders)!)
        }
        func upload(_ request: URLRequest, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
            guard let uploadHandler else {
                XCTFail("Sampled video must not use the Files API")
                return try await data(request)
            }
            requests.append(request)
            let (data, status) = try uploadHandler(request, file)
            progress(1)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func stream(_ request: URLRequest, event: @escaping @MainActor (Data) throws -> Void) async throws { XCTFail("Unexpected stream") }
    }
    private let tool = ModelToolDefinition(name: "browser_observe", description: "Read the current page", parameters: .object(["type": .string("OBJECT")]))
    private func call(_ id: Any = "one", arguments: Any = [String: Any]()) -> [String: Any] {
        ["functionCall": ["id": id, "name": "browser_observe", "args": arguments]]
    }
    private func client(_ http: CaptionHTTPClient, capabilities: ModelCapabilities = .gemini) -> GeminiModelClient {
        GeminiModelClient(identity: ModelIdentity(provider: .gemini, model: "gemini-flash-latest"), capabilities: capabilities, key: "private-gemini-key", http: http)
    }

    func testMalformedToolPartRejectsEntireCompletedBatch() async throws {
        let http = HTTP()
        let invalidParts: [[String: Any]] = [
            ["functionCall": "broken"], ["functionCall": NSNull()],
            call(""), call(12), call(String(repeating: "x", count: 129)), call("line\nbreak"),
            call("one"), call("two", arguments: "not an object"),
            ["thought": true, "functionCall": ["id": "two", "name": "browser_observe", "args": [:]]],
            ["text": 12]
        ]
        for invalid in invalidParts {
            http.handler = { _ in
                let body: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [self.call(), invalid]]]]]
                return (try JSONSerialization.data(withJSONObject: body), 200)
            }
            do {
                _ = try await client(http).generate(ModelRequest(instructions: "Read the page", messages: [ModelMessage(role: .user, content: [.text("Read")])], tools: [tool]), onEvent: { _ in })
                XCTFail("No calls may escape a malformed batch")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private-gemini-key")) }
        }
        XCTAssertEqual(http.requests.count, invalidParts.count)
    }

    func testGeminiContinuationAndMultipleResultIDsArePreserved() throws {
        let raw: [String: Any] = ["role": "model", "parts": [
            ["thought": true, "text": "internal reasoning", "thoughtSignature": "thought-signature"],
            ["functionCall": ["id": "a", "name": "browser_observe", "args": [:]], "thoughtSignature": "first-signature"],
            ["functionCall": ["id": "b", "name": "browser_observe", "args": [:]], "thoughtSignature": "second-signature"]
        ]]
        let response = try GeminiConversationCodec.decode(raw)
        XCTAssertTrue(response.content.isEmpty)
        XCTAssertEqual(response.toolCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(try ModelJSON.from(GeminiConversationCodec.encode(response)), try ModelJSON.from(raw))
        let results = ModelMessage(role: .user, toolResults: [
            ModelToolResult(id: "b", name: "browser_observe", value: .object(["ok": .bool(true)])),
            ModelToolResult(id: "a", name: "browser_observe", value: .object(["ok": .bool(false)]))
        ])
        let parts = try XCTUnwrap(GeminiConversationCodec.encode(results)["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { ($0["functionResponse"] as? [String: Any])?["id"] as? String }, ["b", "a"])
        let noID = try GeminiConversationCodec.decode(["parts": [["functionCall": ["name": "browser_observe", "args": [:]]]]])
        XCTAssertTrue(noID.toolCalls[0].id.hasPrefix("agora-generated-"))
        let legacyResult = ModelMessage(role: .user, toolResults: [ModelToolResult(id: noID.toolCalls[0].id, name: "browser_observe", value: .object([:]))])
        let legacyParts = try XCTUnwrap(GeminiConversationCodec.encode(legacyResult)["parts"] as? [[String: Any]])
        XCTAssertNil((legacyParts.first?["functionResponse"] as? [String: Any])?["id"])
    }

    func testVideoWithoutNativeSupportBecomesFramesAndDoesNotUpload() async throws {
        let file = try await video()
        defer { try? FileManager.default.removeItem(at: file) }
        let http = HTTP()
        var capabilities = ModelCapabilities.gemini
        capabilities.nativeVideo = false
        _ = try await client(http, capabilities: capabilities).generate(ModelRequest(instructions: "Describe visible frames", messages: [ModelMessage(role: .user, content: [.media(file, kind: .video)])]), onEvent: { _ in })
        XCTAssertEqual(http.requests.count, 1)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertTrue(request.url!.path.hasSuffix(":generateContent"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        XCTAssertTrue(parts.contains { $0["inlineData"] != nil })
        XCTAssertFalse(parts.contains { $0["fileData"] != nil })
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("Frame at ") == true })
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("Audio is not included") == true })
        capabilities.images = false
        do {
            _ = try await client(http, capabilities: capabilities).generate(ModelRequest(instructions: "Describe", messages: [ModelMessage(role: .user, content: [.media(file, kind: .video)])]), onEvent: { _ in })
            XCTFail("Video requires native video support or images for sampled frames")
        } catch {}
        XCTAssertEqual(http.requests.count, 1)
    }

    func testNativeVideoSharedClientUploadsWaitsGeneratesAndDeletes() async throws {
        let file = try await video()
        defer { try? FileManager.default.removeItem(at: file) }
        let http = nativeVideoHTTP(file: file)
        var stages: [CaptionProgress] = []
        var notices: [String] = []
        let response = try await client(http).generate(nativeVideoRequest(file)) { event in
            if case .progress(let stage) = event { stages.append(stage) }
            if case .cleanupNotice(let notice) = event { notices.append(notice) }
        }
        XCTAssertEqual(response.text, "A blue scene.")
        XCTAssertEqual(http.requests.map { $0.httpMethod ?? "GET" }, ["POST", "POST", "GET", "POST", "DELETE"])
        XCTAssertEqual(http.requests.last?.url?.path, "/v1beta/files/native-video")
        XCTAssertTrue(stages.contains(.processing))
        XCTAssertTrue(stages.contains(.cleaningUp))
        XCTAssertTrue(notices.isEmpty)
    }

    func testNativeVideoSharedClientDeletesAfterFailureAndCancellation() async throws {
        let file = try await video()
        defer { try? FileManager.default.removeItem(at: file) }
        for cancelled in [false, true] {
            let http = nativeVideoHTTP(file: file)
            let ordinary = http.handler
            var generationStarted = false
            var cleanupWasCancelled: Bool?
            http.asyncHandler = { request in
                if request.httpMethod == "DELETE" { cleanupWasCancelled = Task.isCancelled }
                if request.url!.path.hasSuffix(":generateContent") {
                    generationStarted = true
                    if cancelled { try await Task.sleep(for: .seconds(30)) }
                    throw URLError(.cannotConnectToHost)
                }
                return try ordinary(request)
            }
            let operation = Task { try await self.client(http).generate(self.nativeVideoRequest(file), onEvent: { _ in }) }
            if cancelled {
                let deadline = ContinuousClock.now + .seconds(5)
                while !generationStarted && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(generationStarted)
                operation.cancel()
            }
            do { _ = try await operation.value; XCTFail("Generation should fail") }
            catch { if cancelled { XCTAssertTrue(error is CancellationError) } }
            XCTAssertEqual(http.requests.filter { $0.httpMethod == "DELETE" }.count, 1)
            XCTAssertEqual(cleanupWasCancelled, false)
            XCTAssertEqual(http.requests.last?.url?.path, "/v1beta/files/native-video")
        }
    }

    private func nativeVideoRequest(_ file: URL) -> ModelRequest {
        ModelRequest(instructions: "Describe the video", messages: [ModelMessage(role: .user, content: [.media(file, kind: .video)])])
    }

    private func nativeVideoHTTP(file: URL) -> HTTP {
        let http = HTTP()
        let completed = http.handler
        let remote: [String: Any] = ["name": "files/native-video", "uri": "https://generativelanguage.googleapis.com/v1beta/files/native-video", "mimeType": "video/mp4", "state": "ACTIVE"]
        http.responseHeaders = ["X-Goog-Upload-URL": "https://generativelanguage.googleapis.com/upload/session/native-video"]
        http.uploadHandler = { request, uploaded in
            XCTAssertEqual(uploaded, file)
            XCTAssertGreaterThan(try Data(contentsOf: uploaded).count, 0)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Command"), "upload, finalize")
            var processing = remote; processing["state"] = "PROCESSING"
            return (try JSONSerialization.data(withJSONObject: ["file": processing]), 200)
        }
        http.handler = { request in
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
            if request.httpMethod == "DELETE" { return (Data(), 200) }
            if request.url!.path == "/upload/v1beta/files" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Goog-Upload-Protocol"), "resumable")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "private-gemini-key")
                return (Data(), 200)
            }
            if request.httpMethod == "GET" && request.url!.path == "/v1beta/files/native-video" {
                return (try JSONSerialization.data(withJSONObject: remote), 200)
            }
            XCTAssertTrue(request.url!.path.hasSuffix(":generateContent"))
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            let reference = try XCTUnwrap(parts.first?["fileData"] as? [String: Any])
            XCTAssertEqual(reference["fileUri"] as? String, remote["uri"] as? String)
            XCTAssertEqual(reference["mimeType"] as? String, "video/mp4")
            XCTAssertFalse(parts.contains { $0["inlineData"] != nil })
            return try completed(request)
        }
        return http
    }

    func testSettingsGeminiDiscoveryUsesInjectedSafeTransportAndPagination() async throws {
        let suite = "app.agora.gemini-discovery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = SettingsStore(keychainService: suite, defaults: defaults)
        defer { try? settings.deleteKey(); defaults.removePersistentDomain(forName: suite) }
        try settings.saveKey("discovery-secret")
        let http = HTTP()
        http.handler = { request in
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "discovery-secret")
            let first = !request.url!.absoluteString.contains("pageToken")
            let id = first ? "gemini-one" : "gemini-two"
            var body: [String: Any] = ["models": [["name": "models/\(id)", "supportedGenerationMethods": ["generateContent"]]]]
            if first { body["nextPageToken"] = "next page" }
            return (try JSONSerialization.data(withJSONObject: body), 200)
        }
        let models = try await settings.availableModels(connection: settings.modelConfiguration.connections[0], http: http)
        XCTAssertEqual(models, ["gemini-one", "gemini-two"])
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertTrue(http.requests[1].url!.absoluteString.contains("pageToken=next%20page"))
        http.handler = { _ in (Data("secret server body".utf8), 302) }
        do { _ = try await GeminiProvider.availableModels(key: "discovery-secret", http: http); XCTFail("Redirect must fail") }
        catch { XCTAssertFalse(error.localizedDescription.contains("secret server body")) }
    }

    private func video() async throws -> URL {
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
        await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        return url
    }
}
