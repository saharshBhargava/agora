import Foundation

struct InventoryLocation: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let kind: String
}

struct InventoryHousehold: Decodable, Identifiable {
    let id: UUID
    let name: String
    var locations: [InventoryLocation]
}

struct InventoryProfile: Decodable {
    let households: [InventoryHousehold]
}

struct InventoryMerchant: Decodable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let locality: String?
    var label: String { locality.map { "\(name) · \($0)" } ?? name }
}

struct InventoryItem: Decodable, Identifiable, Equatable {
    let id: UUID
    let householdId: UUID
    var displayName: String
    let category: String?
    var locationId: UUID?
    let unit: String
    var parLevel: Double?
    var status: String
    var quantity: Double?
    var observedAt: Date?
    var source: String?
    var preferredMerchantId: UUID?
    let lastPurchasedFrom: InventoryMerchant?
    // Calendar dates stay dates, independent of the viewer's time zone.
    let lastPurchasedOn: String?

    var isRunningLow: Bool {
        guard status == "active", let quantity, let parLevel else { return false }
        return quantity < parLevel
    }
    var quantityLabel: String { quantity.map { "\($0.formatted()) \(unit)" } ?? "Quantity unknown" }

    var stockSummary: String {
        if quantity == 0 { return "Out of stock" }
        return isRunningLow ? "Running low · \(quantityLabel) left" : quantityLabel
    }

    /// Restock priority, not a consumption forecast. Ratios keep different units comparable.
    static func restockOrder(_ lhs: Self, _ rhs: Self) -> Bool {
        func rank(_ item: Self) -> Int {
            if item.quantity == 0 { return 0 }
            if item.isRunningLow { return 1 }
            return item.quantity == nil ? 3 : 2
        }
        let leftRank = rank(lhs), rightRank = rank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        if leftRank == 1, let lq = lhs.quantity, let lp = lhs.parLevel, lp > 0,
           let rq = rhs.quantity, let rp = rhs.parLevel, rp > 0, lq / lp != rq / rp {
            return lq / lp < rq / rp
        }
        let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
}

struct InventoryObservation: Decodable {
    let time: Date
    let quantity: Double
    let source: String
    let confidence: Double?
}

struct InventoryDailyPoint: Decodable, Identifiable {
    let day: Date
    let quantity: Double?
    var id: Date { day }
}

struct InventoryPurchase: Decodable, Identifiable {
    let merchant: InventoryMerchant?
    let purchasedOn: String?
    let observedAt: Date
    let quantity: Double
    let detectionId: UUID
    var id: UUID { detectionId }
}

struct InventoryDetail: Decodable {
    let item: InventoryItem
    let daily: [InventoryDailyPoint]
    let observations: [InventoryObservation]
    let purchaseHistory: [InventoryPurchase]

    enum CodingKeys: String, CodingKey { case daily, observations, purchaseHistory }
    init(from decoder: Decoder) throws {
        item = try InventoryItem(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        daily = try values.decode([InventoryDailyPoint].self, forKey: .daily)
        observations = try values.decode([InventoryObservation].self, forKey: .observations)
        purchaseHistory = try values.decode([InventoryPurchase].self, forKey: .purchaseHistory)
    }
}

struct InventoryDraft {
    var name = ""
    var category = ""
    var unit = "unit"
    var quantity = ""
    var restockLevel = ""
    var locationID: UUID?
    var merchantID: UUID?

    init(item: InventoryItem? = nil) {
        guard let item else { return }
        name = item.displayName; category = item.category ?? ""; unit = item.unit
        quantity = item.quantity.map { String($0) } ?? ""
        restockLevel = item.parLevel.map { String($0) } ?? ""
        locationID = item.locationId; merchantID = item.preferredMerchantId
    }

    static func number(_ text: String, required: Bool = false) throws -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && !required { return nil }
        let normalized = text.replacingOccurrences(of: Locale.current.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalized), value.isFinite, (0...10_000).contains(value) else {
            throw BrowserError("invalid_quantity", "Enter a number between 0 and 10,000.")
        }
        return value
    }

    func body(householdID: UUID, editing original: InventoryItem? = nil) throws -> [String: Any] {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else {
            throw BrowserError("invalid_name", "Enter an item name of up to 120 characters.")
        }
        let level = try Self.number(restockLevel)
        if let original {
            var body: [String: Any] = [:]
            if name != original.displayName { body["display_name"] = name }
            if level != original.parLevel { body["par_level"] = level.map { $0 as Any } ?? NSNull() }
            if locationID != original.locationId { body["location_id"] = locationID.map { $0.uuidString as Any } ?? NSNull() }
            if merchantID != original.preferredMerchantId { body["preferred_merchant_id"] = merchantID.map { $0.uuidString as Any } ?? NSNull() }
            return body
        }
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !unit.isEmpty, unit.count <= 20, category.count <= 40 else {
            throw BrowserError("invalid_item", "Use a unit of 1–20 characters and a category of up to 40 characters.")
        }
        var body: [String: Any] = ["household_id": householdID.uuidString, "display_name": name, "unit": unit]
        if !category.isEmpty { body["category"] = category }
        if let quantity = try Self.number(quantity) { body["quantity"] = quantity }
        if let level { body["par_level"] = level }
        if let locationID { body["location_id"] = locationID.uuidString }
        if let merchantID { body["preferred_merchant_id"] = merchantID.uuidString }
        return body
    }
}
