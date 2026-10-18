import SwiftUI

/// After lock: the chips nobody claimed (web UnclaimedList). Mine is the default; Put back drops the
/// chip from the run. The footer goes on to the receipt camera or back to the cart.
struct UnclaimedList: View {
    let run: Run
    var busy = false
    let onPutBack: (String) -> Void
    /// "I've paid · snap the receipt". Nil hides the button (no receipt flow on this screen).
    let onPaid: (() -> Void)?
    let onBack: () -> Void

    var body: some View {
        let items = ShopperLogic.unclaimed(run)
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Nobody claimed these")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text(ShopperLogic.unclaimedNote(items))
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 4)

            ForEach(items) { chip in row(chip) }

            VStack(spacing: 4) {
                if let onPaid {
                    Button("I've paid · snap the receipt", action: onPaid)
                        .buttonStyle(.dibs(.ink, fontSize: 16))
                }
                Button(action: onBack) {
                    Text("Back to cart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tap)
                }
                .buttonStyle(.plain)
            }
            .disabled(busy)
            .padding(.top, 6)
        }
    }

    private func row(_ chip: Chip) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CartThumb(chip: chip, size: 48, radius: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ShopperLogic.unclaimedName(chip))
                        .font(.system(size: 16, weight: .bold))
                        .strikethrough(chip.putBack)
                        .foregroundStyle(Color.ink)
                    if chip.putBack {
                        Text("Putting back").font(.system(size: 14)).foregroundStyle(Color.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(ShopperLogic.unclaimedPrice(chip))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
            }
            if !chip.putBack {
                HStack(spacing: 8) {
                    Text("Mine")
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityAddTraits([.isButton, .isSelected])
                    Button { onPutBack(chip.id) } label: {
                        Text("Put back")
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lineStrong))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                }
                .font(.system(size: 15, weight: .bold))
            }
        }
        .padding(12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.line))
        .opacity(chip.putBack ? 0.6 : 1)
    }
}

#if DEBUG
#Preview("Unclaimed") {
    var run = PreviewData.run
    run.state = .locked
    run.chips = run.chips.map { c in
        var c = c
        if c.state != .wish { c.state = .locked }
        return c
    } + [Chip(id: "chicken", name: "Rotisserie chicken", priceCents: 499, state: .locked, putBack: true)]
    return ScrollView {
        UnclaimedList(run: run, onPutBack: { _ in }, onPaid: {}, onBack: {}).padding(16)
    }
    .background(Color.paper)
}
#endif
