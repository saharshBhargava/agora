import SwiftUI

@MainActor
final class RecognitionController: ObservableObject {
    @Published var drafts: [RecognitionDraft] = []
    @Published var locationID: UUID?
    @Published var storeName = ""
    @Published var merchant: InventoryMerchant? {
        didSet { if let merchant { storeName = merchant.label } }
    }
    @Published var purchasedOn = ""
    @Published private(set) var busy = false
    @Published private(set) var saving = false
    @Published private(set) var didRecognize = false
    @Published private(set) var progress: CaptionProgress = .preparing
    @Published private(set) var message: String?
    @Published private(set) var cleanupNotice: String?
    @Published private(set) var modelDescription = ""
    @Published private(set) var mediaDisclosure = ""
    @Published private(set) var submission: SavedRecognition?
    private var model = ""
    private var modelProvider: ModelProviderKind = .gemini
    private var automaticStarted = false
    private var task: Task<Void, Never>?
    var locked: Bool { submission != nil && submission?.rejected != true }
    var completed: Bool { submission?.recognitionID != nil }
    var selectedCount: Int { drafts.filter(\.included).count }

    func restore(_ saved: SavedRecognition?) {
        guard let saved, !busy else { return }
        submission = saved; model = saved.model; modelProvider = saved.provider ?? .gemini; locationID = saved.locationID; purchasedOn = saved.purchasedOn ?? ""
        drafts = saved.items.map { item in
            var draft = RecognitionDraft(.init(name: item.displayName, category: item.category, unit: item.unit,
                                              quantity: item.quantity, confidence: item.confidence), inventory: [])
            draft.inventoryItemID = item.inventoryItemID
            return draft
        }
        modelDescription = "\(modelProvider.title) · \(model)"
        didRecognize = true
        if completed { message = "Saved to inventory." }
        else if !saved.rejected { message = "A save needs confirmation. Retry to safely check its result." }
    }

    func recognize(item: CaptureItem, file: URL, model: String, provider: InventoryRecognizing, store: InventoryStore, identity: ModelIdentity? = nil) {
        guard !busy, !locked else { return }
        let version = store.context
        self.model = model; modelProvider = identity?.provider ?? .gemini; busy = true; message = nil; cleanupNotice = nil
        task = Task {
            defer { busy = false; task = nil }
            do {
                let items = try await provider.recognize(file: file, kind: item.kind,
                    progress: { [weak self] in self?.progress = $0 }, cleanupNotice: { [weak self] in self?.cleanupNotice = $0 })
                try Task.checkCancellation()
                guard store.context == version else { throw CancellationError() }
                drafts = items.map { RecognitionDraft($0, inventory: store.activeItems) }
                submission = nil; didRecognize = true
                if items.isEmpty { message = "No inventory items found. Try a clearer photo or another capture." }
            } catch {
                if Task.isCancelled || error is CancellationError { message = "Recognition cancelled." }
                else if let failure = error as? CaptionHTTPFailure { message = "The model server could not complete the request (HTTP \(failure.status))." }
                else { message = error.localizedDescription }
            }
        }
    }

    func setStoreName(_ value: String) {
        storeName = value
        if value != merchant?.label { merchant = nil }
    }

    // View redraws and sheet presentations share this controller; a capture starts only once.
    func generateIfNeeded(item: CaptureItem, file: URL, settings: SettingsStore, store: InventoryStore,
                          provider: InventoryRecognizing? = nil) {
        guard !automaticStarted, !busy, !didRecognize, !locked else { return }
        automaticStarted = true
        generate(item: item, file: file, settings: settings, store: store, provider: provider)
    }

    func generate(item: CaptureItem, file: URL, settings: SettingsStore, store: InventoryStore,
                  provider: InventoryRecognizing? = nil) {
        do {
            if let provider {
                recognize(item: item, file: file, model: settings.model, provider: provider, store: store)
            } else {
                let client = try settings.client(for: .inventory, kind: item.kind)
                modelDescription = settings.featureDescription(.inventory)
                mediaDisclosure = settings.mediaDisclosure(for: .inventory, kind: item.kind)
                recognize(item: item, file: file, model: client.identity.model,
                          provider: ModelInventoryService(client: client), store: store, identity: client.identity)
            }
        } catch { message = error.localizedDescription }
    }

    func save(item: CaptureItem, store: InventoryStore, library: MediaLibrary) async {
        guard !busy, !completed else { return }
        guard let accountID = store.accountID, let householdID = store.householdID else {
            message = "Connect your account and select a household in Lists first."; return
        }
        let version = store.context
        busy = true; saving = true; message = nil
        defer { busy = false; saving = false }
        var sent = false
        do {
            var pending: SavedRecognition
            if let submission, !submission.rejected { pending = submission }
            else {
                let items = try drafts.filter(\.included).map { try $0.confirmed() }
                guard !items.isEmpty else { throw BrowserError("no_items", "Select at least one item to save.") }
                var identities = Set<String>()
                for item in items {
                    let identity = item.inventoryItemID?.uuidString ?? "\(item.displayName.lowercased())|\(item.unit.lowercased())"
                    guard identities.insert(identity).inserted else {
                        throw BrowserError("duplicate_item", "Combine duplicate items into one quantity before saving.")
                    }
                }
                let date = purchasedOn.trimmingCharacters(in: .whitespacesAndNewlines)
                if !date.isEmpty {
                    let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
                    guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else {
                        throw BrowserError("invalid_date", "Enter the purchase date as YYYY-MM-DD, or leave it blank.")
                    }
                }
                let name = storeName.trimmingCharacters(in: .whitespacesAndNewlines)
                if merchant == nil, !name.isEmpty {
                    guard name.count <= 80, name.contains(where: { $0.isLetter || $0.isNumber }) else {
                        throw BrowserError("invalid_store", "Enter a store name of up to 80 characters.")
                    }
                }
                try await library.savePurchasedFrom(name, for: item.id)
                try Task.checkCancellation()
                guard store.context == version else { throw CancellationError() }
                if merchant == nil, !name.isEmpty {
                    // The backend finds or creates the store by name; no second Save store step.
                    merchant = try await store.addMerchant(name: name, locality: "")
                }
                guard store.context == version else { throw CancellationError() }
                pending = SavedRecognition(key: UUID(), accountID: accountID, householdID: householdID,
                    capturedAt: item.createdAt, mediaKind: item.kind == .video ? "video" : "photos", model: model,
                    locationID: locationID, merchantID: merchant?.id, purchasedOn: date.isEmpty ? nil : date, items: items, provider: modelProvider)
            }
            guard pending.accountID == accountID, pending.householdID == householdID else {
                throw BrowserError("different_account", "Open the original account and household to finish this save.")
            }
            // Persist first; failures here cannot leave an untracked backend write.
            try await library.saveRecognition(pending, for: item.id)
            submission = pending
            try Task.checkCancellation()
            guard store.context == version else { throw CancellationError() }
            sent = true
            let result = try await store.saveRecognition(pending)
            pending.recognitionID = result.recognitionId
            // Even if the local completion write fails, the persisted key makes retry safe.
            try await library.saveRecognition(pending, for: item.id)
            submission = pending; message = "Saved \(result.items.count) items to inventory."
        } catch {
            if sent, let failure = error as? BrowserError, [400, 404, 422].contains(failure.status ?? 0),
               failure.code != "idempotency_key_reused", var rejected = submission {
                // These responses guarantee transaction rollback; editing is safe after persisting that fact.
                rejected.rejected = true
                do { try await library.saveRecognition(rejected, for: item.id); submission = rejected }
                catch { /* Keep the original frozen request when the local write fails. */ }
            }
            message = InventoryStore.message(error)
            if locked { message = "Save not confirmed. Retry this same save safely. \(message ?? "")" }
        }
    }
    func cancel() { task?.cancel() }
}
