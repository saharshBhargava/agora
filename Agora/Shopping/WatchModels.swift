import Foundation

struct WatchCriteria: Decodable {
    let query: String
    let productUrl: String?
    let requiredTerms: [String]
    let excludedTerms: [String]
    let quantity: Int
    let targetPriceCents: Int?
    let maxTotalCents: Int?
    let currency: String
    let fulfillment: String
    let location: String
    let allowedDomains: [String]
    let condition: String
    let allowMembership: Bool
    let neededBy: String?
}

struct WatchSubscription: Decodable {
    let pushEnabled: Bool
    let quietStartHour: Int?
    let quietEndHour: Int?
    let timezone: String
    let dailyCap: Int
    let cooldownHours: Int
}

struct WatchOffer: Decodable, Identifiable {
    let id: UUID
    let watchId: UUID
    let criteriaVersion: Int
    let isCurrent: Bool
    let title: String
    let url: String
    let merchant: String
    let unitPriceCents: Int
    let totalPriceCents: Int?
    let currency: String
    let quantity: Int
    let shippingCents: Int?
    let taxCents: Int?
    let fulfillment: String
    let location: String
    let condition: String
    let observedAt: Date
    let matchedAt: Date
    let evidence: [String]
    let reason: String
    var safeURL: URL? {
        guard let value = URL(string: url), value.scheme == "https", value.host != nil,
              value.user == nil, value.password == nil else { return nil }
        return value
    }
}

struct WatchRun: Decodable, Identifiable {
    let id: UUID
    let criteriaVersion: Int?
    let interactionUrls: [String]?
    let status: String
    let createdAt: Date
    let finishedAt: Date?
    let offerCount: Int
    let matchCount: Int
    let errorCode: String?
}

struct WatchPrice: Decodable, Identifiable {
    let id: UUID
    let title: String
    let url: String
    let merchant: String
    let unitPriceCents: Int
    let currency: String
    let observedAt: Date
    let reason: String
    let isCurrent: Bool
    let provenance: String?
    let verificationNote: String?

    func comparison(target: Int?) -> String {
        guard let target else { return "Add a target price to compare." }
        let difference = unitPriceCents - target
        if difference == 0 { return "At your target price" }
        return "\(WishlistItem.money(abs(difference))) \(difference > 0 ? "above" : "below") your target"
    }
    var safeURL: URL? {
        guard let value = URL(string: url), (try? BrowserPolicy().validate(value)) != nil else { return nil }
        return value
    }
}

struct WatchBrowserFallback: Decodable {
    let runId: UUID
    let status: String
    let urls: [String]
}

struct WatchBrowserClaim: Decodable {
    let runId: UUID
    let token: UUID
    let expiresAt: Date
    let urls: [String]
}

struct WatchBrowserResult: Decodable {
    let status: String
    let priceCount: Int
}

struct PriceWatch: Decodable, Identifiable {
    let id: UUID
    let wishlistItemId: UUID
    let householdId: UUID
    let title: String
    let status: String
    let criteriaVersion: Int
    let criteria: WatchCriteria
    let subscription: WatchSubscription?
    let confirmedAt: Date?
    let lastCheckedAt: Date?
    let lastSuccessfulAt: Date?
    let nextCheckAt: Date?
    let lastError: String?
    let lastResult: String
    let simulationDisclosure: String?
    let rejectionReasons: [String]?
    let searchAvailable: Bool
    let matches: [WatchOffer]
    let runs: [WatchRun]
    let prices: [WatchPrice]?
    let browserFallback: WatchBrowserFallback?
    var isChecking: Bool {
        runs.contains { ($0.criteriaVersion == nil || $0.criteriaVersion == criteriaVersion) && ["queued", "running"].contains($0.status) }
    }
    var currentPrices: [WatchPrice] {
        (prices ?? []).filter { $0.isCurrent && Date().timeIntervalSince($0.observedAt) <= 1800 }
            .sorted { $0.unitPriceCents < $1.unitPriceCents }
    }
    var currentOffers: [WatchOffer] {
        matches.filter { $0.criteriaVersion == criteriaVersion && $0.isCurrent }
            .sorted { ($0.totalPriceCents ?? $0.unitPriceCents * $0.quantity) < ($1.totalPriceCents ?? $1.unitPriceCents * $1.quantity) }
    }
    var browserReviewURLs: [URL] {
        guard confirmedAt != nil, ["active", "paused"].contains(status),
              let latest = runs.max(by: { $0.createdAt < $1.createdAt }),
              latest.criteriaVersion == criteriaVersion else { return [] }
        var seen = Set<URL>()
        return (latest.interactionUrls ?? []).prefix(5).compactMap { value in
            guard let url = URL(string: value), (try? BrowserPolicy().validate(url)) != nil,
                  seen.insert(url).inserted else { return nil }
            return url
        }
    }
    var historicalOffers: [WatchOffer] { matches.filter { !$0.isCurrent || $0.criteriaVersion != criteriaVersion } }
    var rejectionLabels: [String] {
        let labels = [
            "required_terms_missing": "The exact product or required variant could not be verified.",
            "excluded_term": "An excluded variant or product type was found.",
            "merchant_not_allowed": "The offer was from a retailer outside your allowed list.",
            "missing_evidence": "The retailer did not provide enough product evidence.",
            "stale_observation": "The available price information was too old.",
            "invalid_observation_time": "The price verification time could not be established.",
            "expired_offer": "The offer has expired.", "out_of_stock": "The product was out of stock.",
            "currency_mismatch": "The offer was not priced in USD.",
            "condition_mismatch": "The product condition did not match your criteria.",
            "fulfillment_unverified": "Delivery or pickup availability could not be verified for your location.",
            "unconfirmed_eligibility": "The offer required an unapproved membership, coupon or subscription.",
            "arrival_unverified": "Arrival by your needed-by date could not be verified.",
            "insufficient_stock": "The available quantity was too low.",
            "quantity_unverified": "Stock for the requested quantity could not be verified.",
            "above_target": "The unit price exceeded your target.",
            "target_not_set": "Add a target price to receive matching-price alerts.",
            "total_unknown": "The full cost including shipping, tax and fees could not be verified.",
            "above_total_cap": "The full cost exceeded your maximum total.",
            "invalid_product_url": "The source did not provide a valid retailer product link."
        ]
        return (rejectionReasons ?? []).prefix(10).map { labels[$0] ?? "An offer could not be verified against all your criteria." }
    }
    var resultLabel: String {
        if status == "paused" { return "Price checks are paused." }
        if status == "completed" { return "This item is no longer being watched." }
        if status == "expired" { return "Update the needed-by date to continue price checks." }
        if lastError == "agent_paused" { return "Price checks will continue when your agent resumes." }
        if ["check_budget_exhausted", "check_budget_exceeded"].contains(lastError ?? "") {
            return "The price-check limit was reached. Automatic checks will resume later."
        }
        if !searchAvailable { return "Retailer search is unavailable. Your criteria are saved." }
        if isChecking { return "Searching the web for current prices…" }
        if !currentPrices.isEmpty && currentPrices.contains(where: { $0.provenance == "device_browser" }) {
            return "Prices read in your browser. Confirm details with the retailer."
        }
        if browserFallback?.status == "pending" { return "Retailer checks finished. Waiting for the browser backup while the app is open." }
        if browserFallback?.status == "claimed" { return "Reading retailer pages in the browser backup…" }
        if browserFallback?.status == "unavailable" { return "Retailer and browser checks could not verify a price. Try a specific product link." }
        if browserFallback?.status == "completed" && currentPrices.isEmpty { return "The browser prices are no longer current. Check again for updated prices." }
        if !currentPrices.isEmpty && criteria.targetPriceCents == nil { return "Current prices found. Add a target to compare." }
        switch lastResult {
        case "matched": return currentOffers.isEmpty ? "Previous matches are no longer current. Review your watch and check again." : "Verified offers found. Check the retailer before purchasing."
        case "no_match": return "No offers met all your criteria in the last successful check."
        case "failed": return "The last check failed. This does not mean there are no offers."
        case "skipped": return "The last check was skipped."
        default: return "Waiting for the first check."
        }
    }
}

struct WatchListResponse: Decodable {
    let automaticWatches: Bool?
    let discoveryStatus: String?
    let watches: [PriceWatch]
    let searchAvailable: Bool
    let discoveryAvailable: Bool?
}

struct WatchCheckResponse: Decodable {
    let watchId: UUID
    let runId: UUID
    let status: String
}

struct WatchDraft {
    var query = ""
    var productURL = ""
    var requiredTerms = ""
    var excludedTerms = ""
    var quantity = 1
    var targetPrice = ""
    var maxTotal = ""
    var fulfillment = "delivery"
    var location = "US"
    var allowedDomains = ""
    var condition = "new"
    var allowMembership = false
    var hasDeadline = false
    var deadline = Date()
    var pushEnabled = false
    var quietHours = false
    var quietStart = 22
    var quietEnd = 8
    var timezone = TimeZone.current.identifier
    var dailyCap = 3
    var cooldownHours = 24

    init(item: WishlistItem? = nil, watch: PriceWatch? = nil) {
        if let item {
            query = item.title; quantity = item.quantity
            targetPrice = Self.amount(item.targetPriceCents)
            if let date = item.neededBy.flatMap({ WishlistDraft.dateFormatter.date(from: $0) }) { hasDeadline = true; deadline = date }
        }
        guard let watch else { return }
        let criteria = watch.criteria, subscription = watch.subscription
        query = criteria.query; productURL = criteria.productUrl ?? ""
        requiredTerms = criteria.requiredTerms.joined(separator: ", "); excludedTerms = criteria.excludedTerms.joined(separator: ", ")
        quantity = criteria.quantity; targetPrice = Self.amount(criteria.targetPriceCents); maxTotal = Self.amount(criteria.maxTotalCents)
        fulfillment = criteria.fulfillment; location = criteria.location; allowedDomains = criteria.allowedDomains.joined(separator: ", ")
        condition = criteria.condition; allowMembership = criteria.allowMembership
        hasDeadline = criteria.neededBy != nil
        if let date = criteria.neededBy.flatMap({ WishlistDraft.dateFormatter.date(from: $0) }) { deadline = date }
        guard let subscription else { return }
        pushEnabled = subscription.pushEnabled; quietHours = subscription.quietStartHour != nil
        quietStart = subscription.quietStartHour ?? 22; quietEnd = subscription.quietEndHour ?? 8
        timezone = subscription.timezone; dailyCap = subscription.dailyCap; cooldownHours = subscription.cooldownHours
    }
    static func amount(_ cents: Int?) -> String {
        cents.map { NSDecimalNumber(decimal: Decimal($0) / 100).stringValue } ?? ""
    }
    static func terms(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func criteriaBody() throws -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines), location = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...200).contains(query.count), location.count >= 2, location.count <= 200,
              (1...99).contains(quantity) else {
            throw BrowserError("invalid_watch", "Add a specific product and a location.")
        }
        let target = try WishlistDraft.cents(targetPrice)
        let url = productURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty {
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil,
                  parsed.user == nil, parsed.password == nil else {
                throw BrowserError("invalid_product_url", "Use an HTTPS product link without a username or password.")
            }
        }
        let required = Self.terms(requiredTerms), excluded = Self.terms(excludedTerms), domains = Self.terms(allowedDomains).map { $0.lowercased() }
        guard required.count <= 20, excluded.count <= 20, domains.count <= 20,
              (required + excluded).allSatisfy({ $0.count <= 80 }),
              domains.allSatisfy({ $0.range(of: #"^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$"#, options: .regularExpression) != nil }),
              ["delivery", "pickup"].contains(fulfillment), ["new", "used", "refurbished"].contains(condition) else {
            throw BrowserError("invalid_watch", "Use up to 20 terms or retailer domains. Domains should look like retailer.com, without a path.")
        }
        let total = try WishlistDraft.cents(maxTotal)
        if let total, total <= 0 { throw BrowserError("invalid_total", "The maximum total must be greater than zero.") }
        return ["query": query, "product_url": url.isEmpty ? NSNull() : url as Any,
                "required_terms": required, "excluded_terms": excluded, "quantity": quantity,
                "target_price_cents": target.map { $0 as Any } ?? NSNull(), "max_total_cents": total.map { $0 as Any } ?? NSNull(), "currency": "USD",
                "fulfillment": fulfillment, "location": location, "allowed_domains": domains,
                "condition": condition, "allow_membership": allowMembership,
                "needed_by": hasDeadline ? WishlistDraft.dateFormatter.string(from: deadline) as Any : NSNull()]
    }
    func body(confirmed: Bool) throws -> [String: Any] {
        guard confirmed else { throw BrowserError("review_required", "Review and confirm the watch criteria first.") }
        guard TimeZone(identifier: timezone) != nil, (1...20).contains(dailyCap), (1...168).contains(cooldownHours),
              (0...23).contains(quietStart), (0...23).contains(quietEnd), !quietHours || quietStart != quietEnd else {
            throw BrowserError("invalid_alert_preferences", "Choose a valid time zone, distinct quiet hours and alert limits.")
        }
        return ["confirmed": true, "criteria": try criteriaBody(), "subscription": [
            "push_enabled": pushEnabled, "quiet_start_hour": quietHours ? quietStart as Any : NSNull(),
            "quiet_end_hour": quietHours ? quietEnd as Any : NSNull(), "timezone": timezone,
            "daily_cap": dailyCap, "cooldown_hours": cooldownHours]]
    }
}

struct WatchNotification: Decodable, Identifiable {
    let id: UUID
    let householdId: UUID
    let watchId: UUID?
    let matchId: UUID?
    let title: String
    let body: String
    let createdAt: Date
    let readAt: Date?
}

struct WatchReadResponse: Decodable {
    let id: UUID
    let readAt: Date
}
