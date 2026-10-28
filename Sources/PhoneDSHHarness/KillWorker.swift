// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — W3-KILL scripted Worker and MockEngine.
//
// The facade is driven with a deterministic engine: no WebKit and no packed
// DSH image are involved. The Worker side speaks the real ordered-channel
// protocol over the host's loopback WebSocket, sends VFS mutations and journal
// records, and can be terminated between any two frames. On reconnect it
// re-sends the mutations the host has not acknowledged, preserving their
// original mseq (D3), so the host's recovery is exercised with real frames.

import Foundation
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHAgentCore
import PhoneDSHWire

/// Scripted Worker used by the kill matrix.
public actor KillWorker {
    public init() {}

    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var ackedMseq: UInt64 = 0
    private var workerHelloSent = false
    private var connectionCount = 0
    private var helloCount = 0
    private var fenceFrames = 0
    private var lifecycleFrames = 0
    private var lastHostError: String?
    private var outbound: [Data] = []
    private var draining = false

    private var pending: [UInt64] = []
    private var sentBodies: [UInt64: VfsMutationBody] = [:]
    private var journalSequences: [String: UInt64] = [:]
    private var journalAcked: [String: UInt64] = [:]
    /// Journal records this scripted Worker emits only after the host asks it
    /// to open the session for writing. Real DSH reconciles the tool journal in
    /// that write-open path; a history read or `session/follow` never does.
    private var reconcileOnRecovery: [String: [String: Any]] = [:]
    private var recoverySessions: Set<String> = []

    // MARK: Connection

    public func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw KillError.invalidState("bad loopback origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else {
            throw KillError.invalidState("bad loopback channel URL")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
        self.decoder = FrameDecoder()
        self.sendSeq = 0
        self.workerHelloSent = false
        self.connectionCount += 1
        let token = UUID()
        self.connectionToken = token
        receiveTask = Task { await self.receiveLoop(task, token: token) }
    }

    private var connectionToken = UUID()

    public func disconnect() {
        cancelConnection()
    }

    private func cancelConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        outbound.removeAll()
        draining = false
        sendSeq = 0
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, token: UUID) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                return
            }
            guard token == connectionToken else { return }
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: return
            }
            do {
                for frame in try decoder.feed(data) {
                    try await handle(frame)
                }
            } catch {
                lastHostError = String(describing: error)
                return
            }
        }
    }

    private func handle(_ frame: Frame) async throws {
        switch frame.type {
        case .hello:
            _ = try JSONDecoder().decode(HelloPayload.self, from: frame.payload)
            if !workerHelloSent {
                try sendWorkerHello()
            }
        case .vfsAck:
            let body = try VfsAckBody.decode(frame.payload)
            if body.level == .write {
                ackedMseq = max(ackedMseq, body.uptoMseq)
                pending.removeAll { $0 <= body.uptoMseq }
            }
        case .vfsResync:
            // Not expected in these scripts (no appended writes); ignore.
            break
        case .journalAck:
            let body = try JournalAckBody.decode(frame.payload)
            if body.level == .write {
                journalAcked[body.sessionID] = max(journalAcked[body.sessionID] ?? 0,
                                                   body.uptoJseq)
            }
        case .fence:
            fenceFrames += 1
        case .lifecycle:
            lifecycleFrames += 1
        case .apiRequest:
            let request = try ApiRequestFrame.decode(frame.payload)
            try await respond(to: request)
        case .error:
            let payload = try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
            lastHostError = "\(payload.code.rawValue): \(payload.message)"
        default:
            break
        }
    }

    // MARK: API requests

    /// Registers the journal record that this scripted Worker emits when the
    /// host asks it to open `sessionID` for writing (the phone recovery
    /// route). It is never sent proactively, so a test can prove the host drove
    /// the DSH write-open reconcile path rather than a history read.
    public func queueReconcileOnRecovery(sessionID: String,
                                         record: [String: Any]) {
        reconcileOnRecovery[sessionID] = record
    }

    /// Session ids the host opened for writing through the recovery route.
    public func recoveryCalls() -> [String] {
        recoverySessions.sorted()
    }

    private func respond(to request: ApiRequestFrame) async throws {
        if request.head.path == PhoneDSHRecoveryProtocol.path {
            try await respondRecovery(request)
            return
        }
        let operation = request.head.headers[PhoneDSHMuxProtocol.operationHeader]
        if request.head.path == PhoneDSHMuxProtocol.path,
           request.head.headers[PhoneDSHMuxProtocol.muxIDHeader] != nil,
           let operation {
            try await respondMux(request, operation: operation)
            return
        }
        let envelope = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let rpcID = envelope?["rpcId"] as? String ?? ""
        let response: [String: Any] = [
            "type": "server-response",
            "rpcId": rpcID,
            "result": ["ok": true, "value": [String: Any]()],
        ]
        let body = try JSONSerialization.data(withJSONObject: response,
                                              options: [.sortedKeys])
        try respond(request, status: 200,
                    headers: [PhoneDSHMuxProtocol.contentTypeHeader:
                                PhoneDSHMuxProtocol.jsonContentType],
                    body: body)
    }

    /// Answers the phone-only recovery write-open. The queued journal record is
    /// emitted here, and only here: a host that merely reads history never gets
    /// it. Like the production route, the success response is sent only after
    /// the host acknowledged the terminal JOURNAL record, so a test cannot pass
    /// with the host still waiting for the step evidence.
    private func respondRecovery(_ request: ApiRequestFrame) async throws {
        if let object = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
           let sessionID = object["sessionId"] as? String {
            recoverySessions.insert(sessionID)
            if let record = reconcileOnRecovery.removeValue(forKey: sessionID) {
                let jseq = try sendJournal(sessionID: sessionID, record: record)
                // The receive loop must keep running to consume the 0x31 ack,
                // so the response is answered from a child task after the ack
                // arrives. The production route behaves the same way: success
                // is not sent until the terminal JOURNAL was confirmed.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.waitForJournalAck(
                            sessionID: sessionID, jseq: jseq)
                    } catch {
                        return
                    }
                    try? await self.respondRecoverySuccess(request, sessionID: sessionID)
                }
                return
            }
            try respondRecoverySuccess(request, sessionID: sessionID)
            return
        }
        try respond(request, status: 400, body: Data())
    }

    private func respondRecoverySuccess(_ request: ApiRequestFrame,
                                       sessionID: String) throws {
        let body = try JSONSerialization.data(
            withJSONObject: ["ok": true,
                             "value": ["sessionId": sessionID,
                                       "access": "write",
                                       "closed": true]],
            options: [.sortedKeys])
        try respond(request, status: 200,
                    headers: [PhoneDSHMuxProtocol.contentTypeHeader:
                                PhoneDSHMuxProtocol.jsonContentType],
                    body: body)
    }

    private func respondMux(_ request: ApiRequestFrame,
                            operation: String) async throws {
        switch operation {
        case PhoneDSHMuxProtocol.sendOperation:
            // `session/follow` stays a history read here. Recovery must use the
            // dedicated write-open request so a test cannot pass by treating a
            // follow snapshot as journal reconciliation.
            try respond(request, status: 204, body: Data())
        case PhoneDSHMuxProtocol.receiveOperation:
            let snapshot = #"{"type":"item","streamId":"follow","value":{"type":"snapshot","cursor":0,"records":[],"hasMore":false}}"#
                + "\n"
            try respond(request, status: 200,
                        headers: [PhoneDSHMuxProtocol.contentTypeHeader:
                                    PhoneDSHMuxProtocol.ndjsonContentType],
                        body: Data(snapshot.utf8))
        case PhoneDSHMuxProtocol.closeOperation:
            try respond(request, status: 204, body: Data())
        default:
            try respond(request, status: 404, body: Data())
        }
    }

    private func respond(_ request: ApiRequestFrame, status: Int,
                         headers: [String: String] = [:], body: Data) throws {
        let head = ApiResponseHead(status: status, headers: headers)
        try enqueueFrame(.apiResponse,
                         payload: try ApiResponseFrame(reqID: request.reqID,
                                                       head: head,
                                                       body: body).encoded())
        try enqueueFrame(.apiEnd,
                         payload: ApiEndFrame(reqID: request.reqID).encoded())
    }

    private func sendWorkerHello() throws {
        guard let configuration else {
            throw KillError.worker("connect was never called")
        }
        let fence = configuration.fence ?? WebEngineFence()
        let bootID = configuration.bootID ?? Self.makeBootID()
        let hello = try HelloPayload(role: .worker,
                                     bootID: bootID,
                                     sessionEpoch: configuration.sessionEpoch ?? 1,
                                     fence: Fence(owner: fence.owner,
                                                  generation: fence.generation,
                                                  walSeq: fence.walSeq),
                                     caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
                                     lastMseq: lastMseq)
        helloCount += 1
        workerHelloSent = true
        try enqueueJSON(.hello, hello)
        // D3: re-deliver every mutation the host did not acknowledge, with the
        // original mseq. The new connection numbers its own seq from 2.
        for mseq in pending.sorted() {
            guard let body = sentBodies[mseq] else { continue }
            let payload = try VfsMutationPayload.encode(mseq: mseq, body: body)
            try enqueueFrame(.vfsMutation, payload: payload)
        }
    }

    // MARK: Observation

    public func snapshot() -> (acked: UInt64, lastMseq: UInt64, connections: Int,
                        hellos: Int, fences: Int, lifecycles: Int, error: String?) {
        (ackedMseq, lastMseq, connectionCount, helloCount,
         fenceFrames, lifecycleFrames, lastHostError)
    }

    public func acked() -> UInt64 { ackedMseq }

    public func helloNumber() -> Int { helloCount }

    public func connectionNumber() -> Int { connectionCount }

    public func sentMutation(_ mseq: UInt64) -> VfsMutationBody? { sentBodies[mseq] }

    public func waitForOpenFrames(timeout: TimeInterval = 10) async throws {
        try await killWait(timeout: timeout) {
            let state = await self.snapshot()
            return state.fences > 0 && state.lifecycles > 0
        }
    }

    public func waitForAck(_ mseq: UInt64, timeout: TimeInterval = 10) async throws {
        try await killWait(timeout: timeout) {
            await self.ackedMseq >= mseq
        }
    }

    public func waitForJournalAck(sessionID: String, jseq: UInt64,
                           timeout: TimeInterval = 10) async throws {
        try await killWait(timeout: timeout) {
            (await self.journalAcked[sessionID] ?? 0) >= jseq
        }
    }

    public func waitForHelloNumber(_ count: Int, timeout: TimeInterval = 20) async throws {
        try await killWait(timeout: timeout) {
            await self.helloCount >= count
        }
    }

    // MARK: Frames

    @discardableResult
    public func writeFile(_ path: String, data: Data, mode: UInt32 = 0o644) throws -> UInt64 {
        try sendMutation(VfsMutationBody(op: .write, mode: mode,
                                         mflags: [.entryChanged], appendFrom: 0,
                                         path: path, data: data))
    }

    @discardableResult
    public func removeFile(_ path: String) throws -> UInt64 {
        try sendMutation(VfsMutationBody(op: .remove, mode: 0, path: path))
    }

    @discardableResult
    public func mkdir(_ path: String, mode: UInt32 = 0o755) throws -> UInt64 {
        try sendMutation(VfsMutationBody(op: .mkdir, mode: mode, path: path))
    }

    private func sendMutation(_ body: VfsMutationBody) throws -> UInt64 {
        let mseq = lastMseq + 1
        let payload = try VfsMutationPayload.encode(mseq: mseq, body: body)
        try enqueueFrame(.vfsMutation, payload: payload)
        sentBodies[mseq] = body
        lastMseq = mseq
        pending.append(mseq)
        return mseq
    }

    @discardableResult
    public func sendJournal(sessionID: String, record: [String: Any]) throws -> UInt64 {
        let jseq = (journalSequences[sessionID] ?? 0) + 1
        journalSequences[sessionID] = jseq
        let data = try JSONSerialization.data(withJSONObject: record,
                                              options: [.sortedKeys])
        let body = JournalBody(jseq: jseq, sessionID: sessionID, record: data)
        try enqueueFrame(.journal, payload: try body.encoded())
        return jseq
    }

    public func sendBarrier(level: AckLevel, upto: UInt64) throws {
        let body = VfsBarrierBody(wantLevel: level, uptoMseq: upto)
        try enqueueFrame(.vfsBarrier, payload: body.encoded())
    }

    public func requestExec(execID: String, argv: [String], idemKey: String,
                     cwd: String = "/dsh/workspace",
                     journalKey: String? = nil,
                     requiresMseq: UInt64 = 0) throws {
        var body: [String: Any] = [
            "exec_id": execID,
            "argv": argv,
            "cwd": cwd,
        ]
        if let journalKey { body["env"] = ["XL_IDEMPOTENCY_KEY": journalKey] }
        let encoded = try JSONSerialization.data(withJSONObject: body,
                                                 options: [.sortedKeys])
        let payload = try ExecRequestPayload(body: encoded,
                                             requiresMseq: requiresMseq,
                                             idemKey: idemKey)
        try enqueueFrame(.execRequest, payload: try payload.encodedPayload())
    }

    // MARK: Outbound queue

    private func enqueueJSON<T: Encodable>(_ type: FrameType, _ value: T) throws {
        try enqueueFrame(type, payload: try CanonicalJSON.encode(value))
    }

    private func enqueueFrame(_ type: FrameType, payload: Data) throws {
        guard task != nil else {
            throw KillError.worker("the channel is closed")
        }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq, payload: payload)
        outbound.append(encoded)
        if !draining {
            draining = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !outbound.isEmpty {
            let next = outbound.removeFirst()
            guard let task else {
                outbound.removeAll()
                draining = false
                return
            }
            do {
                try await task.send(.data(next))
            } catch {
                outbound.removeAll()
                break
            }
        }
        draining = false
    }

    private static func makeBootID() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var text = ""
        for _ in 0..<32 {
            text.append(digits[Int.random(in: 0..<16, using: &generator)])
        }
        return text
    }
}

// MARK: - Mock engine

/// Deterministic ``WebEngineControlling`` for the facade: it drives
/// ``KillWorker`` instead of WKWebView and can report a WebContent termination.
public final class KillMockEngine: WebEngineControlling, PhoneDSHEngineEventSource, @unchecked Sendable {
    public let worker: KillWorker
    private let lock = NSLock()
    private var lockdown = false
    private var attached = true
    private var bootCountValue = 0
    private var terminationCountValue: UInt64 = 0
    private var lastConfigurationValue: WebEngineConfiguration?
    private let eventStream: AsyncStream<WebEngineEvent>
    private let eventContinuation: AsyncStream<WebEngineEvent>.Continuation

    public init(worker: KillWorker) {
        self.worker = worker
        var continuation: AsyncStream<WebEngineEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    public var isLockdownModeEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockdown
    }

    public var isAttachedWithVisibleArea: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attached
    }

    public var bootCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bootCountValue
    }

    public var lastConfiguration: WebEngineConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return lastConfigurationValue
    }

    public func phoneDSHEvents() -> AsyncStream<WebEngineEvent> {
        eventStream
    }

    public func emitTermination() {
        lock.lock()
        terminationCountValue += 1
        let count = terminationCountValue
        lock.unlock()
        eventContinuation.yield(.terminated(count))
    }

    public func load(_ url: URL) async throws {}

    public func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        lock.lock()
        bootCountValue += 1
        lastConfigurationValue = configuration
        lock.unlock()
        try await worker.connect(configuration)
    }

    public func restart() async throws {
        guard let configuration = lastConfiguration else {
            throw KillError.invalidState("the engine was never booted")
        }
        try await bootWorker(configuration)
    }
}

// MARK: - Gated executor

/// Advertised accelerator whose execution never completes until the test
/// finishes it. The kill matrix uses it to interrupt `during exec`.
public final class KillGatedExecProvider: ExecProvider, @unchecked Sendable {
    public let capabilities = ExecCapabilities(environment: "test",
                                        network: false,
                                        persistentWorkspace: true,
                                        tiers: [.interactive])
    private let lock = NSLock()
    private var started = false
    private var continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation?

    public init() {}

    public var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    public func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ExecEvent, Error>.makeStream()
        lock.lock()
        self.continuation = continuation
        started = true
        lock.unlock()
        return stream
    }

    public func cancel(execID: String) async {
        finish()
    }

    public func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.yield(.exit(code: 0, signal: nil, truncated: false))
        continuation?.finish()
    }
}
