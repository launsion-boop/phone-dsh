// SPDX-License-Identifier: MIT
// Minimal strict DER reader/writer for the pinned self-signed certificate
// profile (§6.2). Definite, minimally encoded lengths only.
import Foundation

struct DERNode: Equatable {
    let tag: UInt8
    /// Content octets.
    let content: ArraySlice<UInt8>
    /// The complete TLV encoding.
    let encoded: ArraySlice<UInt8>

    var isConstructed: Bool { tag & 0x20 != 0 }

    struct Malformed: Error {}

    /// Parses exactly one TLV filling `bytes`.
    static func parse(_ bytes: ArraySlice<UInt8>) throws -> DERNode {
        var reader = DERReader(bytes)
        let node = try reader.next()
        guard reader.isAtEnd else { throw Malformed() }
        return node
    }

    func children() throws -> [DERNode] {
        guard isConstructed else { throw Malformed() }
        var reader = DERReader(content)
        var out: [DERNode] = []
        while !reader.isAtEnd { out.append(try reader.next()) }
        return out
    }
}

struct DERReader {
    private let bytes: ArraySlice<UInt8>
    private var index: Int

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes; index = bytes.startIndex }

    var isAtEnd: Bool { index == bytes.endIndex }

    mutating func next() throws -> DERNode {
        let start = index
        guard index < bytes.endIndex else { throw DERNode.Malformed() }
        let tag = bytes[index]; index += 1
        guard tag & 0x1f != 0x1f else { throw DERNode.Malformed() } // no high tag numbers in this profile
        guard index < bytes.endIndex else { throw DERNode.Malformed() }
        let first = bytes[index]; index += 1
        var length = 0
        if first < 0x80 {
            length = Int(first)
        } else {
            let count = Int(first & 0x7f)
            guard (1...3).contains(count), bytes.endIndex - index >= count else { throw DERNode.Malformed() }
            for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            // DER: the shortest form, no leading zero octet.
            guard length >= 0x80, length >> (8 * (count - 1)) != 0 else { throw DERNode.Malformed() }
        }
        guard bytes.endIndex - index >= length else { throw DERNode.Malformed() }
        let content = bytes[index..<index + length]
        index += length
        return DERNode(tag: tag, content: content, encoded: bytes[start..<index])
    }
}

enum DERTag {
    static let boolean: UInt8 = 0x01, integer: UInt8 = 0x02, bitString: UInt8 = 0x03, octetString: UInt8 = 0x04
    static let null: UInt8 = 0x05, oid: UInt8 = 0x06, utf8String: UInt8 = 0x0c, printableString: UInt8 = 0x13
    static let utcTime: UInt8 = 0x17, generalizedTime: UInt8 = 0x18
    static let sequence: UInt8 = 0x30, set: UInt8 = 0x31
    static func context(_ n: UInt8, constructed: Bool = true) -> UInt8 { 0x80 | (constructed ? 0x20 : 0) | n }
}

enum DEROID {
    static let ecPublicKey: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    static let prime256v1: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07]
    static let ecdsaWithSHA256: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02]
    static let commonName: [UInt8] = [0x55, 0x04, 0x03]
    static let basicConstraints: [UInt8] = [0x55, 0x1d, 0x13]
    static let keyUsage: [UInt8] = [0x55, 0x1d, 0x0f]
    static let extendedKeyUsage: [UInt8] = [0x55, 0x1d, 0x25]
}

enum DERWriter {
    static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        let n = content.count
        if n < 0x80 { out.append(UInt8(n)) }
        else if n < 0x100 { out += [0x81, UInt8(n)] }
        else if n < 0x10000 { out += [0x82, UInt8(n >> 8), UInt8(n & 0xff)] }
        else { out += [0x83, UInt8(n >> 16), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)] }
        return out + content
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(DERTag.sequence, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(DERTag.set, items.flatMap { $0 }) }
    static func oid(_ body: [UInt8]) -> [UInt8] { tlv(DERTag.oid, body) }

    /// A non-negative INTEGER from big-endian magnitude bytes.
    static func unsignedInteger(_ magnitude: [UInt8]) -> [UInt8] {
        var body = Array(magnitude.drop { $0 == 0 })
        if body.isEmpty { body = [0] }
        if body[0] & 0x80 != 0 { body.insert(0, at: 0) }
        return tlv(DERTag.integer, body)
    }

    static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] { tlv(DERTag.bitString, [unusedBits] + bytes) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(DERTag.octetString, bytes) }
    static func boolean(_ value: Bool) -> [UInt8] { tlv(DERTag.boolean, [value ? 0xff : 0x00]) }
}
