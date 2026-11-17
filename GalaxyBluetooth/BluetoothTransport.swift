import Foundation
import Combine
import CoreBluetooth
import CryptoKit
import UIKit

struct NearbyDevice: Identifiable {
    let id: UUID
    let name: String
    let signal: Int
}

@MainActor
final class BluetoothTransport: NSObject, ObservableObject, GalaxyRequestTransport, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    @Published var devices: [NearbyDevice] = []
    @Published var status = "Turn on Bluetooth, then scan for your comma."
    @Published var isScanning = false
    var onEvent: ((String) -> Void)?
    @Published var connected = false
    @Published var connecting = false
    @Published private(set) var connectionFailed = false
    @Published private(set) var pairingRecoveryNeeded = false
    private var authenticationFailures = 0

    private func noteAuthenticationFailure(phase: String, message: String) {
        // The bridge silently rejects unknown keys. Only repeated failures during
        // key verification suggest re-pairing; this is not proof of a revoked key.
        guard phase == "authentication" else { return }
        let lower = message.lowercased()
        guard lower.contains("timed out") || lower.contains("could not verify the encrypted response") else { return }
        authenticationFailures += 1
        pairingRecoveryNeeded = authenticationFailures >= 2
        onEvent?("Bluetooth key verification failed; count=\(authenticationFailures); pairing recovery offered=\(pairingRecoveryNeeded); key rejection not confirmed")
    }

    func retrySavedPairing() {
        pairingRecoveryNeeded = false
        authenticationFailures = 0
        reconnectNotBefore = 0
    }
    @Published private(set) var fastReadFallback = false
    @Published var fastReads = UserDefaults.standard.bool(forKey: "galaxy.bluetooth.fastReads") {
        didSet {
            UserDefaults.standard.set(fastReads, forKey: "galaxy.bluetooth.fastReads")
            if fastReads != oldValue {
                fastReadFallback = false
                onEvent?("Bluetooth read mode: \(fastReads ? "experimental notifications" : "read stream"); applies to the next request")
            }
        }
    }

    private var failedConnections = 0
    private var reconnectNotBefore: TimeInterval = 0
    private var connectionAttempt = 0
    private var connectionPhase = "idle"
    private var connectionStarted: TimeInterval = 0
    private var phaseStarted: TimeInterval = 0

    private func recordConnectionFailure(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        failedConnections = min(failedConnections + 1, 4)
        reconnectNotBefore = now + reconnectDelay
    }

    private func beginConnectionPhase(_ phase: String) {
        connectionPhase = phase
        phaseStarted = ProcessInfo.processInfo.systemUptime
        onEvent?("Bluetooth setup: attempt=\(connectionAttempt); phase=\(phase); elapsed=\(String(format: "%.2f", phaseStarted - connectionStarted))s")
        connectionTimeout?.cancel()
        let attempt = connectionAttempt
        connectionTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self, !self.connected,
                  self.connectionAttempt == attempt, self.connectionPhase == phase else { return }
            self.failConnection("Bluetooth connection timed out during \(phase). Check that the comma bridge is available.")
        }
    }

    var reconnectDelay: TimeInterval { min(25, 3 * pow(2, Double(min(failedConnections, 3)))) }
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var notify: CBCharacteristic?
    private var bond: CBCharacteristic?
    private var bondRead: CheckedContinuation<Void, Error>?
    private var bondReadID: UUID?
    private var bondReadSent = false
    private var bondTimeout: Task<Void, Never>?
    private var healthNotificationBond = false
    var notificationBondSupported: Bool { healthNotificationBond || bond != nil }
    private var key: SymmetricKey?
    private var keyText = ""
    private var session = ""
    var sessionIdentifier: String { session }
    private(set) var catalogSHA256: String?
    private var supportsReadStream = false
    private var activeReadStream = false
    private var supportsNotifications = false
    private var activeNotifications = false
    private var pairingVerified = false
    private var notificationTag = Data()
    private var notificationCount = 0
    private var notificationBuffer: [Data] = []
    private var notificationTimeout: Task<Void, Never>?
    private var counter: UInt64 = 0
    private var queue: [Pending] = []
    private var priorityStreak = 0
    private var requestStarted = 0.0
    private var receivedPackets = 0
    private var receivedWireBytes = 0
    private var active: Pending?
    private var outgoing: [Data] = []
    private var writeIndex = 0
    private var assembler = FrameAssembler()
    private var awaitingAck = false
    private var completedResponse: BridgeResponse?
    private var activeCancelled = false
    private var timeoutTask: Task<Void, Never>?
    private var scanTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?

    private struct Pending {
        let id: String
        let path: String
        let method: String
        let headers: [String: String]
        let body: Data
        let phone: BridgePhone?
        let enqueuedAt = ProcessInfo.processInfo.systemUptime
        let completion: CheckedContinuation<BridgeResponse, Error>
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    private var reconnectTarget: (id: UUID, key: String)?
    private var lastReconnectReason = ""
    var hasSavedDevice: Bool {
        guard let value = UserDefaults.standard.string(forKey: "galaxy.bluetooth.device") else { return false }
        return UUID(uuidString: value) != nil
    }
    var diagnosticSummary: String {
        let saved = UserDefaults.standard.string(forKey: "galaxy.bluetooth.device")
        return "attempt=\(connectionAttempt); phase=\(connectionPhase); retry wait=\(String(format: "%.1f", max(0, reconnectNotBefore - ProcessInfo.processInfo.systemUptime)))s; state=\(central.state.rawValue); saved device=\(saved != nil); saved ID valid=\(saved.flatMap(UUID.init(uuidString:)) != nil); scanning=\(isScanning); connecting=\(connecting); verified=\(connected); paired handshake=\(pairingVerified); recovery scan=\(reconnectTarget != nil); failed connections=\(failedConnections); queued requests=\(queue.count); request active=\(active != nil); RX=\(rx != nil); TX=\(tx != nil); read stream=\(supportsReadStream); notifications=\(supportsNotifications); last reconnect=\(lastReconnectReason)"
    }
    private func reconnectDecision(_ reason: String) {
        guard reason != lastReconnectReason else { return }
        lastReconnectReason = reason
        onEvent?("Bluetooth reconnect: " + reason)
    }
    func reconnectSaved(pairingKey: String) {
        guard !connected, !connecting, !isScanning else { return }
        guard !pairingRecoveryNeeded else {
            reconnectDecision("key verification repeatedly failed; waiting for pairing recovery or manual retry"); return
        }
        guard ProcessInfo.processInfo.systemUptime >= reconnectNotBefore else {
            reconnectDecision("waiting after failed connection; failures=\(failedConnections)"); return
        }
        guard central.state == .poweredOn else { reconnectDecision("waiting for powered-on Bluetooth; state=\(central.state.rawValue)"); return }
        guard let bytes = Data(hex: pairingKey), bytes.count == 32 else {
            status = "Bluetooth app pairing is missing. Connect over Local Wi-Fi and choose Pair Bluetooth with comma."
            reconnectDecision("missing or invalid saved app key; pairing required"); return
        }
        guard let value = UserDefaults.standard.string(forKey: "galaxy.bluetooth.device"), let id = UUID(uuidString: value) else {
            status = "No saved Bluetooth device. Connect over Local Wi-Fi and pair Bluetooth with comma."
            reconnectDecision("saved peripheral ID missing or invalid; pairing required"); return
        }
        if let found = central.retrievePeripherals(withIdentifiers: [id]).first {
            reconnectDecision("saved peripheral retrieved; connecting")
            peripherals[id] = found
            connect(NearbyDevice(id: id, name: found.name ?? "comma", signal: 0), pairingKey: pairingKey)
        } else {
            reconnectDecision("saved peripheral unavailable from iOS cache; scanning for the same device")
            scan()
            reconnectTarget = (id, pairingKey)
            reconnectDiscoveredDevice()
        }
    }
    private func reconnectDiscoveredDevice() {
        guard let target = reconnectTarget, let found = devices.first(where: { $0.id == target.id }) else { return }
        reconnectDecision("saved peripheral rediscovered; connecting with saved app key")
        connect(found, pairingKey: target.key)
    }

    func forgetSavedDevice() {
        disconnect()
        retrySavedPairing()
        UserDefaults.standard.removeObject(forKey: "galaxy.bluetooth.device")
    }

    func scan() {
        reconnectTarget = nil
        guard central.state == .poweredOn else { onEvent?("Bluetooth scan blocked: state=\(central.state.rawValue)"); status = "Bluetooth is unavailable or permission is required."; return }
        devices = []
        peripherals = [:]
        onEvent?("Bluetooth service scan started; timeout=15s")
        for found in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: Wire.service)]) {
            peripherals[found.identifier] = found
            devices.append(NearbyDevice(id: found.identifier, name: found.name ?? "Galaxy", signal: 0))
        }
        onEvent?("Bluetooth scan found \(devices.count) already-connected service candidates")
        central.scanForPeripherals(withServices: [CBUUID(string: Wire.service)], options: nil)
        isScanning = true
        status = "Looking for the Galaxy Bluetooth bridge…"
        scanTimeout?.cancel()
        scanTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.onEvent?("Bluetooth service scan finished: candidates=\(self.devices.count)")
            if self.reconnectTarget != nil {
                self.reconnectDecision("recovery scan timed out without the saved device; candidates=\(self.devices.count)")
                self.reconnectTarget = nil
            }
            self.central.stopScan()
            self.isScanning = false
            self.status = self.devices.isEmpty ? "No bridge found. Start the bridge on your comma and enable Bluetooth in StarPilot." : "Select your comma to connect."
        }
    }

    func connect(_ device: NearbyDevice, pairingKey: String) {
        guard let bytes = Data(hex: pairingKey), bytes.count == 32 else {
            status = "Paste the 64-character pairing key created on your comma."
            return
        }
        guard let found = peripherals[device.id] else { return }
        disconnect()
        key = SymmetricKey(data: bytes)
        keyText = bytes.hex
        peripheral = found
        found.delegate = self
        connecting = true
        status = "Connecting to \(device.name)…"
        onEvent?("Starting Bluetooth connection")
        connectionAttempt += 1
        connectionStarted = ProcessInfo.processInfo.systemUptime
        beginConnectionPhase("link")
        central.connect(found, options: nil)
    }

    func disconnect(reason: String = "Bluetooth connection closed") {
        connectionFailed = false
        reconnectTarget = nil
        let hadConnection = connected || connecting || peripheral != nil
        if hadConnection {
            let now = ProcessInfo.processInfo.systemUptime
            onEvent?("\(reason); attempt=\(connectionAttempt); phase=\(connectionPhase); verified=\(connected); elapsed=\(String(format: "%.2f", now - connectionStarted))s; phase elapsed=\(String(format: "%.2f", now - phaseStarted))s; active request=\(active != nil); queued=\(queue.count); RX=\(rx != nil); TX=\(tx != nil); handshake=\(pairingVerified); retry wait=\(String(format: "%.1f", max(0, reconnectNotBefore - now)))s")
        }
        central.stopScan()
        scanTimeout?.cancel()
        connectionTimeout?.cancel()
        isScanning = false
        connected = false
        connecting = false
        failAll(BridgeError.message("Bluetooth connection closed."))
        finishBondRead(.failure(NotificationBondError.disconnected))
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        rx = nil
        tx = nil
        notify = nil
        bond = nil
        healthNotificationBond = false
        session = ""
        counter = 0
        priorityStreak = 0
        catalogSHA256 = nil
        supportsReadStream = false
        activeReadStream = false
        supportsNotifications = false
        activeNotifications = false
        pairingVerified = false
        notificationBuffer = []
        connectionPhase = "idle"
    }

    private func failConnection(_ message: String) {
        noteAuthenticationFailure(phase: connectionPhase, message: message)
        recordConnectionFailure()
        if Self.shouldPauseFastReads(method: active?.method, notifications: activeNotifications,
                                     cancelled: message.lowercased().contains("cancelled")) {
            fastReadFallback = true
            onEvent?("Fast Bluetooth reads paused after a transfer failure. Reliable reads will be used after reconnecting; toggle fast reads off and on to retry.")
        }
        let lower = message.lowercased()
        let reason: String
        if lower.contains("request timed out") { reason = "Bluetooth request timed out" }
        else if lower.contains("push stalled") { reason = "Bluetooth notification transfer stalled" }
        else if lower.contains("cancelled") { reason = "Bluetooth request cancelled during transfer" }
        else if lower.contains("timed out") { reason = "Bluetooth connection timed out" }
        else if lower.contains("pairing") { reason = "Bluetooth pairing or authentication failed" }
        else if lower.contains("encrypt") || lower.contains("verify bluetooth") { reason = "Bluetooth encrypted response failed" }
        else if lower.hasPrefix("bluetooth operation failed:") { reason = message }
        else { reason = "Bluetooth connection failed" }
        if let active {
            onEvent?("\(reason): [\(active.id.prefix(8))] \(active.method) \(LoopbackServer.reportPath(active.path)), queued=\(queue.count), sent=\(writeIndex)/\(outgoing.count), received packets=\(notificationCount), awaiting ack=\(awaitingAck)")
        }
        disconnect(reason: reason)
        connectionFailed = central.state == .poweredOn
        onEvent?(reason)
        status = message
    }

    func request(path: String, method: String, headers: [String: String], body: Data) async throws -> BridgeResponse {
        try await request(path: path, method: method, headers: headers, body: body, phone: nil)
    }

    private func request(path: String, method: String, headers: [String: String], body: Data,
                         phone: BridgePhone?) async throws -> BridgeResponse {
        let id = UUID().uuidString
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard rx != nil, tx != nil, !session.isEmpty else {
                    onEvent?("Bluetooth request rejected: [\(id.prefix(8))] no ready session; \(method) \(LoopbackServer.reportPath(path))")
                    continuation.resume(throwing: BridgeError.message("Connect to your comma over Bluetooth first."))
                    return
                }
                guard queue.count < 32, body.count <= Wire.maxBody else {
                    onEvent?("Bluetooth request rejected: [\(id.prefix(8))] queue=\(queue.count); body bytes=\(body.count)")
                    continuation.resume(throwing: BridgeError.message("Bluetooth queue is full or upload exceeds 1 MiB."))
                    return
                }
                onEvent?("Bluetooth request queued: [\(id.prefix(8))] \(method) \(LoopbackServer.reportPath(path)); waiting=\(queue.count); active=\(active != nil); upload bytes=\(body.count)")
                queue.append(Pending(id: id, path: path, method: method, headers: headers, body: body, phone: phone, completion: continuation))
                pump()
            }
        }, onCancel: { [weak self] in
            DispatchQueue.main.async { self?.cancel(id) }
        })
    }

    private func cancel(_ id: String) {
        onEvent?("Bluetooth cancellation: [\(id.prefix(8))]; active=\(active?.id == id); queued=\(queue.contains { $0.id == id })")
        if let index = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: index).completion.resume(throwing: CancellationError())
        } else if active?.id == id {
            if Self.canDrainCancellation(method: active?.method, requestSent: writeIndex >= outgoing.count) {
                // Finish read-only requests even if their outgoing frame is still being sent.
                activeCancelled = true
            } else {
                failConnection("Request cancelled. Reconnect before sending another request.")
            }
        }
    }

    static func canDrainCancellation(method: String?, requestSent: Bool) -> Bool {
        method == "GET" || requestSent
    }

    static func useNotifications(method: String, path: String, supported: Bool, fastReads: Bool = false) -> Bool {
        supported && (method != "GET" || fastReads) && path != "/_bridge/health"
    }

    static func shouldPauseFastReads(method: String?, notifications: Bool, cancelled: Bool) -> Bool {
        method == "GET" && notifications && !cancelled
    }

    static func backgroundRead(_ path: String) -> Bool {
        let endpoint = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        return ["/api/device/state", "/api/system/monitor", "/api/local-access", "/api/models/status", "/api/software/status", "/api/drives/stats"].contains(endpoint)
    }

    static func nextRequestIndex(methods: [String], paths: [String], priorityStreak: Int) -> Int {
        guard methods.count == paths.count, !methods.isEmpty, methods[0] == "GET", priorityStreak < 3 else { return 0 }
        // A GPS update can pass queued reads, but never another write. Bound
        // priority bursts so regular reads still make progress.
        for index in methods.indices {
            if methods[index] == "POST" && paths[index] == "/api/companion/location" { return index }
            if methods[index] != "GET" { break }
        }
        // Keep the short-lived state badge from waiting behind large page snapshots.
        for index in methods.indices {
            if methods[index] != "GET" { break }
            if URLComponents(string: paths[index])?.path == "/api/device/state" { return index }
        }
        // A queued write is a barrier: never move a read from after it to before it.
        for index in methods.indices {
            if methods[index] != "GET" { break }
            if !backgroundRead(paths[index]) { return index }
        }
        return 0
    }

    private func pump() {
        // Hold new requests so the pairing sheet cannot stall a transfer's acknowledgements.
        if active == nil, bondRead != nil { sendBondRead(); return }
        guard active == nil, !queue.isEmpty, let peripheral, let key, !session.isEmpty else { return }
        let index = Self.nextRequestIndex(methods: queue.map(\.method), paths: queue.map(\.path), priorityStreak: priorityStreak)
        active = queue.remove(at: index)
        guard let active else { return }
        priorityStreak = index > 0 ? min(3, priorityStreak + 1) : 0
        requestStarted = ProcessInfo.processInfo.systemUptime
        receivedPackets = 0
        receivedWireBytes = 0
        counter += 1
        assembler = FrameAssembler()
        completedResponse = nil
        activeCancelled = false
        awaitingAck = false
        writeIndex = 0
        activeNotifications = Self.useNotifications(method: active.method, path: active.path, supported: supportsNotifications, fastReads: fastReads && !fastReadFallback)
        notificationCount = 0
        notificationBuffer = []
        activeReadStream = supportsReadStream && active.path != "/_bridge/health"
        onEvent?("Bluetooth request started: [\(active.id.prefix(8))] \(active.method) \(LoopbackServer.reportPath(active.path)), queued=\(queue.count), waited=\(String(format: "%.2f", requestStarted - active.enqueuedAt))s, response=\(activeNotifications ? "notifications" : activeReadStream ? "read stream" : "encrypted reads")")
        if requestStarted - active.enqueuedAt > 2 {
            let pending = queue.prefix(6).map { "\($0.method) \(LoopbackServer.reportPath($0.path)) age=\(Int(requestStarted - $0.enqueuedAt))s" }.joined(separator: "; ")
            onEvent?("Bluetooth slow queue: waiting=\(queue.count); priority streak=\(priorityStreak); fast reads=\(fastReads); fallback=\(fastReadFallback); next=[\(pending)]")
        }
        do {
            let body = try PhoneGpsDelivery.body(active.body, path: active.path,
                                                 queuedSeconds: ProcessInfo.processInfo.systemUptime - active.enqueuedAt)
            notificationTag = try Wire.streamTag(session: session, counter: counter)
            let request = BridgeRequest(id: active.id, session: session, counter: counter, path: active.path,
                                        method: active.method, headers: active.headers, body: body.base64EncodedString(),
                                        phone: active.phone, responseCodec: 2, responseFlow: activeNotifications ? "notify-window8" : activeReadStream ? "read-stream" : nil)
            let packetLimit = min(supportsNotifications ? 512 : 180, peripheral.maximumWriteValueLength(for: .withResponse))
            onEvent?("Bluetooth write limit: \(packetLimit) bytes; acknowledged writes; compression=2")
            outgoing = Wire.packets(try Wire.seal(request, key: key, direction: "request"),
                                    size: packetLimit)
            timeoutTask = Task { @MainActor [weak self] in
                let seconds: UInt64 = active.path == "/_bridge/health" ? 10 : 90
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard !Task.isCancelled, let self, self.active?.id == active.id else { return }
                self.failConnection("Bluetooth request timed out. Its outcome may be unknown; reconnect to check before retrying.")
            }
            writeNext()
        } catch {
            finish(.failure(error))
        }
    }

    private func writeNext() {
        guard let peripheral, let rx, active != nil else { return }
        if writeIndex < outgoing.count {
            peripheral.writeValue(outgoing[writeIndex], for: rx, type: .withResponse)
        } else if activeNotifications {
            drainNotifications()
        } else if let tx {
            peripheral.readValue(for: tx)
        }
    }

    private func finish(_ result: Result<BridgeResponse, Error>) {
        timeoutTask?.cancel()
        notificationTimeout?.cancel()
        timeoutTask = nil
        let previous = active
        if let previous {
            let outcome: String
            switch result {
            case .success(let response): outcome = "HTTP \(response.status), \(response.bodyData.count) bytes"
            case .failure(let error): outcome = "failed: \(LANTransport.failureCode(error)); sent packets=\(writeIndex)/\(outgoing.count); awaiting ack=\(awaitingAck); cancelled=\(activeCancelled)"
            }
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - requestStarted)
            onEvent?("Bluetooth request finished: [\(previous.id.prefix(8))] \(previous.method) \(LoopbackServer.reportPath(previous.path)), \(outcome), packets=\(receivedPackets), wire=\(receivedWireBytes) bytes, rate=\(String(format: "%.1f", Double(receivedWireBytes) / elapsed / 1024)) KiB/s, transfer=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - requestStarted))s")
        }
        active = nil
        outgoing = []
        notificationBuffer = []
        if activeCancelled { previous?.completion.resume(throwing: CancellationError()) }
        else { previous?.completion.resume(with: result) }
        activeCancelled = false
        pump()
    }

    /// Reading this encrypted characteristic makes iOS bond the LE link, which lets comma receive notifications over ANCS.
    func readNotificationBond() async throws {
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard connected, peripheral != nil else { continuation.resume(throwing: NotificationBondError.disconnected); return }
                guard bond != nil else { continuation.resume(throwing: NotificationBondError.unavailable); return }
                guard bondRead == nil else { continuation.resume(throwing: NotificationBondError.busy); return }
                bondRead = continuation
                bondReadID = id
                bondReadSent = false
                onEvent?("Notification bond read queued; active request=\(active != nil)")
                bondTimeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 45_000_000_000)
                    guard !Task.isCancelled, let self, self.bondReadID == id else { return }
                    self.finishBondRead(.failure(NotificationBondError.timedOut))
                }
                pump()
            }
        }, onCancel: { [weak self] in
            DispatchQueue.main.async { if self?.bondReadID == id { self?.finishBondRead(.failure(CancellationError())) } }
        })
    }

    private func sendBondRead() {
        guard !bondReadSent, let peripheral, let bond else { return }
        bondReadSent = true
        onEvent?("Notification bond read sent")
        peripheral.readValue(for: bond)
    }

    private func finishBondRead(_ result: Result<Void, Error>) {
        bondTimeout?.cancel()
        bondTimeout = nil
        guard let continuation = bondRead else { return }
        bondRead = nil
        bondReadID = nil
        bondReadSent = false
        switch result {
        case .success: onEvent?("Notification bond read finished: bonded")
        case .failure(let error): onEvent?("Notification bond read failed: \(error)")
        }
        continuation.resume(with: result)
        pump()
    }

    nonisolated static func bondFailure(_ error: Error) -> NotificationBondError {
        let error = error as NSError
        if error.domain == CBATTErrorDomain, [CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientEncryption.rawValue,
                                               CBATTError.insufficientAuthorization.rawValue].contains(error.code) { return .declined }
        if error.domain == CBErrorDomain, error.code == CBError.Code.peerRemovedPairingInformation.rawValue { return .staleBond }
        if error.domain == CBErrorDomain, error.code == CBError.Code.encryptionTimedOut.rawValue { return .timedOut }
        return .failed
    }

    private func failAll(_ error: Error) {
        timeoutTask?.cancel()
        notificationTimeout?.cancel()
        let pending = queue
        queue = []
        let previous = active
        active = nil
        outgoing = []
        notificationBuffer = []
        previous?.completion.resume(throwing: error)
        pending.forEach { $0.completion.resume(throwing: error) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onEvent?("iOS Bluetooth state changed: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn: status = "Ready to scan for your comma."
        case .unauthorized: failConnection("Allow Bluetooth access in iPhone Settings.")
        case .poweredOff: failConnection("Bluetooth is turned off.")
        default: failConnection("Bluetooth is unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let device = NearbyDevice(id: peripheral.identifier,
                                  name: advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Galaxy",
                                  signal: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device); onEvent?("Bluetooth service candidate discovered: RSSI=\(RSSI.intValue), candidates=\(devices.count); saved match=\(reconnectTarget?.id == device.id)") }
        reconnectDiscoveredDevice()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        beginConnectionPhase("services")
        onEvent?("Bluetooth link established; discovering Galaxy service")
        peripheral.readRSSI()
        peripheral.discoverServices([CBUUID(string: Wire.service)])
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard peripheral == self.peripheral else { return }
        onEvent?("Bluetooth signal: attempt=\(connectionAttempt); phase=\(connectionPhase); RSSI=\(RSSI.intValue); result=\(error.map { LANTransport.failureCode($0) } ?? "ok")")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if let error = error as NSError?, error.domain == CBErrorDomain,
           error.code == CBError.Code.peerRemovedPairingInformation.rawValue {
            failConnection("Bluetooth operation failed: comma removed its Bluetooth pairing information (CBErrorDomain 14). In iPhone Settings > Bluetooth, forget the comma entry if listed, then reconnect in StarPilot. Your saved app key has not been removed.")
            return
        }
        failConnection("Bluetooth operation failed: connect callback; \(error.map { LANTransport.failureCode($0) } ?? "no OS error supplied")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if let error, Self.bondFailure(error) == .staleBond { finishBondRead(.failure(NotificationBondError.staleBond)) }
        recordConnectionFailure()
        disconnect(reason: "Bluetooth peer disconnected: \(error.map { LANTransport.failureCode($0) } ?? "no OS error supplied")")
        connectionFailed = error != nil && central.state == .poweredOn
        status = error?.localizedDescription ?? "Your comma disconnected. Scan to reconnect."
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: Wire.service) }) else {
            failConnection("Bluetooth operation failed: service discovery; \(error.map { LANTransport.failureCode($0) } ?? "required service missing")"); return
        }
        beginConnectionPhase("characteristics")
        onEvent?("Bluetooth Galaxy service found; discovering characteristics")
        peripheral.discoverCharacteristics([CBUUID(string: Wire.rx), CBUUID(string: Wire.tx), CBUUID(string: Wire.info), CBUUID(string: Wire.notify), CBUUID(string: Wire.bond)], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil else { failConnection("Bluetooth operation failed: characteristics; \(LANTransport.failureCode(error!))"); return }
        rx = service.characteristics?.first { $0.uuid == CBUUID(string: Wire.rx) }
        tx = service.characteristics?.first { $0.uuid == CBUUID(string: Wire.tx) }
        notify = service.characteristics?.first { $0.uuid == CBUUID(string: Wire.notify) }
        bond = service.characteristics?.first { $0.uuid == CBUUID(string: Wire.bond) }
        guard rx != nil, tx != nil, let info = service.characteristics?.first(where: { $0.uuid == CBUUID(string: Wire.info) }) else {
            failConnection("The comma bridge has incompatible Bluetooth characteristics."); return
        }
        onEvent?("Bluetooth capabilities: characteristics=\(service.characteristics?.count ?? 0); RX properties=\(rx?.properties.rawValue ?? 0); TX properties=\(tx?.properties.rawValue ?? 0); notify present=\(notify != nil); notification bond present=\(bond != nil); write limit=\(peripheral.maximumWriteValueLength(for: .withResponse))")
        beginConnectionPhase("challenge")
        onEvent?("Bluetooth characteristics ready; reading handshake challenge")
        peripheral.readValue(for: info)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == CBUUID(string: Wire.rx), active != nil else { return }
        if let error { failConnection("Bluetooth operation failed: \(LANTransport.failureCode(error))"); return }
        if awaitingAck {
            if activeNotifications { onEvent?("Bluetooth notification window acknowledged: packets=\(notificationCount), complete=\(completedResponse != nil)") }
            awaitingAck = false
            if let response = completedResponse {
                completedResponse = nil
                finish(.success(response))
            } else if activeNotifications {
                drainNotifications()
            } else if let tx {
                peripheral.readValue(for: tx)
            }
        } else {
            writeIndex += 1
            writeNext()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        if characteristic.uuid == CBUUID(string: Wire.bond) {
            if let error {
                onEvent?("Notification bond read error: \(LANTransport.failureCode(error))")
                finishBondRead(.failure(Self.bondFailure(error)))
            } else {
                finishBondRead(characteristic.value == Data([1]) ? .success(()) : .failure(NotificationBondError.failed))
            }
            return
        }
        if let error { failConnection("Bluetooth operation failed: \(LANTransport.failureCode(error))"); return }
        guard let data = characteristic.value else { failConnection("Empty Bluetooth response."); return }
        if characteristic.uuid == CBUUID(string: Wire.notify) {
            receiveNotification(data)
            return
        }
        if characteristic.uuid == CBUUID(string: Wire.info) {
            guard connectionPhase == "challenge" else { return }
            guard data.count == 17, data.first == 1 else { failConnection("Unsupported bridge protocol."); return }
            beginConnectionPhase("authentication")
            session = Data(data.dropFirst()).hex
            let handshakeSession = session
            status = "Verifying the pairing key…"
            Task { @MainActor [weak self, weak peripheral] in
                guard let self, let peripheral else { return }
                do {
                    let response = try await self.request(path: "/_bridge/health", method: "GET", headers: [:], body: Data(),
                        phone: PairingKeyStore.phone(for: self.keyText, name: UIDevice.current.name))
                    guard peripheral == self.peripheral, self.session == handshakeSession else { return }
                    guard response.status == 200 else { throw BridgeError.message("Bridge verification failed.") }
                    let health = try JSONDecoder().decode(BridgeHealth.self, from: response.bodyData)
                    guard health.protocol == 1, health.transport == "bluetooth" else {
                        throw BridgeError.message("Unsupported bridge protocol.")
                    }
                    self.catalogSHA256 = health.catalogSHA256
                    self.supportsReadStream = health.readStream == true
                    self.healthNotificationBond = health.notificationBond == true
                    self.pairingVerified = true
                    if health.notificationStream == true, let notify = self.notify, notify.properties.contains(.notify) {
                        self.beginConnectionPhase("notification subscription")
                        self.status = "Enabling fast Bluetooth transfers…"
                        peripheral.setNotifyValue(true, for: notify)
                    } else {
                        try self.completeConnection()
                    }
                } catch {
                    guard peripheral == self.peripheral, self.session == handshakeSession else { return }
                    self.failConnection("Pairing failed: \(error.localizedDescription)")
                }
            }
            return
        }
        guard characteristic.uuid == CBUUID(string: Wire.tx), active != nil, let rx else { return }
        if data == Data([0]) {
            let requestID = active?.id
            Task { @MainActor [weak self, weak peripheral] in
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled, let self, self.active?.id == requestID, self.active != nil, let tx = self.tx,
                      let peripheral, peripheral == self.peripheral else { return }
                peripheral.readValue(for: tx)
            }
            return
        }
        do {
            receivedPackets += 1
            receivedWireBytes += data.count
            if let message = try assembler.append(data), let key {
                let response = try Wire.open(message, as: BridgeResponse.self, key: key, direction: "response")
                guard response.id == active?.id, response.session == session, response.counter == counter,
                      (100...599).contains(response.status), Data(base64Encoded: response.body) != nil else {
                    throw BridgeError.message("Bluetooth response identity did not match the request.")
                }
                completedResponse = response
            }
            if activeReadStream, completedResponse == nil, let tx {
                peripheral.readValue(for: tx)
                return
            }
            awaitingAck = true
            peripheral.writeValue(Data([2]) + data.subdata(in: 1..<5), for: rx, type: .withResponse)
        } catch { failConnection("Could not verify the encrypted response: \(error.localizedDescription)") }
    }

    private func completeConnection() throws {
        try PairingKeyStore.save(keyText)
        retrySavedPairing()
        connectionTimeout?.cancel()
        if let peripheral { UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "galaxy.bluetooth.device") }
        failedConnections = 0
        reconnectNotBefore = 0
        connectionPhase = "ready"
        phaseStarted = ProcessInfo.processInfo.systemUptime
        connected = true
        connecting = false
        status = supportsNotifications ? "Connected with fast Bluetooth transfers" : "Connected over Bluetooth"
        onEvent?("Bluetooth encrypted handshake completed; attempt=\(connectionAttempt); elapsed=\(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - connectionStarted))s")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == CBUUID(string: Wire.notify), pairingVerified else { return }
        onEvent?("Bluetooth notification subscription: notifying=\(characteristic.isNotifying); active request=\(active != nil); result=\(error.map { LANTransport.failureCode($0) } ?? "ok")")
        guard error == nil, characteristic.isNotifying else {
            supportsNotifications = false
            if activeNotifications && active != nil {
                failConnection("Bluetooth push subscription ended. Reconnect to check any pending setting change.")
            } else if !connected {
                do { try completeConnection() } catch { failConnection(error.localizedDescription) }
            }
            onEvent?("Bluetooth notifications unavailable; using encrypted reads.")
            return
        }
        supportsNotifications = true
        do { try completeConnection() }
        catch { failConnection(error.localizedDescription) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral == self.peripheral, invalidatedServices.contains(where: { $0.uuid == CBUUID(string: Wire.service) }) else { return }
        failConnection("The bridge's Bluetooth services changed. Scan and reconnect.")
    }

    private func receiveNotification(_ data: Data) {
        guard active != nil, activeNotifications else { return }
        do {
            // Unrelated client/request frames must not enter this assembler.
            guard try Wire.notificationPacket(data, tag: notificationTag) != nil else { return }
            notificationTimeout?.cancel()
            let requestID = active?.id
            notificationTimeout = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.active?.id == requestID else { return }
                self.failConnection("Bluetooth push stalled. Reconnect to check any pending setting change.")
            }
            if awaitingAck || writeIndex < outgoing.count {
                guard notificationBuffer.count < Wire.notificationWindow else {
                    throw BridgeError.message("Bluetooth notification window exceeded.")
                }
                notificationBuffer.append(data)
            } else {
                try consumeNotification(data)
            }
        } catch { failConnection("Could not verify Bluetooth push data: \(error.localizedDescription)") }
    }

    private func drainNotifications() {
        while active != nil, activeNotifications, !awaitingAck, !notificationBuffer.isEmpty {
            let data = notificationBuffer.removeFirst()
            do { try consumeNotification(data) }
            catch { failConnection("Could not verify Bluetooth push data: \(error.localizedDescription)") }
        }
    }

    private func consumeNotification(_ data: Data) throws {
        guard let packet = try Wire.notificationPacket(data, tag: notificationTag), let peripheral, let rx else { return }
        if let message = try assembler.append(packet), let key {
            let response = try Wire.open(message, as: BridgeResponse.self, key: key, direction: "response")
            guard response.id == active?.id, response.session == session, response.counter == counter,
                  (100...599).contains(response.status), let body = Data(base64Encoded: response.body), body.count <= Wire.maxBody else {
                throw BridgeError.message("Bluetooth response identity did not match the request.")
            }
            completedResponse = response
        }
        notificationCount += 1
        receivedPackets += 1
        receivedWireBytes += data.count
        if completedResponse != nil || notificationCount % Wire.notificationWindow == 0 {
            awaitingAck = true
            let sequence = Wire.number(packet.subdata(in: 1..<5))
            peripheral.writeValue(Wire.notificationAck(tag: notificationTag, sequence: sequence), for: rx, type: .withResponse)
        }
    }
}
