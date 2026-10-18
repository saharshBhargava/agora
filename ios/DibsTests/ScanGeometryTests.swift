import CoreGraphics
import XCTest
@testable import Dibs

final class ScanGeometryTests: XCTestCase {
    func testVisionToImageFlipsY() {
        let rect = ScanGeometry.visionToImage(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25), imageSize: CGSize(width: 1000, height: 2000))
        XCTAssertEqual(rect, CGRect(x: 250, y: 500, width: 500, height: 500))
    }

    func testCropRectPadsAndClamps() {
        let rect = ScanGeometry.cropRect(for: CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), imageSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 108, height: 108))
    }

    func testCropRectNilUsesCentre() {
        XCTAssertEqual(ScanGeometry.cropRect(for: nil, imageSize: CGSize(width: 1000, height: 2000)),
                       CGRect(x: 200, y: 400, width: 600, height: 1200))
    }

    func testCropRectEnforcesMinSide() {
        let size = CGSize(width: 1000, height: 1000)
        let rect = ScanGeometry.cropRect(for: CGRect(x: 0.5, y: 0.5, width: 0.01, height: 0.01), imageSize: size)
        XCTAssertEqual(rect.width, 64)
        XCTAssertEqual(rect.height, 64)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
    }

    func testSmootherHoldsThroughShortGaps() {
        var smoother = BoxSmoother()
        XCTAssertNotNil(smoother.update(CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        for _ in 0..<4 { XCTAssertNotNil(smoother.update(nil)) }
        XCTAssertNil(smoother.update(nil))
    }

    func testVisionToTopLeft() {
        XCTAssertEqual(ScanGeometry.visionToTopLeft(CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)),
                       CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25))
    }

    func testFillRectOverflowsOneAxis() {
        // A 3:4 portrait frame in a wide 400x300 box: width fills, height overflows and is centred.
        let r = ScanGeometry.fillRect(content: CGSize(width: 300, height: 400), in: CGSize(width: 400, height: 300))
        XCTAssertEqual(r.width, 400, accuracy: 1e-9)
        XCTAssertEqual(r.height, 533.333, accuracy: 0.001)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.minY, -116.667, accuracy: 0.001)
    }

    func testViewRectAndFramePointRoundTrip() {
        let content = CGSize(width: 640, height: 1138)
        let container = CGSize(width: 393, height: 500)
        let v = ScanGeometry.viewRect(normalized: CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1), content: content, in: container)
        XCTAssertEqual(v.minX, 196.5, accuracy: 0.001, "centre of the frame is the centre of the view")
        XCTAssertEqual(v.minY, 250, accuracy: 0.001)
        let p = ScanGeometry.framePoint(viewPoint: CGPoint(x: 196.5, y: 250), content: content, in: container)
        XCTAssertEqual(p, CGPoint(x: 320, y: 569))
        // Clamped to the frame.
        XCTAssertEqual(ScanGeometry.framePoint(viewPoint: CGPoint(x: -50, y: 9999), content: content, in: container),
                       CGPoint(x: 0, y: 1138))
    }
}
