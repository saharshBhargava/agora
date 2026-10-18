import SwiftUI
import GoogleSignInSwift

struct CalendarOnboardingView: View {
    @ObservedObject var calendar: CalendarConnection
    @State private var handle = "demo"
    @State private var password = ""
    var body: some View {
        NavigationStack {
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Spacer()
                Image(systemName: "calendar.badge.plus").font(.system(size: 54)).foregroundStyle(.teal)
                Text("Make time for\nwhat you need.").font(.largeTitle.bold())
                Text("Use the sample account to explore Agora, or connect your Google account.")
                    .font(.title3).foregroundStyle(.secondary)
                Text("Demo sign-in uses built-in Calendar, chat and recognition responses. No Google account or provider API keys are required.")
                    .font(.footnote).foregroundStyle(.secondary)
                if let message = calendar.message { Text(message).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("calendarConnectionMessage") }
                if let email = calendar.email { Text(email).font(.callout) }
                if calendar.connecting {
                    ProgressView("Signing in…")
                }
                TextField("Username", text: $handle)
                    .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("demoUsername")
                SecureField("Password", text: $password).textContentType(.password)
                    .accessibilityIdentifier("demoPassword")
                Button("Sign in to demo") {
                    let submittedPassword = password
                    password = ""
                    Task { await calendar.connectDemo(handle: handle.trimmingCharacters(in: .whitespacesAndNewlines), password: submittedPassword) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(calendar.connecting || password.isEmpty || handle.isEmpty)
                .accessibilityIdentifier("signInDemo")
                Divider()
                Text("Or use Google (optional)").font(.headline)
                Text("Your own account uses your real Calendar and configured model providers.")
                    .font(.footnote).foregroundStyle(.secondary)
                GoogleSignInButton {
                    Task { await calendar.connect() }
                }
                .disabled(calendar.connecting || calendar.configurationIssue != nil)
                .accessibilityIdentifier("connectGoogleCalendar")
                if calendar.email != nil {
                    HStack {
                        Button("Try connection again") { Task { await calendar.refresh() } }
                        Spacer()
                        Button("Sign out") { Task { await calendar.signOut() } }
                    }.disabled(calendar.connecting)
                }
                Spacer()
            }
            .padding(28) }
            .navigationTitle("Welcome to Agora")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct CalendarSettingsSection: View {
    @ObservedObject var calendar: CalendarConnection
    let stopAgent: () -> Void
    @State private var confirmDisconnect = false
    var body: some View {
        Section(calendar.isDemoAccount ? "Agora Calendar" : "Google Calendar") {
            if calendar.isDemoAccount {
                Label("Built-in integrations active", systemImage: "checkmark.circle.fill")
                Text("No Google or model credentials are needed. Events stay in this account; no invitations or real purchases are sent.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Use Google account instead") { stopAgent(); Task { await calendar.connect() } }.disabled(calendar.connecting)
                Button("Sign out") { stopAgent(); Task { await calendar.signOut() } }.disabled(calendar.connecting)
            } else {
            Label(calendar.connected ? "Connected" : "Connection required", systemImage: calendar.connected ? "checkmark.circle.fill" : "calendar.badge.exclamationmark")
            if let email = calendar.email { Text(email) }
            Text("Agora checks availability and adds approved events to your primary calendar.").font(.footnote).foregroundStyle(.secondary)
            if let message = calendar.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Button("Reconnect Google Calendar") { stopAgent(); Task { await calendar.connect() } }.disabled(calendar.connecting)
            Button("Sign out") { stopAgent(); Task { await calendar.signOut() } }.disabled(calendar.connecting)
            Button("Disconnect Google Calendar", role: .destructive) { confirmDisconnect = true }.disabled(calendar.connecting)
        }
        }
        .confirmationDialog("Disconnect Google Calendar?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect and sign out", role: .destructive) { stopAgent(); Task { await calendar.disconnect() } }
        } message: { Text("Agora will lose Calendar access. Your existing Google Calendar events will remain.") }
    }
}

struct CalendarGate<Content: View>: View {
    @ObservedObject var calendar: CalendarConnection
    let onDisconnect: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        Group {
            if calendar.checking { ProgressView("Checking your connection…") }
            else if calendar.connected { content() }
            else { CalendarOnboardingView(calendar: calendar) }
        }
        .task { await calendar.refresh() }
        .onChange(of: calendar.accountID) { old, new in
            if old != nil && old != new { onDisconnect() }
        }
        .onChange(of: calendar.connected) { _, connected in
            if !connected { onDisconnect() }
        }
    }
}
