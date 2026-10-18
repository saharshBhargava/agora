import XCTest
import Security
@testable import Agora

private final class AgoraURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (Int, Any))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, json) = Self.handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AgoraClientTests: XCTestCase {
    private var service = ""
    private var http: URLSession!

    override func setUp() async throws {
        service = "test.agora.client.\(UUID().uuidString)"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgoraURLProtocol.self]
        http = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        http.invalidateAndCancel()
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        AgoraURLProtocol.handler = nil
    }

    func testBearerRequestAndSessionClearOnUnauthorized() async throws {
        let account = AgoraClient.Account(token: "ags_test", email: "alice@example.com", userID: UUID().uuidString, expiresAt: "2099-01-01T00:00:00Z")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "session",
            kSecValueData as String: try JSONEncoder().encode(account)
        ]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        var sawAuth: String?
        AgoraURLProtocol.handler = { request in
            sawAuth = request.value(forHTTPHeaderField: "Authorization")
            if request.url!.path == "/v1/me" { return (200, ["email": "alice@example.com"]) }
            return (401, ["title": "session_expired", "detail": "Sign in again."])
        }

        let client = AgoraClient(baseURL: URL(string: "https://api.example.com"), http: http, service: service)
        XCTAssertTrue(client.signedIn)
        let me = try await client.request("v1/me")
        XCTAssertEqual(sawAuth, "Bearer ags_test")
        XCTAssertEqual(me["email"] as? String, "alice@example.com")

        AgoraURLProtocol.handler = { _ in (401, ["title": "session_expired", "detail": "Sign in again."]) }
        do {
            _ = try await client.request("v1/inventory")
            XCTFail("Expected 401")
        } catch let error as BrowserError {
            XCTAssertEqual(error.code, "session_expired")
            XCTAssertEqual(error.status, 401)
            XCTAssertFalse(client.signedIn)
        }
    }

    func testListJSONAndUnavailableBaseURL() async throws {
        AgoraURLProtocol.handler = { _ in (200, [["id": "item-1"], ["id": "item-2"]]) }
        let client = AgoraClient(baseURL: URL(string: "https://api.example.com"), http: http, service: service)
        try client.save(AgoraClient.Account(token: "ags", email: "a@b.c", userID: "u", expiresAt: "2099-01-01T00:00:00Z"))
        let list = try await client.requestJSON("v1/inventory") as? [[String: Any]]
        XCTAssertEqual(list?.count, 2)

        let missing = AgoraClient(baseURL: nil, http: http, service: service + ".empty")
        do {
            _ = try await missing.request("v1/me")
            XCTFail("Expected unavailable")
        } catch let error as BrowserError {
            XCTAssertEqual(error.code, "service_unavailable")
        }
    }
}
