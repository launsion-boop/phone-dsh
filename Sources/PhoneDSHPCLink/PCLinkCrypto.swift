// SPDX-License-Identifier: MIT
// PhoneDSHPCLink: PCLink v1 cryptography (Ed25519, X25519, HKDF-SHA256,
// HMAC-SHA256, ChaCha20-Poly1305 and the exact §5 transcripts).

import CryptoKit
import Foundation

public enum PCLinkCryptoError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case invalidKeyLength(expected: Int, actual: Int)
    case lowOrderPublicKey
    case allZeroSharedSecret
    case sealFailed
    case openFailed
    case invalidNonce

    public var description: String {
        switch self {
        case .invalidPrivateKey: return "invalid Ed25519/X25519 private key"
        case .invalidPublicKey: return "invalid public key"
        case .invalidSignature: return "invalid Ed25519 signature"
        case .invalidKeyLength(let expected, let actual): return "expected \(expected)-byte key, got \(actual)"
        case .lowOrderPublicKey: return "all-zero/low-order X25519 public key"
        case .allZeroSharedSecret: return "all-zero X25519 shared secret"
        case .sealFailed: return "ChaCha20-Poly1305 seal failed"
        case .openFailed: return "ChaCha20-Poly1305 authentication failed"
        case .invalidNonce: return "invalid AEAD nonce"
        }
    }
}

public enum PCLinkCrypto {
    public static let suite = "pclink-x25519-ed25519-chacha20poly1305-1"
    public static let protocolVersion = "1"

    // MARK: - Hash / MAC / KDF

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func hmacSHA256(key: Data, data: Data) -> Data {
        let key = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    /// HKDF-SHA256 (RFC 5869): extract with `salt`, expand with `info`.
    public static func hkdfSHA256(ikm: Data, salt: Data, info: Data, length: Int) -> Data {
        let prk = hmacSHA256(key: salt, data: ikm)
        var output = Data()
        var previous = Data()
        var counter: UInt8 = 1
        while output.count < length {
            var block = previous
            block.append(info)
            block.append(counter)
            previous = hmacSHA256(key: prk, data: block)
            output.append(previous)
            counter &+= 1
        }
        return output.prefix(length)
    }

    // MARK: - Ed25519

    public static func ed25519PublicKey(seed: Data) throws -> Data {
        guard seed.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: seed.count)
        }
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return key.publicKey.rawRepresentation
        } catch {
            throw PCLinkCryptoError.invalidPrivateKey
        }
    }

    public static func ed25519Sign(seed: Data, message: Data) throws -> Data {
        guard seed.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: seed.count)
        }
        do {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return try key.signature(for: message)
        } catch let error as PCLinkCryptoError {
            throw error
        } catch {
            throw PCLinkCryptoError.invalidPrivateKey
        }
    }

    public static func ed25519Verify(publicKey: Data, message: Data, signature: Data) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
    }

    // MARK: - X25519

    public struct EphemeralKey: Equatable, Sendable {
        public var privateKey: Data
        public var publicKey: Data

        public init(privateKey: Data, publicKey: Data) {
            self.privateKey = privateKey
            self.publicKey = publicKey
        }
    }

    public static func generateX25519() throws -> EphemeralKey {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return EphemeralKey(privateKey: key.rawRepresentation,
                            publicKey: key.publicKey.rawRepresentation)
    }

    public static func x25519PublicKey(privateKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: privateKey.count)
        }
        do {
            let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            return key.publicKey.rawRepresentation
        } catch {
            throw PCLinkCryptoError.invalidPrivateKey
        }
    }

    /// X25519 shared secret. An all-zero public key and an all-zero derived
    /// secret (the low-order points) are rejected before any key derivation.
    public static func x25519SharedSecret(privateKey: Data, publicKey: Data) throws -> Data {
        guard privateKey.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: privateKey.count)
        }
        guard publicKey.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: publicKey.count)
        }
        guard publicKey.contains(where: { $0 != 0 }) else {
            throw PCLinkCryptoError.lowOrderPublicKey
        }
        do {
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey)
            let data = secret.withUnsafeBytes { Data($0) }
            guard data.contains(where: { $0 != 0 }) else {
                throw PCLinkCryptoError.allZeroSharedSecret
            }
            return data
        } catch let error as PCLinkCryptoError {
            throw error
        } catch {
            throw PCLinkCryptoError.invalidPublicKey
        }
    }

    // MARK: - AEAD

    public static func aeadSeal(plaintext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: key.count)
        }
        guard nonce.count == 12 else { throw PCLinkCryptoError.invalidNonce }
        do {
            let box = try ChaChaPoly.seal(plaintext,
                                          using: SymmetricKey(data: key),
                                          nonce: ChaChaPoly.Nonce(data: nonce),
                                          authenticating: aad)
            return box.ciphertext + box.tag
        } catch {
            throw PCLinkCryptoError.sealFailed
        }
    }

    public static func aeadOpen(ciphertext: Data, key: Data, nonce: Data, aad: Data) throws -> Data {
        guard key.count == 32 else {
            throw PCLinkCryptoError.invalidKeyLength(expected: 32, actual: key.count)
        }
        guard nonce.count == 12 else { throw PCLinkCryptoError.invalidNonce }
        guard ciphertext.count >= 16 else { throw PCLinkCryptoError.openFailed }
        do {
            let body = ciphertext.prefix(ciphertext.count - 16)
            let tag = ciphertext.suffix(16)
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                                               ciphertext: body,
                                               tag: tag)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw PCLinkCryptoError.openFailed
        }
    }

    public static func aeadNonce(seq: UInt64) -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in 0..<8 {
            bytes[11 - index] = UInt8((seq >> (8 * UInt64(index))) & 0xFF)
        }
        return Data(bytes)
    }

    // MARK: - Relay auth (§3.2)

    public static func relayAuthTranscript(origin: String, nonce: Data) -> Data {
        var data = Data("pclink-v1/relay-auth".utf8)
        data.append(0)
        data.append(contentsOf: origin.utf8)
        data.append(0)
        data.append(nonce)
        return data
    }

    // MARK: - Session transcripts (§5.2)

    public static let sessionInitDomain = "pclink-v1/session-init"
    public static let sessionRespDomain = "pclink-v1/session-resp"
    public static let sessionConfirmDomain = "pclink-v1/session-confirm"
    public static let sessionRejectDomain = "pclink-v1/session-reject"

    public static func sessionInitTranscript(phoneMachineId: String, pcMachineId: String,
                                             sid: Data, ephPhone: Data, noncePhone: Data) -> Data {
        var data = Data(sessionInitDomain.utf8)
        data.append(0)
        data.append(contentsOf: protocolVersion.utf8)
        data.append(0)
        data.append(contentsOf: suite.utf8)
        data.append(0)
        data.append(contentsOf: phoneMachineId.utf8)
        data.append(0)
        data.append(contentsOf: pcMachineId.utf8)
        data.append(0)
        data.append(sid)
        data.append(0)
        data.append(ephPhone)
        data.append(0)
        data.append(noncePhone)
        return data
    }

    public static func sessionRespTranscript(th1: Data, ephPc: Data, noncePc: Data) -> Data {
        var data = Data(sessionRespDomain.utf8)
        data.append(0)
        data.append(th1)
        data.append(0)
        data.append(ephPc)
        data.append(0)
        data.append(noncePc)
        return data
    }

    public static func sessionConfirmTranscript(th2: Data, phoneMachineId: String,
                                                pcMachineId: String, sid: Data) -> Data {
        var data = Data(sessionConfirmDomain.utf8)
        data.append(0)
        data.append(th2)
        data.append(0)
        data.append(contentsOf: phoneMachineId.utf8)
        data.append(0)
        data.append(contentsOf: pcMachineId.utf8)
        data.append(0)
        data.append(sid)
        return data
    }

    public static func sessionRejectTranscript(th1: Data, code: String) -> Data {
        var data = Data(sessionRejectDomain.utf8)
        data.append(0)
        data.append(th1)
        data.append(0)
        data.append(contentsOf: code.utf8)
        return data
    }

    // MARK: - Session key schedule (§5.3)

    public struct SessionKeys: Equatable, Sendable {
        public var phoneToPC: Data
        public var pcToPhone: Data
        public var confirmPhone: Data
        public var confirmPC: Data

        public init(phoneToPC: Data, pcToPhone: Data, confirmPhone: Data, confirmPC: Data) {
            self.phoneToPC = phoneToPC
            self.pcToPhone = pcToPhone
            self.confirmPhone = confirmPhone
            self.confirmPC = confirmPC
        }
    }

    public static func sessionKeys(dh: Data, th2: Data) -> SessionKeys {
        SessionKeys(
            phoneToPC: hkdfSHA256(ikm: dh, salt: th2, info: Data("pclink-v1/key/phone->pc".utf8), length: 32),
            pcToPhone: hkdfSHA256(ikm: dh, salt: th2, info: Data("pclink-v1/key/pc->phone".utf8), length: 32),
            confirmPhone: hkdfSHA256(ikm: dh, salt: th2, info: Data("pclink-v1/key-confirm/phone->pc".utf8), length: 32),
            confirmPC: hkdfSHA256(ikm: dh, salt: th2, info: Data("pclink-v1/key-confirm/pc->phone".utf8), length: 32))
    }

    public static func confirmation(key: Data, th: Data) -> Data {
        var data = Data("pclink-v1/confirm".utf8)
        data.append(0)
        data.append(th)
        return hmacSHA256(key: key, data: data)
    }

    // MARK: - AAD (§5.4)

    public static func aad(sid: String, seq: UInt64, from: String, to: String) -> Data {
        var data = Data("pclink-v1/aad".utf8)
        data.append(0)
        data.append(contentsOf: protocolVersion.utf8)
        data.append(0)
        data.append(contentsOf: "e2e".utf8)
        data.append(0)
        data.append(contentsOf: sid.utf8)
        data.append(0)
        data.append(contentsOf: String(seq).utf8)
        data.append(0)
        data.append(contentsOf: from.utf8)
        data.append(0)
        data.append(contentsOf: to.utf8)
        return data
    }

    // MARK: - Pairing (§4.4)

    public static let pairHelloDomain = "pclink-v1/pair-hello"
    public static let pairAuthDomain = "pclink-v1/pair-auth"
    public static let pairConfirmDomain = "pclink-v1/pair-confirm"
    public static let pairFinalDomain = "pclink-v1/pair-final"

    public static func pairKey(secret: Data) -> Data {
        hkdfSHA256(ikm: secret,
                   salt: Data(repeating: 0, count: 32),
                   info: Data("pclink-v1/pair-mac".utf8),
                   length: 32)
    }

    /// `HMAC-SHA256(pair_key, UTF8(domain) || 0x00 || canonical_json(object))`.
    public static func pairMAC(pairKey: Data, domain: String, objectWithoutMAC object: PCLinkJSON) throws -> Data {
        var data = Data(domain.utf8)
        data.append(0)
        data.append(try PCLinkJSONEncoder.canonical(object))
        return hmacSHA256(key: pairKey, data: data)
    }

    public static func pairTranscriptHash(hello: PCLinkJSON, auth: PCLinkJSON) throws -> Data {
        let th1 = sha256(try PCLinkJSONEncoder.canonical(hello))
        let th2 = sha256(try PCLinkJSONEncoder.canonical(auth))
        var data = th1
        data.append(0)
        data.append(th2)
        return sha256(data)
    }

    // MARK: - Rendezvous (§4.3)

    public static func rendezvous(secret: Data, relayOrigin: String) -> String {
        var data = Data("pclink-v1/pair".utf8)
        data.append(0)
        data.append(contentsOf: relayOrigin.utf8)
        data.append(0)
        data.append(secret)
        return String(PCLinkBase64URL.encode(sha256(data)).prefix(22))
    }

    // MARK: - Misc

    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count {
            difference |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index]
        }
        return difference == 0
    }
}
