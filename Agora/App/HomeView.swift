import SwiftUI

enum AppTab: Hashable {
    case home, chat, capture, lists, settings
}

struct HomeView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var store: InventoryStore
    @ObservedObject var shopping: ShoppingStore
    @ObservedObject var settings: SettingsStore
    @ObservedObject var trips: TripStore
    private var inventory: [InventoryItem] { store.activeItems }
    private var loading: Bool { store.loading }
    private var inventoryError: String? { store.error }

    private var lowItems: [InventoryItem] {
        inventory.filter(\.isRunningLow).sorted {
            if $0.quantity == $1.quantity {
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            return ($0.quantity ?? 0) < ($1.quantity ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    scanCard
                        .padding(.horizontal, 20)
                    wishlistSection
                    lowStockSection
                    suggestionsSection
                    tripsSection
                }
                .padding(.vertical, 20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await store.refresh(); await shopping.refresh(); await trips.refresh() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Image("AgoraWordmark")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 50)
                .accessibilityLabel("Agora")
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 16)

            NavigationLink { tripsDestination } label: {
                Image(systemName: "calendar")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Calendar")
            .accessibilityHint("View and plan shopping trips")
            .accessibilityIdentifier("homeCalendar")

            NavigationLink {
                WatchInboxView(store: shopping.watches)
                    .toolbar(.visible, for: .navigationBar)
            } label: {
                Image(systemName: "bell")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Notifications")
            .accessibilityIdentifier("homeNotifications")
        }
        .font(.system(size: 21, weight: .regular))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea(edges: .top))
    }

    private var tripsDestination: some View {
        TripsView(store: trips)
            .toolbar(.visible, for: .navigationBar)
    }

    private var scanCard: some View {
        Button {
            selectedTab = .capture
        } label: {
            HStack(spacing: 16) {
                Text("Scan your items")
                    .font(.headline)
                Spacer(minLength: 0)
                Image(systemName: "camera.viewfinder")
                    .font(.title2.weight(.medium))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(red: 0.0, green: 0.36, blue: 0.49),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("homeScanItems")
    }

    private var wishlistSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Wishlist", linkLabel: "View wishlist") {
                ShoppingView(store: shopping, settings: settings)
                    .toolbar(.visible, for: .navigationBar)
            }
            if shopping.loading && shopping.active.isEmpty {
                ProgressView("Loading wishlist…").padding(.horizontal, 20)
            } else if shopping.active.isEmpty {
                sectionMessage("Save something you want and set a target price.")
            } else {
                HomeCarousel {
                    ForEach(shopping.active) { item in
                        HomeCarouselItem(title: item.title, detail: item.targetLabel.map { "Target \($0)" }) { size in
                            ItemThumbnail(kind: "wishlist", id: item.id, name: item.title,
                                          category: item.category, size: size)
                        }
                    }
                }
            }
            if let error = shopping.error { sectionMessage(error) }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Suggested for you", linkLabel: "View suggestions") {
                ShoppingView(store: shopping, settings: settings, selection: "suggestions")
                    .toolbar(.visible, for: .navigationBar)
            }
            if shopping.loading && shopping.suggestions.isEmpty {
                ProgressView("Loading suggestions…").padding(.horizontal, 20)
            } else if shopping.suggestions.isEmpty {
                sectionMessage("Review replenishment suggestions or find ideas based on your inventory.")
            } else {
                HomeCarousel {
                    ForEach(shopping.suggestions) { item in
                        HomeCarouselItem(title: item.title, detail: item.rationale) { size in
                            ItemThumbnail(kind: "wishlist", id: item.id, name: item.title,
                                          category: item.category, size: size)
                        }
                    }
                }
            }
        }
    }

    private var upcomingTrips: [TripRecord] {
        trips.trips.filter { $0.status == "scheduled" && ($0.endDate ?? .distantPast) > Date() }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    private var tripsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Upcoming trips", linkLabel: "Shopping lists & trips", identifier: "homeShoppingTrips") {
                tripsDestination
            }
            if !upcomingTrips.isEmpty {
                HomeCarousel {
                    ForEach(upcomingTrips) { trip in
                        NavigationLink { tripsDestination } label: {
                            HomeCarouselItem(title: trip.title,
                                             detail: trip.startDate?.formatted(.dateTime.weekday().hour().minute())) { size in
                                // Trips have no product image; use a date medallion in the same circular layout.
                                VStack(spacing: 2) {
                                    if let date = trip.startDate {
                                        Text(date, format: .dateTime.month(.abbreviated))
                                            .font(.caption.weight(.semibold))
                                        Text(date, format: .dateTime.day())
                                            .font(.title.weight(.semibold))
                                    } else {
                                        Image(systemName: "calendar").font(.title)
                                    }
                                }
                                .foregroundStyle(.blue)
                                .frame(width: size, height: size)
                                .background(Color.blue.opacity(0.08))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else if trips.loading {
                ProgressView("Loading trips…").padding(.horizontal, 20)
            } else {
                sectionMessage("Plan a shopping trip from your lists.")
            }
            if trips.trips.contains(where: { $0.isUncertain }) {
                Label("A trip needs its Calendar status checked.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
            }
            if let error = trips.error { sectionMessage(error) }
        }
    }

    private var lowStockSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Running low", linkLabel: "View inventory") {
                InventoryListView(store: store)
                    .toolbar(.visible, for: .navigationBar)
            }
            if loading && inventory.isEmpty && inventoryError == nil {
                ProgressView("Checking your inventory…").padding(.horizontal, 20)
            } else if let inventoryError {
                sectionMessage(inventoryError)
                Button("Try again") { Task { await store.refresh() } }
                    .disabled(loading).padding(.horizontal, 20)
            } else if inventory.isEmpty {
                sectionMessage("Your inventory is empty. Items below their restock levels will appear here once your inventory is set up.")
            } else if lowItems.isEmpty {
                sectionMessage("No items below their restock levels. Items need a quantity and a restock level to be checked.")
            } else {
                HomeCarousel {
                    ForEach(lowItems) { item in
                        HomeCarouselItem(title: item.displayName,
                                         detail: item.quantity.map { $0 == 0 ? "Out of stock" : "\($0.formatted()) \(item.unit) left" },
                                         detailColor: item.quantity == 0 ? .red : .secondary) { size in
                            ItemThumbnail(kind: "inventory", id: item.id, name: item.displayName,
                                          category: item.category, size: size)
                        }
                        .accessibilityValue(item.parLevel.map { "Restock below \($0.formatted()) \(item.unit)" } ?? "")
                    }
                }
            }
            NavigationLink("Plan a restock trip") { tripsDestination }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20)
        }
    }

    private func sectionHeader<Destination: View>(_ title: String, linkLabel: String, identifier: String = "",
                                                  @ViewBuilder destination: () -> Destination) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(destination: destination) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(linkLabel)
            .accessibilityIdentifier(identifier)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
    }

    private func sectionMessage(_ message: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 20)
    }
}

/// Each category keeps its own scroll position and snaps to the nearest item.
private struct HomeCarousel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.horizontal) {
            // Measure every label so longer names and Dynamic Type can set the row height.
            HStack(alignment: .top, spacing: 20) {
                content
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }
}

private struct HomeCarouselItem<Artwork: View>: View {
    let title: String
    var detail: String?
    var detailColor: Color = .secondary
    @ViewBuilder var artwork: (CGFloat) -> Artwork
    @ScaledMetric(relativeTo: .body) private var imageSize: CGFloat = 100
    @ScaledMetric(relativeTo: .body) private var itemWidth: CGFloat = 120
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 10) {
            artwork(imageSize)
                .frame(width: imageSize, height: imageSize)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
                .clipShape(Circle())
                .contentShape(Circle())
            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 3)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: itemWidth, alignment: .top)
        .accessibilityElement(children: .combine)
    }
}
