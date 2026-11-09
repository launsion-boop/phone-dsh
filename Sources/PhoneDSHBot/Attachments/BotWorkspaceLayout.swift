// SPDX-License-Identifier: MIT

import Foundation

/// The VFS layout the Bot runtime owns.
///
/// Bot sessions run under a private directory tree below the durable
/// `/dsh/workspace` mount. The tree is deliberately *not* registered with the
/// Worker workspace registry: DSH lists a folder only for a registered
/// workspace record, so this root never becomes a DSH folder. It is still a
/// normal VFS path, so `session/create` creates it and DSH file tools can read
/// and write it.
///
/// `botRoot` is `<botDataDirectory>/agents/<botID>`, matching the upstream
/// dsh-bot `<dataRoot>/agents/<botID>/` convention. Attachments stay under the
/// session cwd, in the same relative `imports/attachments-<messageID>/` layout
/// the directory-import service has always produced.
public enum BotWorkspaceLayout {
    /// Default root used by tests and by callers that do not supply the App's
    /// `BotSessionRegistry.botDataDirectory`. The App passes its constant into
    /// `BotDSHRemoteRuntime`, so production has one value; it must stay equal
    /// to this default (documented in PC-20261109-bot-root).
    public static let defaultBotDataDirectory = "/dsh/workspace/.dshbot"

    /// `<botDataDirectory>/agents/<safe botID>`.
    public static func botRoot(
        botId: String,
        dataDirectory: String = defaultBotDataDirectory
    ) -> String {
        "\(normalizedDataDirectory(dataDirectory))/agents/\(safePathComponent(botId))"
    }

    /// A single safe path component for an id that becomes a VFS directory.
    /// Keeps the value deterministic so the same Bot always maps to one root.
    public static func safePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var output = ""
        for scalar in raw.unicodeScalars {
            output.append(allowed.contains(scalar) ? String(scalar) : "_")
        }
        if output.isEmpty || output == "." || output == ".." {
            output = "bot"
        }
        return String(output.prefix(64))
    }

    private static func normalizedDataDirectory(_ raw: String) -> String {
        var value = raw
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}
