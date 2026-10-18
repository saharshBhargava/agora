import SwiftUI

// Shared view styles for the screens (web/app/globals.css .btn, .card, .input, .wordmark).

extension Color {
    /// Body copy on paper (#2B2A27).
    static let bodyInk = Color(hex: 0x2B2A27)
}

/// Full-width 56 pt button. `.ink` is the main action, `.blue` the share action, `.secondary` a white card button,
/// `.danger` a stop action (the assistant's pause).
struct DibsButtonStyle: ButtonStyle {
    enum Kind { case ink, blue, secondary, danger }
    var kind: Kind = .ink
    var fontSize: CGFloat = 17
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
            .padding(.horizontal, Metrics.space3)
            // Disabled (also "Joining…"): only the fill fades, so the label stays readable (white on ~#555).
            .background(background.opacity(isEnabled || kind == .secondary ? 1 : 0.7),
                        in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }

    private var foreground: Color {
        guard kind == .secondary else { return .white }
        return isEnabled ? .ink : Color.ink.opacity(0.55)
    }

    private var background: Color {
        switch kind {
        case .ink: return .ink
        case .blue: return .meBlue
        case .secondary: return .card
        case .danger: return .danger
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

// MARK: - Shared pieces for the household screens (lists, pantry, wishlist, assistant, settings pages)

extension View {
    /// A `List` or `Form` on paper: white rows, hairline separators, ink text and tint.
    func dibsList() -> some View {
        self.scrollContentBackground(.hidden)
            .background(Color.paper.ignoresSafeArea())
            .listRowBackground(Color.card)
            .listRowSeparatorTint(Color.line)
            .foregroundStyle(Color.ink)
            .tint(Color.ink)
    }

    /// A page pushed from the Dibs home: paper behind everything, an inline ink title, the bar on paper.
    func dibsPage(_ title: String) -> some View {
        self.background(Color.paper.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.paper, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .tint(Color.ink)
    }
}

/// A section label above a card or list section: 13 pt semibold, muted, sentence case.
struct DibsSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.muted)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a screen shows when it has nothing yet: a muted symbol, an ink title and one line of help.
struct DibsEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: Metrics.space1) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(Color.muted)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.ink)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.space4)
        .padding(.horizontal, Metrics.space3)
    }
}
