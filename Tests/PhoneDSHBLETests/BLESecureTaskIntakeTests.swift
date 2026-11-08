// SPDX-License-Identifier: MIT
// secure-session-v2 §8.1-§9.3 intake over real TLS sessions against a
// scripted board (test TLS server + a one-slot task store): durable intents
// before every transition, `status` keepalive while a task runs (never
// `next`), session renewal under one grant, lost-reply recovery without
// re-execution, unresolved request-level errors, the three-attempt limit, and
// the coordinator path whose store gate refuses every shipping grant.
import CoreBluetooth
import Foundation
import XCTest
@testable import PhoneDSHBLE
@testable import PhoneDSHDeviceTasks

/// One-slot reference store with §9.1 semantics and fault knobs.
actor BLESecureScriptedBoard {
    let phoneID: String
    var task: DeviceTask?
    var phase: BLESecureTaskPhase = .unknown
    var by: String?
    var outcome: DeviceTaskOutcome?
    private(set) var received: [String] = []
    private(set) var sessions = 0
    var dropReplies: [String: Int] = [:]
    /// Requests lost before the board saw them (never applied, never answered).
    var dropRequests: [String: Int] = [:]
    var acceptError: BLESecureErrorCode?

    init(phoneID: String, task: DeviceTask?) {
        self.phoneID = phoneID
        self.task = task
        self.phase = task == nil ? .unknown : .queued
    }

    func setDrop(_ type: String, _ count: Int) { dropReplies[type] = count }
    func setDropRequest(_ type: String, _ count: Int) { dropRequests[type] = count }
    func setAcceptError(_ code: BLESecureErrorCode?) { acceptError = code }
    func sessionStarted() { sessions += 1 }
    func types() -> [String] { received }
    func snapshot() -> (BLESecureTaskPhase, DeviceTaskOutcome?) { (phase, outcome) }

    func handle(_ message: BLESecureClientMessage, sc: String) -> BLESecureServerMessage? {
        received.append(message.typeName)
        if let left = dropRequests[message.typeName], left > 0 { dropRequests[message.typeName] = left - 1; return nil }
        let mine = by == phoneID
        let reply: BLESecureServerMessage
        switch message {
        case .readyReq(_, let device, let phone, let eid, let cc):
            return .readyAck(device: device, phone: phone, eid: eid, cc: cc, sc: sc)
        case .next(let seq, _):
            if let task, phase == .queued || (phase == .accepted && mine) { reply = .nextR(re: seq, task: task, phase: phase) }
            else { reply = .nextR(re: seq, task: nil, phase: nil) }
        case .accept(let seq, _, let id, _):
            if let acceptError { reply = .err(re: seq, code: acceptError) }
            else if id != task?.id { reply = .err(re: seq, code: .unknownTask) }
            else if phase == .queued { phase = .accepted; by = phoneID; reply = .r(re: seq, result: .applied, phase: .accepted) }
            else if phase == .accepted && mine { reply = .r(re: seq, result: .duplicate, phase: .accepted) }
            else { reply = .err(re: seq, code: .invalidTransition) }
        case .complete(let seq, _, _, _, let output, let truncated):
            let value = DeviceTaskOutcome.completed(output: output, truncated: truncated)
            if phase == .accepted && mine { phase = .completed; outcome = value; reply = .r(re: seq, result: .applied, phase: .completed) }
            else if phase == .completed && outcome == value { reply = .r(re: seq, result: .duplicate, phase: .completed) }
            else { reply = .err(re: seq, code: .conflict) }
        case .fail(let seq, _, _, _, let kind, let text):
            let value = DeviceTaskOutcome.failed(kind: kind, message: text)
            if phase == .accepted && mine { phase = .failed; outcome = value; reply = .r(re: seq, result: .applied, phase: .failed) }
            else if phase == .failed && outcome == value { reply = .r(re: seq, result: .duplicate, phase: .failed) }
            else { reply = .err(re: seq, code: .conflict) }
        case .status(let seq, _, let id, _):
            guard id == task?.id else { reply = .statusR(re: seq, phase: .unknown, mine: false, outcome: nil); break }
            let owned = mine && phase != .queued
            let terminal = phase == .completed || phase == .failed
            reply = .statusR(re: seq, phase: phase, mine: owned, outcome: terminal && owned ? outcome : nil)
        case .err:
            return nil
        }
        if let left = dropReplies[message.typeName], left > 0 { dropReplies[message.typeName] = left - 1; return nil }
        return reply
    }

    /// Serves one session on `server`.
    nonisolated func serve(_ server: BLESecureTestServer) async {
        guard await server.run() == .established else { return }
        await sessionStarted()
        var frames = BLESecureFrameDecoder()
        let sc = BLESecureIdentifiers.hex(try! BLESecureIdentifiers.randomBytes(32))
        while let chunk = try? await server.receive() {
            for payload in frames.push(chunk).payloads {
                guard let message = try? BLESecureMessageCodec.decodeClient(payload) else { continue }
                if let reply = await handle(message, sc: sc) {
                    try? server.send(try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(reply)))
                }
            }
        }
    }
}

actor BLESecureTestRunner: DeviceTaskRunner {
    private(set) var runs = 0
    let delay: Duration
    init(delay: Duration) { self.delay = delay }
    func session(for deviceID: String, existingSession: String?) async throws -> String { existingSession ?? "secure-session-1" }
    func run(task: DeviceTask, record: DeviceTaskRecord) async -> DeviceTaskOutcome {
        runs += 1
        try? await Task.sleep(for: delay)
        return .completed(output: "answer from phone", truncated: false)
    }
    func cancel(sessionID: String) async {}
}

final class BLESecureTaskIntakeTests: XCTestCase {
    let phoneSigner = BLESecureSoftwareSigner()
    let deviceSigner = BLESecureSoftwareSigner()
    var phoneFP: String { try! BLESecureIdentifiers.fingerprint(publicKey: phoneSigner.publicKey) }
    var deviceFP: String { try! BLESecureIdentifiers.fingerprint(publicKey: deviceSigner.publicKey) }
    let eid = "6f1c0a8e2b9d4c3fa1e0b7d6c5f4e3d2"
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-secure-intake-" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func makeTask(_ id: String = "task-7", key: String = "goal-7") throws -> DeviceTask {
        let body: [String: Any] = ["id": id, "idempotency_key": key, "requester": "device",
                                   "created_at": "2026-11-08T00:00:00Z", "body": ["type": "goal", "text": "Report the temperature"]]
        return try DeviceTask.decode(JSONSerialization.data(withJSONObject: body))
    }

    final class Opens: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var refuse = false
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    struct Rig {
        let generation: BLESecurePhoneGeneration
        let intake: BLESecureTaskIntake
        let board: BLESecureScriptedBoard
        let runner: BLESecureTestRunner
        let executor: DeviceTaskExecutor
        let opens: Opens
        let deviceID: String
    }

    func rig(task: DeviceTask?, runDelay: Duration = .milliseconds(50), lifetime: Duration = .seconds(600),
             responseWait: Duration = .seconds(10), keepalive: Duration = .milliseconds(150)) throws -> Rig {
        let key = try BLESecurePhoneKey(signer: phoneSigner, isHardwareBacked: false)
        let record = BLESecureEnrollmentRecord(state: .committed, device: deviceFP, phone: key.fingerprint, eid: eid, rev: 2)
        var timers = BLESecurePhoneGeneration.Timers()
        timers.lifetime = lifetime
        timers.responseWait = responseWait
        let generation = try BLESecurePhoneGeneration(key: key, selected: record, timers: timers,
                                                      isCurrent: { true }, recordStillCurrent: { true })
        let board = BLESecureScriptedBoard(phoneID: key.phoneID, task: task)
        let opens = Opens()
        let deviceSigner = self.deviceSigner, phoneFP = key.fingerprint
        var timing = BLESecureTaskIntake.Timing()
        timing.keepalive = keepalive
        timing.poll = .milliseconds(50)
        timing.renewalBackoff = .milliseconds(20)
        timing.tick = .milliseconds(20)
        let intake = BLESecureTaskIntake(generation: generation, deviceID: record.deviceID, phoneID: key.phoneID, timing: timing) {
            _ = opens.next()
            if opens.refuse { throw BLEFailure("CoC refused") }
            let pipe = BLESecureMemoryPipe()
            let server = try BLESecureTestServer(stream: pipe.server, signer: deviceSigner, phonePins: [phoneFP])
            Task { await board.serve(server) }
            return pipe.client
        }
        let runner = BLESecureTestRunner(delay: runDelay)
        let executor = try DeviceTaskExecutor(directory: directory, runner: runner)
        return Rig(generation: generation, intake: intake, board: board, runner: runner, executor: executor,
                   opens: opens, deviceID: record.deviceID)
    }

    func waitUntil(timeout: Duration = .seconds(10), _ condition: () async -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock().now + timeout
        while ContinuousClock().now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let reached = await condition()
        XCTAssertTrue(reached, "condition not reached", file: file, line: line)
    }

    func intents(_ suffix: String) -> [String] {
        let ops = directory.appendingPathComponent("ble-secure-ops")
        return ((try? FileManager.default.contentsOfDirectory(atPath: ops.path)) ?? []).filter { $0.hasSuffix(suffix) }
    }

    func grantAndStart(_ rig: Rig) async throws {
        try await rig.intake.grant(executor: rig.executor)
        await rig.intake.start { _ in }
    }

    func testRoundTripInstallsIntentsAndKeepsAliveWithStatusOnly() async throws {
        let task = try makeTask()
        let rig = try rig(task: task, runDelay: .milliseconds(700))
        try await grantAndStart(rig)
        await waitUntil { await rig.board.snapshot().0 == .completed }
        let (_, outcome) = await rig.board.snapshot()
        XCTAssertEqual(outcome, .completed(output: "answer from phone", truncated: false))
        let runs = await rig.runner.runs
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(intents("-accept.json").count, 1, "accept intent durable before send")
        XCTAssertEqual(intents("-complete.json").count, 1, "complete intent durable before send")
        let types = await rig.board.types()
        let accept = try XCTUnwrap(types.firstIndex(of: "accept")), complete = try XCTUnwrap(types.firstIndex(of: "complete"))
        let between = types[(accept + 1)..<complete]
        XCTAssertFalse(between.isEmpty, "keepalive while the task runs")
        XCTAssertTrue(between.allSatisfy { $0 == "status" }, "the keepalive is status, never next: \(types)")
        let keepalives = await rig.intake.keepalivesSent
        XCTAssertGreaterThanOrEqual(keepalives, 1)
        let journal = try await rig.executor.tasks(deviceID: rig.deviceID)
        XCTAssertEqual(journal, [task], "parent journaled under the secure device ID")
        await rig.intake.stop()
    }

    func testSessionRenewalUnderTheSameGrantReportsTheResult() async throws {
        let rig = try rig(task: try makeTask(), runDelay: .milliseconds(1200), lifetime: .milliseconds(500), keepalive: .seconds(30))
        try await grantAndStart(rig)
        await waitUntil { await rig.board.snapshot().0 == .completed }
        let sessions = await rig.board.sessions
        XCTAssertGreaterThanOrEqual(sessions, 2, "the result was reported in a renewed session")
        let grant = await rig.generation.grant
        XCTAssertEqual(grant, .active, "the grant survives session close")
        let runs = await rig.runner.runs
        XCTAssertEqual(runs, 1)
        await rig.intake.stop()
    }

    func testLostRepliesAreReconciledByStatusWithoutReexecution() async throws {
        let rig = try rig(task: try makeTask(), runDelay: .milliseconds(50), responseWait: .milliseconds(300), keepalive: .seconds(30))
        await rig.board.setDrop("accept", 1)
        await rig.board.setDrop("complete", 1)
        try await grantAndStart(rig)
        await waitUntil { await rig.board.snapshot().0 == .completed }
        await waitUntil {
            let types = await rig.board.types()
            guard let complete = types.firstIndex(of: "complete"), let status = types.lastIndex(of: "status") else { return false }
            return status > complete
        }
        let types = await rig.board.types()
        XCTAssertEqual(types.filter { $0 == "accept" }.count, 1, "an applied accept is never resent: \(types)")
        XCTAssertEqual(types.filter { $0 == "complete" }.count, 1, "an applied complete is never resent: \(types)")
        let accept = try XCTUnwrap(types.firstIndex(of: "accept"))
        let status = try XCTUnwrap(types[(accept + 1)...].firstIndex(of: "status"))
        // After the lost reply: the phone's `err timeout`, a new session, then `status` first.
        XCTAssertEqual(Array(types[(accept + 1)..<status]), ["err", "ready_req"], "status is the first request after the renewal: \(types)")
        let runs = await rig.runner.runs
        XCTAssertEqual(runs, 1, "a lost reply never re-runs the DSH turn")
        let sessions = await rig.board.sessions
        XCTAssertGreaterThanOrEqual(sessions, 3)
        await rig.intake.stop()
    }

    func testLostRequestIsResentOnlyAsTheVeryNextRequestAfterStatus() async throws {
        let rig = try rig(task: try makeTask(), responseWait: .milliseconds(300), keepalive: .seconds(30))
        await rig.board.setDropRequest("accept", 1)
        try await grantAndStart(rig)
        await waitUntil { await rig.board.snapshot().0 == .completed }
        let types = await rig.board.types()
        let first = try XCTUnwrap(types.firstIndex(of: "accept"))
        let resend = try XCTUnwrap(types[(first + 1)...].firstIndex(of: "accept"))
        XCTAssertEqual(Array(types[(first + 1)...resend]), ["err", "ready_req", "status", "accept"],
                       "queued → resend of the identical arguments as the very next request: \(types)")
        XCTAssertEqual(intents("-accept.json").count, 1, "the persisted intent is reused, never rewritten")
        let runs = await rig.runner.runs
        XCTAssertEqual(runs, 1)
        await rig.intake.stop()
    }

    func testRequestLevelErrorIsUnresolvedAndNeverResent() async throws {
        let task = try makeTask()
        let rig = try rig(task: task)
        await rig.board.setAcceptError(.wrongOwner)
        try await grantAndStart(rig)
        await waitUntil { await rig.intake.unresolvedTaskIDs.contains(task.id) }
        try await Task.sleep(for: .milliseconds(300))
        let types = await rig.board.types()
        XCTAssertEqual(types.filter { $0 == "accept" }.count, 1, "\(types)")
        let notices = await rig.intake.notices
        XCTAssertFalse(notices.isEmpty, "user-visible")
        let runs = await rig.runner.runs
        XCTAssertEqual(runs, 0)
        XCTAssertEqual(intents("-accept.json").count, 1, "the intent is kept")
        await rig.intake.stop()
    }

    func testThreeFailedSessionAttemptsEndTheGrant() async throws {
        let rig = try rig(task: nil, lifetime: .milliseconds(300))
        let stopped = expectation(description: "stopped")
        try await rig.intake.grant(executor: rig.executor)
        await rig.intake.start { reason in
            XCTAssertEqual(reason, .grantEnded)
            stopped.fulfill()
        }
        rig.opens.refuse = true
        await fulfillment(of: [stopped], timeout: 10)
        let grant = await rig.generation.grant
        XCTAssertEqual(grant, .none)
        let failed = await rig.generation.failedAttempts
        XCTAssertEqual(failed, 3)
        XCTAssertEqual(rig.opens.count, 4, "one ready session, then exactly three failed attempts")
    }

    func testGenerationEndStopsIntakeAndNothingIsSentAfterwards() async throws {
        let rig = try rig(task: nil)
        let stopped = expectation(description: "stopped")
        try await rig.intake.grant(executor: rig.executor)
        await rig.intake.start { _ in stopped.fulfill() }
        await waitUntil { await rig.board.types().contains("next") }
        await rig.generation.end(.disconnect)
        await fulfillment(of: [stopped], timeout: 5)
        let before = await rig.board.types().count
        try await Task.sleep(for: .milliseconds(200))
        let after = await rig.board.types().count
        XCTAssertEqual(before, after)
    }
}

// MARK: coordinator over the real store (test adapter) and a TLS board behind the CoC

/// A CoC test I/O whose far end is a byte stream served by the test board.
final class BLESecurePipeIO: BLESecureStreamIO, @unchecked Sendable {
    final class BoardEnd: BLESecureByteStream, @unchecked Sendable {
        weak var io: BLESecurePipeIO?
        private let lock = NSLock()
        private var queue: [[UInt8]] = []
        private var waiter: CheckedContinuation<[UInt8]?, Error>?
        private var closed = false
        func write(_ bytes: [UInt8]) throws {
            guard let io, !isClosed else { throw BLEFailure("closed") }
            io.receive(bytes)
        }
        func read() async throws -> [UInt8]? {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if !queue.isEmpty { let n = queue.removeFirst(); lock.unlock(); c.resume(returning: n); return }
                if closed { lock.unlock(); c.resume(returning: nil); return }
                waiter = c; lock.unlock()
            }
        }
        func close() {
            lock.lock(); closed = true; let w = waiter; waiter = nil; lock.unlock()
            w?.resume(returning: nil)
            io?.peerClosed()
        }
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        func deliver(_ bytes: [UInt8]) {
            lock.lock()
            if let w = waiter { waiter = nil; lock.unlock(); w.resume(returning: bytes); return }
            queue.append(bytes); lock.unlock()
        }
    }
    let board = BoardEnd()
    weak var stream: BLESecureBoundedStream?
    private let lock = NSLock()
    private var inbound: [UInt8] = []
    private var eof = false
    init() { board.io = self }
    var hasSpaceAvailable: Bool { !board.isClosed }
    var hasBytesAvailable: Bool { lock.lock(); defer { lock.unlock() }; return !inbound.isEmpty }
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Int {
        board.deliver(Array(UnsafeBufferPointer(start: bytes, count: count)))
        return count
    }
    func read(_ buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = min(count, inbound.count)
        for i in 0..<n { buffer[i] = inbound[i] }
        inbound.removeFirst(n)
        return n
    }
    func closeIO() { board.close() }
    fileprivate func receive(_ bytes: [UInt8]) {
        lock.lock(); inbound += bytes; lock.unlock()
        DispatchQueue.main.async { self.stream?.pump() }
    }
    fileprivate func peerClosed() { DispatchQueue.main.async { self.stream?.endEncountered() } }
}

#if DEBUG
final class BLESecureSessionCoordinatorTests: XCTestCase {
    let phoneSigner = BLESecureSoftwareSigner()
    let deviceSigner = BLESecureSoftwareSigner()
    var deviceFP: String { try! BLESecureIdentifiers.fingerprint(publicKey: deviceSigner.publicKey) }
    let eid = "00112233445566778899aabbccddeeff"
    let id = UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pdsh-secure-coordinator-" + UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    @MainActor private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "condition not reached", file: file, line: line)
    }

    @MainActor func testEnrollSelectReadyAndShippingGrantRefusedEndToEnd() async throws {
        let adapter = BLEDeviceStore.TestAdapter()
        let store = BLEDeviceStore(testAdapter: adapter, testDevices: [.init(id: id, name: "PDSH board", rssi: -40)])
        let key = try BLESecurePhoneKey(signer: phoneSigner, isHardwareBacked: false)
        let coordinator = BLESecureSessionCoordinator(
            store: store, records: BLESecureEnrollmentFileStore(directory: directory.appendingPathComponent("enrollment")),
            keys: BLESecureMemoryKeyStore(key: key))
        // §3.4 ceremony on the phone: token in, confirm with a label.
        XCTAssertEqual(coordinator.keyInfo().state, .present)
        XCTAssertEqual(coordinator.keyInfo().token, key.token)
        XCTAssertFalse(coordinator.keyInfo().hardwareBacked, "the UI labels it 软件密钥")
        XCTAssertFalse(coordinator.select(peripheral: id, device: deviceFP), "only committed records can be selected")
        XCTAssertEqual(coordinator.enterBoardToken("  pdsh-board-v1:\(deviceFP.uppercased()):\(eid)\n"), .ok)
        XCTAssertEqual(coordinator.records().first?.record?.state, .staged)
        XCTAssertEqual(coordinator.confirm(device: deviceFP, eid: eid, label: "Bench board"), .ok)
        XCTAssertEqual(coordinator.records().first?.label, "Bench board")
        XCTAssertEqual(coordinator.setLabel(device: deviceFP, label: "Lab board"), .ok)

        XCTAssertTrue(coordinator.select(peripheral: id, device: deviceFP))
        XCTAssertEqual(coordinator.selection?.label, "Lab board")
        XCTAssertEqual(coordinator.selection?.deviceID, "ble:" + deviceFP)
        store.connect(id)
        store.testDidConnect(id)
        let peer = store.testPhysicalPeer(id)!
        let service = BLEDeviceStore.TestService(parent: peer, uuid: BLESecureServiceProfile.serviceUUID)
        store.testDiscoveryServices(id, peer: peer, services: [service])
        store.testDiscoveryCharacteristics(id, peer: peer, service: service, characteristics: [
            .init(parent: service, uuid: BLESecureServiceProfile.psmCharacteristicUUID, properties: [.read])])
        XCTAssertFalse(coordinator.select(peripheral: id, device: deviceFP), "no reselection while connected")

        let board = BLESecureScriptedBoard(phoneID: key.phoneID, task: nil)
        let opening = Task { @MainActor in await coordinator.openSession() }
        await waitUntil { adapter.commands.contains(.secureRead(id)) }
        store.testSecurePSMValue(id, data: Data([0x83, 0x00]))
        await waitUntil { adapter.commands.contains(.secureOpen(id, 0x83)) }
        let pipe = BLESecurePipeIO()
        let server = try BLESecureTestServer(stream: pipe.board, signer: deviceSigner, phonePins: [key.fingerprint])
        Task { await board.serve(server) }
        pipe.stream = try XCTUnwrap(store.testSecureDidOpen(id, psm: 0x83, io: pipe))
        await opening.value
        XCTAssertEqual(coordinator.phase, .ready, coordinator.message)
        XCTAssertTrue(coordinator.message.contains("Lab board") && coordinator.message.contains("ble:" + deviceFP))

        let executor = try DeviceTaskExecutor(directory: directory.appendingPathComponent("journal"), runner: BLESecureTestRunner(delay: .zero))
        #if PDSH_ENABLE_DEVICE_TASKS
        try await coordinator.grant(executor: executor)
        XCTAssertEqual(coordinator.phase, .granted)
        for _ in 0..<200 { if await board.types().contains("next") { break }; try await Task.sleep(for: .milliseconds(10)) }
        let types = await board.types()
        XCTAssertTrue(types.contains("next"), "flagged build: the admitted generation polls the board")
        #else
        do {
            try await coordinator.grant(executor: executor)
            XCTFail("a shipping build must refuse the grant")
        } catch {
            XCTAssertEqual((error as? BLEFailure)?.message, "设备身份认证尚未完成验证，暂不能授权蓝牙设备派任务")
        }
        XCTAssertEqual(coordinator.phase, .ready)
        try await Task.sleep(for: .milliseconds(200))
        let types = await board.types()
        XCTAssertEqual(types, ["ready_req"], "no request after readiness without a grant")
        XCTAssertFalse(store.devices[0].allowDeviceTasks)
        #endif

        // Background ends the generation; the same connection is never reused.
        coordinator.sceneActive(false)
        XCTAssertEqual(coordinator.phase, .ended)
        coordinator.sceneActive(true)
        await coordinator.openSession()
        XCTAssertEqual(coordinator.phase, .ended)
        XCTAssertTrue(coordinator.message.contains("重新连接"), coordinator.message)
        XCTAssertEqual(adapter.commands.filter { $0 == .secureRead(id) }.count, 1, "no new CoC on a spent connection")

        // Disconnect ends the generation; forget clears the selection.
        store.testDidDisconnect(id)
        await waitUntil { coordinator.phase == .ended }
        XCTAssertEqual(coordinator.forget(device: deviceFP), .ok)
        await waitUntil { coordinator.selection == nil }
        XCTAssertEqual(coordinator.records().first?.record?.state, .revoked)
    }
}
#endif
