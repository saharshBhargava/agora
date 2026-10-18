import SwiftUI
import UIKit

/// One cart line for the shopper (web CartRowView): thumb, name, who is in, price. Unclaimed lines
/// are dashed; wishes are dashed in the wisher's color with their avatar.
struct CartRowView: View {
    let chip: Chip
    let people: [Person]
    let me: String
    /// The price worker's status for this item ("Checking qfc.com…"), nil when it isn't checking it.
    var checking: String?

    var body: some View {
        let wish = chip.state == .wish
        let wisher = people.first { $0.id == chip.wishedBy }
        let wishColor = wisher.map { ringColor(people: people, id: $0.id, me: me) } ?? Color.meBlue
        let claimers = chip.claimers.compactMap { id in people.first { $0.id == id } }
        let open = !wish && chip.state != .identifying && claimers.isEmpty
        let background: Color = wish ? Color.card.mix(wishColor, 0.08) : .card

        HStack(spacing: 12) {
            if wish, let wisher {
                Avatar(person: wisher, people: people, me: me, size: .md, ring: background)
            } else {
                CartThumb(chip: chip, size: 40, radius: 10)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.name.isEmpty ? "Identifying" : chip.name)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                switch ShopperLogic.subline(chip, people: people, checking: checking) {
                case .wish(let text, _):
                    Text(text).font(.system(size: 13, weight: .medium)).foregroundStyle(wishColor)
                case .muted(let text):
                    Text(text).font(.system(size: 13)).foregroundStyle(Color.muted)
                case nil:
                    EmptyView()
                }
                if chip.quantity > 1 {
                    Text("×\(chip.quantity)").font(.system(size: 13)).foregroundStyle(Color.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !claimers.isEmpty {
                AvatarStack(list: claimers, people: people, me: me, size: .xs, ring: background)
            }
            Text(ShopperLogic.price(chip))
                .font(wish ? .system(size: 13) : .system(size: 16, weight: .semibold))
                .foregroundStyle(wish ? Color.muted : Color.ink)
                .monospacedDigit()
                .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 60)
        .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            if wish {
                shape.strokeBorder(wishColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            } else if open {
                shape.strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            } else {
                shape.strokeBorder(Color.line, lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(chip, people: people))
    }

    /// Same wording as the web `chipLabel`.
    static func label(_ chip: Chip, people: [Person]) -> String {
        let initial = { (id: String) in people.first { $0.id == id }?.initial ?? "?" }
        if chip.state == .wish { return "Wish: \(chip.name), wished by \(initial(chip.wishedBy ?? ""))" }
        if chip.state == .identifying { return "\(chip.name.isEmpty ? "Item" : chip.name), identifying" }
        let price = chip.priceCents.map(Money.format) ?? "price not known yet"
        let who = chip.claimers.map(initial)
        return "\(chip.name), \(price), \(who.isEmpty ? "not claimed" : "claimed by \(RunText.listNames(who))")"
    }
}

/// Product photo (the server's crop) or the first letter on a soft tile.
struct CartThumb: View {
    let chip: Chip
    var size: CGFloat = 40
    var radius: CGFloat = 10

    var body: some View {
        ZStack {
            tileColor(id: chip.id)
            if let image = CartPhotoCache.image(chipId: chip.id, photoUrl: chip.photoUrl) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = ChipPhoto.remoteURL(chip.photoUrl) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { letter }
            } else {
                letter
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var letter: some View {
        Text(chip.name.first.map { String($0).uppercased() } ?? "?")
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(Color.ink)
    }
}

/// Decoded data-URL photos, so rows don't decode base64 on every redraw.
@MainActor
enum CartPhotoCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(chipId: String, photoUrl: String?) -> UIImage? {
        guard let photoUrl, photoUrl.hasPrefix("data:") else { return nil }
        let key = "\(chipId):\(photoUrl.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = ChipPhoto.image(photoUrl) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

extension Color {
    /// This color mixed toward `other` by `amount` (0...1), in sRGB.
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return Color(.sRGB, red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t),
                     blue: Double(b1 + (b2 - b1) * t), opacity: Double(a1 + (a2 - a1) * t))
    }
}

#if DEBUG
#Preview("Cart rows") {
    let run = PreviewData.run
    VStack(spacing: 8) {
        ForEach(ShopperLogic.rows(run.chips)) { CartRowView(chip: $0, people: run.people, me: run.shopperId) }
        CartRowView(chip: Chip(id: "x", name: "Bagels"), people: run.people, me: run.shopperId,
                    checking: "Checking qfc.com…")
    }
    .padding()
    .background(Color.paper)
}
#endif
