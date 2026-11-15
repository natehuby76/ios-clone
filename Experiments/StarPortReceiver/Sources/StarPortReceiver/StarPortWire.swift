import Foundation

public enum StarPortWireError: Error {
    case malformedFrame, sizeLimit, unexpectedFragment, invalidMessageLength
}

/// Android Auto's outer framing. TLS remains inside these records; it must not
/// be applied directly to the TCP socket as ordinary HTTPS would do.
public struct StarPortFrame: Equatable {
    public let channel: UInt8
    public let flags: UInt8
    public let messageLength: Int?
    public let payload: Data
    public var first: Bool { flags & 1 != 0 }
    public var last: Bool { flags & 2 != 0 }
    public var encrypted: Bool { flags & 8 != 0 }
    public var control: Bool { flags & 4 != 0 }

    public init(channel: UInt8, flags: UInt8, messageLength: Int? = nil, payload: Data) {
        self.channel = channel; self.flags = flags
        self.messageLength = messageLength; self.payload = payload
    }

    public func encoded() throws -> Data {
        guard flags & 0xf0 == 0, !payload.isEmpty, payload.count <= 65535,
              (flags & 3 == 1) == (messageLength != nil) else { throw StarPortWireError.malformedFrame }
        if let messageLength {
            guard (2...StarPortMessageAssembler.maximumMessage).contains(messageLength) else { throw StarPortWireError.sizeLimit }
        }
        var data = Data([channel, flags, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        if let messageLength {
            let value = UInt32(messageLength)
            for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
        }
        data.append(payload)
        return data
    }
}

public struct StarPortFrameParser {
    private var pending = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [StarPortFrame] {
        guard data.count <= 1024 * 1024 else { throw StarPortWireError.sizeLimit }
        pending.append(data)
        var output: [StarPortFrame] = []
        while pending.count >= 4 {
            let header = [UInt8](pending.prefix(8))
            let flags = header[1]
            guard flags & 0xf0 == 0 else { throw StarPortWireError.malformedFrame }
            let size = Int(header[2]) << 8 | Int(header[3])
            guard size > 0 else { throw StarPortWireError.malformedFrame }
            let headerSize = flags & 3 == 1 ? 8 : 4
            guard pending.count >= headerSize else { break }
            let length = headerSize == 8 ? header[4..<8].reduce(0) { ($0 << 8) | Int($1) } : nil
            if let length {
                guard (2...StarPortMessageAssembler.maximumMessage).contains(length) else { throw StarPortWireError.sizeLimit }
            }
            guard pending.count >= headerSize + size else { break }
            output.append(StarPortFrame(channel: header[0], flags: flags, messageLength: length,
                payload: Data(pending.dropFirst(headerSize).prefix(size))))
            pending = Data(pending.dropFirst(headerSize + size))
        }
        guard pending.count <= 65535 + 8 else { throw StarPortWireError.sizeLimit }
        return output
    }
}

public struct StarPortMessage: Equatable {
    public let channel: UInt8
    public let kind: UInt16
    public let body: Data
}

/// Receives each outer record *after* its payload has been decrypted. The total
/// length in a first-fragment header describes plaintext, not TLS ciphertext.
public struct StarPortMessageAssembler {
    public static let maximumMessage = 4 * 1024 * 1024
    private struct Partial { var bytes: Data; let expected: Int; let flags: UInt8 }
    private var partials: [UInt8: Partial] = [:]
    public init() {}

    public mutating func accept(_ frame: StarPortFrame, plaintext: Data) throws -> StarPortMessage? {
        guard !plaintext.isEmpty, plaintext.count <= Self.maximumMessage else { throw StarPortWireError.sizeLimit }
        let attributes = frame.flags & 12
        var bytes: Data
        if frame.first {
            guard partials[frame.channel] == nil else { throw StarPortWireError.unexpectedFragment }
            if frame.last {
                guard frame.messageLength == nil else { throw StarPortWireError.malformedFrame }
                bytes = plaintext
            } else {
                guard let expected = frame.messageLength, expected >= plaintext.count,
                      expected <= Self.maximumMessage, partials.count < 4 else { throw StarPortWireError.sizeLimit }
                partials[frame.channel] = Partial(bytes: plaintext, expected: expected, flags: attributes)
                return nil
            }
        } else {
            guard var partial = partials.removeValue(forKey: frame.channel), partial.flags == attributes,
                  frame.messageLength == nil else { throw StarPortWireError.unexpectedFragment }
            guard plaintext.count <= partial.expected - partial.bytes.count else { throw StarPortWireError.sizeLimit }
            partial.bytes.append(plaintext)
            if !frame.last {
                partials[frame.channel] = partial
                return nil
            }
            guard partial.bytes.count == partial.expected else { throw StarPortWireError.invalidMessageLength }
            bytes = partial.bytes
        }
        guard bytes.count >= 2 else { throw StarPortWireError.invalidMessageLength }
        let kind = bytes.prefix(2).reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        return StarPortMessage(channel: frame.channel, kind: kind, body: Data(bytes.dropFirst(2)))
    }
}
