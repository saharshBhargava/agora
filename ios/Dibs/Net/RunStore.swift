import Foundation
import Observation
import UIKit

/// The app's live view of one run: REST snapshot plus socket updates.
///
/// On every (re)connect the store fetches the run over REST before it applies socket messages:
/// messages that arrive while that fetch is in flight are held, then replayed in order on top of it.
/// Messages and fetch results from an earlier connection are dropped as stale.
@MainActor
@Observable
public final class RunStore {
    public enum Connection: Equatable, Sendable {
        case connecting, live, reconnecting, refused
    }

    public static let reconnectingMessage = "Reconnecting…"

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
    @ObservationIgnored private var held: [ServerMsg] = []

    public init(fetchRun: @escaping Fetch, makeSocket: @escaping SocketFactory) {
        self.fetchRun = fetchRun
        self.makeSocket = makeSocket
    }

    public convenience init(api: DibsAPI) {
        let base = api.base
        self.init(
            fetchRun: { runId in try await api.getRun(runId) },
            makeSocket: { runId, personId in RunSocket(base: base, runId: runId, personId: personId) }
        )
    }

    // MARK: connection

    public func connect(runId: String, personId: String) {
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
        socket = s
        s.start()
    }

    public func disconnect() {
        epoch += 1
        socket?.onEvent = nil
        socket?.onMessage = nil
        socket?.stop()
        socket = nil
        syncing = false
        held = []
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
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
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
        case .refused:
            connection = .refused
            syncing = false
            held = []
        }
    }

    private func resync() {
        guard let runId else { return }
        syncGen += 1
        let gen = syncGen
        let myEpoch = epoch
        syncing = true
        held = []
        Task { [weak self, fetchRun] in
            let result: Result<Run, Error>
            do { result = .success(try await fetchRun(runId)) } catch { result = .failure(error) }
            guard let self, self.epoch == myEpoch, self.syncGen == gen, self.syncing else { return }
            switch result {
            case .success(let r): self.apply(run: r)
            case .failure(let e): self.lastError = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
            self.syncing = false
            let queued = self.held
            self.held = []
            for m in queued { self.apply(m) }
        }
    }

    private func receive(_ msg: ServerMsg) {
        if syncing {
            held.append(msg)
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

    private func apply(run r: Run) {
        run = r
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
        if socket?.send(msg) == true { return true }
        lastError = Self.reconnectingMessage
        return false
    }
}
