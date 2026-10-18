import XCTest
import UIKit
import SwiftUI
@testable import Agora

/// The app root: which opened URLs go to Dibs, the bundle resources and Info.plist keys it needs, and
/// the one light-only window with the household pages pushed inside its stack.
@MainActor
final class DibsRootTests: XCTestCase {
    func testDibsLinksGoToDibs() throws {
        XCTAssertTrue(DibsRootView.owns(try XCTUnwrap(URL(string: "dibs://join?run=abc-123"))))
        XCTAssertTrue(DibsRootView.owns(try XCTUnwrap(URL(string: "DIBS://join?run=abc"))))
        // A malformed dibs:// link still goes to Dibs, whose Home explains it is not a join link.
        XCTAssertTrue(DibsRootView.owns(try XCTUnwrap(URL(string: "dibs://elsewhere"))))
        XCTAssertTrue(DibsRootView.owns(try XCTUnwrap(URL(string: "https://dibs.example.com/join?run=abc"))))
    }

    func testGoogleSignInCallbacksGoToGoogle() throws {
        let reversed = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
            .first { $0.hasPrefix("com.googleusercontent.apps.") }
        let scheme = try XCTUnwrap(reversed, "the Google sign-in scheme must stay registered")
        XCTAssertFalse(DibsRootView.owns(try XCTUnwrap(URL(string: "\(scheme):/oauth2redirect?code=1&state=2"))))
        XCTAssertFalse(DibsRootView.owns(try XCTUnwrap(URL(string: "https://accounts.google.com/o/oauth2/auth"))))
        XCTAssertFalse(DibsRootView.owns(try XCTUnwrap(URL(string: "https://example.com/join"))), "no run id")
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

    func testTheWindowIsLightAndEveryHouseholdPagePushesInsideTheRootStack() async throws {
        let suite = "dibs.root.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, bundledServer: URL(string: "https://dibs.example.com"))
        let workspace = ChatWorkspace()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = .dark
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: DibsRootView(workspace: workspace, model: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; previousWindow?.makeKeyAndVisible()
            workspace.agent.stop(); workspace.browser.close()
            defaults.removePersistentDomain(forName: suite)
        }

        // The whole window is light even when the system is dark: the Dibs design is paper and ink.
        try await waitUntil { host.traitCollection.userInterfaceStyle == .light }
        XCTAssertEqual(host.traitCollection.userInterfaceStyle, .light)
        try await Task.sleep(for: .milliseconds(300))
        attachScreenshot(named: "Home", window: window)

        let pages: [(HouseholdPage, String)] = [(.lists, "Lists"), (.pantry, "Pantry"), (.wishlist, "Wishlist"),
                                                (.assistant, "Assistant"), (.capture, "Capture")]
        for (page, name) in pages {
            model.path = [.household(page)]
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertEqual(model.path, [.household(page)])
            // One stack: the page shows the root stack's back button, not a stack of its own.
            let bars = navigationBars(in: host.view)
            XCTAssertEqual(bars.count, 1, "\(name) has no navigation stack of its own")
            XCTAssertEqual(bars.first?.items?.count, 2, "\(name) is pushed on the home's stack")
            attachScreenshot(named: name, window: window)
        }
        model.path = []
        try await Task.sleep(for: .milliseconds(300))
    }

    func testHouseholdCardsSettingsAndSignInRenderInTheDibsLook() async throws {
        let suite = "dibs.root.look.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let model = AppModel(defaults: defaults, bundledServer: URL(string: "https://dibs.example.com"))
        let workspace = ChatWorkspace()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        defer {
            window.isHidden = true; previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: suite)
        }
        let rows = [
            NextRunRow(id: "low-1", name: "Eggs", reason: "Running low", page: .pantry),
            NextRunRow(id: "wish-1", name: "Cast iron pan", reason: "Target price", amount: "$35.00", page: .wishlist),
            NextRunRow(id: "idea-1", name: "Olive oil", reason: "You use about a bottle a month.", page: .wishlist),
        ]
        let cards = ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space2) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Hairline() }
                        NextRunRowView(row: row)
                    }
                }
                .dibsCard()
                VStack(spacing: 0) {
                    DibsLinkRow(title: "Lists", detail: "Shopping lists and trips", symbol: "checklist", tint: 0xD8E2FA)
                    Hairline()
                    DibsLinkRow(title: "Pantry", detail: "What you have at home", symbol: "shippingbox", tint: 0xF2E3B5)
                }
                .dibsCard()
            }
            .padding(20)
        }
        .dibsScreen()
        let screens: [(String, AnyView)] = [
            ("Home cards", AnyView(cards)),
            ("Settings", AnyView(SettingsSheet(workspace: workspace).environment(model))),
            ("Sign in", AnyView(CalendarOnboardingView(calendar: workspace.calendar))),
        ]
        for (name, view) in screens {
            let host = UIHostingController(rootView: view)
            window.rootViewController = host
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            attachScreenshot(named: name, window: window)
        }
    }

    private func navigationBars(in view: UIView) -> [UINavigationBar] {
        var bars: [UINavigationBar] = []
        func walk(_ v: UIView) {
            if let bar = v as? UINavigationBar, !bar.isHidden, bar.window != nil { bars.append(bar) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return bars
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
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dibs-root-\(name)-\(UUID().uuidString.prefix(8)).png")
            try? data.write(to: url)
            print("Dibs root screenshot: \(url.path)")
        }
    }
}
