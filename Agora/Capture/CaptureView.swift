import SwiftUI
import AVKit
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

struct CaptureView: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var library = MediaLibrary()
    @State private var camera: CameraMode?
    @State private var pickingLibrary = false
    @State private var pickingFiles = false
    @State private var preview: CaptureItem?
    @State private var deleting: CaptureItem?
    @State private var requestingPermission = false
    @State private var needsSettings = false
    enum CameraMode: String, Identifiable { case photo, video; var id: String { rawValue } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Capture something new").font(.title2.bold())
                        Text("Take a photo or record a video.").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        captureButton("Photo", icon: "camera", mode: .photo)
                        captureButton("Video", icon: "video", mode: .video)
                    }.disabled(library.busy || requestingPermission)
                    HStack {
                        Button { pickingLibrary = true } label: { Label("Photo Library", systemImage: "photo.on.rectangle") }
                            .buttonStyle(.borderedProminent)
                        Button { pickingFiles = true } label: { Label("Files", systemImage: "folder") }
                            .buttonStyle(.bordered)
                    }.disabled(library.busy || requestingPermission)
                    Text("Photos and videos are saved in Agora on this device. Nothing is sent to Gemini automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if library.busy { ProgressView("Saving media…").frame(maxWidth: .infinity) }
                    HStack {
                        Text("Your media").font(.title2.bold())
                        Spacer()
                        Text("\(library.items.count)").foregroundStyle(.secondary)
                    }
                    if library.items.isEmpty {
                        ContentUnavailableView("No captures yet", systemImage: "photo.stack", description: Text("Use the camera or import existing photos and videos to get started."))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 14)], spacing: 14) {
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
                }.padding()
            }
            .navigationTitle("Capture")
            .task { await library.load() }
            .fullScreenCover(item: $camera) { mode in
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
            .sheet(item: $preview) { item in
                MediaPreview(item: item, url: library.url(for: item), settings: settings, library: library)
            }
            .alert("Capture", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                if needsSettings {
                    Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }
                Button("OK", role: .cancel) { library.error = nil; needsSettings = false }
            } message: { Text(library.error ?? "") }
            .confirmationDialog("Delete this item from Agora?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let item = deleting { Task { await library.remove(item) } }
                    deleting = nil
                }
            }
        }
    }
    private func captureButton(_ title: String, icon: String, mode: CameraMode) -> some View {
        Button { Task { await openCamera(mode) } } label: {
            VStack(spacing: 10) { Image(systemName: icon).font(.title); Text(title).font(.headline) }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        }.accessibilityIdentifier("capture.\(mode.rawValue)")
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
        camera = mode
    }
    private func saveTemporary(_ url: URL, kind: CaptureItem.Kind) {
        library.busy = true
        Task {
            defer { library.busy = false; try? FileManager.default.removeItem(at: url) }
            await library.add(file: url, kind: kind)
        }
    }
}

private struct MediaTile: View {
    let item: CaptureItem
    let url: URL
    @State private var thumbnail: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.secondary.opacity(0.08)
                if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                else { Image(systemName: item.symbol).font(.largeTitle).foregroundStyle(.teal) }
                if item.kind == .video { Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white).shadow(radius: 3) }
            }.frame(height: 140).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.headline)
            Text(item.createdAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
        }
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
    @ObservedObject var library: MediaLibrary
    @StateObject private var caption = CaptionController()
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var loaded = false
    @State private var confirmDismiss = false
    @State private var purchasedFrom = ""
    @State private var savedStore = ""
    @State private var savingStore = false
    @State private var storeMessage: String?
    private var storeHasEdits: Bool { purchasedFrom.trimmingCharacters(in: .whitespacesAndNewlines) != savedStore }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Group {
                        if item.kind == .video { VideoPlayer(player: player) }
                        else if item.kind == .document { PDFPreview(url: url) }
                        else if let image { Image(uiImage: image).resizable().scaledToFit() }
                        else if loaded { ContentUnavailableView("Cannot preview image", systemImage: "photo", description: Text("You can still share the original file.")) }
                        else { ProgressView() }
                    }.frame(maxWidth: .infinity).frame(height: item.kind == .document ? 550 : 300)
                    if item.kind != .document {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Purchased from").font(.headline)
                            TextField("Store or website, e.g. Costco or Amazon", text: $purchasedFrom)
                                .textFieldStyle(.roundedBorder)
                                .disabled(savingStore)
                                .accessibilityIdentifier("capture.purchasedFrom")
                            Text("Optional. Enter the store for the items in this photo or video.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button(savingStore ? "Saving…" : "Save store") {
                                savingStore = true
                                Task {
                                    defer { savingStore = false }
                                    do {
                                        try await library.savePurchasedFrom(purchasedFrom, for: item.id)
                                        savedStore = purchasedFrom.trimmingCharacters(in: .whitespacesAndNewlines)
                                        purchasedFrom = savedStore
                                        storeMessage = savedStore.isEmpty ? "Store cleared." : "Store saved."
                                    } catch { storeMessage = "Could not save store: \(error.localizedDescription)" }
                                }
                            }.disabled(savingStore || !storeHasEdits)
                            if let storeMessage { Text(storeMessage).font(.footnote).foregroundStyle(.secondary) }
                        }.padding()
                        CaptionPanel(item: item, url: url, settings: settings, library: library, controller: caption)
                    }
                }
            }
            .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        if caption.hasEdits || caption.busy || storeHasEdits { confirmDismiss = true }
                        else { dismiss() }
                    }.disabled(savingStore)
                }
                ToolbarItem(placement: .primaryAction) { ShareLink(item: url) { Image(systemName: "square.and.arrow.up") } }
            }
            .interactiveDismissDisabled(caption.hasEdits || caption.busy || storeHasEdits || savingStore)
            .confirmationDialog("Close this preview? Unsaved edits will be discarded and captioning will be cancelled.", isPresented: $confirmDismiss, titleVisibility: .visible) {
                Button("Close preview", role: .destructive) { caption.cancel(); dismiss() }
            }
            .task {
                let current = library.items.first(where: { $0.id == item.id }) ?? item
                caption.restore(current.caption)
                purchasedFrom = current.purchasedFrom ?? ""
                savedStore = purchasedFrom
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
