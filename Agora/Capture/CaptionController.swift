import SwiftUI

@MainActor
final class CaptionController: ObservableObject {
    @Published var style: CaptionStyle = .short
    @Published var instruction = ""
    @Published var draft = ""
    @Published private(set) var generated: SavedCaption?
    @Published private(set) var partialText = ""
    @Published private(set) var busy = false
    @Published private(set) var cancelling = false
    @Published private(set) var progress: CaptionProgress = .preparing
    @Published private(set) var message: String?
    @Published private(set) var cleanupNotice: String?
    private var task: Task<Void, Never>?
    private var needsSave = false
    private var jobID = UUID()
    var hasEdits: Bool { generated != nil && (draft != generated?.text || needsSave) }

    func restore(_ caption: SavedCaption?) {
        guard !busy else { return }
        needsSave = false; generated = caption; draft = caption?.text ?? ""; style = caption?.style ?? .short
    }
    func generate(item: CaptureItem, file: URL, settings: SettingsStore, library: MediaLibrary) {
        guard !busy else { return }
        do {
            let model = GeminiProvider.normalizedModel(settings.model)
            let provider = GeminiCaptionService(key: try settings.apiKey(), model: model)
            start(item: item, file: file, model: model, provider: provider) { caption in
                try await library.saveCaption(caption, for: item.id)
            }
        } catch { message = error.localizedDescription }
    }
    func start(item: CaptureItem, file: URL, model: String, provider: CaptionGenerating,
               save: @escaping @MainActor (SavedCaption) async throws -> Void) {
        guard !busy else { return }
        let style = style, instruction = instruction
        let id = UUID(); jobID = id
        busy = true; cancelling = false; partialText = ""; message = nil; cleanupNotice = nil; progress = .preparing
        task = Task {
            await AppLog.$taskID.withValue(UUID().uuidString) {
                defer { busy = false; cancelling = false; task = nil }
                do {
                    let result = try await provider.caption(file: file, kind: item.kind, style: style, instruction: instruction,
                        progress: { [weak self] stage in
                            guard let self, self.jobID == id, self.busy else { return }
                            // Delayed upload callbacks must not overwrite later stages.
                            if case .uploading = stage {
                                switch self.progress { case .preparing, .uploading, .retrying: self.progress = stage; default: break }
                            } else { self.progress = stage }
                        }, text: { [weak self] value in if self?.jobID == id { self?.partialText = value } }, cleanupNotice: { [weak self] value in if self?.jobID == id { self?.cleanupNotice = value } })
                    try Task.checkCancellation()
                    let caption = SavedCaption(text: result, style: style, model: model, generatedAt: Date())
                    progress = .saving
                    // Once saving starts, finish the atomic local write; Cancel is disabled.
                    generated = caption; draft = caption.text; needsSave = true
                    try await save(caption)
                    needsSave = false; partialText = ""; message = "Caption saved."
                } catch {
                    partialText = ""
                    if Task.isCancelled || error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                        message = "Cancelled. Your previously saved caption is unchanged."
                    } else if let failure = error as? CaptionHTTPFailure {
                        message = GeminiProvider.responseError(failure.status).localizedDescription
                    } else if progress == .saving { message = "Caption generated, but saving failed. Use Save edits to retry. \(error.localizedDescription)" }
                    else { message = error.localizedDescription }
                    AppLog.failure(.caption, "job.failed", error: error)
                }
            }
        }
    }
    func cancel() {
        guard busy, progress != .saving else { return }
        cancelling = true
        task?.cancel()
    }
    func saveEdits(item: CaptureItem, library: MediaLibrary) async {
        guard !busy, var caption = generated else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 32_000 else { message = "Enter a caption of up to 32,000 bytes."; return }
        busy = true; progress = .saving
        defer { busy = false }
        caption.text = text; caption.editedAt = Date()
        do { try await library.saveCaption(caption, for: item.id); generated = caption; draft = text; needsSave = false; message = "Edits saved." }
        catch { message = "Could not save edits. Your draft is still here. \(error.localizedDescription)" }
    }
}
