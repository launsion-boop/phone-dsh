// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: base32, base64url, Crockford and hex codecs (§2.1, §4.1).

import Foundation
import Security

public enum PCLinkEncodingError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidBase64URL
    case nonCanonicalBase64URL
    case wrongLength(expected: Int, actual: Int)
    case invalidBase32
    case invalidCrockford
    case invalidHex

    public var description: String {
        switch self {
        case .invalidBase64URL: return "invalid base64url"
        case .nonCanonicalBase64URL: return "non-canonical base64url"
        case .wrongLength(let expected, let actual): return "expected \(expected) bytes, got \(actual)"
        case .invalidBase32: return "invalid base32"
        case .invalidCrockford: return "invalid Crockford base32 input"
        case .invalidHex: return "invalid hex"
        }
    }
}

public enum PCLinkBase64URL {
    private static let alphabet: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let lookup: [UInt8: UInt8] = {
        var table: [UInt8: UInt8] = [:]
        for (index, character) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8.enumerated() {
            table[character] = UInt8(index)
        }
        return table
    }()

    public static func encode(_ data: Data) -> String {
        // `Data` from CryptoKit/Foundation may carry a non-zero startIndex, so
        // index through a normalized byte array rather than `data[i]`.
        let bytes = [UInt8](data)
        var result = ""
        result.reserveCapacity((bytes.count * 4 + 2) / 3)
        var index = 0
        while index + 3 <= bytes.count {
            let value = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            result.append(alphabet[Int((value >> 18) & 0x3F)])
            result.append(alphabet[Int((value >> 12) & 0x3F)])
            result.append(alphabet[Int((value >> 6) & 0x3F)])
            result.append(alphabet[Int(value & 0x3F)])
            index += 3
        }
        let remaining = bytes.count - index
        if remaining == 1 {
            let value = UInt32(bytes[index]) << 16
            result.append(alphabet[Int((value >> 18) & 0x3F)])
            result.append(alphabet[Int((value >> 12) & 0x3F)])
        } else if remaining == 2 {
            let value = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
            result.append(alphabet[Int((value >> 18) & 0x3F)])
            result.append(alphabet[Int((value >> 12) & 0x3F)])
            result.append(alphabet[Int((value >> 6) & 0x3F)])
        }
        return result
    }

    /// Strict RFC 4648 base64url without padding: rejects `=`, any character
    /// outside the URL alphabet, impossible lengths and a non-canonical
    /// re-encoding (unused low bits must be zero).
    public static func decode(_ text: String, expectedLength: Int? = nil) throws -> Data {
        guard !text.isEmpty else { throw PCLinkEncodingError.invalidBase64URL }
        var values: [UInt8] = []
        values.reserveCapacity(text.utf8.count)
        for byte in text.utf8 {
            guard let value = lookup[byte] else { throw PCLinkEncodingError.invalidBase64URL }
            values.append(value)
        }
        guard values.count % 4 != 1 else { throw PCLinkEncodingError.invalidBase64URL }
        if let expectedLength {
            let produced = values.count / 4 * 3 + [0, 0, 1, 2][values.count % 4]
            guard produced == expectedLength else {
                throw PCLinkEncodingError.wrongLength(expected: expectedLength, actual: produced)
            }
        }
        var data = Data()
        data.reserveCapacity(values.count / 4 * 3 + 2)
        var index = 0
        while index + 4 <= values.count {
            let value = UInt32(values[index]) << 18 | UInt32(values[index + 1]) << 12
                | UInt32(values[index + 2]) << 6 | UInt32(values[index + 3])
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
            index += 4
        }
        let remaining = values.count - index
        if remaining == 2 {
            let value = UInt32(values[index]) << 18 | UInt32(values[index + 1]) << 12
            guard value & 0xFFFF == 0 else { throw PCLinkEncodingError.nonCanonicalBase64URL }
            data.append(UInt8((value >> 16) & 0xFF))
        } else if remaining == 3 {
            let value = UInt32(values[index]) << 18 | UInt32(values[index + 1]) << 12
                | UInt32(values[index + 2]) << 6
            guard value & 0xFF == 0 else { throw PCLinkEncodingError.nonCanonicalBase64URL }
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        if let expectedLength, data.count != expectedLength {
            throw PCLinkEncodingError.wrongLength(expected: expectedLength, actual: data.count)
        }
        // Defense in depth against a decoder bug: the canonical text must be
        // byte-identical to what we would emit.
        guard encode(data) == text else { throw PCLinkEncodingError.nonCanonicalBase64URL }
        return data
    }

    public static func decode(_ text: String, expectedBytes: Int) throws -> Data {
        try decode(text, expectedLength: expectedBytes)
    }
}

public enum PCLinkBase32 {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    /// RFC 4648 base32 without padding (`A-Z2-7`).
    public static func encode(_ data: Data) -> String {
        var result = ""
        var buffer: UInt64 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt64(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                result.append(alphabet[Int((buffer >> UInt64(bits)) & 0x1F)])
            }
        }
        if bits > 0 {
            result.append(alphabet[Int((buffer << UInt64(5 - bits)) & 0x1F)])
        }
        return result
    }

    public static func decode(_ text: String) throws -> Data {
        var buffer: UInt64 = 0
        var bits = 0
        var data = Data()
        for character in text.uppercased() {
            guard let index = alphabet.firstIndex(of: character) else {
                throw PCLinkEncodingError.invalidBase32
            }
            buffer = (buffer << 5) | UInt64(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                data.append(UInt8((buffer >> UInt64(bits)) & 0xFF))
            }
        }
        // Unused trailing bits must be zero.
        if bits > 0, buffer & ((1 << UInt64(bits)) - 1) != 0 {
            throw PCLinkEncodingError.invalidBase32
        }
        return data
    }

    /// `machineId = lower(base32_nopad(sha256(E)))[0:26]`.
    public static func machineId(fromPublicKey publicKey: Data) -> String {
        let digest = PCLinkCrypto.sha256(publicKey)
        return String(encode(digest).prefix(26)).lowercased()
    }
}

public enum PCLinkCrockford {
    public static let canonicalAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    /// Normalizes manual-code input: uppercases, removes `-`, whitespace and
    /// other separators, maps `O`→`0` and `I`/`L`→`1`, then requires exactly
    /// 16 characters from the canonical alphabet. `U` and everything else is
    /// rejected.
    public static func normalize(_ input: String) throws -> String {
        var scalars: [Unicode.Scalar] = []
        for scalar in input.unicodeScalars {
            if scalar == "-" { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            let upper = String(scalar).uppercased()
            guard upper.unicodeScalars.count == 1 else {
                throw PCLinkEncodingError.invalidCrockford
            }
            switch upper {
            case "O": scalars.append("0")
            case "I", "L": scalars.append("1")
            default:
                guard canonicalAlphabet.unicodeScalars.contains(where: { $0 == upper.unicodeScalars.first! }) else {
                    throw PCLinkEncodingError.invalidCrockford
                }
                scalars.append(upper.unicodeScalars.first!)
            }
        }
        guard scalars.count == 16 else { throw PCLinkEncodingError.invalidCrockford }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Decodes the 16 characters as a big-endian 80-bit value into 10 bytes.
    public static func decode(_ input: String) throws -> Data {
        let normalized = try normalize(input)
        var bytes = [UInt8](repeating: 0, count: 10)
        var accumulator: UInt32 = 0
        var bits = 0
        var byteIndex = 0
        for character in normalized {
            guard let index = canonicalAlphabet.firstIndex(of: character) else {
                throw PCLinkEncodingError.invalidCrockford
            }
            accumulator = (accumulator << 5) | UInt32(canonicalAlphabet.distance(from: canonicalAlphabet.startIndex, to: index))
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes[byteIndex] = UInt8((accumulator >> UInt32(bits)) & 0xFF)
                byteIndex += 1
                accumulator &= (1 << UInt32(bits)) - 1
            }
        }
        guard byteIndex == 10, bits == 0 else { throw PCLinkEncodingError.invalidCrockford }
        return Data(bytes)
    }

    /// Encodes a 10-byte value as the 16-character canonical manual code.
    public static func encode(_ data: Data) throws -> String {
        guard data.count == 10 else {
            throw PCLinkEncodingError.wrongLength(expected: 10, actual: data.count)
        }
        var result = ""
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in data {
            accumulator = (accumulator << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                let index = Int((accumulator >> UInt32(bits)) & 0x1F)
                result.append(canonicalAlphabet[canonicalAlphabet.index(canonicalAlphabet.startIndex, offsetBy: index)])
            }
            accumulator &= (1 << UInt32(bits)) - 1
        }
        if bits == 0 { return result }
        return result
    }

    public static func display(_ input: String) throws -> String {
        let normalized = try normalize(input)
        let characters = Array(normalized)
        return "\(String(characters[0..<4]))-\(String(characters[4..<8]))-\(String(characters[8..<12]))-\(String(characters[12..<16]))"
    }
}

public enum PCLinkHex {
    public static func encode(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func decode(_ text: String) throws -> Data {
        guard text.count % 2 == 0 else { throw PCLinkEncodingError.invalidHex }
        var data = Data()
        data.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            let pair = text[index..<next]
            guard pair.allSatisfy({ char in
                char.isASCII && (char.isNumber
                    || (char >= "a" && char <= "f")
                    || (char >= "A" && char <= "F"))
            }), let byte = UInt8(pair, radix: 16) else {
                throw PCLinkEncodingError.invalidHex
            }
            data.append(byte)
            index = next
        }
        return data
    }
}

public enum PCLinkRandom {
    /// CSPRNG bytes. `SecRandomCopyBytes` is the platform CSPRNG on both iOS
    /// and macOS; a failure is fatal because proceeding would generate a
    /// predictable key or nonce.
    public static func bytes(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, base)
        }
        guard status == errSecSuccess else {
            throw PCLinkError.storage("CSPRNG failed with OSStatus \(status)")
        }
        return data
    }

    public static func nonce(_ count: Int) throws -> Data { try bytes(count) }
}
