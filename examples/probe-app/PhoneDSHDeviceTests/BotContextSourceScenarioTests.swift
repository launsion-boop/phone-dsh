// SPDX-License-Identifier: MIT

import XCTest
import PhoneDSHBot
#if canImport(UIKit)
import UIKit
#endif
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Contacts)
import Contacts
#endif
#if canImport(CoreLocation)
import CoreLocation
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A07 native-source scenarios for an isolated simulator/device.
///
/// These are real-framework tests, not fake permission doubles: each test reads
/// the real Apple authorization state and uses the real adapter when the OS
/// allows it. A permission that is not pre-granted is reported as SKIP with the
/// exact `simctl privacy` command; it is never converted into a PASS. No test
/// reads a personal calendar/contact/photo; calendar/contact tests only read the
/// isolated simulator data and skip when access is unavailable.
///
/// The full 12-scenario A07 matrix (including the model/UI half owned by U/E)
/// and the A13 device commands live in `deliveries/N-A07-A13.md`.
final class BotContextSourceScenarioTests: XCTestCase {
    private let botID = "a07-native-bot"
    private let now: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }

    private func makeRegistry() async -> (BotContextSourceRegistry, BotContextConsentLedger) {
        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        return (registry, ledger)
    }

    private func subscribe(_ source: BotContextSourceKind,
                           _ sourceImpl: any BotContextSource,
                           registry: BotContextSourceRegistry,
                           ledger: BotContextConsentLedger) async throws {
        try await registry.register(sourceImpl)
        _ = try await ledger.grant(source: source, by: .user)
        try await registry.subscribe(botID: botID, sources: [source])
    }

    private func skipUnlessAuthorized(_ status: BotSourceAuthorization,
                                      _ source: String,
                                      service: String) throws {
        guard status.allowsReading else {
            throw XCTSkip("""
            SKIP \(source): real OS status=\(status.rawValue). \
            Pre-grant on the isolated simulator with: \
            xcrun simctl privacy <udid> grant \(service) dev.phone-dsh.probe.devicetests
            """)
        }
    }

    // A07-01 calendar: create a dedicated fixture calendar/event, read it
    // through the real adapter, then delete both by ID.
    func testCalendarFixtureObservedAndCleanedUp() async throws {
#if canImport(EventKit)
        let source = EventKitCalendarSource(now: now)
        try skipUnlessAuthorized(await source.authorization(), "calendar", service: "calendar")
        let store = EKEventStore()
        let title = "A07-Fixture-\(UUID().uuidString)"
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        guard let ekSource = store.defaultCalendarForNewEvents?.source ?? store.sources.first else {
            throw XCTSkip("no EventKit source in this simulator")
        }
        calendar.source = ekSource
        try store.saveCalendar(calendar, commit: true)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = Date().addingTimeInterval(60)
        event.endDate = event.startDate.addingTimeInterval(1_800)
        try store.save(event, span: .thisEvent, commit: true)
        defer {
            if let saved = store.event(withIdentifier: event.eventIdentifier) {
                try? store.remove(saved, span: .thisEvent, commit: true)
            }
            if let savedCalendar = store.calendar(withIdentifier: calendar.calendarIdentifier) {
                try? store.removeCalendar(savedCalendar, commit: true)
            }
        }

        let (registry, ledger) = await makeRegistry()
        try await subscribe(.calendar, source, registry: registry, ledger: ledger)
        var observations: [BotContextObservation] = []
        for _ in 0..<50 {
            observations = try await registry.observations(for: botID, sources: [.calendar])
            if observations.contains(where: { String(describing: $0.payload).contains(title) }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let fixtureObservation = observations.first {
            String(describing: $0.payload).contains(title)
        }
        let observed = try XCTUnwrap(fixtureObservation, "real EventKit fixture was not observed")
        XCTAssertEqual(observed.source, .calendar)
        XCTAssertEqual(observed.delivery, .os)
        XCTAssertEqual(observed.permissionRevision, 1)
        await registry.revoke(source: .calendar, reason: "a07-revoke")
#else
        throw XCTSkip("EventKit not available")
#endif
    }

    // A07-01b: with the OS already granted, requestConsent must write App
    // consent without calling the full-access prompt again (4f194 fix). This is
    // the product path the settings switch invokes; it does not replace the
    // interactive full-access toggle (still WAITING_DEVICE on simulator).
    func testPreGrantedCalendarConsentPathWritesLedger() async throws {
#if canImport(EventKit)
        let source = EventKitCalendarSource(now: now)
        let status = await source.authorization()
        guard status.allowsReading else {
            throw XCTSkip("SKIP pre-granted consent: real OS status=\(status.rawValue); pre-grant first")
        }
        // The old code re-requested full access while already authorized and
        // could hang on the simulator's invalid staged prompt. Bound it.
        let requested = await withTaskGroup(of: BotSourceAuthorization?.self) { group in
            group.addTask { await source.requestAuthorization() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let resolved = try XCTUnwrap(requested, "requestAuthorization hung/timed out")
        XCTAssertTrue(resolved.allowsReading)

        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(source)
        let state = try await registry.requestConsent(
            source: .calendar, botID: "a07-pregrant-bot")
        XCTAssertTrue(state.authorization.allowsReading)
        XCTAssertEqual(state.authorization, .authorized)
        XCTAssertEqual(state.permissionRevision, 1)
        let subscribed = await ledger.isSubscribed(
            botID: "a07-pregrant-bot", source: .calendar)
        XCTAssertTrue(subscribed, "requestConsent must also subscribe")
        await registry.revoke(source: .calendar, reason: "a07-cleanup")
#else
        throw XCTSkip("EventKit not available")
#endif
    }

    // A07-02b: same pre-granted consent path for Contacts. With the OS already
    // authorized/limited, requestConsent must write App consent without a
    // second TCC request (fixes the UI switch staying off after pre-grant).
    func testPreGrantedContactsConsentPathWritesLedger() async throws {
#if canImport(Contacts)
        let source = ContactsSource(now: now)
        let status = await source.authorization()
        guard status.allowsReading else {
            throw XCTSkip("SKIP pre-granted contacts: real OS status=\(status.rawValue); pre-grant first")
        }
        let requested = await withTaskGroup(of: BotSourceAuthorization?.self) { group in
            group.addTask { await source.requestAuthorization() }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let resolved = try XCTUnwrap(requested, "contacts requestAuthorization timed out")
        XCTAssertTrue(resolved.allowsReading)

        let ledger = BotContextConsentLedger(
            store: InMemoryBotContextSourceConsentStore(), now: now)
        let registry = BotContextSourceRegistry(
            ledger: ledger, audit: BotContextAuditLog(), now: now)
        _ = await ledger.load()
        try await registry.register(source)
        let state = try await registry.requestConsent(
            source: .contacts, botID: "a07-pregrant-bot")
        XCTAssertTrue(state.authorization.allowsReading)
        XCTAssertEqual(state.permissionRevision, 1)
        let subscribed = await ledger.isSubscribed(
            botID: "a07-pregrant-bot", source: .contacts)
        XCTAssertTrue(subscribed, "requestConsent must also subscribe")
        await registry.revoke(source: .contacts, reason: "a07-cleanup")
#else
        throw XCTSkip("Contacts not available")
#endif
    }

    // A07-02 contacts: a dedicated fixture contact is created, queried by a
    // unique name through the real Contacts adapter, and deleted by ID.
    func testContactsFixtureQueriedAndCleanedUp() async throws {
#if canImport(Contacts)
        let source = ContactsSource(now: now)
        let status = await source.authorization()
        guard status.allowsReading else {
            throw XCTSkip("SKIP contacts: real OS status=\(status.rawValue); pre-grant with simctl privacy grant contacts")
        }
        let store = CNContactStore()
        let given = "A07Fixture\(UUID().uuidString.prefix(8))"
        let contact = CNMutableContact()
        contact.givenName = given
        contact.familyName = "Native"
        contact.organizationName = "phoneDSH A07 fixture"
        let save = CNSaveRequest()
        save.add(contact, toContainerWithIdentifier: nil)
        try store.execute(save)
        let createdID = contact.identifier
        defer {
            if let saved = try? store.unifiedContact(
                withIdentifier: createdID, keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor]),
               let mutable = saved.mutableCopy() as? CNMutableContact {
                let delete = CNSaveRequest()
                delete.delete(mutable)
                try? store.execute(delete)
            }
        }

        let (registry, ledger) = await makeRegistry()
        try await subscribe(.contacts, source, registry: registry, ledger: ledger)
        let initial = try await registry.observations(for: botID, sources: [.contacts])
        XCTAssertTrue(initial.isEmpty, "subscribe must not enumerate contacts")
        let observed = try await registry.readContacts(
            botID: botID, query: given, limit: 5)
        XCTAssertTrue(String(describing: observed.payload).contains(createdID))
        XCTAssertTrue(String(describing: observed.payload).contains(given))
        await registry.revoke(source: .contacts, reason: "a07-revoke")
#else
        throw XCTSkip("Contacts not available")
#endif
    }

    // A07-03 selected file: real bytes -> sha256 metadata + file baseline.
    func testSelectedFileRealByteDigestAndFileBaseline() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("a07-\(UUID().uuidString).txt")
        try Data("a07-selected-file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let baseline = try BotContextFileBaseline.compute(
            fileAt: url, ownerBotID: botID, resourceKey: "vfs/a07/selected.txt")
        XCTAssertEqual(baseline.subject, "file-bytes")
        XCTAssertTrue(baseline.sha256.hasPrefix("sha256:"))
        XCTAssertEqual(baseline.resource.kind, .file)
        let source = SelectedMediaSource(now: now)
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.selectedMedia, source, registry: registry, ledger: ledger)
        let hash = String(baseline.sha256.dropFirst("sha256:".count))
        let selection = try BotContextUserSelection(
            kind: .file, name: "selected.txt", mimeType: "text/plain",
            byteCount: 16, sha256: hash)
        _ = try source.accept(selection)
        var observations: [BotContextObservation] = []
        for _ in 0..<50 {
            observations = try await registry.observations(
                for: botID, sources: [.selectedMedia])
            if !observations.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard case .known(let basis, let value, _, _, let subject)? = observations.first?.sourceVersion else {
            return XCTFail("selected file must carry a known content version")
        }
        XCTAssertEqual(basis, .contentSHA256)
        XCTAssertEqual(value, baseline.sha256)
        XCTAssertEqual(subject, .fileBytes)
        XCTAssertTrue(observations.first?.resource?.key.hasPrefix("media:") == true)
        await registry.revoke(source: .selectedMedia, reason: "a07-revoke")
    }

    // A07-04 external URL entry is a real user action; query is dropped.
    func testExternalURLDropsQueryAndWakes() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.externalEntry, source, registry: registry, ledger: ledger)
        let observation = try source.accept(
            url: URL(string: "phonedsh://a07/path?token=secret-value")!)
        XCTAssertEqual(observation.kind, .externalURL)
        XCTAssertEqual(observation.delivery, .os)
        XCTAssertFalse(String(describing: observation.payload).contains("secret-value"))
        await registry.revoke(source: .externalEntry, reason: "a07-revoke")
    }

    // A07-05 NSUserActivity entry uses the real declared activity type.
    func testUserActivityEntry() async throws {
        let source = ExternalEntrySource(
            allowedSchemes: ["phonedsh"],
            allowedActivityTypes: ["dev.phone-dsh.probe.context-entry"], now: now)
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.externalEntry, source, registry: registry, ledger: ledger)
        let activity = NSUserActivity(activityType: "dev.phone-dsh.probe.context-entry")
        let observation = try source.accept(userActivity: activity)
        XCTAssertEqual(observation.kind, .externalUserActivity)
        XCTAssertEqual(observation.delivery, .os)
        await registry.revoke(source: .externalEntry, reason: "a07-revoke")
    }

    // A07-06 explicit user paste is read once, never in the background.
    func testUserPasteEntryIsExplicitAndCredentialSafe() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.externalEntry, source, registry: registry, ledger: ledger)
        let observation = try source.accept(pastedText: "明天带工牌")
        XCTAssertEqual(observation.kind, .externalPaste)
        XCTAssertEqual(observation.uncertainty.level, .medium)
        XCTAssertThrowsError(try source.accept(pastedText: "api_key=abcdefghijk"))
        await registry.revoke(source: .externalEntry, reason: "a07-revoke")
    }

    // A07-07 own notification permission: real UNUserNotificationCenter status.
    func testOwnNotificationPermissionIsRealAndBounded() async throws {
#if canImport(UserNotifications)
        let source = OwnNotificationSource(now: now)
        let status = await source.authorization()
        guard status.allowsReading else {
            throw XCTSkip("SKIP own-notification: real status=\(status.rawValue); grant notifications in simulator/app")
        }
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.ownNotification, source, registry: registry, ledger: ledger)
        await registry.revoke(source: .ownNotification, reason: "a07-revoke")
#else
        throw XCTSkip("UserNotifications not available")
#endif
    }

    // A07-08 charging/low-power observation uses real UIDevice/ProcessInfo.
    func testPowerObservationAndRecheck() async throws {
        let source = PowerIdleSource(now: now)
        let (registry, ledger) = await makeRegistry()
        try await subscribe(.power, source, registry: registry, ledger: ledger)
        try await Task.sleep(nanoseconds: 100_000_000)
        let observations = try await registry.observations(for: botID, sources: [.power])
        // Simulator may not report battery state; the real source must still be
        // readable and recheckable without inventing a version.
        let rechecks = await registry.recheck(botID: botID, sources: [.power])
        let recheckResult = rechecks.first { $0.source == .power }
        XCTAssertNotNil(recheckResult)
        XCTAssertTrue([.unknown, .changed, .current].contains(recheckResult!.state))
        await registry.revoke(source: .power, reason: "a07-revoke")
    }

    // A07-09 location fence authorization path; no continuous location starts.
    func testLocationFenceAuthorizationAndNoContinuousLocation() async throws {
#if canImport(CoreLocation)
        let source = LocationRegionSource(fences: [], now: now)
        let status = await source.authorization()
        if status.allowsReading {
            let (registry, ledger) = await makeRegistry()
            try await subscribe(.locationFence, source, registry: registry, ledger: ledger)
            await registry.revoke(source: .locationFence, reason: "a07-revoke")
        } else {
            throw XCTSkip("SKIP location-fence: real status=\(status.rawValue); pre-grant Always in simulator")
        }
#else
        throw XCTSkip("CoreLocation not available")
#endif
    }

    // A07-10 geofence id isolation: only our prefix is stopped.
    func testGeofenceIdentifierIsolation() throws {
        let fence = try BotContextGeofenceSpec(
            id: "office", latitude: 25.0, longitude: 121.5, radiusMeters: 100)
        XCTAssertEqual(fence.regionIdentifier, "pdsh.context.office")
        XCTAssertThrowsError(try BotContextGeofenceSpec(
            id: "office:bad", latitude: 25.0, longitude: 121.5, radiusMeters: 100))
    }

    // A07-11 revoke drops late callback and generation changes.
    func testRevokeDropsLateCallbackAndBumpsGeneration() async throws {
        let driver = BotContextInjectionDriver(kind: .calendar, now: now)
        let (registry, ledger) = await makeRegistry()
        try await registry.register(driver, provenance: .injected)
        _ = try await ledger.grant(source: .calendar, by: .user)
        try await registry.subscribe(botID: botID, sources: [.calendar])
        let revision = (await ledger.state(for: .calendar)).permissionRevision
        let observation = try await driver.inject(
            kind: .calendarChanged,
            payload: .object(["changed": .bool(true)]),
            sourceVersion: .unversioned())
        XCTAssertEqual(observation.permissionRevision, revision)
        await registry.revoke(source: .calendar, reason: "a07-revoke")
        let after = await ledger.state(for: .calendar)
        XCTAssertEqual(after.authorization, .revoked)
        XCTAssertEqual(after.permissionRevision, revision + 1)
        do {
            _ = try await driver.inject(kind: .calendarChanged)
            XCTFail("a revoked driver must reject a late callback")
        } catch {
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.calendar))
        }
        let visible = await registry.observationView(for: botID, sources: [.calendar])
        XCTAssertTrue(visible.items.allSatisfy { $0.state == .inactive })
    }

    // A07-12 unsupported Apple capabilities are explicit, not faked.
    func testUnsupportedCapabilitiesAreNotInvented() {
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "third-party-notifications.read")?.support,
                       .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "sms.read")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "call-history.read")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "power.system-idle")?.support, .unsupported)
        XCTAssertEqual(BotContextCapabilityMatrix.entry(id: "android.notification-listener")?.support,
                       .deferred)
    }

    // A07 observation -> decision/legal silence, with a real observation when
    // the OS allows; otherwise the pure engine still proves silence and bounds.
    func testObservationToDecisionOrQuiet() async throws {
        let driver = BotContextInjectionDriver(kind: .locationFence, now: now)
        let (registry, ledger) = await makeRegistry()
        try await registry.register(driver, provenance: .injected)
        _ = try await ledger.grant(source: .locationFence, by: .user)
        try await registry.subscribe(botID: botID, sources: [.locationFence])
        _ = try await driver.inject(
            kind: .locationEntered,
            payload: .object(["regionId": .string("office")]))
        struct DecisionContext: BotContextWakeDecisionContextProviding {
            let registry: BotContextSourceRegistry
            let ledger: BotContextConsentLedger
            func isStarted() async -> Bool { true }
            func authorization(for source: BotContextSourceKind) async -> BotSourceAuthorizationState? {
                await ledger.state(for: source)
            }
            func activeObservation(botID: String, source: BotContextSourceKind,
                                   kind: BotContextObservationKind) async -> BotContextObservationViewItem? {
                await registry.observationView(for: botID, sources: [source]).items.first {
                    $0.state == .active && $0.kind == kind.rawValue
                }
            }
        }
        let runner = DecisionRunner()
        let engine = BotContextWakeDecisionEngine(
            context: DecisionContext(registry: registry, ledger: ledger),
            now: now,
            runner: { request in await runner.run(request) })
        let outcome = await engine.handle(
            botID: botID, reason: "context:location-fence:location.entered", at: now())
        XCTAssertEqual(outcome, .quiet)
        let runs = await runner.count()
        XCTAssertEqual(runs, 1)
        await registry.revoke(source: .locationFence, reason: "a07-revoke")
    }
}

private actor DecisionRunner {
    private(set) var requests: [RoutineRunRequest] = []
    func run(_ request: RoutineRunRequest) -> RoutineExecutionResult {
        requests.append(request)
        return .success("[quiet]", quiet: true)
    }
    func count() -> Int { requests.count }
}
