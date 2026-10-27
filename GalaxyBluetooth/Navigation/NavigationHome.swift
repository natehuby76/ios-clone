import SwiftUI
import MapKit

struct NavigationHome: View {
    @ObservedObject var connection: CommaConnection
    @ObservedObject var navigation: NavigationModel
    @ObservedObject var saved: SavedPlacesStore
    @ObservedObject private var bluetooth: BluetoothTransport
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var openSettings: () -> Void
    var selectAppTab: (CompanionTab) -> Void
    @State private var searchPurpose: PlaceSearchPurpose?
    @State private var showLibrary = false
    @State private var navigationPanelHeight: CGFloat = 0
    @State private var expanded = false
    @State private var appTabsExpanded = true
    init(connection: CommaConnection, navigation: NavigationModel, saved: SavedPlacesStore, selectAppTab: @escaping (CompanionTab) -> Void, openSettings: @escaping () -> Void) {
        self.openSettings = openSettings
        self.selectAppTab = selectAppTab
        self.connection = connection; self.navigation = navigation; self.saved = saved
        bluetooth = connection.bluetooth
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if navigation.navigating && navigation.usingComma {
                    CommaFollowingMap(navigation: navigation, bottomInset: navigationPanelHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea(.container, edges: .top)
                } else {
                    Map(position: $navigation.camera) {
                        UserAnnotation()
                        ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                            MapPolyline(route.polyline).stroke(index == navigation.selectedRoute ? StarPilotTheme.accent : Color.gray.opacity(0.5),
                                style: StrokeStyle(lineWidth: index == navigation.selectedRoute ? 8 : 5, lineCap: .round))
                        }
                        if let destination = navigation.destination {
                            Marker(destination.name, coordinate: destination.coordinate).tint(.red)
                        }
                    }
                    .mapStyle(.standard(elevation: .realistic))
                    .mapControls { MapCompass(); MapScaleView() }
                    .onChange(of: navigation.camera.positionedByUser) { _, moved in
                        if moved { navigation.followsUser = false }
                    }
                }
            }
            .overlay(alignment: .top) { mapHeader.padding(12) }
            .modifier(PlacePanelLayout(overlaid: navigation.navigating && navigation.usingComma) {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.snappy) { expanded.toggle() }
                    } label: {
                        Capsule().fill(.secondary.opacity(0.35)).frame(width: 36, height: 5)
                            .frame(maxWidth: .infinity).frame(height: 24).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse place panel" : "Expand place panel")
                    .accessibilityIdentifier("place-panel-handle")
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        withAnimation(.snappy) { expanded = value.translation.height < 0 }
                    })
                    if !navigation.error.isEmpty {
                        Text(navigation.error).font(.callout).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                            .accessibilityIdentifier("navigation-error-banner")
                    }
                    if !navigation.notice.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Text(navigation.notice).font(.callout)
                            Spacer(minLength: 0)
                            Button { navigation.notice = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("Dismiss navigation message")
                        }.foregroundStyle(StarPilotTheme.accent)
                            .padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    if !navigation.navigating {
                        searchBar.padding(.horizontal, 20).padding(.bottom, 12)
                    }
                    if navigation.navigating {
                        VStack(alignment: .leading, spacing: 12) {
                            tripPanel
                            messages
                        }.padding(.horizontal, 20).padding(.bottom, 18)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                if navigation.destination != nil { destinationPanel }
                                else { browsePanel }
                                messages
                            }.padding(.horizontal, 20).padding(.bottom, 18)
                        }
                        .scrollIndicators(.hidden)
                        .frame(height: panelContentHeight(available: geometry.size.height), alignment: .top)
                        .id(navigation.destination == nil ? "browse" : "destination")
                    }
                }
                .background {
                    GeometryReader { panel in
                        Color.clear.preference(key: NavigationPanelHeightKey.self, value: panel.size.height)
                    }
                }
                .background {
                    UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                        .fill(.regularMaterial).ignoresSafeArea(edges: .bottom)
                }
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
            })
            .onPreferenceChange(NavigationPanelHeightKey.self) { navigationPanelHeight = $0 }
            .sheet(item: $searchPurpose) { purpose in
                PlaceSearch(navigation: navigation, saved: saved, saveAs: purpose.savedKind) { place in
                    if let kind = purpose.savedKind { saved.save(place, as: kind) }
                    else { selectDestination(place) }
                }
            }
            .sheet(isPresented: $showLibrary) {
                SavedPlacesView(saved: saved) { place in
                    showLibrary = false
                    selectDestination(saved.navigationPlace(place))
                }
            }
            .onChange(of: navigation.navigating) { _, active in
                expanded = false
                if active {
                    if let place = navigation.destination { saved.rememberDestination(place) }
                    navigation.followLocation()
                }
            }
            .tint(StarPilotTheme.accent)
        }
    }
    private var mapHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !navigation.navigating {
                HStack(spacing: 8) {
                    CompanionNavigationBar(tab: .navigation, developerMode: connection.app.developerMode,
                        navigation: navigation, expanded: $appTabsExpanded, compactIconOnly: true,
                        statusModel: connection.app, select: selectAppTab)
                    navigationOptions
                }.frame(height: 54)
            }
            HStack(alignment: .top, spacing: 12) {
                if navigation.navigating {
                    HStack(alignment: .center, spacing: 18) {
                        Image(systemName: turnSymbol).font(.system(size: 42, weight: .bold)).frame(width: 52)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.distanceToTurn)).font(.system(size: 30, weight: .bold, design: .rounded))
                            Text(navigation.instruction).font(.title3.weight(.semibold)).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white).padding(20)
                    .background(LinearGradient(colors: [StarPilotTheme.accent, StarPilotTheme.guidance], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement(children: .combine)
                } else { Spacer() }
                VStack(spacing: 10) {
                    if navigation.navigating {
                        Menu {
                            Button("Galaxy", systemImage: "sparkles") { selectAppTab(.galaxy) }
                            Button("Navigation", systemImage: "location.fill") { }
                            Button("Settings", systemImage: "gearshape.fill") { selectAppTab(.connections) }
                            if connection.app.developerMode {
                                Section("Developer") {
                                    ForEach(CompanionTab.allCases.filter { $0.isDeveloperPage }) { item in
                                        Button(item.rawValue, systemImage: item.icon) { selectAppTab(item) }
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "location.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(StarPilotTheme.accent)
                                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            }.frame(width: 56, height: 44)
                        }.modifier(FloatingGalaxyGlass()).accessibilityIdentifier("expand-app-tabs").accessibilityLabel("Navigation, show app tabs")
                        navigationOptions
                    }
                    mapButton("location.fill", label: "Follow my location") { navigation.followLocation() }
                    if navigation.navigating {
                        mapButton("arrow.up.left.and.arrow.down.right", label: "Show full route") { navigation.showOverview() }
                    }
                }
            }
        }
    }
    private var navigationOptions: some View {
        Menu {
            Button("Copy diagnostic report", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = connection.app.connectionLog.report(model: connection.app)
                navigation.notice = "Diagnostic report copied."
            }
            Button("Reset navigation", systemImage: "arrow.counterclockwise", role: .destructive) {
                Task { await connection.app.navigationServices.resetNavigation() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
        }.accessibilityLabel("Navigation options")
    }
    private func mapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2).accessibilityLabel(label)
    }
    private func panelContentHeight(available: CGFloat) -> CGFloat {
        if navigation.navigating { return min(available * 0.42, expanded ? 260 : 180) }
        if navigation.destination != nil { return min(available * (expanded ? 0.58 : 0.42), expanded ? 520 : 360) }
        let count = min(saved.recentDestinations.count, expanded ? 10 : 3)
        let content: CGFloat = 180 + 42 + (count == 0 ? 30 : CGFloat(count) * 66)
        return min(available * (expanded ? 0.55 : 0.42), content)
    }
    private var searchBar: some View {
        Button { search() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text("Search Maps").foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
                }.font(.title3).padding(14).background(.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityIdentifier("map-search")
    }
    private var browsePanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Favorites").font(.title3.bold())
                Spacer()
                Button("See All") { showLibrary = true }.font(.subheadline.weight(.medium))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    shortcut(.home, icon: "house.fill", title: "Home")
                    shortcut(.work, icon: "briefcase.fill", title: "Work")
                    ForEach(saved.library.places.filter { $0.kind == .favorite }.prefix(6)) { place in
                        favoriteShortcut(place)
                    }
                    Button { search(as: .favorite) } label: {
                        shortcutLabel(icon: "plus", title: "Add", subtitle: "Favorite", tint: StarPilotTheme.accent)
                    }.buttonStyle(.plain).accessibilityLabel("Add favorite")
                }.padding(.vertical, 2)
            }
            HStack {
                Text("Recent Destinations").font(.headline)
                Spacer()
                if !saved.recentDestinations.isEmpty {
                    Button("Clear") { saved.clearRecentDestinations() }.font(.subheadline)
                }
            }
            if saved.recentDestinations.isEmpty {
                Text("Destinations you select will appear here.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(saved.recentDestinations.prefix(expanded ? 10 : 3)) { place in
                    RecentDestinationRow(place: place) {
                        selectDestination(saved.navigationPlace(place))
                    }.disabled(navigation.busy)
                }
            }
            Label(connection.connected ? "Comma connected · \(connection.connectionLabel)" : "Connect comma in Settings", systemImage: "link")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func shortcut(_ kind: SavedPlaceKind, icon: String, title: String) -> some View {
        let place = saved.library.place(kind)
        return Button {
            if let place { selectDestination(saved.navigationPlace(place)) }
            else { search(as: kind) }
        } label: {
            shortcutLabel(icon: icon, title: title, subtitle: place == nil ? "Set address" : place!.name, tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(place != nil && navigation.busy)
        .accessibilityIdentifier(kind == .home ? "home-shortcut" : "work-shortcut")
        .contextMenu {
            Button("Edit address") { search(as: kind) }
            if let place { Button("Remove", role: .destructive) { saved.remove(place) } }
        }
    }
    private func favoriteShortcut(_ place: SavedPlace) -> some View {
        Button { selectDestination(saved.navigationPlace(place)) } label: {
            shortcutLabel(icon: "star.fill", title: place.name, subtitle: "", tint: StarPilotTheme.accent)
        }
        .buttonStyle(.plain).disabled(navigation.busy)
        .contextMenu { Button("Remove favorite", role: .destructive) { saved.remove(place) } }
    }
    private func shortcutLabel(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 25, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 60, height: 60).background(tint.opacity(0.12), in: Circle())
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
            if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: 78)
    }
    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let place = navigation.destination {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name).font(.title2.bold()).lineLimit(2)
                        Text(place.address).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button { navigation.clearPreview() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                    }.disabled(navigation.busy).accessibilityLabel("Close destination")
                }
                HStack(spacing: 16) {
                    Button {
                        if let favorite = saved.library.favorite(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude) {
                            saved.remove(favorite)
                        } else { saved.save(place, as: .favorite) }
                    } label: {
                        Label(saved.library.favorite(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude) == nil ?
                            "Add Favorite" : "Saved", systemImage: "star.fill")
                    }.font(.subheadline.weight(.medium))
                    Menu {
                        Button("Save as Home") { saved.save(place, as: .home) }
                        Button("Save as Work") { saved.save(place, as: .work) }
                    } label: { Image(systemName: "ellipsis.circle").font(.title3) }.accessibilityLabel("Save place options")
                }
            }
            ForEach(Array(navigation.routes.enumerated()), id: \.offset) { index, route in
                HStack(spacing: 14) {
                    Button { navigation.chooseRoute(index) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(minutes(route.expectedTravelTime)).font(.title2.bold())
                            Text("\(distance(route.distance)) · \(route.name)").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button {
                        connection.recordAction("Phone Go button tapped")
                        navigation.chooseRoute(index)
                        Task { await navigation.start(connection: connection) }
                    } label: {
                        Text("Go").font(.title3.bold()).foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 13)
                            .background(StarPilotTheme.guidance, in: Capsule())
                    }.buttonStyle(.plain).accessibilityLabel("Start route \(index + 1)")
                }
                .padding(14)
                .background(navigation.selectedRoute == index ? StarPilotTheme.accent.opacity(0.08) : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(navigation.selectedRoute == index ? StarPilotTheme.accent.opacity(0.5) : .clear))
                .disabled(navigation.busy)
            }
            if navigation.busy { ProgressView("Getting directions…") }
            else if navigation.routes.isEmpty {
                Button("Get directions") { navigation.requestLocation(); Task { await navigation.calculateRoutes(refresh: false) } }
                    .buttonStyle(.borderedProminent)
            }
            Toggle("Send destination to comma", isOn: $navigation.sendToComma).font(.subheadline).disabled(navigation.busy)
            Text("Preview uses Apple routing. After Go, the app shows comma’s route when connected.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var tripPanel: some View {
        VStack(spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : Date().addingTimeInterval(navigation.remainingTime).formatted(date: .omitted, time: .shortened), label: "arrival")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : minutes(navigation.remainingTime), label: "remaining")
                tripMetric(navigation.usingComma && !navigation.commaFeedReady ? "—" : distance(navigation.remainingDistance), label: navigation.usingComma ? "distance" : "estimated")
                Spacer(minLength: 0)
                Button(navigation.endingRoute ? "Ending…" : "End") { Task { await navigation.end(connection: connection) } }
                    .font(.headline).foregroundStyle(.white).padding(.horizontal, 18).padding(.vertical, 13)
                    .background(.red, in: Capsule()).disabled(navigation.busy)
            }
            HStack {
                Text(navigation.destination?.name ?? "Destination").font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Text(navigation.usingComma ? "Comma route" : "Phone route").font(.caption).foregroundStyle(.secondary)
            }
            if expanded {
                Button("Show route overview") { navigation.showOverview() }.frame(maxWidth: .infinity)
            }
        }
    }
    private func tripMetric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 23, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.65)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var messages: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !navigation.locationMessage.isEmpty {
                Button(navigation.locationMessage) { navigation.requestLocation() }.font(.caption)
            }
            if navigation.usingComma, !navigation.commaFeedMessage.isEmpty { Text(navigation.commaFeedMessage).font(.caption).foregroundStyle(.orange) }
            if !saved.message.isEmpty { Text(saved.message).font(.caption).foregroundStyle(.secondary) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var turnSymbol: String {
        let text = (navigation.usingComma ? navigation.commaManeuverType + " " + navigation.commaManeuverModifier : navigation.instruction).lowercased()
        if text.contains("roundabout") { return "arrow.triangle.2.circlepath" }
        if text.contains("u-turn") { return "arrow.uturn.down" }
        if text.contains("left") { return "arrow.turn.up.left" }
        if text.contains("right") { return "arrow.turn.up.right" }
        return "arrow.up"
    }
    private func search(as kind: SavedPlaceKind? = nil) {
        searchPurpose = kind == .home ? .home : kind == .work ? .work : kind == .favorite ? .favorite : .destination
    }
    private func selectDestination(_ place: NavigationPlace) {
        guard !navigation.busy, !navigation.navigating else { return }
        saved.rememberDestination(place)
        Task { await navigation.select(place) }
    }
    private func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }
    private func minutes(_ seconds: Double) -> String { NavigationDuration.text(seconds) }
}

private struct NavigationPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct PlacePanelLayout<Panel: View>: ViewModifier {
    let overlaid: Bool
    let panel: Panel
    init(overlaid: Bool, @ViewBuilder panel: () -> Panel) {
        self.overlaid = overlaid
        self.panel = panel()
    }
    @ViewBuilder func body(content: Content) -> some View {
        if overlaid {
            content.overlay(alignment: .bottom) { panel }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) { panel }
        }
    }
}
