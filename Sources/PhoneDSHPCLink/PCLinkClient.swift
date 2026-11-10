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
    /// Verified `peer.hello` display metadata from the PC, including the exact
    /// DSH version inside and outside the tested range (CCR-2). Nil until the
    /// first handshake or after the record is removed.
    public var peerDshVersion: String?
    public var peerAppName: String?
    public var peerAppVersion: String?
    public var lastNotice: PCLinkNotice?
    public var lastError: PCLinkError?
    public var pairingPrompt: PCLinkPairingPrompt?
    public var pcUnpairedPrompt: PCLinkPCUnpairedPrompt?

    public init(state: PCLinkClientState = .offline(.notStarted),
                machineId: String? = nil,
                fingerprint: String? = nil,
                record: PCLinkPairingRecord? = nil,
                versionWarning: PCLinkVersionWarning? = nil,
                peerDshVersion: String? = nil,
                peerAppName: String? = nil,
                peerAppVersion: String? = nil,
                lastNotice: PCLinkNotice? = nil,
                lastError: PCLinkError? = nil,
                pairingPrompt: PCLinkPairingPrompt? = nil,
                pcUnpairedPrompt: PCLinkPCUnpairedPrompt? = nil) {
        self.state = state
        self.machineId = machineId
        self.fingerprint = fingerprint
        self.record = record
        self.versionWarning = versionWarning
        self.peerDshVersion = peerDshVersion
        self.peerAppName = peerAppName
        self.peerAppVersion = peerAppVersion
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

/// Client-driven pairing progress. `.completed` is emitted only after the PC's
/// authenticated `pair.confirm` and the durable local record write, so the
/// pairing page can leave the waiting state without polling (§4.4/4.6).
public enum PCLinkPairingUpdate: Equatable, Sendable {
    case awaitingApproval(PCLinkPairingPrompt)
    case completed(PCLinkPairingRecord)
    case failed(PCLinkError)
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
    /// §3.8 local sender bucket (must stay at/below the relay pair defaults).
    public var sendRateBytesPerSecond: Double
    public var sendBurstBytes: Double
    /// §6.2 receiver reassembly inactivity budget; injectable for tests.
    public var chunkReassemblyTimeout: TimeInterval

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
                heartbeatEnabled: Bool = true,
                sendRateBytesPerSecond: Double = PCLinkLimits.sendRateBytesPerSecond,
                sendBurstBytes: Double = PCLinkLimits.sendBurstBytes,
                chunkReassemblyTimeout: TimeInterval = PCLinkLimits.chunkReassemblyTimeout) {
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
        self.sendRateBytesPerSecond = sendRateBytesPerSecond
        self.sendBurstBytes = sendBurstBytes
        self.chunkReassemblyTimeout = chunkReassemblyTimeout
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
        /// Local (`events`, `follow`, ...) → per-session wire id.
        var streams: [String: StreamState] = [:]
        /// Wire id → local id. Routing keys on (sid, wire id).
        var wireToLocal: [String: String] = [:]
        var usedStreamIDs: Set<String> = []
    }

    private struct StreamState {
        var muxID: UUID
        var localStreamID: String
        var wireStreamID: String
        var endpoint: String
        var retry: PCLinkRetryClass
        var payload: PCLinkJSON
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
    private var peerDshVersion: String?
    private var peerAppName: String?
    private var peerAppVersion: String?
    private var lastNotice: PCLinkNotice?
    private var lastError: PCLinkError?
    private var pcUnpairedPrompt: PCLinkPCUnpairedPrompt?

    private var stateContinuations: [UUID: AsyncStream<PCLinkClientState>.Continuation] = [:]
    private var noticeContinuations: [UUID: AsyncStream<PCLinkNotice>.Continuation] = [:]
    private var pairingContinuations: [UUID: AsyncStream<PCLinkPairingUpdate>.Continuation] = [:]

    private var connectionTask: Task<Void, Never>?
    private var connectionGeneration = 0
    private var stopTask: Task<Void, Never>?
    private var userWantsConnection = false
    private var stopped = false
    private var attempt = 0
    private var onlineSince: Date?
    private var terminalError: PCLinkError?
    /// A relay `rate_limited` delay that supersedes the normal backoff on the
    /// next reconnect (§9.1). Cleared when consumed.
    private var retryAfterDelay: TimeInterval?

    // One E2E writer. Sealing (seq assignment + AEAD) and enqueue happen with
    // no suspension in between; the writer is the only caller of relay.send
    // for sealed frames, so wire order equals seq order (§5.4).
    private struct Outbound {
        let frame: PCLinkJSON
        let session: PCLinkE2ESession
        let continuation: CheckedContinuation<Void, Error>
    }
    private var outbound: [Outbound] = []
    private var outboundSignal: AsyncStream<Void>.Continuation?
    private var outboundWriter: Task<Void, Never>?
    /// §3.8 sender bucket. The outbound writer is its only caller, so the
    /// bucket cannot let two sealed frames overlap; a queued frame waits.
    private var sendPacer: PCLinkOutboundPacer

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
    private var resultChunkTimeouts: [String: Task<Void, Never>] = [:]
    private var muxes: [UUID: MuxState] = [:]
    private var streamChunks: [String: PCLinkChunkReassembler] = [:]
    private var streamChunkTimeouts: [String: Task<Void, Never>] = [:]

    private var pairingContext: PairingContext?
    private var nextCorrelation = 0

    public init(identityStore: any PCLinkIdentityStore = PCLinkKeychainIdentityStore(),
                pairingStore: any PCLinkPairingStore = PCLinkFilePairingStore(),
                configuration: PCLinkClientConfiguration = PCLinkClientConfiguration()) {
        self.identityStore = identityStore
        self.pairingStore = pairingStore
        self.configuration = configuration
        self.sendPacer = PCLinkOutboundPacer(
            rateBytesPerSecond: configuration.sendRateBytesPerSecond,
            burstBytes: configuration.sendBurstBytes)
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
                           peerDshVersion: peerDshVersion,
                           peerAppName: peerAppName,
                           peerAppVersion: peerAppVersion,
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

    /// Pairing progress for the page's waiting state. The terminal `.completed`
    /// carries the durable record; `.failed` is the same error the call throws.
    public func pairingUpdates() -> AsyncStream<PCLinkPairingUpdate> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let id = UUID()
            pairingContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removePairingContinuation(id) }
            }
        }
    }

    private func emitPairingUpdate(_ update: PCLinkPairingUpdate) {
        for continuation in pairingContinuations.values {
            continuation.yield(update)
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

    private func removePairingContinuation(_ id: UUID) {
        pairingContinuations[id] = nil
    }

    // MARK: Start / stop

    public func start() async throws {
        // A stop that is still draining the old connection owns the lifecycle;
        // never start a second loop beside it.
        if let stopTask {
            await stopTask.value
        }
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

    /// On foreground return: replace a possibly suspended relay socket with a
    /// fresh connection (the old connection loop re-handshakes and stream
    /// consumers resynchronize). Terminal pairing/protocol states are left
    /// alone; `auth_failed` must not auto-retry (§9.1).
    public func foregroundResumed() async {
        guard userWantsConnection, record != nil else { return }
        switch effectiveState() {
        case .online, .versionWarning:
            lastError = nil
            await teardownConnection(error: nil)
            signalDisconnect()
            setState(.offline(.network))
            startConnectionLoopIfNeeded()
        case .offline(.authenticationFailed), .offline(.versionUnsupported),
             .offline(.protocolError), .offline(.unpairedPrompt):
            return
        default:
            try? await start()
        }
    }

    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let stop = Task { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        stopTask = stop
        await stop.value
    }

    /// Stop waits for the old connection loop: wake a loop parked in
    /// `waitForDisconnect`, close the relay, then await the task. `start()` is
    /// idempotent and waits for this drain before creating a new loop.
    private func performStop() async {
        userWantsConnection = false
        stopped = true
        connectionGeneration += 1
        let oldTask = connectionTask
        connectionTask = nil
        oldTask?.cancel()
        // Wake `runOneConnection` before waiting; cancelling a task alone does
        // not resume its checked continuation.
        signalDisconnect()
        await teardownConnection(error: nil)
        if let oldTask {
            await oldTask.value
        }
        setState(record == nil ? .unpaired(staleRecord == nil ? .noRecord : .staleRecord)
                               : .offline(.notStarted))
        stopTask = nil
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
        connectionGeneration += 1
        let generation = connectionGeneration
        connectionTask = Task { await self.connectionLoop(generation: generation) }
    }

    private func connectionLoop(generation: Int) async {
        defer {
            if connectionGeneration == generation { connectionTask = nil }
        }
        while !Task.isCancelled, userWantsConnection, connectionGeneration == generation {
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
            guard !Task.isCancelled, userWantsConnection,
                  connectionGeneration == generation else { return }
            attempt += 1
            let backoff = configuration.reconnectPolicy.delay(attempt: attempt)
            let delay = max(backoff, retryAfterDelay ?? 0)
            retryAfterDelay = nil
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
        applyPeerHello(hello)
        setState(versionWarning == nil ? .online : .versionWarning(versionWarning!))
        resumeSessionWaiters()
        if session.needsRekey {
            startRekeyIfNeeded()
        }
    }

    /// Store the verified display metadata from `peer.hello` (CCR-2).
    private func applyPeerHello(_ hello: PCLinkPeerHello) {
        peerDshVersion = hello.dshVersionText
        peerAppName = hello.appName
        peerAppVersion = hello.appVersion
    }

    private func clearPeerHello() {
        peerDshVersion = nil
        peerAppName = nil
        peerAppVersion = nil
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
        failOutbound(.sessionExpired("rekey moved the session"))
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
            cancelAllChunkTimeouts()
            resultChunks.removeAll()
            streamChunks.removeAll()
        }
        session = replacement
        rekeySession = nil
        versionWarning = hello.versionWarning
            ? PCLinkVersionWarning(dshVersion: hello.dshVersionText)
            : nil
        applyPeerHello(hello)
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
        guard relay != nil else { throw PCLinkError.peerOffline }
        guard let active = session ?? self.session, active.phase == .established else {
            throw PCLinkError.sessionExpired("no established session")
        }
        let frame: PCLinkJSON
        do {
            // Seal (seq allocation + AEAD) and enqueue in one actor step; no
            // suspension may let another sender enqueue a later seq first.
            frame = try active.seal(inner)
        } catch let error as PCLinkError {
            if case .sessionExpired = error {
                sessionTeardown(reason: error)
                signalDisconnect()
            }
            throw error
        }
        try await enqueueSealed(frame, session: active)
    }

    /// Enqueue a sealed frame. Used by `sendInner` (established session) and
    /// by the `version_unsupported` close, which is sent while the session is
    /// still in `.awaitingHello`.
    private func enqueueSealed(_ frame: PCLinkJSON, session: PCLinkE2ESession) async throws {
        guard relay != nil else { throw PCLinkError.peerOffline }
        startOutboundWriterIfNeeded()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            outbound.append(Outbound(frame: frame, session: session, continuation: continuation))
            outboundSignal?.yield()
        }
    }

    private func startOutboundWriterIfNeeded() {
        guard outboundWriter == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        outboundSignal = continuation
        outboundWriter = Task { [weak self] in
            for await _ in stream {
                await self?.drainOutbound()
            }
        }
    }

    private func drainOutbound() async {
        while !Task.isCancelled, !outbound.isEmpty {
            let item = outbound.removeFirst()
            guard let relay else {
                item.continuation.resume(throwing: PCLinkError.peerOffline)
                continue
            }
            // §3.8: wait for the local per-peer bucket before writing. The
            // sleep happens inside this single writer, so no later seq can
            // overtake an older one.
            let bytes = (try? PCLinkJSONEncoder.encode(item.frame).count) ?? 0
            let delay = sendPacer.delayBeforeSending(bytes: bytes, at: Date())
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    item.continuation.resume(throwing: PCLinkError.cancelled)
                    return
                }
            }
            sendPacer.consume(bytes: bytes, at: Date())
            do {
                try await relay.send(item.frame)
                item.continuation.resume()
                if item.session.needsRekey { startRekeyIfNeeded() }
            } catch let error as PCLinkError {
                item.continuation.resume(throwing: error)
            } catch {
                item.continuation.resume(throwing: PCLinkError.peerOffline)
            }
        }
    }

    private func failOutbound(_ error: PCLinkError) {
        let queued = outbound
        outbound.removeAll()
        for item in queued {
            item.continuation.resume(throwing: error)
        }
        outboundSignal?.finish()
        outboundSignal = nil
        outboundWriter?.cancel()
        outboundWriter = nil
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
        case .error(let error, let context):
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
            case .rateLimited(let retryAfterMs):
                // §3.8 (pclink-v1.5): the relay error is uncorrelated, so a
                // dropped frame means this E2E session's seq may already be
                // broken. Stop the writer, best-effort tell the PC with a
                // terminal close (one frame, bypassing the now-empty local
                // bucket), then wait retryAfterMs and re-handshake. In-flight
                // calls follow §7 by retry class.
                retryAfterDelay = retryAfterMs.map { Double($0) / 1000 }
                failOutbound(error)
                if let session, session.phase == .established,
                   let close = try? session.closeFrame(code: "rate_limited") {
                    try? await relay?.send(close)
                }
                failPendingForRelayDrop(sid: context?.sid, id: context?.id,
                                        definiteID: context?.id)
                sessionTeardown(reason: error)
                setState(.offline(.network))
                signalDisconnect()
                Task { [weak self] in await self?.relay?.close() }
            default:
                break
            }
        case .closed(_, _, let error):
            if let error { lastError = error }
            sessionTeardown(reason: error ?? lastError ?? .sessionExpired("relay connection closed"))
            signalDisconnect()
        }
    }

    /// A relay-level drop (`relay.offline`/`rate_limited`) can only identify
    /// the exact undelivered frame when it echoes `id`; the E2E outer frame has
    /// no `id`, so anything already sent on that sid is an ambiguous unsafe
    /// outcome (§7). A matching `id` is a definitively undelivered call.
    private func failPendingForRelayDrop(sid: String?, id: String?, definiteID: String?) {
        let calls = pendingCalls
        for (callID, pending) in calls {
            if let definiteID, callID == definiteID {
                pendingCalls.removeValue(forKey: callID)
                pending.continuation?.resume(throwing: PCLinkError.peerOffline)
                continue
            }
            if let sid, let pendingSID = pending.sessionID, pendingSID == sid {
                pendingCalls.removeValue(forKey: callID)
                pending.continuation?.resume(
                    throwing: PCLinkSessionLost(reason: .peerOffline))
            }
        }
        if let id, pendingCalls[id] != nil {
            pendingCalls.removeValue(forKey: id)?.continuation?.resume(throwing: PCLinkError.peerOffline)
        }
    }

    private func handleRelayFrame(_ frame: PCLinkJSON) async {
        switch frame["type"]?.stringValue {
        case "e2e.handshake":
            handleHandshakeFrame(frame)
        case "e2e":
            await handleE2EFrame(frame)
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

    private func handleE2EFrame(_ frame: PCLinkJSON) async {
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
                await handleInner(decoded.inner, session: session)
                if session.needsRekey { startRekeyIfNeeded() }
            } catch let error as PCLinkError {
                if case .versionUnsupported = error, !session.peerHelloReceived {
                    // §5.6: close with version_unsupported and stop; the UI
                    // shows the upgrade requirement and no retry happens.
                    await sendVersionUnsupportedClose(session)
                }
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
                await handleInner(decoded.inner, session: rekeySession)
            } catch let error as PCLinkError {
                if case .versionUnsupported = error, !rekeySession.peerHelloReceived {
                    await sendVersionUnsupportedClose(rekeySession)
                }
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

    private func sendVersionUnsupportedClose(_ session: PCLinkE2ESession) async {
        guard session.phase != .closed else { return }
        guard let frame = try? session.closeFrame(code: "version_unsupported") else { return }
        try? await enqueueSealed(frame, session: session)
    }

    private func handleSessionError(_ error: PCLinkError) {
        switch error {
        case .versionUnsupported:
            terminalError = error
            failSessionWaiters(error)
            sessionTeardown(reason: error)
            setState(.offline(.versionUnsupported))
            signalDisconnect()
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
        // `relay.offline` says the relay could not deliver a frame. It echoes
        // `id`/`streamId`/`sid` only when the source frame carried them; the
        // E2E outer frame carries `sid` but no `id`, so for an already-sent
        // unsafe call the exact frame is ambiguous. Only a matching `id` (or a
        // frame that never reached the writer) is definitely undelivered and
        // becomes `peer_offline`; the rest follow §7 as a lost session.
        if let sid = offline.sid, session?.sid == sid || rekeySession?.sid == sid {
            failPendingForRelayDrop(sid: sid, id: offline.id, definiteID: offline.id)
            // Streams on that sid: a matching streamId is definite; otherwise
            // an unsafe stream may have opened, so use unknown_outcome.
            for muxID in Array(muxes.keys) {
                guard let mux = muxes[muxID] else { continue }
                for (localID, stream) in mux.streams where stream.sessionID == sid {
                    let definite = offline.streamId == stream.wireStreamID
                    let code = definite || stream.retry != .unsafe
                        ? "peer_offline" : "unknown_outcome"
                    emitStreamError(muxID: muxID, wireStreamID: stream.wireStreamID,
                                    localStreamID: localID,
                                    error: PCLinkRPCError(code: code,
                                                          message: "the PC is offline"))
                }
            }
        } else if let id = offline.id, let pending = pendingCalls.removeValue(forKey: id) {
            pending.continuation?.resume(throwing: PCLinkError.peerOffline)
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

    private func handleInner(_ inner: PCLinkJSON, session: PCLinkE2ESession) async {
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
            await handleStreamFrame(inner, session: session)
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
                cancelResultChunkTimeout(id)
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
        var reassembler = resultChunks[id] ?? PCLinkChunkReassembler()
        do {
            let completed = try reassembler.accept(key: "result:\(id)",
                                                   part: Int(part),
                                                   last: last,
                                                   dataBase64: data)
            resultChunks[id] = reassembler
            guard let completed else {
                // §6.2: the 30 s budget is measured from the last accepted
                // chunk, so each chunk restarts it.
                scheduleResultChunkTimeout(id)
                return
            }
            resultChunks.removeValue(forKey: id)
            cancelResultChunkTimeout(id)
            guard let json = try? PCLinkJSONParser.parseObject(completed),
                  json["type"]?.stringValue == "rpc.result",
                  json["id"]?.stringValue == id else {
                failPendingCall(id, error: .badFrame("chunked rpc.result mismatch"))
                return
            }
            dispatchResult(json, id: id)
        } catch let error as PCLinkError {
            resultChunks.removeValue(forKey: id)
            cancelResultChunkTimeout(id)
            failPendingCall(id, error: error)
        } catch {
            resultChunks.removeValue(forKey: id)
            cancelResultChunkTimeout(id)
            failPendingCall(id, error: .badFrame("chunked rpc.result failed"))
        }
    }

    private func dispatchResult(_ result: PCLinkJSON, id: String) {
        // §2.3: a PCLink object is closed. An unknown member is `bad_frame`,
        // not silently ignored.
        guard let object = try? result.closedObject(required: ["type", "id", "ok"],
                                                    optional: ["result", "error"]),
              object["type"]?.stringValue == "rpc.result",
              object["id"]?.stringValue == id,
              PCLinkValidation.correlationId(id),
              let ok = object["ok"]?.boolValue else {
            handleSessionError(.badFrame("rpc.result header"))
            return
        }
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
                  let message = errorObject["message"]?.stringValue else {
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
    }

    private func scheduleResultChunkTimeout(_ id: String) {
        cancelResultChunkTimeout(id)
        resultChunkTimeouts[id] = Task { [weak self] in
            let timeout = self?.configuration.chunkReassemblyTimeout ?? PCLinkLimits.chunkReassemblyTimeout
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
            } catch { return }
            await self?.expireResultChunk(id)
        }
    }

    private func cancelResultChunkTimeout(_ id: String) {
        resultChunkTimeouts.removeValue(forKey: id)?.cancel()
    }

    /// §6.2/§7 (pclink-v1.5): a stalled result is a transport failure, not a
    /// forever-pending call. A read/idempotent call retries through the normal
    /// `PCLinkSessionLost` path; an unsafe call may have executed, so it is
    /// `unknown_outcome` and is never blindly resent.
    private func expireResultChunk(_ id: String) {
        resultChunkTimeouts.removeValue(forKey: id)
        guard resultChunks.removeValue(forKey: id) != nil else { return }
        guard let pending = pendingCalls.removeValue(forKey: id) else { return }
        switch pending.retry {
        case .read, .idempotent:
            pending.continuation?.resume(throwing:
                PCLinkSessionLost(reason: .sessionExpired("result chunk sequence timed out")))
        case .unsafe:
            pending.continuation?.resume(throwing: PCLinkError.unknownOutcome(endpoint: pending.endpoint))
        }
    }

    private func scheduleStreamChunkTimeout(_ wireStreamID: String) {
        cancelStreamChunkTimeout(wireStreamID)
        streamChunkTimeouts[wireStreamID] = Task { [weak self] in
            let timeout = self?.configuration.chunkReassemblyTimeout ?? PCLinkLimits.chunkReassemblyTimeout
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
            } catch { return }
            await self?.expireStreamChunk(wireStreamID)
        }
    }

    private func cancelStreamChunkTimeout(_ wireStreamID: String) {
        streamChunkTimeouts.removeValue(forKey: wireStreamID)?.cancel()
    }

    /// §6.2/§7 (pclink-v1.5): fail the stalled stream, tell the PC to stop
    /// producing, and let a read-class consumer reopen it. `gateway/
    /// service-unavailable` is a local DSH-transport error that
    /// `DSHRemoteError` classifies as retryable; an unsafe stream is
    /// `unknown_outcome`.
    private func expireStreamChunk(_ wireStreamID: String) async {
        streamChunkTimeouts.removeValue(forKey: wireStreamID)
        guard streamChunks.removeValue(forKey: wireStreamID) != nil else { return }
        guard let muxID = muxForStream(wireStreamID),
              let localID = muxes[muxID]?.wireToLocal[wireStreamID] else { return }
        let retry = muxes[muxID]?.streams[localID]?.retry ?? .read
        if let session {
            try? await sendInner(.object([
                "type": .string("rpc.stream.cancel"),
                "streamId": .string(wireStreamID),
            ]), session: session)
        }
        emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                        error: PCLinkRPCError(
                            code: retry == .unsafe ? "unknown_outcome" : "gateway/service-unavailable",
                            message: "stream chunk sequence timed out"))
    }

    private func failPendingCall(_ id: String, error: PCLinkError) {
        cancelResultChunkTimeout(id)
        guard let pending = pendingCalls.removeValue(forKey: id) else { return }
        pending.continuation?.resume(throwing: error)
    }

    private func cancelAllChunkTimeouts() {
        for task in resultChunkTimeouts.values { task.cancel() }
        resultChunkTimeouts.removeAll()
        for task in streamChunkTimeouts.values { task.cancel() }
        streamChunkTimeouts.removeAll()
    }

    // MARK: Stream frames

    /// Routing key is the session-scoped wire id, never the mux-local id.
    private func muxForStream(_ wireStreamID: String) -> UUID? {
        for (muxID, mux) in muxes where mux.wireToLocal[wireStreamID] != nil {
            return muxID
        }
        return nil
    }

    @discardableResult
    private func removeStream(muxID: UUID, wireStreamID: String) -> String? {
        guard var mux = muxes[muxID] else { return nil }
        let localID = mux.wireToLocal.removeValue(forKey: wireStreamID)
        if let localID { mux.streams.removeValue(forKey: localID) }
        muxes[muxID] = mux
        streamChunks.removeValue(forKey: wireStreamID)
        cancelStreamChunkTimeout(wireStreamID)
        return localID
    }

    private func emitStreamError(muxID: UUID, wireStreamID: String,
                                 localStreamID: String, error: PCLinkRPCError) {
        removeStream(muxID: muxID, wireStreamID: wireStreamID)
        guard let mux = muxes[muxID] else { return }
        let frame: PCLinkJSON = .object([
            "type": .string("error"),
            "streamId": .string(localStreamID),
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

    /// §6.2: an over-limit stream is cancelled on the PC and its partial value
    /// is discarded; the phone never exposes a partial item.
    private func cancelOversizedStream(_ wireStreamID: String, session: PCLinkE2ESession) async {
        let inner: PCLinkJSON = .object(["type": .string("rpc.stream.cancel"),
                                         "streamId": .string(wireStreamID)])
        try? await sendInner(inner, session: session)
    }

    private func handleStreamFrame(_ inner: PCLinkJSON, session: PCLinkE2ESession) async {
        guard let wireStreamID = inner["streamId"]?.stringValue else {
            handleSessionError(.badFrame("stream frame without streamId"))
            return
        }
        guard let muxID = muxForStream(wireStreamID), let mux = muxes[muxID],
              let localID = mux.wireToLocal[wireStreamID],
              let stream = mux.streams[localID] else {
            // Late frames for an ended/unknown stream are discarded.
            return
        }
        // Route by (sid, wire id): a frame for another session is not this
        // stream even when the wire id string matches.
        guard stream.sessionID == session.sid else { return }
        let wasCancelled = stream.cancelled
        switch inner["type"]?.stringValue {
        case "rpc.stream.item":
            if wasCancelled { return }
            guard (try? inner.closedObject(required: ["type", "streamId", "value"])) != nil else {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.item shape"))
                return
            }
            let value = inner["value"] ?? .null
            let size = (try? PCLinkJSONEncoder.encode(value).count) ?? 0
            if size > PCLinkLimits.maxValueBytes {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "frame_too_large",
                                                      message: "value exceeds 8 MiB"))
                await cancelOversizedStream(wireStreamID, session: session)
                return
            }
            mux.continuation.yield(.object(["type": .string("item"), "streamId": .string(localID),
                                            "value": value]))
        case "rpc.stream.chunk":
            if wasCancelled { return }
            guard let object = try? inner.closedObject(required: ["type", "streamId", "part", "last", "data"]),
                  let part = object["part"]?.intValue,
                  let last = object["last"]?.boolValue,
                  let data = object["data"]?.stringValue else {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.chunk shape"))
                return
            }
            var reassembler = streamChunks[wireStreamID] ?? PCLinkChunkReassembler()
            do {
                let completed = try reassembler.accept(key: wireStreamID,
                                                       part: Int(part), last: last,
                                                       dataBase64: data)
                streamChunks[wireStreamID] = reassembler
                guard let completed else {
                    // §6.2: restart the inactivity budget on every chunk.
                    scheduleStreamChunkTimeout(wireStreamID)
                    return
                }
                streamChunks.removeValue(forKey: wireStreamID)
                cancelStreamChunkTimeout(wireStreamID)
                guard let value = try? PCLinkJSONParser.parse(value: completed) else {
                    throw PCLinkError.badFrame("stream chunk is not one JSON value")
                }
                mux.continuation.yield(.object(["type": .string("item"), "streamId": .string(localID),
                                                "value": value]))
            } catch let error as PCLinkError {
                cancelStreamChunkTimeout(wireStreamID)
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: error.code, message: error.message))
                if error.code == "frame_too_large" {
                    await cancelOversizedStream(wireStreamID, session: session)
                }
            } catch {
                cancelStreamChunkTimeout(wireStreamID)
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame", message: "stream chunk"))
            }
        case "rpc.stream.end":
            guard (try? inner.closedObject(required: ["type", "streamId"])) != nil else {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.end shape"))
                return
            }
            removeStream(muxID: muxID, wireStreamID: wireStreamID)
            mux.continuation.yield(.object(["type": .string("end"), "streamId": .string(localID)]))
        case "rpc.stream.error":
            guard let object = try? inner.closedObject(required: ["type", "streamId", "error"]),
                  let errorObject = try? object["error"]?.closedObject(required: ["code", "message"], optional: ["details"]),
                  let code = errorObject["code"]?.stringValue,
                  let message = errorObject["message"]?.stringValue else {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame", message: "rpc.stream.error shape"))
                return
            }
            guard !code.unicodeScalars.contains(where: { $0.value == 0 }) else {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame",
                                                      message: "rpc.stream.error code contains U+0000"))
                return
            }
            do {
                try PCLinkValidation.displayText(message, field: "rpc.stream.error.message",
                                                 minimumBytes: 1, maximumBytes: 2048)
            } catch {
                emitStreamError(muxID: muxID, wireStreamID: wireStreamID, localStreamID: localID,
                                error: PCLinkRPCError(code: "bad_frame",
                                                      message: "rpc.stream.error message invalid"))
                return
            }
            removeStream(muxID: muxID, wireStreamID: wireStreamID)
            var errorOut: PCLinkJSONObject = ["code": .string(code), "message": .string(message)]
            if let details = errorObject["details"] { errorOut["details"] = details }
            mux.continuation.yield(.object([
                "type": .string("error"),
                "streamId": .string(localID),
                "error": .object(errorOut),
            ]))
        default:
            break
        }
    }

    /// Test seam: wire ids with a partial chunk buffer still pending.
    var pendingStreamChunkIDs: Set<String> { Set(streamChunks.keys) }

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
            muxes[id] = mux
            if PCLinkEndpoints.isForbiddenRemoteAdmin(endpoint) {
                muxes[id]?.continuation.yield(.object([
                    "type": .string("error"),
                    "streamId": .string(streamId),
                    "error": .object([
                        "code": .string("forbidden"),
                        "message": .string("remote pclink.admin calls are forbidden"),
                    ]),
                ]))
                return
            }
            let retry = PCLinkEndpoints.retryClass(for: endpoint)
            let deadline = Date().addingTimeInterval(configuration.callRetryDeadline)
            while true {
                let sessionLike = try await requireSession()
                // Map the mux-local id (`events`, `follow`, ...) onto a wire id
                // that is unique for this E2E session (§6.2). A reconnect/retry
                // allocates a fresh one.
                let wireStreamID = sessionLike.session.allocateWireStreamID()
                let inner: PCLinkJSON = .object([
                    "type": .string("rpc.stream.open"),
                    "streamId": .string(wireStreamID),
                    "endpoint": .string(endpoint),
                    "payload": payload,
                ])
                // Re-read the live mux after the suspension: another open on
                // the same mux may have added a stream meanwhile.
                guard var live = muxes[id] else { throw PCLinkError.pairingCancelled }
                live.streams[streamId] = StreamState(
                    muxID: id, localStreamID: streamId, wireStreamID: wireStreamID,
                    endpoint: endpoint, retry: retry, payload: payload,
                    sessionID: sessionLike.session.sid)
                live.wireToLocal[wireStreamID] = streamId
                muxes[id] = live
                do {
                    // Register before sending: a very fast first item must not
                    // race the stream table.
                    try await sendInner(inner, session: sessionLike.session)
                    return
                } catch let lost as PCLinkSessionLost {
                    removeStream(muxID: id, wireStreamID: wireStreamID)
                    if var current = muxes[id] {
                        current.wireToLocal.removeValue(forKey: wireStreamID)
                        muxes[id] = current
                    }
                    switch retry {
                    case .read, .idempotent:
                        if Date() >= deadline { throw lost.reason }
                        try await Task.sleep(nanoseconds: 20_000_000)
                        continue
                    case .unsafe:
                        muxes[id]?.continuation.yield(.object([
                            "type": .string("error"),
                            "streamId": .string(streamId),
                            "error": .object([
                                "code": .string("unknown_outcome"),
                                "message": .string("the stream may have opened but no definitive reply arrived"),
                            ]),
                        ]))
                        return
                    }
                } catch let error as PCLinkError {
                    removeStream(muxID: id, wireStreamID: wireStreamID)
                    if var current = muxes[id] {
                        current.wireToLocal.removeValue(forKey: wireStreamID)
                        muxes[id] = current
                    }
                    throw error
                }
            }
        case "cancel":
            guard let object = try? frame.closedObject(required: ["type", "streamId"]),
                  let streamId = object["streamId"]?.stringValue else {
                throw PCLinkError.badFrame("mux cancel shape")
            }
            guard var live = muxes[id], var stream = live.streams[streamId] else { return }
            if stream.cancelled { return }
            stream.cancelled = true
            live.streams[streamId] = stream
            muxes[id] = live
            let inner: PCLinkJSON = .object(["type": .string("rpc.stream.cancel"),
                                             "streamId": .string(stream.wireStreamID)])
            if let session {
                try? await sendInner(inner, session: session)
            }
        default:
            throw PCLinkError.badFrame("unsupported mux frame type")
        }
    }

    func closeMux(id: UUID) async {
        guard let mux = muxes.removeValue(forKey: id) else { return }
        for stream in mux.streams.values {
            // `streamChunks` is keyed by the wire id, not by `stream:<local>`.
            streamChunks.removeValue(forKey: stream.wireStreamID)
            cancelStreamChunkTimeout(stream.wireStreamID)
            let inner: PCLinkJSON = .object(["type": .string("rpc.stream.cancel"),
                                             "streamId": .string(stream.wireStreamID)])
            if let session {
                try? await sendInner(inner, session: session)
            }
        }
        mux.continuation.finish()
    }

    // MARK: Session teardown

    private func sessionTeardown(reason: PCLinkError) {
        failOutbound(reason)
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
        cancelAllChunkTimeouts()
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
        // Load the durable record before the "already paired" check; otherwise
        // a record that exists only on disk (start() not called yet) would be
        // overwritten by a new pairing.
        try await loadIdentityAndRecordIfNeeded()
        if let record, record.connectionMode == .relay { throw PCLinkError.alreadyPaired }
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
            emitPairingUpdate(.awaitingApproval(prompt))
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
            versionWarning = nil
            clearPeerHello()
            setState(.pairing(.completed))
            emitPairingUpdate(.completed(record))
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
        case .error(let error, _):
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
        if let error, !context.completed {
            emitPairingUpdate(.failed(error))
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
            // Seal the close first, then stop the E2E writer so the queued
            // lower seqs cannot be sent after it (§5.4/§5.5).
            if let close = try? session.closeFrame(code: "unpaired") {
                session.markClosed()
                failOutbound(.sessionExpired("unpair"))
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
        clearPeerHello()
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
        clearPeerHello()
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
        clearPeerHello()
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
