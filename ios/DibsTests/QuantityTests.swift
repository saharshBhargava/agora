import XCTest
@testable import Dibs

/// Item quantity: the same product seen again is one chip "×2"; `priceCents` stays the price of one and
/// every share, room and total uses the line total (unit × quantity, or the receipt's exact total), the
/// same `lineCents` as server/src/money.ts.
final class QuantityTests: XCTestCase {
    private let jake = Person(id: "jake", name: "Jake", initial: "J", isShopper: true)
    private let priya = Person(id: "priya", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000)
    private let marcus = Person(id: "marcus", name: "Marcus", initial: "M", isShopper: false, authorizedCents: 4000)
    private let lee = Person(id: "lee", name: "Lee", initial: "L", isShopper: false, authorizedCents: 2000)
    private var people: [Person] { [jake, priya, marcus, lee] }

    private func apple(_ quantity: Int = 2, price: Int? = 110, claimers: [String] = [], state: ChipState? = nil,
                       receiptTotal: Int? = nil) -> Chip {
        var c = Chip(id: "apple", name: "Cosmic Crisp Apple", priceCents: price, priceSource: .web, quantity: quantity,
                     claimers: claimers, state: state ?? (claimers.isEmpty ? .open : .claimed), addedAt: 1)
        c.receiptTotalCents = receiptTotal
        return c
    }

    private func run(_ chips: [Chip], state: RunState = .open, receipt: ReceiptState? = nil) -> Run {
        Run(id: "r1", state: state, store: "QFC", shopperId: "jake", people: people, chips: chips, receipt: receipt)
    }

    // MARK: model

    func testDecodesQuantityFieldsFromTheServer() throws {
        let json = #"""
        {"id":"apple","name":"Cosmic Crisp Apple","priceCents":110,"priceSource":"receipt","quantity":2,
         "receiptTotalCents":219,"lastSeenAt":9000,"claimers":[],"state":"matched"}
        """#
        let chip = try JSONDecoder().decode(Chip.self, from: Data(json.utf8))
        XCTAssertEqual(chip.quantity, 2)
        XCTAssertEqual(chip.receiptTotalCents, 219)
        XCTAssertEqual(chip.lineCents, 219)
        let older = try JSONDecoder().decode(Chip.self, from: Data(#"{"id":"m","name":"Milk","priceCents":429,"state":"open"}"#.utf8))
        XCTAssertEqual(older.quantity, 1)
        XCTAssertNil(older.receiptTotalCents)
        XCTAssertEqual(older.lineCents, 429)
        let receipt = try JSONDecoder().decode(ReceiptState.self, from: Data(#"""
        {"lines":[],"matches":[],"unmatchedLines":[],"cartQuantities":{"apple":2}}
        """#.utf8))
        XCTAssertEqual(receipt.cartQuantities, ["apple": 2])
    }

    func testLineTotalIsUnitTimesQuantityOrTheReceiptTotal() {
        XCTAssertEqual(apple().lineCents, 220)
        XCTAssertEqual(apple(1).lineCents, 110)
        XCTAssertEqual(apple(receiptTotal: 219).lineCents, 219)
        XCTAssertNil(apple(price: nil).lineCents)
    }

    func testTimesNOnlyAboveOne() {
        XCTAssertEqual(apple().nameWithQty, "Cosmic Crisp Apple ×2")
        XCTAssertEqual(apple(1).nameWithQty, "Cosmic Crisp Apple")
        XCTAssertEqual(Chip.qtyText(1), "")
        XCTAssertEqual(Chip.qtyText(3), "×3")
    }

    // MARK: claim screen

    func testMyShareSplitsTheLineTotalLeftoverToTheEarliest() {
        let c = apple(claimers: ["priya", "marcus", "lee"])
        XCTAssertEqual(ClaimLogic.myShare(c, me: "priya"), 74)
        XCTAssertEqual(ClaimLogic.myShare(c, me: "marcus"), 73)
        XCTAssertEqual(ClaimLogic.myShare(c, me: "lee"), 73)
        XCTAssertEqual(ClaimLogic.traySummary([c], me: "priya"), "1 item · $0.74")
    }

    func testRoomCountsTheFullLineTotal() {
        let r = run([apple(3, claimers: ["priya", "marcus"])])
        XCTAssertEqual(ClaimLogic.roomLeft(run: r, me: "priya"), 4000 - 330)
    }

    func testTheCapCheckUsesTheLineTotal() {
        let wine = Chip(id: "wine", name: "Red Wine", priceCents: 1500, quantity: 3, state: .open)
        XCTAssertEqual(ClaimLogic.decide(wine, roomChips: [], me: "priya", authorizedCents: 4000, taxRate: 0), .overCap)
        var two = wine
        two.quantity = 2
        XCTAssertEqual(ClaimLogic.decide(two, roomChips: [], me: "priya", authorizedCents: 4000, taxRate: 0), .claim)
        XCTAssertEqual(ClaimLogic.neededHold(for: wine, roomChips: [], taxRate: 0), 4500)
    }

    @MainActor
    func testClaimChipShowsTheLineTotalAndTheCount() {
        XCTAssertEqual(ClaimLogic.priceText(apple()), "$2.20")
        XCTAssertEqual(ClaimLogic.priceText(apple(price: nil)), "Finding price…")
        XCTAssertEqual(ChipCard.label(apple(claimers: ["priya"]), people: people), "Cosmic Crisp Apple ×2, $2.20, claimed by P")
        XCTAssertEqual(ClaimLogic.overCapLine(apple(), roomCents: 100), "$2.20 · more than your $1.00 room")
        XCTAssertEqual(ClaimLogic.overHoldLine(apple(), roomCents: -20), "$2.20 · $0.20 over your hold")
    }

    @MainActor
    func testTrayRowNamesTheCountAndMySplit() {
        let c = apple(claimers: ["priya", "marcus"])
        XCTAssertEqual(TrayRow.label(c, me: "priya"), "Cosmic Crisp Apple ×2, your share $1.10, split 2 ways")
    }

    func testLiveViewLabelCarriesTheCount() {
        var c = apple()
        c.region = Box(x: 0, y: 0, w: 10, h: 10)
        c.addedAt = 1000
        XCTAssertEqual(ClaimLogic.highlight(chips: [c], identifying: nil, nowMs: 2000)?.label, "Cosmic Crisp Apple ×2 · $2.20")
    }

    // MARK: shopper screen

    func testCoveredTotalUsesLineTotals() {
        let cover = ShopperLogic.coverage(people: people, chips: [apple(claimers: ["priya", "marcus", "jake"])])
        XCTAssertEqual(cover.totalCents, 220)
        XCTAssertEqual(cover.segments, [.init(id: "priya", name: "Priya", cents: 74), .init(id: "marcus", name: "Marcus", cents: 73)])
        XCTAssertEqual(cover.coveredCents, 147)
    }

    @MainActor
    func testShopperRowShowsTheLineTotalAndTheUnitUnderTheName() {
        XCTAssertEqual(ShopperLogic.price(apple()), "$2.20")
        XCTAssertEqual(ShopperLogic.quantityLine(apple()), "×2 · $1.10 each")
        XCTAssertEqual(ShopperLogic.quantityLine(apple(price: nil)), "×2")
        XCTAssertNil(ShopperLogic.quantityLine(apple(1)))
        XCTAssertEqual(CartRowView.label(apple(), people: people), "Cosmic Crisp Apple ×2, $2.20, not claimed")
    }

    func testStepperStaysWithinOneToTwenty() {
        XCTAssertEqual(ShopperLogic.maxQuantity, 20)
        XCTAssertNil(ShopperLogic.step(1, by: -1))
        XCTAssertEqual(ShopperLogic.step(1, by: 1), 2)
        XCTAssertNil(ShopperLogic.step(20, by: 1))
        XCTAssertEqual(ShopperLogic.step(20, by: -1), 19)
    }

    func testStepperShowsOnItemsWhileTheCartTakesChanges() {
        XCTAssertTrue(ShopperLogic.canAdjustQuantity(apple(), runState: .open))
        XCTAssertTrue(ShopperLogic.canAdjustQuantity(apple(), runState: .lastCall))
        XCTAssertFalse(ShopperLogic.canAdjustQuantity(apple(), runState: .locked))
        XCTAssertFalse(ShopperLogic.canAdjustQuantity(apple(), runState: nil))
        XCTAssertFalse(ShopperLogic.canAdjustQuantity(Chip(id: "w", name: "Bagels", state: .wish), runState: .open))
        XCTAssertFalse(ShopperLogic.canAdjustQuantity(Chip(id: "i", name: "", state: .identifying), runState: .open))
        XCTAssertFalse(ShopperLogic.canAdjustQuantity(apple(state: .removed), runState: .open))
    }

    func testFixSheetSendsTheQuantityOnlyWhenItChanged() {
        XCTAssertNil(ShopperLogic.quantityChange(apple(), to: 2))
        XCTAssertEqual(ShopperLogic.quantityChange(apple(), to: 3), 3)
        XCTAssertEqual(ShopperLogic.priceLabel(quantity: 1), "Price")
        XCTAssertEqual(ShopperLogic.priceLabel(quantity: 2), "Price each")
    }

    // MARK: settle and receipt check

    func testStaysWithNamesTheCountAndTheLineTotal() {
        let r = run([apple(state: .matched, receiptTotal: 219)], state: .settled)
        XCTAssertEqual(SettleLogic.staysWith(run: r), "Cosmic Crisp Apple ×2, $2.19, stays with Jake.")
    }

    func testCapturedPreviewSplitsTheReceiptTotal() {
        let receipt = ReceiptState(lines: [ReceiptLine(text: "2 @ APPLE", cents: 219, quantity: 2)],
                                   matches: [ReceiptMatch(chipId: "apple", lineIndex: 0, confidence: 1)], unmatchedLines: [])
        let r = run([apple(claimers: ["priya", "marcus"], state: .matched, receiptTotal: 219)], state: .receipt, receipt: receipt)
        XCTAssertEqual(SettleLogic.captured(run: r), SettleLogic.Captured(label: "Captured from Priya and Marcus", amount: "$2.19"))
        XCTAssertEqual(SettleLogic.checkRows(run: r).first?.sub, "Cosmic Crisp Apple ×2 · Priya, Marcus")
    }

    func testAChipCountedTwiceWithOneLineCanStillBePaired() {
        var receipt = ReceiptState(
            lines: [ReceiptLine(text: "APPLE", cents: 110), ReceiptLine(text: "APL", cents: 110), ReceiptLine(text: "EGGS", cents: 872)],
            matches: [ReceiptMatch(chipId: "apple", lineIndex: 0, confidence: 1), ReceiptMatch(chipId: "eggs", lineIndex: 2, confidence: 1)],
            unmatchedLines: [1])
        receipt.cartQuantities = ["apple": 2, "eggs": 1, "milk": 1]
        let chips = [
            apple(1, state: .matched),
            Chip(id: "eggs", name: "Eggs", priceCents: 872, state: .matched),
            Chip(id: "milk", name: "Milk", priceCents: 429, state: .unmatched),
        ]
        let r = run(chips, state: .receipt, receipt: receipt)
        XCTAssertEqual(SettleLogic.pairable(run: r).map(\.id), ["apple", "milk"])
        XCTAssertEqual(SettleLogic.notOnReceipt(run: r), "Not on receipt: Milk")
    }

    func testUnclaimedRowShowsTheCountAndTheLineTotal() {
        XCTAssertEqual(ShopperLogic.unclaimedName(apple(state: .locked)), "Cosmic Crisp Apple ×2")
        XCTAssertEqual(ShopperLogic.unclaimedPrice(apple(state: .locked)), "$2.20")
        XCTAssertEqual(ShopperLogic.unclaimedPrice(apple(price: nil, state: .locked)), "~$?")
    }
}
