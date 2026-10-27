import Foundation

@MainActor final class RouteStub: GalaxyRequestTransport {
    var connected = true
    var fail = false
    var status = 200
    var calls = 0
    let name: String
    init(_ name: String) { self.name = name }
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        calls += 1
        if fail { throw URLError(.networkConnectionLost) }
        return BridgeResponse(id: "test", session: name, counter: 0, status: status, headers: [:], body: "")
    }
}
@MainActor final class TunnelServer {
    var identity = "0123456789abcdef"
    var status = 200
    var requests: [URLRequest] = []
    func load(_ request: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "monitor": "local", "instance": identity])
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}
@main struct TunnelRegression {
    @MainActor static func main() async throws {
        let url = "https://galaxy.firestar.link/abcdefghijklmnop"
        precondition(TunnelTransport.endpoint(url + "/")?.absoluteString == url)
        for bad in ["http://galaxy.firestar.link/abcdefghijklmnop", "https://evil.test/abcdefghijklmnop", url + "?cookie=x", url + "/api", "https://user@galaxy.firestar.link/abcdefghijklmnop", "https://galaxy.firestar.link:443/abcdefghijklmnop"] {
            precondition(TunnelTransport.endpoint(bad) == nil)
        }
        precondition(ConnectionRoute.normalized(["bluetooth", "bluetooth", "unknown"]) == [.bluetooth, .lan, .tunnel])
        let server = TunnelServer(), tunnel = TunnelTransport(load: { request, limit in try await server.load(request, limit) })
        try tunnel.configure(TunnelCredential(url: url, cookie: "opaque-token", deviceID: server.identity))
        tunnel.expectedDeviceID = server.identity
        let verified = await tunnel.probe(); precondition(verified)
        _ = try await tunnel.request(path: "/api/settings/confirm", method: "POST", headers: ["Authorization": "must-not-forward", "Cookie": "attacker"], body: Data("{}".utf8))
        let request = server.requests.last!
        precondition(request.url!.absoluteString == url + "/api/settings/confirm")
        precondition(request.value(forHTTPHeaderField: "Origin") == "https://galaxy.firestar.link")
        precondition(request.value(forHTTPHeaderField: "Cookie") == "galaxy_session=opaque-token")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        server.identity = "fedcba9876543210"
        let restarted = await tunnel.probe(); precondition(restarted, "Saved authenticated tunnel survives a Galaxy restart")
        tunnel.expectedDeviceID = "galaxy:another-comma"
        let wrong = await tunnel.probe(); precondition(!wrong && !tunnel.connected, "Never fall back to another comma’s tunnel")
        tunnel.expectedDeviceID = LANTransport.persistentIdentity(url: URL(string: url)!)
        server.identity = "0123456789abcdef"
        _ = await tunnel.probe()
        server.status = 302
        do { _ = try await tunnel.request(path: "/api/settings/pages/hub", method: "GET", headers: [:], body: Data()); preconditionFailure() } catch is URLError {}
        precondition(!tunnel.connected)
        for cookie in ["bad\r\nCookie:x", "bad;other=x", ""] {
            do { try tunnel.configure(TunnelCredential(url: url, cookie: cookie, deviceID: "")); preconditionFailure() } catch {}
        }
        let wifi = RouteStub("wifi"), remote = RouteStub("tunnel"), ble = RouteStub("ble")
        let preferred = PreferredTransport(lan: wifi, bluetooth: ble, tunnel: remote,
            invalidateTunnel: { _ in remote.connected = false }, invalidateLAN: { _ in wifi.connected = false })
        precondition(preferred.label == "Local Wi-Fi")
        precondition(preferred.localRefreshDelay == 0.2)
        wifi.status = 503
        _ = try await preferred.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(preferred.localRefreshDelay == 2)
        wifi.status = 200
        _ = try await preferred.request(path: "/api/system/monitor", method: "GET", headers: [:], body: Data())
        precondition(preferred.localRefreshDelay == 1.8)
        preferred.priority = [.tunnel, .bluetooth, .lan]
        precondition(preferred.label == "Tunnel")
        precondition(preferred.localRefreshDelay == nil)
        remote.fail = true
        let fallback = try await preferred.request(path: "/api/settings/pages/hub", method: "GET", headers: [:], body: Data())
        precondition(fallback.session == "ble" && ble.connected && wifi.connected)
        remote.connected = true
        let before = ble.calls
        do { _ = try await preferred.request(path: "/api/settings/confirm", method: "POST", headers: [:], body: Data("{}".utf8)); preconditionFailure() } catch {}
        precondition(ble.calls == before, "Never replay uncertain writes")
        preferred.mode = .lan
        precondition(preferred.label == "Local Wi-Fi")
        preferred.mode = .bluetooth
        precondition(preferred.label == "Bluetooth")
        precondition(preferred.localRefreshDelay == nil)
        print("Tunnel identity/auth, origin and cookie isolation, priority, fallback and no-write-replay checks passed")
    }
}
