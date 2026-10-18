import SwiftUI

struct ShoppingView: View {
    @ObservedObject var store: ShoppingStore
    @ObservedObject var settings: SettingsStore
    @State var selection = "wishlist"
    @State private var adding = false
    @State private var editing: WishlistItem?
    @State private var rejecting: WishlistItem?
    @State private var expandedHistory = false

    var body: some View {
        AgoraList {
            Section {
                Picker("Shopping", selection: $selection) {
                    Text("Wishlist").tag("wishlist")
                    Text("Suggestions").tag("suggestions")
                }.pickerStyle(.segmented)
                if let error = store.error {
                    Text(error).foregroundStyle(.red)
                    Button("Try again") { Task { await store.refresh() } }
                }
                if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
                WatchShoppingNotice(store: store.watches)
                if !store.canUse { Text("Sign in and choose a household in Lists to start.").foregroundStyle(.secondary) }
            }
            if selection == "wishlist" {
                Section {
                    if store.active.isEmpty && !store.loading {
                        AgoraEmptyState(title: "Your wishlist is empty")
                    }
                    ForEach(store.active) { item in row(item) }
                } header: { Text("Your wishlist · \(store.active.count)") }
                Section {
                    DisclosureGroup("History", isExpanded: $expandedHistory) {
                        if store.history.isEmpty { Text("No history yet.").foregroundStyle(.secondary) }
                        ForEach(store.history) { item in row(item) }
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { suggestionActions }
                            VStack(alignment: .leading, spacing: 12) { suggestionActions }
                        }.buttonStyle(.borderless).disabled(store.busy || !store.canUse)
                        if store.busy { ProgressView("Working on your suggestions…") }
                    }
                    if store.refreshStatus?.lastError != nil {
                        Text("The last check failed. Previous suggestions are still available.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("For you · \(store.suggestions.count)") {
                    if store.suggestions.isEmpty && !store.loading {
                        AgoraEmptyState(title: "No suggestions right now")
                    }
                    ForEach(store.suggestions) { item in row(item) }
                }
                if !store.snoozed.isEmpty {
                    Section("For later") { ForEach(store.snoozed) { item in row(item) } }
                }
                Section {
                    DisclosureGroup("Replenishment · every 6 hours") {
                        if let state = store.refreshStatus {
                            if let last = state.lastRefreshedAt { LabeledContent("Last successful check", value: last.formatted(date: .abbreviated, time: .shortened)) }
                            else { Text("Your first replenishment check is pending.").foregroundStyle(.secondary) }
                            LabeledContent(state.nextRefreshAt < Date() ? "Check pending since" : "Next scheduled check", value: state.nextRefreshAt.formatted(date: .abbreviated, time: .shortened))
                        }
                    }.font(.subheadline)
                    DisclosureGroup("About Find ideas") {
                        Text(settings.featureDescription(.suggestions)).font(.caption).foregroundStyle(.secondary)
                        Text("Shares inventory names, quantities and feedback with your selected model.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
            }
        }
        .agoraSurface()
        .navigationTitle(selection == "wishlist" ? "Watch list" : "Suggestions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    NavigationLink { WatchListView(store: store.watches) } label: { Label("Price watches", systemImage: "binoculars") }
                    NavigationLink { WatchInboxView(store: store.watches) } label: { Label("Offer inbox", systemImage: "tray") }
                } label: { Text("More") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Text("Add") }
                    .disabled(!store.canUse)
            }
        }
        .overlay { if store.loading && store.items.isEmpty { ProgressView("Loading shopping…") } }
        .refreshable { await store.refresh(); await store.watches.refresh() }
        .task { await store.refresh(); await store.watches.refresh() }
        .sheet(isPresented: $adding) { WishlistEditor(store: store) }
        .sheet(item: $editing) { WishlistEditor(store: store, item: $0) }
        .sheet(item: $rejecting) { WishlistRejection(store: store, item: $0) }
    }

    @ViewBuilder private var suggestionActions: some View {
        Button(store.hasPendingIdeas ? "Retry saving ideas" : "Find ideas") {
            Task { await store.findIdeas(settings: settings) }
        }.frame(minHeight: 44)
        Button("Check stock") { Task { await store.refreshSuggestions() } }.frame(minHeight: 44)
    }

    private func row(_ item: WishlistItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                ItemThumbnail(kind: "wishlist", id: item.id, name: item.title, category: item.category, size: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title).font(.headline)
                    if let price = item.targetLabel { Text("Target \(price)").font(.subheadline).foregroundStyle(.secondary) }
                    if item.quantity > 1 { Text("Quantity \(item.quantity)").font(.caption).foregroundStyle(.secondary) }
                    if item.pinned { Text("Pinned").font(.caption).foregroundStyle(Color.agoraAccent) }
                }
            }
            if item.status == "active" {
                WishlistWatchSummary(store: store.watches, item: item)
            }
            if item.isPending, let reason = item.rationale {
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            if item.notes?.isEmpty == false || item.neededBy != nil || !item.priorityReasons.isEmpty || item.evidence.contains(where: { $0.detail != nil }) {
                DisclosureGroup("Details") {
                    if let day = item.neededBy { Text("Needed by \(day)") }
                    if let notes = item.notes, !notes.isEmpty { Text(notes) }
                    if !item.priorityReasons.isEmpty { Text(item.priorityReasons.joined(separator: " · ")) }
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let detail = evidence.detail { Text(detail) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            if let until = item.snoozedUntil { Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
            HStack(spacing: 20) {
                if item.isPending {
                    Button("Add to wishlist") { Task { await store.act(item, action: "accept") } }
                } else if item.status != "active" { Text(item.status.capitalized).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
                Menu("Options") {
                    if item.editable { Button("Edit") { editing = item } }
                    if item.isPending {
                        Menu("Snooze") {
                            Button("Tomorrow") { Task { await store.act(item, action: "snooze", body: ["days": 1]) } }
                            Button("In a week") { Task { await store.act(item, action: "snooze", body: ["days": 7]) } }
                            Button("In a month") { Task { await store.act(item, action: "snooze", body: ["days": 30]) } }
                        }
                        Button("Not interested") { rejecting = item }
                    } else if item.status == "active" {
                        Button("Purchased") { Task { await store.act(item, action: "purchased") } }
                        Button("Remove", role: .destructive) { Task { await store.act(item, action: "remove") } }
                    }
                    if item.source == "agent" {
                        Button(item.myFeedback == "up" ? "Marked helpful" : "Helpful") { Task { await store.feedback(item, rating: "up") } }
                        Button(item.myFeedback == "down" ? "Marked unhelpful" : "Unhelpful") { Task { await store.feedback(item, rating: "down") } }
                    }
                }.accessibilityLabel("Options for \(item.title)")
            }.frame(minHeight: 44).disabled(store.busy)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 16)
    }
}

private struct WishlistWatchSummary: View {
    @ObservedObject var store: WatchStore
    let item: WishlistItem
    var body: some View {
        if let watch = store.watch(for: item) {
            VStack(alignment: .leading, spacing: 5) {
                if watch.currentPrices.isEmpty || watch.lastResult == "failed" || store.browserFallbackStatus[watch.id] != nil {
                    Text(store.browserFallbackStatus[watch.id] ?? watch.resultLabel).font(.caption).foregroundStyle(.secondary)
                }
                if let disclosure = watch.simulationDisclosure { Text(disclosure).font(.caption).foregroundStyle(.secondary) }
                if let price = watch.currentPrices.first {
                    Text("\(WishlistItem.money(price.unitPriceCents)) at \(price.merchant)").font(.subheadline)
                    Text(price.comparison(target: watch.criteria.targetPriceCents)).font(.caption)
                }
                NavigationLink("View prices") { WatchDetailView(store: store, watchID: watch.id) }
            }
        } else {
            Text(store.missingWatchStatus).font(.caption).foregroundStyle(.secondary)
        }
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
            Form {
                Section("Item") {
                    TextField("Name", text: $draft.title)
                    Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                }
                Section {
                    TextField("Target price in USD (optional)", text: $draft.targetPrice).keyboardType(.decimalPad)
                } footer: { Text("Per item before tax and shipping. Prices are watched automatically; nothing is purchased.") }
                Section {
                    DisclosureGroup("More details") {
                        TextField("Category", text: $draft.category)
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                        Toggle("Needed by a date", isOn: $draft.hasDeadline)
                        if draft.hasDeadline { DatePicker("Needed by", selection: $draft.deadline, displayedComponents: .date) }
                        Toggle("Pin to the top", isOn: $draft.pinned)
                        Picker("Priority", selection: $draft.priority) {
                            Text("Automatic").tag(0)
                            ForEach(1...5, id: \.self) { Text("\($0)\($0 == 5 ? " · Highest" : "")").tag($0) }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .agoraSurface()
            .navigationTitle(item == nil ? "Add to wishlist" : "Edit wishlist item")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            do { try await store.save(draft, original: item); dismiss() }
                            catch { self.error = InventoryStore.message(error) }
                            saving = false
                        }
                    }.disabled(saving || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.disabled(saving).interactiveDismissDisabled(saving)
        }
    }
}

private struct WishlistRejection: View {
    @ObservedObject var store: ShoppingStore
    let item: WishlistItem
    @State private var reason = "not_interested"
    @State private var comment = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(item.title) {
                    Picker("Reason", selection: $reason) {
                        Text("Not interested").tag("not_interested")
                        Text("Already have it").tag("already_have")
                        Text("Too expensive").tag("too_expensive")
                        Text("Wrong item").tag("wrong_item")
                        Text("Other").tag("other")
                    }
                    TextField("Anything else? (optional)", text: $comment, axis: .vertical)
                    Text("Hidden for 30 days, except for a lower price after “Too expensive”.").font(.caption)
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
            }
            .agoraSurface()
            .navigationTitle("Not for you?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reject", role: .destructive) {
                        Task {
                            await store.act(item, action: "reject", body: ["reason_code": reason, "comment": comment])
                            if store.error == nil { dismiss() }
                        }
                    }.disabled(store.busy || comment.count > 500)
                }
            }.interactiveDismissDisabled(store.busy)
        }
    }
}
