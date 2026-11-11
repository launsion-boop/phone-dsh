// SPDX-License-Identifier: MIT

import Foundation

/// One canonical pointer into the two authoritative Bot record stores.
///
/// `record://session/<sessionId>#<seq>` identifies one DSH session-log line.
/// `record://event/<commitSeq>` identifies one `bot_events` row. The parser is
/// deliberately strict: it normalizes only surrounding ASCII whitespace,
/// ASCII case in the scheme/authority and leading zeros in the decimal
/// position. Every other spelling is rejected rather than guessed.
public enum BotRecordReference: Sendable, Equatable, Hashable {
    case session(sessionID: String, seq: Int)
    case event(commitSeq: Int)

    public static let maximumDecimal = 9_007_199_254_740_991

    /// Canonical string form stored in facts, envelopes and query results.
    public var canonical: String {
        switch self {
        case let .session(sessionID, seq):
            return "record://session/\(sessionID)#\(seq)"
        case let .event(commitSeq):
            return "record://event/\(commitSeq)"
        }
    }

    public var kind: String {
        switch self {
        case .session: return "session"
        case .event: return "event"
        }
    }

    public var sessionID: String? {
        guard case let .session(sessionID, _) = self else { return nil }
        return sessionID
    }

    public var seq: Int? {
        guard case let .session(_, seq) = self else { return nil }
        return seq
    }

    public var commitSeq: Int? {
        guard case let .event(commitSeq) = self else { return nil }
        return commitSeq
    }

    /// Parses one reference into its canonical value, or returns nil.
    public static func parse(_ raw: String) -> BotRecordReference? {
        let value = trimASCIIWhitespace(raw)
        let header = "record://"
        guard value.utf8.count > header.utf8.count,
              value.prefix(header.count).lowercased() == header else { return nil }
        let rest = String(value.dropFirst(header.count))
        let authorityEnd = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = String(rest[..<authorityEnd]).lowercased()
        guard authority == "session" || authority == "event",
              authorityEnd < rest.endIndex else { return nil }
        let tail = String(rest[rest.index(after: authorityEnd)...])
        if authority == "event" {
            guard let number = decimal(tail), number >= 1, number <= maximumDecimal else { return nil }
            return .event(commitSeq: Int(number))
        }
        guard tail.filter({ $0 == "#" }).count == 1,
              let separator = tail.firstIndex(of: "#") else { return nil }
        let sessionID = String(tail[..<separator])
        let digits = String(tail[tail.index(after: separator)...])
        guard Self.validSessionID(sessionID),
              let number = decimal(digits), number <= maximumDecimal else { return nil }
        return .session(sessionID: sessionID, seq: Int(number))
    }

    /// Canonical string for a valid reference, or nil for an invalid one.
    public static func canonicalize(_ raw: String) -> String? {
        parse(raw)?.canonical
    }

    static func validSessionID(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count),
              value != ".", value != ".." else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                return true
            default:
                return false
            }
        }
    }

    private static func decimal(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return nil
        }
        return UInt64(text)
    }

    private static func trimASCIIWhitespace(_ raw: String) -> String {
        let scalars = Array(raw.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isASCIIWhitespace(scalars[start]) { start += 1 }
        while end > start, isASCIIWhitespace(scalars[end - 1]) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private static func isASCIIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\r" || scalar == "\n"
    }
}
