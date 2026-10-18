import Foundation

// "For your next run" on Home: a few lines from the household's pantry, wishlist and suggestions.
// Pure, so the choice and order are unit tested.

/// One line on the "For your next run" card. Tapping it pushes `page`.
struct NextRunRow: Identifiable, Equatable {
    let id: String
    let name: String
    /// The short muted reason under the name ("Running low", "Target price", a suggestion's rationale).
    let reason: String
    /// A target price, shown large on the right; nil when there is none.
    var amount: String?
    let page: HouseholdPage
}

enum NextRunPicks {
    static let lowLimit = 3
    static let wishLimit = 3
    static let suggestionLimit = 2

    /// Up to 3 running-low items, then up to 3 wishlist items, then up to 2 suggestions. A name already
    /// shown (a suggestion to restock something that is running low, say) is not repeated.
    static func rows(inventory: [InventoryItem], wishlist: [WishlistItem], suggestions: [WishlistItem]) -> [NextRunRow] {
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
        take(lowItems(inventory), limit: lowLimit, name: \.displayName) {
            NextRunRow(id: "low-\($0.id)", name: $0.displayName, reason: "Running low", page: .pantry)
        }
        take(wishlist.filter { $0.status == "active" }, limit: wishLimit, name: \.title) {
            NextRunRow(id: "wish-\($0.id)", name: $0.title, reason: $0.targetLabel == nil ? "On your wishlist" : "Target price",
                       amount: $0.targetLabel, page: .wishlist)
        }
        take(suggestions.filter { $0.status == "suggested" }, limit: suggestionLimit, name: \.title) {
            NextRunRow(id: "idea-\($0.id)", name: $0.title, reason: reason($0.rationale) ?? "Suggested for you",
                       amount: $0.targetLabel, page: .wishlist)
        }
        return rows
    }

    /// Items below their restock level, the emptiest first, then by name (the old Agora Home's order).
    static func lowItems(_ inventory: [InventoryItem]) -> [InventoryItem] {
        inventory.filter(\.isRunningLow).sorted {
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
