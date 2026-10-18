import Foundation

struct ModelConfiguration: Codable, Equatable {
    static let geminiConnectionID = UUID(uuidString: "E7F72F58-1111-4444-8888-000000000001")!
    static let geminiProfileID = UUID(uuidString: "E7F72F58-1111-4444-8888-000000000002")!
    var connections: [ModelConnection]
    var profiles: [ModelProfile]
    var defaultProfileID: UUID
    var assignments: [String: UUID] = [:]

    static func initial(geminiModel: String) -> Self {
        .init(connections: [.init(id: geminiConnectionID, name: "Google Gemini", provider: .gemini, endpoint: "")],
              profiles: [.init(id: geminiProfileID, name: "Gemini", connectionID: geminiConnectionID, model: geminiModel, capabilities: .gemini)],
              defaultProfileID: geminiProfileID)
    }
    func profile(for feature: ModelFeature, override: UUID? = nil) throws -> ModelProfile {
        let id = override ?? assignments[feature.rawValue] ?? defaultProfileID
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw BrowserError("missing_model", "Choose a model for \(feature.title) in Settings.")
        }
        return profile
    }
    func connection(for profile: ModelProfile) throws -> ModelConnection {
        guard let connection = connections.first(where: { $0.id == profile.connectionID }) else {
            throw BrowserError("missing_connection", "Choose a connection for this model in Settings.")
        }
        return connection
    }
    // Only changes that affect the current chat destination/capabilities reset chat context.
    var chatSignature: String {
        guard let profile = try? profile(for: .chat), let connection = try? connection(for: profile) else { return "unconfigured" }
        return "\(profile.id)|\(profile.model)|\(profile.capabilities)|\(connection.id)|\(connection.provider)|\(connection.endpoint)"
    }
}

@MainActor
extension SettingsStore {
    func client(for feature: ModelFeature, profileID: UUID? = nil, http: CaptionHTTPClient? = nil, kind: CaptureItem.Kind? = nil) throws -> ModelClient {
        let profile = try modelConfiguration.profile(for: feature, override: profileID)
        let connection = try modelConfiguration.connection(for: profile)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, model.utf8.count <= 200 else { throw BrowserError("invalid_model", "Enter a model identifier in Settings.") }
        if feature == .chat, !profile.capabilities.tools { throw BrowserError("model_capability", "Chat uses browser and Calendar tools. Choose a model with tool calling enabled.") }
        if feature == .captions || feature == .inventory {
            let canUseNativeVideo = connection.provider == .gemini && profile.capabilities.nativeVideo && kind != .image
            guard profile.capabilities.images || canUseNativeVideo else { throw BrowserError("model_capability", "Choose a model that supports this media for \(feature.title).") }
        }
        if feature == .inventory, !profile.capabilities.structuredOutput { throw BrowserError("model_capability", "Inventory recognition requires structured output. Enable it for a compatible model in Settings.") }
        let identity = ModelIdentity(provider: connection.provider, model: model, profileID: profile.id)
        let key = try connectionKey(connection)
        switch connection.provider {
        case .gemini:
            guard let key, !key.isEmpty else { throw BrowserError("missing_api_key", "Add the Gemini connection’s API key in Settings.") }
            return GeminiModelClient(identity: identity, capabilities: profile.capabilities, key: key, http: http)
        case .openAICompatible:
            _ = try OpenAICompatibleClient.validateEndpoint(connection.endpoint)
            return OpenAICompatibleClient(identity: identity, capabilities: profile.capabilities, endpoint: connection.endpoint, key: key, http: http)
        }
    }
    func availableModels(connection: ModelConnection, http: CaptionHTTPClient? = nil) async throws -> [String] {
        let key = try connectionKey(connection)
        switch connection.provider {
        case .gemini:
            guard let key else { throw BrowserError("missing_api_key", "Save the Gemini API key first.") }
            return try await GeminiProvider.availableModels(key: key, http: http)
        case .openAICompatible:
            return try await OpenAICompatibleClient.availableModels(endpoint: connection.endpoint, key: key, http: http)
        }
    }
    func featureDescription(_ feature: ModelFeature) -> String {
        guard let profile = try? modelConfiguration.profile(for: feature),
              let connection = try? modelConfiguration.connection(for: profile) else { return "Choose a model in Settings" }
        return "\(connection.name) · \(profile.model)"
    }
    func mediaDisclosure(for feature: ModelFeature, kind: CaptureItem.Kind) -> String {
        guard let profile = try? modelConfiguration.profile(for: feature),
              let connection = try? modelConfiguration.connection(for: profile) else { return "Choose a model in Settings." }
        if kind == .video {
            if connection.provider == .gemini && profile.capabilities.nativeVideo {
                return "Video and audio are uploaded to Google. Up to 5 minutes and 100 MB. Agora requests deletion afterward."
            }
            return "Up to eight timestamped video frames go to this model. Audio is not sent or analyzed. Up to 3 minutes and 500 MB."
        }
        return "A resized copy of this photo goes to this model. Your original stays unchanged."
    }
    func isConfigured(for feature: ModelFeature, kind: CaptureItem.Kind? = nil) -> Bool { (try? client(for: feature, kind: kind)) != nil }
}
