import SwiftUI
import AVKit

struct RecognitionView: View {
    let item: CaptureItem
    let url: URL
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: InventoryStore
    @ObservedObject var library: MediaLibrary
    @StateObject private var controller: RecognitionController
    @Environment(\.dismiss) private var dismiss
    @State private var choosingMerchant = false
    @State private var confirmClose = false
    @State private var originalContext: UUID?
    @State private var restored = false
    @State private var differentAccount = false
    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?

    init(item: CaptureItem, url: URL, settings: SettingsStore, store: InventoryStore, library: MediaLibrary,
         controller: RecognitionController? = nil) {
        self.item = item; self.url = url; self.settings = settings; self.store = store; self.library = library
        _controller = StateObject(wrappedValue: controller ?? RecognitionController())
    }

    private var itemSummary: String {
        if controller.busy && !controller.saving { return "Identifying items…" }
        guard let first = controller.drafts.first else { return controller.didRecognize ? "No items found" : "Item identification" }
        return controller.drafts.count == 1 ? first.name : "\(first.name) + \(controller.drafts.count - 1) more"
    }

    var body: some View {
        NavigationStack {
            Form {
                if differentAccount {
                    Section { Text("This capture has an inventory save for another account or household. Switch back in Lists to view or finish it.") }
                } else {
                    Section {
                        if item.kind == .video { VideoPlayer(player: player).frame(height: 150) }
                        HStack(spacing: 16) {
                            if item.kind == .image {
                                Group {
                                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                                    else { ProgressView() }
                                }.frame(width: 96, height: 110)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text(itemSummary).font(.headline).accessibilityIdentifier("recognition.summary")
                                if controller.busy {
                                    ProgressView(controller.saving ? "Adding to inventory…" : controller.progress == .generating ? "Identifying items…" : controller.progress.title)
                                        .accessibilityIdentifier("recognition.progress")
                                } else if !controller.drafts.isEmpty {
                                    Text("Check the details below.").font(.subheadline).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    } footer: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(controller.modelDescription.isEmpty ? settings.featureDescription(.inventory) : controller.modelDescription)
                            Text(controller.busy ? controller.mediaDisclosure : settings.mediaDisclosure(for: .inventory, kind: item.kind))
                            Text("Only confirmed item details go to inventory.")
                        }
                    }
                    Section("Purchased from") {
                        TextField("Store or website, e.g. Costco", text: Binding(
                            get: { controller.storeName }, set: { controller.setStoreName($0) }))
                            .textInputAutocapitalization(.words)
                            .accessibilityIdentifier("recognition.storeName")
                        if store.householdID != nil {
                            Button("Choose an existing store") { choosingMerchant = true }
                                .accessibilityIdentifier("recognition.chooseStore")
                        }
                    }
                    .disabled(controller.saving || controller.locked)
                    Section {
                        if let message = controller.message { Text(message).font(.callout).accessibilityIdentifier("recognition.message") }
                        if let notice = controller.cleanupNotice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                        if !controller.busy, !controller.locked, restored {
                            Button(controller.didRecognize ? "Identify again" : "Try identification again") {
                                controller.generate(item: item, file: url, settings: settings, store: store)
                            }.accessibilityIdentifier("recognition.generate")
                        }
                    }
                    if !controller.drafts.isEmpty {
                        ForEach($controller.drafts) { $draft in
                            RecognitionItemEditor(draft: $draft, inventory: store.activeItems)
                                .disabled(controller.busy || controller.locked)
                        }
                        Section {
                            TextField("Purchase date (YYYY-MM-DD, optional)", text: $controller.purchasedOn)
                                .keyboardType(.numbersAndPunctuation)
                            LabeledContent("Captured") {
                                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                            }
                            Picker("Location for new items", selection: $controller.locationID) {
                                Text("None").tag(nil as UUID?)
                                ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                            }
                        } header: { Text("Optional details") }
                        .disabled(controller.saving || controller.locked)
                        if !controller.completed {
                            Section {
                                Button(controller.locked ? "Retry save" : "Add to inventory") {
                                    Task { await controller.save(item: item, store: store, library: library) }
                                }.disabled(controller.busy || store.householdID == nil || (!controller.locked && controller.selectedCount == 0))
                                    .accessibilityIdentifier("recognition.save")
                                if store.householdID == nil {
                                    Text("Connect the inventory backend to save these items.").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(controller.completed ? "Inventory saved" : "Add to inventory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if controller.busy || ((controller.didRecognize || !controller.storeName.isEmpty) && !controller.locked) { confirmClose = true }
                        else { dismiss() }
                    }.disabled(controller.saving)
                }
            }
            .interactiveDismissDisabled(controller.busy || ((controller.didRecognize || !controller.storeName.isEmpty) && !controller.locked))
            .confirmationDialog("Close review? Unsaved changes will be discarded and recognition will be cancelled.", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Close review", role: .destructive) { controller.cancel(); dismiss() }
            }
            .sheet(isPresented: $choosingMerchant) {
                InventoryMerchantPicker(store: store, title: "Purchased from") { controller.merchant = $0 }
            }
            .task {
                guard !restored else { return }
                restored = true
                originalContext = store.context
                let saved = library.items.first(where: { $0.id == item.id })?.recognition ?? item.recognition
                if let saved, saved.accountID != store.accountID || saved.householdID != store.householdID {
                    differentAccount = true
                } else {
                    controller.restore(saved)
                    if controller.storeName.isEmpty { controller.storeName = item.purchasedFrom ?? "" }
                    controller.generateIfNeeded(item: item, file: url, settings: settings, store: store)
                }
                if item.kind == .video { player = AVPlayer(url: url) }
                else { thumbnail = await Task.detached { MediaLibrary.thumbnail(url, maxPixels: 1600) }.value }
                if !differentAccount, let id = saved?.merchantID {
                    let originalName = controller.storeName
                    if let merchant = try? await store.merchant(id), controller.storeName == originalName {
                        controller.merchant = merchant
                    }
                }
            }
            .onChange(of: store.context) { _, new in
                if let originalContext, originalContext != new { controller.cancel(); dismiss() }
            }
            .onDisappear { player?.pause() }
        }
    }
}

private struct RecognitionItemEditor: View {
    @Binding var draft: RecognitionDraft
    let inventory: [InventoryItem]
    var body: some View {
        Section {
            Toggle("Include \(draft.name)", isOn: $draft.included)
            Group {
                Picker("Save as", selection: $draft.inventoryItemID) {
                    Text("New inventory item").tag(nil as UUID?)
                    ForEach(inventory) { Text("\($0.displayName) (\($0.unit))").tag(Optional($0.id)) }
                }
                .onChange(of: draft.inventoryItemID) { _, id in
                    if let existing = inventory.first(where: { $0.id == id }) {
                        draft.name = existing.displayName; draft.unit = existing.unit; draft.category = existing.category ?? ""
                    }
                }
                TextField("Item name", text: $draft.name).disabled(draft.inventoryItemID != nil)
                HStack {
                    Text("Quantity")
                    TextField("Quantity", text: $draft.quantity).keyboardType(.decimalPad)
                        .accessibilityLabel("Quantity for \(draft.name)")
                    TextField("Unit", text: $draft.unit).disabled(draft.inventoryItemID != nil).accessibilityLabel("Unit for \(draft.name)")
                }
                TextField("Category", text: $draft.category).disabled(draft.inventoryItemID != nil)
                if draft.inventoryItemID != nil {
                    Text("Records the observed total for this existing item; does not add to its quantity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!draft.included)
            Text("Model confidence: \(Int((draft.confidence * 100).rounded()))% — verify before saving")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
