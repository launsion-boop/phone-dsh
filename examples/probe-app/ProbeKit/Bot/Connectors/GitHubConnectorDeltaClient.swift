// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// GitHub's metadata-only delta client (PLAN §2.5).
///
/// The persisted cursor is the notifications response's `Last-Modified` value
/// (an HTTP date). Every later call sends it as `If-Modified-Since` and derives
/// the equivalent ISO-8601 `since` from the same instant, so one frozen cursor
/// string carries both watermarks. A baseline read (no cursor) takes the
/// current head and emits nothing. Only notification metadata is mapped; the
/// notification subject/thread body is never fetched.
public struct GitHubConnectorDeltaClient: ConnectorDeltaClient {
    public let connector: ConnectorKind = .github
    private let api: GitHubConnectorAPI
    private let token: @Sendable () async throws -> String?
    private let now: @Sendable () -> Date

    public init(api: GitHubConnectorAPI = GitHubConnectorAPI(),
                token: @escaping @Sendable () async throws -> String?,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.api = api
        self.token = token
        self.now = now
    }

    public func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage {
        guard let token = try await token(), !token.isEmpty else {
            throw ConnectorClientFailure.unauthorized
        }
        guard GitHubConnectorAPI.isValidToken(token) else {
            // An expired/rotated token is a silent skip, never a prompt.
            throw ConnectorClientFailure.unauthorized
        }
        do {
            guard let cursor, !cursor.cursor.isEmpty else {
                let page = try await api.notifications(
                    since: nil, ifModifiedSince: nil,
                    limit: ConnectorUpdateRecord.maxItems, token: token)
                return ConnectorDeltaPage(cursor: Self.head(page: page, now: now()), items: [])
            }
            let since = Self.iso8601(from: cursor.cursor) ?? Self.isoNow(now())
            let page = try await api.notifications(
                since: since, ifModifiedSince: cursor.cursor,
                limit: ConnectorUpdateRecord.maxItems, token: token)
            let next = page.lastModified ?? cursor.cursor
            guard !page.notModified else {
                return ConnectorDeltaPage(cursor: next, items: [])
            }
            return ConnectorDeltaPage(cursor: next, items: page.notifications.map(Self.item))
        } catch let error as GitHubConnectorError {
            switch error {
            case .unauthorized, .forbidden:
                throw ConnectorClientFailure.unauthorized
            case .rateLimited:
                throw ConnectorClientFailure.rateLimited
            case .invalidResponse:
                throw ConnectorClientFailure.invalidResponse
            case .serviceUnavailable:
                throw ConnectorClientFailure.unavailable
            }
        }
    }

    static func item(_ notification: GitHubConnectorAPI.Notification) -> ConnectorMetadataItem {
        ConnectorMetadataItem(
            id: notification.id,
            at: notification.updatedAt.map {
                Int64(($0.timeIntervalSince1970 * 1000).rounded())
            } ?? 0,
            repo: notification.repositoryFullName,
            title: notification.title.isEmpty ? nil : notification.title)
    }

    static func head(page: GitHubConnectorAPI.NotificationsPage, now: Date) -> String {
        page.lastModified ?? isoNow(now)
    }

    /// Convert either an ISO-8601 instant or an HTTP date to ISO-8601. The
    /// stored cursor is the HTTP date when the server provided one; the
    /// derived `since` is the same instant. An unparseable cursor yields nil so
    /// the caller falls back to the scan start (a fresh baseline).
    static func iso8601(from value: String) -> String? {
        guard !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return isoNow(date) }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return isoNow(date) }
        let http = DateFormatter()
        http.locale = Locale(identifier: "en_US_POSIX")
        http.timeZone = TimeZone(identifier: "GMT")
        http.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = http.date(from: value) { return isoNow(date) }
        return nil
    }

    static func isoNow(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: date)
    }
}
