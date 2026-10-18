import CoreGraphics
import Foundation

/// A small grayscale picture of the frame, row-major from the top-left (96 px on the long side).
struct SceneThumb: Sendable, Equatable {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }
}

/// Decides when new items have landed in the cart and stayed still. Pure: it is fed timestamped
/// Vision results plus a thumbnail and returns decisions, so it is tested without a camera.
///
/// Boxes: foreground instance boxes (or saliency boxes, confidence-sorted, when there are none); a box
/// over `splitArea` of the frame is replaced by the boxes inside it. They are filtered (area `minBoxArea...maxBoxArea`, not
/// touching two or more frame edges), merged (IoU > `mergeIoU`), capped at `maxBoxes`, and a box that
/// groups two smaller ones is dropped. Each box is tracked; it is stable after `settleSeconds` at
/// IoU >= `stableIoU` frame to frame (one missed observation within `missGrace` is tolerated).
///
/// Phases:
/// - Initial scene: stable boxes trigger (or are kept silently when `triggerOnInitialScene` is false).
///   Once the scene has been still for `initialSeconds` with no box still settling, the current
///   thumbnail becomes the reference and watching starts. This happens once per watcher.
/// - Watching: a stable box triggers only when the pixels inside it really changed against the
///   reference (mean |diff| >= `regionMeanDelta` and >= `regionChangedFraction` of its pixels moved
///   by more than `regionPixelDelta`), after compensating a small global camera shift and brightness
///   change. Box flicker or merging over unchanged pixels never triggers. After any box settles the
///   reference takes the current frame's pixels that did not really change (drift) plus everything
///   inside triggered boxes; changed pixels nobody has boxed yet stay pending, so a new item is never
///   absorbed before it triggers.
/// - A small camera shift (best alignment off zero) or a scene change over `shiftFraction` of the
///   frame is a rebaseline: settled boxes move or clear, the reference is retaken, nothing triggers.
///   Fast motion (frame-to-frame change over `motionFraction`) or a hand only resets the tracks.
struct CartWatcher: Sendable {
    struct Observation: Sendable, Equatable {
        /// Seconds, any monotonic clock (the frame's presentation time).
        var time: TimeInterval
        /// Salient objects, Vision-normalized (bottom-left origin), highest confidence first.
        /// Used when there are no instance boxes.
        var boxes: [CGRect]
        var handPresent: Bool
        var thumb: SceneThumb
        /// One box per foreground instance (Vision-normalized), largest first. Preferred over `boxes`.
        var instances: [CGRect]
        /// Where hands are (Vision-normalized). When given, a hand only blocks boxes near it; when
        /// empty with `handPresent`, the whole frame is blocked.
        var hands: [CGRect]

        init(time: TimeInterval, boxes: [CGRect], handPresent: Bool, thumb: SceneThumb, instances: [CGRect] = [], hands: [CGRect] = []) {
            self.time = time
            self.boxes = boxes
            self.handPresent = handPresent || !hands.isEmpty
            self.thumb = thumb
            self.instances = instances
            self.hands = hands
        }
    }

    enum Decision: Sendable, Equatable {
        /// Nothing item-sized in view.
        case empty
        case handPresent
        /// The frame changed a lot since the last one (camera or arm moving): tracks reset.
        case motion
        /// Most of the scene changed against the reference: waiting for it to hold still to retake it.
        case rebaseline
        /// The camera shifted by (dx, dy) thumbnail pixels: reference retaken, settled boxes moved.
        case cameraShift(dx: Int, dy: Int)
        case referenceTaken
        /// At least one candidate is holding still; `elapsed` is the longest so far.
        case settling(elapsed: TimeInterval)
        /// Every box in view is resolved (triggered, unchanged or known).
        case known
        /// A stable box over pixels that did not change: not an item.
        case unchanged(CGRect)
        /// An initial-scene box kept as baseline (no trigger), when `triggerOnInitialScene` is false.
        case baselined(CGRect)
        case trigger(CGRect)
        /// A remembered item's spot emptied for `removeSeconds` with no box over it.
        case removed(chipId: String, item: Int)
        /// A missing item showed up elsewhere (feature prints matched): box updated, nothing added.
        case moved(item: Int, chipId: String?, to: CGRect)
        /// A removed item came back within `moveWindow` (moved, not taken out): undo its removal.
        case restored(chipId: String, item: Int)
        /// A feature-print distance between a new candidate and a missing item (for logs).
        case match(distance: Double, item: Int, chipId: String?)
    }

    /// An item that triggered, remembered for removal and move detection.
    struct Item: Sendable, Equatable {
        let id: Int
        var chipId: String?
        var box: CGRect
        /// The thumbnail right after it was added (or moved, or the camera shifted).
        var reference: SceneThumb
        var missingSince: TimeInterval?
        var wentMissingAt: TimeInterval?
        var removed = false
    }

    private struct Track: Sendable {
        var box: CGRect
        var since: TimeInterval
        var lastSeen: TimeInterval
        var done = false
    }

    var settleSeconds: TimeInterval = 1.0
    var stableIoU: CGFloat = 0.8
    var mergeIoU: CGFloat = 0.5
    var minBoxArea: CGFloat = 0.03
    var maxBoxArea: CGFloat = 0.7
    var edgeMargin: CGFloat = 0.008
    var maxBoxes = 4
    /// A box covering more than this is replaced by the item boxes found inside it.
    var splitArea: CGFloat = 0.35
    var groupRatio: CGFloat = 2.5
    var missGrace: TimeInterval = 0.25
    var initialSeconds: TimeInterval = 2.0
    /// Frame-to-frame fraction (pixels moved > 30) below which the scene counts as still.
    var stillFraction: Double = 0.05
    var motionFraction: Double = 0.6
    var shiftFraction: Double = 0.4
    var regionPixelDelta = 25
    var regionMeanDelta: Double = 12
    var regionChangedFraction: Double = 0.15
    var maxShift = 5
    /// Shifts up to this many thumbnail pixels (hand-held jitter) are compensated without a rebaseline.
    var smallShift = 2
    /// Margin around a hand box inside which tracks are blocked.
    var handMargin: CGFloat = 0.08
    /// The initial scene ends after this long even if the camera never holds perfectly still.
    var initialMaxSeconds: TimeInterval = 6.0
    var triggerOnInitialScene = true
    var removeSeconds: TimeInterval = 2.0
    var moveWindow: TimeInterval = 5.0
    var moveDistance: Double = 0.5
    /// A box overlapping a remembered item by more than this means the item is still there.
    var presentIoU: CGFloat = 0.3

    private(set) var items: [Item] = []
    private var nextItemId = 1
    private var lastTime: TimeInterval?

    private(set) var settled: [CGRect] = []
    private(set) var reference: SceneThumb?
    private(set) var watching = false
    /// Region stats of the last box gated against the reference (for logs).
    private(set) var lastGate: SceneDiff.RegionChange?
    private var tracks: [Track] = []
    private var previous: SceneThumb?
    private var stillSince: TimeInterval?
    private var startTime: TimeInterval?
    private var needsReference = false

    init(triggerOnInitialScene: Bool = true) {
        self.triggerOnInitialScene = triggerOnInitialScene
    }

    /// Returns every trigger / unchanged / baseline / reference / removal / move event this
    /// observation produced, or one status decision when none. `distance(box, itemId)` compares a
    /// candidate box in the current frame with a remembered item's feature print (nil = unknown).
    mutating func observe(_ o: Observation, distance: (CGRect, Int) -> Double? = { _, _ in nil }) -> [Decision] {
        let dt = o.time - (lastTime ?? o.time)
        lastTime = o.time
        items.removeAll { $0.removed && o.time - ($0.wentMissingAt ?? o.time) > moveWindow + 1e-6 }
        let motion = SceneDiff.changeFraction(previous: previous, current: o.thumb)
        // Stillness tolerates 1 px of hand-held jitter (3x3 neighbourhood).
        let jitter = previous.map {
            SceneDiff.regionChange(current: o.thumb, reference: $0, rect: nil, alignment: .identity, pixelDelta: SceneDiff.pixelDelta).fraction
        } ?? 0
        previous = o.thumb
        startTime = startTime ?? o.time
        let globalHand = o.handPresent && o.hands.isEmpty
        let localHands = o.hands.map { $0.insetBy(dx: -handMargin, dy: -handMargin) }
        let still = jitter < stillFraction && !globalHand
        if still { stillSince = stillSince ?? o.time } else { stillSince = nil }

        if o.handPresent {
            // A hand pauses the removal clocks.
            for i in items.indices { if let m = items[i].missingSince { items[i].missingSince = m + dt } }
        }
        if motion > motionFraction || globalHand {
            if !o.handPresent {
                for i in items.indices { if let m = items[i].missingSince { items[i].missingSince = m + dt } }
            }
            tracks = []
            return [globalHand && motion <= motionFraction ? .handPresent : .motion]
        }

        var alignment = SceneDiff.Alignment.identity
        if watching {
            guard let ref = reference, !needsReference else {
                tracks = []
                guard still else { return [.rebaseline] }
                reference = o.thumb
                needsReference = false
                rereferenceItems(o.thumb)
                return [.referenceTaken]
            }
            alignment = SceneDiff.align(current: o.thumb, reference: ref, maxShift: maxShift)
            let global = SceneDiff.regionChange(current: o.thumb, reference: ref, rect: nil,
                                                alignment: alignment, pixelDelta: regionPixelDelta)
            // A hand can cover much of the frame: never rebaseline on it.
            if global.fraction > shiftFraction && !o.handPresent {
                tracks = []
                settled = []
                needsReference = true
                for i in items.indices { items[i].missingSince = nil }
                if still {
                    reference = o.thumb
                    needsReference = false
                    rereferenceItems(o.thumb)
                }
                return [.rebaseline]
            }
            // Small shifts (hand-held jitter) are compensated in every comparison; only a larger
            // one retakes the reference.
            if alignment.isShift && max(abs(alignment.dx), abs(alignment.dy)) > smallShift && !o.handPresent {
                let dx = CGFloat(alignment.dx) / CGFloat(o.thumb.width)
                let dy = CGFloat(alignment.dy) / CGFloat(o.thumb.height)
                // Content moved by (-dx, -dy) in top-left pixels; Vision's y axis points up.
                settled = settled.map { $0.offsetBy(dx: -dx, dy: dy) }
                for i in items.indices { items[i].box = items[i].box.offsetBy(dx: -dx, dy: dy) }
                reference = o.thumb
                rereferenceItems(o.thumb)
                tracks = []
                return [.cameraShift(dx: alignment.dx, dy: alignment.dy)]
            }
        }

        let nearHand = { (b: CGRect) in localHands.contains { $0.intersects(b) } }
        let cands = candidates(primary: o.instances.isEmpty ? o.boxes : o.instances, all: o.instances + o.boxes)
            .filter { !nearHand($0) }
        // A hand near a track restarts its stillness clock.
        tracks.removeAll { nearHand($0.box) }
        track(cands, at: o.time)

        var out: [Decision] = []
        var longest: TimeInterval?
        var anyVisible = false
        var anySettled = false
        var absorbBoxes: [CGRect] = []
        var touched = Set<Int>()
        for i in tracks.indices where tracks[i].lastSeen == o.time {
            anyVisible = true
            if tracks[i].done { continue }
            let box = tracks[i].box
            let elapsed = o.time - tracks[i].since
            // Small epsilon so 10 observations 0.1 s apart count as a full second despite float error.
            guard elapsed + 1e-6 >= settleSeconds else {
                longest = max(longest ?? 0, elapsed)
                continue
            }
            tracks[i].done = true
            anySettled = true
            if !watching {
                if settled.contains(where: { CartWatcher.iou($0, box) >= mergeIoU }) { continue }
                settled.append(box)
                if triggerOnInitialScene {
                    touched.insert(addItem(box, thumb: o.thumb))
                    out.append(.trigger(box))
                } else {
                    out.append(.baselined(box))
                }
                continue
            }
            guard let ref = reference else { continue }
            let gate = SceneDiff.regionChange(current: o.thumb, reference: ref,
                                              rect: SceneDiff.pixelRect(box, width: ref.width, height: ref.height),
                                              alignment: alignment, pixelDelta: regionPixelDelta)
            lastGate = gate
            let changed = gate.mean >= regionMeanDelta && gate.fraction >= regionChangedFraction
            // The spot a missing item just left is not a new item.
            let vacated = items.contains { $0.missingSince != nil && !$0.removed && Self.iou($0.box, box) > presentIoU }
            guard changed, !vacated else {
                out.append(.unchanged(box))
                continue
            }
            // A missing (or just removed) item showing up here is a move, not a new item.
            var best: (index: Int, d: Double)?
            for (j, item) in items.enumerated() where item.missingSince != nil || item.removed {
                guard let d = distance(box, item.id) else { continue }
                out.append(.match(distance: d, item: item.id, chipId: item.chipId))
                if d < (best?.d ?? .infinity) { best = (j, d) }
            }
            if let best, best.d < moveDistance {
                let old = items[best.index].box
                settled.removeAll { $0 == old }
                settled.append(box)
                absorbBoxes += [old, box]
                items[best.index].box = box
                items[best.index].reference = o.thumb
                items[best.index].missingSince = nil
                items[best.index].wentMissingAt = nil
                touched.insert(items[best.index].id)
                if items[best.index].removed, let chip = items[best.index].chipId {
                    out.append(.restored(chipId: chip, item: items[best.index].id))
                }
                items[best.index].removed = false
                out.append(.moved(item: items[best.index].id, chipId: items[best.index].chipId, to: box))
                continue
            }
            settled.append(box)
            absorbBoxes.append(box)
            touched.insert(addItem(box, thumb: o.thumb))
            out.append(.trigger(box))
        }

        // Removal: a remembered item whose spot changed with no box over it, for removeSeconds.
        if watching && !o.handPresent {
            for i in items.indices where !items[i].removed && !touched.contains(items[i].id) {
                let item = items[i]
                let rect = SceneDiff.pixelRect(item.box, width: o.thumb.width, height: o.thumb.height)
                var gate = SceneDiff.regionChange(current: o.thumb, reference: item.reference, rect: rect,
                                                  alignment: SceneDiff.Alignment(offset: alignment.offset), pixelDelta: regionPixelDelta)
                if gate.mean >= regionMeanDelta && gate.fraction >= regionChangedFraction {
                    // Check again after compensating a camera shift since the item's reference.
                    let a = SceneDiff.align(current: o.thumb, reference: item.reference, maxShift: maxShift)
                    gate = SceneDiff.regionChange(current: o.thumb, reference: item.reference, rect: rect, alignment: a, pixelDelta: regionPixelDelta)
                }
                let gone = gate.mean >= regionMeanDelta && gate.fraction >= regionChangedFraction
                let boxed = cands.contains { Self.iou($0, item.box) > presentIoU }
                guard gone, !boxed else {
                    items[i].missingSince = nil
                    items[i].wentMissingAt = nil
                    continue
                }
                let since = item.missingSince ?? o.time
                items[i].missingSince = since
                items[i].wentMissingAt = item.wentMissingAt ?? o.time
                guard o.time - since + 1e-6 >= removeSeconds, let chip = item.chipId else { continue }
                items[i].removed = true
                items[i].missingSince = nil
                settled.removeAll { $0 == item.box }
                absorbBoxes.append(item.box)
                out.append(.removed(chipId: chip, item: item.id))
            }
        }

        if watching, anySettled || !absorbBoxes.isEmpty, let ref = reference {
            reference = SceneDiff.absorb(current: o.thumb, into: ref, offset: alignment.offset,
                                         pixelDelta: regionPixelDelta, boxes: absorbBoxes)
        }

        // End of the initial scene: still long enough and nothing left settling.
        let stillLongEnough = stillSince.map { o.time - $0 + 1e-6 >= initialSeconds } ?? false
        let timedOut = o.time - (startTime ?? o.time) + 1e-6 >= initialMaxSeconds
        if !watching, longest == nil, stillLongEnough || timedOut {
            watching = true
            reference = o.thumb
            rereferenceItems(o.thumb)
            out.append(.referenceTaken)
        }
        if !out.isEmpty { return out }
        if let longest { return [.settling(elapsed: longest)] }
        if !localHands.isEmpty { return [.handPresent] }
        return [anyVisible ? .known : .empty]
    }

    // MARK: items

    /// The item a trigger for `box` created.
    func itemId(for box: CGRect) -> Int? {
        items.last { $0.box == box }?.id
    }

    /// Links an item to the chip its crop became.
    mutating func attach(chipId: String, toItem id: Int) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].chipId = chipId }
    }

    /// Drops an item whose add failed.
    mutating func forget(item id: Int) {
        items.removeAll { $0.id == id }
    }

    private mutating func addItem(_ box: CGRect, thumb: SceneThumb) -> Int {
        let id = nextItemId
        nextItemId += 1
        items.append(Item(id: id, box: box, reference: thumb))
        return id
    }

    private mutating func rereferenceItems(_ thumb: SceneThumb) {
        for i in items.indices {
            items[i].reference = thumb
            items[i].missingSince = nil
            if !items[i].removed { items[i].wentMissingAt = nil }
        }
    }

    /// Match boxes to tracks (best IoU >= stableIoU), start new tracks for the rest, drop stale ones.
    private mutating func track(_ boxes: [CGRect], at time: TimeInterval) {
        var used = Set<Int>()
        for box in boxes {
            var best: (i: Int, iou: CGFloat)?
            for (i, t) in tracks.enumerated() where !used.contains(i) {
                let v = Self.iou(t.box, box)
                if v >= stableIoU, v > (best?.iou ?? 0) { best = (i, v) }
            }
            if let best {
                tracks[best.i].box = box
                tracks[best.i].lastSeen = time
                used.insert(best.i)
            } else {
                tracks.append(Track(box: box, since: time, lastSeen: time))
                used.insert(tracks.count - 1)
            }
        }
        tracks.removeAll { time - $0.lastSeen > missGrace + 1e-6 }
    }

    /// Size and edge filter, merge, cap, then drop a box that groups two smaller ones.
    /// `primary` are instance boxes (or saliency boxes when there are none); `all` is every box seen,
    /// used to split a box over `splitArea` into the item boxes inside it.
    private func candidates(primary: [CGRect], all: [CGRect]) -> [CGRect] {
        let usable = { (b: CGRect) in Self.isItemSized(b, min: self.minBoxArea, max: self.maxBoxArea) && Self.edgesTouched(b, margin: self.edgeMargin) < 2 }
        var raw: [CGRect] = []
        for box in primary {
            guard box.width * box.height > splitArea else { raw.append(box); continue }
            let inner = all.filter { $0 != box && usable($0) && $0.width * $0.height * 1.5 < box.width * box.height && Self.overlapOfSmaller(box, $0) >= 0.8 }
            raw += inner.isEmpty ? [box] : inner
        }
        var kept: [CGRect] = []
        for box in raw where Self.isItemSized(box, min: minBoxArea, max: maxBoxArea) && Self.edgesTouched(box, margin: edgeMargin) < 2 {
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

    /// How many of the four frame edges (normalized 0...1) the box touches within `margin`.
    static func edgesTouched(_ box: CGRect, margin: CGFloat) -> Int {
        [box.minX <= margin, box.minY <= margin, box.maxX >= 1 - margin, box.maxY >= 1 - margin].filter { $0 }.count
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

/// Pixel comparisons on thumbnails.
enum SceneDiff {
    /// Long side of the thumbnail, in pixels.
    static let longSide = 96
    /// Frame-to-frame per-pixel delta (same as the server's DiffDetector).
    static let pixelDelta = 30

    /// Fraction of pixels whose gray level moved by more than `pixelDelta`. A missing or mismatched
    /// previous thumbnail counts as no change.
    static func changeFraction(previous: SceneThumb?, current: SceneThumb, pixelDelta: Int = pixelDelta) -> Double {
        guard let previous, previous.pixels.count == current.pixels.count, !current.pixels.isEmpty else { return 0 }
        var n = 0
        for i in 0..<current.pixels.count where abs(Int(current.pixels[i]) - Int(previous.pixels[i])) > pixelDelta { n += 1 }
        return Double(n) / Double(current.pixels.count)
    }

    /// How the current frame lines up with the reference: current(x, y) ~ reference(x + dx, y + dy) + offset.
    struct Alignment: Sendable, Equatable {
        var dx = 0, dy = 0
        /// Global brightness change (median of current minus reference).
        var offset: Double = 0
        var residual: Double = 0
        var zeroResidual: Double = 0
        static let identity = Alignment()

        /// A real shift: off zero and clearly better than no shift.
        var isShift: Bool { (dx != 0 || dy != 0) && residual < zeroResidual * 0.7 && zeroResidual - residual > 2 }
    }

    /// Finds the translation within ±`maxShift` pixels that best matches the frames (mean absolute
    /// difference after removing the global brightness change). Ties keep the smaller shift.
    static func align(current c: SceneThumb, reference r: SceneThumb, maxShift: Int) -> Alignment {
        guard c.width == r.width, c.height == r.height, !c.pixels.isEmpty else { return .identity }
        // Median of the per-pixel difference: a global brightness change, robust to a new item.
        var histogram = [Int](repeating: 0, count: 511)
        for i in 0..<c.pixels.count { histogram[Int(c.pixels[i]) - Int(r.pixels[i]) + 255] += 1 }
        var seen = 0, off = 0
        for (i, count) in histogram.enumerated() {
            seen += count
            if seen * 2 >= c.pixels.count { off = i - 255; break }
        }
        let offset = Double(off)
        guard c.width > 2 * maxShift, c.height > 2 * maxShift else { return .identity }
        let w = c.width
        // Mean |difference| over the interior every shift can reach, sampled every 2nd pixel.
        func residual(_ cp: UnsafeBufferPointer<UInt8>, _ rp: UnsafeBufferPointer<UInt8>, _ dx: Int, _ dy: Int) -> Double {
            var sum = 0, n = 0
            var y = maxShift
            while y < c.height - maxShift {
                let crow = y * w, rrow = (y + dy) * w + dx
                var x = maxShift
                while x < w - maxShift {
                    let d = Int(cp[crow + x]) - Int(rp[rrow + x]) - off
                    sum += d < 0 ? -d : d
                    n += 1
                    x += 2
                }
                y += 2
            }
            return n > 0 ? Double(sum) / Double(n) : 0
        }
        return c.pixels.withUnsafeBufferPointer { cp in
            r.pixels.withUnsafeBufferPointer { rp in
                let zero = residual(cp, rp, 0, 0)
                var best = Alignment(dx: 0, dy: 0, offset: offset, residual: zero, zeroResidual: zero)
                for dy in -maxShift...maxShift {
                    for dx in -maxShift...maxShift where dx != 0 || dy != 0 {
                        let v = residual(cp, rp, dx, dy)
                        if v < best.residual - 1e-9 || (abs(v - best.residual) < 1e-9 && abs(dx) + abs(dy) < abs(best.dx) + abs(best.dy)) {
                            best.dx = dx; best.dy = dy; best.residual = v
                        }
                    }
                }
                return best
            }
        }
    }

    struct RegionChange: Sendable, Equatable {
        var mean: Double
        var fraction: Double
    }

    /// Change inside `rect` (thumbnail pixels x0..<x1, y0..<y1; nil = whole frame) after applying the
    /// alignment. Each pixel takes the smallest difference against the reference's 3x3 neighbourhood,
    /// so sub-pixel jitter does not count.
    static func regionChange(current c: SceneThumb, reference r: SceneThumb, rect: (x0: Int, y0: Int, x1: Int, y1: Int)?,
                             alignment a: Alignment, pixelDelta: Int) -> RegionChange {
        guard c.width == r.width, c.height == r.height else { return RegionChange(mean: 255, fraction: 1) }
        let box = rect ?? (0, 0, c.width, c.height)
        let off = Int(a.offset.rounded())
        let w = c.width, h = c.height
        var sum = 0, n = 0, changed = 0
        c.pixels.withUnsafeBufferPointer { cp in
            r.pixels.withUnsafeBufferPointer { rp in
                for y in max(0, box.y0)..<min(h, box.y1) {
                    for x in max(0, box.x0)..<min(w, box.x1) {
                        let cv = Int(cp[y * w + x]) - off
                        var best = Int.max
                        let ry0 = max(0, y + a.dy - 1), ry1 = min(h - 1, y + a.dy + 1)
                        let rx0 = max(0, x + a.dx - 1), rx1 = min(w - 1, x + a.dx + 1)
                        if ry0 <= ry1 && rx0 <= rx1 {
                            for ry in ry0...ry1 {
                                for rx in rx0...rx1 {
                                    let d = cv - Int(rp[ry * w + rx])
                                    let ad = d < 0 ? -d : d
                                    if ad < best { best = ad }
                                }
                            }
                        }
                        guard best != Int.max else { continue }
                        sum += best
                        n += 1
                        if best > pixelDelta { changed += 1 }
                    }
                }
            }
        }
        guard n > 0 else { return RegionChange(mean: 0, fraction: 0) }
        return RegionChange(mean: Double(sum) / Double(n), fraction: Double(changed) / Double(n))
    }

    /// Updates the reference: pixels within `pixelDelta` (after `offset`) and pixels inside `boxes`
    /// take the current value; other changed pixels keep the old reference.
    static func absorb(current c: SceneThumb, into r: SceneThumb, offset: Double, pixelDelta: Int, boxes: [CGRect]) -> SceneThumb {
        guard c.width == r.width, c.height == r.height else { return c }
        var out = r
        let off = Int(offset.rounded())
        for i in 0..<c.pixels.count where abs(Int(c.pixels[i]) - Int(r.pixels[i]) - off) <= pixelDelta {
            out.pixels[i] = c.pixels[i]
        }
        for box in boxes {
            let p = pixelRect(box, width: c.width, height: c.height)
            for y in p.y0..<p.y1 { for x in p.x0..<p.x1 { out.pixels[y * c.width + x] = c.pixels[y * c.width + x] } }
        }
        return out
    }

    /// A Vision-normalized (bottom-left) box to thumbnail pixels (top-left), at least 1x1.
    static func pixelRect(_ box: CGRect, width: Int, height: Int) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let top = ScanGeometry.visionToTopLeft(box)
        let x0 = max(0, min(width - 1, Int((top.minX * CGFloat(width)).rounded(.down))))
        let y0 = max(0, min(height - 1, Int((top.minY * CGFloat(height)).rounded(.down))))
        let x1 = max(x0 + 1, min(width, Int((top.maxX * CGFloat(width)).rounded(.up))))
        let y1 = max(y0 + 1, min(height, Int((top.maxY * CGFloat(height)).rounded(.up))))
        return (x0, y0, x1, y1)
    }
}

/// Foreground instance mask (one label per pixel, 0 = background) to one box per instance.
enum InstanceBoxes {
    /// Vision-normalized (bottom-left origin) boxes for each label in `labels`, largest first. The mask
    /// rows are top-first, `rowBytes` apart.
    static func boxes(mask: UnsafeBufferPointer<UInt8>, width: Int, height: Int, rowBytes: Int, labels: [Int]) -> [CGRect] {
        guard width > 0, height > 0, !labels.isEmpty else { return [] }
        let wanted = Set(labels)
        var minX = [Int: Int](), minY = [Int: Int](), maxX = [Int: Int](), maxY = [Int: Int]()
        for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width {
                let l = Int(mask[row + x])
                guard l != 0, wanted.contains(l) else { continue }
                minX[l] = min(minX[l] ?? x, x); maxX[l] = max(maxX[l] ?? x, x)
                minY[l] = min(minY[l] ?? y, y); maxY[l] = max(maxY[l] ?? y, y)
            }
        }
        let w = CGFloat(width), h = CGFloat(height)
        return labels.compactMap { l -> CGRect? in
            guard let x0 = minX[l], let x1 = maxX[l], let y0 = minY[l], let y1 = maxY[l] else { return nil }
            let top = CGRect(x: CGFloat(x0) / w, y: CGFloat(y0) / h,
                             width: CGFloat(x1 + 1 - x0) / w, height: CGFloat(y1 + 1 - y0) / h)
            return CGRect(x: top.minX, y: 1 - top.maxY, width: top.width, height: top.height)
        }
        .sorted { $0.width * $0.height > $1.width * $1.height }
    }

    static func boxes(labels mask: [UInt8], width: Int, height: Int, instances: [Int]) -> [CGRect] {
        mask.withUnsafeBufferPointer { boxes(mask: $0, width: width, height: height, rowBytes: width, labels: instances) }
    }
}
