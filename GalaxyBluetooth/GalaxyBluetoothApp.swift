import SwiftUI
import Network
import MapKit

@main
struct GalaxyBluetoothApp: App {
    @StateObject private var model = AppModel.shared
    var body: some Scene { WindowGroup { GalaxyRootView(model: model) } }
}

enum CompanionTab: String, CaseIterable, Identifiable {
    case galaxy = "Galaxy", navigation = "Navigation", live = "Live View", diagnostics = "Diagnostics", logs = "Dev / Logs", connections = "Settings"
    var id: String { rawValue }
    var isDeveloperPage: Bool { self == .live || self == .diagnostics || self == .logs }
    var icon: String {
        switch self {
        case .galaxy: "sparkles"
        case .navigation: "location.fill"
        case .live: "play.rectangle"
        case .diagnostics: "chart.xyaxis.line"
        case .logs: "ladybug"
        case .connections: "gearshape.fill"
        }
    }
}

struct LegacyGalaxyStatus: Decodable {
    let paired: Bool
    let url: String
    var browserURL: URL? {
        guard let parsed = URL(string: url), parsed.scheme == "https",
              parsed.host == "galaxy.firestar.link", parsed.port == nil,
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              parsed.path.range(of: "^/[A-Za-z0-9]{16}$", options: .regularExpression) != nil else { return nil }
        return parsed
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let diagnostics = CompanionDiagnostics()
    let galaxyPage = GalaxyPageDiagnostics()
    let connectionLog = ConnectionEventLog()
    let discovery = LANDiscovery()
    @Published var selectingDiscoveredComma = false
    private var lastRoute = "Reconnecting…"
    @Published var showDiagnostics = false
    @Published var showAudioPairing = false
    private var offerAudioPairing = false
    private var audioWindowOpen = false
    private let claimer = ClaimTransport()
    lazy var audioPairing = AudioPairing(transport: { [weak self] in self?.transport })
    lazy var phoneLocation: PhoneLocation = {
        let value = PhoneLocation(transport: { [weak self] in self?.transport })
        value.onEvent = { [weak self] in self?.connectionLog.record("GPS: " + $0) }
        value.onSharingChanged = { [weak self] _ in self?.updateMonitoring() }
        return value
    }()
    @Published var tab: CompanionTab = .connections
    @Published var developerMode = UserDefaults.standard.bool(forKey: "galaxy.app.developerMode") {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: "galaxy.app.developerMode")
            if !developerMode {
                if tab.isDeveloperPage { tab = opened ? .galaxy : .connections }
                diagnostics.live = false
                diagnostics.phoneVisible = false
                showDiagnostics = false
            }
        }
    }
    private var galaxyRecoveryTask: Task<Void, Never>?
    private var lastAutomaticGalaxyRecovery: TimeInterval = -.infinity
    func recoverGalaxy(automatic: Bool = true, reload: Bool = true) {
        guard phoneActive, galaxyRecoveryTask == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if automatic && reload {
            guard now - lastAutomaticGalaxyRecovery >= 30 else {
                galaxyPage.record("Automatic page recovery paused; use Retry Galaxy")
                return
            }
            lastAutomaticGalaxyRecovery = now
        }
        galaxyRecoveryTask = Task { @MainActor in
            defer { self.galaxyRecoveryTask = nil }
            let previousURL = self.server.url
            let healthy = await self.server.ensureAvailable()
            guard self.phoneActive else { return }
            if healthy {
                if self.opened && (reload || self.galaxyPage.stalled || previousURL != self.server.url) {
                    self.galaxyPage.record("Local server checked; recreating Galaxy web page")
                    self.galaxyPage.retry()
                }
            } else { self.galaxyPage.fail("Local server unavailable after recovery attempt") }
        }
    }
    lazy var navigationServices = NavigationServices(app: self)
    private var navigationActive = false
    func setNavigationActive(_ active: Bool) { navigationActive = active; updateMonitoring() }
    private var phoneActive = false
    private var carPlayActive = false
    private var monitorTask: Task<Void, Never>?
    func setPhoneActive(_ active: Bool) { connectionLog.record("Lifecycle: phone active=\(active); tab=\(tab.rawValue); navigation=\(navigationActive)"); phoneActive = active; if !active { automaticLAN?.cancel() }; diagnostics.phoneActive = active; if !active { discovery.stop() }; updateMonitoring() }
    func setCarPlayActive(_ active: Bool) { carPlayActive = active; diagnostics.carPlayActive = active; updateMonitoring() }
    private func updateMonitoring() {
        // Sharing phone GPS keeps the app running in the background, so keep reconnecting too.
        if phoneActive || carPlayActive || phoneLocation.sharing || navigationActive {
            if monitorTask == nil { monitorTask = Task { await monitor() } }
        } else { monitorTask?.cancel(); monitorTask = nil }
    }
    @Published var pairingKey = PairingKeyStore.load()
    @Published var address = UserDefaults.standard.string(forKey: "galaxy.lan.address") ?? ""
    @Published var findAddressAutomatically = UserDefaults.standard.object(forKey: "galaxy.lan.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(findAddressAutomatically, forKey: "galaxy.lan.auto") }
    }
    @Published var networkDetails = "Comma can use a hotspot, Wi-Fi or its SIM for internet. Your connection here controls how this iPhone reaches comma."
    @Published var mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "galaxy.connection.mode") ?? "") ?? .automatic {
        didSet {
            automaticLAN?.cancel(); lanProbeTask?.cancel()
            transport.mode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "galaxy.connection.mode")
            if mode == .lan { bluetooth.disconnect() }
            if mode == .bluetooth { discovery.stop(); lan.invalidate(reason: "Bluetooth-only mode selected") }
            logConnection("Connection mode selected: \(mode.title)")
        }
    }
    @Published var showConnections = false
    @Published var pairingInProgress = false
    @Published var opened = false
    @Published var connectionMessage = "Choose a connection, or use Automatic for Wi-Fi with Bluetooth fallback."
    @Published var wantsConnection = true
    @Published var loadingLegacyURL = false
    @Published var legacyMessage = ""
    @Published var legacyURL: URL?
    let bluetooth: BluetoothTransport
    let lan: LANTransport
    let transport: PreferredTransport
    let assets: GalaxyAssetStore
    let server: LoopbackServer
    private let pathMonitor = NWPathMonitor()
    private var lastNetworkPath = ""
    private var lastReconnect = Date.distantPast
    private var lastAddressCheck = Date.distantPast
    private var identitySession = ""
    private var addressCheckSession = ""
    private var localAddressNetwork = ""
    private var automaticLAN: Task<Void, Never>?
    private var lanProbeTask: Task<Void, Never>?
    private var lastLANDiscovery = Date.distantPast
    private var triedLANAddresses = Set<String>()
    /// One step for the app and music: comma's open pairing window gives this iPhone its key, then music is set up in the same window.
    func pairWithComma() {
        guard !pairingInProgress else { return }
        pairingInProgress = true
        offerAudioPairing = false
        showAudioPairing = false
        bluetooth.disconnect(reason: "Starting new phone pairing")
        connectionMessage = "Open Settings → Bluetooth → Pair phone on comma (or Pair phone in Galaxy). Looking for comma…"
        Task { @MainActor in
            defer { pairingInProgress = false }
            do { importClaim(try await claimer.claim(name: UIDevice.current.name)) }
            catch is CancellationError { connectionMessage = "Pairing cancelled." }
            catch { connectionMessage = error.localizedDescription }
        }
    }
    func cancelPairing() { claimer.cancel() }
    private func importClaim(_ outcome: ClaimTransport.Outcome) {
        // The key is saved only after the encrypted handshake, like any imported key.
        opened = false
        wantsConnection = true
        bluetooth.forgetSavedDevice()
        PairingKeyStore.stage(PairingCode(key: outcome.result.key, id: outcome.result.id))
        lan.clearEndpoint()
        lan.bind(to: nil)
        address = ""
        identitySession = ""
        addressCheckSession = ""
        UserDefaults.standard.removeObject(forKey: "galaxy.comma.identity")
        UserDefaults.standard.removeObject(forKey: "galaxy.lan.address")
        UserDefaults.standard.set(outcome.deviceID.uuidString, forKey: "galaxy.bluetooth.device")
        pairingKey = outcome.result.key
        if mode == .lan { mode = .automatic }
        connectionMessage = "Paired. Connecting to comma…"
        offerAudioPairing = true
        audioWindowOpen = true
        lastReconnect = Date()
        bluetooth.reconnectSaved(pairingKey: pairingKey)
        if !bluetooth.connecting { bluetooth.scan() }
    }
    init() {
        let bluetooth = BluetoothTransport()
        let lan = LANTransport()
        let transport = PreferredTransport(lan: lan, bluetooth: bluetooth, invalidateLAN: { lan.invalidate(reason: $0) })
        let assets = GalaxyAssetStore()
        self.bluetooth = bluetooth; self.lan = lan; self.transport = transport; self.assets = assets
        lan.bind(to: UserDefaults.standard.string(forKey: "galaxy.comma.identity"))
        let cache = GalaxyReadCache(transport: transport, sessionID: {
            transport.usesLAN ? "lan-" + lan.generation : "ble-" + bluetooth.sessionIdentifier
        })
        server = LoopbackServer(transport: cache, webRoot: assets.readyRoot ?? assets.bundledRoot)
        transport.mode = mode
        diagnostics.transport = transport; diagnostics.lan = lan
        galaxyPage.recover = { [weak self] automatic in self?.recoverGalaxy(automatic: automatic) }
        server.start()
        discovery.onEvent = { [weak self] reason in self?.connectionLog.record(reason) }
        discovery.onDevicesChanged = { [weak self] in self?.discoverAutomaticLAN() }
        lan.onEvent = { [weak self] reason in self?.logConnection(reason) }
        bluetooth.onEvent = { [weak self] reason in self?.logConnection(reason) }
        claimer.onEvent = { [weak self] reason in self?.connectionLog.record(reason) }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let route = path.usesInterfaceType(.wifi) ? "Wi-Fi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
                let reason = "iOS network path updated: \(path.status == .satisfied ? "available" : "unavailable"), \(route), expensive=\(path.isExpensive), constrained=\(path.isConstrained)"
                let interfaces = path.availableInterfaces
                    .filter { path.usesInterfaceType($0.type) }
                    .map { "\($0.name):\($0.index)" }.sorted().joined(separator: ",")
                let fingerprint = "\(path.status)|\(route)|\(interfaces)|ipv4=\(path.supportsIPv4)|\(LANDiscovery.networkSignature())"
                guard fingerprint != self.lastNetworkPath else { return }
                self.lastNetworkPath = fingerprint
                self.connectionLog.record(reason)
                self.automaticLAN?.cancel(); self.lanProbeTask?.cancel()
                self.discovery.networkChanged()
                self.triedLANAddresses.removeAll()
                self.lastLANDiscovery = .distantPast
                self.lan.invalidate(reason: reason)
                self.lastAddressCheck = .distantPast
                self.discoverAutomaticLAN()
            }
        }
        pathMonitor.start(queue: .main)
        updateMonitoring()
    }
    deinit { pathMonitor.cancel() }
    private func logConnection(_ reason: String) {
        let route = transport.label
        if route != lastRoute {
            connectionLog.record("\(lastRoute) → \(route): \(reason)")
            lastRoute = route
        } else { connectionLog.record("\(route): \(reason)") }
    }
    func connect() {
        legacyURL = nil
        do {
            if mode != .bluetooth, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try lan.configure(address: address)
            } else if mode == .lan {
                throw BridgeError.message("Enter comma’s current local IP address, or use Automatic and pair Bluetooth to find it.")
            }
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "galaxy.lan.address")
            wantsConnection = true
            lastReconnect = .distantPast
            lastAddressCheck = .distantPast
            localAddressNetwork = ""
            connectionMessage = "Checking your comma…"
        } catch { connectionMessage = error.localizedDescription }
    }
    func startAudioPairing() {
        guard transport.connected else { return }
        showAudioPairing = true
        let windowOpen = audioWindowOpen
        audioWindowOpen = false
        audioPairing.start(windowOpen: windowOpen)
    }
    private var openingGalaxy = false
    @Published private(set) var matchingGalaxy = false
    private var lastGalaxyMatch = Date.distantPast

    func applyMatchedGalaxy() {
        guard opened, let root = assets.readyRoot, root != assets.inUseRoot else { return }
        assets.inUseRoot = root
        server.useWebRoot(root)
        recoverGalaxy(automatic: false)
    }

    func checkGalaxyUpdates() async {
        guard wantsConnection, transport.connected, !matchingGalaxy else { return }
        matchingGalaxy = true
        lastGalaxyMatch = Date()
        defer { matchingGalaxy = false }
        let bleSession = bluetooth.sessionIdentifier
        let lanSession = lan.generation
        do {
            let response = try await transport.request(path: "/api/software/status?history=0", method: "GET", headers: [:], body: Data())
            guard wantsConnection, transport.connected, bluetooth.sessionIdentifier == bleSession, lan.generation == lanSession else { return }
            guard response.status == 200 else { throw BridgeError.message("Comma’s Galaxy version could not be read.") }
            let source = try GalaxySource.parse(response.bodyData)
            await assets.check(source: source, stillCurrent: { self.wantsConnection && self.transport.connected && self.bluetooth.sessionIdentifier == bleSession && self.lan.generation == lanSession })
        } catch {
            if bluetooth.sessionIdentifier == bleSession && lan.generation == lanSession {
                assets.unavailable("Couldn’t match Galaxy to comma.")
            }
        }
    }
    func openIfReady() {
        guard wantsConnection, transport.connected, !opened, !openingGalaxy else { return }
        openingGalaxy = true
        Task { @MainActor in
            defer { openingGalaxy = false }
            await checkGalaxyUpdates()
            guard wantsConnection, transport.connected, !opened else { return }
            let root = assets.readyRoot ?? assets.bundledRoot
            assets.inUseRoot = root
            server.useWebRoot(root)
            opened = true
        }
    }
    func disconnect() {
        legacyURL = nil
        automaticLAN?.cancel(); lanProbeTask?.cancel()
        discovery.stop()
        wantsConnection = false; opened = false
        bluetooth.disconnect(reason: "User selected Disconnect"); lan.invalidate(reason: "User selected Disconnect")
        connectionMessage = "Disconnected."
    }
    func selectDiscoveredComma(_ device: DiscoveredComma) async {
        guard !selectingDiscoveredComma, mode != .bluetooth else { return }
        discovery.stop()
        selectingDiscoveredComma = true
        defer { selectingDiscoveredComma = false }
        // Advertised names and addresses are discovery hints, not pairing credentials.
        let candidate = LANTransport()
        candidate.bind(to: lan.expectedDeviceID)
        let originalGeneration = lan.generation
        let originalMode = mode
        do {
            try candidate.configure(address: device.address)
            guard await candidate.probe() else {
                connectionMessage = "Found a device, but Galaxy is unavailable or it doesn’t match your paired comma."
                connectionLog.record("Discovered comma rejected by LAN verification")
                return
            }
            guard lan.generation == originalGeneration, mode == originalMode, phoneActive else {
                connectionMessage = "Connection changed. Select the comma again."
                return
            }
            lan.bind(to: candidate.verifiedDeviceID)
            UserDefaults.standard.set(candidate.verifiedDeviceID, forKey: "galaxy.comma.identity")
            address = device.address
            connect()
            connectionLog.record("User selected a discovered comma; LAN verification passed")
        } catch {
            connectionMessage = "Couldn’t connect to the discovered comma. Try again or enter its IP."
        }
    }
    func fetchLegacyURL() async -> URL? {
        guard !loadingLegacyURL else { return nil }
        legacyMessage = ""
        legacyURL = nil
        guard wantsConnection, transport.connected else {
            legacyMessage = "Connect to your comma first to get its Galaxy link."
            return nil
        }
        loadingLegacyURL = true
        defer { loadingLegacyURL = false }
        let lanSession = lan.generation
        let bluetoothSession = bluetooth.sessionIdentifier
        do {
            let response = try await transport.request(path: "/api/galaxy/status", method: "GET", headers: [:], body: Data())
            guard wantsConnection, transport.connected, lan.generation == lanSession,
                  bluetooth.sessionIdentifier == bluetoothSession else {
                throw BridgeError.message("Connection changed. Try opening legacy Galaxy again.")
            }
            guard response.status == 200 else {
                throw BridgeError.message("Couldn’t get your comma’s Galaxy link (HTTP \(response.status)).")
            }
            let status = try JSONDecoder().decode(LegacyGalaxyStatus.self, from: response.bodyData)
            guard status.paired else {
                throw BridgeError.message("Set up legacy Galaxy pairing on your comma first. Bluetooth pairing is separate.")
            }
            guard let url = status.browserURL else {
                throw BridgeError.message("Your comma hasn’t provided a valid Galaxy link. Check its legacy Galaxy pairing.")
            }
            legacyURL = url
            connectionLog.record("Comma-specific legacy Galaxy link validated")
            return url
        } catch {
            connectionLog.record("Comma-specific legacy Galaxy link unavailable")
            legacyMessage = (error as? BridgeError)?.localizedDescription ?? "Couldn’t get your comma’s Galaxy link. Check the connection and try again."
            return nil
        }
    }
    private func learnAddress() async {
        guard bluetooth.connected, Date().timeIntervalSince(lastAddressCheck) >= 20 || addressCheckSession != bluetooth.sessionIdentifier else { return }
        lastAddressCheck = Date()
        let session = bluetooth.sessionIdentifier
        let networkPath = lastNetworkPath
        addressCheckSession = session
        do {
            if identitySession != session {
                let identity = try await bluetooth.request(path: "/data/runtime.json", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session else { return }
                // Only the authenticated BLE peer may establish the automatic LAN identity.
                guard identity.status == 200, let value = LANTransport.deviceID(identity.bodyData) else {
                    networkDetails = "Automatic local discovery needs a registered device identifier. Bluetooth still works; enter comma’s IP manually for Wi-Fi."
                    return
                }
                lan.bind(to: value)
                UserDefaults.standard.set(value, forKey: "galaxy.comma.identity")

                identitySession = session
            }
            let network = session + "|" + networkPath
            guard findAddressAutomatically, !lan.connected, localAddressNetwork != network else { return }
            let generation = lan.generation
            let response = try await bluetooth.request(path: "/api/local-access", method: "GET", headers: [:], body: Data())
            guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session, response.status == 200,
                  lastNetworkPath == networkPath, lan.generation == generation, !lan.connected,
                  !response.bodyData.isEmpty else { return }
            if let ip = LANTransport.reportedAddress(response.bodyData) {
                localAddressNetwork = network
                try lan.configure(address: ip)
                address = ip
                UserDefaults.standard.set(ip, forKey: "galaxy.lan.address")
                networkDetails = "Trying comma’s current local address. If this hotspot or Wi-Fi network blocks direct access, Bluetooth stays available."
            } else {
                networkDetails = "Comma has no usable local Wi-Fi address. Bluetooth still controls local settings; comma can use its SIM for online downloads."
            }
            // Galaxy's online:true means the server responds, not that comma can reach the internet.
        } catch { /* Discovery is optional; it must not disrupt working BLE. */ }
    }
    private func discoverAutomaticLAN() {
        guard phoneActive, wantsConnection, mode == .automatic,
              !pairingInProgress, !selectingDiscoveredComma, !lan.connected,
              let identity = lan.expectedDeviceID else { return }
        if !discovery.searching, Date().timeIntervalSince(lastLANDiscovery) >= 20 {
            lastLANDiscovery = Date()
            triedLANAddresses.removeAll()
            discovery.start()
        }
        guard automaticLAN == nil else { return }
        let addresses = discovery.devices.map(\.address).filter { !triedLANAddresses.contains($0) }
        guard !addresses.isEmpty else { return }
        triedLANAddresses.formUnion(addresses)
        let generation = lan.generation
        automaticLAN = Task { @MainActor in
            defer { self.automaticLAN = nil }
            let stillCurrent = {
                self.phoneActive && self.wantsConnection && self.mode == .automatic
                    && !self.pairingInProgress && !self.selectingDiscoveredComma && !self.lan.connected
                    && self.lan.generation == generation && self.lan.expectedDeviceID == identity
            }
            let address = await LANDiscoveryMatch.first(addresses: addresses, expectedDeviceID: identity, stillCurrent: stillCurrent) { address, identity in
                let candidate = LANTransport()
                candidate.bind(to: identity)
                guard (try? candidate.configure(address: address)) != nil else { return false }
                return await candidate.probe()
            }
            guard let address, !Task.isCancelled, stillCurrent() else { return }
            do { try self.lan.configure(address: address) } catch { return }
            self.address = address
            UserDefaults.standard.set(address, forKey: "galaxy.lan.address")
            if await self.lan.probe() {
                self.discovery.stop()
                self.connectionLog.record("Automatic Wi-Fi discovery verified the paired comma")
            }
        }
    }

    private func probeLocalConnection() {
        guard lanProbeTask == nil else { return }
        lanProbeTask = Task { @MainActor in
            defer { self.lanProbeTask = nil }
            await self.learnAddress()
            guard !Task.isCancelled, self.wantsConnection, self.mode != .bluetooth else { return }
            if self.lan.endpoint == nil, !self.address.isEmpty {
                do { try self.lan.configure(address: self.address) }
                catch { self.connectionMessage = error.localizedDescription }
            }
            _ = await self.lan.probe()
            if !Task.isCancelled, self.lan.connected { self.discovery.stop() }
        }
    }

    func monitor() async {
        while !Task.isCancelled {
            if wantsConnection && !pairingInProgress {
                if mode != .lan, !bluetooth.connected, !bluetooth.connecting, !bluetooth.isScanning,
                   !pairingKey.isEmpty, Date().timeIntervalSince(lastReconnect) >= bluetooth.reconnectDelay {
                    lastReconnect = Date()
                    bluetooth.reconnectSaved(pairingKey: pairingKey)
                }
                if mode != .bluetooth {
                    discoverAutomaticLAN()
                    probeLocalConnection()
                }
                guard !pairingInProgress else { continue }
                if transport.label != lastRoute { logConnection("Connection availability changed") }
                if transport.connected {
                    openIfReady()
                    if Date().timeIntervalSince(lastGalaxyMatch) > 60 && !openingGalaxy {
                        Task { await self.checkGalaxyUpdates() }
                    }
                    connectionMessage = "Connected over \(transport.label)."
                    if offerAudioPairing { offerAudioPairing = false; startAudioPairing() }
                } else if mode == .bluetooth {
                    connectionMessage = "Reconnecting over Bluetooth. If you forgot this phone on comma, open Pair phone on comma and Pair with comma here."
                } else {
                    connectionMessage = "Wi-Fi unavailable. Pair over Bluetooth below, or check your comma’s IP address."
                }
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }
}


struct GalaxyRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bluetooth: BluetoothTransport
    @ObservedObject var lan: LANTransport
    @ObservedObject var assets: GalaxyAssetStore
    @ObservedObject var server: LoopbackServer
    @ObservedObject var discovery: LANDiscovery
    @ObservedObject var galaxyPage: GalaxyPageDiagnostics
    @ObservedObject private var navigation: NavigationModel
    @State private var hasVisitedGalaxy = false
    @Environment(\.colorScheme) private var systemColorScheme
    private var chromeBackground: LinearGradient {
        let dark = (galaxyColorScheme ?? systemColorScheme) == .dark
        if model.tab == .galaxy {
            let edge = dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.94, green: 0.91, blue: 0.99)
            return LinearGradient(colors: [edge, edge], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: dark
            ? [Color(red: 0.035, green: 0.035, blue: 0.078), Color(red: 0.13, green: 0.07, blue: 0.22)]
            : [Color(red: 0.94, green: 0.91, blue: 0.99), Color(red: 0.87, green: 0.81, blue: 0.96)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var galaxyColorScheme: ColorScheme? {
        guard model.tab == .galaxy, let dark = galaxyPage.darkAppearance else { return nil }
        return dark ? .dark : .light
    }
    private var editorFocused: Bool { model.tab == .galaxy && galaxyPage.landscapeEditor }
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    init(model: AppModel) {
        self.model = model; navigation = model.navigationServices.navigation; bluetooth = model.bluetooth; lan = model.lan; assets = model.assets; server = model.server; discovery = model.discovery; galaxyPage = model.galaxyPage
    }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.opened, let url = server.url {
                    GalaxyWebView(url: url, requestKey: server.localSecret, diagnostics: model.galaxyPage,
                                  isActive: model.tab == .galaxy && scenePhase == .active,
                                  bluetooth: model.transport.label == "Bluetooth") {
                        model.galaxyPage.report(server: server, connection: model.transport.label)
                    }
                        .opacity(model.tab == .galaxy ? 1 : 0)
                        .allowsHitTesting(model.tab == .galaxy)
                        .accessibilityHidden(model.tab != .galaxy)
                } else if model.opened && model.tab == .galaxy {
                    VStack(spacing: 16) {
                        if server.error.isEmpty { ProgressView("Reconnecting Galaxy…") }
                        else { Text(server.error).multilineTextAlignment(.center) }
                        Button("Retry Galaxy") { model.recoverGalaxy(automatic: false) }.buttonStyle(.bordered)
                    }.padding(24)
                }
                if model.tab == .navigation {
                    NavigationHome(connection: model.navigationServices.connection, navigation: model.navigationServices.navigation, saved: model.navigationServices.saved, selectAppTab: select) { select(.connections) }
                } else if model.developerMode && model.tab == .logs {
                    DeveloperLogsView(model: model, log: model.connectionLog)
                } else if model.developerMode && (model.tab == .live || model.tab == .diagnostics) {
                    CompanionView(diagnostics: model.diagnostics)
                } else if model.tab == .connections || !model.opened {
                    ConnectionSettingsView(model: model, returningFromGalaxy: hasVisitedGalaxy, select: select)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !editorFocused && !(model.tab == .navigation && navigation.navigating) {
                CompanionNavigationBar(tab: model.tab, developerMode: model.developerMode, navigation: model.navigationServices.navigation, select: select)
                    .frame(maxWidth: .infinity)


            }
        }
        .background(chromeBackground.ignoresSafeArea())
        .preferredColorScheme(galaxyColorScheme)
        .ignoresSafeArea(.container, edges: editorFocused ? .all : [])
        .statusBarHidden(editorFocused)
        .onChange(of: model.showConnections) { _, show in
            if show { select(.connections); model.showConnections = false }
        }
        .onChange(of: model.showDiagnostics) { _, show in
            if show { if model.developerMode { select(.live) }; model.showDiagnostics = false }
        }
        .onChange(of: bluetooth.connected) { _, connected in if connected { model.openIfReady() } }
        .sheet(isPresented: $model.showAudioPairing, onDismiss: { model.audioPairing.dismiss() }) {
            AudioPairingSheet(pairing: model.audioPairing) { model.showAudioPairing = false }
        }
        .task(id: scenePhase) {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--preview-route") {
                let nav = model.navigationServices.navigation
                let points = [CLLocationCoordinate2D(latitude: 43.6412, longitude: -79.3894), CLLocationCoordinate2D(latitude: 43.6433, longitude: -79.3894), CLLocationCoordinate2D(latitude: 43.6433, longitude: -79.3850)]
                nav.commaPolyline = MKPolyline(coordinates: points, count: points.count)
                nav.commaPosition = points[0]
                nav.usingComma = true; nav.commaFeedReady = true; nav.navigating = true
                nav.instruction = "Turn right onto Bremner Boulevard"
                nav.commaManeuverType = "turn"; nav.commaManeuverModifier = "right"
                nav.distanceToTurn = 240; nav.remainingTime = 1920; nav.remainingDistance = 18200
                let item = MKMapItem(placemark: MKPlacemark(coordinate: points[2])); item.name = "Preview destination"
                nav.destination = NavigationPlace(item: item)
                nav.refreshPreviewPosition()
                model.tab = .navigation
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-galaxy") {
                model.opened = true; model.tab = .galaxy
                return
            }
#endif
            model.setPhoneActive(scenePhase == .active)
            model.navigationServices.setPhoneActive(scenePhase == .active)
            if scenePhase == .active { model.recoverGalaxy(reload: false); await model.checkGalaxyUpdates() }
        }
    }
    private func select(_ requestedTab: CompanionTab) {
        let tab = requestedTab.isDeveloperPage && !model.developerMode ? (model.opened ? CompanionTab.galaxy : .connections) : requestedTab
        if tab != .connections { discovery.stop() }
        model.connectionLog.record("UI tab selected: \(model.tab.rawValue) → \(tab.rawValue)")
        model.tab = tab
        if tab == .galaxy { hasVisitedGalaxy = true; model.applyMatchedGalaxy() }
        model.diagnostics.live = tab == .live
    }
    private let brandPurple = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)


}

private struct CompanionNavigationBar: View {
    let tab: CompanionTab
    let developerMode: Bool
    @ObservedObject var navigation: NavigationModel
    let select: (CompanionTab) -> Void
    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var idleKey: String { "\(tab.rawValue)-\(expanded)-\(navigation.navigating)-\(voiceOver)" }
    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 5) {
                    ForEach([CompanionTab.galaxy, .navigation, .connections]) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 15, weight: .semibold))
                                Text(item.rawValue).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            }.frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle(tab == item ? Color.white : Color.primary.opacity(0.7))
                                .background {
                                    if tab == item {
                                        Capsule().fill(LinearGradient(colors: [Color(red: 0.61, green: 0.39, blue: 0.91), Color(red: 0.40, green: 0.22, blue: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityIdentifier("main-tab-" + item.rawValue)
                            .accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                    if developerMode {
                        Menu {
                            ForEach(CompanionTab.allCases.filter { $0.isDeveloperPage }) { item in
                                Button(item.rawValue, systemImage: item.icon) { select(item) }
                            }
                        } label: {
                            Image(systemName: "ladybug.fill").frame(width: 40, height: 44)
                                .foregroundStyle(StarPilotTheme.accent)
                        }.accessibilityLabel("Developer options")
                    }
                }.padding(5)
            } else {
                Button { expanded = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon).foregroundStyle(StarPilotTheme.accent)
                        Text(tab.rawValue).font(.system(size: 13, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 16).frame(height: 44)
                }.buttonStyle(.plain).accessibilityLabel("Show app tabs").accessibilityIdentifier("expand-app-tabs")
            }
        }
        .modifier(FloatingGalaxyGlass())
        .frame(maxWidth: expanded ? .infinity : nil)
        .padding(.horizontal, 14).padding(.top, expanded ? 5 : 0).padding(.bottom, expanded ? 8 : 4)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86), value: expanded)
        .onChange(of: tab) { _, newTab in if newTab == .connections { expanded = true } }
        .task(id: idleKey) {
            guard expanded, !voiceOver, tab == .galaxy || tab == .navigation else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            expanded = false
        }
    }
}

struct FloatingGalaxyGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(Color.purple.opacity(0.12)), in: .rect(cornerRadius: 24))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.purple.opacity(0.18), lineWidth: 0.5))
        }
    }
}

@MainActor
final class ConnectionEventLog: ObservableObject {
    @Published private(set) var events: [String] = []
    @Published var section = "Connections"
    @Published var detail = ""
    @Published var copied = false
    private var lastEvent = ""
    private let started = Date()
    private var dropped = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    func record(_ event: String) {
        guard event != lastEvent else { return }
        lastEvent = event
        events.append("\(formatter.string(from: Date())) \(event.prefix(1000))")
        if events.count > 3000 { dropped += events.count - 3000; events.removeFirst(events.count - 3000) }
    }
    func clear() { dropped = 0; events.removeAll(); lastEvent = ""; detail = ""; copied = false }
    func report(model: AppModel) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot BT connection diagnostics
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        iOS: \(UIDevice.current.systemVersion)
        Mode: \(model.mode.title)
        Selected route: \(model.transport.label)
        LAN verified: \(model.lan.connected)
        Bluetooth verified: \(model.bluetooth.connected)
        Log session started: \(formatter.string(from: started)); retained: \(events.count); older events dropped: \(dropped)
        Current screen: \(model.tab.rawValue)
        GPS sharing: \(model.phoneLocation.sharing); \(model.phoneLocation.diagnosticSummary)
        \(model.navigationServices.navigation.diagnosticSummary)
        Recent connection events:
        \(events.joined(separator: "\n"))
        """
    }
}

private struct DeveloperLogsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: ConnectionEventLog
    private func selectedReport() -> String {
        switch log.section {
        case "Galaxy": return model.galaxyPage.report(server: model.server, connection: model.transport.label)
        case "Live View": return model.diagnostics.diagnosticLog()
        default: return log.report(model: model)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Dev / Logs").font(.title2.bold())
                Text("Recent events stay in memory. Reports are shared only when you copy them.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Picker("Report", selection: $log.section) {
                    ForEach(["Connections", "Galaxy", "Live View"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                HStack {
                    Button(log.copied ? "Copied" : "Copy report", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = selectedReport(); log.copied = true
                    }.buttonStyle(.borderedProminent).tint(.purple)
                    Button("Refresh") { log.detail = selectedReport(); log.copied = false }.buttonStyle(.bordered)
                }
                Button("Copy all reports") {
                    UIPasteboard.general.string = [log.report(model: model), model.galaxyPage.report(server: model.server, connection: model.transport.label), model.diagnostics.diagnosticLog(), "Galaxy screen updates\n" + model.assets.status].joined(separator: "\n\n")
                    log.copied = true
                }
                Text(log.section == "Connections" ? log.report(model: model) : log.detail)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button("Clear connection history") { log.clear(); log.detail = selectedReport() }
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Color(uiColor: .systemBackground))
            .onAppear { log.detail = selectedReport() }
            .onChange(of: log.section) { _, _ in log.detail = selectedReport(); log.copied = false }
    }
}
