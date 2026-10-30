import Foundation

@MainActor final class Server {
    var calls: [URLRequest] = []
    var sessions = 0
    var expired = false
    var failWrite = false
    var corruptIdentity = false
    var tunnelURL: String?
    func load(_ request: URLRequest, _ limit: Int) async throws -> (Data, HTTPURLResponse) {
        calls.append(request)
        let path = request.url!.path
        var headers: [String: String] = [:]
        var status = 200
        var json: [String: Any] = [:]
        if path == "/api/auth/session" {
            sessions += 1
            let current = sessions
            try await Task.sleep(nanoseconds: 5_000_000)
            json = ["authenticated": true, "localAccess": true]
            headers["Set-Cookie"] = "galaxy_session=token\(current); HttpOnly; SameSite=Strict; Path=/; Max-Age=1800"
        } else {
            precondition(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("galaxy_session=token") == true)
            if path == "/data/runtime.json" {
                json = ["schemaVersion": 1, "monitor": "local", "instance": corruptIdentity ? "fedcba9876543210" : "0123456789abcdef"]
            } else if path == "/api/galaxy/status" {
                json = ["paired": tunnelURL != nil, "url": tunnelURL ?? ""]
            } else if expired {
                expired = false; status = 401; json = ["error": "Refresh the local Galaxy session"]
            } else if failWrite { throw URLError(.networkConnectionLost) }
            else { json = ["saved": true] }
        }
        return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

@main struct LANRegression {
    @MainActor static func main() async throws {
        for address in ["172.31.254.1", "172.31.254.1:8082", " http://172.31.254.1:8082/ ", "http://172.31.254.1/"] {
            let endpoint = try LANTransport.endpoint(address)
            precondition(endpoint.absoluteString == "http://172.31.254.1:8082")
        }
        for address in ["172.31.254.1:80", "https://172.31.254.1", "http://user@172.31.254.1", "172.31.254.1/path", "172.31.254.1?x=1", "8.8.8.8:8082", "127.0.0.1:8082"] {
            do { _ = try LANTransport.endpoint(address); preconditionFailure("Invalid LAN address accepted: \(address)") } catch {}
        }
        let server = Server()
        let lan = LANTransport(load: server.load)
        try lan.configure(address: "192.168.1.86")
        lan.bind(to: "0123456789abcdef")
        let verified = await lan.probe()
        precondition(verified && server.sessions == 1)
        _ = try await lan.request(path: LANPairing.windowPath, method: "POST", headers: [:], body: LANPairing.windowBody)
        precondition(server.calls.last?.timeoutInterval == 35, "Pairing must cover comma’s 25-second daemon window plus preparation")
        server.calls.removeAll()
        server.expired = true
        let result = try await lan.request(path: "/api/settings/confirm", method: "POST", headers: ["Cookie": "forged", "Origin": "http://evil.invalid"], body: Data("{}".utf8))
        precondition(result.status == 200 && server.sessions == 2)
        let writes = server.calls.filter { $0.httpMethod == "POST" }
        precondition(writes.count == 2, "Explicit session rejection must retry exactly once")
        precondition(writes.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "http://192.168.1.86:8082" && $0.value(forHTTPHeaderField: "Content-Type") == "application/json" })
        precondition(writes[0].value(forHTTPHeaderField: "Cookie") != writes[1].value(forHTTPHeaderField: "Cookie"))
        server.failWrite = true
        let before = server.calls.count
        do { _ = try await lan.request(path: "/api/settings/confirm", method: "POST", headers: [:], body: Data("{}".utf8)); preconditionFailure("Expected network error") } catch is URLError {}
        precondition(server.calls.count == before + 1, "Never retry an uncertain mutation")
        server.failWrite = false
        try lan.configure(address: "192.168.1.87")
        precondition(!lan.connected)
        _ = await lan.probe()
        precondition(server.sessions == 3, "A different comma must get a separate session")
        server.corruptIdentity = true
        let mismatched = await lan.probe()
        precondition(!mismatched, "Reject LAN endpoint that differs from authenticated BLE identity")
        server.corruptIdentity = false
        server.tunnelURL = "https://galaxy.firestar.link/abcdefghijklmnop"
        let migrated = await lan.probe()
        precondition(migrated && lan.expectedDeviceID?.hasPrefix("galaxy:") == true, "Verified legacy runtime upgrades to a persistent pin")
        server.corruptIdentity = true
        let restarted = await lan.probe()
        precondition(restarted, "Same comma remains connected after Galaxy restarts")
        let saved = lan.expectedDeviceID
        server.tunnelURL = "https://galaxy.firestar.link/ponmlkjihgfedcba"
        let different = await lan.probe()
        precondition(!different && lan.expectedDeviceID == saved, "Another comma at the same IP must not replace the selected comma")
        server.tunnelURL = nil
        let missing = await lan.probe()
        precondition(!missing, "Missing stable identity must not downgrade a saved pin to runtime matching")
        server.tunnelURL = "https://galaxy.firestar.link/abcdefghijklmnop"
        let returned = await lan.probe()
        precondition(returned, "The selected comma reconnects after another device was rejected")
        precondition(SecretGoodGalaxy.diagnosticPath("/api/navigation/status?secret=hidden") == "/api/navigation/status")
        precondition(SecretGoodGalaxy.diagnosticPath("/api/auth/private-token") == "/api/auth/…")
        precondition(SecretGoodGalaxy.diagnosticPath("/api/private-token") == "[other path]")
        precondition(SecretGoodGalaxy.diagnosticPath("https://private.invalid/token") == "[other path]")
        let framedError = URLError(.timedOut, userInfo: ["StarPilotLANContext": "phase=receiving; received=120"])
        precondition(LANTransport.failureCode(framedError).contains("phase=receiving; received=120"))
        for invalid in ["http://evil.invalid/api/x", "//evil.invalid/api/x", "/api/../x", "/api/%2e%2e/x", "/api/%252e/x", "/api/x#fragment", "/data/system-monitor.sample.json"] {
            precondition(!SecretGoodGalaxy.validTarget(invalid), invalid)
        }
        precondition(SecretGoodGalaxy.validTarget("/api/settings/pages/hub"))
        precondition(SecretGoodGalaxy.validTarget("/data/runtime.json"))
        for invalid in ["/api/params", "/js/../x.js", "/js/a b.js", "/js/app.js?x=1", "/data/runtime.json", "/other/x.js", "//evil/js/a.js", "/js//a.js", "js/app.js", "/js/%2e%2e/a.js"] {
            precondition(!SecretGoodGalaxy.validPage(invalid), invalid)
        }
        for valid in ["/index.html", "/js/app.js", "/vendor/vue/vue.esm-browser.js", "/data/catalog.json", "/manifest.webmanifest"] {
            precondition(SecretGoodGalaxy.validPage(valid), valid)
        }
        server.corruptIdentity = false
        _ = await lan.probe()
        let pageCalls = server.calls.count
        let page = try await lan.page(path: "/js/app.js")
        precondition(page.status == 200 && server.calls.count == pageCalls + 1)
        precondition(server.calls.last!.httpMethod == "GET" && server.calls.last!.url!.path == "/js/app.js")
        do { _ = try await lan.page(path: "/api/params"); preconditionFailure("Pages are not API calls") } catch is BridgeError {}
        precondition(SecretGoodGalaxy.needsWiFi("/api/cameras/snapshot"))
        precondition(!SecretGoodGalaxy.needsWiFi("/api/settings/pages/hub"))
        let concurrent = Server()
        let shared = LANTransport(load: concurrent.load)
        try shared.configure(address: "192.168.1.88")
        async let first = shared.probe()
        async let second = shared.probe()
        _ = await (first, second)
        precondition(concurrent.sessions == 1, "Share concurrent session handshakes")
        let uploadServer = Server()
        let uploader = LANTransport(load: uploadServer.load)
        try uploader.configure(address: "192.168.1.89")
        _ = await uploader.probe()
        let package = Data(repeating: 0x5a, count: 48 * 1024 * 1024)
        let header = Data("POST /api/android-auto/upload HTTP/1.1\r\nContent-Length: \(package.count)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        let partial = try LocalRequest.parse(header)
        precondition(partial == nil)
        let parsed = try LocalRequest.parse(header + package)
        precondition(parsed?.body == package)
        _ = try await uploader.request(path: "/api/android-auto/upload", method: "POST", headers: ["content-type": "application/octet-stream"], body: package)
        let uploaded = uploadServer.calls.last!
        precondition(uploaded.httpBody == package)
        precondition(uploaded.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
        precondition(uploaded.value(forHTTPHeaderField: "Origin") == "http://192.168.1.89:8082")
        precondition(uploaded.timeoutInterval == LocalRequest.packageUploadTimeout)
        let starportHeader = Data("POST /api/starport/upload HTTP/1.1\r\nContent-Length: \(package.count)\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        let starportParsed = try LocalRequest.parse(starportHeader + package)
        precondition(starportParsed?.body == package)
        precondition(SecretGoodGalaxy.needsWiFi("/api/starport/upload"))
        for target in ["/api/settings/confirm", "/api/android-auto/upload/extra", "/api/android-auto/upload?x=1"] {
            let oversized = Data("POST \(target) HTTP/1.1\r\nContent-Length: 50331648\r\n\r\n".utf8)
            do { _ = try LocalRequest.parse(oversized); preconditionFailure("Ordinary requests must remain bounded") } catch {}
        }
        let tooLarge = Data("POST /api/android-auto/upload HTTP/1.1\r\nContent-Length: 268435457\r\n\r\n".utf8)
        do { _ = try LocalRequest.parse(tooLarge); preconditionFailure("Package limit must hold") } catch {}
        let discoveryServer = Server()
        var probed: [String] = []
        let discovered = await LANDiscoveryMatch.first(addresses: ["192.168.1.90", "192.168.1.90", "192.168.1.91"],
                                                       expectedDeviceID: "0123456789abcdef", stillCurrent: { true }) { address, identity in
            probed.append(address)
            discoveryServer.corruptIdentity = address.hasSuffix("90")
            let candidate = LANTransport(load: discoveryServer.load)
            candidate.bind(to: identity)
            try! candidate.configure(address: address)
            let verified = await candidate.probe()
            precondition(candidate.verifiedDeviceID == (verified ? identity : nil))
            return verified
        }
        precondition(discovered == "192.168.1.91" && probed == ["192.168.1.90", "192.168.1.91"], "Try alternate interfaces, never select a different comma")
        let unknown = await LANDiscoveryMatch.first(addresses: ["192.168.1.91"], expectedDeviceID: nil, stillCurrent: { true }) { _, _ in
            preconditionFailure("First-time discovery requires an explicit choice")
        }
        precondition(unknown == nil)
        var sameNetwork = true
        let stale = await LANDiscoveryMatch.first(addresses: ["192.168.1.91"], expectedDeviceID: "0123456789abcdef", stillCurrent: { sameNetwork }) { _, _ in
            await Task.yield()
            sameNetwork = false
            return true
        }
        precondition(stale == nil, "Reject verification completed after the network or selected comma changes")
        print("SecretGood LAN: cookies, refresh, mutation safety, identity and isolation passed")
    }
}
