// SPDX-License-Identifier: MIT

import Foundation

public struct DefaultWriteGate: Sendable {
    private let tokens: MandateTokenStore?
    private let breaker: CircuitBreaker
    private let evidenceAudits: EvidenceAuditStore
    private let deviceExternalWritePrincipals: Set<String>
    private let now: @Sendable () -> Date

    public init(tokens: MandateTokenStore?, breaker: CircuitBreaker, evidenceAudits: EvidenceAuditStore,
                deviceExternalWritePrincipals: Set<String> = [],
                now: @escaping @Sendable () -> Date = Date.init) {
        self.tokens = tokens
        self.breaker = breaker
        self.evidenceAudits = evidenceAudits
        self.deviceExternalWritePrincipals = deviceExternalWritePrincipals
        self.now = now
    }

    public init(root: URL, deviceExternalWritePrincipals: Set<String> = [],
                now: @escaping @Sendable () -> Date = Date.init) throws {
        try self.init(tokens: MandateTokenStore(root: root), breaker: CircuitBreaker(root: root),
                      evidenceAudits: EvidenceAuditStore(root: root),
                      deviceExternalWritePrincipals: deviceExternalWritePrincipals, now: now)
    }

    public func authorize(tool: ConnectorToolDescriptor, argumentsJSON: String,
                          caller: ToolCaller, grant: ConnectorGrant) async -> GateDecision {
        let operationID = UUID()
        guard grant.connectorID == tool.connectorID else {
            return deny("grant_mismatch", "连接器授权与工具不匹配；请重新授权")
        }
        guard !grant.paused else {
            return deny("grant_paused", "连接器已暂停；请在连接器设置中恢复")
        }
        if let denial = await breaker.checkGrant(connectorID: tool.connectorID, grant: grant) {
            return .deny(denial)
        }
        guard let action = tool.mandateAction ?? (tool.effect == .read ? MandateAction.read : nil) else {
            return deny("unmapped_write_action", "写入动作未映射到用户委托；已拒绝")
        }
        guard grant.allowedActions.contains(action) else {
            return deny("action_not_granted", "连接器未授权此动作；请检查授权范围")
        }
        if tool.effect != .read, case .dshDirect = caller {
            return .requireDSHApproval
        }

        let mandate: WorkMandate?
        var delegatedToken: String?
        switch caller {
        case let .personalAgent(value):
            mandate = value
        case let .delegatedDSH(token):
            delegatedToken = token
            do {
                mandate = try await tokens?.mandate(for: token, grant: grant, now: now())
                if mandate == nil { throw MandateTokenError.invalid }
            } catch {
                return deny("mandate_token_invalid", "委派凭证无效、过期或授权已变化；请重新委派")
            }
        case .dshDirect:
            mandate = nil
        }

        if let mandate {
            guard mandate.validUntil > now() else {
                return deny("mandate_expired", "本次委托已过期；请由用户重新确认")
            }
            guard mandate.allowedActions.contains(action) else {
                return deny("action_not_in_mandate", "此动作不在本次用户委托内；已拒绝")
            }
        } else if tool.effect != .read {
            return deny("missing_mandate", "缺少用户委托；已拒绝写入")
        }

        if tool.effect != .read, mandate?.targets.origin == .modelInferred {
            return .requireTargetSelection([])
        }

        let arguments: [String: Any]
        do {
            arguments = try parseObject(argumentsJSON)
        } catch {
            return deny("invalid_arguments", "工具参数无法核验；已拒绝")
        }

        if tool.effect != .read, let mandate {
            if let targetDenial = validateTargets(tool: tool, action: action, arguments: arguments,
                                                  mandate: mandate, grant: grant) {
                return .deny(targetDenial)
            }
            let evidence: Set<EvidenceRef>
            do {
                evidence = try parseEvidence(arguments["evidenceRefs"], mandate: mandate)
            } catch {
                return deny("evidence_outside_mandate", "生成内容引用了委托外资料；已拒绝")
            }
            if let breakerDenial = await breaker.check(connectorID: tool.connectorID, grant: grant, now: now()) {
                return .deny(breakerDenial)
            }
            if mandate.source == .device && !deviceExternalWritePrincipals.contains(mandate.principal) {
                return deny("device_external_write_disabled", "设备来源默认只读；请在设备上明确开启外部写入")
            }
            do {
                try await evidenceAudits.record(EvidenceAuditRecord(
                    operationID: operationID, mandateID: mandate.mandateID,
                    evidenceRefs: evidence, auditedAt: now()))
            } catch {
                return deny("authorization_persistence_failed", "授权审计无法持久化；已拒绝")
            }
        }
        if let delegatedToken {
            do {
                _ = try await tokens?.consume(token: delegatedToken, grant: grant, now: now())
            } catch {
                return deny("mandate_token_invalid", "委派凭证已被使用或失效；请重新委派")
            }
        }

        do {
            let canonical = try S4Persistence.canonicalJSON(arguments)
            let mandateID = mandate?.mandateID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let digest = S4Persistence.digest([
                tool.internalName, canonical, mandateID.uuidString, String(mandate?.version ?? 0), String(grant.version),
            ].joined(separator: "\n"))
            return .allow(OperationIntent(id: operationID, toolName: tool.internalName,
                                          argumentsJSON: canonical, digest: digest, mandateID: mandateID))
        } catch {
            return deny("invalid_arguments", "工具参数无法规范化；已拒绝")
        }
    }

    private func validateTargets(tool: ConnectorToolDescriptor, action: MandateAction,
                                 arguments: [String: Any], mandate: WorkMandate,
                                 grant: ConnectorGrant) -> GateDenial? {
        if action == .githubComment || action == .githubCreateIssue || action == .githubPush || action == .githubOpenPR {
            guard let repository = repository(arguments)?.lowercased(),
                  let allowedRepository = mandate.targets.repository?.lowercased(),
                  repository == allowedRepository,
                  grant.scope.repositories.map({ $0.lowercased() }).contains(repository) else {
                return GateDenial(code: "repository_outside_mandate", message: "仓库超出本次委托或授权；已拒绝")
            }
            if action == .githubComment {
                guard let number = integer(arguments, keys: ["number", "issueNumber", "pullNumber", "prNumber"]),
                      mandate.targets.issueOrPRNumbers.contains(number) else {
                    return GateDenial(code: "issue_outside_mandate", message: "Issue/PR 超出本次委托；已拒绝")
                }
            }
            return nil
        }

        if action == .gmailCreateDraft || action == .gmailReplyInThread
            || action == .gmailSendNew || action == .gmailForward {
            let threadID = string(arguments, keys: ["threadID", "threadId", "thread_id"])
            if action == .gmailReplyInThread {
                guard let threadID, mandate.targets.gmailThreadIDs.contains(threadID) else {
                    return GateDenial(code: "thread_outside_mandate", message: "邮件线程超出本次委托；已拒绝")
                }
            } else if let threadID, !mandate.targets.gmailThreadIDs.contains(threadID) {
                return GateDenial(code: "thread_outside_mandate", message: "邮件线程超出本次委托；已拒绝")
            }
            let recipients = recipientIdentities(arguments)
            let allowed = Set(mandate.targets.recipientIdentities.map(normalizeIdentity))
            guard !recipients.isEmpty, recipients.count <= grant.rateLimit.maxRecipients,
                  Set(recipients).isSubset(of: allowed) else {
                return GateDenial(code: "recipient_outside_mandate", message: "收件人超出本次委托或授权；已拒绝")
            }
            if let attachmentDenial = validateAttachments(arguments, grant: grant) {
                return attachmentDenial
            }
            return nil
        }
        return GateDenial(code: "unsupported_write_action", message: "无法证明该写入目标；已拒绝")
    }

    private func validateAttachments(_ arguments: [String: Any], grant: ConnectorGrant) -> GateDenial? {
        var total = integer(arguments, keys: ["attachmentBytes", "attachment_bytes"]) ?? 0
        if let attachments = arguments["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                guard let bytes = integer(attachment, keys: ["bytes", "size", "attachmentBytes"]), bytes >= 0 else {
                    return GateDenial(code: "attachment_size_unknown", message: "附件大小无法核验；已拒绝")
                }
                total += bytes
            }
        } else if arguments["attachments"] != nil {
            return GateDenial(code: "attachment_size_unknown", message: "附件大小无法核验；已拒绝")
        }
        guard total <= grant.rateLimit.maxAttachmentBytes else {
            return GateDenial(code: "attachment_limit_exceeded", message: "附件超过授权上限；请移除附件后重试")
        }
        return nil
    }

    private func parseObject(_ json: String) throws -> [String: Any] {
        let data = Data(json.utf8)
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else { throw S4PersistenceError.invalidJSON }
        return object
    }

    private func parseEvidence(_ value: Any?, mandate: WorkMandate) throws -> Set<EvidenceRef> {
        guard let value else { return [] }
        guard let values = value as? [Any] else { throw S4PersistenceError.invalidJSON }
        var result: Set<EvidenceRef> = []
        for value in values {
            let ref: EvidenceRef
            if let id = value as? String {
                guard let allowed = mandate.allowedEvidenceRefs.first(where: { $0.id == id }) else {
                    throw S4PersistenceError.invalidJSON
                }
                ref = allowed
            } else if let object = value as? [String: Any] {
                let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                ref = try JSONDecoder().decode(EvidenceRef.self, from: data)
            } else {
                throw S4PersistenceError.invalidJSON
            }
            guard mandate.allowedEvidenceRefs.contains(ref) else { throw S4PersistenceError.invalidJSON }
            result.insert(ref)
        }
        return result
    }

    private func repository(_ arguments: [String: Any]) -> String? {
        if let repository = string(arguments, keys: ["repository", "repo"]) { return repository }
        guard let owner = string(arguments, keys: ["owner"]),
              let name = string(arguments, keys: ["name", "repositoryName"]) else { return nil }
        return owner + "/" + name
    }

    private func recipientIdentities(_ arguments: [String: Any]) -> [String] {
        guard let value = arguments["recipients"] ?? arguments["to"] else { return [] }
        let values = (value as? [String]) ?? (value as? [Any])?.compactMap { $0 as? String } ?? [value as? String].compactMap { $0 }
        return values.map(normalizeIdentity)
    }

    private func normalizeIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func string(_ arguments: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = arguments[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private func integer(_ arguments: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = arguments[key] as? NSNumber { return value.intValue }
            if let value = arguments[key] as? Int { return value }
        }
        return nil
    }

    private func deny(_ code: String, _ message: String) -> GateDecision {
        .deny(GateDenial(code: code, message: message))
    }
}

extension DefaultWriteGate: WriteGate {}
