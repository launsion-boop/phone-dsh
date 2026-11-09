// SPDX-License-Identifier: MIT

import Foundation

public struct BotAttachmentImportResult: Sendable {
    public var items: [BotAttachment]
    public var errors: [(name: String, reason: String)]

    public init(items: [BotAttachment] = [], errors: [(name: String, reason: String)] = []) {
        self.items = items
        self.errors = errors
    }

    public var isEmpty: Bool { items.isEmpty && errors.isEmpty }
}

public protocol BotAttachmentImporting: Sendable {
    /// Copy the user's local files into the Bot session workspace through the
    /// Worker import service and return the absolute VFS paths the model's
    /// file tools can read. The concrete app implementation uses
    /// `imports/attachments-<messageID>/<safeName>` under the session cwd and
    /// takes the final path from the import commit. A failed or oversized file
    /// is reported per item; the caller still sends the successful items.
    func importFiles(botID: String, messageID: String, files: [URL]) async -> BotAttachmentImportResult
}
