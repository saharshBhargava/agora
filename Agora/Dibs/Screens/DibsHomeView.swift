import SwiftUI
import UIKit

/// The first screen: start a run as the shopper, or join one from a pasted link. Never blank: it shows
/// at once, while the launch check for a run to resume runs underneath.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var linkText = ""
    @State private var starting = false
    @State private var startError: String?
    @State private var showSettings = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Color.muted)
                        .frame(width: Metrics.tap, height: Metrics.tap)
                }
                .accessibilityLabel("Server settings")
            }

            Spacer(minLength: Metrics.space2)

            VStack(alignment: .leading, spacing: Metrics.space2) {
                Wordmark(size: 56)
                Text("Shop with your room watching. Claim what is yours, as it lands in the cart.")
                    .font(.system(size: 17))
                    .lineSpacing(3)
                    .foregroundStyle(Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Metrics.space2)

            if model.resuming {
                HStack(spacing: Metrics.space1) {
                    ProgressView()
                    Text("Opening your last run…").font(.system(size: 14)).foregroundStyle(Color.muted)
                }
            }

            joinCard

            if let message = startError ?? model.homeError {
                ErrorText(message: message)
            }

            Button {
                Task { await start() }
            } label: {
                Text(starting ? "Starting…" : "Start a run")
            }
            .buttonStyle(.dibs)
            .disabled(starting)
        }
        .padding(.horizontal, 20)
        .padding(.top, Metrics.space1)
        .padding(.bottom, Metrics.space2)
        .dibsScreen()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .onAppear { model.leaveRun() }
        .task { await model.launch() }
    }

    private var joinCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Join with a link")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.ink)
            Text("Open the link from your house chat, or paste it here.")
                .font(.system(size: 13))
                .foregroundStyle(Color.muted)
            HStack(spacing: Metrics.space1) {
                TextField("Paste the join link", text: $linkText)
                    .font(.system(size: 15))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.join)
                    .focused($linkFocused)
                    .onSubmit(joinFromText)
                    .dibsInput()
                    .contentShape(Rectangle())
                    .onTapGesture { linkFocused = true }
                Button {
                    // Reading the pasteboard shows the system "Allow Paste" prompt once.
                    guard let text = UIPasteboard.general.string else { return }
                    linkText = text
                    joinFromText()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.ink)
                        .frame(width: 52, height: 52)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
                }
                .accessibilityLabel("Paste link")
            }
            Button("Join", action: joinFromText)
                .buttonStyle(.dibs(.secondary))
                .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .dibsCard()
    }

    private func joinFromText() {
        startError = nil
        guard let link = JoinLink.parse(linkText) else {
            model.homeError = linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil : "That doesn't look like a Dibs link. It should end in /join?run=…"
            return
        }
        linkFocused = false
        linkText = ""
        Task { await model.open(link) }
    }

    private func start() async {
        starting = true
        startError = nil
        model.homeError = nil
        defer { starting = false }
        do {
            try await model.startRun()
        } catch {
            startError = (error as? LocalizedError)?.errorDescription ?? "Could not start a run"
        }
    }
}

#if DEBUG
#Preview("Home") {
    let defaults = UserDefaults(suiteName: "preview.home")!
    NavigationStack { HomeView() }
        .environment(AppModel(defaults: defaults))
}
#endif
