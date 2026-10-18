import Foundation

/// The shopper screen's display values (web/app/shopper/ShopperScreen.tsx, web/lib/share.ts
/// `coverage`, web/components/CartRows.tsx, UnclaimedList.tsx, FixChipSheet.tsx). Display only: the
/// server is the authority for every charge.
enum ShopperLogic {
    // MARK: covered total and bar

    struct Segment: Equatable { let id: String; let name: String; let cents: Int }

    struct Coverage: Equatable {
        /// Sum of every housemate's share (the shopper's own claims are not covered).
        let coveredCents: Int
        /// Sum of live chip prices.
        let totalCents: Int
        /// One per housemate with a share, in join order.
        let segments: [Segment]
    }

    /// One colored piece of the per-person bar.
    struct BarPiece: Equatable { let id: String; let fraction: Double; let colorHex: UInt32 }

    /// Floor share each, leftover cents one each to the earliest claimers (web `splitChip`).
    static func split(_ priceCents: Int, among claimers: [String]) -> [String: Int] {
        guard !claimers.isEmpty else { return [:] }
        let base = priceCents / claimers.count
        let leftover = priceCents - base * claimers.count
        var out: [String: Int] = [:]
        for (i, id) in claimers.enumerated() { out[id, default: 0] += base + (i < leftover ? 1 : 0) }
        return out
    }

    /// How much of the cart the housemates cover. Chips without a price count 0.
    static func coverage(people: [Person], chips: [Chip]) -> Coverage {
        var by: [String: Int] = [:]
        var total = 0
        for c in chips where c.isLive {
            guard let price = c.priceCents else { continue }
            total += price
            for (id, cents) in split(price, among: c.claimers) { by[id, default: 0] += cents }
        }
        let segments = people
            .filter { !$0.isShopper && (by[$0.id] ?? 0) > 0 }
            .map { Segment(id: $0.id, name: $0.name, cents: by[$0.id]!) }
        return Coverage(coveredCents: segments.reduce(0) { $0 + $1.cents }, totalCents: total, segments: segments)
    }

    static func coveredLine(_ c: Coverage) -> String { Money.format(c.coveredCents) }
    static func ofLine(_ c: Coverage) -> String { "of \(Money.format(c.totalCents))" }

    /// The bar's colored pieces as fractions of the cart total, in each person's color.
    static func bar(people: [Person], chips: [Chip], me: String) -> [BarPiece] {
        let c = coverage(people: people, chips: chips)
        guard c.totalCents > 0 else { return [] }
        return c.segments.map {
            BarPiece(id: $0.id, fraction: Double($0.cents) / Double(c.totalCents),
                     colorHex: ringColorHex(people: people, id: $0.id, me: me))
        }
    }

    /// VoiceOver label for the bar.
    static func barLabel(people: [Person], chips: [Chip]) -> String {
        let c = coverage(people: people, chips: chips)
        guard c.totalCents > 0 else { return "Nothing priced in the cart yet" }
        let parts = c.segments.map { "\($0.name) covers \(Money.format($0.cents))" }
            + ["\(Money.format(c.totalCents - c.coveredCents)) unclaimed"]
        return parts.joined(separator: ", ")
    }

    // MARK: cart rows

    /// The cart: wishes first, then newest first. Removed and dropped chips are left out, and so is
    /// anything not on the feed yet (`Chip.isOnFeed(at:)`: named, and priced or `showUnpricedAfter` old).
    static func rows(_ chips: [Chip], now: Date? = nil) -> [Chip] {
        chips.filter { $0.state != .removed && !$0.dropped && $0.isOnFeed(at: now) }
            .enumerated()
            .sorted { a, b in
                let wa = a.element.state == .wish, wb = b.element.state == .wish
                if wa != wb { return wa }
                if a.element.addedAt != b.element.addedAt { return a.element.addedAt > b.element.addedAt }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    enum Subline: Equatable {
        /// "Priya wants this", in the wisher's color.
        case wish(String, wisherId: String?)
        /// Secondary line in muted ink.
        case muted(String)
        /// "No price found · Add price": the price lookup gave up; "Add price" opens the fix sheet.
        case noPrice
    }

    /// How long a named item waits for its price before it shows anyway, "Finding price…".
    static let showUnpricedAfter: TimeInterval = 5
    /// How long a row waits for a price before offering "Add price" (fallback when the price worker
    /// hasn't said it gave up).
    // TODO(price worker): also show "Add price" at once when `priceWorker.gaveUp(for: chip.name)` is true,
    // once the price-worker agent commits it (pass it in like `checking`).
    static let noPriceAfter: TimeInterval = 20
    static let noPriceText = "No price found"
    static let addPriceText = "Add price"

    /// The line under a row's name. `checking` is the price worker's status for this item
    /// (`priceWorker.status(for: chip.name)`, "Checking qfc.com…"), nil when it isn't looking it up.
    /// `now` enables "No price found" for a row still unpriced `noPriceAfter` after it was added.
    static func subline(_ chip: Chip, people: [Person], checking: String?, now: Date? = nil) -> Subline? {
        switch chip.state {
        case .wish:
            let wisher = people.first { $0.id == chip.wishedBy }
            return .wish(wisher.map { "\($0.name) wants this" } ?? "Someone wants this", wisherId: wisher?.id)
        case .identifying:
            return nil // never rendered: items show once named and priced
        default:
            if chip.priceCents == nil {
                if let checking { return .muted(checking.isEmpty ? "Checking qfc.com…" : checking) }
                if let now, now.timeIntervalSince1970 - chip.addedAt / 1000 >= noPriceAfter { return .noPrice }
                return .muted("Finding price…")
            }
            return chip.claimers.isEmpty ? .muted("Nobody yet · stays yours") : nil
        }
    }

    /// The row's right column: price, "wish", or nothing while the price is being found.
    static func price(_ chip: Chip) -> String {
        if chip.state == .wish { return "wish" }
        if chip.state == .identifying { return "…" }
        return chip.priceCents.map(Money.format) ?? ""
    }

    /// Whether the screen needs a 1 s clock: some named item is unpriced and younger than
    /// `noPriceAfter`, so it is about to appear (5 s) or switch to "Add price" (20 s).
    static func needsTick(_ chips: [Chip], now: Date) -> Bool {
        chips.contains { c in
            c.state != .wish && c.state != .identifying && c.state != .removed && !c.dropped
                && c.priceCents == nil && !c.name.trimmingCharacters(in: .whitespaces).isEmpty
                && now.timeIntervalSince1970 - c.addedAt / 1000 < noPriceAfter
        }
    }

    /// Whether a row can be lifted to the remove zone or swiped away.
    static func isRemovable(_ chip: Chip) -> Bool { chip.state != .wish && chip.state != .identifying }

    // MARK: duplicates

    /// Chips the server flagged as a possible second add, minus the ones the shopper kept. Only for
    /// chips on the feed whose original is still in the cart.
    static func duplicates(_ chips: [Chip], kept: Set<String>, now: Date? = nil) -> [Chip] {
        let present = Set(chips.filter { $0.state != .removed && !$0.dropped }.map(\.id))
        return chips.filter { c in
            guard let original = c.duplicateOf else { return false }
            return present.contains(original) && present.contains(c.id) && c.isOnFeed(at: now) && !kept.contains(c.id)
        }
    }

    static func duplicateLine(_ chip: Chip) -> String { "\(chip.name) showed up again" }

    // MARK: removals

    /// Chips that just turned `.removed` (by this phone, the camera watcher or anyone), so each gets
    /// the undo toast. `previous` nil (the first snapshot) records the removed set without reporting.
    static func removals(previous: Set<String>?, chips: [Chip]) -> (ids: Set<String>, new: [Chip]) {
        let removed = chips.filter { $0.state == .removed }
        let ids = Set(removed.map(\.id))
        guard let previous else { return (ids, []) }
        return (ids, removed.filter { !previous.contains($0.id) })
    }

    // MARK: modes

    enum Mode: Equatable { case cart, lastCall, locked, closed }

    static func mode(_ state: RunState?) -> Mode {
        switch state {
        case .lastCall: return .lastCall
        case .locked: return .locked
        case .receipt, .settled, .partlySettled: return .closed
        default: return .cart
        }
    }

    /// "Streaming to Priya and Marcus".
    static func streamingText(_ run: Run?) -> String {
        let names = run?.claimers.map(\.name) ?? []
        return names.isEmpty ? "Streaming · nobody has joined yet" : "Streaming to \(RunText.listNames(names))"
    }

    // MARK: last call

    /// Whole seconds left (never negative).
    static func secondsLeft(until endsAt: Date, now: Date) -> Int {
        max(0, Int((endsAt.timeIntervalSince(now)).rounded(.up)))
    }

    /// "9:32".
    static func clock(_ secs: Int) -> String { "\(secs / 60):\(String(format: "%02d", secs % 60))" }

    /// "Priya and Marcus see this too. Then the cart locks."
    static func lastCallTitle(_ run: Run) -> String {
        let names = run.claimers.map(\.name)
        let who = names.isEmpty ? "Nobody else is in."
            : "\(RunText.listNames(names)) \(names.count == 1 ? "sees" : "see") this too."
        return "\(who) Then the cart locks."
    }

    // MARK: locked

    /// After lock: chips nobody claimed (Mine by default; Put back drops them).
    static func unclaimed(_ run: Run) -> [Chip] {
        run.chips.filter { $0.claimers.isEmpty && $0.state == .locked && !$0.dropped }
    }

    static func unclaimedNote(_ items: [Chip]) -> String {
        items.isEmpty ? "Everything has an owner."
            : "They stay yours by default. Put back anything you don't want before the register."
    }

    // MARK: fix sheet

    enum Fix: Equatable {
        /// Fields to send; nil means unchanged. Both nil: nothing to send.
        case save(name: String?, priceCents: Int?)
        case badPrice
    }

    /// "23.99" for $23.99; empty when there is no price.
    static func priceField(_ chip: Chip) -> String {
        chip.priceCents.map { String(Money.format($0).dropFirst()) } ?? ""
    }

    /// Only changed fields are sent; empty fields are left alone.
    static func fix(_ chip: Chip, name: String, price: String) -> Fix {
        let trimmedPrice = price.trimmingCharacters(in: .whitespaces)
        var cents: Int?
        if !trimmedPrice.isEmpty {
            guard let parsed = Money.parse(trimmedPrice) else { return .badPrice }
            cents = parsed
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return .save(name: trimmed.isEmpty || trimmed == chip.name ? nil : trimmed,
                     priceCents: cents == chip.priceCents ? nil : cents)
    }

    // MARK: notices

    /// What to show over the camera for a server error; nil when the store's own pill covers it.
    static func notice(forError reason: String) -> String? {
        // RunStore.reconnectingMessage: the camera's own "Reconnecting…" line covers it.
        if reason == "Reconnecting…" { return nil }
        if reason == "identify failed" { return "Couldn't identify. Tap it again or name it" }
        return RunText.capitalize(reason)
    }
}

extension Chip {
    /// On the feed (shopper rows, claim shelf and tray): wishes, and items once identified and named,
    /// as soon as they are priced or `ShopperLogic.showUnpricedAfter` after they were added
    /// ("Finding price…"). `now` nil counts only priced items.
    func isOnFeed(at now: Date?) -> Bool {
        if state == .wish { return true }
        guard state != .identifying, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if priceCents != nil { return true }
        guard let now else { return false }
        return now.timeIntervalSince1970 - addedAt / 1000 >= ShopperLogic.showUnpricedAfter
    }
}

/// The 5 s undo after removing a row (web UndoToast, server UNDO_MS).
struct UndoCountdown: Equatable, Identifiable {
    let chipId: String
    let label: String
    let startedAt: Date
    var duration: TimeInterval = 5
    var id: String { "\(chipId)|\(startedAt.timeIntervalSince1970)" }

    /// Seconds shown on the button, 5 down to 1.
    func secondsLeft(at now: Date) -> Int {
        max(1, Int((duration - now.timeIntervalSince(startedAt)).rounded(.up)))
    }

    func isExpired(at now: Date) -> Bool { now.timeIntervalSince(startedAt) >= duration }

    /// 1 → 0 as the undo window runs out.
    func remaining(at now: Date) -> Double {
        min(1, max(0, 1 - now.timeIntervalSince(startedAt) / duration))
    }

    func buttonTitle(at now: Date) -> String { "Undo · \(secondsLeft(at: now))s" }
}
