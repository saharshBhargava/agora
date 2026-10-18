import SwiftUI
import Combine

struct ActionApproval: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor
final class AgentCoordinator: ObservableObject {
    let conversations = ConversationStore()
    @Published var messages: [ChatMessage] = [] { didSet { conversations.current.messages = messages } }
    @Published private(set) var running = false
    @Published private(set) var paused = false
    @Published private(set) var status = "Ready"
    @Published private(set) var approval: ActionApproval? {
        didSet {
            guard let approval else { return }
            let row = ChatMessage(role: "approval", text: "")
            row.approval = ChatApprovalRecord(id: approval.id, title: approval.title, detail: approval.detail)
            messages.append(row)
        }
    }
    let browser: BrowserSession
    private let settings: SettingsStore
    private let calendar: CalendarConnection?
    private let shopping: ShoppingStore?
    private let trips: TripStore?
    private var householdSubscription: AnyCancellable?
    private var shoppingMutationInFlight: UUID?
    private let executor: BrowserToolExecutor
    private let repository = TaskRepository()
    private var history: [ModelMessage] {
        get { conversations.current.history }
        set { conversations.current.history = newValue }
    }
    private var accountSubscription: AnyCancellable?
    private var settingsSubscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var calendarMutationInFlight: UUID?
    private var approvalReply: CheckedContinuation<Bool, Never>?
    var providerOverride: ModelProvider?
    var modelClientOverride: ModelClient?

    init(settings: SettingsStore, browser: BrowserSession, calendar: CalendarConnection? = nil, shopping: ShoppingStore? = nil, trips: TripStore? = nil) {
        self.calendar = calendar
        self.shopping = shopping
        self.trips = trips
        self.settings = settings; self.browser = browser; executor = BrowserToolExecutor(session: browser)
        browser.onHumanInteraction = { [weak self] in self?.stop(reason: "Paused for you. Press Resume when ready.", paused: true) }
        settingsSubscription = settings.$chatRevision.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.stop(reason: "Chat model settings changed. Start a new task.")
            self.history.removeAll()
            if !self.messages.isEmpty { self.messages.append(ChatMessage(role: "notice", text: "Model settings changed. The next message starts a new conversation context.")) }
        }
        accountSubscription = calendar?.$accountID.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetConversations()
        }
        householdSubscription = shopping?.$context.removeDuplicates().dropFirst().sink { [weak self] _ in
            self?.resetConversations()
        }
        if repository.needsRecovery {
            messages.append(ChatMessage(role: "notice", text: "The previous task was interrupted. Inspect Lists, the website or Google Calendar before retrying any action; actions are never replayed automatically."))
        }
    }
    @discardableResult
    func send(_ text: String, attachments: [ChatAttachment] = []) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), text.utf8.count <= 16000, attachments.count <= 4, !running else { return false }
        if !history.isEmpty, conversations.current.modelSignature != settings.modelConfiguration.chatSignature { history.removeAll() }
        let provider: ModelClient
        do {
            if let modelClientOverride { provider = modelClientOverride }
            else if let providerOverride { provider = LegacyModelClient(providerOverride) }
            else { provider = try settings.client(for: .chat) }
        }
        catch {
            AppLog.failure(.agent, "task.start_failed", error: error)
            let row = ChatMessage(role: "notice", text: error.localizedDescription); row.retryText = text
            messages.append(row); return false
        }
        guard attachments.allSatisfy({ !$0.mimeType.hasPrefix("image/") || provider.capabilities.images }) else {
            messages.append(ChatMessage(role: "notice", text: "This model cannot read images. Choose an image-capable model or remove the photo.")); return false
        }
        conversations.current.modelSignature = settings.modelConfiguration.chatSignature
        let userMessage = ModelMessage(role: .user, content: [.text(text)] + attachments.map(\.modelContent))
        guard (try? userMessage.byteCount()) ?? Int.max < 1_400_000 else {
            messages.append(ChatMessage(role: "notice", text: "These attachments are too large to send together. Remove an attachment or choose smaller images.")); return false
        }
        browser.policy = settings.policy
        messages.append(ChatMessage(role: "user", text: text, attachments: attachments))
        if conversations.current.title == "New chat" { conversations.current.title = String((text.isEmpty ? attachments.first?.name ?? "Attachments" : text).prefix(48)) }
        let id = UUID(); generation = id; running = true; paused = false; status = "Thinking…"
        let initial = history + [userMessage]
        history = initial
        task = Task { [weak self] in
            await AppLog.$taskID.withValue(id.uuidString) {
                AppLog.event(.agent, "task.started")
                await self?.run(provider: provider, contents: initial, id: id)
            }
        }
        return true
    }
    func resolveApproval(_ allowed: Bool) {
        if approvalReply != nil { AppLog.$taskID.withValue(generation.uuidString) { AppLog.event(.agent, allowed ? "approval.allowed" : "approval.denied") } }
        if let id = approval?.id, let row = messages.last(where: { $0.approval?.id == id }) { row.approval?.status = allowed ? .approved : .rejected }
        approval = nil; let reply = approvalReply; approvalReply = nil; reply?.resume(returning: allowed)
    }
    func stop(reason: String = "Stopped. The browser is still available.", paused: Bool = false) {
        AppLog.$taskID.withValue(generation.uuidString) { AppLog.event(.agent, paused ? "task.paused" : "task.stopped", count: running ? 1 : 0) }
        let old = generation, wasRunning = running
        let uncertainCalendar = calendarMutationInFlight == old
        let uncertainShopping = shoppingMutationInFlight == old
        generation = UUID(); task?.cancel(); task = nil; calendarMutationInFlight = nil; shoppingMutationInFlight = nil
        let expired = messages.last(where: { $0.approval?.id == approval?.id && $0.approval != nil })
        resolveApproval(false); expired?.approval?.status = .expired
        for row in messages {
            row.streaming = false
            if row.tool?.status == .running { row.tool?.status = .stopped }
        }
        browser.revoke(); running = false; self.paused = paused && !uncertainCalendar && !uncertainShopping
        let calendarName = calendar?.isDemoAccount == true ? "Agora Calendar" : "Google Calendar"
        status = uncertainShopping ? "An item may have been saved. Check Lists before retrying." : uncertainCalendar ? "A Calendar event may have been saved. Check \(calendarName) before retrying." : reason
        browser.state.status = status
        if uncertainCalendar || uncertainShopping { messages.append(ChatMessage(role: "notice", text: status)) }
        if wasRunning { try? repository.record(task: old, operation: "task", phase: browser.state.busy || uncertainCalendar || uncertainShopping ? "outcome_unknown" : "stopped") }
    }
    func newChat() {
        AppLog.event(.agent, "chat.new")
        stop(); browser.close(); conversations.create(); messages = []; paused = false; status = "Ready"
    }
    func selectConversation(_ chat: ChatConversation) {
        guard chat.id != conversations.current.id else { return }
        stop(); browser.setPresentationFromUser(.hidden); conversations.select(chat); messages = chat.messages
        paused = false; status = "Ready"
    }
    func deleteConversation(_ chat: ChatConversation) {
        if chat.id == conversations.current.id { stop(); browser.close() }
        conversations.delete(chat); messages = conversations.current.messages
    }
    func archiveConversation(_ chat: ChatConversation) {
        chat.archived.toggle()
        if chat.archived && chat.id == conversations.current.id { newChat() }
    }
    func resetConversations() {
        stop(); browser.close(); conversations.reset(); messages = []; paused = false; status = "Ready"
    }
    func closeBrowser() { stop(); browser.close() }
    func resume() {
        guard !running else { return }
        let id = UUID(); generation = id; running = true; status = "Reading the updated page"
        task = Task {
            do {
                try await browser.resume()
                try Task.checkCancellation(); guard generation == id else { return }
                running = false
                send("Resume the task. The user may have changed the browser; obtain fresh evidence before acting.")
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                running = false; task = nil
                messages.append(ChatMessage(role: "notice", text: error.localizedDescription))
            }
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
            if shoppingMutationInFlight == id { shoppingMutationInFlight = nil }
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
                let schemas = BrowserCall.schemas.filter { provider.capabilities.images || $0["name"] as? String != "browser_screenshot" } + (calendar?.connected == true ? CalendarCall.schemas : []) + (shopping?.canUse == true ? ShoppingCall.schemas : [])
                let request = ModelRequest(instructions: AgentInstructions.text, messages: contents,
                                           tools: try schemas.map { try ModelToolDefinition(legacy: $0) })
                let streamingRow = ChatMessage(role: "assistant", text: "")
                streamingRow.streaming = true
                let response = try await provider.stream(request, onEvent: { [weak self] event in
                    guard let self, self.generation == id, !Task.isCancelled else { return }
                    if case .text(let value) = event {
                        if !value.isEmpty && !self.messages.contains(where: { $0.id == streamingRow.id }) { self.messages.append(streamingRow) }
                        streamingRow.text = value
                    }
                })
                try validateModelResponse(response.message, request: request)
                try Task.checkCancellation(); guard generation == id else { return }
                contents.append(response.message)
                let text = response.text
                streamingRow.streaming = false
                streamingRow.text = text
                if !text.isEmpty && !messages.contains(where: { $0.id == streamingRow.id }) { messages.append(streamingRow) }
                if text.isEmpty { messages.removeAll { $0.id == streamingRow.id } }
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
                    let toolRow = ChatMessage(role: "tool", text: "")
                    toolRow.tool = ChatToolActivity(name: ChatToolActivity.title(modelCall.name), input: ChatToolActivity.summary(modelCall.arguments.mapValues(\.foundation)))
                    messages.append(toolRow)
                    do {
                        if let name = raw["name"] as? String, ShoppingCall.names.contains(name) {
                            guard let shopping else { throw BrowserError("shopping_unavailable") }
                            let call = try ShoppingCall(raw)
                            status = name == "shopping_context" ? "Reading your shopping context…" : call.isAddition ? "Adding item…" : "Saving suggestion…"
                            try repository.record(task: id, operation: name, phase: "dispatched")
                            if call.isAddition { shoppingMutationInFlight = id }
                            result = try await shopping.execute(call, taskID: id, trips: trips)
                            if shoppingMutationInFlight == id { shoppingMutationInFlight = nil }
                            try repository.record(task: id, operation: name, phase: "observed")
                        } else if let name = raw["name"] as? String, CalendarCall.names.contains(name) {
                            guard let calendar, calendar.connected else { throw BrowserError("calendar_reconnect_required") }
                            let approvedAccountID = calendar.accountID
                            let call = try CalendarCall(raw)
                            if call.name == "calendar_create_event" {
                                approval = ActionApproval(title: calendar.isDemoAccount ? "Add this Agora Calendar event?" : "Add this Google Calendar event?", detail: call.approvalDetail)
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
                            status = ChatToolActivity.title(call.name)
                            browser.state.status = status
                            try repository.record(task: id, operation: call.name, phase: "dispatched")
                            result = try await executor.execute(call)
                            try repository.record(task: id, operation: call.name, phase: result["dispatched"] as? Bool == true ? "dispatched_unverified" : "observed")
                        }
                        failures = 0
                    } catch {
                        try Task.checkCancellation(); guard generation == id else { return }
                        if calendarMutationInFlight == id { calendarMutationInFlight = nil }
                        if shoppingMutationInFlight == id { shoppingMutationInFlight = nil }
                        AppLog.failure(.agent, "tool.failed", error: error)
                        result = ["error": error.localizedDescription]; failures += 1
                        try repository.record(task: id, operation: raw["name"] as? String ?? "invalid_tool", phase: "failed_or_uncertain")
                        toolRow.tool?.status = .failed; toolRow.tool?.result = error.localizedDescription
                        if error.localizedDescription.contains("user_action_required") { paused = true }
                        if error.localizedDescription.contains("outcome_unknown") { throw error }
                    }
                    try Task.checkCancellation(); guard generation == id else { return }
                    toolRow.tool?.status = result["error"] == nil ? .complete : .failed
                    toolRow.tool?.result = ChatToolActivity.summary(result)
                    if toolRow.tool?.result.isEmpty == true { toolRow.tool?.result = "The operation completed." }
                    if paused {
                        history = contents.dropLast().map { $0 }
                        status = "Waiting for you"; return
                    }
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
            for row in messages where row.streaming { row.streaming = false }
            let row = ChatMessage(role: "notice", text: status)
            if !status.contains("outcome_unknown") {
                row.retryText = "Continue my previous request. First check the current state; do not repeat any completed action."
            }
            messages.append(row)
            try? repository.record(task: id, operation: "task", phase: status.contains("outcome_unknown") ? "outcome_unknown" : "failed")
        }
    }
}
