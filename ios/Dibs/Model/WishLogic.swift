import Foundation

/// The "+ Wish" page's rules (canvas Wish.dc.html), on plain values so they can be tested.
///
/// The page shows the household's shopping list (when the server has one) and suggestions from
/// `GET /api/runs/:id/wish-picks`. Anything in the cart is hidden, live, as the shopper adds it. Anything
/// I wished in this run, or just wished on this page, is marked Wished. The phone's own usual picks
/// appear only when the server offered nothing at all.
enum WishLogic {
    enum Kind: Equatable, Sendable { case list, suggested, usual }
    /// The trailing control: a "+" to wish, or the blue check once wished.
    enum Mark: Equatable, Sendable { case add, wished }

    struct Row: Identifiable, Equatable, Sendable {
        let name: String
        let key: String
        let kind: Kind
        /// Under the name: the list quantity ("2 bottles"), the suggestion's reason, or "".
        let note: String
        let mark: Mark

        var id: String { "\(kind)-\(key)" }
        /// The second line: the note, or "Wished · in your tray when added" once wished.
        var line: String { mark == .wished ? WishLogic.wishedLine : note }
        var pill: String {
            switch kind {
            case .list: return "On your list"
            case .suggested: return "Suggested"
            case .usual: return "Usual pick"
            }
        }
    }

    struct Sections: Equatable {
        /// "Household essentials · Target"; nil when there is no list section.
        var listCaption: String?
        var list: [Row] = []
        /// Shown in the list section when the list has nothing left to offer.
        var listEmpty: String?
        var suggestions: [Row] = []
        var suggestionsCaption = "From your runs"
        /// The phone's usual picks: only when the server offered no list items and no suggestions.
        var usual: [Row] = []
        /// Nothing at all to offer.
        var empty: String?
    }

    static let wishedLine = "Wished · in your tray when added"
    static let noList = "No list yet — type anything above"
    static let listInCart = "Everything on your list is in the cart"
    static let usualNote = "In your recent runs"
    static let maxRows = 12

    /// The comparison key for an item name: the server's rule (server/src/wish-picks.ts `pickKey`).
    static func key(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// "It lands in your tray when Jake adds it."
    static func subtitle(shopperName: String?) -> String {
        let who = shopperName.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 } ?? "the shopper"
        return "It lands in your tray when \(who) adds it."
    }

    /// "Household essentials · Target", or just the list's name.
    static func listCaption(_ list: WishPicks.List) -> String {
        guard let store = list.store?.trimmingCharacters(in: .whitespaces), !store.isEmpty else { return list.name }
        return "\(list.name) · \(store)"
    }

    /// After typing a wish: "Wished Bagels · in your tray when added".
    static func confirmation(_ name: String) -> String { "Wished \(name) · in your tray when added" }

    /// Keys of the items in the cart now (not wishes, removed, identifying, dropped or put back).
    static func cartKeys(_ run: Run) -> Set<String> {
        Set(run.chips.filter { c in
            c.state != .wish && c.state != .removed && c.state != .identifying && !c.dropped && !c.putBack
        }.map { key($0.name) }.filter { !$0.isEmpty })
    }

    /// Keys of my wishes still waiting in this run. The server records the shopper's own wishes as nobody's.
    static func wishedKeys(_ run: Run, me: String) -> Set<String> {
        let mine: String? = me == run.shopperId ? nil : me
        return Set(run.chips.filter { $0.state == .wish && $0.wishedBy == mine }.map { key($0.name) }.filter { !$0.isEmpty })
    }

    /// The page for this run. `picks` nil means not loaded or failed; `justWished` holds keys wished on
    /// this page (shown as Wished before the run update arrives); `usual` is the phone's history, newest first.
    static func sections(picks: WishPicks?, run: Run, me: String, justWished: Set<String> = [], usual: [String] = []) -> Sections {
        let cart = cartKeys(run)
        let wished = wishedKeys(run, me: me).union(justWished)
        var taken = Set<String>()
        func rows(_ items: [(name: String, note: String)], _ kind: Kind) -> [Row] {
            var out: [Row] = []
            for item in items {
                let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let k = key(name)
                guard !k.isEmpty, !cart.contains(k), !taken.contains(k), out.count < maxRows else { continue }
                taken.insert(k)
                out.append(Row(name: name, key: k, kind: kind, note: item.note, mark: wished.contains(k) ? .wished : .add))
            }
            return out
        }

        var s = Sections()
        if let list = picks?.list {
            s.listCaption = listCaption(list)
            s.list = rows(list.items.map { ($0.name, $0.detail) }, .list)
            if s.list.isEmpty { s.listEmpty = listInCart }
            s.suggestionsCaption = "From your home"
        }
        s.suggestions = rows((picks?.suggestions ?? []).map { ($0.name, $0.reason) }, .suggested)
        if s.list.isEmpty && s.suggestions.isEmpty {
            s.usual = rows(usual.map { ($0, usualNote) }, .usual)
            if s.listCaption == nil && s.usual.isEmpty { s.empty = noList }
        }
        return s
    }
}
