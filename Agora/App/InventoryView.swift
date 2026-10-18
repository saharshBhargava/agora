import SwiftUI
import Charts

/// The pantry: what the household has at home. Pushed from the Dibs home inside the root stack.
///
/// It reads like a Dibs run screen: a display headline with one line of context, the items as tiles in
/// white hairline cards (ChipCard / CartRowView), location filters as capsules, and one full-width ink
/// action pinned to the bottom.
struct InventoryListView: View {
    @ObservedObject var store: InventoryStore
    /// "Scan items": opens Capture, which recognizes items into the pantry. Hidden when nil.
    var onScan: (() -> Void)?
    @State private var search = ""
    @State private var locationID: UUID?
    @State private var showArchived = false
    @State private var adding = false
    @State private var managingLocations = false

    private var visibleItems: [InventoryItem] {
        store.items.filter {
            $0.status == (showArchived ? "archived" : "active") &&
            (locationID == nil || $0.locationId == locationID) &&
            (search.isEmpty || $0.displayName.localizedStandardContains(search) || ($0.category?.localizedStandardContains(search) ?? false))
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Out of stock or under its restock level.
    private func needsRestock(_ item: InventoryItem) -> Bool {
        item.status == "active" && (item.quantity == 0 || item.isRunningLow)
    }

    private var summary: String {
        let active = store.items.filter { $0.status == "active" }
        guard !active.isEmpty else { return "Track what you keep at home, so you know what to pick up on your next run." }
        let low = active.filter(needsRestock).count
        let things = "\(active.count) \(active.count == 1 ? "thing" : "things") at home"
        return low == 0 ? "\(things), nothing running low." : "\(things), \(low) running low."
    }

    var body: some View {
        HousePage {
            HouseHero(title: "What's at home", subtitle: summary)

            if store.households.count > 1 {
                HouseMenu(label: "Household", selection: Binding(get: { store.householdID }, set: { id in
                    if let id { Task { await store.selectHousehold(id) } }
                })) {
                    ForEach(store.households) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            if let error = store.error {
                VStack(alignment: .leading, spacing: 10) {
                    HouseBanner(message: error, kind: .error)
                    Button("Try again") { Task { await store.refresh() } }
                        .buttonStyle(.dibs(.secondary, fontSize: 16))
                        .disabled(store.loading)
                }
            }

            filters
            content
        } bottom: {
            if let onScan {
                Button(action: onScan) { Label("Scan items", systemImage: "camera.viewfinder") }
                    .buttonStyle(.dibs)
                    .disabled(store.householdID == nil)
                    .accessibilityIdentifier("inventory.scan")
            } else {
                Button { adding = true } label: { Label("Add item", systemImage: "plus") }
                    .buttonStyle(.dibs)
                    .disabled(store.householdID == nil)
                    .accessibilityIdentifier("inventory.add")
            }
        }
        .toolbar {
            if onScan != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Label("Add item", systemImage: "plus") }
                        .disabled(store.householdID == nil)
                        .accessibilityIdentifier("inventory.add")
                }
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $adding) { InventoryEditor(store: store, original: nil) }
        .sheet(isPresented: $managingLocations) { InventoryLocationsView(store: store) }
        .id(store.context)
        .onChange(of: store.context) { _, _ in locationID = nil; adding = false; managingLocations = false }
    }

    // MARK: search and filters

    @ViewBuilder private var filters: some View {
        if !store.items.isEmpty || !search.isEmpty {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.muted)
                    .accessibilityHidden(true)
                TextField("Search inventory", text: $search)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(Color.muted)
                            .frame(width: Metrics.tap, height: Metrics.tap)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                    .padding(.trailing, -12)
                }
            }
            .dibsInput()
        }

        if store.householdID != nil {
            HouseFlow(spacing: 8) {
                HouseChip(title: "All locations", selected: locationID == nil) { locationID = nil }
                ForEach(store.locations) { location in
                    HouseChip(title: location.name, selected: locationID == location.id) { locationID = location.id }
                }
                HouseChip(title: "Locations", symbol: "square.grid.2x2", selected: false, quiet: true) { managingLocations = true }
            }
        }

        if !store.items.isEmpty {
            Toggle("Show archived items", isOn: $showArchived)
                .font(.system(size: 15))
                .foregroundStyle(Color.ink)
                .tint(Color.ink)
                .frame(minHeight: Metrics.tap)
        }
    }

    // MARK: items

    @ViewBuilder private var content: some View {
        if store.loading && store.items.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading inventory…").font(.system(size: 14)).foregroundStyle(Color.muted)
            }
            .accessibilityElement(children: .combine)
        } else if visibleItems.isEmpty && store.error == nil {
            VStack(spacing: 12) {
                HouseEmpty(symbol: "shippingbox", title: showArchived ? "No archived items" : "No items found",
                           message: search.isEmpty && locationID == nil ? "Add an item to start tracking your essentials." : "Try another search or location.")
                if !showArchived {
                    Button("Add item") { adding = true }
                        .buttonStyle(.dibs(.secondary, fontSize: 16))
                        .disabled(store.householdID == nil)
                }
            }
        } else {
            let low = showArchived ? [] : visibleItems.filter(needsRestock)
            let rest = showArchived ? visibleItems : visibleItems.filter { !needsRestock($0) }
            if !low.isEmpty { section("Running low · \(low.count)", items: low) }
            if !rest.isEmpty {
                section(showArchived ? "Archived · \(rest.count)" : low.isEmpty ? "At home · \(rest.count)" : "In stock · \(rest.count)", items: rest)
            }
        }
    }

    private func section(_ title: String, items: [InventoryItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle(title)
            ForEach(items) { item in
                let location = store.locations.first { $0.id == item.locationId }?.name
                NavigationLink {
                    InventoryDetailView(store: store, itemID: item.id)
                } label: {
                    InventoryRowView(item: item, location: location)
                        .dibsCard(radius: 14, padding: 12)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(InventoryRowView.label(item: item, location: location))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("inventory.item.\(item.id)")
            }
        }
    }
}

/// One pantry line: tile, name, where it lives and its stock state, the quantity in display type.
private struct InventoryRowView: View {
    let item: InventoryItem
    let location: String?

    var body: some View {
        HStack(spacing: 12) {
            HouseTile(seed: item.id.uuidString, label: item.displayName, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).houseName().lineLimit(2)
                if let location { Text(location).houseNote().lineLimit(1) }
                if let state = Self.state(item) { HousePill(text: state.text, style: state.style) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(item.quantity.map { $0.formatted() } ?? "–")
                    .font(.display(22))
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(item.quantity == nil ? "unknown" : item.unit).houseNote().lineLimit(1)
            }
        }
    }

    static func state(_ item: InventoryItem) -> (text: String, style: HousePill.Style)? {
        if item.status == "archived" { return ("Archived", .muted) }
        if item.quantity == 0 { return ("Out of stock", .danger) }
        if item.isRunningLow { return ("Running low", .ink) }
        return nil
    }

    static func label(item: InventoryItem, location: String?) -> String {
        var parts = [item.displayName]
        if let location { parts.append(location) }
        parts.append(item.quantityLabel)
        if let state = state(item) { parts.append(state.text) }
        return parts.joined(separator: ", ")
    }
}

struct InventoryDetailView: View {
    @ObservedObject var store: InventoryStore
    let itemID: UUID
    @State private var detail: InventoryDetail?
    @State private var days = 30
    @State private var loading = true
    @State private var error: String?
    @State private var editing = false
    @State private var changingQuantity = false
    @State private var confirmingArchive = false
    @State private var saving = false
    @State private var loadID = UUID()
    private var item: InventoryItem? { store.items.first { $0.id == itemID } }

    var body: some View {
        Group {
            if let item {
                HousePage {
                    HouseHero(title: item.displayName, size: 30, subtitle: subtitle(item))
                    stock(item)
                    facts(item)
                    purchaseInformation(item)
                    history(item)
                    if let error {
                        VStack(alignment: .leading, spacing: 10) {
                            HouseBanner(message: error, kind: .error)
                            Button("Reload history") { Task { await load() } }
                                .buttonStyle(.dibs(.secondary, fontSize: 16))
                        }
                    }
                    if let detail { observations(detail, item: item); purchases(detail, item: item) }
                    archive(item)
                } bottom: {
                    Button("Update quantity") { changingQuantity = true }
                        .buttonStyle(.dibs)
                        .accessibilityIdentifier("inventory.updateQuantity")
                }
            } else {
                HousePage {
                    HouseEmpty(symbol: "shippingbox", title: "Item unavailable", message: "This item is no longer in your pantry.")
                }
            }
        }
        .toolbar { Button("Edit") { editing = true }.disabled(item == nil || saving) }
        .sheet(isPresented: $editing) { if let item { InventoryEditor(store: store, original: item) } }
        .sheet(isPresented: $changingQuantity) { if let item { InventoryQuantityEditor(store: store, item: item) } }
        .confirmationDialog(item?.status == "archived" ? "Restore this item?" : "Archive this item?", isPresented: $confirmingArchive, titleVisibility: .visible) {
            if let item {
                Button(item.status == "archived" ? "Restore" : "Archive", role: item.status == "archived" ? nil : .destructive) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await store.setArchived(item, archived: item.status != "archived") }
                        catch { self.error = InventoryStore.message(error) }
                    }
                }
            }
        }
        .task(id: days) { await load() }
        .onChange(of: item) { _, _ in Task { await load() } }
        .refreshable { await store.refresh(); await load() }
    }

    // MARK: sections

    private func subtitle(_ item: InventoryItem) -> String? {
        let parts = [store.locations.first { $0.id == item.locationId }?.name, item.category?.capitalized].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The quantity in display type with its stock state.
    private func stock(_ item: InventoryItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(item.quantity.map { $0.formatted() } ?? "–")
                .font(.display(44))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
            Text(item.quantity == nil ? "quantity unknown" : item.unit)
                .font(.system(size: 17))
                .foregroundStyle(Color.muted)
            Spacer(minLength: 8)
            if let state = InventoryRowView.state(item) { HousePill(text: state.text, style: state.style) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quantity: \(item.quantityLabel)")
    }

    @ViewBuilder private func facts(_ item: InventoryItem) -> some View {
        let rows = factRows(item)
        if !rows.isEmpty { HouseFacts(rows: rows).dibsCard() }
    }

    private func factRows(_ item: InventoryItem) -> [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = []
        if let category = item.category { rows.append(("Category", category)) }
        if let level = item.parLevel { rows.append(("Restock below", "\(level.formatted()) \(item.unit)")) }
        if let date = item.observedAt { rows.append(("Last observed", date.formatted(.dateTime.month().day().hour().minute()))) }
        if let source = item.source { rows.append(("Source", source.capitalized)) }
        return rows
    }

    private func purchaseInformation(_ item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("Purchase information")
            VStack(spacing: 0) {
                if let merchant = item.lastPurchasedFrom { HouseFactRow(title: "Last purchased from", value: merchant.label); Hairline() }
                if let date = item.lastPurchasedOn { HouseFactRow(title: "Last purchased on", value: date); Hairline() }
                if let id = item.preferredMerchantId { PreferredMerchantLabel(store: store, id: id) }
                else { Text("No preferred store").houseNote().frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
            }
            .dibsCard()
        }
    }

    private func history(_ item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("Quantity history")
            VStack(alignment: .leading, spacing: 14) {
                HouseSegments(label: "Period", options: [("7 days", 7), ("30 days", 30), ("90 days", 90)], selection: $days)
                if loading { ProgressView("Loading history…").font(.system(size: 14)).foregroundStyle(Color.muted) }
                if let detail, detail.daily.contains(where: { $0.quantity != nil }) {
                    Chart(detail.daily) { point in
                        if let quantity = point.quantity {
                            BarMark(x: .value("Date", point.day, unit: .day), y: .value("Quantity", quantity))
                                .foregroundStyle(Color.ink)
                        }
                    }
                    .chartXScale(domain: (detail.daily.first?.day ?? Date())...(detail.daily.last?.day ?? Date()).addingTimeInterval(86_400))
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : days == 30 ? 7 : 30)) {
                            AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(Color.muted)
                        }
                    }
                    .chartYAxis {
                        AxisMarks {
                            AxisGridLine().foregroundStyle(Color.line)
                            AxisValueLabel().foregroundStyle(Color.muted)
                        }
                    }
                    .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    .frame(height: 180)
                    .accessibilityLabel("Daily quantity in \(item.unit)")
                } else if !loading && error == nil {
                    Text("No quantity history yet.").houseNote()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
        }
    }

    private func observations(_ detail: InventoryDetail, item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("Recent observations")
            VStack(spacing: 0) {
                if detail.observations.isEmpty { Text("No observations yet.").houseNote().frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(detail.observations.enumerated()), id: \.offset) { index, observation in
                    if index > 0 { Hairline() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(observation.quantity.formatted()) \(item.unit) · \(observation.source.capitalized)").houseBody()
                        Text(observation.time, format: .dateTime.month().day().year().hour().minute()).houseNote()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .dibsCard()
        }
    }

    private func purchases(_ detail: InventoryDetail, item: InventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("Purchase history")
            VStack(spacing: 0) {
                if detail.purchaseHistory.isEmpty { Text("No purchases recorded yet.").houseNote().frame(maxWidth: .infinity, alignment: .leading) }
                ForEach(Array(detail.purchaseHistory.enumerated()), id: \.element.id) { index, purchase in
                    if index > 0 { Hairline() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(purchase.merchant?.label ?? "Store not recorded").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                            if let date = purchase.purchasedOn { Text(date).houseNote() }
                            else { Text(purchase.observedAt, style: .date).houseNote() }
                        }
                        Spacer(minLength: 8)
                        Text("\(purchase.quantity.formatted()) \(item.unit)").font(.display(17)).foregroundStyle(Color.ink)
                    }
                    .padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .dibsCard()
        }
    }

    private func archive(_ item: InventoryItem) -> some View {
        let archived = item.status == "archived"
        return VStack(spacing: 4) {
            Button(archived ? "Restore item" : "Archive item", role: archived ? nil : .destructive) { confirmingArchive = true }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(archived ? Color.ink : Color.danger)
                .frame(maxWidth: .infinity, minHeight: Metrics.tap)
                .disabled(saving)
            Text("Archived items keep their history and can be restored from your pantry.")
                .houseNote()
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
        .padding(.top, 4)
    }

    private func load() async {
        let request = UUID(); loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        do {
            let result = try await store.detail(itemID, days: days)
            guard loadID == request else { return }
            detail = result; error = nil
        } catch {
            guard loadID == request, !(error is CancellationError) else { return }
            self.error = InventoryStore.message(error)
        }
    }
}

private struct PreferredMerchantLabel: View {
    let store: InventoryStore
    let id: UUID
    @State private var merchant: InventoryMerchant?
    @State private var failed = false
    var body: some View {
        HouseFactRow(title: "Preferred store", value: merchant?.label ?? (failed ? "Store unavailable" : "Loading…"))
            .task(id: id) {
                merchant = nil; failed = false
                do { merchant = try await store.merchant(id) } catch { failed = true }
            }
    }
}

// MARK: - Pieces shared by the pantry, wishlist, capture and settings pages
//
// Same look as the shelf pieces on the lists, trips and price-watch pages (ShelfPage, ShelfHero, ShelfTile,
// ShelfPill, ShelfEmpty, ShelfField): paper, a display headline with one line of context, items as soft
// tiles, white hairline cards, dibsInput fields, dashed "nothing yet" boxes and one ink action pinned to
// the bottom. They carry a `House` prefix so this branch merges without clashing; once both land, point
// them at the Shelf versions and delete this block.

extension View {
    /// Secondary copy: 13 pt, muted.
    func houseNote() -> some View {
        font(.system(size: 13)).foregroundStyle(Color.muted)
    }

    /// Body copy: 15 pt, body ink.
    func houseBody() -> some View {
        font(.system(size: 15)).foregroundStyle(Color.bodyInk)
    }

    /// An item name: 16 pt bold ink.
    func houseName() -> some View {
        font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink)
    }

    /// The pinned action bar at the bottom of a page.
    func housePinned() -> some View {
        padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space1)
            .background(Color.paper)
    }
}

/// A page on paper: a scrolling column of cards with an optional pinned action, as in Dibs' Start screen.
/// The hero (a `HouseHero`) is the first thing in `content`; the navigation bar only carries Back and icons.
struct HousePage<Content: View, Bottom: View>: View {
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
            if showsBottom { bottom.housePinned() }
        }
        .dibsScreen()
        .navigationTitle("")
        .toolbar(.visible, for: .navigationBar)
        .tint(Color.ink)
    }
}

extension HousePage where Bottom == EmptyView {
    init(@ViewBuilder content: () -> Content) {
        self.init(bottomVisible: false, content: content, bottom: { EmptyView() })
    }
}

/// The page headline: display type, then one line of context.
struct HouseHero: View {
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
struct HouseSectionTitle: View {
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
struct HouseTile: View {
    let seed: String
    let label: String
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            tileColor(id: seed)
            Text(label.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Color.ink)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A small fact in a capsule: outlined, ink, muted or danger.
struct HousePill: View {
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
struct HouseEmpty: View {
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
struct HouseBanner: View {
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
                    .houseBody()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dibsCard(radius: 14, padding: 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One label and value line inside a card: ink title, muted value.
struct HouseFactRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundStyle(Color.ink)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 15))
                .foregroundStyle(Color.muted)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Label and value rows inside a card, split by hairlines.
struct HouseFacts: View {
    let rows: [(title: String, value: String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { index in
                if index > 0 { Hairline() }
                HouseFactRow(title: rows[index].title, value: rows[index].value)
            }
        }
    }
}

/// A labelled `dibsInput` field.
struct HouseField<Content: View>: View {
    let label: String
    var note: String?
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
            if let note { Text(note).houseNote().fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A labelled field holding a menu `Picker`.
struct HouseMenu<Value: Hashable, Options: View>: View {
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

/// Two or three exclusive choices in one capsule: the chosen one is ink with white text.
struct HouseSegments<Value: Hashable>: View {
    let label: String
    let options: [(title: String, value: Value)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index], chosen = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(chosen ? Color.white : Color.ink)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(chosen ? Color.ink : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.lineStrong))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// A filter capsule: ink when chosen, white with a hairline otherwise; `quiet` is a plain action.
struct HouseChip: View {
    let title: String
    var symbol: String?
    let selected: Bool
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(selected ? Color.white : quiet ? Color.muted : Color.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(Capsule().fill(selected ? Color.ink : quiet ? Color.clear : Color.card))
            .overlay(Capsule().strokeBorder(selected ? Color.ink : quiet ? Color.line : Color.lineStrong,
                                            style: StrokeStyle(lineWidth: 1, dash: quiet ? [4, 3] : [])))
            .frame(minHeight: Metrics.tap)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A compact 44 pt action inside a card: ink or outlined.
struct HouseActionStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(kind == .primary ? Color.white : isEnabled ? Color.ink : Color.ink.opacity(0.55))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity, minHeight: Metrics.tap)
            .padding(.horizontal, 10)
            .background(kind == .primary ? Color.ink.opacity(isEnabled ? 1 : 0.7) : Color.card,
                        in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong)
                }
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
    }
}

extension ButtonStyle where Self == HouseActionStyle {
    static func houseAction(_ kind: HouseActionStyle.Kind = .secondary) -> HouseActionStyle { HouseActionStyle(kind: kind) }
}

/// Chips and pills that wrap onto new lines.
struct HouseFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width { x = 0; y += rowHeight; rowHeight = 0 }
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
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight; rowHeight = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
