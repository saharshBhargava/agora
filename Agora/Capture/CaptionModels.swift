import Foundation

// Optional metadata keeps libraries created before captioning backward compatible.
struct SavedCaption: Codable, Equatable {
    var text: String
    let style: CaptionStyle
    let model: String
    let generatedAt: Date
    var editedAt: Date?
    var provider: ModelProviderKind? = nil // Older saved captions used Gemini.
    var effectiveProvider: ModelProviderKind { provider ?? .gemini }
}

enum CaptionStyle: String, Codable, CaseIterable, Identifiable {
    case short, detailed, social
    var id: String { rawValue }
    var title: String {
        switch self { case .short: return "Short description"; case .detailed: return "Detailed description"; case .social: return "Social caption" }
    }
    var instruction: String {
        switch self {
        case .short: return "Write a clear, factual caption in one or two sentences."
        case .detailed: return "Write a detailed description of the visible subjects, setting, and actions. For video, describe the main sequence of events."
        case .social: return "Write a concise, engaging social-media caption grounded in what the media actually shows. Do not add hashtags unless requested."
        }
    }
}

enum CaptionProgress: Equatable {
    case preparing, uploading(Double), processing, generating, retrying, saving, cleaningUp
    var title: String {
        switch self {
        case .preparing: return "Preparing media…"
        case .uploading: return "Uploading media…"
        case .processing: return "Processing the video…"
        case .generating: return "Writing caption…"
        case .retrying: return "Temporary connection issue. Retrying…"
        case .saving: return "Saving caption…"
        case .cleaningUp: return "Removing uploaded file…"
        }
    }
}

struct CaptionFailure: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

struct CaptionHTTPFailure: Error {
    let status: Int
}

struct GeminiUploadedFile: Decodable {
    let name: String
    let uri: String
    let mimeType: String?
    let state: String?
}

/// SSE events may span several data lines; comments and keep-alives are ignored.
struct CaptionSSEDecoder {
    private var lines: [String] = []
    private var bytes = 0
    mutating func consume(_ line: String) throws -> Data? {
        if line.isEmpty { return finish() }
        guard line.hasPrefix("data:") else { return nil }
        var value = String(line.dropFirst(5))
        if value.hasPrefix(" ") { value.removeFirst() }
        bytes += value.utf8.count
        guard bytes < 1_000_000 else { throw CaptionFailure(code: "stream_limit", message: "Gemini returned an oversized response.") }
        lines.append(value)
        return nil
    }
    mutating func finish() -> Data? {
        defer { lines = []; bytes = 0 }
        guard !lines.isEmpty else { return nil }
        let text = lines.joined(separator: "\n")
        return text == "[DONE]" ? nil : Data(text.utf8)
    }
}

/// Preserve blank lines: AsyncBytes.lines drops the separators SSE needs.
struct CaptionSSEByteDecoder {
    private var line = Data()
    private var afterCR = false
    private var events = CaptionSSEDecoder()

    mutating func consume(_ byte: UInt8) throws -> Data? {
        if byte == 10 && afterCR { afterCR = false; return nil }
        afterCR = byte == 13
        if byte == 10 || byte == 13 {
            let value = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            return try events.consume(value)
        }
        line.append(byte)
        guard line.count < 1_000_000 else {
            throw CaptionFailure(code: "stream_limit", message: "Gemini returned an oversized response.")
        }
        return nil
    }
    mutating func finish() throws -> Data? {
        if !line.isEmpty {
            _ = try events.consume(String(decoding: line, as: UTF8.self))
            line.removeAll()
        }
        return events.finish()
    }
}

/// Only visible text is returned. Partial, blocked or truncated output is not saved.
struct CaptionResponseAccumulator {
    private(set) var text = ""
    private(set) var finished = false
    mutating func consume(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CaptionFailure(code: "invalid_response", message: "Gemini returned an unreadable response.")
        }
        if let error = root["error"] as? [String: Any] {
            throw CaptionHTTPFailure(status: error["code"] as? Int ?? 500)
        }
        if let feedback = root["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw CaptionFailure(code: "blocked", message: "Gemini could not caption this media. Try a different image, clip, or instruction.")
        }
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { return }
        if let reason = candidate["finishReason"] as? String {
            guard reason == "STOP" else {
                throw CaptionFailure(code: "incomplete_response", message: "Gemini stopped before completing the caption. Try a shorter instruction or another model.")
            }
            finished = true
        }
        let content = candidate["content"] as? [String: Any]
        for part in content?["parts"] as? [[String: Any]] ?? [] where part["thought"] as? Bool != true {
            text += part["text"] as? String ?? ""
        }
        guard text.utf8.count <= 32_000 else { throw CaptionFailure(code: "stream_limit", message: "The generated caption is too long.") }
    }
    func result() throws -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard finished, !value.isEmpty else { throw CaptionFailure(code: "incomplete_response", message: "The caption response was interrupted or empty. Please retry.") }
        return value
    }
}
