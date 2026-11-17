// SPDX-License-Identifier: MIT
// External admission journal (P06, spec/host/v1/external-admission.md, revision
// external-admission-v1). Every section of the shared vector file
// spec/host/v1/fixtures/external-admission-v1.json runs through the production
// decoder, policy functions and the real on-disk journal. A crash is modelled
// by dropping the actor and opening a new one on the same directory.

import XCTest
import ProbeKit

final class ExternalAdmissionJournalTests: XCTestCase {
    private var root: URL!
    private var fixture: [String: Any] = [:]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-admission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try Data(contentsOf: contractURL("fixtures/external-admission-v1.json"))
        fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fixture["revision"] as? String, "external-admission-v1")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Identity, content, limits

    func testLimitsMatchTheContract() throws {
        let limits = try XCTUnwrap(fixture["limits"] as? [String: Any])
        XCTAssertEqual(limits.count, 9)
        XCTAssertEqual(int(limits["maxTextBytes"]), Int64(ExternalAdmissionLimits.maxTextBytes))
        XCTAssertEqual(int(limits["minTtlMs"]), ExternalAdmissionLimits.minTtlMs)
        XCTAssertEqual(int(limits["maxTtlMs"]), ExternalAdmissionLimits.maxTtlMs)
        XCTAssertEqual(int(limits["maxPending"]), Int64(ExternalAdmissionLimits.maxPending))
        XCTAssertEqual(int(limits["maxEntries"]), Int64(ExternalAdmissionLimits.maxEntries))
        XCTAssertEqual(int(limits["maxAttempts"]), Int64(ExternalAdmissionLimits.maxAttempts))
        XCTAssertEqual(int(limits["tombstoneMs"]), ExternalAdmissionLimits.tombstoneMs)
        XCTAssertEqual(int(limits["linkedTimeoutMs"]), ExternalAdmissionLimits.linkedTimeoutMs)
        XCTAssertEqual(int(limits["passLimit"]), Int64(ExternalAdmissionLimits.passLimit))
    }

    func testIdentityVectors() throws {
        let cases = try section("ids")
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for item in cases {
            let source = try decode(ExternalAdmissionSource.self, item["source"])
            XCTAssertEqual(
                ExternalAdmissionPolicy.admissionId(
                    principal: try string(item["principal"]), source: source,
                    sourceRequestId: try string(item["sourceRequestId"])),
                try string(item["admissionId"]))
        }
    }

    func testContentHashVectors() throws {
        let cases = try section("content")
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            XCTAssertEqual(ExternalAdmissionPolicy.contentSha256(try string(item["text"])),
                           try string(item["contentSha256"]))
        }
    }

    /// PC-20261116-external-admission §2.1: the voice request builder yields the frozen
    /// identity of the first vector (board name hash, one id for request and downstream).
    func testTonoLinkVoiceRequestMatchesTheFirstVector() async throws {
        let first = try XCTUnwrap(try section("ids").first)
        let requestID = try string(first["sourceRequestId"])
        let nowMs: Int64 = 1_794_700_000_000
        let request = ExternalAdmissionRequest.tonoLinkVoice(
            boardName: "PhoneAgent-7356", requestID: requestID,
            target: .dshSession(sessionId: "gb-main"), text: "现在几点了？", nowMs: nowMs)
        XCTAssertEqual(request.principal, "local")
        XCTAssertEqual(request.downstreamId, requestID)
        XCTAssertEqual(request.expiresAtMs, nowMs + 86_400_000)
        let journal = freshJournal()
        let outcome = await journal.admit(request, nowMs: nowMs)
        XCTAssertEqual(outcome.result, .admitted)
        XCTAssertEqual(outcome.receipt?.admissionId, try string(first["admissionId"]))
        let golden = try goldenInstance("admission-record-admitted.json")
        let written = try JSONSerialization.jsonObject(
            with: Data(contentsOf: file(try string(first["admissionId"]))))
        XCTAssertEqual(written as? NSDictionary, golden as NSDictionary,
                       "the journal writes exactly the admitted golden")
    }

    // MARK: - Records

    func testValidRecordsDecodeAndReencode() throws {
        let valid = try records("valid")
        XCTAssertFalse(valid.isEmpty)
        for item in valid {
            let raw = try XCTUnwrap(item["record"] as? [String: Any])
            try assertRoundTrip(raw, name: try string(item["id"]))
        }
    }

    func testGoldensDecodeAndReencode() throws {
        for name in ["admission-record-admitted.json", "admission-record-dispatching-retry.json",
                     "admission-record-linked.json", "admission-record-completed.json",
                     "admission-record-expired-bot.json"] {
            try assertRoundTrip(try goldenInstance(name), name: name)
        }
    }

    func testInvalidRecordsAreRejectedByTheDecoder() throws {
        let invalid = try records("invalid")
        var kinds = Set<String>()
        for item in invalid {
            kinds.insert(try string(item["by"]))
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["record"]))
            XCTAssertThrowsError(try JSONDecoder().decode(ExternalAdmissionRecord.self, from: data),
                                 "\(item["id"] ?? "?") must not decode")
        }
        XCTAssertEqual(kinds, ["schema", "identity"])
    }

    /// The same invalid records as files: left untouched, counted, never dispatched or deleted.
    func testInvalidRecordFilesAreOpaqueToTheJournal() async throws {
        let invalid = try records("invalid")
        let directory = freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL: Data] = [:]
        for (index, item) in invalid.enumerated() {
            let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(item["record"]),
                                                  options: [.sortedKeys])
            // Distinct, well-formed names: several vectors share one admissionId.
            let url = directory.appendingPathComponent(String(format: "%064x.json", index + 1))
            try data.write(to: url)
            written[url] = data
        }
        let journal = ExternalAdmissionJournal(directory: directory)
        let farFuture: Int64 = 1_900_000_000_000
        let counts = await journal.counts(nowMs: farFuture)
        XCTAssertEqual(counts.undecodable, invalid.count)
        XCTAssertEqual(counts.entries, invalid.count)
        XCTAssertEqual(counts.pending, 0)
        let pass = await journal.beginPass(nowMs: farFuture)
        XCTAssertTrue(pass.isEmpty)
        for (url, data) in written {
            XCTAssertEqual(try Data(contentsOf: url), data, "\(url.lastPathComponent) was touched")
        }
    }

    // MARK: - Admission

    func testAdmissionDecisionsAgainstARealJournal() async throws {
        let cases = try section("admit")
        var seen = Set<String>()
        for item in cases {
            let id = try string(item["id"])
            let now = try XCTUnwrap(int(item["now"]))
            let expected = try string(item["result"])
            seen.insert(expected)
            let directory = freshDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let existing = (item["existing"] as? [[String: Any]]) ?? []
            var before: [String: Data] = [:]
            var pending = 0
            for record in existing {
                let name = try string(record["admissionId"])
                before[name] = try seed(record, in: directory)
                if ["admitted", "dispatching"].contains(try string(record["stage"])) { pending += 1 }
            }
            // `pendingCount` / `directoryEntries` are made true with real files: real
            // pending records, then entries this version does not interpret.
            var entries = existing.count
            if let wanted = int(item["pendingCount"]) {
                var filler = 0
                while pending < Int(wanted) {
                    try seedPending(index: filler, nowMs: now, in: directory)
                    filler += 1; pending += 1; entries += 1
                }
            }
            if let wanted = int(item["directoryEntries"]) {
                var filler = 0
                while entries < Int(wanted) {
                    try Data("x".utf8).write(to: directory.appendingPathComponent("foreign-\(filler)"))
                    filler += 1; entries += 1
                }
            }
            let journal = ExternalAdmissionJournal(directory: directory)
            let rawRequest = try XCTUnwrap(item["request"] as? [String: Any])
            guard let request = try typedRequest(rawRequest) else {
                // The production decoder refused the request's source or target.
                XCTAssertEqual(expected, "invalid", id)
                continue
            }
            let outcome = await journal.admit(request, nowMs: now)
            XCTAssertEqual(outcome.result.rawValue, expected, id)
            let admissionId = ExternalAdmissionPolicy.admissionId(
                principal: request.principal, source: request.source,
                sourceRequestId: request.sourceRequestId)
            let url = directory.appendingPathComponent("\(admissionId).json")
            switch outcome.result {
            case .admitted:
                let receipt = try XCTUnwrap(outcome.receipt, id)
                XCTAssertEqual(receipt.admissionId, admissionId, id)
                XCTAssertEqual(receipt.downstreamId, request.downstreamId, id)
                XCTAssertEqual(receipt.stage, .admitted, id)
                let stored = try JSONDecoder().decode(ExternalAdmissionRecord.self,
                                                      from: Data(contentsOf: url))
                XCTAssertEqual(stored.stage, .admitted, id)
                XCTAssertEqual(stored.attempts, 0, id)
                XCTAssertEqual(stored.text, request.text, id)
                XCTAssertEqual(stored.admittedAtMs, now, id)
                XCTAssertEqual(stored.target, request.target, id)
                let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
                XCTAssertEqual((mode as? NSNumber)?.intValue, 0o600, id)
            case .duplicate:
                let receipt = try XCTUnwrap(outcome.receipt, id)
                let held = try XCTUnwrap(existing.first { ($0["admissionId"] as? String) == admissionId })
                XCTAssertEqual(receipt.downstreamId, try string(held["downstreamId"]), id)
                XCTAssertEqual(receipt.stage.rawValue, try string(held["stage"]), id)
                XCTAssertEqual(try Data(contentsOf: url), before[admissionId], id)
            case .conflict:
                XCTAssertNil(outcome.receipt, id)
                XCTAssertEqual(try Data(contentsOf: url), before[admissionId],
                               "\(id): the existing record is never overwritten")
            case .capacity, .invalid, .storage:
                XCTAssertNil(outcome.receipt, id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), id)
            }
        }
        XCTAssertEqual(seen, ["admitted", "duplicate", "conflict", "capacity", "invalid"])
    }

    func testAFailedWriteIsStorageAndLeavesNoReceipt() async throws {
        let directory = freshDirectory()
        let journal = ExternalAdmissionJournal(directory: directory) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        let outcome = await journal.admit(voiceRequest("a"), nowMs: Self.now)
        XCTAssertEqual(outcome.result, .storage)
        XCTAssertNil(outcome.receipt)
        let counts = await journal.counts(nowMs: Self.now)
        XCTAssertEqual(counts.entries, 0)
    }

    // MARK: - Stages

    func testTransitionTableThroughTheJournal() async throws {
        let cases = try section("transitions")
        XCTAssertEqual(cases.count, 64)
        var pairs = Set<String>()
        let nowMs = Self.now + 1_000
        for item in cases {
            let from = try XCTUnwrap(ExternalAdmissionStage(rawValue: try string(item["from"])))
            let to = try XCTUnwrap(ExternalAdmissionStage(rawValue: try string(item["to"])))
            let allowed = try XCTUnwrap(item["allowed"] as? Bool)
            pairs.insert("\(from.rawValue)>\(to.rawValue)")
            XCTAssertEqual(ExternalAdmissionPolicy.allows(from: from, to: to), allowed,
                           "\(from) → \(to)")
            let directory = freshDirectory()
            let seeded = template(stage: from)
            let before = try seed(seeded, in: directory)
            let journal = ExternalAdmissionJournal(directory: directory)
            var succeeded = false
            do {
                _ = try await journal.transition(seeded.admissionId, to: to,
                                                 reason: "test_reason", nowMs: nowMs)
                succeeded = true
            } catch let error as ExternalAdmissionError {
                XCTAssertEqual(error, .illegalTransition(from: from, to: to))
            }
            XCTAssertEqual(succeeded, allowed, "\(from) → \(to)")
            // A new process reads what the transition left behind with the real decoder.
            let reopened = await ExternalAdmissionJournal(directory: directory)
                .record(admissionId: seeded.admissionId, nowMs: nowMs)
            let stored = try XCTUnwrap(reopened, "\(from) → \(to)")
            if allowed {
                XCTAssertEqual(stored.stage, to)
                XCTAssertEqual(stored.downstreamId, seeded.downstreamId)
                XCTAssertEqual(stored.target, seeded.target)
                XCTAssertEqual(stored.text == nil, !to.isPending,
                               "text leaves with the pending stages")
                if to.isTerminal { XCTAssertEqual(stored.settledAtMs, nowMs) }
                if to == .linked { XCTAssertEqual(stored.linkedAtMs, nowMs) }
            } else {
                XCTAssertEqual(try Data(contentsOf: file(seeded.admissionId, in: directory)),
                               before, "a refused edge writes nothing")
            }
        }
        XCTAssertEqual(pairs.count, 64)
    }

    func testRetryVectors() async throws {
        let cases = try section("retry")
        var stages = Set<String>()
        for item in cases {
            let attempts = Int(try XCTUnwrap(int(item["attempts"])))
            let now = try XCTUnwrap(int(item["now"]))
            let result = try XCTUnwrap(item["result"] as? [String: Any])
            let stage = try string(result["stage"])
            stages.insert(stage)
            switch ExternalAdmissionPolicy.retry(attempts: attempts, nowMs: now) {
            case let .retry(next, nextAttemptAtMs):
                XCTAssertEqual(stage, "admitted")
                XCTAssertEqual(Int64(next), int(result["attempts"]))
                XCTAssertEqual(nextAttemptAtMs, int(result["nextAttemptAtMs"]))
            case .exhausted:
                XCTAssertEqual(stage, "failed")
                XCTAssertEqual(try string(result["reason"]), ExternalAdmissionPolicy.retryExhaustedReason)
            }
            // The same law through a stored `dispatching` record.
            let directory = freshDirectory()
            var seeded = template(stage: .dispatching)
            seeded.attempts = attempts
            seeded.admittedAtMs = now - 10
            seeded.expiresAtMs = now + 3_600_000
            try seed(seeded, in: directory)
            let journal = ExternalAdmissionJournal(directory: directory)
            let after = try await journal.recordDispatchFailure(
                seeded.admissionId, error: "downstream_unavailable", nowMs: now)
            XCTAssertEqual(after.stage.rawValue, stage)
            XCTAssertEqual(after.downstreamId, seeded.downstreamId, "a retry never mints a new id")
            if stage == "admitted" {
                XCTAssertEqual(Int64(after.attempts), int(result["attempts"]))
                XCTAssertEqual(after.nextAttemptAtMs, int(result["nextAttemptAtMs"]))
                XCTAssertEqual(after.lastError, "downstream_unavailable")
                XCTAssertEqual(after.text, seeded.text)
            } else {
                XCTAssertEqual(after.reason, try string(result["reason"]))
                XCTAssertNil(after.text)
                XCTAssertEqual(after.settledAtMs, now)
            }
        }
        XCTAssertEqual(stages, ["admitted", "failed"])
    }

    // MARK: - Sweep and order

    func testSweepVectorsAtOpen() async throws {
        let cases = try section("sweep")
        var actions = Set<String>()
        for item in cases {
            let id = try string(item["id"])
            let now = try XCTUnwrap(int(item["now"]))
            let action = try string(item["action"])
            actions.insert(action)
            let raw = try XCTUnwrap(item["record"] as? [String: Any])
            let record = try decode(ExternalAdmissionRecord.self, raw)
            XCTAssertEqual(ExternalAdmissionPolicy.sweepAction(for: record, nowMs: now).rawValue,
                           action, id)
            let directory = freshDirectory()
            let before = try seed(raw, in: directory)
            let url = file(record.admissionId, in: directory)
            // Opening the journal is what sweeps.
            let stored = await ExternalAdmissionJournal(directory: directory)
                .record(admissionId: record.admissionId, nowMs: now)
            switch action {
            case "keep":
                XCTAssertEqual(stored, record, id)
                XCTAssertEqual(try Data(contentsOf: url), before, id)
            case "expire":
                XCTAssertEqual(stored?.stage, .expired, id)
                XCTAssertEqual(stored?.settledAtMs, now, id)
                XCTAssertEqual(stored?.reason, "expired", id)
                XCTAssertNil(stored?.text, id)
                XCTAssertEqual(stored?.downstreamId, record.downstreamId, id)
            case "unknown":
                XCTAssertEqual(stored?.stage, .unknown, id)
                XCTAssertEqual(stored?.settledAtMs, now, id)
            case "delete":
                XCTAssertNil(stored, id)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), id)
            default:
                XCTFail("unknown sweep action in \(id)")
            }
        }
        XCTAssertEqual(actions, ["keep", "expire", "delete", "unknown"])
    }

    func testDispatchOrderVectors() throws {
        let cases = try section("order")
        XCTAssertFalse(cases.isEmpty)
        for item in cases {
            let now = try XCTUnwrap(int(item["now"]))
            let candidates = try XCTUnwrap(item["records"] as? [[String: Any]]).map { raw in
                ExternalAdmissionDispatchCandidate(
                    admissionId: try string(raw["admissionId"]),
                    stage: try XCTUnwrap(ExternalAdmissionStage(rawValue: try string(raw["stage"]))),
                    admittedAtMs: try XCTUnwrap(int(raw["admittedAtMs"])),
                    expiresAtMs: try XCTUnwrap(int(raw["expiresAtMs"])),
                    nextAttemptAtMs: int(raw["nextAttemptAtMs"]))
            }
            let caseID = try string(item["id"])
            XCTAssertEqual(
                ExternalAdmissionPolicy.dispatchOrder(candidates, nowMs: now).map(\.admissionId),
                try XCTUnwrap(item["dispatch"] as? [String]), caseID)
        }
    }

    /// The journal's own pass uses that order on stored records: FIFO by admission time
    /// then id, sixteen per pass, backoff skipped, `linked` and terminal never returned.
    func testPassOrderOnStoredRecords() async throws {
        let directory = freshDirectory()
        var expected: [(Int64, String)] = []
        for index in 0..<19 {
            var record = template(stage: .admitted, request: "order-\(index)")
            record.admittedAtMs = Self.now + Int64((index * 7) % 5)
            try seed(record, in: directory)
            expected.append((record.admittedAtMs, record.admissionId))
        }
        var backingOff = template(stage: .admitted, request: "order-backoff")
        backingOff.admittedAtMs = Self.now - 5
        backingOff.attempts = 1
        backingOff.nextAttemptAtMs = Self.now + 60_000
        try seed(backingOff, in: directory)
        var linked = template(stage: .linked, request: "order-linked")
        linked.admittedAtMs = Self.now - 5
        try seed(linked, in: directory)
        expected.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        let journal = ExternalAdmissionJournal(directory: directory)
        let pass = await journal.beginPass(nowMs: Self.now + 100)
        XCTAssertEqual(pass.count, 16)
        XCTAssertEqual(pass.map(\.admissionId), expected.prefix(16).map(\.1))
    }

    // MARK: - Crash points (PC-20261116-external-admission §4)

    /// 1. Before the write: nothing durable, no receipt; the source redelivers and is admitted once.
    func testCrashBeforeTheWrite() async throws {
        let directory = freshDirectory()
        let request = voiceRequest("crash-1")
        let dying = ExternalAdmissionJournal(directory: directory) { data, url in
            // The process dies after the temporary file and before the rename.
            let temp = url.deletingLastPathComponent()
                .appendingPathComponent(".\(url.lastPathComponent).tmp.dead")
            try data.write(to: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        let lost = await dying.admit(request, nowMs: Self.now)
        XCTAssertEqual(lost.result, .storage)
        XCTAssertNil(lost.receipt, "no receipt, so the source keeps the request")

        let reopened = ExternalAdmissionJournal(directory: directory)
        let recordsAfterCrash = await reopened.allRecords(nowMs: Self.now + 1)
        XCTAssertTrue(recordsAfterCrash.isEmpty, "a half write is not a record")
        let emptyPass = await reopened.beginPass(nowMs: Self.now + 1)
        XCTAssertTrue(emptyPass.isEmpty)
        let again = await reopened.admit(request, nowMs: Self.now + 2)
        XCTAssertEqual(again.result, .admitted)
        XCTAssertEqual(again.receipt?.downstreamId, request.downstreamId)
        let stored = await reopened.allRecords(nowMs: Self.now + 2)
        XCTAssertEqual(stored.count, 1)
        // The leftover temporary file is left alone and only costs one directory slot.
        let counts = await reopened.counts(nowMs: Self.now + 2)
        XCTAssertEqual(counts.undecodable, 1)
        XCTAssertEqual(counts.entries, 2)
    }

    /// 2. After the write, before dispatch: the record is found and dispatched once.
    func testCrashAfterTheWriteBeforeDispatch() async throws {
        let directory = freshDirectory()
        let request = voiceRequest("crash-2")
        let first = await ExternalAdmissionJournal(directory: directory).admit(request, nowMs: Self.now)
        XCTAssertEqual(first.result, .admitted)

        let reopened = ExternalAdmissionJournal(directory: directory)
        let pass = await reopened.beginPass(nowMs: Self.now + 10)
        XCTAssertEqual(pass.map(\.admissionId), [try XCTUnwrap(first.receipt).admissionId])
        XCTAssertEqual(pass.first?.stage, .admitted)
        XCTAssertEqual(pass.first?.downstreamId, request.downstreamId)
        XCTAssertEqual(pass.first?.text, request.text)
        let redelivery = await reopened.admit(request, nowMs: Self.now + 11)
        XCTAssertEqual(redelivery.result, .duplicate)
        XCTAssertEqual(redelivery.receipt?.downstreamId, request.downstreamId)
        let all = await reopened.allRecords(nowMs: Self.now + 11)
        XCTAssertEqual(all.count, 1)
    }

    /// 3. `dispatching` unconfirmed: no proof either way. It is redone with the same
    /// `downstreamId`, never expired, cancelled or re-admitted; the outbox de-duplicates.
    func testCrashWhileDispatchingIsRedoneWithTheSameDownstreamId() async throws {
        let directory = freshDirectory()
        let outboxDirectory = root.appendingPathComponent("send-outbox-\(UUID().uuidString)")
        let request = voiceRequest("crash-3")
        let admissionId = ExternalAdmissionPolicy.admissionId(
            principal: request.principal, source: request.source,
            sourceRequestId: request.sourceRequestId)
        do {
            let journal = ExternalAdmissionJournal(directory: directory)
            _ = await journal.admit(request, nowMs: Self.now)
            let live = try await journal.beginDispatch(admissionId, nowMs: Self.now + 5)
            XCTAssertEqual(live?.stage, .dispatching)
            // The downstream write landed, then the process died before `linked`.
            _ = try await SendOutbox(directory: outboxDirectory).enqueue(
                sessionID: "gb-main", text: request.text, rpcId: request.downstreamId)
        }
        // Long after the TTL: a `dispatching` record is still kept and still redone.
        let later = Self.now + 30 * 86_400_000
        let reopened = ExternalAdmissionJournal(directory: directory)
        let pass = await reopened.beginPass(nowMs: later)
        XCTAssertEqual(pass.map(\.admissionId), [admissionId])
        let redo = try await reopened.beginDispatch(admissionId, nowMs: later)
        XCTAssertEqual(redo?.stage, .dispatching)
        XCTAssertEqual(redo?.downstreamId, request.downstreamId)
        XCTAssertEqual(redo?.attempts, 0, "a recovered record is not an attempt")
        XCTAssertEqual(redo?.text, request.text)
        for illegal in [ExternalAdmissionStage.expired, .cancelled] {
            do {
                _ = try await reopened.transition(admissionId, to: illegal, nowMs: later)
                XCTFail("dispatching → \(illegal) must not exist")
            } catch let error as ExternalAdmissionError {
                XCTAssertEqual(error, .illegalTransition(from: .dispatching, to: illegal))
            }
        }
        // The redo meets the entry the first attempt left: same rpcId, still one entry.
        let outbox = SendOutbox(directory: outboxDirectory)
        let held = await outbox.entry(rpcId: request.downstreamId)
        XCTAssertEqual(held?.text, request.text)
        do {
            _ = try await outbox.enqueue(sessionID: "gb-main", text: request.text,
                                         rpcId: request.downstreamId)
            XCTFail("the outbox must refuse a second entry for the same rpcId")
        } catch { }
        let entries = await outbox.entries()
        XCTAssertEqual(entries.map(\.rpcId), [request.downstreamId])
        let linked = try await reopened.markLinked(admissionId, nowMs: later + 1)
        XCTAssertEqual(linked.stage, .linked)
        let redelivery = await reopened.admit(request, nowMs: later + 2)
        XCTAssertEqual(redelivery.result, .invalid,
                       "a redelivery whose own deadline has passed is refused before dedupe")
        let fresh = ExternalAdmissionRequest(
            principal: request.principal, source: request.source,
            sourceRequestId: request.sourceRequestId, target: request.target,
            text: request.text, downstreamId: UUID().uuidString.lowercased(),
            expiresAtMs: later + 60_000)
        let duplicate = await reopened.admit(fresh, nowMs: later + 2)
        XCTAssertEqual(duplicate.result, .duplicate)
        XCTAssertEqual(duplicate.receipt?.downstreamId, request.downstreamId)
    }

    /// 4. `linked`, not settled: the downstream owner has it. Never dispatched again,
    /// never deleted by sweep, still the dedupe record.
    func testCrashAfterLinkedBeforeSettlement() async throws {
        let directory = freshDirectory()
        let request = voiceRequest("crash-4")
        let admissionId = ExternalAdmissionPolicy.admissionId(
            principal: request.principal, source: request.source,
            sourceRequestId: request.sourceRequestId)
        do {
            let journal = ExternalAdmissionJournal(directory: directory)
            _ = await journal.admit(request, nowMs: Self.now)
            _ = try await journal.beginDispatch(admissionId, nowMs: Self.now + 5)
            _ = try await journal.markLinked(admissionId, nowMs: Self.now + 9)
        }
        let afterTtl = Self.now + 2 * 86_400_000
        let reopened = ExternalAdmissionJournal(directory: directory)
        let pass = await reopened.beginPass(nowMs: afterTtl)
        XCTAssertTrue(pass.isEmpty, "a linked record is never dispatched again")
        let stored = await reopened.record(admissionId: admissionId, nowMs: afterTtl)
        XCTAssertEqual(stored?.stage, .linked)
        XCTAssertEqual(stored?.downstreamId, request.downstreamId)
        XCTAssertEqual(stored?.linkedAtMs, Self.now + 9)
        XCTAssertNil(stored?.text)
        let noDispatch = try await reopened.beginDispatch(admissionId, nowMs: afterTtl)
        XCTAssertNil(noDispatch)
        let linked = await reopened.linkedRecords(nowMs: afterTtl)
        XCTAssertEqual(linked.map(\.admissionId), [admissionId])
        let completed = try await reopened.complete(admissionId, nowMs: afterTtl + 1)
        XCTAssertEqual(completed.stage, .completed)
        XCTAssertEqual(completed.downstreamId, request.downstreamId)
    }

    /// 5. Terminal, not yet swept: the tombstone still answers a redelivery as a
    /// duplicate, is never dispatched, and is deleted only at its limit.
    func testCrashAfterTerminalBeforeSweep() async throws {
        let directory = freshDirectory()
        let request = voiceRequest("crash-5")
        let admissionId = ExternalAdmissionPolicy.admissionId(
            principal: request.principal, source: request.source,
            sourceRequestId: request.sourceRequestId)
        let settledAt = Self.now + 20
        do {
            let journal = ExternalAdmissionJournal(directory: directory)
            _ = await journal.admit(request, nowMs: Self.now)
            _ = try await journal.beginDispatch(admissionId, nowMs: Self.now + 5)
            _ = try await journal.markLinked(admissionId, nowMs: Self.now + 9)
            _ = try await journal.complete(admissionId, nowMs: settledAt)
        }
        let reopened = ExternalAdmissionJournal(directory: directory)
        let pass = await reopened.beginPass(nowMs: Self.now + 1_000)
        XCTAssertTrue(pass.isEmpty)
        let redelivery = await reopened.admit(request, nowMs: Self.now + 1_000)
        XCTAssertEqual(redelivery.result, .duplicate)
        XCTAssertEqual(redelivery.receipt?.stage, .completed)
        XCTAssertEqual(redelivery.receipt?.downstreamId, request.downstreamId)
        // limit = max(expiresAtMs, settledAtMs + 24 h) = settledAtMs + 24 h here.
        let limit = settledAt + 86_400_000
        let justBefore = await ExternalAdmissionJournal(directory: directory)
            .record(admissionId: admissionId, nowMs: limit - 1)
        XCTAssertEqual(justBefore?.stage, .completed)
        let atLimit = await ExternalAdmissionJournal(directory: directory)
            .record(admissionId: admissionId, nowMs: limit)
        XCTAssertNil(atLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file(admissionId, in: directory).path))
    }

    // MARK: - Undecodable and newer-version files

    func testUndecodableAndNewerVersionFilesAreLeftUntouched() async throws {
        let directory = freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A newer version of a record this build would otherwise accept and dispatch.
        var newer = try goldenInstance("admission-record-admitted.json")
        newer["v"] = 2
        newer["priority"] = "high"
        let newerId = try string(newer["admissionId"])
        let newerData = try seed(newer, in: directory)
        let corruptURL = directory.appendingPathComponent(String(repeating: "ab", count: 32) + ".json")
        let corruptData = Data("{\"v\":1,\"admissionId\":".utf8)
        try corruptData.write(to: corruptURL)
        let healthy = voiceRequest("beside-opaque")

        let journal = ExternalAdmissionJournal(directory: directory)
        let far: Int64 = Self.now + 400 * 86_400_000
        let admitted = await journal.admit(healthy, nowMs: Self.now)
        XCTAssertEqual(admitted.result, .admitted)
        var counts = await journal.counts(nowMs: Self.now)
        XCTAssertEqual(counts.undecodable, 2)
        XCTAssertEqual(counts.entries, 3, "undecodable files count toward the directory bound")
        XCTAssertEqual(counts.pending, 1)
        let pass = await journal.beginPass(nowMs: Self.now + 1)
        XCTAssertEqual(pass.map(\.downstreamId), [healthy.downstreamId],
                       "an undecodable file is never dispatched")
        // The source of the newer-version record redelivers: no receipt, nothing overwritten.
        let redelivery = await journal.admit(
            ExternalAdmissionRequest.tonoLinkVoice(
                boardName: "PhoneAgent-7356", requestID: try string(newer["sourceRequestId"]),
                target: .dshSession(sessionId: "gb-main"), text: "现在几点了？", nowMs: Self.now),
            nowMs: Self.now)
        XCTAssertEqual(redelivery.result, .storage)
        XCTAssertNil(redelivery.receipt)
        do {
            _ = try await journal.transition(newerId, to: .dispatching, nowMs: Self.now)
            XCTFail("an undecodable file has no stage to move")
        } catch let error as ExternalAdmissionError {
            XCTAssertEqual(error, .unknownRecord)
        }
        // Sweeps far in the future, in this process and in a new one.
        _ = await journal.beginPass(nowMs: far)
        let reopened = ExternalAdmissionJournal(directory: directory)
        _ = await reopened.beginPass(nowMs: far)
        counts = await reopened.counts(nowMs: far)
        XCTAssertEqual(counts.undecodable, 2)
        XCTAssertEqual(try Data(contentsOf: file(newerId, in: directory)), newerData)
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptData)
    }

    func testWithdrawForADeletedTarget() async throws {
        let directory = freshDirectory()
        let journal = ExternalAdmissionJournal(directory: directory)
        func bot(_ name: String) -> ExternalAdmissionRequest {
            ExternalAdmissionRequest.tonoLinkVoice(
                boardName: "PhoneAgent-7356", requestID: UUID().uuidString.lowercased(),
                target: .bot(botId: "bot-7f3a"), text: name, nowMs: Self.now)
        }
        let waiting = await journal.admit(bot("waiting"), nowMs: Self.now)
        let inFlight = await journal.admit(bot("in flight"), nowMs: Self.now)
        let handed = await journal.admit(bot("handed over"), nowMs: Self.now)
        let other = await journal.admit(voiceRequest("other target"), nowMs: Self.now)
        let inFlightId = try XCTUnwrap(inFlight.receipt).admissionId
        let handedId = try XCTUnwrap(handed.receipt).admissionId
        _ = try await journal.beginDispatch(inFlightId, nowMs: Self.now + 1)
        _ = try await journal.beginDispatch(handedId, nowMs: Self.now + 1)
        _ = try await journal.markLinked(handedId, nowMs: Self.now + 2)
        _ = await journal.withdraw(target: .bot(botId: "bot-7f3a"), nowMs: Self.now + 3)
        let reopened = ExternalAdmissionJournal(directory: directory)
        let a = await reopened.record(admissionId: try XCTUnwrap(waiting.receipt).admissionId, nowMs: Self.now + 4)
        XCTAssertEqual(a?.stage, .cancelled)
        XCTAssertNil(a?.text)
        let b = await reopened.record(admissionId: inFlightId, nowMs: Self.now + 4)
        XCTAssertEqual(b?.stage, .failed)
        XCTAssertEqual(b?.reason, "target_missing")
        let c = await reopened.record(admissionId: handedId, nowMs: Self.now + 4)
        XCTAssertEqual(c?.stage, .linked)
        let d = await reopened.record(admissionId: try XCTUnwrap(other.receipt).admissionId, nowMs: Self.now + 4)
        XCTAssertEqual(d?.stage, .admitted)
    }

    // MARK: - Helpers

    private static let now: Int64 = 1_794_700_000_000

    private func contractURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent() // PhoneDSHSimTests
            .deletingLastPathComponent() // probe-app
            .deletingLastPathComponent() // examples
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("spec/host/v1")
            .appendingPathComponent(relative)
    }

    private func goldenInstance(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: contractURL("golden/\(name)"))
        let wrapper = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(wrapper["instance"] as? [String: Any])
    }

    private func section(_ name: String) throws -> [[String: Any]] {
        try XCTUnwrap(fixture[name] as? [[String: Any]], "fixture section \(name)")
    }

    private func records(_ name: String) throws -> [[String: Any]] {
        let all = try XCTUnwrap(fixture["records"] as? [String: Any])
        return try XCTUnwrap(all[name] as? [[String: Any]])
    }

    private func string(_ value: Any?) throws -> String {
        try XCTUnwrap(value as? String)
    }

    private func int(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.int64Value
    }

    private func decode<T: Decodable>(_ type: T.Type, _ value: Any?) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value))
        return try JSONDecoder().decode(type, from: data)
    }

    private func assertRoundTrip(_ raw: [String: Any], name: String) throws {
        let record = try decode(ExternalAdmissionRecord.self, raw)
        XCTAssertNil(record.validationProblem(), name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let again = try JSONSerialization.jsonObject(with: try encoder.encode(record))
        XCTAssertEqual(again as? NSDictionary, raw as NSDictionary, name)
    }

    /// The fixture request through the production decoders; nil when one refuses it.
    private func typedRequest(_ raw: [String: Any]) throws -> ExternalAdmissionRequest? {
        guard let source = try? decode(ExternalAdmissionSource.self, raw["source"]),
              let target = try? decode(ExternalAdmissionTarget.self, raw["target"]) else {
            return nil
        }
        let text: String
        if let repeated = raw["textRepeat"] as? [String: Any] {
            text = String(repeating: try string(repeated["unit"]),
                          count: Int(try XCTUnwrap(int(repeated["count"]))))
        } else {
            text = try string(raw["text"])
        }
        return ExternalAdmissionRequest(
            principal: try string(raw["principal"]), source: source,
            sourceRequestId: try string(raw["sourceRequestId"]), target: target, text: text,
            downstreamId: try string(raw["downstreamId"]),
            expiresAtMs: try XCTUnwrap(int(raw["expiresAtMs"])))
    }

    private func freshDirectory() -> URL {
        root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("admissions", isDirectory: true)
    }

    private func freshJournal() -> ExternalAdmissionJournal {
        ExternalAdmissionJournal(directory: root.appendingPathComponent("admissions",
                                                                         isDirectory: true))
    }

    private func file(_ admissionId: String) -> URL {
        root.appendingPathComponent("admissions").appendingPathComponent("\(admissionId).json")
    }

    private func file(_ admissionId: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(admissionId).json")
    }

    /// Writes a record file exactly as given, the way an earlier process left it.
    @discardableResult
    private func seed(_ raw: [String: Any], in directory: URL) throws -> Data {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        try data.write(to: file(try string(raw["admissionId"]), in: directory))
        return data
    }

    @discardableResult
    private func seed(_ record: ExternalAdmissionRecord, in directory: URL) throws -> Data {
        XCTAssertNil(record.validationProblem())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        try data.write(to: file(record.admissionId, in: directory))
        return data
    }

    private func seedPending(index: Int, nowMs: Int64, in directory: URL) throws {
        let request = ExternalAdmissionRequest(
            principal: "local",
            source: ExternalAdmissionSource(kind: .cloudTask, id: "filler-device"),
            sourceRequestId: "filler-\(index)", target: .dshSession(sessionId: "gb-main"),
            text: "filler", downstreamId: UUID().uuidString.lowercased(),
            expiresAtMs: nowMs + 3_600_000)
        let record = try XCTUnwrap(ExternalAdmissionPolicy.candidate(for: request, nowMs: nowMs))
        try seed(record, in: directory)
    }

    private func voiceRequest(_ text: String) -> ExternalAdmissionRequest {
        ExternalAdmissionRequest.tonoLinkVoice(
            boardName: "PhoneAgent-7356", requestID: UUID().uuidString.lowercased(),
            target: .dshSession(sessionId: "gb-main"), text: text, nowMs: Self.now)
    }

    /// A valid stored record at any stage, built by the production types.
    private func template(stage: ExternalAdmissionStage,
                          request: String = "template") -> ExternalAdmissionRecord {
        let source = ExternalAdmissionSource(kind: .cloudTask, id: "dev-template")
        var record = ExternalAdmissionRecord(
            admissionId: ExternalAdmissionPolicy.admissionId(
                principal: "account:u_18f3", source: source, sourceRequestId: request),
            principal: "account:u_18f3", source: source, sourceRequestId: request,
            target: .bot(botId: "bot-7f3a"),
            contentSha256: ExternalAdmissionPolicy.contentSha256("整理今天的会议纪要"),
            text: nil, downstreamId: "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d",
            admittedAtMs: Self.now, expiresAtMs: Self.now + 86_400_000,
            stage: stage, attempts: 0)
        if stage.isPending {
            record.text = "整理今天的会议纪要"
        } else {
            record.linkedAtMs = Self.now + 400
            if stage.isTerminal { record.settledAtMs = Self.now + 500 }
        }
        return record
    }
}
