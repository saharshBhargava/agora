import SwiftUI
import CryptoKit
import Security

@MainActor
final class CalendarConnection: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var checking = true
    @Published private(set) var connecting = false
    @Published private(set) var email: String?
    @Published private(set) var accountID: String?
    @Published var message: String?
    @Published private(set) var isDemoAccount = false
    private var demoSession: DemoSession?
    private let demoBaseURL: URL?
    private let sessionStore: DemoSessionStoring
    let authorization: GoogleCalendarAuthorizing
    private let http: URLSession
    private var revision = UUID()
    private var restoring = false
    var beforeSignOut: (() async -> Void)?
    var configurationIssue: String? { authorization.configurationIssue }

    init(authorization: GoogleCalendarAuthorizing? = nil, http: URLSession? = nil,
         demoBaseURL: URL? = nil, sessionStore: DemoSessionStoring? = nil) {
        self.demoBaseURL = demoBaseURL
        self.sessionStore = sessionStore ?? DemoKeychainStore()
        self.authorization = authorization ?? GoogleCalendarAuthorization()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.http = http ?? URLSession(configuration: config, delegate: NoCredentialRedirect(), delegateQueue: nil)
    }
    private func apply(_ account: GoogleCalendarAccount?) {
        isDemoAccount = false; demoSession = nil
        accountID = account?.id; email = account?.email
        connected = account.map { GoogleCalendarAuthorization.scopes.isSubset(of: $0.scopes) } ?? false
        message = account != nil && !connected ? "Approve Google Calendar permissions to finish onboarding." : nil
    }
    func refresh() async {
        guard !connecting, !restoring else { return }
        restoring = true
        let version = revision
        defer { restoring = false; checking = false }
        let storedSession: DemoSession?
        do { storedSession = try (demoBaseURL == nil ? nil : sessionStore.load()) }
        catch {
            apply(nil)
            message = "Could not read the saved session securely. Sign in again."
            return
        }
        if let stored = storedSession {
            do {
                guard stored.expiresAt > Date(), stored.origin == demoBaseURL?.absoluteString else { throw BrowserError("session_expired") }
                let profile = try await demoHTTP("v1/demo/profile", token: stored.token)
                guard let id = profile["id"] as? String, stored.accountID == "agora:" + id else {
                    throw BrowserError("account_changed")
                }
                guard revision == version else { return }
                applyDemo(stored)
            } catch {
                guard revision == version else { return }
                apply(nil)
                message = "Sign in to the demo again. Your saved data is still available."
            }
            return
        }
        if let configurationIssue { message = configurationIssue; connected = false; return }
        do {
            let account = try await authorization.restore()
            guard revision == version else { return }
            apply(account)
            await discoverDemo()
        } catch {
            guard revision == version else { return }
            handle(error)
        }
    }
    func connect() async {
        guard !connecting, !restoring else { return }
        connecting = true; checking = true; message = nil; revision = UUID()
        defer { connecting = false; checking = false }
        do {
            // Hide the previous account before credentials/provider selection can change.
            if demoBaseURL != nil { try sessionStore.save(nil) }
            apply(nil)
            apply(try await authorization.connect())
            await discoverDemo()
        }
        catch { handle(error) }
    }
    func signOut() async {
        guard !connecting else { return }
        await beforeSignOut?()
        do { if demoBaseURL != nil { try sessionStore.save(nil) } }
        catch { message = "Could not remove the saved session. Try signing out again."; return }
        revision = UUID(); authorization.signOut(); apply(nil); checking = false
    }
    func disconnect() async {
        if isDemoAccount { await signOut(); return }
        guard !connecting else { return }
        await beforeSignOut?()
        connecting = true; revision = UUID()
        defer { connecting = false }
        do { try await authorization.disconnect(); apply(nil) }
        catch { handle(error) }
    }
    private func handle(_ error: Error) {
        if let error = error as? BrowserError {
            message = error.detail.isEmpty ? "Could not connect to Google Calendar. Please try again." : error.detail
            if ["calendar_reconnect_required", "calendar_account_changed"].contains(error.code) { connected = false }
        } else if !(error is CancellationError) {
            message = "Could not connect to Google Calendar. Please try again."
        }
    }
    private func checkAccount(_ id: String, revision version: UUID) throws {
        try Task.checkCancellation()
        guard connected, accountID == id, revision == version else {
            throw BrowserError("calendar_account_changed", "Your Google connection changed. Start a new request.")
        }
    }
    private func request(_ path: String, method: String, body: [String: Any]? = nil,
                         account id: String, revision version: UUID, creating: Bool = false,
                         allowMissing: Bool = false) async throws -> (Int, [String: Any]) {
        let token: String
        do { token = try await authorization.accessToken(for: id) }
        catch { handle(error); throw error }
        try checkAccount(id, revision: version)
        var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/" + path)!
        if creating { url.queryItems = [URLQueryItem(name: "sendUpdates", value: "none")] }
        var request = URLRequest(url: url.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        let data: Data, response: URLResponse
        do { (data, response) = try await http.data(for: request) }
        catch {
            if creating { throw BrowserError("outcome_unknown", "Google did not confirm event creation. Check Calendar before retrying.") }
            try Task.checkCancellation()
            throw BrowserError("connection_failed", "Could not reach Google Calendar. Please try again.")
        }
        try checkAccount(id, revision: version)
        guard let response = response as? HTTPURLResponse else {
            throw BrowserError(creating ? "outcome_unknown" : "invalid_calendar_response")
        }
        // Raw Google error bodies can contain private details and never go to the model or logs.
        if response.statusCode == 401 {
            let error = BrowserError("calendar_reconnect_required", "Google access expired. Reconnect Google Calendar.")
            handle(error); throw error
        }
        if response.statusCode == 403 {
            let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let reasons = ((result?["error"] as? [String: Any])?["errors"] as? [[String: Any]] ?? []).compactMap { $0["reason"] as? String }
            if reasons.contains("insufficientPermissions") {
                let error = BrowserError("calendar_reconnect_required", "Approve Google Calendar permissions to continue.")
                handle(error); throw error
            }
            throw BrowserError("calendar_access_denied", "Google denied Calendar access. The Calendar API may need to be enabled for this app, or access may be restricted by your organization.")
        }
        if response.statusCode == 404 && allowMissing { return (404, [:]) }
        if response.statusCode == 409 { return (409, [:]) }
        guard (200..<300).contains(response.statusCode) else {
            throw BrowserError(creating && response.statusCode >= 500 ? "outcome_unknown" : "calendar_request_failed",
                               creating ? "Google did not confirm event creation. Check Calendar before retrying." : "Could not check your Calendar. Please try again.")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BrowserError(creating ? "outcome_unknown" : "invalid_calendar_response")
        }
        return (response.statusCode, json)
    }
    func execute(_ call: CalendarCall, taskID: UUID, expectedAccountID: String? = nil) async throws -> [String: Any] {
        guard connected, let id = accountID else {
            throw BrowserError("calendar_reconnect_required", "Reconnect Google Calendar to continue.")
        }
        if let expectedAccountID, expectedAccountID != id {
            throw BrowserError("calendar_account_changed", "Your Google account changed. Review a new request.")
        }
        let version = revision
        if isDemoAccount {
            var body = call.arguments
            let path: String
            var key: String?
            if call.name == "calendar_freebusy" { path = "v1/demo/calendar/freebusy" }
            else {
                path = "v1/demo/calendar/events"; body["confirmed"] = true
                key = try call.requestKey(taskID: taskID)
            }
            let token = try await apiToken(for: id)
            let result = try await demoHTTP(path, token: token, method: "POST", body: body, key: key)
            try checkAccount(id, revision: version)
            if call.name == "calendar_create_event" {
                guard result["created"] as? Bool == true, let eventID = result["id"] as? String,
                      UUID(uuidString: eventID) != nil else { throw BrowserError("outcome_unknown") }
            }
            return result
        }
        if call.name == "calendar_freebusy" {
            let (_, response) = try await request("freeBusy", method: "POST", body: [
                "timeMin": call.arguments["start"]!, "timeMax": call.arguments["end"]!,
                "timeZone": call.arguments["timezone"]!, "items": [["id": "primary"]]
            ], account: id, revision: version)
            guard let primary = (response["calendars"] as? [String: Any])?["primary"] as? [String: Any],
                  (primary["errors"] as? [Any] ?? []).isEmpty, let busy = primary["busy"] as? [[String: Any]],
                  busy.allSatisfy({ ($0["start"] as? String).flatMap(CalendarCall.date) != nil && ($0["end"] as? String).flatMap(CalendarCall.date) != nil }) else {
                throw BrowserError("availability_unknown", "Google could not confirm availability. Do not assume the time is free.")
            }
            return ["busy": busy.map { ["start": $0["start"]!, "end": $0["end"]!] }, "timezone": call.arguments["timezone"]!]
        }
        let key = try call.requestKey(taskID: taskID)
        let eventID = Self.hash(Data("agora:\(id):\(key)".utf8))
        let fingerprint = Self.hash(try JSONSerialization.data(withJSONObject: call.arguments, options: [.sortedKeys]))
        let payload: [String: Any] = [
            "id": eventID, "summary": call.arguments["title"]!,
            "description": call.arguments["description"] ?? "", "location": call.arguments["location"] ?? "",
            "start": ["dateTime": call.arguments["start"]!, "timeZone": call.arguments["timezone"]!],
            "end": ["dateTime": call.arguments["end"]!, "timeZone": call.arguments["timezone"]!],
            "extendedProperties": ["private": ["agora_request": fingerprint]]
        ]
        var (status, event) = try await request("calendars/primary/events", method: "POST", body: payload, account: id, revision: version, creating: true)
        if status == 409 {
            // A previous attempt may have succeeded even if the phone missed the response.
            do {
                (status, event) = try await request("calendars/primary/events/\(eventID)", method: "GET", account: id, revision: version)
            } catch { throw BrowserError("outcome_unknown", "An event with this ID already exists, but could not be verified. Check Calendar before retrying.") }
            let properties = (event["extendedProperties"] as? [String: Any])?["private"] as? [String: Any]
            guard properties?["agora_request"] as? String == fingerprint else {
                throw BrowserError("outcome_unknown", "The existing event does not match this request. Check Google Calendar.")
            }
        }
        guard event["id"] as? String == eventID, event["status"] as? String != "cancelled",
              let link = event["htmlLink"] as? String, let url = URL(string: link), url.scheme == "https",
              ["www.google.com", "calendar.google.com"].contains(url.host ?? ""), url.user == nil, url.password == nil else {
            throw BrowserError("outcome_unknown", "Google did not return a confirmed event. Check Calendar before retrying.")
        }
        return ["created": true, "id": eventID, "url": link]
    }
    /// Recovery deliberately performs only reads. A missed creation response must never cause another insert.
    func lookupExistingEvent(_ call: CalendarCall, taskID: UUID, expectedAccountID: String) async throws -> [String: Any]? {
        guard connected, accountID == expectedAccountID, call.name == "calendar_create_event" else {
            throw BrowserError("calendar_account_changed")
        }
        let version = revision
        if isDemoAccount {
            guard let origin = demoBaseURL else { throw BrowserError("agora_not_configured") }
            let token = try await apiToken(for: expectedAccountID)
            var components = URLComponents(url: origin.appendingPathComponent("v1/demo/calendar/events/by-request"), resolvingAgainstBaseURL: false)!
            components.queryItems = [.init(name: "key", value: try call.requestKey(taskID: taskID))]
            var query = URLRequest(url: components.url!)
            query.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await http.data(for: query)
            try checkAccount(expectedAccountID, revision: version)
            guard let response = response as? HTTPURLResponse,
                  let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw BrowserError("outcome_unknown", "Could not verify the saved Calendar event. Check Calendar before trying another trip.")
            }
            if response.statusCode == 404, result["title"] as? String == "not_found" { return nil }
            guard response.statusCode == 200, result["created"] as? Bool == true,
                  let id = result["id"] as? String, UUID(uuidString: id) != nil else {
                throw BrowserError("outcome_unknown", "Could not verify the saved Calendar event. Check Calendar before trying another trip.")
            }
            return ["created": true, "id": id]
        }
        let key = try call.requestKey(taskID: taskID)
        let eventID = Self.hash(Data("agora:\(expectedAccountID):\(key)".utf8))
        let fingerprint = Self.hash(try JSONSerialization.data(withJSONObject: call.arguments, options: [.sortedKeys]))
        let (status, event) = try await request("calendars/primary/events/\(eventID)", method: "GET",
                                          account: expectedAccountID, revision: version, allowMissing: true)
        if status == 404 { return nil }
        let properties = (event["extendedProperties"] as? [String: Any])?["private"] as? [String: Any]
        guard properties?["agora_request"] as? String == fingerprint,
              event["id"] as? String == eventID, event["status"] as? String != "cancelled",
              event["summary"] as? String == call.arguments["title"] as? String,
              (event["description"] as? String ?? "") == (call.arguments["description"] as? String ?? ""),
              (event["location"] as? String ?? "") == (call.arguments["location"] as? String ?? ""),
              ["start", "end"].allSatisfy({ key in
                  guard let raw = (event[key] as? [String: Any])?["dateTime"] as? String,
                        let expected = call.arguments[key] as? String,
                        let actualDate = CalendarCall.date(raw), let expectedDate = CalendarCall.date(expected) else { return false }
                  return actualDate == expectedDate
              }),
              let link = event["htmlLink"] as? String, let url = URL(string: link), url.scheme == "https",
              ["www.google.com", "calendar.google.com"].contains(url.host ?? ""), url.user == nil, url.password == nil else {
            throw BrowserError("outcome_unknown", "The existing Calendar event could not be verified. Check Calendar before continuing.")
        }
        return ["created": true, "id": eventID, "url": link]
    }
    func verifyDemo(expectedAccountID: String?) async throws {
        guard isDemoAccount, let id = expectedAccountID, id == accountID else { throw BrowserError("account_changed") }
        let version = revision
        let token = try await apiToken(for: id)
        _ = try await demoHTTP("v1/demo/profile", token: token)
        try checkAccount(id, revision: version)
        guard isDemoAccount else { throw BrowserError("account_changed") }
    }
    func apiToken(for id: String) async throws -> String {
        let version = revision
        try checkAccount(id, revision: version)
        if let session = demoSession {
            guard session.expiresAt > Date() else {
                connected = false
                throw BrowserError("session_expired", "Sign in to the demo again.")
            }
            return session.token
        }
        let token = try await authorization.idToken(for: id)
        try checkAccount(id, revision: version)
        return token
    }
    func connectDemo(handle: String, password: String) async {
        guard !connecting, !restoring else { return }
        connecting = true; checking = true; message = nil; revision = UUID()
        let version = revision
        defer { connecting = false; checking = false }
        do {
            // A failed sign-in cannot retain another account's access.
            if demoBaseURL != nil { try sessionStore.save(nil) }
            apply(nil)
            let login = try await demoHTTP("v1/dev/login", method: "POST", body: ["handle": handle, "password": password])
            guard let token = login["access_token"] as? String, !token.isEmpty,
                  let expiration = login["expires_at"] as? Double, expiration.isFinite,
                  Date(timeIntervalSince1970: expiration) > Date() else {
                throw BrowserError("invalid_server_response")
            }
            let expires = Date(timeIntervalSince1970: expiration)
            let profile = try await demoHTTP("v1/demo/profile", token: token)
            guard let id = profile["id"] as? String, UUID(uuidString: id) != nil else { throw BrowserError("invalid_server_response") }
            guard revision == version else { return }
            let session = DemoSession(token: token, expiresAt: expires, accountID: "agora:" + id,
                                      origin: demoBaseURL!.absoluteString)
            try sessionStore.save(session)
            authorization.signOut()
            applyDemo(session)
        } catch {
            guard revision == version else { return }
            apply(nil)
            message = ((error as? BrowserError).flatMap { $0.detail.isEmpty ? nil : $0.detail }) ?? "Could not sign in. Check the username and password, then try again."
        }
    }
    private func applyDemo(_ session: DemoSession) {
        demoSession = session; isDemoAccount = true; email = nil
        accountID = session.accountID; connected = true; message = nil
    }
    private func discoverDemo() async {
        // Google remains optional. The server alone decides whether this identity owns the sample account.
        guard demoBaseURL != nil, connected, let id = accountID else { return }
        let version = revision
        do {
            let token = try await authorization.idToken(for: id)
            let profile = try await demoHTTP("v1/demo/profile", token: token)
            guard let profileID = profile["id"] as? String, UUID(uuidString: profileID) != nil else {
                throw BrowserError("invalid_server_response")
            }
            try checkAccount(id, revision: version)
            isDemoAccount = true
        } catch {
            // Fail closed: a network failure cannot send a known demo session to a real provider.
            if (error as? BrowserError)?.code != "integration_unavailable", revision == version {
                connected = false
                message = "Could not verify your account. Try connecting again."
            }
        }
    }
    private func demoHTTP(_ path: String, token: String? = nil, method: String = "GET",
                          body: [String: Any]? = nil, key: String? = nil) async throws -> [String: Any] {
        guard let origin = demoBaseURL, origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else {
            throw BrowserError("agora_not_configured", "Configure an HTTPS Agora API address for demo sign-in.")
        }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let key { request.setValue(key, forHTTPHeaderField: "Idempotency-Key") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await http.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw BrowserError("invalid_server_response") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw BrowserError("invalid_credentials", "Wrong username or password, or your session has expired.") }
            if response.statusCode == 403 { throw BrowserError("integration_unavailable", "Use the designated demo account for this sign-in option.") }
            throw BrowserError("connection_failed", "Dibs could not complete this request. Please try again.")
        }
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw BrowserError("invalid_server_response")
        }
        return json
    }
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class NoCredentialRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}


struct DemoSession: Codable {
    let token: String
    let expiresAt: Date
    let accountID: String
    let origin: String
}

@MainActor
protocol DemoSessionStoring {
    func load() throws -> DemoSession?
    func save(_ session: DemoSession?) throws
}

@MainActor
final class DemoKeychainStore: DemoSessionStoring {
    private let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "app.agora.session", kSecAttrAccount as String: "sample-account"]
    func load() throws -> DemoSession? {
        var query = query; query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw BrowserError("session_storage_failed") }
        return try JSONDecoder().decode(DemoSession.self, from: data)
    }
    func save(_ session: DemoSession?) throws {
        guard let session else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw BrowserError("session_storage_failed") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(session),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else {
            throw BrowserError("session_storage_failed", "Could not save the session securely. Run a signed build with Keychain access.")
        }
    }
}
