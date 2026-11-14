// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHBot
import XCTest
@testable import PhoneDSHProbe

final class BotProjectionReadCacheTests: XCTestCase {
    func testProductionWatchSharesRebuildAndKeepsCursorAfterIdleCacheExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.v4.jsonl")
        try record(1).write(to: url)
        // Explicit staging URLs remain authoritative even if another staged
        // session file is newer in the same directory.
        let unrelated = directory.appendingPathComponent("session.v5.jsonl")
        try record(50, text: "unrelated").write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: unrelated.path)
        let domain = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"))
        let environment = BotProductionEnvironment(
            domain: domain, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: domain)),
            memory: BotMemory(store: SQLiteBotMemoryDocumentStore(eventLog: domain, botID: "main"), botID: "main"),
            grants: BotGrantStore(domainStore: domain), sessionLogURL: url, workspaceRoot: directory)
        let service = BotProductionRowService(environment: environment)
        let batches = try await withThrowingTaskGroup(of: BotRowBatch.self) { group in
            for _ in 0..<8 { group.addTask { try await service.watch(after: 0) } }
            var batches: [BotRowBatch] = []
            for try await batch in group { batches.append(batch) }
            return batches
        }
        XCTAssertEqual(batches.count, 8)
        XCTAssertTrue(batches.allSatisfy { $0.rows.count == 1 && $0.rows.first?.body["text"] == .string("answer") })
        let rebuilds = await service.projectionRebuildCount
        XCTAssertEqual(rebuilds, 1)
        var cursor = try XCTUnwrap(batches.first?.cursor)
        for _ in 0..<10 { _ = try await service.watch(after: cursor) }
        let idleRebuilds = await service.projectionRebuildCount
        XCTAssertEqual(idleRebuilds, 1)
        let progress: PhoneDSHBot.BotJSONValue = .object(["card": .object([
            "cardType": .string("progress"), "cardKey": .string("progress"),
            "title": .string("New progress"), "percent": .number(20), "state": .string("running")])])
        _ = try await domain.append(BotEvent(type: "card.presented", eventId: "new-card", time: 2,
            origin: .local(source: "card-bridge"), traceId: "trace",
            principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
            causationId: nil, correlationId: nil, data: progress))
        let parked = directory.appendingPathComponent("parked.jsonl")
        try FileManager.default.moveItem(at: url, to: parked)
        do {
            _ = try await service.watch(after: cursor)
            XCTFail("a missing live log must preserve history and report a read failure")
        } catch {}
        // Same inode, bytes and mtime: only the retained dirty flag can notice
        // the already-consumed domain event on the retry.
        try FileManager.default.moveItem(at: parked, to: url)
        let recovered = try await service.watch(after: cursor)
        XCTAssertEqual(recovered.rows.first?.body.cardType, .progress)
        cursor = recovered.cursor
        try await Task.sleep(for: .milliseconds(5_200))
        let afterExpiry = try await service.watch(after: cursor)
        XCTAssertEqual(afterExpiry.cursor, cursor)
        XCTAssertFalse(afterExpiry.reset)
        XCTAssertTrue(afterExpiry.rows.isEmpty)
        try append(record(2, text: "new answer"), to: url)
        let update = try await service.watch(after: cursor)
        XCTAssertEqual(update.rows.count, 1)
        XCTAssertGreaterThan(update.cursor, cursor)
        try await domain.close()
    }

    func testUnlistableSessionDirectoryFailsTheReadWithoutClearingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionDirectory = directory
            .appendingPathComponent("materialized/home/sessions/main", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let url = sessionDirectory.appendingPathComponent("session.v1.jsonl")
        try record(1).write(to: url)
        let domain = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"))
        let environment = BotProductionEnvironment(
            domain: domain, botID: "main", sessionID: "main",
            routineMachine: RoutineMachine(store: SQLiteRoutineStore(domainStore: domain)),
            memory: BotMemory(store: SQLiteBotMemoryDocumentStore(eventLog: domain, botID: "main"), botID: "main"),
            grants: BotGrantStore(domainStore: domain), sessionLogURL: url, workspaceRoot: directory)
        let service = BotProductionRowService(environment: environment)
        let first = try await service.watch(after: 0)
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertEqual(first.rows.first?.body["text"], .string("answer"))
        // Removing the whole session directory makes the rotation listing
        // fail while the retained URL still names the file. That is a read
        // failure: it must not silently delete the painted history rows.
        try FileManager.default.removeItem(at: sessionDirectory)
        do {
            _ = try await service.watch(after: first.cursor)
            XCTFail("an unlistable session directory must report a read failure, not clear history")
        } catch {}
        // The log returns: the next watch re-reads it whole and reports the
        // appended row on top of the retained history.
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try record(1).write(to: url)
        try append(record(2, text: "after recovery"), to: url)
        let recovered = try await service.watch(after: first.cursor)
        XCTAssertEqual(recovered.rows.count, 1)
        XCTAssertEqual(recovered.rows.first?.body["text"], .string("after recovery"))
        try await domain.close()
    }

    private func record(_ seq: Int, text: String = "answer") throws -> Data {
        let event = BotDSHSessionEvent(type: "assistant/message", seq: seq, time: Int64(seq),
            data: ["message": .object(["role": .string("assistant"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])])])])
        var data = try JSONEncoder().encode(event)
        data.append(0x0A)
        return data
    }

    private func append(_ data: Data, to url: URL) throws {
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }

    func testIdleReadsNoBytesAndAppendDecodesOnlyNewLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var data = Data()
        for seq in 0..<2_000 { data.append(try record(seq)) }
        try data.write(to: url)
        var cache = BotSessionLogReadCache()
        XCTAssertTrue(try cache.refresh(url))
        let bytes = cache.bytesRead
        let lines = cache.decodedLines
        for _ in 0..<100 { XCTAssertFalse(try cache.refresh(url)) }
        XCTAssertEqual(cache.bytesRead, bytes)
        XCTAssertEqual(cache.decodedLines, lines)
        let addition = try record(2_000, text: "中🙂")
        try append(addition, to: url); data.append(addition)
        XCTAssertTrue(try cache.refresh(url))
        XCTAssertEqual(cache.bytesRead - bytes, addition.count)
        XCTAssertEqual(cache.decodedLines - lines, 1)
        XCTAssertEqual(cache.snapshot().events, BotDSHSessionEvent.parseJSONL(data).events)
        print("BOT-READ-PERF history=2000 idlePolls=100 idleBytes=0 appendLines=1")
    }

    func testPartialLineRepairTruncationAndAtomicReplacementMatchFullParser() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try record(1)
        let second = try record(2)
        var data = first + second.prefix(15)
        try data.write(to: url)
        var cache = BotSessionLogReadCache()
        func verify(_ cache: inout BotSessionLogReadCache, _ data: Data) throws {
            _ = try cache.refresh(url)
            let actual = cache.snapshot()
            let oracle = BotDSHSessionEvent.parseJSONL(data)
            XCTAssertEqual(actual.events, oracle.events)
            XCTAssertEqual(actual.diagnostics, oracle.diagnostics)
        }
        try verify(&cache, data)
        let suffix = Data(second.dropFirst(15))
        try append(suffix, to: url); data.append(suffix)
        try verify(&cache, data)
        // A malformed middle line must preserve its physical line number.
        let corrupt = Data("\n{\"seq\":3,\"invalid\":true}\n".utf8)
        try append(corrupt, to: url); data.append(corrupt)
        try verify(&cache, data)
        data = try record(9, text: "rewritten")
        try data.write(to: url, options: .atomic)
        try verify(&cache, data)
        data = Data()
        try data.write(to: url)
        try verify(&cache, data)
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try cache.refresh(url))
        XCTAssertTrue(try cache.refresh(nil))
        XCTAssertTrue(cache.snapshot().events.isEmpty)
    }

    func testDomainCursorSkipsIdleHistoryAndReloadsErasedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"))
        func event(_ type: String, _ id: String) -> BotEvent {
            BotEvent(type: type, eventId: id, time: 1, origin: .local(source: "user"),
                     traceId: "trace", principal: BotPrincipal(botId: "main", sessionId: "main", kind: "chat"),
                     causationId: nil, correlationId: nil,
                     data: .object(["text": .string("private answer")]))
        }
        _ = try await store.append(event("ui.system_event", "first"))
        var cache = BotDomainReadCache()
        let first = try await cache.refresh(domain: store)
        XCTAssertTrue(first)
        let idle = try await cache.refresh(domain: store)
        XCTAssertFalse(idle)
        XCTAssertEqual(cache.fetchedEvents, 1)
        _ = try await store.erasePayloads([1], erasureEvent: event("erasure", "erase"), atMS: 2)
        _ = try await cache.refresh(domain: store)
        let oracle = try await store.events(after: 0, limit: 100)
        XCTAssertEqual(cache.events, oracle)
        XCTAssertEqual(cache.events.first?.data["$erased"], .bool(true))
        try await store.close()
    }
}
