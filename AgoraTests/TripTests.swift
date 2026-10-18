import XCTest
@testable import Agora

private let tripHousehold = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let tripListID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let tripItemID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
private let tripNow = CalendarCall.date("2026-10-17T08:00:00Z")!

private func tripListJSON(id: UUID = tripListID, deadline: String? = "2026-10-18T18:00:00Z") -> [String: Any] {
    ["id": id.uuidString, "household_id": tripHousehold.uuidString, "name": "Groceries", "status": "open",
     "source": "generated", "needed_by": deadline as Any? ?? NSNull(), "open_count": 1,
     "updated_at": "2026-10-17T07:30:00.123456Z", "items": [["id": tripItemID.uuidString,
        "title": "Milk", "quantity": 2, "checked": false, "explanation": "Milk runs out tomorrow."]]]
}
private func decodeTripList(_ row: [String: Any]) throws -> TripList {
    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TripList.self, from: JSONSerialization.data(withJSONObject: row))
}

final class TripPlannerTests: XCTestCase {
    private var options: TripPlanningOptions { TripPlanningOptions(days: 2, startHour: 9, endHour: 20, durationMinutes: 60, timezone: "UTC") }
    func testStoreGroupsPreserveEveryListAndSeparateMerchantLocations() throws {
        let downtown = UUID(), north = UUID()
        func list(_ name: String, merchant: UUID?, locality: String = "") throws -> TripList {
            var row = tripListJSON(id: UUID()); row["name"] = name
            if let merchant {
                row["merchant"] = ["id": merchant.uuidString, "name": "Market", "locality": locality]
            }
            return try decodeTripList(row)
        }
        let lists = try [list("Weekend", merchant: downtown, locality: "Downtown"),
                         list("Household", merchant: nil),
                         list("Groceries", merchant: downtown, locality: "Downtown"),
                         list("Pickup", merchant: north, locality: "North")]
        let groups = TripListStoreGroup.group(lists)
        XCTAssertEqual(groups.map(\.name), ["Market · Downtown", "Market · North", "Any store"])
        XCTAssertEqual(groups[0].lists.map(\.name), ["Groceries", "Weekend"])
        XCTAssertEqual(Set(groups.flatMap(\.lists).map(\.id)), Set(lists.map(\.id)))
        XCTAssertTrue(TripListStoreGroup.group([]).isEmpty)
    }

    func testBusyIntervalsEarliestDeadlineAndMultipleStoresNeverOverlap() throws {
        let later = try decodeTripList(tripListJSON())
        let urgent = try decodeTripList(tripListJSON(id: UUID(), deadline: "2026-10-17T12:00:00Z"))
        let busy = TripBusyInterval(start: CalendarCall.date("2026-10-17T09:00:00Z")!, end: CalendarCall.date("2026-10-17T10:15:00Z")!)
        let result = try TripPlanner.propose(lists: [later, urgent], busy: [busy], options: options, now: tripNow)
        XCTAssertEqual(result.map(\.id), [urgent.id, later.id])
        XCTAssertEqual(result[0].start, busy.end)
        XCTAssertEqual(result[1].start, result[0].end)
        XCTAssertNil(result[0].warning)
    }
    func testLateDeadlineIsExplicitAndNoAvailabilityExplainsWhy() throws {
        let list = try decodeTripList(tripListJSON(deadline: "2026-10-16T18:00:00Z"))
        let late = try TripPlanner.propose(lists: [list], busy: [], options: options, now: tripNow)[0]
        XCTAssertTrue(late.canSchedule); XCTAssertNotNil(late.warning)
        let unknown = try TripPlanner.propose(lists: [list], busy: nil, options: options, now: tripNow)[0]
        XCTAssertFalse(unknown.canSchedule); XCTAssertTrue(unknown.explanation.contains("unknown"))
        let full = try TripPlanner.propose(lists: [list], busy: [.init(start: tripNow, end: tripNow.addingTimeInterval(3 * 86400))], options: options, now: tripNow)[0]
        XCTAssertFalse(full.canSchedule); XCTAssertTrue(full.explanation.contains("No 60-minute"))
    }
    func testDSTUsesLocalHoursAndCorrectOffsets() throws {
        let list = try decodeTripList(tripListJSON(deadline: nil))
        for (date, expected) in [("2026-03-08T00:00:00-08:00", "2026-03-08T09:00:00-07:00"),
                                 ("2026-11-01T00:00:00-07:00", "2026-11-01T09:00:00-08:00")] {
            var options = options; options.timezone = "America/Los_Angeles"
            let proposal = try TripPlanner.propose(lists: [list], busy: [], options: options, now: CalendarCall.date(date)!)[0]
            XCTAssertEqual(proposal.start, CalendarCall.date(expected))
            let call = try proposal.calendarCall()
            XCTAssertEqual(call.arguments["start"] as? String, expected)
        }
    }
    func testInvalidAndUnknownBusyFailClosed() throws {
        for response: [String: Any] in [[:], ["busy": "unknown"], ["busy": [], "errors": ["unavailable"]],
                                       ["busy": [["start": "2026-10-17T10:00:00Z", "end": "2026-10-17T09:00:00Z"]]]] {
            XCTAssertThrowsError(try TripBusyInterval.decode(response))
        }
        var invalid = options; invalid.days = 15
        XCTAssertThrowsError(try TripPlanner.window(options: invalid, now: tripNow))
        invalid = options; invalid.durationMinutes = 300
        XCTAssertThrowsError(try TripPlanner.window(options: invalid, now: tripNow))
    }
    func testLeadTimeAndCompletedTripsDoNotSuppressReplenishment() throws {
        let list = try decodeTripList(tripListJSON())
        let past = TripRecord(id: UUID(), householdId: tripHousehold, listId: list.id, userId: UUID(), mine: true,
                              listName: list.name, start: "2026-10-16T09:00:00Z", end: "2026-10-16T10:00:00Z", timezone: "UTC",
                              title: "Shopping", description: "", location: "", status: "scheduled", eventId: nil, eventUrl: nil,
                              createdAt: "2026-10-16T08:00:00Z", updatedAt: "2026-10-16T08:00:00Z")
        let result = try TripPlanner.propose(lists: [list], trips: [past], busy: [], options: options,
                                             now: CalendarCall.date("2026-10-17T08:59:30Z")!)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].start, CalendarCall.date("2026-10-17T09:05:00Z"))
    }
}

@MainActor
private final class TripGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = .init(id: "trip-alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes)
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "native-access" }
    func idToken(for accountID: String) async throws -> String { "identity" }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class TripHTTP: URLProtocol {
    static var fixture: TripServer!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, row) = Self.fixture.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: row))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

private final class TripServer {
    var manualList: [String: Any]?
    var itemWrites = 0
    var rejectListRead = false
    var record: [String: Any]?
    var event: [String: Any]?
    var createCount = 0
    var reservationCount = 0
    var checkCount = 0
    var generationKeys: [String] = []
    var unknownCreation = false
    var denyCreation = false
    var loseOutcome = false
    var conflictAtConfirmation = false
    var unknownAvailability = false
    private let lock = NSLock()
    func respond(_ request: URLRequest) -> (Int, Any) {
        lock.lock(); defer { lock.unlock() }
            let path = request.url!.path, body = TripHTTP.body(request)
            if request.url?.host == "www.googleapis.com" {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer native-access")
                if path.hasSuffix("/freeBusy") {
                    checkCount += 1
                    if unknownAvailability { return (200, ["calendars": ["primary": ["errors": [["reason": "internalError"]]]]]) }
                    let busy: [[String: Any]] = conflictAtConfirmation && checkCount > 1 ? [["start": body["timeMin"]!, "end": body["timeMax"]!]] : []
                    return (200, ["calendars": ["primary": ["busy": busy]]])
                }
                if request.httpMethod == "POST" {
                    createCount += 1
                    if denyCreation { return (403, ["error": ["errors": [["reason": "forbidden"]]]]) }
                    event = body; event!["htmlLink"] = "https://calendar.google.com/event?eid=trip"
                    if unknownCreation { return (503, ["error": [:]] as [String: Any]) }
                    return (201, event!)
                }
                if let event { return (200, event) }
                return (404, [:] as [String: Any])
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer identity")
            switch path {
            case "/v1/me": return (200, ["households": [["id": tripHousehold.uuidString, "name": "Home", "locations": []]]])
            case "/v1/inventory": return (200, [])
            case "/v1/lists/generate":
                generationKeys.append(request.value(forHTTPHeaderField: "Idempotency-Key")!)
                XCTAssertEqual(body["within_days"] as? Int, 7)
                return (200, ["lists": [], "added": 0, "skipped": []])
            case "/v1/lists":
                if request.httpMethod == "POST" {
                    var list = tripListJSON(id: UUID(), deadline: nil)
                    list["name"] = body["name"]; list["source"] = "user"
                    list["items"] = []; list["open_count"] = 0
                    manualList = list
                    return (201, list)
                }
                return (200, [tripListJSON()] + (manualList.map { [$0] } ?? []))
            case "/v1/trips":
                if request.httpMethod == "POST" {
                    reservationCount += 1
                    XCTAssertEqual(body["list_updated_at"] as? String, "2026-10-17T07:30:00.123456Z")
                    var result = body; result.removeValue(forKey: "list_updated_at")
                    result["id"] = UUID().uuidString; result["household_id"] = tripHousehold.uuidString
                    result["user_id"] = UUID().uuidString; result["mine"] = true; result["list_name"] = "Groceries"
                    result["status"] = "reserved"; result["created_at"] = "2026-10-17T08:00:00Z"; result["updated_at"] = "2026-10-17T08:00:00Z"
                    record = result; return (201, result)
                }
                return (200, record.map { [$0] } ?? [])
            default:
                if let manualList, path == "/v1/lists/\(manualList["id"]!)" {
                    if rejectListRead { return (503, ["title": "unavailable"]) }
                    return (200, manualList)
                }
                if let manualList, path == "/v1/lists/\(manualList["id"]!)/items", request.httpMethod == "POST" {
                    itemWrites += 1
                    var item = body; item["id"] = UUID().uuidString; item["checked"] = false
                    self.manualList?["items"] = [item]; self.manualList?["open_count"] = 1
                    return (201, item)
                }
                if path.hasSuffix("/outcome") {
                    if record?["status"] as? String == "scheduled", body["status"] as? String == "outcome_unknown" {
                        return (409, ["title": "trip_state_conflict"])
                    }
                    for (key, value) in body { record?[key] = value }
                    if loseOutcome, body["status"] as? String == "scheduled" { loseOutcome = false; return (503, ["title": "unavailable"]) }
                    return (200, record!)
                }
                return (404, ["title": "not_found"])
            }
    }
}

@MainActor
final class TripStoreTests: XCTestCase {
    private var calendar: CalendarConnection!
    private var inventory: InventoryStore!
    private var store: TripStore!
    private var api: AgoraClient!
    private var http: URLSession!
    private var server: TripServer!
    private var options: TripPlanningOptions { .init(days: 2, startHour: 9, endHour: 20, durationMinutes: 60, timezone: "UTC") }
    override func setUp() async throws {
        server = TripServer(); TripHTTP.fixture = server
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [TripHTTP.self]
        http = URLSession(configuration: configuration)
        calendar = CalendarConnection(authorization: TripGoogle(), http: http); await calendar.refresh()
        api = AgoraClient(calendar: calendar, baseURL: URL(string: "https://trips.example.com"), http: http)
        inventory = InventoryStore(api: api, calendar: calendar); await inventory.refresh()
        store = TripStore(api: api, inventory: inventory, calendar: calendar, now: { tripNow })
    }
    override func tearDown() async throws {
        http.invalidateAndCancel(); TripHTTP.fixture = nil
        store = nil; api = nil; inventory = nil; calendar = nil; http = nil; server = nil
    }
    func testManualListSaveDoesNotRequireCalendarAvailabilityAndInvalidatesProposals() async throws {
        await store.plan(options: options)
        XCTAssertFalse(store.proposals.isEmpty)
        let checks = server.checkCount
        server.unknownAvailability = true
        let id = try await store.createList(name: "  Errands  ", merchantID: nil)
        XCTAssertEqual(store.lists.first?.name, "Errands")
        XCTAssertTrue(store.proposals.isEmpty)
        server.rejectListRead = true
        try await store.addItem(listID: id, draft: TripItemDraft(title: "Soap", quantity: "2", unit: "bars"))
        XCTAssertEqual(server.itemWrites, 1)
        XCTAssertEqual(store.lists.first?.items.first?.title, "Soap")
        XCTAssertEqual(store.lists.first?.openCount, 1)
        XCTAssertNotNil(store.notice, "A failed refresh after a confirmed write must not ask for a second POST")
        XCTAssertEqual(server.checkCount, checks)
    }

    func testManualItemValidationRejectsInvalidInputAndSupportsDecimalComma() throws {
        for quantity in ["0", "-1", "1001", "NaN", "1,000", "1.2.3", "2 bottles", ""] {
            XCTAssertThrowsError(try TripItemDraft(title: "Milk", quantity: quantity).body(locale: Locale(identifier: "en_US")))
        }
        XCTAssertThrowsError(try TripItemDraft(title: "  ").body())
        XCTAssertThrowsError(try TripItemDraft(title: String(repeating: "a", count: 121)).body())
        XCTAssertThrowsError(try TripItemDraft(title: "Milk", unit: String(repeating: "a", count: 21)).body())
        let body = try TripItemDraft(title: " Apples ", quantity: "1,5", unit: " kg ").body(locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(body["quantity"] as? Double, 1.5)
        XCTAssertEqual(body["title"] as? String, "Apples")
        XCTAssertEqual(body["unit"] as? String, "kg")
    }

    func testPlanningThenExplicitApprovalReservesCreatesAndReportsOutcome() async throws {
        await store.plan(options: options)
        XCTAssertNil(store.error); XCTAssertEqual(store.proposals.count, 1)
        XCTAssertEqual(server.createCount, 0); XCTAssertEqual(server.reservationCount, 0)
        let proposal = try XCTUnwrap(store.proposals.first)
        await inventory.refresh()
        XCTAssertEqual(store.proposals.count, 1, "Routine inventory refresh must preserve approval context")
        await store.refresh()
        XCTAssertEqual(store.proposals.first?.reservationKey, proposal.reservationKey, "Background trip refresh must preserve unchanged approvals")
        await store.schedule(proposal)
        XCTAssertNil(store.error); XCTAssertEqual(server.checkCount, 2)
        XCTAssertEqual(server.reservationCount, 1); XCTAssertEqual(server.createCount, 1)
        XCTAssertEqual(store.trips.first?.status, "scheduled")
        XCTAssertNotNil(store.trips.first?.eventId)
        await store.schedule(proposal); XCTAssertEqual(server.createCount, 1)
    }
    func testUncertainCreateAndRestartRecoverWithReadOnlyLookup() async throws {
        await store.plan(options: options); server.unknownCreation = true
        await store.schedule(try XCTUnwrap(store.proposals.first))
        XCTAssertEqual(store.trips.first?.status, "outcome_unknown")
        await store.resume(try XCTUnwrap(store.trips.first))
        XCTAssertEqual(server.createCount, 1, "An uncertain trip is never eligible for another create")
        let restarted = TripStore(api: api, inventory: inventory, calendar: calendar, now: { tripNow })
        await restarted.refresh()
        await restarted.plan(options: options)
        XCTAssertTrue(restarted.proposals.isEmpty)
        await restarted.reconcile(try XCTUnwrap(restarted.trips.first))
        XCTAssertNil(restarted.error); XCTAssertEqual(restarted.trips.first?.status, "scheduled")
        XCTAssertEqual(server.createCount, 1); XCTAssertEqual(server.reservationCount, 1)
    }
    func testLostOutcomeWriteDoesNotRepeatExternalEffect() async throws {
        await store.plan(options: options); server.loseOutcome = true
        await store.schedule(try XCTUnwrap(store.proposals.first))
        XCTAssertEqual(store.trips.first?.status, "outcome_unknown")
        await store.reconcile(try XCTUnwrap(store.trips.first))
        XCTAssertEqual(store.trips.first?.status, "scheduled"); XCTAssertEqual(server.createCount, 1)
    }
    func testReservedRecoveryChecksForExistingEventBeforeCreating() async throws {
        await store.plan(options: options)
        await store.schedule(try XCTUnwrap(store.proposals.first))
        server.record?["status"] = "reserved"
        await store.refresh()
        await store.resume(try XCTUnwrap(store.trips.first))
        XCTAssertNil(store.error); XCTAssertEqual(store.trips.first?.status, "scheduled")
        XCTAssertEqual(server.createCount, 1, "A reserved trip with an existing event is recovered using GET only")
    }
    func testReservedBeforeCalendarCallCanResumeSameDeterministicEvent() async throws {
        await store.plan(options: options)
        await store.schedule(try XCTUnwrap(store.proposals.first))
        let originalEventID = server.event?["id"] as? String
        server.record?["status"] = "reserved"; server.event = nil; server.createCount = 0
        await store.refresh()
        await store.resume(try XCTUnwrap(store.trips.first))
        XCTAssertNil(store.error); XCTAssertEqual(store.trips.first?.status, "scheduled")
        XCTAssertEqual(server.createCount, 1); XCTAssertEqual(server.event?["id"] as? String, originalEventID)
        XCTAssertEqual(server.reservationCount, 1, "Recovery reuses the persisted reservation")
    }
    func testDefiniteCalendarDenialMarksFailedAndAllowsReplanning() async throws {
        await store.plan(options: options); server.denyCreation = true
        await store.schedule(try XCTUnwrap(store.proposals.first))
        XCTAssertNotNil(store.error); XCTAssertEqual(store.trips.first?.status, "failed")
        XCTAssertNil(server.event)
        await store.plan(options: options)
        XCTAssertEqual(store.proposals.count, 1)
    }
    func testAbsentCalendarLookupOffersReleaseWithoutCreating() async throws {
        await store.plan(options: options); server.unknownCreation = true
        await store.schedule(try XCTUnwrap(store.proposals.first))
        XCTAssertEqual(store.trips.first?.status, "outcome_unknown")
        server.event = nil
        await store.reconcile(try XCTUnwrap(store.trips.first))
        XCTAssertEqual(store.trips.first?.status, "outcome_unknown")
        XCTAssertEqual(server.createCount, 1)
        XCTAssertTrue(store.notice?.contains("release") == true)
        await store.release(try XCTUnwrap(store.trips.first))
        XCTAssertNil(store.error); XCTAssertEqual(store.trips.first?.status, "failed")
        XCTAssertEqual(server.createCount, 1)
        await store.plan(options: options)
        XCTAssertEqual(store.proposals.count, 1)
    }
    func testReservedPastSlotCanReleaseWithoutCreating() async throws {
        await store.plan(options: options)
        await store.schedule(try XCTUnwrap(store.proposals.first))
        server.record?["status"] = "reserved"; server.event = nil; server.createCount = 0
        await store.refresh()
        let past = tripNow.addingTimeInterval(3600)
        let pastStore = TripStore(api: api, inventory: inventory, calendar: calendar, now: { past })
        await pastStore.refresh()
        await pastStore.resume(try XCTUnwrap(pastStore.trips.first))
        XCTAssertNotNil(pastStore.error); XCTAssertEqual(pastStore.trips.first?.status, "reserved")
        XCTAssertEqual(server.createCount, 0)
        await pastStore.release(try XCTUnwrap(pastStore.trips.first))
        XCTAssertNil(pastStore.error); XCTAssertEqual(pastStore.trips.first?.status, "failed")
        XCTAssertEqual(server.createCount, 0)
    }
    func testExistingEventFingerprintMismatchBlocksReservedResume() async throws {
        await store.plan(options: options)
        await store.schedule(try XCTUnwrap(store.proposals.first))
        server.record?["status"] = "reserved"
        server.event?["extendedProperties"] = ["private": ["agora_request": "different"]]
        await store.refresh()
        await store.resume(try XCTUnwrap(store.trips.first))
        XCTAssertNotNil(store.error); XCTAssertEqual(store.trips.first?.status, "reserved")
        XCTAssertEqual(server.createCount, 1)
    }
    func testConflictAndUnknownAvailabilityNeverReserveOrCreate() async {
        await store.plan(options: options); server.conflictAtConfirmation = true
        await store.schedule(store.proposals[0])
        XCTAssertNotNil(store.error); XCTAssertEqual(server.reservationCount, 0); XCTAssertEqual(server.createCount, 0)
        server.unknownAvailability = true
        await store.plan(options: options)
        XCTAssertNotNil(store.error); XCTAssertTrue(store.proposals.isEmpty)
    }
    func testRecoveryRejectsAnEventEditedOutsideAgora() async throws {
        await store.plan(options: options)
        server.unknownCreation = true
        await store.schedule(try XCTUnwrap(store.proposals.first))
        // Google retains private properties when a user edits the event itself.
        server.event?["start"] = ["dateTime": "2026-10-20T09:00:00Z", "timeZone": "UTC"]
        let trip = try XCTUnwrap(store.trips.first)
        await store.reconcile(trip)
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.trips.first?.status, "outcome_unknown")
        XCTAssertEqual(server.createCount, 1)
    }
    func testSignOutInvalidatesAnAlreadyApprovedProposal() async throws {
        await store.plan(options: options)
        let proposal = try XCTUnwrap(store.proposals.first), originalContext = store.context
        await calendar.signOut()
        XCTAssertNotEqual(store.context, originalContext); XCTAssertFalse(store.canUse)
        await store.schedule(proposal)
        XCTAssertTrue(store.lists.isEmpty); XCTAssertTrue(store.trips.isEmpty); XCTAssertTrue(store.proposals.isEmpty)
        XCTAssertEqual(server.createCount, 0); XCTAssertEqual(server.reservationCount, 0)
    }
    func testHouseholdContextChangeInvalidatesApproval() async throws {
        await store.plan(options: options)
        let proposal = try XCTUnwrap(store.proposals.first), previous = store.context
        inventory.reset(accountID: calendar.accountID)
        XCTAssertNotEqual(store.context, previous)
        await store.schedule(proposal)
        XCTAssertTrue(store.proposals.isEmpty); XCTAssertEqual(server.createCount, 0)
        await inventory.refresh(); await store.refresh()
        XCTAssertNil(store.error); XCTAssertEqual(store.lists.count, 1)
    }
}
