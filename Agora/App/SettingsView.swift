import SwiftUI

/// The household's settings pages, as tile rows split by hairlines for the Settings sheet's "Household"
/// card (the sheet's `NavigationStack` pushes the pages).
struct HouseholdSettingsLinks: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink {
                if settings.usesBuiltInSamples {
                    ShelfPage {
                        ShelfHero(title: "Models", subtitle: "Which models answer chat, captions and recognition.")
                        SettingsCard(symbol: "cpu", tint: 0xE5DDF7, title: "Built-in integrations") {
                            Text("Chat, captions and recognition use sample responses. Calendar events stay inside the sample account. No external API keys are needed.")
                                .shelfBody()
                            Text("Save your Gemini API key under Connected accounts to use Gemini instead.")
                                .shelfNote()
                        }
                    }
                } else { ModelSettingsView(settings: settings) }
            } label: {
                DibsLinkRow(title: "Models", detail: "Connections and feature assignments", symbol: "cpu", tint: 0xE5DDF7)
            }
            Hairline()
            NavigationLink {
                PreferencesSettingsView(settings: settings, workspace: workspace)
            } label: {
                DibsLinkRow(title: "Preferences", detail: "Browser preferences", symbol: "slider.horizontal.3", tint: 0xECEAE6)
            }
            Hairline()
            NavigationLink {
                ConnectedAccountsSettingsView(settings: settings, workspace: workspace)
            } label: {
                DibsLinkRow(title: "Connected accounts", detail: settings.usesBuiltInSamples ? "Built-in integrations · add a Gemini key" : "Google Calendar and Gemini",
                            symbol: "person.crop.circle.badge.checkmark", tint: 0xD8E2FA)
            }
            Hairline()
            NavigationLink {
                AutonomySettingsView()
            } label: {
                DibsLinkRow(title: "Autonomy", detail: "How your assistant acts on your behalf", symbol: "hand.raised", tint: 0xF2E3B5)
            }
            Hairline()
            NavigationLink {
                SpendingView(store: workspace.commerce)
            } label: {
                DibsLinkRow(title: "Spending limits", detail: "Approvals, spending authority and budget", symbol: "creditcard", tint: 0xF6D9CC)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A settings card: a symbol tile and title, then the page's own content.
private struct SettingsCard<Content: View>: View {
    let symbol: String
    var tint: UInt32 = Palette.tileHex[2]
    let title: String
    var detail: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DibsSymbolTile(symbol: symbol, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                    if let detail { Text(detail).shelfNote() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }
}

/// A body line with a symbol tile, for a card that is only text.
private struct SettingsParagraphs: View {
    let paragraphs: [String]
    var muted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(paragraphs, id: \.self) { text in
                Text(text)
                    .font(.system(size: muted ? 13 : 15))
                    .foregroundStyle(muted ? Color.muted : Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A link out of the app, in ink with an arrow.
private struct SettingsLink: View {
    let title: String
    let url: URL
    var body: some View {
        Link(destination: url) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 15, weight: .semibold)).underline()
                Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold)).accessibilityHidden(true)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: Metrics.tap, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}

private struct PreferencesSettingsView: View {
    @ObservedObject var settings: SettingsStore
    let workspace: ChatWorkspace
    @State private var clearing = false
    @State private var message = ""

    var body: some View {
        ShelfPage {
            ShelfHero(title: "Preferences", subtitle: "How your assistant uses the browser on your behalf.")
            VStack(alignment: .leading, spacing: 10) {
                ShelfSectionTitle("Browser access")
                SettingsCard(symbol: "globe", tint: 0xECEAE6, title: "All website domains allowed") {
                    SettingsParagraphs(paragraphs: [
                        "Browse HTTPS websites without adding domains. Redirects to other HTTPS sites are allowed. Local hostnames, IP addresses and URLs containing credentials remain unsupported.",
                        "Use Private mode before entering sensitive information. Login and payment detection also blocks model observations. Website data persists between chats; chat text is kept only in memory.",
                    ])
                    Button(role: .destructive) { clearing = true } label: {
                        Text("Clear cookies and website data").foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.dibs(.secondary, fontSize: 16))
                    if !message.isEmpty { Text(message).shelfNote() }
                }
            }
        }
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

/// The Calendar account: what is connected and how to reconnect, sign out or disconnect.
private struct CalendarAccountCard: View {
    @ObservedObject var calendar: CalendarConnection
    let stopAgent: () -> Void
    @State private var confirmDisconnect = false

    var body: some View {
        Group {
            if calendar.isDemoAccount {
                SettingsCard(symbol: "calendar", tint: 0xD8E2FA, title: "Built-in calendar") {
                    ShelfPill(text: "Built-in integrations active", symbol: "checkmark.circle.fill", style: .ink)
                    SettingsParagraphs(paragraphs: ["No Google or model credentials are needed. Events stay in this account; no invitations or real purchases are sent."], muted: true)
                    Button("Use Google account instead") { stopAgent(); Task { await calendar.connect() } }
                        .buttonStyle(.dibs(.secondary, fontSize: 16)).disabled(calendar.connecting)
                    Button("Sign out") { stopAgent(); Task { await calendar.signOut() } }
                        .buttonStyle(.dibs(.secondary, fontSize: 16)).disabled(calendar.connecting)
                }
            } else {
                SettingsCard(symbol: "calendar", tint: 0xD8E2FA, title: "Google Calendar", detail: calendar.email) {
                    ShelfPill(text: calendar.connected ? "Connected" : "Connection required",
                              symbol: calendar.connected ? "checkmark.circle.fill" : "calendar.badge.exclamationmark",
                              style: calendar.connected ? .ink : .danger)
                    SettingsParagraphs(paragraphs: ["Dibs checks availability and adds approved events to your primary calendar."], muted: true)
                    if let message = calendar.message { Text(message).shelfNote() }
                    Button("Reconnect Google Calendar") { stopAgent(); Task { await calendar.connect() } }
                        .buttonStyle(.dibs(calendar.connected ? .secondary : .ink, fontSize: 16)).disabled(calendar.connecting)
                    Button("Sign out") { stopAgent(); Task { await calendar.signOut() } }
                        .buttonStyle(.dibs(.secondary, fontSize: 16)).disabled(calendar.connecting)
                    Button(role: .destructive) { confirmDisconnect = true } label: {
                        Text("Disconnect Google Calendar").foregroundStyle(Color.danger)
                    }
                    .buttonStyle(.dibs(.secondary, fontSize: 16)).disabled(calendar.connecting)
                }
            }
        }
        .confirmationDialog("Disconnect Google Calendar?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect and sign out", role: .destructive) { stopAgent(); Task { await calendar.disconnect() } }
        } message: { Text("Dibs will lose Calendar access. Your existing Google Calendar events will remain.") }
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
        ShelfPage {
            ShelfHero(title: "Connected accounts",
                      subtitle: settings.usesBuiltInSamples ? "Built-in integrations are active. Save a Gemini key to use Gemini." : "Google Calendar and Gemini.")
            CalendarAccountCard(calendar: workspace.calendar, stopAgent: { workspace.agent.stop() })
            gemini
        }
    }

    private var gemini: some View {
        SettingsCard(symbol: "key", tint: 0xE5DDF7, title: "Google Gemini") {
            ShelfPill(text: settings.hasKey ? "API key saved on this device" : "No API key saved",
                      symbol: settings.hasKey ? "checkmark.circle.fill" : "key",
                      style: settings.hasKey ? .ink : .muted)
                .accessibilityIdentifier("apiKeyStatus")
            SecureField(settings.hasKey ? "Replace API key" : "API key", text: $key)
                .font(.system(size: 16))
                .foregroundStyle(Color.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($editingKey)
                .dibsInput()
                .accessibilityIdentifier("apiKeyInput")
            Button("Save API key") {
                do {
                    try settings.saveKey(key)
                    workspace.agent.stop()
                    key = ""; editingKey = false; keyError = false
                    keyMessage = "Saved and read back successfully. The field is cleared to keep your key private. You can now return to Chat."
                } catch { keyError = true; keyMessage = error.localizedDescription }
            }
            .buttonStyle(.dibs(.ink, fontSize: 16))
            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("saveApiKey")
            if !keyMessage.isEmpty {
                Text(keyMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(keyError ? Color.danger : Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("apiKeySaveResult")
            }
            if settings.hasKey {
                Button(role: .destructive) {
                    workspace.agent.stop()
                    do {
                        try settings.deleteKey(); key = ""; keyError = false; keyMessage = "API key removed."
                    } catch { keyError = true; keyMessage = error.localizedDescription }
                } label: { Text("Remove API key").foregroundStyle(Color.danger) }
                .buttonStyle(.dibs(.secondary, fontSize: 16))
            }
            SettingsLink(title: "Get an API key in Google AI Studio", url: URL(string: "https://aistudio.google.com/apikey")!)
            SettingsParagraphs(paragraphs: ["Your Gemini key stays in this device’s Keychain and is sent only to Google’s API. Chat, captions, and inventory recognition use the model profiles assigned under Models."], muted: true)
        }
    }
}

private struct AutonomySettingsView: View {
    var body: some View {
        ShelfPage {
            ShelfHero(title: "Autonomy", subtitle: "How your assistant acts on your behalf.")
            VStack(alignment: .leading, spacing: 10) {
                ShelfSectionTitle("Current behavior")
                SettingsCard(symbol: "hand.raised.fill", tint: 0xF2E3B5, title: "Ask before acting") {
                    SettingsParagraphs(paragraphs: [
                        "Your assistant asks for approval before clicking, typing, submitting forms, or closing the browser. Each approval applies to one action.",
                    ])
                    SettingsParagraphs(paragraphs: ["Opening pages, reading pages, and scrolling can happen automatically during a task."], muted: true)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                ShelfSectionTitle("Your control")
                VStack(alignment: .leading, spacing: 8) {
                    SettingsParagraphs(paragraphs: ["Use Stop in Chat to end a task. Interacting with the browser pauses the assistant until you resume it."])
                    SettingsParagraphs(paragraphs: ["Additional autonomy modes are not available yet."], muted: true)
                }
                .dibsCard()
            }
        }
    }
}

