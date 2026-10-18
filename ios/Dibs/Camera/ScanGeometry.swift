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

// MARK: preview mapping

extension ScanGeometry {
    /// Vision's normalized, bottom-left-origin rect to a normalized top-left-origin rect.
    static func visionToTopLeft(_ box: CGRect) -> CGRect {
        CGRect(x: box.minX, y: 1 - box.minY - box.height, width: box.width, height: box.height)
    }

    /// Where content of `content` size lands inside `container` when drawn aspect-fill (centred,
    /// overflowing on one axis), in container coordinates.
    static func fillRect(content: CGSize, in container: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = max(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A normalized top-left rect of the frame to container coordinates under aspect-fill.
    static func viewRect(normalized r: CGRect, content: CGSize, in container: CGSize) -> CGRect {
        let fill = fillRect(content: content, in: container)
        return CGRect(x: fill.minX + r.minX * fill.width, y: fill.minY + r.minY * fill.height,
                      width: r.width * fill.width, height: r.height * fill.height)
    }

    /// A tap in container coordinates to a point in frame pixels (`content` size), clamped to the frame.
    static func framePoint(viewPoint p: CGPoint, content: CGSize, in container: CGSize) -> CGPoint {
        let fill = fillRect(content: content, in: container)
        guard fill.width > 0, fill.height > 0 else { return .zero }
        let nx = min(max((p.x - fill.minX) / fill.width, 0), 1)
        let ny = min(max((p.y - fill.minY) / fill.height, 0), 1)
        return CGPoint(x: (nx * content.width).rounded(), y: (ny * content.height).rounded())
    }
}
