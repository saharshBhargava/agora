import CoreGraphics
import XCTest
@testable import Dibs

/// A synthetic 54x96 scene: a textured floor with bright items, viewed through a camera offset.
private struct Scene {
    static let w = 54, h = 96
    /// Items in floor (world) pixels, top-left origin.
    var items: [(x: Int, y: Int, w: Int, h: Int)]
    /// Camera offset in pixels: thumbnail pixel (x, y) shows world (x + sx, y + sy).
    var sx = 0, sy = 0
    var brightness = 0
    var texture = 0

    func world(_ x: Int, _ y: Int) -> Int {
        for it in items where x >= it.x && x < it.x + it.w && y >= it.y && y < it.y + it.h {
            return 225 - ((x + y) % 3) * 8
        }
        let fx = Double(x), fy = Double(y), t = Double(texture)
        return Int(110 + 45 * sin(0.37 * fx + 0.11 * fy + t) + 35 * cos(0.23 * fy - 0.17 * fx + 2 * t) + 12 * sin(0.9 * fx) * cos(0.7 * fy))
    }

    var thumb: SceneThumb {
        var px = [UInt8](repeating: 0, count: Self.w * Self.h)
        for y in 0..<Self.h {
            for x in 0..<Self.w { px[y * Self.w + x] = UInt8(max(0, min(255, world(x + sx, y + sy) + brightness))) }
        }
        return SceneThumb(width: Self.w, height: Self.h, pixels: px)
    }

    /// Vision-normalized box (bottom-left origin) of a world rect as this camera sees it.
    func box(_ r: (x: Int, y: Int, w: Int, h: Int)) -> CGRect {
        let tlx = Double(r.x - sx) / Double(Self.w), tly = Double(r.y - sy) / Double(Self.h)
        let bw = Double(r.w) / Double(Self.w), bh = Double(r.h) / Double(Self.h)
        return CGRect(x: tlx, y: 1 - tly - bh, width: bw, height: bh)
    }

    func box(item i: Int) -> CGRect { box(items[i]) }
}

final class CartWatcherTests: XCTestCase {
    // A can on the left, an apple on the right (world pixels in a 54x96 thumbnail).
    private let can = (x: 6, y: 30, w: 12, h: 24)
    private let apple = (x: 32, y: 40, w: 14, h: 14)
    private let milk = (x: 20, y: 66, w: 14, h: 18)

    private func feed(_ w: inout CartWatcher, _ scene: Scene, _ boxes: [CGRect], from start: Double, seconds: Double,
                      hand: Bool = false, distance: (CGRect, Int) -> Double? = { _, _ in nil }) -> [CartWatcher.Decision] {
        var out: [CartWatcher.Decision] = []
        let thumb = scene.thumb
        for i in 0...Int((seconds / 0.1).rounded()) {
            out += w.observe(.init(time: start + Double(i) * 0.1, boxes: boxes, handPresent: hand, thumb: thumb), distance: distance)
        }
        return out
    }

    private func removals(_ ds: [CartWatcher.Decision]) -> [String] {
        ds.compactMap { if case .removed(let c, _) = $0 { c } else { nil } }
    }

    private func moves(_ ds: [CartWatcher.Decision]) -> [CGRect] {
        ds.compactMap { if case .moved(_, _, let b) = $0 { b } else { nil } }
    }

    /// Can and apple at start, with chips "can" and "apple" attached to their items.
    private func startWithChips() -> (CartWatcher, Scene) {
        var (w, scene) = startWithCanAndApple()
        XCTAssertEqual(w.items.count, 2)
        w.attach(chipId: "can", toItem: w.itemId(for: scene.box(item: 0))!)
        w.attach(chipId: "apple", toItem: w.itemId(for: scene.box(item: 1))!)
        return (w, scene)
    }

    private func triggers(_ ds: [CartWatcher.Decision]) -> [CGRect] {
        ds.compactMap { if case .trigger(let b) = $0 { b } else { nil } }
    }

    /// Two items in view at start: two triggers, then the reference is taken. Returns the watcher.
    private func startWithCanAndApple(_ initial: Bool = true) -> (CartWatcher, Scene) {
        var w = CartWatcher(triggerOnInitialScene: initial)
        let scene = Scene(items: [can, apple])
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 0, seconds: 2.5)
        XCTAssertTrue(ds.contains(.referenceTaken))
        XCTAssertTrue(w.watching)
        return (w, scene)
    }

    // MARK: initial scene

    func testTwoInitialItemsTriggerOnceEach() {
        var w = CartWatcher()
        let scene = Scene(items: [can, apple])
        let boxes = [scene.box(item: 0), scene.box(item: 1)]
        XCTAssertEqual(feed(&w, scene, boxes, from: 0, seconds: 0.9), Array(repeating: .settling(elapsed: 0), count: 1) + (1...9).map { .settling(elapsed: Double($0) * 0.1) })
        XCTAssertEqual(w.observe(.init(time: 1.0, boxes: boxes, handPresent: false, thumb: scene.thumb)), [.trigger(boxes[0]), .trigger(boxes[1])])
        let rest = feed(&w, scene, boxes.reversed(), from: 1.1, seconds: 6)
        XCTAssertEqual(triggers(rest), [])
        XCTAssertEqual(rest.filter { $0 == .referenceTaken }.count, 1, "reference taken once, after 2 s still")
    }

    func testInitialSceneKeptSilentlyWhenDisabled() {
        var (w, scene) = startWithCanAndApple(false)
        XCTAssertEqual(w.settled.count, 2)
        scene.items.append(milk)
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1), scene.box(item: 2)], from: 2.6, seconds: 1.5)
        XCTAssertEqual(triggers(ds), [scene.box(item: 2)])
    }

    func testInitialStaggeredSettlesStillTrigger() {
        var w = CartWatcher()
        let scene = Scene(items: [can, apple])
        var ds = feed(&w, scene, [scene.box(item: 0)], from: 0, seconds: 0.7)
        ds += feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 0.8, seconds: 3)
        XCTAssertEqual(triggers(ds), [scene.box(item: 0), scene.box(item: 1)])
    }

    // MARK: watching: only real pixel change triggers

    func testFlickeringAndMergingBoxesOverSamePixelsNeverTrigger() {
        var (w, scene) = startWithCanAndApple()
        let a = scene.box(item: 0), b = scene.box(item: 1)
        let configs: [[CGRect]] = [
            [a.union(b)],                                             // one box around both
            [a.offsetBy(dx: 0.08, dy: 0.03), b.offsetBy(dx: -0.06, dy: -0.04)],   // separate, moved
            [a.insetBy(dx: -0.05, dy: -0.04), b.insetBy(dx: 0.02, dy: 0.02)],
            [a.union(b).insetBy(dx: -0.04, dy: -0.04)],
            [CGRect(x: 0.3, y: 0.05, width: 0.3, height: 0.2)],       // floor only
        ]
        var t = 2.6
        var all: [CartWatcher.Decision] = []
        for _ in 0..<3 {
            for c in configs {
                all += feed(&w, scene, c, from: t, seconds: 1.5)
                t += 1.6
            }
        }
        XCTAssertEqual(triggers(all), [])
        XCTAssertTrue(all.contains { if case .unchanged = $0 { true } else { false } })
    }

    func testNewItemTriggersOnceWhenItsPixelsChange() {
        var (w, scene) = startWithCanAndApple()
        scene.items.append(milk)
        let boxes = [scene.box(item: 0), scene.box(item: 1), scene.box(item: 2)]
        let ds = feed(&w, scene, boxes, from: 2.6, seconds: 5)
        XCTAssertEqual(triggers(ds), [scene.box(item: 2)])
    }

    func testNewItemNextToOldOnesWithMergedBoxTriggersOnce() {
        var (w, scene) = startWithCanAndApple()
        scene.items.append(milk)
        // Saliency boxes everything as one blob, then the milk alone.
        let blob = scene.box(item: 0).union(scene.box(item: 1)).union(scene.box(item: 2))
        var ds = feed(&w, scene, [blob], from: 2.6, seconds: 1.5)
        ds += feed(&w, scene, [scene.box(item: 2)], from: 4.2, seconds: 2)
        XCTAssertEqual(triggers(ds), [scene.box(item: 2)], "the blob is mostly unchanged; the milk alone triggers")
    }

    func testNoTriggerWhileHandPresentThenTriggerAfter() {
        var (w, scene) = startWithCanAndApple()
        scene.items.append(milk)
        let boxes = [scene.box(item: 2)]
        XCTAssertEqual(triggers(feed(&w, scene, boxes, from: 2.6, seconds: 3, hand: true)), [])
        XCTAssertEqual(triggers(feed(&w, scene, boxes, from: 5.7, seconds: 1.2)), [scene.box(item: 2)])
    }

    // MARK: camera shifts and scene changes

    func testSmallCameraShiftIsCompensatedWithoutTriggers() {
        var (w, scene) = startWithCanAndApple()
        scene.sx = 2
        scene.sy = -1
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 2.6, seconds: 4)
        XCTAssertEqual(triggers(ds), [])
        XCTAssertFalse(ds.contains { if case .cameraShift = $0 { true } else { false } }, "jitter-sized shifts do not rebaseline")
        let merged = scene.box(item: 0).union(scene.box(item: 1))
        XCTAssertEqual(triggers(feed(&w, scene, [merged], from: 6.7, seconds: 3)), [])
    }

    func testLargerCameraShiftRebaselinesWithoutTriggers() {
        var (w, scene) = startWithCanAndApple()
        scene.sx = 4
        scene.sy = -1
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 2.6, seconds: 4)
        XCTAssertEqual(triggers(ds), [])
        XCTAssertTrue(ds.contains(.cameraShift(dx: 4, dy: -1)), "\(ds.prefix(3))")
        // Settled boxes followed the shift.
        XCTAssertEqual(w.settled[0].minX, scene.box(item: 0).minX, accuracy: 1e-9)
        XCTAssertEqual(w.settled[0].minY, scene.box(item: 0).minY, accuracy: 1e-9)
        let merged = scene.box(item: 0).union(scene.box(item: 1))
        XCTAssertEqual(triggers(feed(&w, scene, [merged], from: 6.7, seconds: 3)), [])
    }

    // MARK: device run 4: hand flicker and hand-held jitter must not block hands-free adds

    /// Feeds one observation per 0.1 s with a per-step scene, boxes and hands.
    private func run(_ w: inout CartWatcher, from start: Double, steps: Int,
                     _ frame: (Int) -> (scene: Scene, boxes: [CGRect], hands: [CGRect])) -> [CartWatcher.Decision] {
        var out: [CartWatcher.Decision] = []
        for i in 0..<steps {
            let f = frame(i)
            out += w.observe(.init(time: start + Double(i) * 0.1, boxes: f.boxes, handPresent: false, thumb: f.scene.thumb, hands: f.hands))
        }
        return out
    }

    func testDeviceRun4HandFlickerAndJitterStillAddEveryItemOnce() {
        var w = CartWatcher()
        // A hand (or a false "hand") flickering in the lower corner, on and off every 100-300 ms.
        let hand = CGRect(x: 0.76, y: 0.0, width: 0.2, height: 0.15)   // clear of every item, margin included
        let flicker: (Int) -> [CGRect] = { i in [0, 1, 4, 5, 6, 9].contains(i % 10) ? [hand] : [] }
        // Phone held in the hand: the view wobbles by a pixel.
        func scene(_ items: [(x: Int, y: Int, w: Int, h: Int)], _ i: Int) -> Scene {
            var s = Scene(items: items)
            s.sx = [0, 1, 1, 0][i % 4]
            return s
        }
        // Can and apple in view at start: each triggers once, within 1.5 s, despite the hand flicker.
        let start = run(&w, from: 0, steps: 15) { i in
            let s = scene([self.can, self.apple], i)
            return (s, [Scene(items: [self.can, self.apple]).box(item: 0), Scene(items: [self.can, self.apple]).box(item: 1)], flicker(i))
        }
        XCTAssertEqual(triggers(start).count, 2, "\(start)")
        // Keep going until watching starts (time cap even if the wobble never fully stops).
        let mid = run(&w, from: 1.5, steps: 60) { i in
            let s = scene([self.can, self.apple], i)
            return (s, [Scene(items: [self.can, self.apple]).box(item: 0), Scene(items: [self.can, self.apple]).box(item: 1)], flicker(i))
        }
        XCTAssertEqual(triggers(mid), [])
        XCTAssertTrue(w.watching)
        // An apple-sized item placed later triggers once after ~1 s, hands free, with flicker and wobble.
        let later = run(&w, from: 7.6, steps: 40) { i in
            let items = [self.can, self.apple, self.milk]
            let base = Scene(items: items)
            return (scene(items, i), [base.box(item: 0), base.box(item: 1), base.box(item: 2)], flicker(i))
        }
        XCTAssertEqual(triggers(later), [Scene(items: [can, apple, milk]).box(item: 2)])
    }

    func testHandOverAnItemBlocksOnlyThatItem() {
        var (w, scene) = startWithCanAndApple()
        scene.items.append(milk)
        let milkBox = scene.box(item: 2)
        // A hand right over the milk: no trigger while it is there.
        let over = run(&w, from: 2.6, steps: 20) { _ in (scene, [scene.box(item: 0), scene.box(item: 1), milkBox], [milkBox]) }
        XCTAssertEqual(triggers(over), [])
        // Hand gone: the milk settles and triggers.
        let after = run(&w, from: 4.6, steps: 12) { _ in (scene, [scene.box(item: 0), scene.box(item: 1), milkBox], []) }
        XCTAssertEqual(triggers(after), [milkBox])
    }

    func testBrightnessChangeDoesNotTrigger() {
        var (w, scene) = startWithCanAndApple()
        scene.brightness = 18
        let ds = feed(&w, scene, [scene.box(item: 0).union(scene.box(item: 1))], from: 2.6, seconds: 3)
        XCTAssertEqual(triggers(ds), [])
    }

    func testWholeNewSceneRebaselinesAndDoesNotRetriggerItems() {
        var (w, scene) = startWithCanAndApple()
        scene.texture = 3
        scene.sx = 4
        scene.items = [(x: 10, y: 10, w: 14, h: 20), (x: 30, y: 60, w: 16, h: 16)]
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 2.6, seconds: 5)
        XCTAssertEqual(triggers(ds), [], "initial-scene triggering happens once per watcher")
        XCTAssertTrue(ds.contains(.rebaseline) || ds.contains(.motion))
        XCTAssertEqual(w.reference, scene.thumb, "reference retaken on the new scene")
    }

    // MARK: box filters

    func testCornerAndTinyBoxesIgnored() {
        var w = CartWatcher()
        let corner = (x: 0, y: 70, w: 11, h: 26)    // touches left and bottom
        let scene = Scene(items: [corner, (x: 30, y: 10, w: 6, h: 10)])
        let cornerBox = scene.box(item: 0)
        XCTAssertGreaterThanOrEqual(CartWatcher.edgesTouched(cornerBox, margin: 0.008), 2)
        XCTAssertLessThan(scene.box(item: 1).width * scene.box(item: 1).height, 0.03)
        XCTAssertEqual(triggers(feed(&w, scene, [cornerBox, scene.box(item: 1)], from: 0, seconds: 3)), [])
    }

    func testOneEdgeBoxStillCounts() {
        var w = CartWatcher()
        let scene = Scene(items: [(x: 0, y: 20, w: 20, h: 40)])
        XCTAssertEqual(triggers(feed(&w, scene, [scene.box(item: 0)], from: 0, seconds: 2)), [scene.box(item: 0)])
    }

    func testGroupBoxAroundTwoItemsIsDropped() {
        var w = CartWatcher()
        let scene = Scene(items: [can, apple])
        let a = scene.box(item: 0), b = scene.box(item: 1)
        let group = a.union(b)
        XCTAssertGreaterThan(group.width * group.height, 2.5 * max(a.width * a.height, b.width * b.height))
        let t = triggers(feed(&w, scene, [group, a, b], from: 0, seconds: 2))
        XCTAssertEqual(t, [a, b])
    }

    func testOverlappingBoxesMergeAndCapAtFour() {
        var w = CartWatcher()
        let items = (0..<5).map { (x: 1 + $0 * 10, y: 10, w: 9, h: 20) }
        let scene = Scene(items: items)
        let boxes = items.indices.map { scene.box(item: $0) }
        let near = boxes[0].offsetBy(dx: 0.01, dy: 0)
        XCTAssertEqual(triggers(feed(&w, scene, [boxes[0], near] + boxes.dropFirst(), from: 0, seconds: 2)), Array(boxes.prefix(4)))
    }

    // MARK: instance boxes

    private func feedInstances(_ w: inout CartWatcher, _ scene: Scene, instances: [CGRect], saliency: [CGRect],
                               from start: Double, seconds: Double) -> [CartWatcher.Decision] {
        var out: [CartWatcher.Decision] = []
        let thumb = scene.thumb
        for i in 0...Int((seconds / 0.1).rounded()) {
            out += w.observe(.init(time: start + Double(i) * 0.1, boxes: saliency, handPresent: false, thumb: thumb, instances: instances))
        }
        return out
    }

    private let three = [(x: 4, y: 40, w: 12, h: 16), (x: 18, y: 40, w: 12, h: 16), (x: 32, y: 40, w: 14, h: 16)]

    func testThreeAdjacentItemsFromInstancesTriggerSeparately() {
        var w = CartWatcher()
        let scene = Scene(items: three)
        let inst = three.indices.map { scene.box(item: $0) }
        let merged = inst.dropFirst().reduce(inst[0]) { $0.union($1) }   // what saliency reports
        let ds = feedInstances(&w, scene, instances: inst, saliency: [merged], from: 0, seconds: 3)
        XCTAssertEqual(triggers(ds), inst)
    }

    func testSaliencyIsTheFallbackWithoutInstances() {
        var w = CartWatcher()
        let scene = Scene(items: three)
        let a = scene.box(item: 0)
        XCTAssertEqual(triggers(feedInstances(&w, scene, instances: [], saliency: [a], from: 0, seconds: 2)), [a])
    }

    func testBigBoxIsSplitIntoTheInstancesInsideIt() {
        var w = CartWatcher()
        let scene = Scene(items: three)
        let inner = three.indices.map { scene.box(item: $0) }
        let big = scene.box((x: 2, y: 20, w: 48, h: 60))
        XCTAssertGreaterThan(big.width * big.height, 0.35)
        XCTAssertEqual(triggers(feedInstances(&w, scene, instances: [big] + inner, saliency: [], from: 0, seconds: 3)), inner)
        // One big instance with the items only seen by saliency: the saliency boxes inside it are used.
        var w2 = CartWatcher()
        XCTAssertEqual(triggers(feedInstances(&w2, scene, instances: [big], saliency: Array(inner.prefix(2)), from: 0, seconds: 3)),
                       Array(inner.prefix(2)))
        // Nothing inside: the big box stands.
        var w3 = CartWatcher()
        XCTAssertEqual(triggers(feedInstances(&w3, scene, instances: [big], saliency: [], from: 0, seconds: 3)), [big])
    }

    func testInstanceMaskToBoxes() {
        // 10x8 mask, rows top-first: label 1 at x 1..3, y 0..1; label 2 at x 5..9, y 4..7; label 3 ignored.
        var mask = [UInt8](repeating: 0, count: 80)
        for y in 0...1 { for x in 1...3 { mask[y * 10 + x] = 1 } }
        for y in 4...7 { for x in 5...9 { mask[y * 10 + x] = 2 } }
        mask[0] = 3
        let boxes = InstanceBoxes.boxes(labels: mask, width: 10, height: 8, instances: [1, 2])
        XCTAssertEqual(boxes.count, 2)
        // Largest first; Vision boxes have a bottom-left origin.
        XCTAssertEqual(boxes[0], CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(boxes[1], CGRect(x: 0.1, y: 0.75, width: 0.3, height: 0.25))
        XCTAssertEqual(InstanceBoxes.boxes(labels: mask, width: 10, height: 8, instances: []), [])
    }

    // MARK: tracking

    func testMovingBoxNeverSettlesAndMissedFrameIsTolerated() {
        var w = CartWatcher()
        let scene = Scene(items: [apple])
        let thumb = scene.thumb
        for i in 0..<20 {
            let box = scene.box(item: 0).offsetBy(dx: CGFloat(i % 10) * 0.04 - 0.2, dy: 0)
            XCTAssertEqual(triggers(w.observe(.init(time: Double(i) * 0.1, boxes: [box], handPresent: false, thumb: thumb))), [])
        }
        var w2 = CartWatcher()
        let b = scene.box(item: 0)
        var ds = feed(&w2, scene, [b], from: 0, seconds: 0.5)
        ds += w2.observe(.init(time: 0.6, boxes: [], handPresent: false, thumb: thumb))
        ds += feed(&w2, scene, [b], from: 0.7, seconds: 0.3)
        XCTAssertEqual(triggers(ds), [b])
    }

    func testFastMotionResetsTracks() {
        var (w, scene) = startWithCanAndApple()
        var inverted = scene.thumb
        inverted.pixels = inverted.pixels.map { 255 - $0 }
        XCTAssertEqual(w.observe(.init(time: 2.6, boxes: [], handPresent: false, thumb: inverted)), [.motion])
    }

    // MARK: removal

    func testItemTakenAwayIsRemovedOnceAfterTwoSeconds() {
        var (w, scene) = startWithChips()
        scene.items = [can]
        let ds = feed(&w, scene, [scene.box(item: 0)], from: 2.6, seconds: 1.8)
        XCTAssertEqual(removals(ds), [], "not before 2 s")
        let later = feed(&w, scene, [scene.box(item: 0)], from: 4.5, seconds: 5)
        XCTAssertEqual(removals(later), ["apple"])
        XCTAssertEqual(triggers(ds + later), [], "the emptied spot is not a new item")
    }

    func testBoxFlickerWhileItemStaysNeverRemoves() {
        var (w, scene) = startWithChips()
        let a = scene.box(item: 0), b = scene.box(item: 1)
        var all: [CartWatcher.Decision] = []
        var t = 2.6
        for c in [[a.union(b)], [a], [], [b.offsetBy(dx: 0.05, dy: 0)], []] {
            all += feed(&w, scene, c, from: t, seconds: 2.5)
            t += 2.6
        }
        XCTAssertEqual(removals(all), [])
        XCTAssertEqual(triggers(all), [])
    }

    func testHandPausesTheRemovalClock() {
        var (w, scene) = startWithChips()
        scene.items = [can]
        var ds = feed(&w, scene, [], from: 2.6, seconds: 1.5)
        ds += feed(&w, scene, [], from: 4.2, seconds: 4, hand: true)
        XCTAssertEqual(removals(ds), [])
        // 1.5 s before the hand (2.6...4.1, plus the step into it) + 0.4 s after it = 2 s: the hand time does not count.
        XCTAssertEqual(removals(feed(&w, scene, [], from: 8.3, seconds: 0.3)), [], "paused, not running")
        XCTAssertEqual(removals(feed(&w, scene, [], from: 8.7, seconds: 0.2)), ["apple"])
    }

    func testCameraShiftDoesNotRemove() {
        var (w, scene) = startWithChips()
        scene.sx = 3
        scene.sy = 2
        let ds = feed(&w, scene, [], from: 2.6, seconds: 6)
        XCTAssertEqual(removals(ds), [])
        XCTAssertTrue(ds.contains(.cameraShift(dx: 3, dy: 2)))
        XCTAssertEqual(w.items.first { $0.chipId == "apple" }?.box.minX ?? -1, scene.box(item: 1).minX, accuracy: 1e-9)
    }

    // MARK: moves

    func testMovedItemIsNotAddedOrRemoved() {
        var (w, scene) = startWithChips()
        let appleItem = w.itemId(for: scene.box(item: 1))!
        let movedApple = (x: 30, y: 72, w: 14, h: 14)
        scene.items = [can, movedApple]
        let newBox = scene.box(item: 1)
        var distances: [Double] = []
        let ds = feed(&w, scene, [scene.box(item: 0), newBox], from: 2.6, seconds: 6) { box, item in
            let d = item == appleItem && box == newBox ? 0.2 : 1.5
            distances.append(d)
            return d
        }
        XCTAssertEqual(triggers(ds), [])
        XCTAssertEqual(removals(ds), [])
        XCTAssertEqual(moves(ds), [newBox])
        XCTAssertTrue(ds.contains(.match(distance: 0.2, item: appleItem, chipId: "apple")))
        XCTAssertEqual(w.items.first { $0.id == appleItem }?.box, newBox)
    }

    func testItemMovedAfterRemovalIsRestored() {
        var (w, scene) = startWithChips()
        scene.items = [can]
        let gone = feed(&w, scene, [scene.box(item: 0)], from: 2.6, seconds: 2.5)
        XCTAssertEqual(removals(gone), ["apple"])
        scene.items = [can, (x: 30, y: 72, w: 14, h: 14)]
        let back = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 5.2, seconds: 2) { _, _ in 0.1 }
        XCTAssertEqual(triggers(back), [])
        XCTAssertEqual(back.filter { if case .restored(chipId: "apple", _) = $0 { true } else { false } }.count, 1)
    }

    func testDifferentItemWhileAnotherIsRemovedIsAddPlusRemove() {
        var (w, scene) = startWithChips()
        scene.items = [can, milk]          // apple out, milk in
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1)], from: 2.6, seconds: 4) { _, _ in 1.4 }
        XCTAssertEqual(triggers(ds), [scene.box(item: 1)])
        XCTAssertEqual(removals(ds), ["apple"])
    }

    func testTwoIdenticalCansAreTwoItems() {
        var (w, scene) = startWithChips()
        let secondCan = (x: 20, y: 66, w: 12, h: 24)
        scene.items = [can, apple, secondCan]
        let ds = feed(&w, scene, [scene.box(item: 0), scene.box(item: 1), scene.box(item: 2)], from: 2.6, seconds: 3) { _, _ in 0.05 }
        XCTAssertEqual(triggers(ds), [scene.box(item: 2)], "the first can is not missing, so no move")
        XCTAssertEqual(removals(ds), [])
    }

    // MARK: pixel helpers

    func testAlignFindsShiftAndRegionChangeIgnoresIt() {
        let a = Scene(items: [can]).thumb
        var s = Scene(items: [can])
        s.sx = 3; s.sy = 2
        let al = SceneDiff.align(current: s.thumb, reference: a, maxShift: 5)
        XCTAssertEqual(al.dx, 3)
        XCTAssertEqual(al.dy, 2)
        XCTAssertTrue(al.isShift)
        let whole = SceneDiff.regionChange(current: s.thumb, reference: a, rect: nil, alignment: al, pixelDelta: 25)
        XCTAssertLessThan(whole.fraction, 0.1)
        XCTAssertFalse(SceneDiff.align(current: a, reference: a, maxShift: 5).isShift)
    }

    func testRegionChangeSeesNewItemOnly() {
        let before = Scene(items: [can]).thumb
        let afterScene = Scene(items: [can, milk])
        let after = afterScene.thumb
        let al = SceneDiff.align(current: after, reference: before, maxShift: 5)
        XCTAssertFalse(al.isShift)
        let inMilk = SceneDiff.regionChange(current: after, reference: before,
                                            rect: SceneDiff.pixelRect(afterScene.box(item: 1), width: 54, height: 96), alignment: al, pixelDelta: 25)
        XCTAssertGreaterThan(inMilk.mean, 12)
        XCTAssertGreaterThan(inMilk.fraction, 0.15)
        let inCan = SceneDiff.regionChange(current: after, reference: before,
                                           rect: SceneDiff.pixelRect(afterScene.box(item: 0), width: 54, height: 96), alignment: al, pixelDelta: 25)
        XCTAssertLessThan(inCan.mean, 3)
    }

    func testIoUAndEdges() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(CartWatcher.iou(a, a), 1)
        XCTAssertEqual(CartWatcher.iou(a, CGRect(x: 2, y: 2, width: 1, height: 1)), 0)
        XCTAssertEqual(CartWatcher.iou(a, CGRect(x: 0.5, y: 0, width: 1, height: 1)), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(CartWatcher.edgesTouched(CGRect(x: 0.004, y: 0.002, width: 0.194, height: 0.269), margin: 0.008), 2)
        XCTAssertEqual(CartWatcher.edgesTouched(CGRect(x: 0, y: 0.354, width: 0.498, height: 0.633), margin: 0.008), 1)
    }
}

final class TapGateTests: XCTestCase {
    func testDebouncesTapsWithinTwoSeconds() {
        var g = TapGate()
        XCTAssertTrue(g.allow(CGPoint(x: 100, y: 100), at: 10, busy: []))
        XCTAssertFalse(g.allow(CGPoint(x: 300, y: 500), at: 10.165, busy: []), "double tap 165 ms later")
        XCTAssertFalse(g.allow(CGPoint(x: 300, y: 500), at: 11.9, busy: []))
        XCTAssertTrue(g.allow(CGPoint(x: 300, y: 500), at: 12.0, busy: []))
    }

    func testIgnoresTapsInsideARegionBeingIdentified() {
        var g = TapGate()
        let busy = [CGRect(x: 200, y: 200, width: 100, height: 100)]
        XCTAssertFalse(g.allow(CGPoint(x: 250, y: 250), at: 0, busy: busy))
        XCTAssertTrue(g.allow(CGPoint(x: 50, y: 50), at: 0.5, busy: busy), "an ignored tap does not start the debounce")
    }
}
