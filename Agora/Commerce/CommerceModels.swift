import Foundation

// The agent-commerce API's shapes (docs/api/agent-commerce.md). Decoded by `AgoraClient.decoder`
// (snake_case keys, ISO 8601 timestamps). Model-written text in an intent (rationale, evidence) is shown as
// data only; the backend's `decision_reasons` are shown verbatim and in order.

struct AgentIntent: Decodable, Identifiable, Equatable {
    struct Payload: Decodable, Equatable {
        var url: String?
        var quantity: Int?
        var paymentMethodRef: String?
    }
    struct Evidence: Decodable, Equatable {
        let kind: String
        let detail: String
    }

    let id: UUID
    let householdId: UUID
    let kind: String
    let execution: String
    let title: String
    let payload: Payload
    let amountCents: Int?
    let finalAmountCents: Int?
    let currency: String
    let merchantId: UUID?
    let merchantName: String?
    let category: String?
    let rationale: String
    let evidence: [Evidence]
    let decision: String
    let decisionReasons: [String]
    let reasonCodes: [String]
    let mandateId: UUID?
    let status: String
    let decidedBy: String?
    let decidedAt: Date?
    let rejectReason: String?
    let errorCode: String?
    let orderId: UUID?
    let mine: Bool
    let approvalExpiresAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?

    var isAgoraCheckout: Bool { execution == "agora" }
    var waitingForApproval: Bool { status == "proposed" }
    /// The amount the user agreed to, or what was finally charged once known.
    var displayCents: Int? { finalAmountCents ?? amountCents }

    /// Approving is possible while the request is proposed, the approval has not expired, and it is this person's.
    func canApprove(now: Date = Date()) -> Bool {
        guard status == "proposed", mine else { return false }
        if let expires = approvalExpiresAt { return expires > now }
        return true
    }

    /// The card the server will charge, from the provider token reference ("sim_visa_4242" → "Visa ending 4242").
    /// Card data never reaches the app; the reference only names the brand and last four digits.
    var paymentLabel: String? {
        guard let ref = payload.paymentMethodRef?.lowercased() else { return nil }
        let brands = ["visa": "Visa", "mastercard": "Mastercard", "amex": "American Express", "discover": "Discover"]
        let parts = ref.split(separator: "_").map(String.init)
        guard let brandIndex = parts.firstIndex(where: { brands[$0] != nil }), let brand = brands[parts[brandIndex]] else { return nil }
        if brandIndex + 1 < parts.count, parts[brandIndex + 1].count == 4, parts[brandIndex + 1].allSatisfy(\.isNumber) {
            return "\(brand) ending \(parts[brandIndex + 1])"
        }
        return brand
    }

    var productURL: URL? {
        guard let text = payload.url, let url = URL(string: text), url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    /// Reason codes that deserve a warning tint on the approval sheet.
    static let warningCodes: Set<String> = ["over_budget", "over_txn_cap", "over_period_cap", "duplicate_recent", "duplicate_unknown"]
    var hasWarning: Bool { !Set(reasonCodes).isDisjoint(with: Self.warningCodes) }
}

struct AgentMandate: Decodable, Identifiable, Equatable {
    let id: UUID
    let householdId: UUID
    let label: String
    let merchantIds: [UUID]?
    let categories: [String]?
    let currency: String
    let maxPerTxnCents: Int
    let maxPerPeriodCents: Int?
    let period: String
    let requireConfirmAboveCents: Int?
    let expiresAt: Date
    let status: String
    let revokedAt: Date?
    let revokedReason: String?
    let periodStartedAt: Date
    let spentThisPeriodCents: Int
    let createdAt: Date

    var isActive: Bool { status == "active" }
}

struct AgentState: Decodable, Equatable {
    let autonomyLevel: String
    let paused: Bool
    let pausedAt: Date?
    let activeMandates: Int
    let pendingApprovals: Int
}

/// What pause and resume return.
struct AgentPauseResult: Decodable, Equatable {
    let paused: Bool
    let pausedAt: Date?
    let mandatesRevoked: Int
    let intentsCancelled: Int
    let inFlight: Int
}

struct SpendBudget: Decodable, Identifiable, Equatable {
    let id: UUID
    let householdId: UUID
    let period: String
    let category: String?
    let limitCents: Int
    let currency: String
    let status: String
    let startsOn: String
    let periodStartedAt: Date
    let spentCents: Int
    let pendingCents: Int
    let remainingCents: Int
    let createdAt: Date
    let updatedAt: Date

    var isOver: Bool { remainingCents < 0 }
}

struct SpendSummary: Decodable, Equatable {
    struct Group: Decodable, Equatable, Identifiable {
        let key: String?
        let label: String
        let amountCents: Int
        let entries: Int
        var id: String { key ?? label }
    }
    let householdId: UUID
    let period: String
    let group: String
    let start: Date
    let end: Date
    let currency: String
    let totalCents: Int
    let groups: [Group]
    let budgets: [SpendBudget]
}

/// The "Give spending authority" form.
struct MandateDraft: Equatable {
    var label = ""
    var maxPerPurchase = ""
    var periodLimit = ""
    var period = "month"
    var confirmAbove = ""
    var categories: [String] = []
    var expiresInDays = 30

    static let periods = [("Day", "day"), ("Week", "week"), ("Month", "month")]
    static let expiries = [("7 days", 7), ("30 days", 30), ("90 days", 90), ("1 year", 365)]
    static let suggestedCategories = ["groceries", "dairy", "produce", "pantry", "household", "meat", "bakery", "frozen"]

    /// Dollars ("12", "12.50", "$12.5") to cents; nil when empty or not a positive amount.
    static func cents(_ text: String) -> Int? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty, let value = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        var scaled = value * 100, rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let cents = NSDecimalNumber(decimal: rounded).intValue
        return (1...10_000_000).contains(cents) ? cents : nil
    }

    enum Problem: Error, Equatable { case label, perPurchase, periodLimit, confirmAbove }

    func body(householdID: UUID?) throws -> [String: Any] {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(name.count) else { throw Problem.label }
        guard let perPurchase = Self.cents(maxPerPurchase) else { throw Problem.perPurchase }
        var body: [String: Any] = ["label": name, "max_per_txn_cents": perPurchase, "period": period, "expires_in_days": expiresInDays]
        if !periodLimit.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let limit = Self.cents(periodLimit), limit >= perPurchase else { throw Problem.periodLimit }
            body["max_per_period_cents"] = limit
        }
        if !confirmAbove.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let above = Self.cents(confirmAbove) else { throw Problem.confirmAbove }
            body["require_confirm_above_cents"] = above
        }
        let picked = categories.map { $0.lowercased() }.filter { !$0.isEmpty }
        if !picked.isEmpty { body["categories"] = Array(picked.prefix(20)) }
        if let householdID { body["household_id"] = householdID.uuidString }
        return body
    }
}

/// A purchase the assistant proposes: from the wishlist's "Buy with the assistant" or the chat's `purchase_request`.
/// Always an Agora checkout (`execution: agora`): the server decides and, when allowed or approved, charges.
struct PurchaseProposal: Equatable {
    var title: String
    var amountCents: Int
    var quantity = 1
    var merchantName: String?
    var category: String?
    var url: String?
    var itemKey: String?
    var rationale: String
    var evidence: [(kind: String, detail: String)] = []

    static func == (lhs: PurchaseProposal, rhs: PurchaseProposal) -> Bool {
        lhs.title == rhs.title && lhs.amountCents == rhs.amountCents && lhs.quantity == rhs.quantity
            && lhs.merchantName == rhs.merchantName && lhs.category == rhs.category && lhs.url == rhs.url
            && lhs.itemKey == rhs.itemKey && lhs.rationale == rhs.rationale
            && lhs.evidence.map(\.kind) == rhs.evidence.map(\.kind) && lhs.evidence.map(\.detail) == rhs.evidence.map(\.detail)
    }

    func body(householdID: UUID?) -> [String: Any] {
        var body: [String: Any] = ["kind": "purchase", "execution": "agora", "title": String(title.prefix(120)),
                                   "amount_cents": amountCents, "quantity": max(1, min(99, quantity)),
                                   "rationale": String(rationale.prefix(500))]
        if let merchantName, !merchantName.isEmpty { body["merchant_name"] = String(merchantName.prefix(80)) }
        if let category, !category.isEmpty { body["category"] = String(category.lowercased().prefix(40)) }
        if let url, url.lowercased().hasPrefix("https://"), url.count <= 2000 { body["url"] = url }
        if let itemKey, !itemKey.isEmpty { body["details"] = ["item_key": String(itemKey.prefix(300))] }
        if !evidence.isEmpty { body["evidence"] = evidence.prefix(5).map { ["kind": $0.kind, "detail": String($0.detail.prefix(200))] } }
        if let householdID { body["household_id"] = householdID.uuidString }
        return body
    }
}

/// Plain-language labels for the commerce screens.
enum CommerceText {
    static func money(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD"))
    }

    /// Whole dollars when exact ("$50"), else cents ("$12.50").
    static func shortMoney(_ cents: Int) -> String {
        cents % 100 == 0 ? (Decimal(cents / 100)).formatted(.currency(code: "USD").precision(.fractionLength(0))) : money(cents)
    }

    static func status(_ intent: AgentIntent) -> String {
        switch intent.status {
        case "proposed": return "Waiting for you"
        case "approved": return "Approved"
        case "executing": return "In progress"
        case "succeeded": return "Done"
        case "failed": return "Failed"
        case "outcome_unknown": return "Check this"
        case "rejected": return intent.decidedBy == "policy" ? "Blocked" : "Rejected"
        case "cancelled": return "Cancelled"
        default: return intent.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    static func decidedBy(_ intent: AgentIntent) -> String? {
        switch (intent.decidedBy, intent.status) {
        case ("policy", "rejected"): return "Blocked by your settings"
        case ("policy", _): return "Allowed by your spending authority"
        case ("user", "rejected"): return intent.mine ? "You rejected" : "Rejected"
        case ("user", _): return intent.mine ? "You approved" : "Approved"
        case ("kill_switch", _): return "Cancelled by pause"
        default: return nil
        }
    }

    static func period(_ period: String) -> String {
        switch period {
        case "day": return "day"
        case "week": return "week"
        default: return "month"
        }
    }

    static func limits(_ mandate: AgentMandate) -> String {
        var line = "Up to \(shortMoney(mandate.maxPerTxnCents)) per purchase"
        if let cap = mandate.maxPerPeriodCents { line += " · \(shortMoney(cap)) per \(period(mandate.period))" }
        return line
    }

    static func scope(_ mandate: AgentMandate) -> String {
        let stores = (mandate.merchantIds?.isEmpty ?? true) ? "Any store" : "\(mandate.merchantIds!.count) chosen \(mandate.merchantIds!.count == 1 ? "store" : "stores")"
        let categories = (mandate.categories?.isEmpty ?? true) ? "any category" : mandate.categories!.joined(separator: ", ")
        return "\(stores) · \(categories)"
    }

    static func expires(_ date: Date) -> String {
        "Expires \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// "Expires in 23 h" for a waiting approval; nil once it has passed.
    static func approvalWindow(_ intent: AgentIntent, now: Date = Date()) -> String? {
        guard intent.status == "proposed", let expires = intent.approvalExpiresAt else { return nil }
        let seconds = expires.timeIntervalSince(now)
        guard seconds > 0 else { return "This request expired. The assistant needs to ask again." }
        let hours = Int(seconds / 3600)
        return hours >= 1 ? "Expires in \(hours) h" : "Expires in \(max(1, Int(seconds / 60))) min"
    }

    /// The headline after a decision or an approval: what actually happened.
    static func outcome(_ intent: AgentIntent) -> String {
        let amount = intent.displayCents.map { " for \(money($0))" } ?? ""
        let store = intent.merchantName.map { " at \($0)" } ?? ""
        switch intent.status {
        case "succeeded": return "Bought \(intent.title)\(amount)\(store)."
        case "approved": return intent.isAgoraCheckout ? "Approved \(intent.title)\(amount)." : "Approved. The assistant can go ahead with \(intent.title)."
        case "executing": return "Buying \(intent.title) now."
        case "failed": return "The purchase of \(intent.title) didn't go through\(intent.errorCode == "card_declined" ? ": the card was declined" : ""). Nothing was charged."
        case "outcome_unknown": return "\(intent.title) may or may not have gone through. Check the store before buying again."
        case "rejected": return intent.decidedBy == "policy" ? "Blocked: \(intent.decisionReasons.first ?? "the assistant can't buy this.")" : "Rejected \(intent.title)."
        case "cancelled": return "\(intent.title) was cancelled."
        case "proposed": return "\(intent.title) is waiting for your approval."
        default: return status(intent)
        }
    }

    static func pauseResult(_ result: AgentPauseResult) -> String {
        var line = "The assistant is paused."
        let mandates = result.mandatesRevoked, cancelled = result.intentsCancelled
        if mandates > 0 { line += " \(mandates) spending \(mandates == 1 ? "authority" : "authorities") revoked." }
        if cancelled > 0 { line += " \(cancelled) \(cancelled == 1 ? "request" : "requests") cancelled." }
        if result.inFlight > 0 { line += " \(result.inFlight) \(result.inFlight == 1 ? "action was" : "actions were") already in progress and may still finish." }
        return line
    }

    static let rejectReasons: [(title: String, code: String)] = [
        ("Too expensive", "too_expensive"), ("Don't need it", "not_needed"), ("Wrong item", "wrong_item"),
        ("Wrong store", "wrong_merchant"), ("Other", "other"),
    ]

    static func evidenceSymbol(_ kind: String) -> String {
        switch kind {
        case "inventory_low": return "shippingbox"
        case "runout_forecast": return "chart.line.downtrend.xyaxis"
        case "purchase_history": return "clock.arrow.circlepath"
        case "wishlist": return "heart"
        case "price": return "tag"
        case "product_page": return "safari"
        case "calendar": return "calendar"
        default: return "info.circle"
        }
    }
}

/// "Buy with the assistant" on a wishlist item: an Agora checkout at the cheapest current price the watch found
/// (with its store and page), else the item's target price. Nil when neither is known: the app never guesses a price.
enum WishlistPurchase {
    static func proposal(item: WishlistItem, watch: PriceWatch?) -> PurchaseProposal? {
        proposal(item: item, price: watch?.currentPrices.first.map { (merchant: $0.merchant, cents: $0.unitPriceCents, url: $0.safeURL?.absoluteString) })
    }

    static func proposal(item: WishlistItem, price: (merchant: String, cents: Int, url: String?)?) -> PurchaseProposal? {
        let quantity = max(1, min(99, item.quantity))
        let unit: Int, merchant: String?, url: String?
        var evidence: [(kind: String, detail: String)] = [(kind: "wishlist", detail: "On your household wishlist")]
        if let price {
            unit = price.cents; merchant = price.merchant; url = price.url
            evidence.append((kind: "price", detail: "\(CommerceText.money(price.cents)) at \(price.merchant), found by your price watch"))
        } else if let target = item.targetPriceCents {
            unit = target; merchant = nil; url = nil
            evidence.append((kind: "price", detail: "Your target price is \(CommerceText.money(target))"))
        } else { return nil }
        let total = unit * quantity
        guard (1...10_000_000).contains(total) else { return nil }
        return PurchaseProposal(title: quantity > 1 ? "\(item.title), \(quantity)" : item.title, amountCents: total, quantity: quantity,
                                merchantName: merchant, category: item.category, url: url, itemKey: "wishlist:\(item.id.uuidString.lowercased())",
                                rationale: "You asked the assistant to buy this from your wishlist.", evidence: evidence)
    }
}
