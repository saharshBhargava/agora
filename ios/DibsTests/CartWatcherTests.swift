import CoreGraphics
import XCTest
@testable import Dibs

final class CartWatcherTests: XCTestCase {
    private let apple = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2)
    private let milk = CGRect(x: 0.05, y: 0.6, width: 0.2, height: 0.3)

    private func obs(_ t: Double, _ box: CGRect?, hand: Bool = false, change: Double = 0) -> CartWatcher.Observation {
        .init(time: t, box: box, handPresent: hand, changeFraction: change)
    }

    private func obs(_ t: Double, boxes: [CGRect]) -> CartWatcher.Observation {
        .init(time: t, boxes: boxes, handPresent: false, changeFraction: 0)
    }

    /// Feeds `boxes` every 0.1 s; returns all triggers in order.
    private func feedMany(_ w: inout CartWatcher, _ boxes: [CGRect], from start: Double, seconds: Double) -> [CGRect] {
        var out: [CGRect] = []
        for i in 0...Int((seconds / 0.1).rounded()) {
            for d in w.observe(obs(start + Double(i) * 0.1, boxes: boxes)) { if case .trigger(let b) = d { out.append(b) } }
        }
        return out
    }

    /// Feeds `box` every 0.1 s from `start` for `seconds`; returns the triggers seen.
    @discardableResult
    private func feed(_ w: inout CartWatcher, _ box: CGRect?, from start: Double, seconds: Double, hand: Bool = false) -> [CGRect] {
        var out: [CGRect] = []
        let steps = Int((seconds / 0.1).rounded())
        for i in 0...steps {
            for d in w.observe(obs(start + Double(i) * 0.1, box, hand: hand)) { if case .trigger(let b) = d { out.append(b) } }
        }
        return out
    }

    func testTriggersOnceAfterOneSecondStill() {
        var w = CartWatcher()
        for i in 0..<10 {
            XCTAssertEqual(w.observe(obs(Double(i) * 0.1, apple)), [.settling(elapsed: Double(i) * 0.1)], "t=\(i)")
        }
        XCTAssertEqual(w.observe(obs(1.0, apple)), [.trigger(apple)])
        XCTAssertEqual(w.settled, [apple])
        XCTAssertTrue(feed(&w, apple, from: 1.1, seconds: 5).isEmpty)
    }

    func testNoTriggerWhileHandPresent() {
        var w = CartWatcher()
        XCTAssertEqual(w.observe(obs(0, apple, hand: true)), [.handPresent])
        XCTAssertTrue(feed(&w, apple, from: 0, seconds: 3, hand: true).isEmpty)
        // The hand leaves: the clock starts again from then.
        XCTAssertEqual(w.observe(obs(3.25, apple)), [.settling(elapsed: 0)])
        XCTAssertEqual(w.observe(obs(3.75, apple)), [.settling(elapsed: 0.5)])
        XCTAssertEqual(w.observe(obs(4.25, apple)), [.trigger(apple)])
    }

    func testHandMidwayResetsStillness() {
        var w = CartWatcher()
        feed(&w, apple, from: 0, seconds: 0.8)
        _ = w.observe(obs(0.9, apple, hand: true))
        XCTAssertEqual(w.observe(obs(1.0, apple)), [.settling(elapsed: 0)])
    }

    func testSameBoxDoesNotTriggerTwiceEvenWithJitter() {
        var w = CartWatcher()
        XCTAssertEqual(feed(&w, apple, from: 0, seconds: 1), [apple])
        let nudged = apple.offsetBy(dx: 0.03, dy: 0.02)   // IoU with apple still >= 0.5
        XCTAssertGreaterThanOrEqual(CartWatcher.iou(apple, nudged), 0.5)
        XCTAssertTrue(feed(&w, nudged, from: 1.1, seconds: 3).isEmpty)
        XCTAssertEqual(w.observe(obs(4.2, nudged)), [.known])
    }

    func testNewBoxTriggersAfterSettledOne() {
        var w = CartWatcher()
        XCTAssertEqual(feed(&w, apple, from: 0, seconds: 1), [apple])
        XCTAssertEqual(feed(&w, milk, from: 1.1, seconds: 1), [milk])
        XCTAssertEqual(w.settled, [apple, milk])
    }

    func testMovingBoxNeverSettles() {
        var w = CartWatcher()
        for i in 0..<30 {
            // Slides 0.04 per observation: IoU frame to frame ~0.67 < 0.8.
            let box = apple.offsetBy(dx: CGFloat(i % 10) * 0.04 - 0.2, dy: 0)
            if w.observe(obs(Double(i) * 0.1, box)).contains(where: { if case .trigger = $0 { true } else { false } }) { XCTFail("triggered at \(i)") }
        }
    }

    func testLargeChangeRebaselines() {
        var w = CartWatcher()
        XCTAssertEqual(feed(&w, apple, from: 0, seconds: 1), [apple])
        XCTAssertEqual(w.observe(obs(1.1, apple, change: 0.61)), [.rebaseline])
        XCTAssertTrue(w.settled.isEmpty)
        XCTAssertEqual(w.observe(obs(1.2, apple, change: 0.6)), [.settling(elapsed: 0)], "0.6 is not above the threshold")
    }

    func testRebaselineWinsOverHandAndDoesNotTrigger() {
        var w = CartWatcher()
        for i in 0..<20 {
            XCTAssertEqual(w.observe(obs(Double(i) * 0.1, apple, hand: true, change: 0.9)), [.rebaseline])
        }
    }

    func testInitialSceneBecomesBaselineWhenDisabled() {
        var w = CartWatcher(triggerOnInitialScene: false)
        XCTAssertTrue(feed(&w, apple, from: 0, seconds: 2).isEmpty)
        XCTAssertEqual(w.settled, [apple])
        XCTAssertEqual(feed(&w, milk, from: 2.1, seconds: 1), [milk])
        // After a rebaseline the next scene is the baseline again.
        XCTAssertEqual(w.observe(obs(3.3, milk, change: 0.9)), [.rebaseline])
        var baselined = false
        for i in 0...10 { if case .baselined = w.observe(obs(3.4 + Double(i) * 0.1, milk)).first { baselined = true } }
        XCTAssertTrue(baselined)
    }

    func testInitialSceneTriggersByDefault() {
        var w = CartWatcher()
        XCTAssertTrue(w.triggerOnInitialScene)
        XCTAssertEqual(feed(&w, apple, from: 0, seconds: 1), [apple])
    }

    func testWholeSceneAndSpeckBoxesIgnored() {
        var w = CartWatcher()
        XCTAssertTrue(feed(&w, CGRect(x: 0, y: 0, width: 0.9, height: 0.9), from: 0, seconds: 2).isEmpty)
        XCTAssertTrue(feed(&w, CGRect(x: 0.5, y: 0.5, width: 0.05, height: 0.05), from: 2.1, seconds: 2).isEmpty)
        XCTAssertEqual(w.observe(obs(4.5, nil)), [.empty])
    }

    func testEmptyFramesBeyondGraceResetStillness() {
        var w = CartWatcher()
        feed(&w, apple, from: 0, seconds: 0.8)
        for t in [0.9, 1.0, 1.1] { XCTAssertEqual(w.observe(obs(t, nil)), [.empty]) }
        XCTAssertEqual(w.observe(obs(1.25, apple)), [.settling(elapsed: 0)])
    }

    func testOneMissedFrameKeepsTheTrack() {
        var w = CartWatcher()
        feed(&w, apple, from: 0, seconds: 0.5)
        XCTAssertEqual(w.observe(obs(0.6, nil)), [.empty])
        XCTAssertEqual(feed(&w, apple, from: 0.7, seconds: 0.3), [apple], "still triggers at 1.0 s")
    }

    // MARK: several items

    private let can = CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.3)

    func testTwoItemsInViewTogetherTriggerTwiceThenStayQuiet() {
        var w = CartWatcher()
        let triggers = feedMany(&w, [apple, can], from: 0, seconds: 1)
        XCTAssertEqual(Set(triggers.map { "\($0)" }), Set([apple, can].map { "\($0)" }))
        XCTAssertEqual(triggers.count, 2)
        XCTAssertTrue(feedMany(&w, [can, apple], from: 1.1, seconds: 5).isEmpty, "order swaps do not re-trigger")
        XCTAssertEqual(w.observe(obs(6.2, boxes: [apple, can])), [.known])
    }

    func testSecondItemArrivingLaterTriggersOnItsOwnClock() {
        var w = CartWatcher()
        XCTAssertEqual(feedMany(&w, [apple], from: 0, seconds: 0.5), [])
        XCTAssertEqual(w.observe(obs(0.6, boxes: [apple, can])), [.settling(elapsed: 0.6)])
        XCTAssertEqual(feedMany(&w, [apple, can], from: 0.7, seconds: 0.3), [apple])
        XCTAssertEqual(feedMany(&w, [apple, can], from: 1.1, seconds: 0.4), [])
        XCTAssertEqual(feedMany(&w, [apple, can], from: 1.6, seconds: 0), [can])
    }

    func testOverlappingBoxesMergeIntoOne() {
        var w = CartWatcher()
        let near = apple.offsetBy(dx: 0.02, dy: 0)    // IoU ~0.82 > 0.5: same item
        XCTAssertEqual(feedMany(&w, [apple, near], from: 0, seconds: 2), [apple])
    }

    func testAtMostThreeBoxesTracked() {
        var w = CartWatcher()
        let boxes = (0..<5).map { CGRect(x: Double($0) * 0.2, y: 0.1, width: 0.15, height: 0.15) }
        XCTAssertEqual(feedMany(&w, boxes, from: 0, seconds: 1), Array(boxes.prefix(3)))
    }

    func testGroupBoxAroundTwoItemsIsDropped() {
        var w = CartWatcher()
        // Saliency's top box covers both items; the two items also come back as their own boxes.
        let group = apple.union(can)
        XCTAssertGreaterThan(group.width * group.height, 2.5 * apple.width * apple.height)
        let triggers = feedMany(&w, [group, apple, can], from: 0, seconds: 2)
        XCTAssertEqual(triggers.count, 2)
        XCTAssertFalse(triggers.contains(group))
    }

    func testBoxAreaLimits() {
        var w = CartWatcher()
        XCTAssertEqual(feedMany(&w, [CGRect(x: 0, y: 0, width: 0.1, height: 0.19)], from: 0, seconds: 2), [], "1.9% is too small")
        XCTAssertEqual(feedMany(&w, [CGRect(x: 0, y: 0, width: 0.9, height: 0.8)], from: 2.1, seconds: 2), [], "72% is the whole scene")
        let ok = CGRect(x: 0, y: 0, width: 0.1, height: 0.21)
        XCTAssertEqual(feedMany(&w, [ok], from: 4.2, seconds: 1), [ok])
    }

    func testIoU() {
        let a = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(CartWatcher.iou(a, a), 1)
        XCTAssertEqual(CartWatcher.iou(a, CGRect(x: 2, y: 2, width: 1, height: 1)), 0)
        XCTAssertEqual(CartWatcher.iou(a, CGRect(x: 0.5, y: 0, width: 1, height: 1)), 1.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(CartWatcher.iou(a, .zero), 0)
    }

    func testSceneDiffChangeFraction() {
        let base = [UInt8](repeating: 100, count: 1024)
        XCTAssertEqual(SceneDiff.changeFraction(previous: nil, current: base), 0)
        XCTAssertEqual(SceneDiff.changeFraction(previous: base, current: base), 0)
        var cur = base
        for i in 0..<512 { cur[i] = 131 }          // delta 31 > 30
        for i in 512..<600 { cur[i] = 130 }        // delta 30, not counted
        XCTAssertEqual(SceneDiff.changeFraction(previous: base, current: cur), 0.5)
        XCTAssertEqual(SceneDiff.changeFraction(previous: [1, 2], current: base), 0, "size mismatch is no change")
    }
}
