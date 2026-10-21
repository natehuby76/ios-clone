import Foundation
import Combine
import CryptoKit

/// Navigation adapter only. Pairing, reconnects, GPS uploads and BLE ownership stay in AppModel.
@MainActor
final class CommaConnection: ObservableObject {
    unowned let app: AppModel
    var bluetooth: BluetoothTransport { app.bluetooth }
    var transport: PreferredTransport { app.transport }
    var connected: Bool { transport.connected }
    var connectionLabel: String { connected ? transport.label + " connected" : bluetooth.connecting || bluetooth.isScanning ? "Connecting…" : "Comma not connected" }
    var nativeNavigation: Bool { true }
    @Published var busy = false
    private var verifiedIdentity: String?
    private var identitySession = ""
    private var nativeReadRevision: (session: String, revision: String)?
    private var parkedSample: (session: String, date: Date, value: Bool)?
    private var lastFeedState = ""
    private var requestGeneration = 0
    private var networkSession: String { transport.usesLAN ? "lan-" + app.lan.generation : "ble-" + bluetooth.sessionIdentifier }
    var session: String { networkSession + ":" + String(requestGeneration) }
    func invalidateNavigationRequests() { requestGeneration += 1; nativeReadRevision = nil }
    var deviceIdentity: String? { connected && networkSession == identitySession ? verifiedIdentity : nil }
    init(app: AppModel) { self.app = app }
    func record(_ value: String) { app.connectionLog.record("Navigation: " + value) }
    func recordAction(_ value: String) { record(value) }
    func ensureDeviceIdentity() async throws -> String {
        if let identity = deviceIdentity { return identity }
        let before = session
        let response = try await transport.request(path: nativeNavigation ? "/data/runtime.json" : "/api/params?key=DongleId", method: "GET", headers: [:], body: Data())
        guard connected, session == before, response.status == 200 else { throw BridgeError.message("Connection changed while verifying comma.") }
        let identity = nativeNavigation ? NativeNavigationAPI.identity(response.bodyData) : String(data: response.bodyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity, identity.count == 16, identity.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw BridgeError.message("Comma identity unavailable.") }
        verifiedIdentity = identity; identitySession = networkSession
        record("Comma identity verified")
        return identity
    }
    // Navigation commands never use the general settings or params write endpoints.
    func navigation(_ command: NavigationCommand) async throws -> Data {
        guard connected else { throw BridgeError.message("Connect to comma before sending navigation.") }
        if nativeNavigation {
            let before = session
            let data = try await NativeNavigationAPI.command(command, transport: transport,
                expectedRevision: nativeReadRevision?.session == before ? nativeReadRevision?.revision : nil,
                stillCurrent: { self.session == before })
            if case .read = command, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let value = object["nativeRevision"] as? String {
                nativeReadRevision = (before, value)
            } else { nativeReadRevision = nil }
            return data
        }
        let before = session
        let response = try await transport.request(path: command.path, method: command.method,
            headers: ["content-type": "application/json"], body: try command.body())
        guard before == session else { throw BridgeError.message("Connection changed. Check comma before trying again.") }
        record("Navigation \(command.method): HTTP \(response.status)")
        guard (200...299).contains(response.status) else {
            throw BridgeError.message("Comma rejected navigation (HTTP \(response.status)). Check its Galaxy navigation keys and setup.")
        }
        return response.bodyData
    }
    func commaIsParked() async -> Bool? {
        guard connected else { return nil }
        let before = session
        if let sample = parkedSample, sample.session == before, sample.date > Date() {
            return sample.value
        }
        do {
            let requestedAt = Date()
            let response = try await transport.request(path: nativeNavigation ? "/api/device/state" : "/api/device/status", method: "GET", headers: [:], body: Data())
            guard session == before, response.status == 200,
                  let json = try JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any] else { return nil }
            let parked: Bool
            let expires: Date
            if nativeNavigation {
                guard let state = json["state"] as? String, ["parked", "driving", "standby"].contains(state),
                      let age = json["maxAgeMs"] as? Double, age.isFinite, age > 0, age <= 3000,
                      requestedAt.addingTimeInterval(age / 1000) > Date() else { return nil }
                parked = state == "parked"; expires = requestedAt.addingTimeInterval(age / 1000)
            } else {
                guard let status = json["status"] as? String, ["Parked", "Driving"].contains(status) else { return nil }
                parked = status == "Parked"; expires = Date().addingTimeInterval(10)
            }
            parkedSample = (before, expires, parked)
            return parked
        } catch { return nil }
    }
    func navigationSnapshot(version: String? = nil) async throws -> CommaRouteSnapshot {
        if nativeNavigation {
            let before = session
            let response = try await transport.request(path: try NativeNavigationAPI.statusPath(version: version), method: "GET", headers: [:], body: Data())
            guard before == session, response.status == 200 else { throw BridgeError.message("Comma navigation status unavailable (HTTP \(response.status)).") }
            let decoded = try NativeNavigationAPI.decode(response.bodyData)
            let snapshot = try NativeNavigationAPI.snapshot(response.bodyData)
            let state = "Navigation feed: \(decoded.status); enabled: \(decoded.enabled); map key configured: \(decoded.hasKey); instruction: \(snapshot.instruction != nil)"
            if state != lastFeedState { lastFeedState = state; recordAction(state) }
            return snapshot
        }
        guard connected, let bytes = Data(hex: PairingKeyStore.load()), bytes.count == 32 else {
            throw BridgeError.message("Connect to your paired comma first.")
        }
        var path = "/api/companion/navigation"
        if let version {
            guard version.count == 64, version.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw NavigationContractError.invalidResponse
            }
            path += "?routeVersion=" + version
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let signature = HMAC<SHA256>.authenticationCode(for: Data("\(nonce)\nGET\n\(path)".utf8),
            using: SymmetricKey(data: bytes)).map { String(format: "%02x", $0) }.joined()
        let before = session
        let response = try await transport.request(path: path, method: "GET",
            headers: ["x-companion-nonce": nonce, "x-companion-mac": signature], body: Data())
        guard before == session else { throw BridgeError.message("Comma connection changed.") }
        guard response.status == 200 else {
            if response.status == 404 { throw BridgeError.message("Install the read-only navigation feed on comma first.") }
            throw BridgeError.message("Comma navigation feed unavailable (HTTP \(response.status)).")
        }
        let snapshot = try JSONDecoder().decode(CommaRouteSnapshot.self, from: response.bodyData)
        try snapshot.validate()
        let state = "Navigation feed: \(snapshot.status); ready: \(snapshot.ready); instruction: \(snapshot.instruction != nil)"
        if state != lastFeedState {
            lastFeedState = state
            record(state)
        }
        return snapshot
    }

}
