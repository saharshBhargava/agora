import XCTest
@testable import Agora

final class DibsWishLogicTests: XCTestCase {
    private let jake = Person(id: "jake", name: "Jake", initial: "J", isShopper: true)
    private let priya = Person(id: "priya", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000)
    private let marcus = Person(id: "marcus", name: "Marcus", initial: "M", isShopper: false, authorizedCents: 4000)

    private func run(_ chips: [Chip] = []) -> Run {
        Run(id: "r1", state: .open, store: "QFC", shopperId: "jake", people: [jake, priya, marcus], chips: chips)
    }

    private let picks = WishPicks(
        list: .init(name: "Household essentials", store: "Target", items: [
            .init(name: "Paper towels", detail: "2 rolls"),
            .init(name: "Dish soap", detail: "1 bottle"),
            .init(name: "Oat milk", detail: ""),
        ]),
        suggestions: [
            .init(name: "Large eggs, 12 ct", reason: "Running low · about 2 days left"),
            .init(name: "Bananas", reason: "You buy these every 6 days"),
            .init(name: "dish  SOAP", reason: "Often in your QFC runs"),
        ]
    )

    func testSectionsKeepTheServerOrderWithPillsNotesAndCaptions() {
        let s = WishLogic.sections(picks: picks, run: run(), me: "priya")
        XCTAssertEqual(s.listCaption, "Household essentials · Target")
        XCTAssertEqual(s.list.map(\.name), ["Paper towels", "Dish soap", "Oat milk"])
        XCTAssertEqual(s.list.map(\.line), ["2 rolls", "1 bottle", ""])
        XCTAssertEqual(s.list.first?.pill, "On your list")
        XCTAssertEqual(s.suggestions.map(\.name), ["Large eggs, 12 ct", "Bananas"], "a suggestion already on the list shows once")
        XCTAssertEqual(s.suggestions.first?.pill, "Suggested")
        XCTAssertEqual(s.suggestions.first?.line, "Running low · about 2 days left")
        XCTAssertEqual(s.suggestionsCaption, "From your home")
        XCTAssertTrue(s.usual.isEmpty)
        XCTAssertNil(s.empty)
        XCTAssertNil(s.listEmpty)
        XCTAssertTrue((s.list + s.suggestions).allSatisfy { $0.mark == .add })
    }

    func testItemsInTheCartAreHiddenLive() {
        let r = run([
            Chip(id: "a", name: "paper towels", priceCents: 899, state: .claimed),
            Chip(id: "b", name: "Bananas", state: .identifying),
            Chip(id: "c", name: "Large Eggs, 12ct", state: .removed),
            Chip(id: "d", name: "Dish soap", dropped: true),
        ])
        let s = WishLogic.sections(picks: picks, run: r, me: "priya")
        XCTAssertEqual(s.list.map(\.name), ["Dish soap", "Oat milk"])
        XCTAssertEqual(s.suggestions.map(\.name), ["Large eggs, 12 ct", "Bananas"])
    }

    func testMyWishesAndJustWishedOnesAreMarkedWished() {
        let r = run([
            Chip(id: "w1", name: "Oat Milk", state: .wish, wishedBy: "priya"),
            Chip(id: "w2", name: "Bananas", state: .wish, wishedBy: "marcus"),
        ])
        let s = WishLogic.sections(picks: picks, run: r, me: "priya", justWished: [WishLogic.key("Large eggs, 12 ct")])
        XCTAssertEqual(s.list.map(\.mark), [.add, .add, .wished])
        XCTAssertEqual(s.list.last?.line, "Wished · in your tray when added")
        XCTAssertEqual(s.list.last?.pill, "On your list", "a wished list item keeps its pill")
        XCTAssertEqual(s.suggestions.map(\.mark), [.wished, .add], "Marcus's wish is not mine")
    }

    func testTheShoppersOwnWishesAreNobodys() {
        let r = run([Chip(id: "w", name: "Dish soap", state: .wish, wishedBy: nil)])
        XCTAssertEqual(WishLogic.wishedKeys(r, me: "jake"), ["dishsoap"])
        XCTAssertEqual(WishLogic.wishedKeys(r, me: "priya"), [])
    }

    func testAListWithEverythingInTheCartSaysSo() {
        let one = WishPicks(list: .init(name: "Saturday", store: nil, items: [.init(name: "Bread", detail: "")]), suggestions: [])
        let s = WishLogic.sections(picks: one, run: run([Chip(id: "b", name: "Bread", state: .open)]), me: "priya", usual: ["Milk"])
        XCTAssertEqual(s.listCaption, "Saturday")
        XCTAssertEqual(s.listEmpty, "Everything on your list is in the cart")
        XCTAssertEqual(s.usual.map(\.name), ["Milk"], "usual picks fill in when the server offers nothing")
        XCTAssertNil(s.empty)
    }

    func testNoListMeansNoListSection() {
        let s = WishLogic.sections(picks: WishPicks(list: nil, suggestions: [.init(name: "Greek yogurt", reason: "In your last run")]),
                                   run: run(), me: "priya", usual: ["Milk"])
        XCTAssertNil(s.listCaption)
        XCTAssertNil(s.listEmpty)
        XCTAssertEqual(s.suggestions.map(\.name), ["Greek yogurt"])
        XCTAssertEqual(s.suggestionsCaption, "From your runs")
        XCTAssertTrue(s.usual.isEmpty, "usual picks only when both server sections are empty")
        XCTAssertNil(s.empty)
    }

    func testNothingFromTheServerFallsBackToUsualPicksThenTheEmptyLine() {
        let r = run([Chip(id: "w", name: "Bagels", state: .wish, wishedBy: "priya"), Chip(id: "m", name: "Milk", state: .open)])
        let failed = WishLogic.sections(picks: nil, run: r, me: "priya", usual: ["Bagels", "Milk", "Bananas", "bananas"])
        XCTAssertEqual(failed.usual.map(\.name), ["Bagels", "Bananas"])
        XCTAssertEqual(failed.usual.map(\.mark), [.wished, .add])
        XCTAssertEqual(failed.usual.first?.pill, "Usual pick")
        XCTAssertEqual(failed.usual.last?.line, "In your recent runs")
        XCTAssertNil(failed.empty)

        let nothing = WishLogic.sections(picks: WishPicks(list: nil, suggestions: []), run: run(), me: "priya")
        XCTAssertEqual(nothing.empty, "No list yet — type anything above")
        XCTAssertNil(nothing.listCaption)
    }

    func testRowsAreCappedAtTwelveAndBlankNamesSkipped() {
        let many = WishPicks(list: .init(name: "Big", store: "", items: (0..<20).map { .init(name: "Item \($0)", detail: "") } + [.init(name: "  ", detail: "")]),
                             suggestions: (0..<20).map { .init(name: "Idea \($0)", reason: "") })
        let s = WishLogic.sections(picks: many, run: run(), me: "priya")
        XCTAssertEqual(s.list.count, 12)
        XCTAssertEqual(s.suggestions.count, 12)
        XCTAssertEqual(s.listCaption, "Big", "an empty store adds no dot")
    }

    func testCopy() {
        XCTAssertEqual(WishLogic.subtitle(shopperName: "Jake"), "It lands in your tray when Jake adds it.")
        XCTAssertEqual(WishLogic.subtitle(shopperName: nil), "It lands in your tray when the shopper adds it.")
        XCTAssertEqual(WishLogic.confirmation("Bagels"), "Wished Bagels · in your tray when added")
        XCTAssertEqual(WishLogic.key("  Large Eggs,  12 ct "), "largeeggs12ct")
    }
}

final class DibsWishPicksAPITests: XCTestCase {
    private var api: DibsAPI!

    override func setUp() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        api = DibsAPI(base: URL(string: "https://dibs.example.com/")!, session: URLSession(configuration: config))
        StubProtocol.reset()
    }

    func testGetsAndDecodesWishPicks() async throws {
        StubProtocol.reply(200, #"{"list":{"name":"Household essentials","store":"Target","items":[{"name":"Dish soap","detail":"2 bottles"}]},"suggestions":[{"name":"Bananas","reason":"In your last run"}]}"#)
        let picks = try await api.wishPicks(runId: "r 1", personId: "p&1")
        XCTAssertEqual(picks, WishPicks(list: .init(name: "Household essentials", store: "Target", items: [.init(name: "Dish soap", detail: "2 bottles")]),
                                        suggestions: [.init(name: "Bananas", reason: "In your last run")]))
        let req = try XCTUnwrap(StubProtocol.requests.last)
        XCTAssertEqual(req.method, "GET")
        XCTAssertEqual(req.url.absoluteString, "https://dibs.example.com/api/runs/r%201/wish-picks?personId=p%261")
        XCTAssertNil(req.body)
    }

    func testSendsTheHouseholdTokenOnlyWhenGiven() async throws {
        StubProtocol.reply(200, #"{"list":null,"suggestions":[]}"#)
        _ = try await api.wishPicks(runId: "r1", personId: "p1", householdToken: "tok-123")
        XCTAssertEqual(StubProtocol.requests.last?.household, "tok-123")
        _ = try await api.wishPicks(runId: "r1", personId: "p1")
        XCTAssertNil(StubProtocol.requests.last?.household)
        _ = try await api.wishPicks(runId: "r1", personId: "p1", householdToken: "")
        XCTAssertNil(StubProtocol.requests.last?.household)
    }

    func testNoListDecodesAsNil() async throws {
        StubProtocol.reply(200, #"{"list":null,"suggestions":[]}"#)
        let picks = try await api.wishPicks(runId: "r1", personId: "p1")
        XCTAssertNil(picks.list)
        XCTAssertEqual(picks.suggestions, [])
    }

    func testErrorsMapLikeTheOtherCalls() async {
        StubProtocol.reply(409, #"{"error":"unknown person"}"#)
        do {
            _ = try await api.wishPicks(runId: "r1", personId: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .server(message: "unknown person", status: 409))
        }
        StubProtocol.fail(.timedOut)
        do {
            _ = try await api.wishPicks(runId: "r1", personId: "x")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .timeout)
        }
    }
}
