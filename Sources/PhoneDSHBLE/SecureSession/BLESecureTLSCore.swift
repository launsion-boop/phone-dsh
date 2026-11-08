// SPDX-License-Identifier: MIT
// TLS 1.3 building blocks for the single secure-session-v1 profile (§6.1):
// TLS_AES_128_GCM_SHA256, secp256r1, ecdsa_secp256r1_sha256, no PSK. Only
// CryptoKit primitives are used; nothing here negotiates.
import CryptoKit
import Foundation

public enum BLESecureTLSError: Error, Equatable, Sendable {
    /// A fatal alert this endpoint raised (and attempted to send).
    case sentAlert(UInt8, String)
    /// A fatal alert, or close_notify during the handshake, received from the peer.
    case receivedAlert(UInt8)
    /// The peer certificate failed §6.2; `bad_certificate` was sent.
    case certificate(BLESecureCertificateRejection)
    /// The stream ended without close_notify, or was closed locally.
    case transportClosed
}

enum TLSAlert: UInt8 {
    case closeNotify = 0, unexpectedMessage = 10, badRecordMAC = 20, recordOverflow = 22
    case handshakeFailure = 40, badCertificate = 42, illegalParameter = 47, decodeError = 50
    case decryptError = 51, protocolVersion = 70, internalError = 80, missingExtension = 109
    case unsupportedExtension = 110, certificateRequired = 116, noApplicationProtocol = 120
}

enum TLS {
    static let version13: UInt16 = 0x0304
    static let legacyVersion: UInt16 = 0x0303
    static let cipherAES128GCMSHA256: UInt16 = 0x1301
    static let groupSecp256r1: UInt16 = 0x0017
    static let ecdsaSecp256r1SHA256: UInt16 = 0x0403
    static let alpn = Array(BLESecureServiceProfile.alpn.utf8)
    /// §6.1: each side sends records whose plaintext is at most 4352 bytes.
    static let maxPlaintext = 4352
    /// secure-session-v2.1 §6.1: TLSInnerPlaintext (content, content type and
    /// padding) is at most 4352 + 1 bytes, so under the profile's only AEAD
    /// (16-byte tag) a protected record is at most 4369 bytes. A longer
    /// protected record, or an unprotected record over 4352 bytes, is
    /// record_overflow, decided from the header before decryption.
    static let maxInnerPlaintext = maxPlaintext + 1
    static let maxCiphertext = maxInnerPlaintext + 16

    enum ContentType: UInt8 { case changeCipherSpec = 20, alert = 21, handshake = 22, applicationData = 23 }
    enum HandshakeType: UInt8 {
        case clientHello = 1, serverHello = 2, newSessionTicket = 4, endOfEarlyData = 5, encryptedExtensions = 8
        case certificate = 11, certificateRequest = 13, certificateVerify = 15, finished = 20, keyUpdate = 24
    }
    enum Extension: UInt16 {
        case serverName = 0, maxFragmentLength = 1, statusRequest = 5, supportedGroups = 10, signatureAlgorithms = 13
        case alpn = 16, signedCertificateTimestamp = 18, recordSizeLimit = 28, preSharedKey = 41, earlyData = 42
        case supportedVersions = 43, cookie = 44, pskKeyExchangeModes = 45, certificateAuthorities = 47
        case postHandshakeAuth = 49, signatureAlgorithmsCert = 50, keyShare = 51
    }
    /// SHA-256("HelloRetryRequest")
    static let helloRetryRandom: [UInt8] = [
        0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
        0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
    ]

    static func fail(_ alert: TLSAlert, _ detail: String) -> BLESecureTLSError { .sentAlert(alert.rawValue, detail) }
}

// MARK: byte helpers

struct TLSWriter {
    var bytes: [UInt8] = []
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xff)] }
    mutating func u24(_ v: Int) { bytes += [UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    mutating func raw(_ v: [UInt8]) { bytes += v }
    mutating func vec8(_ v: [UInt8]) { u8(UInt8(v.count)); raw(v) }
    mutating func vec16(_ v: [UInt8]) { u16(UInt16(v.count)); raw(v) }
    mutating func vec24(_ v: [UInt8]) { u24(v.count); raw(v) }
}

struct TLSReader {
    let bytes: [UInt8]
    var index = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init<S: Sequence>(_ bytes: S) where S.Element == UInt8 { self.bytes = Array(bytes) }
    var isAtEnd: Bool { index == bytes.count }
    var remaining: Int { bytes.count - index }

    mutating func take(_ n: Int) throws -> [UInt8] {
        guard n >= 0, remaining >= n else { throw TLS.fail(.decodeError, "truncated structure") }
        defer { index += n }
        return Array(bytes[index..<index + n])
    }
    mutating func u8() throws -> UInt8 { try take(1)[0] }
    mutating func u16() throws -> UInt16 { let b = try take(2); return UInt16(b[0]) << 8 | UInt16(b[1]) }
    mutating func u24() throws -> Int { let b = try take(3); return Int(b[0]) << 16 | Int(b[1]) << 8 | Int(b[2]) }
    mutating func vec8() throws -> [UInt8] { try take(Int(try u8())) }
    mutating func vec16() throws -> [UInt8] { try take(Int(try u16())) }
    mutating func vec24() throws -> [UInt8] { try take(try u24()) }
    func end() throws { guard isAtEnd else { throw TLS.fail(.decodeError, "trailing bytes in structure") } }

    /// Extension list: (type, data) in order; duplicates are illegal.
    static func extensions(_ block: [UInt8]) throws -> [(UInt16, [UInt8])] {
        var r = TLSReader(block)
        var out: [(UInt16, [UInt8])] = []
        var seen = Set<UInt16>()
        while !r.isAtEnd {
            let type = try r.u16()
            guard seen.insert(type).inserted else { throw TLS.fail(.illegalParameter, "duplicate extension \(type)") }
            out.append((type, try r.vec16()))
        }
        return out
    }
}

// MARK: key schedule (RFC 8446 §7.1, SHA-256)

enum TLSKeySchedule {
    static func extract(salt: [UInt8], ikm: [UInt8]) -> [UInt8] {
        Array(HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt))
    }

    static func expandLabel(_ secret: [UInt8], _ label: String, _ context: [UInt8], _ length: Int) -> [UInt8] {
        var info = TLSWriter()
        info.u16(UInt16(length))
        info.vec8(Array(("tls13 " + label).utf8))
        info.vec8(context)
        let prk = SymmetricKey(data: secret)
        let out = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info.bytes, outputByteCount: length)
        return out.withUnsafeBytes { Array($0) }
    }

    static func deriveSecret(_ secret: [UInt8], _ label: String, transcriptHash: [UInt8]) -> [UInt8] {
        expandLabel(secret, label, transcriptHash, 32)
    }

    static func hash(_ bytes: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: bytes)) }
    static let emptyHash = hash([])

    static func finishedMAC(baseKey: [UInt8], transcriptHash: [UInt8]) -> [UInt8] {
        let key = expandLabel(baseKey, "finished", [], 32)
        return Array(HMAC<SHA256>.authenticationCode(for: transcriptHash, using: SymmetricKey(data: key)))
    }

    /// Handshake and application secrets for one connection.
    struct Secrets {
        let handshake: [UInt8]
        let clientHandshake: [UInt8]
        let serverHandshake: [UInt8]

        init(sharedSecret: [UInt8], helloHash: [UInt8]) {
            let early = TLSKeySchedule.extract(salt: [], ikm: [UInt8](repeating: 0, count: 32))
            let derived = TLSKeySchedule.deriveSecret(early, "derived", transcriptHash: TLSKeySchedule.emptyHash)
            handshake = TLSKeySchedule.extract(salt: derived, ikm: sharedSecret)
            clientHandshake = TLSKeySchedule.deriveSecret(handshake, "c hs traffic", transcriptHash: helloHash)
            serverHandshake = TLSKeySchedule.deriveSecret(handshake, "s hs traffic", transcriptHash: helloHash)
        }

        func application(serverFinishedHash: [UInt8]) -> (client: [UInt8], server: [UInt8]) {
            let derived = TLSKeySchedule.deriveSecret(handshake, "derived", transcriptHash: TLSKeySchedule.emptyHash)
            let master = TLSKeySchedule.extract(salt: derived, ikm: [UInt8](repeating: 0, count: 32))
            return (TLSKeySchedule.deriveSecret(master, "c ap traffic", transcriptHash: serverFinishedHash),
                    TLSKeySchedule.deriveSecret(master, "s ap traffic", transcriptHash: serverFinishedHash))
        }
    }

    static func nextTrafficSecret(_ secret: [UInt8]) -> [UInt8] { expandLabel(secret, "traffic upd", [], 32) }
}

// MARK: record protection (AES-128-GCM, RFC 8446 §5.2-5.3)

struct TLSRecordKeys {
    private(set) var secret: [UInt8]
    private var key: SymmetricKey
    private var iv: [UInt8]
    private var sequence: UInt64 = 0

    init(secret: [UInt8]) {
        self.secret = secret
        key = SymmetricKey(data: TLSKeySchedule.expandLabel(secret, "key", [], 16))
        iv = TLSKeySchedule.expandLabel(secret, "iv", [], 12)
    }

    private mutating func nonce() throws -> AES.GCM.Nonce {
        guard sequence < UInt64.max else { throw TLS.fail(.internalError, "record sequence exhausted") }
        var n = iv
        for i in 0..<8 { n[4 + i] ^= UInt8((sequence >> (8 * (7 - UInt64(i)))) & 0xff) }
        sequence += 1
        return try AES.GCM.Nonce(data: n)
    }

    /// One protected record carrying `content` of `type`.
    mutating func seal(_ type: TLS.ContentType, _ content: [UInt8]) throws -> [UInt8] {
        guard content.count <= TLS.maxPlaintext else { throw TLS.fail(.internalError, "record plaintext over cap") }
        let inner = content + [type.rawValue]
        let length = inner.count + 16
        let header: [UInt8] = [TLS.ContentType.applicationData.rawValue, 0x03, 0x03, UInt8(length >> 8), UInt8(length & 0xff)]
        let box = try AES.GCM.seal(inner, using: key, nonce: try nonce(), authenticating: header)
        return header + Array(box.ciphertext) + Array(box.tag)
    }

    #if DEBUG
    /// Test hook (spec §13, test builds only): one protected record with an
    /// explicit inner type and zero padding, without the sender cap, so the
    /// receiver's record limits can be exercised by an independent peer.
    mutating func sealForTesting(innerType: UInt8, content: [UInt8], padding: Int) throws -> [UInt8] {
        let inner = content + [innerType] + [UInt8](repeating: 0, count: padding)
        let length = inner.count + 16
        let header: [UInt8] = [TLS.ContentType.applicationData.rawValue, 0x03, 0x03, UInt8(length >> 8), UInt8(length & 0xff)]
        let box = try AES.GCM.seal(inner, using: key, nonce: try nonce(), authenticating: header)
        return header + Array(box.ciphertext) + Array(box.tag)
    }
    #endif

    /// Opens one protected record; returns the inner content type and content.
    mutating func open(header: [UInt8], body: [UInt8]) throws -> (UInt8, [UInt8]) {
        guard body.count >= 17 else { throw TLS.fail(.badRecordMAC, "short protected record") }
        let box: AES.GCM.SealedBox
        let plaintext: Data
        do {
            box = try AES.GCM.SealedBox(nonce: try nonce(), ciphertext: Array(body.dropLast(16)), tag: Array(body.suffix(16)))
            plaintext = try AES.GCM.open(box, using: key, authenticating: header)
        } catch let error as BLESecureTLSError { throw error } catch {
            throw TLS.fail(.badRecordMAC, "record authentication failed")
        }
        var inner = Array(plaintext)
        while let last = inner.last, last == 0 { inner.removeLast() }
        guard let type = inner.popLast() else { throw TLS.fail(.unexpectedMessage, "record without content type") }
        guard inner.count <= TLS.maxPlaintext else { throw TLS.fail(.recordOverflow, "record plaintext over cap") }
        return (type, inner)
    }
}

/// Splits a byte stream into TLS records without interpreting them.
final class TLSRecordReader: @unchecked Sendable {
    let stream: BLESecureByteStream
    private var buffer: [UInt8] = []

    init(stream: BLESecureByteStream) { self.stream = stream }

    /// (header, body) of the next record; nil at clean EOF on a record boundary.
    func next() async throws -> ([UInt8], [UInt8])? {
        while true {
            if buffer.count >= 5 {
                let length = Int(buffer[3]) << 8 | Int(buffer[4])
                let type = buffer[0]
                let limit = type == TLS.ContentType.applicationData.rawValue ? TLS.maxCiphertext : TLS.maxPlaintext
                guard length <= limit else { throw TLS.fail(.recordOverflow, "record length \(length)") }
                guard TLS.ContentType(rawValue: type) != nil else { throw TLS.fail(.unexpectedMessage, "record type \(type)") }
                if buffer.count >= 5 + length {
                    let header = Array(buffer[0..<5]), body = Array(buffer[5..<5 + length])
                    buffer.removeFirst(5 + length)
                    return (header, body)
                }
            }
            guard let chunk = try await stream.read() else {
                if buffer.isEmpty { return nil }
                throw BLESecureTLSError.transportClosed
            }
            buffer += chunk
        }
    }
}

/// Reassembles handshake messages from handshake-record fragments.
struct TLSHandshakeBuffer {
    private(set) var bytes: [UInt8] = []
    var isEmpty: Bool { bytes.isEmpty }
    mutating func append(_ fragment: [UInt8]) { bytes += fragment }

    /// (type, body, full message bytes) when a complete message is buffered.
    mutating func next() throws -> (UInt8, [UInt8], [UInt8])? {
        guard bytes.count >= 4 else { return nil }
        let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard length <= 16384 else { throw TLS.fail(.decodeError, "handshake message too long") }
        guard bytes.count >= 4 + length else { return nil }
        let message = Array(bytes[0..<4 + length])
        bytes.removeFirst(4 + length)
        return (message[0], Array(message[4...]), message)
    }

    static func message(_ type: TLS.HandshakeType, _ body: [UInt8]) -> [UInt8] {
        var w = TLSWriter(); w.u8(type.rawValue); w.vec24(body); return w.bytes
    }
}

enum TLSSignature {
    static func content(server: Bool, transcriptHash: [UInt8]) -> [UInt8] {
        [UInt8](repeating: 0x20, count: 64)
            + Array((server ? "TLS 1.3, server CertificateVerify" : "TLS 1.3, client CertificateVerify").utf8)
            + [0] + transcriptHash
    }

    static func verify(publicKey point: [UInt8], signature: [UInt8], content: [UInt8]) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: Data(point)),
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: Data(signature)) else { return false }
        return key.isValidSignature(sig, for: Data(content))
    }

    /// The SPKI point of a certificate already accepted by the verifier.
    static func point(of certificate: [UInt8]) -> [UInt8]? {
        (try? BLESecureCertificate.parse(certificate))?.point
    }
}

/// Constant-time equality for MACs.
func tlsConstantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
}
