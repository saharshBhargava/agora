import SwiftUI

enum AppTab: Hashable {
    case home, chat, capture, settings
}

struct HomeView: View {
    @Binding var selectedTab: AppTab

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "house.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.teal)
                            .accessibilityHidden(true)
                        Text("Welcome to Agora")
                            .font(.largeTitle.bold())
                        Text("Explore with your assistant or capture something you want to remember.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 16)

                    VStack(spacing: 12) {
                        shortcut("Open chat", detail: "Ask a question and explore the web together.",
                                 symbol: "bubble.left.and.bubble.right", tab: .chat)
                        shortcut("Capture an item", detail: "Take a photo, record a video, or import a file.",
                                 symbol: "camera.viewfinder", tab: .capture)
                    }

                    Button {
                        selectedTab = .settings
                    } label: {
                        Label("Manage settings", systemImage: "gearshape")
                            .padding(.vertical, 8)
                    }
                }
                .padding()
                .frame(maxWidth: 640, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Home")
        }
    }

    private func shortcut(_ title: String, detail: String, symbol: String, tab: AppTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(20)
            .background(Color.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }
}
