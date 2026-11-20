// SPDX-License-Identifier: MIT

import Foundation

public enum GmailError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case notFound
    case invalidResponse
    case serviceUnavailable
}

public struct GmailAPI: Sendable {
    public struct Summary: Identifiable, Sendable, Equatable {
        public let id: String
        public let sender: String
        public let subject: String
        public let date: Date?
    }

    public struct Page: Sendable {
        public let messages: [Summary]
        public let nextPageToken: String?
    }

    /// The mailbox identity and the current `historyId`. The connector delta
    /// scan stores that `historyId` as its first cursor: the first scan only
    /// establishes the cursor and never treats old mail as new.
    public struct Mailbox: Sendable, Equatable {
        public let emailAddress: String
        public let historyId: String
    }

    /// Metadata-only result of one `users.history.list` pass.
    ///
    /// `messages` carries at most `limit` summaries; `count` is how many new
    /// message ids the history page named. No message body is ever fetched by
    /// this path (`format=metadata` only), so the connector scan stays
    /// metadata-only even for a mailbox with large messages.
    public struct HistoryDelta: Sendable, Equatable {
        public let historyId: String
        public let count: Int
        public let messages: [Summary]
    }

    public struct Message: Sendable {
        public enum Body: Equatable, Sendable {
            case plain(String)
            case html(String)
            case unavailable
        }

        public let summary: Summary
        public let body: Body
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 30
            self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        }
    }

    public func accountEmail(token: String) async throws -> String {
        try await mailbox(token: token).emailAddress
    }

    /// The account's email plus its current `historyId`. A caller that is about
    /// to start a delta scan stores the `historyId` as the baseline; it must
    /// never replay the mailbox's existing messages as new.
    public func mailbox(token: String) async throws -> Mailbox {
        let profile: Profile = try await get("profile", token: token)
        guard !profile.emailAddress.isEmpty else { throw GmailError.invalidResponse }
        let historyId = profile.historyId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !historyId.isEmpty, Self.isHistoryId(historyId) else { throw GmailError.invalidResponse }
        return Mailbox(emailAddress: profile.emailAddress, historyId: historyId)
    }

    public func search(_ query: String, pageToken: String? = nil, token: String) async throws -> Page {
        var items = [URLQueryItem(name: "maxResults", value: "12")]
        if query.isEmpty {
            items.append(.init(name: "labelIds", value: "INBOX"))
        } else {
            items.append(.init(name: "q", value: query))
        }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let listing: Listing = try await get("messages", query: items, token: token)
        let messages = try await withThrowingTaskGroup(of: (Int, Summary?).self) { group in
            for (index, reference) in (listing.messages ?? []).enumerated() {
                group.addTask {
                    do {
                        let raw: RawMessage = try await getMessage(reference.id, format: "metadata", token: token)
                        return (index, raw.summary)
                    } catch GmailError.notFound {
                        return (index, nil)
                    }
                }
            }
            var summaries: [(Int, Summary?)] = []
            for try await row in group { summaries.append(row) }
            return summaries.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }
        return Page(messages: messages, nextPageToken: listing.nextPageToken)
    }

    public func message(id: String, token: String) async throws -> Message {
        let raw: RawMessage = try await getMessage(id, format: "full", token: token)
        return Message(summary: raw.summary, body: raw.payload?.messageBody ?? .unavailable)
    }

    /// Metadata-only incremental query for the connector delta scan.
    ///
    /// `users.history.list` with `startHistoryId` names the messages added to
    /// the inbox since that cursor. Message ids are then fetched with
    /// `format=metadata` (From/Subject only); no message body is requested or
    /// retained. A `404` means the server no longer holds history from that
    /// cursor (the caller resets to a fresh baseline); `count` is how many new
    /// inbox message ids this page named, and `messages` holds at most `limit`
    /// summaries so one scan can never materialize a whole mailbox.
    public func history(startHistoryId: String, limit: Int = 20,
                        token: String) async throws -> HistoryDelta {
        guard Self.isHistoryId(startHistoryId), startHistoryId != "0" else {
            throw GmailError.invalidResponse
        }
        let capped = min(20, max(1, limit))
        let query: [URLQueryItem] = [
            URLQueryItem(name: "startHistoryId", value: startHistoryId),
            URLQueryItem(name: "historyTypes", value: "messageAdded"),
            URLQueryItem(name: "labelId", value: "INBOX"),
            URLQueryItem(name: "maxResults", value: String(capped)),
        ]
        let listing: HistoryListing = try await get("history", query: query, token: token)
        var ids: [String] = []
        var seen = Set<String>()
        var latest = startHistoryId
        for entry in listing.history ?? [] {
            if let entryID = entry.id, Self.isHistoryId(entryID),
               Self.historyIDValue(entryID) > Self.historyIDValue(latest) {
                latest = entryID
            }
            for added in entry.messagesAdded ?? [] {
                let message = added.message
                guard !message.id.isEmpty else { continue }
                if let labels = message.labelIds, !labels.contains("INBOX") { continue }
                if seen.insert(message.id).inserted { ids.append(message.id) }
            }
        }
        let selected = Array(ids.prefix(capped))
        let summaries = try await metadataSummaries(selected, token: token)
        // `count` always describes the items actually carried (removed messages
        // and label mismatches contribute nothing), so a consumer can assert
        // `count == messages.count` without re-counting.
        return HistoryDelta(historyId: latest, count: summaries.count, messages: summaries)
    }

    private func metadataSummaries(_ ids: [String], token: String) async throws -> [Summary] {
        guard !ids.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Summary?).self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    do {
                        let raw: RawMessage = try await getMessage(id, format: "metadata", token: token)
                        return (index, raw.summary)
                    } catch GmailError.notFound {
                        // A message removed between the history page and the
                        // metadata read is not an error and contributes no row.
                        return (index, nil)
                    }
                }
            }
            var rows: [(Int, Summary?)] = []
            for try await row in group { rows.append(row) }
            return rows.sorted { $0.0 < $1.0 }.compactMap { $0.1 }
        }
    }

    /// Gmail ids are uint64 values encoded as decimal strings.
    static func isHistoryId(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 20 else { return false }
        guard value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return UInt64(value) != nil
    }

    private static func historyIDValue(_ value: String) -> UInt64 {
        UInt64(value) ?? 0
    }

    private func getMessage(_ id: String, format: String, token: String) async throws -> RawMessage {
        guard !id.isEmpty, id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { throw GmailError.invalidResponse }
        let query = [URLQueryItem(name: "format", value: format)] + (format == "metadata"
            ? ["From", "Subject"].map { .init(name: "metadataHeaders", value: $0) }
            : [])
        return try await get("messages/\(id)", query: query, token: token)
    }

    private func get<Response: Decodable>(
        _ path: String, query: [URLQueryItem] = [], token: String
    ) async throws -> Response {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "gmail.googleapis.com"
        components.path = "/gmail/v1/users/me/" + path
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw GmailError.invalidResponse }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GmailError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw GmailError.unauthorized
        case 403: throw GmailError.forbidden
        case 404: throw GmailError.notFound
        default: throw GmailError.serviceUnavailable
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw GmailError.invalidResponse
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }

    private struct Profile: Decodable {
        let emailAddress: String
        /// The mailbox's current history record. Absent on very old fixtures;
        /// `mailbox(token:)` then refuses instead of inventing a cursor.
        let historyId: String?
    }
    private struct Reference: Decodable {
        let id: String
        let labelIds: [String]?
    }
    private struct Listing: Decodable {
        let messages: [Reference]?
        let nextPageToken: String?
    }

    private struct HistoryListing: Decodable {
        struct Entry: Decodable {
            struct Added: Decodable {
                let message: Reference
            }

            let id: String?
            let messagesAdded: [Added]?
        }

        let history: [Entry]?
        let nextPageToken: String?
    }

    private struct RawMessage: Decodable {
        let id: String
        let internalDate: String?
        let payload: Part?

        var summary: Summary {
            Summary(
                id: id, sender: payload?.header("From") ?? "", subject: payload?.header("Subject") ?? "",
                date: internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
            )
        }
    }

    private struct Part: Decodable {
        struct Header: Decodable { let name: String; let value: String }
        struct EncodedBody: Decodable { let data: String? }
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: EncodedBody?
        let parts: [Part]?

        func header(_ name: String) -> String? {
            headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        var messageBody: Message.Body {
            if let plain = text("text/plain") { return .plain(plain) }
            if let html = text("text/html") { return .html(html) }
            return .unavailable
        }

        private func text(_ mime: String) -> String? {
            if let filename, !filename.isEmpty { return nil }
            if header("Content-Disposition")?.lowercased().hasPrefix("attachment") == true { return nil }
            if mimeType?.lowercased() == mime, let encoded = body?.data {
                var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
                guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count <= 2_000_000 else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            guard mimeType?.lowercased().hasPrefix("multipart/") == true else { return nil }
            return parts?.lazy.compactMap { $0.text(mime) }.first
        }
    }
}
