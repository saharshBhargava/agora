import Foundation
import Observation

/// App-wide state: the server, the navigation path and the one live `RunStore` the run screens share.
@MainActor
@Observable
final class AppModel {
    /// Screens above Home. Bound to the root `NavigationStack`.
    var path: [Route] = []
    private(set) var server: URL
    private(set) var api: DibsAPI
    /// The live run this phone is in. Screens call `enter(_:)`; Home disconnects it.
    private(set) var store: RunStore
    /// True while the launch check for a run to resume is in flight.
    private(set) var resuming = false
    /// A problem to show on Home (a link that is not a Dibs link, for example).
    var homeError: String?
    /// A link that names a server other than this one; waits for the person to confirm the switch.
    private(set) var pendingLink: JoinLink?

    let defaults: UserDefaults
    /// The server baked into the build (`DIBS_SERVER_URL`).
    let bundledServer: URL?
    @ObservationIgnored private var launched = false
    /// Bumped on every navigation the person asked for, so a slow launch resume never overrides it.
    @ObservationIgnored private var intent = 0

    init(defaults: UserDefaults = .standard, bundledServer: URL? = ServerConfig.bundled()) {
        self.defaults = defaults
        self.bundledServer = bundledServer
        let saved = defaults.string(forKey: ServerConfig.serverKey).flatMap(ServerConfig.validate)
        let server = saved ?? bundledServer ?? ServerConfig.fallback
        let api = DibsAPI(base: server)
        self.server = server
        self.api = api
        self.store = RunStore(api: api)
    }

    // MARK: launch and links

    /// Once per app launch: reopen the last run this phone was in, unless it has settled.
    func launch() async {
        guard !launched else { return }
        launched = true
        let mine = intent
        guard HomeRouting.savedRun(defaults: defaults) != nil else { return }
        resuming = true
        let api = self.api
        let route = await HomeRouting.launchRoute(defaults: defaults) { try await api.getRun($0) }
        resuming = false
        guard let route, mine == intent, path.isEmpty, api.base == self.api.base else { return }
        path = [route]
    }

    /// `dibs://join?run=` from the system, or a universal link.
    func open(url: URL) {
        guard let link = JoinLink.parse(url.absoluteString) else {
            homeError = "That isn't a Dibs link."
            return
        }
        Task { await open(link) }
    }

    /// Opens a join link. A link for this server (or the built-in one) is used at once; a link naming
    /// any other server waits in `pendingLink` until the person confirms the switch. Goes straight back
    /// into the run when this phone already joined it, otherwise to the join screen.
    func open(_ link: JoinLink) async {
        intent += 1
        homeError = nil
        if let linkServer = link.server, linkServer != server {
            guard linkServer == bundledServer else {
                pendingLink = link
                return
            }
            ServerConfig.reset(defaults: defaults)
            apply(linkServer)
        }
        pendingLink = nil
        await proceed(link)
    }

    /// "Use server": saves the link's server, then opens the link.
    func confirmPendingServer(_ link: JoinLink?) async {
        guard let link, let linkServer = link.server else { return }
        intent += 1
        pendingLink = nil
        useServer(linkServer)
        await proceed(link)
    }

    /// "Cancel": forget the link; nothing changes.
    func cancelPendingServer() {
        pendingLink = nil
    }

    private func proceed(_ link: JoinLink) async {
        let mine = intent
        if let personId = ServerConfig.personId(runId: link.runId, defaults: defaults) {
            let api = self.api
            let route = await HomeRouting.resume(RunRef(runId: link.runId, personId: personId)) { try await api.getRun($0) }
            guard mine == intent else { return }
            if let route {
                HomeRouting.saveLastRun(link.runId, defaults: defaults)
                path = [route]
                return
            }
        }
        path = [.join(runId: link.runId, decline: link.decline)]
    }

    // MARK: runs

    /// Creates a run with this phone as the shopper and opens the invite screen.
    func startRun() async throws {
        intent += 1
        let created = try await api.createRun()
        remember(RunRef(runId: created.runId, personId: created.shopperId))
        path = [.start(RunRef(runId: created.runId, personId: created.shopperId))]
    }

    /// Saves this phone's person for the run and makes it the run to resume.
    func remember(_ ref: RunRef) {
        ServerConfig.savePersonId(ref.personId, runId: ref.runId, defaults: defaults)
        HomeRouting.saveLastRun(ref.runId, defaults: defaults)
    }

    /// Replaces the stack with one run screen (after joining, nothing to go back to).
    func show(_ route: Route) {
        intent += 1
        path = [route]
    }

    /// Connects the shared store to this run, unless it already is.
    func enter(_ ref: RunRef) {
        if store.runId == ref.runId, store.personId == ref.personId, store.connection != .refused { return }
        store.connect(runId: ref.runId, personId: ref.personId)
    }

    /// The shopper's way into the receipt flow after checkout ("I've paid · snap the receipt"): pushes
    /// `Route.settle`, which shows the receipt camera while the run is locked, then the check, then Settle.
    func openReceipt(_ ref: RunRef) {
        intent += 1
        if path.last != .settle(ref) { path.append(.settle(ref)) }
    }

    /// When the live run reaches settled or partly settled (or, for the shopper, a read receipt), a claim
    /// or shopper screen on top is replaced by Settle.
    func followRun() {
        guard let run = store.run, store.runId == run.id,
              let next = SettleLogic.follow(path: path, run: run) else { return }
        path = next
    }

    /// Home is showing: stop listening to any run.
    func leaveRun() {
        store.disconnect()
    }

    // MARK: server

    /// Saves a server override from the settings sheet. False when the address is not usable.
    @discardableResult
    func saveServer(_ text: String) -> Bool {
        guard let url = ServerConfig.validate(text) else { return false }
        useServer(url)
        return true
    }

    /// Back to the server baked into the build.
    func resetServer() {
        ServerConfig.reset(defaults: defaults)
        apply(bundledServer ?? ServerConfig.fallback)
    }

    private func useServer(_ url: URL) {
        ServerConfig.save(url.absoluteString, defaults: defaults)
        apply(url)
    }

    private func apply(_ url: URL) {
        guard url != server else { return }
        store.disconnect()
        server = url
        api = DibsAPI(base: url)
        store = RunStore(api: api)
        path = []
    }
}
