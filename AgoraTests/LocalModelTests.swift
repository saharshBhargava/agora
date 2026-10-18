import XCTest
import UIKit
import AVFoundation
@testable import Agora

@MainActor
final class LocalModelTests: XCTestCase {
    final class HTTP: CaptionHTTPClient {
        var requests: [URLRequest] = []
        var response: [String: Any] = ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": "Hello"]]]]
        var failure: Error?
        var status = 200
        var events: [[String: Any]] = []
        func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let failure { throw failure }
            return (try JSONSerialization.data(withJSONObject: response), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        func stream(_ request: URLRequest, event: @escaping @MainActor (Data) throws -> Void) async throws {
            requests.append(request)
            for value in events { try event(JSONSerialization.data(withJSONObject: value)) }
            if let failure { throw failure }
        }
        func upload(_ request: URLRequest, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
            XCTFail("Local models must not upload provider files")
            return try await data(request)
        }
    }
    private let tool = ModelToolDefinition(name: "find_items", description: "Find items", parameters: .object(["type": .string("OBJECT"), "properties": .object(["query": .object(["type": .string("STRING")])])]))
    private func client(_ http: CaptionHTTPClient, capabilities: ModelCapabilities = ModelCapabilities(images: true, tools: true, structuredOutput: true), key: String? = nil) -> OpenAICompatibleClient {
        OpenAICompatibleClient(identity: ModelIdentity(provider: .openAICompatible, model: "custom-org/model:Q4_K_M"), capabilities: capabilities, endpoint: "http://127.0.0.1:1234/v1", key: key, http: http)
    }
    private func request(tools: Bool = false) -> ModelRequest {
        ModelRequest(instructions: "Be helpful", messages: [ModelMessage(role: .user, content: [.text("Hi")])], tools: tools ? [tool] : [])
    }
    private func body(_ http: HTTP) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.requests.last?.httpBody)) as? [String: Any])
    }
    private func completed(_ text: String = "Hello", reason: String = "stop", calls: [[String: Any]]? = nil) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": text]
        if let calls { message["tool_calls"] = calls }
        return ["choices": [["index": 0, "finish_reason": reason, "message": message]]]
    }
    private func call(_ id: String, name: String = "find_items", arguments: String = "{\"query\":\"milk\"}") -> [String: Any] {
        ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
    }
    private func event(_ delta: [String: Any], finish: String? = nil) -> [String: Any] {
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return ["choices": [choice]]
    }

    func testTextAndOptionalAuthorization() async throws {
        let http = HTTP()
        let response = try await client(http).generate(request(), onEvent: { _ in })
        XCTAssertEqual(response.text, "Hello")
        XCTAssertNil(http.requests.last?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(http.requests.last?.url?.absoluteString, "http://127.0.0.1:1234/v1/chat/completions")
        XCTAssertEqual(try body(http)["model"] as? String, "custom-org/model:Q4_K_M")
        _ = try await client(http, key: "private-key").generate(request(), onEvent: { _ in })
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer private-key")
        XCTAssertEqual(http.requests.last?.timeoutInterval, 90)
    }

    func testToolRoundTripPreservesEveryCallID() async throws {
        let http = HTTP()
        http.response = completed("", reason: "tool_calls", calls: [call("first"), call("second", arguments: "{\"query\":\"eggs\"}")])
        let response = try await client(http).generate(request(tools: true), onEvent: { _ in })
        XCTAssertEqual(response.message.toolCalls.map(\.id), ["first", "second"])
        XCTAssertEqual(response.message.toolCalls[1].arguments["query"], .string("eggs"))
        var next = request(tools: true)
        next.messages.append(response.message)
        next.messages.append(ModelMessage(role: .user, toolResults: [
            ModelToolResult(id: "second", name: "find_items", value: .object(["count": .number(2)])),
            ModelToolResult(id: "first", name: "find_items", value: .object(["count": .number(1)]))
        ]))
        http.response = completed("Found them")
        _ = try await client(http).generate(next, onEvent: { _ in })
        let messages = try XCTUnwrap(try body(http)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(messages.first { $0["tool_calls"] != nil })
        XCTAssertEqual((assistant["tool_calls"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["first", "second"])
        XCTAssertEqual(messages.filter { $0["role"] as? String == "tool" }.compactMap { $0["tool_call_id"] as? String }, ["second", "first"])
    }

    func testToolResultsPrecedeFollowupScreenshotAndRetainMultipleIDs() async throws {
        let http = HTTP()
        var input = request(tools: true)
        input.messages.append(ModelMessage(role: .assistant, toolCalls: [
            ModelToolCall(id: "a", name: "find_items", arguments: [:]),
            ModelToolCall(id: "b", name: "find_items", arguments: [:])
        ]))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in }
        input.messages.append(ModelMessage(role: .user,
            content: [.text("Current page"), .image(try XCTUnwrap(image.jpegData(compressionQuality: 0.8)), mimeType: "image/jpeg")],
            toolResults: [ModelToolResult(id: "a", name: "find_items", value: .object([:])), ModelToolResult(id: "b", name: "find_items", value: .object([:]))]))
        _ = try await client(http).generate(input, onEvent: { _ in })
        let messages = try XCTUnwrap(try body(http)["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "user"])
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "a")
        XCTAssertEqual(messages[4]["tool_call_id"] as? String, "b")
        XCTAssertEqual((messages.last?["content"] as? [[String: Any]])?.last?["type"] as? String, "image_url")
        input.messages[input.messages.count - 1].toolResults[1] = ModelToolResult(id: "unknown", name: "find_items", value: .null)
        do { _ = try await client(http).generate(input, onEvent: { _ in }); XCTFail("Mismatched tool result accepted") } catch {}
        XCTAssertEqual(http.requests.count, 1)
    }

    func testProfileWithoutStreamingUsesCompleteRequest() async throws {
        let http = HTTP()
        let model = client(http, capabilities: ModelCapabilities(streaming: false))
        var updates: [String] = []
        let response = try await model.stream(request()) { if case .text(let text) = $0 { updates.append(text) } }
        XCTAssertEqual(response.text, "Hello")
        XCTAssertEqual(updates, ["Hello"])
        XCTAssertEqual(try body(http)["stream"] as? Bool, false)
    }

    func testInvalidOrTruncatedToolResponseNeverReturnsCalls() async throws {
        let http = HTTP()
        for response in [
            completed("", reason: "length", calls: [call("one")]),
            completed("", reason: "content_filter", calls: [call("one")]),
            completed("", reason: "tool_calls", calls: [call("one"), call("two", arguments: "{")]),
            completed("", reason: "tool_calls", calls: [call("one"), call("one")]),
            completed("", reason: "tool_calls", calls: [call("one", name: "execute_shell")]),
            completed("", reason: "tool_calls", calls: [call("one", arguments: "[]")]),
            completed("", reason: "tool_calls", calls: []),
            completed("", reason: "stop", calls: [call("one")])
        ] {
            http.response = response
            do { _ = try await client(http).generate(request(tools: true), onEvent: { _ in }); XCTFail("Invalid calls were accepted") }
            catch { XCTAssertTrue((error as? CaptionFailure)?.code.hasPrefix("local_") == true) }
        }
    }

    func testImagePayloadIsBoundedJPEG() async throws {
        let http = HTTP()
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1000)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2000, height: 1000))
        }
        var input = request()
        input.messages[0].content.append(.image(try XCTUnwrap(image.pngData()), mimeType: "image/png"))
        _ = try await client(http).generate(input, onEvent: { _ in })
        let messages = try XCTUnwrap(try body(http)["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
        let url = try XCTUnwrap((parts.last?["image_url"] as? [String: Any])?["url"] as? String)
        XCTAssertTrue(url.hasPrefix("data:image/jpeg;base64,"))
        let data = try XCTUnwrap(Data(base64Encoded: String(url.split(separator: ",", maxSplits: 1)[1])))
        let resized = try XCTUnwrap(UIImage(data: data))
        XCTAssertLessThanOrEqual(max(resized.size.width, resized.size.height), 1536)
        XCTAssertLessThanOrEqual(data.count, LocalModelMedia.maximumImageBytes)
        XCTAssertThrowsError(try LocalModelMedia.image(Data("invalid".utf8)))
    }

    func testCapabilitiesRejectUnsupportedInputsBeforeNetwork() async throws {
        let http = HTTP()
        let restricted = client(http, capabilities: ModelCapabilities())
        var image = request()
        image.messages[0].content = [.image(Data([1]), mimeType: "image/jpeg")]
        var schema = request()
        schema.outputSchema = .object(["type": .string("OBJECT")])
        for input in [image, request(tools: true), schema] {
            do { _ = try await restricted.generate(input, onEvent: { _ in }); XCTFail("Unsupported request was accepted") } catch {}
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSchemaConversionPreservesPropertyNamesAndEnums() async throws {
        let http = HTTP()
        var input = request(tools: true)
        input.outputSchema = .object([
            "type": .string("OBJECT"),
            "properties": .object(["type": .object(["type": .string("ARRAY"), "items": .object(["type": .string("STRING"), "enum": .array([.string("UPPERCASE")])])])]),
            "$defs": .object(["type": .object(["type": .string("NUMBER")])])
        ])
        _ = try await client(http).generate(input, onEvent: { _ in })
        let payload = try body(http)
        let format = try XCTUnwrap(payload["response_format"] as? [String: Any])
        let schema = try XCTUnwrap((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        let property = try XCTUnwrap((schema["properties"] as? [String: Any])?["type"] as? [String: Any])
        XCTAssertEqual(property["type"] as? String, "array")
        XCTAssertEqual((property["items"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual((property["items"] as? [String: Any])?["enum"] as? [String], ["UPPERCASE"])
        XCTAssertEqual((((schema["$defs"] as? [String: Any])?["type"]) as? [String: Any])?["type"] as? String, "number")
        let tools = try XCTUnwrap(payload["tools"] as? [[String: Any]])
        XCTAssertEqual(((tools[0]["function"] as? [String: Any])?["parameters"] as? [String: Any])?["type"] as? String, "object")
    }

    func testMalformedBlockedAndPartialResponsesFailSafely() async throws {
        let http = HTTP()
        for response: [String: Any] in [[:], ["error": ["message": "secret body"]], completed("partial", reason: "length"), completed("", reason: "content_filter"), completed("")] {
            http.response = response
            do { _ = try await client(http).generate(request(), onEvent: { _ in }); XCTFail("Incomplete response accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret body")) }
        }
        http.status = 401
        do { _ = try await client(http).generate(request(), onEvent: { _ in }); XCTFail() }
        catch { XCTAssertEqual((error as? CaptionFailure)?.code, "local_authentication") }
        http.status = 200
        http.failure = URLError(.timedOut)
        do { _ = try await client(http).generate(request(), onEvent: { _ in }); XCTFail() }
        catch { XCTAssertEqual((error as? CaptionFailure)?.code, "local_timeout") }
        http.failure = CancellationError()
        do { _ = try await client(http).generate(request(), onEvent: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testStreamCumulativeTextAndRequiresCompletion() async throws {
        let http = HTTP()
        http.events = [event(["role": "assistant", "content": "A café "]), event(["content": "☕."], finish: "stop")]
        var updates: [String] = []
        let output = try await client(http).stream(request()) { if case .text(let text) = $0 { updates.append(text) } }
        XCTAssertEqual(updates, ["A café ", "A café ☕."])
        XCTAssertEqual(output.text, "A café ☕.")
        http.events = [event(["content": "partial"])]
        do { _ = try await client(http).stream(request(), onEvent: { _ in }); XCTFail("Truncated stream accepted") } catch {}
        http.events = [event(["content": "partial"], finish: "length")]
        do { _ = try await client(http).stream(request(), onEvent: { _ in }); XCTFail("Token-limited stream accepted") } catch {}
    }

    func testStreamAccumulatesMultipleToolArgumentsBeforeValidation() async throws {
        let http = HTTP()
        http.events = [
            event(["tool_calls": [["index": 0, "id": "a", "type": "function", "function": ["name": "find_items", "arguments": "{\"query\":"]], ["index": 1, "id": "b", "type": "function", "function": ["name": "find_items", "arguments": "{\"query\":\"eggs\"}"]]]]),
            event(["tool_calls": [["index": 0, "function": ["arguments": "\"milk\"}"]]]], finish: "tool_calls")
        ]
        let output = try await client(http).stream(request(tools: true), onEvent: { _ in })
        XCTAssertEqual(output.message.toolCalls.map(\.id), ["a", "b"])
        XCTAssertEqual(output.message.toolCalls[0].arguments["query"], .string("milk"))
        http.events.removeLast()
        do { _ = try await client(http).stream(request(tools: true), onEvent: { _ in }); XCTFail("Unfinished tool stream accepted") } catch {}
    }

    func testEndpointValidation() throws {
        for url in ["http://localhost:11434", "http://127.0.0.1:1234/v1", "http://192.168.1.5:8080/v1", "http://10.0.1.2/v1", "http://172.16.1.2/v1", "http://[::1]:8080", "http://[fd12::1]:8080", "https://models.example.com/api/v1"] {
            XCTAssertNoThrow(try OpenAICompatibleClient.validateEndpoint(url), url)
        }
        for url in ["", "file:///tmp/model", "ftp://localhost", "http://8.8.8.8/v1", "http://169.254.169.254/v1", "http://[fe80::1]:8080/v1", "http://172.32.1.2/v1", "http://010.0.0.1/v1", "https://user:pass@host/v1", "http://localhost/v1?key=secret", "http://localhost/v1#fragment", "http://localhost:0/v1"] {
            XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint(url), url)
        }
        // Reject ambiguous numeric IP spellings before the hostname/DNS path can normalize them.
        for host in ["010.0.0.1", "127.1", "2130706433", "0x7f000001", "0x7f.0.0.1", "127.000.0.1", "%30%31%30.0.0.1"] {
            XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://\(host)/v1", addressesForHost: { _ in
                XCTFail("Numeric IP spellings must not be treated as hostnames")
                return ["10.0.0.1"]
            }), host)
        }
        XCTAssertEqual(try OpenAICompatibleClient.validateEndpoint("http://localhost:1234").absoluteString, "http://localhost:1234/v1")
        XCTAssertNoThrow(try OpenAICompatibleClient.validateEndpoint("http://macbook.local/v1", addressesForHost: { _ in ["192.168.1.10"] }))
        XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://macbook.local/v1", addressesForHost: { _ in ["8.8.8.8"] }))
        XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://macbook.local/v1", addressesForHost: { _ in ["192.168.1.10", "93.184.216.34"] }))
        XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://evil.local/v1", addressesForHost: { _ in ["169.254.1.1"] }))
        XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://example.com/v1", addressesForHost: { _ in ["93.184.216.34"] }))
        XCTAssertThrowsError(try OpenAICompatibleClient.validateEndpoint("http://missing.local/v1", addressesForHost: { _ in [] }))
        XCTAssertTrue(OpenAICompatibleClient.isAllowedPrivateAddress("10.0.0.1"))
        XCTAssertFalse(OpenAICompatibleClient.isAllowedPrivateAddress("169.254.1.1"))
        XCTAssertFalse(OpenAICompatibleClient.isAllowedPrivateAddress("fe80::1"))
        XCTAssertTrue(OpenAICompatibleClient.isAllowedPrivateAddress("::ffff:192.168.0.5"))
        XCTAssertFalse(OpenAICompatibleClient.isAllowedPrivateAddress("::ffff:8.8.8.8"))
    }

    func testModelListingUsesSameEndpointAndOptionalKey() async throws {
        let http = HTTP()
        http.response = ["data": [["id": "local/model:Q4"], ["id": "another"], ["id": "local/model:Q4"]]]
        let models = try await OpenAICompatibleClient.availableModels(endpoint: "http://localhost:11434", key: nil, http: http)
        XCTAssertEqual(models, ["another", "local/model:Q4"])
        XCTAssertEqual(http.requests.last?.url?.path, "/v1/models")
        XCTAssertNil(http.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    func testActualTransportDecodesSSEAcrossByteBoundaries() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LocalModelStreamFixture.self]
        let transport = URLSessionCaptionHTTPClient(configuration: configuration)
        var updates: [String] = []
        let response = try await client(transport).stream(request()) { if case .text(let text) = $0 { updates.append(text) } }
        XCTAssertEqual(response.text, "A café ☕.")
        XCTAssertEqual(updates, ["A café ", "A café ☕."])
    }

    func testVideoBecomesTimestampedFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        for _ in 0..<100 { if input.isReadyForMoreMediaData { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer), withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let parts = try await LocalModelMedia.parts(url: url, kind: .video)
        let frames = parts.filter { $0["type"] as? String == "image_url" }
        XCTAssertFalse(frames.isEmpty)
        XCTAssertLessThanOrEqual(frames.count, LocalModelMedia.maximumFrames)
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("Frame at ") == true })
        XCTAssertTrue(parts.contains { ($0["text"] as? String)?.contains("Audio is not included") == true })
    }
}

private final class LocalModelStreamFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = ": keepalive\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"A café \"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"☕.\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        // Split inside multibyte characters and event separators.
        for byte in body.utf8 { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
