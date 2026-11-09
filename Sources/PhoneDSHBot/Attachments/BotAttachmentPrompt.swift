// SPDX-License-Identifier: MIT

import Foundation

/// The model-visible attachment block and its inverse. The markers and the
/// `- {json}` line shape are shared with dsh-bot; only the explanatory
/// sentence is phoneDSH-specific (the files live in the Bot workspace, not on
/// a Mac). Parsing depends on the markers and the JSON lines, not the prose.
public enum BotAttachmentPrompt {
    public static let explanation = "The user attached these files. They are saved in your workspace; read them with your file tools when the task needs their contents."
    public static let openMarker = "[dshbot-attachments]"
    public static let closeMarker = "[/dshbot-attachments]"

    /// Returns `""` for an empty list; otherwise the block starts with two
    /// newlines so it can be appended directly after the prompt text.
    public static func block(_ items: [BotAttachment]) -> String {
        guard !items.isEmpty else { return "" }
        let lines = items.map { "- " + jsonLine($0) }
        return "\n\n\(openMarker)\n\(explanation)\n" + lines.joined(separator: "\n") + "\n\(closeMarker)"
    }

    /// Removes the first attachment block from visible text and restores its
    /// metadata. Text before the block is kept (trimmed); text after the
    /// closing marker is dropped, matching dsh-bot. A missing marker leaves
    /// the input untouched.
    public static func parse(_ text: String) -> (text: String, attachments: [BotAttachment]) {
        guard let start = text.range(of: openMarker),
              let end = text.range(of: closeMarker, range: start.upperBound..<text.endIndex) else {
            return (text, [])
        }
        let visible = String(text[..<start.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text[start.upperBound..<end.lowerBound]
        var attachments: [BotAttachment] = []
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("- ") else { continue }
            let json = String(line.dropFirst(2))
            guard let data = json.data(using: .utf8),
                  let item = try? JSONDecoder().decode(BotAttachment.self, from: data) else { continue }
            attachments.append(item)
        }
        return (visible, attachments)
    }

    private static func jsonLine(_ item: BotAttachment) -> String {
        "{\"name\":\(quoted(item.name)),\"path\":\(quoted(item.path)),\"size\":\(item.size),"
            + "\"mimeType\":\(quoted(item.mimeType)),\"kind\":\(quoted(item.kind))}"
    }

    private static func quoted(_ value: String) -> String {
        // Mirror `JSON.stringify` for the fields the block carries: ordinary
        // UTF-8 stays literal, `/` is not escaped, and only the JSON control
        // escapes are emitted. This keeps the golden prompt byte-exact.
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
