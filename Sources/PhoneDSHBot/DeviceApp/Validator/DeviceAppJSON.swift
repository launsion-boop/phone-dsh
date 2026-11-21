// SPDX-License-Identifier: MIT

import Foundation

/// Strict JSON reader for the device app manifest. `JSONSerialization` neither reports duplicate
/// keys nor keeps integers exact, and both matter for `app.json` (device-app.md §3).
/// Rejects: duplicate keys at any depth, NaN/Infinity, trailing content, raw control characters
/// in strings, lone surrogate escapes (the oracle would accept them in a string; they cannot be a
/// Swift `String`, and rejecting is the conservative direction) and nesting deeper than 64.
enum DeviceAppJSON {
    indirect enum Value {
        case object([(key: [UInt8], value: Value)])
        case array([Value])
        case string(String)
        /// Integer token without fraction or exponent, exactly as written.
        case integer(String)
        case other
    }

    static func parse(_ text: String) -> Value? {
        var parser = Parser(bytes: Array(text.utf8))
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> Value? {
            guard depth <= 64 else { return nil }
            skipWhitespace()
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(Value.string)
            case UInt8(ascii: "t"): return literal("true")
            case UInt8(ascii: "f"): return literal("false")
            case UInt8(ascii: "n"): return literal("null")
            default: return number()
            }
        }

        mutating func literal(_ word: String) -> Value? {
            let w = Array(word.utf8)
            guard index + w.count <= bytes.count, Array(bytes[index..<index + w.count]) == w else { return nil }
            index += w.count
            return .other
        }

        mutating func number() -> Value? {
            let start = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { return nil }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else {
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            var isInteger = true
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                isInteger = false
                index += 1
                guard index < bytes.count, isDigit(bytes[index]) else { return nil }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                isInteger = false
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard index < bytes.count, isDigit(bytes[index]) else { return nil }
                while index < bytes.count, isDigit(bytes[index]) { index += 1 }
            }
            let token = String(decoding: bytes[start..<index], as: UTF8.self)
            return isInteger ? .integer(token) : .other
        }

        func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

        mutating func array(depth: Int) -> Value? {
            index += 1
            var items: [Value] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        mutating func object(depth: Int) -> Value? {
            index += 1
            var members: [(key: [UInt8], value: Value)] = []
            var seen = Set<[UInt8]>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                let keyBytes = Array(key.utf8)
                guard seen.insert(keyBytes).inserted else { return nil }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let member = value(depth: depth + 1) else { return nil }
                members.append((keyBytes, member))
                skipWhitespace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var v: UInt32 = 0
            for b in bytes[index..<index + 4] {
                guard let d = Character(UnicodeScalar(b)).hexDigitValue else { return nil }
                v = v * 16 + UInt32(d)
            }
            index += 4
            return v
        }

        mutating func string() -> String? {
            index += 1
            var out = [UInt8]()
            while index < bytes.count {
                let b = bytes[index]
                if b == UInt8(ascii: "\"") {
                    index += 1
                    return String(bytes: out, encoding: .utf8)
                }
                if b < 0x20 { return nil }
                if b != UInt8(ascii: "\\") { out.append(b); index += 1; continue }
                index += 1
                guard index < bytes.count else { return nil }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hex4() else { return nil }
                    if (0xD800...0xDBFF).contains(code) {
                        guard index + 2 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                        index += 2
                        guard let low = hex4(), (0xDC00...0xDFFF).contains(low) else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(code) {
                        return nil
                    }
                    guard let scalar = Unicode.Scalar(code) else { return nil }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: return nil
                }
            }
            return nil
        }
    }
}
