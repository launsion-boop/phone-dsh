// SPDX-License-Identifier: MIT
import Foundation
import PhoneDSHBot
import XCTest
@testable import PhoneDSHProbe

final class BotProjectionReadCacheTests: XCTestCase {
    private func record(_ seq: Int, text: String = "answer") throws -> Data {
        let event = BotDSHSessionEvent(type: "assistant/message", seq: seq, time: Int64(seq),
            data: ["content": .array([.object(["type": .string("text"), "text": .string(text)])])])
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
        XCTAssertTrue(try cache.refresh(url))
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
