import XCTest
@testable import Dibs

/// Routes requests by "METHOD /path" to queued replies (the last reply repeats). No network.
final class PriceStub: URLProtocol, @unchecked Sendable {
    struct Recorded: Sendable {
        let method: String
        let path: String
        let body: Data?
        var json: [String: Any] { body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:] }
    }

    enum Reply: Sendable {
        case json(Int, String)
        case fail(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _requests: [Recorded] = []
    nonisolated(unsafe) private static var _routes: [String: [Reply]] = [:]

    static var requests: [Recorded] { lock.withLock { _requests } }
    static func requests(_ key: String) -> [Recorded] { requests.filter { "\($0.method) \($0.path)" == key } }
    static func reset() { lock.withLock { _requests = []; _routes = [:] } }
    static func route(_ key: String, _ replies: Reply...) { lock.withLock { _routes[key] = replies } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let method = request.httpMethod ?? "GET"
        var comps = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        let path = comps.path + (comps.query.map { "?\($0)" } ?? "")
        comps.query = nil
        let key = "\(method) \(path)"
        let reply = Self.lock.withLock { () -> Reply in
            Self._requests.append(Recorded(method: method, path: path, body: body))
            guard var queue = Self._routes[key], let first = queue.first else { return .json(404, #"{"error":"no route"}"#) }
            if queue.count > 1 { queue.removeFirst(); Self._routes[key] = queue }
            return first
        }
        switch reply {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let status, let json):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
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

/// Records tool calls and answers with an observation; no WebKit.
@MainActor
final class FakeBrowser: PriceBrowsing {
    var calls: [(name: String, args: [String: Any])] = []
    var restrictedTo: URL?
    var closed = false
    var pageText = "308 results about $1.10 each Large Cosmic Crisp® Apple – Each"
    var failOpen = false
    /// How many browser_wait_for calls time out before one succeeds.
    var waitFailures = 0

    func restrict(to url: URL) { restrictedTo = url }
    func close() { closed = true }

    func run(tool name: String, args: [String: Any]) async throws -> [String: Any] {
        calls.append((name, args))
        if name == "browser_open" && failOpen { throw BrowserError("navigation_failed") }
        if name == "browser_wait_for" && waitFailures > 0 { waitFailures -= 1; throw BrowserError("timeout") }
        return ["documentId": "d1", "observationId": "d1:\(calls.count)", "title": "Search", "text": pageText,
                "elements": [["id": "e0", "role": "a", "name": "Large Cosmic Crisp Apple"]]]
    }
}

@MainActor
final class PriceWorkerTests: XCTestCase {
    private var api: DibsAPI!
    private var browser: FakeBrowser!
    private var worker: PriceWorker!

    private let openOne = #"[{"id":"r1","name":"cosmic crisp apple","store":"QFC","searchUrl":"https://www.qfc.com/search?query=cosmic%20crisp%20apple"}]"#
    private let notFound = #"{"found":false}"#

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PriceStub.self]
        api = DibsAPI(base: URL(string: "https://dibs.example.com/")!, session: URLSession(configuration: config))
        PriceStub.reset()
        browser = FakeBrowser()
        let fake = browser!
        worker = PriceWorker(pollInterval: .milliseconds(20), retryDelay: .seconds(60), makeBrowser: { fake })
        worker.use(api: api)
    }

    func testFastPathPostsPageTextAndStopsWhenFound() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract",
                        .json(200, #"{"found":true,"priceCents":110,"productName":"Large Cosmic Crisp Apple","unit":"each"}"#))

        await worker.pollOnce()

        XCTAssertEqual(browser.calls.map(\.name), ["browser_open", "browser_wait_for", "browser_observe"])
        XCTAssertEqual(browser.calls[0].args["url"] as? String, "https://www.qfc.com/search?query=cosmic%20crisp%20apple")
        XCTAssertEqual(browser.calls[1].args["text"] as? String, "results")
        XCTAssertEqual(browser.restrictedTo?.host, "www.qfc.com")
        let extract = PriceStub.requests("POST /api/price-requests/r1/extract")
        XCTAssertEqual(extract.count, 1)
        XCTAssertEqual(extract[0].json["pageText"] as? String, browser.pageText)
        XCTAssertTrue(PriceStub.requests("POST /api/price-requests/r1/agent-step").isEmpty)
        XCTAssertEqual(worker.lastOutcome, .init(requestId: "r1", name: "cosmic crisp apple", via: .page,
                                                 cents: 110, productName: "Large Cosmic Crisp Apple"))
        XCTAssertNil(worker.currentName)
    }

    func testMissingResultsReloadsOnceThenObserves() async throws {
        browser.waitFailures = 2   // 25 s wait = 20 s + 5 s chunks, both time out
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))

        await worker.pollOnce()

        XCTAssertEqual(browser.calls.map(\.name),
                       ["browser_open", "browser_wait_for", "browser_wait_for", "browser_act", "browser_wait_for", "browser_observe"])
        XCTAssertEqual(browser.calls.filter { $0.name == "browser_wait_for" }.map { ($0.args["seconds"] as? NSNumber)?.doubleValue },
                       [20, 5, 20])
        XCTAssertEqual(browser.calls[3].args["action"] as? String, "reload")
        XCTAssertEqual(worker.lastOutcome?.cents, 110)
    }

    func testResultsStillMissingAfterReloadStillObservesAndExtracts() async throws {
        browser.waitFailures = 3
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await worker.pollOnce()
        XCTAssertEqual(browser.calls.filter { $0.name == "browser_act" }.count, 1, "reload only once")
        XCTAssertEqual(browser.calls.last?.name, "browser_observe")
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 1)
    }

    func testNoPriceIsRetriedOnceAfterTheDelay() async throws {
        let fake = browser!
        worker = PriceWorker(pollInterval: .milliseconds(20), retryDelay: .zero, makeBrowser: { fake })
        worker.use(api: api)
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))

        await worker.pollOnce()
        await worker.pollOnce()
        await worker.pollOnce()

        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 2, "one retry, no more")
        XCTAssertEqual(worker.outcomes.map(\.via), [.notFound, .notFound])
    }

    func testRetryWaitsForTheDelayAndFoundIsNotRetried() async throws {
        // Default delay in setUp is 60 s: the next poll must not retry yet.
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound), .json(200, #"{"found":true,"priceCents":110}"#))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))
        await worker.pollOnce()
        await worker.pollOnce()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 1)

        let fake = browser!
        worker = PriceWorker(pollInterval: .milliseconds(20), retryDelay: .zero, makeBrowser: { fake })
        worker.use(api: api)
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await worker.pollOnce()
        await worker.pollOnce()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 2, "a found price is never retried")
    }

    func testPageTextIsCappedAt16000Chars() async throws {
        browser.pageText = String(repeating: "x", count: 20_000)
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await worker.pollOnce()
        let text = PriceStub.requests("POST /api/price-requests/r1/extract").first?.json["pageText"] as? String
        XCTAssertEqual(text?.count, 16_000)
    }

    func testAgentLoopRunsCallsKeepsThoughtSignatureAndStopsOnResolved() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"browser_find","args":{"text":"apple"}},"thoughtSignature":"sig/abc+=="}]}"#),
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":true,"priceCents":129,"productName":"Cosmic Crisp","unit":"each"}}}],"resolved":true}"#),
                        .json(500, #"{"error":"should not be called"}"#))

        await worker.pollOnce()

        let steps = PriceStub.requests("POST /api/price-requests/r1/agent-step")
        XCTAssertEqual(steps.count, 2)
        let first = steps[0].json["contents"] as? [[String: Any]] ?? []
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first[0]["role"] as? String, "user")
        let seed = (first[0]["parts"] as? [[String: Any]])?.first?["text"] as? String
        XCTAssertEqual(seed, PriceWorker.agentWaitInstruction + "\n" +
                       #"Item: "cosmic crisp apple". Store: QFC. Start at https://www.qfc.com/search?query=cosmic%20crisp%20apple."#)
        XCTAssertTrue(seed?.hasPrefix(#"After browser_open, call browser_wait_for with text "results" (up to 20 seconds) before reading the page. Do not reopen the same URL more than once."#) ?? false)

        let second = steps[1].json["contents"] as? [[String: Any]] ?? []
        XCTAssertEqual(second.map { $0["role"] as? String }, ["user", "model", "user"])
        let modelPart = (second[1]["parts"] as? [[String: Any]])?.first
        XCTAssertEqual(modelPart?["thoughtSignature"] as? String, "sig/abc+==")
        XCTAssertEqual((modelPart?["functionCall"] as? [String: Any])?["name"] as? String, "browser_find")
        let response = (second[2]["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(response?["name"] as? String, "browser_find")
        XCTAssertEqual((response?["response"] as? [String: Any])?["text"] as? String, browser.pageText)

        XCTAssertEqual(browser.calls.map(\.name), ["browser_open", "browser_wait_for", "browser_observe", "browser_find"])
        XCTAssertEqual(browser.calls[3].args["text"] as? String, "apple")
        XCTAssertEqual(worker.lastOutcome, .init(requestId: "r1", name: "cosmic crisp apple", via: .agent,
                                                 cents: 129, productName: "Cosmic Crisp"))
    }

    func testPageFailureGoesToAgentAndToolErrorsGoBackAsFunctionResponses() async throws {
        browser.failOpen = true
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"browser_open","args":{"url":"https://www.qfc.com/x"}}}]}"#),
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))

        await worker.pollOnce()

        XCTAssertTrue(PriceStub.requests("POST /api/price-requests/r1/extract").isEmpty, "page failure skips extract")
        let steps = PriceStub.requests("POST /api/price-requests/r1/agent-step")
        XCTAssertEqual(steps.count, 2, "report_price with found false ends the loop")
        let contents = steps[1].json["contents"] as? [[String: Any]] ?? []
        let response = (contents.last?["parts"] as? [[String: Any]])?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(response?["name"] as? String, "browser_open")
        XCTAssertEqual((response?["response"] as? [String: Any])?["error"] as? String, "navigation_failed")
        XCTAssertEqual(worker.lastOutcome?.via, .notFound)
    }

    func testAgentLoopStopsAtEightSteps() async throws {
        browser.pageText = String(repeating: "Large Cosmic Crisp Apple $1.10 ", count: 600)   // ~18k chars a page
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"browser_observe","args":{}},"thoughtSignature":"s"}]}"#))

        await worker.pollOnce()

        let steps = PriceStub.requests("POST /api/price-requests/r1/agent-step")
        XCTAssertEqual(steps.count, PriceWorker.maxAgentSteps)
        for step in steps {
            XCTAssertLessThan(step.body?.count ?? .max, 60_000, "server refuses contents over 60 000 chars")
            XCTAssertLessThanOrEqual((step.json["contents"] as? [Any])?.count ?? .max, 24)
        }
        XCTAssertEqual(worker.lastOutcome?.via, .notFound)
    }

    func testAgentErrorStopsTheLoop() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound))
        PriceStub.route("POST /api/price-requests/r1/agent-step", .json(502, #"{"error":"agent step failed"}"#))
        await worker.pollOnce()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/agent-step").count, 1)
        XCTAssertEqual(worker.lastOutcome?.via, .failed)
    }

    func testNetworkErrorSkipsRequestAndKeepsGoing() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, #"""
        [{"id":"a","name":"oat milk","store":"QFC","searchUrl":"https://www.qfc.com/search?query=oat%20milk"},
         {"id":"b","name":"eggs","store":"QFC","searchUrl":"https://www.qfc.com/search?query=eggs"}]
        """#))
        PriceStub.route("POST /api/price-requests/a/extract", .fail(.notConnectedToInternet))
        PriceStub.route("POST /api/price-requests/b/extract", .json(200, #"{"found":true,"priceCents":499}"#))

        await worker.pollOnce()

        XCTAssertEqual(worker.outcomes.map(\.via), [.failed, .page])
        XCTAssertEqual(worker.outcomes.last?.cents, 499)
        XCTAssertTrue(PriceStub.requests("POST /api/price-requests/a/agent-step").isEmpty)

        // A failed poll is survived, and handled requests are not retried.
        PriceStub.route("GET /api/price-requests?open=1", .fail(.timedOut))
        await worker.pollOnce()
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne.replacingOccurrences(of: "r1", with: "a")))
        await worker.pollOnce()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/a/extract").count, 1)
        XCTAssertEqual(worker.outcomes.count, 2)
    }

    func testStartPollsUntilStopped() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, "[]"), .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        worker.start(api: api)
        XCTAssertTrue(worker.isRunning)
        let deadline = Date().addingTimeInterval(5)
        while worker.lastOutcome == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(worker.lastOutcome?.cents, 110)
        worker.stop()
        XCTAssertFalse(worker.isRunning)
        XCTAssertTrue(browser.closed)
        let polls = PriceStub.requests("GET /api/price-requests?open=1").count
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertLessThanOrEqual(PriceStub.requests("GET /api/price-requests?open=1").count, polls + 1)
    }

    func testPolicyKeepsTheBrowserOnTheStore() throws {
        var policy = BrowserPolicy()
        policy.allowedDomains = [BrowserPolicy.domain(of: URL(string: "https://www.qfc.com/search?query=x")!)!]
        XCTAssertNoThrow(try policy.validate(URL(string: "https://www.qfc.com/p/apple")!))
        XCTAssertNoThrow(try policy.validate(URL(string: "https://qfc.com/")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "https://evil.example.com/")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "http://www.qfc.com/")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "https://notqfc.com/")!))
    }

    func testCallValidationRefusesUnknownToolsAndFields() {
        XCTAssertThrowsError(try BrowserCall(name: "browser_eval", arguments: [:]))
        XCTAssertThrowsError(try BrowserCall(name: "browser_open", arguments: ["url": "https://x.com", "extra": "1"]))
        XCTAssertThrowsError(try BrowserCall(name: "browser_wait_for", arguments: ["text": "a", "seconds": 99]))
        XCTAssertNoThrow(try BrowserCall(name: "browser_wait_for", arguments: ["text": "results", "seconds": 12.0]))
    }
}
