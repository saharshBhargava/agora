import SwiftUI

/// "Over your cap. Raise it to $60?" (canvas OverCap.dc.html, web ClaimScreen over-cap dialog).
/// `.claim`: raising grows the hold and then claims the chip; "Not now" closes it.
/// `.raiseOnly`: the chip is already mine and a later price put it past my hold; "Raise to $X" only raises
/// (the server clears the over-cap flag), "Leave it" leaves the chip.
struct OverCapSheet: View {
    let chip: Chip
    var mode: ClaimLogic.OverCapMode = .claim
    let roomCents: Int
    let authorizedCents: Int
    /// The hold "Raise" asks for (`ClaimLogic.raiseTarget`).
    let targetCents: Int
    /// The server answered 403: raising is turned off for this run.
    var raiseOff = false
    var busy = false
    var onRaise: () -> Void = {}
    var onDismiss: () -> Void = {}
    /// Raise only: "Leave it".
    var onLeave: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ChipThumb(chip: chip, height: 56, width: 56, radius: 14, letterSize: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(chip.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(mode == .raiseOnly ? ClaimLogic.overHoldLine(chip, roomCents: roomCents)
                                            : ClaimLogic.overCapLine(chip, roomCents: roomCents))
                        .font(.system(size: 14))
                        .foregroundStyle(Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !canRaise {
                Text(ClaimLogic.raiseOffTitle)
                    .font(.display(26))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(ClaimLogic.overCapTitle(targetCents: targetCents))
                    .font(.display(26))
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(ClaimLogic.raiseCopy(growCents: targetCents - authorizedCents))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onRaise) {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Text(mode == .raiseOnly ? ClaimLogic.raiseOnlyButton(targetCents: targetCents)
                                                : ClaimLogic.raiseButton(targetCents: targetCents))
                    }
                }
                .buttonStyle(.dibs)
                .disabled(busy)
            }
            Button(action: mode == .raiseOnly ? onLeave : onDismiss) {
                Text(mode == .raiseOnly ? "Leave it" : "Not now")
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
    var height: CGFloat { canRaise ? 400 : 260 }

    /// Off when the server refused raises, or the hold is already at the most it can be.
    private var canRaise: Bool { !raiseOff && targetCents > authorizedCents }
}

#if DEBUG
#Preview("Over cap") {
    Color.paper.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let sheet = OverCapSheet(chip: Chip(id: "coffee", name: "Kirkland Coffee 3 lb", priceCents: 1499),
                                     roomCents: 729, authorizedCents: 4000, targetCents: 6000)
            sheet
                .presentationDetents([.height(sheet.height)])
                .presentationBackground(Color.card)
        }
}

#Preview("Over cap, already mine") {
    Color.paper.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let sheet = OverCapSheet(chip: Chip(id: "coffee", name: "Kirkland Coffee 3 lb", priceCents: 4500, claimers: ["p"], overCap: ["p"]),
                                     mode: .raiseOnly, roomCents: -500, authorizedCents: 4000, targetCents: 6000)
            sheet.presentationDetents([.height(sheet.height)])
        }
}

#Preview("Over cap, raise off") {
    Color.paper.ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            let sheet = OverCapSheet(chip: Chip(id: "coffee", name: "Kirkland Coffee 3 lb", priceCents: 1499),
                                     roomCents: 729, authorizedCents: 4000, targetCents: 6000, raiseOff: true)
            sheet.presentationDetents([.height(sheet.height)])
        }
}
#endif
