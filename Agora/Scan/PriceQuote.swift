import Foundation

struct IdentifiedItem: Codable, Equatable, Sendable {
    let name: String
    let detail: String
    let searchQuery: String
    let confidence: Double
}

struct PriceQuote: Equatable, Sendable {
    let productName: String
    let priceCents: Int
    let unit: String
    let storeName: String
    let sourceTitle: String?
    let sourceURL: URL?
    let onStoreSite: Bool
    let note: String?
}

struct QuoteError: Error, Equatable, Sendable {
    let code: String
}

enum QuoteParsing {
    private struct Response: Decodable {
        struct Feedback: Decodable { let blockReason: String? }
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String?; let thought: Bool? }
                let parts: [Part]?
            }
            struct Grounding: Decodable {
                struct Chunk: Decodable {
                    struct Web: Decodable { let uri: String?; let title: String? }
                    let web: Web?
                }
                let groundingChunks: [Chunk]?
            }
            let finishReason: String?
            let content: Content?
            let groundingMetadata: Grounding?
        }
        let promptFeedback: Feedback?
        let candidates: [Candidate]?
    }

    private static func extract(_ data: Data) throws -> (text: String, web: Response.Candidate.Grounding.Chunk.Web?) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw QuoteError(code: "invalid") }
        if response.promptFeedback?.blockReason != nil { throw QuoteError(code: "blocked") }
        guard let candidate = response.candidates?.first, candidate.finishReason == "STOP",
              let parts = candidate.content?.parts else { throw QuoteError(code: "incomplete") }
        let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        return (text, candidate.groundingMetadata?.groundingChunks?.compactMap(\.web).first)
    }

    private static func object(in text: String) throws -> Data {
        guard let json = firstJSONObject(in: text) else { throw QuoteError(code: "invalid") }
        return Data(json.utf8)
    }

    static func identification(fromGeminiResponse data: Data) throws -> IdentifiedItem {
        let (text, _) = try extract(data)
        guard let item = try? JSONDecoder().decode(IdentifiedItem.self, from: object(in: text)),
              !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, item.name.count <= 120,
              !item.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.confidence.isFinite, (0...1).contains(item.confidence) else { throw QuoteError(code: "invalid") }
        return item
    }

    static func quote(fromGeminiResponse data: Data, storeName: String) throws -> PriceQuote? {
        struct Payload: Decodable {
            let found: Bool
            let productName: String?
            let priceCents: Int?
            let unit: String?
            let sourceUrl: String?
            let note: String?
        }
        let (text, web) = try extract(data)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: object(in: text)) else { throw QuoteError(code: "invalid") }
        guard payload.found else { return nil }
        guard let name = payload.productName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 160,
              let cents = payload.priceCents, (1...100_000_000).contains(cents),
              let unit = payload.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !unit.isEmpty, unit.count <= 20
        else { throw QuoteError(code: "invalid") }

        func httpsURL(_ string: String?) -> URL? {
            guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
            return url
        }
        func isQFC(host: String?) -> Bool {
            guard let host = host?.lowercased() else { return false }
            return host == "qfc.com" || host.hasSuffix(".qfc.com")
        }
        let jsonURL = httpsURL(payload.sourceUrl)
        let title = web?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let onStore: Bool
        if let jsonURL {
            onStore = isQFC(host: jsonURL.host)
        } else {
            onStore = (title?.lowercased().hasSuffix("qfc.com") ?? false) || isQFC(host: httpsURL(web?.uri)?.host)
        }
        return PriceQuote(productName: name, priceCents: cents, unit: unit, storeName: storeName,
                          sourceTitle: (title?.isEmpty == false) ? title : nil,
                          sourceURL: jsonURL ?? httpsURL(web?.uri),
                          onStoreSite: onStore, note: payload.note)
    }

    /// The first balanced top-level `{...}` object in `text`, ignoring braces inside JSON strings.
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0, inString = false, escaped = false
        var start: String.Index?
        for index in text.indices {
            let ch = text[index]
            if inString {
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false }
                continue
            }
            switch ch {
            case "\"": if depth > 0 { inString = true }
            case "{": if depth == 0 { start = index }; depth += 1
            case "}":
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start { return String(text[start...index]) }
            default: break
            }
        }
        return nil
    }
}
