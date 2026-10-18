import Foundation
import XCTest

private final class BundleToken {}

/// Loads a JSON fixture captured from the real Dibs server. The files live in the repo's `Fixtures/`
/// folder (bundled flat into AgoraTests) with a `dibs-` prefix: `fixtureData("run")` reads `dibs-run.json`.
func fixtureData(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
    let bundle = Bundle(for: BundleToken.self)
    let resource = "dibs-\(name)"
    let url = try XCTUnwrap(
        bundle.url(forResource: resource, withExtension: "json")
            ?? bundle.url(forResource: resource, withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture \(resource).json", file: file, line: line)
    return try Data(contentsOf: url)
}
