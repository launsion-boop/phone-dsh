// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

private actor ContractVolatileProvider: BotVolatileContextProviding {
    private let blocks: BotVolatileBlocks
    private let delayNs: UInt64
    private let failOnCalls: Set<Int>
    private var callCount = 0

    init(blocks: BotVolatileBlocks, delayNs: UInt64 = 0, failOnCalls: Set<Int> = []) {
        self.blocks = blocks
        self.delayNs = delayNs
        self.failOnCalls = failOnCalls
    }

    func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        callCount += 1
        if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }
        if failOnCalls.contains(callCount) { throw BotMCPError.unavailable("provider failed") }
        return blocks
    }

    var calls: Int { callCount }
}

/// D13 volatile contract: assembly and producer cases from
/// `spec/bot/v1/golden/volatile-context.phone.json`, executed by the real
/// `BotDomainVolatileContextProvider` and `BotVolatileContextProducer`.
final class BotVolatileContextPhoneCasesTests: XCTestCase {
    private var vector: [String: Any] = [:]

    override func setUpWithError() throws {
        vector = try BotGoldenFixture.rawObject("volatile-context.phone")
    }

    func testMCPVolatileFixtureMetadata() throws {
        XCTAssertEqual(vector["vector"] as? String, "volatile-context.phone")
        let upstream = try XCTUnwrap(vector["upstream"] as? String)
        XCTAssertEqual(upstream, "volatile-context.json")
        XCTAssertFalse(try BotContractFixture.array(vector["assemblyCases"], "assemblyCases").isEmpty)
        XCTAssertFalse(try BotContractFixture.array(vector["producerCases"], "producerCases").isEmpty)
        // The upstream cases must still be present in the merged view.
        let merged = try BotContractFixture.object("volatile-context")
        XCTAssertNotNil(merged["valid"])
        XCTAssertNotNil(merged["invalid"])
    }

    func testMCPVolatileAssemblyCases() async throws {
        let cases = try BotContractFixture.array(vector["assemblyCases"], "assemblyCases")
        for (index, object) in cases.enumerated() {
            try await runAssembly(object, label: "assembly[\(index)] \((object["name"] as? String) ?? "?")")
        }
    }

    func testMCPVolatileProducerCases() async throws {
        let cases = try BotContractFixture.array(vector["producerCases"], "producerCases")
        for (index, object) in cases.enumerated() {
            try await runProducer(object, label: "producer[\(index)] \((object["name"] as? String) ?? "?")")
        }
    }

    // MARK: - assembly

    private func runAssembly(_ object: [String: Any], label: String) async throws {
        let input = try BotContractFixture.object(object["input"], "\(label).input")
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteDomainStore(
            fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
        let botId = try BotContractFixture.string(input["botId"], "\(label).input.botId")
        let sessionId = try BotContractFixture.string(input["sessionId"], "\(label).input.sessionId")
        let kind = BotSessionKind(rawValue: try BotContractFixture.string(input["kind"], "\(label).input.kind")) ?? .chat
        let language = (input["language"] as? String) ?? "zh"
        let memory = BotMemory(
            store: SQLiteBotMemoryDocumentStore(eventLog: store, botID: botId, now: { 1_000 }),
            botID: botId, now: { 1_000 })
        // The injection renders the two INDEX documents; create them before a
        // fixture writes an explicit index version.
        if !((input["memory"] as? [[String: Any]]) ?? []).isEmpty {
            _ = try await memory.promptBlock(language: .zh)
        }
        for doc in (input["memory"] as? [[String: Any]]) ?? [] {
            _ = try await memory.write(
                BotMemoryWriteRequest(
                    action: .write,
                    path: try BotContractFixture.string(doc["path"], "\(label).input.memory.path"),
                    content: try BotContractFixture.string(doc["content"], "\(label).input.memory.content"),
                    expectedVersion: (doc["expectedVersion"] as? Int) ?? 0),
                context: BotMemoryWriteContext(
                    botID: botId, sessionID: sessionId, authorKind: .chat,
                    source: BotMemorySource(kind: .userTurn, sessionID: sessionId),
                    trust: .user))
        }
        let routines = RoutineMachine(store: SQLiteRoutineStore(domainStore: store))
        for routine in (input["routines"] as? [[String: Any]]) ?? [] {
            _ = try await routines.create(
                botId: botId,
                title: try BotContractFixture.string(routine["title"], "\(label).input.routines.title"),
                prompt: try BotContractFixture.string(routine["prompt"], "\(label).input.routines.prompt"),
                schedule: .interval(everyMinutes: 60), now: 1_000)
        }
        let teammates: [BotTeammateSummary] = ((input["teammates"] as? [[String: Any]]) ?? []).map {
            BotTeammateSummary(
                id: ($0["id"] as? String) ?? "",
                name: ($0["name"] as? String) ?? "",
                description: ($0["description"] as? String) ?? "",
                isMain: ($0["isMain"] as? Bool) ?? false)
        }
        let personaText = input["persona"] as? String
        let descriptionText = input["description"] as? String
        let personaClosure: (@Sendable (String, String, BotSessionKind) -> String)?
        if let personaText {
            personaClosure = { _, _, _ in personaText }
        } else {
            personaClosure = nil
        }
        let teammatesClosure: (@Sendable (String) async -> [BotTeammateSummary])?
        if teammates.isEmpty {
            teammatesClosure = nil
        } else {
            teammatesClosure = { _ in teammates }
        }
        let descriptionClosure: (@Sendable (String) async -> String?)?
        if let descriptionText {
            descriptionClosure = { _ in descriptionText }
        } else {
            descriptionClosure = nil
        }
        let provider = BotDomainVolatileContextProvider(
            memory: memory, routines: routines,
            persona: personaClosure,
            teammates: teammatesClosure,
            botDescription: descriptionClosure,
            now: { 1_000 }, language: language)
        let blocks = try await provider.snapshot(botId: botId, sessionId: sessionId, kind: kind)

        if let expectedPersona = expect["persona"] as? String {
            XCTAssertEqual(blocks.persona, expectedPersona, label)
        }
        if expect["variantAbsent"] as? Bool == true {
            XCTAssertNil(blocks.variant, label)
        }
        if let contains = expect["variantContains"] as? String {
            XCTAssertTrue(blocks.variant?.contains(contains) == true, "\(label): variant missing \(contains)")
        }
        for text in (expect["memoryContains"] as? [String]) ?? [] {
            XCTAssertTrue(blocks.memory?.contains(text) == true, "\(label): memory missing \(text)")
        }
        let automation = blocks.automation ?? ""
        for text in (expect["automationContains"] as? [String]) ?? [] {
            XCTAssertTrue(automation.contains(text), "\(label): automation missing \(text)")
        }
        for text in (expect["automationAbsent"] as? [String]) ?? [] {
            XCTAssertFalse(automation.contains(text), "\(label): automation unexpectedly contains \(text)")
        }
        if let limit = expect["automationScalarsMax"] as? Int {
            XCTAssertLessThanOrEqual(automation.unicodeScalars.count, limit, label)
        }
        let teammateBlock = teammatesBlock(in: automation)
        if let lines = expect["teammatesLineCount"] as? Int {
            let count = teammateBlock.split(whereSeparator: \.isNewline)
                .filter { $0.hasPrefix("- ") }.count
            XCTAssertEqual(count, lines, "\(label): teammate line count")
        }
        if let limit = expect["teammatesScalarsMax"] as? Int {
            XCTAssertLessThanOrEqual(teammateBlock.unicodeScalars.count, limit, label)
        }
    }

    private func teammatesBlock(in automation: String) -> String {
        guard let start = automation.range(of: "<teammates>"),
              let end = automation.range(of: "</teammates>", range: start.upperBound..<automation.endIndex) else {
            return ""
        }
        return String(automation[start.lowerBound..<end.upperBound])
    }

    // MARK: - producer

    private func runProducer(_ object: [String: Any], label: String) async throws {
        let principalObject = try BotContractFixture.object(object["principal"], "\(label).principal")
        let principal = BotGatewayPrincipal(
            botId: try BotContractFixture.string(principalObject["botId"], "\(label).principal.botId"),
            sessionId: try BotContractFixture.string(principalObject["sessionId"], "\(label).principal.sessionId"),
            kind: BotSessionKind(rawValue: try BotContractFixture.string(principalObject["kind"], "\(label).principal.kind")) ?? .chat,
            expiresAt: 10_000)
        let request = try BotContractFixture.json(object["request"] ?? [:])
        let providerObject = try BotContractFixture.object(object["provider"], "\(label).provider")
        let blocks = try BotContractFixture.json(providerObject)
        let delay = (object["delayNs"] as? NSNumber)?.uint64Value ?? 0
        let fails = (object["sequence"] as? [String]) ?? []
        let failOn = Set(fails.enumerated().compactMap { $0.element == "fail" ? $0.offset + 1 : nil })
        let provider = ContractVolatileProvider(
            blocks: decodeBlocks(blocks), delayNs: delay, failOnCalls: failOn)
        let timeout = (object["timeout"] as? NSNumber)?.doubleValue
            ?? BotVolatileContextProducer.defaultTimeout
        let producer = BotVolatileContextProducer(provider: provider, timeout: timeout)
        let expect = try BotContractFixture.object(object["expect"], "\(label).expect")

        if let sequence = object["sequence"] as? [String], sequence.count > 1 {
            let first = try await producer.snapshot(request: request, principal: principal)
            XCTAssertEqual(expect["error"] as? String, "unavailable", label)
            XCTAssertNotNil(first.blocks.memory, label)
            do {
                _ = try await producer.snapshot(request: request, principal: principal)
                XCTFail("\(label): failed provider must not return a stale snapshot")
            } catch let error as BotMCPError {
                XCTAssertEqual(errorCode(error), "unavailable", label)
            }
            return
        }
        do {
            let snapshot = try await producer.snapshot(request: request, principal: principal)
            if let expected = expect["response"] {
                BotContractFixture.assertSubset(
                    snapshot.jsonValue, try BotContractFixture.json(expected), label)
            } else {
                XCTFail("\(label): expected an error but the snapshot succeeded")
            }
        } catch let error as BotMCPError {
            XCTAssertEqual(errorCode(error), expect["error"] as? String, label)
        }
    }

    private func decodeBlocks(_ value: BotJSONValue) -> BotVolatileBlocks {
        BotVolatileBlocks(
            variant: value["variant"]?.stringValue,
            persona: value["persona"]?.stringValue,
            memory: value["memory"]?.stringValue,
            automation: value["automation"]?.stringValue)
    }

    private func errorCode(_ error: BotMCPError) -> String {
        switch error {
        case .invalidRequest: return "invalid_arguments"
        case .unauthorized: return "unauthorized"
        case .unknownTool: return "unknown_tool"
        case .unattributed: return "unattributed"
        case .crossSessionDenied: return "cross_session_read_denied"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        }
    }
}
