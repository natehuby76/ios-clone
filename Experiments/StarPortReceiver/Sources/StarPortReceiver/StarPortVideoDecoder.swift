import Foundation
import VideoToolbox
import CoreImage

public enum StarPortVideoDecodeError: Error {
    case stopped, overloaded, failed(OSStatus), noPicture
}

public struct StarPortDecodedPicture: @unchecked Sendable {
    public let image: CGImage
    public let frameID: UInt64
    public let submitted: Double
    public let decodeStarted: Double
    public let decoded: Double
    public let imageReady: Double
    public let hardware: Bool?
}

/// An optional comparison path: synchronous VT decoding on one worker, no
/// temporal-processing flag, then a CGImage for the ordinary window compositor.
/// The caller acknowledges media only after this operation completes. This
/// removes the sample-buffer display renderer from the comparison, not the
/// system's CarPlay encoder or the head unit's own buffering.
public final class StarPortVideoDecoder: @unchecked Sendable {
    private final class Output {
        var pixel: CVPixelBuffer?
        var status: OSStatus = noErr
    }
    private let queue = DispatchQueue(label: "StarPilot.video-decode", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private var pending = 0
    private var session: VTDecompressionSession?
    private var format: CMFormatDescription?
    private let images = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
    private var hardware: Bool?

    public init() {}

    public func decode(_ sample: CMSampleBuffer, frameID: UInt64,
                       completion: @escaping (Result<StarPortDecodedPicture, Error>) -> Void) {
        let submitted = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped, pending < 2 else {
            let error: StarPortVideoDecodeError = stopped ? .stopped : .overloaded
            lock.unlock(); completion(.failure(error)); return
        }
        pending += 1; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); pending -= 1; lock.unlock() }
            do {
                lock.lock(); let cancelled = stopped; lock.unlock()
                guard !cancelled else { throw StarPortVideoDecodeError.stopped }
                guard let next = CMSampleBufferGetFormatDescription(sample) else { throw StarPortVideoDecodeError.noPicture }
                if format == nil || !CMFormatDescriptionEqual(format!, otherFormatDescription: next) {
                    if let session { VTDecompressionSessionInvalidate(session) }
                    session = nil; format = next
                    var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { _, ref, status, _, pixel, _, _ in
                        guard let ref else { return }
                        let output = Unmanaged<Output>.fromOpaque(ref).takeUnretainedValue()
                        output.status = status; output.pixel = pixel
                    }, decompressionOutputRefCon: nil)
                    let attributes: [String: Any] = [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
                    ]
                    let result = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: next,
                        decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
                        outputCallback: &callback, decompressionSessionOut: &session)
                    guard result == noErr, let session else { throw StarPortVideoDecodeError.failed(result) }
                    // RealTime defaults to true. Set explicitly for traceability;
                    // it is not itself a claim that this mode reduces latency.
                    VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
                    var value: CFTypeRef?
                    let read = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                        allocator: kCFAllocatorDefault, valueOut: &value)
                    hardware = read == noErr ? (value as? NSNumber)?.boolValue : nil
                }
                guard let session else { throw StarPortVideoDecodeError.noPicture }
                let output = Output()
                let start = ProcessInfo.processInfo.systemUptime
                // With both asynchronous and temporal flags clear, Apple's
                // contract calls the callback before this function returns.
                let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                    frameRefcon: Unmanaged.passUnretained(output).toOpaque(), infoFlagsOut: nil)
                let decoded = ProcessInfo.processInfo.systemUptime
                guard result == noErr else { throw StarPortVideoDecodeError.failed(result) }
                guard output.status == noErr else { throw StarPortVideoDecodeError.failed(output.status) }
                guard let pixel = output.pixel else { throw StarPortVideoDecodeError.noPicture }
                let ci = CIImage(cvPixelBuffer: pixel)
                guard let image = images.createCGImage(ci, from: ci.extent) else { throw StarPortVideoDecodeError.noPicture }
                lock.lock(); let cancelledAfterDecode = stopped; lock.unlock()
                guard !cancelledAfterDecode else { throw StarPortVideoDecodeError.stopped }
                completion(.success(StarPortDecodedPicture(image: image, frameID: frameID, submitted: submitted,
                    decodeStarted: start, decoded: decoded, imageReady: ProcessInfo.processInfo.systemUptime, hardware: hardware)))
            } catch { completion(.failure(error)) }
        }
    }

    public func stop() {
        lock.lock(); stopped = true; lock.unlock()
        queue.async { [self] in
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil; format = nil
        }
    }
}
