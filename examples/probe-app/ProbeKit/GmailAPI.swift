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
        let profile: Profile = try await get("profile", token: token)
        guard !profile.emailAddress.isEmpty else { throw GmailError.invalidResponse }
        return profile.emailAddress
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

    private struct Profile: Decodable { let emailAddress: String }
    private struct Reference: Decodable { let id: String }
    private struct Listing: Decodable {
        let messages: [Reference]?
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
