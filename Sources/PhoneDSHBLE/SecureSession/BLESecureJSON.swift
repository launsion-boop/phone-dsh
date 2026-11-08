// SPDX-License-Identifier: MIT
// §7.2 payload decoding: one UTF-8 JSON object, no BOM, no duplicate member
// names at any depth (compared as Unicode scalar sequences), no NUL and no
// unpaired surrogate, no NaN/Infinity. Numbers keep their source token so an
// integer field can refuse a fraction or exponent.
import Foundation

public indirect enum BLESecureJSON: Equatable, Sendable {
    case object([Member])
    case array([BLESecureJSON])
    case string(String)
    /// The exact JSON number token.
    case number(String)
    case bool(Bool)
    case null

    public struct Member: Equatable, Sendable {
        public let name: String
        public let value: BLESecureJSON
    }

    public struct Invalid: Error, Equatable, Sendable {
        public let reason: String
    }

    static let maxDepth = 64

    // MARK: access

    public subscript(_ name: String) -> BLESecureJSON? {
        guard case .object(let members) = self else { return nil }
        let key = Array(name.utf8)
        return members.first { Array($0.name.utf8) == key }?.value
    }

    /// Member names as UTF-8 byte strings (scalar exact).
    var memberNames: [String]? {
        guard case .object(let members) = self else { return nil }
        return members.map(\.name)
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var isNull: Bool { self == .null }

    /// A JSON integer: an optional minus and digits only, no fraction or exponent.
    var integerValue: Int64? {
        guard case .number(let token) = self else { return nil }
        let bytes = Array(token.utf8)
        let digits = bytes.first == 45 ? Array(bytes.dropFirst()) : bytes
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }), digits.count <= 18 else { return nil }
        return Int64(token)
    }

    // MARK: parse

    public static func parse(_ data: [UInt8]) throws -> BLESecureJSON {
        if data.starts(with: [0xef, 0xbb, 0xbf]) { throw Invalid(reason: "byte order mark") }
        let text = String(decoding: data, as: UTF8.self)
        guard Array(text.utf8) == data else { throw Invalid(reason: "invalid UTF-8") }
        var parser = Parser(bytes: data)
        parser.skipWhitespace()
        let value = try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.index == data.count else { throw Invalid(reason: "trailing data") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func skipWhitespace() {
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) throws -> BLESecureJSON {
            guard depth <= BLESecureJSON.maxDepth else { throw Invalid(reason: "nesting") }
            guard index < bytes.count else { throw Invalid(reason: "end of input") }
            switch bytes[index] {
            case 123: return try object(depth: depth)
            case 91: return try array(depth: depth)
            case 34: return .string(try string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard bytes.count - index >= w.count, Array(bytes[index..<index + w.count]) == w else {
                throw Invalid(reason: "invalid literal")
            }
            index += w.count
        }

        mutating func object(depth: Int) throws -> BLESecureJSON {
            index += 1
            var members: [Member] = []
            var seen = Set<[UInt8]>()
            skipWhitespace()
            if index < bytes.count, bytes[index] == 125 { index += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 34 else { throw Invalid(reason: "member name") }
                let name = try string()
                guard seen.insert(Array(name.utf8)).inserted else { throw Invalid(reason: "duplicate member") }
                skipWhitespace()
                guard index < bytes.count, bytes[index] == 58 else { throw Invalid(reason: "colon") }
                index += 1
                skipWhitespace()
                members.append(Member(name: name, value: try value(depth: depth + 1)))
                skipWhitespace()
                guard index < bytes.count else { throw Invalid(reason: "end of object") }
                if bytes[index] == 44 { index += 1; continue }
                if bytes[index] == 125 { index += 1; return .object(members) }
                throw Invalid(reason: "object separator")
            }
        }

        mutating func array(depth: Int) throws -> BLESecureJSON {
            index += 1
            var items: [BLESecureJSON] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == 93 { index += 1; return .array([]) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard index < bytes.count else { throw Invalid(reason: "end of array") }
                if bytes[index] == 44 { index += 1; continue }
                if bytes[index] == 93 { index += 1; return .array(items) }
                throw Invalid(reason: "array separator")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw Invalid(reason: "escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let b = bytes[index]
                let digit: UInt8
                switch b {
                case 48...57: digit = b - 48
                case 97...102: digit = b - 87
                case 65...70: digit = b - 55
                default: throw Invalid(reason: "escape")
                }
                value = value << 4 | UInt32(digit); index += 1
            }
            return value
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = [UInt8]()
            func flush() { if !run.isEmpty { scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars); run.removeAll() } }
            while true {
                guard index < bytes.count else { throw Invalid(reason: "unterminated string") }
                let b = bytes[index]
                if b == 34 { index += 1; break }
                if b < 0x20 { throw Invalid(reason: "control character in string") }
                if b != 92 { run.append(b); index += 1; continue }
                flush()
                index += 1
                guard index < bytes.count else { throw Invalid(reason: "escape") }
                let e = bytes[index]; index += 1
                switch e {
                case 34: scalars.append("\"")
                case 92: scalars.append("\\")
                case 47: scalars.append("/")
                case 98: scalars.append("\u{08}")
                case 102: scalars.append("\u{0C}")
                case 110: scalars.append("\n")
                case 114: scalars.append("\r")
                case 116: scalars.append("\t")
                case 117:
                    let first = try hex4()
                    var code = first
                    if (0xD800...0xDBFF).contains(first) {
                        guard bytes.count - index >= 6, bytes[index] == 92, bytes[index + 1] == 117 else {
                            throw Invalid(reason: "unpaired surrogate")
                        }
                        index += 2
                        let second = try hex4()
                        guard (0xDC00...0xDFFF).contains(second) else { throw Invalid(reason: "unpaired surrogate") }
                        code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(first) {
                        throw Invalid(reason: "unpaired surrogate")
                    }
                    guard let scalar = Unicode.Scalar(code) else { throw Invalid(reason: "escape") }
                    scalars.append(scalar)
                default: throw Invalid(reason: "escape")
                }
            }
            flush()
            let result = String(scalars)
            guard !result.unicodeScalars.contains(where: { $0.value == 0 }) else { throw Invalid(reason: "NUL") }
            return result
        }

        mutating func number() throws -> String {
            let start = index
            if index < bytes.count, bytes[index] == 45 { index += 1 }
            guard index < bytes.count else { throw Invalid(reason: "number") }
            if bytes[index] == 48 { index += 1 }
            else if (49...57).contains(bytes[index]) { while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 } }
            else { throw Invalid(reason: "number") }
            if index < bytes.count, bytes[index] == 46 {
                index += 1
                let digits = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw Invalid(reason: "number") }
            }
            if index < bytes.count, bytes[index] == 69 || bytes[index] == 101 {
                index += 1
                if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
                let digits = index
                while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 }
                guard index > digits else { throw Invalid(reason: "number") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }

    // MARK: encode

    /// Compact encoding with the given member order policy. `sorted` gives the
    /// §9.2 canonical form (keys sorted by Unicode scalar values, `/` and
    /// non-ASCII literal, `\b \t \n \f \r`, other controls `\u00xx`).
    public func encoded(sorted: Bool = false) -> [UInt8] {
        var out: [UInt8] = []
        encode(into: &out, sorted: sorted)
        return out
    }

    private func encode(into out: inout [UInt8], sorted: Bool) {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(let token): out += Array(token.utf8)
        case .string(let s): Self.encodeString(s, into: &out)
        case .array(let items):
            out.append(91)
            for (i, item) in items.enumerated() { if i > 0 { out.append(44) }; item.encode(into: &out, sorted: sorted) }
            out.append(93)
        case .object(let members):
            let ordered = sorted ? members.sorted { $0.name.unicodeScalars.lexicographicallyPrecedes($1.name.unicodeScalars) { $0.value < $1.value } } : members
            out.append(123)
            for (i, member) in ordered.enumerated() {
                if i > 0 { out.append(44) }
                Self.encodeString(member.name, into: &out)
                out.append(58)
                member.value.encode(into: &out, sorted: sorted)
            }
            out.append(125)
        }
    }

    static func encodeString(_ s: String, into out: inout [UInt8]) {
        out.append(34)
        let hex = Array("0123456789abcdef".utf8)
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += [92, 34]
            case 0x5C: out += [92, 92]
            case 0x08: out += [92, 98]
            case 0x09: out += [92, 116]
            case 0x0A: out += [92, 110]
            case 0x0C: out += [92, 102]
            case 0x0D: out += [92, 114]
            case 0..<0x20: out += [92, 117, 48, 48, hex[Int(scalar.value >> 4)], hex[Int(scalar.value & 15)]]
            default: out += Array(String(scalar).utf8)
            }
        }
        out.append(34)
    }
}
