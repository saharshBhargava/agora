import Foundation

/// Where the Dibs server lives, and which person this phone is in each run.
///
/// The URL comes from `DIBS_SERVER_URL` in Info.plist (set in ios/Local.xcconfig), overridden by the
/// in-app settings sheet, which saves to `UserDefaults` key `dibs.server`. HTTPS only, except plain
/// http to localhost and 127.0.0.1 for the simulator.
public enum ServerConfig {
    public static let serverKey = "dibs.server"
    public static let infoPlistKey = "DIBS_SERVER_URL"
    public static let fallback = URL(string: "http://localhost:3000")!

    /// A usable server base URL from user text, or nil. Trailing slashes are dropped; no query or fragment.
    public static func validate(_ text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let comps = URLComponents(string: s), let scheme = comps.scheme?.lowercased(),
              let host = comps.host?.lowercased(), !host.isEmpty,
              comps.query == nil, comps.fragment == nil, comps.user == nil else { return nil }
        switch scheme {
        case "https": break
        case "http": guard host == "localhost" || host == "127.0.0.1" else { return nil }
        default: return nil
        }
        return comps.url
    }

    /// The URL baked into the build, when it is valid.
    public static func bundled(_ bundle: Bundle = .main) -> URL? {
        (bundle.object(forInfoDictionaryKey: infoPlistKey) as? String).flatMap(validate)
    }

    /// The saved override, else the bundled URL, else localhost.
    public static func current(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> URL {
        if let saved = defaults.string(forKey: serverKey), let url = validate(saved) { return url }
        return bundled(bundle) ?? fallback
    }

    /// Saves an override. Returns false (and saves nothing) when the text is not a usable URL.
    @discardableResult
    public static func save(_ text: String, defaults: UserDefaults = .standard) -> Bool {
        guard let url = validate(text) else { return false }
        defaults.set(url.absoluteString, forKey: serverKey)
        return true
    }

    /// Clears the override, so the bundled URL applies again.
    public static func reset(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: serverKey)
    }

    // MARK: per-run identity

    public static func personKey(runId: String) -> String { "dibs.person.\(runId)" }

    public static func personId(runId: String, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: personKey(runId: runId))
    }

    public static func savePersonId(_ personId: String, runId: String, defaults: UserDefaults = .standard) {
        defaults.set(personId, forKey: personKey(runId: runId))
    }
}
