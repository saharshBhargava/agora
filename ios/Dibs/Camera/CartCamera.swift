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
    /// The watcher's item for this crop; pass back through `attach(chipId:toItem:)` or `forget(item:)`.
    var itemId: Int
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
    /// An item left the cart: remove its chip.
    var onRemoved: (@Sendable (_ chipId: String) -> Void)?
    /// A removed item came back (it was moved): undo the removal.
    var onRestored: (@Sendable (_ chipId: String) -> Void)?

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
    private var watcher = CartWatcher()
    private var lastDecisionKind = ""
    private var loggedFrameSize = false
    private let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
    private let hands: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    /// Feature prints of item crops, by watcher item id (video queue).
    private var prints: [Int: VNFeaturePrintObservation] = [:]
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

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([saliency, hands]) } catch {
            DibsLog.event("vision failed: \(error.localizedDescription)")
            return
        }
        let boxes = (saliency.results?.first?.salientObjects ?? [])
            .sorted { $0.confidence > $1.confidence }
            .map(\.boundingBox)
        let handPresent = (hands.results ?? []).contains { $0.confidence > 0.3 }

        // Feature-print distance between a candidate box in this frame and a remembered item.
        var candidatePrints: [String: VNFeaturePrintObservation] = [:]
        let distance: (CGRect, Int) -> Double? = { [self] box, itemId in
            guard let itemPrint = prints[itemId] else { return nil }
            let key = Self.fmt(box)
            let candidate = candidatePrints[key] ?? Self.featurePrint(buffer, box: box)
            candidatePrints[key] = candidate
            guard let candidate else { return nil }
            var d: Float = 0
            do { try candidate.computeDistance(&d, to: itemPrint) } catch { return nil }
            return Double(d)
        }
        let decisions = watcher.observe(.init(time: t, boxes: boxes, handPresent: handPresent, thumb: thumb), distance: distance)
        for decision in decisions {
            logDecision(decision, boxes: boxes.count)
            switch decision {
            case .trigger(let b):
                guard let itemId = watcher.itemId(for: b) else { continue }
                prints[itemId] = Self.featurePrint(buffer, box: b)
                let rect = ScanGeometry.cropRect(for: b, imageSize: size)
                guard let crop = encoder.cropJPEG(buffer, rect: rect) else {
                    DibsLog.event("crop failed rect=\(Self.fmt(rect))")
                    watcher.forget(item: itemId)
                    continue
                }
                DibsLog.event("crop \(Int(crop.size.width))x\(Int(crop.size.height)) \(crop.data.count / 1024) KB from rect=\(Self.fmt(rect)) item=\(itemId)")
                onTrigger?(CartTrigger(box: b, jpeg: crop.data, cropSize: crop.size, frameSize: size, itemId: itemId))
            case .moved(let itemId, _, let b):
                if let p = Self.featurePrint(buffer, box: b) { prints[itemId] = p }
            case .removed(let chipId, _):
                onRemoved?(chipId)
            case .restored(let chipId, _):
                onRestored?(chipId)
            default:
                break
            }
        }
        // Forget prints of items the watcher no longer remembers.
        let live = Set(watcher.items.map(\.id))
        for id in prints.keys where !live.contains(id) { prints[id] = nil }
    }

    /// Links a watcher item to the chip its crop became (from any thread).
    func attach(chipId: String, toItem itemId: Int) {
        videoQueue.async { [self] in watcher.attach(chipId: chipId, toItem: itemId) }
    }

    /// Drops a watcher item whose add failed (from any thread).
    func forget(item itemId: Int) {
        videoQueue.async { [self] in
            watcher.forget(item: itemId)
            prints[itemId] = nil
        }
    }

    /// Vision feature print of a box (Vision-normalized) in the frame.
    private static func featurePrint(_ buffer: CVPixelBuffer, box: CGRect) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.regionOfInterest = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch {
            DibsLog.event("feature print failed: \(error.localizedDescription)")
            return nil
        }
        return request.results?.first
    }

    /// Logs triggers, unchanged boxes, baselines, shifts and reference events always; status
    /// decisions only when the kind changes.
    private func logDecision(_ d: CartWatcher.Decision, boxes: Int) {
        func gate() -> String {
            guard let g = watcher.lastGate else { return "initial" }
            return String(format: "mean=%.1f changed=%.0f%%", g.mean, g.fraction * 100)
        }
        let kind: String
        switch d {
        case .trigger(let b):
            DibsLog.event("watcher trigger box=\(Self.fmt(b)) \(watcher.watching ? gate() : "initial")"); lastDecisionKind = "trigger"; return
        case .unchanged(let b):
            DibsLog.event("watcher unchanged box=\(Self.fmt(b)) \(gate())"); lastDecisionKind = "unchanged"; return
        case .baselined(let b):
            DibsLog.event("watcher baselined box=\(Self.fmt(b))"); lastDecisionKind = "baselined"; return
        case .cameraShift(let dx, let dy):
            DibsLog.event("watcher camera shift dx=\(dx) dy=\(dy)"); lastDecisionKind = "shift"; return
        case .referenceTaken:
            DibsLog.event("watcher reference taken"); lastDecisionKind = "reference"; return
        case .removed(let chipId, let item):
            DibsLog.event("watcher removed chip=\(chipId) item=\(item)"); lastDecisionKind = "removed"; return
        case .restored(let chipId, let item):
            DibsLog.event("watcher restored chip=\(chipId) item=\(item)"); lastDecisionKind = "restored"; return
        case .moved(let item, let chipId, let b):
            DibsLog.event("watcher moved chip=\(chipId ?? "pending") item=\(item) to box=\(Self.fmt(b))"); lastDecisionKind = "moved"; return
        case .match(let d, let item, let chipId):
            DibsLog.event(String(format: "watcher match d=%.3f vs chip=%@ item=%d", d, chipId ?? "pending", item)); return
        case .rebaseline: kind = "rebaseline"
        case .motion: kind = "motion"
        case .handPresent: kind = "hand present"
        case .empty: kind = "empty"
        case .known: kind = "known"
        case .settling: kind = "settling"
        }
        guard kind != lastDecisionKind else { return }
        lastDecisionKind = kind
        DibsLog.event("watcher \(kind)\(kind == "empty" ? " (salient boxes=\(boxes))" : "")")
    }

    static func fmt(_ r: CGRect) -> String {
        String(format: "(%.3f,%.3f %.3fx%.3f)", r.minX, r.minY, r.width, r.height)
    }

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
