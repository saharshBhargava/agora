import SwiftUI
import GoogleSignIn

@main
struct BrowserChatApp: App {
    @UIApplicationDelegateAdaptor(AgoraNotificationDelegate.self) private var notificationsDelegate
    @ObservedObject private var push = PushNotifications.shared
    @StateObject private var workspace = ChatWorkspace()
    @State private var selectedTab: AppTab = .home
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            CalendarGate(calendar: workspace.calendar, onDisconnect: { workspace.agent.resetConversations() }) {
                TabView(selection: $selectedTab) {
                    HomeView(selectedTab: $selectedTab, store: workspace.inventory, shopping: workspace.shopping, settings: workspace.settings, trips: workspace.trips)
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(AppTab.home)
                    ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .tag(AppTab.chat)
                    CaptureView(settings: workspace.settings, inventory: workspace.inventory)
                        .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                        .tag(AppTab.capture)
                    ListsView(inventory: workspace.inventory, shopping: workspace.shopping, settings: workspace.settings, trips: workspace.trips)
                        .tabItem { Label("Lists", systemImage: "list.bullet") }
                        .tag(AppTab.lists)
                    SettingsView(settings: workspace.settings, workspace: workspace)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
                .background { InventoryRefresh(store: workspace.inventory) }
                .background { ShoppingRefresh(store: workspace.shopping) }
                .background { TripRefresh(store: workspace.trips) }
                .background { WatchRefresh(store: workspace.shopping.watches) }
            }
            .background { ItemImageSessionSync(store: workspace.images, inventory: workspace.inventory) }
            .tint(.teal)
            .sheet(isPresented: Binding(get: { push.openWatchID != nil && workspace.calendar.connected },
                                       set: { if !$0 { push.openWatchID = nil } })) {
                if let id = push.openWatchID {
                    NavigationStack { WatchDetailView(store: workspace.shopping.watches, watchID: id) }
                }
            }
            .environment(\.itemImages, workspace.images)
            .background { PushSessionSync(calendar: workspace.calendar, api: workspace.api) }
            .background { WatchBrowserReviewNavigation(store: workspace.shopping.watches, selectedTab: $selectedTab) }
            .onOpenURL { url in
                if workspace.calendar.configurationIssue == nil { _ = GIDSignIn.sharedInstance.handle(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                AppLog.event(.app, phase == .active ? "scene.active" : phase == .background ? "scene.background" : "scene.inactive")
                if phase != .active { workspace.agent.stop(reason: "Paused while the app is inactive. Press Resume to continue.", paused: true) }
            }
        }
    }
}

private struct PushSessionSync: View {
    @ObservedObject var calendar: CalendarConnection
    let api: AgoraClient
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(calendar.accountID ?? "signed-out")-\(calendar.connected)-\(phase == .active)") {
                if !calendar.connected { PushNotifications.shared.suspend() }
                else if phase == .active { await PushNotifications.shared.sync(api: api) }
            }
    }
}

@MainActor
final class ChatWorkspace: ObservableObject {
    let settings: SettingsStore
    let browser: BrowserSession
    let agent: AgentCoordinator
    let calendar: CalendarConnection
    let api: AgoraClient
    let inventory: InventoryStore
    let shopping: ShoppingStore
    let trips: TripStore
    let images: ItemImageStore
    let watchBrowser: WatchBrowserRunner
    init() {
        AppLog.event(.app, "workspace.created")
        let settings = SettingsStore(); self.settings = settings
        let browser = BrowserSession(policy: settings.policy); self.browser = browser
        let origin = (Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String).flatMap(URL.init(string:))
        let calendar = CalendarConnection(demoBaseURL: origin); self.calendar = calendar
        settings.demoCalendar = calendar
        api = AgoraClient(calendar: calendar)
        images = ItemImageStore(api: api, calendar: calendar)
        calendar.beforeSignOut = { [weak api] in
            if let api { await PushNotifications.shared.signOut(api: api) }
        }
        inventory = InventoryStore(api: api, calendar: calendar)
        shopping = ShoppingStore(api: api, inventory: inventory)
        trips = TripStore(api: api, inventory: inventory, calendar: calendar)
        agent = AgentCoordinator(settings: settings, browser: browser, calendar: calendar, shopping: shopping, trips: trips)
        let agent = agent
        watchBrowser = WatchBrowserRunner(api: api, browser: browser, store: shopping.watches) { [weak agent, weak calendar] in
            calendar?.connected == true && calendar?.isDemoAccount == false && agent?.running == false
        }
        let runner = watchBrowser
        shopping.watches.browserFallbackHandler = { [weak runner] watch in await runner?.check(watch) }
        shopping.watches.browserReviewHandler = { [weak self] url in
            guard let self, self.calendar.connected, self.inventory.accountID == self.calendar.accountID else {
                throw BrowserError("account_changed", "Sign in again before opening this browser review.")
            }
            try self.browser.policy.validate(url)
            self.agent.stop(reason: "You have control of this watch review. Continue directly in the browser.")
            self.browser.close()
            self.browser.state.isOpen = true
            self.browser.state.privateMode = true
            self.browser.setPresentationFromUser(.expanded)
            self.browser.state.status = "Private browser review · You have control"
            let context = self.shopping.watches.context, account = self.calendar.accountID
            let epoch = self.browser.epoch, lease = self.browser.lease
            Task { [weak self] in
                guard let self, self.calendar.connected, self.calendar.accountID == account,
                      self.shopping.watches.context == context, self.browser.epoch == epoch,
                      self.browser.lease == lease else { return }
                do { _ = try await self.browser.open(url) }
                catch {
                    guard self.calendar.connected, self.calendar.accountID == account,
                          self.shopping.watches.context == context, self.browser.epoch == epoch else { return }
                    // Manual/private mode deliberately blocks open's final observation. User takeover
                    // and a new browser session also end monitoring without replacing their status.
                    if let browserError = error as? BrowserError,
                       ["user_action_required", "cancelled", "stale_session"].contains(browserError.code) { return }
                    self.browser.state.status = InventoryStore.message(error)
                }
            }
        }
    }
}

private struct WatchRefresh: View {
    @ObservedObject var store: WatchStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(store.context)-\(phase == .active)-\(store.hasPendingWork)") {
                guard phase == .active, store.canUse else { return }
                while !Task.isCancelled {
                    await store.refresh(poll: false)
                    await store.runBrowserFallbacks()
                    do { try await Task.sleep(for: .seconds(store.hasPendingWork ? 5 : 30)) } catch { return }
                }
            }
    }
}

private struct TripRefresh: View {
    @ObservedObject var store: TripStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(store.context)-\(phase == .active)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}

private struct InventoryRefresh: View {
    @ObservedObject var store: InventoryStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(store.context)-\(phase == .active)") {
                guard phase == .active else { return }
                // Refresh on foreground/household changes and periodically while the app is open.
                // Shared state also updates immediately after every successful local mutation.
                while !Task.isCancelled {
                    await store.refreshWithForecasts()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}

private struct ShoppingRefresh: View {
    @ObservedObject var store: ShoppingStore
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: "\(store.context)-\(phase == .active)") {
                guard phase == .active else { return }
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}

private struct WatchBrowserReviewNavigation: View {
    @ObservedObject var store: WatchStore
    @Binding var selectedTab: AppTab
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: store.browserReviewRequestID) { _, request in
                guard request != nil, store.canUse else { return }
                PushNotifications.shared.openWatchID = nil
                selectedTab = .chat
            }
    }
}

struct ItemImageSessionSync: View {
    @ObservedObject var store: ItemImageStore
    @ObservedObject var inventory: InventoryStore
    @Environment(\.scenePhase) private var phase

    private struct LoadKey: Hashable {
        let context: String
        let references: [ItemImageReference]
        let active: Bool
    }

    var body: some View {
        let references = inventory.items.map {
            ItemImageReference(kind: "inventory", id: $0.id, name: $0.displayName, category: $0.category)
        }
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: inventory.context, initial: true) { _, context in
                store.reset(context: context.uuidString)
            }
            .task(id: LoadKey(context: store.context, references: references, active: phase == .active)) {
                guard phase == .active, !references.isEmpty else { return }
                while !Task.isCancelled {
                    await store.prefetch(references)
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
    }
}
