import SwiftUI

/// Home's gear: the account (sign in or out), the Dibs server address (saved to `UserDefaults`
/// `dibs.server`), and the household's settings pages. Paper, white cards, ink.
struct SettingsSheet: View {
    let workspace: ChatWorkspace
    @ObservedObject private var calendar: CalendarConnection
    @ObservedObject private var inventory: InventoryStore
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var signingIn = false

    init(workspace: ChatWorkspace) {
        self.workspace = workspace
        _calendar = ObservedObject(wrappedValue: workspace.calendar)
        _inventory = ObservedObject(wrappedValue: workspace.inventory)
    }

    private var bundled: URL { ServerConfig.bundled() ?? ServerConfig.fallback }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Text("Settings")
                        .font(.display(32))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)

                    DibsSectionHeader("Account")
                    account

                    DibsSectionHeader("Dibs server")
                    server

                    DibsSectionHeader("Household")
                    HouseholdSettingsLinks(settings: workspace.settings, workspace: workspace)
                        .padding(.horizontal, Metrics.space2)
                        .padding(.vertical, 4)
                        .dibsCard(padding: 0)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, Metrics.space3)
            }
            .scrollDismissesKeyboard(.interactively)
            .dibsScreen()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
        .tint(Color.ink)
        .onAppear { text = model.server.absoluteString }
        .sheet(isPresented: $signingIn) {
            CalendarOnboardingView(calendar: calendar)
        }
    }

    @ViewBuilder
    private var account: some View {
        if calendar.connected {
            let name = inventory.displayName ?? calendar.email ?? "Signed in"
            let person = Person(id: "me", name: name, initial: RunText.initial(of: name), isShopper: false)
            VStack(alignment: .leading, spacing: Metrics.space2) {
                HStack(spacing: 12) {
                    Avatar(person: person, people: [person], me: person.id, size: .lg)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text(inventory.displayName != nil ? calendar.email ?? "Signed in" : "Signed in")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.account")
                Button("Sign out") {
                    workspace.agent.stop()
                    Task { await calendar.signOut() }
                }
                .buttonStyle(.dibs(.secondary, fontSize: 16))
                .disabled(calendar.connecting)
                .accessibilityIdentifier("settings.signOut")
            }
            .dibsCard()
        } else if calendar.checking {
            HStack(spacing: Metrics.space1) {
                ProgressView()
                Text("Checking your account…").font(.system(size: 14)).foregroundStyle(Color.muted)
            }
            .dibsDashedBox()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Sign in to bring your household's lists, pantry and wishlist into your runs.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign in") { signingIn = true }
                    .buttonStyle(.dibs(.secondary, fontSize: 16))
                    .accessibilityIdentifier("settings.signIn")
            }
            .dibsDashedBox()
        }
    }

    private var server: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("https://your-server.ngrok.app", text: $text)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.done)
                .onSubmit(save)
                .dibsInput()
                .accessibilityIdentifier("settings.server")
            Text("Use an https:// address. Plain http works only for localhost.")
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
            if let error {
                ErrorText(message: error)
            }
            Button("Save", action: save)
                .buttonStyle(.dibs)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                model.resetServer()
                dismiss()
            } label: {
                VStack(spacing: 2) {
                    Text("Use the built-in server")
                    Text(bundled.absoluteString)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.dibs(.secondary, fontSize: 16))
        }
        .dibsCard()
    }

    private func save() {
        if model.saveServer(text) {
            dismiss()
        } else {
            error = "That isn't a usable server address. Use https://, or http://localhost for the simulator."
        }
    }
}

#if DEBUG
#Preview("Settings") {
    Color.paper.sheet(isPresented: .constant(true)) {
        SettingsSheet(workspace: ChatWorkspace())
    }
    .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settings")!))
}
#endif
