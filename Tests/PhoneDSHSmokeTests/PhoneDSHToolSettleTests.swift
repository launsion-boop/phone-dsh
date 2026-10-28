// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-84 component regression: tool-call settle on
// the abort drain.
//
// The G2-A09/G2-A10 failure class: the host drain waited only for in-flight
// 0x40 API exchanges. When the runner's budget cut the run mid-tool-call, the
// session turn could close while the D13 step stayed at `tool_dispatched` and
// the tool journal kept a `start` without an end. The fix has two halves:
//
//   * Worker side: `tool-journal` races the dispatch against the abort signal
//     and writes the terminal `done` record even when the command does not
//     cooperate (see `plugins/tests/tool-cancel-settle.test.ts`).
//   * Host side (this file): the abort drain waits, inside its own deadline,
//     for every in-flight step of the drained sessions to reach `journaled`,
//     and fails loud when it never arrives instead of parking on the
//     half-state.
//
// This test uses the real `PhoneDSHHost`, the real loopback origin, the real
// ordered-channel frames and the real `StepMachine`; a scripted Worker stands
// in for the WebKit runtime so the timing of the journal end is deterministic.
//
// Gate selection: the class name starts with `PhoneDSH` and contains
// `PhoneDSHSmoke`, so the task gate `swift test --filter PhoneDSHSmoke` and
// both repository Swift gates (`--filter 'PhoneDSH'` and
// `--filter 'PhoneDSH|PhoneDSHShell'`) select this regression.
// The same convention is documented in
// `PhoneDSHScenarioAbortJournalTests.swift`.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHHarness
import PhoneDSHWire

// MARK: - Fixture

private struct ToolSettleFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-tool-settle-\(UUID().uuidString)", isDirectory: true)
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
                                     token: "tool-settle-token",
                                     origin: origin,
                                     bundle: bundle,
                                     drainDeadline: drainDeadline,
                                     helloTimeout: 10)
    }

    var sessionJournal: URL {
        workspace.appendingPathComponent("materialized")
            .appendingPathComponent("home")
            .appendingPathComponent("sessions")
            .appendingPathComponent("--dsh-workspace--")
            .appendingPathComponent("session-regression")
            .appendingPathComponent("session.v4.jsonl")
    }

    var stepLog: URL {
        workspace.appendingPathComponent("steps")
            .appendingPathComponent("session-regression.ndjson")
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

    var settleString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private enum ToolSettleError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Scripted Worker

/// The Worker side of the abort drain for the tool-call settle regression.
///
/// It mirrors a live DSH session the same way the pinned runtime does: the
/// session log and the tool journal both arrive as real channel frames. The
/// tool-journal end is deliberately delayed past the host's short post-turn
/// settle so the old drain (which only waited for the turn/end) would park
/// while the D13 step was still `tool_dispatched`.
private actor ToolSettleWorker {
    private let settlesTool: Bool
    private let journalEndDelay: TimeInterval
    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var lastJseq: UInt64 = 0
    private var methods: [String] = []
    private var lifecycleStopCount = 0
    private var sessionText = ""
    private var workerHelloSent = false
    private var connectionToken = UUID()

    init(settlesTool: Bool = true, journalEndDelay: TimeInterval = 0) {
        self.settlesTool = settlesTool
        self.journalEndDelay = journalEndDelay
    }

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw ToolSettleError.failed("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else { throw ToolSettleError.failed("bad channel URL") }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        task.resume()
        self.session = session
        self.task = task
        self.decoder = FrameDecoder()
        self.sendSeq = 0
        self.lastMseq = 0
        self.lastJseq = 0
        self.sessionText = ""
        self.methods = []
        self.workerHelloSent = false
        self.connectionToken = UUID()
        let token = self.connectionToken
        receiveTask = Task { await self.receiveLoop(task, token: token) }
    }

    func disconnect() {
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

    func unaryMethods() -> [String] { methods }

    func lifecycleStops() -> Int { lifecycleStopCount }

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
            if !workerHelloSent { try await sendWorkerHello() }
        case .apiRequest:
            let request = try ApiRequestFrame.decode(frame.payload)
            try await respond(to: request)
        case .lifecycle:
            if let object = try? JSONSerialization.jsonObject(with: frame.payload),
               let payload = object as? [String: Any],
               payload["state"] as? String == "stop" {
                lifecycleStopCount += 1
            }
        default:
            break
        }
    }

    private func sendWorkerHello() async throws {
        guard let configuration else { throw ToolSettleError.failed("never connected") }
        let fence = configuration.fence ?? WebEngineFence()
        let bootID = configuration.bootID ?? UUID().uuidString
            .replacingOccurrences(of: "-", with: "").lowercased()
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
            rpcID = envelope["rpcId"]?.settleString ?? ""
            method = envelope["method"]?.settleString ?? ""
        }
        methods.append(method)
        let now = Self.nowMillis()
        switch method {
        case "session/create":
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object(["sessionId": .string("session-regression")]))
        case "session/prompt":
            try await appendSession(
                Self.record("turn/start", seq: 0, time: now, data: #"{"turn":1}"#)
                    + Self.record("step/start", seq: 1, time: now,
                                  data: #"{"turn":1,"step":1}"#))
            try await sendJournal(Self.dispatchedRecord())
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        case "session/cancel":
            // The terminal tool result is what DSH writes after the tool body
            // settles (G2-FIX-84's Worker-side half). It is durable before the
            // turn/end, exactly like the real agent loop.
            try await appendSession(
                Self.record("tool/result", seq: 2, time: Self.nowMillis(),
                            data: #"{"turn":1,"step":1,"message":{"role":"tool","toolCallId":"call-1","isError":true,"content":[{"type":"text","text":"Error: tool call aborted (cancel cause: hook/budget)"}]},"error":{"name":"AbortError","code":"ABORTED","reason":"{\"kind\":\"hook\",\"reason\":{\"kind\":\"budget\"}}"}}"#)
                    + Self.record("step/end", seq: 3, time: Self.nowMillis(),
                                  data: #"{"turn":1,"step":1}"#)
                    + Self.record("turn/end", seq: 4, time: Self.nowMillis(),
                                  data: #"{"turn":1,"reason":{"kind":"aborted","reason":{"kind":"hook"}}}"#))
            if settlesTool {
                if journalEndDelay > 0 {
                    try? await Task.sleep(
                        nanoseconds: UInt64(max(0, journalEndDelay) * 1_000_000_000))
                }
                try await sendJournal(Self.completedRecord())
            }
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        default:
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        }
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    private static func record(_ type: String, seq: Int, time: Int64,
                               data: String) -> String {
        "{\"type\":\"\(type)\",\"seq\":\(seq),\"time\":\(time),\"data\":\(data)}\n"
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
            roots = values.compactMap { $0.settleString }
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

    // MARK: Journal frames

    private static let idempotencyKey = "xl1-0123456789abcdef0123456789abcdef"

    private static func dispatchedRecord() -> String {
        #"{"v":1,"t":"start","type":"dispatched","key":"\#(idempotencyKey)","call_id":"call-1","tool":"bash","class":"non-idempotent","args_sha256":"a","schema_sha256":null,"profile":"pdsh-phone/1+test","at":1}"#
    }

    private static func completedRecord() -> String {
        #"{"v":1,"t":"done","type":"completed","key":"\#(idempotencyKey)","call_id":"call-1","result":{"content":[{"type":"text","text":"Error: tool call aborted (cancel cause: hook/budget)"}],"isError":true,"error":{"name":"AbortError","code":"ABORTED","reason":"{\"kind\":\"hook\",\"reason\":{\"kind\":\"budget\"}}"}},"at":2}"#
    }

    private func sendJournal(_ record: String) async throws {
        lastJseq += 1
        let body = JournalBody(jseq: lastJseq,
                               sessionID: "session-regression",
                               record: Data(record.utf8))
        try await enqueueFrame(.journal, payload: try body.encoded())
    }

    // MARK: Session mirror

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
        guard let task else { throw ToolSettleError.failed("channel is closed") }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq, payload: payload)
        try await task.send(.data(encoded))
    }
}

// MARK: - Scripted engine

private final class ToolSettleEngine: WebEngineControlling, @unchecked Sendable {
    let worker: ToolSettleWorker

    init(worker: ToolSettleWorker) {
        self.worker = worker
    }

    var isLockdownModeEnabled: Bool { false }
    var isAttachedWithVisibleArea: Bool { true }

    func load(_ url: URL) async throws {}

    func bootWorker(_ configuration: WebEngineConfiguration) async throws {
        try await worker.connect(configuration)
    }

    func restart() async throws {}
}

/// Collects host error events, the same sequence the scenario recorder reads.
private actor ToolSettleEventSink {
    private var messages: [String] = []

    func consume(_ stream: AsyncStream<PhoneDSHEvent>) async {
        for await event in stream {
            if case .error(let message) = event { messages.append(message) }
        }
    }

    func errors() -> [String] { messages }
}

// MARK: - Tests

final class PhoneDSHSmokeToolSettleTests: XCTestCase {
    private func startHost(fixture: ToolSettleFixture,
                           worker: ToolSettleWorker,
                           drainDeadline: TimeInterval) async throws -> PhoneDSHHost {
        let configuration = try fixture.configuration(drainDeadline: drainDeadline)
        let engine = ToolSettleEngine(worker: worker)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()
        return host
    }

    private func openTurn(host: PhoneDSHHost) async throws {
        let harness = try await host.harness()
        let session = try await harness.openSession(
            HarnessSessionRequest(workspace: "/dsh/workspace"))
        try await harness.send(
            .prompt(text: "Hold the tool call open until the budget cancels the run.",
                    attachments: [], requestID: "tool-settle-1"),
            to: session.id)
    }

    private func waitForSessionStart(_ fixture: ToolSettleFixture) async throws -> String {
        let deadline = Date().addingTimeInterval(5)
        while true {
            let text = (try? String(decoding: Data(contentsOf: fixture.sessionJournal),
                                    as: UTF8.self)) ?? ""
            if text.contains("\"turn/start\"") { return text }
            if Date() >= deadline {
                throw ToolSettleError.failed("the scripted session never journaled turn/start")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func lastStepLine(_ fixture: ToolSettleFixture) throws -> [String: Any] {
        let text = try String(decoding: Data(contentsOf: fixture.stepLog), as: UTF8.self)
        let lines = text.split(separator: "\n").compactMap { line -> [String: Any]? in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return nil }
            return dictionary
        }
        guard let last = lines.last else {
            throw ToolSettleError.failed("no step record was written")
        }
        return last
    }

    private func lastStepState(_ fixture: ToolSettleFixture) throws -> String {
        guard let state = try lastStepLine(fixture)["state"] as? String else {
            throw ToolSettleError.failed("the step record has no state")
        }
        return state
    }

    /// The regression: the host must not report the drain complete while the
    /// D13 step of the cancelled tool call is still `tool_dispatched`. The
    /// journal end arrives after the turn/end (it is a separate 0x30 frame);
    /// the old drain returned in its short post-turn settle and parked on the
    /// half-state.
    func testStopWaitsForTheToolJournalEndBeforeTheDrainCompletes() async throws {
        let fixture = try ToolSettleFixture()
        defer { fixture.cleanup() }
        let worker = ToolSettleWorker(settlesTool: true, journalEndDelay: 4)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 8)
        try await openTurn(host: host)
        let sessionText = try await waitForSessionStart(fixture)
        XCTAssertTrue(sessionText.contains("\"turn/start\""))
        // The dispatched step exists before the cancel; it is the in-flight
        // tool call the drain has to settle.
        while true {
            if (try? lastStepState(fixture)) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try lastStepState(fixture), "tool_dispatched",
                       "the step is in flight before the abort drain")

        try await host.stop()

        let methods = await worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the abort drain delivered session/cancel; methods: \(methods)")
        let lifecycleStops = await worker.lifecycleStops()
        XCTAssertGreaterThan(lifecycleStops, 0,
                             "the abort drain sent LIFECYCLE stop to the Worker tool layer")
        XCTAssertEqual(try lastStepState(fixture), "journaled",
                       "the drain must wait for the terminal journal record and the D13 step it closes")
        let materialized = try String(decoding: Data(contentsOf: fixture.sessionJournal),
                                      as: UTF8.self)
        XCTAssertTrue(materialized.contains("\"tool/result\""),
                      "the session log carries the terminal toolResult")
        XCTAssertTrue(materialized.contains("\"isError\":true"),
                      "the terminal toolResult marks the call as cut off")
        XCTAssertTrue(materialized.contains("hub/budget") || materialized.contains("budget"),
                      "the terminal toolResult preserves the cancellation cause")
        let hostState = await host.state
        XCTAssertEqual(hostState, .stopped)
    }

    /// A Worker that closes the turn but never journals the end must make the
    /// drain fail loud. The host must not park silently with the step still at
    /// `tool_dispatched`; it gives up ownership and closes the D13 record as
    /// `abandoned` before reporting the error.
    func testStopFailsLoudWhenTheToolCallNeverSettles() async throws {
        let fixture = try ToolSettleFixture()
        defer { fixture.cleanup() }
        let worker = ToolSettleWorker(settlesTool: false)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 2)
        let sink = ToolSettleEventSink()
        let sinkTask = Task { await sink.consume(host.eventStream()) }
        try await openTurn(host: host)
        _ = try await waitForSessionStart(fixture)
        while (try? lastStepState(fixture)) == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) }
            ?? "stop() returned without error"
        XCTAssertTrue(message.contains("tool call"),
                      "the fail-loud error must name the un-settled tool call: \(message)")
        XCTAssertTrue(message.contains("terminal D13 step"),
                      "the fail-loud error must name the missing terminal step: \(message)")
        XCTAssertEqual(try lastStepState(fixture), "abandoned",
                       "the fail-loud drain closes the D13 record as abandoned; "
                           + "it must not fabricate a journal end")
        XCTAssertEqual(try lastStepLine(fixture)["settled_reason"] as? String,
                       "drain-timeout")
        let errors = await sink.errors()
        XCTAssertTrue(errors.contains { $0.contains("tool call") },
                      "the fail-loud error must reach the host event stream the report "
                          + "recorder consumes; events: \(errors)")
        sinkTask.cancel()
        let hostState = await host.state
        XCTAssertEqual(hostState, .stopped)
    }
}
