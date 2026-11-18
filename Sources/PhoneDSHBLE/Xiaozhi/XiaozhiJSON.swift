// SPDX-License-Identifier: MIT
// phone-dsh — PhoneDSHBLE/Xiaozhi: an order-preserving JSON value.
// Foundation's JSONSerialization returns dictionaries, which lose member
// order; the OTA rewrite (spec/device/v1/xiaozhi-firmware.md §2.4) must keep
// every upstream member in its place.
#if DEBUG
import Foundation

enum XiaozhiJSON: Equatable {
    struct Member: Equatable {
        var key: String
        var value: XiaozhiJSON
    }

    case object([Member])
    case array([XiaozhiJSON])
    case string(String)
    /// The number exactly as written; it is never reinterpreted.
    case number(String)
    case bool(Bool)
    case null

    /// nil unless `data` is exactly one JSON value (RFC 8259) with nothing after it.
    static func parse(_ data: Data) -> XiaozhiJSON? {
        var parser = Parser(bytes: Array(data))
        parser.skipSpace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipSpace()
        return parser.index == parser.bytes.count ? value : nil
    }

    /// Compact UTF-8 serialization, members in stored order.
    func serialized() -> Data {
        var out = Data()
        write(into: &out)
        return out
    }

    private func write(into out: inout Data) {
        switch self {
        case .null: out.append(contentsOf: "null".utf8)
        case .bool(let flag): out.append(contentsOf: (flag ? "true" : "false").utf8)
        case .number(let text): out.append(contentsOf: text.utf8)
        case .string(let text): Self.writeString(text, into: &out)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (offset, item) in items.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                item.write(into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let members):
            out.append(UInt8(ascii: "{"))
            for (offset, member) in members.enumerated() {
                if offset > 0 { out.append(UInt8(ascii: ",")) }
                Self.writeString(member.key, into: &out)
                out.append(UInt8(ascii: ":"))
                member.value.write(into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static func writeString(_ text: String, into out: inout Data) {
        out.append(UInt8(ascii: "\""))
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out.append(contentsOf: "\\\"".utf8)
            case "\\": out.append(contentsOf: "\\\\".utf8)
            case "\n": out.append(contentsOf: "\\n".utf8)
            case "\r": out.append(contentsOf: "\\r".utf8)
            case "\t": out.append(contentsOf: "\\t".utf8)
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: String(format: "\\u%04x", scalar.value).utf8)
                } else {
                    out.append(contentsOf: String(scalar).utf8)
                }
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0
        static let maxDepth = 128

        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipSpace() {
            while index < bytes.count, [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> XiaozhiJSON? {
            guard depth <= Self.maxDepth, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map { .string($0) }
            case UInt8(ascii: "t"): return literal("true", .bool(true))
            case UInt8(ascii: "f"): return literal("false", .bool(false))
            case UInt8(ascii: "n"): return literal("null", .null)
            default: return number()
            }
        }

        private mutating func literal(_ word: String, _ result: XiaozhiJSON) -> XiaozhiJSON? {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else { return nil }
            index += expected.count
            return result
        }

        private mutating func object(depth: Int) -> XiaozhiJSON? {
            index += 1
            var members: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\""), let key = string() else { return nil }
                skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                index += 1
                skipSpace()
                guard let member = value(depth: depth + 1) else { return nil }
                members.append(Member(key: key, value: member))
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                return nil
            }
        }

        private mutating func array(depth: Int) -> XiaozhiJSON? {
            index += 1
            var items: [XiaozhiJSON] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
            while true {
                skipSpace()
                guard let item = value(depth: depth + 1) else { return nil }
                items.append(item)
                skipSpace()
                guard index < bytes.count else { return nil }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                return nil
            }
        }

        private mutating func hex4() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var result: UInt32 = 0
            for offset in 0..<4 {
                guard let digit = Self.hexValue(bytes[index + offset]) else { return nil }
                result = result << 4 | digit
            }
            index += 4
            return result
        }

        private static func hexValue(_ byte: UInt8) -> UInt32? {
            switch byte {
            case 0x30...0x39: return UInt32(byte - 0x30)
            case 0x41...0x46: return UInt32(byte - 0x41 + 10)
            case 0x61...0x66: return UInt32(byte - 0x61 + 10)
            default: return nil
            }
        }

        private mutating func string() -> String? {
            index += 1   // opening quote
            var raw: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                switch byte {
                case UInt8(ascii: "\""):
                    return String(data: Data(raw), encoding: .utf8)
                case 0x00..<0x20:
                    return nil
                case UInt8(ascii: "\\"):
                    guard index < bytes.count else { return nil }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): raw.append(0x22)
                    case UInt8(ascii: "\\"): raw.append(0x5c)
                    case UInt8(ascii: "/"): raw.append(0x2f)
                    case UInt8(ascii: "b"): raw.append(0x08)
                    case UInt8(ascii: "f"): raw.append(0x0c)
                    case UInt8(ascii: "n"): raw.append(0x0a)
                    case UInt8(ascii: "r"): raw.append(0x0d)
                    case UInt8(ascii: "t"): raw.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let first = hex4() else { return nil }
                        var code = first
                        if (0xd800...0xdbff).contains(first) {
                            guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                            index += 2
                            guard let low = hex4(), (0xdc00...0xdfff).contains(low) else { return nil }
                            code = 0x10000 + ((first - 0xd800) << 10) + (low - 0xdc00)
                        } else if (0xdc00...0xdfff).contains(first) {
                            return nil
                        }
                        guard let scalar = Unicode.Scalar(code) else { return nil }
                        raw.append(contentsOf: Array(String(scalar).utf8))
                    default: return nil
                    }
                default:
                    raw.append(byte)
                }
            }
            return nil
        }

        private mutating func number() -> XiaozhiJSON? {
            let start = index
            func digits() -> Int {
                var count = 0
                while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1; count += 1 }
                return count
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: "0") {
                index += 1
            } else if digits() == 0 {
                return nil
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                if digits() == 0 { return nil }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                if digits() == 0 { return nil }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }
    }
}
#endif
