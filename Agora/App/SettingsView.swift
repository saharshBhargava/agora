import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace

    var body: some View {
        NavigationStack {
            List {
                NavigationLink {
                    PreferencesSettingsView(settings: settings, workspace: workspace)
                } label: {
                    settingsRow("Preferences", detail: "Model and browser preferences", symbol: "slider.horizontal.3")
                }
                NavigationLink {
                    ConnectedAccountsSettingsView(settings: settings, workspace: workspace)
                } label: {
                    settingsRow("Connected accounts", detail: "Google Calendar and Gemini", symbol: "person.crop.circle.badge.checkmark")
                }
                NavigationLink {
                    AutonomySettingsView()
                } label: {
                    settingsRow("Autonomy settings", detail: "How your assistant acts on your behalf", symbol: "hand.raised")
                }
                NavigationLink {
                    SpendingLimitsSettingsView()
                } label: {
                    settingsRow("Spending limits", detail: "Purchase limits and availability", symbol: "creditcard")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private func settingsRow(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.teal)
        }
    }
}

private struct PreferencesSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace
    @State private var message = ""
    @State private var clearing = false
    @State private var models: [String] = []
    @State private var loadingModels = false

    var body: some View {
        Form {
            Section("Assistant model") {
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
            }
            Section("Browser access") {
                Label("All website domains allowed", systemImage: "globe")
                Text("Browse HTTPS websites without adding domains. Redirects to other HTTPS sites are allowed. Local hostnames, IP addresses and URLs containing credentials remain unsupported.").font(.footnote).foregroundStyle(.secondary)
                Text("Use Private mode before entering sensitive information. Login and payment detection also blocks model observations. Website data persists between chats; chat text is kept only in memory.").font(.footnote).foregroundStyle(.secondary)
                Button("Clear cookies and website data", role: .destructive) { clearing = true }
            }
            if !message.isEmpty {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Preferences")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear all browser cookies and website data?", isPresented: $clearing, titleVisibility: .visible) {
            Button("Clear website data", role: .destructive) {
                workspace.agent.stop()
                Task {
                    await workspace.browser.clearWebsiteData()
                    message = "Website data cleared."
                }
            }
        }
    }
}

private struct ConnectedAccountsSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace
    @State private var key = ""
    @State private var keyMessage = ""
    @State private var keyError = false
    @FocusState private var editingKey: Bool

    var body: some View {
        Form {
            CalendarSettingsSection(calendar: workspace.calendar, stopAgent: { workspace.agent.stop() })
            Section("Google Gemini") {
                Label(settings.hasKey ? "API key saved on this device" : "No API key saved", systemImage: settings.hasKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(settings.hasKey ? Color.green : Color.secondary)
                    .accessibilityIdentifier("apiKeyStatus")
                SecureField(settings.hasKey ? "Replace API key" : "API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editingKey).accessibilityIdentifier("apiKeyInput")
                Button("Save API key") {
                    do {
                        try settings.saveKey(key)
                        workspace.agent.stop()
                        key = ""; editingKey = false; keyError = false
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
                            try settings.deleteKey(); key = ""; keyError = false; keyMessage = "API key removed."
                        } catch { keyError = true; keyMessage = error.localizedDescription }
                    }
                }
                Link("Get an API key in Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                Text("Your key stays in this device’s Keychain and is sent only to Google’s API. Chat and browser evidence are sent to Gemini while a task runs.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Connected accounts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutonomySettingsView: View {
    var body: some View {
        Form {
            Section("Current behavior") {
                Label("Ask before acting", systemImage: "hand.raised.fill")
                Text("Your assistant asks for approval before clicking, typing, submitting forms, or closing the browser. Each approval applies to one action.")
                    .foregroundStyle(.secondary)
                Text("Opening pages, reading pages, and scrolling can happen automatically during a task.")
                    .foregroundStyle(.secondary)
            }
            Section("Your control") {
                Text("Use Stop in Chat to end a task. Interacting with the browser pauses the assistant until you resume it.")
                Text("Additional autonomy modes are not available yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Autonomy settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpendingLimitsSettingsView: View {
    var body: some View {
        Form {
            Section("Purchase limits") {
                Label("Not available yet", systemImage: "creditcard")
                Text("Agora does not currently track spending or enforce purchase limits. Browser action approvals are still required, but they do not check purchase amounts.")
                    .foregroundStyle(.secondary)
            }
            Section("Model usage") {
                Text("Manage Gemini API usage through Google AI Studio. Purchase limits do not cover model usage.")
                    .foregroundStyle(.secondary)
                Link("Manage usage in Google AI Studio", destination: URL(string: "https://aistudio.google.com/")!)
            }
        }
        .navigationTitle("Spending limits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
