import SwiftUI

@main
struct BrowserChatApp: App {
    @StateObject private var workspace = ChatWorkspace()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            TabView {
                ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)
                    .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                SettingsView(settings: workspace.settings, workspace: workspace)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .tint(.teal)
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
    init() {
        AppLog.event(.app, "workspace.created")
        let settings = SettingsStore(); self.settings = settings
        let browser = BrowserSession(policy: settings.policy); self.browser = browser
        agent = AgentCoordinator(settings: settings, browser: browser)
    }
}
