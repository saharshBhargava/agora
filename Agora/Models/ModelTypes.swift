import Foundation

/// JSON values at the model boundary. Provider dictionaries never reach feature controllers.
indirect enum ModelJSON: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: ModelJSON]), array([ModelJSON]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self), v.isFinite { self = .number(v) }
        else if let v = try? c.decode([String: ModelJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ModelJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    static func from(_ value: Any) throws -> ModelJSON {
        try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
    }
    var foundation: Any {
        switch self {
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues(\.foundation)
        case .array(let v): return v.map(\.foundation)
        case .null: return NSNull()
        }
    }
    var object: [String: ModelJSON]? { if case .object(let value) = self { return value }; return nil }
}

extension ModelJSON {
    /// Gemini declarations use uppercase primitive names; preserve property names and enum values.
    static func standardSchema(_ schema: ModelJSON) -> ModelJSON {
        switch schema {
        case .array(let values): return .array(values.map(standardSchema))
        case .object(let values):
            var result: [String: ModelJSON] = [:]
            for (key, value) in values {
                if key == "type", case .string(let type) = value { result[key] = .string(type.lowercased()) }
                else if key == "properties", case .object(let properties) = value { result[key] = .object(properties.mapValues(standardSchema)) }
                else if ["$defs", "definitions", "patternProperties", "dependentSchemas"].contains(key), case .object(let schemas) = value { result[key] = .object(schemas.mapValues(standardSchema)) }
                else if key == "type", case .array(let types) = value { result[key] = .array(types.map { if case .string(let name) = $0 { return .string(name.lowercased()) }; return $0 }) }
                else if ["items", "additionalProperties", "anyOf", "allOf", "oneOf", "not", "prefixItems", "if", "then", "else", "contains", "propertyNames", "unevaluatedProperties"].contains(key) { result[key] = standardSchema(value) }
                else { result[key] = value }
            }
            return .object(result)
        default: return schema
        }
    }

}

enum ModelProviderKind: String, Codable, CaseIterable, Identifiable {
    case builtin
    case gemini
    case openAICompatible = "openai-compatible"
    var id: String { rawValue }
    var title: String { self == .builtin ? "Agora" : self == .gemini ? "Google Gemini" : "Local OpenAI-compatible" }
}

struct ModelIdentity: Codable, Equatable {
    let provider: ModelProviderKind
    let model: String
    // Stable local profile ID, never a credential or endpoint URL.
    var profileID: UUID?
}

struct ModelCapabilities: Codable, Equatable {
    var images = false
    var tools = false
    var structuredOutput = false
    var streaming = true
    var nativeVideo = false
    static let gemini = ModelCapabilities(images: true, tools: true, structuredOutput: true, streaming: true, nativeVideo: true)
}

enum ModelFeature: String, Codable, CaseIterable, Identifiable {
    case chat, captions, inventory, suggestions
    var id: String { rawValue }
    var title: String {
        switch self { case .chat: return "Chat"; case .captions: return "Captions"; case .inventory: return "Inventory recognition"; case .suggestions: return "Shopping suggestions" }
    }
}

struct ModelConnection: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var provider: ModelProviderKind
    var endpoint: String
}

struct ModelProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var connectionID: UUID
    var model: String
    var capabilities: ModelCapabilities
}

enum ModelContent {
    case text(String)
    case image(Data, mimeType: String)
    case media(URL, kind: CaptureItem.Kind)
}

struct ModelToolCall {
    let id: String
    let name: String
    let arguments: [String: ModelJSON]
    var raw: [String: Any] { ["id": id, "name": name, "args": arguments.mapValues(\.foundation)] }
}

struct ModelToolResult {
    let id: String
    let name: String
    let value: ModelJSON
}

struct ModelToolDefinition {
    let name: String
    let description: String
    let parameters: ModelJSON
    init(name: String, description: String, parameters: ModelJSON) {
        self.name = name; self.description = description; self.parameters = parameters
    }
    init(legacy: [String: Any]) throws {
        guard let name = legacy["name"] as? String, let description = legacy["description"] as? String,
              let parameters = legacy["parameters"] else { throw BrowserError("invalid_arguments") }
        self.init(name: name, description: description, parameters: try ModelJSON.from(parameters))
    }
}

/// Only the owning adapter interprets this envelope, preserving provider signatures across turns.
struct ModelContinuation {
    let provider: ModelProviderKind
    let payload: ModelJSON
}

struct ModelMessage {
    enum Role { case user, assistant }
    var role: Role
    var content: [ModelContent] = []
    var toolCalls: [ModelToolCall] = []
    var toolResults: [ModelToolResult] = []
    var continuation: ModelContinuation?
}

struct ModelRequest {
    var instructions: String
    var messages: [ModelMessage]
    var tools: [ModelToolDefinition] = []
    var outputSchema: ModelJSON?
    var maxOutputTokens = 4096
}

struct ModelResponse {
    var message: ModelMessage
    var text: String { message.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() }
}

enum ModelEvent {
    case text(String) // Cumulative visible text; retries may reset it to empty.
    case progress(CaptionProgress)
    case cleanupNotice(String)
}

@MainActor
protocol ModelClient {
    var identity: ModelIdentity { get }
    var capabilities: ModelCapabilities { get }
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse
    func stream(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse
}

extension ModelClient {
    func stream(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        let result = try await generate(request, onEvent: onEvent)
        onEvent(.text(result.text))
        return result
    }
}

extension ModelMessage {
    func byteCount() throws -> Int {
        var size = 0
        for part in content {
            switch part {
            case .text(let text): size += text.utf8.count
            case .image(let data, _): size += (data.count * 4 / 3)
            case .media: size += 1024
            }
        }
        for call in toolCalls { size += try JSONEncoder().encode(ModelJSON.object(call.arguments)).count }
        for result in toolResults { size += try JSONEncoder().encode(result.value).count }
        if let continuation { size += try JSONEncoder().encode(continuation.payload).count }
        return size
    }
}
