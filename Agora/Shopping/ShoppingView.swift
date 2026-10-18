import SwiftUI

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
        List {
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
                    Text("Save what you want and the price you'd like to pay. Set up a price watch to review exact product criteria and find matching offers.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if store.active.isEmpty && !store.loading {
                        ContentUnavailableView("Make room for something good", systemImage: "heart", description: Text("Add an item, set a target price, or accept a suggestion."))
                    }
                    ForEach(store.active) { item in row(item) }
                } header: { Text("Your wishlist · \(store.active.count)") }
                Section {
                    DisclosureGroup("History", isExpanded: $expandedHistory) {
                        if store.history.isEmpty { Text("Purchased, removed and rejected items appear here.").foregroundStyle(.secondary) }
                        ForEach(store.history) { item in row(item) }
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Useful additions, grounded in what you keep at home.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        HStack {
                            Button { Task { await store.findIdeas(settings: settings) } } label: {
                                Label(store.hasPendingIdeas ? "Retry saving ideas" : "Find ideas", systemImage: "sparkles")
                            }.buttonStyle(.borderedProminent)
                            Button { Task { await store.refreshSuggestions() } } label: {
                                Label("Check stock", systemImage: "arrow.clockwise")
                            }.buttonStyle(.bordered)
                        }.disabled(store.busy || !store.canUse)
                        if store.busy { ProgressView("Working on your suggestions…") }
                    }
                    DisclosureGroup("Replenishment · every 6 hours") {
                        if let state = store.refreshStatus {
                            if let last = state.lastRefreshedAt { LabeledContent("Last successful check", value: last.formatted(date: .abbreviated, time: .shortened)) }
                            else { Text("Your first replenishment check is pending.").foregroundStyle(.secondary) }
                            LabeledContent(state.nextRefreshAt < Date() ? "Check pending since" : "Next scheduled check", value: state.nextRefreshAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        Text("Check stock looks for essentials you may need to replenish. Your targets and decisions stay as you left them.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                    if store.refreshStatus?.lastError != nil {
                        Text("The last check failed. Previous suggestions are still available.").font(.caption).foregroundStyle(.orange)
                    }
                    DisclosureGroup("About Find ideas") {
                        Text(settings.featureDescription(.suggestions)).font(.caption).foregroundStyle(.secondary)
                        Text("Find ideas shares inventory names, quantities and suggestion feedback with your selected model. Choose a different model in Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline)
                }
                Section("For you · \(store.suggestions.count)") {
                    if store.suggestions.isEmpty && !store.loading {
                        ContentUnavailableView("All caught up", systemImage: "sparkles", description: Text("Useful ideas will appear here. It's okay if you don't need anything right now."))
                    }
                    ForEach(store.suggestions) { item in row(item) }
                }
                if !store.snoozed.isEmpty {
                    Section("For later") { ForEach(store.snoozed) { item in row(item) } }
                }
            }
        }
        .navigationTitle(selection == "wishlist" ? "Wishlist" : "Suggested for you")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    NavigationLink { WatchListView(store: store.watches) } label: { Label("Price watches", systemImage: "binoculars") }
                    NavigationLink { WatchInboxView(store: store.watches) } label: { Label("Offer inbox", systemImage: "tray") }
                } label: { Label("Watches and inbox", systemImage: "binoculars") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Label("Add item", systemImage: "plus") }
                    .disabled(!store.canUse)
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

    private func row(_ item: WishlistItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                Text(item.title).font(.headline)
                Spacer()
                if item.quantity > 1 { Text("×\(item.quantity)").foregroundStyle(.secondary) }
            }
            if let price = item.targetLabel { Label("Target \(price)", systemImage: "tag").font(.subheadline) }
            if let day = item.neededBy { Text("Needed by \(day)").font(.caption).foregroundStyle(.secondary) }
            if let notes = item.notes, !notes.isEmpty { Text(notes).font(.subheadline) }
            if let reason = item.rationale { Text(reason).font(.subheadline).foregroundStyle(.secondary) }
            if !item.priorityReasons.isEmpty {
                Text(item.priorityReasons.prefix(2).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            if item.evidence.contains(where: { $0.detail != nil }) {
                DisclosureGroup("Why this suggestion?") {
                    ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                        if let detail = evidence.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                }.font(.caption)
            }
            if let until = item.snoozedUntil { Text("Snoozed until \(until.formatted(date: .abbreviated, time: .omitted))").font(.caption) }
            if item.isPending {
                HStack {
                    Button("Add to wishlist") { Task { await store.act(item, action: "accept") } }.buttonStyle(.borderedProminent)
                    Menu {
                        Button("Tomorrow") { Task { await store.act(item, action: "snooze", body: ["days": 1]) } }
                        Button("In a week") { Task { await store.act(item, action: "snooze", body: ["days": 7]) } }
                        Button("In a month") { Task { await store.act(item, action: "snooze", body: ["days": 30]) } }
                    } label: { Image(systemName: "clock").accessibilityLabel("Snooze suggestion") }
                    Button { rejecting = item } label: { Image(systemName: "xmark").accessibilityLabel("Reject suggestion") }
                }.disabled(store.busy)
            } else if item.status == "active" {
                Button("Set up price watch") { watching = item }.buttonStyle(.bordered)
                HStack {
                    Button("Purchased") { Task { await store.act(item, action: "purchased") } }.buttonStyle(.bordered)
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await store.act(item, action: "remove") } }
                }.disabled(store.busy)
            } else { Text(item.status.capitalized).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if item.editable { Button("Edit") { editing = item } }
                Spacer()
                if item.source == "agent" {
                    Button { Task { await store.feedback(item, rating: "up") } } label: {
                        Image(systemName: item.myFeedback == "up" ? "hand.thumbsup.fill" : "hand.thumbsup").accessibilityLabel("Helpful suggestion")
                    }
                    Button { Task { await store.feedback(item, rating: "down") } } label: {
                        Image(systemName: item.myFeedback == "down" ? "hand.thumbsdown.fill" : "hand.thumbsdown").accessibilityLabel("Unhelpful suggestion")
                    }
                }
            }.disabled(store.busy)
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
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
                    TextField("Category (optional)", text: $draft.category)
                    Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                    TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    TextField("Target price in USD", text: $draft.targetPrice).keyboardType(.decimalPad)
                    Text("Your desired price per item, before shipping and tax. This is a target, not a live offer.").font(.caption).foregroundStyle(.secondary)
                    Toggle("Needed by a date", isOn: $draft.hasDeadline)
                    if draft.hasDeadline { DatePicker("Needed by", selection: $draft.deadline, displayedComponents: .date) }
                }
                Section("Priority") {
                    Toggle("Pin to the top", isOn: $draft.pinned)
                    Picker("Priority", selection: $draft.priority) {
                        Text("Automatic").tag(0)
                        ForEach(1...5, id: \.self) { Text("\($0)\($0 == 5 ? " · Highest" : "")").tag($0) }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
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
                    Text("This helps improve future suggestions. We won't suggest this item again for 30 days, except for a lower price after “Too expensive”.").font(.caption)
                    if let error = store.error { Text(error).foregroundStyle(.red) }
                }
            }
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
