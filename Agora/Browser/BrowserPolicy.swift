import Foundation

struct BrowserError: LocalizedError {
    let code: String
    let detail: String
    init(_ code: String, _ detail: String = "") { self.code = code; self.detail = detail }
    var errorDescription: String? { detail.isEmpty ? code : "\(code): \(detail)" }
}

struct BrowserPolicy {
    func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.contains("."), !host.contains(":"),
              host.range(of: #"^[0-9.]+$"#, options: .regularExpression) == nil,
              !["localhost", "local", "internal", "test"].contains(host.components(separatedBy: ".").last ?? "")
        else { throw BrowserError("blocked_destination", "Use a public HTTPS website on the default port, without embedded credentials. Local hostnames and IP literals are not supported.") }
    }
    static func safeURL(_ url: URL?) -> String {
        guard let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return parts.string ?? ""
    }
}

enum BrowserPresentation { case thumbnail, expanded, hidden }
struct BrowserState {
    var isOpen = false
    var presentation: BrowserPresentation = .thumbnail
    var title = "Browser"
    var url: URL?
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var status = "Ready"
    var privateMode = false
    var busy = false
}
