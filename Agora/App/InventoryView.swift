import SwiftUI
import Charts

struct ListsView: View {
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var shopping: ShoppingStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var trips: TripStore

    var body: some View {
        NavigationStack {
            List {
                if inventory.households.count > 1 {
                    Picker("Household", selection: Binding(get: { inventory.householdID }, set: { id in
                        if let id { Task { await inventory.selectHousehold(id) } }
                    })) {
                        ForEach(inventory.households) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Section {
                    NavigationLink {
                        InventoryListView(store: inventory)
                    } label: {
                        listRow("Inventory list", subtitle: "What you have at home", symbol: "shippingbox", tint: .teal)
                    }
                    .accessibilityIdentifier("lists.inventory")
                    NavigationLink {
                        TripsView(store: trips)
                    } label: {
                        listRow("Shopping lists", subtitle: "What to pick up on your next trip", symbol: "checklist", tint: .blue)
                    }
                    .accessibilityIdentifier("lists.shopping")
                    NavigationLink {
                        ShoppingView(store: shopping, settings: settings)
                    } label: {
                        listRow("Watch list", subtitle: "Products and prices you’re keeping an eye on", symbol: "binoculars", tint: .purple)
                    }
                    .accessibilityIdentifier("lists.watches")
                    NavigationLink {
                        ShoppingView(store: shopping, settings: settings, selection: "suggestions")
                    } label: {
                        listRow("Suggested for you", subtitle: "Ideas and essentials to replenish", symbol: "sparkles", tint: .orange)
                    }
                    .accessibilityIdentifier("lists.suggestions")
                }
            }
            .navigationTitle("Lists")
            .refreshable { await inventory.refresh(); await shopping.refresh(); await trips.refresh() }
        }
        .id(inventory.context)
    }

    private func listRow(_ title: String, subtitle: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }
}

struct InventoryView: View {
    @ObservedObject var store: InventoryStore
    var body: some View {
        NavigationStack { InventoryListView(store: store) }
    }
}

struct InventoryListView: View {
    @ObservedObject var store: InventoryStore
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

    var body: some View {
        List {
            if store.households.count > 1 {
                Picker("Household", selection: Binding(get: { store.householdID }, set: { id in
                    if let id { Task { await store.selectHousehold(id) } }
                })) {
                    ForEach(store.households) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            Section {
                Picker("Location", selection: $locationID) {
                    Text("All locations").tag(UUID?.none)
                    ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Show archived items", isOn: $showArchived)
            }
            if let error = store.error {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try again") { Task { await store.refresh() } }.disabled(store.loading)
                }
            }
            Section {
                if store.loading && store.items.isEmpty {
                    ProgressView("Loading inventory…")
                } else if visibleItems.isEmpty && store.error == nil {
                    ContentUnavailableView(showArchived ? "No archived items" : "No items found", systemImage: "shippingbox",
                                           description: Text(search.isEmpty && locationID == nil ? "Add an item to start tracking your essentials." : "Try another search or location."))
                    if !showArchived {
                        Button("Add item") { adding = true }.disabled(store.householdID == nil)
                    }
                }
                ForEach(visibleItems) { item in
                    NavigationLink {
                        InventoryDetailView(store: store, itemID: item.id)
                    } label: {
                        InventoryRowView(item: item, location: store.locations.first { $0.id == item.locationId }?.name)
                    }
                    .accessibilityIdentifier("inventory.item.\(item.id)")
                }
            } header: {
                if let household = store.household { Text(household.name) }
            }
        }
        .searchable(text: $search, prompt: "Search inventory")
        .navigationTitle("Inventory list")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { managingLocations = true } label: { Label("Locations", systemImage: "square.grid.2x2") }
                    .disabled(store.householdID == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("Add item", systemImage: "plus") }
                    .disabled(store.householdID == nil)
                    .accessibilityIdentifier("inventory.add")
            }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $adding) { InventoryEditor(store: store, original: nil) }
        .sheet(isPresented: $managingLocations) { InventoryLocationsView(store: store) }
        .id(store.context)
        .onChange(of: store.context) { _, _ in locationID = nil; adding = false; managingLocations = false }
    }
}

private struct InventoryRowView: View {
    let item: InventoryItem
    let location: String?
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ItemThumbnail(kind: "inventory", id: item.id, name: item.displayName, category: item.category)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.headline)
                if let location { Text(location).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.quantityLabel).font(.subheadline)
                if item.status == "archived" { Text("Archived").font(.caption).foregroundStyle(.secondary) }
                else if item.quantity == 0 { Text("Out of stock").font(.caption).foregroundStyle(.red) }
                else if item.isRunningLow { Text("Running low").font(.caption).foregroundStyle(.orange) }
            }.multilineTextAlignment(.trailing)
        }.padding(.vertical, 4)
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
        List {
            if let item {
                Section {
                    InventoryRowView(item: item, location: store.locations.first { $0.id == item.locationId }?.name)
                    ChangeItemImageButton(ref: .init(kind: "inventory", id: item.id, name: item.displayName, category: item.category))
                    if let category = item.category { LabeledContent("Category", value: category) }
                    if let level = item.parLevel { LabeledContent("Restock below", value: "\(level.formatted()) \(item.unit)") }
                    if let date = item.observedAt {
                        LabeledContent("Last observed") { Text(date, format: .dateTime.month().day().hour().minute()) }
                    }
                    if let source = item.source { LabeledContent("Source", value: source.capitalized) }
                    Button("Update quantity") { changingQuantity = true }
                        .accessibilityIdentifier("inventory.updateQuantity")
                }
                Section("Purchase information") {
                    if let merchant = item.lastPurchasedFrom { LabeledContent("Last purchased from", value: merchant.label) }
                    if let date = item.lastPurchasedOn { LabeledContent("Last purchased on", value: date) }
                    if let id = item.preferredMerchantId { PreferredMerchantLabel(store: store, id: id) }
                    else { Text("No preferred store").foregroundStyle(.secondary) }
                }
                Section("Quantity history") {
                    Picker("Period", selection: $days) {
                        Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                    }.pickerStyle(.segmented)
                    if loading { ProgressView("Loading history…") }
                    if let detail, detail.daily.contains(where: { $0.quantity != nil }) {
                        Chart(detail.daily) { point in
                            if let quantity = point.quantity {
                                BarMark(x: .value("Date", point.day, unit: .day), y: .value("Quantity", quantity))
                                    .foregroundStyle(.teal)
                            }
                        }
                        .chartXScale(domain: (detail.daily.first?.day ?? Date())...(detail.daily.last?.day ?? Date()).addingTimeInterval(86_400))
                        .chartXAxis {
                            AxisMarks(values: .stride(by: .day, count: days == 7 ? 1 : days == 30 ? 7 : 30)) {
                                AxisValueLabel(format: .dateTime.month().day())
                            }
                        }
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                        .frame(height: 180)
                        .accessibilityLabel("Daily quantity in \(item.unit)")
                    } else if !loading && error == nil { Text("No quantity history yet.").foregroundStyle(.secondary) }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Reload history") { Task { await load() } }
                    }
                }
                if let detail {
                    Section("Recent observations") {
                        if detail.observations.isEmpty { Text("No observations yet.").foregroundStyle(.secondary) }
                        ForEach(Array(detail.observations.enumerated()), id: \.offset) { _, observation in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(observation.quantity.formatted()) \(item.unit) · \(observation.source.capitalized)")
                                Text(observation.time, format: .dateTime.month().day().year().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Purchase history") {
                        if detail.purchaseHistory.isEmpty { Text("No purchases recorded yet.").foregroundStyle(.secondary) }
                        ForEach(detail.purchaseHistory) { purchase in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(purchase.merchant?.label ?? "Store not recorded")
                                Text("\(purchase.quantity.formatted()) \(item.unit)").font(.subheadline)
                                if let date = purchase.purchasedOn { Text(date).font(.caption).foregroundStyle(.secondary) }
                                else { Text(purchase.observedAt, style: .date).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                Section {
                    Button(item.status == "archived" ? "Restore item" : "Archive item", role: item.status == "archived" ? nil : .destructive) {
                        confirmingArchive = true
                    }.disabled(saving)
                } footer: { Text("Archived items keep their history and can be restored from Inventory.") }
            } else { ContentUnavailableView("Item unavailable", systemImage: "shippingbox") }
        }
        .navigationTitle(item?.displayName ?? "Item")
        .navigationBarTitleDisplayMode(.inline)
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
        LabeledContent("Preferred store", value: merchant?.label ?? (failed ? "Store unavailable" : "Loading…"))
            .task(id: id) {
                merchant = nil; failed = false
                do { merchant = try await store.merchant(id) } catch { failed = true }
            }
    }
}
