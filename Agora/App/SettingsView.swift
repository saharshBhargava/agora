import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace

    var body: some View {
        NavigationStack {
            AgoraList {
                NavigationLink {
                    if workspace.calendar.isDemoAccount {
                        Form { Section("Built-in integrations") {
                            Text("Chat, captions and recognition use sample responses. Calendar events stay inside the sample account. No external API keys are needed.")
                            Text("Sign out and connect your own Google account to configure real providers.").foregroundStyle(.secondary)
                        } }.agoraSurface()
                        .navigationTitle("Models")
                    } else { ModelSettingsView(settings: settings) }
                } label: {
                    settingsRow("Models")
                }
                NavigationLink {
                    PreferencesSettingsView(settings: settings, workspace: workspace)
                } label: {
                    settingsRow("Preferences")
                }
                NavigationLink {
                    ConnectedAccountsSettingsView(settings: settings, workspace: workspace)
                } label: {
                    settingsRow("Connected accounts")
                }
                NavigationLink {
                    AutonomySettingsView()
                } label: {
                    settingsRow("Autonomy settings")
                }
                NavigationLink {
                    SpendingLimitsSettingsView()
                } label: {
                    settingsRow("Spending limits")
                }
            }
            .agoraSurface()
            .navigationTitle("Settings")
        }
    }

    private func settingsRow(_ title: String) -> some View {
        Text(title).padding(.vertical, 12)
    }
}

private struct PreferencesSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace
    @State private var clearing = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("Browser access") {
                Label("All website domains allowed", systemImage: "globe")
                Text("HTTPS websites are supported. Local addresses and URLs containing credentials are blocked.").font(.footnote).foregroundStyle(.secondary)
                Text("Private mode hides pages from the model. Website data stays between chats; signing out clears chat history.").font(.footnote).foregroundStyle(.secondary)
                Button("Clear cookies and website data", role: .destructive) { clearing = true }
                if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .agoraSurface()
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
            if !workspace.calendar.isDemoAccount { Section("Google Gemini") {
                Label(settings.hasKey ? "API key saved on this device" : "No API key saved", systemImage: settings.hasKey ? "checkmark.circle.fill" : "key")
                    .foregroundStyle(settings.hasKey ? Color.green : Color.secondary)
                    .accessibilityIdentifier("apiKeyStatus")
                SecureField(settings.hasKey ? "Replace API key" : "API key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled().focused($editingKey).accessibilityIdentifier("apiKeyInput")
                Button("Save API key") {
                    do {
                        try settings.saveKey(key)
                        workspace.agent.stop()
                        key = ""; editingKey = false; keyError = false
                        keyMessage = "API key saved."
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
                Text("Your Gemini key stays in this device’s Keychain and is sent only to Google’s API. Chat, captions, and inventory recognition use the model profiles assigned under Models.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        }
        .agoraSurface()
        .navigationTitle("Connected accounts")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AutonomySettingsView: View {
    var body: some View {
        Form {
            Section("Current behavior") {
                Label("Ask before acting", systemImage: "hand.raised.fill")
                Text("Clicks, typing, submissions and closing the browser require approval for each action.")
                    .foregroundStyle(.secondary)
                Text("Opening, reading and scrolling pages can happen automatically.")
                    .foregroundStyle(.secondary)
            }
            Section("Your control") {
                Text("Stop ends a task. Using the browser pauses the assistant.")
            }
        }
        .agoraSurface()
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
        .agoraSurface()
        .navigationTitle("Spending limits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
