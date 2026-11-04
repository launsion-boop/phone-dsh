// SPDX-License-Identifier: MIT

import Foundation

public struct GmailHistoryChange: Sendable, Equatable {
    public let messagesAdded: [String]
    public let historyID: String

    public init(messagesAdded: [String], historyID: String) {
        self.messagesAdded = messagesAdded
        self.historyID = historyID
    }
}

public struct GmailDraftSnapshot: Sendable, Equatable {
    public let id: String
    public let messageID: String
    public let raw: String

    public init(id: String, messageID: String, raw: String) {
        self.id = id
        self.messageID = messageID
        self.raw = raw
    }
}

public protocol GmailReading: Sendable {
    func search(_ query: GmailSearchQuery) async throws -> GmailSearchResult
    func message(id: String, includeBody: Bool) async throws -> GmailMessage
    func thread(id: String, includeBody: Bool) async throws -> GmailThread
    func history(startHistoryID: String) async throws -> GmailHistoryChange
    func profile() async throws -> GmailProfile
}

public struct GmailClient: GmailReading {
    private let tokens: GmailTokenManager
    private let transport: any GmailHTTPTransport

    public init(tokens: GmailTokenManager, transport: any GmailHTTPTransport) {
        self.tokens = tokens
        self.transport = transport
    }

    public func search(_ query: GmailSearchQuery) async throws -> GmailSearchResult {
        guard (1...GmailLimits.maximumSearchResults).contains(query.limit) else {
            throw GmailError.invalidArguments("limit 必须在 1...\(GmailLimits.maximumSearchResults)")
        }
        var parameters = ["maxResults": String(query.limit), "includeSpamTrash": "false"]
        if !query.gmailQuery.isEmpty { parameters["q"] = query.gmailQuery }
        if let pageToken = query.pageToken { parameters["pageToken"] = pageToken }
        let list: MessageListDTO = try await get(path: "/gmail/v1/users/me/messages", query: parameters)
        var messages: [GmailMessage] = []
        for reference in list.messages ?? [] {
            messages.append(try await message(id: reference.id, includeBody: false))
        }
        return GmailSearchResult(messages: messages, nextPageToken: list.nextPageToken)
    }

    public func message(id: String, includeBody: Bool) async throws -> GmailMessage {
        let id = try Self.pathComponent(id, name: "message id")
        let query = ["format": includeBody ? "full" : "metadata"]
        let repeated = includeBody ? [:] : ["metadataHeaders": Self.metadataHeaders]
        let dto: MessageDTO = try await get(path: "/gmail/v1/users/me/messages/\(id)", query: query,
                                            repeatedQuery: repeated)
        return try Self.message(from: dto, includeBody: includeBody)
    }

    public func thread(id: String, includeBody: Bool) async throws -> GmailThread {
        let id = try Self.pathComponent(id, name: "thread id")
        let query = ["format": includeBody ? "full" : "metadata"]
        let repeated = includeBody ? [:] : ["metadataHeaders": Self.metadataHeaders]
        let dto: ThreadDTO = try await get(path: "/gmail/v1/users/me/threads/\(id)", query: query,
                                           repeatedQuery: repeated)
        return GmailThread(id: dto.id, historyID: dto.historyId,
                           messages: try dto.messages.prefix(GmailLimits.maximumSearchResults).map {
                               try Self.message(from: $0, includeBody: includeBody)
                           }, truncated: dto.messages.count > GmailLimits.maximumSearchResults,
                           link: try Self.link(id: dto.id))
    }

    public func history(startHistoryID: String) async throws -> GmailHistoryChange {
        guard !startHistoryID.isEmpty else { throw GmailError.invalidArguments("缺少 historyId") }
        var pageToken: String?
        var latestHistoryID = startHistoryID
        var added: [String] = []
        for _ in 0..<5 {
            var query = ["startHistoryId": startHistoryID, "historyTypes": "messageAdded",
                         "maxResults": String(GmailLimits.maximumSearchResults)]
            query["pageToken"] = pageToken
            let dto: HistoryDTO = try await get(path: "/gmail/v1/users/me/history", query: query)
            added.append(contentsOf: (dto.history ?? []).flatMap { entry in
                (entry.messagesAdded ?? []).map(\.message.id)
            })
            latestHistoryID = dto.historyId
            guard let next = dto.nextPageToken else {
                return GmailHistoryChange(messagesAdded: Array(Set(added)).sorted(), historyID: latestHistoryID)
            }
            pageToken = next
        }
        throw GmailError.responseTooLarge
    }

    public func recentDrafts() async throws -> [GmailDraftSnapshot] {
        let list: DraftListDTO = try await get(path: "/gmail/v1/users/me/drafts",
                                               query: ["maxResults": "100", "includeSpamTrash": "false"])
        var snapshots: [GmailDraftSnapshot] = []
        for reference in list.drafts ?? [] {
            let draft: DraftDTO = try await get(path: "/gmail/v1/users/me/drafts/\(try Self.pathComponent(reference.id, name: "draft id"))",
                                                query: ["format": "raw"])
            guard let raw = draft.message.raw else { throw GmailError.invalidResponse }
            snapshots.append(GmailDraftSnapshot(id: draft.id, messageID: draft.message.id, raw: raw))
        }
        return snapshots
    }

    public func profile() async throws -> GmailProfile {
        let dto: ProfileDTO = try await get(path: "/gmail/v1/users/me/profile")
        return GmailProfile(emailAddress: dto.emailAddress, historyID: dto.historyId)
    }

    internal func post<Body: Encodable, Response: Decodable>(path: String, body: Body,
                                                             grant: ConnectorGrant,
                                                             requiredAction: MandateAction) async throws -> Response {
        try GmailProductScopeGate.authorizeEndpoint(path: path, action: requiredAction, grant: grant)
        return try await send(method: "POST", path: path, body: body)
    }

    internal func put<Body: Encodable, Response: Decodable>(path: String, body: Body,
                                                            grant: ConnectorGrant,
                                                            requiredAction: MandateAction) async throws -> Response {
        try GmailProductScopeGate.authorizeEndpoint(path: path, action: requiredAction, grant: grant)
        return try await send(method: "PUT", path: path, body: body)
    }

    private func get<Response: Decodable>(path: String, query: [String: String] = [:],
                                          repeatedQuery: [String: [String]] = [:]) async throws -> Response {
        try await send(method: "GET", path: path, query: query, repeatedQuery: repeatedQuery)
    }

    private func send<Response: Decodable>(method: String, path: String, query: [String: String] = [:],
                                           repeatedQuery: [String: [String]] = [:],
                                           body: (any Encodable)? = nil) async throws -> Response {
        try await tokens.withValidAccessToken { accessToken in
            var encodedBody: Data?
            if let body { encodedBody = try GmailJSON.encoder.encode(body) }
            var headers = ["Authorization": "Bearer \(accessToken)", "Accept": "application/json"]
            if encodedBody != nil { headers["Content-Type"] = "application/json" }
            let request = GmailHTTPRequest(method: method, path: path, query: query, repeatedQuery: repeatedQuery,
                                           headers: headers, body: encodedBody)
            let response = try await transport.send(request)
            try Self.validate(response)
            do {
                return try GmailJSON.decoder.decode(Response.self, from: response.data)
            } catch {
                throw GmailError.invalidResponse
            }
        }
    }

    private static func validate(_ response: GmailHTTPResponse) throws {
        guard !(200...299).contains(response.statusCode) else { return }
        switch response.statusCode {
        case 401: throw GmailError.expired
        case 403: throw GmailError.permissionDenied("Gmail 当前账号或 scope 不允许此操作")
        default: throw GmailError.httpStatus(response.statusCode)
        }
    }

    private static func message(from dto: MessageDTO, includeBody: Bool) throws -> GmailMessage {
        let headers = Dictionary(uniqueKeysWithValues: (dto.payload?.headers ?? []).map {
            ($0.name.lowercased(), $0.value)
        })
        let milliseconds = dto.internalDate.flatMap(Double.init)
        let body = includeBody ? extractBody(dto.payload) : nil
        let recipients = [headers["to"], headers["cc"]].compactMap { $0 }.joined(separator: ",")
        return GmailMessage(
            id: dto.id, threadID: dto.threadId, historyID: dto.historyId,
            internalDate: milliseconds.map { Date(timeIntervalSince1970: $0 / 1000) }, snippet: dto.snippet ?? "",
            subject: headers["subject"] ?? "", from: headers["from"] ?? "",
            to: addresses(recipients), rfc822MessageID: headers["message-id"],
            operationID: headers["x-phonedsh-operation-id"], requestDigest: headers["x-phonedsh-request-digest"],
            body: body, link: try link(id: dto.id))
    }

    private static func extractBody(_ payload: PayloadDTO?) -> String? {
        guard let payload else { return nil }
        if payload.mimeType == "text/plain", let data = decodeBody(payload.body?.data) {
            return String(String(decoding: data, as: UTF8.self).prefix(GmailLimits.maximumBodyCharacters))
        }
        for part in payload.parts ?? [] {
            if let body = extractBody(part) { return body }
        }
        return nil
    }

    private static func decodeBody(_ value: String?) -> Data? {
        guard let value else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        return Data(base64Encoded: base64)
    }

    private static func addresses(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static let metadataHeaders = [
        "Subject", "From", "To", "Cc", "Message-ID", "X-PhoneDSH-Operation-ID", "X-PhoneDSH-Request-Digest",
    ]

    private static func pathComponent(_ value: String, name: String) throws -> String {
        guard !value.isEmpty, value.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }) else {
            throw GmailError.invalidArguments("\(name) 含非法字符")
        }
        return value
    }

    private static func link(id: String) throws -> URL {
        guard let url = URL(string: "https://mail.google.com/mail/#all/\(id)") else { throw GmailError.invalidResponse }
        return url
    }
}

private struct ReferenceDTO: Decodable { let id: String }
private struct MessageListDTO: Decodable {
    let messages: [ReferenceDTO]?
    let nextPageToken: String?
}
private struct HeaderDTO: Decodable { let name: String; let value: String }
private struct BodyDTO: Decodable { let data: String? }
private struct PayloadDTO: Decodable {
    let mimeType: String?
    let headers: [HeaderDTO]?
    let body: BodyDTO?
    let parts: [PayloadDTO]?
}
private struct MessageDTO: Decodable {
    let id: String
    let threadId: String
    let historyId: String?
    let internalDate: String?
    let snippet: String?
    let payload: PayloadDTO?
    let raw: String?
}
private struct DraftListDTO: Decodable { let drafts: [ReferenceDTO]? }
private struct DraftDTO: Decodable { let id: String; let message: MessageDTO }
private struct ThreadDTO: Decodable {
    let id: String
    let historyId: String?
    let messages: [MessageDTO]
}
private struct ProfileDTO: Decodable { let emailAddress: String; let historyId: String }
private struct HistoryEntryDTO: Decodable { let messagesAdded: [AddedMessageDTO]? }
private struct AddedMessageDTO: Decodable { let message: ReferenceDTO }
private struct HistoryDTO: Decodable {
    let history: [HistoryEntryDTO]?
    let historyId: String
    let nextPageToken: String?
}

public enum GmailProductScopeGate {
    public static func authorizeEndpoint(path: String, action: MandateAction,
                                         grant: ConnectorGrant) throws {
        guard grant.connectorID == "gmail", !grant.paused,
              grant.scope.gmailAccount?.isEmpty == false,
              grant.scope.rawScopes.contains(GmailScope.compose),
              grant.allowedActions.contains(action) else {
            throw GmailError.permissionDenied("Gmail 产品 grant 不允许此写操作")
        }
        if path.hasSuffix("/messages/send") || path.hasSuffix("/drafts/send") {
            let sendActions: Set<MandateAction> = [.gmailReplyInThread, .gmailSendNew, .gmailForward]
            guard grant.allowedActions.contains(where: sendActions.contains) else {
                throw GmailError.permissionDenied("仅授予草稿权限，宿主拒绝 messages.send 和 drafts.send")
            }
        }
    }
}
