// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2 fix regression: the host abort drain.
//
// This is the component-level half of the G2-A08 regression, next to the
// catalog-driven scenario test in `PhoneDSHScenarioAbortJournalTests`.
// It uses the real `PhoneDSHHost` + real loopback origin + a scripted Worker
// over the real ordered-channel frames, but no WebKit and no model: the Worker
// holds an open DSH turn exactly the way the pinned runtime does while a model
// stream is pending, and journals `turn/end` only when it receives
// `session/cancel`.
//
// Before the fix the host drained the in-flight API exchanges, closed the epoch
// and tore the channel down without ever sending or verifying the cancel: the
// session journal stayed on `step/start`. The regression therefore reproduces
// the whole abort class without depending on a wall clock or a visible page.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSHController
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHWire
@testable import PhoneDSHScenario

// MARK: - Temporary workspace and bundle

private struct AbortFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-abort-host-\(UUID().uuidString)", isDirectory: true)
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

    func configuration(drainDeadline: TimeInterval) throws -> PhoneDSHConfiguration {
        let origin = try XCTUnwrap(URL(string: "http://127.0.0.1:1"))
        return PhoneDSHConfiguration(workspaceRoot: workspace,
                                     token: "abort-journal-token",
                                     origin: origin,
                                     bundle: bundle,
                                     drainDeadline: drainDeadline,
                                     helloTimeout: 10)
    }

    func sessionJournal() -> URL {
        workspace.appendingPathComponent("materialized")
            .appendingPathComponent("home")
            .appendingPathComponent("sessions")
            .appendingPathComponent("--dsh-workspace--")
            .appendingPathComponent("session-regression")
            .appendingPathComponent("session.v4.jsonl")
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - JSON access

private extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members[key]
    }

    var abortString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

// MARK: - Scripted Worker

/// The scripted Worker side of the ordered channel for the abort regression.
///
/// It answers `session/create` / `session/prompt` / `session/cancel` like the
/// pinned DSH Remote surface and mirrors the session journal through real
/// `0x10 VFS_MUT` frames. `writesTerminalOnCancel == false` models the failure
/// the fix must surface loud: the cancel RPC is answered but the session layer
/// never closes the turn.
///
/// `jamsCancelLane == true` models the G2-FIX-105 failure: a blocked job owns
/// the execution channel, so the Worker never runs the `session/cancel` RPC and
/// can never journal a terminal turn. Its own abort path then runs only after
/// the host terminates the Worker: the fresh incarnation (`connect`) closes the
/// interrupted turn itself, exactly like the pinned DSH session layer repairing
/// the stored session before it serves the next request. The host only reads
/// the journal; no Swift test code writes a DSH session record.
private actor AbortJournalWorker {
    private let writesTerminalOnCancel: Bool
    private let completesTurnOnPrompt: Bool
    private let jamsCancelLane: Bool
    private let writesTerminalOnWorkerRestart: Bool
    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var methods: [String] = []
    private var sessionText = ""
    private var workerHelloSent = false
    private var connectionToken = UUID()
    private var connectionCount = 0
    private var pendingAbortOnReconnect = false
    private var wroteTerminalOnReconnect = false

    init(writesTerminalOnCancel: Bool = true,
         completesTurnOnPrompt: Bool = false,
         jamsCancelLane: Bool = false,
         writesTerminalOnWorkerRestart: Bool = false) {
        self.writesTerminalOnCancel = writesTerminalOnCancel
        self.completesTurnOnPrompt = completesTurnOnPrompt
        self.jamsCancelLane = jamsCancelLane
        self.writesTerminalOnWorkerRestart = writesTerminalOnWorkerRestart
    }

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        connectionCount += 1
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw AbortJournalError.failed("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else {
            throw AbortJournalError.failed("bad channel URL")
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
        self.decoder = FrameDecoder()
        self.sendSeq = 0
        self.workerHelloSent = false
        self.connectionToken = UUID()
        let token = self.connectionToken
        receiveTask = Task { await self.receiveLoop(task, token: token) }
    }

    func disconnect() {
        cancelConnection()
    }

    /// Terminates this Worker incarnation (the WebContent/Worker stop the host
    /// escalates to). The blocked execution lane dies with it; if a turn is
    /// open, the session layer marks that its own abort path must close the
    /// turn in the fresh incarnation.
    func terminateForEscalation() {
        if writesTerminalOnWorkerRestart,
           sessionText.contains("\"turn/start\""),
           !sessionText.contains("\"turn/end\"") {
            pendingAbortOnReconnect = true
        }
        cancelConnection()
    }

    private func cancelConnection() {
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sendSeq = 0
    }

    // MARK: Observation

    func unaryMethods() -> [String] { methods }

    func journal() -> String { sessionText }

    func connectionTotal() -> Int { connectionCount }

    /// Whether the Worker's own abort path closed the turn after termination.
    func terminalWrittenOnReconnect() -> Bool { wroteTerminalOnReconnect }

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
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: return
            }
            guard let frames = try? decoder.feed(data) else { return }
            for frame in frames {
                do {
                    try await handle(frame)
                } catch {
                    return
                }
            }
        }
    }

    private func handle(_ frame: Frame) async throws {
        switch frame.type {
        case .hello:
            if !workerHelloSent {
                try await sendWorkerHello()
            }
        case .apiRequest:
            let request = try ApiRequestFrame.decode(frame.payload)
            try await respond(to: request)
        default:
            break
        }
    }

    private func sendWorkerHello() async throws {
        guard let configuration else {
            throw AbortJournalError.failed("never connected")
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
        workerHelloSent = true
        try await enqueueJSON(.hello, hello)
        if pendingAbortOnReconnect {
            // The terminated Worker's session layer owns this record: the fresh
            // incarnation closes the turn it inherited from the stored journal
            // before it serves any request, so Swift never synthesizes it.
            pendingAbortOnReconnect = false
            wroteTerminalOnReconnect = true
            let now = Self.nowMillis()
            try await appendSession(
                Self.record("step/end", seq: 2, time: now,
                            data: #"{"turn":1,"step":1}"#)
                    + Self.record("turn/end", seq: 3, time: now,
                                  data: #"{"turn":1,"reason":{"kind":"aborted"}}"#))
        }
    }

    // MARK: Remote API

    private func respond(to request: ApiRequestFrame) async throws {
        if request.head.path == PhoneDSHDescendantDrainProtocol.path {
            try await respondDescendantDrain(request)
            return
        }
        var rpcID = ""
        var method = ""
        if let envelope = try? JSONValue.parse(request.body) {
            rpcID = envelope["rpcId"]?.abortString ?? ""
            method = envelope["method"]?.abortString ?? ""
        }
        methods.append(method)
        let now = Self.nowMillis()
        switch method {
        case "session/create":
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object(["sessionId": .string("session-regression")]))
        case "session/prompt":
            try await appendSession(
                Self.record("turn/start", seq: 0, time: now,
                            data: #"{"turn":1}"#)
                    + Self.record("step/start", seq: 1, time: now,
                                  data: #"{"turn":1,"step":1}"#))
            if completesTurnOnPrompt {
                try await appendSession(
                    Self.record("step/end", seq: 2, time: now,
                                data: #"{"turn":1,"step":1}"#)
                        + Self.record("turn/end", seq: 3, time: now,
                                      data: #"{"turn":1,"reason":{"kind":"completed"}}"#))
            }
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object([:]))
        case "session/cancel":
            if jamsCancelLane {
                // A blocked job owns the execution lane: the RPC is never
                // processed and no journal record (terminal or not) is written.
                // The request stays unanswered until the connection dies.
                return
            }
            if writesTerminalOnCancel {
                try await writeSession(
                    Self.record("step/end", seq: 2, time: now,
                                data: #"{"turn":1,"step":1}"#)
                        + Self.record("turn/end", seq: 3, time: now,
                                      data: #"{"turn":1,"reason":{"kind":"aborted"}}"#))
            }
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object([:]))
        default:
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        }
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// One DSH v4 JSONL record; `data` is the record's `data` object.
    private static func record(_ type: String, seq: Int, time: Int64,
                               data: String) -> String {
        "{\"type\":\"\(type)\",\"seq\":\(seq),\"time\":\(time),\"data\":\(data)}\n"
    }

    private func respondUnary(_ request: ApiRequestFrame, rpcID: String,
                              value: JSONValue) async throws {
        let response = JSONValue.object([
            "type": .string("server-response"),
            "rpcId": .string(rpcID),
            "result": .object(["ok": .bool(true), "value": value]),
        ])
        try await enqueueFrame(.apiResponse,
                               payload: try ApiResponseFrame(
                                reqID: request.reqID,
                                head: ApiResponseHead(status: 200, headers: [
                                    "content-type": "application/json",
                                ]),
                                body: try response.encoded()).encoded())
        try await enqueueFrame(.apiEnd,
                               payload: ApiEndFrame(reqID: request.reqID).encoded())
    }

    /// Answers the phone-only scoped descendant-drain route. These component
    /// tests have no spawned child; the route still returns the exact requested
    /// roots so the host's mandatory route call succeeds.
    private func respondDescendantDrain(_ request: ApiRequestFrame) async throws {
        var roots: [String] = []
        if let object = try? JSONValue.parse(request.body),
           case .object(let members) = object,
           let ids = members["sessionIds"],
           case .array(let values) = ids {
            roots = values.compactMap { $0.abortString }
        }
        let receipt = JSONValue.object([
            "protocol": .string(PhoneDSHDescendantDrainProtocol.receiptProtocol),
            "roots": .array(roots.map { .string($0) }),
            "missing": .array([]),
            "descendants": .array([]),
            "durationMs": .number(0),
        ])
        let envelope = JSONValue.object([
            "ok": .bool(true),
            "value": receipt,
        ])
        try await enqueueFrame(.apiResponse,
                               payload: try ApiResponseFrame(
                                reqID: request.reqID,
                                head: ApiResponseHead(status: 200, headers: [
                                    "content-type": "application/json",
                                ]),
                                body: try envelope.encoded()).encoded())
        try await enqueueFrame(.apiEnd,
                               payload: ApiEndFrame(reqID: request.reqID).encoded())
    }

    // MARK: Journal mirroring

    private func header() -> String {
        #"{"type":"session","version":4,"id":"session-regression","cwd":"/dsh/workspace"}"# + "\n"
    }

    private func appendSession(_ suffix: String) async throws {
        sessionText = header() + sessionText + suffix
        try await writeSession(sessionText)
    }

    private func writeSession(_ text: String) async throws {
        let mseq = lastMseq + 1
        let body = VfsMutationBody(op: .write, mode: 0o644,
                                   mflags: [.entryChanged], appendFrom: 0,
                                   path: "/dsh/home/sessions/--dsh-workspace--/session-regression/session.v4.jsonl",
                                   data: Data(text.utf8))
        try await enqueueFrame(.vfsMutation,
                               payload: try VfsMutationPayload.encode(mseq: mseq, body: body))
        lastMseq = mseq
    }

    // MARK: Frame sends

    private func enqueueJSON<T: Encodable>(_ type: FrameType, _ value: T) async throws {
        try await enqueueFrame(type, payload: try CanonicalJSON.encode(value))
    }

    private func enqueueFrame(_ type: FrameType, payload: Data) async throws {
        guard let task else { throw AbortJournalError.failed("channel is closed") }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq, payload: payload)
        try await task.send(.data(encoded))
    }

    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private enum AbortJournalError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Scripted engine

private final class AbortJournalEngine: WebEngineControlling,
                                       WebEngineRestartRequesting,
                                       @unchecked Sendable {
    let worker: AbortJournalWorker
    private let lock = NSLock()
    private var configuration: WebEngineConfiguration?
    private var restarts = 0
    private var reasons: [WebEngineRestartReason] = []

    init(worker: AbortJournalWorker) {
        self.worker = worker
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        var configuration = configuration
        if configuration.bootID == nil {
            configuration.bootID = Self.makeBootID()
        }
        lock.lock()
        self.configuration = configuration
        lock.unlock()
        try await worker.connect(configuration)
    }

    func restart() async throws {}

    /// The bounded escalation lever: terminate the old Worker/WebContent and
    /// bring up a fresh one. The scripted Worker's own abort path journals the
    /// terminal turn from inside the new incarnation.
    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        let bootID = Self.makeBootID()
        lock.lock()
        restarts += 1
        reasons.append(reason)
        var configuration = self.configuration
        if configuration != nil { configuration?.bootID = bootID }
        self.configuration = configuration
        lock.unlock()
        await worker.terminateForEscalation()
        if let configuration {
            try await worker.connect(configuration)
        }
        return WebEngineRestartReport(reason: reason,
                                      bootID: bootID,
                                      duration: .zero)
    }

    func restartCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return restarts
    }

    func restartReasons() -> [WebEngineRestartReason] {
        lock.lock()
        defer { lock.unlock() }
        return reasons
    }

    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Collects the host error events the scenario recorder turns into report
/// `console_errors` (the same single event sequence).
private actor AbortEventSink {
    private var messages: [String] = []

    func consume(_ stream: AsyncStream<PhoneDSHEvent>) async {
        for await event in stream {
            if case .error(let message) = event {
                messages.append(message)
            }
        }
    }

    func errors() -> [String] { messages }
}

// MARK: - Tests

final class PhoneDSHScenarioAbortHostTests: XCTestCase {
    /// G2-FIX-Q3: this suite exists to prove the abort drain ends a turn
    /// cleanly. A batch/tooling cleanup that sends SIGTERM/SIGINT/SIGHUP to
    /// the test process used to truncate the log mid-suite (no crash report,
    /// no XCTest summary, gate exit 1). The guard records the request so the
    /// drain still completes and the loss is reported as an XCTest failure.
    override class func setUp() {
        super.setUp()
        ScenarioProcessSignals.install()
    }

    override func setUp() {
        super.setUp()
        ScenarioProcessSignals.install()
    }

    /// Fails the test when an external stop request reached the process while
    /// the abort drain was in flight, instead of letting the run end silently.
    private func assertNoExternalStop(file: StaticString = #filePath,
                                      line: UInt = #line) {
        guard let signal = ScenarioProcessSignals.takeSignal() else { return }
        XCTFail("the test process received \(ScenarioProcessSignals.name(of: signal)) "
            + "from outside the scenario while the abort drain was in flight; the harness "
            + "must report the external stop as this assertion instead of dying silently",
            file: file, line: line)
    }

    /// Waits, bounded, for the event sink's consumer task to drain the host
    /// event stream.
    ///
    /// The host publishes the fail-loud error synchronously into the ordered
    /// event bus, but the test consumes that bus from a task; under full-suite
    /// load the cooperative pool can schedule the consumer after `stop()`
    /// returns. The error must still arrive (the assertion below checks that),
    /// so the test waits for delivery instead of asserting on the consumer's
    /// scheduling state with zero-bound patience.
    private func waitForSinkErrors(_ sink: AbortEventSink,
                                   containing needle: String,
                                   timeout: TimeInterval = 10) async -> [String] {
        let deadline = Date().addingTimeInterval(timeout)
        var errors = await sink.errors()
        while Date() < deadline {
            if errors.contains(where: { $0.contains(needle) }) { return errors }
            try? await Task.sleep(nanoseconds: 20_000_000)
            errors = await sink.errors()
        }
        return errors
    }

    private func startHost(fixture: AbortFixture,
                           worker: AbortJournalWorker,
                           drainDeadline: TimeInterval) async throws -> PhoneDSHHost {
        try await startHostWithEngine(fixture: fixture, worker: worker,
                                      drainDeadline: drainDeadline).0
    }

    private func startHostWithEngine(fixture: AbortFixture,
                                     worker: AbortJournalWorker,
                                     drainDeadline: TimeInterval)
        async throws -> (PhoneDSHHost, AbortJournalEngine) {
        let configuration = try fixture.configuration(drainDeadline: drainDeadline)
        let engine = AbortJournalEngine(worker: worker)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()
        return (host, engine)
    }

    private func openTurn(host: PhoneDSHHost) async throws -> String {
        let harness = try await host.harness()
        let session = try await harness.openSession(
            HarnessSessionRequest(workspace: "/dsh/workspace"))
        try await harness.send(
            .prompt(text: "This model stream never completes.",
                    attachments: [], requestID: "abort-regression-1"),
            to: session.id)
        return session.id
    }

    private func waitForOpenJournal(_ fixture: AbortFixture) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while true {
            try ScenarioProcessSignals.throwIfTerminationRequested()
            let text = (try? String(decoding: Data(
                contentsOf: fixture.sessionJournal()), as: UTF8.self)) ?? ""
            if text.contains("\"turn/start\"") { return text }
            if Date() >= deadline {
                throw AbortJournalError.failed("the scripted session never journaled turn/start")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Before the fix this test fails: the host parks without ever sending
    /// `session/cancel`, so the journal keeps the open turn.
    func testStopCancelsTheOpenTurnAndWaitsForTheTerminalJournalRecord() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let worker = AbortJournalWorker()
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 3)
        let sessionID = try await openTurn(host: host)
        XCTAssertEqual(sessionID, "session-regression")
        _ = try await waitForOpenJournal(fixture)

        try await host.stop()
        assertNoExternalStop()

        let methods = await worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the abort drain must deliver session/cancel; methods: \(methods)")
        let materialized = try Data(contentsOf: fixture.sessionJournal())
        let state = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertTrue(state.hasTerminalTurn,
                      "the session journal still has an open turn: \(state)")
        XCTAssertEqual(state.lastRecordType, "turn/end")
        XCTAssertEqual(state.lastTurnEndReason, "aborted")
        let hostState = await host.state
        XCTAssertEqual(hostState, .stopped)
    }

    /// A completed turn needs no cancel; the drain must not invent one.
    func testStopDoesNotCancelACompletedTurn() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let worker = AbortJournalWorker(completesTurnOnPrompt: true)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 3)
        try await openTurn(host: host)
        _ = try await waitForOpenJournal(fixture)

        try await host.stop()
        assertNoExternalStop()

        let methods = await worker.unaryMethods()
        XCTAssertFalse(methods.contains("session/cancel"),
                       "a terminal turn must not be cancelled; methods: \(methods)")
        let state = PhoneDSHSessionLog.state(
            of: try Data(contentsOf: fixture.sessionJournal()))
        XCTAssertTrue(state.hasTerminalTurn)
        XCTAssertEqual(state.lastTurnEndReason, "completed")
    }

    /// The window expiring without a terminal record is fail loud: the host
    /// throws, the error is published, and the journal is never fabricated.
    func testStopFailsLoudWhenNoTerminalRecordArrives() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let worker = AbortJournalWorker(writesTerminalOnCancel: false)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 2)
        let sink = AbortEventSink()
        let sinkTask = Task { await sink.consume(host.eventStream()) }
        try await openTurn(host: host)
        _ = try await waitForOpenJournal(fixture)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? "stop() returned without error"
        XCTAssertTrue(message.contains("open turn"),
                      "the fail-loud error must name the open turn: \(message)")
        XCTAssertTrue(message.contains("terminal turn/end"),
                      "the fail-loud error must name the missing terminal record: \(message)")
        let errors = await waitForSinkErrors(sink, containing: "open turn")
        XCTAssertTrue(errors.contains { $0.contains("open turn") },
                      "the fail-loud error must reach the host event stream the report "
                          + "recorder consumes; events: \(errors)")
        sinkTask.cancel()
        let methods = await worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the failed drain still delivered the cancel: \(methods)")
        let state = PhoneDSHSessionLog.state(
            of: (try? Data(contentsOf: fixture.sessionJournal())) ?? Data())
        XCTAssertTrue(state.isTurnOpen,
                      "the host must not fabricate a turn/end record: \(state)")
        assertNoExternalStop()
    }

    /// The runner consumes the one host event sequence and stops that consumer
    /// immediately after `host.stop()` returns (`ScenarioRun.execute`).
    ///
    /// The fail-loud error must already be in the recorder's `console_errors`
    /// at that point; if the report only saw it after a later pump, the
    /// fail-loud contract would be silently lost on the exact path that needs
    /// it. This drives the same order as the runner.
    func testStopFailureIsRecordedBeforeTheRunnerStopsTheRecorder() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let worker = AbortJournalWorker(writesTerminalOnCancel: false)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 2)
        let recorder = ScenarioRecorder()
        recorder.attach(host: host)
        _ = try await openTurn(host: host)
        _ = try await waitForOpenJournal(fixture)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        // Exactly the runner's order: read the report fields only after stop
        // returned, then cancel the recorder.
        recorder.stop()
        XCTAssertNotNil(failure, "the host must throw on a missing terminal record")
        XCTAssertTrue(recorder.consoleErrors.contains { $0.contains("open turn") },
                      "the fail-loud error must already be in the recorder's console_errors "
                          + "when host.stop() returns; got \(recorder.consoleErrors)")
        assertNoExternalStop()
    }

    /// The abort drain is released by the Worker's terminal journal record;
    /// the configured drain window is only the D3/D14 fail-loud deadline, not
    /// a wait cadence.
    ///
    /// A regression that waited for the window (or a fixed timer) instead of
    /// the cancel round trip shows up here as a `stop()` near the deadline.
    /// The margin is wide so CI scheduling noise cannot make it flaky.
    ///
    /// This file is also the scenario target's host-dispatch anchor: it is the
    /// only scenario test that calls through the `PhoneDSHHost` actor vtable,
    /// so a landing that changes that actor must rebuild this object. A reused
    /// integration worktree kept an object compiled against the pre-G2-FIX-84
    /// vtable and jumped through the old offset into `completeDrain` with an
    /// incompatible async frame (G2-FIX-83 P0). Keeping a test change next to
    /// the host dispatch keeps this object in step with the host.
    func testStopResolvesTheOpenTurnWithoutWaitingForTheDrainDeadline() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let drainDeadline: TimeInterval = 10
        let worker = AbortJournalWorker()
        let host = try await startHost(fixture: fixture, worker: worker,
                                       drainDeadline: drainDeadline)
        _ = try await openTurn(host: host)
        _ = try await waitForOpenJournal(fixture)

        let started = Date()
        try await host.stop()
        let elapsed = Date().timeIntervalSince(started)
        let state = PhoneDSHSessionLog.state(
            of: try Data(contentsOf: fixture.sessionJournal()))
        XCTAssertTrue(state.hasTerminalTurn,
                      "the cancel did not close the turn: \(state)")
        XCTAssertLessThan(elapsed, drainDeadline / 2,
                          "stop() waited \(elapsed) s of the \(drainDeadline) s drain "
                              + "window; the terminal journal record must release the "
                              + "drain, not the deadline")
    }

    /// G2-FIX-105: a Worker that cannot run `session/cancel` inside the drain
    /// window (a blocked interpreter job owns the execution channel) must be
    /// escalated, not merely reported.
    ///
    /// The drain sends the cancel RPC; this Worker never processes it and never
    /// journals. At its bounded escalation point the host terminates the
    /// Worker/WebContent; the fresh incarnation's own abort path closes the
    /// interrupted turn with `turn/end {reason:{kind:'aborted'}}`, and the host
    /// verifies that terminal record before the Draining transition completes.
    ///
    /// Pre-fix this test fails at `host.stop()` with the "still have an open
    /// turn" error and the journal keeps the open turn (`lastTurnEndReason` is
    /// nil); post-fix `stop()` returns, the materialized journal ends on
    /// `turn/end aborted`, and the escalation is observable on the fake engine.
    func testDrainEscalatesAJammedWorkerAndVerifiesItsTerminalTurn() async throws {
        let fixture = try AbortFixture()
        defer { fixture.cleanup() }
        let drainDeadline: TimeInterval = 4
        let worker = AbortJournalWorker(jamsCancelLane: true,
                                        writesTerminalOnWorkerRestart: true)
        let (host, engine) = try await startHostWithEngine(
            fixture: fixture, worker: worker, drainDeadline: drainDeadline)
        let sink = AbortEventSink()
        let sinkTask = Task { await sink.consume(host.eventStream()) }
        _ = try await openTurn(host: host)
        _ = try await waitForOpenJournal(fixture)

        let started = Date()
        try await host.stop()
        let elapsed = Date().timeIntervalSince(started)

        let materialized = try Data(contentsOf: fixture.sessionJournal())
        let state = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertTrue(state.hasTerminalTurn,
                      "the escalated drain must leave a terminal DSH turn: \(state)")
        XCTAssertNil(state.openTurn)
        XCTAssertEqual(state.lastRecordType, "turn/end")
        XCTAssertEqual(state.lastTurnEndReason, "aborted",
                       "the session layer must journal the abort itself, not Swift")
        let hostState = await host.state
        let restartCount = engine.restartCount()
        let restartReasons = engine.restartReasons()
        let workerWroteTerminal = await worker.terminalWrittenOnReconnect()
        let workerJournal = await worker.journal()
        let connectionTotal = await worker.connectionTotal()
        let methods = await worker.unaryMethods()
        let errors = await sink.errors()
        XCTAssertEqual(hostState, .stopped)
        XCTAssertGreaterThanOrEqual(restartCount, 1,
                                    "the drain must terminate the jammed Worker instead of "
                                        + "only recording a host-state error")
        XCTAssertEqual(restartReasons.last, .webContentTerminated)
        XCTAssertGreaterThanOrEqual(connectionTotal, 2,
                                    "the escalation must boot a fresh Worker incarnation")
        XCTAssertTrue(workerWroteTerminal,
                      "the terminal record must be written by the Worker during its own "
                          + "abort path after termination")
        XCTAssertEqual(String(decoding: materialized, as: UTF8.self), workerJournal,
                       "the materialized session log must be exactly the Worker-authored "
                           + "journal; Swift may not synthesize session events")
        XCTAssertGreaterThanOrEqual(methods.filter { $0 == "session/cancel" }.count, 2,
                                    "the drain must re-drive the cancel on the fresh Worker "
                                        + "after escalation; methods: \(methods)")
        XCTAssertFalse(errors.contains { $0.contains("open turn") },
                       "the escalated drain must not end in the open-turn failure: \(errors)")
        XCTAssertLessThan(elapsed, drainDeadline + 1,
                          "the escalation must stay inside the drain window "
                              + "(elapsed \(elapsed) s of \(drainDeadline) s)")
        sinkTask.cancel()
    }

    /// The terminate/reboot escalation is bounded by the same D14 window it
    /// consumes: a cooperative cancel first, then one bounded escalation area,
    /// then the teardown reserve. No phase can extend past the controller's
    /// deadline (G2-FIX-105).
    func testDrainEscalationPlanSplitsTheWindowStrictly() {
        let now = Date()
        let deadline = now.addingTimeInterval(20)
        let plan = DrainEscalationPlan(deadline: deadline, window: 20)
        XCTAssertLessThan(plan.verifyDeadline, deadline,
                          "the journal wait must leave a teardown reserve")
        XCTAssertLessThan(plan.escalationDeadline, plan.verifyDeadline,
                          "the escalation area must end before the journal deadline")
        XCTAssertFalse(plan.shouldEscalate(now: now, attempts: 0),
                       "the cooperative cancel gets the first phase")
        XCTAssertTrue(plan.shouldEscalate(now: plan.escalationDeadline, attempts: 0))
        XCTAssertFalse(plan.shouldEscalate(
            now: plan.escalationDeadline,
            attempts: DrainEscalationPlan.maximumWorkerTerminations),
                       "the bounded retry must stop at its budget")
        XCTAssertFalse(plan.shouldEscalate(now: plan.verifyDeadline, attempts: 0),
                       "a failed escalation must fail loud at the journal deadline")
        let cancelBudget = plan.cancelBudget(now: now)
        XCTAssertGreaterThan(cancelBudget, 0)
        XCTAssertLessThanOrEqual(cancelBudget, 2)
        XCTAssertLessThan(now.addingTimeInterval(cancelBudget),
                          plan.escalationDeadline.addingTimeInterval(0.01),
                          "a cooperative cancel may not eat the escalation area")

        // A short window still yields a strictly ordered, positive budget.
        let shortDeadline = now.addingTimeInterval(3)
        let short = DrainEscalationPlan(deadline: shortDeadline, window: 3)
        XCTAssertGreaterThan(short.escalationDeadline, now)
        XCTAssertLessThan(short.escalationDeadline, short.verifyDeadline)
        XCTAssertLessThan(short.verifyDeadline, shortDeadline)
    }
}
