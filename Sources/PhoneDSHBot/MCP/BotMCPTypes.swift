// SPDX-License-Identifier: MIT

import Foundation

public struct BotMCPToolDefinition: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let inputSchema: BotJSONValue

    public init(name: String, description: String, inputSchema: BotJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct BotMCPCallResult: Codable, Sendable, Equatable {
    public let content: [BotJSONValue]
    public let structuredContent: BotJSONValue?
    public let isError: Bool?

    public init(structuredContent: BotJSONValue? = nil, text: String? = nil, isError: Bool = false) {
        if let text {
            content = [.object(["type": .string("text"), "text": .string(text)])]
        } else {
            content = []
        }
        self.structuredContent = structuredContent
        self.isError = isError ? true : nil
    }

    public static func success(_ value: BotJSONValue, text: String? = nil) -> Self {
        let visible = text ?? (try? value.encoded()).map { String(decoding: $0, as: UTF8.self) }
        return Self(structuredContent: value, text: visible)
    }

    public static func failure(_ code: String, _ message: String) -> Self {
        Self(structuredContent: .object([
            "ok": .bool(false),
            "error": .object(["code": .string(code), "message": .string(message)]),
        ]), text: message, isError: true)
    }
}

public enum BotMCPError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case unauthorized
    case unknownTool(String)
    case unattributed
    case crossSessionDenied
    case timeout
    case unavailable(String)
}

public struct BotMCPRequestContext: Sendable, Equatable {
    public let runtimeId: String
    public let callId: String

    public init(runtimeId: String = BotMCPRuntime.defaultRuntimeID, callId: String) {
        self.runtimeId = runtimeId
        self.callId = callId
    }
}

public struct BotVolatileBlocks: Codable, Sendable, Equatable {
    public let variant: String?
    public let persona: String?
    public let memory: String?
    public let automation: String?

    public init(variant: String? = nil, persona: String? = nil, memory: String? = nil, automation: String? = nil) {
        self.variant = variant
        self.persona = persona
        self.memory = memory
        self.automation = automation
    }

    public static let empty = Self()
}

public struct BotVolatileSnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sessionId: String
    public let revision: Int
    public let blocks: BotVolatileBlocks

    public init(sessionId: String, revision: Int, blocks: BotVolatileBlocks) {
        schemaVersion = 1
        self.sessionId = sessionId
        self.revision = revision
        self.blocks = blocks
    }

    public var jsonValue: BotJSONValue {
        var fields: [String: BotJSONValue] = [:]
        if let variant = blocks.variant { fields["variant"] = .string(variant) }
        if let persona = blocks.persona { fields["persona"] = .string(persona) }
        if let memory = blocks.memory { fields["memory"] = .string(memory) }
        if let automation = blocks.automation { fields["automation"] = .string(automation) }
        return .object([
            "schemaVersion": .number(1),
            "sessionId": .string(sessionId),
            "revision": .number(Double(revision)),
            "blocks": .object(fields),
        ])
    }
}

public protocol BotVolatileContextProviding: Actor {
    func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks
}

public actor EmptyBotVolatileContextProvider: BotVolatileContextProviding {
    public init() {}
    public func snapshot(botId: String, sessionId: String, kind: BotSessionKind) async throws -> BotVolatileBlocks {
        .empty
    }
}

/// Host-registered team tools (for example agent-to-agent messaging). The
/// runtime keeps the existing tool catalog untouched; a registered handler is
/// consulted only for names the catalog does not advertise, after the normal
/// identity registration and authorization path.
public protocol BotTeamToolHandling: Sendable {
    func handles(_ toolName: String) -> Bool
    func execute(name: String, arguments: BotJSONValue,
                 principal: BotGatewayPrincipal,
                 context: BotMCPRequestContext) async -> BotMCPCallResult
}

public protocol BotTaskExecuting: Actor {
    func start(request: BotTaskRequest) async throws -> BotTaskRecord
    func await(taskId: String, timeoutMs: Int, parent: BotResolvedToolCall) async throws -> BotTaskRecord
    func stop(taskId: String, parent: BotResolvedToolCall) async throws -> BotTaskRecord
}

/// Optional task-executor hook: the Worker was replaced, so no in-memory task
/// work can continue. The executor persists interrupted records and arranges a
/// single parent wake.
public protocol BotTaskRestarting: Actor {
    func workerRestarted() async
}

public struct BotTaskRequest: Sendable, Equatable {
    public let parent: BotResolvedToolCall
    public let title: String
    public let prompt: String
    public let asynchronous: Bool
    public let timeoutMs: Int

    public init(parent: BotResolvedToolCall, title: String, prompt: String,
                asynchronous: Bool, timeoutMs: Int) {
        self.parent = parent
        self.title = title
        self.prompt = prompt
        self.asynchronous = asynchronous
        self.timeoutMs = timeoutMs
    }
}

public struct BotTaskRecord: Codable, Sendable, Equatable {
    public let taskId: String
    public let sessionId: String
    public let status: String
    public let title: String
    public let result: String?
    public let partial: String?
    public let error: String?

    public init(taskId: String, sessionId: String, status: String, title: String,
                result: String? = nil, partial: String? = nil, error: String? = nil) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.status = status
        self.title = title
        self.result = result
        self.partial = partial
        self.error = error
    }

    public var jsonValue: BotJSONValue {
        var fields: [String: BotJSONValue] = [
            "task_id": .string(taskId),
            "sessionId": .string(sessionId),
            "status": .string(status),
            "title": .string(title),
        ]
        if let result { fields["result"] = .string(result) }
        if let partial { fields["partial"] = .string(partial) }
        if let error { fields["error"] = .string(error) }
        return .object(fields)
    }
}

public actor UnimplementedBotTaskExecutor: BotTaskExecuting {
    public init() {}
    public func start(request: BotTaskRequest) async throws -> BotTaskRecord {
        throw BotMCPError.unavailable("Task execution is not configured")
    }
    public func await(taskId: String, timeoutMs: Int, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        throw BotMCPError.unavailable("Task execution is not configured")
    }
    public func stop(taskId: String, parent: BotResolvedToolCall) async throws -> BotTaskRecord {
        throw BotMCPError.unavailable("Task execution is not configured")
    }
}
