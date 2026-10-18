import XCTest
@testable import Dibs

/// Records every request and answers with a canned response. No network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let url: URL
        let body: Data?
        let contentType: String?
        let timeout: TimeInterval
    }

    struct Reply: Sendable {
        var status = 200
        var body = Data("{}".utf8)
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var _reply = Reply()

    static var requests: [Recorded] { lock.withLock { _requests } }
    static func reset(_ reply: Reply = Reply()) { lock.withLock { _requests = []; _reply = reply } }
    static func reply(_ status: Int, _ json: String) { lock.withLock { _reply = Reply(status: status, body: Data(json.utf8)) } }
    static func fail(_ code: URLError.Code) { lock.withLock { _reply = Reply(error: URLError(code)) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let reply = Self.lock.withLock { () -> Reply in
            Self._requests.append(Recorded(method: request.httpMethod ?? "GET", url: request.url!, body: body,
                                           contentType: request.value(forHTTPHeaderField: "content-type"),
                                           timeout: request.timeoutInterval))
            return Self._reply
        }
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

final class APITests: XCTestCase {
    private var api: DibsAPI!
    private var runJSON = ""

    override func setUpWithError() throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        api = DibsAPI(base: URL(string: "https://dibs.example.com/")!, session: URLSession(configuration: config))
        runJSON = String(decoding: try fixtureData("run"), as: UTF8.self)
        StubProtocol.reset()
    }

    private var last: StubProtocol.Recorded { StubProtocol.requests.last! }

    private func lastBody() throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(last.body)) as? NSDictionary)
    }

    private func assertRequest(_ method: String, _ path: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(StubProtocol.requests.count, 1, file: file, line: line)
        XCTAssertEqual(last.method, method, file: file, line: line)
        XCTAssertEqual(last.url.absoluteString, "https://dibs.example.com" + path, file: file, line: line)
    }

    // MARK: one test per call in web/lib/api.ts

    func testCreateRun() async throws {
        StubProtocol.reply(200, #"{"runId":"r1","shopperId":"jake"}"#)
        let created = try await api.createRun()
        XCTAssertEqual(created.runId, "r1")
        XCTAssertEqual(created.shopperId, "jake")
        assertRequest("POST", "/api/runs")
        XCTAssertEqual(last.contentType, "application/json")
        XCTAssertEqual(try lastBody(), [:])
    }

    func testGetRun() async throws {
        StubProtocol.reply(200, runJSON)
        let run = try await api.getRun("a b")
        XCTAssertEqual(run.chips.count, 3)
        assertRequest("GET", "/api/runs/a%20b")
        XCTAssertNil(last.body)
    }

    func testJoinSendsTestCard() async throws {
        StubProtocol.reply(200, #"{"personId":"p1","auth":{"status":"AUTHORIZED","authId":"a1","approvalCode":"888888","authorizedCents":4000}}"#)
        let res = try await api.join(runId: "r1", name: "Priya", capCents: 4000)
        XCTAssertEqual(res.personId, "p1")
        XCTAssertEqual(res.auth.authorizedCents, 4000)
        assertRequest("POST", "/api/runs/r1/join")
        XCTAssertEqual(try lastBody(), [
            "name": "Priya", "capCents": 4000,
            "card": ["number": "4111111111111111", "expMonth": 12, "expYear": 2031],
        ])
    }

    func testJoinDeclineSendsExpiredCard() async throws {
        StubProtocol.reply(409, #"{"error":"declined"}"#)
        do {
            _ = try await api.join(runId: "r1", name: "Priya", capCents: 4000, decline: true)
            XCTFail("expected a decline")
        } catch {
            XCTAssertEqual(error as? DibsError, .server(message: "declined", status: 409))
        }
        let card = try XCTUnwrap(lastBody()["card"] as? NSDictionary)
        XCTAssertEqual(card["expYear"] as? Int, 1998)
    }

    func testAddChip() async throws {
        StubProtocol.reply(200, #"{"id":"c1","name":"Eggs","state":"identifying"}"#)
        let chip = try await api.addChip(runId: "r1", imageBase64: "AAAA", hint: "eggs")
        XCTAssertEqual(chip.id, "c1")
        assertRequest("POST", "/api/runs/r1/chips")
        XCTAssertEqual(try lastBody(), ["imageBase64": "AAAA", "hint": "eggs"])
    }

    func testAddChipWithoutHintOmitsIt() async throws {
        StubProtocol.reply(200, #"{"id":"c1","name":"Eggs","state":"identifying"}"#)
        _ = try await api.addChip(runId: "r1", imageBase64: "AAAA")
        XCTAssertEqual(try lastBody(), ["imageBase64": "AAAA"])
    }

    func testFixChip() async throws {
        StubProtocol.reply(200, runJSON)
        _ = try await api.fixChip(runId: "r1", chipId: "c/1", personId: "jake", name: "Eggs", priceCents: 899)
        assertRequest("POST", "/api/runs/r1/chips/c%2F1/fix")
        XCTAssertEqual(try lastBody(), ["personId": "jake", "name": "Eggs", "priceCents": 899])
    }

    func testFixChipPriceOnly() async throws {
        StubProtocol.reply(200, runJSON)
        _ = try await api.fixChip(runId: "r1", chipId: "c1", personId: "jake", priceCents: 899)
        XCTAssertEqual(try lastBody(), ["personId": "jake", "priceCents": 899])
    }

    func testPutBack() async throws {
        StubProtocol.reply(200, runJSON)
        _ = try await api.putBack(runId: "r1", chipId: "c1", personId: "jake")
        assertRequest("POST", "/api/runs/r1/chips/c1/putback")
        XCTAssertEqual(try lastBody(), ["personId": "jake"])
    }

    func testCheckout() async throws {
        StubProtocol.reply(200, runJSON)
        _ = try await api.checkout(runId: "r1", personId: "jake")
        assertRequest("POST", "/api/runs/r1/checkout")
        XCTAssertEqual(try lastBody(), ["personId": "jake"])
    }

    func testBack() async throws {
        StubProtocol.reply(200, runJSON)
        _ = try await api.back(runId: "r1", personId: "jake")
        assertRequest("POST", "/api/runs/r1/back")
        XCTAssertEqual(try lastBody(), ["personId": "jake"])
    }

    func testRaise() async throws {
        StubProtocol.reply(200, #"{"status":"AUTHORIZED","authId":"a1","approvalCode":"","authorizedCents":6000}"#)
        let cents = try await api.raise(runId: "r1", personId: "p1", capCents: 6000)
        XCTAssertEqual(cents, 6000)
        assertRequest("POST", "/api/runs/r1/raise")
        XCTAssertEqual(try lastBody(), ["personId": "p1", "capCents": 6000])
    }

    func testWish() async throws {
        StubProtocol.reply(200, runJSON)
        let run = try await api.wish(runId: "r1", name: "oat milk", byPersonId: "p1")
        XCTAssertEqual(run.chips.first?.state, .wish)
        assertRequest("POST", "/api/runs/r1/chips/text")
        XCTAssertEqual(try lastBody(), ["name": "oat milk", "byPersonId": "p1"])
    }

    func testReceipt() async throws {
        StubProtocol.reply(200, #"{"lines":[{"text":"KS EGGS","cents":872,"quantity":1,"isTax":false}],"matches":[],"unmatchedLines":[0]}"#)
        let receipt = try await api.receipt(runId: "r1", imageBase64: "BBBB")
        XCTAssertEqual(receipt.lines.first?.cents, 872)
        assertRequest("POST", "/api/runs/r1/receipt")
        XCTAssertEqual(try lastBody(), ["imageBase64": "BBBB"])
    }

    func testFixReceiptLineToChip() async throws {
        StubProtocol.reply(200, #"{"lines":[],"matches":[],"unmatchedLines":[]}"#)
        _ = try await api.fixReceiptLine(runId: "r1", lineIndex: 2, target: .chip("c1"))
        assertRequest("POST", "/api/runs/r1/receipt/fix")
        XCTAssertEqual(try lastBody(), ["lineIndex": 2, "target": ["chipId": "c1"]])
    }

    func testFixReceiptLineToMine() async throws {
        StubProtocol.reply(200, #"{"lines":[],"matches":[],"unmatchedLines":[],"mine":[2]}"#)
        let receipt = try await api.fixReceiptLine(runId: "r1", lineIndex: 2, target: .mine)
        XCTAssertEqual(receipt.mine, [2])
        XCTAssertEqual(try lastBody(), ["lineIndex": 2, "target": "mine"])
    }

    func testConfirm() async throws {
        StubProtocol.reply(200, String(decoding: try fixtureData("run-settled"), as: UTF8.self))
        let run = try await api.confirm(runId: "r1", personId: "jake")
        XCTAssertEqual(run.state, .settled)
        assertRequest("POST", "/api/runs/r1/confirm")
        XCTAssertEqual(try lastBody(), ["personId": "jake"])
    }

    func testLinks() {
        XCTAssertEqual(api.qrURL(runId: "r1").absoluteString, "https://dibs.example.com/api/runs/r1/qr")
        XCTAssertEqual(api.joinLink(runId: "r1").absoluteString, "https://dibs.example.com/join?run=r1")
    }

    // MARK: errors

    func testServerErrorUsesBodyErrorField() async {
        StubProtocol.reply(400, #"{"error":"cart closed"}"#)
        do {
            _ = try await api.checkout(runId: "r1", personId: "jake")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .server(message: "cart closed", status: 400))
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, "cart closed")
        }
    }

    func testServerErrorWithoutBody() async {
        StubProtocol.reply(500, "oops")
        do {
            _ = try await api.getRun("r1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .server(message: "request failed (500)", status: 500))
        }
    }

    func testOffline() async {
        StubProtocol.fail(.notConnectedToInternet)
        do {
            _ = try await api.getRun("r1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .offline)
        }
    }

    func testTimeout() async {
        StubProtocol.fail(.timedOut)
        do {
            _ = try await api.getRun("r1")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? DibsError, .timeout)
        }
    }

    func testRequestsUseTenSecondTimeout() throws {
        let req = try api.request("GET", "/api/runs/r1", body: Optional<String>.none)
        XCTAssertEqual(req.timeoutInterval, 10)
    }

    func testGeminiCallsGetFortyFiveSeconds() async throws {
        StubProtocol.reply(200, #"{"id":"c1","name":"Eggs","state":"identifying"}"#)
        _ = try await api.addChip(runId: "r1", imageBase64: "AAAA")
        XCTAssertEqual(last.timeout, 45)
        StubProtocol.reset()
        StubProtocol.reply(200, #"{"lines":[],"matches":[],"unmatchedLines":[]}"#)
        _ = try await api.receipt(runId: "r1", imageBase64: "BBBB")
        XCTAssertEqual(last.timeout, 45)
        StubProtocol.reset()
        StubProtocol.reply(200, runJSON)
        _ = try await api.confirm(runId: "r1", personId: "jake")
        XCTAssertEqual(last.timeout, 45)
        StubProtocol.reset()
        StubProtocol.reply(200, runJSON)
        _ = try await api.getRun("r1")
        XCTAssertEqual(last.timeout, 10)
    }
}
