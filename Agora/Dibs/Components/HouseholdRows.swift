import SwiftUI

// Rows for the household entries on Home and in Settings, in the run screens' look: tiles, not text rows.

/// A 40 pt rounded tile with an SF Symbol in ink on a soft tile color (Palette.tileHex).
struct DibsSymbolTile: View {
    let symbol: String
    var tint: UInt32 = Palette.tileHex[2]
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(width: size, height: size)
            .background(Color(hex: tint), in: RoundedRectangle(cornerRadius: size / 4, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A tappable line in a card: symbol tile, 15 pt semibold title, 13 pt muted detail, chevron.
struct DibsLinkRow: View {
    let title: String
    let detail: String
    let symbol: String
    var tint: UInt32 = Palette.tileHex[2]

    var body: some View {
        HStack(spacing: 12) {
            DibsSymbolTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DibsChevron()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

/// An item as the cart shows it: a tile in `tileColor(id:)` with the first letter (ChipThumb's look).
struct DibsItemTile: View {
    let id: String
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Text(name.first.map { String($0).uppercased() } ?? "?")
            .font(.display(size * 0.42))
            .foregroundStyle(Color.ink.opacity(0.55))
            .frame(width: size, height: size)
            .background(tileColor(id: id), in: RoundedRectangle(cornerRadius: Metrics.radiusSmall * size / 48, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// One "For your next run" line: item tile, name, the muted reason, and a target price in display type.
struct NextRunRowView: View {
    let row: NextRunRow

    var body: some View {
        HStack(spacing: 12) {
            if let image = row.image {
                ShelfItemTile(kind: image.kind, id: image.id, name: row.name, category: image.category, size: 44)
            } else {
                DibsItemTile(id: row.id, name: row.name)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(1)
                Text(row.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let amount = row.amount {
                Text(amount)
                    .font(.display(17))
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
            }
            DibsChevron()
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct DibsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.muted)
            .accessibilityHidden(true)
    }
}

/// A 1 pt `Color.line` divider between rows in a card.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.line).frame(height: 1)
    }
}

extension View {
    /// The dashed "nothing here yet" box (StartView's "Waiting for your housemates…").
    func dibsDashedBox() -> some View {
        self.padding(Metrics.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }
}
