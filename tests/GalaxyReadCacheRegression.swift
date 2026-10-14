import Foundation

struct BridgeResponse { let status: Int; let bodyData: Data }
enum Wire { static let maxBody = 1_048_576 }
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
@MainActor final class FakeTransport: GalaxyRequestTransport {
    var connected = true
    var session = "first"
    var clock = 0.0
    var calls = 0
    var waiting: [Int: CheckedContinuation<BridgeResponse, Error>] = [:]
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        calls += 1
        let index = calls
        return try await withCheckedThrowingContinuation { waiting[index] = $0 }
    }
    func reply(_ index: Int) {
        waiting.removeValue(forKey: index)!.resume(returning: BridgeResponse(status: 200, bodyData: Data("reply\(index)".utf8)))
    }
    func until(_ count: Int) async {
        for _ in 0..<1000 {
            if calls >= count { return }
            await Task.yield()
        }
        preconditionFailure("Request never reached transport")
    }
}
@main struct CacheRegression {
    @MainActor static func main() async throws {
        let transport = FakeTransport()
        let cache = GalaxyReadCache(transport: transport, sessionID: { transport.session }, now: { transport.clock })
        func read(_ path: String, method: String = "GET") -> Task<BridgeResponse, Error> {
            Task { try await cache.request(path: path, method: method, headers: [:], body: Data()) }
        }
        let params = "/api/params/all?galaxy_ble_settings=1", metadata = "/api/params/defaults"
        let first = read(params)
        await transport.until(1)
        let joined = read(params)
        for _ in 0..<10 { await Task.yield() }
        precondition(transport.calls == 1, "Concurrent settings downloads were duplicated")
        transport.reply(1)
        let a = try await first.value, b = try await joined.value
        precondition(a.bodyData == b.bodyData)
        let fresh = read(params)
        await transport.until(2); transport.reply(2)
        _ = try await fresh.value
        let defaults = read(metadata)
        await transport.until(3); transport.reply(3)
        _ = try await defaults.value
        _ = try await cache.request(path: metadata, method: "GET", headers: [:], body: Data())
        precondition(transport.calls == 3, "Stable metadata downloaded again")
        transport.clock = 301
        let expired = read(metadata)
        await transport.until(4); transport.reply(4); _ = try await expired.value
        let write = read("/api/params", method: "PUT")
        await transport.until(5); transport.reply(5); _ = try await write.value
        let afterWrite = read(metadata)
        await transport.until(6); transport.reply(6); _ = try await afterWrite.value
        transport.session = "second"
        let afterReconnect = read(metadata)
        await transport.until(7); transport.reply(7); _ = try await afterReconnect.value
        let stale = read(params)
        await transport.until(8)
        let mutation = read("/api/params", method: "PUT")
        await transport.until(9)
        transport.reply(8)
        do { _ = try await stale.value; preconditionFailure("Read from before mutation was accepted") } catch {}
        transport.reply(9); _ = try await mutation.value
        let oldSession = read(params)
        await transport.until(10)
        transport.session = "third"; transport.reply(10)
        do { _ = try await oldSession.value; preconditionFailure("Old session read accepted") } catch {}
        let cancelled = read(params)
        await transport.until(11)
        let survivor = read(params)
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel(); transport.reply(11)
        do { _ = try await cancelled.value; preconditionFailure("Cancelled caller received result") } catch {}
        _ = try await survivor.value
        precondition(transport.calls == 11, "Cancellation duplicated shared request")
        print("Read cache: coalescing, fresh values, expiry, writes, reconnects and cancellation passed")
    }
}
