import XCTest
@testable import Agora

@MainActor
private final class ClientFakeGoogle: GoogleCalendarAuthorizing {
    var configurationIssue: String?
    var account: GoogleCalendarAccount? = GoogleCalendarAccount(
        id: "alice", email: "alice@example.com", scopes: GoogleCalendarAuthorization.scopes
    )
    var idTokenValue = "google-identity-alice"
    var idTokenCalls = 0
    func restore() async throws -> GoogleCalendarAccount? { account }
    func connect() async throws -> GoogleCalendarAccount { account! }
    func accessToken(for accountID: String) async throws -> String { "access-\(accountID)" }
    func idToken(for accountID: String) async throws -> String {
        idTokenCalls += 1
        guard accountID == account?.id else { throw BrowserError("calendar_account_changed") }
        return idTokenValue
    }
    func signOut() { account = nil }
    func disconnect() async throws { account = nil }
}

private final class AgoraURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = Self.handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct InventoryRow: Decodable, Equatable {
    let id: String
    let displayName: String
}

@MainActor
final class AgoraClientTests: XCTestCase {
    private var auth: ClientFakeGoogle!
    private var calendar: CalendarConnection!
    private var http: URLSession!

    override func setUp() async throws {
        auth = ClientFakeGoogle()
        calendar = CalendarConnection(authorization: auth)
        await calendar.refresh()
        XCTAssertTrue(calendar.connected)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgoraURLProtocol.self]
        http = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        http.invalidateAndCancel()
        AgoraURLProtocol.handler = nil
        calendar = nil
        auth = nil
    }

    func testIDTokenBearerAndSoftUnauthorized() async throws {
        var sawAuth: String?
        AgoraURLProtocol.handler = { request in
            sawAuth = request.value(forHTTPHeaderField: "Authorization")
            if request.url!.path.hasSuffix("/v1/me") {
                return (200, ["email": "alice@example.com"])
            }
            return (401, ["title": "invalid_token", "detail": "Sign in again."])
        }

        let client = AgoraClient(calendar: calendar, baseURL: URL(string: "https://api.example.com"), http: http)
        let me = try await client.request("v1/me")
        XCTAssertEqual(sawAuth, "Bearer google-identity-alice")
        XCTAssertEqual(me["email"] as? String, "alice@example.com")
        XCTAssertEqual(auth.idTokenCalls, 1)
        XCTAssertTrue(calendar.connected)

        do {
            _ = try await client.request("v1/inventory")
            XCTFail("Expected 401")
        } catch let error as BrowserError {
            XCTAssertEqual(error.code, "invalid_token")
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(calendar.connected, "Agora 401 must not sign out of Google")
        }
    }

    func testDecodableFetchListAndMissingBaseURL() async throws {
        AgoraURLProtocol.handler = { _ in
            (200, [["id": "item-1", "display_name": "Milk"], ["id": "item-2", "display_name": "Eggs"]])
        }
        let client = AgoraClient(calendar: calendar, baseURL: URL(string: "https://api.example.com"), http: http)
        let items = try await client.fetch("v1/inventory", as: [InventoryRow].self)
        XCTAssertEqual(items, [InventoryRow(id: "item-1", displayName: "Milk"), InventoryRow(id: "item-2", displayName: "Eggs")])

        // A relative URL has no origin. An empty string can return nil and select the bundled live URL.
        let missing = AgoraClient(calendar: calendar, baseURL: try XCTUnwrap(URL(string: "/")), http: http)
        XCTAssertFalse(missing.isConfigured)
        do {
            _ = try await missing.fetch("v1/inventory", as: [InventoryRow].self)
            XCTFail("Expected not configured")
        } catch let error as BrowserError {
            XCTAssertEqual(error.code, "agora_not_configured")
        }
    }

    func testIdempotencyKeyOnMutatingRequest() async throws {
        var sawKey: String?
        AgoraURLProtocol.handler = { request in
            sawKey = request.value(forHTTPHeaderField: "Idempotency-Key")
            return (201, ["ok": true])
        }
        let client = AgoraClient(calendar: calendar, baseURL: URL(string: "https://api.example.com"), http: http)
        _ = try await client.request("v1/wishlist", method: "POST", body: ["title": "Oat milk"], key: "idem-123")
        XCTAssertEqual(sawKey, "idem-123")
    }
}
