import XCTest
import WebKit
@testable import Agora

final class BrowserPolicyTests: XCTestCase {
    func testHTTPSDomainsDoNotNeedAnAllowlist() throws {
        let policy = BrowserPolicy()
        for text in ["https://example.com/page", "https://en.wikipedia.org", "https://www.premierleague.com", "https://accounts.google.com", "https://unlisted.example.org", "https://example.com:443/path"] {
            XCTAssertNoThrow(try policy.validate(URL(string: text)!), text)
        }
    }
    func testUnsupportedDestinationsRemainBlocked() {
        let policy = BrowserPolicy()
        for text in ["http://example.com", "https://user:password@example.com", "https://example.com:444", "https://127.0.0.1", "https://192.168.1.1", "https://[::1]", "https://localhost.local", "https://localhost.local.", "https://localhost", "file:///tmp/a", "javascript:alert(1)"] {
            XCTAssertThrowsError(try policy.validate(URL(string: text)!), text)
        }
    }
    func testURLRedaction() {
        XCTAssertEqual(BrowserPolicy.safeURL(URL(string: "https://user:password@example.com/path?token=secret#access_token=secret")), "https://example.com/path")
    }
    func testRejectsMalformedTools() {
        for raw: [String: Any] in [
            ["name": "evaluate_javascript", "args": [:]],
            ["name": "browser_open", "args": ["url": "https://example.com", "script": "evil"]],
            ["name": "browser_wait_for", "args": ["text": "hi", "seconds": 50]],
            ["name": "browser_wait_for", "args": ["text": "hi", "seconds": true]],
            ["name": "browser_act", "args": ["action": "click"]],
            ["name": "browser_act", "args": ["action": "eval"]]
        ] { XCTAssertThrowsError(try BrowserCall(raw)) }
    }
}

@MainActor
final class BrowserIntegrationTests: XCTestCase {
    var session: BrowserSession!
    var window: UIWindow!
    override func setUp() async throws {
        session = BrowserSession(policy: BrowserPolicy())
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController(); controller.view = BrowserViewport(page: session.webView)
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        let fixture = try String(contentsOf: Bundle(for: Self.self).url(forResource: "browser-fixture", withExtension: "html")!, encoding: .utf8)
        session.webView.loadHTMLString(fixture, baseURL: nil)
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let ready = try? await session.webView.evaluateJavaScript("document.readyState"), ready as? String == "complete",
               let title = try? await session.webView.evaluateJavaScript("document.querySelector('h1')?.textContent"), title as? String == "Browser fixture" { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        session.state.isOpen = true
        _ = try await session.observe()
    }
    override func tearDown() async throws { session.close(); window.isHidden = true; window = nil; session = nil }
    func action(_ name: String, label: String, text: String? = nil) async throws -> [String: Any] {
        let observation = try await session.observe()
        let elements = observation["elements"] as! [[String: Any]]
        let element = try XCTUnwrap(elements.first { $0["name"] as? String == label })
        var args: [String: Any] = ["operation": "act", "action": name, "documentId": observation["documentId"]!, "observationId": observation["observationId"]!, "elementId": element["id"]!]
        if let text { args["text"] = text }
        return try await session.bridge(args, mutation: true)
    }
    func testTypeClickWaitRoundTripAndArgumentsStayData() async throws {
        let value = "shoes '; window.pwned = true; //"
        _ = try await action("type", label: "Search", text: value)
        _ = try await action("click", label: "Search now")
        let executor = BrowserToolExecutor(session: session)
        let result = try await executor.execute(BrowserCall(["name": "browser_wait_for", "args": ["text": "Results for " + value, "seconds": 3]]))
        XCTAssertTrue((result["text"] as! String).contains(value))
        let injected = try await session.webView.evaluateJavaScript("window.pwned === true")
        XCTAssertEqual(injected as? Bool, false)
    }
    final class ClickAndTypeProvider: ModelProvider {
        let session: BrowserSession
        var turns = 0
        init(session: BrowserSession) { self.session = session }
        func nextTurn(contents: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
            turns += 1
            guard turns <= 2 else { return ["role": "model", "parts": [["text": "Search complete."]]] }
            let observation = try await session.observe()
            let label = turns == 1 ? "Search" : "Search now"
            let elements = try XCTUnwrap(observation["elements"] as? [[String: Any]])
            let element = try XCTUnwrap(elements.first { $0["name"] as? String == label })
            var args: [String: Any] = ["action": turns == 1 ? "type" : "click", "documentId": observation["documentId"]!, "observationId": observation["observationId"]!, "elementId": element["id"]!]
            if turns == 1 { args["text"] = "automatic search" }
            return ["role": "model", "parts": [["functionCall": ["name": "browser_act", "args": args]]]]
        }
    }
    func testAgentClicksAndTypesWithoutApproval() async throws {
        let agent = AgentCoordinator(settings: SettingsStore(), browser: session)
        let provider = ClickAndTypeProvider(session: session)
        agent.providerOverride = provider
        defer { agent.stop() }
        agent.send("Search for automatic search")
        let deadline = ContinuousClock.now + .seconds(10)
        while agent.running && agent.approval == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(agent.approval)
        XCTAssertFalse(agent.running)
        XCTAssertEqual(provider.turns, 3)
        let executor = BrowserToolExecutor(session: session)
        let result = try await executor.execute(BrowserCall(["name": "browser_wait_for", "args": ["text": "Results for automatic search", "seconds": 3]]))
        XCTAssertTrue((result["text"] as? String ?? "").contains("Results for automatic search"))
    }
    func testReplacedNodeCannotReceiveAnAction() async throws {
        let observation = try await session.observe()
        let element = (observation["elements"] as! [[String: Any]]).first { $0["name"] as? String == "Search now" }!
        _ = try await session.webView.evaluateJavaScript("document.getElementById('search').outerHTML = '<button>Replacement</button>'")
        do {
            _ = try await session.bridge(["operation": "act", "action": "click", "documentId": observation["documentId"]!, "observationId": observation["observationId"]!, "elementId": element["id"]!])
            XCTFail("Expected stale reference")
        } catch { XCTAssertTrue(error.localizedDescription.contains("stale_reference")) }
    }
    func testSensitivePagesBlockObservationAndScreenshot() async throws {
        let initial = try await session.observe()
        XCTAssertFalse((initial["text"] as! String).contains("never-send-this"))
        _ = try await session.webView.evaluateJavaScript("document.getElementById('secret').hidden = false")
        do { _ = try await session.observe(); XCTFail("Expected private page") } catch { XCTAssertTrue(error.localizedDescription.contains("user_action_required")) }
        do { _ = try await session.screenshot(); XCTFail("Expected blocked capture") } catch { XCTAssertTrue(error.localizedDescription.contains("user_action_required")) }
    }
    func testHideRestoreKeepsSameWebViewAndInput() async throws {
        let identity = ObjectIdentifier(session.webView)
        _ = try await action("type", label: "Search", text: "preserved")
        for presentation: BrowserPresentation in [.expanded, .thumbnail, .hidden, .thumbnail] { session.state.presentation = presentation }
        XCTAssertEqual(ObjectIdentifier(session.webView), identity)
        let value = try await session.webView.evaluateJavaScript("document.getElementById('query').value")
        XCTAssertEqual(value as? String, "preserved")
    }
    func testScreenshotIsBoundedAndHiddenCaptureIsRejected() async throws {
        session.state.presentation = .expanded
        let result = try await session.screenshot()
        XCTAssertEqual(result["mimeType"] as? String, "image/jpeg")
        XCTAssertNotNil(Data(base64Encoded: result["image"] as! String))
        XCTAssertLessThanOrEqual(result["pixelWidth"] as! Int, 1440)
        session.state.presentation = .hidden
        do { _ = try await session.screenshot(); XCTFail("Expected hidden capture error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("observation_unavailable")) }
    }
    func testViewportKeepsSamePageAtNonzeroSize() {
        let viewport = window.rootViewController!.view as! BrowserViewport
        viewport.frame = CGRect(x: 0, y: 0, width: 184, height: 253)
        viewport.thumbnail = true; viewport.layoutIfNeeded()
        XCTAssertEqual(session.webView.bounds.width, 390)
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        viewport.thumbnail = false; viewport.layoutIfNeeded()
        XCTAssertTrue(viewport.page === session.webView)
        XCTAssertEqual(session.webView.bounds.height, 700)
    }
    func testHumanLeaseRevokesPendingWaitAndCloseSettles() async throws {
        let executor = BrowserToolExecutor(session: session)
        let task = Task { try await executor.execute(BrowserCall(["name": "browser_wait_for", "args": ["text": "never appears", "seconds": 10]])) }
        try await Task.sleep(for: .milliseconds(200))
        session.humanInteraction()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error.localizedDescription.contains("cancelled")) }
        session.close()
        do { _ = try await session.observe(); XCTFail("Expected no browser") } catch { XCTAssertTrue(error.localizedDescription.contains("no_browser")) }
    }
}

@MainActor
final class AgentLoopTests: XCTestCase {
    final class FakeProvider: ModelProvider {
        var turns = 0
        var receivedToolResult = false
        func nextTurn(contents: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
            turns += 1
            if turns == 1 { return ["role": "model", "parts": [["thoughtSignature": "retain-me", "functionCall": ["id": "call-1", "name": "browser_observe", "args": [:]]]]] }
            let model = contents[contents.count - 2]["parts"] as! [[String: Any]]
            XCTAssertEqual(model[0]["thoughtSignature"] as? String, "retain-me")
            let parts = contents.last!["parts"] as! [[String: Any]]
            let response = parts[0]["functionResponse"] as! [String: Any]
            XCTAssertEqual(response["id"] as? String, "call-1")
            receivedToolResult = (response["response"] as? [String: Any])?["error"] != nil
            return ["role": "model", "parts": [["text": "Please open a page first."]]]
        }
    }
    final class ApprovalProvider: ModelProvider {
        var turns = 0
        func nextTurn(contents: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
            turns += 1
            return ["role": "model", "parts": [["functionCall": ["name": "browser_close", "args": [:]]]]]
        }
    }
    func testStopWhileAwaitingApprovalDoesNotExecuteOrContinue() async throws {
        let settings = SettingsStore(), browser = BrowserSession(policy: BrowserPolicy())
        browser.state.isOpen = true
        let agent = AgentCoordinator(settings: settings, browser: browser), fake = ApprovalProvider()
        agent.providerOverride = fake; agent.send("Close browser")
        for _ in 0..<100 { if agent.approval != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(agent.approval)
        agent.stop(); agent.resolveApproval(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(agent.approval); XCTAssertFalse(agent.running)
        XCTAssertTrue(browser.state.isOpen); XCTAssertEqual(fake.turns, 1)
        browser.close()
    }
    func testToolResultsAndSignaturesSurviveRoundTrip() async throws {
        let settings = SettingsStore(), browser = BrowserSession(policy: BrowserPolicy())
        let agent = AgentCoordinator(settings: settings, browser: browser), fake = FakeProvider()
        agent.providerOverride = fake; agent.send("Read the page")
        for _ in 0..<100 { if !agent.running { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(agent.running); XCTAssertTrue(fake.receivedToolResult)
        XCTAssertEqual(agent.messages.last?.text, "Please open a page first.")
        agent.newChat(); XCTAssertTrue(agent.messages.isEmpty); XCTAssertFalse(browser.state.isOpen)
    }
}

@MainActor
final class GeminiConfigurationTests: XCTestCase {
    func testModelNamesAreNormalized() {
        XCTAssertEqual(GeminiProvider.normalizedModel("  models/gemini-flash-latest\n"), "gemini-flash-latest")
        XCTAssertEqual(GeminiProvider.normalizedModel("gemini-3.8-flash"), "gemini-3.8-flash")
    }
    func testModelListFiltersUnsupportedModesAndRetainsPagination() throws {
        let data = Data(#"{"models":[{"name":"models/gemini-flash-latest","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-flash-image","supportedGenerationMethods":["generateContent"]},{"name":"models/gemini-flash-tts","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next-page"}"#.utf8)
        let page = try JSONDecoder().decode(GeminiProvider.ModelPage.self, from: data)
        XCTAssertEqual(page.chatModels, ["gemini-flash-latest"])
        XCTAssertEqual(page.nextPageToken, "next-page")
    }
    func testHTTPFailuresHaveDistinctRecoveryInstructions() {
        XCTAssertTrue(GeminiProvider.responseError(404).detail.contains("Load available models"))
        XCTAssertTrue(GeminiProvider.responseError(403).detail.contains("permissions"))
        XCTAssertTrue(GeminiProvider.responseError(429).detail.contains("quota"))
        XCTAssertTrue(GeminiProvider.responseError(503).detail.contains("temporarily"))
    }
}

@MainActor
final class APIKeyStorageTests: XCTestCase {
    func testSaveReadReplaceRelaunchAndRemove() throws {
        // Unique service prevents tests from reading or changing the user's actual key.
        let service = "app.agora.tests.\(UUID().uuidString)"
        let settings = SettingsStore(keychainService: service)
        defer { try? settings.deleteKey() }
        XCTAssertFalse(settings.hasKey)
        XCTAssertThrowsError(try settings.apiKey())
        try settings.saveKey("  test-key-one\n")
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(try settings.apiKey(), "test-key-one")
        let relaunched = SettingsStore(keychainService: service)
        XCTAssertTrue(relaunched.hasKey)
        XCTAssertEqual(try relaunched.apiKey(), "test-key-one")
        try relaunched.saveKey("test-key-two")
        XCTAssertEqual(try settings.apiKey(), "test-key-two")
        try relaunched.deleteKey()
        XCTAssertFalse(relaunched.hasKey)
        XCTAssertThrowsError(try settings.apiKey())
        try relaunched.deleteKey() // Removing an already absent key is safe.
    }
    func testBlankReplacementDoesNotEraseSavedKey() throws {
        let settings = SettingsStore(keychainService: "app.agora.tests.\(UUID().uuidString)")
        defer { try? settings.deleteKey() }
        try settings.saveKey("test-existing-key")
        XCTAssertThrowsError(try settings.saveKey(" \n\t "))
        XCTAssertTrue(settings.hasKey)
        XCTAssertEqual(try settings.apiKey(), "test-existing-key")
    }
}

final class DiagnosticLoggingTests: XCTestCase {
    func testWebsiteAndNativeErrorDetailsAreNotLogged() {
        XCTAssertEqual(AppLog.safeErrorCode(BrowserError("user_action_required: secret page contents")), "user_action_required")
        XCTAssertEqual(AppLog.safeErrorCode(BrowserError("unexpected-secret-token")), "browser_error")
        XCTAssertEqual(AppLog.safeErrorCode(NSError(domain: "https://secret.example/token", code: 7, userInfo: [NSLocalizedDescriptionKey: "secret"])), "other:7")
        XCTAssertEqual(AppLog.safeErrorCode(BrowserError("gemini_http_404", "secret response body")), "gemini_http_404")
    }
}

@MainActor
final class BrowserPresentationTests: XCTestCase {
    final class WaitingProvider: ModelProvider {
        var reply: CheckedContinuation<[String: Any], Never>?
        func nextTurn(contents: [[String: Any]], tools: [[String: Any]]) async throws -> [String: Any] {
            await withCheckedContinuation { reply = $0 }
        }
        func finish() {
            reply?.resume(returning: ["role": "model", "parts": [["text": "Finished while the browser was open."]]])
            reply = nil
        }
    }
    func testPresentationChangesKeepInFlightAgentRunning() async throws {
        let browser = BrowserSession(policy: BrowserPolicy())
        let agent = AgentCoordinator(settings: SettingsStore(), browser: browser)
        let provider = WaitingProvider(); agent.providerOverride = provider
        defer { provider.finish(); agent.stop(); browser.close() }
        browser.state.isOpen = true
        agent.send("Continue working")
        for _ in 0..<100 { if provider.reply != nil { break }; await Task.yield() }
        XCTAssertNotNil(provider.reply)
        let lease = browser.lease
        for presentation: BrowserPresentation in [.expanded, .thumbnail, .hidden, .thumbnail, .expanded] {
            browser.setPresentationFromUser(presentation)
            XCTAssertTrue(agent.running)
            XCTAssertFalse(agent.paused)
            XCTAssertEqual(browser.lease, lease)
        }
        provider.finish()
        for _ in 0..<100 { if !agent.running { break }; await Task.yield() }
        XCTAssertEqual(agent.messages.last?.text, "Finished while the browser was open.")
        XCTAssertFalse(agent.paused)
    }
    func testHitTestingDoesNotTakeControlButDeliveredPageTouchDoes() {
        let browser = BrowserSession(policy: BrowserPolicy())
        defer { browser.close() }
        let viewport = BrowserViewport(page: browser.webView)
        viewport.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        viewport.thumbnail = false; viewport.layoutIfNeeded()
        var takeovers = 0
        viewport.onTouch = { takeovers += 1; browser.humanInteraction() }
        let lease = browser.lease
        _ = viewport.hitTest(CGPoint(x: 20, y: 20), with: nil)
        _ = viewport.hitTest(CGPoint(x: -20, y: -20), with: nil)
        XCTAssertEqual(takeovers, 0)
        XCTAssertEqual(browser.lease, lease)
        // Exercise the observer callback without generating system input events.
        viewport.touchObserver.touchesBegan([], with: UIEvent())
        XCTAssertEqual(takeovers, 1)
        XCTAssertGreaterThan(browser.lease, lease)
        XCTAssertFalse(viewport.touchObserver.cancelsTouchesInView)
        XCTAssertFalse(viewport.touchObserver.delaysTouchesBegan)
    }
}
