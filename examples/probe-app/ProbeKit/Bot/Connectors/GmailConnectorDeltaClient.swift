// SPDX-License-Identifier: MIT

import Foundation
import PhoneDSHBot

/// Gmail's metadata-only delta client (PLAN §2.5).
///
/// The cursor is the Gmail `historyId` decimal string. A baseline (no cursor)
/// reads the mailbox head and emits nothing; later scans call
/// `users.history.list` with `startHistoryId` and fetch only From/Subject
/// metadata for at most 20 new inbox messages. No body is requested.
public struct GmailConnectorDeltaClient: ConnectorDeltaClient {
    public let connector: ConnectorKind = .gmail
    private let api: GmailAPI
    private let token: @Sendable () async throws -> String?

    public init(api: GmailAPI = GmailAPI(),
                token: @escaping @Sendable () async throws -> String?) {
        self.api = api
        self.token = token
    }

    public func fetchDelta(cursor: ConnectorCursorState?) async throws -> ConnectorDeltaPage {
        guard let token = try await token(), !token.isEmpty else {
            throw ConnectorClientFailure.unauthorized
        }
        do {
            guard let cursor, !cursor.cursor.isEmpty else {
                let mailbox = try await api.mailbox(token: token)
                return ConnectorDeltaPage(cursor: mailbox.historyId, items: [])
            }
            let delta = try await api.history(startHistoryId: cursor.cursor,
                                              limit: ConnectorUpdateRecord.maxItems,
                                              token: token)
            return ConnectorDeltaPage(
                cursor: delta.historyId,
                items: delta.messages.map(Self.item))
        } catch let error as GmailError {
            switch error {
            case .unauthorized, .forbidden:
                // An expired or under-scoped token is skipped silently: the
                // settings page already owns that state and a wake scan must
                // never prompt.
                throw ConnectorClientFailure.unauthorized
            case .notFound:
                // The server no longer holds history from this cursor. Report
                // the current head so the scanner resets without inventing a
                // delta; a head read failure leaves the reset to the next scan.
                let head = (try? await api.mailbox(token: token))?.historyId
                throw ConnectorClientFailure.cursorInvalid(head: head)
            case .serviceUnavailable:
                throw ConnectorClientFailure.unavailable
            case .invalidResponse:
                throw ConnectorClientFailure.invalidResponse
            }
        }
    }

    static func item(_ summary: GmailAPI.Summary) -> ConnectorMetadataItem {
        let from = summary.sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = summary.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectorMetadataItem(
            id: summary.id,
            at: summary.date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) } ?? 0,
            from: from.isEmpty ? nil : from,
            subject: subject.isEmpty ? nil : subject)
    }
}
