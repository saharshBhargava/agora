import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct CaptureItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case image, video, document }
    let id: UUID
    let kind: Kind
    let filename: String
    let createdAt: Date
    var caption: SavedCaption? = nil
    var title: String {
        switch kind { case .image: return "Photo"; case .video: return "Video"; case .document: return "Document scan" }
    }
    var symbol: String {
        switch kind { case .image: return "photo"; case .video: return "video"; case .document: return "doc.viewfinder" }
    }
}

enum CaptureFailure: LocalizedError {
    case unsupported, tooLarge, missingFile
    var errorDescription: String? {
        switch self {
        case .unsupported: return "This file is not a supported image, video, or PDF."
        case .tooLarge: return "Choose a file smaller than 500 MB."
        case .missingFile: return "This file is no longer available."
        }
    }
}

actor MediaRepository {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    private var index: URL { directory.appendingPathComponent("library.json") }
    func load() throws -> [CaptureItem] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: index.path) else { return [] }
        return try JSONDecoder().decode([CaptureItem].self, from: Data(contentsOf: index))
    }
    private func persist(_ items: [CaptureItem]) throws {
        try JSONEncoder().encode(items).write(to: index, options: [.atomic, .completeFileProtection])
    }
    func add(file: URL, kind: CaptureItem.Kind) throws -> [CaptureItem] {
        var items = try load()
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 500 * 1024 * 1024 else { throw CaptureFailure.tooLarge }
        let ext = file.pathExtension.lowercased()
        guard let type = UTType(filenameExtension: ext),
              (kind == .image && type.conforms(to: .image)) || (kind == .video && type.conforms(to: .movie)) || (kind == .document && type.conforms(to: .pdf)) else { throw CaptureFailure.unsupported }
        let id = UUID()
        let item = CaptureItem(id: id, kind: kind, filename: "\(id.uuidString).\(ext)", createdAt: Date())
        let destination = directory.appendingPathComponent(item.filename)
        try FileManager.default.copyItem(at: file, to: destination)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            items.insert(item, at: 0)
            try persist(items)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return items
    }
    func saveCaption(_ caption: SavedCaption, for id: UUID) throws -> [CaptureItem] {
        var items = try load()
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw CaptureFailure.missingFile }
        items[index].caption = caption
        try persist(items)
        return items
    }
    func remove(_ item: CaptureItem) throws -> [CaptureItem] {
        let items = try load().filter { $0.id != item.id }
        try persist(items)
        let file = directory.appendingPathComponent(item.filename)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        return items
    }
}

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [CaptureItem] = []
    @Published var busy = false
    @Published var error: String?
    let directory: URL
    private let repository: MediaRepository
    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Agora/Media", isDirectory: true)
        repository = MediaRepository(directory: directory)
    }
    func load() async {
        do { items = try await repository.load() }
        catch { self.error = "Could not load your media: \(error.localizedDescription)" }
    }
    func url(for item: CaptureItem) -> URL { directory.appendingPathComponent(item.filename) }
    func add(file: URL, kind: CaptureItem.Kind) async {
        do { items = try await repository.add(file: file, kind: kind) }
        catch { self.error = error.localizedDescription }
    }
    func saveCaption(_ caption: SavedCaption, for id: UUID) async throws {
        items = try await repository.saveCaption(caption, for: id)
    }
    func remove(_ item: CaptureItem) async {
        do { items = try await repository.remove(item) }
        catch { self.error = error.localizedDescription }
    }
    nonisolated static func thumbnail(_ url: URL, maxPixels: Int = 600) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}
