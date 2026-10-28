// SPDX-License-Identifier: MIT
// phone-dsh phone DSH — PhoneDSHLoopback: small shared utilities.
//
// Canonical JSON (channel.md §5) for the few payloads this module builds
// itself, SHA-1 for the RFC 6455 handshake (avoiding a CryptoKit dependency so
// the module stays Foundation + Network only), token generation and the HTTP
// status table.

import Foundation

// MARK: - Canonical JSON writer

/// Minimal canonical JSON value (channel.md §5): UTF-8, sorted member names, no
/// insignificant whitespace, integers only, `/` not escaped and non-ASCII
/// emitted literally. Used for internal payload objects whose shape this
/// module owns; the W0 codecs remain the authority for every frame body.
enum CanonicalJSONValue: Equatable, Sendable {
    case string(String)
    case integer(UInt64)
    case signed(Int64)
    case boolean(Bool)
    case null
    case array([CanonicalJSONValue])
    case object([String: CanonicalJSONValue])

    /// Canonical bytes of this value.
    func encoded() -> Data {
        var text = ""
        write(into: &text)
        return Data(text.utf8)
    }

    private func write(into text: inout String) {
        switch self {
        case .string(let value):
            Self.writeString(value, into: &text)
        case .integer(let value):
            text += String(value)
        case .signed(let value):
            text += String(value)
        case .boolean(let value):
            text += value ? "true" : "false"
        case .null:
            text += "null"
        case .array(let values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                value.write(into: &text)
            }
            text += "]"
        case .object(let members):
            text += "{"
            let keys = members.keys.sorted()
            for (index, key) in keys.enumerated() {
                if index > 0 { text += "," }
                Self.writeString(key, into: &text)
                text += ":"
                members[key]?.write(into: &text)
            }
            text += "}"
        }
    }

    private static func writeString(_ value: String, into text: inout String) {
        text += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: text += "\\\""
            case 0x5C: text += "\\\\"
            case 0x08: text += "\\b"
            case 0x0C: text += "\\f"
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0x00...0x1F:
                let hex = String(scalar.value, radix: 16)
                text += "\\u00"
                if hex.count < 2 { text += "0" }
                text += hex
            default:
                text.unicodeScalars.append(scalar)
            }
        }
        text += "\""
    }
}

// MARK: - SHA-1 (RFC 3174)

/// SHA-1 as required by the RFC 6455 `Sec-WebSocket-Accept` handshake.
///
/// SHA-1 is used only for the non-cryptographic WebSocket accept value that
/// RFC 6455 fixes; it authenticates nothing by itself.
enum SHA1 {
    static func digest(_ message: Data) -> Data {
        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        var padded = message
        let bitLength = UInt64(message.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            padded.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var words = [UInt32](repeating: 0, count: 80)
        padded.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset < bytes.count {
                for index in 0..<16 {
                    let base = offset + index * 4
                    words[index] = (UInt32(bytes[base]) << 24) |
                        (UInt32(bytes[base + 1]) << 16) |
                        (UInt32(bytes[base + 2]) << 8) |
                        UInt32(bytes[base + 3])
                }
                for index in 16..<80 {
                    words[index] = rotateLeft(
                        words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16],
                        by: 1)
                }
                var a = h0
                var b = h1
                var c = h2
                var d = h3
                var e = h4
                for index in 0..<80 {
                    let f: UInt32
                    let k: UInt32
                    switch index {
                    case 0..<20:
                        f = (b & c) | ((~b) & d)
                        k = 0x5A82_7999
                    case 20..<40:
                        f = b ^ c ^ d
                        k = 0x6ED9_EBA1
                    case 40..<60:
                        f = (b & c) | (b & d) | (c & d)
                        k = 0x8F1B_BCDC
                    default:
                        f = b ^ c ^ d
                        k = 0xCA62_C1D6
                    }
                    let temp = rotateLeft(a, by: 5) &+ f &+ e &+ k &+ words[index]
                    e = d
                    d = c
                    c = rotateLeft(b, by: 30)
                    b = a
                    a = temp
                }
                h0 = h0 &+ a
                h1 = h1 &+ b
                h2 = h2 &+ c
                h3 = h3 &+ d
                h4 = h4 &+ e
                offset += 64
            }
        }

        var digest = Data()
        for word in [h0, h1, h2, h3, h4] {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}

// MARK: - Tokens and comparisons

enum LoopbackToken {
    /// A fresh 128-bit token as 32 lowercase hexadecimal characters.
    static func make() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-independent byte comparison of two strings.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

// MARK: - HTTP status text

enum HTTPStatus {
    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 413: return "Payload Too Large"
        case 426: return "Upgrade Required"
        case 429: return "Too Many Requests"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status"
        }
    }
}

// MARK: - Percent decoding and query parsing

enum HTTPURL {
    struct Parsed: Equatable, Sendable {
        var path: String
        var query: [String: String]
    }

    /// Parses an origin-form request target (`/path?query`). Percent-decodes
    /// the path and the query values; `+` stays a literal plus in a path.
    static func parse(_ target: String) -> Parsed? {
        guard target.hasPrefix("/") else { return nil }
        guard let mark = target.firstIndex(of: "?") else {
            guard let path = target.removingPercentEncoding else { return nil }
            return Parsed(path: path, query: [:])
        }
        let rawPath = String(target[target.startIndex..<mark])
        let rawQuery = String(target[target.index(after: mark)...])
        guard let path = rawPath.removingPercentEncoding else { return nil }
        var query: [String: String] = [:]
        for item in rawQuery.split(separator: "&") {
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(pair[0]).removingPercentEncoding ?? String(pair[0])
            let value = pair.count > 1
                ? (String(pair[1]).removingPercentEncoding ?? String(pair[1]))
                : ""
            if query[name] == nil { query[name] = value }
        }
        return Parsed(path: path, query: query)
    }
}

// MARK: - JSON error envelopes

enum LoopbackJSON {
    /// `{"error":{"code":...,"message":...}}`, spec/exec-bridge-v1 §1.
    static func error(code: String, message: String) -> Data {
        CanonicalJSONValue.object([
            "error": .object([
                "code": .string(code),
                "message": .string(message),
            ]),
        ]).encoded()
    }
}
