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
                    HomeView(selectedTab: $selectedTab, calendar: workspace.calendar, backend: workspace.backend)
                        .tabItem { Label("Home", systemImage: "house") }
                        .tag(AppTab.home)
                    ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)
                        .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                        .tag(AppTab.chat)
                    CaptureView(settings: workspace.settings)
                        .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                        .tag(AppTab.capture)
                    SettingsView(settings: workspace.settings, workspace: workspace)
                        .tabItem { Label("Settings", systemImage: "gearshape") }
                        .tag(AppTab.settings)
                }
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
    let api: AgoraClient
    let calendar: CalendarConnection
    let backend: AgoraAPIClient
    init() {
        AppLog.event(.app, "workspace.created")
        let settings = SettingsStore(); self.settings = settings
        let browser = BrowserSession(policy: settings.policy); self.browser = browser
        let api = AgoraClient(); self.api = api
        let calendar = CalendarConnection(); self.calendar = calendar
        backend = AgoraAPIClient(calendar: calendar)
        agent = AgentCoordinator(settings: settings, browser: browser, calendar: calendar)
    }
}
