import Foundation

struct NavigationDestination: Codable, Equatable {
    let name: String
    let latitude: Double
    let longitude: Double
    var place_name: String { name }
    enum CodingKeys: String, CodingKey { case name, place_name, latitude, longitude }
    init(name: String, latitude: Double, longitude: Double) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 256, latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw NavigationContractError.invalidDestination
        }
        self.name = clean; self.latitude = latitude; self.longitude = longitude
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? c.decode(String.self, forKey: .place_name)
        try self.init(name: name, latitude: c.decode(Double.self, forKey: .latitude), longitude: c.decode(Double.self, forKey: .longitude))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name); try c.encode(name, forKey: .place_name)
        try c.encode(latitude, forKey: .latitude); try c.encode(longitude, forKey: .longitude)
    }
    func matches(_ other: Self) -> Bool {
        abs(latitude - other.latitude) < 0.000001 && abs(longitude - other.longitude) < 0.000001
    }
}

enum NavigationCommand {
    case read
    case start(NavigationDestination)
    case end
    var path: String { "/api/navigation" }
    var method: String { switch self { case .read: "GET"; case .start: "POST"; case .end: "DELETE" } }
    func body() throws -> Data {
        if case .start(let destination) = self { return try JSONEncoder().encode(destination) }
        return Data()
    }
    static func activeDestination(in data: Data) throws -> NavigationDestination? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["destination"] as? String else { throw NavigationContractError.invalidResponse }
        if raw.isEmpty { return nil }
        return try JSONDecoder().decode(NavigationDestination.self, from: Data(raw.utf8))
    }
}

enum NavigationContractError: LocalizedError {
    case invalidDestination, invalidResponse
    var errorDescription: String? {
        switch self {
        case .invalidDestination: "Invalid destination."
        case .invalidResponse: "Couldn’t verify comma’s navigation state."
        }
    }
}

enum NavigationDuration {
    static func text(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let minutes = Int(min(ceil(seconds / 60), Double(Int.max / 2)))
        let total = max(1, minutes)
        let hours = total / 60
        let remainder = total % 60
        if hours == 0 { return "\(total) min" }
        if remainder == 0 { return "\(hours) hr" }
        return "\(hours) hr \(remainder) min"
    }
}
