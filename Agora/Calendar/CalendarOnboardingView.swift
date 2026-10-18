import SwiftUI
import GoogleSignInSwift

/// Signing in to the household account, as a sheet from Home or Settings. Dibs itself never needs it:
/// it brings the household's lists, pantry and wishlist in. Closes itself once the sign-in succeeds.
struct CalendarOnboardingView: View {
    @ObservedObject var calendar: CalendarConnection
    @Environment(\.dismiss) private var dismiss
    @State private var handle = "demo"
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Wordmark(size: 40)
                    Text("Bring your household")
                        .font(.display(32))
                        .foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your household's lists, pantry and wishlist come along on every run. Starting or joining a run never needs an account.")
                        .font(.system(size: 15))
                        .lineSpacing(2)
                        .foregroundStyle(Color.bodyInk)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Demo account")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.ink)
                        Text("Demo sign-in uses built-in Calendar, chat and recognition responses. No Google account or provider API keys are required.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Username", text: $handle)
                            .font(.system(size: 16))
                            .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .dibsInput()
                            .accessibilityIdentifier("demoUsername")
                        SecureField("Password", text: $password)
                            .font(.system(size: 16))
                            .textContentType(.password)
                            .dibsInput()
                            .accessibilityIdentifier("demoPassword")
                        if let message = calendar.message, message != calendar.configurationIssue {
                            ErrorText(message: message)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("calendarConnectionMessage")
                        }
                        Button(calendar.connecting ? "Signing in…" : "Sign in to demo") {
                            let submittedPassword = password
                            password = ""
                            Task { await calendar.connectDemo(handle: handle.trimmingCharacters(in: .whitespacesAndNewlines), password: submittedPassword) }
                        }
                        .buttonStyle(.dibs)
                        .disabled(calendar.connecting || password.isEmpty || handle.isEmpty)
                        .accessibilityIdentifier("signInDemo")
                    }
                    .dibsCard()

                    Rectangle().fill(Color.line).frame(height: 1)
                        .padding(.vertical, Metrics.space1)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Or use Google (optional)")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.ink)
                        Text("Your own account uses your real Calendar and configured model providers.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let email = calendar.email {
                        Text(email).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                    }
                    GoogleSignInButton {
                        Task { await calendar.connect() }
                    }
                    .disabled(calendar.connecting || calendar.configurationIssue != nil)
                    .accessibilityIdentifier("connectGoogleCalendar")
                    if let issue = calendar.configurationIssue {
                        Text(issue)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if calendar.email != nil {
                        HStack(spacing: Metrics.space1) {
                            Button("Try again") { Task { await calendar.refresh() } }
                                .buttonStyle(.dibs(.secondary, fontSize: 15))
                            Button("Sign out") { Task { await calendar.signOut() } }
                                .buttonStyle(.dibs(.secondary, fontSize: 15))
                        }
                        .disabled(calendar.connecting)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, Metrics.space1)
                .padding(.bottom, Metrics.space3)
            }
            .scrollDismissesKeyboard(.interactively)
            .dibsScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(Color.ink)
        .onChange(of: calendar.connected) { _, connected in
            if connected { dismiss() }
        }
    }
}
