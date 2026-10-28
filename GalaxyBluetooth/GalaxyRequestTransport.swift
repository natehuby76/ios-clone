import Foundation

@MainActor
protocol GalaxyRequestTransport: AnyObject {
    var connected: Bool { get }
    var catalogSHA256: String? { get }
    var localRefreshDelay: TimeInterval? { get }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse
    /// GET one Galaxy page file (not an API call). Only the Local Wi-Fi/LAN transport can do this.
    func page(path: String) async throws -> BridgeResponse
}

extension GalaxyRequestTransport {
    var catalogSHA256: String? { nil }
    var localRefreshDelay: TimeInterval? { nil }
    func page(path: String) async throws -> BridgeResponse {
        throw BridgeError.message("Galaxy screens can only be downloaded from comma over Local Wi-Fi or Tunnel.")
    }
}

/// When the phone already reaches comma over Local Wi-Fi/LAN it opens comma's two-minute pairing window itself, the same call
/// as Pair phone on Galaxy's Bluetooth page, so nobody has to touch comma before the Bluetooth key claim.
enum LANPairing {
    static let windowPath = "/api/bluetooth/action"
    static let windowBody = Data("{\"operation\":\"accept_pair\"}".utf8)
    /// False means there is no verified LAN session for opening the window.
    /// A refused or uncertain LAN request must not silently start a Bluetooth claim.
    @MainActor static func openWindow(over lan: any GalaxyRequestTransport,
        pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        progress: (String) -> Void = { _ in }) async throws -> Bool {
        guard lan.connected else { return false }
        for attempt in 0...15 {
            try Task.checkCancellation()
            let response = try await lan.request(path: "/api/companion/bluetooth-ready", method: "GET", headers: [:], body: Data())
            // Older comma versions do not expose readiness. The window POST remains authoritative.
            guard response.status == 200,
                  let json = try? JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any],
                  json["schema"] as? Int == 1, let ready = json["ready"] as? Bool else { break }
            if ready { break }
            let code = json["code"] as? String ?? ""
            let message = json["message"] as? String ?? "Comma is not ready to pair."
            guard ["starting", "bridge_starting"].contains(code), attempt < 15 else {
                throw BridgeError.message(message)
            }
            progress(message)
            try await pause(3_000_000_000)
        }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            progress("Opening comma’s pairing window over Local Wi-Fi…")
            let response = try await lan.request(path: windowPath, method: "POST", headers: [:], body: windowBody)
            try Task.checkCancellation()
            if response.status == 200 { return true }
            let json = (try? JSONSerialization.jsonObject(with: response.bodyData)) as? [String: Any]
            let code = json?["code"] as? String ?? ""
            if response.status == 409 && code == "busy" && attempt < 3 {
                progress("Comma’s Bluetooth is busy. Waiting to retry…")
                try await pause(2_500_000_000)
                continue
            }
            throw BridgeError.message("Couldn’t open comma’s pairing window (HTTP \(response.status)\(code.isEmpty ? "" : " · " + code)). Check your Local Wi-Fi connection to comma, then retry Bluetooth setup in this app.")
        }
        return false
    }
}

enum SecretGoodGalaxy {
    static func diagnosticPath(_ target: String) -> String {
        let path = String(target.prefix(512)).split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        if ["/_bridge/health", "/data/runtime.json", "/api/navigation/status", "/api/navigation/action", "/api/companion/location", "/api/device/state"].contains(path) { return path }
        let category = path.split(separator: "/").dropFirst().first.map(String.init) ?? ""
        let known = ["auth", "galaxy", "settings", "local-access", "system", "ui", "companion", "navigation", "device", "cameras", "recordings", "maps", "android-auto", "spotify", "phone-internet"]
        return path.hasPrefix("/api/") && known.contains(category) ? "/api/" + category + "/…" : "[other path]"
    }
    static func validTarget(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.hasPrefix("//"),
              let parts = URLComponents(string: path), parts.scheme == nil, parts.host == nil, parts.fragment == nil,
              let decoded = parts.percentEncodedPath.removingPercentEncoding,
              !decoded.contains("%"), !decoded.contains("\\"), !decoded.contains("//"),
              !decoded.unicodeScalars.contains(where: { $0.value < 32 }),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return false }
        return decoded.hasPrefix("/api/") || decoded == "/data/runtime.json"
    }
    /// A Galaxy page file under the same roots the app accepts when it saves comma's screens.
    static func validPage(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 47, 95].contains($0) }) else { return false }
        let file = String(path.dropFirst())
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), file != "data/runtime.json" else { return false }
        return ["index.html", "manifest.webmanifest", "sentry-push-worker.js"].contains(file)
            || ["assets/", "css/", "js/", "vendor/", "data/"].contains(where: { file.hasPrefix($0) })
    }
    static func needsWiFi(_ path: String) -> Bool {
        let path = URLComponents(string: path)?.path ?? path
        return ["/api/recordings/", "/api/replay/", "/api/cameras/", "/api/maps/tiles/",
                "/api/android-auto/upload", "/api/android-auto/apk", "/api/phone-internet/", "/api/spotify/upload"].contains(where: { path.hasPrefix($0) })
            || ["/api/auth/login", "/api/auth/logout"].contains(path)
    }
}

/// Coalesce simultaneous identical reads. View/intent tokens are never cached for later use.
@MainActor
final class GalaxyReadCache: GalaxyRequestTransport {
    private let transport: any GalaxyRequestTransport
    private let sessionID: () -> String
    private var session = ""
    private var generation: UInt64 = 0
    private var pending: [String: (UUID, Task<BridgeResponse, Error>)] = [:]
    var connected: Bool { transport.connected }
    var catalogSHA256: String? { transport.catalogSHA256 }
    var localRefreshDelay: TimeInterval? { transport.localRefreshDelay }

    init(transport: any GalaxyRequestTransport, sessionID: @escaping () -> String,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.transport = transport
        self.sessionID = sessionID
    }

    private func invalidate() {
        generation += 1
        // Already-sent reads still drain, but new reads cannot join an old one.
        pending.removeAll()
    }

    func page(path: String) async throws -> BridgeResponse { try await transport.page(path: path) }

    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        try Task.checkCancellation()
        if session != sessionID() {
            session = sessionID()
            invalidate()
        }
        guard connected else { throw BridgeError.message("Connect to your comma over Bluetooth first.") }
        if method != "GET" {
            invalidate()
            defer { invalidate() }
            return try await transport.request(path: path, method: method, headers: headers, body: body)
        }
        guard body.isEmpty, path.hasPrefix("/api/"), headers.keys.allSatisfy({ !["authorization", "range"].contains($0.lowercased()) }) else {
            return try await transport.request(path: path, method: method, headers: headers, body: body)
        }
        let relevantHeaders = headers
            .map { "\($0.key.lowercased()):\($0.value)" }.sorted().joined(separator: "\n")
        let cacheKey = path + "\n" + relevantHeaders
        let token: UUID
        let task: Task<BridgeResponse, Error>
        if let existing = pending[cacheKey] {
            (token, task) = existing
        } else {
            // Bound cache variants even when a local client changes headers.
            guard pending.count < 16 else {
                return try await transport.request(path: path, method: method, headers: headers, body: body)
            }
            token = UUID()
            task = Task { try await transport.request(path: path, method: method, headers: headers, body: body) }
            pending[cacheKey] = (token, task)
        }
        let readGeneration = generation
        let readSession = session
        defer { if pending[cacheKey]?.0 == token { pending.removeValue(forKey: cacheKey) } }
        let response = try await task.value
        guard readGeneration == generation, readSession == sessionID(), connected else {
            throw BridgeError.message("Connection or saved settings changed during this read. Load the page again.")
        }
        try Task.checkCancellation()
        return response
    }
}

/// Include time spent in the Bluetooth queue in the phone-reported fix age.
/// Expired GPS is discarded before transmission; other requests are unchanged.
enum PhoneGpsDelivery {
    static func body(_ body: Data, path: String, queuedSeconds: TimeInterval) throws -> Data {
        guard path == "/api/companion/location" else { return body }
        guard queuedSeconds.isFinite, queuedSeconds >= 0,
              var value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let age = value["ageMs"] as? Double, age.isFinite, age >= 0,
              age + queuedSeconds * 1000 <= 2000 else {
            throw BridgeError.message("Waiting for a fresh GPS fix.")
        }
        value["ageMs"] = age + queuedSeconds * 1000
        return try JSONSerialization.data(withJSONObject: value)
    }
}
