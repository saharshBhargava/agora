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
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space3) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your models").font(.display(32)).tracking(-0.5).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                    Text("Pick the model each feature uses, add your own connections and check what they can do.")
                        .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk).fixedSize(horizontal: false, vertical: true)
                }
                if let issue = settings.modelConfigurationIssue {
                    Text(issue).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                        .background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                }
                defaultCard
                connectionsSection
                profilesSection
            }
            .padding(.horizontal, 20).padding(.top, Metrics.space1).padding(.bottom, Metrics.space4)
        }
        .scrollBounceBehavior(.basedOnSize)
        .dibsPage("Models")
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

    // MARK: default model

    private var defaultCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Default model").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader).padding(.bottom, 4)
            assignmentRow(title: "Default", symbol: "star",
                          value: configuration.profiles.first { $0.id == configuration.defaultProfileID }.map { $0.label(in: configuration) } ?? "None") {
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
            }
            ForEach(ModelFeature.allCases) { feature in
                Color.line.frame(height: 1)
                assignmentRow(title: feature.title, symbol: nil,
                              value: configuration.assignments[feature.rawValue].flatMap { id in configuration.profiles.first { $0.id == id } }.map { $0.label(in: configuration) } ?? "Use default") {
                    Picker(feature.title, selection: assignmentBinding(for: feature)) {
                        Text("Use default").tag(Optional<UUID>.none)
                        ForEach(configuration.profiles) { profile in
                            Text(profile.label(in: configuration)).tag(Optional(profile.id))
                        }
                    }
                }
            }
            Text("Each feature uses its assignment, or the default model when set to Use default.")
                .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }

    private func assignmentRow<P: View>(title: String, symbol: String?, value: String, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 15, weight: .bold)) }
                else { Text(String(title.prefix(1)).uppercased()).font(.display(16)) }
            }
            .foregroundStyle(Color.ink).frame(width: 36, height: 36)
            .background(tileColor(id: title), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            Spacer(minLength: 8)
            Menu {
                picker().pickerStyle(.inline).labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.muted)
                }
                .padding(.horizontal, 12).frame(minHeight: 36)
                .overlay(Capsule().strokeBorder(Color.lineStrong))
                .frame(maxWidth: 190, alignment: .trailing)
            }
            .accessibilityLabel(title).accessibilityValue(value)
        }
        .frame(minHeight: 56)
    }

    private func assignmentBinding(for feature: ModelFeature) -> Binding<UUID?> {
        Binding(get: { settings.modelConfiguration.assignments[feature.rawValue] }, set: { value in
            var config = settings.modelConfiguration
            if let value { config.assignments[feature.rawValue] = value }
            else { config.assignments.removeValue(forKey: feature.rawValue) }
            settings.modelConfiguration = config
        })
    }

    // MARK: connections

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text("Connections").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            ForEach(configuration.connections) { connection in connectionCard(connection) }
            addRow("Add connection") { addingConnection = true }
            Text("Gemini uses Google’s API. OpenAI-compatible connections use the endpoint you enter; HTTP is limited to local network addresses. Reassign the default and any listed features before deleting an assigned connection.")
                .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connectionCard(_ connection: ModelConnection) -> some View {
        let labels = connectionAssignmentLabels(connection)
        return HStack(spacing: 4) {
            Button { editingConnection = connection } label: { connectionRow(connection, labels: labels) }
                .buttonStyle(.plain)
            if labels.isEmpty {
                Menu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(connection) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.muted).frame(width: 40, height: 44) }
                    .accessibilityLabel("Options for \(connection.name)")
            }
        }
        .padding(.leading, 12).padding(.trailing, labels.isEmpty ? 4 : 12).padding(.vertical, 10)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line))
    }

    private func connectionRow(_ connection: ModelConnection, labels: [String]) -> some View {
        HStack(spacing: 12) {
            Image(systemName: connection.provider == .gemini ? "sparkles" : "server.rack")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.ink)
                .frame(width: 48, height: 48)
                .background(tileColor(id: connection.id.uuidString), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(connection.provider.title + (connection.endpoint.isEmpty ? "" : " · \(connection.endpoint)"))
                    .font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
                if !labels.isEmpty {
                    pill("In use: \(labels.joined(separator: ", ")) · Reassign before deleting")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lineStrong)
        }
        .contentShape(Rectangle())
    }

    // MARK: profiles

    private var profilesSection: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text("Model profiles").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            ForEach(configuration.profiles) { profile in profileCard(profile) }
            addRow("Add model profile") { addingProfile = true }
            Text("A profile combines a connection, model identifier, and declared capabilities. Reassign the default and any listed features before deleting an assigned profile. Capability probes send harmless requests; they do not guarantee behavior on every prompt.")
                .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func profileCard(_ profile: ModelProfile) -> some View {
        let deletable = assignmentLabels(for: profile).isEmpty && configuration.profiles.count > 1
        return HStack(spacing: 4) {
            Button { editingProfile = profile } label: { profileRow(profile) }
                .buttonStyle(.plain)
            if deletable {
                Menu {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(profile) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.muted).frame(width: 40, height: 44) }
                    .accessibilityLabel("Options for \(profile.name)")
            }
        }
        .padding(.leading, 12).padding(.trailing, deletable ? 4 : 12).padding(.vertical, 10)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line))
    }

    private func profileRow(_ profile: ModelProfile) -> some View {
        let labels = assignmentLabels(for: profile)
        let capabilities = profile.capabilities.summaryItems
        return HStack(alignment: .top, spacing: 12) {
            Text(String(profile.name.prefix(1)).uppercased()).font(.display(22)).foregroundStyle(Color.ink)
                .frame(width: 48, height: 48)
                .background(tileColor(id: profile.id.uuidString), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(profile.name).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                    if profile.id == configuration.defaultProfileID {
                        Text("DEFAULT").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.ink, in: Capsule())
                    }
                }
                Text(profile.label(in: configuration)).font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1)
                if capabilities.isEmpty {
                    Text("No capabilities declared").font(.system(size: 13)).foregroundStyle(Color.muted)
                } else {
                    ModelFlowLayout(spacing: 6) { ForEach(capabilities, id: \.self) { pill($0) } }
                }
                if !labels.isEmpty {
                    pill("In use: \(labels.joined(separator: ", ")) · Reassign before deleting")
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.lineStrong).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func addRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.muted)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .overlay(Capsule().strokeBorder(Color.line))
            .fixedSize(horizontal: false, vertical: true)
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

    private var nameEmpty: Bool { connection.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(existing == nil ? "Add connection" : "Edit connection").font(.display(30)).tracking(-0.5).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                        Text("Name it, choose the provider, then add a key if it needs one and test it.")
                            .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
                    }
                    connectionCard
                    if persisted {
                        keyCard
                        testCard
                    }
                }
                .padding(.horizontal, 20).padding(.top, Metrics.space1).padding(.bottom, Metrics.space3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button("Save connection") { save() }
                    .buttonStyle(.dibs)
                    .disabled(nameEmpty || busy)
                    .padding(.horizontal, 20).padding(.vertical, Metrics.space1).background(Color.paper)
            }
            .dibsScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .onAppear { refreshKeyStatus() }
            .onChange(of: connection.provider) { _, provider in
                if provider == .gemini { connection.endpoint = "" }
                if provider == .openAICompatible && connection.endpoint.isEmpty { connection.endpoint = "http://localhost:1234/v1" }
                key = ""; hasSavedKey = false; message = nil; availableModels = []
            }
        }
        .tint(Color.ink)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connection")
            TextField("Name", text: $connection.name).textInputAutocapitalization(.words)
                .font(.system(size: 16)).foregroundStyle(Color.ink).dibsInput()
            MenuFieldRow(title: "Provider", value: connection.provider.title) {
                Picker("Provider", selection: $connection.provider) {
                    ForEach(ModelProviderKind.allCases.filter { $0 != .builtin }) { provider in Text(provider.title).tag(provider) }
                }
            }
            .disabled(connection.id == ModelConfiguration.geminiConnectionID)
            if connection.provider == .openAICompatible {
                TextField("Base URL, for example http://localhost:1234/v1", text: $connection.endpoint)
                    .font(.system(size: 16)).foregroundStyle(Color.ink)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).dibsInput()
                note("Use HTTPS for hosted servers. Plain HTTP is accepted only for local network addresses.")
            } else {
                note("Gemini requests use Google’s Generative Language API.")
            }
            if let message, !persisted { status(message) }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(connection.provider == .gemini ? "Gemini API key" : "Optional server credential")
            SecureField(hasSavedKey ? "Replace saved key" : "API key (optional)", text: $key)
                .font(.system(size: 16)).foregroundStyle(Color.ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled().focused($keyFocused).dibsInput()
            HStack(spacing: Metrics.space1) {
                Button("Save key") { saveKey() }.buttonStyle(.dibs(.secondary, fontSize: 15))
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
                if hasSavedKey {
                    Button(role: .destructive) { removeKey() } label: { Text("Remove key").foregroundStyle(Color.danger) }
                        .buttonStyle(.dibs(.secondary, fontSize: 15))
                }
            }
            if let message, persisted { status(message) }
            if connection.provider == .gemini && connection.id == ModelConfiguration.geminiConnectionID {
                note("The built-in Gemini connection uses the same Keychain key as the Connected accounts screen.")
            } else if connection.provider == .gemini {
                note("This Gemini connection has its own Keychain key, separate from the built-in Gemini connection.")
            } else {
                note("Credentials are saved in Keychain for this exact provider and endpoint. Changing the endpoint requires saving the connection before entering a key.")
            }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var testCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connection test")
            Button(busy ? "Testing…" : "Test connection and load models") { loadModels() }
                .buttonStyle(.dibs(.secondary, fontSize: 15)).disabled(busy)
            if !availableModels.isEmpty {
                Text("Found \(availableModels.count) model identifiers.").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
            }
            if let message, persisted { status(message) }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
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
        Text(value).font(.system(size: 13, weight: .medium)).foregroundStyle(error ? Color.danger : Color.muted).fixedSize(horizontal: false, vertical: true)
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

    private var saveDisabled: Bool {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connection == nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(existing == nil ? "Add model profile" : "Edit model profile").font(.display(30)).tracking(-0.5).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
                        Text("A profile pairs a connection with a model and what it can do.")
                            .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
                    }
                    profileCard
                    capabilitiesCard
                    probesCard
                }
                .padding(.horizontal, 20).padding(.top, Metrics.space1).padding(.bottom, Metrics.space3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                Button("Save profile") { save() }
                    .buttonStyle(.dibs)
                    .disabled(saveDisabled)
                    .padding(.horizontal, 20).padding(.vertical, Metrics.space1).background(Color.paper)
            }
            .dibsScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
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
        .tint(Color.ink)
    }

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Profile")
            TextField("Profile name", text: $profile.name).font(.system(size: 16)).foregroundStyle(Color.ink).dibsInput()
            MenuFieldRow(title: "Connection", value: connection?.name ?? "None") {
                Picker("Connection", selection: $profile.connectionID) {
                    ForEach(settings.modelConfiguration.connections) { connection in Text(connection.name).tag(connection.id) }
                }
            }
            TextField("Model identifier", text: $profile.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                .font(.system(size: 16)).foregroundStyle(Color.ink).dibsInput()
            if let connection {
                Button(busy ? "Loading models…" : "Load available models") { loadModels(connection) }
                    .buttonStyle(.dibs(.secondary, fontSize: 15)).disabled(busy)
            }
            if !models.isEmpty {
                MenuFieldRow(title: "Available models", value: profile.model) {
                    Picker("Available models", selection: $profile.model) {
                        if !models.contains(profile.model) { Text(profile.model).tag(profile.model) }
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            note("Model listing checks endpoint access. It does not establish tool, image, structured output, or streaming support.")
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var capabilitiesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Declared capabilities").padding(.bottom, 4)
            capabilityToggle("Tool calling", isOn: $profile.capabilities.tools)
            Color.line.frame(height: 1)
            capabilityToggle("Images", isOn: $profile.capabilities.images)
            Color.line.frame(height: 1)
            capabilityToggle("Structured output", isOn: $profile.capabilities.structuredOutput)
            Color.line.frame(height: 1)
            capabilityToggle("Streaming", isOn: $profile.capabilities.streaming)
            if connection?.provider == .gemini {
                Color.line.frame(height: 1)
                capabilityToggle("Native video", isOn: $profile.capabilities.nativeVideo)
            } else {
                note("Videos are sent as sampled image frames. Audio is not analyzed by this connection.").padding(.top, 10)
            }
            note("These switches describe what the selected model is expected to support. Use the probes below to check actual requests; probe results do not change these declarations.").padding(.top, 10)
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private func capabilityToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).tint(Color.ink).frame(minHeight: 52)
    }

    private var probesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Capability probes")
            probeButton("Test tool calling", key: "tools", capability: profile.capabilities.tools) { client in try await Self.probeTools(client) }
            probeButton("Test image input", key: "images", capability: profile.capabilities.images) { client in try await Self.probeImages(client) }
            probeButton("Test structured output", key: "structured", capability: profile.capabilities.structuredOutput) { client in try await Self.probeStructuredOutput(client) }
            probeButton("Test streaming", key: "streaming", capability: profile.capabilities.streaming) { client in try await Self.probeStreaming(client) }
            if profile.capabilities.nativeVideo {
                Label("Native video is declared. A probe requires a real video clip and is not sent from this settings screen.", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !capabilityResults.isEmpty {
                ForEach(["tools", "images", "structured", "streaming"], id: \.self) { key in
                    if let result = capabilityResults[key] {
                        Text("\(key.capitalized): \(result)").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(result.hasPrefix("Failed") ? Color.danger : Color.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let message { Text(message).font(.system(size: 13)).foregroundStyle(error ? Color.danger : Color.muted).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
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
        .buttonStyle(.dibs(.secondary, fontSize: 15))
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

/// A menu picker in a Dibs input box: the title at the left, the current choice and chevrons at the right,
/// on one line (a plain menu `Picker` wraps long choices over several lines).
struct MenuFieldRow<Choices: View>: View {
    let title: String
    let value: String
    @ViewBuilder var choices: () -> Choices
    var body: some View {
        Menu {
            choices().pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 16)).foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                Text(value).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.muted)
            }
            .dibsInput()
        }
        .accessibilityLabel(title).accessibilityValue(value)
    }
}

private extension ModelCapabilities {
    var summaryItems: [String] {
        [(tools, "tools"), (images, "images"), (structuredOutput, "structured output"), (streaming, "streaming"), (nativeVideo, "native video")].compactMap { $0.0 ? $0.1 : nil }
    }
}

/// Wraps its children onto as many rows as the width needs (capability pills).
private struct ModelFlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}
