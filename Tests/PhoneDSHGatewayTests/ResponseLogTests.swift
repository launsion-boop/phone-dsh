// SPDX-License-Identifier: MIT
// ResponseLog: content-addressed keys, commit-only visibility, persistence,
// quota eviction and LRU touch semantics.

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class ResponseLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func record(_ log: ResponseLog,
                        key: String,
                        requestID: String = UUID().uuidString,
                        status: Int = 200,
                        headers: [String: String] = ["content-type": "text/plain"],
                        body: Data) async throws {
        try await log.begin(requestID: requestID, key: key, status: status, headers: headers)
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0, body: body, isFinal: true))
        _ = try await log.finish(requestID: requestID)
    }

    private func key(_ seed: String) -> String {
        ResponseLog.cacheKey(method: "POST",
                             url: URL(string: "http://127.0.0.1/v1/\(seed)")!,
                             headers: [:],
                             body: Data(),
                             headerAllowList: [])
    }

    // MARK: - Keys

    func testCacheKeyIsStableForSameRequest() {
        let url = URL(string: "https://api.example.invalid/v1/chat")!
        let headers = ["content-type": "application/json", "accept": "text/event-stream"]
        let first = ResponseLog.cacheKey(method: "post", url: url, headers: headers,
                                         body: Data("{}".utf8),
                                         headerAllowList: ["content-type", "accept"])
        let second = ResponseLog.cacheKey(method: "POST", url: url, headers: headers,
                                          body: Data("{}".utf8),
                                          headerAllowList: ["content-type", "accept"])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertTrue(ResponseLog.isValidKey(first))
    }

    func testCacheKeyMatchesKnownSHA256Vector() {
        // SHA-256 of "GET\nhttp://127.0.0.1/health\n\n".
        let key = ResponseLog.cacheKey(method: "GET",
                                       url: URL(string: "http://127.0.0.1/health")!,
                                       headers: [:],
                                       body: Data(),
                                       headerAllowList: [])
        XCTAssertEqual(key, "d2db8893a1ddbc4d949922dfe5b2b2d1126937f1764c1c402b3cb787c38a2061")
    }

    func testCacheKeyCanonicalizesJSONBody() {
        let url = URL(string: "https://api.example.invalid/v1/chat")!
        let allow: Set<String> = ["content-type"]
        let first = ResponseLog.cacheKey(method: "POST", url: url,
                                         headers: ["content-type": "application/json"],
                                         body: Data(#"{"b":2,"a":1}"#.utf8),
                                         headerAllowList: allow)
        let second = ResponseLog.cacheKey(method: "POST", url: url,
                                          headers: ["content-type": "application/json"],
                                          body: Data(#"{ "a" : 1, "b" : 2 }"#.utf8),
                                          headerAllowList: allow)
        XCTAssertEqual(first, second)
    }

    func testCacheKeyIgnoresVolatileHeaders() {
        let url = URL(string: "https://api.example.invalid/v1/chat")!
        let base = ResponseLog.cacheKey(method: "POST", url: url,
                                        headers: ["content-type": "application/json",
                                                  "authorization": "Bearer a"],
                                        body: Data("{}".utf8),
                                        headerAllowList: ["content-type"])
        let other = ResponseLog.cacheKey(method: "POST", url: url,
                                         headers: ["content-type": "application/json",
                                                   "authorization": "Bearer b",
                                                   "x-request-id": "1"],
                                         body: Data("{}".utf8),
                                         headerAllowList: ["content-type"])
        XCTAssertEqual(base, other)
    }

    func testCacheKeyDistinguishesMethodURLHeaderAndBody() {
        let url = URL(string: "https://api.example.invalid/v1/chat")!
        let allow: Set<String> = ["content-type"]
        let reference = ResponseLog.cacheKey(method: "POST", url: url,
                                             headers: ["content-type": "application/json"],
                                             body: Data(#"{"a":1}"#.utf8),
                                             headerAllowList: allow)
        let differentBody = ResponseLog.cacheKey(method: "POST", url: url,
                                                 headers: ["content-type": "application/json"],
                                                 body: Data(#"{"a":2}"#.utf8),
                                                 headerAllowList: allow)
        let differentMethod = ResponseLog.cacheKey(method: "PUT", url: url,
                                                   headers: ["content-type": "application/json"],
                                                   body: Data(#"{"a":1}"#.utf8),
                                                   headerAllowList: allow)
        let differentHeader = ResponseLog.cacheKey(method: "POST", url: url,
                                                   headers: ["content-type": "text/plain"],
                                                   body: Data(#"{"a":1}"#.utf8),
                                                   headerAllowList: allow)
        let differentURL = ResponseLog.cacheKey(method: "POST",
                                                url: URL(string: "https://api.example.invalid/v1/responses")!,
                                                headers: ["content-type": "application/json"],
                                                body: Data(#"{"a":1}"#.utf8),
                                                headerAllowList: allow)
        XCTAssertNotEqual(reference, differentBody)
        XCTAssertNotEqual(reference, differentMethod)
        XCTAssertNotEqual(reference, differentHeader)
        XCTAssertNotEqual(reference, differentURL)
    }

    // MARK: - Commit visibility

    func testRecordingIsInvisibleUntilFinish() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let requestID = "req-1"
        let cacheKey = key("chat")
        try await log.begin(requestID: requestID, key: cacheKey, status: 200,
                            headers: ["content-type": "application/json"])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: Data("half".utf8)))
        let midStream = await log.replay(key: cacheKey)
        XCTAssertNil(midStream)
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 1,
                                              body: Data("-done".utf8), isFinal: true))
        _ = try await log.finish(requestID: requestID)
        let replay = await log.replay(key: cacheKey)
        XCTAssertEqual(replay?.status, 200)
        XCTAssertEqual(replay?.body, Data("half-done".utf8))
    }

    func testAbortDiscardsRecording() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("aborted")
        try await log.begin(requestID: "req", key: cacheKey, status: 200, headers: [:])
        try await log.append(ResponseLogEntry(requestID: "req", sequence: 0, body: Data("partial".utf8)))
        await log.abort(requestID: "req")
        let replay = await log.replay(key: cacheKey)
        XCTAssertNil(replay)
        let total = await log.totalBytes()
        XCTAssertEqual(total, 0)
    }

    func testSequenceIsEnforced() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        try await log.begin(requestID: "req", key: key("seq"), status: 200, headers: [:])
        do {
            try await log.append(ResponseLogEntry(requestID: "req", sequence: 3, body: Data()))
            XCTFail("out-of-order append must fail")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .invalidSequence(expected: 0, got: 3))
        }
        await log.abort(requestID: "req")
    }

    func testInvalidKeyIsRejected() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        do {
            try await log.begin(requestID: "req", key: "../escape", status: 200, headers: [:])
            XCTFail("a non-hash key must be rejected before touching the filesystem")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .invalidKey)
        }
    }

    func testCommittedLayoutIsUnderKeyDirectory() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("layout")
        try await record(log, key: cacheKey, body: Data("body".utf8))
        let entryDirectory = root.appendingPathComponent("response-log")
            .appendingPathComponent(cacheKey, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory
            .appendingPathComponent("body").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryDirectory
            .appendingPathComponent("entry.json").path))
    }

    // MARK: - Persistence and eviction

    func testReplayPersistsAcrossReopen() async throws {
        let cacheKey = key("persist")
        do {
            let log = try ResponseLog(root: root, quotaBytes: 10_000)
            try await record(log, key: cacheKey, status: 201,
                             headers: ["content-type": "text/plain"],
                             body: Data("persisted".utf8))
        }
        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.status, 201)
        XCTAssertEqual(replay?.body, Data("persisted".utf8))
    }

    func testIndexRebuildsFromEntriesWhenMissing() async throws {
        let cacheKey = key("rebuild")
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        try await record(log, key: cacheKey, body: Data("rebuilt".utf8))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("response-log/index.json"))
        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, Data("rebuilt".utf8))
    }

    /// A failed `index.json` write is observable at runtime and retried by the
    /// next mutation; committed responses stay replayable either way.
    func testIndexWriteFailureIsObservableAndRepairedByNextWrite() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let blocker = root.appendingPathComponent("response-log/index.json.tmp",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let firstKey = key("index-failure")
        try await record(log, key: firstKey, body: Data("committed-anyway".utf8))

        let failed = await log.indexStatus()
        XCTAssertFalse(failed.isPersisted)
        XCTAssertEqual(failed.consecutiveFailures, 1)
        let bodyURL = root.appendingPathComponent("response-log", isDirectory: true)
            .appendingPathComponent(firstKey, isDirectory: true)
            .appendingPathComponent("body", isDirectory: false)
        XCTAssertEqual(try Data(contentsOf: bodyURL), Data("committed-anyway".utf8))

        try FileManager.default.removeItem(at: blocker)
        let secondKey = key("index-retry")
        try await record(log, key: secondKey, body: Data("second".utf8))
        let repaired = await log.indexStatus()
        XCTAssertTrue(repaired.isPersisted)
        XCTAssertEqual(repaired.consecutiveFailures, 0)

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let first = await reopened.replay(key: firstKey)
        let second = await reopened.replay(key: secondKey)
        XCTAssertEqual(first?.body, Data("committed-anyway".utf8))
        XCTAssertEqual(second?.body, Data("second".utf8))
    }

    func testQuotaEvictsLeastRecentlyUsed() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 1_200)
        let first = key("a")
        let second = key("b")
        let third = key("c")
        try await record(log, key: first, body: Data(repeating: 0x61, count: 500))
        try await record(log, key: second, body: Data(repeating: 0x62, count: 500))
        let before = await log.totalBytes()
        XCTAssertEqual(before, 1_000)
        try await record(log, key: third, body: Data(repeating: 0x63, count: 500))
        let after = await log.totalBytes()
        XCTAssertLessThanOrEqual(after, 1_200)
        let evicted = await log.replay(key: first)
        XCTAssertNil(evicted)
        let keptSecond = await log.replay(key: second)
        XCTAssertNotNil(keptSecond)
        let keptThird = await log.replay(key: third)
        XCTAssertNotNil(keptThird)
    }

    func testReplayTouchesLeastRecentlyUsedOrder() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 1_200)
        let first = key("touch-a")
        let second = key("touch-b")
        let third = key("touch-c")
        try await record(log, key: first, body: Data(repeating: 0x61, count: 500))
        try await record(log, key: second, body: Data(repeating: 0x62, count: 500))
        _ = await log.replay(key: first)
        try await record(log, key: third, body: Data(repeating: 0x63, count: 500))
        let keptFirst = await log.replay(key: first)
        XCTAssertNotNil(keptFirst)
        let evictedSecond = await log.replay(key: second)
        XCTAssertNil(evictedSecond)
        let keptThird = await log.replay(key: third)
        XCTAssertNotNil(keptThird)
    }

    func testSingleResponseLargerThanQuotaIsDropped() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 100)
        let cacheKey = key("huge")
        try await record(log, key: cacheKey, body: Data(repeating: 0x78, count: 1000))
        let replay = await log.replay(key: cacheKey)
        XCTAssertNil(replay)
        let total = await log.totalBytes()
        XCTAssertEqual(total, 0)
    }

    /// Eviction at the real default 128 MiB quota, not only a scaled-down
    /// parameter: 33 × 4 MiB committed responses leave exactly the quota worth
    /// of LRU entries.
    func testDefaultQuotaEvictsAtReal128MiBScale() async throws {
        let quota = ModelGatewayConfiguration.defaultResponseLogQuotaBytes
        XCTAssertEqual(quota, 128 * 1024 * 1024)
        let log = try ResponseLog(root: root)
        let bodySize = 4 * 1024 * 1024
        let body = Data(repeating: 0x61, count: bodySize)
        var keys: [String] = []
        for index in 0..<33 {
            let cacheKey = key("scale-\(index)")
            keys.append(cacheKey)
            try await record(log, key: cacheKey, body: body)
        }
        let total = await log.totalBytes()
        XCTAssertEqual(total, quota, "LRU eviction must keep the log within 128 MiB")
        let evicted = await log.replay(key: keys[0])
        XCTAssertNil(evicted)
        let retained = await log.replay(key: keys[32])
        XCTAssertEqual(retained?.body.count, bodySize)
    }

    func testDuplicateRequestIdentifierIsRejected() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        try await log.begin(requestID: "req", key: key("dup"), status: 200, headers: [:])
        do {
            try await log.begin(requestID: "req", key: key("dup"), status: 200, headers: [:])
            XCTFail("duplicate request id must fail")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .duplicateRequest("req"))
        }
        await log.abort(requestID: "req")
    }

    func testRestartDiscardsPendingRecordings() async throws {
        let cacheKey = key("interrupted")
        let first = try ResponseLog(root: root, quotaBytes: 10_000)
        try await first.begin(requestID: "req", key: cacheKey, status: 200, headers: [:])
        try await first.append(ResponseLogEntry(requestID: "req", sequence: 0,
                                                body: Data("never finished".utf8)))
        // Simulate a process kill: the recording is not finished or aborted.

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertNil(replay)
        let pendingDirectory = root.appendingPathComponent("response-log/.pending")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: pendingDirectory.path)
        XCTAssertTrue(leftovers.isEmpty)
    }

    // MARK: - Delivery receipts (G2-FIX-113)

    private func entryMetadata(_ key: String) throws -> [String: Any] {
        let url = root.appendingPathComponent("response-log")
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("entry.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func entryJSON(_ key: String) throws -> URL {
        root.appendingPathComponent("response-log")
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("entry.json", isDirectory: false)
    }

    private func entryBody(_ key: String) throws -> URL {
        root.appendingPathComponent("response-log")
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("body", isDirectory: false)
    }

    private func indexJSON() -> URL {
        root.appendingPathComponent("response-log/index.json", isDirectory: false)
    }

    private func responseLogDirectory() -> URL {
        root.appendingPathComponent("response-log", isDirectory: true)
    }

    private func entryDirectory(_ key: String) -> URL {
        responseLogDirectory().appendingPathComponent(key, isDirectory: true)
    }

    private func replacementContainer() -> URL {
        responseLogDirectory()
            .appendingPathComponent(".replacing", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func stagingContainer() -> URL {
        responseLogDirectory()
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Writes a complete committed entry directly, for crash-boundary tests
    /// that need a staged/installed copy without running `finish`.
    private func writeCommittedEntry(at directory: URL,
                                     key: String,
                                     status: Int = 200,
                                     headers: [String: String] = ["content-type": "text/plain"],
                                     body: Data,
                                     lastUsed: UInt64 = 0,
                                     deliveryCount: Int = 0) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try body.write(to: directory.appendingPathComponent("body", isDirectory: false))
        let metadata: [String: Any] = [
            "key": key,
            "status": status,
            "headers": headers,
            "bodyBytes": body.count,
            "lastUsed": lastUsed,
            "deliveryCount": deliveryCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata,
                                              options: [.sortedKeys])
        try data.write(to: directory.appendingPathComponent("entry.json", isDirectory: false),
                       options: .atomic)
    }

    /// Before the fix `entry.json` was written once with `lastUsed = 0` and
    /// `replay` only rewrote `index.json`; a single entry directory could not
    /// prove that the response had ever been delivered.
    func testEntryFileRecordsReplayDeliveriesAndSurvivesIndexLoss() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("receipt")
        let body = Data("receipt-body".utf8)
        try await record(log, key: cacheKey, status: 201, body: body)

        var entry = try entryMetadata(cacheKey)
        XCTAssertEqual((entry["lastUsed"] as? NSNumber)?.uint64Value, 0,
                       "a freshly committed response has not been used yet")
        XCTAssertEqual((entry["deliveryCount"] as? NSNumber)?.intValue, 0)

        let committedReceiptValue = await log.receipt(key: cacheKey)
        let committedReceipt = try XCTUnwrap(committedReceiptValue)
        XCTAssertEqual(committedReceipt.key, cacheKey)
        XCTAssertEqual(committedReceipt.status, 201)
        XCTAssertEqual(committedReceipt.bodyBytes, body.count)
        XCTAssertEqual(committedReceipt.lastUsed, 0)
        XCTAssertEqual(committedReceipt.deliveryCount, 0)

        let firstReplay = await log.replay(key: cacheKey)
        let secondReplay = await log.replay(key: cacheKey)
        XCTAssertNotNil(firstReplay)
        XCTAssertNotNil(secondReplay)

        entry = try entryMetadata(cacheKey)
        let lastUsed = try XCTUnwrap((entry["lastUsed"] as? NSNumber)?.uint64Value)
        XCTAssertGreaterThan(lastUsed, 0,
                             "replay must rewrite the single entry file")
        XCTAssertEqual((entry["deliveryCount"] as? NSNumber)?.intValue, 2)

        let usedReceiptValue = await log.receipt(key: cacheKey)
        let usedReceipt = try XCTUnwrap(usedReceiptValue)
        XCTAssertEqual(usedReceipt.lastUsed, lastUsed)
        XCTAssertEqual(usedReceipt.deliveryCount, 2)

        // The index is only the LRU cache; dropping it must not lose the
        // delivery facts that live beside the body.
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("response-log/index.json"))
        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let recoveredReceiptValue = await reopened.receipt(key: cacheKey)
        let recoveredReceipt = try XCTUnwrap(recoveredReceiptValue)
        XCTAssertEqual(recoveredReceipt.lastUsed, lastUsed)
        XCTAssertEqual(recoveredReceipt.deliveryCount, 2)
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.status, 201)
        XCTAssertEqual(replay?.body, body)
    }

    func testReceiptRequiresTheCompleteCommittedBody() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("receipt-body")
        try await record(log, key: cacheKey, body: Data("complete".utf8))
        let complete = await log.receipt(key: cacheKey)
        XCTAssertNotNil(complete)

        try FileManager.default.removeItem(at: try entryBody(cacheKey))
        let missingBody = await log.receipt(key: cacheKey)
        XCTAssertNil(missingBody,
                     "a missing body cannot prove a delivered response")

        try Data("short".utf8).write(to: try entryBody(cacheKey))
        let shortBody = await log.receipt(key: cacheKey)
        XCTAssertNil(shortBody,
                     "a body shorter than entry.json says cannot be a receipt")

        try Data("longer-than-the-entry-metadata".utf8).write(to: try entryBody(cacheKey))
        let oversizedBody = await log.receipt(key: cacheKey)
        XCTAssertNil(oversizedBody,
                     "a body longer than entry.json says cannot be a receipt")
    }

    func testPreReceiptEntryFileDecodesDeliveryCountAsZero() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("legacy-receipt")
        try await record(log, key: cacheKey, body: Data("legacy".utf8))

        // Simulate an entry.json written before deliveryCount existed.
        var object = try entryMetadata(cacheKey)
        object.removeValue(forKey: "deliveryCount")
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.sortedKeys])
        try data.write(to: try entryJSON(cacheKey), options: .atomic)

        let receiptValue = await log.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptValue)
        XCTAssertEqual(receipt.deliveryCount, 0)
    }

    /// A process killed after `replay` rewrote `entry.json` but before it
    /// rewrote `index.json` leaves the cached `accessCounter` behind the
    /// entry's `lastUsed`. Restarting must advance the counter from every
    /// entry, otherwise the next replay overwrites the newer entry ordinal
    /// with the stale one.
    func testStaleIndexRestartDoesNotRewindReplayFact() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("stale-index-counter")
        try await record(log, key: cacheKey, body: Data("stale-index".utf8))
        let staleIndex = try Data(contentsOf: indexJSON())

        _ = await log.replay(key: cacheKey)
        _ = await log.replay(key: cacheKey)
        let beforeRestartValue = await log.receipt(key: cacheKey)
        let beforeRestart = try XCTUnwrap(beforeRestartValue)
        XCTAssertEqual(beforeRestart.deliveryCount, 2)
        XCTAssertGreaterThan(beforeRestart.lastUsed, 0)

        // Simulate the crash window: entry.json keeps the two deliveries, but
        // index.json is the snapshot from before the first replay.
        try staleIndex.write(to: indexJSON(), options: .atomic)
        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertNotNil(replay)

        let afterRestartValue = await reopened.receipt(key: cacheKey)
        let afterRestart = try XCTUnwrap(afterRestartValue)
        XCTAssertGreaterThan(afterRestart.lastUsed, beforeRestart.lastUsed,
                             "a stale index counter must not rewind entry.json's lastUsed")
        XCTAssertEqual(afterRestart.deliveryCount, 3)
    }

    /// The same stale index must not hand a fresh commit an ordinal older than
    /// entries already on disk: eviction would then drop the just-committed
    /// response first instead of the genuinely least recently used one.
    func testStaleIndexRestartDoesNotEvictNewCommitFirst() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 800)
        let first = key("stale-index-first")
        try await record(log, key: first, body: Data(repeating: 0x61, count: 500))
        let staleIndex = try Data(contentsOf: indexJSON())

        _ = await log.replay(key: first)
        _ = await log.replay(key: first)
        let usedValue = await log.receipt(key: first)
        let used = try XCTUnwrap(usedValue)
        XCTAssertEqual(used.deliveryCount, 2)
        XCTAssertGreaterThan(used.lastUsed, 0)

        try staleIndex.write(to: indexJSON(), options: .atomic)
        let reopened = try ResponseLog(root: root, quotaBytes: 800)
        let second = key("stale-index-second")
        try await record(reopened, key: second, body: Data(repeating: 0x62, count: 500))

        let firstReplay = await reopened.replay(key: first)
        let secondReplay = await reopened.replay(key: second)
        XCTAssertNil(firstReplay, "the older entry must be evicted first")
        XCTAssertNotNil(secondReplay,
                        "a stale index must not make the fresh commit the eviction victim")

        let secondEntry = try entryMetadata(second)
        XCTAssertEqual((secondEntry["deliveryCount"] as? NSNumber)?.intValue, 1)
    }

    /// A crash after the entry directory rename but before the index write
    /// leaves a fresh commit with `entry.json { lastUsed: 0 }` and no index
    /// record. Restarting must give it a newer ordinal than the entries the
    /// stale index still knows, so the next quota eviction drops the genuinely
    /// older response instead of the just-committed one.
    func testStaleIndexRestartDoesNotEvictUnindexedFreshCommit() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 1_200)
        let old = key("stale-index-old")
        try await record(log, key: old, body: Data(repeating: 0x61, count: 500))
        let staleIndex = try Data(contentsOf: indexJSON())

        // The second commit is renamed into place, but its index write is lost
        // in the simulated crash.
        let fresh = key("stale-index-fresh")
        try await record(log, key: fresh, body: Data(repeating: 0x62, count: 500))
        try staleIndex.write(to: indexJSON(), options: .atomic)

        let reopened = try ResponseLog(root: root, quotaBytes: 1_200)
        let newest = key("stale-index-newest")
        try await record(reopened, key: newest, body: Data(repeating: 0x63, count: 500))

        let oldReplay = await reopened.replay(key: old)
        let freshReplay = await reopened.replay(key: fresh)
        let newestReplay = await reopened.replay(key: newest)
        XCTAssertNil(oldReplay, "the genuinely older entry must be evicted first")
        XCTAssertNotNil(freshReplay,
                        "an unindexed fresh commit must keep a newer ordinal than the stale index knows")
        XCTAssertNotNil(newestReplay)
    }

    /// `finish` returns the commit receipt atomically: `nil` means the entry
    /// was dropped by quota eviction and must not be reported as committed.
    func testFinishReturnsReceiptOnlyWhenTheCommitIsRetained() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 1_000)
        let retainedKey = key("finish-retained")
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: retainedKey, status: 202, headers: [:])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: Data("kept".utf8), isFinal: true))
        let retainedReceipt = try await log.finish(requestID: requestID)
        let retained = try XCTUnwrap(retainedReceipt)
        XCTAssertEqual(retained.key, retainedKey)
        XCTAssertEqual(retained.status, 202)
        XCTAssertEqual(retained.bodyBytes, 4)
        XCTAssertEqual(retained.lastUsed, 0)
        XCTAssertEqual(retained.deliveryCount, 0)

        let oversizedKey = key("finish-dropped")
        let oversizedID = UUID().uuidString
        try await log.begin(requestID: oversizedID, key: oversizedKey, status: 200, headers: [:])
        try await log.append(ResponseLogEntry(requestID: oversizedID, sequence: 0,
                                              body: Data(repeating: 0x78, count: 2_000),
                                              isFinal: true))
        let dropped = try await log.finish(requestID: oversizedID)
        XCTAssertNil(dropped, "a commit larger than the quota is not retained")
    }

    // MARK: - Recoverable same-key replacement

    func testFinishReplacesSameKeyWithOnlyTheNewCommittedEntry() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-finish")
        let oldBody = Data("old-response".utf8)
        let newBody = Data("new-response-body".utf8)
        try await record(log, key: cacheKey, body: oldBody)
        // A marker left by an earlier failed replacement must not survive a
        // later successful replacement of the same key.
        let stale = replacementContainer().appendingPathComponent(cacheKey, isDirectory: true)
        try writeCommittedEntry(at: stale, key: cacheKey, body: Data("stale-backup".utf8))
        try await record(log, key: cacheKey, body: newBody)

        let receiptResult = await log.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, newBody.count)
        XCTAssertEqual(receipt.deliveryCount, 0)
        let replay = await log.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        let total = await log.totalBytes()
        XCTAssertEqual(total, newBody.count)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "a completed replacement leaves no backup")
    }

    /// Crash after the old commit moved aside and before the staged commit was
    /// installed: startup must restore the old committed data and discard the
    /// uninstalled staging copy.
    func testInterruptedReplacementRestoresOldCommitAndDiscardsStaging() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-restore-old")
        let oldBody = Data("old-committed".utf8)
        try await record(log, key: cacheKey, body: oldBody)
        let oldReceiptResult = await log.receipt(key: cacheKey)
        let oldReceipt = try XCTUnwrap(oldReceiptResult)

        let container = replacementContainer()
        let backup = container.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entryDirectory(cacheKey), to: backup)
        let staging = stagingContainer()
        try writeCommittedEntry(at: staging, key: cacheKey, body: Data("staged-new".utf8))

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let receiptResult = await reopened.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, oldBody.count)
        XCTAssertEqual(receipt.lastUsed, oldReceipt.lastUsed,
                       "a restored old commit keeps its own LRU fact")
        XCTAssertEqual(receipt.deliveryCount, oldReceipt.deliveryCount)
        let restoredMetadata = try entryMetadata(cacheKey)
        XCTAssertEqual((restoredMetadata["lastUsed"] as? NSNumber)?.uint64Value, 0,
                       "startup recovery must not rewrite a restored old entry")
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, oldBody.count, "only the restored old commit counts against the quota")
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, oldBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path),
                       "the recovered backup container must not survive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path),
                       "an uninstalled staging copy must be discarded")
    }

    /// Crash after the staged commit was installed and before the old backup
    /// was removed: the installed copy wins and the stale backup is dropped.
    func testInterruptedReplacementKeepsInstalledNewCommit() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-installed-new")
        let oldBody = Data("old-committed".utf8)
        let newBody = Data("new-installed-body".utf8)
        try await record(log, key: cacheKey, body: oldBody)

        let container = replacementContainer()
        let backup = container.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entryDirectory(cacheKey), to: backup)
        try writeCommittedEntry(at: entryDirectory(cacheKey),
                                key: cacheKey,
                                body: newBody,
                                lastUsed: 7,
                                deliveryCount: 1)

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let receiptResult = await reopened.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, newBody.count)
        XCTAssertEqual(receipt.lastUsed, 7)
        XCTAssertEqual(receipt.deliveryCount, 1)
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, newBody.count, "the stale backup must not double-count bytes")
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path),
                       "the stale backup must be removed once the new commit is valid")
    }

    /// A real same-key `finish` keeps the displaced commit in `.replacing`
    /// when its index write fails. The backup is the marker that tells startup
    /// the destination is the new commit, so the stale index's facts are not
    /// merged and the fresh entry gets a new ordinal.
    func testReplacementBackupSurvivesFailedIndexWriteAndRecoversFreshFacts() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-index-failure")
        let oldBody = Data("old-committed".utf8)
        let newBody = Data("new-committed".utf8)
        try await record(log, key: cacheKey, body: oldBody)
        let oldReceiptResult = await log.receipt(key: cacheKey)
        let oldReceipt = try XCTUnwrap(oldReceiptResult)

        let blocker = root.appendingPathComponent("response-log/index.json.tmp",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try await record(log, key: cacheKey, body: newBody)
        let failed = await log.indexStatus()
        XCTAssertFalse(failed.isPersisted)
        XCTAssertEqual(try Data(contentsOf: entryBody(cacheKey)), newBody)
        let containers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(containers.count, 1,
                       "a failed index write must leave the backup as the replacement marker")
        let backup = try XCTUnwrap(containers.first).appendingPathComponent(cacheKey)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("body")), oldBody)

        try FileManager.default.removeItem(at: blocker)
        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let freshResult = await reopened.receipt(key: cacheKey)
        let fresh = try XCTUnwrap(freshResult)
        XCTAssertEqual(fresh.bodyBytes, newBody.count)
        XCTAssertEqual(fresh.deliveryCount, 0,
                       "the installed commit must not inherit the displaced delivery count")
        XCTAssertGreaterThan(fresh.lastUsed, oldReceipt.lastUsed)
        let persistedFresh = try entryMetadata(cacheKey)
        XCTAssertEqual((persistedFresh["lastUsed"] as? NSNumber)?.uint64Value,
                       fresh.lastUsed,
                       "the recovered ordinal must be persisted in entry.json")
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        let deliveredResult = await reopened.receipt(key: cacheKey)
        let delivered = try XCTUnwrap(deliveredResult)
        XCTAssertEqual(delivered.deliveryCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: containers[0].path))
    }

    /// A replacement installed before the index write has a fresh `0/0`
    /// entry, while the stale index still describes the displaced response
    /// with a real LRU ordinal and delivery count. Startup must not copy those
    /// facts onto the new response: it needs a newer ordinal (so quota
    /// eviction keeps it) and its own delivery count (so a replay counts 1).
    func testInterruptedReplacementFreshEntryDoesNotInheritDisplacedIndexFacts() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-fresh-zero")
        let otherKey = key("replace-fresh-zero-other")
        let triggerKey = key("replace-fresh-zero-trigger")
        let oldBody = Data(repeating: 0x6f, count: 12)
        let newBody = Data(repeating: 0x6e, count: 12)
        let otherBody = Data(repeating: 0x74, count: 12)
        try await record(log, key: cacheKey, body: oldBody)
        try await record(log, key: otherKey, body: otherBody)
        _ = await log.replay(key: cacheKey)
        _ = await log.replay(key: otherKey)
        let oldReceiptResult = await log.receipt(key: cacheKey)
        let oldReceipt = try XCTUnwrap(oldReceiptResult)
        let otherReceiptResult = await log.receipt(key: otherKey)
        let otherReceipt = try XCTUnwrap(otherReceiptResult)
        XCTAssertEqual(oldReceipt.deliveryCount, 1)
        XCTAssertGreaterThan(oldReceipt.lastUsed, 0)
        XCTAssertGreaterThan(otherReceipt.lastUsed, oldReceipt.lastUsed)

        // Crash after moving the old commit aside and installing the new one,
        // before `finish` could persist the index.
        let container = replacementContainer()
        let backup = container.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entryDirectory(cacheKey), to: backup)
        try writeCommittedEntry(at: entryDirectory(cacheKey),
                                key: cacheKey,
                                body: newBody,
                                lastUsed: 0,
                                deliveryCount: 0)
        let staging = stagingContainer()
        try writeCommittedEntry(at: staging, key: cacheKey,
                                body: Data("staged-must-not-win".utf8))

        // One entry (12 bytes) fits, two (24) exceed the quota. The stale
        // index would make the new response the LRU victim.
        let reopened = try ResponseLog(root: root, quotaBytes: 23)
        let freshResult = await reopened.receipt(key: cacheKey)
        let fresh = try XCTUnwrap(freshResult)
        XCTAssertEqual(fresh.bodyBytes, newBody.count)
        XCTAssertEqual(fresh.deliveryCount, 0,
                       "a fresh replacement must not inherit the displaced delivery count")
        XCTAssertGreaterThan(fresh.lastUsed, otherReceipt.lastUsed,
                             "a fresh replacement must receive a new LRU ordinal")
        let persistedFresh = try entryMetadata(cacheKey)
        XCTAssertEqual((persistedFresh["lastUsed"] as? NSNumber)?.uint64Value,
                       fresh.lastUsed,
                       "the recovered ordinal must be persisted in entry.json")
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, newBody.count + otherBody.count)

        let triggerID = UUID().uuidString
        try await reopened.begin(requestID: triggerID, key: triggerKey,
                                 status: 200, headers: [:])
        try await reopened.append(ResponseLogEntry(requestID: triggerID,
                                                   sequence: 0,
                                                   body: Data(),
                                                   isFinal: true))
        _ = try await reopened.finish(requestID: triggerID)
        let retainedNew = await reopened.receipt(key: cacheKey)
        XCTAssertNotNil(retainedNew,
                        "the freshly installed replacement must not be quota-evicted first")
        let evictedOther = await reopened.receipt(key: otherKey)
        XCTAssertNil(evictedOther,
                     "the older indexed response is the eviction victim")

        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        let deliveredResult = await reopened.receipt(key: cacheKey)
        let delivered = try XCTUnwrap(deliveredResult)
        XCTAssertEqual(delivered.deliveryCount, 1,
                       "the replacement's first replay is delivery 1, not 2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: container.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// Two restarts with no replay/finish in between must not lose the fresh
    /// ordinal assigned to an installed replacement: the `.replacing` marker
    /// may only be cleared after `entry.json` and `index.json` carry it. If it
    /// is cleared too early, the second start merges the displaced response's
    /// facts from the stale index into the new entry.
    func testInstalledReplacementFactsSurviveTwoConsecutiveRestarts() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-two-restarts")
        let otherKey = key("replace-two-restarts-other")
        let oldBody = Data(repeating: 0x6f, count: 12)
        let newBody = Data(repeating: 0x6e, count: 12)
        let otherBody = Data(repeating: 0x74, count: 12)
        try await record(log, key: cacheKey, body: oldBody)
        try await record(log, key: otherKey, body: otherBody)
        _ = await log.replay(key: cacheKey)
        _ = await log.replay(key: otherKey)
        let otherReceiptResult = await log.receipt(key: otherKey)
        let otherReceipt = try XCTUnwrap(otherReceiptResult)

        // Crash after the old commit moved aside and the new one installed,
        // before `finish` could persist the index.
        let container = replacementContainer()
        let backup = container.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entryDirectory(cacheKey), to: backup)
        try writeCommittedEntry(at: entryDirectory(cacheKey),
                                key: cacheKey,
                                body: newBody,
                                lastUsed: 0,
                                deliveryCount: 0)

        let first = try ResponseLog(root: root, quotaBytes: 23)
        let firstResult = await first.receipt(key: cacheKey)
        let firstReceipt = try XCTUnwrap(firstResult)
        XCTAssertEqual(firstReceipt.deliveryCount, 0)
        XCTAssertGreaterThan(firstReceipt.lastUsed, otherReceipt.lastUsed)
        let persisted = try entryMetadata(cacheKey)
        XCTAssertEqual((persisted["lastUsed"] as? NSNumber)?.uint64Value,
                       firstReceipt.lastUsed,
                       "startup recovery must persist the fresh ordinal")
        let markersAfterFirst = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(markersAfterFirst.isEmpty,
                      "a durable corrected index releases the replacement marker")

        // No replay and no `finish` between the two starts.
        let second = try ResponseLog(root: root, quotaBytes: 23)
        let secondResult = await second.receipt(key: cacheKey)
        let secondReceipt = try XCTUnwrap(secondResult)
        XCTAssertEqual(secondReceipt.lastUsed, firstReceipt.lastUsed,
                       "the second restart must not reassign or inherit an ordinal")
        XCTAssertEqual(secondReceipt.deliveryCount, 0,
                       "the second restart must not inherit the displaced delivery count")

        let replay = await second.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        let deliveredResult = await second.receipt(key: cacheKey)
        let delivered = try XCTUnwrap(deliveredResult)
        XCTAssertEqual(delivered.deliveryCount, 1,
                       "the replacement's first replay is delivery 1, not 2")
        XCTAssertGreaterThan(delivered.lastUsed, secondReceipt.lastUsed)
    }

    /// If startup recovery cannot persist the corrected index, it must keep
    /// the `.replacing` marker so the next restart repeats the correction
    /// instead of merging the displaced facts after the marker is gone.
    func testRecoveryIndexWriteFailureKeepsReplacementMarkerForNextRestart() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-recovery-index-failure")
        let otherKey = key("replace-recovery-index-failure-other")
        let oldBody = Data(repeating: 0x6f, count: 12)
        let newBody = Data(repeating: 0x6e, count: 12)
        let otherBody = Data(repeating: 0x74, count: 12)
        try await record(log, key: cacheKey, body: oldBody)
        try await record(log, key: otherKey, body: otherBody)
        _ = await log.replay(key: cacheKey)
        _ = await log.replay(key: otherKey)
        let otherReceiptResult = await log.receipt(key: otherKey)
        let otherReceipt = try XCTUnwrap(otherReceiptResult)

        let container = replacementContainer()
        let backup = container.appendingPathComponent(cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: container,
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: entryDirectory(cacheKey), to: backup)
        try writeCommittedEntry(at: entryDirectory(cacheKey),
                                key: cacheKey,
                                body: newBody,
                                lastUsed: 0,
                                deliveryCount: 0)

        let blocker = root.appendingPathComponent("response-log/index.json.tmp",
                                                  isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        let first = try ResponseLog(root: root, quotaBytes: 10_000)
        let firstResult = await first.receipt(key: cacheKey)
        let firstReceipt = try XCTUnwrap(firstResult)
        XCTAssertGreaterThan(firstReceipt.lastUsed, otherReceipt.lastUsed)
        XCTAssertEqual(firstReceipt.deliveryCount, 0)
        let markers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertFalse(markers.isEmpty,
                       "a failed recovery index write must keep the replacement marker")

        try FileManager.default.removeItem(at: blocker)
        let second = try ResponseLog(root: root, quotaBytes: 10_000)
        let secondResult = await second.receipt(key: cacheKey)
        let secondReceipt = try XCTUnwrap(secondResult)
        XCTAssertEqual(secondReceipt.lastUsed, firstReceipt.lastUsed)
        XCTAssertEqual(secondReceipt.deliveryCount, 0,
                       "the retried recovery must not inherit the displaced delivery count")
        let replay = await second.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody)
        let deliveredResult = await second.receipt(key: cacheKey)
        let delivered = try XCTUnwrap(deliveredResult)
        XCTAssertEqual(delivered.deliveryCount, 1)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty,
                      "the marker is released once the retried index write succeeds")
    }

    /// Several backups for one key can only come from repeated interrupted
    /// replacements. Recovery must choose the newest valid one by a
    /// deterministic order, remove the others, and count only the restored
    /// body once against the quota.
    func testMultipleReplacementBackupsRestoreNewestWithoutDoubleCounting() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-multiple-backups")
        let oldBody = Data("older-backup".utf8)
        let newBody = Data("newer-backup".utf8)
        try await record(log, key: cacheKey, body: oldBody)

        // The live destination is gone; only two backups of the same key
        // remain. Directory enumeration order must not decide the winner.
        try FileManager.default.removeItem(at: entryDirectory(cacheKey))
        let older = replacementContainer().appendingPathComponent(cacheKey, isDirectory: true)
        let newer = replacementContainer().appendingPathComponent(cacheKey, isDirectory: true)
        try writeCommittedEntry(at: older, key: cacheKey, body: oldBody,
                                lastUsed: 1, deliveryCount: 0)
        try writeCommittedEntry(at: newer, key: cacheKey, body: newBody,
                                lastUsed: 2, deliveryCount: 1)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: older.deletingLastPathComponent().path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: newer.deletingLastPathComponent().path)

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let receiptResult = await reopened.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, newBody.count)
        XCTAssertEqual(receipt.lastUsed, 2)
        XCTAssertEqual(receipt.deliveryCount, 1)
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, newBody.count,
                       "only the one restored backup may count against the quota")
        let replay = await reopened.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, newBody,
                       "the newest backup, not the directory-order winner, is restored")
        let containers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(containers.isEmpty, "the stale backups are removed after recovery")
    }

    /// A stale backup left for a key that is later evicted must be removed
    /// with the live directory. Otherwise restart recovery would move the old
    /// response back and count its bytes again, possibly above the quota.
    func testEvictionRemovesStaleReplacementBackupsWithoutResurrection() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 800)
        let oldKey = key("evict-stale-backup-old")
        let newKey = key("evict-stale-backup-new")
        try await record(log, key: oldKey, body: Data(repeating: 0x61, count: 500))

        // Simulate two stale markers left by earlier failed replacements while
        // the old committed directory is still live.
        for (index, byte) in [UInt8(0x62), UInt8(0x63)].enumerated() {
            let stale = replacementContainer().appendingPathComponent(oldKey, isDirectory: true)
            try writeCommittedEntry(at: stale, key: oldKey,
                                    body: Data(repeating: byte, count: 500),
                                    lastUsed: UInt64(index + 1),
                                    deliveryCount: 0)
        }

        // The second 500-byte commit exceeds the 800-byte quota and evicts the
        // older key (lastUsed 1 versus the new commit's 2).
        try await record(log, key: newKey, body: Data(repeating: 0x64, count: 500))
        let oldReceipt = await log.receipt(key: oldKey)
        XCTAssertNil(oldReceipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory(oldKey).path))
        let containers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(containers.isEmpty,
                      "eviction must clear every stale backup for the victim key")

        let reopened = try ResponseLog(root: root, quotaBytes: 800)
        let resurrected = await reopened.receipt(key: oldKey)
        XCTAssertNil(resurrected,
                     "an evicted response must not return from a stale backup")
        let newReplay = await reopened.replay(key: newKey)
        XCTAssertNotNil(newReplay)
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, 500)
        XCTAssertLessThanOrEqual(total, 800)
    }

    /// If a stale backup cannot be removed, skip that victim and continue to a
    /// removable LRU entry; deleting its live destination would let startup
    /// recovery resurrect the backup above quota.
    func testEvictionSkipsAKeyWithUndeletableReplacementBackup() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 600)
        let oldKey = key("evict-stale-backup-unwritable")
        let otherKey = key("evict-stale-backup-unwritable-other")
        let newKey = key("evict-stale-backup-unwritable-new")
        let oldBody = Data(repeating: 0x61, count: 200)
        try await record(log, key: oldKey, body: oldBody)
        try await record(log, key: otherKey, body: Data(repeating: 0x63, count: 200))

        let container = replacementContainer()
        let stale = container.appendingPathComponent(oldKey, isDirectory: true)
        try writeCommittedEntry(at: stale, key: oldKey, body: Data(repeating: 0x62, count: 200))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)
        }

        // 200 + 200 + 300 crosses quota. The oldest key is blocked by its
        // undeletable marker, so eviction must continue to the next LRU key.
        try await record(log, key: newKey, body: Data(repeating: 0x64, count: 300))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: container.path)

        let reopened = try ResponseLog(root: root, quotaBytes: 600)
        let oldReplay = await reopened.replay(key: oldKey)
        XCTAssertEqual(oldReplay?.body, oldBody,
                       "the stale backup must not replace the live committed response")
        let otherReceipt = await reopened.receipt(key: otherKey)
        XCTAssertNil(otherReceipt, "eviction must continue to the next removable LRU entry")
        let newReplay = await reopened.replay(key: newKey)
        XCTAssertNotNil(newReplay)
        let total = await reopened.totalBytes()
        XCTAssertEqual(total, 500)
        XCTAssertLessThanOrEqual(total, 600)
    }

    /// Rollback cannot remove an unusable destination: the backup in
    /// `.replacing` is the only committed copy and must survive for startup
    /// recovery instead of being deleted because `destination` still exists.
    func testReplacementDestinationRemovalFailureKeepsBackupForStartupRecovery() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-remove-destination-failure")
        let oldBody = Data("old-committed".utf8)
        let newBody = Data("new-rejected".utf8)
        try await record(log, key: cacheKey, body: oldBody)
        let destination = entryDirectory(cacheKey)

        await log.setReplacementInstallProbeForTesting {
            // Simulate a failed install that left an unusable destination.
            try FileManager.default.createDirectory(at: destination,
                                                    withIntermediateDirectories: true)
            throw ResponseLogError.ioFailure
        }
        await log.setReplacementRestoreProbeForTesting { step in
            if step == .removeUnusableDestination {
                throw ResponseLogError.ioFailure
            }
        }
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: cacheKey, status: 200, headers: [:])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: newBody, isFinal: true))
        do {
            _ = try await log.finish(requestID: requestID)
            XCTFail("the injected rollback failure must be reported")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .ioFailure)
        }
        await log.setReplacementInstallProbeForTesting(nil)
        await log.setReplacementRestoreProbeForTesting(nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let unusableReceipt = await log.receipt(key: cacheKey)
        XCTAssertNil(unusableReceipt,
                     "the unusable destination is not a committed receipt")
        let containers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(containers.count, 1)
        let backup = try XCTUnwrap(containers.first).appendingPathComponent(cacheKey)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("body")),
                       oldBody,
                       "the backup must not be deleted when destination removal failed")

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let receiptResult = await reopened.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, oldBody.count)
        let totalAfterRecovery = await reopened.totalBytes()
        XCTAssertEqual(totalAfterRecovery, oldBody.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: containers[0].path),
                       "startup recovery must remove the recovered backup container")
    }

    /// Rollback cleared the failed destination but the restore move failed:
    /// keep the backup for startup instead of deleting `.replacing` because a
    /// destination path happens to exist.
    func testReplacementRestoreMoveFailureKeepsBackupForStartupRecovery() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-restore-move-failure")
        let oldBody = Data("old-committed".utf8)
        let newBody = Data("new-rejected".utf8)
        try await record(log, key: cacheKey, body: oldBody)

        await log.setReplacementInstallProbeForTesting {
            throw ResponseLogError.ioFailure
        }
        await log.setReplacementRestoreProbeForTesting { step in
            if step == .restoreBackup {
                throw ResponseLogError.ioFailure
            }
        }
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: cacheKey, status: 200, headers: [:])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: newBody, isFinal: true))
        do {
            _ = try await log.finish(requestID: requestID)
            XCTFail("the injected restore failure must be reported")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .ioFailure)
        }
        await log.setReplacementInstallProbeForTesting(nil)
        await log.setReplacementRestoreProbeForTesting(nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory(cacheKey).path))
        let containers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertEqual(containers.count, 1)
        let backup = try XCTUnwrap(containers.first).appendingPathComponent(cacheKey)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("body")),
                       oldBody,
                       "the backup must survive a failed restore move")

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000)
        let receiptResult = await reopened.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, oldBody.count)
        let totalAfterRecovery = await reopened.totalBytes()
        XCTAssertEqual(totalAfterRecovery, oldBody.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: containers[0].path),
                       "startup recovery must remove the recovered backup container")
    }

    /// A runtime failure between the backup move and the install must put the
    /// old commit back and report no receipt for the failed replacement.
    func testFailedReplacementInstallRestoresOldCommit() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("replace-install-failure")
        let oldBody = Data("old-committed".utf8)
        let newBody = Data("new-rejected".utf8)
        try await record(log, key: cacheKey, body: oldBody)

        await log.setReplacementInstallProbeForTesting {
            throw ResponseLogError.ioFailure
        }
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: cacheKey, status: 200, headers: [:])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: newBody, isFinal: true))
        do {
            _ = try await log.finish(requestID: requestID)
            XCTFail("the injected install failure must be reported")
        } catch {
            XCTAssertEqual(error as? ResponseLogError, .ioFailure)
        }
        await log.setReplacementInstallProbeForTesting(nil)

        let receiptResult = await log.receipt(key: cacheKey)
        let receipt = try XCTUnwrap(receiptResult)
        XCTAssertEqual(receipt.bodyBytes, oldBody.count,
                       "a failed replacement must not expose a partial receipt")
        XCTAssertEqual(receipt.deliveryCount, 0)
        let total = await log.totalBytes()
        XCTAssertEqual(total, oldBody.count)
        let replay = await log.replay(key: cacheKey)
        XCTAssertEqual(replay?.body, oldBody)
        XCTAssertNotEqual(replay?.body, newBody)
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: responseLogDirectory().appendingPathComponent(".replacing", isDirectory: true),
            includingPropertiesForKeys: nil)
        XCTAssertTrue(leftovers.isEmpty, "the restored backup container must be removed")
    }

    // MARK: - Resume offset accounting

    func testResumeOffsetOutOfRangeDoesNotCountADelivery() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000)
        let cacheKey = key("resume-offset")
        let body = Data("0123456789".utf8)
        try await record(log, key: cacheKey, body: body)
        let beforeResult = await log.receipt(key: cacheKey)
        let before = try XCTUnwrap(beforeResult)
        XCTAssertEqual(before.deliveryCount, 0)
        XCTAssertEqual(before.lastUsed, 0)

        let rejected = await log.replay(key: cacheKey, offset: body.count + 1)
        guard case .offsetOutOfRange(let bodyBytes) = rejected else {
            XCTFail("an offset past the committed body must be rejected")
            return
        }
        XCTAssertEqual(bodyBytes, body.count)
        let afterRejectionResult = await log.receipt(key: cacheKey)
        let afterRejection = try XCTUnwrap(afterRejectionResult)
        XCTAssertEqual(afterRejection.deliveryCount, before.deliveryCount,
                       "a rejected resume must not count as a delivery")
        XCTAssertEqual(afterRejection.lastUsed, before.lastUsed)

        let accepted = await log.replay(key: cacheKey, offset: 4)
        guard case .replay(let replay) = accepted else {
            XCTFail("an in-range offset is served from the committed body")
            return
        }
        XCTAssertEqual(replay.body, body)
        let afterAcceptanceResult = await log.receipt(key: cacheKey)
        let afterAcceptance = try XCTUnwrap(afterAcceptanceResult)
        XCTAssertEqual(afterAcceptance.deliveryCount, 1)
        XCTAssertGreaterThan(afterAcceptance.lastUsed, 0)
    }
}
