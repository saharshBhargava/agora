import Foundation

struct RecognitionDraft: Identifiable, Equatable {
    let id = UUID()
    var included = true
    var name: String
    var category: String
    var unit: String
    var quantity: String
    let confidence: Double
    var inventoryItemID: UUID?

    init(_ item: RecognizedItem, inventory: [InventoryItem]) {
        name = item.name; category = item.category; unit = item.unit
        quantity = item.quantity.formatted(.number.grouping(.never)); confidence = item.confidence
        let matches = inventory.filter {
            $0.status == "active" && $0.displayName.caseInsensitiveCompare(item.name) == .orderedSame && $0.unit == item.unit
        }
        if matches.count == 1 { inventoryItemID = matches[0].id }
    }
    func confirmed() throws -> ConfirmedRecognitionItem {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let unit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        let category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120, !unit.isEmpty, unit.count <= 20, category.count <= 40 else {
            throw BrowserError("invalid_item", "Each selected item needs a name (up to 120 characters), unit (20), and optional category (40).")
        }
        return ConfirmedRecognitionItem(inventoryItemID: inventoryItemID, displayName: name, category: category,
                                        unit: unit, quantity: try InventoryDraft.number(quantity, required: true)!, confidence: confidence)
    }
}

struct ConfirmedRecognitionItem: Codable, Equatable {
    let inventoryItemID: UUID?
    let displayName: String
    let category: String
    let unit: String
    let quantity: Double
    let confidence: Double
    var body: [String: Any] {
        var body: [String: Any] = ["display_name": displayName, "category": category, "unit": unit,
                                   "quantity": quantity, "confidence": confidence]
        if let inventoryItemID { body["inventory_item_id"] = inventoryItemID.uuidString }
        return body
    }
}

// Persist BEFORE the network write. The identical body/key survives a lost response or app restart.
// This record deliberately contains no filename, media URL, file reference, or image/video bytes.
struct SavedRecognition: Codable, Equatable {
    let key: UUID
    let accountID: String
    let householdID: UUID
    let capturedAt: Date
    let mediaKind: String
    let model: String
    let locationID: UUID?
    let merchantID: UUID?
    let purchasedOn: String?
    let items: [ConfirmedRecognitionItem]
    var rejected = false
    var recognitionID: UUID?
    var body: [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var body: [String: Any] = ["household_id": householdID.uuidString, "captured_at": formatter.string(from: capturedAt),
                                   "media_kind": mediaKind, "model": model, "items": items.map(\.body)]
        if let locationID { body["location_id"] = locationID.uuidString }
        if let merchantID { body["purchased_from_merchant_id"] = merchantID.uuidString }
        if let purchasedOn { body["purchased_on"] = purchasedOn }
        return body
    }
}

struct RecognitionResult: Decodable {
    let recognitionId: UUID
    let items: [InventoryItem]
}
