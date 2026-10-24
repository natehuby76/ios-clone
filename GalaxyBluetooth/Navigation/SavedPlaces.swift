import Foundation

enum SavedPlaceKind: String, Codable, CaseIterable {
    case home, work, favorite
}

struct SavedPlace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var address: String
    let latitude: Double
    let longitude: Double
    var kind: SavedPlaceKind
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 256 &&
        address.count <= 512 && latitude.isFinite && longitude.isFinite &&
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
    func matches(latitude: Double, longitude: Double) -> Bool {
        abs(self.latitude - latitude) < 0.000001 && abs(self.longitude - longitude) < 0.000001
    }
}

struct SavedPlaceLibrary: Codable {
    private(set) var places: [SavedPlace] = []
    static let limit = 100

    init(places: [SavedPlace] = []) {
        var ids = Set<UUID>()
        var special = Set<SavedPlaceKind>()
        self.places = places.filter { place in
            guard place.valid, ids.insert(place.id).inserted else { return false }
            if place.kind != .favorite { return special.insert(place.kind).inserted }
            return true
        }.prefix(Self.limit).map { $0 }
    }
    mutating func save(name: String, address: String, latitude: Double, longitude: Double, kind: SavedPlaceKind) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = SavedPlace(id: UUID(), name: clean, address: String(address.prefix(512)),
            latitude: latitude, longitude: longitude, kind: kind)
        guard candidate.valid else { throw SavedPlaceError.invalid }
        if kind != .favorite, let index = places.firstIndex(where: { $0.kind == kind }) {
            let existing = places[index]
            places[index] = SavedPlace(id: existing.id, name: clean, address: candidate.address,
                latitude: latitude, longitude: longitude, kind: kind)
            return
        }
        if kind == .favorite, let index = places.firstIndex(where: {
            $0.kind == .favorite && $0.matches(latitude: latitude, longitude: longitude)
        }) {
            places[index].name = clean; places[index].address = candidate.address
            return
        }
        guard places.count < Self.limit else { throw SavedPlaceError.full }
        places.append(candidate)
    }
    mutating func rename(id: UUID, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 256, let index = places.firstIndex(where: { $0.id == id }) else {
            throw SavedPlaceError.invalid
        }
        places[index].name = clean
    }
    mutating func remove(id: UUID) { places.removeAll { $0.id == id } }
    func place(_ kind: SavedPlaceKind) -> SavedPlace? { places.first { $0.kind == kind } }
    func favorite(latitude: Double, longitude: Double) -> SavedPlace? {
        places.first { $0.kind == .favorite && $0.matches(latitude: latitude, longitude: longitude) }
    }
}

enum SavedPlaceError: LocalizedError {
    case invalid, full
    var errorDescription: String? {
        switch self {
        case .invalid: "Enter a name and a valid location."
        case .full: "You’ve reached 100 saved places. Remove one to add another."
        }
    }
}
