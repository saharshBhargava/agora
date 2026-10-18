import SwiftUI
import Combine

@MainActor
final class ShoppingStore: ObservableObject {
    @Published private(set) var items: [WishlistItem] = []
    @Published private(set) var refreshStatus: ShoppingRefreshStatus?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var context = UUID()
    private let api: AgoraClient
    private let inventory: InventoryStore
    private var subscription: AnyCancellable?
    private var loadID = UUID()
    private var pending: [(body: [String: Any], key: String)] = []
    private var refreshKey: String?
    private var householdID: UUID?

    init(api: AgoraClient, inventory: InventoryStore) {
        self.api = api; self.inventory = inventory
        subscription = inventory.$householdID.combineLatest(inventory.$context)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.sink { [weak self] household, _ in
            guard let self else { return }
            self.householdID = household; self.context = UUID(); self.loadID = UUID()
            self.items = []; self.refreshStatus = nil; self.error = nil; self.notice = nil
            self.loading = false; self.busy = false; self.pending = []; self.refreshKey = nil
        }
    }
    var active: [WishlistItem] { items.filter { $0.status == "active" } }
    var suggestions: [WishlistItem] { items.filter { $0.status == "suggested" } }
    var snoozed: [WishlistItem] { items.filter { $0.status == "snoozed" } }
    var history: [WishlistItem] { items.filter { !$0.editable } }
    var canUse: Bool { householdID != nil }
    var hasPendingIdeas: Bool { !pending.isEmpty }

    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard context == version else { throw CancellationError() }
    }
    func refresh() async {
        guard let householdID else { return }
        let version = context, request = UUID(); loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        let query = [URLQueryItem(name: "household_id", value: householdID.uuidString)]
        do {
            let active = try await api.fetch("v1/wishlist", as: [WishlistItem].self,
                query: query + [.init(name: "status", value: "active"), .init(name: "limit", value: "200")])
            try check(version)
            let suggestions = try await api.fetch("v1/wishlist/suggestions", as: [WishlistItem].self,
                query: query + [.init(name: "include_snoozed", value: "true")])
            try check(version)
            let history = try await api.fetch("v1/wishlist", as: [WishlistItem].self,
                query: query + ["purchased", "removed", "rejected"].map { .init(name: "status", value: $0) })
            try check(version)
            guard loadID == request else { return }
            items = active + suggestions + history
            let state = try await api.fetch("v1/wishlist/refresh-status", as: ShoppingRefreshStatus.self, query: query)
            try check(version)
            guard loadID == request else { return }
            refreshStatus = state; error = nil
        } catch {
            guard version == context, loadID == request, !Task.isCancelled else { return }
            self.error = InventoryStore.message(error)
        }
    }
    private func update(_ item: WishlistItem) {
        loadID = UUID(); loading = false
        items.removeAll { $0.id == item.id }; items.append(item)
        items.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        error = nil
    }
    func save(_ draft: WishlistDraft, original: WishlistItem? = nil) async throws {
        guard let householdID, original == nil || original?.householdId == householdID else { throw CancellationError() }
        let version = context
        let row = try await api.fetch(original.map { "v1/wishlist/\($0.id)" } ?? "v1/wishlist", as: WishlistItem.self,
            method: original == nil ? "POST" : "PATCH", body: try draft.body(householdID: householdID, editing: original != nil))
        try check(version); update(row)
    }
    func act(_ item: WishlistItem, action: String, body: [String: Any]? = nil) async {
        guard !busy, item.householdId == householdID else { return }
        let version = context; busy = true; error = nil; notice = nil
        defer { if context == version { busy = false } }
        do {
            let path = "v1/wishlist/\(item.id)" + (action == "remove" ? "" : "/\(action)")
            let row = try await api.fetch(path, as: WishlistItem.self,
                                          method: action == "remove" ? "DELETE" : "POST", body: body)
            try check(version); update(row)
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func feedback(_ item: WishlistItem, rating: String) async {
        guard !busy, item.householdId == householdID else { return }
        let version = context; busy = true; error = nil
        defer { if context == version { busy = false } }
        do {
            let path = "v1/wishlist/\(item.id)/feedback"
            if item.myFeedback == rating {
                // DELETE returns 204, which the generic JSON client cannot decode.
                try await api.send(path, method: "DELETE")
            } else {
                _ = try await api.request(path, method: "POST", body: ["rating": rating])
            }
            try check(version); await refresh()
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func refreshSuggestions() async {
        guard !busy, let householdID else { return }
        let version = context; busy = true; error = nil; notice = nil
        defer { if context == version { busy = false } }
        let key = refreshKey ?? UUID().uuidString; refreshKey = key
        do {
            let state = try await api.fetch("v1/wishlist/refresh", as: ShoppingRefreshStatus.self, method: "POST",
                body: ["household_id": householdID.uuidString], key: key)
            try check(version); refreshStatus = state; refreshKey = nil
            await refresh(); try check(version)
            notice = state.generatedCount == 0 ? "You're up to date. No new replenishment suggestions." : "Added \(state.generatedCount) replenishment suggestions."
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func findIdeas(settings: SettingsStore) async {
        guard !busy, let householdID else { return }
        let version = context; busy = true; error = nil; notice = nil
        defer { if context == version { busy = false } }
        do {
            if pending.isEmpty {
                let modelConfiguration = settings.modelConfiguration
                let client = try settings.client(for: .suggestions)
                let feedback = try await api.fetch("v1/wishlist/agent-context", as: ModelJSON.self,
                    query: [.init(name: "household_id", value: householdID.uuidString)])
                try check(version)
                let snapshot = inventory.activeItems
                let candidates = try await SuggestionService(client: client).generate(inventory: snapshot,
                    feedback: feedback.foundation as? [String: Any] ?? [:])
                try check(version)
                guard snapshot == inventory.activeItems else { throw BrowserError("inventory_changed", "Your inventory changed while finding ideas. Try again for fresh suggestions.") }
                guard settings.modelConfiguration == modelConfiguration else { throw BrowserError("model_changed", "Model settings changed. Find ideas again.") }
                pending = candidates.map { (proposalBody($0, householdID: householdID), UUID().uuidString) }
            }
            var added = 0
            while let (body, key) = pending.first {
                try check(version)
                do {
                    let item = try await api.fetch("v1/wishlist/suggestions", as: WishlistItem.self, method: "POST", body: body, key: key)
                    try check(version); update(item); added += 1
                } catch let failure as BrowserError where ["already_on_wishlist", "recently_rejected", "too_many_suggestions"].contains(failure.code) {
                    try check(version)
                }
                pending.removeFirst()
            }
            notice = added == 0 ? "No new ideas to add right now." : "Added \(added) suggestions for you to review."
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    private func proposalBody(_ candidate: ShoppingCandidate, householdID: UUID) -> [String: Any] {
        let evidence = candidate.evidenceItemIds.compactMap { id -> [String: String]? in
            guard let item = inventory.activeItems.first(where: { $0.id == id }) else { return nil }
            return ["kind": "other", "detail": String("Inventory: \(item.displayName); \(item.quantityLabel)".prefix(200))]
        }
        var body: [String: Any] = ["household_id": householdID.uuidString, "title": candidate.title,
            "quantity": candidate.quantity, "rationale": candidate.rationale, "confidence": candidate.confidence, "evidence": evidence]
        if !candidate.category.isEmpty { body["category"] = candidate.category }
        return body
    }

    func execute(_ call: ShoppingCall, taskID: UUID) async throws -> [String: Any] {
        guard let householdID else { throw BrowserError("no_household", "Open Inventory to load your household first.") }
        let version = context
        if call.name == "shopping_context" {
            let feedback = try await api.fetch("v1/wishlist/agent-context", as: ModelJSON.self,
                query: [.init(name: "household_id", value: householdID.uuidString)])
            try check(version)
            return ["feedback": feedback.foundation, "inventory": inventory.activeItems.prefix(100).map { item -> [String: Any] in
                ["id": item.id.uuidString, "name": item.displayName, "quantity": item.quantity as Any? ?? NSNull(),
                 "unit": item.unit, "restock_level": item.parLevel as Any? ?? NSNull()]
            }]
        }
        let candidate = try call.candidate(inventoryIDs: Set(inventory.activeItems.map(\.id)))
        let row = try await api.fetch("v1/wishlist/suggestions", as: WishlistItem.self, method: "POST",
            body: proposalBody(candidate, householdID: householdID), key: try call.requestKey(taskID: taskID))
        try check(version); update(row)
        return ["id": row.id.uuidString, "title": row.title, "status": row.status,
                "message": "Saved for review in Suggested for you. This is not a purchase."]
    }

}
