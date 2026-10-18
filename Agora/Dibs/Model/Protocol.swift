import Foundation

// WebSocket message shapes, mirroring server/src/protocol.ts. Client messages act on one chip;
// server messages carry run state.

public enum ClientMsg: Sendable, Equatable, Encodable {
    case claim(chipId: String)
    case leave(chipId: String)
    case remove(chipId: String)
    case undoRemove(chipId: String)
    /// A shopper camera frame. `detect: false` means the phone already found the item, so the
    /// server only relays the frame and skips its own detector.
    case frame(jpegBase64: String, at: Double, detect: Bool)
    case identifyAt(x: Double, y: Double)

    private enum Keys: String, CodingKey { case t, chipId, jpegBase64, at, detect, x, y }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .claim(let id): try c.encode("claim", forKey: .t); try c.encode(id, forKey: .chipId)
        case .leave(let id): try c.encode("leave", forKey: .t); try c.encode(id, forKey: .chipId)
        case .remove(let id): try c.encode("remove", forKey: .t); try c.encode(id, forKey: .chipId)
        case .undoRemove(let id): try c.encode("undoRemove", forKey: .t); try c.encode(id, forKey: .chipId)
        case .frame(let jpeg, let at, let detect):
            try c.encode("frame", forKey: .t)
            try c.encode(jpeg, forKey: .jpegBase64)
            try c.encode(at, forKey: .at)
            try c.encode(detect, forKey: .detect)
        case .identifyAt(let x, let y):
            try c.encode("identifyAt", forKey: .t)
            try c.encode(x, forKey: .x)
            try c.encode(y, forKey: .y)
        }
    }

    /// The JSON text sent over the socket.
    public func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum ServerMsg: Sendable, Equatable, Decodable {
    case run(Run)
    case error(reason: String)
    case lastCall(endsAt: Double)
    case locked
    case frame(jpegBase64: String, at: Double)
    case identifying(region: Box?)
    /// A message type this app does not know. Ignored.
    case unknown(String)

    private enum Keys: String, CodingKey { case t, run, reason, endsAt, jpegBase64, at, region }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "run": self = .run(try c.decode(Run.self, forKey: .run))
        case "error": self = .error(reason: (try? c.decode(String.self, forKey: .reason)) ?? "error")
        case "lastCall": self = .lastCall(endsAt: try c.decode(Double.self, forKey: .endsAt))
        case "locked": self = .locked
        case "frame":
            self = .frame(jpegBase64: try c.decode(String.self, forKey: .jpegBase64),
                          at: (try? c.decode(Double.self, forKey: .at)) ?? 0)
        case "identifying": self = .identifying(region: try c.decodeIfPresent(Box.self, forKey: .region))
        default: self = .unknown(t)
        }
    }

    /// Parses one socket text frame, or nil when it is not a message.
    public static func parse(_ text: String) -> ServerMsg? {
        try? JSONDecoder().decode(ServerMsg.self, from: Data(text.utf8))
    }
}
