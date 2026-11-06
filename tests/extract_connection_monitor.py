from pathlib import Path
import sys

source = Path('GalaxyBluetooth/GalaxyBluetoothApp.swift').read_text()

def method(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

stubs = r'''
import Foundation

@MainActor final class SentryPush {
    static let shared = SentryPush()
    func synchronize() async {}
}

enum ConnectionMode: String { case automatic, bluetooth, lan }
@MainActor final class Bluetooth {
    var connected = false, connecting = false, isScanning = false
    var reconnectDelay: TimeInterval { 3 }
    var status = "Bluetooth status"
    var attempts = 0
    func reconnectSaved(pairingKey: String) { attempts += 1 }
}
@MainActor final class LAN {
    var endpoint: URL?
    var connected = false
    var probes = 0
    func configure(address: String) throws { endpoint = URL(string: "http://\(address):8082") }
    func probe() async -> Bool {
        probes += 1
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return false
    }
}
@MainActor final class Tunnel {
    var connected = false
    var credential: String? = "saved"
    var status = "Tunnel paused in Bluetooth only"
    var invalidations = 0
    func invalidate(_ reason: String) { status = reason; invalidations += 1 }
}
@MainActor final class Transport {
    let label = "Reconnecting…"
    var connected = false
}
@MainActor final class Discovery { var searching = false; var status = "Find comma on Wi-Fi"; func start() { searching = true }; func stop() {} }
@MainActor final class Audio { func refreshAudioRoute() {} }
@MainActor final class Assets { var readyRoot: URL?; var status = "" }
@MainActor final class Log { func recordState(_ key: String, _ event: String) {} }
@MainActor final class MonitorProbe {
    let connectionLog = Log()
    let tunnel = Tunnel()
    let bluetooth = Bluetooth(), lan = LAN(), transport = Transport(), discovery = Discovery()
    let assets = Assets()
    let audioPairing = Audio()
    var legacyURL: URL?
    var lastTunnelProbe = Date.distantPast
    func probeTunnelConnection() {}
    var lastAddressCheck = Date.distantPast
    var localAddressNetwork = ""
    var opened = false
    var showAudioPairing = false
    var galaxyOpens = 0, galaxyChecks = 0, musicStarts = 0
    var selectingDiscoveredComma = false
    var wantsConnection = true, pairingInProgress = false, openingGalaxy = false, offerAudioPairing = false
    var mode = ConnectionMode.automatic
    var pairingKey = "saved", address = "", connectionMessage = "", lastRoute = ""
    var lastReconnect = Date.distantPast, lastGalaxyMatch = Date.distantPast
    var tunnelProbeTask: Task<Void, Never>?
    var phoneActive = true, carPlayActive = false
    var lanProbeTask: Task<Void, Never>?
    func learnAddress() async {}
    func discoverAutomaticLAN() {}
    func logConnection(_ reason: String) {}
    func openIfReady() { galaxyOpens += 1 }
    func checkGalaxyUpdates() async { galaxyChecks += 1 }
    func startAudioPairing() { musicStarts += 1; showAudioPairing = true }
'''
tests = r'''
}
@main struct MonitorRegression {
    @MainActor static func main() async throws {
        for mode in [ConnectionMode.automatic, .lan, .bluetooth] {
            let fresh = MonitorProbe()
            fresh.mode = mode
            fresh.wantsConnection = false
            fresh.connect()
            precondition(fresh.wantsConnection)
            precondition(fresh.discovery.searching == (mode != .bluetooth), "First connection must browse LAN unless Bluetooth-only")
        }
        let resuming = MonitorProbe()
        resuming.lastTunnelProbe = Date()
        resuming.mode = .bluetooth
        let pausedDate = resuming.lastTunnelProbe
        resuming.resumeAutomaticTunnel()
        precondition(resuming.lastTunnelProbe == pausedDate && resuming.tunnel.invalidations == 0, "Bluetooth-only must not resume the tunnel")
        resuming.mode = .automatic
        resuming.resumeAutomaticTunnel()
        precondition(Date().timeIntervalSince(resuming.lastTunnelProbe) >= 30, "Returning to Automatic allows the next monitor tick to probe immediately")
        precondition(resuming.tunnel.status == "Tunnel check pending in Automatic" && resuming.tunnel.invalidations == 1, "Do not retain a Bluetooth-only pause label in Automatic")
        let unconfigured = MonitorProbe()
        unconfigured.tunnel.credential = nil
        unconfigured.resumeAutomaticTunnel()
        precondition(unconfigured.tunnel.invalidations == 0, "Do not imply a tunnel is configured when it is not")
        let saved = MonitorProbe()
        saved.address = "192.168.1.20"
        saved.connect()
        precondition(saved.lan.endpoint != nil && !saved.discovery.searching)
        let selecting = MonitorProbe()
        selecting.selectingDiscoveredComma = true
        let selectionMonitor = Task { await selecting.monitor() }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(selecting.lan.probes == 0 && selecting.bluetooth.attempts == 0, "Background connections must not race a tapped comma")
        selectionMonitor.cancel()
        await selectionMonitor.value
        let music = MonitorProbe()
        music.mode = .bluetooth
        music.bluetooth.connected = true
        music.transport.connected = true
        music.offerAudioPairing = true
        let musicMonitor = Task { await music.monitor() }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(music.musicStarts == 1 && music.galaxyOpens == 0 && music.galaxyChecks == 0,
                     "Music setup must start before Galaxy can occupy the Bluetooth request queue")
        musicMonitor.cancel()
        await musicMonitor.value
        let model = MonitorProbe()
        let monitor = Task { await model.monitor() }
        for _ in 0..<100 where model.lan.probes == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(model.lan.probes == 1 && model.bluetooth.attempts == 1)
        model.lastReconnect = .distantPast
        try await Task.sleep(nanoseconds: 3_200_000_000)
        precondition(model.bluetooth.attempts >= 2, "A stalled Wi-Fi request must not block Bluetooth reconnects")
        precondition(model.lan.probes == 1, "Do not pile up Wi-Fi probes while one is still running")
        monitor.cancel()
        model.lanProbeTask?.cancel()
        await monitor.value
        print("Slow Wi-Fi leaves Bluetooth reconnects running; only one LAN probe in flight")
    }
}
'''
Path(sys.argv[1]).write_text(stubs + '\n' + method('    private func resumeAutomaticTunnel()').replace('private func', 'func') + '\n' + method('    func connect()') + '\n' + method('    private func probeLocalConnection()') + '\n' + method('    func monitor() async') + tests)
