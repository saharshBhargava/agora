import XCTest
@testable import Dibs

final class ClaimLogicTests: XCTestCase {
    private let jake = Person(id: "jake", name: "Jake", initial: "J", isShopper: true)
    private let priya = Person(id: "priya", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000, approvalCode: "888888")
    private let marcus = Person(id: "marcus", name: "Marcus", initial: "M", isShopper: false, authorizedCents: 4000)
    private let lee = Person(id: "lee", name: "Lee", initial: "L", isShopper: false, authorizedCents: 2000)
    private var people: [Person] { [jake, priya, marcus, lee] }

    private func chip(_ id: String, _ price: Int?, _ claimers: [String] = [], state: ChipState? = nil,
                      addedAt: Double = 0, wishedBy: String? = nil, region: Box? = nil, dropped: Bool = false) -> Chip {
        Chip(id: id, name: id.capitalized, priceCents: price, region: region, claimers: claimers,
             state: state ?? (claimers.isEmpty ? .open : .claimed), wishedBy: wishedBy, dropped: dropped, addedAt: addedAt)
    }

    private func run(_ chips: [Chip], taxRate: Double = 0, state: RunState = .open) -> Run {
        Run(id: "r1", state: state, store: "costco", shopperId: "jake", people: people, chips: chips, taxRate: taxRate)
    }

    // MARK: room left, from the server's authorized cents and tax rate

    func testRoomLeftIsHeldMinusTrayWithTaxRoundedUp() {
        // Eggs $8.72 split with Marcus: the full price counts against my hold, plus tax, rounded up.
        let r = run([chip("eggs", 872, ["priya", "marcus"]), chip("milk", 429)], taxRate: 0.1025)
        // 872 * 1.1025 = 961.38 -> 962; 4000 - 962 = 3038
        XCTAssertEqual(ClaimLogic.roomLeft(run: r, me: "priya"), 3038)
        XCTAssertEqual(ClaimLogic.roomFor([872], authorizedCents: 4000, taxRate: 0), 3128)
    }

    func testRoomLeftDisplaysServerHoldAndCanGoNegative() {
        let r = run([chip("tv", 4500, ["priya"])])
        XCTAssertEqual(ClaimLogic.roomLeft(run: r, me: "priya"), -500)
        XCTAssertEqual(Money.format(ClaimLogic.roomLeft(run: r, me: "priya")!), "-$5.00")
    }

    func testRoomLeftIsNilWithoutAHold() {
        XCTAssertNil(ClaimLogic.roomLeft(run: run([]), me: "jake"))
    }

    func testRoomLeftCountsUnpricedChipsAsZero() {
        let r = run([chip("mystery", nil, ["priya"]), chip("milk", 429, ["priya"])])
        XCTAssertEqual(ClaimLogic.roomLeft(run: r, me: "priya"), 4000 - 429)
    }

    func testShareSplitsWithLeftoverCentsToEarliestClaimers() {
        let eggs = chip("eggs", 873, ["priya", "marcus"])
        XCTAssertEqual(ClaimLogic.myShare(eggs, me: "priya"), 437)
        XCTAssertEqual(ClaimLogic.myShare(eggs, me: "marcus"), 436)
        XCTAssertEqual(ClaimLogic.myShare(chip("x", nil, ["priya"]), me: "priya"), 0)
        XCTAssertEqual(ClaimLogic.myShare(eggs, me: "lee"), 0)
    }

    func testTraySummary() {
        let tray = [chip("eggs", 872, ["priya", "marcus"])]
        XCTAssertEqual(ClaimLogic.traySummary(tray, me: "priya"), "1 item · $4.36")
        XCTAssertEqual(ClaimLogic.traySummary([], me: "priya"), "0 items · $0.00")
        XCTAssertEqual(ClaimLogic.traySummary(tray + [chip("milk", 429, ["priya"])], me: "priya"), "2 items · $8.65")
    }

    // MARK: which chips show as mine

    func testTrayHoldsOnlyMyLiveChips() {
        let r = run([
            chip("eggs", 872, ["priya", "marcus"]),
            chip("towels", 2399, ["marcus"]),
            chip("milk", 429),
            chip("gone", 100, ["priya"], state: .removed),
            chip("dup", 100, ["priya"], dropped: true),
            chip("bagels", nil, state: .wish, wishedBy: "priya"),
        ])
        XCTAssertEqual(ClaimLogic.trayChips(r, me: "priya").map(\.id), ["eggs"])
        XCTAssertEqual(ClaimLogic.trayChips(r, me: "marcus").map(\.id).sorted(), ["eggs", "towels"])
        XCTAssertTrue(ClaimLogic.isMine(r.chips[0], me: "priya"))
        XCTAssertFalse(ClaimLogic.isMine(r.chips[1], me: "priya"))
    }

    func testShelfDropsRemovedAndDroppedAndPutsWishesFirstThenNewest() {
        let r = run([
            chip("old", 100, addedAt: 1),
            chip("new", 100, addedAt: 5),
            chip("wish", nil, state: .wish, addedAt: 2, wishedBy: "priya"),
            chip("gone", 100, state: .removed, addedAt: 9),
            chip("dup", 100, addedAt: 9, dropped: true),
        ])
        XCTAssertEqual(ClaimLogic.shelfChips(r).map(\.id), ["wish", "new", "old"])
    }

    func testChipTag() {
        let p = people
        XCTAssertEqual(ClaimLogic.chipTag(chip("a", 1), people: p, me: "priya"), .init(text: "open", colorHex: nil))
        XCTAssertEqual(ClaimLogic.chipTag(chip("a", 1, ["priya"]), people: p, me: "priya"), .init(text: "You", colorHex: 0x2B59E8))
        XCTAssertEqual(ClaimLogic.chipTag(chip("a", 1, ["marcus"]), people: p, me: "priya"), .init(text: "Marcus", colorHex: 0xD9480F))
        XCTAssertEqual(ClaimLogic.chipTag(chip("a", 1, ["marcus", "priya"]), people: p, me: "priya"), .init(text: "÷2", colorHex: 0x2B59E8))
        XCTAssertEqual(ClaimLogic.chipTag(chip("a", 1, ["marcus", "lee"]), people: p, me: "priya"), .init(text: "÷2", colorHex: 0x111111))
    }

    func testBorderColorsFollowClaimersInOrder() {
        let p = people
        XCTAssertEqual(ClaimLogic.borderColors(chip("a", 1), people: p, me: "priya"), [])
        XCTAssertEqual(ClaimLogic.borderColors(chip("a", 1, ["priya", "marcus"]), people: p, me: "priya"), [0x2B59E8, 0xD9480F])
        XCTAssertEqual(ClaimLogic.borderColors(chip("w", nil, state: .wish, wishedBy: "marcus"), people: p, me: "priya"), [0xD9480F])
        // A shopper's wish (wishedBy null) is drawn in my blue, like the web.
        XCTAssertEqual(ClaimLogic.borderColors(chip("w", nil, state: .wish), people: p, me: "priya"), [0x2B59E8])
    }

    // MARK: split label

    func testSplitLabel() {
        let p = people
        XCTAssertEqual(ClaimLogic.splitLabel(chip("eggs", 872, ["priya", "marcus"]), people: p, me: "priya"), "Split with Marcus")
        XCTAssertEqual(ClaimLogic.splitLabel(chip("eggs", 872, ["marcus", "priya", "lee"]), people: p, me: "priya"), "Split with Marcus and Lee")
        XCTAssertEqual(ClaimLogic.splitLabel(chip("eggs", 872, ["priya"]), people: p, me: "priya"), "Just you")
        XCTAssertEqual(ClaimLogic.splitLabel(chip("eggs", 872, ["priya", "ghost"]), people: p, me: "priya"), "Split with someone")
    }

    // MARK: wish delete

    func testWishDeleteOnlyForMyWishesAndTheShopper() {
        let mine = chip("bagels", nil, state: .wish, wishedBy: "priya")
        let marcusWish = chip("oat", nil, state: .wish, wishedBy: "marcus")
        let shopperWish = chip("chips", nil, state: .wish, wishedBy: nil)
        XCTAssertTrue(ClaimLogic.canDeleteWish(mine, me: "priya", meIsShopper: false))
        XCTAssertFalse(ClaimLogic.canDeleteWish(marcusWish, me: "priya", meIsShopper: false))
        XCTAssertFalse(ClaimLogic.canDeleteWish(shopperWish, me: "priya", meIsShopper: false))
        XCTAssertTrue(ClaimLogic.canDeleteWish(marcusWish, me: "jake", meIsShopper: true))
        XCTAssertTrue(ClaimLogic.canDeleteWish(shopperWish, me: "jake", meIsShopper: true))
        // Not a wish: never.
        XCTAssertFalse(ClaimLogic.canDeleteWish(chip("milk", 429, ["priya"]), me: "priya", meIsShopper: false))
        XCTAssertFalse(ClaimLogic.canDeleteWish(chip("milk", 429), me: "jake", meIsShopper: true))
    }

    // MARK: claim decision and raise

    func testClaimDecision() {
        let eggs = chip("eggs", 872, ["priya", "marcus"])
        let tray = [eggs]
        XCTAssertEqual(ClaimLogic.decide(chip("milk", 429), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .claim)
        XCTAssertEqual(ClaimLogic.decide(eggs, tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .alreadyMine)
        // 872 + 3500 = 4372 > 4000
        XCTAssertEqual(ClaimLogic.decide(chip("tv", 3500), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .overCap)
        // Exactly the cap fits.
        XCTAssertEqual(ClaimLogic.decide(chip("tv", 3128), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .claim)
        // Tax pushes it over.
        XCTAssertEqual(ClaimLogic.decide(chip("tv", 3128), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0.1), .overCap)
        XCTAssertEqual(ClaimLogic.decide(chip("w", nil, state: .wish), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .notClaimable)
        XCTAssertEqual(ClaimLogic.decide(chip("i", nil, state: .identifying), tray: tray, me: "priya", authorizedCents: 4000, taxRate: 0), .notClaimable)
        // No hold (shopper): no cap check.
        XCTAssertEqual(ClaimLogic.decide(chip("tv", 99999), tray: [], me: "jake", authorizedCents: nil, taxRate: 0), .claim)
    }

    func testRaiseCopy() {
        XCTAssertEqual(ClaimLogic.raiseTarget(authorizedCents: 4000), 6000)
        XCTAssertEqual(ClaimLogic.overCapTitle(authorizedCents: 4000), "Over your cap. Raise it to $60?")
        XCTAssertEqual(ClaimLogic.raiseButton(authorizedCents: 4000), "Raise to $60 and claim")
        XCTAssertEqual(ClaimLogic.raiseCopy, "Your hold grows by $20. Only what you claim is captured.")
        XCTAssertEqual(ClaimLogic.overCapLine(chip("coffee", 1499), roomCents: 729), "$14.99 · more than your $7.29 room")
        XCTAssertEqual(ClaimLogic.overCapLine(chip("coffee", nil), roomCents: -50), "Price not known yet · more than your $0.00 room")
    }

    // MARK: copy

    func testHeaderAndBanners() {
        XCTAssertEqual(ClaimLogic.statusLine(run([])), "Live · 4 in the run")
        XCTAssertEqual(ClaimLogic.statusLine(run([], state: .lastCall)), "Live · 4 in the run")
        XCTAssertEqual(ClaimLogic.statusLine(run([], state: .locked)), "Closed · 4 in the run")
        XCTAssertEqual(ClaimLogic.lastCallLine(shopperName: "Jake", secs: 7), "Jake is checking out · last call · 7s")
        XCTAssertEqual(ClaimLogic.closedLine(trayCents: 436, count: 1), "Your tray is $4.36 across 1 item")
        XCTAssertEqual(ClaimLogic.closedLine(trayCents: 0, count: 0), "Your tray is $0.00 across 0 items")
        XCTAssertEqual(ClaimLogic.notice("over cap"), "Over cap")
    }

    func testWishCopy() {
        let p = people
        let mine = chip("bagels", nil, state: .wish, wishedBy: "priya")
        let theirs = chip("oat", nil, state: .wish, wishedBy: "marcus")
        XCTAssertEqual(ClaimLogic.wishWho(mine, people: p, me: "priya"), "Your wish")
        XCTAssertEqual(ClaimLogic.wishWho(theirs, people: p, me: "priya"), "Marcus's wish")
        XCTAssertEqual(ClaimLogic.wishNote(mine, people: p, me: "priya"), "Lands in your tray when Jake adds it")
        XCTAssertEqual(ClaimLogic.wishNote(theirs, people: p, me: "priya"), "Lands in Marcus's tray when Jake adds it")
    }

    // MARK: live view outline

    func testHighlightPrefersIdentifyingRegion() {
        let region = Box(x: 10, y: 20, w: 100, h: 80)
        let h = ClaimLogic.highlight(chips: [], identifying: region, nowMs: 0)
        XCTAssertEqual(h, .init(region: region, label: "Identifying…", pending: true))
    }

    func testHighlightShowsNewestChipForEightSeconds() {
        let r1 = Box(x: 0, y: 0, w: 10, h: 10), r2 = Box(x: 5, y: 5, w: 20, h: 20)
        let chips = [chip("eggs", 872, region: r1).with(addedAt: 1000), chip("milk", nil, region: r2).with(addedAt: 2000),
                     chip("w", nil, state: .wish, region: r1).with(addedAt: 5000)]
        XCTAssertEqual(ClaimLogic.highlight(chips: chips, identifying: nil, nowMs: 9999), .init(region: r2, label: "Milk · ~$?", pending: false))
        XCTAssertNil(ClaimLogic.highlight(chips: chips, identifying: nil, nowMs: 10000))
    }

    func testFrameBoxMapsThroughAspectFill() {
        // A 640x480 frame filling a 320x196 box: scale 0.5, cropped top and bottom by (240-196)/2 = 22.
        let rect = ClaimLogic.frameBoxToDisplay(Box(x: 100, y: 100, w: 200, h: 100), box: CGSize(width: 320, height: 196),
                                                imageSize: CGSize(width: 640, height: 480))
        XCTAssertEqual(rect.minX, 50, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 28, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.height, 50, accuracy: 0.001)
    }

    func testFrameBoxScalesWhenImageIsNotSentWidth() {
        // Image decoded at 1280 wide (2x the 640 frame): region in 640-frame pixels still lands in place.
        let rect = ClaimLogic.frameBoxToDisplay(Box(x: 100, y: 100, w: 200, h: 100), box: CGSize(width: 320, height: 240),
                                                imageSize: CGSize(width: 1280, height: 960))
        XCTAssertEqual(rect.minX, 50, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 50, accuracy: 0.001)
        XCTAssertEqual(rect.width, 100, accuracy: 0.001)
    }

    // MARK: usual picks

    func testRememberPicksKeepsNewestFirstUniqueAndAtMostTwenty() {
        var picks = ClaimLogic.rememberPicks(["Milk", "Eggs"], seen: ["eggs", "Bagels"])
        XCTAssertEqual(picks, ["Bagels", "eggs", "Milk"])
        picks = ClaimLogic.rememberPicks([], seen: (1...30).map { "Item \($0)" })
        XCTAssertEqual(picks.count, 20)
        XCTAssertEqual(picks.first, "Item 30")
        XCTAssertEqual(ClaimLogic.rememberPicks(["Milk"], seen: ["  ", ""]), ["Milk"])
        XCTAssertEqual(ClaimLogic.rememberPicks(["Milk"], seen: [" Oat milk "]), ["Oat milk", "Milk"])
    }

    func testSeenNamesAreWishesAndNamedChipsOldestFirst() {
        let r = run([
            chip("eggs", 872, addedAt: 3),
            chip("bagels", nil, state: .wish, addedAt: 1, wishedBy: "priya"),
            Chip(id: "i", name: "", state: .identifying, addedAt: 2),
            chip("gone", 1, state: .removed, addedAt: 4),
        ])
        XCTAssertEqual(ClaimLogic.seenNames(r), ["Bagels", "Eggs", "Gone"])
    }

    func testUsualPicksHideWhatIsAlreadyInTheRun() {
        let r = run([chip("eggs", 872), chip("bagels", nil, state: .wish, wishedBy: "marcus"), chip("gone", 1, state: .removed)])
        XCTAssertEqual(ClaimLogic.usualPicks(saved: ["Eggs", "Gone", "BAGELS", "Milk"], run: r), ["Gone", "Milk"])
    }

    func testUsualPicksStorage() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClaimLogicTests"))
        defaults.removePersistentDomain(forName: "ClaimLogicTests")
        XCTAssertEqual(ClaimLogic.savedPicks(defaults), [])
        ClaimLogic.recordSeen(["Eggs", "Milk"], defaults: defaults)
        ClaimLogic.recordSeen(["Eggs"], defaults: defaults)
        XCTAssertEqual(ClaimLogic.savedPicks(defaults), ["Eggs", "Milk"])
        XCTAssertEqual(defaults.stringArray(forKey: "dibs.usualPicks"), ["Eggs", "Milk"])
    }
}

private extension Chip {
    func with(addedAt: Double) -> Chip {
        var c = self
        c.addedAt = addedAt
        return c
    }
}
