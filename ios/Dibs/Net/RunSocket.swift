import Foundation

/// Connection lifecycle events a run socket reports.
public enum SocketEvent: Sendable, Equatable {
    case connecting
    /// The socket is open. The server pushes a `{t:'run'}` snapshot right after.
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
    func start()
    func stop()
    /// Sends when the socket is open. Returns false (and sends nothing) otherwise.
    func send(_ msg: ClientMsg) -> Bool
}

/// The live run socket: `<base as ws/wss>/ws?run=&person=`, reconnecting with backoff
/// 0.5, 1, 2, 4, 8 s (capped at 8) and stopping for good on close code 1008.
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
    public private(set) var isOpen = false

    private let url: URL
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var retry: Task<Void, Never>?
    private var attempt = 0
    private var stopped = true
    private let delegate = SocketDelegate()

    public init(base: URL, runId: String, personId: String) {
        url = Self.url(base: base, runId: runId, personId: personId)
        delegate.owner = self
    }

    public func start() {
        guard stopped else { return }
        stopped = false
        attempt = 0
        // Delegate callbacks and receive completions all arrive on the main queue, in order.
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: .main)
        open()
    }

    public func stop() {
        stopped = true
        isOpen = false
        retry?.cancel()
        retry = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    public func send(_ msg: ClientMsg) -> Bool {
        guard isOpen, let task else { return false }
        task.send(.string(msg.jsonString())) { _ in }
        return true
    }

    // MARK: lifecycle

    private func open() {
        guard !stopped, let session else { return }
        onEvent?(.connecting)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
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

    fileprivate func didOpen(_ t: URLSessionWebSocketTask) {
        guard task === t, !stopped else { return }
        attempt = 0
        isOpen = true
        onEvent?(.open)
    }

    fileprivate func dropped(_ t: URLSessionWebSocketTask, code: URLSessionWebSocketTask.CloseCode) {
        guard task === t, !stopped else { return }
        isOpen = false
        task = nil
        t.cancel()
        if code == .policyViolation {
            stopped = true
            retry?.cancel()
            session?.invalidateAndCancel()
            session = nil
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
