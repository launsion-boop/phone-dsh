// SPDX-License-Identifier: MIT

import Foundation

/// G-1 r22: canonical bot-root-relative path for a successful write/edit.
/// Only paths inside this Bot's root are accepted; the caller records the
/// derivation, never a guessed one.
enum BotWorkspaceDerivation {
    static func path(arguments: BotJSONValue?, botID: String) -> String? {
        var object = arguments?.objectValue
        if object == nil, let text = arguments?.stringValue,
           let data = text.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(BotJSONValue.self, from: data) {
            object = decoded.objectValue
        }
        guard let raw = object?["file_path"]?.stringValue else { return nil }
        let prefix = "/dsh/workspace/.dshbot/agents/\(botID)/"
        var relative = raw
        if raw.hasPrefix(prefix) {
            relative = String(raw.dropFirst(prefix.count))
        } else if raw.hasPrefix("/") {
            // An absolute path outside this Bot's root is not this Bot's file.
            return nil
        }
        var parts: [String] = []
        for part in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { return nil }
            parts.append(String(part))
        }
        let path = parts.joined(separator: "/")
        return path.isEmpty ? nil : String(path.prefix(1_024))
    }
}
