// SPDX-License-Identifier: MIT

import Foundation

private struct GitHubFollowUpCursor: Codable, Sendable, Equatable {
    var headSHA: String
    var reviewIDs: Set<Int64>
    var issueCommentIDs: Set<Int64>
    var reviewCommentIDs: Set<Int64>
    var checks: [String: String]
}

public actor GitHubFollowUpChecker: FollowUpChecker {
    public let targetKind: FollowUpTarget.Kind = .githubPR
    private let client: GitHubClient
    private let store: (any ConnectorKeyValueStore)?
    private let now: @Sendable () -> Date

    public init(client: GitHubClient,
                store: (any ConnectorKeyValueStore)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.store = store
        self.now = now
    }

    public func check(_ followUp: FollowUp, since cursor: String?) async -> FollowUpCheckResult {
        let checkedAt = now()
        guard followUp.target.kind == .githubPR,
              let repository = followUp.target.repository,
              let number = followUp.target.number else {
            return FollowUpCheckResult(changed: false, summary: "GitHub 跟进目标无效",
                                       cursor: cursor, needsAttention: true, lastVerifiedAt: checkedAt)
        }
        if let pausedUntil = followUp.pausedUntil, pausedUntil > checkedAt {
            return FollowUpCheckResult(changed: false, cursor: cursor, lastVerifiedAt: checkedAt)
        }
        do {
            async let pullRequest = client.pull(repository: repository, number: number, commentLimit: 100)
            async let checksRequest = client.checks(repository: repository, number: number)
            let snapshot = try await pullRequest
            let checks = try await checksRequest
            guard checks.headSHA == snapshot.pull.head.sha else {
                return FollowUpCheckResult(changed: false, summary: "PR 在检查期间更新，请再次核验",
                                           cursor: cursor, needsAttention: true, lastVerifiedAt: checkedAt)
            }
            let current = GitHubFollowUpCursor(
                headSHA: snapshot.pull.head.sha,
                reviewIDs: Set(snapshot.reviews.map(\.id)),
                issueCommentIDs: Set(snapshot.issueComments.map(\.id)),
                reviewCommentIDs: Set(snapshot.reviewComments.map(\.id)),
                checks: Dictionary(uniqueKeysWithValues: checks.checkRuns.map {
                    (String($0.id), "\($0.status):\($0.conclusion ?? "")")
                }))
            let encoded = try String(decoding: JSONEncoder().encode(current), as: UTF8.self)
            let storedCursor = try store?.string(forKey: key(followUp.id))
            let previousCursor = cursor ?? storedCursor
            guard let previousCursor,
                  let previousData = previousCursor.data(using: .utf8),
                  let previous = try? JSONDecoder().decode(GitHubFollowUpCursor.self, from: previousData) else {
                try store?.setString(encoded, forKey: key(followUp.id))
                return FollowUpCheckResult(changed: false, cursor: encoded, lastVerifiedAt: checkedAt)
            }
            let newReviews = snapshot.reviews.filter { !previous.reviewIDs.contains($0.id) }
            let newIssueComments = snapshot.issueComments.filter { !previous.issueCommentIDs.contains($0.id) }
            let newReviewComments = snapshot.reviewComments.filter { !previous.reviewCommentIDs.contains($0.id) }
            let changedChecks = current.checks.filter { previous.checks[$0.key] != $0.value }
            let blockingReviews = newReviews.filter { $0.state.uppercased() == "CHANGES_REQUESTED" }
            let blockingChecks = checks.checkRuns.filter { run in
                changedChecks[String(run.id)] != nil && Self.blockingConclusions.contains(run.conclusion ?? "")
            }
            let headChanged = current.headSHA != previous.headSHA
            let blockersOnly = Self.blockersOnly(followUp.nextCheckCondition.expression)
            let ordinaryChange = !newReviews.isEmpty || !newIssueComments.isEmpty ||
                !newReviewComments.isEmpty || !changedChecks.isEmpty || headChanged
            let blockingChange = !blockingReviews.isEmpty || !blockingChecks.isEmpty
            let changed = blockersOnly ? blockingChange : ordinaryChange
            var sentences: [String] = []
            if !blockingReviews.isEmpty { sentences.append("新增 \(blockingReviews.count) 条请求修改的 review") }
            if !blockingChecks.isEmpty { sentences.append("新增或变为阻塞的 Checks：\(blockingChecks.map(\.name).joined(separator: ", "))") }
            if !blockersOnly {
                if headChanged { sentences.append("PR head 已更新为 \(current.headSHA.prefix(12))") }
                if !newReviews.isEmpty { sentences.append("新增 \(newReviews.count) 条 review") }
                if !newIssueComments.isEmpty { sentences.append("新增 \(newIssueComments.count) 条评论") }
                if !newReviewComments.isEmpty { sentences.append("新增 \(newReviewComments.count) 条行内评论") }
                if !changedChecks.isEmpty && blockingChecks.isEmpty { sentences.append("Checks 状态有变化") }
            }
            try store?.setString(encoded, forKey: key(followUp.id))
            return FollowUpCheckResult(changed: changed,
                                       summary: changed ? sentences.joined(separator: "；") : nil,
                                       cursor: encoded, needsAttention: blockingChange,
                                       lastVerifiedAt: checkedAt)
        } catch let error as GitHubClientError {
            return FollowUpCheckResult(changed: false, summary: error.message, cursor: cursor,
                                       needsAttention: true, lastVerifiedAt: checkedAt)
        } catch {
            return FollowUpCheckResult(changed: false, summary: "GitHub 跟进检查失败",
                                       cursor: cursor, needsAttention: true, lastVerifiedAt: checkedAt)
        }
    }

    private func key(_ id: UUID) -> String { "followup:\(id.uuidString)" }

    private static let blockingConclusions: Set<String> = [
        "failure", "timed_out", "action_required", "cancelled", "startup_failure",
    ]

    private static func blockersOnly(_ expression: String) -> Bool {
        let normalized = expression.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "new_blockers" || normalized == "blockers_only" || expression == "只告诉我新阻塞"
    }
}
