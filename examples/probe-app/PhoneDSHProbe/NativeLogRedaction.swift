// SPDX-License-Identifier: MIT
//
// S1-G: redaction for diagnostic values written to `chat-status.log`.
//
// A diagnostic line may say how long a value was and a stable SHA-256 prefix so
// two occurrences can be correlated, but never the value itself. This keeps
// user prompts, model answers, tool arguments, file contents and credentials
// out of the status log.

import CryptoKit
import Foundation

enum NativeLogRedaction {
    /// `len=123 hash=ab12cd34` for one arbitrary diagnostic value.
    static func value(_ text: String, hashPrefixCount: Int = 8) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let prefix = String(digest.prefix(max(0, hashPrefixCount)))
        return "len=\(text.count) hash=\(prefix)"
    }

    /// The queued-message line. Only the length is recorded; the composer text
    /// may contain a credential (the device bug this replaces wrote the first
    /// 40 characters verbatim).
    static func queued(_ text: String) -> String {
        "queued: len=\(text.count)"
    }

    /// A failed turn's raw host message: the kind of failure is already on the
    /// same line, so the message itself is reduced to its fingerprint.
    static func failedTurn(_ raw: String) -> String {
        "turn failed: \(value(raw))"
    }

    /// One error's description reduced to its fingerprint.
    static func error(_ error: Error) -> String {
        value(String(describing: error))
    }

    /// One error's localized description reduced to its fingerprint.
    static func localizedError(_ error: Error) -> String {
        value(error.localizedDescription)
    }
}
