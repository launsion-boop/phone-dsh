// SPDX-License-Identifier: MIT

import Foundation

/// The uniform source protocol C integrates against.
///
/// An adapter returns raw observations without an owner; the registry stamps the
/// host-resolved Bot owner and the current permission revision before any Bot
/// can read it. `authorization()` is the Apple-framework status (or `authorized`
/// for sources with no OS read permission); the App-level opt-in lives in the
/// consent ledger, not in the adapter.
public protocol BotContextSource: Sendable {
    var kind: BotContextSourceKind { get }
    func authorization() async -> BotSourceAuthorization
    func observations(since: Int64?) async throws -> [BotContextObservation]
    func stop() async
}

/// A source that can push OS callbacks. The revision is passed at start so the
/// adapter can tag its callbacks; the registry additionally drops callbacks from
/// a previous revision, which is the actual security boundary.
public protocol BotContextSourceStreaming: BotContextSource {
    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws
}

/// A source that can present the OS permission prompt. Sources without an OS
/// read permission simply do not conform.
public protocol BotContextSourceRequesting: BotContextSource {
    func requestAuthorization() async -> BotSourceAuthorization
}

/// Optional diagnostic word for the OS status (`fullAccess`, `limited`, ...).
public protocol BotContextSourceDiagnosing: BotContextSource {
    func authorizationDiagnostic() async -> String?
}

/// Contacts uses an explicit query instead of a continuous data stream. It is a
/// separate protocol so the general source protocol stays read-only and no
/// caller can enumerate the address book by accident.
public protocol BotContextContactsQuerying: Sendable {
    func contactsObservation(query: String, limit: Int) async throws -> BotContextObservation
}

/// The registry surface C composes into the production runtime.
public protocol BotContextSourceRegistrying: Sendable {
    func registeredSources() async -> [BotContextSourceKind]
    func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState?
    func requestConsent(source: BotContextSourceKind, botID: String) async throws -> BotSourceAuthorizationState
    func subscribe(botID: String, sources: [BotContextSourceKind]) async throws
    func revoke(source: BotContextSourceKind, by actor: BotSourceAuthorizationActor, reason: String) async
    func observations(for botID: String, since: Int64?,
                      sources: [BotContextSourceKind]) async throws -> [BotContextObservation]
    func recheck(botID: String, sources: [BotContextSourceKind]) async -> [BotContextRecheck]
    func stopAll() async
    func setWakeHandler(_ handler: (@Sendable (BotContextWake) -> Void)?) async
}

/// The single registration, authorization, revocation and read-gate authority.
///
/// - Every read goes through the ledger's current consent + revision.
/// - Revocation stops the adapter and clears its buffer before returning, so a
///   late OS callback cannot be buffered; even if it is, the revision check in
///   `receive` drops it.
/// - The wake handler is called only after the same checks; N never decides
///   whether the Bot should speak.
public actor BotContextSourceRegistry: BotContextSourceRegistrying {
    public static let maximumBufferedObservations = 200
    public static let maximumReadBatch = 50
    public static let maximumDeliveredIDs = 1_000
    public static let maximumWakeKeys = 1_000

    private struct Registered {
        var source: any BotContextSource
        var streaming: (any BotContextSourceStreaming)?
        var requesting: (any BotContextSourceRequesting)?
        var provenance: BotContextObservationDelivery
        var buffer: [BotContextObservation] = []
        var activeRevision: Int?
        var started = false
    }

    private let ledger: BotContextConsentLedger
    private let audit: any BotContextAuditRecording
    private let observationRecorder: (any BotContextObservationRecording)?
    private let consentRecorder: (any BotContextConsentRecording)?
    private let now: @Sendable () -> Int64
    private var registered: [BotContextSourceKind: Registered] = [:]
    private var wakeHandler: (@Sendable (BotContextWake) -> Void)?
    private var wakeKeys: [String] = []
    private var wakeKeySet: Set<String> = []
    private var cursors: [String: [BotContextSourceKind: Int64]] = [:]
    private var deliveredIDs: [String: [String]] = [:]
    private var deliveredIDSet: [String: Set<String>] = [:]
    private var recordRefs: [String: [String: String]] = [:]
    private var retired: [BotContextSourceKind: [(BotContextObservation, BotContextObservationViewItem.InactiveReason)]] = [:]

    public init(ledger: BotContextConsentLedger,
                audit: any BotContextAuditRecording = BotContextAuditLog(),
                observationRecorder: (any BotContextObservationRecording)? = nil,
                consentRecorder: (any BotContextConsentRecording)? = nil,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }) {
        self.ledger = ledger
        self.audit = audit
        self.observationRecorder = observationRecorder
        self.consentRecorder = consentRecorder
        self.now = now
    }

    // MARK: - Registration

    /// Registers one adapter. `provenance` is `.injected` only for a simulator /
    /// debug driver; a production adapter must be `.os`.
    public func register(_ source: any BotContextSource,
                         provenance: BotContextObservationDelivery = .os) async throws {
        guard registered[source.kind] == nil else {
            throw BotContextSourceError.invalidRequest("source \(source.kind.rawValue) is already registered")
        }
        registerUnchecked(source, provenance: provenance)
    }

    /// Replaces an adapter only after stopping the previous one. Used by the App
    /// when a debug/simulator driver replaces the real adapter.
    public func replace(_ source: any BotContextSource,
                        provenance: BotContextObservationDelivery = .os) async throws {
        if let previous = registered[source.kind] {
            await stopAdapter(previous)
        }
        registered.removeValue(forKey: source.kind)
        registerUnchecked(source, provenance: provenance)
    }

    private func registerUnchecked(_ source: any BotContextSource,
                                   provenance: BotContextObservationDelivery) {
        registered[source.kind] = Registered(
            source: source,
            streaming: source as? any BotContextSourceStreaming,
            requesting: source as? any BotContextSourceRequesting,
            provenance: provenance)
    }

    public func registeredSources() -> [BotContextSourceKind] {
        BotContextSourceKind.allCases.filter { registered[$0] != nil }
    }

    public func setWakeHandler(_ handler: (@Sendable (BotContextWake) -> Void)?) {
        wakeHandler = handler
    }

    private func recordConsentEvent(_ event: BotContextAuditEvent) async {
        await audit.record(event)
        await consentRecorder?.record(event)
    }

    /// Read-only subscription check for entry methods that call an adapter
    /// directly (selected media, share). It never consumes buffered observations.
    public func isSubscribed(botID: String, source: BotContextSourceKind) async -> Bool {
        await ledger.isSubscribed(botID: botID, source: source)
    }

    // MARK: - Consent / subscription

    public func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
        guard registered[source] != nil else { return nil }
        return await ledger.state(for: source)
    }

    /// Requests the OS permission (when the source has one), records the user's
    /// opt-in, and subscribes `botID`. A denied OS prompt never produces a
    /// subscription. A source the user explicitly revoked can be re-enabled only
    /// by this explicit user request; an OS re-grant alone does not resurrect it.
    @discardableResult
    public func requestConsent(source: BotContextSourceKind,
                               botID: String) async throws -> BotSourceAuthorizationState {
        guard registered[source] != nil else {
            throw BotContextSourceError.notRegistered(source)
        }
        let current = await ledger.state(for: source)
        if current.authorization.allowsReading {
            try await subscribe(botID: botID, sources: [source])
            return await ledger.state(for: source)
        }

        var osStatus = await registered[source]!.source.authorization()
        if source.requiresOSPermission, osStatus == .notDetermined {
            guard let requesting = registered[source]?.requesting else {
                throw BotContextSourceError.unsupported("\(source.rawValue) has no OS permission requester")
            }
            osStatus = await requesting.requestAuthorization()
        }
        if osStatus == .denied || osStatus == .restricted {
            _ = try await ledger.noteOSStatus(source: source, status: osStatus)
            let state = await ledger.state(for: source)
            await recordConsentEvent(BotContextAuditEvent(
                kind: .consentChanged, source: source, ownerBotID: botID,
                at: now(), permissionRevision: state.permissionRevision,
                detail: "os-\(osStatus.rawValue)", previous: current.authorization,
                current: state.authorization, by: .os, osState: osStatus))
            throw BotContextSourceError.notAuthorized(
                source, permissionRevision: state.permissionRevision)
        }
        guard osStatus.allowsReading || !source.requiresOSPermission else {
            throw BotContextSourceError.notAuthorized(
                source, permissionRevision: await ledger.state(for: source).permissionRevision)
        }
        let updated = try await ledger.grant(
            source: source, by: .user,
            authorization: osStatus == .limited ? .limited : .authorized,
            detail: "user-requested")
        await recordConsentEvent(BotContextAuditEvent(
            kind: .consentChanged, source: source, ownerBotID: botID,
            at: now(), permissionRevision: updated.permissionRevision,
            detail: "user-grant", previous: current.authorization,
            current: updated.authorization, by: .user, osState: osStatus))
        try await subscribe(botID: botID, sources: [source])
        return await ledger.state(for: source)
    }

    public func subscribe(botID: String, sources: [BotContextSourceKind]) async throws {
        let unique = Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        guard !unique.isEmpty else { return }
        var startedKinds: [BotContextSourceKind] = []
        var subscribedKinds: [BotContextSourceKind] = []
        do {
            for source in unique {
                guard registered[source] != nil else {
                    throw BotContextSourceError.notRegistered(source)
                }
                let state = await ledger.state(for: source)
                guard state.authorization.allowsReading else {
                    throw BotContextSourceError.notAuthorized(
                        source, permissionRevision: state.permissionRevision)
                }
                let wasSubscribed = await ledger.isSubscribed(botID: botID, source: source)
                // Record the subscription before starting the adapter: a
                // pull/snapshot observation emitted during start() must not be
                // filtered out by the subscription timestamp.
                try await ledger.subscribe(botID: botID, source: source)
                if !wasSubscribed { subscribedKinds.append(source) }
                if registered[source]?.started != true {
                    try await startAdapter(source, revision: state.permissionRevision)
                    startedKinds.append(source)
                }
            }
        } catch {
            for source in subscribedKinds.reversed() {
                try? await ledger.unsubscribe(botID: botID, source: source)
            }
            for source in startedKinds.reversed() {
                let remaining = await ledger.subscribedBots(for: source)
                if remaining.isEmpty {
                    await stopAdapter(source)
                }
            }
            throw error
        }
    }

    public func unsubscribe(botID: String, source: BotContextSourceKind) async {
        try? await ledger.unsubscribe(botID: botID, source: source)
        let remaining = await ledger.subscribedBots(for: source)
        if remaining.isEmpty {
            await stopAdapter(source)
        }
    }

    /// Removes only this Bot's subscription. The OS adapter is stopped only
    /// when no Bot remains subscribed; another Bot's observations stay live.
    /// This is not a global revoke: consent, generation and other Bots remain.
    public func unsubscribe(botID: String, sources: [BotContextSourceKind]) async throws {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BotContextSourceError.invalidRequest("botID must be non-empty")
        }
        for source in Set(sources).sorted(by: { $0.rawValue < $1.rawValue }) {
            let wasSubscribed = await ledger.isSubscribed(botID: trimmed, source: source)
            guard wasSubscribed else { continue }
            try await ledger.unsubscribe(botID: trimmed, source: source)
            if await ledger.subscribedBots(for: source).isEmpty {
                await stopAdapter(source)
                clearDeliveryState(for: source)
            }
        }
    }

    public func revoke(source: BotContextSourceKind,
                       by actor: BotSourceAuthorizationActor = .user,
                       reason: String) async {
        let previous = await ledger.state(for: source).authorization
        do {
            let updated = try await ledger.revoke(source: source, by: actor, reason: reason)
            retire(source, reason: .revoked)
            await stopAdapter(source)
            clearDeliveryState(for: source)
            await recordConsentEvent(BotContextAuditEvent(
                kind: .consentChanged, source: source,
                at: now(), permissionRevision: updated.permissionRevision,
                detail: reason, previous: previous, current: updated.authorization,
                by: actor, osState: updated.osAuthorization))
        } catch {
            await audit.record(BotContextAuditEvent(
                kind: .sourceFailed, source: source, at: now(),
                permissionRevision: await ledger.state(for: source).permissionRevision,
                detail: "revoke-failed:\(String(describing: error))",
                previous: previous))
        }
    }

    /// Mirrors an OS Settings change. Denial/restriction revokes and stops the
    /// adapter; an OS grant never silently opts the user in.
    public func noteOSAuthorizationChange(source: BotContextSourceKind,
                                          status: BotSourceAuthorization) async {
        do {
            let before = await ledger.state(for: source).authorization
            let updated = try await ledger.noteOSStatus(source: source, status: status)
            if before.allowsReading && !updated.authorization.allowsReading {
                retire(source, reason: .revoked)
                await stopAdapter(source)
                clearDeliveryState(for: source)
            }
            if before != updated.authorization {
                await recordConsentEvent(BotContextAuditEvent(
                    kind: .consentChanged, source: source, at: now(),
                    permissionRevision: updated.permissionRevision,
                    detail: "os-\(status.rawValue)", previous: before,
                    current: updated.authorization, by: .os, osState: status))
            }
        } catch {
            await audit.record(BotContextAuditEvent(
                kind: .sourceFailed, source: source, at: now(),
                permissionRevision: 0, detail: "os-sync-failed:\(String(describing: error))"))
        }
    }

    // MARK: - Read

    public func observations(for botID: String,
                             since: Int64? = nil,
                             sources: [BotContextSourceKind] = []) async throws -> [BotContextObservation] {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BotContextSourceError.invalidRequest("botID is required")
        }
        let requested = sources.isEmpty
            ? await ledger.subscriptions(for: trimmed)
            : Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        guard !requested.isEmpty else { return [] }

        var result: [BotContextObservation] = []
        for source in requested {
            guard registered[source] != nil else {
                throw BotContextSourceError.notRegistered(source)
            }
            let state = await ledger.state(for: source)
            guard state.authorization.allowsReading else {
                if state.authorization == .revoked {
                    throw BotContextSourceError.revoked(source)
                }
                throw BotContextSourceError.notAuthorized(
                    source, permissionRevision: state.permissionRevision)
            }
            guard await ledger.isSubscribed(botID: trimmed, source: source) else {
                throw BotContextSourceError.notAuthorized(
                    source, permissionRevision: state.permissionRevision)
            }
            let subscribedAt = await ledger.subscriptionStart(botID: trimmed, source: source) ?? 0
            let explicit = max(0, since ?? 0)
            let cursor = max(explicit, cursors[trimmed]?[source] ?? 0, subscribedAt)
            let buffer = registered[source]?.buffer ?? []
            var nextCursor = cursor
            for observation in buffer
                .filter({ $0.observedAt >= cursor && $0.permissionRevision == state.permissionRevision })
                .sorted(by: { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }) {
                if deliveredIDSet[trimmed]?.contains(observation.id) == true { continue }
                guard observation.permissionRevision == state.permissionRevision else { continue }
                guard let bound = try? observation.bound(to: trimmed) else { continue }
                result.append(bound)
                markDelivered(botID: trimmed, observationID: observation.id)
                nextCursor = max(nextCursor, observation.observedAt)
                if result.count >= Self.maximumReadBatch { break }
            }
            cursors[trimmed, default: [:]][source] = nextCursor
            if result.count >= Self.maximumReadBatch { break }
        }
        return result.sorted { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }
    }

    /// Explicit contacts lookup through the same consent/revision gate. The
    /// query is user/model-initiated; there is no address-book enumeration.
    public func readContacts(botID: String, query: String,
                             limit: Int = 20) async throws -> BotContextObservation {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !query.isEmpty else {
            throw BotContextSourceError.invalidRequest("contacts query requires botID and a non-empty query")
        }
        guard let entry = registered[.contacts],
              let querying = entry.source as? any BotContextContactsQuerying else {
            throw BotContextSourceError.unsupported("contacts query is not registered")
        }
        let state = await ledger.state(for: .contacts)
        guard state.authorization.allowsReading else {
            throw BotContextSourceError.notAuthorized(
                .contacts, permissionRevision: state.permissionRevision)
        }
        guard await ledger.isSubscribed(botID: trimmed, source: .contacts) else {
            throw BotContextSourceError.notAuthorized(
                .contacts, permissionRevision: state.permissionRevision)
        }
        let observation = try await querying.contactsObservation(
            query: query, limit: min(max(1, limit), 20))
        guard observation.permissionRevision == state.permissionRevision,
              observation.source == .contacts else {
            throw BotContextSourceError.staleCallback
        }
        let bound = try observation.bound(to: trimmed)
        await audit.record(BotContextAuditEvent(
            kind: .observationAccepted, source: .contacts, ownerBotID: trimmed,
            at: now(), permissionRevision: state.permissionRevision,
            detail: "contacts-query", uncertainty: bound.uncertainty,
            observationID: bound.id))
        return bound
    }

    // MARK: - Lifecycle

    public func stopAll() async {
        for kind in registered.keys {
            await stopAdapter(kind)
        }
    }

    /// Called by an adapter (or its delegate bridge) for one OS event.
    private func receive(_ raw: BotContextObservation,
                         from kind: BotContextSourceKind,
                         revision: Int) async {
        guard let entry = registered[kind], entry.started else { return }
        let state = await ledger.state(for: kind)
        guard state.authorization.allowsReading,
              state.permissionRevision == revision,
              raw.source == kind,
              raw.permissionRevision == revision else {
            await audit.record(BotContextAuditEvent(
                kind: .observationRejected, source: kind, at: now(),
                permissionRevision: revision, detail: "stale-or-unauthorized-callback",
                current: state.authorization, observationID: raw.id))
            return
        }
        if entry.provenance == .injected {
            guard raw.delivery == .injected else {
                await audit.record(BotContextAuditEvent(
                    kind: .observationRejected, source: kind, at: now(),
                    permissionRevision: revision, detail: "injected-source-claimed-os",
                    current: state.authorization, observationID: raw.id))
                return
            }
        } else {
            guard raw.delivery == .os else {
                await audit.record(BotContextAuditEvent(
                    kind: .observationRejected, source: kind, at: now(),
                    permissionRevision: revision, detail: "real-source-claimed-injected",
                    current: state.authorization, observationID: raw.id))
                return
            }
            if BotContextSecretScanner.readsSecret(raw.payload) {
                await audit.record(BotContextAuditEvent(
                    kind: .observationRejected, source: kind, at: now(),
                    permissionRevision: revision, detail: "credential-shape",
                    current: state.authorization, observationID: raw.id))
                return
            }
        }
        // Re-check after any await: a revocation may have raced this callback.
        let confirmed = await ledger.state(for: kind)
        guard confirmed.authorization.allowsReading,
              confirmed.permissionRevision == revision else {
            await audit.record(BotContextAuditEvent(
                kind: .observationRejected, source: kind, at: now(),
                permissionRevision: revision, detail: "revoked-during-callback",
                current: confirmed.authorization, observationID: raw.id))
            return
        }
        guard registered[kind]?.started == true else { return }
        var mutable = entry
        guard !mutable.buffer.contains(where: { $0.id == raw.id }) else { return }
        mutable.buffer.append(raw)
        if mutable.buffer.count > Self.maximumBufferedObservations {
            mutable.buffer.removeFirst(mutable.buffer.count - Self.maximumBufferedObservations)
        }
        registered[kind] = mutable
        let subscribers = await ledger.subscribedBots(for: kind)
        if subscribers.isEmpty {
            await audit.record(BotContextAuditEvent(
                kind: .observationAccepted, source: kind, at: now(),
                permissionRevision: revision, detail: raw.kind.rawValue,
                uncertainty: raw.uncertainty, observationID: raw.id))
            return
        }
        for botID in subscribers {
            guard await ledger.isSubscribed(botID: botID, source: kind) else { continue }
            await audit.record(BotContextAuditEvent(
                kind: .observationAccepted, source: kind, ownerBotID: botID, at: now(),
                permissionRevision: revision, detail: raw.kind.rawValue,
                uncertainty: raw.uncertainty, observationID: raw.id))
            if let recorded = await observationRecorder?.record(raw, ownerBotID: botID) {
                recordRefs[botID, default: [:]][raw.id] = recorded.recordRef
                if recordRefs[botID]!.count > Self.maximumDeliveredIDs {
                    // The record-ref map is bounded the same way as the
                    // delivered-id map; dropping an old ref only affects an
                    // observation that is no longer in the buffer.
                    recordRefs[botID] = [:]
                }
            }
            guard raw.wakeRequested else { continue }
            guard let bound = try? raw.bound(to: botID) else { continue }
            try? await emitWake(bound, botID: botID, revision: revision)
        }
    }

    private func emitWake(_ observation: BotContextObservation,
                          botID: String,
                          revision: Int) async throws {
        let key = botID + "\u{0}" + observation.source.rawValue + "\u{0}" + observation.kind.rawValue
            + "\u{0}" + observation.dedupeKey
        if wakeKeySet.contains(key) {
            await audit.record(BotContextAuditEvent(
                kind: .wakeSuppressed, source: observation.source, ownerBotID: botID,
                at: now(), permissionRevision: revision, detail: "duplicate",
                observationID: observation.id))
            return
        }
        guard let wake = try? BotContextWake(
            botID: botID, source: observation.source, kind: observation.kind,
            observationID: observation.id, observedAt: observation.observedAt,
            permissionRevision: revision, dedupeKey: observation.dedupeKey) else { return }
        wakeKeySet.insert(key)
        wakeKeys.append(key)
        if wakeKeys.count > Self.maximumWakeKeys {
            let overflow = wakeKeys.count - Self.maximumWakeKeys
            let removed = wakeKeys.prefix(overflow)
            wakeKeys.removeFirst(overflow)
            for key in removed { wakeKeySet.remove(key) }
        }
        wakeHandler?(wake)
        await audit.record(BotContextAuditEvent(
            kind: .wakeEmitted, source: observation.source, ownerBotID: botID,
            at: now(), permissionRevision: revision, detail: wake.reason,
            uncertainty: observation.uncertainty, observationID: observation.id))
    }

    // MARK: - Real G-1 r5 recheck

    /// Re-queries each requested source through its real adapter at the current
    /// consent generation and compares the returned revision with the latest
    /// observation. A revoked/unauthorized/unsubscribed source is answered from
    /// the ledger without touching the adapter (`refresh-denied`, zero OS read).
    /// A source without a queryable producer is `refresh-not-performed`, never
    /// `current`.
    public func recheck(botID: String,
                        sources: [BotContextSourceKind] = []) async -> [BotContextRecheck] {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let snapshot = await ledger.snapshot()
        let requested = sources.isEmpty
            ? snapshot.subscriptions[trimmed].map { Array($0).sorted { $0.rawValue < $1.rawValue } } ?? []
            : Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        var results: [BotContextRecheck] = []
        for source in requested {
            guard let state = snapshot.states[source] else { continue }
            let latest = (registered[source]?.buffer ?? [])
                .filter { $0.permissionRevision == state.permissionRevision }
                .max { ($0.observedAt, $0.id) < ($1.observedAt, $1.id) }
            let baseline = latest?.sourceVersion
            let observedAt = latest?.observedAt
            let latestRef = latest.flatMap { recordRefs[trimmed]?[$0.id] }
            let stamp = now()
            if state.authorization == .revoked {
                results.append(BotContextRecheck(
                    source: source, state: .revoked,
                    reasons: [.grantRevoked, .refreshDenied],
                    baseline: baseline, observedAtMS: observedAt,
                    recheckedAtMS: stamp, latestRef: latestRef))
                continue
            }
            guard state.authorization.allowsReading,
                  snapshot.subscriptions[trimmed]?.contains(source) == true,
                  snapshot.subscriptionRevisions[trimmed]?[source] == state.permissionRevision
            else {
                results.append(BotContextRecheck(
                    source: source, state: .unknown, reasons: [.refreshDenied],
                    baseline: baseline, observedAtMS: observedAt,
                    recheckedAtMS: stamp, latestRef: latestRef))
                continue
            }
            guard let rechecker = registered[source]?.source as? any BotContextSourceRechecking else {
                results.append(BotContextRecheck(
                    source: source, state: .unknown, reasons: [.refreshNotPerformed],
                    baseline: baseline, observedAtMS: observedAt,
                    recheckedAtMS: stamp, latestRef: latestRef))
                continue
            }
            let probe = await rechecker.recheck(
                permissionRevision: state.permissionRevision,
                baseline: baseline, latestKind: latest?.kind)
            // A revoke racing the query still yields denied and no result is
            // reported as current.
            let after = await ledger.state(for: source)
            if after.authorization == .revoked || after.authorization == .denied {
                results.append(BotContextRecheck(
                    source: source, state: .revoked, reasons: [.grantRevoked, .refreshDenied],
                    baseline: baseline, observedAtMS: observedAt,
                    recheckedAtMS: stamp, latestRef: latestRef))
                continue
            }
            results.append(BotContextRecheckEvaluator.evaluate(
                source: source, probe: probe, baseline: baseline,
                observedAtMS: observedAt, latestRef: latestRef,
                recheckedAtMS: stamp))
        }
        return results.sorted { $0.source.rawValue < $1.source.rawValue }
    }

    // MARK: - Read view

    /// Frozen `context-observation-view` shape. Active items carry only a
    /// `record_ref`; payload/body is never copied into the view. Retired items
    /// from a revoked/stale generation are `inactive` with a reason.
    public func observationView(for botID: String,
                                since: Int64? = nil,
                                sources: [BotContextSourceKind] = []) async -> BotContextObservationView {
        let trimmed = botID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return BotContextObservationView(botID: botID, consentGeneration: 0, items: [])
        }
        let snapshot = await ledger.snapshot()
        let requested = sources.isEmpty
            ? snapshot.subscriptions[trimmed].map { Array($0).sorted { $0.rawValue < $1.rawValue } } ?? []
            : Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
        let floor = max(0, since ?? 0)
        var items: [BotContextObservationViewItem] = []
        var generations: [Int] = []
        for source in requested {
            guard let state = snapshot.states[source] else { continue }
            generations.append(state.permissionRevision)
            let subscribed = snapshot.subscriptions[trimmed]?.contains(source) == true
                && state.authorization.allowsReading
                && snapshot.subscriptionRevisions[trimmed]?[source] == state.permissionRevision
            if state.authorization.allowsReading, subscribed {
                for observation in (registered[source]?.buffer ?? [])
                    where observation.observedAt >= floor
                        && observation.permissionRevision == state.permissionRevision {
                    items.append(BotContextObservationViewItem(
                        source: observation.source,
                        kind: observation.kind.rawValue,
                        observedAtMS: observation.observedAt,
                        sourceVersion: observation.sourceVersion,
                        uncertainty: observation.uncertainty,
                        recordRef: recordRefs[trimmed]?[observation.id],
                        state: .active,
                        consentGeneration: observation.permissionRevision))
                }
            }
            for (observation, retiredReason) in retired[source] ?? [] where observation.observedAt >= floor {
                let reason: BotContextObservationViewItem.InactiveReason =
                    state.authorization == .revoked ? .revoked
                    : observation.permissionRevision != state.permissionRevision ? .generationMismatch
                    : retiredReason
                items.append(BotContextObservationViewItem(
                    source: observation.source,
                    kind: observation.kind.rawValue,
                    observedAtMS: observation.observedAt,
                    sourceVersion: observation.sourceVersion,
                    uncertainty: observation.uncertainty,
                    recordRef: recordRefs[trimmed]?[observation.id],
                    state: .inactive,
                    inactiveReason: reason,
                    consentGeneration: observation.permissionRevision))
            }
        }
        return BotContextObservationView(
            botID: trimmed,
            consentGeneration: generations.max() ?? 0,
            items: items.sorted {
                ($0.observedAtMS, $0.kind, $0.source.rawValue)
                    < ($1.observedAtMS, $1.kind, $1.source.rawValue)
            })
    }

    private func retire(_ source: BotContextSourceKind,
                        reason: BotContextObservationViewItem.InactiveReason) {
        guard let entry = registered[source], !entry.buffer.isEmpty else { return }
        var existing = retired[source] ?? []
        existing.append(contentsOf: entry.buffer.map { ($0, reason) })
        if existing.count > Self.maximumBufferedObservations * 2 {
            existing.removeFirst(existing.count - Self.maximumBufferedObservations * 2)
        }
        retired[source] = existing
    }

    // MARK: - Adapter lifecycle

    private func startAdapter(_ source: BotContextSourceKind, revision: Int) async throws {
        guard var entry = registered[source] else {
            throw BotContextSourceError.notRegistered(source)
        }
        if entry.started, entry.activeRevision == revision { return }
        if entry.started {
            await stopAdapter(entry)
            guard let refreshed = registered[source] else {
                throw BotContextSourceError.notRegistered(source)
            }
            entry = refreshed
        }
        entry.started = true
        entry.activeRevision = revision
        registered[source] = entry
        guard let streaming = entry.streaming else { return }
        do {
            try await streaming.start(permissionRevision: revision) { [weak self] observation in
                guard let self else { return }
                Task { await self.receive(observation, from: source, revision: revision) }
            }
        } catch {
            entry.started = false
            entry.activeRevision = nil
            registered[source] = entry
            await audit.record(BotContextAuditEvent(
                kind: .sourceFailed, source: source, at: now(),
                permissionRevision: revision, detail: "start-failed:\(String(describing: error))"))
            throw error
        }
    }

    private func stopAdapter(_ source: BotContextSourceKind) async {
        guard let entry = registered[source] else { return }
        await stopAdapter(entry)
    }

    private func stopAdapter(_ entry: Registered) async {
        var mutable = entry
        mutable.started = false
        mutable.activeRevision = nil
        mutable.buffer = []
        registered[entry.source.kind] = mutable
        // `BotContextSourceStreaming` refines `BotContextSource`; one stop call
        // is enough and avoids double teardown of a delegate/observer.
        await entry.source.stop()
    }

    private func clearDeliveryState(for source: BotContextSourceKind) {
        for botID in Array(cursors.keys) {
            cursors[botID]?.removeValue(forKey: source)
        }
        // Delivered ids stay monotonic across revocations on purpose: if an
        // observation id somehow reappears, it is still not re-delivered as new.
    }

    private func markDelivered(botID: String, observationID: String) {
        deliveredIDSet[botID, default: []].insert(observationID)
        deliveredIDs[botID, default: []].append(observationID)
        if deliveredIDs[botID]!.count > Self.maximumDeliveredIDs {
            let overflow = deliveredIDs[botID]!.count - Self.maximumDeliveredIDs
            let removed = deliveredIDs[botID]!.prefix(overflow)
            deliveredIDs[botID]!.removeFirst(overflow)
            for id in removed { deliveredIDSet[botID]?.remove(id) }
        }
    }
}
