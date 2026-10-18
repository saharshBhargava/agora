import Foundation

/// Uses the very same WKWebView as chat, only after the backend requests its final fallback.
@MainActor
final class WatchBrowserRunner {
    private let api: AgoraClient
    private let browser: BrowserSession
    private let store: WatchStore
    private let canStart: () -> Bool
    private var running = false

    init(api: AgoraClient, browser: BrowserSession, store: WatchStore, canStart: @escaping () -> Bool) {
        self.api = api; self.browser = browser; self.store = store; self.canStart = canStart
    }
    func check(_ watch: PriceWatch) async {
        guard !running, canStart(), !Task.isCancelled, watch.status == "active", watch.simulationDisclosure == nil,
              !watch.isChecking, let fallback = watch.browserFallback, fallback.status == "pending" else { return }
        let owner: UUID
        do { owner = try browser.beginPriceResearch() }
        catch { store.setBrowserStatus("Browser backup is waiting for your chat browser to be free.", for: watch.id); return }
        running = true
        let context = store.context, epoch = browser.epoch, lease = browser.lease
        defer {
            browser.endPriceResearch(owner, epoch: epoch, lease: lease)
            running = false
        }
        var claim: WatchBrowserClaim?
        let body: [String: Any] = ["run_id": fallback.runId.uuidString, "criteria_version": watch.criteriaVersion]
        do {
            try await browser.preparePriceResearch(owner)
            try checkContext(context, epoch, lease)
            store.setBrowserStatus("Trying the browser backup…", for: watch.id)
            let claimed = try await api.fetch("v1/watches/\(watch.id)/browser-claim", as: WatchBrowserClaim.self,
                                              method: "POST", body: body, key: UUID().uuidString)
            claim = claimed
            var pages: [[String: Any]] = []
            var interactionRequired = false
            for source in claimed.urls.prefix(5) {
                try checkContext(context, epoch, lease)
                // Reserve enough lease time for navigation, rendering and posting the evidence.
                guard Date().addingTimeInterval(30) < claimed.expiresAt,
                      let url = URL(string: source) else { break }
                do {
                    _ = try await browser.open(url)
                    let deadline = ContinuousClock.now + .seconds(8)
                    repeat {
                        try checkContext(context, epoch, lease)
                        var evidence = try await browser.priceEvidence()
                        if let products = evidence["products"] as? [[String: Any]], !products.isEmpty {
                            guard let final = (evidence["final_url"] as? String).flatMap(URL.init(string:)),
                                  final.host?.lowercased() == url.host?.lowercased() else { break }
                            evidence["source_url"] = source; pages.append(evidence); break
                        }
                        try await Task.sleep(for: .milliseconds(300))
                    } while ContinuousClock.now < deadline
                } catch {
                    try checkContext(context, epoch, lease)
                    if (error as? BrowserError)?.code.hasPrefix("user_action_required") == true { interactionRequired = true }
                    // A private or blocked page does not prevent trying another public retailer.
                    browser.state.privateMode = false
                }
            }
            try checkContext(context, epoch, lease)
            _ = try await api.fetch("v1/watches/\(watch.id)/browser-result", as: WatchBrowserResult.self,
                method: "POST", body: body.merging(["token": claimed.token.uuidString, "pages": pages,
                    "outcome": pages.isEmpty ? (interactionRequired ? "interaction_required" : "unavailable") : "completed"]) { _, new in new },
                key: UUID().uuidString)
            try checkContext(context, epoch, lease)
            store.setBrowserStatus(nil, for: watch.id)
            await store.refresh(poll: false)
        } catch {
            // A cancelled device never uploads stale evidence. The server lease expires for safe retry.
            if store.context == context, !Task.isCancelled {
                store.setBrowserStatus(claim == nil ? "Browser backup could not start. Pull to refresh to retry." :
                    "Browser backup paused. It will retry when the browser is free.", for: watch.id)
            }
        }
    }
    private func checkContext(_ context: UUID, _ epoch: UInt64, _ lease: UInt64) throws {
        guard store.context == context, canStart() else { throw CancellationError() }
        try browser.check(epoch: epoch, lease: lease)
    }
}
