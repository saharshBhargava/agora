import Foundation
import CoreGraphics

/// The claim screen's rules, kept free of UI so they can be tested (web/lib/share.ts, web/components/Chip.tsx,
/// Tray.tsx, web/lib/highlight.ts, web/lib/frame.ts). Every number here is a display preview built from the
/// server's own numbers (authorized cents, tax rate, prices, claimers); the server decides every claim.
enum ClaimLogic {
    /// Each raise grows the hold by at least $20 (web RAISE_STEP_CENTS).
    static let raiseStepCents = 2000
    /// A raise big enough for one chip is rounded up to the next $5.
    static let raiseRoundCents = 500
    /// The most a hold can be: the server's payments refuse anything above $1000 (server/src/payments/sim.ts MAX_AUTH_CENTS).
    static let maxHoldCents = 100000
    /// Undo window after a claim or leave.
    static let undoSeconds = 3
    /// How long a server error toast stays up.
    static let noticeSeconds: Double = 4
    /// How long a new chip's outline stays on the live picture.
    static let highlightMs: Double = 8000
    /// Camera frames are sent this many pixels wide; regions arrive in these frame pixels.
    static let frameWidth: Double = 640
    /// Where the wish screen's "Usual picks" are kept.
    static let usualPicksKey = "dibs.usualPicks"
    static let usualPicksLimit = 20

    // MARK: money

    /// Split a price among claimers: floor share, leftover cents one each to the earliest claimers.
    static func splitChip(_ priceCents: Int, _ claimers: [String]) -> [String: Int] {
        guard !claimers.isEmpty else { return [:] }
        let base = priceCents / claimers.count
        let leftover = priceCents - base * claimers.count
        var out: [String: Int] = [:]
        for (i, id) in claimers.enumerated() { out[id] = base + (i < leftover ? 1 : 0) }
        return out
    }

    /// My share of one chip; a chip with no price yet counts 0.
    static func myShare(_ chip: Chip, me: String) -> Int {
        guard let price = chip.priceCents else { return 0 }
        return splitChip(price, chip.claimers)[me] ?? 0
    }

    /// Cents of hold left after the tray's full prices plus tax, rounded up; may be negative.
    static func roomFor(_ trayFullPricesCents: [Int], authorizedCents: Int, taxRate: Double) -> Int {
        let sum = trayFullPricesCents.reduce(0, +)
        let rate = 10000 + Int((taxRate * 10000).rounded())
        let withTax = (sum * rate + 9999) / 10000   // ceil for non-negative sums
        return authorizedCents - withTax
    }

    /// The chips the server counts against my hold, exactly as `trayPrices` in server/src/run.ts: claimed by me,
    /// not removed and not put back. A dropped duplicate still counts there, so it counts here; unpriced count 0.
    static func roomChips(_ run: Run, me: String) -> [Chip] {
        run.chips.filter { $0.state != .removed && !$0.putBack && $0.claimers.contains(me) }
    }

    /// Room left on my hold, the same number the server's cap check uses; nil when I have no hold.
    static func roomLeft(run: Run, me: String) -> Int? {
        guard let held = run.person(me)?.authorizedCents else { return nil }
        return roomFor(roomChips(run, me: me).map { $0.priceCents ?? 0 }, authorizedCents: held, taxRate: run.taxRate)
    }

    static func trayTotal(_ tray: [Chip], me: String) -> Int {
        tray.reduce(0) { $0 + myShare($1, me: me) }
    }

    /// "1 item · $4.36".
    static func traySummary(_ tray: [Chip], me: String) -> String {
        "\(tray.count) \(tray.count == 1 ? "item" : "items") · \(Money.format(trayTotal(tray, me: me)))"
    }

    // MARK: chips

    /// What the shelf shows: everything not removed or dropped, wishes first, then newest first.
    static func shelfChips(_ run: Run) -> [Chip] {
        run.chips
            .filter { $0.state != .removed && !$0.dropped }
            .sorted { a, b in
                let aw = a.state == .wish, bw = b.state == .wish
                if aw != bw { return aw }
                return a.addedAt > b.addedAt
            }
    }

    static func isMine(_ chip: Chip, me: String) -> Bool {
        chip.claimers.contains(me)
    }

    /// My tray: the shelf chips I claimed, in shelf order.
    static func trayChips(_ run: Run, me: String) -> [Chip] {
        shelfChips(run).filter { isMine($0, me: me) }
    }

    /// The small label at a chip's bottom right. `colorHex` nil means muted.
    struct Tag: Equatable {
        let text: String
        let colorHex: UInt32?
    }

    /// "÷2" (my blue when I share it, ink otherwise), "You", the one claimer's name, or "open".
    static func chipTag(_ chip: Chip, people: [Person], me: String) -> Tag {
        let n = chip.claimers.count
        if n == 0 { return Tag(text: "open", colorHex: nil) }
        if n == 1 {
            let id = chip.claimers[0]
            let text = id == me ? "You" : (people.first { $0.id == id }?.name ?? "?")
            return Tag(text: text, colorHex: ringColorHex(people: people, id: id, me: me))
        }
        let mine = chip.claimers.contains(me)
        return Tag(text: "÷\(n)", colorHex: mine ? ringColorHex(people: people, id: me, me: me) : 0x111111)
    }

    /// Border colors in claim order: empty for the plain line border, one per claimer for an even split.
    /// A wish takes its wisher's color (my blue for a shopper's wish, like the web).
    static func borderColors(_ chip: Chip, people: [Person], me: String) -> [UInt32] {
        if chip.state == .wish {
            guard let w = chip.wishedBy, people.contains(where: { $0.id == w }) else { return [Palette.meHex] }
            return [ringColorHex(people: people, id: w, me: me)]
        }
        if chip.state == .identifying { return [] }
        return chip.claimers.map { ringColorHex(people: people, id: $0, me: me) }
    }

    /// "Split with Marcus", "Split with Marcus and Lee", or "Just you".
    static func splitLabel(_ chip: Chip, people: [Person], me: String) -> String {
        let others = chip.claimers.filter { $0 != me }.map { id in people.first { $0.id == id }?.name ?? "someone" }
        return others.isEmpty ? "Just you" : "Split with \(RunText.listNames(others))"
    }

    /// A wish shows a delete control to the person who wished it and to the shopper.
    static func canDeleteWish(_ chip: Chip, me: String, meIsShopper: Bool) -> Bool {
        guard chip.state == .wish else { return false }
        return meIsShopper || chip.wishedBy == me
    }

    /// "Your wish" or "Marcus's wish".
    static func wishWho(_ chip: Chip, people: [Person], me: String) -> String {
        if chip.wishedBy == me { return "Your wish" }
        let name = people.first { $0.id == chip.wishedBy }?.name ?? "A"
        return "\(name)'s wish"
    }

    /// "Lands in your tray when Jake adds it".
    static func wishNote(_ chip: Chip, people: [Person], me: String) -> String {
        let whose: String
        if chip.wishedBy == me { whose = "your" } else {
            whose = "\(people.first { $0.id == chip.wishedBy }?.name ?? "their")'s"
        }
        let shopper = people.first { $0.isShopper }?.name ?? "the shopper"
        return "Lands in \(whose) tray when \(shopper) adds it"
    }

    // MARK: claiming

    enum ClaimDecision: Equatable {
        /// Send the claim.
        case claim
        /// It would go past my hold: offer the raise sheet.
        case overCap
        /// Already in my tray: nothing to do.
        case alreadyMine
        /// A wish or a chip still being identified.
        case notClaimable
    }

    /// The server's cap check before a claim (`fits` in server/src/run.ts). `roomChips` is `roomChips(run, me:)`;
    /// `authorizedCents` nil skips the cap check.
    static func decide(_ chip: Chip, roomChips: [Chip], me: String, authorizedCents: Int?, taxRate: Double) -> ClaimDecision {
        if chip.state == .wish || chip.state == .identifying { return .notClaimable }
        if chip.claimers.contains(me) { return .alreadyMine }
        if let held = authorizedCents, roomFor(prices(with: chip, roomChips), authorizedCents: held, taxRate: taxRate) < 0 {
            return .overCap
        }
        return .claim
    }

    /// Full prices of my counted chips plus this one (the server leaves the chip itself out of the tray first).
    private static func prices(with chip: Chip, _ roomChips: [Chip]) -> [Int] {
        roomChips.filter { $0.id != chip.id }.map { $0.priceCents ?? 0 } + [chip.priceCents ?? 0]
    }

    /// The smallest hold that fits my counted chips plus this one, with tax.
    static func neededHold(for chip: Chip, roomChips: [Chip], taxRate: Double) -> Int {
        -roomFor(prices(with: chip, roomChips), authorizedCents: 0, taxRate: taxRate)
    }

    /// What "Raise" asks for: at least $20 more, or enough for this chip rounded up to the next $5,
    /// whichever is larger, never above the most the server allows.
    static func raiseTarget(for chip: Chip, roomChips: [Chip], authorizedCents: Int, taxRate: Double) -> Int {
        let needed = neededHold(for: chip, roomChips: roomChips, taxRate: taxRate)
        let rounded = (needed + raiseRoundCents - 1) / raiseRoundCents * raiseRoundCents
        return min(max(authorizedCents + raiseStepCents, rounded), maxHoldCents)
    }

    /// "Over your cap. Raise it to $60?"
    static func overCapTitle(targetCents: Int) -> String {
        "Over your cap. Raise it to \(Money.whole(targetCents))?"
    }

    /// "Raise to $60 and claim".
    static func raiseButton(targetCents: Int) -> String {
        "Raise to \(Money.whole(targetCents)) and claim"
    }

    /// "Your hold grows by $20. You still only pay for what you claim." (canvas OverCap.dc.html)
    static func raiseCopy(growCents: Int) -> String {
        "Your hold grows by \(Money.whole(growCents)). You still only pay for what you claim."
    }
    static let raiseOffTitle = "Raising your cap is off for this run"

    /// "$14.99 · more than your $7.29 room".
    static func overCapLine(_ chip: Chip, roomCents: Int) -> String {
        let price = chip.priceCents.map(Money.format) ?? "Price not known yet"
        return "\(price) · more than your \(Money.format(max(0, roomCents))) room"
    }

    // MARK: copy

    /// "Live · 3 in the run" or "Closed · 3 in the run".
    static func statusLine(_ run: Run) -> String {
        "\(run.isJoinable ? "Live" : "Closed") · \(run.people.count) in the run"
    }

    static func lastCallLine(shopperName: String?, secs: Int) -> String {
        "\(shopperName ?? "The shopper") is checking out · last call · \(secs)s"
    }

    static func closedLine(trayCents: Int, count: Int) -> String {
        "Your tray is \(Money.format(trayCents)) across \(count) \(count == 1 ? "item" : "items")"
    }

    /// A server reason ("over cap") as a toast ("Over cap").
    static func notice(_ reason: String) -> String { RunText.capitalize(reason) }

    // MARK: run changes

    /// Something that happened to me between two run snapshots.
    enum ClaimEvent: Equatable {
        /// A chip I had claimed was removed from the cart (by the shopper or the shopper's camera).
        case removed(chipName: String)
        /// My wish was matched by a real chip; the server claimed it for me, or flagged me over cap.
        case wishArrived(wishName: String, chipId: String, overCap: Bool)
    }

    /// The server's name key for matching a wish (server/src/run.ts `normalize`).
    static func normalize(_ name: String) -> String {
        name.lowercased()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// What changed for me from `old` to `new`. A chip coming back (undo remove) is not an event.
    static func events(from old: Run, to new: Run, me: String) -> [ClaimEvent] {
        guard old.id == new.id else { return [] }
        var out: [ClaimEvent] = []
        for c in new.chips where c.state == .removed {
            if let before = old.chip(c.id), before.state != .removed, before.claimers.contains(me) {
                out.append(.removed(chipName: c.name))
            }
        }
        for w in old.chips where w.state == .wish && w.wishedBy == me && new.chip(w.id) == nil {
            let key = normalize(w.name)
            guard !key.isEmpty else { continue }
            let landed = new.chips.first { c in
                guard c.state != .wish, c.state != .removed, normalize(c.name) == key,
                      c.claimers.contains(me) || c.overCap.contains(me) else { return false }
                // Only new news: not a chip that already had me before.
                guard let before = old.chip(c.id) else { return true }
                return !before.claimers.contains(me) && !before.overCap.contains(me)
            }
            if let landed {
                out.append(.wishArrived(wishName: w.name, chipId: landed.id, overCap: !landed.claimers.contains(me)))
            }
        }
        return out
    }

    /// "Jake removed Coke Zero from the cart".
    static func removedLine(chipName: String, shopperName: String?) -> String {
        "\(shopperName ?? "The shopper") removed \(chipName) from the cart"
    }

    /// "Your Everything bagels are in the cart".
    static func wishArrivedLine(wishName: String) -> String {
        "Your \(wishName) are in the cart"
    }

    /// The leave-run confirmation: "Your $40 hold stays until the shopper checks out."
    static func leaveRunMessage(authorizedCents: Int?) -> String {
        guard let held = authorizedCents else { return "You can come back with the link until the shopper checks out." }
        return "Your \(Money.whole(held)) hold stays until the shopper checks out."
    }

    /// The price under a chip: the price, or "Finding price…" while the server looks it up.
    static func priceText(_ chip: Chip) -> String {
        chip.priceCents.map(Money.format) ?? "Finding price…"
    }

    // MARK: live view

    struct Highlight: Equatable {
        let region: Box
        let label: String
        let pending: Bool
    }

    /// The region being identified now, or else the newest chip with a region for 8 s after it lands.
    static func highlight(chips: [Chip], identifying: Box?, nowMs: Double) -> Highlight? {
        if let identifying { return Highlight(region: identifying, label: "Identifying…", pending: true) }
        let newest = chips
            .filter { $0.region != nil && $0.state != .wish && $0.state != .identifying && $0.state != .removed && !$0.dropped }
            .max { $0.addedAt < $1.addedAt }
        guard let newest, let region = newest.region, nowMs - newest.addedAt < highlightMs else { return nil }
        let price = newest.priceCents.map(Money.format) ?? "~$?"
        return Highlight(region: region, label: "\(newest.name) · \(price)", pending: false)
    }

    /// A region in sent-frame pixels to a rectangle in a box the image fills (aspect fill, centered).
    static func frameBoxToDisplay(_ r: Box, box: CGSize, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let s = max(box.width / imageSize.width, box.height / imageSize.height)
        let ox = (box.width - imageSize.width * s) / 2
        let oy = (box.height - imageSize.height * s) / 2
        let k = frameWidth / imageSize.width
        let f = s / k
        return CGRect(x: ox + r.x * f, y: oy + r.y * f, width: r.w * f, height: r.h * f)
    }

    // MARK: usual picks

    /// Names this phone has seen in the run (wishes and named chips), oldest first.
    static func seenNames(_ run: Run) -> [String] {
        run.chips
            .sorted { $0.addedAt < $1.addedAt }
            .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Adds `seen` (oldest first) to the front of `existing`, newest first, unique ignoring case, at most 20.
    static func rememberPicks(_ existing: [String], seen: [String]) -> [String] {
        var out = existing
        for raw in seen {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            out.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
            out.insert(name, at: 0)
        }
        return Array(out.prefix(usualPicksLimit))
    }

    /// Saved picks minus anything already on the shelf (in the cart or wished).
    static func usualPicks(saved: [String], run: Run) -> [String] {
        let present = Set(shelfChips(run).map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return saved.filter { !present.contains($0.lowercased()) }
    }

    static func savedPicks(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: usualPicksKey) ?? []
    }

    static func recordSeen(_ seen: [String], defaults: UserDefaults) {
        let before = savedPicks(defaults)
        let after = rememberPicks(before, seen: seen)
        if after != before { defaults.set(after, forKey: usualPicksKey) }
    }
}
