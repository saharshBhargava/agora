import XCTest
@testable import Dibs

/// Links that name another server must not switch servers without the person's say-so.
@MainActor
final class AppModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private let bundled = URL(string: "https://dibs.ngrok.app")!

    override func setUp() async throws {
        suite = "dibs.appmodel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func model() -> AppModel { AppModel(defaults: defaults, bundledServer: bundled) }

    func testSameServerLinkOpensJoinWithoutAPrompt() async {
        let m = model()
        await m.open(JoinLink.parse("https://dibs.ngrok.app/join?run=abc")!)
        XCTAssertNil(m.pendingLink)
        XCTAssertEqual(m.path, [.join(runId: "abc", decline: false)])
        XCTAssertNil(defaults.string(forKey: ServerConfig.serverKey))
    }

    func testAppSchemeLinkUsesTheCurrentServer() async {
        let m = model()
        await m.open(JoinLink.parse("dibs://join?run=abc")!)
        XCTAssertNil(m.pendingLink)
        XCTAssertEqual(m.path, [.join(runId: "abc", decline: false)])
        XCTAssertEqual(m.server, bundled)
    }

    func testOtherServerLinkWaitsForConfirmation() async {
        let m = model()
        await m.open(JoinLink.parse("https://evil.example/join?run=x")!)
        XCTAssertEqual(m.pendingLink?.server?.host, "evil.example")
        XCTAssertEqual(m.path, [])
        XCTAssertEqual(m.server, bundled)
        XCTAssertEqual(m.api.base, bundled)
        XCTAssertNil(defaults.string(forKey: ServerConfig.serverKey))
    }

    func testConfirmSavesTheServerAndOpensJoin() async {
        let m = model()
        await m.open(JoinLink.parse("https://x.ngrok.app/join?run=abc")!)
        await m.confirmPendingServer(m.pendingLink)
        XCTAssertNil(m.pendingLink)
        XCTAssertEqual(m.server.absoluteString, "https://x.ngrok.app")
        XCTAssertEqual(m.api.base.absoluteString, "https://x.ngrok.app")
        XCTAssertEqual(defaults.string(forKey: ServerConfig.serverKey), "https://x.ngrok.app")
        XCTAssertEqual(m.path, [.join(runId: "abc", decline: false)])
    }

    func testCancelLeavesEverythingUnchanged() async {
        let m = model()
        await m.open(JoinLink.parse("https://evil.example/join?run=x")!)
        m.cancelPendingServer()
        XCTAssertNil(m.pendingLink)
        XCTAssertEqual(m.path, [])
        XCTAssertEqual(m.server, bundled)
        XCTAssertNil(defaults.string(forKey: ServerConfig.serverKey))
    }

    func testBuiltInServerLinkSwitchesBackWithoutAPrompt() async {
        defaults.set("https://other.ngrok.app", forKey: ServerConfig.serverKey)
        let m = model()
        XCTAssertEqual(m.server.absoluteString, "https://other.ngrok.app")
        await m.open(JoinLink.parse("https://dibs.ngrok.app/join?run=abc")!)
        XCTAssertNil(m.pendingLink)
        XCTAssertEqual(m.server, bundled)
        XCTAssertNil(defaults.string(forKey: ServerConfig.serverKey))
        XCTAssertEqual(m.path, [.join(runId: "abc", decline: false)])
    }
}
