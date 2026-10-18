import SwiftUI

@main
struct BrowserChatApp: App {
    @UIApplicationDelegateAdaptor(AgoraNotificationDelegate.self) private var notificationsDelegate
    @StateObject private var workspace = ChatWorkspace()
    var body: some Scene {
        WindowGroup {
            // The old Dibs app is the core: its home at the root of one stack, the household screens
            // (lists, pantry, wishlist, assistant) pushed from it. See DibsRootView.
            DibsRootView(workspace: workspace)
        }
    }
}

struct PushSessionSync: View {
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
    let commerce: CommerceStore
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
        commerce = CommerceStore(api: api, inventory: inventory)
        agent = AgentCoordinator(settings: settings, browser: browser, calendar: calendar, shopping: shopping, trips: trips, commerce: commerce)
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

struct WatchRefresh: View {
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

struct TripRefresh: View {
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

struct InventoryRefresh: View {
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

struct ShoppingRefresh: View {
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

/// A watch's "review in the browser" opens the assistant, where the shared browser lives.
struct WatchBrowserReviewNavigation: View {
    @ObservedObject var store: WatchStore
    let openAssistant: () -> Void
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: store.browserReviewRequestID) { _, request in
                guard request != nil, store.canUse else { return }
                PushNotifications.shared.openWatchID = nil
                openAssistant()
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
