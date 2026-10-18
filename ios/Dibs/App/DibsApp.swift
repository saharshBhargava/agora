import SwiftUI

@main
struct DibsApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { model.open(url: $0) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.open(url: url) }
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
            // Task 5 replaces this with ClaimView.
            RunPendingView(ref: ref)
        case .shopper(let ref):
            // Task 6 replaces this with ShopperView.
            RunPendingView(ref: ref)
        case .settle(let ref):
            // Task 8 replaces this with SettleView.
            RunPendingView(ref: ref)
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
