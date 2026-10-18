import SwiftUI
import Combine

@MainActor
final class TripStore: ObservableObject {
    @Published private(set) var lists: [TripList] = []
    @Published private(set) var trips: [TripRecord] = []
    @Published private(set) var proposals: [TripProposal] = []
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var context = UUID()
    private let api: AgoraClient
    let inventory: InventoryStore
    private let calendar: CalendarConnection
    private var subscriptions: Set<AnyCancellable> = []
    private var householdID: UUID?
    private var accountID: String?
    private var loadID = UUID()
    private var generationKey: String?
    private var reservationInDoubt = false
    private let now: () -> Date

    init(api: AgoraClient, inventory: InventoryStore, calendar: CalendarConnection, now: @escaping () -> Date = Date.init) {
        self.api = api; self.inventory = inventory; self.calendar = calendar; self.now = now
        inventory.$householdID.combineLatest(inventory.$context)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.sink { [weak self] household, _ in
            self?.reset(household: household, account: calendar.connected ? calendar.accountID : nil)
        }.store(in: &subscriptions)
        calendar.$accountID.combineLatest(calendar.$connected)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.sink { [weak self] account, connected in
            guard let self else { return }
            self.reset(household: self.inventory.householdID, account: connected ? account : nil)
        }.store(in: &subscriptions)
    }
    var canUse: Bool { householdID != nil && accountID != nil }

    private func reset(household: UUID?, account: String?) {
        householdID = household; accountID = account; context = UUID(); loadID = UUID()
        lists = []; trips = []; proposals = []; error = nil; notice = nil
        loading = false; busy = false; generationKey = nil; reservationInDoubt = false
    }
    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard version == context, calendar.connected, calendar.accountID == accountID,
              householdID == inventory.householdID else { throw CancellationError() }
    }
    private func read(_ version: UUID) async throws -> ([TripList], [TripRecord]) {
        guard let householdID else { throw CancellationError() }
        let query = [URLQueryItem(name: "household_id", value: householdID.uuidString)]
        let lists = try await api.fetch("v1/lists", as: [TripList].self, query: query)
        try check(version)
        let trips = try await api.fetch("v1/trips", as: [TripRecord].self, query: query)
        try check(version)
        guard lists.allSatisfy({ $0.householdId == householdID && CalendarCall.date($0.updatedAt) != nil }),
              trips.allSatisfy({ $0.householdId == householdID && ["reserved", "scheduled", "outcome_unknown", "failed"].contains($0.status)
                  && (try? $0.calendarCall()) != nil }) else {
            throw BrowserError("invalid_server_response")
        }
        return (lists, trips)
    }
    func refresh() async {
        guard canUse, !busy else { return }
        let version = context, request = UUID(); loadID = request; loading = true
        defer { if context == version, loadID == request { loading = false } }
        do {
            let result = try await read(version)
            guard loadID == request else { return }
            lists = result.0; trips = result.1
            proposals.removeAll { proposal in
                !lists.contains(where: { $0.id == proposal.id && $0.updatedAt == proposal.list.updatedAt && $0.status == "open" })
                    || trips.contains(where: { $0.listId == proposal.id && $0.blocksNewTrip(at: now()) })
                    || (proposal.start.map { $0 <= now() } ?? false)
            }
            reservationInDoubt = false; error = nil
            if trips.contains(where: { $0.mine && $0.isUncertain }) {
                notice = "A previous trip needs verification. Check its Calendar status; adding it again is blocked."
            }
        } catch { if loadID == request { report(error, version: version) } }
    }
    func plan(options: TripPlanningOptions) async {
        guard canUse, !busy, let householdID, let accountID else { return }
        let version = context; busy = true; loading = false; loadID = UUID(); error = nil; notice = nil; proposals = []
        defer { if context == version { busy = false } }
        do {
            try options.validate()
            if generationKey == nil { generationKey = UUID().uuidString }
            _ = try await api.request("v1/lists/generate", method: "POST", body: [
                "household_id": householdID.uuidString, "within_days": 7
            ], key: generationKey)
            try check(version); generationKey = nil
            // Generate returns only newly changed lists; fetch all lists before selecting stores.
            let result = try await read(version)
            lists = result.0; trips = result.1; reservationInDoubt = false
            let planningTime = now()
            let window = try TripPlanner.window(options: options, now: planningTime)
            let availability = try await calendar.execute(availabilityCall(window, timezone: options.timezone),
                                                          taskID: UUID(), expectedAccountID: accountID)
            try check(version)
            let intervals = try TripBusyInterval.decode(availability)
            proposals = try TripPlanner.propose(lists: lists, trips: trips, busy: intervals, options: options,
                                               now: planningTime, context: version)
            if proposals.isEmpty { notice = "No open shopping lists need a new trip. Existing trips are shown below." }
        } catch { report(error, version: version) }
    }
    private func availabilityCall(_ interval: TripBusyInterval, timezone: String) throws -> CalendarCall {
        try CalendarCall(["name": "calendar_freebusy", "args": [
            "start": TripPlanner.timestamp(interval.start, timezone: timezone),
            "end": TripPlanner.timestamp(interval.end, timezone: timezone), "timezone": timezone
        ]])
    }
    /// Only call after the user has reviewed and explicitly approved this proposal.
    func schedule(_ proposal: TripProposal) async {
        guard !busy, !reservationInDoubt, proposal.context == context, proposal.canSchedule,
              proposal.list.householdId == householdID, let accountID,
              proposals.contains(where: { $0.reservationKey == proposal.reservationKey }),
              !trips.contains(where: { $0.listId == proposal.list.id && $0.blocksNewTrip(at: now()) }) else { return }
        let version = context; busy = true; error = nil; notice = nil; loadID = UUID(); loading = false
        defer { if context == version { busy = false } }
        var reserved: TripRecord?
        var eventCallStarted = false
        var eventConfirmed = false
        do {
            let call = try proposal.calendarCall()
            guard let start = proposal.start, let end = proposal.end, start > now() else {
                throw BrowserError("trip_time_passed", "This slot has already started. Plan again.")
            }
            let availability = try await calendar.execute(availabilityCall(.init(start: start, end: end), timezone: proposal.timezone),
                                                          taskID: UUID(), expectedAccountID: accountID)
            try check(version)
            guard try TripBusyInterval.decode(availability).allSatisfy({ $0.end <= start || $0.start >= end }) else {
                proposals = []
                throw BrowserError("trip_conflict", "Your Calendar changed and this slot is busy. Plan again to choose another time.")
            }
            var body = call.arguments
            body["list_id"] = proposal.list.id.uuidString; body["list_updated_at"] = proposal.list.updatedAt
            // A lost reservation reply must be recovered by a read, never by a fresh approval/create.
            reservationInDoubt = true
            let trip = try await api.fetch("v1/trips", as: TripRecord.self, method: "POST", body: body, key: proposal.reservationKey)
            try check(version)
            guard trip.householdId == householdID, trip.listId == proposal.list.id, trip.mine,
                  trip.status == "reserved", trip.calendarArguments as NSDictionary == call.arguments as NSDictionary else {
                throw BrowserError("trip_changed", "The reserved trip changed. Verify its Calendar status before continuing.")
            }
            upsert(trip); reserved = trip; proposals.removeAll { $0.id == proposal.id }
            reservationInDoubt = false
            try check(version)
            eventCallStarted = true
            let event = try await calendar.execute(try trip.calendarCall(), taskID: trip.id, expectedAccountID: accountID)
            eventConfirmed = true
            try check(version)
            try await outcome(trip, status: "scheduled", event: event, version: version)
            notice = "Shopping trip added to Calendar."
        } catch {
            guard context == version else { return }
            if let reserved {
                // Even cancellation or a missed outcome save after the external call is uncertain.
                let uncertain = eventCallStarted && (eventConfirmed || !Self.definiteRejection(error))
                let status = uncertain ? "outcome_unknown" : "failed"
                if uncertain {
                    var uncertain = reserved; uncertain.status = status; upsert(uncertain)
                    notice = "Calendar may already contain this trip. Verify its status before scheduling another trip for this list."
                }
                if !Task.isCancelled { try? await outcome(reserved, status: status, event: nil, version: version) }
            } else if reservationInDoubt {
                proposals = []
                notice = "Could not confirm the trip reservation. Refresh to recover it before trying again."
            }
            report(error, version: version)
        }
    }
    func reconcile(_ trip: TripRecord) async {
        guard !busy, trip.mine, trip.isUncertain, trip.householdId == householdID,
              trips.contains(where: { $0.id == trip.id && $0.isUncertain }), let accountID else { return }
        let version = context; busy = true; error = nil; notice = nil
        defer { if context == version { busy = false } }
        do {
            let event = try await calendar.lookupExistingEvent(try trip.calendarCall(), taskID: trip.id, expectedAccountID: accountID)
            try check(version)
            guard let event else {
                notice = "No matching event could be verified. Check Calendar; this list remains blocked to prevent a duplicate trip."
                return
            }
            try await outcome(trip, status: "scheduled", event: event, version: version)
            notice = "Existing Calendar event verified. No new event was created."
        } catch { report(error, version: version) }
    }
    /// The user approves the original saved details again. A reserved trip always reuses its original event identity.
    func resume(_ trip: TripRecord) async {
        guard !busy, trip.mine, trip.status == "reserved", trip.householdId == householdID,
              trips.contains(where: { $0.id == trip.id && $0.status == "reserved" }), let accountID else { return }
        let version = context; busy = true; error = nil; notice = nil
        defer { if context == version { busy = false } }
        var eventCallStarted = false
        var eventConfirmed = false
        do {
            let call = try trip.calendarCall()
            let existing = try await calendar.lookupExistingEvent(call, taskID: trip.id, expectedAccountID: accountID)
            try check(version)
            if let existing {
                try await outcome(trip, status: "scheduled", event: existing, version: version)
                notice = "Existing Calendar event verified. No new event was created."
                return
            }
            guard let start = trip.startDate, let end = trip.endDate, start > now() else {
                throw BrowserError("trip_time_passed", "The original slot has already started. Check Calendar before releasing this reservation.")
            }
            let availability = try await calendar.execute(availabilityCall(.init(start: start, end: end), timezone: trip.timezone),
                                                          taskID: UUID(), expectedAccountID: accountID)
            try check(version)
            guard try TripBusyInterval.decode(availability).allSatisfy({ $0.end <= start || $0.start >= end }) else {
                throw BrowserError("trip_conflict", "The original slot is now busy. The reservation is retained; no new event was added.")
            }
            eventCallStarted = true
            let event = try await calendar.execute(call, taskID: trip.id, expectedAccountID: accountID)
            eventConfirmed = true
            try check(version)
            try await outcome(trip, status: "scheduled", event: event, version: version)
            notice = "Shopping trip added to Calendar."
        } catch {
            guard context == version else { return }
            if eventCallStarted {
                let status = !eventConfirmed && Self.definiteRejection(error) ? "failed" : "outcome_unknown"
                var local = trip; local.status = status; upsert(local)
                if !Task.isCancelled { try? await outcome(trip, status: status, event: nil, version: version) }
            }
            report(error, version: version)
        }
    }
    private static func definiteRejection(_ error: Error) -> Bool {
        guard let error = error as? BrowserError else { return false }
        return ["calendar_reconnect_required", "calendar_access_denied", "calendar_request_failed",
                "invalid_calendar_time", "invalid_calendar_details", "missing_event_title",
                "integration_unavailable", "invalid_credentials"].contains(error.code)
    }
    private func outcome(_ trip: TripRecord, status: String, event: [String: Any]?, version: UUID) async throws {
        try check(version)
        var body: [String: Any] = ["status": status]
        if let id = event?["id"] as? String { body["event_id"] = id }
        if let url = event?["url"] as? String { body["event_url"] = url }
        let result = try await api.fetch("v1/trips/\(trip.id)/outcome", as: TripRecord.self, method: "PATCH", body: body)
        try check(version); upsert(result)
    }
    func createList(name: String, merchantID: UUID?) async throws -> UUID {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else {
            throw BrowserError("invalid_list", "Enter a list name of 1–80 characters.")
        }
        guard canUse, !busy, let householdID else { throw CancellationError() }
        let version = context
        busy = true; loadID = UUID(); loading = false; error = nil; notice = nil
        defer { if context == version { busy = false } }
        var body: [String: Any] = ["name": name, "household_id": householdID.uuidString]
        if let merchantID { body["merchant_id"] = merchantID.uuidString }
        let list = try await api.fetch("v1/lists", as: TripList.self, method: "POST", body: body)
        try check(version)
        guard list.householdId == householdID else { throw BrowserError("invalid_server_response") }
        lists.insert(list, at: 0); proposals = []
        return list.id
    }

    func addItem(listID: UUID, draft: TripItemDraft) async throws {
        let body = try draft.body()
        guard canUse, !busy, let index = lists.firstIndex(where: { $0.id == listID && $0.status == "open" }) else {
            throw BrowserError("list_unavailable", "Refresh and choose an open shopping list.")
        }
        let version = context
        busy = true; loadID = UUID(); loading = false; error = nil; notice = nil
        defer { if context == version { busy = false } }
        let item = try await api.fetch("v1/lists/\(listID)/items", as: TripListItem.self, method: "POST", body: body)
        try check(version)
        // Retain the confirmed write even if the subsequent refresh fails. Never repeat the POST.
        lists[index].items.append(item); lists[index].openCount += item.checked ? 0 : 1
        proposals = []
        do {
            let list = try await api.fetch("v1/lists/\(listID)", as: TripList.self)
            try check(version)
            guard list.id == listID, list.householdId == householdID else { throw BrowserError("invalid_server_response") }
            lists[index] = list
        } catch {
            try check(version)
            notice = "Item saved. Pull to refresh for the latest list."
        }
    }

    func setChecked(listID: UUID, itemID: UUID, checked: Bool) async {
        guard canUse, !busy, let list = lists.first(where: { $0.id == listID }), list.status == "open",
              list.items.contains(where: { $0.id == itemID }) else { return }
        let version = context; busy = true; error = nil
        defer { if context == version { busy = false } }
        do {
            _ = try await api.fetch("v1/lists/\(listID)/items/\(itemID)", as: TripListItem.self,
                                    method: "PATCH", body: ["checked": checked])
            try check(version)
            let result = try await read(version)
            lists = result.0; trips = result.1; proposals = []
        } catch { report(error, version: version) }
    }
    private func upsert(_ trip: TripRecord) {
        trips.removeAll { $0.id == trip.id }; trips.append(trip)
        trips.sort { $0.start < $1.start }
    }
    private func report(_ error: Error, version: UUID) {
        guard context == version, !(error is CancellationError), !Task.isCancelled else { return }
        self.error = (error as? BrowserError).flatMap { $0.detail.isEmpty ? nil : $0.detail }
            ?? "Could not update shopping trips. Refresh and try again."
    }
}
