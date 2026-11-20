// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// GitHub's metadata-only delta client (PLAN §2.5, contract §3.3).
///
/// The persisted cursor is `{since: <RFC 3339 UTC seconds>, lastModified:
/// <IMF-fixdate>|null}`. A baseline (no usable cursor) takes the current head
/// and emits nothing. An incremental scan sends `since` + `If-Modified-Since`;
/// a `304` keeps `since` and emits nothing, a non-empty page advances `since`
/// to the scan start, and an empty page keeps it. Only notification metadata
/// is mapped; the notification body/thread is never fetched.
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
        let scanStartedAt = now()
        do {
            guard let cursor, case .github(let since, let lastModified) = cursor.cursor else {
                let page = try await api.notifications(
                    since: nil, ifModifiedSince: nil,
                    limit: ConnectorUpdateRecord.maxItems, token: token)
                return ConnectorDeltaPage(
                    head: .github(since: Self.isoNow(scanStartedAt),
                                  lastModified: page.lastModified))
            }
            let page = try await api.notifications(
                since: since, ifModifiedSince: lastModified,
                limit: ConnectorUpdateRecord.maxItems, token: token)
            let nextLastModified = page.lastModified ?? lastModified
            guard !page.notModified else {
                return ConnectorDeltaPage(
                    head: .github(since: since, lastModified: nextLastModified))
            }
            let items = page.notifications.map(Self.item)
            // Only an actual notification advances the `since` watermark; an
            // empty page or a lastModified-only change keeps it so the next
            // scan does not skip work and no connectorUpdate is emitted.
            let nextSince = items.isEmpty ? since : Self.isoNow(scanStartedAt)
            return ConnectorDeltaPage(
                head: .github(since: nextSince, lastModified: nextLastModified),
                items: items)
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

    static func isoNow(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "GMT")
        return formatter.string(from: date)
    }
}
