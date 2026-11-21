// SPDX-License-Identifier: MIT

import Foundation

/// Read-only memory adapter. The Feedback module verifies that a correction
/// names the version the host actually applied; it never writes memory.
extension BotMemory: BotFeedbackMemoryReading {
    public func memorySnapshot(path: String) async throws -> BotFeedbackMemorySnapshot? {
        guard let scope = BotMemoryAuthorizer.scope(of: path) else { return nil }
        let documents = try await documents(scope: scope)
        guard let document = documents.first(where: { $0.path == path }) else { return nil }
        return BotFeedbackMemorySnapshot(version: document.version, evidence: document.evidence)
    }
}
