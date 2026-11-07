// SPDX-License-Identifier: MIT

import XCTest
@testable import PhoneDSHBot

private actor StubVolatileProvider: BotVolatileContextProviding {
    let blocks: BotVolatileBlocks
    let delayNs: UInt64
    private(set) var calls: [(String, String, BotSessionKind)] = []

    init(blocks: BotVolatileBlocks, delayNs: UInt64 = 0) {
        self.blocks = blocks
        self.delayNs = delayNs
    }

    func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        calls.append((botId, sessionId, kind))
        if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }
        return blocks
    }
}

final class BotVolatileContextTests: XCTestCase {
    func testRealBlocksUseOnlyCurrentPrincipalAndMonotonicRevision() async throws {
        let provider = StubVolatileProvider(blocks: BotVolatileBlocks(
            variant: "简洁直接", persona: "你叫大肥鱼", memory: "## 记忆\n\n- 我喜欢简短回答",
            automation: "<automation_status>没有待处理例行任务</automation_status>"))
        let producer = BotVolatileContextProducer(provider: provider)
        let principal = Self.principal()
        let first = try await producer.snapshot(request: .object(["sessionId": .string("gb-main")]), principal: principal)
        let second = try await producer.snapshot(request: .object(["sessionId": .string("gb-main")]), principal: principal)
        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, 2)
        XCTAssertEqual(first.blocks.persona, "你叫大肥鱼")
        XCTAssertEqual(first.blocks.memory, "## 记忆\n\n- 我喜欢简短回答")
        XCTAssertEqual(first.jsonValue["schemaVersion"], .number(1))
        XCTAssertEqual(first.jsonValue["sessionId"], .string("gb-main"))
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.0), ["main", "main"])
        XCTAssertEqual(calls.map(\.1), ["gb-main", "gb-main"])
    }

    func testInvalidCrossSessionOversizedAndSecretRequestsFailClosed() async throws {
        let producer = BotVolatileContextProducer(provider: StubVolatileProvider(blocks: BotVolatileBlocks(
            memory: "Bearer abcdef1234567890")))
        for request in [
            BotJSONValue.object([:]), .object(["sessionId": .string("")]),
            .object(["sessionId": .string("gb-other")]),
            .object(["sessionId": .string("gb-main"), "botID": .string("other")]),
        ] {
            do {
                _ = try await producer.snapshot(request: request, principal: Self.principal())
                XCTFail("request must fail: \(request)")
            } catch {}
        }
        do {
            _ = try await producer.snapshot(request: .object(["sessionId": .string("gb-main")]), principal: Self.principal())
            XCTFail("credential-shaped content must be withheld")
        } catch {}
        let oversized = BotVolatileContextProducer(provider: StubVolatileProvider(
            blocks: BotVolatileBlocks(variant: String(repeating: "v", count: 12_001))))
        do {
            _ = try await oversized.snapshot(request: .object(["sessionId": .string("gb-main")]), principal: Self.principal())
            XCTFail("oversized block must fail")
        } catch {}
    }

    func testProviderTimeoutReturnsNoPartialSnapshot() async throws {
        let producer = BotVolatileContextProducer(
            provider: StubVolatileProvider(blocks: BotVolatileBlocks(memory: "secret"), delayNs: 200_000_000),
            timeout: 0.01)
        do {
            _ = try await producer.snapshot(request: .object(["sessionId": .string("gb-main")]), principal: Self.principal())
            XCTFail("timeout must fail")
        } catch BotMCPError.timeout {}
    }

    func testDomainProviderReadsSQLiteMemoryAndRoutineState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let memory = BotMemory(
            store: SQLiteBotMemoryFactStore(eventLog: store, now: { 1_000 }),
            dataRoot: directory.path, botID: "main", now: { 1_000 })
        _ = try await memory.write(BotMemoryWriteRequest(
            text: "我喜欢简短回答", source: BotMemorySource(kind: .userTurn, sessionID: "gb-main")))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        _ = try await machine.create(
            botId: "main", title: "Morning", prompt: "report", schedule: .interval(everyMinutes: 60), now: 1_000)
        let provider = BotDomainVolatileContextProvider(
            memory: memory, routines: machine,
            variant: { session, kind in "\(kind.rawValue):\(session)" },
            persona: { _, _ in "大肥鱼" }, now: { 1_000 })
        let snapshot = try await provider.snapshot(botId: "main", sessionId: "gb-main", kind: .chat)
        XCTAssertEqual(snapshot.variant, "chat:gb-main")
        XCTAssertEqual(snapshot.persona, "大肥鱼")
        XCTAssertTrue(snapshot.memory?.contains("我喜欢简短回答") == true)
        XCTAssertTrue(snapshot.automation?.contains("Morning") == true)

        let defaults = BotDomainVolatileContextProvider(memory: memory, routines: machine, now: { 1_000 })
        let routineSnapshot = try await defaults.snapshot(botId: "main", sessionId: "gb-main--routine-1", kind: .routine)
        XCTAssertTrue(routineSnapshot.persona?.contains("大肥鱼") == true)
        XCTAssertTrue(routineSnapshot.variant?.contains("例行任务变体") == true)
    }

    private static func principal() -> BotGatewayPrincipal {
        BotGatewayPrincipal(botId: "main", sessionId: "gb-main", kind: .chat, expiresAt: 10_000)
    }
}
