import XCTest
@testable import Agora

final class ScanLogicTests: XCTestCase {
    private func gemini(text: String, finish: String = "STOP", block: String? = nil, web: (uri: String, title: String)? = nil) -> Data {
        var candidate: [String: Any] = ["finishReason": finish,
                                        "content": ["parts": [["text": "hidden", "thought": true], ["text": text]]]]
        if let web { candidate["groundingMetadata"] = ["groundingChunks": [["web": ["uri": web.uri, "title": web.title]]]] }
        var root: [String: Any] = ["candidates": [candidate]]
        if let block { root["promptFeedback"] = ["blockReason": block] }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private func identification(_ json: String) throws -> IdentifiedItem {
        try QuoteParsing.identification(fromGeminiResponse: gemini(text: json))
    }

    private func assertInvalid<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? QuoteError, QuoteError(code: "invalid"), file: file, line: line) }
    }

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

    func testIdentificationDecodes() throws {
        let item = try identification(#"{"name":"Honeycrisp apple","detail":"single loose apple","searchQuery":"honeycrisp apple","confidence":0.92}"#)
        XCTAssertEqual(item, IdentifiedItem(name: "Honeycrisp apple", detail: "single loose apple", searchQuery: "honeycrisp apple", confidence: 0.92))
    }

    func testIdentificationRejectsBlocked() {
        XCTAssertThrowsError(try QuoteParsing.identification(fromGeminiResponse: gemini(text: "{}", block: "SAFETY"))) {
            XCTAssertEqual($0 as? QuoteError, QuoteError(code: "blocked"))
        }
    }

    func testIdentificationClampsConfidence() {
        assertInvalid(try identification(#"{"name":"Apple","detail":"x","searchQuery":"apple","confidence":1.7}"#))
        assertInvalid(try identification(#"{"name":"","detail":"x","searchQuery":"apple","confidence":0.5}"#))
    }

    func testQuoteParsesFencedJSON() throws {
        let text = "Here you go:\n```json\n{\"found\":true,\"productName\":\"Honeycrisp Apple\",\"priceCents\":299,\"unit\":\"lb\",\"sourceUrl\":\"https://www.qfc.com/p/honeycrisp-apple/0000000003283\",\"note\":null}\n```"
        let quote = try XCTUnwrap(QuoteParsing.quote(fromGeminiResponse: gemini(text: text), storeName: "QFC"))
        XCTAssertEqual(quote.priceCents, 299)
        XCTAssertEqual(quote.unit, "lb")
        XCTAssertTrue(quote.onStoreSite)
        XCTAssertEqual(quote.storeName, "QFC")
    }

    func testQuoteNotFoundIsNil() throws {
        XCTAssertNil(try QuoteParsing.quote(fromGeminiResponse: gemini(text: #"{"found":false}"#), storeName: "QFC"))
    }

    func testQuoteRejectsAbsurdPrice() {
        for cents in ["0", "-5", "100000001"] {
            let text = #"{"found":true,"productName":"Apple","priceCents":\#(cents),"unit":"lb"}"#
            assertInvalid(try QuoteParsing.quote(fromGeminiResponse: gemini(text: text), storeName: "QFC"))
        }
        let longUnit = #"{"found":true,"productName":"Apple","priceCents":299,"unit":"abcdefghijklmnopqrstu"}"#
        assertInvalid(try QuoteParsing.quote(fromGeminiResponse: gemini(text: longUnit), storeName: "QFC"))
    }

    func testQuoteUsesGroundingSourceWhenNoURL() throws {
        let text = #"{"found":true,"productName":"Apple","priceCents":299,"unit":"lb"}"#
        let data = gemini(text: text, web: ("https://vertexaisearch.cloud.google.com/x", "qfc.com"))
        let quote = try XCTUnwrap(QuoteParsing.quote(fromGeminiResponse: data, storeName: "QFC"))
        XCTAssertEqual(quote.sourceTitle, "qfc.com")
        XCTAssertTrue(quote.onStoreSite)
    }

    func testQuoteOffSiteSource() throws {
        let text = #"{"found":true,"productName":"Apple","priceCents":299,"unit":"lb","sourceUrl":"https://www.kroger.com/p/apple/1"}"#
        let quote = try XCTUnwrap(QuoteParsing.quote(fromGeminiResponse: gemini(text: text), storeName: "QFC"))
        XCTAssertFalse(quote.onStoreSite)
    }

    func testFirstJSONObjectHandlesBracesInStrings() {
        XCTAssertEqual(QuoteParsing.firstJSONObject(in: #"x {"a":"}"} y"#), #"{"a":"}"}"#)
    }
}
