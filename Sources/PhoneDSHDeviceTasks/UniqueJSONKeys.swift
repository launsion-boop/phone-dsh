// SPDX-License-Identifier: MIT
import Foundation

/// Checks raw JSON before Foundation can discard duplicate object members.
///
/// Public so a second boundary can reuse this scanner instead of copying it:
/// `PhoneDSHBLE`'s device-panel evaluator must detect duplicate member names on
/// the raw descriptor bytes before Foundation parses them (device-panel.md §4.2).
/// Semantics are unchanged.
public struct UniqueJSONKeys {
    private var bytes: [UInt8]
    private var index = 0
    public init(_ data: Data) { bytes = Array(data) }

    /// A single valid JSON value with no duplicate object member names at any
    /// depth, optionally rejecting U+0000 inside strings.
    public mutating func check(rejectNUL: Bool = false) -> Bool {
        guard value(depth: 0, rejectNUL: rejectNUL) else { return false }
        whitespace()
        return index == bytes.count
    }

    /// Returns original bytes of selected top-level members and rejects
    /// duplicates of known names. Duplicate unknown names are preserved for
    /// journal compatibility; callers validate the selected values themselves.
    mutating func rawRootMembers(capturing names: Set<String>, enforcingUnique unique: Set<String>) -> [String: Data]? {
        guard transcodeRootToUTF8() else { return nil }
        whitespace()
        guard index < bytes.count, bytes[index] == 123 else { return nil }
        index += 1
        whitespace()
        var found: [Data: Data] = [:]
        var seen = Set<Data>()
        let nameBytes = Set(names.map { Data($0.utf8) })
        let uniqueBytes = Set(unique.map { Data($0.utf8) })
        if index < bytes.count, bytes[index] == 125 {
            index += 1
            whitespace()
            return index == bytes.count ? [:] : nil
        }
        while index < bytes.count {
            whitespace()
            guard let key = string() else { return nil }
            let keyBytes = Data(key.utf8)
            if uniqueBytes.contains(keyBytes) && !seen.insert(keyBytes).inserted { return nil }
            whitespace()
            guard index < bytes.count, bytes[index] == 58 else { return nil }
            index += 1
            whitespace()
            let start = index
            guard value(depth: 1, rejectDuplicates: false) else { return nil }
            if nameBytes.contains(keyBytes) { found[keyBytes] = Data(bytes[start..<index]) }
            whitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == 125 {
                index += 1
                whitespace()
                guard index == bytes.count else { return nil }
                var result: [String: Data] = [:]
                for name in names { result[name] = found[Data(name.utf8)] }
                return result
            }
            guard bytes[index] == 44 else { return nil }
            index += 1
        }
        return nil
    }

    /// JSONDecoder accepts several Unicode encodings for an existing parent.
    /// Convert only the text, never its object model, and reject incomplete
    /// code units which Foundation's String conversion can otherwise drop.
    private mutating func transcodeRootToUTF8() -> Bool {
        let source = Data(bytes)
        let encoding: String.Encoding
        let skip: Int
        if bytes.starts(with: [0, 0, 0xfe, 0xff]) {
            encoding = .utf32BigEndian; skip = 4
        } else if bytes.starts(with: [0xff, 0xfe, 0, 0]) {
            encoding = .utf32LittleEndian; skip = 4
        } else if bytes.starts(with: [0xfe, 0xff]) {
            encoding = .utf16BigEndian; skip = 2
        } else if bytes.starts(with: [0xff, 0xfe]) {
            encoding = .utf16LittleEndian; skip = 2
        } else if bytes.starts(with: [0xef, 0xbb, 0xbf]) {
            encoding = .utf8; skip = 3
        } else if bytes.count >= 4 && bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0 {
            encoding = .utf32BigEndian; skip = 0
        } else if bytes.count >= 4 && bytes[1] == 0 && bytes[2] == 0 && bytes[3] == 0 {
            encoding = .utf32LittleEndian; skip = 0
        } else if bytes.count >= 4 && bytes[0] == 0 && bytes[2] == 0 {
            encoding = .utf16BigEndian; skip = 0
        } else if bytes.count >= 4 && bytes[1] == 0 && bytes[3] == 0 {
            encoding = .utf16LittleEndian; skip = 0
        } else {
            encoding = .utf8; skip = 0
        }
        let payload = Data(source.dropFirst(skip))
        guard let text = String(data: payload, encoding: encoding),
              text.data(using: encoding) == payload else { return false }
        bytes = Array(text.utf8)
        index = 0
        return true
    }

    private static func isJSONNumber(_ token: ArraySlice<UInt8>) -> Bool {
        let value = token
        var i = value.startIndex
        guard i < value.endIndex else { return false }
        if value[i] == 45 { i += 1 }
        guard i < value.endIndex else { return false }
        if value[i] == 48 {
            i += 1
        } else {
            guard (49...57).contains(value[i]) else { return false }
            i += 1
            while i < value.endIndex && (48...57).contains(value[i]) { i += 1 }
        }
        if i < value.endIndex && value[i] == 46 {
            i += 1
            let start = i
            while i < value.endIndex && (48...57).contains(value[i]) { i += 1 }
            guard i > start else { return false }
        }
        if i < value.endIndex && (value[i] == 69 || value[i] == 101) {
            i += 1
            if i < value.endIndex && (value[i] == 43 || value[i] == 45) { i += 1 }
            let start = i
            while i < value.endIndex && (48...57).contains(value[i]) { i += 1 }
            guard i > start else { return false }
        }
        return i == value.endIndex
    }
    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func string() -> String? {
        guard index < bytes.count, bytes[index] == 34 else { return nil }
        let start = index; index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { return nil }; index += 1; continue }
            if byte == 34 {
                return try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
            }
        }
        return nil
    }
    private enum ValueState { case objectKey, objectAfterValue, arrayValue, arrayAfterValue }
    private struct ValueFrame {
        var state: ValueState
        // Data preserves decoded scalar bytes; String equality normalizes keys.
        var keys = Set<Data>()
    }

    private mutating func value(depth: Int, rejectDuplicates: Bool = true, rejectNUL: Bool = false) -> Bool {
        var frames: [ValueFrame] = []
        var needValue = true
        var valueDepth = depth
        while true {
            if needValue {
                guard valueDepth <= 1000 else { return false }
                whitespace()
                guard index < bytes.count else { return false }
                switch bytes[index] {
                case 123:
                    index += 1; whitespace()
                    if index < bytes.count && bytes[index] == 125 { index += 1 }
                    else { frames.append(ValueFrame(state: .objectKey)) }
                case 91:
                    index += 1; whitespace()
                    if index < bytes.count && bytes[index] == 93 { index += 1 }
                    else { frames.append(ValueFrame(state: .arrayValue)) }
                case 34:
                    guard let text = string(), !rejectNUL || !text.utf8.contains(0) else { return false }
                default:
                    let start = index
                    while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                    let token = bytes[start..<index]
                    guard token.elementsEqual("true".utf8) || token.elementsEqual("false".utf8) ||
                            token.elementsEqual("null".utf8) || Self.isJSONNumber(token) else { return false }
                }
                needValue = false
            }
            guard !frames.isEmpty else { return true }
            let last = frames.count - 1
            switch frames[last].state {
            case .objectKey:
                whitespace()
                guard let key = string(), !rejectNUL || !key.utf8.contains(0) else { return false }
                if rejectDuplicates && !frames[last].keys.insert(Data(key.utf8)).inserted { return false }
                whitespace()
                guard index < bytes.count, bytes[index] == 58 else { return false }
                index += 1
                frames[last].state = .objectAfterValue
                valueDepth = depth + frames.count
                needValue = true
            case .arrayValue:
                frames[last].state = .arrayAfterValue
                valueDepth = depth + frames.count
                needValue = true
            case .objectAfterValue:
                whitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 125 { index += 1; frames.removeLast() }
                else if bytes[index] == 44 { index += 1; frames[last].state = .objectKey }
                else { return false }
            case .arrayAfterValue:
                whitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 93 { index += 1; frames.removeLast() }
                else if bytes[index] == 44 { index += 1; frames[last].state = .arrayValue }
                else { return false }
            }
        }
    }

}
