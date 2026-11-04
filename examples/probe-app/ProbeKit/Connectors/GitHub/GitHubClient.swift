// SPDX-License-Identifier: MIT

import Foundation

public enum GitHubClientError: Error, Equatable, Sendable {
    case invalidRepository
    case invalidNumber
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case providerUnavailable(Int)
    case invalidResponse
    case responseTooLarge
    case notConfigured
    case networkUnavailable

    public var code: String {
        switch self {
        case .invalidRepository: return "invalid_repository"
        case .invalidNumber: return "invalid_number"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .rateLimited: return "rate_limited"
        case .providerUnavailable: return "provider_unavailable"
        case .invalidResponse: return "invalid_response"
        case .responseTooLarge: return "response_too_large"
        case .notConfigured: return "not_configured"
        case .networkUnavailable: return "network_unavailable"
        }
    }

    public var message: String {
        switch self {
        case .invalidRepository: return "仓库必须使用 owner/name 格式"
        case .invalidNumber: return "Issue 或 PR 编号必须大于零"
        case .unauthorized: return "GitHub 凭据无效、已过期或已撤权，请重新配置"
        case .forbidden: return "GitHub 拒绝了此操作；当前仓库或所需能力可能没有权限"
        case .notFound: return "GitHub 未返回该资源；资源不存在或当前凭据不可见"
        case .rateLimited: return "GitHub API 已限流，请稍后重试"
        case .providerUnavailable(let status): return "GitHub 服务暂不可用（HTTP \(status)）"
        case .invalidResponse: return "GitHub 返回了无法解析的响应"
        case .responseTooLarge: return "GitHub 响应超过大小限制"
        case .notConfigured: return "GitHub 尚未配置 PAT"
        case .networkUnavailable: return "无法连接 GitHub，请检查网络后重试"
        }
    }
}

private struct GitHubCollection<T: Decodable>: Sendable where T: Sendable {
    let items: [T]
    let truncated: Bool
}

private struct GitHubCheckRunsResponse: Decodable {
    let checkRuns: [GitHubCheckRun]
    private enum CodingKeys: String, CodingKey { case checkRuns = "check_runs" }
}

public struct GitHubClient: Sendable {
    public static let apiHost = "api.github.com"

    private let http: ConnectorHTTPClient
    private let credentialRef: String
    private let decoder = JSONDecoder()

    public init(transport: any ConnectorHTTPTransport,
                credentials: any ConnectorCredentialStore,
                credentialRef: String = "github.pat",
                limits: ConnectorHTTPLimits = ConnectorHTTPLimits()) {
        self.init(http: ConnectorHTTPClient(host: Self.apiHost,
                                            allowedHosts: [Self.apiHost],
                                            transport: transport,
                                            credentials: credentials,
                                            limits: limits),
                  credentialRef: credentialRef)
    }

    public init(http: ConnectorHTTPClient, credentialRef: String = "github.pat") {
        self.http = http
        self.credentialRef = credentialRef
    }

    public func verify(repositories: [String]) async throws -> GitHubActor {
        let actor: GitHubActor = try await get("/user")
        for repository in repositories { _ = try await self.repository(repository) }
        return actor
    }

    public func repository(_ repository: String) async throws -> GitHubRepository {
        try await get("/repos/\(try repositoryPath(repository))")
    }

    public func issue(repository: String, number: Int,
                      commentLimit: Int = 20) async throws -> GitHubIssueSnapshot {
        let path = try issuePath(repository, number: number)
        async let issueRequest: GitHubIssue = get(path)
        async let commentsRequest: GitHubCollection<GitHubComment> = collection(
            path: path + "/comments", limit: commentLimit)
        let issue = try await issueRequest
        let comments = try await commentsRequest
        return GitHubIssueSnapshot(issue: truncating(issue),
                                   comments: comments.items.map(truncating),
                                   commentsTruncated: comments.truncated)
    }

    public func pull(repository: String, number: Int,
                     commentLimit: Int = 20) async throws -> GitHubPullSnapshot {
        let path = try pullPath(repository, number: number)
        async let pullRequest: GitHubPullRequest = get(path)
        async let issueCommentsRequest: GitHubCollection<GitHubComment> = collection(
            path: "/repos/\(try repositoryPath(repository))/issues/\(number)/comments", limit: commentLimit)
        async let reviewsRequest: GitHubCollection<GitHubReview> = collection(
            path: path + "/reviews", limit: commentLimit)
        async let reviewCommentsRequest: GitHubCollection<GitHubComment> = collection(
            path: path + "/comments", limit: commentLimit)
        let pull = try await pullRequest
        let issueComments = try await issueCommentsRequest
        let reviews = try await reviewsRequest
        let reviewComments = try await reviewCommentsRequest
        return GitHubPullSnapshot(pull: truncating(pull),
                                  issueComments: issueComments.items.map(truncating),
                                  reviews: reviews.items.map(truncating),
                                  reviewComments: reviewComments.items.map(truncating),
                                  truncated: issueComments.truncated || reviews.truncated || reviewComments.truncated)
    }

    public func diff(repository: String, number: Int,
                     maximumPatchBytes: Int = 32_768) async throws -> GitHubDiffSummary {
        let pull: GitHubPullRequest = try await get(try pullPath(repository, number: number))
        let files = try await collection(path: try pullPath(repository, number: number) + "/files",
                                         limit: 100) as GitHubCollection<GitHubFile>
        let budget = max(0, min(maximumPatchBytes, 65_536))
        var remaining = budget
        var patchTruncated = false
        let summaries = files.items.map { file -> GitHubDiffFile in
            guard let patch = file.patch else { return GitHubDiffFile(file: file, patchTruncated: false) }
            let bytes = Data(patch.utf8)
            let take = min(remaining, bytes.count)
            remaining -= take
            let truncated = take < bytes.count
            patchTruncated = patchTruncated || truncated
            let prefix = String(decoding: bytes.prefix(take), as: UTF8.self)
            var bounded = file
            bounded.patch = prefix
            return GitHubDiffFile(file: bounded, patchTruncated: truncated)
        }
        return GitHubDiffSummary(repository: repository, number: number, headSHA: pull.head.sha,
                                 sourceURL: pull.htmlURL, files: summaries,
                                 truncated: files.truncated || patchTruncated,
                                 totalAdditions: files.items.reduce(0) { $0 + $1.additions },
                                 totalDeletions: files.items.reduce(0) { $0 + $1.deletions })
    }

    public func checks(repository: String, number: Int) async throws -> GitHubChecksSnapshot {
        let pull: GitHubPullRequest = try await get(try pullPath(repository, number: number))
        let sha = pull.head.sha
        guard sha.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil else {
            throw GitHubClientError.invalidResponse
        }
        let response: GitHubCheckRunsResponse = try await get(
            "/repos/\(try repositoryPath(repository))/commits/\(sha)/check-runs",
            query: [URLQueryItem(name: "per_page", value: "100")])
        let current = response.checkRuns.filter { $0.headSHA == sha }
        return GitHubChecksSnapshot(repository: repository, number: number, headSHA: sha,
                                    sourceURL: pull.htmlURL, checkRuns: current,
                                    truncated: response.checkRuns.count == 100)
    }

    public func createComment(repository: String, number: Int,
                              body: String) async throws -> GitHubWriteReceipt {
        let data = try JSONSerialization.data(withJSONObject: ["body": body])
        let comment: GitHubComment = try await send("/repos/\(try repositoryPath(repository))/issues/\(number)/comments",
                                                     method: "POST", body: data, expectedStatus: 201)
        return GitHubWriteReceipt(providerObjectID: String(comment.id), url: comment.htmlURL, number: nil)
    }

    public func recentIssues(repository: String, limit: Int = 100) async throws -> [GitHubIssue] {
        let result: GitHubCollection<GitHubIssue> = try await collection(
            path: "/repos/\(try repositoryPath(repository))/issues", limit: limit)
        return result.items
    }

    public func createIssue(repository: String, title: String,
                            body: String) async throws -> GitHubWriteReceipt {
        let data = try JSONSerialization.data(withJSONObject: ["title": title, "body": body])
        let issue: GitHubIssue = try await send("/repos/\(try repositoryPath(repository))/issues",
                                                method: "POST", body: data, expectedStatus: 201)
        return GitHubWriteReceipt(providerObjectID: String(issue.number), url: issue.htmlURL, number: issue.number)
    }

    private func get<T: Decodable & Sendable>(_ path: String,
                                              query: [URLQueryItem] = []) async throws -> T {
        try await send(path, query: query, expectedStatus: 200)
    }

    private func collection<T: Decodable & Sendable>(path: String,
                                                     limit: Int) async throws -> GitHubCollection<T> {
        let boundedLimit = max(1, min(limit, 100))
        let perPage = 100
        var items: [T] = []
        for page in 1...10 {
            let batch: [T] = try await get(path, query: [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: String(page)),
            ])
            items.append(contentsOf: batch)
            if items.count >= boundedLimit && boundedLimit < perPage {
                return GitHubCollection(items: Array(items.prefix(boundedLimit)), truncated: true)
            }
            if batch.count < perPage {
                return GitHubCollection(items: Array(items.prefix(boundedLimit)),
                                        truncated: items.count > boundedLimit)
            }
        }
        return GitHubCollection(items: Array(items.prefix(boundedLimit)), truncated: true)
    }

    private func send<T: Decodable & Sendable>(_ path: String,
                                               method: String = "GET",
                                               query: [URLQueryItem] = [],
                                               body: Data? = nil,
                                               expectedStatus: Int) async throws -> T {
        do {
            let response = try await http.request(path: path, method: method, query: query, body: body,
                                                  credentialRef: credentialRef,
                                                  additionalHeaders: ["X-GitHub-Api-Version": "2022-11-28"])
            guard response.statusCode == expectedStatus else { throw map(response) }
            return try decoder.decode(T.self, from: response.data)
        } catch let error as GitHubClientError {
            throw error
        } catch let error as ConnectorHTTPError {
            throw map(error)
        } catch is DecodingError {
            throw GitHubClientError.invalidResponse
        } catch {
            throw GitHubClientError.invalidResponse
        }
    }

    private func map(_ response: ConnectorHTTPResponse) -> GitHubClientError {
        if response.statusCode == 401 { return .unauthorized }
        if response.statusCode == 404 { return .notFound }
        if response.statusCode == 429 || response.statusCode == 403,
           response.headers["x-ratelimit-remaining"] == "0" || response.statusCode == 429 {
            return .rateLimited
        }
        if response.statusCode == 403 { return .forbidden }
        if response.statusCode >= 500 { return .providerUnavailable(response.statusCode) }
        return .invalidResponse
    }

    private func map(_ error: ConnectorHTTPError) -> GitHubClientError {
        switch error {
        case .missingCredential: return .notConfigured
        case .responseTooLarge: return .responseTooLarge
        case .networkUnavailable: return .networkUnavailable
        default: return .invalidResponse
        }
    }

    private func repositoryPath(_ repository: String) throws -> String {
        let parts = repository.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
              }) else { throw GitHubClientError.invalidRepository }
        return parts.joined(separator: "/")
    }

    private func issuePath(_ repository: String, number: Int) throws -> String {
        guard number > 0 else { throw GitHubClientError.invalidNumber }
        return "/repos/\(try repositoryPath(repository))/issues/\(number)"
    }

    private func pullPath(_ repository: String, number: Int) throws -> String {
        guard number > 0 else { throw GitHubClientError.invalidNumber }
        return "/repos/\(try repositoryPath(repository))/pulls/\(number)"
    }

    private func truncating(_ issue: GitHubIssue) -> GitHubIssue {
        var copy = issue
        copy.body = issue.body.map(boundedText)
        return copy
    }

    private func truncating(_ pull: GitHubPullRequest) -> GitHubPullRequest {
        var copy = pull
        copy.body = pull.body.map(boundedText)
        return copy
    }

    private func truncating(_ comment: GitHubComment) -> GitHubComment {
        var copy = comment
        copy.body = boundedText(comment.body)
        return copy
    }

    private func truncating(_ review: GitHubReview) -> GitHubReview {
        var copy = review
        copy.body = review.body.map(boundedText)
        return copy
    }

    private func boundedText(_ text: String) -> String {
        String(decoding: Data(text.utf8).prefix(12_000), as: UTF8.self)
    }
}
