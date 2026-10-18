import Foundation

/// Connection lifecycle events a run socket reports.
public enum SocketEvent: Sendable, Equatable {
    case connecting
    /// The socket is open and the server has spoken (its `{t:'run'}` snapshot follows this event).
    /// A server that accepts and then refuses (1008) never reaches `.open`.
    case open
    /// The socket dropped; it reconnects after `retryIn` seconds.
    case closed(retryIn: TimeInterval)
    /// The server refused the socket (close code 1008: unknown run or person). No more reconnects.
    case refused
}

/// What RunStore needs from a socket, so tests can drive it without a network.
@MainActor
public protocol RunSocketing: AnyObject {
    var onMessage: ((ServerMsg) -> Void)? { get set }
    var onEvent: ((SocketEvent) -> Void)? { get set }
    /// A message `send` accepted could not be written. The socket then reconnects.
    var onSendFailed: ((ClientMsg) -> Void)? { get set }
    func start()
    func stop()
    /// Sends when the socket is open. Returns false (and sends nothing) otherwise.
    func send(_ msg: ClientMsg) -> Bool
    /// Checks the connection now (for example when the app returns to the foreground): pings an open
    /// socket and drops it if no pong comes back soon; reconnects at once when waiting to retry.
    func checkAlive()
    /// Closes the connection from any context (used from `deinit`).
    nonisolated var teardown: @Sendable () -> Void { get }
}

/// The live run socket: `<base as ws/wss>/ws?run=&person=`, reconnecting with backoff
/// 0.5, 1, 2, 4, 8 s (capped at 8) and stopping for good on close code 1008.
/// Pings every 10 s; a ping or send failure, or an unanswered ping, drops and reconnects.
@MainActor
public final class RunSocket: RunSocketing {
    public nonisolated static let backoffSchedule: [TimeInterval] = [0.5, 1, 2, 4, 8]

    /// Delay before reconnect attempt `attempt` (0 = first retry after a drop).
    public nonisolated static func backoff(attempt: Int) -> TimeInterval {
        backoffSchedule[min(max(attempt, 0), backoffSchedule.count - 1)]
    }

    /// `<base as ws/wss>/ws?run=<id>&person=<id>`.
    public nonisolated static func url(base: URL, runId: String, personId: String) -> URL {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme?.lowercased() == "https" ? "wss" : "ws"
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        comps.path = path + "/ws"
        comps.queryItems = [URLQueryItem(name: "run", value: runId), URLQueryItem(name: "person", value: personId)]
        return comps.url!
    }

    public var onMessage: ((ServerMsg) -> Void)?
    public var onEvent: ((SocketEvent) -> Void)?
    public var onSendFailed: ((ClientMsg) -> Void)?
    /// True once the server has spoken on the current connection.
    public private(set) var isOpen = false

    private let url: URL
    private let heartbeatInterval: TimeInterval
    private let pingTimeout: TimeInterval
    private nonisolated let resources = SocketResources()
    private var retry: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var attempt = 0
    private var stopped = true
    private var pingSeq = 0
    private var outstandingPing: (seq: Int, sentAt: Date)?
    private let delegate = SocketDelegate()

    private var session: URLSession? { resources.session }
    private var task: URLSessionWebSocketTask? { resources.task }

    public init(base: URL, runId: String, personId: String, heartbeatInterval: TimeInterval = 10, pingTimeout: TimeInterval = 8) {
        url = Self.url(base: base, runId: runId, personId: personId)
        self.heartbeatInterval = heartbeatInterval
        self.pingTimeout = pingTimeout
        delegate.owner = self
    }

    deinit {
        // Released without stop(): close the socket so it stops receiving frames.
        resources.teardown()
    }

    public nonisolated var teardown: @Sendable () -> Void {
        { [resources] in resources.teardown() }
    }

    public func start() {
        guard stopped else { return }
        stopped = false
        attempt = 0
        // Delegate callbacks and receive completions all arrive on the main queue, in order.
        resources.session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        open()
    }

    public func stop() {
        stopped = true
        isOpen = false
        retry?.cancel()
        retry = nil
        heartbeat?.cancel()
        heartbeat = nil
        resources.teardown()
    }

    public func send(_ msg: ClientMsg) -> Bool {
        guard isOpen, let t = task else { return false }
        t.send(.string(msg.jsonString())) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return }
                self.onSendFailed?(msg)
                self.dropped(t, code: Self.code(t))
            }
        }
        return true
    }

    public func checkAlive() {
        guard !stopped else { return }
        if isOpen, let t = task {
            ping(t, deadline: min(5, pingTimeout))
        } else if task == nil {
            // Waiting out a backoff: try now.
            retry?.cancel()
            retry = nil
            open()
        }
    }

    // MARK: lifecycle

    private func open() {
        guard !stopped, let session else { return }
        onEvent?(.connecting)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        resources.task = t
        isOpen = false
        outstandingPing = nil
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, self.task === t else { return }
                switch result {
                case .success(let message):
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: text = ""
                    }
                    if !self.isOpen { self.becameLive(t) }
                    if let msg = ServerMsg.parse(text) { self.onMessage?(msg) }
                    self.receive(on: t)
                case .failure:
                    // A close frame (1008) can race the receive failure. When no close code is known
                    // yet, let the delegate's close or completion callback decide, with a fallback.
                    if t.closeCode != .invalid {
                        self.dropped(t, code: t.closeCode)
                    } else {
                        Task { [weak self] in
                            try? await Task.sleep(for: .seconds(1))
                            self?.dropped(t, code: t.closeCode)
                        }
                    }
                }
            }
        }
    }

    /// The first server message on a connection: only now is it live. Backoff resets here, so a
    /// server that accepts and drops without speaking is not hammered every 0.5 s.
    private func becameLive(_ t: URLSessionWebSocketTask) {
        attempt = 0
        isOpen = true
        onEvent?(.open)
        heartbeat?.cancel()
        let interval = heartbeatInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                self.tick(t)
            }
        }
    }

    private func tick(_ t: URLSessionWebSocketTask) {
        guard task === t, isOpen else { return }
        if let o = outstandingPing {
            if Date().timeIntervalSince(o.sentAt) >= pingTimeout { dropped(t, code: .abnormalClosure) }
            return
        }
        ping(t, deadline: nil)
    }

    private func ping(_ t: URLSessionWebSocketTask, deadline: TimeInterval?) {
        pingSeq += 1
        let seq = pingSeq
        outstandingPing = (seq, Date())
        t.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.task === t else { return }
                if error != nil {
                    self.dropped(t, code: Self.code(t))
                } else if self.outstandingPing?.seq == seq {
                    self.outstandingPing = nil
                }
            }
        }
        if let deadline {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(deadline))
                guard let self, self.task === t, self.outstandingPing?.seq == seq else { return }
                self.dropped(t, code: .abnormalClosure)
            }
        }
    }

    private static func code(_ t: URLSessionWebSocketTask) -> URLSessionWebSocketTask.CloseCode {
        t.closeCode == .invalid ? .abnormalClosure : t.closeCode
    }

    fileprivate func didOpen(_ t: URLSessionWebSocketTask) {
        // Handshake done. `.open` waits for the server's first message (see becameLive).
    }

    fileprivate func dropped(_ t: URLSessionWebSocketTask, code: URLSessionWebSocketTask.CloseCode) {
        guard task === t, !stopped else { return }
        isOpen = false
        resources.task = nil
        heartbeat?.cancel()
        heartbeat = nil
        outstandingPing = nil
        t.cancel()
        if code == .policyViolation {
            stopped = true
            retry?.cancel()
            resources.teardown()
            onEvent?(.refused)
            return
        }
        let delay = Self.backoff(attempt: attempt)
        attempt += 1
        onEvent?(.closed(retryIn: delay))
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.open()
        }
    }
}

/// The session and task, reachable from `deinit` (nonisolated) to close the connection.
private final class SocketResources: @unchecked Sendable {
    private let lock = NSLock()
    private var _session: URLSession?
    private var _task: URLSessionWebSocketTask?

    var session: URLSession? {
        get { lock.withLock { _session } }
        set { lock.withLock { _session = newValue } }
    }

    var task: URLSessionWebSocketTask? {
        get { lock.withLock { _task } }
        set { lock.withLock { _task = newValue } }
    }

    func teardown() {
        let (s, t) = lock.withLock { () -> (URLSession?, URLSessionWebSocketTask?) in
            defer { _session = nil; _task = nil }
            return (_session, _task)
        }
        t?.cancel(with: .goingAway, reason: nil)
        s?.invalidateAndCancel()
    }
}

/// URLSession delegate. Its queue is `.main`, so it hops straight onto the main actor.
private final class SocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    weak var owner: RunSocket?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated { owner?.didOpen(webSocketTask) }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated { owner?.dropped(webSocketTask, code: closeCode) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let ws = task as? URLSessionWebSocketTask else { return }
        MainActor.assumeIsolated { owner?.dropped(ws, code: ws.closeCode) }
    }
}
