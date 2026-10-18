import SwiftUI

/// The Dibs tab inside the Agora app. It owns the Dibs `AppModel` and its `NavigationStack`, so Dibs
/// keeps its own server, routes and run state next to Agora's workspace.
///
/// Links reach it through `incomingURL`: the app's `onOpenURL` sets it for `dibs://join?run=…` (and
/// https join links) and selects this tab; the tab consumes the link and clears it. Because the change
/// is observed with `initial: true`, a link that arrives before the tab exists (while Agora's sign-in
/// gate is showing) still opens the join screen once the tab appears.
struct DibsTab: View {
    @Binding var incomingURL: URL?
    /// True while this tab is the selected one. The Dibs design is light only (paper and ink; dark mode
    /// left rows unreadable), but a color-scheme preference applies to the whole window, so the tab asks
    /// for light only while it is showing and the rest of Agora keeps following the system.
    var isActive: Bool
    @State private var model = AppModel()
    @State private var autoShopStarted = false

    var body: some View {
        DibsRootView()
            .environment(model)
            .environment(\.colorScheme, .light)
            .preferredColorScheme(isActive ? .light : nil)
            .onChange(of: incomingURL, initial: true) { _, url in
                guard let url else { return }
                incomingURL = nil
                model.open(url: url)
            }
            .task {
                // Unattended device testing: `-DibsAutoShop YES` starts a run and opens the shopper camera
                // inside the normal routes (receipt and settle included). The app selects this tab at launch.
                guard DebugLaunch.autoShop, !autoShopStarted else { return }
                autoShopStarted = true
                do { try await model.autoShop() } catch { DibsLog.event("autoshop failed: \(error)") }
            }
    }

    /// Whether an opened URL belongs to Dibs: any `dibs://` URL (Dibs explains a malformed one on its
    /// Home), or an http(s) Dibs join link. Everything else (Google sign-in callbacks) stays with Agora.
    static func owns(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == "dibs" { return true }
        return JoinLink.parse(url.absoluteString) != nil
    }
}

/// Home at the root; every run screen is a `Route` pushed on top.
struct DibsRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            DibsHomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        .tint(Color.ink)
        // A claim or shopper screen moves to Settle (or the receipt check) when the live run gets there.
        .onChange(of: model.store.run.map { "\($0.id)|\($0.state.rawValue)" }) { model.followRun() }
        // Back from the lock screen or another app: check the socket at once instead of waiting for the heartbeat.
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.store.foregrounded() } }
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
