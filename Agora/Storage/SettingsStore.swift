import SwiftUI
import Security

@MainActor
final class SettingsStore: ObservableObject {
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: "gemini.model") } }
    @Published var hasKey = false
    private let keychainService: String
    init(keychainService: String = "app.agora.gemini") {
        self.keychainService = keychainService
        let savedModel = UserDefaults.standard.string(forKey: "gemini.model")
        // Migrate the original default, which Google now restricts for new projects.
        let migrateLegacyDefault = !UserDefaults.standard.bool(forKey: "gemini.defaultMigration.v2") && savedModel == "gemini-2.5-flash"
        model = savedModel == nil || migrateLegacyDefault ? "gemini-flash-latest" : savedModel!
        UserDefaults.standard.set(true, forKey: "gemini.defaultMigration.v2")
        UserDefaults.standard.set(model, forKey: "gemini.model")
        hasKey = (try? apiKey()) != nil
    }
    var policy: BrowserPolicy {
        BrowserPolicy()
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "personal-api-key"]
    }
    private func keychainError(_ status: OSStatus, operation: String) -> BrowserError {
        if status == errSecMissingEntitlement {
            return BrowserError("keychain_error", "This build is missing its Keychain entitlement (-34018). Run Agora from Xcode with code signing enabled; unsigned simulator builds cannot save API keys.")
        }
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
        return BrowserError("keychain_error", "Could not \(operation) the API key: \(detail) (\(status)).")
    }
    func apiKey() throws -> String {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        AppLog.keychain("read", status: status)
        if status == errSecItemNotFound {
            throw BrowserError("missing_api_key", "Add your Gemini API key in Settings.")
        }
        guard status == errSecSuccess else { throw keychainError(status, operation: "read") }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw BrowserError("invalid_stored_key", "The saved API key is unreadable. Replace it in Settings.")
        }
        return key
    }
    func saveKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw BrowserError("empty_api_key") }
        let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        AppLog.keychain("update", status: status)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            AppLog.keychain("insert", status: status)
        }
        guard status == errSecSuccess else { throw keychainError(status, operation: "save") }
        // Do not report success until the same read path used by chat returns the saved value.
        guard try apiKey() == key else {
            throw BrowserError("keychain_verification_failed", "The API key could not be read back. Please save it again.")
        }
        hasKey = true
        AppLog.event(.keychain, "save.verified")
    }
    func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        AppLog.keychain("delete", status: status)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status, operation: "remove") }
        hasKey = false
    }
}
