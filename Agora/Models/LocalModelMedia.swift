import Foundation
import AVFoundation
import ImageIO
import UIKit

/// Local vision servers receive bounded JPEGs, never original videos or audio tracks.
@MainActor
enum LocalModelMedia {
    static let maximumInputBytes = 25_000_000
    static let maximumImageBytes = 900_000
    static let maximumFrames = 8

    static func image(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1536,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw failure() }
        return try jpeg(thumbnail)
    }

    static func parts(url: URL, kind: CaptureItem.Kind) async throws -> [[String: Any]] {
        try Task.checkCancellation()
        guard url.isFileURL else { throw failure() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        switch kind {
        case .image:
            guard size > 0, size <= maximumInputBytes else { throw failure() }
            return [imagePart(try image(Data(contentsOf: url, options: .mappedIfSafe)))]
        case .video:
            guard size > 0, size <= 500_000_000 else { throw failure() }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, duration <= 180 else {
                throw CaptionFailure(code: "local_media_limit", message: "Choose a video up to three minutes long for frame sampling.")
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1536, height: 1536)
            let count = min(maximumFrames, max(1, Int(ceil(duration / 2))))
            return try await withTaskCancellationHandler {
                var parts: [[String: Any]] = [["type": "text", "text": "Video sampled as \(count) timestamped frames over \(String(format: "%.2f", duration)) seconds. Audio is not included."]]
                for index in 0..<count {
                    try Task.checkCancellation()
                    let time = duration * (Double(index) + 0.5) / Double(count)
                    let result = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                    try Task.checkCancellation()
                    parts.append(["type": "text", "text": "Frame at \(String(format: "%.2f", result.actualTime.seconds)) seconds:"])
                    parts.append(imagePart(try jpeg(result.image)))
                }
                return parts
            } onCancel: { generator.cancelAllCGImageGeneration() }
        case .document: throw failure()
        }
    }

    static func imagePart(_ data: Data) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"]]
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let value = UIImage(cgImage: image)
        for quality in [0.8, 0.6, 0.4, 0.2] {
            if let data = value.jpegData(compressionQuality: quality), data.count <= maximumImageBytes { return data }
        }
        throw failure()
    }
    private static func failure() -> CaptionFailure {
        CaptionFailure(code: "local_media_invalid", message: "This media could not be prepared for the model. Choose a smaller photo or video.")
    }
}
