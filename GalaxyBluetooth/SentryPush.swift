import SwiftUI
import UserNotifications
import CryptoKit

@MainActor
final class SentryPush: ObservableObject {
    static let shared = SentryPush()
    @Published private(set) var enabled: Bool
    @Published private(set) var registered = false
    @Published private(set) var status = "Enable phone alerts to set up notifications automatically."
    @Published var openEvents = false
    private var token = ""
    private var busy = false
    private var lastAttempt = Date.distantPast
    var transport: (any GalaxyRequestTransport)?
    private let defaults: UserDefaults
    private let environment: String
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         environment: String = Bundle.main.object(forInfoDictionaryKey: "SentryAPNsEnvironment") as? String ?? "",
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.environment = environment
        self.now = now
        enabled = defaults.bool(forKey: "galaxy.sentry.enabled")
    }
    private var identity: String { defaults.string(forKey: "galaxy.comma.identity") ?? "" }
    private var subscribed: [String: String] {
        get { defaults.dictionary(forKey: "galaxy.sentry.subscriptions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "galaxy.sentry.subscriptions") }
    }
    var id: String { token.isEmpty ? "" : SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description }
    var stateJSON: String {
        let value: [String: Any] = ["available": true, "enabled": enabled, "registered": registered, "id": id, "status": status]
        return String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)!
    }

    func restore() {
        if enabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    func setEnabled(_ on: Bool) async {
        if on {
            do {
                guard try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) else {
                    status = "Allow notifications in iPhone Settings to receive Sentry alerts."
                    return
                }
            } catch { status = "Couldn’t request notification permission."; return }
            enabled = true
            defaults.set(true, forKey: "galaxy.sentry.enabled")
            defaults.set(true, forKey: "galaxy.sentry.enrollRequested")
            status = "Registering this iPhone…"
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            enabled = false
            defaults.set(false, forKey: "galaxy.sentry.enabled")
            defaults.set(false, forKey: "galaxy.sentry.enrollRequested")
            registered = false
            UIApplication.shared.unregisterForRemoteNotifications()
            status = "Phone alerts disabled. Reconnect to comma to remove its subscription."
        }
        lastAttempt = .distantPast
        await synchronize()
    }

    func receivedToken(_ data: Data) {
        guard ["production", "development"].contains(environment) else { status = "This build has no APNs environment configured."; return }
        token = "apns.\(environment == "development" ? "sandbox" : "production")." + data.map { String(format: "%02x", $0) }.joined()
        registered = false
        lastAttempt = .distantPast
        Task { await synchronize() }
    }

    func registrationFailed() { registered = false; status = "Apple push registration failed. Check internet access and the app’s Push Notifications capability." }

    private func request(_ body: [String: Any], over transport: any GalaxyRequestTransport) async throws -> [String: Any] {
        let result = try await transport.request(path: "/api/sentry/notifications", method: "POST",
            headers: ["Content-Type": "application/json"], body: JSONSerialization.data(withJSONObject: body))
        guard result.status == 200, let value = try JSONSerialization.jsonObject(with: result.bodyData) as? [String: Any] else {
            throw BridgeError.message("Couldn’t update phone alerts on comma (HTTP \(result.status)).")
        }
        return value
    }

    func synchronize() async {
        guard !busy, let transport, transport.connected, !identity.isEmpty,
              now().timeIntervalSince(lastAttempt) >= 60 else { return }
        let device = identity
        guard enabled ? !token.isEmpty : subscribed[device] != nil else { return }
        busy = true
        lastAttempt = now()
        defer { busy = false }
        do {
            let currentToken = token
            if let old = subscribed[device], !enabled || old != currentToken {
                _ = try await request(["action": "appUnsubscribe", "token": old], over: transport)
                var values = subscribed; values.removeValue(forKey: device); subscribed = values
            }
            guard enabled else { status = "Phone alerts disabled."; return }
            guard device == identity else { return }
            var result = try await request(["action": "appSubscribe", "token": currentToken,
                "appId": Bundle.main.bundleIdentifier ?? "", "label": "iPhone"], over: transport)
            var values = subscribed; values[device] = currentToken; subscribed = values
            if !enabled {
                _ = try await request(["action": "appUnsubscribe", "token": currentToken], over: transport)
                values.removeValue(forKey: device); subscribed = values
                status = "Phone alerts disabled."
                return
            }
            guard device == identity, token == currentToken else { lastAttempt = .distantPast; return }
            if defaults.bool(forKey: "galaxy.sentry.enrollRequested") {
                if let relay = result["relayEnrollment"] as? [String: Any] {
                    if relay["automaticConfigured"] as? Bool == true || ["enrolling", "enrolled", "rotating", "confirming"].contains(relay["state"] as? String ?? "") {
                        result = try await request(["action": "relayEnroll", "confirmed": true], over: transport)
                        defaults.set(false, forKey: "galaxy.sentry.enrollRequested")
                    }
                } else { defaults.set(false, forKey: "galaxy.sentry.enrollRequested") }
            }
            guard enabled, device == identity, token == currentToken else { lastAttempt = .distantPast; return }
            registered = true
            let enrollment = (result["relayEnrollment"] as? [String: Any])?["state"] as? String
            switch enrollment {
            case "enrolling", "rotating", "confirming": status = "Phone registered. Waiting for relay enrollment in Galaxy → Sentry."
            case "unenrolled", "revoked": status = (result["relayEnrollment"] as? [String: Any])?["automaticConfigured"] as? Bool == true ? "Enable alerts to enroll this comma automatically." : "Phone registered. Hosted alerts are not configured in this release yet."
            case "revoking": status = "Relay revocation pending. Push alerts are paused."
            case "actionRequired": status = "Relay authorization needs attention in Galaxy → Sentry."
            default: status = result["appPushAvailable"] as? Bool == true ? "Registered. Send a test from Galaxy → Sentry." : "Registered. Configure the HTTPS push relay in Galaxy → Sentry."
            }
        } catch { registered = false; status = "Couldn’t register phone alerts. Reconnect and check Galaxy’s relay settings." }
    }

    func test() async {
        guard enabled, registered, let transport, transport.connected else { return }
        do {
            _ = try await request(["action": "test", "target": "app", "id": id], over: transport)
            status = "Test queued. Check for a notification."
        } catch { status = "Couldn’t send a test. Check the relay in Galaxy → Sentry." }
    }
}

@MainActor
final class SentryAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        SentryPush.shared.restore()
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) { SentryPush.shared.receivedToken(token) }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) { SentryPush.shared.registrationFailed() }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in completion(SentryPush.shared.enabled ? [.banner, .sound, .list] : []) }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completion: @escaping () -> Void) {
        guard response.notification.request.content.userInfo["type"] as? String == "sentry" else { completion(); return }
        Task { @MainActor in
            SentryPush.shared.openEvents = true
            AppModel.shared.tab = .galaxy
            completion()
        }
    }
}

struct SentrySettingsView: View {
    @ObservedObject private var push = SentryPush.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Sentry phone alerts", isOn: Binding(get: { push.enabled }, set: { on in Task { await push.setEnabled(on) } }))
            Text(push.status).font(.caption).foregroundStyle(.secondary)
            if push.enabled && push.registered { Button("Send test to this iPhone") { Task { await push.test() } } }
        }.padding(14)
    }
}
