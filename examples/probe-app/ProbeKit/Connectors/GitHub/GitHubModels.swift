// SPDX-License-Identifier: MIT

import Foundation

public struct GitHubActor: Codable, Sendable, Equatable {
    public var login: String
}

public struct GitHubRepository: Codable, Sendable, Equatable {
    public var fullName: String
    public var isPrivate: Bool
    public var htmlURL: String
    public var defaultBranch: String

    private enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case isPrivate = "private"
        case htmlURL = "html_url"
        case defaultBranch = "default_branch"
    }
}

public struct GitHubIssue: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var body: String?
    public var htmlURL: String
    public var user: GitHubActor?
    public var createdAt: String
    public var updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case number, title, state, body, user
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct GitHubComment: Codable, Sendable, Equatable {
    public var id: Int64
    public var body: String
    public var htmlURL: String
    public var createdAt: String
    public var user: GitHubActor?

    private enum CodingKeys: String, CodingKey {
        case id, body, user
        case htmlURL = "html_url"
        case createdAt = "created_at"
    }
}

public struct GitHubReview: Codable, Sendable, Equatable {
    public var id: Int64
    public var state: String
    public var body: String?
    public var submittedAt: String?
    public var htmlURL: String
    public var user: GitHubActor?

    private enum CodingKeys: String, CodingKey {
        case id, state, body, user
        case submittedAt = "submitted_at"
        case htmlURL = "html_url"
    }
}

public struct GitHubBranch: Codable, Sendable, Equatable {
    public var ref: String
    public var sha: String
}

public struct GitHubPullRequest: Codable, Sendable, Equatable {
    public var number: Int
    public var title: String
    public var state: String
    public var body: String?
    public var htmlURL: String
    public var head: GitHubBranch
    public var base: GitHubBranch
    public var user: GitHubActor?
    public var draft: Bool?

    private enum CodingKeys: String, CodingKey {
        case number, title, state, body, head, base, user, draft
        case htmlURL = "html_url"
    }
}

public struct GitHubFile: Codable, Sendable, Equatable {
    public var filename: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var changes: Int
    public var patch: String?
}

public struct GitHubCheckRun: Codable, Sendable, Equatable {
    public var id: Int64
    public var name: String
    public var status: String
    public var conclusion: String?
    public var headSHA: String
    public var htmlURL: String?
    public var detailsURL: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case detailsURL = "details_url"
    }
}

public struct GitHubIssueSnapshot: Codable, Sendable, Equatable {
    public var issue: GitHubIssue
    public var comments: [GitHubComment]
    public var commentsTruncated: Bool
}

public struct GitHubPullSnapshot: Codable, Sendable, Equatable {
    public var pull: GitHubPullRequest
    public var issueComments: [GitHubComment]
    public var reviews: [GitHubReview]
    public var reviewComments: [GitHubComment]
    public var truncated: Bool
}

public struct GitHubDiffFile: Codable, Sendable, Equatable {
    public var file: GitHubFile
    public var patchTruncated: Bool
}

public struct GitHubDiffSummary: Codable, Sendable, Equatable {
    public var repository: String
    public var number: Int
    public var headSHA: String
    public var sourceURL: String
    public var files: [GitHubDiffFile]
    public var truncated: Bool
    public var totalAdditions: Int
    public var totalDeletions: Int
}

public struct GitHubChecksSnapshot: Codable, Sendable, Equatable {
    public var repository: String
    public var number: Int
    public var headSHA: String
    public var sourceURL: String
    public var checkRuns: [GitHubCheckRun]
    public var truncated: Bool
}

public struct GitHubWriteReceipt: Codable, Sendable, Equatable {
    public var providerObjectID: String
    public var url: String
    public var number: Int?
}
