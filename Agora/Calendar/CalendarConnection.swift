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
    let client: AgoraClient

    typealias Account = AgoraClient.Account

    init(client: AgoraClient) {
        self.client = client
        email = client.email
        message = client.sessionLoadError
        super.init()
    }

    /// Test helper — builds a dedicated `AgoraClient` with the given base URL / session / Keychain service.
    convenience init(baseURL: URL? = nil, http: URLSession? = nil, service: String = "app.agora.account") {
        self.init(client: AgoraClient(baseURL: baseURL, http: http, service: service))
    }

    private func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        key: String? = nil,
        authenticated: Bool = true
    ) async throws -> [String: Any] {
        do {
            if authenticated && !client.hasSession {
                throw BrowserError("calendar_reconnect_required", "Connect Google Calendar to continue.")
            }
            return try await client.request(path, method: method, body: body, key: key, authenticated: authenticated)
        } catch let error as BrowserError {
            if !client.signedIn {
                connected = false
                email = nil
            }
            if ["calendar_reconnect_required", "calendar_access_denied"].contains(error.code) {
                message = "Reconnect Google Calendar to continue."
                connected = false
            }
            if path == "v1/calendar/events" {
                if error.code == "connection_failed" || error.code == "invalid_server_response" {
                    throw BrowserError("outcome_unknown", "Check Google Calendar before retrying; event creation could not be confirmed.")
                }
                if let status = error.status, status >= 500 {
                    throw BrowserError("outcome_unknown", "Check Google Calendar before retrying; event creation could not be confirmed.", status: status)
                }
            }
            if error.code == "service_unavailable" {
                throw BrowserError("service_unavailable", "Calendar connection is unavailable in this build. Please try again later.")
            }
            if error.code == "sign_in_required" {
                throw BrowserError("calendar_reconnect_required", "Connect Google Calendar to continue.")
            }
            if error.code == "request_failed" {
                throw BrowserError("calendar_request_failed", error.detail.isEmpty ? "Calendar request failed. Please try again." : error.detail, status: error.status)
            }
            throw error
        }
    }

    func refresh() async {
        guard !connecting else { return }
        defer { checking = false }
        guard client.hasSession else { connected = false; email = nil; return }
        do {
            let status = try await request("v1/integrations/google")
            connected = status["connected"] as? Bool == true
            email = status["email"] as? String ?? client.email
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
            let started = try await request("v1/integrations/google/start", method: "POST", body: ["code_challenge": challenge], authenticated: client.hasSession)
            guard let state = started["state"] as? String, let address = started["authorization_url"] as? String,
                  let url = URL(string: address), url.scheme == "https", url.host == "accounts.google.com" else { throw BrowserError("invalid_sign_in_response") }
            let callback = try await authenticate(url)
            let code = try Self.authorizationCode(callback: callback, expectedState: state)
            let result = try await request("v1/integrations/google/exchange", method: "POST", body: ["state": state, "code": code, "code_verifier": verifier], authenticated: false)
            guard let token = result["access_token"] as? String, let email = result["email"] as? String,
                  let user = result["user_id"] as? String, let expires = result["expires_at"] as? String else { throw BrowserError("invalid_sign_in_response") }
            try client.save(Account(token: token, email: email, userID: user, expiresAt: expires))
            self.email = email
            connected = true
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            message = "Connect Google Calendar to finish setting up Agora."
        } catch let error as BrowserError where error.code == "account_keychain_error" {
            message = error.detail.isEmpty ? error.localizedDescription : error.detail
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
        do {
            _ = try await request("v1/integrations/google", method: "DELETE")
            client.clear()
            connected = false
            email = nil
            message = nil
        } catch { message = error.localizedDescription }
    }

    func signOut() async {
        do {
            _ = try await request("v1/auth/logout", method: "POST")
            client.clear()
            connected = false
            email = nil
            message = nil
        } catch { message = error.localizedDescription }
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
