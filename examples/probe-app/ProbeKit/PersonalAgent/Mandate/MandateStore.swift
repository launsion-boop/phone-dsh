// SPDX-License-Identifier: MIT

import Foundation

public struct MandateDraft: Sendable, Equatable {
    public var goal: String
    public var allowedActions: Set<MandateAction>
    public var allowedEvidenceRefs: Set<EvidenceRef>
    public var targets: MandateTargets
    public var validUntil: Date

    public init(goal: String, allowedActions: Set<MandateAction> = [.read],
                allowedEvidenceRefs: Set<EvidenceRef> = [], targets: MandateTargets, validUntil: Date) {
        self.goal = goal
        self.allowedActions = allowedActions
        self.allowedEvidenceRefs = allowedEvidenceRefs
        self.targets = targets
        self.validUntil = validUntil
    }
}

public enum MandateStoreError: Error, Equatable {
    case requestAlreadyHasDifferentMandate
    case invalidVersion
    case missingPreviousMandate
}

public actor MandateStore {
    private struct State: Codable {
        var byRequestID: [UUID: WorkMandate] = [:]
        var byID: [UUID: WorkMandate] = [:]
    }

    private let fileURL: URL
    private var state: State

    public init(root: URL) throws {
        fileURL = root.appendingPathComponent("mandate/mandates.json")
        state = try S4Persistence.load(State.self, from: fileURL) ?? State()
    }

    @discardableResult
    public func issue(envelope: SourceEnvelope, draft: MandateDraft) throws -> WorkMandate {
        if let existing = state.byRequestID[envelope.requestID] { return existing }
        let mandate = WorkMandate(
            mandateID: UUID(), version: 1, requestID: envelope.requestID,
            principal: envelope.principal, source: envelope.source, goal: draft.goal,
            allowedActions: draft.allowedActions.isEmpty ? [.read] : draft.allowedActions,
            allowedEvidenceRefs: draft.allowedEvidenceRefs, targets: draft.targets,
            validUntil: draft.validUntil)
        try persistInsert(mandate)
        return mandate
    }

    public func revise(previous: WorkMandate, envelope: SourceEnvelope, draft: MandateDraft) throws -> WorkMandate {
        guard let current = state.byID[previous.mandateID] else { throw MandateStoreError.missingPreviousMandate }
        guard current == previous, state.byRequestID[envelope.requestID] == nil else {
            throw MandateStoreError.invalidVersion
        }
        guard envelope.principal == previous.principal, envelope.source == previous.source else {
            throw MandateStoreError.invalidVersion
        }
        let mandate = WorkMandate(
            mandateID: previous.mandateID, version: previous.version + 1, requestID: envelope.requestID,
            principal: envelope.principal, source: envelope.source, goal: draft.goal,
            allowedActions: draft.allowedActions.isEmpty ? [.read] : draft.allowedActions,
            allowedEvidenceRefs: draft.allowedEvidenceRefs, targets: draft.targets,
            validUntil: draft.validUntil)
        try persistInsert(mandate)
        return mandate
    }

    public func mandate(for requestID: UUID) -> WorkMandate? {
        state.byRequestID[requestID]
    }

    public func mandate(id: UUID) -> WorkMandate? {
        state.byID[id]
    }

    public func all() -> [WorkMandate] {
        state.byRequestID.values.sorted { lhs, rhs in
            if lhs.mandateID == rhs.mandateID { return lhs.version < rhs.version }
            return lhs.mandateID.uuidString < rhs.mandateID.uuidString
        }
    }

    private func persistInsert(_ mandate: WorkMandate) throws {
        var updated = state
        updated.byRequestID[mandate.requestID] = mandate
        updated.byID[mandate.mandateID] = mandate
        try S4Persistence.save(updated, to: fileURL)
        state = updated
    }
}

public struct RuleBasedMandateFactory: Sendable {
    public let validityInterval: TimeInterval

    public init(validityInterval: TimeInterval = 15 * 60) {
        self.validityInterval = validityInterval
    }

    public func draft(userText: String, now: Date = Date()) -> MandateDraft {
        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        let clauses = authoritativeClauses(text)
        var actions: Set<MandateAction> = [.read]

        for clause in clauses {
            if containsAny(clause, ["github.comment", "comment on", "发表评论", "请评论", "帮我评论", "替我评论", "评论这", "评论该"]) {
                actions.insert(.githubComment)
            }
            if containsAny(clause, ["create issue", "open issue", "创建 issue", "开 issue", "新建 issue"]) {
                actions.insert(.githubCreateIssue)
            }
            if containsAny(clause, ["git push", "push commit", "推送提交", "推送代码"]) {
                actions.insert(.githubPush)
            }
            if containsAny(clause, ["open pr", "create pr", "open pull request", "创建 pr", "开 pr"]) {
                actions.insert(.githubOpenPR)
            }
            if containsAny(clause, ["create draft", "创建草稿", "新建草稿", "生成草稿"]) {
                actions.insert(.gmailCreateDraft)
            }
            if containsAny(clause, ["替我回复", "帮我回复", "请回复", "回复这", "回复该"])
                || clause.hasPrefix("reply to ") || clause.hasPrefix("reply in ") {
                actions.insert(.gmailReplyInThread)
            }
            if containsAny(clause, ["替我转发", "帮我转发", "请转发", "forward this", "forward the"]) {
                actions.insert(.gmailForward)
            }
            if containsAny(clause, ["替我发送", "帮我发送", "请发送", "发送新邮件", "send an email", "send email"]) {
                actions.insert(.gmailSendNew)
            }
            if containsAny(clause, ["rename assistant", "rename the assistant", "修改助手名字", "给助手改名", "给你改名"]) {
                actions.insert(.personalProfileWrite)
            }
            if containsAny(clause, ["remember ", "save this preference", "记住", "记下", "修改偏好", "保存偏好", "删除记忆", "忘记这条"]) {
                actions.insert(.personalMemoryWrite)
            }
            if containsAny(clause, ["create followup", "create follow-up", "创建跟进", "新建跟进", "完成跟进", "取消跟进"]) {
                actions.insert(.personalFollowUpWrite)
            }
            if containsAny(clause, ["record suggestion", "记录建议交互"]) {
                actions.insert(.personalSuggestionHistoryWrite)
            }
            if containsAny(clause, ["create schedule", "schedule a", "remind me", "创建定时", "新建定时", "提醒我", "修改定时", "取消定时"]) {
                actions.insert(.personalScheduleWrite)
            }
        }

        let repository = firstMatch(#"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"#, in: text)
        let numbers = matches(#"#([0-9]+)"#, in: text).compactMap(Int.init)
        let recipients = matches(#"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, in: text)
            .map { $0.lowercased() }
        let threadIDs = matches(#"(?:thread(?:id)?|线程)\s*[:#]?\s*([A-Za-z0-9_-]+)"#, in: lowered)
        let hasWrite = actions.contains(where: { $0 != .read })
        let hasExplicitTarget = repository != nil || !numbers.isEmpty || !recipients.isEmpty || !threadIDs.isEmpty
        let origin: TargetOrigin = hasWrite && !hasExplicitTarget ? .modelInferred : .userNamed
        let evidence = matches(#"evidence:([A-Za-z0-9_.:-]+)"#, in: text).map {
            EvidenceRef(id: $0, kind: "user", locator: "user://\($0)")
        }

        return MandateDraft(
            goal: text, allowedActions: actions, allowedEvidenceRefs: Set(evidence),
            targets: MandateTargets(gmailThreadIDs: threadIDs, recipientIdentities: recipients,
                                    repository: repository, issueOrPRNumbers: numbers, origin: origin),
            validUntil: now.addingTimeInterval(validityInterval))
    }

    private func authoritativeClauses(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { ";；\n!?！？".contains($0) }).compactMap { raw in
            let clause = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clause.isEmpty else { return nil }
            if containsAny(clause, ["do not", "don't", "never ", "avoid ", "without ", "不要", "别", "禁止", "无需", "不用", "不能", "不可以", "不应"]) {
                return nil
            }
            if containsAny(clause, ["should i", "could you", "would you", "can you explain", "what if", "why ", "how to"]) {
                return nil
            }
            if containsAny(clause, ["写着", "引用", "转述", "quoted", "says:", "said:", "邮件正文", "以下内容"]) {
                return nil
            }
            let hasExplicitChineseCommand = containsAny(clause, ["请", "帮我", "替我", "给我"])
            let hasEnglishCommand = ["comment ", "create ", "open ", "send ", "reply ", "forward ", "push ", "remember ", "schedule ", "remind "]
                .contains(where: clause.hasPrefix)
            if containsAny(clause, ["only ", "just ", "summar", "analy", "只", "查看", "检查", "读取", "整理", "解释", "说明"]),
               !hasExplicitChineseCommand, !hasEnglishCommand {
                return nil
            }
            return clause
        }
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        matches(pattern, in: text).first
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            let capture = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard capture.location != NSNotFound, let swiftRange = Range(capture, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
