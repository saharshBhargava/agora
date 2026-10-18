import SwiftUI

/// A compact "− N +" capsule for how many of an item are in the cart (web QuantityStepper). − is
/// disabled at 1 (removing stays the swipe or "Remove from cart"), + at 20; `busy` disables both while a
/// change is on its way. Each button is 44 pt tall to tap, inside a 32 pt capsule.
struct QuantityStepper: View {
    let name: String
    let quantity: Int
    var busy = false
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            button(icon: "minus", label: "One fewer \(name)", delta: -1)
            Text("\(quantity)")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
                .frame(minWidth: 22)
            button(icon: "plus", label: "One more \(name)", delta: 1)
        }
        .frame(height: Metrics.tap)
        .background {
            Capsule().fill(Color.card).frame(height: 32)
                .overlay(Capsule().strokeBorder(Color.lineStrong, lineWidth: 1).frame(height: 32))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("How many \(name)")
        .accessibilityValue("\(quantity)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: change(by: 1)
            case .decrement: change(by: -1)
            @unknown default: break
            }
        }
    }

    private func change(by delta: Int) {
        guard !busy, let next = ShopperLogic.step(quantity, by: delta) else { return }
        onChange(next)
    }

    private func button(icon: String, label: String, delta: Int) -> some View {
        let enabled = !busy && ShopperLogic.step(quantity, by: delta) != nil
        return Button { change(by: delta) } label: {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? Color.ink : Color.lineStrong)
                .frame(width: 30, height: Metrics.tap)
                .contentShape(Rectangle())
        }
        // Borderless: inside a List row it takes its own taps instead of the row's.
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

#if DEBUG
#Preview("Stepper") {
    VStack(spacing: 16) {
        QuantityStepper(name: "Apple", quantity: 1) { _ in }
        QuantityStepper(name: "Apple", quantity: 2) { _ in }
        QuantityStepper(name: "Apple", quantity: 20) { _ in }
        QuantityStepper(name: "Apple", quantity: 3, busy: true) { _ in }
    }
    .padding()
    .background(Color.paper)
}
#endif
