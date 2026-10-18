import Foundation

// Codable mirrors of server/src/types.ts. Field names match the TypeScript exactly.
// Enums never throw on a value they do not know: it decodes to `.unknown`, so a newer server
// cannot break an older app. Timestamps are JavaScript milliseconds, kept as Double.

public enum RunState: String, Codable, Sendable, Hashable {
    case open, lastCall, locked, receipt, settled, partlySettled, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RunState(rawValue: raw) ?? .unknown
    }
}

public enum ChipState: String, Codable, Sendable, Hashable {
    case wish, identifying, open, claimed, locked, matched, unmatched, settled, removed, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ChipState(rawValue: raw) ?? .unknown
    }
}

public enum PriceSource: String, Codable, Sendable, Hashable {
    case sticker, web, receipt, none, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PriceSource(rawValue: raw) ?? .unknown
    }
}

public enum SettleStep: String, Codable, Sendable, Hashable {
    case joined, settling, incremented, reversed, captured, failed, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SettleStep(rawValue: raw) ?? .unknown
    }
}

/// A region in frame coordinates, as the server sends it.
public struct Box: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct Chip: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var priceCents: Int?
    public var priceSource: PriceSource
    public var photoUrl: String?
    public var region: Box?
    /// How many of this item are in the cart (1 to 20). `priceCents` is the price of one.
    public var quantity: Int
    /// The receipt's exact line total for this chip, tax included; once set it replaces priceCents × quantity.
    public var receiptTotalCents: Int?
    /// When the camera last counted this item (ms).
    public var lastSeenAt: Double?
    /// Ordered by claim time.
    public var claimers: [String]
    public var state: ChipState
    public var wishedBy: String?
    public var duplicateOf: String?
    public var putBack: Bool
    public var dropped: Bool
    /// Person ids whose tray broke the rule when a price arrived.
    public var overCap: [String]
    public var removedAt: Double?
    /// When the chip was added (ms).
    public var addedAt: Double

    public init(
        id: String, name: String, priceCents: Int? = nil, priceSource: PriceSource = .none,
        photoUrl: String? = nil, region: Box? = nil, quantity: Int = 1, claimers: [String] = [],
        state: ChipState = .open, wishedBy: String? = nil, duplicateOf: String? = nil,
        putBack: Bool = false, dropped: Bool = false, overCap: [String] = [],
        removedAt: Double? = nil, addedAt: Double = 0, receiptTotalCents: Int? = nil
    ) {
        self.id = id; self.name = name; self.priceCents = priceCents; self.priceSource = priceSource
        self.photoUrl = photoUrl; self.region = region; self.quantity = quantity; self.claimers = claimers
        self.state = state; self.wishedBy = wishedBy; self.duplicateOf = duplicateOf
        self.putBack = putBack; self.dropped = dropped; self.overCap = overCap
        self.removedAt = removedAt; self.addedAt = addedAt; self.receiptTotalCents = receiptTotalCents
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, priceCents, priceSource, photoUrl, region, quantity, receiptTotalCents, lastSeenAt, claimers, state
        case wishedBy, duplicateOf, putBack, dropped, overCap, removedAt, addedAt
    }

    // Lenient on fields an older stored run may lack; strict on id, name and state.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        priceCents = try c.decodeIfPresent(Int.self, forKey: .priceCents)
        priceSource = try c.decodeIfPresent(PriceSource.self, forKey: .priceSource) ?? .none
        photoUrl = try c.decodeIfPresent(String.self, forKey: .photoUrl)
        region = try c.decodeIfPresent(Box.self, forKey: .region)
        quantity = try c.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        receiptTotalCents = try c.decodeIfPresent(Int.self, forKey: .receiptTotalCents)
        lastSeenAt = try c.decodeIfPresent(Double.self, forKey: .lastSeenAt)
        claimers = try c.decodeIfPresent([String].self, forKey: .claimers) ?? []
        state = try c.decode(ChipState.self, forKey: .state)
        wishedBy = try c.decodeIfPresent(String.self, forKey: .wishedBy)
        duplicateOf = try c.decodeIfPresent(String.self, forKey: .duplicateOf)
        putBack = try c.decodeIfPresent(Bool.self, forKey: .putBack) ?? false
        dropped = try c.decodeIfPresent(Bool.self, forKey: .dropped) ?? false
        overCap = try c.decodeIfPresent([String].self, forKey: .overCap) ?? []
        removedAt = try c.decodeIfPresent(Double.self, forKey: .removedAt)
        addedAt = try c.decodeIfPresent(Double.self, forKey: .addedAt) ?? 0
    }
}

extension Chip {
    /// The most of one item a chip counts (server MAX_QUANTITY): the shopper's stepper stops here.
    public static let maxQuantity = 20

    /// The line total: the receipt's exact total once read, else unit price × quantity; nil while
    /// unpriced. Mirrors `lineCents` in server/src/money.ts; every share, room and total uses it.
    public var lineCents: Int? { receiptTotalCents ?? priceCents.map { $0 * quantity } }

    /// "×2" for more than one, "" for one.
    public static func qtyText(_ quantity: Int) -> String { quantity > 1 ? "×\(quantity)" : "" }

    /// "Cosmic Crisp Apple ×2", or just the name for one.
    public var nameWithQty: String { quantity > 1 ? "\(name) \(Self.qtyText(quantity))" : name }
}

public struct Person: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var initial: String
    public var isShopper: Bool
    public var authorizedCents: Int?
    public var authId: String?
    /// Approval code from the authorization (or the latest incremental one).
    public var approvalCode: String?
    public var payoutPan: String?

    public init(
        id: String, name: String, initial: String, isShopper: Bool, authorizedCents: Int? = nil,
        authId: String? = nil, approvalCode: String? = nil, payoutPan: String? = nil
    ) {
        self.id = id; self.name = name; self.initial = initial; self.isShopper = isShopper
        self.authorizedCents = authorizedCents; self.authId = authId
        self.approvalCode = approvalCode; self.payoutPan = payoutPan
    }
}

public struct ReceiptLine: Codable, Sendable, Hashable {
    public var text: String
    public var cents: Int
    public var quantity: Int
    public var isTax: Bool

    public init(text: String, cents: Int, quantity: Int = 1, isTax: Bool = false) {
        self.text = text; self.cents = cents; self.quantity = quantity; self.isTax = isTax
    }
}

public struct ReceiptMatch: Codable, Sendable, Hashable {
    public var chipId: String
    public var lineIndex: Int
    public var confidence: Double

    public init(chipId: String, lineIndex: Int, confidence: Double) {
        self.chipId = chipId; self.lineIndex = lineIndex; self.confidence = confidence
    }
}

public struct ReceiptState: Codable, Sendable, Hashable {
    public var lines: [ReceiptLine]
    public var matches: [ReceiptMatch]
    public var unmatchedLines: [Int]
    /// Lines the shopper claimed as their own.
    public var mine: [Int]?
    /// Each chip's count before the receipt changed it: how many items' worth of lines it may take.
    public var cartQuantities: [String: Int]?

    public init(lines: [ReceiptLine], matches: [ReceiptMatch], unmatchedLines: [Int], mine: [Int]? = nil,
                cartQuantities: [String: Int]? = nil) {
        self.lines = lines; self.matches = matches; self.unmatchedLines = unmatchedLines; self.mine = mine
        self.cartQuantities = cartQuantities
    }
}

public struct PersonSettle: Codable, Sendable, Hashable {
    public var step: SettleStep
    public var shareCents: Int
    public var capturedCents: Int
    public var releasedCents: Int
    public var owedCents: Int
    public var approvalCode: String?
    public var captureId: String?
    public var error: String?
}

public struct PayoutRecord: Codable, Sendable, Hashable {
    /// Always true: the Visa Direct payout is simulated, and the UI says so.
    public var simulated: Bool
    public var businessApplicationId: String
    public var amountCents: Int
    public var recipientPan: String
    public var requestId: String
}

public struct Run: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var state: RunState
    public var store: String
    public var shopperId: String
    public var people: [Person]
    public var chips: [Chip]
    public var taxRate: Double
    public var lastCallEndsAt: Double?
    public var receipt: ReceiptState?
    public var settle: [String: PersonSettle]
    public var payout: PayoutRecord?

    public init(
        id: String, state: RunState = .open, store: String = "", shopperId: String,
        people: [Person] = [], chips: [Chip] = [], taxRate: Double = 0, lastCallEndsAt: Double? = nil,
        receipt: ReceiptState? = nil, settle: [String: PersonSettle] = [:], payout: PayoutRecord? = nil
    ) {
        self.id = id; self.state = state; self.store = store; self.shopperId = shopperId
        self.people = people; self.chips = chips; self.taxRate = taxRate
        self.lastCallEndsAt = lastCallEndsAt; self.receipt = receipt; self.settle = settle; self.payout = payout
    }

    public func person(_ id: String) -> Person? { people.first { $0.id == id } }
    public var shopper: Person? { person(shopperId) }
    public func chip(_ id: String) -> Chip? { chips.first { $0.id == id } }
}

extension Run {
    /// Decodes a run from server JSON.
    public static func decode(_ data: Data) throws -> Run {
        try JSONDecoder().decode(Run.self, from: data)
    }
}
