import CoreGraphics

enum ScanGeometry {
    /// Vision's normalized, bottom-left-origin rect to a top-left-origin pixel rect.
    static func visionToImage(_ box: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: box.minX * imageSize.width,
               y: (1 - box.minY - box.height) * imageSize.height,
               width: box.width * imageSize.width,
               height: box.height * imageSize.height)
    }

    /// Pixel crop rect for a Vision box: padded, clamped to the image, at least `minSide`, integer-aligned.
    /// A nil box yields the centred rect covering 60% of each dimension.
    static func cropRect(for box: CGRect?, imageSize: CGSize, padding: CGFloat = 0.08, minSide: CGFloat = 64) -> CGRect {
        let bounds = CGRect(origin: .zero, size: imageSize)
        guard let box else {
            return CGRect(x: imageSize.width * 0.2, y: imageSize.height * 0.2,
                          width: imageSize.width * 0.6, height: imageSize.height * 0.6).rounded()
        }
        let pixel = visionToImage(box, imageSize: imageSize)
        var rect = pixel.insetBy(dx: -pixel.width * padding, dy: -pixel.height * padding).intersection(bounds)
        if rect.isNull { rect = CGRect(x: pixel.midX, y: pixel.midY, width: 0, height: 0) }
        let width = min(max(rect.width, minSide), imageSize.width)
        let height = min(max(rect.height, minSide), imageSize.height)
        let x = min(max(rect.midX - width / 2, 0), imageSize.width - width)
        let y = min(max(rect.midY - height / 2, 0), imageSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height).rounded()
    }
}

private extension CGRect {
    func rounded() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(), width: width.rounded(), height: height.rounded())
    }
}

struct BoxSmoother: Sendable {
    private let alpha: CGFloat
    private let dropAfter: Int
    private var current: CGRect?
    private var misses = 0

    init(alpha: CGFloat = 0.35, dropAfter: Int = 5) {
        self.alpha = alpha
        self.dropAfter = dropAfter
    }

    /// Exponentially smooths each edge. Returns nil only after `dropAfter` consecutive nil inputs.
    mutating func update(_ box: CGRect?) -> CGRect? {
        guard let box else {
            misses += 1
            if misses >= dropAfter { current = nil }
            return current
        }
        misses = 0
        guard let previous = current else { current = box; return box }
        func mix(_ old: CGFloat, _ new: CGFloat) -> CGFloat { old + alpha * (new - old) }
        let minX = mix(previous.minX, box.minX), minY = mix(previous.minY, box.minY)
        let maxX = mix(previous.maxX, box.maxX), maxY = mix(previous.maxY, box.maxY)
        let smoothed = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        current = smoothed
        return smoothed
    }
}
