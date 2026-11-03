// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_GitHubFollowUpTests: XCTestCase {
    func testOnlyNewBlockersAreReportedAndCursorPersists() async throws {
        let credentials = InMemoryConnectorCredentials()
        try credentials.saveCredential("test-only-secret", for: "github.pat")
        let transport = MockConnectorHTTPTransport()
        await stubPull(transport, reviews: "[]", conclusion: "success")
        let store = InMemoryConnectorStore()
        let checker = GitHubFollowUpChecker(client: GitHubClient(transport: transport, credentials: credentials),
                                            store: store,
                                            now: { Date(timeIntervalSince1970: 1_762_000_000) })
        let followUp = FollowUp(goal: "只告诉我新阻塞",
                                target: FollowUpTarget(kind: .githubPR, repository: "owner/repo", number: 7),
                                nextCheckCondition: CheckCondition(expression: "new_blockers"),
                                stopCondition: StopCondition(expression: "closed"))
        let baseline = await checker.check(followUp, since: nil)
        XCTAssertFalse(baseline.changed)
        XCTAssertNotNil(baseline.cursor)

        let review = #"[{"id":1,"state":"CHANGES_REQUESTED","body":"fix","submitted_at":"2026-11-03T00:00:00Z","html_url":"https://github.com/review/1","user":{"login":"octo"}}]"#
        await stubPull(transport, reviews: review, conclusion: "failure")
        let changed = await checker.check(followUp, since: nil)
        XCTAssertTrue(changed.changed)
        XCTAssertTrue(changed.needsAttention)
        XCTAssertTrue(changed.summary?.contains("请求修改") == true)
        XCTAssertTrue(changed.summary?.contains("Checks") == true)

        let unchanged = await checker.check(followUp, since: nil)
        XCTAssertFalse(unchanged.changed)
        XCTAssertNil(unchanged.summary)
        XCTAssertEqual(unchanged.lastVerifiedAt, Date(timeIntervalSince1970: 1_762_000_000))

        let reloaded = GitHubFollowUpChecker(client: GitHubClient(transport: transport, credentials: credentials),
                                             store: store,
                                             now: { Date(timeIntervalSince1970: 1_762_000_000) })
        let afterReload = await reloaded.check(followUp, since: nil)
        XCTAssertFalse(afterReload.changed)
    }

    private func stubPull(_ transport: MockConnectorHTTPTransport,
                          reviews: String, conclusion: String) async {
        await transport.stub("/repos/owner/repo/pulls/7", json: githubPullJSON)
        await transport.stub("/repos/owner/repo/issues/7/comments", json: "[]")
        await transport.stub("/repos/owner/repo/pulls/7/comments", json: "[]")
        await transport.stub("/repos/owner/repo/pulls/7/reviews", json: reviews)
        let checks = #"{"check_runs":[{"id":1,"name":"build","status":"completed","conclusion":"\#(conclusion)","head_sha":"abcdef1234567890","html_url":"https://github.com/check/1","details_url":null}]}"#
        await transport.stub("/repos/owner/repo/commits/abcdef1234567890/check-runs", json: checks)
    }
}
