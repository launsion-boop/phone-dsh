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

/// The most recent failed `/identity/register` call, kept in host memory for
/// the read-only Bot status line and diagnostics. It carries only the local
/// time, the App's error code and the session id: never a token, argument or
/// request body. A later successful registration clears it.
public struct BotBridgeDiagnostic: Codable, Sendable, Equatable {
    public let atMilliseconds: Int64
    public let code: String
    public let sessionId: String

    public init(atMilliseconds: Int64, code: String, sessionId: String) {
        self.atMilliseconds = atMilliseconds
        self.code = code
        self.sessionId = sessionId
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

    /// A caller that needs an ordered content array (for example a text part
    /// plus an MCP image block). The MCP client admits declared images only;
    /// every other block keeps the ordinary text behaviour.
    public init(content: [BotJSONValue], structuredContent: BotJSONValue? = nil,
                isError: Bool = false) {
        self.content = content
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

/// Optional team-handler hook that supplies the roster-aware tool catalog.
/// The runtime uses it for the MCP `tools/list` response once a caller is
/// identified, so registering the team tools is enough for the App to get a
/// per-caller catalog without additional wiring. Returning `nil` keeps the
/// static catalog for that request.
public protocol BotTeamToolCatalogProviding: Sendable {
    func toolDefinitions(callerBotID: String?) async -> [BotMCPToolDefinition]?
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

/// Optional task-executor hook: a durable approval reached a terminal state.
/// The executor resumes or closes the task/routine that was parked on it. It
/// is also called for decisions restored after a process restart.
public protocol BotApprovalResuming: Actor {
    func approvalResolved(_ notice: BotApprovalResolutionNotice) async
}

/// Optional task-executor hook: an egress write became a durable todo while a
/// tool call was still running. The executor may stop the turn so the task can
/// park in one deterministic place (the Worker structural gate stops itself).
public protocol BotApprovalPendingObserving: Actor {
    func approvalBecamePending(_ state: BotDurableApprovalState) async
}

/// The optional work budget declared with a Task. `maxDurationMs` defaults to
/// the existing `timeout_ms`; the verifier budget is derived from it and is
/// never separately negotiable (P26 §2.8).
public struct BotTaskBudget: Codable, Sendable, Equatable {
    public static let minimumDurationMs = 1_000
    public static let maximumDurationMs = 300_000

    public var maxDurationMs: Int?

    public init(maxDurationMs: Int? = nil) {
        self.maxDurationMs = maxDurationMs
    }

    public func durationMs(taskTimeoutMs: Int) -> Int {
        maxDurationMs ?? taskTimeoutMs
    }

    public var jsonValue: BotJSONValue {
        var fields: [String: BotJSONValue] = [:]
        if let maxDurationMs { fields["max_duration_ms"] = .number(Double(maxDurationMs)) }
        return .object(fields)
    }
}

public struct BotTaskRequest: Sendable, Equatable {
    public let parent: BotResolvedToolCall
    public let title: String
    public let prompt: String
    public let asynchronous: Bool
    public let timeoutMs: Int
    /// Empty means the caller did not declare a checkable finish line.
    public let completion: String
    public let purpose: String?
    public let constraints: [String]
    public let budget: BotTaskBudget?

    public init(parent: BotResolvedToolCall, title: String, prompt: String,
                asynchronous: Bool, timeoutMs: Int, completion: String = "",
                purpose: String? = nil, constraints: [String] = [],
                budget: BotTaskBudget? = nil) {
        self.parent = parent
        self.title = title
        self.prompt = prompt
        self.asynchronous = asynchronous
        self.timeoutMs = timeoutMs
        self.completion = completion
        self.purpose = purpose
        self.constraints = constraints
        self.budget = budget
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
    public let completion: String?
    public let purpose: String?
    public let constraints: [String]
    public let budget: BotTaskBudget?
    public let verification: BotVerification?

    public init(taskId: String, sessionId: String, status: String, title: String,
                result: String? = nil, partial: String? = nil, error: String? = nil,
                completion: String? = nil, purpose: String? = nil,
                constraints: [String] = [], budget: BotTaskBudget? = nil,
                verification: BotVerification? = nil) {
        self.taskId = taskId
        self.sessionId = sessionId
        self.status = status
        self.title = title
        self.result = result
        self.partial = partial
        self.error = error
        self.completion = completion
        self.purpose = purpose
        self.constraints = constraints
        self.budget = budget
        self.verification = verification
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
        if let completion, !completion.isEmpty { fields["completion"] = .string(completion) }
        if let purpose, !purpose.isEmpty { fields["purpose"] = .string(purpose) }
        if !constraints.isEmpty { fields["constraints"] = .array(constraints.map(BotJSONValue.string)) }
        if let budget { fields["budget"] = budget.jsonValue }
        if let verification { fields["verification"] = verification.jsonValue }
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
