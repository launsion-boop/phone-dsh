// SPDX-License-Identifier: MIT
// §3.2 enrollment console grammar (secure-session-v2), for host tooling on the trusted serial
// host. Parses host commands and board responses byte-exactly and prints them.
import Foundation

public enum BLESecureConsole {
    public enum Direction: String, Sendable { case host, board }

    public enum Parsed: Equatable, Sendable {
        /// Not addressed to enrollment: ignored, no response.
        case unaddressed
        /// Addressed but invalid; `echo` is the verb if known, else "-".
        case syntaxError(echo: String)
        case line(verb: String, fields: [String: String])
    }

    public static let maxLine = 384
    public static let commands: [String: [String]] = [
        "status": [], "begin": [], "phone": ["eid", "phone"], "commit": ["eid", "device", "phone"],
        "abort": ["eid"], "revoke": ["eid", "device", "phone"], "identity-reset": [],
    ]
    public static let responses: [String: [String]] = [
        "status": ["state", "mode", "ctx", "device", "phone", "eid", "rev"], "armed": ["window_s"], "begun": ["eid", "device"],
        "staged": ["eid", "device", "phone", "token"], "press": ["eid", "action", "timeout_s"],
        "committed": ["eid", "device", "phone", "rev"], "aborted": ["eid"],
        "revoked": ["eid", "device", "phone", "rev"], "reset": ["device"], "error": ["code", "cmd"],
    ]
    static let states: Set<String> = ["none", "committed", "revoked", "key_lost", "key_unavailable", "record_corrupt"]
    static let modes: Set<String> = ["locked", "armed"]
    static let contexts: Set<String> = ["idle", "begun", "staged", "press"]
    static let actions: Set<String> = ["commit", "revoke", "identity-reset"]
    public static let errorCodes: Set<String> = [
        "syntax", "busy", "occupied", "no_session", "state", "eid_mismatch", "value_mismatch", "same_key",
        "timeout", "storage", "controls_unavailable", "not_armed", "gesture", "key_lost", "key_unavailable", "record_corrupt",
    ]

    /// Parses one LF-terminated line (a single CR before LF is removed).
    public static func parse(_ raw: [UInt8], direction: Direction) -> Parsed {
        var line = raw
        if line.last == 10 { line.removeLast() }
        if line.last == 13 { line.removeLast() }
        let prefix = Array((direction == .host ? "pdsh-enroll" : "pdsh-enroll-r").utf8)
        let first = line.split(separator: 32, maxSplits: 1, omittingEmptySubsequences: false).first.map(Array.init) ?? []
        guard first == prefix else { return .unaddressed }
        let tokens = line.split(separator: 32, omittingEmptySubsequences: false).map(Array.init)
        let table = direction == .host ? commands : responses
        let verb = tokens.count > 1 ? String(decoding: tokens[1], as: UTF8.self) : ""
        let known = table[verb] != nil && tokens.count > 1 && tokens[1].allSatisfy { (0x21...0x7e).contains($0) }
        let echo = known ? verb : "-"
        guard (1...maxLine).contains(line.count), line.allSatisfy({ (0x20...0x7e).contains($0) }),
              !tokens.contains(where: \.isEmpty), let names = table[verb], known,
              tokens.count - 2 == names.count else { return .syntaxError(echo: echo) }
        var fields: [String: String] = [:]
        for (name, token) in zip(names, tokens.dropFirst(2)) {
            let text = String(decoding: token, as: UTF8.self)
            guard let eq = text.firstIndex(of: "="), text[..<eq] == name else { return .syntaxError(echo: echo) }
            let value = String(text[text.index(after: eq)...])
            guard !value.isEmpty else { return .syntaxError(echo: echo) }
            fields[name] = value
        }
        for name in names where !valueOK(direction, verb, name, fields[name]!, fields) { return .syntaxError(echo: echo) }
        return .line(verb: verb, fields: fields)
    }

    private static func valueOK(_ direction: Direction, _ verb: String, _ name: String, _ value: String,
                                _ fields: [String: String]) -> Bool {
        switch name {
        case "eid": return BLESecureIdentifiers.isEID(value) || (direction == .board && (verb == "status" || verb == "press") && value == "-")
        case "device", "phone": return BLESecureIdentifiers.isFingerprint(value) || (direction == .board && verb == "status" && value == "-")
        case "rev":
            let bytes = Array(value.utf8)
            guard (1...10).contains(bytes.count), bytes.allSatisfy({ (48...57).contains($0) }),
                  bytes.count == 1 || bytes[0] != 48, let n = UInt64(value) else { return false }
            return n <= 4294967295
        case "state": return states.contains(value)
        case "mode": return modes.contains(value)
        case "ctx": return contexts.contains(value)
        case "window_s": return value == "300"
        case "action": return actions.contains(value)
        case "timeout_s": return value == "30"
        case "token": return value == BLESecureIdentifiers.boardToken(device: fields["device"] ?? "", eid: fields["eid"] ?? "")
        case "code": return errorCodes.contains(value)
        case "cmd": return value == "-" || commands[value] != nil
        default: return false
        }
    }

    /// Prints a host command or board response, fields in the listed order, LF-terminated.
    public static func print(_ verb: String, _ fields: [String: String], direction: Direction) -> [UInt8]? {
        let table = direction == .host ? commands : responses
        guard let names = table[verb], Set(fields.keys) == Set(names) else { return nil }
        let prefix = direction == .host ? "pdsh-enroll" : "pdsh-enroll-r"
        let text = ([prefix, verb] + names.map { "\($0)=\(fields[$0]!)" }).joined(separator: " ")
        let bytes = Array(text.utf8) + [10]
        guard parse(bytes, direction: direction) == .line(verb: verb, fields: fields) else { return nil }
        return bytes
    }
}
