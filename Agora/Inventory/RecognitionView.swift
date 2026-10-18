import SwiftUI
import AVKit

struct RecognitionView: View {
    let item: CaptureItem
    let url: URL
    @ObservedObject var settings: SettingsStore
    @ObservedObject var store: InventoryStore
    @ObservedObject var library: MediaLibrary
    @StateObject private var controller: RecognitionController
    var onClose: (() -> Void)?
    var onScanMore: (() -> Void)?
    var onNextScan: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var choosingMerchant = false
    @State private var confirmClose = false
    @State private var originalContext: UUID?
    @State private var restored = false
    @State private var differentAccount = false
    @State private var thumbnail: UIImage?
    @State private var player: AVPlayer?

    init(item: CaptureItem, url: URL, settings: SettingsStore, store: InventoryStore, library: MediaLibrary,
         controller: RecognitionController? = nil, onClose: (() -> Void)? = nil,
         onScanMore: (() -> Void)? = nil, onNextScan: (() -> Void)? = nil) {
        self.item = item; self.url = url; self.settings = settings; self.store = store; self.library = library
        self.onClose = onClose; self.onScanMore = onScanMore; self.onNextScan = onNextScan
        _controller = StateObject(wrappedValue: controller ?? RecognitionController())
    }

    private var needsConfirmation: Bool {
        !controller.completed && (controller.busy || ((controller.didRecognize || !controller.storeName.isEmpty) && !controller.locked))
    }
    private var summary: String {
        if controller.busy && !controller.saving { return "Identifying items…" }
        if !controller.drafts.isEmpty { return "We found \(controller.drafts.count) \(controller.drafts.count == 1 ? "item" : "items")" }
        return controller.didRecognize ? "No items found" : "Let's identify your items"
    }

    var body: some View {
        NavigationStack {
            Group {
                if differentAccount {
                    ContentUnavailableView("Switch back to finish", systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("This scan has a saved review for another account or household. Switch back in Lists to view or finish it."))
                } else if controller.completed {
                    successView
                } else {
                    reviewForm
                }
            }
            .agoraSurface()
            .navigationTitle(controller.completed ? "Inventory saved" : "Review scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(controller.completed ? "Done" : "Close") {
                        if needsConfirmation { confirmClose = true }
                        else { close() }
                    }.disabled(controller.saving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !differentAccount && !controller.completed { saveBar }
            }
            .interactiveDismissDisabled(needsConfirmation || controller.saving || onNextScan != nil)
            .confirmationDialog("Close review? Unsaved edits will be discarded. Your scan stays in Recent scans so you can identify it again.", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Close review", role: .destructive) { close() }
            }
            .sheet(isPresented: $choosingMerchant) {
                InventoryMerchantPicker(store: store, title: "Purchased from") { controller.merchant = $0 }
            }
            .task {
                guard !restored else { return }
                restored = true; originalContext = store.context
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
                if let originalContext, originalContext != new { close() }
            }
            .onDisappear { player?.pause(); controller.cancel() }
        }
    }

    private var reviewForm: some View {
        Form {
            Section {
                if item.kind == .video { VideoPlayer(player: player).frame(height: 150) }
                HStack(spacing: 16) {
                    if item.kind == .image {
                        Group {
                            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFit() }
                            else { ProgressView() }
                        }
                        .frame(width: 80, height: 90).clipShape(RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("Your captured photo")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(summary).font(.headline).accessibilityIdentifier("recognition.summary")
                        if controller.busy {
                            ProgressView(controller.saving ? "Adding to inventory…" : controller.progress == .generating ? "Identifying items…" : controller.progress.title)
                                .accessibilityIdentifier("recognition.progress")
                        }
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(controller.modelDescription.isEmpty ? settings.featureDescription(.inventory) : controller.modelDescription)
                    Text(controller.busy ? controller.mediaDisclosure : settings.mediaDisclosure(for: .inventory, kind: item.kind))
                }
            }
            // Keep this field mounted while recognition finishes, preserving keyboard focus.
            Section("Purchased from · optional") {
                TextField("Store or website, e.g. Costco", text: Binding(
                    get: { controller.storeName }, set: { controller.setStoreName($0) }))
                    .textInputAutocapitalization(.words).accessibilityIdentifier("recognition.storeName")
                if store.householdID != nil {
                    Button("Choose a saved store") { choosingMerchant = true }
                        .accessibilityIdentifier("recognition.chooseStore")
                }
            }.disabled(controller.saving || controller.locked)
            if let message = controller.message {
                Section { Text(message).font(.callout).accessibilityIdentifier("recognition.message") }
            }
            if let notice = controller.cleanupNotice { Section { Text(notice).font(.footnote).foregroundStyle(.secondary) } }
            if !controller.drafts.isEmpty {
                Section("Items · \(controller.selectedCount) selected") {
                    ForEach($controller.drafts) { $draft in
                        RecognitionItemEditor(draft: $draft, inventory: store.activeItems)
                            .disabled(controller.busy || controller.locked)
                    }
                }
                Section {
                    DisclosureGroup("Purchase date & storage location") {
                        TextField("Purchase date (YYYY-MM-DD, optional)", text: $controller.purchasedOn)
                            .keyboardType(.numbersAndPunctuation)
                        Picker("Location for new items", selection: $controller.locationID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                        }
                        LabeledContent("Captured") { Text(item.createdAt, format: .dateTime.month().day().hour().minute()) }
                    }
                }.disabled(controller.saving || controller.locked)
            }
            if !controller.busy, !controller.locked, restored {
                Section {
                    Button(controller.didRecognize ? "Identify again" : "Try identification again") {
                        controller.generate(item: item, file: url, settings: settings, store: store)
                    }.accessibilityIdentifier("recognition.generate")
                    if controller.drafts.isEmpty, let onScanMore {
                        Button("Take another photo", systemImage: "camera") { controller.cancel(); onScanMore() }
                    }
                    if let onNextScan { Button("Skip to next scan") { controller.cancel(); onNextScan() } }
                }
            }
        }
    }

    private var saveBar: some View {
        VStack(spacing: 8) {
            if store.householdID == nil {
                Text("Sign in and choose a household in Lists to save items.").font(.caption).foregroundStyle(.secondary)
            } else if controller.locked {
                Text("Retry checks the same save safely; it won't add the items twice.").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Task { await controller.save(item: item, store: store, library: library) }
            } label: {
                Text(controller.saving ? "Saving…" : controller.locked ? "Check save status" : "Add \(controller.selectedCount) \(controller.selectedCount == 1 ? "item" : "items") to inventory")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(AgoraPrimaryButtonStyle())
            .disabled(controller.busy || store.householdID == nil || (!controller.locked && controller.selectedCount == 0))
            .accessibilityIdentifier("recognition.save")
        }
        .padding().background(.bar)
    }

    private var successView: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Inventory updated").font(.title.bold())
                    Text("\(controller.submission?.items.count ?? 0) \(controller.submission?.items.count == 1 ? "item" : "items") saved to your inventory.")
                        .foregroundStyle(.secondary)
                }.multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    if let onNextScan {
                        Button("Review next scan", action: onNextScan)
                            .buttonStyle(AgoraPrimaryButtonStyle())
                    }
                    NavigationLink { InventoryListView(store: store) } label: {
                        Text("View inventory").frame(maxWidth: .infinity)
                    }.buttonStyle(AgoraPrimaryButtonStyle())
                        .accessibilityIdentifier("recognition.viewInventory")
                    if onNextScan == nil, let onScanMore {
                        Button("Scan more", systemImage: "camera.viewfinder", action: onScanMore)
                            .buttonStyle(.bordered).controlSize(.large)
                            .accessibilityIdentifier("recognition.scanMore")
                    }
                }
            }.padding(24).frame(maxWidth: 600).frame(maxWidth: .infinity).padding(.top, 32)
        }
        .accessibilityIdentifier("recognition.success")
    }

    private func close() { controller.cancel(); onClose?(); dismiss() }
}

private struct RecognitionItemEditor: View {
    @Binding var draft: RecognitionDraft
    let inventory: [InventoryItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $draft.included) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(draft.name).font(.headline)
                    if draft.confidence < 0.7 {
                        Label("Check this item", systemImage: "exclamationmark.circle")
                            .labelStyle(.titleAndIcon)
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }.accessibilityLabel("Include \(draft.name)")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Quantity")
                    Spacer()
                    TextField("Quantity", text: $draft.quantity).keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing).frame(minWidth: 50, maxWidth: 90)
                        .accessibilityLabel("Quantity for \(draft.name)")
                    Text(draft.unit).foregroundStyle(.secondary)
                }
                if draft.inventoryItemID != nil {
                    Text("Updates your existing item to this total; it doesn't add to the current quantity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Edit details") {
                    VStack(alignment: .leading, spacing: 12) {
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
                        TextField("Unit", text: $draft.unit).disabled(draft.inventoryItemID != nil)
                            .accessibilityLabel("Unit for \(draft.name)")
                        TextField("Category", text: $draft.category).disabled(draft.inventoryItemID != nil)
                    }.padding(.vertical, 8)
                }.font(.subheadline)
            }.disabled(!draft.included)
        }.padding(.vertical, 6)
    }
}
