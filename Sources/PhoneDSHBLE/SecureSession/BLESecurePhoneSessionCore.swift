// SPDX-License-Identifier: MIT
// secure-session-v2 §8.1-§8.2, §9.3: the phone's connection-generation state
// machine as a pure value type. It holds one selected record, the grant and
// its windows, the failed-attempt count, and the state of the current
// session (readiness, seq, sc, outstanding request, resend authorization).
// I/O, TLS and real clocks live in BLESecurePhoneGeneration; the shared
// fixtures drive this type directly.
import Foundation
import PhoneDSHDeviceTasks

public struct BLESecurePhoneSessionCore: Sendable {
    public static let readyWaitSeconds = 10
    public static let responseWaitSeconds = 10
    public static let keepaliveSeconds = 30
    public static let sessionLifetimeSeconds = 600
    public static let grantAcceptWindowSeconds = 1800
    public static let grantReportExtensionSeconds = 600
    public static let maxFailedSessionAttempts = 3

    public enum SessionState: String, Sendable { case closed, readyWait = "ready_wait", ready }
    public enum Grant: String, Sendable { case none, active, reportOnly = "report_only" }

    public enum Result: String, Sendable {
        case sent, ok, ready, granted, ignored
        case refusedNotEligible = "refused_not_eligible", refusedNotReady = "refused_not_ready"
        case refusedBusy = "refused_busy", refusedNoGrant = "refused_no_grant", refusedWindow = "refused_window"
        case refusedNextSuspended = "refused_next_suspended", refusedRequery = "refused_requery"
        case refusedSeqExhausted = "refused_seq_exhausted"
        case pinMismatch = "pin_mismatch", fatal, malformed, recordMismatch = "record_mismatch"
        case badChallenge = "bad_challenge", responseTimeout = "response_timeout", lifetimeExpired = "lifetime_expired"
        case disconnect, background, forget, recordChanged = "record_changed", keyLost = "key_lost"
        case userRevoked = "user_revoked"
        case unresolved, applied, noTask = "no_task", localConflict = "local_conflict"
        case taskOffered = "task_offered", acceptedOffer = "accepted_offer", status
        case statusApplied = "status_applied", statusResend = "status_resend"
        case statusUnresolved = "status_unresolved", statusRetryQuery = "status_retry_query"
    }

    /// Events that end the whole generation (and its grant).
    public enum GenerationEnd: String, Sendable {
        case disconnect, background, forget, recordChanged = "record_changed", keyLost = "key_lost"
        /// The user revoked the grant (§8.2 "user revocation").
        case userRevoked = "user_revoked"
    }

    public struct Record: Equatable, Sendable {
        public let device: String
        public let eid: String
        public let rev: UInt32
        public let state: BLESecureEnrollmentState
        public init(device: String, eid: String, rev: UInt32, state: BLESecureEnrollmentState) {
            self.device = device; self.eid = eid; self.rev = rev; self.state = state
        }
        public init(_ record: BLESecureEnrollmentRecord) {
            self.init(device: record.device, eid: record.eid, rev: record.rev, state: record.state)
        }
    }

    /// A persisted transition intent being reconciled through `status` (§9.3).
    public struct Intent: Equatable, Sendable {
        public let arguments: BLESecureTransitionArguments
        public let phoneID: String
        public init(arguments: BLESecureTransitionArguments, phoneID: String) { self.arguments = arguments; self.phoneID = phoneID }
    }

    public enum Request: Equatable, Sendable {
        case next
        /// `resend` marks a resend of persisted arguments after a `status_r`
        /// that allowed it (§9.3); it must be the very next request.
        case transition(BLESecureTransitionArguments, resend: Bool)
        case status(id: String, idem: String, intent: Intent?)

        var name: String {
            switch self {
            case .next: return "next"
            case .transition(let a, _): return a.action.rawValue
            case .status: return "status"
            }
        }
    }

    public struct Output: Equatable, Sendable {
        public let result: Result
        public let send: BLESecureClientMessage?
        public let close: Bool
        public let state: SessionState
        public let grant: Grant
    }

    public let phone: String
    public let selected: Record
    private var parents: [DeviceTask]
    public private(set) var state: SessionState = .closed
    public private(set) var grant: Grant = .none
    private var grantAt: Int?
    public private(set) var now = 0
    private var everReady = false
    public private(set) var failedAttempts = 0
    // session
    public private(set) var lastSeq = 0
    public private(set) var sc: String?
    private var cc: String?
    private var outstanding: (request: Request, seq: Int)?
    private var sentAt = 0
    private var sessionStart = 0
    private var nextSuspended = false
    private var resendArmed: BLESecureTransitionArguments?
    /// The task offered by the last accepted `next_r`, for the caller.
    public private(set) var offered: (task: DeviceTask, phase: BLESecureTaskPhase)?
    /// The time of the last response, for the ≤ 30 s keepalive.
    public private(set) var lastResponseAt = 0

    /// - Parameters:
    ///   - phone: the current phone key fingerprint.
    ///   - selected: the one record the user selected (v2 M1).
    ///   - parents: tasks of existing parent records of this device, for the
    ///     local idempotency conflict check of §8.2.
    public init(phone: String, selected: Record, parents: [DeviceTask] = []) {
        self.phone = phone
        self.selected = selected
        self.parents = parents
    }

    public var hasOutstanding: Bool { outstanding != nil }

    public mutating func updateParents(_ parents: [DeviceTask]) { self.parents = parents }

    private mutating func resetSession() {
        lastSeq = 0; sc = nil; cc = nil; outstanding = nil
        sentAt = 0; sessionStart = now; nextSuspended = false; resendArmed = nil
        offered = nil
    }

    private func out(_ result: Result, _ send: BLESecureClientMessage? = nil, close: Bool = false) -> Output {
        Output(result: result, send: send, close: close, state: state, grant: grant)
    }

    private mutating func closeSession(_ result: Result, _ send: BLESecureClientMessage? = nil, failedAttempt: Bool = false) -> Output {
        state = .closed
        if failedAttempt {
            failedAttempts += 1
            if failedAttempts >= Self.maxFailedSessionAttempts { grant = .none; grantAt = nil }
        }
        resetSession()
        return out(result, send, close: true)
    }

    // MARK: events

    /// The local TLS handshake returned with the server key `serverKey`
    /// (the pinned fingerprint). Sends `ready_req` with the fresh `cc`.
    public mutating func handshake(serverKey: String, cc challenge: String) -> Output {
        guard state == .closed, selected.state == .committed else { return out(.refusedNotEligible) }
        resetSession()
        guard serverKey == selected.device else { return closeSession(.pinMismatch, failedAttempt: true) }
        cc = challenge
        state = .readyWait
        lastSeq = 1
        outstanding = (.next, 1) // placeholder; readiness is tracked by `state`
        sentAt = now
        return out(.sent, .readyReq(seq: 1, device: BLESecureIdentifiers.deviceID(fingerprint: selected.device),
                                    phone: BLESecureIdentifiers.phoneID(fingerprint: phone), eid: selected.eid, cc: challenge))
    }

    /// The handshake itself failed (pin, profile, transport): a failed attempt.
    public mutating func handshakeFailed(_ result: Result = .pinMismatch) -> Output {
        guard state == .closed, selected.state == .committed else { return out(.refusedNotEligible) }
        resetSession()
        return closeSession(result, failedAttempt: true)
    }

    /// A foreground user grant: only after a session of this generation
    /// reached readiness, and while ready.
    public mutating func grantByUser() -> Output {
        guard state == .ready, everReady else { return out(.refusedNotReady) }
        grant = .active; grantAt = now
        return out(.granted)
    }

    public mutating func end(_ reason: GenerationEnd) -> Output {
        state = .closed
        grant = .none; grantAt = nil
        everReady = false; failedAttempts = 0
        resetSession()
        return out(Result(rawValue: reason.rawValue)!, nil, close: true)
    }

    /// Test hook of §13 (and the 65535 boundary).
    public mutating func setLastSeq(_ seq: Int) -> Output { lastSeq = seq; return out(.ok) }

    /// Advances the monotonic clock; applies grant windows, lifetime and the
    /// response wait.
    public mutating func elapse(seconds: Int) -> Output {
        now += seconds
        if grant != .none, let grantAt {
            let age = now - grantAt
            if age >= Self.grantAcceptWindowSeconds + Self.grantReportExtensionSeconds { grant = .none; self.grantAt = nil }
            else if age >= Self.grantAcceptWindowSeconds { grant = .reportOnly }
        }
        if state == .closed { return out(.ok) }
        if now - sessionStart >= Self.sessionLifetimeSeconds { return closeSession(.lifetimeExpired) }
        if outstanding != nil, now - sentAt >= Self.responseWaitSeconds {
            return closeSession(.responseTimeout, .err(code: .timeout), failedAttempt: state == .readyWait)
        }
        return out(.ok)
    }

    // MARK: requests

    public mutating func request(_ request: Request) -> Output {
        guard state == .ready else { return out(.refusedNotReady) }
        guard outstanding == nil else { return out(.refusedBusy) }
        guard grant != .none else { return out(.refusedNoGrant) }
        let opensWork: Bool
        switch request { case .next: opensWork = true; case .transition(let a, _): opensWork = a.action == .accept; case .status: opensWork = false }
        if opensWork && grant != .active { return out(.refusedWindow) }
        if case .next = request, nextSuspended { return out(.refusedNextSuspended) }
        let armed = resendArmed
        resendArmed = nil
        if case .transition(let args, true) = request, armed != args { return out(.refusedRequery) }
        if lastSeq >= 65535 { return closeSession(.refusedSeqExhausted) }
        lastSeq += 1
        let seq = lastSeq, sc = self.sc!
        let message: BLESecureClientMessage
        switch request {
        case .next: message = .next(seq: seq, sc: sc)
        case .status(let id, let idem, _): message = .status(seq: seq, sc: sc, id: id, idem: idem)
        case .transition(let a, _):
            switch a {
            case .accept(let id, let idem): message = .accept(seq: seq, sc: sc, id: id, idem: idem)
            case .complete(let id, let idem, let output, let truncated):
                message = .complete(seq: seq, sc: sc, id: id, idem: idem, output: output, truncated: truncated)
            case .fail(let id, let idem, let kind, let text):
                message = .fail(seq: seq, sc: sc, id: id, idem: idem, kind: kind, message: text)
            }
        }
        outstanding = (request, seq)
        sentAt = now
        return out(.sent, message)
    }

    // MARK: responses

    /// One received server message; nil for a payload that failed §7.2
    /// decoding (including an offered task that fails task-delegation
    /// validation).
    public mutating func receive(_ message: BLESecureServerMessage?) -> Output {
        guard state != .closed else { return out(.ignored) }
        guard let message else { return closeSession(.malformed, .err(code: .malformed), failedAttempt: state == .readyWait) }
        if state == .readyWait {
            if case .err = message { return closeSession(.fatal, failedAttempt: true) }
            guard case .readyAck(let device, let phoneID, let eid, let echo, let serverChallenge) = message else {
                return closeSession(.malformed, .err(code: .malformed), failedAttempt: true)
            }
            guard device == BLESecureIdentifiers.deviceID(fingerprint: selected.device),
                  phoneID == BLESecureIdentifiers.phoneID(fingerprint: phone), eid == selected.eid else {
                return closeSession(.recordMismatch, .err(code: .recordMismatch), failedAttempt: true)
            }
            guard echo == cc else { return closeSession(.badChallenge, .err(code: .badChallenge), failedAttempt: true) }
            state = .ready; sc = serverChallenge; outstanding = nil
            everReady = true; failedAttempts = 0
            lastResponseAt = now
            return out(.ready)
        }
        let pending = outstanding
        if case .err(let re, let code) = message, code.isFatal, re == 0 || re == pending?.seq {
            return closeSession(.fatal)
        }
        guard let pending, message.typeName != "ready_ack", message.re == pending.seq else {
            return closeSession(.malformed, .err(code: .malformed))
        }
        outstanding = nil
        lastResponseAt = now
        if case .err(_, let code) = message {
            switch pending.request {
            case .transition: if !code.isFatal { return out(.unresolved) }
            case .status: if code == .conflict { return out(.unresolved) }
            case .next: break
            }
            return closeSession(.malformed, .err(code: .malformed))
        }
        switch pending.request {
        case .next:
            guard case .nextR(_, let task, let phase) = message else { return closeSession(.malformed, .err(code: .malformed)) }
            guard let task, let phase else { return out(.noTask) }
            for parent in parents {
                let sameKey = parent.idempotencyKey == task.idempotencyKey
                if (sameKey && parent != task) || (parent.id == task.id && !sameKey) {
                    nextSuspended = true
                    return out(.localConflict)
                }
            }
            offered = (task, phase)
            return out(phase == .queued ? .taskOffered : .acceptedOffer)
        case .transition(let args, _):
            let expected: BLESecureTaskPhase = args.action == .accept ? .accepted : args.action == .complete ? .completed : .failed
            guard case .r(_, _, let phase) = message, phase == expected else { return closeSession(.malformed, .err(code: .malformed)) }
            return out(.applied)
        case .status(_, _, let intent):
            guard case .statusR(_, let phase, let mine, let outcome) = message else { return closeSession(.malformed, .err(code: .malformed)) }
            guard let intent else { return out(.status) }
            let observation = BLESecureStatusObservation.status(phase: phase.rawValue, mine: mine, outcome: outcome)
            let decision: BLESecureRecoveryDecision = intent.phoneID == BLESecureIdentifiers.phoneID(fingerprint: phone)
                ? BLESecureRecovery.decide(arguments: intent.arguments, observation: observation) : .unresolved
            if decision == .resend { resendArmed = intent.arguments }
            return out(Result(rawValue: "status_" + decision.rawValue)!)
        }
    }
}
