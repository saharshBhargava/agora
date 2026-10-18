import Foundation

/// Inventory uses an optional Agora server. Google access/refresh tokens never go to that server.
@MainActor
final class AgoraAPIClient {
    private let calendar: CalendarConnection
    private let baseURL: URL?
    private let http: URLSession
    var isConfigured: Bool { Self.validOrigin(baseURL) }

    init(calendar: CalendarConnection, baseURL: URL? = nil, http: URLSession? = nil) {
        self.calendar = calendar
        self.baseURL = baseURL ?? (Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String).flatMap(URL.init(string:))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.http = http ?? URLSession(configuration: config, delegate: NoCredentialRedirect(), delegateQueue: nil)
    }
    private static func validOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    func fetch<Value: Decodable>(_ path: String, as type: Value.Type) async throws -> Value {
        guard isConfigured, let baseURL else {
            throw BrowserError("inventory_not_configured", "Inventory sync isn’t available in this build yet. Calendar and chat are ready to use.")
        }
        guard calendar.connected, let accountID = calendar.accountID else { throw BrowserError("inventory_sign_in_required") }
        // The SDK's Google ID token authenticates identity; Calendar's access token is not used here.
        let token = try await calendar.authorization.idToken(for: accountID)
        try Task.checkCancellation()
        guard calendar.accountID == accountID, calendar.connected else { throw BrowserError("inventory_account_changed") }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard calendar.accountID == accountID, calendar.connected else { throw BrowserError("inventory_account_changed") }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            // A server configuration/auth failure must not sign the user out of Google Calendar.
            throw BrowserError("inventory_unavailable", "Couldn’t load inventory. Please try again later.")
        }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}
