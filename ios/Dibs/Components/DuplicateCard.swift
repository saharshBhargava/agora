import SwiftUI

/// "Added twice?" for a chip the server flagged with `duplicateOf` (web .dupe card).
struct DuplicateCard: View {
    let chip: Chip
    let onKeep: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CartThumb(chip: chip, size: 40, radius: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Added twice?")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(ShopperLogic.duplicateLine(chip))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Button(action: onKeep) {
                    Text("Keep both")
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.ink))
                }
                Button(action: onRemove) {
                    Text("Remove one")
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
