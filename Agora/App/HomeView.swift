import SwiftUI

enum AppTab: Hashable {
    case home, chat, capture, settings
}

struct HomeInventoryItem: Decodable, Identifiable {
    let id: UUID
    let displayName: String
    let unit: String
    let parLevel: Double?
    let quantity: Double?

    var isRunningLow: Bool {
        guard let quantity, let parLevel else { return false }
        return quantity < parLevel
    }
}

struct HomeView: View {
    @Binding var selectedTab: AppTab
    @ObservedObject var calendar: CalendarConnection
    let api: AgoraClient
    @State private var inventory: [HomeInventoryItem] = []
    @State private var loading = true
    @State private var inventoryError: String?
    @Environment(\.scenePhase) private var scenePhase

    private var lowItems: [HomeInventoryItem] {
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
                        dashboardCard(title: "Wishlist prices", subtitle: "Good finds, at your price.", symbol: "tag", tint: .purple) {
                            Text("Coming soon").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Keep an eye on items you want, with a heads-up when prices get close to or meet your target.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        dashboardCard(title: "Suggested for you", subtitle: "A few thoughtful additions.", symbol: "sparkles", tint: .teal) {
                            Text("Coming soon").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Discover useful picks based on what you have and what you might need next.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        dashboardCard(title: "Upcoming trips", subtitle: "Make room for your next run.", symbol: "calendar", tint: .blue) {
                            Text("Upcoming trip summaries are coming soon. For now, plan a shopping trip with your assistant.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button {
                                selectedTab = .chat
                            } label: {
                                Label("Plan a trip in chat", systemImage: "arrow.right")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedTab = .settings
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .task(id: calendar.accountID) {
                inventory = []; inventoryError = nil
                await loadInventory()
            }
            .refreshable { await loadInventory() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await loadInventory() } }
            }
        }
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
                Button("Try again") { Task { await loadInventory() } }
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

    @MainActor
    private func loadInventory() async {
        loading = true
        defer { loading = false }
        do {
            let items = try await api.fetch("v1/inventory", as: [HomeInventoryItem].self)
            try Task.checkCancellation()
            inventory = items
            inventoryError = nil
        } catch {
            if Task.isCancelled { return }
            inventoryError = (error as? BrowserError)?.detail ?? "Couldn’t load your inventory. Please try again."
        }
    }
}
