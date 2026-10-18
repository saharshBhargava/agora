import SwiftUI

struct TripsView: View {
    @ObservedObject var store: TripStore
    @State private var options = TripPlanningOptions()
    @State private var reviewing: TripProposal?
    @State private var creatingList = false
    @State private var createdListID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ShelfPage {
                ShelfHero(title: "Your lists",
                          subtitle: "Make a shopping list or generate one from items running out, then find time to shop. Review each trip before adding it to your calendar.")
                status
                if !store.proposals.isEmpty { suggestedTimes.id("suggested") }
                shoppingLists
                if !store.trips.isEmpty { calendarTrips }
                planningOptions
            } bottom: {
                Button {
                    reviewing = nil
                    Task { await store.plan(options: options) }
                } label: {
                    Label("Find shopping times", systemImage: "calendar.badge.clock")
                }
                .buttonStyle(.dibs)
                .disabled(store.busy || store.loading || options.startHour >= options.endHour)
                .accessibilityIdentifier("trips.plan")
            }
            .onChange(of: store.proposals.map(\.reservationKey)) { _, keys in
                if let reviewing, !keys.contains(reviewing.reservationKey) { self.reviewing = nil }
                if !keys.isEmpty { withAnimation { proxy.scrollTo("suggested", anchor: .top) } }
            }
        }
        .navigationTitle("")
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
        .sheet(item: $reviewing) { proposal in
            TripReviewSheet(proposal: proposal) {
                reviewing = nil
                Task { await store.schedule(proposal) }
            }
        }
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        if store.busy || store.loading {
            HStack(spacing: 10) {
                ProgressView()
                Text(store.busy ? "Updating shopping trips…" : "Loading trips…")
                    .font(.system(size: 14)).foregroundStyle(Color.muted)
            }
            .accessibilityElement(children: .combine)
        }
        if let error = store.error {
            ShelfBanner(message: error, kind: .error).accessibilityIdentifier("trips.error")
        }
        if let notice = store.notice {
            ShelfBanner(message: notice).accessibilityIdentifier("trips.notice")
        }
    }

    // MARK: sections

    private var suggestedTimes: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Suggested times")
            ForEach(store.proposals) { proposal in
                VStack(alignment: .leading, spacing: 10) {
                    Text(proposal.title).shelfName()
                    if let start = proposal.start, let end = proposal.end {
                        TripTimeLabel(start: start, end: end, timezone: proposal.timezone)
                    }
                    Text(proposal.explanation).shelfNote().fixedSize(horizontal: false, vertical: true)
                    if let warning = proposal.warning {
                        ShelfPill(text: warning, symbol: "exclamationmark.triangle", style: .danger)
                    }
                    if proposal.canSchedule {
                        Button("Review trip") { reviewing = proposal }
                            .buttonStyle(.dibs(.secondary, fontSize: 16))
                            .disabled(store.busy)
                            .accessibilityIdentifier("trips.review.\(proposal.id)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dibsCard()
            }
        }
    }

    private var calendarTrips: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Calendar trips")
            ForEach(store.trips.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }) { trip in
                TripRecordRow(trip: trip, store: store)
            }
        }
    }

    private var shoppingLists: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Shopping lists")
            if store.lists.isEmpty && !store.loading {
                ShelfEmpty(symbol: "list.bullet.clipboard", title: "No lists yet",
                           message: "Create a list and add what you need, or find shopping times to generate lists from upcoming run-outs.")
            }
            ForEach(store.lists) { list in
                NavigationLink {
                    TripListView(store: store, listID: list.id)
                } label: {
                    HStack(spacing: 12) {
                        ShelfTile(seed: list.id.uuidString, label: list.name, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(list.name).shelfName().lineLimit(2)
                            if let merchant = list.merchant { Text(merchant.label).shelfNote() }
                            if let due = list.neededBy {
                                Text("Needed by \(due.formatted(date: .abbreviated, time: .shortened))").shelfNote()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(list.openCount)").font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
                            Text("left").shelfNote()
                        }
                    }
                    .dibsCard(radius: 14, padding: 12)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(listLabel(list))
                .accessibilityAddTraits(.isButton)
            }
        }
    }

    private func listLabel(_ list: TripList) -> String {
        var parts = [list.name]
        if let merchant = list.merchant { parts.append(merchant.label) }
        parts.append("\(list.openCount) items left")
        if let due = list.neededBy { parts.append("Needed by \(due.formatted(date: .abbreviated, time: .shortened))") }
        return parts.joined(separator: ", ")
    }

    private var planningOptions: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
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
                    .shelfNote()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.system(size: 15))
            .foregroundStyle(Color.ink)
            .padding(.top, 8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Shopping times").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
                Text("\(options.days) days ahead · \(hour(options.startHour))–\(hour(options.endHour)) · \(options.durationMinutes) minutes")
                    .shelfNote()
            }
        }
        .tint(Color.ink)
        .dibsCard()
    }

    private func hour(_ value: Int) -> String {
        value == 24 ? "Midnight" : String(format: "%02d:00", value)
    }
}

/// A trip's day in display type and its time range beneath.
struct TripTimeLabel: View {
    let start: Date
    let end: Date
    let timezone: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(start, format: .dateTime.weekday().month().day())
                .font(.display(22))
                .foregroundStyle(Color.ink)
            HStack(spacing: 4) {
                Text(start, style: .time)
                Text("–")
                Text(end, style: .time)
            }
            .font(.system(size: 15))
            .foregroundStyle(Color.bodyInk)
        }
        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
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
            ShelfPage {
                ShelfHero(title: "New shopping list", size: 30,
                          subtitle: "Add items after creating your list. You can use it without adding a Calendar trip.")
                ShelfField(label: "List name") {
                    TextField("Weekend groceries", text: $name)
                        .accessibilityIdentifier("lists.name")
                }
                VStack(alignment: .leading, spacing: 4) {
                    ShelfPickerButton(label: "Store", value: merchant?.label ?? "Any store") { choosingStore = true }
                    if merchant != nil {
                        Button("Remove store") { merchant = nil }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.danger)
                            .frame(minHeight: Metrics.tap)
                    }
                }
                if let error { ShelfBanner(message: error, kind: .error) }
                if saving {
                    HStack(spacing: 10) { ProgressView(); Text("Creating list…").font(.system(size: 14)).foregroundStyle(Color.muted) }
                }
            } bottom: {
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
                .buttonStyle(.dibs)
                .disabled(saving || saveUnconfirmed || store.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                .accessibilityIdentifier("lists.save")
            }
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
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
            ShelfPage {
                ShelfHero(title: "Add item", size: 30)
                ShelfField(label: "Item name") {
                    TextField("Dish soap", text: $draft.title).accessibilityIdentifier("lists.itemName")
                }
                HStack(alignment: .top, spacing: Metrics.space1) {
                    ShelfField(label: "Quantity") {
                        TextField("1", text: $draft.quantity).keyboardType(.decimalPad)
                    }
                    ShelfField(label: "Unit (optional)") {
                        TextField("bottles", text: $draft.unit)
                    }
                }
                ShelfField(label: "Notes (optional)") {
                    TextField("Unscented", text: $draft.note, axis: .vertical).lineLimit(2...4)
                }
                if let error { ShelfBanner(message: error, kind: .error) }
                if saving {
                    HStack(spacing: 10) { ProgressView(); Text("Adding item…").font(.system(size: 14)).foregroundStyle(Color.muted) }
                }
            } bottom: {
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
                .buttonStyle(.dibs)
                .disabled(saving || saveUnconfirmed || store.busy || (try? draft.body()) == nil)
                .accessibilityIdentifier("lists.saveItem")
            }
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
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

private func tripFacts(timezone: String, location: String) -> [(title: String, value: String)] {
    var rows: [(title: String, value: String)] = [("Timezone", timezone)]
    if !location.isEmpty { rows.append(("Location", location)) }
    return rows
}

private struct TripReviewSheet: View {
    let proposal: TripProposal
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ShelfPage {
                ShelfHero(title: "Review trip", size: 30,
                          subtitle: "Your availability is checked again before saving. No invitations are sent.")

                VStack(alignment: .leading, spacing: 10) {
                    ShelfSectionTitle("Calendar event")
                    VStack(alignment: .leading, spacing: 10) {
                        Text(proposal.title).shelfName()
                        if let start = proposal.start, let end = proposal.end {
                            TripTimeLabel(start: start, end: end, timezone: proposal.timezone)
                        }
                        if let warning = proposal.warning {
                            ShelfPill(text: warning, symbol: "exclamationmark.triangle", style: .danger)
                        }
                        ShelfDivider()
                        ShelfFacts(rows: tripFacts(timezone: proposal.timezone, location: proposal.location))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dibsCard()
                }

                VStack(alignment: .leading, spacing: 10) {
                    ShelfSectionTitle("Event notes")
                    Text(proposal.description)
                        .shelfBody()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dibsCard()
                }
            } bottom: {
                Button("Add to Calendar", action: confirm)
                    .buttonStyle(.dibs)
                    .disabled(!proposal.canSchedule)
                    .accessibilityIdentifier("trips.confirm")
            }
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Metrics.space1) {
                ShelfPill(text: status,
                          symbol: trip.status == "scheduled" ? "checkmark.circle.fill" : "exclamationmark.circle",
                          style: trip.status == "failed" ? .danger : .line)
                if !trip.mine { ShelfPill(text: "Planned by a household member", symbol: "person.2", style: .muted) }
            }
            Text(trip.title).shelfName()
            if let start = trip.startDate, let end = trip.endDate {
                TripTimeLabel(start: start, end: end, timezone: trip.timezone)
            }
            if trip.isUncertain {
                Text("This event may have been saved. Check its status before planning another trip for this list.")
                    .shelfNote()
                    .fixedSize(horizontal: false, vertical: true)
                if trip.mine {
                    Button("Check Calendar status") { Task { await store.reconcile(trip) } }
                        .buttonStyle(.dibs(.secondary, fontSize: 16))
                        .disabled(store.busy)
                        .accessibilityIdentifier("trips.reconcile.\(trip.id)")
                    if trip.status == "reserved" {
                        Button("Review saved trip") { reviewingSavedTrip = true }
                            .buttonStyle(.dibs(.secondary, fontSize: 16))
                            .disabled(store.busy)
                    }
                }
            }
            if let raw = trip.eventUrl, let url = URL(string: raw), url.scheme == "https",
               ["www.google.com", "calendar.google.com"].contains(url.host ?? "") {
                Link(destination: url) {
                    Label("Open in Calendar", systemImage: "arrow.up.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
        .sheet(isPresented: $reviewingSavedTrip) {
            NavigationStack {
                ShelfPage {
                    ShelfHero(title: "Review saved trip", size: 30,
                              subtitle: "Checks for this exact event first. If it has not been saved, checks your availability and submits the same saved request.")
                    VStack(alignment: .leading, spacing: 10) {
                        ShelfSectionTitle("Saved Calendar request")
                        VStack(alignment: .leading, spacing: 10) {
                            Text(trip.title).shelfName()
                            if let start = trip.startDate, let end = trip.endDate {
                                TripTimeLabel(start: start, end: end, timezone: trip.timezone)
                            }
                            ShelfDivider()
                            ShelfFacts(rows: tripFacts(timezone: trip.timezone, location: trip.location))
                            if !trip.description.isEmpty {
                                ShelfDivider()
                                Text(trip.description).shelfBody()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dibsCard()
                    }
                } bottom: {
                    Button("Finish adding this trip") {
                        reviewingSavedTrip = false
                        Task { await store.resume(trip) }
                    }
                    .buttonStyle(.dibs)
                }
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
        ShelfPage(bottomVisible: list?.status == "open") {
            if let list {
                ShelfHero(title: list.name, subtitle: summary(list))
                if list.items.isEmpty {
                    ShelfEmpty(symbol: "checklist", title: "Nothing here yet",
                               message: "Your list is empty. Add your first item to get started.")
                } else {
                    VStack(spacing: 10) {
                        ForEach(list.items) { item in itemRow(item, in: list) }
                    }
                }
                Text(list.status == "open"
                     ? "Checking an item updates this list. Update inventory quantities after bringing purchases home."
                     : "This list is closed.")
                    .shelfNote()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ShelfHero(title: "Shopping list")
            }
            if let error = store.error { ShelfBanner(message: error, kind: .error) }
            if let notice = store.notice { ShelfBanner(message: notice) }
        } bottom: {
            Button("Add item", systemImage: "plus") { addingItem = true }
                .buttonStyle(.dibs)
                .disabled(store.busy || store.loading)
                .accessibilityIdentifier("lists.addItem")
        }
        .navigationTitle("")
        .sheet(isPresented: $addingItem) { TripAddItemSheet(store: store, listID: listID) }
        .onChange(of: store.context) { _, _ in addingItem = false }
        .refreshable { await store.refresh() }
    }

    private func summary(_ list: TripList) -> String? {
        var parts: [String] = []
        if let merchant = list.merchant { parts.append(merchant.label) }
        if !list.items.isEmpty { parts.append("\(list.openCount) of \(list.items.count) left") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func itemRow(_ item: TripListItem, in list: TripList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    Task { await store.setChecked(listID: list.id, itemID: item.id, checked: !item.checked) }
                } label: {
                    ShelfTile(seed: item.id.uuidString, label: item.title, size: 44, checked: item.checked)
                        .frame(width: Metrics.tap, height: Metrics.tap)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.busy || list.status != "open")
                .accessibilityLabel("\(item.checked ? "Uncheck" : "Check") \(item.title)")
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 16, weight: .bold))
                        .strikethrough(item.checked)
                        .foregroundStyle(item.checked ? Color.muted : Color.ink)
                        .lineLimit(2)
                    if let note = item.note, !note.isEmpty { Text(note).shelfNote() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(item.quantity.formatted())
                        .font(.display(17))
                        .foregroundStyle(item.checked ? Color.muted : Color.ink)
                        .monospacedDigit()
                    if let unit = item.unit, !unit.isEmpty { Text(unit).shelfNote() }
                }
            }
            if let reason = item.explanation {
                DisclosureGroup {
                    Text(reason).shelfNote().fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Why this item?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
                }
                .tint(Color.ink)
            }
        }
        .dibsCard(radius: 14, padding: 12)
    }
}
