import SwiftUI
import AVKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

struct CaptureView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var inventory: InventoryStore
    @StateObject private var library = MediaLibrary()
    @State private var camera: CameraMode?
    @State private var pickingLibrary = false
    @State private var pickingFiles = false
    @State private var preview: CaptureItem?
    @State private var deleting: CaptureItem?
    @State private var requestingPermission = false
    @State private var needsSettings = false
    @State private var cameraDismissed = true
    @State private var pendingReview: CaptureReview?
    @State private var captureReview: CaptureReview?
    private struct CaptureReview: Identifiable {
        let item: CaptureItem
        let controller: RecognitionController
        var id: UUID { item.id }
    }
    enum CameraMode: String, Identifiable { case photo, video; var id: String { rawValue } }
    var body: some View {
        ShelfPage {
            ShelfHero(title: "Scan what you have",
                      subtitle: "Take a photo or record a video of your shelves, and Dibs finds the items for your pantry.")
            sources
            Text("New camera captures go to your selected inventory model to identify items. Enter the purchase store while recognition runs.")
                .shelfNote()
                .fixedSize(horizontal: false, vertical: true)
            if library.busy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Saving media…").font(.system(size: 14)).foregroundStyle(Color.muted)
                }
                .accessibilityElement(children: .combine)
            }
            media
        } bottom: {
            HStack(spacing: 10) {
                captureButton("Video", icon: "video", mode: .video, kind: .secondary)
                captureButton("Photo", icon: "camera", mode: .photo, kind: .ink)
            }
            .disabled(library.busy || requestingPermission)
        }
        .task { await library.load() }
        .fullScreenCover(item: $camera, onDismiss: {
            cameraDismissed = true
            presentCaptureReview()
        }) { mode in
            CameraPicker(video: mode == .video) { result in
                camera = nil
                switch result {
                case .success(let media): if let (url, kind) = media { saveTemporary(url, kind: kind) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }.ignoresSafeArea()
        }

        .sheet(isPresented: $pickingLibrary) {
            LibraryPicker { results in
                pickingLibrary = false
                guard !results.isEmpty else { return }
                library.busy = true
                Task {
                    defer { library.busy = false }
                    for result in results {
                        do {
                            let (url, kind) = try await LibraryPicker.copyFile(from: result)
                            await library.add(file: url, kind: kind)
                            try? FileManager.default.removeItem(at: url)
                        } catch { library.error = "Could not import a selected item: \(error.localizedDescription)" }
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.image, .movie, .pdf], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                library.busy = true
                Task {
                    defer { library.busy = false }
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let type = UTType(filenameExtension: url.pathExtension)
                        let kind: CaptureItem.Kind = type?.conforms(to: .movie) == true ? .video : type?.conforms(to: .pdf) == true ? .document : .image
                        await library.add(file: url, kind: kind)
                    }
                }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
        .sheet(item: $captureReview) { review in
            RecognitionView(item: review.item, url: library.url(for: review.item), settings: settings,
                            store: inventory, library: library, controller: review.controller)
        }
        .sheet(item: $preview) { item in
            MediaPreview(item: item, url: library.url(for: item), settings: settings, inventory: inventory, library: library)
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
    private func captureButton(_ title: String, icon: String, mode: CameraMode, kind: DibsButtonStyle.Kind) -> some View {
        Button { Task { await openCamera(mode) } } label: { Label(title, systemImage: icon) }
            .buttonStyle(.dibs(kind))
            .accessibilityIdentifier("capture.\(mode.rawValue)")
    }

    /// Photo Library and Files: bring in what is already on the phone.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfSectionTitle("Import from your phone")
            VStack(spacing: 0) {
                Button { pickingLibrary = true } label: {
                    DibsLinkRow(title: "Photo Library", detail: "Pick photos or videos you already have", symbol: "photo.on.rectangle", tint: 0xD8E2FA)
                }
                .buttonStyle(.plain)
                Hairline()
                Button { pickingFiles = true } label: {
                    DibsLinkRow(title: "Files", detail: "Import images, videos or PDFs", symbol: "folder", tint: 0xF2E3B5)
                }
                .buttonStyle(.plain)
            }
            .dibsCard()
            .disabled(library.busy || requestingPermission)
        }
    }

    private var media: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ShelfSectionTitle("Your media")
                Text("\(library.items.count)").font(.display(17)).foregroundStyle(Color.ink).monospacedDigit()
            }
            if library.items.isEmpty {
                ShelfEmpty(symbol: "photo.stack", title: "No captures yet",
                           message: "Use the camera or import existing photos and videos to get started.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                    ForEach(library.items) { item in
                        Button { preview = item } label: { MediaTile(item: item, url: library.url(for: item)) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                ShareLink(item: library.url(for: item)) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                            }
                    }
                }
            }
        }
    }
    private func openCamera(_ mode: CameraMode) async {
        requestingPermission = true; needsSettings = false
        defer { requestingPermission = false }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            library.error = "This device does not support camera capture. Use Photo Library or Files, or try on a physical iPhone."
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            needsSettings = true; library.error = "Allow camera access in Settings to take photos or record videos."; return
        }
        if mode == .video, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            needsSettings = true; library.error = "Allow microphone access in Settings to record videos with sound."; return
        }
        cameraDismissed = false
        camera = mode
    }
    private func saveTemporary(_ url: URL, kind: CaptureItem.Kind) {
        library.busy = true
        Task {
            defer { library.busy = false; try? FileManager.default.removeItem(at: url) }
            guard let item = await library.add(file: url, kind: kind) else { return }
            let controller = RecognitionController()
            controller.generateIfNeeded(item: item, file: library.url(for: item), settings: settings, store: inventory)
            pendingReview = CaptureReview(item: item, controller: controller)
            presentCaptureReview()
        }
    }
    private func presentCaptureReview() {
        // The file copy and camera dismissal can finish in either order.
        guard cameraDismissed, let pendingReview else { return }
        captureReview = pendingReview
        self.pendingReview = nil
    }
}

private struct MediaTile: View {
    let item: CaptureItem
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The photo goes in an overlay so a wide image can't stretch the cell past its column.
            Color(hex: Palette.tileHex[2])
                .frame(height: 120)
                .frame(maxWidth: .infinity)
                .overlay {
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Image(systemName: item.symbol).font(.system(size: 30)).foregroundStyle(Color.muted) }
                }
                .overlay {
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.ink.opacity(0.85)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusSmall, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.ink).lineLimit(1)
                Text(item.createdAt, format: .dateTime.month().day().hour().minute()).shelfNote()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .dibsCard(radius: 16, padding: 8)
        .task(id: item.id) {
            if item.kind == .image { thumbnail = await Task.detached { MediaLibrary.thumbnail(url) }.value }
            else if item.kind == .video {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 600, height: 600)
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
