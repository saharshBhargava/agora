import SwiftUI
import UserNotifications
import UIKit

/// OS registration is separate from the persistent inbox. No credentials or device tokens enter logs.
@MainActor
final class PushNotifications: ObservableObject {
    static let shared = PushNotifications()
    @Published private(set) var permissionStatus = "Not enabled"
    @Published var openWatchID: UUID?
    private var token: String?
    private var deviceID: UUID?
    private var api: AgoraClient?
    private var revision = UUID()
    private var registration: Task<Void, Never>?

    func enable(api: AgoraClient) async throws {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard granted else {
            permissionStatus = "Notifications are disabled in Settings"
            throw BrowserError("notifications_disabled", permissionStatus)
        }
        self.api = api
        permissionStatus = "Registering this device"
        UIApplication.shared.registerForRemoteNotifications()
        if token != nil { try await register(api: api) }
    }

    func sync(api: AgoraClient) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        self.api = api
        UIApplication.shared.registerForRemoteNotifications()
        if token != nil {
            do { try await register(api: api) }
            catch { permissionStatus = "Could not register alerts. Offers remain in your inbox." }
        }
    }

    func registered(_ data: Data) {
        token = data.map { String(format: "%02x", $0) }.joined()
        guard let api else { return }
        registration?.cancel()
        registration = Task {
            do { try await register(api: api) }
            catch { if !Task.isCancelled { permissionStatus = "Could not register alerts. Offers remain in your inbox." } }
        }
    }

    private func register(api: AgoraClient) async throws {
        guard let token else { return }
        let version = revision
        let environment = Bundle.main.object(forInfoDictionaryKey: "AgoraPushEnvironment") as? String ?? "sandbox"
        let result = try await api.fetch("v1/push-devices", as: PushRegistration.self, method: "POST",
                                         body: ["token": token, "environment": environment])
        guard version == revision, !Task.isCancelled else { return }
        deviceID = result.id
        permissionStatus = result.deliveryStatus == "available" ? "Push alerts enabled" : "Push delivery is not configured on the server. Offers remain in your inbox."
    }

    /// Called while the old account is still authenticated, before its credentials are discarded.
    func signOut(api: AgoraClient) async {
        let previousDeviceID = deviceID
        suspend()
        if let previousDeviceID { try? await api.send("v1/push-devices/\(previousDeviceID)", method: "DELETE") }
    }

    func suspend() {
        revision = UUID(); registration?.cancel(); registration = nil
        self.api = nil; openWatchID = nil
        UIApplication.shared.unregisterForRemoteNotifications()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        deviceID = nil; token = nil; permissionStatus = "Not enabled"
    }

    func registrationFailed() {
        permissionStatus = "This device could not register for push. Offers remain in your inbox."
    }

    func opened(_ userInfo: [AnyHashable: Any]) {
        guard let value = userInfo["watch_id"] as? String, let id = UUID(uuidString: value) else { return }
        openWatchID = id
    }
}

private struct PushRegistration: Decodable {
    let id: UUID
    let deliveryStatus: String
}

final class AgoraNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushNotifications.shared.registered(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushNotifications.shared.registrationFailed() }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            PushNotifications.shared.opened(response.notification.request.content.userInfo)
            completionHandler()
        }
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
