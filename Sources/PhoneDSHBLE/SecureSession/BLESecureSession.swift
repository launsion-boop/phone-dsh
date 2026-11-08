// SPDX-License-Identifier: MIT
// secure-session-v2 §8.2: one CoreBluetooth connection generation to one
// user-selected device, running successive TLS sessions. Every decision is
// taken by BLESecurePhoneSessionCore; this actor adds the TLS client, the
// framing, the monotonic clock and the timers.
//
// Constructed by BLESecureSessionCoordinator for the selected record; its
// grant is reachable only through BLEDeviceStore.grantDeviceTasks, which
// refuses in every build until the spec's §14 acceptance is recorded
// (GAP-16). Keepalive scheduling (a `status` at most 30 s after the previous
// response while a task is accepted or running) belongs to
// BLESecureTaskIntake.
import Foundation
import PhoneDSHDeviceTasks

public actor BLESecurePhoneGeneration {
    public enum Failure: Error, Equatable, Sendable {
        case tls(BLESecureTLSError)
        /// The core refused or closed; carries its result.
        case core(BLESecurePhoneSessionCore.Result)
        /// The generation ended or was superseded.
        case ended
    }

    /// Wall-clock durations for tests; defaults are the §8.1 values.
    public struct Timers: Sendable {
        public var handshake: Duration = .seconds(15)
        public var responseWait: Duration = .seconds(BLESecurePhoneSessionCore.responseWaitSeconds)
        public var lifetime: Duration = .seconds(BLESecurePhoneSessionCore.sessionLifetimeSeconds)
        public init() {}
    }

    private var core: BLESecurePhoneSessionCore
    private let key: BLESecurePhoneKey
    private let certificate: [UInt8]
    private let timers: Timers
    private let isCurrent: @Sendable () -> Bool
    private let recordStillCurrent: @Sendable () -> Bool
    private let randomBytes: @Sendable (Int) throws -> [UInt8]
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var tls: BLESecureTLSClient?
    private var frames = BLESecureFrameDecoder()
    private var reader: Task<Void, Never>?
    private var lifetimeTimer: Task<Void, Never>?
    private var waiter: CheckedContinuation<BLESecurePhoneSessionCore.Output, Error>?
    /// A decided response that arrived before the sender started waiting.
    private var parked: BLESecurePhoneSessionCore.Output?
    private var awaiting = false
    private var sessionToken = 0
    private var ended = false

    /// - Parameters:
    ///   - selected: the one committed record the user selected (v2 M1).
    ///   - parents: tasks already in the journal for this device (§8.2 local conflict).
    ///   - isCurrent: the CoreBluetooth connection-owner generation check.
    ///   - recordStillCurrent: the selected record is still committed with the
    ///     same rev and the phone key is unchanged.
    public init(key: BLESecurePhoneKey, selected: BLESecureEnrollmentRecord, parents: [DeviceTask] = [],
                timers: Timers = Timers(), isCurrent: @escaping @Sendable () -> Bool,
                recordStillCurrent: @escaping @Sendable () -> Bool,
                randomBytes: @escaping @Sendable (Int) throws -> [UInt8] = BLESecureIdentifiers.randomBytes) throws {
        self.key = key
        self.certificate = try BLESecureCertificate.make(role: .phone, signer: key.signer)
        let eligible = selected.phone == key.fingerprint ? selected : BLESecureEnrollmentRecord(
            state: .revoked, device: selected.device, phone: selected.phone, eid: selected.eid, rev: selected.rev)
        self.core = BLESecurePhoneSessionCore(phone: key.fingerprint, selected: .init(eligible), parents: parents)
        self.timers = timers
        self.isCurrent = isCurrent
        self.recordStillCurrent = recordStillCurrent
        self.randomBytes = randomBytes
        self.start = ContinuousClock().now
    }

    public var state: BLESecurePhoneSessionCore.SessionState { core.state }
    public var grant: BLESecurePhoneSessionCore.Grant { core.grant }
    public var failedAttempts: Int { core.failedAttempts }
    public var offered: (task: DeviceTask, phase: BLESecureTaskPhase)? { core.offered }

    /// True when a keepalive `status` is due (≤ 30 s after the last response).
    public var keepaliveDue: Bool {
        tick()
        return core.state == .ready && !core.hasOutstanding
            && core.now - core.lastResponseAt >= BLESecurePhoneSessionCore.keepaliveSeconds - 5
    }

    private func tick() {
        let elapsed = Int((clock.now - start).components.seconds)
        if elapsed > core.now { apply(core.elapse(seconds: elapsed - core.now)) }
    }

    public func updateParents(_ parents: [DeviceTask]) { core.updateParents(parents) }

    // MARK: sessions

    /// Opens one session over `stream`: handshake pinned to the selected
    /// device, `ready_req`, `ready_ack`. Returns the core's readiness output.
    @discardableResult
    public func openSession(over stream: BLESecureByteStream) async throws -> BLESecurePhoneSessionCore.Output {
        tick()
        guard !ended, core.state == .closed, isCurrent(), recordStillCurrent() else { stream.close(); throw Failure.ended }
        // §8.2 step 1: only with the selected record committed; nothing is sent otherwise.
        guard core.selected.state == .committed else { stream.close(); throw Failure.core(.refusedNotEligible) }
        sessionToken += 1
        let token = sessionToken
        let client = BLESecureTLSClient(stream: stream, credentials: .init(certificate: certificate, signer: key.signer),
                                        selectedDevice: core.selected.device, randomBytes: randomBytes)
        let serverKey: String
        do {
            serverKey = try await withDeadline(timers.handshake, stream: stream) { try await client.handshake() }
        } catch {
            let output = core.handshakeFailed(Self.handshakeResult(error))
            throw (error as? BLESecureTLSError).map(Failure.tls) ?? Failure.core(output.result)
        }
        guard token == sessionToken, !ended, isCurrent(), recordStillCurrent() else { await client.close(); throw Failure.ended }
        tick()
        let challenge = BLESecureIdentifiers.hex(try randomBytes(32))
        let sent = core.handshake(serverKey: serverKey, cc: challenge)
        guard sent.result == .sent, let message = sent.send else { await client.close(); throw Failure.core(sent.result) }
        tls = client
        frames = BLESecureFrameDecoder()
        startReader(client, token: token)
        lifetimeTimer = Task { [timers] in
            try? await Task.sleep(for: timers.lifetime)
            guard !Task.isCancelled else { return }
            await self.expireSession(token)
        }
        let output = try await exchange(message, token: token)
        guard output.result == .ready else { throw Failure.core(output.result) }
        return output
    }

    private static func handshakeResult(_ error: Error) -> BLESecurePhoneSessionCore.Result {
        if case BLESecureTLSError.certificate(.pinMismatch)? = error as? BLESecureTLSError { return .pinMismatch }
        return .fatal
    }

    /// A session attempt that failed before the TLS client ran (no PSM, CoC
    /// refused or timed out): a failed attempt toward the limit of three (§8.1).
    @discardableResult
    public func sessionAttemptFailed() -> BLESecurePhoneSessionCore.Output {
        tick()
        guard !ended, core.state == .closed else { return BLESecurePhoneSessionCore.Output(result: .ignored, send: nil, close: false, state: core.state, grant: core.grant) }
        return core.handshakeFailed(.fatal)
    }

    public var isEnded: Bool { ended }

    /// Foreground user grant after readiness (§8.2 "Generation and grant").
    public func grantByUser() -> BLESecurePhoneSessionCore.Output { tick(); return core.grantByUser() }

    /// Sends one request through the core and returns its decided output and
    /// the server message it was decided on.
    public func request(_ request: BLESecurePhoneSessionCore.Request) async throws -> BLESecurePhoneSessionCore.Output {
        tick()
        guard isCurrent(), recordStillCurrent() else { end(.recordChanged); throw Failure.ended }
        let output = core.request(request)
        apply(output)
        guard output.result == .sent, let message = output.send else { return output }
        return try await exchange(message, token: sessionToken)
    }

    /// Ends the generation (disconnect, background, forget, record change, key loss).
    public func end(_ reason: BLESecurePhoneSessionCore.GenerationEnd) {
        ended = true
        apply(core.end(reason))
    }

    // MARK: I/O

    private func exchange(_ message: BLESecureClientMessage, token: Int) async throws -> BLESecurePhoneSessionCore.Output {
        guard let tls else { throw Failure.ended }
        parked = nil
        awaiting = true
        defer { awaiting = false }
        do { try await tls.send(try BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode(message))) }
        catch {
            apply(core.receive(nil))
            throw Failure.tls(error as? BLESecureTLSError ?? .transportClosed)
        }
        let timer = Task { [timers] in
            try? await Task.sleep(for: timers.responseWait)
            guard !Task.isCancelled else { return }
            await self.responseTimedOut(token)
        }
        defer { timer.cancel() }
        if let parked { self.parked = nil; return parked }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    private func responseTimedOut(_ token: Int) {
        guard token == sessionToken, waiter != nil else { return }
        // The wall-clock wait expired: let the core see the full response wait.
        let output = core.elapse(seconds: BLESecurePhoneSessionCore.responseWaitSeconds)
        apply(output)
    }

    private func expireSession(_ token: Int) {
        guard token == sessionToken, core.state != .closed else { return }
        let output = core.elapse(seconds: BLESecurePhoneSessionCore.sessionLifetimeSeconds)
        apply(output)
    }

    private func startReader(_ client: BLESecureTLSClient, token: Int) {
        reader = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let chunk = try await client.receive() else { await self?.transportEnded(token); return }
                    await self?.deliver(chunk, token: token)
                } catch {
                    await self?.transportEnded(token)
                    return
                }
            }
        }
    }

    private func deliver(_ chunk: [UInt8], token: Int) {
        guard token == sessionToken, core.state != .closed else { return }
        let (payloads, error) = frames.push(chunk)
        for payload in payloads {
            tick()
            apply(core.receive(try? BLESecureMessageCodec.decodeServer(payload)))
            if core.state == .closed { return }
        }
        if error != nil { apply(core.receive(nil)) }
    }

    private func transportEnded(_ token: Int) {
        guard token == sessionToken, core.state != .closed else { return }
        // CoC loss / TLS failure: fatal without an `err` message.
        _ = frames.finish()
        apply(core.receive(.err(re: 0, code: .internal)))
    }

    /// Applies an output: performs its send and close, resumes a waiter.
    private func apply(_ output: BLESecurePhoneSessionCore.Output) {
        if output.close {
            // Invalidate before asynchronous teardown (§8.4).
            sessionToken += 1
            reader?.cancel(); reader = nil
            lifetimeTimer?.cancel(); lifetimeTimer = nil
            if let client = tls {
                tls = nil
                let err = output.send.flatMap { try? BLESecureFrameEncoder.frame(BLESecureMessageCodec.encode($0)) }
                Task {
                    if let err { try? await client.send(err) }
                    await client.close()
                }
            }
        }
        guard output.result != .sent, output.result != .ok || output.close else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: output)
        } else if awaiting {
            parked = output
        }
    }

    private func withDeadline<T: Sendable>(_ limit: Duration, stream: BLESecureByteStream,
                                           _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                stream.close() // unblocks the handshake's pending read
                throw BLESecureTLSError.transportClosed
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
