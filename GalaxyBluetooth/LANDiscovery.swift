import Foundation
import Darwin

struct DiscoveredComma: Identifiable {
    let id: String
    let name: String
    let address: String
}

@MainActor
final class LANDiscovery: NSObject, ObservableObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    static let serviceType = "_sp-galaxy._tcp."
    @Published private(set) var devices: [DiscoveredComma] = []
    @Published private(set) var searching = false
    @Published private(set) var status = "Find comma on the same Wi-Fi or hotspot, without Bluetooth."
    var onEvent: ((String) -> Void)?
    var onDevicesChanged: (() -> Void)?
    private var browser: NetServiceBrowser?
    private var services: [String: NetService] = [:]
    private var retriedServices = Set<String>()
    private var deadline: Task<Void, Never>?
    private var appActive = true
    private var resumeWhenActive = false

    func setActive(_ active: Bool) {
        appActive = active
        if !active {
            let resume = searching || resumeWhenActive
            stop()
            resumeWhenActive = resume
        } else if resumeWhenActive {
            resumeWhenActive = false
            start()
        }
    }

    func start(retryEmpty: Bool = true) {
        stop()
        devices = []
        searching = true
        status = "Looking for comma on your local network…"
        onEvent?("Local Wi-Fi discovery started")
        let browser = NetServiceBrowser()
        self.browser = browser
        browser.delegate = self
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
        deadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if self.devices.isEmpty && retryEmpty && self.appActive {
                self.onEvent?("Local Wi-Fi discovery found no addresses; retrying once")
                self.start(retryEmpty: false)
                return
            }
            self.stop()
            self.status = self.devices.isEmpty
                ? "No comma found. Use the same Wi-Fi, allow Local Network access, and update comma for discovery. You can still enter its IP."
                : "Select your comma below."
            self.onEvent?("Local Wi-Fi discovery finished: \(self.devices.count) result(s)")
        }
    }

    func stop() {
        resumeWhenActive = false
        deadline?.cancel(); deadline = nil
        browser?.delegate = nil; browser?.stop(); browser = nil
        for service in services.values { service.delegate = nil; service.stop() }
        services.removeAll()
        retriedServices.removeAll()
        if searching { status = devices.isEmpty ? "Search stopped." : "Select your comma below." }
        searching = false
    }

    func networkChanged() {
        let resume = searching || resumeWhenActive
        stop()
        devices = []
        status = "Network changed. Find comma on the current network."
        if resume {
            if appActive { start() }
            else { resumeWhenActive = true }
        }
    }

    private func pauseAfterSearchFailure() {
        let resume = searching || resumeWhenActive
        stop()
        resumeWhenActive = resume
    }

    private func key(_ service: NetService) -> String { service.name + "/" + service.type + "/" + service.domain }
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard searching, browser === self.browser, services.count < 16, services[key(service)] == nil else { return }
        services[key(service)] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browser === self.browser else { return }
        let id = key(service)
        services.removeValue(forKey: id)?.stop()
        devices.removeAll { $0.id == id }
        onDevicesChanged?()
    }
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        guard browser === self.browser else { return }
        let denied = errorDict[NetService.errorCode]?.intValue == -72008
        pauseAfterSearchFailure()
        status = denied ? "Allow Local Network access for this app in iPhone Settings, then search again."
            : "Local Wi-Fi discovery couldn’t start. Check Local Network permission or enter comma’s IP."
        onEvent?("Local Wi-Fi discovery failed: code \(errorDict[NetService.errorCode]?.intValue ?? 0)")
    }
    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        let id = key(sender)
        guard searching, services[id] === sender else { return }
        onEvent?("Local Wi-Fi service address lookup failed: code \(errorDict[NetService.errorCode]?.intValue ?? 0)")
        guard retriedServices.insert(id).inserted else { return }
        onEvent?("Retrying Local Wi-Fi service address lookup")
        sender.resolve(withTimeout: 5)
    }
    func netServiceDidResolveAddress(_ sender: NetService) {
        guard searching, services[key(sender)] === sender, sender.port == 8082 else { return }
        let txt = sender.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
        guard txt["protocol"] == Data("galaxy-lan-1".utf8) else { return }
        guard let address = (sender.addresses ?? []).compactMap(Self.privateIPv4).first else { return }
        let suffix = "-" + address.replacingOccurrences(of: ".", with: "-")
        let name = sender.name.hasSuffix(suffix) ? String(sender.name.dropLast(suffix.count)) : sender.name
        let device = DiscoveredComma(id: key(sender), name: String(name.prefix(80)), address: address)
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        status = "Found \(devices.count) comma device(s). Select one below."
        onEvent?("Local Wi-Fi discovery found Galaxy at \(address):8082")
        onDevicesChanged?()
    }
    static func networkSignature() -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "" }
        defer { freeifaddrs(interfaces) }
        var values: [String] = []
        var current = interfaces
        while let pointer = current {
            let interface = pointer.pointee
            current = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            if inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil {
                values.append(String(cString: interface.ifa_name) + ":" + String(cString: buffer))
            }
        }
        return values.sorted().joined(separator: ",")
    }

    static func privateIPv4(_ data: Data) -> String? {
        guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        var socketAddress = sockaddr_in()
        _ = withUnsafeMutableBytes(of: &socketAddress) { data.copyBytes(to: $0, count: MemoryLayout<sockaddr_in>.size) }
        guard socketAddress.sin_family == sa_family_t(AF_INET), UInt16(bigEndian: socketAddress.sin_port) == 8082 else { return nil }
        var ip = socketAddress.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil else { return nil }
        let address = String(cString: buffer)
        return (try? LANTransport.endpoint(address)) != nil ? address : nil
    }
}
