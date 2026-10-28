// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — the two-phase drain escalation regression.
//
// The real park_resume failure is a Worker whose tool lane is jammed when the
// drain reaches its cancellation reserve. The old implementation repacked the
// overlay before the Worker was stopped, then navigated to the replacement
// page and expected DSH to repair the interrupted turn on connect. DSH does not
// do that: `AgentLoop.resume` appends the `interrupted` tail closers, and no
// Agent exists in the fresh Worker until the host resumes the stored session.
//
// This regression drives the real `PhoneDSHHost` over the real loopback
// channel and scripted Worker. It pins the generic sequence:
//   1. stop the old Worker (two-phase termination) before repacking;
//   2. boot a replacement and wait for its HELLO;
//   3. ask the replacement to run DSH's own resume/repair, which journals the
//      terminal turn;
//   4. verify the materialized journal before the drain completes.
// The scripted Worker deliberately never writes a terminal record on HELLO,
// so a host that merely restarts and waits cannot pass. No Swift code writes a
// DSH session record.

import Foundation
import XCTest
import PhoneDSHAgentCore
import PhoneDSH
import PhoneDSHController
import PhoneDSHEngine
import PhoneDSHWire

// MARK: - Fixture

private struct RecoveryAbortFixture {
    let root: URL
    let workspace: URL
    let bundle: PhoneDSHBundleLocation

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-abort-recovery-\(UUID().uuidString)",
                                    isDirectory: true)
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
                                     token: "abort-recovery-token",
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

    var recoveryString: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private enum RecoveryAbortError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let detail): return detail
        }
    }
}

// MARK: - Scripted Worker

/// A Worker that cannot process `session/cancel` while its tool lane is jammed.
/// It never closes the turn on connect/HELLO; only the phone-only DSH
/// resume/repair route does that, exactly like the pinned `AgentLoop.resume`
/// path in production.
private actor RecoveryAbortWorker {
    private let sessionID: String
    private let handlesRecoveryResume: Bool
    private let rewritesHeaderOnlyOnResume: Bool
    private let regressesToOlderCompletedTurnOnResume: Bool
    private let regressesToOlderCompletedTurnOnCancel: Bool
    private var configuration: WebEngineConfiguration?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var decoder = FrameDecoder()
    private var sendSeq: UInt64 = 0
    private var lastMseq: UInt64 = 0
    private var sessionText = ""
    private var workerHelloSent = false
    private var connectionToken = UUID()
    private var methods: [String] = []
    private var descendantDrainRootSets: [[String]] = []
    private var resumeCalls: [String] = []
    private var terminalSource: String?
    private var connectionCount = 0
    private var hellos = 0

    init(sessionID: String,
         handlesRecoveryResume: Bool = true,
         rewritesHeaderOnlyOnResume: Bool = false,
         regressesToOlderCompletedTurnOnResume: Bool = false,
         regressesToOlderCompletedTurnOnCancel: Bool = false) {
        self.sessionID = sessionID
        self.handlesRecoveryResume = handlesRecoveryResume
        self.rewritesHeaderOnlyOnResume = rewritesHeaderOnlyOnResume
        self.regressesToOlderCompletedTurnOnResume =
            regressesToOlderCompletedTurnOnResume
        self.regressesToOlderCompletedTurnOnCancel =
            regressesToOlderCompletedTurnOnCancel
    }

    // MARK: Connection

    func connect(_ configuration: WebEngineConfiguration) throws {
        self.configuration = configuration
        cancelConnection()
        connectionCount += 1
        guard var components = URLComponents(url: configuration.origin,
                                             resolvingAgainstBaseURL: false) else {
            throw RecoveryAbortError.failed("bad origin")
        }
        components.scheme = "ws"
        components.path = configuration.channelPath
        components.queryItems = [URLQueryItem(name: "token", value: configuration.token)]
        guard let url = components.url else {
            throw RecoveryAbortError.failed("bad channel URL")
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

    func terminate() {
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
    func descendantDrainRequests() -> [[String]] { descendantDrainRootSets }
    func recoveryResumes() -> [String] { resumeCalls }
    func journal() -> String { sessionText }
    func terminalWasWrittenByResume() -> Bool { terminalSource == "resume" }
    func connectionTotal() -> Int { connectionCount }
    func helloTotal() -> Int { hellos }

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
            // The teardown cancel is deliberately not sufficient for this
            // fixture: the tool lane is jammed. Only the DSH resume route can
            // close the stored turn.
            break
        default:
            break
        }
    }

    private func sendWorkerHello() async throws {
        guard let configuration else {
            throw RecoveryAbortError.failed("never connected")
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
        hellos += 1
        try await enqueueJSON(.hello, hello)
        // Deliberately no terminal turn here: the fresh incarnation only
        // repairs the stored session when the host drives DSH's resume path.
    }

    // MARK: Remote API

    private func respond(to request: ApiRequestFrame) async throws {
        if request.head.path == PhoneDSHDescendantDrainProtocol.path {
            let body = try JSONValue.parse(request.body)
            guard case .array(let roots)? = body["sessionIds"] else {
                XCTFail("the scoped drain must name its root sessions")
                return
            }
            descendantDrainRootSets.append(roots.compactMap { $0.recoveryString })
            // These recovery fixtures have one root and no descendants. The
            // real route receipt is still required before testing turn repair.
            let receipt = JSONValue.object([
                "ok": .bool(true),
                "value": .object([
                    "protocol": .string(PhoneDSHDescendantDrainProtocol.receiptProtocol),
                    "roots": .array(roots), "missing": .array([]),
                    "descendants": .array([]), "durationMs": .number(0),
                ]),
            ])
            try await respond(request, status: 200,
                              headers: ["content-type": "application/json"],
                              body: try receipt.encoded())
            return
        }
        if request.head.path == PhoneDSHRecoveryProtocol.resumePath {
            try await respondRecoveryResume(request)
            return
        }
        if request.head.path == PhoneDSHRecoveryProtocol.path {
            try await respondUnary(request, rpcID: "", value: .object([:]))
            return
        }
        var rpcID = ""
        var method = ""
        if let envelope = try? JSONValue.parse(request.body) {
            rpcID = envelope["rpcId"]?.recoveryString ?? ""
            method = envelope["method"]?.recoveryString ?? ""
        }
        methods.append(method)
        let now = Self.nowMillis()
        switch method {
        case "session/create":
            try await respondUnary(request, rpcID: rpcID,
                                   value: .object(["sessionId": .string(sessionID)]))
        case "session/prompt":
            if regressesToOlderCompletedTurnOnResume
                || regressesToOlderCompletedTurnOnCancel {
                // Turn 1 is durably completed; turn 2 is the one this drain
                // observes open. The repair/cancel below drops turn 2's start,
                // so the journal regresses to turn 1's older terminal record.
                try await appendSession(
                    Self.record("turn/start", seq: 0, time: now,
                                data: #"{"turn":1}"#)
                        + Self.record("turn/end", seq: 1, time: now,
                                      data: #"{"turn":1,"reason":{"kind":"completed"}}"#)
                        + Self.record("turn/start", seq: 2, time: now + 1,
                                      data: #"{"turn":2}"#))
            } else {
                try await appendSession(
                    Self.record("turn/start", seq: 0, time: now, data: #"{"turn":1}"#)
                        + Self.record("step/start", seq: 1, time: now,
                                      data: #"{"turn":1,"step":1}"#))
            }
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        case "session/cancel":
            // The jammed lane never processes this while the turn is open. If
            // the resume route already closed the turn, acknowledge it so the
            // verification phase is not delayed by a dead RPC.
            if regressesToOlderCompletedTurnOnCancel {
                // The cooperative cancel path has the same torn-tail hazard as
                // escalation: turn 2 was open, but the journal falls back to
                // turn 1's completed `turn/end`. "No open turn" is not proof
                // that the interrupted turn closed.
                let now = Self.nowMillis()
                sessionText = header()
                    + Self.record("turn/start", seq: 0, time: now,
                                  data: #"{"turn":1}"#)
                    + Self.record("turn/end", seq: 1, time: now,
                                  data: #"{"turn":1,"reason":{"kind":"completed"}}"#)
                try await writeSession(sessionText)
                try await respondUnary(request, rpcID: rpcID, value: .object([:]))
            } else if sessionText.contains("\"turn/end\"") {
                try await respondUnary(request, rpcID: rpcID, value: .object([:]))
            }
        default:
            try await respondUnary(request, rpcID: rpcID, value: .object([:]))
        }
    }

    /// The phone-only DSH resume/repair route. The terminal record is written
    /// here and nowhere else; the host only reads the journal afterwards.
    private func respondRecoveryResume(_ request: ApiRequestFrame) async throws {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let sessionID = body?["sessionId"] as? String ?? ""
        guard sessionID == self.sessionID else {
            try await respond(request, status: 404, body: Data())
            return
        }
        guard handlesRecoveryResume else {
            try await respond(request, status: 500, body: Data())
            return
        }
        resumeCalls.append(sessionID)
        if rewritesHeaderOnlyOnResume {
            // A truncated/regressed journal has no open turn, but it has no
            // `turn/end` either: the host must not treat that absence as a
            // completed or terminated turn.
            sessionText = ""
            try await writeSession(header())
        } else if regressesToOlderCompletedTurnOnResume {
            // A torn tail dropped turn 2's `turn/start`; the journal now ends
            // on turn 1's completed `turn/end`. It is still not a terminal
            // record for the interrupted turn the host observed open.
            let now = Self.nowMillis()
            sessionText = header()
                + Self.record("turn/start", seq: 0, time: now,
                              data: #"{"turn":1}"#)
                + Self.record("turn/end", seq: 1, time: now,
                              data: #"{"turn":1,"reason":{"kind":"completed"}}"#)
            try await writeSession(sessionText)
        } else if !sessionText.contains("\"turn/end\"") {
            let now = Self.nowMillis()
            // The pinned session layer's `interrupted` closers: an open step
            // end followed by the terminal turn/end with DSH's own reason.
            try await appendSession(
                Self.record("step/end", seq: 2, time: now,
                            data: #"{"turn":1,"step":1}"#)
                    + Self.record("turn/end", seq: 3, time: now,
                                  data: #"{"turn":1,"reason":{"kind":"interrupted"}}"#))
            terminalSource = "resume"
        }
        let value: [String: Any] = ["ok": true,
                                    "value": ["sessionId": sessionID,
                                              "access": "resume",
                                              "closed": true]]
        try await respond(request, status: 200,
                          headers: [PhoneDSHMuxProtocol.contentTypeHeader:
                                        PhoneDSHMuxProtocol.jsonContentType],
                          body: try JSONSerialization.data(withJSONObject: value,
                                                           options: [.sortedKeys]))
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

    private func respond(_ request: ApiRequestFrame, status: Int,
                         headers: [String: String] = [:], body: Data) async throws {
        try await enqueueFrame(.apiResponse,
                               payload: try ApiResponseFrame(
                                reqID: request.reqID,
                                head: ApiResponseHead(status: status, headers: headers),
                                body: body).encoded())
        try await enqueueFrame(.apiEnd,
                               payload: ApiEndFrame(reqID: request.reqID).encoded())
    }

    // MARK: Frame sends

    private func enqueueJSON<T: Encodable>(_ type: FrameType, _ value: T) async throws {
        try await enqueueFrame(type, payload: try CanonicalJSON.encode(value))
    }

    private func enqueueFrame(_ type: FrameType, payload: Data) async throws {
        guard let task else { throw RecoveryAbortError.failed("channel is closed") }
        sendSeq += 1
        let encoded = try FrameEncoder.encode(type: type, seq: sendSeq, payload: payload)
        try await task.send(.data(encoded))
    }

    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - Scripted engine

/// Two-phase engine: `terminateWorker()` stops the old incarnation and leaves
/// the view empty; a later `restart` boots a fresh one. It records the order so
/// the test can prove the host did not boot before stopping the old Worker.
private final class RecoveryAbortEngine: WebEngineControlling,
                                         WebEngineRestartRequesting,
                                         WebEngineWorkerTerminating,
                                         @unchecked Sendable {
    let worker: RecoveryAbortWorker
    private let lock = NSLock()
    private var configuration: WebEngineConfiguration?
    private var terminateCount = 0
    private var restartCount = 0
    private var sequence: [String] = []
    private var timestampedSequence: [(name: String, at: Date)] = []

    init(worker: RecoveryAbortWorker) {
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

    func terminateWorker() async throws {
        lock.lock()
        terminateCount += 1
        sequence.append("terminate")
        timestampedSequence.append(("terminate", Date()))
        lock.unlock()
        await worker.terminate()
    }

    func restart() async throws {
        _ = try await restart(reason: .webContentTerminated)
    }

    func restart(reason: WebEngineRestartReason) async throws -> WebEngineRestartReport {
        let bootID = Self.makeBootID()
        lock.lock()
        restartCount += 1
        sequence.append("restart")
        timestampedSequence.append(("restart", Date()))
        var configuration = self.configuration
        if configuration != nil { configuration?.bootID = bootID }
        self.configuration = configuration
        lock.unlock()
        if let configuration { try await worker.connect(configuration) }
        return WebEngineRestartReport(reason: reason,
                                      bootID: bootID,
                                      duration: .zero)
    }

    func counts() -> (terminate: Int, restart: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (terminateCount, restartCount)
    }

    func events() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return sequence
    }

    func eventDates() -> [(name: String, at: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return timestampedSequence
    }

    private static func makeBootID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

// MARK: - Tests

final class PhoneDSHScenarioAbortRecoveryTests: XCTestCase {
    private static let sessionID = "session-recovery-resume"

    private func startHost(fixture: RecoveryAbortFixture,
                           worker: RecoveryAbortWorker,
                           drainDeadline: TimeInterval)
        async throws -> (PhoneDSHHost, RecoveryAbortEngine) {
        let configuration = try fixture.configuration(drainDeadline: drainDeadline)
        let engine = RecoveryAbortEngine(worker: worker)
        let host = PhoneDSHHost(configuration: configuration,
                                engineFactory: { _ in engine })
        try await host.start()
        return (host, engine)
    }

    private func openTurn(host: PhoneDSHHost,
                          fixture: RecoveryAbortFixture) async throws {
        let harness = try await host.harness()
        let session = try await harness.openSession(
            HarnessSessionRequest(workspace: "/dsh/workspace"))
        XCTAssertEqual(session.id, Self.sessionID)
        try await harness.send(
            .prompt(text: "Hold the turn open through the drain.",
                    attachments: [], requestID: "abort-recovery-1"),
            to: session.id)
        let deadline = Date().addingTimeInterval(5)
        while true {
            let text = (try? String(decoding: Data(
                contentsOf: fixture.sessionJournal(sessionID: Self.sessionID)),
                as: UTF8.self)) ?? ""
            if text.contains("\"turn/start\"") { return }
            if Date() >= deadline {
                throw RecoveryAbortError.failed("the scripted session never journaled turn/start")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func waitForOpenTurn(_ turn: Int,
                                 fixture: RecoveryAbortFixture) async throws {
        let deadline = Date().addingTimeInterval(5)
        while true {
            if let data = try? Data(contentsOf:
                fixture.sessionJournal(sessionID: Self.sessionID)) {
                let state = PhoneDSHSessionLog.state(of: data)
                if state.openTurn == turn { return }
            }
            if Date() >= deadline {
                throw RecoveryAbortError.failed(
                    "the scripted session never journaled open turn \(turn)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// The regression: a jammed cancel cannot be settled by a plain reboot.
    /// The host must stop the old Worker first, then drive DSH's own resume
    /// route at the replacement and verify the terminal journal it wrote.
    func testEscalationStopsOldWorkerThenDrivesDSHRecoveryResume() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(sessionID: Self.sessionID)
        let (host, engine) = try await startHost(fixture: fixture, worker: worker,
                                                 drainDeadline: 10)
        try await openTurn(host: host, fixture: fixture)

        try await host.stop()
        let state = await host.state
        XCTAssertEqual(state, .stopped)

        let counts = engine.counts()
        XCTAssertGreaterThanOrEqual(counts.terminate, 1,
                                    "the escalation must stop the old Worker, not only reload")
        XCTAssertGreaterThanOrEqual(counts.restart, 1,
                                    "the escalation must boot a replacement Worker")
        XCTAssertEqual(Array(engine.events().prefix(2)), ["terminate", "restart"],
                       "the old Worker must stop before the replacement boots")

        let materialized = try Data(contentsOf: fixture.sessionJournal(sessionID: Self.sessionID))
        let turn = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertTrue(turn.hasTerminalTurn,
                      "the replacement must leave a terminal DSH turn: \(turn)")
        XCTAssertEqual(turn.lastTurnEndReason, "interrupted",
                       "DSH's interrupted repair owns the terminal reason, not Swift")
        XCTAssertNil(turn.openTurn)

        let resumes = await worker.recoveryResumes()
        XCTAssertTrue(resumes.contains(Self.sessionID),
                      "the host must drive the DSH resume/repair route; calls: \(resumes)")
        let byResume = await worker.terminalWasWrittenByResume()
        XCTAssertTrue(byResume,
                      "the terminal record must come from the resume route, never HELLO")
        let journal = await worker.journal()
        XCTAssertEqual(String(decoding: materialized, as: UTF8.self), journal,
                       "the materialized journal must be exactly the Worker-authored bytes")
        let methods = await worker.unaryMethods()
        XCTAssertTrue(methods.contains("session/cancel"),
                      "the existing cancel lever still runs before escalation: \(methods)")
    }

    /// The real B04 shape: a background `park()` on the normal 20 s window
    /// with a jammed turn. The graceful phase must stop at the escalation
    /// point, so the terminate/reboot/DSH-repair sequence starts with the full
    /// escalation allowance instead of arriving with only the teardown tail
    /// left.
    func testParkEntersEscalationAtTheReservedPoint() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(sessionID: Self.sessionID)
        let drainDeadline: TimeInterval = 20
        let (host, engine) = try await startHost(fixture: fixture, worker: worker,
                                                 drainDeadline: drainDeadline)
        try await openTurn(host: host, fixture: fixture)

        let started = Date()
        try await host.park()
        let elapsed = Date().timeIntervalSince(started)
        let state = await host.state
        XCTAssertEqual(state, .stopped,
                       "a completed park releases the facade runtime")
        let diagnostics = await host.diagnostics()
        XCTAssertEqual(diagnostics.hostState, .parked,
                       "the controller moved to Parked; .parked is not the facade state")
        XCTAssertLessThan(elapsed, drainDeadline,
                          "the park must finish inside its 20 s window")
        let drainRequests = await worker.descendantDrainRequests()
        XCTAssertEqual(drainRequests, [[Self.sessionID]],
                       "abort must reuse the successful exact-root early drain "
                           + "after the escalation cutoff, then verify the durable "
                           + "terminal journal instead of spending a second route budget")

        let plan = DrainEscalationPlan(
            deadline: started.addingTimeInterval(drainDeadline),
            window: drainDeadline)
        let escalationOffset = plan.escalationDeadline.timeIntervalSince(started)
        let dates = engine.eventDates()
        let terminateAt = try XCTUnwrap(
            dates.first { $0.name == "terminate" }?.at,
            "the jammed turn must reach the terminate escalation")
        let terminateOffset = terminateAt.timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(
            terminateOffset, escalationOffset - 1.5,
            "the graceful phase must not escalate early (terminate at "
                + "\(terminateOffset) s, escalation point \(escalationOffset) s)")
        XCTAssertLessThanOrEqual(
            terminateOffset, escalationOffset + 1.5,
            "the graceful phase ate the escalation allowance (terminate at "
                + "\(terminateOffset) s, escalation point \(escalationOffset) s)")

        let counts = engine.counts()
        XCTAssertGreaterThanOrEqual(counts.terminate, 1)
        XCTAssertGreaterThanOrEqual(counts.restart, 1)
        let events = engine.events()
        let terminateIndex = try XCTUnwrap(events.firstIndex(of: "terminate"))
        let restartIndex = try XCTUnwrap(events.firstIndex(of: "restart"))
        XCTAssertLessThan(terminateIndex, restartIndex,
                          "the replacement Worker must boot after termination")
        let journal = try Data(contentsOf:
            fixture.sessionJournal(sessionID: Self.sessionID))
        let turn = PhoneDSHSessionLog.state(of: journal)
        XCTAssertTrue(turn.hasTerminalTurn)
        XCTAssertEqual(turn.lastTurnEndReason, "interrupted")
    }

    /// A journal that regresses to a header-only file has no open turn, but it
    /// also has no terminal `turn/end`. The escalation must not settle on
    /// "not open" alone: it stays fail loud after the bounded window.
    func testEscalationWithHeaderOnlyJournalDoesNotSettle() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(sessionID: Self.sessionID,
                                         rewritesHeaderOnlyOnResume: true)
        let (host, _) = try await startHost(fixture: fixture, worker: worker,
                                            drainDeadline: 3)
        try await openTurn(host: host, fixture: fixture)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? "stop() returned without error"
        XCTAssertTrue(message.contains("no terminal turn/end")
                        || message.contains("not a completed turn"),
                      "a header-only journal is not a settled turn: \(message)")

        let materialized = try Data(contentsOf: fixture.sessionJournal(sessionID: Self.sessionID))
        let turn = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertFalse(turn.hasTerminalTurn)
        XCTAssertFalse(turn.sawTurnEnd)
        XCTAssertNil(turn.openTurn)
        let resumes = await worker.recoveryResumes()
        XCTAssertTrue(resumes.contains(Self.sessionID),
                      "the host must have tried the DSH repair route before failing: \(resumes)")
    }

    /// A torn journal can fall back to an older completed turn: turn 1 has a
    /// real `turn/end`, turn 2 was open when escalation began, and the repair
    /// regresses the file to turn 1. `hasTerminalTurn` alone would accept it;
    /// the drain must require the terminal record to close turn 2 and stay
    /// fail loud.
    func testEscalationDoesNotSettleOnOlderCompletedTurn() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(
            sessionID: Self.sessionID,
            regressesToOlderCompletedTurnOnResume: true)
        let (host, _) = try await startHost(fixture: fixture, worker: worker,
                                            drainDeadline: 3)
        try await openTurn(host: host, fixture: fixture)
        try await waitForOpenTurn(2, fixture: fixture)

        let before = PhoneDSHSessionLog.state(of: try Data(contentsOf:
            fixture.sessionJournal(sessionID: Self.sessionID)))
        XCTAssertEqual(before.openTurn, 2)
        XCTAssertEqual(before.lastTurnEndTurn, 1)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? "stop() returned without error"
        XCTAssertTrue(message.contains("no terminal turn/end")
                        || message.contains("not a completed turn"),
                      "an older completed turn must not settle turn 2: \(message)")

        let materialized = try Data(contentsOf:
            fixture.sessionJournal(sessionID: Self.sessionID))
        let turn = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertTrue(turn.hasTerminalTurn,
                      "the fixture must leave the older terminal record the bug accepted")
        XCTAssertEqual(turn.lastTurnEndTurn, 1)
        XCTAssertNil(turn.openTurn)
        let resumes = await worker.recoveryResumes()
        XCTAssertTrue(resumes.contains(Self.sessionID),
                      "the host must have tried the DSH repair route before failing: \(resumes)")
    }

    /// The ordinary `session/cancel` path has the same exact-turn obligation as
    /// escalation. Turn 2 is open when the cancel arrives; the Worker rewrites
    /// the journal back to turn 1's completed `turn/end`. A drain that equates
    /// "no open turn" with "terminal" would park successfully. It must stay
    /// fail loud because turn 2 has no closing record.
    func testCancelDoesNotSettleOnOlderCompletedTurn() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(
            sessionID: Self.sessionID,
            regressesToOlderCompletedTurnOnCancel: true)
        let (host, _) = try await startHost(fixture: fixture, worker: worker,
                                            drainDeadline: 3)
        try await openTurn(host: host, fixture: fixture)
        try await waitForOpenTurn(2, fixture: fixture)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? "stop() returned without error"
        XCTAssertTrue(message.contains("no terminal turn/end")
                        || message.contains("not a completed turn"),
                      "a cancel that regresses to an older turn/end must not settle: \(message)")

        let materialized = try Data(contentsOf:
            fixture.sessionJournal(sessionID: Self.sessionID))
        let turn = PhoneDSHSessionLog.state(of: materialized)
        XCTAssertTrue(turn.hasTerminalTurn,
                      "the fixture must leave the older terminal record the bug accepted")
        XCTAssertEqual(turn.lastTurnEndTurn, 1)
        XCTAssertNil(turn.openTurn)
    }

    /// A two-phase engine whose replacement never repairs the turn still fails
    /// loud: the new stop path does not turn "old Worker terminated" into a
    /// completed or terminal session.
    func testEscalationWithoutDSHRepairStillFailsLoud() async throws {
        let fixture = try RecoveryAbortFixture()
        defer { fixture.cleanup() }
        let worker = RecoveryAbortWorker(sessionID: Self.sessionID,
                                         handlesRecoveryResume: false)
        let (host, _) = try await startHost(fixture: fixture, worker: worker,
                                            drainDeadline: 3)
        try await openTurn(host: host, fixture: fixture)

        var failure: Error?
        do {
            try await host.stop()
        } catch {
            failure = error
        }
        let message = failure.map { String(describing: $0) } ?? "stop() returned without error"
        XCTAssertTrue(message.contains("open turn") || message.contains("terminal"),
                      "a Worker that cannot repair the turn must fail loud: \(message)")
    }
}
