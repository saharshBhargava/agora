import Foundation

/// What the "+ Wish" page offers (server GET /api/runs/:id/wish-picks): the household's shopping list,
/// when the server can reach it, and suggestions. The server leaves out what is already in the cart.
public struct WishPicks: Decodable, Sendable, Equatable {
    public struct Item: Decodable, Sendable, Equatable {
        public let name: String
        /// "2 bottles", "×4", or "".
        public let detail: String

        public init(name: String, detail: String) { self.name = name; self.detail = detail }
    }

    public struct List: Decodable, Sendable, Equatable {
        public let name: String
        public let store: String?
        public let items: [Item]

        public init(name: String, store: String?, items: [Item]) { self.name = name; self.store = store; self.items = items }
    }

    public struct Suggestion: Decodable, Sendable, Equatable {
        public let name: String
        /// "Running low · about 2 days left", "Often in your QFC runs".
        public let reason: String

        public init(name: String, reason: String) { self.name = name; self.reason = reason }
    }

    public let list: List?
    public let suggestions: [Suggestion]

    public init(list: List?, suggestions: [Suggestion]) { self.list = list; self.suggestions = suggestions }
}

extension DibsAPI {
    private struct NoBody: Encodable {}
    private struct ErrorBody: Decodable { let error: String? }

    /// `householdToken` is the signed-in household account's team-API token, so the server reads that household's
    /// lists and suggestions. Callers pass it only for the build's own server (`AppModel.householdTokenForWishPicks`).
    public func wishPicks(runId: String, personId: String, householdToken: String? = nil) async throws -> WishPicks {
        var req = try request("GET", "\(Self.runPath(runId))/wish-picks?personId=\(Self.encode(personId))", body: Optional<NoBody>.none)
        if let householdToken, !householdToken.isEmpty { req.setValue(householdToken, forHTTPHeaderField: "X-Household-Token") }
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
            return try JSONDecoder().decode(WishPicks.self, from: data)
        } catch {
            throw DibsError.server(message: "Unexpected reply from the server.", status: status)
        }
    }
}
