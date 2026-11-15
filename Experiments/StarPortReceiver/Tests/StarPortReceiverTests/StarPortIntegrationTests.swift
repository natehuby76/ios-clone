import XCTest
@testable import StarPortReceiver

final class StarPortIntegrationTests: XCTestCase {
    func testOfficialDomFrameAcknowledgements() throws { try run("frame") }
    func testOfficialDomFragmentAcknowledgements() throws { try run("fragment") }
    func testUnapprovedCertificateRequiresExplicitApproval() throws { try run("approval") }
    func testChangedCertificateIsRejected() throws { try run("changed") }

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
        let lock = NSLock(); var received = 0; var failure: Error?
        let trusted: Data? = mode == "approval" ? nil : (mode == "changed" ? Data([1]) : certificate)
        let client = StarPortClient(host: "127.0.0.1", port: UInt16(port), certificate: trusted,
            fragmentACKs: mode == "fragment", allowLoopbackForTest: true, log: { print($0) },
            video: { bytes, number, timestamp, consumed in
                lock.lock(); received += 1; lock.unlock()
                XCTAssertEqual(bytes.count, 48005)
                XCTAssertEqual(bytes.last, UInt8(16 + number))
                XCTAssertEqual(timestamp, (number - 1) * 33333)
                consumed()
            }, ended: { error in
                if mode == "approval", case StarPortReceiverError.certificateApprovalRequired(let presented) = error {
                    XCTAssertEqual(presented, certificate)
                } else if mode == "changed", case StarPortReceiverError.certificateChanged = error {
                } else if mode == "frame" || mode == "fragment", case StarPortReceiverError.closed = error {
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
            XCTAssertEqual(received, 10)
            XCTAssertTrue(String(decoding: result, as: UTF8.self).contains("\"acked\": 10"))
        }
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
