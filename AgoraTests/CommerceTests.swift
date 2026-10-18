import XCTest
import SwiftUI
@testable import Agora

/// Responses from docs/api/agent-commerce.md and, `live*`, real responses from the local backend's demo
/// account (2026-10-18), ids scrubbed.
enum CommerceFixtures {
    static let docPropose = #"""
{
  "id": "02eeba9f-deab-4596-bbab-7139df979223",
  "household_id": "8f25c7bf-8bfa-488d-96b6-fad6bad46a3b",
  "kind": "purchase",
  "execution": "device",
  "title": "Oat milk, 2 cartons",
  "payload": {"url": "https://ballardmarket.example/oat-milk", "quantity": 2},
  "amount_cents": 898,
  "final_amount_cents": null,
  "currency": "USD",
  "merchant_id": "cef0d416-84ef-4ccc-8d62-3081c817ce40",
  "merchant_name": "Ballard Market",
  "category": "dairy",
  "rationale": "One carton left; you go through about two a week.",
  "evidence": [
    {"kind": "inventory_low", "detail": "1 carton in the fridge (scan, 2 days ago)"},
    {"kind": "runout_forecast", "detail": "Runs out Thu (Wed-Fri)"}
  ],
  "decision": "allow",
  "decision_reasons": [
    "Within your 'Weekly groceries' mandate: $8.98 of $50.00 allowed per purchase.",
    "$141.02 left on 'Weekly groceries' this week after this.",
    "$51.02 left in your monthly dairy budget after this."
  ],
  "reason_codes": ["within_mandate", "mandate_period_left", "within_budget"],
  "mandate_id": "b0dc5e4a-95c6-4da3-9e24-ff67cc712710",
  "status": "approved",
  "decided_by": "policy",
  "decided_at": "2026-10-18T00:39:44.472384Z",
  "reject_reason": null,
  "error_code": null,
  "order_id": null,
  "mine": true,
  "approval_expires_at": null,
  "created_at": "2026-10-18T00:39:44.472384Z",
  "updated_at": "2026-10-18T00:39:44.472384Z",
  "completed_at": null
}
"""#
    static let docMandate = #"""
{
  "id": "b0dc5e4a-95c6-4da3-9e24-ff67cc712710",
  "household_id": "8f25c7bf-8bfa-488d-96b6-fad6bad46a3b",
  "label": "Weekly groceries",
  "merchant_ids": ["cef0d416-84ef-4ccc-8d62-3081c817ce40"],
  "categories": ["dairy", "produce"],
  "currency": "USD",
  "max_per_txn_cents": 5000,
  "max_per_period_cents": 15000,
  "period": "week",
  "require_confirm_above_cents": 3000,
  "expires_at": "2026-11-17T00:38:53.175944Z",
  "status": "active",
  "revoked_at": null,
  "revoked_reason": null,
  "period_started_at": "2026-10-12T00:00:00-07:00",
  "spent_this_period_cents": 0,
  "created_at": "2026-10-18T00:38:53.177215Z"
}
"""#
    static let docPause = #"""
{
  "paused": true,
  "paused_at": "2026-10-18T00:39:19.428929Z",
  "mandates_revoked": 1,
  "intents_cancelled": 1,
  "in_flight": 0
}
"""#
    static let docState = #"""
{
  "autonomy_level": "buy_within_mandate",
  "paused": false,
  "paused_at": null,
  "active_mandates": 1,
  "pending_approvals": 0
}
"""#
    static let docBudgets = #"""
[
  {
    "id": "ae109f7c-0cda-47fd-83ca-d18be92d9c03",
    "household_id": "8f25c7bf-8bfa-488d-96b6-fad6bad46a3b",
    "period": "month",
    "category": "dairy",
    "limit_cents": 6000,
    "currency": "USD",
    "status": "active",
    "starts_on": "2026-10-18",
    "period_started_at": "2026-10-01T00:00:00-07:00",
    "spent_cents": 6298,
    "pending_cents": 0,
    "remaining_cents": -298,
    "created_at": "2026-10-18T00:39:44.458207Z",
    "updated_at": "2026-10-18T00:39:44.458207Z"
  }
]
"""#
    static let liveIntents = #"""
[{"id":"00000000-0000-4000-8000-000000000001","household_id":"00000000-0000-4000-8000-000000000002","kind":"purchase","execution":"device","title":"Extra virgin olive oil","payload":{},"amount_cents":1899,"final_amount_cents":null,"currency":"USD","merchant_id":null,"merchant_name":"PCC Community Markets","category":"pantry","rationale":"Your current bottle should run out this week.","evidence":[],"decision":"needs_approval","decision_reasons":["Please approve this purchase."],"reason_codes":["approval_required"],"mandate_id":null,"status":"proposed","decided_by":null,"decided_at":null,"reject_reason":null,"error_code":null,"order_id":null,"mine":true,"approval_expires_at":"2026-10-19T09:04:41.553627Z","created_at":"2026-10-18T09:04:41.553627Z","updated_at":"2026-10-18T09:04:41.553627Z","completed_at":null},{"id":"00000000-0000-4000-8000-000000000003","household_id":"00000000-0000-4000-8000-000000000002","kind":"purchase","execution":"device","title":"Apples and spinach","payload":{},"amount_cents":1125,"final_amount_cents":null,"currency":"USD","merchant_id":null,"merchant_name":"PCC Community Markets","category":"produce","rationale":"Restocked after running low.","evidence":[],"decision":"needs_approval","decision_reasons":["Waiting for your approval."],"reason_codes":["approval_required"],"mandate_id":null,"status":"succeeded","decided_by":"user","decided_at":"2026-10-16T09:04:41.553534Z","reject_reason":null,"error_code":null,"order_id":"00000000-0000-4000-8000-000000000004","mine":true,"approval_expires_at":null,"created_at":"2026-10-16T09:04:41.553534Z","updated_at":"2026-10-16T09:04:41.553534Z","completed_at":"2026-10-16T09:04:41.553534Z"},{"id":"00000000-0000-4000-8000-000000000005","household_id":"00000000-0000-4000-8000-000000000002","kind":"purchase","execution":"device","title":"Milk and eggs","payload":{},"amount_cents":1298,"final_amount_cents":null,"currency":"USD","merchant_id":null,"merchant_name":"PCC Community Markets","category":"dairy","rationale":"Restocked after running low.","evidence":[],"decision":"needs_approval","decision_reasons":["Waiting for your approval."],"reason_codes":["approval_required"],"mandate_id":null,"status":"succeeded","decided_by":"user","decided_at":"2026-10-14T09:04:41.553534Z","reject_reason":null,"error_code":null,"order_id":"00000000-0000-4000-8000-000000000006","mine":true,"approval_expires_at":null,"created_at":"2026-10-14T09:04:41.553534Z","updated_at":"2026-10-14T09:04:41.553534Z","completed_at":"2026-10-14T09:04:41.553534Z"}]
"""#
    static let livePropose = #"""
{"id":"00000000-0000-4000-8000-000000000007","household_id":"00000000-0000-4000-8000-000000000002","kind":"purchase","execution":"agora","title":"Sparkling water, 12 pack","payload":{"details":{"item_key":"chat-check"},"quantity":1},"amount_cents":699,"final_amount_cents":null,"currency":"USD","merchant_id":null,"merchant_name":"PCC Community Markets","category":"pantry","rationale":"You asked the assistant to buy this in chat.","evidence":[],"decision":"needs_approval","decision_reasons":["Your agent is set to Buy with approval, so every purchase needs your OK.","$553.79 left in your monthly budget after this."],"reason_codes":["autonomy_requires_approval","within_budget"],"mandate_id":null,"status":"proposed","decided_by":null,"decided_at":null,"reject_reason":null,"error_code":null,"order_id":null,"mine":true,"approval_expires_at":"2026-10-19T16:37:27.664866Z","created_at":"2026-10-18T16:37:27.664866Z","updated_at":"2026-10-18T16:37:27.664866Z","completed_at":null}
"""#
    static let liveApprove = #"""
{"id":"00000000-0000-4000-8000-000000000007","household_id":"00000000-0000-4000-8000-000000000002","kind":"purchase","execution":"agora","title":"Sparkling water, 12 pack","payload":{"details":{"item_key":"chat-check"},"quantity":1},"amount_cents":699,"final_amount_cents":699,"currency":"USD","merchant_id":null,"merchant_name":"PCC Community Markets","category":"pantry","rationale":"You asked the assistant to buy this in chat.","evidence":[],"decision":"needs_approval","decision_reasons":["Your agent is set to Buy with approval, so every purchase needs your OK.","$553.79 left in your monthly budget after this."],"reason_codes":["autonomy_requires_approval","within_budget"],"mandate_id":null,"status":"succeeded","decided_by":"user","decided_at":"2026-10-18T16:37:35.120380Z","reject_reason":null,"error_code":null,"order_id":"00000000-0000-4000-8000-000000000008","mine":true,"approval_expires_at":null,"created_at":"2026-10-18T16:37:27.664866Z","updated_at":"2026-10-18T16:37:35.118782Z","completed_at":"2026-10-18T16:37:35.118782Z"}
"""#
    static let liveMandates = #"""
[{"id":"00000000-0000-4000-8000-000000000009","household_id":"00000000-0000-4000-8000-000000000002","label":"Weekly groceries","merchant_ids":null,"categories":["dairy","produce","pantry"],"currency":"USD","max_per_txn_cents":2500,"max_per_period_cents":20000,"period":"month","require_confirm_above_cents":1500,"expires_at":"2026-11-08T09:04:41.553534Z","status":"active","revoked_at":null,"revoked_reason":null,"period_started_at":"2026-10-01T00:00:00-07:00","spent_this_period_cents":0,"created_at":"2026-10-18T09:04:41.553627Z"}]
"""#
    static let liveMandateCreate = #"""
{"id":"00000000-0000-4000-8000-000000000010","household_id":"00000000-0000-4000-8000-000000000002","label":"Weekly groceries","merchant_ids":null,"categories":["dairy","pantry","produce"],"currency":"USD","max_per_txn_cents":2500,"max_per_period_cents":20000,"period":"month","require_confirm_above_cents":1500,"expires_at":"2026-11-08T09:04:41.553534Z","status":"active","revoked_at":null,"revoked_reason":null,"period_started_at":"2026-10-01T00:00:00-07:00","spent_this_period_cents":0,"created_at":"2026-10-18T16:37:44.590114Z"}
"""#
    static let liveState = #"""
{"autonomy_level":"buy_with_approval","paused":false,"paused_at":null,"active_mandates":1,"pending_approvals":1}
"""#
    static let livePause = #"""
{"paused":true,"paused_at":"2026-10-18T16:37:35.135018Z","mandates_revoked":1,"intents_cancelled":1,"in_flight":0}
"""#
    static let liveResume = #"""
{"paused":false,"paused_at":null,"mandates_revoked":0,"intents_cancelled":0,"in_flight":0}
"""#
    static let liveBudgets = #"""
[{"id":"00000000-0000-4000-8000-000000000011","household_id":"00000000-0000-4000-8000-000000000002","period":"month","category":null,"limit_cents":60000,"currency":"USD","status":"active","starts_on":"2026-10-18","period_started_at":"2026-10-01T00:00:00-07:00","spent_cents":3922,"pending_cents":0,"remaining_cents":56078,"created_at":"2026-10-18T09:04:41.553627Z","updated_at":"2026-10-18T09:04:41.553627Z"}]
"""#
    static let liveSpend = #"""
{"household_id":"00000000-0000-4000-8000-000000000002","period":"month","group":"category","start":"2026-10-01T00:00:00-07:00","end":"2026-11-01T00:00:00-07:00","currency":"USD","total_cents":3922,"groups":[{"key":"pantry","label":"pantry","amount_cents":1499,"entries":1},{"key":"dairy","label":"dairy","amount_cents":1298,"entries":1},{"key":"produce","label":"produce","amount_cents":1125,"entries":1}],"budgets":[{"id":"00000000-0000-4000-8000-000000000011","household_id":"00000000-0000-4000-8000-000000000002","period":"month","category":null,"limit_cents":60000,"currency":"USD","status":"active","starts_on":"2026-10-18","period_started_at":"2026-10-01T00:00:00-07:00","spent_cents":3922,"pending_cents":0,"remaining_cents":56078,"created_at":"2026-10-18T09:04:41.553627Z","updated_at":"2026-10-18T09:04:41.553627Z"}]}
"""#

    static func intent(id: UUID = UUID(), status: String = "proposed", decision: String = "needs_approval", mine: Bool = true,
                       execution: String = "agora", decidedBy: String? = nil, orderID: UUID? = nil, title: String = "Sparkling water") -> [String: Any] {
        ["id": id.uuidString, "household_id": "00000000-0000-4000-8000-000000000002", "kind": "purchase", "execution": execution,
         "title": title, "payload": ["quantity": 1, "payment_method_ref": "sim_visa_4242"], "amount_cents": 699,
         "final_amount_cents": status == "succeeded" ? 699 : NSNull(), "currency": "USD", "merchant_id": NSNull(),
         "merchant_name": "PCC Community Markets", "category": "pantry", "rationale": "You asked.", "evidence": [],
         "decision": decision, "decision_reasons": decision == "deny" ? ["You paused your agent. Resume it to let it act again."]
                                                                      : ["Your agent is set to Buy with approval, so every purchase needs your OK."],
         "reason_codes": decision == "deny" ? ["agent_paused"] : ["autonomy_requires_approval"], "mandate_id": NSNull(),
         "status": status, "decided_by": decidedBy ?? NSNull(), "decided_at": NSNull(), "reject_reason": NSNull(),
         "error_code": NSNull(), "order_id": orderID?.uuidString ?? NSNull(), "mine": mine,
         "approval_expires_at": status == "proposed" ? ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600 * 23 + 60)) : NSNull(),
         "created_at": "2026-10-18T16:37:27.664866Z", "updated_at": "2026-10-18T16:37:27.664866Z", "completed_at": NSNull()]
    }
    static let mandate: [String: Any] = try! JSONSerialization.jsonObject(with: Data(liveMandateCreate.utf8)) as! [String: Any]
    static func state(paused: Bool = false, pending: Int = 1, mandates: Int = 1) -> [String: Any] {
        ["autonomy_level": "buy_with_approval", "paused": paused, "paused_at": paused ? "2026-10-18T16:37:35.135018Z" : NSNull(),
         "active_mandates": mandates, "pending_approvals": pending]
    }
    static let budget: [String: Any] = (try! JSONSerialization.jsonObject(with: Data(liveBudgets.utf8)) as! [[String: Any]])[0]
    static let spend: [String: Any] = try! JSONSerialization.jsonObject(with: Data(liveSpend.utf8)) as! [String: Any]
}

@MainActor
private final class CommerceGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "commerce-alex", email: "alex@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "unused" }
    func idToken(for accountID: String) async throws -> String { "commerce-token" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class CommerceHTTP: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any?))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var stopped = false
    private let lock = NSLock()
    override func startLoading() {
        // The stub's state lives on the main actor; answer from there, as ShoppingTests' stub does.
        DispatchQueue.main.async { [self] in
            let (status, value) = Self.handler(request)
            lock.lock(); defer { lock.unlock() }; guard !stopped else { return }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            if let value { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value)) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}

private func commerceBody(_ request: URLRequest) -> [String: Any] {
    var data = request.httpBody ?? Data()
    if data.isEmpty, let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

@MainActor
private final class PurchaseModel: ModelClient {
    let identity = ModelIdentity(provider: .openAICompatible, model: "purchase-fixture")
    let capabilities = ModelCapabilities(tools: true)
    let handler: (ModelRequest) async throws -> ModelResponse
    init(handler: @escaping (ModelRequest) async throws -> ModelResponse) { self.handler = handler }
    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        try await handler(request)
    }
}

@MainActor
final class CommerceTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var session: URLSession!
    private var store: CommerceStore!
    /// The server's state for the stub: what GETs return.
    private var inbox: [[String: Any]] = []
    private var recent: [[String: Any]] = []
    private var mandates: [[String: Any]] = []
    private var serverState: [String: Any] = CommerceFixtures.state()
    private var requests: [URLRequest] = []
    /// Extra routes, checked first: return nil to fall through.
    private var route: ((URLRequest) -> (Int, Any?)?)?

    override func setUp() async throws {
        calendar = CalendarConnection(authorization: CommerceGoogle()); await calendar.refresh()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CommerceHTTP.self]
        session = URLSession(configuration: config)
        let api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://commerce.example.com"), http: session)
        store = CommerceStore(api: api)
        inbox = [CommerceFixtures.intent()]
        recent = [CommerceFixtures.intent(status: "succeeded", decidedBy: "user", orderID: UUID(), title: "Milk and eggs")]
        mandates = [CommerceFixtures.mandate]
        serverState = CommerceFixtures.state()
        requests = []; route = nil
        CommerceHTTP.handler = { [unowned self] request in
            MainActor.assumeIsolated {
                self.requests.append(request)
                if let answer = self.route?(request) { return answer }
                let path = request.url!.path
                let statuses = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "status" }.compactMap(\.value) ?? []
                switch (request.httpMethod ?? "GET", path) {
                case ("GET", "/v1/agent/state"): return (200, self.serverState)
                case ("GET", "/v1/agent/intents"): return (200, statuses == ["proposed"] ? self.inbox : self.recent)
                case ("GET", "/v1/agent/mandates"): return (200, self.mandates)
                case ("GET", "/v1/budgets"): return (200, [CommerceFixtures.budget])
                case ("GET", "/v1/spend"): return (200, CommerceFixtures.spend)
                default: return (404, ["title": "not_found", "detail": "Not found.", "status": 404])
                }
            }
        }
    }

    override func tearDown() async throws {
        session.invalidateAndCancel(); CommerceHTTP.handler = nil
        store = nil; calendar = nil
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try AgoraClient.decoder().decode(type, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testDecodesDocumentedResponses() throws {
        let allowed = try decode(AgentIntent.self, CommerceFixtures.docPropose)
        XCTAssertEqual(allowed.decision, "allow"); XCTAssertEqual(allowed.status, "approved")
        XCTAssertEqual(allowed.decisionReasons.first, "Within your 'Weekly groceries' mandate: $8.98 of $50.00 allowed per purchase.")
        XCTAssertEqual(allowed.evidence.count, 2); XCTAssertEqual(allowed.payload.quantity, 2)
        XCTAssertEqual(allowed.productURL?.host, "ballardmarket.example")
        let mandate = try decode(AgentMandate.self, CommerceFixtures.docMandate)
        XCTAssertEqual(mandate.maxPerTxnCents, 5000); XCTAssertEqual(mandate.period, "week")
        XCTAssertEqual(CommerceText.limits(mandate), "Up to $50 per purchase · $150 per week")
        let pause = try decode(AgentPauseResult.self, CommerceFixtures.docPause)
        XCTAssertTrue(pause.paused); XCTAssertEqual(pause.mandatesRevoked, 1)
        XCTAssertEqual(CommerceText.pauseResult(pause), "The assistant is paused. 1 spending authority revoked. 1 request cancelled.")
        let state = try decode(AgentState.self, CommerceFixtures.docState)
        XCTAssertFalse(state.paused); XCTAssertEqual(state.autonomyLevel, "buy_within_mandate")
        let budgets = try decode([SpendBudget].self, CommerceFixtures.docBudgets)
        XCTAssertTrue(budgets[0].isOver); XCTAssertEqual(budgets[0].remainingCents, -298)
    }

    func testDecodesLiveDemoResponses() throws {
        let intents = try decode([AgentIntent].self, CommerceFixtures.liveIntents)
        XCTAssertEqual(intents.count, 3); XCTAssertEqual(intents[0].status, "proposed")
        let proposed = try decode(AgentIntent.self, CommerceFixtures.livePropose)
        XCTAssertEqual(proposed.decision, "needs_approval"); XCTAssertTrue(proposed.isAgoraCheckout)
        XCTAssertNotNil(proposed.approvalExpiresAt)
        let approved = try decode(AgentIntent.self, CommerceFixtures.liveApprove)
        XCTAssertEqual(approved.status, "succeeded"); XCTAssertNotNil(approved.orderId); XCTAssertEqual(approved.finalAmountCents, 699)
        XCTAssertEqual(CommerceText.outcome(approved), "Bought Sparkling water, 12 pack for $6.99 at PCC Community Markets.")
        XCTAssertEqual(try decode([AgentMandate].self, CommerceFixtures.liveMandates).first?.label, "Weekly groceries")
        XCTAssertTrue(try decode(AgentMandate.self, CommerceFixtures.liveMandateCreate).isActive)
        XCTAssertEqual(try decode(AgentState.self, CommerceFixtures.liveState).pendingApprovals, 1)
        XCTAssertTrue(try decode(AgentPauseResult.self, CommerceFixtures.livePause).paused)
        XCTAssertFalse(try decode(AgentPauseResult.self, CommerceFixtures.liveResume).paused)
        XCTAssertEqual(try decode([SpendBudget].self, CommerceFixtures.liveBudgets).first?.limitCents, 60000)
        let spend = try decode(SpendSummary.self, CommerceFixtures.liveSpend)
        XCTAssertEqual(spend.groups.count, 3); XCTAssertEqual(spend.budgets.count, 1)
    }

    func testIntentLabelsAndPaymentCard() throws {
        let data = try JSONSerialization.data(withJSONObject: CommerceFixtures.intent())
        let intent = try AgoraClient.decoder().decode(AgentIntent.self, from: data)
        XCTAssertEqual(intent.paymentLabel, "Visa ending 4242")
        XCTAssertTrue(intent.canApprove())
        XCTAssertEqual(CommerceText.approvalWindow(intent), "Expires in 23 h")
        XCTAssertEqual(CommerceText.status(intent), "Waiting for you")
        let blocked = try AgoraClient.decoder().decode(AgentIntent.self, from: JSONSerialization.data(withJSONObject:
            CommerceFixtures.intent(status: "rejected", decision: "deny", decidedBy: "policy")))
        XCTAssertEqual(CommerceText.status(blocked), "Blocked")
        XCTAssertEqual(CommerceText.outcome(blocked), "Blocked: You paused your agent. Resume it to let it act again.")
        let theirs = try AgoraClient.decoder().decode(AgentIntent.self, from: JSONSerialization.data(withJSONObject: CommerceFixtures.intent(mine: false)))
        XCTAssertFalse(theirs.canApprove())
    }

    // MARK: Store

    func testRefreshLoadsEverySection() async {
        await store.refresh()
        XCTAssertNil(store.error)
        XCTAssertEqual(store.inbox.count, 1); XCTAssertEqual(store.recent.count, 1)
        XCTAssertEqual(store.activeMandates.count, 1); XCTAssertEqual(store.budgets.count, 1)
        XCTAssertEqual(store.spend?.totalCents, 3922); XCTAssertEqual(store.pendingApprovals, 1)
    }

    func testApproveRefreshesTheInbox() async throws {
        await store.refresh()
        let pending = try XCTUnwrap(store.inbox.first)
        let done = CommerceFixtures.intent(id: pending.id, status: "succeeded", decidedBy: "user", orderID: UUID())
        route = { [unowned self] request in
            guard request.httpMethod == "POST", request.url!.path == "/v1/agent/intents/\(pending.id.uuidString)/approve" else { return nil }
            self.inbox = []; self.recent = [done]; self.serverState = CommerceFixtures.state(pending: 0)
            return (200, done)
        }
        let result = try await store.approve(pending)
        XCTAssertEqual(result.status, "succeeded")
        XCTAssertTrue(store.inbox.isEmpty); XCTAssertEqual(store.recent.first?.id, pending.id); XCTAssertEqual(store.pendingApprovals, 0)
        let approveIndex = try XCTUnwrap(requests.firstIndex { $0.httpMethod == "POST" })
        XCTAssertTrue(requests[(approveIndex + 1)...].contains { $0.url!.path == "/v1/agent/intents" }, "approve refetches the inbox")
    }

    func testRejectSendsTheReasonCode() async throws {
        await store.refresh()
        let pending = try XCTUnwrap(store.inbox.first)
        var body: [String: Any] = [:]
        route = { request in
            guard request.httpMethod == "POST" else { return nil }
            body = commerceBody(request)
            return (200, CommerceFixtures.intent(id: pending.id, status: "rejected", decidedBy: "user"))
        }
        let result = try await store.reject(pending, reason: "too_expensive")
        XCTAssertEqual(result.status, "rejected"); XCTAssertEqual(body["reason_code"] as? String, "too_expensive")
    }

    func testPauseSetsPausedAndClearsMandates() async {
        await store.refresh()
        XCTAssertEqual(store.activeMandates.count, 1)
        route = { [unowned self] request in
            guard request.httpMethod == "POST", request.url!.path == "/v1/agent/pause" else { return nil }
            self.mandates = []; self.inbox = []; self.serverState = CommerceFixtures.state(paused: true, pending: 0, mandates: 0)
            return (200, try! JSONSerialization.jsonObject(with: Data(CommerceFixtures.livePause.utf8)))
        }
        await store.pause()
        XCTAssertTrue(store.paused); XCTAssertTrue(store.activeMandates.isEmpty); XCTAssertTrue(store.inbox.isEmpty)
        XCTAssertEqual(store.notice, "The assistant is paused. 1 spending authority revoked. 1 request cancelled.")
        route = { [unowned self] request in
            guard request.httpMethod == "POST", request.url!.path == "/v1/agent/resume" else { return nil }
            self.serverState = CommerceFixtures.state(paused: false, pending: 0, mandates: 0)
            return (200, try! JSONSerialization.jsonObject(with: Data(CommerceFixtures.liveResume.utf8)))
        }
        await store.resume()
        XCTAssertFalse(store.paused); XCTAssertTrue(store.activeMandates.isEmpty, "mandates stay revoked after resume")
        XCTAssertTrue(store.notice?.contains("stays revoked") == true)
    }

    func testPauseLocallyEvenWhenTheRefreshFails() async {
        await store.refresh()
        route = { request in
            if request.httpMethod == "POST" { return (200, try! JSONSerialization.jsonObject(with: Data(CommerceFixtures.livePause.utf8))) }
            return (500, ["title": "agora_unavailable", "detail": "Try again.", "status": 500])
        }
        await store.pause()
        XCTAssertTrue(store.paused); XCTAssertTrue(store.activeMandates.isEmpty)
    }

    func testIdempotencyKeyIsReusedOnRetryAndNewPerAction() async throws {
        await store.refresh()
        let pending = try XCTUnwrap(store.inbox.first)
        var keys: [String] = [], fail = true
        route = { request in
            guard request.httpMethod == "POST" else { return nil }
            keys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            if fail { return (500, ["title": "agora_unavailable", "detail": "Try again.", "status": 500]) }
            if request.url!.path == "/v1/agent/intents" { return (201, CommerceFixtures.intent(id: UUID())) }
            return (200, CommerceFixtures.intent(id: pending.id, status: "succeeded", decidedBy: "user", orderID: UUID()))
        }
        do { _ = try await store.approve(pending); XCTFail("expected failure") } catch {}
        fail = false
        _ = try await store.approve(pending)
        XCTAssertEqual(keys.count, 2); XCTAssertEqual(keys[0], keys[1], "a retry reuses the key")

        let proposal = PurchaseProposal(title: "Oat milk", amountCents: 499, rationale: "You asked.")
        _ = try await store.propose(proposal, action: "wishlist:a")
        _ = try await store.propose(proposal, action: "wishlist:b")
        _ = try await store.propose(proposal, action: "wishlist:a")
        XCTAssertEqual(Set(keys[2...]).count, 3, "each new action gets its own key")
        XCTAssertFalse(keys[2...].contains(keys[0]))
    }

    func testProposalBodyIsAnAgoraCheckout() throws {
        let body = PurchaseProposal(title: "Olive oil", amountCents: 1899, merchantName: "PCC Community Markets", category: "Pantry",
                                    url: "http://insecure.example", itemKey: "wishlist:1", rationale: "You asked.").body(householdID: nil)
        XCTAssertEqual(body["kind"] as? String, "purchase"); XCTAssertEqual(body["execution"] as? String, "agora")
        XCTAssertEqual(body["amount_cents"] as? Int, 1899); XCTAssertEqual(body["category"] as? String, "pantry")
        XCTAssertNil(body["url"]); XCTAssertNil(body["item_key"], "the API has no item_key field; it travels in details")
        XCTAssertEqual((body["details"] as? [String: String])?["item_key"], "wishlist:1")
    }

    func testMandateDraftValidation() throws {
        var draft = MandateDraft()
        XCTAssertThrowsError(try draft.body(householdID: nil))
        draft.label = "Weekly groceries"; draft.maxPerPurchase = "$25"; draft.periodLimit = "20"
        XCTAssertThrowsError(try draft.body(householdID: nil)) { XCTAssertEqual($0 as? MandateDraft.Problem, .periodLimit) }
        draft.periodLimit = "200"; draft.confirmAbove = "15.5"; draft.categories = ["Dairy"]; draft.period = "week"
        let body = try draft.body(householdID: nil)
        XCTAssertEqual(body["max_per_txn_cents"] as? Int, 2500); XCTAssertEqual(body["max_per_period_cents"] as? Int, 20000)
        XCTAssertEqual(body["require_confirm_above_cents"] as? Int, 1550); XCTAssertEqual(body["categories"] as? [String], ["dairy"])
        XCTAssertEqual(body["expires_in_days"] as? Int, 30)
        XCTAssertNil(MandateDraft.cents("0")); XCTAssertNil(MandateDraft.cents("abc")); XCTAssertEqual(MandateDraft.cents("1,000"), 100000)
    }

    func testWishlistPurchaseUsesFoundPriceElseTarget() throws {
        let item = try AgoraClient.decoder().decode(WishlistItem.self, from: JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString, "household_id": UUID().uuidString, "title": "Olive oil", "quantity": 2, "category": "pantry",
            "target_price_cents": 1500, "source": "user", "status": "active", "pinned": false, "evidence": [], "score": 1,
            "priority_reasons": [], "created_at": "2026-10-17T19:00:00Z"]))
        let found = try XCTUnwrap(WishlistPurchase.proposal(item: item, price: (merchant: "QFC", cents: 1299, url: "https://qfc.example/oil")))
        XCTAssertEqual(found.amountCents, 2598); XCTAssertEqual(found.merchantName, "QFC"); XCTAssertEqual(found.quantity, 2)
        XCTAssertEqual(found.itemKey, "wishlist:\(item.id.uuidString.lowercased())")
        let target = try XCTUnwrap(WishlistPurchase.proposal(item: item, price: nil))
        XCTAssertEqual(target.amountCents, 3000); XCTAssertNil(target.merchantName)
    }

    // MARK: Routing

    func testSpendingIsAHouseholdPageOnHome() {
        XCTAssertEqual(Route.household(.spending), Route.household(.spending))
        XCTAssertNotEqual(Route.household(.spending), Route.household(.wishlist))
        let entry = HouseholdCards.entries.first { $0.page == .spending }
        XCTAssertEqual(entry?.title, "Spending"); XCTAssertEqual(entry?.detail, "Approvals, limits and budget")
        XCTAssertEqual(entry?.symbol, "creditcard"); XCTAssertEqual(HouseholdCards.entries.count, 5)
        XCTAssertNil(HouseholdCards.approvalBadge(0)); XCTAssertEqual(HouseholdCards.approvalBadge(2), "2")
        XCTAssertEqual(HouseholdCards.approvalBadge(120), "99+")
    }

    // MARK: Chat tool

    func testPurchaseToolValidatesModelArguments() throws {
        let ok = try PurchaseCall(["name": "purchase_request", "args": ["title": " Olive oil ", "amount_cents": 1899,
                                                                      "merchant_name": "PCC Community Markets", "category": "Pantry"]])
        XCTAssertEqual(ok.proposal.title, "Olive oil"); XCTAssertEqual(ok.proposal.category, "pantry")
        XCTAssertEqual(ok.approvalTitle, "Buy Olive oil for $18.99 at PCC Community Markets?")
        let bad: [[String: Any]] = [
            ["title": "Oil", "amount_cents": true], ["title": "Oil", "amount_cents": 18.5], ["title": "Oil", "amount_cents": 0],
            ["title": "Oil", "amount_cents": "1899"], ["title": "", "amount_cents": 100], ["title": "Oil"],
            ["title": "Oil", "amount_cents": 100, "url": "http://shop.example"], ["title": "Oil", "amount_cents": 100, "payment_method_ref": "sim_visa_4242"],
        ]
        for args in bad { XCTAssertThrowsError(try PurchaseCall(["name": "purchase_request", "args": args]), "\(args)") }
        let task = UUID()
        XCTAssertEqual(try ok.requestKey(taskID: task), try ok.requestKey(taskID: task))
        XCTAssertNotEqual(try ok.requestKey(taskID: task), try ok.requestKey(taskID: UUID()))
        XCTAssertLessThanOrEqual(try ok.requestKey(taskID: task).count, 128)
        let schema = PurchaseCall.schema
        XCTAssertTrue((schema["description"] as? String)?.contains("ONLY when the user clearly and explicitly asks") == true)
        XCTAssertNoThrow(try ModelToolDefinition(legacy: schema))
    }

    func testPurchaseToolResultCarriesBackendReasons() throws {
        let denied = try AgoraClient.decoder().decode(AgentIntent.self, from: JSONSerialization.data(withJSONObject:
            CommerceFixtures.intent(status: "rejected", decision: "deny", decidedBy: "policy")))
        let result = PurchaseCall.result(denied)
        XCTAssertEqual(result["reasons"] as? [String], ["You paused your agent. Resume it to let it act again."])
        XCTAssertTrue((result["instruction"] as? String)?.contains("Do not retry") == true)
    }

    private func agent(model: PurchaseModel) -> AgentCoordinator {
        let suite = "commerce-tests-" + UUID().uuidString
        let settings = SettingsStore(keychainService: suite, defaults: UserDefaults(suiteName: suite)!)
        let agent = AgentCoordinator(settings: settings, browser: BrowserSession(policy: settings.policy), calendar: calendar, commerce: store)
        agent.modelClientOverride = model
        return agent
    }

    private func purchaseModel(_ results: @escaping ([String: Any]) -> Void) -> PurchaseModel {
        PurchaseModel { request in
            XCTAssertTrue(request.tools.contains { $0.name == "purchase_request" })
            if let result = request.messages.last?.toolResults.last {
                results(result.value.foundation as? [String: Any] ?? [:])
                return ModelResponse(message: .init(role: .assistant, content: [.text("Done.")]))
            }
            return ModelResponse(message: .init(role: .assistant, toolCalls: [
                .init(id: "buy-1", name: "purchase_request", arguments: ["title": .string("Sparkling water"), "amount_cents": .number(699),
                                                                          "merchant_name": .string("PCC Community Markets")])
            ]))
        }
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testChatPurchaseNeedingApprovalAsksThenApproves() async throws {
        let intentID = UUID()
        var posts: [String] = [], keys: [String] = []
        route = { request in
            guard request.httpMethod == "POST" else { return nil }
            posts.append(request.url!.path); keys.append(request.value(forHTTPHeaderField: "Idempotency-Key") ?? "")
            if request.url!.path == "/v1/agent/intents" {
                let body = commerceBody(request)
                XCTAssertEqual(body["execution"] as? String, "agora"); XCTAssertEqual(body["amount_cents"] as? Int, 699)
                return (201, CommerceFixtures.intent(id: intentID))
            }
            return (200, CommerceFixtures.intent(id: intentID, status: "succeeded", decidedBy: "user", orderID: UUID()))
        }
        var toolResult: [String: Any]?
        let agent = agent(model: purchaseModel { toolResult = $0 })
        XCTAssertTrue(agent.send("Buy sparkling water for $6.99"))
        try await waitUntil { agent.approval != nil }
        XCTAssertEqual(agent.approval?.title, "Buy Sparkling water for $6.99 at PCC Community Markets?")
        XCTAssertTrue(agent.approval?.detail.contains("Your agent is set to Buy with approval, so every purchase needs your OK.") == true)
        XCTAssertTrue(agent.approval?.detail.contains("Visa ending 4242") == true)
        agent.resolveApproval(true)
        try await waitUntil { !agent.running }
        XCTAssertEqual(posts, ["/v1/agent/intents", "/v1/agent/intents/\(intentID.uuidString)/approve"])
        XCTAssertTrue(keys[0].hasPrefix("chat-"))
        XCTAssertEqual(toolResult?["status"] as? String, "succeeded"); XCTAssertEqual(toolResult?["user_decision"] as? String, "approved")
        XCTAssertEqual(toolResult?["order_placed"] as? Bool, true)
    }

    func testChatPurchaseRejectedByUserIsReported() async throws {
        let intentID = UUID()
        var posts: [String] = []
        route = { request in
            guard request.httpMethod == "POST" else { return nil }
            posts.append(request.url!.path)
            if request.url!.path == "/v1/agent/intents" { return (201, CommerceFixtures.intent(id: intentID)) }
            return (200, CommerceFixtures.intent(id: intentID, status: "rejected", decidedBy: "user"))
        }
        var toolResult: [String: Any]?
        let agent = agent(model: purchaseModel { toolResult = $0 })
        XCTAssertTrue(agent.send("Buy sparkling water for $6.99"))
        try await waitUntil { agent.approval != nil }
        agent.resolveApproval(false)
        try await waitUntil { !agent.running }
        XCTAssertEqual(posts.last, "/v1/agent/intents/\(intentID.uuidString)/reject")
        XCTAssertEqual(toolResult?["user_decision"] as? String, "rejected")
        XCTAssertTrue((toolResult?["instruction"] as? String)?.contains("Do not retry") == true)
    }

    func testChatPurchaseDeniedReturnsReasonsWithoutAsking() async throws {
        route = { request in
            guard request.httpMethod == "POST" else { return nil }
            return (201, CommerceFixtures.intent(status: "rejected", decision: "deny", decidedBy: "policy"))
        }
        var toolResult: [String: Any]?
        let agent = agent(model: purchaseModel { toolResult = $0 })
        XCTAssertTrue(agent.send("Buy sparkling water for $6.99"))
        try await waitUntil { !agent.running }
        XCTAssertNil(agent.approval)
        XCTAssertFalse(agent.messages.contains { $0.role == "approval" })
        XCTAssertEqual(toolResult?["reasons"] as? [String], ["You paused your agent. Resume it to let it act again."])
    }

    func testDemoGrammarRecognisesAPurchaseRequest() throws {
        let match = try XCTUnwrap(DemoModelClient.purchaseArguments("Buy olive oil for $18.99 at QFC"))
        XCTAssertEqual(match.title, "olive oil"); XCTAssertEqual(match.cents, 1899); XCTAssertEqual(match.merchant, "QFC")
        let noPrice = try XCTUnwrap(DemoModelClient.purchaseArguments("buy milk"))
        XCTAssertEqual(noPrice.title, "milk"); XCTAssertNil(noPrice.cents)
        XCTAssertNil(DemoModelClient.purchaseArguments("add eggs to my shopping list"))
    }

    // MARK: Rendering

    func testSpendingPageAndApprovalSheetRender() async throws {
        await store.refresh()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 1900)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let pending = try XCTUnwrap(store.inbox.first)
        let pages: [(String, AnyView)] = [
            ("spending", AnyView(NavigationStack { SpendingView(store: store) })),
            ("approval", AnyView(ApprovalSheet(store: store, intent: pending))),
            ("mandate", AnyView(MandateEditor(store: store))),
        ]
        for (name, page) in pages {
            let host = UIHostingController(rootView: page)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("commerce-\(name).png")
            try image.pngData()?.write(to: url)
            print("RENDERED \(url.path)")
        }
    }
}
