import SwiftUI

// MARK: - Pieces shared by the household pages (pantry forms, shopping lists and trips, price watches)
//
// They follow the Dibs run screens: a heavy display headline with one line of context, items as soft
// tiles (ChipCard / CartRowView), white hairline cards, dibsInput fields, dashed "nothing yet" boxes and
// one full-width ink action pinned to the bottom.

extension View {
    /// Secondary copy: 13 pt, muted.
    func shelfNote() -> some View {
        font(.system(size: 13)).foregroundStyle(Color.muted)
    }

    /// Body copy: 15 pt, body ink.
    func shelfBody() -> some View {
        font(.system(size: 15)).foregroundStyle(Color.bodyInk)
    }

    /// An item name: 16 pt bold ink.
    func shelfName() -> some View {
        font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
    }

    /// The pinned action bar at the bottom of a page.
    func shelfPinned() -> some View {
        padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space1)
            .background(Color.paper)
    }
}

/// A page on paper: a scrolling column of cards with an optional pinned action, as in Dibs' Start screen.
/// The hero (a `ShelfHero`) is the first thing in `content`; the navigation bar only carries Back and icons.
struct ShelfPage<Content: View, Bottom: View>: View {
    private let content: Content
    private let bottom: Bottom
    private let showsBottom: Bool

    init(bottomVisible: Bool = true, @ViewBuilder content: () -> Content, @ViewBuilder bottom: () -> Bottom) {
        self.content = content()
        self.bottom = bottom()
        self.showsBottom = bottomVisible
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, Metrics.space1)
                .padding(.bottom, Metrics.space3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            if showsBottom { bottom.shelfPinned() }
        }
        .dibsScreen()
        .toolbar(.visible, for: .navigationBar)
        .tint(Color.ink)
    }
}

extension ShelfPage where Bottom == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(bottomVisible: false, content: content, bottom: { EmptyView() })
    }
}

/// The page headline: display type, then one line of context.
struct ShelfHero: View {
    let title: String
    var size: CGFloat = 32
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.display(size))
                .tracking(-0.5)
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section title above a group of cards: 17 pt bold ink.
struct ShelfSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title)
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A rounded tile in the item's soft tint with its first letter, as on ChipCard and CartRowView.
/// `checked` turns it into an ink tile with a check (a ticked list line).
struct ShelfTile: View {
    let seed: String
    let label: String
    var size: CGFloat = 44
    var checked: Bool?

    var body: some View {
        ZStack {
            if checked == true {
                Color.ink
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(Color.white)
            } else {
                tileColor(id: seed)
                Text(label.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Color.ink)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// An item's tile with its photo: the household or product image the image service found for it (the team's
/// `ItemImageStore`, from the environment), shown in the same rounded square; until one loads, or when there is
/// none, the plain `ShelfTile` letter tile. `kind` is the image service's item kind ("inventory", "list",
/// "wishlist").
struct ShelfItemTile: View {
    let kind: String
    let id: UUID
    let name: String
    var category: String? = nil
    var size: CGFloat = 44
    var checked: Bool? = nil
    @Environment(\.itemImages) private var images

    var body: some View {
        if checked != true, let images {
            ShelfPhotoTile(store: images, ref: ItemImageReference(kind: kind, id: id, name: name, category: category), size: size)
        } else {
            ShelfTile(seed: id.uuidString, label: name, size: size, checked: checked)
        }
    }
}

private struct ShelfPhotoTile: View {
    @ObservedObject var store: ItemImageStore
    let ref: ItemImageReference
    let size: CGFloat
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Group {
            if let asset = store.descriptors[ref]?.displayAsset, let image = store.pictures[asset.id] {
                ZStack {
                    Color.white
                    Image(uiImage: image).resizable().scaledToFit().padding(size * 0.06)
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).stroke(Color.line, lineWidth: 1))
                .accessibilityHidden(true)
            } else {
                ShelfTile(seed: ref.id.uuidString, label: ref.name, size: size)
            }
        }
        .task(id: "\(ref)-\(store.context)-\(store.revision)-\(phase == .active)") {
            if phase == .active { await store.observe(ref) }
        }
    }
}

/// A small fact in a capsule: outlined, ink, muted or danger.
struct ShelfPill: View {
    enum Style { case line, ink, muted, danger }
    let text: String
    var symbol: String?
    var style: Style = .line

    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .bold)) }
            Text(text).font(.system(size: 12, weight: .bold)).fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(border))
    }

    private var foreground: Color {
        switch style {
        case .line: return .ink
        case .ink: return .white
        case .muted: return .muted
        case .danger: return .danger
        }
    }
    private var fill: Color {
        switch style {
        case .line: return .card
        case .ink: return .ink
        case .muted: return .paper
        case .danger: return .dangerSoft
        }
    }
    private var border: Color {
        switch style {
        case .line, .muted: return .line
        case .ink: return .ink
        case .danger: return .dangerSoft
        }
    }
}

/// A dashed "nothing here yet" box, like Start's "Waiting for your housemates…".
struct ShelfEmpty: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(Color.muted)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.space3)
        .padding(.horizontal, Metrics.space2)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .combine)
    }
}

/// A message above the content: an error on a soft red card, or a notice on a white one.
struct ShelfBanner: View {
    enum Kind { case error, notice }
    let message: String
    var kind: Kind = .notice

    var body: some View {
        Group {
            switch kind {
            case .error:
                ErrorText(message: message)
                    .padding(12)
                    .background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            case .notice:
                Text(message)
                    .shelfBody()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dibsCard(radius: 14, padding: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A divider inside a card.
struct ShelfDivider: View {
    var body: some View { Rectangle().fill(Color.line).frame(height: 1) }
}

/// Label and value rows inside a card, split by hairlines: ink title, muted value.
struct ShelfFacts: View {
    let rows: [(title: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { ShelfDivider() }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(rows[index].title).font(.system(size: 15)).foregroundStyle(Color.ink)
                    Spacer(minLength: 12)
                    Text(rows[index].value)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.muted)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A labelled `dibsInput` field.
struct ShelfField<Content: View>: View {
    let label: String
    var note: String?
    /// Taller padding for a multi-line text field (notes).
    var multiline = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
            content
                .font(.system(size: 16))
                .foregroundStyle(Color.ink)
                .accessibilityLabel(label)
                .padding(.vertical, multiline ? 12 : 0)
                .dibsInput()
            if let note { Text(note).shelfNote().fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A labelled field that opens a chooser (a store, a saved list) when tapped.
struct ShelfPickerButton: View {
    let label: String
    let value: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
            Button(action: action) {
                HStack {
                    Text(value).font(.system(size: 16)).foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.muted)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dibsInput()
            .accessibilityLabel("\(label), \(value)")
        }
    }
}

/// A labelled field holding a menu `Picker`.
struct ShelfMenu<Value: Hashable, Options: View>: View {
    let label: String
    @Binding var selection: Value
    @ViewBuilder let options: Options

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
            HStack(spacing: 0) {
                Picker(label, selection: $selection) { options }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(Color.ink)
                    .padding(.leading, -8)
                Spacer(minLength: 0)
            }
            .dibsInput()
        }
    }
}

/// Two or three exclusive choices as capsule buttons: ink when chosen.
struct ShelfChoice<Value: Hashable>: View {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 13)).foregroundStyle(Color.muted)
            HStack(spacing: Metrics.space1) {
                ForEach(options.indices, id: \.self) { index in
                    let option = options[index], chosen = option.value == selection
                    Button { selection = option.value } label: {
                        Text(option.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(chosen ? Color.white : Color.ink)
                            .frame(maxWidth: .infinity, minHeight: Metrics.tap)
                            .background(chosen ? Color.ink : Color.card,
                                        in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous)
                                .strokeBorder(chosen ? Color.ink : Color.lineStrong))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
        }
    }
}

/// Pills that wrap onto new lines.
struct ShelfFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Pantry forms

struct InventoryEditor: View {
    @ObservedObject var store: InventoryStore
    let original: InventoryItem?
    @State private var draft: InventoryDraft
    @State private var saving = false
    @State private var error: String?
    @State private var choosingMerchant = false
    @State private var merchantLabel: String?
    @State private var uncertainSave = false
    @Environment(\.dismiss) private var dismiss

    init(store: InventoryStore, original: InventoryItem?) {
        self.store = store; self.original = original
        _draft = State(initialValue: InventoryDraft(item: original))
    }
    private var valid: Bool {
        guard let householdID = store.householdID else { return false }
        return (try? draft.body(householdID: householdID, editing: original)) != nil
    }
    var body: some View {
        NavigationStack {
            ShelfPage {
                ShelfHero(title: original == nil ? "Add to your pantry" : "Edit item", size: 30,
                          subtitle: original == nil
                            ? "Track what you keep at home, and set a restock level to know when it runs low."
                            : original?.displayName)

                VStack(alignment: .leading, spacing: 14) {
                    ShelfField(label: "Name") {
                        TextField("Oat milk", text: $draft.name).accessibilityIdentifier("inventory.name")
                    }
                    if original == nil {
                        ShelfField(label: "Category (optional)") {
                            TextField("Dairy", text: $draft.category)
                        }
                        HStack(alignment: .top, spacing: Metrics.space1) {
                            ShelfField(label: "Unit") { TextField("cartons", text: $draft.unit) }
                            ShelfField(label: "Quantity") {
                                TextField("Unknown", text: $draft.quantity).keyboardType(.decimalPad)
                                    .accessibilityIdentifier("inventory.quantity")
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    ShelfSectionTitle("Tracking")
                    ShelfMenu(label: "Location", selection: $draft.locationID) {
                        Text("No location").tag(UUID?.none)
                        ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    ShelfField(label: "Restock below",
                               note: "An empty restock level turns off low-stock tracking. Quantities use \(draft.unit).") {
                        TextField("Not set", text: $draft.restockLevel).keyboardType(.decimalPad)
                            .accessibilityIdentifier("inventory.restockLevel")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    ShelfSectionTitle("Preferred store")
                    ShelfPickerButton(label: "Store",
                                      value: merchantLabel ?? (draft.merchantID == nil ? "None" : "Choose store")) {
                        choosingMerchant = true
                    }
                    if draft.merchantID != nil {
                        Button("Clear preferred store", role: .destructive) { draft.merchantID = nil; merchantLabel = nil }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.danger)
                            .frame(minHeight: Metrics.tap)
                    }
                }

                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button(saving ? "Saving…" : "Save") { save() }
                    .buttonStyle(.dibs)
                    .disabled(!valid || saving || uncertainSave)
                    .accessibilityIdentifier("inventory.save")
            }
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $choosingMerchant) {
                InventoryMerchantPicker(store: store) { merchant in
                    draft.merchantID = merchant.id; merchantLabel = merchant.label
                }
            }
            .task {
                if let id = draft.merchantID { merchantLabel = try? await store.merchant(id).label }
            }
        }
    }
    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { _ = try await store.save(draft, original: original); dismiss() }
            catch is CancellationError { dismiss() }
            catch {
                if original == nil, let failure = error as? BrowserError,
                   failure.code == "connection_failed" || (failure.status ?? 0) >= 500 {
                    uncertainSave = true
                    self.error = "Couldn’t confirm whether this item was saved. Close this form and refresh Inventory before adding it again."
                    await store.refresh()
                } else { self.error = InventoryStore.message(error) }
            }
        }
    }
}

struct InventoryQuantityEditor: View {
    @ObservedObject var store: InventoryStore
    let item: InventoryItem
    @State private var quantity: String
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: InventoryStore, item: InventoryItem) {
        self.store = store; self.item = item
        _quantity = State(initialValue: item.quantity.map { String($0) } ?? "")
    }
    var body: some View {
        NavigationStack {
            ShelfPage {
                ShelfHero(title: "Update quantity", size: 30,
                          subtitle: "Enter the total amount you have now. This records a new observation and keeps the previous history.")

                HStack(spacing: 12) {
                    ShelfTile(seed: item.id.uuidString, label: item.displayName, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName).shelfName()
                        Text(item.unit).shelfNote()
                    }
                    Spacer(minLength: 0)
                }
                .dibsCard(radius: 14, padding: 12)
                .accessibilityElement(children: .combine)

                ShelfField(label: "Quantity in \(item.unit)") {
                    TextField("0", text: $quantity).keyboardType(.decimalPad)
                        .font(.display(30))
                        .accessibilityIdentifier("inventory.quantity")
                }

                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            let value = try InventoryDraft.number(quantity, required: true)!
                            try await store.updateQuantity(item, quantity: value)
                            dismiss()
                        } catch is CancellationError { dismiss() }
                        catch { self.error = InventoryStore.message(error) }
                    }
                }
                .buttonStyle(.dibs)
                .disabled(saving || (try? InventoryDraft.number(quantity, required: true)) == nil)
                .accessibilityIdentifier("inventory.save")
            }
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct InventoryLocationsView: View {
    @ObservedObject var store: InventoryStore
    @State private var name = ""
    @State private var kind = "pantry"
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ShelfPage {
                ShelfHero(title: "Storage locations", size: 30,
                          subtitle: store.household?.name ?? "Where you keep things at home.")

                if store.locations.isEmpty {
                    ShelfEmpty(symbol: "refrigerator", title: "No locations yet",
                               message: "Add the places you keep food and supplies, like the fridge or the pantry.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.locations.enumerated()), id: \.element.id) { index, location in
                            if index > 0 { ShelfDivider() }
                            HStack(spacing: 12) {
                                ShelfTile(seed: location.id.uuidString, label: location.name, size: 40)
                                Text(location.name).shelfName()
                                Spacer(minLength: 8)
                                ShelfPill(text: location.kind.capitalized)
                            }
                            .padding(.vertical, 10)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .dibsCard(padding: 12)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ShelfSectionTitle("Add location")
                    ShelfField(label: "Name") { TextField("Garage freezer", text: $name) }
                    ShelfMenu(label: "Type", selection: $kind) {
                        ForEach(["fridge", "freezer", "pantry", "bathroom", "other"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                }
                .disabled(saving)

                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button(saving ? "Adding…" : "Add location") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            _ = try await store.addLocation(name: cleanName, kind: kind)
                            name = ""
                        } catch { self.error = InventoryStore.message(error) }
                    }
                }
                .buttonStyle(.dibs)
                .disabled(saving || cleanName.isEmpty || name.count > 40)
            }
            .toolbar { Button("Done") { dismiss() }.disabled(saving) }
            .interactiveDismissDisabled(saving)
        }
    }
}

struct InventoryMerchantPicker: View {
    @ObservedObject var store: InventoryStore
    var title = "Preferred store"
    let selected: (InventoryMerchant) -> Void
    @State private var search = ""
    @State private var locality = ""
    @State private var merchants: [InventoryMerchant] = []
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var name: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            ShelfPage(bottomVisible: !name.isEmpty) {
                ShelfHero(title: title, size: 30, subtitle: "Search for a store or enter a name to add one.")

                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.muted)
                        .accessibilityHidden(true)
                    TextField("Store name", text: $search)
                        .font(.system(size: 16))
                        .foregroundStyle(Color.ink)
                        .submitLabel(.search)
                }
                .dibsInput()

                if loading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finding stores…").font(.system(size: 14)).foregroundStyle(Color.muted)
                    }
                }

                if !merchants.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(merchants.enumerated()), id: \.element.id) { index, merchant in
                            if index > 0 { ShelfDivider() }
                            Button { selected(merchant); dismiss() } label: {
                                HStack(spacing: 12) {
                                    ShelfTile(seed: merchant.id.uuidString, label: merchant.name, size: 40)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(merchant.name).shelfName()
                                        if let locality = merchant.locality { Text(locality).shelfNote() }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.vertical, 8)
                                .frame(minHeight: Metrics.tap)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(merchant.label)
                        }
                    }
                    .dibsCard(padding: 12)
                }

                if !name.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ShelfSectionTitle("Add a store")
                        ShelfField(label: "Neighborhood or branch (optional)") {
                            TextField("Ballard", text: $locality)
                        }
                    }
                } else if merchants.isEmpty && !loading {
                    ShelfEmpty(symbol: "storefront", title: "Find a store",
                               message: "Search for a store or enter a name to add one.")
                }
                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button("Add “\(name)”") {
                    saving = true; error = nil
                    Task {
                        defer { saving = false }
                        do {
                            let merchant = try await store.addMerchant(name: name, locality: locality.trimmingCharacters(in: .whitespacesAndNewlines))
                            selected(merchant); dismiss()
                        } catch { self.error = InventoryStore.message(error) }
                    }
                }
                .buttonStyle(.dibs)
                .disabled(name.count > 80 || locality.count > 80)
            }
            .disabled(saving)
            .toolbar { Button("Cancel") { dismiss() }.disabled(saving) }
            .interactiveDismissDisabled(saving)
            .task(id: search) {
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    let result = try await store.merchants(search: String(name.prefix(80)))
                    try Task.checkCancellation()
                    merchants = result; error = nil; loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = InventoryStore.message(error); loading = false
                }
            }
        }
    }
}
