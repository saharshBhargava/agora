import Foundation

/// Process-wide QFC traffic state: QFC (Akamai) rate-limits by IP, so every price worker and
/// browser in the app shares one backoff. Also remembers that the home page was loaded this launch.
@MainActor
final class QFCTraffic {
    static let shared = QFCTraffic()

    /// Pause lengths for the first, second and later rate limits in a row.
    let pauses: [Duration]
    private(set) var pausedUntil: ContinuousClock.Instant?
    private(set) var lastPause: Duration?
    private var level = 0
    /// The home page has been warmed this launch (at most once).
    var homeWarmed = false

    init(pauses: [Duration] = [.seconds(60), .seconds(120), .seconds(240)]) {
        self.pauses = pauses.isEmpty ? [.seconds(60)] : pauses
    }

    var isPaused: Bool { pausedUntil.map { ContinuousClock.now < $0 } ?? false }

    /// Starts a pause (60 s, then 120 s, then 240 s). A hit during a pause is the same episode.
    func rateLimited() {
        guard !isPaused else { return }
        let pause = pauses[min(level, pauses.count - 1)]
        level += 1
        lastPause = pause
        pausedUntil = .now + pause
        PriceLog.event("price qfc rate-limited; pausing \(Self.seconds(pause)) s")
    }

    /// A results page came back: the next rate limit starts the ladder again.
    func pageOK() { level = 0 }

    /// The page is QFC's rate-limit answer: "Too many requests" (Akamai JSON body), or a main-frame
    /// HTTP 429, or a 403 with an Akamai reference.
    static func isRateLimited(_ observation: [String: Any]) -> Bool {
        let text = (observation["text"] as? String ?? "").lowercased()
        if text.contains("too many requests") { return true }
        switch observation["httpStatus"] as? Int {
        case 429: return true
        case 403: return text.contains("reference") || text.contains("access denied")
        default: return false
        }
    }

    static func seconds(_ d: Duration) -> String {
        let ms = d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
        return ms % 1000 == 0 ? "\(ms / 1000)" : String(format: "%.1f", Double(ms) / 1000)
    }
}
