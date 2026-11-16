// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private final class EmittedObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [BotContextObservation] = []
    func append(_ observation: BotContextObservation) {
        lock.lock(); items.append(observation); lock.unlock()
    }
    func all() -> [BotContextObservation] {
        lock.lock(); defer { lock.unlock() }; return items
    }
}

final class ContextSourceUserEntryTests: XCTestCase {
    private let now: @Sendable () -> Int64 = { 1_000_000 }

    func testAllowedURLAcceptsAppOwnedSchemeAndDropsQueryAndFragment() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        let emitted = EmittedObservations()
        try await source.start(permissionRevision: 2) { emitted.append($0) }
        let url = try XCTUnwrap(URL(string: "phonedsh://bot/chat?token=super-secret-value#frag"))
        let observation = try source.accept(url: url)
        XCTAssertEqual(observation.source, .externalEntry)
        XCTAssertEqual(observation.kind, .externalURL)
        XCTAssertEqual(observation.delivery, .os)
        XCTAssertEqual(observation.permissionRevision, 2)
        XCTAssertTrue(observation.wakeRequested)
        guard case .object(let payload) = observation.payload else {
            return XCTFail("payload is not an object")
        }
        XCTAssertEqual(payload["scheme"], .string("phonedsh"))
        XCTAssertEqual(payload["host"], .string("bot"))
        XCTAssertEqual(payload["path"], .string("/chat"))
        XCTAssertNil(payload["query"])
        XCTAssertFalse(String(describing: payload).contains("super-secret-value"))
        XCTAssertEqual(emitted.all().count, 1)
        XCTAssertEqual(emitted.all().first?.id, observation.id)
    }

    func testUnknownURLSchemeIsRejected() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        try await source.start(permissionRevision: 1) { _ in }
        XCTAssertThrowsError(try source.accept(url: URL(string: "https://example.com/x")!)) { error in
            XCTAssertEqual(error as? BotContextSourceError,
                           .invalidRequest("URL scheme is not an App-owned entry"))
        }
    }

    func testUserActivityAndSharedItemAreBounded() async throws {
        let source = ExternalEntrySource(
            allowedSchemes: ["phonedsh"],
            allowedActivityTypes: ["dev.phone-dsh.probe.context-entry"], now: now)
        try await source.start(permissionRevision: 1) { _ in }
        let activity = NSUserActivity(activityType: "dev.phone-dsh.probe.context-entry")
        let observation = try source.accept(userActivity: activity)
        XCTAssertEqual(observation.kind, .externalUserActivity)
        XCTAssertEqual(observation.uncertainty.level, .low)

        let selection = try BotContextUserSelection(
            kind: .file, name: "receipt.pdf", mimeType: "application/pdf",
            byteCount: 1234, sha256: String(repeating: "a", count: 64))
        let shared = try source.accept(sharedItem: selection)
        XCTAssertEqual(shared.kind, .externalShareItem)
    }

    func testPastedTextRejectsCredentialShapeAndEmptyInput() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        try await source.start(permissionRevision: 1) { _ in }
        XCTAssertThrowsError(try source.accept(pastedText: ""))
        XCTAssertThrowsError(try source.accept(
            pastedText: "api_key=abcdefghijklmnop")) { error in
            XCTAssertEqual(error as? BotContextSourceError, .credentialShapeRejected)
        }
        let observation = try source.accept(pastedText: "明天下午三点开会")
        XCTAssertEqual(observation.kind, .externalPaste)
        XCTAssertEqual(observation.sourceVersion, .unversioned())
        XCTAssertEqual(observation.uncertainty.level, .medium)
    }

    func testStopRevokesDirectEntryCalls() async throws {
        let source = ExternalEntrySource(allowedSchemes: ["phonedsh"], now: now)
        try await source.start(permissionRevision: 1) { _ in }
        await source.stop()
        XCTAssertThrowsError(try source.accept(url: URL(string: "phonedsh://bot")!)) { error in
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.externalEntry))
        }
    }

    func testSelectedMediaCarriesMetadataOnlyAndStopRevokes() async throws {
        let source = SelectedMediaSource(now: now)
        let emitted = EmittedObservations()
        try await source.start(permissionRevision: 4) { emitted.append($0) }
        let hash = BotContextUserSelection.fingerprint(Data("receipt-bytes".utf8))
        let selection = try BotContextUserSelection(
            kind: .image, name: "receipt.jpg", mimeType: "image/jpeg",
            byteCount: 13, sha256: hash)
        let observation = try source.accept(selection)
        XCTAssertEqual(observation.source, .selectedMedia)
        XCTAssertEqual(observation.kind, .mediaSelected)
        XCTAssertEqual(observation.delivery, .os)
        XCTAssertEqual(observation.permissionRevision, 4)
        guard case .object(let payload) = observation.payload else {
            return XCTFail("payload is not an object")
        }
        XCTAssertNil(payload["fingerprint"], "the digest is metadata, not model-visible payload")
        XCTAssertEqual(payload["byteCount"], .number(13))
        XCTAssertEqual(observation.sourceVersion,
                       .known(.contentSHA256, value: "sha256:\(hash)", observedAt: 1_000_000))
        XCTAssertFalse(String(describing: payload).contains("receipt-bytes"))
        XCTAssertEqual(emitted.all().count, 1)

        await source.stop()
        XCTAssertThrowsError(try source.accept(selection)) { error in
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.selectedMedia))
        }
    }

    func testInjectionDriverStampsInjectedAndCannotUpgrade() async throws {
        let driver = BotContextInjectionDriver(kind: .locationFence, now: now)
        try await driver.start(permissionRevision: 2) { _ in }
        let observation = try driver.inject(
            kind: .locationEntered,
            payload: .object(["regionId": .string("office")]))
        XCTAssertEqual(observation.delivery, .injected)
        XCTAssertFalse(observation.delivery.isReal)
        XCTAssertEqual(observation.permissionRevision, 2)
        await driver.stop()
        XCTAssertThrowsError(try driver.inject(kind: .locationExited)) { error in
            XCTAssertEqual(error as? BotContextSourceError, .revoked(.locationFence))
        }
    }

    func testWakeRelayImplementsExistingSignalSourceAndStops() async throws {
        let relay = BotContextWakeRelay()
        let recorder = WakeSignalRecorder()
        await relay.start { signal in
            Task { await recorder.recordSignal(signal) }
        }
        let wake = try BotContextWake(
            botID: "bot-a", source: .locationFence, kind: .locationEntered,
            observationID: "o-1", observedAt: 1234, permissionRevision: 1,
            dedupeKey: "location:office:enter")
        await relay.emit(wake)
        for _ in 0..<50 {
            if await recorder.signals().count == 1 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let signals = await recorder.signals()
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.botId, "bot-a")
        XCTAssertEqual(signals.first?.reason, "context:location-fence:location.entered")
        XCTAssertEqual(signals.first?.at, 1234)
        await relay.stop()
        await relay.emit(wake)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await recorder.signals()
        XCTAssertEqual(after.count, 1)
    }
}

actor WakeSignalRecorder {
    private var values: [WakeSignal] = []
    func recordSignal(_ signal: WakeSignal) { values.append(signal) }
    func signals() -> [WakeSignal] { values }
}
