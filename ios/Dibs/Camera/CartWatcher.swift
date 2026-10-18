import CoreGraphics
import Foundation

/// Decides when new items have landed in the cart and stayed still. Pure: it is fed timestamped
/// Vision results and returns decisions, so it is tested without a camera.
///
/// Rules (brief, Task 6, plus the controller's multi-item ruling):
/// - A frame whose change fraction (vs the previous frame) is above `rebaselineFraction` clears the
///   settled set and all tracks instead of triggering (the camera moved or the light changed).
/// - While a hand is present nothing settles (tracks are cleared).
/// - Each observation carries salient boxes, confidence-sorted. Boxes outside `minBoxArea...maxBoxArea`
///   are dropped, boxes with IoU > `mergeIoU` with a higher-confidence box are merged into it, and at
///   most `maxBoxes` are kept. A box that overlaps two smaller kept or tracked boxes, each under
///   1/`groupRatio` of its area, is dropped in favour of them (saliency sometimes boxes two close items as one).
/// - Each box is tracked on its own. A track whose box stays the same (IoU >= `stableIoU` frame to
///   frame) for `settleSeconds`, and overlaps every settled box with IoU < `newIoU`, triggers once
///   and joins the settled set. A track unseen for more than `missGrace` is dropped.
/// - `triggerOnInitialScene`: when true (default), objects already in view when watching starts (or
///   after a rebaseline) trigger like any new item. When false, the boxes that settle first after
///   start or a rebaseline become the baseline silently.
struct CartWatcher: Sendable {
    struct Observation: Sendable, Equatable {
        /// Seconds, any monotonic clock (the frame's presentation time).
        var time: TimeInterval
        /// Salient objects, Vision-normalized (bottom-left origin), highest confidence first.
        var boxes: [CGRect]
        var handPresent: Bool
        /// Fraction of the 32x32 thumbnail that changed since the previous observation, 0...1.
        var changeFraction: Double

        init(time: TimeInterval, boxes: [CGRect], handPresent: Bool, changeFraction: Double) {
            self.time = time
            self.boxes = boxes
            self.handPresent = handPresent
            self.changeFraction = changeFraction
        }

        init(time: TimeInterval, box: CGRect?, handPresent: Bool, changeFraction: Double) {
            self.init(time: time, boxes: box.map { [$0] } ?? [], handPresent: handPresent, changeFraction: changeFraction)
        }
    }

    enum Decision: Sendable, Equatable {
        /// Nothing item-sized in view.
        case empty
        case handPresent
        case rebaseline
        /// At least one new candidate is holding still; `elapsed` is the longest so far.
        case settling(elapsed: TimeInterval)
        /// Every box in view overlaps an item already settled.
        case known
        /// A box that settled first after start or a rebaseline, kept as baseline (no trigger).
        case baselined(CGRect)
        case trigger(CGRect)
    }

    private struct Track: Sendable {
        var box: CGRect
        var since: TimeInterval
        var lastSeen: TimeInterval
        var done = false
    }

    var settleSeconds: TimeInterval = 1.0
    var stableIoU: CGFloat = 0.8
    var newIoU: CGFloat = 0.5
    var mergeIoU: CGFloat = 0.5
    var rebaselineFraction: Double = 0.6
    var minBoxArea: CGFloat = 0.02
    var maxBoxArea: CGFloat = 0.7
    var maxBoxes = 3
    var groupRatio: CGFloat = 2.5
    var missGrace: TimeInterval = 0.25
    var triggerOnInitialScene = true

    private(set) var settled: [CGRect] = []
    private var tracks: [Track] = []
    private var hasBaseline = false

    init(triggerOnInitialScene: Bool = true) {
        self.triggerOnInitialScene = triggerOnInitialScene
    }

    /// Returns every trigger / baseline this observation produced, or one status decision when none.
    mutating func observe(_ o: Observation) -> [Decision] {
        if o.changeFraction > rebaselineFraction {
            settled = []
            tracks = []
            hasBaseline = false
            return [.rebaseline]
        }
        if o.handPresent {
            tracks = []
            return [.handPresent]
        }
        let boxes = candidates(o.boxes)

        // Match boxes to tracks (best IoU >= stableIoU), start new tracks for the rest.
        var used = Set<Int>()
        for box in boxes {
            var best: (i: Int, iou: CGFloat)?
            for (i, t) in tracks.enumerated() where !used.contains(i) {
                let v = Self.iou(t.box, box)
                if v >= stableIoU, v > (best?.iou ?? 0) { best = (i, v) }
            }
            if let best {
                tracks[best.i].box = box
                tracks[best.i].lastSeen = o.time
                used.insert(best.i)
            } else {
                tracks.append(Track(box: box, since: o.time, lastSeen: o.time))
                used.insert(tracks.count - 1)
            }
        }
        tracks.removeAll { o.time - $0.lastSeen > missGrace + 1e-6 }

        var out: [Decision] = []
        var longest: TimeInterval?
        var anyVisible = false
        let baselining = !triggerOnInitialScene && !hasBaseline
        for i in tracks.indices where tracks[i].lastSeen == o.time {
            anyVisible = true
            if tracks[i].done { continue }
            let box = tracks[i].box
            if settled.contains(where: { Self.iou($0, box) >= newIoU }) {
                tracks[i].done = true
                continue
            }
            let elapsed = o.time - tracks[i].since
            // Small epsilon so 10 observations 0.1 s apart count as a full second despite float error.
            guard elapsed + 1e-6 >= settleSeconds else {
                longest = max(longest ?? 0, elapsed)
                continue
            }
            settled.append(box)
            tracks[i].done = true
            out.append(baselining ? .baselined(box) : .trigger(box))
        }
        if !out.isEmpty {
            hasBaseline = true
            return out
        }
        if let longest { return [.settling(elapsed: longest)] }
        return [anyVisible ? .known : .empty]
    }

    /// Size filter, merge, cap, then drop a box that groups two smaller ones.
    private func candidates(_ raw: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for box in raw where Self.isItemSized(box, min: minBoxArea, max: maxBoxArea) {
            if kept.contains(where: { Self.iou($0, box) > mergeIoU }) { continue }
            kept.append(box)
            if kept.count == maxBoxes { break }
        }
        let others = kept + tracks.map(\.box)
        return kept.filter { big in
            let area = big.width * big.height
            let inside = others.filter { small in
                small != big && small.width * small.height * groupRatio < area && Self.overlapOfSmaller(big, small) >= 0.5
            }
            // Two distinct smaller boxes (not the same item seen twice).
            for (i, a) in inside.enumerated() {
                for b in inside[(i + 1)...] where Self.iou(a, b) < mergeIoU { return false }
            }
            return true
        }
    }

    static func isItemSized(_ box: CGRect, min: CGFloat, max: CGFloat) -> Bool {
        let area = box.width * box.height
        return area >= min && area <= max
    }

    /// Intersection over union of two rects; 0 when either is empty.
    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// Intersection area over the smaller rect's area.
    static func overlapOfSmaller(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let smaller = min(a.width * a.height, b.width * b.height)
        return smaller > 0 ? (i.width * i.height) / smaller : 0
    }
}

/// Frame-to-frame change on small grayscale thumbnails (same per-pixel delta as the server's DiffDetector).
enum SceneDiff {
    static let side = 32
    static let pixelDelta = 30

    /// Fraction of pixels whose gray level moved by more than `pixelDelta`. A missing or mismatched
    /// previous thumbnail counts as no change (the first frame is the baseline).
    static func changeFraction(previous: [UInt8]?, current: [UInt8], pixelDelta: Int = pixelDelta) -> Double {
        guard let previous, previous.count == current.count, !current.isEmpty else { return 0 }
        var n = 0
        for i in 0..<current.count where abs(Int(current[i]) - Int(previous[i])) > pixelDelta { n += 1 }
        return Double(n) / Double(current.count)
    }
}
