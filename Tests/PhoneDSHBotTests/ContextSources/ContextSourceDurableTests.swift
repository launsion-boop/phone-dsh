// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private actor CapturingEventLog: BotEventLog {
    private var items: [BotEvent] = []
    private var next = 0

    func append(_ event: BotEvent) async throws -> Int {
        next += 1
        items.append(event)
        return next
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        items.filter { ($0.commitSeq ?? 0) > commitSeq }.prefix(limit).map { $0 }
    }

    func all() -> [BotEvent] { items }
}

final class ContextSourceDurableTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 1_000_000 }

    private func observation() throws -> BotContextObservation {
        try BotContextObservation(
            id: "obs-1", source: .calendar, kind: .calendarChanged,
            observedAt: 1_000_001, permissionRevision: 2,
            sourceVersion: .unversioned(),
            uncertainty: BotContextUncertainty(level: .high, reason: "no-event-identity"),
            delivery: .os, payload: .object(["changed": .bool(true)]),
            dedupeKey: "calendar:changed:1", wakeRequested: true)
    }

    func testObservationEventUsesFrozenTypeAndShape() async throws {
        let log = CapturingEventLog()
        let writer = BotContextDurableWriter(eventLog: log, now: now)
        let recorded = await writer.record(try observation(), ownerBotID: "bot-a")
        let recordRef = try XCTUnwrap(recorded?.recordRef)
        XCTAssertEqual(recordRef, "record://event/1")
        let events = await log.all()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.type, "context.observed")
        XCTAssertEqual(event.ignorable ?? false, true)
        XCTAssertEqual(event.origin, .local(source: "runtime"))
        XCTAssertEqual(event.principal.kind, "proactive")
        XCTAssertEqual(event.principal.botId, "bot-a")
        XCTAssertEqual(event.time, 1_000_001)
        guard case .object(let data) = event.data else { return XCTFail("data is not an object") }
        XCTAssertEqual(data["schema"], .string("bot-context-observation/v1"))
        XCTAssertEqual(data["source"], .string("calendar"))
        XCTAssertEqual(data["kind"], .string("calendar.changed"))
        XCTAssertEqual(data["observed_at_ms"], .number(1_000_001))
        XCTAssertEqual(data["owner_bot_id"], .string("bot-a"))
        XCTAssertEqual(data["consent_generation"], .number(2))
        XCTAssertEqual(data["delivery"], .string("os"))
        XCTAssertEqual(data["dedupe_key"], .string("calendar:changed:1"))
        XCTAssertEqual(data["wake_requested"], .bool(true))
        XCTAssertNil(data["id"])
        XCTAssertEqual(data["resource"]?.objectValue?["kind"]?.stringValue, "context-source")
        XCTAssertEqual(data["resource"]?.objectValue?["owner"]?.stringValue, "bot-a")
    }

    func testConsentChangedEventUsesFrozenShapeAndIgnoresNonConsentAudit() async throws {
        let log = CapturingEventLog()
        let writer = BotContextDurableWriter(eventLog: log, now: now)
        await writer.record(BotContextAuditEvent(
            kind: .observationAccepted, source: .calendar, at: 1,
            permissionRevision: 1, detail: "accepted"))
        let afterAudit = await log.all()
        XCTAssertTrue(afterAudit.isEmpty)

        await writer.record(BotContextAuditEvent(
            kind: .consentChanged, source: .calendar, ownerBotID: "bot-a",
            at: 1_000, permissionRevision: 2, detail: "user-revoked",
            previous: .authorized, current: .revoked,
            by: .user, osState: .authorized))
        let events = await log.all()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.type, "context.consent_changed")
        XCTAssertEqual(event.ignorable ?? false, true)
        XCTAssertEqual(event.origin, .local(source: "runtime"))
        XCTAssertEqual(event.principal.kind, "proactive")
        guard case .object(let data) = event.data else { return XCTFail("data is not an object") }
        XCTAssertEqual(data["schema"], .string("bot-context-consent-changed/v1"))
        XCTAssertEqual(data["source"], .string("calendar"))
        XCTAssertEqual(data["generation"], .number(2))
        XCTAssertEqual(data["previous"], .string("authorized"))
        XCTAssertEqual(data["consent"], .string("revoked"))
        XCTAssertEqual(data["os_state"], .string("authorized"))
        XCTAssertEqual(data["by"], .string("user"))
        XCTAssertEqual(data["at_ms"], .number(1_000))
        XCTAssertEqual(data["reason"], .string("user-revoked"))
    }

    func testWriterRejectsMissingOwnerAndMissingConsentTransition() async throws {
        let log = CapturingEventLog()
        let writer = BotContextDurableWriter(eventLog: log, now: now)
        let missingOwner = await writer.record(try observation(), ownerBotID: "")
        XCTAssertNil(missingOwner)
        await writer.record(BotContextAuditEvent(
            kind: .consentChanged, source: .calendar, at: 1,
            permissionRevision: 0, detail: "no-transition"))
        let afterAudit = await log.all()
        XCTAssertTrue(afterAudit.isEmpty)
    }

    func testViewIsPayloadFreeAndBecomesInactiveAfterRevoke() async throws {
        let store = InMemoryBotContextSourceConsentStore()
        let ledger = BotContextConsentLedger(store: store, now: now)
        let audit = BotContextAuditLog()
        let log = CapturingEventLog()
        let writer = BotContextDurableWriter(eventLog: log, now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: audit,
            observationRecorder: writer, consentRecorder: writer, now: now)
        _ = await ledger.load()
        let fake = FakeContextSource(kind: .calendar, osStatus: .authorized)
        try await registry.register(fake)
        _ = try await registry.requestConsent(source: .calendar, botID: "bot-a")
        await fake.emit(try await fake.observation(observedAt: 1_000_001, revision: 1))
        for _ in 0..<50 {
            let view = await registry.observationView(for: "bot-a", sources: [.calendar])
            if !view.items.isEmpty {
                let item = try XCTUnwrap(view.items.first)
                XCTAssertEqual(item.state, .active)
                XCTAssertEqual(item.consentGeneration, 1)
                XCTAssertTrue(item.recordRef?.hasPrefix("record://event/") == true)
                XCTAssertFalse(String(describing: item).contains("payload"))
                await registry.revoke(source: .calendar, reason: "user-revoked")
                let after = await registry.observationView(for: "bot-a", sources: [.calendar])
                let inactive = try XCTUnwrap(after.items.first)
                XCTAssertEqual(inactive.state, .inactive)
                XCTAssertEqual(inactive.inactiveReason, .revoked)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("observation view never became active")
    }
}
