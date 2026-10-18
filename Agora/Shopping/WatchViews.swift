import SwiftUI

struct WatchListView: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        List {
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            if let notice = store.notice { Section { Text(notice).foregroundStyle(.secondary) } }
            if store.discoveryUnavailable {
                Section { Label("Add a product link for direct checks", systemImage: "link")
                    Text(store.discoveryExplanation).font(.caption).foregroundStyle(.secondary) }
            }
            if store.watches.isEmpty && !store.loading && store.hasLoadedCapabilities {
                ContentUnavailableView("Watch for the right offer", systemImage: "binoculars", description: Text("Open an active wishlist item and choose Set up price watch. Review the exact product, price and location before confirming."))
            }
            ForEach(store.watches) { watch in
                NavigationLink { WatchDetailView(store: store, watchID: watch.id) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(watch.title).font(.headline); Spacer(); Text(watch.status.capitalized).font(.caption) }
                        Text("Target \(WishlistItem.money(watch.criteria.targetPriceCents)) each · \(watch.criteria.quantity) item(s)").font(.subheadline)
                        Text(watch.resultLabel).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }
        }.navigationTitle("Watch list")
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
                List {
                    if !watch.browserReviewURLs.isEmpty {
                        Section("Needs browser review") {
                            Text("These pages need you to review a sign-in, product variant or cart. Continue yourself in the shared browser. An offer still needs verification, and purchases require your decision.")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(watch.browserReviewURLs, id: \.self) { url in
                                Button("Review \(url.host ?? "retailer")") {
                                    store.reviewInBrowser(watchID: watch.id, url: url)
                                }.disabled(store.busy)
                            }
                        }
                    }
                    Section {
                        Text(watch.resultLabel).foregroundStyle(watch.lastResult == "failed" ? .orange : .secondary)
                        if !watch.rejectionLabels.isEmpty {
                            DisclosureGroup("Why offers were excluded") {
                                ForEach(Array(watch.rejectionLabels.enumerated()), id: \.offset) { _, reason in Text(reason).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        LabeledContent("Status", value: watch.status.capitalized)
                        if let last = watch.lastSuccessfulAt { LabeledContent("Last successful check", value: last.formatted(date: .abbreviated, time: .shortened)) }
                        else { Text("No successful check yet.").font(.caption).foregroundStyle(.secondary) }
                        if let last = watch.lastCheckedAt { LabeledContent("Last attempt", value: last.formatted(date: .abbreviated, time: .shortened)) }
                        if let next = watch.nextCheckAt, watch.status == "active" { LabeledContent("Next check", value: next.formatted(date: .abbreviated, time: .shortened)) }
                        if let error = store.error { Text(error).foregroundStyle(.red) }
                        if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
                        Button("Check now") { Task { await store.checkNow(watch) } }
                            .disabled(store.busy || !watch.searchAvailable || watch.status != "active")
                        if ["active", "paused"].contains(watch.status) {
                            Button(watch.status == "paused" ? "Resume watch" : "Pause watch") {
                                Task { await store.setPaused(watch, paused: watch.status == "active") }
                            }.disabled(store.busy)
                        }
                        Button("Edit criteria and alerts") { editing = true }.disabled(store.busy)
                    }
                    Section("Best verified offers · \(watch.currentOffers.count)") {
                        if watch.currentOffers.isEmpty { Text(watch.lastResult == "failed" ? "Offers could not be checked. Try again later." : "No verified offer is available for these criteria yet.").foregroundStyle(.secondary) }
                        ForEach(watch.currentOffers) { offer in WatchOfferRow(offer: offer) }
                    }
                    if !watch.historicalOffers.isEmpty {
                        Section("Previous offers · no longer current") {
                            ForEach(watch.historicalOffers) { offer in WatchOfferRow(offer: offer, historical: true) }
                        }
                    }
                    Section("Confirmed criteria") { WatchCriteriaSummary(criteria: watch.criteria) }
                    Section("Alerts") {
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
                        Text("Matched offers are saved in your inbox even when push permission is off.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !watch.runs.isEmpty {
                        Section("Recent checks") {
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
                }.navigationTitle(watch.title).navigationBarTitleDisplayMode(.inline)
                    .sheet(isPresented: $editing) { WatchEditor(store: store, itemID: watch.wishlistItemId, watch: watch) }
            } else {
                ContentUnavailableView("Watch unavailable", systemImage: "binoculars", description: Text(store.error ?? "Refresh to load this watch for your current household."))
            }
        }.task(id: "\(store.context)-\(watchID)") { await store.detail(watchID) }
            .refreshable { await store.detail(watchID) }
    }
}

private struct WatchOfferRow: View {
    let offer: WatchOffer
    var historical = false
    private var isCurrent: Bool { offer.isCurrent && !historical }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !isCurrent { Label("Historical offer · verify again at the retailer", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
            Text(offer.title).font(.headline)
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
            Text("Price and availability can change. Confirm the variant, full cost and conditions at the retailer.").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 5)
    }
}

private struct WatchCriteriaSummary: View {
    let criteria: WatchCriteria
    var body: some View {
        LabeledContent("Product", value: criteria.query)
        if let url = criteria.productUrl { Text(url).font(.caption).textSelection(.enabled) }
        LabeledContent("Quantity", value: "\(criteria.quantity)")
        LabeledContent("Target per item", value: WishlistItem.money(criteria.targetPriceCents))
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
            }.navigationTitle(review ? "Review price watch" : "Set up price watch")
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
            VStack(alignment: .leading) {
                Text("Must include").font(.caption).foregroundStyle(.secondary)
                TextField("Model, size, color…", text: $draft.requiredTerms, axis: .vertical)
            }
            VStack(alignment: .leading) {
                Text("Must exclude").font(.caption).foregroundStyle(.secondary)
                TextField("Mini, bundle, compatible…", text: $draft.excludedTerms, axis: .vertical)
            }
            Text("Be specific about brand, model, size, color and pack count to avoid a different variant. Separate required and excluded terms with commas.").font(.caption).foregroundStyle(.secondary)
            Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
        }
        Section("Price and availability") {
            VStack(alignment: .leading) {
                Text("Target per item · USD").font(.caption).foregroundStyle(.secondary)
                TextField("0.00", text: $draft.targetPrice).keyboardType(.decimalPad)
            }
            Text("Target applies to each item before tax and shipping.").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                Text("Maximum total · USD (optional)").font(.caption).foregroundStyle(.secondary)
                TextField("No total limit", text: $draft.maxTotal).keyboardType(.decimalPad)
            }
            Text("A total limit includes the requested quantity, shipping, tax and fees. Unknown full costs cannot satisfy this limit.").font(.caption).foregroundStyle(.secondary)
            Picker("Fulfillment", selection: $draft.fulfillment) { Text("Delivery").tag("delivery"); Text("Pickup").tag("pickup") }
            TextField("Delivery region or pickup store", text: $draft.location)
            Text("Use a merchant-supported region such as US for delivery; an exact store or postcode for pickup. Availability must be verified for this location.").font(.caption).foregroundStyle(.secondary)
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
        Section { Text("Saving a wishlist item does not start a watch. Confirm your criteria on the next screen. A watch only finds offers; it does not buy anything.").font(.caption).foregroundStyle(.secondary) }
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
        List {
            if let error = store.error { Section { Text(error).foregroundStyle(.red) } }
            if store.notifications.isEmpty {
                ContentUnavailableView("Your offer inbox", systemImage: "tray", description: Text("Verified matches appear here, including when push notifications are off."))
            }
            ForEach(store.notifications) { notification in
                NavigationLink {
                    if let watchID = notification.watchId { WatchDetailView(store: store, watchID: watchID) }
                    else { Text(notification.body).padding().navigationTitle(notification.title) }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { if notification.readAt == nil { Image(systemName: "circle.fill").font(.caption2).foregroundStyle(.blue).accessibilityLabel("Unread") }; Text(notification.title).font(.headline) }
                        Text(notification.body).font(.subheadline)
                        Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.simultaneousGesture(TapGesture().onEnded { Task { await store.markRead(notification) } })
            }
        }.navigationTitle("Offer inbox").task(id: store.context) { await store.refreshInbox() }
            .refreshable { await store.refreshInbox() }
    }
}

struct WatchShoppingNotice: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        if let notice = store.notice { Text(notice).font(.subheadline).foregroundStyle(.secondary) }
    }
}
