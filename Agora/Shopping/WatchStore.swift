import Foundation
import Combine

@MainActor
final class WatchStore: ObservableObject {
    @Published private(set) var notifications: [WatchNotification] = []
    @Published private(set) var watches: [PriceWatch] = []
    @Published private(set) var searchAvailable = false
    @Published private(set) var discoveryAvailable = false
    @Published private(set) var hasLoadedCapabilities = false
    @Published private(set) var automaticWatches = false
    @Published private(set) var discoveryStatus: String?
    @Published private(set) var loading = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var context = UUID()
    @Published var openWatchID: UUID?
    @Published private(set) var browserReviewRequestID: UUID?
    var browserReviewHandler: ((URL) throws -> Void)?
    var browserFallbackHandler: ((PriceWatch) async -> Void)?
    @Published private(set) var browserFallbackStatus: [UUID: String] = [:]
    private let api: AgoraClient
    private var householdID: UUID?
    private var subscription: AnyCancellable?
    private var loadID = UUID()
    private var mutationKeys: [String: String] = [:]
    private var pollingTask: Task<Void, Never>?

    init(api: AgoraClient, inventory: InventoryStore) {
        self.api = api
        subscription = inventory.$householdID.combineLatest(inventory.$context)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.sink { [weak self] household, _ in
                guard let self else { return }
                self.pollingTask?.cancel(); self.pollingTask = nil
                self.householdID = household; self.context = UUID(); self.loadID = UUID()
                self.watches = []; self.notifications = []; self.searchAvailable = false; self.discoveryAvailable = false; self.loading = false; self.busy = false
                self.hasLoadedCapabilities = false
                self.automaticWatches = false
                self.discoveryStatus = nil
                self.error = nil; self.notice = nil; self.openWatchID = nil; self.browserReviewRequestID = nil; self.mutationKeys = [:]
                self.browserFallbackStatus = [:]
            }
    }
    var canUse: Bool { householdID != nil }
    var hasPendingWork: Bool {
        watches.contains { $0.isChecking || ["pending", "claimed"].contains($0.browserFallback?.status ?? "") }
    }
    var discoveryUnavailable: Bool { hasLoadedCapabilities && !discoveryAvailable }
    var discoveryExplanation: String {
        switch discoveryStatus {
        case "model_not_configured":
            return "Background search needs a model connection on the service. Web search providers are configured separately. A product link can still be checked without a model."
        case "search_not_configured":
            return "Background search needs an enabled web search provider. A product link can still be checked directly."
        default:
            return "Broad retailer discovery is unavailable. A supported product link can still be checked directly."
        }
    }
    func watch(for item: WishlistItem) -> PriceWatch? { watches.first { $0.wishlistItemId == item.id } }
    var missingWatchStatus: String {
        if let error { return error }
        if !canUse { return "Sign in to load price checks." }
        if !hasLoadedCapabilities { return loading ? "Loading price checks…" : "Price checks haven’t loaded. Pull to refresh." }
        if !automaticWatches { return "Automatic price checks aren’t enabled on this service yet." }
        return "Price checks haven’t started for this item. Pull to refresh."
    }
    func setBrowserStatus(_ message: String?, for watch: UUID) { browserFallbackStatus[watch] = message }
    func runBrowserFallbacks() async {
        guard let browserFallbackHandler else { return }
        let version = context
        for watch in watches where watch.browserFallback?.status == "pending" && !watch.isChecking {
            guard context == version, !Task.isCancelled else { return }
            await browserFallbackHandler(watch)
        }
    }
    private func check(_ version: UUID) throws {
        try Task.checkCancellation()
        guard context == version else { throw CancellationError() }
    }
    func refresh(poll: Bool = true) async {
        guard let householdID else { return }
        let version = context, request = UUID(); loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        do {
            let result = try await api.fetch("v1/watches", as: WatchListResponse.self,
                query: [.init(name: "household_id", value: householdID.uuidString)])
            try check(version); guard loadID == request else { return }
            watches = result.watches; searchAvailable = result.searchAvailable; discoveryAvailable = result.discoveryAvailable ?? result.searchAvailable
            let pending = Set(watches.filter { ["pending", "claimed"].contains($0.browserFallback?.status ?? "") }.map(\.id))
            browserFallbackStatus = browserFallbackStatus.filter { pending.contains($0.key) }
            hasLoadedCapabilities = true; error = nil
            automaticWatches = result.automaticWatches == true
            discoveryStatus = result.discoveryStatus
            if poll { pollPendingChecks() }
        } catch {
            if context == version, loadID == request, !Task.isCancelled {
                hasLoadedCapabilities = false
                discoveryStatus = nil
                if (error as? BrowserError)?.status == 404 {
                    self.error = "Price watches aren’t available on the connected service yet. Please try again after it has been updated."
                } else { self.error = InventoryStore.message(error) }
            }
        }
    }
    func detail(_ id: UUID) async {
        let version = context
        guard householdID != nil else { return }
        do {
            let result = try await api.fetch("v1/watches/\(id)", as: PriceWatch.self)
            try check(version)
            guard result.householdId == householdID else { return }
            upsert(result)
            if notice?.hasPrefix("Check queued") == true, !result.runs.contains(where: { ["queued", "running"].contains($0.status) }) { notice = nil }
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    private func upsert(_ watch: PriceWatch) {
        loadID = UUID(); loading = false
        watches.removeAll { $0.id == watch.id }; watches.insert(watch, at: 0); error = nil
        pollPendingChecks()
    }
    private func pollPendingChecks() {
        guard pollingTask == nil, watches.contains(where: \.isChecking) else { return }
        let version = context
        pollingTask = Task { [weak self] in
            // Bounded foreground refresh; account changes cancel it and background jobs keep running.
            for _ in 0..<45 {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                guard let self, self.context == version, !Task.isCancelled else { break }
                await self.refresh(poll: false)
                if !self.watches.contains(where: \.isChecking) { break }
            }
            if let self, self.context == version { self.pollingTask = nil }
        }
    }
    func save(_ draft: WatchDraft, itemID: UUID, confirmed: Bool, key: String) async throws {
        guard householdID != nil, !busy else { throw CancellationError() }
        let body = try draft.body(confirmed: confirmed), version = context
        busy = true; defer { if context == version { busy = false } }
        let result = try await api.fetch("v1/wishlist/\(itemID)/watch", as: PriceWatch.self, method: "PUT", body: body, key: key)
        try check(version); guard result.householdId == householdID else { throw CancellationError() }
        upsert(result)
        notice = result.searchAvailable ? "Watch settings saved." : "Watch saved. Retailer search is currently unavailable."
    }
    func setPaused(_ watch: PriceWatch, paused: Bool) async {
        guard watch.householdId == householdID, !busy else { return }
        let version = context; busy = true
        defer { if context == version { busy = false } }
        do {
            let result = try await api.fetch("v1/watches/\(watch.id)", as: PriceWatch.self, method: "PATCH",
                body: ["status": paused ? "paused" : "active"])
            try check(version); upsert(result)
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func checkNow(_ watch: PriceWatch) async {
        guard watch.householdId == householdID, watch.status == "active", watch.searchAvailable, !busy else { return }
        let version = context, operation = "check-\(watch.id)"; busy = true; notice = nil
        defer { if context == version { busy = false } }
        let key = mutationKeys[operation] ?? UUID().uuidString; mutationKeys[operation] = key
        do {
            _ = try await api.fetch("v1/watches/\(watch.id)/check", as: WatchCheckResponse.self, method: "POST", key: key)
            try check(version); mutationKeys[operation] = nil; error = nil
            notice = "Check queued. Pull to refresh for updated offers."
            await detail(watch.id)
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func refreshInbox() async {
        guard let householdID else { return }
        let version = context
        do {
            let rows = try await api.fetch("v1/notifications", as: [WatchNotification].self,
                query: [.init(name: "household_id", value: householdID.uuidString)])
            try check(version); notifications = rows; error = nil
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func markRead(_ notification: WatchNotification) async {
        guard notification.householdId == householdID else { return }
        let version = context
        do {
            _ = try await api.fetch("v1/notifications/\(notification.id)/read", as: WatchReadResponse.self, method: "POST")
            try check(version); await refreshInbox()
        } catch { if context == version, !Task.isCancelled { self.error = InventoryStore.message(error) } }
    }
    func reviewInBrowser(watchID: UUID, url: URL) {
        guard let watch = watches.first(where: { $0.id == watchID }), watch.householdId == householdID,
              watch.browserReviewURLs.contains(url) else {
            error = "This browser review is no longer available. Refresh the watch for current sources."
            return
        }
        do {
            try BrowserPolicy().validate(url)
            guard let browserReviewHandler else {
                throw BrowserError("browser_unavailable", "The shared browser is unavailable. Open this watch from the signed-in app.")
            }
            try browserReviewHandler(url)
            error = nil; browserReviewRequestID = UUID()
        } catch { self.error = InventoryStore.message(error) }
    }
    func enablePushAlerts() async {
        let version = context
        do { try await PushNotifications.shared.enable(api: api); try check(version) }
        catch { if context == version, !Task.isCancelled { notice = "Watch saved. Push alerts: " + InventoryStore.message(error) + " Offers remain available in your inbox." } }
    }

}
