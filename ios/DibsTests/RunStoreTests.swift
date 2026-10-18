import XCTest
@testable import Dibs

/// A socket the test drives by hand.
@MainActor
final class FakeSocket: RunSocketing {
    var onMessage: ((ServerMsg) -> Void)?
    var onEvent: ((SocketEvent) -> Void)?
    var isOpen = false
    var started = 0
    var stopped = 0
    var sent: [ClientMsg] = []

    func start() { started += 1 }
    func stop() { stopped += 1 }
    func send(_ msg: ClientMsg) -> Bool {
        guard isOpen else { return false }
        sent.append(msg)
        return true
    }

    func open() { isOpen = true; onEvent?(.open) }
    func drop() { isOpen = false; onEvent?(.closed(retryIn: 0.5)) }
    func refuse() { isOpen = false; onEvent?(.refused) }
    func deliver(_ msg: ServerMsg) { onMessage?(msg) }
}

/// REST fetches the test releases one by one, in any order.
@MainActor
final class FetchGate {
    private(set) var calls: [String] = []
    private var waiting: [CheckedContinuation<Run, Error>] = []

    func fetch(_ runId: String) async throws -> Run {
        calls.append(runId)
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    var pending: Int { waiting.count }

    /// Resolves fetch number `index` (0-based among those still waiting).
    func resolve(_ index: Int = 0, with run: Run) { waiting.remove(at: index).resume(returning: run) }
    func fail(_ index: Int = 0, _ error: Error) { waiting.remove(at: index).resume(throwing: error) }
}

@MainActor
final class RunStoreTests: XCTestCase {
    private var gate: FetchGate!
    private var sockets: [FakeSocket] = []
    private var store: RunStore!

    override func setUp() async throws {
        gate = FetchGate()
        sockets = []
        let gate = self.gate!
        store = RunStore(
            fetchRun: { runId in try await gate.fetch(runId) },
            makeSocket: { [unowned self] _, _ in
                let s = FakeSocket()
                self.sockets.append(s)
                return s
            }
        )
    }

    private func run(_ id: String = "r1", chips: [Chip] = [], lastCallEndsAt: Double? = nil) -> Run {
        Run(id: id, shopperId: "jake",
            people: [Person(id: "jake", name: "Jake", initial: "J", isShopper: true),
                     Person(id: "p1", name: "Priya", initial: "P", isShopper: false, authorizedCents: 4000)],
            chips: chips, lastCallEndsAt: lastCallEndsAt)
    }

    private func chip(_ id: String, _ state: ChipState = .open) -> Chip { Chip(id: id, name: id, state: state) }

    /// Lets queued main-actor work run until `condition` holds.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    func testFetchesOverRESTOnOpenBeforeApplyingSocketMessages() async throws {
        store.connect(runId: "r1", personId: "p1")
        XCTAssertEqual(store.connection, .connecting)
        XCTAssertEqual(sockets.count, 1)
        XCTAssertEqual(sockets[0].started, 1)

        sockets[0].open()
        XCTAssertEqual(store.connection, .live)
        await settle { self.gate.pending == 1 }
        XCTAssertEqual(gate.calls, ["r1"])

        // The socket's snapshot and an update arrive while the fetch is in flight: they wait.
        sockets[0].deliver(.run(run(chips: [chip("a")])))
        sockets[0].deliver(.run(run(chips: [chip("a"), chip("b")])))
        XCTAssertNil(store.run)

        gate.resolve(with: run(chips: []))
        // REST first, then the held messages in order: the newest state wins.
        await settle { self.store.run?.chips.count == 2 }
        XCTAssertEqual(store.run?.chips.map(\.id), ["a", "b"])
        XCTAssertEqual(store.me?.name, "Priya")
    }

    func testReFetchesOnEveryReconnect() async throws {
        store.connect(runId: "r1", personId: "p1")
        sockets[0].open()
        await settle { self.gate.pending == 1 }
        gate.resolve(with: run(chips: [chip("a")]))
        await settle { self.store.run != nil }

        sockets[0].drop()
        XCTAssertEqual(store.connection, .reconnecting)
        sockets[0].open()
        XCTAssertEqual(store.connection, .live)
        await settle { self.gate.pending == 1 }
        XCTAssertEqual(gate.calls, ["r1", "r1"])
        gate.resolve(with: run(chips: [chip("a"), chip("z")]))
        await settle { self.store.run?.chips.count == 2 }
    }

    func testDropsAFetchFromAnEarlierConnection() async throws {
        store.connect(runId: "r1", personId: "p1")
        sockets[0].open()
        await settle { self.gate.pending == 1 }
        sockets[0].drop()
        sockets[0].open()
        await settle { self.gate.pending == 2 }

        // The newer fetch lands first, then the stale one: the stale one is ignored.
        gate.resolve(1, with: run(chips: [chip("new")]))
        await settle { self.store.run?.chips.first?.id == "new" }
        gate.resolve(0, with: run(chips: [chip("old")]))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(store.run?.chips.first?.id, "new")
    }

    func testDropsMessagesFromAPreviousSocketAndOtherRuns() async throws {
        store.connect(runId: "r1", personId: "p1")
        let old = sockets[0]
        store.connect(runId: "r2", personId: "p1")
        XCTAssertEqual(old.stopped, 1)
        let current = sockets[1]
        current.open()
        await settle { self.gate.pending == 1 }
        gate.resolve(with: run("r2", chips: [chip("mine")]))
        await settle { self.store.run?.id == "r2" }

        old.deliver(.run(run("r1", chips: [chip("stale")])))
        old.onEvent?(.refused)
        current.deliver(.run(run("r1", chips: [chip("wrong run")])))
        XCTAssertEqual(store.run?.id, "r2")
        XCTAssertEqual(store.run?.chips.map(\.id), ["mine"])
        XCTAssertEqual(store.connection, .live)
    }

    func testHeldMessagesFromADroppedConnectionAreDiscarded() async throws {
        store.connect(runId: "r1", personId: "p1")
        sockets[0].open()
        await settle { self.gate.pending == 1 }
        sockets[0].deliver(.run(run(chips: [chip("stale")])))
        sockets[0].drop()
        sockets[0].open()
        await settle { self.gate.pending == 2 }
        gate.resolve(1, with: run(chips: [chip("fresh")]))
        await settle { self.store.run != nil }
        XCTAssertEqual(store.run?.chips.map(\.id), ["fresh"])
    }

    func testRefusedSendSetsLastError() async throws {
        store.connect(runId: "r1", personId: "p1")
        XCTAssertFalse(store.claim("c1"))
        XCTAssertEqual(store.lastError, "Reconnecting…")

        sockets[0].open()
        XCTAssertNil(store.lastError)
        XCTAssertTrue(store.claim("c1"))
        XCTAssertTrue(store.leave("c1"))
        XCTAssertTrue(store.remove("c1"))
        XCTAssertTrue(store.undoRemove("c1"))
        XCTAssertEqual(sockets[0].sent, [.claim(chipId: "c1"), .leave(chipId: "c1"), .remove(chipId: "c1"), .undoRemove(chipId: "c1")])
    }

    func testServerRefusalStopsAndMarksRefused() {
        store.connect(runId: "r1", personId: "nobody")
        sockets[0].refuse()
        XCTAssertEqual(store.connection, .refused)
    }

    func testServerErrorMessageSetsLastError() async {
        store.connect(runId: "r1", personId: "p1")
        sockets[0].deliver(.error(reason: "cart closed"))
        XCTAssertEqual(store.lastError, "cart closed")
        sockets[0].deliver(.error(reason: "cart closed"))
        XCTAssertEqual(store.errorSeq, 2)
    }

    func testSendFrameIncludesDetectAndNeverSetsError() async throws {
        store.connect(runId: "r1", personId: "jake")
        XCTAssertFalse(store.sendFrame(jpeg: Data([1, 2, 3]), detect: false))
        XCTAssertNil(store.lastError)
        sockets[0].open()
        XCTAssertTrue(store.sendFrame(jpeg: Data([1, 2, 3]), detect: false))
        guard case .frame(let b64, let at, let detect)? = sockets[0].sent.last else { return XCTFail("no frame") }
        XCTAssertEqual(b64, "AQID")
        XCTAssertFalse(detect)
        XCTAssertEqual(at, (Date().timeIntervalSince1970 * 1000), accuracy: 5000)
    }

    func testLastCallIdentifyingAndFrames() async throws {
        store.connect(runId: "r1", personId: "p1")
        sockets[0].deliver(.lastCall(endsAt: 1_700_000_010_000))
        XCTAssertEqual(store.lastCallEndsAt, Date(timeIntervalSince1970: 1_700_000_010))
        sockets[0].deliver(.identifying(region: Box(x: 1, y: 2, w: 3, h: 4)))
        XCTAssertEqual(store.identifyingRegion, Box(x: 1, y: 2, w: 3, h: 4))

        // A run with a chip still identifying keeps the outline; one without clears it.
        sockets[0].deliver(.run(run(chips: [chip("a", .identifying)], lastCallEndsAt: 1_700_000_010_000)))
        XCTAssertNotNil(store.identifyingRegion)
        sockets[0].deliver(.run(run(chips: [chip("a", .open)])))
        XCTAssertNil(store.identifyingRegion)
        XCTAssertNil(store.lastCallEndsAt)

        // 1x1 PNG.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
        sockets[0].deliver(.frame(jpegBase64: png, at: 1))
        XCTAssertNotNil(store.liveFrame)
    }
}
