import SwiftUI

struct TripsView: View {
    @ObservedObject var store: TripStore
    @State private var options = TripPlanningOptions()
    @State private var reviewing: TripProposal?

    var body: some View {
        List {
            Section {
                Text("Turn the items running out into store lists, then find time to shop. Review each trip before adding it to your calendar.")
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
                    Text("Find shopping times to make lists from your upcoming run-outs. If nothing is running out, no new list is needed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.lists) { list in
                    NavigationLink {
                        TripListView(store: store, listID: list.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(list.storeName).font(.headline)
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
        .navigationTitle("Shopping trips")
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .onChange(of: store.context) { _, _ in reviewing = nil }
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
                    } footer: {
                        Text("Checks for this exact event first. If it has not been saved, checks your availability and submits the same saved request.")
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

private struct TripListView: View {
    @ObservedObject var store: TripStore
    let listID: UUID
    private var list: TripList? { store.lists.first { $0.id == listID } }
    var body: some View {
        List {
            if let list {
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
        }
        .navigationTitle(list?.storeName ?? "Shopping list")
        .refreshable { await store.refresh() }
    }
}
