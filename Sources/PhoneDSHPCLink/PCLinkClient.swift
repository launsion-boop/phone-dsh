// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: App-facing PCLink client (state, pairing, relay/E2E session
// lifecycle, RPC correlation and notices).

import Foundation

// MARK: - Public state

public struct PCLinkVersionWarning: Equatable, Sendable {
    public var dshVersion: String
    public var testedRange: String
    public var message: String

    public init(dshVersion: String, testedRange: String = PCLinkEndpoints.dshTestedRange) {
        self.dshVersion = dshVersion
        self.testedRange = testedRange
        self.message = "版本未验证：电脑 DSH \(dshVersion) 不在测试范围 \(testedRange) 内"
    }
}

public enum PCLinkUnpairedReason: Equatable, Sendable {
    case noRecord
    case identityMissing
    case staleRecord
    case unsupported(String)
}

public enum PCLinkPairingPhase: Equatable, Sendable {
    case idle
    case joining
    case waitingForPC
    case awaitingUser
    case authenticating
    case awaitingConfirmation
    case completed
    case failed(PCLinkError)
}

public enum PCLinkOfflineReason: Equatable, Sendable {
    case notStarted
    case network
    case peerOffline
    case replaced
    case authenticationFailed
    case versionUnsupported
    case unpairedPrompt
    case protocolError(String)
    case storage(String)
}

public enum PCLinkClientState: Equatable, Sendable {
    case unpaired(PCLinkUnpairedReason)
    case pairing(PCLinkPairingPhase)
    case connecting
    case online
    case offline(PCLinkOfflineReason)
    case versionWarning(PCLinkVersionWarning)

    public var isOnline: Bool {
        switch self {
        case .online, .versionWarning: return true
        default: return false
        }
    }
}

public struct PCLinkClientStatus: Equatable, Sendable {
    public var state: PCLinkClientState
    public var machineId: String?
    public var fingerprint: String?
    public var record: PCLinkPairingRecord?
    public var versionWarning: PCLinkVersionWarning?
    public var lastNotice: PCLinkNotice?
    public var lastError: PCLinkError?
    public var pairingPrompt: PCLinkPairingPrompt?
    public var pcUnpairedPrompt: PCLinkPCUnpairedPrompt?

    public init(state: PCLinkClientState = .offline(.notStarted),
                machineId: String? = nil,
                fingerprint: String? = nil,
                record: PCLinkPairingRecord? = nil,
                versionWarning: PCLinkVersionWarning? = nil,
                lastNotice: PCLinkNotice? = nil,
                lastError: PCLinkError? = nil,
                pairingPrompt: PCLinkPairingPrompt? = nil,
                pcUnpairedPrompt: PCLinkPCUnpairedPrompt? = nil) {
        self.state = state
        self.machineId = machineId
        self.fingerprint = fingerprint
        self.record = record
        self.versionWarning = versionWarning
        self.lastNotice = lastNotice
        self.lastError = lastError
        self.pairingPrompt = pairingPrompt
        self.pcUnpairedPrompt = pcUnpairedPrompt
    }
}

public struct PCLinkPairingPrompt: Equatable, Sendable {
    public var id: UUID
    public var mode: PCLinkPairingMode
    public var relayOrigin: String
    public var pcName: String
    public var pcMachineId: String
    public var ownFingerprint: String
    public var warningText: String
    public var expiresAt: Date

    public static let fullOwnerWarning =
        "此手机将能完整操作这台电脑上的 DSH：对话、在电脑上执行 Shell 和读写文件、处理审批、修改设置和插件。"
}

public struct PCLinkPairingResult: Equatable, Sendable {
    public var record: PCLinkPairingRecord
    public var prompt: PCLinkPairingPrompt
}

/// A verified signed `unpaired` reject (or an authenticated `session.close`
/// with `code:"unpaired"`). The phone keeps its record until the user
/// explicitly confirms removal.
public struct PCLinkPCUnpairedPrompt: Equatable, Sendable {
    public var code: String
    public var message: String
    public var record: PCLinkPairingRecord
    public static let text = "电脑已解除与此手机的配对"
}

public struct PCLinkNotice: Equatable, Sendable {
    public var kind: String
    public var name: String
    public var fingerprint: String
    public var at: String

    public static let warning =
        "收到新的配对通知。如果不是你本人刚配对的新手机，请立即在电脑上「撤销全部配对」并运行 rotate-identity。"
}

public enum PCLinkNotices {
    public static let longOfflineHint =
        "电脑长时间离线。如果电脑已更换身份或解除配对，请手动解除配对。"
}

// MARK: - Configuration

public struct PCLinkClientConfiguration: Sendable {
    public var phoneName: String
    public var appName: String
    public var appVersion: String
    public var phoneDshVersion: String
    public var phoneDshCommit: String?
    public var websocketFactory: any PCLinkWebSocketFactory
    public var reconnectPolicy: PCLinkReconnectPolicy
    public var connectTimeout: TimeInterval
    public var handshakeTimeout: TimeInterval
    public var callRetryDeadline: TimeInterval
    public var pairingTimeout: TimeInterval
    public var pairingPromptTimeout: TimeInterval
    public var heartbeatIntervalRange: ClosedRange<TimeInterval>
    public var heartbeatEnabled: Bool

    public init(phoneName: String = "iPhone",
                appName: String = "phoneDSH",
                appVersion: String = "0.1.0",
                phoneDshVersion: String = "0.2.2-rc.1",
                phoneDshCommit: String? = nil,
                websocketFactory: any PCLinkWebSocketFactory = PCLinkURLSessionWebSocketFactory(),
                reconnectPolicy: PCLinkReconnectPolicy = .v1,
                connectTimeout: TimeInterval = 15,
                handshakeTimeout: TimeInterval = PCLinkLimits.handshakeStepTimeout,
                callRetryDeadline: TimeInterval = 120,
                pairingTimeout: TimeInterval = 120,
                pairingPromptTimeout: TimeInterval = PCLinkLimits.pairingApprovalTimeout,
                heartbeatIntervalRange: ClosedRange<TimeInterval> = PCLinkLimits.heartbeatRange,
                heartbeatEnabled: Bool = true) {
        self.phoneName = phoneName
        self.appName = appName
        self.appVersion = appVersion
        self.phoneDshVersion = phoneDshVersion
        self.phoneDshCommit = phoneDshCommit
        self.websocketFactory = websocketFactory
        self.reconnectPolicy = reconnectPolicy
        self.connectTimeout = connectTimeout
        self.handshakeTimeout = handshakeTimeout
        self.callRetryDeadline = callRetryDeadline
        self.pairingTimeout = pairingTimeout
        self.pairingPromptTimeout = pairingPromptTimeout
        self.heartbeatIntervalRange = heartbeatIntervalRange
        self.heartbeatEnabled = heartbeatEnabled
    }
}

// MARK: - Mux endpoint

public struct PCLinkMuxEndpoint: Sendable {
    public let id: UUID
    public let frames: AsyncStream<PCLinkJSON>
}

// MARK: - Client

public actor PCLinkClient {
    private struct MuxState {
        var continuation: AsyncStream<PCLinkJSON>.Continuation
        var streams: [String: StreamState] = [:]
        var usedStreamIDs: Set<String> = []
    }

    private struct StreamState {
        var muxID: UUID
        var endpoint: String
        var retry: PCLinkRetryClass
        var payload: PCLinkJSON
        var chunkKey: String
        var sessionID: String?
        var cancelled: Bool = false
    }

    private final class PendingCall {
        let endpoint: String
        let retry: PCLinkRetryClass
        var continuation: CheckedContinuation<PCLinkJSON, Error>?
        var sent: Bool = false
        var sessionID: String?

        init(endpoint: String, retry: PCLinkRetryClass) {
            self.endpoint = endpoint
            self.retry = retry
        }
    }

    private final class PairingContext {
        let id = UUID()
        let offer: PCLinkPairingOffer
        let relay: PCLinkRelayClient
        var consumer: Task<Void, Never>?
        var joined = false
        var hello: PCLinkPairHello?
        var authNonce: Data?
        var transcriptHash: Data?
        var helloWaiter: CheckedContinuation<PCLinkPairHello, Error>?
        var confirmWaiter: CheckedContinuation<PCLinkPairConfirm, Error>?
        var timeoutTask: Task<Void, Never>?
        var failure: PCLinkError?
        var completed = false
        var prompt: PCLinkPairingPrompt?
        var expiresAt = Date()

        init(offer: PCLinkPairingOffer, relay: PCLinkRelayClient) {
            self.offer = offer
            self.relay = relay
        }
    }

    private enum HandshakeKind {
        case initial
        case rekey
    }

    private struct HandshakeState {
        var session: PCLinkE2ESession
        var kind: HandshakeKind
        var continuation: CheckedContinuation<PCLinkPeerHello, Error>
        var timeoutTask: Task<Void, Never>?
    }

    public nonisolated let configuration: PCLinkClientConfiguration
    private let identityStore: any PCLinkIdentityStore
    private let pairingStore: any PCLinkPairingStore

    private var identity: PCLinkIdentity?
    private var record: PCLinkPairingRecord?
    private var staleRecord: PCLinkPairingRecord?
    private var state: PCLinkClientState = .offline(.notStarted)
    private var versionWarning: PCLinkVersionWarning?
    private var lastNotice: PCLinkNotice?
    private var lastError: PCLinkError?
    private var pcUnpairedPrompt: PCLinkPCUnpairedPrompt?

    private var stateContinuations: [UUID: AsyncStream<PCLinkClientState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PCLinkNotice>.Continuation] = [:]

    private var connectionTask: Task<Void, Never>?
    private var userWantsConnection = false
    private var stopped = false
    private var attempt = 0
    private var onlineSince: Date?
    private var terminalError: PCLinkError?

    private var relay: PCLinkRelayClient?
    private var relayConsumer: Task<Void, Never>?
    private var session: PCLinkE2ESession?
    private var handshake: HandshakeState?
    private var rekeySession: PCLinkE2ESession?
    private var disconnected = false
    private var disconnectContinuation: CheckedContinuation<Void, Never>?

    private var sessionWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingCalls: [String: PendingCall] = [:]
    private var resultChunks: [String: PCLinkChunkReassembler] = [:]
    private var muxes: [UUID: MuxState] = [:]
    private var streamChunks: [String: PCLinkChunkReassembler] = [:]

    private var pairingContext: PairingContext?
    private var nextCorrelation = 0

    public init(identityStore: any PCLinkIdentityStore = PCLinkKeychainIdentityStore(),
                pairingStore: any PCLinkPairingStore = PCLinkFilePairingStore(),
                configuration: PCLinkClientConfiguration = PCLinkClientConfiguration()) {
        self.identityStore = identityStore
        self.pairingStore = pairingStore
        self.configuration = configuration
    }

    // MARK: Status / streams

    public func currentState() -> PCLinkClientState {
        effectiveState()
    }

    public func status() -> PCLinkClientStatus {
        PCLinkClientStatus(state: effectiveState(),
                           machineId: identity?.machineId,
                           fingerprint: identity?.fingerprint,
                           record: record,
                           versionWarning: versionWarning,
                           lastNotice: lastNotice,
                           lastError: lastError,
                           pairingPrompt: pairingContext?.prompt,
                           pcUnpairedPrompt: pcUnpairedPrompt)
    }

    public func stateStream() -> AsyncStream<PCLinkClientState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            stateContinuations[id] = continuation
            continuation.yield(effectiveState())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    public func notices() -> AsyncStream<PCLinkNotice> {
        noticeStream()
    }

    public func noticeStream() -> AsyncStream<PCLinkNotice> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            noticeContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeNoticeContinuation(id) }
            }
        }
    }

    private func effectiveState() -> PCLinkClientState {
        if state.isOnline, let versionWarning { return .versionWarning(versionWarning) }
        return state
    }

    private func setState(_ newState: PCLinkClientState) {
        state = newState
        let emitted = effectiveState()
        for continuation in stateContinuations.values {
            continuation.yield(emitted)
        }
    }

    private func yieldNotice(_ notice: PCLinkNotice) {
        lastNotice = notice
        for continuation in noticeContinuations.values {
            continuation.yield(notice)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func removeNoticeContinuation(_ id: UUID) {
        noticeContinuations[id] = nil
    }

    // MARK: Start / stop

    public func start() async throws {
        stopped = false
        userWantsConnection = true
        terminalError = nil
        lastError = nil
        try await loadIdentityAndRecord()
        if record != nil {
            startConnectionLoopIfNeeded()
        } else if case .unpaired = effectiveState() {
            // already set by loadIdentityAndRecord
        } else {
            setState(.unpaired(staleRecord == nil ? .noRecord : .staleRecord))
        }
    }

    public func connectAndWait() async throws {
        try await start()
        guard record != nil else { throw PCLinkError.notPaired }
        _ = try await requireSession()
    }

    public func stop() async {
        userWantsConnection = false
        stopped = true
        connectionTask?.cancel()
        connectionTask = nil
        await teardownConnection(error: nil)
        setState(record == nil ? .unpaired(staleRecord == nil ? .noRecord : .staleRecord) : .offline(.notStarted))
    }

    public func disconnect() async {
        await stop()
    }

    private func loadIdentityAndRecord() async throws {
        if identity == nil {
            let stored = try identityStore.loadSeed()
            if let stored {
                identity = try PCLinkIdentity(seed: stored)
            } else if pairingStore.hasStoredFile() {
                // A missing phone key while a pairing record exists is not
                // silently regenerated (§2.2).
                record = nil
                setState(.unpaired(.identityMissing))
                throw PCLinkError.noIdentity
            } else {
                let generated = try PCLinkIdentity.generate()
                try identityStore.saveSeed(generated.seed)
                identity = generated
            }
        }
        guard let identity else { throw PCLinkError.noIdentity }
        let loaded = try pairingStore.load(phoneMachineId: identity.machineId)
        switch loaded {
        case .none:
            record = nil
            staleRecord = nil
            if state != .pairing(.idle) {
                setState(.unpaired(.noRecord))
            }
        case .usable(let value):
            record = value
            staleRecord = nil
        case .stale(let value):
            record = nil
            staleRecord = value
            setState(.unpaired(.staleRecord))
        }
    }

    // MARK: Connection loop

    private func startConnectionLoopIfNeeded() {
        guard connectionTask == nil, userWantsConnection, record != nil else { return }
        connectionTask = Task { await self.connectionLoop() }
    }

    private func connectionLoop() async {
        defer { connectionTask = nil }
        while !Task.isCancelled, userWantsConnection {
            guard let record else {
                setState(.unpaired(staleRecord == nil ? .noRecord : .staleRecord))
                return
            }
            setState(.connecting)
            terminalError = nil
            do {
                try await runOneConnection(record: record)
            } catch let error as PCLinkError {
                lastError = error
                await teardownConnection(error: error)
                switch error {
                case .unpaired:
                    terminalError = error
                    failSessionWaiters(error)
                    setState(pcUnpairedPrompt == nil
                        ? .unpaired(staleRecord == nil ? .noRecord : .staleRecord)
                        : .offline(.unpairedPrompt))
                    return
                case .authFailed:
                    terminalError = error
                    failSessionWaiters(error)
                    setState(.offline(.authenticationFailed))
                    return
                case .versionUnsupported:
                    terminalError = error
                    failSessionWaiters(error)
                    setState(.offline(.versionUnsupported))
                    return
                case .replay, .badFrame, .frameTooLarge:
                    terminalError = error
                    failSessionWaiters(error)
                    setState(.offline(.protocolError(error.message)))
                    return
                case .noIdentity, .notPaired:
                    terminalError = error
                    failSessionWaiters(error)
                    setState(.unpaired(.identityMissing))
                    return
                case .replaced:
                    setState(.offline(.replaced))
                    do {
                    try await Task.sleep(nanoseconds: UInt64(configuration.reconnectPolicy.replacedDelay(attempt: max(1, attempt)) * 1_000_000_000))
                } catch { return }
                default:
                    setState(.offline(.network))
                }
            } catch {
                lastError = .unavailable("\(error)")
                await teardownConnection(error: lastError)
                setState(.offline(.network))
            }
            // §10: the backoff resets only after 60 s of a successful
            // connection, not immediately after the handshake.
            if let onlineSince,
               Date().timeIntervalSince(onlineSince) >= configuration.reconnectPolicy.resetAfter {
                attempt = 0
            }
            onlineSince = nil
            guard !Task.isCancelled, userWantsConnection else { return }
            attempt += 1
            let delay = configuration.reconnectPolicy.delay(attempt: attempt)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    /// One relay connection: authenticate, establish the E2E session, stay
    /// online until the socket closes or a terminal handshake error occurs.
    private func runOneConnection(record: PCLinkPairingRecord) async throws {
        guard let identity else { throw PCLinkError.noIdentity }
        disconnected = false
        let relay = PCLinkRelayClient(
            configuration: .init(origin: record.relayOrigin, identity: identity,
                                 role: "phone",
                                 frameLimit: PCLinkLimits.maxRelayFrameBytes,
                                 heartbeatIntervalRange: configuration.heartbeatIntervalRange,
                                 heartbeatEnabled: configuration.heartbeatEnabled),
            factory: configuration.websocketFactory)
        self.relay = relay
        let consumer = Task { [weak self] in
            for await event in relay.events {
                await self?.handleRelayEvent(event)
            }
        }
        relayConsumer = consumer
        do {
            try await relay.connect()
        } catch {
            consumer.cancel()
            throw (error as? PCLinkError) ?? .unavailable("relay connect: \(error)")
        }
        do {
            try await startInitialHandshake()
        } catch {
            consumer.cancel()
            throw (error as? PCLinkError) ?? .unavailable("handshake: \(error)")
        }
        onlineSince = Date()
        setState(.online)
        await waitForDisconnect()
        await teardownConnection(error: lastError)
        if let terminalError { throw terminalError }
        if let lastError, !lastError.isRetryable, lastError != .peerOffline {
            throw lastError
        }
        setState(.offline(.network))
    }

    private func waitForDisconnect() async {
        if disconnected { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            disconnectContinuation = continuation
        }
    }

    // MARK: Handshake

    private func makePeerHello() throws -> PCLinkPeerHello {
        var caps = ["workspace/1", PCLinkCrypto.suite]
        if !caps.contains(PCLinkEndpoints.suite) { caps = [PCLinkEndpoints.suite] + caps }
        return try PCLinkPeerHello.make(
            role: "phone",
            caps: caps,
            dshVersion: configuration.phoneDshVersion,
            dshCommit: configuration.phoneDshCommit,
            appName: configuration.appName,
            appVersion: configuration.appVersion,
            name: configuration.phoneName)
    }

    private func startInitialHandshake() async throws {
        guard let identity, let record else { throw PCLinkError.notPaired }
        let session = try PCLinkE2ESession(identity: identity, peer: record)
        self.session = session
        let hello = try await beginHandshake(session: session, kind: .initial)
        install(session: session, hello: hello)
    }

    /// Installs the waiter *before* sending `session.init`, otherwise a very
    /// fast `session.resp` could arrive while `handshake` is still nil.
    private func beginHandshake(session: PCLinkE2ESession,
                                kind: HandshakeKind) async throws -> PCLinkPeerHello {
        let timeout = configuration.handshakeTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let task = Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch { return }
                await self.timeoutHandshake(sid: session.sid)
            }
            handshake = HandshakeState(session: session, kind: kind,
                                       continuation: continuation, timeoutTask: task)
            Task { [weak self] in
                do {
                    try await self?.sendHandshakeFrame(session.initFrame)
                } catch {
                    await self?.handshakeSendFailed(sid: session.sid, error: error)
                }
            }
        }
    }

    private func handshakeSendFailed(sid: String, error: Error) {
        guard let handshake, handshake.session.sid == sid else { return }
        failHandshake((error as? PCLinkError) ?? .peerOffline)
    }

    private func timeoutHandshake(sid: String) async {
        guard let handshake, handshake.session.sid == sid else { return }
        let error = PCLinkError.unavailable("handshake timed out")
        failHandshake(error)
    }

    private func failHandshake(_ error: PCLinkError) {
        guard let handshake else { return }
        self.handshake = nil
        handshake.timeoutTask?.cancel()
        handshake.session.markClosed()
        handshake.continuation.resume(throwing: error)
        if case .initial = handshake.kind {
            lastError = error
        }
    }

    private func install(session: PCLinkE2ESession, hello: PCLinkPeerHello) {
        self.session = session
        versionWarning = hello.versionWarning
            ? PCLinkVersionWarning(dshVersion: hello.dshVersionText)
            : nil
        setState(versionWarning == nil ? .online : .versionWarning(versionWarning!))
        resumeSessionWaiters()
        if session.needsRekey {
            startRekeyIfNeeded()
        }
    }

    private func startRekeyIfNeeded() {
        guard handshake == nil, rekeySession == nil, let identity, let record,
              session?.phase == .established else { return }
        do {
            let replacement = try PCLinkE2ESession(identity: identity, peer: record)
            rekeySession = replacement
            Task { [weak self] in
                do {
                    _ = try await self?.beginHandshake(session: replacement, kind: .rekey)
                } catch {
                    await self?.rekeyFailed(error)
                }
            }
        } catch {
            rekeySession = nil
        }
    }

    private func rekeyFailed(_ error: Error) {
        rekeySession = nil
        // The older session stays valid for in-flight frames, but no new call
        // is sent on it after a rekey has started (§5.5).
        lastError = (error as? PCLinkError) ?? .unavailable("rekey failed")
    }

    private func completeRekey(_ replacement: PCLinkE2ESession, hello: PCLinkPeerHello) {
        let old = session
        if let old {
            // In-flight calls that were sent on the old sid follow §7 on the
            // new session; mux consumers see a closed socket and reopen.
            let oldCalls = pendingCalls.filter { $0.value.sessionID == old.sid }
            for (id, pending) in oldCalls {
                pendingCalls.removeValue(forKey: id)
                pending.continuation?.resume(throwing: PCLinkSessionLost(
                    reason: .sessionExpired("rekey moved the session")))
            }
            let oldMuxes = muxes
            muxes.removeAll()
            for mux in oldMuxes.values {
                mux.continuation.finish()
            }
            streamChunks.removeAll()
        }
        session = replacement
        rekeySession = nil
        versionWarning = hello.versionWarning
            ? PCLinkVersionWarning(dshVersion: hello.dshVersionText)
            : nil
        setState(versionWarning == nil ? .online : .versionWarning(versionWarning!))
        if let old {
            Task { [weak self] in
                if let frame = try? old.closeFrame(code: "rekey") {
                    try? await self?.relay?.send(frame)
                }
                old.markClosed()
            }
        }
        resumeSessionWaiters()
    }

    private func sendHandshakeFrame(_ frame: PCLinkJSON) async throws {
        guard let relay else { throw PCLinkError.peerOffline }
        do {
            try await relay.send(frame)
        } catch let error as PCLinkError {
            throw error
        } catch {
            throw PCLinkError.peerOffline
        }
    }

    private func sendInner(_ inner: PCLinkJSON, session: PCLinkE2ESession? = nil) async throws {
        guard let relay else { throw PCLinkError.peerOffline }
        guard let active = session ?? self.session, active.phase == .established else {
            throw PCLinkError.sessionExpired("no established session")
        }
        let frame: PCLinkJSON
        do {
            frame = try active.seal(inner)
        } catch let error as PCLinkError {
            if case .sessionExpired = error {
                sessionTeardown(reason: error)
                signalDisconnect()
            }
            throw error
        }
        do {
            try await relay.send(frame)
        } catch let error as PCLinkError {
            throw error
        } catch {
            throw PCLinkError.peerOffline
        }
        if active.needsRekey { startRekeyIfNeeded() }
    }

    // MARK: Session waiters

    private func requireSession() async throws -> PCLinkSessionLike {
        if let session, session.phase == .established, rekeySession == nil {
            if session.needsRekey {
                startRekeyIfNeeded()
            } else {
                return PCLinkSessionLike(session: session)
            }
        }
        if let terminalError, !terminalError.isRetryable {
            throw terminalError
        }
        startConnectionLoopIfNeeded()
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            sessionWaiters[id] = continuation
            Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(configuration.connectTimeout, 0.05) * 1_000_000_000))
                } catch { return }
                await self.timeoutSessionWaiter(id)
            }
        }
        guard let session, session.phase == .established else {
            throw PCLinkError.peerOffline
        }
        return PCLinkSessionLike(session: session)
    }

    /// Small value wrapper so the transport can use the session without
    /// exposing the mutable session class.
    struct PCLinkSessionLike {
        let session: PCLinkE2ESession
    }

    private func timeoutSessionWaiter(_ id: UUID) async {
        guard let continuation = sessionWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: PCLinkError.peerOffline)
    }

    private func resumeSessionWaiters() {
        let waiters = sessionWaiters
        sessionWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    private func failSessionWaiters(_ error: PCLinkError) {
        let waiters = sessionWaiters
        sessionWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: Relay event handling

    private func handleRelayEvent(_ event: PCLinkRelayEvent) async {
        switch event {
        case .ready:
            break
        case .frame(let frame):
            await handleRelayFrame(frame)
        case .offline(let offline):
            handleRelayOffline(offline)
        case .error(let error):
            lastError = error
            switch error {
            case .unpaired:
                terminalError = error
                failSessionWaiters(error)
                if handshake != nil { failHandshake(error) }
            case .authFailed, .versionUnsupported:
                terminalError = error
                failSessionWaiters(error)
                if handshake != nil { failHandshake(error) }
            case .replaced:
                terminalError = error
                failSessionWaiters(error)
                if handshake != nil { failHandshake(error) }
                sessionTeardown(reason: error)
                signalDisconnect()
            default:
                break
            }
        case .closed(_, _, let error):
            if let error { lastError = error }
            sessionTeardown(reason: error ?? lastError ?? .sessionExpired("relay connection closed"))
            signalDisconnect()
        }
    }

    private func handleRelayFrame(_ frame: PCLinkJSON) async {
        switch frame["type"]?.stringValue {
        case "e2e.handshake":
            handleHandshakeFrame(frame)
        case "e2e":
            handleE2EFrame(frame)
        default:
            break
        }
    }

    private func handleHandshakeFrame(_ frame: PCLinkJSON) {
        guard let sid = frame["sid"]?.stringValue else { return }
        guard let handshake, handshake.session.sid == sid else {
            return
        }
        let body = frame["body"] ?? .null
        switch body["type"]?.stringValue {
        case "session.resp":
            do {
                try handshake.session.acceptResp(outer: frame)
                let confirm = try handshake.session.confirmFrame()
                let hello = try makePeerHello()
                let helloFrame = try handshake.session.makePeerHelloFrame(hello: hello)
                Task { [weak self] in
                    do {
                        try await self?.sendHandshakeFrame(confirm)
                        try await self?.sendHandshakeFrame(helloFrame)
                        await self?.armHandshakeStepTimeout(sid: sid)
                    } catch {
                        await self?.handshakeTransportFailed(error)
                    }
                }
            } catch let error as PCLinkError {
                failHandshake(error)
            } catch {
                failHandshake(.authFailed("session.resp verification failed"))
            }
        case "session.reject":
            let result = handshake.session.verifyReject(body)
            switch result {
            case .verified(code: "unpaired", let message):
                pcUnpairedPrompt = PCLinkPCUnpairedPrompt(code: "unpaired", message: message,
                                                          record: handshake.session.peer)
                failHandshake(.unpaired(message))
                setState(.offline(.unpairedPrompt))
            case .verified(let code, let message):
                failHandshake(PCLinkError.code(code, message: message))
            case .unauthenticated(_, let message):
                failHandshake(.authFailed("unauthenticated session.reject: \(message)"))
            }
        default:
            failHandshake(.badFrame("unexpected handshake body"))
        }
    }

    private func armHandshakeStepTimeout(sid: String) {
        guard let handshake, handshake.session.sid == sid else { return }
        handshake.timeoutTask?.cancel()
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(configuration.handshakeTimeout * 1_000_000_000))
            } catch { return }
            await self.timeoutHandshake(sid: sid)
        }
        self.handshake?.timeoutTask = task
    }

    private func handshakeTransportFailed(_ error: Error) {
        sessionTeardown(reason: (error as? PCLinkError) ?? .peerOffline)
        signalDisconnect()
    }

    private func handleE2EFrame(_ frame: PCLinkJSON) {
        guard let sid = frame["sid"]?.stringValue else { return }
        // A frame for the active session.
        if let session, session.sid == sid {
            do {
                let decoded = try session.open(frame)
                if !session.peerHelloReceived {
                    if decoded.inner["type"]?.stringValue == "session.close" {
                        handleSessionClose(decoded.inner, session: session)
                        return
                    }
                    let hello = try session.acceptFirstInner(decoded.inner)
                    if let handshake, handshake.session.sid == sid {
                        self.handshake = nil
                        handshake.timeoutTask?.cancel()
                        handshake.continuation.resume(returning: hello)
                    }
                    return
                }
                handleInner(decoded.inner, session: session)
                if session.needsRekey { startRekeyIfNeeded() }
            } catch let error as PCLinkError {
                handleSessionError(error)
            } catch {
                handleSessionError(.badFrame("E2E frame handling failed"))
            }
            return
        }
        if let rekeySession, rekeySession.sid == sid {
            do {
                let decoded = try rekeySession.open(frame)
                if !rekeySession.peerHelloReceived {
                    if decoded.inner["type"]?.stringValue == "session.close" {
                        handleSessionClose(decoded.inner, session: rekeySession)
                        return
                    }
                    let hello = try rekeySession.acceptFirstInner(decoded.inner)
                    if let handshake, handshake.session.sid == sid {
                        self.handshake = nil
                        handshake.timeoutTask?.cancel()
                        completeRekey(rekeySession, hello: hello)
                        handshake.continuation.resume(returning: hello)
                    }
                    return
                }
                handleInner(decoded.inner, session: rekeySession)
            } catch let error as PCLinkError {
                rekeyFailed(error)
                rekeySession.markClosed()
                self.rekeySession = nil
            } catch {
                rekeyFailed(PCLinkError.badFrame("rekey frame handling failed"))
                rekeySession.markClosed()
                self.rekeySession = nil
            }
        }
        // Unknown/closed sid: dropped (§5.5).
    }

    private func handleSessionError(_ error: PCLinkError) {
        switch error {
        case .replay, .authFailed, .badFrame, .sessionExpired, .frameTooLarge:
            switch error {
            case .replay, .authFailed, .badFrame, .frameTooLarge:
                terminalError = error
            default:
                break
            }
            sessionTeardown(reason: error)
            signalDisconnect()
        default:
            lastError = error
        }
    }

    private func handleRelayOffline(_ offline: PCLinkRelayOffline) {
        // The relay reports an undelivered e2e frame with the outer sid; the
        // inner id is not visible to it. Every pending call on that session
        // was therefore not delivered, so `peer_offline` (not
        // `unknown_outcome`) is the correct local outcome.
        if let sid = offline.sid, session?.sid == sid || rekeySession?.sid == sid {
            let calls = pendingCalls
            pendingCalls.removeAll()
            for pending in calls.values {
                pending.continuation?.resume(throwing: PCLinkError.peerOffline)
            }
        }
        if let id = offline.id, let pending = pendingCalls.removeValue(forKey: id) {
            pending.continuation?.resume(throwing: PCLinkError.peerOffline)
        }
        if let streamId = offline.streamId, let muxID = muxForStream(streamId) {
            emitStreamError(muxID: muxID, streamId: streamId,
                            error: PCLinkRPCError(code: "peer_offline", message: "the PC is offline"))
        }
        // The PC's relay connection is gone, so the E2E session cannot be
        // trusted any more. Reconnect the relay and run a fresh handshake.
        lastError = .peerOffline
        sessionTeardown(reason: .peerOffline)
        setState(.offline(.peerOffline))
        signalDisconnect()
        Task { [weak self] in await self?.relay?.close() }
    }

    // MARK: Inner messages

    private func handleInner(_ inner: PCLinkJSON, session: PCLinkE2ESession) {
        guard let type = inner["type"]?.stringValue else {
            handleSessionError(.badFrame("inner message has no type"))
            return
        }
        switch type {
        case "peer.hello":
            handleSessionError(.badFrame("duplicate peer.hello"))
        case "pclink.notice":
            do {
                try decodeNotice(inner)
            } catch {
                handleSessionError(.badFrame("invalid pclink.notice"))
            }
        case "session.close":
            handleSessionClose(inner, session: session)
        case "rpc.result", "rpc.result.chunk":
            handleResultFrame(inner)
        case "rpc.stream.item", "rpc.stream.chunk", "rpc.stream.end", "rpc.stream.error":
            handleStreamFrame(inner)
        default:
            if type.hasPrefix("task.") || type.hasPrefix("call.") {
                if type.hasSuffix(".error") { return }
                replyUnavailableReserved(inner)
                return
            }
            handleSessionError(.badFrame("unknown inner type \(type)"))
        }
    }

    private func decodeNotice(_ inner: PCLinkJSON) throws {
        let object = try inner.closedObject(required: ["type", "kind", "name", "fingerprint", "at"])
        guard object["kind"]?.stringValue == "paired" else {
            throw PCLinkError.badFrame("unknown notice kind")
        }
        let name = try inner.requiredString("name")
        try PCLinkValidation.name(name)
        let fingerprint = try inner.requiredString("fingerprint")
        guard fingerprint.range(of: #"^[a-z2-7]{4}-[a-z2-7]{4}-[a-z2-7]{4}$"#,
                                options: .regularExpression) != nil else {
            throw PCLinkError.badFrame("notice fingerprint")
        }
        let at = try inner.requiredString("at")
        guard PCLinkValidation.timestamp(at) else {
            throw PCLinkError.badFrame("notice at")
        }
        yieldNotice(PCLinkNotice(kind: "paired", name: name, fingerprint: fingerprint, at: at))
    }

    private func handleSessionClose(_ inner: PCLinkJSON, session: PCLinkE2ESession) {
        let object = try? inner.closedObject(required: ["type", "code"], optional: ["message"])
        guard let object, let code = object["code"]?.stringValue else {
            handleSessionError(.badFrame("session.close"))
            return
        }
        let message = object["message"]?.stringValue ?? ""
        do {
            // PCLink display text, not a DSH passthrough value (§2.3).
            try PCLinkValidation.displayText(message, field: "session.close message",
                                             maximumBytes: 512)
        } catch {
            handleSessionError(.badFrame("session.close message invalid"))
            return
        }
        let closeCodes: Set<String> = ["unavailable", "unpaired", "auth_failed", "replaced",
                                       "session_expired", "replay", "bad_frame",
                                       "frame_too_large", "rate_limited",
                                       "version_unsupported", "rekey"]
        guard closeCodes.contains(code) else {
            handleSessionError(.badFrame("unknown session.close code"))
            return
        }
        if code == "unpaired" {
            pcUnpairedPrompt = PCLinkPCUnpairedPrompt(code: code, message: message,
                                                      record: session.peer)
            let error = PCLinkError.unpaired(message)
            terminalError = error
            lastError = error
            sessionTeardown(reason: error)
            setState(.offline(.unpairedPrompt))
            signalDisconnect()
            return
        }
        if code == "rekey" {
            sessionTeardown(reason: .sessionExpired("rekey close"))
            return
        }
        let error = PCLinkError.code(code, message: message)
        if ["version_unsupported", "auth_failed", "bad_frame", "replay"].contains(code) {
            terminalError = error
        }
        sessionTeardown(reason: error)
        signalDisconnect()
    }

    private func replyUnavailableReserved(_ inner: PCLinkJSON) {
        guard let type = inner["type"]?.stringValue,
              let dot = type.firstIndex(of: ".") else { return }
        let prefix = String(type[..<dot])
        var reply: PCLinkJSONObject = [
            "type": .string("\(prefix)."),
            "code": .string("unavailable"),
            "message": .string("reserved namespace is unavailable"),
        ]
        if let id = inner["id"] { reply["id"] = id }
        if let typeValue = reply["type"]?.stringValue {
            reply["type"] = .string(typeValue + type.dropFirst(prefix.count + 1) + ".error")
        }
        if let session {
            Task { [weak self] in try? await self?.sendInner(.object(reply), session: session) }
        }
    }

    // MARK: Unary results

    private func nextID() -> String {
        nextCorrelation += 1
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        return "call-\(nextCorrelation)-\(suffix)"
    }

    private func handleResultFrame(_ inner: PCLinkJSON) {
        guard let type = inner["type"]?.stringValue else { return }
        if type == "rpc.result" {
            guard let id = inner["id"]?.stringValue else {
                handleSessionError(.badFrame("rpc.result without id"))
                return
            }
            if resultChunks[id] != nil {
                resultChunks.removeValue(forKey: id)
                failPendingCall(id, error: .badFrame("rpc.result arrived during chunked result"))
                return
            }
            dispatchResult(inner, id: id)
            return
        }
        // rpc.result.chunk
        guard let object = try? inner.closedObject(required: ["type", "id", "part", "last", "data"]),
              let id = object["id"]?.stringValue,
              let part = object["part"]?.intValue,
              let last = object["last"]?.boolValue,
              let data = object["data"]?.stringValue else {
            handleSessionError(.badFrame("rpc.result.chunk malformed"))
            return
        }
        let starting = resultChunks[id] == nil && part == 0
        var reassembler = resultChunks[id] ?? PCLinkChunkReassembler()
        do {
            let completed = try reassembler.accept(key: "result:\(id)",
                                                   part: Int(part),
                                                   last: last,
                                                   dataBase64: data)
            resultChunks[id] = reassembler
            guard let completed else {
                if starting { scheduleResultChunkTimeout(id) }
                return
            }
            resultChunks.removeValue(forKey: id)
            guard let json = try? PCLinkJSONParser.parseObject(completed),
                  json["type"]?.stringValue == "rpc.result",
                  json["id"]?.stringValue == id else {
                failPendingCall(id, error: .badFrame("chunked rpc.result mismatch"))
                return
            }
            dispatchResult(json, id: id)
        } catch let error as PCLinkError {
            resultChunks.removeValue(forKey: id)
            failPendingCall(id, error: error)
        } catch {
            resultChunks.removeValue(forKey: id)
            failPendingCall(id, error: .badFrame("chunked rpc.result failed"))
        }
    }

    private func dispatchResult(_ result: PCLinkJSON, id: String) {
        guard let object = result.objectValue else {
            handleSessionError(.badFrame("rpc.result is not an object"))
            return
        }
        guard object["type"]?.stringValue == "rpc.result",
              object["ok"]?.boolValue != nil else {
            handleSessionError(.badFrame("rpc.result header"))
            return
        }
        let ok = object["ok"]!.boolValue!
        if ok {
            guard object["error"] == nil, object["result"] != nil else {
                failPendingCall(id, error: .badFrame("rpc.result ok/result mismatch"))
                return
            }
            guard let pending = pendingCalls.removeValue(forKey: id) else { return }
            pending.continuation?.resume(returning: object["result"]!)
        } else {
            guard object["result"] == nil, let errorValue = object["error"] else {
                failPendingCall(id, error: .badFrame("rpc.result ok/error mismatch"))
                return
            }
            guard let errorObject = try? errorValue.closedObject(required: ["code", "message"],
                                                                optional: ["details"]),
                  let code = errorObject["code"]?.stringValue,
                  let message = errorObject["message"]?.stringValue,
                  errorObject["code"]?.stringValue != nil else {
                failPendingCall(id, error: .badFrame("rpc.result error shape"))
                return
            }
            guard !code.unicodeScalars.contains(where: { $0.value == 0 }) else {
                failPendingCall(id, error: .badFrame("rpc.result error code contains U+0000"))
                return
            }
            do {
                try PCLinkValidation.displayText(message, field: "rpc.result.error.message",
                                                 minimumBytes: 1, maximumBytes: 2048)
            } catch {
                failPendingCall(id, error: .badFrame("rpc.result error message invalid"))
                return
            }
            guard let pending = pendingCalls.removeValue(forKey: id) else { return }
            pending.continuation?.resume(throwing: PCLinkRPCError(code: code, message: message,
                                                                  details: errorObject["details"]))
        }
        _ = object
    }

    private func scheduleResultChunkTimeout(_ id: String) {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(PCLinkLimits.chunkReassemblyTimeout * 1_000_000_000))
            } catch { return }
            await self?.expireResultChunk(id)
        }
    }

    private func expireResultChunk(_ id: String) {
        guard resultChunks.removeValue(forKey: id) != nil else { return }
        failPendingCall(id, error: .badFrame("result chunk sequence timed out"))
    }

    private func scheduleStreamChunkTimeout(_ streamId: String) {
        Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(PCLinkLimits.chunkReassemblyTimeout * 1_000_000_000))
            } catch { return }
            await self?.expireStreamChunk(streamId)
        }
    }

    private func expireStreamChunk(_ streamId: String) {
        guard streamChunks.removeValue(forKey: streamId) != nil else { return }
        guard let muxID = muxForStream(streamId) else { return }
        emitStreamError(muxID: muxID, streamId: streamId,
                        error: PCLinkRPCError(code: "bad_frame", message: "stream chunk sequence timed out"))
    }

    private func failPendingCall(_ id: String, error: PCLinkError) {
        guard let pending = pendingCalls.removeValue(forKey: id) else { return }
        pending.continuation?.resume(throwing: error)
    }

    // MARK: Stream frames

    private func muxForStream(_ streamId: String) -> UUID? {
        for (muxID, mux) in muxes where mux.streams[streamId] != nil {
            return muxID
        }
        return nil
    }

    private func emitStreamError(muxID: UUID, streamId: String, error: PCLinkRPCError) {
        guard var mux = muxes[muxID] else { return }
        mux.streams.removeValue(forKey: streamId)
        muxes[muxID] = mux
        let frame: PCLinkJSON = .object([
            "type": .string("error"),
            "streamId": .string(streamId),
            "error": .object({
                var errorObject: PCLinkJSONObject = [
                    "code": .string(error.code),
                    "message": .string(error.message),
                ]
                if let details = error.details { errorObject["details"] = details }
                return errorObject
            }()),
        ])
        mux.continuation.yield(frame)
    }

    private func handleStreamFrame(_ inner: PCLinkJSON) {
        guard let streamId = inner["streamId"]?.stringValue else {
            handleSessionError(.badFrame("stream frame without streamId"))
            return
        }
        guard let muxID = muxForStream(streamId), var mux = muxes[muxID],
              let stream = mux.streams[streamId] else {
            // Late frames for an ended/unknown stream are discarded.
            return
        }
        let wasCancelled = stream.cancelled
        switch inner["type"]?.stringValue {
        case "rpc.stream.item":
            if wasCancelled { return }
            guard (try? inner.closedObject(required: ["type", "streamId", "value"])) != nil else {
                emitStreamError(muxID: muxID, streamId: streamId, error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.item shape"))
                return
            }
            let value = inner["value"] ?? .null
            let size = (try? PCLinkJSONEncoder.encode(value).count) ?? 0
            if size > PCLinkLimits.maxValueBytes {
                emitStreamError(muxID: muxID, streamId: streamId, error: PCLinkRPCError(code: "frame_too_large", message: "value exceeds 8 MiB"))
                return
            }
            muxes[muxID] = mux
            mux.continuation.yield(.object(["type": .string("item"), "streamId": .string(streamId),
                                            "value": value]))
        case "rpc.stream.chunk":
            if wasCancelled { return }
            guard let object = try? inner.closedObject(required: ["type", "streamId", "part", "last", "data"]),
                  let part = object["part"]?.intValue,
                  let last = object["last"]?.boolValue,
                  let data = object["data"]?.stringValue else {
                emitStreamError(muxID: muxID, streamId: streamId, error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.chunk shape"))
                return
            }
            let starting = streamChunks[streamId] == nil && part == 0
            var reassembler = streamChunks[streamId] ?? PCLinkChunkReassembler()
            do {
                let completed = try reassembler.accept(key: "stream:\(streamId)",
                                                       part: Int(part), last: last,
                                                       dataBase64: data)
                streamChunks[streamId] = reassembler
                guard let completed else {
                    if starting { scheduleStreamChunkTimeout(streamId) }
                    return
                }
                streamChunks.removeValue(forKey: streamId)
                guard let value = try? PCLinkJSONParser.parse(value: completed) else {
                    throw PCLinkError.badFrame("stream chunk is not one JSON value")
                }
                muxes[muxID] = mux
                mux.continuation.yield(.object(["type": .string("item"), "streamId": .string(streamId),
                                                "value": value]))
            } catch let error as PCLinkError {
                streamChunks.removeValue(forKey: streamId)
                emitStreamError(muxID: muxID, streamId: streamId,
                                error: PCLinkRPCError(code: error.code, message: error.message))
            } catch {
                streamChunks.removeValue(forKey: streamId)
                emitStreamError(muxID: muxID, streamId: streamId,
                                error: PCLinkRPCError(code: "bad_frame", message: "stream chunk"))
            }
        case "rpc.stream.end":
            guard (try? inner.closedObject(required: ["type", "streamId"])) != nil else {
                emitStreamError(muxID: muxID, streamId: streamId, error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.end shape"))
                return
            }
            mux.streams.removeValue(forKey: streamId)
            streamChunks.removeValue(forKey: streamId)
            muxes[muxID] = mux
            mux.continuation.yield(.object(["type": .string("end"), "streamId": .string(streamId)]))
        case "rpc.stream.error":
            guard let object = try? inner.closedObject(required: ["type", "streamId", "error"]),
                  let errorObject = try? object["error"]?.closedObject(required: ["code", "message"], optional: ["details"]),
                  let code = errorObject["code"]?.stringValue,
                  let message = errorObject["message"]?.stringValue else {
                emitStreamError(muxID: muxID, streamId: streamId, error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.error shape"))
                return
            }
            guard !code.unicodeScalars.contains(where: { $0.value == 0 }) else {
                emitStreamError(muxID: muxID, streamId: streamId,
                                error: PCLinkRPCError(code: "bad_frame",
                                                      message: "rpc.stream.error code contains U+0000"))
                return
            }
            do {
                try PCLinkValidation.displayText(message, field: "rpc.stream.error.message",
                                                 minimumBytes: 1, maximumBytes: 2048)
            } catch {
                emitStreamError(muxID: muxID, streamId: streamId,
                                error: PCLinkRPCError(code: "bad_frame",
                                                      message: "rpc.stream.error message invalid"))
                return
            }
            mux.streams.removeValue(forKey: streamId)
            streamChunks.removeValue(forKey: streamId)
            muxes[muxID] = mux
            var errorOut: PCLinkJSONObject = ["code": .string(code), "message": .string(message)]
            if let details = errorObject["details"] { errorOut["details"] = details }
            mux.continuation.yield(.object([
                "type": .string("error"),
                "streamId": .string(streamId),
                "error": .object(errorOut),
            ]))
        default:
            break
        }
        _ = stream
    }

    // MARK: RPC (used by RelayDSHTransport)

    func rpcCall(endpoint: String, args: PCLinkJSON) async throws -> PCLinkJSON {
        guard PCLinkValidation.endpoint(endpoint) else {
            throw PCLinkError.badFrame("invalid endpoint")
        }
        if PCLinkEndpoints.isForbiddenRemoteAdmin(endpoint) {
            throw PCLinkRPCError(code: "forbidden",
                                 message: "remote pclink.admin calls are forbidden")
        }
        guard args.objectValue != nil else { throw PCLinkError.badFrame("args must be an object") }
        let argsBytes = (try? PCLinkJSONEncoder.encode(args).count) ?? Int.max
        guard argsBytes <= PCLinkLimits.maxValueBytes else {
            throw PCLinkError.frameTooLarge("args exceed 8 MiB")
        }
        try await loadIdentityAndRecordIfNeeded()
        guard record != nil else { throw PCLinkError.notPaired }
        let retry = PCLinkEndpoints.retryClass(for: endpoint)
        let deadline = Date().addingTimeInterval(configuration.callRetryDeadline)
        var lastSessionError: PCLinkError = .peerOffline
        while true {
            if Task.isCancelled { throw PCLinkError.cancelled }
            let sessionLike: PCLinkSessionLike
            do {
                sessionLike = try await requireSession()
            } catch let error as PCLinkError {
                throw error
            }
            let id = nextID()
            do {
                return try await callOnce(session: sessionLike.session, endpoint: endpoint,
                                          args: args, id: id)
            } catch let lost as PCLinkSessionLost {
                lastSessionError = lost.reason
                switch retry {
                case .read, .idempotent:
                    if Date() >= deadline { throw lastSessionError }
                    try await Task.sleep(nanoseconds: 20_000_000)
                    continue
                case .unsafe:
                    throw PCLinkError.unknownOutcome(endpoint: endpoint)
                }
            } catch let offline as PCLinkError where offline == .peerOffline {
                // The relay explicitly said the target was not connected, so
                // the frame was not delivered; unsafe may retry only via the
                // user, read/idempotent retry after reconnect.
                switch retry {
                case .read, .idempotent:
                    if Date() >= deadline { throw offline }
                    try await Task.sleep(nanoseconds: 20_000_000)
                    continue
                case .unsafe:
                    throw offline
                }
            }
        }
    }

    private func callOnce(session: PCLinkE2ESession, endpoint: String, args: PCLinkJSON,
                          id: String) async throws -> PCLinkJSON {
        let inner: PCLinkJSON = .object([
            "type": .string("rpc.call"),
            "id": .string(id),
            "endpoint": .string(endpoint),
            "args": args,
        ])
        let pending = PendingCall(endpoint: endpoint, retry: PCLinkEndpoints.retryClass(for: endpoint))
        pending.sessionID = session.sid
        pendingCalls[id] = pending
        return try await withCheckedThrowingContinuation { continuation in
            pending.continuation = continuation
            Task { [weak self] in
                do {
                    try await self?.sendInner(inner, session: session)
                } catch {
                    await self?.pendingSendFailed(id: id, error: error)
                }
            }
        }
    }

    private func pendingSendFailed(id: String, error: Error) {
        guard let pending = pendingCalls.removeValue(forKey: id) else { return }
        let mapped: PCLinkError
        switch error {
        case let error as PCLinkError: mapped = error
        default: mapped = .peerOffline
        }
        switch mapped {
        case .authFailed, .badFrame, .frameTooLarge, .forbidden, .versionUnsupported:
            pending.continuation?.resume(throwing: mapped)
        default:
            // The frame may or may not have reached the PC. The retry class
            // decides whether this becomes a retry or unknown_outcome.
            pending.continuation?.resume(throwing: PCLinkSessionLost(reason: mapped))
        }
    }

    private func loadIdentityAndRecordIfNeeded() async throws {
        if identity == nil || (record == nil && pairingStore.hasStoredFile()) {
            try await loadIdentityAndRecord()
        }
    }

    // MARK: Mux

    func openMux() async throws -> PCLinkMuxEndpoint {
        try await loadIdentityAndRecordIfNeeded()
        guard record != nil else { throw PCLinkError.notPaired }
        _ = try await requireSession()
        let (stream, continuation) = AsyncStream.makeStream(of: PCLinkJSON.self,
                                                            bufferingPolicy: .unbounded)
        let id = UUID()
        muxes[id] = MuxState(continuation: continuation)
        return PCLinkMuxEndpoint(id: id, frames: stream)
    }

    func muxSend(id: UUID, frame: PCLinkJSON) async throws {
        guard var mux = muxes[id] else { throw PCLinkError.pairingCancelled }
        guard let type = frame["type"]?.stringValue else {
            throw PCLinkError.badFrame("mux frame has no type")
        }
        switch type {
        case "open":
            guard let object = try? frame.closedObject(required: ["type", "streamId", "endpoint", "payload"]),
                  let streamId = object["streamId"]?.stringValue,
                  PCLinkValidation.correlationId(streamId),
                  let endpoint = object["endpoint"]?.stringValue,
                  PCLinkValidation.endpoint(endpoint),
                  let payload = object["payload"],
                  let payloadObject = try? payload.closedObject(required: ["args"]),
                  payloadObject["args"]?.objectValue != nil else {
                throw PCLinkError.badFrame("mux open shape")
            }
            let payloadBytes = (try? PCLinkJSONEncoder.encode(payload).count) ?? Int.max
            guard payloadBytes <= PCLinkLimits.maxValueBytes else {
                throw PCLinkError.frameTooLarge("stream payload exceeds 8 MiB")
            }
            guard mux.streams[streamId] == nil, !mux.usedStreamIDs.contains(streamId) else {
                throw PCLinkError.badFrame("duplicate or reused streamId")
            }
            mux.usedStreamIDs.insert(streamId)
            if PCLinkEndpoints.isForbiddenRemoteAdmin(endpoint) {
                mux.continuation.yield(.object([
                    "type": .string("error"),
                    "streamId": .string(streamId),
                    "error": .object([
                        "code": .string("forbidden"),
                        "message": .string("remote pclink.admin calls are forbidden"),
                    ]),
                ]))
                muxes[id] = mux
                return
            }
            let retry = PCLinkEndpoints.retryClass(for: endpoint)
            let inner: PCLinkJSON = .object([
                "type": .string("rpc.stream.open"),
                "streamId": .string(streamId),
                "endpoint": .string(endpoint),
                "payload": payload,
            ])
            let deadline = Date().addingTimeInterval(configuration.callRetryDeadline)
            while true {
                let sessionLike = try await requireSession()
                do {
                    try await sendInner(inner, session: sessionLike.session)
                    mux.streams[streamId] = StreamState(muxID: id, endpoint: endpoint,
                                                        retry: retry, payload: payload,
                                                        chunkKey: "stream:\(streamId)",
                                                        sessionID: sessionLike.session.sid)
                    muxes[id] = mux
                    return
                } catch let lost as PCLinkSessionLost {
                    switch retry {
                    case .read, .idempotent:
                        if Date() >= deadline { throw lost.reason }
                        try await Task.sleep(nanoseconds: 20_000_000)
                        continue
                    case .unsafe:
                        mux.continuation.yield(.object([
                            "type": .string("error"),
                            "streamId": .string(streamId),
                            "error": .object([
                                "code": .string("unknown_outcome"),
                                "message": .string("the stream may have opened but no definitive reply arrived"),
                            ]),
                        ]))
                        muxes[id] = mux
                        return
                    }
                } catch let error as PCLinkError {
                    throw error
                }
            }
        case "cancel":
            guard let object = try? frame.closedObject(required: ["type", "streamId"]),
                  let streamId = object["streamId"]?.stringValue else {
                throw PCLinkError.badFrame("mux cancel shape")
            }
            guard var stream = mux.streams[streamId] else { return }
            if stream.cancelled { return }
            stream.cancelled = true
            mux.streams[streamId] = stream
            muxes[id] = mux
            let inner: PCLinkJSON = .object(["type": .string("rpc.stream.cancel"),
                                             "streamId": .string(streamId)])
            if let session {
                try? await sendInner(inner, session: session)
            }
        default:
            throw PCLinkError.badFrame("unsupported mux frame type")
        }
    }

    func closeMux(id: UUID) async {
        guard let mux = muxes.removeValue(forKey: id) else { return }
        for (streamId, _) in mux.streams {
            streamChunks.removeValue(forKey: "stream:\(streamId)")
            let inner: PCLinkJSON = .object(["type": .string("rpc.stream.cancel"),
                                             "streamId": .string(streamId)])
            if let session {
                try? await sendInner(inner, session: session)
            }
        }
        mux.continuation.finish()
    }

    // MARK: Session teardown

    private func sessionTeardown(reason: PCLinkError) {
        if let session {
            session.markClosed()
        }
        if let rekeySession {
            rekeySession.markClosed()
        }
        session = nil
        rekeySession = nil
        if let handshake {
            self.handshake = nil
            handshake.timeoutTask?.cancel()
            handshake.session.markClosed()
            handshake.continuation.resume(throwing: reason)
        }
        let calls = pendingCalls
        pendingCalls.removeAll()
        for pending in calls.values {
            pending.continuation?.resume(throwing: PCLinkSessionLost(reason: reason))
        }
        resultChunks.removeAll()
        let muxValues = muxes
        muxes.removeAll()
        for mux in muxValues.values {
            mux.continuation.finish()
        }
        streamChunks.removeAll()
        if let lastError { self.lastError = lastError }
    }

    private func signalDisconnect() {
        disconnected = true
        if let continuation = disconnectContinuation {
            disconnectContinuation = nil
            continuation.resume()
        }
    }

    private func teardownConnection(error: PCLinkError?) async {
        relayConsumer?.cancel()
        relayConsumer = nil
        if let relay {
            await relay.close()
        }
        self.relay = nil
        if let error { lastError = error }
        sessionTeardown(reason: error ?? .sessionExpired("connection closed"))
        if case .connecting = state {
            setState(.offline(.network))
        }
    }

    // MARK: Pairing

    public func beginPairing(qrURI: String) async throws -> PCLinkPairingPrompt {
        try await beginPairing(offer: try PCLinkQRCode.parse(qrURI))
    }

    public func beginManualPairing(code: String, relayOrigin: String,
                                   pcName: String? = nil) async throws -> PCLinkPairingPrompt {
        var offer = try PCLinkManualCode.parse(code, relayOrigin: relayOrigin)
        offer.pcName = pcName
        return try await beginPairing(offer: offer)
    }

    public func beginPairing(offer: PCLinkPairingOffer) async throws -> PCLinkPairingPrompt {
        if pairingContext != nil { throw PCLinkError.unavailable("pairing already in progress") }
        if let record, record.connectionMode == .relay { throw PCLinkError.alreadyPaired }
        try await loadIdentityAndRecordIfNeeded()
        if identity == nil {
            let generated = try PCLinkIdentity.generate()
            try identityStore.saveSeed(generated.seed)
            identity = generated
        }
        guard let identity else { throw PCLinkError.noIdentity }
        try PCLinkValidation.origin(offer.relayOrigin)
        if let pinned = offer.pcMachineId, !PCLinkValidation.machineId(pinned) {
            throw PCLinkError.badFrame("QR machineId")
        }
        setState(.pairing(.joining))
        let relay = PCLinkRelayClient(
            configuration: .init(origin: offer.relayOrigin, identity: identity, role: "phone",
                                 frameLimit: PCLinkLimits.maxRelayFrameBytes,
                                 heartbeatIntervalRange: configuration.heartbeatIntervalRange,
                                 heartbeatEnabled: configuration.heartbeatEnabled),
            factory: configuration.websocketFactory)
        let context = PairingContext(offer: offer, relay: relay)
        context.expiresAt = Date().addingTimeInterval(configuration.pairingTimeout)
        pairingContext = context
        context.consumer = Task { [weak self] in
            for await event in relay.events {
                await self?.handlePairingEvent(event, contextID: context.id)
            }
        }
        do {
            try await relay.connect()
            try await relay.send(.object([
                "v": .int(1), "type": .string("relay.pair.join"),
                "rendezvous": .string(offer.rendezvous),
            ]))
            setState(.pairing(.waitingForPC))
            armPairingTimeout(context)
            let hello = try await waitForPairHello(context)
            if let failure = context.failure { throw failure }
            let prompt = PCLinkPairingPrompt(
                id: context.id,
                mode: offer.mode,
                relayOrigin: offer.relayOrigin,
                pcName: hello.name,
                pcMachineId: hello.machineId,
                ownFingerprint: identity.fingerprint,
                warningText: PCLinkPairingPrompt.fullOwnerWarning,
                expiresAt: Date().addingTimeInterval(configuration.pairingPromptTimeout))
            context.prompt = prompt
            context.expiresAt = prompt.expiresAt
            armPairingTimeout(context)
            setState(.pairing(.awaitingUser))
            return prompt
        } catch {
            let mapped = (error as? PCLinkError) ?? .unavailable("pairing failed: \(error)")
            await closePairingContext(context, error: mapped)
            throw mapped
        }
    }

    private func waitForPairHello(_ context: PairingContext) async throws -> PCLinkPairHello {
        try await withCheckedThrowingContinuation { continuation in
            context.helloWaiter = continuation
        }
    }

    public func confirmPairing(_ id: UUID) async throws -> PCLinkPairingResult {
        guard let context = pairingContext, context.id == id else {
            throw PCLinkError.unavailable("no matching pairing")
        }
        if let failure = context.failure { throw failure }
        guard let hello = context.hello, let prompt = context.prompt else {
            throw PCLinkError.badFrame("pair.hello is not available")
        }
        guard let identity else { throw PCLinkError.noIdentity }
        guard context.authNonce == nil else { throw PCLinkError.unavailable("pairing already confirmed") }
        setState(.pairing(.authenticating))
        context.timeoutTask?.cancel()
        let nonce = try PCLinkRandom.bytes(32)
        let auth = try PCLinkPairingMessage.makeAuth(
            machineId: identity.machineId,
            publicKey: identity.publicKey,
            name: configuration.phoneName,
            relayOrigin: context.offer.relayOrigin,
            nonce: nonce,
            peerNonce: hello.nonce,
            pairKey: context.offer.pairKey)
        context.authNonce = nonce
        do {
            try await context.relay.send(.object([
                "v": .int(1), "type": .string("relay.pair.message"),
                "rendezvous": .string(context.offer.rendezvous),
                "payload": auth.raw,
            ]))
            setState(.pairing(.awaitingConfirmation))
            let confirm = try await waitForPairConfirm(context)
            guard confirm.nonce == hello.nonce,
                  confirm.peerNonce == nonce else {
                throw PCLinkError.authFailed("pair.confirm nonces do not match")
            }
            guard let helloCanonical = try? PCLinkPairingMessage.hello(hello).canonicalWithoutMAC(),
                  let authCanonical = try? PCLinkPairingMessage.auth(auth).canonicalWithoutMAC() else {
                throw PCLinkError.badFrame("pairing transcript")
            }
            let expectedTranscript = try PCLinkCrypto.pairTranscriptHash(hello: helloCanonical,
                                                                         auth: authCanonical)
            guard PCLinkCrypto.constantTimeEquals(expectedTranscript, confirm.transcriptHash) else {
                throw PCLinkError.authFailed("pair.confirm transcript hash mismatch")
            }
            try PCLinkPairingMessage.confirm(confirm).verifyMAC(pairKey: context.offer.pairKey)
            let record = PCLinkPairingRecord(
                peerMachineId: hello.machineId,
                peerPublicKey: hello.publicKey,
                peerName: hello.name,
                pairedAt: PCLinkValidation.nowTimestamp(),
                relayOrigin: context.offer.relayOrigin,
                connectionMode: .relay)
            do {
                try pairingStore.save(record, phoneMachineId: identity.machineId)
            } catch {
                try? await context.relay.send(.object([
                    "v": .int(1), "type": .string("relay.pair.close"),
                    "rendezvous": .string(context.offer.rendezvous),
                    "reason": .string("storage"),
                ]))
                throw PCLinkError.storage("cannot write the pairing record: \(error)")
            }
            let final = try PCLinkPairingMessage.makeFinal(
                authNonce: nonce, helloNonce: hello.nonce,
                transcriptHash: expectedTranscript, pairKey: context.offer.pairKey)
            try await context.relay.send(.object([
                "v": .int(1), "type": .string("relay.pair.message"),
                "rendezvous": .string(context.offer.rendezvous),
                "payload": final.raw,
            ]))
            try? await context.relay.send(.object([
                "v": .int(1), "type": .string("relay.pair.close"),
                "rendezvous": .string(context.offer.rendezvous),
                "reason": .string("paired"),
            ]))
            context.completed = true
            await closePairingContext(context, error: nil)
            self.record = record
            staleRecord = nil
            setState(.pairing(.completed))
            pcUnpairedPrompt = nil
            userWantsConnection = true
            stopped = false
            startConnectionLoopIfNeeded()
            return PCLinkPairingResult(record: record, prompt: prompt)
        } catch {
            let mapped = (error as? PCLinkError) ?? .authFailed("pairing confirmation failed")
            await closePairingContext(context, error: mapped)
            throw mapped
        }
    }

    private func waitForPairConfirm(_ context: PairingContext) async throws -> PCLinkPairConfirm {
        let timeout = configuration.pairingPromptTimeout
        return try await withCheckedThrowingContinuation { continuation in
            context.confirmWaiter = continuation
            context.timeoutTask?.cancel()
            context.timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                } catch { return }
                await self?.expirePairing(context.id, reason: "timeout")
            }
        }
    }

    private func armPairingTimeout(_ context: PairingContext) {
        context.timeoutTask?.cancel()
        let interval = max(context.expiresAt.timeIntervalSinceNow, 0.05)
        context.timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch { return }
            await self?.expirePairing(context.id, reason: "timeout")
        }
    }

    private func expirePairing(_ id: UUID, reason: String) async {
        guard let context = pairingContext, context.id == id, !context.completed else { return }
        let error: PCLinkError = reason == "timeout" ? .pairingTimedOut : .pairingCancelled
        try? await context.relay.send(.object([
            "v": .int(1), "type": .string("relay.pair.close"),
            "rendezvous": .string(context.offer.rendezvous),
            "reason": .string(reason),
        ]))
        await closePairingContext(context, error: error)
    }

    public func cancelPairing() async {
        guard let context = pairingContext else { return }
        try? await context.relay.send(.object([
            "v": .int(1), "type": .string("relay.pair.close"),
            "rendezvous": .string(context.offer.rendezvous),
            "reason": .string("cancelled"),
        ]))
        await closePairingContext(context, error: .pairingCancelled)
    }

    private func handlePairingEvent(_ event: PCLinkRelayEvent, contextID: UUID) async {
        guard let context = pairingContext, context.id == contextID else { return }
        switch event {
        case .error(let error):
            await failPairing(context, error: error)
        case .closed(_, _, let error):
            if !context.completed {
                await failPairing(context, error: error ?? .peerOffline)
            }
        case .offline:
            break
        case .ready:
            break
        case .frame(let frame):
            guard let type = frame["type"]?.stringValue else { return }
            switch type {
            case "relay.pair.joined":
                guard let object = try? frame.closedObject(required: ["v", "type", "rendezvous", "role", "peerMachineId"]),
                      object["v"]?.intValue == 1,
                      object["rendezvous"]?.stringValue == context.offer.rendezvous,
                      object["role"]?.stringValue == "phone",
                      let peer = object["peerMachineId"]?.stringValue,
                      PCLinkValidation.machineId(peer) else {
                    await failPairing(context, error: .badFrame("relay.pair.joined shape"))
                    return
                }
                if let pinned = context.offer.pcMachineId, pinned != peer {
                    await failPairing(context, error: .authFailed("the joined PC does not match the QR pin"))
                    return
                }
                context.joined = true
            case "relay.pair.message":
                guard let object = try? frame.closedObject(required: ["v", "type", "rendezvous", "payload"]),
                      object["v"]?.intValue == 1,
                      object["rendezvous"]?.stringValue == context.offer.rendezvous,
                      let payload = object["payload"] else {
                    await failPairing(context, error: .badFrame("relay.pair.message shape"))
                    return
                }
                if context.hello == nil {
                    guard context.joined else {
                        await failPairing(context, error: .badFrame("pair.hello before relay.pair.joined"))
                        return
                    }
                    do {
                        let message = try PCLinkPairingMessage.decode(payload)
                        guard case .hello(let hello) = message else {
                            throw PCLinkError.badFrame("expected pair.hello")
                        }
                        try context.offer.verifyHello(hello)
                        context.hello = hello
                        if let waiter = context.helloWaiter {
                            context.helloWaiter = nil
                            waiter.resume(returning: hello)
                        }
                    } catch let error as PCLinkError {
                        await failPairing(context, error: error)
                    } catch {
                        await failPairing(context, error: .authFailed("pair.hello verification failed"))
                    }
                } else if context.authNonce != nil {
                    do {
                        let message = try PCLinkPairingMessage.decode(payload)
                        guard case .confirm(let confirm) = message else {
                            throw PCLinkError.badFrame("expected pair.confirm")
                        }
                        if let waiter = context.confirmWaiter {
                            context.confirmWaiter = nil
                            waiter.resume(returning: confirm)
                        }
                    } catch let error as PCLinkError {
                        await failPairing(context, error: error)
                    } catch {
                        await failPairing(context, error: .authFailed("pair.confirm decode failed"))
                    }
                } else {
                    await failPairing(context, error: .badFrame("unexpected pairing message"))
                }
            case "relay.pair.close":
                guard let object = try? frame.closedObject(required: ["v", "type", "rendezvous", "reason"]),
                      object["rendezvous"]?.stringValue == context.offer.rendezvous,
                      let reason = object["reason"]?.stringValue else {
                    return
                }
                if context.completed, reason == "paired" { return }
                let mapped: PCLinkError
                switch reason {
                case "paired": mapped = .unavailable("pairing completed without pair.confirm")
                case "cancelled": mapped = .pairingCancelled
                case "rejected": mapped = .pairingRejected
                case "peer_offline": mapped = .peerOffline
                case "rendezvous_expired": mapped = .rendezvousExpired
                case "rendezvous_exhausted": mapped = .rendezvousExhausted
                case "auth_failed": mapped = .authFailed("the PC rejected the pairing authentication")
                case "storage": mapped = .storage("the PC could not store the pairing")
                case "timeout": mapped = .pairingTimedOut
                default: mapped = .badFrame("unknown pairing close reason")
                }
                await failPairing(context, error: mapped)
            default:
                break
            }
        }
    }

    private func failPairing(_ context: PairingContext, error: PCLinkError) async {
        guard !context.completed else { return }
        context.failure = error
        if let waiter = context.helloWaiter {
            context.helloWaiter = nil
            waiter.resume(throwing: error)
        }
        if let waiter = context.confirmWaiter {
            context.confirmWaiter = nil
            waiter.resume(throwing: error)
        }
        context.timeoutTask?.cancel()
        lastError = error
        await closePairingContext(context, error: error)
    }

    private func closePairingContext(_ context: PairingContext, error: PCLinkError?) async {
        context.consumer?.cancel()
        context.timeoutTask?.cancel()
        await context.relay.close()
        if pairingContext?.id == context.id {
            pairingContext = nil
        }
        if error != nil, !context.completed {
            setState(.unpaired(staleRecord == nil ? .noRecord : .staleRecord))
        } else if record == nil, !context.completed {
            setState(.unpaired(staleRecord == nil ? .noRecord : .staleRecord))
        } else if context.completed {
            // confirmPairing sets the next state.
        }
    }

    // MARK: Unpair

    /// Phone-initiated unpair (§4.6): best-effort authenticated `session.close`
    /// with `code:"unpaired"`, discard keys, remove the local record. A local
    /// removal while offline cannot notify the PC, so the UI must say to unpair
    /// on the PC as well.
    public func unpair() async throws {
        guard record != nil else { throw PCLinkError.notPaired }
        if let session, session.phase == .established {
            if let close = try? session.closeFrame(code: "unpaired") {
                try? await relay?.send(close)
            }
        }
        connectionTask?.cancel()
        connectionTask = nil
        await teardownConnection(error: nil)
        try pairingStore.delete()
        self.record = nil
        pcUnpairedPrompt = nil
        versionWarning = nil
        setState(.unpaired(.noRecord))
    }

    /// The user confirmed the PC's signed/authenticated `unpaired` notice.
    /// Only this explicit action removes the local record (§5.5).
    public func acknowledgePCUnpair() async throws {
        guard pcUnpairedPrompt != nil else { return }
        connectionTask?.cancel()
        connectionTask = nil
        try pairingStore.delete()
        record = nil
        pcUnpairedPrompt = nil
        versionWarning = nil
        setState(.unpaired(.noRecord))
        await teardownConnection(error: nil)
    }

    /// The user removes a stale/one-sided record without a live PC.
    public func removeLocalRecord() async throws {
        try pairingStore.delete()
        record = nil
        staleRecord = nil
        pcUnpairedPrompt = nil
        versionWarning = nil
        setState(.unpaired(.noRecord))
    }

    public func clearLastError() {
        lastError = nil
    }
}

// MARK: - Helpers

private extension PCLinkJSONParser {
    static func parse(value data: Data) throws -> PCLinkJSON {
        try parse(data)
    }
}
