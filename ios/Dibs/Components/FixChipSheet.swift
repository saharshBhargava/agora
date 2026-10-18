import SwiftUI

/// Name and price a chip (web FixChipSheet). Empty fields are left alone; only changes are sent.
struct FixChipSheet: View {
    let chip: Chip
    /// Called with the changed fields (both nil: nothing changed).
    let onSave: (_ name: String?, _ priceCents: Int?) -> Void
    let onCancel: () -> Void
    /// Start in the price field ("Add price" on a row with no price found).
    var focusPrice = false
    /// "Remove from cart" at the bottom (shopper, while the cart takes changes); nil hides it.
    var onRemove: (() -> Void)?

    @State private var name: String
    @State private var price: String
    @FocusState private var focus: Field?

    private enum Field { case name, price }

    init(chip: Chip, focusPrice: Bool = false, onSave: @escaping (_ name: String?, _ priceCents: Int?) -> Void,
         onCancel: @escaping () -> Void, onRemove: (() -> Void)? = nil) {
        self.chip = chip
        self.focusPrice = focusPrice
        self.onRemove = onRemove
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: chip.name)
        _price = State(initialValue: ShopperLogic.priceField(chip))
    }

    private var result: ShopperLogic.Fix { ShopperLogic.fix(chip, name: name, price: price) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fix this item")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.ink)
            field("Name") {
                TextField("", text: $name, prompt: Text("What is it?").foregroundStyle(Color.muted))
                    .focused($focus, equals: .name)
                    .submitLabel(.next)
                    .onSubmit { focus = .price }
            }
            field("Price") {
                TextField("", text: $price, prompt: Text("0.00").foregroundStyle(Color.muted))
                    .keyboardType(.decimalPad)
                    .focused($focus, equals: .price)
            }
            if result == .badPrice {
                ErrorText(message: "Enter a price like 4.29")
            }
            Button("Save") {
                if case let .save(n, c) = result { onSave(n, c) }
            }
            .buttonStyle(.dibs)
            .disabled(result == .badPrice)
            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: Metrics.tap)
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label(ShopperLogic.removeButtonTitle, systemImage: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.danger)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tap)
                        .background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.paper)
        .onAppear { focus = focusPrice ? .price : .name }
    }

    private func field(_ label: String, @ViewBuilder input: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
            input()
                .font(.system(size: 16))
                .foregroundStyle(Color.ink)
                .tint(Color.meBlue)
                .dibsInput()
        }
    }
}

#if DEBUG
#Preview("Fix sheet") {
    Color.cameraDark.sheet(isPresented: .constant(true)) {
        FixChipSheet(chip: Chip(id: "t", name: "Paper Towels 12 pk", priceCents: 2399), onSave: { _, _ in }, onCancel: {})
            .presentationDetents([.height(430)])
            .presentationBackground(Color.paper)
    }
}
#endif
