import SwiftUI

/// Everything after the shopper checks out, for one run (web/app/settle): the shopper's receipt camera
/// while locked, the receipt check, then Settle (canvas Settle.dc.html, docs/screenshots/v2-4-settle.jpg)
/// or Partly settled (Partly.dc.html, v2-13-partly.jpg) for everyone.
///
/// Routed as `Route.settle(ref)`. The shopper's way in from the cart is `AppModel.openReceipt(ref)`.
struct SettleView: View {
    let ref: RunRef
    /// Previews pass a run so nothing connects.
    var previewRun: Run?

    @Environment(AppModel.self) private var model
    @State private var busy = false
    @State private var error: String?
    @State private var paid = false

    private var run: Run? {
        if let previewRun { return previewRun }
        return model.store.runId == ref.runId ? model.store.run : nil
    }
    private var isShopper: Bool { run?.shopperId == ref.personId }

    var body: some View {
        content
            .task(id: ref) {
                guard previewRun == nil else { return }
                model.enter(ref)
                paid = model.defaults.bool(forKey: SettleLogic.paidKey(runId: ref.runId))
            }
    }

    @ViewBuilder
    private var content: some View {
        if let run {
            switch run.state {
            case .locked where isShopper:
                ReceiptView(busy: busy, error: error,
                            onSubmit: { b64 in act { _ = try await model.api.receipt(runId: ref.runId, imageBase64: b64); await model.store.refresh() } },
                            onError: { error = $0 })
            case .receipt where run.receipt != nil:
                ReceiptCheckView(run: run, canFix: isShopper, busy: busy, error: error,
                                 onFix: { i, target in act { _ = try await model.api.fixReceiptLine(runId: ref.runId, lineIndex: i, target: target); await model.store.refresh() } },
                                 onConfirm: confirm)
                    .safeAreaInset(edge: .top) { reconnecting }
                    .dibsScreen()
            case .settled, .partlySettled:
                settled(run)
            default:
                waiting(run)
            }
        } else {
            VStack(spacing: Metrics.space2) {
                ProgressView()
                Text(model.store.connection == .refused ? "This run is not available on this phone." : "Loading the run")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .dibsScreen()
        }
    }

    // MARK: settled and partly settled

    private func settled(_ run: Run) -> some View {
        let hero = SettleLogic.hero(run: run, me: ref.personId)
        let heroColor: Color = { if case .settled = hero { return .shopperTeal } else { return .ink } }()
        return ScrollView {
            VStack(spacing: 0) {
                heroView(hero)
                    // Bottom-aligned and tall, so the hero color also fills the bars and any overscroll above.
                    .background(alignment: .bottom) { heroColor.frame(height: 2000) }
                VStack(spacing: Metrics.space2) {
                    reconnecting
                    SettleLines(run: run, me: ref.personId, busy: busy, onRetry: confirm)
                    if SettleLogic.canRetryPayout(run: run, me: ref.personId) {
                        Button(busy ? "Retrying…" : "Retry payout", action: confirm)
                            .buttonStyle(.dibs(.ink, fontSize: 16))
                            .disabled(busy)
                    }
                    if let error { ErrorText(message: error) }
                    if let receipt = run.receipt { ReceiptCard(receipt: receipt) }
                }
                .padding(.horizontal, Metrics.space2)
                .padding(.top, 18)
                .padding(.bottom, Metrics.space3)
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if SettleLogic.isFinished(run) {
                // Settled: forget the run. Partly settled: keep it so the shopper can come back to retry.
                Button(run.state == .settled ? "Start another run" : "Done") {
                    if run.state == .settled { HomeRouting.clearLastRun(defaults: model.defaults) }
                    model.path = []
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.ink)
                .frame(maxWidth: .infinity, minHeight: Metrics.buttonHeight)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.ink))
                .padding(.horizontal, Metrics.space2)
                .padding(.top, Metrics.space1)
                .padding(.bottom, Metrics.space1)
                .background(Color.paper)
            }
        }
        .toolbarBackground(heroColor, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func heroView(_ hero: SettleLogic.Hero) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            switch hero {
            case .settled(let name, let amount, let note):
                HStack(spacing: Metrics.space1) {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold))
                    Text("Run settled · nobody chases anybody")
                }
                .font(.system(size: 13, weight: .medium))
                heroTitle("\(name) gets back", amount: amount, size: 68)
                heroNote(note, color: .tealSoft)
            case .partly(let name, let amount, let note):
                partlyPill
                heroTitle("\(name) gets back so far", amount: amount, size: 60)
                heroNote(note, color: Color.white.opacity(0.85))
            case .owed(let name, let amount, let note):
                partlyPill
                heroTitle("You owe \(name)", amount: amount, size: 60)
                heroNote(note, color: Color.white.opacity(0.85))
                if paid {
                    Label("You marked this paid", systemImage: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .padding(.top, 6)
                } else {
                    Button("I've paid") {
                        paid = true
                        model.defaults.set(true, forKey: SettleLogic.paidKey(runId: ref.runId))
                    }
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 6)
                }
            case .none:
                EmptyView()
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, Metrics.space1)
        .padding(.bottom, 26)
    }

    private var partlyPill: some View {
        Text("Partly settled")
            .font(.system(size: 12, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Color.secondPerson, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func heroTitle(_ title: String, amount: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text(title).font(.display(22))
            Text(amount)
                .font(.display(size))
                .tracking(-2)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func heroNote(_ note: String, color: Color) -> some View {
        Text(note)
            .font(.system(size: 13))
            .lineSpacing(2)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: before the receipt

    private func waiting(_ run: Run) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Wordmark()
            Text("Settle")
                .font(.display(30))
                .foregroundStyle(Color.ink)
            reconnecting
            switch run.state {
            case .open, .lastCall:
                Text("The run is still open.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
                Button("Back to the cart") {
                    model.show(isShopper ? .shopper(ref) : .claim(ref))
                }
                .buttonStyle(.dibs(.secondary))
            default:
                Text(run.state == .receipt ? "Waiting for the shopper to confirm." : "Waiting for the shopper to read the receipt.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.muted)
            }
            if let error { ErrorText(message: error) }
            Spacer()
        }
        .padding(20)
        .dibsScreen()
    }

    @ViewBuilder
    private var reconnecting: some View {
        if previewRun == nil, model.store.connection == .reconnecting {
            Text(RunStore.reconnectingMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: actions

    private func confirm() {
        act {
            let settled = try await model.api.confirm(runId: ref.runId, personId: ref.personId)
            model.store.adopt(settled)
        }
    }

    private func act(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = RunText.capitalize((error as? LocalizedError)?.errorDescription ?? "Something went wrong")
            }
            busy = false
        }
    }
}

#if DEBUG
/// Runs for the receipt and settle previews (the same numbers as the fixtures).
enum SettlePreview {
    static let jake = PreviewData.jake
    static let priya = PreviewData.priya
    static let marcus = PreviewData.marcus
    static let people = [jake, priya, marcus]
    static let chips = [
        Chip(id: "eggs", name: "Kirkland Eggs 24 ct", priceCents: 872, priceSource: .receipt,
             claimers: [priya.id, marcus.id], state: .matched, addedAt: 1),
        Chip(id: "towels", name: "Paper Towels 12 pk", priceCents: 2399, priceSource: .receipt,
             claimers: [priya.id], state: .matched, addedAt: 2),
        Chip(id: "milk", name: "2% Milk", priceCents: 429, priceSource: .receipt, state: .matched, addedAt: 3),
    ]
    static let receipt = ReceiptState(
        lines: [ReceiptLine(text: "KS EGGS 24CT", cents: 872), ReceiptLine(text: "PAPER TOWEL 12PK", cents: 2399),
                ReceiptLine(text: "2% MILK", cents: 429)],
        matches: [ReceiptMatch(chipId: "eggs", lineIndex: 0, confidence: 1),
                  ReceiptMatch(chipId: "towels", lineIndex: 1, confidence: 1),
                  ReceiptMatch(chipId: "milk", lineIndex: 2, confidence: 1)],
        unmatchedLines: []
    )
    static var check: Run {
        var r = Run(id: PreviewData.runId, state: .receipt, store: "costco", shopperId: "jake", people: people,
                    chips: chips, receipt: receipt)
        r.receipt?.lines.append(ReceiptLine(text: "BANANAS", cents: 199))
        r.receipt?.unmatchedLines = [3]
        return r
    }
    static let settledRun = Run(
        id: PreviewData.runId, state: .settled, store: "costco", shopperId: "jake", people: people, chips: chips,
        receipt: receipt,
        settle: [
            priya.id: PersonSettle(step: .captured, shareCents: 2835, capturedCents: 2835, releasedCents: 1165,
                                   owedCents: 0, approvalCode: "888888"),
            marcus.id: PersonSettle(step: .captured, shareCents: 436, capturedCents: 436, releasedCents: 5564,
                                    owedCents: 0, approvalCode: "888888"),
        ],
        payout: PayoutRecord(simulated: true, businessApplicationId: "FD", amountCents: 3271,
                             recipientPan: "4111111111111111", requestId: "r")
    )
    static var partlyRun: Run {
        var r = settledRun
        r.state = .partlySettled
        r.payout = nil
        r.settle[marcus.id] = PersonSettle(step: .failed, shareCents: 436, capturedCents: 0, releasedCents: 0,
                                           owedCents: 0, approvalCode: "888888", error: "declined")
        return r
    }
    static var owedRun: Run {
        var r = settledRun
        r.state = .partlySettled
        r.settle[marcus.id] = PersonSettle(step: .captured, shareCents: 6835, capturedCents: 6000, releasedCents: 0,
                                           owedCents: 835, approvalCode: "888888")
        return r
    }
}

#Preview("Settled") {
    NavigationStack { SettleView(ref: RunRef(runId: PreviewData.runId, personId: "jake"), previewRun: SettlePreview.settledRun) }
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settle")!))
}

#Preview("Partly, shopper") {
    NavigationStack { SettleView(ref: RunRef(runId: PreviewData.runId, personId: "jake"), previewRun: SettlePreview.partlyRun) }
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settle")!))
}

#Preview("Partly, owes") {
    NavigationStack { SettleView(ref: RunRef(runId: PreviewData.runId, personId: PreviewData.marcusId), previewRun: SettlePreview.owedRun) }
        .environment(AppModel(defaults: UserDefaults(suiteName: "preview.settle")!))
}
#endif
