import SwiftUI
import UIKit

/// The first screen: start a run as the shopper, or join one from a pasted link. Never blank: it shows
/// at once, while the launch check for a run to resume runs underneath. Between the tagline and the join
/// card, the household: what to pick up on the next run, and its lists, pantry, wishlist and assistant.
/// The body scrolls; "Start a run" stays pinned at the bottom.
struct DibsHomeView: View {
    let workspace: ChatWorkspace
    @Environment(AppModel.self) private var model
    @State private var linkText = ""
    @State private var starting = false
    @State private var startError: String?
    @State private var showSettings = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ScrollView {
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
                    .accessibilityLabel("Settings")
                }

                VStack(alignment: .leading, spacing: Metrics.space2) {
                    Wordmark(size: 56)
                    Text("Shop with your room watching. Claim what is yours, as it lands in the cart.")
                        .font(.system(size: 17))
                        .lineSpacing(3)
                        .foregroundStyle(Color.bodyInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Metrics.space2)
                .padding(.bottom, Metrics.space1)

                HouseholdCards(calendar: workspace.calendar, inventory: workspace.inventory, shopping: workspace.shopping)

                joinCard
            }
            .padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space2)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
        .dibsScreen()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(workspace: workspace)
        }
        .onAppear { model.leaveRun() }
        .task { await model.launch() }
    }

    /// Pinned under the scrolling body: the resume line, any error, and "Start a run".
    private var startBar: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            if model.resuming {
                HStack(spacing: Metrics.space1) {
                    ProgressView()
                    Text("Opening your last run…").font(.system(size: 14)).foregroundStyle(Color.muted)
                }
            }

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
        .background(Color.paper.ignoresSafeArea(edges: .bottom))
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

/// "For your next run" (signed in, when the household has something) and "Your household".
private struct HouseholdCards: View {
    @ObservedObject var calendar: CalendarConnection
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var shopping: ShoppingStore
    @State private var signingIn = false

    private var nextRun: [NextRunRow] {
        guard calendar.connected else { return [] }
        return NextRunPicks.rows(inventory: inventory.activeItems, wishlist: shopping.active, suggestions: shopping.suggestions)
    }

    var body: some View {
        let rows = nextRun
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: "For your next run", subtitle: "Running low at home, and on your household's wishlist.")
                    .padding(.bottom, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Hairline() }
                    NavigationLink(value: Route.household(row.page)) {
                        NextRunRowView(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.nextRun.\(row.id)")
                }
            }
            .dibsCard()
        }

        if calendar.connected {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle(title: "Your household", subtitle: nil)
                    .padding(.bottom, 4)
                ForEach(Array(Self.entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Hairline() }
                    NavigationLink(value: Route.household(entry.page)) {
                        DibsLinkRow(title: entry.title, detail: entry.detail, symbol: entry.symbol, tint: entry.tint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home.household.\(entry.id)")
                }
            }
            .dibsCard()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(title: "Your household", subtitle: nil)
                if calendar.checking {
                    HStack(spacing: Metrics.space1) {
                        ProgressView()
                        Text("Checking your account…").font(.system(size: 14)).foregroundStyle(Color.muted)
                    }
                    .frame(minHeight: 32)
                } else {
                    Text("Sign in to bring your household's lists, pantry and wishlist into your runs.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Sign in") { signingIn = true }
                        .buttonStyle(.dibs(.secondary))
                        .accessibilityIdentifier("home.signIn")
                }
            }
            .dibsDashedBox()
            .sheet(isPresented: $signingIn) {
                CalendarOnboardingView(calendar: calendar)
            }
        }
    }

    private struct Entry {
        let id: String
        let page: HouseholdPage
        let title: String
        let detail: String
        let symbol: String
        let tint: UInt32
    }

    private static let entries: [Entry] = [
        Entry(id: "lists", page: .lists, title: "Lists", detail: "Shopping lists and trips", symbol: "checklist", tint: 0xD8E2FA),
        Entry(id: "pantry", page: .pantry, title: "Pantry", detail: "What you have at home", symbol: "shippingbox", tint: 0xF2E3B5),
        Entry(id: "wishlist", page: .wishlist, title: "Wishlist", detail: "Watch prices, get suggestions", symbol: "heart", tint: 0xF6D9CC),
        Entry(id: "assistant", page: .assistant, title: "Assistant", detail: "Ask, plan, compare", symbol: "bubble.left.and.bubble.right", tint: 0xE5DDF7),
    ]
}

/// A home card's 15 pt bold title and optional 13 pt muted subtitle (the join card's type scale).
private struct CardTitle: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#if DEBUG
#Preview("Home") {
    let defaults = UserDefaults(suiteName: "preview.home")!
    NavigationStack { DibsHomeView(workspace: ChatWorkspace()) }
        .environment(AppModel(defaults: defaults))
}
#endif
