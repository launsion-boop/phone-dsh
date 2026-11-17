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
    var failNextSkillChanged = false

    func setFailApplied(_ value: Bool) { failApplied = value }
    func setFailNextSkillChanged(_ value: Bool) { failNextSkillChanged = value }

    func append(_ event: BotEvent) async throws -> Int {
        if failApplied,
           event.type == BotFeatureAdminSkillMutationRecorder.eventType,
           event.data["status"]?.stringValue == "applied" {
            throw TestFailure.appliedAppend
        }
        if failNextSkillChanged, event.type == "skill.changed" {
            failNextSkillChanged = false
            throw TestFailure.skillChangedAppend
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

    enum TestFailure: Error, Sendable { case appliedAppend, skillChangedAppend }
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
                self.lock.lock()
                self.suppressed.append((file, action, operationID))
                self.lock.unlock()
            },
            clear: { [weak self] operationID in
                guard let self else { return }
                self.lock.lock()
                self.cleared.append(operationID)
                self.lock.unlock()
            },
            emit: { [weak self] file, action, request, applied in
                guard let self else { return false }
                self.lock.lock()
                self.emitted.append((file, action, request, applied))
                self.lock.unlock()
                return self.emitResult
            })
    }
}

private struct RealFeatureAdminChain {
    let log: FeatureAdminTestLog
    let service: BotProvenanceService
    let queue: BotSkillEventQueue
    let recorder: BotFeatureAdminSkillMutationRecorder
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

    private func beginRefBody(operationID: String = "op-1",
                              action: String = "write",
                              file: String = "weekly.md",
                              content: String) -> BotJSONValue {
        let data = Data(content.utf8)
        let hash = contentHash(content)
        return .object([
            "op": .string("begin"),
            "operation_id": .string(operationID),
            "action": .string(action),
            "file": .string(file),
            "content_ref": .string("blob://sha256/\(hash)"),
            "content_sha256": .string(hash),
            "bytes": .number(Double(data.count)),
        ])
    }

    private func blobFixture(_ content: String) -> BotFeatureAdminSkillMutationBlob {
        let data = Data(content.utf8)
        let digest = contentHash(content)
        return BotFeatureAdminSkillMutationBlob(read: { requested, expectedBytes in
            requested == digest && expectedBytes == data.count ? data : nil
        })
    }

    private func appliedBody(operationID: String = "op-1") -> BotJSONValue {
        .object(["op": .string("applied"), "operation_id": .string(operationID)])
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

    /// Real provenance service + producer + queue + recorder. The emit closure
    /// returns the producer's actual recorded/failed result, exactly like the
    /// composition seam should.
    private func realChain(_ log: FeatureAdminTestLog,
                           blob: BotFeatureAdminSkillMutationBlob? = nil)
        -> RealFeatureAdminChain {
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
            blob: blob,
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
                    let sources = [
                        BotDerivationSource(record: appliedRecord, role: .basis),
                        BotDerivationSource(record: requestRecord, role: .evidence),
                    ]
                    let emitted = await queue.enqueueAndWaitResult {
                        switch action {
                        case .write:
                            return await queue.userWriteResult(file, sources: sources)
                        case .delete:
                            return await queue.userDeleteResult(file, sources: sources)
                        }
                    }
                    return emitted ?? false
                }),
            now: { featureAdminTestNow }, fileVerificationAttempts: 1)
        return RealFeatureAdminChain(log: log, service: service, queue: queue,
                                     recorder: recorder)
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

    func testDuplicateAppliedAfterSuccessDoesNotReEmit() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        _ = result(await recorder.handle(beginBody(content: "wanted")))
        try Data("wanted".utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let first = result(await recorder.handle(appliedBody()))
        let second = result(await recorder.handle(appliedBody()))
        XCTAssertEqual(first["record"]?.stringValue, second["record"]?.stringValue)
        XCTAssertEqual(first["skill_event"]?.boolValue, true)
        XCTAssertEqual(second["skill_event"]?.boolValue, true)
        let events = await log.all()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(spy.emitted.count, 1,
                       "a completed applied retry must not call the producer again")
    }

    // MARK: - capacity compatibility (2 MiB skill bound)

    func testTwoMebibyteContentRefIsAcceptedAndRecoverable() async throws {
        let log = FeatureAdminTestLog()
        let content = String(repeating: "a", count: 2 * 1024 * 1024)
        let blob = blobFixture(content)
        let chain = realChain(log, blob: blob)
        let begin = result(await chain.recorder.handle(beginRefBody(content: content)))
        XCTAssertEqual(begin["ok"]?.boolValue, true, "\(begin)")
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let applied = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(applied["ok"]?.boolValue, true)
        XCTAssertEqual(applied["skill_event"]?.boolValue, true)

        let events = await log.all()
        let requested = try XCTUnwrap(events.first {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "requested"
        })
        XCTAssertEqual("record://event/\(requested.commitSeq ?? 0)", requestRecord)
        XCTAssertNil(requested.data["content"])
        XCTAssertEqual(requested.data["content_ref"]?.stringValue,
                       "blob://sha256/\(contentHash(content))")
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 1)
        let readback = try XCTUnwrap(blob.read(contentHash(content), content.utf8.count))
        XCTAssertEqual(readback, Data(content.utf8))
    }

    func test64KiBPlusOneContentRefIsAccepted() async throws {
        let log = FeatureAdminTestLog()
        let content = String(repeating: "b", count: 64 * 1024 + 1)
        let chain = realChain(log, blob: blobFixture(content))
        let begin = result(await chain.recorder.handle(beginRefBody(content: content)))
        XCTAssertEqual(begin["ok"]?.boolValue, true, "\(begin)")
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let applied = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(applied["ok"]?.boolValue, true)
        XCTAssertEqual(applied["skill_event"]?.boolValue, true)
        let events = await log.all()
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 1)
    }

    func testTwoMebibyteDeleteContentRefIsRecoverable() async throws {
        let log = FeatureAdminTestLog()
        let content = String(repeating: "d", count: 2 * 1024 * 1024)
        let blob = blobFixture(content)
        let chain = realChain(log, blob: blob)
        _ = result(await chain.recorder.handle(beginRefBody(content: content)))
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let written = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(written["skill_event"]?.boolValue, true)

        let beginDelete = result(await chain.recorder.handle(
            beginRefBody(operationID: "op-2", action: "delete", content: content)))
        XCTAssertEqual(beginDelete["ok"]?.boolValue, true, "\(beginDelete)")
        try FileManager.default.removeItem(at: userDir.appendingPathComponent("weekly.md"))
        let deleted = result(await chain.recorder.handle(appliedBody(operationID: "op-2")))
        XCTAssertEqual(deleted["ok"]?.boolValue, true)
        XCTAssertEqual(deleted["skill_event"]?.boolValue, true)

        let events = await log.all()
        let requested = try XCTUnwrap(events.first {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "requested"
                && $0.data["operation_id"]?.stringValue == "op-2"
        })
        XCTAssertNil(requested.data["content"])
        XCTAssertEqual(requested.data["content_ref"]?.stringValue,
                       "blob://sha256/\(contentHash(content))")
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 2)
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.last?
            .data["action"]?.stringValue, "delete")
        let readback = try XCTUnwrap(blob.read(contentHash(content), content.utf8.count))
        XCTAssertEqual(readback, Data(content.utf8))
    }

    func testTwoMebibytePlusOneIsRejectedBeforeAnyRecordOrFile() async throws {
        let log = FeatureAdminTestLog()
        let spy = FeatureAdminQueueSpy()
        let recorder = recorder(log, queue: spy)
        let content = String(repeating: "x", count: 2 * 1024 * 1024 + 1)
        let reply = result(await recorder.handle(beginRefBody(content: content)))
        XCTAssertEqual(reply["ok"]?.boolValue, false)
        XCTAssertEqual(reply["code"]?.stringValue, "invalid-request")
        let events = await log.all()
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: userDir.appendingPathComponent("weekly.md").path))
    }

    func testAppendOnlyEventCarriesTwoMebibyteRawContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-admin-event-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"),
            now: { featureAdminTestNow })
        let content = String(repeating: "e", count: 2 * 1024 * 1024)
        let event = BotEvent(
            type: BotFeatureAdminSkillMutationRecorder.eventType,
            eventId: "feature-admin-large-content",
            time: featureAdminTestNow,
            origin: .local(source: "user"),
            traceId: "trace-large-content",
            principal: BotPrincipal(botId: nil, sessionId: nil, kind: "ipc"),
            causationId: nil, correlationId: nil, ignorable: true,
            data: .object([
                "schema": .string(BotFeatureAdminSkillMutationRecorder.schema),
                "content": .string(content),
            ]))
        let seq = try await store.append(event)
        XCTAssertGreaterThan(seq, 0)
        let stored = try await store.events(after: 0, limit: 10)
        let first = try XCTUnwrap(stored.first { $0.eventId == event.eventId })
        XCTAssertEqual(first.data["content"]?.stringValue, content)
    }

    // MARK: - real queue + producer idempotency

    func testSameAppliedOperationTwiceUsesOneRawAppliedAndOneSkillChanged() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let content = "# Weekly\n\n- one real body\n"
        let begin = result(await chain.recorder.handle(beginBody(content: content)))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))

        let first = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(first["ok"]?.boolValue, true)
        XCTAssertEqual(first["skill_event"]?.boolValue, true)
        let appliedRecord = try XCTUnwrap(first["record"]?.stringValue)
        let second = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(second["record"]?.stringValue, appliedRecord)
        XCTAssertEqual(second["skill_event"]?.boolValue, true)

        var events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
        }.count, 1)
        var changed = events.filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(changed.first?.data["skill"]?["revision"]?.intValue, 1)

        // Even a rogue second producer call with the same applied operation
        // record must reuse the existing carrier, not revision+1.
        let sources = [
            BotDerivationSource(record: appliedRecord, role: .basis),
            BotDerivationSource(record: requestRecord, role: .evidence),
        ]
        let rogue = await chain.queue.userWriteResult("weekly.md", sources: sources)
        XCTAssertTrue(rogue)
        changed = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 1)
    }

    func testSameDeleteAppliedOperationTwiceUsesOneDeleteCarrier() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let content = "# Weekly\n"
        _ = result(await chain.recorder.handle(beginBody(content: content)))
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let write = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(write["skill_event"]?.boolValue, true)

        let beginDelete = result(await chain.recorder.handle(
            beginBody(operationID: "op-2", action: "delete", content: content)))
        XCTAssertEqual(beginDelete["ok"]?.boolValue, true)
        try FileManager.default.removeItem(at: userDir.appendingPathComponent("weekly.md"))
        let firstDelete = result(await chain.recorder.handle(appliedBody(operationID: "op-2")))
        XCTAssertEqual(firstDelete["ok"]?.boolValue, true)
        XCTAssertEqual(firstDelete["skill_event"]?.boolValue, true)
        let duplicate = result(await chain.recorder.handle(appliedBody(operationID: "op-2")))
        XCTAssertEqual(duplicate["record"]?.stringValue, firstDelete["record"]?.stringValue)
        XCTAssertEqual(duplicate["skill_event"]?.boolValue, true)

        let events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
                && $0.data["operation_id"]?.stringValue == "op-2"
        }.count, 1)
        let changed = events.filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 2)
        let deleted = try XCTUnwrap(changed.last)
        XCTAssertEqual(deleted.data["action"]?.stringValue, "delete")
        XCTAssertEqual(deleted.data["skill"]?["revision"]?.intValue, 2)
    }

    func testFailedSkillEventIsRepairedByOneAppliedRetry() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let content = "# Weekly\n"
        _ = result(await chain.recorder.handle(beginBody(content: content)))
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        await log.setFailNextSkillChanged(true)

        let first = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(first["ok"]?.boolValue, true, "the applied raw fact itself is durable")
        XCTAssertEqual(first["skill_event"]?.boolValue, false,
                       "a caught producer failure must not claim a skill event")
        var events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
        }.count, 1)
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 0)

        let retry = result(await chain.recorder.handle(appliedBody()))
        XCTAssertEqual(retry["ok"]?.boolValue, true)
        XCTAssertEqual(retry["skill_event"]?.boolValue, true)
        events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
        }.count, 1)
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 1)
    }

    func testNewOperationWithSameFileAndBodyCreatesNewRevision() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let content = "# Same body\n"
        for operation in ["op-1", "op-2"] {
            _ = result(await chain.recorder.handle(
                beginBody(operationID: operation, content: content)))
            try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))
            let applied = result(await chain.recorder.handle(appliedBody(operationID: operation)))
            XCTAssertEqual(applied["ok"]?.boolValue, true)
            XCTAssertEqual(applied["skill_event"]?.boolValue, true)
        }
        let events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
        }.count, 2)
        let changed = events.filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 2)
        XCTAssertEqual(changed.compactMap { $0.data["skill"]?["revision"]?.intValue }.sorted(), [1, 2])
    }

    func testRouterReturnsProducerResultAndNoQueueIsFalse() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let router = BotSkillQueueRouter()
        let missing = await router.userWriteAndWait("weekly.md", sources: [])
        XCTAssertFalse(missing)
        router.set(chain.queue)

        let begin = result(await chain.recorder.handle(beginBody(content: "body")))
        let requestRecord = try XCTUnwrap(begin["record"]?.stringValue)
        try Data("body".utf8).write(to: userDir.appendingPathComponent("weekly.md"))
        let sources = [BotDerivationSource(record: requestRecord, role: .basis)]
        await log.setFailNextSkillChanged(true)
        let failed = await router.userWriteAndWait("weekly.md", sources: sources)
        XCTAssertFalse(failed)
        let succeeded = await router.userWriteAndWait("weekly.md", sources: sources)
        XCTAssertTrue(succeeded)
        let changed = await log.all().filter { $0.type == "skill.changed" }
        XCTAssertEqual(changed.count, 1)
    }

    func testConcurrentSameAppliedOperationEmitsAtMostOneSkillChanged() async throws {
        let log = FeatureAdminTestLog()
        let chain = realChain(log)
        let content = "# Weekly\n"
        _ = result(await chain.recorder.handle(beginBody(content: content)))
        try Data(content.utf8).write(to: userDir.appendingPathComponent("weekly.md"))

        async let first = chain.recorder.handle(appliedBody())
        async let second = chain.recorder.handle(appliedBody())
        let replies = [result(await first), result(await second)]
        XCTAssertTrue(replies.contains { $0["ok"]?.boolValue == true })
        let events = await log.all()
        XCTAssertEqual(events.filter {
            $0.type == BotFeatureAdminSkillMutationRecorder.eventType
                && $0.data["status"]?.stringValue == "applied"
        }.count, 1)
        XCTAssertEqual(events.filter { $0.type == "skill.changed" }.count, 1)
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
                    let sources = [
                        BotDerivationSource(record: appliedRecord, role: .basis),
                        BotDerivationSource(record: requestRecord, role: .evidence),
                    ]
                    await queue.enqueueAndWait {
                        switch action {
                        case .write:
                            await queue.userWrite(file, sources: sources)
                        case .delete:
                            await queue.userDelete(file, sources: sources)
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
        let diagnostics = queue.diagnosticsSnapshot()
        XCTAssertFalse(diagnostics.contains {
            $0.action == "user-write" && $0.outcome == .failed
        }, "\(diagnostics)")

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
            forSkill: BotSkillIdentity(name: "weekly"), botID: "bot-a")
        XCTAssertEqual(state.state, .current, "\(state.reasons) sources=\(state.sources)")
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
                    let sources = [
                        BotDerivationSource(record: appliedRecord, role: .basis),
                        BotDerivationSource(record: requestRecord, role: .evidence),
                    ]
                    await queue.enqueueAndWait {
                        switch action {
                        case .write: await queue.userWrite(file, sources: sources)
                        case .delete: await queue.userDelete(file, sources: sources)
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
            forSkill: BotSkillIdentity(name: "weekly"), botID: "bot-a")
        XCTAssertEqual(before.state, .current, "\(before.reasons) sources=\(before.sources)")

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
            forSkill: BotSkillIdentity(name: "weekly"), botID: "bot-a")
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
