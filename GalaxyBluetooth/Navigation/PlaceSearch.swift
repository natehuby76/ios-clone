import SwiftUI

enum PlaceSearchPurpose: String, Identifiable {
    case destination, home, work, favorite
    var id: String { rawValue }
    var savedKind: SavedPlaceKind? {
        switch self {
        case .destination: nil
        case .home: .home
        case .work: .work
        case .favorite: .favorite
        }
    }
}

struct PlaceSearch: View {
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    let saveAs: SavedPlaceKind?
    let onSelect: (NavigationPlace) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if navigation.searching { ProgressView("Searching…") }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !saved.recentDestinations.isEmpty {
                    Section("Recent Destinations") {
                        ForEach(saved.recentDestinations) { place in
                            RecentDestinationRow(place: place) {
                                onSelect(saved.navigationPlace(place)); dismiss()
                            }
                        }
                        Button("Clear Recent Destinations", role: .destructive) { saved.clearRecentDestinations() }
                    }
                }
                ForEach(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : navigation.results) { place in
                    Button { onSelect(place); dismiss() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(StarPilotTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(place.name).font(.headline).foregroundStyle(.primary)
                                Text(place.address).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }.accessibilityIdentifier("place-search-result")
                }
                if !navigation.error.isEmpty { Text(LocalizedStringKey(navigation.error)).foregroundStyle(.secondary) }
                if query.isEmpty {
                    Text(saveAs == .home ? "Search for your home address, then select it to save." :
                        saveAs == .work ? "Search for your work address, then select it to save." :
                        "Search for an address, business, or place.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(saveAs == .home ? "Add Home" : saveAs == .work ? "Add Work" : saveAs == .favorite ? "Add Favorite" : "Search Maps")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search places or addresses")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(450)); try Task.checkCancellation(); await navigation.search(query) }
                catch {}
            }
        }.presentationDetents([.medium, .large])
    }
}

struct SavedPlacesView: View {
    @ObservedObject var saved: SavedPlacesStore
    let onSelect: (SavedPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: SavedPlace?
    @State private var name = ""
    @State private var showRename = false
    var body: some View {
        NavigationStack {
            List {
                ForEach(SavedPlaceKind.allCases, id: \.self) { kind in
                    Section(kind == .home ? "Home" : kind == .work ? "Work" : "Favorites") {
                        ForEach(saved.library.places.filter { $0.kind == kind }) { place in
                            Button { onSelect(place); dismiss() } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(place.name).foregroundStyle(.primary)
                                        Text(place.address).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: kind == .home ? "house.fill" : kind == .work ? "briefcase.fill" : "star.fill")
                                        .foregroundStyle(StarPilotTheme.accent)
                                }.padding(.vertical, 4)
                            }
                            .swipeActions {
                                Button("Delete", role: .destructive) { saved.remove(place) }
                                Button("Rename") { renaming = place; name = place.name; showRename = true }.tint(StarPilotTheme.accent)
                            }
                        }
                    }
                }
                Section { Text("Saved on this iPhone.").font(.caption).foregroundStyle(.secondary) }
                if !saved.message.isEmpty { Text(LocalizedStringKey(saved.message)).font(.caption) }
            }
            .navigationTitle("Saved Places")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename place", isPresented: $showRename) {
                TextField("Name", text: $name)
                Button("Save") { if let place = renaming { saved.rename(place, to: name) } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }
}

struct RecentDestinationRow: View {
    let place: SavedPlace
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "clock").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(place.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
