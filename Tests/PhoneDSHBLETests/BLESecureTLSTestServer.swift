// SPDX-License-Identifier: MIT
// A test-only TLS 1.3 server for the secure-session-v1 profile with fault
// knobs. It checks that the phone's ClientHello is exactly the profile and
// can misbehave in every way the phone must refuse.
import CryptoKit
import Foundation
@testable import PhoneDSHBLE

final class BLESecureTestServer: @unchecked Sendable {
    struct Faults {
        var omitSupportedVersions = false
        var cipher: UInt16 = 0x1301
        var group: UInt16 = 0x0017
        var helloRetry = false
        var serverHelloExtra: [(UInt16, [UInt8])] = []
        var alpn: [UInt8]? = Array("pdsh-ble-task/1".utf8)
        var encryptedExtensionsExtra: [(UInt16, [UInt8])] = []
        var sendCertificateRequest = true
        var certificateRequestExtra: [(UInt16, [UInt8])] = []
        var chain: [[UInt8]]?
        var corruptCertificateVerify = false
        var corruptFinished = false
        var sendTicket = false
        var keyUpdate = false
        /// Application data right after the server Finished (0.5-RTT).
        var halfRTTData: [UInt8]?
        var certificateVerifyScheme: UInt16 = 0x0403
        var compatibilityCCS = false
    }

    enum Outcome: Equatable {
        case established
        case clientAlert(UInt8)
        case clientClosed
        case serverRejectedClient(String)
    }

    let stream: BLESecureByteStream
    let signer: BLESecureSigner
    let certificate: [UInt8]
    let phonePins: Set<String>
    var faults: Faults
    private let records: TLSRecordReader
    private var hs = TLSHandshakeBuffer()
    private var readKeys: TLSRecordKeys?
    private var writeKeys: TLSRecordKeys?
    private(set) var clientHelloExtensions: [UInt16] = []
    private(set) var clientHelloSuites: [UInt8] = []
    private(set) var clientHelloSessionID: [UInt8] = [0xff]
    private(set) var clientHelloRecordVersion: [UInt8] = []
    private(set) var clientHelloOK = false

    init(stream: BLESecureByteStream, signer: BLESecureSigner, phonePins: Set<String>, faults: Faults = Faults()) throws {
        self.stream = stream
        self.signer = signer
        self.certificate = try BLESecureCertificate.make(role: .device, signer: signer)
        self.phonePins = phonePins
        self.faults = faults
        self.records = TLSRecordReader(stream: stream)
    }

    private func nextHandshake() async throws -> (UInt8, [UInt8], [UInt8])? {
        while true {
            if let m = try hs.next() { return m }
            guard let (header, body) = try await records.next() else { return nil }
            if header[0] == 21 { throw ClientAlert(code: body.count == 2 ? body[1] : 255) }
            if header[0] == 23 {
                let (inner, content) = try readKeys!.open(header: header, body: body)
                if inner == 21 { throw ClientAlert(code: content[1]) }
                guard inner == 22 else { throw TLS.fail(.unexpectedMessage, "server: inner \(inner)") }
                hs.append(content)
            } else {
                if clientHelloRecordVersion.isEmpty { clientHelloRecordVersion = Array(header[1..<3]) }
                hs.append(body)
            }
        }
    }

    struct ClientAlert: Error { let code: UInt8 }

    /// The client may already have aborted and closed; its alert is read next.
    private func protectedFlight(_ messages: [UInt8]) throws { try? stream.write(try writeKeys!.seal(.handshake, messages)) }

    func run() async -> Outcome {
        do { return try await handshake() }
        catch let alert as ClientAlert { return .clientAlert(alert.code) }
        catch BLESecureTLSError.transportClosed { return .clientClosed }
        catch { return .serverRejectedClient("\(error)") }
    }

    private func ext(_ list: [(UInt16, [UInt8])]) -> [UInt8] {
        var w = TLSWriter()
        for (t, d) in list { w.u16(t); w.vec16(d) }
        return w.bytes
    }

    private func handshake() async throws -> Outcome {
        guard let (type, body, raw) = try await nextHandshake(), type == 1 else { return .clientClosed }
        var transcript = raw
        // Inspect the ClientHello.
        var r = TLSReader(body)
        _ = try r.u16(); _ = try r.take(32)
        clientHelloSessionID = try r.vec8()
        clientHelloSuites = try r.vec16()
        _ = try r.vec8()
        let extensions = try TLSReader.extensions(try r.vec16())
        clientHelloExtensions = extensions.map(\.0)
        var clientShare: [UInt8]?
        for (t, d) in extensions where t == 51 {
            var k = TLSReader(d); var list = TLSReader(try k.vec16())
            if try list.u16() == 0x0017 { clientShare = try list.vec16() }
        }
        clientHelloOK = clientHelloSuites == [0x13, 0x01] && clientHelloSessionID.isEmpty && clientShare != nil
            && Set(clientHelloExtensions) == [43, 10, 13, 50, 51, 16]
            && extensions.first { $0.0 == 43 }?.1 == [2, 3, 4]
            && extensions.first { $0.0 == 10 }?.1 == [0, 2, 0, 0x17]
            && extensions.first { $0.0 == 13 }?.1 == [0, 2, 4, 3]
            && extensions.first { $0.0 == 50 }?.1 == [0, 2, 4, 3]
            && extensions.first { $0.0 == 16 }?.1 == [0, 0x10, 0x0f] + Array("pdsh-ble-task/1".utf8)

        let share = P256.KeyAgreement.PrivateKey()
        var sh = TLSWriter()
        sh.u16(0x0303)
        sh.raw(faults.helloRetry ? TLS.helloRetryRandom : (0..<32).map { _ in UInt8.random(in: 0...255) })
        sh.vec8(clientHelloSessionID)
        sh.u16(faults.cipher)
        sh.u8(0)
        var list: [(UInt16, [UInt8])] = []
        if !faults.omitSupportedVersions { list.append((43, [3, 4])) }
        var ks = TLSWriter(); ks.u16(faults.group)
        ks.vec16(faults.group == 0x0017 ? Array(share.publicKey.x963Representation) : [UInt8](repeating: 9, count: 32))
        list.append((51, ks.bytes))
        list += faults.serverHelloExtra
        sh.vec16(ext(list))
        let serverHello = TLSHandshakeBuffer.message(.serverHello, sh.bytes)
        try? stream.write([22, 3, 3, UInt8(serverHello.count >> 8), UInt8(serverHello.count & 0xff)] + serverHello)
        transcript += serverHello
        if faults.compatibilityCCS { try? stream.write([20, 3, 3, 0, 1, 1]) }
        guard let clientShare, faults.group == 0x0017, !faults.helloRetry else { return try await awaitAlert() }
        let shared = try share.sharedSecretFromKeyAgreement(with: try P256.KeyAgreement.PublicKey(x963Representation: Data(clientShare)))
            .withUnsafeBytes { Array($0) }
        let secrets = TLSKeySchedule.Secrets(sharedSecret: shared, helloHash: TLSKeySchedule.hash(transcript))
        readKeys = TLSRecordKeys(secret: secrets.clientHandshake)
        writeKeys = TLSRecordKeys(secret: secrets.serverHandshake)

        var flight: [UInt8] = []
        var eeList = faults.encryptedExtensionsExtra
        if let alpn = faults.alpn { var a = TLSWriter(); var n = TLSWriter(); n.vec8(alpn); a.vec16(n.bytes); eeList.insert((16, a.bytes), at: 0) }
        var ee = TLSWriter(); ee.vec16(ext(eeList))
        flight += TLSHandshakeBuffer.message(.encryptedExtensions, ee.bytes)
        if faults.sendCertificateRequest {
            var cr = TLSWriter(); cr.vec8([])
            cr.vec16(ext([(13, [0, 2, 4, 3])] + faults.certificateRequestExtra))
            flight += TLSHandshakeBuffer.message(.certificateRequest, cr.bytes)
        }
        var cert = TLSWriter(); cert.vec8([])
        var entries = TLSWriter()
        for der in faults.chain ?? [certificate] { entries.vec24(der); entries.vec16([]) }
        cert.vec24(entries.bytes)
        flight += TLSHandshakeBuffer.message(.certificate, cert.bytes)
        var signature = try signer.sign(TLSSignature.content(server: true, transcriptHash: TLSKeySchedule.hash(transcript + flight)))
        if faults.corruptCertificateVerify { signature = try signer.sign([1, 2, 3]) }
        var cv = TLSWriter(); cv.u16(faults.certificateVerifyScheme); cv.vec16(signature)
        flight += TLSHandshakeBuffer.message(.certificateVerify, cv.bytes)
        var mac = TLSKeySchedule.finishedMAC(baseKey: secrets.serverHandshake, transcriptHash: TLSKeySchedule.hash(transcript + flight))
        if faults.corruptFinished { mac[0] ^= 1 }
        flight += TLSHandshakeBuffer.message(.finished, mac)
        try protectedFlight(flight)
        transcript += flight
        let application = secrets.application(serverFinishedHash: TLSKeySchedule.hash(transcript))
        var appWrite = TLSRecordKeys(secret: application.server)
        if let early = faults.halfRTTData { try? stream.write(try appWrite.seal(.applicationData, early)) }

        // Client flight.
        guard let (ct, cbody, craw) = try await nextHandshake() else { return .clientClosed }
        guard ct == 11 else { return .serverRejectedClient("expected Certificate") }
        var c = TLSReader(cbody)
        guard try c.vec8().isEmpty else { return .serverRejectedClient("context") }
        var centries = TLSReader(try c.vec24())
        var chain: [[UInt8]] = []
        while !centries.isAtEnd { chain.append(try centries.vec24()); _ = try centries.vec16() }
        if chain.isEmpty { try sendAlert(116); return .serverRejectedClient("certificate_required") }
        guard case .success = BLESecureCertificate.verify(chain: chain, pins: phonePins) else {
            try sendAlert(42); return .serverRejectedClient("bad_certificate")
        }
        transcript += craw
        guard let (vt, vbody, vraw) = try await nextHandshake(), vt == 15 else { return .serverRejectedClient("expected CertificateVerify") }
        var v = TLSReader(vbody)
        guard try v.u16() == 0x0403,
              TLSSignature.verify(publicKey: TLSSignature.point(of: chain[0])!, signature: try v.vec16(),
                                  content: TLSSignature.content(server: false, transcriptHash: TLSKeySchedule.hash(transcript))) else {
            try sendAlert(51); return .serverRejectedClient("client CertificateVerify")
        }
        transcript += vraw
        guard let (ft, fbody, _) = try await nextHandshake(), ft == 20,
              fbody == TLSKeySchedule.finishedMAC(baseKey: secrets.clientHandshake, transcriptHash: TLSKeySchedule.hash(transcript)) else {
            try sendAlert(51); return .serverRejectedClient("client Finished")
        }
        readKeys = TLSRecordKeys(secret: application.client)
        writeKeys = appWrite
        if faults.sendTicket {
            var t = TLSWriter(); t.raw([0, 0, 0, 60, 1, 2, 3, 4]); t.vec8([9]); t.vec16([1, 2, 3]); t.vec16([])
            try stream.write(try writeKeys!.seal(.handshake, TLSHandshakeBuffer.message(.newSessionTicket, t.bytes)))
        }
        if faults.keyUpdate {
            try stream.write(try writeKeys!.seal(.handshake, TLSHandshakeBuffer.message(.keyUpdate, [1])))
            writeKeys = TLSRecordKeys(secret: TLSKeySchedule.nextTrafficSecret(writeKeys!.secret))
        }
        return .established
    }

    private func sendAlert(_ code: UInt8) throws {
        if writeKeys != nil { try? stream.write(try writeKeys!.seal(.alert, [2, code])) }
        else { try? stream.write([21, 3, 3, 0, 2, 2, code]) }
        stream.close()
    }

    private func awaitAlert() async throws -> Outcome {
        while true {
            guard let (header, body) = try await records.next() else { return .clientClosed }
            if header[0] == 21 { return .clientAlert(body[1]) }
        }
    }

    // MARK: application data after .established

    private var appBuffer = TLSHandshakeBuffer()

    func receive() async throws -> [UInt8]? {
        while true {
            guard let (header, body) = try await records.next() else { return nil }
            let (inner, content) = try readKeys!.open(header: header, body: body)
            switch inner {
            case 23: return content
            case 21: if content == [1, 0] { return nil }; throw ClientAlert(code: content[1])
            case 22:
                appBuffer.append(content)
                while let (t, b, _) = try appBuffer.next() {
                    guard t == 24 else { throw TLS.fail(.unexpectedMessage, "server: post-handshake \(t)") }
                    readKeys = TLSRecordKeys(secret: TLSKeySchedule.nextTrafficSecret(readKeys!.secret))
                    if b == [1] { throw TLS.fail(.unexpectedMessage, "client requested update") }
                }
            default: throw TLS.fail(.unexpectedMessage, "server: inner \(inner)")
            }
        }
    }

    func send(_ bytes: [UInt8]) throws { try stream.write(try writeKeys!.seal(.applicationData, bytes)) }
    func sendRawRecord(type: TLS.ContentType, _ content: [UInt8]) throws { try stream.write(try writeKeys!.seal(type, content)) }
    func closeNotify() { try? stream.write(try writeKeys!.seal(.alert, [1, 0])); stream.close() }
}
