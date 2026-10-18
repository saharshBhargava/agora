import SwiftUI
import UIKit

struct ModelSettingsView: View {
    @ObservedObject var settings: SettingsStore
    @State private var editingConnection: ModelConnection?
    @State private var editingProfile: ModelProfile?
    @State private var addingConnection = false
    @State private var addingProfile = false

    private var configuration: ModelConfiguration { settings.modelConfiguration }

    var body: some View {
        Form {
            if let issue = settings.modelConfigurationIssue { Section { Text(issue).foregroundStyle(.secondary) } }
            Section("Default model") {
                Picker("Default", selection: Binding(
                    get: { settings.modelConfiguration.defaultProfileID },
                    set: { value in
                        var config = settings.modelConfiguration
                        config.defaultProfileID = value
                        settings.modelConfiguration = config
                    })) {
                    ForEach(configuration.profiles) { profile in
                        Text(profile.label(in: configuration)).tag(profile.id)
                    }
                }
                ForEach(ModelFeature.allCases) { feature in
                    Picker(feature.title, selection: assignmentBinding(for: feature)) {
                        Text("Use default").tag(Optional<UUID>.none)
                        ForEach(configuration.profiles) { profile in
                            Text(profile.label(in: configuration)).tag(Optional(profile.id))
                        }
                    }
                }
                Text("Each feature uses its assignment, or the default model when set to Use default.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ForEach(configuration.connections) { connection in
                    Button {
                        editingConnection = connection
                    } label: {
                        connectionRow(connection)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if connectionAssignmentLabels(connection).isEmpty {
                            Button("Delete", role: .destructive) { delete(connection) }
                        }
                    }
                }
                Button { addingConnection = true } label: {
                    Label("Add connection", systemImage: "plus")
                }
            } header: {
                Text("Connections")
            } footer: {
                Text("Gemini uses Google’s API. OpenAI-compatible connections use the endpoint you enter; HTTP is limited to local network addresses. Reassign the default and any listed features before deleting an assigned connection.")
            }

            Section {
                ForEach(configuration.profiles) { profile in
                    Button { editingProfile = profile } label: {
                        profileRow(profile)
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        if assignmentLabels(for: profile).isEmpty && configuration.profiles.count > 1 {
                            Button("Delete", role: .destructive) { delete(profile) }
                        }
                    }
                }
                Button { addingProfile = true } label: {
                    Label("Add model profile", systemImage: "plus")
                }
            } header: {
                Text("Model profiles")
            } footer: {
                Text("A profile combines a connection, model identifier, and declared capabilities. Reassign the default and any listed features before deleting an assigned profile. Capability probes send harmless requests; they do not guarantee behavior on every prompt.")
            }
        }
        .navigationTitle("Models")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $addingConnection) {
            ModelConnectionEditor(settings: settings, existing: nil, onSave: upsert)
        }
        .sheet(item: $editingConnection) { connection in
            ModelConnectionEditor(settings: settings, existing: connection, onSave: upsert)
        }
        .sheet(isPresented: $addingProfile) {
            ModelProfileEditor(settings: settings, existing: nil, onSave: upsert)
        }
        .sheet(item: $editingProfile) { profile in
            ModelProfileEditor(settings: settings, existing: profile, onSave: upsert)
        }
    }

    private func assignmentBinding(for feature: ModelFeature) -> Binding<UUID?> {
        Binding(get: { settings.modelConfiguration.assignments[feature.rawValue] }, set: { value in
            var config = settings.modelConfiguration
            if let value { config.assignments[feature.rawValue] = value }
            else { config.assignments.removeValue(forKey: feature.rawValue) }
            settings.modelConfiguration = config
        })
    }

    private func connectionRow(_ connection: ModelConnection) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.provider == .gemini ? "sparkles" : "server.rack")
                .foregroundStyle(.teal).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).foregroundStyle(.primary)
                Text(connection.provider.title + (connection.endpoint.isEmpty ? "" : " · \(connection.endpoint)"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let labels = connectionAssignmentLabels(connection)
                if !labels.isEmpty {
                    Text("In use: \(labels.joined(separator: ", ")) · Reassign before deleting")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func profileRow(_ profile: ModelProfile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(profile.name).foregroundStyle(.primary)
                if profile.id == configuration.defaultProfileID {
                    Text("DEFAULT").font(.caption2.bold()).foregroundStyle(.teal)
                }
            }
            Text(profile.label(in: configuration)).font(.caption).foregroundStyle(.secondary)
            Text(profile.capabilities.summary).font(.caption2).foregroundStyle(.tertiary)
            let labels = assignmentLabels(for: profile)
            if !labels.isEmpty {
                Text("In use: \(labels.joined(separator: ", ")) · Reassign before deleting")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func upsert(_ connection: ModelConnection) {
        var config = settings.modelConfiguration
        if let index = config.connections.firstIndex(where: { $0.id == connection.id }) { config.connections[index] = connection }
        else { config.connections.append(connection) }
        settings.modelConfiguration = config
        addingConnection = false; editingConnection = nil
    }

    private func upsert(_ profile: ModelProfile) {
        var config = settings.modelConfiguration
        if let index = config.profiles.firstIndex(where: { $0.id == profile.id }) { config.profiles[index] = profile }
        else { config.profiles.append(profile) }
        settings.modelConfiguration = config
        addingProfile = false; editingProfile = nil
    }

    private func delete(_ connection: ModelConnection) {
        var config = settings.modelConfiguration
        let removedIDs = Set(config.profiles.filter { $0.connectionID == connection.id }.map(\.id))
        guard connectionAssignmentLabels(connection).isEmpty, config.profiles.count > removedIDs.count else { return }
        config.connections.removeAll { $0.id == connection.id }
        config.profiles.removeAll { removedIDs.contains($0.id) }
        settings.modelConfiguration = config
    }

    private func delete(_ profile: ModelProfile) {
        var config = settings.modelConfiguration
        guard config.profiles.count > 1, assignmentLabels(for: profile, configuration: config).isEmpty else { return }
        config.profiles.removeAll { $0.id == profile.id }
        settings.modelConfiguration = config
    }

    private func assignmentLabels(for profile: ModelProfile, configuration: ModelConfiguration? = nil) -> [String] {
        let configuration = configuration ?? settings.modelConfiguration
        var labels: [String] = []
        if configuration.defaultProfileID == profile.id { labels.append("Default") }
        for feature in ModelFeature.allCases where configuration.assignments[feature.rawValue] == profile.id {
            labels.append(feature.title)
        }
        return labels
    }

    private func connectionAssignmentLabels(_ connection: ModelConnection) -> [String] {
        var labels: [String] = []
        for profile in settings.modelConfiguration.profiles where profile.connectionID == connection.id {
            for label in assignmentLabels(for: profile) where !labels.contains(label) { labels.append(label) }
        }
        return labels
    }
}

private struct ModelConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore
    let existing: ModelConnection?
    let onSave: (ModelConnection) -> Void
    @State private var connection: ModelConnection
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var message: String?
    @State private var error = false
    @State private var busy = false
    @State private var availableModels: [String] = []
    @State private var probeID = UUID()
    @FocusState private var keyFocused: Bool

    init(settings: SettingsStore, existing: ModelConnection?, onSave: @escaping (ModelConnection) -> Void) {
        self.settings = settings; self.existing = existing; self.onSave = onSave
        _connection = State(initialValue: existing ?? ModelConnection(id: UUID(), name: "", provider: .openAICompatible, endpoint: ""))
    }

    private var persisted: Bool { settings.modelConfiguration.connections.contains(where: { $0 == connection }) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $connection.name).textInputAutocapitalization(.words)
                    Picker("Provider", selection: $connection.provider) {
                        ForEach(ModelProviderKind.allCases.filter { $0 != .builtin }) { provider in Text(provider.title).tag(provider) }
                    }
                    .disabled(connection.id == ModelConfiguration.geminiConnectionID)
                    if connection.provider == .openAICompatible {
                        TextField("Base URL, for example http://localhost:1234/v1", text: $connection.endpoint)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        Text("Use HTTPS for hosted servers. Plain HTTP is accepted only for local network addresses.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Gemini requests use Google’s Generative Language API.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let message, !persisted { status(message) }
                    Button("Save connection") { save() }
                        .disabled(connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                }

                if persisted {
                    Section(connection.provider == .gemini ? "Gemini API key" : "Optional server credential") {
                        SecureField(hasSavedKey ? "Replace saved key" : "API key (optional)", text: $key)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().focused($keyFocused)
                        HStack {
                            Button("Save key") { saveKey() }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                            if hasSavedKey {
                                Button("Remove key", role: .destructive) { removeKey() }
                            }
                        }
                        if let message, persisted { status(message) }
                        if connection.provider == .gemini && connection.id == ModelConfiguration.geminiConnectionID {
                            Text("The built-in Gemini connection uses the same Keychain key as the Connected accounts screen.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if connection.provider == .gemini {
                            Text("This Gemini connection has its own Keychain key, separate from the built-in Gemini connection.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else {
                            Text("Credentials are saved in Keychain for this exact provider and endpoint. Changing the endpoint requires saving the connection before entering a key.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    Section("Connection test") {
                        Button(busy ? "Testing…" : "Test connection and load models") { loadModels() }.disabled(busy)
                        if !availableModels.isEmpty {
                            Text("Found \(availableModels.count) model identifiers.").font(.footnote).foregroundStyle(.secondary)
                        }
                        if let message, persisted { status(message) }
                    }
                }
            }
            .navigationTitle(existing == nil ? "Add connection" : "Edit connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!persisted && connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { refreshKeyStatus() }
            .onChange(of: connection.provider) { _, provider in
                if provider == .gemini { connection.endpoint = "" }
                if provider == .openAICompatible && connection.endpoint.isEmpty { connection.endpoint = "http://localhost:1234/v1" }
                key = ""; hasSavedKey = false; message = nil; availableModels = []
            }
        }
    }

    private func save() {
        do {
            connection.name = connection.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if connection.provider == .gemini { connection.endpoint = "" }
            else { _ = try OpenAICompatibleClient.validateEndpoint(connection.endpoint) }
            onSave(connection)
            message = "Connection saved. Add its key, if required, then test it."
            error = false
            if existing == nil { dismiss() }
            refreshKeyStatus()
        } catch { show(error) }
    }

    private func refreshKeyStatus() {
        do { hasSavedKey = try settings.connectionKey(connection) != nil }
        catch { hasSavedKey = false; show(error) }
    }

    private func saveKey() {
        do {
            try settings.saveConnectionKey(key, connection: connection)
            key = ""; keyFocused = false; hasSavedKey = true; message = "Key saved and verified in Keychain."; error = false
        } catch { show(error) }
    }

    private func removeKey() {
        do {
            try settings.deleteConnectionKey(connection); key = ""; hasSavedKey = false; message = "Saved key removed."; error = false
        } catch { show(error) }
    }

    private func loadModels() {
        let requestID = UUID(); probeID = requestID
        let snapshot = connection
        busy = true; message = nil; availableModels = []
        Task { @MainActor in
            defer { if probeID == requestID { busy = false } }
            do {
                let result = try await settings.availableModels(connection: snapshot)
                guard probeID == requestID, connection == snapshot else { return }
                availableModels = result
                message = result.isEmpty ? "Connection responded, but returned no model identifiers." : "Connection succeeded. A listed model is reachable; this does not verify every capability."
                error = false
            } catch {
                guard probeID == requestID, connection == snapshot else { return }
                show(error)
            }
        }
    }

    private func show(_ value: Error) { message = value.localizedDescription; error = true }
    @ViewBuilder private func status(_ value: String) -> some View {
        Text(value).font(.footnote).foregroundStyle(error ? Color.red : Color.secondary)
    }
}

private struct ModelProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SettingsStore
    let existing: ModelProfile?
    let onSave: (ModelProfile) -> Void
    @State private var profile: ModelProfile
    @State private var models: [String] = []
    @State private var busy = false
    @State private var message: String?
    @State private var error = false
    @State private var loadID = UUID()
    @State private var capabilityResults: [String: String] = [:]
    @State private var capabilityID = UUID()

    init(settings: SettingsStore, existing: ModelProfile?, onSave: @escaping (ModelProfile) -> Void) {
        self.settings = settings; self.existing = existing; self.onSave = onSave
        let config = settings.modelConfiguration
        let connectionID = existing?.connectionID ?? config.connections.first?.id ?? ModelConfiguration.geminiConnectionID
        let provider = config.connections.first(where: { $0.id == connectionID })?.provider
        let capabilities = provider == .gemini ? ModelCapabilities.gemini : ModelCapabilities()
        _profile = State(initialValue: existing ?? ModelProfile(id: UUID(), name: "", connectionID: connectionID, model: "", capabilities: capabilities))
    }

    private var connection: ModelConnection? { settings.modelConfiguration.connections.first { $0.id == profile.connectionID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Profile name", text: $profile.name)
                    Picker("Connection", selection: $profile.connectionID) {
                        ForEach(settings.modelConfiguration.connections) { connection in Text(connection.name).tag(connection.id) }
                    }
                    TextField("Model identifier", text: $profile.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let connection {
                        Button(busy ? "Loading models…" : "Load available models") { loadModels(connection) }.disabled(busy)
                    }
                    if !models.isEmpty {
                        Picker("Available models", selection: $profile.model) {
                            if !models.contains(profile.model) { Text(profile.model).tag(profile.model) }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Text("Model listing checks endpoint access. It does not establish tool, image, structured output, or streaming support.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Declared capabilities") {
                    Toggle("Tool calling", isOn: $profile.capabilities.tools)
                    Toggle("Images", isOn: $profile.capabilities.images)
                    Toggle("Structured output", isOn: $profile.capabilities.structuredOutput)
                    Toggle("Streaming", isOn: $profile.capabilities.streaming)
                    if connection?.provider == .gemini {
                        Toggle("Native video", isOn: $profile.capabilities.nativeVideo)
                    } else {
                        Text("Videos are sent as sampled image frames. Audio is not analyzed by this connection.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("These switches describe what the selected model is expected to support. Use the probes below to check actual requests; probe results do not change these declarations.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Capability probes") {
                    probeButton("Test tool calling", key: "tools", capability: profile.capabilities.tools) { client in try await Self.probeTools(client) }
                    probeButton("Test image input", key: "images", capability: profile.capabilities.images) { client in try await Self.probeImages(client) }
                    probeButton("Test structured output", key: "structured", capability: profile.capabilities.structuredOutput) { client in try await Self.probeStructuredOutput(client) }
                    probeButton("Test streaming", key: "streaming", capability: profile.capabilities.streaming) { client in try await Self.probeStreaming(client) }
                    if profile.capabilities.nativeVideo {
                        Label("Native video is declared. A probe requires a real video clip and is not sent from this settings screen.", systemImage: "info.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !capabilityResults.isEmpty {
                        ForEach(["tools", "images", "structured", "streaming"], id: \.self) { key in
                            if let result = capabilityResults[key] { Text("\(key.capitalized): \(result)").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    if let message { Text(message).font(.footnote).foregroundStyle(error ? Color.red : Color.secondary) }
                }
            }
            .navigationTitle(existing == nil ? "Add model profile" : "Edit model profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection == nil)
                }
            }
            .onChange(of: profile.connectionID) { _, _ in loadID = UUID(); models = []; resetCapabilityProbes() }
            .onChange(of: profile.model) { _, _ in resetCapabilityProbes() }
            .onChange(of: profile.capabilities) { _, _ in resetCapabilityProbes() }
            .onChange(of: connection) { _, value in
                if existing == nil && profile.model.isEmpty {
                    profile.capabilities = value?.provider == .gemini ? .gemini : .init()
                } else if value?.provider == .openAICompatible {
                    profile.capabilities.nativeVideo = false
                }
                resetCapabilityProbes()
            }
        }
    }

    @ViewBuilder private func probeButton(_ title: String, key: String, capability: Bool,
                                          operation: @escaping @MainActor (ModelClient) async throws -> String) -> some View {
        Button(busy ? "Testing…" : title) {
            let requestID = UUID(); capabilityID = requestID; busy = true; message = nil
            Task { @MainActor in
                defer { if capabilityID == requestID { busy = false } }
                do {
                    let client = try makeClient()
                    let result = try await operation(client)
                    guard capabilityID == requestID else { return }
                    capabilityResults[key] = "Passed · \(result)"; message = "Probe passed. The capability remains a declaration for future requests."; error = false
                } catch {
                    guard capabilityID == requestID else { return }
                    capabilityResults[key] = "Failed · \(error.localizedDescription)"; message = error.localizedDescription; self.error = true
                }
            }
        }
        .disabled(busy || !capability || connection == nil || profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func loadModels(_ connection: ModelConnection) {
        let requestID = UUID(); loadID = requestID; let snapshot = connection
        busy = true; message = nil; models = []
        Task { @MainActor in
            defer { if loadID == requestID { busy = false } }
            do {
                let result = try await settings.availableModels(connection: snapshot)
                guard loadID == requestID, self.connection == snapshot else { return }
                models = result; message = result.isEmpty ? "Connection responded, but returned no model identifiers." : "Models loaded. Check each capability with its probe."; error = false
            } catch {
                guard loadID == requestID, self.connection == snapshot else { return }
                message = error.localizedDescription; self.error = true
            }
        }
    }

    private func resetCapabilityProbes() {
        capabilityID = UUID(); busy = false; capabilityResults = [:]; message = nil
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if connection?.provider == .openAICompatible { profile.capabilities.nativeVideo = false }
        onSave(profile); dismiss()
    }

    private func makeClient() throws -> ModelClient {
        guard let connection else { throw BrowserError("missing_connection") }
        let identity = ModelIdentity(provider: connection.provider, model: profile.model, profileID: profile.id)
        let key = try settings.connectionKey(connection)
        switch connection.provider {
        case .builtin: throw BrowserError("integration_unavailable")
        case .gemini:
            guard let key else { throw BrowserError("missing_api_key", "Add the Gemini connection’s API key before testing capabilities.") }
            return GeminiModelClient(identity: identity, capabilities: profile.capabilities, key: key)
        case .openAICompatible:
            _ = try OpenAICompatibleClient.validateEndpoint(connection.endpoint)
            return OpenAICompatibleClient(identity: identity, capabilities: profile.capabilities, endpoint: connection.endpoint, key: key)
        }
    }

    private static func probeTools(_ client: ModelClient) async throws -> String {
        let schema = try ModelJSON.from(["type": "object", "properties": ["ready": ["type": "boolean"]], "required": ["ready"], "additionalProperties": false] as [String: Any])
        let tool = ModelToolDefinition(name: "connection_check", description: "Report that the harmless settings capability check ran.", parameters: schema)
        var request = ModelRequest(instructions: "For this connection check, call connection_check with ready set to true. Do not describe or perform any outside action.", messages: [.init(role: .user, content: [.text("Run the connection check.")])], tools: [tool])
        request.maxOutputTokens = 128
        let response = try await client.generate(request) { _ in }
        guard response.message.toolCalls.contains(where: { $0.name == "connection_check" }) else { throw BrowserError("probe_failed", "The model replied without calling the harmless test function.") }
        return "the model returned the test function call; it was not executed"
    }

    private static func probeImages(_ client: ModelClient) async throws -> String {
        let pixel = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }.pngData()!
        let request = ModelRequest(instructions: "Describe the supplied one-pixel test image in a few words.", messages: [.init(role: .user, content: [.image(pixel, mimeType: "image/png"), .text("What is in this test image?")])], maxOutputTokens: 128)
        let response = try await client.generate(request) { _ in }
        guard !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserError("probe_failed", "The model returned no text for the image probe.") }
        return "the image request returned text"
    }

    private static func probeStructuredOutput(_ client: ModelClient) async throws -> String {
        let schema = try ModelJSON.from(["type": "object", "properties": ["ok": ["type": "boolean"]], "required": ["ok"], "additionalProperties": false] as [String: Any])
        var request = ModelRequest(instructions: "Return the requested JSON object with ok set to true.", messages: [.init(role: .user, content: [.text("Return {\"ok\":true}.")])], outputSchema: schema, maxOutputTokens: 128)
        request.maxOutputTokens = 128
        let response = try await client.generate(request) { _ in }
        guard let data = response.text.data(using: .utf8),
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], value["ok"] as? Bool == true else {
            throw BrowserError("probe_failed", "The model did not return the requested JSON object.")
        }
        return "the model returned valid JSON matching the probe shape"
    }

    private static func probeStreaming(_ client: ModelClient) async throws -> String {
        let request = ModelRequest(instructions: "Reply with the exact word READY.", messages: [.init(role: .user, content: [.text("Reply READY.")])], maxOutputTokens: 64)
        var streamed = ""
        let response = try await client.stream(request) { event in if case .text(let value) = event { streamed = value } }
        let value = streamed.isEmpty ? response.text : streamed
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserError("probe_failed", "The streaming request returned no text.") }
        return "the streaming request returned text"
    }
}

private extension ModelProfile {
    func label(in configuration: ModelConfiguration) -> String {
        let connection = configuration.connections.first { $0.id == connectionID }
        return "\(connection?.name ?? "Missing connection") · \(model)"
    }
}

private extension ModelCapabilities {
    var summary: String {
        let enabled = [(tools, "tools"), (images, "images"), (structuredOutput, "structured output"), (streaming, "streaming"), (nativeVideo, "native video")].compactMap { $0.0 ? $0.1 : nil }
        return enabled.isEmpty ? "No capabilities declared" : enabled.joined(separator: " · ")
    }
}
