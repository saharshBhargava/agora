import Foundation

// Pure routing logic: which screen to show, and what a join link says. No UIKit, so it is unit tested.

/// This phone's seat in one run.
public struct RunRef: Hashable, Sendable {
    public let runId: String
    public let personId: String

    public init(runId: String, personId: String) {
        self.runId = runId
        self.personId = personId
    }
}

/// Every screen above Home. Pushed on the app's `NavigationStack`.
public enum Route: Hashable, Sendable {
    /// The shopper's invite screen (share link, QR, who has joined).
    case start(RunRef)
    /// Joining a run with a card hold. `decline` uses the declined test card (`&decline=1` on the link).
    case join(runId: String, decline: Bool)
    /// A claimer's live screen.
    case claim(RunRef)
    /// The shopper's camera and cart.
    case shopper(RunRef)
    /// A run that has settled or partly settled (Task 8's settle screen).
    case settle(RunRef)
}

/// A link to join a run: `dibs://join?run=<id>` or `https://<server>/join?run=<id>`.
public struct JoinLink: Equatable, Sendable {
    public let runId: String
    /// The server the link points at, for http(s) links; nil for `dibs://` links.
    public let server: URL?
    public let decline: Bool

    public init(runId: String, server: URL? = nil, decline: Bool = false) {
        self.runId = runId
        self.server = server
        self.decline = decline
    }

    /// The link in pasted or opened text, or nil when it is not a Dibs join link.
    public static func parse(_ text: String) -> JoinLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: trimmed), let scheme = comps.scheme?.lowercased() else { return nil }
        let items = comps.queryItems ?? []
        guard let runId = items.first(where: { $0.name == "run" })?.value, isRunId(runId) else { return nil }
        let decline = items.first(where: { $0.name == "decline" })?.value == "1"

        switch scheme {
        case "dibs":
            guard comps.host?.lowercased() == "join", comps.path.isEmpty || comps.path == "/" else { return nil }
            return JoinLink(runId: runId, server: nil, decline: decline)
        case "http", "https":
            var path = comps.path
            while path.hasSuffix("/") { path.removeLast() }
            guard path == "/join" || path.hasSuffix("/join") else { return nil }
            var base = URLComponents()
            base.scheme = scheme
            base.host = comps.host
            base.port = comps.port
            base.path = String(path.dropLast("/join".count))
            guard let baseText = base.string, let server = ServerConfig.validate(baseText) else { return nil }
            return JoinLink(runId: runId, server: server, decline: decline)
        default:
            return nil
        }
    }

    /// Server run ids are UUIDs; accept any short id of letters, digits, "-" and "_".
    static func isRunId(_ s: String) -> Bool {
        guard (1...128).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }
}

/// What Home does at launch: resume the last run this phone was in, unless it is settled.
public enum HomeRouting {
    public static let lastRunKey = "dibs.lastRun"

    public static func saveLastRun(_ runId: String, defaults: UserDefaults = .standard) {
        defaults.set(runId, forKey: lastRunKey)
    }

    public static func clearLastRun(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: lastRunKey)
    }

    /// The last run and this phone's person in it, when both are saved along with the person's key
    /// (a run saved before the server handed out keys can't be acted in, so it is not resumed).
    public static func savedRun(defaults: UserDefaults = .standard) -> RunRef? {
        guard let runId = defaults.string(forKey: lastRunKey),
              let personId = ServerConfig.personId(runId: runId, defaults: defaults),
              RunKeys(defaults: defaults).key(runId: runId) != nil else { return nil }
        return RunRef(runId: runId, personId: personId)
    }

    /// Where a person lands in a run they are already part of; nil when they are not in it.
    /// Settled and partly settled runs go to Settle. The shopper goes back to the invite screen until
    /// the first item lands, then to the cart.
    public static func route(for run: Run, personId: String) -> Route? {
        guard let me = run.person(personId) else { return nil }
        let ref = RunRef(runId: run.id, personId: personId)
        if run.state == .settled || run.state == .partlySettled { return .settle(ref) }
        guard me.isShopper else { return .claim(ref) }
        return run.state == .open && run.chips.isEmpty ? .start(ref) : .shopper(ref)
    }

    /// Fetches the run and decides; nil (stay on Home) when it cannot be fetched.
    public static func resume(_ ref: RunRef, fetch: @Sendable (String) async throws -> Run) async -> Route? {
        guard let run = try? await fetch(ref.runId), run.id == ref.runId else { return nil }
        return route(for: run, personId: ref.personId)
    }

    /// The screen to open at launch, or nil for Home. Fetches only when a person is saved for the last
    /// run. A settled last run is not resumed, and is forgotten as the last run.
    @MainActor
    public static func launchRoute(defaults: UserDefaults = .standard, fetch: @Sendable (String) async throws -> Run) async -> Route? {
        guard let ref = savedRun(defaults: defaults),
              let run = try? await fetch(ref.runId), run.id == ref.runId else { return nil }
        if run.state == .settled {
            clearLastRun(defaults: defaults)
            return nil
        }
        return route(for: run, personId: ref.personId)
    }
}
