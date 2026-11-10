// SPDX-License-Identifier: MIT

import Foundation
import Network

public enum BotMCPHTTPError: Error, Sendable, Equatable {
    case startFailed(String)
    case alreadyStarted
}

/// Outcome of one ``BotMCPHTTPServer/ensureListening()`` call.
///
/// ``listening`` means the existing endpoint answered a loopback probe;
/// ``rebound`` means the listener had to be recreated. A rebind keeps the
/// previous port whenever the OS lets it, so Worker/MCP URLs stay valid.
public enum BotMCPListenerRecovery: Equatable, Sendable {
    case listening(URL)
    case rebound(URL)
    case unavailable(String)

    public var url: URL? {
        switch self {
        case .listening(let url), .rebound(let url): return url
        case .unavailable: return nil
        }
    }

    public var didRebind: Bool {
        if case .rebound = self { return true }
        return false
    }
}

/// The App's own Bot MCP listener. It is created by the Bot composition and is
/// reached only through the host's `/v1/http` egress, never from the LAN.
///
/// iOS can reap this socket while the App is suspended even though the process
/// and the Worker stay alive. A listener that only observes `.ready`/`.failed`
/// before `start()` returns hands that dead URL to the next Worker boot, and the
/// gateway then waits for connectivity against a closed loopback port. This
/// class therefore keeps observing after `.ready` and exposes
/// ``ensureListening()`` so every Worker start/resume path heals the listener
/// before using its URL.
public final class BotMCPHTTPServer: @unchecked Sendable {
    public static let maximumBodyBytes = 1_048_576

    public let token: String
    public let handler: BotMCPHandler

    private let queue = DispatchQueue(label: "phone-dsh.bot.mcp.http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var attempt: ListenerAttempt?
    private var endpoint: URL?
    private var started = false
    private var healthy = false
    private var lastPort: UInt16?
    private var recoveryInFlight: Task<BotMCPListenerRecovery, Never>?
    private var endpointChangeHandler: (@Sendable (URL) -> Void)?

    public init(handler: BotMCPHandler, token: String? = nil) {
        self.handler = handler
        self.token = token ?? Self.randomToken()
    }

    public var url: URL? {
        lock.withLock { endpoint }
    }

    /// `false` after an unexpected `.failed`/`.cancelled` or a failed loopback
    /// probe. ``ensureListening()`` recreates the listener in that state.
    public var isHealthy: Bool {
        lock.withLock { healthy }
    }

    /// Called after a recovery rebound the endpoint to a different URL. The
    /// callback runs outside the state lock, on whichever task called
    /// ``ensureListening()``.
    public var onEndpointChange: (@Sendable (URL) -> Void)? {
        get { lock.withLock { endpointChangeHandler } }
        set { lock.withLock { endpointChangeHandler = newValue } }
    }

    public func start() async throws -> URL {
        let canStart = lock.withLock { () -> Bool in
            guard !started, listener == nil else { return false }
            started = true
            healthy = false
            return true
        }
        guard canStart else { throw BotMCPHTTPError.alreadyStarted }
        do {
            // The Bot MCP surface is only ever reached through the host's
            // /v1/http egress, never from the LAN. Bind the IPv4 loopback
            // explicitly instead of `.any`.
            return try await bind(preferredPort: nil)
        } catch {
            lock.withLock { started = false }
            throw error
        }
    }

    /// Probes the current endpoint and, when it no longer accepts loopback
    /// connections, recreates the listener. The old port is tried first so
    /// URLs already handed to the Worker and the MCP policy remain valid; only
    /// an occupied port falls back to `.any`, and that change is announced via
    /// ``onEndpointChange``.
    public func ensureListening() async -> BotMCPListenerRecovery {
        let task: Task<BotMCPListenerRecovery, Never> = lock.withLock {
            if let recoveryInFlight { return recoveryInFlight }
            let task = Task<BotMCPListenerRecovery, Never> { [weak self] in
                guard let self else { return .unavailable("server deallocated") }
                defer { self.lock.withLock { self.recoveryInFlight = nil } }
                return await self.performEnsureListening()
            }
            recoveryInFlight = task
            return task
        }
        return await task.value
    }

    private func performEnsureListening() async -> BotMCPListenerRecovery {
        let snapshot = lock.withLock {
            (started: started, healthy: healthy, endpoint: endpoint,
             listener: listener, port: lastPort)
        }
        guard snapshot.started else { return .unavailable("listener is not started") }

        if snapshot.healthy, let endpoint = snapshot.endpoint {
            if await probe(endpoint) {
                return .listening(endpoint)
            }
            markUnhealthy(listener: snapshot.listener,
                          reason: "loopback health check failed")
        }

        let previousURL = snapshot.endpoint
        cancelCurrentListener()
        if let preferred = snapshot.port {
            // Cancel is asynchronous: give the old socket one short retry
            // before treating the preferred port as genuinely taken.
            for attempt in 0..<2 {
                if let url = try? await bind(preferredPort: preferred) {
                    announceEndpointChange(from: previousURL, to: url)
                    return .rebound(url)
                }
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        do {
            let url = try await bind(preferredPort: nil)
            announceEndpointChange(from: previousURL, to: url)
            return .rebound(url)
        } catch {
            lock.withLock { healthy = false }
            return .unavailable(error.localizedDescription)
        }
    }

    public func stop() {
        let current: (NWListener?, ListenerAttempt?) = lock.withLock {
            let current = (listener, attempt)
            listener = nil
            attempt = nil
            endpoint = nil
            started = false
            healthy = false
            lastPort = nil
            recoveryInFlight?.cancel()
            recoveryInFlight = nil
            return current
        }
        current.1?.markExpectedCancellation()
        current.0?.cancel()
    }

    // MARK: - Listener lifecycle

    private func bind(preferredPort: UInt16?) async throws -> URL {
        let parameters = NWParameters.tcp
        // A rebound may land on a port still in TIME_WAIT after iOS closed the
        // old socket; reuse makes the preferred-port attempt more likely to
        // succeed without ever allowing two live listeners on one port.
        parameters.allowLocalEndpointReuse = true
        let port = preferredPort.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        let attempt = ListenerAttempt()
        let accepted = lock.withLock { () -> Bool in
            guard started else { return false }
            self.attempt = attempt
            return true
        }
        guard accepted else { throw BotMCPHTTPError.startFailed("listener is not started") }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        return try await withCheckedThrowingContinuation { continuation in
            attempt.install(continuation)
            listener.stateUpdateHandler = { [weak self, weak listener, weak attempt] state in
                guard let self, let listener, let attempt else { return }
                self.handle(state, listener: listener, attempt: attempt)
            }
            listener.start(queue: queue)
        }
    }

    private func handle(_ state: NWListener.State,
                        listener: NWListener,
                        attempt: ListenerAttempt) {
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue, port != 0 else {
                clearAttempt(attempt)
                attempt.finish(.failure(BotMCPHTTPError.startFailed("listener bound no port")))
                listener.cancel()
                return
            }
            let url = URL(string: "http://127.0.0.1:\(port)/mcp")!
            let installed = lock.withLock { () -> Bool in
                guard started, self.attempt === attempt else { return false }
                self.listener = listener
                self.attempt = attempt
                self.endpoint = url
                self.healthy = true
                self.lastPort = port
                return true
            }
            guard installed else {
                attempt.markExpectedCancellation()
                listener.cancel()
                attempt.finish(.failure(BotMCPHTTPError.startFailed("listener is not started")))
                return
            }
            attempt.markReady()
            attempt.finish(.success(url))
        case .failed(let error):
            if attempt.isReady {
                markUnhealthy(listener: listener,
                              reason: "failed: \(error.localizedDescription)")
            } else {
                clearAttempt(attempt)
                attempt.finish(.failure(BotMCPHTTPError.startFailed(error.localizedDescription)))
                listener.cancel()
            }
        case .cancelled:
            if attempt.isReady {
                if !attempt.isExpectedCancellation {
                    markUnhealthy(listener: listener, reason: "cancelled")
                }
            } else {
                clearAttempt(attempt)
                attempt.finish(.failure(BotMCPHTTPError.startFailed("listener cancelled")))
            }
        default:
            break
        }
    }

    /// Marks the endpoint unhealthy only when the event belongs to the current
    /// listener; a cancelled listener left over from a rebind must not poison
    /// the replacement.
    private func markUnhealthy(listener: NWListener?, reason: String) {
        let endpoint: URL? = lock.withLock {
            guard let listener, self.listener === listener, healthy else { return nil }
            healthy = false
            return self.endpoint
        }
        guard let endpoint else { return }
        print("[BotMCPHTTPServer] listener unavailable (\(reason)); "
            + "endpoint=\(endpoint.absoluteString)")
    }

    private func cancelCurrentListener() {
        let current: (NWListener?, ListenerAttempt?) = lock.withLock {
            let current = (listener, attempt)
            listener = nil
            attempt = nil
            healthy = false
            return current
        }
        current.1?.markExpectedCancellation()
        current.0?.cancel()
    }

    private func clearAttempt(_ attempt: ListenerAttempt) {
        lock.withLock {
            if self.attempt === attempt { self.attempt = nil }
        }
    }

    private func announceEndpointChange(from previous: URL?, to url: URL) {
        guard previous != url else { return }
        let callback = lock.withLock { endpointChangeHandler }
        callback?(url)
    }

    /// Opens and immediately closes one TCP connection. `NWConnection` is used
    /// instead of URLSession so this check states the listener's own liveness
    /// rather than the gateway's connectivity policy.
    private func probe(_ endpoint: URL, timeout: TimeInterval = 1.5) async -> Bool {
        guard let number = endpoint.port,
              let port = NWEndpoint.Port(rawValue: UInt16(clamping: number)) else {
            return false
        }
        let connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let box = ProbeBox()
        return await withCheckedContinuation { continuation in
            box.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if box.finish(true) { connection.cancel() }
                case .failed, .cancelled, .waiting:
                    if box.finish(false) { connection.cancel() }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if box.finish(false) { connection.cancel() }
            }
        }
    }

    /// Test-only: the live listener, so a regression can cancel it exactly as
    /// iOS would when it reaps the socket. Never used by production code.
    var listenerForTesting: NWListener? {
        lock.withLock { listener }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumBodyBytes + 65_536) {
            [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffer
            if let data { accumulated.append(data) }
            if accumulated.count > Self.maximumBodyBytes + 65_536 {
                self.send(.text(413, #"{"error":"request too large"}"#), on: connection)
                return
            }
            if let response = awaitResponse(accumulated) {
                Task { await self.respond(response, on: connection) }
                return
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: accumulated)
        }
    }

    private func awaitResponse(_ data: Data) -> BotHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = data.range(of: separator),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= Self.maximumBodyBytes else {
            return BotHTTPRequest(method: "ERROR", target: "", headers: [:], body: Data())
        }
        let body = Data(data[range.upperBound...])
        guard body.count >= length else { return nil }
        return BotHTTPRequest(
            method: String(parts[0]).uppercased(), target: String(parts[1]),
            headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ request: BotHTTPRequest, on connection: NWConnection) async {
        if request.method == "ERROR" {
            send(.text(413, #"{"error":"request too large"}"#), on: connection)
            return
        }
        // A request that carries an Origin must carry exactly this server's
        // origin (LoopbackServer's rule). Requests from the host egress carry
        // none, so they stay accepted.
        if let origin = request.headers["origin"],
           origin.caseInsensitiveCompare(originString) != .orderedSame {
            send(.text(403, #"{"error":"origin mismatch"}"#), on: connection)
            return
        }
        guard Self.tokenMatches(request.headers["authorization"], expected: "Bearer \(token)") else {
            send(.text(401, #"{"error":"unauthorized"}"#), on: connection)
            return
        }
        guard request.method == "POST" else {
            send(.text(405, #"{"error":"method not allowed"}"#), on: connection)
            return
        }
        // Paths are exact. A query string, a trailing slash, a different case
        // or a `..` segment is not a route; DELETE cannot succeed anywhere.
        guard !request.target.isEmpty,
              !request.target.contains("?"),
              !request.target.contains("#"),
              !request.target.contains(".."),
              request.target.hasPrefix("/") else {
            send(.text(400, #"{"error":"invalid request target"}"#), on: connection)
            return
        }
        guard let value = try? BotJSONValue.parse(request.body) else {
            send(.text(400, #"{"error":"invalid JSON"}"#), on: connection)
            return
        }
        switch request.target {
        case "/identity/register":
            let reply = await handler.registerIdentity(value)
            send(.json(200, reply), on: connection)
        case "/identity/cancel":
            let reply = await handler.cancelIdentity(value)
            send(.json(200, reply), on: connection)
        case "/approval":
            let reply = await handler.approval(value)
            send(.json(200, reply), on: connection)
        case "/mcp":
            let messages = value.arrayValue ?? [value]
            var replies: [BotJSONValue] = []
            for message in messages {
                guard case .object(let object) = message,
                      case .string(let method)? = object["method"] else {
                    send(.text(400, #"{"error":"invalid JSON-RPC message"}"#), on: connection)
                    return
                }
                guard let id = object["id"] else { continue }
                let params = object["params"] ?? .object([:])
                replies.append(await handler.rpc(method: method, params: params, id: id,
                                                 headers: request.headers))
            }
            if replies.isEmpty {
                send(.text(202, "", session: true), on: connection)
            } else {
                let reply: BotJSONValue = value.arrayValue == nil ? replies[0] : .array(replies)
                send(.json(200, reply, session: true), on: connection)
            }
        default:
            send(.text(404, #"{"error":"not found"}"#), on: connection)
        }
    }

    private func send(_ response: BotHTTPResponse, on connection: NWConnection) {
        let body = response.body
        var head = "HTTP/1.1 \(response.status) \(response.status == 200 ? "OK" : "Status")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if response.session {
            head += "Mcp-Session-Id: \(handler.mcpSessionId)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private var originString: String {
        let current = lock.withLock { endpoint }
        guard let current,
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return "" }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.string ?? ""
    }

    /// Constant-time comparison over UTF-8 bytes. Length is allowed to differ
    /// (it is not secret), but equal-length byte comparison does not exit on
    /// the first mismatch.
    static func tokenMatches(_ supplied: String?, expected: String) -> Bool {
        guard let supplied else { return false }
        let left = Array(supplied.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}

private final class ListenerAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var finished = false
    private var ready = false
    private var expectedCancellation = false

    func install(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func markReady() {
        lock.lock()
        ready = true
        lock.unlock()
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ready
    }

    func markExpectedCancellation() {
        lock.lock()
        expectedCancellation = true
        lock.unlock()
    }

    var isExpectedCancellation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return expectedCancellation
    }
}

private final class ProbeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    /// Returns `true` only to the caller that actually resumes the continuation.
    func finish(_ result: Bool) -> Bool {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return false
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
        return true
    }
}

private struct BotHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

private struct BotHTTPResponse {
    let status: Int
    let body: Data
    let session: Bool

    static func text(_ status: Int, _ text: String, session: Bool = false) -> Self {
        Self(status: status, body: Data(text.utf8), session: session)
    }

    static func json(_ status: Int, _ value: BotJSONValue, session: Bool = false) -> Self {
        let data = (try? value.encoded()) ?? Data(#"{"error":"encoding failed"}"#.utf8)
        return Self(status: status, body: data, session: session)
    }

    private init(status: Int, body: Data, session: Bool) {
        self.status = status
        self.body = body
        self.session = session
    }
}
