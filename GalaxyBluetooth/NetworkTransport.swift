import Foundation
import Combine
import Security
import CryptoKit

/// Each request has an isolated, bounded buffer.
final class BoundedHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var cancelled = false
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    static func load(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let client = BoundedHTTP(limit: limit)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { client.start(request, continuation: $0) }
        }, onCancel: { client.cancel() })
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= limit else {
            completionHandler(.cancel); return
        }
        self.response = http
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count + data.count <= limit else { dataTask.cancel(); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let callback = continuation; continuation = nil; let cancelled = cancelled; lock.unlock()
        if cancelled { callback?.resume(throwing: CancellationError()) }
        else if let error { callback?.resume(throwing: error) }
        else if let response { callback?.resume(returning: (buffer, response)) }
        else { callback?.resume(throwing: BridgeError.message("Invalid HTTP response.")) }
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}

@MainActor
final class LANTransport: ObservableObject, GalaxyRequestTransport {
    @Published private(set) var connected = false
    @Published private(set) var status = "Local connection not checked yet."
    var onEvent: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var probeNumber = 0
    private(set) var endpoint: URL?
    private(set) var generation = UUID().uuidString
    private(set) var expectedDeviceID: String?
    private(set) var verifiedDeviceID: String?

    private var cookie: String?
    private var sessionTask: (UUID, Task<String, Error>)?
    private let load: (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    init(load: @escaping (URLRequest, Int) async throws -> (Data, HTTPURLResponse) = { try await PrivateLANHTTP.load($0, limit: $1) }) {
        self.load = load
    }

    // An explicit private IPv4 address prevents cloud/loopback endpoints from being treated as the local comma.
    static func endpoint(_ address: String) throws -> URL {
        var input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("http://") { input = String(input.dropFirst(7)) }
        if input.hasSuffix("/") { input.removeLast() }
        if input.hasSuffix(":8082") { input = String(input.dropLast(5)) }
        let parts = input.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ String(Int($0) ?? -1) == $0 }),
              let a = Int(parts[0]), let b = Int(parts[1]), parts.allSatisfy({ (0...255).contains(Int($0) ?? -1) }),
              a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168),
              let url = URL(string: "http://\(parts.joined(separator: ".")):8082") else {
            throw BridgeError.message("Enter your comma’s local IP address, such as 192.168.10.85.")
        }
        return url
    }
    func configure(address: String) throws {
        let new = try Self.endpoint(address)
        if endpoint != new { endpoint = new; invalidate(reason: "Comma LAN address changed") }
    }
    static func reportedAddress(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addresses = json["addresses"] as? [[String: Any]] else { return nil }
        return addresses.compactMap { row -> String? in
            guard let text = row["url"] as? String, let url = URL(string: text),
                  let host = url.host, let expected = try? endpoint(host),
                  url.scheme == "http", url.port == 8082, url.user == nil, url.password == nil,
                  url.host == expected.host else { return nil }
            return host
        }.first
    }
    static func runtimeDiagnostic(_ data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data) else {
            let prefix = String(decoding: data.prefix(128), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return prefix.hasPrefix("<") ? "HTML instead of runtime JSON" : "invalid JSON"
        }
        guard let json = value as? [String: Any] else { return "JSON root is not an object" }
        guard json["schemaVersion"] as? Int == 1 else { return "unsupported or missing runtime schema" }
        guard json["monitor"] as? String == "local" else { return "runtime is not a live comma" }
        guard deviceID(data) != nil else { return "missing or invalid runtime instance" }
        return "valid live runtime"
    }
    static func responseDiagnostic(_ data: Data, _ response: HTTPURLResponse) -> String {
        let mime = response.mimeType?.lowercased() ?? ""
        let type = mime.contains("json") ? "JSON" : mime.contains("html") ? "HTML" : mime.isEmpty ? "missing" : "other"
        return "HTTP \(response.statusCode); bytes=\(data.count); content-type=\(type); \(runtimeDiagnostic(data))"
    }
    static func deviceID(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 1, json["monitor"] as? String == "local",
              let value = json["instance"] as? String,
              value.count == 16, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return value
    }
    // Galaxy's runtime instance changes on restart. Its paired tunnel URL persists.
    // Store a digest so diagnostics never expose the private tunnel link.
    static func persistentIdentity(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["paired"] as? Bool == true, let text = json["url"] as? String,
              let url = TunnelTransport.endpoint(text) else { return nil }
        return persistentIdentity(url: url)
    }
    static func persistentIdentity(url: URL) -> String {
        "galaxy:" + SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func matches(_ expected: String?, runtime: String, persistent: String?) -> Bool {
        guard let expected else { return true }
        return expected.hasPrefix("galaxy:") ? expected == persistent : expected == runtime
    }
    private(set) var pairingIdentityMismatch = false
    func bind(to identity: String?) {
        if expectedDeviceID != identity { expectedDeviceID = identity; invalidate(reason: "Paired comma identity changed") }
    }
    func clearEndpoint() { endpoint = nil; invalidate(reason: "Saved LAN endpoint cleared") }
    func invalidate(reason: String = "LAN verification reset") {
        cookie = nil; sessionTask?.1.cancel(); sessionTask = nil
        connected = false; verifiedDeviceID = nil; generation = UUID().uuidString
        onEvent?(reason)
    }
    func probe() async -> Bool {
        guard endpoint != nil else { return false }
        pairingIdentityMismatch = false
        let expectedGeneration = generation
        probeNumber += 1
        let attempt = probeNumber, started = ProcessInfo.processInfo.systemUptime
        let wasConnected = connected
        let sampleProbe = !wasConnected || attempt % 20 == 0
        if sampleProbe { onDiagnostic?("LAN probe \(attempt) started; endpoint=\(endpoint?.host ?? "none"):8082; previously verified=\(wasConnected)") }
        defer {
            if sampleProbe || !connected || Task.isCancelled || expectedGeneration != generation {
                onDiagnostic?("LAN probe \(attempt) finished; elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s; cancelled=\(Task.isCancelled); superseded=\(expectedGeneration != generation); verified=\(connected)")
            }
        }
        do {
            let (data, response) = try await authenticated(path: "/data/runtime.json", method: "GET", headers: [:], body: Data(), limit: 4096)
            guard !Task.isCancelled, expectedGeneration == generation else { return false }
            if sampleProbe || response.statusCode != 200 { onDiagnostic?("LAN probe \(attempt) runtime response: \(Self.responseDiagnostic(data, response))") }
            let runtime = Self.deviceID(data)
            var persistent: String?
            if response.statusCode == 200, runtime != nil {
                do {
                    let (statusData, statusResponse) = try await authenticated(path: "/api/galaxy/status", method: "GET", headers: [:], body: Data(), limit: 8192)
                    if statusResponse.statusCode == 200 { persistent = Self.persistentIdentity(statusData) }
                    if sampleProbe || persistent == nil {
                        onDiagnostic?("LAN persistent identity response: HTTP \(statusResponse.statusCode); bytes=\(statusData.count); valid paired identity=\(persistent != nil)")
                    }
                } catch {
                    onDiagnostic?("LAN persistent identity request failed: \(Self.failureCode(error)); cancelled=\(Task.isCancelled)")
                }
            }
            let identity = persistent ?? runtime
            if sampleProbe { onDiagnostic?("LAN identity check: runtime=\(runtime != nil); persistent=\(persistent != nil); saved=\(expectedDeviceID != nil); matches=\(runtime.map { Self.matches(expectedDeviceID, runtime: $0, persistent: persistent) } ?? false)") }
            let available = response.statusCode == 200 && runtime != nil
                && Self.matches(expectedDeviceID, runtime: runtime ?? "", persistent: persistent)
            guard !Task.isCancelled, expectedGeneration == generation else { return false }
            let changed = connected != available
            connected = available
            verifiedDeviceID = available ? identity : nil
            if available {
                if let persistent, expectedDeviceID != persistent {
                    expectedDeviceID = persistent
                    onEvent?("Saved persistent comma identity")
                }
                status = "Local comma verified."
            }
            else if response.statusCode != 200 { status = "Galaxy answered HTTP \(response.statusCode)." }
            else if identity == nil { status = "The address answered, but did not return a valid Galaxy identity." }
            else if expectedDeviceID?.hasPrefix("galaxy:") == true && persistent == nil {
                status = "Waiting for comma’s saved identity."
                onEvent?("Comma identity verification unavailable: stable identity missing; saved identity preserved")
            }
            else {
                pairingIdentityMismatch = expectedDeviceID?.hasPrefix("galaxy:") == true && persistent != nil && persistent != expectedDeviceID
                status = pairingIdentityMismatch
                    ? "This address belongs to a different pairing identity. Select your comma in Settings to verify it."
                    : "Couldn’t verify the saved comma. Reconnect Bluetooth to confirm its identity."
                onEvent?("Comma identity mismatch: saved=\(expectedDeviceID ?? "none"); received=\(identity ?? "none"). A legacy runtime pin needs Bluetooth verification or explicit local-only selection after a restart.")
            }
            if changed || !available { onEvent?(available ? "LAN probe succeeded; comma identity verified" : "LAN probe rejected: " + status) }
        } catch {
            if !Task.isCancelled, expectedGeneration == generation {
                status = Self.failureCode(error)
                invalidate(reason: "LAN probe failed: \(status)")
            }
        }
        return connected
    }
    static func failureCode(_ error: Error) -> String {
        let value = error as NSError
        if let url = error as? URLError {
            let name: String
            switch url.code {
            case .timedOut: name = "timeout"
            case .networkConnectionLost: name = "connection lost"
            case .notConnectedToInternet: name = "no network route"
            case .cannotConnectToHost: name = "cannot reach comma"
            case .cancelled: name = "cancelled"
            default: name = "network error"
            }
            let context = url.userInfo["StarPilotLANContext"] as? String
            return "\(name) (\(value.domain) \(value.code))" + (context.map { "; " + $0 } ?? "")
        }
        return "\(value.domain) \(value.code)"
    }
    private func sessionCookie(endpoint: URL, generation original: String) async throws -> String {
        if let cookie { return cookie }
        let token: UUID
        let pending: Task<String, Error>
        if let existing = sessionTask {
            onDiagnostic?("LAN session: joining authentication already in progress")
            (token, pending) = existing
        }
        else {
            token = UUID()
            pending = Task {
                let started = ProcessInfo.processInfo.systemUptime
                onDiagnostic?("LAN session: authentication started; timeout=8s")
                defer { onDiagnostic?("LAN session: authentication finished; elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s; cancelled=\(Task.isCancelled); superseded=\(original != generation)") }
                var request = URLRequest(url: endpoint.appendingPathComponent("api/auth/session"))
                request.timeoutInterval = 8
                let (data, response) = try await load(request, 65_536)
                onDiagnostic?("LAN session: HTTP \(response.statusCode); bytes=\(data.count)")
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: response.allHeaderFields.reduce(into: [String: String]()) {
                    if let key = $1.key as? String { $0[key] = String(describing: $1.value) }
                }, for: endpoint)
                onDiagnostic?("LAN session: authenticated=\(json?["authenticated"] as? Bool == true); local access=\(json?["localAccess"] as? Bool == true); session cookie present=\(cookies.contains { $0.name == "galaxy_session" && !$0.value.isEmpty })")
                guard response.statusCode == 200, json?["authenticated"] as? Bool == true,
                      json?["localAccess"] as? Bool == true,
                      let value = cookies.first(where: { $0.name == "galaxy_session" && !$0.value.isEmpty }) else {
                    throw BridgeError.message("Couldn’t open a local Galaxy session. Connect directly to comma’s Wi-Fi.")
                }
                return "galaxy_session=\(value.value)"
            }
            sessionTask = (token, pending)
        }
        defer { if sessionTask?.0 == token { sessionTask = nil } }
        let value: String
        do { value = try await pending.value }
        catch {
            onDiagnostic?("LAN session failed: \(Self.failureCode(error)); cancelled=\(Task.isCancelled); superseded=\(original != generation)")
            throw error
        }
        try Task.checkCancellation()
        guard original == generation, self.endpoint == endpoint else { throw CancellationError() }
        cookie = value
        return value
    }

    private func authenticated(path: String, method: String, headers: [String: String], body: Data,
                               limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let endpoint else { throw URLError(.notConnectedToInternet) }
        let original = generation
        for attempt in 0...1 {
            let usedCookie = try await sessionCookie(endpoint: endpoint, generation: original)
            guard original == generation else { throw CancellationError() }
            var request = URLRequest(url: URL(string: endpoint.absoluteString + path)!)
            request.httpMethod = method
            request.httpBody = body.isEmpty ? nil : body
            request.timeoutInterval = LocalRequest.isPackageUpload(method: method, target: path) ? LocalRequest.packageUploadTimeout
                : (method == "POST" && path == LANPairing.windowPath ? 35 : method == "POST" && path == "/api/navigation/action" ? 25 : 8)
            for (name, value) in headers where ["accept", "range", "content-type"].contains(name.lowercased()) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            request.setValue(usedCookie, forHTTPHeaderField: "Cookie")
            if !["GET", "HEAD"].contains(method) {
                request.setValue(endpoint.absoluteString, forHTTPHeaderField: "Origin")
                request.setValue(LocalRequest.isPackageUpload(method: method, target: path) ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result: (Data, HTTPURLResponse)
            do { result = try await load(request, limit) }
            catch {
                onDiagnostic?("LAN request \(method) \(SecretGoodGalaxy.diagnosticPath(path)) failed; elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started))s; session changed=\(original != generation); \(Self.failureCode(error))")
                throw error
            }
            try Task.checkCancellation()
            guard original == generation, self.endpoint == endpoint else { throw CancellationError() }
            let message = (try? JSONSerialization.jsonObject(with: result.0)) as? [String: Any]
            if attempt == 0, result.1.statusCode == 401,
               message?["error"] as? String == "Refresh the local Galaxy session" {
                // The server rejected this operation before execution. Retry only this explicit response.
                onDiagnostic?("LAN session: explicit refresh rejection; retrying once; method=\(method); path=\(SecretGoodGalaxy.diagnosticPath(path))")
                if cookie == usedCookie { cookie = nil }
                continue
            }
            return result
        }
        throw BridgeError.message("Galaxy session expired. Reconnect to comma.")
    }

    func carPlayLiveRequest() async throws -> URLRequest {
        guard connected, let endpoint else { throw URLError(.notConnectedToInternet) }
        let original = generation
        let usedCookie = try await sessionCookie(endpoint: endpoint, generation: original)
        try Task.checkCancellation()
        guard connected, generation == original, self.endpoint == endpoint else { throw CancellationError() }
        var request = URLRequest(url: endpoint.appendingPathComponent("api/companion/carplay-live"))
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = false
        request.setValue(usedCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/x-starpilot-h264", forHTTPHeaderField: "Accept")
        return request
    }

    func page(path: String) async throws -> BridgeResponse {
        guard connected else { throw URLError(.notConnectedToInternet) }
        guard SecretGoodGalaxy.validPage(path) else { throw BridgeError.message("Invalid Galaxy page request.") }
        let (data, response) = try await authenticated(path: path, method: "GET", headers: [:], body: Data(), limit: 8 * Wire.maxBody)
        return bridgeResponse(data, response)
    }

    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        guard connected else { throw URLError(.notConnectedToInternet) }
        guard SecretGoodGalaxy.validTarget(path),
              ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method), body.count <= LocalRequest.bodyLimit(method: method, target: path) else {
            throw BridgeError.message("Invalid Galaxy request.")
        }
        let (data, response) = try await authenticated(path: path, method: method, headers: headers, body: body, limit: 8 * Wire.maxBody)
        return bridgeResponse(data, response)
    }

    private func bridgeResponse(_ data: Data, _ response: HTTPURLResponse) -> BridgeResponse {
        var responseHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let name = key as? String, ["content-type", "content-range", "accept-ranges", "content-disposition"].contains(name.lowercased()) {
                responseHeaders[name.lowercased()] = String(describing: value)
            }
        }
        return BridgeResponse(id: UUID().uuidString, session: generation, counter: 0, status: response.statusCode,
                              headers: responseHeaders, body: data.base64EncodedString())
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable {
    case automatic, lan, bluetooth
    var id: String { rawValue }
    var title: String { switch self { case .automatic: "Automatic"; case .lan: "Local Wi-Fi only"; case .bluetooth: "Bluetooth only" } }
}

enum ConnectionRoute: String, CaseIterable, Identifiable, Codable {
    case lan, tunnel, bluetooth
    var id: String { rawValue }
    var title: String { switch self { case .lan: "Local Wi-Fi"; case .tunnel: "Tunnel"; case .bluetooth: "Bluetooth" } }
    static func normalized(_ values: [String]) -> [Self] {
        var result: [Self] = []
        for value in values { if let route = Self(rawValue: value), !result.contains(route) { result.append(route) } }
        return result + allCases.filter { !result.contains($0) }
    }
}

@MainActor
final class PreferredTransport: ObservableObject, GalaxyRequestTransport {
    var onDiagnostic: ((String) -> Void)?
    private var diagnosticRequest = 0
    private var diagnosticSampler = DiagnosticSuccessSampler()
    private var lastDiagnosticRoute: ConnectionRoute?
    private var diagnosticFailurePending = false
    let lan: any GalaxyRequestTransport
    let bluetooth: any GalaxyRequestTransport
    let tunnel: (any GalaxyRequestTransport)?
    var invalidateLAN: (String) -> Void
    var invalidateTunnel: (String) -> Void
    @Published var mode: ConnectionMode = .automatic
    var priority: [ConnectionRoute] = ConnectionRoute.allCases
    private var routes: [ConnectionRoute] {
        switch mode {
        case .automatic: ConnectionRoute.normalized(priority.map(\.rawValue))
        case .lan: [.lan]
        case .bluetooth: [.bluetooth]
        }
    }
    private func transport(_ route: ConnectionRoute) -> (any GalaxyRequestTransport)? {
        switch route { case .lan: lan; case .tunnel: tunnel; case .bluetooth: bluetooth }
    }
    var selectedRoute: ConnectionRoute? { routes.first { transport($0)?.connected == true } }
    var connected: Bool { selectedRoute != nil }
    var usesLAN: Bool { selectedRoute == .lan }
    private var localDelay: TimeInterval = 0.2
    var localRefreshDelay: TimeInterval? { usesLAN ? localDelay : nil }
    var usesNetwork: Bool { selectedRoute == .lan || selectedRoute == .tunnel }
    var label: String { selectedRoute?.title ?? "Reconnecting…" }
    var catalogSHA256: String? { selectedRoute.flatMap { transport($0)?.catalogSHA256 } }
    init(lan: any GalaxyRequestTransport, bluetooth: any GalaxyRequestTransport,
         tunnel: (any GalaxyRequestTransport)? = nil, invalidateTunnel: @escaping (String) -> Void = { _ in },
         invalidateLAN: @escaping (String) -> Void) {
        self.lan = lan; self.bluetooth = bluetooth; self.tunnel = tunnel
        self.invalidateLAN = invalidateLAN; self.invalidateTunnel = invalidateTunnel
    }
    func page(path: String) async throws -> BridgeResponse {
        guard let route = selectedRoute, route != .bluetooth, let chosen = transport(route) else {
            throw BridgeError.message("Connect over Local Wi-Fi or Tunnel to download Galaxy screens.")
        }
        return try await chosen.page(path: path)
    }
    private func recordDiagnostic(routineSuccess: Bool = false, _ message: @autoclosure () -> String) {
        guard let onDiagnostic,
              let sampled = diagnosticSampler.take(routineSuccess: routineSuccess, now: ProcessInfo.processInfo.systemUptime) else { return }
        onDiagnostic(message() + (sampled == 0 ? "" : "; routine successes sampled=\(sampled)"))
    }
    private var diagnosticAvailability: String {
        "available: lan=\(lan.connected), tunnel=\(tunnel?.connected ?? false), bluetooth=\(bluetooth.connected)"
    }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        var lastError: Error = URLError(.notConnectedToInternet)
        diagnosticRequest += 1
        let requestID = diagnosticRequest
        for route in routes {
            if Task.isCancelled {
                diagnosticFailurePending = true
                recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) cancelled before dispatch; mode=\(mode.rawValue)")
            }
            try Task.checkCancellation()
            guard let chosen = transport(route), chosen.connected else { continue }
            if route == .bluetooth && SecretGoodGalaxy.needsWiFi(path) {
                diagnosticFailurePending = true
                recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) blocked: network-required; route=bluetooth; HTTP 501")
                return BridgeResponse(id: UUID().uuidString, session: "network-required", counter: 0, status: 501,
                    headers: ["content-type": "application/json"],
                    body: Data("{\"error\":\"Connect over Local Wi-Fi or Tunnel to use this feature.\"}".utf8).base64EncodedString())
            }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let response = try await chosen.request(path: path, method: method, headers: headers, body: body)
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                if route == .lan {
                    let target = response.status >= 400 ? 2.0 : min(2, max(0.2, elapsed * 2))
                    // Back off immediately; recover gradually rather than oscillating.
                    localDelay = target > localDelay ? target : max(target, localDelay * 0.9)
                }
                let routine = (200..<300).contains(response.status) && elapsed < 2 && !Task.isCancelled
                    && lastDiagnosticRoute == route && !diagnosticFailurePending
                    && (["GET", "HEAD"].contains(method) || (method == "POST" && path == "/api/companion/location"))
                lastDiagnosticRoute = route
                diagnosticFailurePending = response.status >= 400
                recordDiagnostic(routineSuccess: routine, "Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) completed over \(route.rawValue): HTTP \(response.status); \(SecretGoodGalaxy.responseDiagnostic(status: response.status, encodedBody: response.body)); elapsed=\(String(format: "%.3f", elapsed))s; mode=\(mode.rawValue); selected now=\(label); upload bytes=\(body.count); cancelled=\(Task.isCancelled)\(response.status >= 400 ? "; " + diagnosticAvailability : "")")
                return response
            }
            catch {
                let elapsed = ProcessInfo.processInfo.systemUptime - started
                lastDiagnosticRoute = route
                diagnosticFailurePending = true
                recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) failed over \(route.rawValue); elapsed=\(String(format: "%.3f", elapsed))s; mode=\(mode.rawValue); \(diagnosticAvailability); cancelled=\(Task.isCancelled); \(LANTransport.failureCode(error))")
                if route == .lan { localDelay = 2 }
                try Task.checkCancellation()
                guard error is URLError, route != .bluetooth else { throw error }
                if route == .lan { invalidateLAN("LAN request failed: " + LANTransport.failureCode(error)) }
                else { invalidateTunnel("Tunnel request failed: " + LANTransport.failureCode(error)) }
                // An uncertain write must never be replayed on another connection.
                guard ["GET", "HEAD"].contains(method) else {
                    recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) uncertain write: replay blocked")
                    throw BridgeError.message("Connection interrupted. This change may have saved; reload to confirm before trying again.")
                }
                lastError = error
                recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) read fallback: checking remaining routes")
            }
        }
        diagnosticFailurePending = true
        recordDiagnostic("Request #\(requestID) \(method) \(SecretGoodGalaxy.diagnosticPath(path)) exhausted available routes; mode=\(mode.rawValue); \(diagnosticAvailability)")
        throw lastError
    }
}

/// The gateway owns login. Only its session cookie is retained; never the password.
struct TunnelCredential: Codable {
    let url: String
    let cookie: String
    let deviceID: String
}
enum TunnelKeyStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "link.galaxy.tunnel", kSecAttrAccount as String: "comma"] }
    static func load() -> TunnelCredential? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(TunnelCredential.self, from: data)
    }
    static func save(_ value: TunnelCredential) throws {
        let data = try JSONEncoder().encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw BridgeError.message("Could not save Tunnel login.") }
        } else if status != errSecSuccess { throw BridgeError.message("Could not save Tunnel login.") }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}

@MainActor
final class TunnelTransport: ObservableObject, GalaxyRequestTransport {
    @Published private(set) var loginRequired = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Not configured"
    private(set) var generation = UUID().uuidString
    private(set) var credential: TunnelCredential?
    var expectedDeviceID: String?
    var onEvent: ((String) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    private var probeNumber = 0
    private var runtimePath = "/api/companion/runtime"
    private var lastProbeDetail = "Not attempted"
    private var lastFailureComparison = -Double.infinity
    var diagnosticSummary: String {
        "configured=\(credential != nil); expected identity saved=\(expectedDeviceID != nil); credential identity saved=\(!(credential?.deviceID.isEmpty ?? true)); preferred runtime path=\(runtimePath); last probe=\(lastProbeDetail)"
    }
    private let load: (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    init(load: @escaping (URLRequest, Int) async throws -> (Data, HTTPURLResponse) = { try await BoundedHTTP.load($0, limit: $1) }) { self.load = load }
    static func endpoint(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host == "galaxy.firestar.link", url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.range(of: "^/[A-Za-z0-9]{16}/?$", options: .regularExpression) != nil else { return nil }
        return URL(string: "https://galaxy.firestar.link/" + url.path.split(separator: "/")[0])
    }
    /// Match the cookie to this comma's API path, not just the shared gateway host.
    static func loginCookie(_ cookies: [HTTPCookie], url: URL, now: Date = Date()) -> HTTPCookie? {
        guard let endpoint = endpoint(url.absoluteString) else { return nil }
        let requestPath = endpoint.path + "/api/companion/runtime"
        return cookies.filter { cookie in
            guard cookie.name == "galaxy_session", cookie.isSecure, !cookie.value.isEmpty,
                  cookie.domain == "galaxy.firestar.link" || cookie.domain == ".galaxy.firestar.link",
                  cookie.expiresDate.map({ $0 > now }) ?? true else { return false }
            let path = cookie.path
            return requestPath == path || (requestPath.hasPrefix(path) &&
                (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
        }.sorted { $0.path.count > $1.path.count }.first
    }
    func configure(_ value: TunnelCredential) throws {
        guard Self.endpoint(value.url) != nil, !value.cookie.isEmpty, value.cookie.utf8.count <= 4096,
              value.cookie.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 59 }) else {
            throw BridgeError.message("Invalid Galaxy tunnel login.")
        }
        loginRequired = false
        credential = value; invalidate("Tunnel configured")
    }
    func invalidate(_ reason: String) { connected = false; generation = UUID().uuidString; status = reason; onEvent?(reason) }
    func forget() { credential = nil; loginRequired = false; invalidate("Not configured") }
    private static func requiresLogin(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 401 { return true }
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let source = response.url,
              let location = response.value(forHTTPHeaderField: "Location"),
              let target = URL(string: location, relativeTo: source)?.absoluteURL,
              target.scheme == "https", target.host == source.host, target.port == source.port,
              let slug = source.pathComponents.dropFirst().first else { return false }
        return ["/login", "/\(slug)/login"].contains(target.path)
    }
    func probe() async -> Bool {
        guard let credential else { return false }
        let original = generation
        probeNumber += 1
        let attempt = probeNumber, started = ProcessInfo.processInfo.systemUptime
        onDiagnostic?("Tunnel probe \(attempt) started; previously verified=\(connected)")
        defer {
            onDiagnostic?("Tunnel probe \(attempt) finished; elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s; cancelled=\(Task.isCancelled); session changed=\(original != generation); verified=\(connected)")
        }
        do {
            var path = runtimePath
            var (data, response) = try await send(path: path, method: "GET", headers: [:], body: Data(), limit: 4096)
            guard !Task.isCancelled, generation == original else { return false }
            lastProbeDetail = Self.probeDetail(path, data, response)
            onDiagnostic?("Tunnel probe \(attempt): \(lastProbeDetail)")
            // Some gateways route static /data paths to HTML; older comma builds lack the API alias.
            // Only retry a read. Never treat HTML or an arbitrary HTTP 200 as device verification.
            if response.statusCode == 404 || (response.statusCode == 200 && LANTransport.deviceID(data) == nil) {
                path = path == "/api/companion/runtime" ? "/data/runtime.json" : "/api/companion/runtime"
                onDiagnostic?("Tunnel probe \(attempt): trying compatible runtime endpoint \(path)")
                (data, response) = try await send(path: path, method: "GET", headers: [:], body: Data(), limit: 4096)
                guard !Task.isCancelled, generation == original else { return false }
                lastProbeDetail = Self.probeDetail(path, data, response)
                onDiagnostic?("Tunnel probe \(attempt): \(lastProbeDetail)")
            }
            // Diagnostic reads never verify a connection or replace the primary response.
            // Rate-limit during outages and retain cancellation/session boundaries.
            if (500...599).contains(response.statusCode), onDiagnostic != nil,
               ProcessInfo.processInfo.systemUptime - lastFailureComparison >= 120 {
                lastFailureComparison = ProcessInfo.processInfo.systemUptime
                for diagnosticPath in [path == "/api/companion/runtime" ? "/data/runtime.json" : "/api/companion/runtime", "/api/auth/session"] {
                    do {
                        let (sample, reply) = try await send(path: diagnosticPath, method: "GET", headers: [:], body: Data(), limit: 4096)
                        guard !Task.isCancelled, generation == original else { return false }
                        onDiagnostic?("Tunnel failure comparison: \(Self.probeDetail(diagnosticPath, sample, reply))")
                        if diagnosticPath == "/api/auth/session", reply.statusCode == 200,
                           let json = try? JSONSerialization.jsonObject(with: sample) as? [String: Any],
                           let authenticated = json["authenticated"] as? Bool {
                            onDiagnostic?("Tunnel session comparison: authenticated=\(authenticated); gatewayAccess=\(json["gatewayAccess"] as? Bool == true)")
                        }
                    } catch {
                        guard !Task.isCancelled, generation == original else { return false }
                        onDiagnostic?("Tunnel failure comparison \(diagnosticPath): \(LANTransport.failureCode(error))")
                    }
                }
            }
            let persistent = LANTransport.persistentIdentity(url: Self.endpoint(credential.url)!)
            let savedCredentialMatches = !credential.deviceID.hasPrefix("galaxy:") || credential.deviceID == persistent
            let runtime = LANTransport.deviceID(data)
            let savedDeviceMatches = runtime.map { LANTransport.matches(expectedDeviceID, runtime: $0, persistent: persistent) } ?? false
            if response.statusCode == 200 {
            onDiagnostic?("Tunnel identity check: valid runtime=\(runtime != nil); saved credential matches URL=\(savedCredentialMatches); saved comma matches=\(savedDeviceMatches); legacy identity=\(!credential.deviceID.isEmpty && !credential.deviceID.hasPrefix("galaxy:"))")
            } else {
                onDiagnostic?("Tunnel identity check skipped: server returned HTTP \(response.statusCode); saved credential matches URL=\(savedCredentialMatches)")
            }
            guard response.statusCode == 200, let runtime,
                  // The authenticated, fixed tunnel URL identifies the saved tunnel across restarts.
                  (!credential.deviceID.hasPrefix("galaxy:") || credential.deviceID == persistent),
                  (LANTransport.matches(expectedDeviceID, runtime: runtime, persistent: persistent)
                   || (expectedDeviceID == credential.deviceID && !credential.deviceID.isEmpty && !credential.deviceID.hasPrefix("galaxy:"))) else {
                let reason: String
                if Self.requiresLogin(response) {
                    loginRequired = true
                    reason = "Sign in to Tunnel again"
                }
                else if response.statusCode != 200 { reason = "Tunnel server returned HTTP \(response.statusCode)" }
                else if runtime == nil { reason = "Tunnel returned \(LANTransport.runtimeDiagnostic(data))." }
                else { reason = "Tunnel identity does not match the saved comma" }
                lastProbeDetail += "; rejected: " + reason
                invalidate(reason)
                return false
            }
            runtimePath = path
            self.credential = TunnelCredential(url: credential.url, cookie: credential.cookie, deviceID: persistent)
            expectedDeviceID = persistent
            loginRequired = false
            connected = true; status = "Tunnel verified"
            return true
        } catch {
            lastProbeDetail = "request failed: " + LANTransport.failureCode(error) + "; cancelled=\(Task.isCancelled); superseded=\(generation != original)"
            onDiagnostic?("Tunnel probe \(attempt): \(lastProbeDetail)")
            if !Task.isCancelled, generation == original { invalidate("Tunnel unavailable: " + LANTransport.failureCode(error)) }
            return false
        }
    }
    private static func probeDetail(_ path: String, _ data: Data, _ response: HTTPURLResponse) -> String {
        if response.statusCode == 200, path == "/api/auth/session" {
            return "\(path): HTTP 200; bytes=\(data.count); JSON object=\((try? JSONSerialization.jsonObject(with: data)) is [String: Any])"
        }
        if response.statusCode == 200 {
            return "\(path): \(LANTransport.responseDiagnostic(data, response))"
        }
        return "\(path): \(failureDiagnostic(data, response))"
    }
    static func failureDiagnostic(_ data: Data, _ response: HTTPURLResponse) -> String {
        // Never emit arbitrary server text, URLs, cookies or header values.
        // A digest correlates repeated unknown responses without retaining their payload.
        let fingerprint = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = ((json?["error"] as? String) ?? (json?["message"] as? String) ?? "").lowercased()
        let category: String
        if message.contains("unreachable") || message.contains("cannot be reached") || message.contains("could not be reached") { category = "upstream-unreachable" }
        else if message.contains("offline") { category = "upstream-offline" }
        else if message.contains("timed out") || message.contains("timeout") { category = "upstream-timeout" }
        else if message.contains("sign in") || message.contains("unauthorized") || message.contains("session") { category = "authentication-related" }
        else { category = "unclassified" }
        let mime = response.mimeType?.lowercased() ?? ""
        let type = mime.contains("json") ? "JSON" : mime.contains("html") ? "HTML" : "other"
        let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map { String(min(max($0, 0), 86400)) } ?? "absent-or-date"
        let ray = response.value(forHTTPHeaderField: "CF-Ray") ?? ""
        let safeRay = ray.range(of: "^[0-9a-fA-F]{16,32}-[A-Z]{3}$", options: .regularExpression) != nil ? ray : "absent-or-redacted"
        return "HTTP \(response.statusCode); bytes=\(data.count); content-type=\(type); category=\(category); body fingerprint=\(fingerprint); error field=\(json?["error"] != nil); message field=\(json?["message"] != nil); code field=\(json?["code"] != nil); retry-after seconds=\(retry); cf-ray=\(safeRay); redirect present=\(response.value(forHTTPHeaderField: "Location") != nil)"
    }
    private func send(path: String, method: String, headers: [String: String], body: Data, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let credential, let endpoint = Self.endpoint(credential.url),
              let url = URL(string: endpoint.absoluteString + path) else { throw URLError(.notConnectedToInternet) }
        let original = generation
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body.isEmpty ? nil : body
        // comma may follow short links and geocode before answering a shared place.
        request.timeoutInterval = LocalRequest.isPackageUpload(method: method, target: path) ? LocalRequest.packageUploadTimeout
            : method == "POST" && path == "/api/navigation/action" ? 25 : 8
        request.setValue("galaxy_session=" + credential.cookie, forHTTPHeaderField: "Cookie")
        for (name, value) in headers where ["accept", "range", "content-type"].contains(name.lowercased()) { request.setValue(value, forHTTPHeaderField: name) }
        if !["GET", "HEAD"].contains(method) {
            request.setValue("https://galaxy.firestar.link", forHTTPHeaderField: "Origin")
            if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }
        let started = ProcessInfo.processInfo.systemUptime
        let result: (Data, HTTPURLResponse)
        do { result = try await load(request, limit) }
        catch {
            onDiagnostic?("Tunnel request \(method) \(SecretGoodGalaxy.diagnosticPath(path)) failed; elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started))s; cancelled=\(Task.isCancelled); superseded=\(generation != original); \(LANTransport.failureCode(error))")
            throw error
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if result.1.statusCode >= 300 || elapsed >= 2 {
            onDiagnostic?("Tunnel request \(method) \(SecretGoodGalaxy.diagnosticPath(path)): HTTP \(result.1.statusCode); bytes=\(result.0.count); elapsed=\(String(format: "%.3f", elapsed))s; superseded=\(generation != original)")
        }
        try Task.checkCancellation()
        guard generation == original else { throw CancellationError() }
        return result
    }
    private func perform(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        guard connected else { throw URLError(.notConnectedToInternet) }
        let (data, response) = try await send(path: path, method: method, headers: headers, body: body, limit: 8 * Wire.maxBody)
        if Self.requiresLogin(response) {
            loginRequired = true
            invalidate("Sign in to Tunnel again")
            throw URLError(.userAuthenticationRequired)
        }
        if (300..<400).contains(response.statusCode) {
            invalidate("Unexpected Tunnel response (HTTP \(response.statusCode))")
            throw URLError(.badServerResponse)
        }
        var filtered: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, ["content-type", "content-range", "accept-ranges", "content-disposition"].contains(key.lowercased()) { filtered[key.lowercased()] = String(describing: value) }
        }
        return BridgeResponse(id: UUID().uuidString, session: generation, counter: 0, status: response.statusCode, headers: filtered, body: data.base64EncodedString())
    }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        guard SecretGoodGalaxy.validTarget(path), ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(method),
              body.count <= LocalRequest.bodyLimit(method: method, target: path) else { throw BridgeError.message("Invalid Galaxy request.") }
        return try await perform(path: path, method: method, headers: headers, body: body)
    }
    func page(path: String) async throws -> BridgeResponse {
        guard SecretGoodGalaxy.validPage(path) else { throw BridgeError.message("Invalid Galaxy page request.") }
        return try await perform(path: path, method: "GET", headers: [:], body: Data())
    }
}

@MainActor
enum LANDiscoveryMatch {
    static func first(addresses: [String], expectedDeviceID: String?, stillCurrent: () -> Bool,
                      probe: (String, String) async -> Bool) async -> String? {
        guard let identity = expectedDeviceID, !identity.isEmpty else { return nil }
        var seen = Set<String>()
        for address in addresses.prefix(16) {
            guard !Task.isCancelled, stillCurrent() else { return nil }
            guard seen.insert(address).inserted, (try? LANTransport.endpoint(address)) != nil else { continue }
            let verified = await probe(address, identity)
            guard !Task.isCancelled, stillCurrent() else { return nil }
            if verified { return address }
        }
        return nil
    }
}
