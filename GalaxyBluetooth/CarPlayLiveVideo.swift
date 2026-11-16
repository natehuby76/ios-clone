import AVFoundation
import CarPlay
import UIKit
import CryptoKit

struct CarPlayVideoPacket {
    let frameID: UInt64
    let captureClock: UInt64
    let encodeMicroseconds: UInt64
    let sourceAgeMicroseconds: UInt64
    let payload: Data
}

struct CarPlayVideoParser {
    static let maximumFrameBytes = 2 * 1024 * 1024
    private var pending = Data()
    var bufferedBytes: Int { pending.count }

    mutating func append(_ data: Data) throws -> [CarPlayVideoPacket] {
        pending.append(data)
        var packets: [CarPlayVideoPacket] = []
        while pending.count >= 32 {
            guard pending.prefix(4) == Data("SPV1".utf8) else {
                throw BridgeError.message("Unexpected Live View stream format.")
            }
            func integer(_ offset: Int, _ count: Int) -> UInt64 {
                pending.dropFirst(offset).prefix(count).reduce(0) { ($0 << 8) | UInt64($1) }
            }
            let size = Int(integer(4, 4))
            guard size <= Self.maximumFrameBytes else {
                throw BridgeError.message("Live View frame exceeds the size limit.")
            }
            guard pending.count >= 32 + size else { break }
            packets.append(CarPlayVideoPacket(
                frameID: integer(8, 8), captureClock: integer(16, 8),
                encodeMicroseconds: integer(24, 4), sourceAgeMicroseconds: integer(28, 4),
                payload: Data(pending.dropFirst(32).prefix(size))))
            pending = Data(pending.dropFirst(32 + size))
        }
        guard pending.count <= Self.maximumFrameBytes + 32 else {
            throw BridgeError.message("Live View stream buffer exceeds the size limit.")
        }
        return packets
    }
}

@MainActor
enum CarPlayVideoLayout {
    static func visibleRect(in view: UIView) -> CGRect {
        var contentSafeAreas = [view.safeAreaLayoutGuide.layoutFrame, view.bounds.inset(by: view.safeAreaInsets)]
        if let window = view.window as? CPWindow {
            contentSafeAreas.append(window.convert(window.safeAreaLayoutGuide.layoutFrame, to: view))
            contentSafeAreas.append(window.convert(window.bounds.inset(by: window.safeAreaInsets), to: view))
        }
        // Build 142 on the factory Corolla reports zero insets on both the
        // root view and CPWindow, despite a roughly 50-point dock overlay.
        // The user confirmed the left-side dock on this private test head unit.
        // Reserve only that edge when insets are missing; the menu may overlay.
        return StarPortVideoViewport.visibleRect(bounds: view.bounds, contentSafeAreas: contentSafeAreas, fallbackLeftInset: 60)
    }
}

@MainActor
private final class CarPlayVideoConnection {
    private var client: StarPortClient?
    private var stopped = false
    init(host: String, certificate: Data?, received: @escaping (CarPlayVideoPacket, @escaping () -> Void) throws -> Void,
         ended: @escaping (Error?) -> Void) {
        client = StarPortClient(host: host, certificate: certificate, log: { message in
            Task { @MainActor in CarPlayLiveDiagnostics.shared.record("App-only receiver: " + message) }
        }, video: { [weak self] payload, number, timestamp, consumed in
            let delivered = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard self?.stopped == false else { consumed(); return }
                do {
                    try received(CarPlayVideoPacket(frameID: number, captureClock: timestamp * 1000,
                        encodeMicroseconds: 0, sourceAgeMicroseconds: 0, payload: payload), consumed)
                    if number == 1 || number % 60 == 0 {
                        CarPlayLiveDiagnostics.shared.record("Native receiver frame=\(number); sender timestamp us=\(timestamp); receive-to-main ms=\((ProcessInfo.processInfo.systemUptime-delivered)*1000); encode/source age unavailable in native protocol; capture and phone clocks are not synchronized")
                    }
                } catch { ended(error) }
            }
        }, ended: { [weak self] error in Task { @MainActor in
            guard self?.stopped == false else { return }; ended(error)
        } })
    }
    func stop() { stopped = true; client?.stop(); client = nil }
}

@MainActor
final class CarPlayLiveVideoController: UIViewController {
    weak var interfaceController: CPInterfaceController?
    var directDisplay = false
    private let directLayer = CALayer()
    private var directDecoder: StarPortVideoDecoder?
    private var directPresented: UInt64 = 0
    private var layoutDescription = ""
    private var awaitingTrust = false
    private var trustRejected = false
    private let video = AVSampleBufferDisplayLayer()
    private let status = UILabel()
    private var connection: CarPlayVideoConnection?
    private var maintenance: Task<Void, Never>?
    private var sourceEndpoint: URL?
    private var sourceGeneration = ""
    private var format: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var waitingForKeyframe = true
    private var lastPacket = ProcessInfo.processInfo.systemUptime
    private var lastVideoFrame: Double?
    private var reconnectAt = 0.0
    private var enqueued = 0
    private var lastMetricsAt = 0.0
    private var metricsPending = false
    private var previousRendererMetric: (frames: Int, delay: Double)?
    private var videoEpoch = UUID()
    private var waitingDrops = 0, backpressureDrops = 0

    private func logRendererMetrics() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastMetricsAt >= 2, !metricsPending else { return }
        if directDisplay {
            lastMetricsAt = now
            CarPlayLiveDiagnostics.shared.record("Direct video pipeline: presented-to-layer=\(enqueued); last frame=\(directPresented); waiting-for-IDR drops=\(waitingDrops); maximum decoder jobs=2; no sample-buffer display renderer; phone thermal=\(ProcessInfo.processInfo.thermalState.rawValue). Layer commits are not physical head-unit presentation timestamps.")
            return
        }
        lastMetricsAt = now
        CarPlayLiveDiagnostics.shared.record("Video pipeline: enqueued=\(enqueued); waiting-for-IDR drops=\(waitingDrops); backpressure drops=\(backpressureDrops); enqueue ready=\(video.isReadyForMoreMediaData); display ready=\(displayReady); layer status=\(video.status.rawValue); window attached=\(view.window != nil); screen max FPS=\(view.window?.screen.maximumFramesPerSecond ?? 0); phone thermal=\(ProcessInfo.processInfo.thermalState.rawValue). Enqueued frames are not head-unit presentation frames.")
        guard #available(iOS 17.4, *) else { return }
        metricsPending = true
        let epoch = videoEpoch
        video.sampleBufferRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            Task { @MainActor in
                guard let self, self.videoEpoch == epoch else { return }
                self.metricsPending = false
                guard let metrics else {
                    CarPlayLiveDiagnostics.shared.record("iOS video renderer metrics unavailable")
                    return
                }
                let frames = Int(metrics.totalNumberOfFrames)
                let delay = metrics.totalAccumulatedFrameDelay
                if let previous = self.previousRendererMetric, frames > previous.frames, delay >= previous.delay {
                    let count = frames - previous.frames
                    CarPlayLiveDiagnostics.shared.record("iOS renderer interval: frames=\(count); added accumulated delay seconds=\(delay-previous.delay); mean recorded delay per frame ms=\((delay-previous.delay)*1000/Double(count)). Renderer metric only; excludes physical head-unit latency.")
                }
                self.previousRendererMetric = (frames, delay)
                CarPlayLiveDiagnostics.shared.record("iOS renderer metrics: total frames=\(metrics.totalNumberOfFrames); dropped=\(metrics.numberOfDroppedFrames); corrupted=\(metrics.numberOfCorruptedFrames); optimized-compositing frames=\(metrics.numberOfFramesDisplayedUsingOptimizedCompositing); accumulated presentation delay seconds=\(metrics.totalAccumulatedFrameDelay). These describe the iOS renderer, not capture-to-head-unit latency.")
            }
        }
    }

    private var displayReady: Bool {
        if directDisplay { return directLayer.contents != nil }
        if #available(iOS 17.4, *) { return video.isReadyForDisplay }
        return video.status == .rendering
    }

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        video.videoGravity = .resizeAspect
        directLayer.contentsGravity = .resizeAspect
        view.layer.addSublayer(video)
        view.layer.addSublayer(directLayer)
        video.isHidden = directDisplay
        directLayer.isHidden = !directDisplay
        status.textColor = .white
        status.textAlignment = .center
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .headline)
        view.addSubview(status)
    }

    func useRenderer(direct: Bool) {
        guard directDisplay != direct else { return }
        directDisplay = direct
        videoEpoch = UUID()
        directDecoder?.stop(); directDecoder = nil
        video.flushAndRemoveImage()
        directLayer.contents = nil; directPresented = 0
        waitingForKeyframe = true; lastVideoFrame = nil
        enqueued = 0; waitingDrops = 0; backpressureDrops = 0
        previousRendererMetric = nil; metricsPending = false; lastMetricsAt = 0
        guard isViewLoaded else { return }
        video.isHidden = direct
        directLayer.isHidden = !direct
        status.text = "Switching display—waiting for a fresh video frame…"
        status.isHidden = false
        refreshVideoLayout()
        CarPlayLiveDiagnostics.shared.record("Renderer changed in existing video connection: \(direct ? "direct" : "standard"); waiting for keyframe; TCP/TLS session preserved")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshVideoLayout()
    }

    private func refreshVideoLayout() {
        guard isViewLoaded else { return }
        let area = CarPlayVideoLayout.visibleRect(in: view)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        video.frame = area; directLayer.frame = area
        CATransaction.commit()
        status.frame = area.insetBy(dx: 12, dy: 12)
        let description = "bounds=\(view.bounds); view safe frame=\(view.safeAreaLayoutGuide.layoutFrame); view insets=\(view.safeAreaInsets); window safe frame=\(view.window?.safeAreaLayoutGuide.layoutFrame ?? .zero); window insets=\(view.window?.safeAreaInsets ?? .zero); content video rect=\(area); renderer=\(directDisplay ? "direct" : "standard"); missing horizontal insets use left-only 60pt sidebar gutter; menu overlay allowed; map-button guide diagnostic only=\((view.window as? CPWindow)?.mapButtonSafeAreaLayoutGuide.layoutFrame ?? .zero)"
        if description != layoutDescription {
            layoutDescription = description
            CarPlayLiveDiagnostics.shared.record("CarPlay video layout: " + description)
        }
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        view.setNeedsLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard maintenance == nil else { return }
        CarPlayLiveDiagnostics.shared.record("Native Live View appeared; source=official Dom tablet protocol; APP ONLY; local LAN only; target=30 FPS")
        CarPlayLiveDiagnostics.shared.record("Live View renderer selected: \(directDisplay ? "direct VT decode / latest CGImage" : "standard sample-buffer display layer")")
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maintain()
                do { try await Task.sleep(for: .seconds(0.5)) } catch { return }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        maintenance?.cancel()
        maintenance = nil
        stop()
        CarPlayLiveDiagnostics.shared.record("Native Live View disappeared; stream stopped")
    }

    private func stop() {
        connection?.stop()
        connection = nil
        video.flushAndRemoveImage()
        directDecoder?.stop(); directDecoder = nil
        directLayer.contents = nil; directPresented = 0
        format = nil
        sps = Data()
        pps = Data()
        waitingForKeyframe = true
        lastVideoFrame = nil
        videoEpoch = UUID(); metricsPending = false
        previousRendererMetric = nil
        enqueued = 0; waitingDrops = 0; backpressureDrops = 0
        lastMetricsAt = 0
    }

    private func maintain() async {
        // CarPlay can finish laying out its chrome after the root view first
        // appears. Read current content insets even without a view resize.
        refreshVideoLayout()
        let lan = AppModel.shared.lan
        guard lan.connected, let endpoint = lan.endpoint else {
            if connection != nil { stop() }
            status.text = "Connect to comma over local Wi-Fi for Live View."
            status.isHidden = false
            return
        }
        if connection != nil && (sourceEndpoint != endpoint || sourceGeneration != lan.generation) {
            CarPlayLiveDiagnostics.shared.record("LAN identity or endpoint changed; resetting video stream")
            stop()
        }
        if connection != nil && ProcessInfo.processInfo.systemUptime - lastPacket > 15 {
            CarPlayLiveDiagnostics.shared.record("Video stalled: no packet for 15 seconds; clearing display and reconnecting")
            stop()
            reconnectAt = ProcessInfo.processInfo.systemUptime + 2
        }
        if let lastVideoFrame, ProcessInfo.processInfo.systemUptime - lastVideoFrame > 3 {
            CarPlayLiveDiagnostics.shared.record("Video is stale: no enqueued frame for 3 seconds; clearing the old image")
            stop()
            reconnectAt = ProcessInfo.processInfo.systemUptime + 2
            status.text = "Waiting for fresh local video…"
            status.isHidden = false
        }
        guard connection == nil, !awaitingTrust, !trustRejected, ProcessInfo.processInfo.systemUptime >= reconnectAt else { return }
        do {
            let generation = lan.generation
            guard let identity = lan.verifiedDeviceID, let host = endpoint.host else { return }
            let pinKey = "StarPortVideoCertificate." + SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let certificate = UserDefaults.standard.data(forKey: pinKey)
            guard lan.connected, lan.endpoint == endpoint, lan.generation == generation else { return }
            sourceEndpoint = endpoint
            sourceGeneration = generation
            lastPacket = ProcessInfo.processInfo.systemUptime
            status.text = "Starting local Live View…"
            status.isHidden = false
            CarPlayLiveDiagnostics.shared.record("Starting APP-ONLY tablet TCP receiver on port 5277; no patched HTTP route; no comma setting writes; no tunnel or Bluetooth fallback")
            connection = CarPlayVideoConnection(host: host, certificate: certificate, received: { [weak self] packet, consumed in
                guard let self else { consumed(); return }
                try self.receive(packet, consumed: consumed)
            }, ended: { [weak self] error in
                guard let self else { return }
                CarPlayLiveDiagnostics.shared.record("Video connection ended: \(error.map { LANTransport.failureCode($0) } ?? "server closed stream")")
                self.stop()
                if let receiverError = error as? StarPortReceiverError,
                   case .certificateApprovalRequired(let certificate) = receiverError {
                    self.requestCertificateApproval(certificate, pinKey: pinKey, identity: identity)
                    return
                }
                if let receiverError = error as? StarPortReceiverError, case .certificateChanged = receiverError {
                    self.trustRejected = true
                    self.status.text = "Local video certificate changed. Recheck the comma identity before trusting a replacement."
                    self.status.isHidden = false
                    return
                }
                self.status.text = "Local video unavailable. While parked, enable StarPort and select tablet / HeadunitPad mode in Galaxy."
                self.status.isHidden = false
                self.reconnectAt = ProcessInfo.processInfo.systemUptime + 3
            })
        } catch {
            if Task.isCancelled { return }
            CarPlayLiveDiagnostics.shared.record("Video setup failed: \(LANTransport.failureCode(error))")
            reconnectAt = ProcessInfo.processInfo.systemUptime + 3
        }
    }

    private func requestCertificateApproval(_ certificate: Data, pinKey: String, identity: String) {
        guard AppModel.shared.lan.connected, AppModel.shared.lan.verifiedDeviceID == identity,
              view.window != nil, let interfaceController else { return }
        awaitingTrust = true
        let fingerprint = SHA256.hash(data: certificate).prefix(6).map { String(format: "%02X", $0) }.joined(separator: ":")
        status.text = "Approve this comma’s local video certificate to continue."
        status.isHidden = false
        let approve = CPAlertAction(title: "Trust local comma", style: .default) { [weak self, weak interfaceController] _ in
            guard let self else { return }
            if AppModel.shared.lan.connected, AppModel.shared.lan.verifiedDeviceID == identity {
                UserDefaults.standard.set(certificate, forKey: pinKey)
                CarPlayLiveDiagnostics.shared.record("Local video certificate explicitly approved; fingerprint=\(fingerprint); pin follows paired identity across IP changes")
            }
            self.awaitingTrust = false
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        let cancel = CPAlertAction(title: "Cancel", style: .cancel) { [weak self, weak interfaceController] _ in
            self?.awaitingTrust = false; self?.trustRejected = true
            interfaceController?.dismissTemplate(animated: true, completion: nil)
        }
        interfaceController.presentTemplate(CPAlertTemplate(titleVariants: ["Trust local video from your paired comma? Certificate \(fingerprint)"], actions: [cancel, approve]), animated: true) { [weak self] success, _ in
            if !success { self?.awaitingTrust = false; self?.trustRejected = true }
        }
    }

    private func receive(_ packet: CarPlayVideoPacket, consumed: @escaping () -> Void) throws {
        var acknowledgeAfterDecode = false
        defer { if !acknowledgeAfterDecode { consumed() } }
        let deliveryUptime = ProcessInfo.processInfo.systemUptime
        let lan = AppModel.shared.lan
        guard lan.connected, lan.endpoint == sourceEndpoint, lan.generation == sourceGeneration else {
            throw CancellationError()
        }
        lastPacket = ProcessInfo.processInfo.systemUptime
        guard !packet.payload.isEmpty else { return }
        let units = Self.nalUnits(packet.payload)
        let keyframe = units.contains { $0.first.map { $0 & 31 == 5 } ?? false }
        if let next = units.first(where: { $0.first.map { $0 & 31 == 7 } ?? false }), next != sps {
            sps = next
            format = nil
            waitingForKeyframe = true
        }
        if let next = units.first(where: { $0.first.map { $0 & 31 == 8 } ?? false }), next != pps {
            pps = next
            format = nil
            waitingForKeyframe = true
        }
        if !directDisplay && video.status == .failed {
            CarPlayLiveDiagnostics.shared.record("Video layer failed; waiting for keyframe; error=\(video.error.map { LANTransport.failureCode($0) } ?? "none")")
            video.flushAndRemoveImage()
            waitingForKeyframe = true
        }
        guard !waitingForKeyframe || keyframe else {
            waitingDrops += 1
            return
        }
        guard directDisplay || video.isReadyForMoreMediaData else {
            backpressureDrops += 1
            waitingForKeyframe = true
            CarPlayLiveDiagnostics.shared.record("Video layer backpressure; discarding dependent frames until next keyframe")
            return
        }
        if format == nil {
            guard !sps.isEmpty, !pps.isEmpty else { return }
            let result = sps.withUnsafeBytes { sequence in
                pps.withUnsafeBytes { picture in
                    let pointers = [sequence.bindMemory(to: UInt8.self).baseAddress!, picture.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                }
            }
            guard result == noErr else { throw BridgeError.message("H.264 format failed (\(result)).") }
        }
        guard let format else { return }
        var payload = Data()
        for unit in units where unit.first.map({ ![7, 8, 9].contains(Int($0 & 31)) }) ?? false {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
            payload.append(unit)
        }
        guard !payload.isEmpty else { return }
        var block: CMBlockBuffer?
        var result = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &block)
        guard result == noErr, let block else { throw BridgeError.message("Video allocation failed (\(result)).") }
        result = payload.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard result == noErr else { throw BridgeError.message("Video buffer copy failed (\(result)).") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: CMTime(value: Int64(clamping: packet.frameID), timescale: 30),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = payload.count
        result = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard result == noErr, let sample else { throw BridgeError.message("Video sample failed (\(result)).") }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let beforeEnqueue = ProcessInfo.processInfo.systemUptime
        if directDisplay {
            if directDecoder == nil { directDecoder = StarPortVideoDecoder() }
            let epoch = videoEpoch
            acknowledgeAfterDecode = true
            waitingForKeyframe = false
            directDecoder?.decode(sample, frameID: packet.frameID) { [weak self] result in
                Task { @MainActor in
                    defer { consumed() }
                    guard let self, self.videoEpoch == epoch else { return }
                    switch result {
                    case .success(let picture):
                        guard picture.frameID > self.directPresented else { return }
                        let commit = ProcessInfo.processInfo.systemUptime
                        CATransaction.begin(); CATransaction.setDisableActions(true)
                        self.directLayer.contents = picture.image
                        CATransaction.commit()
                        self.directPresented = picture.frameID
                        self.lastVideoFrame = commit
                        self.enqueued += 1
                        self.status.isHidden = true
                        CarPlayLiveDiagnostics.shared.record("Direct frame=\(picture.frameID); sender media clock ns=\(packet.captureClock); delivery uptime=\(deliveryUptime); decode queue ms=\((picture.decodeStarted-picture.submitted)*1000); decode ms=\((picture.decoded-picture.decodeStarted)*1000); image conversion ms=\((picture.imageReady-picture.decoded)*1000); decoded-to-main ms=\((commit-picture.imageReady)*1000); hardware decoder=\(picture.hardware.map(String.init) ?? "unknown"); layer commit uptime=\(commit). Not physical head-unit presentation.", includeInConnectionLog: self.enqueued == 1 || self.enqueued % 60 == 0)
                        self.logRendererMetrics()
                    case .failure(let error):
                        self.waitingForKeyframe = true
                        self.directDecoder?.stop(); self.directDecoder = nil
                        self.directLayer.contents = nil
                        self.status.text = "Direct display is recovering. Use the menu to return to Live View."
                        self.status.isHidden = false
                        CarPlayLiveDiagnostics.shared.record("Direct decoder failed; waiting for next keyframe: \(error)")
                    }
                }
            }
            return
        }
        video.enqueue(sample)
        let afterEnqueue = ProcessInfo.processInfo.systemUptime
        lastVideoFrame = ProcessInfo.processInfo.systemUptime
        waitingForKeyframe = false
        status.isHidden = displayReady
        enqueued += 1
        CarPlayLiveDiagnostics.shared.record("H264 frame=\(packet.frameID); bytes=\(packet.payload.count); keyframe=\(keyframe); source age us=\(packet.sourceAgeMicroseconds); encode us=\(packet.encodeMicroseconds); source capture clock ns=\(packet.captureClock); app delivery uptime=\(deliveryUptime); sample build ms=\((beforeEnqueue - deliveryUptime) * 1000); enqueue call ms=\((afterEnqueue - beforeEnqueue) * 1000); layer status=\(video.status.rawValue); display readiness indicator=\(displayReady)", includeInConnectionLog: enqueued == 1 || enqueued % 60 == 0)
        logRendererMetrics()
    }

    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(offset: Int, size: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if index + 3 < bytes.count && bytes[index...index + 3].elementsEqual([0, 0, 0, 1]) {
                starts.append((index, 4))
                index += 4
            } else if bytes[index...index + 2].elementsEqual([0, 0, 1]) {
                starts.append((index, 3))
                index += 3
            } else { index += 1 }
        }
        return starts.enumerated().compactMap { position, start in
            let end = position + 1 < starts.count ? starts[position + 1].offset : bytes.count
            let begin = start.offset + start.size
            return begin < end ? Data(bytes[begin..<end]) : nil
        }
    }
}
