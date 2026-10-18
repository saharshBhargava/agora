import Foundation

/// Shared Agora API client. Identity comes from native Google Sign-In (ID token);
/// Google access/refresh tokens never leave the device for these calls.
@MainActor
final class AgoraClient {
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

    /// Release builds require HTTPS. DEBUG also allows plain HTTP to loopback, `*.local`, and private LAN IPs (Plan B laptop demo).
    static func validOrigin(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        #if DEBUG
        guard scheme == "http" else { return false }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") { return true }
        return OpenAICompatibleClient.isAllowedPrivateAddress(name)
        #else
        return false
        #endif
    }

    /// Typed JSON (`Decodable`, snake_case). Preferred for inventory and similar list/detail routes.
    func fetch<Value: Decodable>(
        _ path: String,
        as type: Value.Type,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Value {
        let data = try await perform(path, method: method, body: body, key: key, query: query)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid timestamp"))
        }
        return try decoder.decode(type, from: data)
    }

    /// Requests whose successful response has no JSON body (for example, DELETE feedback).
    func send(_ path: String, method: String) async throws {
        _ = try await perform(path, method: method, body: nil, key: nil, query: [])
    }

    /// JSON object responses (`{...}`).
    func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil
    ) async throws -> [String: Any] {
        let value = try await requestJSON(path, method: method, body: body, key: key)
        guard let object = value as? [String: Any] else { throw BrowserError("invalid_server_response") }
        return object
    }

    /// Any JSON value (object or array). Use for untyped list endpoints.
    func requestJSON(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil
    ) async throws -> Any {
        let data = try await perform(path, method: method, body: body, key: key)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw BrowserError("invalid_server_response")
        }
        return json
    }

    /// Only same-origin, application-owned image paths can receive the account credential.
    func imageData(_ path: String) async throws -> Data {
        let parts = path.split(separator: "/")
        guard parts.count == 4, parts[0] == "v1", parts[1] == "item-images", parts[2] == "assets",
              UUID(uuidString: String(parts[3])) != nil else { throw BrowserError("invalid_image_path") }
        let data = try await perform(path, method: "GET", body: nil, key: nil)
        guard data.count <= 500_000 else { throw BrowserError("invalid_image") }
        return data
    }

    private func perform(
        _ path: String,
        method: String,
        body: [String: Any]?,
        key: String?,
        query: [URLQueryItem] = []
    ) async throws -> Data {
        guard isConfigured, let baseURL else {
            throw BrowserError(
                "agora_not_configured",
                "Inventory isn’t connected to a backend. This app needs a valid HTTPS household API address configured before inventory can load or save."
            )
        }
        guard calendar.connected, let accountID = calendar.accountID else {
            throw BrowserError("sign_in_required", "Sign in to continue.")
        }
        let token = try await calendar.apiToken(for: accountID)
        try Task.checkCancellation()
        guard calendar.accountID == accountID, calendar.connected else {
            throw BrowserError("account_changed", "Your account changed. Please try again.")
        }

        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        // Form-style query parsers otherwise interpret literal '+' characters as spaces.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw BrowserError("invalid_request") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch {
            try Task.checkCancellation()
            throw BrowserError("connection_failed", "Could not reach your household. Check your connection and try again.")
        }
        try Task.checkCancellation()
        guard calendar.accountID == accountID, calendar.connected else {
            throw BrowserError("account_changed", "Your account changed. Please try again.")
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrowserError("invalid_server_response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Do not sign the user out of Google when the Agora API rejects a call.
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = object?["title"] as? String ?? "agora_unavailable"
            let detail = object?["detail"] as? String ?? "Couldn’t reach your household. Please try again later."
            throw BrowserError(code, detail, status: httpResponse.statusCode)
        }
        return data
    }
}
