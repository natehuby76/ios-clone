import AVFoundation
import CarPlay
import UIKit

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
private final class CarPlayVideoConnection: NSObject, @preconcurrency URLSessionDataDelegate, @preconcurrency URLSessionTaskDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var parser = CarPlayVideoParser()
    private var stopped = false
    private let received: (CarPlayVideoPacket) throws -> Void
    private let ended: (Error?) -> Void

    init(request: URLRequest, received: @escaping (CarPlayVideoPacket) throws -> Void, ended: @escaping (Error?) -> Void) {
        self.received = received
        self.ended = ended
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 360
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        task = session.dataTask(with: request)
        task?.resume()
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !stopped else { completionHandler(.cancel); return }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        CarPlayLiveDiagnostics.shared.record("Video HTTP response: status=\(status); MIME=\(response.mimeType ?? "none"); transport=local LAN; cellular disabled")
        guard status == 200, response.mimeType == "application/x-starpilot-h264" else {
            completionHandler(.cancel)
            finish(BridgeError.message("Local Live View request failed (HTTP \(status))."))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped else { return }
        do {
            for packet in try parser.append(data) { try received(packet) }
        } catch { finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !stopped else { return }
        finish(error)
    }

    private func finish(_ error: Error?) {
        stop()
        ended(error)
    }
}

@MainActor
final class CarPlayLiveVideoController: UIViewController {
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

    override func loadView() {
        view = UIView()
        view.backgroundColor = .black
        video.videoGravity = .resizeAspect
        view.layer.addSublayer(video)
        status.textColor = .white
        status.textAlignment = .center
        status.numberOfLines = 0
        status.font = .preferredFont(forTextStyle: .headline)
        view.addSubview(status)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        video.frame = view.bounds
        status.frame = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 20, dy: 20)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard maintenance == nil else { return }
        CarPlayLiveDiagnostics.shared.record("Native Live View appeared; source=Dom hardware H.264; local LAN only; target=30 FPS")
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
        format = nil
        sps = Data()
        pps = Data()
        waitingForKeyframe = true
        lastVideoFrame = nil
    }

    private func maintain() async {
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
        guard connection == nil, ProcessInfo.processInfo.systemUptime >= reconnectAt else { return }
        do {
            let generation = lan.generation
            let request = try await lan.carPlayLiveRequest()
            try Task.checkCancellation()
            guard lan.connected, lan.endpoint == endpoint, lan.generation == generation else { return }
            sourceEndpoint = endpoint
            sourceGeneration = generation
            lastPacket = ProcessInfo.processInfo.systemUptime
            status.text = "Starting local Live View…"
            status.isHidden = false
            CarPlayLiveDiagnostics.shared.record("Starting authenticated LAN video request; no tunnel or Bluetooth fallback")
            connection = CarPlayVideoConnection(request: request, received: { [weak self] packet in
                try self?.receive(packet)
            }, ended: { [weak self] error in
                guard let self else { return }
                CarPlayLiveDiagnostics.shared.record("Video connection ended: \(error.map { LANTransport.failureCode($0) } ?? "server closed stream")")
                self.stop()
                self.status.text = "Reconnecting local Live View…"
                self.status.isHidden = false
                self.reconnectAt = ProcessInfo.processInfo.systemUptime + 3
            })
        } catch {
            if Task.isCancelled { return }
            CarPlayLiveDiagnostics.shared.record("Video setup failed: \(LANTransport.failureCode(error))")
            reconnectAt = ProcessInfo.processInfo.systemUptime + 3
        }
    }

    private func receive(_ packet: CarPlayVideoPacket) throws {
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
        if video.status == .failed {
            CarPlayLiveDiagnostics.shared.record("Video layer failed; waiting for keyframe; error=\(video.error.map { LANTransport.failureCode($0) } ?? "none")")
            video.flushAndRemoveImage()
            waitingForKeyframe = true
        }
        guard !waitingForKeyframe || keyframe else { return }
        guard video.isReadyForMoreMediaData else {
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
        video.enqueue(sample)
        lastVideoFrame = ProcessInfo.processInfo.systemUptime
        waitingForKeyframe = false
        status.isHidden = video.isReadyForDisplay
        enqueued += 1
        CarPlayLiveDiagnostics.shared.record("H264 frame=\(packet.frameID); bytes=\(packet.payload.count); keyframe=\(keyframe); source age us=\(packet.sourceAgeMicroseconds); encode us=\(packet.encodeMicroseconds); layer status=\(video.status.rawValue); ready for display=\(video.isReadyForDisplay)", includeInConnectionLog: enqueued == 1 || enqueued % 30 == 0)
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
