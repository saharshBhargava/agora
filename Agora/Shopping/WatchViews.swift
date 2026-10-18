import SwiftUI

struct WatchListView: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        ShelfPage {
            ShelfHero(title: "Watching prices",
                      subtitle: "A watch looks for verified offers on the exact product you chose. It never buys anything.")
            if let error = store.error { ShelfBanner(message: error, kind: .error) }
            if let notice = store.notice { ShelfBanner(message: notice) }
            if store.discoveryUnavailable {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Add a product link for direct checks", systemImage: "link")
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                    Text(store.discoveryExplanation).shelfNote().fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .dibsCard(radius: 14, padding: 12)
            }
            if store.watches.isEmpty && !store.loading && store.hasLoadedCapabilities {
                ShelfEmpty(symbol: "binoculars", title: "Watch for the right offer",
                           message: "Add an item to your wishlist to start searching for current prices automatically.")
            }
            ForEach(store.watches) { watch in
                NavigationLink { WatchDetailView(store: store, watchID: watch.id) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ShelfItemTile(kind: "wishlist", id: watch.wishlistItemId, name: watch.title, size: 48)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(watch.title).shelfName().lineLimit(2)
                            HStack(spacing: 6) {
                                WatchStatusPill(status: watch.status)
                                ShelfPill(text: "\(watch.criteria.quantity) item(s)", style: .muted)
                            }
                            Text(store.browserFallbackStatus[watch.id] ?? watch.resultLabel).shelfNote().fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(watch.criteria.targetPriceCents.map { WishlistItem.money($0) } ?? "–")
                                .font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
                            Text(watch.criteria.targetPriceCents == nil ? "no target" : "target each").shelfNote()
                        }
                    }
                    .dibsCard(radius: 14, padding: 12)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(watch.title), \(watch.status.capitalized). \(watch.criteria.targetPriceCents.map { "Target \(WishlistItem.money($0)) each" } ?? "No target price"), \(watch.criteria.quantity) item(s). \(store.browserFallbackStatus[watch.id] ?? watch.resultLabel)")
                .accessibilityAddTraits(.isButton)
            }
        }
        .navigationTitle("")
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
                ShelfPage {
                    ShelfHero(title: watch.title, size: 30)
                    HStack(spacing: Metrics.space1) {
                        WatchStatusPill(status: watch.status)
                        ShelfPill(text: "\(watch.criteria.quantity) item(s)", style: .muted)
                    }
                    figures(watch)
                    if let error = store.error { ShelfBanner(message: error, kind: .error) }
                    if let notice = store.notice { ShelfBanner(message: notice) }
                    if !watch.browserReviewURLs.isEmpty { browserReview(watch) }
                    checks(watch)
                    VStack(spacing: Metrics.space1) {
                        if ["active", "paused"].contains(watch.status) {
                            Button(watch.status == "paused" ? "Resume watch" : "Pause watch") {
                                Task { await store.setPaused(watch, paused: watch.status == "active") }
                            }
                            .buttonStyle(.dibs(.secondary, fontSize: 16))
                            .disabled(store.busy)
                        }
                        Button("Edit criteria and alerts") { editing = true }
                            .buttonStyle(.dibs(.secondary, fontSize: 16))
                            .disabled(store.busy)
                    }
                    offers(watch)
                    criteria(watch)
                    alerts(watch)
                    if !watch.runs.isEmpty { recentChecks(watch) }
                } bottom: {
                    Button("Check now") { Task { await store.checkNow(watch) } }
                        .buttonStyle(.dibs)
                        .disabled(store.busy || !watch.searchAvailable || watch.status != "active")
                }
                .navigationTitle("")
                .sheet(isPresented: $editing) { WatchEditor(store: store, itemID: watch.wishlistItemId, watch: watch) }
            } else {
                ShelfPage {
                    ShelfHero(title: "Price watch")
                    ShelfEmpty(symbol: "binoculars", title: "Watch unavailable",
                               message: store.error ?? "Refresh to load this watch for your current household.")
                }
                .navigationTitle("")
            }
        }.task(id: "\(store.context)-\(watchID)") { await store.detail(watchID) }
            .refreshable { await store.detail(watchID) }
    }

    // MARK: pieces

    /// The target and the best price so far (a verified offer, else the lowest current retailer price), in display numbers.
    private func figures(_ watch: PriceWatch) -> some View {
        let verified = watch.currentOffers.map(\.unitPriceCents).min()
        let best = verified ?? watch.currentPrices.map(\.unitPriceCents).min()
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(watch.criteria.targetPriceCents.map { WishlistItem.money($0) } ?? "Not set")
                    .font(.display(watch.criteria.targetPriceCents == nil ? 22 : 32))
                    .foregroundStyle(watch.criteria.targetPriceCents == nil ? Color.muted : Color.ink)
                    .monospacedDigit()
                    .frame(minHeight: 38, alignment: .leading)
                Text("Target per item").shelfNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(Color.line).frame(width: 1).padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(best.map(WishlistItem.money) ?? "None yet")
                    .font(.display(best == nil ? 22 : 32))
                    .foregroundStyle(best == nil ? Color.muted : Color.ink)
                    .monospacedDigit()
                    .frame(minHeight: 38, alignment: .leading)
                Text(verified == nil && best != nil ? "Lowest current price" : "Best verified offer").shelfNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Metrics.space2)
        }
        .accessibilityElement(children: .combine)
        .dibsCard()
    }

    private func browserReview(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Needs browser review").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink)
                .accessibilityAddTraits(.isHeader)
            Text("These pages need you to review a sign-in, product variant or cart. Continue yourself in the shared browser. An offer still needs verification, and purchases require your decision.")
                .shelfNote().fixedSize(horizontal: false, vertical: true)
            ForEach(watch.browserReviewURLs, id: \.self) { url in
                Button("Review \(url.host ?? "retailer")") {
                    store.reviewInBrowser(watchID: watch.id, url: url)
                }
                .buttonStyle(.dibs(.secondary, fontSize: 16))
                .disabled(store.busy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }

    private func checks(_ watch: PriceWatch) -> some View {
        var rows: [(title: String, value: String)] = [("Status", watch.status.capitalized)]
        if let last = watch.lastSuccessfulAt { rows.append(("Last successful check", last.formatted(date: .abbreviated, time: .shortened))) }
        else if let price = watch.currentPrices.first { rows.append(("Latest price found", price.observedAt.formatted(date: .abbreviated, time: .shortened))) }
        if let last = watch.lastCheckedAt { rows.append(("Last attempt", last.formatted(date: .abbreviated, time: .shortened))) }
        if let next = watch.nextCheckAt, watch.status == "active" { rows.append(("Next check", next.formatted(date: .abbreviated, time: .shortened))) }
        return VStack(alignment: .leading, spacing: 10) {
            if let disclosure = watch.simulationDisclosure { Text(disclosure).shelfNote().fixedSize(horizontal: false, vertical: true) }
            Text(store.browserFallbackStatus[watch.id] ?? watch.resultLabel)
                .font(.system(size: 15, weight: watch.lastResult == "failed" ? .bold : .regular))
                .foregroundStyle(watch.lastResult == "failed" ? Color.danger : Color.bodyInk)
                .fixedSize(horizontal: false, vertical: true)
            if !watch.rejectionLabels.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(watch.rejectionLabels.enumerated()), id: \.offset) { _, reason in
                            Text(reason).shelfNote().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Why offers were excluded").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                }
                .tint(Color.ink)
            }
            ShelfDivider()
            ShelfFacts(rows: rows)
            if watch.lastSuccessfulAt == nil && watch.currentPrices.isEmpty { Text("No successful check yet.").shelfNote() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }

    private func offers(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !watch.currentPrices.isEmpty {
                ShelfSectionTitle("Current retailer prices · \(watch.currentPrices.count)")
                VStack(spacing: 0) {
                    ForEach(Array(watch.currentPrices.enumerated()), id: \.element.id) { index, price in
                        if index > 0 { ShelfDivider() }
                        WatchPriceRow(price: price, watch: watch)
                    }
                }
                .dibsCard()
                .padding(.bottom, Metrics.space1)
            }
            ShelfSectionTitle("Offers meeting all requirements · \(watch.currentOffers.count)")
            if watch.currentOffers.isEmpty {
                ShelfEmpty(symbol: "tag", title: "No verified offer yet",
                           message: watch.lastResult == "failed" && watch.currentPrices.isEmpty ? "Offers could not be checked. Try again later." : "No verified offer meets all your requirements yet.")
            }
            ForEach(watch.currentOffers) { offer in WatchOfferRow(offer: offer, wishlistItemID: watch.wishlistItemId) }
            if !watch.historicalOffers.isEmpty {
                ShelfSectionTitle("Previous offers · no longer current").padding(.top, Metrics.space1)
                ForEach(watch.historicalOffers) { offer in WatchOfferRow(offer: offer, wishlistItemID: watch.wishlistItemId, historical: true) }
            }
        }
    }

    private func criteria(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Confirmed criteria")
            WatchCriteriaSummary(criteria: watch.criteria)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dibsCard()
        }
    }

    private func alerts(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Alerts")
            VStack(alignment: .leading, spacing: 8) {
                if let subscription = watch.subscription {
                    ShelfFacts(rows: alertRows(subscription))
                    Text(push.permissionStatus).shelfNote()
                    Text(subscription.timezone).shelfNote()
                } else {
                    Text("You have not subscribed to this household watch. Edit criteria and alerts to subscribe.").shelfBody()
                }
                Text("Matched offers are saved in your inbox even when push permission is off.").shelfNote()
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
        }
    }

    private func alertRows(_ subscription: WatchSubscription) -> [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = [
            ("Push alerts requested", subscription.pushEnabled ? "Yes" : "No"),
            ("Daily maximum", "\(subscription.dailyCap)"),
            ("Minimum interval", "\(subscription.cooldownHours) hours")]
        if let start = subscription.quietStartHour, let end = subscription.quietEndHour {
            rows.append(("Quiet hours", "\(start):00–\(end):00"))
        }
        return rows
    }

    private func recentChecks(_ watch: PriceWatch) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Recent checks")
            VStack(spacing: 0) {
                ForEach(Array(watch.runs.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { ShelfDivider() }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run.status.capitalized).font(.system(size: 15, weight: .bold)).foregroundStyle(Color.ink)
                            Spacer(minLength: 8)
                            Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).shelfNote()
                        }
                        if run.status == "succeeded" { Text("\(run.offerCount) offers checked · \(run.matchCount) met your criteria").shelfBody() }
                        if run.status == "failed" {
                            Text("Check failed. No conclusion about available offers.")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
            }
            .dibsCard(padding: 12)
        }
    }
}

/// One retailer's current price for a watched wish: photo tile, title and store, the price in display type, how it
/// compares to the target, and what still needs checking.
private struct WatchPriceRow: View {
    let price: WatchPrice
    let watch: PriceWatch
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ShelfItemTile(kind: "wishlist", id: watch.wishlistItemId, name: watch.title, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(price.title).shelfName().fixedSize(horizontal: false, vertical: true)
                    Text(price.merchant).shelfNote()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(WishlistItem.money(price.unitPriceCents))
                    .font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
            }
            ShelfPill(text: price.comparison(target: watch.criteria.targetPriceCents), style: .line)
            if let note = price.verificationNote {
                ShelfPill(text: note, symbol: "exclamationmark.circle", style: .danger)
            } else if !["confirmed_criteria_met", "above_target", "target_not_set"].contains(price.reason) {
                ShelfPill(text: "Price found; availability, delivery or other requirements still need verification.", symbol: "exclamationmark.circle", style: .danger)
            }
            Text("Before tax and shipping · \(price.observedAt.formatted(date: .omitted, time: .shortened))").shelfNote()
            if let url = price.safeURL {
                Link(destination: url) {
                    Label("View retailer", systemImage: "arrow.up.right")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 10)
    }
}

private struct WatchOfferRow: View {
    let offer: WatchOffer
    let wishlistItemID: UUID
    var historical = false
    private var isCurrent: Bool { offer.isCurrent && !historical }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !isCurrent {
                ShelfPill(text: "Historical offer · verify again at the retailer", symbol: "clock", style: .muted)
            }
            HStack(alignment: .top, spacing: 12) {
                ShelfItemTile(kind: "wishlist", id: wishlistItemID, name: offer.title, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(offer.title).shelfName().fixedSize(horizontal: false, vertical: true)
                    Text(offer.merchant).shelfNote()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 0) {
                    Text(WishlistItem.money(offer.unitPriceCents))
                        .font(.display(26)).foregroundStyle(Color.ink).monospacedDigit()
                    Text("each").shelfNote()
                }
            }
            if let total = offer.totalPriceCents {
                Text("Total \(WishlistItem.money(total)) for \(offer.quantity)")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            } else {
                ShelfPill(text: "Total unavailable · tax, shipping or fees may be additional", symbol: "exclamationmark.circle", style: .danger)
            }
            ShelfFlow {
                ShelfPill(text: offer.shippingCents.map { "Shipping \(WishlistItem.money($0))" } ?? "Shipping unknown")
                ShelfPill(text: offer.taxCents.map { "Tax \(WishlistItem.money($0))" } ?? "Tax unknown")
                ShelfPill(text: offer.condition.capitalized, style: .muted)
                ShelfPill(text: offer.fulfillment.capitalized, style: .muted)
                ShelfPill(text: offer.location, symbol: "mappin.and.ellipse", style: .muted)
            }
            Text(offer.reason).shelfBody().fixedSize(horizontal: false, vertical: true)
            Text("\(isCurrent ? "Verified" : "Previously observed") \(offer.observedAt.formatted(date: .abbreviated, time: .shortened))").shelfNote()
            if !offer.evidence.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(offer.evidence.enumerated()), id: \.offset) { _, value in
                            Text(value).shelfNote().fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Source evidence").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                }
                .tint(Color.ink)
            }
            if let url = offer.safeURL {
                Link(destination: url) {
                    Label("View at \(offer.merchant)", systemImage: "arrow.up.right")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap, alignment: .leading)
                }
            }
            Text("Price and availability can change. Confirm the variant, full cost and conditions at the retailer.")
                .shelfNote().fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }
}

private struct WatchCriteriaSummary: View {
    let criteria: WatchCriteria
    private var rows: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = [
            ("Product", criteria.query),
            ("Quantity", "\(criteria.quantity)"),
            ("Target per item", criteria.targetPriceCents.map { WishlistItem.money($0) } ?? "Not set")]
        if let total = criteria.maxTotalCents { rows.append(("Maximum total", WishlistItem.money(total))) }
        rows += [
            ("Must include", criteria.requiredTerms.isEmpty ? "No additional terms" : criteria.requiredTerms.joined(separator: ", ")),
            ("Must exclude", criteria.excludedTerms.isEmpty ? "None" : criteria.excludedTerms.joined(separator: ", ")),
            ("Fulfillment", criteria.fulfillment.capitalized),
            ("Location", criteria.location),
            ("Condition", criteria.condition.capitalized),
            ("Membership offers", criteria.allowMembership ? "Allowed" : "Excluded"),
            ("Retailers", criteria.allowedDomains.isEmpty ? "Any supported retailer" : criteria.allowedDomains.joined(separator: ", "))]
        if let deadline = criteria.neededBy { rows.append(("Needed by", deadline)) }
        return rows
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ShelfFacts(rows: rows)
            if let url = criteria.productUrl { Text(url).shelfNote().textSelection(.enabled) }
            Text("Before tax and shipping · USD").shelfNote()
        }
    }
}

/// A watch's state as a small ink or outlined pill.
private struct WatchStatusPill: View {
    let status: String
    var body: some View {
        ShelfPill(text: status.capitalized, style: status == "active" ? .ink : .line)
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
            ShelfPage {
                if review { reviewSections } else { editSections }
                if let error { ShelfBanner(message: error, kind: .error) }
            } bottom: {
                Button(review ? "Confirm watch" : "Review") {
                    if review { save() }
                    else {
                        do { _ = try draft.body(confirmed: true); error = nil; review = true }
                        catch { self.error = InventoryStore.message(error) }
                    }
                }
                .buttonStyle(.dibs)
                .disabled(saving || store.busy)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(review ? "Back" : "Cancel") { if review { review = false; requestKey = UUID().uuidString } else { dismiss() } }.disabled(saving)
                }
            }
            .disabled(saving).interactiveDismissDisabled(saving)
            .onChange(of: store.context) { _, _ in dismiss() }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
    }

    @ViewBuilder private var editSections: some View {
        ShelfHero(title: "Watch settings", size: 30,
                  subtitle: "Wishlist items are watched automatically. These settings refine your search and alerts. A watch finds prices; it does not buy anything.")
        VStack(alignment: .leading, spacing: 12) {
            ShelfSectionTitle("Exact product")
            ShelfField(label: "Product") {
                TextField("Brand, model, size and variant", text: $draft.query, axis: .vertical)
            }
            ShelfField(label: "Product link (optional)") {
                TextField("https://", text: $draft.productURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if store.discoveryUnavailable { Text(store.discoveryExplanation).shelfNote().fixedSize(horizontal: false, vertical: true) }
            ShelfField(label: "Must include") {
                TextField("Model, size, color…", text: $draft.requiredTerms, axis: .vertical)
            }
            ShelfField(label: "Must exclude",
                       note: "Be specific about brand, model, size, color and pack count to avoid a different variant. Separate required and excluded terms with commas.") {
                TextField("Mini, bundle, compatible…", text: $draft.excludedTerms, axis: .vertical)
            }
            card {
                Stepper("Quantity: \(draft.quantity)", value: $draft.quantity, in: 1...99)
                    .font(.system(size: 16)).foregroundStyle(Color.ink)
            }
        }
        VStack(alignment: .leading, spacing: 12) {
            ShelfSectionTitle("Price and availability")
            ShelfField(label: "Target per item · USD (optional)", note: "Target applies to each item before tax and shipping.") {
                TextField("0.00", text: $draft.targetPrice).keyboardType(.decimalPad).font(.display(28))
            }
            ShelfField(label: "Maximum total · USD (optional)",
                       note: "A total limit includes the requested quantity, shipping, tax and fees. Unknown full costs cannot satisfy this limit.") {
                TextField("No total limit", text: $draft.maxTotal).keyboardType(.decimalPad)
            }
            ShelfChoice(label: "Fulfillment", options: [("Delivery", "delivery"), ("Pickup", "pickup")], selection: $draft.fulfillment)
            ShelfField(label: "Delivery region or pickup store",
                       note: "Use a merchant-supported region such as US for delivery; an exact store or postcode for pickup. Availability must be verified for this location.") {
                TextField("Seattle, WA 98107", text: $draft.location)
            }
            ShelfField(label: "Retailers (optional)") {
                TextField("retailer.com", text: $draft.allowedDomains).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            ShelfChoice(label: "Condition", options: [("New", "new"), ("Used", "used"), ("Refurbished", "refurbished")], selection: $draft.condition)
            card {
                Toggle("Allow membership-only offers", isOn: $draft.allowMembership)
                ShelfDivider()
                Toggle("Needed by a date", isOn: $draft.hasDeadline)
                if draft.hasDeadline {
                    DatePicker("Needed by", selection: $draft.deadline, in: Date()..., displayedComponents: .date)
                }
            }
            .font(.system(size: 16)).foregroundStyle(Color.ink).tint(Color.ink)
        }
        VStack(alignment: .leading, spacing: 12) {
            ShelfSectionTitle("Alerts")
            card {
                Toggle("Enable push alerts", isOn: $draft.pushEnabled)
                Text("Push permission is requested when you confirm with alerts enabled. Your inbox works if permission is denied.")
                    .shelfNote().fixedSize(horizontal: false, vertical: true)
                ShelfDivider()
                Stepper("At most \(draft.dailyCap) alerts per day for this watch", value: $draft.dailyCap, in: 1...20)
                ShelfDivider()
                Stepper("Wait \(draft.cooldownHours) hours between alerts", value: $draft.cooldownHours, in: 1...168)
                ShelfDivider()
                Toggle("Quiet hours", isOn: $draft.quietHours)
            }
            .font(.system(size: 16)).foregroundStyle(Color.ink).tint(Color.ink)
            if draft.quietHours {
                HStack(alignment: .top, spacing: Metrics.space1) {
                    ShelfMenu(label: "Start", selection: $draft.quietStart) {
                        ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) }
                    }
                    ShelfMenu(label: "End", selection: $draft.quietEnd) {
                        ForEach(0...23, id: \.self) { Text("\($0):00").tag($0) }
                    }
                }
            }
            ShelfField(label: "Time zone") {
                TextField("America/Los_Angeles", text: $draft.timezone).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
        }
    }

    @ViewBuilder private var reviewSections: some View {
        ShelfHero(title: "Review watch settings", size: 30,
                  subtitle: "Confirm only if these details identify the exact product you want. Offers with another variant or missing verification will be excluded.")
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Check the product and limits")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    ShelfTile(seed: draft.query, label: draft.query, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.query).shelfName().fixedSize(horizontal: false, vertical: true)
                        if !draft.productURL.isEmpty { Text(draft.productURL).shelfNote() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("$\(draft.targetPrice)").font(.display(22)).foregroundStyle(Color.ink).monospacedDigit()
                        Text("each, USD").shelfNote()
                    }
                }
                ShelfDivider()
                ShelfFacts(rows: reviewRows)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
        }
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Alert preferences")
            VStack(alignment: .leading, spacing: 8) {
                ShelfFacts(rows: [("Push alerts", draft.pushEnabled ? "Enabled" : "Off")])
                Text("Maximum \(draft.dailyCap) per day for this watch; at least \(draft.cooldownHours) hours apart.").shelfBody()
                if draft.quietHours { Text("Quiet \(draft.quietStart):00–\(draft.quietEnd):00 · \(draft.timezone)").shelfBody() }
                else { Text("No quiet hours · \(draft.timezone)").shelfBody() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dibsCard()
        }
        if store.discoveryUnavailable && draft.productURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ShelfPill(text: store.discoveryExplanation, symbol: "exclamationmark.triangle", style: .muted)
        }
    }

    private var reviewRows: [(title: String, value: String)] {
        var rows: [(title: String, value: String)] = [
            ("Must include", draft.requiredTerms.isEmpty ? "No additional terms" : draft.requiredTerms),
            ("Must exclude", draft.excludedTerms.isEmpty ? "None" : draft.excludedTerms),
            ("Quantity", "\(draft.quantity)"),
            ("Per item before tax/shipping", "$\(draft.targetPrice) USD"),
            ("Maximum total", draft.maxTotal.isEmpty ? "No limit" : "$\(draft.maxTotal) USD"),
            ("Fulfillment", draft.fulfillment.capitalized),
            ("Location", draft.location),
            ("Condition", draft.condition.capitalized),
            ("Retailers", draft.allowedDomains.isEmpty ? "Any supported retailer" : draft.allowedDomains),
            ("Membership offers", draft.allowMembership ? "Allowed" : "Excluded")]
        if draft.hasDeadline { rows.append(("Needed by", WishlistDraft.dateFormatter.string(from: draft.deadline))) }
        return rows
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
        ShelfPage {
            ShelfHero(title: "Offer inbox",
                      subtitle: store.notifications.isEmpty ? nil : "Verified matches from your price watches.")
            if let error = store.error { ShelfBanner(message: error, kind: .error) }
            if store.notifications.isEmpty {
                ShelfEmpty(symbol: "tray", title: "Your offer inbox",
                           message: "Verified matches appear here, including when push notifications are off.")
            }
            ForEach(store.notifications) { notification in
                NavigationLink {
                    if let watchID = notification.watchId { WatchDetailView(store: store, watchID: watchID) }
                    else {
                        ShelfPage {
                            ShelfHero(title: notification.title, size: 30)
                            Text(notification.body).shelfBody()
                        }
                        .navigationTitle("")
                    }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        ShelfTile(seed: notification.id.uuidString, label: notification.title, size: 44)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                if notification.readAt == nil {
                                    Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(Color.ink).accessibilityLabel("Unread")
                                }
                                Text(notification.title).shelfName().lineLimit(2)
                            }
                            Text(notification.body).shelfBody().fixedSize(horizontal: false, vertical: true)
                            Text(notification.createdAt.formatted(date: .abbreviated, time: .shortened)).shelfNote()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.muted)
                            .padding(.top, 4).accessibilityHidden(true)
                    }
                    .dibsCard(radius: 14, padding: 12)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded { Task { await store.markRead(notification) } })
            }
        }
        .navigationTitle("")
        .task(id: store.context) { await store.refreshInbox() }
        .refreshable { await store.refreshInbox() }
    }
}

struct WatchShoppingNotice: View {
    @ObservedObject var store: WatchStore
    var body: some View {
        if let notice = store.notice { Text(notice).font(.system(size: 15)).foregroundStyle(Color.muted) }
    }
}
