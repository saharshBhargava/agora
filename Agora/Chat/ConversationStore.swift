import SwiftUI
import Combine

/// Row objects publish independently: a streaming token never replaces the transcript array.
@MainActor
final class ChatMessage: ObservableObject, Identifiable {
    let id: UUID
    let role: String
    @Published var text: String
    @Published var streaming = false
    @Published var tool: ChatToolActivity?
    @Published var approval: ChatApprovalRecord?
    var attachments: [ChatAttachment]
    var retryText: String?
    init(id: UUID = UUID(), role: String, text: String, attachments: [ChatAttachment] = []) {
        self.id = id; self.role = role; self.text = text; self.attachments = attachments
    }
}

struct ChatToolActivity {
    enum Status: String { case running = "In progress", complete = "Complete", failed = "Failed", stopped = "Stopped" }
    let name: String
    let input: String
    var result = ""
    var status: Status = .running
    static func title(_ name: String) -> String {
        switch name {
        case "browser_open": return "Opening a website"
        case "browser_observe": return "Reading a page"
        case "browser_screenshot": return "Viewing the page"
        case "browser_act": return "Using the browser"
        case "browser_wait_for": return "Waiting for the page"
        case "browser_close": return "Closing the browser"
        case "calendar_create_event": return "Adding a Calendar event"
        case "calendar_list_events", "calendar_availability": return "Checking your Calendar"
        case "shopping_context": return "Reading your shopping context"
        case "shopping_list_create": return "Creating a shopping list"
        case "shopping_list_add": return "Adding to shopping list"
        case "wishlist_add": return "Adding to wishlist"
        case "inventory_add": return "Adding to inventory"
        case "shopping_suggest": return "Saving a suggestion"
        case "purchase_request": return "Asking to buy"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    /// Only useful, public-facing fields. Never display raw model or DOM payloads.
    static func summary(_ values: [String: Any]) -> String {
        ["url", "action", "title", "name", "summary", "text", "error"].compactMap { key in
            guard let value = values[key] as? String, !value.isEmpty else { return nil }
            return String(value.prefix(1200))
        }.joined(separator: "\n")
    }
}

struct ChatApprovalRecord {
    enum Status: String { case pending = "Pending", approved = "Approved", rejected = "Rejected", expired = "Expired" }
    let id: UUID
    let title: String
    let detail: String
    var status: Status = .pending
}

@MainActor
final class ChatConversation: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title = "New chat"
    @Published var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published var attachments: [ChatAttachment] = []
    @Published var archived = false
    var history: [ModelMessage] = []
    var modelSignature = ""
    var scrollAnchor: UUID?
    var followsLatest = true
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published var conversations: [ChatConversation]
    @Published var current: ChatConversation
    init() {
        let chat = ChatConversation(); current = chat; conversations = [chat]
    }
    func create() {
        let chat = ChatConversation(); conversations.insert(chat, at: 0); current = chat
    }
    func select(_ chat: ChatConversation) { current = chat }
    func delete(_ chat: ChatConversation) {
        conversations.removeAll { $0.id == chat.id }
        if current.id == chat.id { if let next = conversations.first(where: { !$0.archived }) { current = next } else { create() } }
    }
    func reset() { conversations.removeAll(); create() }
}

/// Explicit fixtures for previews and render tests; never injected into a real account.
@MainActor
enum ChatFixtures {
    static func populate(_ chat: ChatConversation) {
        chat.title = "A better morning brew"
        chat.messages = [ChatMessage(role: "user", text: "Help me choose a coffee setup for a small kitchen. Under $150, easy to clean.")]
        let tool = ChatMessage(role: "tool", text: "")
        tool.tool = ChatToolActivity(name: "Comparing coffee makers", input: "Compact brewers · under $150", result: "Compared size, cleanup, and brewing method across three options.", status: .complete)
        chat.messages.append(tool)
        chat.messages.append(ChatMessage(role: "assistant", text: """
        ## Small counter, great coffee
        A **manual pour-over** is a good fit: it takes little space, cleans up quickly, and leaves room in your budget for a grinder.

        | Option | Best for |
        | --- | --- |
        | Pour-over | A clear, balanced cup |
        | AeroPress | Quick brewing and cleanup |
        | French press | Rich, full-bodied coffee |

        > Start with the brewer you’ll enjoy using every morning.

        See the [AeroPress brewing guide](https://aeropress.com/pages/how-to-use) for the steps. [1](https://aeropress.com/pages/how-to-use)
        """))
    }
}

struct ChatScrollMetrics: Equatable {
    var origin: CGFloat = 0
    var height: CGFloat = 0
    var bottom: CGFloat { origin + height }
}
/// Distinguish a growing answer from a person scrolling, including VoiceOver scroll actions.
struct ChatScrollFollowing {
    var follows = true
    private var previous = ChatScrollMetrics()
    mutating func update(_ metrics: ChatScrollMetrics, viewport: CGFloat, dragging: Bool) -> Bool {
        let distance = metrics.bottom - viewport
        let grew = abs(metrics.height - previous.height) > 1
        let movedAway = metrics.origin > previous.origin + 1 && !grew
        if dragging || movedAway { follows = distance < 120 }
        else if !grew && distance < 40 { follows = true }
        previous = metrics
        return follows && grew && !dragging
    }
}
