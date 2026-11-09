// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: relay WebSocket client (§3): challenge signature auth,
// heartbeat, frame limits, error mapping and reconnect backoff constants.

import Foundation

// MARK: - Injectable WebSocket seam

public enum PCLinkWebSocketMessage: Sendable {
    case text(String)
    case binary(Data)
}

public protocol PCLinkWebSocket: Sendable {
    func send(text: String) async throws
    /// One message, or nil once the peer closed cleanly.
    func receive() async throws -> PCLinkWebSocketMessage?
    func close(code: UInt16, reason: String) async
}

public protocol PCLinkWebSocketFactory: Sendable {
    func connect(to url: URL) async throws -> any PCLinkWebSocket
}

/// Production WebSocket. `URLSessionWebSocketTask` is thread-safe; the
/// reference never changes after creation.
public final class PCLinkURLSessionWebSocket: PCLinkWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func send(text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw PCLinkError.unavailable("relay WebSocket send failed: \(error)")
        }
    }

    public func receive() async throws -> PCLinkWebSocketMessage? {
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            if task.closeCode == .normalClosure || task.closeCode == .goingAway {
                return nil
            }
            throw PCLinkError.unavailable("relay WebSocket receive failed: \(error)")
        }
        switch message {
        case .string(let text): return .text(text)
        case .data(let data): return .binary(data)
        @unknown default: return nil
        }
    }

    public func close(code: UInt16, reason: String) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.data(using: .utf8))
    }
}

public struct PCLinkURLSessionWebSocketFactory: PCLinkWebSocketFactory {
    public var session: URLSession
    public var maximumMessageSize: Int

    public init(session: URLSession = URLSession(configuration: .ephemeral),
                maximumMessageSize: Int = 16 << 20) {
        self.session = session
        self.maximumMessageSize = maximumMessageSize
    }

    public func connect(to url: URL) async throws -> any PCLinkWebSocket {
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = maximumMessageSize
        task.resume()
        return PCLinkURLSessionWebSocket(task: task)
    }
}

// MARK: - Reconnect policy

/// §10: 0.5 s, 1 s, 2 s, 4 s, 8 s, 16 s, 30 s, then 30 s, each with ±20 %
/// jitter; reset after 60 s of successful connection. A `replaced` client
/// waits at least 30 s with jitter (§3.2).
public struct PCLinkReconnectPolicy: Equatable, Sendable {
    public var delays: [TimeInterval]
    public var jitterFraction: Double
    public var resetAfter: TimeInterval
    public var replacedMinimumDelay: TimeInterval

    public init(delays: [TimeInterval] = [0.5, 1, 2, 4, 8, 16, 30, 30],
                jitterFraction: Double = 0.2,
                resetAfter: TimeInterval = 60,
                replacedMinimumDelay: TimeInterval = 30) {
        self.delays = delays
        self.jitterFraction = jitterFraction
        self.resetAfter = resetAfter
        self.replacedMinimumDelay = replacedMinimumDelay
    }

    public static let v1 = PCLinkReconnectPolicy()

    /// `attempt` is 1-based; values past the list repeat the last delay.
    public func baseDelay(attempt: Int) -> TimeInterval {
        guard !delays.isEmpty else { return 30 }
        let index = min(max(attempt, 1) - 1, delays.count - 1)
        return delays[index]
    }

    public func delay(attempt: Int, jitter: Double) -> TimeInterval {
        let base = baseDelay(attempt: attempt)
        let clamped = min(max(jitter, 0), 1)
        let factor = 1 + jitterFraction * (clamped * 2 - 1)
        return base * factor
    }

    public func delay(attempt: Int) -> TimeInterval {
        delay(attempt: attempt, jitter: Double.random(in: 0...1))
    }

    public func replacedDelay(attempt: Int) -> TimeInterval {
        max(replacedMinimumDelay, delay(attempt: attempt))
    }
}

// MARK: - Relay events

public struct PCLinkRelayOffline: Equatable, Sendable {
    public var to: String
    public var id: String?
    public var streamId: String?
    public var sid: String?
}

/// Relay-error correlation fields (§3.7: the relay echoes `id`/`streamId`/`sid`
/// only when the dropped source frame carried them). The client must not turn
/// a correlated drop into an ambiguous session loss.
public struct PCLinkRelayErrorContext: Equatable, Sendable {
    public var id: String?
    public var streamId: String?
    public var sid: String?
    public var retryAfterMs: Int?

    public init(id: String? = nil, streamId: String? = nil, sid: String? = nil,
                retryAfterMs: Int? = nil) {
        self.id = id
        self.streamId = streamId
        self.sid = sid
        self.retryAfterMs = retryAfterMs
    }
}

public enum PCLinkRelayEvent: Sendable {
    case ready(machineId: String, role: String)
    case frame(PCLinkJSON)
    case offline(PCLinkRelayOffline)
    case error(PCLinkError, context: PCLinkRelayErrorContext?)
    case closed(code: UInt16?, reason: String?, error: PCLinkError?)
}

// MARK: - Relay client

public actor PCLinkRelayClient {
    public struct Configuration: Sendable {
        public var origin: String
        public var identity: PCLinkIdentity
        public var role: String
        public var challengeTimeout: TimeInterval
        public var readyTimeout: TimeInterval
        public var frameLimit: Int
        public var heartbeatIntervalRange: ClosedRange<TimeInterval>
        public var heartbeatEnabled: Bool

        public init(origin: String, identity: PCLinkIdentity, role: String = "phone",
                    challengeTimeout: TimeInterval = 10,
                    readyTimeout: TimeInterval = 10,
                    frameLimit: Int = 16 << 20,
                    heartbeatIntervalRange: ClosedRange<TimeInterval> = 20...30,
                    heartbeatEnabled: Bool = true) {
            self.origin = origin
            self.identity = identity
            self.role = role
            self.challengeTimeout = challengeTimeout
            self.readyTimeout = readyTimeout
            self.frameLimit = frameLimit
            self.heartbeatIntervalRange = heartbeatIntervalRange
            self.heartbeatEnabled = heartbeatEnabled
        }
    }

    public enum State: Equatable, Sendable {
        case idle
        case connecting
        case ready
        case closed
    }

    public nonisolated let events: AsyncStream<PCLinkRelayEvent>
    private let eventContinuation: AsyncStream<PCLinkRelayEvent>.Continuation
    private let configuration: Configuration
    private let factory: any PCLinkWebSocketFactory

    private var socket: (any PCLinkWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var state: State = .idle
    private var challenged = false
    private var challengeNonce: Data?
    private var readyReceived = false
    private var challengeContinuation: CheckedContinuation<Data, Error>?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var challengeTimeoutTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var outstandingPing: Data?
    private var finished = false

    // One socket, one writer. `sendObject` only enqueues; the writer drains the
    // FIFO, so no two `socket.send` calls can overlap and reorder (§3.1/§5.4).
    private struct QueuedSend {
        let text: String
        let continuation: CheckedContinuation<Void, Error>
    }
    private var sendQueue: [QueuedSend] = []
    private var sendSignal: AsyncStream<Void>.Continuation?
    private var sendWriter: Task<Void, Never>? = nil

    public init(configuration: Configuration, factory: any PCLinkWebSocketFactory) {
        self.configuration = configuration
        self.factory = factory
        var continuation: AsyncStream<PCLinkRelayEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventContinuation = continuation
    }

    public var currentState: State { state }

    /// Dials, validates `relay.challenge`, signs the exact challenge origin and
    /// waits for `relay.ready`.
    public func connect() async throws {
        guard state == .idle else { throw PCLinkError.badFrame("relay client already started") }
        try PCLinkValidation.origin(configuration.origin)
        let url = try PCLinkValidation.websocketURL(for: configuration.origin)
        state = .connecting
        do {
            socket = try await factory.connect(to: url)
        } catch let error as PCLinkError {
            state = .closed
            await finish(code: nil, reason: nil, error: error)
            throw error
        } catch {
            state = .closed
            let mapped = PCLinkError.unavailable("relay connect failed: \(error)")
            await finish(code: nil, reason: nil, error: mapped)
            throw mapped
        }
        receiveTask = Task { await self.receiveLoop() }
        startSendWriter()
        do {
            let nonce = try await awaitChallenge()
            let transcript = PCLinkCrypto.relayAuthTranscript(origin: configuration.origin, nonce: nonce)
            let signature = try configuration.identity.sign(transcript)
            let auth: PCLinkJSON = .object([
                "v": .int(1),
                "type": .string("peer.auth"),
                "machineId": .string(configuration.identity.machineId),
                "publicKey": .string(PCLinkBase64URL.encode(configuration.identity.publicKey)),
                "role": .string(configuration.role),
                "sig": .string(PCLinkBase64URL.encode(signature)),
            ])
            try await sendObject(auth, allowBeforeReady: true)
            try await awaitReady()
            state = .ready
            eventContinuation.yield(.ready(machineId: configuration.identity.machineId,
                                          role: configuration.role))
            startHeartbeat()
        } catch {
            let mapped = (error as? PCLinkError) ?? PCLinkError.unavailable("relay authentication failed: \(error)")
            await shutdown(code: closeCode(for: mapped), reason: mapped.code, error: mapped)
            throw mapped
        }
    }

    public func send(_ frame: PCLinkJSON) async throws {
        guard state == .ready else { throw PCLinkError.peerOffline }
        try await sendObject(frame, allowBeforeReady: false)
    }

    public func close(code: UInt16 = 1000, reason: String = "") async {
        await shutdown(code: code, reason: reason, error: nil)
    }

    // MARK: Receive loop

    private func receiveLoop() async {
        while !Task.isCancelled, !finished {
            let message: PCLinkWebSocketMessage?
            do {
                message = try await socket?.receive()
            } catch let error as PCLinkError {
                await connectionEnded(code: nil, reason: nil, error: error)
                return
            } catch {
                await connectionEnded(code: nil, reason: nil,
                                      error: PCLinkError.unavailable("relay receive failed: \(error)"))
                return
            }
            guard let message else {
                await connectionEnded(code: nil, reason: nil, error: nil)
                return
            }
            switch message {
            case .binary:
                await protocolViolation(.badFrame("binary relay frame"), code: 1003)
                return
            case .text(let text):
                let bytes = text.utf8.count
                guard bytes <= configuration.frameLimit else {
                    await protocolViolation(.frameTooLarge("relay frame exceeds 16 MiB"), code: 1009)
                    return
                }
                guard let frame = try? PCLinkJSONParser.parseObject(Data(text.utf8)) else {
                    await protocolViolation(.badFrame("relay frame is not one JSON object"), code: 1008)
                    return
                }
                do {
                    if try await handleFrame(frame, wireSize: bytes) { return }
                } catch let error as PCLinkError {
                    await protocolViolation(error, code: closeCode(for: error))
                    return
                } catch {
                    await protocolViolation(.badFrame("relay frame handling failed"), code: 1008)
                    return
                }
            }
        }
    }

    /// Returns true when the loop must stop.
    private func handleFrame(_ frame: PCLinkJSON, wireSize: Int) async throws -> Bool {
        guard let type = frame["type"]?.stringValue else {
            throw PCLinkError.badFrame("relay frame has no type")
        }
        switch type {
        case "relay.challenge":
            guard !challenged, state == .connecting else {
                throw PCLinkError.badFrame("unexpected relay.challenge")
            }
            let object = try frame.closedObject(required: ["v", "type", "nonce", "relay"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.challenge v") }
            let nonceText = try frame.requiredString("nonce")
            let nonce = try PCLinkBase64URL.decode(nonceText, expectedBytes: 32)
            let relay = try frame.requiredString("relay")
            try PCLinkValidation.origin(relay)
            guard relay == configuration.origin else {
                throw PCLinkError.authFailed("relay origin does not match the dialed origin")
            }
            challenged = true
            challengeTimeoutTask?.cancel()
            if let continuation = challengeContinuation {
                challengeContinuation = nil
                continuation.resume(returning: nonce)
            } else {
                // The challenge can arrive before `awaitChallenge` installs its
                // waiter (same race as relay.ready below). Cache it.
                challengeNonce = nonce
            }
            return false

        case "relay.ready":
            let object = try frame.closedObject(required: ["v", "type", "machineId", "role"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.ready v") }
            let machineId = try frame.requiredString("machineId")
            let role = try frame.requiredString("role")
            try PCLinkValidation.requireMachineId(machineId)
            guard machineId == configuration.identity.machineId,
                  role == configuration.role else {
                throw PCLinkError.authFailed("relay.ready machineId/role mismatch")
            }
            readyTimeoutTask?.cancel()
            if let continuation = readyContinuation {
                readyContinuation = nil
                continuation.resume()
            } else {
                // `relay.ready` may arrive while `connect` is still signing and
                // sending `peer.auth`; cache it so `awaitReady` cannot miss it.
                readyReceived = true
            }
            return false

        case "relay.ping":
            let object = try frame.closedObject(required: ["v", "type", "nonce"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.ping v") }
            let nonce = try frame.requiredString("nonce")
            _ = try PCLinkBase64URL.decode(nonce, expectedBytes: 16)
            try await sendObject(.object(["v": .int(1), "type": .string("relay.pong"),
                                          "nonce": .string(nonce)]), allowBeforeReady: true)
            return false

        case "relay.pong":
            let object = try frame.closedObject(required: ["v", "type", "nonce"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.pong v") }
            let nonce = try PCLinkBase64URL.decode(try frame.requiredString("nonce"), expectedBytes: 16)
            if outstandingPing == nonce { outstandingPing = nil }
            return false

        case "relay.error":
            let object = try frame.closedObject(required: ["v", "type", "code"],
                                                optional: ["message", "id", "streamId", "sid", "retryAfterMs"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.error v") }
            let code = try frame.requiredString("code")
            let relayErrorCodes: Set<String> = ["unavailable", "unpaired", "auth_failed", "replaced",
                                                "session_expired", "replay", "bad_frame",
                                                "frame_too_large", "rate_limited",
                                                "version_unsupported", "rendezvous_expired",
                                                "rendezvous_exhausted"]
            guard relayErrorCodes.contains(code) else {
                throw PCLinkError.badFrame("unknown PCLink code \(code)")
            }
            let message = object["message"]?.stringValue ?? ""
            try PCLinkValidation.displayText(message, field: "relay.error message",
                                             maximumBytes: 2048)
            if let id = object["id"] {
                guard let text = id.stringValue, PCLinkValidation.correlationId(text) else {
                    throw PCLinkError.badFrame("relay.error id")
                }
            }
            if let streamId = object["streamId"] {
                guard let text = streamId.stringValue, PCLinkValidation.correlationId(text) else {
                    throw PCLinkError.badFrame("relay.error streamId")
                }
            }
            if let sid = object["sid"] {
                guard let text = sid.stringValue, PCLinkValidation.sessionId(text) else {
                    throw PCLinkError.badFrame("relay.error sid")
                }
            }
            var mapped: PCLinkError
            var retryAfterMs: Int?
            if code == "rate_limited" {
                let value = object["retryAfterMs"]?.intValue
                if let value, value < 0 || value > 86_400_000 {
                    throw PCLinkError.badFrame("relay.error retryAfterMs out of range")
                }
                retryAfterMs = value.map(Int.init)
                mapped = .rateLimited(retryAfterMs: retryAfterMs)
            } else {
                mapped = PCLinkError.code(code, message: message)
            }
            let context = PCLinkRelayErrorContext(
                id: object["id"]?.stringValue,
                streamId: object["streamId"]?.stringValue,
                sid: object["sid"]?.stringValue,
                retryAfterMs: retryAfterMs)
            // A PCLink error frame is delivered before the relay's close. The
            // upper layer decides whether to reconnect; the client only
            // finishes the stream once the socket actually closes.
            eventContinuation.yield(.error(mapped, context: context))
            if ["auth_failed", "replaced", "bad_frame", "frame_too_large"].contains(code) {
                await connectionEnded(code: closeCode(for: mapped), reason: code, error: mapped)
                return true
            }
            return false

        case "relay.offline":
            let object = try frame.closedObject(required: ["v", "type", "to"],
                                                optional: ["id", "streamId", "sid"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.offline v") }
            let to = try frame.requiredString("to")
            try PCLinkValidation.requireMachineId(to)
            let offline = PCLinkRelayOffline(
                to: to,
                id: object["id"]?.stringValue,
                streamId: object["streamId"]?.stringValue,
                sid: object["sid"]?.stringValue)
            eventContinuation.yield(.offline(offline))
            return false

        case "relay.redirect":
            let object = try frame.closedObject(required: ["v", "type", "url"])
            guard object["v"]?.intValue == 1 else { throw PCLinkError.badFrame("relay.redirect v") }
            try PCLinkValidation.origin(try frame.requiredString("url"))
            // Reserved: log and ignore, never act on it (§3.6).
            return false

        case "relay.pair.joined":
            _ = try frame.closedObject(required: ["v", "type", "rendezvous", "role", "peerMachineId"])
            try requireRendezvousShape(frame)
            eventContinuation.yield(.frame(frame))
            return false

        case "relay.pair.message":
            _ = try frame.closedObject(required: ["v", "type", "rendezvous", "payload"])
            try requireRendezvousShape(frame)
            guard frame["payload"]?.objectValue != nil else {
                throw PCLinkError.badFrame("relay.pair.message payload")
            }
            eventContinuation.yield(.frame(frame))
            return false

        case "relay.pair.close":
            _ = try frame.closedObject(required: ["v", "type", "rendezvous", "reason"])
            try requireRendezvousShape(frame)
            let reasons: Set<String> = ["paired", "cancelled", "rejected", "peer_offline",
                                        "rendezvous_expired", "rendezvous_exhausted",
                                        "auth_failed", "storage", "timeout"]
            guard let reason = frame["reason"]?.stringValue, reasons.contains(reason) else {
                throw PCLinkError.badFrame("relay.pair.close reason")
            }
            eventContinuation.yield(.frame(frame))
            return false

        case "e2e", "e2e.handshake":
            guard state == .ready else { throw PCLinkError.badFrame("e2e before relay.ready") }
            eventContinuation.yield(.frame(frame))
            return false

        case "peer.auth", "relay.allow", "relay.pair.open", "relay.pair.join":
            throw PCLinkError.badFrame("unexpected relay frame \(type)")

        default:
            throw PCLinkError.badFrame("unknown relay frame type \(type)")
        }
    }

    private func requireRendezvousShape(_ frame: PCLinkJSON) throws {
        guard frame["v"]?.intValue == 1 else { throw PCLinkError.badFrame("pair frame v") }
        guard PCLinkValidation.sessionId(try frame.requiredString("rendezvous")) else {
            throw PCLinkError.badFrame("bad rendezvous")
        }
    }

    private func closeCode(for error: PCLinkError) -> UInt16 {
        switch error {
        case .authFailed: return 4002
        case .replaced: return 4001
        case .frameTooLarge: return 1009
        default: return 1008
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        guard configuration.heartbeatEnabled else { return }
        heartbeatTask = Task { await self.heartbeatLoop() }
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled, state == .ready {
            let interval = Double.random(in: configuration.heartbeatIntervalRange)
            do {
                try await Task.sleep(nanoseconds: UInt64(max(interval, 0.001) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, state == .ready else { return }
            if outstandingPing != nil {
                // Two consecutive pings without a matching pong close the
                // connection with 1001 (§3.4).
                await shutdown(code: 1001, reason: "heartbeat timeout", error: nil)
                return
            }
            let nonce = (try? PCLinkRandom.bytes(16)) ?? Data((0..<16).map { _ in 0 })
            outstandingPing = nonce
            do {
                try await sendObject(.object([
                    "v": .int(1), "type": .string("relay.ping"),
                    "nonce": .string(PCLinkBase64URL.encode(nonce)),
                ]), allowBeforeReady: false)
            } catch {
                await connectionEnded(code: nil, reason: nil, error: nil)
                return
            }
        }
    }

    // MARK: Waiters / teardown

    private func awaitChallenge() async throws -> Data {
        if let challengeNonce {
            self.challengeNonce = nil
            return challengeNonce
        }
        return try await withCheckedThrowingContinuation { continuation in
            challengeContinuation = continuation
            challengeTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(configuration.challengeTimeout * 1_000_000_000))
                } catch { return }
                await self.timeoutChallenge()
            }
        }
    }

    private func awaitReady() async throws {
        if readyReceived { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
            readyTimeoutTask = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(configuration.readyTimeout * 1_000_000_000))
                } catch { return }
                await self.timeoutReady()
            }
        }
    }

    private func timeoutChallenge() async {
        guard let continuation = challengeContinuation else { return }
        challengeContinuation = nil
        continuation.resume(throwing: PCLinkError.unavailable("relay.challenge timeout"))
        await shutdown(code: 4002, reason: "auth_failed", error: PCLinkError.authFailed("relay.challenge timeout"))
    }

    private func timeoutReady() async {
        guard let continuation = readyContinuation else { return }
        readyContinuation = nil
        continuation.resume(throwing: PCLinkError.authFailed("relay.ready timeout"))
        await shutdown(code: 4002, reason: "auth_failed", error: PCLinkError.authFailed("relay.ready timeout"))
    }

    private func protocolViolation(_ error: PCLinkError, code: UInt16) async {
        await shutdown(code: code, reason: error.code, error: error)
    }

    private func connectionEnded(code: UInt16?, reason: String?, error: PCLinkError?) async {
        await shutdown(code: code, reason: reason, error: error)
    }

    private func shutdown(code: UInt16?, reason: String?, error: PCLinkError?) async {
        if finished { return }
        finished = true
        state = .closed
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        challengeTimeoutTask?.cancel()
        readyTimeoutTask?.cancel()
        sendSignal?.finish()
        sendSignal = nil
        sendWriter?.cancel()
        sendWriter = nil
        failQueuedSends(error ?? PCLinkError.unavailable("relay connection closed"))
        if let continuation = challengeContinuation {
            challengeContinuation = nil
            continuation.resume(throwing: error ?? PCLinkError.unavailable("relay connection closed"))
        }
        if let continuation = readyContinuation {
            readyContinuation = nil
            continuation.resume(throwing: error ?? PCLinkError.unavailable("relay connection closed"))
        }
        let socket = self.socket
        self.socket = nil
        if let code {
            await socket?.close(code: code, reason: reason ?? "")
        } else {
            await socket?.close(code: 1000, reason: reason ?? "")
        }
        eventContinuation.yield(.closed(code: code, reason: reason, error: error))
        eventContinuation.finish()
    }

    /// Used by `finish` callers before the stream's consumer is attached.
    private func finish(code: UInt16?, reason: String?, error: PCLinkError?) async {
        await shutdown(code: code, reason: reason, error: error)
    }

    // MARK: Single socket writer

    private func startSendWriter() {
        guard sendWriter == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        sendSignal = continuation
        sendWriter = Task { [weak self] in
            for await _ in stream {
                await self?.drainSendQueue()
            }
        }
    }

    private func drainSendQueue() async {
        while !sendQueue.isEmpty {
            let item = sendQueue.removeFirst()
            guard let socket else {
                item.continuation.resume(throwing: PCLinkError.peerOffline)
                continue
            }
            do {
                try await socket.send(text: item.text)
                item.continuation.resume()
            } catch let error as PCLinkError {
                item.continuation.resume(throwing: error)
            } catch {
                item.continuation.resume(
                    throwing: PCLinkError.unavailable("relay send failed: \(error)"))
            }
        }
    }

    private func failQueuedSends(_ error: PCLinkError) {
        let queued = sendQueue
        sendQueue.removeAll()
        for item in queued {
            item.continuation.resume(throwing: error)
        }
    }

    private func sendObject(_ object: PCLinkJSON, allowBeforeReady: Bool) async throws {
        guard allowBeforeReady || state == .ready else { throw PCLinkError.peerOffline }
        let data: Data
        do {
            data = try PCLinkJSONEncoder.encode(object)
        } catch {
            throw PCLinkError.badFrame("cannot encode relay frame")
        }
        guard data.count <= configuration.frameLimit else {
            throw PCLinkError.frameTooLarge("relay frame exceeds 16 MiB")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PCLinkError.badFrame("relay frame is not UTF-8")
        }
        guard sendWriter != nil, socket != nil else { throw PCLinkError.peerOffline }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.append(QueuedSend(text: text, continuation: continuation))
            sendSignal?.yield()
        }
    }
}
