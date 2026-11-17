import Foundation
import Security

public enum StarPortReceiverError: Error {
    case tls(OSStatus), certificateApprovalRequired(Data), certificateChanged
    case protocolFailure(String), closed
}

// This private prototype needs TLS inside AA records, rather than TLS around
// TCP. SecureTransport's memory callbacks provide that ordering without a
// vendored crypto library. It is deprecated; replace before public release.
final class StarPortTLS {
    private let context: SSLContext
    private var incoming = Data()
    private var outgoing = Data()
    private let expectedCertificate: Data?
    private(set) var complete = false

    init(certificate: Data?) throws {
        expectedCertificate = certificate
        guard let context = SSLCreateContext(nil, .clientSide, .streamType) else {
            throw StarPortReceiverError.tls(errSecAllocate)
        }
        self.context = context
        try check(SSLSetProtocolVersionMin(context, .tlsProtocol12))
        try check(SSLSetProtocolVersionMax(context, .tlsProtocol12))
        try check(SSLSetSessionOption(context, .breakOnServerAuth, true))
        try check(SSLSetConnection(context, Unmanaged.passUnretained(self).toOpaque()))
        try check(SSLSetIOFuncs(context, { connection, bytes, length in
            let owner = Unmanaged<StarPortTLS>.fromOpaque(connection).takeUnretainedValue()
            let count = min(length.pointee, owner.incoming.count)
            if count > 0 {
                owner.incoming.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: count)
                owner.incoming = Data(owner.incoming.dropFirst(count))
            }
            let requested = length.pointee
            length.pointee = count
            return count == requested ? noErr : errSSLWouldBlock
        }, { connection, bytes, length in
            let owner = Unmanaged<StarPortTLS>.fromOpaque(connection).takeUnretainedValue()
            guard owner.outgoing.count + length.pointee <= 256 * 1024 else { return errSSLBufferOverflow }
            owner.outgoing.append(bytes.assumingMemoryBound(to: UInt8.self), count: length.pointee)
            return noErr
        }))
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw StarPortReceiverError.tls(status) }
    }

    func handshake(_ bytes: Data = Data()) throws -> Data {
        incoming.append(bytes)
        for _ in 0..<8 {
            let result = SSLHandshake(context)
            if result == errSSLPeerAuthCompleted {
                var trust: SecTrust?
                try check(SSLCopyPeerTrust(context, &trust))
                guard let trust, let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
                    throw StarPortReceiverError.protocolFailure("Missing local video certificate")
                }
                let presented = SecCertificateCopyData(certificate) as Data
                // Explicit first-use approval on CarPlay. Never silently replace
                // a pin, even when the paired comma changes IP addresses.
                guard let expectedCertificate else {
                    throw StarPortReceiverError.certificateApprovalRequired(presented)
                }
                guard presented == expectedCertificate else { throw StarPortReceiverError.certificateChanged }
                continue
            }
            if result == noErr { complete = true }
            else if result != errSSLWouldBlock { throw StarPortReceiverError.tls(result) }
            let data = outgoing; outgoing.removeAll(keepingCapacity: true)
            return data
        }
        throw StarPortReceiverError.protocolFailure("TLS handshake did not advance")
    }

    func encrypt(_ data: Data) throws -> Data {
        var processed = 0
        let result = data.withUnsafeBytes { SSLWrite(context, $0.baseAddress!, $0.count, &processed) }
        try check(result)
        guard processed == data.count else { throw StarPortReceiverError.protocolFailure("Incomplete TLS write") }
        let resultData = outgoing; outgoing.removeAll(keepingCapacity: true)
        return resultData
    }

    func decrypt(_ data: Data) throws -> Data {
        guard incoming.count + data.count <= 128 * 1024 else { throw StarPortWireError.sizeLimit }
        incoming.append(data)
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 32768)
        for _ in 0..<8 {
            var count = 0
            let result = SSLRead(context, &buffer, buffer.count, &count)
            if count > 0 { output.append(contentsOf: buffer.prefix(count)) }
            if result == errSSLWouldBlock { return output }
            try check(result)
            guard output.count <= 65535 else { throw StarPortWireError.sizeLimit }
        }
        throw StarPortWireError.sizeLimit
    }
}
