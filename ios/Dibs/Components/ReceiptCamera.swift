@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The receipt photo the server reads: JPEG, at most 2400 px on the long side, quality 0.85.
enum ReceiptImage {
    static let maxSide: CGFloat = 2400
    static let quality: CGFloat = 0.85

    /// `size` scaled down (never up) so the long side is at most `maxSide`, in whole pixels.
    static func targetSize(for size: CGSize, maxSide: CGFloat = maxSide) -> CGSize {
        let long = max(size.width, size.height)
        guard long > maxSide, long > 0 else { return CGSize(width: size.width.rounded(), height: size.height.rounded()) }
        let k = maxSide / long
        return CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
    }

    /// The server takes request bodies up to 8 MB; the base64 stays under 6 MB to leave headroom.
    static let maxBase64Bytes = 6_000_000

    /// Base64 JPEG (no data: prefix), upright, at most 2400 px at quality 0.85. A busy photo over the
    /// payload cap steps down in quality, then size, until it fits.
    static func jpegBase64(_ image: UIImage, maxBytes: Int = maxBase64Bytes) -> String? {
        let steps: [(side: CGFloat, quality: CGFloat)] = [(maxSide, quality), (maxSide, 0.7), (2000, 0.7), (1600, 0.6), (1280, 0.6), (1024, 0.5)]
        var last: String?
        for step in steps {
            guard let b64 = encode(image, side: step.side, quality: step.quality) else { return nil }
            if b64.utf8.count <= maxBytes { return b64 }
            last = b64
        }
        return last
    }

    private static func encode(_ image: UIImage, side: CGFloat, quality: CGFloat) -> String? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let target = targetSize(for: pixels, maxSide: side)
        guard target.width >= 1, target.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: quality)?.base64EncodedString()
    }

    static func jpegBase64(data: Data) -> String? {
        UIImage(data: data).flatMap { jpegBase64($0) }
    }
}

/// The rear camera for one receipt photo: a preview session and a still capture.
final class ReceiptCamera: NSObject, @unchecked Sendable {
    enum Status: Sendable { case starting, running, denied, unavailable }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "dev.dibs.receipt.camera")
    private let output = AVCapturePhotoOutput()
    // Queue state.
    private var configured = false
    private var delegates: [Int64: ReceiptPhotoDelegate] = [:]

    /// Asks for the camera if needed, then starts the preview.
    func start() async -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return .denied }
        default: return .denied
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<Status, Never>) in
            queue.async { [self] in
                guard configure() else { return cont.resume(returning: .unavailable) }
                if !session.isRunning { session.startRunning() }
                cont.resume(returning: .running)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Takes a full-resolution portrait JPEG.
    func capture() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            queue.async { [self] in
                guard configured, session.isRunning else {
                    return cont.resume(throwing: ReceiptCameraError.notRunning)
                }
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                let id = settings.uniqueID
                let delegate = ReceiptPhotoDelegate { [weak self] result in
                    if let camera = self { camera.queue.async { camera.delegates[id] = nil } }
                    cont.resume(with: result)
                }
                delegates[id] = delegate
                output.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        session.commitConfiguration()
        if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        configured = true
        return true
    }
}

enum ReceiptCameraError: LocalizedError {
    case notRunning, noPhoto
    var errorDescription: String? {
        switch self {
        case .notRunning: return "Point the camera at the receipt first"
        case .noPhoto: return "Could not read that photo"
        }
    }
}

private final class ReceiptPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let done: @Sendable (Result<Data, Error>) -> Void
    init(done: @escaping @Sendable (Result<Data, Error>) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { return done(.failure(error)) }
        guard let data = photo.fileDataRepresentation() else { return done(.failure(ReceiptCameraError.noPhoto)) }
        done(.success(data))
    }
}

/// The live preview, filling its frame.
struct ReceiptCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Portrait-only app: keep the preview upright once the session connects.
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }
    }
}
