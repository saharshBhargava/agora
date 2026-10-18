import SwiftUI
import Security
import CryptoKit

@MainActor
final class SettingsStore: ObservableObject {
    weak var demoCalendar: CalendarConnection?
    @Published var model: String { didSet {
        defaults.set(model, forKey: "gemini.model")
        if let index = modelConfiguration.profiles.firstIndex(where: { $0.id == ModelConfiguration.geminiProfileID }),
           modelConfiguration.profiles[index].model != model { modelConfiguration.profiles[index].model = model }
    } }
    @Published private(set) var modelConfigurationIssue: String?
    @Published var modelConfiguration: ModelConfiguration { didSet {
        modelConfigurationIssue = nil
        if let data = try? JSONEncoder().encode(modelConfiguration) { defaults.set(data, forKey: "models.configuration.v1") }
        if oldValue.chatSignature != modelConfiguration.chatSignature { chatRevision += 1 }
    } }
    @Published private(set) var chatRevision = 0
    private let defaults: UserDefaults
    @Published var hasKey = false
    private let keychainService: String
    /// A Gemini key built into this build (DIBS_DEFAULT_GEMINI_KEY in the gitignored Config/Local.xcconfig or on the
    /// build command line), used when none is saved on the device. Empty in the shared project.
    let bundledKey: String?
    nonisolated static func infoPlistGeminiKey(_ bundle: Bundle = .main) -> String? {
        let value = (bundle.object(forInfoDictionaryKey: "DibsDefaultGeminiKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false && value?.hasPrefix("$(") == false ? value : nil
    }
    init(keychainService: String = "app.agora.gemini", defaults: UserDefaults = .standard, bundledKey: String? = SettingsStore.infoPlistGeminiKey()) {
        self.bundledKey = bundledKey
        self.defaults = defaults
        self.keychainService = keychainService
        let savedModel = defaults.string(forKey: "gemini.model")
        // Migrate the original default, which Google now restricts for new projects.
        let migrateLegacyDefault = !defaults.bool(forKey: "gemini.defaultMigration.v2") && savedModel == "gemini-2.5-flash"
        let initialModel = savedModel == nil || migrateLegacyDefault ? "gemini-flash-latest" : savedModel!
        model = initialModel
        defaults.set(true, forKey: "gemini.defaultMigration.v2")
        defaults.set(initialModel, forKey: "gemini.model")
        if let data = defaults.data(forKey: "models.configuration.v1") {
            if let saved = try? JSONDecoder().decode(ModelConfiguration.self, from: data) { modelConfiguration = saved }
            else {
                // Never turn a damaged local configuration into an implicit cloud selection.
                modelConfiguration = .init(connections: [], profiles: [], defaultProfileID: UUID())
                modelConfigurationIssue = "Saved model settings could not be read. Add a connection and model profile, then choose a default."
            }
        } else { modelConfiguration = .initial(geminiModel: initialModel) }
        hasKey = (try? apiKey()) != nil
    }
    var policy: BrowserPolicy {
        BrowserPolicy()
    }
    private var query: [String: Any] { keyQuery(account: "personal-api-key") }
    private func keyQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
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
            // Nothing saved on this device: a personal build may carry its owner's key (DIBS_DEFAULT_GEMINI_KEY).
            if let bundledKey { return bundledKey }
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
        if (try? modelConfiguration.profile(for: .chat).connectionID) == ModelConfiguration.geminiConnectionID { chatRevision += 1 }
        AppLog.event(.keychain, "save.verified")
    }
    func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        AppLog.keychain("delete", status: status)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status, operation: "remove") }
        hasKey = bundledKey != nil
        if (try? modelConfiguration.profile(for: .chat).connectionID) == ModelConfiguration.geminiConnectionID { chatRevision += 1 }
    }

    private func connectionAccount(_ connection: ModelConnection) -> String {
        // Bind credentials to both connection identity and destination. Editing an endpoint never sends its old key elsewhere.
        let destination = "\(connection.provider.rawValue)|\(connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines))"
        let hash = SHA256.hash(data: Data(destination.utf8)).map { String(format: "%02x", $0) }.joined()
        return "connection-\(connection.id)-\(hash)"
    }
    func connectionKey(_ connection: ModelConnection) throws -> String? {
        if connection.id == ModelConfiguration.geminiConnectionID && connection.provider == .gemini {
            do { return try apiKey() }
            catch let error as BrowserError where error.code == "missing_api_key" { return nil }
        }
        var q = keyQuery(account: connectionAccount(connection)); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status, operation: "read") }
        guard let data = value as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { throw BrowserError("invalid_stored_key") }
        return key
    }
    func saveConnectionKey(_ value: String, connection: ModelConnection) throws {
        if connection.id == ModelConfiguration.geminiConnectionID && connection.provider == .gemini { try saveKey(value); return }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw BrowserError("empty_api_key") }
        let q = keyQuery(account: connectionAccount(connection))
        let attrs: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound { status = SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard status == errSecSuccess else { throw keychainError(status, operation: "save") }
        guard try connectionKey(connection) == key else { throw BrowserError("keychain_verification_failed") }
        if (try? modelConfiguration.connection(for: modelConfiguration.profile(for: .chat)).id) == connection.id { chatRevision += 1 }
    }
    func deleteConnectionKey(_ connection: ModelConnection) throws {
        if connection.id == ModelConfiguration.geminiConnectionID && connection.provider == .gemini { try deleteKey(); return }
        let status = SecItemDelete(keyQuery(account: connectionAccount(connection)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status, operation: "remove") }
        if (try? modelConfiguration.connection(for: modelConfiguration.profile(for: .chat)).id) == connection.id { chatRevision += 1 }
    }
}
