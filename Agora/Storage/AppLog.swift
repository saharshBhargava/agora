import Foundation
import OSLog

/// Diagnostic metadata only. Never pass prompts, URLs, credentials, arguments,
/// provider response bodies or localized error descriptions to the logger.
enum AppLog {
    static let subsystem = "dev.agora.browserchat"
    enum Category: String, CaseIterable { case app, agent, gemini, browser, keychain, storage }
    @TaskLocal static var taskID = "none"
    @TaskLocal static var operationID = "none"
    private static let loggers = Dictionary(uniqueKeysWithValues: Category.allCases.map {
        ($0, Logger(subsystem: subsystem, category: $0.rawValue))
    })

    static func event(_ category: Category, _ event: String, status: Int = 0, count: Int = 0) {
        loggers[category]!.info("event=\(event, privacy: .public) task=\(taskID, privacy: .public) operation=\(operationID, privacy: .public) status=\(status) count=\(count)")
    }
    static func failure(_ category: Category, _ event: String, error: Error) {
        let code = safeErrorCode(error)
        loggers[category]!.error("event=\(event, privacy: .public) task=\(taskID, privacy: .public) operation=\(operationID, privacy: .public) error=\(code, privacy: .public)")
    }
    static func keychain(_ operation: String, status: Int32) {
        if status == 0 || status == -25300 {
            event(.keychain, operation, status: Int(status))
        } else {
            loggers[.keychain]!.error("event=\(operation, privacy: .public) status=\(status)")
        }
    }
    // Bridge errors may contain website-controlled strings, and NSError.userInfo
    // may contain URLs or request data. Only allow known codes into diagnostics.
    static func safeErrorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? BrowserError {
            let code = String(error.code.split(separator: ":", maxSplits: 1).first ?? "")
            let allowed: Set<String> = ["invalid_model", "provider_error", "model_list_limit", "incomplete_model_response", "missing_api_key", "keychain_error", "empty_api_key", "invalid_stored_key", "keychain_verification_failed", "no_browser", "stale_session", "stale_reference", "unsupported_action", "unsupported_frame", "blocked_destination", "user_action_required", "approval_required", "approval_denied", "cancelled", "timeout", "outcome_unknown", "web_process_terminated", "observation_unavailable", "navigation_failed", "invalid_arguments", "executor_busy", "task_budget_exhausted", "tool_budget_exhausted", "conversation_limit", "repeated_tool_errors"]
            if allowed.contains(code) { return code }
            if code.range(of: #"^gemini_http_[1-5][0-9]{2}$"#, options: .regularExpression) != nil { return code }
            return "browser_error"
        }
        let native = error as NSError
        let domain = [NSURLErrorDomain, NSCocoaErrorDomain, "WKErrorDomain", NSOSStatusErrorDomain].contains(native.domain) ? native.domain : "other"
        return "\(domain):\(native.code)"
    }
    @MainActor
    static func measure<T>(_ category: Category, _ operation: String, body: () async throws -> T) async throws -> T {
        try await $operationID.withValue(UUID().uuidString) {
            let started = ProcessInfo.processInfo.systemUptime
            event(category, "\(operation).started")
            do {
                let result = try await body()
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                loggers[category]!.info("event=\(operation, privacy: .public).completed task=\(taskID, privacy: .public) operation=\(operationID, privacy: .public) duration_ms=\(elapsed)")
                return result
            } catch {
                failure(category, "\(operation).failed", error: error)
                throw error
            }
        }
    }
}
