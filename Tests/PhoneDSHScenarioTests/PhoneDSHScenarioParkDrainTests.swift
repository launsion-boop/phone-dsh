// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — G2-FIX-Q3 regression: a graceful park spends the
// D14 drain window on the work that is already running.
//
// The catalog `park_resume` perturbation parks the host while the first tool
// call is executing in the Worker (`G2-SELFTEST`: `sleep 1; echo ... > a.txt`).
// The scenario asserts the write is materialized after resume. A park that
// cancels the turn as soon as admission closes aborts the command before it
// wrote anything (the transcript shows the terminal toolResult `ABORTED`
// microseconds after `tool/call`), so the drain-window write is lost.
//
// This regression pins the ordering at the component layer, without WebKit:
// the Worker holds an open turn and has not yet observed the tool step (the
// model stream / tool dispatch is in flight). `park()` must use its drain
// window to let that turn finish and must not cancel it. `stop()` is a
// teardown and keeps the immediate cancel (G2-FIX-84) — both directions are
// asserted here so a future "fix" cannot trade one for the other.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHEngine
import PhoneDSHWire

// MARK: - Fixture

private struct ParkDrainFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-park-drain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staticDirectory = root.appendingPathComponent("www", isDirectory: true)
        let lazy = staticDirectory.appendingPathComponent("lazy", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: staticDirectory,
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lazy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
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
                                     token: "park-drain-token",
                                     origin: origin,
                                     bundle: bundle,
                                     drainDeadline: drainDeadline,
                                     helloTimeout: 10)
    }

    func sessionJournal(sessionID: String) -> URL {
        workspace.appendingPathComponent("materialized")
            .appendingPathComponent("home")
            .appendingPathComponent("sessions")
            .appendingPathComponent("--dsh-workspace--")
            .appendingPathComponent(sessionID)
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

    var parkString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

// MARK: - Scripted Worker

/// Holds one DSH turn open over the real ordered channel.
///
/// The turn starts (and is journaled through real `0x10` frames) but the tool
/// dispatch is deliberately not journaled until the test calls
/// ``finishTurn(reason:)``. That is the load-dependent window the catalog
/// `park_resume` self-test hit: the runner sees the harness `toolCall` event
/// and parks before the host's D13 step exists, so a park that keys only on
/// observed tool steps returns immediately and cancels the command.
private actor ParkDrainWorker {
    private let sessionID: String
    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var methods: [String] = []
    private var lifecycleStopCount = 0
    private var sessionText = ""
    private var workerHelloSent = false
    private var connectionToken = UUID()
    /// D23 `remote.mux` receives this Worker answered with a response head and
    /// deliberately left open (the standing stream a real mux would keep).
    private var standingMuxReceives: [(reqID: UInt32, muxID: String)] = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw ParkDrainError.failed("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else {
            throw ParkDrainError.failed("bad channel URL")
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
    func lifecycleStops() -> Int { lifecycleStopCount }
    func journal() -> String { sessionText }
    func standingMuxReceiveCount() -> Int { standingMuxReceives.count }

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
        case .lifecycle:
            // The host sends `state: .run` when it opens admission; only the
            // teardown `state: .stop` is the drain cancellation this test
            // counts.
            if let payload = try? JSONDecoder().decode(LifecyclePayload.self,
                                                       from: frame.payload),
               payload.state == .stop {
                lifecycleStopCount += 1
            }
        default:
            break
        }
    }

    private func sendWorkerHello() async throws {
        guard let configuration else {
            throw ParkDrainError.failed("never connected")
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
    }

    // MARK: Remote API

    private func respond(to request: ApiRequestFrame) async throws {
        if request.head.path == PhoneDSHDescendantDrainProtocol.path {
            try await respondDescendantDrain(request)
            return
        }
        if request.head.path == PhoneDSHMuxProtocol.path,
           let operation = request.head.headers[PhoneDSHMuxProtocol.operationHeader] {
            try await respondMux(request, operation: operation)
            return
        }
        var rpcID = ""
        var method = ""
        if let envelope = try? JSONValue.parse(request.body) {
            rpcID = envelope["rpcId"]?.parkString ?? ""
            method = envelope["method"]?.parkString ?? ""
        }
        methods.append(method)
        let now = Self.nowMillis()
        switch method {
        case "session/create":
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object(["sessionId": .string(sessionID)]))
        case "session/prompt":
            try await appendSession(
                Self.record("turn/start", seq: 0, time: now, data: #"{"turn":1}"#)
                    + Self.record("step/start", seq: 1, time: now,
                                  data: #"{"turn":1,"step":1}"#))
            // The prompt RPC returns immediately; the turn stays open in the
            // journal (the model/tool work is what the park must drain).
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        case "session/cancel":
            try await finishTurn(reason: "aborted")
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        default:
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        }
    }

    /// Answers the D23 mux operations. A `receive` gets its `200` ndjson head
    /// and is left open until the mux closes or the connection dies; that
    /// standing stream is exactly what the drain must not count as in-flight
    /// work.
    private func respondMux(_ request: ApiRequestFrame, operation: String) async throws {
        guard let muxID = request.head.headers[PhoneDSHMuxProtocol.muxIDHeader] else {
            try await respondStatus(request, status: 400)
            return
        }
        switch operation {
        case PhoneDSHMuxProtocol.receiveOperation:
            standingMuxReceives.append((reqID: request.reqID, muxID: muxID))
            try await enqueueFrame(.apiResponse,
                                   payload: try ApiResponseFrame(
                                    reqID: request.reqID,
                                    head: ApiResponseHead(status: 200, headers: [
                                        PhoneDSHMuxProtocol.contentTypeHeader:
                                            PhoneDSHMuxProtocol.ndjsonContentType,
                                    ])).encoded())
        case PhoneDSHMuxProtocol.closeOperation:
            try await respondStatus(request, status: 204)
            if let index = standingMuxReceives.firstIndex(where: { $0.muxID == muxID }) {
                let pending = standingMuxReceives.remove(at: index)
                try await enqueueFrame(.apiEnd,
                                       payload: try ApiEndFrame(reqID: pending.reqID).encoded())
            }
        default:
            try await respondStatus(
                request,
                status: operation == PhoneDSHMuxProtocol.sendOperation ? 204 : 404)
        }
    }

    private func respondStatus(_ request: ApiRequestFrame, status: Int) async throws {
        try await enqueueFrame(.apiResponse,
                               payload: try ApiResponseFrame(
                                reqID: request.reqID,
                                head: ApiResponseHead(status: status, headers: [:])).encoded())
        try await enqueueFrame(.apiEnd,
                               payload: try ApiEndFrame(reqID: request.reqID).encoded())
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
            roots = values.compactMap { $0.parkString }
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

    /// Closes the open turn the way the pinned DSH session layer does: the
    /// step end first, then the terminal `turn/end` with its reason.
    func finishTurn(reason: String) async throws {
        guard sessionText.contains("\"turn/start\"") else { return }
        guard !sessionText.contains("\"turn/end\"") else { return }
        let now = Self.nowMillis()
        try await appendSession(
            Self.record("step/end", seq: 2, time: now, data: #"{"turn":1,"step":1}"#)
                + Self.record("turn/end", seq: 3, time: now,
                              data: "{\"turn\":1,\"reason\":{\"kind\":\"\(reason)\"}}"))
    }

    private static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

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

    // MARK: Journal mirroring

    private func header() -> String {
        "{\"type\":\"session\",\"version\":4,\"id\":\"\(sessionID)\","
            + "\"cwd\":\"/dsh/workspace\"}\n"
    }

    private func appendSession(_ suffix: String) async throws {
        sessionText = header() + sessionText + suffix
        try await writeSession(sessionText)
    }

    private func writeSession(_ text: String) async throws {
        let mseq = lastMseq + 1
        let body = VfsMutationBody(
            op: .write, mode: 0o644, mflags: [.entryChanged], appendFrom: 0,
            path: "/dsh/home/sessions/--dsh-workspace--/\(sessionID)/session.v4.jsonl",
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
        guard let task else { throw ParkDrainError.failed("channel is closed") }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq, payload: payload)
        try await task.send(.data(encoded))
    }

    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private enum ParkDrainError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Scripted engine

private final class ParkDrainEngine: WebEngineControlling, @unchecked Sendable {
    let worker: ParkDrainWorker

    init(worker: ParkDrainWorker) {
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

// MARK: - Tests

final class PhoneDSHScenarioParkDrainTests: XCTestCase {
    private static let sessionID = "session-park-drain"

    private func startHost(fixture: ParkDrainFixture,
                           worker: ParkDrainWorker,
                           drainDeadline: TimeInterval) async throws -> PhoneDSHHost {
        let configuration = try fixture.configuration(drainDeadline: drainDeadline)
        let engine = ParkDrainEngine(worker: worker)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()
        return host
    }

    private func openTurn(host: PhoneDSHHost, worker: ParkDrainWorker,
                          fixture: ParkDrainFixture) async throws {
        let harness = try await host.harness()
        let session = try await harness.openSession(
            HarnessSessionRequest(workspace: "/dsh/workspace"))
        XCTAssertEqual(session.id, Self.sessionID)
        try await harness.send(
            .prompt(text: "Hold the turn open until the park drain window.",
                    attachments: [], requestID: "park-drain-1"),
            to: session.id)
        let deadline = Date().addingTimeInterval(5)
        while true {
            let text = (try? String(decoding: Data(
                contentsOf: fixture.sessionJournal(sessionID: Self.sessionID)),
                as: UTF8.self)) ?? ""
            if text.contains("\"turn/start\"") { return }
            if Date() >= deadline {
                throw ParkDrainError.failed("the scripted session never journaled turn/start")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Opens one real D23 standing receive through the host transport and
    /// waits until the scripted Worker has answered its ndjson head. The
    /// receive task deliberately never completes while the connection lives.
    private func openStandingMuxReceive(
        host: PhoneDSHHost,
        worker: ParkDrainWorker
    ) async throws -> Task<JSONValue?, Never> {
        let transport = try await host.makeTransport()
        let mux = try await transport.openMux()
        let receive = Task { try? await mux.receive() }
        let deadline = Date().addingTimeInterval(5)
        while await worker.standingMuxReceiveCount() == 0 {
            guard Date() < deadline else {
                receive.cancel()
                throw ParkDrainError.failed(
                    "the scripted Worker never observed the standing mux receive")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return receive
    }

    /// The regression: a graceful park must spend the drain window on the
    /// already-accepted turn. Before the fix the park cancelled the turn as
    /// soon as admission closed — the exact ordering that loses the
    /// `park_resume` drain-window write in `G2-SELFTEST`.
    func testGracefulParkLetsTheAcceptedTurnFinishBeforeCancelling() async throws {
        let fixture = try ParkDrainFixture()
        defer { fixture.cleanup() }
        let worker = ParkDrainWorker(sessionID: Self.sessionID)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 10)
        try await openTurn(host: host, worker: worker, fixture: fixture)

        let park = Task { try await host.park() }
        // The Worker has not journaled a D13 tool step yet (the dispatch is in
        // flight). An immediate cancel is the failure this test pins.
        try await Task.sleep(nanoseconds: 500_000_000)
        let beforeFinish = await worker.unaryMethods()
        let stopsBeforeFinish = await worker.lifecycleStops()
        XCTAssertFalse(beforeFinish.contains("session/cancel"),
                       "a graceful park must use its drain window, not cancel the "
                       + "accepted turn immediately; methods: \(beforeFinish)")
        XCTAssertEqual(stopsBeforeFinish, 0,
                       "a graceful park must not send the teardown LIFECYCLE stop")

        try await worker.finishTurn(reason: "completed")
        try await park.value
        let afterFinish = await worker.unaryMethods()
        XCTAssertFalse(afterFinish.contains("session/cancel"),
                       "the turn closed inside the window; no cancel was needed: \(afterFinish)")
        let text = (try? String(decoding: Data(
            contentsOf: fixture.sessionJournal(sessionID: Self.sessionID)),
            as: UTF8.self)) ?? ""
        XCTAssertTrue(text.contains("\"turn/end\""),
                      "the graceful park must not tear down before the terminal record")
        XCTAssertTrue(text.contains("\"completed\""),
                      "the turn must carry its own terminal reason, not a fabricated abort")
        let parkState = await host.state
        XCTAssertEqual(parkState, .stopped)
        try await host.stop()
    }

    /// G2-FIX-53: with no turn and no unary exchange, the D23 standing mux
    /// receive is the only thing open. The drain must not wait for that stream
    /// (which by design never ends), so an idle park returns in bounded time
    /// instead of spending the full 10 s deadline.
    func testIdleParkWithStandingMuxReceiveReturnsBeforeTheDrainDeadline() async throws {
        let fixture = try ParkDrainFixture()
        defer { fixture.cleanup() }
        let worker = ParkDrainWorker(sessionID: Self.sessionID)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 10)
        let receive = try await openStandingMuxReceive(host: host, worker: worker)

        let started = Date()
        try await host.park()
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3,
                          "an idle park must not spend the drain deadline on the "
                          + "standing mux receive (took \(elapsed)s)")

        receive.cancel()
        _ = await receive.value
        let state = await host.state
        XCTAssertEqual(state, .stopped)
        try await host.stop()
    }

    /// Same standing stream on the D24 planned-restart path: the drain check
    /// before the `Running -> Recovering` edge must see quiescence at once.
    func testPlannedRestartWithStandingMuxReceiveReturnsBeforeTheDrainDeadline() async throws {
        let fixture = try ParkDrainFixture()
        defer { fixture.cleanup() }
        let worker = ParkDrainWorker(sessionID: Self.sessionID)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 10)
        let receive = try await openStandingMuxReceive(host: host, worker: worker)

        let started = Date()
        try await host.plannedRestart(reason: "drain-quiescence")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3,
                          "a planned restart must not spend the drain deadline on the "
                          + "standing mux receive (took \(elapsed)s)")

        receive.cancel()
        _ = await receive.value
        let state = await host.state
        XCTAssertEqual(state, .running)
        try await host.stop()
    }

    /// The other direction of the same ordering: `stop()` is a teardown, so it
    /// keeps G2-FIX-84's immediate cancellation of the in-flight turn.
    func testTeardownStopStillCancelsTheOpenTurnImmediately() async throws {
        let fixture = try ParkDrainFixture()
        defer { fixture.cleanup() }
        let worker = ParkDrainWorker(sessionID: Self.sessionID)
        let host = try await startHost(fixture: fixture, worker: worker, drainDeadline: 10)
        try await openTurn(host: host, worker: worker, fixture: fixture)

        try await host.stop()
        let methods = await worker.unaryMethods()
        let stops = await worker.lifecycleStops()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "stop() must still cancel the open turn: \(methods)")
        XCTAssertGreaterThan(stops, 0,
                             "stop() must still send the teardown LIFECYCLE stop")
        let text = (try? String(decoding: Data(
            contentsOf: fixture.sessionJournal(sessionID: Self.sessionID)),
            as: UTF8.self)) ?? ""
        XCTAssertTrue(text.contains("\"turn/end\""),
                      "the teardown must wait for the terminal turn record")
        let hostState = await host.state
        XCTAssertEqual(hostState, .stopped)
    }
}
