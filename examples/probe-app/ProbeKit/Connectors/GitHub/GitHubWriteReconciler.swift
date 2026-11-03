// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// Reconciles provider results without replaying a write. A missing match stays unknown.
public struct GitHubWriteReconciler: Sendable {
    private let client: GitHubClient
    private let window: TimeInterval

    public init(client: GitHubClient, window: TimeInterval = 10 * 60) {
        self.client = client
        self.window = window
    }

    public func reconcile(_ operation: OperationRecord) async throws -> ProviderReceipt? {
        guard operation.intent.toolName == "github.issue.comment",
              let arguments = try JSONSerialization.jsonObject(
                with: Data(operation.intent.argumentsJSON.utf8)) as? [String: Any],
              let repository = arguments["repository"] as? String,
              let number = arguments["number"] as? Int,
              let body = arguments["body"] as? String else { return nil }
        let snapshot = try await client.issue(repository: repository, number: number, commentLimit: 100)
        let digest = Self.digest(body)
        guard let match = snapshot.comments.filter({ comment in
            Self.digest(comment.body) == digest && Self.isWithinWindow(comment.createdAt,
                                                                       operation: operation,
                                                                       window: window)
        }).sorted(by: { $0.id > $1.id }).first else { return nil }
        return ProviderReceipt(providerObjectID: String(match.id), url: match.htmlURL, rawJSON: "{}")
    }

    public static func digest(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isWithinWindow(_ value: String, operation: OperationRecord,
                                       window: TimeInterval) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else { return false }
        return date >= operation.createdAt.addingTimeInterval(-window) &&
            date <= operation.updatedAt.addingTimeInterval(window)
    }
}
