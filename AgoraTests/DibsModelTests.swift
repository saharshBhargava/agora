import XCTest
@testable import Agora

final class DibsModelTests: XCTestCase {
    private let priya = "252defdd-68a7-473a-96c3-0f1b5e781df6"
    private let marcus = "abea27ec-1781-4719-8fac-382dc040dcee"

    // MARK: Run decoding (fixtures captured from the real server)

    func testDecodesOpenRunFromServer() throws {
        let run = try Run.decode(fixtureData("run"))
        XCTAssertEqual(run.id, "a3a5112e-8e2d-4790-852b-b431bb200e5f")
        XCTAssertEqual(run.state, .open)
        XCTAssertEqual(run.store, "costco")
        XCTAssertEqual(run.shopperId, "jake")
        XCTAssertEqual(run.people.map(\.name), ["Jake", "Priya", "Marcus"])
        XCTAssertEqual(run.shopper?.isShopper, true)
        XCTAssertNil(run.shopper?.authorizedCents)
        XCTAssertEqual(run.person(priya)?.authorizedCents, 4000)
        XCTAssertEqual(run.person(marcus)?.initial, "M")
        XCTAssertNil(run.lastCallEndsAt)
        XCTAssertNil(run.receipt)
        XCTAssertNil(run.payout)
        XCTAssertTrue(run.settle.isEmpty)

        XCTAssertEqual(run.chips.count, 3)
        let wish = run.chips[0]
        XCTAssertEqual(wish.state, .wish)
        XCTAssertEqual(wish.name, "oat milk")
        XCTAssertEqual(wish.wishedBy, marcus)
        XCTAssertNil(wish.priceCents)

        let eggs = run.chips[1]
        XCTAssertEqual(eggs.name, "Kirkland Eggs 24 ct")
        XCTAssertEqual(eggs.state, .claimed)
        XCTAssertEqual(eggs.priceCents, 872)
        XCTAssertEqual(eggs.priceSource, .sticker)
        XCTAssertEqual(eggs.claimers, [priya, marcus])
        XCTAssertEqual(eggs.quantity, 1)
        XCTAssertFalse(eggs.putBack)
        XCTAssertFalse(eggs.dropped)
        XCTAssertTrue(eggs.overCap.isEmpty)
        XCTAssertTrue(eggs.photoUrl?.hasPrefix("data:image/jpeg;base64,") ?? false)
        XCTAssertGreaterThan(eggs.addedAt, 1_700_000_000_000)

        XCTAssertEqual(run.chips[2].claimers, [priya])
    }

    func testDecodesSettledRunFromServer() throws {
        let run = try Run.decode(fixtureData("run-settled"))
        XCTAssertEqual(run.state, .settled)
        let receipt = try XCTUnwrap(run.receipt)
        XCTAssertEqual(receipt.lines.count, 3)
        XCTAssertEqual(receipt.lines[0], ReceiptLine(text: "KS EGGS 24CT", cents: 872, quantity: 1, isTax: false))
        XCTAssertEqual(receipt.matches.count, 2)
        XCTAssertEqual(receipt.unmatchedLines, [2])
        XCTAssertNil(receipt.mine)
        let p = try XCTUnwrap(run.settle[priya])
        XCTAssertEqual(p.step, .captured)
        XCTAssertEqual(p.shareCents, 2835)
        XCTAssertEqual(p.capturedCents, 2835)
        XCTAssertEqual(p.releasedCents, 1165)
        XCTAssertEqual(run.settle[marcus]?.shareCents, 436)
        let payout = try XCTUnwrap(run.payout)
        XCTAssertTrue(payout.simulated)
        XCTAssertEqual(payout.businessApplicationId, "FD")
        XCTAssertEqual(payout.amountCents, 3271)
        XCTAssertEqual(run.chips.map(\.state), [.wish, .matched, .matched])
    }

    func testUnknownEnumValuesDecodeToUnknown() throws {
        let json = """
        {"id":"r","state":"teleported","store":"qfc","shopperId":"s","people":[],"taxRate":0.1,
         "lastCallEndsAt":null,"receipt":null,"settle":{"x":{"step":"vanished","shareCents":1,"capturedCents":0,
         "releasedCents":0,"owedCents":0,"approvalCode":null,"captureId":null,"error":null}},"payout":null,
         "chips":[{"id":"c","name":"n","priceCents":null,"priceSource":"psychic","photoUrl":null,"region":null,
         "quantity":1,"claimers":[],"state":"floating","wishedBy":null,"duplicateOf":null,"putBack":false,
         "dropped":false,"overCap":[],"removedAt":null,"addedAt":1}]}
        """
        let run = try Run.decode(Data(json.utf8))
        XCTAssertEqual(run.state, .unknown)
        XCTAssertEqual(run.chips[0].state, .unknown)
        XCTAssertEqual(run.chips[0].priceSource, .unknown)
        XCTAssertEqual(run.settle["x"]?.step, .unknown)
    }

    func testChipToleratesMissingOptionalFields() throws {
        let json = #"{"id":"c","name":"Milk","state":"open","region":{"x":1,"y":2.5,"w":3,"h":4}}"#
        let chip = try JSONDecoder().decode(Chip.self, from: Data(json.utf8))
        XCTAssertEqual(chip.claimers, [])
        XCTAssertEqual(chip.quantity, 1)
        XCTAssertEqual(chip.priceSource, PriceSource.none)
        XCTAssertEqual(chip.region, Box(x: 1, y: 2.5, w: 3, h: 4))
    }

    // MARK: Money

    func testMoneyFormat() {
        XCTAssertEqual(Money.format(436), "$4.36")
        XCTAssertEqual(Money.format(-100), "-$1.00")
        XCTAssertEqual(Money.format(0), "$0.00")
        XCTAssertEqual(Money.format(5), "$0.05")
        XCTAssertEqual(Money.format(-5), "-$0.05")
        XCTAssertEqual(Money.format(123456), "$1234.56")
        XCTAssertEqual(Money.whole(4000), "$40")
        XCTAssertEqual(Money.whole(4050), "$40.50")
    }

    func testMoneyParse() {
        XCTAssertEqual(Money.parse("8.72"), 872)
        XCTAssertEqual(Money.parse("$8"), 800)
        XCTAssertEqual(Money.parse(" 8.5 "), 850)
        XCTAssertNil(Money.parse("8.725"))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse(""))
        XCTAssertNil(Money.parse("1234567"))
    }

    // MARK: Protocol

    func testClientMessagesEncodeLikeTheWeb() throws {
        func obj(_ m: ClientMsg) throws -> NSDictionary {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(m.jsonString().utf8)) as? NSDictionary)
        }
        XCTAssertEqual(try obj(.claim(chipId: "c1")), ["t": "claim", "chipId": "c1"])
        XCTAssertEqual(try obj(.leave(chipId: "c1")), ["t": "leave", "chipId": "c1"])
        XCTAssertEqual(try obj(.remove(chipId: "c1")), ["t": "remove", "chipId": "c1"])
        XCTAssertEqual(try obj(.undoRemove(chipId: "c1")), ["t": "undoRemove", "chipId": "c1"])
        XCTAssertEqual(try obj(.frame(jpegBase64: "AAA", at: 12, detect: false)),
                       ["t": "frame", "jpegBase64": "AAA", "at": 12, "detect": false])
        XCTAssertEqual(try obj(.identifyAt(x: 1.5, y: 2)), ["t": "identifyAt", "x": 1.5, "y": 2])
    }

    func testServerMessagesDecode() throws {
        let runJSON = String(decoding: try fixtureData("run"), as: UTF8.self)
        guard case .run(let run)? = ServerMsg.parse(#"{"t":"run","run":\#(runJSON)}"#) else { return XCTFail("run") }
        XCTAssertEqual(run.chips.count, 3)
        XCTAssertEqual(ServerMsg.parse(#"{"t":"error","reason":"cart closed"}"#), .error(reason: "cart closed"))
        XCTAssertEqual(ServerMsg.parse(#"{"t":"lastCall","endsAt":1700000010000}"#), .lastCall(endsAt: 1_700_000_010_000))
        XCTAssertEqual(ServerMsg.parse(#"{"t":"locked"}"#), .locked)
        XCTAssertEqual(ServerMsg.parse(#"{"t":"frame","jpegBase64":"AA==","at":5}"#), .frame(jpegBase64: "AA==", at: 5))
        XCTAssertEqual(ServerMsg.parse(#"{"t":"identifying","region":{"x":1,"y":2,"w":3,"h":4}}"#),
                       .identifying(region: Box(x: 1, y: 2, w: 3, h: 4)))
        XCTAssertEqual(ServerMsg.parse(#"{"t":"newThing"}"#), .unknown("newThing"))
        XCTAssertNil(ServerMsg.parse("not json"))
    }

    // MARK: Socket URL and backoff

    func testSocketURL() {
        XCTAssertEqual(RunSocket.url(base: URL(string: "https://dibs.example.com")!, runId: "r 1", personId: "p&2").absoluteString,
                       "wss://dibs.example.com/ws?run=r%201&person=p%262")
        XCTAssertEqual(RunSocket.url(base: URL(string: "http://localhost:3000/")!, runId: "r", personId: "p").absoluteString,
                       "ws://localhost:3000/ws?run=r&person=p")
        XCTAssertEqual(RunSocket.url(base: URL(string: "https://dibs.example.com")!, runId: "r", personId: "p", key: "a+b/c=").absoluteString,
                       "wss://dibs.example.com/ws?run=r&person=p&key=a%2Bb%2Fc%3D")
    }

    func testBackoffSchedule() {
        XCTAssertEqual((0..<7).map { RunSocket.backoff(attempt: $0) }, [0.5, 1, 2, 4, 8, 8, 8])
    }

    // MARK: Server config

    func testServerURLValidation() {
        XCTAssertEqual(ServerConfig.validate("https://dibs.example.com/")?.absoluteString, "https://dibs.example.com")
        XCTAssertEqual(ServerConfig.validate(" http://localhost:3000 ")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(ServerConfig.validate("http://127.0.0.1:3000")?.absoluteString, "http://127.0.0.1:3000")
        XCTAssertNil(ServerConfig.validate("http://dibs.example.com"))
        XCTAssertNil(ServerConfig.validate("ftp://dibs.example.com"))
        XCTAssertNil(ServerConfig.validate("dibs.example.com"))
        XCTAssertNil(ServerConfig.validate(""))
    }

    func testServerOverrideAndPersonIdPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "dibs.tests.\(UUID().uuidString)"))
        XCTAssertFalse(ServerConfig.save("http://evil.example.com", defaults: defaults))
        XCTAssertTrue(ServerConfig.save("https://a.example.com", defaults: defaults))
        XCTAssertEqual(ServerConfig.current(defaults: defaults).absoluteString, "https://a.example.com")
        XCTAssertEqual(defaults.string(forKey: "dibs.server"), "https://a.example.com")
        ServerConfig.savePersonId("p1", runId: "r1", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: "dibs.person.r1"), "p1")
        XCTAssertEqual(ServerConfig.personId(runId: "r1", defaults: defaults), "p1")
        let keys = RunKeys(defaults: defaults)
        XCTAssertNil(keys.key(runId: "r1"))
        keys.save("secret", runId: "r1")
        XCTAssertEqual(keys.key(runId: "r1"), "secret")
        XCTAssertNil(keys.key(runId: "r2"))
    }

    // MARK: Colors

    func testRingColorsMatchTheWeb() throws {
        let run = try Run.decode(fixtureData("run"))
        // Priya's phone: she is blue, Marcus orange, Jake teal.
        XCTAssertEqual(ringColorHex(people: run.people, id: priya, me: priya), 0x2B59E8)
        XCTAssertEqual(ringColorHex(people: run.people, id: marcus, me: priya), 0xD9480F)
        XCTAssertEqual(ringColorHex(people: run.people, id: "jake", me: priya), 0x0F7B6C)
        // Jake's phone (shopper): first claimer blue, second orange.
        XCTAssertEqual(ringColorHex(people: run.people, id: priya, me: "jake"), 0x2B59E8)
        XCTAssertEqual(ringColorHex(people: run.people, id: marcus, me: "jake"), 0xD9480F)
    }
}
