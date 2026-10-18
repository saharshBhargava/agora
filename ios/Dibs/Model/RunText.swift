import Foundation

/// Copy built from a run, matching the web app (web/lib/tile.ts, web/lib/share.ts).
public enum RunText {
    /// The hold each person puts on their card by default.
    public static let holdCents = 4000
    /// The hold choices on the join screen.
    public static let capOptions = [2000, 4000, 6000]

    /// "Costco" from "costco".
    public static func capitalize(_ s: String) -> String {
        guard let first = s.first else { return s }
        return first.uppercased() + s.dropFirst()
    }

    /// "Jake's Costco run", "The Costco run", "Jake's run".
    public static func title(shopperName: String?, store: String) -> String {
        let who = shopperName.map { "\($0)'s" } ?? "The"
        return store.isEmpty ? "\(who) run" : "\(who) \(capitalize(store)) run"
    }

    /// "Your Costco run is open".
    public static func openHeadline(store: String) -> String {
        store.isEmpty ? "Your run is open" : "Your \(capitalize(store)) run is open"
    }

    /// "Priya", "Priya and Marcus", "Priya, Marcus and Lee".
    public static func listNames(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// "Jake is shopping · Priya and Marcus are in", leaving out `excluding` (the person joining).
    public static func whoLine(run: Run, excluding: String?) -> String {
        let others = run.claimers.filter { $0.id != excluding }.map(\.name)
        var parts: [String] = []
        if let shopper = run.shopper { parts.append("\(shopper.name) is shopping") }
        if !others.isEmpty { parts.append("\(listNames(others)) \(others.count == 1 ? "is" : "are") in") }
        return parts.joined(separator: " · ")
    }

    /// The avatar initial the server would give this name.
    public static func initial(of name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    /// "In the cart so far": the newest three live chips.
    public static func cartTiles(_ run: Run, limit: Int = 3) -> [Chip] {
        Array(run.chips.filter(\.isLive).sorted { $0.addedAt > $1.addedAt }.prefix(limit))
    }
}

extension Chip {
    /// In the cart: not a wish, not removed, not still being identified, not put back or dropped.
    public var isLive: Bool {
        state != .wish && state != .removed && state != .identifying && !putBack && !dropped
    }
}

extension Run {
    /// Everyone but the shopper, in join order.
    public var claimers: [Person] { people.filter { !$0.isShopper } }

    /// "Jake's Costco run".
    public var title: String { RunText.title(shopperName: shopper?.name, store: store) }

    /// Whether people can still join and claim.
    public var isJoinable: Bool { state == .open || state == .lastCall }
}
