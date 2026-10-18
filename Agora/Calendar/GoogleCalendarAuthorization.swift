import GoogleSignIn
import UIKit

struct GoogleCalendarAccount: Equatable {
    let id: String
    let email: String
    let scopes: Set<String>
}

@MainActor
protocol GoogleCalendarAuthorizing {
    var configurationIssue: String? { get }
    func restore() async throws -> GoogleCalendarAccount?
    func connect() async throws -> GoogleCalendarAccount
    func accessToken(for accountID: String) async throws -> String
    func idToken(for accountID: String) async throws -> String
    func signOut()
    func disconnect() async throws
}

@MainActor
final class GoogleCalendarAuthorization: GoogleCalendarAuthorizing {
    static let scopes: Set<String> = [
        "https://www.googleapis.com/auth/calendar.events",
        "https://www.googleapis.com/auth/calendar.freebusy"
    ]
    private let clientID: String
    let configurationIssue: String?

    init(bundle: Bundle = .main) {
        let id = (bundle.object(forInfoDictionaryKey: "GIDClientID") as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        clientID = id
        configurationIssue = Self.configurationIssue(clientID: id, schemes: types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] })
    }
    static func configurationIssue(clientID: String, schemes: [String]) -> String? {
        guard clientID.range(of: #"^[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$"#, options: .regularExpression) != nil else {
            return "Google sign-in hasn’t been set up for this build yet. An iOS Google client ID is required."
        }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        guard schemes.contains(reversed) else {
            return "This build’s Google sign-in callback isn’t configured. Update the Google callback scheme and rebuild."
        }
        return nil
    }
    private func configuredSignIn() throws -> GIDSignIn {
        if let configurationIssue { throw BrowserError("google_not_configured", configurationIssue) }
        let signIn = GIDSignIn.sharedInstance
        signIn.configuration = GIDConfiguration(clientID: clientID)
        return signIn
    }
    private func account(_ user: GIDGoogleUser) throws -> GoogleCalendarAccount {
        guard let id = user.userID, !id.isEmpty, let email = user.profile?.email, !email.isEmpty else {
            throw BrowserError("google_identity_failed", "Could not read your Google account. Please sign in again.")
        }
        return GoogleCalendarAccount(id: id, email: email, scopes: Set(user.grantedScopes ?? []))
    }
    func restore() async throws -> GoogleCalendarAccount? {
        let signIn = try configuredSignIn()
        guard signIn.hasPreviousSignIn() else { return nil }
        do { return try account(await signIn.restorePreviousSignIn()) }
        catch {
            if (error as NSError).domain == kGIDSignInErrorDomain && (error as NSError).code == GIDSignInError.Code.hasNoAuthInKeychain.rawValue { return nil }
            throw Self.safeError(error)
        }
    }
    func connect() async throws -> GoogleCalendarAccount {
        let signIn = try configuredSignIn()
        guard var presenter = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow)?.rootViewController else {
            throw BrowserError("google_sign_in_failed", "Open Agora and try connecting again.")
        }
        while let presented = presenter.presentedViewController { presenter = presented }
        do {
            // A fresh interactive flow also repairs a revoked grant whose cached scopes look complete.
            let result = try await signIn.signIn(withPresenting: presenter, hint: signIn.currentUser?.profile?.email, additionalScopes: Array(Self.scopes).sorted())
            return try account(result.user)
        } catch { throw Self.safeError(error) }
    }
    private func refreshedUser(for accountID: String) async throws -> GIDGoogleUser {
        let signIn = try configuredSignIn()
        guard let user = signIn.currentUser, user.userID == accountID else {
            throw BrowserError("calendar_account_changed", "Your Google account changed. Start a new request.")
        }
        let refreshed: GIDGoogleUser
        do { refreshed = try await user.refreshTokensIfNeeded() }
        catch { throw Self.safeError(error) }
        try Task.checkCancellation()
        guard refreshed.userID == accountID, signIn.currentUser?.userID == accountID else {
            throw BrowserError("calendar_account_changed", "Your Google account changed. Start a new request.")
        }
        return refreshed
    }
    func accessToken(for accountID: String) async throws -> String {
        let user = try await refreshedUser(for: accountID)
        guard Self.scopes.isSubset(of: Set(user.grantedScopes ?? [])) else {
            throw BrowserError("calendar_reconnect_required", "Approve Calendar permissions to continue.")
        }
        return user.accessToken.tokenString
    }
    func idToken(for accountID: String) async throws -> String {
        guard let token = try await refreshedUser(for: accountID).idToken?.tokenString else {
            throw BrowserError("google_identity_failed", "Sign in again to access your inventory.")
        }
        return token
    }
    func signOut() {
        guard configurationIssue == nil else { return }
        GIDSignIn.sharedInstance.signOut()
    }
    func disconnect() async throws {
        do { try await configuredSignIn().disconnect() }
        catch { throw Self.safeError(error) }
    }
    private static func safeError(_ error: Error) -> Error {
        if error is CancellationError || error is BrowserError { return error }
        let ns = error as NSError
        if ns.domain == kGIDSignInErrorDomain, ns.code == GIDSignInError.Code.canceled.rawValue {
            return BrowserError("google_sign_in_cancelled", "Connect Google Calendar to finish setting up Agora.")
        }
        if ns.domain == NSURLErrorDomain {
            return BrowserError("connection_failed", "Could not reach Google. Check your connection and try again.")
        }
        return BrowserError("calendar_reconnect_required", "Google sign-in needs attention. Please connect again.")
    }
}
