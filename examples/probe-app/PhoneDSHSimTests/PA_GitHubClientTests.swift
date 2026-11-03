// SPDX-License-Identifier: MIT

import Foundation
import ProbeKit
import XCTest

final class PA_GitHubClientTests: XCTestCase {
    private func makeClient(_ transport: MockConnectorHTTPTransport) -> GitHubClient {
        let credentials = InMemoryConnectorCredentials()
        try! credentials.saveCredential("test-only-secret", for: "github.pat")
        return GitHubClient(transport: transport, credentials: credentials)
    }

    func testRepositoryAndExactHostCredentialInjection() async throws {
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo", json: githubRepositoryJSON)
        let repository = try await makeClient(transport).repository("owner/repo")
        XCTAssertEqual(repository.fullName, "owner/repo")
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url, "https://api.github.com/repos/owner/repo")
        XCTAssertTrue(requests[0].hasAuthorization)
        XCTAssertFalse(requests[0].url.contains("test-only-secret"))
    }

    func testIssueCommentsPaginationIsBounded() async throws {
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/issues/7", json: githubIssueJSON)
        let first = (1...100).map { #"{"id":\#($0),"body":"c","html_url":"https://github.com/c/\#($0)","created_at":"2026-11-03T00:00:00Z","user":{"login":"o"}}"# }.joined(separator: ",")
        await transport.stub("/repos/owner/repo/issues/7/comments", json: "[\(first)]")
        await transport.stub("/repos/owner/repo/issues/7/comments", json: "[]", append: true)
        let snapshot = try await makeClient(transport).issue(repository: "owner/repo", number: 7, commentLimit: 100)
        XCTAssertEqual(snapshot.comments.count, 100)
        XCTAssertFalse(snapshot.commentsTruncated)
        let paths = await transport.snapshot().map(\.url)
        XCTAssertTrue(paths.contains { $0.contains("page=2") })
    }

    func testErrorMappingDistinguishesAuthorizationVisibilityPermissionAndRateLimit() async throws {
        for (status, headers, expected) in [
            (401, [:], GitHubClientError.unauthorized),
            (403, [:], GitHubClientError.forbidden),
            (404, [:], GitHubClientError.notFound),
            (429, [:], GitHubClientError.rateLimited),
            (403, ["x-ratelimit-remaining": "0"], GitHubClientError.rateLimited),
        ] {
            let transport = MockConnectorHTTPTransport()
            await transport.stub("/repos/owner/repo", status: status, headers: headers)
            do {
                _ = try await makeClient(transport).repository("owner/repo")
                XCTFail("HTTP \(status) must fail")
            } catch let error as GitHubClientError {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testDiffTruncatesAndChecksBindCurrentHeadSHA() async throws {
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo/pulls/7", json: githubPullJSON)
        let files = #"[{"filename":"a.swift","status":"modified","additions":3,"deletions":1,"changes":4,"patch":"abcdefghij"}]"#
        await transport.stub("/repos/owner/repo/pulls/7/files", json: files)
        let diff = try await makeClient(transport).diff(repository: "owner/repo", number: 7,
                                                        maximumPatchBytes: 4)
        XCTAssertEqual(diff.files[0].file.patch, "abcd")
        XCTAssertTrue(diff.files[0].patchTruncated)
        XCTAssertTrue(diff.truncated)

        let checks = #"{"check_runs":[{"id":1,"name":"new","status":"completed","conclusion":"success","head_sha":"abcdef1234567890","html_url":"https://github.com/check/1","details_url":null},{"id":2,"name":"old","status":"completed","conclusion":"failure","head_sha":"1234567890abcdef","html_url":null,"details_url":null}]}"#
        await transport.stub("/repos/owner/repo/commits/abcdef1234567890/check-runs", json: checks)
        let snapshot = try await makeClient(transport).checks(repository: "owner/repo", number: 7)
        XCTAssertEqual(snapshot.headSHA, "abcdef1234567890")
        XCTAssertEqual(snapshot.checkRuns.map(\.id), [1])
    }

    func testNetworkFailureAndInvalidRepositoryAreNotEmptySuccess() async throws {
        let transport = MockConnectorHTTPTransport()
        await transport.stub("/repos/owner/repo", failure: .networkUnavailable)
        do {
            _ = try await makeClient(transport).repository("owner/repo")
            XCTFail("network failure must throw")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .networkUnavailable)
        }
        do {
            _ = try await makeClient(transport).repository("owner/repo?access_token=test-only-secret")
            XCTFail("credential-bearing repository input must fail")
        } catch let error as GitHubClientError {
            XCTAssertEqual(error, .invalidRepository)
        }
    }
}
