import Foundation

struct BridgeResponse { let status: Int; let bodyData: Data }
enum BridgeError: Error { case message(String) }
@MainActor protocol GalaxyRequestTransport: AnyObject {
    var connected: Bool { get }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse
}
@MainActor final class UIApplication {
    static let shared = UIApplication()
    func registerForRemoteNotifications() {}
    func unregisterForRemoteNotifications() {}
}
@MainActor final class Transport: GalaxyRequestTransport {
    var connected = true
    var requests: [[String: Any]] = []
    var status = 200
    var enrollment: String?
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        precondition(path == "/api/sentry/notifications" && method == "POST")
        requests.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        var value: [String: Any] = ["appPushAvailable": true]
        if let enrollment { value["relayEnrollment"] = ["state": enrollment, "automaticConfigured": true] }
        return BridgeResponse(status: status, bodyData: try JSONSerialization.data(withJSONObject: value))
    }
}
@main struct Regression {
    @MainActor static func main() async {
        let suite = "sentry-regression-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "galaxy.sentry.enabled")
        defaults.set("comma-one", forKey: "galaxy.comma.identity")
        var time = Date()
        let push = SentryPush(defaults: defaults, environment: "production", now: { time })
        let transport = Transport()
        push.transport = transport
        push.receivedToken(Data(repeating: 0xab, count: 32))
        await push.synchronize()
        precondition(transport.requests.count == 1)
        precondition(transport.requests[0]["token"] as? String == "apns.production." + String(repeating: "ab", count: 32))
        precondition(push.registered && push.id.count == 12)
        await push.synchronize()
        precondition(transport.requests.count == 1)
        push.receivedToken(Data(repeating: 0xcd, count: 32))
        await push.synchronize()
        precondition(transport.requests.suffix(2).map { $0["action"] as! String } == ["appUnsubscribe", "appSubscribe"])
        transport.connected = false
        await push.setEnabled(false)
        precondition(!push.enabled && !push.registered)
        let count = transport.requests.count
        transport.connected = true
        time = time.addingTimeInterval(61)
        await push.synchronize()
        precondition(transport.requests.count == count + 1 && transport.requests.last?["action"] as? String == "appUnsubscribe")
        precondition((defaults.dictionary(forKey: "galaxy.sentry.subscriptions") ?? [:]).isEmpty)

        defaults.set(true, forKey: "galaxy.sentry.enabled")
        let sandbox = SentryPush(defaults: defaults, environment: "development", now: { time })
        sandbox.transport = transport
        transport.status = 500
        sandbox.receivedToken(Data(repeating: 1, count: 32))
        await sandbox.synchronize()
        precondition(!sandbox.registered)
        precondition((transport.requests.last?["token"] as? String)?.hasPrefix("apns.sandbox.") == true)
        transport.status = 200
        time = time.addingTimeInterval(61)
        await sandbox.synchronize()
        precondition(sandbox.registered)
        await sandbox.test()
        precondition(transport.requests.last?["id"] as? String == sandbox.id)
        let beforeDeviceChange = transport.requests.count
        defaults.set("comma-two", forKey: "galaxy.comma.identity")
        await sandbox.test()
        precondition(transport.requests.count == beforeDeviceChange, "Do not test an enrollment belonging to another comma")
        await sandbox.synchronize()
        precondition(!sandbox.registered, "Changing comma clears registration even while throttled")
        defaults.set("comma-one", forKey: "galaxy.comma.identity")
        transport.enrollment = "actionRequired"
        time = time.addingTimeInterval(61)
        await sandbox.synchronize()
        precondition(sandbox.registered && sandbox.status.contains("authorization needs attention"))
        transport.enrollment = "unenrolled"
        time = time.addingTimeInterval(61)
        await sandbox.synchronize()
        precondition(sandbox.status.contains("enroll this comma"))
        defaults.set(true, forKey: "galaxy.sentry.enrollRequested")
        time = time.addingTimeInterval(61)
        await sandbox.synchronize()
        precondition(transport.requests.suffix(2).map { $0["action"] as! String } == ["appSubscribe", "relayEnroll"])
        precondition(transport.requests.last?["confirmed"] as? Bool == true)
        precondition(!defaults.bool(forKey: "galaxy.sentry.enrollRequested"))
        print("Sentry registration, rotation, retry, unsubscribe and test regressions passed")
    }
}
