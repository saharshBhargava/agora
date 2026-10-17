import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace
    @State private var key = ""
    @State private var message = ""
    @State private var keyMessage = ""
    @State private var keyError = false
    @FocusState private var editingKey: Bool
    @State private var clearing = false
    @State private var models: [String] = []
    @State private var loadingModels = false
    var body: some View {
        NavigationStack {
            Form {
                Section("Google Gemini") {
                    Label(settings.hasKey ? "API key saved on this device" : "No API key saved", systemImage: settings.hasKey ? "checkmark.circle.fill" : "key")
                        .foregroundStyle(settings.hasKey ? Color.green : Color.secondary)
                        .accessibilityIdentifier("apiKeyStatus")
                    SecureField(settings.hasKey ? "Replace API key" : "API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editingKey).accessibilityIdentifier("apiKeyInput")
                    Button("Save API key") {
                        do {
                            try settings.saveKey(key)
                            workspace.agent.stop()
                            key = ""; editingKey = false; models = []; keyError = false
                            keyMessage = "Saved and read back successfully. The field is cleared to keep your key private. You can now return to Chat."
                        } catch { keyError = true; keyMessage = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("saveApiKey")
                    if !keyMessage.isEmpty {
                        Text(keyMessage).font(.footnote).foregroundStyle(keyError ? Color.red : Color.secondary)
                            .accessibilityIdentifier("apiKeySaveResult")
                    }
                    if settings.hasKey {
                        Button("Remove API key", role: .destructive) {
                            workspace.agent.stop()
                            do {
                                try settings.deleteKey(); key = ""; models = []; keyError = false; keyMessage = "API key removed."
                            } catch { keyError = true; keyMessage = error.localizedDescription }
                        }
                    }
                    TextField("Model", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(loadingModels ? "Loading models…" : "Load available models") {
                        loadingModels = true
                        Task { @MainActor in
                            defer { loadingModels = false }
                            do {
                                models = try await GeminiProvider.availableModels(key: settings.apiKey())
                                message = models.isEmpty ? "No chat models were returned for this key." : "Choose a model below. Listing a model does not guarantee quota or function-calling access."
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(!settings.hasKey || loadingModels)
                    if !models.isEmpty {
                        Picker("Available models", selection: $settings.model) {
                            if !models.contains(settings.model) { Text(settings.model).tag(settings.model) }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Link("Get an API key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                    Text("Your key stays in this device’s Keychain and is sent only to Google’s API. Chat and browser evidence are sent to Gemini while a task runs.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Browser access") {
                    Label("All website domains allowed", systemImage: "globe")
                    Text("Browse HTTPS websites without adding domains. Redirects to other HTTPS sites are allowed. Local hostnames, IP addresses and URLs containing credentials remain unsupported.").font(.footnote).foregroundStyle(.secondary)
                    Text("Use Private mode before entering sensitive information. Login and payment detection also blocks model observations. Website data persists between chats; chat text is kept only in memory.").font(.footnote).foregroundStyle(.secondary)
                    Button("Clear cookies and website data", role: .destructive) { clearing = true }
                }
                if !message.isEmpty { Section { Text(message).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Clear all browser cookies and website data?", isPresented: $clearing, titleVisibility: .visible) {
                Button("Clear website data", role: .destructive) { workspace.agent.stop(); Task { await workspace.browser.clearWebsiteData(); message = "Website data cleared." } }
            }
        }
    }
}
