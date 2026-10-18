import PhotosUI
import SwiftUI
import UIKit

/// The shopper photographs the receipt (canvas Receipt.dc.html, docs/screenshots/v2-11-receipt-camera.jpg):
/// full-screen camera with a receipt guide, the shutter, and "From photos". `onSubmit` gets the base64 JPEG.
struct ReceiptView: View {
    var busy: Bool
    var error: String?
    var onSubmit: (String) -> Void
    var onError: (String) -> Void

    /// Created once in `.task`, so redraws never build another capture session.
    @State private var camera: ReceiptCamera?
    @State private var status: ReceiptCamera.Status = .starting
    @State private var pick: PhotosPickerItem?
    @State private var capturing = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Snap the receipt")
                    .font(.display(26))
                Text("Fit the whole receipt in the frame. We match each line to what was claimed.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, Metrics.space1)
            .padding(.bottom, Metrics.space2)

            stage

            if let error {
                Text(error)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: 0xFFB4A8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .accessibilityAddTraits(.isStaticText)
            }

            bar
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cameraDark.ignoresSafeArea())
        .toolbarBackground(Color.cameraDark, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let cam = camera ?? ReceiptCamera()
            camera = cam
            status = await cam.start()
        }
        .onDisappear { camera?.stop() }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            pick = nil
            Task { await usePicked(item) }
        }
    }

    private var stage: some View {
        ZStack {
            switch status {
            case .running:
                if let camera { ReceiptCameraPreview(session: camera.session) }
            case .starting:
                Color.black.opacity(0.25)
            case .denied, .unavailable:
                stripes
                VStack(spacing: Metrics.space1) {
                    Text(status == .denied ? "Dibs can't use the camera." : "No camera here.")
                        .font(.system(size: 15, weight: .bold))
                    Text("Pick a photo of the receipt instead.")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.white.opacity(0.85))
                    if status == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(.system(size: 14, weight: .bold))
                        .padding(.top, 4)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
            }
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(.white, lineWidth: 3)
                .frame(width: 270, height: 440)
                .padding(.vertical, 30)
                .accessibilityHidden(true)
            VStack {
                HStack(spacing: 6) {
                    if busy { ProgressView().controlSize(.small).tint(Color.ink) }
                    Text(busy ? "Reading the receipt…" : "Hold steady")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 26)
                .accessibilityAddTraits(.updatesFrequently)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var stripes: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            var i = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 18, height: size.height)),
                         with: .color(Color(hex: i.isMultiple(of: 2) ? 0x2E2A26 : 0x26231F)))
                x += 18
                i += 1
            }
        }
    }

    private var bar: some View {
        HStack {
            PhotosPicker(selection: $pick, matching: .images) {
                Text("From photos")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    .overlay(Capsule().strokeBorder(Color.muted))
            }
            .disabled(busy)
            .frame(width: 120, alignment: .leading)
            Spacer()
            Button {
                Task { await shoot() }
            } label: {
                Circle()
                    .fill(.white)
                    .frame(width: 60, height: 60)
                    .padding(4)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 4))
                    .frame(width: 76, height: 76)
            }
            .buttonStyle(.plain)
            .disabled(busy || capturing)
            .opacity(busy || capturing ? 0.5 : 1)
            .accessibilityLabel("Take the receipt photo")
            Spacer()
            Color.clear.frame(width: 120, height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func shoot() async {
        guard status == .running else {
            onError(status == .starting ? "Point the camera at the receipt first" : "Pick a photo of the receipt instead.")
            return
        }
        capturing = true
        defer { capturing = false }
        do {
            guard let camera else { return onError("Point the camera at the receipt first") }
            let data = try await camera.capture()
            guard let base64 = await Self.encode(data) else { return onError("Could not read that photo") }
            onSubmit(base64)
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func usePicked(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let base64 = await Self.encode(data) else { return onError("Could not read that photo") }
            onSubmit(base64)
        } catch {
            onError("Could not read that photo")
        }
    }

    /// Scales and re-encodes off the main thread.
    private static func encode(_ data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) { ReceiptImage.jpegBase64(data: data) }.value
    }
}

#if DEBUG
#Preview("Receipt camera") {
    NavigationStack {
        ReceiptView(busy: false, error: nil, onSubmit: { _ in }, onError: { _ in })
    }
}

#Preview("Reading") {
    NavigationStack {
        ReceiptView(busy: true, error: "The server is taking too long. Try again.", onSubmit: { _ in }, onError: { _ in })
    }
}
#endif
