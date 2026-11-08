// SPDX-License-Identifier: MIT
// The phone's TLS 1.3 client for secure-session-v2 (§6.1, §6.2). It implements
// exactly one profile and refuses every deviation; there is no fallback and
// no plaintext mode. It sends no pre_shared_key, psk_key_exchange_modes,
// early_data, post_handshake_auth, server_name, max_fragment_length or
// record_size_limit, never stores a ticket, and runs over any
// BLESecureByteStream.
import CryptoKit
import Foundation

public actor BLESecureTLSClient {
    public struct Credentials: Sendable {
        public let certificate: [UInt8]
        public let signer: BLESecureSigner
        public init(certificate: [UInt8], signer: BLESecureSigner) {
            self.certificate = certificate
            self.signer = signer
        }
    }

    private let stream: BLESecureByteStream
    private let credentials: Credentials
    /// v2 §6.2 rule 3: the device of the one record the user selected.
    private let pin: String
    private let randomBytes: @Sendable (Int) throws -> [UInt8]
    private let records: TLSRecordReader
    private var handshake = TLSHandshakeBuffer()
    private var readKeys: TLSRecordKeys?
    private var writeKeys: TLSRecordKeys?
    private var established = false
    private var finished = false
    /// The SPKI fingerprint of the accepted server certificate.
    public private(set) var peerFingerprint: String?

    public init(stream: BLESecureByteStream, credentials: Credentials, selectedDevice: String,
                randomBytes: @escaping @Sendable (Int) throws -> [UInt8] = BLESecureIdentifiers.randomBytes) {
        self.stream = stream
        self.credentials = credentials
        self.pin = selectedDevice
        self.randomBytes = randomBytes
        self.records = TLSRecordReader(stream: stream)
    }

    // MARK: handshake

    /// Runs the full (EC)DHE handshake with mutual authentication. Returns the
    /// pinned device fingerprint. Any failure sends a fatal alert and closes.
    public func handshake() async throws -> String {
        guard !established, !finished else { throw BLESecureTLSError.transportClosed }
        do {
            return try await runHandshake()
        } catch let error as BLESecureTLSError {
            abort(error)
            throw error
        } catch {
            let wrapped = TLS.fail(.internalError, "\(error)")
            abort(wrapped)
            throw wrapped
        }
    }

    private func runHandshake() async throws -> String {
        let share = P256.KeyAgreement.PrivateKey()
        let clientHello = TLSHandshakeBuffer.message(.clientHello, try clientHelloBody(share: share))
        try writePlain(.handshake, clientHello)
        var transcript = clientHello

        // ServerHello (plaintext; a compatibility change_cipher_spec may follow).
        let (shType, shBody, shRaw) = try await nextHandshake(allowCCS: true)
        guard shType == TLS.HandshakeType.serverHello.rawValue else { throw TLS.fail(.unexpectedMessage, "expected ServerHello") }
        let serverShare = try parseServerHello(shBody)
        transcript += shRaw
        guard handshake.isEmpty else { throw TLS.fail(.unexpectedMessage, "data after ServerHello before key change") }
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data(serverShare))
        let shared = try share.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
        let secrets = TLSKeySchedule.Secrets(sharedSecret: shared, helloHash: TLSKeySchedule.hash(transcript))
        readKeys = TLSRecordKeys(secret: secrets.serverHandshake)
        writeKeys = TLSRecordKeys(secret: secrets.clientHandshake)

        // EncryptedExtensions
        var (type, body, raw) = try await nextHandshake(allowCCS: true)
        guard type == TLS.HandshakeType.encryptedExtensions.rawValue else { throw TLS.fail(.unexpectedMessage, "expected EncryptedExtensions") }
        try parseEncryptedExtensions(body)
        transcript += raw

        // CertificateRequest is mandatory (client authentication).
        (type, body, raw) = try await nextHandshake(allowCCS: true)
        guard type == TLS.HandshakeType.certificateRequest.rawValue else { throw TLS.fail(.unexpectedMessage, "expected CertificateRequest") }
        try parseCertificateRequest(body)
        transcript += raw

        // Server Certificate, pinned.
        (type, body, raw) = try await nextHandshake(allowCCS: true)
        guard type == TLS.HandshakeType.certificate.rawValue else { throw TLS.fail(.unexpectedMessage, "expected Certificate") }
        let chain = try parseCertificate(body)
        let fingerprint: String
        // Decided inside the handshake, before CertificateVerify/Finished are
        // processed and before any application data (v2 §6.2).
        switch BLESecureCertificate.verify(chain: chain, pins: [pin]) {
        case .success(let fp): fingerprint = fp
        case .failure(let reason): throw BLESecureTLSError.certificate(reason)
        }
        guard let serverPoint = TLSSignature.point(of: chain[0]) else { throw TLS.fail(.badCertificate, "certificate key") }
        transcript += raw

        // CertificateVerify
        (type, body, raw) = try await nextHandshake(allowCCS: true)
        guard type == TLS.HandshakeType.certificateVerify.rawValue else { throw TLS.fail(.unexpectedMessage, "expected CertificateVerify") }
        var cv = TLSReader(body)
        guard try cv.u16() == TLS.ecdsaSecp256r1SHA256 else { throw TLS.fail(.illegalParameter, "CertificateVerify scheme") }
        let signature = try cv.vec16()
        try cv.end()
        guard TLSSignature.verify(publicKey: serverPoint, signature: signature,
                                  content: TLSSignature.content(server: true, transcriptHash: TLSKeySchedule.hash(transcript))) else {
            throw TLS.fail(.decryptError, "server CertificateVerify")
        }
        transcript += raw

        // Finished
        (type, body, raw) = try await nextHandshake(allowCCS: true)
        guard type == TLS.HandshakeType.finished.rawValue else { throw TLS.fail(.unexpectedMessage, "expected Finished") }
        guard body.count == 32 else { throw TLS.fail(.decodeError, "Finished length") }
        let expected = TLSKeySchedule.finishedMAC(baseKey: secrets.serverHandshake, transcriptHash: TLSKeySchedule.hash(transcript))
        guard tlsConstantTimeEqual(body, expected) else { throw TLS.fail(.decryptError, "server Finished") }
        transcript += raw
        guard handshake.isEmpty else { throw TLS.fail(.unexpectedMessage, "data after server Finished before key change") }
        let application = secrets.application(serverFinishedHash: TLSKeySchedule.hash(transcript))

        // Client flight: Certificate, CertificateVerify, Finished.
        var certificate = TLSWriter()
        certificate.vec8([])
        var entry = TLSWriter(); entry.vec24(credentials.certificate); entry.vec16([])
        certificate.vec24(entry.bytes)
        let certificateMessage = TLSHandshakeBuffer.message(.certificate, certificate.bytes)
        transcript += certificateMessage
        let clientSignature = try credentials.signer.sign(TLSSignature.content(server: false, transcriptHash: TLSKeySchedule.hash(transcript)))
        var verify = TLSWriter(); verify.u16(TLS.ecdsaSecp256r1SHA256); verify.vec16(clientSignature)
        let verifyMessage = TLSHandshakeBuffer.message(.certificateVerify, verify.bytes)
        transcript += verifyMessage
        let clientFinished = TLSHandshakeBuffer.message(.finished,
            TLSKeySchedule.finishedMAC(baseKey: secrets.clientHandshake, transcriptHash: TLSKeySchedule.hash(transcript)))
        try writeProtected(.handshake, certificateMessage + verifyMessage + clientFinished)

        readKeys = TLSRecordKeys(secret: application.server)
        writeKeys = TLSRecordKeys(secret: application.client)
        established = true
        peerFingerprint = fingerprint
        return fingerprint
    }

    private func clientHelloBody(share: P256.KeyAgreement.PrivateKey) throws -> [UInt8] {
        var w = TLSWriter()
        w.u16(TLS.legacyVersion)
        w.raw(try randomBytes(32))
        w.vec8([])                                  // legacy_session_id: empty, no middlebox compatibility mode
        var suites = TLSWriter(); suites.u16(TLS.cipherAES128GCMSHA256); w.vec16(suites.bytes)
        w.vec8([0])                                 // legacy_compression_methods: null
        var ext = TLSWriter()
        func add(_ type: TLS.Extension, _ data: [UInt8]) { ext.u16(type.rawValue); ext.vec16(data) }
        var versions = TLSWriter(); versions.vec8([0x03, 0x04]); add(.supportedVersions, versions.bytes)
        var groups = TLSWriter(); var g = TLSWriter(); g.u16(TLS.groupSecp256r1); groups.vec16(g.bytes); add(.supportedGroups, groups.bytes)
        var schemes = TLSWriter(); var s = TLSWriter(); s.u16(TLS.ecdsaSecp256r1SHA256); schemes.vec16(s.bytes)
        add(.signatureAlgorithms, schemes.bytes)
        add(.signatureAlgorithmsCert, schemes.bytes)
        var keyShare = TLSWriter(); var shareEntry = TLSWriter()
        shareEntry.u16(TLS.groupSecp256r1); shareEntry.vec16(Array(share.publicKey.x963Representation))
        keyShare.vec16(shareEntry.bytes); add(.keyShare, keyShare.bytes)
        var alpn = TLSWriter(); var names = TLSWriter(); names.vec8(TLS.alpn); alpn.vec16(names.bytes); add(.alpn, alpn.bytes)
        w.vec16(ext.bytes)
        return w.bytes
    }

    private func parseServerHello(_ body: [UInt8]) throws -> [UInt8] {
        var r = TLSReader(body)
        let legacy = try r.u16()
        let random = try r.take(32)
        if random == TLS.helloRetryRandom { throw TLS.fail(.illegalParameter, "HelloRetryRequest is never used") }
        guard try r.vec8().isEmpty else { throw TLS.fail(.illegalParameter, "legacy_session_id_echo") }
        let suite = try r.u16()
        let compression = try r.u8()
        let extensions = try TLSReader.extensions(try r.vec16())
        try r.end()
        var version: [UInt8]?, keyShare: [UInt8]?
        for (type, data) in extensions {
            switch TLS.Extension(rawValue: type) {
            case .supportedVersions: version = data
            case .keyShare: keyShare = data
            default: throw TLS.fail(.unsupportedExtension, "ServerHello extension \(type)")
            }
        }
        guard legacy == TLS.legacyVersion, let version else { throw TLS.fail(.protocolVersion, "server did not negotiate TLS 1.3") }
        guard version == [0x03, 0x04] else { throw TLS.fail(.illegalParameter, "selected version") }
        guard suite == TLS.cipherAES128GCMSHA256 else { throw TLS.fail(.illegalParameter, "cipher suite \(suite)") }
        guard compression == 0 else { throw TLS.fail(.illegalParameter, "compression") }
        guard let keyShare else { throw TLS.fail(.missingExtension, "key_share") }
        var k = TLSReader(keyShare)
        guard try k.u16() == TLS.groupSecp256r1 else { throw TLS.fail(.illegalParameter, "key share group") }
        let point = try k.vec16()
        try k.end()
        guard point.count == 65, point[0] == 4 else { throw TLS.fail(.illegalParameter, "key share encoding") }
        guard (try? BLESecureIdentifiers.validate(publicKey: point)) != nil else { throw TLS.fail(.illegalParameter, "key share point") }
        return point
    }

    private func parseEncryptedExtensions(_ body: [UInt8]) throws {
        var r = TLSReader(body)
        let extensions = try TLSReader.extensions(try r.vec16())
        try r.end()
        var alpnSelected = false
        for (type, data) in extensions {
            switch TLS.Extension(rawValue: type) {
            case .alpn:
                var a = TLSReader(data)
                var list = TLSReader(try a.vec16())
                try a.end()
                let name = try list.vec8()
                guard list.isAtEnd, name == TLS.alpn else { throw TLS.fail(.noApplicationProtocol, "selected ALPN") }
                alpnSelected = true
            case .supportedGroups:
                continue // RFC 8446 §4.2.7: informational only; never acted upon
            default:
                throw TLS.fail(.unsupportedExtension, "EncryptedExtensions extension \(type)")
            }
        }
        guard alpnSelected else { throw TLS.fail(.noApplicationProtocol, "no ALPN selected") }
    }

    private func parseCertificateRequest(_ body: [UInt8]) throws {
        var r = TLSReader(body)
        guard try r.vec8().isEmpty else { throw TLS.fail(.illegalParameter, "certificate_request_context") }
        let extensions = try TLSReader.extensions(try r.vec16())
        try r.end()
        var schemesSeen = false
        for (type, data) in extensions {
            switch TLS.Extension(rawValue: type) {
            case .signatureAlgorithms, .signatureAlgorithmsCert:
                var s = TLSReader(data)
                let list = try s.vec16()
                try s.end()
                guard list == [0x04, 0x03] else { throw TLS.fail(.illegalParameter, "CertificateRequest schemes") }
                if TLS.Extension(rawValue: type) == .signatureAlgorithms { schemesSeen = true }
            default:
                throw TLS.fail(.illegalParameter, "CertificateRequest extension \(type)")
            }
        }
        guard schemesSeen else { throw TLS.fail(.missingExtension, "CertificateRequest signature_algorithms") }
    }

    private func parseCertificate(_ body: [UInt8]) throws -> [[UInt8]] {
        var r = TLSReader(body)
        guard try r.vec8().isEmpty else { throw TLS.fail(.illegalParameter, "certificate_request_context") }
        var list = TLSReader(try r.vec24())
        try r.end()
        var chain: [[UInt8]] = []
        while !list.isAtEnd {
            let der = try list.vec24()
            guard !der.isEmpty else { throw TLS.fail(.decodeError, "empty certificate entry") }
            guard try list.vec16().isEmpty else { throw TLS.fail(.unsupportedExtension, "certificate entry extension") }
            chain.append(der)
        }
        return chain
    }

    // MARK: records

    private func writePlain(_ type: TLS.ContentType, _ content: [UInt8]) throws {
        var offset = 0
        repeat {
            let chunk = Array(content[offset..<min(content.count, offset + TLS.maxPlaintext)])
            offset += chunk.count
            let version: [UInt8] = type == .handshake && !established && readKeys == nil ? [0x03, 0x01] : [0x03, 0x03]
            try stream.write([type.rawValue] + version + [UInt8(chunk.count >> 8), UInt8(chunk.count & 0xff)] + chunk)
        } while offset < content.count
    }

    private func writeProtected(_ type: TLS.ContentType, _ content: [UInt8]) throws {
        guard writeKeys != nil else { throw TLS.fail(.internalError, "no write keys") }
        var offset = 0
        repeat {
            let chunk = Array(content[offset..<min(content.count, offset + TLS.maxPlaintext)])
            offset += chunk.count
            try stream.write(try writeKeys!.seal(type, chunk))
        } while offset < content.count
    }

    /// The next complete handshake message during the handshake.
    private func nextHandshake(allowCCS: Bool) async throws -> (UInt8, [UInt8], [UInt8]) {
        while true {
            if let message = try handshake.next() { return message }
            guard let (header, body) = try await records.next() else { throw BLESecureTLSError.transportClosed }
            switch header[0] {
            case TLS.ContentType.changeCipherSpec.rawValue:
                // RFC 8446 §5: one byte 0x01 is dropped until the peer's Finished.
                guard allowCCS, body == [0x01] else { throw TLS.fail(.unexpectedMessage, "change_cipher_spec") }
            case TLS.ContentType.alert.rawValue:
                guard readKeys == nil else { throw TLS.fail(.unexpectedMessage, "plaintext alert after key change") }
                throw try alert(body)
            case TLS.ContentType.handshake.rawValue:
                guard readKeys == nil else { throw TLS.fail(.unexpectedMessage, "plaintext handshake after key change") }
                guard !body.isEmpty else { throw TLS.fail(.unexpectedMessage, "empty handshake record") }
                handshake.append(body)
            case TLS.ContentType.applicationData.rawValue:
                guard readKeys != nil else { throw TLS.fail(.unexpectedMessage, "protected record before keys") }
                let (inner, content) = try readKeys!.open(header: header, body: body)
                switch inner {
                case TLS.ContentType.handshake.rawValue:
                    guard !content.isEmpty else { throw TLS.fail(.unexpectedMessage, "empty handshake record") }
                    handshake.append(content)
                case TLS.ContentType.alert.rawValue:
                    throw try alert(content)
                default:
                    throw TLS.fail(.unexpectedMessage, "content type \(inner) during handshake")
                }
            default:
                throw TLS.fail(.unexpectedMessage, "record type")
            }
        }
    }

    private func alert(_ body: [UInt8]) throws -> BLESecureTLSError {
        guard body.count == 2 else { throw TLS.fail(.decodeError, "alert length") }
        return .receivedAlert(body[1])
    }

    // MARK: application data

    /// Sends application data in protected records of ≤ 4352 plaintext bytes.
    public func send(_ data: [UInt8]) throws {
        guard established, !finished else { throw BLESecureTLSError.transportClosed }
        guard !data.isEmpty else { return }
        do { try writeProtected(.applicationData, data) } catch {
            abort(error as? BLESecureTLSError ?? .transportClosed)
            throw error
        }
    }

    /// The next non-empty application-data chunk; nil after the peer's
    /// close_notify. Post-handshake NewSessionTicket is discarded unused;
    /// KeyUpdate fails the session (v2 §6.1). EOF without close_notify throws.
    public func receive() async throws -> [UInt8]? {
        guard established else { throw BLESecureTLSError.transportClosed }
        do {
            while true {
                if finished { return nil }
                if let (type, body, _) = try handshake.next() {
                    try postHandshake(type, body)
                    continue
                }
                guard let (header, body) = try await records.next() else { throw BLESecureTLSError.transportClosed }
                guard !finished else { return nil }
                guard header[0] == TLS.ContentType.applicationData.rawValue else {
                    throw TLS.fail(.unexpectedMessage, "unprotected record after handshake")
                }
                let (inner, content) = try readKeys!.open(header: header, body: body)
                switch inner {
                case TLS.ContentType.applicationData.rawValue:
                    guard handshake.isEmpty else { throw TLS.fail(.unexpectedMessage, "interleaved handshake fragment") }
                    if !content.isEmpty { return content }
                case TLS.ContentType.handshake.rawValue:
                    guard !content.isEmpty else { throw TLS.fail(.unexpectedMessage, "empty handshake record") }
                    handshake.append(content)
                case TLS.ContentType.alert.rawValue:
                    let error = try alert(content)
                    if error == .receivedAlert(TLSAlert.closeNotify.rawValue) {
                        finished = true
                        stream.close()
                        return nil
                    }
                    throw error
                default:
                    throw TLS.fail(.unexpectedMessage, "content type \(inner)")
                }
            }
        } catch let error as BLESecureTLSError {
            abort(error)
            throw error
        }
    }

    private func postHandshake(_ type: UInt8, _ body: [UInt8]) throws {
        switch type {
        case TLS.HandshakeType.newSessionTicket.rawValue:
            return // §6.1: never stored or used
        case TLS.HandshakeType.keyUpdate.rawValue:
            // v2 §6.1: neither end sends KeyUpdate; receipt fails the session.
            throw TLS.fail(.unexpectedMessage, "KeyUpdate received")
        default:
            throw TLS.fail(.unexpectedMessage, "post-handshake message \(type)")
        }
    }

    // MARK: closure

    /// Sends close_notify (if keys exist) and closes the stream.
    public func close() {
        guard !finished else { return }
        finished = true
        if writeKeys != nil, let record = try? writeKeys!.seal(.alert, [1, TLSAlert.closeNotify.rawValue]) {
            try? stream.write(record)
        }
        stream.close()
    }

    private func abort(_ error: BLESecureTLSError) {
        guard !finished else { return }
        finished = true
        let alert: UInt8?
        switch error {
        case .sentAlert(let code, _): alert = code
        case .certificate: alert = TLSAlert.badCertificate.rawValue
        case .receivedAlert, .transportClosed: alert = nil
        }
        if let alert {
            let body: [UInt8] = [2, alert]
            if writeKeys != nil, let record = try? writeKeys!.seal(.alert, body) {
                try? stream.write(record)
            } else {
                try? stream.write([TLS.ContentType.alert.rawValue, 0x03, 0x03, 0x00, 0x02] + body)
            }
        }
        stream.close()
    }
}
