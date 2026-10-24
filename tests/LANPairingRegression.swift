import Foundation

@MainActor final class FakeLAN: GalaxyRequestTransport {
    var connected = true
    var replies: [(Int, String)] = []
    var requests: [(path: String, method: String, body: Data)] = []
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        requests.append((path, method, body))
        let (status, json) = replies.removeFirst()
        if status == -1 { throw URLError(.timedOut) }
        return BridgeResponse(id: "", session: "", counter: 0, status: status, headers: [:], body: Data(json.utf8).base64EncodedString())
    }
}

@main struct LANPairingRegression {
    @MainActor static func main() async throws {
        let lan = FakeLAN()
        let ready = (200, "{\"schema\":1,\"ready\":true}")
        let starting = (200, "{\"schema\":1,\"ready\":false,\"code\":\"starting\"}")
        let busy = (409, "{\"code\":\"busy\"}")
        var waits: [UInt64] = []
        lan.replies = [starting, ready, busy, (200, "{}")]
        let opened = try await LANPairing.openWindow(over: lan, pause: { waits.append($0) })
        precondition(opened && waits == [3_000_000_000, 2_500_000_000])
        let posts = lan.requests.filter { $0.method == "POST" }
        precondition(posts.count == 2 && posts.allSatisfy { $0.path == LANPairing.windowPath && $0.body == LANPairing.windowBody })
        precondition(SecretGoodGalaxy.validTarget(LANPairing.windowPath))
        // Older comma: no readiness endpoint, but the pairing window can still open.
        lan.replies = [(404, "{}"), (200, "{}")]
        let legacy = try await LANPairing.openWindow(over: lan)
        precondition(legacy)
        for replies in [[ready, (409, "{\"code\":\"park_required\"}")],
                        [ready, busy, busy, busy, busy], [ready, (-1, "")],
                        [(200, "{\"schema\":1,\"ready\":false,\"code\":\"park_required\"}")],
                        Array(repeating: starting, count: 16)] {
            lan.replies = replies
            do {
                _ = try await LANPairing.openWindow(over: lan, pause: { _ in })
                preconditionFailure("A failed window or blocked readiness must stop the claim")
            } catch {}
            precondition(lan.replies.isEmpty, "Retry only explicit busy, and bound startup waits")
        }
        lan.replies = [ready, busy]
        do {
            _ = try await LANPairing.openWindow(over: lan, pause: { _ in throw CancellationError() })
            preconditionFailure("Cancellation must stop preparation")
        } catch is CancellationError {}
        lan.connected = false; lan.requests = []
        let disconnected = try await LANPairing.openWindow(over: lan)
        precondition(!disconnected && lan.requests.isEmpty)
        print("LAN pairing: readiness, legacy fallback, busy retries, refusal, timeout and cancellation passed")
    }
}

