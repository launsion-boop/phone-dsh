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

/// Identities the user has confirmed on this phone (first-use trust, SSH style).
/// Only public identifiers are stored; no secrets.
public enum BLETrustedIdentities {
    static let key = "pdsh.ble.trustedIdentities"

    public static func contains(_ identity: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(identity)
    }

    public static func insert(_ identity: String, defaults: UserDefaults = .standard) {
        var current = defaults.stringArray(forKey: key) ?? []
        guard !current.contains(identity) else { return }
        current.append(identity)
        defaults.set(current, forKey: key)
    }
}
