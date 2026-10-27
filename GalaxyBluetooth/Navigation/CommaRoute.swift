import Foundation

struct RoutePoint: Equatable {
    let latitude: Double
    let longitude: Double
}
enum RoutePolyline {
    static func decode(_ encoded: String, precision: Double = 1_000_000) throws -> [RoutePoint] {
        guard encoded.utf8.count <= 280_000, precision > 0 else { throw NavigationContractError.invalidResponse }
        let bytes = Array(encoded.utf8)
        var index = 0, latitude = 0, longitude = 0
        var points: [RoutePoint] = []
        func delta() throws -> Int {
            var value = 0, shift = 0
            while index < bytes.count {
                let byte = Int(bytes[index]); index += 1
                guard (63...126).contains(byte), shift <= 30 else { throw NavigationContractError.invalidResponse }
                let chunk = byte - 63
                value |= (chunk & 31) << shift
                if chunk < 32 { return value & 1 == 1 ? ~(value >> 1) : value >> 1 }
                shift += 5
            }
            throw NavigationContractError.invalidResponse
        }
        while index < bytes.count {
            latitude += try delta(); longitude += try delta()
            let lat = Double(latitude) / precision, lon = Double(longitude) / precision
            guard (-90...90).contains(lat), (-180...180).contains(lon), points.count < 20_000 else {
                throw NavigationContractError.invalidResponse
            }
            points.append(RoutePoint(latitude: lat, longitude: lon))
        }
        return points
    }
}
struct CommaPosition: Decodable {
    let latitude: Double
    let longitude: Double
    let bearing: Double?
    var valid: Bool {
        latitude.isFinite && longitude.isFinite && (bearing == nil || (bearing!.isFinite && (0..<360).contains(bearing!))) &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}
struct CommaInstruction: Decodable {
    let primary: String
    let secondary: String
    let distance: Double
    let distanceRemaining: Double
    let timeRemaining: Double
    let type: String
    let modifier: String
    var valid: Bool {
        primary.count <= 512 && secondary.count <= 256 &&
        [distance, distanceRemaining, timeRemaining].allSatisfy { $0.isFinite && $0 >= 0 }
    }
}
struct CommaRouteSnapshot: Decodable {
    let protocolVersion: Int
    let ready: Bool
    let source: String
    let status: String
    let ageSeconds: Double?
    let destination: NavigationDestination?
    let position: CommaPosition?
    let routeVersion: String?
    let polyline6: String?
    let instruction: CommaInstruction?
    let error: String?
    var routePoints: [RoutePoint]? = nil
    var positionValidForSeconds: Double? = nil
    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case ready, source, status, ageSeconds, destination, position, routeVersion, polyline6, instruction, error
    }
    func validate() throws {
        guard protocolVersion == 1, source == "comma", ["active", "waiting", "inactive"].contains(status),
              ageSeconds == nil || (ageSeconds!.isFinite && ageSeconds! >= 0),
              position == nil || position!.valid, instruction == nil || instruction!.valid else {
            throw NavigationContractError.invalidResponse
        }
        if let version = routeVersion {
            guard version.count == 64, version.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw NavigationContractError.invalidResponse
            }
        }
        if status == "active" {
            guard destination != nil, routeVersion != nil, instruction != nil,
                  let age = ageSeconds, age <= 3 else { throw NavigationContractError.invalidResponse }
        }
    }
}

enum NavigationMapMotion {
    /// Display only. Do not use a projected point as a location observation or control input.
    static func routeAligned(_ point: RoutePoint, route: [RoutePoint]) -> RoutePoint {
        guard route.count >= 2 else { return point }
        let latScale = 111_195.0
        let lonScale = latScale * cos(point.latitude * .pi / 180)
        guard abs(lonScale) > 1 else { return point }
        var candidates: [(distance: Double, x: Double, y: Double)] = []
        for index in 1..<route.count {
            let a = route[index - 1], b = route[index]
            let ax = delta(from: point.longitude, to: a.longitude) * lonScale
            let ay = (a.latitude - point.latitude) * latScale
            let bx = delta(from: point.longitude, to: b.longitude) * lonScale
            let by = (b.latitude - point.latitude) * latScale
            let dx = bx - ax, dy = by - ay
            let length = dx * dx + dy * dy
            guard length > 0 else { continue }
            let fraction = min(1, max(0, -(ax * dx + ay * dy) / length))
            let x = ax + fraction * dx, y = ay + fraction * dy
            let distance = hypot(x, y)
            if distance <= 20 { candidates.append((distance, x, y)) }
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }) else { return point }
        // Nearby parallel sections or a hairpin can both be plausible. Keep the real position.
        if candidates.contains(where: {
            $0.distance <= best.distance + 3 && hypot($0.x - best.x, $0.y - best.y) > 10
        }) { return point }
        return RoutePoint(latitude: point.latitude + best.y / latScale,
            longitude: point.longitude + best.x / lonScale)
    }

    static func point(from: RoutePoint, to: RoutePoint, fraction: Double) -> RoutePoint {
        let amount = min(1, max(0, fraction))
        let longitude = from.longitude + delta(from: from.longitude, to: to.longitude) * amount
        return RoutePoint(latitude: from.latitude + (to.latitude - from.latitude) * amount,
            longitude: (longitude + 540).truncatingRemainder(dividingBy: 360) - 180)
    }
    static func heading(from: Double, to: Double, fraction: Double) -> Double {
        let value = from + delta(from: from, to: to) * min(1, max(0, fraction))
        return (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }
    private static func delta(from: Double, to: Double) -> Double {
        let value = (to - from).truncatingRemainder(dividingBy: 360)
        return value > 180 ? value - 360 : value < -180 ? value + 360 : value
    }
    static func anchorY(height: Double, bottomInset: Double) -> Double {
        max(0, min(height, height - max(0, bottomInset) - 64))
    }
    static func cameraDistance(speed: Double, distanceToTurn: Double) -> Double {
        let speed = speed.isFinite ? min(55, max(0, speed)) : 0
        let cruising = min(3800, 1600 + speed * 65)
        guard distanceToTurn.isFinite, distanceToTurn > 0 else { return cruising }
        // Blend continuously over the approach; no zoom switch at a distance threshold.
        let approach = max(180, speed * 22)
        let fraction = min(1, max(0, (distanceToTurn - 30) / approach))
        let blend = fraction * fraction * (3 - 2 * fraction)
        return 1200 + (cruising - 1200) * blend
    }

    static func smoothDistance(_ current: Double, toward target: Double, elapsed: Double) -> Double {
        let dt = min(0.1, max(0, elapsed))
        let amount = 1 - exp(-dt / (target < current ? 1.5 : 3.0))
        return current + (target - current) * amount
    }
}
