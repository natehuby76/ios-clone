import Foundation

// Minimal read-only receiver: no audio, input, navigation, sensors, pairing
// commands or vehicle controls are advertised. Protocol values follow Dom's
// existing ProjectionSession, not an Android app implementation.
final class StarPortSession {
    private var parser = StarPortFrameParser()
    private var assembler = StarPortMessageAssembler()
    private var tls: StarPortTLS?
    private let certificate: Data?
    private var sessionID: UInt64?
    private var fragments = 0
    private var frameNumber: UInt64 = 0
    let fragmentACKs: Bool
    var write: (Data) throws -> Void
    var log: (String) -> Void
    var video: (Data, UInt64, UInt64, @escaping () -> Void) -> Void

    init(certificate: Data?, fragmentACKs: Bool,
         write: @escaping (Data) throws -> Void, log: @escaping (String) -> Void,
         video: @escaping (Data, UInt64, UInt64, @escaping () -> Void) -> Void) {
        self.certificate = certificate; self.fragmentACKs = fragmentACKs
        self.write = write; self.log = log; self.video = video
    }

    func start() throws { try send(0, 1, Data([0, 1, 0, 7]), encrypted: false); log("Version request sent") }

    func feed(_ bytes: Data) throws {
        for frame in try parser.append(bytes) {
            let plain: Data
            if frame.encrypted {
                guard let tls, tls.complete else { throw StarPortReceiverError.protocolFailure("Media before TLS") }
                plain = try tls.decrypt(frame.payload)
            } else { plain = frame.payload }
            if !frame.encrypted, tls?.complete == true {
                throw StarPortReceiverError.protocolFailure("Plaintext after TLS authentication")
            }
            if frame.channel == 3 { fragments += 1 }
            if let message = try assembler.accept(frame, plaintext: plain) {
                let count = fragments; if frame.channel == 3 { fragments = 0 }
                try receive(message, fragments: count)
            }
        }
    }

    private func send(_ channel: UInt8, _ kind: UInt16, _ body: Data = Data(), encrypted: Bool = true, control: Bool = false) throws {
        var payload = Data([UInt8(kind >> 8), UInt8(truncatingIfNeeded: kind)])
        payload.append(body)
        if encrypted {
            guard let tls, tls.complete else { throw StarPortReceiverError.protocolFailure("TLS not ready") }
            payload = try tls.encrypt(payload)
        }
        try write(StarPortFrame(channel: channel, flags: 3 | (encrypted ? 8 : 0) | (control ? 4 : 0), payload: payload).encoded())
    }

    private func advanceTLS(_ data: Data) throws {
        guard let tls else { throw StarPortReceiverError.protocolFailure("TLS not initialized") }
        let outgoing = try tls.handshake(data)
        if !outgoing.isEmpty { try send(0, 3, outgoing, encrypted: false) }
        if tls.complete { try send(0, 4, Self.field(1, 0), encrypted: false); log("TLS complete; approved certificate matched") }
    }

    private func receive(_ message: StarPortMessage, fragments: Int) throws {
        let channel = message.channel, kind = message.kind, body = message.body
        if channel == 0 && kind == 2 {
            guard body.count == 6, body.suffix(2) == Data([0, 0]) else { throw StarPortReceiverError.protocolFailure("Version rejected") }
            tls = try StarPortTLS(certificate: certificate)
            try advanceTLS(Data())
        } else if channel == 0 && kind == 3 {
            try advanceTLS(body)
        } else {
            guard tls?.complete == true else { throw StarPortReceiverError.protocolFailure("Unexpected plaintext handshake message") }
            if channel == 0 && kind == 5 {
                // Resolution 2 = 1280x720, frame-rate enum 2 = 30 FPS.
                let config = Self.field(1, 2) + Self.field(2, 2) + Self.field(3, 0) + Self.field(4, 0) + Self.field(5, 160)
                let service = Self.field(1, 3) + Self.blob(4, config)
                let videoChannel = Self.field(1, 3) + Self.blob(3, service)
                try send(0, 6, Self.blob(1, videoChannel) + Self.blob(2, Data("StarPilot".utf8)) + Self.blob(3, Data("Local Live View".utf8)))
                log("Read-only video service advertised; 1280x720 at 30 FPS; ACK mode=\(fragmentACKs ? "fragment" : "frame")")
            } else if kind == 7 && channel == 3 {
                try send(3, 8, Self.field(1, 0), control: true)
            } else if channel == 0 && kind == 11 {
                try send(0, 12, body)
            } else if channel == 0 && kind == 15 {
                try send(0, 16); throw StarPortReceiverError.closed
            } else if channel == 3 && kind == 0x8000 {
                try send(3, 0x8003, Self.field(1, 2) + Self.field(2, 2) + Self.field(3, 0))
                log("Video setup accepted; receive window=2")
            } else if channel == 3 && kind == 0x8007 {
                try send(3, 0x8008, Self.field(1, 1) + Self.field(2, 0))
            } else if channel == 3 && kind == 0x8001 {
                sessionID = try Self.integerField(1, body)
                guard sessionID != nil else { throw StarPortReceiverError.protocolFailure("Missing video session") }
                log("Video session started")
            } else if channel == 3 && (kind == 0 || kind == 1) {
                guard let sessionID else { throw StarPortReceiverError.protocolFailure("Video without session") }
                if kind == 0 && body.count < 9 { throw StarPortReceiverError.protocolFailure("Truncated video timestamp") }
                let timestamp = kind == 0 ? body.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } : 0
                let payload = kind == 0 ? Data(body.dropFirst(8)) : body
                frameNumber += 1
                let acknowledgements = fragmentACKs ? fragments : 1
                video(payload, frameNumber, timestamp) { [weak self] in
                    guard let self else { return }
                    do {
                        for _ in 0..<acknowledgements { try self.send(3, 0x8004, Self.field(1, sessionID) + Self.field(2, 1)) }
                    } catch { self.log("ACK failed: \(error)") }
                }
            } else if channel == 3 && kind == 0x8002 {
                throw StarPortReceiverError.closed
            } else { log("Protocol message: channel=\(channel); kind=\(kind); bytes=\(body.count)") }
        }
    }

    static func varint(_ value: UInt64) -> Data {
        var value = value; var data = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; data.append(byte | (value == 0 ? 0 : 128)) } while value != 0
        return data
    }
    static func field(_ number: UInt64, _ value: UInt64) -> Data { varint(number << 3) + varint(value) }
    static func blob(_ number: UInt64, _ data: Data) -> Data { varint(number << 3 | 2) + varint(UInt64(data.count)) + data }
    static func integerField(_ number: UInt64, _ data: Data) throws -> UInt64? {
        let bytes = [UInt8](data); var offset = 0
        func read() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < bytes.count else { throw StarPortWireError.malformedFrame }
                let byte = bytes[offset]; offset += 1
                guard shift < 63 || byte < 2 else { throw StarPortWireError.malformedFrame }
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw StarPortWireError.malformedFrame
        }
        while offset < bytes.count {
            let key = try read()
            if key & 7 == 0 { let value = try read(); if key >> 3 == number { return value } }
            else if key & 7 == 2 { let length = try read(); guard length <= bytes.count - offset else { throw StarPortWireError.sizeLimit }; offset += Int(length) }
            else { throw StarPortWireError.malformedFrame }
        }
        return nil
    }
}
