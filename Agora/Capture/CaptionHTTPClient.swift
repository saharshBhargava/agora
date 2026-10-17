import Foundation

@MainActor
protocol CaptionHTTPClient {
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func upload(_ request: URLRequest, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (Data, HTTPURLResponse)
    func stream(_ request: URLRequest, event: @escaping @MainActor (Data) throws -> Void) async throws
}

private final class CaptionNetworkDelegate: NSObject, URLSessionTaskDelegate {
    let progress: (@MainActor (Double) -> Void)?
    init(progress: (@MainActor (Double) -> Void)? = nil) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let fraction = min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        Task { @MainActor [progress] in progress?(fraction) }
    }
    // Credentials and upload payloads never follow redirects to another service.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class URLSessionCaptionHTTPClient: CaptionHTTPClient {
    private let configuration: URLSessionConfiguration
    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }
    private func session(delegate: CaptionNetworkDelegate, resourceTimeout: TimeInterval) -> URLSession {
        let config = configuration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    private func checked(_ response: URLResponse, count: Int = 0) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw CaptionFailure(code: "network_response", message: "No response from Gemini.") }
        AppLog.event(.caption, "http.response", status: http.statusCode, count: count)
        guard (200..<300).contains(http.statusCode) else { throw CaptionHTTPFailure(status: http.statusCode) }
        return http
    }
    func data(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = session(delegate: CaptionNetworkDelegate(), resourceTimeout: 40)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (data, response) = try await session.data(for: request)
            return (data, try checked(response, count: data.count))
        } onCancel: { session.invalidateAndCancel() }
    }
    func upload(_ request: URLRequest, file: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> (Data, HTTPURLResponse) {
        let session = session(delegate: CaptionNetworkDelegate(progress: progress), resourceTimeout: 300)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (data, response) = try await session.upload(for: request, fromFile: file)
            return (data, try checked(response, count: data.count))
        } onCancel: { session.invalidateAndCancel() }
    }
    func stream(_ request: URLRequest, event: @escaping @MainActor (Data) throws -> Void) async throws {
        let session = session(delegate: CaptionNetworkDelegate(), resourceTimeout: 180)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            _ = try checked(response)
            var decoder = CaptionSSEByteDecoder()
            for try await byte in bytes {
                try Task.checkCancellation()
                if let data = try decoder.consume(byte) { try event(data) }
            }
            if let remaining = try decoder.finish() { try event(remaining) }
        } onCancel: { session.invalidateAndCancel() }
    }
}
