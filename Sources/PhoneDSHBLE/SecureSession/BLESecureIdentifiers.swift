// SPDX-License-Identifier: MIT
// secure-session-v1 identifiers (spec/device/v1/ble-secure-session.md §2, §3.4).
import CryptoKit
import Foundation
import Security

/// The first failing §2 public-key check, in the normative order.
public enum BLESecureKeyRejection: String, Error, Equatable, Sendable {
    case notHex = "not_hex", uppercase, length, notUncompressed = "not_uncompressed"
    case coordinateRange = "coordinate_range", notOnCurve = "not_on_curve"
}

public enum BLESecureIdentifiers {
    public static let devicePrefix = "ble:"
    public static let phonePrefix = "phone:"
    public static let boardTokenPrefix = "pdsh-board-v1:"
    public static let phoneTokenPrefix = "pdsh-phone-v1:"

    /// P-256 field prime, big-endian.
    static let fieldPrime: [UInt8] = [
        0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    ]

    // MARK: hex

    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let digits = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        for byte in bytes { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// Lowercase-only hex of an exact character length.
    public static func isLowerHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func decodeLowerHex(_ text: String) -> [UInt8]? {
        let utf8 = Array(text.utf8)
        guard utf8.count % 2 == 0 else { return nil }
        var out = [UInt8](); out.reserveCapacity(utf8.count / 2)
        var index = 0
        while index < utf8.count {
            guard let high = nibble(utf8[index], upper: false), let low = nibble(utf8[index + 1], upper: false) else { return nil }
            out.append(high << 4 | low); index += 2
        }
        return out
    }

    private static func nibble(_ byte: UInt8, upper: Bool) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        case 65...70 where upper: return byte - 55
        default: return nil
        }
    }

    // MARK: §2 public keys

    /// Validates a text public key and returns its 65 raw bytes.
    public static func publicKey(hex text: String) throws -> [UInt8] {
        let utf8 = Array(text.utf8)
        guard utf8.count % 2 == 0, utf8.allSatisfy({ nibble($0, upper: true) != nil }) else { throw BLESecureKeyRejection.notHex }
        guard !utf8.contains(where: { (65...70).contains($0) }) else { throw BLESecureKeyRejection.uppercase }
        let raw = decodeLowerHex(text) ?? []
        try validate(publicKey: raw)
        return raw
    }

    /// The §2 checks after decoding: length, prefix, coordinate range, curve.
    public static func validate(publicKey raw: [UInt8]) throws {
        guard raw.count == 65 else { throw BLESecureKeyRejection.length }
        guard raw[0] == 0x04 else { throw BLESecureKeyRejection.notUncompressed }
        guard lessThanPrime(raw[1..<33]), lessThanPrime(raw[33..<65]) else { throw BLESecureKeyRejection.coordinateRange }
        guard (try? P256.Signing.PublicKey(x963Representation: Data(raw))) != nil else { throw BLESecureKeyRejection.notOnCurve }
    }

    private static func lessThanPrime(_ coordinate: ArraySlice<UInt8>) -> Bool {
        for (a, b) in zip(coordinate, fieldPrime) where a != b { return a < b }
        return false
    }

    /// 64-hex SHA-256 of a validated 65-byte public key.
    public static func fingerprint(publicKey raw: [UInt8]) throws -> String {
        try validate(publicKey: raw)
        return hex(SHA256.hash(data: Data(raw)))
    }

    public static func deviceID(fingerprint: String) -> String { devicePrefix + fingerprint }
    public static func phoneID(fingerprint: String) -> String { phonePrefix + fingerprint }

    public static func isFingerprint(_ text: String) -> Bool { isLowerHex(text, length: 64) }
    public static func isEID(_ text: String) -> Bool { isLowerHex(text, length: 32) }
    public static func isChallenge(_ text: String) -> Bool { isLowerHex(text, length: 64) }

    public static func isDeviceID(_ text: String) -> Bool {
        text.hasPrefix(devicePrefix) && isFingerprint(String(text.utf8.dropFirst(4)) ?? "")
    }

    public static func isPhoneID(_ text: String) -> Bool {
        text.hasPrefix(phonePrefix) && isFingerprint(String(text.utf8.dropFirst(6)) ?? "")
    }

    /// Bare fingerprint of a valid `ble:` device ID.
    public static func fingerprint(deviceID: String) -> String? {
        isDeviceID(deviceID) ? String(deviceID.utf8.dropFirst(4)) : nil
    }

    public static func fingerprint(phoneID: String) -> String? {
        isPhoneID(phoneID) ? String(phoneID.utf8.dropFirst(6)) : nil
    }

    // MARK: §3.4 tokens

    public static func phoneToken(fingerprint: String) -> String { phoneTokenPrefix + fingerprint }

    public static func isPhoneToken(_ text: String) -> Bool {
        text.hasPrefix(phoneTokenPrefix) && isFingerprint(String(text.utf8.dropFirst(phoneTokenPrefix.utf8.count)) ?? "")
    }

    public static func boardToken(device: String, eid: String) -> String { boardTokenPrefix + device + ":" + eid }

    /// §3.4 board token input: trim ASCII space, tab, CR, LF at both ends; hex
    /// in either case, normalized to lowercase. Any other deviation is nil.
    public static func parseBoardToken(_ input: String) -> (device: String, eid: String)? {
        var bytes = ArraySlice(Array(input.utf8))
        let trim: Set<UInt8> = [32, 9, 13, 10]
        while let first = bytes.first, trim.contains(first) { bytes = bytes.dropFirst() }
        while let last = bytes.last, trim.contains(last) { bytes = bytes.dropLast() }
        let prefix = Array(boardTokenPrefix.utf8)
        guard bytes.count == prefix.count + 64 + 1 + 32, bytes.starts(with: prefix) else { return nil }
        let body = Array(bytes.dropFirst(prefix.count))
        guard body[64] == 58 else { return nil }
        var device = [UInt8](), eid = [UInt8]()
        for (index, byte) in body.enumerated() where index != 64 {
            guard nibble(byte, upper: true) != nil else { return nil }
            let lower = (65...70).contains(byte) ? byte + 32 : byte
            if index < 64 { device.append(lower) } else { eid.append(lower) }
        }
        return (String(decoding: device, as: UTF8.self), String(decoding: eid, as: UTF8.self))
    }

    // MARK: randomness

    /// 32 bytes from the system CSPRNG.
    public static func randomBytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw BLEFailure("secure session random source unavailable")
        }
        return bytes
    }
}
