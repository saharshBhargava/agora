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
    init() {
        AppLog.event(.app, "workspace.created")
        let settings = SettingsStore(); self.settings = settings
        let browser = BrowserSession(policy: settings.policy); self.browser = browser
        let origin = (Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String).flatMap(URL.init(string:))
        let calendar = CalendarConnection(demoBaseURL: origin); self.calendar = calendar
        settings.demoCalendar = calendar
        api = AgoraClient(calendar: calendar)
        calendar.beforeSignOut = { [weak api] in
            if let api { await PushNotifications.shared.signOut(api: api) }
        }
        inventory = InventoryStore(api: api, calendar: calendar)
        shopping = ShoppingStore(api: api, inventory: inventory)
        trips = TripStore(api: api, inventory: inventory, calendar: calendar)
        agent = AgentCoordinator(settings: settings, browser: browser, calendar: calendar, shopping: shopping)
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
                    await store.refresh()
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
