import SwiftUI

@main
struct DibsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            if DebugLaunch.autoShop {
                // Unattended device testing: `-DibsAutoShop YES` skips Home and opens the shopper camera.
                AutoShopRoot(base: ServerConfig.current())
                    .preferredColorScheme(.light)
            } else {
                RootView()
                    .environment(model)
                    // The design is light only (paper and ink); dark mode left rows unreadable.
                    .preferredColorScheme(.light)
                    .onOpenURL { model.open(url: $0) }
                    .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                        if let url = activity.webpageURL { model.open(url: url) }
                    }
            }
        }
    }
}

/// Home at the root; every run screen is a `Route` pushed on top.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: Route.self) { route in
                    destination(route)
                }
        }
        .tint(Color.ink)
        // A claim or shopper screen moves to Settle (or the receipt check) when the live run gets there.
        .onChange(of: model.store.run.map { "\($0.id)|\($0.state.rawValue)" }) { model.followRun() }
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
