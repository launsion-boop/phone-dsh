// SPDX-License-Identifier: MIT
//
// Minimal LAN listener used to prove plan §2.8: while the app is resident the
// local port answers; once iOS suspends the process it does not, and the
// request has to fall back to the cloud-task push. Spike-only.
//
// This is not the production Bot MCP listener and does not add a production
// listener or any keep-alive.

#if BOT_RESIDENCY_SPIKE

import Foundation
import Network

@MainActor
final class EngineWakeLANListener {
    private var listener: NWListener?
    private(set) var port: UInt16?
    private(set) var requestCount = 0
    var onReady: ((UInt16) -> Void)?
    var onRequest: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    func start(preferredPort: UInt16 = 0) {
        stop()
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let endpointPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any
            let listener = try NWListener(using: parameters, on: endpointPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.port = listener.port?.rawValue
                        if let port = self?.port { self?.onReady?(port) }
                    case .failed(let error):
                        self?.onFailure?(String(describing: error))
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handle(connection)
                }
            }
            self.listener = listener
            listener.start(queue: .main)
        } catch {
            onFailure?(String(describing: error))
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            Task { @MainActor in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                self?.requestCount += 1
                self?.onRequest?(request)
                let body = "ok"
                let response = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
#endif
