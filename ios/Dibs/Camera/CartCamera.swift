@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Vision

/// A crop of a newly settled item, ready to post.
struct CartTrigger: Sendable {
    /// Vision-normalized (bottom-left origin) box in the frame.
    var box: CGRect
    var jpeg: Data
    var cropSize: CGSize
    var frameSize: CGSize
}

/// The shopper's rear camera: AVCaptureSession with a preview, a video output processed on a serial
/// queue, and a photo output for receipts. Frames are rotated to portrait.
///
/// On the video queue: every `FrameEncoder.streamInterval` while `streaming`, a 640 px JPEG goes to
/// `onStreamFrame`; every third frame while `watching`, Vision (saliency + hand pose) and the scene
/// thumbnail feed `CartWatcher`, and a trigger crops the same full-resolution frame to `onTrigger`.
final class CartCamera: NSObject, @unchecked Sendable {
    enum Permission: Sendable { case authorized, denied, unavailable }

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "dev.dibs.camera.session")
    private let videoQueue = DispatchQueue(label: "dev.dibs.camera.video", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let encoder = FrameEncoder()

    /// Called on the video queue.
    var onStreamFrame: (@Sendable (Data, CGSize) -> Void)?
    var onTrigger: (@Sendable (CartTrigger) -> Void)?

    private let lock = NSLock()
    private var _streaming = false
    private var _watching = false
    /// Gates the 2 fps livestream (only while the run is open or in last call).
    var streaming: Bool {
        get { lock.withLock { _streaming } }
        set { lock.withLock { _streaming = newValue } }
    }
    /// Gates the on-device trigger.
    var watching: Bool {
        get { lock.withLock { _watching } }
        set { lock.withLock { _watching = newValue } }
    }

    // Video-queue state.
    private var configured = false
    private var frameIndex = 0
    private var lastStreamAt: TimeInterval = -.infinity
    private var framesSent = 0
    private var previousThumb: [UInt8]?
    private var watcher = CartWatcher()
    private var lastDecisionKind = ""
    private var loggedFrameSize = false
    private let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
    private let hands: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private var photoDelegates: [Int64: PhotoDelegate] = [:]

    init(triggerOnInitialScene: Bool = true) {
        watcher = CartWatcher(triggerOnInitialScene: triggerOnInitialScene)
        super.init()
    }

    // MARK: permission and lifecycle

    static func requestPermission() async -> Permission {
        guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .authorized : .denied
        default: return .denied
        }
    }

    func start() {
        sessionQueue.async { [self] in
            if !configured { configure() }
            guard configured, !session.isRunning else { return }
            session.startRunning()
            DibsLog.event("camera started running=\(session.isRunning)")
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
            DibsLog.event("camera stopped")
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            DibsLog.event("camera unavailable: no rear camera input")
            return
        }
        session.addInput(input)
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        for output in [videoOutput, photoOutput] as [AVCaptureOutput] {
            if let c = output.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        }
        configured = true
        DibsLog.event("camera configured preset=\(session.sessionPreset.rawValue)")
    }

    // MARK: receipts

    /// Takes a full photo (portrait JPEG).
    func capturePhoto() async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            sessionQueue.async { [self] in
                let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                let id = settings.uniqueID
                let delegate = PhotoDelegate { [weak self] result in
                    if let camera = self {
                        camera.sessionQueue.async { camera.photoDelegates[id] = nil }
                    }
                    cont.resume(with: result)
                }
                photoDelegates[id] = delegate
                photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: frame processing (video queue)

    fileprivate func process(_ sampleBuffer: CMSampleBuffer) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if !loggedFrameSize {
            loggedFrameSize = true
            DibsLog.event("camera first frame \(Int(size.width))x\(Int(size.height))")
        }
        frameIndex += 1

        if streaming, t - lastStreamAt >= FrameEncoder.streamInterval - 0.01 {
            lastStreamAt = t
            if let jpeg = encoder.streamJPEG(buffer) {
                framesSent += 1
                if framesSent % 10 == 0 { DibsLog.event("frames sent \(framesSent) (\(jpeg.count / 1024) KB)") }
                onStreamFrame?(jpeg, FrameEncoder.streamSize(for: size))
            }
        }

        guard watching, frameIndex % 3 == 0 else { return }
        let thumb = encoder.thumbnail(buffer)
        let change = SceneDiff.changeFraction(previous: previousThumb, current: thumb)
        previousThumb = thumb

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([saliency, hands]) } catch {
            DibsLog.event("vision failed: \(error.localizedDescription)")
            return
        }
        let boxes = (saliency.results?.first?.salientObjects ?? [])
            .sorted { $0.confidence > $1.confidence }
            .map(\.boundingBox)
        let handPresent = (hands.results ?? []).contains { $0.confidence > 0.3 }

        let decisions = watcher.observe(.init(time: t, boxes: boxes, handPresent: handPresent, changeFraction: change))
        for decision in decisions {
            logDecision(decision, change: change, boxes: boxes.count)
            guard case .trigger(let b) = decision else { continue }
            let rect = ScanGeometry.cropRect(for: b, imageSize: size)
            guard let crop = encoder.cropJPEG(buffer, rect: rect) else {
                DibsLog.event("crop failed rect=\(Self.fmt(rect))")
                continue
            }
            DibsLog.event("crop \(Int(crop.size.width))x\(Int(crop.size.height)) \(crop.data.count / 1024) KB from rect=\(Self.fmt(rect))")
            onTrigger?(CartTrigger(box: b, jpeg: crop.data, cropSize: crop.size, frameSize: size))
        }
    }

    /// Logs triggers, rebaselines and baselines always; other decisions only when the kind changes.
    private func logDecision(_ d: CartWatcher.Decision, change: Double, boxes: Int) {
        let kind: String
        switch d {
        case .trigger(let b): DibsLog.event("watcher trigger box=\(Self.fmt(b)) change=\(Self.pct(change))"); lastDecisionKind = "trigger"; return
        case .baselined(let b): DibsLog.event("watcher baselined box=\(Self.fmt(b))"); lastDecisionKind = "baselined"; return
        case .rebaseline: kind = "rebaseline change=\(Self.pct(change))"
        case .handPresent: kind = "hand present"
        case .empty: kind = "empty (salient boxes=\(boxes))"
        case .known: kind = "known"
        case .settling: kind = "settling"
        }
        let head = kind.components(separatedBy: " change=")[0].components(separatedBy: " (")[0]
        guard head != lastDecisionKind else { return }
        lastDecisionKind = head
        DibsLog.event("watcher \(kind)")
    }

    static func fmt(_ r: CGRect) -> String {
        String(format: "(%.3f,%.3f %.3fx%.3f)", r.minX, r.minY, r.width, r.height)
    }

    private static func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }
}

extension CartCamera: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        process(sampleBuffer)
    }
}

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let done: (Result<Data, Error>) -> Void
    init(done: @escaping (Result<Data, Error>) -> Void) { self.done = done }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { done(.failure(error)); return }
        guard let data = photo.fileDataRepresentation() else {
            done(.failure(CocoaError(.fileReadCorruptFile)))
            return
        }
        done(.success(data))
    }
}
