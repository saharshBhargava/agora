import XCTest
@testable import Dibs

/// Settle, partly settled and receipt check values from runs captured from the real server
/// (stub vision, stub prices, simulated payments).
final class SettleLogicTests: XCTestCase {
    private let priyaSettled = "252defdd-68a7-473a-96c3-0f1b5e781df6"
    private let marcusSettled = "abea27ec-1781-4719-8fac-382dc040dcee"
    private let priya = "71fccf2e-7e32-4308-a0ce-8fd62cce1c68"
    private let marcus = "4ca8c39e-8d01-450b-b805-3eae20ca2be7"

    private func load(_ name: String) throws -> Run { try Run.decode(fixtureData(name)) }

    // MARK: settled

    func testSettledHeroShowsThePayout() throws {
        let run = try load("run-settled")
        XCTAssertEqual(SettleLogic.hero(run: run, me: "jake"), .settled(
            shopperName: "Jake",
            amount: "$32.71",
            note: "Pushed to Jake's card over Visa Direct (simulated in this build)."
        ))
    }

    func testSettledCardsShowCapturedReleasedAndApproval() throws {
        let run = try load("run-settled")
        let cards = SettleLogic.cards(run: run, me: priyaSettled)
        XCTAssertEqual(cards.map(\.name), ["Priya", "Marcus"])
        XCTAssertEqual(cards[0], SettleLogic.Card(
            personId: priyaSettled, name: "Priya", sub: "$11.65 released · settles tonight",
            amount: "$28.35", muted: false, auth: "auth 888888", failed: false, retry: nil))
        XCTAssertEqual(cards[1].sub, "$25.64 released · settles tonight")
        XCTAssertEqual(cards[1].amount, "$4.36")
        XCTAssertEqual(cards[1].auth, "auth 888888")
    }

    func testSettledReceiptCard() throws {
        let run = try load("run-settled")
        let receipt = try XCTUnwrap(run.receipt)
        XCTAssertEqual(SettleLogic.matchedLabel(receipt), "2 of 3 lines matched")
        XCTAssertEqual(SettleLogic.receiptRows(receipt).map(\.text), ["KS EGGS 24CT", "PAPER TOWEL 12PK", "2% MILK"])
        XCTAssertEqual(SettleLogic.receiptRows(receipt).map(\.amount), ["8.72", "23.99", "4.29"])
        XCTAssertEqual(SettleLogic.receiptTotal(receipt), "37.00")
    }

    func testStaysWithNamesUnclaimedItemsAndMineLines() throws {
        // The settled fixture's 2% MILK line is unmatched and not marked Mine: nothing stays.
        XCTAssertNil(SettleLogic.staysWith(run: try load("run-settled")))
        // In the partly fixture, the 2% Milk chip matched and nobody claimed it.
        var run = try load("run-partly")
        XCTAssertEqual(SettleLogic.staysWith(run: run), "2% Milk, $4.29, stays with Jake.")
        run.receipt?.lines.append(ReceiptLine(text: "BANANAS", cents: 199))
        run.receipt?.mine = [3]
        XCTAssertEqual(SettleLogic.staysWith(run: run), "2% Milk ($4.29) and BANANAS ($1.99) stay with Jake.")
    }

    func testSettledHeroAddsWhatStays() throws {
        var run = try load("run-partly")
        run.state = .settled
        run.settle[marcus] = PersonSettle(step: .captured, shareCents: 436, capturedCents: 436, releasedCents: 3564,
                                          owedCents: 0, approvalCode: "888888")
        run.payout = PayoutRecord(simulated: true, businessApplicationId: "FD", amountCents: 3271,
                                  recipientPan: "4111111111111111", requestId: "r")
        guard case .settled(_, let amount, let note) = SettleLogic.hero(run: run, me: priya) else {
            return XCTFail("expected settled hero")
        }
        XCTAssertEqual(amount, "$32.71")
        XCTAssertEqual(note, "Pushed to Jake's card over Visa Direct (simulated in this build). 2% Milk, $4.29, stays with Jake.")
    }

    // MARK: partly settled

    func testPartlyHeroShowsWhatCameBackSoFar() throws {
        let run = try load("run-partly")
        XCTAssertEqual(SettleLogic.hero(run: run, me: "jake"), .partly(
            shopperName: "Jake",
            amount: "$28.35",
            note: "One share didn't go through. Retrying never repeats what already worked."
        ))
    }

    func testPartlyFailedCardHasRetryForTheShopperOnly() throws {
        let run = try load("run-partly")
        let shopperCards = SettleLogic.cards(run: run, me: "jake")
        XCTAssertEqual(shopperCards[0].sub, "$11.65 released · settles tonight")
        XCTAssertEqual(shopperCards[0].amount, "$28.35")
        XCTAssertEqual(shopperCards[1], SettleLogic.Card(
            personId: marcus, name: "Marcus", sub: "Didn't go through", amount: "$4.36",
            muted: true, auth: nil, failed: true, retry: "Retry Marcus"))

        let claimerCards = SettleLogic.cards(run: run, me: priya)
        XCTAssertEqual(claimerCards[1].sub, "Didn't go through, Jake will retry")
        XCTAssertNil(claimerCards[1].retry)
    }

    func testTwoFailedSharesAndNothingCaptured() throws {
        var run = try load("run-partly")
        run.settle[priya]?.step = .failed
        run.settle[priya]?.capturedCents = 0
        XCTAssertEqual(SettleLogic.hero(run: run, me: "jake"), .partly(
            shopperName: "Jake", amount: "$0",
            note: "2 shares didn't go through. Retrying never repeats what already worked."))
    }

    func testReleasedEverythingCard() throws {
        var run = try load("run-partly")
        run.settle[marcus] = PersonSettle(step: .reversed, shareCents: 0, capturedCents: 0, releasedCents: 4000,
                                          owedCents: 0, approvalCode: "888888")
        let card = SettleLogic.cards(run: run, me: "jake")[1]
        XCTAssertEqual(card.sub, "Nothing captured · $40.00 released")
        XCTAssertEqual(card.amount, "$0")
        XCTAssertTrue(card.muted)
        XCTAssertNil(card.auth)
    }

    func testOwedShareShowsOnTheCardAndInTheClaimersHero() throws {
        // A raised share the hold could not cover: captured up to the hold, the rest owed.
        var run = try load("run-partly")
        run.settle[marcus] = PersonSettle(step: .captured, shareCents: 4835, capturedCents: 4000, releasedCents: 0,
                                          owedCents: 835, approvalCode: "888888")
        run.payout = PayoutRecord(simulated: true, businessApplicationId: "FD", amountCents: 6835,
                                  recipientPan: "4111111111111111", requestId: "r")
        XCTAssertEqual(SettleLogic.cards(run: run, me: "jake")[1].sub, "Captured $40.00 · $8.35 owed")
        XCTAssertEqual(SettleLogic.hero(run: run, me: "jake"), .partly(
            shopperName: "Jake", amount: "$68.35", note: "Marcus still owes $8.35."))
        XCTAssertEqual(SettleLogic.hero(run: run, me: marcus), .owed(
            shopperName: "Jake", amount: "$8.35",
            note: "Your hold covered $40.00. Pay Jake the rest directly."))
        XCTAssertEqual(SettleLogic.hero(run: run, me: priya), .partly(
            shopperName: "Jake", amount: "$68.35", note: "Marcus still owes $8.35."))
    }

    func testPayoutFailureOffersARetry() throws {
        var run = try load("run-partly")
        run.settle[marcus] = PersonSettle(step: .captured, shareCents: 436, capturedCents: 436, releasedCents: 3564,
                                          owedCents: 0, approvalCode: "888888")
        XCTAssertEqual(SettleLogic.hero(run: run, me: "jake"), .partly(
            shopperName: "Jake", amount: "$32.71",
            note: "The payout didn't go through. Retrying never repeats what already worked."))
        XCTAssertTrue(SettleLogic.canRetryPayout(run: run, me: "jake"))
        XCTAssertFalse(SettleLogic.canRetryPayout(run: run, me: priya))
        XCTAssertFalse(SettleLogic.canRetryPayout(run: try load("run-partly"), me: "jake"))
    }

    // MARK: receipt check

    func testCheckRowsFromAFullyMatchedReceipt() throws {
        let run = try load("run-receipt")
        let rows = SettleLogic.checkRows(run: run)
        XCTAssertEqual(rows.map(\.sub), [
            "Kirkland Eggs 24 ct · Priya, Marcus",
            "Paper Towels 12 pk · Priya",
            "2% Milk · yours",
        ])
        XCTAssertEqual(rows.map(\.amount), ["$8.72", "$23.99", "$4.29"])
        XCTAssertEqual(rows.map(\.match), ["100% match", "100% match", "100% match"])
        XCTAssertFalse(rows.contains { $0.needsYou })
        XCTAssertEqual(SettleLogic.checkSubtitle(try XCTUnwrap(run.receipt)), "3 lines matched")
        XCTAssertEqual(SettleLogic.captured(run: run), .init(label: "Captured from Priya and Marcus", amount: "$32.71"))
        XCTAssertTrue(SettleLogic.pairable(run: run).isEmpty)
        XCTAssertNil(SettleLogic.notOnReceipt(run: run))
    }

    func testUnmatchedLineNeedsTheShopper() throws {
        var run = try load("run-receipt")
        // The receipt read missed the milk: its line is unmatched and the chip is free to pair.
        run.receipt?.matches.removeLast()
        run.receipt?.unmatchedLines = [2]
        let receipt = try XCTUnwrap(run.receipt)
        let rows = SettleLogic.checkRows(run: run)
        XCTAssertTrue(rows[2].needsYou)
        XCTAssertNil(rows[2].sub)
        XCTAssertNil(rows[2].match)
        XCTAssertEqual(SettleLogic.checkSubtitle(receipt), "2 lines matched · 1 needs you")
        XCTAssertEqual(SettleLogic.pairable(run: run).map(\.name), ["2% Milk"])
        XCTAssertEqual(SettleLogic.notOnReceipt(run: run), "Not on receipt: 2% Milk")

        run.receipt?.mine = [2]
        run.receipt?.unmatchedLines = []
        let mine = SettleLogic.checkRows(run: run)[2]
        XCTAssertFalse(mine.needsYou)
        XCTAssertEqual(mine.sub, "Mine")
        XCTAssertEqual(SettleLogic.checkSubtitle(try XCTUnwrap(run.receipt)), "2 lines matched")
    }

    func testTaxLineIsSpreadAndNeverNeedsYou() throws {
        var run = try load("run-receipt")
        run.receipt?.lines.append(ReceiptLine(text: "TAX", cents: 120, isTax: true))
        let rows = SettleLogic.checkRows(run: run)
        XCTAssertEqual(rows[3].sub, "Tax, spread across the lines")
        XCTAssertFalse(rows[3].needsYou)
        XCTAssertEqual(SettleLogic.matchedLabel(try XCTUnwrap(run.receipt)), "3 of 3 lines matched")
    }

    func testTwoNeedYou() throws {
        var run = try load("run-receipt")
        let first = try XCTUnwrap(run.receipt?.matches.first)
        run.receipt?.matches = [first]
        run.receipt?.unmatchedLines = [1, 2]
        XCTAssertEqual(SettleLogic.checkSubtitle(try XCTUnwrap(run.receipt)), "1 line matched · 2 need you")
    }

    // MARK: routing

    func testClaimAndShopperScreensMoveToSettle() throws {
        let partly = try load("run-partly")
        let claim = RunRef(runId: partly.id, personId: priya)
        let shop = RunRef(runId: partly.id, personId: "jake")
        XCTAssertEqual(SettleLogic.follow(path: [.claim(claim)], run: partly), [.settle(claim)])
        XCTAssertEqual(SettleLogic.follow(path: [.shopper(shop)], run: partly), [.settle(shop)])
        XCTAssertNil(SettleLogic.follow(path: [.settle(shop)], run: partly))
        // Back from a finished Settle goes Home, not to the stale cart underneath.
        XCTAssertEqual(SettleLogic.follow(path: [.shopper(shop), .settle(shop)], run: partly), [.settle(shop)])
        XCTAssertEqual(SettleLogic.follow(path: [.claim(claim), .settle(claim)], run: partly), [.settle(claim)])
        XCTAssertNil(SettleLogic.follow(path: [], run: partly))
        XCTAssertNil(SettleLogic.follow(path: [.claim(RunRef(runId: "other", personId: priya))], run: partly))

        let receipt = try load("run-receipt")
        XCTAssertEqual(SettleLogic.follow(path: [.shopper(shop)], run: receipt), [.settle(shop)])
        XCTAssertNil(SettleLogic.follow(path: [.claim(claim)], run: receipt), "claimers wait on the claim screen")
        var locked = receipt
        locked.state = .locked
        XCTAssertNil(SettleLogic.follow(path: [.shopper(shop)], run: locked), "the shopper taps through to the receipt")
        XCTAssertNil(SettleLogic.follow(path: [.shopper(shop), .settle(shop)], run: receipt), "Back returns to the cart mid-check")
    }

    func testReceiptPathPushesWhileCheckingOutAndReplacesOnceFinished() throws {
        let receipt = try load("run-receipt")
        let shop = RunRef(runId: receipt.id, personId: "jake")
        var locked = receipt
        locked.state = .locked
        XCTAssertEqual(SettleLogic.receiptPath(path: [.shopper(shop)], ref: shop, run: locked), [.shopper(shop), .settle(shop)])
        XCTAssertEqual(SettleLogic.receiptPath(path: [.shopper(shop), .settle(shop)], ref: shop, run: locked), [.shopper(shop), .settle(shop)])
        XCTAssertEqual(SettleLogic.receiptPath(path: [.shopper(shop)], ref: shop, run: nil), [.shopper(shop), .settle(shop)])
        var settled = receipt
        settled.state = .settled
        XCTAssertEqual(SettleLogic.receiptPath(path: [.shopper(shop)], ref: shop, run: settled), [.settle(shop)])
        var partly = receipt
        partly.state = .partlySettled
        XCTAssertEqual(SettleLogic.receiptPath(path: [.shopper(shop)], ref: shop, run: partly), [.settle(shop)])
    }

    // MARK: receipt photo

    func testReceiptPhotoFitsTwoThousandPixels() throws {
        XCTAssertEqual(ReceiptImage.targetSize(for: CGSize(width: 3024, height: 4032)), CGSize(width: 1800, height: 2400))
        XCTAssertEqual(ReceiptImage.targetSize(for: CGSize(width: 4800, height: 1200)), CGSize(width: 2400, height: 600))
        XCTAssertEqual(ReceiptImage.targetSize(for: CGSize(width: 1200, height: 1600)), CGSize(width: 1200, height: 1600))

        let big = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }()).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        let base64 = try XCTUnwrap(ReceiptImage.jpegBase64(big))
        let decoded = try XCTUnwrap(UIImage(data: try XCTUnwrap(Data(base64Encoded: base64))))
        XCTAssertEqual(decoded.size.width * decoded.scale, 2400)
        XCTAssertEqual(decoded.size.height * decoded.scale, 1200)
    }

    func testBusyReceiptPhotoFitsTheServerBodyLimit() throws {
        // Random noise compresses badly: several MB even at 1500x2000.
        let w = 1500, h = 2000
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 12345
        for i in bytes.indices { seed = seed &* 1664525 &+ 1013904223; bytes[i] = UInt8(truncatingIfNeeded: seed >> 24) }
        let cg = try XCTUnwrap(bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        })
        let image = UIImage(cgImage: cg)
        let base64 = try XCTUnwrap(ReceiptImage.jpegBase64(image))
        XCTAssertLessThanOrEqual(base64.utf8.count, ReceiptImage.maxBase64Bytes)
        XCTAssertEqual(ReceiptImage.maxBase64Bytes, 6_000_000)
        // A tighter cap forces the quality and size steps.
        let small = try XCTUnwrap(ReceiptImage.jpegBase64(image, maxBytes: 1_500_000))
        XCTAssertLessThanOrEqual(small.utf8.count, 1_500_000)
        XCTAssertNotNil(UIImage(data: try XCTUnwrap(Data(base64Encoded: small))))
    }

    func testWhichScreenTheSettleRouteShows() throws {
        let receipt = try load("run-receipt")
        var locked = receipt
        locked.state = .locked
        locked.receipt = nil
        XCTAssertEqual(SettleLogic.screen(run: locked, isShopper: true, retaking: false), .camera)
        XCTAssertEqual(SettleLogic.screen(run: locked, isShopper: false, retaking: false), .waiting)
        XCTAssertEqual(SettleLogic.screen(run: receipt, isShopper: true, retaking: false), .check)
        // Retake: the shopper's camera comes back during the check; claimers keep the check.
        XCTAssertEqual(SettleLogic.screen(run: receipt, isShopper: true, retaking: true), .camera)
        XCTAssertEqual(SettleLogic.screen(run: receipt, isShopper: false, retaking: true), .check)
        XCTAssertEqual(SettleLogic.screen(run: try load("run-partly"), isShopper: true, retaking: true), .settle)
        var open = receipt
        open.state = .open
        XCTAssertEqual(SettleLogic.screen(run: open, isShopper: true, retaking: false), .waiting)
        XCTAssertEqual(SettleLogic.readingMessage, "Reading the receipt… this takes about 20 seconds")
    }
}
