import Foundation
import Observation
import UIKit

/// The app's live view of one run: REST snapshot plus socket updates.
///
/// On every (re)connect the store fetches the run over REST before it applies socket messages:
/// messages that arrive while that fetch is in flight are held, then replayed in order on top of it.
/// Messages and fetch results from an earlier connection are dropped as stale. Once the REST run is
/// applied, held `{t:'run'}` snapshots are dropped, except the newest one that arrived after the REST
/// request went out (the server broadcasts the full run on every change, so that one may be newer).
/// A chip action that may not have reached the server (send failure, or a drop before the server
/// answered) always surfaces in `lastError`: claims are never silently lost.
@MainActor
@Observable
public final class RunStore {
    public enum Connection: Equatable, Sendable {
        case connecting, live, reconnecting, refused
    }

    public static let reconnectingMessage = "Reconnecting…"
    public static let notSentMessage = "That didn't reach the server. Check your items and try again."

    public private(set) var run: Run?
    public private(set) var connection: Connection = .connecting
    /// The latest error to show: a server `{t:'error'}` reason, a failed fetch, or "Reconnecting…".
    public var lastError: String?
    /// Bumped on every server error, so identical repeats are distinguishable.
    public private(set) var errorSeq = 0
    /// Latest relayed camera frame (claimers' live view).
    public private(set) var liveFrame: UIImage?
    /// Where the server is identifying an item right now, in frame coordinates.
    public private(set) var identifyingRegion: Box?
    public private(set) var lastCallEndsAt: Date?
    public private(set) var runId: String?
    public private(set) var personId: String?

    /// This phone's person in the run.
    public var me: Person? {
        guard let personId else { return nil }
        return run?.person(personId)
    }

    public typealias Fetch = @Sendable (String) async throws -> Run
    public typealias SocketFactory = @MainActor (_ runId: String, _ personId: String) -> RunSocketing

    private let fetchRun: Fetch
    private let makeSocket: SocketFactory
    @ObservationIgnored private var socket: RunSocketing?
    /// Which connect() call is current; callbacks from older sockets are ignored.
    @ObservationIgnored private var epoch = 0
    /// Which (re)open is current; fetches from older opens are ignored.
    @ObservationIgnored private var syncGen = 0
    @ObservationIgnored private var syncing = false
    /// Messages held during a resync, with whether they arrived after the REST request went out.
    @ObservationIgnored private var held: [(msg: ServerMsg, afterRequest: Bool)] = []
    @ObservationIgnored private var requestIssued = false
    /// Chip actions sent since the server last spoke; if the connection drops first, they may be lost.
    @ObservationIgnored private var unanswered = 0
    /// The error text a failed REST fetch set, cleared when a fresh run arrives.
    @ObservationIgnored private var fetchError: String?
    /// Closes the socket from deinit if the store is released without disconnect().
    @ObservationIgnored private let teardownBox = TeardownBox()

    public init(fetchRun: @escaping Fetch, makeSocket: @escaping SocketFactory) {
        self.fetchRun = fetchRun
        self.makeSocket = makeSocket
    }

    deinit {
        teardownBox.run()
    }

    public convenience init(api: DibsAPI) {
        let base = api.base
        let keys = api.keys
        self.init(
            fetchRun: { runId in try await api.getRun(runId) },
            makeSocket: { runId, personId in RunSocket(base: base, runId: runId, personId: personId, key: keys.key(runId: runId)) }
        )
    }

    // MARK: connection

    /// Connects to a run. Calling it again for the same run and person while connected or
    /// reconnecting is a no-op (no state wipe).
    public func connect(runId: String, personId: String) {
        if socket != nil, connection != .refused, self.runId == runId, self.personId == personId { return }
        disconnect()
        epoch += 1
        let myEpoch = epoch
        self.runId = runId
        self.personId = personId
        run = nil
        liveFrame = nil
        identifyingRegion = nil
        lastCallEndsAt = nil
        lastError = nil
        connection = .connecting
        let s = makeSocket(runId, personId)
        s.onEvent = { [weak self] event in
            guard let self, self.epoch == myEpoch else { return }
            self.handle(event)
        }
        s.onMessage = { [weak self] msg in
            guard let self, self.epoch == myEpoch else { return }
            self.receive(msg)
        }
        s.onSendFailed = { [weak self] msg in
            guard let self, self.epoch == myEpoch else { return }
            if case .frame = msg { return }
            self.lastError = Self.notSentMessage
        }
        socket = s
        teardownBox.set(s.teardown)
        s.start()
    }

    public func disconnect() {
        epoch += 1
        socket?.onEvent = nil
        socket?.onMessage = nil
        socket?.onSendFailed = nil
        socket?.stop()
        socket = nil
        teardownBox.set(nil)
        syncing = false
        held = []
        unanswered = 0
    }

    /// Call when the app returns to the foreground: re-checks the socket (ping, or reconnect now).
    public func foregrounded() {
        socket?.checkAlive()
    }

    /// Re-fetches the run over REST (for example after a REST call elsewhere), keeping the socket.
    public func refresh() async {
        guard let runId else { return }
        let myEpoch = epoch
        do {
            let r = try await fetchRun(runId)
            guard epoch == myEpoch else { return }
            apply(run: r)
        } catch {
            guard epoch == myEpoch else { return }
            showFetchError(error)
        }
    }

    /// Applies a run a REST call returned, when it is for this run.
    public func adopt(_ r: Run) {
        guard r.id == runId else { return }
        apply(run: r)
    }

    private func handle(_ event: SocketEvent) {
        switch event {
        case .connecting:
            if connection != .live && connection != .reconnecting { connection = .connecting }
        case .open:
            connection = .live
            if lastError == Self.reconnectingMessage { lastError = nil }
            resync()
        case .closed:
            connection = .reconnecting
            // Anything held from the dropped connection is stale; the next open re-fetches.
            syncing = false
            held = []
            if unanswered > 0 { lastError = Self.notSentMessage }
            unanswered = 0
        case .refused:
            // Refusal wins over anything a resync set.
            connection = .refused
            syncGen += 1
            syncing = false
            held = []
            unanswered = 0
            lastError = nil
            fetchError = nil
        }
    }

    private func resync() {
        guard let runId else { return }
        syncGen += 1
        let gen = syncGen
        let myEpoch = epoch
        syncing = true
        requestIssued = false
        held = []
        Task { [weak self, fetchRun] in
            guard let self, self.epoch == myEpoch, self.syncGen == gen else { return }
            self.requestIssued = true
            let result: Result<Run, Error>
            do { result = .success(try await fetchRun(runId)) } catch { result = .failure(error) }
            guard self.epoch == myEpoch, self.syncGen == gen, self.syncing else { return }
            let queued = self.held
            self.held = []
            self.syncing = false
            var newestRun: Int?
            switch result {
            case .success(let r):
                self.apply(run: r)
                // Held snapshots from before the request are older than r: drop them. Keep only the
                // newest snapshot that arrived after the request, which may be newer than r.
                newestRun = queued.lastIndex { if case .run = $0.msg { return $0.afterRequest } else { return false } }
            case .failure(let e):
                self.showFetchError(e)
                newestRun = queued.lastIndex { if case .run = $0.msg { return true } else { return false } }
            }
            for (i, h) in queued.enumerated() {
                if case .run = h.msg, i != newestRun { continue }
                self.apply(h.msg)
            }
        }
    }

    private func receive(_ msg: ServerMsg) {
        switch msg {
        case .run, .error: unanswered = 0
        default: break
        }
        if syncing {
            held.append((msg, requestIssued))
        } else {
            apply(msg)
        }
    }

    // MARK: applying messages

    private func apply(_ msg: ServerMsg) {
        switch msg {
        case .run(let r):
            guard r.id == runId else { return }
            apply(run: r)
        case .frame(let jpegBase64, _):
            if let data = Data(base64Encoded: jpegBase64), let image = UIImage(data: data) { liveFrame = image }
        case .lastCall(let endsAt):
            lastCallEndsAt = Date(timeIntervalSince1970: endsAt / 1000)
        case .locked:
            lastCallEndsAt = nil
        case .identifying(let region):
            identifyingRegion = region
        case .error(let reason):
            lastError = reason
            errorSeq += 1
        case .unknown:
            break
        }
    }

    private func showFetchError(_ e: Error) {
        let text = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
        lastError = text
        fetchError = text
    }

    private func apply(run r: Run) {
        run = r
        if let f = fetchError {
            if lastError == f { lastError = nil }
            fetchError = nil
        }
        if let ends = r.lastCallEndsAt {
            lastCallEndsAt = Date(timeIntervalSince1970: ends / 1000)
        } else {
            lastCallEndsAt = nil
        }
        // No chip is identifying any more: clear the outline.
        if !r.chips.contains(where: { $0.state == .identifying && !$0.dropped }) { identifyingRegion = nil }
    }

    // MARK: actions

    @discardableResult public func claim(_ chipId: String) -> Bool { send(.claim(chipId: chipId)) }
    @discardableResult public func leave(_ chipId: String) -> Bool { send(.leave(chipId: chipId)) }
    @discardableResult public func remove(_ chipId: String) -> Bool { send(.remove(chipId: chipId)) }
    @discardableResult public func undoRemove(_ chipId: String) -> Bool { send(.undoRemove(chipId: chipId)) }
    @discardableResult public func identifyAt(x: Double, y: Double) -> Bool { send(.identifyAt(x: x, y: y)) }

    /// Sends one shopper camera frame. A dropped frame is not an error (the next one follows).
    @discardableResult
    public func sendFrame(jpeg: Data, detect: Bool) -> Bool {
        let at = (Date().timeIntervalSince1970 * 1000).rounded()
        return socket?.send(.frame(jpegBase64: jpeg.base64EncodedString(), at: at, detect: detect)) ?? false
    }

    /// Returns false and sets `lastError` to "Reconnecting…" when the socket is not open.
    private func send(_ msg: ClientMsg) -> Bool {
        if socket?.send(msg) == true {
            unanswered += 1
            return true
        }
        lastError = Self.reconnectingMessage
        return false
    }
}

/// Holds the socket's teardown so the store's nonisolated deinit can close it.
private final class TeardownBox: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?

    func set(_ a: (@Sendable () -> Void)?) { lock.withLock { action = a } }

    func run() {
        let a = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { action = nil }
            return action
        }
        a?()
    }
}
