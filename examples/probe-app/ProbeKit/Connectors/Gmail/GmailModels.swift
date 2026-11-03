// SPDX-License-Identifier: MIT

import Foundation

public enum GmailScope {
    public static let readOnly = "https://www.googleapis.com/auth/gmail.readonly"
    public static let compose = "https://www.googleapis.com/auth/gmail.compose"
}

public enum GmailLimits {
    public static let maximumSearchResults = 50
    public static let maximumResponseBytes = 2 * 1024 * 1024
    public static let maximumBodyCharacters = 64_000
    public static let processedMessageIDs = 1_000
    public static let derivedSummaryLifetime: TimeInterval = 7 * 24 * 60 * 60
}

public enum GmailError: Error, Equatable, Sendable {
    case notConfigured
    case disconnected
    case expired
    case revoked
    case invalidArguments(String)
    case invalidState
    case permissionDenied(String)
    case approvalRequired
    case timeout
    case transport
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
    case outcomeUnknown
}

extension GmailError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置 OAuth 客户端"
        case .disconnected: return "Gmail 尚未连接"
        case .expired: return "Gmail 授权已过期，请重新授权"
        case .revoked: return "Gmail 授权已撤销"
        case .invalidArguments(let detail): return "Gmail 参数无效：\(detail)"
        case .invalidState: return "OAuth 回调校验失败"
        case .permissionDenied(let detail): return detail
        case .approvalRequired: return "DSH 直接写入需要逐项审批"
        case .timeout: return "Gmail 请求超时，结果待对账"
        case .transport: return "Gmail 网络请求未完成"
        case .httpStatus(let status): return "Gmail 服务返回 HTTP \(status)"
        case .responseTooLarge: return "Gmail 响应超过大小上限"
        case .invalidResponse: return "Gmail 返回了无效响应"
        case .outcomeUnknown: return "发送结果未知，正在确认最终结果；不会自动重发"
        }
    }
}

public struct GmailOAuthConfiguration: Sendable, Equatable {
    public let clientID: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(clientID: String, redirectURI: URL, scopes: [String] = [GmailScope.readOnly]) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public var callbackScheme: String? { redirectURI.scheme }
}

public struct GmailTokenSet: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scopes: [String]

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }
}

public struct GmailSearchQuery: Codable, Sendable, Equatable {
    public var since: Date?
    public var until: Date?
    public var unreadOnly: Bool
    public var sender: String?
    public var subject: String?
    public var sentOnly: Bool
    public var rfc822MessageID: String?
    public var limit: Int
    public var pageToken: String?

    public init(since: Date? = nil, until: Date? = nil, unreadOnly: Bool = false,
                sender: String? = nil, subject: String? = nil, sentOnly: Bool = false,
                rfc822MessageID: String? = nil, limit: Int = 20, pageToken: String? = nil) {
        self.since = since
        self.until = until
        self.unreadOnly = unreadOnly
        self.sender = sender
        self.subject = subject
        self.sentOnly = sentOnly
        self.rfc822MessageID = rfc822MessageID
        self.limit = limit
        self.pageToken = pageToken
    }

    public var gmailQuery: String {
        var terms: [String] = []
        if let since { terms.append("after:\(Int(since.timeIntervalSince1970))") }
        if let until { terms.append("before:\(Int(until.timeIntervalSince1970))") }
        if unreadOnly { terms.append("is:unread") }
        if sentOnly { terms.append("in:sent") }
        if let sender, !sender.isEmpty { terms.append("from:\(Self.quote(sender))") }
        if let subject, !subject.isEmpty { terms.append("subject:\(Self.quote(subject))") }
        if let rfc822MessageID, !rfc822MessageID.isEmpty {
            terms.append("rfc822msgid:\(Self.quote(rfc822MessageID))")
        }
        return terms.joined(separator: " ")
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

public struct GmailMessage: Codable, Sendable, Equatable {
    public let id: String
    public let threadID: String
    public let historyID: String?
    public let internalDate: Date?
    public let snippet: String
    public let subject: String
    public let from: String
    public let to: [String]
    public let rfc822MessageID: String?
    public let operationID: String?
    public let requestDigest: String?
    public let body: String?
    public let link: URL

    public init(id: String, threadID: String, historyID: String?, internalDate: Date?, snippet: String,
                subject: String, from: String, to: [String], rfc822MessageID: String?,
                operationID: String?, requestDigest: String?, body: String?, link: URL) {
        self.id = id
        self.threadID = threadID
        self.historyID = historyID
        self.internalDate = internalDate
        self.snippet = snippet
        self.subject = subject
        self.from = from
        self.to = to
        self.rfc822MessageID = rfc822MessageID
        self.operationID = operationID
        self.requestDigest = requestDigest
        self.body = body
        self.link = link
    }
}

public struct GmailThread: Codable, Sendable, Equatable {
    public let id: String
    public let historyID: String?
    public let messages: [GmailMessage]
    public let truncated: Bool
    public let link: URL

    public init(id: String, historyID: String?, messages: [GmailMessage], truncated: Bool = false, link: URL) {
        self.id = id
        self.historyID = historyID
        self.messages = messages
        self.truncated = truncated
        self.link = link
    }
}

public struct GmailSearchResult: Codable, Sendable, Equatable {
    public let messages: [GmailMessage]
    public let nextPageToken: String?

    public init(messages: [GmailMessage], nextPageToken: String?) {
        self.messages = messages
        self.nextPageToken = nextPageToken
    }
}

public struct GmailProfile: Codable, Sendable, Equatable {
    public let emailAddress: String
    public let historyID: String

    public init(emailAddress: String, historyID: String) {
        self.emailAddress = emailAddress
        self.historyID = historyID
    }
}

public enum GmailJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
