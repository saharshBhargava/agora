import SwiftUI

/// One card per claimer after confirm: avatar, name, captured / released line, the captured amount and
/// approval code; a failed share has an orange border and, for the shopper, "Retry <name>"
/// (canvas Settle.dc.html, Partly.dc.html; web/components/SettleLines.tsx).
struct SettleLines: View {
    let run: Run
    let me: String
    var busy = false
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            ForEach(SettleLogic.cards(run: run, me: me)) { card in
                SettleCard(card: card, person: run.person(card.personId), people: run.people, me: me,
                           busy: busy, onRetry: onRetry)
            }
        }
    }
}

private struct SettleCard: View {
    let card: SettleLogic.Card
    let person: Person?
    let people: [Person]
    let me: String
    let busy: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if let person { Avatar(person: person, people: people, me: me, size: .lg) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.name)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Text(card.sub)
                        .font(.system(size: 13))
                        .foregroundStyle(card.failed ? Color(hex: 0x8A2C06) : Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if card.amount != nil || card.auth != nil {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let amount = card.amount {
                            Text(amount)
                                .font(.display(22))
                                .foregroundStyle(card.muted ? Color.muted : Color.ink)
                                .accessibilityLabel("\(card.failed ? "Share" : "Captured") \(amount)")
                        }
                        if let auth = card.auth {
                            Text(auth)
                                .font(.receipt(11))
                                .foregroundStyle(Color.muted)
                        }
                    }
                }
            }
            if let retry = card.retry {
                Button(retry, action: onRetry)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .disabled(busy)
                    .opacity(busy ? 0.5 : 1)
            }
        }
        .padding(14)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(card.failed ? Color.secondPerson : Color.line, lineWidth: card.failed ? 2 : 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// The settled receipt: mono lines, a dashed rule and TOTAL (canvas Settle.dc.html).
struct ReceiptCard: View {
    let receipt: ReceiptState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Receipt")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                Spacer()
                Text(SettleLogic.matchedLabel(receipt))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.shopperTeal)
            }
            DashedRule()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(SettleLogic.receiptRows(receipt).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.text)
                            Spacer(minLength: 12)
                            Text(row.amount)
                        }
                        if row.mine {
                            Text("Mine")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.muted)
                        }
                    }
                }
                DashedRule().padding(.top, 2)
                HStack {
                    Text("TOTAL")
                    Spacer()
                    Text(SettleLogic.receiptTotal(receipt))
                }
                .fontWeight(.medium)
            }
            .font(.receipt(12))
            .foregroundStyle(Color.bodyInk)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, Metrics.space2)
        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Receipt")
    }
}

/// A 1 pt dashed hairline.
struct DashedRule: View {
    var body: some View {
        Line()
            .stroke(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.width, y: rect.midY))
            return p
        }
    }
}
