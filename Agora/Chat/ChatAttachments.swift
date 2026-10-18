import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import Speech
import AVFoundation

struct ChatAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let mimeType: String
    let extractedText: String?
    var image: UIImage? { mimeType.hasPrefix("image/") ? UIImage(data: data) : nil }
    var modelContent: ModelContent {
        if mimeType.hasPrefix("image/") { return .image(data, mimeType: mimeType) }
        return .text("Attached file: \(name)\n\(extractedText ?? "")")
    }
    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 10_000_000 else { throw BrowserError("attachment_size", "Choose a file smaller than 10 MB.") }
        let data = try Data(contentsOf: url)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .image) { return try photo(data, name: url.lastPathComponent) }
        let text: String?
        if type.conforms(to: .pdf) { text = PDFDocument(data: data)?.string }
        else if type.conforms(to: .text) { text = String(data: data, encoding: .utf8) }
        else { throw BrowserError("attachment_type", "Choose an image, PDF, or UTF-8 text file.") }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BrowserError("attachment_unreadable", "This file has no readable text. For a scanned PDF, attach a photo of the page.")
        }
        guard text.utf8.count <= 120_000 else { throw BrowserError("attachment_size", "Choose a shorter document (up to 120 KB of text).") }
        return .init(name: url.lastPathComponent, data: data, mimeType: type.preferredMIMEType ?? "text/plain", extractedText: text)
    }
    static func photo(_ data: Data, name: String = "Photo.jpg") throws -> Self {
        guard data.count <= 20_000_000, let original = UIImage(data: data), original.size.width > 0 else {
            throw BrowserError("attachment_unreadable", "Choose a readable photo smaller than 20 MB.")
        }
        let scale = min(1, 1400 / max(original.size.width, original.size.height))
        let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
        guard let bytes = image.jpegData(compressionQuality: 0.75), bytes.count < 1_000_000 else {
            throw BrowserError("attachment_size", "This image is too large. Choose a smaller photo.")
        }
        return .init(name: name, data: bytes, mimeType: "image/jpeg", extractedText: nil)
    }
}

struct ChatAttachmentPreview: View {
    let attachment: ChatAttachment
    var body: some View {
        ScrollView {
            if let image = attachment.image { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(attachment.name) }
            else if attachment.mimeType == "application/pdf" { PDFPreview(data: attachment.data).frame(minHeight: 650) }
            else { Text(attachment.extractedText ?? "").font(.body.monospaced()).textSelection(.enabled).padding() }
        }.navigationTitle(attachment.name).navigationBarTitleDisplayMode(.inline)
    }
}
private struct PDFPreview: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

@MainActor
final class ChatDictation: ObservableObject {
    @Published private(set) var recording = false
    @Published var error: String?
    private let engine = AVAudioEngine()
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var installedTap = false
    private var generation = UUID()
    func start(update: @escaping (String) -> Void) async {
        stop(); let token = UUID(); generation = token
        let speech = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        let mic = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
        guard generation == token else { return }
        guard speech == .authorized, mic else { error = "Enable Microphone and Speech Recognition for Agora in iOS Settings to dictate."; return }
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else { error = "Dictation is unavailable. Try again when connected."; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers); try session.setActive(true)
            let request = SFSpeechAudioBufferRecognitionRequest(); self.request = request
            request.shouldReportPartialResults = true
            let input = engine.inputNode, format = engine.inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { throw BrowserError("microphone_unavailable", "The microphone is unavailable.") }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }; installedTap = true
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    if let result { update(result.bestTranscription.formattedString) }
                    if failure != nil || result?.isFinal == true {
                        self.stop()
                        if let failure { self.error = failure.localizedDescription }
                    }
                }
            }
            engine.prepare(); try engine.start(); recording = true
        } catch { stop(); self.error = error.localizedDescription }
    }
    func stop() {
        generation = UUID(); engine.stop()
        if installedTap { engine.inputNode.removeTap(onBus: 0); installedTap = false }
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil; recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
