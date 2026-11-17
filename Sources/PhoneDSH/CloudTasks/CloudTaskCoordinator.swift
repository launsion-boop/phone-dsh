// SPDX-License-Identifier: MIT
// phone-dsh SDK — PhoneDSH: phone task queue coordinator (phone side).
//
// spec/v1/cloud-tasks.md §5–§8. One actor runs one pull → admit → ack pass at
// a time. It has no timer and never polls while idle: the app triggers a pass
// when it becomes active, after sign-in, after a task push and when the user
// turns the feature on. It never boots an engine; it only writes into the
// admission journal through the injected `admit` closure and reports what the
// journal later says. Accepted ≠ durable ≠ executed: `admitted` is sent only
// after `admit` returned, and a terminal state only from a record's stage.

import Foundation

/// What the coordinator asks the admission journal to admit (§7). The app
/// adds `principal = "account:" + <signed-in user id>`,
/// `source = {kind: "cloud-task", id: deviceID}`, `sourceRequestId = taskID`
/// and a fresh `downstreamId`.
public struct CloudTaskAdmissionRequest: Equatable, Sendable {
    /// `source.id`.
    public var deviceID: String
    /// `sourceRequestId`.
    public var taskID: String
    /// `target.id` is the `sessionId` / `botId`.
    public var target: CloudTaskTarget
    /// The opened task text.
    public var text: String
    public var expiresAtMs: Int64
}

/// The admission journal's answer (external-admission.md §2).
public enum CloudTaskAdmissionResult: Equatable, Sendable {
    /// Written now; `admissionID` is the record's 64-hex id.
    case admitted(admissionID: String)
    /// A record for this task already exists with the same target and content.
    case duplicate(admissionID: String)
    case invalid
    case conflict
    /// Journal full: the task stays with the cloud and is redelivered.
    case capacity
    /// The write failed (or the phone is locked): no receipt, no ack.
    case storage
}

/// A cloud-task admission record that left the pending stages.
public struct CloudTaskTerminalReport: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case completed
        /// The record's `reason`, as stored.
        case failed(reason: String?)
        case expired
        case cancelled
        case unknown
    }

    /// The record's `sourceRequestId`.
    public var taskID: String
    public var admissionID: String
    public var stage: Stage

    public init(taskID: String, admissionID: String, stage: Stage) {
        self.taskID = taskID
        self.admissionID = admissionID
        self.stage = stage
    }

    /// §7: the ack this stage produces. The mapping is total: a `failed`
    /// record keeps its reason when it is `target_missing`, `not_authorized`
    /// or `retry_exhausted`; any other or absent reason is `run_failed`.
    public var ackState: CloudTaskAck.State {
        switch stage {
        case .completed: return .completed
        case .unknown: return .unknown
        case .expired: return .failed(.expired)
        case .cancelled: return .failed(.cancelled)
        case .failed(let reason):
            switch reason {
            case "target_missing": return .failed(.targetMissing)
            case "not_authorized": return .failed(.notAuthorized)
            case "retry_exhausted": return .failed(.retryExhausted)
            default: return .failed(.runFailed)
            }
        }
    }
}

/// The app's side of the coordinator. Every closure may be called off the main actor.
public struct CloudTaskHost: Sendable {
    /// Does this session / Bot exist on the phone right now?
    public var targetExists: @Sendable (CloudTaskTarget) async -> Bool
    /// Admits into the external admission journal and returns only after the journal write returned.
    public var admit: @Sendable (CloudTaskAdmissionRequest) async -> CloudTaskAdmissionResult
    /// The terminal cloud-task records (`source.id == deviceID`) the journal still holds.
    public var terminalReports: @Sendable (_ deviceID: String) async -> [CloudTaskTerminalReport]
    /// The cloud settled the terminal ack of this task; it need not be reported again.
    public var terminalSettled: @Sendable (_ taskID: String) async -> Void

    public init(targetExists: @escaping @Sendable (CloudTaskTarget) async -> Bool,
                admit: @escaping @Sendable (CloudTaskAdmissionRequest) async -> CloudTaskAdmissionResult,
                terminalReports: @escaping @Sendable (_ deviceID: String) async -> [CloudTaskTerminalReport] = { _ in [] },
                terminalSettled: @escaping @Sendable (_ taskID: String) async -> Void = { _ in }) {
        self.targetExists = targetExists
        self.admit = admit
        self.terminalReports = terminalReports
        self.terminalSettled = terminalSettled
    }
}

/// Why a pass was asked for. Every trigger runs the same single pass.
public enum CloudTaskTrigger: Equatable, Sendable {
    case appActive
    /// A (possibly different) account signed in: the device is registered again.
    case signedIn
    case push
    case enabled
}

/// Where the feature stands after a pass.
public enum CloudTaskStatus: Equatable, Sendable {
    /// The pass ran to the end of the queue (or its bound).
    case ready
    /// The switch is off; nothing was sent.
    case disabled
    /// No account is signed in; nothing was sent.
    case signedOut
    /// The cloud answered `404`: it does not serve the phone task routes (or
    /// no longer knows this device). Nothing is retried until the next trigger.
    case unavailable
    /// `409 device_limit`: the account already has 8 devices.
    case deviceLimit
    /// The key store cannot be used right now (before first unlock) or the
    /// install's device id is unusable. Nothing was acknowledged.
    case storeUnavailable
    /// The pass stopped on this error; unacknowledged tasks are redelivered.
    case failed(CloudTaskClientError)
}

/// What one pass did.
public struct CloudTaskPassReport: Equatable, Sendable {
    public var status: CloudTaskStatus
    /// Tasks received from the cloud.
    public var pulled = 0
    /// `admissionId`s acknowledged `admitted` (new or duplicate), in order.
    /// When non-empty the app runs its admission dispatch entry.
    public var admitted: [String] = []
    /// Tasks acknowledged `rejected` or `expired`, undecodable elements included.
    public var refused = 0
    /// Elements left unacknowledged (`capacity` / `storage`, or no usable `task_id`); the lease redelivers them.
    public var deferred = 0
    /// Terminal acks the cloud settled in this pass.
    public var terminalSettled = 0

    public init(status: CloudTaskStatus) {
        self.status = status
    }
}

public actor CloudTaskCoordinator {
    public struct Configuration: Sendable {
        /// 1–32 characters, sent as `app_version`.
        public var appVersion: String
        /// Pull → ack rounds per pass; a pass handles at most `maxRounds × 16` tasks.
        public var maxRounds: Int
        public var leaseSeconds: Int
        /// Wall clock in milliseconds.
        public var now: @Sendable () -> Int64

        public init(appVersion: String, maxRounds: Int = 8, leaseSeconds: Int = 300,
                    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
            self.appVersion = appVersion
            self.maxRounds = maxRounds
            self.leaseSeconds = leaseSeconds
            self.now = now
        }
    }

    private struct Registered: Equatable {
        var deviceID: String
        var registration: CloudTaskDeviceRegistration
    }

    private let configuration: Configuration
    private let client: CloudTaskClient
    private let tokens: any TonoAccessTokenSource
    private let keyStore: any CloudTaskKeyStore
    private let preferences: CloudTaskPreferences
    private let host: CloudTaskHost

    private var push: CloudTaskPush?
    /// What this process registered; never persisted, so each launch registers once.
    private var registered: Registered?
    private var inFlight: Task<CloudTaskPassReport, Never>?
    /// Turning the feature off could not reach the cloud; retried on the next trigger.
    private var deleteOwed = false
    private var settledTerminal: Set<String> = []
    /// The most recent pass, for a settings screen.
    public private(set) var lastReport: CloudTaskPassReport?

    /// - Parameters:
    ///   - tokens: production passes `TonoAccountSession.shared`.
    ///   - transport: production passes `URLSessionCloudTaskTransport()`.
    ///   - keyStore: production passes `KeychainCloudTaskKeyStore()`.
    public init(configuration: Configuration,
                host: CloudTaskHost,
                tokens: any TonoAccessTokenSource,
                transport: any CloudTaskTransport,
                keyStore: any CloudTaskKeyStore,
                defaults: UserDefaults = .standard,
                sleep: (@Sendable (TimeInterval) async -> Void)? = nil) {
        self.configuration = configuration
        self.host = host
        self.tokens = tokens
        self.keyStore = keyStore
        self.preferences = CloudTaskPreferences(defaults: defaults)
        self.client = sleep.map { CloudTaskClient(transport: transport, tokens: tokens, sleep: $0) }
            ?? CloudTaskClient(transport: transport, tokens: tokens)
    }

    // MARK: - App entry points

    /// The user's switch (absent = off).
    public nonisolated var isEnabled: Bool { preferences.isEnabled }

    /// Runs one pass, or joins the pass already running. Call when the app
    /// becomes active, after sign-in and after a task push. Does nothing on
    /// the network while the feature is off or no account is signed in.
    @discardableResult
    public func run(_ trigger: CloudTaskTrigger = .appActive) async -> CloudTaskPassReport {
        if trigger == .signedIn { registered = nil }
        if let inFlight { return await inFlight.value }
        let task = Task { () -> CloudTaskPassReport in
            let report = await self.pass()
            self.lastReport = report
            self.inFlight = nil
            return report
        }
        inFlight = task
        return await task.value
    }

    /// `application(_:didReceiveRemoteNotification:)`: runs one pass for a §8
    /// task push and returns its report; returns `nil` (and does nothing) for
    /// any other payload, including an unknown `pdsh.kind` or `pdsh.v`.
    public nonisolated func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> CloudTaskPassReport? {
        guard CloudTasks.isTaskPush(userInfo) else { return nil }
        return await run(.push)
    }

    /// The APNs address to register (`nil`: none). Takes effect on the next
    /// pass; returns false, and registers no push, for a value the contract rejects.
    @discardableResult
    public func setPush(_ push: CloudTaskPush?) -> Bool {
        guard let push else { self.push = nil; return true }
        guard (try? CloudTaskPush(json: push.json)) != nil else { self.push = nil; return false }
        self.push = push
        return true
    }

    /// The settings switch. On: stores the preference and runs a pass (which
    /// registers the device). Off: stores the preference and deletes the
    /// registration; the report says whether the cloud confirmed it.
    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> CloudTaskPassReport {
        if enabled {
            preferences.setEnabled(true)
            deleteOwed = false
            return await run(.enabled)
        }
        let wasEnabled = preferences.isEnabled
        preferences.setEnabled(false)
        _ = await inFlight?.value
        guard wasEnabled || deleteOwed else { return CloudTaskPassReport(status: .disabled) }
        let report = CloudTaskPassReport(status: await deleteRegistration())
        deleteOwed = report.status != .disabled && report.status != .signedOut
        lastReport = report
        return report
    }

    /// Call **before** the account signs out, while its token still works:
    /// deletes the registration (§2). The switch itself is left as it is.
    /// Returns false when the cloud did not confirm.
    @discardableResult
    public func accountWillSignOut() async -> Bool {
        _ = await inFlight?.value
        guard preferences.isEnabled else { return true }
        let status = await deleteRegistration()
        return status == .disabled || status == .signedOut
    }

    /// Makes a new sealing key; the next pass registers it. The cloud rejects
    /// the tasks still sealed to the old key (`key_replaced`), and the old
    /// private key is deleted once that registration is acknowledged.
    public func rotateKey() throws {
        try keyStore.save(CloudTaskKey.generate(nowMs: configuration.now()))
    }

    // MARK: - One pass

    private func pass() async -> CloudTaskPassReport {
        var report = CloudTaskPassReport(status: .ready)
        guard preferences.isEnabled else {
            report.status = .disabled
            if deleteOwed {
                report.status = await deleteRegistration()
                deleteOwed = report.status != .disabled && report.status != .signedOut
            }
            return report
        }
        guard tokens.hasSession else { report.status = .signedOut; return report }
        guard let deviceID = preferences.deviceID() else { report.status = .storeUnavailable; return report }

        do {
            try await register(deviceID: deviceID)
            try await sendTerminalAcks(deviceID: deviceID, report: &report)
            for _ in 0..<max(1, configuration.maxRounds) {
                guard preferences.isEnabled else { break }
                let pulled = try await client.pull(deviceID: deviceID, leaseSeconds: configuration.leaseSeconds)
                guard !pulled.elements.isEmpty else { break }
                report.pulled += pulled.elements.count
                // The cloud's clock judges expiry; the phone's is only the fallback.
                let nowMs = pulled.serverTimeMs ?? configuration.now()
                var acks: [CloudTaskAck] = []
                var journalDeferred = false
                for element in pulled.elements {
                    switch element {
                    case .task(let task):
                        if let ack = try await decide(task, deviceID: deviceID, nowMs: nowMs) {
                            acks.append(ack)
                        } else {
                            journalDeferred = true
                            report.deferred += 1
                        }
                    case .undecodable(let taskID):
                        acks.append(CloudTaskAck(taskID: taskID, state: .rejected(.invalid)))
                    case .skipped:
                        report.deferred += 1
                    }
                }
                var start = 0
                while start < acks.count {
                    let chunk = Array(acks[start..<min(start + CloudTasks.batchMax, acks.count)])
                    start += chunk.count
                    _ = try await client.acknowledge(CloudTaskAckBatch(deviceID: deviceID, acks: chunk))
                    for ack in chunk {
                        if case .admitted(let admissionID) = ack.state { report.admitted.append(admissionID) } else { report.refused += 1 }
                    }
                }
                // A full journal or a failing disk will not improve within this pass.
                if journalDeferred { break }
            }
        } catch let error as CloudTaskClientError {
            report.status = status(for: error)
        } catch {
            report.status = .storeUnavailable
        }
        return report
    }

    private func status(for error: CloudTaskClientError) -> CloudTaskStatus {
        switch error {
        case .signedOut: return .signedOut
        case .notFound:
            // Not served, or the device is gone: register again on the next trigger, not now.
            registered = nil
            return .unavailable
        case .http(status: 409, code: let code) where code == "device_limit": return .deviceLimit
        default: return .failed(error)
        }
    }

    /// Registers when this process has not registered exactly this body yet.
    private func register(deviceID: String) async throws {
        var key = try keyStore.currentKey()
        if key == nil {
            let made = CloudTaskKey.generate(nowMs: configuration.now())
            try keyStore.save(made)
            key = made
        }
        guard let first = key else { throw CloudTaskKeyStoreError.corrupt }
        do {
            try await register(deviceID: deviceID, key: first)
        } catch CloudTaskClientError.http(status: 409, code: let code) where code == "key_mismatch" {
            // §2 (v1.4): the cloud holds another public key under this `key_id`
            // (a restored install, a lost Keychain item). A `key_id` names one
            // key, so make a new one and register again: once, never in a loop.
            // A second refusal ends the pass; the next trigger starts from the new key.
            let made = CloudTaskKey.generate(nowMs: max(configuration.now(), first.createdAtMs + 1))
            try keyStore.save(made)
            try await register(deviceID: deviceID, key: made)
        }
    }

    private func register(deviceID: String, key: CloudTaskKey) async throws {
        guard let deviceKey = key.deviceKey else { throw CloudTaskKeyStoreError.corrupt }
        let wanted = Registered(deviceID: deviceID, registration: CloudTaskDeviceRegistration(
            platform: .ios, appVersion: configuration.appVersion, key: deviceKey, push: push))
        guard registered != wanted else { return }
        let ack = try await client.register(deviceID: deviceID, wanted.registration)
        guard ack.deviceID == deviceID, ack.keyID == key.keyID else { throw CloudTaskClientError.malformedResponse }
        registered = wanted
        // §2: the cloud has now rejected every task sealed to an older key, so
        // no pending task names one any more (§3).
        for old in try keyStore.keys() where old.keyID != key.keyID {
            try keyStore.delete(id: old.keyID)
        }
    }

    /// §7, in order. `nil` means no ack: the lease expires and the task comes back.
    private func decide(_ task: CloudTaskPulled, deviceID: String, nowMs: Int64) async throws -> CloudTaskAck? {
        func ack(_ state: CloudTaskAck.State) -> CloudTaskAck { CloudTaskAck(taskID: task.taskID, state: state) }
        guard task.expiresAtMs - nowMs >= CloudTasks.minRemainingMs else { return ack(.expired) }
        // A store that cannot be read (locked before first unlock) ends the pass without an ack.
        guard let key = try keyStore.key(id: task.keyID) else { return ack(.rejected(.keyUnknown)) }
        let aad = CloudTasks.aad(deviceID: deviceID, keyID: task.keyID, requestID: task.requestID,
                                 target: task.target, expiresAtMs: task.expiresAtMs)
        guard let text = try? CloudTaskSealing.open(task.sealed, privateScalar: key.privateScalar, aad: aad) else {
            return ack(.rejected(.decryptFailed))
        }
        guard await host.targetExists(task.target) else { return ack(.rejected(.targetMissing)) }
        let result = await host.admit(CloudTaskAdmissionRequest(
            deviceID: deviceID, taskID: task.taskID, target: task.target, text: text, expiresAtMs: task.expiresAtMs))
        switch result {
        case .admitted(let admissionID), .duplicate(let admissionID):
            // Without a well-formed receipt there is nothing to acknowledge.
            return CloudTaskJSON.isLowerHex(admissionID, 64...64) ? ack(.admitted(admissionID: admissionID)) : nil
        case .invalid: return ack(.rejected(.invalid))
        case .conflict: return ack(.rejected(.conflict))
        case .capacity, .storage: return nil
        }
    }

    /// Terminal acks from the journal's records, re-sent on every pass until the cloud settles them.
    private func sendTerminalAcks(deviceID: String, report: inout CloudTaskPassReport) async throws {
        var pending: [(report: CloudTaskTerminalReport, state: CloudTaskAck.State)] = []
        for item in await host.terminalReports(deviceID) where !settledTerminal.contains(item.taskID) {
            // `taskID` is the record's `sourceRequestId`, which the cloud chose; anything else is not ours.
            guard CloudTaskJSON.isID(item.taskID) else { continue }
            pending.append((item, item.ackState))
        }
        var start = 0
        while start < pending.count {
            let chunk = Array(pending[start..<min(start + CloudTasks.batchMax, pending.count)])
            start += chunk.count
            let response = try await client.acknowledge(CloudTaskAckBatch(
                deviceID: deviceID, acks: chunk.map { CloudTaskAck(taskID: $0.report.taskID, state: $0.state) }))
            // The cloud never saw `admitted` (that ack was lost): repeat it, then the terminal state.
            var followUp: [CloudTaskAck] = []
            for (item, result) in zip(chunk, response.results) {
                if result.accepted || result.state != "pending" {
                    await settle(item.report.taskID, report: &report)
                } else if CloudTaskJSON.isLowerHex(item.report.admissionID, 64...64) {
                    followUp.append(CloudTaskAck(taskID: item.report.taskID,
                                                 state: .admitted(admissionID: item.report.admissionID)))
                    followUp.append(CloudTaskAck(taskID: item.report.taskID, state: item.state))
                }
            }
            var next = 0
            while next < followUp.count {
                let pairs = Array(followUp[next..<min(next + CloudTasks.batchMax, followUp.count)])
                next += pairs.count
                let again = try await client.acknowledge(CloudTaskAckBatch(deviceID: deviceID, acks: pairs))
                for (ack, result) in zip(pairs, again.results) where ack.state.isTerminalReport {
                    if result.accepted || result.state != "pending" { await settle(ack.taskID, report: &report) }
                }
            }
        }
    }

    private func settle(_ taskID: String, report: inout CloudTaskPassReport) async {
        settledTerminal.insert(taskID)
        report.terminalSettled += 1
        await host.terminalSettled(taskID)
    }

    /// `DELETE` device. `.disabled` means the cloud confirmed and the keys are gone.
    private func deleteRegistration() async -> CloudTaskStatus {
        guard tokens.hasSession else { return .signedOut }
        // Never create an identity just to delete it.
        guard let deviceID = preferences.existingDeviceID() else { return .disabled }
        do {
            try await client.unregister(deviceID: deviceID)
        } catch let error as CloudTaskClientError {
            return status(for: error)
        } catch {
            return .storeUnavailable
        }
        registered = nil
        // Every pending task of the device is now `cancelled`: no task names these keys.
        if let keys = try? keyStore.keys() {
            for key in keys { try? keyStore.delete(id: key.keyID) }
        }
        return .disabled
    }
}
