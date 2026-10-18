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
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("A little ahead of everyday.")
                            .font(.title2.bold())
                        Text("Your essentials, good finds, and next shopping trip.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    scanCard

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                        lowStockCard
                        dashboardCard(title: "Wishlist", subtitle: "Good finds, at your price.", symbol: "heart", tint: .purple) {
                            if shopping.active.isEmpty {
                                Text("Save something you want and set a target price.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(shopping.active.prefix(3)) { item in
                                HStack {
                                    Text(item.title).font(.subheadline)
                                    Spacer()
                                    if let price = item.targetLabel { Text(price).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                            NavigationLink("View wishlist") {
                                ShoppingView(store: shopping, settings: settings)
                                    .toolbar(.visible, for: .navigationBar)
                            }
                        }
                        dashboardCard(title: "Suggested for you", subtitle: "A few thoughtful additions.", symbol: "sparkles", tint: .teal) {
                            if shopping.suggestions.isEmpty {
                                Text("Review replenishment suggestions or find ideas based on your inventory.").font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(shopping.suggestions.prefix(2)) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.subheadline.weight(.semibold))
                                    if let reason = item.rationale { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                            }
                            if let error = shopping.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                            NavigationLink("View suggestions") {
                                ShoppingView(store: shopping, settings: settings, selection: "suggestions")
                                    .toolbar(.visible, for: .navigationBar)
                            }
                        }
                        dashboardCard(title: "Upcoming trips", subtitle: "Make room for your next run.", symbol: "calendar", tint: .blue) {
                            if trips.trips.contains(where: { $0.isUncertain }) {
                                Label("A trip needs its Calendar status checked.", systemImage: "exclamationmark.circle")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                            ForEach(trips.trips.filter { $0.status == "scheduled" && ($0.endDate ?? .distantPast) > Date() }
                                .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.prefix(2)) { trip in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(trip.title).font(.subheadline.weight(.semibold))
                                    if let start = trip.startDate {
                                        Text(start, format: .dateTime.weekday().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if let error = trips.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                            NavigationLink("Shopping lists & trips") { tripsDestination }
                                .accessibilityIdentifier("homeShoppingTrips")
                        }
                    }
                }
                .padding(20)
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
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 32, weight: .medium))
                        .accessibilityHidden(true)
                    Spacer()
                    Text("START HERE")
                        .font(.caption.weight(.bold))
                        .tracking(1.4)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("What’s on your shelves?")
                        .font(.title2.bold())
                    Text("Start with a photo of your everyday essentials.")
                        .font(.subheadline)
                }
                Label("Scan your items", systemImage: "arrow.right")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.16), in: Capsule())
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [Color(red: 0.04, green: 0.34, blue: 0.32), Color(red: 0.06, green: 0.43, blue: 0.39)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 24)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("homeScanItems")
    }

    private var lowStockCard: some View {
        dashboardCard(title: "Running low", subtitle: "Catch the essentials before they run out.", symbol: "basket", tint: .orange) {
            if loading && inventory.isEmpty && inventoryError == nil {
                ProgressView("Checking your inventory…").font(.subheadline)
            } else if let inventoryError {
                Text(inventoryError).font(.subheadline).foregroundStyle(.secondary)
                Button("Try again") { Task { await store.refresh() } }
                    .disabled(loading)
            } else if inventory.isEmpty {
                Text("Your inventory is empty.").font(.subheadline.weight(.semibold))
                Text("Items below their restock levels will appear here once your inventory is set up.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if lowItems.isEmpty {
                Text("No items below their restock levels.").font(.subheadline.weight(.semibold))
                Text("Items need a quantity and a restock level to be checked.")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(lowItems.prefix(4)) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.displayName).font(.subheadline.weight(.semibold))
                            if let threshold = item.parLevel {
                                Text("Restock below \(threshold.formatted()) \(item.unit)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        if let quantity = item.quantity {
                            Text(quantity == 0 ? "Out of stock" : "\(quantity.formatted()) left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(quantity == 0 ? Color.red : Color.primary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if lowItems.count > 4 {
                    Text("And \(lowItems.count - 4) more running low")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            NavigationLink("View inventory") {
                InventoryListView(store: store)
                    .toolbar(.visible, for: .navigationBar)
            }
                .font(.subheadline.weight(.semibold))
            NavigationLink("Plan a restock trip") { tripsDestination }
                .font(.subheadline.weight(.semibold))
        }
    }

    private func dashboardCard<Content: View>(title: String, subtitle: String, symbol: String, tint: Color,
                                               @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 42, height: 42)
                    .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content()
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

}
