import Foundation
import Observation
import os

/// `DIBS: <time> price ...` lines on stdout (same shape as the app's remote-debug log) and os_log.
enum PriceLog {
    private static let logger = Logger(subsystem: "dev.dibs.app", category: "price")

    static func event(_ s: String) {
        let time = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        print("DIBS: \(time) \(s)")
        logger.log("\(s, privacy: .public)")
    }
}

/// One open lookup from `GET /api/price-requests?open=1`.
struct PriceRequest: Decodable, Sendable, Equatable {
    let id: String
    let name: String
    let store: String
    let searchUrl: String
}

/// The browser the worker drives. StoreBrowser (through BrowserToolExecutor) in the app; a fake in tests.
@MainActor
protocol PriceBrowsing: AnyObject {
    /// Keeps navigation on the store's domain for this request.
    func restrict(to url: URL)
    /// Runs one browser tool (`browser_open`, `browser_observe`, ...) and returns its JSON result.
    func run(tool name: String, args: [String: Any]) async throws -> [String: Any]
    func close()
}

/// The price-request routes. JSON stays untyped so model parts (and their thoughtSignature)
/// go back to the server byte-for-byte as they came.
@MainActor
struct PriceAPI {
    let api: DibsAPI

    func open() async throws -> [PriceRequest] {
        let data = try await send("GET", "/api/price-requests?open=1", json: nil, timeout: api.timeout)
        do { return try JSONDecoder().decode([PriceRequest].self, from: data) }
        catch { throw DibsError.server(message: "Unexpected reply from the server.", status: 200) }
    }

    func extract(id: String, pageText: String) async throws -> [String: Any] {
        try object(await send("POST", "/api/price-requests/\(DibsAPI.encode(id))/extract",
                              json: ["pageText": pageText], timeout: api.slowTimeout))
    }

    func agentStep(id: String, contents: [[String: Any]]) async throws -> [String: Any] {
        try object(await send("POST", "/api/price-requests/\(DibsAPI.encode(id))/agent-step",
                              json: ["contents": contents], timeout: api.slowTimeout))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DibsError.server(message: "Unexpected reply from the server.", status: 200)
        }
        return o
    }

    private func send(_ method: String, _ path: String, json: [String: Any]?, timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: api.url(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await api.session.data(for: req)
        } catch let e as URLError {
            throw e.code == .timedOut ? DibsError.timeout : DibsError.offline
        } catch {
            throw DibsError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw DibsError.server(message: body?["error"] as? String ?? "request failed (\(status))", status: status)
        }
        return data
    }
}

/// Finds store prices for the server's open price requests with an in-app browser.
/// Runs on the shopper's phone while a run is open: `start(api:)` / `stop()`.
///
/// Per request: open the store's search page, wait for "results", send the visible text to
/// `/extract` (the server asks Gemini). If that finds nothing, fall back to the team's browser
/// agent loop through `/agent-step` for up to 8 steps.
@MainActor
@Observable
final class PriceWorker {
    enum Via: String, Sendable { case page, agent, notFound, failed }

    struct Outcome: Equatable, Sendable {
        let requestId: String
        let name: String
        let via: Via
        var cents: Int? = nil
        var productName: String? = nil
    }

    static let maxAgentSteps = 12
    /// Prepended to the agent's first turn: QFC renders slowly, and the model used to reopen
    /// the page instead of waiting.
    static let agentWaitInstruction = "After browser_open, call browser_wait_for with text \"results\" (up to 20 seconds) before reading the page. Do not reopen the same URL more than once."
    static let pageTextLimit = 16_000
    /// The server refuses agent-step contents over 60 000 JSON chars.
    static let contentsBudget = 56_000

    private(set) var isRunning = false
    /// The item being looked up right now, or nil.
    private(set) var currentName: String?
    /// "Checking qfc.com…" while a lookup is in flight, else "".
    private(set) var phase = ""
    private(set) var lastOutcome: Outcome?
    /// Every finished lookup, oldest first (tests and debugging).
    private(set) var outcomes: [Outcome] = []

    @ObservationIgnored private let makeBrowser: @MainActor () -> PriceBrowsing
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let waitSeconds: Double
    @ObservationIgnored private let reloadWaitSeconds: Double
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private var browser: PriceBrowsing?
    @ObservationIgnored private var api: PriceAPI?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Lookups started per request id; a request that ends without a price gets one retry.
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var retryAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pollFailing = false

    init(pollInterval: Duration = .seconds(2), waitSeconds: Double = 25, reloadWaitSeconds: Double = 20,
         retryDelay: Duration = .seconds(20),
         makeBrowser: @escaping @MainActor () -> PriceBrowsing = { BrowserToolExecutor(session: StoreBrowser()) }) {
        self.pollInterval = pollInterval
        self.waitSeconds = waitSeconds
        self.reloadWaitSeconds = reloadWaitSeconds
        self.retryDelay = retryDelay
        self.makeBrowser = makeBrowser
    }

    func start(api: DibsAPI) {
        self.api = PriceAPI(api: api)
        guard loop == nil else { return }
        isRunning = true
        PriceLog.event("price worker start \(api.base.absoluteString)")
        let interval = pollInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        PriceLog.event("price worker stop")
        loop?.cancel()
        loop = nil
        isRunning = false
        browser?.close()
        currentName = nil
        phase = ""
    }

    /// Sets the server without starting the poll loop (tests drive `pollOnce` directly).
    func use(api: DibsAPI) { self.api = PriceAPI(api: api) }

    /// One poll: fetch open requests and handle each new one, one at a time.
    func pollOnce() async {
        guard let api else { return }
        let open: [PriceRequest]
        do {
            open = try await api.open()
            if pollFailing { PriceLog.event("price poll ok again") }
            pollFailing = false
        } catch {
            if !pollFailing { PriceLog.event("price poll failed: \(error.localizedDescription)") }
            pollFailing = true
            return
        }
        for request in open where isDue(request.id) {
            if Task.isCancelled { return }
            let attempt = (attempts[request.id] ?? 0) + 1
            attempts[request.id] = attempt
            retryAt[request.id] = nil
            if attempt > 1 { PriceLog.event("price \(request.id) retry \(attempt - 1)") }
            let outcome = await handle(request, api: api)
            lastOutcome = outcome
            outcomes.append(outcome)
            if outcome.cents == nil && attempt == 1 {
                retryAt[request.id] = .now + retryDelay
                PriceLog.event("price \(request.id) no price; retrying in \(retryDelay)")
            }
        }
    }

    /// New requests, and a priceless first attempt once its retry delay has passed.
    private func isDue(_ id: String) -> Bool {
        switch attempts[id] ?? 0 {
        case 0: return true
        case 1: return retryAt[id].map { ContinuousClock.now >= $0 } ?? false
        default: return false
        }
    }

    private func handle(_ request: PriceRequest, api: PriceAPI) async -> Outcome {
        guard let url = URL(string: request.searchUrl) else {
            PriceLog.event("price \(request.id) bad searchUrl")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        }
        let host = BrowserPolicy.domain(of: url) ?? "the store"
        currentName = request.name
        phase = "Checking \(host)…"
        defer { currentName = nil; phase = "" }
        let browser = self.browser ?? makeBrowser()
        self.browser = browser
        browser.restrict(to: url)
        PriceLog.event("price \(request.id) start \"\(request.name)\" at \(request.store)")

        do {
            if let found = try await fastPath(request, browser: browser, api: api) { return found }
        } catch let error as DibsError {
            PriceLog.event("price \(request.id) extract failed: \(error.localizedDescription); skipping")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        } catch {
            PriceLog.event("price \(request.id) page failed: \(error.localizedDescription); trying agent")
        }
        if Task.isCancelled { return Outcome(requestId: request.id, name: request.name, via: .failed) }

        do {
            return try await agentLoop(request, browser: browser, api: api)
        } catch {
            PriceLog.event("price \(request.id) agent stopped: \(error.localizedDescription)")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        }
    }

    /// open → wait for "results" → observe → /extract. Nil when the page had no match.
    private func fastPath(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI) async throws -> Outcome? {
        PriceLog.event("price \(request.id) open \(BrowserPolicy.safeURL(URL(string: request.searchUrl)))")
        _ = try await browser.run(tool: "browser_open", args: ["url": request.searchUrl])
        var ready = await waitForResults(browser, seconds: waitSeconds)
        if ready {
            PriceLog.event("price \(request.id) results showing")
        } else {
            PriceLog.event("price \(request.id) no \"results\" text after \(Int(waitSeconds)) s; reloading")
            _ = try await browser.run(tool: "browser_act", args: ["action": "reload"])
            ready = await waitForResults(browser, seconds: reloadWaitSeconds)
            PriceLog.event("price \(request.id) " + (ready ? "results showing after reload" : "still no \"results\" after reload"))
        }
        let observation = try await browser.run(tool: "browser_observe", args: [:])
        let text = String((observation["text"] as? String ?? "").prefix(Self.pageTextLimit))
        PriceLog.event("price \(request.id) observed \(text.count) chars")
        if !ready {
            let head = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200)
            PriceLog.event("price \(request.id) page starts: \(head)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let reply = try await api.extract(id: request.id, pageText: text)
        if reply["found"] as? Bool == true, let cents = reply["priceCents"] as? Int {
            let product = reply["productName"] as? String
            PriceLog.event("price \(request.id) found \(Money.format(cents)) \"\(product ?? "")\" from page")
            return Outcome(requestId: request.id, name: request.name, via: .page, cents: cents, productName: product)
        }
        PriceLog.event("price \(request.id) page had no match")
        return nil
    }

    /// Waits for "results" in chunks of at most 20 s (the tool's limit). False on timeout or error.
    private func waitForResults(_ browser: PriceBrowsing, seconds: Double) async -> Bool {
        var left = seconds
        while left > 0 {
            let chunk = min(left, 20)
            left -= chunk
            do {
                _ = try await browser.run(tool: "browser_wait_for", args: ["text": "results", "seconds": chunk])
                return true
            } catch {
                if Task.isCancelled { return false }
            }
        }
        return false
    }

    /// The team's Gemini browser agent, with the model on the server: post the conversation,
    /// run the model's browser calls here, append both turns, repeat.
    private func agentLoop(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI) async throws -> Outcome {
        // The server seeds the Item/Store line when contents is empty; sending the turn ourselves
        // keeps the task (and the wait instruction) in the history every later step must carry.
        // 12 steps make 23 entries, under the server's 24.
        var contents: [[String: Any]] = [[
            "role": "user",
            "parts": [["text": "\(Self.agentWaitInstruction)\nItem: \"\(request.name)\". Store: \(request.store). Start at \(request.searchUrl)."]],
        ]]
        for step in 1...Self.maxAgentSteps {
            try Task.checkCancellation()
            Self.fit(&contents)
            PriceLog.event("price \(request.id) agent step \(step)")
            let reply = try await api.agentStep(id: request.id, contents: contents)
            let parts = reply["parts"] as? [[String: Any]] ?? []
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }
            let report = calls.first { $0["name"] as? String == "report_price" }
            if reply["resolved"] as? Bool == true {
                let args = report?["args"] as? [String: Any] ?? [:]
                let cents = args["priceCents"] as? Int
                let product = args["productName"] as? String
                PriceLog.event("price \(request.id) found \(cents.map(Money.format) ?? "?") \"\(product ?? "")\" by agent")
                return Outcome(requestId: request.id, name: request.name, via: .agent, cents: cents, productName: product)
            }
            if report != nil {
                PriceLog.event("price \(request.id) agent reported no match")
                return Outcome(requestId: request.id, name: request.name, via: .notFound)
            }
            if calls.isEmpty {
                PriceLog.event("price \(request.id) agent stopped without a tool call")
                return Outcome(requestId: request.id, name: request.name, via: .notFound)
            }
            contents.append(["role": "model", "parts": parts])
            var replies: [[String: Any]] = []
            for call in calls {
                try Task.checkCancellation()
                let name = call["name"] as? String ?? "unknown"
                let args = call["args"] as? [String: Any] ?? [:]
                var result: [String: Any]
                do {
                    result = Self.compact(try await browser.run(tool: name, args: args))
                    PriceLog.event("price \(request.id) tool \(name) ok")
                } catch {
                    result = ["error": error.localizedDescription]
                    PriceLog.event("price \(request.id) tool \(name) error: \(error.localizedDescription)")
                }
                var response: [String: Any] = ["name": name, "response": result]
                if let id = call["id"] { response["id"] = id }
                replies.append(["functionResponse": response])
            }
            contents.append(["role": "user", "parts": replies])
        }
        PriceLog.event("price \(request.id) agent hit the \(Self.maxAgentSteps)-step cap")
        return Outcome(requestId: request.id, name: request.name, via: .notFound)
    }

    // MARK: conversation size

    /// Trims one tool result: bounded text, at most 60 elements with short names, no images.
    static func compact(_ result: [String: Any]) -> [String: Any] {
        var r = result
        r.removeValue(forKey: "image")
        if let text = r["text"] as? String, text.count > 12_000 { r["text"] = String(text.prefix(12_000)) }
        if let elements = r["elements"] as? [[String: Any]] {
            r["elements"] = elements.prefix(60).map { e -> [String: Any] in
                var e = e
                if let name = e["name"] as? String, name.count > 100 { e["name"] = String(name.prefix(100)) }
                return e
            }
        }
        return r
    }

    static func jsonSize(_ contents: [[String: Any]]) -> Int {
        (try? JSONSerialization.data(withJSONObject: contents).count) ?? Int.max
    }

    /// Replaces the oldest tool results with a note until the conversation fits the server's limit.
    static func fit(_ contents: inout [[String: Any]]) {
        let note: [String: Any] = ["note": "Older page observation omitted to save space. Observe again if needed."]
        var index = 0
        while jsonSize(contents) > contentsBudget, index < contents.count {
            defer { index += 1 }
            guard contents[index]["role"] as? String == "user",
                  var parts = contents[index]["parts"] as? [[String: Any]] else { continue }
            var changed = false
            for i in parts.indices {
                guard var response = parts[i]["functionResponse"] as? [String: Any],
                      let body = response["response"] as? [String: Any], body["note"] == nil else { continue }
                response["response"] = note
                parts[i]["functionResponse"] = response
                changed = true
            }
            if changed { contents[index]["parts"] = parts }
        }
    }
}
