import SwiftUI

extension Color {
    /// Home's cerulean, with a lighter text/link variant for dark appearances.
    static let agoraAccent = Color("AccentColor")
    static let agoraBackground = Color(uiColor: .systemGroupedBackground)
    static let agoraSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let agoraAction = Color(red: 0, green: 0.36, blue: 0.49)
}

extension View {
    /// Shared by destinations as well as roots so sheets and previews stay consistent.
    func agoraSurface() -> some View {
        self
            .tint(Color.agoraAccent)
            .labelStyle(.titleOnly)
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.agoraBackground)
            .toolbarBackground(Color.agoraBackground, for: .navigationBar)
    }
}

struct AgoraPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.agoraAction, in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

/// Empty states use the same quiet typography as Home, without decorative symbols.
struct AgoraEmptyState: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }
}

/// Native list behavior, with open rows on Home's canvas instead of stacked white cards.
struct AgoraList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content.listRowBackground(Color.agoraBackground)
        }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .agoraSurface()
    }
}
