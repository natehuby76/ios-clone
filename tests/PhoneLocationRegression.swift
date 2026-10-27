import CoreLocation
import Foundation

struct BridgeResponse { let status: Int; let bodyData: Data }
enum Wire { static let maxBody = 1_048_576 }
enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor final class RecordingComma: GalaxyRequestTransport {
    var connected = true
    var localRefreshDelay: TimeInterval?
    var bodies: [[String: Any]] = []
    var pauseNext = false
    var release: CheckedContinuation<Void, Never>?
    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        precondition(path == PhoneLocation.path && method == "POST" && headers["Content-Type"] == "application/json")
        bodies.append(try JSONSerialization.jsonObject(with: body) as! [String: Any])
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { release = $0 }
        }
        return BridgeResponse(status: 200, bodyData: Data("{\"ok\":true}".utf8))
    }
}

func fix(at time: Date, course: Double = 90, courseAccuracy: Double = 10, speed: Double = 20, vertical: Double = 4) -> CLLocation {
    CLLocation(coordinate: CLLocationCoordinate2D(latitude: 40, longitude: -110), altitude: 1200, horizontalAccuracy: 5,
               verticalAccuracy: vertical, course: course, courseAccuracy: courseAccuracy, speed: speed, speedAccuracy: -1, timestamp: time)
}

@main
struct PhoneLocationRegression {
    @MainActor static func main() async {
        let now = Date()
        let known = try! JSONSerialization.jsonObject(with: PhoneLocation.payload(fix(at: now.addingTimeInterval(-0.3)), now: now)!) as! [String: Any]
        precondition(known["ageMs"] as? Int == 300 && known["bearing"] as? Double == 90 && known["speedAccuracy"] == nil)

        let queued = try! PhoneGpsDelivery.body(PhoneLocation.payload(fix(at: now.addingTimeInterval(-0.3)), now: now)!,
                                                path: PhoneLocation.path, queuedSeconds: 1.2)
        let dated = try! JSONSerialization.jsonObject(with: queued) as! [String: Any]
        precondition(abs((dated["ageMs"] as! Double) - 1500) < 1)
        precondition((try? PhoneGpsDelivery.body(queued, path: PhoneLocation.path, queuedSeconds: 1)) == nil)
        let other = Data("unchanged".utf8)
        precondition((try! PhoneGpsDelivery.body(other, path: "/api/settings/action", queuedSeconds: 90)) == other)

        // iOS reports unknown values as negative numbers; they are left out.
        let unknown = try! JSONSerialization.jsonObject(with: PhoneLocation.payload(fix(at: now, courseAccuracy: -1, speed: -1, vertical: -1), now: now)!) as! [String: Any]
        precondition(unknown["bearing"] == nil && unknown["speed"] == nil && unknown["altitude"] == nil)
        precondition(PhoneLocation.payload(fix(at: now.addingTimeInterval(-3)), now: now) == nil)

        UserDefaults.standard.set(true, forKey: "galaxy.phoneGps")
        let comma = RecordingComma()
        let sharing = PhoneLocation(transport: { comma }, manager: nil)
        await sharing.deliver(fix(at: now), now: now)
        await sharing.deliver(fix(at: now.addingTimeInterval(0.5)), now: now.addingTimeInterval(0.5))
        precondition(comma.bodies.count == 1 && sharing.status == "Sharing GPS with comma")
        await sharing.deliver(fix(at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        precondition(comma.bodies.count == 2)

        comma.connected = false
        await sharing.deliver(fix(at: now.addingTimeInterval(2)), now: now.addingTimeInterval(2))
        precondition(comma.bodies.count == 2 && sharing.status == "Waiting for comma")
        sharing.setSharing(false)
        comma.connected = true
        await sharing.deliver(fix(at: now.addingTimeInterval(3)), now: now.addingTimeInterval(3))
        precondition(comma.bodies.count == 2)
        // While one request waits, coalesce callbacks to the newest position.
        UserDefaults.standard.set(true, forKey: "galaxy.phoneGps")
        let delayed = RecordingComma()
        delayed.pauseNext = true
        let stream = PhoneLocation(transport: { delayed }, manager: nil)
        let initial = Date().addingTimeInterval(-1)
        let first = Task { await stream.deliver(fix(at: initial), now: initial) }
        while delayed.release == nil { await Task.yield() }
        await stream.deliver(fix(at: Date(), course: 180))
        await stream.deliver(fix(at: Date(), course: 270))
        delayed.release?.resume()
        await first.value
        for _ in 0..<1000 {
            if delayed.bodies.count == 2 { break }
            await Task.yield()
        }
        precondition(delayed.bodies.count == 2 && delayed.bodies.last?["bearing"] as? Double == 270)
        stream.setSharing(false)
        UserDefaults.standard.set(true, forKey: "galaxy.phoneGps")
        let local = RecordingComma()
        local.localRefreshDelay = 0.2
        let wifi = PhoneLocation(transport: { local }, manager: nil)
        await wifi.deliver(fix(at: now), now: now)
        await wifi.deliver(fix(at: now.addingTimeInterval(0.1)), now: now.addingTimeInterval(0.1))
        precondition(local.bodies.count == 1)
        await wifi.deliver(fix(at: now.addingTimeInterval(0.25)), now: now.addingTimeInterval(0.25))
        precondition(local.bodies.count == 2)
        // Never dress a duplicate fix up as a faster GPS sample.
        await wifi.deliver(fix(at: now.addingTimeInterval(0.25)), now: now.addingTimeInterval(0.5))
        precondition(local.bodies.count == 2)
        local.localRefreshDelay = 2
        await wifi.deliver(fix(at: now.addingTimeInterval(0.75)), now: now.addingTimeInterval(0.75))
        precondition(local.bodies.count == 2)
        // A route switch immediately restores the existing non-LAN throttle.
        local.localRefreshDelay = nil
        await wifi.deliver(fix(at: now.addingTimeInterval(0.8)), now: now.addingTimeInterval(0.8))
        precondition(local.bodies.count == 2)
        await wifi.deliver(fix(at: now.addingTimeInterval(1.25)), now: now.addingTimeInterval(1.25))
        precondition(local.bodies.count == 3)
        wifi.setSharing(false)
        UserDefaults.standard.removeObject(forKey: "galaxy.phoneGps")
        print("phone location ok")
    }
}
