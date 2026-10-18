import SwiftUI

// Shared view styles for the screens (web/app/globals.css .btn, .card, .input, .wordmark).

extension Color {
    /// Body copy on paper (#2B2A27).
    static let bodyInk = Color(hex: 0x2B2A27)
}

/// Full-width 56 pt button. `.ink` is the main action, `.blue` the share action, `.secondary` a white card button.
struct DibsButtonStyle: ButtonStyle {
    enum Kind { case ink, blue, secondary }
    var kind: Kind = .ink
    var fontSize: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(kind == .secondary ? Color.ink : Color.white)
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
            .padding(.horizontal, Metrics.space3)
            .background(background, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }

    private var background: Color {
        switch kind {
        case .ink: return .ink
        case .blue: return .meBlue
        case .secondary: return .card
        }
    }
}

extension ButtonStyle where Self == DibsButtonStyle {
    static var dibs: DibsButtonStyle { DibsButtonStyle() }
    static func dibs(_ kind: DibsButtonStyle.Kind, fontSize: CGFloat = 17) -> DibsButtonStyle {
        DibsButtonStyle(kind: kind, fontSize: fontSize)
    }
}

extension View {
    /// White card with a hairline border.
    func dibsCard(radius: CGFloat = Metrics.radius, padding: CGFloat = Metrics.space2) -> some View {
        self.padding(padding)
            .background(Color.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.line))
    }

    /// Text field box: 52 pt, white, strong hairline.
    func dibsInput() -> some View {
        self.padding(.horizontal, Metrics.space2)
            .frame(minHeight: 52)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
    }

    /// Paper background behind the whole screen, with the navigation bar blending into it.
    func dibsScreen() -> some View {
        self.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.paper.ignoresSafeArea())
            .toolbarBackground(Color.paper, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The "dibs" wordmark.
struct Wordmark: View {
    var size: CGFloat = 26
    var body: some View {
        Text("dibs")
            .font(.display(size))
            .tracking(size > 40 ? -2 : -0.5)
            .foregroundStyle(Color.ink)
            .accessibilityLabel("Dibs")
    }
}

/// Error line in danger red (web .error).
struct ErrorText: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isStaticText)
    }
}
