import SwiftUI
import Combine

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String
    let text: String
}
struct ActionApproval: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor
final class AgentCoordinator: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var status = "Ready"
    @Published private(set) var approval: ActionApproval?
    let browser: BrowserSession
    private let settings: SettingsStore
    private let calendar: CalendarConnection?
    private let executor: BrowserToolExecutor
    private let repository = TaskRepository()
    private var history: [ModelMessage] = []
    private var settingsSubscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var calendarMutationInFlight: UUID?
    private var approvalReply: CheckedContinuation<Bool, Never>?
    var providerOverride: ModelProvider?
    var modelClientOverride: ModelClient?

    init(settings: SettingsStore, browser: BrowserSession, calendar: CalendarConnection? = nil) {
        self.calendar = calendar
        self.settings = settings; self.browser = browser; executor = BrowserToolExecutor(session: browser)
        browser.onHumanInteraction = { [weak self] in self?.stop(reason: "Paused for you. Press Resume when ready.", paused: true) }
        settingsSubscription = settings.$chatRevision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.stop(reason: "Chat model settings changed. Start a new task.")
            self.history.removeAll()
            if !self.messages.isEmpty { self.messages.append(ChatMessage(role: "notice", text: "Model settings changed. The next message starts a new conversation context.")) }
        }
        if repository.needsRecovery {
            messages.append(ChatMessage(role: "notice", text: "The previous task was interrupted. Inspect the website or Google Calendar before retrying any action; actions are never replayed automatically."))
        }
    }
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 16000, !running else { return }
        let provider: ModelClient
        do {
            if let modelClientOverride { provider = modelClientOverride }
            else if let providerOverride { provider = LegacyModelClient(providerOverride) }
            else { provider = try settings.client(for: .chat) }
        }
        catch { AppLog.failure(.agent, "task.start_failed", error: error); messages.append(ChatMessage(role: "notice", text: error.localizedDescription)); return }
        browser.policy = settings.policy
        messages.append(ChatMessage(role: "user", text: text))
        let id = UUID(); generation = id; running = true; paused = false; status = "Thinking…"
        let initial = history + [ModelMessage(role: .user, content: [.text(text)])]
        history = initial
        task = Task { [weak self] in
            await AppLog.$taskID.withValue(id.uuidString) {
                AppLog.event(.agent, "task.started")
                await self?.run(provider: provider, contents: initial, id: id)
            }
        }
    }
    func resolveApproval(_ allowed: Bool) {
        if approvalReply != nil { AppLog.$taskID.withValue(generation.uuidString) { AppLog.event(.agent, allowed ? "approval.allowed" : "approval.denied") } }
        approval = nil; let reply = approvalReply; approvalReply = nil; reply?.resume(returning: allowed)
    }
    func stop(reason: String = "Stopped. The browser is still available.", paused: Bool = false) {
        AppLog.$taskID.withValue(generation.uuidString) { AppLog.event(.agent, paused ? "task.paused" : "task.stopped", count: running ? 1 : 0) }
        let old = generation, wasRunning = running
        let uncertainCalendar = calendarMutationInFlight == old
        generation = UUID(); task?.cancel(); task = nil; calendarMutationInFlight = nil
        resolveApproval(false); browser.revoke(); running = false; self.paused = paused && !uncertainCalendar
        status = uncertainCalendar ? "A Calendar event may have been saved. Check Google Calendar before retrying." : reason
        browser.state.status = status
        if uncertainCalendar { messages.append(ChatMessage(role: "notice", text: status)) }
        if wasRunning { try? repository.record(task: old, operation: "task", phase: browser.state.busy || uncertainCalendar ? "outcome_unknown" : "stopped") }
    }
    func newChat() {
        AppLog.event(.agent, "chat.new")
        stop(); browser.close(); history.removeAll(); messages.removeAll(); paused = false; status = "Ready"
    }
    func closeBrowser() { stop(); browser.close() }
    func resume() {
        guard !running else { return }
        task = Task {
            do { try await browser.resume(); send("Resume the task. The user may have changed the browser; obtain fresh evidence before acting.") }
            catch { messages.append(ChatMessage(role: "notice", text: error.localizedDescription)) }
        }
    }
    private func requestApproval(_ call: BrowserCall) async -> Bool {
        let action = call.arguments["action"] as? String ?? "close browser"
        let value = call.arguments["text"] as? String
        let reference = call.arguments["elementId"] as? String
        let elements = browser.lastObservation["elements"] as? [[String: Any]] ?? []
        let target = elements.first { $0["id"] as? String == reference }?["name"] as? String ?? reference ?? "page"
        approval = ActionApproval(title: "Allow Agora to \(action)?", detail: "\(browser.state.title) · \(browser.state.url?.host ?? "Browser")\nTarget: \(target)\(value.map { "\nValue: \($0)" } ?? "")\nReview the page first. This approval applies once to this action.")
        AppLog.event(.agent, "approval.requested")
        status = "Waiting for your approval"
        return await withCheckedContinuation { approvalReply = $0 }
    }
    private func run(provider: ModelClient, contents initial: [ModelMessage], id: UUID) async {
        var contents = initial
        var failures = 0
        var turn = 0
        defer {
            if calendarMutationInFlight == id { calendarMutationInFlight = nil }
            if generation == id { running = false; task = nil; browser.state.status = status }
        }
        do {
            try repository.record(task: id, operation: "task", phase: "running")
            while true {
                turn += 1
                AppLog.event(.agent, "turn.started", count: turn)
                try Task.checkCancellation(); guard generation == id else { return }
                guard try contents.reduce(0, { try $0 + $1.byteCount() }) < 1_500_000 else { throw BrowserError("conversation_limit", "Start a new chat to continue.") }
                status = "Thinking…"
                let schemas = BrowserCall.schemas.filter { provider.capabilities.images || $0["name"] as? String != "browser_screenshot" } + (calendar?.connected == true ? CalendarCall.schemas : [])
                let request = ModelRequest(instructions: AgentInstructions.text, messages: contents,
                                           tools: try schemas.map { try ModelToolDefinition(legacy: $0) })
                let response = try await provider.generate(request, onEvent: { _ in })
                try validateModelResponse(response.message, request: request)
                try Task.checkCancellation(); guard generation == id else { return }
                contents.append(response.message)
                let text = response.text
                if !text.isEmpty { messages.append(ChatMessage(role: "assistant", text: text)) }
                let calls = response.message.toolCalls
                if calls.isEmpty {
                    AppLog.event(.agent, "task.completed")
                    history = contents; status = "Ready"
                    try repository.record(task: id, operation: "task", phase: "complete"); return
                }
                guard calls.count <= 8 else { throw BrowserError("tool_budget_exhausted") }
                var replies: [ModelToolResult] = []
                var images: [ModelContent] = []
                for modelCall in calls {
                    let raw = modelCall.raw
                    try Task.checkCancellation(); guard generation == id else { return }
                    var result: [String: Any]
                    do {
                        if let name = raw["name"] as? String, CalendarCall.names.contains(name) {
                            guard let calendar, calendar.connected else { throw BrowserError("calendar_reconnect_required") }
                            let approvedAccountID = calendar.accountID
                            let call = try CalendarCall(raw)
                            if call.name == "calendar_create_event" {
                                approval = ActionApproval(title: "Add this Google Calendar event?", detail: call.approvalDetail)
                                status = "Waiting for your approval"
                                let allowed = await withCheckedContinuation { approvalReply = $0 }
                                guard allowed else { throw BrowserError("approval_denied", "Do not retry this action.") }
                            }
                            try Task.checkCancellation(); guard generation == id else { return }
                            status = call.name == "calendar_create_event" ? "Adding Calendar event…" : "Checking availability…"
                            try repository.record(task: id, operation: call.name, phase: "dispatched")
                            if call.name == "calendar_create_event" { calendarMutationInFlight = id }
                            result = try await calendar.execute(call, taskID: id, expectedAccountID: approvedAccountID)
                            if calendarMutationInFlight == id { calendarMutationInFlight = nil }
                            try repository.record(task: id, operation: call.name, phase: "observed")
                        } else {
                            let call = try BrowserCall(raw)
                            if call.name == "browser_close" || (call.name == "browser_act" && !["click", "type", "scroll"].contains(call.arguments["action"] as? String ?? "")) {
                                let epoch = browser.epoch, lease = browser.lease, document = browser.documentEpoch
                                guard await requestApproval(call) else { throw BrowserError("approval_denied", "Do not retry this action.") }
                                try browser.check(epoch: epoch, lease: lease)
                                guard document == browser.documentEpoch else { throw BrowserError("stale_reference") }
                            }
                            status = call.name.replacingOccurrences(of: "browser_", with: "Browser: ")
                            browser.state.status = status
                            try repository.record(task: id, operation: call.name, phase: "dispatched")
                            result = try await executor.execute(call)
                            try repository.record(task: id, operation: call.name, phase: result["dispatched"] as? Bool == true ? "dispatched_unverified" : "observed")
                        }
                        failures = 0
                    } catch {
                        try Task.checkCancellation(); guard generation == id else { return }
                        if calendarMutationInFlight == id { calendarMutationInFlight = nil }
                        AppLog.failure(.agent, "tool.failed", error: error)
                        result = ["error": error.localizedDescription]; failures += 1
                        try repository.record(task: id, operation: raw["name"] as? String ?? "invalid_tool", phase: "failed_or_uncertain")
                        if error.localizedDescription.contains("outcome_unknown") { throw error }
                    }
                    try Task.checkCancellation(); guard generation == id else { return }
                    if let image = result.removeValue(forKey: "image") as? String, let data = Data(base64Encoded: image) {
                        images.append(.image(data, mimeType: "image/jpeg"))
                    }
                    replies.append(ModelToolResult(id: modelCall.id, name: modelCall.name, value: try ModelJSON.from(result)))
                }
                contents.append(ModelMessage(role: .user, content: images, toolResults: replies))
                history = contents // Only commit complete, correlated tool exchanges.
                if failures >= 3 { throw BrowserError("repeated_tool_errors", "Review the browser and try again.") }
            }
        } catch {
            guard generation == id, !Task.isCancelled else { return }
            AppLog.failure(.agent, "task.failed", error: error)
            status = error.localizedDescription
            messages.append(ChatMessage(role: "notice", text: status))
            try? repository.record(task: id, operation: "task", phase: status.contains("outcome_unknown") ? "outcome_unknown" : "failed")
        }
    }
}
