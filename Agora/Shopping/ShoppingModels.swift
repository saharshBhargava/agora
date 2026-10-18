import Foundation

struct WishlistEvidence: Decodable {
    let kind: String?
    let detail: String?
}

struct WishlistItem: Decodable, Identifiable {
    let id: UUID
    let householdId: UUID
    let title: String
    let notes: String?
    let category: String?
    let quantity: Int
    let targetPriceCents: Int?
    let neededBy: String?
    let source: String
    let status: String
    let pinned: Bool
    let priority: Int?
    let confidence: Double?
    let rationale: String?
    let evidence: [WishlistEvidence]
    let snoozedUntil: Date?
    let rejectReason: String?
    let myFeedback: String?
    let score: Double
    let priorityReasons: [String]
    let createdAt: Date
    let inventoryItemId: UUID?

    var isPending: Bool { status == "suggested" || status == "snoozed" }
    var editable: Bool { isPending || status == "active" }
    var targetLabel: String? { targetPriceCents.map { Self.money($0) } }
    static func money(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD"))
    }
}

struct ShoppingRefreshStatus: Decodable {
    let householdId: UUID
    let lastRefreshedAt: Date?
    let nextRefreshAt: Date
    let lastError: String?
    let generatedCount: Int
}

struct WishlistDraft {
    var title = ""
    var notes = ""
    var category = ""
    var quantity = 1
    var targetPrice = ""
    var hasDeadline = false
    var deadline = Date()
    var pinned = false
    var priority = 0

    init(item: WishlistItem? = nil) {
        guard let item else { return }
        title = item.title; notes = item.notes ?? ""; category = item.category ?? ""
        quantity = item.quantity; pinned = item.pinned; priority = item.priority ?? 0
        targetPrice = item.targetPriceCents.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? ""
        if let day = item.neededBy, let date = Self.dateFormatter.date(from: day) { hasDeadline = true; deadline = date }
    }
    static var dateFormatter: DateFormatter {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian); formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
    static func cents(_ value: String) throws -> Int? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let normalized = text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard normalized.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              amount >= 0, amount <= 100_000 else {
            throw BrowserError("invalid_price", "Enter a price from 0 to 100,000 with at most two decimal places.")
        }
        return NSDecimalNumber(decimal: amount * 100).intValue
    }
    func body(householdID: UUID, editing: Bool) throws -> [String: Any] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 120, notes.count <= 1000, category.count <= 40,
              (1...99).contains(quantity), (0...5).contains(priority) else {
            throw BrowserError("invalid_wishlist_item", "Use a name of 1–120 characters, notes up to 1,000 characters and a category up to 40 characters.")
        }
        var body: [String: Any] = ["title": title, "quantity": quantity, "pinned": pinned,
            "notes": notes.isEmpty ? NSNull() : notes as Any,
            "category": category.isEmpty ? NSNull() : category as Any,
            "priority": priority == 0 ? NSNull() : priority as Any,
            "target_price_cents": try Self.cents(targetPrice).map { $0 as Any } ?? NSNull(),
            "needed_by": hasDeadline ? Self.dateFormatter.string(from: deadline) as Any : NSNull()]
        if !editing { body["household_id"] = householdID.uuidString }
        return body
    }
}
