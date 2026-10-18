import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import ImageIO

/// JPEG encoding for the shopper camera: the 2 fps livestream frame, the trigger crop, and the
/// 32x32 gray thumbnail for scene change. Thread-safe (CIContext is), used on the video queue.
final class FrameEncoder: @unchecked Sendable {
    static let streamInterval: TimeInterval = 0.5
    static let streamWidth: CGFloat = 640
    static let streamQuality: CGFloat = 0.6
    static let cropQuality: CGFloat = 0.8
    static let cropMaxSide: CGFloat = 1024

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Size of a streamed frame for a source frame of `size` (640 wide, aspect kept).
    static func streamSize(for size: CGSize) -> CGSize {
        guard size.width > 0 else { return .zero }
        return CGSize(width: streamWidth, height: (size.height * streamWidth / size.width).rounded())
    }

    /// Scale factor so the long side is at most `maxSide` (never upscales).
    static func cropScale(for size: CGSize, maxSide: CGFloat = cropMaxSide) -> CGFloat {
        let long = max(size.width, size.height)
        return long > maxSide ? maxSide / long : 1
    }

    /// 640 px wide JPEG, quality 0.6.
    func streamJPEG(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = Self.streamWidth / image.extent.width
        return jpeg(scaled(image, by: scale), quality: Self.streamQuality)
    }

    /// Crops `rect` (top-left-origin pixels, from `ScanGeometry.cropRect`), long side <= 1024, JPEG 0.8.
    func cropJPEG(_ buffer: CVPixelBuffer, rect: CGRect) -> (data: Data, size: CGSize)? {
        let image = CIImage(cvPixelBuffer: buffer)
        let h = image.extent.height
        let ciRect = CGRect(x: rect.minX, y: h - rect.maxY, width: rect.width, height: rect.height)
        let cropped = image.cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))
        let scale = Self.cropScale(for: rect.size)
        let out = scaled(cropped, by: scale)
        guard let data = jpeg(out, quality: Self.cropQuality) else { return nil }
        return (data, CGSize(width: out.extent.width.rounded(), height: out.extent.height.rounded()))
    }

    /// 32x32 grayscale thumbnail bytes (Lanczos-averaged, so sensor noise mostly cancels out).
    func thumbnail(_ buffer: CVPixelBuffer) -> [UInt8] {
        let side = SceneDiff.side
        let image = CIImage(cvPixelBuffer: buffer)
        let gray = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = gray
        f.scale = Float(CGFloat(side) / image.extent.height)
        f.aspectRatio = Float(image.extent.height / image.extent.width)
        let out = f.outputImage ?? gray
        let small = out
            .transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
            .clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var bytes = [UInt8](repeating: 0, count: side * side)
        bytes.withUnsafeMutableBytes { raw in
            context.render(small, toBitmap: raw.baseAddress!, rowBytes: side, bounds: small.extent,
                           format: .L8, colorSpace: nil)
        }
        return bytes
    }

    private func scaled(_ image: CIImage, by scale: CGFloat) -> CIImage {
        guard scale != 1 else { return image }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(scale)
        f.aspectRatio = 1
        return f.outputImage ?? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }

    private func jpeg(_ image: CIImage, quality: CGFloat) -> Data? {
        context.jpegRepresentation(of: image, colorSpace: colorSpace,
                                   options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality])
    }
}
