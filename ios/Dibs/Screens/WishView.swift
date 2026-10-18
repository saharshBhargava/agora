import SwiftUI
import UIKit

/// "+ Wish" (canvas Wish.dc.html), pushed from the claim screen: type anything, or tap "+" on an item
/// from the household's shopping list or the suggestions (`GET /api/runs/:id/wish-picks`). A wish lands
/// on the shelf as a dashed chip and in my tray when the shopper adds the item. The page stays open, so
/// several wishes take several taps; each turns blue with a check.
struct WishView: View {
    /// The run, live: items the shopper adds while this page is open drop off it.
    let run: Run
    let me: String
    var shopperName: String?
    /// The phone's usual picks, newest first: shown only when the server offers nothing.
    var usualPicks: [String] = []
    /// Loads the page's list and suggestions; nil when they could not be had.
    var loadPicks: () async -> WishPicks? = { nil }
    /// Sends the wish; returns an error message, or nil when it was added.
    var onWish: (String) async -> String? = { _ in nil }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busyKey: String?
    @State private var error: String?
    @State private var confirmation: String?
    @State private var loading = true
    @State private var picks: WishPicks?
    @State private var justWished: Set<String> = []
    /// The usual picks as they were on arrival, so one I wish here stays (as Wished) instead of vanishing.
    @State private var usualSnapshot: [String]?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var busy: Bool { busyKey != nil }
    private var sections: WishLogic.Sections {
        WishLogic.sections(picks: picks, run: run, me: me, justWished: justWished, usual: usualSnapshot ?? usualPicks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backButton
            header
            entry
            ScrollView {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, Metrics.space3)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if usualSnapshot == nil { usualSnapshot = usualPicks }
            guard loading else { return }
            picks = await loadPicks()
            loading = false
        }
    }

    // MARK: top

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.ink)
                .frame(width: Metrics.tap, height: Metrics.tap)
                .background(Circle().fill(Color.card))
                .overlay(Circle().strokeBorder(Color.line))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to the cart")
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Wish for something")
                .font(.display(28))
                .tracking(-0.5)
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text(WishLogic.subtitle(shopperName: shopperName))
                .font(.system(size: 14))
                .foregroundStyle(Color.muted)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
    }

    private var entry: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Metrics.space1) {
                TextField("Type anything, like oat milk", text: $name)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.ink)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { add(trimmed, typed: true) }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lineStrong))
                    .accessibilityLabel("Type a wish")
                Button { add(trimmed, typed: true) } label: {
                    Group {
                        if busyKey == WishLogic.key(trimmed), !trimmed.isEmpty { ProgressView().tint(.white) } else { Text("Add") }
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .frame(height: 48)
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                // Always ink, as on the canvas: an empty or busy tap does nothing (see `add`).
                .buttonStyle(.plain)
            }
            if let error {
                ErrorText(message: error)
            } else if let confirmation {
                Label(confirmation, systemImage: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.meBlue)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    // MARK: sections

    @ViewBuilder private var content: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading your list")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 24)
        } else {
            let s = sections
            VStack(alignment: .leading, spacing: 10) {
                if let caption = s.listCaption {
                    SectionHead(title: "Your shopping list", caption: caption) { ListGlyph().stroke(Color.shopperTeal, lineWidth: 2) }
                    if let empty = s.listEmpty { EmptyLine(text: empty) }
                    ForEach(s.list) { row(for: $0) }
                }
                if !s.suggestions.isEmpty {
                    SectionHead(title: "Suggested for you", caption: s.suggestionsCaption) { SparkleGlyph().stroke(Color.meBlue, lineWidth: 2) }
                        .padding(.top, s.listCaption == nil ? 0 : 10)
                    ForEach(s.suggestions) { row(for: $0) }
                }
                if !s.usual.isEmpty {
                    SectionHead(title: "Usual picks", caption: "On this phone") {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                    }
                    .padding(.top, s.listCaption == nil ? 0 : 10)
                    ForEach(s.usual) { row(for: $0) }
                }
                if let empty = s.empty { EmptyLine(text: empty) }
            }
        }
    }

    private func row(for row: WishLogic.Row) -> some View {
        WishRow(row: row, busy: busyKey == row.key, disabled: busy) { add(row.name, typed: false) }
    }

    private func add(_ wish: String, typed: Bool) {
        let key = WishLogic.key(wish)
        guard !wish.isEmpty, !key.isEmpty, !busy else { return }
        busyKey = key
        error = nil
        Task {
            let failure = await onWish(wish)
            busyKey = nil
            if let failure {
                error = failure
                confirmation = nil
            } else {
                justWished.insert(key)
                if typed {
                    name = ""
                    confirmation = WishLogic.confirmation(wish)
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

/// One item: name, a pill and a line, and the 44 pt "+" (or the blue check once wished).
private struct WishRow: View {
    let row: WishLogic.Row
    var busy = false
    var disabled = false
    var onAdd: () -> Void = {}

    private static let wishedBorder = Color(hex: 0xC9D6F8)
    private static let suggestedBorder = Color(hex: 0x9FB4EE)
    private var wished: Bool { row.mark == .wished }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Pill(text: row.pill, kind: row.kind)
                    if !row.line.isEmpty {
                        Text(row.line)
                            .font(.system(size: 12, weight: wished ? .bold : .regular))
                            .foregroundStyle(wished ? Color.meBlue : Color.muted)
                            .lineLimit(2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 10))
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(border)
    }

    @ViewBuilder private var trailing: some View {
        if wished {
            Image(systemName: "checkmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: Metrics.tap, height: Metrics.tap)
                .background(Circle().fill(Color.meBlue))
                .accessibilityLabel("Wished")
        } else {
            Button(action: onAdd) {
                Group {
                    if busy { ProgressView().tint(Color.ink) } else { Image(systemName: "plus").font(.system(size: 16, weight: .semibold)) }
                }
                .foregroundStyle(Color.ink)
                .frame(width: Metrics.tap, height: Metrics.tap)
                .background(Circle().fill(Color.card))
                .overlay(Circle().strokeBorder(Color.ink))
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .accessibilityLabel("Wish for \(row.name)")
        }
    }

    private var background: Color {
        if wished { return .meSoft }
        return row.kind == .list ? .card : .paper
    }

    @ViewBuilder private var border: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        if wished {
            shape.strokeBorder(Self.wishedBorder)
        } else if row.kind == .list {
            shape.strokeBorder(Color.line)
        } else {
            shape.strokeBorder(Self.suggestedBorder, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
    }
}

private struct Pill: View {
    let text: String
    let kind: WishLogic.Kind

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .fixedSize()
    }

    private var foreground: Color {
        switch kind {
        case .list: return .shopperTeal
        case .suggested: return Color(hex: 0x1E3FA8)
        case .usual: return .ink
        }
    }

    private var background: Color {
        switch kind {
        case .list: return Color(hex: 0xE3F2EF)
        case .suggested: return Color(hex: 0xDCE5FB)
        case .usual: return Color(hex: 0xECEAE6)
        }
    }
}

private struct SectionHead<Glyph: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        HStack(spacing: 8) {
            glyph().frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 4)
    }
}

private struct EmptyLine: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(Color.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
    }
}

/// The canvas list glyph (24-unit box): a rounded sheet with three lines.
private struct ListGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        var p = Path(roundedRect: CGRect(x: 4 * s, y: 3 * s, width: 16 * s, height: 18 * s), cornerRadius: 3 * s)
        for (y, w) in [(8.0, 8.0), (12, 8), (16, 5)] {
            p.move(to: CGPoint(x: 8 * s, y: y * s))
            p.addLine(to: CGPoint(x: (8 + w) * s, y: y * s))
        }
        return p
    }
}

/// The canvas sparkle glyph (24-unit box): a four-point star and a small one.
private struct SparkleGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func star(_ pts: [(Double, Double)]) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: pts[0].0 * s, y: pts[0].1 * s))
            for pt in pts.dropFirst() { p.addLine(to: CGPoint(x: pt.0 * s, y: pt.1 * s)) }
            p.closeSubpath()
            return p
        }
        var p = star([(12, 3), (13.8, 8.2), (19, 10), (13.8, 11.8), (12, 17), (10.2, 11.8), (5, 10), (10.2, 8.2)])
        p.addPath(star([(19, 16), (19.8, 18.2), (22, 19), (19.8, 19.8), (19, 22), (18.2, 19.8), (16, 19), (18.2, 18.2)]))
        return p
    }
}

#if DEBUG
private enum WishPreview {
    static let picks = WishPicks(
        list: .init(name: "Household essentials", store: "QFC", items: [
            .init(name: "Paper towels", detail: "2 rolls"),
            .init(name: "Dish soap", detail: "1 bottle"),
            .init(name: "Oat milk", detail: ""),
        ]),
        suggestions: [
            .init(name: "Large eggs, 12 ct", reason: "Running low · about 2 days left"),
            .init(name: "Bananas", reason: "You buy these every 6 days"),
            .init(name: "Greek yogurt", reason: "Often in your QFC runs"),
        ]
    )
    static var run: Run {
        var r = PreviewData.run
        r.chips.removeAll { $0.name == "Paper towels" }
        r.chips.append(Chip(id: "w-oat", name: "Oat milk", state: .wish, wishedBy: PreviewData.marcusId, addedAt: 5))
        return r
    }
}

#Preview("Wish, list and suggestions") {
    NavigationStack {
        WishView(run: WishPreview.run, me: PreviewData.marcusId, shopperName: "Jake", loadPicks: { WishPreview.picks })
    }
}

#Preview("Wish, nothing from the server") {
    NavigationStack {
        WishView(run: PreviewData.emptyRun, me: PreviewData.priyaId, shopperName: "Jake",
                 usualPicks: ["Everything bagels", "2% Milk"], onWish: { _ in "Cart closed" })
    }
}
#endif
