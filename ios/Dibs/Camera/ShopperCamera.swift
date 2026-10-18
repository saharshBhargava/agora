import Foundation
import Observation
import UIKit

/// Main-actor side of the shopper camera: permission, gating the stream on run state, posting
/// trigger crops with `DibsAPI.addChip`, and the tap-to-identify fallback.
@MainActor
@Observable
final class ShopperCamera {
    enum Status: Equatable { case starting, running, denied, unavailable }

    private(set) var status: Status = .starting
    /// Size of the frames being streamed (640 wide), for mapping the server's region and taps.
    private(set) var streamSize: CGSize?
    /// Normalized top-left boxes of crops being named right now (local outline while addChip runs).
    private(set) var pending: [UUID: CGRect] = [:]
    private(set) var lastAddError: String?

    @ObservationIgnored let camera: CartCamera
    @ObservationIgnored private let api: DibsAPI
    @ObservationIgnored private let store: RunStore
    @ObservationIgnored private let runId: String
    @ObservationIgnored private var cropCount = 0

    init(store: RunStore, api: DibsAPI, runId: String, triggerOnInitialScene: Bool = true) {
        self.store = store
        self.api = api
        self.runId = runId
        self.camera = CartCamera(triggerOnInitialScene: triggerOnInitialScene)
        camera.onStreamFrame = { [weak self] jpeg, size in
            Task { @MainActor [weak self] in self?.send(jpeg, size: size) }
        }
        camera.onTrigger = { [weak self] trigger in
            Task { @MainActor [weak self] in self?.post(trigger) }
        }
        camera.onRemoved = { [weak self] chipId in
            Task { @MainActor [weak self] in self?.removed(chipId) }
        }
        camera.onRestored = { [weak self] chipId in
            Task { @MainActor [weak self] in self?.restored(chipId) }
        }
    }

    /// Asks for camera access, then starts the session.
    func start() async {
        switch await CartCamera.requestPermission() {
        case .authorized:
            DibsLog.event("camera permission authorized")
            status = .running
            camera.start()
        case .denied:
            DibsLog.event("camera permission denied")
            status = .denied
        case .unavailable:
            DibsLog.event("camera unavailable")
            status = .unavailable
        }
    }

    func stop() { camera.stop() }

    /// Streams and watches only while the run is open or in last call.
    func runStateChanged(_ state: RunState?) {
        let live = state == .open || state == .lastCall
        guard camera.streaming != live || camera.watching != live else { return }
        camera.streaming = live
        camera.watching = live
        DibsLog.event("camera stream \(live ? "on" : "off") run state=\(state?.rawValue ?? "none")")
    }

    /// Tap on the preview: ask the server to identify what is at that point of the last frame.
    func tap(at point: CGPoint, in container: CGSize) {
        guard let streamSize else { return }
        let p = ScanGeometry.framePoint(viewPoint: point, content: streamSize, in: container)
        let sent = store.identifyAt(x: p.x, y: p.y)
        DibsLog.event("identifyAt (\(Int(p.x)),\(Int(p.y))) sent=\(sent)")
    }

    private func send(_ jpeg: Data, size: CGSize) {
        if streamSize != size { streamSize = size }
        store.sendFrame(jpeg: jpeg, detect: false)
    }

    /// The item left the cart: the shopper removes its chip (the server keeps an undo).
    private func removed(_ chipId: String) {
        let name = store.run?.chip(chipId)?.name ?? "?"
        let sent = store.remove(chipId)
        DibsLog.event("watcher removed chip=\(chipId) name=\(name) sent=\(sent)")
    }

    /// A removed item turned up elsewhere (it was moved): bring its chip back.
    private func restored(_ chipId: String) {
        let name = store.run?.chip(chipId)?.name ?? "?"
        let sent = store.undoRemove(chipId)
        DibsLog.event("watcher restored chip=\(chipId) name=\(name) sent=\(sent)")
    }

    private func post(_ trigger: CartTrigger) {
        cropCount += 1
        let n = cropCount
        DebugLaunch.saveCrop(trigger.jpeg, index: n)
        let id = UUID()
        pending[id] = ScanGeometry.visionToTopLeft(trigger.box)
        DibsLog.event("addChip #\(n) start crop=\(Int(trigger.cropSize.width))x\(Int(trigger.cropSize.height)) \(trigger.jpeg.count / 1024) KB")
        let api = api, runId = runId, base64 = trigger.jpeg.base64EncodedString(), camera = camera, itemId = trigger.itemId
        Task { [weak self] in
            do {
                let chip = try await api.addChip(runId: runId, imageBase64: base64)
                camera.attach(chipId: chip.id, toItem: itemId)
                let price = chip.priceCents.map { Money.format($0) } ?? "no price"
                DibsLog.event("addChip #\(n) ok name=\"\(chip.name)\" price=\(price) source=\(chip.priceSource.rawValue) state=\(chip.state.rawValue)")
                self?.lastAddError = nil
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DibsLog.event("addChip #\(n) error=\(text)")
                camera.forget(item: itemId)
                self?.lastAddError = text
            }
            self?.pending[id] = nil
        }
    }
}
