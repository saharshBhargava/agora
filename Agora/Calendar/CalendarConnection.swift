import SwiftUI
import CryptoKit

@MainActor
final class CalendarConnection: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var checking = true
    @Published private(set) var connecting = false
    @Published private(set) var email: String?
    @Published private(set) var accountID: String?
    @Published var message: String?
    let authorization: GoogleCalendarAuthorizing
    private let http: URLSession
    private var revision = UUID()
    private var restoring = false
    var configurationIssue: String? { authorization.configurationIssue }

    init(authorization: GoogleCalendarAuthorizing? = nil, http: URLSession? = nil) {
        self.authorization = authorization ?? GoogleCalendarAuthorization()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        self.http = http ?? URLSession(configuration: config, delegate: NoCredentialRedirect(), delegateQueue: nil)
    }
    private func apply(_ account: GoogleCalendarAccount?) {
        accountID = account?.id; email = account?.email
        connected = account.map { GoogleCalendarAuthorization.scopes.isSubset(of: $0.scopes) } ?? false
        message = account != nil && !connected ? "Approve Google Calendar permissions to finish onboarding." : nil
    }
    func refresh() async {
        guard !connecting, !restoring else { return }
        restoring = true
        let version = revision
        defer { restoring = false; checking = false }
        if let configurationIssue { message = configurationIssue; connected = false; return }
        do {
            let account = try await authorization.restore()
            guard revision == version else { return }
            apply(account)
        } catch {
            guard revision == version else { return }
            handle(error)
        }
    }
    func connect() async {
        guard !connecting, !restoring else { return }
        connecting = true; message = nil; revision = UUID()
        defer { connecting = false; checking = false }
        do { apply(try await authorization.connect()) }
        catch { handle(error) }
    }
    func signOut() async {
        guard !connecting else { return }
        revision = UUID(); authorization.signOut(); apply(nil); checking = false
    }
    func disconnect() async {
        guard !connecting else { return }
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
                         account id: String, revision version: UUID, creating: Bool = false) async throws -> (Int, [String: Any]) {
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
    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class NoCredentialRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
