import SwiftUI

/// One shelf chip (web Chip.tsx, canvas Claim.dc.html): photo tile, name, price and who has it. The border
/// is split evenly among the claimers' colors; a wish has a dashed border in the wisher's color.
struct ChipCard: View {
    let chip: Chip
    let people: [Person]
    let me: String
    /// Shows the wish delete control (my wish, or any wish for the shopper).
    var canDelete = false
    var onDelete: () -> Void = {}

    static let width: CGFloat = 132
    private static let outer: CGFloat = 22
    private static let inner: CGFloat = 19

    var body: some View {
        Group {
            if chip.state == .wish { wish } else { item }
        }
        .frame(width: Self.width)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.label(chip, people: people))
    }

    // MARK: wish

    private var wish: some View {
        let color = Color(hex: ClaimLogic.borderColors(chip, people: people, me: me).first ?? Palette.meHex)
        let wisher = people.first { $0.id == chip.wishedBy }
        return VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 6) {
                if let wisher {
                    Avatar(person: wisher, people: people, me: me, size: .sm, ring: .card)
                } else {
                    Text("?").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.muted)
                }
                Text(ClaimLogic.wishWho(chip, people: people, me: me))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))

            Text(chip.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(ClaimLogic.wishNote(chip, people: people, me: me))
                .font(.system(size: 12))
                .foregroundStyle(Color.muted)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(minHeight: 186, alignment: .top)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Self.outer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.outer, style: .continuous)
                .strokeBorder(color, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        )
        .overlay(alignment: .topTrailing) {
            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.card))
                        .overlay(Circle().strokeBorder(Color.line))
                        .frame(width: Metrics.tap, height: Metrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete wish \(chip.name)")
            }
        }
    }

    // MARK: item

    private var item: some View {
        let identifying = chip.state == .identifying
        let tag = identifying ? nil : ClaimLogic.chipTag(chip, people: people, me: me)
        return VStack(alignment: .leading, spacing: 8) {
            ChipThumb(chip: chip, height: 84, radius: Metrics.radiusSmall, letterSize: 28)
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if chip.quantity > 1 { badge("×\(chip.quantity)", fill: .ink) }
                        if chip.overCap.contains(me) { badge("Over cap", fill: .danger) }
                    }
                    .padding(6)
                }
            Text(chip.name.isEmpty ? "Identifying" : chip.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack {
                Text(identifying ? "…" : ClaimLogic.priceText(chip))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                if let tag {
                    Text(tag.text)
                        .font(.system(size: 12, weight: tag.colorHex == nil ? .regular : .bold))
                        .foregroundStyle(tag.colorHex.map { Color(hex: $0) } ?? Color.muted)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .frame(minHeight: 180, alignment: .top)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Self.inner, style: .continuous))
        .padding(3)
        .background(border, in: RoundedRectangle(cornerRadius: Self.outer, style: .continuous))
        .opacity(identifying ? 0.7 : 1)
    }

    private var border: AnyShapeStyle {
        let colors = ClaimLogic.borderColors(chip, people: people, me: me)
        switch colors.count {
        case 0: return AnyShapeStyle(Color.line)
        case 1: return AnyShapeStyle(Color(hex: colors[0]))
        default:
            // Even conic split starting at the top, hard edges (web chipBorder).
            let step = 1.0 / Double(colors.count)
            var stops: [Gradient.Stop] = []
            for (i, hex) in colors.enumerated() {
                stops.append(.init(color: Color(hex: hex), location: Double(i) * step))
                stops.append(.init(color: Color(hex: hex), location: Double(i + 1) * step))
            }
            return AnyShapeStyle(AngularGradient(gradient: Gradient(stops: stops), center: .center,
                                                 startAngle: .degrees(-90), endAngle: .degrees(270)))
        }
    }

    private func badge(_ text: String, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(fill))
    }

    /// VoiceOver name (web chipLabel).
    static func label(_ chip: Chip, people: [Person]) -> String {
        let initial = { (id: String?) in people.first { $0.id == id }?.initial ?? "?" }
        switch chip.state {
        case .wish: return "Wish: \(chip.name), wished by \(initial(chip.wishedBy))"
        case .identifying: return "\(chip.name.isEmpty ? "Item" : chip.name), identifying"
        default:
            let price = chip.priceCents.map(Money.format) ?? "price not known yet"
            let who = chip.claimers.map { initial($0) }
            let claimed = who.isEmpty ? "not claimed" : "claimed by \(RunText.listNames(who))"
            return "\(chip.name), \(price), \(claimed)"
        }
    }
}

/// A chip's photo (a `data:` crop or a URL) or its tinted tile with the first letter.
struct ChipThumb: View {
    let chip: Chip
    var height: CGFloat = 44
    var width: CGFloat?
    var radius: CGFloat = 10
    var letterSize: CGFloat = 18

    var body: some View {
        ZStack {
            tileColor(id: chip.id)
            if let image = ChipPhoto.image(chip.photoUrl) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let url = ChipPhoto.remoteURL(chip.photoUrl) {
                AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { letter }
            } else {
                letter
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var letter: some View {
        Text(String(chip.name.prefix(1)))
            .font(.display(letterSize))
            .foregroundStyle(Color.ink.opacity(0.55))
    }
}

#if DEBUG
#Preview("Chips") {
    let run = PreviewData.run
    ScrollView(.horizontal) {
        HStack(alignment: .top, spacing: 12) {
            ForEach(ClaimLogic.shelfChips(run)) { chip in
                ChipCard(chip: chip, people: run.people, me: PreviewData.marcusId,
                         canDelete: ClaimLogic.canDeleteWish(chip, me: PreviewData.marcusId, meIsShopper: false))
            }
            ChipCard(chip: Chip(id: "id1", name: "", state: .identifying), people: run.people, me: PreviewData.priyaId)
            ChipCard(chip: Chip(id: "big", name: "Kirkland Coffee 3 lb", priceCents: 1499, quantity: 2, overCap: [PreviewData.priyaId]),
                     people: run.people, me: PreviewData.priyaId)
        }
        .padding()
    }
    .background(Color.paper)
}
#endif
