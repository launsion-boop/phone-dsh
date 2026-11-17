// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import XCTest
@testable import PhoneDSHBot

private struct FeatureAdminRoots: BotSkillRootResolving {
    var user: URL
    var project: URL
    func root(for source: BotSkillSource, ownerBotID: String?) -> URL? {
        source == .userDsh ? user : project
    }
}

private let featureAdminTestNow: Int64 = 1_760_000_000_000

private actor FeatureAdminTestLog: BotEventLog {
    private var storage: [Int: BotEvent] = [:]
    private var nextSeq = 1
    var failApplied = false

    func setFailApplied(_ value: Bool) { failApplied = value }

    func append(_ event: BotEvent) async throws -> Int {
        if failApplied,
           event.type == BotFeatureAdminSkillMutationRecorder.eventType,
           event.data["status"]?.stringValue == "applied" {
            throw TestFailure.appliedAppend
        }
        if let existing = storage.values.first(where: { $0.eventId == event.eventId }),
           let seq = existing.commitSeq {
            return seq
        }
        let seq = nextSeq
        nextSeq += 1
        storage[seq] = event.assigningCommitSeq(seq)
        return seq
    }

    func events(after commitSeq: Int, limit: Int) async throws -> [BotEvent] {
        Array(storage.values.filter { ($0.commitSeq ?? 0) > commitSeq }
            .sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }
            .prefix(limit))
    }

    func all() -> [BotEvent] {
        storage.values.sorted { ($0.commitSeq ?? 0) < ($1.commitSeq ?? 0) }
    }

    enum TestFailure: Error, Sendable { case appliedAppend }
}

private final class FeatureAdminQueueSpy: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var suppressed: [(String, String, String)] = []
    private(set) var cleared: [String] = []
    private(set) var emitted: [(String, BotFeatureAdminSkillMutationAction, String, String)] = []
    var ready = true
    var emitResult = true

    func queue() -> BotFeatureAdminSkillMutationQueue {
        BotFeatureAdminSkillMutationQueue(
            ready: { [weak self] in self?.ready ?? false },
            suppress: { [weak self] file, action, operationID in
                guard let self else { return }
                lock.lock(); suppressed.append((file, action, operationID)); lock.unlock()
            },
            clear: { [weak self] operationID in
                guard let self else { return }
                lock.lock(); cleared.append(operationID); lock.unlock()
            },
            emit: { [weak self] file, action, request, applied in
                guard let self else { return false }
                lock.lock(); emitted.append((file, action, request, applied)); lock.unlock()
                return self.emitResult
            })
    }
}

final class BotFeatureAdminSkillMutationTests: XCTestCase {
    private var root: URL!
    private var userDir: URL!
    private var projectDir: URL!
    private var roots: FeatureAdminRoots!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-admin-records-\(UUID().uuidString)",
                                    isDirectory: true)
        userDir = root.appendingPathComponent("materialized/home/skills", isDirectory: true)
        projectDir = root.appendingPathComponent("bot/.dsh/skills", isDirectory: true)
        try FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        roots = FeatureAdminRoots(user: userDir, project: projectDir)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func beginBody(operationID: String = "op-1",
                           action: String = "write",
                           file: String = "weekly.md",
                           content: String) -> BotJSONValue {
        .object([
            "op": .string("begin"),
            "operation_id": .string(operationID),
            "action": .string(action),
            "file": .string(file),
            "content": .string(content),
            "content_sha256": .string(contentHash(content)),
            "bytes": .number(Double(Data(content.utf8).count)),
        ])
    }

    private func result(_ value: BotJSONValue) -> [String: BotJSONValue] {
        guard let object = value.objectValue else {
            XCTFail("reply is not an object")
            return [:]
        }
        return object
    }

    private func recorder(_ log: FeatureAdminTestLog,
                          queue: FeatureAdminQueueSpy) -> BotFeatureAdminSkillMutationRecorder {
        BotFeatureAdminSkillMutationRecorder(
            eventLog: log, userSkillsRoot: userDir, queue: queue.queue(),
            now: { featureAdminTestNow }, fileVerificationAttempts: 1)
    }

    func testRequestedRecordCarriesRecoverableActualInput() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let content = "# Weekly\n\n- ship the fixed record chain\n"
        let reply = result(await recorder.handle(beginBody(content: content)))
        XCTAssertEqual(reply["ok"]?.boolValue, true)
        XCTAssertEqual(reply["status"]?.stringValue, "requested")
        let record = try XCTUnwrap(reply["record"]?.stringValue)
        XCTAssertTrue(record.hasPrefix("record://event/"))

        let events = await log.all()
        XCTAssertEqual(events.count, 1)
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.type, "feature-admin.skill_mutation")
        XCTAssertEqual(event.ignorable, true)
        XCTAssertEqual(event.data["schema"]?.stringValue, "phone-skill-mutation/v2")
        XCTAssertEqual(event.data["status"]?.stringValue, "requested")
        XCTAssertEqual(event.data["action"]?.stringValue, "write")
        XCTAssertEqual(event.data["file"]?.stringValue, "weekly.md")
        XCTAssertEqual(event.data["content"]?.stringValue, content)
        XCTAssertEqual(event.data["content_sha256"]?.stringValue, contentHash(content))
        XCTAssertEqual(event.data["bytes"]?.intValue, content.utf8.count)
        XCTAssertEqual(event.data["actor"]?["kind"]?.stringValue, "user")
        XCTAssertEqual(event.data["surface"]?.stringValue, "phone-feature-admin")
        XCTAssertNil(event.principal.sessionId)
        XCTAssertNil(event.principal.botId)
        XCTAssertNil(event.data["request_record"])
        XCTAssertEqual(spy.suppressed.count, 1)
        XCTAssertEqual(spy.suppressed.first?.0, "weekly.md")
        XCTAssertEqual(spy.suppressed.first?.1, "write")
    }

    func testBeginRejectsMismatchedHashWithoutAppendingOrSuppressing() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        var object = try XCTUnwrap(beginBody(content: "real body").objectValue)
        object["content_sha256"] = .string(String(repeating: "0", count: 64))
        let reply = result(await recorder.handle(.object(object)))
        XCTAssertEqual(reply["ok"]?.boolValue, false)
        XCTAssertEqual(reply["code"]?.stringValue, "invalid-request")
        let events = await log.all()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(spy.suppressed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("weekly.md").path))
    }

    func testBeginFailsClosedWhenQueueIsNotAttached() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        spy.ready = false
        let recorder = recorder(log, queue: spy)
        let reply = result(await recorder.handle(beginBody(content: "body")))
        XCTAssertEqual(reply["ok"]?.boolValue, false)
        XCTAssertEqual(reply["code"]?.stringValue, "unavailable")
        let events = await log.all()
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(spy.suppressed.isEmpty)
    }

    func testDeleteBeginBindsTheContentActuallyOnDisk() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let file = userDir.appendingPathComponent("weekly.md")
        try Data("on disk".utf8).write(to: file)

        let wrong = result(await recorder.handle(
            beginBody(action: "delete", content: "stale reader")))
        XCTAssertEqual(wrong["ok"]?.boolValue, false)
        XCTAssertEqual(wrong["code"]?.stringValue, "file-mismatch")
        let afterWrong = await log.all()
        XCTAssertTrue(afterWrong.isEmpty)
        XCTAssertTrue(spy.suppressed.isEmpty)

        let right = result(await recorder.handle(
            beginBody(action: "delete", content: "on disk")))
        XCTAssertEqual(right["ok"]?.boolValue, true)
        XCTAssertEqual(right["status"]?.stringValue, "requested")
        let events = await log.all()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.data["action"]?.stringValue, "delete")
        XCTAssertEqual(event.data["content"]?.stringValue, "on disk")
        XCTAssertEqual(event.data["content_sha256"]?.stringValue, contentHash("on disk"))
        XCTAssertEqual(spy.suppressed.first?.1, "delete")
    }

    func testAppliedCarriesRequestRecordAndEmitsAppliedBasisOnce() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let content = "# Weekly\n"
        let begin = result(await recorder.handle(beginBody(content: content)))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))

        let applied = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(applied["ok"]?.boolValue, true)
        XCTAssertEqual(applied["status"]?.stringValue, "applied")
        XCTAssertEqual(applied["skill_event"]?.boolValue, true)
        let appliedRecord = try XCTUnwrap(applied["record"]?.stringValue)

        let events = await log.all()
        XCTAssertEqual(events.count, 2)
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.data["status"]?.stringValue, "applied")
        XCTAssertEqual(event.data["request_record"]?.stringValue, requestRecord)
        XCTAssertEqual(event.data["content_sha256"]?.stringValue, contentHash(content))
        XCTAssertNil(event.data["content"])
        XCTAssertEqual(spy.emitted.count, 1)
        XCTAssertEqual(spy.emitted.first?.2, requestRecord)
        XCTAssertEqual(spy.emitted.first?.3, appliedRecord)
        XCTAssertTrue(spy.cleared.isEmpty, "a successful applied keeps the one-shot observer suppression")
    }

    func testAppliedDetectsDifferentFinalBytesAndNeverEmits() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let begin = result(await recorder.handle(beginBody(content: "wanted")))
        _ = try XCTUnwrap(begin["record"]?.stringValue)
        try Data("something else".utf8).write(to: userDir.appendingPathComponent("weekly.md"))

        let applied = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(applied["ok"]?.boolValue, false)
        XCTAssertEqual(applied["code"]?.stringValue, "file-mismatch")
        let events = await log.all()
        XCTAssertEqual(events.compactMap { $0.data["status"]?.stringValue }, ["requested", "failed"])
        XCTAssertEqual(events.last?.data["failure_code"]?.stringValue, "file-mismatch")
        XCTAssertTrue(spy.emitted.isEmpty)
        XCTAssertEqual(spy.cleared, ["op-1"])
    }

    func testAppliedAppendFailureKeepsRequestedAndNeverEmits() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        await log.setFailApplied(true)
        let begin = result(await recorder.handle(beginBody(content: "wanted")))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data("wanted".utf8).write(to: userDir.appendingPathComponent("weekly.md"))

        let applied = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(applied["ok"]?.boolValue, false)
        XCTAssertEqual(applied["code"]?.stringValue, "append-failed")
        let events = await log.all()
        XCTAssertEqual(events.compactMap { $0.data["status"]?.stringValue }, ["requested"])
        XCTAssertEqual("record://event/\(events.first?.commitSeq ?? 0)", requestRecord)
        XCTAssertTrue(spy.emitted.isEmpty)
        XCTAssertTrue(spy.cleared.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("weekly.md").path))

        // Repair: the requested fact and file remain; a retry can complete the
        // same operation after the append path recovers.
        await log.setFailApplied(false)
        let retry = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(retry["ok"]?.boolValue, true)
        XCTAssertEqual(spy.emitted.count, 1)
    }

    func testFailedAppendCarriesBoundedCodeAndClearsOneShotSuppression() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let begin = result(await recorder.handle(beginBody(content: "wanted")))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        let failed = result(await recorder.handle(.object([
            "op": .string("failed"), "operation_id": .string("op-1"),
            "failure_code": .string("EACCES"),
        ])))
        XCTAssertEqual(failed["ok"]?.boolValue, true)
        XCTAssertEqual(failed["status"]?.stringValue, "failed")
        let events = await log.all()
        XCTAssertEqual(events.compactMap { $0.data["status"]?.stringValue }, ["requested", "failed"])
        XCTAssertEqual(events.last?.data["request_record"]?.stringValue, requestRecord)
        XCTAssertEqual(events.last?.data["failure_code"]?.stringValue, "EACCES")
        XCTAssertTrue(spy.emitted.isEmpty)
        XCTAssertEqual(spy.cleared, ["op-1"])
    }

    func testDuplicateAppliedRepairsIdempotently() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        _ = result(await recorder.handle(beginBody(content: "wanted")))
        try Data("wanted".utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let first = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        let second = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(first["record"]?.stringValue, second["record"]?.stringValue)
        let events = await log.all()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(spy.emitted.count, 2, "repair reuses the same durable applied record")
        XCTAssertEqual(spy.emitted[0].3, spy.emitted[1].3)
    }

    // MARK: - real producer chain

    func testOneUserWriteProducesOneSkillChangedSourcedToAppliedBasis() async throws {
        let log = FeatureAdminTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotSkillFileRechecker(roots: roots))
        let producer = BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/bot-a",
            roots: roots,
            recorder: { try await service.recordSkillWrite($0) },
            latest: { try await service.latestSkillChange(identity: $0) },
            now: { featureAdminTestNow })
        let queue = BotSkillEventQueue(producer: producer, now: { featureAdminTestNow })
        let recorder = BotFeatureAdminSkillMutationRecorder(
            eventLog: log, userSkillsRoot: userDir,
            queue: BotFeatureAdminSkillMutationQueue(
                ready: { true },
                suppress: { file, action, operationID in
                    queue.suppressObserverMutation(
                        fileName: file, action: action, operationID: operationID)
                },
                clear: { operationID in
                    queue.clearObserverSuppression(operationID: operationID)
                },
                emit: { file, action, requestRecord, appliedRecord in
                    let name = String(file.dropLast(3))
                    let sources = [
                        BotDerivationSource(record: appliedRecord, role: .basis),
                        BotDerivationSource(record: requestRecord, role: .evidence),
                    ]
                    await queue.enqueueAndWait {
                        switch action {
                        case .write:
                            await queue.userWrite(name, sources: sources)
                        case .delete:
                            await queue.userDelete(name, sources: sources)
                        }
                    }
                    return true
                }),
            now: { featureAdminTestNow }, fileVerificationAttempts: 1)

        let content = "# Weekly\n\n- one real UI body\n"
        let begin = result(await recorder.handle(beginBody(content: content)))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let applied = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        XCTAssertEqual(applied["ok"]?.boolValue, true)
        let appliedRecord = try XCTUnwrap(applied["record"]?.stringValue)

        var changed = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 1, "exactly one skill.changed per UI mutation")
        let event = try XCTUnwrap(changed.first)
        XCTAssertEqual(event.data["skill"]?["name"]?.stringValue, "weekly")
        XCTAssertEqual(event.data["skill"]?["revision"]?.intValue, 1)
        let derivation = try XCTUnwrap(event.data["derivation"])
        let sources = try XCTUnwrap(derivation["sources"]?.arrayValue)
        let roles = sources.compactMap { $0["role"]?.stringValue }
        let records = sources.compactMap { $0["record"]?.stringValue }
        XCTAssertTrue(roles.contains("basis"))
        XCTAssertTrue(roles.contains("evidence"))
        XCTAssertTrue(records.contains(appliedRecord))
        XCTAssertTrue(records.contains(requestRecord))
        let basis = sources.first { $0["role"]?.stringValue == "basis" }
        XCTAssertEqual(basis?["record"]?.stringValue, appliedRecord)

        // The observer saw the same file change but the one-shot suppression
        // consumes it instead of appending a second, unsourced event.
        await queue.observeUserWrite("weekly.md")
        changed = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(queue.diagnosticsSnapshot().contains {
            $0.action == "observer-write" && $0.outcome == .skipped
        })

        let state = try await service.currentState(
            forSkill: BotSkillIdentity(name: "weekly"), botID: nil)
        XCTAssertEqual(state.state, .current)
    }

    func testErasingTheRequestRecordInvalidatesTheDerivedSkill() async throws {
        let log = FeatureAdminTestLog()
        let service = BotProvenanceService(
            eventLog: log,
            skillRechecker: BotSkillFileRechecker(roots: roots))
        let producer = BotSkillProvenanceProducer(
            botRoot: "/dsh/workspace/.dshbot/agents/bot-a",
            roots: roots,
            recorder: { try await service.recordSkillWrite($0) },
            latest: { try await service.latestSkillChange(identity: $0) },
            now: { featureAdminTestNow })
        let queue = BotSkillEventQueue(producer: producer, now: { featureAdminTestNow })
        let recorder = BotFeatureAdminSkillMutationRecorder(
            eventLog: log, userSkillsRoot: userDir,
            queue: BotFeatureAdminSkillMutationQueue(
                ready: { true },
                suppress: { file, action, operationID in
                    queue.suppressObserverMutation(
                        fileName: file, action: action, operationID: operationID)
                },
                clear: { operationID in queue.clearObserverSuppression(operationID: operationID) },
                emit: { file, action, requestRecord, appliedRecord in
                    let name = String(file.dropLast(3))
                    let sources = [
                        BotDerivationSource(record: appliedRecord, role: .basis),
                        BotDerivationSource(record: requestRecord, role: .evidence),
                    ]
                    await queue.enqueueAndWait {
                        switch action {
                        case .write: await queue.userWrite(name, sources: sources)
                        case .delete: await queue.userDelete(name, sources: sources)
                        }
                    }
                    return true
                }),
            now: { featureAdminTestNow }, fileVerificationAttempts: 1)

        let begin = result(await recorder.handle(beginBody(content: "body")))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data("body".utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        _ = result(await recorder.handle(.object([
            "op": .string("applied"), "operation_id": .string("op-1"),
        ])))
        let before = try await service.currentState(
            forSkill: BotSkillIdentity(name: "weekly"), botID: nil)
        XCTAssertEqual(before.state, .current)

        let seq = try await log.append(BotEvent(
            type: "erasure", eventId: "erasure-request", time: featureAdminTestNow + 1,
            origin: .local(source: "ipc"), traceId: "trace-erasure",
            principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil, ignorable: nil,
            data: .object([
                "erasedEvents": .array([.object(["record": .string(requestRecord)])]),
            ])))
        XCTAssertGreaterThan(seq, 0)
        let after = try await service.currentState(
            forSkill: BotSkillIdentity(name: "weekly"), botID: nil)
        XCTAssertEqual(after.state, .erased)
    }

    func testOldReaderIgnoresTheUnknownMutationTypeAndRequestedOnly() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let begin = result(await recorder.handle(beginBody(content: "requested only")))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        let snapshot = BotProvenanceSnapshot.build(events: await log.all())
        XCTAssertTrue(snapshot.assertions.isEmpty,
                      "an unknown requested-only event must not become a skill assertion")
        XCTAssertEqual(snapshot.eventFacts[requestRecord]?.recordType,
                       "feature-admin.skill_mutation")
        XCTAssertNil(snapshot.assertions[BotDerivedRef(kind: .skill, id: "weekly")])
    }
}
