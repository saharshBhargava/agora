import SwiftUI
import GoogleSignIn

@main
struct BrowserChatApp: App {
    @StateObject private var workspace = ChatWorkspace()
    @State private var selectedTab: AppTab = .home
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            CalendarGate(calendar: workspace.calendar, onDisconnect: { workspace.agent.newChat() }) {
                TabView(selection: $selectedTab) {
                    HomeView(selectedTab: $selectedTab, store: workspace.inventory)
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(AppTab.home)
                    ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .tag(AppTab.chat)
                    CaptureView(settings: workspace.settings, inventory: workspace.inventory)
                        .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                        .tag(AppTab.capture)
                    InventoryView(store: workspace.inventory)
                        .tabItem { Label("Inventory", systemImage: "shippingbox") }
                        .tag(AppTab.inventory)
                    SettingsView(settings: workspace.settings, workspace: workspace)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
                .background { InventoryRefresh(store: workspace.inventory) }
            }
            .tint(.teal)
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

@MainActor
final class ChatWorkspace: ObservableObject {
    let settings: SettingsStore
    let browser: BrowserSession
    let agent: AgentCoordinator
    let calendar: CalendarConnection
    let api: AgoraClient
    let inventory: InventoryStore
    init() {
        AppLog.event(.app, "workspace.created")
        let settings = SettingsStore(); self.settings = settings
        let browser = BrowserSession(policy: settings.policy); self.browser = browser
        let calendar = CalendarConnection(); self.calendar = calendar
        api = AgoraClient(calendar: calendar)
        inventory = InventoryStore(api: api, calendar: calendar)
        agent = AgentCoordinator(settings: settings, browser: browser, calendar: calendar)
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
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                }
            }
    }
}
