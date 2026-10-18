#if DEBUG
import Foundation

/// Fixture runs for SwiftUI previews (same people and items as DibsTests/Fixtures/run.json).
enum PreviewData {
    static let runId = "a3a5112e-8e2d-4790-852b-b431bb200e5f"
    static let priyaId = "priya"
    static let marcusId = "marcus"

    static let jake = Person(id: "jake", name: "Jake", initial: "J", isShopper: true, payoutPan: "4111111111111111")
    static let priya = Person(id: priyaId, name: "Priya", initial: "P", isShopper: false,
                              authorizedCents: 4000, authId: "auth-p", approvalCode: "831002")
    static let marcus = Person(id: marcusId, name: "Marcus", initial: "M", isShopper: false,
                               authorizedCents: 6000, authId: "auth-m", approvalCode: "552190")

    static let run = Run(
        id: runId, state: .open, store: "costco", shopperId: "jake",
        people: [jake, priya, marcus],
        chips: [
            Chip(id: "eggs", name: "Eggs, 24 ct", priceCents: 899, priceSource: .web, claimers: [priyaId, marcusId], state: .claimed, addedAt: 3),
            Chip(id: "towels", name: "Paper towels", priceCents: 2199, priceSource: .sticker, claimers: [priyaId], state: .claimed, addedAt: 2),
            Chip(id: "oat", name: "Oat milk", state: .wish, wishedBy: marcusId, addedAt: 4),
            Chip(id: "apples", name: "Honeycrisp apples", priceCents: 649, priceSource: .web, addedAt: 1),
        ],
        taxRate: 0.1025
    )

    /// The invite screen right after starting: nobody in yet.
    static let emptyRun = Run(id: runId, state: .open, store: "costco", shopperId: "jake", people: [jake])

    /// Marcus is in, Priya is still authorizing.
    static let oneInRun = Run(
        id: runId, state: .open, store: "costco", shopperId: "jake",
        people: [jake, Person(id: marcusId, name: "Marcus", initial: "M", isShopper: false, authorizedCents: 4000),
                 Person(id: priyaId, name: "Priya", initial: "P", isShopper: false)]
    )
}
#endif
