import SwiftUI

/// "Added twice?" for a chip the server flagged with `duplicateOf` (web .dupe card), and "Counted twice?"
/// for a chip the camera counted again, whose second button takes the count back.
struct DuplicateCard: View {
    let chip: Chip
    var title = "Added twice?"
    var line: String?
    var keepTitle = "Keep both"
    var removeTitle = "Remove one"
    let onKeep: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CartThumb(chip: chip, size: 40, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(line ?? ShopperLogic.duplicateLine(chip))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(action: onKeep) {
                    Text(keepTitle)
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.ink))
                }
                Button(action: onRemove) {
                    Text(removeTitle)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .font(.system(size: 15, weight: .bold))
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.meBlue, lineWidth: 2))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(chip.name) may be a duplicate")
    }
}

#if DEBUG
#Preview("Duplicate") {
    DuplicateCard(chip: Chip(id: "eggs2", name: "Kirkland Eggs 24 ct", priceCents: 872, duplicateOf: "eggs"), onKeep: {}, onRemove: {})
        .padding()
        .background(Color.paper)
}
#endif
