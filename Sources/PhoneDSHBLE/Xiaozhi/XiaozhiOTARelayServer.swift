// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE/Xiaozhi: the OTA relay's TCP listener
// (spec/device/v1/xiaozhi-firmware.md §2.1). DEBUG builds only; the user
// switches it on and off, and it never listens on cellular.
#if DEBUG
import Foundation
import Network

@MainActor public final class XiaozhiOTARelayServer {
    public let relay: XiaozhiOTARelay
    public let port: UInt16
    private var listener: NWListener?
    private var running = false
    public private(set) var restarts = 0
    public private(set) var state = "stopped"
    public var onStateChange: ((String) -> Void)?

    public var records: XiaozhiDeviceRecords { relay.records }
    public var images: XiaozhiStagedImages { relay.images }
    public var isRunning: Bool { running }

    public init(relay: XiaozhiOTARelay, port: UInt16 = XiaozhiOTARelay.port) {
        self.relay = relay; self.port = port
    }

    public func start() throws {
        guard listener == nil else { return }
        running = true
        try listen()
    }

    public func stop() {
        running = false
        listener?.cancel(); listener = nil
        state = "stopped"; onStateChange?(state)
    }

    /// Recreates the listener 1 s after it fails or stalls while running.
    private func listen() throws {
        let parameters = NWParameters.tcp
        parameters.prohibitedInterfaceTypes = [.cellular]
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw URLError(.badURL) }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready: self.state = "listening on :\(self.port)" + (self.restarts > 0 ? " (restarted \(self.restarts)x)" : "")
                case .failed(let error), .waiting(let error):
                    self.state = "relistening after \(error)"
                    self.listener?.cancel(); self.listener = nil
                    self.restarts += 1
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.running, self.listener == nil else { return }
                        do { try self.listen() } catch { self.state = "failed: \(error)"; self.onStateChange?(self.state) }
                    }
                default: return
                }
                self.onStateChange?(self.state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.serve(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        read(connection, peer: Self.peerHost(connection.endpoint), buffer: Data())
    }

    private static func peerHost(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        switch host {
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        case .name(let name, _): return name
        @unknown default: return ""
        }
    }

    private func read(_ connection: NWConnection, peer: String, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch XiaozhiHTTP.parseHead(buffer) {
                case .reject(let status):
                    self.reply(connection, XiaozhiHTTPResponse(status: status))
                case .incomplete:
                    if error != nil || complete { connection.cancel() } else { self.read(connection, peer: peer, buffer: buffer) }
                case .complete(var request, let length, let start):
                    if buffer.count - start >= length {
                        request.body = Data(buffer[(buffer.startIndex + start)..<(buffer.startIndex + start + length)])
                        let response = await self.relay.handle(peerHost: peer, request)
                        self.reply(connection, response)
                    } else if error != nil || complete {
                        connection.cancel()
                    } else {
                        self.read(connection, peer: peer, buffer: buffer)
                    }
                }
            }
        }
    }

    private func reply(_ connection: NWConnection, _ response: XiaozhiHTTPResponse) {
        connection.send(content: XiaozhiHTTP.encode(response), completion: .contentProcessed { _ in connection.cancel() })
    }
}
#endif
