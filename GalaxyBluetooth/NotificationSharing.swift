import Foundation
import UserNotifications

enum NotificationBondError: Error, Equatable {
    case unavailable, declined, timedOut, disconnected, staleBond, busy, failed
}

/// iOS shares notifications only with a bonded accessory, so comma reads them itself over Apple's notification service.
/// The app opens comma's short bond window, then reads an encrypted characteristic so iOS shows its pairing request.
@MainActor
final class NotificationSharing: ObservableObject {
    enum Phase: Equatable {
        case idle
        case requesting
        case pairing
        case done
        case message(String)
    }

    static let windowPath = "/_bridge/notification-bond"
    static let hintKey = "galaxy.notifications.sharedDevice"
    static let updateMessage = "Update StarPilot on your comma to use phone notifications."
    static let bluetoothMessage = "Connect to comma over Bluetooth to set this up."

    static let testTitle = "StarPilot test notification"
    static let testType = "starpilotTest"

    var onEvent: ((String) -> Void)?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var testStatus: String?
    private let transport: () -> (any GalaxyRequestTransport)?
    private let supported: () -> Bool
    private let bond: () async throws -> Void
    private let device: () -> String?
    private let defaults: UserDefaults
    private var task: Task<Void, Never>?

    /// `transport` must be the Bluetooth transport: the bond belongs to that link.
    init(transport: @escaping () -> (any GalaxyRequestTransport)?, supported: @escaping () -> Bool,
         bond: @escaping () async throws -> Void, device: @escaping () -> String?, defaults: UserDefaults = .standard) {
        self.transport = transport; self.supported = supported; self.bond = bond; self.device = device; self.defaults = defaults
    }

    var active: Bool { phase == .requesting || phase == .pairing }

    /// A hint only: the person can turn sharing off in iPhone Settings without the app knowing.
    var sharedWithThisComma: Bool {
        guard let id = device(), !id.isEmpty else { return false }
        return defaults.string(forKey: Self.hintKey) == id
    }

    func summary(bluetoothConnected: Bool) -> String {
        switch phase {
        case .requesting, .pairing: return "Setup in progress"
        case .done: return "Shared with comma"
        case .message: return "Setup needs attention"
        case .idle:
            if bluetoothConnected && !supported() { return "Needs a StarPilot update on comma" }
            return sharedWithThisComma ? "Set up on this comma" : "Not set up"
        }
    }

    func start() {
        guard task == nil else { return }
        onEvent?("Phone notifications setup started")
        phase = .requesting
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func dismiss() { if active { cancel() } else { phase = .idle } }

    /// Posts a local notification; iOS shares it with comma like any other, so it checks the whole path.
    func sendTest() async {
        let center = UNUserNotificationCenter.current()
        let allowed: Bool
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: allowed = true
        case .notDetermined: allowed = (try? await center.requestAuthorization(options: [.alert])) ?? false
        default: allowed = false
        }
        guard allowed else {
            testStatus = "Allow notifications for this app in iPhone **Settings → Notifications** so it can send a test."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = Self.testTitle
        content.body = "If sharing works, this shows on your comma and car screen."
        content.userInfo = ["type": Self.testType]
        let request = UNNotificationRequest(identifier: "starpilot-test-" + UUID().uuidString, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        do {
            try await center.add(request)
            onEvent?("Phone notifications test posted")
            testStatus = "Test sent. Look at the top of the comma screen or car screen. If nothing shows within a few seconds, check that **Share System Notifications** is on for comma in **Settings → Bluetooth** and that **Show phone notifications** is on in Galaxy → Toggles → Phone."
        } catch {
            testStatus = "Couldn't send the test. Try again."
        }
    }

    private func run() async {
        guard let transport = transport(), transport.connected else { phase = .message(Self.bluetoothMessage); return }
        guard supported() else { phase = .message(Self.updateMessage); return }
        let response: BridgeResponse
        do {
            response = try await transport.request(path: Self.windowPath, method: "POST",
                                                   headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        } catch {
            if Task.isCancelled { return }
            onEvent?("Phone notifications window request failed: " + error.localizedDescription)
            phase = .message(transport.connected ? Self.updateMessage : Self.bluetoothMessage)
            return
        }
        if Task.isCancelled { return }
        onEvent?("Phone notifications window request finished: HTTP \(response.status)")
        switch response.status {
        case 200: break
        case 409:
            phase = .message(Self.busyMessage(response.bodyData)); return
        case 400, 404, 405, 501:
            phase = .message(Self.updateMessage); return
        default:
            phase = .message("Comma couldn't start setup. Try again."); return
        }
        phase = .pairing
        do {
            try await bond()
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            onEvent?("Phone notifications pairing failed: \(error)")
            phase = .message(Self.message(for: error))
            return
        }
        if Task.isCancelled { return }
        if let id = device(), !id.isEmpty { defaults.set(id, forKey: Self.hintKey) }
        onEvent?("Phone notifications pairing finished")
        phase = .done
    }

    /// Map comma's reason code to app copy; its own text is never shown.
    nonisolated static func busyMessage(_ body: Data) -> String {
        let code = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["code"] as? String
        switch code {
        case "park_required"?: return "Park the car to set up phone notifications."
        case "bluetooth_off"?, "bluetooth_unavailable"?, "starting"?, "not_ready"?: return "Comma's Bluetooth isn't ready. Try again in a moment."
        case "disconnected"?: return message(for: NotificationBondError.disconnected)
        default: return "Comma is busy pairing another device. Wait a minute, then try again."
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error as? NotificationBondError {
        case .declined?: return "Pairing wasn't completed. Try again and tap **Pair** when iOS asks."
        case .timedOut?: return "iOS didn't finish pairing in time. Try again and tap **Pair** when iOS asks."
        case .disconnected?: return "Comma disconnected during setup. Reconnect over Bluetooth and try again."
        case .unavailable?: return "Your iPhone hasn't seen comma's new Bluetooth features yet. Turn Bluetooth off and on, reconnect, then try again."
        case .staleBond?: return "Your iPhone's saved pairing with comma has changed. In **Settings → Bluetooth**, tap ⓘ next to comma, choose **Forget This Device**, then reconnect and try again."
        case .busy?: return "Setup is already running."
        case .failed?, nil: return "Pairing didn't finish. Try again."
        }
    }
}
