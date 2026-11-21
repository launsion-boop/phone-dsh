// SPDX-License-Identifier: MIT

import Foundation

public enum GitHubConnectorError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden
    case rateLimited
    case invalidResponse
    case serviceUnavailable
}

public struct GitHubConnectorAPI: Sendable {
    public struct Account: Equatable, Sendable {
        public let login: String
    }

    public struct Repository: Identifiable, Equatable, Sendable {
        public let id: Int
        public let name: String
        public let fullName: String
        public let htmlURL: URL
    }

    public struct Page: Equatable, Sendable {
        public let repositories: [Repository]
        public let nextPage: Int?
    }

    /// One notification's metadata. The subject title and repository name are
    /// what the held-inbox item carries; the notification body/thread is never
    /// fetched by the connector scan.
    public struct Notification: Identifiable, Equatable, Sendable {
        public let id: String
        public let repositoryFullName: String
        public let title: String
        public let type: String
        public let updatedAt: Date?
        public let unread: Bool
    }

    /// One incremental `GET /notifications` result.
    ///
    /// `lastModified` is the response's `Last-Modified` header (the next
    /// `If-Modified-Since` value). `notModified` is a `304`: nothing changed,
    /// keep the cursor and emit no item.
    public struct NotificationsPage: Equatable, Sendable {
        public let notifications: [Notification]
        public let lastModified: String?
        public let notModified: Bool
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// GitHub App user access tokens issued by the broker: the `ghu_` prefix
    /// plus 1 to 251 ASCII letters, digits or underscores. A legacy PAT or a
    /// malformed value is rejected before it can be sent anywhere.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8)
        guard (5...255).contains(bytes.count), token.hasPrefix("ghu_") else { return false }
        return bytes.dropFirst(4).allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95
        }
    }

    public func account(token: String) async throws -> Account {
        let (data, _) = try await get("user", query: [], token: token)
        let user: User = try decode(User.self, from: data)
        guard !user.login.isEmpty else { throw GitHubConnectorError.invalidResponse }
        return Account(login: user.login)
    }

    public func repositories(page: Int = 1, token: String) async throws -> Page {
        guard page > 0, page < Int.max else { throw GitHubConnectorError.invalidResponse }
        let query = [
            URLQueryItem(name: "per_page", value: "30"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        let (data, response) = try await get("user/repos", query: query, token: token)
        let repositories = try decode([RawRepository].self, from: data).map { try $0.repository() }
        return Page(
            repositories: repositories,
            nextPage: Self.hasNextPage(response.value(forHTTPHeaderField: "Link")) ? page + 1 : nil
        )
    }

    /// Metadata-only incremental query for the connector delta scan.
    ///
    /// `since` is the stored ISO-8601 scan watermark; `ifModifiedSince` is the
    /// stored `Last-Modified` response header. A `304` means nothing changed
    /// and returns `notModified` with the same cursor. Notification bodies are
    /// never requested: the page carries id, repository, subject title/type,
    /// updated time and unread state only.
    public func notifications(since: String?, ifModifiedSince: String?,
                              limit: Int = 20,
                              token: String) async throws -> NotificationsPage {
        let capped = min(20, max(1, limit))
        var query: [URLQueryItem] = [
            URLQueryItem(name: "per_page", value: String(capped)),
            URLQueryItem(name: "all", value: "true"),
            URLQueryItem(name: "participating", value: "false"),
        ]
        if let since, !since.isEmpty {
            guard Self.isSafeSince(since) else { throw GitHubConnectorError.invalidResponse }
            query.append(URLQueryItem(name: "since", value: since))
        }
        var headers: [String: String] = [:]
        if let ifModifiedSince, !ifModifiedSince.isEmpty {
            guard Self.isSafeHeaderValue(ifModifiedSince) else {
                throw GitHubConnectorError.invalidResponse
            }
            headers["If-Modified-Since"] = ifModifiedSince
        }
        let (data, response) = try await perform("notifications", query: query, token: token,
                                                 extraHeaders: headers)
        let lastModified = response.value(forHTTPHeaderField: "Last-Modified") ?? ifModifiedSince
        switch response.statusCode {
        case 200:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            let rows = try decode([RawNotification].self, from: data)
            var notifications: [Notification] = []
            for row in rows {
                guard let notification = row.notification(formatter: formatter, fallback: fallback)
                else { continue }
                notifications.append(notification)
                if notifications.count >= capped { break }
            }
            return NotificationsPage(notifications: notifications, lastModified: lastModified,
                                     notModified: false)
        case 304:
            return NotificationsPage(notifications: [], lastModified: lastModified,
                                     notModified: true)
        case 401:
            throw GitHubConnectorError.unauthorized
        case 403:
            if response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw GitHubConnectorError.rateLimited
            }
            throw GitHubConnectorError.forbidden
        case 429:
            throw GitHubConnectorError.rateLimited
        default:
            throw GitHubConnectorError.serviceUnavailable
        }
    }

    /// `since` is an ISO-8601 timestamp placed in the query string. Only the
    /// characters an ISO-8601 instant needs are accepted, so a stored value
    /// can never smuggle a second query parameter or a header break.
    private static func isSafeSince(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        let allowed = Set("0123456789TtZz:+-.".utf8)
        return value.utf8.allSatisfy { allowed.contains($0) }
    }

    private static func isSafeHeaderValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { (32...126).contains($0) }
    }

    private func get(
        _ path: String, query: [URLQueryItem], token: String
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, http) = try await perform(path, query: query, token: token, extraHeaders: [:])
        switch http.statusCode {
        case 200:
            return (data, http)
        case 401:
            throw GitHubConnectorError.unauthorized
        case 403:
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" {
                throw GitHubConnectorError.rateLimited
            }
            throw GitHubConnectorError.forbidden
        case 429:
            throw GitHubConnectorError.rateLimited
        default:
            throw GitHubConnectorError.serviceUnavailable
        }
    }

    /// One authenticated GET without status interpretation beyond transport
    /// failures, so the incremental notification query can accept a `304`.
    private func perform(
        _ path: String, query: [URLQueryItem], token: String,
        extraHeaders: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        guard Self.isValidToken(token) else { throw GitHubConnectorError.invalidResponse }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/" + path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw GitHubConnectorError.invalidResponse }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("phone-dsh", forHTTPHeaderField: "User-Agent")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw GitHubConnectorError.invalidResponse
            }
            return (data, http)
        } catch let error as GitHubConnectorError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw GitHubConnectorError.serviceUnavailable
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubConnectorError.invalidResponse
        }
    }

    /// Only the relation is used; the next request is rebuilt from the fixed
    /// endpoint and the current page, never from the response URL.
    private static func hasNextPage(_ link: String?) -> Bool {
        guard let link else { return false }
        return link.split(separator: ",").contains { entry in
            entry.split(separator: ";").dropFirst().contains { parameter in
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2,
                      pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "rel"
                else { return false }
                let relation = pair[1].trimmingCharacters(in: .whitespaces)
                return relation.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .split(separator: " ").contains { $0.lowercased() == "next" }
            }
        }
    }

    private struct RawNotification: Decodable {
        struct Subject: Decodable {
            let title: String?
            let type: String?
        }

        struct Repository: Decodable {
            let fullName: String?

            enum CodingKeys: String, CodingKey {
                case fullName = "full_name"
            }
        }

        let id: String
        let unread: Bool?
        let reason: String?
        let updatedAt: String?
        let subject: Subject?
        let repository: Repository?

        enum CodingKeys: String, CodingKey {
            case id, unread, reason, subject, repository
            case updatedAt = "updated_at"
        }

        func notification(formatter: ISO8601DateFormatter,
                          fallback: ISO8601DateFormatter) -> Notification? {
            let identifier = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let repositoryName = repository?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !identifier.isEmpty, !repositoryName.isEmpty else { return nil }
            let title = subject?.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let updated = updatedAt.flatMap { formatter.date(from: $0) ?? fallback.date(from: $0) }
            return Notification(
                id: identifier,
                repositoryFullName: repositoryName,
                title: title.isEmpty ? repositoryName : title,
                type: subject?.type?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Notification",
                updatedAt: updated,
                unread: unread ?? true)
        }
    }

    private struct User: Decodable {
        let login: String
    }

    private struct RawRepository: Decodable {
        let id: Int
        let name: String
        let fullName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case id, name
            case fullName = "full_name"
            case htmlURL = "html_url"
        }

        func repository() throws -> Repository {
            guard !name.isEmpty, !fullName.isEmpty, let url = Self.repositoryURL(htmlURL) else {
                throw GitHubConnectorError.invalidResponse
            }
            return Repository(id: id, name: name, fullName: fullName, htmlURL: url)
        }

        private static func repositoryURL(_ value: String) -> URL? {
            guard let components = URLComponents(string: value),
                  components.scheme == "https",
                  components.host == "github.com",
                  components.port == nil,
                  components.user == nil,
                  components.password == nil,
                  components.query == nil,
                  components.fragment == nil,
                  components.percentEncodedPath.range(
                    of: #"^/[^/]+/[^/]+/?$"#, options: .regularExpression
                  ) != nil
            else { return nil }
            return components.url
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
        ) async -> URLRequest? { nil }
    }
}
