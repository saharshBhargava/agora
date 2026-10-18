import SwiftUI

/// "Over your cap. Raise it to $60?" (canvas OverCap.dc.html, web ClaimScreen over-cap dialog). Raising
/// grows the hold by $20 and then claims the chip; "Not now" closes it.
struct OverCapSheet: View {
    let chip: Chip
    let roomCents: Int
    let authorizedCents: Int
    /// The server answered 403: raising is turned off for this run.
    var raiseOff = false
    var busy = false
    var onRaise: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChipThumb(chip: chip, height: 56, width: 56, radius: 14, letterSize: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(ClaimLogic.overCapLine(chip, roomCents: roomCents))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if raiseOff {
                Text(ClaimLogic.raiseOffTitle)
                    .font(.display(26))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ClaimLogic.overCapTitle(authorizedCents: authorizedCents))
                    .font(.display(26))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(ClaimLogic.raiseCopy)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRaise) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Text(ClaimLogic.raiseButton(authorizedCents: authorizedCents))
                    }
                }
                .buttonStyle(.dibs)
                .disabled(busy)
            }
            Button(action: onDismiss) {
                Text("Not now")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Sheet height for the presentation detent.
    var height: CGFloat { raiseOff ? 260 : 400 }
}

#if DEBUG
#Preview("Over cap") {
    Color.paper.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let sheet = OverCapSheet(chip: Chip(id: "coffee", name: "Kirkland Coffee 3 lb", priceCents: 1499),
                                     roomCents: 729, authorizedCents: 4000)
            sheet
                .presentationDetents([.height(sheet.height)])
                .presentationBackground(Color.card)
        }
}

#Preview("Over cap, raise off") {
    Color.paper.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let sheet = OverCapSheet(chip: Chip(id: "coffee", name: "Kirkland Coffee 3 lb", priceCents: 1499),
                                     roomCents: 729, authorizedCents: 4000, raiseOff: true)
            sheet.presentationDetents([.height(sheet.height)])
        }
}
#endif
