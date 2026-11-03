// SPDX-License-Identifier: MIT

import Foundation

public struct GmailFollowUpChecker: FollowUpChecker {
    public let targetKind: FollowUpTarget.Kind = .gmailThread
    private let client: any GmailReading
    private let incremental: GmailIncrementalSynchronizer
    private let now: @Sendable () -> Date

    public init(client: any GmailReading, incremental: GmailIncrementalSynchronizer,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.incremental = incremental
        self.now = now
    }

    public func check(_ followUp: FollowUp, since cursor: String?) async -> FollowUpCheckResult {
        let checkedAt = now()
        if let pausedUntil = followUp.pausedUntil, pausedUntil > checkedAt {
            return FollowUpCheckResult(changed: false, cursor: cursor, lastVerifiedAt: checkedAt)
        }
        if let validUntil = followUp.validUntil, validUntil <= checkedAt {
            return FollowUpCheckResult(changed: false, cursor: cursor, lastVerifiedAt: checkedAt)
        }
        do {
            if followUp.nextCheckCondition.expression == "newMail" {
                let result = try await incremental.synchronize()
                let summary = result.newMessages.isEmpty ? nil : "Gmail 有 \(result.newMessages.count) 封新邮件"
                return FollowUpCheckResult(changed: !result.newMessages.isEmpty, summary: summary,
                                           cursor: result.state.historyID,
                                           needsAttention: !result.newMessages.isEmpty, lastVerifiedAt: checkedAt)
            }
            guard let threadID = followUp.target.threadID else {
                return FollowUpCheckResult(changed: false, summary: "Gmail 跟进缺少线程", cursor: cursor,
                                           needsAttention: true, lastVerifiedAt: checkedAt)
            }
            let thread = try await client.thread(id: threadID, includeBody: false)
            let ids = Set(thread.messages.map(\.id))
            let previous = Self.cursorIDs(cursor)
            let added = previous == nil ? [] : ids.subtracting(previous ?? []).sorted()
            let nextCursor = Self.cursor(ids: ids)
            return FollowUpCheckResult(changed: !added.isEmpty,
                                       summary: added.isEmpty ? nil : "指定 Gmail 线程有 \(added.count) 条新回复",
                                       cursor: nextCursor, needsAttention: !added.isEmpty, lastVerifiedAt: checkedAt)
        } catch {
            return FollowUpCheckResult(changed: false, summary: error.localizedDescription, cursor: cursor,
                                       needsAttention: true, lastVerifiedAt: checkedAt)
        }
    }

    private static func cursorIDs(_ cursor: String?) -> Set<String>? {
        guard let cursor, let data = cursor.data(using: .utf8),
              let ids = try? JSONDecoder().decode([String].self, from: data) else { return nil }
        return Set(ids)
    }

    private static func cursor(ids: Set<String>) -> String? {
        guard let data = try? JSONEncoder().encode(ids.sorted()) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
