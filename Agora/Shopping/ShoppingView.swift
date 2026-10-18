import SwiftUI

/// The wishlist page: what the household wants (with a target price) and what the assistant suggests.
/// Pushed from the Dibs home. Items are tiles in white cards with the target in display type; the
/// pinned action is "Add item" on the wishlist and "Find ideas" on the suggestions.
struct ShoppingView: View {
    @ObservedObject var store: ShoppingStore
    @ObservedObject var settings: SettingsStore
    @State var selection = "wishlist"
    @State private var adding = false
    @State private var editing: WishlistItem?
    @State private var rejecting: WishlistItem?
    @State private var expandedHistory = false
    @State private var watching: WishlistItem?

    var body: some View {
        HousePage {
            HouseHero(title: selection == "wishlist" ? "Your wishlist" : "Suggested for you",
                      subtitle: selection == "wishlist"
                        ? "Save what you want and the price you'd like to pay. Set up a price watch to review exact product criteria and find matching offers."
                        : "Useful additions, grounded in what you keep at home.")
            HouseSegments(label: "Shopping", options: [("Wishlist", "wishlist"), ("Suggestions", "suggestions")], selection: $selection)
            status
            if selection == "wishlist" { wishlist } else { suggestions }
        } bottom: {
            if selection == "wishlist" {
                Button { adding = true } label: { Label("Add item", systemImage: "plus") }
                    .buttonStyle(.dibs)
                    .disabled(!store.canUse)
            } else {
                Button { Task { await store.findIdeas(settings: settings) } } label: {
                    Label(store.hasPendingIdeas ? "Retry saving ideas" : "Find ideas", systemImage: "sparkles")
                }
                .buttonStyle(.dibs)
                .disabled(store.busy || !store.canUse)
            }
        }
        .overlay { if store.loading && store.items.isEmpty { ProgressView("Loading shopping…") } }
        .refreshable { await store.refresh() }
        .task { await store.refresh(); await store.watches.refresh() }
        .sheet(isPresented: $adding) { WishlistEditor(store: store) }
        .sheet(item: $editing) { WishlistEditor(store: store, item: $0) }
        .sheet(item: $watching) { item in WatchEditor(store: store.watches, itemID: item.id, item: item, watch: store.watches.watch(for: item)) }
        .sheet(item: $rejecting) { WishlistRejection(store: store, item: $0) }
    }

    // MARK: status

    @ViewBuilder private var status: some View {
        if let error = store.error {
            VStack(alignment: .leading, spacing: 10) {
                HouseBanner(message: error, kind: .error)
                Button("Try again") { Task { await store.refresh() } }
                    .buttonStyle(.dibs(.secondary, fontSize: 16))
            }
        }
        if let notice = store.notice { HouseBanner(message: notice) }
        WishlistWatchNotice(store: store.watches)
        if !store.canUse { HouseBanner(message: "Sign in and choose a household in Lists to start.") }
    }

    // MARK: wishlist

    @ViewBuilder private var wishlist: some View {
        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("Wanted · \(store.active.count)")
            if store.active.isEmpty && !store.loading {
                HouseEmpty(symbol: "heart", title: "Make room for something good",
                           message: "Add an item, set a target price, or accept a suggestion.")
            }
            ForEach(store.active) { item in card(item) }
        }

        VStack(spacing: 0) {
            NavigationLink { WatchListView(store: store.watches) } label: {
                DibsLinkRow(title: "Price watches", detail: "Targets Dibs is watching for you", symbol: "binoculars", tint: 0xD3EDE8)
            }
            .buttonStyle(.plain)
            Hairline()
            NavigationLink { WatchInboxView(store: store.watches) } label: {
                DibsLinkRow(title: "Offer inbox", detail: "Offers that matched your targets", symbol: "tray", tint: 0xF2E3B5)
            }
            .buttonStyle(.plain)
        }
        .dibsCard()

        DisclosureGroup(isExpanded: $expandedHistory) {
            VStack(spacing: 0) {
                if store.history.isEmpty {
                    Text("Purchased, removed and rejected items appear here.")
                        .houseNote()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                }
                ForEach(Array(store.history.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Hairline() }
                    historyRow(item)
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("History").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
                Text("\(store.history.count) purchased, removed or rejected").houseNote()
            }
        }
        .tint(Color.ink)
        .dibsCard()
    }

    // MARK: suggestions

    @ViewBuilder private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                DibsSymbolTile(symbol: "arrow.clockwise", tint: 0xD8E2FA)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replenishment").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                    Text("Dibs checks your stock every 6 hours").houseNote()
                }
            }
            if let state = store.refreshStatus {
                VStack(spacing: 0) {
                    if let last = state.lastRefreshedAt {
                        HouseFactRow(title: "Last successful check", value: last.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    } else {
                        Text("Your first replenishment check is pending.")
                            .houseNote()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                    Hairline()
                    HouseFactRow(title: state.nextRefreshAt < Date() ? "Check pending since" : "Next scheduled check",
                                 value: state.nextRefreshAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                }
            }
            if store.refreshStatus?.lastError != nil {
                HousePill(text: "The last check failed. Previous suggestions are still available.", symbol: "exclamationmark.triangle", style: .danger)
            }
            Text("Check stock looks for essentials you may need to replenish. Your targets and decisions stay as you left them.")
                .houseNote()
                .fixedSize(horizontal: false, vertical: true)
            Button { Task { await store.refreshSuggestions() } } label: {
                Label("Check stock", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.dibs(.secondary, fontSize: 16))
            .disabled(store.busy || !store.canUse)
            if store.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Working on your suggestions…").font(.system(size: 14)).foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()

        VStack(alignment: .leading, spacing: 10) {
            HouseSectionTitle("For you · \(store.suggestions.count)")
            if store.suggestions.isEmpty && !store.loading {
                HouseEmpty(symbol: "sparkles", title: "All caught up",
                           message: "Useful ideas will appear here. It's okay if you don't need anything right now.")
            }
            ForEach(store.suggestions) { item in card(item) }
        }

        if !store.snoozed.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HouseSectionTitle("For later · \(store.snoozed.count)")
                ForEach(store.snoozed) { item in card(item) }
            }
        }

        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                Text(settings.featureDescription(.suggestions)).houseNote()
                Text("Find ideas shares inventory names, quantities and suggestion feedback with your selected model. Choose a different model in Settings.")
                    .houseNote()
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            Text("About Find ideas").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
        }
        .tint(Color.ink)
        .dibsCard()
    }

    // MARK: cards

    /// The facts about an item, as capsules under its name.
    private func pills(_ item: WishlistItem) -> some View {
        HouseFlow(spacing: 6) {
            if item.quantity > 1 { HousePill(text: "×\(item.quantity)", style: .ink) }
            if let day = item.neededBy { HousePill(text: "Needed by \(Self.day(day))", symbol: "calendar", style: .line) }
            if let until = item.snoozedUntil {
                HousePill(text: "Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))", symbol: "clock", style: .muted)
            }
            if !item.isPending && item.status != "active" { HousePill(text: item.status.capitalized, style: .muted) }
        }
    }

    /// "2026-10-20" as "Oct 20"; anything else as the server sent it.
    private static func day(_ value: String) -> String {
        WishlistDraft.dateFormatter.date(from: value)?.formatted(.dateTime.month(.abbreviated).day()) ?? value
    }

    private func headerLabel(_ item: WishlistItem) -> String {
        var parts = [item.title]
        if item.pinned { parts.append("pinned") }
        if item.quantity > 1 { parts.append("quantity \(item.quantity)") }
        if let price = item.targetLabel { parts.append("target \(price)") }
        if let day = item.neededBy { parts.append("needed by \(Self.day(day))") }
        return parts.joined(separator: ", ")
    }

    private func card(_ item: WishlistItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HouseTile(seed: item.id.uuidString, label: item.title, size: 48)
                    .overlay(alignment: .topTrailing) {
                        if item.pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(Color.ink))
                                .overlay(Circle().strokeBorder(Color.card, lineWidth: 2))
                                .offset(x: 6, y: -6)
                                .accessibilityHidden(true)
                        }
                    }
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).houseName().lineLimit(3)
                    pills(item)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let price = item.targetLabel {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(price).font(.display(22)).foregroundStyle(Color.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Text("target").houseNote()
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headerLabel(item))

            details(item)
            actions(item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }

    @ViewBuilder private func details(_ item: WishlistItem) -> some View {
        if let notes = item.notes, !notes.isEmpty { Text(notes).houseBody().fixedSize(horizontal: false, vertical: true) }
        if let reason = item.rationale { Text(reason).houseBody().fixedSize(horizontal: false, vertical: true) }
        if !item.priorityReasons.isEmpty {
            Text(item.priorityReasons.prefix(2).joined(separator: " · ")).houseNote().fixedSize(horizontal: false, vertical: true)
        }
        if item.evidence.contains(where: { $0.detail != nil }) {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let detail = evidence.detail { Text(detail).houseNote().fixedSize(horizontal: false, vertical: true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            } label: {
                Text("Why this suggestion?").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.ink)
            }
            .tint(Color.ink)
        }
    }

    @ViewBuilder private func actions(_ item: WishlistItem) -> some View {
        if item.isPending {
            HStack(spacing: 8) {
                Button("Add to wishlist") { Task { await store.act(item, action: "accept") } }
                    .buttonStyle(.houseAction(.primary))
                Menu {
                    Button("Tomorrow") { Task { await store.act(item, action: "snooze", body: ["days": 1]) } }
                    Button("In a week") { Task { await store.act(item, action: "snooze", body: ["days": 7]) } }
                    Button("In a month") { Task { await store.act(item, action: "snooze", body: ["days": 30]) } }
                } label: {
                    iconBox("clock").accessibilityLabel("Snooze suggestion")
                }
                Button { rejecting = item } label: { iconBox("xmark").accessibilityLabel("Reject suggestion") }
                    .buttonStyle(.plain)
            }
            .disabled(store.busy)
            footer(item)
        } else if item.status == "active" {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Button("Set up price watch") { watching = item }.buttonStyle(.houseAction())
                    Button("Purchased") { Task { await store.act(item, action: "purchased") } }
                        .buttonStyle(.houseAction())
                        .disabled(store.busy)
                }
                footer(item, removable: true)
            }
        }
    }

    /// Edit on the left; feedback and remove on the right.
    @ViewBuilder private func footer(_ item: WishlistItem, removable: Bool = false) -> some View {
        if item.editable || item.source == "agent" || removable {
            HStack(spacing: 0) {
                if item.editable {
                    Button("Edit") { editing = item }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap)
                        .padding(.trailing, 12)
                        .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
                if item.source == "agent" {
                    feedbackButton(item, rating: "up", symbol: "hand.thumbsup", label: "Helpful suggestion")
                    feedbackButton(item, rating: "down", symbol: "hand.thumbsdown", label: "Unhelpful suggestion")
                }
                if removable {
                    Button("Remove", role: .destructive) { Task { await store.act(item, action: "remove") } }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.danger)
                        .frame(minHeight: Metrics.tap)
                        .padding(.leading, 12)
                        .buttonStyle(.plain)
                }
            }
            .disabled(store.busy)
        }
    }

    private func feedbackButton(_ item: WishlistItem, rating: String, symbol: String, label: String) -> some View {
        Button { Task { await store.feedback(item, rating: rating) } } label: {
            Image(systemName: item.myFeedback == rating ? symbol + ".fill" : symbol)
                .font(.system(size: 16))
                .foregroundStyle(item.myFeedback == rating ? Color.ink : Color.muted)
                .frame(width: Metrics.tap, height: Metrics.tap)
                .contentShape(Rectangle())
                .accessibilityLabel(label)
        }
        .buttonStyle(.plain)
    }

    private func iconBox(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.ink)
            .frame(width: 48, height: Metrics.tap)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous).strokeBorder(Color.lineStrong))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
    }

    /// A line in History: tile, name, the outcome and the target.
    private func historyRow(_ item: WishlistItem) -> some View {
        HStack(spacing: 12) {
            HouseTile(seed: item.id.uuidString, label: item.title, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(2)
                HousePill(text: item.status.capitalized, style: .muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let price = item.targetLabel {
                Text(price).font(.display(17)).foregroundStyle(Color.ink).monospacedDigit()
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// The price watches' notice (the store is a separate object, so the view watches it itself).
private struct WishlistWatchNotice: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        if let notice = store.notice { HouseBanner(message: notice) }
    }
}

private struct WishlistEditor: View {
    @ObservedObject var store: ShoppingStore
    let item: WishlistItem?
    @State private var draft: WishlistDraft
    @State private var saving = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: ShoppingStore, item: WishlistItem? = nil) {
        self.store = store; self.item = item; _draft = State(initialValue: WishlistDraft(item: item))
    }
    var body: some View {
        NavigationStack {
            HousePage {
                HouseHero(title: item == nil ? "Add to wishlist" : "Edit wishlist item", size: 30,
                          subtitle: item == nil ? "Save what you want and the price you'd like to pay." : item?.title)

                VStack(alignment: .leading, spacing: 14) {
                    HouseField(label: "Name") { TextField("Sourdough starter kit", text: $draft.title) }
                    HouseField(label: "Category (optional)") { TextField("Kitchen", text: $draft.category) }
                    quantity
                    HouseField(label: "Notes", multiline: true) {
                        TextField("Brand, size or anything else", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HouseSectionTitle("Price and timing")
                    HouseField(label: "Target price in USD",
                               note: "Your desired price per item, before shipping and tax. This is a target, not a live offer.") {
                        TextField("Not set", text: $draft.targetPrice).keyboardType(.decimalPad)
                    }
                    Toggle("Needed by a date", isOn: $draft.hasDeadline)
                        .font(.system(size: 16)).foregroundStyle(Color.ink).tint(Color.ink)
                        .dibsInput()
                    if draft.hasDeadline {
                        DatePicker("Needed by", selection: $draft.deadline, displayedComponents: .date)
                            .font(.system(size: 16)).foregroundStyle(Color.ink)
                            .dibsInput()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HouseSectionTitle("Priority")
                    Toggle("Pin to the top", isOn: $draft.pinned)
                        .font(.system(size: 16)).foregroundStyle(Color.ink).tint(Color.ink)
                        .dibsInput()
                    HouseMenu(label: "Priority", selection: $draft.priority) {
                        Text("Automatic").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0)\($0 == 5 ? " · Highest" : "")").tag($0) }
                    }
                }

                if let error { HouseBanner(message: error, kind: .error) }
            } bottom: {
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    Task {
                        do { try await store.save(draft, original: item); dismiss() }
                        catch { self.error = InventoryStore.message(error) }
                        saving = false
                    }
                }
                .buttonStyle(.dibs)
                .disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
        }
    }

    /// A "− N +" row in an input box: 1 to 99.
    private var quantity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quantity").font(.system(size: 13)).foregroundStyle(Color.muted)
            HStack(spacing: 0) {
                Text("\(draft.quantity)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .monospacedDigit()
                Spacer(minLength: 8)
                stepButton("minus", label: "One fewer", enabled: draft.quantity > 1) { draft.quantity -= 1 }
                stepButton("plus", label: "One more", enabled: draft.quantity < 99) { draft.quantity += 1 }
            }
            .padding(.trailing, -8)
            .dibsInput()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Quantity")
            .accessibilityValue("\(draft.quantity)")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: draft.quantity = min(99, draft.quantity + 1)
                case .decrement: draft.quantity = max(1, draft.quantity - 1)
                @unknown default: break
                }
            }
        }
    }

    private func stepButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? Color.ink : Color.lineStrong)
                .frame(width: Metrics.tap, height: Metrics.tap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

private struct WishlistRejection: View {
    @ObservedObject var store: ShoppingStore
    let item: WishlistItem
    @State private var reason = "not_interested"
    @State private var comment = ""
    @Environment(\.dismiss) private var dismiss

    private static let reasons: [(title: String, code: String)] = [
        ("Not interested", "not_interested"), ("Already have it", "already_have"), ("Too expensive", "too_expensive"),
        ("Wrong item", "wrong_item"), ("Other", "other"),
    ]

    var body: some View {
        NavigationStack {
            HousePage {
                HouseHero(title: "Not for you?", size: 30, subtitle: item.title)

                VStack(alignment: .leading, spacing: 10) {
                    HouseSectionTitle("Reason")
                    VStack(spacing: 0) {
                        ForEach(Array(Self.reasons.enumerated()), id: \.element.code) { index, option in
                            if index > 0 { Hairline() }
                            Button { reason = option.code } label: {
                                HStack {
                                    Text(option.title).font(.system(size: 16)).foregroundStyle(Color.ink)
                                    Spacer(minLength: 8)
                                    if reason == option.code {
                                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.ink)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(reason == option.code ? .isSelected : [])
                        }
                    }
                    .dibsCard(padding: Metrics.space2)
                }

                HouseField(label: "Anything else? (optional)",
                           note: "This helps improve future suggestions. We won't suggest this item again for 30 days, except for a lower price after “Too expensive”.",
                           multiline: true) {
                    TextField("Tell us more", text: $comment, axis: .vertical).lineLimit(2...5)
                }

                if let error = store.error { HouseBanner(message: error, kind: .error) }
            } bottom: {
                Button("Reject", role: .destructive) {
                    Task {
                        await store.act(item, action: "reject", body: ["reason_code": reason, "comment": comment])
                        if store.error == nil { dismiss() }
                    }
                }
                .buttonStyle(.dibs)
                .disabled(store.busy || comment.count > 500)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .interactiveDismissDisabled(store.busy)
        }
    }
}
