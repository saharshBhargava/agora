import SwiftUI

/// The shopper's latest relayed frame as a rounded hero, with the red "Jake's cart" pill and a white
/// outline over the region being identified (web LiveView.tsx, canvas Claim.dc.html).
struct LiveView: View {
    let frame: UIImage?
    let shopperName: String
    var highlight: ClaimLogic.Highlight?
    var height: CGFloat = 196

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let frame {
                    Image(uiImage: frame)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .accessibilityLabel("\(shopperName)'s cart, live")
                } else {
                    Stripes()
                    Text("Waiting for the cart")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if let frame, let highlight {
                    let rect = ClaimLogic.frameBoxToDisplay(highlight.region, box: geo.size, imageSize: frame.size)
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: highlight.pending ? [6, 4] : []))
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityHidden(true)
                    Text(highlight.label)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .offset(x: max(0, rect.minX), y: max(0, rect.minY - 28))
                }

                HStack(spacing: 8) {
                    Circle().fill(Color.liveRed).frame(width: 8, height: 8)
                    Text("\(shopperName)'s cart")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white)
                }
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Color.ink.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)
                .accessibilityHidden(true)
            }
        }
        .frame(height: height)
        .background(Color(hex: 0x2A2723))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The dark striped placeholder before the first frame arrives.
private struct Stripes: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(hex: 0x2A2723)))
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 14, height: size.height)), with: .color(Color(hex: 0x34302B)))
                x += 28
            }
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
extension PreviewData {
    /// A 640 x 480 stand-in for a relayed cart frame.
    @MainActor static let sampleFrame: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480), format: format).image { ctx in
            UIColor(red: 0.20, green: 0.19, blue: 0.17, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            UIColor(red: 0.91, green: 0.81, blue: 0.49, alpha: 1).setFill()
            ctx.fill(CGRect(x: 240, y: 160, width: 160, height: 120))
            UIColor(red: 0.85, green: 0.89, blue: 0.98, alpha: 1).setFill()
            ctx.fill(CGRect(x: 60, y: 260, width: 140, height: 170))
        }
    }()
}

#Preview("Live view") {
    VStack(spacing: 16) {
        LiveView(frame: nil, shopperName: "Jake")
        LiveView(frame: PreviewData.sampleFrame, shopperName: "Jake",
                 highlight: .init(region: Box(x: 220, y: 140, w: 200, h: 160), label: "Kirkland Eggs · $8.72", pending: false))
    }
    .padding()
    .background(Color.paper)
}
#endif
