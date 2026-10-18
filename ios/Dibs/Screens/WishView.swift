import SwiftUI

/// "+ Wish" (web WishSheet, as its own screen): type an item, or tap one of the usual picks (the last 20
/// wish and item names this phone has seen). The wish lands on the shelf as a dashed chip.
struct WishView: View {
    /// Usual picks, newest first, minus what is already on the shelf.
    let picks: [String]
    var shopperName: String?
    /// Sends the wish; returns an error message, or nil when it was added.
    var onWish: (String) async -> String? = { _ in nil }

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Wish for something")
                        .font(.display(30))
                        .tracking(-0.5)
                        .foregroundStyle(Color.ink)
                    Text("It lands in your tray when \(shopperName ?? "the shopper") adds it.")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.bodyInk)
                }

                HStack(spacing: Metrics.space1) {
                    TextField("Bagels", text: $name)
                        .font(.system(size: 17))
                        .textInputAutocapitalization(.sentences)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { add(trimmed) }
                        .dibsInput()
                        .accessibilityLabel("Wish")
                    Button { add(trimmed) } label: {
                        if busy { ProgressView().tint(.white) } else { Text("Add") }
                    }
                    .buttonStyle(.dibs(.ink, fontSize: 16))
                    .frame(width: 88)
                    .disabled(busy || trimmed.isEmpty)
                }

                if let error { ErrorText(message: error) }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Usual picks")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    if picks.isEmpty {
                        Text("Items you see in your runs show up here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.muted)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(picks, id: \.self) { pick in
                                Button { add(pick) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                                        Text(pick).lineLimit(1)
                                    }
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(Color.ink)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: Metrics.tap)
                                    .background(Capsule().fill(Color.card))
                                    .overlay(Capsule().strokeBorder(Color.line))
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .accessibilityLabel("Wish for \(pick)")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .dibsScreen()
        .onAppear { focused = true }
    }

    private func add(_ wish: String) {
        guard !wish.isEmpty, !busy else { return }
        busy = true
        error = nil
        Task {
            let failure = await onWish(wish)
            busy = false
            if let failure {
                error = failure
            } else {
                name = ""
                dismiss()
            }
        }
    }
}

/// Lays children out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.init(width: bounds.width, height: nil))
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: .init(width: min(size.width, bounds.width), height: size.height))
                x += min(size.width, bounds.width) + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.init(width: width, height: nil))
            let w = min(size.width, width)
            if !row.items.isEmpty, row.width + spacing + w > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.items.isEmpty ? 0 : spacing) + w
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

#if DEBUG
#Preview("Wish") {
    NavigationStack {
        WishView(picks: ["Everything bagels", "2% Milk", "Kirkland Eggs 24 ct", "Oat milk", "Bananas", "Paper Towels 12 pk"],
                 shopperName: "Jake")
    }
}

#Preview("Wish, no picks yet") {
    NavigationStack {
        WishView(picks: [], shopperName: "Jake") { _ in "Cart closed" }
    }
}
#endif
