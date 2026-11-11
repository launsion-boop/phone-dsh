// SPDX-License-Identifier: MIT
// One line of host error text that is safe to put on screen (P09).
//
// The chat banner used to show only a hand-written Chinese sentence; the raw
// host text went to chat-status.log. That hid the real cause from every
// screenshot and bug report, so the banner now carries a condensed version of
// it. Condensed is not enough: a provider error can echo the endpoint it
// refused (scheme, host, path, query) and, for a misconfigured provider, a key.
// This masks those while keeping the words that explain the failure.

import Foundation

public enum ScreenSafeText {
    /// Longest line kept. The banner is two lines tall; the log keeps the rest.
    public static let maximumCharacters = 120

    /// `raw` reduced to one line with URLs, credentials and long opaque blobs
    /// masked. Never returns an empty string for non-empty input.
    public static func condensed(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        text = maskURLs(text)
        text = maskSecrets(text)
        text = collapseSpaces(text)
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "…"
    }

    /// `https://user:pw@host:8080/v1/messages?key=abc` → `https://host:8080/…`
    /// (userinfo, path and query dropped; the port is kept because "wrong port"
    /// is a real diagnosis).
    static func maskURLs(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\b([a-z][a-z0-9+.-]*)://(?:[^/@\s]*@)?([^/\s:?]+)(?::(\d+))?[^\s]*"#)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var result = text
        for match in regex.matches(in: text, range: range).reversed() {
            guard let whole = Range(match.range, in: text),
                  let scheme = Range(match.range(at: 1), in: text),
                  let host = Range(match.range(at: 2), in: text) else { continue }
            var replacement = "\(text[scheme].lowercased())://\(text[host])"
            if match.range(at: 3).location != NSNotFound,
               let port = Range(match.range(at: 3), in: text) {
                replacement += ":\(text[port])"
            }
            replacement += "/…"
            result.replaceSubrange(whole, with: replacement)
        }
        return result
    }

    /// Bearer tokens, `sk-` keys, `key=value` query parameters and long opaque
    /// runs (32+ hex/base64 characters) become `***`.
    static func maskSecrets(_ text: String) -> String {
        var value = text
        let patterns = [
            #"(?i)\b(bearer|token|apikey|api[_-]?key|authorization|key)\b\s*[:=]\s*\S+"#,
            #"(?i)\bsk-[A-Za-z0-9._-]{6,}"#,
            #"\b[A-Fa-f0-9]{32,}\b"#,
            #"\b[A-Za-z0-9_\-]{40,}={0,2}\b"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..., in: value)
            value = regex.stringByReplacingMatches(in: value, range: range, withTemplate: "***")
        }
        return value
    }

    static func collapseSpaces(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }
}
