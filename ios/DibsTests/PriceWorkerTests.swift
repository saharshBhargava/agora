import XCTest
import WebKit
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
    /// Observations show a bare loading page until a reload (or forever).
    var renderAfterReload = false
    var neverRender = false
    var observeDelay: Duration = .zero
    var warmedUp: [URL] = []
    private var reloaded = false

    var pageView: WKWebView? { nil }
    func restrict(to url: URL) { restrictedTo = url }
    func close() { closed = true }
    func warmUp(_ url: URL) async { warmedUp.append(url) }

    func run(tool name: String, args: [String: Any]) async throws -> [String: Any] {
        calls.append((name, args))
        if name == "browser_open" && failOpen { throw BrowserError("navigation_failed") }
        if name == "browser_act" && args["action"] as? String == "reload" { reloaded = true }
        if name == "browser_observe" && observeDelay > .zero { try await Task.sleep(for: observeDelay) }
        let loading = neverRender || (renderAfterReload && !reloaded)
        return ["documentId": "d1", "observationId": "d1:\(calls.count)", "title": "Search",
                "text": loading ? "QFC Sign In Loading" : pageText,
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
        worker = makeWorker { fake }
    }

    private func makeWorker(pool: Int = 1, retryDelay: Duration = .seconds(60), wait: Double = 25,
                            warmUp: URL? = nil, make: @escaping @MainActor () -> PriceBrowsing) -> PriceWorker {
        let w = PriceWorker(pollInterval: .milliseconds(20), poolSize: pool, warmUpURL: warmUp,
                            renderPoll: .milliseconds(10), waitSeconds: wait, reloadWaitSeconds: wait,
                            retryDelay: retryDelay, makeBrowser: make)
        w.use(api: api)
        return w
    }

    /// One poll, then wait for the lookups it started.
    private func poll() async {
        await worker.pollOnce()
        await worker.waitUntilIdle()
    }

    func testFastPathPostsPageTextAndStopsWhenFound() async throws {
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract",
                        .json(200, #"{"found":true,"priceCents":110,"productName":"Large Cosmic Crisp Apple","unit":"each"}"#))

        await poll()

        XCTAssertEqual(browser.calls.map(\.name), ["browser_open", "browser_observe"])
        XCTAssertEqual(browser.calls[0].args["url"] as? String, "https://www.qfc.com/search?query=cosmic%20crisp%20apple")
        XCTAssertEqual(browser.restrictedTo?.host, "www.qfc.com")
        let extract = PriceStub.requests("POST /api/price-requests/r1/extract")
        XCTAssertEqual(extract.count, 1)
        XCTAssertEqual(extract[0].json["pageText"] as? String, browser.pageText)
        XCTAssertTrue(PriceStub.requests("POST /api/price-requests/r1/agent-step").isEmpty)
        XCTAssertEqual(worker.lastOutcome, .init(requestId: "r1", name: "cosmic crisp apple", via: .page,
                                                 cents: 110, productName: "Large Cosmic Crisp Apple"))
        XCTAssertNil(worker.currentName)
    }

    func testNotRenderedReloadsOnceThenReads() async throws {
        let fake = browser!
        worker = makeWorker(wait: 0.2) { fake }
        browser.renderAfterReload = true
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))

        await poll()

        let names = browser.calls.map(\.name)
        XCTAssertEqual(names.first, "browser_open")
        XCTAssertGreaterThan(names.filter { $0 == "browser_observe" }.count, 2, "polled while waiting")
        XCTAssertEqual(browser.calls.filter { $0.name == "browser_act" }.map { $0.args["action"] as? String }, ["reload"])
        XCTAssertEqual(names.last, "browser_observe")
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").first?.json["pageText"] as? String, browser.pageText)
        XCTAssertEqual(worker.lastOutcome?.cents, 110)
    }

    func testStillNotRenderedAfterReloadStillExtracts() async throws {
        let fake = browser!
        worker = makeWorker(wait: 0.1) { fake }
        browser.neverRender = true
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await poll()
        XCTAssertEqual(browser.calls.filter { $0.name == "browser_act" }.count, 1, "reload only once")
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").first?.json["pageText"] as? String, "QFC Sign In Loading")
    }

    func testRenderedPredicate() {
        let item = "cosmic crisp apple"
        XCTAssertTrue(PriceWorker.rendered("308 results", item: item))
        XCTAssertTrue(PriceWorker.rendered("Large Cosmic Crisp® Apple – Each about $1.10 each", item: item))
        XCTAssertTrue(PriceWorker.rendered("COSMIC crisp $ 2.19 /lb", item: item))
        XCTAssertFalse(PriceWorker.rendered("QFC Sign In Loading", item: item))
        XCTAssertFalse(PriceWorker.rendered("Bananas $0.59", item: item), "price but not the item")
        XCTAssertFalse(PriceWorker.rendered("Cosmic Crisp apples are here! Save $5", item: item), "a banner, not a price line")
        XCTAssertTrue(PriceWorker.rendered("Coca-Cola Zero Sugar $3.49", item: "Coca-Cola Zero"))
    }

    func testPoolRunsTwoLookupsAtOnceNeverMore() async throws {
        var made: [FakeBrowser] = []
        worker = makeWorker(pool: 2) {
            let b = FakeBrowser()
            b.observeDelay = .milliseconds(150)
            made.append(b)
            return b
        }
        PriceStub.route("GET /api/price-requests?open=1", .json(200, #"""
        [{"id":"a","name":"oat milk","store":"QFC","searchUrl":"https://www.qfc.com/search?query=oat%20milk"},
         {"id":"b","name":"eggs","store":"QFC","searchUrl":"https://www.qfc.com/search?query=eggs"},
         {"id":"c","name":"apple","store":"QFC","searchUrl":"https://www.qfc.com/search?query=apple"}]
        """#))
        for id in ["a", "b", "c"] {
            PriceStub.route("POST /api/price-requests/\(id)/extract", .json(200, #"{"found":true,"priceCents":100}"#))
        }

        var maxActive = 0
        let deadline = Date().addingTimeInterval(5)
        while worker.outcomes.count < 3 && Date() < deadline {
            await worker.pollOnce()
            maxActive = max(maxActive, worker.active.count)
            try await Task.sleep(for: .milliseconds(20))
            maxActive = max(maxActive, worker.active.count)
        }
        await worker.waitUntilIdle()

        XCTAssertEqual(maxActive, 2)
        XCTAssertEqual(made.count, 2, "a pool of two browsers")
        XCTAssertEqual(Set(worker.outcomes.map(\.requestId)), ["a", "b", "c"])
        XCTAssertTrue(made.allSatisfy { $0.calls.contains { $0.name == "browser_open" } }, "both browsers used")
        for id in ["a", "b", "c"] {
            XCTAssertEqual(PriceStub.requests("POST /api/price-requests/\(id)/extract").count, 1, "one lookup per request")
        }
    }

    func testStartWarmsUpEveryBrowserOnTheStoreHomePage() async throws {
        var made: [FakeBrowser] = []
        worker = makeWorker(pool: 2, warmUp: URL(string: "https://www.qfc.com/")) {
            let b = FakeBrowser(); made.append(b); return b
        }
        PriceStub.route("GET /api/price-requests?open=1", .json(200, "[]"))
        worker.start(api: api)
        try await Task.sleep(for: .milliseconds(100))
        worker.stop()
        XCTAssertEqual(made.count, 2)
        XCTAssertEqual(made.map(\.warmedUp), [[URL(string: "https://www.qfc.com/")!], [URL(string: "https://www.qfc.com/")!]])
    }

    func testNoPriceIsRetriedOnceAfterTheDelay() async throws {
        let fake = browser!
        worker = makeWorker(retryDelay: .zero) { fake }
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))

        await poll()
        await poll()
        await poll()

        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 2, "one retry, no more")
        XCTAssertEqual(worker.outcomes.map(\.via), [.notFound, .notFound])
    }

    func testRetryWaitsForTheDelayAndFoundIsNotRetried() async throws {
        // Default delay in setUp is 60 s: the next poll must not retry yet.
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, notFound), .json(200, #"{"found":true,"priceCents":110}"#))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))
        await poll()
        await poll()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 1)

        let fake = browser!
        worker = makeWorker(retryDelay: .zero) { fake }
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await poll()
        await poll()
        XCTAssertEqual(PriceStub.requests("POST /api/price-requests/r1/extract").count, 2, "a found price is never retried")
    }

    func testPageTextIsCappedAt16000Chars() async throws {
        let fake = browser!
        worker = makeWorker(wait: 0.05) { fake }
        browser.pageText = String(repeating: "x", count: 20_000)
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await poll()
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

        await poll()

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

        XCTAssertEqual(browser.calls.map(\.name), ["browser_open", "browser_observe", "browser_find"])
        XCTAssertEqual(browser.calls[2].args["text"] as? String, "apple")
        XCTAssertEqual(worker.lastOutcome, .init(requestId: "r1", name: "cosmic crisp apple", via: .agent,
                                                 cents: 129, productName: "Cosmic Crisp"))
    }

    func testPageFailureGoesToAgentAndToolErrorsGoBackAsFunctionResponses() async throws {
        browser.failOpen = true
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/agent-step",
                        .json(200, #"{"parts":[{"functionCall":{"name":"browser_open","args":{"url":"https://www.qfc.com/x"}}}]}"#),
                        .json(200, #"{"parts":[{"functionCall":{"name":"report_price","args":{"found":false}}}]}"#))

        await poll()

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

        await poll()

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
        await poll()
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

        await poll()   // one browser: "a" now, "b" on the next poll
        await poll()

        XCTAssertEqual(worker.outcomes.map(\.via), [.failed, .page])
        XCTAssertEqual(worker.outcomes.last?.cents, 499)
        XCTAssertTrue(PriceStub.requests("POST /api/price-requests/a/agent-step").isEmpty)

        // A failed poll is survived, and handled requests are not retried.
        PriceStub.route("GET /api/price-requests?open=1", .fail(.timedOut))
        await poll()
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne.replacingOccurrences(of: "r1", with: "a")))
        await poll()
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

    func testThumbnailShowsOnlyWhileALookupRunsAndPicksTheFirstStarted() {
        let a = PriceWorker.Lookup(requestId: "a", name: "apple", host: "qfc.com")
        let b = PriceWorker.Lookup(requestId: "b", name: "eggs", host: "qfc.com")
        XCTAssertNil(PriceWorker.shownLookup([]))
        XCTAssertEqual(PriceWorker.shownLookup([a]), a)
        XCTAssertEqual(PriceWorker.shownLookup([a, b]), a, "two at once: the one started first")
        XCTAssertEqual(PriceWorker.shownLookup([b]), b)
    }

    func testSheetCaptionFollowsTheLookup() {
        let a = PriceWorker.Lookup(requestId: "a", name: "Honeycrisp apple", host: "qfc.com")
        XCTAssertEqual(PriceWorker.caption(requestId: "a", active: [a], outcomes: []), "Checking qfc.com…")
        XCTAssertEqual(PriceWorker.caption(requestId: "a", active: [], outcomes: [
            .init(requestId: "a", name: "Honeycrisp apple", via: .page, cents: 175, productName: "Large Honeycrisp Apple")]),
                       "Found $1.75 · Large Honeycrisp Apple")
        XCTAssertEqual(PriceWorker.caption(requestId: "a", active: [], outcomes: [
            .init(requestId: "a", name: "Honeycrisp apple", via: .agent, cents: 175, productName: "")]),
                       "Found $1.75 · Honeycrisp apple")
        XCTAssertEqual(PriceWorker.caption(requestId: "a", active: [], outcomes: [
            .init(requestId: "a", name: "Honeycrisp apple", via: .notFound)]), "No price found")
    }

    func testActiveLookupIsListedWhileRunning() async throws {
        browser.observeDelay = .milliseconds(100)
        PriceStub.route("GET /api/price-requests?open=1", .json(200, openOne))
        PriceStub.route("POST /api/price-requests/r1/extract", .json(200, #"{"found":true,"priceCents":110}"#))
        await worker.pollOnce()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(PriceWorker.shownLookup(worker.active)?.requestId, "r1")
        XCTAssertEqual(worker.currentName, "cosmic crisp apple")
        await worker.waitUntilIdle()
        XCTAssertNil(PriceWorker.shownLookup(worker.active), "hidden once the lookup ends")
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
