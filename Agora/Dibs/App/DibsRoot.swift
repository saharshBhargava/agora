import SwiftUI
import GoogleSignIn

/// The app's one window: the Dibs home at the root of one `NavigationStack`, with every run screen and
/// household screen a `Route` pushed on top. Light only (paper and ink), tinted ink, no tab bar.
///
/// It owns the Dibs `AppModel` and carries the app-wide wiring: opened links (Dibs links go to the Dibs
/// model, anything else is Google sign-in's callback), the watch push sheet, push registration and the
/// household refresh loops, pausing the assistant when the app leaves the foreground, and the account
/// checks the old sign-in gate made (restore the session at launch, reset conversations when the
/// account changes or signs out). Nothing is gated on signing in: a typed name is enough for Dibs.
struct DibsRootView: View {
    let workspace: ChatWorkspace
    @State private var model: AppModel
    @State private var autoShopStarted = false
    @ObservedObject private var calendar: CalendarConnection
    @ObservedObject private var push = PushNotifications.shared
    @Environment(\.scenePhase) private var scenePhase

    /// `model` is for tests; the app makes its own.
    @MainActor init(workspace: ChatWorkspace, model: AppModel? = nil) {
        self.workspace = workspace
        let appModel = model ?? AppModel()
        let calendar = workspace.calendar
        // "+ Wish" reads the signed-in person's own household with their token (AppModel decides which server may see it).
        appModel.householdToken = { [weak calendar] in
            guard let calendar, calendar.connected, let id = calendar.accountID else { return nil }
            return try? await calendar.apiToken(for: id)
        }
        _model = State(initialValue: appModel)
        _calendar = ObservedObject(wrappedValue: calendar)
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            DibsHomeView(workspace: workspace)
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        // A claim or shopper screen moves to Settle (or the receipt check) when the live run gets there.
        .onChange(of: model.store.run.map { "\($0.id)|\($0.state.rawValue)" }) { model.followRun() }
        .onChange(of: scenePhase) { _, phase in
            AppLog.event(.app, phase == .active ? "scene.active" : phase == .background ? "scene.background" : "scene.inactive")
            // Back from the lock screen or another app: check the run socket at once instead of waiting
            // for the heartbeat. Leaving the foreground pauses the assistant.
            if phase == .active { model.store.foregrounded() }
            else { workspace.agent.stop(reason: "Paused while the app is inactive. Press Resume to continue.", paused: true) }
        }
        .confirmationDialog(
            "This link is from \(model.pendingLink?.server?.host ?? "another server"). Use it as your Dibs server?",
            isPresented: Binding(
                get: { model.pendingLink != nil },
                set: { if !$0 { model.cancelPendingServer() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingLink
        ) { link in
            Button("Use server") { Task { await model.confirmPendingServer(link) } }
            Button("Cancel", role: .cancel) { model.cancelPendingServer() }
        }
        .sheet(isPresented: Binding(get: { push.openWatchID != nil && calendar.connected },
                                   set: { if !$0 { push.openWatchID = nil } })) {
            if let id = push.openWatchID {
                NavigationStack { WatchDetailView(store: workspace.shopping.watches, watchID: id) }
                    .tint(Color.ink)
            }
        }
        .background { InventoryRefresh(store: workspace.inventory) }
        .background { ShoppingRefresh(store: workspace.shopping) }
        .background { TripRefresh(store: workspace.trips) }
        .background { PushSessionSync(calendar: workspace.calendar, api: workspace.api) }
        .background { WatchBrowserReviewNavigation(store: workspace.shopping.watches) { model.openHousehold(.assistant) } }
        .background { NamePrefill(calendar: workspace.calendar, inventory: workspace.inventory, model: model) }
        .onOpenURL { url in
            if Self.owns(url) { model.open(url: url) }
            else if calendar.configurationIssue == nil { _ = GIDSignIn.sharedInstance.handle(url) }
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL, Self.owns(url) { model.open(url: url) }
        }
        // What the sign-in gate did besides gating: restore the saved session, and drop the assistant's
        // conversations when the account changes or signs out.
        .task { await calendar.refresh() }
        .onChange(of: calendar.accountID) { old, new in
            if old != nil && old != new { workspace.agent.resetConversations() }
        }
        .onChange(of: calendar.connected) { _, connected in
            if !connected { workspace.agent.resetConversations() }
        }
        .task {
            // Unattended device testing: `-DibsAutoShop YES` starts a run and opens the shopper camera
            // inside the normal routes (receipt and settle included).
            guard DebugLaunch.autoShop, !autoShopStarted else { return }
            autoShopStarted = true
            do { try await model.autoShop() } catch { DibsLog.event("autoshop failed: \(error)") }
        }
        .environment(model)
        .environment(\.colorScheme, .light)
        .preferredColorScheme(.light)
        .tint(Color.ink)
    }

    /// Whether an opened URL belongs to Dibs: any `dibs://` URL (Dibs explains a malformed one on its
    /// Home), or an http(s) Dibs join link. Everything else (Google sign-in callbacks) goes to Google.
    static func owns(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "dibs" { return true }
        return JoinLink.parse(url.absoluteString) != nil
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .start(let ref):
            StartView(ref: ref)
        case .join(let runId, let decline):
            JoinView(runId: runId, decline: decline)
        case .claim(let ref):
            ClaimView(ref: ref, onSettle: { model.path.append(.settle(ref)) })
        case .shopper(let ref):
            ShopperView(store: model.store, api: model.api, runId: ref.runId, personId: ref.personId,
                        onSnapReceipt: { model.openReceipt(ref) },
                        onLeave: { model.leaveRun(); model.path = [] })
        case .settle(let ref):
            SettleView(ref: ref)
        case .household(let page):
            HouseholdPageView(page: page, workspace: workspace)
        }
    }
}

/// A household screen pushed from Home. Each lives inside the root stack; none brings its own.
struct HouseholdPageView: View {
    let page: HouseholdPage
    let workspace: ChatWorkspace
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch page {
            case .lists:
                TripsView(store: workspace.trips)
            case .pantry:
                InventoryListView(store: workspace.inventory, onScan: { model.openHousehold(.capture) })
            case .wishlist:
                ShoppingView(store: workspace.shopping, settings: workspace.settings)
            case .assistant:
                ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)
            case .capture:
                CaptureView(settings: workspace.settings, inventory: workspace.inventory)
            }
        }
        .toolbar(.visible, for: .navigationBar)
    }
}

/// Signed in: the account's first name becomes the Dibs join name when none is saved yet.
private struct NamePrefill: View {
    @ObservedObject var calendar: CalendarConnection
    @ObservedObject var inventory: InventoryStore
    let model: AppModel

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: calendar.connected ? inventory.displayName : nil, initial: true) { _, name in
                model.prefillName(from: name)
            }
    }
}

/// Stand-in for the claim and shopper screens until they land: connects to the run and shows who is in.
struct RunPendingView: View {
    let ref: RunRef
    @Environment(AppModel.self) private var model

    var body: some View {
        let run = model.store.run
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Wordmark()
            Text(run?.title ?? "Your run")
                .font(.display(30))
                .foregroundStyle(Color.ink)
            if let run, let message = RunText.stateMessage(run) {
                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
            }
            if let run {
                Text(RunText.whoLine(run: run, excluding: nil))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
            }
            if let me = model.store.me, let cents = me.authorizedCents {
                HeldBadge(cents: cents, approvalCode: me.approvalCode)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .dibsScreen()
        .task(id: ref) { model.enter(ref) }
    }
}
