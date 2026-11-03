// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

public enum GmailSendKind: String, Codable, Sendable {
    case reply
    case new
    case forward

    public var action: MandateAction {
        switch self {
        case .reply: return .gmailReplyInThread
        case .new: return .gmailSendNew
        case .forward: return .gmailForward
        }
    }
}

public struct GmailDraftInput: Codable, Sendable, Equatable {
    public var recipients: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    public var body: String
    public var threadID: String?
    public var inReplyTo: String?
    public var references: String?
    public var evidenceRefs: [String]

    public init(recipients: [String], cc: [String] = [], bcc: [String] = [], subject: String, body: String,
                threadID: String? = nil, inReplyTo: String? = nil, references: String? = nil,
                evidenceRefs: [String] = []) {
        self.recipients = recipients
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.threadID = threadID
        self.inReplyTo = inReplyTo
        self.references = references
        self.evidenceRefs = evidenceRefs
    }
}

public struct GmailDraftUpdateInput: Codable, Sendable, Equatable {
    public var draftID: String
    public var draft: GmailDraftInput

    public init(draftID: String, draft: GmailDraftInput) {
        self.draftID = draftID
        self.draft = draft
    }
}

public struct GmailSendInput: Codable, Sendable, Equatable {
    public var kind: GmailSendKind
    public var draft: GmailDraftInput

    public init(kind: GmailSendKind, draft: GmailDraftInput) {
        self.kind = kind
        self.draft = draft
    }

    public var digest: String {
        let data = (try? GmailJSON.encoder.encode(self)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol GmailUndoWindow: Sendable {
    func wait() async throws
}

public struct GmailFiveSecondUndoWindow: GmailUndoWindow {
    public init() {}
    public func wait() async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
    }
}

public struct GmailWriteCoordinator: Sendable {
    private let client: GmailClient
    private let gate: any WriteGate
    private let ledger: any OperationLedger
    private let undoWindow: any GmailUndoWindow
    private let grants: (any GmailGrantProviding)?
    private let now: @Sendable () -> Date

    public init(client: GmailClient, gate: any WriteGate, ledger: any OperationLedger,
                undoWindow: any GmailUndoWindow = GmailFiveSecondUndoWindow(),
                grants: (any GmailGrantProviding)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.gate = gate
        self.ledger = ledger
        self.undoWindow = undoWindow
        self.grants = grants
        self.now = now
    }

    public func createDraft(_ input: GmailDraftInput, caller: ToolCaller,
                            grant: ConnectorGrant, argumentsJSON: String) async throws -> ProviderReceipt {
        let descriptor = GmailToolBridge.descriptor(named: "gmail.draft.create")
        try await Self.authorizeDraft(input, caller: caller, grant: grant, now: now())
        let intent = try await authorizeWithHost(descriptor: descriptor, argumentsJSON: argumentsJSON,
                                                 caller: caller, grant: grant)
        let record = try await ledger.prepare(intent)
        try await ledger.markCommitting(record.id)
        do {
            let response: DraftResponseDTO = try await client.post(
                path: "/gmail/v1/users/me/drafts", body: DraftRequestDTO(input: input),
                grant: grant, requiredAction: .gmailCreateDraft)
            return try await commit(record.id, id: response.id,
                                    raw: ["id": response.id, "messageID": response.message.id])
        } catch let error as GmailError where error == .timeout || error == .transport {
            try await ledger.markUnknown(record.id, reason: "草稿请求结果未知")
            throw GmailError.outcomeUnknown
        }
    }

    public func updateDraft(_ input: GmailDraftUpdateInput, caller: ToolCaller,
                            grant: ConnectorGrant, argumentsJSON: String) async throws -> ProviderReceipt {
        let descriptor = GmailToolBridge.descriptor(named: "gmail.draft.update")
        try await Self.authorizeDraft(input.draft, caller: caller, grant: grant, now: now())
        guard input.draftID.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }), !input.draftID.isEmpty else {
            throw GmailError.invalidArguments("draftID 含非法字符")
        }
        let intent = try await authorizeWithHost(descriptor: descriptor, argumentsJSON: argumentsJSON,
                                                 caller: caller, grant: grant)
        let record = try await ledger.prepare(intent)
        try await ledger.markCommitting(record.id)
        do {
            let response: DraftResponseDTO = try await client.put(
                path: "/gmail/v1/users/me/drafts/\(input.draftID)", body: DraftRequestDTO(input: input.draft),
                grant: grant, requiredAction: .gmailCreateDraft)
            return try await commit(record.id, id: response.id,
                                    raw: ["id": response.id, "messageID": response.message.id])
        } catch let error as GmailError where error == .timeout || error == .transport {
            try await ledger.markUnknown(record.id, reason: "草稿更新结果未知")
            throw GmailError.outcomeUnknown
        }
    }

    public func send(_ input: GmailSendInput, caller: ToolCaller,
                     grant: ConnectorGrant, argumentsJSON: String) async throws -> ProviderReceipt {
        let name = switch input.kind {
        case .reply: "gmail.message.reply"
        case .new: "gmail.message.send"
        case .forward: "gmail.message.forward"
        }
        let descriptor = GmailToolBridge.descriptor(named: name)
        try await authorizeSend(input, caller: caller, grant: grant)
        let intent = try await authorizeWithHost(descriptor: descriptor, argumentsJSON: argumentsJSON,
                                                 caller: caller, grant: grant)
        let record = try await ledger.prepare(intent)
        let undoLedger = ledger as? any UndoWindowOperationLedger
        if let undoLedger { _ = try await undoLedger.beginUndoWindow(record.id) }
        do {
            try await undoWindow.wait()
        } catch {
            if let undoLedger { _ = try? await undoLedger.markCancelled(record.id, reason: "用户在发送前撤销") }
            throw GmailError.permissionDenied("发送已在撤销窗口取消，未调用 Gmail")
        }
        var activeGrant = grant
        do {
            if let grants {
                guard let current = await grants.gmailGrant(), current == grant else {
                    throw GmailError.permissionDenied("Gmail grant 已变化，发送未执行")
                }
                activeGrant = current
                try await authorizeSend(input, caller: caller, grant: activeGrant)
            }
            try await ledger.markCommitting(record.id)
        } catch {
            if let undoLedger { _ = try? await undoLedger.markCancelled(record.id, reason: "发送前授权已变化") }
            throw error
        }
        do {
            let body = SendRequestDTO(input: input, operationID: record.id, digest: input.digest)
            let response: SendResponseDTO = try await client.post(
                path: "/gmail/v1/users/me/messages/send", body: body,
                grant: activeGrant, requiredAction: input.kind.action)
            return try await commit(record.id, id: response.id,
                                    raw: ["id": response.id, "threadID": response.threadId])
        } catch let error as GmailError where error == .timeout || error == .transport {
            try await ledger.markUnknown(record.id, reason: "发送超时或网络中断；不会自动重发")
            throw GmailError.outcomeUnknown
        }
    }

    private func authorizeWithHost(descriptor: ConnectorToolDescriptor, argumentsJSON: String,
                                   caller: ToolCaller, grant: ConnectorGrant) async throws -> OperationIntent {
        switch await gate.authorize(tool: descriptor, argumentsJSON: argumentsJSON, caller: caller, grant: grant) {
        case .allow(let intent): return intent
        case .requireDSHApproval: throw GmailError.approvalRequired
        case .requireTargetSelection: throw GmailError.permissionDenied("请先选择明确的 Gmail 目标")
        case .downgradeToDraft(let reason): throw GmailError.permissionDenied("只能创建草稿：\(reason)")
        case .deny(let denial): throw GmailError.permissionDenied(denial.message)
        }
    }

    private func commit(_ id: UUID, id providerID: String, raw: [String: String]) async throws -> ProviderReceipt {
        let rawJSON = String(decoding: (try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])),
                             as: UTF8.self)
        let receipt = ProviderReceipt(providerObjectID: providerID,
                                      url: "https://mail.google.com/mail/#all/\(providerID)", rawJSON: rawJSON)
        try await ledger.commit(id, receipt: receipt)
        return receipt
    }

    private static func authorizeDraft(_ input: GmailDraftInput, caller: ToolCaller,
                                       grant: ConnectorGrant, now: Date) async throws {
        try validateMessage(input, grant: grant)
        try GmailProductScopeGate.authorizeEndpoint(path: "/gmail/v1/users/me/drafts",
                                                    action: .gmailCreateDraft, grant: grant)
        let mandate = try personalMandate(caller)
        guard mandate.validUntil > now, mandate.allowedActions.contains(.gmailCreateDraft),
              mandate.source != .device, principal(mandate, matches: grant) else {
            throw GmailError.permissionDenied("本次委托不允许创建或更新 Gmail 草稿")
        }
        try validateEvidence(input.evidenceRefs, mandate: mandate)
    }

    private func authorizeSend(_ input: GmailSendInput, caller: ToolCaller,
                               grant: ConnectorGrant) async throws {
        try Self.validateMessage(input.draft, grant: grant)
        try GmailProductScopeGate.authorizeEndpoint(path: "/gmail/v1/users/me/messages/send",
                                                    action: input.kind.action, grant: grant)
        let mandate = try Self.personalMandate(caller)
        guard mandate.validUntil > now(), mandate.allowedActions.contains(input.kind.action),
              mandate.targets.origin != .modelInferred, mandate.source != .device,
              Self.principal(mandate, matches: grant) else {
            throw GmailError.permissionDenied("本次委托不允许该 Gmail 发送类型、账号或目标")
        }
        try Self.validateEvidence(input.draft.evidenceRefs, mandate: mandate)
        let recipients = Set((input.draft.recipients + input.draft.cc + input.draft.bcc).map(Self.normalizedAddress))
        let named = Set(mandate.targets.recipientIdentities.map(Self.normalizedAddress))
        guard input.kind == .reply || (!named.isEmpty && recipients.isSubset(of: named)) else {
            throw GmailError.permissionDenied("新邮件和转发只能发给用户点名的收件人")
        }
        switch input.kind {
        case .new:
            guard input.draft.threadID == nil, input.draft.inReplyTo == nil, input.draft.references == nil else {
                throw GmailError.permissionDenied("新邮件不能借用线程回复参数")
            }
        case .forward:
            guard let threadID = input.draft.threadID,
                  mandate.targets.gmailThreadIDs.contains(threadID) else {
                throw GmailError.permissionDenied("转发原线程不在本次委托范围内")
            }
        case .reply:
            guard let threadID = input.draft.threadID,
                  mandate.targets.gmailThreadIDs.contains(threadID) else {
                throw GmailError.permissionDenied("回复线程不在本次委托范围内")
            }
            let thread = try await client.thread(id: threadID, includeBody: false)
            let participants = Set(thread.messages.flatMap { [$0.from] + $0.to }.map(Self.normalizedAddress))
            guard recipients.isSubset(of: participants.union(named)) else {
                throw GmailError.permissionDenied("回复收件人超出线程参与者或用户点名范围")
            }
        }
    }

    private static func personalMandate(_ caller: ToolCaller) throws -> WorkMandate {
        switch caller {
        case .personalAgent(let mandate): return mandate
        case .dshDirect: throw GmailError.approvalRequired
        case .delegatedDSH: throw GmailError.permissionDenied("委派 token 尚未由宿主核验，写入已拒绝")
        }
    }

    private static func principal(_ mandate: WorkMandate, matches grant: ConnectorGrant) -> Bool {
        guard let account = grant.scope.gmailAccount else { return false }
        return mandate.principal.caseInsensitiveCompare(account) == .orderedSame
    }

    private static func validateMessage(_ input: GmailDraftInput, grant: ConnectorGrant) throws {
        let recipients = input.recipients + input.cc + input.bcc
        guard !input.recipients.isEmpty, recipients.count <= grant.rateLimit.maxRecipients,
              recipients.allSatisfy(isValidAddress), !input.subject.contains(where: \.isNewline),
              input.subject.utf8.count <= 998, input.body.utf8.count <= 256 * 1024,
              !input.body.contains("\u{0}") else {
            throw GmailError.invalidArguments("收件人、主题或正文不符合限制")
        }
        for value in [input.inReplyTo, input.references, input.threadID] {
            if let value, value.contains(where: \.isNewline) { throw GmailError.invalidArguments("邮件头含换行") }
        }
    }

    private static func validateEvidence(_ refs: [String], mandate: WorkMandate) throws {
        let allowed = Set(mandate.allowedEvidenceRefs.map(\.id))
        guard Set(refs).isSubset(of: allowed) else {
            throw GmailError.permissionDenied("正文引用了本次委托之外的资料")
        }
    }

    private static func isValidAddress(_ value: String) -> Bool {
        let address = normalizedAddress(value)
        guard !address.isEmpty, !address.contains(where: \.isNewline), address.contains("@") else { return false }
        let parts = address.split(separator: "@")
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
    }

    internal static func normalizedAddress(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let left = trimmed.lastIndex(of: "<"), let right = trimmed.lastIndex(of: ">"), left < right {
            return String(trimmed[trimmed.index(after: left)..<right]).lowercased()
        }
        return trimmed.lowercased()
    }
}

private struct DraftRequestDTO: Encodable {
    struct Message: Encodable { let raw: String; let threadId: String? }
    let message: Message

    init(input: GmailDraftInput) {
        message = Message(raw: GmailMIME.rawMessage(input: input, operationID: nil, digest: nil),
                          threadId: input.threadID)
    }
}

private struct SendRequestDTO: Encodable {
    let raw: String
    let threadId: String?

    init(input: GmailSendInput, operationID: UUID, digest: String) {
        raw = GmailMIME.rawMessage(input: input.draft, operationID: operationID, digest: digest)
        threadId = input.draft.threadID
    }
}

private struct DraftResponseDTO: Decodable {
    struct Message: Decodable { let id: String }
    let id: String
    let message: Message
}
private struct SendResponseDTO: Decodable { let id: String; let threadId: String }

public enum GmailMIME {
    public static func rawMessage(input: GmailDraftInput, operationID: UUID?, digest: String?) -> String {
        var headers = ["To: \(input.recipients.joined(separator: ", "))", "Subject: \(input.subject)",
                       "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8",
                       "Content-Transfer-Encoding: 8bit"]
        if !input.cc.isEmpty { headers.append("Cc: \(input.cc.joined(separator: ", "))") }
        if !input.bcc.isEmpty { headers.append("Bcc: \(input.bcc.joined(separator: ", "))") }
        if let reply = input.inReplyTo { headers.append("In-Reply-To: \(reply)") }
        if let references = input.references { headers.append("References: \(references)") }
        if let operationID {
            headers.append("Message-ID: <\(operationID.uuidString.lowercased())@phone-dsh.invalid>")
            headers.append("X-PhoneDSH-Operation-ID: \(operationID.uuidString.lowercased())")
        }
        if let digest { headers.append("X-PhoneDSH-Request-Digest: \(digest)") }
        let raw = (headers.joined(separator: "\r\n") + "\r\n\r\n" + input.body)
        return GmailOAuthFlow.base64URL(Data(raw.utf8))
    }

    public static func plaintext(raw: String) -> String? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
