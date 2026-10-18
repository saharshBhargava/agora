import XCTest
import UIKit
import SwiftUI
@testable import Agora

/// The Dibs tab's wiring inside the Agora app: which opened URLs it owns, the bundle resources and
/// Info.plist keys it needs, and that its light-only design does not leak into the other tabs.
@MainActor
final class DibsTabTests: XCTestCase {
    func testDibsLinksGoToTheDibsTab() throws {
        XCTAssertTrue(DibsTab.owns(try XCTUnwrap(URL(string: "dibs://join?run=abc-123"))))
        XCTAssertTrue(DibsTab.owns(try XCTUnwrap(URL(string: "DIBS://join?run=abc"))))
        // A malformed dibs:// link still goes to Dibs, whose Home explains it is not a join link.
        XCTAssertTrue(DibsTab.owns(try XCTUnwrap(URL(string: "dibs://elsewhere"))))
        XCTAssertTrue(DibsTab.owns(try XCTUnwrap(URL(string: "https://dibs.example.com/join?run=abc"))))
    }

    func testGoogleSignInCallbacksStayWithAgora() throws {
        let reversed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .first { $0.hasPrefix("com.googleusercontent.apps.") }
        let scheme = try XCTUnwrap(reversed, "the Google sign-in scheme must stay registered")
        XCTAssertFalse(DibsTab.owns(try XCTUnwrap(URL(string: "\(scheme):/oauth2redirect?code=1&state=2"))))
        XCTAssertFalse(DibsTab.owns(try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/auth"))))
        XCTAssertFalse(DibsTab.owns(try XCTUnwrap(URL(string: "https://example.com/join"))), "no run id")
    }

    func testInfoPlistRegistersTheDibsSchemeNextToGoogle() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains("dibs"))
        XCTAssertTrue(schemes.contains { $0.hasPrefix("com.googleusercontent.apps.") })
    }

    func testDibsServerURLComesFromInfoPlist() throws {
        XCTAssertEqual(ServerConfig.infoPlistKey, "DibsServerURL")
        // Present in every build: empty unless Config/Local.xcconfig sets DIBS_SERVER_URL, never unexpanded.
        let value = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "DibsServerURL") as? String)
        XCTAssertFalse(value.contains("$("))
        if !value.isEmpty { XCTAssertNotNil(ServerConfig.validate(value), "DIBS_SERVER_URL must be https (or localhost)") }
    }

    func testHomeScreenNameIsDibs() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Dibs")
    }

    func testBothBrowserScriptsAreBundledSeparately() throws {
        let agora = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "BrowserScripts", withExtension: "js")),
                               encoding: .utf8)
        let dibs = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "DibsBrowserScripts", withExtension: "js")),
                              encoding: .utf8)
        XCTAssertTrue(agora.contains("humanActivity"), "Agora's script reports human takeover")
        XCTAssertFalse(dibs.contains("humanActivity"), "Dibs' script runs unattended")
    }

    func testTabConsumesAnIncomingLinkAndIsLightOnlyWhileSelected() async throws {
        let box = LinkBox()
        box.url = URL(string: "dibs://not-a-join-link")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: TabHarness(box: box))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }

        // Another tab selected: the Dibs tab must not force the window light.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .dark)

        // The app selects the Dibs tab when a link arrives; the tab consumes the link and goes light.
        box.selected = 1
        try await waitUntil { box.url == nil && host.traitCollection.userInterfaceStyle == .light }
        XCTAssertNil(box.url, "the Dibs tab consumes the link")
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .light)
        attachScreenshot(named: "Dibs tab · malformed link on Home", window: window)

        // Back on another tab, the window follows its own (dark) setting again.
        box.selected = 0
        try await waitUntil { host.traitCollection.userInterfaceStyle == .dark }
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .dark)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func attachScreenshot(named name: String, window: UIWindow) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let data = image.pngData() {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dibs-tab-\(UUID().uuidString).png")
            try? data.write(to: url)
            print("Dibs tab screenshot: \(url.path)")
        }
    }
}

@MainActor
private final class LinkBox: ObservableObject {
    @Published var url: URL?
    @Published var selected = 0
}

/// The app's tab shell in miniature: one Agora tab and the Dibs tab, wired the way BrowserChatApp wires them.
private struct TabHarness: View {
    @ObservedObject var box: LinkBox

    var body: some View {
        TabView(selection: $box.selected) {
            Text("Agora").tabItem { Label("Home", systemImage: "house") }.tag(0)
            DibsTab(incomingURL: $box.url, isActive: box.selected == 1)
                .tabItem { Label("Dibs", systemImage: "cart") }
                .tag(1)
        }
    }
}
