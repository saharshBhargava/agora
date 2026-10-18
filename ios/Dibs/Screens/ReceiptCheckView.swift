import SwiftUI

/// Check the receipt and confirm (canvas ReceiptCheck.dc.html, docs/screenshots/v2-12-receipt-check.jpg):
/// one row per receipt line with its matched item and confidence; a line not in the cart is an orange card
/// asking whose it is (Pair with an item / Mine). "Confirm & charge" settles. Claimers see it read-only.
struct ReceiptCheckView: View {
    let run: Run
    /// The shopper fixes lines and confirms; claimers only watch.
    var canFix: Bool
    var busy = false
    var error: String?
    var onFix: (Int, ReceiptTarget) -> Void = { _, _ in }
    var onConfirm: () -> Void = {}

    @State private var pairing: SettleLogic.CheckRow?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Check the receipt")
                            .font(.display(26))
                            .foregroundStyle(Color.ink)
                        if let receipt = run.receipt {
                            Text(SettleLogic.checkSubtitle(receipt))
                                .font(.system(size: 14))
                                .foregroundStyle(Color.muted)
                        }
                    }
                    .padding(.horizontal, 4)

                    VStack(spacing: Metrics.space1) {
                        ForEach(SettleLogic.checkRows(run: run)) { row in
                            if row.needsYou {
                                unmatched(row)
                            } else {
                                matched(row)
                            }
                        }
                    }
                    if let note = SettleLogic.notOnReceipt(run: run) {
                        Text(note)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.muted)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, Metrics.space2)
                .padding(.top, Metrics.space1)
                .padding(.bottom, Metrics.space2)
            }
            footer
        }
    }

    private func matched(_ row: SettleLogic.CheckRow) -> some View {
        HStack(spacing: 10) {
            Thumb(chip: row.chip)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.text)
                    .font(.receipt(12))
                    .foregroundStyle(Color.ink)
                if let sub = row.sub {
                    Text(sub)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.amount)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.ink)
                if let match = row.match {
                    Text(match)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.shopperTeal)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.line))
        .accessibilityElement(children: .combine)
    }

    private func unmatched(_ row: SettleLogic.CheckRow) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.text)
                        .font(.receipt(12))
                        .foregroundStyle(Color.ink)
                    Text(canFix ? "Not in the cart. Whose is it?" : "Unmatched")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x8A2C06))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(row.amount)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.ink)
            }
            .accessibilityElement(children: .combine)
            if canFix {
                HStack(spacing: Metrics.space1) {
                    Button("Pair with an item") { pairing = row }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.ink))
                        .confirmationDialog(
                            "Pair \(row.text) with",
                            isPresented: Binding(get: { pairing?.index == row.index }, set: { if !$0 { pairing = nil } }),
                            titleVisibility: .visible
                        ) {
                            ForEach(SettleLogic.pairable(run: run)) { chip in
                                Button(chip.name) { onFix(row.index, .chip(chip.id)) }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            if SettleLogic.pairable(run: run).isEmpty { Text("Every item is already on the receipt.") }
                        }
                    Button("Mine") { onFix(row.index, .mine) }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(busy)
                .opacity(busy ? 0.5 : 1)
            }
        }
        .padding(12)
        .background(Color(hex: 0xFFF4E5), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.secondPerson, lineWidth: 2))
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let captured = SettleLogic.captured(run: run) {
                HStack {
                    Text(captured.label)
                        .foregroundStyle(Color.muted)
                    Spacer()
                    Text(captured.amount)
                        .fontWeight(.bold)
                        .foregroundStyle(Color.ink)
                }
                .font(.system(size: 14))
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
            }
            if let error { ErrorText(message: error) }
            if canFix {
                Button(busy ? "Charging…" : "Confirm & charge", action: onConfirm)
                    .buttonStyle(.dibs(.ink, fontSize: 16))
                    .disabled(busy)
            } else {
                Text("Waiting for the shopper to confirm.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, minHeight: Metrics.tap)
            }
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.top, Metrics.space1)
        .padding(.bottom, Metrics.space1)
        .background(Color.paper)
    }
}

/// The matched item's photo, or its soft tile color.
private struct Thumb: View {
    let chip: Chip?

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(chip.map { tileColor(id: $0.id) } ?? Color(hex: 0xECEAE6))
            .frame(width: 40, height: 40)
            .overlay {
                if let image = ChipPhoto.image(chip?.photoUrl) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let url = ChipPhoto.remoteURL(chip?.photoUrl) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("Check the receipt") {
    ReceiptCheckView(run: SettlePreview.check, canFix: true)
        .dibsScreen()
}

#Preview("Check, claimer") {
    ReceiptCheckView(run: SettlePreview.check, canFix: false)
        .dibsScreen()
}
#endif
