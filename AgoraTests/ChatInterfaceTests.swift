import XCTest
import SwiftUI
import WebKit
@testable import Agora

@MainActor
final class ChatInterfaceTests: XCTestCase {
    final class StreamingModel: ModelClient {
        let identity = ModelIdentity(provider: .openAICompatible, model: "fixture")
        let capabilities = ModelCapabilities(images: true, tools: true)
        var emit: (@MainActor (ModelEvent) -> Void)?
        var completion: CheckedContinuation<ModelResponse, Error>?
        var requests: [ModelRequest] = []
        func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse { try await stream(request, onEvent: onEvent) }
        func stream(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
            requests.append(request); emit = onEvent
            return try await withCheckedThrowingContinuation { completion = $0 }
        }
        func finish(_ text: String) { completion?.resume(returning: .init(message: .init(role: .assistant, content: [.text(text)]))); completion = nil }
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not become true")
    }
    func testStreamingUpdatesOneRowAndStopRejectsLateEvents() async throws {
        let browser = BrowserSession(policy: BrowserPolicy()), agent = AgentCoordinator(settings: SettingsStore(), browser: BrowserSession(policy: BrowserPolicy()))
        defer { browser.close(); agent.stop(); agent.browser.close() }
        let model = StreamingModel(); agent.modelClientOverride = model
        agent.send("Explain coffee")
        try await wait { model.completion != nil }
        model.emit?(.text("A"))
        let row = try XCTUnwrap(agent.messages.last), count = agent.messages.count
        XCTAssertTrue(row.streaming)
        model.emit?(.text("A better cup"))
        XCTAssertEqual(agent.messages.count, count)
        XCTAssertTrue(agent.messages.last === row)
        XCTAssertEqual(row.text, "A better cup")
        agent.stop()
        XCTAssertFalse(agent.running); XCTAssertFalse(row.streaming)
        model.emit?(.text("Late content")); model.finish("Late final")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(row.text, "A better cup")
    }
    func testHistoryKeepsDraftAttachmentsAndContextAndCanDeleteArchiveReset() async throws {
        let agent = AgentCoordinator(settings: SettingsStore(), browser: BrowserSession(policy: BrowserPolicy()))
        let model = StreamingModel(); agent.modelClientOverride = model
        defer { model.finish("Done"); agent.stop(); agent.browser.close() }
        let first = agent.conversations.current
        first.draft = "Draft to keep"
        first.attachments = [.init(name: "notes.txt", data: Data("notes".utf8), mimeType: "text/plain", extractedText: "notes")]
        agent.send("First message"); try await wait { model.completion != nil }; model.finish("First answer"); try await wait { !agent.running }
        let row = agent.messages.last
        agent.newChat(); XCTAssertTrue(agent.messages.isEmpty)
        let second = agent.conversations.current
        second.draft = "Second draft"
        agent.selectConversation(first)
        XCTAssertEqual(first.draft, "Draft to keep"); XCTAssertEqual(first.attachments.count, 1)
        XCTAssertTrue(agent.messages.last === row)
        agent.send("Follow-up"); try await wait { model.completion != nil }
        XCTAssertEqual(model.requests.last?.messages.count, 3)
        model.finish("Follow-up answer"); try await wait { !agent.running }
        agent.archiveConversation(first); XCTAssertTrue(first.archived)
        agent.selectConversation(second); XCTAssertEqual(second.draft, "Second draft")
        agent.deleteConversation(first); XCTAssertFalse(agent.conversations.conversations.contains { $0.id == first.id })
        agent.resetConversations(); XCTAssertEqual(agent.conversations.conversations.count, 1); XCTAssertTrue(agent.messages.isEmpty)
    }
    func testAttachmentsAreActuallyIncludedInModelRequest() async throws {
        let agent = AgentCoordinator(settings: SettingsStore(), browser: BrowserSession(policy: BrowserPolicy())), model = StreamingModel()
        agent.modelClientOverride = model
        defer { model.finish("Read"); agent.stop(); agent.browser.close() }
        let attachment = ChatAttachment(name: "notes.txt", data: Data("coffee notes".utf8), mimeType: "text/plain", extractedText: "coffee notes")
        XCTAssertTrue(agent.send("Read this", attachments: [attachment]))
        try await wait { model.completion != nil }
        let content = try XCTUnwrap(model.requests.last?.messages.last?.content)
        XCTAssertEqual(content.count, 2)
        if case .text(let text) = content[1] { XCTAssertTrue(text.contains("coffee notes")) } else { XCTFail("Missing file text") }
        XCTAssertEqual(agent.messages.first(where: { $0.role == "user" })?.attachments.first?.name, "notes.txt")
    }
    func testApprovalRecordExpiresWhenStopped() async throws {
        let browser = BrowserSession(policy: BrowserPolicy()), agent = AgentCoordinator(settings: SettingsStore(), browser: BrowserSession(policy: BrowserPolicy()))
        defer { browser.close(); agent.browser.close() }
        agent.providerOverride = AgentLoopTests.ApprovalProvider()
        agent.send("Close the browser")
        try await wait { agent.approval != nil }
        let row = try XCTUnwrap(agent.messages.last(where: { $0.approval != nil }))
        XCTAssertEqual(row.approval?.status, .pending)
        agent.stop(); XCTAssertEqual(row.approval?.status, .expired)
        agent.resolveApproval(true); XCTAssertEqual(row.approval?.status, .expired)
        XCTAssertTrue(agent.messages.contains { $0.tool?.status == .stopped })
    }
    func testMarkdownBlocksKeepCodeTablesAndListsDistinct() {
        let blocks = MarkdownBlock.parse("# Title\n\nA [source](https://example.com).\n\n- One\n2. Two\n> Quote\n```swift\nlet x = 1\n```\n| A | B |\n| --- | --- |\n| C | D |")
        XCTAssertEqual(blocks.map(\.kind), [.heading(1), .paragraph, .list("•"), .list("2."), .quote, .code("swift"), .table])
        XCTAssertEqual(blocks[5].text, "let x = 1")
        XCTAssertEqual(MarkdownBlock.parse("```\nunfinished").first?.text, "unfinished")
    }
    func testScrollFollowingPreservesPositionDuringStreamingAndAccessibilityScrolls() {
        var state = ChatScrollFollowing()
        XCTAssertTrue(state.update(.init(origin: 0, height: 1200), viewport: 600, dragging: false))
        _ = state.update(.init(origin: -600, height: 1200), viewport: 600, dragging: false)
        XCTAssertTrue(state.follows)
        // Upward scrolling, including an accessibility scroll without a pan gesture.
        XCTAssertFalse(state.update(.init(origin: -300, height: 1200), viewport: 600, dragging: false))
        XCTAssertFalse(state.follows)
        XCTAssertFalse(state.update(.init(origin: -300, height: 1400), viewport: 600, dragging: false))
        XCTAssertFalse(state.follows)
        _ = state.update(.init(origin: -800, height: 1400), viewport: 600, dragging: true)
        XCTAssertTrue(state.follows)
        XCTAssertTrue(state.update(.init(origin: -800, height: 1500), viewport: 600, dragging: false))
    }
    func testUnreadableAndOversizedDocumentsAreRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0xFF, 0xFF]).write(to: url); XCTAssertThrowsError(try ChatAttachment.read(url))
        try Data(String(repeating: "a", count: 120_001).utf8).write(to: url); XCTAssertThrowsError(try ChatAttachment.read(url))
        try Data("A note".utf8).write(to: url); XCTAssertEqual(try ChatAttachment.read(url).extractedText, "A note")
    }
    func testGeminiStreamKeepsSignaturesAndPrivateThoughtsOutOfVisibleText() throws {
        var stream = GeminiChatStream()
        func chunk(_ parts: [[String: Any]], finish: String? = nil) throws -> Data {
            var candidate: [String: Any] = ["content": ["role": "model", "parts": parts]]
            if let finish { candidate["finishReason"] = finish }
            return try JSONSerialization.data(withJSONObject: ["candidates": [candidate]])
        }
        try stream.consume(chunk([["thought": true, "text": "Private reasoning", "thoughtSignature": "opaque"], ["text": "Reading "]]))
        try stream.consume(chunk([["text": "the page"], ["functionCall": ["id": "read", "name": "browser_observe", "args": [:]], "thoughtSignature": "signed-call"]], finish: "STOP"))
        XCTAssertEqual(stream.text, "Reading the page")
        let result = try stream.result()
        XCTAssertEqual(result.toolCalls.first?.id, "read")
        let wire = try GeminiConversationCodec.encode(result)
        let parts = try XCTUnwrap(wire["parts"] as? [[String: Any]])
        XCTAssertEqual(parts.last?["thoughtSignature"] as? String, "signed-call")
        var incomplete = GeminiChatStream(); try incomplete.consume(chunk([["text": "partial"]])); XCTAssertThrowsError(try incomplete.result())
        var blocked = GeminiChatStream(); XCTAssertThrowsError(try blocked.consume(chunk([["text": "partial"]], finish: "MAX_TOKENS")))
    }
    func testChatRendersLightDarkDynamicTypeAndPersistentBrowser() async throws {
        let workspace = ChatWorkspace()
        ChatFixtures.populate(workspace.agent.conversations.current)
        workspace.agent.messages = workspace.agent.conversations.current.messages
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        let host = UIHostingController(rootView: AnyView(ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser)))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible(); workspace.agent.stop(); workspace.browser.close() }
        for (style, label) in [(UIUserInterfaceStyle.light, "light"), (.dark, "dark")] {
            window.overrideUserInterfaceStyle = style
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            try capture(window, name: label)
        }
        host.rootView = AnyView(ChatView(workspace: workspace, agent: workspace.agent, browser: workspace.browser))
        host.view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await Task.sleep(for: .milliseconds(350)); try capture(window, name: "dynamic-type")
        host.view.traitOverrides.preferredContentSizeCategory = .large
        let webView = workspace.browser.webView
        workspace.browser.state.isOpen = true
        webView.loadHTMLString("<meta name='viewport' content='width=device-width'><h1>Shared browser</h1><input id='note' value='Keep this text'><div style='height:1800px'>A live page</div>", baseURL: URL(string: "https://example.com"))
        for _ in 0..<100 {
            if let value = try? await webView.evaluateJavaScript("document.getElementById('note')?.value"), value as? String == "Keep this text" { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "agora-chat-fixture", .value: UUID().uuidString, .secure: "TRUE"]))
        let cookies = webView.configuration.websiteDataStore.httpCookieStore
        await withCheckedContinuation { continuation in cookies.setCookie(cookie) { continuation.resume() } }
        _ = try await webView.evaluateJavaScript("window.scrollTo(0, 60); window.location.hash = 'second'")
        let scroll = try await webView.evaluateJavaScript("window.scrollY") as? Double
        let historyCount = webView.backForwardList.backList.count
        let identity = ObjectIdentifier(webView)
        for presentation: BrowserPresentation in [.thumbnail, .expanded, .hidden, .thumbnail] {
            workspace.browser.setPresentationFromUser(presentation)
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(ObjectIdentifier(workspace.browser.webView), identity)
            XCTAssertNotNil(webView.superview)
            let input = try await webView.evaluateJavaScript("document.getElementById('note').value")
            XCTAssertEqual(input as? String, "Keep this text")
            let offset = try await webView.evaluateJavaScript("window.scrollY") as? Double
            XCTAssertEqual(offset, scroll)
            let savedCookies = await withCheckedContinuation { continuation in cookies.getAllCookies { continuation.resume(returning: $0) } }
            XCTAssertTrue(savedCookies.contains { $0.name == cookie.name && $0.value == cookie.value })
            XCTAssertEqual(webView.backForwardList.backList.count, historyCount)
            try capture(window, name: "browser-\(presentation)")
        }
        await withCheckedContinuation { continuation in cookies.delete(cookie) { continuation.resume() } }
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768); host.view.frame = window.bounds
        workspace.browser.setPresentationFromUser(.expanded)
        try await Task.sleep(for: .milliseconds(300)); try capture(window, name: "wide-browser")
        XCTAssertEqual(ObjectIdentifier(workspace.browser.webView), identity)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852); host.view.frame = window.bounds
        workspace.agent.newChat()
        window.overrideUserInterfaceStyle = .light
        try await Task.sleep(for: .milliseconds(300)); try capture(window, name: "empty")
        workspace.agent.messages = [ChatMessage(role: "assistant", text: "### A reusable recipe\n1. Measure your coffee.\n2. Heat your water.\n```swift\nlet coffee = 18\nlet water = coffee * 16\n```"), ChatMessage(role: "notice", text: "The internet connection appears to be offline.")]
        let approval = ChatMessage(role: "approval", text: "")
        approval.approval = .init(id: UUID(), title: "Add this Calendar event?", detail: "Coffee shopping · Sunday, 10–11 AM\nThis approval applies once.")
        workspace.agent.messages.append(approval)
        workspace.agent.conversations.current.draft = "Keep my draft"
        workspace.agent.conversations.current.attachments = [.init(name: "Coffee notes.txt", data: Data("Recipe".utf8), mimeType: "text/plain", extractedText: "Recipe")]
        try await Task.sleep(for: .milliseconds(300)); try capture(window, name: "approval-attachments")
        host.rootView = AnyView(ChatHistorySheet(store: workspace.agent.conversations, agent: workspace.agent, showSettings: {}).tint(.teal))
        try await Task.sleep(for: .milliseconds(300)); try capture(window, name: "history")
    }
    private func capture(_ window: UIWindow, name: String) throws {
        window.layoutIfNeeded()
        func inspect(_ view: UIView) {
            if let scroll = view as? UIScrollView, !(scroll is UITextView) {
                print("CHAT_LAYOUT \(name) \(type(of: scroll)) offset=\(scroll.contentOffset) content=\(scroll.contentSize) bounds=\(scroll.bounds.size)")
            }
            view.subviews.forEach(inspect)
        }
        inspect(window)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "Chat · \(name)"; attachment.lifetime = .keepAlways; add(attachment)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agora-chat-\(name).png")
        try XCTUnwrap(image.pngData()).write(to: path)
        print("CHAT_SCREENSHOT \(path.path)")
    }
}
