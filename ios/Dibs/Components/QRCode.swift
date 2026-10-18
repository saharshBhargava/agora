import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR codes drawn on the phone with CoreImage (no network round trip).
enum QRCode {
    /// One pixel per module, with CoreImage's quiet zone. Scale it up with `.interpolation(.none)`.
    static func cgImage(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent)
    }
}

/// A crisp, square QR code for `text`.
struct QRCodeView: View {
    let text: String
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: text) { image = QRCode.cgImage(for: text) }
        .accessibilityElement()
        .accessibilityLabel("QR code to join the run")
        .accessibilityAddTraits(.isImage)
    }
}
