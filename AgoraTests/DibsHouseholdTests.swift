import XCTest
@testable import Agora

/// "For your next run" on the Dibs home: which household lines show, in what order, and where they go.
final class DibsNextRunTests: XCTestCase {
    private let household = UUID()

    private func item(_ name: String, quantity: Double?, restockBelow: Double?, status: String = "active") -> InventoryItem {
        InventoryItem(id: UUID(), householdId: household, displayName: name, category: nil, locationId: nil, unit: "each",
                      parLevel: restockBelow, status: status, quantity: quantity, observedAt: nil, source: nil,
                      preferredMerchantId: nil, lastPurchasedFrom: nil, lastPurchasedOn: nil)
    }

    private func wish(_ title: String, status: String = "active", targetCents: Int? = nil, rationale: String? = nil) -> WishlistItem {
        WishlistItem(id: UUID(), householdId: household, title: title, notes: nil, category: nil, quantity: 1,
                     targetPriceCents: targetCents, neededBy: nil, source: "user", status: status, pinned: false,
                     priority: nil, confidence: nil, rationale: rationale, evidence: [], snoozedUntil: nil,
                     rejectReason: nil, myFeedback: nil, score: 0, priorityReasons: [], createdAt: Date(),
                     inventoryItemId: nil)
    }

    func testNothingToShowIsEmpty() {
        XCTAssertEqual(NextRunPicks.rows(inventory: [], wishlist: [], suggestions: []), [])
        // Stocked items, items without a restock level and archived items are not running low.
        let rows = NextRunPicks.rows(inventory: [
            item("Rice", quantity: 5, restockBelow: 2),
            item("Salt", quantity: 1, restockBelow: nil),
            item("Old jam", quantity: 0, restockBelow: 1, status: "archived"),
        ], wishlist: [], suggestions: [])
        XCTAssertEqual(rows, [])
    }

    func testRunningLowUsesTheOldHomeOrderAndKeepsThree() {
        let rows = NextRunPicks.rows(inventory: [
            item("Oat milk", quantity: 1, restockBelow: 2),
            item("Eggs", quantity: 0, restockBelow: 6),
            item("Bananas", quantity: 1, restockBelow: 3),
            item("Coffee", quantity: 0.5, restockBelow: 1),
            item("Rice", quantity: 5, restockBelow: 2),
        ], wishlist: [], suggestions: [])
        // Emptiest first; equal quantities by name. The fourth low item does not fit.
        XCTAssertEqual(rows.map(\.name), ["Eggs", "Coffee", "Bananas"])
        XCTAssertEqual(Set(rows.map(\.reason)), ["Running low"])
        XCTAssertEqual(Set(rows.map(\.page)), [.pantry])
        XCTAssertEqual(NextRunPicks.lowItems([item("Oat milk", quantity: 1, restockBelow: 2), item("Bananas", quantity: 1, restockBelow: 3)])
            .map(\.displayName), ["Bananas", "Oat milk"])
    }

    func testWishlistAndSuggestionsFollowWithTheirReasons() {
        let rows = NextRunPicks.rows(inventory: [item("Eggs", quantity: 0, restockBelow: 6)], wishlist: [
            wish("Cast iron pan", targetCents: 3500),
            wish("Picnic blanket"),
            wish("Bought already", status: "purchased"),
            wish("Lamp"),
            wish("Fourth wish"),
        ], suggestions: [
            wish("Olive oil", status: "suggested", rationale: "  You use about a bottle\na month.  "),
            wish("Paper towels", status: "suggested"),
            wish("Third idea", status: "suggested"),
        ])
        XCTAssertEqual(rows.map(\.name), ["Eggs", "Cast iron pan", "Picnic blanket", "Lamp", "Olive oil", "Paper towels"])
        XCTAssertEqual(rows.map(\.reason), [
            "Running low",
            "Target price",
            "On your wishlist",
            "On your wishlist",
            "You use about a bottle a month.",
            "Suggested for you",
        ])
        XCTAssertEqual(rows.map(\.amount), [nil, WishlistItem.money(3500), nil, nil, nil, nil], "a target price shows on the right")
        XCTAssertEqual(rows.map(\.page), [.pantry, .wishlist, .wishlist, .wishlist, .wishlist, .wishlist])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count, "row ids are unique")
    }

    func testANameAlreadyShownIsNotRepeated() {
        let rows = NextRunPicks.rows(inventory: [item("Eggs", quantity: 0, restockBelow: 6)],
                                     wishlist: [wish("Lamp")],
                                     suggestions: [wish("eggs ", status: "suggested"), wish("LAMP", status: "suggested"), wish("Tea", status: "suggested")])
        XCTAssertEqual(rows.map(\.name), ["Eggs", "Lamp", "Tea"])
    }

    func testASkippedDuplicateDoesNotUseUpALimit() {
        let rows = NextRunPicks.rows(inventory: [], wishlist: [wish("Tea")], suggestions: [
            wish("Tea", status: "suggested"), wish("Honey", status: "suggested"), wish("Lemons", status: "suggested"),
        ])
        XCTAssertEqual(rows.map(\.name), ["Tea", "Honey", "Lemons"])
    }

    func testLowItemsBeyondTheLimitDoNotHideLaterRows() {
        // The fourth running-low item is not shown, so a wish with its name still shows.
        let rows = NextRunPicks.rows(inventory: [
            item("A", quantity: 0, restockBelow: 1), item("B", quantity: 0, restockBelow: 1),
            item("C", quantity: 0, restockBelow: 1), item("D", quantity: 0, restockBelow: 1),
        ], wishlist: [wish("D")], suggestions: [])
        XCTAssertEqual(rows.map(\.name), ["A", "B", "C", "D"])
        XCTAssertEqual(rows.last?.page, .wishlist)
    }
}

/// `Route.household` next to the run routes: the path and resume logic leaves it alone.
@MainActor
final class DibsHouseholdRouteTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let ref = RunRef(runId: "r1", personId: "priya")

    override func setUp() async throws {
        suite = "dibs.household.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model() -> AppModel { AppModel(defaults: defaults, bundledServer: URL(string: "https://dibs.example.com")!) }

    private func run(_ state: RunState) -> Run {
        Run(id: "r1", state: state, store: "costco", shopperId: "jake", people: [
            Person(id: "jake", name: "Jake", initial: "J", isShopper: true),
            Person(id: "priya", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000),
        ], chips: [])
    }

    func testHouseholdRoutesAreDistinctValues() {
        let pages: [HouseholdPage] = [.lists, .pantry, .wishlist, .assistant, .capture]
        XCTAssertEqual(Set(pages.map { Route.household($0) }).count, 5)
        XCTAssertEqual(Route.household(.pantry), .household(.pantry))
        XCTAssertNotEqual(Route.household(.assistant), .claim(ref))
        let path: [Route] = [.household(.pantry), .household(.capture)]
        XCTAssertEqual(path.last, .household(.capture))
    }

    func testRunFollowingLeavesHouseholdPagesAlone() {
        let partly = run(.partlySettled)
        XCTAssertNil(SettleLogic.follow(path: [.household(.pantry)], run: partly))
        XCTAssertNil(SettleLogic.follow(path: [.household(.wishlist), .household(.capture)], run: partly))
        // The assistant opened over a run (a watch's browser review) stays until the person goes back.
        XCTAssertNil(SettleLogic.follow(path: [.claim(ref), .household(.assistant)], run: partly))
        // Back on the run screen, following works as before.
        XCTAssertEqual(SettleLogic.follow(path: [.claim(ref)], run: partly), [.settle(ref)])
    }

    func testResumeNeverLandsOnAHouseholdPage() {
        for state: RunState in [.open, .lastCall, .locked, .receipt, .settled, .partlySettled, .unknown] {
            let route = HomeRouting.route(for: run(state), personId: "priya")
            if case .household = route { XCTFail("\(state) resumed onto a household page") }
        }
    }

    func testOpenHouseholdPushesOnceAndKeepsWhatIsUnderneath() {
        let m = model()
        m.openHousehold(.pantry)
        XCTAssertEqual(m.path, [.household(.pantry)])
        m.openHousehold(.pantry)
        XCTAssertEqual(m.path, [.household(.pantry)], "already on top: not pushed twice")
        m.openHousehold(.capture)
        XCTAssertEqual(m.path, [.household(.pantry), .household(.capture)])

        m.show(.claim(ref))
        m.openHousehold(.assistant)
        XCTAssertEqual(m.path, [.claim(ref), .household(.assistant)])
    }

    func testLaunchWithNothingToResumeKeepsAHouseholdPage() async {
        let m = model()
        m.openHousehold(.wishlist)
        await m.launch()
        XCTAssertEqual(m.path, [.household(.wishlist)])
        XCTAssertFalse(m.resuming)
    }

    func testLeavingRunsFromHomeKeepsTheRunToResume() {
        let m = model()
        m.remember(ref)
        m.openHousehold(.lists)
        m.path = []
        m.leaveRun()
        XCTAssertEqual(defaults.string(forKey: HomeRouting.lastRunKey), "r1")
        XCTAssertEqual(ServerConfig.personId(runId: "r1", defaults: defaults), "priya")
    }

    func testSignedInNamePrefillsAnEmptyDibsName() {
        let m = model()
        m.prefillName(from: nil)
        XCTAssertNil(defaults.string(forKey: JoinView.nameKey))
        m.prefillName(from: "   ")
        XCTAssertNil(defaults.string(forKey: JoinView.nameKey))
        m.prefillName(from: "Alex Rivera")
        XCTAssertEqual(defaults.string(forKey: JoinView.nameKey), "Alex")
        m.prefillName(from: "Sam Lee")
        XCTAssertEqual(defaults.string(forKey: JoinView.nameKey), "Alex", "a saved name is never replaced")
    }

    func testATypedNameWins() {
        defaults.set("Priya", forKey: JoinView.nameKey)
        model().prefillName(from: "Alex Rivera")
        XCTAssertEqual(defaults.string(forKey: JoinView.nameKey), "Priya")
    }

    func testFirstNameIsTheFirstWordClampedToTheJoinLimit() {
        XCTAssertEqual(AppModel.firstName("  Alex   Rivera "), "Alex")
        XCTAssertEqual(AppModel.firstName("Cher"), "Cher")
        XCTAssertEqual(AppModel.firstName(String(repeating: "a", count: 40))?.count, 24)
        XCTAssertNil(AppModel.firstName(""))
        XCTAssertNil(AppModel.firstName(nil))
    }
}

/// The household token rides on "+ Wish" only to the build's own Dibs server.
@MainActor
final class DibsHouseholdTokenTests: XCTestCase {
    private func model(saved: String?, bundled: String?) -> AppModel {
        let defaults = UserDefaults(suiteName: "household-token-\(UUID().uuidString)")!
        if let saved { defaults.set(saved, forKey: ServerConfig.serverKey) }
        return AppModel(defaults: defaults, bundledServer: bundled.flatMap(URL.init(string:)))
    }

    func testTheBuiltInServerGetsTheToken() async {
        let m = model(saved: nil, bundled: "https://dibs.example.com")
        m.householdToken = { "tok" }
        let token = await m.householdTokenForWishPicks()
        XCTAssertEqual(token, "tok")
    }

    func testAnotherServerNeverGetsTheTokenOrAsksForIt() async {
        let m = model(saved: "https://other.example.com", bundled: "https://dibs.example.com")
        var asked = false
        m.householdToken = { asked = true; return "tok" }
        let token = await m.householdTokenForWishPicks()
        XCTAssertNil(token)
        XCTAssertFalse(asked)
    }

    func testNoBuiltInServerMeansNoToken() async {
        let m = model(saved: nil, bundled: nil)
        m.householdToken = { "tok" }
        let token = await m.householdTokenForWishPicks()
        XCTAssertNil(token)
    }

    func testSignedOutSendsNothing() async {
        let m = model(saved: nil, bundled: "https://dibs.example.com")
        let token = await m.householdTokenForWishPicks()
        XCTAssertNil(token)
        m.householdToken = { "" }
        let empty = await m.householdTokenForWishPicks()
        XCTAssertNil(empty)
    }

    func testSameServerIgnoresATrailingSlashButNothingElse() throws {
        let built = try XCTUnwrap(URL(string: "https://dibs.example.com"))
        XCTAssertTrue(ServerConfig.isSameServer(try XCTUnwrap(URL(string: "https://dibs.example.com/")), built))
        XCTAssertFalse(ServerConfig.isSameServer(try XCTUnwrap(URL(string: "https://dibs.example.com.evil.io")), built))
        XCTAssertFalse(ServerConfig.isSameServer(try XCTUnwrap(URL(string: "http://dibs.example.com")), built))
        XCTAssertFalse(ServerConfig.isSameServer(try XCTUnwrap(URL(string: "https://dibs.example.com:8443")), built))
        XCTAssertFalse(ServerConfig.isSameServer(built, nil))
    }
}

/// The household rows are always on the home; signed out, a tap signs in first and then opens the page.
final class DibsHouseholdRowActionTests: XCTestCase {
    func testSignedInOpensAndSignedOutSignsInFirst() {
        XCTAssertEqual(HouseholdRowAction.forRow(connected: true), .open)
        XCTAssertEqual(HouseholdRowAction.forRow(connected: false), .signInFirst)
    }
}

/// The invite share text carries the link, so the share sheet's Copy copies it.
final class DibsShareTextTests: XCTestCase {
    func testShareTextIncludesTheJoinLink() throws {
        let link = try XCTUnwrap(URL(string: "https://dibs.example.com/join?run=r1"))
        let text = StartLogic.shareText(title: "Jake's QFC run", link: link)
        XCTAssertEqual(text, "Join Jake's QFC run on Dibs: https://dibs.example.com/join?run=r1")
        XCTAssertTrue(text.contains(link.absoluteString))
    }
}
