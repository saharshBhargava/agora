import SwiftUI
import Combine

@MainActor
final class InventoryStore: ObservableObject {
    @Published private(set) var households: [InventoryHousehold] = []
    @Published private(set) var householdID: UUID?
    @Published private(set) var items: [InventoryItem] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var context = UUID()
    @Published private(set) var forecasts: [UUID: InventoryForecast] = [:]
    @Published private(set) var forecastError: String?
    @Published private(set) var forecastsLoading = false
    private let api: AgoraClient
    private(set) var accountID: String?
    private var loadID = UUID()
    private var forecastLoadID = UUID()
    private var accountSubscription: AnyCancellable?

    init(api: AgoraClient, calendar: CalendarConnection? = nil) {
        self.api = api
        if let calendar {
            accountSubscription = calendar.$accountID.combineLatest(calendar.$connected)
                .map { $0.1 ? $0.0 : nil }.removeDuplicates()
                .sink { [weak self] in self?.reset(accountID: $0) }
        }
    }
    var household: InventoryHousehold? { households.first { $0.id == householdID } }
    var locations: [InventoryLocation] { household?.locations ?? [] }
    var activeItems: [InventoryItem] { items.filter { $0.status == "active" } }

    func forecast(for item: InventoryItem) -> InventoryForecast? {
        guard let forecast = forecasts[item.id], forecast.matches(item) else { return nil }
        return forecast
    }

    func needsRestock(_ item: InventoryItem) -> Bool {
        item.status == "active" && (item.quantity == 0 || item.isRunningLow || forecast(for: item)?.runsOutSoon() == true)
    }

    var runningLowItems: [InventoryItem] { activeItems.filter(needsRestock).sorted(by: restockOrder) }

    func restockOrder(_ lhs: InventoryItem, _ rhs: InventoryItem) -> Bool {
        if (lhs.quantity == 0) != (rhs.quantity == 0) { return lhs.quantity == 0 }
        if needsRestock(lhs) != needsRestock(rhs) { return needsRestock(lhs) }
        let left = forecast(for: lhs).flatMap { $0.runsOutSoon() ? $0.runoutAt : nil }
        let right = forecast(for: rhs).flatMap { $0.runsOutSoon() ? $0.runoutAt : nil }
        if left != right { return (left ?? .distantFuture) < (right ?? .distantFuture) }
        return InventoryItem.restockOrder(lhs, rhs)
    }

    func stockSummary(_ item: InventoryItem) -> String {
        if item.quantity == 0 { return "Out of stock" }
        if let forecast = forecast(for: item), forecast.runsOutSoon() { return forecast.summary() }
        return item.stockSummary
    }

    func refreshWithForecasts() async {
        await refresh()
        guard !Task.isCancelled, error == nil else { return }
        await refreshForecasts()
    }

    func refreshForecasts() async {
        guard accountID != nil, let householdID, !activeItems.isEmpty else { return }
        let version = context, request = UUID()
        forecastLoadID = request; forecastsLoading = true
        defer { if forecastLoadID == request { forecastsLoading = false } }
        do {
            let result = try await api.fetch("v1/forecasts/runouts", as: InventoryRunouts.self, query: [
                URLQueryItem(name: "household_id", value: householdID.uuidString),
                URLQueryItem(name: "within", value: "7d")
            ])
            try check(version)
            guard forecastLoadID == request else { return }
            guard result.householdId == householdID, result.withinDays == 7 else {
                throw BrowserError("invalid_server_response")
            }
            var fresh: [UUID: InventoryForecast] = [:]
            for entry in result.runouts {
                guard entry.item.householdId == householdID,
                      let item = items.first(where: { $0.id == entry.item.id }),
                      entry.forecast.matches(item), entry.forecast.runsOutSoon() else { continue }
                fresh[item.id] = entry.forecast
            }
            forecasts = fresh; forecastError = nil
        } catch {
            guard version == context, forecastLoadID == request, !Task.isCancelled else { return }
            forecasts = [:]
            forecastError = "Run-out estimates are unavailable. Showing recorded stock levels."
        }
    }

    func reset(accountID: String?) {
        self.accountID = accountID
        context = UUID(); loadID = UUID()
        households = []; householdID = nil; items = []; error = nil; loading = false
        clearForecasts()
    }

    func refresh() async {
        guard accountID != nil else { return }
        let version = context, request = UUID()
        loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        do {
            let profile = try await api.fetch("v1/me", as: InventoryProfile.self)
            try check(version)
            guard loadID == request else { return }
            households = profile.households
            let selected = householdID.flatMap { id in households.first { $0.id == id }?.id } ?? households.first?.id
            householdID = selected
            guard let selected else {
                items = []; error = "No household is available for this account."; return
            }
            let result = try await api.fetch("v1/inventory", as: [InventoryItem].self, query: [
                URLQueryItem(name: "household_id", value: selected.uuidString),
                URLQueryItem(name: "include_archived", value: "true")
            ])
            try check(version)
            guard loadID == request else { return }
            items = result; error = nil
            forecasts = forecasts.filter { id, forecast in result.contains { $0.id == id && forecast.matches($0) } }
        } catch {
            guard context == version, loadID == request, !Task.isCancelled else { return }
            self.error = Self.message(error)
        }
    }

    func selectHousehold(_ id: UUID) async {
        guard households.contains(where: { $0.id == id }), householdID != id else { return }
        context = UUID(); loadID = UUID(); householdID = id; items = []; error = nil
        clearForecasts()
        await refresh()
    }

    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard version == context else { throw CancellationError() }
    }

    private func upsert(_ item: InventoryItem) {
        // Invalidate reads started before this write completed.
        loadID = UUID(); loading = false
        forecastLoadID = UUID(); forecastsLoading = false
        forecasts[item.id] = nil
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        error = nil
    }

    private func clearForecasts() {
        forecastLoadID = UUID(); forecasts = [:]; forecastError = nil; forecastsLoading = false
    }

    func save(_ draft: InventoryDraft, original: InventoryItem?) async throws -> InventoryItem {
        guard let householdID else { throw BrowserError("no_household", "Choose a household first.") }
        let version = context
        let body = try draft.body(householdID: householdID, editing: original)
        if let original, body.isEmpty { return original }
        if let original, original.householdId != householdID { throw CancellationError() }
        let item = try await api.fetch(original.map { "v1/inventory/\($0.id)" } ?? "v1/inventory",
                                       as: InventoryItem.self, method: original == nil ? "POST" : "PATCH", body: body)
        try check(version)
        upsert(item)
        return item
    }

    func addFromChat(title: String, quantity: Double?, unit: String?, key: String) async throws -> InventoryItem {
        guard let householdID else { throw BrowserError("no_household") }
        let version = context
        var body: [String: Any] = ["household_id": householdID.uuidString, "display_name": title, "unit": unit ?? "unit"]
        if let quantity { body["quantity"] = quantity }
        let item = try await api.fetch("v1/inventory", as: InventoryItem.self, method: "POST", body: body, key: key)
        try check(version)
        guard item.householdId == householdID else { throw BrowserError("invalid_server_response") }
        upsert(item)
        return item
    }

    func setArchived(_ item: InventoryItem, archived: Bool) async throws {
        guard item.householdId == householdID else { throw CancellationError() }
        let version = context
        let updated = try await api.fetch("v1/inventory/\(item.id)", as: InventoryItem.self, method: "PATCH",
                                          body: ["status": archived ? "archived" : "active"])
        try check(version)
        upsert(updated)
    }

    func updateQuantity(_ item: InventoryItem, quantity: Double) async throws {
        guard quantity.isFinite, (0...10_000).contains(quantity) else { throw BrowserError("invalid_quantity") }
        guard item.householdId == householdID else { throw CancellationError() }
        let version = context
        let observation = try await api.fetch("v1/inventory/\(item.id)/observations", as: InventoryObservation.self,
                                              method: "POST", body: ["quantity": quantity])
        try check(version)
        var updated = items.first { $0.id == item.id } ?? item
        updated.quantity = observation.quantity; updated.observedAt = observation.time; updated.source = observation.source
        upsert(updated)
    }

    func detail(_ id: UUID, days: Int) async throws -> InventoryDetail {
        let version = context
        let detail = try await api.fetch("v1/inventory/\(id)", as: InventoryDetail.self,
                                         query: [URLQueryItem(name: "days", value: String(days))])
        try check(version)
        guard detail.item.householdId == householdID else { throw CancellationError() }
        return detail
    }

    func addLocation(name: String, kind: String) async throws -> InventoryLocation {
        guard let householdID else { throw BrowserError("no_household") }
        let version = context
        let location = try await api.fetch("v1/households/\(householdID)/locations", as: InventoryLocation.self,
                                           method: "POST", body: ["name": name, "kind": kind])
        try check(version)
        // Invalidate reads started before this write completed (same as upsert).
        loadID = UUID(); loading = false
        if let index = households.firstIndex(where: { $0.id == householdID }) {
            households[index].locations.append(location)
        }
        return location
    }

    func merchants(search: String) async throws -> [InventoryMerchant] {
        guard let householdID else { return [] }
        let version = context
        let result = try await api.fetch("v1/merchants", as: [InventoryMerchant].self, query: [
            URLQueryItem(name: "household_id", value: householdID.uuidString),
            URLQueryItem(name: "q", value: search), URLQueryItem(name: "limit", value: "50")
        ])
        try check(version)
        return result
    }

    func merchant(_ id: UUID) async throws -> InventoryMerchant {
        let version = context
        let result = try await api.fetch("v1/merchants/\(id)", as: InventoryMerchant.self)
        try check(version)
        return result
    }

    func addMerchant(name: String, locality: String) async throws -> InventoryMerchant {
        guard let householdID else { throw BrowserError("no_household") }
        struct Result: Decodable { let merchant: InventoryMerchant }
        let version = context
        let result = try await api.fetch("v1/merchants", as: Result.self, method: "POST", body: [
            "name": name, "locality": locality, "household_id": householdID.uuidString
        ])
        try check(version)
        return result.merchant
    }

    func saveRecognition(_ recognition: SavedRecognition) async throws -> RecognitionResult {
        guard recognition.accountID == accountID, recognition.householdID == householdID else { throw CancellationError() }
        let version = context
        let result = try await api.fetch("v1/inventory/recognitions", as: RecognitionResult.self, method: "POST",
                                          body: recognition.body, key: recognition.key.uuidString)
        try check(version)
        for item in result.items { upsert(item) }
        return result
    }

    static func message(_ error: Error) -> String {
        if let error = error as? BrowserError, !error.detail.isEmpty { return error.detail }
        return "Couldn’t update inventory. Please refresh and try again."
    }
}
