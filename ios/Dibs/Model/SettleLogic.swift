import Foundation

/// What the receipt check and settle screens show, built from server numbers only (web/app/settle,
/// web/components/ReceiptMatch.tsx and SettleLines.tsx). The one computed figure, the "Captured from"
/// preview on the check screen, is display-only and uses the same split as the server.
enum SettleLogic {
    // MARK: hero

    enum Hero: Equatable {
        /// "Jake gets back $32.71" on teal.
        case settled(shopperName: String, amount: String, note: String)
        /// "Partly settled · Jake gets back so far $4.36" on ink.
        case partly(shopperName: String, amount: String, note: String)
        /// A claimer whose share went past their hold: what they still owe the shopper, with "I've paid".
        case owed(shopperName: String, amount: String, note: String)
        /// Not settled yet.
        case none
    }

    static func shopperName(_ run: Run) -> String { run.shopper?.name ?? "The shopper" }

    static func hero(run: Run, me: String) -> Hero {
        let name = shopperName(run)
        let settles = run.claimers.compactMap { run.settle[$0.id] }
        switch run.state {
        case .partlySettled:
            if let mine = run.settle[me], mine.step == .captured, mine.owedCents > 0, !(run.person(me)?.isShopper ?? true) {
                return .owed(shopperName: name, amount: Money.format(mine.owedCents),
                             note: "Your hold covered \(Money.format(mine.capturedCents)). Pay \(name) the rest directly.")
            }
            let soFar = run.payout?.amountCents ?? settles.reduce(0) { $0 + ($1.step == .captured ? $1.capturedCents : 0) }
            let failed = settles.filter { $0.step == .failed }.count
            let owing = run.claimers.filter { (run.settle[$0.id]?.owedCents ?? 0) > 0 }
            let note: String
            if failed > 0 {
                note = (failed == 1 ? "One share didn't go through." : "\(failed) shares didn't go through.")
                    + " Retrying never repeats what already worked."
            } else if !owing.isEmpty {
                let total = owing.reduce(0) { $0 + (run.settle[$1.id]?.owedCents ?? 0) }
                note = "\(RunText.listNames(owing.map(\.name))) still \(owing.count == 1 ? "owes" : "owe") \(Money.format(total))."
            } else {
                note = "The payout didn't go through. Retrying never repeats what already worked."
            }
            return .partly(shopperName: name, amount: Money.whole(soFar), note: note)
        case .settled:
            let paid = run.payout?.amountCents ?? settles.reduce(0) { $0 + $1.capturedCents }
            var note = "Pushed to \(name)'s card over Visa Direct (simulated in this build)."
            if run.payout == nil { note = "Nothing to pay back." }
            if let stays = staysWith(run: run) { note += " \(stays)" }
            return .settled(shopperName: name, amount: Money.format(paid), note: note)
        default:
            return .none
        }
    }

    /// The shopper can retry a payout that failed after every share went through (no card has a retry).
    static func canRetryPayout(run: Run, me: String) -> Bool {
        guard run.state == .partlySettled, me == run.shopperId else { return false }
        let settles = run.claimers.compactMap { run.settle[$0.id] }
        return !settles.contains { $0.step == .failed || $0.owedCents > 0 } && run.payout == nil
    }

    /// "2% Milk, $4.29, stays with Jake." / "Milk ($4.29) and Gum ($1.99) stay with Jake." / nil.
    static func staysWith(run: Run) -> String? {
        var items: [(name: String, cents: Int?)] = run.chips
            .filter { $0.isLive && $0.claimers.isEmpty }
            .map { ($0.name, $0.priceCents) }
        for i in run.receipt?.mine ?? [] {
            if let lines = run.receipt?.lines, lines.indices.contains(i) { items.append((lines[i].text, lines[i].cents)) }
        }
        guard !items.isEmpty else { return nil }
        let money = { (c: Int?) in c.map(Money.format) ?? "~$?" }
        let name = shopperName(run)
        if items.count == 1 { return "\(items[0].name), \(money(items[0].cents)), stays with \(name)." }
        return "\(RunText.listNames(items.map { "\($0.name) (\(money($0.cents)))" })) stay with \(name)."
    }

    // MARK: person cards

    struct Card: Equatable, Identifiable {
        let personId: String
        let name: String
        let sub: String
        /// Big number on the right; nil while still settling.
        let amount: String?
        let muted: Bool
        /// "auth 888888" under a captured amount.
        let auth: String?
        let failed: Bool
        /// "Retry Marcus", shopper only.
        let retry: String?
        var id: String { personId }
    }

    /// One card per claimer with a settle entry, in join order.
    static func cards(run: Run, me: String) -> [Card] {
        let isShopper = me == run.shopperId
        let name = shopperName(run)
        return run.claimers.compactMap { p in
            guard let s = run.settle[p.id] else { return nil }
            switch s.step {
            case .captured:
                let sub = s.owedCents > 0
                    ? "Captured \(Money.format(s.capturedCents)) · \(Money.format(s.owedCents)) owed"
                    : "\(Money.format(s.releasedCents)) released · settles tonight"
                return Card(personId: p.id, name: p.name, sub: sub, amount: amountText(s.capturedCents), muted: false,
                            auth: s.approvalCode.map { "auth \($0)" }, failed: false, retry: nil)
            case .reversed where s.shareCents == 0:
                return Card(personId: p.id, name: p.name, sub: "Nothing captured · \(Money.format(s.releasedCents)) released",
                            amount: "$0", muted: true, auth: nil, failed: false, retry: nil)
            case .failed:
                return Card(personId: p.id, name: p.name,
                            sub: isShopper ? "Didn't go through" : "Didn't go through, \(name) will retry",
                            amount: amountText(s.shareCents), muted: true, auth: nil, failed: true,
                            retry: isShopper ? "Retry \(p.name)" : nil)
            default:
                return Card(personId: p.id, name: p.name, sub: "Settling…", amount: nil, muted: false,
                            auth: nil, failed: false, retry: nil)
            }
        }
    }

    private static func amountText(_ cents: Int) -> String { cents == 0 ? "$0" : Money.format(cents) }

    // MARK: receipt card (settled)

    struct ReceiptRow: Equatable {
        let text: String
        let amount: String
        let mine: Bool
    }

    /// "8.72": receipt amounts without the dollar sign.
    static func plain(_ cents: Int) -> String { Money.format(cents).replacingOccurrences(of: "$", with: "") }

    static func receiptRows(_ receipt: ReceiptState) -> [ReceiptRow] {
        receipt.lines.enumerated().map { i, line in
            ReceiptRow(text: line.text, amount: plain(line.cents), mine: receipt.mine?.contains(i) ?? false)
        }
    }

    static func receiptTotal(_ receipt: ReceiptState) -> String { plain(receipt.lines.reduce(0) { $0 + $1.cents }) }

    struct Counts: Equatable {
        let matched: Int
        let items: Int
        let needs: Int
    }

    /// Lines matched to a chip, item lines, and lines that still need the shopper.
    static func counts(_ receipt: ReceiptState) -> Counts {
        let matchedLines = Set(receipt.matches.map(\.lineIndex))
        let items = receipt.lines.filter { !$0.isTax }.count
        let matched = receipt.lines.indices.filter { !receipt.lines[$0].isTax && matchedLines.contains($0) }.count
        let needs = receipt.unmatchedLines.filter { !(receipt.mine ?? []).contains($0) }.count
        return Counts(matched: matched, items: items, needs: needs)
    }

    /// "3 of 3 lines matched".
    static func matchedLabel(_ receipt: ReceiptState) -> String {
        let c = counts(receipt)
        return "\(c.matched) of \(c.items) lines matched"
    }

    // MARK: receipt check

    /// "3 lines matched · 1 needs you".
    static func checkSubtitle(_ receipt: ReceiptState) -> String {
        let c = counts(receipt)
        var s = "\(c.matched) \(c.matched == 1 ? "line" : "lines") matched"
        if c.needs > 0 { s += " · \(c.needs) \(c.needs == 1 ? "needs" : "need") you" }
        return s
    }

    struct CheckRow: Equatable, Identifiable {
        let index: Int
        let text: String
        let amount: String
        let chip: Chip?
        /// "Kirkland Eggs 24 ct · Priya and Marcus", "Mine", the tax note, or nil.
        let sub: String?
        /// "100% match" for a matched line.
        let match: String?
        /// Unmatched and not marked Mine: the orange "Whose is it?" card.
        let needsYou: Bool
        let isTax: Bool
        var id: Int { index }
    }

    static func checkRows(run: Run) -> [CheckRow] {
        guard let receipt = run.receipt else { return [] }
        return receipt.lines.enumerated().map { i, line in
            let match = receipt.matches.first { $0.lineIndex == i }
            let chip = match.flatMap { run.chip($0.chipId) }
            let mine = receipt.mine?.contains(i) ?? false
            let needsYou = receipt.unmatchedLines.contains(i) && !mine && !line.isTax
            var sub: String?
            if let chip {
                let names = chip.claimers.map { run.person($0)?.name ?? "?" }
                sub = "\(chip.name) · \(names.isEmpty ? "yours" : names.joined(separator: ", "))"
            } else if mine {
                sub = "Mine"
            } else if line.isTax {
                sub = "Tax, spread across the lines"
            }
            return CheckRow(index: i, text: line.text, amount: Money.format(line.cents), chip: chip, sub: sub,
                            match: match.map { "\(Int(($0.confidence * 100).rounded()))% match" },
                            needsYou: needsYou, isTax: line.isTax)
        }
    }

    /// Live chips not paired with any line: what "Pair with an item" offers.
    static func pairable(run: Run) -> [Chip] {
        let matched = Set(run.receipt?.matches.map(\.chipId) ?? [])
        return run.chips.filter { $0.isLive && !matched.contains($0.id) }
    }

    /// "Not on receipt: Milk, Gum", or nil.
    static func notOnReceipt(run: Run) -> String? {
        let names = pairable(run: run).map(\.name)
        return names.isEmpty ? nil : "Not on receipt: \(names.joined(separator: ", "))"
    }

    struct Captured: Equatable {
        let label: String
        let amount: String
    }

    /// "Captured from Priya and Marcus $32.71": each housemate's share of the matched chips (display only;
    /// the same split as the server: floor shares, leftover cents to the earliest claimers).
    static func captured(run: Run) -> Captured? {
        let matched = Set(run.receipt?.matches.map(\.chipId) ?? [])
        var by: [String: Int] = [:]
        for c in run.chips where matched.contains(c.id) && c.isLive {
            guard let price = c.priceCents, !c.claimers.isEmpty else { continue }
            let base = price / c.claimers.count
            let leftover = price - base * c.claimers.count
            for (i, id) in c.claimers.enumerated() { by[id, default: 0] += base + (i < leftover ? 1 : 0) }
        }
        let payers = run.claimers.filter { (by[$0.id] ?? 0) > 0 }
        guard !payers.isEmpty else { return nil }
        let total = payers.reduce(0) { $0 + (by[$1.id] ?? 0) }
        return Captured(label: "Captured from \(RunText.listNames(payers.map(\.name)))", amount: Money.format(total))
    }

    // MARK: routing

    /// The stack to show when the live run moves on. Once the run is settled or partly settled, a claim,
    /// shopper or settle screen on top becomes Settle alone, so Back goes Home rather than to a stale cart.
    /// The shopper's cart becomes the receipt check once a receipt is read (Back returns to the cart).
    /// Nil when nothing changes.
    static func follow(path: [Route], run: Run) -> [Route]? {
        guard let last = path.last else { return nil }
        let ref: RunRef
        let shopperScreen: Bool
        switch last {
        case .claim(let r): ref = r; shopperScreen = false
        case .shopper(let r): ref = r; shopperScreen = true
        case .settle(let r): ref = r; shopperScreen = false
        default: return nil
        }
        guard ref.runId == run.id else { return nil }
        let next: [Route]
        if isFinished(run) {
            next = [.settle(ref)]
        } else if shopperScreen, run.state == .receipt {
            next = Array(path.dropLast()) + [.settle(ref)]
        } else {
            return nil
        }
        return next == path ? nil : next
    }

    /// The stack after the shopper taps into the receipt flow: pushed on the cart while the run is still
    /// being checked out, Settle alone once the run is finished.
    static func receiptPath(path: [Route], ref: RunRef, run: Run?) -> [Route] {
        if let run, run.id == ref.runId, isFinished(run) { return [.settle(ref)] }
        return path.last == .settle(ref) ? path : path + [.settle(ref)]
    }

    static func isFinished(_ run: Run) -> Bool { run.state == .settled || run.state == .partlySettled }

    // MARK: which screen

    /// The pill on the receipt camera while the server reads the photo (Gemini, about 20 s).
    static let readingMessage = "Reading the receipt… this takes about 20 seconds"

    enum Screen: Equatable { case camera, check, settle, waiting }

    /// What `Route.settle` shows: the shopper's camera while locked (or when retaking during the check),
    /// the receipt check, Settle once finished, otherwise a waiting panel.
    static func screen(run: Run, isShopper: Bool, retaking: Bool) -> Screen {
        switch run.state {
        case .locked: return isShopper ? .camera : .waiting
        case .receipt:
            guard run.receipt != nil else { return isShopper ? .camera : .waiting }
            return isShopper && retaking ? .camera : .check
        case .settled, .partlySettled: return .settle
        default: return .waiting
        }
    }

    // MARK: I've paid

    /// Where a claimer's "I've paid" is remembered on this phone (nothing is sent to the server).
    static func paidKey(runId: String) -> String { "dibs.paid.\(runId)" }
}
