import XCTest
import SwiftUI
@testable import Agora

// Only this test transport rewrites the synthetic HTTPS origin to an isolated local API.
private final class TripLiveHTTP: URLProtocol {
    private var forwardedTask: URLSessionDataTask?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "trips-live.example.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var forwarded = request
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = "http"; components.host = "127.0.0.1"; components.port = 18765
        forwarded.url = components.url
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            forwarded.httpBodyStream = nil; forwarded.httpBody = data
        }
        forwardedTask = URLSession.shared.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            if let response { self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            if let data { self.client?.urlProtocol(self, didLoad: data) }
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }
    override func stopLoading() { forwardedTask?.cancel() }
}

@MainActor
private final class TripLiveSession: DemoSessionStoring {
    var session: DemoSession?
    func load() throws -> DemoSession? { session }
    func save(_ session: DemoSession?) throws { self.session = session }
}

@MainActor
final class TripLiveTests: XCTestCase {
    func testReplenishmentThroughCalendarAndRestartAgainstRealBackend() async throws {
        var probe = URLRequest(url: URL(string: "http://127.0.0.1:18765/healthz")!)
        probe.timeoutInterval = 2
        do { _ = try await URLSession.shared.data(for: probe) }
        catch { throw XCTSkip("Start the isolated API with tests.support.ios_inventory_server on port 18765.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TripLiveHTTP.self]
        let http = URLSession(configuration: configuration)
        defer { http.invalidateAndCancel() }
        let origin = URL(string: "https://trips-live.example.com")!
        let session = TripLiveSession()
        let calendar = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await calendar.connectDemo(handle: "demo", password: "")
        XCTAssertTrue(calendar.connected, calendar.message ?? "Sign-in failed")
        XCTAssertTrue(calendar.isDemoAccount)
        let api = AgoraClient(calendar: calendar, baseURL: origin, http: http)
        let inventory = InventoryStore(api: api, calendar: calendar)
        await inventory.refresh()
        XCTAssertNil(inventory.error)
        let trips = TripStore(api: api, inventory: inventory, calendar: calendar)
        await trips.refresh()
        XCTAssertNil(trips.error)
        let initialEvents = try await api.requestJSON("v1/demo/calendar/events") as? [[String: Any]]
        let initialCount = try XCTUnwrap(initialEvents).count

        var options = TripPlanningOptions()
        options.days = 14; options.startHour = 0; options.endHour = 24
        options.durationMinutes = 30; options.timezone = "America/Los_Angeles"
        await trips.plan(options: options)
        XCTAssertNil(trips.error, trips.error ?? "")
        let proposal = try XCTUnwrap(trips.proposals.first { $0.canSchedule }, "Seeded run-outs must yield a shopping trip")
        XCTAssertFalse(proposal.list.items.isEmpty)
        XCTAssertTrue(proposal.list.items.contains { $0.explanation != nil })
        let plannedEvents = try await api.requestJSON("v1/demo/calendar/events") as? [[String: Any]]
        XCTAssertEqual(plannedEvents?.count, initialCount, "Planning must wait for approval before creating an event")
        try await render(TripsView(store: trips), name: "Shopping trip suggestions")

        await trips.schedule(proposal)
        XCTAssertNil(trips.error, trips.error ?? "")
        let trip = try XCTUnwrap(trips.trips.first { $0.listId == proposal.list.id && $0.status == "scheduled" })
        XCTAssertNotNil(trip.eventId)
        let eventResponse = try await api.requestJSON("v1/demo/calendar/events")
        let savedEvents = try XCTUnwrap(eventResponse as? [[String: Any]])
        XCTAssertEqual(savedEvents.count, initialCount + 1)
        let event = try XCTUnwrap(savedEvents.first { $0["id"] as? String == trip.eventId })
        XCTAssertEqual(event["title"] as? String, proposal.title)
        XCTAssertEqual((event["start"] as? String).flatMap(CalendarCall.date), proposal.start)
        XCTAssertEqual(event["description"] as? String, proposal.description)
        let existing = try await calendar.lookupExistingEvent(try trip.calendarCall(), taskID: trip.id,
                                                               expectedAccountID: try XCTUnwrap(calendar.accountID))
        XCTAssertEqual(existing?["id"] as? String, trip.eventId)

        // Restore the authenticated session and state from the actual database.
        let restoredCalendar = CalendarConnection(http: http, demoBaseURL: origin, sessionStore: session)
        await restoredCalendar.refresh()
        let restoredAPI = AgoraClient(calendar: restoredCalendar, baseURL: origin, http: http)
        let restoredInventory = InventoryStore(api: restoredAPI, calendar: restoredCalendar)
        await restoredInventory.refresh()
        let restored = TripStore(api: restoredAPI, inventory: restoredInventory, calendar: restoredCalendar)
        await restored.refresh()
        XCTAssertTrue(restored.trips.contains { $0.id == trip.id && $0.status == "scheduled" })
        await restored.plan(options: options)
        XCTAssertNil(restored.error)
        XCTAssertFalse(restored.proposals.contains { $0.list.id == trip.listId && $0.canSchedule })
        let afterRestart = try await restoredAPI.requestJSON("v1/demo/calendar/events") as? [[String: Any]]
        XCTAssertEqual(afterRestart?.count, initialCount + 1)
        if let item = proposal.list.items.first {
            await restored.setChecked(listID: proposal.list.id, itemID: item.id, checked: true)
            XCTAssertNil(restored.error)
            XCTAssertEqual(restored.lists.first { $0.id == proposal.list.id }?.items.first { $0.id == item.id }?.checked, true)
        }
        try await render(TripsView(store: restored), name: "Scheduled shopping trips")
        _ = try await restoredAPI.request("v1/lists/\(proposal.list.id)", method: "PATCH", body: ["status": "done"])
    }

    private func render<Content: View>(_ content: Content, name: String) async throws {
        let controller = UIHostingController(rootView: NavigationStack { content })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
