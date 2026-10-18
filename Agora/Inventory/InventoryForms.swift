import SwiftUI

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
            Form {
                Section("Item") {
                    TextField("Name", text: $draft.name).accessibilityIdentifier("inventory.name")
                    if original == nil {
                        TextField("Category (optional)", text: $draft.category)
                        TextField("Unit, e.g. cartons", text: $draft.unit)
                        LabeledContent("Quantity") {
                            TextField("Unknown", text: $draft.quantity).keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("inventory.quantity")
                        }
                    }
                }
                Section {
                    Picker("Location", selection: $draft.locationID) {
                        Text("No location").tag(UUID?.none)
                        ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                    }
                    LabeledContent("Restock below") {
                        TextField("Not set", text: $draft.restockLevel).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("inventory.restockLevel")
                    }
                } header: { Text("Tracking") } footer: {
                    Text("An empty restock level turns off low-stock tracking. Quantities use \(draft.unit).")
                }
                Section("Preferred store") {
                    Button { choosingMerchant = true } label: {
                        LabeledContent("Store", value: merchantLabel ?? (draft.merchantID == nil ? "None" : "Choose store"))
                    }
                    if draft.merchantID != nil {
                        Button("Clear preferred store", role: .destructive) { draft.merchantID = nil; merchantLabel = nil }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .disabled(saving)
            .navigationTitle(original == nil ? "Add item" : "Edit item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(!valid || saving || uncertainSave)
                        .accessibilityIdentifier("inventory.save")
                }
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
            Form {
                Section {
                    TextField("Quantity in \(item.unit)", text: $quantity).keyboardType(.decimalPad)
                        .accessibilityIdentifier("inventory.quantity")
                } header: { Text(item.displayName) } footer: {
                    Text("Enter the total amount you have now. This records a new observation and keeps the previous history.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle("Update quantity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
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
                    .disabled(saving || (try? InventoryDraft.number(quantity, required: true)) == nil)
                    .accessibilityIdentifier("inventory.save")
                }
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
    var body: some View {
        NavigationStack {
            Form {
                Section(store.household?.name ?? "Locations") {
                    ForEach(store.locations) { location in
                        LabeledContent(location.name, value: location.kind.capitalized)
                    }
                }
                Section("Add location") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(["fridge", "freezer", "pantry", "bathroom", "other"], id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    Button(saving ? "Adding…" : "Add location") {
                        saving = true; error = nil
                        Task {
                            defer { saving = false }
                            do {
                                _ = try await store.addLocation(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
                                name = ""
                            } catch { self.error = InventoryStore.message(error) }
                        }
                    }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 40)
                }.disabled(saving)
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("Storage locations")
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
            List {
                if loading { ProgressView("Finding stores…") }
                ForEach(merchants) { merchant in
                    Button(merchant.label) { selected(merchant); dismiss() }
                }
                if !name.isEmpty {
                    Section("Add a store") {
                        TextField("Neighborhood or branch (optional)", text: $locality)
                        Button("Add “\(name)”") {
                            saving = true; error = nil
                            Task {
                                defer { saving = false }
                                do {
                                    let merchant = try await store.addMerchant(name: name, locality: locality.trimmingCharacters(in: .whitespacesAndNewlines))
                                    selected(merchant); dismiss()
                                } catch { self.error = InventoryStore.message(error) }
                            }
                        }.disabled(name.count > 80 || locality.count > 80)
                    }
                } else if merchants.isEmpty && !loading {
                    Text("Search for a store or enter a name to add one.").foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving)
            .searchable(text: $search, prompt: "Store name")
            .navigationTitle(title)
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
