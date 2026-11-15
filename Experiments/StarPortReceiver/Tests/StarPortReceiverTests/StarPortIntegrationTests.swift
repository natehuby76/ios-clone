import XCTest
import CoreMedia
@testable import StarPortReceiver

final class StarPortIntegrationTests: XCTestCase {
    func testOfficialDomFrameAcknowledgements() throws { try run("frame") }
    func testOfficialDomFragmentAcknowledgements() throws { try run("fragment") }
    func testUnapprovedCertificateRequiresExplicitApproval() throws { try run("approval") }
    func testChangedCertificateIsRejected() throws { try run("changed") }
    func testRealH264PicturesSurviveSwiftTLSReceiver() throws { try run("media") }

    private func run(_ mode: String) throws {
        guard ProcessInfo.processInfo.environment["STARPORT_OFFICIAL_SOURCE"] != nil else {
            throw XCTSkip("Set STARPORT_OFFICIAL_SOURCE to the pinned official Dom checkout")
        }
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("official_server.py")
        server.arguments = ["python3", script.path, mode]
        let output = Pipe(); server.standardOutput = output
        try server.run(); defer { if server.isRunning { server.terminate() } }
        var line = Data()
        while let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }; line.append(byte)
        }
        let ready = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        let port = try XCTUnwrap(ready["port"] as? Int)
        let certificate = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(ready["certificate"] as? String)))
        let finished = expectation(description: "Official Dom received all ACKs and shutdown response")
        let lock = NSLock(); var received = 0; var failure: Error?; var receivedMedia = Data()
        var mediaPackets: [Data] = []
        let trusted: Data? = mode == "approval" ? nil : (mode == "changed" ? Data([1]) : certificate)
        let client = StarPortClient(host: "127.0.0.1", port: UInt16(port), certificate: trusted,
            fragmentACKs: mode == "fragment" || mode == "media", allowLoopbackForTest: true, log: { print($0) },
            video: { bytes, number, timestamp, consumed in
                lock.lock(); received += 1
                if mode == "media" { receivedMedia.append(bytes); mediaPackets.append(bytes) }
                lock.unlock()
                if mode != "media" {
                    XCTAssertEqual(bytes.count, 48005)
                    XCTAssertEqual(bytes.last, UInt8(16 + number))
                    XCTAssertEqual(timestamp, (number - 1) * 33333)
                }
                consumed()
            }, ended: { error in
                if mode == "approval", case StarPortReceiverError.certificateApprovalRequired(let presented) = error {
                    XCTAssertEqual(presented, certificate)
                } else if mode == "changed", case StarPortReceiverError.certificateChanged = error {
                } else if ["frame", "fragment", "media"].contains(mode), case StarPortReceiverError.closed = error {
                } else { failure = error }
                finished.fulfill()
            })
        wait(for: [finished], timeout: 25)
        client.stop()
        server.waitUntilExit()
        XCTAssertNil(failure)
        let result = try output.fileHandleForReading.readToEnd() ?? Data()
        if mode == "approval" || mode == "changed" {
            XCTAssertNotEqual(server.terminationStatus, 0)
            XCTAssertEqual(received, 0)
        } else {
            XCTAssertEqual(server.terminationStatus, 0)
            XCTAssertEqual(received, mode == "media" ? 11 : 10) // SPS/PPS plus ten pictures
            XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("\"acked\": 10"))
            if mode == "media" {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".h264")
                try receivedMedia.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }
                let decode = Process(); decode.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                decode.arguments = ["python3", script.path, "decode", file.path]
                try decode.run(); decode.waitUntilExit()
                XCTAssertEqual(decode.terminationStatus, 0, "Real receiver output must decode into the ten expected pictures")
                try verifyAppleDecoder(mediaPackets)
            }
        }
    }

    private func verifyAppleDecoder(_ packets: [Data]) throws {
        var sps = Data(), pps = Data()
        var format: CMVideoFormatDescription?
        let decoder = StarPortVideoDecoder()
        defer { decoder.stop() }
        var decoded = 0
        for packet in packets {
            // Native Dom sends codec configuration separately from pictures.
            let bytes = [UInt8](packet)
            var starts: [(Int, Int)] = []; var offset = 0
            while offset + 2 < bytes.count {
                if offset + 3 < bytes.count && bytes[offset...offset+3].elementsEqual([0,0,0,1]) {
                    starts.append((offset,4)); offset += 4
                } else if bytes[offset...offset+2].elementsEqual([0,0,1]) {
                    starts.append((offset,3)); offset += 3
                } else { offset += 1 }
            }
            let units = starts.enumerated().compactMap { index, start -> Data? in
                let end = index + 1 < starts.count ? starts[index+1].0 : bytes.count
                let begin = start.0 + start.1
                return end > begin ? Data(bytes[begin..<end]) : nil
            }
            if let value = units.first(where: { ($0.first ?? 0) & 31 == 7 }) { sps = value }
            if let value = units.first(where: { ($0.first ?? 0) & 31 == 8 }) { pps = value }
            var payload = Data()
            for unit in units where ![7,8,9].contains(Int((unit.first ?? 0) & 31)) {
                var length = UInt32(unit.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }; payload.append(unit)
            }
            if payload.isEmpty { continue }
            if format == nil {
                XCTAssertFalse(sps.isEmpty); XCTAssertFalse(pps.isEmpty)
                let result = sps.withUnsafeBytes { sequence in pps.withUnsafeBytes { picture in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: [sequence.bindMemory(to: UInt8.self).baseAddress!, picture.bindMemory(to: UInt8.self).baseAddress!],
                        parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
                } }
                XCTAssertEqual(result, noErr)
            }
            let description = try XCTUnwrap(format)
            var block: CMBlockBuffer?
            XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: payload.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block), noErr)
            let data = try XCTUnwrap(block)
            XCTAssertEqual(payload.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
                blockBuffer: data, offsetIntoDestination: 0, dataLength: payload.count) }, noErr)
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(decoded), timescale: 30), decodeTimeStamp: .invalid)
            var size = payload.count; var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: data,
                formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
            let ready = expectation(description: "Apple decoder produced frame \(decoded)")
            decoder.decode(try XCTUnwrap(sample), frameID: UInt64(decoded + 1)) { result in
                switch result {
                case .success(let image):
                    XCTAssertEqual(image.image.width, 1280); XCTAssertEqual(image.image.height, 720)
                    XCTAssertGreaterThanOrEqual(image.decoded, image.decodeStarted)
                    XCTAssertGreaterThanOrEqual(image.imageReady, image.decoded)
                case .failure(let error): XCTFail("Apple decoder failed: \(error)")
                }
                ready.fulfill()
            }
            wait(for: [ready], timeout: 5)
            decoded += 1
        }
        XCTAssertEqual(decoded, 10)
        print("Apple VideoToolbox comparison decoder: ten generated pictures decoded and converted to CGImage")
    }

    func testLocalAddressRestrictionsAndMalformedProtobuf() throws {
        XCTAssertTrue(StarPortClient.privateIPv4("172.20.10.2"))
        XCTAssertTrue(StarPortClient.privateIPv4("192.168.10.83"))
        for value in ["127.0.0.1", "8.8.8.8", "172.32.0.1", "comma.local", "192.168.1.999", "10.0.1"] {
            XCTAssertFalse(StarPortClient.privateIPv4(value), value)
        }
        XCTAssertEqual(try StarPortSession.integerField(1, StarPortSession.field(1, 12345)), 12345)
        XCTAssertThrowsError(try StarPortSession.integerField(1, Data([8, 128])))
    }
}
