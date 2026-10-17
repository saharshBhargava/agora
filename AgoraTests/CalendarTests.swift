import XCTest
import Security
@testable import Agora

final class CalendarToolTests: XCTestCase {
    static let args: [String: Any] = ["title": "Grocery run", "start": "2026-10-18T17:00:00-07:00", "end": "2026-10-18T17:30:00-07:00", "timezone": "America/Los_Angeles"]
    func testRejectsUnapprovedFieldsAndInvalidDates() {
        for changes: [String: Any] in [["confirmed": true], ["attendees": ["someone@example.com"]], ["start": "tomorrow"], ["end": "2026-10-18T16:30:00-07:00"], ["timezone": "Mars/Olympus"], ["title": " "], ["location": 42]] {
            XCTAssertThrowsError(try CalendarCall(["name": "calendar_create_event", "args": Self.args.merging(changes) { _, new in new }]))
        }
    }
    func testStableRequestKeyAndCompleteApproval() throws {
        let call = try CalendarCall(["name": "calendar_create_event", "args": Self.args])
        let task = UUID()
        XCTAssertEqual(try call.requestKey(taskID: task), try call.requestKey(taskID: task))
        XCTAssertNotEqual(try call.requestKey(taskID: task), try call.requestKey(taskID: UUID()))
        XCTAssertTrue(call.approvalDetail.contains("Grocery run"))
        XCTAssertTrue(call.approvalDetail.contains("America/Los_Angeles"))
        XCTAssertTrue(call.approvalDetail.contains("17:30"))
    }
}

@MainActor
final class CalendarAuthTests: XCTestCase {
    func testCallbackStateAndDestinationAreValidated() throws {
        let good = URL(string: "dev.agora.browserchat://google-callback?state=expected&code=one-time")!
        XCTAssertEqual(try CalendarConnection.authorizationCode(callback: good, expectedState: "expected"), "one-time")
        for address in [
            "dev.agora.browserchat://google-callback?state=other&code=secret",
            "dev.agora.browserchat://google-callback?state=expected&state=other&code=secret",
            "dev.agora.browserchat://other?state=expected&code=secret",
            "https://google-callback?state=expected&code=secret",
            "dev.agora.browserchat://google-callback?state=expected&error=access_denied"
        ] {
            XCTAssertThrowsError(try CalendarConnection.authorizationCode(callback: URL(string: address)!, expectedState: "expected"))
        }
    }
}

private final class CalendarURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: Any]))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class CalendarModel: ModelProvider {
    var turn = 0
    var replies: [[String: Any]] = []
    func nextTurn(contents: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
        XCTAssertTrue(tools.contains { $0["name"] as? String == "calendar_create_event" })
        defer { turn += 1 }
        if turn == 0 {
            return ["role": "model", "parts": [["functionCall": ["name": "calendar_create_event", "args": CalendarToolTests.args, "id": "calendar-call"]]]]
        }
        replies = contents
        return ["role": "model", "parts": [["text": "Done."]]]
    }
}

@MainActor
final class CalendarAgentTests: XCTestCase {
    private var service = ""
    private var connection: CalendarConnection!
    private var http: URLSession!
    private var creates = 0
    private var lastRequest: URLRequest?
    override func setUp() async throws {
        service = "test.agora.calendar.\(UUID().uuidString)"
        let account = CalendarConnection.Account(token: "ags_test", email: "alice@example.com", userID: UUID().uuidString, expiresAt: "2099-01-01T00:00:00Z")
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session", kSecValueData as String: try JSONEncoder().encode(account)]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarURLProtocol.self]
        http = URLSession(configuration: config)
        CalendarURLProtocol.handler = { [weak self] request in
            if request.url!.path == "/v1/integrations/google" { return (200, ["connected": true, "email": "alice@example.com"]) }
            if request.url!.path == "/v1/calendar/events" {
                self?.creates += 1; self?.lastRequest = request
                return (201, ["created": true, "id": "event", "url": "https://calendar.google.com/event"])
            }
            return (404, [:])
        }
        connection = CalendarConnection(baseURL: URL(string: "https://api.example.com"), http: http, service: service)
        await connection.refresh()
        XCTAssertTrue(connection.connected)
    }
    override func tearDown() async throws {
        http.invalidateAndCancel()
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        connection = nil; CalendarURLProtocol.handler = nil
    }
    private func agent() -> (AgentCoordinator, CalendarModel) {
        let agent = AgentCoordinator(settings: SettingsStore(keychainService: service + ".gemini"), browser: BrowserSession(policy: BrowserPolicy()), calendar: connection)
        let model = CalendarModel(); agent.providerOverride = model
        return (agent, model)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    func testCreationWaitsForApprovalAndReturnsCorrelatedResult() async throws {
        let (agent, model) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        XCTAssertEqual(creates, 0)
        agent.resolveApproval(true)
        try await waitUntil { !agent.running }
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer ags_test")
        XCTAssertEqual(lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")?.count, 64)
        let parts = model.replies.last?["parts"] as? [[String: Any]]
        let reply = parts?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(reply?["id"] as? String, "calendar-call")
        XCTAssertEqual((reply?["response"] as? [String: Any])?["created"] as? Bool, true)
    }
    func testDenialAndCancellationDoNotCreateEvents() async throws {
        let (agent, _) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.resolveApproval(false)
        try await waitUntil { !agent.running }
        XCTAssertEqual(creates, 0)
        agent.newChat()
        agent.providerOverride = CalendarModel()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(creates, 0)
    }
    func testRevokedAccessReturnsToOnboarding() async throws {
        CalendarURLProtocol.handler = { _ in (409, ["title": "calendar_reconnect_required", "detail": "Reconnect."]) }
        do {
            _ = try await connection.execute(CalendarCall(["name": "calendar_create_event", "args": CalendarToolTests.args]), taskID: UUID())
            XCTFail("Expected reconnect")
        } catch { XCTAssertFalse(connection.connected) }
    }
}
