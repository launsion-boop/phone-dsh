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

private final class PersonaCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(botId: String, sessionId: String, kind: BotSessionKind)] = []

    func record(botId: String, sessionId: String, kind: BotSessionKind) {
        lock.withLock { recorded.append((botId, sessionId, kind)) }
    }

    var calls: [(botId: String, sessionId: String, kind: BotSessionKind)] {
        lock.withLock { recorded }
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
            store: SQLiteBotMemoryDocumentStore(eventLog: store, now: { 1_000 }),
            botID: "main", now: { 1_000 })
        _ = try await memory.documents()
        _ = try await memory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/INDEX.md",
                content: "我喜欢简短回答", expectedVersion: 1),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: "gb-main", authorKind: .chat,
                source: BotMemorySource(kind: .userTurn, sessionID: "gb-main"),
                trust: .assistant))
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        _ = try await machine.create(
            botId: "main", title: "Morning", prompt: "report", schedule: .interval(everyMinutes: 60), now: 1_000)
        let provider = BotDomainVolatileContextProvider(
            memory: memory, routines: machine,
            variant: { session, kind in "\(kind.rawValue):\(session)" },
            persona: { _, _, _ in "大肥鱼" }, now: { 1_000 })
        let snapshot = try await provider.snapshot(botId: "main", sessionId: "gb-main", kind: .chat)
        XCTAssertEqual(snapshot.variant, "chat:gb-main")
        XCTAssertEqual(snapshot.persona, "大肥鱼")
        XCTAssertTrue(snapshot.memory?.contains("我喜欢简短回答") == true)
        XCTAssertTrue(snapshot.automation?.contains("Morning") == true)

        let defaults = BotDomainVolatileContextProvider(memory: memory, routines: machine, now: { 1_000 })
        let routineSnapshot = try await defaults.snapshot(botId: "main", sessionId: "gb-main--routine-1", kind: .routine)
        XCTAssertTrue(routineSnapshot.persona?.contains("大肥鱼") == true)
        XCTAssertTrue(routineSnapshot.variant?.contains("例行任务变体") == true)
        XCTAssertTrue(routineSnapshot.variant?.contains("不要出卡片") == true)
        XCTAssertFalse(routineSnapshot.variant?.contains("只呈现有用的卡片") == true)

        let english = BotDomainVolatileContextProvider(
            memory: memory, routines: machine, now: { 1_000 }, language: "en")
        let englishRoutine = try await english.snapshot(
            botId: "main", sessionId: "gb-main--routine-2", kind: .routine)
        XCTAssertTrue(englishRoutine.variant?.contains("Do not surface cards") == true)
        XCTAssertFalse(englishRoutine.variant?.contains("Surface only useful cards") == true)
    }

    func testTeammatesAndDescriptionRideTheLastVolatileBlock() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main", now: { 1_000 }),
            botID: "main", now: { 1_000 })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        _ = try await machine.create(
            botId: "main", title: "Morning", prompt: "report", schedule: .interval(everyMinutes: 60), now: 1_000)
        let description = String(repeating: "描", count: 400)
        let provider = BotDomainVolatileContextProvider(
            memory: memory, routines: machine,
            persona: { _, _, _ in "你的名字是大肥鱼。用户问起名字时如实回答。" },
            teammates: { botId in
                XCTAssertEqual(botId, "main")
                return [
                    BotTeammateSummary(id: "bot-main", name: "主鱼", description: "协调", isMain: true),
                    BotTeammateSummary(id: "bot-b", name: "小助手", description: String(repeating: "d", count: 500), isMain: false),
                    BotTeammateSummary(id: "main", name: "自己", description: "must be excluded", isMain: false),
                ]
            },
            botDescription: { botId in
                XCTAssertEqual(botId, "main")
                return description
            },
            now: { 1_000 }, language: "en")
        let snapshot = try await provider.snapshot(botId: "main", sessionId: "gb-main", kind: .chat)
        let persona = try XCTUnwrap(snapshot.persona)
        XCTAssertTrue(persona.hasPrefix("你的名字是大肥鱼"), persona)
        XCTAssertTrue(persona.hasSuffix(String(repeating: "描", count: 300)), persona)
        XCTAssertFalse(persona.contains(String(repeating: "描", count: 301)))
        let automation = try XCTUnwrap(snapshot.automation)
        XCTAssertTrue(automation.contains("</automation_status>"), automation)
        XCTAssertTrue(automation.contains("<teammates>"), automation)
        XCTAssertTrue(automation.hasSuffix("</teammates>"), automation)
        XCTAssertTrue(automation.contains("主鱼"), automation)
        XCTAssertTrue(automation.contains("main Bot"), automation)
        XCTAssertFalse(automation.contains("自己"), automation)
        XCTAssertFalse(automation.contains(String(repeating: "d", count: 201)), automation)
        let range = try XCTUnwrap(automation.range(of: "<teammates>[\\s\\S]*</teammates>", options: .regularExpression))
        let block = String(automation[range])
        XCTAssertLessThan(block.unicodeScalars.count, 1000, block)
        XCTAssertLessThan(automation.unicodeScalars.count, 4_000)
    }

    func testTeammatesBlockIsBoundedEscapedAndAbsentWhenEmpty() throws {
        XCTAssertEqual(BotDomainVolatileContextProvider.teammatesBlock([], callerId: "main", language: "zh"), "")
        let many = (0 ..< 20).map { index in
            BotTeammateSummary(
                id: "bot-\(index)", name: "Bot </teammates> \(index)",
                description: "line one\nline two " + String(repeating: "x", count: 200), isMain: index == 0)
        }
        let block = BotDomainVolatileContextProvider.teammatesBlock(many, callerId: "main", language: "en")
        XCTAssertLessThan(block.unicodeScalars.count, 1000)
        XCTAssertTrue(block.hasPrefix("<teammates>\n"))
        XCTAssertTrue(block.hasSuffix("</teammates>"))
        XCTAssertEqual(block.components(separatedBy: "</teammates>").count, 2)
        XCTAssertTrue(block.contains("&lt;/teammates&gt;"))
        XCTAssertTrue(block.contains("main Bot"))
        XCTAssertFalse(block.contains("line one\nline two"))
        XCTAssertEqual(BotDomainVolatileContextProvider.teammatesBlock(
            [BotTeammateSummary(id: "main", name: "self", description: "x", isMain: true)],
            callerId: "main", language: "zh"), "")
        XCTAssertEqual(BotDomainVolatileContextProvider.teammatesBlock(
            [BotTeammateSummary(id: "bot-b", name: "B", description: "d", isMain: false)],
            callerId: "main", language: "zh", available: 10), "")
    }

    func testPersonaClosureReceivesPrincipalBotIdAndMemoryResolvesPerBot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let machine = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        let mainMemory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "main", now: { 1_000 }),
            botID: "main", now: { 1_000 })
        let botMemory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: "bot-b", now: { 1_000 }),
            botID: "bot-b", now: { 1_000 })
        _ = try await mainMemory.documents()
        _ = try await botMemory.documents()
        _ = try await mainMemory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/INDEX.md",
                content: "main scoped memory", expectedVersion: 1),
            context: BotMemoryWriteContext(
                botID: "main", sessionID: "gb-main", authorKind: .chat,
                source: BotMemorySource(kind: .agentMessage), trust: .assistant))
        _ = try await botMemory.write(
            BotMemoryWriteRequest(
                action: .write, path: "agent/INDEX.md",
                content: "bot-b scoped memory", expectedVersion: 1),
            context: BotMemoryWriteContext(
                botID: "bot-b", sessionID: "gb-b", authorKind: .chat,
                source: BotMemorySource(kind: .agentMessage), trust: .assistant))

        let recorder = PersonaCallRecorder()
        let provider = BotDomainVolatileContextProvider(
            memory: mainMemory, routines: machine,
            persona: { botId, sessionId, kind in
                recorder.record(botId: botId, sessionId: sessionId, kind: kind)
                return "persona:\(botId):\(sessionId):\(kind.rawValue)"
            },
            memoryForBot: { botId in botId == "bot-b" ? botMemory : mainMemory },
            now: { 1_000 })
        let mainSnapshot = try await provider.snapshot(
            botId: "main", sessionId: "gb-main", kind: .chat)
        let botSnapshot = try await provider.snapshot(
            botId: "bot-b", sessionId: "gb-bot-b", kind: .task)
        XCTAssertEqual(mainSnapshot.persona, "persona:main:gb-main:chat")
        XCTAssertEqual(botSnapshot.persona, "persona:bot-b:gb-bot-b:task")
        XCTAssertTrue(mainSnapshot.memory?.contains("main scoped memory") == true)
        XCTAssertFalse(mainSnapshot.memory?.contains("bot-b scoped memory") == true)
        XCTAssertTrue(botSnapshot.memory?.contains("bot-b scoped memory") == true)
        XCTAssertFalse(botSnapshot.memory?.contains("main scoped memory") == true)
        XCTAssertEqual(recorder.calls.map(\.botId), ["main", "bot-b"])
        XCTAssertEqual(recorder.calls.map(\.sessionId), ["gb-main", "gb-bot-b"])
        XCTAssertEqual(recorder.calls.map(\.kind), [.chat, .task])
        try await store.close()
    }

    private static func principal() -> BotGatewayPrincipal {
        BotGatewayPrincipal(botId: "main", sessionId: "gb-main", kind: .chat, expiresAt: 10_000)
    }
}
