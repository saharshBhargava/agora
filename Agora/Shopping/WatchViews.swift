import SwiftUI

struct WatchListView: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        AgoraList {
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            if let notice = store.notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if store.discoveryUnavailable {
                Section { Label("Add a product link for direct checks", systemImage: "link")
                    Text(store.discoveryExplanation).font(.caption).foregroundStyle(.secondary) }
            }
            if store.watches.isEmpty && !store.loading && store.hasLoadedCapabilities {
                AgoraEmptyState(title: "No price watches yet", detail: "Add an item to your wishlist.")
            }
            ForEach(store.watches) { watch in
                NavigationLink { WatchDetailView(store: store, watchID: watch.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { ItemThumbnail(kind: "wishlist", id: watch.wishlistItemId, name: watch.title); Text(watch.title).font(.headline); Spacer(); Text(watch.status.capitalized).font(.caption) }
                        Text("\(watch.criteria.targetPriceCents.map { "Target \(WishlistItem.money($0)) each" } ?? "No target price") · \(watch.criteria.quantity) item(s)").font(.subheadline)
                        Text(store.browserFallbackStatus[watch.id] ?? watch.resultLabel).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }.agoraSurface()
        .navigationTitle("Watch list")
            .overlay { if store.loading && store.watches.isEmpty { ProgressView() } }
            .task(id: store.context) { await store.refresh() }.refreshable { await store.refresh() }
            .navigationDestination(item: $store.openWatchID) { id in WatchDetailView(store: store, watchID: id) }
    }
}

struct WatchDetailView: View {
    @ObservedObject var store: WatchStore
    let watchID: UUID
    @State private var editing = false
    @ObservedObject private var push = PushNotifications.shared
    var body: some View {
        Group {
            if let watch = store.watches.first(where: { $0.id == watchID }) {
                AgoraList {
                    Section {
                        VStack(spacing: 12) {
                            ItemThumbnail(kind: "wishlist", id: watch.wishlistItemId, name: watch.title, size: 180)
                            Text(watch.title).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                            if let target = watch.criteria.targetPriceCents {
                                Text("Target \(WishlistItem.money(target))").foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 16)
                        if let disclosure = watch.simulationDisclosure { Text(disclosure).font(.caption).foregroundStyle(.secondary) }
                        Text(store.browserFallbackStatus[watch.id] ?? watch.resultLabel)
                            .font(.subheadline).foregroundStyle(watch.lastResult == "failed" ? .orange : .secondary)
                        if let error = store.error { Text(error).foregroundStyle(.red) }
                        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                    }
                    if !watch.browserReviewURLs.isEmpty {
                        Section("Needs browser review") {
                            Text("Review the sign-in, variant or cart in your browser. Offers are unverified; purchases require your decision.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(watch.browserReviewURLs, id: \.self) { url in
                                Button("Review \(url.host ?? "retailer")") {
                                    store.reviewInBrowser(watchID: watch.id, url: url)
                                }.disabled(store.busy)
                            }
                        }
                    }
                    if !watch.currentPrices.isEmpty {
                        Section("Current retailer prices") {
                            ForEach(watch.currentPrices) { price in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(price.merchant).font(.headline)
                                    Text(WishlistItem.money(price.unitPriceCents)).font(.title3.weight(.semibold))
                                    if price.title != watch.title { Text(price.title).font(.caption).foregroundStyle(.secondary) }
                                    Text(price.comparison(target: watch.criteria.targetPriceCents)).font(.subheadline)
                                    if let note = price.verificationNote { Text(note).font(.caption).foregroundStyle(.orange) }
                                    else if !["confirmed_criteria_met", "above_target", "target_not_set"].contains(price.reason) {
                                        Text("Price found; availability, delivery or other requirements still need verification.").font(.caption).foregroundStyle(.orange)
                                    }
                                    Text("Before tax and shipping · \(price.observedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                                    if let url = price.safeURL { Link("View retailer", destination: url) }
                                }
                            }
                        }
                    }
                    Section("Verified offers · \(watch.currentOffers.count)") {
                        if watch.currentOffers.isEmpty { Text(watch.lastResult == "failed" && watch.currentPrices.isEmpty ? "Offers could not be checked. Try again later." : "No matching offers yet.").foregroundStyle(.secondary) }
                        ForEach(watch.currentOffers) { offer in WatchOfferRow(offer: offer, wishlistItemID: watch.wishlistItemId) }
                    }
                    if !watch.historicalOffers.isEmpty {
                        Section {
                            DisclosureGroup("Previous offers") {
                                ForEach(watch.historicalOffers) { offer in WatchOfferRow(offer: offer, wishlistItemID: watch.wishlistItemId, historical: true) }
                            }
                        }
                    }
                    Section {
                        DisclosureGroup("Watch activity") {
                            if !watch.rejectionLabels.isEmpty {
                                DisclosureGroup("Why offers were excluded") {
                                    ForEach(Array(watch.rejectionLabels.enumerated()), id: \.offset) { _, reason in Text(reason).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            LabeledContent("Status", value: watch.status.capitalized)
                            if let last = watch.lastSuccessfulAt { LabeledContent("Last successful check", value: last.formatted(date: .abbreviated, time: .shortened)) }
                            else if let price = watch.currentPrices.first {
                                LabeledContent("Latest price found", value: price.observedAt.formatted(date: .abbreviated, time: .shortened))
                            } else { Text("No successful check yet.").font(.caption).foregroundStyle(.secondary) }
                            if let last = watch.lastCheckedAt { LabeledContent("Last attempt", value: last.formatted(date: .abbreviated, time: .shortened)) }
                            if let next = watch.nextCheckAt, watch.status == "active" { LabeledContent("Next check", value: next.formatted(date: .abbreviated, time: .shortened)) }
                        }
                        Button("Check now") { Task { await store.checkNow(watch) } }
                            .disabled(store.busy || !watch.searchAvailable || watch.status != "active")
                        if ["active", "paused"].contains(watch.status) {
                            Button(watch.status == "paused" ? "Resume watch" : "Pause watch") {
                                Task { await store.setPaused(watch, paused: watch.status == "active") }
                            }.disabled(store.busy)
                        }
                    }
                    Section { DisclosureGroup("Criteria") { WatchCriteriaSummary(criteria: watch.criteria) } }
                    Section {
                        DisclosureGroup("Alerts") {
                            if let subscription = watch.subscription {
                                LabeledContent("Push alerts requested", value: subscription.pushEnabled ? "Yes" : "No")
                                Text(push.permissionStatus).font(.caption).foregroundStyle(.secondary)
                                LabeledContent("Daily maximum", value: "\(subscription.dailyCap)")
                                LabeledContent("Minimum interval", value: "\(subscription.cooldownHours) hours")
                                if let start = subscription.quietStartHour, let end = subscription.quietEndHour {
                                    LabeledContent("Quiet hours", value: "\(start):00–\(end):00")
                                }
                                Text(subscription.timezone).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("You have not subscribed to this household watch. Edit criteria and alerts to subscribe.").font(.caption)
                            }
                            Text("Offers stay in your inbox when push alerts are off.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if !watch.runs.isEmpty {
                        Section {
                            DisclosureGroup("Recent checks") {
                                ForEach(watch.runs) { run in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(run.status.capitalized)
                                        Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                        if run.status == "succeeded" { Text("\(run.offerCount) offers checked · \(run.matchCount) met your criteria").font(.caption) }
                                        if run.status == "failed" { Text("Check failed. No conclusion about available offers.").font(.caption).foregroundStyle(.orange) }
                                    }
                                }
                            }
                        }
                    }
                }.agoraSurface()
                .navigationTitle(watch.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Edit") { editing = true }.disabled(store.busy) }
                    .sheet(isPresented: $editing) { WatchEditor(store: store, itemID: watch.wishlistItemId, watch: watch) }
            } else {
                AgoraEmptyState(title: "Watch unavailable", detail: store.error ?? "Pull to refresh.").padding(20)
            }
        }.task(id: "\(store.context)-\(watchID)") { await store.detail(watchID) }
            .refreshable { await store.detail(watchID) }
    }
}

private struct WatchOfferRow: View {
    let offer: WatchOffer
    let wishlistItemID: UUID
    var historical = false
    private var isCurrent: Bool { offer.isCurrent && !historical }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCurrent { Label("Historical offer · verify again at the retailer", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            HStack {
                ItemThumbnail(kind: "wishlist", id: wishlistItemID, name: offer.title)
                Text(offer.title).font(.headline)
            }
            Text("\(offer.merchant) · \(WishlistItem.money(offer.unitPriceCents)) each")
            if let total = offer.totalPriceCents { Text("Total \(WishlistItem.money(total)) for \(offer.quantity)") }
            else { Text("Total unavailable · tax, shipping or fees may be additional").font(.caption).foregroundStyle(.orange) }
            HStack {
                Text(offer.shippingCents.map { "Shipping \(WishlistItem.money($0))" } ?? "Shipping unknown")
                Text(offer.taxCents.map { "Tax \(WishlistItem.money($0))" } ?? "Tax unknown")
            }.font(.caption).foregroundStyle(.secondary)
            Text("\(offer.condition.capitalized) · \(offer.fulfillment.capitalized) · \(offer.location)").font(.caption)
            Text("\(isCurrent ? "Verified" : "Previously observed") \(offer.observedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            Text(offer.reason).font(.caption)
            if !offer.evidence.isEmpty { DisclosureGroup("Source evidence") { ForEach(Array(offer.evidence.enumerated()), id: \.offset) { _, value in Text(value).font(.caption) } } }
            if let url = offer.safeURL { Link("View at \(offer.merchant)", destination: url) }
            Text("Confirm the variant and final total at the retailer.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct WatchCriteriaSummary: View {
    let criteria: WatchCriteria
    var body: some View {
        LabeledContent("Product", value: criteria.query)
        if let url = criteria.productUrl { Text(url).font(.caption).textSelection(.enabled) }
        LabeledContent("Quantity", value: "\(criteria.quantity)")
        LabeledContent("Target per item", value: criteria.targetPriceCents.map { WishlistItem.money($0) } ?? "Not set")
        Text("Before tax and shipping · USD").font(.caption).foregroundStyle(.secondary)
        if let total = criteria.maxTotalCents { LabeledContent("Maximum total", value: WishlistItem.money(total)) }
        LabeledContent("Must include", value: criteria.requiredTerms.isEmpty ? "No additional terms" : criteria.requiredTerms.joined(separator: ", "))
        LabeledContent("Must exclude", value: criteria.excludedTerms.isEmpty ? "None" : criteria.excludedTerms.joined(separator: ", "))
        LabeledContent("Fulfillment", value: criteria.fulfillment.capitalized)
        LabeledContent("Location", value: criteria.location)
        LabeledContent("Condition", value: criteria.condition.capitalized)
        LabeledContent("Membership offers", value: criteria.allowMembership ? "Allowed" : "Excluded")
        LabeledContent("Retailers", value: criteria.allowedDomains.isEmpty ? "Any supported retailer" : criteria.allowedDomains.joined(separator: ", "))
        if let deadline = criteria.neededBy { LabeledContent("Needed by", value: deadline) }
    }
}

struct WatchEditor: View {
    @ObservedObject var store: WatchStore
    let itemID: UUID
    @State private var draft: WatchDraft
    @State private var review = false
    @State private var error: String?
    @State private var saving = false
    @State private var requestKey = UUID().uuidString
    @Environment(\.dismiss) private var dismiss
    init(store: WatchStore, itemID: UUID, item: WishlistItem? = nil, watch: PriceWatch? = nil) {
        self.store = store; self.itemID = itemID; _draft = State(initialValue: WatchDraft(item: item, watch: watch))
    }
    var body: some View {
        NavigationStack {
            Form {
                if review { reviewSections } else { editSections }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.agoraSurface()
            .navigationTitle(review ? "Review watch settings" : "Watch settings")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(review ? "Back" : "Cancel") { if review { review = false; requestKey = UUID().uuidString } else { dismiss() } }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(review ? "Confirm watch" : "Review") {
                            if review { save() }
                            else {
                                do { _ = try draft.body(confirmed: true); error = nil; review = true }
                                catch { self.error = InventoryStore.message(error) }
                            }
                        }.disabled(saving || store.busy)
                    }
                }.disabled(saving).interactiveDismissDisabled(saving)
                .onChange(of: store.context) { _, _ in dismiss() }
        }
    }
    @ViewBuilder private var editSections: some View {
        Section("Exact product") {
            TextField("Brand, model, size and variant", text: $draft.query, axis: .vertical)
            TextField("Product link (optional)", text: $draft.productURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if store.discoveryUnavailable { Text(store.discoveryExplanation).font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("Product matching") {
                VStack(alignment: .leading) {
                    Text("Must include").font(.caption).foregroundStyle(.secondary)
                    TextField("Model, size, color…", text: $draft.requiredTerms, axis: .vertical)
                }
                VStack(alignment: .leading) {
                    Text("Must exclude").font(.caption).foregroundStyle(.secondary)
                    TextField("Mini, bundle, compatible…", text: $draft.excludedTerms, axis: .vertical)
                }
                Text("Separate terms with commas.").font(.caption).foregroundStyle(.secondary)
            }
            Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
        }
        Section("Price and availability") {
            VStack(alignment: .leading) {
                Text("Target per item · USD (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("0.00", text: $draft.targetPrice).keyboardType(.decimalPad)
            }
            Text("Target applies to each item before tax and shipping.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Maximum total · USD (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("No total limit", text: $draft.maxTotal).keyboardType(.decimalPad)
            }
            Text("Includes shipping, tax and fees. Unknown totals do not qualify.").font(.caption).foregroundStyle(.secondary)
            Picker("Fulfillment", selection: $draft.fulfillment) { Text("Delivery").tag("delivery"); Text("Pickup").tag("pickup") }
            TextField("Delivery region or pickup store", text: $draft.location)
            Text("Delivery region, or store/postcode for pickup.").font(.caption).foregroundStyle(.secondary)
            TextField("Retailers: retailer.com (optional)", text: $draft.allowedDomains).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Condition", selection: $draft.condition) { Text("New").tag("new"); Text("Used").tag("used"); Text("Refurbished").tag("refurbished") }
            Toggle("Allow membership-only offers", isOn: $draft.allowMembership)
            Toggle("Needed by a date", isOn: $draft.hasDeadline)
            if draft.hasDeadline { DatePicker("Needed by", selection: $draft.deadline, in: Date()..., displayedComponents: .date) }
        }
        Section("Alerts") {
            Toggle("Enable push alerts", isOn: $draft.pushEnabled)
            Text("Push permission is requested when you confirm with alerts enabled. Your inbox works if permission is denied.").font(.caption).foregroundStyle(.secondary)
            Stepper("At most \(draft.dailyCap) alerts per day for this watch", value: $draft.dailyCap, in: 1...20)
            Stepper("Wait \(draft.cooldownHours) hours between alerts", value: $draft.cooldownHours, in: 1...168)
            Toggle("Quiet hours", isOn: $draft.quietHours)
            if draft.quietHours {
                Picker("Start", selection: $draft.quietStart) { ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) } }
                Picker("End", selection: $draft.quietEnd) { ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) } }
            }
            TextField("Time zone", text: $draft.timezone).textInputAutocapitalization(.never).autocorrectionDisabled()
        }
        Section { Text("Wishlist items are watched automatically. These settings refine your search and alerts. A watch finds prices; it does not buy anything.").font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private var reviewSections: some View {
        Section("Check the product and limits") {
            Text(draft.query).font(.headline)
            if !draft.productURL.isEmpty { Text(draft.productURL).font(.caption) }
            LabeledContent("Must include", value: draft.requiredTerms.isEmpty ? "No additional terms" : draft.requiredTerms)
            LabeledContent("Must exclude", value: draft.excludedTerms.isEmpty ? "None" : draft.excludedTerms)
            LabeledContent("Quantity", value: "\(draft.quantity)")
            LabeledContent("Per item before tax/shipping", value: "$\(draft.targetPrice) USD")
            LabeledContent("Maximum total", value: draft.maxTotal.isEmpty ? "No limit" : "$\(draft.maxTotal) USD")
            LabeledContent("Fulfillment", value: draft.fulfillment.capitalized)
            LabeledContent("Location", value: draft.location)
            LabeledContent("Condition", value: draft.condition.capitalized)
            LabeledContent("Retailers", value: draft.allowedDomains.isEmpty ? "Any supported retailer" : draft.allowedDomains)
            LabeledContent("Membership offers", value: draft.allowMembership ? "Allowed" : "Excluded")
            if draft.hasDeadline { LabeledContent("Needed by", value: WishlistDraft.dateFormatter.string(from: draft.deadline)) }
        }
        Section("Alert preferences") {
            LabeledContent("Push alerts", value: draft.pushEnabled ? "Enabled" : "Off")
            Text("Maximum \(draft.dailyCap) per day for this watch; at least \(draft.cooldownHours) hours apart.")
            if draft.quietHours { Text("Quiet \(draft.quietStart):00–\(draft.quietEnd):00 · \(draft.timezone)") }
            else { Text("No quiet hours · \(draft.timezone)") }
        }
        Section {
            Text("Confirm only if these details identify the exact product you want. Offers with another variant or missing verification will be excluded.")
            if store.discoveryUnavailable && draft.productURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Label(store.discoveryExplanation, systemImage: "exclamationmark.triangle").font(.caption) }
        }
    }
    private func save() {
        saving = true; error = nil
        Task {
            do {
                try await store.save(draft, itemID: itemID, confirmed: true, key: requestKey)
                if draft.pushEnabled { await store.enablePushAlerts() }
                dismiss()
            } catch { self.error = InventoryStore.message(error) }
            saving = false
        }
    }
}

struct WatchInboxView: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        AgoraList {
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            if store.notifications.isEmpty {
                AgoraEmptyState(title: "No offers yet", detail: "Verified matches will appear here.")
            }
            ForEach(store.notifications) { notification in
                NavigationLink {
                    if let watchID = notification.watchId { WatchDetailView(store: store, watchID: watchID) }
                    else { Text(notification.body).padding().agoraSurface()
                    .navigationTitle(notification.title) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { if notification.readAt == nil { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(Color.agoraAccent).accessibilityLabel("Unread") }; Text(notification.title).font(.headline) }
                        Text(notification.body).font(.subheadline)
                        Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.simultaneousGesture(TapGesture().onEnded { Task { await store.markRead(notification) } })
            }
        }.agoraSurface()
        .navigationTitle("Offer inbox").task(id: store.context) { await store.refreshInbox() }
            .refreshable { await store.refreshInbox() }
    }
}

struct WatchShoppingNotice: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
    }
}
