import Foundation
import CoreFoundation

// Ported from Agora/Browser/BrowserPolicy.swift and BrowserToolExecutor.swift. The worker runs
// unattended, so actions that needed a person's approval there are refused here.

struct BrowserError: LocalizedError {
    let code: String
    let detail: String
    init(_ code: String, _ detail: String = "") {
        self.code = code; self.detail = detail
    }
    var errorDescription: String? { detail.isEmpty ? code : "\(code): \(detail)" }
}

struct BrowserPolicy {
    /// Registrable domains the main frame may visit (empty allows any public HTTPS host).
    var allowedDomains: [String] = []

    func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.contains("."), !host.contains(":"),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              !["localhost", "local", "internal", "test"].contains(host.components(separatedBy: ".").last ?? "")
        else { throw BrowserError("blocked_destination", "Use a public HTTPS website on the default port, without embedded credentials.") }
        guard allowedDomains.isEmpty || allowedDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw BrowserError("blocked_destination", "Stay on \(allowedDomains.joined(separator: ", ")).")
        }
    }

    /// The store's domain for a search URL: www.qfc.com -> qfc.com.
    static func domain(of url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let parts = host.split(separator: ".")
        return parts.count >= 2 ? parts.suffix(2).joined(separator: ".") : host
    }

    static func safeURL(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string ?? ""
    }
}

struct BrowserCall {
    let name: String
    let arguments: [String: Any]

    init(name: String, arguments: [String: Any]) throws {
        self.name = name; self.arguments = arguments
        try Self.validate(name: name, arguments: arguments)
    }

    static let fields: [String: Set<String>] = [
        "browser_open": ["url"], "browser_observe": [], "browser_find": ["text"],
        "browser_wait_for": ["text", "absent", "seconds"],
        "browser_act": ["action", "documentId", "observationId", "elementId", "text", "direction"],
        "browser_screenshot": [], "browser_close": []
    ]
    static let actions: Set<String> = ["click", "type", "clear", "select", "check", "uncheck", "focus", "scroll", "back", "forward", "reload"]
    /// What the team agent ran without asking (click, type, scroll) plus history moves.
    static let unattendedActions: Set<String> = ["click", "type", "scroll", "back", "forward", "reload"]

    static func validate(name: String, arguments: [String: Any]) throws {
        guard let allowed = fields[name], Set(arguments.keys).isSubset(of: allowed) else { throw BrowserError("invalid_arguments", "Unknown tool or field.") }
        for (key, value) in arguments {
            if key == "seconds" {
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, (0.25...20).contains(number.doubleValue) else { throw BrowserError("invalid_arguments") }
            } else if key == "absent" {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw BrowserError("invalid_arguments") }
            } else { guard let text = value as? String, text.utf8.count <= 4000 else { throw BrowserError("invalid_arguments") } }
        }
        let required: [String]
        switch name {
        case "browser_open": required = ["url"]
        case "browser_find", "browser_wait_for": required = ["text"]
        case "browser_act":
            guard let action = arguments["action"] as? String, actions.contains(action) else { throw BrowserError("unsupported_action") }
            required = ["action"] + (["back", "forward", "reload"].contains(action) ? [] : ["documentId", "observationId"] + (action == "scroll" ? [] : ["elementId"])) + (["type", "select"].contains(action) ? ["text"] : [])
            if let direction = arguments["direction"] as? String, !["up", "down"].contains(direction) { throw BrowserError("invalid_arguments") }
        default: required = []
        }
        let missing = required.filter { !(arguments[$0] is String) }
        guard missing.isEmpty else {
            throw BrowserError("invalid_arguments", "Required field missing: \(missing.joined(separator: ", ")). Use documentId and observationId from the latest observation.")
        }
    }
}

/// Runs the server's browser tool calls against a StoreBrowser.
@MainActor
final class BrowserToolExecutor: PriceBrowsing {
    let session: StoreBrowser
    private var executing = false

    init(session: StoreBrowser) { self.session = session }

    func restrict(to url: URL) {
        session.policy.allowedDomains = BrowserPolicy.domain(of: url).map { [$0] } ?? []
    }

    func close() { session.close() }

    func run(tool name: String, args: [String: Any]) async throws -> [String: Any] {
        try await execute(BrowserCall(name: name, arguments: args))
    }

    func execute(_ call: BrowserCall) async throws -> [String: Any] {
        guard !executing else { throw BrowserError("executor_busy") }
        executing = true; defer { executing = false }
        let epoch = session.epoch
        let a = call.arguments
        var result: [String: Any]
        switch call.name {
        case "browser_open":
            guard let url = URL(string: a["url"] as! String) else { throw BrowserError("invalid_arguments") }
            result = try await session.open(url)
        case "browser_observe":
            result = try await session.observe()
        case "browser_find":
            let observation = try await session.observe(), text = a["text"] as! String
            result = observation
            result["elements"] = (observation["elements"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(text) }
            result["found"] = (observation["text"] as? String ?? "").localizedCaseInsensitiveContains(text)
        case "browser_wait_for":
            let seconds = (a["seconds"] as? NSNumber)?.doubleValue ?? 10
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
            let text = a["text"] as! String, absent = (a["absent"] as? NSNumber)?.boolValue ?? false
            while true {
                try Task.checkCancellation()
                guard session.epoch == epoch else { throw BrowserError("stale_session") }
                do {
                    let observation = try await session.observe()
                    let found = (observation["text"] as? String ?? "").localizedCaseInsensitiveContains(text)
                    if found != absent { result = observation; break }
                } catch let error as BrowserError where error.code.contains("stale_reference") || error.code == "timeout" {
                    // The page is still navigating or busy: keep waiting.
                }
                if ContinuousClock.now >= deadline { throw BrowserError("timeout") }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "browser_act":
            guard !session.privateMode else { throw BrowserError("user_action_required") }
            let action = a["action"] as! String
            guard BrowserCall.unattendedActions.contains(action) else {
                throw BrowserError("unsupported_action", "Only click, type, scroll, back, forward and reload are available.")
            }
            switch action {
            case "back":
                guard session.webView.canGoBack else { throw BrowserError("unsupported_action") }
                session.webView.goBack()
                result = ["dispatched": true, "note": "Navigation dispatched. Wait for or observe the resulting page."]
            case "forward":
                guard session.webView.canGoForward else { throw BrowserError("unsupported_action") }
                session.webView.goForward()
                result = ["dispatched": true, "note": "Navigation dispatched. Wait for or observe the resulting page."]
            case "reload":
                session.webView.reload()
                result = ["dispatched": true, "note": "Navigation dispatched. Wait for or observe the resulting page."]
            default:
                result = try await session.bridge(a.merging(["operation": "act"]) { _, new in new }, mutation: true)
            }
        case "browser_screenshot":
            throw BrowserError("unsupported_action", "Screenshots are not available. Use browser_observe.")
        case "browser_close":
            session.close()
            return ["closed": true]
        default:
            throw BrowserError("unsupported_action")
        }
        guard session.epoch == epoch else { throw BrowserError("stale_session") }
        return result
    }
}
