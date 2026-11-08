// SPDX-License-Identifier: MIT
// BLE device identity (PC-20261106-device-identity-tofu).
//
// The device signs a fresh phone nonce with its ECDSA P-256 identity key. The
// phone verifies the signature with the public key the device presented and
// derives the identity as "ble:" + SHA-256(public key). The first time an
// identity appears the user must confirm it; after that it is trusted.
import CryptoKit
import Foundation
import Security

public enum BLEIdentity {
    static let domain = Array("phoneDSH BLE identity v1".utf8)
    static let publicKeyLength = 65
    static let signatureLength = 64

    public static func randomNonce() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw BLEFailure("无法生成身份证明随机数")
        }
        return Data(bytes)
    }

    /// Verifies a proof for `nonce` and returns the derived identity string.
    public static func verify(nonce: Data, publicKeyHex: String, signatureHex: String) throws -> String {
        guard nonce.count == 32,
              let publicKey = hexDecode(publicKeyHex), publicKey.count == publicKeyLength, publicKey.first == 0x04,
              let signature = hexDecode(signatureHex), signature.count == signatureLength else {
            throw BLEFailure("设备身份证明格式无效")
        }
        let key: P256.Signing.PublicKey
        let sig: P256.Signing.ECDSASignature
        do {
            key = try P256.Signing.PublicKey(x963Representation: Data(publicKey))
            sig = try P256.Signing.ECDSASignature(rawRepresentation: Data(signature))
        } catch {
            throw BLEFailure("设备身份证明无法解析")
        }
        let message = domain + [0] + [UInt8](nonce) + [0] + publicKey
        guard key.isValidSignature(sig, for: SHA256.hash(data: Data(message))) else {
            throw BLEFailure("设备身份证明验签失败")
        }
        return identity(publicKey: publicKey)
    }

    public static func identity(publicKey: [UInt8]) -> String {
        "ble:" + hexEncode(Array(SHA256.hash(data: Data(publicKey))))
    }

    static func hexEncode(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hexDecode(_ text: String) -> [UInt8]? {
        guard text.count % 2 == 0, text.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }
}

/// Legacy labels only; these records do not authenticate a peer or grant tasks.
public enum BLETrustedIdentities {
    static let key = "pdsh.ble.trustedIdentities"
    private static let lock = NSRecursiveLock()
    // UserDefaults can synchronously call back into this API. Refuse nested
    // operations instead of deadlocking or interleaving their read/write cycle.
    private static var active = false

    private static func access<Result>(_ rejected: Result, _ action: () -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        guard !active else { return rejected }
        active = true
        defer { active = false }
        return action()
    }

    public static func contains(_ identity: String, defaults: UserDefaults = .standard) -> Bool {
        access(false) { (defaults.object(forKey: key) as? [String])?.contains(identity) ?? false }
    }

    public static func insert(_ identity: String, defaults: UserDefaults = .standard) {
        _ = insertIfVisibleValid(identity, defaults: defaults)
    }

    /// A successful readback confirms only what this process can currently see;
    /// it does not establish durable storage or authenticate a device.
    @discardableResult
    public static func insertIfVisibleValid(_ identity: String, defaults: UserDefaults = .standard) -> Bool {
        access(false) { insertCore(identity, defaults: defaults, isCurrent: { true }) == .success }
    }

    enum ConfirmationOutcome {
        case success, storageFailure, stale, reentrantBusy, notAdmitted
    }

    /// Admission happens only after the participating process lock is held.
    /// The callbacks are synchronous and must not access UserDefaults.
    @MainActor
    static func confirm(_ identity: String, defaults: UserDefaults = .standard,
                        onAccepted: () -> Bool, isCurrent: () -> Bool) -> ConfirmationOutcome {
        access(.reentrantBusy) {
            guard onAccepted() else { return .notAdmitted }
            return insertCore(identity, defaults: defaults, isCurrent: isCurrent)
        }
    }

    private static func insertCore(_ identity: String, defaults: UserDefaults,
                                   isCurrent: () -> Bool) -> ConfirmationOutcome {
        let visible = defaults.object(forKey: key)
        guard isCurrent() else { return .stale }
        var current: [String]
        if let visible {
            guard let strings = visible as? [String] else { return .storageFailure }
            current = strings
        } else {
            current = []
        }
        if current.contains(identity) { return .success }
        current.append(identity)
        guard isCurrent() else { return .stale }
        defaults.set(current, forKey: key)
        // A synchronous callback within set may already have invalidated the
        // captured owner. The write may have happened and must not be undone.
        guard isCurrent() else { return .stale }
        let visibleReadback = defaults.object(forKey: key)
        guard isCurrent() else { return .stale }
        guard let readback = visibleReadback as? [String], readback.count == current.count,
              zip(readback, current).allSatisfy({ $0.0.unicodeScalars.elementsEqual($0.1.unicodeScalars) }) else {
            return .storageFailure
        }
        return .success
    }
}
