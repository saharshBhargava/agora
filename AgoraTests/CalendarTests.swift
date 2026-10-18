import XCTest
@testable import Agora

final class CalendarToolTests: XCTestCase {
    static let args: [String: Any] = ["title": "Grocery run", "start": "2026-10-18T17:00:00-07:00", "end": "2026-10-18T17:30:00-07:00", "timezone": "America/Los_Angeles"]
    func testRejectsUnapprovedFieldsInvalidDatesAndDSTOffsets() {
        for changes: [String: Any] in [["confirmed": true], ["attendees": ["someone@example.com"]], ["start": "tomorrow"], ["start": "2026-10-18T17:00:00"], ["start": "2026-10-18T17:00:00-08:00"], ["end": "2026-10-18T16:30:00-07:00"], ["timezone": "Mars/Olympus"], ["title": " "], ["location": 42]] {
            XCTAssertThrowsError(try CalendarCall(["name": "calendar_create_event", "args": Self.args.merging(changes) { _, new in new }]))
        }
    }
    func testStableRequestKeyAndCompleteApproval() throws {
        let call = try CalendarCall(["name": "calendar_create_event", "args": Self.args])
        let task = UUID()
        XCTAssertEqual(try call.requestKey(taskID: task), try call.requestKey(taskID: task))
        XCTAssertNotEqual(try call.requestKey(taskID: task), try call.requestKey(taskID: UUID()))
        for value in ["Grocery run", "America/Los_Angeles", "17:30"] { XCTAssertTrue(call.approvalDetail.contains(value)) }
    }
}

@MainActor
private final class FakeGoogleAuthorization: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = GoogleCalendarAccount(id: "alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    var accessTokenCalls = 0
    var idTokenCalls = 0
    var didSignOut = false
    var didDisconnect = false
    var connectionError: Error?
    var holdTokenRefresh = false
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount {
        if let connectionError { throw connectionError }
        return account!
    }
    func accessToken(for accountID: String) async throws -> String {
        guard accountID == account?.id else { throw BrowserError("calendar_account_changed") }
        accessTokenCalls += 1
        if holdTokenRefresh { try await Task.sleep(for: .seconds(30)) }
        return "google-access-\(accountID)"
    }
    func idToken(for accountID: String) async throws -> String {
        idTokenCalls += 1
        return "google-identity-\(accountID)"
    }
    func signOut() { didSignOut = true; account = nil }
    func disconnect() async throws { didDisconnect = true; account = nil }
}

private final class CalendarURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, json) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&bytes, maxLength: bytes.count)
                if read <= 0 { break }
                data.append(contentsOf: bytes.prefix(read))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private final class CalendarServerStub {
    private let lock = NSLock()
    private var events: [String: [String: Any]] = [:]
    private var savedRequests: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { savedRequests } }
    var count: Int { lock.withLock { events.count } }
    func respond(_ request: URLRequest) -> (Int, Any) {
        lock.withLock {
            savedRequests.append(request)
            if request.url!.path.hasSuffix("/freeBusy") { return (200, ["calendars": ["primary": ["busy": []]]]) }
            if request.httpMethod == "POST", request.url!.path.hasSuffix("/events") {
                var event = CalendarURLProtocol.body(request)
                let id = event["id"] as! String
                if events[id] != nil { return (409, [:]) }
                event["htmlLink"] = "https://calendar.google.com/event?eid=\(id)"
                events[id] = event
                return (201, event)
            }
            if let event = events[request.url!.lastPathComponent] { return (200, event) }
            return (404, [:])
        }
    }
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
final class CalendarAuthTests: XCTestCase {
    func testMissingOrIncorrectOAuthConfigurationIsActionable() {
        XCTAssertNotNil(GoogleCalendarAuthorization.configurationIssue(clientID: "", schemes: []))
        XCTAssertNotNil(GoogleCalendarAuthorization.configurationIssue(clientID: "$(AGORA_GOOGLE_IOS_CLIENT_ID)", schemes: []))
        XCTAssertNotNil(GoogleCalendarAuthorization.configurationIssue(clientID: "123-test.apps.googleusercontent.com", schemes: ["wrong"]))
        XCTAssertNil(GoogleCalendarAuthorization.configurationIssue(clientID: "123-test.apps.googleusercontent.com", schemes: ["com.googleusercontent.apps.123-test"]))
    }
    func testRestoreWithoutBackendAndPartialConsent() async {
        let auth = FakeGoogleAuthorization()
        auth.account = GoogleCalendarAccount(id: "alice", email: "alice@example.com", scopes: [])
        let connection = CalendarConnection(authorization: auth)
        await connection.refresh()
        XCTAssertFalse(connection.connected)
        XCTAssertFalse(connection.checking)
        XCTAssertEqual(connection.email, "alice@example.com")
        XCTAssertTrue(connection.message!.contains("permissions"))
        auth.account = GoogleCalendarAccount(id: "alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
        await connection.connect()
        XCTAssertTrue(connection.connected)
        XCTAssertEqual(auth.accessTokenCalls, 0)
        XCTAssertEqual(auth.idTokenCalls, 0)
    }
    func testCancelledConsentStaysInOnboarding() async {
        let auth = FakeGoogleAuthorization()
        auth.account = nil
        auth.connectionError = BrowserError("google_sign_in_cancelled", "Connect Google Calendar to continue.")
        let connection = CalendarConnection(authorization: auth)
        await connection.connect()
        XCTAssertFalse(connection.connected)
        XCTAssertFalse(connection.connecting)
        XCTAssertNotNil(connection.message)
    }
    func testSignOutAndDisconnectUseGoogleSDKWithoutBackend() async {
        let auth = FakeGoogleAuthorization()
        let connection = CalendarConnection(authorization: auth)
        await connection.refresh()
        await connection.signOut()
        XCTAssertTrue(auth.didSignOut)
        XCTAssertFalse(connection.connected)
        XCTAssertNil(connection.accountID)
        auth.account = GoogleCalendarAccount(id: "bob", email: "bob@example.com", scopes: GoogleCalendarAuthorization.scopes)
        await connection.connect()
        await connection.disconnect()
        XCTAssertTrue(auth.didDisconnect)
        XCTAssertFalse(connection.connected)
    }
}

@MainActor
final class CalendarAgentTests: XCTestCase {
    private var auth: FakeGoogleAuthorization!
    private var connection: CalendarConnection!
    private var http: URLSession!
    private var stub: CalendarServerStub!
    override func setUp() async throws {
        auth = FakeGoogleAuthorization()
        stub = CalendarServerStub()
        let server = stub!
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CalendarURLProtocol.self]
        http = URLSession(configuration: config)
        CalendarURLProtocol.handler = { server.respond($0) }
        connection = CalendarConnection(authorization: auth, http: http)
        await connection.refresh()
        XCTAssertTrue(connection.connected)
    }
    override func tearDown() async throws {
        http.invalidateAndCancel()
        connection = nil; CalendarURLProtocol.handler = nil
    }
    private func agent() -> (AgentCoordinator, CalendarModel) {
        let agent = AgentCoordinator(settings: SettingsStore(keychainService: "test.agora.calendar.\(UUID())"), browser: BrowserSession(policy: BrowserPolicy()), calendar: connection)
        let model = CalendarModel(); agent.providerOverride = model
        return (agent, model)
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate())
    }
    func testCreationWaitsForApprovalAndCallsGoogleDirectly() async throws {
        let (agent, model) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        XCTAssertEqual(stub.count, 0)
        agent.resolveApproval(true)
        try await waitUntil { !agent.running }
        XCTAssertEqual(stub.count, 1)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.url?.host, "www.googleapis.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer google-access-alice")
        XCTAssertEqual(auth.accessTokenCalls, 1)
        XCTAssertEqual(auth.idTokenCalls, 0)
        let parts = model.replies.last?["parts"] as? [[String: Any]]
        let reply = parts?.first?["functionResponse"] as? [String: Any]
        XCTAssertEqual(reply?["id"] as? String, "calendar-call")
        XCTAssertEqual((reply?["response"] as? [String: Any])?["created"] as? Bool, true)
        let serialized = String(data: try JSONSerialization.data(withJSONObject: model.replies), encoding: .utf8)!
        XCTAssertFalse(serialized.contains("google-access"))
    }
    func testDenialAndCancellationDoNotCreateEvents() async throws {
        let (agent, _) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.resolveApproval(false)
        try await waitUntil { !agent.running }
        XCTAssertEqual(stub.count, 0)
        agent.newChat(); agent.providerOverride = CalendarModel()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(stub.count, 0)
    }
    func testRepeatedCreateRecoversSameEvent() async throws {
        let call = try CalendarCall(["name": "calendar_create_event", "args": CalendarToolTests.args])
        let task = UUID()
        let first = try await connection.execute(call, taskID: task)
        let second = try await connection.execute(call, taskID: task)
        XCTAssertEqual(first["id"] as? String, second["id"] as? String)
        XCTAssertEqual(stub.count, 1)
        XCTAssertEqual(stub.requests.last?.httpMethod, "GET")
    }
    func testAccountChangeInvalidatesApproval() async throws {
        let (agent, _) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        auth.account = GoogleCalendarAccount(id: "bob", email: "bob@example.com", scopes: GoogleCalendarAuthorization.scopes)
        await connection.connect()
        agent.resolveApproval(true)
        try await waitUntil { !agent.running }
        XCTAssertEqual(stub.count, 0)
    }
    func testAvailabilityErrorsDoNotBecomeFreeTime() async throws {
        CalendarURLProtocol.handler = { _ in (200, ["calendars": ["primary": ["errors": [["reason": "internalError"]]]]]) }
        let call = try CalendarCall(["name": "calendar_freebusy", "args": CalendarToolTests.args.filter { $0.key != "title" }])
        do { _ = try await connection.execute(call, taskID: UUID()); XCTFail("Expected unknown availability") }
        catch { XCTAssertEqual((error as? BrowserError)?.code, "availability_unknown") }
    }
    func testRevokedAccessReturnsToOnboarding() async throws {
        CalendarURLProtocol.handler = { _ in (401, ["private": "must-not-leak"]) }
        do {
            _ = try await connection.execute(CalendarCall(["name": "calendar_create_event", "args": CalendarToolTests.args]), taskID: UUID())
            XCTFail("Expected reconnect")
        } catch {
            XCTAssertFalse(connection.connected)
            XCTAssertFalse(error.localizedDescription.contains("must-not-leak"))
        }
    }
    func testUncertainMutationStopsAgentWithoutRetry() async throws {
        CalendarURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let (agent, model) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.resolveApproval(true)
        try await waitUntil { !agent.running }
        XCTAssertTrue(agent.status.contains("outcome_unknown"))
        XCTAssertEqual(model.turn, 1)
        XCTAssertEqual(auth.accessTokenCalls, 1)
    }
    func testStoppingDuringCalendarWriteWarnsInsteadOfOfferingResume() async throws {
        auth.holdTokenRefresh = true
        let (agent, _) = agent()
        agent.send("Add a grocery run")
        try await waitUntil { agent.approval != nil }
        agent.resolveApproval(true)
        try await waitUntil { auth.accessTokenCalls == 1 }
        agent.stop(reason: "App backgrounded", paused: true)
        XCTAssertFalse(agent.paused)
        XCTAssertTrue(agent.status.contains("Check Google Calendar"))
        XCTAssertEqual(stub.count, 0)
    }
    func testInventoryFetchDecodesArraysAndUsesIdentityTokenOnly() async throws {
        CalendarURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "api.example.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer google-identity-alice")
            return (200, [["id": UUID().uuidString, "display_name": "Milk", "quantity": 1.0, "unit": "liters", "par_level": 2.0]])
        }
        let api = AgoraClient(calendar: connection, baseURL: URL(string: "https://api.example.com"), http: http)
        let items = try await api.fetch("v1/inventory", as: [HomeInventoryItem].self)
        XCTAssertEqual(items.first?.displayName, "Milk")
        XCTAssertEqual(items.first?.isRunningLow, true)
        XCTAssertEqual(auth.accessTokenCalls, 0)
        XCTAssertEqual(auth.idTokenCalls, 1)
    }
    func testInventoryAuthenticationFailureDoesNotSignOutCalendar() async throws {
        CalendarURLProtocol.handler = { _ in (401, [:]) }
        let api = AgoraClient(calendar: connection, baseURL: URL(string: "https://api.example.com"), http: http)
        do { _ = try await api.fetch("v1/inventory", as: [HomeInventoryItem].self); XCTFail("Expected error") }
        catch { XCTAssertTrue(connection.connected); XCTAssertEqual(connection.email, "alice@example.com") }
    }
}
