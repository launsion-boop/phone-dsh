// SPDX-License-Identifier: MIT
// Shared fakes, clients and helpers for the PhoneDSHLoopback tests.

import Foundation
import Network
import XCTest
import PhoneDSHWire
import PhoneDSHLoopback
import PhoneDSHAgentCore

// MARK: - Temporary files

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("pdsh-phone-loopback-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func removeTemporaryDirectory(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - HTTP client

struct TestHTTPClient {
    let endpoint: LoopbackEndpoint
    let session: URLSession

    init(endpoint: LoopbackEndpoint) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: configuration)
    }

    func url(_ pathAndQuery: String) -> URL {
        URL(string: endpoint.baseURL.absoluteString + pathAndQuery)!
    }

    func makeRequest(_ method: String, _ pathAndQuery: String,
                     headers: [String: String] = [:],
                     body: Data? = nil,
                     authorized: Bool = true,
                     origin: String? = nil) -> URLRequest {
        var request = URLRequest(url: url(pathAndQuery))
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if authorized {
            request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        }
        if let origin {
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        return request
    }

    func send(_ method: String, _ pathAndQuery: String,
              headers: [String: String] = [:], body: Data? = nil,
              authorized: Bool = true, origin: String? = nil) async throws
        -> (HTTPURLResponse, Data) {
        let request = makeRequest(method, pathAndQuery, headers: headers, body: body,
                                  authorized: authorized, origin: origin)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPTestError.notHTTP
        }
        return (http, data)
    }
}

enum HTTPTestError: Error {
    case notHTTP
    case timeout
}

// MARK: - Data helpers

func hexNamespace() -> String {
    UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

func sha256Name() -> String {
    String(repeating: "0", count: 64)
}

// MARK: - Worker HELLO

func workerHelloPayload(state: ChannelHostState,
                        bootID: String = "ffeeddccbbaa99887766554433221100",
                        lastMseq: UInt64,
                        generation: UInt64? = nil,
                        owner: String? = nil) throws -> HelloPayload {
    HelloPayload(role: .worker,
                 bootID: bootID,
                 sessionEpoch: state.sessionEpoch,
                 fence: Fence(owner: owner ?? state.fence.owner,
                              generation: generation ?? state.fence.generation,
                              walSeq: state.fence.walSeq),
                 caps: ["channel/1", "vfs-sink/1", "journal/1", "api/1"],
                 lastMseq: lastMseq)
}

func encodedFrame(_ type: FrameType, seq: UInt64, payload: Data) throws -> Data {
    try FrameEncoder.encode(type: type, seq: seq, payload: payload)
}

func encodeJSONFrame<T: Encodable>(_ type: FrameType, seq: UInt64, value: T) throws -> Data {
    try encodedFrame(type, seq: seq, payload: CanonicalJSON.encode(value))
}

// MARK: - WebSocket client over URLSession

final class TestWebSocketClient {
    let session: URLSession
    let task: URLSessionWebSocketTask
    private var decoder = FrameDecoder()

    init(endpoint: LoopbackEndpoint, pathAndQuery: String = "/channel?token=@TOKEN@") {
        let configuration = URLSessionConfiguration.ephemeral
        self.session = URLSession(configuration: configuration)
        let suffix = pathAndQuery.replacingOccurrences(of: "@TOKEN@", with: endpoint.token)
        let httpURL = URL(string: endpoint.baseURL.absoluteString + suffix)!
        var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        let url = components.url!
        self.task = session.webSocketTask(with: url)
    }

    func connect() {
        task.resume()
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    func send(frame data: Data) async throws {
        try await send(data)
    }

    func receiveBinary() async throws -> Data {
        let message = try await task.receive()
        switch message {
        case .data(let data):
            return data
        case .string(let text):
            throw WebSocketError.protocolViolation("unexpected text \(text)")
        @unknown default:
            throw WebSocketError.closed
        }
    }

    /// Receives one ordered channel frame.
    func receiveFrame() async throws -> Frame {
        while true {
            let data = try await receiveBinary()
            let frames = try decoder.feed(data)
            if let frame = frames.first { return frame }
        }
    }

    func receiveFrame(timeout: TimeInterval) async throws -> Frame {
        try await withThrowingTaskGroup(of: Frame.self) { group in
            group.addTask { try await self.receiveFrame() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw HTTPTestError.timeout
            }
            let frame = try await group.next()!
            group.cancelAll()
            return frame
        }
    }
}

// MARK: - In-memory channel socket

final class MockChannelSocket: ChannelSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var receiveWaiters: [CheckedContinuation<Data?, Never>] = []
    private var outbox: [Data] = []
    private var isClosed = false
    private var closeCodeValue: Int?
    /// Number of upcoming `sendChannelMessage` calls that fail, in order.
    private var sendsToFail = 0

    init() {}

    /// Inject a transport send failure for the next `count` frames; they are
    /// not appended to the outbox, mirroring a WebSocket write error.
    func failNextSends(_ count: Int) {
        lock.lock()
        sendsToFail = max(0, count)
        lock.unlock()
    }

    func push(_ data: Data) {
        lock.lock()
        if !receiveWaiters.isEmpty {
            let waiter = receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: data)
            return
        }
        inbox.append(data)
        lock.unlock()
    }

    func receiveChannelMessage() async throws -> Data? {
        lock.lock()
        if !inbox.isEmpty {
            let data = inbox.removeFirst()
            lock.unlock()
            return data
        }
        if isClosed {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return await withCheckedContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let data = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: data)
            } else if isClosed {
                lock.unlock()
                continuation.resume(returning: nil)
            } else {
                receiveWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func sendChannelMessage(_ data: Data) async throws {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            throw WebSocketError.closed
        }
        if sendsToFail > 0 {
            sendsToFail -= 1
            lock.unlock()
            throw WebSocketError.closed
        }
        outbox.append(data)
        lock.unlock()
    }

    func closeChannel(code: Int) async {
        lock.lock()
        isClosed = true
        closeCodeValue = code
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: nil) }
    }

    func sentData() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return outbox
    }

    func sentFrames() -> [Frame] {
        var decoder = FrameDecoder()
        var frames: [Frame] = []
        for data in sentData() {
            if let decoded = try? decoder.feed(data) {
                frames.append(contentsOf: decoded)
            }
        }
        return frames
    }

    func waitForFrames(count: Int, timeout: TimeInterval = 5) async throws -> [Frame] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frames = sentFrames()
            if frames.count >= count { return frames }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HTTPTestError.timeout
    }

    func nextFrame(after index: Int, timeout: TimeInterval = 5) async throws -> Frame {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frames = sentFrames()
            if frames.count > index { return frames[index] }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HTTPTestError.timeout
    }

    func closedCode(timeout: TimeInterval = 5) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let code = closeCodeValue
            lock.unlock()
            if let code { return code }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        throw HTTPTestError.timeout
    }
}

// MARK: - Workspace log fake

actor RecordingWorkspaceLog: LoopbackWorkspaceLog {
    private(set) var mutations: [VfsMutationBody] = []
    private(set) var nextMseq: UInt64
    /// Accepted logical sizes of the fake VFS; the pre-WAL single-file refusal
    /// (channel.md §6, §8) projects against them.
    private(set) var logicalSizes: [String: Int] = [:]
    /// Paths for which the fake materializer reports a base mismatch after the
    /// append (channel.md §8). The real detection lives in W1-LOG/W2.
    private let mismatchPaths: Set<String>
    /// Configured single-file budget; `Int.max` leaves the other tests
    /// unchanged and refuses only when a test opts in.
    private let singleFileLimitBytes: Int
    private var lastAck: LoopbackWorkspaceAck?
    private var ackContinuations: [UUID: AsyncStream<LoopbackWorkspaceAck>.Continuation] = [:]
    private var resyncContinuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var pendingResyncs: [String] = []

    init(nextMseq: UInt64 = 1, mismatchPaths: Set<String> = [],
         singleFileLimitBytes: Int = Int.max,
         seedSizes: [String: Int] = [:]) {
        self.nextMseq = nextMseq
        self.mismatchPaths = mismatchPaths
        self.singleFileLimitBytes = singleFileLimitBytes
        self.logicalSizes = seedSizes
    }

    func append(_ mutation: VfsMutationBody) async throws -> UInt64 {
        if mutation.op == .write {
            let projected = projectedSize(for: mutation)
            guard projected <= singleFileLimitBytes else {
                throw VFSResourceRefusal(
                    path: mutation.path,
                    limitBytes: UInt64(singleFileLimitBytes),
                    projectedBytes: UInt64(projected),
                    reason: .fileTooLarge,
                    message: "VFS_REFUSED: \(mutation.path) would grow to \(projected) bytes, above the single-file limit of \(singleFileLimitBytes) bytes")
            }
        }
        let mseq = nextMseq
        nextMseq += 1
        mutations.append(mutation)
        apply(mutation)
        emit(level: .write, uptoMseq: mseq)
        if mismatchPaths.contains(mutation.path) {
            emitResync(path: mutation.path)
        }
        return mseq
    }

    private func projectedSize(for mutation: VfsMutationBody) -> Int {
        let current = logicalSizes[mutation.path] ?? 0
        guard mutation.mflags.contains(.appended) else { return mutation.data.count }
        guard mutation.appendFrom <= UInt64(Int.max),
              mutation.data.count <= Int.max - Int(mutation.appendFrom) else {
            return Int.max
        }
        return max(current, Int(mutation.appendFrom) + mutation.data.count)
    }

    private func apply(_ mutation: VfsMutationBody) {
        switch mutation.op {
        case .write:
            logicalSizes[mutation.path] = projectedSize(for: mutation)
        case .remove:
            logicalSizes[mutation.path] = nil
            let prefix = mutation.path + "/"
            let descendants = logicalSizes.keys.filter { $0.hasPrefix(prefix) }
            for key in descendants {
                logicalSizes[key] = nil
            }
        case .mkdir, .chmod:
            break
        }
    }

    func emit(level: AckLevel, uptoMseq: UInt64) {
        let ack = LoopbackWorkspaceAck(level: level, uptoMseq: uptoMseq)
        lastAck = ack
        for continuation in ackContinuations.values {
            continuation.yield(ack)
        }
    }

    /// Reports a materializer base mismatch for one path; the ordered channel
    /// turns it into `0x13 VFS_RESYNC`.
    func emitResync(path: String) {
        if resyncContinuations.isEmpty { pendingResyncs.append(path) }
        for continuation in resyncContinuations.values {
            continuation.yield(path)
        }
    }

    nonisolated func acks() -> AsyncStream<LoopbackWorkspaceAck> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.store(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.remove(id) }
            }
        }
    }

    nonisolated func resyncs() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.storeResync(continuation, id: id) }
            continuation.onTermination = { _ in
                Task { await self.removeResync(id) }
            }
        }
    }

    private func store(_ continuation: AsyncStream<LoopbackWorkspaceAck>.Continuation, id: UUID) {
        ackContinuations[id] = continuation
        // Acks are cumulative: a late subscriber learns the current level
        // instead of waiting for the next write (keeps tests deterministic).
        if let lastAck { continuation.yield(lastAck) }
    }

    private func remove(_ id: UUID) {
        ackContinuations[id] = nil
    }

    private func storeResync(_ continuation: AsyncStream<String>.Continuation, id: UUID) {
        resyncContinuations[id] = continuation
        for path in pendingResyncs { continuation.yield(path) }
        pendingResyncs.removeAll()
    }

    private func removeResync(_ id: UUID) {
        resyncContinuations[id] = nil
    }

    func mutationCount() -> Int { mutations.count }

    var subscriberCount: Int { ackContinuations.count }
}

// MARK: - Journal log fake

/// Durable-journal double with the D2 high-water semantics: the per-session
/// mark survives `ChannelServer` reconnects for as long as the object does.
/// `appendCalls` counts every append attempt, so a test can prove that a
/// duplicate resend is acknowledged without being appended again.
actor CountingJournalLog: LoopbackJournalLog {
    private var recordStore: [String: [UInt64: Data]] = [:]
    private var highWater: [String: UInt64] = [:]
    private(set) var appendCalls: [(sessionID: String, jseq: UInt64)] = []
    private(set) var storedAppends = 0

    /// Seeds records that a previous connection already persisted; seeding is
    /// not an append.
    init(seed: [String: [UInt64: Data]] = [:]) {
        for (sessionID, entries) in seed {
            recordStore[sessionID] = entries
            highWater[sessionID] = entries.keys.max() ?? 0
        }
    }

    func lastJseq(sessionID: String) async -> UInt64 {
        highWater[sessionID] ?? 0
    }

    func appendJournal(sessionID: String, jseq: UInt64,
                       record: Data) async throws -> UInt64 {
        appendCalls.append((sessionID, jseq))
        let current = highWater[sessionID] ?? 0
        if jseq <= current { return current }
        guard jseq == current &+ 1 else {
            throw PhoneWireError(code: .badPayload, message: "journal jseq gap")
        }
        recordStore[sessionID, default: [:]][jseq] = record
        highWater[sessionID] = jseq
        storedAppends += 1
        return jseq
    }

    func record(sessionID: String, jseq: UInt64) -> Data? {
        recordStore[sessionID]?[jseq]
    }

    func highestJseq(sessionID: String) -> UInt64 {
        highWater[sessionID] ?? 0
    }

    func appendCount() -> Int { appendCalls.count }
}

// MARK: - Exec provider fake

final class ScriptedExecProvider: ExecProvider, @unchecked Sendable {
    let capabilities = ExecCapabilities(environment: "test",
                                        network: false,
                                        persistentWorkspace: true,
                                        tiers: [.interactive])
    private let lock = NSLock()
    private var runCountValue = 0
    private var cancelledIDs: [String] = []
    private let events: [ExecEvent]

    init(events: [ExecEvent]) {
        self.events = events
    }

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runCountValue
    }

    var cancelled: [String] {
        lock.lock()
        defer { lock.unlock() }
        return cancelledIDs
    }

    func run(_ request: ExecRequest) -> AsyncThrowingStream<ExecEvent, Error> {
        lock.lock()
        runCountValue += 1
        let events = self.events
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func cancel(execID: String) async {
        lock.lock()
        cancelledIDs.append(execID)
        lock.unlock()
    }
}

// MARK: - Exec bridge fake (open-source extraction boundary)

enum FakeExecBridgeError: Error {
    case invalidEndpoint
}

/// One parsed HTTP/1.1 request for ``FakeExecBridge``.
struct FakeExecBridgeRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
    var head: String

    /// Parses a complete request head plus `Content-Length` body, or nil while
    /// more bytes are needed.
    static func parse(_ data: Data) -> FakeExecBridgeRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<separator.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = separator.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        let body = Data(data[bodyStart..<(bodyStart + contentLength)])
        return FakeExecBridgeRequest(method: String(requestLine[0]),
                                     path: String(requestLine[1]),
                                     headers: headers,
                                     body: body,
                                     head: head)
    }
}

/// In-test exec-bridge host double. It starts a real loopback HTTP listener and
/// answers the two routes the origin forwards (`POST /v1/exec` NDJSON and
/// `GET /v1/exec/<id>` status) from an ``ExecProvider``. The loopback test
/// target uses it instead of linking the `XiaozhiLinkExecBridge` module, so the
/// phone tests build against `PhoneDSHAgentCore` alone after extraction.
actor FakeExecBridge: ExecBridgeHosting {
    private let provider: any ExecProvider
    private let queue = DispatchQueue(label: "xl.phone.loopback.tests.exec-bridge")
    private var listener: NWListener?
    private var baseURLValue: URL?
    private var tokenValue: String?
    private var requestHeads: [String] = []
    private var exited: Set<String> = []

    init(provider: any ExecProvider) {
        self.provider = provider
    }

    var token: String? { tokenValue }
    var baseURL: URL? { baseURLValue }

    /// Heads seen by the fake, in arrival order (diagnostics only).
    var recordedRequestHeads: [String] { requestHeads }

    func start() async throws -> URL {
        if let baseURLValue { return baseURLValue }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let queue = self.queue
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: queue)
            self.receive(connection, buffer: Data())
        }
        self.listener = listener
        tokenValue = String(UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased())
        let port = try await FakeExecBridge.listen(listener, queue: queue)
        guard let url = URL(string: "http://127.0.0.1:\(port)") else {
            listener.cancel()
            throw FakeExecBridgeError.invalidEndpoint
        }
        baseURLValue = url
        return url
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        baseURLValue = nil
        tokenValue = nil
    }

    func setLifecycle(_ state: ExecBridgeLifecycleState) async {}

    private nonisolated func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = FakeExecBridgeRequest.parse(buffer) {
                Task { await self.handle(request, connection: connection) }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private func handle(_ request: FakeExecBridgeRequest,
                        connection: NWConnection) async {
        requestHeads.append(request.head)
        guard let token = tokenValue,
              request.headers["authorization"] == "Bearer \(token)" else {
            Self.respond(connection, status: 401, contentType: "application/json",
                         body: Data("{\"error\":\"unauthorized\"}".utf8))
            return
        }
        if request.method == "POST" && request.path == "/v1/exec" {
            await handleExec(request, connection: connection)
            return
        }
        if request.method == "GET" && request.path.hasPrefix("/v1/exec/") {
            let execID = String(request.path.dropFirst("/v1/exec/".count))
            let state = exited.contains(execID) ? "exited" : "running"
            let body = (try? JSONSerialization.data(withJSONObject: [
                "exec_id": execID,
                "started_at": 0,
                "state": state,
            ])) ?? Data()
            Self.respond(connection, status: 200, contentType: "application/json",
                         body: body)
            return
        }
        Self.respond(connection, status: 404, contentType: "application/json",
                     body: Data("{\"error\":\"not_found\"}".utf8))
    }

    private func handleExec(_ request: FakeExecBridgeRequest,
                            connection: NWConnection) async {
        guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
              let execID = object["exec_id"] as? String,
              let argv = object["argv"] as? [String],
              let cwd = object["cwd"] as? String else {
            Self.respond(connection, status: 400, contentType: "application/json",
                         body: Data("{\"error\":\"bad_request\"}".utf8))
            return
        }
        var lines: [Data] = [
            Self.eventLine(["type": "start", "exec_id": execID, "seq": 0]),
        ]
        do {
            let stream = provider.run(ExecRequest(execID: execID, argv: argv, cwd: cwd))
            for try await event in stream {
                switch event {
                case .stdout(let seq, let data):
                    lines.append(Self.eventLine([
                        "type": "output", "exec_id": execID, "stream": "stdout",
                        "seq": seq + 1, "data": data.base64EncodedString(),
                    ]))
                case .stderr(let seq, let data):
                    lines.append(Self.eventLine([
                        "type": "output", "exec_id": execID, "stream": "stderr",
                        "seq": seq + 1, "data": data.base64EncodedString(),
                    ]))
                case .exit(let code, let signal, let truncated):
                    var fields: [String: Any] = [
                        "type": "exit", "exec_id": execID, "quiescent": true,
                        "status": code == nil ? "failed" : "exited",
                    ]
                    if let code { fields["code"] = Int(code) }
                    if let signal { fields["signal"] = Int(signal) }
                    if truncated { fields["stdout_truncated"] = true }
                    lines.append(Self.eventLine(fields))
                    exited.insert(execID)
                }
            }
        } catch {
            lines.append(Self.eventLine([
                "type": "error", "exec_id": execID,
                "code": "internal", "message": String(describing: error),
            ]))
        }
        var body = Data()
        for line in lines {
            body.append(line)
            body.append(Data("\n".utf8))
        }
        Self.respond(connection, status: 200, contentType: "application/x-ndjson",
                     body: body)
    }

    private static func eventLine(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
    }

    private nonisolated static func respond(_ connection: NWConnection, status: Int,
                                            contentType: String, body: Data) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        response.append(Data("Content-Type: \(contentType)\r\n".utf8))
        response.append(Data("Cache-Control: no-store\r\n".utf8))
        response.append(Data("Content-Length: \(body.count)\r\n".utf8))
        response.append(Data("Connection: close\r\n\r\n".utf8))
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated static func listen(_ listener: NWListener,
                                           queue: DispatchQueue) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    lock.lock()
                    let claim = !resumed
                    resumed = true
                    lock.unlock()
                    if claim {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    lock.lock()
                    let claim = !resumed
                    resumed = true
                    lock.unlock()
                    if claim { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }
}

// MARK: - Channel handler recording fake

actor RecordingChannelHandler: ChannelHandling {
    /// When set, a mutation is persisted like ``DefaultChannelHandling`` does
    /// so the server can forward the log's level-1 ack.
    private let workspaceLog: (any LoopbackWorkspaceLog)?
    private(set) var hellos: [HelloPayload] = []
    private(set) var mutations: [(mseq: UInt64, body: VfsMutationBody)] = []
    private(set) var barriers: [VfsBarrierBody] = []
    private(set) var journals: [JournalBody] = []
    private(set) var consoles: [ConsolePayload] = []
    private(set) var execRequests: [ExecRequestPayload] = []
    private(set) var errors: [ErrorPayload] = []
    private(set) var apiResponses = 0
    private(set) var apiEnds = 0
    private(set) var apiAborts = 0

    init(workspaceLog: (any LoopbackWorkspaceLog)? = nil) {
        self.workspaceLog = workspaceLog
    }

    func handleHello(_ payload: HelloPayload) async throws {
        hellos.append(payload)
    }

    func handleVFSMutation(_ body: VfsMutationBody, seq: UInt64) async throws {
        mutations.append((0, body))
    }

    func handleVFSMutation(_ body: VfsMutationBody, mseq: UInt64, seq: UInt64) async throws {
        if let workspaceLog {
            _ = try await workspaceLog.append(body)
        }
        mutations.append((mseq, body))
    }

    func handleVFSBarrier(_ body: VfsBarrierBody) async throws {
        barriers.append(body)
    }

    func handleExecRequest(_ payload: ExecRequestPayload) async throws {
        execRequests.append(payload)
    }

    func handleExecControl(_ payload: ExecControlPayload) async throws {}

    func handleJournal(_ body: JournalBody) async throws {
        journals.append(body)
    }

    func handleAPIResponse(_ frame: ApiResponseFrame) async throws {
        apiResponses += 1
    }

    func handleAPIEnd(_ frame: ApiEndFrame) async throws {
        apiEnds += 1
    }

    func handleAPIAbort(_ frame: ApiAbortFrame) async throws {
        apiAborts += 1
    }

    func handleConsole(_ payload: ConsolePayload) async throws {
        consoles.append(payload)
    }

    func handleError(_ payload: ErrorPayload) async throws {
        errors.append(payload)
    }
}

// MARK: - Gates and streaming egress fakes

actor TestGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        released = true
        let current = waiters
        waiters.removeAll()
        for waiter in current { waiter.resume() }
    }

    func isReleased() -> Bool { released }
}

/// Echoes the request body and records the request.
final class EchoHTTPEgress: HTTPEgress, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [HTTPEgressRequest] = []

    var recordedRequests: [HTTPEgressRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let body = request.body
        return AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(status: 200,
                                               headers: ["Content-Type": "application/octet-stream"],
                                               body: body,
                                               isFinal: true))
            continuation.finish()
        }
    }
}

/// Emits a first NDJSON chunk immediately, then waits for the gate.
final class GatedStreamingEgress: HTTPEgress, @unchecked Sendable {
    let gate = TestGate()

    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(HTTPEgressChunk(
                status: 200,
                headers: ["Content-Type": "application/x-ndjson"],
                body: Data("{\"chunk\":1}\n".utf8)))
            let gate = self.gate
            Task {
                await gate.wait()
                continuation.yield(HTTPEgressChunk(body: Data("{\"chunk\":2}\n".utf8),
                                                   isFinal: true))
                continuation.finish()
            }
        }
    }
}

/// Fails before producing a first chunk.
final class FailingHTTPEgress: HTTPEgress, @unchecked Sendable {
    func handle(_ request: HTTPEgressRequest) -> AsyncThrowingStream<HTTPEgressChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LoopbackError.upstreamFailed("boom"))
        }
    }
}

// MARK: - Polling helper

func waitUntil(timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 3_000_000)
    }
    return false
}

// MARK: - Tiny upstream HTTP server (for /mcp proxy tests)

final class TinyHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var lastRequestHead = ""
    private let responseBody: Data
    private(set) var port: UInt16

    private init(listener: NWListener, port: UInt16, responseBody: Data,
                 queue: DispatchQueue) {
        self.listener = listener
        self.port = port
        self.responseBody = responseBody
        self.queue = queue
    }

    static func start(responseBody: Data) async throws -> TinyHTTPServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let queue = DispatchQueue(label: "xl.phone.loopback.tests.upstream")
        let server = TinyHTTPServer(listener: listener, port: 0, responseBody: responseBody,
                                    queue: queue)
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection)
        }
        server.port = try await server.listen()
        return server
    }

    private func listen() async throws -> UInt16 {
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    lock.lock()
                    let claim = !resumed
                    resumed = true
                    lock.unlock()
                    if claim {
                        listener.stateUpdateHandler = nil
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let error):
                    lock.lock()
                    let claim = !resumed
                    resumed = true
                    lock.unlock()
                    if claim { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    var requestHead: String {
        lock.lock()
        defer { lock.unlock() }
        return lastRequestHead
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, _ in
            if let data {
                self.lock.lock()
                self.lastRequestHead += String(decoding: data, as: UTF8.self)
                self.lock.unlock()
            }
            var response = Data("HTTP/1.1 200 OK\r\n".utf8)
            response.append(Data("Content-Type: application/json\r\n".utf8))
            response.append(Data("Content-Length: \(self.responseBody.count)\r\n".utf8))
            response.append(Data("Connection: close\r\n\r\n".utf8))
            response.append(self.responseBody)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}


// MARK: - Raw TCP client (chunked requests, RFC 6455 edges)

final class RawTCPClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "xl.phone.loopback.tests.raw")
    private var buffer = Data()
    private var isClosed = false

    init(host: String = "127.0.0.1", port: UInt16) {
        self.connection = NWConnection(host: NWEndpoint.Host(host),
                                       port: NWEndpoint.Port(rawValue: port)!,
                                       using: .tcp)
    }

    func connect(timeout: TimeInterval = 5) async throws {
        let connection = self.connection
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let lock = NSLock()
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(with: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(error))
                case .cancelled: finish(.failure(HTTPTestError.timeout))
                default: break
                }
            }
            connection.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + timeout) {
                connection.cancel()
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func receiveChunk(timeout: TimeInterval = 10) async throws -> Data? {
        let connection = self.connection
        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<Data?, Error>) {
                lock.lock()
                if resumed { lock.unlock(); return }
                resumed = true
                lock.unlock()
                continuation.resume(with: result)
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                data, _, isComplete, error in
                if let error { finish(.failure(error)) }
                else if let data, !data.isEmpty { finish(.success(data)) }
                else if isComplete { finish(.success(nil)) }
                else { finish(.success(Data())) }
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                lock.lock()
                let pending = !resumed
                lock.unlock()
                if pending {
                    connection.cancel()
                    finish(.failure(HTTPTestError.timeout))
                }
            }
        }
    }

    func readUntil(_ marker: Data, timeout: TimeInterval = 10) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let range = buffer.range(of: marker) {
                let data = Data(buffer[buffer.startIndex..<range.upperBound])
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return data
            }
            guard let chunk = try await receiveChunk(timeout: max(0.1, deadline.timeIntervalSinceNow)) else {
                throw HTTPTestError.timeout
            }
            if !chunk.isEmpty { buffer.append(chunk) }
        }
        throw HTTPTestError.timeout
    }

    func readExactly(_ count: Int, timeout: TimeInterval = 10) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while buffer.count < count {
            guard Date() < deadline else { throw HTTPTestError.timeout }
            guard let chunk = try await receiveChunk(timeout: max(0.1, deadline.timeIntervalSinceNow)) else {
                throw HTTPTestError.timeout
            }
            if !chunk.isEmpty { buffer.append(chunk) }
        }
        let data = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        return data
    }

    func close() {
        isClosed = true
        connection.cancel()
    }
}

// MARK: - Raw RFC 6455 client

/// The RFC 6455 sample nonce from RFC 6455 §1.3; its SHA-1/GUID accept value is
/// the fixed vector below, so a raw handshake can check the server's accept
/// computation instead of trusting URLSession.
let rfc6455SampleKey = "dGhlIHNhbXBsZSBub25jZQ=="
/// RFC 6455 §1.3: base64(SHA-1("dGhlIHNhbXBsZSBub25jZQ==" + GUID)).
let rfc6455SampleAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

/// One parsed HTTP upgrade response from the raw client.
struct RawWebSocketHandshake {
    var status: Int
    /// Header names are lowercased.
    var headers: [String: String]

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

final class RawWebSocketClient {
    let tcp: RawTCPClient
    let host: String
    let port: UInt16
    let token: String

    init(endpoint: LoopbackEndpoint) {
        self.host = "127.0.0.1"
        self.port = UInt16(endpoint.baseURL.port ?? 80)
        self.token = endpoint.token
        self.tcp = RawTCPClient(port: UInt16(endpoint.baseURL.port ?? 80))
    }

    func connectAndHandshake(key: String = rfc6455SampleKey) async throws -> RawWebSocketHandshake {
        try await tcp.connect()
        var request = Data("GET /channel?token=\(token) HTTP/1.1\r\n".utf8)
        request.append(Data("Host: \(host):\(port)\r\n".utf8))
        request.append(Data("Upgrade: websocket\r\n".utf8))
        request.append(Data("Connection: Upgrade\r\n".utf8))
        request.append(Data("Sec-WebSocket-Key: \(key)\r\n".utf8))
        request.append(Data("Sec-WebSocket-Version: 13\r\n".utf8))
        let origin = "http://" + host + ":" + String(port)
        request.append(Data("Origin: \(origin)\r\n\r\n".utf8))
        try await tcp.send(request)
        let response = try await tcp.readUntil(Data("\r\n\r\n".utf8))
        let lines = String(decoding: response, as: UTF8.self)
            .components(separatedBy: "\r\n")
        guard let line = lines.first,
              let status = line.split(separator: " ").dropFirst().first,
              let code = Int(status) else {
            throw HTTPTestError.notHTTP
        }
        var headers: [String: String] = [:]
        for headerLine in lines.dropFirst() {
            guard let colon = headerLine.firstIndex(of: ":") else { continue }
            let name = headerLine[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = headerLine[headerLine.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return RawWebSocketHandshake(status: code, headers: headers)
    }

    func sendFrame(fin: Bool, opcode: UInt8, payload: Data,
                   masked: Bool = true) async throws {
        var frame = Data()
        frame.append((fin ? 0x80 : 0x00) | opcode)
        let maskBit: UInt8 = masked ? 0x80 : 0x00
        if payload.count < 126 {
            frame.append(maskBit | UInt8(payload.count))
        } else {
            frame.append(maskBit | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        if masked {
            let mask: [UInt8] = [0x11, 0x22, 0x33, 0x44]
            frame.append(contentsOf: mask)
            var maskedPayload = payload
            maskedPayload.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for index in 0..<bytes.count { bytes[index] ^= mask[index % 4] }
            }
            frame.append(maskedPayload)
        } else {
            frame.append(payload)
        }
        try await tcp.send(frame)
    }

    struct RawFrame {
        var fin: Bool
        var opcode: UInt8
        var payload: Data
    }

    func receiveFrame() async throws -> RawFrame {
        let header = try await tcp.readExactly(2)
        let first = header[header.startIndex]
        let second = header[header.index(after: header.startIndex)]
        let fin = first & 0x80 != 0
        let opcode = first & 0x0F
        var length = Int(second & 0x7F)
        if length == 126 {
            let extended = try await tcp.readExactly(2)
            length = (Int(extended[extended.startIndex]) << 8)
                | Int(extended[extended.index(after: extended.startIndex)])
        } else if length == 127 {
            let extended = try await tcp.readExactly(8)
            var value: UInt64 = 0
            for byte in extended { value = (value << 8) | UInt64(byte) }
            length = Int(value)
        }
        let masked = second & 0x80 != 0
        var mask = [UInt8]()
        if masked {
            let key = try await tcp.readExactly(4)
            mask = Array(key)
        }
        var payload = try await tcp.readExactly(length)
        if masked && !mask.isEmpty {
            payload.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for index in 0..<bytes.count { bytes[index] ^= mask[index % 4] }
            }
        }
        return RawFrame(fin: fin, opcode: opcode, payload: payload)
    }

    func close() {
        tcp.close()
    }
}

// MARK: - Big-endian helpers

func bigEndianBytes<T: FixedWidthInteger>(_ value: T) -> Data {
    var bigEndian = value.bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}

func rawFrameHeader(type: UInt8, seq: UInt64, length: UInt32) -> Data {
    var data = Data([0x5A, 0x4C, type, 0x00])
    data.append(bigEndianBytes(seq))
    data.append(bigEndianBytes(length))
    return data
}


func rawMutationPayload(mseq: UInt64, op: UInt8 = 1, mode: UInt32 = 0o644,
                        mflags: UInt8 = 1, appendFrom: UInt64 = 0,
                        path: String, data: Data = Data()) -> Data {
    var payload = bigEndianBytes(mseq)
    payload.append(op)
    payload.append(bigEndianBytes(mode))
    payload.append(mflags)
    payload.append(bigEndianBytes(appendFrom))
    let pathBytes = Data(path.utf8)
    payload.append(bigEndianBytes(UInt16(pathBytes.count)))
    payload.append(pathBytes)
    payload.append(bigEndianBytes(UInt32(data.count)))
    payload.append(data)
    return payload
}
