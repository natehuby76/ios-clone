import CoreLocation
import Foundation

/// Shares fresh fixes up to 5 Hz on Local Wi-Fi, retaining the existing cadence on other routes.
/// Galaxy's navigation GPS source setting controls whether comma prefers this phone or uses it as backup.
@MainActor
final class PhoneLocation: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    static let path = "/api/companion/location"
    nonisolated static let maxAgeMs = 2000.0

    @Published private(set) var sharing = UserDefaults.standard.bool(forKey: "galaxy.phoneGps")
    @Published private(set) var status = ""
    var onEvent: ((String) -> Void)?
    private var offered = 0
    private var skipped = 0
    private var accepted = 0
    private var failed = 0
    var diagnosticSummary: String { "offered=\(offered); skipped=\(skipped); accepted=\(accepted); failed=\(failed); in flight=\(sending); permission=\(manager?.authorizationStatus.rawValue ?? -1); upload interval=\(transport()?.localRefreshDelay ?? 0.9)s" }
    var onSharingChanged: ((Bool) -> Void)?
    private let transport: () -> (any GalaxyRequestTransport)?
    private let manager: CLLocationManager?
    private var sending = false
    private var pending: CLLocation?
    private var lastSent = Date.distantPast
    private var lastLocalFix = Date.distantPast

    init(transport: @escaping () -> (any GalaxyRequestTransport)?, manager: CLLocationManager? = CLLocationManager()) {
        self.transport = transport
        self.manager = manager
        super.init()
        guard let manager else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        #if os(iOS)
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        #endif
        if sharing { begin() }
    }

    func setSharing(_ value: Bool) {
        guard value != sharing else { return }
        onEvent?("Sharing changed: \(value)")
        sharing = value
        UserDefaults.standard.set(value, forKey: "galaxy.phoneGps")
        if value { begin() } else { manager?.stopUpdatingLocation(); status = "" }
        onSharingChanged?(value)
    }

    private func begin() {
        guard let manager else { return }
        switch manager.authorizationStatus {
        case .notDetermined: status = "Allow location to share GPS."; manager.requestWhenInUseAuthorization()
        case .denied, .restricted: status = "Location is off for this app. Turn it on in iPhone Settings."
        default:
            #if os(iOS)
            manager.allowsBackgroundLocationUpdates = true
            #endif
            status = "Waiting for GPS"
            manager.startUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onEvent?("Authorization changed: \(manager.authorizationStatus.rawValue)")
        if sharing { begin() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { await deliver(location) }
    }

    /// One upload at a time; newer callbacks replace pending fixes instead of building a queue.
    func deliver(_ location: CLLocation, now: Date = Date()) async {
        offered += 1
        guard sharing else { skipped += 1; return }
        if sending { pending = location; skipped += 1; return }
        let currentTransport = transport()
        let localDelay = currentTransport?.localRefreshDelay
        guard now.timeIntervalSince(lastSent) >= (localDelay ?? 0.9) else { skipped += 1; return }
        if localDelay != nil, location.timestamp <= lastLocalFix { skipped += 1; return }
        guard let body = Self.payload(location, now: now) else { skipped += 1; onEvent?("Fix rejected: age=\(now.timeIntervalSince(location.timestamp)); accuracy=\(location.horizontalAccuracy)"); status = "Waiting for GPS"; return }
        guard let transport = currentTransport, transport.connected else { skipped += 1; status = "Waiting for comma"; return }
        if localDelay != nil {
            lastLocalFix = location.timestamp
            lastSent = now
        }
        let started = Date()
        onEvent?("Upload started; fix age=\(now.timeIntervalSince(location.timestamp)); accuracy=\(location.horizontalAccuracy)m")
        sending = true
        defer {
            sending = false
            if let next = pending {
                pending = nil
                Task { await deliver(next) }
            }
        }
        do {
            let response = try await transport.request(path: Self.path, method: "POST", headers: ["Content-Type": "application/json"], body: body)
            if response.status == 200 { accepted += 1 } else { failed += 1 }
            onEvent?("Upload finished: HTTP \(response.status); elapsed=\(Date().timeIntervalSince(started))s")
            lastSent = now
            status = response.status == 200 ? "Sharing GPS with comma"
                : response.status == 405 ? "This comma doesn't take phone GPS yet." : "Comma didn't accept the location."
        } catch { failed += 1; onEvent?("Upload failed: \((error as NSError).domain) \((error as NSError).code)"); status = "Waiting for comma" }
    }

    /// iOS marks an unknown value with a negative number; those are left out.
    nonisolated static func payload(_ location: CLLocation, now: Date) -> Data? {
        let age = now.timeIntervalSince(location.timestamp) * 1000
        guard age >= 0, age <= maxAgeMs, location.horizontalAccuracy > 0, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        var value: [String: Any] = ["latitude": location.coordinate.latitude, "longitude": location.coordinate.longitude,
                                    "horizontalAccuracy": location.horizontalAccuracy, "ageMs": Int(age.rounded()),
                                    "timestamp": Int64(location.timestamp.timeIntervalSince1970 * 1000)]
        if location.verticalAccuracy > 0 { value["altitude"] = location.altitude; value["verticalAccuracy"] = location.verticalAccuracy }
        if location.speed >= 0 { value["speed"] = location.speed }
        if location.speedAccuracy >= 0 { value["speedAccuracy"] = location.speedAccuracy }
        if location.course >= 0, location.courseAccuracy >= 0 { value["bearing"] = location.course; value["bearingAccuracy"] = location.courseAccuracy }
        return try? JSONSerialization.data(withJSONObject: value)
    }
}
