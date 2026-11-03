// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHShell

public protocol GmailGrantProviding: Sendable {
    func gmailGrant() async -> ConnectorGrant?
}

public struct GmailRegistryGrantProvider: GmailGrantProviding {
    private let registry: any ConnectorRegistry

    public init(registry: any ConnectorRegistry) { self.registry = registry }
    public func gmailGrant() async -> ConnectorGrant? { await registry.grant(of: "gmail") }
}

public final class GmailToolBridge: PhoneToolBridge, ConnectorToolInvoker, Sendable {
    public let supportsContext = false
    public let handles: Set<String>
    public let descriptors: [ConnectorToolDescriptor]

    private let client: GmailClient
    private let grants: any GmailGrantProviding
    private let writes: GmailWriteCoordinator?

    public init(client: GmailClient, grants: any GmailGrantProviding, writes: GmailWriteCoordinator? = nil) {
        self.client = client
        self.grants = grants
        self.writes = writes
        descriptors = Self.allDescriptors
        handles = Set(Self.allDescriptors.map(\.internalName))
    }

    public func callTool(name: String, arguments: String) async throws -> String {
        let tool = name.hasPrefix("phone.") ? String(name.dropFirst("phone.".count)) : name
        return try await result(tool, argumentsJSON: arguments, caller: .dshDirect).content
    }

    public func invoke(_ name: String, argumentsJSON: String, caller: ToolCaller) async -> ToolInvocationResult {
        let outcome = (try? await result(name, argumentsJSON: argumentsJSON, caller: caller))
            ?? InvocationContent(content: Self.errorJSON(name, GmailError.invalidResponse), isError: true)
        return ToolInvocationResult(toolCallID: name, contentJSON: outcome.content, isError: outcome.isError)
    }

    internal static func descriptor(named name: String) -> ConnectorToolDescriptor {
        guard let descriptor = allDescriptors.first(where: { $0.internalName == name }) else {
            preconditionFailure("Unknown Gmail descriptor")
        }
        return descriptor
    }

    private func result(_ name: String, argumentsJSON: String,
                        caller: ToolCaller) async throws -> InvocationContent {
        do {
            guard argumentsJSON.utf8.count <= PhoneToolEnvelope.maximumBytes else { throw GmailError.responseTooLarge }
            guard handles.contains(name) else { throw GmailError.invalidArguments("未知 Gmail 工具") }
            guard let grant = await grants.gmailGrant() else { throw GmailError.disconnected }
            if Self.readTools.contains(name) {
                try Self.authorizeRead(caller: caller, grant: grant)
                let value = try await read(name, argumentsJSON: argumentsJSON)
                return InvocationContent(content: try Self.successJSON(tool: name, value: value), isError: false)
            }
            guard let writes else { throw GmailError.permissionDenied("Gmail 写门禁尚未由宿主接入") }
            let receipt: ProviderReceipt
            switch name {
            case "gmail.draft.create":
                let input = try Self.decode(DraftArguments.self, argumentsJSON).input
                receipt = try await writes.createDraft(input, caller: caller, grant: grant,
                                                       argumentsJSON: argumentsJSON)
            case "gmail.draft.update":
                let arguments = try Self.decode(DraftUpdateArguments.self, argumentsJSON)
                let input = GmailDraftUpdateInput(draftID: arguments.draftID, draft: arguments.draft.input)
                receipt = try await writes.updateDraft(input, caller: caller, grant: grant,
                                                       argumentsJSON: argumentsJSON)
            case "gmail.message.reply", "gmail.message.send", "gmail.message.forward":
                let arguments = try Self.decode(SendArguments.self, argumentsJSON)
                let expected = switch name {
                case "gmail.message.reply": GmailSendKind.reply
                case "gmail.message.send": GmailSendKind.new
                default: GmailSendKind.forward
                }
                guard arguments.kind == expected else { throw GmailError.invalidArguments("发送类型与工具不一致") }
                receipt = try await writes.send(GmailSendInput(kind: arguments.kind, draft: arguments.draft.input),
                                                caller: caller, grant: grant, argumentsJSON: argumentsJSON)
            default:
                throw GmailError.invalidArguments("未知 Gmail 工具")
            }
            return InvocationContent(content: try Self.successJSON(tool: name, value: receipt), isError: false)
        } catch let error as GmailError {
            return InvocationContent(content: Self.errorJSON(name, error), isError: true)
        } catch is CancellationError {
            return InvocationContent(content: Self.errorJSON(name, .permissionDenied("操作已取消")), isError: true)
        } catch {
            return InvocationContent(content: Self.errorJSON(name, .invalidResponse), isError: true)
        }
    }

    private func read(_ name: String, argumentsJSON: String) async throws -> any Encodable {
        switch name {
        case "gmail.search":
            let arguments = try Self.decode(SearchArguments.self, argumentsJSON)
            return try await client.search(GmailSearchQuery(
                since: arguments.since, until: arguments.until, unreadOnly: arguments.unreadOnly ?? false,
                sender: arguments.sender, subject: arguments.subject, limit: arguments.limit ?? 20,
                pageToken: arguments.pageToken))
        case "gmail.message.get":
            let arguments = try Self.decode(MessageArguments.self, argumentsJSON)
            return try await client.message(id: arguments.id, includeBody: arguments.includeBody ?? false)
        case "gmail.thread.get":
            let arguments = try Self.decode(ThreadArguments.self, argumentsJSON)
            return try await client.thread(id: arguments.id, includeBody: arguments.includeBody ?? false)
        default:
            throw GmailError.invalidArguments("未知 Gmail 读取工具")
        }
    }

    private static func authorizeRead(caller: ToolCaller, grant: ConnectorGrant) throws {
        guard grant.connectorID == "gmail", !grant.paused,
              grant.allowedActions.contains(.read), grant.scope.rawScopes.contains(GmailScope.readOnly) else {
            throw GmailError.permissionDenied("Gmail 产品 grant 不允许读取")
        }
        if case .personalAgent(let mandate) = caller {
            guard mandate.allowedActions.contains(.read), mandate.validUntil > Date() else {
                throw GmailError.permissionDenied("本次委托不允许读取 Gmail")
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        do {
            return try GmailJSON.decoder.decode(type, from: Data(text.utf8))
        } catch {
            throw GmailError.invalidArguments("JSON 参数不完整或类型错误")
        }
    }

    private static func successJSON<T: Encodable>(tool: String, value: T) throws -> String {
        let data = try GmailJSON.encoder.encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw GmailError.invalidResponse }
        return try PhoneToolEnvelope.success(tool: tool, scope: "gmail", data: dictionary)
    }

    private static func errorJSON(_ tool: String, _ error: GmailError) -> String {
        let code = switch error {
        case .invalidArguments: "invalid_arguments"
        case .permissionDenied, .approvalRequired: "permission_denied"
        case .notConfigured, .disconnected: "not_configured"
        case .expired, .revoked: "authorization_expired"
        case .outcomeUnknown, .timeout: "outcome_unknown"
        case .responseTooLarge: "result_too_large"
        default: "provider_error"
        }
        let object: [String: Any] = ["ok": false, "tool": tool,
                                     "error": ["code": code, "message": error.localizedDescription,
                                               "retryable": false]]
        return (try? PhoneToolEnvelope.string(object)) ?? "{\"ok\":false}"
    }

    private struct InvocationContent { let content: String; let isError: Bool }
    private static let readTools: Set<String> = ["gmail.search", "gmail.message.get", "gmail.thread.get"]

    private static let allDescriptors: [ConnectorToolDescriptor] = [
        ConnectorToolDescriptor(internalName: "gmail.search", connectorID: "gmail", effect: .read,
                                mandateAction: .read, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "搜索 Gmail 邮件"),
        ConnectorToolDescriptor(internalName: "gmail.message.get", connectorID: "gmail", effect: .read,
                                mandateAction: .read, inputSchemaJSON: #"{"type":"object","required":["id"]}"#,
                                summary: "读取 Gmail 邮件"),
        ConnectorToolDescriptor(internalName: "gmail.thread.get", connectorID: "gmail", effect: .read,
                                mandateAction: .read, inputSchemaJSON: #"{"type":"object","required":["id"]}"#,
                                summary: "读取 Gmail 线程"),
        ConnectorToolDescriptor(internalName: "gmail.draft.create", connectorID: "gmail", effect: .write,
                                mandateAction: .gmailCreateDraft, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "创建 Gmail 草稿"),
        ConnectorToolDescriptor(internalName: "gmail.draft.update", connectorID: "gmail", effect: .write,
                                mandateAction: .gmailCreateDraft, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "更新 Gmail 草稿"),
        ConnectorToolDescriptor(internalName: "gmail.message.reply", connectorID: "gmail", effect: .irreversible,
                                mandateAction: .gmailReplyInThread, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "在线程内回复 Gmail"),
        ConnectorToolDescriptor(internalName: "gmail.message.send", connectorID: "gmail", effect: .irreversible,
                                mandateAction: .gmailSendNew, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "发送新 Gmail 邮件"),
        ConnectorToolDescriptor(internalName: "gmail.message.forward", connectorID: "gmail", effect: .irreversible,
                                mandateAction: .gmailForward, inputSchemaJSON: #"{"type":"object"}"#,
                                summary: "转发 Gmail 邮件"),
    ]
}

private struct SearchArguments: Decodable {
    let since: Date?
    let until: Date?
    let unreadOnly: Bool?
    let sender: String?
    let subject: String?
    let limit: Int?
    let pageToken: String?
}
private struct MessageArguments: Decodable { let id: String; let includeBody: Bool? }
private struct ThreadArguments: Decodable { let id: String; let includeBody: Bool? }
private struct DraftArguments: Decodable {
    let recipients: [String]
    let cc: [String]?
    let bcc: [String]?
    let subject: String
    let body: String
    let threadID: String?
    let inReplyTo: String?
    let references: String?
    let evidenceRefs: [String]?

    var input: GmailDraftInput {
        GmailDraftInput(recipients: recipients, cc: cc ?? [], bcc: bcc ?? [], subject: subject, body: body,
                        threadID: threadID, inReplyTo: inReplyTo, references: references,
                        evidenceRefs: evidenceRefs ?? [])
    }
}
private struct DraftUpdateArguments: Decodable { let draftID: String; let draft: DraftArguments }
private struct SendArguments: Decodable { let kind: GmailSendKind; let draft: DraftArguments }
