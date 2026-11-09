// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: strict JSON value, parser and canonical encoder.
//
// The PCLink v1 contract (§2.3) requires a closed JSON decoder: one UTF-8
// object, no BOM, no leading/trailing bytes, no duplicate member names at any
// depth, no NUL, no unpaired surrogates, no NaN/Infinity and no non-object
// root for wire frames. Foundation's JSONDecoder accepts duplicate keys and
// JSONEncoder escapes `/`, which is not the canonical form used by the pairing
// MACs, so this module carries its own parser/encoder.

import Foundation
import PhoneDSHAgentCore

/// One PCLink JSON value. Integers keep their exact spelling so `seq`,
/// `part`, `v` and canonical pairing objects are not round-tripped through
/// `Double`.
public enum PCLinkJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([PCLinkJSON])
    case object([String: PCLinkJSON])

    public var objectValue: [String: PCLinkJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [PCLinkJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        if case .int(let value) = self { return Double(value) }
        return nil
    }

    public subscript(key: String) -> PCLinkJSON? {
        get { objectValue?[key] }
        set {
            var object = objectValue ?? [:]
            object[key] = newValue
            self = .object(object)
        }
    }

    /// Converts from the PhoneDSHAgentCore JSON value used by
    /// `DSHRemoteTransport`. Integral doubles inside the exactly representable
    /// Int64 range are emitted as integers so DSH does not see `1.0` for an
    /// integer argument.
    public init(_ value: JSONValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let bool):
            self = .bool(bool)
        case .number(let number):
            if number.isFinite,
               number.rounded(.towardZero) == number,
               number >= -9_007_199_254_740_992,
               number <= 9_007_199_254_740_992 {
                self = .int(Int64(number))
            } else if number.isFinite {
                self = .double(number)
            } else {
                self = .null
            }
        case .string(let string):
            self = .string(string)
        case .array(let array):
            self = .array(array.map(PCLinkJSON.init))
        case .object(let object):
            self = .object(object.mapValues(PCLinkJSON.init))
        }
    }

    /// Converts back to the transport value type. Integers outside the exact
    /// Double range become the nearest Double, exactly like `JSONValue`'s own
    /// decoder would have produced.
    public var jsonValue: JSONValue {
        switch self {
        case .null: return .null
        case .bool(let value): return .bool(value)
        case .int(let value): return .number(Double(value))
        case .double(let value): return .number(value)
        case .string(let value): return .string(value)
        case .array(let value): return .array(value.map(\.jsonValue))
        case .object(let value): return .object(value.mapValues(\.jsonValue))
        }
    }
}

// MARK: - Errors

public enum PCLinkJSONError: Error, Equatable, CustomStringConvertible, Sendable {
    case notUTF8
    case byteOrderMark
    case leadingOrTrailingBytes
    case unexpectedEnd
    case unexpectedCharacter(Int)
    case duplicateMember(String)
    case invalidNumber
    case loneSurrogate
    case trailingContent
    case notAnObject
    case invalidEscape
    case numberOutOfRange

    public var description: String {
        switch self {
        case .notUTF8: return "JSON is not valid UTF-8"
        case .byteOrderMark: return "JSON starts with a byte-order mark"
        case .leadingOrTrailingBytes: return "JSON has leading or trailing bytes"
        case .unexpectedEnd: return "JSON ended unexpectedly"
        case .unexpectedCharacter(let offset): return "unexpected JSON character at byte \(offset)"
        case .duplicateMember(let name): return "duplicate JSON member \(name)"
        case .invalidNumber: return "invalid JSON number"
        case .loneSurrogate: return "unpaired JSON surrogate"
        case .trailingContent: return "extra JSON content"
        case .notAnObject: return "JSON root is not an object"
        case .invalidEscape: return "invalid JSON escape"
        case .numberOutOfRange: return "JSON number out of range"
        }
    }
}

// MARK: - Strict parser

public enum PCLinkJSONParser {
    /// Parses exactly one JSON value with no BOM and no leading/trailing bytes.
    public static func parse(_ data: Data) throws -> PCLinkJSON {
        guard !data.isEmpty else { throw PCLinkJSONError.unexpectedEnd }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw PCLinkJSONError.byteOrderMark }
        guard let text = String(data: data, encoding: .utf8) else { throw PCLinkJSONError.notUTF8 }
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> PCLinkJSON {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw PCLinkJSONError.unexpectedEnd }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            throw PCLinkJSONError.byteOrderMark
        }
        guard let first = bytes.first, first != 0x20, first != 0x09, first != 0x0A, first != 0x0D else {
            throw PCLinkJSONError.leadingOrTrailingBytes
        }
        var parser = Parser(bytes: bytes)
        let value = try parser.parseValue(depth: 0)
        if parser.offset != bytes.count {
            if parser.offset < bytes.count, Parser.isWhitespace(bytes[parser.offset]) {
                throw PCLinkJSONError.leadingOrTrailingBytes
            }
            throw PCLinkJSONError.trailingContent
        }
        return value
    }

    /// Parses one JSON value from a document, allowing insignificant
    /// leading/trailing whitespace. This is for fixture/configuration files;
    /// wire frames use the strict `parse`/`parseObject` above.
    public static func parseDocument(_ data: Data) throws -> PCLinkJSON {
        guard !data.isEmpty else { throw PCLinkJSONError.unexpectedEnd }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { throw PCLinkJSONError.byteOrderMark }
        guard let text = String(data: data, encoding: .utf8) else { throw PCLinkJSONError.notUTF8 }
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.offset == text.utf8.count else { throw PCLinkJSONError.trailingContent }
        return value
    }

    public static func parseDocumentObject(_ data: Data) throws -> PCLinkJSON {
        let value = try parseDocument(data)
        guard value.objectValue != nil else { throw PCLinkJSONError.notAnObject }
        return value
    }

    /// Parses and requires a JSON object at the root.
    public static func parseObject(_ data: Data) throws -> PCLinkJSON {
        let value = try parse(data)
        guard value.objectValue != nil else { throw PCLinkJSONError.notAnObject }
        return value
    }

    public static func parseObject(_ text: String) throws -> PCLinkJSON {
        let value = try parse(text)
        guard value.objectValue != nil else { throw PCLinkJSONError.notAnObject }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0

        static func isWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        mutating func skipWhitespace() {
            while offset < bytes.count, Self.isWhitespace(bytes[offset]) { offset += 1 }
        }

        mutating func parseValue(depth: Int) throws -> PCLinkJSON {
            guard depth <= 512 else { throw PCLinkJSONError.unexpectedEnd }
            skipWhitespace()
            guard offset < bytes.count else { throw PCLinkJSONError.unexpectedEnd }
            switch bytes[offset] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                return try parseNumber()
            default:
                throw PCLinkJSONError.unexpectedCharacter(offset)
            }
        }

        mutating func expect(_ literal: String) throws {
            let start = offset
            for byte in literal.utf8 {
                guard offset < bytes.count, bytes[offset] == byte else {
                    throw PCLinkJSONError.unexpectedCharacter(start)
                }
                offset += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> PCLinkJSON {
            offset += 1 // {
            var object: [String: PCLinkJSON] = [:]
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
                offset += 1
                return .object(object)
            }
            while true {
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: "\"") else {
                    throw PCLinkJSONError.unexpectedCharacter(offset)
                }
                let key = try parseString()
                if object[key] != nil { throw PCLinkJSONError.duplicateMember(key) }
                skipWhitespace()
                guard offset < bytes.count, bytes[offset] == UInt8(ascii: ":") else {
                    throw PCLinkJSONError.unexpectedCharacter(offset)
                }
                offset += 1
                object[key] = try parseValue(depth: depth + 1)
                skipWhitespace()
                guard offset < bytes.count else { throw PCLinkJSONError.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") {
                    offset += 1
                    // Reject a trailing comma before the next iteration's guard.
                    skipWhitespace()
                    if offset < bytes.count, bytes[offset] == UInt8(ascii: "}") {
                        throw PCLinkJSONError.unexpectedCharacter(offset)
                    }
                    continue
                }
                if bytes[offset] == UInt8(ascii: "}") {
                    offset += 1
                    return .object(object)
                }
                throw PCLinkJSONError.unexpectedCharacter(offset)
            }
        }

        mutating func parseArray(depth: Int) throws -> PCLinkJSON {
            offset += 1 // [
            var array: [PCLinkJSON] = []
            skipWhitespace()
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
                offset += 1
                return .array(array)
            }
            while true {
                array.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard offset < bytes.count else { throw PCLinkJSONError.unexpectedEnd }
                if bytes[offset] == UInt8(ascii: ",") {
                    offset += 1
                    skipWhitespace()
                    if offset < bytes.count, bytes[offset] == UInt8(ascii: "]") {
                        throw PCLinkJSONError.unexpectedCharacter(offset)
                    }
                    continue
                }
                if bytes[offset] == UInt8(ascii: "]") {
                    offset += 1
                    return .array(array)
                }
                throw PCLinkJSONError.unexpectedCharacter(offset)
            }
        }

        mutating func parseString() throws -> String {
            offset += 1 // opening quote
            var scalars: [Unicode.Scalar] = []
            while true {
                guard offset < bytes.count else { throw PCLinkJSONError.unexpectedEnd }
                let byte = bytes[offset]
                if byte == UInt8(ascii: "\"") {
                    offset += 1
                    return String(String.UnicodeScalarView(scalars))
                }
                if byte == UInt8(ascii: "\\") {
                    offset += 1
                    guard offset < bytes.count else { throw PCLinkJSONError.unexpectedEnd }
                    let escape = bytes[offset]
                    offset += 1
                    switch escape {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let scalar = try parseUnicodeEscape()
                        guard scalar.value != 0 else {
                            throw PCLinkJSONError.unexpectedCharacter(offset)
                        }
                        scalars.append(scalar)
                    default:
                        throw PCLinkJSONError.invalidEscape
                    }
                    continue
                }
                if byte < 0x20 || byte == 0x7F {
                    // NUL and unescaped C0/C1 controls are rejected.
                    throw PCLinkJSONError.unexpectedCharacter(offset)
                }
                if byte < 0x80 {
                    scalars.append(Unicode.Scalar(byte))
                    offset += 1
                    continue
                }
                // Consume one complete UTF-8 scalar from the original text.
                guard let (scalar, length) = try decodeUTF8Scalar(at: offset) else {
                    throw PCLinkJSONError.notUTF8
                }
                scalars.append(scalar)
                offset += length
            }
        }

        mutating func parseUnicodeEscape() throws -> Unicode.Scalar {
            let first = try parseHex4()
            if first >= 0xD800, first <= 0xDBFF {
                guard offset + 1 < bytes.count,
                      bytes[offset] == UInt8(ascii: "\\"),
                      bytes[offset + 1] == UInt8(ascii: "u") else {
                    throw PCLinkJSONError.loneSurrogate
                }
                offset += 2
                let second = try parseHex4()
                guard second >= 0xDC00, second <= 0xDFFF else { throw PCLinkJSONError.loneSurrogate }
                let value = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(value) else { throw PCLinkJSONError.loneSurrogate }
                return scalar
            }
            if first >= 0xDC00, first <= 0xDFFF { throw PCLinkJSONError.loneSurrogate }
            guard let scalar = Unicode.Scalar(first) else { throw PCLinkJSONError.loneSurrogate }
            return scalar
        }

        mutating func parseHex4() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw PCLinkJSONError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[offset]
                offset += 1
                let digit: UInt32
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - 0x30)
                case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - 0x61) + 10
                case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - 0x41) + 10
                default: throw PCLinkJSONError.invalidEscape
                }
                value = value << 4 | digit
            }
            return value
        }

        func decodeUTF8Scalar(at index: Int) throws -> (Unicode.Scalar, Int)? {
            let first = bytes[index]
            let length: Int
            if first & 0xE0 == 0xC0 { length = 2 }
            else if first & 0xF0 == 0xE0 { length = 3 }
            else if first & 0xF8 == 0xF0 { length = 4 }
            else { return nil }
            guard index + length <= bytes.count else { return nil }
            let slice = Array(bytes[index..<(index + length)])
            guard let text = String(bytes: slice, encoding: .utf8),
                  text.unicodeScalars.count == 1,
                  let scalar = text.unicodeScalars.first else { return nil }
            return (scalar, length)
        }

        mutating func parseNumber() throws -> PCLinkJSON {
            let start = offset
            if bytes[offset] == UInt8(ascii: "-") { offset += 1 }
            guard offset < bytes.count else { throw PCLinkJSONError.invalidNumber }
            if bytes[offset] == UInt8(ascii: "0") {
                offset += 1
                if offset < bytes.count, bytes[offset] >= UInt8(ascii: "0"), bytes[offset] <= UInt8(ascii: "9") {
                    throw PCLinkJSONError.invalidNumber
                }
            } else if bytes[offset] >= UInt8(ascii: "1"), bytes[offset] <= UInt8(ascii: "9") {
                while offset < bytes.count, bytes[offset] >= UInt8(ascii: "0"), bytes[offset] <= UInt8(ascii: "9") {
                    offset += 1
                }
            } else {
                throw PCLinkJSONError.invalidNumber
            }
            var isInteger = true
            if offset < bytes.count, bytes[offset] == UInt8(ascii: ".") {
                isInteger = false
                offset += 1
                let digitsStart = offset
                while offset < bytes.count, bytes[offset] >= UInt8(ascii: "0"), bytes[offset] <= UInt8(ascii: "9") {
                    offset += 1
                }
                guard offset > digitsStart else { throw PCLinkJSONError.invalidNumber }
            }
            if offset < bytes.count, bytes[offset] == UInt8(ascii: "e") || bytes[offset] == UInt8(ascii: "E") {
                isInteger = false
                offset += 1
                if offset < bytes.count, bytes[offset] == UInt8(ascii: "+") || bytes[offset] == UInt8(ascii: "-") {
                    offset += 1
                }
                let digitsStart = offset
                while offset < bytes.count, bytes[offset] >= UInt8(ascii: "0"), bytes[offset] <= UInt8(ascii: "9") {
                    offset += 1
                }
                guard offset > digitsStart else { throw PCLinkJSONError.invalidNumber }
            }
            let text = String(decoding: bytes[start..<offset], as: UTF8.self)
            if isInteger, let integer = Int64(text) { return .int(integer) }
            guard let double = Double(text), double.isFinite else { throw PCLinkJSONError.numberOutOfRange }
            return .double(double)
        }
    }
}

// MARK: - Canonical encoder

public enum PCLinkJSONEncoder {
    /// Canonical JSON used by the pairing MACs (§2.3): keys sorted by Unicode
    /// scalar order, no insignificant whitespace, `/` and non-ASCII literal,
    /// lowercase short control escapes, no lone surrogates.
    public static func canonical(_ value: PCLinkJSON) throws -> Data {
        var output = Data()
        try append(value, to: &output, canonical: true, depth: 0)
        return output
    }

    public static func canonicalString(_ value: PCLinkJSON) throws -> String {
        String(decoding: try canonical(value), as: UTF8.self)
    }

    /// Compact wire JSON. Also canonical (sorted keys, literal `/`); PCLink
    /// message bodies do not require canonical bytes, but emitting them keeps
    /// the golden vectors and our own frames byte-stable.
    public static func encode(_ value: PCLinkJSON) throws -> Data {
        var output = Data()
        try append(value, to: &output, canonical: true, depth: 0)
        return output
    }

    public static func encodeString(_ value: PCLinkJSON) throws -> String {
        String(decoding: try encode(value), as: UTF8.self)
    }

    private static func append(_ value: PCLinkJSON, to output: inout Data, canonical: Bool, depth: Int) throws {
        guard depth <= 512 else { throw PCLinkJSONError.unexpectedEnd }
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let bool):
            output.append(contentsOf: (bool ? "true" : "false").utf8)
        case .int(let int):
            output.append(contentsOf: String(int).utf8)
        case .double(let double):
            guard double.isFinite else { throw PCLinkJSONError.numberOutOfRange }
            var text = String(double)
            if text == "-0.0" { text = "0" }
            output.append(contentsOf: text.utf8)
        case .string(let string):
            try appendString(string, to: &output)
        case .array(let array):
            output.append(UInt8(ascii: "["))
            for (index, item) in array.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try append(item, to: &output, canonical: canonical, depth: depth + 1)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let object):
            output.append(UInt8(ascii: "{"))
            let keys = object.keys.sorted { lhs, rhs in
                lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try appendString(key, to: &output)
                output.append(UInt8(ascii: ":"))
                try append(object[key]!, to: &output, canonical: canonical, depth: depth + 1)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static func appendString(_ string: String, to output: inout Data) throws {
        output.append(UInt8(ascii: "\""))
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: output.append(contentsOf: "\\\"".utf8)
            case 0x5C: output.append(contentsOf: "\\\\".utf8)
            case 0x08: output.append(contentsOf: "\\b".utf8)
            case 0x09: output.append(contentsOf: "\\t".utf8)
            case 0x0A: output.append(contentsOf: "\\n".utf8)
            case 0x0C: output.append(contentsOf: "\\f".utf8)
            case 0x0D: output.append(contentsOf: "\\r".utf8)
            case 0x00...0x1F:
                let hex = String(format: "\\u%04x", scalar.value)
                output.append(contentsOf: hex.utf8)
            default:
                if scalar.value >= 0xD800, scalar.value <= 0xDFFF {
                    throw PCLinkJSONError.loneSurrogate
                }
                output.append(contentsOf: String(scalar).utf8)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}

// MARK: - Closed-object helpers

public extension PCLinkJSON {
    /// Requires an object whose members are exactly `required` plus the
    /// optional set. Unknown members are `bad_frame` (§2.3).
    func closedObject(required: Set<String>, optional: Set<String> = []) throws -> [String: PCLinkJSON] {
        guard let object = objectValue else { throw PCLinkError.badFrame("expected a JSON object") }
        for key in object.keys where !required.contains(key) && !optional.contains(key) {
            throw PCLinkError.badFrame("unknown member \(key)")
        }
        for key in required where object[key] == nil {
            throw PCLinkError.badFrame("missing member \(key)")
        }
        return object
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else {
            throw PCLinkError.badFrame("\(key) must be a string")
        }
        return value
    }

    func requiredInt(_ key: String) throws -> Int64 {
        guard let value = self[key]?.intValue else {
            throw PCLinkError.badFrame("\(key) must be an integer")
        }
        return value
    }

    func requiredBool(_ key: String) throws -> Bool {
        guard let value = self[key]?.boolValue else {
            throw PCLinkError.badFrame("\(key) must be a boolean")
        }
        return value
    }
}
