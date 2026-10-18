import AVFoundation
import SwiftUI
import UIKit

/// The shopper's screen: live camera of the cart (streamed to housemates, watched on-device for new
/// items) over the run's chip list. Minimal layout; Task 7 restyles it.
struct ShopperView: View {
    let store: RunStore
    let api: DibsAPI
    let runId: String
    let personId: String
    @State private var camera: ShopperCamera
    /// Finds QFC prices for unpriced chips with the in-app browser while this shopper is in the run.
    @State private var priceWorker = PriceWorker()

    init(store: RunStore, api: DibsAPI, runId: String, personId: String) {
        self.store = store
        self.api = api
        self.runId = runId
        self.personId = personId
        _camera = State(initialValue: ShopperCamera(store: store, api: api, runId: runId))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                cameraArea
                    .frame(height: geo.size.height * 0.6)
                    .clipped()
                chipList
            }
        }
        .background(Color.paper.ignoresSafeArea())
        .task {
            store.connect(runId: runId, personId: personId)
            priceWorker.start(api: api)
            await camera.start()
        }
        .onDisappear { camera.stop(); priceWorker.stop() }
        .onChange(of: store.run?.state, initial: true) { _, state in camera.runStateChanged(state) }
        .onChange(of: store.connection, initial: true) { _, c in DibsLog.event("socket \(c)") }
        .onChange(of: store.lastError) { _, e in if let e { DibsLog.event("store error: \(e)") } }
    }

    // MARK: camera

    @ViewBuilder
    private var cameraArea: some View {
        switch camera.status {
        case .denied:
            CameraOffPanel(title: "Camera is off",
                           message: "Dibs needs the camera to stream your cart to your housemates.",
                           showSettings: true)
        case .unavailable:
            CameraOffPanel(title: "No camera", message: "This device has no rear camera.", showSettings: false)
        case .starting, .running:
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    CameraPreview(session: camera.camera.session)
                        .contentShape(Rectangle())
                        .onTapGesture(coordinateSpace: .local) { p in camera.tap(at: p, in: geo.size) }
                    outlines(in: geo.size)
                    streamingPill.padding(.top, 12)
                }
            }
            .background(Color.cameraDark)
        }
    }

    @ViewBuilder
    private func outlines(in size: CGSize) -> some View {
        if let frame = camera.streamSize {
            ForEach(Array(camera.pending.values.enumerated()), id: \.offset) { _, r in
                PulsingOutline(rect: ScanGeometry.viewRect(normalized: r, content: frame, in: size))
            }
            if let region = store.identifyingRegion, frame.width > 0, frame.height > 0 {
                let n = CGRect(x: region.x / frame.width, y: region.y / frame.height,
                               width: region.w / frame.width, height: region.h / frame.height)
                PulsingOutline(rect: ScanGeometry.viewRect(normalized: n, content: frame, in: size))
            }
        }
    }

    private var streamingPill: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.white).frame(width: 7, height: 7)
            Text(streamingText).font(.system(size: 13, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.liveRed, in: Capsule())
    }

    private var streamingText: String {
        let names = (store.run?.people ?? []).filter { !$0.isShopper }.map(\.name)
        switch names.count {
        case 0: return "Streaming"
        case 1: return "Streaming to \(names[0])"
        case 2: return "Streaming to \(names[0]) and \(names[1])"
        default: return "Streaming to \(names.dropLast().joined(separator: ", ")) and \(names.last!)"
        }
    }

    // MARK: chips

    private var chipList: some View {
        let chips = (store.run?.chips ?? []).filter { !$0.dropped && $0.state != .removed }
        return List {
            if let err = camera.lastAddError {
                Text(err).font(.system(size: 14)).foregroundStyle(Color.danger)
            }
            if chips.isEmpty {
                Text("Put an item in the cart and hold still.").foregroundStyle(Color.muted)
            }
            ForEach(chips.reversed()) { chip in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chip.state == .identifying ? "Identifying…" : chip.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.ink)
                        Text(chip.state.rawValue).font(.system(size: 12)).foregroundStyle(Color.muted)
                    }
                    Spacer()
                    Text(chip.priceCents.map { Money.format($0) } ?? (priceWorker.currentName == chip.name && !priceWorker.phase.isEmpty ? priceWorker.phase : "Finding price…"))
                        .font(.display(16))
                        .foregroundStyle(chip.priceCents == nil ? Color.muted : Color.ink)
                }
            }
        }
        .listStyle(.plain)
    }
}

/// White outline that pulses over an item being identified.
private struct PulsingOutline: View {
    let rect: CGRect
    @State private var on = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white, lineWidth: 3)
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .allowsHitTesting(false)
    }
}

private struct CameraOffPanel: View {
    let title: String
    let message: String
    let showSettings: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(.display(22)).foregroundStyle(.white)
            Text(message).font(.system(size: 15)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
            if showSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 20)
                .frame(minHeight: 44)
                .background(Color.white, in: Capsule())
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cameraDark)
    }
}

/// AVCaptureVideoPreviewLayer, aspect-fill, rotated to portrait.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let c = previewLayer.connection, c.isVideoRotationAngleSupported(90), c.videoRotationAngle != 90 {
                c.videoRotationAngle = 90
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.backgroundColor = UIColor(Color.cameraDark)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
