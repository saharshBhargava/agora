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

    private var itemSummary: String {
        if controller.busy && !controller.saving { return "Identifying items…" }
        if !controller.drafts.isEmpty { return "We found \(controller.drafts.count) \(controller.drafts.count == 1 ? "item" : "items")" }
        return controller.didRecognize ? "No items found" : "Let's identify your items"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.space2) {
                    hero
                    if differentAccount {
                        Text("This scan has a saved review for another account or household. Switch back to that account to view or finish it.")
                            .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    } else if controller.completed {
                        successCard
                    } else {
                        mediaCard
                        disclosures
                        storeCard
                        statusBlock
                        if controller.drafts.isEmpty {
                            Text(controller.busy ? "Your items will appear here…" : "Nothing identified yet.")
                                .font(.system(size: 14)).foregroundStyle(Color.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(minHeight: 52)
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        } else {
                            // Bindings by id, not by index: a save that replaces the drafts (fewer items) must not
                            // leave an editor reading a position that no longer exists.
                            ForEach(controller.drafts) { draft in
                                RecognitionItemEditor(draft: draftBinding(draft), inventory: store.activeItems)
                                    .disabled(controller.busy || controller.locked)
                            }
                            detailsCard
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, Metrics.space1).padding(.bottom, Metrics.space3)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) { pinnedAction }
            .dibsScreen()
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
            .interactiveDismissDisabled(needsConfirmation || controller.saving || onNextScan != nil)
            .confirmationDialog("Close review? Unsaved edits will be discarded. Your scan stays in Recent scans so you can identify it again.", isPresented: $confirmClose, titleVisibility: .visible) {
                Button("Close review", role: .destructive) { close() }
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
                if let originalContext, originalContext != new { close() }
            }
            .onDisappear { player?.pause(); controller.cancel() }
        }
        .tint(Color.ink)
    }

    // MARK: pieces

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.completed ? "Inventory saved" : "Review scan")
                .font(.display(32)).tracking(-0.5).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            Text(controller.completed ? "These items are in your pantry now." : "Check names and quantities. Uncheck anything you don't want to save.")
                .font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
        }
    }

    private var mediaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.kind == .video {
                VideoPlayer(player: player).frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            }
            HStack(spacing: 14) {
                if item.kind == .image {
                    Group {
                        if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                        else { ProgressView() }
                    }
                    .frame(width: 96, height: 110)
                    .background(Color.paper)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(itemSummary).font(.display(22)).foregroundStyle(Color.ink).accessibilityIdentifier("recognition.summary")
                    if controller.busy {
                        ProgressView(controller.saving ? "Adding to inventory…" : controller.progress == .generating ? "Identifying items…" : controller.progress.title)
                            .font(.system(size: 14)).foregroundStyle(Color.muted)
                            .accessibilityIdentifier("recognition.progress")
                    } else if !controller.drafts.isEmpty {
                        Text("\(controller.selectedCount) selected").font(.system(size: 13)).foregroundStyle(Color.muted)
                    }
                }
                Spacer(minLength: 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).dibsCard()
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.modelDescription.isEmpty ? settings.featureDescription(.inventory) : controller.modelDescription)
            Text(controller.busy ? controller.mediaDisclosure : settings.mediaDisclosure(for: .inventory, kind: item.kind))
            Text("Only confirmed item details go to inventory.")
        }.font(.system(size: 13)).foregroundStyle(Color.muted).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Keep this field mounted while recognition finishes, preserving keyboard focus.
            Text("Purchased from · optional").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            TextField("Store or website, e.g. Costco", text: Binding(
                get: { controller.storeName }, set: { controller.setStoreName($0) }))
                .font(.system(size: 16)).foregroundStyle(Color.ink)
                .textInputAutocapitalization(.words)
                .dibsInput()
                .accessibilityIdentifier("recognition.storeName")
            if store.householdID != nil {
                Button("Choose a saved store") { choosingMerchant = true }
                    .buttonStyle(.dibs(.secondary, fontSize: 15))
                    .accessibilityIdentifier("recognition.chooseStore")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).dibsCard()
        .disabled(controller.saving || controller.locked)
    }

    @ViewBuilder private var statusBlock: some View {
        if let message = controller.message {
            Text(message).font(.system(size: 15)).lineSpacing(3).foregroundStyle(Color.bodyInk)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                .background(Color.dangerSoft, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .accessibilityIdentifier("recognition.message")
        }
        if let notice = controller.cleanupNotice { Text(notice).font(.system(size: 13)).foregroundStyle(Color.muted) }
        if !controller.busy, !controller.locked, restored {
            Button(controller.didRecognize ? "Identify again" : "Try identification again") {
                controller.generate(item: item, file: url, settings: settings, store: store)
            }.buttonStyle(.dibs(.secondary))
                .accessibilityIdentifier("recognition.generate")
            if controller.drafts.isEmpty, let onScanMore {
                Button { controller.cancel(); onScanMore() } label: { Label("Take another photo", systemImage: "camera") }
                    .buttonStyle(.dibs(.secondary))
            }
            if let onNextScan {
                Button("Skip to next scan") { controller.cancel(); onNextScan() }
                    .buttonStyle(.dibs(.secondary))
            }
        }
    }

    /// After a save: how many items went in, then the next step (the next queued scan, the pantry, or scan more).
    private var successCard: some View {
        let count = controller.submission?.items.count ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 48, height: 48)
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Inventory updated").font(.display(22)).foregroundStyle(Color.ink)
                    Text("\(count) \(count == 1 ? "item" : "items") saved to your pantry.").font(.system(size: 15)).foregroundStyle(Color.bodyInk)
                }
            }
            Text(controller.submission?.items.contains(where: { $0.inventoryItemID != nil }) == true
                 ? "Existing items now use the quantities you confirmed."
                 : "Your items are ready in your pantry.")
                .font(.system(size: 13)).foregroundStyle(Color.muted)
            if let onNextScan {
                Button("Review next scan", action: onNextScan).buttonStyle(.dibs)
            }
            NavigationLink { InventoryListView(store: store) } label: { Text("View pantry") }
                .buttonStyle(.dibs(onNextScan == nil ? .ink : .secondary))
                .accessibilityIdentifier("recognition.viewInventory")
            if onNextScan == nil, let onScanMore {
                Button(action: onScanMore) { Label("Scan more", systemImage: "camera.viewfinder") }
                    .buttonStyle(.dibs(.secondary))
                    .accessibilityIdentifier("recognition.scanMore")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
        .accessibilityIdentifier("recognition.success")
    }

    private func close() { controller.cancel(); onClose?(); dismiss() }

    private func draftBinding(_ draft: RecognitionDraft) -> Binding<RecognitionDraft> {
        Binding(
            get: { controller.drafts.first { $0.id == draft.id } ?? draft },
            set: { value in
                if let index = controller.drafts.firstIndex(where: { $0.id == draft.id }) { controller.drafts[index] = value }
            })
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Purchase date & storage location").font(.system(size: 17, weight: .bold)).foregroundStyle(Color.ink).accessibilityAddTraits(.isHeader)
            TextField("Purchase date (YYYY-MM-DD, optional)", text: $controller.purchasedOn)
                .font(.system(size: 16)).foregroundStyle(Color.ink)
                .keyboardType(.numbersAndPunctuation)
                .dibsInput()
            HStack {
                Text("Captured").font(.system(size: 15)).foregroundStyle(Color.bodyInk)
                Spacer()
                Text(item.createdAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink)
            }
            MenuFieldRow(title: "Location for new items", value: store.locations.first { $0.id == controller.locationID }?.name ?? "None") {
                Picker("Location for new items", selection: $controller.locationID) {
                    Text("None").tag(nil as UUID?)
                    ForEach(store.locations) { Text($0.name).tag(Optional($0.id)) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).dibsCard()
        .disabled(controller.saving || controller.locked)
    }

    @ViewBuilder private var pinnedAction: some View {
        if !differentAccount, !controller.drafts.isEmpty, !controller.completed {
            VStack(spacing: 6) {
                if store.householdID == nil {
                    Text("Sign in and choose a household to save items.").font(.system(size: 13)).foregroundStyle(Color.muted)
                } else if controller.locked {
                    Text("Retry checks the same save safely; it won't add the items twice.").font(.system(size: 13)).foregroundStyle(Color.muted)
                }
                Button(controller.saving ? "Saving…" : controller.locked ? "Check save status" : "Add \(controller.selectedCount) \(controller.selectedCount == 1 ? "item" : "items") to inventory") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await controller.save(item: item, store: store, library: library) }
                }.buttonStyle(.dibs)
                    .disabled(controller.busy || store.householdID == nil || (!controller.locked && controller.selectedCount == 0))
                    .accessibilityIdentifier("recognition.save")
            }
            .padding(.horizontal, 20).padding(.vertical, Metrics.space1).background(Color.paper)
        }
    }
}

private struct RecognitionItemEditor: View {
    @Binding var draft: RecognitionDraft
    let inventory: [InventoryItem]

    private var second: String {
        [draft.category, draft.unit].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(String(draft.name.prefix(1)).uppercased()).font(.display(22)).foregroundStyle(Color.ink)
                    .frame(width: 52, height: 52)
                    .background(tileColor(id: draft.id.uuidString), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.name.isEmpty ? "New item" : draft.name).font(.system(size: 16, weight: .bold)).foregroundStyle(Color.ink).lineLimit(2)
                    if !second.isEmpty { Text(second).font(.system(size: 13)).foregroundStyle(Color.muted).lineLimit(1) }
                    if draft.confidence < 0.7 { ShelfPill(text: "Check this item", symbol: "exclamationmark.circle", style: .danger) }
                }
                Spacer(minLength: 8)
                Text(draft.quantity.isEmpty ? "–" : draft.quantity).font(.display(28)).foregroundStyle(Color.ink).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            }
            .opacity(draft.included ? 1 : 0.45)
            Color.line.frame(height: 1)
            Toggle("Include \(draft.name)", isOn: $draft.included).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).tint(Color.ink)
            VStack(alignment: .leading, spacing: 12) {
                labeled("Quantity") {
                    TextField("Quantity", text: $draft.quantity).keyboardType(.decimalPad)
                        .accessibilityLabel("Quantity for \(draft.name)")
                }
                if draft.inventoryItemID != nil {
                    Text("Updates your existing item to this total; it doesn't add to the current quantity.")
                        .font(.system(size: 13)).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Edit details") {
                    VStack(alignment: .leading, spacing: 12) {
                        MenuFieldRow(title: "Save as", value: inventory.first { $0.id == draft.inventoryItemID }.map { "\($0.displayName) (\($0.unit))" } ?? "New inventory item") {
                            Picker("Save as", selection: $draft.inventoryItemID) {
                                Text("New inventory item").tag(nil as UUID?)
                                ForEach(inventory) { Text("\($0.displayName) (\($0.unit))").tag(Optional($0.id)) }
                            }
                        }
                        .onChange(of: draft.inventoryItemID) { _, id in
                            if let existing = inventory.first(where: { $0.id == id }) {
                                draft.name = existing.displayName; draft.unit = existing.unit; draft.category = existing.category ?? ""
                            }
                        }
                        labeled("Item name") { TextField("Item name", text: $draft.name).disabled(draft.inventoryItemID != nil) }
                        labeled("Unit") { TextField("Unit", text: $draft.unit).disabled(draft.inventoryItemID != nil).accessibilityLabel("Unit for \(draft.name)") }
                        labeled("Category") { TextField("Category", text: $draft.category).disabled(draft.inventoryItemID != nil) }
                    }
                    .padding(.top, 8)
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.ink)
            }.disabled(!draft.included)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dibsCard()
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13)).foregroundStyle(Color.muted)
            content().font(.system(size: 16)).foregroundStyle(Color.ink).dibsInput()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
