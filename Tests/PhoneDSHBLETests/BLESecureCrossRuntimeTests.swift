// SPDX-License-Identifier: MIT
// Cross-runtime conformance of secure-session-v2.1 (ble-secure-session.md §13,
// AGENTS.md §3.4): the REAL Swift phone end (enrollment ceremony, certificate
// builder and verifier, TLS 1.3 client, framing, message codec, connection
// generation) against the REAL C board end (firmware/esp32-reference/main
// pdsh_identity/pdsh_enroll/pdsh_secure_cert/pdsh_secure_msg/pdsh_secure_session/
// pdsh_task_store on mbedTLS 4.1 at the commit ESP-IDF v6.1 fff9895c pins),
// connected by an in-memory byte pipe below the board's real §5 CoC receive
// path (firmware/tests/test_secure_bridge.c). Nothing that decides is
// substituted; only the radio, NVS flash and clocks are.
//
// The bridge is built by firmware/tests/run.sh, which needs the pinned cJSON
// component and PDSH_MBEDTLS_SRC (or IDF_PATH). A missing prerequisite fails
// the test; it is never skipped.
import Foundation
import XCTest
import PhoneDSHDeviceTasks
@testable import PhoneDSHBLE

/// The real board end as a host process (one board, its own fake NVS).
final class CSecureBoard: @unchecked Sendable {
    struct Pump: Sendable {
        let state: String
        let alert: Int
        let reason: String
        let coc: String
        let tx: [UInt8]
    }

    private let process = Process(), input = Pipe(), output = Pipe()
    private let lock = NSLock()
    private var buffered = Data()
    private(set) var device = ""

    init(executable: URL) throws {
        process.executableURL = executable
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        try process.run()
        let boot = try command("boot")
        guard boot.hasPrefix("ok ") else { throw BLEFailure("bridge boot: \(boot)") }
        device = String(boot.dropFirst(3))
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }

    func command(_ line: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        try input.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
        while true {
            if let newline = buffered.firstIndex(of: 10) {
                let text = String(decoding: buffered[buffered.startIndex..<newline], as: UTF8.self)
                buffered = Data(buffered[buffered.index(after: newline)...])
                return text
            }
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { throw BLEFailure("secure bridge ended") }
            buffered.append(chunk)
        }
    }

    private func lines(_ response: String) throws -> [String] {
        guard response.hasPrefix("ok") else { throw BLEFailure("bridge: \(response)") }
        let body = response.dropFirst(2).drop(while: { $0 == " " })
        return body.isEmpty ? [] : body.split(separator: "|").map(String.init)
    }

    func console(_ line: String) throws -> [String] { try lines(command("console " + line)) }
    func hold(ms: Int) throws -> [String] { try lines(command("hold \(ms)")) }
    func advance(ms: Int) throws -> [String] { try lines(command("advance \(ms)")) }
    func submit(_ json: String) throws -> Bool { try command("submit " + json) == "ok" }
    /// Accepts a new CoC; returns its channel number (nil when refused).
    func open() throws -> Int? {
        let response = try command("open")
        return response.hasPrefix("ok ") ? Int(response.dropFirst(3)) : nil
    }
    func reboot() throws { _ = try command("boot") }

    func result(_ id: String) throws -> [String: Any]? {
        let response = try command("result " + id)
        guard response.hasPrefix("ok ") else { throw BLEFailure("bridge: \(response)") }
        return try JSONSerialization.jsonObject(with: Data(response.dropFirst(3).utf8), options: [.fragmentsAllowed]) as? [String: Any]
    }

    func rx(_ coc: Int, _ bytes: [UInt8]) throws -> Pump { try pump(command("rx \(coc) " + BLESecureIdentifiers.hex(bytes))) }
    func poll(_ coc: Int) throws -> Pump { try pump(command("poll \(coc)")) }
    func eof(_ coc: Int) throws -> Pump { try pump(command("eof \(coc)")) }

    private func pump(_ response: String) throws -> Pump {
        let parts = response.split(separator: " ", maxSplits: 4).map(String.init)
        guard parts.count == 5, let alert = Int(parts[1]) else { throw BLEFailure("bridge pump: \(response)") }
        return Pump(state: parts[0], alert: alert, reason: parts[2], coc: parts[3],
                    tx: parts[4] == "-" ? [] : BLESecureCrossRuntimeTests.bytes(hex: parts[4]))
    }
}

/// The CoC as seen by the phone: bytes written go to the board's L2CAP
/// receive path; whatever the board's TLS server emits comes back. The board
/// closing the session is a CoC disconnect (EOF).
final class CSecureBoardStream: BLESecureByteStream, @unchecked Sendable {
    let board: CSecureBoard
    /// The board's channel number: a later CoC never receives this stream's bytes.
    let coc: Int
    private let lock = NSLock()
    private var queue: [[UInt8]] = []
    private var waiter: CheckedContinuation<[UInt8]?, Error>?
    private var closed = false, peerClosed = false
    private var pumps: [CSecureBoard.Pump] = []
    /// Fault injection: phone→board bytes lost, or board→phone bytes lost.
    var dropWrites = false
    var dropResponses = false

    init(board: CSecureBoard, coc: Int) { self.board = board; self.coc = coc }

    var last: CSecureBoard.Pump? { lock.lock(); defer { lock.unlock() }; return pumps.last }
    var boardClosed: Bool { lock.lock(); defer { lock.unlock() }; return peerClosed }
    var phoneClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func write(_ bytes: [UInt8]) throws {
        lock.lock()
        guard !closed, !peerClosed else { lock.unlock(); throw BLEFailure("secure CoC closed") }
        let drop = dropWrites
        lock.unlock()
        if drop || bytes.isEmpty { return }
        handle(try board.rx(coc, bytes))
    }

    /// Lets the board's timers and pending output run (main.c's loop tick).
    func poll() throws { handle(try board.poll(coc)) }

    private func handle(_ pump: CSecureBoard.Pump) {
        lock.lock()
        pumps.append(pump)
        var resume: (CheckedContinuation<[UInt8]?, Error>, [UInt8]?)?
        if !pump.tx.isEmpty, !dropResponses, !closed {
            if let w = waiter { waiter = nil; resume = (w, pump.tx) } else { queue.append(pump.tx) }
        }
        if pump.state == "closed", !peerClosed {
            peerClosed = true
            if resume == nil, let w = waiter, queue.isEmpty { waiter = nil; resume = (w, nil) }
        }
        lock.unlock()
        if let (w, value) = resume { w.resume(returning: value) }
    }

    func read() async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !queue.isEmpty { let next = queue.removeFirst(); lock.unlock(); continuation.resume(returning: next); return }
            if closed || peerClosed { lock.unlock(); continuation.resume(returning: nil); return }
            waiter = continuation
            lock.unlock()
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        queue = []
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(returning: nil)
        if let pump = try? board.eof(coc) {
            lock.lock(); pumps.append(pump); peerClosed = peerClosed || pump.state == "closed"; lock.unlock()
        }
    }
}

final class BLESecureCrossRuntimeTests: XCTestCase {
    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(hex.utf8.count / 2)
        var high: UInt8?
        for c in hex.utf8 {
            let v: UInt8 = c <= 57 ? c - 48 : c - 87
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        return out
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let buildOnce: Result<Void, Error> = {
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/bin/bash")
        build.arguments = [root.appendingPathComponent("firmware/tests/run.sh").path]
        build.currentDirectoryURL = root
        build.standardOutput = FileHandle.nullDevice
        build.standardError = FileHandle.standardError
        do {
            try build.run()
            build.waitUntilExit()
            guard build.terminationStatus == 0 else {
                return .failure(BLEFailure("firmware/tests/run.sh failed (needs cJSON + PDSH_MBEDTLS_SRC or IDF_PATH)"))
            }
            return .success(())
        } catch { return .failure(error) }
    }()

    private var boards: [CSecureBoard] = []
    override func tearDown() {
        boards.forEach { $0.stop() }
        boards = []
        super.tearDown()
    }

    private func newBoard() throws -> CSecureBoard {
        // PDSH_SECURE_BRIDGE runs a prebuilt (e.g. deliberately mutated) board
        // instead of building the tree's one: mutation evidence for this test.
        let executable: URL
        if let prebuilt = ProcessInfo.processInfo.environment["PDSH_SECURE_BRIDGE"] {
            executable = URL(fileURLWithPath: prebuilt)
        } else {
            try Self.buildOnce.get()
            executable = Self.root.appendingPathComponent(".build/link-host/secure-bridge")
        }
        let board = try CSecureBoard(executable: executable)
        boards.append(board)
        return board
    }

    struct Phone {
        let enrollment: BLESecureEnrollment
        let key: BLESecurePhoneKey
    }

    private func newPhone() throws -> Phone {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-cross-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let keys = BLESecureMemoryKeyStore()
        let enrollment = BLESecureEnrollment(store: BLESecureEnrollmentFileStore(directory: dir), keys: keys)
        guard case .success(let token) = enrollment.showToken() else { throw BLEFailure("phone token") }
        let key = try XCTUnwrap(try keys.load())
        XCTAssertEqual(token, "pdsh-phone-v1:" + key.fingerprint)
        return Phone(enrollment: enrollment, key: key)
    }

    private func fields(_ lines: [String], _ verb: String) throws -> [String: String] {
        for line in lines {
            if case .line(let v, let f) = BLESecureConsole.parse(Array(line.utf8), direction: .board), v == verb { return f }
        }
        throw BLEFailure("no \(verb) line in \(lines)")
    }

    /// §3 offline ceremony end to end: the board's real console grammar and
    /// gesture classifier, the phone's real token parser and record store.
    @discardableResult
    private func enroll(_ phone: Phone, on board: CSecureBoard, label: String) throws -> BLESecureEnrollmentRecord {
        let fp = phone.key.fingerprint
        _ = try fields(board.hold(ms: 5100), "armed")
        let begun = try fields(board.console("pdsh-enroll begin"), "begun")
        let eid = try XCTUnwrap(begun["eid"]), device = try XCTUnwrap(begun["device"])
        XCTAssertEqual(device, board.device)
        let staged = try fields(board.console("pdsh-enroll phone eid=\(eid) phone=\(fp)"), "staged")
        XCTAssertEqual(phone.enrollment.enterBoardToken(try XCTUnwrap(staged["token"])), .ok)
        let press = try fields(board.console("pdsh-enroll commit eid=\(eid) device=\(device) phone=\(fp)"), "press")
        XCTAssertEqual(press["action"], "commit")
        let committed = try fields(board.hold(ms: 3100), "committed")
        XCTAssertEqual(committed["phone"], fp)
        XCTAssertEqual(phone.enrollment.confirm(recordDevice: device, eid: eid, device: device, label: label), .ok)
        return try XCTUnwrap(try phone.enrollment.committedRecord(device: device))
    }

    private func generation(_ phone: Phone, _ record: BLESecureEnrollmentRecord,
                            responseWait: Duration = .seconds(5)) throws -> BLESecurePhoneGeneration {
        var timers = BLESecurePhoneGeneration.Timers()
        timers.responseWait = responseWait
        return try BLESecurePhoneGeneration(key: phone.key, selected: record, timers: timers,
                                            isCurrent: { true }, recordStillCurrent: { true })
    }

    private func session(_ board: CSecureBoard) throws -> CSecureBoardStream {
        let coc = try XCTUnwrap(try board.open(), "board admitted the CoC")
        return CSecureBoardStream(board: board, coc: coc)
    }

    private func eventually(_ what: String, timeout: Double = 5, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private static func task(_ id: String, _ idem: String, _ text: String = "Hello from the board") -> String {
        #"{"id":"\#(id)","idempotency_key":"\#(idem)","requester":"sensor","created_at":"2026-11-06T00:00:00Z","body":{"type":"goal","text":"\#(text)"}}"#
    }

    private func report(_ row: String, _ detail: String) { print("cross-runtime \(row): PASS (\(detail))") }

    // MARK: raw sessions (the real TLS client and codec without the generation)

    struct Raw {
        let client: BLESecureTLSClient
        let stream: CSecureBoardStream
        var frames = BLESecureFrameDecoder()
        var sc = ""
    }

    private func rawHandshake(_ phone: Phone, _ record: BLESecureEnrollmentRecord, _ board: CSecureBoard) async throws -> Raw {
        let stream = try session(board)
        let client = BLESecureTLSClient(stream: stream, credentials: .init(certificate: try BLESecureCertificate.make(role: .phone, signer: phone.key.signer),
                                                                           signer: phone.key.signer), selectedDevice: record.device)
        let pinned = try await client.handshake()
        XCTAssertEqual(pinned, record.device)
        return Raw(client: client, stream: stream)
    }

    private func send(_ raw: Raw, _ message: BLESecureClientMessage) async throws {
        try await raw.client.send(try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(message)))
    }

    /// The next chunk, or a failure after 5 s: a board that neither answers
    /// nor closes fails the test instead of hanging it (the stream is closed).
    private func chunk(_ raw: Raw) async throws -> [UInt8]? {
        let client = raw.client, stream = raw.stream
        return try await withThrowingTaskGroup(of: [UInt8]?.self) { group in
            group.addTask { try await client.receive() }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                stream.close()
                throw BLEFailure("board neither answered nor closed within 5 s")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func receive(_ raw: inout Raw) async throws -> BLESecureServerMessage? {
        while true {
            guard let chunk = try await chunk(raw) else { return nil }
            let (payloads, error) = raw.frames.push(chunk)
            XCTAssertNil(error)
            if let payload = payloads.first { return try BLESecureMessageCodec.decodeServer(payload) }
        }
    }

    private func rawReady(_ phone: Phone, _ record: BLESecureEnrollmentRecord, _ board: CSecureBoard) async throws -> Raw {
        var raw = try await rawHandshake(phone, record, board)
        let cc = BLESecureIdentifiers.hex(try BLESecureIdentifiers.randomBytes(32))
        try await send(raw, .readyReq(seq: 1, device: record.deviceID, phone: record.phoneID, eid: record.eid, cc: cc))
        guard case .readyAck(let device, let phoneID, let eid, let echo, let sc)? = try await receive(&raw) else {
            throw BLEFailure("no ready_ack")
        }
        XCTAssertEqual([device, phoneID, eid, echo], [record.deviceID, record.phoneID, record.eid, cc])
        raw.sc = sc
        return raw
    }

    /// The phone's view of a failed session: the TLS error it raised or received.
    private func failure(_ raw: inout Raw) async -> BLESecureTLSError? {
        do {
            while try await receive(&raw) != nil {}
            return nil
        } catch let error as BLESecureTLSError { return error } catch {
            XCTFail("\(error)")
            return nil
        }
    }

    // MARK: positive

    /// physical-enroll-and-task-round-trip and physical-long-task-across-session-renewal
    /// at host/cross-runtime layer; tls-no-ticket-sent, tls-no-half-rtt-data,
    /// tls-record-sender-cap observed from the phone; keepalive §8.1.
    func testEnrollHandshakeReadyTaskRoundTripKeepaliveAndRenewal() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "bench board")
        let status = try fields(board.console("pdsh-enroll status"), "status")
        XCTAssertEqual(status["state"], "committed")
        XCTAssertEqual(status["phone"], phone.key.fingerprint)
        XCTAssertEqual(status["eid"], record.eid)

        let gen = try generation(phone, record)
        let s1 = try session(board)
        let ready = try await gen.openSession(over: s1)
        XCTAssertEqual(ready.result, .ready)
        XCTAssertEqual(s1.last?.state, "open")
        let state1 = await gen.state
        XCTAssertEqual(state1, .ready)
        let v1 = await gen.grantByUser().result
        XCTAssertEqual(v1, .granted)

        XCTAssertTrue(try board.submit(Self.task("task-1", "goal-1")))
        let offer = try await gen.request(.next)
        XCTAssertEqual(offer.result, .taskOffered)
        let offered = await gen.offered
        XCTAssertEqual(offered?.task.id, "task-1")
        XCTAssertEqual(offered?.task.body.text, "Hello from the board")
        XCTAssertEqual(offered?.phase, .queued)

        let accept = try await gen.request(.transition(.accept(id: "task-1", idem: "goal-1"), resend: false))
        XCTAssertEqual(accept.result, .applied)
        var slot = try XCTUnwrap(try board.result("task-1"))
        XCTAssertEqual(slot["phase"] as? String, "accepted")

        // Keepalive (§8.1): `status` every 80 s keeps the board's 90 s idle timer from firing.
        for _ in 0..<3 {
            _ = try board.advance(ms: 80_000)
            try s1.poll()
            XCTAssertEqual(s1.last?.state, "open", "board idle timer reset by keepalive")
            let keep = try await gen.request(.status(id: "task-1", idem: "goal-1", intent: nil))
            XCTAssertEqual(keep.result, .status)
        }
        let complete = try await gen.request(.transition(.complete(id: "task-1", idem: "goal-1", output: "answer from phone",
                                                                   truncated: false), resend: false))
        XCTAssertEqual(complete.result, .applied)
        slot = try XCTUnwrap(try board.result("task-1"))
        XCTAssertEqual(slot["phase"] as? String, "completed")
        XCTAssertEqual((slot["outcome"] as? [String: Any])?["output"] as? String, "answer from phone")
        XCTAssertEqual(slot["by"] as? String, record.phoneID)
        // A duplicate complete is idempotent on the board (§9.1).
        let duplicate = try await gen.request(.transition(.complete(id: "task-1", idem: "goal-1", output: "answer from phone",
                                                                    truncated: false), resend: false))
        XCTAssertEqual(duplicate.result, .applied)

        // Board idle 90 s without a request: err timeout, close; the grant survives.
        _ = try board.advance(ms: 90_000)
        try s1.poll()
        XCTAssertEqual(s1.last?.state, "closed")
        await eventually("phone session closed") { await gen.state == .closed }
        let grant1 = await gen.grant
        XCTAssertEqual(grant1, .active, "the grant belongs to the generation, not the session")

        // Session renewal under the same grant: fresh handshake and readiness, no new grant.
        let s2 = try session(board)
        let v2 = try await gen.openSession(over: s2).result
        XCTAssertEqual(v2, .ready)
        let renewed = try await gen.request(.status(id: "task-1", idem: "goal-1", intent: nil))
        XCTAssertEqual(renewed.result, .status)
        let v3 = await gen.failedAttempts
        XCTAssertEqual(v3, 0)

        // Session lifetime 600 s on the board: close_notify only, no dispatch afterwards.
        _ = try board.advance(ms: 600_000)
        try s2.poll()
        XCTAssertEqual(s2.last?.state, "closed")
        XCTAssertEqual(s2.last?.alert, 0)
        await eventually("phone session closed after lifetime") { await gen.state == .closed }
        report("physical-enroll-and-task-round-trip", "enrollment ceremony, handshake, ready, next/accept/complete")
        report("keepalive+renewal", "3 keepalives across 240 s, idle close at 90 s, renewal under one grant, lifetime 600 s")
    }

    /// physical-board-reboot-recovery (host layer): the board reboots between
    /// accept and complete; the phone reconciles through status, never re-executes.
    func testBoardRebootRecoveryThroughStatus() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "reboot board")
        let gen = try generation(phone, record, responseWait: .milliseconds(400))
        let v4 = try await gen.openSession(over: try session(board)).result
        XCTAssertEqual(v4, .ready)
        _ = await gen.grantByUser()
        XCTAssertTrue(try board.submit(Self.task("task-2", "goal-2")))
        let v5 = try await gen.request(.next).result
        XCTAssertEqual(v5, .taskOffered)
        let v6 = try await gen.request(.transition(.accept(id: "task-2", idem: "goal-2"), resend: false)).result
        XCTAssertEqual(v6, .applied)
        try board.reboot() // power loss: RAM session gone, NVS kept
        XCTAssertEqual(try board.result("task-2")?["phase"] as? String, "accepted", "durable before its response")
        let s2 = try session(board)
        // The old session's stream is dead; the generation renews.
        await gen.end(.disconnect)
        let gen2 = try generation(phone, record, responseWait: .milliseconds(400))
        let v7 = try await gen2.openSession(over: s2).result
        XCTAssertEqual(v7, .ready)
        _ = await gen2.grantByUser()
        let intent = BLESecurePhoneSessionCore.Intent(arguments: .complete(id: "task-2", idem: "goal-2", output: "done", truncated: false),
                                                     phoneID: record.phoneID)
        let decided = try await gen2.request(.status(id: "task-2", idem: "goal-2", intent: intent))
        XCTAssertEqual(decided.result, .statusResend, "accepted, mine → resend the persisted complete")
        let v8 = try await gen2.request(.transition(intent.arguments, resend: true)).result
        XCTAssertEqual(v8, .applied)
        XCTAssertEqual(try board.result("task-2")?["phase"] as? String, "completed")
        report("physical-board-reboot-recovery", "host layer: reboot between accept and complete, status → resend → applied")
    }

    // MARK: negatives (each fails closed on both ends)

    /// M1 / physical-two-enrolled-boards-swap and tls-negative-decision-aborts-handshake
    /// (phone end): the user selected board A, board B answers.
    func testSwappedEnrolledBoardFailsPinOnPhone() async throws {
        let boardA = try newBoard(), boardB = try newBoard()
        let phone = try newPhone()
        let recordA = try enroll(phone, on: boardA, label: "A")
        try enroll(phone, on: boardB, label: "B")
        XCTAssertNotEqual(boardA.device, boardB.device)
        XCTAssertTrue(try boardB.submit(Self.task("task-b", "goal-b")))
        let gen = try generation(phone, recordA)
        let streamB = try session(boardB)
        do {
            _ = try await gen.openSession(over: streamB)
            XCTFail("phone accepted board B for selected board A")
        } catch BLESecurePhoneGeneration.Failure.tls(.certificate(.pinMismatch)) {
        } catch { XCTFail("unexpected \(error)") }
        let v9 = await gen.failedAttempts
        XCTAssertEqual(v9, 1)
        let v10 = await gen.state
        XCTAssertEqual(v10, .closed)
        await eventually("board B closed") { streamB.boardClosed }
        XCTAssertEqual(streamB.last?.state, "closed")
        XCTAssertNotEqual(streamB.last?.reason, "ready_wait", "board B never reached the application layer")
        XCTAssertEqual(try boardB.result("task-b")?["phase"] as? String, "queued")
        // The same phone still reaches board A.
        let v11 = try await gen.openSession(over: try session(boardA)).result
        XCTAssertEqual(v11, .ready)
        report("physical-two-enrolled-boards-swap", "phone pin_mismatch with bad_certificate inside the handshake; board B: \(streamB.last?.reason ?? "?")")
    }

    /// physical-unenrolled-phone and the v2.1 client-certificate outcome: the
    /// board rejects the phone's certificate after its own Finished; the phone
    /// fails before readiness whichever of the alert or bad_record_mac it sees.
    func testUnenrolledPhoneKeyFailsClosedBeforeReadiness() async throws {
        let board = try newBoard()
        let enrolled = try newPhone()
        let record = try enroll(enrolled, on: board, label: "bench")
        // A second phone key that commits the same board locally only.
        let stranger = try newPhone()
        XCTAssertEqual(stranger.enrollment.enterBoardToken(BLESecureIdentifiers.boardToken(device: record.device, eid: record.eid)), .ok)
        XCTAssertEqual(stranger.enrollment.confirm(recordDevice: record.device, eid: record.eid, device: record.device), .ok)
        let strangerRecord = try XCTUnwrap(try stranger.enrollment.committedRecord(device: record.device))
        XCTAssertTrue(try board.submit(Self.task("task-s", "goal-s")))

        // Generation: no readiness, a failed attempt, no grant possible.
        let gen = try generation(stranger, strangerRecord)
        let stream = try session(board)
        do { _ = try await gen.openSession(over: stream); XCTFail("unenrolled phone reached readiness") } catch {}
        let v12 = await gen.failedAttempts
        XCTAssertEqual(v12, 1)
        let v13 = await gen.grantByUser().result
        XCTAssertEqual(v13, .refusedNotReady)
        XCTAssertEqual(stream.last?.reason, "pin_mismatch")
        XCTAssertEqual(stream.last?.state, "closed")

        // The raw client shows what the phone observes (v2.1 §6.2: alert not guaranteed).
        var raw = try await rawHandshake(stranger, strangerRecord, board)
        XCTAssertEqual(raw.stream.last?.reason, "pin_mismatch")
        let observed = await failure(&raw)
        switch observed {
        case .receivedAlert(42)?, .sentAlert(20, _)?: break
        default: XCTFail("phone must fail closed before readiness, got \(String(describing: observed))")
        }
        XCTAssertEqual(try board.result("task-s")?["phase"] as? String, "queued")
        // The enrolled phone is still served afterwards (no state damage).
        let v14 = try await generation(enrolled, record).openSession(over: try session(board)).result
        XCTAssertEqual(v14, .ready)
        report("physical-unenrolled-phone", "board pin_mismatch after its Finished; phone observed \(String(describing: observed!)), no readiness")
    }

    /// tls-key-update-received (board end): neither end sends KeyUpdate; receipt fails the session.
    func testKeyUpdateFromPhoneFailsBoardSession() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "ku")
        var raw = try await rawReady(phone, record, board)
        try await raw.client.writeProtectedRecordForTesting(innerType: 22, content: [24, 0, 0, 1, 0]) // KeyUpdate(update_not_requested)
        XCTAssertEqual(raw.stream.last?.state, "closed")
        XCTAssertEqual(raw.stream.last?.alert, 10, "unexpected_message")
        let observed = await failure(&raw)
        XCTAssertEqual(observed, .receivedAlert(10))
        report("tls-key-update-received", "board end: unexpected_message, session closed")
    }

    /// tls-record-overflow and tls-record-invalid-not-overflow (board end, v2.1 §6.1).
    func testRecordLimitAndInvalidRecordsOnBoard() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "records")
        func statusFrame(_ seq: Int, _ sc: String) throws -> [UInt8] {
            try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(.status(seq: seq, sc: sc, id: "task-none", idem: "none")))
        }
        // Boundary: TLSInnerPlaintext of exactly 4353 bytes (TLSCiphertext 4369), padded, is accepted.
        var raw = try await rawReady(phone, record, board)
        let frame = try statusFrame(2, raw.sc)
        try await raw.client.writeProtectedRecordForTesting(innerType: 23, content: frame, padding: 4352 - frame.count)
        guard case .statusR(2, .unknown, false, nil)? = try await receive(&raw) else { return XCTFail("boundary record not served") }
        // One byte more: record_overflow, decided from the header.
        let over = try statusFrame(3, raw.sc)
        try await raw.client.writeProtectedRecordForTesting(innerType: 23, content: over, padding: 4353 - over.count)
        XCTAssertEqual(raw.stream.last?.alert, 22)
        XCTAssertEqual(raw.stream.last?.reason, "record_overflow")
        let v15 = await failure(&raw)
        XCTAssertEqual(v15, .receivedAlert(22))

        // Content over 4352 bytes without padding (TLSCiphertext 4370): record_overflow.
        raw = try await rawReady(phone, record, board)
        try await raw.client.writeProtectedRecordForTesting(innerType: 23, content: [UInt8](repeating: 0, count: 4353))
        XCTAssertEqual(raw.stream.last?.alert, 22)
        let v16 = await failure(&raw)
        XCTAssertEqual(v16, .receivedAlert(22))

        // Invalid but within the limit: never record_overflow.
        raw = try await rawReady(phone, record, board)
        try raw.stream.write([23, 3, 3, 0, 40] + [UInt8](repeating: 0x5a, count: 40)) // fails authentication
        XCTAssertEqual(raw.stream.last?.state, "closed")
        XCTAssertEqual(raw.stream.last?.alert, 20, "bad_record_mac")
        let v17 = await failure(&raw)
        XCTAssertEqual(v17, .receivedAlert(20))
        raw = try await rawReady(phone, record, board)
        try raw.stream.write([24, 3, 3, 0, 5, 1, 2, 3, 4, 5]) // unknown outer content type
        let unknownTypeAlert = raw.stream.last?.alert ?? -1
        XCTAssertEqual(raw.stream.last?.state, "closed")
        XCTAssertNotEqual(raw.stream.last?.alert, 22)
        let unknownType = await failure(&raw)
        XCTAssertNotEqual(unknownType, .receivedAlert(22))
        raw = try await rawReady(phone, record, board)
        try await raw.client.writeProtectedRecordForTesting(innerType: 0, content: [], padding: 8) // no inner content type
        let noTypeAlert = raw.stream.last?.alert ?? -1
        XCTAssertEqual(raw.stream.last?.state, "closed")
        XCTAssertNotEqual(noTypeAlert, 22)
        XCTAssertNotEqual(noTypeAlert, 0, "a fatal alert, not a silent close")
        XCTAssertNotEqual(unknownTypeAlert, 0, "a fatal alert, not a silent close")
        report("tls-record-overflow", "board end: 4369 accepted, 4370 (padded or not) record_overflow")
        report("tls-record-invalid-not-overflow", "board end: bad tag → 20, unknown outer type → \(unknownTypeAlert), no inner type → \(noTypeAlert); never 22")
    }

    /// §8.3 step 2 / §6.1 ordering: data before readiness, sequence and challenge violations.
    func testApplicationLayerViolationsCloseTheBoardSession() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "app")
        XCTAssertTrue(try board.submit(Self.task("task-3", "goal-3")))

        // Request before readiness → not_ready.
        var raw = try await rawHandshake(phone, record, board)
        try await send(raw, .next(seq: 1, sc: String(repeating: "5c", count: 32)))
        guard case .err(1, .notReady)? = try await receive(&raw) else { return XCTFail("expected err not_ready") }
        let afterErr = try await receive(&raw)
        XCTAssertNil(afterErr, "close_notify after the fatal err")
        XCTAssertEqual(raw.stream.last?.state, "closed")

        // Skipped seq → bad_sequence.
        raw = try await rawReady(phone, record, board)
        try await send(raw, .next(seq: 3, sc: raw.sc))
        guard case .err(3, .badSequence)? = try await receive(&raw) else { return XCTFail("expected err bad_sequence") }
        XCTAssertEqual(raw.stream.last?.state, "closed")

        // Replayed seq after a served request → bad_sequence.
        raw = try await rawReady(phone, record, board)
        try await send(raw, .status(seq: 2, sc: raw.sc, id: "task-3", idem: "goal-3"))
        guard case .statusR(2, .queued, false, nil)? = try await receive(&raw) else { return XCTFail("status") }
        try await send(raw, .status(seq: 2, sc: raw.sc, id: "task-3", idem: "goal-3"))
        guard case .err(2, .badSequence)? = try await receive(&raw) else { return XCTFail("expected replay bad_sequence") }

        // Stale challenge from another session → bad_challenge.
        let stale = raw.sc
        raw = try await rawReady(phone, record, board)
        XCTAssertNotEqual(stale, raw.sc, "fresh sc per session")
        try await send(raw, .next(seq: 2, sc: stale))
        guard case .err(2, .badChallenge)? = try await receive(&raw) else { return XCTFail("expected bad_challenge") }

        // Second ready_req → bad_sequence; a server-only type would not even encode.
        raw = try await rawReady(phone, record, board)
        try await send(raw, .readyReq(seq: 2, device: record.deviceID, phone: record.phoneID, eid: record.eid,
                                      cc: String(repeating: "c2", count: 32)))
        guard case .err(2, .badSequence)? = try await receive(&raw) else { return XCTFail("expected second ready bad_sequence") }

        // ready_req naming another eid → record_mismatch.
        raw = try await rawHandshake(phone, record, board)
        try await send(raw, .readyReq(seq: 1, device: record.deviceID, phone: record.phoneID,
                                      eid: String(repeating: "0", count: 32), cc: String(repeating: "c3", count: 32)))
        guard case .err(1, .recordMismatch)? = try await receive(&raw) else { return XCTFail("expected record_mismatch") }

        XCTAssertEqual(try board.result("task-3")?["phase"] as? String, "queued", "no violation changed the store")
        report("app-layer violations", "not_ready, bad_sequence (skip, replay, second ready), bad_challenge, record_mismatch; store unchanged")
    }

    /// §9.3 review assumption 5: a resend must be the very next request after
    /// the status that allowed it; lost request and lost response recovery.
    func testResendOnlyAsNextRequestAndLostReplyRecovery() async throws {
        let board = try newBoard()
        let phone = try newPhone()
        let record = try enroll(phone, on: board, label: "resend")
        let gen = try generation(phone, record, responseWait: .milliseconds(400))
        XCTAssertTrue(try board.submit(Self.task("task-4", "goal-4")))
        let s1 = try session(board)
        let v18 = try await gen.openSession(over: s1).result
        XCTAssertEqual(v18, .ready)
        _ = await gen.grantByUser()
        let v19 = try await gen.request(.next).result
        XCTAssertEqual(v19, .taskOffered)

        // The accept is lost on the way to the board: response timeout, session closed.
        s1.dropWrites = true
        let lost = try await gen.request(.transition(.accept(id: "task-4", idem: "goal-4"), resend: false))
        XCTAssertEqual(lost.result, .responseTimeout)
        await eventually("phone closed the session") { s1.phoneClosed }
        XCTAssertEqual(try board.result("task-4")?["phase"] as? String, "queued")
        let grant = await gen.grant
        XCTAssertEqual(grant, .active)

        let acceptIntent = BLESecurePhoneSessionCore.Intent(arguments: .accept(id: "task-4", idem: "goal-4"), phoneID: record.phoneID)
        let s2 = try session(board)
        let v20 = try await gen.openSession(over: s2).result
        XCTAssertEqual(v20, .ready)
        let v21 = try await gen.request(.status(id: "task-4", idem: "goal-4", intent: acceptIntent)).result
        XCTAssertEqual(v21, .statusResend)
        // Another request first voids the authorization.
        let v22 = try await gen.request(.next).result
        XCTAssertEqual(v22, .taskOffered)
        let v23 = try await gen.request(.transition(acceptIntent.arguments, resend: true)).result
        XCTAssertEqual(v23, .refusedRequery)
        XCTAssertEqual(try board.result("task-4")?["phase"] as? String, "queued", "the voided resend never reached the board")
        // Query again, then resend as the very next request.
        let v24 = try await gen.request(.status(id: "task-4", idem: "goal-4", intent: acceptIntent)).result
        XCTAssertEqual(v24, .statusResend)
        let v25 = try await gen.request(.transition(acceptIntent.arguments, resend: true)).result
        XCTAssertEqual(v25, .applied)
        XCTAssertEqual(try board.result("task-4")?["phase"] as? String, "accepted")

        // The complete is applied but its response is lost: recovery decides `applied`, no resend.
        s2.dropResponses = true
        let args = BLESecureTransitionArguments.complete(id: "task-4", idem: "goal-4", output: "result", truncated: false)
        let v26 = try await gen.request(.transition(args, resend: false)).result
        XCTAssertEqual(v26, .responseTimeout)
        await eventually("phone closed the session") { s2.phoneClosed }
        XCTAssertEqual(try board.result("task-4")?["phase"] as? String, "completed")
        let v27 = try await gen.openSession(over: try session(board)).result
        XCTAssertEqual(v27, .ready)
        let completeIntent = BLESecurePhoneSessionCore.Intent(arguments: args, phoneID: record.phoneID)
        let v28 = try await gen.request(.status(id: "task-4", idem: "goal-4", intent: completeIntent)).result
        XCTAssertEqual(v28, .statusApplied)
        // A different outcome for the same task is never applied (conflict, unresolved).
        let other = BLESecureTransitionArguments.complete(id: "task-4", idem: "goal-4", output: "other", truncated: false)
        let v29 = try await gen.request(.transition(other, resend: false)).result
        XCTAssertEqual(v29, .unresolved)
        XCTAssertEqual((try board.result("task-4")?["outcome"] as? [String: Any])?["output"] as? String, "result")
        report("phone-resend-not-next-request", "voided by an intervening next; resend as next request applied once")
        report("lost-reply recovery", "lost accept → queued → resend; lost complete response → status applied, no resend")
    }
}
