import Foundation
import CryptoKit
import CoreFoundation

/// The chat's `purchase_request` tool: the assistant asks the backend to buy one thing as an Agora checkout.
/// The backend's policy decides (allow, needs approval, deny); the app asks the user in the chat's approval
/// card when it needs approval. Model arguments are untrusted: validated and clamped here.
struct PurchaseCall {
    static let name = "purchase_request"
    let proposal: PurchaseProposal
    let arguments: [String: Any]

    init(_ raw: [String: Any]) throws {
        guard raw["name"] as? String == Self.name, let args = raw["args"] as? [String: Any] else {
            throw BrowserError("invalid_purchase_tool")
        }
        let allowed: Set<String> = ["title", "amount_cents", "merchant_name", "item_key", "category", "url"]
        guard Set(args.keys).isSubset(of: allowed) else { throw BrowserError("invalid_purchase_tool") }
        guard let rawTitle = args["title"] as? String else { throw BrowserError("invalid_item", "An item name is required.") }
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(title.count) else { throw BrowserError("invalid_item", "Use an item name of 1–120 characters.") }
        guard let number = args["amount_cents"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              (1...10_000_000).contains(number.intValue) else {
            throw BrowserError("invalid_amount", "amount_cents must be a whole number of cents from the user or a confirmed price.")
        }
        func text(_ key: String, limit: Int) throws -> String? {
            guard let value = args[key] else { return nil }
            guard let string = value as? String else { throw BrowserError("invalid_purchase_tool") }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= limit else { throw BrowserError("invalid_purchase_tool", "\(key) is too long.") }
            return trimmed.isEmpty ? nil : trimmed
        }
        let merchant = try text("merchant_name", limit: 80)
        let category = try text("category", limit: 40)?.lowercased()
        let itemKey = try text("item_key", limit: 120)
        let url = try text("url", limit: 2000)
        if let url { guard url.lowercased().hasPrefix("https://"), URL(string: url) != nil else { throw BrowserError("invalid_url", "Use an https:// product page.") } }
        proposal = PurchaseProposal(title: title, amountCents: number.intValue, merchantName: merchant, category: category,
                                    url: url, itemKey: itemKey, rationale: "You asked the assistant to buy this in chat.")
        arguments = args
    }

    /// One key per tool call in a task: a retried identical call reuses the intent instead of buying twice.
    func requestKey(taskID: UUID) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return "chat-" + SHA256.hash(data: Data((taskID.uuidString + Self.name).utf8) + data).map { String(format: "%02x", $0) }.joined().prefix(64)
    }

    /// "Buy Olive oil for $18.99 at PCC Community Markets?"
    var approvalTitle: String {
        let store = proposal.merchantName.map { " at \($0)" } ?? ""
        return "Buy \(proposal.title) for \(CommerceText.money(proposal.amountCents))\(store)?"
    }

    static func approvalDetail(_ intent: AgentIntent) -> String {
        var lines = intent.decisionReasons
        if let card = intent.paymentLabel { lines.append("Paid with \(card).") }
        if intent.isAgoraCheckout { lines.append("Dibs checks out as soon as you approve.") }
        return lines.joined(separator: "\n")
    }

    /// The tool result the model reads: the backend's answer, never rewritten.
    static func result(_ intent: AgentIntent, userDecision: String? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "title": intent.title, "status": intent.status, "decision": intent.decision,
            "reasons": intent.decisionReasons, "summary": CommerceText.outcome(intent),
        ]
        if let cents = intent.displayCents { result["amount"] = CommerceText.money(cents) }
        if let merchant = intent.merchantName { result["merchant"] = merchant }
        if intent.orderId != nil { result["order_placed"] = true }
        if let code = intent.errorCode { result["error_code"] = code }
        if let userDecision { result["user_decision"] = userDecision }
        switch intent.status {
        case "rejected" where intent.decidedBy == "policy":
            result["instruction"] = "The purchase was refused. Explain the reasons to the user. Do not retry or buy it another way."
        case "rejected", "cancelled":
            result["instruction"] = "The user said no. Do not retry this purchase."
        case "outcome_unknown":
            result["instruction"] = "The outcome is unknown. Ask the user to check before buying again. Do not retry."
        default: break
        }
        return result
    }

    static var schema: [String: Any] {
        ["name": name,
         "description": "Buy one item for the user through Dibs checkout. Use ONLY when the user clearly and explicitly asks you to buy, order or purchase a specific item now; never for suggestions, wishlists or lists, and never on your own initiative. amount_cents is the total in cents and must come from the user or a confirmed price; never invent a price. The server decides whether the purchase is allowed; the app asks the user to approve when needed. Report exactly what the tool returns, including its reasons. Never retry a refused, rejected or uncertain purchase.",
         "parameters": ["type": "object", "additionalProperties": false, "required": ["title", "amount_cents"],
            "properties": [
                "title": ["type": "string", "description": "What to buy, in the user's words, at most 120 characters."],
                "amount_cents": ["type": "integer", "description": "Total price in US cents, e.g. 1899 for $18.99."],
                "merchant_name": ["type": "string", "description": "Store name if known."],
                "item_key": ["type": "string", "description": "Optional household item ID or wishlist ID this purchase is for."],
                "category": ["type": "string", "description": "Optional lowercase category, e.g. dairy, produce, pantry."],
                "url": ["type": "string", "description": "Optional https:// product page."],
            ]]]
    }
}
