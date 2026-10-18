import Foundation

struct BrowserCall {
    let name: String
    let arguments: [String: Any]
    let id: String?
    init(_ raw: [String: Any]) throws {
        guard let name = raw["name"] as? String, var arguments = raw["args"] as? [String: Any] else { throw BrowserError("invalid_arguments") }
        // Models sometimes send reference ids as whole numbers ("elementId": 12); they mean the same id text.
        for key in ["documentId", "observationId", "elementId"] {
            if let number = arguments[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
               number.doubleValue.isFinite, number.doubleValue == number.doubleValue.rounded(), abs(number.doubleValue) < 1e15 {
                arguments[key] = String(number.int64Value)
            }
        }
        // Models often leave out the page reference on a click or typing action; use the latest observation's,
        // which the page script still checks (a stale or unknown element is refused there).
        if name == "browser_act", let action = arguments["action"] as? String,
           !["back", "forward", "reload"].contains(action), let last = Self.lastReference {
            if arguments["documentId"] == nil { arguments["documentId"] = last.documentId }
            if arguments["observationId"] == nil { arguments["observationId"] = last.observationId }
        }
        self.name = name; self.arguments = arguments; id = raw["id"] as? String
        do { try Self.validate(name: name, arguments: arguments) }
        catch {
            // Field names and value types only (no values), to see why a model's call was refused.
            let shape = arguments.keys.sorted().map { key -> String in
                let v = arguments[key]
                let type = v is String ? "string" : (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() ? "bool" : "number" } ?? String(describing: type(of: v as Any))
                return "\(key):\(type)"
            }.joined(separator: ",")
            NSLog("[browser] refused tool=%@ fields=%@ error=%@", name, shape, String(describing: error))
            throw error
        }
    }
    static let fields: [String: Set<String>] = [
        "browser_open": ["url"], "browser_observe": [], "browser_find": ["text"],
        "browser_wait_for": ["text", "absent", "seconds"],
        "browser_act": ["action", "documentId", "observationId", "elementId", "text", "direction"],
        "browser_screenshot": [], "browser_close": []
    ]
    /// The page reference from the most recent observation the browser returned (set by the executor).
    nonisolated(unsafe) static var lastReference: (documentId: String, observationId: String)?
    static let actions: Set<String> = ["click", "type", "clear", "select", "check", "uncheck", "focus", "scroll", "back", "forward", "reload"]
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
            throw BrowserError("invalid_arguments", "Required field missing: \(missing.joined(separator: ", ")). Use documentId and observationId from the latest browser_observe or browser_find result.")
        }
    }
    static var schemas: [[String: Any]] {
        let descriptions = ["browser_open": "Open an allowed HTTPS URL and observe.", "browser_observe": "Read fresh bounded page text and element references.", "browser_find": "Observe and find elements or text matching text.", "browser_wait_for": "Wait up to 20 seconds for text to be present (or absent).", "browser_act": "Act on current references. Actions: click, type, clear, select, check, uncheck, focus, scroll, back, forward, reload. Click, type, and scroll execute without an approval prompt. Other actions require user approval.", "browser_screenshot": "Capture only the browser, except on private pages.", "browser_close": "Close the browser only when explicitly requested by the user; requires confirmation."]
        return fields.keys.sorted().map { name in
            var properties: [String: Any] = [:]
            for field in fields[name]! {
                var property: [String: Any] = ["type": field == "seconds" ? "NUMBER" : field == "absent" ? "BOOLEAN" : "STRING"]
                if field == "action" { property["enum"] = actions.sorted() }
                if field == "direction" { property["enum"] = ["up", "down"] }
                properties[field] = property
            }
            let required = name == "browser_open" ? ["url"] : ["browser_find", "browser_wait_for"].contains(name) ? ["text"] : name == "browser_act" ? ["action"] : []
            return ["name": name, "description": descriptions[name]!, "parameters": ["type": "OBJECT", "properties": properties, "required": required]]
        }
    }
}

import CoreFoundation

@MainActor
final class BrowserToolExecutor {
    let session: BrowserSession
    private var executing = false
    init(session: BrowserSession) { self.session = session }
    func execute(_ call: BrowserCall) async throws -> [String: Any] {
        // Revalidate before logging a model-supplied operation name.
        try BrowserCall.validate(name: call.name, arguments: call.arguments)
        return try await AppLog.measure(.browser, call.name) { try await executeImpl(call) }
    }
    private func executeImpl(_ call: BrowserCall) async throws -> [String: Any] {
        // The coordinator is the sole FIFO consumer. Reject other callers across awaits.
        guard !executing, session.priceResearchID == nil else { throw BrowserError("executor_busy") }
        executing = true; defer { executing = false }
        let epoch = session.epoch, lease = session.lease
        try session.check(epoch: epoch, lease: lease)
        let a = call.arguments
        var result: [String: Any]
        switch call.name {
        case "browser_open":
            guard let url = URL(string: a["url"] as! String) else { throw BrowserError("invalid_arguments") }
            result = try await session.open(url)
        case "browser_observe": result = try await session.observe()
        case "browser_find":
            let observation = try await session.observe(), text = a["text"] as! String
            result = observation
            result["elements"] = (observation["elements"] as? [[String: Any]] ?? []).filter { ($0["name"] as? String ?? "").localizedCaseInsensitiveContains(text) }
            result["found"] = (observation["text"] as? String ?? "").localizedCaseInsensitiveContains(text)
        case "browser_wait_for":
            let deadline = ContinuousClock.now + .seconds(a["seconds"] as? Double ?? 10)
            while true {
                try session.check(epoch: epoch, lease: lease)
                let observation = try await session.observe()
                let found = (observation["text"] as? String ?? "").localizedCaseInsensitiveContains(a["text"] as! String)
                if found != (a["absent"] as? Bool ?? false) { result = observation; break }
                if ContinuousClock.now >= deadline { throw BrowserError("timeout") }
                try await Task.sleep(for: .milliseconds(250))
            }
        case "browser_act":
            guard !session.state.privateMode else { throw BrowserError("user_action_required") }
            let action = a["action"] as! String
            session.state.busy = true; defer { session.state.busy = false }
            if ["back", "forward", "reload"].contains(action) {
                switch action {
                case "back": guard session.webView.canGoBack else { throw BrowserError("unsupported_action") }; session.webView.goBack()
                case "forward": guard session.webView.canGoForward else { throw BrowserError("unsupported_action") }; session.webView.goForward()
                default: session.webView.reload()
                }
                result = ["dispatched": true, "note": "Navigation dispatched. Wait for or observe the resulting page."]
            } else { result = try await session.bridge(a.merging(["operation": "act"]) { _, new in new }, mutation: true) }
        case "browser_screenshot": result = try await session.screenshot()
        case "browser_close": session.close(); return ["closed": true]
        default: throw BrowserError("unsupported_action")
        }
        try session.check(epoch: epoch, lease: lease)
        if let document = result["documentId"] as? String, let observation = result["observationId"] as? String,
           !document.isEmpty, !observation.isEmpty {
            BrowserCall.lastReference = (document, observation)
        }
        return result
    }
}
