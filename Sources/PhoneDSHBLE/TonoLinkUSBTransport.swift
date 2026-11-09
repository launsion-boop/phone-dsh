// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE: Network.framework :8768 session and URLSession HTTP
// for the TonoLink USB OTA (`TonoLinkUSBOTA`).
import Foundation
import Network

@MainActor public final class TonoLinkUSBSocketNetwork: TonoLinkUSBNetwork {
    private let host: String
    private let port: UInt16
    private let attemptTimeout: Duration

    public init(host: String = TonoLinkUSB.host, port: UInt16 = TonoLinkUSB.socketPort, attemptTimeout: Duration = .seconds(3)) {
        self.host = host; self.port = port; self.attemptTimeout = attemptTimeout
    }

    public func openSession(token: String) async throws -> TonoLinkUSBSession {
        let session = TonoLinkUSBSocketSession(host: host, port: port)
        try await session.start(token: token, timeout: attemptTimeout)
        return session
    }
}

/// Authenticates once, then pings every second so the board's 5 s receive
/// timeout never closes the socket (which would invalidate the token).
@MainActor final class TonoLinkUSBSocketSession: TonoLinkUSBSession {
    private let connection: NWConnection
    private var decoder = TonoLinkUSBFrame.Decoder()
    private var started: CheckedContinuation<Void, Error>?
    private var keepAlive: Task<Void, Never>?
    private var lastPong = ContinuousClock.now
    private(set) var isAlive = false

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // The board is only reachable over the USB NCM link.
        parameters.prohibitedInterfaceTypes = [.cellular, .wifi]
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    func start(token: String, timeout: Duration) async throws {
        let auth = try TonoLinkUSBFrame.authenticate(token: token)
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.handle(state, auth: auth) }
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(TonoLinkUSBOTAError("USB socket timed out"))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            started = continuation
            connection.start(queue: .main)
        }
    }

    func close() {
        isAlive = false
        keepAlive?.cancel(); keepAlive = nil
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State, auth: Data) {
        switch state {
        case .ready:
            connection.send(content: auth, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.fail(error) }
            })
            receive()
        case .waiting(let error), .failed(let error):
            fail(error)
        case .cancelled:
            fail(TonoLinkUSBOTAError("USB socket closed"))
        default:
            break
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if let error { self.fail(error) }
                else if complete { self.fail(TonoLinkUSBOTAError("board closed the USB socket")) }
                else if self.started != nil || self.isAlive { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) {
        do {
            for frame in try decoder.append(data) {
                if !isAlive {
                    guard TonoLinkUSBFrame.isAuthAck(kind: frame.kind, payload: frame.payload) else {
                        throw TonoLinkUSBOTAError("board rejected the USB token")
                    }
                    isAlive = true
                    lastPong = .now
                    startKeepAlive()
                    started?.resume(); started = nil
                } else if frame.kind == TonoLinkUSBFrame.pong {
                    lastPong = .now
                }
            }
        } catch { fail(error) }
    }

    private func startKeepAlive() {
        keepAlive = Task { [weak self] in
            var counter: UInt32 = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: TonoLinkUSB.keepAliveInterval)
                guard let self, self.isAlive, !Task.isCancelled else { return }
                if ContinuousClock.now - self.lastPong > .seconds(4) {
                    self.fail(TonoLinkUSBOTAError("board stopped answering USB pings")); return
                }
                counter &+= 1
                let ping = try? TonoLinkUSBFrame.encode(kind: TonoLinkUSBFrame.ping, payload: withUnsafeBytes(of: counter.bigEndian) { Data($0) })
                self.connection.send(content: ping, completion: .contentProcessed { error in
                    guard let error else { return }
                    Task { @MainActor in self.fail(error) }
                })
            }
        }
    }

    private func fail(_ error: Error) {
        let wasStarting = started
        started = nil
        close()
        wasStarting?.resume(throwing: error)
    }
}

@MainActor public final class TonoLinkURLSessionHTTP: TonoLinkHTTP {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForResource = 240   // firmware upload deadline is 180 s
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest, body: Data?, progress: ((Double) -> Void)?) async throws -> (status: Int, body: Data) {
        let (data, response): (Data, URLResponse)
        if let body, request.httpMethod == "POST", !body.isEmpty {
            let delegate = UploadProgress { value in Task { @MainActor in progress?(value) } }
            (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw TonoLinkUSBOTAError("not an HTTP response") }
        return (http.statusCode, data)
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
