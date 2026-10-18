import Foundation

/// Wire translation is kept here, including opaque Gemini thought signatures.
enum GeminiConversationCodec {
    static func encode(_ message: ModelMessage, media: [URL: [[String: Any]]] = [:]) throws -> [String: Any] {
        if let continuation = message.continuation, continuation.provider == .gemini,
           let content = continuation.payload.foundation as? [String: Any] { return content }
        var parts: [[String: Any]] = []
        for result in message.toolResults {
            var response: [String: Any] = ["name": result.name, "response": result.value.foundation]
            if !result.id.hasPrefix("agora-generated-") { response["id"] = result.id }
            parts.append(["functionResponse": response])
        }
        for content in message.content {
            switch content {
            case .text(let text): parts.append(["text": text])
            case .image(let data, let mime): parts.append(["inlineData": ["mimeType": mime, "data": data.base64EncodedString()]])
            case .media(let url, _):
                guard let prepared = media[url] else { throw BrowserError("unsupported_media") }
                parts += prepared
            }
        }
        for call in message.toolCalls { parts.append(["functionCall": call.raw]) }
        return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
    }
    static func decode(_ content: [String: Any]) throws -> ModelMessage {
        guard let parts = content["parts"] as? [[String: Any]], !parts.isEmpty, parts.count <= 256,
              content["role"] == nil || content["role"] as? String == "model" else { throw BrowserError("incomplete_model_response") }
        var message = ModelMessage(role: .assistant)
        var ids = Set<String>()
        for part in parts {
            if let thought = part["thought"], !(thought is Bool) { throw BrowserError("invalid_arguments") }
            if let rawText = part["text"] {
                guard let text = rawText as? String, text.utf8.count <= 128_000 else { throw BrowserError("incomplete_model_response") }
                if part["thought"] as? Bool != true { message.content.append(.text(text)) }
            }
            if let rawCall = part["functionCall"] {
                guard part["thought"] as? Bool != true, let call = rawCall as? [String: Any],
                      let name = call["name"] as? String, validIdentifier(name),
                      let args = call["args"] as? [String: Any],
                      let arguments = try ModelJSON.from(args).object,
                      try JSONEncoder().encode(ModelJSON.object(arguments)).count <= 64_000 else { throw BrowserError("invalid_arguments") }
                let id: String
                if let rawID = call["id"] {
                    guard let supplied = rawID as? String, validIdentifier(supplied) else { throw BrowserError("invalid_arguments") }
                    id = supplied
                } else { id = "agora-generated-\(UUID())" }
                guard ids.insert(id).inserted, message.toolCalls.count < 8 else { throw BrowserError("invalid_arguments") }
                message.toolCalls.append(.init(id: id, name: name, arguments: arguments))
            }
        }
        message.continuation = .init(provider: .gemini, payload: try ModelJSON.from(content))
        return message
    }
    static func validIdentifier(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 128 &&
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

}

@MainActor
final class GeminiModelClient: ModelClient {
    let identity: ModelIdentity
    let capabilities: ModelCapabilities
    private let key: String
    private let http: CaptionHTTPClient
    private let media: GeminiCaptionService

    init(identity: ModelIdentity, capabilities: ModelCapabilities = .gemini, key: String, http: CaptionHTTPClient? = nil) {
        self.identity = identity; self.capabilities = capabilities; self.key = key
        let transport = http ?? URLSessionCaptionHTTPClient(); self.http = transport
        media = GeminiCaptionService(key: key, model: identity.model, http: transport)
    }
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        try await perform(request, streaming: false, onEvent: onEvent)
    }
    func stream(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        // Tool turns are returned atomically, so no partial tool call can execute.
        try await perform(request, streaming: capabilities.streaming && request.tools.isEmpty, onEvent: onEvent)
    }
    private func perform(_ input: ModelRequest, streaming: Bool, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        try validateModelRequest(input, capabilities: capabilities)
        let model = GeminiProvider.normalizedModel(identity.model)
        guard model.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { throw BrowserError("invalid_model") }
        let attachments: [(URL, CaptureItem.Kind)] = input.messages.flatMap { message in
            message.content.compactMap { if case .media(let url, let kind) = $0 { return (url, kind) }; return nil }
        }
        do {
            return try await withMedia(attachments, prepared: [:], onEvent: onEvent) { prepared in
                let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
                var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):\(method)")!)
                request.httpMethod = "POST"; request.timeoutInterval = 180
                request.setValue(self.key, forHTTPHeaderField: "x-goog-api-key")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                var config: [String: Any] = ["maxOutputTokens": input.maxOutputTokens]
                if let schema = input.outputSchema { config["responseMimeType"] = "application/json"; config["responseJsonSchema"] = schema.foundation }
                var body: [String: Any] = ["systemInstruction": ["parts": [["text": input.instructions]]],
                    "contents": try input.messages.map { try GeminiConversationCodec.encode($0, media: prepared) }, "generationConfig": config]
                if !input.tools.isEmpty {
                    body["tools"] = [["functionDeclarations": input.tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters.foundation] }]]
                }
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                // Preserve caption retry behavior; agent/tool turns are never replayed here.
                let attempts = streaming ? 3 : 1
                for attempt in 0..<attempts {
                    do {
                        try Task.checkCancellation(); onEvent(.progress(.generating))
                        if streaming {
                            onEvent(.text(""))
                            var accumulator = CaptionResponseAccumulator()
                            try await self.http.stream(request) { chunk in
                                try accumulator.consume(chunk); onEvent(.text(accumulator.text))
                            }
                            try Task.checkCancellation()
                            return ModelResponse(message: .init(role: .assistant, content: [.text(try accumulator.result())]))
                        }
                        let (data, httpResponse) = try await self.http.data(request)
                        try Task.checkCancellation()
                        guard (200..<300).contains(httpResponse.statusCode) else { throw CaptionHTTPFailure(status: httpResponse.statusCode, body: data) }
                        guard data.count < 8_000_000,
                              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["error"] == nil,
                              (root["promptFeedback"] as? [String: Any])?["blockReason"] == nil,
                              let first = (root["candidates"] as? [[String: Any]])?.first,
                              first["finishReason"] as? String == "STOP",
                              let content = first["content"] as? [String: Any] else {
                            throw BrowserError("incomplete_model_response", "The model returned an incomplete or blocked response. No tools were executed.")
                        }
                        let message = try GeminiConversationCodec.decode(content)
                        try validateModelResponse(message, request: input)
                        return ModelResponse(message: message)
                    } catch {
                        guard attempt + 1 < attempts, GeminiCaptionService.isRetryable(error) else { throw error }
                        onEvent(.progress(.retrying))
                        try await Task.sleep(for: .seconds(pow(2, Double(attempt))))
                    }
                }
                throw BrowserError("provider_error")
            }
        } catch let failure as CaptionHTTPFailure {
            if failure.status == 400, input.outputSchema != nil {
                let hint: String
                switch failure.rejection {
                case .schema:
                    hint = "Google rejected the item-list format for \(model). In Settings → Models, choose an Inventory model that supports structured output."
                case .media:
                    hint = "Google rejected the photo or video for \(model). Try another capture and check that the Inventory model supports images."
                case nil:
                    hint = "Google rejected the identification request for \(model). Check the Inventory model in Settings → Models; it must support images and structured output."
                }
                throw BrowserError("gemini_http_400", hint)
            }
            throw GeminiProvider.responseError(failure.status)
        }
    }
    private func withMedia<T>(_ files: [(URL, CaptureItem.Kind)], prepared: [URL: [[String: Any]]],
                              onEvent: @escaping @MainActor (ModelEvent) -> Void,
                              body: ([URL: [[String: Any]]]) async throws -> T) async throws -> T {
        guard let first = files.first else { return try await body(prepared) }
        if prepared[first.0] != nil { return try await withMedia(Array(files.dropFirst()), prepared: prepared, onEvent: onEvent, body: body) }
        if first.1 == .video && !capabilities.nativeVideo {
            onEvent(.progress(.preparing))
            let samples = try await LocalModelMedia.parts(url: first.0, kind: .video)
            let parts = try samples.map { sample -> [String: Any] in
                if let text = sample["text"] as? String { return ["text": text] }
                guard let image = sample["image_url"] as? [String: Any], let url = image["url"] as? String,
                      url.hasPrefix("data:image/jpeg;base64,") else { throw BrowserError("unsupported_media") }
                return ["inlineData": ["mimeType": "image/jpeg", "data": String(url.dropFirst("data:image/jpeg;base64,".count))]]
            }
            var next = prepared; next[first.0] = parts
            return try await withMedia(Array(files.dropFirst()), prepared: next, onEvent: onEvent, body: body)
        }
        return try await media.withMedia(file: first.0, kind: first.1,
            progress: { onEvent(.progress($0)) }, cleanupNotice: { onEvent(.cleanupNotice($0)) }) { part in
                var next = prepared; next[first.0] = [part]
                return try await self.withMedia(Array(files.dropFirst()), prepared: next, onEvent: onEvent, body: body)
            }
    }
}

func validateModelRequest(_ request: ModelRequest, capabilities: ModelCapabilities) throws {
    if !request.tools.isEmpty && !capabilities.tools { throw BrowserError("model_capability", "This model profile does not support tools. Choose a tool-capable model for Chat.") }
    if request.outputSchema != nil && !capabilities.structuredOutput { throw BrowserError("model_capability", "Choose a model profile with structured output enabled.") }
    for content in request.messages.flatMap(\.content) {
        switch content {
        case .image: guard capabilities.images else { throw BrowserError("model_capability", "Choose a model profile that supports images.") }
        case .media(_, let kind):
            guard kind != .document else { throw BrowserError("unsupported_media", "Document scans remain in your gallery; choose a photo or video.") }
            guard capabilities.images || (kind == .video && capabilities.nativeVideo) else { throw BrowserError("model_capability", "Choose a model profile that supports images or video.") }
        case .text: break
        }
    }
}

func validateModelResponse(_ message: ModelMessage, request: ModelRequest) throws {
    let names = Set(request.tools.map(\.name))
    guard message.toolCalls.count <= 8, Set(message.toolCalls.map(\.id)).count == message.toolCalls.count,
          message.toolCalls.allSatisfy({ names.contains($0.name) && GeminiConversationCodec.validIdentifier($0.id) && GeminiConversationCodec.validIdentifier($0.name) }) else {
        throw BrowserError("invalid_arguments", "The model returned invalid or unsupported tool calls. No tools were executed.")
    }
    guard !message.content.isEmpty || !message.toolCalls.isEmpty else { throw BrowserError("incomplete_model_response") }
}

/// Compatibility seam for existing injected coordinator tests, never used by configured providers.
@MainActor
final class LegacyModelClient: ModelClient {
    let identity = ModelIdentity(provider: .gemini, model: "injected")
    let capabilities = ModelCapabilities.gemini
    let provider: ModelProvider
    init(_ provider: ModelProvider) { self.provider = provider }
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        let response = try await provider.nextTurn(contents: request.messages.map { try GeminiConversationCodec.encode($0) },
            tools: request.tools.map { ["name": $0.name, "description": $0.description, "parameters": $0.parameters.foundation] })
        return ModelResponse(message: try GeminiConversationCodec.decode(response))
    }
}
