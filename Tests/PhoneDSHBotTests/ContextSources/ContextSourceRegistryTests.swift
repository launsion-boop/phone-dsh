// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

/// One deterministic fake adapter. It is an actor so the tests can inspect and
/// mutate it without racing the registry; no real framework, permission prompt
/// or personal datum is touched.
actor FakeContextSource: BotContextSource, BotContextSourceStreaming,
                         BotContextSourceRequesting, BotContextContactsQuerying,
                         BotContextSourceRechecking {
    nonisolated let kind: BotContextSourceKind
    private var osStatus: BotSourceAuthorization
    private var requestResult: BotSourceAuthorization
    private var revision: Int?
    private var sink: (@Sendable (BotContextObservation) -> Void)?
    private var buffer: [BotContextObservation] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var requestCount = 0
    private(set) var observationsReadCount = 0
    private(set) var recheckCount = 0
    private var recheckProbe: BotContextRecheckProbe = .notPerformed("fake")

    init(kind: BotContextSourceKind, osStatus: BotSourceAuthorization = .authorized) {
        self.kind = kind
        self.osStatus = osStatus
        self.requestResult = osStatus
    }

    func setOSStatus(_ status: BotSourceAuthorization) { osStatus = status }
    func setRequestResult(_ status: BotSourceAuthorization) { requestResult = status }
    func setRecheckProbe(_ probe: BotContextRecheckProbe) { recheckProbe = probe }

    func recheck(permissionRevision: Int,
                 baseline: BotContextSourceVersion?,
                 latestKind: BotContextObservationKind?) async -> BotContextRecheckProbe {
        recheckCount += 1
        guard revision == permissionRevision else { return .denied("revoked-generation") }
        return recheckProbe
    }

    func authorization() async -> BotSourceAuthorization { osStatus }

    func requestAuthorization() async -> BotSourceAuthorization {
        requestCount += 1
        osStatus = requestResult
        return osStatus
    }

    func start(permissionRevision: Int,
               emit: @escaping @Sendable (BotContextObservation) -> Void) async throws {
        startCount += 1
        revision = permissionRevision
        sink = emit
    }

    func stop() async {
        stopCount += 1
        revision = nil
        sink = nil
        buffer = []
    }

    func observations(since: Int64?) async throws -> [BotContextObservation] {
        observationsReadCount += 1
        let floor = max(0, since ?? 0)
        return buffer.filter { $0.observedAt >= floor }
    }

    func emit(_ observation: BotContextObservation) {
        buffer.append(observation)
        sink?(observation)
    }

    func observation(id: String = "fake:1",
                     kind observationKind: BotContextObservationKind = .calendarChanged,
                     observedAt: Int64 = 1_000_001,
                     revision requestedRevision: Int? = nil,
                     delivery: BotContextObservationDelivery = .os,
                     payload: BotJSONValue = .object(["changed": .bool(true)]),
                     dedupeKey: String = "fake:changed",
                     wakeRequested: Bool = false,
                     sourceVersion: BotContextSourceVersion = .unversioned()) throws -> BotContextObservation {
        try BotContextObservation(
            id: id, source: kind, kind: observationKind, observedAt: observedAt,
            permissionRevision: requestedRevision ?? revision ?? 1,
            sourceVersion: sourceVersion,
            uncertainty: BotContextUncertainty(level: .medium, reason: "fake"),
            delivery: delivery, payload: payload, dedupeKey: dedupeKey,
            wakeRequested: wakeRequested)
    }

    func contactsObservation(query: String, limit: Int) async throws -> BotContextObservation {
        try BotContextObservation(
            id: "contacts:test", source: .contacts, kind: .contactsChanged,
            observedAt: 1_000_001, permissionRevision: revision ?? 1,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(level: .medium, reason: "fake"),
            delivery: .os,
            payload: .object([
                "query": .string(query),
                "items": .array([.object(["name": .string("A***")])]),
            ]),
            dedupeKey: "contacts:test", wakeRequested: false)
    }

    func counts() -> (start: Int, stop: Int, request: Int, reads: Int, rechecks: Int) {
        (startCount, stopCount, requestCount, observationsReadCount, recheckCount)
    }
}

actor WakeRecorder {
    private var wakes: [BotContextWake] = []
    func record(_ wake: BotContextWake) { wakes.append(wake) }
    func all() -> [BotContextWake] { wakes }
}

final class ContextSourceRegistryTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 1_000_000 }

    private func makeStack(provenance: BotContextObservationDelivery = .os,
                           fakes: [FakeContextSource]) async throws
        -> (BotContextSourceRegistry, BotContextConsentLedger, BotContextAuditLog) {
        let store = InMemoryBotContextSourceConsentStore()
        let ledger = BotContextConsentLedger(store: store, now: now)
        let audit = BotContextAuditLog()
        let registry = BotContextSourceRegistry(ledger: ledger, audit: audit, now: now)
        _ = await ledger.load()
        for fake in fakes {
            try await registry.register(fake, provenance: provenance)
        }
        return (registry, ledger, audit)
    }

    private func readUntil(_ registry: BotContextSourceRegistry, botID: String,
                           count expected: Int, timeout: TimeInterval = 2) async throws
        -> [BotContextObservation] {
        let deadline = Date().addingTimeInterval(timeout)
        var latest: [BotContextObservation] = []
        while Date() < deadline {
            latest = try await registry.observations(for: botID)
            if latest.count >= expected { return latest }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        return latest
    }

    func testDefaultConsentDeniesReadWithoutTouchingAdapter() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        do {
            _ = try await registry.observations(for: "bot-a", sources: [.calendar])
            XCTFail("an unconsented read must fail")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError,
                           .notAuthorized(.calendar, permissionRevision: 0))
        }
        let counts = await fake.counts()
        XCTAssertEqual(counts.reads, 0)
        XCTAssertEqual(counts.start, 0)
    }

    func testRequestConsentGrantsSubscribesStartsAndBindsObservation() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        let state = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(state.permissionRevision, 1)
        let started = await fake.counts()
        XCTAssertEqual(started.start, 1)

        let observation = try await fake.observation(
            observedAt: 1_000_001, wakeRequested: false)
        await fake.emit(observation)
        let received = try await readUntil(registry, botID: "bot-a", count: 1)
        let first = try XCTUnwrap(received.first)
        XCTAssertEqual(first.ownerBotID, "bot-a")
        XCTAssertEqual(first.source, .calendar)
        XCTAssertEqual(first.observedAt, 1_000_001)
        XCTAssertEqual(first.permissionRevision, 1)
        XCTAssertEqual(first.uncertainty, observation.uncertainty)
        XCTAssertEqual(first.delivery, .os)

        // The same observation is not delivered twice.
        let again = try await registry.observations(for: "bot-a")
        XCTAssertTrue(again.isEmpty)
    }

    func testRevokeStopsAdapterDropsLateCallbackAndBlocksRead() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, audit) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await registry.revoke(source: .calendar, by: .user, reason: "user-revoked")
        let stopped = await fake.counts()
        XCTAssertEqual(stopped.stop, 1)
        let authorization = await registry.authorization(for: .calendar)
        let state = try XCTUnwrap(authorization)
        XCTAssertEqual(state.authorization, .revoked)
        XCTAssertEqual(state.permissionRevision, 2)

        // A late callback from the previous revision is dropped.
        let late = try await fake.observation(observedAt: 1_000_002, revision: 1)
        await fake.emit(late)
        try await Task.sleep(nanoseconds: 80_000_000)
        do {
            _ = try await registry.observations(for: "bot-a", sources: [.calendar])
            XCTFail("a revoked source must not be readable")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.calendar))
        }

        let events = await audit.snapshot()
        let consent = try XCTUnwrap(events.first { $0.kind == .consentChanged && $0.current == .revoked })
        XCTAssertEqual(consent.source, .calendar)
        XCTAssertEqual(consent.permissionRevision, 2)
        XCTAssertEqual(consent.previous, .authorized)
        XCTAssertEqual(consent.at, 1_000_000)
        XCTAssertEqual(consent.detail, "user-revoked")
        // The adapter was stopped synchronously, so the late callback never
        // reaches the registry at all; the absence of a read is the proof.
        XCTAssertFalse(events.contains { $0.kind == .observationAccepted && $0.observationID == late.id })
    }

    func testStaleCallbackAfterRegrantIsDroppedButCurrentRevisionIsAccepted() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await registry.revoke(source: .calendar, reason: "revoked")
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        let currentAuthorization = await registry.authorization(for: .calendar)
        let current = try XCTUnwrap(currentAuthorization)
        XCTAssertEqual(current.authorization, .authorized)
        XCTAssertEqual(current.permissionRevision, 3)

        let stale = try await fake.observation(id: "fake:stale", observedAt: 1_000_003, revision: 1)
        await fake.emit(stale)
        let fresh = try await fake.observation(id: "fake:fresh", observedAt: 1_000_004, revision: 3)
        await fake.emit(fresh)
        let received = try await readUntil(registry, botID: "bot-a", count: 1)
        XCTAssertEqual(received.map(\.id), ["fake:fresh"])
    }

    func testOSDenialRevokesAndStops() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await fake.setOSStatus(.denied)
        await registry.noteOSAuthorizationChange(source: .calendar, status: .denied)
        let authorization = await registry.authorization(for: .calendar)
        let state = try XCTUnwrap(authorization)
        XCTAssertEqual(state.authorization, .denied)
        XCTAssertEqual(state.permissionRevision, 2)
        let stopped = await fake.counts()
        XCTAssertEqual(stopped.stop, 1)
    }

    func testPerBotSubscriptionBindsOwnerAndRevokeAffectsEveryBot() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        try await registry.subscribe(botID: "bot-b", sources: [.calendar])
        let observation = try await fake.observation(observedAt: 1_000_001)
        await fake.emit(observation)
        let a = try await readUntil(registry, botID: "bot-a", count: 1)
        let b = try await readUntil(registry, botID: "bot-b", count: 1)
        XCTAssertEqual(a.first?.ownerBotID, "bot-a")
        XCTAssertEqual(b.first?.ownerBotID, "bot-b")
        do {
            _ = try await registry.observations(for: "bot-c", sources: [.calendar])
            XCTFail("bot-c never subscribed")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .notAuthorized(.calendar, permissionRevision: 1))
        }
        await registry.revoke(source: .calendar, reason: "revoked")
        for bot in ["bot-a", "bot-b"] {
            do {
                _ = try await registry.observations(for: bot, sources: [.calendar])
                XCTFail("\(bot) must be blocked after revoke")
            } catch {
                XCTAssertEqual(error as? BotContextSourceError, .revoked(.calendar))
            }
        }
    }

    func testUnsubscribeLastBotStopsAdapter() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await registry.unsubscribe(botID: "bot-a", source: .calendar)
        let stopped = await fake.counts()
        XCTAssertEqual(stopped.stop, 1)
    }

    func testStopAllDropsLateCallback() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await registry.stopAll()
        let late = try await fake.observation(observedAt: 1_000_002)
        await fake.emit(late)
        try await Task.sleep(nanoseconds: 80_000_000)
        let received = try await registry.observations(for: "bot-a")
        XCTAssertTrue(received.isEmpty)
    }

    func testInjectedProvenanceCannotClaimOS() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, audit) = try await makeStack(provenance: .injected, fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        let claimedOS = try await fake.observation(observedAt: 1_000_001, delivery: .os)
        await fake.emit(claimedOS)
        try await Task.sleep(nanoseconds: 80_000_000)
        let received = try await registry.observations(for: "bot-a")
        XCTAssertTrue(received.isEmpty)
        let events = await audit.snapshot()
        XCTAssertTrue(events.contains {
            $0.kind == .observationRejected && $0.detail == "injected-source-claimed-os"
        })
    }

    func testInjectionDriverAlwaysMarksInjected() async throws {
        let driver = BotContextInjectionDriver(kind: .locationFence, now: now)
        let store = InMemoryBotContextSourceConsentStore()
        let ledger = BotContextConsentLedger(store: store, now: now)
        let audit = BotContextAuditLog()
        let registry = BotContextSourceRegistry(ledger: ledger, audit: audit, now: now)
        _ = await ledger.load()
        try await registry.register(driver, provenance: .injected)
        _ = try await registry.requestConsent(source: .locationFence, botID: "bot-a")
        _ = try await driver.inject(
            kind: .locationEntered,
            payload: .object(["regionId": .string("office")]))
        let received = try await readUntil(registry, botID: "bot-a", count: 1)
        XCTAssertEqual(received.first?.delivery, .injected)
        XCTAssertFalse(received.first!.delivery.isReal)
    }

    func testCredentialPayloadIsRejectedByRegistryRecheck() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, audit) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        var observation = try await fake.observation(observedAt: 1_000_001)
        observation.payload = .object(["api_key": .string("sk-abcdefghijklmnopqrstuvwxyz")])
        await fake.emit(observation)
        try await Task.sleep(nanoseconds: 80_000_000)
        let received = try await registry.observations(for: "bot-a")
        XCTAssertTrue(received.isEmpty)
        let events = await audit.snapshot()
        XCTAssertTrue(events.contains { $0.kind == .observationRejected && $0.detail == "credential-shape" })
    }

    func testWakeRelayReceivesTypedReasonOnceAndStopsAfterRevoke() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        let recorder = WakeRecorder()
        await registry.setWakeHandler { wake in
            Task { await recorder.record(wake) }
        }
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        let first = try await fake.observation(
            id: "fake:wake-1", observedAt: 1_000_001, dedupeKey: "same", wakeRequested: true)
        let duplicate = try await fake.observation(
            id: "fake:wake-2", observedAt: 1_000_002, dedupeKey: "same", wakeRequested: true)
        await fake.emit(first)
        await fake.emit(duplicate)
        for _ in 0..<50 {
            if await recorder.all().count >= 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let wakes = await recorder.all()
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(wakes.first?.reason, "context:calendar:calendar.changed")
        XCTAssertEqual(wakes.first?.botID, "bot-a")
        XCTAssertEqual(wakes.first?.permissionRevision, 1)

        await registry.revoke(source: .calendar, reason: "revoked")
        let after = try await fake.observation(
            id: "fake:wake-3", observedAt: 1_000_003, dedupeKey: "other", wakeRequested: true)
        await fake.emit(after)
        try await Task.sleep(nanoseconds: 80_000_000)
        let finalWakes = await recorder.all()
        XCTAssertEqual(finalWakes.count, 1)
    }

    func testContactsQueryRequiresConsentAndSubscription() async throws {
        let fake = FakeContextSource(kind: .contacts, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        do {
            _ = try await registry.readContacts(botID: "bot-a", query: "Ada")
            XCTFail("unconsented contacts query must fail")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError,
                           .notAuthorized(.contacts, permissionRevision: 0))
        }
        _ = try await registry.requestConsent(source: .contacts, botID: "bot-a")
        let observation = try await registry.readContacts(botID: "bot-a", query: "Ada")
        XCTAssertEqual(observation.ownerBotID, "bot-a")
        XCTAssertEqual(observation.source, .contacts)
        XCTAssertEqual(observation.kind, .contactsChanged)
    }

    func testSourceVersionUnknownReasonIsPreservedInReadView() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _, _) = try await makeStack(fakes: [fake])
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await fake.emit(try await fake.observation(observedAt: 1_000_001))
        let received = try await readUntil(registry, botID: "bot-a", count: 1)
        XCTAssertEqual(received.first?.sourceVersion,
                       .unversioned())
    }
}

final class ContextSourceRecheckTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 2_000_000 }
    private let digest = "sha256:" + String(repeating: "a", count: 64)

    private func makeRegistry(_ fake: FakeContextSource) async throws
        -> (BotContextSourceRegistry, BotContextConsentLedger) {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(fake)
        _ = try await registry.requestConsent(source: fake.kind, botID: "bot-a")
        return (registry, ledger)
    }

    func testRecheckStateMachineUsesBaselineAndProviderProbe() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _) = try await makeRegistry(fake)
        let version = BotContextSourceVersion.known(.contentSHA256, value: digest)
        await fake.emit(try await fake.observation(
            observedAt: 2_000_001, sourceVersion: version))
        _ = try await registry.observations(for: "bot-a")
        try await Task.sleep(nanoseconds: 50_000_000)

        await fake.setRecheckProbe(.version(version))
        let currentResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let current = try XCTUnwrap(currentResult.first)
        XCTAssertEqual(current.state, .current)
        XCTAssertTrue(current.reasons.isEmpty)
        XCTAssertEqual(current.sourceVersion, version)
        XCTAssertEqual(current.baseline, version)
        XCTAssertNotNil(current.recheckedAtMS)

        let changedVersion = BotContextSourceVersion.known(
            .contentSHA256, value: "sha256:" + String(repeating: "b", count: 64))
        await fake.setRecheckProbe(.version(changedVersion))
        let changedResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let changed = try XCTUnwrap(changedResult.first)
        XCTAssertEqual(changed.state, .changed)
        XCTAssertEqual(changed.reasons, [.sourceChanged])

        await fake.setRecheckProbe(.version(.known(.providerVersion, value: "rev:7")))
        let mismatchResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let mismatch = try XCTUnwrap(mismatchResult.first)
        XCTAssertEqual(mismatch.state, .unknown)
        XCTAssertEqual(mismatch.reasons, [.revisionBasisMismatch])

        await fake.setRecheckProbe(.denied("user-denied"))
        let deniedResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let denied = try XCTUnwrap(deniedResult.first)
        XCTAssertEqual(denied.state, .unknown)
        XCTAssertEqual(denied.reasons, [.refreshDenied])

        await fake.setRecheckProbe(.notPerformed("no-provider"))
        let notPerformedResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let notPerformed = try XCTUnwrap(notPerformedResult.first)
        XCTAssertEqual(notPerformed.state, .unknown)
        XCTAssertEqual(notPerformed.reasons, [.refreshNotPerformed])
    }

    func testRecheckWithoutBaselineNeverReportsCurrent() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _) = try await makeRegistry(fake)
        let version = BotContextSourceVersion.known(.contentSHA256, value: digest)
        await fake.setRecheckProbe(.version(version))
        let resultResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let result = try XCTUnwrap(resultResult.first)
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reasons, [.noBaseline])
        XCTAssertNil(result.baseline)
        XCTAssertNotNil(result.sourceVersion)
    }

    func testRecheckAfterRevokeIsDeniedWithZeroAdapterReads() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _) = try await makeRegistry(fake)
        await registry.revoke(source: .calendar, reason: "user-revoked")
        let before = await fake.counts()
        let resultResult = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let result = try XCTUnwrap(resultResult.first)
        let after = await fake.counts()
        XCTAssertEqual(result.state, .revoked)
        XCTAssertTrue(result.reasons.contains(.refreshDenied))
        XCTAssertTrue(result.reasons.contains(.grantRevoked))
        XCTAssertEqual(after.rechecks, before.rechecks, "a revoked source must perform zero adapter reads")
    }

    func testRecheckAfterOSDenialIsDeniedWithZeroAdapterReads() async throws {
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        let (registry, _) = try await makeRegistry(fake)
        await registry.noteOSAuthorizationChange(source: .calendar, status: .denied)
        let before = await fake.counts()
        let rechecked = await registry.recheck(botID: "bot-a", sources: [.calendar])
        let result = try XCTUnwrap(rechecked.first)
        let after = await fake.counts()
        XCTAssertEqual(result.state, .unknown)
        XCTAssertEqual(result.reasons, [.refreshDenied])
        XCTAssertEqual(after.rechecks, before.rechecks)
    }

    func testInjectedDriverRecheckStateMachine() async throws {
        let driver = BotContextInjectionDriver(kind: .locationFence, now: now)
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(driver, provenance: .injected)
        _ = try await registry.requestConsent(source: .locationFence, botID: "bot-a")
        let version = BotContextSourceVersion.known(.providerVersion, value: "rev:office")
        await driver.setRecheckProbe(.version(version))
        _ = try await driver.inject(
            kind: .locationEntered, payload: .object(["regionId": .string("office")]),
            sourceVersion: version)
        _ = try await registry.observations(for: "bot-a")
        try await Task.sleep(nanoseconds: 50_000_000)
        let resultResult = await registry.recheck(botID: "bot-a", sources: [.locationFence])
        let result = try XCTUnwrap(resultResult.first)
        XCTAssertEqual(result.state, .current)
        XCTAssertEqual(result.sourceVersion, version)
    }
}
