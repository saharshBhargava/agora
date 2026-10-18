import SwiftUI

/// What a drag carries: a shelf chip's id, or "tray:<id>" for a chip lifted out of the tray.
enum DragPayload {
    static let trayPrefix = "tray:"

    static func shelf(_ chipId: String) -> String { chipId }
    static func tray(_ chipId: String) -> String { trayPrefix + chipId }

    /// The chip id of a chip being dragged out of the tray, or nil.
    static func fromTray(_ payload: String) -> String? {
        payload.hasPrefix(trayPrefix) ? String(payload.dropFirst(trayPrefix.count)) : nil
    }

    /// The chip id of a shelf chip, or nil for a tray payload.
    static func fromShelf(_ payload: String) -> String? {
        payload.hasPrefix(trayPrefix) ? nil : payload
    }
}

/// The dark tray at the bottom of the claim screen (web Tray.tsx, canvas Claim.dc.html). Shelf chips are
/// dropped here to claim; a row leaves by its swipe action or by dragging it out of the tray.
struct Tray: View {
    let chips: [Chip]
    let people: [Person]
    let me: String
    /// A drag is over the tray.
    var targeted = false
    /// "$40.00 held · $4.36 your share · $31.28 room" while a chip is over the tray.
    var previewLine: String?
    var onLeave: (Chip) -> Void = { _ in }

    private static let rowHeight: CGFloat = 64
    private static let rowGap: CGFloat = 8
    private static let visibleRows = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(Color(hex: 0x4A4743))
                .frame(width: 40, height: 4)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                Text("Your tray")
                    .font(.system(size: 16, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(ClaimLogic.traySummary(chips, me: me))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.lineStrong)
            }
            if let previewLine {
                Text(previewLine)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.lineStrong)
            }
            if chips.isEmpty {
                Text("Hold a chip and drop it here to claim it.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.lineStrong)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color(hex: 0x4A4743), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
            } else {
                List {
                    ForEach(chips) { chip in
                        row(chip)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { onLeave(chip) } label: { Text("Leave") }
                            }
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(Self.rowGap)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollDisabled(chips.count <= Self.visibleRows)
                .frame(height: listHeight)
            }
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Color.ink)
                .ignoresSafeArea(edges: .bottom)
        )
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .strokeBorder(Color.meBlue, lineWidth: targeted ? 3 : 0)
                .ignoresSafeArea(edges: .bottom)
        )
        .scaleEffect(targeted ? 1.01 : 1, anchor: .bottom)
        .animation(.easeOut(duration: 0.15), value: targeted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Your tray")
    }

    private var listHeight: CGFloat {
        let n = CGFloat(min(chips.count, Self.visibleRows))
        return n * Self.rowHeight + max(0, n - 1) * Self.rowGap
    }

    private func row(_ chip: Chip) -> some View {
        TrayRow(chip: chip, people: people, me: me)
            .draggable(DragPayload.tray(chip.id)) {
                TrayRow(chip: chip, people: people, me: me).frame(width: 300)
            }
            .accessibilityAction(named: "Leave") { onLeave(chip) }
    }
}

/// One tray row: thumbnail, name, "Split with Marcus", my share.
struct TrayRow: View {
    let chip: Chip
    let people: [Person]
    let me: String

    var body: some View {
        let share = chip.priceCents == nil ? nil : ClaimLogic.myShare(chip, me: me)
        HStack(spacing: 12) {
            ChipThumb(chip: chip, height: 44, width: 44, radius: 10, letterSize: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(chip.name)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Text(ClaimLogic.splitLabel(chip, people: people, me: me))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.lineStrong)
                    .lineLimit(1)
                if chip.overCap.contains(me) {
                    Text("Raise your cap or leave")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: 0xFF8A80))
                }
            }
            Spacer(minLength: 8)
            Text(share.map(Money.format) ?? "~$?")
                .font(.display(20))
                .foregroundStyle(Color.white)
        }
        .padding(10)
        .frame(height: 64)
        .background(Color(hex: 0x1F1D1A), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(share: share))
    }

    private func label(share: Int?) -> String {
        let n = chip.claimers.count
        return "\(chip.name), your share \(share.map(Money.format) ?? "not known yet")\(n > 1 ? ", split \(n) ways" : "")"
    }
}

#if DEBUG
#Preview("Tray") {
    let run = PreviewData.run
    VStack(spacing: 24) {
        Spacer()
        Tray(chips: ClaimLogic.trayChips(run, me: PreviewData.priyaId), people: run.people, me: PreviewData.priyaId)
        Tray(chips: [], people: run.people, me: PreviewData.priyaId, targeted: true)
    }
    .background(Color.paper)
}
#endif
