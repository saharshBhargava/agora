import Foundation

public enum DibsError: Error, Equatable, Sendable, LocalizedError {
    /// The server answered with an error status. `message` is the body's `error` field.
    case server(message: String, status: Int)
    case offline
    case timeout

    public var errorDescription: String? {
        switch self {
        case .server(let message, _): return message
        case .offline: return "Can't reach the server. Check your connection and try again."
        case .timeout: return "The server is taking too long. Try again."
        }
    }
}

/// The Visa sandbox test card every join uses, and its declined twin (expired).
public enum TestCard {
    public struct Card: Encodable, Sendable, Equatable {
        public let number: String
        public let expMonth: Int
        public let expYear: Int
    }

    public static let approved = Card(number: "4111111111111111", expMonth: 12, expYear: 2031)
    public static let declined = Card(number: "4111111111111111", expMonth: 12, expYear: 1998)
}

public struct JoinResult: Decodable, Sendable, Equatable {
    public struct Auth: Decodable, Sendable, Equatable {
        public let status: String
        public let authId: String?
        public let approvalCode: String
        public let authorizedCents: Int
    }

    public let personId: String
    /// This person's secret for the run. `DibsAPI.join` keeps it in `keys`.
    public let key: String
    public let auth: Auth
}

/// Who a receipt line belongs to: a chip, or the shopper ("mine").
public enum ReceiptTarget: Encodable, Sendable, Equatable {
    case chip(String)
    case mine

    private enum Keys: String, CodingKey { case chipId }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .chip(let id):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .chipId)
        case .mine:
            var c = encoder.singleValueContainer()
            try c.encode("mine")
        }
    }
}

/// REST client for the Dibs server, one method per call in web/lib/api.ts.
///
/// Every request under `/api/runs/<id>` carries this phone's key for that run (`x-dibs-key`, from
/// `keys`); `createRun` and `join` save the key the server hands out.
public struct DibsAPI: Sendable {
    public let base: URL
    public let session: URLSession
    public let timeout: TimeInterval
    /// For addChip and receipt, which wait on Gemini on the server.
    public let slowTimeout: TimeInterval
    /// This phone's key for each run it is in.
    public let keys: RunKeys

    public init(base: URL, session: URLSession = .shared, timeout: TimeInterval = 10, slowTimeout: TimeInterval = 45,
                keys: RunKeys = RunKeys()) {
        self.base = base
        self.session = session
        self.timeout = timeout
        self.slowTimeout = slowTimeout
        self.keys = keys
    }

    // MARK: URLs

    /// `<base>/<path>`, where `path` starts with "/".
    public func url(_ path: String) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + path)!
    }

    /// The QR code PNG the server renders for the join link.
    public func qrURL(runId: String) -> URL { url("\(Self.runPath(runId))/qr") }

    /// `<base>/join?run=<id>`: the link housemates open (web app or this app).
    public func joinLink(runId: String) -> URL {
        var comps = URLComponents(url: url("/join"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "run", value: runId)]
        return comps.url!
    }

    static func encode(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    static func runPath(_ runId: String) -> String { "/api/runs/\(encode(runId))" }

    /// The run a request path acts on: `/api/runs/<id>[/...][?...]`, decoded; nil for anything else.
    static func runId(inPath path: String) -> String? {
        let prefix = "/api/runs/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = path.dropFirst(prefix.count)
        let id = rest.prefix { $0 != "/" && $0 != "?" }
        guard !id.isEmpty else { return nil }
        return String(id).removingPercentEncoding
    }

    // MARK: calls

    private struct Created: Decodable { let runId: String; let shopperId: String; let key: String }
    private struct Empty: Encodable {}
    private struct PersonBody: Encodable { let personId: String }

    public func createRun() async throws -> (runId: String, shopperId: String) {
        // Fastify rejects a JSON content-type with an empty body, so send an empty object.
        let r: Created = try await call("POST", "/api/runs", body: Empty())
        keys.save(r.key, runId: r.runId)
        return (r.runId, r.shopperId)
    }

    public func getRun(_ runId: String) async throws -> Run {
        try await call("GET", Self.runPath(runId))
    }

    public func join(runId: String, name: String, capCents: Int, decline: Bool = false) async throws -> JoinResult {
        struct Body: Encodable { let name: String; let card: TestCard.Card; let capCents: Int }
        let result: JoinResult = try await call("POST", "\(Self.runPath(runId))/join",
                                                body: Body(name: name, card: decline ? TestCard.declined : TestCard.approved, capCents: capCents))
        keys.save(result.key, runId: runId)
        return result
    }

    public func addChip(runId: String, imageBase64: String, hint: String? = nil) async throws -> Chip {
        struct Body: Encodable { let imageBase64: String; let hint: String? }
        return try await call("POST", "\(Self.runPath(runId))/chips", body: Body(imageBase64: imageBase64, hint: hint), timeout: slowTimeout)
    }

    public func fixChip(runId: String, chipId: String, personId: String, name: String? = nil, priceCents: Int? = nil) async throws -> Run {
        struct Body: Encodable { let personId: String; let name: String?; let priceCents: Int? }
        return try await call("POST", "\(Self.runPath(runId))/chips/\(Self.encode(chipId))/fix",
                              body: Body(personId: personId, name: name, priceCents: priceCents))
    }

    /// How many of the item are in the cart (shopper only, 1 to 20, open or last call). Claimers' caps are
    /// re-checked by the server like a price fix.
    public func setQuantity(runId: String, chipId: String, personId: String, quantity: Int) async throws -> Run {
        struct Body: Encodable { let personId: String; let quantity: Int }
        return try await call("POST", "\(Self.runPath(runId))/chips/\(Self.encode(chipId))/quantity",
                              body: Body(personId: personId, quantity: quantity))
    }

    public func putBack(runId: String, chipId: String, personId: String) async throws -> Run {
        try await call("POST", "\(Self.runPath(runId))/chips/\(Self.encode(chipId))/putback", body: PersonBody(personId: personId))
    }

    public func checkout(runId: String, personId: String) async throws -> Run {
        try await call("POST", "\(Self.runPath(runId))/checkout", body: PersonBody(personId: personId))
    }

    public func back(runId: String, personId: String) async throws -> Run {
        try await call("POST", "\(Self.runPath(runId))/back", body: PersonBody(personId: personId))
    }

    /// Raises this person's hold. Returns the new authorized amount in cents.
    public func raise(runId: String, personId: String, capCents: Int) async throws -> Int {
        struct Body: Encodable { let personId: String; let capCents: Int }
        struct Result: Decodable { let authorizedCents: Int }
        let r: Result = try await call("POST", "\(Self.runPath(runId))/raise", body: Body(personId: personId, capCents: capCents))
        return r.authorizedCents
    }

    public func wish(runId: String, name: String, byPersonId: String) async throws -> Run {
        struct Body: Encodable { let name: String; let byPersonId: String }
        return try await call("POST", "\(Self.runPath(runId))/chips/text", body: Body(name: name, byPersonId: byPersonId))
    }

    public func receipt(runId: String, imageBase64: String) async throws -> ReceiptState {
        struct Body: Encodable { let imageBase64: String }
        return try await call("POST", "\(Self.runPath(runId))/receipt", body: Body(imageBase64: imageBase64), timeout: slowTimeout)
    }

    public func fixReceiptLine(runId: String, lineIndex: Int, target: ReceiptTarget) async throws -> ReceiptState {
        struct Body: Encodable { let lineIndex: Int; let target: ReceiptTarget }
        return try await call("POST", "\(Self.runPath(runId))/receipt/fix", body: Body(lineIndex: lineIndex, target: target))
    }

    public func confirm(runId: String, personId: String) async throws -> Run {
        // Settling runs every capture, reversal and the payout before it answers.
        try await call("POST", "\(Self.runPath(runId))/confirm", body: PersonBody(personId: personId), timeout: slowTimeout)
    }

    // MARK: transport

    private struct NoBody: Encodable {}
    private struct ErrorBody: Decodable { let error: String? }

    private func call<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        try await send(request(method, path, body: Optional<NoBody>.none))
    }

    private func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B, timeout: TimeInterval? = nil) async throws -> T {
        try await send(request(method, path, body: body, timeout: timeout))
    }

    func request<B: Encodable>(_ method: String, _ path: String, body: B?, timeout: TimeInterval? = nil) throws -> URLRequest {
        var req = URLRequest(url: url(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout ?? self.timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let runId = Self.runId(inPath: path), let key = keys.key(runId: runId) {
            req.setValue(key, forHTTPHeaderField: "x-dibs-key")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw e.code == .timedOut ? DibsError.timeout : DibsError.offline
        } catch {
            throw DibsError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "request failed (\(status))"
            throw DibsError.server(message: message, status: status)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DibsError.server(message: "Unexpected reply from the server.", status: status)
        }
    }
}
