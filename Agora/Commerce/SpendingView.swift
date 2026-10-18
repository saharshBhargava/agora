import SwiftUI

/// The Spending page: what the assistant is waiting on you for, this month's budget and spend, the spending
/// authority you've given it, its recent requests, and the pause switch. Pushed from the Dibs home and from
/// Settings → Spending limits.
struct SpendingView: View {
    @ObservedObject var store: CommerceStore
    @State private var opened: AgentIntent?
    @State private var granting = false
    @State private var revoking: AgentMandate?
    @State private var confirmingPause = false

    var body: some View {
        ShelfPage {
            ShelfHero(title: "Spending", subtitle: subtitle)
            banners
            if store.paused { pausedBanner }
            waiting
            thisMonth
            authority
            recentSection
            killSwitch
        } bottom: {
            Button { granting = true } label: { Label("Give spending authority", systemImage: "plus") }
                .buttonStyle(.dibs(.secondary))
                .disabled(!store.canUse || store.paused || store.busy)
                .accessibilityIdentifier("spending.grant")
        }
        .overlay { if store.loading && !store.loaded { ProgressView("Loading spending…") } }
        .refreshable { await store.refresh() }
        .task(id: store.context) { await store.refresh() }
        .sheet(item: $opened) { ApprovalSheet(store: store, intent: $0) }
        .sheet(isPresented: $granting) { MandateEditor(store: store) }
        .confirmationDialog("Revoke this spending authority?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
                            titleVisibility: .visible, presenting: revoking) { mandate in
            Button("Revoke “\(mandate.label)”", role: .destructive) { Task { await store.revoke(mandate) } }
            Button("Keep it", role: .cancel) {}
        } message: { _ in
            Text("The assistant will ask you before buying anything it covered.")
        }
        .confirmationDialog("Pause the assistant?", isPresented: $confirmingPause, titleVisibility: .visible) {
            Button("Pause the assistant", role: .destructive) { Task { await store.pause() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes all of its spending authority and cancels anything it hasn't started yet.")
        }
    }

    private var subtitle: String {
        let waiting = store.inbox.filter(\.mine).count
        if store.paused { return "The assistant is paused. It can't buy anything until you resume it." }
        if waiting > 0 { return waiting == 1 ? "One purchase is waiting for your OK." : "\(waiting) purchases are waiting for your OK." }
        return "What the assistant may buy for your household, and what it has asked for."
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        if let error = store.error {
            VStack(alignment: .leading, spacing: 10) {
                ShelfBanner(message: error, kind: .error)
                Button("Try again") { Task { await store.refresh() } }
                    .buttonStyle(.dibs(.secondary, fontSize: 16))
            }
        }
        if let notice = store.notice { ShelfBanner(message: notice) }
        if !store.canUse { ShelfBanner(message: "Sign in and choose a household in Lists to start.") }
    }

    private var pausedBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "pause.circle.fill").font(.system(size: 22)).foregroundStyle(Color.danger)
                Text("The assistant is paused").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
            }
            Text("Resuming lets it ask again. Spending authority you revoked stays revoked, so give it again on purpose.")
                .shelfBody().fixedSize(horizontal: false, vertical: true)
            Button(store.busy ? "Resuming…" : "Resume") { Task { await store.resume() } }
                .buttonStyle(.dibs)
                .disabled(store.busy)
                .accessibilityIdentifier("spending.resume")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.space2)
        .background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }

    // MARK: Waiting for you

    @ViewBuilder private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Waiting for you")
            if store.inbox.isEmpty {
                ShelfEmpty(symbol: "checkmark.circle", title: "Nothing to approve",
                           message: "When the assistant needs your OK to buy something, it shows up here.")
            } else {
                ForEach(store.inbox) { intent in
                    Button { opened = intent } label: { WaitingTile(intent: intent) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("spending.waiting.\(intent.id)")
                }
            }
        }
    }

    // MARK: This month

    @ViewBuilder private var thisMonth: some View {
        let budgets = store.budgets.filter { $0.status == "active" }
        let groups = store.spend?.groups ?? []
        if !budgets.isEmpty || !groups.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ShelfSectionTitle("This month")
                VStack(alignment: .leading, spacing: 14) {
                    if let total = store.spend?.totalCents {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spent so far").font(.system(size: 14)).foregroundStyle(Color.muted)
                            Text(CommerceText.money(total)).font(.display(34)).foregroundStyle(Color.ink).monospacedDigit()
                        }
                    }
                    ForEach(budgets) { BudgetBar(budget: $0) }
                    if !groups.isEmpty {
                        ShelfDivider()
                        VStack(spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 { ShelfDivider() }
                                HStack(spacing: 12) {
                                    ShelfTile(seed: group.id, label: group.label, size: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(group.label.capitalized).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                                        Text("\(group.entries) \(group.entries == 1 ? "purchase" : "purchases")").shelfNote()
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(CommerceText.money(group.amountCents)).font(.display(17)).foregroundStyle(Color.ink).monospacedDigit()
                                }
                                .padding(.vertical, 8)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                    Text("The assistant asks before going over a budget.").shelfNote()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dibsCard()
            }
        }
    }

    // MARK: Spending authority

    @ViewBuilder private var authority: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("What the assistant may buy")
            if store.activeMandates.isEmpty {
                ShelfEmpty(symbol: "creditcard", title: "No spending authority",
                           message: store.paused ? "Resume the assistant, then give it spending authority again."
                                                 : "The assistant asks before every purchase. Give it a limit to let it buy small things on its own.")
            } else {
                ForEach(store.activeMandates) { mandate in
                    MandateCard(mandate: mandate, busy: store.busy) { revoking = mandate }
                }
                if !store.mandatesApply {
                    Text("Right now the assistant asks before every purchase, so it won't buy on its own within these limits yet.")
                        .shelfNote().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Recent

    @ViewBuilder private var recentSection: some View {
        if !store.recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ShelfSectionTitle("Recent").padding(.bottom, 6)
                VStack(spacing: 0) {
                    ForEach(Array(store.recent.enumerated()), id: \.element.id) { index, intent in
                        if index > 0 { ShelfDivider() }
                        Button { opened = intent } label: { RecentRow(intent: intent) }
                            .buttonStyle(.plain)
                    }
                }
                .dibsCard(padding: 14)
            }
        }
    }

    // MARK: Kill switch

    @ViewBuilder private var killSwitch: some View {
        if !store.paused {
            VStack(alignment: .leading, spacing: 8) {
                Button { confirmingPause = true } label: {
                    Label(store.busy ? "Pausing…" : "Pause the assistant", systemImage: "pause.fill")
                }
                .buttonStyle(.dibs(.danger))
                .disabled(!store.canUse || store.busy)
                .accessibilityIdentifier("spending.pause")
                Text("Stops it at once: revokes all spending authority and cancels anything not yet started.")
                    .shelfNote().fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Pieces

/// A purchase waiting for approval: tile, title and store, the backend's first reason, the amount in display type.
private struct WaitingTile: View {
    let intent: AgentIntent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ShelfTile(seed: intent.id.uuidString, label: intent.title, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(intent.title).shelfName().lineLimit(2)
                    Text(intent.merchantName ?? "Any store").shelfNote().lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let cents = intent.displayCents {
                    Text(CommerceText.money(cents)).font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            if let reason = intent.decisionReasons.first {
                Text(reason)
                    .font(.system(size: 14))
                    .foregroundStyle(intent.hasWarning ? Color.danger : Color.bodyInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ShelfPill(text: intent.mine ? "Waiting for you" : "Waiting for a housemate", style: .ink)
                if let window = CommerceText.approvalWindow(intent) { ShelfPill(text: window, style: .muted) }
                Spacer(minLength: 0)
                DibsChevron()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
        .contentShape(Rectangle())
    }
}

/// Spent (solid) plus pending (lighter) against the limit, red when over.
struct BudgetBar: View {
    let budget: SpendBudget

    var body: some View {
        let limit = max(1, budget.limitCents)
        let spent = min(1, Double(budget.spentCents) / Double(limit))
        let pending = min(1 - spent, Double(budget.pendingCents) / Double(limit))
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(budget.category.map { "\($0.capitalized) budget" } ?? "Household budget")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                Spacer(minLength: 8)
                (Text(CommerceText.money(budget.spentCents)).font(.display(17)).foregroundStyle(Color.ink)
                 + Text("  of \(CommerceText.shortMoney(budget.limitCents))").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(Color.muted))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(budget.isOver ? Color.danger : Color.ink).frame(width: geo.size.width * spent)
                    Rectangle().fill(Color.ink.opacity(0.3)).frame(width: geo.size.width * pending)
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            .background(Color.line)
            .clipShape(Capsule())
            .accessibilityHidden(true)
            Text(line).font(.system(size: 13)).foregroundStyle(budget.isOver ? Color.danger : Color.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private var line: String {
        var parts: [String] = []
        if budget.isOver { parts.append("\(CommerceText.money(-budget.remainingCents)) over") }
        else { parts.append("\(CommerceText.money(budget.remainingCents)) left this \(CommerceText.period(budget.period))") }
        if budget.pendingCents > 0 { parts.append("\(CommerceText.money(budget.pendingCents)) pending") }
        return parts.joined(separator: " · ")
    }
}

/// One spending authority: label, limits, scope pills, period progress and Revoke.
private struct MandateCard: View {
    let mandate: AgentMandate
    let busy: Bool
    let onRevoke: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                DibsSymbolTile(symbol: "creditcard", tint: 0xD3EDE8)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mandate.label).shelfName()
                    Text(CommerceText.limits(mandate)).shelfNote().fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(CommerceText.shortMoney(mandate.maxPerTxnCents)).font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
            }
            ShelfFlow(spacing: 6) {
                if let categories = mandate.categories, !categories.isEmpty {
                    ForEach(categories, id: \.self) { ShelfPill(text: $0.capitalized) }
                } else {
                    ShelfPill(text: "Any category")
                }
                if let ids = mandate.merchantIds, !ids.isEmpty {
                    ShelfPill(text: ids.count == 1 ? "1 store" : "\(ids.count) stores", symbol: "storefront")
                }
                if let above = mandate.requireConfirmAboveCents { ShelfPill(text: "Asks above \(CommerceText.shortMoney(above))", style: .muted) }
                ShelfPill(text: CommerceText.expires(mandate.expiresAt), style: .muted)
            }
            if let cap = mandate.maxPerPeriodCents {
                let fraction = min(1, Double(mandate.spentThisPeriodCents) / Double(max(1, cap)))
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geo in
                        Rectangle().fill(Color.ink).frame(width: geo.size.width * fraction)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 8)
                    .background(Color.line)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                    Text("\(CommerceText.money(mandate.spentThisPeriodCents)) of \(CommerceText.shortMoney(cap)) used this \(CommerceText.period(mandate.period))")
                        .shelfNote()
                }
            }
            ShelfDivider()
            Button("Revoke", role: .destructive, action: onRevoke)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.danger)
                .frame(minHeight: Metrics.tap)
                .buttonStyle(.plain)
                .disabled(busy)
                .accessibilityIdentifier("spending.revoke.\(mandate.id)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }
}

/// A finished or moving request in Recent: tile, title, who decided, status pill and amount.
private struct RecentRow: View {
    let intent: AgentIntent

    var body: some View {
        HStack(spacing: 12) {
            ShelfTile(seed: intent.id.uuidString, label: intent.title, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(intent.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                HStack(spacing: 6) {
                    ShelfPill(text: CommerceText.status(intent), style: pillStyle)
                    if let who = CommerceText.decidedBy(intent) { Text(who).shelfNote().lineLimit(1) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let cents = intent.displayCents {
                Text(CommerceText.money(cents)).font(.display(17)).foregroundStyle(Color.ink).monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var pillStyle: ShelfPill.Style {
        switch intent.status {
        case "failed", "outcome_unknown": return .danger
        case "rejected" where intent.decidedBy == "policy": return .danger
        case "succeeded", "approved", "executing": return .line
        default: return .muted
        }
    }
}

// MARK: - Approval sheet

/// One request: what, how much, where, why the assistant wants it, why it's asking you (the backend's reasons,
/// verbatim and in order) and the card it would charge. Approve and Reject when it's yours and still open;
/// read-only otherwise. After a decision it shows what actually happened.
struct ApprovalSheet: View {
    @ObservedObject var store: CommerceStore
    @State private var intent: AgentIntent
    @State private var rejecting = false
    @State private var reason: String?
    @State private var working = false
    @State private var error: String?
    @State private var decided = false
    @Environment(\.dismiss) private var dismiss

    init(store: CommerceStore, intent: AgentIntent) {
        self.store = store
        _intent = State(initialValue: intent)
    }

    var body: some View {
        NavigationStack {
            ShelfPage(bottomVisible: intent.canApprove() && !decided) {
                header
                if decided || !intent.waitingForApproval { outcome }
                if !intent.decisionReasons.isEmpty { reasons }
                why
                facts
                if !intent.mine && intent.waitingForApproval {
                    ShelfBanner(message: "This request is waiting for the housemate whose assistant made it.")
                }
                if let window = CommerceText.approvalWindow(intent), intent.mine { Text(window).shelfNote() }
                if rejecting { rejectPicker }
                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                VStack(spacing: Metrics.space1) {
                    if rejecting {
                        Button(working ? "Rejecting…" : "Reject") { decide(approve: false) }
                            .buttonStyle(.dibs)
                            .accessibilityIdentifier("approval.confirmReject")
                    } else {
                        Button(working ? (intent.isAgoraCheckout ? "Buying…" : "Approving…") : approveTitle) { decide(approve: true) }
                            .buttonStyle(.dibs)
                            .accessibilityIdentifier("approval.approve")
                        Button("Reject") { rejecting = true }
                            .buttonStyle(.dibs(.secondary))
                            .accessibilityIdentifier("approval.reject")
                    }
                }
                .disabled(working)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(decided ? "Done" : "Close") { dismiss() }.disabled(working) }
            }
            .interactiveDismissDisabled(working)
        }
    }

    private var approveTitle: String {
        guard let cents = intent.amountCents else { return "Approve" }
        return intent.isAgoraCheckout ? "Approve and pay \(CommerceText.money(cents))" : "Approve"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                ShelfTile(seed: intent.id.uuidString, label: intent.title, size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(intent.title).font(.display(26)).foregroundStyle(Color.ink).fixedSize(horizontal: false, vertical: true)
                    Text(intent.merchantName ?? "Any store").shelfBody()
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if let cents = intent.displayCents {
                    Text(CommerceText.money(cents)).font(.display(44)).foregroundStyle(Color.ink).monospacedDigit()
                }
                if intent.isAgoraCheckout { ShelfPill(text: "Dibs checkout", symbol: "creditcard") }
            }
            ShelfFlow(spacing: 6) {
                ShelfPill(text: CommerceText.status(intent), style: intent.waitingForApproval ? .ink : .line)
                if let who = CommerceText.decidedBy(intent) { ShelfPill(text: who, style: .muted) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outcome: some View {
        Text(CommerceText.outcome(intent))
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(["failed", "outcome_unknown"].contains(intent.status) || intent.decidedBy == "policy" && intent.status == "rejected" ? Color.danger : Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .dibsCard(radius: 14, padding: 14)
            .accessibilityIdentifier("approval.outcome")
    }

    private var reasons: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfSectionTitle(intent.waitingForApproval ? "Why it's asking you" : "What Dibs said")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(intent.decisionReasons.enumerated()), id: \.offset) { index, reason in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: index == 0 && intent.hasWarning ? "exclamationmark.triangle.fill" : "circle.fill")
                            .font(.system(size: index == 0 && intent.hasWarning ? 14 : 6))
                            .foregroundStyle(index == 0 && intent.hasWarning ? Color.danger : Color.muted)
                            .frame(width: 16, height: 20)
                            .accessibilityHidden(true)
                        Text(reason)
                            .font(.system(size: 15, weight: index == 0 ? .semibold : .regular))
                            .foregroundStyle(index == 0 ? Color.ink : Color.bodyInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
        }
    }

    @ViewBuilder private var why: some View {
        if !intent.rationale.isEmpty || !intent.evidence.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ShelfSectionTitle("Why the assistant wants this")
                VStack(alignment: .leading, spacing: 10) {
                    if !intent.rationale.isEmpty { Text(intent.rationale).shelfBody().fixedSize(horizontal: false, vertical: true) }
                    ForEach(Array(intent.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: CommerceText.evidenceSymbol(evidence.kind))
                                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted).frame(width: 18)
                                .accessibilityHidden(true)
                            Text(evidence.detail).shelfNote().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dibsCard()
            }
        }
    }

    @ViewBuilder private var facts: some View {
        let rows = factRows
        if !rows.isEmpty || intent.productURL != nil {
            VStack(alignment: .leading, spacing: 4) {
                if !rows.isEmpty { ShelfFacts(rows: rows) }
                if let url = intent.productURL {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text("View product page")
                            Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .bold))
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap)
                    }
                }
            }
            .dibsCard(padding: 14)
        }
    }

    private var factRows: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = []
        if let quantity = intent.payload.quantity, quantity > 1 { rows.append(("Quantity", "\(quantity)")) }
        if let category = intent.category { rows.append(("Category", category.capitalized)) }
        if let card = intent.paymentLabel { rows.append(("Payment", card)) }
        if intent.orderId != nil { rows.append(("Order", "Placed")) }
        rows.append(("Asked", intent.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())))
        return rows
    }

    private var rejectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfSectionTitle("Why not? (optional)")
            ShelfFlow(spacing: 8) {
                ForEach(CommerceText.rejectReasons, id: \.code) { option in
                    let chosen = reason == option.code
                    Button { reason = chosen ? nil : option.code } label: {
                        Text(option.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(chosen ? Color.white : Color.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: Metrics.tap)
                            .background(chosen ? Color.ink : Color.card, in: Capsule())
                            .overlay(Capsule().strokeBorder(chosen ? Color.ink : Color.lineStrong))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(chosen ? .isSelected : [])
                }
            }
            Button("Keep it waiting") { rejecting = false; reason = nil }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).frame(minHeight: Metrics.tap)
                .buttonStyle(.plain)
        }
    }

    private func decide(approve: Bool) {
        working = true; error = nil
        Task {
            defer { working = false }
            do {
                intent = approve ? try await store.approve(intent) : try await store.reject(intent, reason: reason)
                decided = true; rejecting = false
            } catch is CancellationError {
                dismiss()
            } catch {
                self.error = CommerceStore.message(error)
                if let current = store.inbox.first(where: { $0.id == intent.id }) ?? store.recent.first(where: { $0.id == intent.id }) {
                    intent = current
                }
            }
        }
    }
}

// MARK: - Give spending authority

struct MandateEditor: View {
    @ObservedObject var store: CommerceStore
    @State private var draft = MandateDraft()
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    private var problem: MandateDraft.Problem? {
        do { _ = try draft.body(householdID: nil); return nil } catch let problem as MandateDraft.Problem { return problem } catch { return .label }
    }

    var body: some View {
        NavigationStack {
            ShelfPage {
                ShelfHero(title: "Give spending authority", size: 30,
                          subtitle: "Let the assistant buy small things on its own, within these limits. It still asks for anything outside them.")
                VStack(alignment: .leading, spacing: 14) {
                    ShelfField(label: "Name") {
                        TextField("Weekly groceries", text: $draft.label).accessibilityIdentifier("mandate.label")
                    }
                    ShelfField(label: "Most per purchase") {
                        TextField("$25", text: $draft.maxPerPurchase).keyboardType(.decimalPad).accessibilityIdentifier("mandate.perPurchase")
                    }
                    HStack(alignment: .top, spacing: Metrics.space1) {
                        ShelfField(label: "Limit per period (optional)", note: problem == .periodLimit ? "At least the per-purchase amount." : nil) {
                            TextField("$200", text: $draft.periodLimit).keyboardType(.decimalPad).accessibilityIdentifier("mandate.periodLimit")
                        }
                    }
                    ShelfChoice(label: "Period", options: MandateDraft.periods.map { (title: $0.0, value: $0.1) }, selection: $draft.period)
                    ShelfField(label: "Still ask me above (optional)") {
                        TextField("$15", text: $draft.confirmAbove).keyboardType(.decimalPad)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ShelfSectionTitle("Categories")
                    Text("None chosen means any category.").shelfNote()
                    ShelfFlow(spacing: 8) {
                        ForEach(MandateDraft.suggestedCategories, id: \.self) { category in
                            let chosen = draft.categories.contains(category)
                            Button {
                                if chosen { draft.categories.removeAll { $0 == category } } else { draft.categories.append(category) }
                            } label: {
                                Text(category.capitalized)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(chosen ? Color.white : Color.ink)
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: Metrics.tap)
                                    .background(chosen ? Color.ink : Color.card, in: Capsule())
                                    .overlay(Capsule().strokeBorder(chosen ? Color.ink : Color.lineStrong))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                    }
                }
                ShelfMenu(label: "Expires after", selection: $draft.expiresInDays) {
                    ForEach(MandateDraft.expiries, id: \.1) { Text($0.0).tag($0.1) }
                }
                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button(saving ? "Saving…" : "Give authority") { save() }
                    .buttonStyle(.dibs)
                    .disabled(problem != nil || saving)
                    .accessibilityIdentifier("mandate.save")
            }
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
            }
            .interactiveDismissDisabled(saving)
        }
    }

    private func save() {
        saving = true; error = nil
        Task {
            defer { saving = false }
            do { _ = try await store.grant(draft); dismiss() }
            catch is CancellationError { dismiss() }
            catch { self.error = CommerceStore.message(error) }
        }
    }
}
