import Foundation
import Security

/// Shared Agora API session: Keychain bearer token + HTTPS JSON requests.
/// Feature modules (calendar, scans, inventory) should use this instead of owning their own auth HTTP.
@MainActor
final class AgoraClient: ObservableObject {
    struct Account: Codable {
        let token: String
        let email: String
        let userID: String
        let expiresAt: String
    }

    @Published private(set) var signedIn = false
    @Published private(set) var email: String?
    /// Set when Keychain session data exists but cannot be read/decoded.
    private(set) var sessionLoadError: String?
    private let baseURL: URL?
    private let http: URLSession
    private let service: String
    private var account: Account?

    init(baseURL: URL? = nil, http: URLSession? = nil, service: String = "app.agora.account") {
        self.baseURL = baseURL ?? (Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String).flatMap(URL.init(string:))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.http = http ?? URLSession(configuration: config, delegate: AgoraNoRedirect(), delegateQueue: nil)
        self.service = service
        do {
            account = try readAccount()
            email = account?.email
            signedIn = account != nil
        } catch {
            account = nil
            email = nil
            signedIn = false
            sessionLoadError = "Could not read your saved sign-in. Please reconnect."
        }
    }

    var hasSession: Bool { account != nil }

    func save(_ account: Account) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: try JSONEncoder().encode(account),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess, try readAccount()?.token == account.token else {
            throw BrowserError("account_keychain_error", "Could not securely save your sign-in. Please try again.")
        }
        self.account = account
        email = account.email
        signedIn = true
    }

    func clear() {
        SecItemDelete(query as CFDictionary)
        account = nil
        email = nil
        signedIn = false
    }

    /// JSON object responses (`{...}`). Prefer this for most `/v1` routes.
    func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil,
        authenticated: Bool = true
    ) async throws -> [String: Any] {
        let value = try await requestJSON(path, method: method, body: body, key: key, authenticated: authenticated)
        guard let object = value as? [String: Any] else { throw BrowserError("invalid_server_response") }
        return object
    }

    /// Any JSON value (object or array). Use for list endpoints like `/v1/inventory`.
    func requestJSON(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil,
        authenticated: Bool = true
    ) async throws -> Any {
        guard let baseURL, baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw BrowserError("service_unavailable", "Agora is unavailable in this build. Please try again later.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if authenticated {
            guard let account else { throw BrowserError("sign_in_required", "Sign in to continue.") }
            request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        }
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
            throw BrowserError("connection_failed", "Could not reach Agora. Check your connection and try again.")
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw BrowserError("invalid_server_response") }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard (200..<300).contains(httpResponse.statusCode) else {
            let object = json as? [String: Any]
            let code = object?["title"] as? String ?? "request_failed"
            let detail = object?["detail"] as? String ?? "Request failed. Please try again."
            if httpResponse.statusCode == 401 && authenticated { clear() }
            throw BrowserError(code, detail, status: httpResponse.statusCode)
        }
        guard let json else { throw BrowserError("invalid_server_response") }
        return json
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }

    private func readAccount() throws -> Account? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw BrowserError("account_keychain_error") }
        return try JSONDecoder().decode(Account.self, from: data)
    }
}

private final class AgoraNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
