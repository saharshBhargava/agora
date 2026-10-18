import SwiftUI

struct TripsView: View {
    @ObservedObject var store: TripStore
    @State private var options = TripPlanningOptions()
    @State private var reviewing: TripProposal?
    @State private var creatingList = false
    @State private var createdListID: UUID?

    var body: some View {
        List {
            Section {
                Text("Make a shopping list or generate one from items running out, then find time to shop. Review each trip before adding it to your calendar.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Shopping times") {
                    Stepper("Look ahead \(options.days) days", value: $options.days, in: 1...14)
                    Picker("Start after", selection: $options.startHour) {
                        ForEach(0..<24) { Text(hour($0)).tag($0) }
                    }
                    Picker("Finish by", selection: $options.endHour) {
                        ForEach(1...24, id: \.self) { Text(hour($0)).tag($0) }
                    }
                    Picker("Time for each trip", selection: $options.durationMinutes) {
                        ForEach([30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    Text("Include travel time. Times use \(options.timezone). Store opening hours are not checked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    reviewing = nil
                    Task { await store.plan(options: options) }
                } label: {
                    Label("Find shopping times", systemImage: "calendar.badge.clock")
                }
                .disabled(store.busy || store.loading || options.startHour >= options.endHour)
                .accessibilityIdentifier("trips.plan")
            }

            if store.busy || store.loading {
                Section { ProgressView(store.busy ? "Updating shopping trips…" : "Loading trips…") }
            }
            if let error = store.error {
                Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("trips.error") }
            }
            if let notice = store.notice {
                Section { Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("trips.notice") }
            }

            if !store.proposals.isEmpty {
                Section("Suggested times") {
                    ForEach(store.proposals) { proposal in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(proposal.title).font(.headline)
                            if let start = proposal.start, let end = proposal.end {
                                TripTimeLabel(start: start, end: end, timezone: proposal.timezone)
                            }
                            Text(proposal.explanation).font(.subheadline).foregroundStyle(.secondary)
                            if let warning = proposal.warning {
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.subheadline).foregroundStyle(.orange)
                            }
                            if proposal.canSchedule {
                                Button("Review trip") { reviewing = proposal }
                                    .disabled(store.busy)
                                    .accessibilityIdentifier("trips.review.\(proposal.id)")
                            }
                        }.padding(.vertical, 6)
                    }
                }
            }

            if !store.trips.isEmpty {
                Section("Calendar trips") {
                    ForEach(store.trips.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }) { trip in
                        TripRecordRow(trip: trip, store: store)
                    }
                }
            }

            Section("Shopping lists") {
                if store.lists.isEmpty && !store.loading {
                    Text("Create a list and add what you need, or find shopping times to generate lists from upcoming run-outs.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.lists) { list in
                    NavigationLink {
                        TripListView(store: store, listID: list.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(list.name).font(.headline)
                            if let merchant = list.merchant { Text(merchant.label).font(.caption).foregroundStyle(.secondary) }
                            Text("\(list.openCount) items left").font(.subheadline).foregroundStyle(.secondary)
                            if let due = list.neededBy {
                                Text("Needed by \(due.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Shopping lists & trips")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New list", systemImage: "plus") { creatingList = true }
                    .disabled(!store.canUse || store.busy || store.loading)
                    .accessibilityIdentifier("lists.create")
            }
        }
        .sheet(isPresented: $creatingList) {
            TripCreateListSheet(store: store) { id in
                creatingList = false
                createdListID = id
            }
        }
        .navigationDestination(item: $createdListID) { id in
            TripListView(store: store, listID: id)
        }
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .onChange(of: store.context) { _, _ in
            reviewing = nil; creatingList = false; createdListID = nil
        }
        .onChange(of: store.proposals.map(\.reservationKey)) { _, keys in
            if let reviewing, !keys.contains(reviewing.reservationKey) { self.reviewing = nil }
        }
        .sheet(item: $reviewing) { proposal in
            TripReviewSheet(proposal: proposal) {
                reviewing = nil
                Task { await store.schedule(proposal) }
            }
        }
    }

    private func hour(_ value: Int) -> String {
        value == 24 ? "Midnight" : String(format: "%02d:00", value)
    }
}

struct TripTimeLabel: View {
    let start: Date
    let end: Date
    let timezone: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(start, format: .dateTime.weekday().month().day())
            HStack(spacing: 4) {
                Text(start, style: .time)
                Text("–")
                Text(end, style: .time)
            }
        }
        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
        .font(.subheadline)
    }
}

struct TripCreateListSheet: View {
    @ObservedObject var store: TripStore
    let created: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var merchant: InventoryMerchant?
    @State private var choosingStore = false
    @State private var saving = false
    @State private var saveUnconfirmed = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("List details") {
                    TextField("List name, e.g. Weekend groceries", text: $name)
                        .accessibilityIdentifier("lists.name")
                    Button { choosingStore = true } label: {
                        LabeledContent("Store", value: merchant?.label ?? "Any store")
                    }
                    if merchant != nil { Button("Remove store") { merchant = nil } }
                }
                Section { Text("Add items after creating your list. You can use it without adding a Calendar trip.").foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("Creating list…") }
            }
            .disabled(saving)
            .navigationTitle("New shopping list")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        saving = true; error = nil
                        let context = store.context
                        Task {
                            defer { saving = false }
                            do {
                                let id = try await store.createList(name: name, merchantID: merchant?.id)
                                guard store.context == context else { return }
                                created(id)
                            } catch {
                                guard store.context == context else { return }
                                self.error = manualListError(error)
                                saveUnconfirmed = manualListSaveUnconfirmed(error)
                            }
                        }
                    }
                    .disabled(saving || saveUnconfirmed || store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                    .accessibilityIdentifier("lists.save")
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $choosingStore) {
                InventoryMerchantPicker(store: store.inventory, title: "Shopping at") { merchant = $0 }
            }
        }
    }
}

struct TripAddItemSheet: View {
    @ObservedObject var store: TripStore
    let listID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TripItemDraft()
    @State private var saving = false
    @State private var saveUnconfirmed = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Item") {
                    TextField("Item name", text: $draft.title).accessibilityIdentifier("lists.itemName")
                    TextField("Quantity", text: $draft.quantity).keyboardType(.decimalPad)
                    TextField("Unit (optional), e.g. bottles", text: $draft.unit)
                    TextField("Notes (optional)", text: $draft.note, axis: .vertical).lineLimit(2...4)
                }
                if let error { Text(error).foregroundStyle(.red) }
                if saving { ProgressView("Adding item…") }
            }
            .disabled(saving)
            .navigationTitle("Add item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true; error = nil
                        let context = store.context
                        Task {
                            defer { saving = false }
                            do {
                                try await store.addItem(listID: listID, draft: draft)
                                guard store.context == context else { return }
                                dismiss()
                            } catch {
                                guard store.context == context else { return }
                                self.error = manualListError(error)
                                saveUnconfirmed = manualListSaveUnconfirmed(error)
                            }
                        }
                    }
                    .disabled(saving || saveUnconfirmed || store.busy || (try? draft.body()) == nil)
                    .accessibilityIdentifier("lists.saveItem")
                }
            }
            .interactiveDismissDisabled(saving)
        }
    }
}

private func manualListSaveUnconfirmed(_ error: Error) -> Bool {
    guard let error = error as? BrowserError else { return !(error is CancellationError) }
    if ["invalid_list", "invalid_list_item", "list_unavailable"].contains(error.code) { return false }
    return error.status.map { !(400..<500).contains($0) } ?? true
}

@MainActor private func manualListError(_ error: Error) -> String {
    if !manualListSaveUnconfirmed(error) {
        return InventoryStore.message(error)
    }
    return "Could not confirm the save. Close this form and refresh your lists before trying again; it may already have saved."
}

private struct TripReviewSheet: View {
    let proposal: TripProposal
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Calendar event") {
                    Text(proposal.title).font(.headline)
                    if let start = proposal.start, let end = proposal.end {
                        TripTimeLabel(start: start, end: end, timezone: proposal.timezone)
                    }
                    LabeledContent("Timezone", value: proposal.timezone)
                    if !proposal.location.isEmpty { LabeledContent("Location", value: proposal.location) }
                    if let warning = proposal.warning {
                        Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                }
                Section("Event notes") { Text(proposal.description) }
                Section {
                    Button("Add to Calendar", action: confirm)
                        .disabled(!proposal.canSchedule)
                        .accessibilityIdentifier("trips.confirm")
                } footer: {
                    Text("Your availability is checked again before saving. No invitations are sent.")
                }
            }
            .navigationTitle("Review trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

private struct TripRecordRow: View {
    let trip: TripRecord
    @ObservedObject var store: TripStore
    @State private var reviewingSavedTrip = false
    private var status: String {
        switch trip.status {
        case "scheduled": return "Added to Calendar"
        case "failed": return "Not added"
        default: return "Needs checking"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trip.title).font(.headline)
            if let start = trip.startDate, let end = trip.endDate {
                TripTimeLabel(start: start, end: end, timezone: trip.timezone)
            }
            Label(status, systemImage: trip.status == "scheduled" ? "checkmark.circle" : "exclamationmark.circle")
                .font(.caption).foregroundStyle(trip.status == "scheduled" ? Color.secondary : Color.orange)
            if !trip.mine { Text("Planned by a household member").font(.caption).foregroundStyle(.secondary) }
            if trip.isUncertain {
                Text("This event may have been saved. Check its status before planning another trip for this list.")
                    .font(.caption).foregroundStyle(.secondary)
                if trip.mine {
                    Button("Check Calendar status") { Task { await store.reconcile(trip) } }
                        .disabled(store.busy)
                        .accessibilityIdentifier("trips.reconcile.\(trip.id)")
                    if trip.status == "reserved" {
                        Button("Review saved trip") { reviewingSavedTrip = true }
                            .disabled(store.busy)
                    }
                    Button("Release reservation", role: .destructive) {
                        Task { await store.release(trip) }
                    }
                    .disabled(store.busy)
                    .accessibilityIdentifier("trips.release.\(trip.id)")
                    Text("Only release after confirming this trip is not in Calendar. Releasing incorrectly can lead to a duplicate event.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let raw = trip.eventUrl, let url = URL(string: raw), url.scheme == "https",
               ["www.google.com", "calendar.google.com"].contains(url.host ?? "") {
                Link("Open in Calendar", destination: url)
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $reviewingSavedTrip) {
            NavigationStack {
                List {
                    Section("Saved Calendar request") {
                        Text(trip.title).font(.headline)
                        if let start = trip.startDate, let end = trip.endDate {
                            TripTimeLabel(start: start, end: end, timezone: trip.timezone)
                        }
                        LabeledContent("Timezone", value: trip.timezone)
                        if !trip.location.isEmpty { LabeledContent("Location", value: trip.location) }
                        Text(trip.description)
                    }
                    Section {
                        Button("Finish adding this trip") {
                            reviewingSavedTrip = false
                            Task { await store.resume(trip) }
                        }
                        Button("Release reservation", role: .destructive) {
                            reviewingSavedTrip = false
                            Task { await store.release(trip) }
                        }
                    } footer: {
                        Text("Finish checks for this exact event first. If it has not been saved, checks your availability and submits the same saved request. Release only if the slot has passed or Calendar has no matching event.")
                    }
                }
                .navigationTitle("Review saved trip")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { reviewingSavedTrip = false } } }
            }
        }
        .onChange(of: store.context) { _, _ in reviewingSavedTrip = false }
    }
}

struct TripListView: View {
    @ObservedObject var store: TripStore
    let listID: UUID
    @State private var addingItem = false
    private var list: TripList? { store.lists.first { $0.id == listID } }
    var body: some View {
        List {
            if let list {
                if let merchant = list.merchant { Text(merchant.label).foregroundStyle(.secondary) }
                if list.status == "open" {
                    Button("Add item", systemImage: "plus") { addingItem = true }
                        .disabled(store.busy || store.loading)
                        .accessibilityIdentifier("lists.addItem")
                }
                if list.items.isEmpty {
                    Text("Your list is empty. Add your first item to get started.").foregroundStyle(.secondary)
                }
                Section {
                    ForEach(list.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Button {
                                Task { await store.setChecked(listID: list.id, itemID: item.id, checked: !item.checked) }
                            } label: {
                                Image(systemName: item.checked ? "checkmark.circle.fill" : "circle").font(.title2)
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.busy || list.status != "open")
                            .accessibilityLabel("\(item.checked ? "Uncheck" : "Check") \(item.title)")
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.title).strikethrough(item.checked)
                                Text("\(item.quantity.formatted()) \(item.unit ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let note = item.note, !note.isEmpty { Text(note).font(.caption) }
                                if let reason = item.explanation {
                                    DisclosureGroup("Why this item?") { Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }.padding(.vertical, 4)
                    }
                } footer: {
                    Text(list.status == "open"
                         ? "Checking an item updates this list. Update inventory quantities after bringing purchases home."
                         : "This list is closed.")
                }
            }
            if let error = store.error { Text(error).foregroundStyle(.red) }
            if let notice = store.notice { Text(notice).foregroundStyle(.secondary) }
        }
        .navigationTitle(list?.name ?? "Shopping list")
        .sheet(isPresented: $addingItem) { TripAddItemSheet(store: store, listID: listID) }
        .onChange(of: store.context) { _, _ in addingItem = false }
        .refreshable { await store.refresh() }
    }
}
