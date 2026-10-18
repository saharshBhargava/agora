import Foundation

struct RecognizedItem: Codable, Equatable {
    let name: String
    let category: String
    let unit: String
    let quantity: Double
    let confidence: Double
}

@MainActor
protocol InventoryRecognizing {
    func recognize(file: URL, kind: CaptureItem.Kind,
                   progress: @escaping @MainActor (CaptionProgress) -> Void,
                   cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> [RecognizedItem]
}

@MainActor
final class GeminiInventoryService: InventoryRecognizing {
    private let key: String
    private let model: String
    private let http: CaptionHTTPClient
    private let media: GeminiCaptionService
    init(key: String, model: String, http: CaptionHTTPClient? = nil) {
        self.key = key; self.model = GeminiProvider.normalizedModel(model)
        let transport = http ?? URLSessionCaptionHTTPClient()
        self.http = transport
        media = GeminiCaptionService(key: key, model: model, http: transport)
    }

    func recognize(file: URL, kind: CaptureItem.Kind,
                   progress: @escaping @MainActor (CaptionProgress) -> Void,
                   cleanupNotice: @escaping @MainActor (String) -> Void) async throws -> [RecognizedItem] {
        try await media.withMedia(file: file, kind: kind, progress: progress, cleanupNotice: cleanupNotice) { part in
            progress(.generating)
            var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(self.model):generateContent")!)
            request.httpMethod = "POST"; request.timeoutInterval = 180
            request.setValue(self.key, forHTTPHeaderField: "x-goog-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "systemInstruction": ["parts": [["text": InventoryRecognitionContract.instructions]]],
                "contents": [["role": "user", "parts": [part, ["text": "Identify the inventory items to review."]]]],
                "generationConfig": ["responseMimeType": "application/json", "responseJsonSchema": Self.schema, "maxOutputTokens": 8192]
            ])
            let (data, _) = try await self.http.data(request)
            try Task.checkCancellation()
            return try Self.decode(data)
        }
    }

    static let schema = InventoryRecognitionContract.schema

    static func decode(_ data: Data) throws -> [RecognizedItem] {
        struct Response: Decodable {
            struct Feedback: Decodable { let blockReason: String? }
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String?; let thought: Bool? }
                    let parts: [Part]
                }
                let finishReason: String?
                let content: Content?
            }
            let promptFeedback: Feedback?
            let candidates: [Candidate]?
        }
        do {
            let response = try JSONDecoder().decode(Response.self, from: data)
            guard response.promptFeedback?.blockReason == nil,
                  let candidate = response.candidates?.first, candidate.finishReason == "STOP",
                  let parts = candidate.content?.parts else { throw BrowserError("incomplete_recognition") }
            let text = parts.filter { $0.thought != true }.compactMap(\.text).joined()
            return try InventoryRecognitionContract.decode(text)
        } catch {
            throw CaptionFailure(code: "invalid_recognition", message: "Gemini did not return a complete item list. Try recognizing again or use a clearer capture.")
        }
    }
}
