import XCTest
@testable import Dibs

/// The shopper screen's values: covered total and bar, cart rows, duplicates, the undo countdown,
/// last call and the locked list. Runs come from the fixture captured from the real server.
final class ShopperLogicTests: XCTestCase {
    private let priya = "252defdd-68a7-473a-96c3-0f1b5e781df6"
    private let marcus = "abea27ec-1781-4719-8fac-382dc040dcee"
    private let eggs = "1879bc33-79c6-49c6-9d08-0716a4e4b47e"
    private let towels = "1898fc97-393e-4fbe-9c32-51bedac55a1a"
    private let oat = "223be3d9-167c-41c2-9938-6bfc4e391b28"

    private func fixture() throws -> Run { try Run.decode(fixtureData("run")) }

    /// The fixture plus an unclaimed 2% Milk ($4.29) and an unpriced, unclaimed bagel.
    private func withMilk() throws -> Run {
        var run = try fixture()
        run.chips.append(Chip(id: "milk", name: "2% Milk", priceCents: 429, priceSource: .web, state: .open, addedAt: 1_792_293_600_000))
        run.chips.append(Chip(id: "bagel", name: "Bagels", priceCents: nil, state: .open, addedAt: 1_792_293_590_000))
        return run
    }

    // MARK: covered total and bar

    func testCoveredTotalFromTheFixtureRun() throws {
        let run = try fixture()
        let cover = ShopperLogic.coverage(people: run.people, chips: run.chips)
        // Eggs $8.72 split Priya/Marcus ($4.36 each), towels $23.99 Priya; the wish has no price.
        XCTAssertEqual(cover.totalCents, 3271)
        XCTAssertEqual(cover.coveredCents, 3271)
        XCTAssertEqual(cover.segments, [
            .init(id: priya, name: "Priya", cents: 2835),
            .init(id: marcus, name: "Marcus", cents: 436),
        ])
        XCTAssertEqual(ShopperLogic.coveredLine(cover), "$32.71")
        XCTAssertEqual(ShopperLogic.ofLine(cover), "of $32.71")
    }

    func testUnclaimedAndUnpricedChipsCountTowardTheTotalOnlyWhenPriced() throws {
        let cover = ShopperLogic.coverage(people: try withMilk().people, chips: try withMilk().chips)
        XCTAssertEqual(cover.totalCents, 3700)
        XCTAssertEqual(cover.coveredCents, 3271)
    }

    func testBarSegmentsAreFractionsOfTheTotalInJoinOrderWithShopperColors() throws {
        let run = try withMilk()
        let bar = ShopperLogic.bar(people: run.people, chips: run.chips, me: run.shopperId)
        XCTAssertEqual(bar.map(\.id), [priya, marcus])
        XCTAssertEqual(bar[0].fraction, 2835.0 / 3700.0, accuracy: 1e-9)
        XCTAssertEqual(bar[1].fraction, 436.0 / 3700.0, accuracy: 1e-9)
        // Seen by the shopper, the first claimer is blue and the second orange (web ringColor).
        XCTAssertEqual(bar[0].colorHex, 0x2B59E8)
        XCTAssertEqual(bar[1].colorHex, 0xD9480F)
        XCTAssertEqual(ShopperLogic.barLabel(people: run.people, chips: run.chips),
                       "Priya covers $28.35, Marcus covers $4.36, $4.29 unclaimed")
    }

    func testRemovedPutBackAndDroppedChipsAreNotCounted() throws {
        var run = try withMilk()
        run.chips = run.chips.map { c in
            var c = c
            if c.id == "milk" { c.state = .removed }
            if c.id == towels { c.dropped = true }
            return c
        }
        let cover = ShopperLogic.coverage(people: run.people, chips: run.chips)
        XCTAssertEqual(cover.totalCents, 872)
        XCTAssertEqual(cover.segments.map(\.cents), [436, 436])
    }

    func testEmptyCartHasNoSegmentsAndSaysSo() throws {
        let run = try fixture()
        XCTAssertTrue(ShopperLogic.bar(people: run.people, chips: [], me: run.shopperId).isEmpty)
        XCTAssertEqual(ShopperLogic.barLabel(people: run.people, chips: []), "Nothing priced in the cart yet")
    }

    func testSplitGivesLeftoverCentsToTheEarliestClaimers() {
        XCTAssertEqual(ShopperLogic.split(1000, among: ["a", "b", "c"]), ["a": 334, "b": 333, "c": 333])
        XCTAssertEqual(ShopperLogic.split(500, among: []), [:])
    }

    // MARK: cart rows

    func testRowsPutWishesFirstThenNewestAndHideRemovedOnes() throws {
        var run = try withMilk()
        run.chips.append(Chip(id: "gone", name: "Gone", priceCents: 100, state: .removed, removedAt: 1, addedAt: 1_792_293_700_000))
        // The unpriced bagel is not on the feed yet.
        XCTAssertEqual(ShopperLogic.rows(run.chips).map(\.id), [oat, "milk", towels, eggs])
    }

    func testRowsShowNamedItemsPricedAtOnceOrUnpricedAfterFiveSeconds() throws {
        var run = try withMilk()
        // Added with the bagel; they never show however long they wait.
        run.chips.append(Chip(id: "naming", name: "", state: .identifying, addedAt: 1_792_293_590_000))
        run.chips.append(Chip(id: "nameless", name: "", priceCents: 199, state: .open, addedAt: 1_792_293_590_000))
        let bagelAdded = Date(timeIntervalSince1970: 1_792_293_590)
        let at = { (s: Double) in bagelAdded.addingTimeInterval(s) }
        // 4 s: the unpriced bagel is still hidden; priced items and wishes show.
        XCTAssertEqual(ShopperLogic.rows(run.chips, now: at(4)).map(\.id), [oat, "milk", towels, eggs])
        // 5 s: it shows, finding its price.
        XCTAssertEqual(ShopperLogic.rows(run.chips, now: at(5)).map(\.id), [oat, "milk", "bagel", towels, eggs])
        XCTAssertEqual(ShopperLogic.subline(run.chip("bagel")!, people: run.people, checking: nil, now: at(5)),
                       .muted("Finding price…"))
        // 20 s: "No price found · Add price".
        XCTAssertEqual(ShopperLogic.subline(run.chip("bagel")!, people: run.people, checking: nil, now: at(20)), .noPrice)
        XCTAssertEqual(ShopperLogic.rows(run.chips, now: at(600)).map(\.id), [oat, "milk", "bagel", towels, eggs])
        // Priced shows immediately, even at the moment it was added.
        let fresh = Chip(id: "fresh", name: "Fresh", priceCents: 100, state: .open, addedAt: 1_792_293_590_000)
        XCTAssertTrue(fresh.isOnFeed(at: bagelAdded))
        XCTAssertTrue(run.chip(oat)!.isOnFeed(at: nil))
        XCTAssertFalse(run.chip("bagel")!.isOnFeed(at: nil))
        XCTAssertFalse(run.chip("naming")!.isOnFeed(at: at(600)))
        XCTAssertFalse(run.chip("nameless")!.isOnFeed(at: at(600)))
    }

    func testGaveUpShowsAddPriceAtOnce() {
        let chip = Chip(id: "o", name: "Lawry's Casero Onion Powder", state: .open, addedAt: 1_792_293_590_000)
        let added = Date(timeIntervalSince1970: 1_792_293_590)
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: nil, now: added.addingTimeInterval(8)), .muted("Finding price…"))
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: nil, now: added.addingTimeInterval(8), gaveUp: true), .noPrice)
        // While the worker is still checking, that status wins.
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: "Checking qfc.com…", now: added.addingTimeInterval(8), gaveUp: true), .muted("Checking qfc.com…"))
    }

    func testTickerRunsOnlyWhileAnUnpricedNamedItemIsYoung() throws {
        let added = 1_792_293_590_000.0
        let t0 = Date(timeIntervalSince1970: added / 1000)
        let chips = [Chip(id: "b", name: "Bagels", priceCents: nil, state: .open, addedAt: added),
                     Chip(id: "m", name: "Milk", priceCents: 429, state: .open, addedAt: added)]
        XCTAssertTrue(ShopperLogic.needsTick(chips, now: t0.addingTimeInterval(3)))
        XCTAssertTrue(ShopperLogic.needsTick(chips, now: t0.addingTimeInterval(19.5)))
        XCTAssertFalse(ShopperLogic.needsTick(chips, now: t0.addingTimeInterval(21)))
        XCTAssertFalse(ShopperLogic.needsTick([chips[1]], now: t0))
    }

    func testRowSublines() throws {
        let run = try withMilk()
        func sub(_ id: String, checking: String? = nil) -> ShopperLogic.Subline? {
            ShopperLogic.subline(run.chip(id)!, people: run.people, checking: checking)
        }
        XCTAssertEqual(sub(oat), .wish("Marcus wants this", wisherId: marcus))
        XCTAssertEqual(sub("milk"), .muted("Nobody yet · stays yours"))
        XCTAssertNil(sub(eggs))
        XCTAssertEqual(sub("bagel"), .muted("Finding price…"))
        XCTAssertEqual(sub("bagel", checking: "Checking qfc.com…"), .muted("Checking qfc.com…"))
        XCTAssertEqual(sub("bagel", checking: ""), .muted("Checking qfc.com…"))
        // Identifying chips are never rendered, so they have no line of their own.
        let identifying = Chip(id: "i", name: "", state: .identifying)
        XCTAssertNil(ShopperLogic.subline(identifying, people: run.people, checking: nil))
    }

    func testNoPriceFoundAfterTwentySecondsUnlessBeingChecked() throws {
        let added = 1_792_293_590_000.0
        let chip = Chip(id: "bagel", name: "Bagels", priceCents: nil, state: .open, addedAt: added)
        let at = { (s: Double) in Date(timeIntervalSince1970: added / 1000 + s) }
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: nil, now: at(19)), .muted("Finding price…"))
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: nil, now: at(20)), .noPrice)
        XCTAssertEqual(ShopperLogic.subline(chip, people: [], checking: "Checking qfc.com…", now: at(90)),
                       .muted("Checking qfc.com…"))
        var priced = chip
        priced.priceCents = 199
        XCTAssertEqual(ShopperLogic.subline(priced, people: [], checking: nil, now: at(90)), .muted("Nobody yet · stays yours"))
        XCTAssertEqual(ShopperLogic.noPriceText, "No price found")
        XCTAssertEqual(ShopperLogic.addPriceText, "Add price")
    }

    func testEveryRemovalRaisesTheUndoOnceWhoeverRemovedIt() throws {
        var run = try withMilk()
        // The first snapshot only records what is already removed.
        run.chips.append(Chip(id: "old", name: "Old", priceCents: 100, state: .removed, removedAt: 1))
        let first = ShopperLogic.removals(previous: nil, chips: run.chips)
        XCTAssertEqual(first.ids, ["old"])
        XCTAssertTrue(first.new.isEmpty)
        // The camera (or this phone) removes the milk: one new removal.
        run.chips = run.chips.map { c in var c = c; if c.id == "milk" { c.state = .removed }; return c }
        let second = ShopperLogic.removals(previous: first.ids, chips: run.chips)
        XCTAssertEqual(second.new.map(\.id), ["milk"])
        // Same snapshot again: nothing new.
        XCTAssertTrue(ShopperLogic.removals(previous: second.ids, chips: run.chips).new.isEmpty)
        // Undone, then removed again: new again.
        run.chips = run.chips.map { c in var c = c; if c.id == "milk" { c.state = .open }; return c }
        let undone = ShopperLogic.removals(previous: second.ids, chips: run.chips)
        run.chips = run.chips.map { c in var c = c; if c.id == "milk" { c.state = .removed }; return c }
        XCTAssertEqual(ShopperLogic.removals(previous: undone.ids, chips: run.chips).new.map(\.id), ["milk"])
    }

    func testFixSheetOffersRemoveOnlyWhileTheCartTakesChanges() {
        let chip = Chip(id: "m", name: "2% Milk", priceCents: 429, state: .open)
        XCTAssertTrue(ShopperLogic.canRemoveFromSheet(chip, runState: .open))
        XCTAssertTrue(ShopperLogic.canRemoveFromSheet(chip, runState: .lastCall))
        XCTAssertFalse(ShopperLogic.canRemoveFromSheet(chip, runState: .locked))
        XCTAssertFalse(ShopperLogic.canRemoveFromSheet(chip, runState: .receipt))
        XCTAssertFalse(ShopperLogic.canRemoveFromSheet(chip, runState: nil))
        var claimed = chip
        claimed.claimers = ["p"]
        claimed.state = .claimed
        XCTAssertTrue(ShopperLogic.canRemoveFromSheet(claimed, runState: .open))
        var gone = chip
        gone.state = .removed
        XCTAssertFalse(ShopperLogic.canRemoveFromSheet(gone, runState: .open))
        XCTAssertFalse(ShopperLogic.canRemoveFromSheet(Chip(id: "w", name: "Bagels", state: .wish), runState: .open))
        XCTAssertEqual(ShopperLogic.removeButtonTitle, "Remove from cart")
    }

    func testUndoToastNamesTheRemovedItem() {
        XCTAssertEqual(ShopperLogic.undoLabel(Chip(id: "m", name: "2% Milk")), "Removed 2% Milk")
        XCTAssertEqual(ShopperLogic.undoLabel(Chip(id: "x", name: "  ")), "Removed item")
        let undo = UndoCountdown(chipId: "m", label: ShopperLogic.undoLabel(Chip(id: "m", name: "2% Milk")), startedAt: .now)
        XCTAssertEqual("\(undo.label) · \(undo.buttonTitle(at: undo.startedAt))", "Removed 2% Milk · Undo · 5s")
    }

    func testRowPrices() throws {
        let run = try withMilk()
        XCTAssertEqual(ShopperLogic.price(run.chip("milk")!), "$4.29")
        XCTAssertEqual(ShopperLogic.price(run.chip("bagel")!), "")
        XCTAssertEqual(ShopperLogic.price(run.chip(oat)!), "wish")
    }

    // MARK: duplicates

    func testDuplicateCardShowsForChipsWithDuplicateOfUntilKeptOrRemoved() throws {
        var run = try fixture()
        run.chips.append(Chip(id: "eggs2", name: "Kirkland Eggs 24 ct", priceCents: 872, state: .open, duplicateOf: eggs, addedAt: 1_792_293_590_000))
        XCTAssertEqual(ShopperLogic.duplicates(run.chips, kept: []).map(\.id), ["eggs2"])
        XCTAssertEqual(ShopperLogic.duplicateLine(run.chip("eggs2")!), "Kirkland Eggs 24 ct showed up again")
        // Keep both hides it.
        XCTAssertTrue(ShopperLogic.duplicates(run.chips, kept: ["eggs2"]).isEmpty)
        // Remove one hides it.
        run.chips[run.chips.count - 1].state = .removed
        XCTAssertTrue(ShopperLogic.duplicates(run.chips, kept: []).isEmpty)
    }

    func testNoDuplicateCardWhenTheOriginalIsGone() throws {
        var run = try fixture()
        run.chips.append(Chip(id: "ghost", name: "Milk", priceCents: 429, state: .open, duplicateOf: "deleted-chip", addedAt: 5))
        run.chips.append(Chip(id: "eggs2", name: "Kirkland Eggs 24 ct", priceCents: 872, state: .open, duplicateOf: eggs, addedAt: 6))
        XCTAssertEqual(ShopperLogic.duplicates(run.chips, kept: []).map(\.id), ["eggs2"])
        // The original removed: no card either.
        run.chips = run.chips.map { c in var c = c; if c.id == eggs { c.state = .removed }; return c }
        XCTAssertTrue(ShopperLogic.duplicates(run.chips, kept: []).isEmpty)
        // A duplicate not yet priced isn't on the feed, so no card.
        var fresh = try fixture()
        fresh.chips.append(Chip(id: "eggs3", name: "Kirkland Eggs 24 ct", priceCents: nil, state: .open, duplicateOf: eggs, addedAt: 7))
        XCTAssertTrue(ShopperLogic.duplicates(fresh.chips, kept: []).isEmpty)
    }

    func testNoDuplicateCardWithoutDuplicateOf() throws {
        XCTAssertTrue(ShopperLogic.duplicates(try fixture().chips, kept: []).isEmpty)
    }

    // MARK: undo countdown

    func testUndoCountdownCountsDownAndExpiresAfterFiveSeconds() {
        let start = Date(timeIntervalSince1970: 1000)
        let undo = UndoCountdown(chipId: "milk", label: "Removed 2% Milk", startedAt: start)
        XCTAssertEqual(undo.duration, 5)
        XCTAssertEqual(undo.secondsLeft(at: start), 5)
        XCTAssertEqual(undo.secondsLeft(at: start.addingTimeInterval(0.2)), 5)
        XCTAssertEqual(undo.secondsLeft(at: start.addingTimeInterval(1.0)), 4)
        XCTAssertEqual(undo.secondsLeft(at: start.addingTimeInterval(4.5)), 1)
        XCTAssertEqual(undo.secondsLeft(at: start.addingTimeInterval(9)), 1, "never shows 0s")
        XCTAssertFalse(undo.isExpired(at: start.addingTimeInterval(4.99)))
        XCTAssertTrue(undo.isExpired(at: start.addingTimeInterval(5)))
        XCTAssertEqual(undo.remaining(at: start.addingTimeInterval(2.5)), 0.5, accuracy: 1e-9)
        XCTAssertEqual(undo.remaining(at: start.addingTimeInterval(7)), 0)
        XCTAssertEqual(undo.buttonTitle(at: start.addingTimeInterval(1.2)), "Undo · 4s")
    }

    // MARK: modes, streaming, last call, locked

    func testModeFollowsRunState() {
        XCTAssertEqual(ShopperLogic.mode(.open), .cart)
        XCTAssertEqual(ShopperLogic.mode(.lastCall), .lastCall)
        XCTAssertEqual(ShopperLogic.mode(.locked), .locked)
        XCTAssertEqual(ShopperLogic.mode(.receipt), .closed)
        XCTAssertEqual(ShopperLogic.mode(.settled), .closed)
        XCTAssertEqual(ShopperLogic.mode(.partlySettled), .closed)
        XCTAssertEqual(ShopperLogic.mode(nil), .cart)
    }

    func testStreamingPill() throws {
        let run = try fixture()
        XCTAssertEqual(ShopperLogic.streamingText(run), "Streaming to Priya and Marcus")
        XCTAssertEqual(ShopperLogic.streamingText(Run(id: "r", shopperId: "jake", people: [run.shopper!])),
                       "Streaming · nobody has joined yet")
        XCTAssertEqual(ShopperLogic.streamingText(nil), "Streaming · nobody has joined yet")
    }

    func testLastCallClockAndTitle() throws {
        let ends = Date(timeIntervalSince1970: 2000)
        XCTAssertEqual(ShopperLogic.secondsLeft(until: ends, now: ends.addingTimeInterval(-9.2)), 10)
        XCTAssertEqual(ShopperLogic.secondsLeft(until: ends, now: ends.addingTimeInterval(3)), 0)
        XCTAssertEqual(ShopperLogic.clock(572), "9:32")
        XCTAssertEqual(ShopperLogic.clock(4), "0:04")
        XCTAssertEqual(ShopperLogic.lastCallTitle(try fixture()), "Priya and Marcus see this too. Then the cart locks.")
        var one = try fixture()
        one.people.removeLast()
        XCTAssertEqual(ShopperLogic.lastCallTitle(one), "Priya sees this too. Then the cart locks.")
        one.people.removeLast()
        XCTAssertEqual(ShopperLogic.lastCallTitle(one), "Nobody else is in. Then the cart locks.")
    }

    func testLockedListShowsOnlyUnclaimedLockedChips() throws {
        var run = try withMilk()
        run.state = .locked
        run.chips = run.chips.map { c in
            var c = c
            if c.state != .wish { c.state = .locked }
            if c.id == "bagel" { c.putBack = true }
            return c
        }
        run.chips.append(Chip(id: "dropped", name: "Dropped", priceCents: 100, state: .locked, dropped: true))
        XCTAssertEqual(ShopperLogic.unclaimed(run).map(\.id), ["milk", "bagel"])
        XCTAssertEqual(ShopperLogic.unclaimedNote(ShopperLogic.unclaimed(run)),
                       "They stay yours by default. Put back anything you don't want before the register.")
        XCTAssertEqual(ShopperLogic.unclaimedNote([]), "Everything has an owner.")
    }

    // MARK: fix sheet and notices

    func testFixSendsOnlyChangedFields() {
        let chip = Chip(id: "t", name: "Paper Towels 12 pk", priceCents: 2399, state: .open)
        XCTAssertEqual(ShopperLogic.priceField(chip), "23.99")
        XCTAssertEqual(ShopperLogic.priceField(Chip(id: "x", name: "x")), "")
        XCTAssertEqual(ShopperLogic.fix(chip, name: "Paper Towels 12 pk", price: "23.99"), .save(name: nil, priceCents: nil))
        XCTAssertEqual(ShopperLogic.fix(chip, name: "  Towels ", price: "$21"), .save(name: "Towels", priceCents: 2100))
        XCTAssertEqual(ShopperLogic.fix(chip, name: "", price: ""), .save(name: nil, priceCents: nil))
        XCTAssertEqual(ShopperLogic.fix(chip, name: "Towels", price: "abc"), .badPrice)
    }

    func testServerErrorNotices() {
        XCTAssertEqual(ShopperLogic.notice(forError: "identify failed"), "Couldn't identify. Tap it again or name it")
        XCTAssertEqual(ShopperLogic.notice(forError: "undo expired"), "Undo expired")
        XCTAssertNil(ShopperLogic.notice(forError: "Reconnecting…"))
    }
}
