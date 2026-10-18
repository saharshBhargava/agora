import SwiftUI
import AVKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

/// Scan: add items to the pantry from a photo, a shelf video, the photo library or Files. Every new scan joins a
/// review queue and opens in `RecognitionView` one at a time; nothing is saved until the review is confirmed.
/// Pushed from the Dibs home and the pantry, in the Dibs look (hero, cards, one pinned ink action).
struct CaptureView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var inventory: InventoryStore
    @StateObject private var library: MediaLibrary
    @State private var camera: CameraMode?
    @State private var sheet: CaptureSheet?
    @State private var pickingFiles = false
    @State private var deleting: CaptureItem?
    @State private var requestingPermission = false
    @State private var needsSettings = false
    @State private var cameraDismissed = true
    @State private var sheetDismissed = true
    @State private var reviewQueue = ScanReviewQueue()
    @State private var scanAfterDismiss = false
    @State private var showingAll = false
    @State private var inputContext: UUID?

    init(settings: SettingsStore, inventory: InventoryStore, library: MediaLibrary? = nil) {
        self.settings = settings; self.inventory = inventory
        _library = StateObject(wrappedValue: library ?? MediaLibrary())
    }

    enum CameraMode: String, Identifiable { case photo, video; var id: String { rawValue } }
    private enum CaptureSheet: Identifiable {
        case library, review(CaptureItem), preview(CaptureItem)
        var id: String {
            switch self {
            case .library: return "library"
            case .review(let item): return "review-\(item.id)"
            case .preview(let item): return "preview-\(item.id)"
            }
        }
    }
    private var disabled: Bool { library.busy || requestingPermission }

    var body: some View {
        ShelfPage {
            ShelfHero(title: "Add items to your pantry",
                      subtitle: "Scan, review, and save. You choose what gets added.")
            Label("Keep labels visible and include the whole item.", systemImage: "viewfinder")
                .font(.system(size: 13)).foregroundStyle(Color.muted)
            sources
            Text("Photos and videos are identified automatically. Review the results before saving. PDFs are kept for viewing only.")
                .shelfNote()
                .fixedSize(horizontal: false, vertical: true)
            if library.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Preparing your scans…").font(.system(size: 14)).foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
            }
            recentScans
        } bottom: {
            Button { Task { await openCamera(.photo) } } label: { Label("Scan items", systemImage: "camera.viewfinder") }
                .buttonStyle(.dibs)
                .accessibilityIdentifier("capture.photo")
                .disabled(disabled)
        }
        .task { await library.load() }
        .fullScreenCover(item: $camera, onDismiss: {
            cameraDismissed = true
            presentNextReview()
        }) { mode in
            // The native camera provides Use Photo / Retake before handing us the capture.
            CameraPicker(video: mode == .video) { result in
                camera = nil
                switch result {
                case .success(let media): if let (url, kind) = media { saveTemporary(url, kind: kind) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }.ignoresSafeArea()
        }
        .sheet(item: $sheet, onDismiss: {
            sheetDismissed = true
            if scanAfterDismiss {
                scanAfterDismiss = false
                Task { await openCamera(.photo) }
            } else { presentNextReview() }
        }) { destination in
            switch destination {
            case .library:
                LibraryPicker { results in
                    sheet = nil
                    guard !results.isEmpty else { return }
                    importPhotos(results)
                }
            case .review(let item):
                RecognitionView(item: item, url: library.url(for: item), settings: settings,
                                store: inventory, library: library,
                                onClose: { reviewQueue.clear() },
                                onScanMore: {
                                    reviewQueue.clear(); scanAfterDismiss = true; sheet = nil
                                },
                                onNextScan: reviewQueue.isEmpty ? nil : { sheet = nil })
            case .preview(let item):
                MediaPreview(item: item, url: library.url(for: item), settings: settings, inventory: inventory, library: library)
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.image, .movie, .pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .onChange(of: pickingFiles) { _, presented in if !presented { presentNextReview() } }
        .onChange(of: inventory.context) { _, _ in
            inputContext = nil
            reviewQueue.clear(); scanAfterDismiss = false; sheet = nil; camera = nil
        }
        .alert("Capture", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            if needsSettings {
                Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Button("OK", role: .cancel) { library.error = nil; needsSettings = false }
        } message: { Text(library.error ?? "") }
        .confirmationDialog("Delete this item?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let item = deleting { Task { await library.remove(item) } }
                deleting = nil
            }
        }
    }

    /// A shelf video, the photo library and Files: other ways in besides the pinned "Scan items".
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("More ways to add")
            VStack(spacing: 0) {
                Button { Task { await openCamera(.video) } } label: {
                    DibsLinkRow(title: "Scan a shelf", detail: "Record a short video. Pan slowly so labels stay clear.", symbol: "video", tint: 0xDCEFD9)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.video")
                Hairline()
                Button { present(.library) } label: {
                    DibsLinkRow(title: "Choose photos", detail: "Pick photos or videos you already have", symbol: "photo.on.rectangle", tint: 0xD8E2FA)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.library")
                Hairline()
                Button { inputContext = inventory.context; pickingFiles = true } label: {
                    DibsLinkRow(title: "Import", detail: "Photos, videos, or PDFs from Files", symbol: "square.and.arrow.down", tint: 0xF2E3B5)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("capture.files")
            }
            .dibsCard()
            .disabled(disabled)
        }
    }

    private var recentScans: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfSectionTitle("Recent scans")
                if library.items.count > 3 {
                    Button(showingAll ? "Show less" : "See all") { showingAll.toggle() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .frame(minHeight: Metrics.tap)
                }
            }
            if library.items.isEmpty {
                ShelfEmpty(symbol: "clock", title: "No scans yet",
                           message: "Your scans will appear here. You can return to review them anytime.")
            } else {
                VStack(spacing: 0) {
                    let shown = showingAll ? library.items : Array(library.items.prefix(3))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Hairline() }
                        HStack(spacing: 4) {
                            Button { present(item.kind == .document ? .preview(item) : .review(item)) } label: {
                                RecentScanRow(item: item, url: library.url(for: item),
                                              status: item.scanStatus(accountID: inventory.accountID, householdID: inventory.householdID))
                            }
                            .buttonStyle(.plain)
                            Menu {
                                Button("View media & captions", systemImage: "photo") { present(.preview(item)) }
                                ShareLink(item: library.url(for: item)) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(Color.ink)
                                    .frame(width: Metrics.tap, height: Metrics.tap)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Options for \(item.title)")
                        }
                    }
                }
                .dibsCard()
            }
        }
    }

    private func present(_ destination: CaptureSheet) {
        if case .library = destination { inputContext = inventory.context }
        sheetDismissed = false; sheet = destination
    }

    private func openCamera(_ mode: CameraMode) async {
        requestingPermission = true; needsSettings = false
        let context = inventory.context
        defer { requestingPermission = false }
        guard CameraPicker.availableCamera(video: mode == .video) != nil else {
            library.error = CaptureFailure.cameraUnavailable.localizedDescription
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            needsSettings = true; library.error = "Allow camera access in Settings to scan items."; return
        }
        if mode == .video, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            needsSettings = true; library.error = "Allow microphone access in Settings to record videos with sound."; return
        }
        guard inventory.context == context else { return }
        inputContext = context; cameraDismissed = false; camera = mode
    }

    private func saveTemporary(_ url: URL, kind: CaptureItem.Kind) {
        guard let context = inputContext, context == inventory.context else {
            try? FileManager.default.removeItem(at: url); return
        }
        library.busy = true
        Task {
            defer { library.busy = false; presentNextReview(); try? FileManager.default.removeItem(at: url) }
            if let item = await library.add(file: url, kind: kind), inventory.context == context {
                reviewQueue.enqueue([item])
            }
        }
    }

    private func importPhotos(_ results: [PHPickerResult]) {
        guard let context = inputContext, context == inventory.context else { return }
        library.busy = true
        Task {
            defer { library.busy = false; presentNextReview() }
            for result in results {
                guard inventory.context == context else { return }
                do {
                    let (url, kind) = try await LibraryPicker.copyFile(from: result)
                    defer { try? FileManager.default.removeItem(at: url) }
                    if let item = await library.add(file: url, kind: kind), inventory.context == context {
                        reviewQueue.enqueue([item])
                    }
                } catch { library.error = "Could not import a selected item: \(error.localizedDescription)" }
            }
        }
    }

    private func importFiles(_ urls: [URL]) {
        guard let context = inputContext, context == inventory.context else { return }
        library.busy = true
        Task {
            defer { library.busy = false; presentNextReview() }
            for url in urls {
                guard inventory.context == context else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let type = UTType(filenameExtension: url.pathExtension)
                let kind: CaptureItem.Kind = type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .pdf) == true ? .document : .image
                if let item = await library.add(file: url, kind: kind), inventory.context == context {
                    reviewQueue.enqueue([item])
                }
            }
        }
    }

    private func presentNextReview() {
        guard cameraDismissed, sheetDismissed, !pickingFiles, !library.busy, sheet == nil,
              let next = reviewQueue.next() else { return }
        present(.review(next))
    }
}

/// One recent scan: its thumbnail as a tile, the title, where its review stands, and when it was taken.
private struct RecentScanRow: View {
    let item: CaptureItem
    let url: URL
    let status: String
    @State private var thumbnail: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            Color(hex: Palette.tileHex[2])
                .frame(width: 56, height: 56)
                .overlay {
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: item.symbol).font(.system(size: 20)).foregroundStyle(Color.muted) }
                }
                .overlay {
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.ink.opacity(0.85)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.ink).lineLimit(1)
                ShelfPill(text: status, style: status == "Added to inventory" ? .line : status == "Needs review" ? .ink : .muted)
                Text(item.createdAt, format: .dateTime.month().day().hour().minute()).shelfNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .task(id: item.id) {
            if item.kind == .image { thumbnail = await Task.detached { MediaLibrary.thumbnail(url) }.value }
            else if item.kind == .video {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 160, height: 160)
                if let image = try? await generator.image(at: .zero) { thumbnail = UIImage(cgImage: image.image) }
            }
        }
    }
}

private struct MediaPreview: View {
    let item: CaptureItem
    let url: URL
    @ObservedObject var settings: SettingsStore
    @ObservedObject var inventory: InventoryStore
    @ObservedObject var library: MediaLibrary
    @StateObject private var caption = CaptionController()
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loaded = false
    @State private var confirmDismiss = false
    @State private var reviewingInventory = false
    var body: some View {
        NavigationStack {
            ShelfPage(bottomVisible: item.kind != .document) {
                ShelfHero(title: item.title, size: 28,
                          subtitle: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                Group {
                    if item.kind == .video { VideoPlayer(player: player) }
                    else if item.kind == .document { PDFPreview(url: url) }
                    else if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 420) }
                    else if loaded { ShelfEmpty(symbol: "photo", title: "Cannot preview image", message: "You can still share the original file.").padding(Metrics.space2) }
                    else { ProgressView() }
                }
                .frame(maxWidth: .infinity)
                .frame(height: item.kind == .document ? 550 : item.kind == .image && image != nil ? nil : 300)
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line))
                if item.kind != .document {
                    CaptionPanel(item: item, url: url, settings: settings, library: library, controller: caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous).strokeBorder(Color.line))
                }
            } bottom: {
                Button { reviewingInventory = true } label: {
                    Label("Identify items and add store", systemImage: "viewfinder")
                }
                .buttonStyle(.dibs)
                .disabled(caption.busy)
                .accessibilityIdentifier("capture.recognizeInventory")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if caption.hasEdits || caption.busy { confirmDismiss = true }
                        else { dismiss() }
                    }
                }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
            }
            .sheet(isPresented: $reviewingInventory) {
                let current = library.items.first(where: { $0.id == item.id }) ?? item
                RecognitionView(item: current, url: url, settings: settings, store: inventory, library: library)
            }
            .interactiveDismissDisabled(caption.hasEdits || caption.busy)
            .confirmationDialog("Close this preview? Unsaved edits will be discarded and captioning will be cancelled.", isPresented: $confirmDismiss, titleVisibility: .visible) {
                Button("Close preview", role: .destructive) { caption.cancel(); dismiss() }
            }
            .task {
                let current = library.items.first(where: { $0.id == item.id }) ?? item
                caption.restore(current.caption)
                if item.kind == .video { player = AVPlayer(url: url) }
                else if item.kind == .image { image = await Task.detached { MediaLibrary.thumbnail(url, maxPixels: 2400) }.value; loaded = true }
            }
            .onDisappear { player?.pause(); player = nil; caption.cancel() }
        }
    }
}
private struct PDFPreview: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updateUIView(_ view: PDFView, context: Context) {}
}
