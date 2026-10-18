import Foundation
import XCTest

private final class BundleToken {}

/// Loads a JSON fixture captured from the real Dibs server.
func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
    let bundle = Bundle(for: BundleToken.self)
    let url = try XCTUnwrap(
        bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(name).json", file: file, line: line)
    return try Data(contentsOf: url)
}
