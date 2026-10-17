import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

@MainActor
final class CalendarConnection: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var connected = false
    @Published private(set) var checking = true
    @Published private(set) var connecting = false
    @Published private(set) var email: String?
    @Published var message: String?
    private var authentication: ASWebAuthenticationSession?
    private let baseURL: URL?
    private let http: URLSession
    private let service: String
    private var account: Account?

    struct Account: Codable {
        let token: String
        let email: String
        let userID: String
        let expiresAt: String
    }
    init(baseURL: URL? = nil, http: URLSession? = nil, service: String = "app.agora.account") {
        self.baseURL = baseURL ?? (Bundle.main.object(forInfoDictionaryKey: "AgoraAPIBaseURL") as? String).flatMap(URL.init(string:))
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.http = http ?? URLSession(configuration: config, delegate: CalendarNoRedirect(), delegateQueue: nil)
        self.service = service
        super.init()
        do {
            account = try readAccount()
            email = account?.email
        } catch { message = "Could not read your saved sign-in. Please reconnect." }
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"]
    }
    private func readAccount() throws -> Account? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw BrowserError("account_keychain_error") }
        return try JSONDecoder().decode(Account.self, from: data)
    }
    private func save(_ account: Account) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess, try readAccount()?.token == account.token else {
            throw BrowserError("account_keychain_error", "Could not securely save your sign-in. Please try again.")
        }
        self.account = account; email = account.email
    }
    private func clear() {
        SecItemDelete(query as CFDictionary)
        account = nil; email = nil; connected = false
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, key: String? = nil, authenticated: Bool = true) async throws -> [String: Any] {
        guard let baseURL, baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil else {
            throw BrowserError("service_unavailable", "Calendar connection is unavailable in this build. Please try again later.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if authenticated {
            guard let account else { throw BrowserError("calendar_reconnect_required", "Connect Google Calendar to continue.") }
            request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch {
            if path == "v1/calendar/events" { throw BrowserError("outcome_unknown", "Check Google Calendar before retrying; event creation could not be confirmed.") }
            throw BrowserError("connection_failed", "Could not reach Agora. Check your connection and try again.")
        }
        guard let httpResponse = response as? HTTPURLResponse else { throw BrowserError("invalid_server_response") }
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrowserError(path == "v1/calendar/events" ? "outcome_unknown" : "invalid_server_response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let code = path == "v1/calendar/events" && httpResponse.statusCode >= 500 ? "outcome_unknown" : (result["title"] as? String ?? "calendar_request_failed")
            if httpResponse.statusCode == 401 && authenticated { clear() }
            if ["calendar_reconnect_required", "calendar_access_denied"].contains(code) {
                message = "Reconnect Google Calendar to continue."; connected = false
            }
            throw BrowserError(code, result["detail"] as? String ?? "Calendar request failed. Please try again.")
        }
        return result
    }
    func refresh() async {
        guard !connecting else { return }
        defer { checking = false }
        guard account != nil else { connected = false; return }
        do {
            let status = try await request("v1/integrations/google")
            connected = status["connected"] as? Bool == true
            email = status["email"] as? String
            message = connected ? nil : "Reconnect Google Calendar to continue."
        } catch { message = error.localizedDescription }
    }
    func connect() async {
        guard !connecting else { return }
        connecting = true; message = nil
        defer { connecting = false; authentication = nil; checking = false }
        do {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw BrowserError("sign_in_failed") }
            let verifier = Self.base64URL(Data(random))
            let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
            let started = try await request("v1/integrations/google/start", method: "POST", body: ["code_challenge": challenge], authenticated: account != nil)
            guard let state = started["state"] as? String, let address = started["authorization_url"] as? String,
                  let url = URL(string: address), url.scheme == "https", url.host == "accounts.google.com" else { throw BrowserError("invalid_sign_in_response") }
            let callback = try await authenticate(url)
            let code = try Self.authorizationCode(callback: callback, expectedState: state)
            let result = try await request("v1/integrations/google/exchange", method: "POST", body: ["state": state, "code": code, "code_verifier": verifier], authenticated: false)
            guard let token = result["access_token"] as? String, let email = result["email"] as? String,
                  let user = result["user_id"] as? String, let expires = result["expires_at"] as? String else { throw BrowserError("invalid_sign_in_response") }
            try save(Account(token: token, email: email, userID: user, expiresAt: expires))
            connected = true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            message = "Connect Google Calendar to finish setting up Agora."
        } catch { message = error.localizedDescription }
    }
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func authorizationCode(callback: URL, expectedState: String) throws -> String {
        guard callback.scheme == "dev.agora.browserchat", callback.host == "google-callback",
              let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false) else { throw BrowserError("invalid_oauth_callback") }
        let items = parts.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == expectedState else { throw BrowserError("invalid_oauth_state") }
        if items.contains(where: { $0.name == "error" }) { throw BrowserError("calendar_permission_required", "Approve Google Calendar access to finish onboarding.") }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw BrowserError("invalid_oauth_callback") }
        return code
    }
    private func authenticate(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "dev.agora.browserchat") { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url) }
                else { continuation.resume(throwing: BrowserError("sign_in_failed")) }
            }
            session.presentationContextProvider = self
            // Use the system Google session to minimize repeated sign-in prompts.
            session.prefersEphemeralWebBrowserSession = false
            authentication = session
            if !session.start() { continuation.resume(throwing: BrowserError("sign_in_failed")) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func disconnect() async {
        connecting = true; defer { connecting = false }
        do { _ = try await request("v1/integrations/google", method: "DELETE"); clear(); message = nil }
        catch { message = error.localizedDescription }
    }
    func signOut() async {
        do { _ = try await request("v1/auth/logout", method: "POST"); clear(); message = nil }
        catch { message = error.localizedDescription }
    }
    func execute(_ call: CalendarCall, taskID: UUID) async throws -> [String: Any] {
        guard connected else { throw BrowserError("calendar_reconnect_required", "Reconnect Google Calendar in Settings.") }
        var body = call.arguments
        if call.name == "calendar_create_event" {
            body["confirmed"] = true // Set by the app only after the native approval completes.
            return try await request("v1/calendar/events", method: "POST", body: body, key: call.requestKey(taskID: taskID))
        }
        return try await request("v1/calendar/freebusy", method: "POST", body: body)
    }
}

private final class CalendarNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
