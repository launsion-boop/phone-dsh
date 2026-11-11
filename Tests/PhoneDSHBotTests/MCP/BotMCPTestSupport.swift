// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import PhoneDSHBot

struct BotMCPTestFixture {
    let directory: URL
    let store: SQLiteDomainStore
    let runtime: BotMCPRuntime

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

func makeBotMCPFixture(
    volatileProvider: (any BotVolatileContextProviding)? = nil,
    taskExecutor: (any BotTaskExecuting)? = nil
) throws -> BotMCPTestFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try SQLiteDomainStore(fileURL: directory.appendingPathComponent("domain.sqlite"), now: { 1_000 })
    let runtime = BotMCPRuntime(
        store: store, volatileProvider: volatileProvider, taskExecutor: taskExecutor, now: { 1_000 })
    return BotMCPTestFixture(directory: directory, store: store, runtime: runtime)
}

func registerAndExecute(
    _ runtime: BotMCPRuntime,
    name: String,
    arguments: BotJSONValue = .object([:]),
    sessionId: String = "gb-main",
    callId: String = UUID().uuidString
) async throws -> BotMCPCallResult {
    _ = try await runtime.registerIdentity(
        runtimeId: BotMCPRuntime.defaultRuntimeID, sessionId: sessionId,
        callId: callId, name: name, arguments: arguments)
    return await runtime.execute(
        name: name, arguments: arguments,
        context: BotMCPRequestContext(callId: callId))
}

/// Start a synthetic user turn so goal-widening tools (UpdateRoutine,
/// CreateTeammate) see the same authority a real user message would give.
func beginUserTurn(_ runtime: BotMCPRuntime, sessionId: String = "gb-main",
                   rpcId: String = "bot-test") async {
    await runtime.beginTurn(
        sessionId: sessionId, hidden: false,
        origin: BotTurnOrigin(rpcId: rpcId))
}

func botEvents(_ store: SQLiteDomainStore) async throws -> [BotEvent] {
    try await store.events(after: 0, limit: 1_000)
}

func botJSON<T: Encodable>(_ value: T) throws -> BotJSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try BotJSONValue.parse(encoder.encode(value))
}

actor StubBotTaskExecutor: BotTaskExecuting {
    private var records: [String: BotTaskRecord] = [:]

    func start(request: BotTaskRequest) async throws -> BotTaskRecord {
        let id = "task-\(UUID().uuidString.prefix(8))"
        let session = "gb-task-\(UUID().uuidString.prefix(8))"
        let record = BotTaskRecord(
            taskId: id, sessionId: session,
            status: request.asynchronous ? "running" : "completed",
            title: request.title,
            result: request.asynchronous ? nil : "completed: \(request.prompt)",
            partial: request.asynchronous ? "partial: \(request.prompt)" : nil)
        records[id] = record
        return record
    }

    func await(taskId: String, timeoutMs: Int, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        guard var record = records[taskId] else { throw BotMCPError.invalidRequest("unknown task") }
        if record.status == "running" {
            record = BotTaskRecord(
                taskId: record.taskId, sessionId: record.sessionId,
                status: "completed", title: record.title,
                result: "completed async", partial: record.partial)
            records[taskId] = record
        }
        return record
    }

    func stop(taskId: String, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        guard let record = records[taskId] else { throw BotMCPError.invalidRequest("unknown task") }
        let stopped = BotTaskRecord(
            taskId: record.taskId, sessionId: record.sessionId,
            status: "stopped", title: record.title,
            result: record.result, partial: record.partial)
        records[taskId] = stopped
        return stopped
    }
}
