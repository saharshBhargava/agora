import SwiftUI

@main
struct DibsApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// Placeholder root. The start, join, shop and settle screens replace it in later tasks.
struct RootView: View {
    var body: some View {
        VStack(spacing: Metrics.space1) {
            Text("Dibs")
                .font(.display(44))
                .foregroundStyle(Color.ink)
            Text(ServerConfig.current().host ?? "")
                .font(.footnote)
                .foregroundStyle(Color.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paper)
    }
}
