import Foundation

// "For your next run" on Home: a few lines from the household's pantry (running low, or predicted to run out
// soon from its quantity history), wishlist and suggestions. Pure, so the choice and order are unit tested.

/// One line on the "For your next run" card. Tapping it pushes `page`.
struct NextRunRow: Identifiable, Equatable {
    let id: String
    let name: String
    /// The short muted reason under the name ("Running low", "Target price", a suggestion's rationale).
    let reason: String
    /// A target price, shown large on the right; nil when there is none.
    var amount: String?
    let page: HouseholdPage
    /// The item behind the line, for its photo tile: the image service's kind ("inventory", "wishlist") and id.
    var image: NextRunImage?
}

struct NextRunImage: Equatable {
    let kind: String
    let id: UUID
    var category: String?
}

enum NextRunPicks {
    static let lowLimit = 3
    static let wishLimit = 3
    static let suggestionLimit = 2

    /// Up to 3 running-low items, then up to 3 wishlist items, then up to 2 suggestions. A name already
    /// shown (a suggestion to restock something that is running low, say) is not repeated.
    ///
    /// `forecast` is the item's current run-out prediction (`InventoryStore.forecast(for:)`): an item predicted
    /// to run out within a week counts as running low even above its restock level, says so as its reason
    /// ("May run out in 3 days"), and sorts by when it runs out.
    static func rows(inventory: [InventoryItem], wishlist: [WishlistItem], suggestions: [WishlistItem],
                     forecast: (InventoryItem) -> InventoryForecast? = { _ in nil }, now: Date = Date()) -> [NextRunRow] {
        var rows: [NextRunRow] = []
        var seen = Set<String>()
        /// Adds up to `limit` rows from `candidates`, skipping names already shown.
        func take<T>(_ candidates: [T], limit: Int, name: (T) -> String, row: (T) -> NextRunRow) {
            var taken = 0
            for candidate in candidates where taken < limit {
                guard seen.insert(key(name(candidate))).inserted else { continue }
                rows.append(row(candidate))
                taken += 1
            }
        }
        take(lowItems(inventory, forecast: forecast, now: now), limit: lowLimit, name: \.displayName) { item in
            let soon = forecast(item).flatMap { $0.runsOutSoon(at: now) ? $0 : nil }
            return NextRunRow(id: "low-\(item.id)", name: item.displayName,
                              reason: item.quantity == 0 || soon == nil ? "Running low" : soon!.summary(at: now), page: .pantry,
                              image: NextRunImage(kind: "inventory", id: item.id, category: item.category))
        }
        take(wishlist.filter { $0.status == "active" }, limit: wishLimit, name: \.title) {
            NextRunRow(id: "wish-\($0.id)", name: $0.title, reason: $0.targetLabel == nil ? "On your wishlist" : "Target price",
                       amount: $0.targetLabel, page: .wishlist, image: NextRunImage(kind: "wishlist", id: $0.id, category: $0.category))
        }
        take(suggestions.filter { $0.status == "suggested" }, limit: suggestionLimit, name: \.title) {
            NextRunRow(id: "idea-\($0.id)", name: $0.title, reason: reason($0.rationale) ?? "Suggested for you",
                       amount: $0.targetLabel, page: .wishlist, image: NextRunImage(kind: "wishlist", id: $0.id, category: $0.category))
        }
        return rows
    }

    /// Active items below their restock level or predicted to run out within a week. Out of stock first, then
    /// the soonest predicted run-out, then the emptiest, then by name (the old Agora Home's order).
    static func lowItems(_ inventory: [InventoryItem], forecast: (InventoryItem) -> InventoryForecast? = { _ in nil },
                         now: Date = Date()) -> [InventoryItem] {
        func runout(_ item: InventoryItem) -> Date? {
            forecast(item).flatMap { $0.runsOutSoon(at: now) ? $0.runoutAt : nil }
        }
        return inventory.filter { $0.isRunningLow || ($0.status == "active" && runout($0) != nil) }.sorted {
            if ($0.quantity == 0) != ($1.quantity == 0) { return $0.quantity == 0 }
            let left = runout($0), right = runout($1)
            if left != right { return (left ?? .distantFuture) < (right ?? .distantFuture) }
            if $0.quantity == $1.quantity {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return ($0.quantity ?? 0) < ($1.quantity ?? 0)
        }
    }

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A rationale on one line: whitespace collapsed; nil when blank.
    private static func reason(_ text: String?) -> String? {
        let words = text?.split(whereSeparator: \.isWhitespace) ?? []
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
