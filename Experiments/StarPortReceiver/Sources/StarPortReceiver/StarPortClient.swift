import Foundation
import Network

public final class StarPortClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "StarPilot.local-video", qos: .userInteractive)
    private var connection: NWConnection?
    private var session: StarPortSession?
    private var stopped = false
    private var finishing = false
    private var lastBytes = ProcessInfo.processInfo.systemUptime
    private var timer: DispatchSourceTimer?
    private let ended: (Error) -> Void

    public init(host: String, port: UInt16 = 5277, certificate: Data?, fragmentACKs: Bool = true,
                allowLoopbackForTest: Bool = false,
                log: @escaping (String) -> Void,
                video: @escaping (Data, UInt64, UInt64, @escaping () -> Void) -> Void,
                ended: @escaping (Error) -> Void) {
        self.ended = ended
        queue.async { [self] in
            // Numeric private addresses only. Never resolve a hostname onto
            // cellular or follow an address supplied by the video protocol.
            guard Self.privateIPv4(host) || (allowLoopbackForTest && host == "127.0.0.1"),
                  let port = NWEndpoint.Port(rawValue: port) else {
                finish(StarPortReceiverError.protocolFailure("Local IPv4 address required")); return
            }
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            parameters.prohibitedInterfaceTypes = [.cellular]
            parameters.includePeerToPeer = false
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            self.connection = connection
            session = StarPortSession(certificate: certificate, fragmentACKs: fragmentACKs, write: { [weak self] bytes in
                guard let self, !self.stopped else { throw StarPortReceiverError.closed }
                self.connection?.send(content: bytes, completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(error) }
                })
            }, log: log, video: { [weak self] data, frame, timestamp, consumed in
                video(data, frame, timestamp) { self?.queue.async { consumed() } }
            })
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    log("TCP ready; local-only native tablet receiver; cellular prohibited")
                    do { try self.session?.start(); self.read() } catch { self.finish(error) }
                case .failed(let error): self.finish(error)
                default: break
                }
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped, ProcessInfo.processInfo.systemUptime - self.lastBytes > 15 else { return }
                self.finish(StarPortReceiverError.protocolFailure("Local video timed out. Enable StarPort tablet mode in Galaxy while parked."))
            }
            self.timer = timer; timer.resume()
            connection.start(queue: queue)
        }
    }

    private func read() {
        guard !stopped else { return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] bytes, _, complete, error in
            guard let self, !self.stopped else { return }
            do {
                if let bytes, !bytes.isEmpty { self.lastBytes = ProcessInfo.processInfo.systemUptime; try self.session?.feed(bytes) }
                if let error { self.finish(error) }
                else if complete { self.finish(StarPortReceiverError.closed) }
                else { self.read() }
            } catch { self.finish(error) }
        }
    }

    public func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        stopped = true; timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil; session = nil
    }
    private func finish(_ error: Error) {
        guard !stopped, !finishing else { return }
        finishing = true
        if case StarPortReceiverError.closed = error, let connection {
            // The protocol's shutdown response is already queued. Drain it
            // before cancelling TCP, otherwise Dom sees an incomplete shutdown.
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                completion: .contentProcessed { [weak self] _ in
                    guard let self, !self.stopped else { return }
                    self.stopOnQueue(); self.ended(error)
                })
        } else { stopOnQueue(); ended(error) }
    }
    static func privateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let values = parts.compactMap { UInt8($0) }; guard values.count == 4 else { return false }
        return values[0] == 10 || (values[0] == 172 && (16...31).contains(values[1])) || (values[0] == 192 && values[1] == 168)
    }
}
