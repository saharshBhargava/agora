import Foundation
import Observation
import WebKit
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
    /// The store to price at, when the server names one (else the worker's default).
    var storeLocation: StoreLocation? = nil
}

/// The browser the worker drives. StoreBrowser (through BrowserToolExecutor) in the app; a fake in tests.
@MainActor
protocol PriceBrowsing: AnyObject {
    /// Keeps navigation on the store's domain for this request.
    func restrict(to url: URL)
    /// Runs one browser tool (`browser_open`, `browser_observe`, ...) and returns its JSON result.
    func run(tool name: String, args: [String: Any]) async throws -> [String: Any]
    /// Switches the site's pickup store (or confirms it); see StoreSetupScript.
    func setStore(_ location: StoreLocation) async -> StoreSetupResult
    /// The page being driven, for the on-screen thumbnail (nil in tests).
    var pageView: WKWebView? { get }
    /// Loads the store's home page so cookies, consent, scripts and caches are ready. Stops early when cancelled.
    func warmUp(_ url: URL) async
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

/// Finds store prices for the server's open price requests with in-app browsers.
/// Runs on the shopper's phone while a run is open: `start(api:)` / `stop()`.
///
/// A pool of 2 StoreBrowsers, warmed on the store's home page at start, takes one request each.
/// Per request: open the store's search page, poll the page until it shows a price line for the
/// item (or "results"), send the visible text to `/extract` (the server asks Gemini). If that finds
/// nothing, fall back to the team's browser agent loop through `/agent-step`.
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
        /// False when the store's results page loaded and had no match: no retry.
        var retryable = true
    }

    struct Lookup: Equatable, Sendable {
        let requestId: String
        let name: String
        /// "qfc.com"
        let host: String
        var phase: String { "Checking \(host)…" }
    }

    static let maxAgentSteps = 12
    /// Prepended to the agent's first turn: QFC renders slowly, and the model used to reopen
    /// the page instead of waiting.
    static let agentWaitInstruction = "After browser_open, call browser_wait_for with text \"results\" (up to 20 seconds) before reading the page. Do not reopen the same URL more than once."
    static let pageTextLimit = 16_000
    /// The server refuses agent-step contents over 60 000 JSON chars.
    static let contentsBudget = 56_000

    private(set) var isRunning = false
    /// Lookups in flight, oldest first.
    private(set) var active: [Lookup] = []
    private(set) var lastOutcome: Outcome?
    /// Every finished lookup, oldest first (tests and debugging).
    private(set) var outcomes: [Outcome] = []
    /// Items whose final attempt ended without a price.
    private(set) var gaveUpNames: Set<String> = []
    /// The store the site was verified to show; nil until store setup succeeds.
    /// Lookups never wait for it: they price at whatever store the site has.
    private(set) var activeStore: StoreLocation?

    /// True once the worker has stopped trying to price `name` ("No price found · Add price").
    func gaveUp(for name: String) -> Bool { gaveUpNames.contains(name) }

    /// The most recently started lookup's item, or nil.
    var currentName: String? { active.last?.name }
    /// "Checking qfc.com…" while a lookup is in flight, else "".
    var phase: String { active.last?.phase ?? "" }
    /// "Checking qfc.com…" while `name` is being looked up, else nil.
    func status(for name: String) -> String? { active.last(where: { $0.name == name })?.phase }

    /// The lookup the thumbnail shows: the one started first, or nil (thumbnail hidden).
    static func shownLookup(_ active: [Lookup]) -> Lookup? { active.first }

    /// "Checking qfc.com…" while running, then "Found $1.75 · Large Honeycrisp Apple" or "No price found".
    static func caption(requestId: String, active: [Lookup], outcomes: [Outcome]) -> String {
        if let lookup = active.first(where: { $0.requestId == requestId }) { return lookup.phase }
        guard let outcome = outcomes.last(where: { $0.requestId == requestId }) else { return "" }
        guard let cents = outcome.cents else { return "No price found" }
        let product = outcome.productName.flatMap { $0.isEmpty ? nil : $0 } ?? outcome.name
        return "Found \(Money.format(cents)) · \(product)"
    }

    /// The live page for a running lookup.
    func pageView(for requestId: String) -> WKWebView? { lookupBrowsers[requestId]?.pageView }

    @MainActor private final class Slot {
        let browser: PriceBrowsing
        var busy = false
        /// Home-page warm-up; a lookup cuts it short.
        var warm: Task<Void, Never>?
        init(_ browser: PriceBrowsing) { self.browser = browser }
    }

    @ObservationIgnored private let makeBrowser: @MainActor () -> PriceBrowsing
    @ObservationIgnored private let poolSize: Int
    @ObservationIgnored private let warmUpURL: URL?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let renderPoll: Duration
    @ObservationIgnored private let waitSeconds: Double
    @ObservationIgnored private let reloadWaitSeconds: Double
    @ObservationIgnored private let retryDelay: Duration
    @ObservationIgnored private let storeLocation: StoreLocation
    @ObservationIgnored private let giveUpSteps: Int
    @ObservationIgnored private let giveUpSeconds: Double
    @ObservationIgnored private let storeAttempts: Int
    @ObservationIgnored private let storeRetryInterval: Duration
    @ObservationIgnored private let makeStoreBrowser: @MainActor () -> PriceBrowsing
    @ObservationIgnored private var storeBrowser: PriceBrowsing?
    @ObservationIgnored private var storeTask: Task<Void, Never>?
    @ObservationIgnored private var storeTarget: StoreLocation?
    @ObservationIgnored private var slots: [Slot] = []
    @ObservationIgnored private var inFlight: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var lookupBrowsers: [String: PriceBrowsing] = [:]
    @ObservationIgnored private var api: PriceAPI?
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Lookups started per request id; a request that ends without a price gets one retry.
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var retryAt: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var pollFailing = false

    init(pollInterval: Duration = .milliseconds(500), poolSize: Int = 2,
         warmUpURL: URL? = URL(string: "https://www.qfc.com/"),
         renderPoll: Duration = .milliseconds(250), waitSeconds: Double = 25, reloadWaitSeconds: Double = 20,
         retryDelay: Duration = .seconds(20),
         storeLocation: StoreLocation = .universityVillage,
         giveUpSteps: Int = 3, giveUpSeconds: Double = 10,
         storeAttempts: Int = 3, storeRetryInterval: Duration = .seconds(60),
         makeBrowser: @escaping @MainActor () -> PriceBrowsing = { BrowserToolExecutor(session: StoreBrowser()) },
         makeStoreBrowser: (@MainActor () -> PriceBrowsing)? = nil) {
        self.pollInterval = pollInterval
        self.poolSize = max(1, poolSize)
        self.warmUpURL = warmUpURL
        self.renderPoll = renderPoll
        self.waitSeconds = waitSeconds
        self.reloadWaitSeconds = reloadWaitSeconds
        self.retryDelay = retryDelay
        self.storeLocation = storeLocation
        self.giveUpSteps = giveUpSteps
        self.giveUpSeconds = giveUpSeconds
        self.storeAttempts = max(1, storeAttempts)
        self.storeRetryInterval = storeRetryInterval
        self.makeBrowser = makeBrowser
        self.makeStoreBrowser = makeStoreBrowser ?? makeBrowser
    }

    func start(api: DibsAPI) {
        self.api = PriceAPI(api: api)
        guard loop == nil else { return }
        isRunning = true
        PriceLog.event("price worker start \(api.base.absoluteString)")
        while slots.count < poolSize { slots.append(Slot(makeBrowser())) }
        if let warmUpURL {
            for (i, slot) in slots.enumerated() where !slot.busy && slot.warm == nil {
                let browser = slot.browser
                slot.warm = Task {
                    let t0 = ContinuousClock.now
                    await browser.warmUp(warmUpURL)
                    PriceLog.event("price browser \(i) warm-up \(Self.ms(since: t0)) ms\(Task.isCancelled ? " (cut short)" : "")")
                }
            }
        }
        setUpStore(storeLocation)
        let interval = pollInterval
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        guard isRunning || !inFlight.isEmpty else { return }
        PriceLog.event("price worker stop")
        loop?.cancel()
        loop = nil
        isRunning = false
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        storeTask?.cancel()
        storeTask = nil
        storeTarget = nil
        storeBrowser?.close()
        for slot in slots {
            slot.warm?.cancel()
            slot.warm = nil
            slot.busy = false
            slot.browser.close()
        }
        active = []
    }

    /// Sets the server without starting the poll loop (tests drive `pollOnce` directly).
    func use(api: DibsAPI) { self.api = PriceAPI(api: api) }

    /// One poll: fetch open requests and start each due one on a free browser. Returns without
    /// waiting for the lookups (see `isIdle`).
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
            guard let slot = freeSlot() else { break }
            let attempt = (attempts[request.id] ?? 0) + 1
            attempts[request.id] = attempt
            retryAt[request.id] = nil
            if attempt > 1 { PriceLog.event("price \(request.id) retry \(attempt - 1)") }
            slot.busy = true
            inFlight[request.id] = Task { [weak self] in
                await self?.lookUp(request, attempt: attempt, on: slot, api: api)
            }
        }
    }

    /// No lookup in flight.
    var isIdle: Bool { inFlight.isEmpty }


    private func freeSlot() -> Slot? {
        if let slot = slots.first(where: { !$0.busy }) { return slot }
        guard slots.count < poolSize else { return nil }
        let slot = Slot(makeBrowser())
        slots.append(slot)
        return slot
    }

    /// New requests, and a priceless first attempt once its retry delay has passed.
    private func isDue(_ id: String) -> Bool {
        guard inFlight[id] == nil else { return false }
        switch attempts[id] ?? 0 {
        case 0: return true
        case 1: return retryAt[id].map { ContinuousClock.now >= $0 } ?? false
        default: return false
        }
    }

    private func lookUp(_ request: PriceRequest, attempt: Int, on slot: Slot, api: PriceAPI) async {
        lookupBrowsers[request.id] = slot.browser
        defer {
            slot.busy = false
            inFlight[request.id] = nil
            lookupBrowsers[request.id] = nil
        }
        if let warm = slot.warm {
            // The search page replaces the home page; cookies and caches are already warming.
            warm.cancel()
            await warm.value
            slot.warm = nil
        }
        if let location = request.storeLocation { setUpStore(location) }
        let outcome = await handle(request, browser: slot.browser, api: api)
        if Task.isCancelled { return }
        lastOutcome = outcome
        outcomes.append(outcome)
        if outcome.cents != nil {
            gaveUpNames.remove(request.name)
        } else if attempt == 1 && outcome.retryable {
            retryAt[request.id] = .now + retryDelay
            PriceLog.event("price \(request.id) no price; retrying in \(retryDelay)")
        } else {
            gaveUpNames.insert(request.name)
            PriceLog.event("price \(request.id) gave up on \"\(request.name)\"")
        }
    }

    // MARK: store

    /// Switches the site's pickup store in the background, on its own browser (cookies are shared,
    /// so the lookup browsers price there from their next page). Never blocks or uses a lookup.
    /// Up to `storeAttempts` tries, `storeRetryInterval` apart.
    func setUpStore(_ location: StoreLocation) {
        guard storeTarget != location else { return }
        storeTarget = location
        storeTask?.cancel()
        storeTask = Task { [weak self] in await self?.runStoreSetup(location) }
    }

    private func runStoreSetup(_ location: StoreLocation) async {
        let browser = storeBrowser ?? makeStoreBrowser()
        storeBrowser = browser
        defer { if !Task.isCancelled { browser.close() } }
        for attempt in 1...storeAttempts {
            if Task.isCancelled { return }
            let t0 = ContinuousClock.now
            let result = await browser.setStore(location)
            if Task.isCancelled { return }
            switch result {
            case .already:
                PriceLog.event("price store already \(location.name)")
                activeStore = location
                return
            case .set:
                PriceLog.event("price store set \(location.name) (\(Self.ms(since: t0)) ms)")
                activeStore = location
                return
            case .failed(let step):
                PriceLog.event("price store setup attempt \(attempt)/\(storeAttempts) failed at \(step)")
            }
            if attempt < storeAttempts { try? await Task.sleep(for: storeRetryInterval) }
        }
        PriceLog.event("price store setup gave up; pricing at the site's current store")
    }

    private struct Timing {
        var open = 0, render = 0, extract = 0
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private func handle(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI) async -> Outcome {
        guard let url = URL(string: request.searchUrl) else {
            PriceLog.event("price \(request.id) bad searchUrl")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        }
        let host = BrowserPolicy.domain(of: url) ?? "the store"
        active.append(Lookup(requestId: request.id, name: request.name, host: host))
        let start = ContinuousClock.now
        var timing = Timing()
        defer {
            active.removeAll { $0.requestId == request.id }
            PriceLog.event("price \(request.id) timing open=\(timing.open) render=\(timing.render) extract=\(timing.extract) total=\(Self.ms(since: start))")
        }
        browser.restrict(to: url)
        PriceLog.event("price \(request.id) start \"\(request.name)\" at \(request.store)")

        var readNoMatch = false
        do {
            switch try await fastPath(request, browser: browser, api: api, timing: &timing) {
            case .found(let outcome): return outcome
            case .noMatch: readNoMatch = true
            case .unreadable: break
            }
        } catch let error as DibsError {
            PriceLog.event("price \(request.id) extract failed: \(error.localizedDescription); skipping")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        } catch {
            PriceLog.event("price \(request.id) page failed: \(error.localizedDescription); trying agent")
        }
        if Task.isCancelled { return Outcome(requestId: request.id, name: request.name, via: .failed) }

        if readNoMatch {
            // The results page loaded and had no match: the store likely doesn't carry it.
            // A short, capped look, then give up (no retry).
            PriceLog.event("price \(request.id) quick agent look (\(giveUpSteps) steps, \(Int(giveUpSeconds)) s)")
            var outcome = await cappedAgent(request, browser: browser, api: api, maxSteps: giveUpSteps, seconds: giveUpSeconds)
            if outcome.cents == nil { outcome.retryable = false }
            return outcome
        }
        do {
            return try await agentLoop(request, browser: browser, api: api, seed: Self.priceSeed(request), maxSteps: Self.maxAgentSteps)
        } catch {
            PriceLog.event("price \(request.id) agent stopped: \(error.localizedDescription)")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        }
    }

    /// The agent loop with a wall-clock cap; on timeout or error it ends as not found.
    private func cappedAgent(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI,
                             maxSteps: Int, seconds: Double) async -> Outcome {
        let work = Task { [weak self] () -> Outcome? in
            try await self?.agentLoop(request, browser: browser, api: api, seed: Self.priceSeed(request), maxSteps: maxSteps)
        }
        let capped = Flag()
        let timer = Task {
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            if !Task.isCancelled { capped.on = true; work.cancel() }
        }
        let result = await withTaskCancellationHandler { await work.result } onCancel: { work.cancel() }
        timer.cancel()
        switch result {
        case .success(let outcome?): return outcome
        case .success(nil): return Outcome(requestId: request.id, name: request.name, via: .failed)
        case .failure where capped.on || Task.isCancelled:
            PriceLog.event("price \(request.id) quick agent hit the \(Int(seconds)) s cap")
            return Outcome(requestId: request.id, name: request.name, via: .notFound)
        case .failure(let error):
            PriceLog.event("price \(request.id) quick agent stopped: \(error.localizedDescription)")
            return Outcome(requestId: request.id, name: request.name, via: .failed)
        }
    }

    /// The page is ready to read: it says "results", or it names the item's first word and shows
    /// a price like "$1.10".
    static func rendered(_ text: String, item: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("results") { return true }
        guard let word = item.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first,
              lower.contains(word) else { return false }
        return text.range(of: #"\$\s?\d+\.\d{2}"#, options: .regularExpression) != nil
    }

    @MainActor private final class Flag { var on = false }

    private enum FastResult {
        case found(Outcome)
        /// The page rendered and /extract found no match.
        case noMatch
        /// The page never rendered, or had no text.
        case unreadable
    }

    /// open → poll until rendered (25 s, then one reload and 20 s more) → /extract.
    private func fastPath(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI,
                          timing: inout Timing) async throws -> FastResult {
        PriceLog.event("price \(request.id) open \(BrowserPolicy.safeURL(URL(string: request.searchUrl)))")
        var t0 = ContinuousClock.now
        _ = try await browser.run(tool: "browser_open", args: ["url": request.searchUrl])
        timing.open = Self.ms(since: t0)
        t0 = ContinuousClock.now
        var (ready, text) = await waitRendered(browser, item: request.name, seconds: waitSeconds)
        if !ready {
            PriceLog.event("price \(request.id) not rendered after \(Int(waitSeconds)) s; reloading")
            _ = try await browser.run(tool: "browser_act", args: ["action": "reload"])
            (ready, text) = await waitRendered(browser, item: request.name, seconds: reloadWaitSeconds)
        }
        timing.render = Self.ms(since: t0)
        text = String(text.prefix(Self.pageTextLimit))
        PriceLog.event("price \(request.id) \(ready ? "rendered" : "still not rendered"), \(text.count) chars")
        if !ready {
            let head = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(200)
            PriceLog.event("price \(request.id) page starts: \(head)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unreadable }
        t0 = ContinuousClock.now
        let reply = try await api.extract(id: request.id, pageText: text)
        timing.extract = Self.ms(since: t0)
        if reply["found"] as? Bool == true, let cents = reply["priceCents"] as? Int {
            let product = reply["productName"] as? String
            PriceLog.event("price \(request.id) found \(Money.format(cents)) \"\(product ?? "")\" from page")
            return .found(Outcome(requestId: request.id, name: request.name, via: .page, cents: cents, productName: product))
        }
        PriceLog.event("price \(request.id) page had no match")
        return ready ? .noMatch : .unreadable
    }

    /// Observes every `renderPoll` until `rendered` or `seconds` pass. Returns the last page text.
    private func waitRendered(_ browser: PriceBrowsing, item: String, seconds: Double) async -> (Bool, String) {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        var text = ""
        while true {
            if let observation = try? await browser.run(tool: "browser_observe", args: [:]) {
                text = observation["text"] as? String ?? ""
                if Self.rendered(text, item: item) { return (true, text) }
            }
            if Task.isCancelled || ContinuousClock.now >= deadline { return (false, text) }
            try? await Task.sleep(for: renderPoll)
        }
    }

    /// The team's Gemini browser agent, with the model on the server: post the conversation,
    /// run the model's browser calls here, append both turns, repeat.
    /// The server seeds the Item/Store line when contents is empty; sending the turn ourselves
    /// keeps the task (and the wait instruction) in the history every later step must carry.
    static func priceSeed(_ request: PriceRequest) -> String {
        "\(agentWaitInstruction)\nItem: \"\(request.name)\". Store: \(request.store). Start at \(request.searchUrl)."
    }

    /// 12 steps make 23 entries, under the server's 24.
    private func agentLoop(_ request: PriceRequest, browser: PriceBrowsing, api: PriceAPI,
                           seed: String, maxSteps: Int) async throws -> Outcome {
        var contents: [[String: Any]] = [["role": "user", "parts": [["text": seed]]]]
        for step in 1...max(1, min(maxSteps, Self.maxAgentSteps)) {
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
        PriceLog.event("price \(request.id) agent hit the \(maxSteps)-step cap")
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
