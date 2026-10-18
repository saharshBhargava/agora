import XCTest
import UIKit
@testable import Agora

private struct ModelWireReply {
    var status = 200
    var headers = ["Content-Type": "application/json"]
    let data: Data
    static func json(_ value: Any, status: Int = 200) throws -> Self {
        .init(status: status, data: try JSONSerialization.data(withJSONObject: value))
    }
}

/// Real URLSession transport plus deterministic responses; model and credential data never leave this protocol.
private final class ModelWireProtocol: URLProtocol {
    @MainActor static var handler: ((URLRequest) async throws -> ModelWireReply)?
    private var operation: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        operation = Task { @MainActor [self] in
            do {
                guard let handler = Self.handler else { throw URLError(.unsupportedURL) }
                let reply = try await handler(request)
                try Task.checkCancellation()
                let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil,
                                               headerFields: reply.headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: reply.data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { operation?.cancel() }
}

private func modelWireBody(_ request: URLRequest) throws -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
    }
    return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@MainActor
final class ModelIntegrationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var settings: SettingsStore!
    private var suite: String!
    private var service: String!
    private var http: URLSessionCaptionHTTPClient!
    private let localConnectionID = UUID(), localProfileID = UUID()
    private var capabilities: ModelCapabilities {
        .init(images: true, tools: true, structuredOutput: true, streaming: true, nativeVideo: false)
    }
    private var localConnection: ModelConnection {
        .init(id: localConnectionID, name: "Laptop", provider: .openAICompatible, endpoint: "http://127.0.0.1:1234/v1")
    }
    override func setUp() async throws {
        suite = "app.agora.model-tests.defaults.\(UUID())"
        service = "app.agora.model-tests.keys.\(UUID())"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        settings = SettingsStore(keychainService: service, defaults: defaults)
        var config = settings.modelConfiguration
        config.connections.append(localConnection)
        config.profiles.append(.init(id: localProfileID, name: "Local vision", connectionID: localConnectionID,
                                     model: "org/vision:Q4_K_M", capabilities: capabilities))
        settings.modelConfiguration = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelWireProtocol.self]
        http = URLSessionCaptionHTTPClient(configuration: configuration)
    }
    override func tearDown() async throws {
        ModelWireProtocol.handler = nil
        for connection in settings.modelConfiguration.connections { try? settings.deleteConnectionKey(connection) }
        defaults.removePersistentDomain(forName: suite)
        http = nil; settings = nil; defaults = nil
    }
    private func client(_ provider: ModelProviderKind) -> ModelClient {
        let identity = ModelIdentity(provider: provider, model: provider == .gemini ? "gemini-flash-latest" : "org/vision:Q4_K_M")
        if provider == .gemini { return GeminiModelClient(identity: identity, key: "gemini-private-key", http: http) }
        return OpenAICompatibleClient(identity: identity, capabilities: capabilities,
                                      endpoint: localConnection.endpoint, key: nil, http: http)
    }
    private func response(_ provider: ModelProviderKind, text: String) -> [String: Any] {
        if provider == .gemini {
            return ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": text]]]]]]
        }
        return ["choices": [["index": 0, "finish_reason": "stop", "message": ["role": "assistant", "content": text]]]]
    }
    private func streamingResponse(_ provider: ModelProviderKind, text: String) throws -> ModelWireReply {
        let event: [String: Any]
        if provider == .gemini { event = response(provider, text: text) }
        else { event = ["choices": [["index": 0, "finish_reason": "stop", "delta": ["role": "assistant", "content": text]]]] }
        let data = try JSONSerialization.data(withJSONObject: event)
        return .init(headers: ["Content-Type": "text/event-stream"],
                     data: Data("data: ".utf8) + data + Data("\n\ndata: [DONE]\n\n".utf8))
    }
    private func photo() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Operation did not finish before the test deadline")
    }

    func testDefaultFeatureOverrideAndExplicitRequestRoutingPersistOnRelaunch() throws {
        settings.modelConfiguration.defaultProfileID = localProfileID
        settings.modelConfiguration.assignments[ModelFeature.inventory.rawValue] = ModelConfiguration.geminiProfileID
        XCTAssertEqual(try settings.client(for: .chat, http: http).identity.provider, .openAICompatible)
        XCTAssertEqual(try settings.client(for: .captions, http: http).identity.model, "org/vision:Q4_K_M")
        XCTAssertEqual(try settings.modelConfiguration.profile(for: .inventory).id, ModelConfiguration.geminiProfileID)
        XCTAssertEqual(try settings.client(for: .inventory, profileID: localProfileID, http: http).identity.profileID, localProfileID)
        let reloaded = SettingsStore(keychainService: service, defaults: defaults)
        XCTAssertEqual(reloaded.modelConfiguration, settings.modelConfiguration)
        XCTAssertEqual(try reloaded.client(for: .chat, http: http).identity.profileID, localProfileID)
        XCTAssertThrowsError(try settings.modelConfiguration.profile(for: .chat, override: UUID()))
    }

    func testLegacyGeminiMigrationPreservesCustomModelAndExistingKey() throws {
        let oldSuite = "app.agora.model-tests.migration.\(UUID())"
        let oldDefaults = try XCTUnwrap(UserDefaults(suiteName: oldSuite))
        defer { oldDefaults.removePersistentDomain(forName: oldSuite) }
        oldDefaults.set("gemini-2.5-flash", forKey: "gemini.model")
        let migrated = SettingsStore(keychainService: service, defaults: oldDefaults)
        XCTAssertEqual(migrated.model, "gemini-flash-latest")
        XCTAssertEqual(try migrated.modelConfiguration.profile(for: .chat).model, migrated.model)
        try migrated.saveKey("existing-gemini-key")
        let relaunched = SettingsStore(keychainService: service, defaults: oldDefaults)
        XCTAssertEqual(try relaunched.connectionKey(relaunched.modelConfiguration.connections[0]), "existing-gemini-key")
        XCTAssertEqual(try relaunched.client(for: .captions, http: http).identity.provider, .gemini)
        oldDefaults.removeObject(forKey: "models.configuration.v1")
        oldDefaults.set("gemini-custom-model", forKey: "gemini.model")
        XCTAssertEqual(SettingsStore(keychainService: service, defaults: oldDefaults).model, "gemini-custom-model")
    }

    func testCorruptPersistedConfigurationFailsClosedDespiteExistingGeminiKey() throws {
        try settings.saveKey("existing-cloud-key")
        defaults.set(Data("{broken model configuration".utf8), forKey: "models.configuration.v1")
        let relaunched = SettingsStore(keychainService: service, defaults: defaults)
        XCTAssertTrue(relaunched.hasKey)
        XCTAssertNotNil(relaunched.modelConfigurationIssue)
        XCTAssertTrue(relaunched.modelConfiguration.connections.isEmpty)
        XCTAssertTrue(relaunched.modelConfiguration.profiles.isEmpty)
        for feature in ModelFeature.allCases {
            XCTAssertThrowsError(try relaunched.client(for: feature, http: http))
            XCTAssertFalse(relaunched.isConfigured(for: feature))
        }
        XCTAssertEqual(defaults.data(forKey: "models.configuration.v1"), Data("{broken model configuration".utf8))
    }

    func testKeysAreIsolatedByConnectionAndEndpointAndNeverCopiedIntoDefaults() throws {
        try settings.saveKey("gemini-credential")
        try settings.saveConnectionKey("local-credential", connection: localConnection)
        XCTAssertEqual(try settings.connectionKey(localConnection), "local-credential")
        XCTAssertEqual(try settings.apiKey(), "gemini-credential")
        var other = localConnection; other.id = UUID()
        XCTAssertNil(try settings.connectionKey(other))
        var changed = localConnection; changed.endpoint = "http://127.0.0.1:4321/v1"
        XCTAssertNil(try settings.connectionKey(changed))
        changed = localConnection; changed.provider = .gemini
        XCTAssertNil(try settings.connectionKey(changed))
        let persisted = try XCTUnwrap(defaults.data(forKey: "models.configuration.v1"))
        let json = String(decoding: persisted, as: UTF8.self)
        XCTAssertFalse(json.contains("credential")); XCTAssertFalse(json.contains("apiKey"))
        try settings.deleteConnectionKey(localConnection)
        XCTAssertNil(try settings.connectionKey(localConnection))
        XCTAssertEqual(try settings.apiKey(), "gemini-credential")
    }

    func testNativeVideoOnlyGeminiProfileAllowsVideoButRequiresImagesForPhotosAndLocalFrames() throws {
        try settings.saveKey("video-model-key")
        settings.modelConfiguration.profiles[0].capabilities.images = false
        settings.modelConfiguration.profiles[0].capabilities.nativeVideo = true
        for feature in [ModelFeature.captions, .inventory] {
            XCTAssertEqual(try settings.client(for: feature, http: http, kind: .video).identity.provider, .gemini)
            XCTAssertThrowsError(try settings.client(for: feature, http: http, kind: .image))
        }
        settings.modelConfiguration.defaultProfileID = localProfileID
        settings.modelConfiguration.profiles[1].capabilities.images = false
        settings.modelConfiguration.profiles[1].capabilities.nativeVideo = true
        for feature in [ModelFeature.captions, .inventory] {
            XCTAssertThrowsError(try settings.client(for: feature, http: http, kind: .video))
            XCTAssertThrowsError(try settings.client(for: feature, http: http, kind: .image))
        }
    }

    func testMissingCapabilitiesFailBeforeNetworkAndNeverUseGeminiKeyForLocal() async throws {
        settings.modelConfiguration.defaultProfileID = localProfileID
        try settings.saveKey("gemini-only")
        settings.modelConfiguration.profiles[1].capabilities.tools = false
        XCTAssertThrowsError(try settings.client(for: .chat, http: http))
        settings.modelConfiguration.profiles[1].capabilities.images = false
        XCTAssertThrowsError(try settings.client(for: .captions, http: http))
        settings.modelConfiguration.profiles[1].capabilities.images = true
        settings.modelConfiguration.profiles[1].capabilities.structuredOutput = false
        XCTAssertThrowsError(try settings.client(for: .inventory, http: http))
        settings.modelConfiguration.profiles[1].capabilities = capabilities
        var count = 0
        ModelWireProtocol.handler = { request in
            count += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
            return try .json(self.response(.openAICompatible, text: "Hello locally."))
        }
        let response = try await settings.client(for: .chat, http: http).generate(
            .init(instructions: "Be helpful", messages: [.init(role: .user, content: [.text("Hello")])]), onEvent: { _ in })
        XCTAssertEqual(response.text, "Hello locally."); XCTAssertEqual(count, 1)
    }

    func testBothProvidersTranslateImagesStructuredSchemaAndCredentials() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let image = try Data(contentsOf: file)
        let schema = try ModelJSON.from(["type": "object", "properties": ["items": ["type": "array", "items": ["type": "string"]]], "required": ["items"]])
        for provider in ModelProviderKind.allCases {
            ModelWireProtocol.handler = { request in
                let body = try modelWireBody(request)
                if provider == .gemini {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gemini-private-key")
                    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                    let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
                    XCTAssertTrue(parts.contains { $0["inlineData"] != nil })
                    XCTAssertNotNil((body["generationConfig"] as? [String: Any])?["responseJsonSchema"])
                } else {
                    XCTAssertEqual(request.url?.path, "/v1/chat/completions")
                    XCTAssertNil(request.value(forHTTPHeaderField: "x-goog-api-key"))
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let content = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])
                    XCTAssertTrue(content.contains { ($0["image_url"] as? [String: Any])?["url"] as? String != nil })
                    XCTAssertEqual((body["response_format"] as? [String: Any])?["type"] as? String, "json_schema")
                }
                XCTAssertNil(body["tools"])
                return try .json(self.response(provider, text: "{\"items\": []}"))
            }
            let result = try await client(provider).generate(.init(instructions: "Identify visible items", messages: [
                .init(role: .user, content: [.text("Identify"), .image(image, mimeType: "image/jpeg")])], outputSchema: schema), onEvent: { _ in })
            XCTAssertEqual(result.text, "{\"items\": []}")
        }
    }

    func testBothProvidersStreamThroughRealURLSessionTransport() async throws {
        for provider in ModelProviderKind.allCases {
            ModelWireProtocol.handler = { _ in try self.streamingResponse(provider, text: "A blue square.") }
            var text: [String] = []
            let result = try await client(provider).stream(.init(instructions: "Describe", messages: [
                .init(role: .user, content: [.text("What is visible?")])]), onEvent: { if case .text(let value) = $0 { text.append(value) } })
            XCTAssertEqual(result.text, "A blue square.")
            XCTAssertEqual(text.last, "A blue square.")
        }
    }

    func testPhotoRecognitionUsesSupportedSchemaThroughBothGeminiPaths() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        // Emulate Google's supported schema subset, including rejection of unsupported string bounds.
        func supported(_ schema: [String: Any]) -> Bool {
            let keywords: Set<String> = ["type", "properties", "required", "additionalProperties", "items", "minimum", "maximum"]
            guard Set(schema.keys).isSubset(of: keywords) else { return false }
            if let properties = schema["properties"] as? [String: [String: Any]], !properties.values.allSatisfy(supported) { return false }
            if let items = schema["items"] as? [String: Any], !supported(items) { return false }
            return true
        }
        var calls = 0
        ModelWireProtocol.handler = { request in
            calls += 1
            XCTAssertEqual(request.url?.host, "generativelanguage.googleapis.com")
            let body = try modelWireBody(request)
            XCTAssertNil(body["tools"])
            let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
            XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
            let schema = try XCTUnwrap(config["responseJsonSchema"] as? [String: Any])
            guard supported(schema) else {
                return try .json(["error": ["message": "Unsupported response JSON schema constraint"]], status: 400)
            }
            let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
            let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
            XCTAssertNotNil(parts.first?["inlineData"])
            return try .json(self.response(.gemini, text: #"{"items":[{"name":"Milk","brand":"Organic Valley","variant":"Whole","packageSize":"1/2 gallon","category":"Food","unit":"unit","quantity":1,"confidence":0.9}]}"#))
        }
        let services: [InventoryRecognizing] = [ModelInventoryService(client: client(.gemini)),
            GeminiInventoryService(key: "gemini-private-key", model: "gemini-flash-latest", http: http)]
        for service in services {
            let items = try await service.recognize(file: file, kind: .image, progress: { _ in }, cleanupNotice: { _ in })
            XCTAssertEqual(items.map(\.name), ["Organic Valley Milk, Whole, 1/2 gallon"])
        }
        XCTAssertEqual(calls, 2)
    }

    func testRecognitionStillEnforcesLocalLengthCountAndQuantityLimits() throws {
        let valid: [String: Any] = ["name": "Milk", "category": "Food", "unit": "unit", "quantity": 1, "confidence": 0.9]
        var invalid: [[String: Any]] = []
        for (field, value) in [("name", String(repeating: "n", count: 121)), ("unit", String(repeating: "u", count: 21)),
                               ("category", String(repeating: "c", count: 41)), ("name", " "),
                               ("brand", String(repeating: "b", count: 81)), ("variant", String(repeating: "v", count: 81)),
                               ("packageSize", String(repeating: "s", count: 41))] {
            var item = valid; item[field] = value; invalid.append(item)
        }
        var negative = valid; negative["quantity"] = -1; invalid.append(negative)
        var confidence = valid; confidence["confidence"] = 2; invalid.append(confidence)
        for items in invalid.map({ [$0] }) + [Array(repeating: valid, count: 101)] {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["items": items]), as: UTF8.self)
            XCTAssertThrowsError(try InventoryRecognitionContract.decode(text))
        }
    }

    func testRecognitionNamesUseKnownDetailsWithoutDuplicatesOrInventedValues() throws {
        let cases: [(String, String, String, String, String)] = [
            ("Milk", "Organic Valley", "Whole", "1/2 gallon", "Organic Valley Milk, Whole, 1/2 gallon"),
            ("Organic Valley Whole Milk, 1/2 gallon", "Organic Valley", "Whole", "1/2 gallon", "Organic Valley Whole Milk, 1/2 gallon"),
            (" Blue   upholstered armchair ", "", "", "", "Blue upholstered armchair"),
            ("Milk", "unknown", "N/A", "unreadable", "Milk"),
            ("Dovetail soap dish", "Dove", "", "", "Dove Dovetail soap dish"),
            ("Soap", " Dove ", " Sensitive skin ", " 500 mL ", "Dove Soap, Sensitive skin, 500 mL"),
            (String(repeating: "A", count: 120), "Brand", "Variant", "1 L", String(repeating: "A", count: 120))
        ]
        for (name, brand, variant, size, expected) in cases {
            let json: [String: Any] = ["items": [["name": name, "brand": brand, "variant": variant, "packageSize": size,
                "category": "Household", "unit": "unit", "quantity": 2, "confidence": 0.9]]]
            let items = try InventoryRecognitionContract.decode(String(decoding: JSONSerialization.data(withJSONObject: json), as: UTF8.self))
            XCTAssertEqual(items.first?.name, expected)
            XCTAssertEqual(items.first?.quantity, 2) // Labelled volume must never become the observed count.
            XCTAssertEqual(items.first?.unit, "unit")
        }
        let legacy = try InventoryRecognitionContract.decode(#"{"items":[{"name":"Milk","category":"Food","unit":"unit","quantity":1,"confidence":0.9}]}"#)
        XCTAssertEqual(legacy.first?.name, "Milk")
    }

    func testRecognitionKeepsDifferentVariantsAndSizesSeparate() throws {
        let items = try InventoryRecognitionContract.decode(#"{"items":[{"name":"Milk","brand":"Organic Valley","variant":"Whole","packageSize":"1/2 gallon","category":"Food","unit":"unit","quantity":1,"confidence":0.9},{"name":"Milk","brand":"Organic Valley","variant":"2%","packageSize":"1 gallon","category":"Food","unit":"unit","quantity":2,"confidence":0.9}]}"#)
        XCTAssertEqual(items.map(\.name), ["Organic Valley Milk, Whole, 1/2 gallon", "Organic Valley Milk, 2%, 1 gallon"])
        XCTAssertEqual(items.map(\.quantity), [1, 2])
    }

    func testPhotoRecognition400UsesContextAndDoesNotExposeProviderBody() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        for (reason, expected) in [("responseJsonSchema has unsupported constraints", "item-list format"),
                                   ("Unable to decode image", "photo or video"), ("Invalid argument", "identification request")] {
            var calls = 0
            ModelWireProtocol.handler = { _ in
                calls += 1
                return try .json(["error": ["message": reason + " private-user-data gemini-private-key"]], status: 400)
            }
            do {
                _ = try await ModelInventoryService(client: client(.gemini)).recognize(file: file, kind: .image,
                    progress: { _ in }, cleanupNotice: { _ in })
                XCTFail("Rejected recognition must not produce items")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("gemini-flash-latest"))
                XCTAssertFalse(error.localizedDescription.contains("function calling"))
                XCTAssertFalse(error.localizedDescription.contains("private-user-data"))
                XCTAssertFalse(error.localizedDescription.contains("gemini-private-key"))
            }
            XCTAssertEqual(calls, 1)
        }
    }

    func testBothProvidersRejectMalformedToolArgumentsBeforeReturningCalls() async throws {
        let tool = try ModelToolDefinition(legacy: BrowserCall.schemas[0])
        for provider in ModelProviderKind.allCases {
            ModelWireProtocol.handler = { _ in
                if provider == .gemini {
                    return try .json(["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [
                        ["functionCall": ["name": tool.name, "args": "malformed JSON"]]]]]]])
                }
                return try .json(["choices": [["index": 0, "finish_reason": "tool_calls", "message": ["role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": "invalid", "type": "function", "function": ["name": tool.name, "arguments": "{broken"]]]]]]])
            }
            do {
                _ = try await client(provider).generate(.init(instructions: "Use the browser", messages: [
                    .init(role: .user, content: [.text("Read")])], tools: [tool]), onEvent: { _ in })
                XCTFail("Malformed arguments must never leave the adapter")
            } catch { XCTAssertFalse(error.localizedDescription.contains("private-key")) }
        }
    }
}

@MainActor
private final class ModelInventoryAuthorization: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "model-integration-account", email: "alex@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused-calendar-token" }
    func idToken(for accountID: String) async throws -> String { "inventory-identity-token" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

extension ModelIntegrationTests {
    func testBothProvidersCoordinatorToolResultFinalAndGeminiSignatureRoundTrip() async throws {
        for provider in ModelProviderKind.allCases {
            let browser = BrowserSession(policy: BrowserPolicy())
            let agent = AgentCoordinator(settings: settings, browser: browser)
            agent.modelClientOverride = client(provider)
            defer { agent.stop(); browser.close() }
            var turns = 0
            ModelWireProtocol.handler = { request in
                turns += 1
                let body = try modelWireBody(request)
                if turns == 1 {
                    if provider == .gemini {
                        return try .json(["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [[
                            "thoughtSignature": "retain-this-signature", "functionCall": ["id": "observe-1", "name": "browser_observe", "args": [:]]]]]]]])
                    }
                    return try .json(["choices": [["index": 0, "finish_reason": "tool_calls", "message": [
                        "role": "assistant", "content": NSNull(), "tool_calls": [["id": "observe-1", "type": "function",
                        "function": ["name": "browser_observe", "arguments": "{}"]]]]]]])
                }
                XCTAssertEqual(turns, 2)
                if provider == .gemini {
                    let contents = try XCTUnwrap(body["contents"] as? [[String: Any]])
                    let original = try XCTUnwrap(contents[1]["parts"] as? [[String: Any]])
                    XCTAssertEqual(original.first?["thoughtSignature"] as? String, "retain-this-signature")
                    let parts = try XCTUnwrap(contents.last?["parts"] as? [[String: Any]])
                    let result = try XCTUnwrap(parts.first?["functionResponse"] as? [String: Any])
                    XCTAssertEqual(result["id"] as? String, "observe-1")
                    XCTAssertEqual(result["name"] as? String, "browser_observe")
                } else {
                    let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
                    let result = try XCTUnwrap(messages.last)
                    XCTAssertEqual(result["role"] as? String, "tool")
                    XCTAssertEqual(result["tool_call_id"] as? String, "observe-1")
                    XCTAssertTrue((result["content"] as? String)?.contains("error") == true)
                }
                return try .json(self.response(provider, text: "Please open a page first."))
            }
            agent.send("Read the page")
            try await waitUntil { !agent.running }
            XCTAssertEqual(turns, 2); XCTAssertNil(agent.approval)
            XCTAssertEqual(agent.messages.last?.text, "Please open a page first.")
            XCTAssertFalse(browser.state.isOpen)
            agent.newChat(); XCTAssertTrue(agent.messages.isEmpty)
        }
    }

    func testMalformedModelToolBatchDoesNotReachCoordinatorExecutor() async throws {
        let browser = BrowserSession(policy: BrowserPolicy())
        let agent = AgentCoordinator(settings: settings, browser: browser)
        agent.modelClientOverride = client(.openAICompatible)
        defer { agent.stop(); browser.close() }
        var requests = 0
        ModelWireProtocol.handler = { _ in
            requests += 1
            return try .json(["choices": [["index": 0, "finish_reason": "tool_calls", "message": [
                "role": "assistant", "content": NSNull(), "tool_calls": [
                    ["id": "first", "type": "function", "function": ["name": "browser_observe", "arguments": "{}"]],
                    ["id": "bad", "type": "function", "function": ["name": "browser_open", "arguments": "{invalid"]]
                ]]]]])
        }
        agent.send("Read a page")
        try await waitUntil { !agent.running }
        XCTAssertEqual(requests, 1); XCTAssertNil(agent.approval); XCTAssertFalse(browser.state.isOpen)
        XCTAssertFalse(agent.messages.contains { $0.role == "assistant" })
        XCTAssertTrue(agent.messages.contains { $0.role == "notice" })
    }

    func testChangingChatProfileCancelsInflightWorkAndClearsConversationContext() async throws {
        let browser = BrowserSession(policy: BrowserPolicy())
        let agent = AgentCoordinator(settings: settings, browser: browser)
        agent.modelClientOverride = client(.openAICompatible)
        defer { agent.stop(); browser.close() }
        var requests = 0
        var nextBody: [String: Any]?
        ModelWireProtocol.handler = { request in
            requests += 1
            if requests == 1 { try await Task.sleep(for: .seconds(30)) }
            else { nextBody = try modelWireBody(request) }
            return try .json(self.response(.openAICompatible, text: "Fresh model conversation."))
        }
        agent.send("Private previous task")
        try await waitUntil { requests == 1 }
        let revision = settings.chatRevision
        settings.modelConfiguration.assignments[ModelFeature.captions.rawValue] = localProfileID
        XCTAssertEqual(settings.chatRevision, revision); XCTAssertTrue(agent.running)
        settings.modelConfiguration.defaultProfileID = localProfileID
        XCTAssertFalse(agent.running)
        XCTAssertGreaterThan(settings.chatRevision, revision)
        agent.send("Fresh task")
        try await waitUntil { !agent.running && nextBody != nil }
        let wire = try JSONSerialization.data(withJSONObject: XCTUnwrap(nextBody))
        let text = String(decoding: wire, as: UTF8.self)
        XCTAssertFalse(text.contains("Private previous task")); XCTAssertTrue(text.contains("Fresh task"))
        XCTAssertEqual(agent.messages.last?.text, "Fresh model conversation.")
    }

    func testBothProvidersCaptionControllerGeneratesAndPersistsGenericProvenance() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let item = CaptureItem(id: UUID(), kind: .image, filename: file.lastPathComponent, createdAt: Date())
        for provider in ModelProviderKind.allCases {
            let model = client(provider)
            var requests = 0
            ModelWireProtocol.handler = { request in
                requests += 1
                let body = try modelWireBody(request)
                XCTAssertNil(body["tools"])
                return try self.streamingResponse(provider, text: "A blue square.")
            }
            let controller = CaptionController()
            controller.style = .detailed; controller.instruction = "Use plain language."
            var saved: SavedCaption?
            controller.start(item: item, file: file, model: model.identity.model,
                             provider: ModelCaptionService(client: model), identity: model.identity) { saved = $0 }
            try await waitUntil { !controller.busy }
            let value = try XCTUnwrap(saved)
            XCTAssertEqual(value.text, "A blue square."); XCTAssertEqual(value.style, .detailed)
            XCTAssertEqual(value.provider, provider); XCTAssertEqual(value.model, model.identity.model)
            XCTAssertEqual(controller.message, "Caption saved."); XCTAssertEqual(requests, 1)
            XCTAssertEqual(try JSONDecoder().decode(SavedCaption.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testBothProvidersRecognitionReviewSaveAndRestartKeepExactMetadata() async throws {
        for provider in ModelProviderKind.allCases {
            let calendar = CalendarConnection(authorization: ModelInventoryAuthorization())
            await calendar.refresh()
            let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ModelWireProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let store = InventoryStore(api: AgoraClient(calendar: calendar,
                baseURL: URL(string: "https://inventory.model-tests.invalid"), http: session), calendar: calendar)
            let household = UUID(), inventoryID = UUID(), recognitionID = UUID()
            var item: [String: Any] = ["id": inventoryID.uuidString, "household_id": household.uuidString,
                "display_name": "Organic Valley Milk, Whole, 1/2 gallon", "unit": "cartons", "quantity": 1, "status": "active"]
            var submissions: [[String: Any]] = []
            var keys: [String] = []
            ModelWireProtocol.handler = { request in
                if request.url?.host == "inventory.model-tests.invalid" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer inventory-identity-token")
                    if request.url!.path.hasSuffix("/me") {
                        return try .json(["households": [["id": household.uuidString, "name": "Home", "locations": []]]])
                    }
                    if request.url!.path.hasSuffix("/recognitions") {
                        let body = try modelWireBody(request)
                        submissions.append(body)
                        keys.append(try XCTUnwrap(request.value(forHTTPHeaderField: "Idempotency-Key")))
                        XCTAssertEqual(body["provider"] as? String ?? "gemini", provider.rawValue)
                        let entries = try XCTUnwrap(body["items"] as? [[String: Any]])
                        XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0]["quantity"] as? Double, 4.5)
                        XCTAssertEqual(entries[0]["display_name"] as? String, "Organic Valley Milk, Whole, 1/2 gallon")
                        XCTAssertNil(body["image"]); XCTAssertNil(body["file_uri"]); XCTAssertNil(body["frame_keys"])
                        if submissions.count == 1 { return try .json(["title": "unavailable", "detail": "Try again"], status: 503) }
                        item["quantity"] = 4.5
                        return try .json(["recognition_id": recognitionID.uuidString, "items": [item]])
                    }
                    return try .json([item])
                }
                let text = #"{"items":[{"name":"Milk","brand":"Organic Valley","variant":"Whole","packageSize":"1/2 gallon","category":"dairy","unit":"cartons","quantity":2,"confidence":0.93},{"name":"Uncertain jar","brand":"","variant":"","packageSize":"","category":"other","unit":"unit","quantity":1,"confidence":0.3}]}"#
                return try .json(self.response(provider, text: text))
            }
            await store.refresh(); XCTAssertNil(store.error)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let library = MediaLibrary(directory: directory)
            let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
            await library.add(file: file, kind: .image)
            let capture = try XCTUnwrap(library.items.first)
            let model = client(provider), controller = RecognitionController()
            controller.recognize(item: capture, file: library.url(for: capture), model: model.identity.model,
                provider: ModelInventoryService(client: model), store: store, identity: model.identity)
            try await waitUntil { !controller.busy }
            XCTAssertEqual(controller.drafts.count, 2)
            XCTAssertEqual(controller.drafts.first?.name, "Organic Valley Milk, Whole, 1/2 gallon")
            XCTAssertEqual(controller.drafts.first?.inventoryItemID, inventoryID)
            controller.drafts[0].quantity = "4.5"; controller.drafts[1].included = false
            await controller.save(item: capture, store: store, library: library)
            XCTAssertTrue(controller.locked); XCTAssertFalse(controller.completed)
            let restarted = MediaLibrary(directory: directory); await restarted.load()
            let pending = try XCTUnwrap(restarted.items.first?.recognition)
            XCTAssertEqual(pending.provider, provider)
            let retry = RecognitionController(); retry.restore(pending)
            retry.drafts[0].quantity = "99"
            await retry.save(item: capture, store: store, library: restarted)
            XCTAssertTrue(retry.completed); XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1])
            XCTAssertEqual(submissions[0] as NSDictionary, submissions[1] as NSDictionary)
            XCTAssertEqual(store.items.first?.quantity, 4.5)
            await restarted.load(); XCTAssertEqual(restarted.items.first?.recognition?.recognitionID, recognitionID)
        }
    }

    func testBothProvidersRejectInvalidRecognitionBeforeShowingReviewItems() async throws {
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        for provider in ModelProviderKind.allCases {
            for text in [#"{"items":[{"name":"Milk","category":"dairy","unit":"unit","quantity":-1,"confidence":0.9}]}"#,
                         #"{"items":[{"name":"Milk","category":"dairy","unit":"unit","quantity":1,"confidence":2}]}"#,
                         "not JSON"] {
                ModelWireProtocol.handler = { _ in try .json(self.response(provider, text: text)) }
                do {
                    _ = try await ModelInventoryService(client: client(provider)).recognize(file: file, kind: .image,
                        progress: { _ in }, cleanupNotice: { _ in XCTFail("Images are not uploaded to a Files API") })
                    XCTFail("Invalid model items must not reach review")
                } catch { XCTAssertEqual((error as? CaptionFailure)?.code, "invalid_recognition") }
            }
        }
    }

    func testLegacySavedMetadataDecodesWithoutProviderAndKeepsGeminiRequestShape() throws {
        let caption = SavedCaption(text: "An older caption", style: .short, model: "gemini-flash-latest", generatedAt: Date())
        var captionJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(caption)) as? [String: Any])
        captionJSON.removeValue(forKey: "provider")
        let restoredCaption = try JSONDecoder().decode(SavedCaption.self, from: JSONSerialization.data(withJSONObject: captionJSON))
        XCTAssertNil(restoredCaption.provider)
        let recognition = SavedRecognition(key: UUID(), accountID: "account", householdID: UUID(), capturedAt: Date(),
            mediaKind: "photos", model: "gemini-flash-latest", locationID: nil, merchantID: nil, purchasedOn: nil, items: [])
        var recognitionJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(recognition)) as? [String: Any])
        recognitionJSON.removeValue(forKey: "provider")
        let restored = try JSONDecoder().decode(SavedRecognition.self, from: JSONSerialization.data(withJSONObject: recognitionJSON))
        XCTAssertNil(restored.provider); XCTAssertNil(restored.body["provider"])
    }

    /// Start scripts/model-fixture-server.py to enable this real loopback socket smoke test.
    func testLoopbackServerChatToolsCaptionAndRecognition() async throws {
        let health = URL(string: "http://127.0.0.1:18766/healthz")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: health); request.timeoutInterval = 0.3
        do {
            let (data, _) = try await session.data(for: request)
            let value = try JSONSerialization.jsonObject(with: data) as? [String: String]
            guard value?["fixture"] == "agora-model-fixture-v1" else { throw XCTSkip("Start scripts/model-fixture-server.py") }
        } catch { throw XCTSkip("Start scripts/model-fixture-server.py for the loopback integration smoke test") }
        let endpoint = "http://127.0.0.1:18766/v1"
        let models = try await OpenAICompatibleClient.availableModels(endpoint: endpoint, key: nil)
        XCTAssertEqual(models, ["agora-fixture/vision:local"])
        let model = OpenAICompatibleClient(identity: .init(provider: .openAICompatible, model: models[0]),
            capabilities: capabilities, endpoint: endpoint, key: nil)
        let agent = AgentCoordinator(settings: settings, browser: BrowserSession(policy: BrowserPolicy()))
        agent.modelClientOverride = model; defer { agent.stop(); agent.browser.close() }
        agent.send("Read the page")
        try await waitUntil { !agent.running }
        XCTAssertEqual(agent.messages.last?.text, "The browser tool completed. Open a page to continue.")
        let file = try photo(); defer { try? FileManager.default.removeItem(at: file) }
        let caption = try await ModelCaptionService(client: model).caption(file: file, kind: .image, style: .short,
            instruction: "", progress: { _ in }, text: { _ in }, cleanupNotice: { _ in })
        XCTAssertEqual(caption, "A blue square on a plain background.")
        let recognized = try await ModelInventoryService(client: model).recognize(file: file, kind: .image,
            progress: { _ in }, cleanupNotice: { _ in })
        XCTAssertEqual(recognized.first?.name, "Milk"); XCTAssertEqual(recognized.first?.quantity, 2)
    }
}
