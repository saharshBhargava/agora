import Foundation
import Darwin

/// Chat Completions adapter for an explicitly selected local or self-hosted server.
@MainActor
final class OpenAICompatibleClient: ModelClient {
    let identity: ModelIdentity
    let capabilities: ModelCapabilities
    private let endpoint: String
    private let key: String?
    private let http: CaptionHTTPClient
    private static let maximumResponseBytes = 2_000_000
    private static let maximumTextBytes = 128_000
    private static let maximumCalls = 8

    init(identity: ModelIdentity, capabilities: ModelCapabilities, endpoint: String, key: String?, http: CaptionHTTPClient? = nil) {
        self.identity = identity; self.capabilities = capabilities; self.endpoint = endpoint
        self.key = key; self.http = http ?? URLSessionCaptionHTTPClient()
    }

    /// HTTP is allowed only when every destination address is private/loopback. HTTPS supports hosted servers.
    ///
    /// Literal private IPs and `localhost` / `*.localhost` (RFC 6761 loopback names) are accepted without DNS.
    /// Other hostnames are resolved; every result must be private. Link-local (`169.254/16`, `fe80::/10`) is rejected.
    /// Pass `addressesForHost` in tests to inject DNS results.
    static func validateEndpoint(_ endpoint: String, addressesForHost: ((String) throws -> [String])? = nil) throws -> URL {
        guard endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
              endpoint.utf8.count <= 2048, !endpoint.contains("\\"),
              let components = URLComponents(string: endpoint),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              var host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else {
            throw failure("endpoint", "Enter an HTTPS server URL or an HTTP address on your local network.")
        }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if scheme == "http" {
            try assertPrivateHTTPHost(host, addressesForHost: addressesForHost)
        }
        var base = url
        if base.path.isEmpty || base.path == "/" { base.appendPathComponent("v1") }
        return base
    }

    private static func assertPrivateHTTPHost(_ host: String, addressesForHost: ((String) throws -> [String])?) throws {
        if isIPLiteral(host) {
            guard isAllowedPrivateAddress(host) else {
                throw failure("endpoint", "Use HTTPS for servers outside your local network.")
            }
            return
        }
        // Noncanonical IPv4 spellings must not fall through to DNS: Darwin's resolver accepts
        // leading zeros, abbreviated addresses and integer/hex forms that parseIPv4 rejects.
        var legacyAddress = in_addr()
        guard !host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              host.withCString({ inet_aton($0, &legacyAddress) }) == 0 else {
            throw failure("endpoint", "Enter a standard dotted IPv4 address or a local server hostname.")
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return }
        let resolve = addressesForHost ?? { try lookupAddresses(host: $0) }
        let addresses: [String]
        do { addresses = try resolve(host) }
        catch let error as CaptionFailure { throw error }
        catch {
            throw failure("endpoint", "Could not resolve that local server address. Use a private IP (for example 192.168.x.x) or HTTPS.")
        }
        guard !addresses.isEmpty, addresses.allSatisfy(isAllowedPrivateAddress) else {
            throw failure("endpoint", "Use HTTPS for servers outside your local network.")
        }
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        parseIPv4(host) != nil || parseIPv6(host) != nil
    }

    /// Loopback and RFC 1918 / unique-local only. No link-local (`169.254`, `fe80`).
    static func isAllowedPrivateAddress(_ host: String) -> Bool {
        if let octets = parseIPv4(host) {
            return octets[0] == 127
                || octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
        }
        guard let bytes = parseIPv6(host) else { return false }
        // IPv4-mapped ::ffff:a.b.c.d → apply the IPv4 private check.
        if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isAllowedPrivateAddress("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
        }
        // ::1
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }
        // fc00::/7 unique local
        return (bytes[0] & 0xfe) == 0xfc
    }

    private static func parseIPv4(_ host: String) -> [Int]? {
        let segments = host.split(separator: ".", omittingEmptySubsequences: false)
        let octets = segments.compactMap { Int($0) }
        guard segments.count == 4, octets.count == 4,
              segments.allSatisfy({ !$0.isEmpty && ($0 == "0" || !$0.hasPrefix("0")) && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func lookupAddresses(host: String) throws -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        let code = host.withCString { getaddrinfo($0, nil, &hints, &info) }
        guard code == 0, let first = info else {
            throw failure("endpoint", "Could not resolve that local server address. Use a private IP (for example 192.168.x.x) or HTTPS.")
        }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let node = cursor {
            defer { cursor = node.pointee.ai_next }
            guard let addr = node.pointee.ai_addr else { continue }
            var numeric = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                addr,
                socklen_t(node.pointee.ai_addrlen),
                &numeric,
                socklen_t(numeric.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { continue }
            var value = String(cString: numeric).lowercased()
            if let zone = value.firstIndex(of: "%") { value = String(value[..<zone]) }
            if !value.isEmpty { addresses.append(value) }
        }
        guard !addresses.isEmpty else {
            throw failure("endpoint", "Could not resolve that local server address. Use a private IP (for example 192.168.x.x) or HTTPS.")
        }
        return addresses
    }

    static func availableModels(endpoint: String, key: String?, http: CaptionHTTPClient? = nil) async throws -> [String] {
        do {
            let base = try validateEndpoint(endpoint)
            let request = try networkRequest(url: base.appendingPathComponent("models"), key: key)
            let (data, response) = try await (http ?? URLSessionCaptionHTTPClient()).data(request)
            try checkedStatus(response.statusCode)
            let root = try object(data)
            guard root["error"] == nil, let entries = root["data"] as? [[String: Any]], entries.count <= 1000 else { throw invalid() }
            var models: [String] = []
            for entry in entries {
                guard let id = entry["id"] as? String, validName(id, limit: 256) else { throw invalid() }
                if !models.contains(id) { models.append(id) }
            }
            return models.sorted()
        } catch { throw normalized(error) }
    }

    func generate(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        do {
            onEvent(.progress(.preparing))
            let wire = try await networkRequest(request, stream: false)
            try Task.checkCancellation()
            onEvent(.progress(.generating))
            let (data, response) = try await http.data(wire)
            try Task.checkCancellation()
            try Self.checkedStatus(response.statusCode)
            return try parse(Self.object(data), request: request)
        } catch { throw Self.normalized(error) }
    }

    func stream(_ request: ModelRequest, onEvent: @escaping @MainActor (ModelEvent) -> Void) async throws -> ModelResponse {
        guard capabilities.streaming else {
            let response = try await generate(request, onEvent: onEvent)
            onEvent(.text(response.text))
            return response
        }
        do {
            onEvent(.progress(.preparing))
            let wire = try await networkRequest(request, stream: true)
            onEvent(.progress(.generating))
            var text = ""
            var calls: [Int: [String: Any]] = [:]
            var finish: String?
            var bytes = 0
            try await http.stream(wire) { data in
                try Task.checkCancellation()
                bytes += data.count
                guard bytes <= Self.maximumResponseBytes else { throw Self.invalid() }
                let root = try Self.object(data)
                guard root["error"] == nil, let choices = root["choices"] as? [[String: Any]], choices.count <= 1 else { throw Self.invalid() }
                guard let choice = choices.first else { return } // Optional usage-only chunk.
                guard (choice["index"] as? Int ?? 0) == 0, finish == nil,
                      let delta = choice["delta"] as? [String: Any] else { throw Self.invalid() }
                if let role = delta["role"] as? String, role != "assistant" { throw Self.invalid() }
                if let refusal = delta["refusal"], !(refusal is NSNull) { throw Self.failure("blocked", "The model declined this request.") }
                if let value = delta["content"], !(value is NSNull) {
                    guard let fragment = value as? String else { throw Self.invalid() }
                    text += fragment
                    guard text.utf8.count <= Self.maximumTextBytes else { throw Self.invalid() }
                    onEvent(.text(text))
                }
                if let raw = delta["tool_calls"] {
                    guard self.capabilities.tools, let fragments = raw as? [[String: Any]], fragments.count <= Self.maximumCalls else { throw Self.invalid() }
                    for fragment in fragments {
                        guard let index = fragment["index"] as? Int, (0..<Self.maximumCalls).contains(index) else { throw Self.invalid() }
                        var call = calls[index] ?? ["id": "", "type": "function", "function": ["name": "", "arguments": ""]]
                        if let type = fragment["type"] as? String, type != "function" { throw Self.invalid() }
                        if let id = fragment["id"] {
                            guard let value = id as? String else { throw Self.invalid() }
                            call["id"] = (call["id"] as? String ?? "") + value
                        }
                        if let rawFunction = fragment["function"] {
                            guard let function = rawFunction as? [String: Any] else { throw Self.invalid() }
                            var accumulated = call["function"] as! [String: Any]
                            for field in ["name", "arguments"] where function[field] != nil {
                                guard let value = function[field] as? String else { throw Self.invalid() }
                                accumulated[field] = (accumulated[field] as? String ?? "") + value
                            }
                            call["function"] = accumulated
                        }
                        calls[index] = call
                    }
                }
                if let reason = choice["finish_reason"], !(reason is NSNull) {
                    guard let value = reason as? String else { throw Self.invalid() }
                    finish = value
                }
            }
            try Task.checkCancellation()
            guard let finish else { throw Self.failure("incomplete", "The model response was interrupted. Please retry.") }
            guard calls.keys.sorted() == Array(0..<calls.count) else { throw Self.invalid() }
            let message: [String: Any] = ["role": "assistant", "content": text, "tool_calls": calls.keys.sorted().compactMap { calls[$0] }]
            return try parse(["choices": [["index": 0, "finish_reason": finish, "message": message]]], request: request)
        } catch { throw Self.normalized(error) }
    }

    private func networkRequest(_ request: ModelRequest, stream: Bool) async throws -> URLRequest {
        guard identity.provider == .openAICompatible, Self.validName(identity.model, limit: 256),
              !request.messages.isEmpty, request.messages.count <= 100,
              (1...32768).contains(request.maxOutputTokens) else { throw Self.failure("request", "The model request is invalid or too large.") }
        let base = try Self.validateEndpoint(endpoint)
        let definitions = request.tools.map(\.name)
        guard definitions.count <= 64, Set(definitions).count == definitions.count,
              definitions.allSatisfy({ Self.validToolName($0) }), request.tools.allSatisfy({ $0.parameters.object != nil }) else { throw Self.invalid() }
        if !request.tools.isEmpty && !capabilities.tools { throw Self.failure("capability", "Enable tool support for this model profile to use chat actions.") }
        if request.outputSchema != nil && !capabilities.structuredOutput { throw Self.failure("capability", "This model profile does not support structured output.") }
        var messages: [[String: Any]] = []
        if !request.instructions.isEmpty { messages.append(["role": "system", "content": request.instructions]) }
        var pending: [String: String] = [:]
        var seenIDs = Set<String>()
        var images = 0
        for message in request.messages {
            try Task.checkCancellation()
            if let continuation = message.continuation, continuation.provider != .openAICompatible { throw Self.invalid() }
            var parts: [[String: Any]] = []
            for content in message.content {
                switch content {
                case .text(let text): parts.append(["type": "text", "text": text])
                case .image(let data, let mimeType):
                    guard capabilities.images, mimeType.hasPrefix("image/") else { throw Self.failure("capability", "Enable image support for this model profile to use photos or video frames.") }
                    images += 1
                    guard images <= 16 else { throw Self.invalid() }
                    parts.append(LocalModelMedia.imagePart(try LocalModelMedia.image(data)))
                case .media(let url, let kind):
                    guard capabilities.images else { throw Self.failure("capability", "Enable image support for this model profile to use photos or video frames.") }
                    let media = try await LocalModelMedia.parts(url: url, kind: kind)
                    images += media.filter { $0["type"] as? String == "image_url" }.count
                    guard images <= 16 else { throw Self.invalid() }
                    parts += media
                }
            }
            // Chat Completions requires every pending tool result before a new user screenshot/text turn.
            guard message.toolCalls.isEmpty || message.toolResults.isEmpty else { throw Self.invalid() }
            for result in message.toolResults {
                guard capabilities.tools, pending[result.id] == result.name else { throw Self.invalid() }
                pending.removeValue(forKey: result.id)
                messages.append(["role": "tool", "tool_call_id": result.id, "content": try Self.jsonString(result.value)])
            }
            if !message.toolCalls.isEmpty {
                guard capabilities.tools, message.role == .assistant, pending.isEmpty, message.toolCalls.count <= Self.maximumCalls else { throw Self.invalid() }
            }
            var wire: [String: Any] = ["role": message.role == .user ? "user" : "assistant"]
            if parts.allSatisfy({ $0["type"] as? String == "text" }) {
                wire["content"] = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            } else {
                guard message.role == .user else { throw Self.invalid() }
                wire["content"] = parts
            }
            if !message.toolCalls.isEmpty {
                wire["tool_calls"] = try message.toolCalls.map { call -> [String: Any] in
                    guard Self.validName(call.id, limit: 128), definitions.contains(call.name), !seenIDs.contains(call.id) else { throw Self.invalid() }
                    seenIDs.insert(call.id); pending[call.id] = call.name
                    return ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": try Self.jsonString(.object(call.arguments))]]
                }
            }
            if !parts.isEmpty || !message.toolCalls.isEmpty {
                guard pending.isEmpty || !message.toolCalls.isEmpty else { throw Self.invalid() }
                messages.append(wire)
            }
        }
        guard pending.isEmpty, !messages.isEmpty else { throw Self.invalid() }
        var body: [String: Any] = ["model": identity.model, "messages": messages, "max_tokens": request.maxOutputTokens, "stream": stream]
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": ModelJSON.standardSchema($0.parameters).foundation]] }
        }
        if let schema = request.outputSchema {
            guard schema.object != nil else { throw Self.invalid() }
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": "response", "strict": true, "schema": ModelJSON.standardSchema(schema).foundation]]
        }
        var wire = try Self.networkRequest(url: base.appendingPathComponent("chat/completions"), key: key)
        wire.httpMethod = "POST"
        wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        wire.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        wire.httpBody = try JSONSerialization.data(withJSONObject: body)
        guard wire.httpBody!.count <= 25_000_000 else { throw Self.failure("request", "The model request is too large. Use fewer images or a shorter conversation.") }
        return wire
    }

    private func parse(_ root: [String: Any], request: ModelRequest) throws -> ModelResponse {
        guard root["error"] == nil, let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, (choice["index"] as? Int ?? 0) == 0,
              let reason = choice["finish_reason"] as? String else { throw Self.invalid() }
        guard ["stop", "tool_calls"].contains(reason) else {
            throw Self.failure(reason == "content_filter" ? "blocked" : "incomplete", reason == "content_filter" ? "The model declined this request." : "The model stopped before completing its response. Try a shorter request or increase the output limit.")
        }
        guard let message = choice["message"] as? [String: Any], message["role"] as? String == "assistant" else { throw Self.invalid() }
        if let refusal = message["refusal"], !(refusal is NSNull) { throw Self.failure("blocked", "The model declined this request.") }
        let text: String
        if let value = message["content"], !(value is NSNull) {
            guard let value = value as? String, value.utf8.count <= Self.maximumTextBytes else { throw Self.invalid() }
            text = value
        } else { text = "" }
        var calls: [ModelToolCall] = []
        var ids = Set<String>()
        if let raw = message["tool_calls"], !(raw is NSNull) {
            guard let values = raw as? [[String: Any]], values.count <= Self.maximumCalls else { throw Self.invalid() }
            for value in values {
                guard capabilities.tools, reason == "tool_calls", value["type"] as? String == "function",
                      let id = value["id"] as? String, Self.validName(id, limit: 128), ids.insert(id).inserted,
                      let function = value["function"] as? [String: Any], let name = function["name"] as? String,
                      request.tools.contains(where: { $0.name == name }),
                      let arguments = function["arguments"] as? String, arguments.utf8.count <= 64_000,
                      let object = try ModelJSON.from(JSONSerialization.jsonObject(with: Data(arguments.utf8))).object else { throw Self.invalid() }
                calls.append(ModelToolCall(id: id, name: name, arguments: object))
            }
        }
        guard reason != "tool_calls" || !calls.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !calls.isEmpty else { throw Self.invalid() }
        // No tool call can leave this method until every call and the completion reason are validated.
        return ModelResponse(message: ModelMessage(role: .assistant, content: text.isEmpty ? [] : [.text(text)], toolCalls: calls))
    }

    private static func networkRequest(url: URL, key: String?) throws -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        if let key, !key.isEmpty {
            guard key.utf8.count <= 4096, !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw failure("credential", "The server credential is invalid.") }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumResponseBytes, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw invalid() }
        return value
    }
    private static func jsonString(_ value: ModelJSON) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
    private static func validName(_ value: String, limit: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= limit && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func validToolName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
    private static func checkedStatus(_ status: Int) throws {
        guard (200..<300).contains(status) else { throw CaptionHTTPFailure(status: status) }
    }
    private static func invalid() -> CaptionFailure { failure("invalid_response", "The server returned an invalid or incomplete model response.") }
    private static func failure(_ code: String, _ message: String) -> CaptionFailure { CaptionFailure(code: "local_\(code)", message: message) }
    private static func normalized(_ error: Error) -> Error {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return CancellationError() }
        if let failure = error as? CaptionFailure, failure.code.hasPrefix("local_") { return failure }
        if let http = error as? CaptionHTTPFailure {
            switch http.status {
            case 401, 403: return failure("authentication", "The server rejected this credential. Check the connection settings.")
            case 404: return failure("not_found", "The server endpoint or model was not found. Check the base URL and model name.")
            case 429: return failure("rate_limit", "The model server is busy. Try again shortly.")
            default: return failure("http", "The model server could not complete the request (HTTP \(http.status)).")
            }
        }
        if let url = error as? URLError {
            return failure(url.code == .timedOut ? "timeout" : "network", url.code == .timedOut ? "The model server timed out. Try again or choose a faster model." : "Could not connect to the model server. Check that it is running and reachable.")
        }
        return invalid()
    }
}
