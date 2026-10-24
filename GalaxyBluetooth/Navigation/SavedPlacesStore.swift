import SwiftUI
import MapKit

@MainActor
final class SavedPlacesStore: ObservableObject {
    @Published private(set) var library: SavedPlaceLibrary
    @Published var message = ""
    @Published private(set) var recentDestinations: [SavedPlace] = []
    private let recentKey = "starpilotnav.recentdestinations.v1"
    private let defaults: UserDefaults
    private let storageKey = "starpilotnav.savedplaces.v1"
    init(defaults: UserDefaults = .standard) {
        #if DEBUG
        let defaults = ProcessInfo.processInfo.arguments.contains("--ui-testing") ?
            UserDefaults(suiteName: "starpilotnav.ui-tests")! : defaults
        if ProcessInfo.processInfo.arguments.contains("--reset-ui-state") {
            defaults.removePersistentDomain(forName: "starpilotnav.ui-tests")
        }
        #endif
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(SavedPlaceLibrary.self, from: data) {
            library = SavedPlaceLibrary(places: saved.places)
        } else { library = SavedPlaceLibrary() }
        if let data = defaults.data(forKey: recentKey), data.count <= 32_768,
           let places = try? JSONDecoder().decode([SavedPlace].self, from: data) {
            for place in places where place.valid {
                if !recentDestinations.contains(where: { $0.matches(latitude: place.latitude, longitude: place.longitude) }) {
                    recentDestinations.append(place)
                }
                if recentDestinations.count == 10 { break }
            }
        }
    }
    func rememberDestination(_ place: NavigationPlace) {
        let entry = SavedPlace(id: UUID(), name: place.name, address: String(place.address.prefix(512)),
            latitude: place.coordinate.latitude, longitude: place.coordinate.longitude, kind: .favorite)
        guard entry.valid else { return }
        let next = [entry] + recentDestinations.filter {
            !$0.matches(latitude: entry.latitude, longitude: entry.longitude)
        }
        if let data = try? JSONEncoder().encode(Array(next.prefix(10))) {
            defaults.set(data, forKey: recentKey)
            recentDestinations = Array(next.prefix(10))
        }
    }
    func clearRecentDestinations() {
        defaults.removeObject(forKey: recentKey)
        recentDestinations = []
    }
    func save(_ place: NavigationPlace, as kind: SavedPlaceKind) {
        do {
            var next = library
            try next.save(name: place.name, address: place.address, latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude, kind: kind)
            try persist(next)
            message = kind == .home ? "Home saved." : kind == .work ? "Work saved." : "Added to Favorites."
        } catch { message = error.localizedDescription }
    }
    func remove(_ place: SavedPlace) {
        var next = library; next.remove(id: place.id)
        do { try persist(next); message = "" } catch { message = error.localizedDescription }
    }
    func rename(_ place: SavedPlace, to name: String) {
        do {
            var next = library; try next.rename(id: place.id, name: name)
            try persist(next); message = ""
        } catch { message = error.localizedDescription }
    }
    private func persist(_ value: SavedPlaceLibrary) throws {
        let data = try JSONEncoder().encode(value)
        defaults.set(data, forKey: storageKey); library = value
    }
    func navigationPlace(_ place: SavedPlace) -> NavigationPlace {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(
            latitude: place.latitude, longitude: place.longitude)))
        item.name = place.name
        return NavigationPlace(item: item, subtitle: place.address)
    }
}
