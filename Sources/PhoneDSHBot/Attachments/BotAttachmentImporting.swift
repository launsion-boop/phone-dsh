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
    /// Copy the user's local files into the Bot's private workspace through the
    /// Worker import service and return the absolute VFS paths the model's
    /// file tools can read. The concrete app implementation uses the Bot root
    /// from `BotWorkspaceLayout` as the session cwd and writes
    /// `imports/attachments-<messageID>/<safeName>` under it; the final path
    /// comes from the import commit, never a local constant. A failed or
    /// oversized file is reported per item; the caller still sends the
    /// successful items.
    func importFiles(botID: String, messageID: String, files: [URL]) async -> BotAttachmentImportResult
}
