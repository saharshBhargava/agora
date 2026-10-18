import Foundation
import Combine

/// The agent-commerce state behind the Spending page, the home row's approval count, the wishlist's
/// "Buy with the assistant" and the chat's `purchase_request` tool. Every decision is the backend's: this
/// store only proposes, approves, rejects, grants, revokes, pauses and resumes, then refetches.
///
/// Idempotency: each user action gets a fresh `Idempotency-Key`, kept until that action succeeds, so a
/// retry after a dropped connection reuses it and the server never decides or charges twice.
@MainActor
final class CommerceStore: ObservableObject {
    @Published private(set) var state: AgentState?
    /// Proposed intents (the approval inbox), newest first.
    @Published private(set) var inbox: [AgentIntent] = []
    /// Everything else the assistant asked for, newest first.
    @Published private(set) var recent: [AgentIntent] = []
    @Published private(set) var mandates: [AgentMandate] = []
    @Published private(set) var budgets: [SpendBudget] = []
    @Published private(set) var spend: SpendSummary?
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published var notice: String?
    @Published private(set) var context = UUID()

    private let api: AgoraClient
    private let usesHousehold: Bool
    private var householdID: UUID?
    private var subscription: AnyCancellable?
    private var keys: [String: String] = [:]
    private var loadID = UUID()

    init(api: AgoraClient, inventory: InventoryStore? = nil) {
        self.api = api
        usesHousehold = inventory != nil
        subscription = inventory?.$householdID.combineLatest(inventory!.$context)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] household, _ in
                guard let self else { return }
                self.householdID = household; self.context = UUID(); self.loadID = UUID()
                self.state = nil; self.inbox = []; self.recent = []; self.mandates = []; self.budgets = []; self.spend = nil
                self.loading = false; self.loaded = false; self.busy = false; self.error = nil; self.notice = nil; self.keys = [:]
            }
    }

    var canUse: Bool { !usesHousehold || householdID != nil }
    var paused: Bool { state?.paused == true }
    /// Approvals waiting on this person (the home row's pill).
    var pendingApprovals: Int { state?.pendingApprovals ?? inbox.filter(\.mine).count }
    var activeMandates: [AgentMandate] { mandates.filter(\.isActive) }
    /// Mandates only take effect at "Buy within mandate"; below it every purchase asks.
    var mandatesApply: Bool { state?.autonomyLevel == "buy_within_mandate" }

    private var householdQuery: [URLQueryItem] {
        householdID.map { [URLQueryItem(name: "household_id", value: $0.uuidString)] } ?? []
    }

    // MARK: Idempotency keys

    /// The key for one user action: the same until the action succeeds, then a new one next time.
    func key(for action: String) -> String {
        if let key = keys[action] { return key }
        let key = UUID().uuidString
        keys[action] = key
        return key
    }

    private func finished(_ action: String) { keys[action] = nil }

    // MARK: Loading

    func refreshState() async {
        guard canUse else { return }
        let version = context
        do {
            let value = try await api.fetch("v1/agent/state", as: AgentState.self)
            guard version == context else { return }
            state = value
        } catch {
            // The home pill stays hidden when the state can't be read; the page shows the error itself.
        }
    }

    func refresh() async {
        guard canUse else { return }
        let version = context, request = UUID()
        loadID = request; loading = true
        defer { if loadID == request { loading = false } }
        do {
            async let stateValue = api.fetch("v1/agent/state", as: AgentState.self)
            async let inboxValue = api.fetch("v1/agent/intents", as: [AgentIntent].self,
                                             query: householdQuery + [.init(name: "status", value: "proposed")])
            async let recentValue = api.fetch("v1/agent/intents", as: [AgentIntent].self,
                                              query: householdQuery + Self.settledStatuses.map { .init(name: "status", value: $0) } + [.init(name: "limit", value: "12")])
            async let mandateValue = api.fetch("v1/agent/mandates", as: [AgentMandate].self, query: householdQuery)
            async let budgetValue = api.fetch("v1/budgets", as: [SpendBudget].self, query: householdQuery)
            async let spendValue = api.fetch("v1/spend", as: SpendSummary.self,
                                             query: householdQuery + [.init(name: "period", value: "month"), .init(name: "group", value: "category")])
            let values = try await (stateValue, inboxValue, recentValue, mandateValue, budgetValue, spendValue)
            guard version == context, loadID == request else { return }
            state = values.0; inbox = values.1; recent = values.2; mandates = values.3; budgets = values.4; spend = values.5
            loaded = true; error = nil
        } catch {
            guard version == context, loadID == request, !Task.isCancelled else { return }
            self.error = Self.message(error)
        }
    }

    static let settledStatuses = ["approved", "executing", "succeeded", "failed", "outcome_unknown", "rejected", "cancelled"]

    // MARK: Intents

    /// Proposes a purchase for one user action (`action` names it, e.g. "wishlist:<item id>"), reusing that
    /// action's key on retry. Returns the backend's decision; the caller shows it as-is.
    func propose(_ proposal: PurchaseProposal, action: String) async throws -> AgentIntent {
        let key = key(for: "propose:\(action)")
        let intent = try await propose(proposal, key: key)
        finished("propose:\(action)")
        return intent
    }

    /// Proposes with a caller-owned key (the chat tool derives one per tool call).
    func propose(_ proposal: PurchaseProposal, key: String) async throws -> AgentIntent {
        let version = context
        let intent = try await api.fetch("v1/agent/intents", as: AgentIntent.self, method: "POST",
                                         body: proposal.body(householdID: householdID), key: key)
        guard version == context else { throw CancellationError() }
        await refresh()
        return intent
    }

    func approve(_ intent: AgentIntent) async throws -> AgentIntent {
        try await decide(intent, path: "approve", body: nil)
    }

    func reject(_ intent: AgentIntent, reason: String?) async throws -> AgentIntent {
        try await decide(intent, path: "reject", body: reason.map { ["reason_code": $0] } ?? [:])
    }

    private func decide(_ intent: AgentIntent, path: String, body: [String: Any]?) async throws -> AgentIntent {
        let action = "\(path):\(intent.id.uuidString)"
        let version = context
        busy = true
        defer { if version == context { busy = false } }
        do {
            let result = try await api.fetch("v1/agent/intents/\(intent.id.uuidString)/\(path)", as: AgentIntent.self,
                                             method: "POST", body: body, key: key(for: action))
            guard version == context else { throw CancellationError() }
            finished(action)
            await refresh()
            return result
        } catch let failure as BrowserError where failure.status == 409 || failure.status == 403 {
            // Another device acted, the approval expired, or the assistant was paused: show the current state.
            finished(action)
            await refresh()
            throw failure
        }
    }

    // MARK: Mandates

    func grant(_ draft: MandateDraft) async throws -> AgentMandate {
        let version = context
        busy = true
        defer { if version == context { busy = false } }
        let mandate = try await api.fetch("v1/agent/mandates", as: AgentMandate.self, method: "POST",
                                          body: try draft.body(householdID: householdID))
        guard version == context else { throw CancellationError() }
        await refresh()
        return mandate
    }

    func revoke(_ mandate: AgentMandate) async {
        let version = context
        busy = true; error = nil
        defer { if version == context { busy = false } }
        do {
            _ = try await api.fetch("v1/agent/mandates/\(mandate.id.uuidString)", as: AgentMandate.self, method: "DELETE")
            guard version == context else { return }
            mandates.removeAll { $0.id == mandate.id }
            notice = "Revoked “\(mandate.label)”. The assistant asks before buying anything it covered."
            await refresh()
        } catch {
            if version == context, !Task.isCancelled { self.error = Self.message(error) }
        }
    }

    // MARK: Kill switch

    /// Pauses the assistant: the server revokes every mandate and cancels everything not yet started.
    func pause() async {
        let version = context
        busy = true; error = nil
        defer { if version == context { busy = false } }
        do {
            let result = try await api.fetch("v1/agent/pause", as: AgentPauseResult.self, method: "POST")
            guard version == context else { return }
            applyPaused(result)
            notice = CommerceText.pauseResult(result)
            await refresh()
        } catch {
            if version == context, !Task.isCancelled { self.error = Self.message(error) }
        }
    }

    func resume() async {
        let version = context
        busy = true; error = nil
        defer { if version == context { busy = false } }
        do {
            let result = try await api.fetch("v1/agent/resume", as: AgentPauseResult.self, method: "POST")
            guard version == context else { return }
            if let state {
                self.state = AgentState(autonomyLevel: state.autonomyLevel, paused: result.paused, pausedAt: result.pausedAt,
                                        activeMandates: state.activeMandates, pendingApprovals: state.pendingApprovals)
            }
            notice = "The assistant can act again. Spending authority you had stays revoked, so give it again when you're ready."
            await refresh()
        } catch {
            if version == context, !Task.isCancelled { self.error = Self.message(error) }
        }
    }

    private func applyPaused(_ result: AgentPauseResult) {
        let level = state?.autonomyLevel ?? "buy_with_approval"
        state = AgentState(autonomyLevel: level, paused: true, pausedAt: result.pausedAt, activeMandates: 0, pendingApprovals: 0)
        mandates = mandates.filter { !$0.isActive }
        inbox = []
    }

    static func message(_ error: Error) -> String {
        if let error = error as? BrowserError, !error.detail.isEmpty { return error.detail }
        if error is MandateDraft.Problem { return "Check the amounts and try again." }
        return "Couldn’t reach your household. Please try again."
    }
}
