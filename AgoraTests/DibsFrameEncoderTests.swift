import CoreVideo
import UIKit
import XCTest
@testable import Agora

final class DibsFrameEncoderTests: XCTestCase {
    func testLivestreamSendsFifteenFramesASecondFromAThirtyFpsCamera() {
        var last = -Double.infinity
        var sent = 0
        for i in 0..<60 { // two seconds of 30 fps presentation times, with a little jitter
            let t = Double(i) / 30 + (i % 2 == 0 ? 0.002 : -0.002)
            if FrameEncoder.shouldStream(at: t, lastStreamAt: last) {
                last = t
                sent += 1
            }
        }
        XCTAssertEqual(sent, 30)
    }

    /// A 1080x1920 BGRA frame, light gray, with a black square whose top-left (in top-left pixels) is `square`.
    private func frame(square: CGRect?) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1080, 1920, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<1920 {
            for x in 0..<1080 {
                let dark = square.map { $0.contains(CGPoint(x: x, y: y)) } ?? false
                let p = base + y * rowBytes + x * 4
                p[0] = dark ? 0 : 200; p[1] = dark ? 0 : 200; p[2] = dark ? 0 : 200; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func meanGray(_ jpeg: Data) -> Double {
        let cg = UIImage(data: jpeg)!.cgImage!
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Double(px.reduce(0) { $0 + Int($1) }) / Double(px.count)
    }

    func testStreamFrameIs640Wide() throws {
        let jpeg = try XCTUnwrap(FrameEncoder().streamJPEG(frame(square: nil)))
        let image = try XCTUnwrap(UIImage(data: jpeg))
        XCTAssertEqual(image.size, CGSize(width: 640, height: 1138))
        XCTAssertEqual(FrameEncoder.streamSize(for: CGSize(width: 1080, height: 1920)), CGSize(width: 640, height: 1138))
    }

    func testCropTakesTopLeftRectAndCapsLongSide() throws {
        // Dark square near the top: a top-left crop over it must be dark (checks the y flip).
        let square = CGRect(x: 100, y: 100, width: 400, height: 400)
        let buffer = frame(square: square)
        let enc = FrameEncoder()
        let top = try XCTUnwrap(enc.cropJPEG(buffer, rect: CGRect(x: 150, y: 150, width: 300, height: 300)))
        XCTAssertEqual(top.size, CGSize(width: 300, height: 300))
        XCTAssertLessThan(meanGray(top.data), 30)
        let bottom = try XCTUnwrap(enc.cropJPEG(buffer, rect: CGRect(x: 150, y: 1500, width: 300, height: 300)))
        XCTAssertGreaterThan(meanGray(bottom.data), 170)
        let big = try XCTUnwrap(enc.cropJPEG(buffer, rect: CGRect(x: 0, y: 0, width: 1080, height: 1920)))
        XCTAssertEqual(max(big.size.width, big.size.height), 1024)
        XCTAssertEqual(FrameEncoder.cropScale(for: CGSize(width: 500, height: 300)), 1)
    }

    func testCropOfVisionBoxEndToEnd() throws {
        // Vision box (bottom-left origin) for the square at top-left pixels (100,100,400,400) in 1080x1920.
        let box = CGRect(x: 100.0 / 1080, y: 1 - 500.0 / 1920, width: 400.0 / 1080, height: 400.0 / 1920)
        let rect = ScanGeometry.cropRect(for: box, imageSize: CGSize(width: 1080, height: 1920))
        XCTAssertEqual(rect, CGRect(x: 68, y: 68, width: 464, height: 464))
        let crop = try XCTUnwrap(FrameEncoder().cropJPEG(frame(square: CGRect(x: 100, y: 100, width: 400, height: 400)), rect: rect))
        XCTAssertLessThan(meanGray(crop.data), 140, "mostly the dark square")
    }

    func testThumbnailIs96TallAndRowsStartAtTheTop() {
        let enc = FrameEncoder()
        let empty = enc.thumbnail(frame(square: nil))
        XCTAssertEqual(empty.width, 54)
        XCTAssertEqual(empty.height, 96)
        // Dark top-left quarter (top-left pixel coordinates): thumbnail rows start at the top.
        let quarter = enc.thumbnail(frame(square: CGRect(x: 0, y: 0, width: 540, height: 960)))
        XCTAssertLessThan(quarter.at(5, 5), 40)
        XCTAssertGreaterThan(quarter.at(50, 90), 160)
        XCTAssertGreaterThan(quarter.at(50, 5), 160)
        XCTAssertEqual(SceneDiff.changeFraction(previous: empty, current: enc.thumbnail(frame(square: nil))), 0)
        XCTAssertEqual(SceneDiff.changeFraction(previous: empty, current: quarter), 0.25, accuracy: 0.05)
        // The square's Vision box maps onto the dark thumbnail pixels.
        let r = SceneDiff.pixelRect(CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), width: 54, height: 96)
        XCTAssertTrue(r == (0, 0, 27, 48))
    }
}
