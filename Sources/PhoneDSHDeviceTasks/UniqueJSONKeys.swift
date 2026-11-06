// SPDX-License-Identifier: MIT
import Foundation

/// Checks raw JSON before Foundation can discard duplicate object members.
struct UniqueJSONKeys {
    private let bytes: [UInt8]
    private var index = 0
    init(_ data: Data) { bytes = Array(data) }

    mutating func check() -> Bool {
        guard value(depth: 0) else { return false }
        whitespace()
        return index == bytes.count
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
    private mutating func value(depth: Int) -> Bool {
        guard depth <= 1000 else { return false }
        whitespace()
        guard index < bytes.count else { return false }
        switch bytes[index] {
        case 123:
            index += 1; whitespace(); var keys = Set<Data>()
            if index < bytes.count && bytes[index] == 125 { index += 1; return true }
            while index < bytes.count {
                whitespace(); guard let key = string(), keys.insert(Data(key.utf8)).inserted else { return false }
                whitespace(); guard index < bytes.count && bytes[index] == 58 else { return false }
                index += 1; guard value(depth: depth + 1) else { return false }; whitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 125 { index += 1; return true }
                guard bytes[index] == 44 else { return false }; index += 1
            }
            return false
        case 91:
            index += 1; whitespace()
            if index < bytes.count && bytes[index] == 93 { index += 1; return true }
            while index < bytes.count {
                guard value(depth: depth + 1) else { return false }; whitespace()
                guard index < bytes.count else { return false }
                if bytes[index] == 93 { index += 1; return true }
                guard bytes[index] == 44 else { return false }; index += 1
            }
            return false
        case 34: return string() != nil
        default:
            let start = index
            while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
            return index > start
        }
    }
}
