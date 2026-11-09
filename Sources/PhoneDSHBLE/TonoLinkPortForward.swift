// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: raw TCP port forwards from the iPhone's network
// interfaces to the TonoLink board on USB NCM, so a computer on the same
// Wi-Fi uses the board's tools unchanged with host = the iPhone's IP
// (`:8767` HTTP, `:8769` the long-lived AirPlay viewer stream).
//
// Each accepted connection gets its own upstream connection; bytes are piped
// both ways with backpressure (the next read starts only after the previous
// chunk was handed to the other side). Half-closes are propagated; an error on
// either side closes both. Known limit: when a client half-closes while the
// target is still sending, Network.framework can fail the upstream connection
// (seen as ENETDOWN on loopback) and drop the rest of the reply. The board's
// clients (HTTP tools, the AirPlay viewer) do not half-close. No authentication (owner decision, 2026-11-02): the
// forwards only exist while the relay is switched on.
import Foundation
import Network

public final class TonoLinkPortForward: @unchecked Sendable {
    public let listenPort: UInt16
    public let targetHost: String
    public let targetPort: UInt16
    private let queue: DispatchQueue
    private let upstreamProhibited: [NWInterface.InterfaceType]
    private var listener: NWListener?
    private var pipes: [ObjectIdentifier: Pipe] = [:]
    private var bytesUp = 0, bytesDown = 0, accepted = 0
    private var running = false, everReady = false, restarts = 0
    /// Called on the forward's queue: "listening", "failed: …", "stopped".
    public var onState: (@Sendable (String) -> Void)?

    public struct Stats: Equatable, Sendable {
        public let active: Int, accepted: Int, bytesUp: Int, bytesDown: Int, restarts: Int
    }

    /// `upstreamProhibited` keeps upstream traffic off Wi-Fi/cellular: the board
    /// is only reachable over the USB link.
    public init(listenPort: UInt16, targetHost: String = TonoLinkUSB.host, targetPort: UInt16,
                upstreamProhibited: [NWInterface.InterfaceType] = [.wifi, .cellular]) {
        self.listenPort = listenPort; self.targetHost = targetHost; self.targetPort = targetPort
        self.upstreamProhibited = upstreamProhibited
        queue = DispatchQueue(label: "tonolink.forward.\(listenPort)")
        queue.setSpecific(key: Self.queueKey, value: listenPort)
    }

    private static let queueKey = DispatchSpecificKey<UInt16>()

    public func start() throws {
        queue.sync { running = true }
        try listen()
    }

    /// A listener that was serving and then fails or stalls (e.g. a network
    /// path change while screen mirroring restarts) is recreated after 1 s.
    /// One that never got ready (port taken) reports `failed` and stops, so the
    /// owner can pick another port.
    private func listen() throws {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: listenPort)!)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.everReady = true
                self.onState?(self.restarts == 0 ? "listening" : "listening (restarted \(self.restarts)x)")
            case .failed(let error), .waiting(let error):
                guard self.everReady else { self.onState?("failed: \(error)"); self.stop(); return }
                guard self.running, self.listener === listener else { return }
                self.onState?("relistening after \(error)")
                self.listener?.cancel(); self.listener = nil
                self.restarts += 1
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.running, self.listener == nil else { return }
                    do { try self.listen() } catch { self.onState?("failed: \(error)") }
                }
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        if DispatchQueue.getSpecific(key: Self.queueKey) == listenPort { self.listener = listener }
        else { queue.sync { self.listener = listener } }
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            self.running = false
            self.listener?.cancel(); self.listener = nil
            for pipe in self.pipes.values { pipe.close() }
            self.pipes = [:]
            self.onState?("stopped")
        }
    }

    public func stats() -> Stats {
        queue.sync { Stats(active: pipes.count, accepted: accepted, bytesUp: bytesUp, bytesDown: bytesDown, restarts: restarts) }
    }

    private func accept(_ client: NWConnection) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.prohibitedInterfaceTypes = upstreamProhibited
        let upstream = NWConnection(host: NWEndpoint.Host(targetHost), port: NWEndpoint.Port(rawValue: targetPort)!, using: parameters)
        let pipe = Pipe(client: client, upstream: upstream, queue: queue) { [weak self] pipe, up, down in
            guard let self else { return }
            self.bytesUp += up; self.bytesDown += down
            if let pipe { self.pipes[ObjectIdentifier(pipe)] = nil }
        }
        pipes[ObjectIdentifier(pipe)] = pipe
        accepted += 1
        pipe.start()
    }

    /// One client ↔ upstream pair. Runs entirely on the forward's queue.
    final class Pipe {
        let client: NWConnection, upstream: NWConnection
        private let queue: DispatchQueue
        private let account: (Pipe?, Int, Int) -> Void
        private var openHalves = 2
        private var closed = false

        init(client: NWConnection, upstream: NWConnection, queue: DispatchQueue, account: @escaping (Pipe?, Int, Int) -> Void) {
            self.client = client; self.upstream = upstream; self.queue = queue; self.account = account
        }

        func start() {
            upstream.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.pump(from: self.client, to: self.upstream, up: true)
                    self.pump(from: self.upstream, to: self.client, up: false)
                case .failed, .waiting, .cancelled: self.close()
                default: break
                }
            }
            client.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            client.start(queue: queue)
            upstream.start(queue: queue)
        }

        private func pump(from source: NWConnection, to sink: NWConnection, up: Bool) {
            source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    self.account(nil, up ? data.count : 0, up ? 0 : data.count)
                    sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                        guard let self else { return }
                        if sendError != nil { self.close(); return }
                        if complete { self.finish(sink) } else if error == nil { self.pump(from: source, to: sink, up: up) }
                    })
                    if error != nil { self.close() }
                    return
                }
                if error != nil { self.close() } else if complete { self.finish(sink) } else { self.pump(from: source, to: sink, up: up) }
            }
        }

        /// The source half-closed: half-close the sink, close both when both directions ended.
        private func finish(_ sink: NWConnection) {
            sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            openHalves -= 1
            // Both directions sent their FIN. `cancel()` would drop bytes the
            // stack has not transmitted yet, so give it time to drain first.
            if openHalves == 0 { queue.asyncAfter(deadline: .now() + 5) { [weak self] in self?.close() } }
        }

        func close() {
            guard !closed else { return }
            closed = true
            client.cancel(); upstream.cancel()
            account(self, 0, 0)
        }
    }
}
