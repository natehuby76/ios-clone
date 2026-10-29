import SwiftUI
import Network
import MapKit
import CoreBluetooth

@main
struct GalaxyBluetoothApp: App {
    @StateObject private var model = AppModel.shared
    @AppStorage("galaxy.app.language") private var language = "en"
    var body: some Scene { WindowGroup { GalaxyRootView(model: model).environment(\.locale, Locale(identifier: language)) } }
}

enum CompanionTab: String, CaseIterable, Identifiable {
    case galaxy = "Galaxy", navigation = "Navigation", live = "Live View", diagnostics = "Diagnostics", logs = "Logs & support", connections = "Settings"
    var id: String { rawValue }
    var isDeveloperPage: Bool { self == .live || self == .diagnostics }
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
                navigationAlpha = false
                if tab.isDeveloperPage { tab = opened ? .galaxy : .connections }
                diagnostics.live = false
                diagnostics.phoneVisible = false
                showDiagnostics = false
            }
        }
    }
    @Published var navigationAlpha = UserDefaults.standard.bool(forKey: "galaxy.app.developerMode") && UserDefaults.standard.bool(forKey: "galaxy.app.navigationAlpha") {
        didSet {
            UserDefaults.standard.set(navigationAlpha, forKey: "galaxy.app.navigationAlpha")
            navigationServices.setEnabled(navigationAlpha && developerMode)
            if !navigationAlpha && tab == .navigation { tab = opened ? .galaxy : .connections }
        }
    }
    var navigationEnabled: Bool { developerMode && navigationAlpha }
    var connectionSetupBusy: Bool { pairingInProgress || offerAudioPairing || showAudioPairing }
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
    func setPhoneActive(_ active: Bool) { connectionLog.record("Lifecycle: phone active=\(active); tab=\(tab.rawValue); navigation=\(navigationActive)"); phoneActive = active; if !active { automaticLAN?.cancel(); firstConnection?.cancel(); firstConnection = nil }; diagnostics.phoneActive = active; discovery.setActive(active); updateMonitoring() }
    func setCarPlayActive(_ active: Bool) { carPlayActive = active; diagnostics.carPlayActive = active; updateMonitoring() }
    private func updateMonitoring() {
        // Sharing phone GPS keeps the app running in the background, so keep reconnecting too.
        if phoneActive || carPlayActive || phoneLocation.sharing || navigationActive {
            if monitorTask == nil { monitorTask = Task { await monitor() } }
        } else { monitorTask?.cancel(); monitorTask = nil; tunnelProbeTask?.cancel() }
    }
    @Published var pairingKey = PairingKeyStore.load()
    @Published var address = UserDefaults.standard.string(forKey: "galaxy.lan.address") ?? ""
    @Published var findAddressAutomatically = UserDefaults.standard.object(forKey: "galaxy.lan.auto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(findAddressAutomatically, forKey: "galaxy.lan.auto") }
    }
    @Published var networkDetails = "Comma can use a hotspot, Wi-Fi or its SIM for internet. Your connection here controls how this iPhone reaches comma."
    @Published var mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "galaxy.connection.mode") ?? "") ?? .automatic {
        didSet {
            automaticLAN?.cancel(); lanProbeTask?.cancel(); firstConnection?.cancel(); firstConnection = nil
            transport.mode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "galaxy.connection.mode")
            if mode == .lan { bluetooth.disconnect() }
            if mode == .bluetooth { discovery.stop(); lan.invalidate(reason: "Bluetooth-only mode selected") }
            if mode != .automatic { tunnelProbeTask?.cancel(); tunnel.invalidate("Tunnel paused in " + mode.title) }
            logConnection("Connection mode selected: \(mode.title)")
        }
    }
    @Published var connectionPriority = ConnectionRoute.normalized(UserDefaults.standard.stringArray(forKey: "galaxy.connection.priority") ?? []) {
        didSet {
            transport.priority = connectionPriority
            UserDefaults.standard.set(connectionPriority.map(\.rawValue), forKey: "galaxy.connection.priority")
            logConnection("Connection order changed")
        }
    }
    var connectionSession: String {
        switch transport.selectedRoute {
        case .lan: "lan-" + lan.generation
        case .tunnel: "tunnel-" + tunnel.generation
        case .bluetooth: "ble-" + bluetooth.sessionIdentifier
        case nil: "disconnected"
        }
    }
    private var tunnelProbeTask: Task<Void, Never>?
    private var lastTunnelProbe = Date.distantPast
    func forgetTunnel() {
        tunnelProbeTask?.cancel()
        tunnel.forget(); TunnelKeyStore.remove()
    }
    func acceptTunnel(url: URL, cookie: String) async throws {
        let candidate = TunnelTransport()
        let previousIdentity = lan.expectedDeviceID
        candidate.expectedDeviceID = previousIdentity
        try candidate.configure(TunnelCredential(url: url.absoluteString, cookie: cookie, deviceID: ""))
        guard await candidate.probe(), let credential = candidate.credential else { throw BridgeError.message(candidate.status) }
        try Task.checkCancellation()
        guard lan.expectedDeviceID == previousIdentity else {
            throw BridgeError.message("This tunnel belongs to a different comma.")
        }
        try TunnelKeyStore.save(credential)
        tunnelProbeTask?.cancel()
        try tunnel.configure(credential)
        lan.bind(to: credential.deviceID)
        UserDefaults.standard.set(credential.deviceID, forKey: "galaxy.comma.identity")
        tunnel.expectedDeviceID = lan.expectedDeviceID
        wantsConnection = true
        mode = .automatic
        lastTunnelProbe = .distantPast
        probeTunnelConnection()
    }
    private func probeTunnelConnection() {
        guard mode == .automatic, (phoneActive || carPlayActive || navigationActive || phoneLocation.sharing), wantsConnection, tunnel.credential != nil,
              tunnelProbeTask == nil, Date().timeIntervalSince(lastTunnelProbe) >= 30 else { return }
        lastTunnelProbe = Date()
        if tunnel.expectedDeviceID != lan.expectedDeviceID {
            tunnel.expectedDeviceID = lan.expectedDeviceID
            tunnel.invalidate("Comma identity changed")
        }
        tunnelProbeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.tunnelProbeTask = nil }
            let previousIdentity = self.tunnel.expectedDeviceID
            if await self.tunnel.probe(), let credential = self.tunnel.credential {
                try? TunnelKeyStore.save(credential)
                if self.lan.expectedDeviceID == previousIdentity {
                    self.lan.bind(to: credential.deviceID)
                    UserDefaults.standard.set(credential.deviceID, forKey: "galaxy.comma.identity")
                }
            }
            self.objectWillChange.send()
        }
    }
    @Published var showConnections = false
    @Published var pairingInProgress = false
    @Published var pairingFailure = ""
    @Published var showBluetoothPermission = false
    @Published var opened = false
    @Published var connectionMessage = "Choose a connection, or use Automatic to follow your connection priority."
    @Published var wantsConnection = true
    @Published var loadingLegacyURL = false
    @Published var legacyMessage = ""
    @Published var legacyURL: URL?
    let bluetooth: BluetoothTransport
    let lan: LANTransport
    let tunnel: TunnelTransport
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
    private var initialDiscoveryStarted = false
    private var firstConnection: Task<Void, Never>?
    private var openAfterFirstConnection = false
    private var automaticLAN: Task<Void, Never>?
    private var lanProbeTask: Task<Void, Never>?
    private var lastLANDiscovery = Date.distantPast
    private var triedLANAddresses = Set<String>()
    /// One step for the app and music: comma's open pairing window gives this iPhone its key, then music is set up in the same window.
    private var pairingTask: Task<Void, Never>?
    var hasLANPairingSetup: Bool {
        lan.expectedDeviceID != nil && (try? LANTransport.endpoint(address)) != nil
    }
    func pairWithComma() {
        guard !pairingInProgress else { return }
        guard hasLANPairingSetup else {
            pairingFailure = "Connect to your comma over Local Wi-Fi first, then set up Bluetooth."
            connectionMessage = pairingFailure
            return
        }
        pairingInProgress = true
        pairingFailure = ""
        offerAudioPairing = false
        showAudioPairing = false
        bluetooth.disconnect(reason: "Starting new phone pairing")
        connectionMessage = "Preparing Bluetooth setup over Local Wi-Fi…"
        pairingTask = Task { @MainActor in
            defer { pairingInProgress = false; pairingTask = nil }
            do {
                // Bluetooth-only invalidates the normal LAN session. Use a separate, identity-checked
                // connection just for opening the pairing window; do not change the selected route.
                let pairingLAN = LANTransport()
                pairingLAN.bind(to: lan.expectedDeviceID)
                if !lan.connected, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    connectionMessage = "Checking comma over Local Wi-Fi before Bluetooth pairing…"
                    try pairingLAN.configure(address: address)
                    _ = await pairingLAN.probe()
                }
                try Task.checkCancellation()
                let windowLAN = lan.connected ? lan : pairingLAN
                guard windowLAN.connected else {
                    throw BridgeError.message("Connect to your comma over Local Wi-Fi first. Its saved LAN address could not be verified.")
                }
                // Bind the Bluetooth reply to the comma whose LAN pairing window we open.
                let adapterResponse = try? await windowLAN.request(path: "/api/bluetooth/status", method: "GET", headers: [:], body: Data())
                let adapter = adapterResponse.flatMap { $0.status == 200 ? AudioPairing.parse($0.bodyData) : nil }
                let expectedAdapter = adapter.flatMap { AudioPairing.validAddress($0.adapterAddress) ? $0.adapterAddress : nil }
                try Task.checkCancellation()
                connectionLog.record("Pairing target adapter verification available=\(expectedAdapter != nil)")
                connectionLog.record("Opening phone pairing window over verified LAN")
                guard try await LANPairing.openWindow(over: windowLAN, progress: { self.connectionMessage = $0 }) else {
                    throw BridgeError.message("Local Wi-Fi disconnected before Bluetooth setup. Reconnect to comma over Local Wi-Fi and try again.")
                }
                connectionMessage = "Opened comma’s pairing window over Local Wi-Fi. Looking for comma…"
                connectionLog.record("Phone pairing window opened over verified LAN")
                try Task.checkCancellation()
                importClaim(try await claimer.claim(name: UIDevice.current.name, expectedAdapterAddress: expectedAdapter))
            }
            catch is CancellationError { connectionMessage = "Pairing cancelled." }
            catch {
                pairingFailure = error.localizedDescription
                connectionMessage = pairingFailure
                connectionLog.record("Phone pairing preparation or claim failed: " + error.localizedDescription)
            }
        }
    }
    func cancelPairing() { pairingTask?.cancel(); claimer.cancel() }
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
        let tunnel = TunnelTransport()
        let transport = PreferredTransport(lan: lan, bluetooth: bluetooth, tunnel: tunnel, invalidateTunnel: { tunnel.invalidate($0) }, invalidateLAN: { lan.invalidate(reason: $0) })
        let assets = GalaxyAssetStore()
        self.bluetooth = bluetooth; self.lan = lan; self.tunnel = tunnel; self.transport = transport; self.assets = assets
        lan.bind(to: UserDefaults.standard.string(forKey: "galaxy.comma.identity"))
        if let credential = TunnelKeyStore.load() { try? tunnel.configure(credential) }
        tunnel.expectedDeviceID = lan.expectedDeviceID
        let cache = GalaxyReadCache(transport: transport, sessionID: {
            transport.selectedRoute == .tunnel ? "tunnel-" + tunnel.generation : transport.usesLAN ? "lan-" + lan.generation : "ble-" + bluetooth.sessionIdentifier
        })
        server = LoopbackServer(transport: cache, webRoot: assets.readyRoot)
        transport.mode = mode
        transport.priority = connectionPriority
        diagnostics.transport = transport; diagnostics.lan = lan
        galaxyPage.recover = { [weak self] automatic in self?.recoverGalaxy(automatic: automatic) }
        server.start()
        discovery.onEvent = { [weak self] reason in self?.connectionLog.record(reason) }
        discovery.onDevicesChanged = { [weak self] in self?.discoverAutomaticLAN() }
        lan.onDiagnostic = { [weak self] in self?.connectionLog.record($0) }
        tunnel.onDiagnostic = { [weak self] in self?.connectionLog.record($0) }
        tunnel.onEvent = { [weak self] reason in self?.objectWillChange.send(); self?.logConnection(reason) }
        lan.onEvent = { [weak self] reason in
            guard let self else { return }
            if self.lan.connected, let identity = self.lan.verifiedDeviceID {
                UserDefaults.standard.set(identity, forKey: "galaxy.comma.identity")
            }
            if self.tunnel.expectedDeviceID != self.lan.expectedDeviceID {
                self.tunnel.expectedDeviceID = self.lan.expectedDeviceID
                self.tunnel.invalidate("Comma identity changed")
            }
            self.logConnection(reason)
        }
        bluetooth.onEvent = { [weak self] reason in self?.logConnection(reason) }
        claimer.onEvent = { [weak self] reason in
            guard let self else { return }
            self.connectionLog.record(reason)
            if self.pairingInProgress {
                if reason == "Phone pairing started" { self.connectionMessage = "Starting Bluetooth…" }
                else if reason == "Phone pairing found comma; connecting" { self.connectionMessage = "Connecting to comma…" }
                else if reason == "Phone pairing connected; discovering service" { self.connectionMessage = "Checking Bluetooth service…" }
            }
        }
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
                self.firstConnection?.cancel(); self.firstConnection = nil
                self.initialDiscoveryStarted = false
                self.discovery.networkChanged()
                self.triedLANAddresses.removeAll()
                self.lastLANDiscovery = .distantPast
                self.lan.invalidate(reason: reason)
                self.tunnelProbeTask?.cancel()
                self.tunnel.invalidate("Network changed")
                self.lastTunnelProbe = .distantPast
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
            } else if mode != .bluetooth {
                discovery.start()
            }
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "galaxy.lan.address")
            wantsConnection = true
            lastReconnect = .distantPast
            lastTunnelProbe = .distantPast
            lastAddressCheck = .distantPast
            localAddressNetwork = ""
            connectionMessage = "Checking your comma…"
        } catch { connectionMessage = error.localizedDescription }
    }
    func startAudioPairing() {
        guard transport.connected else { return }
        audioPairing.onEvent = { [weak self] event in self?.connectionLog.record(event) }
        connectionLog.record("Music setup using " + transport.label)
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

    private var softwareReportSession = ""
    private var softwareReport = "Comma software: unavailable; no verified connection has reported it yet."
    private var softwareReportDate: Date?
    var commaSoftwareDiagnostics: String {
        guard let date = softwareReportDate else { return softwareReport }
        return softwareReport + "\nSoftware observed: " + ISO8601DateFormatter().string(from: date)
            + "\nSoftware snapshot matches current connection: " + String(transport.connected && softwareReportSession == connectionSession)
    }
    private func collectSoftwareDiagnostics() async {
        let session = connectionSession
        guard transport.connected, softwareReportSession != session else { return }
        softwareReportSession = session
        do {
            let response = try await transport.request(path: "/api/software/status?history=0", method: "GET", headers: [:], body: Data())
            guard connectionSession == session else { return }
            guard response.status == 200,
                  let json = try JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any],
                  let installed = json["installed"] as? [String: Any] else {
                softwareReport = "Comma software: unavailable (HTTP \(response.status) or unsupported response)."
                softwareReportDate = Date(); return
            }
            func field(_ value: Any?) -> String {
                guard let text = value as? String, !text.isEmpty else { return "not reported" }
                return String(text.filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(160))
            }
            let operations = json["operations"] as? [String: Any]
            let repository = (operations?["repository"] ?? json["repository"]) as? String
            // Only report owner/repo, never a remote URL containing credentials.
            let safeRepo = repository.flatMap { $0.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil ? $0 : nil }
            softwareReport = "Comma repository: \(field(safeRepo))\nComma branch: \(field(installed["branch"]))\nComma version: \(field(installed["version"]))\nComma display version: \(field(installed["displayVersion"]))\nComma commit: \(field(installed["commit"]))\nRestart history: not reported by this endpoint; a runtime-instance change alone does not prove a full device reboot."
            softwareReportDate = Date()
        } catch {
            guard connectionSession == session else { return }
            softwareReport = "Comma software: unavailable (" + LANTransport.failureCode(error) + ")."
            softwareReportDate = Date()
        }
    }

    func checkGalaxyUpdates() async {
        guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected, !matchingGalaxy else { return }
        matchingGalaxy = true
        lastGalaxyMatch = Date()
        defer { matchingGalaxy = false }
        let session = connectionSession
        await collectSoftwareDiagnostics()
        guard connectionSession == session, transport.connected else { return }
        let stillCurrent = { self.wantsConnection && self.transport.connected && self.connectionSession == session }
        if transport.usesNetwork {
            // Pages come straight from comma, never through the Bluetooth bridge or the read cache.
            let lan = self.transport
            await assets.check(fetch: { path, _ in
                let response = path.hasPrefix("/api/") ? try await lan.request(path: path, method: "GET", headers: [:], body: Data()) : try await lan.page(path: path)
                return (response.status, response.bodyData)
            }, stillCurrent: stillCurrent)
        } else if assets.readyRoot != nil {
            // Over Bluetooth nothing can be downloaded; just say when the saved screens are behind comma.
            guard let response = try? await transport.request(path: "/api/software/status?history=0", method: "GET", headers: [:], body: Data()),
                  response.status == 200, stillCurrent(),
                  let status = try? JSONSerialization.jsonObject(with: response.bodyData) as? [String: Any],
                  let installed = status["installed"] as? [String: Any] else { return }
            assets.noteCommaBuild(commit: installed["commit"] as? String)
        }
    }
    func openIfReady() {
        guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected, !opened, !openingGalaxy else { return }
        openingGalaxy = true
        Task { @MainActor in
            defer { openingGalaxy = false }
            if transport.usesNetwork ? Date().timeIntervalSince(lastGalaxyMatch) > 15 : assets.readyRoot != nil && !matchingGalaxy {
                await checkGalaxyUpdates()
            }
            guard wantsConnection, !pairingInProgress, !offerAudioPairing, !showAudioPairing, transport.connected, !opened else { return }
            // Bluetooth Galaxy runs from screens saved from comma; the first download needs Wi-Fi/LAN.
            // Over Wi-Fi/LAN an older comma that cannot share its screens still opens, read live.
            guard let root = assets.readyRoot else {
                guard transport.usesNetwork else { return }
                assets.inUseRoot = nil
                opened = true
                finishFirstConnection()
                return
            }
            assets.inUseRoot = root
            server.useWebRoot(root)
            opened = true
            finishFirstConnection()
        }
    }
    private func finishFirstConnection() {
        guard openAfterFirstConnection else { return }
        openAfterFirstConnection = false
        if tab == .connections { tab = .galaxy }
    }
    func disconnect() {
        legacyURL = nil
        automaticLAN?.cancel(); lanProbeTask?.cancel()
        discovery.stop()
        firstConnection?.cancel(); firstConnection = nil; openAfterFirstConnection = false
        tunnelProbeTask?.cancel(); tunnel.invalidate("Disconnected")
        wantsConnection = false; opened = false
        bluetooth.disconnect(reason: "User selected Disconnect"); lan.invalidate(reason: "User selected Disconnect")
        connectionMessage = "Disconnected."
    }
    func selectDiscoveredComma(_ device: DiscoveredComma, userSelected: Bool = true) async -> Bool {
        guard !selectingDiscoveredComma, mode != .bluetooth else { return false }
        selectingDiscoveredComma = true
        automaticLAN?.cancel()
        lanProbeTask?.cancel()
        discovery.stop()
        defer { selectingDiscoveredComma = false }
        // Advertised names and addresses are discovery hints, not pairing credentials.
        let candidate = LANTransport()
        candidate.onEvent = { [weak self] event in
            self?.connectionLog.record("Selected comma \(device.address): \(event)")
        }
        connectionLog.record("Checking selected comma at \(device.address):8082")
        // Explicit local-only selection can recover an old runtime pin or choose another comma.
        // Never apply that permission to background discovery or another saved transport.
        if !userSelected || !pairingKey.isEmpty || tunnel.credential != nil {
            candidate.bind(to: lan.expectedDeviceID)
        }
        let originalGeneration = lan.generation
        let originalMode = mode
        do {
            try candidate.configure(address: device.address)
            guard await candidate.probe() else {
                connectionMessage = "Couldn’t connect to \(device.address): \(candidate.status)"
                connectionLog.record("Selected comma \(device.address) rejected: \(candidate.status)")
                return false
            }
            guard !Task.isCancelled, lan.generation == originalGeneration, mode == originalMode, phoneActive else {
                connectionMessage = "Connection changed. Select the comma again."
                return false
            }
            lan.bind(to: candidate.verifiedDeviceID)
            UserDefaults.standard.set(candidate.verifiedDeviceID, forKey: "galaxy.comma.identity")
            address = device.address
            connect()
            guard await lan.probe() else {
                connectionMessage = "Couldn’t connect to \(device.address): \(lan.status)"
                return false
            }
            openIfReady()
            connectionLog.record("Discovered comma selected; LAN verification passed")
            return true
        } catch {
            connectionMessage = "Couldn’t connect to the discovered comma. Try again or enter its IP."
            return false
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
            if identitySession != session || !lan.connected {
                let identity = try await bluetooth.request(path: "/data/runtime.json", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session else { return }
                // Only the authenticated BLE peer may establish the automatic LAN identity.
                guard identity.status == 200, let value = LANTransport.deviceID(identity.bodyData) else {
                    networkDetails = "Automatic local discovery needs a registered device identifier. Bluetooth still works; enter comma’s IP manually for Local Wi-Fi."
                    return
                }
                let status = try? await bluetooth.request(path: "/api/galaxy/status", method: "GET", headers: [:], body: Data())
                guard !Task.isCancelled, wantsConnection, mode != .bluetooth, bluetooth.sessionIdentifier == session else { return }
                let persistent = status.flatMap { $0.status == 200 ? LANTransport.persistentIdentity($0.bodyData) : nil }
                let verified = persistent ?? value
                lan.bind(to: verified)
                UserDefaults.standard.set(verified, forKey: "galaxy.comma.identity")

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
        guard phoneActive, wantsConnection, mode != .bluetooth, !connectionSetupBusy,
              !selectingDiscoveredComma, !lan.connected else { return }
        if lan.expectedDeviceID == nil && pairingKey.isEmpty {
            if !initialDiscoveryStarted {
                initialDiscoveryStarted = true
                discovery.start()
            }
            guard firstConnection == nil, discovery.devices.count == 1 else { return }
            let candidate = discovery.devices[0]
            firstConnection = Task { @MainActor in
                defer { self.firstConnection = nil }
                // Allow other advertisements to arrive before choosing an unpaired device.
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard self.phoneActive, self.wantsConnection, self.mode != .bluetooth,
                      !self.connectionSetupBusy, self.lan.expectedDeviceID == nil,
                      self.pairingKey.isEmpty, self.discovery.devices.count == 1,
                      self.discovery.devices[0].id == candidate.id else { return }
                self.connectionLog.record("First setup: verifying the only discovered comma")
                self.openAfterFirstConnection = true
                if !(await self.selectDiscoveredComma(candidate, userSelected: false)) { self.openAfterFirstConnection = false }
            }
            return
        }
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
                self.connectionLog.record("Automatic Local Wi-Fi discovery verified the paired comma")
            }
        }
    }

    private func probeLocalConnection() {
        guard !selectingDiscoveredComma, lanProbeTask == nil else { return }
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
            if wantsConnection && !pairingInProgress && !selectingDiscoveredComma {
                if mode != .lan, !bluetooth.connected, !bluetooth.connecting, !bluetooth.isScanning,
                   !pairingKey.isEmpty, Date().timeIntervalSince(lastReconnect) >= bluetooth.reconnectDelay {
                    lastReconnect = Date()
                    bluetooth.reconnectSaved(pairingKey: pairingKey)
                }
                if mode != .bluetooth && !offerAudioPairing && !showAudioPairing {
                    discoverAutomaticLAN()
                    probeLocalConnection()
                    probeTunnelConnection()
                }
                guard !pairingInProgress else { continue }
                if transport.label != lastRoute { logConnection("Connection availability changed") }
                if transport.connected {
                    if offerAudioPairing { offerAudioPairing = false; startAudioPairing() }
                    if !showAudioPairing {
                        openIfReady()
                        if Date().timeIntervalSince(lastGalaxyMatch) > 60 && !openingGalaxy {
                            Task { await self.checkGalaxyUpdates() }
                        }
                    }
                    connectionMessage = "Connected over \(transport.label)." + (opened || assets.readyRoot != nil ? "" : " " + assets.status)
                } else if mode == .bluetooth {
                    connectionMessage = "Reconnecting over Bluetooth. If you removed this phone’s pairing, connect over Local Wi-Fi.\nThen set up Bluetooth again in this app."
                } else {
                    connectionMessage = discovery.searching || lan.endpoint == nil
                        ? discovery.status
                        : "Comma is not reachable on the local network yet. Use the same Wi-Fi or connect comma to this iPhone’s hotspot, then search again."
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
    @State private var appTabsExpanded = true
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                        .ignoresSafeArea(.container, edges: .bottom)
                        .overlay(alignment: .top) {
                            if !editorFocused {
                                let dark = (galaxyColorScheme ?? systemColorScheme) == .dark
                                let edge = dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.94, green: 0.91, blue: 0.99)
                                LinearGradient(colors: [edge, edge.opacity(0)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 16).allowsHitTesting(false).accessibilityHidden(true)
                            }
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
                if model.navigationEnabled && model.tab == .navigation {
                    NavigationHome(connection: model.navigationServices.connection, navigation: model.navigationServices.navigation, saved: model.navigationServices.saved, selectAppTab: select) { select(.connections) }
                } else if model.tab == .logs {
                    DeveloperLogsView(model: model, log: model.connectionLog, back: { select(.connections) })
                } else if model.developerMode && (model.tab == .live || model.tab == .diagnostics) {
                    CompanionView(diagnostics: model.diagnostics)
                } else if model.tab == .connections || !model.opened {
                    ConnectionSettingsView(model: model, returningFromGalaxy: hasVisitedGalaxy, select: select)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)

        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !editorFocused && model.tab != .navigation {
                CompanionNavigationBar(tab: model.tab, developerMode: model.developerMode,
                    navigation: model.navigationServices.navigation, expanded: $appTabsExpanded,
                    compactIconOnly: true, statusModel: model, select: select)
                    .padding(.horizontal, 14).padding(.vertical, 0)


            }
        }
        .background {
            if model.navigationEnabled { chromeBackground.ignoresSafeArea() }
            else { Color(uiColor: .systemBackground).ignoresSafeArea() }
        }
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
        .alert("Bluetooth access needed", isPresented: $model.showBluetoothPermission) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text(model.pairingFailure)
        }
        .task(id: scenePhase) {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--preview-route") {
                model.developerMode = true; model.navigationAlpha = true
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
            model.navigationServices.setEnabled(model.navigationEnabled)
            model.navigationServices.setPhoneActive(scenePhase == .active)
            if scenePhase == .active { model.recoverGalaxy(reload: false); await model.checkGalaxyUpdates() }
        }
    }
    private func select(_ requestedTab: CompanionTab) {
        let tab = (requestedTab.isDeveloperPage && !model.developerMode) || (requestedTab == .navigation && !model.navigationEnabled) ? (model.opened ? CompanionTab.galaxy : .connections) : requestedTab
        if tab == .connections { appTabsExpanded = true }
        if tab != .connections { discovery.stop() }
        model.connectionLog.record("UI tab selected: \(model.tab.rawValue) → \(tab.rawValue)")
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { model.tab = tab }
        if tab == .galaxy { hasVisitedGalaxy = true; model.applyMatchedGalaxy() }
        model.diagnostics.live = tab == .live
    }
    private let brandPurple = Color(red: 139.0 / 255, green: 92.0 / 255, blue: 246.0 / 255)


}

struct CompanionNavigationBar: View {
    let tab: CompanionTab
    let developerMode: Bool
    @ObservedObject var navigation: NavigationModel
    @Binding var expanded: Bool
    var compactIconOnly = false
    var statusModel: AppModel? = nil
    let select: (CompanionTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    private var idleKey: String { "\(tab.rawValue)-\(expanded)-\(navigation.navigating)-\(voiceOver)" }
    var body: some View {
        GeometryReader { geometry in
            // Keep both content trees alive at their natural sizes. Only the glass
            // envelope and transforms animate; labels never squeeze and reflow.
            ZStack(alignment: .leading) {
                HStack(spacing: 5) {
                    ForEach(statusModel?.navigationEnabled == false ? [CompanionTab.galaxy, .connections] : [CompanionTab.galaxy, .navigation, .connections]) { item in
                        Button { select(item) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: item.icon).font(.system(size: 15, weight: .semibold))
                                Text(LocalizedStringKey(item.rawValue)).font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                            }.frame(maxWidth: .infinity).frame(height: 44)
                                .foregroundStyle((tab == item || (tab == .logs && item == .connections)) ? Color.white : Color.primary.opacity(0.7))
                                .background {
                                    if tab == item || (tab == .logs && item == .connections) {
                                        Capsule().fill(LinearGradient(colors: [Color(red: 0.61, green: 0.39, blue: 0.91), Color(red: 0.40, green: 0.22, blue: 0.69)], startPoint: .topLeading, endPoint: .bottomTrailing))
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityIdentifier("main-tab-" + item.rawValue)
                            .accessibilityAddTraits((tab == item || (tab == .logs && item == .connections)) ? .isSelected : [])
                    }

                }.padding(3)
                    .padding(.trailing, statusModel == nil ? 0 : 32)
                    .frame(width: geometry.size.width)
                    .scaleEffect(x: expanded ? 1 : 0.18, y: expanded ? 1 : 0.65, anchor: .leading)
                    .opacity(expanded ? 1 : 0)
                    .allowsHitTesting(expanded).accessibilityHidden(!expanded)
                Button { setExpanded(true) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: tab.icon).foregroundStyle(StarPilotTheme.accent)
                        if !compactIconOnly { Text(tab.rawValue).font(.system(size: 13, weight: .semibold)) }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }.frame(width: compactWidth, height: 46)
                }.buttonStyle(.plain).accessibilityLabel("Show app tabs").accessibilityIdentifier("expand-app-tabs")
                    .opacity(expanded ? 0 : 1)
                    .scaleEffect(expanded ? 0.8 : 1, anchor: .leading)
                    .allowsHitTesting(!expanded).accessibilityHidden(expanded)
            }
            .frame(width: expanded ? geometry.size.width : compactWidth, height: 46, alignment: .leading)
            .clipped()
            .modifier(FloatingGalaxyGlass())
            .frame(width: geometry.size.width, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let statusModel {
                    CompactConnectionStatus(model: statusModel, compact: expanded) { select(.connections) }
                        .padding(.trailing, expanded ? 5 : 0)
                }
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 46)
        .onChange(of: tab) { _, newTab in if newTab == .connections { setExpanded(true) } }
        .task(id: idleKey) {
            guard expanded, !voiceOver, tab == .galaxy || tab == .navigation else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            setExpanded(false)
        }
    }
    private var compactWidth: CGFloat { compactIconOnly ? 56 : 168 }
    private func setExpanded(_ value: Bool) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.82)) { expanded = value }
    }
}

/// Displays the selected verified transport, not Wi-Fi availability or a saved address.
struct CompactConnectionStatus: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var bluetooth: BluetoothTransport
    @ObservedObject private var lan: LANTransport
    @ObservedObject private var tunnel: TunnelTransport
    let openSettings: () -> Void
    var compact: Bool

    init(model: AppModel, compact: Bool = false, openSettings: @escaping () -> Void) {
        self.model = model
        self.compact = compact
        bluetooth = model.bluetooth
        lan = model.lan
        tunnel = model.tunnel
        self.openSettings = openSettings
    }

    private var label: String {
        switch model.transport.selectedRoute {
        case .bluetooth: return "Bluetooth"
        case .lan: return lan.endpoint?.host ?? "Local Wi-Fi"
        // Tunnel links may contain private access codes. Never display the link here.
        case .tunnel: return "Tunnel"
        case nil: return bluetooth.connecting || bluetooth.isScanning ? "Connecting…" : "Disconnected"
        }
    }
    private var tint: Color {
        model.transport.connected ? .green : bluetooth.connecting || bluetooth.isScanning ? .orange : .secondary
    }
    var body: some View {
        Button(action: openSettings) {
            HStack(spacing: compact ? 0 : 7) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(label).font(.system(size: 13, weight: .medium))
                    .monospacedDigit().lineLimit(1).truncationMode(.middle)
                    .frame(width: compact ? 0 : nil).opacity(compact ? 0 : 1)
                    .clipped()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12).frame(height: 44)
            .background {
                Capsule().fill(.regularMaterial).opacity(compact ? 0 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection settings")
        .accessibilityValue(model.transport.connected ? "Connected via " + label : label)
        .accessibilityIdentifier("bluetooth-connection-status")
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
    private var storage = Array(repeating: "", count: 3000)
    private var nextEvent = 0
    private var retained = 0
    private var sequence = 0
    private var repeats = 0
    private let uptime = ProcessInfo.processInfo.systemUptime
    var events: [String] {
        let start = retained == storage.count ? nextEvent : 0
        return (0..<retained).map { storage[(start + $0) % storage.count] }
    }
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
    // Error descriptions can contain private tunnel URLs or key material.
    private static let privateValues = try! NSRegularExpression(pattern:
        #"https?://[^\s]+|\b[0-9a-fA-F]{64}\b|(?i:bearer)\s+[^\s]+"#)
    private static func redact(_ text: String) -> String {
        privateValues.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "[redacted]")
    }
    // No published changes or disk/network work on the connection callback path.
    func record(_ event: String) {
        let bounded = Self.redact(String(event.prefix(1000)))
        guard bounded != lastEvent else { repeats += 1; return }
        if repeats > 0 { append("Previous event repeated \(repeats) additional times"); repeats = 0 }
        lastEvent = bounded
        append(bounded)
    }
    private func append(_ event: String) {
        sequence += 1
        let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - uptime)
        storage[nextEvent] = "\(formatter.string(from: Date())) #\(sequence) +\(elapsed)s \(event)"
        nextEvent = (nextEvent + 1) % storage.count
        if retained == storage.count { dropped += 1 } else { retained += 1 }
    }
    func clear() {
        storage = Array(repeating: "", count: 3000)
        nextEvent = 0; retained = 0; dropped = 0; repeats = 0
        lastEvent = ""; detail = ""; copied = false
    }
    func report(model: AppModel, eventLimit: Int? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return """
        StarPilot BT connection diagnostics
        \(ISO8601DateFormatter().string(from: Date()))
        App: \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?"))
        iOS: \(UIDevice.current.systemVersion)
        Mode: \(model.mode.title)
        Selected route: \(model.transport.label)
        Tunnel verified: \(model.tunnel.connected)
        Tunnel status: \(model.tunnel.status)
        Connection order: \(model.connectionPriority.map(\.title).joined(separator: " → "))
        \(model.commaSoftwareDiagnostics)
        Saved comma identity: \(model.lan.expectedDeviceID ?? "none")
        LAN verified: \(model.lan.connected)
        Bluetooth verified: \(model.bluetooth.connected)
        Log session started: \(formatter.string(from: started)); retained: \(retained); older events dropped: \(dropped); pending repeated events: \(repeats)
        Current screen: \(model.tab.rawValue)
        GPS sharing: \(model.phoneLocation.sharing); \(model.phoneLocation.diagnosticSummary)
        \(model.navigationServices.navigation.diagnosticSummary)
        Bluetooth permission: \(CBManager.authorization)
        Discovery: searching=\(model.discovery.searching); results=\(model.discovery.devices.count)
        Discovery status: \(model.discovery.status)
        Local Network permission: iOS does not expose a direct status; see discovery errors and LAN verification above.
        LAN pairing setup saved: \(model.hasLANPairingSetup)
        Pairing active: \(model.pairingInProgress); setup busy: \(model.connectionSetupBusy)
        Last pairing failure: \(model.pairingFailure.isEmpty ? "none" : model.pairingFailure)
        Current connection message: \(model.connectionMessage)
        Navigation alpha: \(model.navigationEnabled)
        Recent connection events:
        \(events.suffix(eventLimit ?? retained).joined(separator: "\n"))
        """
    }
}

private struct DeveloperLogsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var log: ConnectionEventLog
    let back: () -> Void
    @State private var sharedReport: GalaxyDownloadedFile?
    @State private var reportDirectory: URL?
    @State private var exportStatus = ""
    @State private var exporting = false
    @State private var discordReport: String?
    @State private var showDiscordReport = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.68, green: 0.48, blue: 0.96) : Color(red: 0.45, green: 0.26, blue: 0.73) }
    private var panel: Color { colorScheme == .dark ? Color(red: 0.09, green: 0.065, blue: 0.145) : Color(red: 0.88, green: 0.83, blue: 0.95) }
    private var background: Color { colorScheme == .dark ? Color(red: 0.035, green: 0.035, blue: 0.078) : Color(red: 0.93, green: 0.90, blue: 0.98) }
    private var muted: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.65, blue: 0.77) : Color(red: 0.36, green: 0.29, blue: 0.46) }
    private func allReports() -> String {
        [log.report(model: model), model.galaxyPage.report(server: model.server, connection: model.transport.label), model.diagnostics.diagnosticLog(), "Galaxy screen updates\n" + model.assets.status].joined(separator: "\n\n")
    }
    private func selectedReport() -> String {
        switch log.section {
        case "Galaxy": return model.galaxyPage.report(server: model.server, connection: model.transport.label)
        case "Live View": return model.diagnostics.diagnosticLog()
        default: return log.report(model: model)
        }
    }
    private func previewReport() -> String {
        log.section == "Connections" ? log.report(model: model, eventLimit: 150) : selectedReport()
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Logs & support").font(.largeTitle.bold()).frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        Button(action: back) { Image(systemName: "chevron.left").font(.headline).frame(width: 44, height: 44).contentShape(Rectangle()) }
                            .buttonStyle(.plain).accessibilityLabel("Back to Settings")
                    }
                VStack(alignment: .leading, spacing: 14) {
                    Label("Need a hand?", systemImage: "bubble.left.and.exclamationmark.bubble.right.fill")
                        .font(.headline).foregroundStyle(accent)
                    Text("Tell us what happened and send diagnostics to the support forum.")
                        .font(.subheadline).foregroundStyle(muted)
                    Button {
                        discordReport = allReports()
                        showDiscordReport = true
                    } label: {
                        Label("Report a problem", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 13)
                            .foregroundStyle(.white).background(accent, in: Capsule())
                    }.buttonStyle(.plain)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(panel, in: RoundedRectangle(cornerRadius: 22))
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                    Text("Preview your logs or share a file. Nothing is sent until you choose to share or submit it.")
                        .font(.subheadline).foregroundStyle(muted)
                    Picker("Report", selection: $log.section) {
                        ForEach(["Connections", "Galaxy", "Live View"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    HStack {
                        Button(log.copied ? "Copied" : "Copy selected", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = selectedReport(); log.copied = true
                        }
                        Spacer()
                        Button("Refresh", systemImage: "arrow.clockwise") { log.detail = previewReport(); log.copied = false }
                    }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                    Button("Copy all diagnostics", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = allReports(); log.copied = true
                    }.font(.subheadline.weight(.semibold)).foregroundStyle(accent)
                Button(exporting ? "Preparing report…" : "Share diagnostics .txt", systemImage: "square.and.arrow.up") {
                    guard !exporting else { return }
                    exporting = true; exportStatus = ""
                    let report = allReports()
                    Task {
                        do {
                            let url = try await Task.detached(priority: .utility) {
                                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                                do {
                                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                                    let name = "StarPilot-diagnostics-" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-") + ".txt"
                                    let url = directory.appendingPathComponent(name)
                                    try report.write(to: url, atomically: true, encoding: .utf8)
                                    return url
                                } catch {
                                    try? FileManager.default.removeItem(at: directory)
                                    throw error
                                }
                            }.value
                            reportDirectory = url.deletingLastPathComponent()
                            sharedReport = GalaxyDownloadedFile(url: url)
                        } catch { exportStatus = "Couldn’t prepare diagnostics. Try again or copy the report." }
                        exporting = false
                    }
                }.buttonStyle(.bordered).buttonBorderShape(.capsule).disabled(exporting).accessibilityIdentifier("save-diagnostics-txt")
                if !exportStatus.isEmpty { Text(exportStatus).font(.caption).foregroundStyle(.secondary) }
                Text("Preview shows the latest 150 connection events. Copy or share includes the full retained log.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(log.detail)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
                Button("Clear connection history") { log.clear(); log.detail = previewReport() }
                    .font(.caption).foregroundStyle(muted)
                    }
                } label: {
                    Label("Manual Log Submission", systemImage: "doc.text.magnifyingglass")
                        .font(.headline).foregroundStyle(accent)
                }.padding(18).background(panel, in: RoundedRectangle(cornerRadius: 22))
            }.padding(20)
        }.background(background.ignoresSafeArea())
            .sheet(isPresented: $showDiscordReport) {
                DiscordReportSheet(logs: discordReport ?? "")
            }
            .sheet(item: $sharedReport, onDismiss: {
                if let directory = reportDirectory { try? FileManager.default.removeItem(at: directory) }
                reportDirectory = nil
            }) { file in
                GalaxyFileShareSheet(url: file.url) { sharedReport = nil }
            }
            .task {
                while !Task.isCancelled {
                    let report = previewReport()
                    if report != log.detail { log.detail = report }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
            .onChange(of: log.section) { _, _ in log.detail = previewReport(); log.copied = false }
    }
}
