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
    private let api: AgoraClient
    private(set) var accountID: String?
    private var loadID = UUID()
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

    func reset(accountID: String?) {
        self.accountID = accountID
        context = UUID(); loadID = UUID()
        households = []; householdID = nil; items = []; error = nil; loading = false
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
        } catch {
            guard context == version, loadID == request, !Task.isCancelled else { return }
            self.error = Self.message(error)
        }
    }

    func selectHousehold(_ id: UUID) async {
        guard households.contains(where: { $0.id == id }), householdID != id else { return }
        context = UUID(); loadID = UUID(); householdID = id; items = []; error = nil
        await refresh()
    }

    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard version == context else { throw CancellationError() }
    }

    private func upsert(_ item: InventoryItem) {
        // Invalidate reads started before this write completed.
        loadID = UUID(); loading = false
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index] = item }
        else { items.append(item) }
        error = nil
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
