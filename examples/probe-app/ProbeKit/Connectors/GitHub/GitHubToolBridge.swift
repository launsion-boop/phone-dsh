// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell

public final class GitHubToolBridge: PhoneToolBridge, ConnectorToolInvoker, @unchecked Sendable {
    public static let connectorID = "github"
    public let supportsContext = false
    public let descriptors: [ConnectorToolDescriptor]
    public let handles: Set<String>
    public var hostCapabilities: Set<String> { Set(handles.map { "phone-tool:\($0)" }) }

    private let client: GitHubClient
    private let registry: any ConnectorRegistry
    private let writeGate: (any WriteGate)?
    private let ledger: (any OperationLedger)?
    private let breaker: CircuitBreaker?

    public init(client: GitHubClient,
                registry: any ConnectorRegistry,
                writeGate: (any WriteGate)? = nil,
                ledger: (any OperationLedger)? = nil,
                breaker: CircuitBreaker? = nil,
                includeWriteTools: Bool? = nil) {
        self.client = client
        self.registry = registry
        self.writeGate = writeGate
        self.ledger = ledger
        self.breaker = breaker
        let includeWriteTools = includeWriteTools ?? (writeGate != nil && ledger != nil)
        var descriptors = [
            Self.descriptor("github.repository.get", "读取 GitHub 仓库", schema: Self.repositorySchema),
            Self.descriptor("github.issue.get", "读取 GitHub Issue", schema: Self.numberSchema),
            Self.descriptor("github.pull.get", "读取 GitHub Pull Request", schema: Self.numberSchema),
            Self.descriptor("github.pull.diff", "读取 GitHub PR 的有界 diff", schema: Self.numberSchema),
            Self.descriptor("github.pull.checks", "读取 GitHub PR 当前 head 的 Checks", schema: Self.numberSchema),
        ]
        if includeWriteTools {
            descriptors.append(Self.descriptor("github.issue.comment", "评论 GitHub Issue 或 PR",
                                               schema: Self.commentSchema, effect: .write,
                                               action: .githubComment))
            descriptors.append(Self.descriptor("github.issue.create", "创建 GitHub Issue",
                                               schema: Self.createIssueSchema, effect: .write,
                                               action: .githubCreateIssue))
        }
        self.descriptors = descriptors
        handles = Set(descriptors.map(\.internalName))
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        return await invoke(tool, argumentsJSON: arguments, caller: .dshDirect).contentJSON
    }

    public func invoke(_ name: String, argumentsJSON: String,
                       caller: ToolCaller) async -> ToolInvocationResult {
        guard let descriptor = descriptors.first(where: { $0.internalName == name }) else {
            return Self.failure(name: "unknown", code: "unknown_tool", message: "未知 GitHub 工具")
        }
        do {
            let arguments = try Self.object(argumentsJSON)
            let record = await registry.state(of: Self.connectorID)
            guard record.state == .connected else {
                return Self.failure(name: name, code: "connector_\(record.state.rawValue)",
                                    message: record.issue ?? "GitHub 未连接，请先在发现页完成配置")
            }
            guard let grant = await registry.grant(of: Self.connectorID), !grant.paused,
                  grant.allowedActions.contains(.read) else {
                return Self.failure(name: name, code: "grant_unavailable", message: "GitHub 授权不可用或已暂停")
            }
            if descriptor.effect == .read {
                if case .personalAgent(let mandate) = caller, !mandate.allowedActions.contains(.read) {
                    return Self.failure(name: name, code: "read_not_delegated", message: "当前委托不允许读取 GitHub")
                }
                return try await read(descriptor, arguments: arguments, grant: grant)
            }
            return await write(descriptor, arguments: arguments, argumentsJSON: argumentsJSON,
                               caller: caller, grant: grant)
        } catch let error as GitHubClientError {
            return Self.failure(name: name, error: error)
        } catch let error as GateDenial {
            return Self.failure(name: name, code: error.code, message: error.message)
        } catch {
            return Self.failure(name: name, code: "invalid_arguments", message: "GitHub 工具参数无效")
        }
    }

    private func read(_ descriptor: ConnectorToolDescriptor,
                      arguments: [String: Any], grant: ConnectorGrant) async throws -> ToolInvocationResult {
        let repository = try Self.repository(arguments)
        try Self.authorize(repository, grant: grant)
        let value: Any
        switch descriptor.internalName {
        case "github.repository.get":
            value = try EncodableValue(try await client.repository(repository))
        case "github.issue.get":
            value = try EncodableValue(try await client.issue(repository: repository,
                                                               number: try Self.number(arguments)))
        case "github.pull.get":
            value = try EncodableValue(try await client.pull(repository: repository,
                                                              number: try Self.number(arguments)))
        case "github.pull.diff":
            let maximum = min((arguments["maxPatchBytes"] as? Int) ?? 32_768, 65_536)
            value = try EncodableValue(try await client.diff(repository: repository,
                                                              number: try Self.number(arguments),
                                                              maximumPatchBytes: maximum))
        case "github.pull.checks":
            value = try EncodableValue(try await client.checks(repository: repository,
                                                                number: try Self.number(arguments)))
        default:
            return Self.failure(name: descriptor.internalName, code: "unknown_tool", message: "未知 GitHub 工具")
        }
        let payload: [String: Any] = ["ok": true, "tool": descriptor.internalName, "result": value]
        let data = try JSONSerialization.data(withJSONObject: try Self.foundation(payload))
        guard data.count <= 256 * 1024 else {
            return Self.failure(name: descriptor.internalName, code: "response_too_large",
                                message: "GitHub 工具结果超过大小限制")
        }
        return ToolInvocationResult(toolCallID: "", contentJSON: String(decoding: data, as: UTF8.self))
    }

    private func write(_ descriptor: ConnectorToolDescriptor,
                       arguments: [String: Any], argumentsJSON: String,
                       caller: ToolCaller, grant: ConnectorGrant) async -> ToolInvocationResult {
        var committingIntent: OperationIntent?
        do {
            let repository = try Self.repository(arguments)
            try Self.authorize(repository, grant: grant)
            guard let writeGate, let ledger else {
                return Self.failure(name: descriptor.internalName, code: "write_unavailable",
                                    message: "GitHub 写门禁或操作账本尚未接线，未执行写入")
            }
            let decision = await writeGate.authorize(tool: descriptor, argumentsJSON: argumentsJSON,
                                                     caller: caller, grant: grant)
            if case .dshDirect = caller {
                return Self.failure(name: descriptor.internalName, code: "dsh_approval_required",
                                    message: "DSH 直接写入需要原生逐项审批；未继承 Chat 授权，未执行写入")
            }
            guard case .allow(let intent) = decision else {
                return Self.gateFailure(name: descriptor.internalName, decision: decision)
            }
            _ = try await ledger.prepare(intent)
            try await ledger.markCommitting(intent.id)
            try await breaker?.recordOperation(connectorID: Self.connectorID)
            committingIntent = intent
            let receipt: GitHubWriteReceipt
            switch descriptor.internalName {
            case "github.issue.comment":
                receipt = try await client.createComment(repository: repository,
                                                          number: try Self.number(arguments),
                                                          body: try Self.string(arguments, key: "body"))
            case "github.issue.create":
                receipt = try await client.createIssue(repository: repository,
                                                        title: try Self.string(arguments, key: "title"),
                                                        body: try Self.string(arguments, key: "body"))
            default:
                return Self.failure(name: descriptor.internalName, code: "unknown_tool", message: "未知 GitHub 工具")
            }
            let providerReceipt = ProviderReceipt(providerObjectID: receipt.providerObjectID,
                                                  url: receipt.url, rawJSON: "{}")
            try await ledger.commit(intent.id, receipt: providerReceipt)
            try await breaker?.recordProviderSuccess(connectorID: Self.connectorID)
            try await breaker?.setUnknown(connectorID: Self.connectorID, operationID: intent.id, isUnknown: false)
            committingIntent = nil
            let payload: [String: Any] = ["ok": true, "tool": descriptor.internalName,
                                          "id": receipt.providerObjectID, "url": receipt.url]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return ToolInvocationResult(toolCallID: "", contentJSON: String(decoding: data, as: UTF8.self))
        } catch let error as GitHubClientError {
            if let intent = committingIntent {
                try? await markUnknown(intent.id)
            }
            return Self.failure(name: descriptor.internalName, error: error)
        } catch let error as GateDenial {
            return Self.failure(name: descriptor.internalName, code: error.code, message: error.message)
        } catch {
            if let intent = committingIntent {
                try? await markUnknown(intent.id)
            }
            return Self.failure(name: descriptor.internalName, code: "write_failed",
                                message: "GitHub 写入未完成；如网络结果未知，请通过操作账本对账，不要重复提交")
        }
    }

    private func markUnknown(_ operationID: UUID) async throws {
        try await ledger?.markUnknown(operationID, reason: "GitHub 写入结果未知，需要反查对账")
        try await breaker?.recordProviderFailure(connectorID: Self.connectorID)
        try await breaker?.setUnknown(connectorID: Self.connectorID, operationID: operationID, isUnknown: true)
    }

    private static func gateFailure(name: String, decision: GateDecision) -> ToolInvocationResult {
        switch decision {
        case .requireTargetSelection:
            return failure(name: name, code: "target_selection_required", message: "需要用户明确选择写入目标")
        case .downgradeToDraft(let reason):
            return failure(name: name, code: "write_downgraded", message: reason)
        case .requireDSHApproval:
            return failure(name: name, code: "dsh_approval_required", message: "DSH 直接写入需要逐项审批")
        case .deny(let denial):
            return failure(name: name, code: denial.code, message: denial.message)
        case .allow:
            return failure(name: name, code: "write_denied", message: "写入未获授权")
        }
    }

    private static func authorize(_ repository: String, grant: ConnectorGrant) throws {
        guard grant.scope.repositories.contains(repository) else { throw GateDenial(
            code: "repository_outside_grant", message: "目标仓库不在 GitHub 授权范围内") }
    }

    private static func object(_ json: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw GitHubClientError.invalidResponse
        }
        return object
    }

    private static func repository(_ object: [String: Any]) throws -> String {
        try string(object, key: "repository")
    }

    private static func number(_ object: [String: Any]) throws -> Int {
        guard let number = object["number"] as? Int, number > 0 else { throw GitHubClientError.invalidNumber }
        return number
    }

    private static func string(_ object: [String: Any], key: String) throws -> String {
        guard let value = object[key] as? String, !value.isEmpty else { throw GitHubClientError.invalidResponse }
        return value
    }

    private static func failure(name: String, error: GitHubClientError) -> ToolInvocationResult {
        failure(name: name, code: error.code, message: error.message)
    }

    private static func failure(name: String, code: String, message: String) -> ToolInvocationResult {
        let data = try? JSONSerialization.data(withJSONObject: [
            "ok": false, "tool": name, "error": ["code": code, "message": message],
        ])
        return ToolInvocationResult(toolCallID: "",
                                    contentJSON: data.map { String(decoding: $0, as: UTF8.self) } ?? "{}",
                                    isError: true)
    }

    private static func descriptor(_ name: String, _ summary: String, schema: String,
                                   effect: ToolEffect = .read,
                                   action: MandateAction? = .read) -> ConnectorToolDescriptor {
        ConnectorToolDescriptor(internalName: name, connectorID: connectorID, effect: effect,
                                mandateAction: action, inputSchemaJSON: schema, summary: summary)
    }

    private static let repositorySchema = #"{"type":"object","required":["repository"],"properties":{"repository":{"type":"string"}},"additionalProperties":false}"#
    private static let numberSchema = #"{"type":"object","required":["repository","number"],"properties":{"repository":{"type":"string"},"number":{"type":"integer","minimum":1},"maxPatchBytes":{"type":"integer","maximum":65536}},"additionalProperties":false}"#
    private static let commentSchema = #"{"type":"object","required":["repository","number","body"],"properties":{"repository":{"type":"string"},"number":{"type":"integer","minimum":1},"body":{"type":"string","minLength":1}},"additionalProperties":false}"#
    private static let createIssueSchema = #"{"type":"object","required":["repository","title","body"],"properties":{"repository":{"type":"string"},"title":{"type":"string","minLength":1},"body":{"type":"string"}},"additionalProperties":false}"#

    private static func foundation(_ value: Any) throws -> Any {
        if let value = value as? EncodableValue { return try value.foundation() }
        if let dictionary = value as? [String: Any] {
            return try dictionary.mapValues(foundation)
        }
        if let array = value as? [Any] { return try array.map(foundation) }
        return value
    }
}

private struct EncodableValue: Sendable {
    let data: Data

    init<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        data = try encoder.encode(value)
    }

    func foundation() throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
