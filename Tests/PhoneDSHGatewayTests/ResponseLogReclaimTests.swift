// SPDX-License-Identifier: MIT
// W3 response-log tiering and reclamation. Entries stay replayable from either
// the durable documents tree or Library/Caches; a cache purge is `missing`,
// never a partial or a different response (gateway-security.md §11).

import Foundation
import XCTest
@testable import PhoneDSHGateway

final class ResponseLogReclaimTests: XCTestCase {
    private var root: URL!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-rl-\(UUID().uuidString)", isDirectory: true)
        cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdsh-rl-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        if let cacheRoot { try? FileManager.default.removeItem(at: cacheRoot) }
    }

    private func key(_ seed: String) -> String {
        ResponseLog.cacheKey(method: "POST",
                             url: URL(string: "http://127.0.0.1/v1/\(seed)")!,
                             headers: [:],
                             body: Data(),
                             headerAllowList: [])
    }

    private func commit(_ log: ResponseLog, key: String, body: String) async throws {
        let requestID = UUID().uuidString
        try await log.begin(requestID: requestID, key: key, status: 200,
                            headers: ["content-type": "text/plain"])
        try await log.append(ResponseLogEntry(requestID: requestID, sequence: 0,
                                              body: Data(body.utf8), isFinal: true))
        _ = try await log.finish(requestID: requestID)
    }

    func testRelocatedEntryReplaysFromCachesAfterReopen() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let key = key("move")
        try await commit(log, key: key, body: "body")
        let documents = root.appendingPathComponent("response-log/\(key)", isDirectory: true)
        let caches = cacheRoot.appendingPathComponent("response-log/\(key)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: documents.path))

        let moved = await log.relocateToCache(keys: [key])
        XCTAssertEqual(moved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: documents.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: caches.path))
        let replay = await log.replay(key: key)
        XCTAssertEqual(replay?.body, Data("body".utf8))

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let reopenedReplay = await reopened.replay(key: key)
        XCTAssertEqual(reopenedReplay?.body, Data("body".utf8))
    }

    func testCachePurgeIsMissingNotAnError() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let key = key("purge")
        try await commit(log, key: key, body: "body")
        let moved = await log.relocateToCache(keys: [key])
        XCTAssertEqual(moved, 1)
        try FileManager.default.removeItem(at: cacheRoot)

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let replay = await reopened.replay(key: key)
        XCTAssertNil(replay)
        let receipt = await reopened.receipt(key: key)
        XCTAssertNil(receipt)
        let bytes = await reopened.totalBytes()
        XCTAssertEqual(bytes, 0)
    }

    func testReclaimRefusesAnInFlightResume() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let key = key("resume")
        try await commit(log, key: key, body: "body")
        await log.beginResume(key: key)
        let blocked = await log.reclaim(keys: [key])
        XCTAssertEqual(blocked, 0)
        await log.endResume(key: key)
        let removed = await log.reclaim(keys: [key])
        XCTAssertEqual(removed, 1)
        let replay = await log.replay(key: key)
        XCTAssertNil(replay)
    }

    func testPreW3EntryWithoutBodyLocationStillReadsFromDocuments() async throws {
        let log = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let key = key("legacy")
        try await commit(log, key: key, body: "legacy")
        let metadata = root.appendingPathComponent("response-log/\(key)/entry.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: metadata))
        var dictionary = try XCTUnwrap(object as? [String: Any])
        dictionary.removeValue(forKey: "bodyLocation")
        try JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys])
            .write(to: metadata, options: .atomic)

        let reopened = try ResponseLog(root: root, quotaBytes: 10_000, cacheRoot: cacheRoot)
        let replay = await reopened.replay(key: key)
        XCTAssertEqual(replay?.body, Data("legacy".utf8))
    }
}
