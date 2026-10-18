import XCTest
@testable import Dibs

final class JoinLinkTests: XCTestCase {
    func testAppSchemeLink() throws {
        let link = try XCTUnwrap(JoinLink.parse("dibs://join?run=abc"))
        XCTAssertEqual(link.runId, "abc")
        XCTAssertNil(link.server)
        XCTAssertFalse(link.decline)
    }

    func testPastedServerLink() throws {
        let link = try XCTUnwrap(JoinLink.parse("https://x.ngrok.app/join?run=abc"))
        XCTAssertEqual(link.runId, "abc")
        XCTAssertEqual(link.server?.absoluteString, "https://x.ngrok.app")
    }

    func testPastedLinkWithWhitespaceAndTrailingSlash() throws {
        let link = try XCTUnwrap(JoinLink.parse("  https://x.ngrok.app/join/?run=abc\n"))
        XCTAssertEqual(link.runId, "abc")
        XCTAssertEqual(link.server?.absoluteString, "https://x.ngrok.app")
    }

    func testServerUnderAPathAndPort() throws {
        let link = try XCTUnwrap(JoinLink.parse("https://example.com:8443/dibs/join?run=a3a5112e-8e2d-4790-852b-b431bb200e5f"))
        XCTAssertEqual(link.runId, "a3a5112e-8e2d-4790-852b-b431bb200e5f")
        XCTAssertEqual(link.server?.absoluteString, "https://example.com:8443/dibs")
    }

    func testLocalhostHTTPIsAllowedButNotOtherHTTP() throws {
        XCTAssertEqual(JoinLink.parse("http://localhost:3000/join?run=abc")?.server?.absoluteString, "http://localhost:3000")
        XCTAssertNil(JoinLink.parse("http://x.ngrok.app/join?run=abc"))
    }

    func testDeclineFlag() {
        XCTAssertEqual(JoinLink.parse("dibs://join?run=abc&decline=1")?.decline, true)
        XCTAssertEqual(JoinLink.parse("https://x.ngrok.app/join?run=abc&decline=0")?.decline, false)
    }

    func testGarbageIsNil() {
        let bad = [
            "", "hello", "abc", "join?run=abc", "dibs://join", "dibs://join?run=", "dibs://claim?run=abc",
            "dibs://join/extra?run=abc", "https://x.ngrok.app/claim?run=abc", "https://x.ngrok.app/join",
            "https://x.ngrok.app/join?room=abc", "ftp://x.ngrok.app/join?run=abc", "https:///join?run=abc",
            "https://x.ngrok.app/join?run=a%20b", "https://x.ngrok.app/join?run=../x",
            "mailto:join?run=abc", "https://x.ngrok.app/rejoin?run=abc",
        ]
        for text in bad { XCTAssertNil(JoinLink.parse(text), text) }
    }

    func testRoundTripsTheAPIJoinLink() throws {
        let api = DibsAPI(base: URL(string: "https://x.ngrok.app")!)
        let link = try XCTUnwrap(JoinLink.parse(api.joinLink(runId: "run-1").absoluteString))
        XCTAssertEqual(link.runId, "run-1")
        XCTAssertEqual(link.server, api.base)
    }
}

final class HomeRoutingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "dibs.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeRun(_ state: RunState = .open, chips: [Chip] = []) -> Run {
        Run(id: "r1", state: state, store: "costco", shopperId: "jake", people: [
            Person(id: "jake", name: "Jake", initial: "J", isShopper: true),
            Person(id: "priya", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000),
        ], chips: chips)
    }

    func testNoSavedRunMeansHome() {
        XCTAssertNil(HomeRouting.savedRun(defaults: defaults))
    }

    func testLastRunWithoutAPersonMeansHome() {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        XCTAssertNil(HomeRouting.savedRun(defaults: defaults))
    }

    func testLastRunWithAPersonIsSaved() {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        ServerConfig.savePersonId("priya", runId: "r1", defaults: defaults)
        XCTAssertEqual(HomeRouting.savedRun(defaults: defaults), RunRef(runId: "r1", personId: "priya"))
    }

    func testRouteForAClaimer() {
        XCTAssertEqual(HomeRouting.route(for: makeRun(), personId: "priya"), .claim(RunRef(runId: "r1", personId: "priya")))
        XCTAssertEqual(HomeRouting.route(for: makeRun(.lastCall), personId: "priya"), .claim(RunRef(runId: "r1", personId: "priya")))
        XCTAssertEqual(HomeRouting.route(for: makeRun(.partlySettled), personId: "priya"), .claim(RunRef(runId: "r1", personId: "priya")))
    }

    func testRouteForTheShopper() {
        let ref = RunRef(runId: "r1", personId: "jake")
        XCTAssertEqual(HomeRouting.route(for: makeRun(), personId: "jake"), .start(ref))
        XCTAssertEqual(HomeRouting.route(for: makeRun(chips: [Chip(id: "c1", name: "Eggs")]), personId: "jake"), .shopper(ref))
        XCTAssertEqual(HomeRouting.route(for: makeRun(.receipt), personId: "jake"), .shopper(ref))
    }

    func testSettledRunOrStrangerIsNotResumed() {
        XCTAssertNil(HomeRouting.route(for: makeRun(.settled), personId: "priya"))
        XCTAssertNil(HomeRouting.route(for: makeRun(.settled), personId: "jake"))
        XCTAssertNil(HomeRouting.route(for: makeRun(), personId: "someone-else"))
    }

    func testLaunchWithoutASavedPersonStaysHomeAndDoesNotFetch() async {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        let fetched = Counter()
        let open = makeRun()
        let route = await HomeRouting.launchRoute(defaults: defaults) { _ in
            await fetched.bump()
            return open
        }
        XCTAssertNil(route)
        let n = await fetched.value
        XCTAssertEqual(n, 0)
    }

    func testLaunchWithASavedPersonResumesTheRun() async {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        ServerConfig.savePersonId("priya", runId: "r1", defaults: defaults)
        let open = makeRun()
        let route = await HomeRouting.launchRoute(defaults: defaults) { id in
            XCTAssertEqual(id, "r1")
            return open
        }
        XCTAssertEqual(route, .claim(RunRef(runId: "r1", personId: "priya")))
    }

    func testLaunchWithASavedPersonButSettledRunStaysHome() async {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        ServerConfig.savePersonId("priya", runId: "r1", defaults: defaults)
        let settled = makeRun(.settled)
        let route = await HomeRouting.launchRoute(defaults: defaults) { _ in settled }
        XCTAssertNil(route)
    }

    func testLaunchWhenTheServerIsUnreachableStaysHome() async {
        HomeRouting.saveLastRun("r1", defaults: defaults)
        ServerConfig.savePersonId("priya", runId: "r1", defaults: defaults)
        let route = await HomeRouting.launchRoute(defaults: defaults) { _ in throw DibsError.offline }
        XCTAssertNil(route)
    }
}

private actor Counter {
    var value = 0
    func bump() { value += 1 }
}

final class RunTextTests: XCTestCase {
    func testRunTitle() {
        XCTAssertEqual(RunText.title(shopperName: "Jake", store: "costco"), "Jake's Costco run")
        XCTAssertEqual(RunText.title(shopperName: nil, store: "qfc"), "The Qfc run")
        XCTAssertEqual(RunText.title(shopperName: "Jake", store: ""), "Jake's run")
        XCTAssertEqual(RunText.openHeadline(store: "costco"), "Your Costco run is open")
        XCTAssertEqual(RunText.openHeadline(store: ""), "Your run is open")
    }

    func testListNames() {
        XCTAssertEqual(RunText.listNames([]), "")
        XCTAssertEqual(RunText.listNames(["Priya"]), "Priya")
        XCTAssertEqual(RunText.listNames(["Priya", "Marcus"]), "Priya and Marcus")
        XCTAssertEqual(RunText.listNames(["Priya", "Marcus", "Lee"]), "Priya, Marcus and Lee")
    }

    func testWhoLineFromTheFixture() throws {
        let run = try Run.decode(fixtureData("run"))
        XCTAssertEqual(RunText.whoLine(run: run, excluding: nil), "Jake is shopping · Priya and Marcus are in")
        let priya = try XCTUnwrap(run.people.first { $0.name == "Priya" })
        XCTAssertEqual(RunText.whoLine(run: run, excluding: priya.id), "Jake is shopping · Marcus is in")
    }

    func testInitial() {
        XCTAssertEqual(RunText.initial(of: "  lee"), "L")
        XCTAssertEqual(RunText.initial(of: ""), "?")
    }

    func testCartTilesAreTheLatestThreeLiveChips() {
        let run = Run(id: "r", shopperId: "j", chips: [
            Chip(id: "a", name: "A", addedAt: 1), Chip(id: "b", name: "B", addedAt: 2),
            Chip(id: "w", name: "Wish", state: .wish, addedAt: 9), Chip(id: "x", name: "X", state: .removed, addedAt: 8),
            Chip(id: "p", name: "P", putBack: true, addedAt: 7), Chip(id: "c", name: "C", addedAt: 3),
            Chip(id: "d", name: "D", addedAt: 4),
        ])
        XCTAssertEqual(RunText.cartTiles(run).map(\.id), ["d", "c", "b"])
    }

    func testQRCodeRendersTheLink() throws {
        let image = try XCTUnwrap(QRCode.cgImage(for: "https://x.ngrok.app/join?run=abc"))
        XCTAssertGreaterThan(image.width, 20)
        XCTAssertEqual(image.width, image.height)
    }
}
