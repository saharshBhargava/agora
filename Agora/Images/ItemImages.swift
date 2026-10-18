import SwiftUI
import Combine
import CryptoKit

struct ItemImageReference: Hashable {
    let kind: String
    let id: UUID
    let name: String
    var category: String? = nil
    var path: String { "v1/item-images/\(kind)/\(id.uuidString)" }
}

struct ItemImageVerification: Decodable {
    let version: Int?
    let status: String?
    let basis: String?
    let visualCheck: String?
}

struct ItemProductIdentity: Codable, Equatable {
    var name: String
    var brand: String? = nil
    var model: String? = nil
    var variant: String? = nil
    var size: String? = nil
    var color: String? = nil
    var packCount: Int? = nil
    var gtin: String? = nil
    var body: [String: Any] {
        var result: [String: Any] = ["name": name]
        for (key, value) in [("brand", brand), ("model", model), ("variant", variant),
                             ("size", size), ("color", color), ("gtin", gtin)] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result[key] = value }
        }
        if let packCount { result["pack_count"] = packCount }
        return result
    }
}

struct ItemImageAsset: Decodable, Identifiable {
    let id: UUID
    let path: String
    let sourceUrl: String?
    let attribution: String?
    let matchKind: String
    let verification: ItemImageVerification?
    let title: String?
    var isExact: Bool { matchKind == "product" && verification?.version == 2 && verification?.status == "exact" }
    var isCandidate: Bool { matchKind == "product" && verification?.version == 2 && verification?.status == "candidate" }
    var label: String {
        switch matchKind {
        case "photo": return "Household photo"
        case "product": return "Product image"
        default: return "Representative illustration"
        }
    }
    var safeSource: URL? {
        guard let sourceUrl, let url = URL(string: sourceUrl), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct ItemImageDescriptor: Decodable {
    let status: String
    let fallback: String
    let asset: ItemImageAsset?
    let choices: [ItemImageAsset]
    let userSelected: Bool
    let inherited: Bool
    let version: Int
    let matchStatus: String?
    let identity: ItemProductIdentity?
    let missingIdentity: [String]?
    let unresolvedReason: String?
    var displayAsset: ItemImageAsset? {
        // Older servers may return usable alternatives without assigning their main asset yet.
        // Show a default during rollout, but never resurrect an explicitly removed image or stale search.
        let selected = asset ?? (!userSelected && status != "queued" ? choices.first { $0.isExact || $0.isCandidate } : nil)
        guard let asset = selected, asset.isExact || asset.isCandidate || userSelected || asset.matchKind == "photo" || asset.matchKind == "representative"
        else { return nil }
        return asset
    }
    var imageLabel: String {
        if userSelected, displayAsset != nil { return "Image you selected" }
        if displayAsset?.isCandidate == true { return "Automatically selected image" }
        return displayAsset?.label ?? (status == "queued" ? "Finding product image" : "No matching image found")
    }
}

@MainActor
final class ItemImageStore: ObservableObject {
    @Published private(set) var descriptors: [ItemImageReference: ItemImageDescriptor] = [:]
    @Published private(set) var loadMessages: [ItemImageReference: String] = [:]
    @Published private(set) var pictures: [UUID: UIImage] = [:]
    @Published private(set) var context = ""
    @Published private(set) var revision = 0
    private let api: AgoraClient
    private var tasks: [ItemImageReference: Task<Void, Never>] = [:]
    private var taskIDs: [ItemImageReference: UUID] = [:]
    private var loadedAt: [ItemImageReference: Date] = [:]
    private var pending: [ItemImageReference: (String, String)] = [:]
    private var cancellable: AnyCancellable?

    init(api: AgoraClient, calendar: CalendarConnection? = nil) {
        self.api = api
        // Clear synchronously before sign-out/account changes can redraw any private image.
        cancellable = calendar?.objectWillChange.sink { [weak self] _ in self?.reset() }
    }

    func reset(context: String = "") {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll(); taskIDs.removeAll(); loadMessages.removeAll(); descriptors.removeAll(); pictures.removeAll(); loadedAt.removeAll(); pending.removeAll()
        self.context = context + UUID().uuidString
    }

    func observe(_ ref: ItemImageReference, interval: Duration = .seconds(30)) async {
        let epoch = context
        while !Task.isCancelled, context == epoch {
            await load(ref)
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }

    func prefetch(_ references: [ItemImageReference]) async {
        let epoch = context
        var seen = Set<ItemImageReference>()
        var remaining = references.filter { seen.insert($0).inserted }.makeIterator()
        // One read per item per pass: a slow search must not hold up the rest of the inventory.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                if let ref = remaining.next() { group.addTask { @MainActor in
                    guard self.context == epoch else { return }
                    await self.load(ref, poll: false)
                } }
            }
            while await group.next() != nil {
                guard !Task.isCancelled, context == epoch else { group.cancelAll(); return }
                if let ref = remaining.next() { group.addTask { @MainActor in
                    guard self.context == epoch else { return }
                    await self.load(ref, poll: false)
                } }
            }
        }
    }

    func load(_ ref: ItemImageReference, force: Bool = false, poll: Bool = true) async {
        guard !Task.isCancelled else { return }
        if let task = tasks[ref] {
            if poll { await task.value }
            return
        }
        let cacheAge: TimeInterval = descriptors[ref]?.status == "queued" ? 3 : 60
        if !force, let date = loadedAt[ref], Date().timeIntervalSince(date) < cacheAge {
            if poll, let asset = descriptors[ref]?.displayAsset, pictures[asset.id] == nil {
                try? await loadAsset(asset)
            }
            return
        }
        let epoch = context, taskID = UUID()
        taskIDs[ref] = taskID
        let task = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<(poll ? 30 : 1) {
                do {
                    let descriptor = try await api.fetch(ref.path, as: ItemImageDescriptor.self)
                    guard !Task.isCancelled, context == epoch else { return }
                    descriptors[ref] = descriptor
                    if let asset = descriptor.displayAsset { try await loadAsset(asset, epoch: epoch) }
                    loadMessages[ref] = nil
                    loadedAt[ref] = Date()
                    if descriptor.status != "queued" || !poll { return }
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    guard !Task.isCancelled, context == epoch else { return }
                    switch (error as? BrowserError)?.status {
                    case 401, 403: loadMessages[ref] = "Sign in again to load images."
                    case 404: loadMessages[ref] = "The image service isn't available yet. Try again shortly."
                    default: loadMessages[ref] = "Images couldn't be loaded. Check your connection and try again."
                    }
                    return
                }
            }
        }
        tasks[ref] = task
        await task.value
        if context == epoch, taskIDs[ref] == taskID { tasks[ref] = nil; taskIDs[ref] = nil }
    }

    func loadAsset(_ asset: ItemImageAsset, epoch: String? = nil) async throws {
        if pictures[asset.id] != nil { return }
        let expected = epoch ?? context
        let data = try await api.imageData(asset.path)
        guard expected == context, !Task.isCancelled else { throw CancellationError() }
        guard let image = UIImage(data: data) else { throw BrowserError("invalid_image", "This image could not be loaded.") }
        if pictures.count >= 200, let oldest = pictures.keys.first { pictures[oldest] = nil }
        pictures[asset.id] = image
    }

    func select(_ ref: ItemImageReference, mode: String, photo: Data? = nil, asset: UUID? = nil,
                identity: ItemProductIdentity? = nil) async throws {
        let epoch = context
        var body: [String: Any] = ["mode": mode]
        if let identity { body["identity"] = identity.body }
        if let photo { body["photo"] = photo.base64EncodedString() }
        if let asset { body["asset_id"] = asset.uuidString }
        let digest = SHA256.hash(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]))
            .map { String(format: "%02x", $0) }.joined()
        let key = pending[ref]?.0 == digest ? pending[ref]!.1 : UUID().uuidString
        pending[ref] = (digest, key)
        let result = try await api.fetch(ref.path, as: ItemImageDescriptor.self, method: "PUT", body: body, key: key)
        guard context == epoch, !Task.isCancelled else { throw CancellationError() }
        pending[ref] = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        // Linked lists/wishes inherit inventory choices; invalidate their metadata as well.
        descriptors.removeAll(); loadedAt.removeAll()
        descriptors[ref] = result
        loadMessages[ref] = nil
        if let asset = result.displayAsset { try await loadAsset(asset, epoch: epoch) }
        revision += 1
    }
}

private struct ItemImageStoreKey: EnvironmentKey {
    static let defaultValue: ItemImageStore? = nil
}
extension EnvironmentValues {
    var itemImages: ItemImageStore? {
        get { self[ItemImageStoreKey.self] }
        set { self[ItemImageStoreKey.self] = newValue }
    }
}

struct ItemThumbnail: View {
    let kind: String
    let id: UUID
    let name: String
    var category: String? = nil
    var size: CGFloat = 52
    @Environment(\.itemImages) private var store
    var body: some View {
        let ref = ItemImageReference(kind: kind, id: id, name: name, category: category)
        if let store {
            StoredItemThumbnail(store: store, ref: ref, size: size)
        } else {
            Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                .frame(width: size, height: size).accessibilityLabel("Exact image unavailable for \(name)")
        }
    }
}

private struct StoredItemThumbnail: View {
    @ObservedObject var store: ItemImageStore
    let ref: ItemImageReference
    let size: CGFloat
    @Environment(\.scenePhase) private var phase
    var body: some View {
        Group {
            if let asset = store.descriptors[ref]?.displayAsset, let image = store.pictures[asset.id] {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                VStack(spacing: 3) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: max(16, size / 3)))
                    if size >= 100 { Text(store.loadMessages[ref] == nil ? (store.descriptors[ref]?.imageLabel ?? "Finding product image") : "Images unavailable")
                        .font(.caption).multilineTextAlignment(.center) }
                }.foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("\(ref.name): \(store.loadMessages[ref] ?? store.descriptors[ref]?.imageLabel ?? "Exact image unavailable")")
        .task(id: "\(ref)-\(store.context)-\(store.revision)-\(phase == .active)") {
            if phase == .active { await store.observe(ref) }
        }
    }
}

struct RepresentativeImage: View {
    let name: String
    var category: String? = nil
    var kindOverride: String? = nil
    var body: some View {
        Image("Item-\(kindOverride ?? Self.kind(name: name, category: category))")
            .resizable().scaledToFit()
            .accessibilityLabel("Representative illustration of \(name)")
    }
    static func kind(name: String, category: String?) -> String {
        let groups: [(String, [String])] = [
            ("milk", ["milk", "dairy", "yogurt", "cream"]), ("eggs", ["egg"]),
            ("produce", ["apple", "banana", "fruit", "vegetable", "spinach", "produce", "avocado", "potato"]),
            ("bread", ["bread", "bakery", "toast"]), ("drink", ["water", "juice", "coffee", "tea", "beverage"]),
            ("cleaning", ["soap", "detergent", "clean", "sponge", "paper towel"]),
            ("cookware", ["pan", "skillet", "pot", "kitchen", "cookware"]),
            ("electronics", ["headphone", "speaker", "charger", "electronic", "computer"]),
            ("food", ["rice", "pasta", "food", "pantry", "cereal", "bean", "snack", "meat", "fish", "steak"])]
        for text in [name.lowercased(), (category ?? "").lowercased()] {
            if let group = groups.first(where: { group in
                group.1.contains { term in
                    text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: term) + "(?:s|es)?\\b", options: .regularExpression) != nil
                }
            }) { return group.0 }
        }
        return "item"
    }
}
