import XCTest
import UIKit
import SwiftUI
@testable import Agora

@MainActor
final class ModelSettingsRenderTests: XCTestCase {
    func testModelSettingsRendersAssignmentsConnectionsAndProfilesInPortrait() async throws {
        let suiteName = "test.model-settings-render.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SettingsStore(keychainService: suiteName, defaults: defaults)
        var configuration = settings.modelConfiguration
        let localConnection = ModelConnection(id: UUID(), name: "Home model server", provider: .openAICompatible,
                                              endpoint: "http://localhost:1234/v1")
        let geminiProfile = try XCTUnwrap(configuration.profiles.first { $0.id == ModelConfiguration.geminiProfileID })
        let localProfile = ModelProfile(id: UUID(), name: "Local vision", connectionID: localConnection.id,
                                        model: "qwen2.5-vl:7b", capabilities: ModelCapabilities(images: true, tools: true,
                                                                                               structuredOutput: true, streaming: false))
        configuration.connections.append(localConnection)
        configuration.profiles.append(localProfile)
        configuration.defaultProfileID = geminiProfile.id
        configuration.assignments = [
            ModelFeature.chat.rawValue: localProfile.id,
            ModelFeature.inventory.rawValue: localProfile.id
        ]
        settings.modelConfiguration = configuration

        let size = CGSize(width: 393, height: 852)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { ModelSettingsView(settings: settings) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))

        XCTAssertEqual(settings.modelConfiguration.defaultProfileID, geminiProfile.id)
        XCTAssertEqual(settings.modelConfiguration.assignments[ModelFeature.chat.rawValue], localProfile.id)
        XCTAssertEqual(settings.modelConfiguration.assignments[ModelFeature.inventory.rawValue], localProfile.id)
        XCTAssertFalse(settings.hasKey, "The fixture must not depend on a user credential.")

        let first = try attachScreenshot(named: "Model settings · assignments and connections", window: window)
        XCTAssertEqual(first.size, size)
        XCTAssertGreaterThan(try Data(contentsOf: first.url).count, 10_000)

        if let scrollView = firstScrollView(in: host.view) {
            scrollView.setContentOffset(CGPoint(x: 0, y: max(0, scrollView.contentSize.height - scrollView.bounds.height)), animated: false)
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let lower = try attachScreenshot(named: "Model settings · model profiles", window: window)
            XCTAssertEqual(lower.size, size)
            XCTAssertGreaterThan(try Data(contentsOf: lower.url).count, 10_000)
        }
    }

    private func attachScreenshot(named name: String, window: UIWindow) throws -> (size: CGSize, url: URL) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let data = try XCTUnwrap(image.pngData())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agora-\(UUID().uuidString).png")
        try data.write(to: url)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("Model settings screenshot: \(url.path)")
        return (image.size, url)
    }

    private func firstScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView { return scrollView }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
