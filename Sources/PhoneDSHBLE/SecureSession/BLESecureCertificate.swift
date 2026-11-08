// SPDX-License-Identifier: MIT
// §6.2 pinned self-signed certificates: the producer profile and the
// acceptance rules. The pin is the only trust decision; dates, names, serial
// and non-critical unknown extensions are not evaluated.
import CryptoKit
import Foundation

/// An ECDSA P-256 / SHA-256 signing key. `sign` returns an X9.62 DER signature
/// over SHA-256 of `message`. The private key never leaves the implementation.
public protocol BLESecureSigner: Sendable {
    /// SEC1 uncompressed point, 65 bytes.
    var publicKey: [UInt8] { get }
    func sign(_ message: [UInt8]) throws -> [UInt8]
}

/// A CryptoKit software key (tests and the in-memory key store).
public struct BLESecureSoftwareSigner: BLESecureSigner {
    let key: P256.Signing.PrivateKey
    public init(_ key: P256.Signing.PrivateKey = .init()) { self.key = key }
    public var publicKey: [UInt8] { Array(key.publicKey.x963Representation) }
    public func sign(_ message: [UInt8]) throws -> [UInt8] {
        Array(try key.signature(for: Data(message)).derRepresentation)
    }
}

public enum BLESecureCertificateRole: String, Sendable {
    case device, phone
    var commonName: String { self == .device ? "pdsh-ble-device" : "pdsh-ble-phone" }
}

/// The closed §6.2 rejection reasons, checked in this order.
public enum BLESecureCertificateRejection: String, Error, Equatable, Sendable {
    case noCertificate = "no_certificate", chainLength = "chain_length"
    case oversize, malformed, curve
    case pinMismatch = "pin_mismatch", signatureAlgorithm = "signature_algorithm"
    case badSelfSignature = "bad_self_signature", caTrue = "ca_true", keyUsage = "key_usage"
    case ekuPresent = "eku_present", unknownCriticalExtension = "unknown_critical_extension"
}

public enum BLESecureCertificate {
    public static let maxDER = 1024

    // MARK: producer

    /// The exact producer profile: v3, serial 1, CN subject = issuer, validity
    /// 2026-01-01 to 9999-12-31, P-256 SPKI, ecdsa-with-SHA256, extensions
    /// basicConstraints (critical, cA FALSE) and keyUsage (critical, digitalSignature).
    public static func make(role: BLESecureCertificateRole, signer: BLESecureSigner) throws -> [UInt8] {
        let point = signer.publicKey
        try BLESecureIdentifiers.validate(publicKey: point)
        let algorithm = DERWriter.sequence([DERWriter.oid(DEROID.ecdsaWithSHA256)])
        let name = DERWriter.sequence([DERWriter.set([DERWriter.sequence([
            DERWriter.oid(DEROID.commonName), DERWriter.tlv(DERTag.utf8String, Array(role.commonName.utf8)),
        ])])])
        let validity = DERWriter.sequence([
            DERWriter.tlv(DERTag.utcTime, Array("260101000000Z".utf8)),
            DERWriter.tlv(DERTag.generalizedTime, Array("99991231235959Z".utf8)),
        ])
        let spki = DERWriter.sequence([
            DERWriter.sequence([DERWriter.oid(DEROID.ecPublicKey), DERWriter.oid(DEROID.prime256v1)]),
            DERWriter.bitString(point),
        ])
        let extensions = DERWriter.tlv(DERTag.context(3), DERWriter.sequence([
            DERWriter.sequence([DERWriter.oid(DEROID.basicConstraints), DERWriter.boolean(true),
                                DERWriter.octetString(DERWriter.sequence([]))]),
            DERWriter.sequence([DERWriter.oid(DEROID.keyUsage), DERWriter.boolean(true),
                                DERWriter.octetString(DERWriter.bitString([0x80], unusedBits: 7))]),
        ]))
        let tbs = DERWriter.sequence([
            DERWriter.tlv(DERTag.context(0), DERWriter.tlv(DERTag.integer, [2])),
            DERWriter.unsignedInteger([1]),
            algorithm, name, validity, name, spki, extensions,
        ])
        let signature = try signer.sign(tbs)
        let der = DERWriter.sequence([tbs, algorithm, DERWriter.bitString(signature)])
        guard der.count <= maxDER else { throw BLESecureCertificateRejection.oversize }
        return der
    }

    // MARK: verifier

    /// Accepts the received list iff all §6.2 rules hold and its SPKI
    /// fingerprint is one of `pins`; returns that fingerprint.
    public static func verify(chain: [[UInt8]], pins: Set<String>) -> Result<String, BLESecureCertificateRejection> {
        guard !chain.isEmpty else { return .failure(.noCertificate) }
        guard chain.count == 1 else { return .failure(.chainLength) }
        let der = chain[0]
        guard der.count <= maxDER else { return .failure(.oversize) }
        let parsed: Parsed
        do { parsed = try parse(der) } catch { return .failure(.malformed) }
        guard parsed.spkiIsP256, (try? BLESecureIdentifiers.validate(publicKey: parsed.point)) != nil,
              let key = try? P256.Signing.PublicKey(x963Representation: Data(parsed.point)) else { return .failure(.curve) }
        guard let fingerprint = try? BLESecureIdentifiers.fingerprint(publicKey: parsed.point),
              pins.contains(fingerprint) else { return .failure(.pinMismatch) }
        guard parsed.signatureAlgorithmOK else { return .failure(.signatureAlgorithm) }
        guard parsed.signatureUnusedBits == 0,
              let signature = try? P256.Signing.ECDSASignature(derRepresentation: Data(parsed.signature)),
              key.isValidSignature(signature, for: Data(parsed.tbs)) else { return .failure(.badSelfSignature) }
        if parsed.caTrue { return .failure(.caTrue) }
        if !parsed.digitalSignature { return .failure(.keyUsage) }
        if parsed.ekuPresent { return .failure(.ekuPresent) }
        if parsed.unknownCritical { return .failure(.unknownCriticalExtension) }
        return .success(fingerprint)
    }

    struct Parsed {
        var tbs: [UInt8] = []
        var point: [UInt8] = []
        var spkiIsP256 = false
        var signatureAlgorithmOK = false
        var signature: [UInt8] = []
        var signatureUnusedBits: UInt8 = 0
        var caTrue = false
        var digitalSignature = false
        var ekuPresent = false
        var unknownCritical = false
    }

    /// X.509 v3 structure; any structural deviation throws (`malformed`).
    static func parse(_ der: [UInt8]) throws -> Parsed {
        typealias M = DERNode.Malformed
        var out = Parsed()
        let cert = try DERNode.parse(ArraySlice(der))
        guard cert.tag == DERTag.sequence else { throw M() }
        let top = try cert.children()
        guard top.count == 3, top[0].tag == DERTag.sequence, top[1].tag == DERTag.sequence, top[2].tag == DERTag.bitString,
              !top[2].content.isEmpty else { throw M() }
        out.tbs = Array(top[0].encoded)
        let outerAlgorithm = top[1]
        out.signatureUnusedBits = top[2].content.first!
        out.signature = Array(top[2].content.dropFirst())

        var fields = try top[0].children()[...]
        // version [0] EXPLICIT INTEGER 2 (v3)
        guard let version = fields.popFirst(), version.tag == DERTag.context(0) else { throw M() }
        let versionValue = try version.children()
        guard versionValue.count == 1, versionValue[0].tag == DERTag.integer, Array(versionValue[0].content) == [2] else { throw M() }
        guard let serial = fields.popFirst(), serial.tag == DERTag.integer, (1...21).contains(serial.content.count) else { throw M() }
        guard let innerAlgorithm = fields.popFirst(), innerAlgorithm.tag == DERTag.sequence else { throw M() }
        guard let issuer = fields.popFirst(), issuer.tag == DERTag.sequence else { throw M() }
        guard let validity = fields.popFirst(), validity.tag == DERTag.sequence else { throw M() }
        let times = try validity.children()
        guard times.count == 2, times.allSatisfy({ $0.tag == DERTag.utcTime || $0.tag == DERTag.generalizedTime }) else { throw M() }
        guard let subject = fields.popFirst(), subject.tag == DERTag.sequence else { throw M() }
        _ = try issuer.children(); _ = try subject.children()
        guard let spki = fields.popFirst(), spki.tag == DERTag.sequence else { throw M() }
        let spkiParts = try spki.children()
        guard spkiParts.count == 2, spkiParts[0].tag == DERTag.sequence, spkiParts[1].tag == DERTag.bitString,
              !spkiParts[1].content.isEmpty else { throw M() }
        let keyAlgorithm = try spkiParts[0].children()
        out.spkiIsP256 = keyAlgorithm.count == 2
            && keyAlgorithm[0].tag == DERTag.oid && Array(keyAlgorithm[0].content) == DEROID.ecPublicKey
            && keyAlgorithm[1].tag == DERTag.oid && Array(keyAlgorithm[1].content) == DEROID.prime256v1
            && spkiParts[1].content.first == 0
        out.point = Array(spkiParts[1].content.dropFirst())
        if fields.first?.tag == DERTag.context(1, constructed: false) { fields.removeFirst() }
        if fields.first?.tag == DERTag.context(2, constructed: false) { fields.removeFirst() }
        var seen = Set<[UInt8]>()
        if let extensionsWrapper = fields.popFirst() {
            guard extensionsWrapper.tag == DERTag.context(3) else { throw M() }
            let wrapped = try extensionsWrapper.children()
            guard wrapped.count == 1, wrapped[0].tag == DERTag.sequence else { throw M() }
            let extensions = try wrapped[0].children()
            guard !extensions.isEmpty else { throw M() }
            for ext in extensions {
                guard ext.tag == DERTag.sequence else { throw M() }
                let parts = try ext.children()
                guard (2...3).contains(parts.count), parts[0].tag == DERTag.oid, parts.last!.tag == DERTag.octetString else { throw M() }
                let oid = Array(parts[0].content)
                guard seen.insert(oid).inserted else { throw M() }
                var critical = false
                if parts.count == 3 {
                    guard parts[1].tag == DERTag.boolean, parts[1].content.count == 1,
                          parts[1].content.first == 0 || parts[1].content.first == 0xff else { throw M() }
                    critical = parts[1].content.first == 0xff
                }
                let value = try DERNode.parse(parts[parts.count - 1].content)
                switch oid {
                case DEROID.basicConstraints:
                    guard value.tag == DERTag.sequence else { throw M() }
                    let bc = try value.children()
                    guard bc.count <= 2 else { throw M() }
                    if let first = bc.first, first.tag == DERTag.boolean {
                        guard first.content.count == 1, first.content.first == 0 || first.content.first == 0xff else { throw M() }
                        out.caTrue = first.content.first == 0xff
                        if bc.count == 2 { guard bc[1].tag == DERTag.integer else { throw M() } }
                    } else if let first = bc.first {
                        guard bc.count == 1, first.tag == DERTag.integer else { throw M() }
                    }
                case DEROID.keyUsage:
                    guard value.tag == DERTag.bitString, value.content.count >= 2, value.content.first! < 8 else { throw M() }
                    out.digitalSignature = value.content[value.content.startIndex + 1] & 0x80 != 0
                case DEROID.extendedKeyUsage:
                    out.ekuPresent = true
                default:
                    if critical { out.unknownCritical = true }
                }
            }
        }
        guard fields.isEmpty else { throw M() }
        func isECDSASHA256(_ node: DERNode) -> Bool {
            guard let parts = try? node.children(), parts.count == 1, parts[0].tag == DERTag.oid else { return false }
            return Array(parts[0].content) == DEROID.ecdsaWithSHA256
        }
        out.signatureAlgorithmOK = isECDSASHA256(outerAlgorithm) && isECDSASHA256(innerAlgorithm)
            && outerAlgorithm.encoded.elementsEqual(innerAlgorithm.encoded)
        return out
    }
}
