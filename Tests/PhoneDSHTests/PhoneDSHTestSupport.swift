// SPDX-License-Identifier: MIT
// Shared fixtures for PhoneDSHTests.
//
// The host tests exercise the real loopback origin: MockEngine implements
// WebEngineControlling and MockWorker is a small in-process ordered-channel
// client over URLSessionWebSocketTask. No WebKit and no device are involved;
// the Worker HELLO, VFS_MUT, API_REQ and remote.mux traffic are scripted here.

import Foundation
import XCTest
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHLoopback
import PhoneDSHWire
import PhoneDSHAgentCore

enum FacadeTestError: Error, Equatable {
    case timeout
    case invalidState(String)
}

// MARK: - Temporary workspace and bundle

struct FacadeFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-phone-dsh-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staticDirectory = root.appendingPathComponent("www", isDirectory: true)
        let lazy = staticDirectory.appendingPathComponent("lazy", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: staticDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lazy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let image = staticDirectory.appendingPathComponent("image.tar.gz")
        try Data("image".utf8).write(to: image)
        try Data("<html>boot</html>".utf8)
            .write(to: staticDirectory.appendingPathComponent("index.html"))
        try Data("// worker entry".utf8)
            .write(to: staticDirectory.appendingPathComponent("worker-entry.js"))
        try Data("// boot".utf8)
            .write(to: staticDirectory.appendingPathComponent("boot.js"))
        self.root = root
        self.workspace = workspace
        self.bundle = PhoneDSHBundleLocation(staticDirectory: staticDirectory,
                                             imageArchive: image,
                                             lazyDirectory: lazy)
    }

    func configuration(token: String = "test-token",
                       helloTimeout: TimeInterval = 10,
                       drainDeadline: TimeInterval? = nil,
                       execProvider: (any ExecProvider)? = nil,
                       acceleratorNames: [String] = [],
                       budgets: BudgetTable? = nil,
                       turnInactivityTimeout: TimeInterval =
                           PhoneDSHConfiguration.defaultTurnInactivityTimeout)
        throws -> PhoneDSHConfiguration {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        return PhoneDSHConfiguration(workspaceRoot: workspace,
                                     token: token,
                                     origin: origin,
                                     bundle: bundle,
                                     execProvider: execProvider,
                                     acceleratorNames: acceleratorNames,
                                     budgets: budgets,
                                     drainDeadline: drainDeadline,
                                     helloTimeout: helloTimeout,
                                     turnInactivityTimeout: turnInactivityTimeout)
    }

    func materializedFile(_ path: String) -> URL {
        workspace.appendingPathComponent("materialized").appendingPathComponent(path)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

extension BudgetTable {
    /// The 8 GB row with only the VFS logical cap tightened. The per-prefix
    /// caps stay at their normal values, so an over-budget decision can only
    /// come from the summed `MemoryProxySample` (the same basis as
    /// `WorkspaceLogMetrics.totalVFSBytes`).
    static func withVFSLogicalCap(_ bytes: Int) -> BudgetTable {
        let base = BudgetTable.eightGB
        return BudgetTable(engineHeapBytes: base.engineHeapBytes,
                           vfsLogicalBytes: bytes,
                           workspaceBytes: base.workspaceBytes,
                           sessionBytes: base.sessionBytes,
                           tmpBytes: base.tmpBytes,
                           singleFileBytes: base.singleFileBytes,
                           wasiHotInstanceBytes: base.wasiHotInstanceBytes,
                           appProcessBytes: base.appProcessBytes,
                           peakFraction: base.peakFraction,
                           maxSubAgents: base.maxSubAgents,
                           thermalFairSubAgents: base.thermalFairSubAgents,
                           loopbackRoundTripP95Milliseconds: base.loopbackRoundTripP95Milliseconds,
                           plannedRestartIntervalSeconds: base.plannedRestartIntervalSeconds,
                           recoveryBaseSeconds: base.recoveryBaseSeconds,
                           recoverySecondsPerMegabyte: base.recoverySecondsPerMegabyte)
    }
}

// MARK: - Polling helpers

func waitUntil(timeout: TimeInterval = 5,
               _ condition: @escaping @Sendable () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline { throw FacadeTestError.timeout }
        try await Task.sleep(nanoseconds: 3_000_000)
    }
}

// MARK: - JSONValue test helpers

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var testString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var testBool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var testInt: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }
}

// MARK: - Fake channel (transport contract tests)

/// One in-memory ``PhoneDSHChannel``. `respond` receives the decoded request
/// and returns the API events the host should observe.
final class FakeChannel: PhoneDSHChannel, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var recorded: [(head: ApiRequestHead, body: Data)] = []
    private var responder: @Sendable (ApiRequestHead, Data) -> [ChannelAPIEvent]

    init(responder: @escaping @Sendable (ApiRequestHead, Data) -> [ChannelAPIEvent]) {
        self.responder = responder
    }

    func setResponder(_ responder: @escaping @Sendable (ApiRequestHead, Data) -> [ChannelAPIEvent]) {
        lock.lock()
        self.responder = responder
        lock.unlock()
    }

    var requests: [(head: ApiRequestHead, body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sendAPIRequest(head: ApiRequestHead, body: Data) async throws -> AsyncStream<ChannelAPIEvent> {
        lock.lock()
        recorded.append((head, body))
        let responder = self.responder
        lock.unlock()
        let events = responder(head, body)
        return AsyncStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    /// A scripted manual channel: every request gets its own stream that the
    /// test can drive later.
    static func manual() -> ManualChannel { ManualChannel() }
}

/// A channel whose response streams the test drives explicitly.
final class ManualChannel: PhoneDSHChannel, @unchecked Sendable {
    let id = UUID()
    private let lock = NSLock()
    private var recorded: [(id: UUID, head: ApiRequestHead, body: Data)] = []
    private var continuations: [UUID: AsyncStream<ChannelAPIEvent>.Continuation] = [:]

    var requests: [(id: UUID, head: ApiRequestHead, body: Data)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func sendAPIRequest(head: ApiRequestHead, body: Data) async throws -> AsyncStream<ChannelAPIEvent> {
        let requestID = UUID()
        let (stream, continuation) = AsyncStream<ChannelAPIEvent>.makeStream()
        lock.lock()
        recorded.append((requestID, head, body))
        continuations[requestID] = continuation
        lock.unlock()
        return stream
    }

    func send(_ requestIndex: Int, _ event: ChannelAPIEvent) {
        lock.lock()
        let continuation = recorded.indices.contains(requestIndex)
            ? continuations[recorded[requestIndex].id] : nil
        lock.unlock()
        continuation?.yield(event)
    }

    func finish(_ requestIndex: Int) {
        lock.lock()
        let continuation = recorded.indices.contains(requestIndex)
            ? continuations[recorded[requestIndex].id] : nil
        lock.unlock()
        continuation?.finish()
    }
}

/// Hands out pre-scripted channels and records the excluded ids.
actor ChannelQueue {
    private var channels: [FakeChannel]
    private var excludedSets: [Set<UUID>] = []

    init(_ channels: [FakeChannel]) {
        self.channels = channels
    }

    func next(excluding: Set<UUID>) throws -> FakeChannel {
        excludedSets.append(excluding)
        guard channels.isEmpty == false else { throw FacadeTestError.invalidState("no channel left") }
        return channels.removeFirst()
    }

    func exclusions() -> [Set<UUID>] { excludedSets }
}

// MARK: - Scripted in-process worker over the real loopback origin

/// The Worker side of the ordered channel used by the assembly tests.
///
/// It speaks the real 0x01/0x10/0x40/0x41/0x42 frame contract over a
/// URLSessionWebSocketTask connected to the host's loopback server. The only
/// additional contract is the remote.mux bridge documented in
/// ``PhoneDSHMuxProtocol``.
actor MockWorker {
    private struct PendingReceive {
        var reqID: UInt32
        var muxID: String
        var headSent: Bool
    }

    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var connectionToken = UUID()
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var ackedMseq: UInt64 = 0
    private var hostHello: HelloPayload?
    private var connectionCount = 0
    private var helloCount = 0
    private var workerHelloSent = false
    private var fenceFrames = 0
    private var lifecycleFrames = 0
    private var lastHostError: String?
    private var outbound: [Data] = []
    private var draining = false

    private var pendingReceives: [PendingReceive] = []
    private var muxQueues: [String: [Data]] = [:]
    private var receivedMux: [(muxID: String, frame: JSONValue)] = []
    private var lastMuxIDValue: String?
    private var muxClosed: Set<String> = []
    /// Unary remote-API methods the host called, in arrival order. The
    /// turn-inactivity tests use it to prove that an abandoned harness never
    /// sends `session/cancel` into the recovered session.
    private var receivedUnaryMethods: [String] = []

    /// API requests the scripted Worker deliberately leaves unanswered so a
    /// test can hold one `0x40` exchange in flight through a drain.
    private var hangingRequests: [ApiRequestFrame] = []
    /// Scripted HTTP status for the scoped descendant-drain route. `nil`
    /// answers with a successful `pdsh-descendant-drain/1` receipt.
    private var descendantDrainFailureStatus: Int?
    /// Descendant ids the successful scripted route reports as live. A test can
    /// name a child whose durable journal was never written.
    private var descendantDrainDescendants: [String] = []
    /// Scoped descendant-drain requests received (success or scripted failure).
    private var descendantDrainRequests = 0
    /// Exec events the host emitted, in arrival order.
    private var receivedExecEvents: [(execID: String, type: String, replayed: Bool)] = []
    /// Raw payloads of the same events, for tests that inspect stdout/stderr.
    private var receivedExecEventBodies: [(execID: String, type: String, body: Data)] = []
    private var journalSequences: [String: UInt64] = [:]
    private var journalAcked: [String: UInt64] = [:]

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw FacadeTestError.invalidState("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else {
            throw FacadeTestError.invalidState("bad channel URL")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
        self.decoder = FrameDecoder()
        self.sendSeq = 0
        self.connectionCount += 1
        self.connectionToken = UUID()
        let token = self.connectionToken
        receiveTask = Task { await self.receiveLoop(task, token: token) }

        workerHelloSent = false
        // The worker HELLO is sent after the first host HELLO arrives: the
        // host sends its HELLO as soon as the WebSocket opens, and this avoids
        // racing URLSessionWebSocketTask.send() against the TCP connect.
    }

    private func sendWorkerHello() throws {
        guard let configuration else { throw FacadeTestError.invalidState("never connected") }
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
    }

    func reconnect() throws {
        guard let configuration else { throw FacadeTestError.invalidState("never connected") }
        try connect(configuration)
    }

    func disconnect() {
        cancelConnection()
        pendingReceives.removeAll()
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

    // MARK: Observation

    func counts() -> (connections: Int, hellos: Int, fences: Int, lifecycles: Int) {
        (connectionCount, helloCount, fenceFrames, lifecycleFrames)
    }

    func acknowledgedMseq() -> UInt64 { ackedMseq }
    func highestMseq() -> UInt64 { lastMseq }
    func hostErrorText() -> String? { lastHostError }
    func latestMuxID() -> String? { lastMuxIDValue }
    /// Host HELLO channel caps, as seen by the Worker.
    func hostHelloCaps() -> [String] { hostHello?.caps ?? [] }

    func muxFrames() -> [(muxID: String, frame: JSONValue)] { receivedMux }

    /// Remote.mux ids the host explicitly closed (the follow stream of a
    /// cancelled or finished subscription).
    func closedMuxIDs() -> Set<String> { muxClosed }

    /// Unary remote-API endpoint names the host called.
    func unaryMethods() -> [String] { receivedUnaryMethods }

    /// Sends one `ERROR` frame as the scripted Worker (G2-ENG-03 regression:
    /// a `VFS_REFUSED` diagnostic must not close the ordered channel).
    func sendError(_ payload: ErrorPayload) throws {
        try enqueueJSON(.error, payload)
    }

    /// Sends one `CONSOLE` frame; a refused-but-alive channel still carries it.
    func sendConsole(_ text: String, level: ConsolePayload.Level = .info) throws {
        try enqueueJSON(.console, ConsolePayload(level: level, text: text))
    }

    func waitForOpenFrames(timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            let counts = await self.counts()
            return counts.fences > 0 && counts.lifecycles > 0
        }
    }

    func waitForAck(_ mseq: UInt64, timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            (await self.acknowledgedMseq()) >= mseq
        }
    }

    // MARK: Drain and exec helpers

    func waitForHangingRequest(timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            await self.hasHangingRequest()
        }
    }

    /// Scripts the scoped descendant-drain route to answer with `status`
    /// instead of a receipt. `nil` restores the successful receipt.
    func setDescendantDrainFailureStatus(_ status: Int?) {
        descendantDrainFailureStatus = status
    }

    /// Names descendants in the successful scripted receipt even when no
    /// journal for them was written. This models a route that claims a live
    /// child the host cannot verify from durable records.
    func setDescendantDrainDescendants(_ descendants: [String]) {
        descendantDrainDescendants = descendants
    }

    /// Number of scoped descendant-drain requests this Worker has answered.
    func descendantDrainRequestCount() -> Int { descendantDrainRequests }

    private func hasHangingRequest() -> Bool { hangingRequests.isEmpty == false }

    /// Completes the request that `session/hang` parked, with a normal
    /// `server-response` envelope.
    func respondToHanging(sessionID: String) throws {
        guard let request = hangingRequests.first else {
            throw FacadeTestError.invalidState("no hanging request")
        }
        hangingRequests.removeFirst()
        let rpcID = (try? JSONValue.parse(request.body))?["rpcId"]?.testString ?? ""
        let response = JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string(rpcID),
            "result": .object([
                "ok": .bool(true),
                "value": .object(["sessionId": .string(sessionID)]),
            ]),
        ])
        try sendAPIResponse(reqID: request.reqID,
                            head: ApiResponseHead(status: 200, headers: [
                                PhoneDSHMuxProtocol.contentTypeHeader:
                                    PhoneDSHMuxProtocol.jsonContentType,
                            ]),
                            body: try response.encoded())
        try sendAPIEnd(reqID: request.reqID)
    }

    /// Sends one `0x20 EXEC_REQ` for an advertised accelerator.
    func requestExec(execID: String, idemKey: String, argv: [String],
                     cwd: String = "/dsh/workspace", journalKey: String? = nil,
                     requiresMseq: UInt64 = 0,
                     extraEnv: [String: JSONValue] = [:]) throws {
        var bodyMembers: [String: JSONValue] = [
            "exec_id": .string(execID),
            "argv": .array(argv.map { .string($0) }),
            "cwd": .string(cwd),
        ]
        if let journalKey {
            var env = extraEnv
            env["XL_IDEMPOTENCY_KEY"] = .string(journalKey)
            bodyMembers["env"] = .object(env)
        }
        let body = JSONValue.object(bodyMembers)
        let payload = try ExecRequestPayload(body: try body.encoded(),
                                             requiresMseq: requiresMseq,
                                             idemKey: idemKey)
        try enqueueFrame(.execRequest, payload: try payload.encodedPayload())
    }

    @discardableResult
    func sendJournal(sessionID: String, record: [String: Any]) throws -> UInt64 {
        let jseq = (journalSequences[sessionID] ?? 0) + 1
        journalSequences[sessionID] = jseq
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let body = JournalBody(jseq: jseq, sessionID: sessionID, record: data)
        try enqueueFrame(.journal, payload: try body.encoded())
        return jseq
    }

    func waitForJournalAck(sessionID: String, jseq: UInt64,
                           timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            await self.journalAcked[sessionID, default: 0] >= jseq
        }
    }

    func execEvents() -> [(execID: String, type: String, replayed: Bool)] {
        receivedExecEvents
    }

    func execEventBodies() -> [(execID: String, type: String, body: Data)] {
        receivedExecEventBodies
    }

    /// Caps of the host HELLO this connection received.
    func hostHelloCapabilities() -> [String]? {
        hostHello?.caps
    }

    func waitForExecEvent(_ execID: String, type: String,
                          timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            await self.receivedExecEvents.contains {
                $0.execID == execID && $0.type == type
            }
        }
    }

    // MARK: VFS

    @discardableResult
    func writeFile(path: String, data: Data, mode: UInt32 = 0o644) throws -> UInt64 {
        let mseq = lastMseq + 1
        let body = VfsMutationBody(op: .write, mode: mode,
                                   mflags: [.entryChanged], appendFrom: 0,
                                   path: path, data: data)
        try enqueueFrame(.vfsMutation,
                         payload: try VfsMutationPayload.encode(mseq: mseq, body: body))
        lastMseq = mseq
        return mseq
    }

    // MARK: remote.mux bridge (test side)

    func pushMuxFrame(_ frame: JSONValue, muxID: String) throws {
        let encoded = try frame.encoded()
        var line = Data(String(decoding: encoded, as: UTF8.self).utf8)
        line.append(0x0A)
        if let index = pendingReceives.firstIndex(where: { $0.muxID == muxID }) {
            var pending = pendingReceives[index]
            if pending.headSent {
                try sendAPIResponse(reqID: pending.reqID, head: nil, body: line)
            } else {
                try sendAPIResponse(reqID: pending.reqID,
                                    head: ApiResponseHead(status: 200, headers: [
                                        PhoneDSHMuxProtocol.contentTypeHeader:
                                            PhoneDSHMuxProtocol.ndjsonContentType,
                                    ]),
                                    body: line)
                pending.headSent = true
                pendingReceives[index] = pending
            }
        } else {
            muxQueues[muxID, default: []].append(line)
        }
    }

    func waitForMuxReceive(muxID: String, timeout: TimeInterval = 5) async throws {
        try await waitUntil(timeout: timeout) {
            await self.hasPendingReceive(muxID: muxID)
        }
    }

    private func hasPendingReceive(muxID: String) -> Bool {
        pendingReceives.contains { $0.muxID == muxID }
    }

    // MARK: Receive loop

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
            case .data(let bytes):
                data = bytes
            case .string(let text):
                data = Data(text.utf8)
            @unknown default:
                return
            }
            do {
                let frames = try decoder.feed(data)
                for frame in frames { try handle(frame) }
            } catch {
                lastHostError = String(describing: error)
                return
            }
        }
    }

    private func handle(_ frame: Frame) throws {
        switch frame.type {
        case .hello:
            hostHello = try JSONDecoder().decode(HelloPayload.self, from: frame.payload)
            if !workerHelloSent { try sendWorkerHello() }
        case .vfsAck:
            let body = try VfsAckBody.decode(frame.payload)
            if body.level == .write {
                ackedMseq = max(ackedMseq, body.uptoMseq)
            }
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
            try respond(to: request)
        case .execEvent:
            guard let object = try? JSONValue.parse(frame.payload) else { return }
            let execID = object["exec_id"]?.testString ?? ""
            let type = object["type"]?.testString ?? ""
            let replayed = object["replayed"]?.testBool ?? false
            receivedExecEvents.append((execID, type, replayed))
            receivedExecEventBodies.append((execID, type, body: frame.payload))
        case .error:
            let payload = try JSONDecoder().decode(ErrorPayload.self, from: frame.payload)
            lastHostError = "\(payload.code.rawValue): \(payload.message)"
        default:
            break
        }
    }

    // MARK: API responses

    private func respond(to request: ApiRequestFrame) throws {
        let muxID = request.head.headers[PhoneDSHMuxProtocol.muxIDHeader]
        let operation = request.head.headers[PhoneDSHMuxProtocol.operationHeader]
        if request.head.path == PhoneDSHMuxProtocol.path, let muxID, let operation {
            try respondMux(request, muxID: muxID, operation: operation)
        } else {
            try respondUnary(request)
        }
    }

    private func respondUnary(_ request: ApiRequestFrame) throws {
        var rpcID = ""
        var method = ""
        if let envelope = try? JSONValue.parse(request.body) {
            rpcID = envelope["rpcId"]?.testString ?? ""
            method = envelope["method"]?.testString ?? ""
        }
        receivedUnaryMethods.append(method)
        if request.head.path == PhoneDSHDescendantDrainProtocol.path {
            try respondDescendantDrain(request)
            return
        }
        if method == "session/hang" {
            // Hold this exchange open; the test completes it through
            // `respondToHanging`.
            hangingRequests.append(request)
            return
        }
        let value: JSONValue
        switch method {
        case "session/create":
            value = .object(["sessionId": .string("mock-session")])
        case "session/page":
            value = .object(["records": .array([]), "hasMore": .bool(false)])
        default:
            value = .object([:])
        }
        let response = JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string(rpcID),
            "result": .object(["ok": .bool(true), "value": value]),
        ])
        try sendAPIResponse(reqID: request.reqID,
                            head: ApiResponseHead(status: 200, headers: [
                                PhoneDSHMuxProtocol.contentTypeHeader:
                                    PhoneDSHMuxProtocol.jsonContentType,
                            ]),
                            body: try response.encoded())
        try sendAPIEnd(reqID: request.reqID)
    }

    private func respondDescendantDrain(_ request: ApiRequestFrame) throws {
        descendantDrainRequests += 1
        if let status = descendantDrainFailureStatus {
            let body = Data("scripted descendant-drain HTTP \(status)".utf8)
            try sendAPIResponse(reqID: request.reqID,
                                head: ApiResponseHead(status: status, headers: [:]),
                                body: body)
            try sendAPIEnd(reqID: request.reqID)
            return
        }
        var roots: [String] = []
        if let object = try? JSONValue.parse(request.body),
           case .object(let members) = object,
           let sessionIDs = members["sessionIds"],
           case .array(let values) = sessionIDs {
            roots = values.compactMap { $0.testString }
        }
        let receipt = JSONValue.object([
            "protocol": .string(PhoneDSHDescendantDrainProtocol.receiptProtocol),
            "roots": .array(roots.map { .string($0) }),
            "missing": .array([]),
            "descendants": .array(descendantDrainDescendants.map { .string($0) }),
            "durationMs": .number(0),
        ])
        let envelope = JSONValue.object([
            "ok": .bool(true),
            "value": receipt,
        ])
        try sendAPIResponse(reqID: request.reqID,
                            head: ApiResponseHead(status: 200, headers: [
                                PhoneDSHMuxProtocol.contentTypeHeader:
                                    PhoneDSHMuxProtocol.jsonContentType,
                            ]),
                            body: try envelope.encoded())
        try sendAPIEnd(reqID: request.reqID)
    }

    private func respondMux(_ request: ApiRequestFrame, muxID: String, operation: String) throws {
        lastMuxIDValue = muxID
        switch operation {
        case PhoneDSHMuxProtocol.sendOperation:
            if muxClosed.contains(muxID) {
                try sendAPIResponse(reqID: request.reqID,
                                    head: ApiResponseHead(status: 410, headers: [:]), body: Data())
                try sendAPIEnd(reqID: request.reqID)
                return
            }
            if let frame = try? JSONValue.parse(request.body) {
                receivedMux.append((muxID, frame))
            }
            try sendAPIResponse(reqID: request.reqID,
                                head: ApiResponseHead(status: 204, headers: [:]), body: Data())
            try sendAPIEnd(reqID: request.reqID)

        case PhoneDSHMuxProtocol.receiveOperation:
            pendingReceives.append(PendingReceive(reqID: request.reqID, muxID: muxID,
                                                  headSent: false))
            try flushMuxQueue(muxID)

        case PhoneDSHMuxProtocol.closeOperation:
            muxClosed.insert(muxID)
            try sendAPIResponse(reqID: request.reqID,
                                head: ApiResponseHead(status: 204, headers: [:]), body: Data())
            try sendAPIEnd(reqID: request.reqID)
            if let index = pendingReceives.firstIndex(where: { $0.muxID == muxID }) {
                let pending = pendingReceives.remove(at: index)
                try sendAPIEnd(reqID: pending.reqID)
            }
            muxQueues[muxID] = []

        default:
            try sendAPIResponse(reqID: request.reqID,
                                head: ApiResponseHead(status: 404, headers: [:]), body: Data())
            try sendAPIEnd(reqID: request.reqID)
        }
    }

    private func flushMuxQueue(_ muxID: String) throws {
        guard let index = pendingReceives.firstIndex(where: { $0.muxID == muxID }) else { return }
        var pending = pendingReceives[index]
        let lines = muxQueues[muxID] ?? []
        muxQueues[muxID] = []
        for line in lines {
            if pending.headSent {
                try sendAPIResponse(reqID: pending.reqID, head: nil, body: line)
            } else {
                try sendAPIResponse(reqID: pending.reqID,
                                    head: ApiResponseHead(status: 200, headers: [
                                        PhoneDSHMuxProtocol.contentTypeHeader:
                                            PhoneDSHMuxProtocol.ndjsonContentType,
                                    ]),
                                    body: line)
                pending.headSent = true
            }
        }
        pendingReceives[index] = pending
    }

    private func sendAPIResponse(reqID: UInt32, head: ApiResponseHead?, body: Data) throws {
        let frame = ApiResponseFrame(reqID: reqID, head: head, body: body)
        try enqueueFrame(.apiResponse, payload: try frame.encoded())
    }

    private func sendAPIEnd(reqID: UInt32) throws {
        try enqueueFrame(.apiEnd, payload: ApiEndFrame(reqID: reqID).encoded())
    }

    // MARK: Frame sends

    private func enqueueJSON<T: Encodable>(_ type: FrameType, _ value: T) throws {
        try enqueueFrame(type, payload: try CanonicalJSON.encode(value))
    }

    private func enqueueFrame(_ type: FrameType, payload: Data) throws {
        guard task != nil else { throw FacadeTestError.invalidState("channel is closed") }
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

// MARK: - Scripted executor

/// Deterministic read-only accelerator used by the D10 dedup tests.
final class TestExecProvider: ExecProvider, @unchecked Sendable {
    let capabilities = ExecCapabilities(environment: "test",
                                        network: false,
                                        persistentWorkspace: true,
                                        tiers: [.interactive])
    private let lock = NSLock()
    private var runCountValue = 0

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runCountValue
    }

    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        lock.lock()
        runCountValue += 1
        lock.unlock()
        let events: [ExecEvent] = [
            .stdout(seq: 0, data: Data("needle\n".utf8)),
            .exit(code: 0, signal: nil, truncated: false),
        ]
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(execID: String) async {}
}

/// Exec provider whose event stream the test emits explicitly. It lets a test
/// break the on-disk ledger after the execution `start` was persisted and then
/// drive later events through the failing append path.
final class GatedExecProvider: ExecProvider, @unchecked Sendable {
    let capabilities = ExecCapabilities(environment: "test",
                                        network: false,
                                        persistentWorkspace: true,
                                        tiers: [.interactive])
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<ExecEvent, Error>.Continuation?
    private var started = false

    var didStart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ExecEvent, Error>.makeStream()
        lock.lock()
        self.continuation = continuation
        self.started = true
        lock.unlock()
        return stream
    }

    func emit(_ event: ExecEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    func finish() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func cancel(execID: String) async {
        finish()
    }
}

// MARK: - Mock engine

final class MockEngine: WebEngineControlling, WebEngineRestartRequesting,
    WebEngineWorkerTerminating, WebEngineShutdownRequesting,
    PhoneDSHEngineEventSource, @unchecked Sendable {
    let worker: MockWorker
    private let lock = NSLock()
    private var lockdown = false
    private var attached = true
    private var bootError: Error?
    private var stopError: Error?
    private var shutdownError: Error?
    private var bootCountValue = 0
    private var terminateCountValue = 0
    private var shutdownCountValue = 0
    private var lastConfigurationValue: WebEngineConfiguration?
    /// Test-only pause before the Worker connects. A recovery boot keeps the
    /// controller in `Recovering` (and therefore the replay window open) for
    /// this long, so a regression can observe the edge before HELLO.
    private var bootDelayValue: TimeInterval = 0
    /// Test-only hook run while the old Worker is being replaced, after the
    /// controller seal and before the replacement Worker connects. It lets a
    /// planned-restart regression simulate the old Worker writing a child
    /// journal in the shutdown window.
    private var restartHookValue: (@Sendable () throws -> Void)?
    private let eventStream: AsyncStream<WebEngineEvent>
    private let eventContinuation: AsyncStream<WebEngineEvent>.Continuation

    init(worker: MockWorker, lockdown: Bool = false, attached: Bool = true) {
        self.worker = worker
        self.lockdown = lockdown
        self.attached = attached
        var continuation: AsyncStream<WebEngineEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    var isLockdownModeEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lockdown
    }

    var isAttachedWithVisibleArea: Bool {
        lock.lock()
        defer { lock.unlock() }
        return attached
    }

    var bootCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return bootCountValue
    }

    /// How many times the page/Worker termination hook was called. A handoff
    /// must call this before the fence CAS, not just drop the host's reference.
    var terminateCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return terminateCountValue
    }

    /// How many times the engine bridge was shut down. A handoff must call this
    /// after a successful termination, before the fence CAS.
    var shutdownCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return shutdownCountValue
    }

    var lastConfiguration: WebEngineConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return lastConfigurationValue
    }

    func setBootDelay(_ value: TimeInterval) {
        lock.lock()
        bootDelayValue = max(0, value)
        lock.unlock()
    }

    func setStopError(_ error: Error?) {
        lock.lock()
        stopError = error
        lock.unlock()
    }

    func setShutdownError(_ error: Error?) {
        lock.lock()
        shutdownError = error
        lock.unlock()
    }

    /// Installs a hook in the old Worker shutdown window before replacement.
    func setRestartHook(_ hook: (@Sendable () throws -> Void)?) {
        lock.lock()
        restartHookValue = hook

        lock.unlock()
    }

    func setLockdown(_ value: Bool) {
        lock.lock()
        lockdown = value
        lock.unlock()
    }

    func setAttached(_ value: Bool) {
        lock.lock()
        attached = value
        lock.unlock()
    }

    func setBootError(_ error: Error?) {
        lock.lock()
        bootError = error
        lock.unlock()
    }

    func emit(_ event: WebEngineEvent) {
        eventContinuation.yield(event)
    }

    func phoneDSHEvents() -> AsyncStream<WebEngineEvent> {
        eventStream
    }

    func load(_ url: URL) async throws {}

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        lock.lock()
        bootCountValue += 1
        lastConfigurationValue = configuration
        let error = bootError
        let delay = bootDelayValue
        lock.unlock()
        if let error { throw error }
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try await worker.connect(configuration)
    }

    func restart() async throws {
        guard let configuration = lastConfiguration else {
            throw FacadeTestError.invalidState("never booted")
        }
        lock.lock()
        let hook = restartHookValue
        lock.unlock()
        try hook?()
        try await bootWorker(configuration)
    }

    /// Mirrors the real engine's first phase: destroy the page/Worker. A test
    /// can inject a failure to prove a refused stop never reaches the CAS.
    func terminateWorker() async throws {
        lock.lock()
        terminateCountValue += 1
        let error = stopError
        lock.unlock()
        if let error { throw error }
        // The real terminate phase destroys the page and closes its peer
        // socket before the Host may accept clean EOF and pack the overlay.
        await worker.disconnect()
    }

    /// Mirrors the real engine's bridge shutdown after the page is gone. A
    /// test can inject a failure to prove the second required hook is not
    /// treated as optional.
    func shutdownWorker() async throws {
        lock.lock()
        shutdownCountValue += 1
        let error = shutdownError
        lock.unlock()
        if let error { throw error }
        await worker.disconnect()
    }

    /// Mirrors ``WebEngine``: a completed restart publishes one
    /// `.restarted(report)` on the engine's own event stream and returns the
    /// same report to the caller. The facade therefore observes the report
    /// twice on a planned restart and must publish it once.
    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        let start = Date()
        try await restart()
        let report = WebEngineRestartReport(reason: reason, bootID: Self.makeBootID(),
                                            duration: .seconds(Date().timeIntervalSince(start)))
        emit(.restarted(report))
        return report
    }

    /// Fresh 32-character lowercase hex boot id, as D6 requires.
    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
